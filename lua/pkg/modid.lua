-- Core's mod id normalizer (_bmad-output/specs/spec-distribution-v0/mod-ids.md, "Normalizer"), the Lua copy of the
-- rule the release tools and the Mod Manager run (mods/mod-manager/Scripts/modid.lua, same cases in
-- test/unit/net_test.lua). Pure: no UE4SS, usable in core's state, a dependent's state and the unit tests.
--
--   M.normalize(id) -> the normalized id | nil, message      the rule exactly; never raises
--   M.netId(id)     -> the id core's net state uses | nil, message
--                      normalize(id), or a legacy bare id [a-z0-9-]{1,64} (lowercased): spikes and test dependents keep
--                      bare ids until distribution story 13 renames them
--   M.isNetId(id)   -> true when id is already in that form (netId(id) == id): what a client accepts from the net
local M = {}

M.MAX = 200
M.MAX_BARE = 64
M.PREFIX = "github.com/"
local FORMS = "accepted forms: <owner>.<mod> or github.com/<owner>.<mod>"

local function q(s) return (tostring(s):sub(1, 64):gsub("[^%w%p ]", "?")) end

function M.normalize(id)
    if type(id) ~= "string" then return nil, "an id must be a string, got " .. type(id) end
    if #id == 0 then return nil, "an id is empty" end
    if #id > M.MAX then return nil, string.format("an id is at most %d characters, got %d", M.MAX, #id) end
    local s = id:lower()
    if s:sub(1, #M.PREFIX) == M.PREFIX then s = s:sub(#M.PREFIX + 1) end
    if s:find("/", 1, true) then
        if s:find("://", 1, true) or s:match("^[^/]*github%.com/") then return nil, "'" .. q(id) .. "' is not an id (" .. FORMS .. ")" end
        return nil, "'" .. q(id) .. "' names another host; only GitHub ids are accepted for now (" .. FORMS .. ")"
    end
    if not s:find(".", 1, true) then return nil, "'" .. q(id) .. "' has no namespace (" .. FORMS .. ")" end
    if not s:match("^[a-z0-9%-]+%.[a-z0-9%-]+$") then return nil, "'" .. q(id) .. "' is not an id (" .. FORMS .. ")" end
    return s
end

function M.netId(id)
    if type(id) == "string" and #id >= 1 and #id <= M.MAX_BARE and id:match("^[A-Za-z0-9%-]+$") then return id:lower() end
    return M.normalize(id)
end

function M.isNetId(id)
    if type(id) ~= "string" then return false end
    return M.netId(id) == id
end

return M
