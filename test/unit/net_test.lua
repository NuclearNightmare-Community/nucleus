-- Unit tests for core.net (core story 22, Net-1), outside the game: the mod id normalizer (lua/pkg/modid.lua), the
-- pure state module (validation, caps, State encode and bounded decode, reads, the limiter), core's owner
-- (lua/pkg/net/host.lua: roles, the channel op, spawn and setter writes, the client's find/version/decode path) over
-- fake UObjects, and the dependent's core.net (lua/pkg/net/client.lua) wired to that owner through fake shared
-- variables and a fake channel. Every row of the story's I/O matrix.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  texlua test/unit/net_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
local VERSION = { name = "Nucleus", version = "0.11.0", floor = "0.1.0" }
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

local LINES = {}
local realPrint = print
print = function(s) LINES[#LINES + 1] = (tostring(s):gsub("\n$", "")) end
local function linesMatching(pat) local n = 0 for _, l in ipairs(LINES) do if l:find(pat) then n = n + 1 end end return n end
local function clearLines() LINES = {} end

local pass, fail = 0, 0
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else fail = fail + 1; realPrint("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")) end
end
local function eq(got, want, name) ok(got == want, name, "got " .. tostring(got) .. ", want " .. tostring(want)) end
local function raises(fn, text, name)
    local okC, err = pcall(fn)
    ok(not okC and tostring(err):find(text, 1, true) ~= nil, name, okC and "did not raise" or tostring(err))
end

-- ---------------------------------------------------------------- the normalizer (mod-ids.md cases, + legacy bare)
local ID = require("nucleus.modid")
do
    local function norm(id, want, name) local okP, got, err = pcall(ID.normalize, id) ok(okP and got == want, "normalize: " .. name, tostring(got) .. " / " .. tostring(err)) end
    local function refused(id, part, name)
        local okP, got, err = pcall(ID.normalize, id)
        ok(okP and got == nil and type(err) == "string" and (not part or err:find(part, 1, true) ~= nil), "normalize refused: " .. name, tostring(got) .. " / " .. tostring(err))
    end
    norm("nuclearnightmare-community.waypoints", "nuclearnightmare-community.waypoints", "<owner>.<mod>")
    norm("github.com/NuclearNightmare-Community.waypoints", "nuclearnightmare-community.waypoints", "github.com/<owner>.<mod>")
    norm("NuclearNightmare-Community.Nucleus", "nuclearnightmare-community.nucleus", "lowercased")
    norm("GitHub.com/NuclearNightmare-Community.nucleus", "nuclearnightmare-community.nucleus", "the prefix in any case")
    norm("nuclearnightmare-community.base-installer", "nuclearnightmare-community.base-installer", "a hyphen in the mod part")
    norm("a.b", "a.b", "the shortest id")
    refused("gitlab.com/alice.waypoints", "another host", "another host")
    refused("gitlab.com/group/sub.waypoints", "another host", "a subgroup on another host")
    refused("www.github.com/NuclearNightmare-Community.waypoints", "accepted forms", "www.github.com/")
    refused("http://github.com/NuclearNightmare-Community.waypoints", "accepted forms", "http://")
    refused("https://github.com/NuclearNightmare-Community.waypoints", "accepted forms", "https://")
    refused("nucleus", "no namespace", "a bare id")
    refused("other.nucleus.x", "not an id", "a dot in a GitHub owner")
    refused("owner.mod_name", "not an id", "an underscore in the mod part")
    refused("owner.", "not an id", "an empty mod part")
    refused(".mod", "not an id", "an empty owner")
    refused(" owner.mod", "not an id", "a leading space")
    refused("", "empty", "empty")
    refused(string.rep("a", 100) .. "." .. string.rep("b", 100), "at most 200", "201 characters")
    norm(string.rep("a", 100) .. "." .. string.rep("b", 99), string.rep("a", 100) .. "." .. string.rep("b", 99), "200 characters")
    for _, x in ipairs({ 1, true, {}, false }) do refused(x, "must be a string", "a " .. type(x)) end
    do local okP, got = pcall(ID.normalize) ok(okP and got == nil, "normalize(nil): refused, never raises") end
    -- the net id: legacy bare ids too (spikes, test dependents), lowercased
    eq(ID.netId("skeltest"), "skeltest", "netId: a legacy bare id")
    eq(ID.netId("SkelTest"), "skeltest", "netId: a bare id is lowercased")
    eq(ID.netId(string.rep("a", 64)), string.rep("a", 64), "netId: a 64-character bare id")
    eq(ID.netId(string.rep("a", 65)), nil, "netId: a 65-character bare id is refused")
    eq(ID.netId("github.com/Owner.Mod"), "owner.mod", "netId: a namespaced id normalized")
    ok(ID.isNetId("skeltest") and ID.isNetId("nuclearnightmare-community.skeltest-ns"), "isNetId: normalized forms")
    ok(not ID.isNetId("SkelTest") and not ID.isNetId("github.com/owner.mod") and not ID.isNetId("Bad..Id") and not ID.isNetId(5), "isNetId: not normalized")
end

-- ---------------------------------------------------------------- state: checks
local S = require("nucleus.net.state")
do
    local id, name = S.splitKey("skeltest.revivesN")
    ok(id == "skeltest" and name == "revivesN", "splitKey: bare id", tostring(id) .. " " .. tostring(name))
    id, name = S.splitKey("nuclearnightmare-community.skeltest-ns.x")
    ok(id == "nuclearnightmare-community.skeltest-ns" and name == "x", "splitKey: namespaced id, split at the last dot")
    ok(S.splitKey("nodot") == nil, "splitKey: no dot")
    ok(S.splitKey("skeltest." .. string.rep("a", 33)) == nil, "splitKey: name 33 chars")
    ok(S.splitKey("skeltest." .. string.rep("a", 32)) ~= nil, "splitKey: name 32 chars")
    ok(S.splitKey("skeltest.a-b") == nil and S.splitKey("skeltest.a b") == nil and S.splitKey("skeltest.") == nil, "splitKey: bad name characters, empty name")
    ok(S.splitKey(string.rep("k", 10240)) == nil, "splitKey: a 10 kB key")
    ok(S.splitKey(5) == nil and S.splitKey(nil) == nil, "splitKey: non-string")
    ok(S.splitKey("Bad..Id.x") == nil and S.splitKey("SkelTest.x") == nil and S.splitKey("github.com/a.b.x") == nil, "splitKey: an id not in normalized form")
    eq(S.checkInt(8), 8, "checkInt: 8")
    eq(math.type(S.checkInt(8.0)), "integer", "checkInt: 8.0 -> integer")
    eq(S.checkInt(-2147483648), -2147483648, "checkInt: INT_MIN")
    eq(S.checkInt(2147483647), 2147483647, "checkInt: INT_MAX")
    for _, bad in ipairs({ { nil, "nil" }, { "8", "string" }, { 2.5, "2.5" }, { 0 / 0, "NaN" }, { math.huge, "inf" }, { -math.huge, "-inf" }, { 2 ^ 31, "2^31" }, { 2 ^ 53, "2^53" }, { 2147483648, "2147483648" } }) do
        ok(S.checkInt(bad[1]) == nil, "checkInt refuses " .. bad[2])
    end
end

-- ---------------------------------------------------------------- state: table, caps, encode
do
    local T = S.new()
    ok(S.put(T, "skeltest", "revivesN", 8), "put")
    eq(S.encode(T), "#1=skeltest,1.revivesN=8", "encode: the matrix example")
    local okP, changed = S.put(T, "skeltest", "revivesN", 8)
    ok(okP and changed == false, "put: same value is unchanged")
    S.put(T, "skeltest", "enemyDamage", 250)
    S.put(T, "nuclearnightmare-community.skeltest-ns", "x", 1)
    eq(S.encode(T), "#1=skeltest,1.revivesN=8,1.enemyDamage=250,#2=nuclearnightmare-community.skeltest-ns,2.x=1", "encode: the namespaced id once, behind #2")
    local D = S.decode(S.encode(T))
    eq(S.get(D, "nuclearnightmare-community.skeltest-ns.x"), 1, "decode: the namespaced key reads back by its full key")
    eq(S.encode(D), S.encode(T), "decode(encode(T)) round trip")
    -- caps
    local C = S.new()
    for i = 1, 16 do assert(S.put(C, "a", "k" .. i, i)) end
    local okC, code, why = S.put(C, "a", "k17", 17)
    ok(not okC and code == "cap" and why:find("per mod", 1, true), "put: 17th key of one mod refused", tostring(why))
    for m = 2, 4 do for i = 1, 16 do assert(S.put(C, "m" .. m, "k" .. i, i)) end end
    okC, code, why = S.put(C, "m5", "k1", 1)
    ok(not okC and code == "cap" and why:find("cap 64", 1, true), "put: 65th key in all refused", tostring(why))
    eq(C.count, 64, "64 keys held")
    local Mods = S.new()
    for m = 1, 16 do assert(S.put(Mods, "m" .. m, "x", m)) end
    okC, code, why = S.put(Mods, "m17", "x", 1)
    ok(not okC and why:find("publishing mods", 1, true), "put: 17th publishing mod refused", tostring(why))
    -- the largest State the caps allow fits in 8192 bytes (16 x 200-char ids, 64 x 32-char names, 11-char values)
    local Big = S.new()
    for m = 1, 16 do
        local id = string.format("%02d", m) .. string.rep("o", 97) .. "." .. string.rep("m", 100)
        assert(#id == 200 and ID.isNetId(id), "fixture id")
        for i = 1, 4 do assert(S.put(Big, id, string.format("%02d", i) .. string.rep("n", 30), -2147483648)) end
    end
    local big = S.encode(Big)
    ok(#big <= S.MAX_STATE, "the largest State within the caps fits: " .. #big .. " bytes")
    local DB, rj = S.decode(big)
    ok(DB.count == 64 and #rj == 0, "the largest State decodes whole")
end

-- ---------------------------------------------------------------- state: hostile State (client rules)
do
    local function dec(s) local T, r, whole = S.decode(s) return T, r, whole end
    local T, r, whole = dec(string.rep("x", 9 * 1024))
    ok(whole and T.count == 0 and #r == 1, "hostile: a 9 kB string is ignored whole")
    T, r, whole = dec(5)
    ok(whole and T.count == 0, "hostile: a non-string is ignored whole")
    T, r = dec("#1=skeltest,1.y=99999999999,1.z=3")
    ok(S.get(T, "skeltest.y") == nil and S.get(T, "skeltest.z") == 3 and #r == 1 and r[1].key == "skeltest.y", "hostile: 1.y=99999999999 dropped, the rest kept")
    T, r = dec("#1=skeltest,1.y=2147483648,1.w=-2147483649,1.v=+5,1.u=0x10,1.t=1e3,1.s=")
    ok(T.count == 0 and #r == 6, "hostile: out-of-range and non-decimal values dropped", #r)
    do
        local parts = { "#1=a" }
        for i = 1, 17 do parts[#parts + 1] = "1.k" .. i .. "=" .. i end
        T, r = dec(table.concat(parts, ","))
        ok(T.count == 16 and S.get(T, "a.k16") == 16 and S.get(T, "a.k17") == nil and #r == 1, "hostile: 17 entries for one mod: the 17th dropped")
    end
    T, r = dec("#1=a,3.x=1,1.y=2")
    ok(S.get(T, "a.y") == 2 and T.count == 1 and #r == 1 and r[1].why:find("no header", 1, true), "hostile: 3.x=1 with no #3 dropped")
    T, r = dec("#1=a,#1=b,1.x=1")
    ok(S.get(T, "a.x") == 1 and S.get(T, "b.x") == nil and #r == 1, "hostile: #1 listed twice: the first header kept")
    T, r = dec("#1=Bad..Id,1.x=1,#2=b,2.y=2")
    ok(T.count == 1 and S.get(T, "b.y") == 2 and #r == 2, "hostile: header id Bad..Id: it and its entries dropped", #r)
    T, r = dec("#1=Bad..Id,#1=good,1.x=1")
    ok(T.count == 0 and S.get(T, "good.x") == nil, "hostile: a bad header poisons its number (a later #1 doesn't take its entries)")
    T, r = dec("#1=a,#2=a,1.x=1,2.y=2")
    ok(S.get(T, "a.x") == 1 and S.get(T, "a.y") == nil, "hostile: one id under two numbers: the second header dropped")
    T, r = dec("#1=a,1.x=1,1.x=2")
    ok(S.get(T, "a.x") == 1 and #r == 1, "hostile: a duplicate key: the first kept")
    T, r = dec("hello world,;;;,#,#0=a,#17=a,#01=a,=,1.=2,1.a-b=3, ,\0")
    ok(T.count == 0 and #r >= 8, "hostile: garbage text dropped", #r)
    T, r = dec("#1=github.com/owner.mod,1.x=1,#2=SkelTest,2.y=1")
    ok(T.count == 0, "hostile: header ids not in normalized form dropped")
    do
        local parts = {}
        for i = 1, 200 do parts[#parts + 1] = "junk" .. i end
        T, r = dec(table.concat(parts, ","))
        ok(#r == S.MAX_REJECTS + 1 and r[#r].key == "*more", "hostile: rejects are bounded per decode", #r)
    end
    T, r, whole = dec("")
    ok(T.count == 0 and #r == 0 and not whole, "an empty State is no values, no rejects")
    ok(#S.encode(S.new()) == 0, "encode of nothing is empty")
end

-- ---------------------------------------------------------------- state: reads and the limiter
do
    local T = S.decode("#1=skeltest,1.revivesN=8,1.enemyDamage=250")
    eq(S.readResult("ok", T, "skeltest.revivesN", 0, 20), 8, "read in bounds")
    local v, why = S.readResult("ok", T, "skeltest.enemyDamage", 0, 200)
    ok(v == nil and why == "out-of-bounds", "read out of bounds")
    v, why = S.readResult("ok", T, "skeltest.never", 0, 200)
    ok(v == nil and why == "absent", "read absent")
    v, why = S.readResult("no-state", nil, "skeltest.revivesN", 0, 20)
    ok(v == nil and why == "no-state", "read with no state")
    v, why = S.readResult("version", nil, "skeltest.revivesN", 0, 20)
    ok(v == nil and why == "version", "read with a version mismatch")
    local t = 0
    local allow = S.limiter(function() return t end, 60000000, 3)
    ok(allow("a") and not allow("a"), "limiter: once per key")
    t = 59999999; ok(not allow("a"), "limiter: not within the minute")
    t = 60000000; ok(allow("a"), "limiter: again after a minute")
    ok(allow("b") and allow("c"), "limiter: other keys")
    ok(not allow("d"), "limiter: bounded table refuses a new key while none expired")
    t = 130000000; ok(allow("d"), "limiter: expired keys make room")
end

-- ---------------------------------------------------------------- host.lua over fake UObjects
-- Fake objects are tables; host.lua's liveness check and weak handles are replaced (M.alive, M.REF).
local function fname(s) return { ToString = function() return s end } end
local HOST = require("nucleus.net.host")
local CLASS_FULL = "BlueprintGeneratedClass " .. HOST.CLASS
local objects = {} -- handle -> object
local nextHandle = 0
HOST.REF = {
    ref = function(o) nextHandle = nextHandle + 1; objects[nextHandle] = o; return nextHandle end,
    deref = function(h) local o = objects[h] if o and not o.dead then return o end return nil end,
    free = function(h) objects[h] = nil end,
}
HOST.alive = function(o) return type(o) == "table" and o.isObject == true and not o.dead end

local SHARED = {}
ModRef = { SetSharedVariable = function(_, k, v) SHARED[k] = v end, GetSharedVariable = function(_, k) return SHARED[k] end }
FName = function(s) return s end
local loops, nextLoop = {}, 0
LoopInGameThreadWithDelay = function(ms, fn) nextLoop = nextLoop + 1; loops[nextLoop] = { ms = ms, fn = fn } return nextLoop end
CancelDelayedAction = function(h) loops[h] = nil end
local function runLoops() for h, l in pairs(loops) do l.fn() end end

local NET = { server = true, standalone = false }
local classObj = { isObject = true }
local spawnFails = 0
local spawned = {}
local function newActor(world, authority)
    local a = { isObject = true, State = "", CoreVersion = "", bReplicates = true, bAlwaysRelevant = true, auth = authority, worldObj = world, sets = {} }
    a.GetFName = function() return fname("NucleusNet_C_" .. (#spawned + 1)) end
    a.GetFullName = function() return "NucleusNet_C " .. world.path .. ":PersistentLevel.NucleusNet_C_1" end
    a.GetClass = function() return { GetFullName = function() return CLASS_FULL end } end
    a.HasAuthority = function() return a.auth end
    a.GetWorld = function() return world end
    a.GetOwner = function() return nil end
    a.Nucleus_NetSetState = function(self, s) self.State = s; self.sets[#self.sets + 1] = s end
    a.Nucleus_NetSetVersion = function(self, v) self.CoreVersion = v end
    return a
end
local function newWorld(path)
    local w = { isObject = true, path = path }
    w.GetFullName = function() return "World " .. path end
    w.SpawnActor = function(self, cls, at, rot)
        if spawnFails > 0 then spawnFails = spawnFails - 1 return nil end
        local a = newActor(self, true)
        spawned[#spawned + 1] = a
        return a
    end
    return w
end
local WORLDS = {}
local FOUND = {} -- FindAllOf results
StaticFindObject = function(path)
    if path == "/Script/Engine.Default__KismetSystemLibrary" then
        return { IsServer = function() return NET.server end, IsStandalone = function() return NET.standalone end }
    end
    if path == "/Script/AssetRegistry.Default__AssetRegistryHelpers" then return { GetAsset = function() return classObj end } end
    return WORLDS[path]
end
FindAllOf = function(short) if short == HOST.SHORT then return FOUND end return nil end

local clockT = 0
local function hlog()
    return { info = function(f, ...) print("[Nucleus] " .. string.format(f, ...)) end,
             warn = function(f, ...) print("[Nucleus] WARN " .. string.format(f, ...)) end,
             error = function(f, ...) print("[Nucleus] ERROR " .. string.format(f, ...)) end, debug = function() end }
end
HOST.init({ log = hlog(), setShared = function(k, v) SHARED[k] = v end, getShared = function(k) return SHARED[k] end, now = function() return clockT end })
eq(SHARED["nucleus.net.role"], "none", "host.lua: role none before the first world")
eq(SHARED["nucleus.net.status"], "no-state", "host.lua: no state before the first world")

-- the dependent's core.net, wired to host.lua through the fake shared variables and a fake channel
local CL = require("nucleus.net.client")
local calls = {}
local function call(op, payload)
    calls[#calls + 1] = op .. ":" .. tostring(payload)
    if op ~= "net-publish" then return false, "err:unknown-op " .. op end
    local reply = HOST.op(payload)
    if reply:sub(1, 3) == "ok:" then return true, reply:sub(4) end
    return false, reply
end
local DLINES = {}
local dlog = { info = function(f, ...) DLINES[#DLINES + 1] = string.format(f, ...) end,
               warn = function(f, ...) DLINES[#DLINES + 1] = "WARN " .. string.format(f, ...) end,
               error = function(f, ...) DLINES[#DLINES + 1] = "ERROR " .. string.format(f, ...) end, debug = function() end }
local function dlines(pat) local n = 0 for _, l in ipairs(DLINES) do if l:find(pat) then n = n + 1 end end return n end

-- before connect
raises(function() CL.read("skeltest.x", 0, 1) end, "nucleus.net.read: called before connect", "client: read before connect raises")
CL.bind({ call = call, log = dlog, id = "skeltest", micros = function() return clockT end })
local net = CL.API

-- Role: before the first world
eq(net.role(), "none", "role before the first world: none")
do local okP, why = net.publish("skeltest.revivesN", 8) ok(okP == false and why == "no-world", "publish with no world: false, no-world", why) end
do local v, why = net.read("skeltest.revivesN", 0, 20) ok(v == nil and why == "no-state", "read with no world: nil, no-state") end

-- the menu: standalone
NET.server, NET.standalone = true, true
local menu = newWorld("/Game/Maps/NewMainMenu.NewMainMenu")
WORLDS[menu.path] = menu
HOST.onLoadMap(menu)
eq(net.role(), "standalone", "role in the menu: standalone")
do local okP, why = net.publish("skeltest.revivesN", 8) ok(okP == false and why == "standalone", "publish standalone: false, standalone", why) end
eq(#spawned, 0, "standalone: no actor spawned")
eq(HOST.op("skeltest.x=1"), "err:standalone no network game in this world", "channel op standalone: err:standalone")
do local v, why = net.read("skeltest.revivesN", 0, 20) ok(v == nil and why == "no-state", "read standalone: nil, no-state") end

-- a host world, spawn fails twice first: publish before spawn is kept
NET.server, NET.standalone = true, false
local match = newWorld("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap")
WORLDS[match.path] = match
spawnFails = 2
clearLines()
HOST.onLoadMap(match)
eq(net.role(), "host", "role in a host world: host")
eq(#spawned, 0, "host: first spawn failed")
ok(net.publish("skeltest.revivesN", 8) == true, "publish before spawn: true")
eq(net.read("skeltest.revivesN", 0, 20), 8, "host read returns the value at once")
HOST.start()
ok(HOST.looping() and loops[1] and loops[1].ms <= 250, "the loop runs every 250 ms or faster")
runLoops() -- too early for a retry
eq(#spawned, 0, "no retry before a second has passed")
clockT = clockT + 1000000; runLoops() -- second try fails
clockT = clockT + 1000000; runLoops() -- third succeeds
eq(#spawned, 1, "spawned on the third try")
local hostActor = spawned[1]
eq(hostActor.State, "#1=skeltest,1.revivesN=8", "a value published before the spawn is written when it spawns")
eq(hostActor.CoreVersion, "0.11.0", "CoreVersion written through the setter")
eq(linesMatching("ERROR"), 0, "no ERROR line when a retry succeeds")
-- publish on the host: written through the setter at once
ok(net.publish("skeltest.enemyDamage", 250) == true, "publish enemyDamage")
eq(hostActor.State, "#1=skeltest,1.revivesN=8,1.enemyDamage=250", "the setter wrote State at once")
local nSets = #hostActor.sets
ok(net.publish("skeltest.enemyDamage", 250) == true and #hostActor.sets == nSets, "same value again: true, nothing written")
ok(net.publish("skeltest.enemyDamage", 260.0) == true and HOST.op("skeltest.enemyDamage=260") == "ok:unchanged", "a float with an integer value is that integer")
eq(net.read("skeltest.enemyDamage", 0, 2000), 260, "host reads its own change")
-- the namespaced fixture through the channel
eq(HOST.op("nuclearnightmare-community.skeltest-ns.x=1"), "ok:published", "channel op: a namespaced id")
eq(net.read("nuclearnightmare-community.skeltest-ns.x", 0, 1), 1, "read of the namespaced full key")
ok(hostActor.State:find("#2=nuclearnightmare-community.skeltest-ns,2.x=1", 1, true) ~= nil, "State names the namespaced id once", hostActor.State)

-- Bad publish (each raises one clean error, nothing written)
do
    local before = hostActor.State
    local bad = {
        { function() net.publish("other.revivesN", 8) end, "must start with this mod's own id", "another mod's prefix" },
        { function() net.publish("nodot", 8) end, "must be <mod id>.<name>", "no dot" },
        { function() net.publish("skeltest." .. string.rep("a", 33), 8) end, "must match [A-Za-z0-9_]{1,32}", "name 33 chars" },
        { function() net.publish("skeltest.a-b", 8) end, "must match [A-Za-z0-9_]", "bad characters" },
        { function() net.publish(string.rep("k", 10240), 8) end, "cap", "key 10 kB" },
        { function() net.publish(5, 8) end, "key must be a string, got number", "non-string key" },
        { function() net.publish("skeltest.x", nil) end, "value must be an integer, got nil", "value nil" },
        { function() net.publish("skeltest.x", "8") end, "value must be an integer, got string", "value '8'" },
        { function() net.publish("skeltest.x", 2.5) end, "value must be an integer, got 2.5", "value 2.5" },
        { function() net.publish("skeltest.x", 0 / 0) end, "NaN", "value NaN" },
        { function() net.publish("skeltest.x", math.huge) end, "inf", "value inf" },
        { function() net.publish("skeltest.x", -math.huge) end, "inf", "value -inf" },
        { function() net.publish("skeltest.x", 2 ^ 31) end, "must be in", "value 2^31" },
        { function() net.publish("skeltest.x", 2 ^ 53) end, "must be in", "value 2^53" },
        { function() net.publish("skeltest.x", 1, 2) end, "takes 2 arguments", "an extra argument" },
    }
    for _, b in ipairs(bad) do
        local okC, err = pcall(b[1])
        ok(not okC and tostring(err):sub(1, 21) == "nucleus.net.publish: " and tostring(err):find(b[2], 1, true) ~= nil, "bad publish: " .. b[3], okC and "did not raise" or tostring(err))
    end
    eq(hostActor.State, before, "bad publishes wrote nothing")
end
-- the 17th own key, the 65th in all
do
    for i = 3, 16 do assert(net.publish("skeltest.k" .. i, i)) end
    raises(function() net.publish("skeltest.k17", 17) end, "nucleus.net.publish: skeltest has 16 keys, cap 16 per mod", "17th own key raises")
    -- 16 (skeltest) + 1 (namespaced) + 47 = 64
    for i = 1, 47 do assert(HOST.op("m" .. ((i - 1) // 16 + 1) .. ".k" .. i .. "=1") == "ok:published") end
    local W = HOST._world()
    ok(W.T.count == 64, "64 keys held in all", W.T.count)
    CL._reset(); CL.bind({ call = call, log = dlog, id = "m9", micros = function() return clockT end }); net = CL.API
    raises(function() net.publish("m9.x", 1) end, "nucleus.net.publish: 64 keys in this world, cap 64", "65th key in all raises")
    CL._reset(); CL.bind({ call = call, log = dlog, id = nil, idWhy = "no Mods/X/mod.json", micros = function() return clockT end }); net = CL.API
    raises(function() net.publish("skeltest.x", 1) end, "nucleus.net.publish: this mod has no valid id in its mod.json", "no mod.json id: publish raises")
    eq(net.read("skeltest.revivesN", 0, 20), 8, "no mod.json id: read still works")
    CL._reset(); CL.bind({ call = call, log = dlog, id = "skeltest", micros = function() return clockT end }); net = CL.API
end
-- Channel op direct
do
    eq(HOST.op(string.rep("x", 4000)):match("^err:(%S+)"), "bad-request", "channel op: payload oversized")
    eq(HOST.op("skeltest.x"):match("^err:(%S+)"), "bad-request", "channel op: missing =")
    eq(HOST.op("Bad..Id.x=1"):match("^err:(%S+)"), "bad-request", "channel op: bad id")
    eq(HOST.op("skeltest.x=1.5"):match("^err:(%S+)"), "bad-request", "channel op: non-integer value")
    eq(HOST.op("skeltest.x=99999999999"):match("^err:(%S+)"), "bad-request", "channel op: value out of range")
    eq(HOST.op(nil):match("^err:(%S+)"), "bad-request", "channel op: no payload")
    eq(HOST.op(""):match("^err:(%S+)"), "bad-request", "channel op: empty payload")
end
-- Bad read/watch args
do
    raises(function() net.read(5, 0, 1) end, "nucleus.net.read: key must be a string", "read: non-string key")
    raises(function() net.read("nodot", 0, 1) end, "nucleus.net.read: key 'nodot' must be <mod id>.<name>", "read: malformed key")
    raises(function() net.read("skeltest.x", 0.5, 1) end, "nucleus.net.read: min must be an integer", "read: min non-integer")
    raises(function() net.read("skeltest.x", 0, "1") end, "nucleus.net.read: max must be an integer, got string", "read: max non-number")
    raises(function() net.read("skeltest.x", 5, 1) end, "nucleus.net.read: min 5 is greater than max 1", "read: min > max")
    raises(function() net.read("skeltest.x", 0, 2 ^ 40) end, "nucleus.net.read: max must be in", "read: max out of range")
    raises(function() net.read("skeltest.x", 0, 1, 2) end, "takes 3 arguments", "read: an extra argument")
    raises(function() net.watch("skeltest.x", 0, 1, "fn") end, "nucleus.net.watch: fn must be a function", "watch: fn not a function")
    raises(function() net.watch(nil, 0, 1, function() end) end, "nucleus.net.watch: key must be a string", "watch: nil key")
    raises(function() net.watch("skeltest.x", 2, 1, function() end) end, "nucleus.net.watch: min 2 is greater than max 1", "watch: min > max")
    raises(function() net.unwatch("1") end, "nucleus.net.unwatch: id must be a number", "unwatch: non-number")
    eq(net.unwatch(12345), false, "unwatch: unknown id -> false")
    eq(net.unwatch(1.5), false, "unwatch: a non-integer number -> false")
    raises(function() net.role(1) end, "nucleus.net.role: takes no arguments", "role: an argument")
end
-- Watch: first poll and every change of the result; a throwing fn logged once
do
    local seen = {}
    local id = net.watch("skeltest.enemyDamage", 0, 2000, function(v, why) seen[#seen + 1] = tostring(v) .. "/" .. tostring(why) end)
    ok(math.type(id) == "integer", "watch returns an integer id")
    eq(#seen, 0, "watch: nothing before the first poll")
    CL._tick()
    eq(seen[1], "260/nil", "watch: fires at the first poll with the value")
    CL._tick()
    eq(#seen, 1, "watch: no call while the result is unchanged")
    HOST.op("skeltest.enemyDamage=270")
    CL._tick()
    eq(seen[2], "270/nil", "watch: fires on a change")
    HOST.op("skeltest.enemyDamage=2500")
    clearLines(); DLINES = {}
    CL._tick()
    eq(seen[3], "nil/out-of-bounds", "watch: out of bounds -> fn(nil, 'out-of-bounds')")
    eq(dlines("outside this mod's bounds"), 1, "watch out of bounds: one log line")
    local bad = net.watch("skeltest.revivesN", 0, 20, function() error("boom") end)
    CL._tick(); HOST.op("skeltest.revivesN=9"); CL._tick()
    eq(dlines("watch " .. bad .. " %(skeltest.revivesN%) failed"), 1, "a throwing watch is logged once")
    ok(net.unwatch(id) == true and net.unwatch(id) == false, "unwatch: known id true, then false")
    net.unwatch(bad)
    local ids = {}
    for i = 1, CL.MAX_WATCHES do ids[i] = net.watch("skeltest.x", 0, 1, function() end) end
    raises(function() net.watch("skeltest.x", 0, 1, function() end) end, "nucleus.net.watch: 64 watches in this mod, cap 64", "watch: the 65th raises")
    for _, i in ipairs(ids) do net.unwatch(i) end
end
-- Read out of bounds: one log line per key per minute
do
    HOST.op("skeltest.enemyDamage=250")
    DLINES = {}
    clockT = clockT + 61000000
    local v, why = net.read("skeltest.enemyDamage", 0, 200)
    ok(v == nil and why == "out-of-bounds", "read out of bounds: nil, out-of-bounds")
    net.read("skeltest.enemyDamage", 0, 200)
    eq(dlines("outside this mod's bounds"), 1, "read out of bounds twice: one line")
    clockT = clockT + 61000000
    net.read("skeltest.enemyDamage", 0, 200)
    eq(dlines("outside this mod's bounds"), 2, "a minute later: another line")
    v, why = net.read("skeltest.never", 0, 200)
    ok(v == nil and why == "absent", "read absent: nil, absent")
end

-- A new world clears every value
do
    local match2 = newWorld("/Game/Maps/Tower/Tower.Tower")
    WORLDS[match2.path] = match2
    HOST.onLoadMap(match2)
    local v, why = net.read("skeltest.enemyDamage", 0, 2000)
    ok(v == nil and why == "absent", "a new host world starts empty")
    eq(#spawned, 2, "one actor spawned in the new host world")
    eq(spawned[2].State, "", "the new actor's State is empty")
end

-- ---------------------------------------------------------------- the client side of host.lua
NET.server, NET.standalone = false, false
local cworld = newWorld("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap")
WORLDS[cworld.path] = cworld
clearLines()
HOST.onLoadMap(cworld)
eq(net.role(), "client", "role in a client world: client")
raises(function() net.publish("skeltest.revivesN", 8) end, "nucleus.net.publish: only the host publishes (this machine is a client)", "publish on a client raises")
eq(HOST.op("skeltest.x=1"), "err:client only the host publishes (this machine is a client)", "channel op on a client: err:client")
do local v, why = net.read("skeltest.revivesN", 0, 20) ok(v == nil and why == "no-state", "client before the actor: nil, no-state") end
local before = #spawned
runLoops()
eq(#spawned, before, "a client never spawns the actor")
-- the host's actor replicates in: NotifyOnNewObject, then the tick
local remote = newActor(cworld, false)
remote.State, remote.CoreVersion = "#1=skeltest,1.revivesN=8,1.enemyDamage=250", "0.11.0"
HOST.onNewObject(remote)
runLoops()
eq(net.read("skeltest.revivesN", 0, 20), 8, "client: read in bounds after the actor arrived")
eq(net.read("skeltest.enemyDamage", 0, 2000), 250, "client: enemyDamage 250")
eq(linesMatching("holding NucleusNet"), 1, "client: one 'holding' line")
-- a value change on the host replicates
remote.State = "#1=skeltest,1.revivesN=8,1.enemyDamage=260"
runLoops()
eq(net.read("skeltest.enemyDamage", 0, 2000), 260, "client: the change is read on the next tick")
-- hostile State: one line per key per minute
clearLines()
remote.State = "#1=skeltest,1.y=99999999999,1.revivesN=8"
runLoops()
eq(linesMatching("dropped from the host's State %(skeltest.y%)"), 1, "client: a hostile entry logs one line")
remote.State = "#1=skeltest,1.y=99999999998,1.revivesN=8"
runLoops()
eq(linesMatching("dropped from the host's State %(skeltest.y%)"), 1, "client: the same key again within the minute: no second line")
eq(net.read("skeltest.revivesN", 0, 20), 8, "client: good entries kept beside a bad one")
remote.State = string.rep("x", 9000)
runLoops()
do local v, why = net.read("skeltest.revivesN", 0, 20) ok(v == nil and why == "absent", "client: a 9 kB State is ignored whole (nothing reads)") end
eq(linesMatching("dropped from the host's State %(actor:"), 1, "client: one line per actor for a whole-state reject")
remote.State = string.rep("y", 9000)
runLoops()
eq(linesMatching("dropped from the host's State %(actor:"), 1, "client: still one line within the minute")
-- version mismatch: ignored with one line per world
clearLines()
remote.State, remote.CoreVersion = "#1=skeltest,1.revivesN=8", "0.10.0"
runLoops(); runLoops()
do local v, why = net.read("skeltest.revivesN", 0, 20) ok(v == nil and why == "version", "client: another core version reads as version") end
eq(linesMatching("its core version is '0.10.0'"), 1, "client: one version line per world")
remote.CoreVersion = "0.11.0"
runLoops()
eq(net.read("skeltest.revivesN", 0, 20), 8, "client: same version again: read")
-- the actor goes away: no state; the fallback finds a new one (filtered by class, world, authority)
remote.dead = true
runLoops()
do local v, why = net.read("skeltest.revivesN", 0, 20) ok(v == nil and why == "no-state", "client: actor gone: no-state") end
local localOne = newActor(cworld, true) -- spawned locally (authority): never the host's
local otherWorld = newActor(newWorld("/Game/Maps/Old/Old.Old"), false)
local good = newActor(cworld, false)
good.State, good.CoreVersion = "#1=skeltest,1.revivesN=3", "0.11.0"
FOUND = { localOne, otherWorld, good }
clockT = clockT + 3000000
runLoops(); runLoops()
eq(net.read("skeltest.revivesN", 0, 20), 3, "client: FindAllOf fallback takes only the host's actor in this world")
-- an actor held through NotifyOnNewObject that turns out to have authority is dropped
do
    HOST.onLoadMap(cworld)
    FOUND = {}
    local fake = newActor(cworld, true)
    fake.State, fake.CoreVersion = "#1=skeltest,1.revivesN=1", "0.11.0"
    HOST.onNewObject(fake)
    runLoops()
    local v, why = net.read("skeltest.revivesN", 0, 20)
    ok(v == nil and why == "no-state", "client: a locally spawned (authority) actor is ignored")
end
-- the watch on a client sees the replicated change
do
    local seen = {}
    local w = net.watch("skeltest.revivesN", 0, 20, function(v, why) seen[#seen + 1] = tostring(v) .. "/" .. tostring(why) end)
    CL._tick()
    eq(seen[1], "nil/no-state", "client watch: fn(nil, 'no-state') at the first poll")
    local r2 = newActor(cworld, false)
    r2.State, r2.CoreVersion = "#1=skeltest,1.revivesN=5", "0.11.0"
    HOST.onNewObject(r2)
    runLoops(); CL._tick()
    eq(seen[2], "5/nil", "client watch: fires with the replicated value")
    net.unwatch(w)
end

-- core unloads
HOST.stop(); HOST.unload()
eq(SHARED["nucleus.net.role"], "none", "unload: role none")
ok(not HOST.looping(), "unload: loop stopped")

-- ---------------------------------------------------------------- own id from mod.json
do
    local DIR = (ROOT .. "/build/unit-net/Mods"):gsub("/", "\\")
    os.execute('rmdir /s /q "' .. DIR .. '" >nul 2>nul')
    os.execute('mkdir "' .. DIR .. '\\SkelTest" >nul 2>nul')
    os.execute('mkdir "' .. DIR .. '\\Ns" >nul 2>nul')
    os.execute('mkdir "' .. DIR .. '\\NoId" >nul 2>nul')
    local function write(p, t) local f = assert(io.open(p, "wb")) f:write(t) f:close() end
    write(DIR .. "\\SkelTest\\mod.json", '{ "id": "skeltest", "name": "NucleusSkelTest" }')
    write(DIR .. "\\Ns\\mod.json", '{ "id": "github.com/NuclearNightmare-Community.skeltest-ns", "name": "Ns" }')
    write(DIR .. "\\NoId\\mod.json", '{ "name": "NoId" }')
    eq(CL.ownId(DIR, "SkelTest"), "skeltest", "ownId: a bare id")
    eq(CL.ownId(DIR, "Ns"), "nuclearnightmare-community.skeltest-ns", "ownId: a namespaced id, normalized")
    local id, why = CL.ownId(DIR, "NoId")
    ok(id == nil and why:find("mod.json id", 1, true), "ownId: no id", why)
    id, why = CL.ownId(DIR, "Missing")
    ok(id == nil and why:find("no Mods/Missing/mod.json", 1, true), "ownId: no mod.json", why)
    id, why = CL.ownId(nil, nil)
    ok(id == nil, "ownId: folder unknown")
end

-- ---------------------------------------------------------------- features
do
    local F = require("nucleus.features")
    local set = F.set(F.declared())
    for _, n in ipairs({ "net", "net.publish", "net.read", "net.watch", "net.unwatch", "net.role" }) do ok(set[n] == true, "features: " .. n) end
    local api = { net = CL.API }
    local list = F.fromApi(api)
    local s2 = F.set(list)
    ok(s2.net and not s2["net.publish.x"], "features.fromApi lists net as a module")
end

realPrint(("net_test: %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
