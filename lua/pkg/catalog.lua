-- core.catalog (Mod Manager v2 story 2; README "Catalog"): the signed mod catalog, fetched and verified by core's native
-- part on a background worker (native/src/catalog.cpp). Lua only starts jobs and reads their results: no crypto and no
-- HTTP here, and no loop of its own (the caller polls, for example from a LoopInGameThreadWithDelay it already runs).
-- Runs in any Lua state (a dependent's core.catalog, or require("<core>.catalog") directly); holds nothing. Never raises.
--
--   refresh()                -> job, or nil, reason
--       Starts fetching and verifying the catalog. reason: "busy" (a job is queued or running), "data folder unknown",
--       "native part missing", "error: <message>".
--   download(id, version)    -> job, or nil, reason
--       Starts downloading one release file named by the last verified catalog. id and version are strings; nothing
--       else reaches the native part. reason: "busy", "no verified catalog", "not in the catalog", "too large",
--       "downloads folder full", "data folder unknown", "bad arguments: <why>", "native part missing",
--       "error: <message>" (for example an id the normalizer refuses).
--   poll(job)                -> "running" | "done", result | nil, reason
--       result = { outcome = <code>, message = <text>, payload = <decoded table, or nil>, payloadError = <why, or nil> }.
--       outcome "ok" for success, else verify.ps1's codes (bad-signature, unknown-key, serial-rollback, schema-too-new,
--       invalid-index, url-not-allowed, size-mismatch, hash-mismatch, revoked, error) and, for downloads, unreachable.
--       A refresh's ok payload: { source = "network" | "copy", base, index_issued, revoked_issued, details, index,
--       revoked }; a download's: { id, version, sha256, size, file }; a stage's: { txn, owners = { { id, version, name,
--       files, bytes }, ... }, ops }. reason: "unknown job", "bad job", "native part missing", "error: <message>".
--   stage(list)              -> job, or nil, reason                                   (Mod Manager v2 story 5)
--       Stages an install of every (id, version) in list = { { id = <string>, version = <string> }, ... } (1 to 16, in
--       order: dependencies first) into the change core's helper applies when the game exits (core.apply): core's
--       native part downloads and verifies each release zip, reads it, maps its files to install-layout paths and
--       merges them into the staged plan. Only the ids and versions reach the native part; nothing from Lua becomes a
--       path, a name or a hash. Outcomes (poll): ok, not-in-catalog, not-a-mod, revoked, too-large, downloads-full,
--       size-mismatch, hash-mismatch, url-not-allowed, unreachable, bad-zip, bad-layout, name-mismatch, id-mismatch,
--       folder-in-use, downgrade, applying, interrupted, error. reason: "busy", "no verified index", "applying",
--       "interrupted", "data folder unknown", "bad arguments: <why>", "native part missing", "error: <message>" (for
--       example an id the normalizer refuses, or an id listed twice).
--       Story 6: an installed owner makes a pair an update (the installed version's files the new release lacks are
--       deleted; a downgrade only away from an installed version the verified revoked list names).
--   unstage(id, version)     -> job, or nil, reason                                   (Mod Manager v2 story 6)
--       Stages the removal of the installed (id, version) into the same change: a delete for each file the installed
--       version owns (a file changed on disk is kept and counted) and its mods.txt line removed. Only the id and version
--       reach the native part. Outcomes (poll): ok, not-installed, changed, not-in-catalog, base-pack (core or Mod
--       Manager: the installer removes those), story 2's download outcomes, applying, interrupted, error. Payload of ok:
--       { txn, owners = { { id, version, name, files, kept } }, ops }. reason: as stage's.
local BASE = (...):gsub("%.catalog$", "")
local V = require(BASE .. ".version")
local json = require(BASE .. ".json")

local M = {}
local KEY_REFRESH, KEY_DOWNLOAD, KEY_POLL = V.name .. "_CatalogRefresh", V.name .. "_CatalogDownload", V.name .. "_CatalogPoll"
local KEY_STAGE, KEY_UNSTAGE = V.name .. "_CatalogStage", V.name .. "_CatalogUnstage"

-- What a payload may hold: two 4 MiB catalog files and the detail lines, nested at most 64 deep inside one wrapper.
M.CAPS = { maxBytes = 9 * 1024 * 1024, maxDepth = 66, maxValues = 2000000, maxString = 4 * 1024 * 1024 }
M.MAX_ID, M.MAX_VERSION = 200, 128
M.MAX_JOB = (1 << 53) - 1
M.MAX_PAIRS = 16

