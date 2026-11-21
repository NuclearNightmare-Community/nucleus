-- Unit tests for Mod Manager v2 story 3 (core.apply, lua/pkg/apply.lua), outside the game: what status(), start() and
-- ack() return for every answer of the natives (each staged and result state, nil + reason, a raised error, a missing
-- native, garbage), that they never raise, pass only a checked txn on, and look the native up on every call.
-- The natives and the helper: native/test/apply.tests.ps1 and run.ps1 -Scenario bad-input (in game).
-- Run from the repo root with any standalone Lua 5.3 or 5.4 (MiKTeX's texlua is one):  lua test/unit/apply_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.24.0", floor = "0.1.0" } end
table.insert(package.searchers, 2, function(name)
    local rest = name:match("^nucleus%.(.+)$")
    if not rest then return nil end
    local path = ROOT .. "/lua/pkg/" .. rest:gsub("%.", "/") .. ".lua"
    local f = io.open(path, "r")
    if not f then return "\n\tno file " .. path end
    f:close()
    return assert(loadfile(path)), path
end)

local pass, fail = 0, 0
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")) end
end
local function same(name, want, ...)
    local got = table.pack(...)
    local okS = got.n == want.n
    for i = 1, math.max(got.n, want.n) do if got[i] ~= want[i] then okS = false end end
    local parts = {}
    for i = 1, got.n do parts[i] = tostring(got[i]) end
    ok(okS, name, "got (" .. table.concat(parts, ", ") .. ")")
end
local function P(...) return table.pack(...) end

local A = require("nucleus.apply")
ok(type(A.status) == "function" and type(A.start) == "function" and type(A.ack) == "function", "the module has status, start and ack")

local TXN = "0123456789abcdef0123456789abcdef"

-- No natives (an old or missing native part).
_G.Nucleus_ApplyStatus, _G.Nucleus_ApplyStart, _G.Nucleus_ApplyAck = nil, nil, nil
same("status: native part missing", P(nil, "native part missing"), A.status())
same("start: native part missing", P(nil, "native part missing"), A.start())
same("ack: native part missing", P(nil, "native part missing"), A.ack(TXN))

-- status()
local args
_G.Nucleus_ApplyStatus = function(...) args = table.pack(...) return "none", "none", "", "", "", "0", "0" end
local s = A.status("ignored", 1)
ok(args.n == 0, "status: no argument reaches the native", args.n)
ok(type(s) == "table" and s.staged == "none" and s.result == "none" and s.txn == "" and s.reason == "" and s.path == "" and s.attempts == 0 and s.changes == 0,
    "status: none none")
for _, st in ipairs({ "pending", "waiting", "applying", "interrupted" }) do
    _G.Nucleus_ApplyStatus = function() return st, "none", TXN, "", "", "0", "3" end
    s = A.status()
    ok(s and s.staged == st and s.txn == TXN and s.changes == 3, "status: staged " .. st)
end
_G.Nucleus_ApplyStatus = function() return "pending", "failed", TXN, "locked", "NuclearNightmare\\Content\\Paks\\A_P.pak", "2", "1" end
s = A.status()
ok(s and s.result == "failed" and s.reason == "locked" and s.path == "NuclearNightmare\\Content\\Paks\\A_P.pak" and s.attempts == 2 and math.type(s.attempts) == "integer",
    "status: a failed result with its reason, path and attempts")
for _, r in ipairs({ "applied", "discarded" }) do
    _G.Nucleus_ApplyStatus = function() return "none", r, TXN, "", "", "1", "0" end
    s = A.status()
    ok(s and s.result == r, "status: result " .. r)
end
local bad = {
    { "an unknown staged state", { "later", "none", "", "", "", "0", "0" } },
    { "an unknown result", { "none", "maybe", "", "", "", "0", "0" } },
    { "attempts not decimal", { "none", "none", "", "", "", "x", "0" } },
    { "changes negative", { "none", "none", "", "", "", "0", "-1" } },
    { "a txn that isn't hex", { "pending", "none", "ZZ", "", "", "0", "1" } },
    { "a missing value", { "none", "none", "", "", "" } },
    { "a non-string reason", { "none", "none", "", {}, "", "0", "0" } },
    { "an oversized path", { "none", "failed", TXN, "locked", string.rep("a", 2000), "1", "1" } },
}
for _, b in ipairs(bad) do
    _G.Nucleus_ApplyStatus = function() return table.unpack(b[2], 1, 7) end
    same("status: " .. b[1] .. " is a bad answer", P(nil, "bad answer"), A.status())
end
_G.Nucleus_ApplyStatus = function() error("Nucleus_ApplyStatus: internal error: boom\nmore", 0) end
same("status: a raised error is a reason, first line only", P(nil, "error: Nucleus_ApplyStatus: internal error: boom"), A.status())
_G.Nucleus_ApplyStatus = "not a function"
same("status: a non-function global is missing", P(nil, "native part missing"), A.status())

-- start()
local n = 0
_G.Nucleus_ApplyStart = function(...) n = n + 1; args = table.pack(...) if n == 1 then return true end return nil, "already started" end
same("start: true", P(true), A.start({}, "x"))
ok(args.n == 0, "start: no argument reaches the native", args.n)
same("start: already started", P(nil, "already started"), A.start())
for _, why in ipairs({ "nothing staged", "applying", "helper missing", "command line too long", "start failed: 5" }) do
    _G.Nucleus_ApplyStart = function() return nil, why end
    same("start: " .. why, P(nil, why), A.start())
end
_G.Nucleus_ApplyStart = function() return 1 end
same("start: anything but true is a failure", P(nil, "start failed: unknown"), A.start())
_G.Nucleus_ApplyStart = function() error({}) end
ok(select("#", A.start()) == 2 and A.start() == nil, "start: a table error never raises")

-- ack(txn)
local seen
_G.Nucleus_ApplyAck = function(...) seen = table.pack(...) return true end
same("ack: true", P(true), A.ack(TXN))
ok(seen.n == 1 and seen[1] == TXN, "ack: exactly the txn reaches the native")
seen = nil
for _, b in ipairs({ { "nil", nil }, { "a number", 5 }, { "upper case", TXN:upper() }, { "31 digits", TXN:sub(2) }, { "33 digits", TXN .. "0" },
    { "a table", {} }, { "not hex", ("g"):rep(32) } }) do
    same("ack: " .. b[1] .. " is a bad txn", P(nil, "bad txn"), A.ack(b[2]))
end
ok(seen == nil, "ack: a bad txn never reaches the native")
for _, why in ipairs({ "no result", "txn mismatch" }) do
    _G.Nucleus_ApplyAck = function() return nil, why end
    same("ack: " .. why, P(nil, why), A.ack(TXN))
end
_G.Nucleus_ApplyAck = function() error("Nucleus_ApplyAck: argument 1 (txn) must be 32 lowercase hex digits", 0) end
same("ack: a raised error is a reason", P(nil, "error: Nucleus_ApplyAck: argument 1 (txn) must be 32 lowercase hex digits"), A.ack(TXN))
_G.Nucleus_ApplyAck = function() return true end
same("ack: the current native is called", P(true), A.ack(TXN))

print(string.format("apply_test: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
