-- Unit tests for the settings service (Mod Manager story 5), outside the game: the declaration schema, core's store
-- (values file, atomic write, .bak recovery, windows, the channel ops) on real files in build/unit-settings/, and
-- core.settings in two dependent states (two copies of the client module) through nucleus.client's call and a fake
-- class default object that routes to core's handler. Every row of the story's I/O matrix; I/O failures by stubbing
-- io.open and os.rename. Difficulty's real mod.json is the fixture test/unit/fixtures/difficulty.mod.json.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  texlua test/unit/settings_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
local VERSION = { name = "Nucleus", version = "0.9.0", floor = "0.1.0" }
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

local pass, fail = 0, 0
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else fail = fail + 1; realPrint("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")) end
end
local function eq(got, want, name) ok(got == want, name, "got " .. tostring(got) .. ", want " .. tostring(want)) end
local function raises(fn, text, name)
    local okC, err = pcall(fn)
    ok(not okC and tostring(err):find(text, 1, true) ~= nil, name, okC and "did not raise" or tostring(err))
end

-- ---------------------------------------------------------------- a Mods folder on disk
local MODS = (ROOT .. "/build/unit-settings/Mods"):gsub("/", "\\")
os.execute('rmdir /s /q "' .. MODS .. '" >nul 2>nul')
local function mkdir(p) os.execute('mkdir "' .. p .. '" >nul 2>nul') end
local function write(p, text) local f = assert(io.open(p, "wb")) f:write(text) f:close() end
local function read(p) local f = io.open(p, "rb") if not f then return nil end local t = f:read("a") f:close() return t end
local function exists(p) local f = io.open(p, "rb") if f then f:close() return true end return false end
local function modDir(folder, manifest)
    mkdir(MODS .. "\\" .. folder)
    if manifest then write(MODS .. "\\" .. folder .. "\\mod.json", manifest) end
end
local function file(folder, name) return MODS .. "\\" .. folder .. "\\" .. (name or "settings.json") end

local CLOCK = [[{
  "id": "nuclearnightmare-community.clock", "name": "Clock", "version": "0.2.0", "scope": "client",
  "settings": {
    "updateEvery": { "type": "int", "default": 1, "min": 1, "max": 60,
                     "label": "Update every N game minutes", "changeable": "anytime" }
  }
}]]
local WAYPOINTS = [[{
  "id": "nuclearnightmare-community.waypoints", "name": "Waypoints",
  "settings": {
    "onRevive": { "type": "enum", "values": [ "restore", "clear" ], "default": "restore",
                  "label": "After a revive, your map waypoints", "changeable": "anytime" }
  }
}]]
local SKEL = [[{
  "id": "nucleus-skeltest", "name": "NucleusSkelTest",
  "settings": {
    "test.flag": { "type": "bool", "default": false, "label": "A flag", "changeable": "anytime", "help": "on or off" },
    "test.count": { "type": "int", "default": 3, "min": 1, "max": 60, "changeable": "anytime", "scope": "client" },
    "test.ratio": { "type": "number", "default": 0.5, "min": 0, "max": 2, "step": 0.25, "changeable": "anytime" },
    "test.mode": { "type": "enum", "values": ["a", "b", "c"], "default": "a", "changeable": "menu" },
    "test.boot": { "type": "int", "default": 10, "min": 0, "max": 100 },
    "test.lobby": { "type": "bool", "default": false, "changeable": "lobby" },
    "test.preset": { "type": "number", "default": null, "min": 0, "max": 10, "source": "presets", "changeable": "menu" }
  }
}]]
modDir("Clock", CLOCK)
modDir("Waypoints", WAYPOINTS)
modDir("NucleusSkelTest", SKEL)
modDir("Difficulty", assert(read(ROOT .. "/test/unit/fixtures/difficulty.mod.json")))
modDir("Plain", '{ "id": "plain", "name": "Plain" }')
modDir("Broken", '{ "id": "broken", ')
modDir("NoManifest", nil)
modDir("Nucleus", '{ "id": "nuclearnightmare-community.nucleus", "name": "Nucleus" }')

