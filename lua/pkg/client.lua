-- Dependent-side client (api-contract.md, "nncore.client"). Runs in the dependent's own Lua state; reaches the one
-- running core only through shared variables (state, version) and the Blueprint channel on ModActor's class default
-- object. connect() is asynchronous: the channel exists only once the first world has loaded core's class.
local BASE = (...):gsub("%.client$", "")
local V = require(BASE .. ".version")
local semver = require(BASE .. ".semver")
local logm = require(BASE .. ".log")
local refm = require(BASE .. ".ref")

local NAME, LOWER = V.name, V.name:lower()
local CLASS = "/Game/Mods/" .. NAME .. "/ModActor.ModActor_C"
local CDO = "/Game/Mods/" .. NAME .. "/ModActor.Default__ModActor_C"
local CALL = NAME .. "_Call"
local MAX_REQUEST = 4096

local C = { name = NAME }

local function str(v)
    if type(v) == "string" then return v end
    if type(v) == "userdata" and v.ToString then return v:ToString() end
    return tostring(v)
end

local function found(path)
    local o = StaticFindObject(path)
    return o ~= nil and o:IsValid() and o or nil
end

-- call(op, payload) -> true, payload | false, reply-or-reason. Game thread only.
function C.call(op, payload)
    local req = payload ~= nil and (op .. ":" .. tostring(payload)) or op
    if #req > MAX_REQUEST then return false, "err:too-long" end
    local cdo = found(CDO)
    if not cdo then return false, "channel class not loaded" end
    local ok, out = pcall(function() return str(cdo[CALL](cdo, req)) end)
    if not ok then return false, "call failed: " .. tostring(out) end
    if out:sub(1, 3) == "ok:" then return true, out:sub(4) end
    return false, out
end

-- connect{ mod, need, onReady = fn(core), onFail = fn(message), timeout = seconds }
function C.connect(opts)
    assert(type(opts) == "table" and type(opts.mod) == "string" and type(opts.need) == "string", "connect{ mod = <string>, need = <semver> }")
    local mod, need = opts.mod, opts.need
    local log = logm.new(mod)
    local timeout = tonumber(opts.timeout) or 60
    local tail = " " .. mod .. " will not run."
    local done = false

    local function fail(msg)
        if done then return end
        done = true
        log.error("%s", msg .. tail)
        if opts.onFail then
            local ok, err = pcall(opts.onFail, msg)
            if not ok then log.error("onFail threw: %s", tostring(err)) end
        end
    end

    if type(_G[NAME .. "_NativeVersion"]) ~= "function" then
        fail(NAME .. "'s native part is not loaded (Mods/" .. NAME .. "/dlls/main.dll missing or failed to load).")
        return
    end

    local deadline -- set on the first game-thread attempt; covers a wrong mods.txt order and slow first worlds
    local function attempt()
        deadline = deadline or (os.time() + timeout)
        local expired = os.time() > deadline
        local state = ModRef:GetSharedVariable(LOWER .. ".state")
        local version = ModRef:GetSharedVariable(LOWER .. ".version")
        if state == nil then
            if expired then fail(NAME .. " is installed but not running (disabled in mods.txt, or not the first line).") end
            return
        end
        if type(state) == "string" and state:sub(1, 7) == "failed:" then
            fail(NAME .. " failed to start (" .. state:sub(9) .. ").")
            return
        end
        if state == "stopped" then fail(NAME .. " was stopped (uninstalled or reloading).") return end
        if state ~= "ready" then
            if expired then fail(NAME .. " did not finish loading; see its errors earlier in UE4SS.log.") end
            return
        end
        if not semver.satisfies(version, need) then
            fail(string.format("%s %s is not compatible; %s needs %s (^ rules). Update %s.", NAME, tostring(version), mod, need, NAME))
            return
        end
        if not found(CLASS) then
            if expired then fail(NAME .. "'s Blueprint content is not installed (Content/Paks/LogicMods/" .. NAME .. ".pak).") end
            return
        end
        local ok, reply = C.call("ping")
        if not ok then
            if expired then fail(NAME .. " is not answering its channel (" .. tostring(reply) .. ").") end
            return
        end
        done = true
        log.info("CONNECT ok %s %s (%s)", NAME, version, reply)
        local api = {
            name = NAME, version = version, log = log, call = C.call,
            ref = refm.ref, deref = refm.deref, free = refm.free,
        }
        if opts.onReady then
            local okR, err = pcall(opts.onReady, api)
            if not okR then log.error("onReady threw: %s", tostring(err)) end
        end
    end

    LoopAsync(500, function()
        if not done then
            ExecuteInGameThread(function()
                if done then return end
                local ok, err = pcall(attempt)
                if not ok then fail("connect failed: " .. tostring(err)) end
            end)
        end
        return done
    end)
end

return C
