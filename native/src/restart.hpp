// Restart now (Mod Manager story 8, core story 45): which way this game can be started again, and the relaunch helper
// <Core>Restart.exe (restart_helper.cpp) started from the game process. Names come from CORE_NAME. Definitions in
// restart.cpp; the rule itself in restart_mode.hpp. Mod Manager v2 story 3 (apply.cpp) starts the same helper in apply
// mode through the shared part below, and RestartStart then asks that helper to relaunch instead of starting another.
#pragma once

#include <cstdint>
#include <string>

#include "core_shared.hpp"

namespace core_stage
{
    struct Layout;
}

namespace core_native::restart
{
    extern const std::string g_fn_mode;  // <Core>_RestartMode
    extern const std::string g_fn_start; // <Core>_RestartStart

    // <Core>_RestartMode() -> "steam" | "direct", or nil, "unsupported launch"
    int l_mode(const Lua& lua);
    // <Core>_RestartStart() -> true, or nil, "unsupported launch" | "helper missing" | "already started" |
    // "command line too long" | "start failed: <win32 code>". Starts the helper unless one is still waiting; never quits.
    // While this session's apply helper waits it writes <Core>Data\relaunch.txt (game PID, helper PID) and answers true.
    int l_start(const Lua& lua);

    // ---------------------------------------------------------------- shared with apply.cpp (all under lock())
    // Locks the helper state (both helpers) for the scope of the returned object.
    struct Guard
    {
        Guard();
        ~Guard();
        Guard(const Guard&) = delete;
        Guard& operator=(const Guard&) = delete;
    };
    // Whether this session's apply helper is still waiting (a zero wait on its SYNCHRONIZE handle); a helper that has
    // exited is forgotten. pid set when it waits.
    bool apply_waiting(uint32_t* pid);
    // Starts the helper in apply mode (--apply --mode steam|direct|none). "" with *pid on success, else the reason
    // ("helper missing", "command line too long", "start failed: <code>"). Remembers it as this session's apply helper.
    std::string start_apply_helper(uint32_t* pid);
    // The install layout from this DLL's own path (Mods\<Core>\dlls\main.dll). false when it doesn't match.
    bool own_layout(core_stage::Layout& out);
} // namespace core_native::restart
