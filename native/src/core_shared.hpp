// What core's natives share (dllmain.cpp, objectives.cpp, and the test-only DLL in test/SkelNative): logging, the
// game-thread rule, argument checks, the guard every Lua-facing function runs in, and the live-object proof
// (GUObjectArray scan and slot state under SEH). Definitions in core_shared.cpp; nothing here spells core's name.
#pragma once

#include <atomic>
#include <cstdint>
#include <format>
#include <stdexcept>
#include <string>
#include <thread>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Helpers/String.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <LuaType/LuaUObject.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <Unreal/UObject.hpp>

namespace core_native
{
    using Lua = RC::LuaMadeSimple::Lua;

    // The tag in front of every log line: "[<tag>] native: ...". CORE_NAME unless a DLL sets another one.
    extern std::string g_log_tag;

    template <typename... Args>
    void logf(std::format_string<Args...> fmt, Args&&... args)
    {
        try
        {
            auto line = std::format(fmt, std::forward<Args>(args)...);
            RC::Output::send<RC::LogLevel::Normal>(STR("[{}] native: {}\n"), RC::ensure_str(g_log_tag), RC::ensure_str(line));
        }
        catch (...)
        {
            // Logging must never take the caller down; there is nowhere left to report this.
        }
    }

    // A problem with what the caller passed (or did). Its text is the whole Lua error message.
    struct ArgError : std::runtime_error
    {
        using std::runtime_error::runtime_error;
    };

    // ------------------------------------------------------------------ the game thread
    // The game thread is the one that runs engine ticks. Before the first tick (every main.lua) it is unknown and
    // UObject calls are allowed: all Lua mods load one after another on one thread then.
    extern std::atomic<bool> g_game_thread_known;
    extern std::thread::id g_game_thread;
    // Engine tick pre-callback (registered once): records the game thread. Catches everything.
    void engine_tick_pre(RC::Unreal::Hook::TCallbackIterationData<void>&, RC::Unreal::UEngine*, float, bool);
    // Throws "<fn> refused: called off the game thread" off the game thread (once it is known).
    void require_game_thread(const std::string& fn);

    // ------------------------------------------------------------------ arguments
    // Argument 1 by its Lua type ("an integer", "a float", "nil", "a boolean", "a string", "a table", ...).
    auto describe_first_arg(const Lua& lua) -> std::string;
    // Exactly want arguments, else "<fn>: expected <want> argument(s)<what>, got <n>".
    void require_args(const Lua& lua, const std::string& fn, int32_t want, const char* what);

    // ------------------------------------------------------------------ SEH last-resort guards and the live-object proof
    // Functions with __try may not hold C++ objects that need unwinding, so these take and return plain values only.
    int seh_filter(unsigned long code);

    struct ScanResult
    {
        int32_t index;   // slot index when found
        int32_t scanned; // slots compared
        unsigned long fault;
    };
    // Finds once how to read FUObjectItem::Object quickly (logs the layout); call before scan_object_array.
    void probe_object_array();
    // 1 = found, 0 = not in the array, -1 = SEH fault (fault code set). Compares pointers only: never reads *target.
    int scan_object_array(const void* target, ScanResult* out);
    // Slot state after a successful scan: 1 = live, 0 = slot no longer holds target or is unreachable/pending kill,
    // -1 = SEH fault.
    int slot_state(int32_t index, const void* target, unsigned long* fault);

    // Flags of a proven-live object (bits of ObjectFlagBits), read under SEH. 1 = read, 0 = the slot no longer holds
    // target, -1 = SEH fault.
    enum ObjectFlagBits : uint32_t
    {
        OF_ClassDefaultObject = 1u << 0, // RF_ClassDefaultObject
        OF_Archetype = 1u << 1,          // RF_ArchetypeObject
        OF_Garbage = 1u << 2,            // UE5: EInternalObjectFlags::Garbage (1 << 21) or RF_MirroredGarbage (0x40000000)
    };
    int object_flags(int32_t index, const void* target, uint32_t* bits, unsigned long* fault);

    // One log line per fault (the first 16; then every 256th), so a fault is never silent and never floods the log.
    void log_fault(const std::string& fn, const char* what, unsigned long code, uint64_t detail);

    // ------------------------------------------------------------------ the guard every Lua-facing function uses
    // What a body hands back; guarded() pushes it onto the Lua stack after leaving the try block.
    struct Result
    {
        enum class Kind { None, Integer, Object, Nil, Strings, String } kind = Kind::None;
        int64_t integer{};
        RC::Unreal::UObject* object{};
        const char* s1{};
        const char* s2{};
        std::string text; // Kind::String
    };

    // Runs body. An ArgError becomes the Lua error "<its text>"; any other C++ exception becomes "<fn>: internal
    // error ..." and is logged. Lua is only touched (results pushed, errors raised) outside the try block, so a Lua
    // error never meets our catch clauses.
    template <typename Body>
    int guarded(const Lua& lua, const std::string& fn, Body&& body)
    {
        Result r{};
        std::string error;
        try
        {
            r = body();
        }
        catch (const ArgError& e)
        {
            error = e.what();
        }
        catch (const std::exception& e)
        {
            error = std::format("{}: internal error: {}", fn, e.what());
            logf("ERROR {}", error);
        }
        catch (...)
        {
            error = std::format("{}: internal error (unknown C++ exception)", fn);
            logf("ERROR {}", error);
        }
        if (!error.empty())
        {
            lua.throw_error(error); // raises the Lua error; does not return
            return 0;
        }
        switch (r.kind)
        {
        case Result::Kind::Integer:
            lua.set_integer(r.integer);
            return 1;
        case Result::Kind::Object:
            // auto_construct_object(nullptr) pushes an invalid wrapper, not nil; only live objects get here.
            RC::LuaType::auto_construct_object(lua, r.object);
            return 1;
        case Result::Kind::Nil:
            lua.set_nil();
            return 1;
        case Result::Kind::Strings:
            lua.set_string(r.s1);
            lua.set_string(r.s2);
            return 2;
        case Result::Kind::String:
            lua.set_string(std::string_view{r.text});
            return 1;
        default:
            return 0;
        }
    }
} // namespace core_native
