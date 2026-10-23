-- Plain semver (MAJOR.MINOR.PATCH) and caret compatibility (api-contract.md, "mod.json").
local M = {}

function M.parse(s)
    if type(s) ~= "string" then return nil end
    local a, b, c = s:match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return { major = tonumber(a), minor = tonumber(b), patch = tonumber(c) }
end

-- satisfies(have, need): caret rule. From 1.0.0: same major and have >= need. Below 1.0.0: same minor too.
function M.satisfies(have, need)
    local h, n = M.parse(have), M.parse(need)
    if not h or not n or h.major ~= n.major then return false end
    if n.major == 0 then
        return h.minor == n.minor and h.patch >= n.patch
    end
    if h.minor ~= n.minor then return h.minor > n.minor end
    return h.patch >= n.patch
end

return M
