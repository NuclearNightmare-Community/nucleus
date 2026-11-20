// Restart now (Mod Manager story 8, core story 45): which way this game can be started again, and the relaunch helper
// <Core>Restart.exe (restart_helper.cpp) started from the game process. Names come from CORE_NAME. Definitions in
// restart.cpp; the rule itself in restart_mode.hpp.
#pragma once

#include <string>

#include "core_shared.hpp"

namespace core_native::restart
{
    extern const std::string g_fn_mode;  // <Core>_RestartMode
    extern const std::string g_fn_start; // <Core>_RestartStart

    // <Core>_RestartMode() -> "steam" | "direct", or nil, "unsupported launch"
    int l_mode(const Lua& lua);
    // <Core>_RestartStart() -> true, or nil, "unsupported launch" | "helper missing" | "already started" |
    // "command line too long" | "start failed: <win32 code>". Starts the helper at most once per session; never quits.
    int l_start(const Lua& lua);
} // namespace core_native::restart
