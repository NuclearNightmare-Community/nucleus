-- Dependent-side client (api-contract.md, "<core>.client"; <core> is the lowercase mod.json name). Runs in the
-- dependent's own Lua state; reaches the one running core only through shared variables (state, version) and the
-- Blueprint channel on ModActor's class default object. connect() is asynchronous: the channel exists only once the
-- first world has loaded core's class.
local BASE = (...):gsub("%.client$", "")
local V = require(BASE .. ".version")
local semver = require(BASE .. ".semver")
local logm = require(BASE .. ".log")
local refm = require(BASE .. ".ref")
local clockm = require(BASE .. ".clock")
-- UI helpers (ui-helpers-contract.md). Loading them registers the HUD creation callback (ui/hud.lua) in this Lua state.
-- A failure here must not stop connect for mods that use no UI: core.ui is then missing and onReady is told why.
local uiOk, uiErr = pcall(function()
    return { common = require(BASE .. ".ui.common"), hud = require(BASE .. ".ui.hud"),
             text = require(BASE .. ".ui.text"), place = require(BASE .. ".ui.place"), debug = require(BASE .. ".ui.debug") }
end)

local NAME, LOWER = V.name, V.name:lower()
local CLASS = "/Game/Mods/" .. NAME .. "/ModActor.ModActor_C"
local CDO = "/Game/Mods/" .. NAME .. "/ModActor.Default__ModActor_C"
local CALL = NAME .. "_Call"
local MAX_REQUEST = 4096

local C = { name = NAME }

local function str(v)
    if type(v) == "string" then return v end
    if type(v) == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok then return s end
    end
    return tostring(v)
end

local function found(path)
    local o = StaticFindObject(path)
    return o ~= nil and o:IsValid() and o or nil
end

-- call(op, payload) -> true, payload | false, reply-or-reason. Game thread only. Never raises: bad arguments come
-- back as false, "err:bad-request ..." without reaching the channel.
function C.call(op, payload)
    if type(op) ~= "string" then return false, "err:bad-request op must be a string, got " .. type(op) end
    if payload ~= nil and type(payload) ~= "string" and type(payload) ~= "number" then
        return false, "err:bad-request payload must be a string or number, got " .. type(payload)
    end
    local req = payload ~= nil and (op .. ":" .. tostring(payload)) or op
    if #req > MAX_REQUEST then return false, string.format("err:too-long %d bytes, cap %d", #req, MAX_REQUEST) end
    local okF, cdo = pcall(found, CDO)
    if not okF or not cdo then return false, "channel class not loaded" end
    local ok, out = pcall(function() return str(cdo[CALL](cdo, req)) end)
    if not ok then return false, "call failed: " .. tostring(out) end
    if type(out) ~= "string" then return false, "call failed: reply is " .. type(out) end
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
            clock = clockm,
        }
        if uiOk then
            local U = uiErr
            api.ui = {
                hud = { find = U.hud.find, watch = U.hud.watch, unwatch = U.hud.unwatch, isVisible = U.hud.isVisible, stats = U.hud.stats },
                text = { create = U.text.create, set = U.text.set, setStyle = U.text.setStyle, setVisible = U.text.setVisible,
                         remove = U.text.remove, isShown = U.text.isShown, stats = U.text.stats, tagOf = U.text.tagOf },
                place = U.place.place,
                elements = U.place.elements,
                debug = { overlaps = U.debug.overlaps }, -- story 12: a diagnostic for testing a mod's UI
            }
            -- The UI helpers run in this mod's state with its logger; until now they refuse every call ("before connect").
            U.common.bind{ mod = mod, log = log, ref = refm.ref, deref = refm.deref, free = refm.free, micros = clockm.micros }
            -- One timing summary line when this mod unloads, chained in front of any OnUnload already set.
            pcall(function()
                local prev = ModRef.OnUnload
                ModRef.OnUnload = function(...)
                    pcall(U.hud._summary)
                    if type(prev) == "function" then return prev(...) end
                end
            end)
        else
            log.error("%s's UI helpers failed to load (%s); core.ui is not available.", NAME, tostring(uiErr))
        end
        if opts.onReady then
            local okR, err = pcall(opts.onReady, api)
            if not okR then log.error("onReady threw: %s", tostring(err)) end
        end
    end

    -- A game-thread loop, registered once here and cancelled from inside once done. Not LoopAsync +
    -- ExecuteInGameThread: in the pinned UE4SS an ExecuteInGameThread from the async thread can lose its callback (and
    -- register a stray value instead) while this mod's Lua runs on the game thread (ui/hud.lua explains the race).
    local handle
    local okL, res = pcall(LoopInGameThreadWithDelay, 500, function()
        if not done then
            local ok, err = pcall(attempt)
            if not ok then
                local okF, errF = pcall(fail, "connect failed: " .. tostring(err))
                if not okF then done = true; print("[" .. tostring(mod) .. "] ERROR connect failed and so did reporting it: " .. tostring(errF) .. "\n") end
            end
        end
        if done and handle then pcall(CancelDelayedAction, handle); handle = nil end
    end)
    if okL and math.type(res) == "integer" then handle = res
    else fail("connect could not reach the game thread: " .. (okL and ("LoopInGameThreadWithDelay returned " .. tostring(res)) or tostring(res))) end
end

return C
