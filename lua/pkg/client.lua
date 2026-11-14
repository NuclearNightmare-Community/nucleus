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
local featm = require(BASE .. ".features")
local deprecate = require(BASE .. ".deprecate")
-- core.settings (Mod Manager story 5). A failure here must not stop connect: core.settings is then missing.
local setOk, settingsm = pcall(require, BASE .. ".settings.client")
-- core.net (core story 22). The same: a failure here costs core.net, not connect.
local netOk, netm = pcall(require, BASE .. ".net.client")
-- UI helpers (ui-helpers-contract.md). Loading them registers the HUD creation callback (ui/hud.lua) in this Lua state.
-- A failure here must not stop connect for mods that use no UI: core.ui is then missing and onReady is told why.
local uiOk, uiErr = pcall(function()
    return { common = require(BASE .. ".ui.common"), hud = require(BASE .. ".ui.hud"),
             journal = require(BASE .. ".ui.journal"),
             text = require(BASE .. ".ui.text"), place = require(BASE .. ".ui.place"), debug = require(BASE .. ".ui.debug"),
             panel = require(BASE .. ".ui.panel"), button = require(BASE .. ".ui.button"),
             -- story 21 (Mod Manager story 2): the title-screen menu, its entry, windows, lists and rows
             menu = require(BASE .. ".ui.menu"), entry = require(BASE .. ".ui.entry"), screen = require(BASE .. ".ui.screen"),
             list = require(BASE .. ".ui.list"), row = require(BASE .. ".ui.row"),
             -- story 24 (core 0.8.0): images and icons
             image = require(BASE .. ".ui.image"),
             -- Mod Manager story 4 (core story 26): checkbox, choice and slider-with-number controls
             checkbox = require(BASE .. ".ui.checkbox"), choice = require(BASE .. ".ui.choice"), slider = require(BASE .. ".ui.slider") }
end)

local NAME, LOWER = V.name, V.name:lower()
local CLASS = "/Game/Mods/" .. NAME .. "/ModActor.ModActor_C"
local CDO = "/Game/Mods/" .. NAME .. "/ModActor.Default__ModActor_C"
local CALL = NAME .. "_Call"
local MAX_REQUEST = 4096

local FLOOR = V.floor -- the oldest need this core still serves (mod.json "compat.floor", story 18); nil: no floor

local C = { name = NAME }
local boundLog -- the connecting mod's logger (deprecation lines are tagged with it); set by connect

-- Echoes at most 64 printable bytes of a caller's value into a message.
local function quote(s)
    return (tostring(s):sub(1, 64):gsub("[^%w%p ]", "?"))
end

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
    local repl = deprecate.OPS[op]
    if repl then pcall(deprecate.warn, boundLog, "channel op '" .. quote(op) .. "'", "'" .. repl .. "'") end
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

-- The refusal for a version mismatch or a bad need (story 18), without the " <mod> will not run." tail; nil when
-- compatible. Internal (the unit tests check the exact messages).
function C._compatMessage(have, need, mod, floor)
    local ok, kind = semver.check(have, need, floor)
    if ok then return nil end
    if kind == "core-too-old" then
        return string.format("%s %s is older than %s needs (%s). Update %s.", NAME, tostring(have), mod, need, NAME)
    elseif kind == "mod-too-old" then
        return string.format("%s was made for %s %s, which this %s %s no longer supports (oldest: %s). Update %s.",
            mod, NAME, need, NAME, tostring(have), tostring(floor), mod)
    elseif kind == "bad-have" then
        return string.format("%s reports version '%s', which isn't X.Y.Z; reinstall %s.", NAME, quote(have), NAME)
    end
    local _, why = semver.parseNeed(need)
    return string.format("connect: need %s. Fix %s's connect call (and its mod.json dependsOn) to name the oldest %s it works with, like '>=%s'.",
        type(need) == "string" and ("'" .. quote(need) .. "' " .. tostring(why)) or tostring(why), mod, NAME, V.version)
end

-- core.has(name) -> boolean and core.features() -> sorted list (story 18), over the list features.fromApi made from
-- this mod's api table. has never raises: anything but a known name (non-string, empty, too long, nil) is false.
local function featureCalls(list)
    local set = featm.set(list)
    local function has(name)
        if type(name) ~= "string" or #name == 0 or #name > featm.MAX_NAME then return false end
        return set[name] == true
    end
    local function features()
        local copy = {}
        for i, n in ipairs(list) do copy[i] = n end
        return copy
    end
    return has, features
end

