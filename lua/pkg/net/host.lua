-- core.net's owner (core story 22, Net-1). Runs in core's Lua state only, on every machine: the single owner of this
-- machine's net state, which dependents read through four shared variables and change only through the channel op
-- net-publish.
--
--   host (isHost: IsServer and not IsStandalone, map/setup.lua's per-world cache): keeps this world's published values,
--         spawns one <Core>Net (replicated, always relevant, no owner) and writes State and CoreVersion through the
--         class's Blueprint setters; a publish before the actor exists is written when it spawns.
--   client: finds the host's <Core>Net (NotifyOnNewObject on the full class path, plus a FindAllOf fallback at most
--         every 2 s while none is held, filtered by full class path, world and no authority), holds it only as a weak
--         handle checked with the KismetSystemLibrary:IsValid UFunction, ignores it when its CoreVersion isn't this
--         core's, and decodes its State with the untrusted-input rules of net/state.lua.
--   standalone (the menu) and before the first world: nothing.
--
-- Shared variables (strings; <core> is the lowercase core name):
--   <core>.net.role      "none" | "standalone" | "host" | "client"
--   <core>.net.status    "ok" | "no-state" | "version"
--   <core>.net.snapshot  the clean values in State form (net/state.lua encode of what passed the checks)
--   <core>.net.gen       integer, +1 whenever any of the three changes (dependents re-read only then)
--
-- Values belong to the world they were published in: every LoadMap clears them. The loop is a 250 ms
-- LoopInGameThreadWithDelay started from core's LoadMap post-hook (never LoopAsync). No UObject is kept across ticks:
-- the actor and its class are weak handles, the world a path.
local BASE = (...):gsub("%.net%.host$", "")
local V = require(BASE .. ".version")
local S = require(BASE .. ".net.state")
local REF = require(BASE .. ".ref")
local clock = require(BASE .. ".clock")

local M = {}
M.REF = REF -- weak handles (tests replace it)

local NAME, LOWER = V.name, V.name:lower()
M.CLASS_PKG = "/Game/Mods/" .. NAME .. "/" .. NAME .. "Net"
M.CLASS_ASSET = NAME .. "Net_C"
M.CLASS = M.CLASS_PKG .. "." .. M.CLASS_ASSET
M.SHORT = M.CLASS_ASSET
M.SET_STATE = NAME .. "_NetSetState"
M.SET_VERSION = NAME .. "_NetSetVersion"
M.KEYS = { role = LOWER .. ".net.role", status = LOWER .. ".net.status", snapshot = LOWER .. ".net.snapshot", gen = LOWER .. ".net.gen" }
M.POLL_MS = 250
M.FIND_EVERY_US = 2000000 -- the FindAllOf fallback, at most this often while no actor is held
M.SPAWN_TRIES = 5
M.SPAWN_EVERY_US = 1000000
M.MAX_VERSION = 64 -- a longer replicated CoreVersion is never copied into Lua

local KSL_CDO = "/Script/Engine.Default__KismetSystemLibrary"
local KSL_ISVALID = "/Script/Engine.KismetSystemLibrary:IsValid"
local HELPERS = "/Script/AssetRegistry.Default__AssetRegistryHelpers"

