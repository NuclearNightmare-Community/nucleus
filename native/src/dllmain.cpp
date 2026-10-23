// Core's native part (docs: _bmad-output/specs/spec-core-v0/api-contract.md, "C++ natives").
//
// Registers <Core>_NativeVersion, <Core>_Ref, <Core>_Deref and <Core>_RefFree into every Lua mod's state in
// on_lua_start, before that mod's main.lua runs. Weak handles are FWeakObjectPtr (GUObjectArray index + serial
// number), so a handle never resolves to an object that took over a freed object's slot or address.
//
// Rules (AGENTS.md, "C++ mods"): only LuaMadeSimple and other UE4SS.dll exports, never the Lua C API; never call
// into a Lua state; catch everything in engine hook callbacks; undo every registration in the destructor.

#include <atomic>
#include <cstdint>
#include <format>
#include <mutex>
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
        auto line = std::format(fmt, std::forward<Args>(args)...);
        Output::send<LogLevel::Normal>(STR("[{}] native: {}\n"), ensure_str(std::string{CORE_NAME}), ensure_str(line));
    }

    // The game thread is the one that runs engine ticks. Before the first tick (every main.lua) it is unknown and
    // UObject calls are allowed: all Lua mods load one after another on one thread then.
    std::atomic<bool> g_game_thread_known{false};
    std::thread::id g_game_thread{};

    const std::string g_fn_version = std::string{CORE_NAME} + "_NativeVersion";
    const std::string g_fn_ref = std::string{CORE_NAME} + "_Ref";
    const std::string g_fn_deref = std::string{CORE_NAME} + "_Deref";
    const std::string g_fn_free = std::string{CORE_NAME} + "_RefFree";

    void require_game_thread(const Lua& lua, const std::string& fn)
    {
        if (g_game_thread_known.load() && std::this_thread::get_id() != g_game_thread)
        {
            lua.throw_error(std::format("{} refused: called off the game thread", fn));
        }
    }

    auto arg_int(const Lua& lua, const std::string& fn) -> int64_t
    {
        if (!lua.is_integer()) lua.throw_error(std::format("{}: expected an integer argument", fn));
        return lua.get_integer();
    }

    // Weak handles. Positive integers, unique for this DLL's lifetime; a hot reload starts an empty table.
    constexpr size_t k_max_handles = 65536;
    std::mutex g_weak_mutex;
    std::unordered_map<int64_t, FWeakObjectPtr> g_weak;
    int64_t g_weak_next = 1;

    int l_native_version(const Lua& lua)
    {
        lua.set_string(CORE_VERSION);
        lua.set_string(CORE_UE4SS_BUILD);
        return 2;
    }

    // <Core>_Ref(address): address is obj:GetAddress() of an object the caller holds right now.
    int l_ref(const Lua& lua)
    {
        require_game_thread(lua, g_fn_ref);
        const auto addr = arg_int(lua, g_fn_ref);
        auto* obj = reinterpret_cast<UObject*>(static_cast<uintptr_t>(addr));
        if (!obj) lua.throw_error(std::format("{}: null address", g_fn_ref));
        // The slot at the object's own index must point back at it, or the address is not a live UObject.
        const int32 index = obj->GetInternalIndex();
        auto* item = UObjectArray::IndexToObject(index);
        if (!item || item->GetUObject() != obj) lua.throw_error(std::format("{}: address is not a live UObject", g_fn_ref));
        int64_t handle{};
        {
            std::lock_guard guard{g_weak_mutex};
            if (g_weak.size() >= k_max_handles)
            {
                lua.throw_error(std::format("{}: too many live handles ({}); free some with {}", g_fn_ref, k_max_handles, g_fn_free));
            }
            handle = g_weak_next++;
            g_weak.emplace(handle, FWeakObjectPtr{obj});
        }
        lua.set_integer(handle);
        return 1;
    }

    // <Core>_Deref(handle): the object, or nil once it is gone, its slot reused, or the handle unknown.
    int l_deref(const Lua& lua)
    {
        require_game_thread(lua, g_fn_deref);
        const auto handle = arg_int(lua, g_fn_deref);
        UObject* obj{};
        {
            std::lock_guard guard{g_weak_mutex};
            auto it = g_weak.find(handle);
            if (it != g_weak.end()) obj = it->second.Get();
        }
        // auto_construct_object(nullptr) pushes an invalid wrapper, not nil; push a real nil instead.
        if (obj) LuaType::auto_construct_object(lua, obj);
        else lua.set_nil();
        return 1;
    }

    // <Core>_RefFree(handle): idempotent; touches no UObject, so any thread may call it.
    int l_ref_free(const Lua& lua)
    {
        const auto handle = arg_int(lua, g_fn_free);
        std::lock_guard guard{g_weak_mutex};
        g_weak.erase(handle);
        return 0;
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
        catch (...)
        {
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

        register_on_unreal_init([](CppUserModBase* self) { static_cast<CoreNative*>(self)->unreal_init(); });
        register_on_lua_start([](CppUserModBase*, CStringView, Lua& lua, Lua&, Lua&, Lua*) {
            // Globals live in the mod's main state, which its main, async and hook threads share. Every Lua mod
            // gets them, so dependents can call them from main.lua.
            lua.register_function(g_fn_version.c_str(), &l_native_version);
            lua.register_function(g_fn_ref.c_str(), &l_ref);
            lua.register_function(g_fn_deref.c_str(), &l_deref);
            lua.register_function(g_fn_free.c_str(), &l_ref_free);
        });
    }

    ~CoreNative() override
    {
        // Hot reload unloads this DLL: nothing may keep pointing into it.
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
