-- core.settings (Mod Manager story 5): the dependent side of core's settings service. Runs in the dependent's own Lua
-- state; core's state owns the values (settings/store.lua) and this module reaches it only through the channel ops
-- settings-get and settings-set and the shared integer <core>.settings.rev. It caches its own mod's values, refreshes
-- them when the revision moves, and calls its watchers for every live value that changed, whoever changed it.
--
-- Game thread only, after connect. Caller bugs (bad arguments, an unknown key or folder, a bad value) raise one clean
-- error "<core>.settings.<fn>: <problem>"; refusals by state come back as false, "<code> <detail>" (read-only, locked,
-- write-failed). Watchers run under pcall. The poll that calls them is a LoopInGameThreadWithDelay that runs only
-- while a watcher exists (never LoopAsync).
local BASE = (...):gsub("%.settings%.client$", "")
local V = require(BASE .. ".version")
local json = require(BASE .. ".json")

local NAME, LOWER = V.name, V.name:lower()
local FN = LOWER .. ".settings."
local REV_KEY = LOWER .. ".settings.rev"
local FOLDER = "^[A-Za-z0-9_-]+$"
local POLL_MS = 500
-- Replies describe up to 64 settings with every field: larger than a mod.json, so the reader's caps are raised here.
local REPLY_CAPS = { maxBytes = 262144, maxValues = 16384, maxDepth = 8 }

local M = {}

local B = { bound = false } -- call, log, folder (own; nil when unknown), mod
local cache = { rev = nil, values = nil, keys = nil, live = nil } -- own mod: key -> value, declared keys, live keys
local watchers, order, nextToken = {}, {}, 0
local poll = { gen = 0, running = false, handle = nil }

