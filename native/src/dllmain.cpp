// Core's native part (docs: _bmad-output/specs/spec-core-v0/api-contract.md, "C++ natives").
//
// Registers <Core>_NativeVersion, <Core>_Ref, <Core>_Deref and <Core>_RefFree into every Lua mod's state in
// on_lua_start, before that mod's main.lua runs. <Core> is CORE_NAME (core_config.hpp, generated from mod.json
// "name"); nothing here spells the name. Weak handles are FWeakObjectPtr (GUObjectArray index + serial number), so a
// handle never resolves to an object that took over a freed object's slot or address.
//
// Rules (AGENTS.md, "C++ mods"): only LuaMadeSimple and other UE4SS.dll exports, never the Lua C API; never call
// into a Lua state; catch everything in engine hook callbacks; undo every registration in the destructor.
//
// Hardening: whatever a dependent passes, core must not crash the game.
//   - Every Lua-facing function runs its body inside guarded(): argument problems become one clean Lua error
//     "<fn>: <problem>"; any C++ exception becomes "<fn>: internal error ..." and is logged. Lua is only touched
//     (results pushed, errors raised) outside the try block, so a Lua error never meets our catch clauses.
//   - <Core>_Ref never reads through the address it is given. It looks the address up in GUObjectArray, comparing
//     pointers only (scan_object_array), and builds the weak pointer from the slot index it found.
//   - Reads of engine memory (the object array, weak pointer resolution) run under SEH (__try/__except) as a last
//     resort; a fault is logged with context and becomes a Lua error, never a crash.

#include <excpt.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <format>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Helpers/String.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <LuaType/LuaUObject.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/FWeakObjectPtr.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectArray.hpp>

#include "core_config.hpp"

using namespace RC;
using namespace RC::Unreal;
using Lua = RC::LuaMadeSimple::Lua;

namespace
{
    template <typename... Args>
    void logf(std::format_string<Args...> fmt, Args&&... args)
    {
        try
        {
            auto line = std::format(fmt, std::forward<Args>(args)...);
            Output::send<LogLevel::Normal>(STR("[{}] native: {}\n"), ensure_str(std::string{CORE_NAME}), ensure_str(line));
        }
        catch (...)
        {
            // Logging must never take the caller down; there is nowhere left to report this.
        }
    }

    // The game thread is the one that runs engine ticks. Before the first tick (every main.lua) it is unknown and
    // UObject calls are allowed: all Lua mods load one after another on one thread then.
    std::atomic<bool> g_game_thread_known{false};
    std::thread::id g_game_thread{};

    const std::string g_fn_version = std::string{CORE_NAME} + "_NativeVersion";
    const std::string g_fn_ref = std::string{CORE_NAME} + "_Ref";
    const std::string g_fn_deref = std::string{CORE_NAME} + "_Deref";
    const std::string g_fn_free = std::string{CORE_NAME} + "_RefFree";

    // A problem with what the caller passed (or did). Its text is the whole Lua error message.
    struct ArgError : std::runtime_error
    {
        using std::runtime_error::runtime_error;
    };

    // ------------------------------------------------------------------ SEH last-resort guards
    // Functions with __try may not hold C++ objects that need unwinding, so these take and return plain values only.

    int seh_filter(unsigned long code)
    {
        switch (code)
        {
        case 0xC0000005: // access violation
        case 0xC0000006: // in-page error
        case 0x80000002: // datatype misalignment
        case 0xC000001D: // illegal instruction
        case 0xC0000094: // integer divide by zero
        case 0xC0000096: // privileged instruction
            return EXCEPTION_EXECUTE_HANDLER;
        default:
            return EXCEPTION_CONTINUE_SEARCH; // C++ exceptions (0xE06D7363) and everything else pass through
        }
    }

    constexpr int32_t k_chunk = TUObjectArray::NumElementsPerChunk;
    // How to read FUObjectItem::Object without a call per item; found once by probe_object_array().
    int32_t g_item_stride = 0;
    int32_t g_object_offset = -1;
    bool g_contiguous_chunks = false;
    std::once_flag g_probe_once;

    struct ScanResult
    {
        int32_t index;   // slot index when found
        int32_t scanned; // slots compared
        unsigned long fault;
    };

