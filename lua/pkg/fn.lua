-- core.fn (core story 43, CAP-13): cancel or replace a game function, over core's native function interception
-- (native/src/intercept.cpp; README "Function interception"). Runs in the dependent's own Lua state; each mod has its
-- own copy. Holds no UObject: target and value become weak handles for the duration of one native call, and the
-- object an onCall hears about travels to the next frame as a handle.
--
--   intercept{ fn = <allowlisted path>, target = <UObject|nil>, action = "skip"|"replace", value = <UObject|nil>,
--              onCall = <function(obj)|nil> } -> id
--       A rule on one target object (nil: any instance). skip: the game's function doesn't run (a function that returns
--       an object returns nil). replace: it doesn't run and returns value. The same mod and the same (fn, target)
--       replace that mod's rule and keep its id. onCall(obj) runs on the next frame after each call the rule applied
--       to (not after a call runOriginal let through), under pcall, with the object called on (never if it is gone).
--   release(id) -> boolean      true: released; false: no such rule. Another mod's rule raises.
--   runOriginal(id, f, ...)     suspends the rule, calls f(...) under pcall, resumes it, then returns f's results or
--                               raises f's error again. The game's function runs for every call f makes.
--   list() -> { { id, mod, fn, target, action, seen, applied, suspended } ... }   every mod's rules
-- Errors are raised as "fn.<op>: <problem>". intercept, release and runOriginal: game thread only; list: any thread
-- (<Core>_FnList touches no UObject).
--
-- onCall: one RegisterHook post-hook per function path per Lua state, registered at most once. The hook returns
-- nothing, so it never overwrites the result. It acts only while this state owns a rule on that function whose
-- applied count went up during the call (read from <Core>_FnList), so it stays silent for other mods' rules and for
-- calls let through. Inside a hook or a dependent callback (story 37) no hook is registered: that waits for the next
-- game-thread frame.
local BASE = (...):gsub("%.fn$", "")
local V = require(BASE .. ".version")
local refm = require(BASE .. ".ref")

local NAME = V.name
local F = {}
local API = {}
F.API = API

