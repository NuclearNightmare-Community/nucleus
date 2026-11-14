-- A small, strict, bounded JSON reader and writer (Mod Manager story 5, core's settings service). One parser for
-- mod.json, the settings values files and the settings channel's payloads and replies. Never runs data as code (no
-- load/loadfile) and never raises: every problem is a return value.
--
-- decode(text, caps) -> value, orders | nil, "<line>:<col> <reason>"
--   Strict RFC 8259: one value, only space/tab/LF/CR as whitespace (a leading UTF-8 byte order mark is ignored, which
--   RFC 8259 allows); duplicate keys, trailing commas, comments, NaN/Infinity, leading zeros, control characters in
--   strings, invalid UTF-8 and lone surrogates are errors. JSON null is M.null (so a key with null is still present).
--   Arrays are Lua sequences marked with M.ARRAY as metatable; objects are plain tables, and orders[object] is the list
--   of its keys in document order. Integers without a fraction or exponent that fit 64 bits are Lua integers; other
--   numbers are floats and must be finite.
--   Caps (caps overrides each one; the defaults are the mod.json/values-file caps): maxBytes 65,536 input bytes,
--   maxDepth 16 nested arrays/objects, maxValues 4,096 values in all (keys not counted), maxString 1,024 bytes per
--   string after unescaping (keys included).
-- encodeFlat(t, keys) -> text | nil, reason
--   A flat object with the string keys in the given order (missing keys skipped); values boolean, finite number
--   (integers as integers) or string.
-- encode(v, orders) -> text | nil, reason
--   Any value decode can return (M.null, booleans, finite numbers, strings, M.ARRAY sequences, objects with string
--   keys); an object's keys in orders[object] order, then any others sorted. Depth at most 32.
local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end, __newindex = function() error("json.null is read-only", 2) end })
M.ARRAY = { __name = "json.array" }
M.CAPS = { maxBytes = 65536, maxDepth = 16, maxValues = 4096, maxString = 1024 }

function M.isArray(t) return type(t) == "table" and getmetatable(t) == M.ARRAY end
function M.array(t) return setmetatable(t or {}, M.ARRAY) end

-- ---------------------------------------------------------------- reader
local byte, sub, find, char = string.byte, string.sub, string.find, string.char

local function utf8char(cp)
    if cp < 0x80 then return char(cp) end
    if cp < 0x800 then return char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)) end
    if cp < 0x10000 then return char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)) end
    return char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
end

-- Checks one run of raw (unescaped) bytes for valid UTF-8 (no overlongs, no encoded surrogates, at most U+10FFFF).
-- Returns nil, or the offset of the first bad byte within s.
local function badUtf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = byte(s, i)
        if c < 0x80 then i = i + 1
        else
            local need, lo, hi
            if c >= 0xC2 and c <= 0xDF then need, lo, hi = 1, 0x80, 0xBF
            elseif c == 0xE0 then need, lo, hi = 2, 0xA0, 0xBF
            elseif c == 0xED then need, lo, hi = 2, 0x80, 0x9F
            elseif c >= 0xE1 and c <= 0xEF then need, lo, hi = 2, 0x80, 0xBF
            elseif c == 0xF0 then need, lo, hi = 3, 0x90, 0xBF
            elseif c >= 0xF1 and c <= 0xF3 then need, lo, hi = 3, 0x80, 0xBF
            elseif c == 0xF4 then need, lo, hi = 3, 0x80, 0x8F
            else return i end
            local c2 = byte(s, i + 1)
            if not c2 or c2 < lo or c2 > hi then return i end
            for k = 2, need do
                local ck = byte(s, i + k)
                if not ck or ck < 0x80 or ck > 0xBF then return i end
            end
            i = i + need + 1
        end
    end
    return nil
end

