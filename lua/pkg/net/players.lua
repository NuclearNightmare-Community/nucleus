-- core.net's player presence owner (core story 23, Net-2). Runs in core's Lua state only, on every machine, driven
-- from story 22's LoadMap reset and 250 ms loop (net/host.lua, main.lua). Pure parts are in net/presence.lua.
--
--   local list  this machine's (mod id, version[, netCompat]) pairs: core's own entry, then each connected dependent
--               that sent the channel op net-mod:<id>=<version>[/<netCompat>] (removed by net-mod-off:<id>), at most 32.
--   host        (isHost, story 22's role) one <Core>Presence per client connection's player controller, spawned here
--               and owned by that controller (SetOwner), CoreVersion set through its Blueprint setter. A modded client
--               calls the actor's reliable server RPC <Core>_SV_Report(Report); its Blueprint body checks Len(Report)
--               and calls <Core>_PresenceIn("", Len) when Len > 8192, else <Core>_PresenceIn(Report, Len), which this
--               state post-hooks. The reporting player is
--               the actor's owner's PlayerState (GetPlayerId), and only for an actor in this world's own table; never
--               anything in the report. Reports are rate-limited (1 per second, 10 per minute per player), validated
--               (net/presence.lua) and recorded against that PlayerId. A controller gone from
--               NetDriver.ClientConnections loses its record and its actor (K2_DestroyActor). The host's own record is
--               the local list; its own controller gets no actor.
--   client      finds its own <Core>Presence (NotifyOnNewObject + a FindAllOf fallback at most every 2 s, by full class
--               path, this world, no authority, owned by the local player controller), ignores it when its CoreVersion
--               isn't this core's (one line per world), and sends the local list once when it first holds it and again
--               2 s after any change to the list.
--   standalone  the local record only.
--
-- Shared variables: <core>.net.presence (net/presence.lua's snapshot: the local record first, then the clients' in
-- PlayerId order; "" when there is none: a client, or no world) and <core>.net.presence.gen (+1 per change).
-- Records belong to the host world: every LoadMap clears them. No UObject is kept across ticks: actors and the world
-- are weak handles plus their paths.
local BASE = (...):gsub("%.net%.players$", "")
local V = require(BASE .. ".version")
local P = require(BASE .. ".net.presence")
local S = require(BASE .. ".net.state")
local modid = require(BASE .. ".modid")
local REF = require(BASE .. ".ref")
local clock = require(BASE .. ".clock")

local M = {}
M.REF = REF -- weak handles (tests replace it)

local NAME, LOWER = V.name, V.name:lower()
M.CORE_ID = LOWER
M.CLASS_PKG = "/Game/Mods/" .. NAME .. "/" .. NAME .. "Presence"
M.CLASS_ASSET = NAME .. "Presence_C"
M.CLASS = M.CLASS_PKG .. "." .. M.CLASS_ASSET
M.SHORT = M.CLASS_ASSET
M.SET_VERSION = NAME .. "_PresenceSetVersion"
M.REPORT = NAME .. "_SV_Report"
M.IN_FN = NAME .. "_PresenceIn"
M.HOOK = M.CLASS .. ":" .. M.IN_FN
M.KEYS = { snapshot = LOWER .. ".net.presence", gen = LOWER .. ".net.presence.gen" }
M.RESEND_US = 2000000
M.FIND_EVERY_US = 2000000
M.CANDIDATE_US = 2000000
M.MAX_CANDIDATES = 16
M.SPAWN_TRIES = 5
M.SPAWN_EVERY_US = 1000000
M.MAX_VERSION = 64 -- a longer replicated CoreVersion is never copied into Lua
M.MAX_CONNECTIONS = 256 -- NetDriver.ClientConnections entries looked at per poll

local KSL_CDO = "/Script/Engine.Default__KismetSystemLibrary"
local KSL_ISVALID = "/Script/Engine.KismetSystemLibrary:IsValid"
local GSL_CDO = "/Script/Engine.Default__GameplayStatics"
local HELPERS = "/Script/AssetRegistry.Default__AssetRegistryHelpers"

local log = { info = function() end, warn = function() end, error = function() end, debug = function() end }
local setShared = function() end
local roleFn = function() return "none" end
local now = function() return clock.micros() end
local allow -- story 22's per-minute limiter (net/state.lua): one line per key per minute

local function q(s) return P.quote(s) end
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
local function nameOf(o) return try(function() return o:GetFName():ToString() end) or "?" end
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
local function limited(key, fmt, ...)
    if allow and not allow(key) then return end
    pcall(log.warn, fmt, ...)
end

-- ---------------------------------------------------------------- state
local localList = { { id = M.CORE_ID, version = V.version } }
local localGen = 0
local pgen = 0
local shared -- the snapshot last shared
-- W: this world. role, world (path), worldRef (weak handle), localPid;
--   host: clients (pcPath -> entry), byActor (actor path -> entry), count, records (PlayerId -> list), rate, capLogged
--   client: actor (weak handle), actorName, cands, nextFind, ignored, sent, sendAt
local W = { role = "none" }
local clsRef -- weak handle on <Core>Presence_C
local hook = { done = false, failedIn = nil }

local function share()
    local s
    if W.role == "host" then s = P.encodeSnapshot(W.localPid, localList, W.records)
    elseif W.role == "standalone" then s = P.encodeSnapshot(W.localPid, localList, nil)
    else s = "" end
    if s == shared then return end
    shared = s
    pgen = pgen + 1
    -- the gen goes last: a dependent that sees the new gen finds the new snapshot
    setShared(M.KEYS.snapshot, s)
    setShared(M.KEYS.gen, pgen)
end

-- init{ log, setShared = fn(key, value), getShared = fn(key), role = fn() -> story 22's role, now = fn() | nil }
function M.init(env)
    env = env or {}
    if env.log then log = env.log end
    if type(env.setShared) == "function" then setShared = env.setShared end
    if type(env.role) == "function" then roleFn = env.role end
    if type(env.now) == "function" then now = env.now end
    allow = S.limiter(function() return now() end, 60000000, 256)
    local prev = env.getShared and math.tointeger(try(function() return env.getShared(M.KEYS.gen) end)) or nil
    pgen = prev or 0
    localList = { { id = M.CORE_ID, version = V.version } }
    localGen = 0
    W = { role = "none" }
    shared = nil
    share()
end

function M.localList() return localList end
function M.world() return W end

-- ---------------------------------------------------------------- the local list (channel ops)
local function localChanged()
    localGen = localGen + 1
    if W.role == "client" and W.sent then W.sendAt = now() + M.RESEND_US end
    share()
end

-- net-mod:<id>=<version>[/<netCompat>] and net-mod-off:<id>. The payload comes from any mod in this process, so it is
-- checked in full; nothing here raises. Replies: ok:registered | ok:unchanged | ok:removed | ok:unknown |
-- err:bad-request <detail> | err:cap <detail>.
function M.op(op, payload)
    if op == "net-mod" then
        if type(payload) ~= "string" or payload == "" then return "err:bad-request net-mod needs <id>=<version>[/<netCompat>]" end
        if #payload > P.MAX_PAIR then return string.format("err:bad-request payload is %d bytes, cap %d", #payload, P.MAX_PAIR) end
        if not payload:find("=", 1, true) then return "err:bad-request payload '" .. q(payload) .. "' has no '=' (want <id>=<version>[/<netCompat>])" end
        local p, why = P.parsePair(payload)
        if not p then return "err:bad-request " .. why end
        if p.id == M.CORE_ID then return "err:bad-request '" .. p.id .. "' is core's own entry" end
        for i, e in ipairs(localList) do
            if e.id == p.id then
                if e.version == p.version and e.netCompat == p.netCompat then return "ok:unchanged" end
                localList[i] = p
                localChanged()
                return "ok:registered"
            end
        end
        if #localList >= P.MAX_PAIRS then return string.format("err:cap %d entries, cap %d", #localList, P.MAX_PAIRS) end
        localList[#localList + 1] = p
        localChanged()
        return "ok:registered"
    elseif op == "net-mod-off" then
        if type(payload) ~= "string" or payload == "" then return "err:bad-request net-mod-off needs <id>" end
        if #payload > modid.MAX then return string.format("err:bad-request payload is %d bytes, cap %d", #payload, modid.MAX) end
        if not modid.isNetId(payload) then return "err:bad-request '" .. q(payload) .. "' is not a normalized mod id" end
        if payload == M.CORE_ID then return "err:bad-request '" .. payload .. "' is core's own entry" end
        for i, e in ipairs(localList) do
            if e.id == payload then
                table.remove(localList, i)
                localChanged()
                return "ok:removed"
            end
        end
        return "ok:unknown"
    end
    return "err:bad-request unknown presence op"
end

-- ---------------------------------------------------------------- the world and the class
local function worldObj()
    if W.worldRef ~= nil then
        local w = try(function() return M.REF.deref(W.worldRef) end)
        if alive(w) then return w end
    end
    return nil
end

local function serverTime(world)
    local t = world and try(function() return world.GameState:GetServerWorldTimeSeconds() end)
    return type(t) == "number" and string.format("%.3f", t) or "?"
end

local function presenceClass()
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

local function readPid(pc)
    local ps = try(function() return pc.PlayerState end)
    if not alive(ps) then return nil end
    local id = math.tointeger(try(function() return ps:GetPlayerId() end))
    if id ~= nil and id >= P.INT_MIN and id <= P.INT_MAX then return id end
    return nil
end

local function refreshLocalPid(world)
    if W.localPid ~= nil then return end
    local pc = try(function() return StaticFindObject(GSL_CDO):GetPlayerController(world, 0) end)
    if not alive(pc) then return end
    local pid = readPid(pc)
    if pid ~= nil then
        W.localPid = pid
        log.info("PRESENCE local player %d (%s): %s", pid, W.role, P.encodeList(localList))
        share()
    end
end

-- ---------------------------------------------------------------- host: the report hook
-- The post-hook on <Core>_PresenceIn(Report, Len): (ctx, report, len) are UE4SS's hook parameters. Host only.
function M.onReport(ctx, report, len)
    if W.role ~= "host" then return end
    local a = try(function() return ctx:get() end)
    if not alive(a) then return end
    local path = try(function() return pathOf(a) end)
    local e = path and W.byActor and W.byActor[path]
    if not e then
        limited("presence:?", "PRESENCE ignored a report on %s: not one of this world's %sPresence actors", q(path), NAME)
        return
    end
    -- Identity: the owning connection's player state, read here; never anything in the report.
    local owner = try(function() return a:GetOwner() end)
    if not alive(owner) or try(function() return pathOf(owner) end) ~= e.pcPath then
        limited("presence:" .. e.pcPath, "PRESENCE ignored a report on %s: its owner is not %s any more", tostring(e.actorName), q(e.pcName))
        return
    end
    local pid = readPid(owner)
    if pid == nil then
        limited("presence:" .. e.pcPath, "PRESENCE ignored a report from %s: its player state has no PlayerId yet", q(e.pcName))
        return
    end
    e.pid = pid
    local key = "presence:" .. pid
    if not W.rate(pid) then
        limited(key, "PRESENCE rejected a report from player %d: more than 1 per second or %d per minute", pid, P.RATE_PER_MIN)
        return
    end
    local n = math.tointeger(try(function() return len:get() end))
    if n == nil or n < 0 or n > P.MAX_REPORT then
        limited(key, "PRESENCE rejected a report from player %d: %s characters, cap %d", pid, tostring(n), P.MAX_REPORT)
        return
    end
    local s = n == 0 and "" or str(try(function() return report:get() end))
    local list, rejects, whole = P.decodeReport(s)
    if whole then
        limited(key, "PRESENCE rejected a report from player %d: %s", pid, rejects[1] and rejects[1].why or "unreadable")
        return
    end
    if #rejects > 0 then
        limited(key, "PRESENCE dropped %d pair(s) from player %d's report: %s", #rejects, pid, q(rejects[1].why))
    end
    local old = W.records[pid]
    local ev = P.diff(old, list)
    W.records[pid] = list
    local nj, nc, nl = 0, 0, 0
    for _, x in ipairs(ev) do
        if x.event == "joined" then nj = nj + 1 elseif x.event == "changed" then nc = nc + 1 else nl = nl + 1 end
    end
    log.info("PRESENCE record player %d: %s (joined %d, changed %d, left %d) server=%s us=%d", pid, P.encodeList(list), nj, nc, nl, serverTime(worldObj()), now())
    share()
end

local function ensureHook()
    if hook.done or hook.failedIn == W.world then return end
    local ok, err = pcall(RegisterHook, M.HOOK, function(ctx, report, len)
        local okR, errR = pcall(M.onReport, ctx, report, len)
        if not okR then limited("hook", "PRESENCE report hook failed: %s", firstLine(errR)) end
    end)
    if ok then
        hook.done = true
        log.info("PRESENCE hooked %s", M.HOOK)
    else
        hook.failedIn = W.world
        log.error("PRESENCE could not hook %s: %s; reports from clients are not recorded in this world", M.HOOK, firstLine(err))
    end
end

-- ---------------------------------------------------------------- host: the per-poll reconcile
local function leave(e)
    local n = 0
    local rec = e.pid ~= nil and W.records[e.pid] or nil
    if rec then n = #rec; W.records[e.pid] = nil end
    local destroyed = "none"
    if e.actor ~= nil then
        local a = try(function() return M.REF.deref(e.actor) end)
        if alive(a) then
            local ok = pcall(function() a:K2_DestroyActor() end)
            destroyed = ok and tostring(e.actorName) or ("failed: " .. tostring(e.actorName))
        end
        pcall(M.REF.free, e.actor)
    end
    if e.actorPath then W.byActor[e.actorPath] = nil end
    W.clients[e.pcPath] = nil
    W.count = W.count - 1
    log.info("PRESENCE player %s left (%s): %d mod(s) removed%s; destroyed %s server=%s us=%d", e.pid ~= nil and tostring(e.pid) or "?", q(e.pcName), n,
        rec and (" (" .. P.encodeList(rec) .. ")") or "", destroyed, serverTime(worldObj()), now())
    share()
end

local function spawnFor(world, pc, e)
    if e.tries >= M.SPAWN_TRIES then return end
    if e.nextSpawn and now() < e.nextSpawn then return end
    e.tries = e.tries + 1
    e.nextSpawn = now() + M.SPAWN_EVERY_US
    local cls, why = presenceClass()
    local a, err
    if cls then
        local okS, r = pcall(function() return world:SpawnActor(cls, { X = 0, Y = 0, Z = -50000 }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
        if okS and alive(r) then a = r else err = okS and "SpawnActor returned no actor" or firstLine(r) end
    else
        err = "class " .. M.CLASS .. " " .. tostring(why) .. " (is LogicMods/" .. NAME .. ".pak installed?)"
    end
    if not a then
        if e.tries >= M.SPAWN_TRIES then
            log.error("PRESENCE could not spawn %sPresence for %s after %d tries: %s; that player is never reported", NAME, q(e.pcName), e.tries, err)
        end
        return
    end
    ensureHook()
    local okO, errO = pcall(function() a:SetOwner(pc) end)
    local okV, errV = pcall(function() a[M.SET_VERSION](a, V.version) end)
    local okR, h = pcall(M.REF.ref, a)
    if not okR or not okO or not okV then
        e.tries = M.SPAWN_TRIES -- one actor and one ERROR line per player
        pcall(function() a:K2_DestroyActor() end)
        log.error("PRESENCE spawned %sPresence for %s but could not %s (%s); destroyed it, that player is never reported", NAME, q(e.pcName),
            not okO and "set its owner" or (not okV and "set CoreVersion" or "take a weak handle"), firstLine(not okO and errO or (not okV and errV or h)))
        return
    end
    e.actor, e.actorName, e.actorPath = h, nameOf(a), try(function() return pathOf(a) end)
    if e.actorPath then W.byActor[e.actorPath] = e end
    local owner = try(function() return a:GetOwner() end)
    log.info("PRESENCE spawned %s for %s (player %s, try %d) replicates=%s alwaysRelevant=%s owner=%s server=%s us=%d", e.actorName, q(e.pcName),
        e.pid ~= nil and tostring(e.pid) or "?", e.tries, tostring(try(function() return a.bReplicates end)), tostring(try(function() return a.bAlwaysRelevant end)),
        alive(owner) and nameOf(owner) or "none", serverTime(world), now())
end

local function hostTick()
    local world = worldObj()
    if not world then return end
    refreshLocalPid(world)
    -- This poll's client controllers, by path (UObjects only within this tick).
    local seen, order = {}, {}
    local d = try(function() return world.NetDriver end)
    if alive(d) then
        local n = math.tointeger(try(function() return d.ClientConnections:GetArrayNum() end)) or 0
        for i = 1, math.min(n, M.MAX_CONNECTIONS) do
            local c = try(function() return d.ClientConnections[i] end)
            local pc = alive(c) and try(function() return c.PlayerController end) or nil
            if alive(pc) then
                local path = try(function() return pathOf(pc) end)
                if path and not seen[path] then seen[path] = pc; order[#order + 1] = path end
            end
        end
    end
    -- Leaves: a controller no longer in NetDriver.ClientConnections.
    local gone = {}
    for path, e in pairs(W.clients) do if not seen[path] then gone[#gone + 1] = e end end
    for _, e in ipairs(gone) do leave(e) end
    -- Joins and upkeep.
    for _, path in ipairs(order) do
        local pc = seen[path]
        local e = W.clients[path]
        if not e then
            if W.count >= P.MAX_RECORDS then
                if not W.capLogged then
                    W.capLogged = true
                    log.warn("PRESENCE %d client players already tracked in this world, cap %d; %s and later players are not reported", W.count, P.MAX_RECORDS, q(nameOf(pc)))
                end
            else
                e = { pcPath = path, pcName = nameOf(pc), tries = 0 }
                e.pid = readPid(pc)
                W.clients[path] = e
                W.count = W.count + 1
                log.info("PRESENCE saw controller %s (player %s) server=%s us=%d", q(e.pcName), e.pid ~= nil and tostring(e.pid) or "?", serverTime(world), now())
            end
        end
        if e then
            if e.pid == nil then e.pid = readPid(pc) end
            if e.actor ~= nil then
                local a = try(function() return M.REF.deref(e.actor) end)
                if not alive(a) then
                    pcall(M.REF.free, e.actor)
                    if e.actorPath then W.byActor[e.actorPath] = nil end
                    e.actor, e.actorPath = nil, nil
                    e.tries = 0
                    limited("respawn", "PRESENCE %s's %sPresence went away; spawning another", q(e.pcName), NAME)
                end
            end
            if e.actor == nil then spawnFor(world, pc, e) end
        end
    end
end

-- ---------------------------------------------------------------- client: find the own actor, send
local function forgetActor()
    if W.actor ~= nil then pcall(M.REF.free, W.actor) end
    W.actor, W.actorName = nil, nil
end
local function freeCands()
    for _, c in ipairs(W.cands or {}) do pcall(M.REF.free, c.h) end
    W.cands = {}
end

local function classOk(a)
    local cp = try(function() return a:GetClass():GetFullName() end)
    return type(cp) == "string" and (cp == M.CLASS or cp:match("^%S+%s+(.+)$") == M.CLASS)
end
-- Mine: the right class, in this world, not spawned here, owned by this machine's player controller.
local function mine(a, world)
    if not alive(a) or not classOk(a) then return false end
    if try(function() return a:HasAuthority() end) ~= false then return false end
    if try(function() return pathOf(a:GetWorld()) end) ~= W.world then return false end
    local owner = try(function() return a:GetOwner() end)
    if not alive(owner) then return false end
    local pc = try(function() return StaticFindObject(GSL_CDO):GetPlayerController(world, 0) end)
    if not alive(pc) then return false end
    local op, pp = try(function() return pathOf(owner) end), try(function() return pathOf(pc) end)
    return op ~= nil and op == pp
end

-- NotifyOnNewObject: the object is still being constructed, so only a weak handle is taken; the tick checks it.
function M.onNewObject(obj)
    if W.role ~= "client" or W.actor ~= nil or W.ignored then return end
    W.cands = W.cands or {}
    if #W.cands >= M.MAX_CANDIDATES then return end
    local nm = nameOf(obj)
    if nm:sub(1, 9) == "Default__" then return end
    local okR, h = pcall(M.REF.ref, obj)
    if okR then W.cands[#W.cands + 1] = { h = h, name = nm, at = now() } end
end

local function hold(a, how)
    local okR, h = pcall(M.REF.ref, a)
    if not okR then return false end
    W.actor, W.actorName = h, nameOf(a)
    log.info("PRESENCE holding %s (%s) in %s us=%d", W.actorName, how, tostring(W.world), now())
    return true
end

local function checkCands(world)
    local keep = {}
    for _, c in ipairs(W.cands or {}) do
        local a = try(function() return M.REF.deref(c.h) end)
        if W.actor == nil and alive(a) and mine(a, world) then
            pcall(M.REF.free, c.h)
            hold(a, "NotifyOnNewObject")
        elseif W.actor == nil and alive(a) and now() - c.at < M.CANDIDATE_US then
            keep[#keep + 1] = c -- its owner may not have replicated yet
        else
            pcall(M.REF.free, c.h)
        end
    end
    W.cands = keep
    if W.actor ~= nil then freeCands() end
end

local function findFallback(world)
    local t = now()
    if W.nextFind and t < W.nextFind then return end
    W.nextFind = t + M.FIND_EVERY_US
    for _, a in ipairs(FindAllOf(M.SHORT) or {}) do
        if mine(a, world) and hold(a, "FindAllOf") then return end
    end
end

local function heldActor()
    if W.actor == nil then return nil end
    local a = try(function() return M.REF.deref(W.actor) end)
    if alive(a) then return a end
    log.info("PRESENCE my %s went away", tostring(W.actorName))
    forgetActor()
    W.sent, W.sendAt = nil, nil -- a new actor gets the list again
    return nil
end

local function send(a, world, why)
    local report = P.encodeList(localList)
    -- The same checks as the host's, before sending.
    local _, rejects, whole = P.decodeReport(report)
    W.sent, W.sendAt = true, nil
    if whole or #rejects > 0 then
        log.error("PRESENCE the local list does not pass the report checks (%s); not sent", q(whole and rejects[1].why or rejects[1].why))
        return
    end
    local ok, err = pcall(function() a[M.REPORT](a, report) end)
    if not ok then
        W.sendAt = now() + M.RESEND_US -- try again in this world
        limited("send", "PRESENCE could not send the report on %s: %s; retrying in 2 s", tostring(W.actorName), firstLine(err))
        return
    end
    log.info("PRESENCE report sent (%s) on %s: %s server=%s us=%d", why, tostring(W.actorName), report, serverTime(world), now())
end

local function clientTick()
    if W.ignored then return end
    local world = worldObj()
    if not world then return end
    local a = heldActor()
    if not a then
        checkCands(world)
        a = heldActor()
        if not a then findFallback(world) a = heldActor() end
        if not a then return end
    end
    -- CoreVersion's length first: a long one is never copied, only a short marker is compared.
    local raw = try(function() return a.CoreVersion end)
    local vn = lenOf(raw)
    local ver
    if vn ~= nil and vn > M.MAX_VERSION then ver = "<" .. vn .. " characters>" elseif vn ~= nil then ver = str(raw) end
    if ver == nil or ver == "" then return end -- not replicated yet
    if ver ~= V.version then
        W.ignored = true
        log.warn("PRESENCE ignoring my %s: its core version is '%s', this core is %s (versions must match exactly); this machine does not report in this world",
            tostring(W.actorName), q(ver), V.version)
        forgetActor()
        freeCands()
        return
    end
    if not W.sent then send(a, world, "first")
    elseif W.sendAt and now() >= W.sendAt then send(a, world, "change") end
end

-- ---------------------------------------------------------------- per world, the tick, stop
local function forgetWorld()
    forgetActor()
    freeCands()
    for _, e in pairs(W.clients or {}) do if e.actor ~= nil then pcall(M.REF.free, e.actor) end end
    if W.worldRef ~= nil then pcall(M.REF.free, W.worldRef) end
end

-- The LoadMap post-hook, after story 22's (its role is this world's). Records are cleared.
function M.onLoadMap(world)
    forgetWorld()
    W = { role = "none", clients = {}, byActor = {}, count = 0, records = {}, cands = {} }
    share() -- the previous world's records are gone even if what follows fails
    if not alive(world) then return end
    W.world = try(function() return pathOf(world) end)
    local okR, h = pcall(M.REF.ref, world)
    if okR then W.worldRef = h end
    local role = try(roleFn)
    W.role = (role == "host" or role == "client" or role == "standalone") and role or "none"
    W.rate = P.rate(function() return now() end, 256)
    if W.role == "host" or W.role == "standalone" then refreshLocalPid(world) end
    share()
end

function M.tick()
    if W.role == "host" then hostTick()
    elseif W.role == "client" then clientTick()
    elseif W.role == "standalone" then
        local world = worldObj()
        if world then refreshLocalPid(world) end
    end
end

function M.stop()
    forgetWorld()
    W = { role = "none", clients = {}, byActor = {}, count = 0, records = {}, cands = {} }
    if clsRef ~= nil then pcall(M.REF.free, clsRef) clsRef = nil end
end

-- Core unloads: no presence (a new gen, so dependents notice).
function M.unload()
    W = { role = "none", clients = {}, byActor = {}, count = 0, records = {}, cands = {} }
    share()
end

-- Test hooks (unit tests).
function M._world() return W end
function M._hook() return hook end
function M._resetHook() hook = { done = false, failedIn = nil } end

return M
