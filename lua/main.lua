-- Core's own Lua (api-contract.md, "Core's own start-up"): checks the native part, publishes state and version,
-- answers the Blueprint channel <Core>_Call, and loads its Blueprint class itself when BPModLoaderMod has not.
-- The name comes from this mod's folder (Mods/<Core>/Scripts/main.lua; the folder is mod.json "name", set by
-- build.ps1), so nothing here spells it.
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local NAME = scriptDir:match("([^/\\]+)[/\\][Ss]cripts$")
local LOWER = NAME:lower()
local V = require(LOWER .. ".version")
local log = require(LOWER .. ".log").new(NAME)
-- The map service's host setup (lua/pkg/map/setup.lua, map service story 5); loaded here, started in start().
local okMap, MAP = pcall(require, LOWER .. ".map.setup")
-- The map service's Journal map and area flags (lua/pkg/map/journalmap.lua, map service story 7, every machine);
-- driven from the same LoadMap post-hook.
local okJMap, JMAP = pcall(require, LOWER .. ".map.journalmap")

local CLASS_PKG = "/Game/Mods/" .. NAME .. "/ModActor"
local CLASS = CLASS_PKG .. ".ModActor_C"
local CALL_FN = CLASS .. ":" .. NAME .. "_Call"
local MAX_REQUEST = 4096
local MAX_OP = 64

local state = "loading"
local function setState(s)
    state = s
    ModRef:SetSharedVariable(LOWER .. ".state", s)
end
setState("loading")
-- <core>.map: "ready" once the map service's setup is installed (DemoMapLoader then skips its own), else why not.
ModRef:SetSharedVariable(LOWER .. ".map", "loading")
local boot = (tonumber(ModRef:GetSharedVariable(LOWER .. ".boot")) or 0) + 1
ModRef:SetSharedVariable(LOWER .. ".boot", boot)
ModRef:SetSharedVariable(LOWER .. ".version", V.version)

-- The request as a Lua string, or the raw value when it is not one (handle() then replies err:bad-request).
local function str(v)
    if type(v) == "string" then return v end
    if type(v) == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok and type(s) == "string" then return s end
    end
    return v
end

-- Echoes at most 64 printable bytes of untrusted text back into a reply or the log.
local function quote(s)
    return (tostring(s):sub(1, 64):gsub("[^%w%p ]", "?"))
end

-- The channel. Runs in core's Lua state on the caller's thread (callers must be on the game thread).
-- Requests come from any mod, so nothing in them is trusted: every malformed request gets a clean err: reply.
-- Request: <op> or <op>:<payload>, op = 1..64 of [A-Za-z0-9_-], at most MAX_REQUEST bytes in all.
local function handle(request)
    if type(request) ~= "string" then return "err:bad-request expected a string, got " .. type(request) end
    if #request > MAX_REQUEST then return string.format("err:too-long %d bytes, cap %d", #request, MAX_REQUEST) end
    if #request == 0 then return "err:bad-request empty request" end
    if state ~= "ready" then return "err:not-ready " .. state end
    local op = request:match("^([%w_%-]+):") or request:match("^([%w_%-]+)$")
    if not op then return "err:bad-request malformed request '" .. quote(request) .. "' (want <op> or <op>:<payload>)" end
    if #op > MAX_OP then return string.format("err:bad-request op is %d bytes, cap %d", #op, MAX_OP) end
    if op == "ping" then return string.format("ok:pong %s boot=%d", V.version, boot) end
    if op == "version" then return "ok:" .. V.version end
    return "err:unknown-op " .. quote(op)
end

local hooked = false
local function hookChannel(reason)
    if hooked then return end
    local cls = StaticFindObject(CLASS)
    if not cls or not cls:IsValid() then return end
    hooked = true
    -- Blueprint functions get post-hooks only; the return value replaces <Core>_Call's ReturnValue. Everything,
    -- reading the parameter included, runs under pcall: no error may escape a hook callback.
    local ok, err = pcall(RegisterHook, CALL_FN, function(_, request)
        local okH, reply = pcall(function() return handle(str(request:get())) end)
        if not okH then
            reply = "err:internal " .. quote(reply)
            log.warn("CHANNEL request failed inside %s: %s", NAME, reply)
        end
        return reply
    end)
    if not ok then
        hooked = false
        log.error("CHANNEL could not hook %s: %s", CALL_FN, tostring(err))
        return
    end
    log.info("CHANNEL hooked %s (%s)", CALL_FN, reason)
end

-- Loads the class the way BPModLoaderMod does (LoadAsset can't: pak-only assets aren't in the asset registry).
local missingLogged = false
local function ensureClass()
    if StaticFindObject(CLASS) and StaticFindObject(CLASS):IsValid() then hookChannel("already loaded") return end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    local cls = helpers:GetAsset({ PackageName = FName(CLASS_PKG), AssetName = FName("ModActor_C") })
    if cls and cls:IsValid() then
        log.info("SELF_LOAD BPModLoaderMod had not loaded %s; %s loaded it itself", CLASS, NAME)
        hookChannel("self-load")
    elseif not missingLogged then
        missingLogged = true
        log.error("MISSING %s's Blueprint content is not installed: %s did not load. Is Content/Paks/LogicMods/%s.pak there (exact name, no _P)?", NAME, CLASS, NAME)
    end