function M.decode(text, caps)
    if type(text) ~= "string" then return nil, "1:1 expected a string to decode, got " .. type(text) end
    local C = M.CAPS
    if type(caps) == "table" then
        C = {}
        for k, v in pairs(M.CAPS) do C[k] = (math.type(caps[k]) == "integer" and caps[k] > 0) and caps[k] or v end
    end
    local function where(pos)
        local line, col = 1, 1
        local p = 1
        while true do
            local nl = find(text, "\n", p, true)
            if not nl or nl >= pos then break end
            line = line + 1
            p = nl + 1
        end
        col = pos - p + 1
        return line .. ":" .. col
    end
    if #text > C.maxBytes then return nil, "1:1 input is " .. #text .. " bytes, cap " .. C.maxBytes end
    local pos = 1
    if sub(text, 1, 3) == "\239\187\191" then pos = 4 end
    local values = 0
    local orders = {}
    local fail -- set to the error message; parse functions then unwind returning nil

    local function err(p, msg) if not fail then fail = where(p) .. " " .. msg end return nil end

    local function skip()
        local _, e = find(text, "^[ \t\r\n]*", pos)
        pos = e + 1
    end

    local parseValue

    local function parseString()
        -- pos is at the opening quote
        local start = pos
        pos = pos + 1
        local parts, len = {}, 0
        while true do
            local s, e = find(text, '^[^"\\\0-\31]*', pos)
            local run = sub(text, s, e)
            if #run > 0 then
                local bad = badUtf8(run)
                if bad then return err(pos + bad - 1, "invalid UTF-8 in a string") end
                len = len + #run
                if len > C.maxString then return err(start, "string is longer than " .. C.maxString .. " bytes") end
                parts[#parts + 1] = run
            end
            pos = e + 1
            local c = byte(text, pos)
            if c == nil then return err(start, "unterminated string") end
            if c == 34 then pos = pos + 1; break end -- "
            if c ~= 92 then return err(pos, "control character in a string") end -- not a backslash: a byte below 0x20
            local esc = sub(text, pos + 1, pos + 1)
            local out
            if esc == '"' then out = '"' elseif esc == "\\" then out = "\\" elseif esc == "/" then out = "/"
            elseif esc == "b" then out = "\b" elseif esc == "f" then out = "\f" elseif esc == "n" then out = "\n"
            elseif esc == "r" then out = "\r" elseif esc == "t" then out = "\t"
            elseif esc == "u" then
                local hex = sub(text, pos + 2, pos + 5)
                if not find(hex, "^%x%x%x%x$") then return err(pos, "bad \\u escape") end
                local cp = tonumber(hex, 16)
                local used = 6
                if cp >= 0xD800 and cp <= 0xDBFF then
                    local lo = sub(text, pos + 6, pos + 11)
                    local lhex = lo:match("^\\u(%x%x%x%x)$")
                    local lcp = lhex and tonumber(lhex, 16)
                    if not lcp or lcp < 0xDC00 or lcp > 0xDFFF then return err(pos, "lone surrogate in a \\u escape") end
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lcp - 0xDC00)
                    used = 12
                elseif cp >= 0xDC00 and cp <= 0xDFFF then
                    return err(pos, "lone surrogate in a \\u escape")
                end
                out = utf8char(cp)
                pos = pos + used
            else
                return err(pos, "bad escape")
            end
            if esc ~= "u" then pos = pos + 2 end
            len = len + #out
            if len > C.maxString then return err(start, "string is longer than " .. C.maxString .. " bytes") end
            parts[#parts + 1] = out
        end
        return table.concat(parts)
    end

    local function parseNumber()
        local s, e = find(text, "^-?%d+", pos)
        if not s then return err(pos, "unexpected character") end
        local intPart = sub(text, s, e)
        if find(intPart, "^-?0%d") then return err(pos, "leading zero in a number") end
        local isInt = true
        local p = e + 1
        local fs, fe = find(text, "^%.%d+", p)
        if fs then isInt = false; p = fe + 1
        elseif sub(text, p, p) == "." then return err(p, "bad number") end
        local es, ee = find(text, "^[eE][+-]?%d+", p)
        if es then isInt = false; p = ee + 1
        elseif find(text, "^[eE]", p) then return err(p, "bad number") end
        local raw = sub(text, pos, p - 1)
        local start = pos
        pos = p
        if isInt then
            local n = math.tointeger(tonumber(raw))
            -- tonumber gives a float when the digits don't fit 64 bits; keep it only when finite
            if n and tostring(n) == (raw:gsub("^%-0$", "0")) then return n end
        end
        local f = tonumber(raw)
        if not f or f ~= f or f == math.huge or f == -math.huge then return err(start, "number out of range") end
        return f + 0.0
    end

    local function parseArray(depth)
        local start = pos
        pos = pos + 1
        local arr = setmetatable({}, M.ARRAY)
        skip()
        if byte(text, pos) == 93 then pos = pos + 1; return arr end -- ]
        while true do
            local v = parseValue(depth)
            if fail then return nil end
            arr[#arr + 1] = v
            skip()
            local c = byte(text, pos)
            if c == 44 then -- ,
                pos = pos + 1
                skip()
                if byte(text, pos) == 93 then return err(pos, "trailing comma") end
            elseif c == 93 then pos = pos + 1; return arr
            elseif c == nil then return err(start, "unterminated array")
            else return err(pos, "expected ',' or ']'") end
        end
    end

    local function parseObject(depth)
        local start = pos
        pos = pos + 1
        local obj, keys = {}, {}
        orders[obj] = keys
        skip()
        if byte(text, pos) == 125 then pos = pos + 1; return obj end -- }
        while true do
            if byte(text, pos) ~= 34 then
                if byte(text, pos) == nil then return err(start, "unterminated object") end
                return err(pos, "expected a string key")
            end
            local kpos = pos
            local k = parseString()
            if fail then return nil end
            if obj[k] ~= nil then return err(kpos, "duplicate key") end
            skip()
            if byte(text, pos) ~= 58 then return err(pos, "expected ':'") end -- :
            pos = pos + 1
            local v = parseValue(depth)
            if fail then return nil end
            obj[k] = v
            keys[#keys + 1] = k
            skip()
            local c = byte(text, pos)
            if c == 44 then
                pos = pos + 1
                skip()
                if byte(text, pos) == 125 then return err(pos, "trailing comma") end
            elseif c == 125 then pos = pos + 1; return obj
            elseif c == nil then return err(start, "unterminated object")
            else return err(pos, "expected ',' or '}'") end
        end
    end

    parseValue = function(depth)
        skip()
        values = values + 1
        if values > C.maxValues then return err(pos, "more than " .. C.maxValues .. " values") end
        local c = byte(text, pos)
        if c == nil then return err(pos, "unexpected end of input") end
        if c == 123 or c == 91 then -- { [
            if depth >= C.maxDepth then return err(pos, "nested deeper than " .. C.maxDepth) end
            if c == 123 then return parseObject(depth + 1) end
            return parseArray(depth + 1)
        end
        if c == 34 then return parseString() end
        if c == 116 then if sub(text, pos, pos + 3) == "true" then pos = pos + 4 return true end return err(pos, "unexpected character") end
        if c == 102 then if sub(text, pos, pos + 4) == "false" then pos = pos + 5 return false end return err(pos, "unexpected character") end
        if c == 110 then if sub(text, pos, pos + 3) == "null" then pos = pos + 4 return M.null end return err(pos, "unexpected character") end
        if c == 45 or (c >= 48 and c <= 57) then return parseNumber() end
        if c == 47 then return err(pos, "comments are not allowed") end
        return err(pos, "unexpected character")
    end

    local ok, v = pcall(parseValue, 0)
    if not ok then return nil, where(pos) .. " internal error: " .. tostring(v):sub(1, 64) end
    if fail then return nil, fail end
    skip()
    if pos <= #text then
        if byte(text, pos) == 47 then return nil, where(pos) .. " comments are not allowed" end
        return nil, where(pos) .. " unexpected text after the value"
    end
    return v, orders
end

-- ---------------------------------------------------------------- writer
local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function encString(s)
    return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", byte(c)) end) .. '"'
end

-- Finite numbers only; integers as integers, floats in the shortest form that reads back exactly.
local function encNumber(n)
    if math.type(n) == "integer" then return string.format("%d", n) end
    if n ~= n or n == math.huge or n == -math.huge then return nil end
    for _, f in ipairs({ "%.15g", "%.16g", "%.17g" }) do
        local s = string.format(f, n)
        if tonumber(s) == n then return s end
    end
    return string.format("%.17g", n)
end
M.encodeNumber = encNumber

local function scalar(v)
    local t = type(v)
    if t == "boolean" then return v and "true" or "false" end
    if t == "string" then return encString(v) end
    if t == "number" then local s = encNumber(v) if not s then return nil, "a number that isn't finite" end return s end
    if v == M.null then return "null" end
    return nil, "a " .. t
end

function M.encodeFlat(t, keys)
    if type(t) ~= "table" or type(keys) ~= "table" then return nil, "encodeFlat needs a table and a key list" end
    local parts = {}
    for _, k in ipairs(keys) do
        if type(k) ~= "string" then return nil, "a key that isn't a string" end
        local v = t[k]
        if v ~= nil then
            if type(v) == "table" then return nil, "key '" .. k .. "' holds a table" end
            local s, why = scalar(v)
            if not s then return nil, "key '" .. k .. "' holds " .. why end
            parts[#parts + 1] = encString(k) .. ":" .. s
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function M.encode(v, orders)
    orders = orders or {}
    local function enc(x, depth)
        if depth > 32 then return nil, "nested deeper than 32" end
        if type(x) ~= "table" or x == M.null then return scalar(x) end
        local parts = {}
        if M.isArray(x) then
            for i = 1, #x do
                local s, why = enc(x[i], depth + 1)
                if not s then return nil, why end
                parts[i] = s
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local seen, keys = {}, {}
        for _, k in ipairs(orders[x] or {}) do if x[k] ~= nil and not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
        local rest = {}
        for k in pairs(x) do
            if type(k) ~= "string" then return nil, "an object key that isn't a string" end
            if not seen[k] then rest[#rest + 1] = k end
        end
        table.sort(rest)
        for _, k in ipairs(rest) do keys[#keys + 1] = k end
        for _, k in ipairs(keys) do
            local s, why = enc(x[k], depth + 1)
            if not s then return nil, why end
            parts[#parts + 1] = encString(k) .. ":" .. s
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    local ok, s, why = pcall(enc, v, 0)
    if not ok then return nil, "internal error: " .. tostring(s):sub(1, 64) end
    return s, why
end

return M
