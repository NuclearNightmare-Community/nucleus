// Core's native part (docs: _bmad-output/specs/spec-core-v0/api-contract.md, "C++ natives").
//
// Registers <Core>_NativeVersion, <Core>_ClockMicros, <Core>_Ref, <Core>_Deref, <Core>_RefFree and the objectives natives
// (objectives.cpp: <Core>_SetObjectives, <Core>_DescribeObjectives, <Core>_SetTraitorTaskState) and the function
// interception natives (intercept.cpp, core story 43: <Core>_FnIntercept, <Core>_FnRelease, <Core>_FnSuspend,
// <Core>_FnList) and the restart natives (restart.cpp, core story 45 / Mod Manager story 8: <Core>_RestartMode,
// <Core>_RestartStart, which start the relaunch helper bin/<Core>Restart.exe) and the catalog natives (catalog.cpp, Mod Manager
// v2 story 2: <Core>_CatalogRefresh, <Core>_CatalogDownload, <Core>_CatalogPoll, run on a background worker) into every Lua
// mod's state in on_lua_start, before that mod's main.lua runs. <Core> is CORE_NAME (core_config.hpp, generated from mod.json
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
//     pointers only (scan_object_array, newest slots first), and builds the weak pointer from the slot index it found.
//   - Reads of engine memory (the object array, weak pointer resolution) run under SEH (__try/__except) as a last
//     resort; a fault is logged with context and becomes a Lua error, never a crash.
//   Shared parts (the guard, the checks, the GUObjectArray scan) are in core_shared.hpp/core_shared.cpp.

#include <excpt.h>

#include <chrono>
#include <cstdint>
#include <format>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

#include <Mod/CppUserModBase.hpp>
#include <Unreal/FWeakObjectPtr.hpp>
#include <Unreal/UObjectArray.hpp>

#include "catalog.hpp"
#include "core_shared.hpp"
#include "core_config.hpp"
#include "intercept.hpp"
#include "objectives.hpp"
#include "restart.hpp"

// QueryPerformanceCounter/Frequency (<Core>_ClockMicros). After the UE4SS headers, so their own Windows setup wins.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>

using namespace RC;
using namespace RC::Unreal;
using namespace core_native;

namespace
{
    const std::string g_fn_version = std::string{CORE_NAME} + "_NativeVersion";
    const std::string g_fn_ref = std::string{CORE_NAME} + "_Ref";
    const std::string g_fn_deref = std::string{CORE_NAME} + "_Deref";
    const std::string g_fn_free = std::string{CORE_NAME} + "_RefFree";
    const std::string g_fn_clock = std::string{CORE_NAME} + "_ClockMicros";

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

    // <Core>_ClockMicros(): microseconds from QueryPerformanceCounter, a monotonic clock. The epoch is arbitrary
    // (counts since boot on current Windows); only differences between two calls mean anything. Touches no UObject,
    // so any thread may call it, also during main.lua. Normal path: no allocation, no lock, no logging.
    // The frequency is fixed at boot; read it once, when the DLL loads.
    const int64_t g_qpc_freq = [] {
        LARGE_INTEGER f{};
        return QueryPerformanceFrequency(&f) && f.QuadPart > 0 ? static_cast<int64_t>(f.QuadPart) : int64_t{0};
    }();

