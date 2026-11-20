-- Unit tests for core.net's player presence (core story 23, Net-2), outside the game: the pure module
-- (lua/pkg/net/presence.lua: versions, netCompat, pairs, the report caps and bad pairs, duplicates, the rate limit over
-- a fake clock, the record diff, the snapshot), core's owner (lua/pkg/net/players.lua: the local list and its channel
-- ops, the host's per-player actors, the report hook with identity from the owner, leaves, the cap, the client's own
-- actor, the version mismatch, the sends) over fake UObjects, and the dependent's API (lua/pkg/net/client.lua:
-- presence, watchPresence, compatible, versionsCompatible) wired to that owner through fake shared variables. Every row
-- of the story's I/O matrix that doesn't need a second machine.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  texlua test/unit/net_presence_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
local VERSION = { name = "Nucleus", version = "0.12.0", floor = "0.1.0" }
package.preload["nucleus.version"] = function() return VERSION end
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
local function eq(got, want, name) ok(got == want, name, "got " .. tostring(got) .. ", want " .. tostring(want)) end
local function raises(fn, text, name)
    local okC, err = pcall(fn)
    ok(not okC and tostring(err):find(text, 1, true) ~= nil, name, okC and "did not raise" or tostring(err))
end

local P = require("nucleus.net.presence")
local V0 = VERSION.version

-- ---------------------------------------------------------------- versions and netCompat
do
    for _, v in ipairs({ "0.0.0", "0.1.0", "1.2.3", "999.999.999", "10.0.1" }) do ok(P.isVersion(v), "version ok: " .. v) end
    for _, v in ipairs({ "1.0", "1.0.0.0", "01.0.0", "1.00.0", "1.0.1000", "+1.0.0", "-1.0.0", " 1.0.0", "1.0.0 ", "a.b.c", "", "1..0", "1.0.-1" }) do
        ok(not P.isVersion(v), "version refused: '" .. v .. "'")
    end
    ok(not P.isVersion(1) and not P.isVersion(nil) and not P.isVersion({}), "version refused: non-strings")
    eq(P.defaultNetCompat("0.1.4"), "0.1.0", "default netCompat 0.x: 0.<minor>.0")
    eq(P.defaultNetCompat("1.9.3"), "1.0.0", "default netCompat from 1.0: <major>.0.0")
    eq(P.defaultNetCompat("0.0.7"), "0.0.0", "default netCompat 0.0.x")
    ok(P.checkNetCompat("0.3.0", "0.1.0"), "netCompat below its version")
    ok(P.checkNetCompat("0.3.0", "0.3.0"), "netCompat equal to its version")
    ok(not P.checkNetCompat("1.0.0", "1.1.0"), "netCompat above its version is refused")
    ok(not P.checkNetCompat("1.0.0", "1.1"), "netCompat not strict is refused")
    -- the matrix's versionsCompatible rows
    eq(P.compatible("0.1.0", nil, "0.1.9", nil), true, "compatible: 0.1.0 / 0.1.9 (same 0.minor)")
    eq(P.compatible("1.2.0", nil, "1.9.0", nil), true, "compatible: 1.2.0 / 1.9.0 (same major)")
    eq(P.compatible("0.3.0", "0.1.0", "0.1.0", nil), true, "compatible: 0.3.0 (netCompat 0.1.0) / 0.1.0")
    eq(P.compatible("0.3.0", nil, "0.1.0", nil), false, "compatible: 0.3.0 / 0.1.0 (defaults) are not")
    eq(P.compatible("0.1.0", nil, "0.3.0", "0.1.0"), true, "compatible is symmetric")
    eq(P.compatible("1.0.0", nil, "2.0.0", nil), false, "compatible: majors differ")
    local r, why = P.compatible("1.0", nil, "1.0.0", nil)
    ok(r == nil and why:find("aVersion", 1, true), "compatible: a malformed version is an error", why)
    r, why = P.compatible("1.0.0", "1.1.0", "1.0.0", nil)
    ok(r == nil and why:find("aNetCompat", 1, true), "compatible: netCompat above version is an error", why)
end