-- ---------------------------------------------------------------- schema
local schema = require("nucleus.settings.schema")
do
    local m = schema.parse(CLOCK, "Clock")
    ok(m and #m.settings == 1 and m.settings[1].key == "updateEvery" and m.settings[1].type == "int" and m.settings[1].default == 1
        and m.settings[1].min == 1 and m.settings[1].max == 60 and m.settings[1].changeable == "anytime", "Clock's shape")
    m = schema.parse(WAYPOINTS, "Waypoints")
    ok(m and m.settings[1].type == "enum" and m.settings[1].values[2] == "clear" and m.settings[1].default == "restore", "Waypoints' shape")
    m = schema.parse(SKEL, "NucleusSkelTest")
    eq(#m.settings, 7, "SkelTest: seven settings")
    local keys = {}
    for i, d in ipairs(m.settings) do keys[i] = d.key end
    eq(table.concat(keys, ","), "test.flag,test.count,test.ratio,test.mode,test.boot,test.lobby,test.preset", "declaration order kept")
    eq(m.byKey["test.boot"].changeable, "restart", "changeable defaults to restart")
    eq(m.byKey["test.count"].label, "test.count", "label defaults to the key")
    ok(m.byKey["test.preset"].readOnly and m.byKey["test.preset"].default == nil, "source: read-only, null default allowed")
    eq(#m.problems, 0, "no problems")
    -- Difficulty's real mod.json: 19 read-only settings in declaration order
    local text = read(ROOT .. "/test/unit/fixtures/difficulty.mod.json")
    m = schema.parse(text, "Difficulty")
    eq(#m.settings, 19, "Difficulty: 19 settings")
    local all = true
    for _, d in ipairs(m.settings) do if not (d.readOnly and d.source == "presets" and d.type == "number") then all = false end end
    ok(all, "Difficulty: all read-only number settings from presets")
    eq(m.settings[1].key, "enemyDamage", "Difficulty: first in declaration order")
    eq(m.settings[19].key, text:match('.*\n%s*"([%w%.]+)": {'), "Difficulty: last in declaration order")
    eq(#m.problems, 0, "Difficulty: no problems")

    -- bad entries: each dropped with one problem naming folder and key; the rest kept
    local function one(entry, key)
        local mm = schema.parse('{"settings":{"good":{"type":"bool","default":true},"' .. (key or "bad") .. '":' .. entry .. '}}', "F")
        return mm
    end
    local cases = {
        { '{"type":"string","default":"x"}', "type must be" },
        { '{"type":"int","default":1.5}', "default must be an integer" },
        { '{"type":"int","default":5,"min":10}', "default must be from" },
        { '{"type":"int","default":1,"min":1.5}', "min must be an integer" },
        { '{"type":"int","default":5,"min":10,"max":1}', "min is above max" },
        { '{"type":"number","default":1,"step":0}', "step must be" },
        { '{"type":"number","default":1,"step":-1}', "step must be" },
        { '{"type":"enum","values":[],"default":"a"}', "values must be" },
        { '{"type":"enum","values":["a","a"],"default":"a"}', "twice" },
        { '{"type":"enum","values":["a",1],"default":"a"}', "values[2]" },
        { '{"type":"enum","values":["a"],"default":"b"}', "default must be one of" },
        { '{"type":"enum","values":[' .. string.rep('"x",', 32) .. '"y"],"default":"y"}', "values must be" },
        { '{"type":"bool"}', "default is missing" },
        { '{"type":"bool","default":null}', "default is missing" },
        { '{"type":"bool","default":1}', "default must be true or false" },
        { '{"type":"bool","default":true,"label":"' .. string.rep("l", 65) .. '"}', "label must be" },
        { '{"type":"bool","default":true,"help":"' .. string.rep("h", 257) .. '"}', "help must be" },
        { '{"type":"bool","default":true,"changeable":"never"}', "changeable must be" },
        { '{"type":"bool","default":true,"scope":"world"}', "scope must be" },
        { '{"type":"bool","default":true,"source":"' .. string.rep("s", 33) .. '"}', "source must be" },
        { '[1]', "not an object" },
        { '5', "not an object" },
    }
    for i, c in ipairs(cases) do
        local mm = one(c[1])
        ok(mm and #mm.settings == 1 and mm.settings[1].key == "good" and #mm.problems == 1 and mm.problems[1]:find("F: setting 'bad' left out: ", 1, true)
            and mm.problems[1]:find(c[2], 1, true), "bad entry " .. i .. " dropped (" .. c[2] .. ")", mm and mm.problems[1])
    end
    for i, k in ipairs({ "1abc", "a b", "a-b", string.rep("k", 65), "_x" }) do
        local mm = one('{"type":"bool","default":true}', k)
        ok(mm and #mm.settings == 1 and #mm.problems == 1 and mm.problems[1]:find("key must match", 1, true), "bad key " .. i .. " dropped")
    end
    local mm = one('{"type":"bool","default":true,"futureKey":{"x":1},"min":3}')
    eq(mm and #mm.settings, 2, "unknown keys (and min on a bool) are ignored")
    local big = {}
    for i = 1, 70 do big[#big + 1] = string.format('"k%d":{"type":"bool","default":true}', i) end
    mm = schema.parse('{"settings":{' .. table.concat(big, ",") .. '}}', "F")
    ok(#mm.settings == 64 and #mm.problems == 1 and mm.problems[1]:find("more than 64 settings", 1, true), "at most 64 settings")
    mm = schema.parse('{"settings":[1]}', "F")
    ok(mm.hasSettings and #mm.settings == 0 and mm.problems[1]:find("settings is not an object", 1, true), "settings not an object")
    ok(schema.parse("{", "F") == nil, "corrupt mod.json")
    ok(schema.parse('{"id":"plain"}', "F").hasSettings == false, "no settings key")
    -- check
    local d = schema.parse(SKEL, "S").byKey
    eq(schema.check(d["test.count"], 5.0), 5, "an integral float is an int"); eq(math.type(schema.check(d["test.count"], 5.0)), "integer", "...as an integer")
    ok(schema.check(d["test.count"], 2.5) == nil and schema.check(d["test.count"], 61) == nil and schema.check(d["test.count"], 0) == nil, "int bounds and type")
    ok(schema.check(d["test.ratio"], 0 / 0) == nil and schema.check(d["test.ratio"], math.huge) == nil and schema.check(d["test.ratio"], 3) == nil, "number: NaN, inf, max")
    ok(schema.check(d["test.mode"], "x") == nil and schema.check(d["test.mode"], "b") == "b", "enum")
    ok(schema.check(d["test.flag"], "true") == nil and schema.check(d["test.flag"], true) == true, "bool")
end

-- ---------------------------------------------------------------- core's store
local store = require("nucleus.settings.store")
local json = require("nucleus.json")
local WORLD = "World /Game/Maps/NewMainMenu.NewMainMenu"
local revs = {}
local logm = require("nucleus.log")
store.init{ modsDir = MODS, core = "Nucleus", log = logm.new("Nucleus"), rev = 0, world = function() return WORLD end,
            publishRev = function(n) revs[#revs + 1] = n end }

local function desc(folder) local d = store.op("settings-get", folder) return d end
local function decoded(reply) return reply:sub(1, 3) == "ok:" and json.decode(reply:sub(4)) or nil end
local function entryOf(d, key) for _, e in ipairs(d.settings) do if e.key == key then return e end end end

do -- Fresh install: Clock with no settings.json -> default 1, one info line (spec revision: info, not WARN)
    local before = #LINES
    local d = decoded(desc("Clock"))
    ok(d and d.folder == "Clock" and d.id == "nuclearnightmare-community.clock" and d.name == "Clock", "describe: id, name, folder")
    eq(entryOf(d, "updateEvery").value, 1, "fresh: updateEvery = 1")
    eq(linesMatching("^%[Nucleus%] settings: Clock: no settings%.json; using the declared defaults$"), 1, "fresh: one info line")
    eq(linesMatching("WARN"), 0, "fresh: no WARN")
    desc("Clock"); desc("Clock")
    eq(#LINES - before, 1, "fresh: only one line however often it's read")
    ok(not exists(file("Clock")), "fresh: nothing written by reading")
    local e = entryOf(d, "updateEvery")
    ok(e.type == "int" and e.min == 1 and e.max == 60 and e.default == 1 and e.label == "Update every N game minutes" and e.changeable == "anytime"
        and e.readOnly == false and e.restart == false and e.pendingRestart == false, "describe: every field of the entry")
    ok(json.isArray(d.problems) and #d.problems == 0, "describe: problems is an empty list")
end

do -- A set: file written in declaration order, rev + 1, no .tmp or .bak left; back to the default writes {}
    local r = store.op("settings-set", '{"mod":"Clock","key":"updateEvery","value":5}')
    ok(r:sub(1, 3) == "ok:", "set Clock updateEvery 5", r)
    eq(decoded(r).value, 5, "the reply is the entry with its new value")
    eq(read(file("Clock")), '{"updateEvery":5}', "settings.json holds the value")
    ok(not exists(file("Clock", "settings.json.tmp")) and not exists(file("Clock", "settings.json.bak")), "no .tmp or .bak left")
    eq(store.rev(), 1, "rev rose by one"); eq(revs[#revs], 1, "rev published")
    eq(entryOf(decoded(desc("Clock")), "updateEvery").value, 5, "describe shows 5")
    store.op("settings-set", '{"mod":"Clock","key":"updateEvery","value":1}')
    eq(read(file("Clock")), "{}", "back to the default: only non-defaults are written")
    eq(store.rev(), 2, "rev 2")
end

do -- Manager edit of Waypoints (the matrix row; the watcher side is in the client part below)
    local r = store.op("settings-set", '{"mod":"Waypoints","key":"onRevive","value":"clear"}')
    ok(r:sub(1, 3) == "ok:" and read(file("Waypoints")) == '{"onRevive":"clear"}', "Waypoints onRevive=clear written", r)
end

do -- Restart-only: saved; the value stays the session's; pendingRestart until a new session
    local r = store.op("settings-set", '{"mod":"NucleusSkelTest","key":"test.boot","value":42}')
    local e = decoded(r)
    ok(e and e.value == 10 and e.pendingRestart == true and e.saved == 42 and e.restart == true, "restart: value stays 10, pendingRestart, saved 42", r)
    eq(read(file("NucleusSkelTest")), '{"test.boot":42}', "restart: saved to the file")
    store._reset() -- a new session
    e = entryOf(decoded(desc("NucleusSkelTest")), "test.boot")
    ok(e.value == 42 and e.pendingRestart == false and e.saved == nil, "restart: the next session uses it")
end

do -- Read-only: Difficulty describe and set
    local d = decoded(desc("Difficulty"))
    eq(#d.settings, 19, "Difficulty: 19 entries")
    local all = true
    for _, e in ipairs(d.settings) do if not (e.readOnly == true and e.value == nil and e.source == "presets") then all = false end end
    ok(all, "Difficulty: all readOnly, value absent")
    eq(store.op("settings-set", '{"mod":"Difficulty","key":"dmg.husk","value":10}'), "err:read-only dmg.husk comes from presets", "Difficulty set refused read-only")
    ok(not exists(file("Difficulty")) and not exists(file("Difficulty", "settings.json.tmp")), "Difficulty: no file written")
end

do -- Windows: menu outside the title screen and lobby are locked; anytime works anywhere
    WORLD = "World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap"
    eq(store.op("settings-set", '{"mod":"NucleusSkelTest","key":"test.mode","value":"b"}'), "err:locked test.mode changes only at the main menu", "menu locked in a match")
    ok(store.op("settings-set", '{"mod":"NucleusSkelTest","key":"test.count","value":7}'):sub(1, 3) == "ok:", "anytime works in a match")
    WORLD = nil
    ok(store.op("settings-set", '{"mod":"NucleusSkelTest","key":"test.mode","value":"b"}'):find("^err:locked"), "menu locked with no known world")
    WORLD = "World /Game/Maps/NewMainMenu.NewMainMenu"
    ok(store.op("settings-set", '{"mod":"NucleusSkelTest","key":"test.mode","value":"b"}'):sub(1, 3) == "ok:", "menu works at the main menu")
    eq(store.op("settings-set", '{"mod":"NucleusSkelTest","key":"test.lobby","value":true}'), "err:locked test.lobby changes only in the lobby", "lobby is locked in v1")
    eq(read(file("NucleusSkelTest")), '{"test.count":7,"test.mode":"b","test.boot":42}', "declaration order in the file")
end

do -- Corrupt files: defaults, exactly one WARN per folder per session
    for i, text in ipairs({ '{"a":', string.rep(" ", 70 * 1024), string.rep("[", 40) .. string.rep("]", 40), "[1]", "return {}" }) do
        local f = "Corrupt" .. i
        modDir(f, CLOCK)
        write(file(f), text)
        local before = linesMatching("WARN settings: " .. f .. ": ")
        local d = decoded(desc(f))
        eq(entryOf(d, "updateEvery").value, 1, "corrupt " .. i .. ": defaults")
        desc(f); desc(f)
        eq(linesMatching("WARN settings: " .. f .. ": settings%.json ") - before, 1, "corrupt " .. i .. ": exactly one WARN")
        ok(#d.problems == 1, "corrupt " .. i .. ": a problem in the description", d.problems[1])
    end
    -- a set over a corrupt file replaces it
    ok(store.op("settings-set", '{"mod":"Corrupt1","key":"updateEvery","value":9}'):sub(1, 3) == "ok:" and read(file("Corrupt1")) == '{"updateEvery":9}', "a set replaces a corrupt file")
end

do -- Entries re-validated: unknown, read-only, wrong-type, out-of-range dropped (one WARN); the good one kept
    modDir("Mixed", SKEL)
    write(file("Mixed"), '{"nope":1,"test.preset":5,"test.flag":"yes","test.count":99,"test.ratio":1.5}')
    local d = decoded(desc("Mixed"))
    ok(entryOf(d, "test.ratio").value == 1.5 and entryOf(d, "test.count").value == 3 and entryOf(d, "test.flag").value == false
        and entryOf(d, "test.preset").value == nil, "only the valid entry is used")
    eq(linesMatching("WARN settings: Mixed: settings%.json entries ignored: nope %(unknown%), test%.preset %(read%-only%), test%.flag %(must be true or false%), test%.count %(must be from 1 to 60%)"), 1, "one WARN lists them")
end

do -- Crash mid-write: target missing, .bak present -> restored and used
    modDir("Crashed", CLOCK)
    write(file("Crashed", "settings.json.bak"), '{"updateEvery":12}')
    eq(entryOf(decoded(desc("Crashed")), "updateEvery").value, 12, "crash: the .bak's value is used")
    ok(exists(file("Crashed")) and not exists(file("Crashed", "settings.json.bak")), "crash: .bak restored as settings.json")
    -- both present (crash after the second rename): the target wins, the stale .bak is cleaned by the next write
    modDir("Both", CLOCK)
    write(file("Both"), '{"updateEvery":20}')
    write(file("Both", "settings.json.bak"), '{"updateEvery":2}')
    eq(entryOf(decoded(desc("Both")), "updateEvery").value, 20, "both: the target wins")
    ok(store.op("settings-set", '{"mod":"Both","key":"updateEvery","value":21}'):sub(1, 3) == "ok:" and not exists(file("Both", "settings.json.bak")), "both: the next write leaves no .bak")
end

do -- I/O failures: write-failed, the previous file and the in-memory value unchanged
    local realOpen, realRename = io.open, os.rename
    local prev = read(file("Clock"))
    local before = store.rev()
    io.open = function(p, m) if p:find("%.tmp$") and m == "wb" then return nil, "Permission denied" end return realOpen(p, m) end
    local r = store.op("settings-set", '{"mod":"Clock","key":"updateEvery","value":30}')
    io.open = realOpen
    ok(r:find("^err:write%-failed updateEvery: open tmp: Permission denied"), "tmp can't be opened: write-failed", r)
    ok(#r <= #"err:write-failed " + 64, "the detail is at most 64 bytes")
    eq(read(file("Clock")), prev, "tmp can't be opened: file unchanged")
    eq(entryOf(decoded(desc("Clock")), "updateEvery").value, 1, "tmp can't be opened: value unchanged")
    eq(store.rev(), before, "no rev bump on a failure")
    eq(linesMatching("WARN settings: Clock: could not write settings%.json"), 1, "the failure is logged")

    os.rename = function(a, b) if a:find("%.tmp$") then return nil, "File exists" end return realRename(a, b) end
    r = store.op("settings-set", '{"mod":"Clock","key":"updateEvery","value":30}')
    os.rename = realRename
    ok(r:find("^err:write%-failed"), "tmp -> target fails: write-failed", r)
    eq(read(file("Clock")), prev, "tmp -> target fails: the previous file is back")
    ok(not exists(file("Clock", "settings.json.tmp")) and not exists(file("Clock", "settings.json.bak")), "tmp -> target fails: no .tmp or .bak left")
    eq(entryOf(decoded(desc("Clock")), "updateEvery").value, 1, "tmp -> target fails: value unchanged")

    os.rename = function(a, b) if b:find("%.bak$") then return nil, "Access denied" end return realRename(a, b) end
    r = store.op("settings-set", '{"mod":"Clock","key":"updateEvery","value":30}')
    os.rename = realRename
    ok(r:find("^err:write%-failed updateEvery: rename to %.bak"), "target -> .bak fails: write-failed", r)
    eq(read(file("Clock")), prev, "target -> .bak fails: file unchanged")

    io.open = function(p, m) if p:find("%.tmp$") and m == "rb" then return nil, "gone" end return realOpen(p, m) end
    r = store.op("settings-set", '{"mod":"Clock","key":"updateEvery","value":30}')
    io.open = realOpen
    ok(r:find("^err:write%-failed updateEvery: tmp read back differs"), "read-back mismatch: write-failed", r)
    eq(read(file("Clock")), prev, "read-back mismatch: file unchanged")
    eq(store.rev(), before, "still no rev bump")
end

do -- Bad calls through the ops: clean err:<code>, nothing written
    local function files() local n = 0 for _, f in ipairs({ "Plain", "Broken", "NoManifest", "Nucleus" }) do if exists(file(f)) then n = n + 1 end end return n end
    local cases = {
        { "settings-get", nil, "err:bad-request" },
        { "settings-get", "", "err:bad-request" },
        { "settings-get", "..\\x", "err:bad-request folder must match" },
        { "settings-get", "../x", "err:bad-request" },
        { "settings-get", string.rep("a", 65), "err:bad-request" },
        { "settings-get", "C:\\Windows", "err:bad-request" },
        { "settings-get", "NoSuchMod", "err:unknown-mod NoSuchMod has no mod.json" },
        { "settings-get", "NoManifest", "err:unknown-mod" },
        { "settings-get", "Broken", "err:unknown-mod Broken: mod.json: " },
        { "settings-get", "Plain", "err:no-settings Plain declares no settings" },
        { "settings-get", "Nucleus", "err:no-settings" },
        { "settings-set", nil, "err:bad-request" },
        { "settings-set", "{", "err:bad-request payload: 1:1 unterminated object" },
        { "settings-set", "[]", "err:bad-request payload must be a JSON object" },
        { "settings-set", "null", "err:bad-request payload must be a JSON object" },
        { "settings-set", '{"key":"a","value":1}', "err:bad-request mod must be a string" },
        { "settings-set", '{"mod":"Clock","value":1}', "err:bad-request key must be a string" },
        { "settings-set", '{"mod":"Clock","key":"updateEvery"}', "err:bad-request value must be" },
        { "settings-set", '{"mod":"Clock","key":"updateEvery","value":null}', "err:bad-request value must be" },
        { "settings-set", '{"mod":"Clock","key":"updateEvery","value":[5]}', "err:bad-request value must be" },
        { "settings-set", '{"mod":"Clock","key":"updateEvery","value":{"a":1}}', "err:bad-request" },
        { "settings-set", '{"mod":"..\\\\x","key":"a","value":1}', "err:bad-request mod must match" },
        { "settings-set", '{"mod":"' .. string.rep("a", 65) .. '","key":"a","value":1}', "err:bad-request mod must match" },
        { "settings-set", '{"mod":"NoSuchMod","key":"a","value":1}', "err:unknown-mod" },
        { "settings-set", '{"mod":"Plain","key":"a","value":1}', "err:no-settings" },
        { "settings-set", '{"mod":"Clock","key":"nope","value":1}', "err:unknown-key 'nope' in Clock" },
        { "settings-set", '{"mod":"Clock","key":"updateEvery","value":2.5}', "err:bad-value updateEvery must be an integer" },
        { "settings-set", '{"mod":"Clock","key":"updateEvery","value":61}', "err:bad-value updateEvery must be from 1 to 60" },
        { "settings-set", '{"mod":"Clock","key":"updateEvery","value":"5"}', "err:bad-value updateEvery must be an integer" },
        { "settings-set", '{"mod":"Clock","key":"updateEvery","value":1e999}', "err:bad-request payload: 1:44 number out of range" },
        { "settings-set", '{"mod":"Clock","key":"updateEvery","value":NaN}', "err:bad-request payload" },
        { "settings-set", '{"mod":"Waypoints","key":"onRevive","value":"x"}', "err:bad-value onRevive must be one of restore|clear" },
        { "settings-set", '{"mod":"NucleusSkelTest","key":"test.flag","value":1}', "err:bad-value" },
        { "settings-set", '{"mod":"Clock","key":"updateEvery","value":5,"mod":"X"}', "err:bad-request payload: 1:46 duplicate key" },
        { "settings-set", string.rep("[", 40), "err:bad-request payload: 1:3 nested deeper than 2" },
        { "settings-set", '{"mod":"Clock","key":"' .. string.rep("k", 2000) .. '","value":1}', "err:bad-request payload: " },
        { "settings-nope", "x", "err:unknown-op" },
    }
    local before = read(file("Clock"))
    local rev0 = store.rev()
    for i, c in ipairs(cases) do
        local okP, r = pcall(store.op, c[1], c[2])
        ok(okP and type(r) == "string" and r:sub(1, #c[3]) == c[3], "bad call " .. i .. " -> " .. c[3], okP and r or ("raised: " .. tostring(r)))
        ok(okP and #r <= 4 + #(r:match("^err:(%S+)") or "") + 1 + 64, "bad call " .. i .. ": detail at most 64 bytes", okP and #r)
    end
    eq(read(file("Clock")), before, "bad calls: Clock's file unchanged")
    eq(files(), 0, "bad calls: nothing written elsewhere")
    eq(store.rev(), rev0, "bad calls: no rev bump")
    eq(linesMatching("settings: Plain: no settings%.json") + linesMatching("settings: Nucleus: no settings%.json"), 0, "a mod without settings: no values-file line")
    ok(not exists(MODS .. "\\x") and not exists(MODS .. "\\..\\x"), "no path built from bad text")
end

-- ---------------------------------------------------------------- core.settings, two dependent states
local shared = { ["nucleus.state"] = "ready", ["nucleus.version"] = "0.9.0" }
ModRef = { GetSharedVariable = function(_, k) return shared[k] end, SetSharedVariable = function(_, k, v) shared[k] = v end }
store.init{ modsDir = MODS, core = "Nucleus", log = logm.new("Nucleus"), rev = 0, world = function() return WORLD end,
            publishRev = function(n) shared["nucleus.settings.rev"] = n end }
shared["nucleus.settings.rev"] = 0
local loops, cancelled = {}, {}
function LoopInGameThreadWithDelay(ms, fn) loops[#loops + 1] = { ms = ms, fn = fn } return #loops end
function CancelDelayedAction(h) cancelled[h] = true return true end
local OFF = false
Nucleus_Deref = function(h) if OFF then error("Nucleus_Deref refused: called off the game thread") end return nil end
-- The class default object routes the channel to core's handler (main.lua's settings branch).
local cdo = { IsValid = function() return true end,
    Nucleus_Call = function(_, req)
        local op = req:match("^([%w_%-]+):") or req:match("^([%w_%-]+)$")
        if op == "ping" then return "ok:pong 0.9.0 boot=1" end
        if op == "settings-get" or op == "settings-set" then
            local payload = #req > #op and req:sub(#op + 2) or nil
            return store.op(op, payload)
        end
        return "err:unknown-op " .. tostring(op)
    end }
function StaticFindObject(p) if p:find("Default__ModActor_C", 1, true) then return cdo end return { IsValid = function() return true end } end
local client = require("nucleus.client")

-- Two copies of the settings client: two dependents' Lua states.
local function newState(folder, mod)
    package.loaded["nucleus.settings.client"] = nil
    local S = require("nucleus.settings.client")
    S.bind{ call = client.call, log = logm.new(mod), folder = folder, mod = mod }
    return S
end
local function runLoops() for i, l in ipairs(loops) do if not cancelled[i] then l.fn() end end end

do -- own folder discovery from the call stack (connect runs it while the dependent's main.lua is on the stack)
    package.loaded["nucleus.settings.client"] = nil
    local S = require("nucleus.settings.client")
    local chunk = load("local S = ... local r = S.findFolder('Nucleus') return r", "@C:\\Games\\NN\\ue4ss\\Mods\\Clock\\Scripts\\main.lua")
    eq(chunk(S), "Clock", "findFolder: the caller's Mods/<Folder>/Scripts/")
    chunk = load("local S = ... local r = S.findFolder('Nucleus') return r", "@C:\\Games\\NN\\ue4ss\\Mods\\Nucleus\\Scripts\\main.lua")
    eq(chunk(S), nil, "findFolder: core's own folder is skipped")
    chunk = load("local S = ... local r = S.findFolder('Nucleus') return r", "@C:\\x\\Mods\\..\\Scripts\\main.lua")
    eq(chunk(S), nil, "findFolder: an invalid folder name is skipped")
    S.bind{ call = client.call, log = logm.new("X"), folder = nil, mod = "X" }
    raises(function() S.get("a") end, "nucleus.settings.get: own mod folder unknown", "no folder: get raises")
    raises(function() S.set("a", 1) end, "nucleus.settings.set: own mod folder unknown", "no folder: set raises")
    raises(function() S.watch(function() end) end, "nucleus.settings.watch: own mod folder unknown", "no folder: watch raises")
    ok(type(S.describe("Clock")) == "table", "no folder: describe still works")
    package.loaded["nucleus.settings.client"] = nil
    local U = require("nucleus.settings.client")
    raises(function() U.get("a") end, "nucleus.settings.get: called before connect", "before connect: raises")
end

local W = newState("Waypoints", "Waypoints")
local C = newState("Clock", "Clock")
local M = newState("NucleusSkelPeer", "Manager") -- the Mod Manager's state (any other mod)

do -- get, getAll, the cache and the revision
    eq(W.get("onRevive"), "clear", "Waypoints get: the value the Manager wrote earlier")
    eq(C.get("updateEvery"), 1, "Clock get: default")
    local all = C.getAll(); all.updateEvery = 99
    eq(C.get("updateEvery"), 1, "getAll returns a copy")
    -- Manager edit from another state: Waypoints' get sees it at once (the revision moved), no loop needed
    local rev0 = shared["nucleus.settings.rev"]
    eq(M.setFor("Waypoints", "onRevive", "restore"), true, "setFor from another state")
    eq(shared["nucleus.settings.rev"], rev0 + 1, "rev +1")
    eq(W.get("onRevive"), "restore", "Waypoints sees the change at its next get")
    eq(read(file("Waypoints")), "{}", "file written")
end

do -- watchers: called by the poll for changes by anyone; the poll runs only while a watcher exists
    local seen = {}
    local n0 = #loops
    local tok = W.watch(function(k, v) seen[#seen + 1] = k .. "=" .. tostring(v) end)
    ok(math.type(tok) == "integer", "watch returns an integer token")
    eq(#loops, n0 + 1, "one poll loop started"); eq(loops[#loops].ms, 500, "polling every 500 ms")
    local tok2 = W.watch(function() error("watcher boom") end)
    eq(#loops, n0 + 1, "a second watcher shares the loop")
    runLoops()
    eq(#seen, 0, "no change: no call")
    M.setFor("Waypoints", "onRevive", "clear")
    runLoops()
    eq(table.concat(seen, ","), "onRevive=clear", "the Manager's change reaches the watcher")
    eq(linesMatching("^%[Waypoints%] WARN settings watcher 2 failed for 'onRevive': .*watcher boom$"), 1, "a throwing watcher: one WARN, others still called")
    runLoops()
    eq(#seen, 1, "no repeat")
    -- own set: watchers called before set returns
    eq(W.set("onRevive", "restore"), true, "own set")
    eq(table.concat(seen, ","), "onRevive=clear,onRevive=restore", "own set calls the watcher at once")
    runLoops()
    eq(#seen, 2, "and the poll doesn't call it again")
    -- a change to another mod moves the revision but changes nothing here
    C.set("updateEvery", 5)
    runLoops()
    eq(#seen, 2, "another mod's change: no call")
    eq(W.unwatch(tok2), true, "unwatch")
    eq(W.unwatch(tok2), false, "unwatch again: false")
    eq(W.unwatch(12345), false, "unwatch an unknown token: false")
    eq(W.unwatch(tok), true, "unwatch the last")
    ok(cancelled[n0 + 1] == true, "the poll stops with the last watcher")
    M.setFor("Waypoints", "onRevive", "clear")
    runLoops()
    eq(#seen, 2, "after unwatch: not called")
    -- restart settings never call watchers; their get stays the session's value
    local K = newState("NucleusSkelTest", "NucleusSkelTest")
    local ks = {}
    K.watch(function(k, v) ks[#ks + 1] = k end)
    local before = K.get("test.boot")
    eq(K.set("test.boot", 77), true, "restart setting saved")
    eq(K.get("test.boot"), before, "restart: get keeps the session value")
    eq(#ks, 0, "restart: no watcher call")
    local d = K.describe("NucleusSkelTest")
    local e
    for _, x in ipairs(d.settings) do if x.key == "test.boot" then e = x end end
    ok(e.pendingRestart == true and e.saved == 77, "restart: describe shows pendingRestart")
    ok(K.set("test.count", 9) == true and ks[1] == "test.count", "anytime: the own watcher sees it")
end

do -- Read-only Difficulty through the client: describe and setFor
    local d = M.describe("Difficulty")
    eq(#d.settings, 19, "describe('Difficulty'): 19 entries")
    local all = true
    for i, e in ipairs(d.settings) do if not (e.readOnly == true and e.value == nil) then all = false end end
    ok(all, "describe('Difficulty'): all readOnly, value absent")
    eq(d.settings[1].key, "enemyDamage", "declaration order")
    ok(getmetatable(d.settings) == nil, "plain Lua tables")
    local okS, why = M.setFor("Difficulty", "dmg.husk", 10)
    ok(okS == false and why:find("^read%-only "), "setFor Difficulty: false, 'read-only ...'", why)
    ok(not exists(file("Difficulty")), "no file touched")
end

do -- Refusals by state return false; caller bugs raise
    WORLD = "World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap"
    local K = newState("NucleusSkelTest", "NucleusSkelTest")
    local okS, why = K.set("test.mode", "c")
    ok(okS == false and why:find("^locked "), "menu setting in a match: false, locked", why)
    okS, why = K.set("test.lobby", true)
    ok(okS == false and why:find("^locked "), "lobby: false, locked", why)
    okS, why = K.set("test.preset", 3)
    ok(okS == false and why:find("^read%-only "), "source: false, read-only", why)
    WORLD = "World /Game/Maps/NewMainMenu.NewMainMenu"
    local realOpen = io.open
    io.open = function(p, m) if p:find("%.tmp$") and m == "wb" then return nil, "disk full" end return realOpen(p, m) end
    okS, why = K.set("test.count", 11)
    io.open = realOpen
    ok(okS == false and why:find("^write%-failed "), "write fails: false, write-failed", why)
    eq(K.get("test.count"), 9, "write fails: value unchanged")

    local bad = {
        { function() return K.get(nil) end, "nucleus.settings.get: key must be a string, got nil" },
        { function() return K.get(42) end, "nucleus.settings.get: key must be a string, got number" },
        { function() return K.get({}) end, "nucleus.settings.get: key must be a string, got table" },
        { function() return K.get("") end, "nucleus.settings.get: key '' must be 1 to 64 bytes" },
        { function() return K.get("nope") end, "nucleus.settings.get: unknown key 'nope'" },
        { function() return K.getAll(1) end, "nucleus.settings.getAll: takes no arguments" },
        { function() return K.set(5, 1) end, "nucleus.settings.set: key must be a string" },
        { function() return K.set("nope", 1) end, "nucleus.settings.set: unknown key 'nope' in NucleusSkelTest" },
        { function() return K.set("test.count", 2.5) end, "nucleus.settings.set: bad value: test.count must be an integer" },
        { function() return K.set("test.count", 61) end, "nucleus.settings.set: bad value: test.count must be from 1 to 60" },
        { function() return K.set("test.mode", "x") end, "nucleus.settings.set: bad value: test.mode must be one of a|b|c" },
        { function() return K.set("test.ratio", 0 / 0) end, "nucleus.settings.set: value must be finite" },
        { function() return K.set("test.ratio", math.huge) end, "nucleus.settings.set: value must be finite" },
        { function() return K.set("test.ratio", -math.huge) end, "nucleus.settings.set: value must be finite" },
        { function() return K.set("test.flag", nil) end, "nucleus.settings.set: value must be a boolean, number or string, got nil" },
        { function() return K.set("test.flag", {}) end, "nucleus.settings.set: value must be a boolean, number or string, got table" },
        { function() return K.set("test.flag", print) end, "nucleus.settings.set: value must be" },
        { function() return K.set("test.flag", true, 3) end, "nucleus.settings.set: takes 2 arguments" },
        { function() return K.watch(nil) end, "nucleus.settings.watch: expected a function, got nil" },
        { function() return K.watch("f") end, "nucleus.settings.watch: expected a function, got string" },
        { function() return K.watch({}) end, "nucleus.settings.watch: expected a function, got table" },
        { function() return K.unwatch("1") end, "nucleus.settings.unwatch: token must be an integer, got string" },
        { function() return K.unwatch(1.5) end, "nucleus.settings.unwatch: token must be an integer, got float" },
        { function() return K.unwatch(nil) end, "nucleus.settings.unwatch: token must be an integer, got nil" },
        { function() return K.describe("..\\x") end, "nucleus.settings.describe: folder '..\\x' must match" },
        { function() return K.describe(string.rep("a", 65)) end, "nucleus.settings.describe: folder '" .. string.rep("a", 64) },
        { function() return K.describe(nil) end, "nucleus.settings.describe: folder must be a string, got nil" },
        { function() return K.describe("") end, "nucleus.settings.describe: folder '' must match" },
        { function() return K.setFor("..\\x", "a", 1) end, "nucleus.settings.setFor: folder '..\\x' must match" },
        { function() return K.setFor(string.rep("a", 65), "a", 1) end, "nucleus.settings.setFor: folder" },
        { function() return K.setFor("NoSuchMod", "a", 1) end, "nucleus.settings.setFor: unknown-mod NoSuchMod has no mod.json" },
        { function() return K.setFor("Plain", "a", 1) end, "nucleus.settings.setFor: no-settings" },
        { function() return K.setFor("Clock", "updateEvery", 61) end, "nucleus.settings.setFor: bad value: updateEvery must be from 1 to 60" },
        { function() return K.setFor(5, "a", 1) end, "nucleus.settings.setFor: folder must be a string, got number" },
    }
    local fileBefore = read(file("NucleusSkelTest"))
    for i, c in ipairs(bad) do raises(c[1], c[2], "client bad call " .. i .. ": " .. c[2]) end
    eq(read(file("NucleusSkelTest")), fileBefore, "client bad calls: nothing written")
    local r1, r2 = K.describe("NoSuchMod")
    ok(r1 == nil and r2:find("^unknown%-mod "), "describe(unknown): nil, 'unknown-mod ...'", r2)
    r1, r2 = K.describe("Plain")
    ok(r1 == nil and r2:find("^no%-settings "), "describe(no settings): nil, 'no-settings ...'", r2)
    -- a mod whose mod.json declares no settings: its own get raises cleanly
    local P = newState("Plain", "Plain")
    raises(function() P.get("x") end, "nucleus.settings.get: Plain declares no settings", "own mod without settings: get raises")

    -- off the game thread: every function refuses
    OFF = true
    for _, fn in ipairs({ "get", "getAll", "set", "setFor", "describe", "watch", "unwatch" }) do
        raises(function() return K[fn]("x", 1, 2) end, "nucleus.settings." .. fn .. ": called off the game thread", "off thread: " .. fn)
    end
    OFF = false
end

do -- core not answering: get raises cleanly, set returns false, describe returns nil
    local K = newState("Clock", "Clock")
    local realCall = cdo.Nucleus_Call
    cdo.Nucleus_Call = function() return "bp-default:x" end
    shared["nucleus.settings.rev"] = shared["nucleus.settings.rev"] + 1
    raises(function() K.get("updateEvery") end, "nucleus.settings.get: call-failed", "core silent: get raises")
    local okS, why = K.set("updateEvery", 3)
    ok(okS == false and type(why) == "string", "core silent: set false", why)
    local d, w = K.describe("Clock")
    ok(d == nil and type(w) == "string", "core silent: describe nil")
    cdo.Nucleus_Call = realCall
    eq(K.get("updateEvery"), 5, "core back: get works")
end

-- The api table: what connect hands out as core.settings
do
    package.loaded["nucleus.settings.client"] = nil
    local S = require("nucleus.settings.client")
    local names = {}
    for k, v in pairs(S.API) do ok(type(v) == "function", "API." .. k .. " is a function") names[#names + 1] = k end
    table.sort(names)
    eq(table.concat(names, ","), "describe,get,getAll,set,setFor,unwatch,watch", "core.settings has the seven functions")
end

do -- review fixes: init without modsDir; one state per folder whatever the case; problems rebuilt per read; caps
    raises(function() store.init{ core = "Nucleus" } end, "init needs a non-empty modsDir string", "init without modsDir raises")
    raises(function() store.init{ modsDir = "" } end, "init needs a non-empty modsDir string", "init with an empty modsDir raises")
    store.init{ modsDir = MODS, core = "Nucleus", log = logm.new("Nucleus"), rev = shared["nucleus.settings.rev"], world = function() return WORLD end,
                publishRev = function(n) shared["nucleus.settings.rev"] = n end }
    -- case: Windows paths ignore case, so "clock" and "Clock" are one state and one file
    ok(store.op("settings-set", '{"mod":"clock","key":"updateEvery","value":33}'):sub(1, 3) == "ok:", "set through 'clock'")
    eq(entryOf(decoded(desc("Clock")), "updateEvery").value, 33, "'Clock' sees the value set through 'clock'")
    ok(store.op("settings-set", '{"mod":"CLOCK","key":"updateEvery","value":34}'):sub(1, 3) == "ok:", "set through 'CLOCK'")
    eq(entryOf(decoded(desc("clock")), "updateEvery").value, 34, "one state: no stale copy overwrote it")
    eq(read(file("Clock")), '{"updateEvery":34}', "one file")
    local Cs = newState("Clock", "Clock")
    local seen = {}
    Cs.watch(function(k, v) seen[#seen + 1] = v end)
    eq(Cs.setFor("clock", "updateEvery", 35), true, "setFor on the own folder in another case")
    eq(seen[1], 35, "...refreshes the own cache at once (watcher called before setFor returns)")
    -- a watcher that unwatches during the call doesn't make the next one miss the change
    local Ws = newState("Waypoints", "Waypoints")
    local calls = {}
    local t1
    t1 = Ws.watch(function() calls[#calls + 1] = "a"; Ws.unwatch(t1) end)
    Ws.watch(function() calls[#calls + 1] = "b" end)
    local now = Ws.get("onRevive")
    Ws.set("onRevive", now == "clear" and "restore" or "clear")
    eq(table.concat(calls, ","), "a,b", "unwatch inside a watcher: the next watcher is still called")
    raises(function() Ws.get("onRevive", 2) end, "nucleus.settings.get: takes 1 argument (key)", "get with an extra argument raises")
    -- problems from a corrupt / partly invalid values file go away once a write replaces it
    modDir("Healed", SKEL)
    write(file("Healed"), '{"test.count":99,"test.flag":true}')
    local d = decoded(desc("Healed"))
    ok(#d.problems == 1 and d.problems[1]:find("entries ignored", 1, true), "partly invalid file: one problem", d.problems[1])
    ok(store.op("settings-set", '{"mod":"Healed","key":"test.count","value":5}'):sub(1, 3) == "ok:", "a set rewrites it")
    eq(#decoded(desc("Healed")).problems, 0, "after the write: no stale problem")
    modDir("Healed2", CLOCK)
    write(file("Healed2"), '{"a":')
    eq(#decoded(desc("Healed2")).problems, 1, "corrupt file: one problem")
    store.op("settings-set", '{"mod":"Healed2","key":"updateEvery","value":4}')
    eq(#decoded(desc("Healed2")).problems, 0, "corrupt file replaced: no stale problem")
    -- UTF-8: id and name cut at a character boundary
    eq(schema.cut(string.rep("a", 63) .. "\195\169", 64), string.rep("a", 63), "cut never splits a 2-byte character")
    eq(schema.cut("ab\226\130\172", 4), "ab", "cut never splits a 3-byte character")
    eq(schema.cut("abc", 64), "abc", "short strings unchanged")
    modDir("Utf", '{"id":"' .. string.rep("i", 63) .. '\226\130\172","name":"' .. string.rep("n", 62) .. '\240\159\152\128x",'
        .. '"settings":{"k":{"type":"bool","default":true}}}')
    local r = desc("Utf")
    local du = decoded(r)
    ok(du and du.id == string.rep("i", 63) and du.name == string.rep("n", 62), "id and name cut at a UTF-8 boundary, reply decodes", r:sub(1, 80))
end

do -- a description near the manifest cap goes through the client (its raised reply caps); long problems are capped
    local ents, vals = {}, {}
    for v = 1, 8 do vals[v] = '"' .. string.format("%02d", v) .. string.rep("v", 62) .. '"' end
    local valList = table.concat(vals, ",")
    for i = 1, 64 do
        ents[i] = string.format('"k%02d":{"type":"enum","values":[%s],"default":%s,"label":"%s","help":"%s","changeable":"anytime"}',
            i, valList, vals[1], string.rep("L", 64), string.rep("H", 256))
    end
    local text = '{"id":"big","name":"Big","settings":{' .. table.concat(ents, ",") .. '}}'
    ok(#text > 60000 and #text <= 65536, "the generated mod.json is near the 65,536-byte cap", #text)
    modDir("Big", text)
    -- three bad enum values: the "entries ignored" problem would be about 1.6 KB uncapped
    write(file("Big"), '{"k01":"' .. string.rep("x", 60) .. '","k02":"' .. string.rep("y", 60) .. '","k03":"' .. string.rep("z", 60) .. '"}')
    local B = newState("Big", "Big")
    local d = B.describe("Big")
    eq(d and #d.settings, 64, "client describe of a near-cap mod: 64 entries")
    ok(d and #d.problems == 1 and #d.problems[1] <= 256, "a long problem is capped at 256 bytes", d and #d.problems[1])
    eq(B.get("k64"), "01" .. string.rep("v", 62), "the mod's own get works")
end

do -- connect binds core.settings to the folder of the main.lua that called it
    function RegisterHook() return 1, 1 end
    function NotifyOnNewObject() end
    function FindAllOf() return nil end
    function FName(s) return s end
    function FText(s) return { s = s } end
    function LoopAsync() end
    function ExecuteInGameThread() end
    function ExecuteInGameThreadWithDelay() end
    function RegisterLoadMapPostHook() end
    Nucleus_NativeVersion = function() return "0.9.0", "v3.0.1-1181-g83330635" end
    Nucleus_ClockMicros = function() return 0 end
    package.loaded["nucleus.settings.client"] = nil
    package.loaded["nucleus.client"] = nil
    local cl = require("nucleus.client")
    local got
    local main = load("local cl, done = ... cl.connect{ mod = 'Clock', need = '>=0.9.0', onReady = done }",
        "@C:\\Games\\NN\\ue4ss\\Mods\\Clock\\Scripts\\main.lua")
    main(cl, function(core) got = core end)
    for _ = 1, 3 do runLoops() end
    ok(got ~= nil and type(got.settings) == "table", "connect: core.settings on the api")
    ok(got and got.has("settings") == true, "connect: core.has('settings')")
    eq(got and got.settings.get("updateEvery"), 35, "connect: core.settings.get reads the caller's own folder (Clock)")
end

do -- a value too long for the channel is a bad value (raises), not a refusal by state
    local S = newState("Clock", "Clock")
    raises(function() S.set("updateEvery", string.rep("x", 5000)) end, "nucleus.settings.set: bad value: the request is too long", "too-long value: set raises")
    raises(function() S.setFor("Waypoints", "onRevive", string.rep("x", 5000)) end, "nucleus.settings.setFor: bad value: the request is too long", "too-long value: setFor raises")
end

do -- a poll registered with an unusable handle is retired: it never calls the watchers
    local S = newState("Clock", "Clock")
    local realLoop, stray = LoopInGameThreadWithDelay, nil
    LoopInGameThreadWithDelay = function(ms, fn) stray = fn return "not-a-handle" end
    local seen = 0
    S.watch(function() seen = seen + 1 end)
    LoopInGameThreadWithDelay = realLoop
    eq(linesMatching("^%[Clock%] WARN settings poll could not start: LoopInGameThreadWithDelay returned not%-a%-handle$"), 1, "bad poll handle: one WARN")
    local cur = S.get("updateEvery")
    local other = newState("NucleusSkelPeer", "Manager")
    eq(select(1, other.setFor("Clock", "updateEvery", cur == 7 and 8 or 7)), true, "bad poll handle: a change from another state")
    ok(type(stray) == "function", "bad poll handle: the loop body was registered")
    stray()
    eq(seen, 0, "bad poll handle: the stray loop does nothing")
    eq(S.get("updateEvery"), cur == 7 and 8 or 7, "bad poll handle: get still sees the change")
end

print = realPrint
print(string.format("settings_test: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
