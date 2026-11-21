-- Unit tests for Mod Manager v2 story 2 (core.catalog, lua/pkg/catalog.lua), outside the game: what refresh(),
-- download(), poll() and (story 5) stage() return for every answer of the natives (a job, nil + reason, "running", "done" with a payload,
-- a raised error, a missing native, garbage), that they never raise, check their arguments before any native call,
-- pass exactly the caller's id and version on, decode the payload with core's JSON reader, and look the native up on
-- every call (a hot reload registers a new one).
-- The natives themselves: native/test/catalog.tests.ps1 (the test exe) and run.ps1 -Scenario bad-input (in game).
-- Run from the repo root with any standalone Lua 5.3 or 5.4 (MiKTeX's texlua is one):  lua test/unit/catalog_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.23.0", floor = "0.1.0" } end
table.insert(package.searchers, 2, function(name)
    local rest = name:match("^nucleus%.(.+)$")
    if not rest then return nil end
    local path = ROOT .. "/lua/pkg/" .. rest:gsub("%.", "/") .. ".lua"
    local f = io.open(path, "r")
    if not f then return "\n\tno file " .. path end
    f:close()
    return assert(loadfile(path)), path
end)

local pass, fail = 0, 0
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")) end
end
local function same(name, want, ...)
    local got = table.pack(...)
    local okS = got.n == want.n
    for i = 1, math.max(got.n, want.n) do if got[i] ~= want[i] then okS = false end end
    local parts = {}
    for i = 1, got.n do parts[i] = tostring(got[i]) end
    ok(okS, name, "got (" .. table.concat(parts, ", ") .. ")")
end
local function P(...) return table.pack(...) end

local C = require("nucleus.catalog")
local json = require("nucleus.json")
ok(type(C.refresh) == "function" and type(C.download) == "function" and type(C.poll) == "function" and type(C.stage) == "function" and type(C.unstage) == "function",
    "the module has refresh, download, poll, stage and unstage")

-- ---------------------------------------------------------------- no natives
_G.Nucleus_CatalogRefresh, _G.Nucleus_CatalogDownload, _G.Nucleus_CatalogPoll, _G.Nucleus_CatalogStage = nil, nil, nil, nil
same("refresh: native part missing", P(nil, "native part missing"), C.refresh())
same("stage: native part missing", P(nil, "native part missing"), C.stage({ { id = "a.b", version = "1.0.0" } }))
same("download: native part missing", P(nil, "native part missing"), C.download("a.b", "1.0.0"))
same("poll: native part missing", P(nil, "native part missing"), C.poll(1))

-- ---------------------------------------------------------------- refresh
local args
_G.Nucleus_CatalogRefresh = function(...) args = table.pack(...) return 7 end
same("refresh: the job", P(7), C.refresh("ignored", {}))
ok(args.n == 0, "refresh: no argument reaches the native", args.n)
_G.Nucleus_CatalogRefresh = function() return nil, "busy" end
same("refresh: busy", P(nil, "busy"), C.refresh())
_G.Nucleus_CatalogRefresh = function() return nil, "data folder unknown" end
same("refresh: data folder unknown", P(nil, "data folder unknown"), C.refresh())
_G.Nucleus_CatalogRefresh = function() error("Nucleus_CatalogRefresh: takes no arguments\nmore", 0) end
same("refresh: a raised error is a reason, first line only", P(nil, "error: Nucleus_CatalogRefresh: takes no arguments"), C.refresh())
_G.Nucleus_CatalogRefresh = function() return 1.5 end
same("refresh: a float job is no job", P(nil, "error: no job"), C.refresh())
_G.Nucleus_CatalogRefresh = "not a function"
same("refresh: a non-function global is missing", P(nil, "native part missing"), C.refresh())
-- looked up per call: a new native after a reload is used
_G.Nucleus_CatalogRefresh = function() return 1 end
same("refresh: first native", P(1), C.refresh())
_G.Nucleus_CatalogRefresh = function() return 2 end
same("refresh: the native is looked up again", P(2), C.refresh())

-- ---------------------------------------------------------------- download
local calls = 0
_G.Nucleus_CatalogDownload = function(...) calls = calls + 1; args = table.pack(...) return 9 end
same("download: the job", P(9), C.download("NuclearNightmare-Community.Markers", "0.1.0"))
ok(args.n == 2 and args[1] == "NuclearNightmare-Community.Markers" and args[2] == "0.1.0", "download: exactly id and version reach the native")
calls = 0
for _, c in ipairs({
    { "id not a string", { 5, "1.0.0" }, "bad arguments: id must be a string" },
    { "id nil", { nil, "1.0.0" }, "bad arguments: id must be a string" },
    { "id empty", { "", "1.0.0" }, "bad arguments: id must be 1 to 200 bytes" },
    { "id over 200 bytes", { ("a"):rep(100) .. "." .. ("b"):rep(100), "1.0.0" }, "bad arguments: id must be 1 to 200 bytes" },
    { "id with a NUL byte", { "owner.m\0od", "1.0.0" }, "bad arguments: id must not contain a NUL byte" },
    { "version not a string", { "a.b", 1 }, "bad arguments: version must be a string" },
    { "version a table", { "a.b", {} }, "bad arguments: version must be a string" },
    { "version over 128 bytes", { "a.b", "1.0.0-" .. ("x"):rep(123) }, "bad arguments: version must be 1 to 128 bytes" },
    { "version with a NUL byte", { "a.b", "1.0.0\0" }, "bad arguments: version must not contain a NUL byte" },
}) do
    same("download: " .. c[1], P(nil, c[3]), C.download(c[2][1], c[2][2]))
end
ok(calls == 0, "download: bad arguments never reach the native", calls)
same("download: 200 bytes is fine", P(9), C.download(("a"):rep(100) .. "." .. ("b"):rep(99), "1.0.0"))
for _, why in ipairs({ "busy", "no verified catalog", "not in the catalog", "too large", "downloads folder full" }) do
    _G.Nucleus_CatalogDownload = function() return nil, why end
    same("download: reason " .. why, P(nil, why), C.download("a.b", "1.0.0"))
end
_G.Nucleus_CatalogDownload = function() error("Nucleus_CatalogDownload: argument 1 (id): an id needs a namespace; use ...", 0) end
same("download: a raised error is a reason", P(nil, "error: Nucleus_CatalogDownload: argument 1 (id): an id needs a namespace; use ..."), C.download("nucleus", "1.0.0"))
_G.Nucleus_CatalogDownload = function() return "seven" end
same("download: a string job is no job", P(nil, "error: no job"), C.download("a.b", "1.0.0"))

-- ---------------------------------------------------------------- poll
calls = 0
_G.Nucleus_CatalogPoll = function(...) calls = calls + 1; args = table.pack(...) return "running" end
same("poll: running", P("running"), C.poll(3))
ok(args.n == 1 and args[1] == 3 and math.type(args[1]) == "integer", "poll: exactly the job reaches the native")
calls = 0
for _, bad in ipairs({ { "a float", 1.0 }, { "a string", "1" }, { "nil", nil }, { "zero", 0 }, { "negative", -1 }, { "above 2^53-1", 1 << 53 }, { "a table", {} } }) do
    same("poll: " .. bad[1] .. " is a bad job", P(nil, "bad job"), C.poll(bad[2]))
end
ok(calls == 0, "poll: a bad job never reaches the native", calls)

-- A refresh's ok payload, decoded with core's JSON reader.
local index = '{"schema":2,"serial":9,"issued":"2026-11-20T10:00:00Z","packages":[{"id":"a.b","name":"B","kind":"mod","versions":[{"version":"1.0.0","size":4096}]}]}'
local payload = '{"source":"network","base":"https://nuclearnightmare-community.github.io/catalog/","index_issued":"2026-11-20T10:00:00Z",' ..
    '"revoked_issued":null,"details":["trust: built-in (3 keys)","endpoint: x ok"],"index":' .. index .. ',"revoked":null}'
_G.Nucleus_CatalogPoll = function() return "done", "ok", "index serial 9 verified from x", payload end
local st, r = C.poll(3)
ok(st == "done" and type(r) == "table" and r.outcome == "ok" and r.message == "index serial 9 verified from x", "poll: done, outcome and message", st)
ok(r and type(r.payload) == "table" and r.payload.source == "network" and r.payload.revoked == json.null and r.payload.index.serial == 9 and
    math.type(r.payload.index.serial) == "integer" and r.payload.index.packages[1].versions[1].size == 4096 and r.payload.details[2] == "endpoint: x ok" and
    r.payloadError == nil, "poll: the payload is decoded (index, details, null revoked)")
-- A download's payload.
_G.Nucleus_CatalogPoll = function() return "done", "ok", "package a.b 1.0.0 downloaded", '{"id":"a.b","version":"1.0.0","sha256":"ab","size":4096,"file":"C:\\\\x\\\\ab.zip"}' end
st, r = C.poll(4)
ok(st == "done" and r.payload and r.payload.file == "C:\\x\\ab.zip" and r.payload.size == 4096, "poll: a download's payload", r and r.payloadError)
-- A rejection: outcome and message, the details payload.
_G.Nucleus_CatalogPoll = function() return "done", "bad-signature", "endpoint https://x/: signature does not verify against the index", '{"details":["endpoint: https://x/ rejected (bad-signature): ..."]}' end
st, r = C.poll(5)
ok(st == "done" and r.outcome == "bad-signature" and r.payload.details[1]:find("rejected", 1, true), "poll: a rejection keeps its code, message and details")
-- A payload that isn't JSON: the result says why; poll still doesn't raise.
_G.Nucleus_CatalogPoll = function() return "done", "ok", "m", "{not json" end
st, r = C.poll(6)
ok(st == "done" and r.payload == nil and type(r.payloadError) == "string", "poll: an undecodable payload gives payloadError", r and r.payloadError)
_G.Nucleus_CatalogPoll = function() return "done", "ok", "m" end
st, r = C.poll(6)
ok(st == "done" and r.payload == nil and r.payloadError == "no payload", "poll: a missing payload gives payloadError")
-- A large payload (well above the settings reader's 64 KiB default) still decodes.
do
    local parts = {}
    for i = 1, 3000 do parts[i] = '{"id":"o.m' .. i .. '","name":"M","kind":"mod","versions":[]}' end
    local big = '{"index":{"packages":[' .. table.concat(parts, ",") .. ']}}'
    _G.Nucleus_CatalogPoll = function() return "done", "ok", "m", big end
    st, r = C.poll(7)
    ok(st == "done" and r.payload and #r.payload.index.packages == 3000, "poll: a payload of " .. #big .. " bytes decodes", r and r.payloadError)
end
_G.Nucleus_CatalogPoll = function() return nil, "unknown job" end
same("poll: unknown job", P(nil, "unknown job"), C.poll(99))
_G.Nucleus_CatalogPoll = function() error("Nucleus_CatalogPoll: job 0 is out of range (1..9007199254740991)", 0) end
same("poll: a raised error is a reason", P(nil, "error: Nucleus_CatalogPoll: job 0 is out of range (1..9007199254740991)"), C.poll(1))
_G.Nucleus_CatalogPoll = function() return 42 end
same("poll: garbage is an unexpected answer", P(nil, "error: unexpected answer"), C.poll(1))

-- ---------------------------------------------------------------- stage (Mod Manager v2 story 5)
calls = 0
_G.Nucleus_CatalogStage = function(...) calls = calls + 1; args = table.pack(...) return 11 end
same("stage: the job", P(11), C.stage({ { id = "NuclearNightmare-Community.Nucleus", version = "0.26.0" }, { id = "o.hud-clock", version = "0.3.0" } }))
ok(args.n == 4 and args[1] == "NuclearNightmare-Community.Nucleus" and args[2] == "0.26.0" and args[3] == "o.hud-clock" and args[4] == "0.3.0",
    "stage: exactly the ids and versions reach the native, as pairs in order", args.n)
do
    local list = {}
    for i = 1, 16 do list[i] = { id = "o.m" .. i, version = "1.0." .. i } end
    same("stage: 16 entries", P(11), C.stage(list))
    ok(args.n == 32 and args[31] == "o.m16" and args[32] == "1.0.16", "stage: 16 entries are 32 arguments", args.n)
end
calls = 0
local seventeen = {}
for i = 1, 17 do seventeen[i] = { id = "o.m" .. i, version = "1.0.0" } end
for _, c in ipairs({
    { "not a table", "x", "bad arguments: list must be a table of { id, version }" },
    { "nil", nil, "bad arguments: list must be a table of { id, version }" },
    { "empty", {}, "bad arguments: list must not be empty" },
    { "17 entries", seventeen, "bad arguments: at most 16 entries" },
    { "a hole", { { id = "a.b", version = "1.0.0" }, nil, { id = "c.d", version = "1.0.0" } }, "bad arguments: list must be a sequence" },
    { "a string key", { { id = "a.b", version = "1.0.0" }, x = 1 }, "bad arguments: list must be a sequence" },
    { "an entry not a table", { "a.b" }, "bad arguments: entry 1 must be a table" },
    { "id not a string", { { id = 1, version = "1.0.0" } }, "bad arguments: entry 1's id must be a string" },
    { "version missing", { { id = "a.b" } }, "bad arguments: entry 1's version must be a string" },
    { "second id empty", { { id = "a.b", version = "1.0.0" }, { id = "", version = "1.0.0" } }, "bad arguments: entry 2's id must be 1 to 200 bytes" },
    { "id over 200 bytes", { { id = ("a"):rep(100) .. "." .. ("b"):rep(100), version = "1.0.0" } }, "bad arguments: entry 1's id must be 1 to 200 bytes" },
    { "version with a NUL", { { id = "a.b", version = "1.0.0\0" } }, "bad arguments: entry 1's version must not contain a NUL byte" },
    { "version over 128 bytes", { { id = "a.b", version = "1.0.0-" .. ("x"):rep(123) } }, "bad arguments: entry 1's version must be 1 to 128 bytes" },
}) do
    same("stage: " .. c[1], P(nil, c[3]), C.stage(c[2]))
end
ok(calls == 0, "stage: bad arguments never reach the native", calls)
for _, why in ipairs({ "busy", "no verified index", "applying", "interrupted", "data folder unknown" }) do
    _G.Nucleus_CatalogStage = function() return nil, why end
    same("stage: reason " .. why, P(nil, why), C.stage({ { id = "a.b", version = "1.0.0" } }))
end
_G.Nucleus_CatalogStage = function() error("Nucleus_CatalogStage: argument 3 (id): o.m is listed twice\nmore", 0) end
same("stage: a raised error is a reason, first line only", P(nil, "error: Nucleus_CatalogStage: argument 3 (id): o.m is listed twice"),
    C.stage({ { id = "o.m", version = "1.0.0" }, { id = "O.M", version = "1.0.0" } }))
_G.Nucleus_CatalogStage = function() return 2.5 end
same("stage: a float job is no job", P(nil, "error: no job"), C.stage({ { id = "a.b", version = "1.0.0" } }))
-- A stage's payload, decoded by poll.
_G.Nucleus_CatalogPoll = function() return "done", "ok", "2 mods staged", '{"txn":"0123456789abcdef0123456789abcdef","owners":[{"id":"o.a","version":"1.0.0","name":"A","files":3,"bytes":99},{"id":"o.b","version":"2.0.0","name":"B","files":1,"bytes":5}],"ops":6}' end
st, r = C.poll(12)
ok(st == "done" and r.outcome == "ok" and r.payload.txn == "0123456789abcdef0123456789abcdef" and #r.payload.owners == 2 and r.payload.owners[2].name == "B" and
    math.type(r.payload.ops) == "integer" and r.payload.ops == 6, "poll: a stage's payload { txn, owners, ops }")
_G.Nucleus_CatalogPoll = function() return "done", "bad-zip", "o.a 1.0.0: entry x fails its CRC-32 check", '{"failed":"o.a"}' end
st, r = C.poll(13)
ok(st == "done" and r.outcome == "bad-zip" and r.payload.failed == "o.a", "poll: a refused stage keeps its code and names the pair")

-- ---------------------------------------------------------------- unstage (Mod Manager v2 story 6)
_G.Nucleus_CatalogUnstage = nil
same("unstage: native part missing", P(nil, "native part missing"), C.unstage("a.b", "1.0.0"))
calls = 0
_G.Nucleus_CatalogUnstage = function(...) calls = calls + 1; args = table.pack(...) return 21 end
same("unstage: the job", P(21), C.unstage("NuclearNightmare-Community.Whistle-Mute", "0.2.1"))
ok(args.n == 2 and args[1] == "NuclearNightmare-Community.Whistle-Mute" and args[2] == "0.2.1", "unstage: exactly the id and version reach the native", args.n)
calls = 0
for _, c in ipairs({
    { "id nil", { nil, "1.0.0" }, "bad arguments: id must be a string" },
    { "id a number", { 1, "1.0.0" }, "bad arguments: id must be a string" },
    { "id empty", { "", "1.0.0" }, "bad arguments: id must be 1 to 200 bytes" },
    { "id over 200 bytes", { ("a"):rep(100) .. "." .. ("b"):rep(100), "1.0.0" }, "bad arguments: id must be 1 to 200 bytes" },
    { "id with a NUL", { "a.b\0", "1.0.0" }, "bad arguments: id must not contain a NUL byte" },
    { "version a table", { "a.b", {} }, "bad arguments: version must be a string" },
    { "version over 128 bytes", { "a.b", "1.0.0-" .. ("x"):rep(123) }, "bad arguments: version must be 1 to 128 bytes" },
}) do
    same("unstage: " .. c[1], P(nil, c[3]), C.unstage(c[2][1], c[2][2]))
end
ok(calls == 0, "unstage: bad arguments never reach the native", calls)
for _, why in ipairs({ "busy", "no verified index", "applying", "interrupted", "data folder unknown" }) do
    _G.Nucleus_CatalogUnstage = function() return nil, why end
    same("unstage: reason " .. why, P(nil, why), C.unstage("a.b", "1.0.0"))
end
_G.Nucleus_CatalogUnstage = function() error("Nucleus_CatalogUnstage: argument 2 (version) is not semver: '1.0'\nmore", 0) end
same("unstage: a raised error is a reason, first line only", P(nil, "error: Nucleus_CatalogUnstage: argument 2 (version) is not semver: '1.0'"), C.unstage("a.b", "1.0"))
_G.Nucleus_CatalogUnstage = function() return 3.5 end
same("unstage: a float job is no job", P(nil, "error: no job"), C.unstage("a.b", "1.0.0"))
_G.Nucleus_CatalogPoll = function() return "done", "ok", "WhistleMute removal staged", '{"txn":"0123456789abcdef0123456789abcdef","owners":[{"id":"o.wm","version":"0.2.1","name":"WhistleMute","files":3,"kept":1}],"ops":4}' end
st, r = C.poll(22)
ok(st == "done" and r.outcome == "ok" and #r.payload.owners == 1 and r.payload.owners[1].files == 3 and r.payload.owners[1].kept == 1 and r.payload.ops == 4,
    "poll: an unstage's payload { txn, owners [{ id, version, name, files, kept }], ops }")
_G.Nucleus_CatalogPoll = function() return "done", "not-in-catalog", "o.wm 0.1.0: not in installed.txt nor in the catalog", '{"failed":"o.wm"}' end
st, r = C.poll(23)
ok(st == "done" and r.outcome == "not-in-catalog" and r.payload.failed == "o.wm", "poll: a refused unstage keeps its code")

-- ---------------------------------------------------------------- never raises
local garbage = { nil, true, 1, 1.5, "x", {}, function() end, ("z"):rep(1000) }
local raised = 0
for _, g in ipairs({ function() error("boom") end, function() return nil end, 5, "x" }) do
    _G.Nucleus_CatalogRefresh, _G.Nucleus_CatalogDownload, _G.Nucleus_CatalogPoll, _G.Nucleus_CatalogStage, _G.Nucleus_CatalogUnstage = g, g, g, g, g
    for i = 1, #garbage + 1 do
        for j = 1, #garbage + 1 do
            if not pcall(C.download, garbage[i], garbage[j]) then raised = raised + 1 end
        end
        if not pcall(C.poll, garbage[i]) then raised = raised + 1 end
        if not pcall(C.refresh, garbage[i]) then raised = raised + 1 end
        if not pcall(C.stage, garbage[i]) then raised = raised + 1 end
        for j = 1, #garbage + 1 do if not pcall(C.unstage, garbage[i], garbage[j]) then raised = raised + 1 end end
        if not pcall(C.stage, { garbage[i] }) then raised = raised + 1 end
        if not pcall(C.stage, { { id = garbage[i], version = garbage[i] } }) then raised = raised + 1 end
    end
end
ok(raised == 0, "nothing raises, whatever the natives or the arguments", raised)

print(("catalog_test: %d passed, %d failed"):format(pass, fail))
if fail > 0 then os.exit(1) end