    // 1 = found, 0 = not in the array, -1 = SEH fault (fault code set). Compares pointers only: never reads *target.
    int scan_object_array(const void* target, ScanResult* out)
    {
        out->index = -1;
        out->scanned = 0;
        out->fault = 0;
        __try
        {
            const int32_t n = FUObjectArray::GetNumElements();
            if (g_contiguous_chunks)
            {
                for (int32_t base = 0; base < n; base += k_chunk)
                {
                    const auto* first = reinterpret_cast<const uint8_t*>(FUObjectArray::IndexToObject(base));
                    if (!first) break;
                    const int32_t count = (n - base < k_chunk) ? (n - base) : k_chunk;
                    const uint8_t* p = first + g_object_offset;
                    for (int32_t i = 0; i < count; ++i, p += g_item_stride)
                    {
                        if (*reinterpret_cast<const void* const*>(p) == target)
                        {
                            out->index = base + i;
                            out->scanned += i + 1;
                            return 1;
                        }
                    }
                    out->scanned += count;
                }
            }
            else
            {
                for (int32_t i = 0; i < n; ++i)
                {
                    const auto* item = FUObjectArray::IndexToObject(i);
                    if (item && item->GetUObject() == target)
                    {
                        out->index = i;
                        out->scanned = i + 1;
                        return 1;
                    }
                }
                out->scanned = n;
            }
            return 0;
        }
        __except (seh_filter(GetExceptionCode()))
        {
            out->fault = GetExceptionCode();
            return -1;
        }
    }

    // Finds where FUObjectItem keeps its object pointer and whether a chunk's items are contiguous, by comparing
    // against GetUObject() on live slots. Falls back to one GetUObject() call per slot if anything disagrees.
    // Returns 0 or an SEH fault code.
    unsigned long probe_object_array_raw(int32_t* stride, int32_t* offset, bool* contiguous)
    {
        __try
        {
            *stride = FUObjectArray::GetObjectItemSize();
            *offset = -1;
            *contiguous = false;
            const int32_t n = FUObjectArray::GetNumElements();
            if (*stride < 8 || *stride > 64 || n < 2) return 0;
            const auto* item0 = reinterpret_cast<const uint8_t*>(FUObjectArray::IndexToObject(0));
            const void* obj0 = item0 ? FUObjectArray::IndexToObject(0)->GetUObject() : nullptr;
            if (!obj0) return 0;
            for (int32_t off = 0; off + 8 <= *stride; off += 8)
            {
                if (*reinterpret_cast<const void* const*>(item0 + off) == obj0)
                {
                    *offset = off;
                    break;
                }
            }
            if (*offset < 0) return 0;
            // Check the layout on a spread of slots in the first chunks.
            const int32_t limit = n < 2 * k_chunk ? n : 2 * k_chunk;
            for (int32_t i = 1; i < limit; i += 997)
            {
                const int32_t base = (i / k_chunk) * k_chunk;
                const auto* first = reinterpret_cast<const uint8_t*>(FUObjectArray::IndexToObject(base));
                const auto* item = FUObjectArray::IndexToObject(i);
                if (!first || !item) return 0;
                if (reinterpret_cast<const uint8_t*>(item) != first + static_cast<size_t>(i - base) * *stride) return 0;
                if (*reinterpret_cast<const void* const*>(reinterpret_cast<const uint8_t*>(item) + *offset) != item->GetUObject()) return 0;
            }
            *contiguous = true;
            return 0;
        }
        __except (seh_filter(GetExceptionCode()))
        {
            *contiguous = false;
            return GetExceptionCode();
        }
    }

    void probe_object_array()
    {
        std::call_once(g_probe_once, [] {
            int32_t stride{}, offset{};
            bool contiguous{};
            const auto fault = probe_object_array_raw(&stride, &offset, &contiguous);
            g_item_stride = stride;
            g_object_offset = offset;
            g_contiguous_chunks = contiguous && fault == 0;
            logf("GUObjectArray layout: item size {}, object at +{}, scan mode {}{}", stride, offset,
                 g_contiguous_chunks ? "contiguous chunks" : "one GetUObject() per slot",
                 fault ? std::format(" (probe faulted 0x{:08X})", fault) : std::string{});
        });
    }

    // Slot state after a successful scan: 1 = live, 0 = slot no longer holds target or is unreachable/garbage,
    // -1 = SEH fault.
    int slot_state(int32_t index, const void* target, unsigned long* fault)
    {
        *fault = 0;
        __try
        {
            auto* item = FUObjectArray::IndexToObject(index);
            if (!item || item->GetUObject() != target) return 0;
            if (item->IsUnreachable() || item->IsPendingKill()) return 0;
            return 1;
        }
        __except (seh_filter(GetExceptionCode()))
        {
            *fault = GetExceptionCode();
            return -1;
        }
    }