end

local function start()
    local nativeVersion = _G[NAME .. "_NativeVersion"]
    if type(nativeVersion) ~= "function" then
        setState("failed: native part missing")
        log.error("native part is not loaded (Mods/%s/dlls/main.dll missing, failed to load, or %s disabled); %s does nothing.", NAME, NAME, NAME)
        return
    end
    local nv, nue = nativeVersion()
    if nv ~= V.version then
        setState("failed: native part " .. tostring(nv) .. " does not match Lua " .. V.version)
        log.error("native part %s does not match Lua part %s; reinstall %s. %s does nothing.", tostring(nv), V.version, NAME, NAME)
        return
    end
    -- The objectives natives (native/src/objectives.cpp; the map service fills intel task lists through them). Checked
    -- once; core still starts without them, only task lists can't be filled.
    local missingNatives = {}
    for _, suffix in ipairs({ "_SetObjectives", "_DescribeObjectives", "_SetTraitorTaskState" }) do
        if type(_G[NAME .. suffix]) ~= "function" then missingNatives[#missingNatives + 1] = NAME .. suffix end
    end
    if #missingNatives > 0 then
        log.error("objectives natives missing from the native part (%s); intel task lists can't be filled. Reinstall %s.", table.concat(missingNatives, ", "), NAME)
    end

    -- The map service: the Start marker's and the game state's BeginPlay hooks (InitGameState post-hook); the setup's
    -- LoadMap part runs from core's one LoadMap post-hook below.
    local mapReady = false
    if not okMap then
        log.error("map service did not load (%s); no map setup on this machine", tostring(MAP):match("^[^\n]*"))
        ModRef:SetSharedVariable(LOWER .. ".map", "failed: did not load")
    else
        local okI, errI = pcall(function() MAP.init({ log = log }) MAP.install() end)
        if okI then mapReady = true
        else
            log.error("map service could not start: %s", tostring(errI):match("^[^\n]*"))
            ModRef:SetSharedVariable(LOWER .. ".map", "failed: could not start")
        end
    end

    -- The Journal map: a loop of its own, started or stopped from the LoadMap post-hook below.
    local jmapReady = false
    if not okJMap then
        log.error("Journal map service did not load (%s); no Journal map or area flags on this machine", tostring(JMAP):match("^[^\n]*"))
    else
        local okJ, errJ = pcall(JMAP.init, { log = log })
        if okJ then jmapReady = true
        else log.error("Journal map service could not start: %s", tostring(errJ):match("^[^\n]*")) end
    end

    NotifyOnNewObject(CLASS, function()
        local okN, errN = pcall(hookChannel, "NotifyOnNewObject")
        if not okN then log.error("channel hook from NotifyOnNewObject failed: %s", tostring(errN)) end
        return true
    end)
    hookChannel("main.lua")

    -- Fallback when BPModLoaderMod did not load core's class (disabled, or the pak missing or misnamed).
    -- The LoadMap hook runs on the game thread, so the delayed check is scheduled from there and runs there. Not
    -- ExecuteWithDelay + ExecuteInGameThread: an ExecuteInGameThread from the async thread can lose its callback while
    -- this state's Lua runs on the game thread (the channel hook, for one); lua/pkg/ui/hud.lua explains the race.
    RegisterLoadMapPostHook(function(_, world)
        if mapReady then
            local okM, errM = pcall(function() MAP.onLoadMap(world and world:get()) end)
            if not okM then log.error("map service LoadMap part failed: %s", tostring(errM):match("^[^\n]*")) end
        end
        if jmapReady then
            local okJ, errJ = pcall(function() JMAP.onLoadMap(world and world:get()) end)
            if not okJ then log.error("Journal map LoadMap part failed: %s", tostring(errJ):match("^[^\n]*")) end
        end
        local okL, errL = pcall(ExecuteInGameThreadWithDelay, 3000, function()
            local ok, err = pcall(ensureClass)
            if not ok then log.error("class check failed: %s", tostring(err)) end
        end)
        if not okL then log.error("class check could not be scheduled: %s", tostring(errL)) end
    end)

    ModRef.OnUnload = function()
        pcall(function() ModRef:SetSharedVariable(LOWER .. ".map", "stopped") end)
        if jmapReady then pcall(JMAP.stop) end
        local okU, errU = pcall(setState, "stopped")
        log.info("STOPPED%s", okU and "" or (" (state not published: " .. tostring(errU) .. ")"))
    end

    if mapReady then ModRef:SetSharedVariable(LOWER .. ".map", "ready") end
    setState("ready")
    log.info("READY version=%s native=%s ue4ss=%s boot=%d", V.version, tostring(nv), tostring(nue), boot)
end

local ok, err = xpcall(start, debug.traceback)
if not ok then
    setState("failed: " .. tostring(err):match("^[^\n]*"))
    log.error("start-up failed: %s", tostring(err))
end
