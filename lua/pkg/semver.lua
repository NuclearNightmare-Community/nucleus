-- Plain semver (MAJOR.MINOR.PATCH) and minimum-version dependencies (api-contract.md, "mod.json"; story 18).
-- A dependent names the oldest core it works with: ">=X.Y.Z". Any core at or above it satisfies it, as long as that
-- minimum is not below core's compatibility floor (mod.json "compat.floor": the oldest need this core still serves).
-- "^X.Y.Z" (the old caret form) and a bare "X.Y.Z" (what connect took before 0.4.0) are read as ">=X.Y.Z".
local M = {}

M.MAX_NEED = 64 -- longest need string accepted (bytes)

function M.parse(s)
    if type(s) ~= "string" then return nil end
    local a, b, c = s:match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return { major = tonumber(a), minor = tonumber(b), patch = tonumber(c) }
end

-- compare(a, b) -> -1 | 0 | 1 for two parsed versions (tables from parse) or strings; nil when either doesn't parse.
function M.compare(a, b)
    if type(a) == "string" then a = M.parse(a) end
    if type(b) == "string" then b = M.parse(b) end
    if type(a) ~= "table" or type(b) ~= "table" then return nil end
    for _, k in ipairs({ "major", "minor", "patch" }) do
        if a[k] ~= b[k] then return a[k] < b[k] and -1 or 1 end
    end
    return 0
end

-- parseNeed(need) -> minimum {major, minor, patch} | nil, why. Accepts ">=X.Y.Z", "^X.Y.Z" or "X.Y.Z" (each part 1-9
-- digits, nothing else, at most MAX_NEED bytes). why is a short reason for the refusal; never raises.
function M.parseNeed(need)
    if type(need) ~= "string" then return nil, "must be a string like '>=0.4.0', got " .. type(need) end
    if #need == 0 then return nil, "is empty (want '>=X.Y.Z')" end
    if #need > M.MAX_NEED then return nil, string.format("is %d bytes, cap %d (want '>=X.Y.Z')", #need, M.MAX_NEED) end
    local body = need:match("^>=(.*)$") or need:match("^%^(.*)$") or need
    local a, b, c = body:match("^(%d%d?%d?%d?%d?%d?%d?%d?%d?)%.(%d%d?%d?%d?%d?%d?%d?%d?%d?)%.(%d%d?%d?%d?%d?%d?%d?%d?%d?)$")
    if not a then return nil, "is not a minimum version (want '>=X.Y.Z')" end
    return { major = tonumber(a), minor = tonumber(b), patch = tonumber(c) }
end

-- check(have, need, floor) -> true | false, kind. kind: "bad-need" (need doesn't parse), "bad-have" (have doesn't
-- parse), "core-too-old" (have is below need's minimum), "mod-too-old" (need's minimum is below floor). floor nil or
-- unparsable means no floor. Never raises.
function M.check(have, need, floor)
    local n = M.parseNeed(need)
    if not n then return false, "bad-need" end
    local h = M.parse(have)
    if not h then return false, "bad-have" end
    if M.compare(h, n) < 0 then return false, "core-too-old" end
    local f = M.parse(floor)
    if f and M.compare(n, f) < 0 then return false, "mod-too-old" end
    return true
end

-- satisfies(have, need[, floor]) -> bool: check() without the reason. need: ">=X.Y.Z" (or "^X.Y.Z", "X.Y.Z").
-- Before 0.4.0 this was the caret rule (same minor below 1.0.0); a caret need is now a minimum (story 18).
function M.satisfies(have, need, floor)
    return (M.check(have, need, floor)) == true
end

return M
