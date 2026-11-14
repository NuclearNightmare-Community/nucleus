-- nucleus.modid: core's mod id normalizer (_bmad-output/specs/spec-distribution-v0/mod-ids.md, "Normalizer"; distribution
-- story 13). The Lua twin of tools/release/modid.ps1 in the workspace: both run the shared cases in
-- test/unit/fixtures/modid-cases.json (a byte-identical copy of tools/release/tests/modid-cases.json) with identical
-- results and messages. Pure: no UE4SS, usable in core's state, a dependent's state (require("nucleus.modid")) and
-- the unit tests.
--
--   M.normalize(id) -> the normalized id | nil, message      never raises; the message doesn't echo the input
--   M.netId(id)     -> the id core's net state uses | nil, message
--                      normalize(id), or a legacy bare id [a-z0-9-]{1,64} (lowercased): unreleased spikes and test
--                      dependents keep bare ids (core stories 22 and 23)
--   M.isNetId(id)   -> true when id is already in that form (netId(id) == id): what a client accepts from the net
--
-- The rule: at most M.MAX bytes; lowercase (ASCII letters only); strip one leading "github.com/"; refuse "://" or a
-- leading "www.", another host (a "/" left with a "." before it), a bare id (no dot); then "<owner>.<mod>", each part
-- [a-z0-9-]+.
local M = {}

M.MAX = 200
M.MAX_BARE = 64
M.PREFIX = "github.com/"

local FORMS = "use <owner>.<mod> or github.com/<owner>.<mod>"
M.ERR = {
    type = "an id must be a string",
    empty = "an id must not be empty",
    long = "an id must be at most 200 characters",
    url = "an id is not a URL; " .. FORMS,
    host = "ids on hosts other than GitHub are not supported yet; " .. FORMS,
    bare = "an id needs a namespace; " .. FORMS,
    format = "an id must be <owner>.<mod> with only a-z, 0-9 and - in each part; " .. FORMS,
}

local function lowerAscii(c) return string.char(c:byte() + 32) end

function M.normalize(id)
    if type(id) ~= "string" then return nil, M.ERR.type end
    if #id == 0 then return nil, M.ERR.empty end
    if #id > M.MAX then return nil, M.ERR.long end
    local s = id:gsub("[A-Z]", lowerAscii)
    if s:sub(1, #M.PREFIX) == M.PREFIX then s = s:sub(#M.PREFIX + 1) end
    if s:find("://", 1, true) or s:sub(1, 4) == "www." then return nil, M.ERR.url end
    local slash = s:find("/", 1, true)
    if slash and s:sub(1, slash - 1):find(".", 1, true) then return nil, M.ERR.host end
    if not s:find(".", 1, true) then return nil, M.ERR.bare end
    if not s:match("^[a-z0-9%-]+%.[a-z0-9%-]+$") then return nil, M.ERR.format end
    return s
end

function M.netId(id)
    if type(id) == "string" and #id >= 1 and #id <= M.MAX_BARE and id:match("^[A-Za-z0-9%-]+$") then return (id:gsub("[A-Z]", lowerAscii)) end
    return M.normalize(id)
end

function M.isNetId(id)
    if type(id) ~= "string" then return false end
    return M.netId(id) == id
end

return M
