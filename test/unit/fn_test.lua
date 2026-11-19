-- Unit tests for core story 43 (core.fn), outside the game: list()'s parsing of <Core>_FnList lines (empty, one,
-- several, malformed lines skipped), runOriginal (suspends, resumes, returns f's results, resumes and re-raises after
-- an error), intercept's argument checks and handle handling, release, the error mapping, and the onCall dispatch
-- (applied counts, next-frame delivery, no delivery when the object is gone), with the natives and UE4SS stubbed.
-- The in-game proof is run.ps1 -Scenario intercept -Target vm and -Scenario bad-input.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/fn_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.18.0", floor = "0.1.0" } end
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
local function eq(got, want, name) ok(got == want, name, "got " .. tostring(got) .. ", want " .. tostring(want)) end
local function errOf(f, ...) local okC, e = pcall(f, ...) return not okC and tostring(e) or nil end

-- ---------------------------------------------------------------- stubbed natives
local N = { list = "", suspended = {}, calls = {}, offThread = false }
_G.Nucleus_Deref = function(h)
    if N.offThread then error("Nucleus_Deref refused: called off the game thread", 0) end
    return N.objects and N.objects[h] or nil
end
_G.Nucleus_FnList = function() return N.list end
_G.Nucleus_FnSuspend = function(id, on)
    N.calls[#N.calls + 1] = "suspend " .. tostring(id) .. " " .. tostring(on)
    if id == 99 then error("Nucleus_FnSuspend: no rule 99", 0) end
    N.suspended[id] = on
end
_G.Nucleus_FnRelease = function(id)
    if id == 7 then error("Nucleus_FnRelease: rule 7 belongs to OtherMod, not NucleusSkelTest", 0) end
    return id == 1
end
_G.Nucleus_FnIntercept = function(path, target, action, value)
    N.last = { path = path, target = target, action = action, value = value }
    if path == "bad" then error("Nucleus_FnIntercept: 'bad' is not on the allowlist", 0) end
    if path == "offthread" then error("Nucleus_FnIntercept refused: called off the game thread", 0) end
    return 5
end

local F = require("nucleus.fn")
local A = F.API

-- seams: handles, scheduling, hooks
local H = { next = 100, live = {}, freed = {} }
F._deps.ref = function(obj)
    if obj == "dead" then error("ref: expected a UObject (it has no GetAddress)", 0) end
    H.next = H.next + 1
    H.live[H.next] = obj
    return H.next
end
F._deps.deref = function(h) return H.live[h] end
F._deps.free = function(h) H.freed[#H.freed + 1] = h; H.live[h] = nil end
local Q = {}
F._deps.schedule = function(ms, cb) Q[#Q + 1] = cb return #Q end
local HOOKS = {}
F._deps.registerHook = function(path, cb) HOOKS[path] = cb return 1, 2 end
local IN_HOOK = false
F._deps.inHook = function() return IN_HOOK end
local DEP = 0
F._deps.callDependent = function(fn, ...) DEP = DEP + 1 return pcall(fn, ...) end
local function runQueue() local q = Q; Q = {}; for _, cb in ipairs(q) do cb() end end

-- ---------------------------------------------------------------- list()
local L1 = "id=1 mod=NucleusSkelTest fn=/Game/A.A_C:Click target=any action=skip seen=0 applied=0 suspended=false"
local L2 = "id=12 mod=NucleusSkelPeer fn=/Game/A.A_C:GetToolTipWidget target=EnemySlot_Button_C /Engine/Transient.GameEngine_0:Widget_1.EnemySlot_Button_C_3 action=replace seen=4 applied=3 suspended=true"
N.list = ""
local r = A.list()
eq(type(r), "table", "list: empty -> a table")
eq(#r, 0, "list: empty -> no rule")
N.list = L1
r = A.list()
eq(#r, 1, "list: one line -> one rule")
eq(r[1].id, 1, "list: id"); eq(math.type(r[1].id), "integer", "list: id is an integer")
eq(r[1].mod, "NucleusSkelTest", "list: mod"); eq(r[1].fn, "/Game/A.A_C:Click", "list: fn")
eq(r[1].target, "any", "list: target any"); eq(r[1].action, "skip", "list: action")
eq(r[1].seen, 0, "list: seen"); eq(r[1].applied, 0, "list: applied"); eq(r[1].suspended, false, "list: suspended false")
N.list = L1 .. "\n" .. L2
r = A.list()
eq(#r, 2, "list: two lines -> two rules")
eq(r[2].id, 12, "list: second id")
eq(r[2].target, "EnemySlot_Button_C /Engine/Transient.GameEngine_0:Widget_1.EnemySlot_Button_C_3", "list: a full name with a space as target")
eq(r[2].action, "replace", "list: replace"); eq(r[2].seen, 4, "list: seen 4"); eq(r[2].applied, 3, "list: applied 3")
eq(r[2].suspended, true, "list: suspended true")
N.list = table.concat({
    L1,
    "garbage",
    "id=x mod=M fn=/a target=any action=skip seen=0 applied=0 suspended=false",
    "id=2 mod=M fn=/a target=any action=drop seen=0 applied=0 suspended=false",
    "id=3 mod=M fn=/a target=any action=skip seen=0 applied=0 suspended=maybe",
    "id=4 mod=M fn=/a target=any action=skip seen=-1 applied=0 suspended=false",
    "",
    L2,
}, "\n")
r = A.list()
eq(#r, 2, "list: malformed lines are skipped (two good of eight)")
eq(r[1].id, 1, "list: first good line kept"); eq(r[2].id, 12, "list: last good line kept")
eq(#F._parse(nil), 0, "parse(nil) -> empty")
ok(errOf(A.list, 1):find("^fn%.list: expected 0 arguments, got 1") ~= nil, "list(1) raises fn.list: expected 0 arguments")

-- ---------------------------------------------------------------- runOriginal
N.calls = {}
local got = table.pack(A.runOriginal(3, function(a, b)
    ok(N.suspended[3] == true, "runOriginal: suspended while f runs")
    return a + b, "x"
end, 2, 5))
eq(got.n, 2, "runOriginal: f's results count"); eq(got[1], 7, "runOriginal: first result"); eq(got[2], "x", "runOriginal: second result")
eq(N.suspended[3], false, "runOriginal: resumed after f")
eq(table.concat(N.calls, ","), "suspend 3 true,suspend 3 false", "runOriginal: suspend then resume")
N.calls = {}
local e = errOf(A.runOriginal, 3, function() error("boom in f", 0) end)
eq(e, "boom in f", "runOriginal: f's error re-raised unchanged")
eq(N.suspended[3], false, "runOriginal: resumed after f raised")
eq(table.concat(N.calls, ","), "suspend 3 true,suspend 3 false", "runOriginal: resume follows an error")
local tbl = {}
e = select(2, pcall(A.runOriginal, 3, function() error(tbl) end))
ok(e == tbl, "runOriginal: a non-string error is re-raised as the same value")
eq(errOf(A.runOriginal, 99, function() end), "fn.runOriginal: no rule 99", "runOriginal: unknown rule -> the native's problem, mapped")
eq(errOf(A.runOriginal, "1", function() end), "fn.runOriginal: id must be an integer (one intercept returned), got '1'", "runOriginal: id type")
eq(errOf(A.runOriginal, 3, 5), "fn.runOriginal: f must be a function, got 5", "runOriginal: f type")

-- ---------------------------------------------------------------- intercept: arguments and handles
eq(errOf(A.intercept, nil), "fn.intercept: expected a table { fn, target, action, value, onCall }, got nil", "intercept(nil)")
eq(errOf(A.intercept, {}, 1), "fn.intercept: expected 1 argument (a table), got 2", "intercept(t, 1)")
eq(errOf(A.intercept, { fn = 1, action = "skip" }), "fn.intercept: fn must be a string (an allowlisted function path), got 1", "intercept fn number")
eq(errOf(A.intercept, { fn = "p", action = "skip", target = 5 }), "fn.intercept: target must be a UObject or nil (any instance), got 5", "intercept target number")
eq(errOf(A.intercept, { fn = "p", action = 2 }), "fn.intercept: action must be 'skip' or 'replace', got 2", "intercept action number")
eq(errOf(A.intercept, { fn = "p", action = "skip", value = {} }), "fn.intercept: value must be a UObject or nil, got table", "intercept value table")
eq(errOf(A.intercept, { fn = "p", action = "skip", onCall = 1 }), "fn.intercept: onCall must be a function or nil, got 1", "intercept onCall number")
eq(errOf(A.intercept, { fn = "p", action = "skip", mod = "Other" }), "fn.intercept: unknown key 'mod' (fn, target, action, value, onCall)", "intercept: no owner argument")
eq(errOf(A.intercept, { fn = "bad", action = "skip" }), "fn.intercept: 'bad' is not on the allowlist", "intercept: native error mapped")
eq(errOf(A.intercept, { fn = "offthread", action = "skip" }), "fn.intercept: refused: called off the game thread", "intercept: native refusal mapped")
N.offThread = true
eq(errOf(A.intercept, { fn = "p", action = "skip" }), "fn.intercept: called off the game thread", "intercept off the game thread (checked before any handle)")
eq(errOf(A.release, 1), "fn.release: called off the game thread", "release off the game thread")
N.offThread = false
-- handles: target and value become handles for the call and are freed after it, also when the native refuses
H.freed = {}
local function udata(tag) -- a userdata, as a UObject is (io.tmpfile: Lua 5.3 and 5.4 have no newproxy)
    local u = (newproxy and newproxy(true)) or io.tmpfile() -- a userdata in Lua 5.3/5.4 without newproxy
    return u, tag
end
local tu = udata("target"); local vu = udata("value")
local id = A.intercept{ fn = "p", target = tu, action = "replace", value = vu }
eq(id, 5, "intercept: returns the native's id")
eq(N.last.target, 101, "intercept: target passed as a handle"); eq(N.last.value, 102, "intercept: value passed as a handle")
eq(#H.freed, 2, "intercept: both handles freed after the call")
H.freed = {}
id = A.intercept{ fn = "p", action = "skip" }
eq(N.last.target, 0, "intercept: no target -> 0 (any instance)"); eq(N.last.value, nil, "intercept: no value -> nil")
eq(#H.freed, 0, "intercept: no handle made for nil target and value")
H.freed = {}
ok(errOf(A.intercept, { fn = "bad", target = tu, action = "skip" }) ~= nil, "intercept refused with a target")
eq(#H.freed, 1, "intercept: the target handle is freed when the native refuses")
eq(errOf(A.intercept, { fn = "p", target = "dead", action = "skip" }), "fn.intercept: target must be a UObject or nil (any instance), got 'dead'", "a string target is refused before ref")

-- ---------------------------------------------------------------- release
eq(A.release(1), true, "release(own) -> true")
F._S.rules[2] = { path = "/p", applied = 0 }
eq(A.release(2), false, "release(unknown) -> false")
eq(F._S.rules[2], nil, "release: a rule already gone (pruned) is forgotten by this state too")
eq(errOf(A.release, 7), "fn.release: rule 7 belongs to OtherMod, not NucleusSkelTest", "release(another mod's) raises, mapped")
eq(errOf(A.release, 1.5), "fn.release: id must be an integer (one intercept returned), got 1.5", "release(1.5)")
eq(errOf(A.release), "fn.release: id must be an integer (one intercept returned), got nil", "release()")

-- ---------------------------------------------------------------- onCall
HOOKS, Q, DEP = {}, {}, 0
local heard = {}
N.list = "id=5 mod=NucleusSkelTest fn=/Game/X.X_C:Click target=any action=skip seen=0 applied=0 suspended=false"
id = A.intercept{ fn = "/Game/X.X_C:Click", action = "skip", onCall = function(o) heard[#heard + 1] = o end }
ok(HOOKS["/Game/X.X_C:Click"] ~= nil, "onCall: a post-hook registered for the path")
local obj = io.tmpfile()
local ctx = { get = function() return obj end }
-- a call the rule applied to: applied went up
N.list = "id=5 mod=NucleusSkelTest fn=/Game/X.X_C:Click target=any action=skip seen=1 applied=1 suspended=false"
eq(HOOKS["/Game/X.X_C:Click"](ctx), nil, "onCall: the hook returns nothing")
eq(#heard, 0, "onCall: not inside the call")
eq(#Q, 1, "onCall: one delivery scheduled for the next frame")
runQueue()
eq(#heard, 1, "onCall: delivered once, next frame"); ok(heard[1] == obj, "onCall: with the object called on")
eq(DEP, 1, "onCall: through callDependent")
-- a call let through (runOriginal): applied didn't move
N.list = "id=5 mod=NucleusSkelTest fn=/Game/X.X_C:Click target=any action=skip seen=2 applied=1 suspended=false"
HOOKS["/Game/X.X_C:Click"](ctx)
eq(#Q, 0, "onCall: nothing scheduled for a call the rule didn't apply to")
-- the object is gone by the next frame: nothing delivered, the handle freed
N.list = "id=5 mod=NucleusSkelTest fn=/Game/X.X_C:Click target=any action=skip seen=3 applied=2 suspended=false"
H.freed = {}
HOOKS["/Game/X.X_C:Click"](ctx)
for h in pairs(H.live) do H.live[h] = nil end
runQueue()
eq(#heard, 1, "onCall: nothing delivered when the object is gone")
eq(#H.freed, 1, "onCall: the handle is freed after")
-- a throwing onCall is contained
N.list = "id=5 mod=NucleusSkelTest fn=/Game/X.X_C:Click target=any action=skip seen=4 applied=3 suspended=false"
F._S.rules[5].onCall = function() error("dependent bug") end
HOOKS["/Game/X.X_C:Click"](ctx)
ok(pcall(runQueue), "onCall: a throwing callback doesn't escape")
-- a second intercept on the same path doesn't register a second hook
local before = HOOKS["/Game/X.X_C:Click"]
A.intercept{ fn = "/Game/X.X_C:Click", action = "skip", onCall = function() end }
ok(HOOKS["/Game/X.X_C:Click"] == before, "onCall: at most one hook per path per state")
-- inside a hook: the registration waits for the next frame
IN_HOOK = true
Q = {}
A.intercept{ fn = "/Game/Y.Y_C:Click", action = "skip", onCall = function() end }
eq(HOOKS["/Game/Y.Y_C:Click"], nil, "onCall: no hook registered inside a hook")
eq(#Q, 1, "onCall: the registration is scheduled")
IN_HOOK = false
runQueue()
ok(HOOKS["/Game/Y.Y_C:Click"] ~= nil, "onCall: registered on the next frame")
-- a rule the native side dropped (its target gone; not in FnList) is forgotten at the next call on its path
Q = {}
F._S.rules[9] = { path = "/Game/X.X_C:Click", onCall = function() error("never") end, applied = 0 }
N.list = "id=5 mod=NucleusSkelTest fn=/Game/X.X_C:Click target=any action=skip seen=5 applied=3 suspended=false"
HOOKS["/Game/X.X_C:Click"](ctx)
eq(F._S.rules[9], nil, "onCall: a rule missing from FnList (dropped natively) is forgotten")
ok(F._S.rules[5] ~= nil, "onCall: a rule still in FnList is kept")
eq(#Q, 0, "onCall: nothing scheduled for the dropped rule")

print(string.format("fn_test: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