    // FWeakObjectPtr::Get() under SEH. Reads only GUObjectArray (by the stored index), never the object.
    UObject* weak_get(const FWeakObjectPtr* weak, unsigned long* fault)
    {
        *fault = 0;
        __try
        {
            return weak->Get();
        }
        __except (seh_filter(GetExceptionCode()))
        {
            *fault = GetExceptionCode();
            return nullptr;
        }
    }

    // One log line per fault (the first 16; then every 256th), so a fault is never silent and never floods the log.
    std::atomic<uint32_t> g_faults{0};
    void log_fault(const std::string& fn, const char* what, unsigned long code, uint64_t detail)
    {
        const auto n = ++g_faults;
        if (n <= 16 || n % 256 == 0)
        {
            logf("FAULT {}: SEH exception 0x{:08X} while {} (detail 0x{:X}); call refused, game continues (fault #{})", fn, code, what, detail, n);
        }
    }

    // ------------------------------------------------------------------ argument checks

    void require_game_thread(const std::string& fn)
    {
        if (g_game_thread_known.load() && std::this_thread::get_id() != g_game_thread)
        {
            throw ArgError(std::format("{} refused: called off the game thread", fn));
        }
    }

    // Describes argument 1 by its Lua type (lua_isnumber/lua_isstring would also accept numeric strings and numbers).
    auto describe_first_arg(const Lua& lua) -> std::string
    {
        if (lua.get_stack_size() < 1) return "nothing";
        const std::string type{lua.get_type_string()};
        if (type == "number") return lua.is_integer(1) ? "an integer" : "a float";
        if (type == "nil") return "nil";
        if (type == "boolean") return "a boolean";
        if (type == "string") return "a string";
        if (type == "table") return "a table";
        if (type == "function") return "a function";
        if (type == "userdata") return "a userdata";
        return "a " + type;
    }

    void require_args(const Lua& lua, const std::string& fn, int32_t want, const char* what)
    {
        const int32_t got = lua.get_stack_size();
        if (got != want)
        {
            throw ArgError(std::format("{}: expected {} argument{}{}, got {}", fn, want, want == 1 ? "" : "s", what, got));
        }
    }

    // Exactly one integer argument (Lua integer subtype; floats and numeric strings are refused, never coerced).
    auto one_integer(const Lua& lua, const std::string& fn, const char* name) -> int64_t
    {
        require_args(lua, fn, 1, std::format(" ({})", name).c_str());
        if (!lua.is_integer(1)) throw ArgError(std::format("{}: argument 1 ({}) must be an integer, got {}", fn, name, describe_first_arg(lua)));
        return lua.get_integer(1);
    }

    // Handles are 1 .. 2^53-1, so they survive any float round trip in Lua.
    constexpr int64_t k_max_handle = (int64_t{1} << 53) - 1;
    auto one_handle(const Lua& lua, const std::string& fn) -> int64_t
    {
        const int64_t h = one_integer(lua, fn, "handle");
        if (h < 1 || h > k_max_handle) throw ArgError(std::format("{}: handle {} is out of range (1..{})", fn, h, k_max_handle));
        return h;
    }

    // ------------------------------------------------------------------ the guard every Lua-facing function uses