-- The native is looked up on every call (never cached): a hot reload registers a new one.
local function call(key, ...)
    local fn = _G[key]
    if type(fn) ~= "function" then return false, "native part missing" end
    local res = table.pack(pcall(fn, ...))
    if not res[1] then return false, "error: " .. (tostring(res[2]):match("^[^\n]*") or "?") end
    return true, table.unpack(res, 2, res.n)
end

-- A string argument the native can take whole: no NUL byte (the native reads C strings) and at most max bytes.
local function textArg(v, name, max)
    if type(v) ~= "string" then return nil, ("%s must be a string"):format(name) end
    if #v == 0 or #v > max then return nil, ("%s must be 1 to %d bytes"):format(name, max) end
    if v:find("\0", 1, true) then return nil, ("%s must not contain a NUL byte"):format(name) end
    return v
end

function M.refresh()
    local ok, job, why = call(KEY_REFRESH)
    if not ok then return nil, job end
    if math.type(job) == "integer" then return job end
    return nil, type(why) == "string" and why or "error: no job"
end

function M.download(id, version)
    local okId, whyId = textArg(id, "id", M.MAX_ID)
    if not okId then return nil, "bad arguments: " .. whyId end
    local okV, whyV = textArg(version, "version", M.MAX_VERSION)
    if not okV then return nil, "bad arguments: " .. whyV end
    local ok, job, why = call(KEY_DOWNLOAD, id, version)
    if not ok then return nil, job end
    if math.type(job) == "integer" then return job end
    return nil, type(why) == "string" and why or "error: no job"
end

function M.stage(list)
    if type(list) ~= "table" then return nil, "bad arguments: list must be a table of { id, version }" end
    local n = 0
    for k in pairs(list) do
        if math.type(k) ~= "integer" or k < 1 then return nil, "bad arguments: list must be a sequence" end
        n = n + 1
        if n > M.MAX_PAIRS then return nil, "bad arguments: at most " .. M.MAX_PAIRS .. " entries" end
    end
    if n == 0 then return nil, "bad arguments: list must not be empty" end
    if #list ~= n then return nil, "bad arguments: list must be a sequence" end
    local args = {}
    for i = 1, n do
        local e = list[i]
        if type(e) ~= "table" then return nil, ("bad arguments: entry %d must be a table"):format(i) end
        local okId, whyId = textArg(e.id, ("entry %d's id"):format(i), M.MAX_ID)
        if not okId then return nil, "bad arguments: " .. whyId end
        local okV, whyV = textArg(e.version, ("entry %d's version"):format(i), M.MAX_VERSION)
        if not okV then return nil, "bad arguments: " .. whyV end
        args[#args + 1] = e.id
        args[#args + 1] = e.version
    end
    local ok, job, why = call(KEY_STAGE, table.unpack(args, 1, #args))
    if not ok then return nil, job end
    if math.type(job) == "integer" then return job end
    return nil, type(why) == "string" and why or "error: no job"
end

function M.unstage(id, version)
    local okId, whyId = textArg(id, "id", M.MAX_ID)
    if not okId then return nil, "bad arguments: " .. whyId end
    local okV, whyV = textArg(version, "version", M.MAX_VERSION)
    if not okV then return nil, "bad arguments: " .. whyV end
    local ok, job, why = call(KEY_UNSTAGE, id, version)
    if not ok then return nil, job end
    if math.type(job) == "integer" then return job end
    return nil, type(why) == "string" and why or "error: no job"
end

function M.poll(job)
    if math.type(job) ~= "integer" or job < 1 or job > M.MAX_JOB then return nil, "bad job" end
    local ok, state, outcome, message, payload = call(KEY_POLL, job)
    if not ok then return nil, state end
    if state == "running" then return "running" end
    if state == "done" and type(outcome) == "string" then
        local result = { outcome = outcome, message = type(message) == "string" and message or "" }
        if type(payload) == "string" then
            local value, err = json.decode(payload, M.CAPS)
            if value ~= nil then result.payload = value else result.payloadError = err end
        else
            result.payloadError = "no payload"
        end
        return "done", result
    end
    if state == nil and type(outcome) == "string" then return nil, outcome end
    return nil, "error: unexpected answer"
end

return M
