-- core.restart (core story 45, Mod Manager story 8; README "Restart"): start the game again the way it was launched,
-- over core's natives <Core>_RestartMode and <Core>_RestartStart (native/src/restart.cpp). Runs in any Lua state
-- (a dependent's core.restart, or require("<core>.restart") directly); holds nothing. Never raises.
--
--   mode()  -> "steam" | "direct", or nil, reason
--              steam: a Steam install (Steam starts the game again, with the player's launch options); direct: a dev
--              copy (the same exe and command line). reason: "unsupported launch" (neither), "native part missing".
--   start() -> true, or nil, reason
--              Starts core's relaunch helper (Mods/<Core>/bin/<Core>Restart.exe), which waits for this game to exit
--              and then starts it again. It does not quit the game: the caller quits it (the game's QuitGame) right
--              after. At most one waiting helper at a time: a call while it waits gives nil, "already started"
--              (quitting still restarts); after it has exited, a call starts a new one. reason: "unsupported launch", "helper missing", "already
--              started", "command line too long", "start failed: <win32 code>", "native part missing", or
--              "error: <message>" when the native raised.
-- Arguments are ignored: nothing a caller passes reaches the natives (they take none).
local V = require((...):gsub("%.restart$", "") .. ".version")

local M = {}
local KEY_MODE, KEY_START = V.name .. "_RestartMode", V.name .. "_RestartStart"

-- The native is looked up on every call (never cached): a hot reload registers a new one.
local function call(key)
    local fn = _G[key]
    if type(fn) ~= "function" then return false, "native part missing" end
    local ok, a, b = pcall(fn)
    if not ok then return false, "error: " .. (tostring(a):match("^[^\n]*") or "?") end
    return true, a, b
end

function M.mode()
    local ok, m, why = call(KEY_MODE)
    if not ok then return nil, m end
    if m == "steam" or m == "direct" then return m end
    return nil, type(why) == "string" and why or "unsupported launch"
end

function M.start()
    local ok, r, why = call(KEY_START)
    if not ok then return nil, r end
    if r == true then return true end
    return nil, type(why) == "string" and why or "start failed: unknown"
end

return M