    // What a body hands back; guarded() pushes it onto the Lua stack after leaving the try block.
    struct Result
    {
        enum class Kind { None, Integer, Object, Nil, Strings } kind = Kind::None;
        int64_t integer{};
        UObject* object{};
        const char* s1{};
        const char* s2{};
    };

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
            LuaType::auto_construct_object(lua, r.object);
            return 1;
        case Result::Kind::Nil:
            lua.set_nil();
            return 1;
        case Result::Kind::Strings:
            lua.set_string(r.s1);
            lua.set_string(r.s2);
            return 2;
        default:
            return 0;
        }
    }

    // ------------------------------------------------------------------ weak handles
    // Positive integers, unique for this DLL's lifetime; a hot reload starts an empty table.
    constexpr size_t k_max_handles = 65536;
    std::mutex g_weak_mutex;
    std::unordered_map<int64_t, FWeakObjectPtr> g_weak;
    int64_t g_weak_next = 1;

    // Cost of the GUObjectArray lookup, logged at call counts 1, 2, 4, 8, ... (a bounded number of lines).
    std::atomic<uint64_t> g_scan_calls{0};
    std::atomic<uint64_t> g_scan_total_ns{0};
    std::atomic<uint64_t> g_scan_max_ns{0};

    int l_native_version(const Lua& lua)
    {
        return guarded(lua, g_fn_version, [&] {
            require_args(lua, g_fn_version, 0, "");
            Result r;
            r.kind = Result::Kind::Strings;
            r.s1 = CORE_VERSION;
            r.s2 = CORE_UE4SS_BUILD;
            return r;
        });
    }

    // <Core>_Ref(address): address is obj:GetAddress() of an object the caller holds right now.
    int l_ref(const Lua& lua)
    {
        return guarded(lua, g_fn_ref, [&] {
            require_game_thread(g_fn_ref);
            const int64_t addr = one_integer(lua, g_fn_ref, "address");
            if (addr == 0) throw ArgError(std::format("{}: address is null (0)", g_fn_ref));
            // User-mode canonical addresses on x64 Windows; anything else cannot be an object.
            if (addr < 0x10000 || addr > 0x7FFFFFFFFFFF)
            {
                throw ArgError(std::format("{}: address {} is not a live UObject (outside the user address space)", g_fn_ref, addr));
            }
            if (addr % 8 != 0) throw ArgError(std::format("{}: address 0x{:X} is not a live UObject (misaligned)", g_fn_ref, addr));
            const void* target = reinterpret_cast<const void*>(static_cast<uintptr_t>(addr));

            probe_object_array();
            ScanResult scan{};
            const auto t0 = std::chrono::steady_clock::now();
            const int found = scan_object_array(target, &scan);
            const auto ns = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count());
            const auto calls = ++g_scan_calls;
            const auto total = (g_scan_total_ns += ns);
            uint64_t prev_max = g_scan_max_ns.load();
            while (ns > prev_max && !g_scan_max_ns.compare_exchange_weak(prev_max, ns)) {}
            if ((calls & (calls - 1)) == 0)
            {
                logf("REF_COST calls={} last={:.3f} ms avg={:.3f} ms max={:.3f} ms slots={} (scan of {} of {} slots)", calls, ns / 1e6,
                     total / 1e6 / static_cast<double>(calls), g_scan_max_ns.load() / 1e6, FUObjectArray::GetNumElements(), scan.scanned,
                     FUObjectArray::GetNumElements());
            }
            if (found < 0)
            {
                log_fault(g_fn_ref, "scanning GUObjectArray", scan.fault, static_cast<uint64_t>(addr));
                throw ArgError(std::format("{}: internal fault while scanning GUObjectArray (logged); nothing was referenced", g_fn_ref));
            }
            if (found == 0) throw ArgError(std::format("{}: address 0x{:X} is not a live UObject (not in GUObjectArray)", g_fn_ref, addr));

            unsigned long fault{};
            const int state = slot_state(scan.index, target, &fault);
            if (state < 0)
            {
                log_fault(g_fn_ref, "reading a GUObjectArray slot", fault, static_cast<uint64_t>(scan.index));
                throw ArgError(std::format("{}: internal fault while reading GUObjectArray (logged); nothing was referenced", g_fn_ref));
            }
            if (state == 0) throw ArgError(std::format("{}: address 0x{:X} is not a live UObject (being destroyed)", g_fn_ref, addr));

            // Built from the slot we found: ObjectToIndex without reading the object (FWeakObjectPtr's own
            // operator= would read Object->InternalIndex).
            FWeakObjectPtr weak{};
            weak.ObjectIndex = scan.index;
            weak.ObjectSerialNumber = FUObjectArray::AllocateSerialNumber(scan.index);
            if (weak_get(&weak, &fault) != target)
            {
                if (fault) log_fault(g_fn_ref, "resolving the new weak pointer", fault, static_cast<uint64_t>(scan.index));
                throw ArgError(std::format("{}: address 0x{:X} is not a live UObject (slot changed while referencing)", g_fn_ref, addr));
            }

            Result r;
            r.kind = Result::Kind::Integer;
            {
                std::lock_guard guard{g_weak_mutex};
                if (g_weak.size() >= k_max_handles)
                {
                    throw ArgError(std::format("{}: too many live handles ({}); free some with {}", g_fn_ref, k_max_handles, g_fn_free));
                }
                if (g_weak_next > k_max_handle) throw ArgError(std::format("{}: handle space exhausted", g_fn_ref));
                r.integer = g_weak_next++;
                g_weak.emplace(r.integer, weak);
            }
            return r;
        });
    }

    // <Core>_Deref(handle): the object, or nil once it is gone, its slot reused, or the handle unknown.
    int l_deref(const Lua& lua)
    {
        return guarded(lua, g_fn_deref, [&] {
            require_game_thread(g_fn_deref);
            const int64_t handle = one_handle(lua, g_fn_deref);
            FWeakObjectPtr weak{};
            bool known = false;
            {
                std::lock_guard guard{g_weak_mutex};
                auto it = g_weak.find(handle);
                if (it != g_weak.end())
                {
                    weak = it->second;
                    known = true;
                }
            }
            Result r;
            r.kind = Result::Kind::Nil;
            if (known)
            {
                unsigned long fault{};
                UObject* obj = weak_get(&weak, &fault);
                if (fault)
                {
                    log_fault(g_fn_deref, "resolving a weak handle", fault, static_cast<uint64_t>(handle));
                    throw ArgError(std::format("{}: internal fault while resolving handle {} (logged)", g_fn_deref, handle));
                }
                if (obj)
                {
                    r.kind = Result::Kind::Object;
                    r.object = obj;
                }
            }
            return r;
        });
    }

    // <Core>_RefFree(handle): idempotent; touches no UObject, so any thread may call it.
    int l_ref_free(const Lua& lua)
    {
        return guarded(lua, g_fn_free, [&] {
            const int64_t handle = one_handle(lua, g_fn_free);
            std::lock_guard guard{g_weak_mutex};
            g_weak.erase(handle);
            return Result{};
        });
    }

    void engine_tick_pre(Hook::TCallbackIterationData<void>&, UEngine*, float, bool)
    {
        // Registered with bOnce: runs on the first tick only. UE4SS removes a hook whose callback throws: catch everything.
        try
        {
            if (!g_game_thread_known.load())
            {
                g_game_thread = std::this_thread::get_id();
                g_game_thread_known = true;
                logf("game thread known (first engine tick)");
            }
        }
        catch (const std::exception& e)
        {
            logf("ERROR engine tick hook: {}", e.what());
        }
        catch (...)
        {
            logf("ERROR engine tick hook: unknown C++ exception");
        }
    }
} // namespace

