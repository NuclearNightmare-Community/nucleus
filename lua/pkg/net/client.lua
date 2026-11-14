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
-- A key is "<mod id>.<name>"; publish takes only this mod's own id (mod.json "id", normalized). Game thread only, after
-- connect. Caller bugs raise one clean error "<core>.net.<fn>: <problem>". Watchers run under pcall on the game thread,
-- from a 250 ms LoopInGameThreadWithDelay that runs only while a watch exists.
local BASE = (...):gsub("%.net%.client$", "")
local V = require(BASE .. ".version")
local S = require(BASE .. ".net.state")
local modid = require(BASE .. ".modid")
local json = require(BASE .. ".json")

local NAME, LOWER = V.name, V.name:lower()
local FN = LOWER .. ".net."
local KEYS = { role = LOWER .. ".net.role", status = LOWER .. ".net.status", snapshot = LOWER .. ".net.snapshot", gen = LOWER .. ".net.gen" }
local POLL_MS = 250
local MAX_WATCHES = 64
local MAX_MANIFEST = 65536

local M = {}
M.MAX_WATCHES = MAX_WATCHES

local B = { bound = false } -- call, log, id (own, normalized; nil when unknown), idWhy, micros
local cache = { gen = nil, role = "none", status = "no-state", T = nil }
local watches, order, nextId = {}, {}, 0
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

local function tickWatches()
    -- A copy: a watcher that unwatches must not shift the list under this loop.
    local list = { table.unpack(order) }
    for _, id in ipairs(list) do
        local w = watches[id]
        if w then runWatch(w) end
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
    if i == nil or not watches[i] then return false end
    watches[i] = nil
    for k, t in ipairs(order) do if t == i then table.remove(order, k) break end end
    if #order == 0 then stopPoll() end
    return true
end

function M.role(...)
    enter("role")
    if select("#", ...) > 0 then fail("role", "takes no arguments") end
    return current().role
end

-- The api table connect hands out (core.net).
M.API = { publish = M.publish, read = M.read, watch = M.watch, unwatch = M.unwatch, role = M.role }

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

-- ownId(modsDir, folder) -> normalized id | nil, why: mod.json "id" of Mods/<folder>/.
function M.ownId(modsDir, folder)
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
    return id
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
    poll = { gen = 0, running = false, handle = nil }
    allow = nil
end

return M