-- ---------------------------------------------------------------- pairs and reports
do
    local p = P.parsePair("skeltest=0.1.0")
    ok(p and p.id == "skeltest" and p.version == "0.1.0" and p.netCompat == nil, "parsePair: bare id")
    p = P.parsePair("nuclearnightmare-community.skeltest-ns=0.3.0/0.1.0")
    ok(p and p.id == "nuclearnightmare-community.skeltest-ns" and p.version == "0.3.0" and p.netCompat == "0.1.0", "parsePair: namespaced id with netCompat")
    for _, bad in ipairs({ "Bad_Id=1.0.0", "skeltest=1.0.1000", "1:skeltest=9.9.9", "GitHub.com/x.y=1.0.0", "skeltest-x=1.0.0/1.1.0",
                           "skeltest", "=1.0.0", "skeltest=", "skeltest=1.0.0/", "skeltest=1.0.0/1.0", "SkelTest=1.0.0", "github.com/owner.mod=1.0.0",
                           string.rep("a", 65) .. "=1.0.0", string.rep("a", 100) .. "." .. string.rep("b", 100) .. "=1.0.0" }) do
        ok(P.parsePair(bad) == nil, "parsePair refuses '" .. bad:sub(1, 40) .. "'")
    end
    ok(P.parsePair(string.rep("a", 64) .. "=1.0.0") ~= nil, "parsePair: a 64-character bare id")
    ok(P.parsePair(string.rep("a", 33) .. "=1.0.0") ~= nil, "parsePair: a 33-character bare id is a valid legacy id")

    -- the matrix: bad pairs dropped, the rest kept
    local list, rejects, whole = P.decodeReport("nucleus=" .. V0 .. ",Bad_Id=1.0.0,skeltest=1.0.1000,1:skeltest=9.9.9,GitHub.com/x.y=1.0.0,skeltest-x=1.0.0/1.1.0,skeltest-forge=1.0.0")
    eq(whole, false, "bad pairs: not a whole reject")
    eq(P.encodeList(list), "nucleus=" .. V0 .. ",skeltest-forge=1.0.0", "bad pairs: record {nucleus, skeltest-forge}")
    eq(#rejects, 5, "bad pairs: five rejects")
    -- the design notes' step 3
    list = P.decodeReport("nucleus=" .. V0 .. ",Bad_Id=1.0.0,skeltest=1.0.1000,1:skeltest=9.9.9,skeltest-forge=1.0.0")
    eq(P.encodeList(list), "nucleus=" .. V0 .. ",skeltest-forge=1.0.0", "forge step 3's record")
    -- caps
    local parts = {}
    for i = 1, 33 do parts[i] = "m" .. i .. "=1.0.0" end
    list, rejects, whole = P.decodeReport(table.concat(parts, ","))
    ok(whole and #list == 0 and rejects[1].why:find("33 pairs, cap 32", 1, true), "33 pairs: whole report rejected", rejects[1] and rejects[1].why)
    list, rejects, whole = P.decodeReport(table.concat(parts, ",", 1, 32))
    ok(not whole and #list == 32, "32 pairs: accepted")
    list, rejects, whole = P.decodeReport(string.rep("a", 9000))
    ok(whole and rejects[1].why:find("9000 bytes, cap 8192", 1, true), "9 kB: whole report rejected", rejects[1] and rejects[1].why)
    list, rejects, whole = P.decodeReport(string.rep("a", 8193))
    ok(whole, "8193 bytes: whole report rejected")
    list, rejects, whole = P.decodeReport(nil)
    ok(whole, "a non-string report: whole reject")
    list, rejects, whole = P.decodeReport("")
    ok(not whole and #list == 0 and #rejects == 0, "an empty report: an empty record")
    -- duplicates: the first wins
    list, rejects = P.decodeReport("skeltest=0.1.0,skeltest=9.9.9,other=1.0.0")
    eq(P.encodeList(list), "skeltest=0.1.0,other=1.0.0", "duplicate id: the first wins")
    ok(#rejects == 1 and rejects[1].why:find("duplicate", 1, true), "duplicate id: one reject")
    -- namespaced id with netCompat round trip
    list = P.decodeReport("nucleus=" .. V0 .. ",nuclearnightmare-community.skeltest-ns=0.3.0/0.1.0")
    eq(P.toMap(list)["nuclearnightmare-community.skeltest-ns"].version, "0.3.0", "namespaced id and netCompat: the version")
    eq(P.encodeList(list), "nucleus=" .. V0 .. ",nuclearnightmare-community.skeltest-ns=0.3.0/0.1.0", "report round trip")
    -- the largest legal report fits the cap
    parts = {}
    for i = 1, 32 do parts[i] = string.rep("a", 97) .. string.format("%02d", i) .. "." .. string.rep("b", 100) .. "=999.999.999/999.999.999" end
    local big = table.concat(parts, ",")
    list, rejects, whole = P.decodeReport(big)
    ok(not whole and #list == 32 and #big <= P.MAX_REPORT, "32 longest pairs fit in 8192 bytes", #big)
end

-- ---------------------------------------------------------------- the diff
do
    local function L(s) return (P.decodeReport(s)) end
    local ev = P.diff(nil, L("a=1.0.0,b=2.0.0"))
    ok(#ev == 2 and ev[1].event == "joined" and ev[1].id == "a" and ev[2].id == "b", "diff: first record: joined for each")
    ev = P.diff(L("a=1.0.0,b=2.0.0"), L("a=1.0.1,c=1.0.0"))
    ok(#ev == 3 and ev[1].event == "changed" and ev[1].version == "1.0.1" and ev[1].previous == "1.0.0"
        and ev[2].event == "joined" and ev[2].id == "c" and ev[3].event == "left" and ev[3].id == "b" and ev[3].previous == "2.0.0", "diff: changed, joined, left")
    eq(#P.diff(L("a=1.0.0"), L("a=1.0.0/1.0.0")), 0, "diff: a netCompat change alone is no event")
    ev = P.diff(L("a=1.0.0,b=1.0.0"), nil)
    ok(#ev == 2 and ev[1].event == "left" and ev[2].event == "left", "diff: leaving: left for each")
end

-- ---------------------------------------------------------------- the rate limit (fake clock)
do
    local t = 0
    local allow = P.rate(function() return t end, 4)
    local n = 0
    for _ = 1, 50 do if allow(7) then n = n + 1 end end
    eq(n, 1, "flood: 50 reports in one tick, the first accepted")
    t = 500000; ok(not allow(7), "rate: a second report within 1 s is dropped")
    t = 1000000; ok(allow(7), "rate: 1 s later, accepted")
    for i = 2, 8 do t = i * 1000000; allow(7) end
    t = 10000000; ok(allow(7), "rate: the 10th in a minute is accepted")
    t = 11000000; ok(not allow(7), "rate: the 11th in a minute is dropped")
    t = 60000001; ok(allow(7), "rate: a minute after the first, accepted again")
    ok(allow(8), "rate: another player has its own budget")
    ok(allow(9) and allow(10), "rate: up to the key cap")
    ok(not allow(11), "rate: a new key past the cap is refused while none is idle for a minute")
    t = 200000000; ok(allow(11), "rate: idle keys make room")
end

-- ---------------------------------------------------------------- the snapshot
do
    local recs = { [34] = (P.decodeReport("nucleus=" .. V0 .. ",skeltest=0.1.0")), [12] = (P.decodeReport("nucleus=" .. V0)) }
    local s = P.encodeSnapshot(5, (P.decodeReport("nucleus=" .. V0 .. ",skeltest=0.1.0")), recs)
    eq(s, "5:nucleus=" .. V0 .. ",skeltest=0.1.0;12:nucleus=" .. V0 .. ";34:nucleus=" .. V0 .. ",skeltest=0.1.0", "snapshot: local first, then PlayerId order")
    local snap = P.decodeSnapshot(s)
    ok(snap.localPid == 5 and snap.localMap.skeltest.version == "0.1.0" and snap.records[34].skeltest.version == "0.1.0" and snap.records[12].skeltest == nil, "snapshot decode")
    ok(P.recordOf(snap, 5) == snap.localMap and P.recordOf(snap, 34) == snap.records[34] and P.recordOf(snap, 999999) == nil, "recordOf: local, client, unknown")
    eq(P.encodeSnapshot(nil, (P.decodeReport("nucleus=" .. V0)), nil), "-:nucleus=" .. V0, "snapshot: local PlayerId unknown")
    snap = P.decodeSnapshot("-:nucleus=" .. V0)
    ok(snap.localPid == nil and snap.localMap.nucleus ~= nil, "snapshot: '-' keeps the local list")
    snap = P.decodeSnapshot("")
    ok(snap and snap.localPid == nil and next(snap.records) == nil, "snapshot: empty")
    snap = P.decodeSnapshot("5:nucleus=" .. V0 .. ";x:garbage;7:" .. string.rep("a", 9000) .. ";8:Bad_Id=1.0.0,ok=1.0.0")
    ok(snap.records[7] == nil and snap.records[8] and snap.records[8].ok and not snap.records[8].Bad_Id, "snapshot: hostile records dropped or cleaned")
    ok(P.decodeSnapshot(string.rep("a", P.MAX_SNAPSHOT + 1)) == nil, "snapshot: over its cap refused")
end

-- ---------------------------------------------------------------- players.lua over fake UObjects
local PL = require("nucleus.net.players")
local LINES = {}
local function L(level) return function(f, ...) LINES[#LINES + 1] = level .. " " .. string.format(f, ...) end end
local log = { info = L("INFO"), warn = L("WARN"), error = L("ERROR"), debug = function() end }
local function lines(pat) local n = 0 for _, l in ipairs(LINES) do if l:find(pat) then n = n + 1 end end return n end
local function clearLines() LINES = {} end

local objects, nextHandle = {}, 0
PL.REF = {
    ref = function(o) nextHandle = nextHandle + 1; objects[nextHandle] = o; return nextHandle end,
    deref = function(h) local o = objects[h] if o and not o.dead then return o end return nil end,
    free = function(h) objects[h] = nil end,
}
PL.alive = function(o) return type(o) == "table" and o.isObject == true and not o.dead end

local SHARED = {}
ModRef = { SetSharedVariable = function(_, k, v) SHARED[k] = v end, GetSharedVariable = function(_, k) return SHARED[k] end }
FName = function(s) return s end
local function fname(s) return { ToString = function() return s end } end
local CLASS_FULL = "BlueprintGeneratedClass " .. PL.CLASS
local presenceClass = { isObject = true }
local HOOKS = {}
RegisterHook = function(path, fn) HOOKS[path] = fn return 1, 1 end
local FOUND = {}
FindAllOf = function(short) if short == PL.SHORT then return FOUND end return nil end

local serverT = 100.0
local function newPS(pid) return { isObject = true, GetPlayerId = function() return pid end } end
local function newPC(name, world, pid)
    local pc = { isObject = true, name = name }
    pc.PlayerState = pid and newPS(pid) or nil
    pc.GetFullName = function() return "BP_PC_C " .. world.path .. ":PersistentLevel." .. name end
    pc.GetFName = function() return fname(name) end
    return pc
end
local spawned = {}
local function newPresence(world, auth)
    local a = { isObject = true, auth = auth, CoreVersion = "", bReplicates = true, bAlwaysRelevant = true, reports = {} }
    local n = #spawned + 1
    a.name = "NucleusPresence_C_" .. n
    a.GetFName = function() return fname(a.name) end
    a.GetFullName = function() return "NucleusPresence_C " .. world.path .. ":PersistentLevel." .. a.name end
    a.GetClass = function() return { GetFullName = function() return CLASS_FULL end } end
    a.GetWorld = function() return world end
    a.HasAuthority = function() return a.auth end
    a.SetOwner = function(self, pc) self.owner = pc end
    a.GetOwner = function() return a.owner end
    a.K2_DestroyActor = function(self) self.dead = true end
    a.Nucleus_PresenceSetVersion = function(self, v) self.CoreVersion = v end
    a.Nucleus_SV_Report = function(self, r) self.reports[#self.reports + 1] = r end
    return a
end
local spawnFails = 0
local function newWorld(path)
    local w = { isObject = true, path = path, conns = {} }
    w.GetFullName = function() return "World " .. path end
    w.NetDriver = { isObject = true, ClientConnections = setmetatable({}, { __index = function(_, i) return w.conns[i] end }) }
    w.NetDriver.ClientConnections.GetArrayNum = function() return #w.conns end
    w.GameState = { GetServerWorldTimeSeconds = function() return serverT end }
    w.SpawnActor = function(self, cls, at, rot)
        if spawnFails > 0 then spawnFails = spawnFails - 1 return nil end
        local a = newPresence(self, true)
        spawned[#spawned + 1] = a
        return a
    end
    return w
end
StaticFindObject = function(path)
    if path == "/Script/Engine.Default__GameplayStatics" then
        return { GetPlayerController = function(_, world, i) return world.localPC end }
    end
    if path == "/Script/AssetRegistry.Default__AssetRegistryHelpers" then return { GetAsset = function() return presenceClass end } end
    return nil
end

local clockT = 0
local ROLE = "none"
PL.init({ log = log, setShared = function(k, v) SHARED[k] = v end, getShared = function(k) return SHARED[k] end,
          role = function() return ROLE end, now = function() return clockT end })
eq(SHARED["nucleus.net.presence"], "", "players: no snapshot before the first world")
ok(math.type(SHARED["nucleus.net.presence.gen"]) == "integer", "players: the gen is shared")

-- the local list and its channel ops
do
    eq(PL.op("net-mod", "skeltest=0.1.0"), "ok:registered", "net-mod: a dependent registers")
    eq(PL.op("net-mod", "skeltest=0.1.0"), "ok:unchanged", "net-mod: the same again is unchanged")
    eq(PL.op("net-mod", "skeltest=0.1.0/0.1.0"), "ok:registered", "net-mod: a netCompat change replaces it")
    eq(PL.op("net-mod", "skeltest=0.1.0"), "ok:registered", "net-mod: back without netCompat")
    ok(PL.op("net-mod", string.rep("a", 300)):find("^err:bad%-request payload is 300 bytes"), "net-mod: oversized")
    ok(PL.op("net-mod", "skeltest"):find("^err:bad%-request .* has no '='"), "net-mod: no '='")
    ok(PL.op("net-mod", "Bad_Id=1.0.0"):find("^err:bad%-request id 'Bad_Id' is not a normalized mod id"), "net-mod: bad id")
    ok(PL.op("net-mod", "x-y=1.0"):find("^err:bad%-request x%-y: version '1.0'"), "net-mod: bad version")
    ok(PL.op("net-mod", "x-y=1.0.0/1.1.0"):find("^err:bad%-request x%-y: netCompat 1.1.0 is above version 1.0.0"), "net-mod: netCompat above version")
    ok(PL.op("net-mod", "nucleus=9.9.9"):find("^err:bad%-request 'nucleus' is core's own entry"), "net-mod: core's own id")
    ok(PL.op("net-mod", nil):find("^err:bad%-request"), "net-mod: no payload")
    for i = 1, 30 do assert(PL.op("net-mod", "f" .. i .. "=1.0.0") == "ok:registered") end
    eq(#PL.localList(), 32, "net-mod: 32 entries (core, skeltest and 30)")
    ok(PL.op("net-mod", "f31=1.0.0"):find("^err:cap 32 entries, cap 32"), "net-mod: the 33rd entry is refused")
    eq(PL.op("net-mod", "f30=1.0.1"), "ok:registered", "net-mod: an existing entry still changes at the cap")
    for i = 1, 30 do assert(PL.op("net-mod-off", "f" .. i) == "ok:removed") end
    eq(PL.op("net-mod-off", "f1"), "ok:unknown", "net-mod-off: unknown id is ok (idempotent)")
    ok(PL.op("net-mod-off", "Bad_Id"):find("^err:bad%-request"), "net-mod-off: bad id")
    ok(PL.op("net-mod-off", "nucleus"):find("^err:bad%-request"), "net-mod-off: core's own entry stays")
    ok(PL.op("net-mod-off", ""):find("^err:bad%-request") and PL.op("net-mod-off", string.rep("a", 201)):find("^err:bad%-request"), "net-mod-off: empty, oversized")
    eq(P.encodeList(PL.localList()), "nucleus=" .. V0 .. ",skeltest=0.1.0", "the local list: core first, then skeltest")
    ok(PL.op("nope", "x"):find("^err:"), "an unknown op never raises")
end

-- the dependent's API, wired to players.lua through SHARED
local CL = require("nucleus.net.client")
local DLINES = {}
local dlog = { info = function(f, ...) DLINES[#DLINES + 1] = string.format(f, ...) end,
               warn = function(f, ...) DLINES[#DLINES + 1] = "WARN " .. string.format(f, ...) end,
               error = function(f, ...) DLINES[#DLINES + 1] = "ERROR " .. string.format(f, ...) end, debug = function() end }
local loops, nextLoop = {}, 0
LoopInGameThreadWithDelay = function(ms, fn) nextLoop = nextLoop + 1; loops[nextLoop] = { ms = ms, fn = fn } return nextLoop end
CancelDelayedAction = function(h) loops[h] = nil end
local function runLoops() for _, l in pairs(loops) do l.fn() end end
local roleGen = 0
local function setRole(r) ROLE = r; roleGen = roleGen + 1; SHARED["nucleus.net.role"] = r; SHARED["nucleus.net.gen"] = 1000 + roleGen end
CL._alive = function(o) return type(o) == "table" and o.isObject == true and not o.dead end
CL._isPlayerState = function(o) return o.GetPlayerId ~= nil end
CL._isObjectValue = function(v) return type(v) == "table" and v.isObject ~= nil end
-- the bad-args checks run on any userdata check; tables stand in for UObjects here
local realType = type
raises(function() CL.presence(1, "skeltest") end, "nucleus.net.presence: called before connect", "presence before connect raises")
CL.bind({ call = function() return false, "unused" end, log = dlog, id = "skeltest", micros = function() return clockT end })
local net = CL.API

-- no world yet
setRole("none")
do local v, why = net.presence(5, "skeltest") ok(v == nil and why == "no-world", "presence before the first world: nil, no-world") end
do local v, why = net.compatible(5, "skeltest") ok(v == false and why == "no-world", "compatible before the first world: false, no-world") end

-- bad arguments (one clean error each)
do
    local FN = "nucleus.net."
    raises(function() net.presence("x", "skeltest") end, FN .. "presence: player must be a PlayerState or an integer PlayerId, got string", "presence: player a string")
    raises(function() net.presence(nil, "skeltest") end, FN .. "presence: player must be a PlayerState or an integer PlayerId, got nil", "presence: player nil")
    raises(function() net.presence(1.5, "skeltest") end, FN .. "presence: player must be a PlayerState or an integer PlayerId, got 1.5", "presence: player 1.5")
    raises(function() net.presence(2 ^ 40, "skeltest") end, "is outside -2147483648..2147483647", "presence: player id out of range")
    raises(function() net.presence(true, "skeltest") end, "got boolean", "presence: player a boolean")
    raises(function() net.presence(1, 5) end, FN .. "presence: modId must be a string, got number", "presence: modId a number")
    raises(function() net.presence(1, "") end, FN .. "presence: modId is empty", "presence: modId empty")
    raises(function() net.presence(1, "Bad_Id") end, FN .. "presence: modId 'Bad_Id' is not a normalized mod id", "presence: modId Bad_Id")
    raises(function() net.presence(1, string.rep("a", 65)) end, "is not a normalized mod id", "presence: modId a 65-character bare id")
    raises(function() net.presence(1, string.rep("a", 201)) end, FN .. "presence: modId is 201 characters, cap 200", "presence: modId 201 characters")
    raises(function() net.presence(1, "skeltest", 3) end, FN .. "presence: takes 2 arguments", "presence: three arguments")
    raises(function() net.watchPresence("skeltest", "fn") end, FN .. "watchPresence: fn must be a function, got string", "watchPresence: fn not a function")
    raises(function() net.watchPresence(nil, function() end) end, FN .. "watchPresence: modId must be a string, got nil", "watchPresence: modId nil")
    raises(function() net.compatible({}, "skeltest") end, "got table", "compatible: player a table (not a live object)")
    raises(function() net.compatible(1, 7) end, FN .. "compatible: modId must be a string, got number", "compatible: modId a number")
    -- versionsCompatible
    raises(function() net.versionsCompatible("1.0", nil, "1.0.0", nil) end, FN .. "versionsCompatible: aVersion '1.0' is not a strict", "versionsCompatible: '1.0' raises")
    raises(function() net.versionsCompatible("1.0.0", nil, 5, nil) end, FN .. "versionsCompatible: bVersion must be a string, got number", "versionsCompatible: a number")
    raises(function() net.versionsCompatible("1.0.0", "1.1.0", "1.0.0", nil) end, FN .. "versionsCompatible: aNetCompat 1.1.0 is above aVersion 1.0.0", "versionsCompatible: netCompat above version")
    raises(function() net.versionsCompatible("1.0.0", "x", "1.0.0", nil) end, "aNetCompat 'x' is not a strict", "versionsCompatible: bad netCompat")
    raises(function() net.versionsCompatible("1.0.0", nil, "1.0.0", nil, 1) end, "takes 4 arguments", "versionsCompatible: five arguments")
    eq(net.versionsCompatible("0.1.0", nil, "0.1.9", nil), true, "versionsCompatible row 1")
    eq(net.versionsCompatible("1.2.0", nil, "1.9.0", nil), true, "versionsCompatible row 2")
    eq(net.versionsCompatible("0.3.0", "0.1.0", "0.1.0", nil), true, "versionsCompatible row 3")
    eq(net.versionsCompatible("0.3.0", nil, "0.1.0", nil), false, "versionsCompatible row 4")
end

-- dead objects and non-PlayerStates
do
    local dead = newPS(3); dead.dead = true
    raises(function() net.presence(dead, "skeltest") end, "nucleus.net.presence: player is not a live object", "presence: a dead object")
    raises(function() net.presence({ isObject = true }, "skeltest") end, "nucleus.net.presence: player is not a PlayerState", "presence: a live object that isn't a PlayerState")
end

-- standalone (the menu): the local record only
local menu = newWorld("/Game/Maps/NewMainMenu.NewMainMenu")
menu.localPC = newPC("PC_menu", menu, 256)
setRole("standalone")
PL.onLoadMap(menu)
PL.tick()
eq(SHARED["nucleus.net.presence"], "256:nucleus=" .. V0 .. ",skeltest=0.1.0", "standalone: the local record in the snapshot")
eq(net.presence(256, "skeltest"), "0.1.0", "standalone: presence of the local player (PlayerId)")
eq(net.presence(menu.localPC.PlayerState, "skeltest"), "0.1.0", "standalone: presence of the local player (PlayerState)")
eq(net.presence(256, "nucleus"), V0, "standalone: core's own entry")
do local v, why = net.presence(999999, "skeltest") ok(v == nil and why == "absent", "unknown PlayerId: nil, absent") end
do local v, why = net.presence(256, "notinstalled") ok(v == nil and why == "absent", "mod not in the record: nil, absent") end
eq(net.compatible(256, "skeltest"), true, "compatible: the local player with itself")
do local v, why = net.compatible(256, "notinstalled") ok(v == false and why == "absent", "compatible: a mod not installed locally: absent") end
eq(#spawned, 0, "standalone: no actor spawned")

-- watchPresence: the local player included, changes, a faulty watcher logged once, unwatch shares story 22's
local EV = {}
local wid = net.watchPresence("skeltest", function(ev, pid, v, prev) EV[#EV + 1] = string.format("%s %d %s %s", ev, pid, tostring(v), tostring(prev)) end)
ok(math.type(wid) == "integer", "watchPresence returns an integer id")
local bad = net.watchPresence("skeltest", function() error("boom") end)
runLoops()
eq(table.concat(EV, "|"), "joined 256 0.1.0 nil", "watch: joined for the local player at the first poll")
PL.op("net-mod", "skeltest=0.1.1")
runLoops()
eq(EV[2], "changed 256 0.1.1 0.1.0", "watch: changed when the local list changes")
runLoops()
eq(#EV, 2, "watch: nothing more without a change")
PL.op("net-mod", "skeltest=0.1.0")
runLoops()
eq(#DLINES, 1, "watch: a faulty watcher is logged once")
ok(DLINES[1] and DLINES[1]:find("presence watch " .. bad .. " %(skeltest%) failed: .*boom"), "watch: the fault line", DLINES[1])
eq(net.unwatch(bad), true, "unwatch takes a presence watch id")
eq(net.unwatch(bad), false, "unwatch again: false")
do
    local ids = {}
    for _ = 1, 63 do ids[#ids + 1] = net.watchPresence("skeltest", function() end) end
    raises(function() net.watchPresence("skeltest", function() end) end, "nucleus.net.watchPresence: 64 presence watches in this mod, cap 64", "watchPresence: the 65th in a state")
    for _, id in ipairs(ids) do net.unwatch(id) end
end

-- a host world: B's controller appears, its actor is spawned and owned, B reports
local match = newWorld("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap")
match.localPC = newPC("PC_host", match, 256)
setRole("host")
EV = {}
clearLines()
PL.onLoadMap(match)
runLoops()
eq(table.concat(EV, "|"), "", "a new world with the same local PlayerId and list: no event (the record didn't change between polls)")
EV = {}
local B = newPC("PC_B", match, 300)
match.conns = { { isObject = true, PlayerController = B } }
PL.tick()
eq(#spawned, 1, "host: one actor for B's controller")
local actor = spawned[1]
ok(actor.owner == B, "host: the actor is owned by B's controller (SetOwner)")
eq(actor.CoreVersion, V0, "host: CoreVersion set through the setter")
eq(lines("PRESENCE saw controller PC_B %(player 300%) server=100.000"), 1, "host: one 'saw controller' line with the server clock")
eq(lines("PRESENCE spawned NucleusPresence_C_1 for PC_B .* owner=PC_B "), 1, "host: the spawn line names the owner")
ok(HOOKS[PL.HOOK] ~= nil, "host: <Core>_PresenceIn is hooked")
PL.tick()
eq(#spawned, 1, "host: no second actor for the same controller")

local function report(a, s, n)
    HOOKS[PL.HOOK]({ get = function() return a end }, { get = function() return s end }, { get = function() return n or #s end })
end
clockT = 10000000
report(actor, "nucleus=" .. V0 .. ",skeltest=0.1.0")
eq(net.presence(300, "skeltest"), "0.1.0", "joins: presence(B, skeltest) == 0.1.0")
eq(net.presence(B.PlayerState, "nucleus"), V0, "joins: presence by B's PlayerState")
eq(net.presence(256, "skeltest"), "0.1.0", "host: its own record is the local list")
runLoops()
eq(table.concat(EV, "|"), "joined 300 0.1.0 nil", "watch: joined for B")
eq(lines("PRESENCE record player 300: nucleus=" .. V0:gsub("%.", "%%.") .. ",skeltest=0%.1%.0 %(joined 2, changed 0, left 0%)"), 1, "host: the record line")
eq(net.compatible(300, "skeltest"), true, "compatible: B 0.1.0")

-- compatibility rows against the host's skeltest 0.1.0 (no netCompat)
for _, row in ipairs({ { "0.1.4", nil, true }, { "0.2.0", nil, false }, { "0.2.0", "0.1.0", true } }) do
    clockT = clockT + 2000000
    report(actor, "nucleus=" .. V0 .. ",skeltest=" .. row[1] .. (row[2] and ("/" .. row[2]) or ""))
    local r, why = net.compatible(300, "skeltest")
    ok(r == row[3] and (row[3] or why == "incompatible"), "compatible: B " .. row[1] .. (row[2] and (" netCompat " .. row[2]) or ""), tostring(r) .. " " .. tostring(why))
end
clockT = clockT + 2000000
report(actor, "nucleus=" .. V0)
do local r, why = net.compatible(300, "skeltest") ok(r == false and why == "absent", "compatible: B without skeltest: absent") end

-- the forge sequence: one reject line for B, the host's own record unchanged
clearLines()
local hostRec = P.encodeList(PL.localList())
clockT = clockT + 2000000
report(actor, "nucleus=" .. V0 .. ",skeltest=0.1.0")
local function bRec() return P.encodeList((P.decodeReport(SHARED["nucleus.net.presence"]:match(";300:([^;]*)")))) end
eq(bRec(), "nucleus=" .. V0 .. ",skeltest=0.1.0", "forge 0: core's own report")
local parts = {}
for i = 1, 33 do parts[i] = "m" .. i .. "=1.0.0" end
clockT = clockT + 2000000
report(actor, table.concat(parts, ","))
eq(bRec(), "nucleus=" .. V0 .. ",skeltest=0.1.0", "forge 1: 33 pairs, record unchanged")
clockT = clockT + 2000000
report(actor, "", 9000) -- the Blueprint passes "" with Len 9000
eq(bRec(), "nucleus=" .. V0 .. ",skeltest=0.1.0", "forge 2: 9000 characters, record unchanged")
clockT = clockT + 2000000
report(actor, "nucleus=" .. V0 .. ",Bad_Id=1.0.0,skeltest=1.0.1000,1:skeltest=9.9.9,skeltest-forge=1.0.0")
eq(bRec(), "nucleus=" .. V0 .. ",skeltest-forge=1.0.0", "forge 3: bad pairs dropped")
clockT = clockT + 2000000
for _ = 1, 50 do report(actor, "nucleus=" .. V0 .. ",skeltest=7.7.7") end
eq(bRec(), "nucleus=" .. V0 .. ",skeltest=7.7.7", "forge 4: 50 in one tick, the first accepted")
eq(P.encodeList(PL.localList()), hostRec, "forge: the host's own record unchanged")
eq(lines("^WARN PRESENCE"), 1, "forge: exactly one presence-reject line for B")
do local r, why = net.compatible(300, "skeltest") ok(r == false and why == "incompatible", "forge: compatible(B) false, incompatible") end

-- a report on an actor that isn't in the table, or whose owner changed: nothing recorded
do
    local stray = newPresence(match, true)
    stray.owner = B
    clockT = clockT + 61000000
    report(stray, "nucleus=" .. V0 .. ",skeltest=1.2.3")
    eq(bRec(), "nucleus=" .. V0 .. ",skeltest=7.7.7", "a report on a stray actor changes nothing")
    actor.owner = newPC("PC_other", match, 301)
    clockT = clockT + 2000000
    report(actor, "nucleus=" .. V0 .. ",skeltest=1.2.3")
    eq(bRec(), "nucleus=" .. V0 .. ",skeltest=7.7.7", "a report whose owner is not B's controller changes nothing")
    actor.owner = B
end

-- a forged identity is impossible: the report text names nobody; B's PlayerState decides
do
    local C = newPC("PC_C", match, 400)
    match.conns[2] = { isObject = true, PlayerController = C }
    PL.tick()
    local cActor = spawned[#spawned]
    ok(cActor.owner == C, "a second client gets its own actor")
    clockT = clockT + 2000000
    report(cActor, "nucleus=" .. V0 .. ",skeltest=0.1.0")
    eq(net.presence(400, "skeltest"), "0.1.0", "C's record")
    eq(bRec(), "nucleus=" .. V0 .. ",skeltest=7.7.7", "C's report doesn't touch B's record")
    EV = {}
    runLoops()
    eq(table.concat(EV, "|"), "changed 300 7.7.7 0.1.0|joined 400 0.1.0 nil", "watch: B changed, C joined")
    -- C leaves
    EV = {}
    match.conns[2] = nil
    clearLines()
    PL.tick()
    ok(cActor.dead, "leave: C's actor destroyed (K2_DestroyActor)")
    do local v, why = net.presence(400, "skeltest") ok(v == nil and why == "absent", "leave: presence(C) nil, absent") end
    runLoops()
    eq(table.concat(EV, "|"), "left 400 nil 0.1.0", "leave: left for C")
    eq(lines("PRESENCE player 400 left %(PC_C%): 2 mod%(s%) removed"), 1, "leave: the line")
end

-- B leaves
EV = {}
match.conns = {}
PL.tick()
ok(actor.dead, "B leaves: its actor destroyed")
do local v, why = net.presence(300, "skeltest") ok(v == nil and why == "absent", "B leaves: presence(B) nil, absent") end
runLoops()
eq(table.concat(EV, "|"), "left 300 nil 7.7.7", "B leaves: left for each of B's mods (skeltest)")
eq(net.unwatch(wid), true, "unwatch the presence watch")

-- the cap: at most 64 client records (actors); beyond that one line
do
    clearLines()
    match.conns = {}
    for i = 1, 66 do match.conns[i] = { isObject = true, PlayerController = newPC("PC_" .. i, match, 1000 + i) } end
    local before = #spawned
    PL.tick()
    eq(#spawned - before, 64, "cap: 64 client actors")
    eq(lines("PRESENCE 64 client players already tracked in this world, cap 64"), 1, "cap: one line")
    PL.tick()
    eq(lines("already tracked"), 1, "cap: still one line")
    match.conns = {}
    PL.tick()
end

-- spawn failures: retried, then one ERROR line
do
    clearLines()
    spawnFails = 10
    local D = newPC("PC_D", match, 500)
    match.conns = { { isObject = true, PlayerController = D } }
    for _ = 1, 8 do clockT = clockT + 1000000; PL.tick() end
    eq(lines("^ERROR PRESENCE could not spawn"), 1, "spawn: five tries, one ERROR line")
    spawnFails = 0
    match.conns = {}
    PL.tick()
end

-- not the host: the hook ignores reports
do
    local menu2 = newWorld("/Game/Maps/NewMainMenu.NewMainMenu")
    menu2.localPC = newPC("PC_m2", menu2, 256)
    setRole("standalone")
    PL.onLoadMap(menu2)
    clockT = clockT + 61000000
    report(actor, "nucleus=" .. V0)
    eq(SHARED["nucleus.net.presence"], "256:nucleus=" .. V0 .. ",skeltest=0.1.0", "standalone: a stray report changes nothing")
end

-- ---------------------------------------------------------------- the client side
local cw = newWorld("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap")
cw.localPC = newPC("PC_local", cw, 300)
setRole("client")
clearLines()
PL.onLoadMap(cw)
eq(SHARED["nucleus.net.presence"], "", "client: no snapshot")
raises(function() net.presence(300, "skeltest") end, "nucleus.net.presence: only the host knows presence (this machine is a client)", "client: presence raises")
raises(function() net.watchPresence("skeltest", function() end) end, "nucleus.net.watchPresence: only the host knows presence (this machine is a client)", "client: watchPresence raises")
raises(function() net.compatible(300, "skeltest") end, "nucleus.net.compatible: only the host knows presence (this machine is a client)", "client: compatible raises")
eq(net.versionsCompatible("0.1.0", nil, "0.1.2", nil), true, "client: versionsCompatible works anywhere")
do
    -- another player's actor (owned by a controller this machine doesn't have) and the own one, by NotifyOnNewObject
    local other = newPresence(cw, false)
    other.owner = nil
    local own = newPresence(cw, false)
    own.owner = cw.localPC
    own.CoreVersion = ""
    PL.onNewObject(other)
    PL.onNewObject(own)
    PL.tick()
    eq(lines("PRESENCE holding NucleusPresence_C_%d+ %(NotifyOnNewObject%)"), 1, "client: holds its own actor (NotifyOnNewObject)")
    eq(#own.reports, 0, "client: waits for CoreVersion to replicate")
    own.CoreVersion = V0
    PL.tick()
    eq(#own.reports, 1, "client: sends once on acquire")
    eq(own.reports[1], "nucleus=" .. V0 .. ",skeltest=0.1.0", "client: the report is the local list")
    eq(#other.reports, 0, "client: never reports on another player's actor")
    PL.tick()
    eq(#own.reports, 1, "client: no resend without a change")
    PL.op("net-mod", "late-mod=1.0.0")
    clockT = clockT + 1000000; PL.tick()
    eq(#own.reports, 1, "client: not yet 1 s after a change")
    clockT = clockT + 1000001; PL.tick()
    eq(#own.reports, 2, "client: again 2 s after a change")
    eq(own.reports[2], "nucleus=" .. V0 .. ",skeltest=0.1.0,late-mod=1.0.0", "client: the changed list")
    PL.op("net-mod-off", "late-mod")
end
-- a failed send is retried 2 s later in the same world
do
    local cwr = newWorld("/Game/Maps/Retry.Retry")
    cwr.localPC = newPC("PC_retry", cwr, 303)
    PL.onLoadMap(cwr)
    clearLines()
    local own = newPresence(cwr, false)
    own.owner = cwr.localPC
    own.CoreVersion = V0
    local fails = 1
    own.Nucleus_SV_Report = function(self, r) if fails > 0 then fails = fails - 1 error("rpc failed") end self.reports[#self.reports + 1] = r end
    PL.onNewObject(own)
    PL.tick()
    eq(#own.reports, 0, "send failure: nothing sent")
    eq(lines("^WARN PRESENCE could not send the report .*rpc failed; retrying in 2 s"), 1, "send failure: one line")
    clockT = clockT + 1000000; PL.tick()
    eq(#own.reports, 0, "send failure: no retry within 2 s")
    clockT = clockT + 1000001; PL.tick()
    eq(#own.reports, 1, "send failure: retried 2 s later")
    eq(own.reports[1], "nucleus=" .. V0 .. ",skeltest=0.1.0", "send failure: the retry carries the local list")
    clockT = clockT + 3000000; PL.tick()
    eq(#own.reports, 1, "send failure: no further sends after the retry worked")
end

-- the FindAllOf fallback, and a version mismatch: never reports, one line per world
do
    local cw2 = newWorld("/Game/Maps/Other.Other")
    cw2.localPC = newPC("PC_local2", cw2, 301)
    PL.onLoadMap(cw2)
    clearLines()
    local own = newPresence(cw2, false)
    own.owner = cw2.localPC
    own.CoreVersion = "0.11.0"
    local spawnedHere = newPresence(cw2, true) -- authority: spawned on this machine, never ours
    spawnedHere.owner = cw2.localPC
    FOUND = { spawnedHere, own }
    clockT = clockT + 3000000
    PL.tick()
    eq(lines("PRESENCE holding NucleusPresence_C_%d+ %(FindAllOf%)"), 1, "client: the FindAllOf fallback finds the own actor")
    for _ = 1, 5 do clockT = clockT + 1000000; PL.tick() end
    eq(#own.reports, 0, "version mismatch: never reports")
    eq(#spawnedHere.reports, 0, "an actor with authority is never ours")
    eq(lines("^WARN PRESENCE ignoring my NucleusPresence_C_%d+: its core version is '0.11.0', this core is " .. V0:gsub("%.", "%%.")), 1, "version mismatch: one line in the world")
    -- a long CoreVersion is never copied
    local cw3 = newWorld("/Game/Maps/Third.Third")
    cw3.localPC = newPC("PC_local3", cw3, 302)
    PL.onLoadMap(cw3)
    local long = newPresence(cw3, false)
    long.owner = cw3.localPC
    local copied = false
    long.CoreVersion = { Len = function() return 9000 end, ToString = function() copied = true return string.rep("x", 9000) end }
    FOUND = { long }
    clockT = clockT + 3000000
    PL.tick()
    ok(not copied and #long.reports == 0, "a 9000-character CoreVersion is never copied, and nothing is sent")
    FOUND = {}
end

-- unload: the snapshot empties with a new gen
do
    local g = SHARED["nucleus.net.presence.gen"]
    setRole("host")
    PL.onLoadMap(match)
    PL.tick()
    ok(SHARED["nucleus.net.presence"] ~= "", "host again: a snapshot")
    PL.stop(); PL.unload()
    ok(SHARED["nucleus.net.presence"] == "" and SHARED["nucleus.net.presence.gen"] > g, "unload: empty snapshot, new gen")
    -- a hot reload keeps the gen rising
    local g2 = SHARED["nucleus.net.presence.gen"]
    PL.init({ log = log, setShared = function(k, v) SHARED[k] = v end, getShared = function(k) return SHARED[k] end, role = function() return ROLE end, now = function() return clockT end })
    ok(SHARED["nucleus.net.presence.gen"] >= g2, "init after unload: the gen doesn't go back")
end

-- ---------------------------------------------------------------- ownManifest (connect's mod.json reader)
do
    local DIR = (ROOT .. "/build/unit-presence/Mods"):gsub("/", "\\")
    os.execute('rmdir /s /q "' .. DIR .. '" >nul 2>nul')
    for _, d in ipairs({ "A", "B", "C", "D", "E", "F", "G", "H" }) do os.execute('mkdir "' .. DIR .. '\\' .. d .. '" >nul 2>nul') end
    local function write(p, t) local f = assert(io.open(p, "wb")) f:write(t) f:close() end
    write(DIR .. "\\A\\mod.json", '{ "id": "skeltest", "version": "0.1.0" }')
    write(DIR .. "\\B\\mod.json", '{ "id": "github.com/NuclearNightmare-Community.skeltest-ns", "version": "0.3.0", "netCompat": "0.1.0" }')
    write(DIR .. "\\C\\mod.json", '{ "id": "x-c", "version": "1.0" }')
    write(DIR .. "\\D\\mod.json", '{ "id": "x-d", "version": "1.0.0", "netCompat": "1.1.0" }')
    write(DIR .. "\\E\\mod.json", '{ "id": "x-e", "version": "1.0.0", "netCompat": 5 }')
    -- Distribution story 14: scope for connect's host gate (a short string as written, else nil).
    write(DIR .. "\\F\\mod.json", '{ "id": "x-f", "version": "1.0.0", "scope": "host" }')
    write(DIR .. "\\G\\mod.json", '{ "id": "x-g", "version": "1.0.0", "scope": 5 }')
    write(DIR .. "\\H\\mod.json", '{ "id": "x-h", "version": "1.0.0", "scope": "' .. string.rep("h", 33) .. '" }')
    local m = CL.ownManifest(DIR, "A")
    ok(m and m.id == "skeltest" and m.version == "0.1.0" and m.netCompat == nil and #m.notes == 0, "ownManifest: id and version")
    m = CL.ownManifest(DIR, "B")
    ok(m and m.id == "nuclearnightmare-community.skeltest-ns" and m.version == "0.3.0" and m.netCompat == "0.1.0", "ownManifest: namespaced id normalized, netCompat")
    m = CL.ownManifest(DIR, "C")
    ok(m and m.version == nil and #m.notes == 1 and m.notes[1]:find("not reported", 1, true), "ownManifest: a version that isn't strict is not reported, with a note", m and m.notes[1])
    m = CL.ownManifest(DIR, "D")
    ok(m and m.version == "1.0.0" and m.netCompat == nil and #m.notes == 1 and m.notes[1]:find("above version", 1, true), "ownManifest: netCompat above version left out, with a note", m and m.notes[1])
    m = CL.ownManifest(DIR, "E")
    ok(m and m.netCompat == nil and #m.notes == 1, "ownManifest: a non-string netCompat left out, with a note")
    m = CL.ownManifest(DIR, "A")
    ok(m and m.scope == nil, "ownManifest: no scope in mod.json gives nil")
    m = CL.ownManifest(DIR, "F")
    ok(m and m.scope == "host", "ownManifest: scope host", m and m.scope)
    m = CL.ownManifest(DIR, "G")
    ok(m and m.scope == nil, "ownManifest: a non-string scope gives nil", m and m.scope)
    m = CL.ownManifest(DIR, "H")
    ok(m and m.scope == nil, "ownManifest: a 33-byte scope gives nil", m and m.scope)
    eq(CL.ownId(DIR, "A"), "skeltest", "ownId still answers")
end

-- ---------------------------------------------------------------- connect's registration and its OnUnload chain
do
    local C = require("nucleus.client")
    local realCall = C.call
    C.call = function(op, payload)
        local r = PL.op(op, payload)
        if r:sub(1, 3) == "ok:" then return true, r:sub(4) end
        return false, r
    end
    local clog = { info = function() end, warn = function(f, ...) DLINES[#DLINES + 1] = "WARN " .. string.format(f, ...) end, error = function() end }
    local prevRan = 0
    ModRef.OnUnload = function() prevRan = prevRan + 1 end
    C._registerPresence({ id = "unload-mod", version = "1.2.3", netCompat = "1.0.0", notes = {} }, nil, clog)
    ok(P.encodeList(PL.localList()):find("unload-mod=1.2.3/1.0.0", 1, true) ~= nil, "connect: the mod is registered with its netCompat")
    ModRef.OnUnload()
    ok(P.encodeList(PL.localList()):find("unload-mod", 1, true) == nil, "unload: net-mod-off removed the mod from the local list")
    eq(prevRan, 1, "unload: the previous OnUnload still ran")
    -- a mod without a strict version is not registered and chains nothing
    local before = ModRef.OnUnload
    C._registerPresence({ id = "noversion-mod", notes = { "mod.json version: x" } }, nil, clog)
    ok(P.encodeList(PL.localList()):find("noversion-mod", 1, true) == nil and ModRef.OnUnload == before, "connect: no strict version: not registered, no unload chain")
    C.call = realCall
end

-- ---------------------------------------------------------------- features
do
    local F = require("nucleus.features")
    local set = F.set(F.declared())
    for _, n in ipairs({ "net.presence", "net.watchPresence", "net.compatible", "net.versionsCompatible" }) do ok(set[n] == true, "features: " .. n) end
    for _, n in ipairs({ "presence", "watchPresence", "compatible", "versionsCompatible" }) do ok(type(CL.API[n]) == "function", "core.net." .. n .. " is in the api") end
end

print(("net_presence_test: %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
