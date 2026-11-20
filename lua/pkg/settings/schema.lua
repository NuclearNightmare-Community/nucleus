-- Settings declarations (Mod Manager story 5): reads a mod's mod.json text into its declared settings, and checks
-- values against a declaration. Pure Lua, no I/O, never raises. Used by core's settings store (core's state only).
--
-- parse(text, folder) -> manifest | nil, problem
--   manifest = { id, name, hasSettings, settings = { decl, ... in declaration order }, byKey = { key -> decl },
--   problems = { strings } }. nil only when the text isn't a JSON object (problem says why). A bad settings entry is
--   left out with one problem naming the folder and the key; the rest of the mod still works.
-- check(decl, value) -> value' | nil, reason: value' is the value to keep (an integral float becomes an integer for
--   an int setting).
local json = require((...):gsub("%.settings%.schema$", "") .. ".json")

local M = {}

M.MAX_SETTINGS = 64
M.TYPES = { bool = true, int = true, number = true, enum = true }
M.CHANGEABLE = { anytime = true, menu = true, lobby = true, restart = true }
M.SCOPES = { client = true, host = true, both = true }
M.KEY = "^[A-Za-z][A-Za-z0-9_.]*$"
M.MAX_KEY = 64

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
M.finite = finite

-- Printable, at most 64 bytes: for problems and error details that echo untrusted text.
local function q(s) return (tostring(s):sub(1, 64):gsub("[^%w%p ]", "?")) end
M.quote = q

M.MAX_PROBLEM = 256 -- bytes per problem string in a description

-- cut(s, max) -> s, at most max bytes, cut at a UTF-8 character boundary (never in the middle of a character).
function M.cut(s, max)
    s = tostring(s)
    if #s <= max then return s end
    local i = max
    while i > 0 do
        local b = s:byte(i + 1)
        if not b or b < 0x80 or b > 0xBF then break end -- the byte after the cut starts a character
        i = i - 1
    end
    return s:sub(1, i)
end

function M.validKey(k) return type(k) == "string" and #k >= 1 and #k <= M.MAX_KEY and k:find(M.KEY) ~= nil end

function M.check(d, v)
    if d.type == "bool" then
        if type(v) ~= "boolean" then return nil, "must be true or false" end
        return v
    elseif d.type == "int" then
        if type(v) ~= "number" then return nil, "must be an integer" end
        local i = math.tointeger(v)
        if not i or not finite(v) then return nil, "must be an integer" end
        if (d.min and i < d.min) or (d.max and i > d.max) then
            return nil, string.format("must be from %s to %s", tostring(d.min or "-inf"), tostring(d.max or "inf"))
        end
        return i
    elseif d.type == "number" then
        if type(v) ~= "number" or not finite(v) then return nil, "must be a finite number" end
        if (d.min and v < d.min) or (d.max and v > d.max) then
            return nil, string.format("must be from %s to %s", tostring(d.min or "-inf"), tostring(d.max or "inf"))
        end
        return v
    elseif d.type == "enum" then
        if type(v) ~= "string" or not d.valueSet[v] then return nil, "must be one of " .. table.concat(d.values, "|") end
        return v
    end
    return nil, "unknown type"
end

local function str(v, max) return type(v) == "string" and #v <= max end

-- One declaration -> decl | nil, why.
local function entry(key, e)
    if not M.validKey(key) then return nil, "key must match [A-Za-z][A-Za-z0-9_.]{0,63}" end
    if type(e) ~= "table" or json.isArray(e) or e == json.null then return nil, "not an object" end
    local d = { key = key }
    if not M.TYPES[e.type] then return nil, "type must be bool, int, number or enum" end
    d.type = e.type
    if d.type == "int" or d.type == "number" then
        for _, b in ipairs({ "min", "max" }) do
            local v = e[b]
            if v ~= nil and v ~= json.null then
                if d.type == "int" then
                    if math.type(v) ~= "integer" then return nil, b .. " must be an integer" end
                elseif not finite(v) then return nil, b .. " must be a finite number" end
                d[b] = v
            end
        end
        if d.min and d.max and d.min > d.max then return nil, "min is above max" end
        if d.type == "number" and e.step ~= nil and e.step ~= json.null then
            if not finite(e.step) or e.step <= 0 then return nil, "step must be a number above 0" end
            d.step = e.step
        end
    elseif d.type == "enum" then
        local vals = e.values
        if not json.isArray(vals) or #vals < 1 or #vals > 32 then return nil, "values must be a list of 1 to 32 strings" end
        d.values, d.valueSet = {}, {}
        for i, s in ipairs(vals) do
            if not str(s, 64) or #s == 0 then return nil, "values[" .. i .. "] must be a string of 1 to 64 bytes" end
            if d.valueSet[s] then return nil, "values has '" .. q(s) .. "' twice" end
            d.valueSet[s] = true
            d.values[i] = s
        end
    end
    if e.label ~= nil then
        if not str(e.label, 64) then return nil, "label must be a string of at most 64 bytes" end
        d.label = e.label
    else d.label = key end
    if e.help ~= nil then
        if not str(e.help, 256) then return nil, "help must be a string of at most 256 bytes" end
        d.help = e.help
    end
    if e.changeable ~= nil then
        if not M.CHANGEABLE[e.changeable] then return nil, "changeable must be anytime, menu, lobby or restart" end
        d.changeable = e.changeable
    else d.changeable = "restart" end
    if e.scope ~= nil then
        if not M.SCOPES[e.scope] then return nil, "scope must be client, host or both" end
        d.scope = e.scope
    end
    if e.source ~= nil then
        if not str(e.source, 32) or #e.source == 0 then return nil, "source must be a string of 1 to 32 bytes" end
        d.source = e.source
    end
    -- default: of the type and within bounds; null (or missing) only with a source.
    if e.default == nil or e.default == json.null then
        if not d.source then return nil, "default is missing (null is allowed only with source)" end
    else
        local v, why = M.check(d, e.default)
        if v == nil then return nil, "default " .. why end
        d.default = v
    end
    d.readOnly = d.source ~= nil
    return d
end

function M.parse(text, folder)
    local root, orders = json.decode(text)
    if root == nil then return nil, "mod.json: " .. orders end
    if type(root) ~= "table" or json.isArray(root) or root == json.null then return nil, "mod.json: not a JSON object" end
    local m = { settings = {}, byKey = {}, problems = {}, hasSettings = false }
    m.id = type(root.id) == "string" and M.cut(root.id, 64) or nil
    m.name = type(root.name) == "string" and M.cut(root.name, 64) or nil
    local s = root.settings
    if s == nil or s == json.null then return m end
    m.hasSettings = true
    if type(s) ~= "table" or json.isArray(s) or s == json.null then
        m.problems[#m.problems + 1] = string.format("%s: settings is not an object; no settings", folder)
        return m
    end
    local keys = orders[s] or {}
    for i, key in ipairs(keys) do
        if i > M.MAX_SETTINGS then
            m.problems[#m.problems + 1] = string.format("%s: more than %d settings; '%s' and the rest are left out", folder, M.MAX_SETTINGS, q(key))
            break
        end
        local d, why = entry(key, s[key])
        if d then
            m.settings[#m.settings + 1] = d
            m.byKey[key] = d
        else
            m.problems[#m.problems + 1] = string.format("%s: setting '%s' left out: %s", folder, q(key), why)
        end
    end
    return m
end

return M