local log = { info = function() end, warn = function() end, error = function() end, debug = function() end }
local setShared = function() end
local isHostFn -- env.isHost(world) -> boolean (map/setup.lua's cache), or nil: computed here
local now = function() return clock.micros() end
local allow -- the per-minute limiter (per key, or per actor for whole-state rejects)

local function q(s) return S.quote(s) end
local function firstLine(e) return (tostring(e):match("^[^\n]*")) end
local function try(f) local ok, v = pcall(f) if ok then return v end return nil end

-- Liveness: UE4SS's own gate first (a UObject wrapper, not null), then the UFunction, which checks the garbage flag.
local UOBJECT_WRAPPERS = { UObject = true, AActor = true, UClass = true, UStruct = true, UWorld = true }
function M.alive(o)
    if type(o) ~= "userdata" then return false end
    local okT, t = pcall(function() return o:type() end)
    if not (okT and type(t) == "string" and UOBJECT_WRAPPERS[t]) then return false end
    local okV, v = pcall(function() return o:IsValid() end)
    if not (okV and v == true) then return false end
    local ok, r = pcall(function() return StaticFindObject(KSL_ISVALID)(StaticFindObject(KSL_CDO), o) end)
    return ok and r == true
end
local function alive(o) return M.alive(o) end -- (tests replace M.alive)
local function pathOf(o) local full = o:GetFullName() return full:match("^%S+%s+(.+)$") or full end
-- A replicated FString's length without copying it (UE4SS FString:Len()); a Lua string's own. nil: unreadable.
local function lenOf(v)
    if type(v) == "string" then return #v end
    local ok, n = pcall(function() return v:Len() end)
    return ok and math.tointeger(n) or nil
end
local function str(v)
    if type(v) == "string" then return v end
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and type(s) == "string" and s or nil
end

-- ---------------------------------------------------------------- state
local gen = 0
local shared = { role = nil, status = nil, snapshot = nil }
-- W: this world. role, world (path), T (host: published values; client: last clean decode), actor (weak handle),
-- actorName, written (host: the State last written), wroteVersion, spawnTries, nextSpawn, nextFind, raw (client: the
-- State string last decoded), versionLogged, gone (the held actor went away)
local W = { role = "none" }
local clsRef -- weak handle on <Core>Net_C
local loop = { handle = nil, gen = 0 }

local function publishShared(role, status, snapshot)
    if role == shared.role and status == shared.status and snapshot == shared.snapshot then return end
    shared.role, shared.status, shared.snapshot = role, status, snapshot
    gen = gen + 1
    -- the gen goes last: a dependent that sees the new gen finds the new values
    setShared(M.KEYS.role, role)
    setShared(M.KEYS.status, status)
    setShared(M.KEYS.snapshot, snapshot)
    setShared(M.KEYS.gen, gen)
end
local function share()
    if W.role == "host" then publishShared("host", "ok", S.encode(W.T))
    elseif W.role == "client" then
        if W.status == "ok" then publishShared("client", "ok", S.encode(W.T))
        else publishShared("client", W.status or "no-state", "") end
    else publishShared(W.role or "none", "no-state", "") end
end

local function limited(key, fmt, ...)
    if allow and not allow(key) then return end
    pcall(log.warn, fmt, ...)
end

-- init{ log, setShared = fn(key, value), getShared = fn(key), isHost = fn(world) | nil, now = fn() | nil }
function M.init(env)
    env = env or {}
    if env.log then log = env.log end
    if type(env.setShared) == "function" then setShared = env.setShared end
    isHostFn = type(env.isHost) == "function" and env.isHost or nil
    if type(env.now) == "function" then now = env.now end
    allow = S.limiter(function() return now() end, 60000000, 256)
    -- A hot reload keeps the gen rising (shared variables outlive the state).
    local prev = env.getShared and math.tointeger(try(function() return env.getShared(M.KEYS.gen) end)) or nil
    gen = prev or 0
    W = { role = "none" }
    shared = {}
    share()
end

function M.role() return W.role end
function M.world() return W end

-- ---------------------------------------------------------------- the actor
local function netClass()
    if clsRef ~= nil then
        local c = try(function() return M.REF.deref(clsRef) end)
        if alive(c) then return c end
        pcall(M.REF.free, clsRef)
        clsRef = nil
    end
    local helpers = StaticFindObject(HELPERS)
    local okG, cls = pcall(function() return helpers:GetAsset({ PackageName = FName(M.CLASS_PKG), AssetName = FName(M.CLASS_ASSET) }) end)
    if not okG or not alive(cls) then return nil, okG and "not found" or firstLine(cls) end
    local okR, h = pcall(M.REF.ref, cls)
    if okR then clsRef = h end
    return cls
end

local function heldActor()
    if W.actor == nil then return nil end
    local a = try(function() return M.REF.deref(W.actor) end)
    if alive(a) then return a end
    pcall(M.REF.free, W.actor)
    W.actor, W.actorName = nil, nil
    W.gone = true
    return nil
end

local function forgetActor()
    if W.actor ~= nil then pcall(M.REF.free, W.actor) end
    W.actor, W.actorName = nil, nil
end

-- Host: writes CoreVersion once and State when it changed, through the Blueprint setters.
local function writeActor(a)
    if not W.wroteVersion then
        local ok, err = pcall(function() a[M.SET_VERSION](a, V.version) end)
        if not ok then limited("write:version", "NET could not set CoreVersion on %s: %s", tostring(W.actorName), firstLine(err)) return false end
        W.wroteVersion = true
    end
    local s = S.encode(W.T)
    if s == W.written then return true end
    local ok, err = pcall(function() a[M.SET_STATE](a, s) end)
    if not ok then limited("write:state", "NET could not set State on %s: %s", tostring(W.actorName), firstLine(err)) return false end
    W.written = s
    return true
end

local function spawn(world)
    W.spawnTries = (W.spawnTries or 0) + 1
    W.nextSpawn = now() + M.SPAWN_EVERY_US
    local cls, why = netClass()
    local a, err
    if cls then
        local okS, r = pcall(function() return world:SpawnActor(cls, { X = 0, Y = 0, Z = -50000 }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
        if okS and alive(r) then a = r else err = okS and "SpawnActor returned no actor" or firstLine(r) end
    else
        err = "class " .. M.CLASS .. " " .. tostring(why) .. " (is LogicMods/" .. NAME .. ".pak installed?)"
    end
    if not a then
        if W.spawnTries >= M.SPAWN_TRIES then
            if not W.spawnErrorLogged then
                W.spawnErrorLogged = true
                log.error("NET could not spawn %sNet in %s after %d tries: %s; modded clients get no published values in this world", NAME, tostring(W.world), W.spawnTries, err)
            end
        end
        return false
    end
    local okR, h = pcall(M.REF.ref, a)
    if not okR then
        W.spawnTries = M.SPAWN_TRIES -- no more tries in this world: each would leave another actor nothing holds
        log.error("NET spawned %sNet but could not take a weak handle (%s); no more tries in this world", NAME, firstLine(h))
        return false
    end
    W.actor, W.actorName = h, try(function() return a:GetFName():ToString() end) or "?"
    W.wroteVersion, W.written = false, nil
    writeActor(a)
    log.info("NET spawned %s in %s (host, try %d) replicates=%s alwaysRelevant=%s owner=%s state=%d bytes", W.actorName, tostring(W.world), W.spawnTries,
        tostring(try(function() return a.bReplicates end)), tostring(try(function() return a.bAlwaysRelevant end)),
        alive(try(function() return a:GetOwner() end)) and "set" or "none", #(W.written or ""))
    return true
end

-- ---------------------------------------------------------------- per world
-- The LoadMap post-hook (world: the loaded UWorld, or nil). Values are cleared; the role is decided once here.
function M.onLoadMap(world)
    forgetActor()
    local prevRole = W.role
    W = { role = "none", T = S.new(), status = "no-state" }
    share() -- the previous world's role and values are gone even if what follows fails
    if not alive(world) then
        log.info("NET LoadMap gave no world; role none")
        return
    end
    W.world = pathOf(world)
    local k = StaticFindObject(KSL_CDO)
    local server = k:IsServer(world) == true
    local standalone = k:IsStandalone(world) == true
    local host
    if isHostFn then
        local okH, h = pcall(isHostFn, world)
        host = okH and h == true or (not okH and server and not standalone)
    else
        host = server and not standalone
    end
    W.role = host and "host" or (standalone and "standalone" or (server and "standalone" or "client"))
    W.status = W.role == "host" and "ok" or "no-state"
    share()
    log.info("NET world %s role=%s (was %s)", W.world, W.role, tostring(prevRole))
    if W.role == "host" then spawn(world) end
end

-- ---------------------------------------------------------------- client side
local function classOk(a)
    local cp = try(function() return a:GetClass():GetFullName() end)
    return type(cp) == "string" and (cp == M.CLASS or cp:match("^%S+%s+(.+)$") == M.CLASS)
end
local function acceptable(a)
    if not alive(a) or not classOk(a) then return false end
    if try(function() return a:HasAuthority() end) ~= false then return false end -- a locally spawned one isn't the host's
    local wp = try(function() return pathOf(a:GetWorld()) end)
    return wp == W.world
end

-- NotifyOnNewObject: the object is still being constructed, so only a weak handle is taken; the tick checks it.
function M.onNewObject(obj)
    if W.role ~= "client" or W.actor ~= nil then return end
    local nm = try(function() return obj:GetFName():ToString() end)
    if type(nm) ~= "string" or nm:sub(1, 9) == "Default__" then return end
    local okR, h = pcall(M.REF.ref, obj)
    if okR then
        W.actor, W.actorName, W.fresh = h, nm, true
        log.info("NET %s created (NotifyOnNewObject); checking it on the next tick", nm)
    end
end

local function findFallback()
    local t = now()
    if W.nextFind and t < W.nextFind then return end
    W.nextFind = t + M.FIND_EVERY_US
    for _, a in ipairs(FindAllOf(M.SHORT) or {}) do
        if acceptable(a) then
            local okR, h = pcall(M.REF.ref, a)
            if okR then
                W.actor, W.actorName, W.fresh = h, try(function() return a:GetFName():ToString() end) or "?", false
                log.info("NET found %s by FindAllOf", W.actorName)
                return
            end
        end
    end
end

local function clientTick()
    local a = heldActor()
    if a and W.fresh ~= nil then
        -- first look at a newly held actor: it must be the host's, in this world
        if not acceptable(a) then
            log.info("NET %s is not the host's %sNet in this world (authority, class or world); ignored", tostring(W.actorName), NAME)
            forgetActor()
            a = nil
        else
            log.info("NET holding %s (%s) in %s us=%d", tostring(W.actorName), W.fresh and "NotifyOnNewObject" or "FindAllOf", tostring(W.world), now())
        end
        W.fresh = nil
    end
    if not a then
        if W.gone then
            W.gone = nil
            log.info("NET the host's %sNet went away; no state", NAME)
        end
        if W.status ~= "no-state" or W.raw ~= nil then
            W.status, W.raw, W.T = "no-state", nil, S.new()
            share()
        end
        findFallback()
        return
    end
    -- CoreVersion's length first too: a long one is never copied, only a short marker is compared.
    local rawVer = try(function() return a.CoreVersion end)
    local vn = lenOf(rawVer)
    local ver
    if vn ~= nil and vn > M.MAX_VERSION then ver = "<" .. vn .. " characters>" elseif vn ~= nil then ver = str(rawVer) end
    if ver == nil or ver == "" then
        -- not replicated yet
        if W.status ~= "no-state" then W.status, W.raw, W.T = "no-state", nil, S.new(); share() end
        return
    end
    if ver ~= V.version then
        if not W.versionLogged then
            W.versionLogged = true
            log.warn("NET ignoring the host's %s: its core version is '%s', this core is %s (versions must match exactly)", tostring(W.actorName), q(ver), V.version)
        end
        if W.status ~= "version" then W.status, W.raw, W.T = "version", nil, S.new(); share() end
        return
    end
    local raw = try(function() return a.State end)
    -- The length first: an oversized State is never copied into Lua (only a small marker is kept).
    local n = lenOf(raw)
    if n == nil or n > S.MAX_STATE then
        local marker = "<oversized " .. tostring(n) .. ">"
        if W.status == "ok" and W.raw == marker then return end
        W.raw = marker
        limited("actor:" .. tostring(W.actorName), "NET dropped from the host's State (%s): State is %s bytes, cap %d",
            q("actor:" .. tostring(W.actorName)), n and tostring(n) or "an unreadable number of", S.MAX_STATE)
        W.T, W.status = S.new(), "ok"
        share()
        return
    end
    local s = str(raw)
    if W.status == "ok" and s == W.raw then return end
    W.raw = s
    local T, rejects, whole = S.decode(s)
    for _, r in ipairs(rejects) do
        local key = whole and ("actor:" .. tostring(W.actorName)) or (r.key or "?")
        limited(key, "NET dropped from the host's State (%s): %s", q(key), r.why)
    end
    W.T, W.status = T, "ok"
    share()
end

-- ---------------------------------------------------------------- host side
local function hostTick()
    local a = heldActor()
    if a then writeActor(a) return end
    if W.gone then
        W.gone = nil
        limited("respawn", "NET this world's %sNet went away; spawning another", NAME)
        W.spawnTries = 0
    end
    if (W.spawnTries or 0) >= M.SPAWN_TRIES then return end
    if W.nextSpawn and now() < W.nextSpawn then return end
    if not W.world then return end
    -- The world exists while it is current (a miss would mean a full scan, so the tries are capped).
    local world = StaticFindObject(W.world)
    if not alive(world) then
        W.spawnTries = (W.spawnTries or 0) + 1
        W.nextSpawn = now() + M.SPAWN_EVERY_US
        return
    end
    spawn(world)
end

function M.tick()
    if W.role == "client" then clientTick()
    elseif W.role == "host" then hostTick() end
end

-- ---------------------------------------------------------------- the loop
function M.start()
    if loop.handle then return true end
    loop.gen = loop.gen + 1
    local mine = loop.gen
    local handle
    local ok, res = pcall(LoopInGameThreadWithDelay, M.POLL_MS, function()
        if mine ~= loop.gen then
            if handle then pcall(CancelDelayedAction, handle) end
            return
        end
        local okT, err = pcall(M.tick)
        if not okT then limited("tick", "NET tick failed: %s", firstLine(err)) end
    end)
    if ok and math.type(res) == "integer" then
        handle = res
        loop.handle = res
        return true
    end
    loop.gen = loop.gen + 1
    log.error("NET loop could not start: %s", ok and ("LoopInGameThreadWithDelay returned " .. tostring(res)) or firstLine(res))
    return false
end

function M.stop()
    loop.gen = loop.gen + 1
    if loop.handle then pcall(CancelDelayedAction, loop.handle) end
    loop.handle = nil
    forgetActor()
    if clsRef ~= nil then pcall(M.REF.free, clsRef) clsRef = nil end
end

function M.looping() return loop.handle ~= nil end

-- Core unloads: the shared variables say "no state" (with a new gen, so dependents notice).
function M.unload()
    W = { role = "none" }
    publishShared("none", "no-state", "")
end

-- ---------------------------------------------------------------- the channel op
-- net-publish:<key>=<value>. The payload comes from any mod in this process, so it is checked again in full; nothing
-- here raises. Replies: ok:published | ok:unchanged | err:<code> <detail> with code bad-request, client, standalone,
-- no-world or cap.
function M.op(payload)
    if type(payload) ~= "string" or payload == "" then return "err:bad-request net-publish needs <key>=<value>" end
    if #payload > S.MAX_KEY + 13 then return string.format("err:bad-request payload is %d bytes, cap %d", #payload, S.MAX_KEY + 13) end
    local key, val = payload:match("^([^=]+)=(.*)$")
    if not key then return "err:bad-request payload '" .. q(payload) .. "' has no '=' (want <key>=<value>)" end
    local id, name = S.splitKey(key)
    if not id then return "err:bad-request " .. name end
    local v = val:match("^%-?%d+$") and #val <= 11 and math.tointeger(tonumber(val)) or nil
    if v == nil or v < S.INT_MIN or v > S.INT_MAX then
        return string.format("err:bad-request value '%s' must be an integer in %d..%d", q(val), S.INT_MIN, S.INT_MAX)
    end
    if W.role == "client" then return "err:client only the host publishes (this machine is a client)" end
    if W.role == "standalone" then return "err:standalone no network game in this world" end
    if W.role ~= "host" then return "err:no-world no world loaded yet" end
    -- On a copy: nothing changes unless the whole publish fits.
    local T = S.copy(W.T)
    local ok, changed, why = S.put(T, id, name, v)
    if not ok then
        limited("publish:" .. key, "NET publish of %s refused: %s", q(key), tostring(why))
        return "err:cap " .. tostring(why)
    end
    if not changed then return "ok:unchanged" end
    -- The State must fit (it always does within the caps; checked anyway).
    local s = S.encode(T)
    if #s > S.MAX_STATE then
        log.error("NET State would be %d bytes, cap %d; %s not published", #s, S.MAX_STATE, q(key))
        return "err:cap State would be too large"
    end
    W.T = T
    share()
    local a = heldActor()
    if a then writeActor(a) end
    return "ok:published"
end

-- Test hooks (unit tests): the world table and a role set by hand.
function M._world() return W end
function M._setRole(role, worldPath)
    forgetActor()
    W = { role = role, T = S.new(), status = role == "host" and "ok" or "no-state", world = worldPath }
    share()
end

return M
