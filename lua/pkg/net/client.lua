-- core.net (core story 22, Net-1): the dependent side. Runs in the dependent's own Lua state. Core's state owns the
-- net state on every machine (net/host.lua); this module reads it from core's shared variables (role, status, a clean
-- snapshot, a generation counter) and publishes only through the channel op net-publish, so nothing from the net
-- reaches a dependent unchecked: the snapshot is decoded again here with the same rules, and every read applies the
-- reader's own bounds.
--
--   publish(key, value) -> true | false, "standalone" | false, "no-world"     host only; raises on a client
--   read(key, min, max) -> value | nil, "absent" | "out-of-bounds" | "no-state" | "version"
--   watch(key, min, max, fn) -> id      fn(value) or fn(nil, reason) at the first poll and whenever that result changes
--   unwatch(id) -> true | false
--   role() -> "none" | "standalone" | "host" | "client"
--
-- Core story 23 (Net-2, player presence; core's state keeps it in net/players.lua and shares it as a snapshot):
--   presence(player, modId) -> version | nil, "absent" | nil, "no-world"    host and standalone; raises on a client
--   watchPresence(modId, fn) -> id     fn(event, playerId, version, previous) for "joined" / "changed" / "left",
--                                      the local player included; the id works with unwatch
--   compatible(player, modId) -> true | false, "absent" | "incompatible" | "no-world"     like presence
--   versionsCompatible(aVersion, aNetCompat, bVersion, bNetCompat) -> boolean    pure (nil netCompat = the default)
-- player is a PlayerState object or its integer PlayerId.
--
-- A key is "<mod id>.<name>"; publish takes only this mod's own id (mod.json "id", normalized). Game thread only, after
-- connect. Caller bugs raise one clean error "<core>.net.<fn>: <problem>". Watchers run under pcall on the game thread,
-- from a 250 ms LoopInGameThreadWithDelay that runs only while a watch exists.
local BASE = (...):gsub("%.net%.client$", "")
local V = require(BASE .. ".version")
local S = require(BASE .. ".net.state")
local P = require(BASE .. ".net.presence")
local modid = require(BASE .. ".modid")
local json = require(BASE .. ".json")

local NAME, LOWER = V.name, V.name:lower()
local FN = LOWER .. ".net."
local KEYS = { role = LOWER .. ".net.role", status = LOWER .. ".net.status", snapshot = LOWER .. ".net.snapshot", gen = LOWER .. ".net.gen" }
local PKEYS = { snapshot = LOWER .. ".net.presence", gen = LOWER .. ".net.presence.gen" }
local POLL_MS = 250
local MAX_WATCHES = 64
local MAX_MANIFEST = 65536

local M = {}
M.MAX_WATCHES = MAX_WATCHES

local B = { bound = false } -- call, log, id (own, normalized; nil when unknown), idWhy, micros
local cache = { gen = nil, role = "none", status = "no-state", T = nil }
local watches, order, nextId = {}, {}, 0
-- story 23: presence watches (a cap of their own; ids from the same counter, so unwatch takes both)
local pwatches, porder = {}, {}
local pcache = { gen = nil, snap = nil }
local poll = { gen = 0, running = false, handle = nil }
local allow -- per key per minute

local function q(s) return S.quote(s) end
local function fail(fn, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    error(FN .. fn .. ": " .. (ok and msg or tostring(fmt)), 0)
end

-- Off the game thread? The same probe as core.ui and core.settings: <Core>_Deref of a never-issued handle refuses off
-- the game thread.
local PROBE = (1 << 53) - 1
local function offGameThread()
    local deref = _G[NAME .. "_Deref"]
    if type(deref) ~= "function" then return false end
    local ok, err = pcall(deref, PROBE)
    return not ok and tostring(err):find("off the game thread", 1, true) ~= nil
end
M._offGameThread = offGameThread

local function enter(fn)
    if not B.bound then fail(fn, "called before connect") end
    if M._offGameThread() then fail(fn, "called off the game thread") end
end

local function getShared(k)
    local ok, v = pcall(function() return ModRef:GetSharedVariable(k) end)
    if ok then return v end
    return nil
end
M._getShared = getShared

-- The current role, status and values, re-read only when core's generation moved.
local function current()
    local g = math.tointeger(M._getShared(KEYS.gen))
    if g ~= nil and g == cache.gen then return cache end
    local role, status, snap = M._getShared(KEYS.role), M._getShared(KEYS.status), M._getShared(KEYS.snapshot)
    if role ~= "host" and role ~= "client" and role ~= "standalone" then role = "none" end
    if status ~= "ok" and status ~= "version" then status = "no-state" end
    local T = nil
    if status == "ok" then
        local t, rejects, whole = S.decode(type(snap) == "string" and snap or "")
        T = t
        if (whole or #rejects > 0) and B.log then
            -- core already cleaned it; a reject here means a broken core, so say it (rate-limited)
            if not allow or allow("snapshot") then pcall(B.log.warn, "%s's net snapshot had %d bad entries; they are ignored", NAME, #rejects) end
        end
    end
    cache = { gen = g, role = role, status = status, T = T }
    return cache
end

-- Story 23: core's presence snapshot, decoded again here (the same rules), re-read only when its generation moved.
local function currentPresence()
    local g = math.tointeger(M._getShared(PKEYS.gen))
    if g ~= nil and g == pcache.gen and pcache.snap then return pcache.snap end
    local raw = M._getShared(PKEYS.snapshot)
    local snap, why = P.decodeSnapshot(type(raw) == "string" and raw or "")
    if not snap then
        if B.log and (not allow or allow("presence-snapshot")) then pcall(B.log.warn, "%s's presence snapshot is unreadable (%s); ignored", NAME, tostring(why)) end
        snap = P.decodeSnapshot("")
    end
    pcache = { gen = g, snap = snap }
    return snap
end

-- ---------------------------------------------------------------- argument checks
local function checkKey(fn, key)
    if type(key) ~= "string" then fail(fn, "key must be a string, got %s", type(key)) end
    local id, name = S.splitKey(key)
    if not id then fail(fn, "%s", name) end
    return id, name
end

local function checkBound(fn, which, v)
    if type(v) ~= "number" or math.tointeger(v) == nil then
        fail(fn, "%s must be an integer, got %s", which, type(v) == "number" and tostring(v) or type(v))
    end
    local i = math.tointeger(v)
    if i < S.INT_MIN or i > S.INT_MAX then fail(fn, "%s must be in %d..%d, got %s", which, S.INT_MIN, S.INT_MAX, tostring(v)) end
    return i
end

local function checkBounds(fn, min, max)
    local lo, hi = checkBound(fn, "min", min), checkBound(fn, "max", max)
    if lo > hi then fail(fn, "min %d is greater than max %d", lo, hi) end
    return lo, hi
end

-- read's result for checked arguments, with the out-of-bounds line (per key per minute).
local function result(key, lo, hi)
    local c = current()
    local v, why = S.readResult(c.status, c.T, key, lo, hi)
    if why == "out-of-bounds" and B.log and (not allow or allow("oob:" .. key)) then
        pcall(B.log.warn, "%s.net: %s = %s is outside this mod's bounds %d..%d; read as out-of-bounds", NAME, key, tostring(S.get(c.T, key)), lo, hi)
    end
    return v, why
end

-- ---------------------------------------------------------------- the poll (only while a watch exists)
local function runWatch(w)
    local v, why = result(w.key, w.min, w.max)
    if w.seen and w.v == v and w.why == why then return end
    w.seen, w.v, w.why = true, v, why
    local ok, err
    if v ~= nil then ok, err = pcall(w.fn, v) else ok, err = pcall(w.fn, nil, why) end
    if not ok and not w.faulted then
        w.faulted = true
        if B.log then pcall(B.log.warn, "%s.net watch %d (%s) failed: %s (further failures of this watch not logged)", NAME, w.id, w.key, tostring(err):match("^[^\n]*")) end
    end
end

-- Story 23: one presence watch. Its last view (PlayerId -> version) is diffed with the snapshot's whenever the
-- snapshot or the role moved; events in PlayerId order, joined and changed first, then left.
local function presenceView(modId)
    local view = {}
    local c = current()
    if c.role ~= "host" and c.role ~= "standalone" then return view end
    local snap = currentPresence()
    if snap.localPid ~= nil and snap.localMap[modId] then view[snap.localPid] = snap.localMap[modId].version end
    for pid, rec in pairs(snap.records) do
        if rec[modId] then view[pid] = rec[modId].version end
    end
    return view
end

local function runPresenceWatch(w)
    local c = current()
    currentPresence()
    local key = tostring(c.gen) .. "/" .. tostring(pcache.gen) .. "/" .. c.role
    if w.seen and w.key == key then return end
    w.key = key
    local view = presenceView(w.modId)
    local old = w.seen or {}
    w.seen = view
    local ev = {}
    for pid, v in pairs(view) do
        if old[pid] == nil then ev[#ev + 1] = { "joined", pid, v, nil }
        elseif old[pid] ~= v then ev[#ev + 1] = { "changed", pid, v, old[pid] } end
    end
    for pid, v in pairs(old) do
        if view[pid] == nil then ev[#ev + 1] = { "left", pid, nil, v } end
    end
    local rank = { joined = 1, changed = 1, left = 2 }
    table.sort(ev, function(a, b)
        if rank[a[1]] ~= rank[b[1]] then return rank[a[1]] < rank[b[1]] end
        return a[2] < b[2]
    end)
    for _, e in ipairs(ev) do
        if not pwatches[w.id] then return end -- unwatched by its own callback
        local ok, err = pcall(w.fn, e[1], e[2], e[3], e[4])
        if not ok and not w.faulted then
            w.faulted = true
            if B.log then pcall(B.log.warn, "%s.net presence watch %d (%s) failed: %s (further failures of this watch not logged)", NAME, w.id, w.modId, tostring(err):match("^[^\n]*")) end
        end
    end
end

local function tickWatches()
    -- A copy: a watcher that unwatches must not shift the list under this loop.
    local list = { table.unpack(order) }
    for _, id in ipairs(list) do
        local w = watches[id]
        if w then runWatch(w) end
    end
    local plist = { table.unpack(porder) }
    for _, id in ipairs(plist) do
        local w = pwatches[id]
        if w then runPresenceWatch(w) end
    end
end
M._tick = tickWatches

local function stopPoll()
    if not poll.running then return end
    poll.running = false
    poll.gen = poll.gen + 1
    if poll.handle then pcall(CancelDelayedAction, poll.handle) end
    poll.handle = nil
end

local function startPoll()
    if poll.running then return end
    poll.running = true
    poll.gen = poll.gen + 1
    local mine = poll.gen
    local handle
    local ok, res = pcall(LoopInGameThreadWithDelay, POLL_MS, function()
        if mine ~= poll.gen then
            if handle then pcall(CancelDelayedAction, handle) end
            return
        end
        local okT, err = pcall(tickWatches)
        if not okT and not poll.warned then
            poll.warned = true
            if B.log then pcall(B.log.warn, "%s.net poll failed: %s (further failures not logged)", NAME, tostring(err):match("^[^\n]*")) end
        end
    end)
    if ok and math.type(res) == "integer" then
        handle = res
        poll.handle = res
    else
        -- A loop registered with an unusable handle can't be cancelled: retire its generation so it stops working.
        poll.running = false
        poll.gen = poll.gen + 1
        if B.log then pcall(B.log.warn, "%s.net poll could not start: %s", NAME, ok and ("LoopInGameThreadWithDelay returned " .. tostring(res)) or tostring(res)) end
    end
end

-- ---------------------------------------------------------------- the API
function M.publish(key, value, ...)
    enter("publish")
    if select("#", ...) > 0 then fail("publish", "takes 2 arguments (key, value)") end
    local id = checkKey("publish", key)
    if not B.id then fail("publish", "this mod has no valid id in its mod.json (%s); it can read and watch, not publish", tostring(B.idWhy)) end
    if id ~= B.id then fail("publish", "key '%s' must start with this mod's own id '%s.'", q(key), B.id) end
    local v, why = S.checkInt(value)
    if v == nil then fail("publish", "value %s", why) end
    local role = current().role
    if role == "client" then fail("publish", "only the host publishes (this machine is a client)") end
    if role == "standalone" then return false, "standalone" end
    if role ~= "host" then return false, "no-world" end
    local ok, reply = B.call("net-publish", key .. "=" .. string.format("%d", v))
    if ok then return true end
    local code, detail = tostring(reply):match("^err:(%S+)%s?(.*)$")
    if code == "standalone" then return false, "standalone" end
    if code == "no-world" then return false, "no-world" end
    if code == "client" then fail("publish", "only the host publishes (this machine is a client)") end
    if code == "cap" then fail("publish", "%s", detail) end
    if code == "bad-request" then fail("publish", "%s", detail) end
    fail("publish", "%s did not take it: %s", NAME, q(reply))
end

function M.read(key, min, max, ...)
    enter("read")
    if select("#", ...) > 0 then fail("read", "takes 3 arguments (key, min, max)") end
    checkKey("read", key)
    local lo, hi = checkBounds("read", min, max)
    return result(key, lo, hi)
end

function M.watch(key, min, max, fn, ...)
    enter("watch")
    if select("#", ...) > 0 then fail("watch", "takes 4 arguments (key, min, max, fn)") end
    checkKey("watch", key)
    local lo, hi = checkBounds("watch", min, max)
    if type(fn) ~= "function" then fail("watch", "fn must be a function, got %s", type(fn)) end
    if #order >= MAX_WATCHES then fail("watch", "%d watches in this mod, cap %d", #order, MAX_WATCHES) end
    nextId = nextId + 1
    watches[nextId] = { id = nextId, key = key, min = lo, max = hi, fn = fn }
    order[#order + 1] = nextId
    startPoll()
    return nextId
end

function M.unwatch(id, ...)
    enter("unwatch")
    if type(id) ~= "number" then fail("unwatch", "id must be a number, got %s", type(id)) end
    if select("#", ...) > 0 then fail("unwatch", "takes 1 argument (id)") end
    local i = math.tointeger(id)
    if i == nil then return false end
    if watches[i] then
        watches[i] = nil
        for k, t in ipairs(order) do if t == i then table.remove(order, k) break end end
    elseif pwatches[i] then
        pwatches[i] = nil
        for k, t in ipairs(porder) do if t == i then table.remove(porder, k) break end end
    else
        return false
    end
    if #order == 0 and #porder == 0 then stopPoll() end
    return true
end

function M.role(...)
    enter("role")
    if select("#", ...) > 0 then fail("role", "takes no arguments") end
    return current().role
end

-- ---------------------------------------------------------------- presence (core story 23)
local KSL_CDO = "/Script/Engine.Default__KismetSystemLibrary"
local KSL_ISVALID = "/Script/Engine.KismetSystemLibrary:IsValid"
local PS_CLASS = "/Script/Engine.PlayerState"
local UOBJECT_WRAPPERS = { UObject = true, AActor = true, UClass = true, UStruct = true, UWorld = true }
-- Liveness: UE4SS's own gate, then the KismetSystemLibrary:IsValid UFunction (it checks the garbage flag).
function M._alive(o)
    if type(o) ~= "userdata" then return false end
    local okT, t = pcall(function() return o:type() end)
    if not (okT and type(t) == "string" and UOBJECT_WRAPPERS[t]) then return false end
    local okV, v = pcall(function() return o:IsValid() end)
    if not (okV and v == true) then return false end
    local ok, r = pcall(function() return StaticFindObject(KSL_ISVALID)(StaticFindObject(KSL_CDO), o) end)
    return ok and r == true
end
-- A UE4SS object value (userdata); tests replace it.
function M._isObjectValue(v) return type(v) == "userdata" end
-- A PlayerState (or a subclass)?
function M._isPlayerState(o)
    local ok, r = pcall(function() return o:IsA(StaticFindObject(PS_CLASS)) end)
    return ok and r == true
end

local function checkModId(fn, id)
    if type(id) ~= "string" then fail(fn, "modId must be a string, got %s", type(id)) end
    if id == "" then fail(fn, "modId is empty") end
    if #id > modid.MAX then fail(fn, "modId is %d characters, cap %d", #id, modid.MAX) end
    if not modid.isNetId(id) then
        fail(fn, "modId '%s' is not a normalized mod id (lowercase: a namespaced <owner>.<mod>, or a legacy bare id of up to %d characters)", q(id), modid.MAX_BARE)
    end
    return id
end

-- player (a PlayerState object or its integer PlayerId) -> PlayerId
local function playerId(fn, player)
    if type(player) == "number" then
        local i = math.tointeger(player)
        if i == nil then fail(fn, "player must be a PlayerState or an integer PlayerId, got %s", tostring(player)) end
        if i < P.INT_MIN or i > P.INT_MAX then fail(fn, "player id %d is outside %d..%d", i, P.INT_MIN, P.INT_MAX) end
        return i
    end
    if not M._isObjectValue(player) then fail(fn, "player must be a PlayerState or an integer PlayerId, got %s", type(player)) end
    if not M._alive(player) then fail(fn, "player is not a live object") end
    if not M._isPlayerState(player) then fail(fn, "player is not a PlayerState") end
    local ok, id = pcall(function() return player:GetPlayerId() end)
    local i = ok and math.tointeger(id) or nil
    if i == nil then fail(fn, "the player state's PlayerId can't be read") end
    return i
end

local function notOnClient(fn, role)
    if role == "client" then fail(fn, "only the host knows presence (this machine is a client)") end
end

function M.presence(player, modId, ...)
    enter("presence")
    if select("#", ...) > 0 then fail("presence", "takes 2 arguments (player, modId)") end
    local pid = playerId("presence", player)
    checkModId("presence", modId)
    local role = current().role
    notOnClient("presence", role)
    if role ~= "host" and role ~= "standalone" then return nil, "no-world" end
    local rec = P.recordOf(currentPresence(), pid)
    local e = rec and rec[modId]
    if not e then return nil, "absent" end
    return e.version
end

function M.watchPresence(modId, fn, ...)
    enter("watchPresence")
    if select("#", ...) > 0 then fail("watchPresence", "takes 2 arguments (modId, fn)") end
    checkModId("watchPresence", modId)
    if type(fn) ~= "function" then fail("watchPresence", "fn must be a function, got %s", type(fn)) end
    notOnClient("watchPresence", current().role)
    if #porder >= MAX_WATCHES then fail("watchPresence", "%d presence watches in this mod, cap %d", #porder, MAX_WATCHES) end
    nextId = nextId + 1
    pwatches[nextId] = { id = nextId, modId = modId, fn = fn }
    porder[#porder + 1] = nextId
    startPoll()
    return nextId
end

function M.compatible(player, modId, ...)
    enter("compatible")
    if select("#", ...) > 0 then fail("compatible", "takes 2 arguments (player, modId)") end
    local pid = playerId("compatible", player)
    checkModId("compatible", modId)
    local role = current().role
    notOnClient("compatible", role)
    if role ~= "host" and role ~= "standalone" then return false, "no-world" end
    local snap = currentPresence()
    local own = snap.localMap[modId]
    local rec = P.recordOf(snap, pid)
    local theirs = rec and rec[modId]
    if not own or not theirs then return false, "absent" end
    if P.compatible(own.version, own.netCompat, theirs.version, theirs.netCompat) == true then return true end
    return false, "incompatible"
end

local function checkVersionArg(which, v)
    if type(v) ~= "string" then fail("versionsCompatible", "%s must be a string, got %s", which, type(v)) end
    if not P.isVersion(v) then fail("versionsCompatible", "%s '%s' is not a strict <major>.<minor>.<patch> version (each part 0..%d)", which, q(v), P.MAX_PART) end
end

-- Pure: reads no core state, so it works anywhere (off the game thread too).
function M.versionsCompatible(aVersion, aNetCompat, bVersion, bNetCompat, ...)
    if select("#", ...) > 0 then fail("versionsCompatible", "takes 4 arguments (aVersion, aNetCompat, bVersion, bNetCompat)") end
    checkVersionArg("aVersion", aVersion)
    if aNetCompat ~= nil then checkVersionArg("aNetCompat", aNetCompat) end
    checkVersionArg("bVersion", bVersion)
    if bNetCompat ~= nil then checkVersionArg("bNetCompat", bNetCompat) end
    if not P.checkNetCompat(aVersion, aNetCompat) then fail("versionsCompatible", "aNetCompat %s is above aVersion %s", aNetCompat, aVersion) end
    if not P.checkNetCompat(bVersion, bNetCompat) then fail("versionsCompatible", "bNetCompat %s is above bVersion %s", bNetCompat, bVersion) end
    return P.compatible(aVersion, aNetCompat, bVersion, bNetCompat) == true
end

-- The api table connect hands out (core.net).
M.API = { publish = M.publish, read = M.read, watch = M.watch, unwatch = M.unwatch, role = M.role,
          presence = M.presence, watchPresence = M.watchPresence, compatible = M.compatible, versionsCompatible = M.versionsCompatible }

-- ---------------------------------------------------------------- the own id
-- findOwn(skip) -> modsDir, folder | nil: the first Mods/<Folder>/Scripts/ in the call stack's sources that isn't
-- core's own folder (connect's caller: the dependent's main.lua).
function M.findOwn(skip)
    skip = skip or NAME
    for level = 2, 64 do
        local info = debug.getinfo(level, "S")
        if not info then break end
        local src = type(info.source) == "string" and info.source:gsub("^@", "") or ""
        local dir, f = src:match("^(.*[/\\][Mm]ods)[/\\]([^/\\]+)[/\\][Ss]cripts[/\\]")
        if f and f:lower() ~= skip:lower() and #f <= 64 and f:find("^[A-Za-z0-9_-]+$") then return dir, f end
    end
    return nil
end

-- ownManifest(modsDir, folder) -> { id, version, netCompat, notes } | nil, why: mod.json "id" (normalized), and for
-- presence (story 23) "version" and "netCompat" of Mods/<folder>/. A version that isn't strict x.y.z is nil, and a
-- netCompat that is invalid or above the version is nil, each with a note for connect's one line.
function M.ownManifest(modsDir, folder)
    if type(modsDir) ~= "string" or type(folder) ~= "string" then return nil, "install folder unknown" end
    local f = io.open(modsDir .. "\\" .. folder .. "\\mod.json", "rb")
    if not f then return nil, "no Mods/" .. folder .. "/mod.json" end
    local text = f:read(MAX_MANIFEST + 1)
    f:close()
    if type(text) ~= "string" then return nil, "mod.json is empty" end
    if #text > MAX_MANIFEST then return nil, "mod.json is over " .. MAX_MANIFEST .. " bytes" end
    local root, err = json.decode(text, { maxBytes = MAX_MANIFEST })
    if type(root) ~= "table" then return nil, "mod.json does not parse (" .. tostring(err) .. ")" end
    local id, why = modid.netId(root.id)
    if not id then return nil, "mod.json id: " .. tostring(why) end
    local out = { id = id, notes = {} }
    local okV, whyV = P.parseVersion(root.version)
    if okV then out.version = root.version
    else out.notes[#out.notes + 1] = "mod.json version: " .. tostring(whyV) .. "; this mod is not reported to the host (presence)" end
    if root.netCompat ~= nil and out.version then
        local okN, whyN = false, "netCompat must be a string, got " .. type(root.netCompat)
        if type(root.netCompat) == "string" then okN, whyN = P.checkNetCompat(out.version, root.netCompat) end
        if okN then out.netCompat = root.netCompat
        else out.notes[#out.notes + 1] = "mod.json " .. tostring(whyN) .. "; netCompat left out (the default applies)" end
    end
    return out
end

-- ownId(modsDir, folder) -> normalized id | nil, why: mod.json "id" of Mods/<folder>/.
function M.ownId(modsDir, folder)
    local m, why = M.ownManifest(modsDir, folder)
    if not m then return nil, why end
    return m.id
end

-- bind{ call, log, id, idWhy, micros }: called by connect once core answers.
function M.bind(b)
    B = { bound = true, call = b.call, log = b.log, id = b.id, idWhy = b.idWhy }
    allow = type(b.micros) == "function" and S.limiter(b.micros, 60000000, 256) or nil
end

-- Test hook: back to the unconnected state.
function M._reset()
    stopPoll()
    B = { bound = false }
    cache = { gen = nil, role = "none", status = "no-state", T = nil }
    watches, order, nextId = {}, {}, 0
    pwatches, porder = {}, {}
    pcache = { gen = nil, snap = nil }
    poll = { gen = 0, running = false, handle = nil }
    allow = nil
end

return M