-- Seams (the unit tests replace them): hook registration, next-frame scheduling, the dependent-callback guard, and
-- "inside a hook" (core.ui's flag when the UI helpers are loaded).
local function uiCommon()
    local ok, C = pcall(require, BASE .. ".ui.common")
    return ok and C or nil
end
F._deps = {
    registerHook = function(path, cb) return RegisterHook(path, cb) end,
    schedule = function(ms, cb) return ExecuteInGameThreadWithDelay(ms, cb) end,
    inHook = function()
        local okX, X = pcall(require, BASE .. ".ui.text")
        if okX and type(X) == "table" and type(X._inHook) == "function" then return X._inHook() == true end
        local C = uiCommon()
        return C ~= nil and (C.inDispatch or 0) > 0
    end,
    callDependent = function(fn, ...)
        local C = uiCommon()
        if C and type(C.callDependent) == "function" then return C.callDependent(fn, ...) end
        return pcall(fn, ...)
    end,
    ref = refm.ref, deref = refm.deref, free = refm.free,
}

local S = {
    rules = {},   -- id -> { path, onCall, applied } (this state's own rules)
    hooked = {},  -- path -> true once its post-hook is registered
    pending = {}, -- path -> true while its registration waits for the next frame
    log = nil,
}

local PROBE = (1 << 53) - 1 -- a handle never issued: <Core>_Deref refuses it off the game thread, returns nil on it

local function native(suffix)
    local fn = _G[NAME .. suffix]
    if type(fn) ~= "function" then error(NAME .. "'s native part is not loaded (" .. NAME .. suffix .. " missing)", 0) end
    return fn
end

local function firstLine(e) return (tostring(e):match("^[^\n]*")) end

local function describe(v)
    local t = type(v)
    if t == "string" then
        local s = v:sub(1, 32):gsub("[^%w%p ]", "?")
        return string.format("'%s'%s", s, #v > 32 and "..." or "")
    end
    if t == "number" then return v ~= v and "NaN" or tostring(v) end
    return t
end

local function fail(op, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    error("fn." .. op .. ": " .. (ok and msg or tostring(fmt)), 0)
end

-- A native's error as "fn.<op>: <problem>": the native's own "<Core>_<Native>: " prefix (or "<Core>_<Native> " before
-- "refused: ...") is dropped, so the problem reads the same from Lua and from the native.
local function rethrow(op, suffix, err)
    local msg = firstLine(err)
    local full = NAME .. suffix
    local at = msg:find(full, 1, true)
    if at then
        local rest = msg:sub(at + #full)
        if rest:sub(1, 2) == ": " then msg = rest:sub(3)
        elseif rest:sub(1, 1) == " " then msg = rest:sub(2) end
    end
    error("fn." .. op .. ": " .. msg, 0)
end

local function offGameThread()
    local ok, err = pcall(native("_Deref"), PROBE)
    return not ok and tostring(err):find("off the game thread", 1, true) ~= nil
end

local function enter(op)
    if offGameThread() then fail(op, "called off the game thread") end
end

-- ---------------------------------------------------------------- list

local LINE = "^id=(%d+) mod=(.-) fn=(%S+) target=(.-) action=(%a+) seen=(%d+) applied=(%d+) suspended=(%a+)$"

-- parse(text) -> list of rule tables; a line that doesn't match (or holds an impossible value) is skipped.
function F._parse(text)
    local out = {}
    if type(text) ~= "string" then return out end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local id, mod, fn, target, action, seen, applied, susp = line:match(LINE)
        if id and (action == "skip" or action == "replace") and (susp == "true" or susp == "false") and mod ~= "" and target ~= "" then
            out[#out + 1] = {
                id = math.tointeger(tonumber(id)), mod = mod, fn = fn, target = target, action = action,
                seen = math.tointeger(tonumber(seen)), applied = math.tointeger(tonumber(applied)), suspended = susp == "true",
            }
        end
    end
    return out
end

local function rawList()
    return F._parse(native("_FnList")())
end

function API.list(...)
    if select("#", ...) ~= 0 then fail("list", "expected 0 arguments, got %d", select("#", ...)) end
    local ok, r = pcall(rawList)
    if not ok then rethrow("list", "_FnList", r) end
    return r
end

local function appliedOf(id)
    for _, r in ipairs(rawList()) do
        if r.id == id then return r.applied end
    end
    return nil
end

-- ---------------------------------------------------------------- onCall

-- Runs inside the game's call (a UE4SS post-hook): no UObject is kept; the object goes to the next frame as a handle.
local function dispatch(path, ctx)
    local mine
    for id, r in pairs(S.rules) do
        if r.path == path and r.onCall then mine = mine or {}; mine[#mine + 1] = id end
    end
    if not mine then return end
    local now = {}
    for _, r in ipairs(rawList()) do now[r.id] = r.applied end
    local fire
    for _, id in ipairs(mine) do
        local r = S.rules[id]
        local a = now[id]
        if a and r.applied and a > r.applied then fire = fire or {}; fire[#fire + 1] = r.onCall end
        if a then r.applied = a else S.rules[id] = nil end -- not in FnList: dropped with its target or function
    end
    if not fire then return end
    local obj = ctx:get()
    local h = F._deps.ref(obj)
    local okS, errS = pcall(F._deps.schedule, 1, function()
        local okD, o = pcall(F._deps.deref, h)
        if okD and o ~= nil then
            for _, cb in ipairs(fire) do
                local okC, errC = F._deps.callDependent(cb, o)
                if not okC and S.log then S.log.warn("fn onCall threw: %s", firstLine(errC)) end
            end
        end
        pcall(F._deps.free, h)
    end)
    if not okS then
        pcall(F._deps.free, h)
        if S.log then S.log.warn("fn onCall could not be scheduled: %s", firstLine(errS)) end
    end
end

local function hookFor(path)
    return function(ctx)
        local ok, err = pcall(dispatch, path, ctx)
        if not ok and S.log then S.log.warn("fn onCall dispatch for %s failed: %s", path, firstLine(err)) end
        -- nothing returned: the result of the call stays as it is
    end
end

local function register(path)
    if S.hooked[path] then return true end
    local ok, err = pcall(F._deps.registerHook, path, hookFor(path))
    if ok then
        S.hooked[path] = true
        S.pending[path] = nil
        return true
    end
    if S.log then S.log.warn("fn onCall: RegisterHook(%s) failed: %s", path, firstLine(err)) end
    return false
end

local function ensureHook(path)
    if S.hooked[path] or S.pending[path] then return end
    if not F._deps.inHook() then register(path) return end
    -- Story 37: never inside a hook or a dependent callback; the next game-thread frame registers it.
    S.pending[path] = true
    local ok, err = pcall(F._deps.schedule, 1, function()
        local okR, errR = pcall(register, path)
        if not okR and S.log then S.log.warn("fn onCall: registering the hook for %s failed: %s", path, firstLine(errR)) end
        S.pending[path] = nil
    end)
    if not ok then
        S.pending[path] = nil
        if S.log then S.log.warn("fn onCall: the hook for %s could not be scheduled: %s", path, firstLine(err)) end
    end
end

-- ---------------------------------------------------------------- intercept, release, runOriginal

local KEYS = { fn = true, target = true, action = true, value = true, onCall = true }

function API.intercept(opts, ...)
    if select("#", ...) ~= 0 then fail("intercept", "expected 1 argument (a table), got %d", 1 + select("#", ...)) end
    if type(opts) ~= "table" then fail("intercept", "expected a table { fn, target, action, value, onCall }, got %s", describe(opts)) end
    for k in pairs(opts) do
        if not KEYS[k] then fail("intercept", "unknown key %s (fn, target, action, value, onCall)", describe(k)) end
    end
    local path, target, action, value, onCall = opts.fn, opts.target, opts.action, opts.value, opts.onCall
    if type(path) ~= "string" then fail("intercept", "fn must be a string (an allowlisted function path), got %s", describe(path)) end
    if target ~= nil and type(target) ~= "userdata" then fail("intercept", "target must be a UObject or nil (any instance), got %s", describe(target)) end
    if type(action) ~= "string" then fail("intercept", "action must be 'skip' or 'replace', got %s", describe(action)) end
    if value ~= nil and type(value) ~= "userdata" then fail("intercept", "value must be a UObject or nil, got %s", describe(value)) end
    if onCall ~= nil and type(onCall) ~= "function" then fail("intercept", "onCall must be a function or nil, got %s", describe(onCall)) end
    enter("intercept")

    local th, vh
    if target ~= nil then
        local ok, h = pcall(F._deps.ref, target)
        if not ok then fail("intercept", "target is not a live UObject (%s)", firstLine(h)) end
        th = h
    end
    if value ~= nil then
        local ok, h = pcall(F._deps.ref, value)
        if not ok then
            if th then pcall(F._deps.free, th) end
            fail("intercept", "value is not a live UObject (%s)", firstLine(h))
        end
        vh = h
    end
    local ok, id = pcall(native("_FnIntercept"), path, th or 0, action, vh)
    if th then pcall(F._deps.free, th) end
    if vh then pcall(F._deps.free, vh) end
    if not ok then rethrow("intercept", "_FnIntercept", id) end

    local okA, applied = pcall(appliedOf, id)
    S.rules[id] = { path = path, onCall = onCall, applied = okA and applied or 0 }
    if onCall then ensureHook(path) end
    return id
end

local function checkId(op, id)
    if math.type(id) ~= "integer" then fail(op, "id must be an integer (one intercept returned), got %s", describe(id)) end
end

function API.release(id, ...)
    if select("#", ...) ~= 0 then fail("release", "expected 1 argument (id), got %d", 1 + select("#", ...)) end
    checkId("release", id)
    enter("release")
    local ok, r = pcall(native("_FnRelease"), id)
    if not ok then rethrow("release", "_FnRelease", r) end
    S.rules[id] = nil -- released, or already gone (pruned with its target): either way no longer this state's
    return r == true
end

function API.runOriginal(id, f, ...)
    checkId("runOriginal", id)
    if type(f) ~= "function" then fail("runOriginal", "f must be a function, got %s", describe(f)) end
    enter("runOriginal")
    local suspend = native("_FnSuspend")
    local okS, errS = pcall(suspend, id, true)
    if not okS then rethrow("runOriginal", "_FnSuspend", errS) end
    local r = table.pack(pcall(f, ...))
    -- Resumed in every case; a rule f released meanwhile is simply gone.
    pcall(suspend, id, false)
    if not r[1] then error(r[2], 0) end
    return table.unpack(r, 2, r.n)
end

-- bind{ log }: the connecting mod's logger (onCall warnings). Called by client.connect.
function F.bind(api)
    S.log = api and api.log or nil
end

-- For unit tests only.
F._S = S
F._dispatch = dispatch

return F