class CoreNative : public CppUserModBase
{
    std::vector<Hook::GlobalCallbackId> m_hooks;

  public:
    CoreNative() : CppUserModBase()
    {
        ModName = ensure_str(std::string{CORE_NAME});
        ModVersion = ensure_str(std::string{CORE_VERSION});
        ModDescription = STR("Core shared library: native part");
        ModAuthors = STR("nuclear-nightmare workspace");
        // The constructor runs before Unreal is initialized: no UObject access here.
        logf("loaded, version {} for UE4SS {}", CORE_VERSION, CORE_UE4SS_BUILD);

        register_on_unreal_init([](CppUserModBase* self) {
            try
            {
                static_cast<CoreNative*>(self)->unreal_init();
            }
            catch (const std::exception& e)
            {
                logf("ERROR unreal init: {}", e.what());
            }
            catch (...)
            {
                logf("ERROR unreal init: unknown C++ exception");
            }
        });
        register_on_lua_start([](CppUserModBase*, CStringView, Lua& lua, Lua&, Lua&, Lua*) {
            // Globals live in the mod's main state, which its main, async and hook threads share. Every Lua mod
            // gets them, so dependents can call them from main.lua.
            try
            {
                lua.register_function(g_fn_version.c_str(), &l_native_version);
                lua.register_function(g_fn_ref.c_str(), &l_ref);
                lua.register_function(g_fn_deref.c_str(), &l_deref);
                lua.register_function(g_fn_free.c_str(), &l_ref_free);
            }
            catch (const std::exception& e)
            {
                logf("ERROR registering natives into a Lua mod: {}", e.what());
            }
            catch (...)
            {
                logf("ERROR registering natives into a Lua mod: unknown C++ exception");
            }
        });
    }

    ~CoreNative() override
    {
        // Hot reload unloads this DLL: nothing may keep pointing into it.
        try
        {
            for (auto id : m_hooks)
            {
                Hook::UnregisterCallback(id);
            }
            size_t handles{};
            {
                std::lock_guard guard{g_weak_mutex};
                handles = g_weak.size();
                g_weak.clear();
            }
            logf("unloading: unregistered {} hooks, dropped {} handles", m_hooks.size(), handles);
        }
        catch (...)
        {
            logf("ERROR while unloading (unknown exception)");
        }
    }

    void unreal_init()
    {
        m_hooks.push_back(Hook::RegisterEngineTickPreCallback(&engine_tick_pre, {true, true, ensure_str(std::string{CORE_NAME}), STR("engine_tick_pre")}));
    }
};

extern "C"
{
    __declspec(dllexport) CppUserModBase* start_mod()
    {
        return new CoreNative();
    }
    __declspec(dllexport) void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
