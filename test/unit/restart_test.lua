-- Unit tests for core story 45 (core.restart, lua/pkg/restart.lua), outside the game: what mode() and start() return
-- for every answer of the natives (steam, direct, nil + reason, a raised error, a missing native, garbage), that they
-- never raise, pass no argument on, and look the native up on every call (a hot reload registers a new one).
-- The natives themselves: native/test/restart-helper.tests.ps1 (the helper) and run.ps1 -Scenario bad-input (in game).
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/restart_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.20.0", floor = "0.1.0" } end
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

local R = require("nucleus.restart")
ok(type(R.mode) == "function" and type(R.start) == "function", "the module has mode and start")

-- No natives (an old or missing native part).
_G.Nucleus_RestartMode, _G.Nucleus_RestartStart = nil, nil
same("mode: native part missing", P(nil, "native part missing"), R.mode())
same("start: native part missing", P(nil, "native part missing"), R.start())

-- mode()
local args
_G.Nucleus_RestartMode = function(...) args = table.pack(...) return "direct" end
same("mode: direct", P("direct"), R.mode("ignored", 1, {}))
ok(args.n == 0, "mode: no argument reaches the native", args.n)
_G.Nucleus_RestartMode = function() return "steam" end
same("mode: steam", P("steam"), R.mode())
_G.Nucleus_RestartMode = function() return nil, "unsupported launch" end
same("mode: unsupported launch", P(nil, "unsupported launch"), R.mode())
_G.Nucleus_RestartMode = function() return "elsewhere" end
same("mode: an unknown answer is unsupported", P(nil, "unsupported launch"), R.mode())
_G.Nucleus_RestartMode = function() return nil end
same("mode: a bare nil is unsupported", P(nil, "unsupported launch"), R.mode())
_G.Nucleus_RestartMode = function() error("Nucleus_RestartMode: internal error: boom\nmore", 0) end
same("mode: a raised error is a reason, first line only", P(nil, "error: Nucleus_RestartMode: internal error: boom"), R.mode())
_G.Nucleus_RestartMode = "not a function"
same("mode: a non-function global is missing", P(nil, "native part missing"), R.mode())

-- start()
local n = 0
_G.Nucleus_RestartStart = function(...) n = n + 1; args = table.pack(...) if n == 1 then return true end return nil, "already started" end
same("start: true", P(true), R.start({}, "x"))
ok(args.n == 0, "start: no argument reaches the native", args.n)
same("start: already started", P(nil, "already started"), R.start())
for _, why in ipairs({ "unsupported launch", "helper missing", "command line too long", "start failed: 5" }) do
    _G.Nucleus_RestartStart = function() return nil, why end
    same("start: " .. why, P(nil, why), R.start())
end
_G.Nucleus_RestartStart = function() return 1 end
same("start: anything but true is a failure", P(nil, "start failed: unknown"), R.start())
_G.Nucleus_RestartStart = function() error({}) end
ok(select("#", R.start()) == 2 and R.start() == nil, "start: a table error never raises")
-- looked up on every call
_G.Nucleus_RestartStart = function() return true end
same("start: the current native is called", P(true), R.start())

print(string.format("restart_test: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
