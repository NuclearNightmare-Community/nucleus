// Function interception (core story 43, CAP-13): a dependent installs a rule (a function on the allowlist, one target
// object or any instance, skip or replace with a value) as data; one ProcessLocalScriptFunction pre-callback applies the
// rules on the game thread and never calls Lua. Names come from CORE_NAME. Definitions in intercept.cpp.
#pragma once

#include <cstdint>
#include <string>

#include <Unreal/FWeakObjectPtr.hpp>

#include "core_shared.hpp"

namespace core_native
{
    // dllmain.cpp's weak handle table (<Core>_Ref): the weak pointer behind a handle, or false for an unknown one.
    bool handle_weak(int64_t handle, RC::Unreal::FWeakObjectPtr* out);
} // namespace core_native

namespace core_native::intercept
{
    extern const std::string g_fn_intercept; // <Core>_FnIntercept
    extern const std::string g_fn_release;   // <Core>_FnRelease
    extern const std::string g_fn_suspend;   // <Core>_FnSuspend
    extern const std::string g_fn_list;      // <Core>_FnList

    int l_intercept(const Lua& lua);
    int l_release(const Lua& lua);
    int l_suspend(const Lua& lua);
    int l_list(const Lua& lua);

    // The ProcessLocalScriptFunction pre-callback (registered once, non-readonly). Catches everything.
    void plsf_pre(RC::Unreal::Hook::TCallbackIterationData<void>& data, RC::Unreal::UObject* context, RC::Unreal::FFrame& stack, void* result);
    // Engine tick pre-callback (every tick): clears every suspension. Catches everything.
    void tick_pre(RC::Unreal::Hook::TCallbackIterationData<void>&, RC::Unreal::UEngine*, float, bool);

    // Releases every rule of one mod (and lets its replacement go); returns how many. Never throws.
    size_t release_mod(const std::string& mod);
    // Releases every rule (and lets the replacements go); returns how many. Never throws.
    size_t release_all();
} // namespace core_native::intercept