local function fail(fn, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    error(FN .. fn .. ": " .. (ok and msg or tostring(fmt)), 0)
end

local function q(s) return (tostring(s):sub(1, 64):gsub("[^%w%p ]", "?")) end

-- Off the game thread? The same probe as core.ui: <Core>_Deref of a never-issued handle refuses off the game thread.
local PROBE = (1 << 53) - 1
local function offGameThread()
    local deref = _G[NAME .. "_Deref"]
    if type(deref) ~= "function" then return false end
    local ok, err = pcall(deref, PROBE)
    return not ok and tostring(err):find("off the game thread", 1, true) ~= nil
end

local function enter(fn)
    if not B.bound then fail(fn, "called before connect") end
    if offGameThread() then fail(fn, "called off the game thread") end
end

local function needFolder(fn)
    if not B.folder then fail(fn, "own mod folder unknown") end
    return B.folder
end

local function checkFolder(fn, folder)
    if type(folder) ~= "string" then fail(fn, "folder must be a string, got %s", type(folder)) end
    if #folder < 1 or #folder > 64 or not folder:find(FOLDER) then fail(fn, "folder '%s' must match [A-Za-z0-9_-]{1,64}", q(folder)) end
end

local function checkKey(fn, key)
    if type(key) ~= "string" then fail(fn, "key must be a string, got %s", type(key)) end
    if #key < 1 or #key > 64 then fail(fn, "key '%s' must be 1 to 64 bytes", q(key)) end
end

local function readRev()
    local ok, v = pcall(function() return ModRef:GetSharedVariable(REV_KEY) end)
    return ok and math.tointeger(v) or nil
end

-- settings-get for a folder -> description | nil, code, detail
local function fetch(folder)
    local ok, reply = B.call("settings-get", folder)
    if not ok then
        local code, detail = tostring(reply):match("^err:(%S+)%s?(.*)$")
        return nil, code or "call-failed", code and detail or tostring(reply)
    end
    local desc, err = json.decode(reply, REPLY_CAPS)
    if type(desc) ~= "table" or json.isArray(desc) or not json.isArray(desc.settings) then
        return nil, "bad-reply", "settings-get reply: " .. tostring(desc == nil and err or "not a description")
    end
    return desc
end

-- Plain Lua tables from a decoded description: arrays as sequences without the marker, JSON null as nil.
local function plain(v)
    if v == json.null then return nil end
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = plain(x) end
    return t
end

local function callWatchers(changes)
    for _, c in ipairs(changes) do
        -- A copy: a watcher that unwatches (itself or another) must not shift the list under this loop.
        local snapshot = { table.unpack(order) }
        for _, tok in ipairs(snapshot) do
            local fn = watchers[tok]
            if fn then
                local ok, err = pcall(fn, c[1], c[2])
                if not ok and B.log then pcall(B.log.warn, "settings watcher %d failed for '%s': %s", tok, c[1], tostring(err):match("^[^\n]*")) end
            end
        end
    end
end

-- Refreshes the own cache from core; calls the watchers for every live key whose value changed. -> true | nil, code, detail
local function refresh()
    local rev = readRev()
    local desc, code, detail = fetch(B.folder)
    if not desc then return nil, code, detail end
    local values, keys, live, changes = {}, {}, {}, {}
    for _, e in ipairs(desc.settings) do
        if type(e) == "table" and type(e.key) == "string" then
            keys[e.key] = true
            local v = e.value
            if v == json.null then v = nil end
            values[e.key] = v
            live[e.key] = not e.readOnly and e.changeable ~= "restart"
        end
    end
    local old = cache.values
    cache.values, cache.keys, cache.live, cache.rev = values, keys, live, rev
    if old then
        for _, e in ipairs(desc.settings) do
            local k = type(e) == "table" and e.key
            if k and live[k] and old[k] ~= values[k] then changes[#changes + 1] = { k, values[k] } end
        end
        if #changes > 0 then callWatchers(changes) end
    end
    return true
end

-- The own cache, current: refreshed when it was never loaded or the revision moved. Raises for caller-visible
-- problems (no settings, core not answering).
local function current(fn)
    local folder = needFolder(fn)
    if cache.values == nil or readRev() ~= cache.rev then
        local ok, code, detail = refresh()
        if not ok then
            if code == "no-settings" then fail(fn, "%s declares no settings in its mod.json", folder) end
            fail(fn, "%s %s", tostring(code), q(detail))
        end
    end
    return cache
end

-- ---------------------------------------------------------------- the poll (only while a watcher exists)
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
    local gen = poll.gen
    local handle
    local ok, res = pcall(LoopInGameThreadWithDelay, POLL_MS, function()
        if gen ~= poll.gen then
            if handle then pcall(CancelDelayedAction, handle) end
            return
        end
        local okT, err = pcall(function()
            if B.folder and readRev() ~= cache.rev then
                local okR, code, detail = refresh()
                if not okR and not poll.warned then
                    poll.warned = true
                    if B.log then pcall(B.log.warn, "settings refresh failed: %s %s (further failures not logged)", tostring(code), q(detail)) end
                end
            end
        end)
        if not okT and not poll.warned then
            poll.warned = true
            if B.log then pcall(B.log.warn, "settings poll failed: %s (further failures not logged)", tostring(err):match("^[^\n]*")) end
        end
    end)
    if ok and math.type(res) == "integer" then
        handle = res
        poll.handle = res
    else
        poll.running = false
        if B.log then pcall(B.log.warn, "settings poll could not start: %s", ok and ("LoopInGameThreadWithDelay returned " .. tostring(res)) or tostring(res)) end
    end
end

-- ---------------------------------------------------------------- the API
local function encodeValue(fn, value)
    local t = type(value)
    if t == "number" then
        if value ~= value or value == math.huge or value == -math.huge then fail(fn, "value must be finite, got %s", tostring(value)) end
    elseif t ~= "boolean" and t ~= "string" then
        fail(fn, "value must be a boolean, number or string, got %s", t)
    end
    return value
end

local function doSet(fn, folder, key, value)
    encodeValue(fn, value)
    local payload, why = json.encodeFlat({ mod = folder, key = key, value = value }, { "mod", "key", "value" })
    if not payload then fail(fn, "value can't be sent: %s", why) end
    local ok, reply = B.call("settings-set", payload)
    if ok then
        if B.folder and folder:lower() == B.folder:lower() then
            -- Own value: refresh now, so get returns it and the watchers run before set returns.
            local okR = pcall(refresh)
            if not okR then cache.values = nil end
        end
        return true
    end
    local code, detail = tostring(reply):match("^err:(%S+)%s?(.*)$")
    if code == "read-only" or code == "locked" or code == "write-failed" then return false, code .. " " .. detail end
    if code == "unknown-key" then fail(fn, "unknown key %s", detail) end
    if code == "bad-value" then fail(fn, "bad value: %s", detail) end
    if code == "unknown-mod" or code == "no-settings" or code == "bad-request" then fail(fn, "%s %s", code, detail) end
    -- core not answering, or an unexpected reply: a refusal by state
    return false, (code or "call-failed") .. " " .. q(code and detail or reply)
end

function M.get(key, ...)
    enter("get")
    if select("#", ...) > 0 then fail("get", "takes 1 argument (key)") end
    checkKey("get", key)
    local c = current("get")
    if not c.keys[key] then fail("get", "unknown key '%s' (not declared in %s's mod.json)", q(key), B.folder) end
    return c.values[key]
end

function M.getAll(...)
    enter("getAll")
    if select("#", ...) > 0 then fail("getAll", "takes no arguments") end
    local c = current("getAll")
    local t = {}
    for k, v in pairs(c.values) do t[k] = v end
    return t
end

function M.set(key, value, ...)
    enter("set")
    if select("#", ...) > 0 then fail("set", "takes 2 arguments (key, value)") end
    checkKey("set", key)
    return doSet("set", needFolder("set"), key, value)
end

function M.setFor(folder, key, value, ...)
    enter("setFor")
    if select("#", ...) > 0 then fail("setFor", "takes 3 arguments (folder, key, value)") end
    checkFolder("setFor", folder)
    checkKey("setFor", key)
    return doSet("setFor", folder, key, value)
end

-- describe(folder) -> description | nil, "<code> <detail>" (unknown-mod, no-settings, or core not answering)
function M.describe(folder, ...)
    enter("describe")
    if select("#", ...) > 0 then fail("describe", "takes 1 argument (folder)") end
    checkFolder("describe", folder)
    local desc, code, detail = fetch(folder)
    if not desc then
        if code == "bad-request" then fail("describe", "%s %s", code, detail) end
        return nil, tostring(code) .. " " .. tostring(detail)
    end
    return plain(desc)
end

function M.watch(fn, ...)
    enter("watch")
    if type(fn) ~= "function" then fail("watch", "expected a function, got %s", type(fn)) end
    if select("#", ...) > 0 then fail("watch", "takes 1 argument (fn)") end
    needFolder("watch")
    -- Load the cache first, so the first change seen is a change, not the initial values.
    if cache.values == nil then pcall(refresh) end
    nextToken = nextToken + 1
    watchers[nextToken] = fn
    order[#order + 1] = nextToken
    startPoll()
    return nextToken
end

function M.unwatch(token, ...)
    enter("unwatch")
    if math.type(token) ~= "integer" then fail("unwatch", "token must be an integer, got %s", math.type(token) or type(token)) end
    if select("#", ...) > 0 then fail("unwatch", "takes 1 argument (token)") end
    if not watchers[token] then return false end
    watchers[token] = nil
    for i, t in ipairs(order) do if t == token then table.remove(order, i) break end end
    if #order == 0 then stopPoll() end
    return true
end

-- The api table connect hands out (core.settings).
M.API = { get = M.get, getAll = M.getAll, set = M.set, setFor = M.setFor, describe = M.describe, watch = M.watch, unwatch = M.unwatch }

-- Own folder: the first Mods/<Folder>/Scripts/ in the call stack's sources that isn't core's folder. -> folder | nil
function M.findFolder(skip)
    skip = skip or NAME
    for level = 2, 64 do
        local info = debug.getinfo(level, "S")
        if not info then break end
        local src = type(info.source) == "string" and info.source or ""
        for f in src:gmatch("[/\\][Mm]ods[/\\]([^/\\]+)[/\\][Ss]cripts[/\\]") do
            if f:lower() ~= skip:lower() and #f <= 64 and f:find(FOLDER) then return f end
        end
    end
    return nil
end

-- bind{ call, log, folder, mod }: called by connect once core answers.
function M.bind(b)
    B.call, B.log, B.folder, B.mod = b.call, b.log, b.folder, b.mod
    B.bound = true
end

-- Test hook: back to the unconnected state.
function M._reset()
    stopPoll()
    B = { bound = false }
    cache = { rev = nil, values = nil, keys = nil, live = nil }
    watchers, order, nextToken = {}, {}, 0
    poll = { gen = 0, running = false, handle = nil }
end

return M
