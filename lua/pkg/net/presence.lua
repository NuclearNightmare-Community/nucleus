-- core.net's player presence (core story 23, Net-2): validation, the report and snapshot formats, the rate limit, the
-- record diff and the netCompat rule. Pure (no UE4SS): the one implementation the host (net/players.lua, after it
-- receives a report), a client (net/players.lua, before it sends one), each dependent (net/client.lua, reading core's
-- snapshot) and the unit tests share.
--
-- A pair is "<id>=<version>" or "<id>=<version>/<netCompat>": the id a normalized net id (modid.lua: namespaced, at
-- most 200 characters, or a legacy bare id), each version strict <major>.<minor>.<patch>, each part decimal 0..999
-- with no sign, no leading "+" and no leading zero. A netCompat above its version is a bad pair.
--
-- A report is comma-separated pairs, at most 32 pairs and 8192 bytes: more than either rejects the whole report. A bad
-- pair is dropped and the rest kept; on a duplicate id the first wins.
--
-- netCompat (2026-11-14): a mod's effective netCompat is the declared one, else the caret default (0.<minor>.0 for 0.x,
-- <major>.0.0 from 1.0). Two entries are compatible when each version is at least the other's effective netCompat.
--
-- The snapshot core shares with its dependents (<core>.net.presence): ";"-separated records, the first the local
-- machine's ("<PlayerId or ->:<report>"), then one "<PlayerId>:<report>" per client player, in PlayerId order.
local BASE = (...):gsub("%.net%.presence$", "")
local modid = require(BASE .. ".modid")

local M = {}

M.MAX_PAIRS = 32
M.MAX_REPORT = 8192
M.MAX_PART = 999
M.MAX_VERSION = 11 -- "999.999.999"
M.MAX_PAIR = modid.MAX + 1 + M.MAX_VERSION + 1 + M.MAX_VERSION
M.MAX_RECORDS = 64 -- client records the host keeps
M.MAX_SNAPSHOT = (M.MAX_RECORDS + 1) * (M.MAX_REPORT + 16)
M.INT_MIN = -2147483648
M.INT_MAX = 2147483647
M.RATE_GAP_US = 1000000 -- at most one report per player per second
M.RATE_PER_MIN = 10     -- and ten per player per minute
M.MINUTE_US = 60000000

local function q(s) return (tostring(s):sub(1, 64):gsub("[^%w%p ]", "?")) end
M.quote = q

-- ---------------------------------------------------------------- versions
-- parseVersion(s) -> { major, minor, patch } | nil, why
function M.parseVersion(s)
    if type(s) ~= "string" then return nil, "a version must be a string, got " .. type(s) end
    if #s > M.MAX_VERSION then return nil, "version '" .. q(s) .. "' is not <major>.<minor>.<patch>" end
    local a, b, c = s:match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil, "version '" .. q(s) .. "' is not <major>.<minor>.<patch>" end
    local out = {}
    for i, part in ipairs({ a, b, c }) do
        if #part > 3 or (#part > 1 and part:sub(1, 1) == "0") then
            return nil, "version '" .. q(s) .. "': each part is 0.." .. M.MAX_PART .. " with no leading zero"
        end
        out[i] = tonumber(part)
    end
    return { major = out[1], minor = out[2], patch = out[3] }
end

function M.isVersion(s) return M.parseVersion(s) ~= nil end

local function cmp(a, b)
    for _, k in ipairs({ "major", "minor", "patch" }) do
        if a[k] ~= b[k] then return a[k] < b[k] and -1 or 1 end
    end
    return 0
end

-- compareVersions(a, b) -> -1 | 0 | 1 (both must be valid)
function M.compareVersions(a, b) return cmp(assert(M.parseVersion(a)), assert(M.parseVersion(b))) end

-- defaultNetCompat(version) -> the caret default: "0.<minor>.0" for 0.x, "<major>.0.0" from 1.0. version must be valid.
function M.defaultNetCompat(version)
    local v = assert(M.parseVersion(version))
    if v.major == 0 then return "0." .. v.minor .. ".0" end
    return v.major .. ".0.0"
end

-- checkNetCompat(version, netCompat) -> true | nil, why. nil netCompat is fine (the default applies).
function M.checkNetCompat(version, netCompat)
    if netCompat == nil then return true end
    local v, whyV = M.parseVersion(version)
    if not v then return nil, whyV end
    local n, whyN = M.parseVersion(netCompat)
    if not n then return nil, "netCompat: " .. whyN end
    if cmp(n, v) > 0 then return nil, "netCompat " .. netCompat .. " is above version " .. version end
    return true
