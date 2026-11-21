-- Core's own Lua (api-contract.md, "Core's own start-up"): checks the native part, publishes state and version,
-- answers the Blueprint channel <Core>_Call, and loads its Blueprint class itself when BPModLoaderMod has not.
-- The name comes from this mod's folder (Mods/<Core>/Scripts/main.lua; the folder is mod.json "name", set by
-- build.ps1), so nothing here spells it.
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local NAME = scriptDir:match("([^/\\]+)[/\\][Ss]cripts$")
local LOWER = NAME:lower()
local V = require(LOWER .. ".version")
local log = require(LOWER .. ".log").new(NAME)
-- Story 18: the feature names core.has answers for, listed in the READY line (a player's log shows what their core
-- supports). Loaded under pcall: a missing file costs the list, not the start-up.
local okFeat, FEAT = pcall(require, LOWER .. ".features")
-- The map service (lua/pkg/map/setup.lua, map service stories 5-9); loaded here, started in start().
local okMap, MAP = pcall(require, LOWER .. ".map.setup")
-- The map service's Journal map and area flags (lua/pkg/map/journalmap.lua, map service story 7, every machine);
-- driven from the same LoadMap post-hook.
local okJMap, JMAP = pcall(require, LOWER .. ".map.journalmap")
-- The settings service (lua/pkg/settings/store.lua, Mod Manager story 5): every mod's declared settings and their
-- values, reached through the channel ops settings-get and settings-set. Loaded here, started in start().
local okSet, SETTINGS = pcall(require, LOWER .. ".settings.store")
-- core.net's owner (lua/pkg/net/host.lua, core story 22): this machine's net state; spawns <Core>Net on the host, reads
-- it on a client, answers the channel op net-publish. Loaded here, started in start(), driven from the LoadMap hook.
local okNet, NET = pcall(require, LOWER .. ".net.host")
-- core.net's player presence (lua/pkg/net/players.lua, core story 23): this machine's mod list, the per-player
-- <Core>Presence actors on the host and the client's report; answers the channel ops net-mod and net-mod-off. Ticked
-- on story 22's loop and reset from the same LoadMap post-hook.
local okPl, PLAYERS = pcall(require, LOWER .. ".net.players")
-- core.input's owner (lua/pkg/input/service.lua, core story 44): every dependent's controls in the game's Controls menu;
-- answers the channel ops input-control, input-release, input-state and input-list. Loaded here, started in start(),
-- ticked on its own loop and told of each map load from the LoadMap post-hook.
local okIn, INPUT = pcall(require, LOWER .. ".input.service")

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
-- <core>.map.setup (map service story 9, add-only): this machine's map setup, "none" | "pending <world>" | "done <world>"
-- | "failed <n> <world>"; the map service publishes it from here on (MAP.init's env.publish), and it stays "none" when
-- that service doesn't run (then <core>.map says why).
local SETUP_KEY = LOWER .. ".map.setup"
ModRef:SetSharedVariable(SETUP_KEY, "none")
local boot = (tonumber(ModRef:GetSharedVariable(LOWER .. ".boot")) or 0) + 1
ModRef:SetSharedVariable(LOWER .. ".boot", boot)
ModRef:SetSharedVariable(LOWER .. ".version", V.version)
-- <core>.settings.rev (Mod Manager story 5, add-only): +1 after every successful settings write; dependents poll it.
-- Starts at its previous value (a hot reload keeps it rising) or 0.
local REV_KEY = LOWER .. ".settings.rev"
local settingsRev = math.tointeger(ModRef:GetSharedVariable(REV_KEY)) or 0
ModRef:SetSharedVariable(REV_KEY, settingsRev)
local settingsReady = false
local inputReady = false
local netReady = false
local playersReady = false
-- The current world's full name (a string, never the UObject), from the LoadMap post-hook: the settings service
-- refuses "menu" settings outside the title screen.
local currentWorld
local function worldName()
    if currentWorld then return currentWorld end
    local ok, name = pcall(function()
        local pc = FindFirstOf("PlayerController")
        if pc and pc:IsValid() then return pc:GetWorld():GetFullName() end
    end)
    return ok and name or nil
end

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
    -- Test-only, deprecated in favour of "version" (story 18 AC 8; deprecate.lua): answered like it, and the client logs
    -- one DEPRECATED line per dependent. Not public API.
    if op == "deprecated-test" then return "ok:" .. V.version end
    -- Mod Manager story 5: the settings service. The payload is everything after "<op>:".
    if op == "settings-get" or op == "settings-set" then
        if not settingsReady then return "err:internal settings service not running" end
        local payload = #request > #op and request:sub(#op + 2) or nil
        return SETTINGS.op(op, payload)
    end
    -- Core story 22: core.net's publish (net/host.lua re-checks the payload, the role and the caps).
    if op == "net-publish" then
        if not netReady then return "err:internal net service not running" end
        local payload = #request > #op and request:sub(#op + 2) or nil
        return NET.op(payload)
    end
    -- Core story 23: a dependent's (id, version[, netCompat]) for presence, registered at connect and removed at unload.
    if op == "net-mod" or op == "net-mod-off" then
        if not playersReady then return "err:internal presence service not running" end
        local payload = #request > #op and request:sub(#op + 2) or nil
        return PLAYERS.op(op, payload)
    end
    -- Core story 44: core.input (input/service.lua re-checks every field, the caps and the key classes).
    if op == "input-control" or op == "input-release" or op == "input-state" or op == "input-list" then
        if not inputReady then return "err:internal input service not running" end
        local payload = #request > #op and request:sub(#op + 2) or nil
        return INPUT.op(op, payload)
    end
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
    -- The restart natives (native/src/restart.cpp, core story 45). Checked once; without them core.restart answers
    -- nil, "native part missing" (lua/pkg/restart.lua), and a Restart now button stays hidden.
    local missingRestart = {}
    for _, suffix in ipairs({ "_RestartMode", "_RestartStart" }) do
        if type(_G[NAME .. suffix]) ~= "function" then missingRestart[#missingRestart + 1] = NAME .. suffix end
    end
    if #missingRestart > 0 then
        log.error("restart natives missing from the native part (%s); core.restart is unavailable. Reinstall %s.", table.concat(missingRestart, ", "), NAME)
    end
    -- The catalog natives (native/src/catalog.cpp, Mod Manager v2 story 2). Checked once; without them core.catalog
    -- answers nil, "native part missing" (lua/pkg/catalog.lua).
    local missingCatalog = {}
    for _, suffix in ipairs({ "_CatalogRefresh", "_CatalogDownload", "_CatalogPoll" }) do
        if type(_G[NAME .. suffix]) ~= "function" then missingCatalog[#missingCatalog + 1] = NAME .. suffix end
    end
    if #missingCatalog > 0 then
        log.error("catalog natives missing from the native part (%s); core.catalog is unavailable. Reinstall %s.", table.concat(missingCatalog, ", "), NAME)
    end
    -- The staged-change natives (native/src/apply.cpp, Mod Manager v2 story 3). Checked once; without them core.apply
    -- answers nil, "native part missing" (lua/pkg/apply.lua), and nothing staged is applied.
    local missingApply = {}
    for _, suffix in ipairs({ "_ApplyStatus", "_ApplyStart", "_ApplyAck" }) do
        if type(_G[NAME .. suffix]) ~= "function" then missingApply[#missingApply + 1] = NAME .. suffix end
    end
    if #missingApply > 0 then
        log.error("apply natives missing from the native part (%s); core.apply is unavailable. Reinstall %s.", table.concat(missingApply, ", "), NAME)
    end

    -- The map service: the Start marker's and the game state's BeginPlay hooks (InitGameState post-hook); the setup's
    -- LoadMap part runs from core's one LoadMap post-hook below.
    local mapReady = false
    if not okMap then
        log.error("map service did not load (%s); no map setup on this machine", tostring(MAP):match("^[^\n]*"))
        ModRef:SetSharedVariable(LOWER .. ".map", "failed: did not load")
    else
        local okI, errI = pcall(function()
            MAP.init({ log = log, publish = function(value) ModRef:SetSharedVariable(SETUP_KEY, value) end })
            MAP.install()
        end)
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

    -- The settings service: core's own folder is the parent of Scripts/; Mods/ is the one above it.
    if not okSet then
        log.error("settings service did not load (%s); settings-get and settings-set are unavailable", tostring(SETTINGS):match("^[^\n]*"))
    else
        local okI, errI = pcall(SETTINGS.init, {
            modsDir = scriptDir:match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts$"), core = NAME, log = log, rev = settingsRev, world = worldName,
            publishRev = function(n) settingsRev = n; ModRef:SetSharedVariable(REV_KEY, n) end,
        })
        if okI then settingsReady = true
        else log.error("settings service could not start: %s", tostring(errI):match("^[^\n]*")) end
    end

    -- core.net (story 22): role none until the first world; its loop starts from the LoadMap post-hook.
    if not okNet then
        log.error("net service did not load (%s); core.net has no state on this machine", tostring(NET):match("^[^\n]*"))
    else
        local okI, errI = pcall(NET.init, {
            log = log, setShared = function(k, v) ModRef:SetSharedVariable(k, v) end,
            getShared = function(k) return ModRef:GetSharedVariable(k) end,
            isHost = mapReady and function(w) return MAP.isHost(w) end or nil,
            -- story 23: presence runs on this loop, after core.net's own tick
            tick = function() if playersReady then PLAYERS.tick() end end,
        })
        if okI then
            netReady = true
            -- A client learns the host's <Core>Net from its creation (the callback only takes a weak handle).
            local okN, errN = pcall(NotifyOnNewObject, NET.CLASS, function(obj)
                local okC, errC = pcall(NET.onNewObject, obj)
                if not okC then log.warn("NET creation callback failed: %s", tostring(errC):match("^[^\n]*")) end
                return false
            end)
            if not okN then log.warn("NET NotifyOnNewObject(%s) failed (%s); clients find the actor by the 2 s fallback only", NET.CLASS, tostring(errN):match("^[^\n]*")) end
        else
            log.error("net service could not start: %s", tostring(errI):match("^[^\n]*"))
        end
    end
    -- core.net's presence (story 23): needs the net service (its role and loop).
    if not okPl then
        log.error("presence service did not load (%s); core.net.presence has no records on this machine", tostring(PLAYERS):match("^[^\n]*"))
    elseif netReady then
        local okI, errI = pcall(PLAYERS.init, {
            log = log, setShared = function(k, v) ModRef:SetSharedVariable(k, v) end,
            getShared = function(k) return ModRef:GetSharedVariable(k) end,
            role = function() return NET.role() end,
        })
        if okI then
            playersReady = true
            -- A client learns of its own <Core>Presence from its creation (the callback only takes a weak handle).
            local okN, errN = pcall(NotifyOnNewObject, PLAYERS.CLASS, function(obj)
                local okC, errC = pcall(PLAYERS.onNewObject, obj)
                if not okC then log.warn("PRESENCE creation callback failed: %s", tostring(errC):match("^[^\n]*")) end
                return false
            end)
            if not okN then log.warn("PRESENCE NotifyOnNewObject(%s) failed (%s); clients find their actor by the 2 s fallback only", PLAYERS.CLASS, tostring(errN):match("^[^\n]*")) end
        else
            log.error("presence service could not start: %s", tostring(errI):match("^[^\n]*"))
        end
    end

    -- core.input (story 44): the registry and the ops now; its loop and the Controls page poll from the first map load.
    if not okIn then
        log.error("input service did not load (%s); core.input is unavailable", tostring(INPUT):match("^[^\n]*"))
    else
        local okI, errI = pcall(function()
            local refm = require(LOWER .. ".ref")
            INPUT.init({ log = log, ref = refm.ref, deref = refm.deref, free = refm.free, micros = require(LOWER .. ".clock").micros })
        end)
        if okI then inputReady = true
        else log.error("input service could not start: %s", tostring(errI):match("^[^\n]*")) end
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
        local okW, name = pcall(function() return world:get():GetFullName() end)
        currentWorld = okW and type(name) == "string" and name or nil
        if mapReady then
            local okM, errM = pcall(function() MAP.onLoadMap(world and world:get()) end)
            if not okM then log.error("map service LoadMap part failed: %s", tostring(errM):match("^[^\n]*")) end
            -- Story 6: the 1 s loop (traitor mirror, client Area Name, cabin sound), registered here on the game thread
            -- in a level with the Start marker, cancelled in any other.
            local okS, errS = pcall(function() return MAP.start(world and world:get()) end)
            if not okS then log.error("map service loop could not start: %s", tostring(errS):match("^[^\n]*")) end
        end
        if jmapReady then
            local okJ, errJ = pcall(function() JMAP.onLoadMap(world and world:get()) end)
            if not okJ then log.error("Journal map LoadMap part failed: %s", tostring(errJ):match("^[^\n]*")) end
        end
        -- Story 22: core.net's values belong to this world (cleared), the role is decided here (after the map service
        -- refreshed its isHost cache), the host spawns <Core>Net; the 250 ms loop starts once, here, on the game thread.
        if netReady then
            local okN, errN = pcall(function() NET.onLoadMap(world and world:get()) end)
            if not okN then log.error("net LoadMap part failed: %s", tostring(errN):match("^[^\n]*")) end
            -- Story 23: presence records belong to this world (cleared); its role is the one just decided.
            if playersReady then
                local okP, errP = pcall(function() PLAYERS.onLoadMap(world and world:get()) end)
                if not okP then log.error("presence LoadMap part failed: %s", tostring(errP):match("^[^\n]*")) end
            end
            local okS, errS = pcall(NET.start)
            if not okS then log.error("net loop could not start: %s", tostring(errS):match("^[^\n]*")) end
        end
        -- Story 44: the input service's controls are added again in this world; its loop and the Controls page poll
        -- start here once (game thread).
        if inputReady then
            for _, part in ipairs({ "start", "startScreen", "onLoadMap" }) do
                local okI, errI = pcall(INPUT[part])
                if not okI then log.error("input service %s failed: %s", part, tostring(errI):match("^[^\n]*")) end
            end
        end
        local okL, errL = pcall(ExecuteInGameThreadWithDelay, 3000, function()
            local ok, err = pcall(ensureClass)
            if not ok then log.error("class check failed: %s", tostring(err)) end
        end)
        if not okL then log.error("class check could not be scheduled: %s", tostring(errL)) end
    end)

    ModRef.OnUnload = function()
        if mapReady then pcall(MAP.stop) end
        pcall(function() ModRef:SetSharedVariable(LOWER .. ".map", "stopped") end)
        pcall(function() ModRef:SetSharedVariable(SETUP_KEY, "none") end)
        if jmapReady then pcall(JMAP.stop) end
        if netReady then pcall(NET.stop); pcall(NET.unload) end
        if playersReady then pcall(PLAYERS.stop); pcall(PLAYERS.unload) end
        if inputReady then pcall(INPUT.unload) end
        local okU, errU = pcall(setState, "stopped")
        log.info("STOPPED%s", okU and "" or (" (state not published: " .. tostring(errU) .. ")"))
    end

    -- Story 18: what this core supports, as core.has answers it (features.lua), for the READY line.
    local features = "unavailable"
    local okD, list = false, FEAT
    if okFeat then okD, list = pcall(FEAT.declared) end
    if okD then features = table.concat(list, ",")
    else log.warn("feature list unavailable: %s", tostring(list):match("^[^\n]*")) end

    if mapReady then ModRef:SetSharedVariable(LOWER .. ".map", "ready") end
    setState("ready")
    log.info("READY version=%s native=%s ue4ss=%s boot=%d floor=%s features=%s", V.version, tostring(nv), tostring(nue), boot, tostring(V.floor), features)
end

local ok, err = xpcall(start, debug.traceback)
if not ok then
    setState("failed: " .. tostring(err):match("^[^\n]*"))
    log.error("start-up failed: %s", tostring(err))
end