-- connect{ mod, need, onReady = fn(core), onFail = fn(message), timeout = seconds } -> true | false, message.
-- need is the oldest core the mod works with: ">=X.Y.Z" ("^X.Y.Z" and a bare "X.Y.Z" are read as ">=X.Y.Z"). Returns
-- false when connect refuses at once (bad arguments, the native part missing), after logging the one line and calling
-- onFail; true when it is waiting for core (onReady or onFail come later, on the game thread). Never raises.
function C.connect(opts)
    if type(opts) ~= "table" or type(opts.mod) ~= "string" then
        local msg = string.format("connect{ mod = <string>, need = '>=X.Y.Z' } needs a table with a string mod, got %s%s.",
            type(opts), type(opts) == "table" and (" with mod " .. type(opts.mod)) or "")
        pcall(logm.new(NAME .. " client").error, "%s", msg)
        if type(opts) == "table" and type(opts.onFail) == "function" then pcall(opts.onFail, msg) end
        return false, msg
    end
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

    -- need is checked here, in main.lua, so a typo is reported at once (story 18 AC 5: one clean line, no raise).
    if not semver.parseNeed(need) then
        local msg = C._compatMessage(V.version, need, mod, nil)
        fail(msg)
        return false, msg .. tail
    end

    boundLog = boundLog or log -- the first mod in this state that got past its arguments (normally the only one)
    -- core.settings addresses the mod by its folder under Mods/: found now, while the caller's main.lua is on the stack.
    local ownFolder
    if setOk then
        local okF, f = pcall(settingsm.findFolder, NAME)
        if okF then ownFolder = f end
    end
    -- core.net publishes under the mod's own mod.json id: the install folder, found the same way, now.
    local netDir, netFolder
    if netOk then
        local okF, d, f = pcall(netm.findOwn, NAME)
        if okF then netDir, netFolder = d, f end
    end
    if type(_G[NAME .. "_NativeVersion"]) ~= "function" then
        local msg = NAME .. "'s native part is not loaded (Mods/" .. NAME .. "/dlls/main.dll missing or failed to load)."
        fail(msg)
        return false, msg .. tail
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
        local incompatible = C._compatMessage(version, need, mod, FLOOR)
        if incompatible then fail(incompatible) return end
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
        boundLog = log
        log.info("CONNECT ok %s %s (%s)", NAME, version, reply)
        local api = {
            name = NAME, version = version, log = log, call = C.call,
            ref = refm.ref, deref = refm.deref, free = refm.free,
            clock = clockm,
        }
        if uiOk then
            local U = uiErr
            -- core.ui's shape is declared once, in features.lua (UI), so the feature list core's READY line shows is
            -- the one core.has answers from.
            local ui, missing = featm.buildUi(U)
            if #missing > 0 then log.error("%s's UI helpers lack %s; those calls are not available.", NAME, table.concat(missing, ", ")) end
            api.ui = ui
            -- The UI helpers run in this mod's state with its logger; until now they refuse every call ("before connect").
            U.common.bind{ mod = mod, log = log, ref = refm.ref, deref = refm.deref, free = refm.free, micros = clockm.micros }
            -- One timing summary line when this mod unloads, chained in front of any OnUnload already set.
            pcall(function()
                local prev = ModRef.OnUnload
                ModRef.OnUnload = function(...)
                    pcall(U.hud._summary)
                    pcall(U.entry._unload) -- story 21: the entry leaves the live menu with its mod
                    if type(prev) == "function" then return prev(...) end
                end
            end)
            -- Story 15: the button class is loaded before onReady, so the first button.create registers this state's
            -- click hook at once (RegisterHook needs the function to exist).
            local okP, errP = pcall(U.button._prepare)
            if not okP then log.warn("%s's button class could not be loaded before onReady: %s", NAME, tostring(errP)) end
        else
            log.error("%s's UI helpers failed to load (%s); core.ui is not available.", NAME, tostring(uiErr))
        end
        -- Mod Manager story 5: core.settings, bound to this mod's folder (nil: the get/set/watch calls raise "own mod
        -- folder unknown"; describe and setFor still work).
        if setOk then
            local okB, errB = pcall(settingsm.bind, { call = C.call, log = log, folder = ownFolder, mod = mod })
            if okB then api.settings = settingsm.API
            else log.error("%s's settings client could not start (%s); core.settings is not available.", NAME, tostring(errB)) end
        else
            log.error("%s's settings client failed to load (%s); core.settings is not available.", NAME, tostring(settingsm))
        end
        -- Core story 22: core.net, bound to this mod's own id (nil: publish raises; read, watch and role still work).
        if netOk then
            local okI, man, why = pcall(netm.ownManifest, netDir, netFolder)
            if not okI then man, why = nil, tostring(man) end
            local id = man and man.id or nil
            local okB, errB = pcall(netm.bind, { call = C.call, log = log, id = id, idWhy = why, micros = clockm.micros })
            if okB then api.net = netm.API
            else log.error("%s's net client could not start (%s); core.net is not available.", NAME, tostring(errB)) end
            -- Core story 23: this mod's (id, version[, netCompat]) goes into this machine's presence list, and leaves it
            -- when the mod unloads.
            if man then
                for _, note in ipairs(man.notes or {}) do log.warn("%s.net presence: %s", NAME, note) end
                if man.version then
                    local payload = man.id .. "=" .. man.version .. (man.netCompat and ("/" .. man.netCompat) or "")
                    local okM, reply = C.call("net-mod", payload)
                    if okM then
                        log.info("%s.net presence: registered %s", NAME, payload)
                        pcall(function()
                            local prev = ModRef.OnUnload
                            ModRef.OnUnload = function(...)
                                pcall(C.call, "net-mod-off", man.id)
                                if type(prev) == "function" then return prev(...) end
                            end
                        end)
                    else
                        log.warn("%s.net presence: %s did not register %s: %s", NAME, NAME, payload, tostring(reply))
                    end
                end
            else
                log.info("%s.net presence: this mod is not reported to the host (%s)", NAME, tostring(why))
            end
        else
            log.error("%s's net client failed to load (%s); core.net is not available.", NAME, tostring(netm))
        end
        -- Story 18: feature checks, generated from this api table (features.lua). Optional for dependents: the
        -- minimum version is the normal way to depend on a feature.
        api.has, api.features = featureCalls(featm.fromApi(api))
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
    else
        local msg = "connect could not reach the game thread: " .. (okL and ("LoopInGameThreadWithDelay returned " .. tostring(res)) or tostring(res))
        fail(msg)
        return false, msg .. tail
    end
    return true
end

return C