end

-- effectiveNetCompat(version, netCompat) -> the declared netCompat, else the caret default. Both must be valid.
function M.effectiveNetCompat(version, netCompat)
    if netCompat ~= nil then return netCompat end
    return M.defaultNetCompat(version)
end

-- compatible(aVersion, aNetCompat, bVersion, bNetCompat) -> boolean | nil, why. nil netCompat = the default.
function M.compatible(aV, aNC, bV, bNC)
    for _, x in ipairs({ { aV, aNC, "a" }, { bV, bNC, "b" } }) do
        local okV, whyV = M.parseVersion(x[1])
        if not okV then return nil, x[3] .. "Version: " .. whyV end
        if x[2] ~= nil and type(x[2]) ~= "string" then return nil, x[3] .. "NetCompat must be a string or nil, got " .. type(x[2]) end
        local okN, whyN = M.checkNetCompat(x[1], x[2])
        if not okN then return nil, x[3] .. "NetCompat: " .. whyN end
    end
    local a, b = M.parseVersion(aV), M.parseVersion(bV)
    local ea, eb = M.parseVersion(M.effectiveNetCompat(aV, aNC)), M.parseVersion(M.effectiveNetCompat(bV, bNC))
    return cmp(a, eb) >= 0 and cmp(b, ea) >= 0
end

-- ---------------------------------------------------------------- pairs and reports
-- checkPair(id, version, netCompat) -> true | nil, why
function M.checkPair(id, version, netCompat)
    if not modid.isNetId(id) then
        local _, why = modid.netId(id)
        return nil, "id '" .. q(id) .. "' is not a normalized mod id" .. (why and (" (" .. why .. ")") or "")
    end
    local okV, whyV = M.parseVersion(version)
    if not okV then return nil, id .. ": " .. whyV end
    local okN, whyN = M.checkNetCompat(version, netCompat)
    if not okN then return nil, id .. ": " .. whyN end
    return true
end

-- parsePair(entry) -> { id, version, netCompat } | nil, why
function M.parsePair(e)
    if type(e) ~= "string" then return nil, "a pair must be a string" end
    if #e > M.MAX_PAIR then return nil, string.format("pair is %d bytes, cap %d", #e, M.MAX_PAIR) end
    local id, rest = e:match("^([^=]*)=(.*)$")
    if not id then return nil, "pair '" .. q(e) .. "' has no '=' (want <id>=<version>[/<netCompat>])" end
    local version, nc = rest:match("^([^/]*)/(.*)$")
    if not version then version = rest end
    local ok, why = M.checkPair(id, version, nc)
    if not ok then return nil, why end
    return { id = id, version = version, netCompat = nc }
end

function M.encodePair(p) return p.id .. "=" .. p.version .. (p.netCompat and ("/" .. p.netCompat) or "") end

-- encodeList(list) -> report string
function M.encodeList(list)
    local out = {}
    for i, p in ipairs(list) do out[i] = M.encodePair(p) end
    return table.concat(out, ",")
end

