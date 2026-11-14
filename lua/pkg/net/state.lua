-- core.net's state (core story 22, Net-1): validation, caps, and the replicated State string. Pure (no UE4SS): the one
-- implementation the host (net/host.lua, before it writes), a client (net/host.lua, after it reads the net), each
-- dependent (net/client.lua, reading core's snapshot) and the unit tests share.
--
-- A key is "<mod id>.<name>" split at the last dot: the mod id is a normalized net id (modid.lua: namespaced, at most
-- 200 characters, or a legacy bare id), the name [A-Za-z0-9_]{1,32}. A value is an integer in -2^31..2^31-1 (a float
-- with an exact integer value counts). Caps: 16 keys per mod, 64 keys in all, 16 mods, State at most 8192 bytes.
--
-- State: comma-separated entries, a header "#<n>=<mod id>" per publishing mod (n = 1..16, in first-publish order on the
-- host, per world) and "<n>.<name>=<int>" per value. The numbers exist only on the wire: decode maps them through the
-- headers of the same string, and a table always speaks full keys.
--
-- Everything read from the net is untrusted. decode drops: the whole string when it is not a string or is over 8192
-- bytes; a header with a bad number or an id not already in normalized form (and every entry of that number); a
-- value entry whose number has no header; a bad name or value; entries past a cap; duplicates after the first (headers
-- and keys alike); anything else. Each drop comes back as a reject { key, why } for the caller's rate-limited log.
local BASE = (...):gsub("%.net%.state$", "")
local modid = require(BASE .. ".modid")

local M = {}

M.MAX_STATE = 8192
M.MAX_PER_MOD = 16
M.MAX_KEYS = 64
M.MAX_MODS = 16
M.MAX_NAME = 32
M.MAX_KEY = modid.MAX + 1 + M.MAX_NAME
M.INT_MIN = -2147483648
M.INT_MAX = 2147483647
M.MAX_REJECTS = 32 -- rejects reported per decode (the rest only counted)

local function q(s) return (tostring(s):sub(1, 64):gsub("[^%w%p ]", "?")) end
M.quote = q

-- ---------------------------------------------------------------- checks
-- checkName(name) -> true | nil, why
function M.checkName(name)
    if type(name) ~= "string" then return nil, "name must be a string, got " .. type(name) end
    if #name < 1 or #name > M.MAX_NAME or not name:match("^[A-Za-z0-9_]+$") then
        return nil, string.format("name '%s' must match [A-Za-z0-9_]{1,%d}", q(name), M.MAX_NAME)
    end
    return true
end

-- splitKey(key) -> id, name | nil, why. The id must already be a normalized net id (lowercase, no github.com/ prefix).
function M.splitKey(key)
    if type(key) ~= "string" then return nil, "key must be a string, got " .. type(key) end
    if #key > M.MAX_KEY then return nil, string.format("key is %d bytes, cap %d", #key, M.MAX_KEY) end
    local id, name = key:match("^(.+)%.([^.]*)$")
    if not id then return nil, "key '" .. q(key) .. "' must be <mod id>.<name>" end
    local okN, whyN = M.checkName(name)
    if not okN then return nil, whyN end
    if not modid.isNetId(id) then
        local _, why = modid.netId(id)
        return nil, "key '" .. q(key) .. "': mod id '" .. q(id) .. "' is not a normalized mod id" .. (why and (" (" .. why .. ")") or "")
    end
    return id, name
end

-- checkInt(v) -> integer | nil, why: an integer, or a float with an exact integer value, in -2^31..2^31-1.
function M.checkInt(v)
    if type(v) ~= "number" then return nil, "must be an integer, got " .. type(v) end
    if v ~= v then return nil, "must be an integer, got NaN" end
    if v == math.huge or v == -math.huge then return nil, "must be an integer, got " .. tostring(v) end
    local i = math.tointeger(v)
    if i == nil then return nil, "must be an integer, got " .. tostring(v) end
    if i < M.INT_MIN or i > M.INT_MAX then return nil, string.format("must be in %d..%d, got %s", M.INT_MIN, M.INT_MAX, tostring(v)) end
    return i
end

-- ---------------------------------------------------------------- the table
-- new() -> T: T.order = mod ids in first-publish order; T.mods[id] = { names = {...}, vals = { name -> int } }; T.count
function M.new() return { order = {}, mods = {}, count = 0 } end

-- put(T, id, name, value) -> true, changed | nil, code, why. id, name and value must already be checked. code "cap".
function M.put(T, id, name, value)
    local m = T.mods[id]
    if m and m.vals[name] ~= nil then
        local changed = m.vals[name] ~= value
        m.vals[name] = value
        return true, changed
    end
    if not m and #T.order >= M.MAX_MODS then return nil, "cap", string.format("%d publishing mods in this world, cap %d", #T.order, M.MAX_MODS) end
    if m and #m.names >= M.MAX_PER_MOD then return nil, "cap", string.format("%s has %d keys, cap %d per mod", q(id), #m.names, M.MAX_PER_MOD) end
    if T.count >= M.MAX_KEYS then return nil, "cap", string.format("%d keys in this world, cap %d", T.count, M.MAX_KEYS) end
    if not m then
        m = { names = {}, vals = {} }
        T.mods[id] = m
        T.order[#T.order + 1] = id
    end
    m.names[#m.names + 1] = name
    m.vals[name] = value
    T.count = T.count + 1
    return true, true
end

-- get(T, key) -> integer | nil
function M.get(T, key)
    if type(T) ~= "table" or type(key) ~= "string" then return nil end
    local id, name = key:match("^(.+)%.([^.]*)$")
    local m = id and T.mods[id]
    return m and m.vals[name] or nil
end

-- copy(T) -> a deep copy
function M.copy(T)
    local c = M.new()
    for _, id in ipairs(T.order) do
        local m = T.mods[id]
        for _, n in ipairs(m.names) do M.put(c, id, n, m.vals[n]) end
    end
    return c
end

-- encode(T) -> State string (mods in order, numbered 1..n; a mod without values is left out)
function M.encode(T)
    local out, n = {}, 0
    for _, id in ipairs(T.order) do
        local m = T.mods[id]
        if #m.names > 0 then
            n = n + 1
            out[#out + 1] = "#" .. n .. "=" .. id
            for _, name in ipairs(m.names) do out[#out + 1] = n .. "." .. name .. "=" .. string.format("%d", m.vals[name]) end
        end
    end
    return table.concat(out, ",")
end

-- ---------------------------------------------------------------- decode (untrusted input)
-- decode(s) -> T, rejects, whole. whole is true when the string as a whole was refused (T is then empty).
function M.decode(s)
    local T, rejects, dropped = M.new(), {}, 0
    local function reject(key, why)
        if #rejects < M.MAX_REJECTS then rejects[#rejects + 1] = { key = key, why = why } else dropped = dropped + 1 end
    end
    if type(s) ~= "string" then reject("*", "State is not a string (" .. type(s) .. ")") return T, rejects, true end
    if #s > M.MAX_STATE then reject("*", string.format("State is %d bytes, cap %d", #s, M.MAX_STATE)) return T, rejects, true end
    if #s == 0 then return T, rejects, false end
    local entries = {}
    for e in (s .. ","):gmatch("([^,]*),") do entries[#entries + 1] = e end
    -- Pass 1: headers. A number is taken by its first header, valid or not (a bad header poisons its number).
    local ids, seenNum, seenId = {}, {}, {}
    for _, e in ipairs(entries) do
        if e:sub(1, 1) == "#" then
            local num, id = e:match("^#(%d+)=(.*)$")
            local n = num and #num <= 2 and num:sub(1, 1) ~= "0" and tonumber(num) or nil
            if not n or n < 1 or n > M.MAX_MODS then
                reject("header", "bad header '" .. q(e) .. "'")
            elseif seenNum[n] then
                reject("header:" .. n, "duplicate header #" .. n .. " (the first is kept)")
            else
                seenNum[n] = true
                if not modid.isNetId(id) then
                    reject("header:" .. n, "header #" .. n .. " id '" .. q(id) .. "' is not a normalized mod id; it and its entries are dropped")
                elseif seenId[id] then
                    reject(id, "mod id '" .. q(id) .. "' has a second header #" .. n .. "; dropped")
                else
                    seenId[id] = true
                    ids[n] = id
                end
            end
        end
    end
    -- Pass 2: values, in order (the caps keep the first ones).
    for _, e in ipairs(entries) do
        if e:sub(1, 1) ~= "#" then
            local num, name, val = e:match("^(%d+)%.([^=]*)=(.*)$")
            local id = num and #num <= 2 and num:sub(1, 1) ~= "0" and ids[tonumber(num)] or nil
            if not num then
                if e ~= "" then reject("garbage", "unreadable entry '" .. q(e) .. "'") end
            elseif not id then
                reject("entry:" .. q(num), "entry '" .. q(e) .. "' has no header for its number")
            elseif not M.checkName(name) then
                reject(id .. ".?", "entry '" .. q(e) .. "': bad name")
            else
                local key = id .. "." .. name
                local v = val:match("^%-?%d+$") and #val <= 11 and math.tointeger(tonumber(val)) or nil
                if v == nil or v < M.INT_MIN or v > M.INT_MAX then
                    reject(key, "value '" .. q(val) .. "' is not an integer in range")
                elseif T.mods[id] and T.mods[id].vals[name] ~= nil then
                    reject(key, "duplicate key (the first is kept)")
                else
                    local ok, _, why = M.put(T, id, name, v)
                    if not ok then reject(key, why) end
                end
            end
        end
    end
    if dropped > 0 then rejects[#rejects + 1] = { key = "*more", why = dropped .. " more rejected entries" } end
    return T, rejects, false
end

-- ---------------------------------------------------------------- reads
-- readResult(status, T, key, min, max) -> value | nil, reason ("no-state", "version", "absent", "out-of-bounds").
-- status: "ok" | "no-state" | "version" (anything else reads as no-state). Arguments must already be checked.
function M.readResult(status, T, key, min, max)
    if status == "version" then return nil, "version" end
    if status ~= "ok" or type(T) ~= "table" then return nil, "no-state" end
    local v = M.get(T, key)
    if v == nil then return nil, "absent" end
    if v < min or v > max then return nil, "out-of-bounds" end
    return v
end

-- ---------------------------------------------------------------- rate limit
-- limiter(now, periodUs, maxKeys) -> allow(key) -> boolean: true at most once per key per period. now() -> integer
-- microseconds. The table is bounded: past maxKeys, expired keys are dropped first; if none have expired the new key
-- is refused (no line) until some do.
function M.limiter(now, periodUs, maxKeys)
    periodUs, maxKeys = periodUs or 60000000, maxKeys or 256
    local last, n = {}, 0
    return function(key)
        local t = now()
        local prev = last[key]
        if prev ~= nil then
            if t - prev < periodUs then return false end
            last[key] = t
            return true
        end
        if n >= maxKeys then
            for k, v in pairs(last) do
                if t - v >= periodUs then last[k] = nil; n = n - 1 end
            end
            if n >= maxKeys then return false end
        end
        last[key] = t
        n = n + 1
        return true
    end
end

return M
