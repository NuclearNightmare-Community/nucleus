-- Core's own Lua (api-contract.md, "Core's own start-up"): checks the native part, publishes state and version,
-- answers the Blueprint channel <Core>_Call, and loads its Blueprint class itself when BPModLoaderMod has not.
-- The name comes from this mod's folder (Mods/<Core>/Scripts/main.lua), so nothing here hardcodes it.
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local NAME = scriptDir:match("([^/\\]+)[/\\][Ss]cripts$")
local LOWER = NAME:lower()
local V = require(LOWER .. ".version")
local log = require(LOWER .. ".log").new(NAME)

local CLASS_PKG = "/Game/Mods/" .. NAME .. "/ModActor"
local CLASS = CLASS_PKG .. ".ModActor_C"
local CALL_FN = CLASS .. ":" .. NAME .. "_Call"
local MAX_REQUEST = 4096

local state = "loading"
local function setState(s)
    state = s
    ModRef:SetSharedVariable(LOWER .. ".state", s)
end
setState("loading")
local boot = (tonumber(ModRef:GetSharedVariable(LOWER .. ".boot")) or 0) + 1
ModRef:SetSharedVariable(LOWER .. ".boot", boot)
ModRef:SetSharedVariable(LOWER .. ".version", V.version)

local function str(v)
    if type(v) == "string" then return v end
    if type(v) == "userdata" and v.ToString then return v:ToString() end
    return tostring(v)
end

-- The channel. Runs in core's Lua state on the caller's thread (callers must be on the game thread).
local function handle(request)
    if #request > MAX_REQUEST then return "err:too-long" end
    if state ~= "ready" then return "err:not-ready " .. state end
    local op = request:match("^([%w_%-]+)")
    if op == "ping" then return string.format("ok:pong %s boot=%d", V.version, boot) end
    if op == "version" then return "ok:" .. V.version end
    return "err:unknown-op " .. tostring(op)
end

local hooked = false
local function hookChannel(reason)
    if hooked then return end
    local cls = StaticFindObject(CLASS)
    if not cls or not cls:IsValid() then return end
    hooked = true
    -- Blueprint functions get post-hooks only; the return value replaces <Core>_Call's ReturnValue.
    RegisterHook(CALL_FN, function(_, request)
        local ok, reply = pcall(handle, str(request:get()))
        if not ok then reply = "err:internal " .. tostring(reply) end
        return reply
    end)
    log.info("CHANNEL hooked %s (%s)", CALL_FN, reason)
end

-- Loads the class the way BPModLoaderMod does (LoadAsset can't: pak-only assets aren't in the asset registry).
local missingLogged = false
local function ensureClass()
    if StaticFindObject(CLASS) and StaticFindObject(CLASS):IsValid() then hookChannel("already loaded") return end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    local cls = helpers:GetAsset({ PackageName = FName(CLASS_PKG), AssetName = FName("ModActor_C") })
    if cls and cls:IsValid() then
        log.info("SELF_LOAD BPModLoaderMod had not loaded %s; core loaded it itself", CLASS)
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

    NotifyOnNewObject(CLASS, function(obj)
        hookChannel("NotifyOnNewObject")
        return true
    end)
    hookChannel("main.lua")

    -- Fallback when BPModLoaderMod did not load core's class (disabled, or the pak missing or misnamed).
    RegisterLoadMapPostHook(function()
        ExecuteWithDelay(3000, function()
            ExecuteInGameThread(function()
                local ok, err = pcall(ensureClass)
                if not ok then log.error("class check failed: %s", tostring(err)) end
            end)
        end)
    end)

    ModRef.OnUnload = function()
        setState("stopped")
        log.info("STOPPED")
    end

    setState("ready")
    log.info("READY version=%s native=%s ue4ss=%s boot=%d", V.version, tostring(nv), tostring(nue), boot)
end

local ok, err = xpcall(start, debug.traceback)
if not ok then
    setState("failed: " .. tostring(err):match("^[^\n]*"))
    log.error("start-up failed: %s", tostring(err))
end