-- decodeReport(s) -> list, rejects, whole. whole is true when the report as a whole was refused (list is then empty).
-- rejects: { { key, why } } (key: the pair's id when known, else "pair").
function M.decodeReport(s)
    local list, rejects = {}, {}
    if type(s) ~= "string" then return list, { { key = "*", why = "report is not a string (" .. type(s) .. ")" } }, true end
    if #s > M.MAX_REPORT then return list, { { key = "*", why = string.format("report is %d bytes, cap %d", #s, M.MAX_REPORT) } }, true end
    if #s == 0 then return list, rejects, false end
    local _, commas = s:gsub(",", ",")
    if commas + 1 > M.MAX_PAIRS then
        return list, { { key = "*", why = string.format("report has %d pairs, cap %d", commas + 1, M.MAX_PAIRS) } }, true
    end
    local seen = {}
    for e in (s .. ","):gmatch("([^,]*),") do
        local p, why = M.parsePair(e)
        if not p then
            rejects[#rejects + 1] = { key = "pair", why = why }
        elseif seen[p.id] then
            rejects[#rejects + 1] = { key = p.id, why = "duplicate id " .. p.id .. " (the first is kept)" }
        else
            seen[p.id] = true
            list[#list + 1] = p
        end
    end
    return list, rejects, false
end

-- toMap(list) -> id -> pair
function M.toMap(list)
    local m = {}
    for _, p in ipairs(list or {}) do m[p.id] = p end
    return m
end

-- diff(old, new) -> events { { event = "joined" | "changed" | "left", id, version, previous } }: old and new are lists
-- (or nil for none). In new's order, then old's for the left ones. Only a version change is "changed".
function M.diff(old, new)
    local ev = {}
    local om, nm = M.toMap(old), M.toMap(new)
    for _, p in ipairs(new or {}) do
        local o = om[p.id]
        if not o then ev[#ev + 1] = { event = "joined", id = p.id, version = p.version }
        elseif o.version ~= p.version then ev[#ev + 1] = { event = "changed", id = p.id, version = p.version, previous = o.version } end
    end
    for _, p in ipairs(old or {}) do
        if not nm[p.id] then ev[#ev + 1] = { event = "left", id = p.id, previous = p.version } end
    end
    return ev
end

-- ---------------------------------------------------------------- rate limit
-- rate(now, maxKeys) -> allow(key) -> boolean: at most one per key per second and ten per key per minute (every call
-- counts once it is allowed). now() -> integer microseconds. Bounded: past maxKeys, keys idle for a minute are dropped
-- first; if none are, a new key is refused.
function M.rate(now, maxKeys)
    maxKeys = maxKeys or 256
    local S, n = {}, 0
    return function(key)
        local t = now()
        local s = S[key]
        if not s then
            if n >= maxKeys then
                for k, v in pairs(S) do
                    if t - v.last >= M.MINUTE_US then S[k] = nil; n = n - 1 end
                end
                if n >= maxKeys then return false end
            end
            s = { last = nil, times = {} }
            S[key] = s
            n = n + 1
        end
        if s.last and t - s.last < M.RATE_GAP_US then return false end
        local kept = {}
        for _, x in ipairs(s.times) do if t - x < M.MINUTE_US then kept[#kept + 1] = x end end
        s.times = kept
        if #kept >= M.RATE_PER_MIN then return false end
        kept[#kept + 1] = t
        s.last = t
        return true
    end
end

-- ---------------------------------------------------------------- the snapshot (core -> its dependents)
local function pidOk(n) return math.type(n) == "integer" and n >= M.INT_MIN and n <= M.INT_MAX end

-- encodeSnapshot(localPid | nil, localList, records) -> string. records: PlayerId -> list.
function M.encodeSnapshot(localPid, localList, records)
    local out = { (localPid ~= nil and string.format("%d", localPid) or "-") .. ":" .. M.encodeList(localList or {}) }
    local pids = {}
    for pid in pairs(records or {}) do pids[#pids + 1] = pid end
    table.sort(pids)
    for _, pid in ipairs(pids) do out[#out + 1] = string.format("%d", pid) .. ":" .. M.encodeList(records[pid]) end
    return table.concat(out, ";")
end

-- decodeSnapshot(s) -> { localPid, localList, localMap, records = pid -> map, order = { pids } } | nil, why.
-- Untrusted the same way (a dependent re-checks what core shared): bad records are dropped.
function M.decodeSnapshot(s)
    local snap = { localPid = nil, localList = {}, localMap = {}, records = {}, order = {} }
    if s == nil or s == "" then return snap end
    if type(s) ~= "string" then return nil, "snapshot is not a string" end
    if #s > M.MAX_SNAPSHOT then return nil, string.format("snapshot is %d bytes, cap %d", #s, M.MAX_SNAPSHOT) end
    local i = 0
    for f in (s .. ";"):gmatch("([^;]*);") do
        i = i + 1
        if i > M.MAX_RECORDS + 1 then break end
        local p, rep = f:match("^([^:]*):(.*)$")
        local pid = p and p:match("^%-?%d+$") and #p <= 11 and math.tointeger(tonumber(p)) or nil
        if pid ~= nil and not pidOk(pid) then pid = nil end
        local list, _, whole = M.decodeReport(rep)
        if i == 1 then
            if p == "-" or pid ~= nil then
                snap.localPid = pid
                if not whole then snap.localList = list; snap.localMap = M.toMap(list) end
            end
        elseif pid ~= nil and not whole and not snap.records[pid] then
            snap.records[pid] = M.toMap(list)
            snap.order[#snap.order + 1] = pid
        end
    end
    return snap
end

-- recordOf(snap, pid) -> id -> pair | nil: a client's record, or the local machine's for its own PlayerId.
function M.recordOf(snap, pid)
    if type(snap) ~= "table" then return nil end
    if snap.records[pid] then return snap.records[pid] end
    if snap.localPid ~= nil and snap.localPid == pid then return snap.localMap end
    return nil
end

return M