    int l_clock_micros(const Lua& lua)
    {
        return guarded(lua, g_fn_clock, [&] {
            require_args(lua, g_fn_clock, 0, "");
            if (g_qpc_freq <= 0) throw std::runtime_error("QueryPerformanceFrequency is unavailable");
            LARGE_INTEGER c{};
            QueryPerformanceCounter(&c);
            const int64_t ticks = c.QuadPart;
            // Whole seconds and remainder separately: ticks * 1'000'000 alone would overflow after ~10 days at 10 MHz.
            const int64_t secs = ticks / g_qpc_freq;
            const int64_t rem = ticks % g_qpc_freq;
            Result r;
            r.kind = Result::Kind::Integer;
            r.integer = secs * 1'000'000 + rem * 1'000'000 / g_qpc_freq;
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
                logf("REF_COST calls={} last={:.3f} ms avg={:.3f} ms max={:.3f} ms slots={} (scan of {} of {} slots, newest first)", calls, ns / 1e6,
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
} // namespace

// Function interception (intercept.cpp) takes its target and value objects as handles from this table.
bool core_native::handle_weak(int64_t handle, FWeakObjectPtr* out)
{
    std::lock_guard guard{g_weak_mutex};
    auto it = g_weak.find(handle);
    if (it == g_weak.end()) return false;
    *out = it->second;
    return true;
}

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
                lua.register_function(g_fn_clock.c_str(), &l_clock_micros);
                lua.register_function(g_fn_ref.c_str(), &l_ref);
                lua.register_function(g_fn_deref.c_str(), &l_deref);
                lua.register_function(g_fn_free.c_str(), &l_ref_free);
                lua.register_function(objectives::g_fn_set.c_str(), &objectives::l_set_objectives);
                lua.register_function(objectives::g_fn_describe.c_str(), &objectives::l_describe_objectives);
                lua.register_function(objectives::g_fn_traitor.c_str(), &objectives::l_set_traitor_task_state);
                lua.register_function(intercept::g_fn_intercept.c_str(), &intercept::l_intercept);
                lua.register_function(intercept::g_fn_release.c_str(), &intercept::l_release);
                lua.register_function(intercept::g_fn_suspend.c_str(), &intercept::l_suspend);
                lua.register_function(intercept::g_fn_list.c_str(), &intercept::l_list);
                lua.register_function(restart::g_fn_mode.c_str(), &restart::l_mode);
                lua.register_function(restart::g_fn_start.c_str(), &restart::l_start);
                lua.register_function(catalog_natives::g_fn_refresh.c_str(), &catalog_natives::l_refresh);
                lua.register_function(catalog_natives::g_fn_download.c_str(), &catalog_natives::l_download);
                lua.register_function(catalog_natives::g_fn_poll.c_str(), &catalog_natives::l_poll);
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
        // Core story 43: a Lua mod's interception rules go when its Lua stops (UninstallMod, RestartMod, hot reload).
        register_on_lua_stop([](CppUserModBase*, CStringView mod_name, Lua&, Lua&, Lua&, Lua*) {
            try
            {
                const std::string mod = mod_name.data ? to_string(StringType{mod_name.data, mod_name.size}) : std::string{};
                const size_t n = intercept::release_mod(mod);
                if (n > 0) logf("intercept: released {} rule(s) of {} (Lua stopped)", n, mod);
            }
            catch (const std::exception& e)
            {
                logf("ERROR releasing a stopped Lua mod's intercepts: {}", e.what());
            }
            catch (...)
            {
                logf("ERROR releasing a stopped Lua mod's intercepts: unknown C++ exception");
            }
        });
    }

    ~CoreNative() override
    {
        // Hot reload unloads this DLL: nothing may keep pointing into it. The callbacks go first (UnregisterCallback
        // waits for a running one to finish), then the rules and their roots.
        try
        {
            for (auto id : m_hooks)
            {
                Hook::UnregisterCallback(id);
            }
            const size_t intercepts = intercept::release_all();
            // The catalog worker: its request in flight aborted, then joined (it runs this DLL's code).
            catalog_natives::shutdown();
            size_t handles{};
            {
                std::lock_guard guard{g_weak_mutex};
                handles = g_weak.size();
                g_weak.clear();
            }
            logf("unloading: unregistered {} hooks, dropped {} handles, released {} intercepts", m_hooks.size(), handles, intercepts);
        }
        catch (...)
        {
            logf("ERROR while unloading (unknown exception)");
        }
    }

    void unreal_init()
    {
        const auto owner = ensure_str(std::string{CORE_NAME});
        m_hooks.push_back(Hook::RegisterEngineTickPreCallback(&engine_tick_pre, {true, true, owner, STR("engine_tick_pre")}));
        // Core story 43: function interception. One pre-callback for every Blueprint function call (non-readonly: it
        // may prevent the original), registered once and unregistered only in the destructor (never from inside a
        // callback: UnregisterCallback deadlocks there). With no rule it returns after one atomic load. A separate
        // every-tick callback clears suspensions (engine_tick_pre runs once only).
        m_hooks.push_back(Hook::RegisterProcessLocalScriptFunctionPreCallback(&intercept::plsf_pre, {false, false, owner, STR("intercept_plsf_pre")}));
        m_hooks.push_back(Hook::RegisterEngineTickPreCallback(&intercept::tick_pre, {false, true, owner, STR("intercept_tick_pre")}));
        logf("intercept: callback registered ({} allowlisted functions)", intercept::g_allow_count);
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
