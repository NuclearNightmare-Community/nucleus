-- core.apply (Mod Manager v2 story 3; README "Staged changes"): a change staged while the game runs (files of a running
-- game can't be replaced) is applied by core's relaunch helper once the game has exited, however it exits. This module
-- only reads the status, starts the helper and acknowledges a result, over core's natives <Core>_ApplyStatus,
-- <Core>_ApplyStart and <Core>_ApplyAck (native/src/apply.cpp). It never stages anything: stories 5-7 do that in C++.
-- Runs in any Lua state (a dependent's core.apply, or require("<core>.apply") directly); holds nothing. Never raises.
--
--   status() -> { staged, result, txn, reason, path, attempts, changes }, or nil, reason
--       staged   "none" | "pending" (staged, no helper waiting) | "waiting" (this session's helper waits for the game
--                to exit) | "applying" | "interrupted" (an apply was cut short; the next helper puts it back first)
--       result   "none" | "applied" | "failed" (the change stays staged and is retried at the next exit) |
--                "discarded" (dropped: a bad plan, a staged file that doesn't match, or the third failure)
--       txn      the result's change id (32 lowercase hex), else the staged one's, else ""
--       reason   the result's reason ("locked", "io-error", "target-changed", "staged-file-mismatch", "bad-plan",
--                "game-running", "rollback-incomplete") or ""
--       path     the file it concerns, relative to the game folder, or ""
--       attempts, changes: integers (failed attempts of that change; operations in the staged change)
--       reason (nil case): "native part missing", "error: <message>", "bad answer"
--   start()  -> true, or nil, reason
--       Starts the helper in apply mode: it waits (no time limit) for this game to exit, then applies. reason:
--       "nothing staged", "already started", "applying", "helper missing", "command line too long",
--       "start failed: <code>", "native part missing", "error: <message>".
--   ack(txn) -> true, or nil, reason
--       The result was shown: forget it. reason: "no result", "txn mismatch", "delete failed: <code>", "bad txn" (not 32 lowercase hex: never
--       passed on), "native part missing", "error: <message>".
local V = require((...):gsub("%.apply$", "") .. ".version")

local M = {}
local KEY_STATUS, KEY_START, KEY_ACK = V.name .. "_ApplyStatus", V.name .. "_ApplyStart", V.name .. "_ApplyAck"

local STAGED = { none = true, pending = true, waiting = true, applying = true, interrupted = true }
local RESULT = { none = true, applied = true, failed = true, discarded = true }
local MAX_TEXT = 1024

-- The native is looked up on every call (never cached): a hot reload registers a new one.
local function call(key, ...)
    local fn = _G[key]
    if type(fn) ~= "function" then return false, "native part missing" end
    local res = table.pack(pcall(fn, ...))
    if not res[1] then return false, "error: " .. (tostring(res[2]):match("^[^\n]*") or "?") end
    return true, table.unpack(res, 2, res.n)
end

local function count(s)
    if type(s) ~= "string" or not s:match("^%d+$") or #s > 9 then return nil end
    return math.tointeger(tonumber(s))
end
local function text(s)
    return type(s) == "string" and #s <= MAX_TEXT and s or nil
end

function M.status()
    local ok, staged, result, txn, reason, path, attempts, changes = call(KEY_STATUS)
    if not ok then return nil, staged end
    local t = { staged = staged, result = result, txn = text(txn), reason = text(reason), path = text(path), attempts = count(attempts), changes = count(changes) }
    if not (STAGED[staged] and RESULT[result] and t.txn and t.reason and t.path and t.attempts and t.changes) then return nil, "bad answer" end
    if t.txn ~= "" and not t.txn:match("^[0-9a-f]+$") then return nil, "bad answer" end
    return t
end

function M.start()
    local ok, r, why = call(KEY_START)
    if not ok then return nil, r end
    if r == true then return true end
    return nil, type(why) == "string" and why or "start failed: unknown"
end

function M.ack(txn)
    if type(txn) ~= "string" or #txn ~= 32 or not txn:match("^[0-9a-f]+$") then return nil, "bad txn" end
    local ok, r, why = call(KEY_ACK, txn)
    if not ok then return nil, r end
    if r == true then return true end
    return nil, type(why) == "string" and why or "no result"
end

return M
