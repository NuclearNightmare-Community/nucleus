-- Unit tests for the map service's host setup (lua/pkg/map/setup.lua, map service stories 5, 6 and 8), outside the game: UE4SS
-- globals, the level's markers, PlayerStarts and the spawned game classes are fake Lua tables. Checks the marker value
-- checks, the Corrective count, the host gate, the deferral to the map load and the per-object lines; the in-game proof
-- is mods/map-spike's demo-solo. Run from the repo root with any standalone Lua 5.3 or 5.4:
--   lua test/unit/map_setup_test.lua   (on this workspace's machine: MiKTeX's texlua.exe)
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.5.0" } end
table.insert(package.searchers, 2, function(name)
    local rest = name:match("^nucleus%.(.+)$")
    if not rest then return nil end
    local path = ROOT .. "/lua/pkg/" .. rest:gsub("%.", "/") .. ".lua"
    local f = io.open(path, "r")
    if not f then return "\n\tno file " .. path end
    f:close()
    return assert(loadfile(path)), path
end)

-- ---------------------------------------------------------------- tiny harness
local pass, failN = 0, 0
local function ok(cond, what, extra)
    if cond then pass = pass + 1 else failN = failN + 1 print("FAIL " .. what .. (extra ~= nil and (" (" .. tostring(extra) .. ")") or "")) end
end

-- ---------------------------------------------------------------- fake engine
local objects = {}   -- path -> object
local nextAddr = 0x1000
local CLASS = {}     -- full class path -> class object
local function arr(list)
    local a = {}
    for i, v in ipairs(list or {}) do a[i] = v end
    function a:GetArrayNum() local n = 0 for _ in ipairs(self) do n = n + 1 end return n end
    return a
end
local function newObj(path, classPath, fields)
    nextAddr = nextAddr + 0x100
    local o = fields or {}
    local raw = {}
    for k, v in pairs(o) do raw[k] = v end
    local addr = nextAddr
    local meta = {
        __alive = true, __path = path, __class = classPath,
        GetFullName = function() return (classPath:match("([^%.]+)$") or "Object") .. " " .. path end,
        GetFName = function() local n = path:match("([^%.:]+)$") return { ToString = function() return n end } end,
        GetAddress = function() return addr end,
        GetClass = function() return CLASS[classPath] or { GetFullName = function() return "Class " .. classPath end, GetFName = function() return { ToString = function() return classPath:match("([^%.]+)$") end } end } end,
    }
    local t = setmetatable({}, {
        __index = function(_, k) if meta[k] ~= nil then return meta[k] end return raw[k] end,
        -- an object array property assigned from a Lua list reads back with GetArrayNum
        __newindex = function(_, k, v)
            if type(v) == "table" and getmetatable(v) == nil and (v[1] ~= nil or next(v) == nil) then raw[k] = arr(v)
            else raw[k] = v end
        end,
    })
    t.__meta = meta
    objects[path] = t
    return t
end
local function isAlive(o) return type(o) == "table" and o.__meta ~= nil and o.__meta.__alive == true end
local function kill(o) o.__meta.__alive = false objects[o.__meta.__path] = nil end

local INVALID = {}
function StaticFindObject(path) return objects[path] or INVALID end
function FName(s) return s end
function FText(s) return { ToString = function() return s end } end
local hooks = {}
function RegisterHook(path, fn) hooks[#hooks + 1] = { path = path, fn = fn } return #hooks end
local initHooks = {}
function RegisterInitGameStatePostHook(fn) initHooks[#initHooks + 1] = fn end
-- core's weak handles (lua/pkg/ref.lua wants userdata; here the handle is the object's path and deref gives the
-- object while it lives)
local refs, frees = 0, 0
package.preload["nucleus.ref"] = function()
    return {
        ref = function(o) refs = refs + 1 return o.__meta.__path end,
        deref = function(h) local o = objects[h] return (o and o.__meta.__alive) and o or nil end,
        free = function() frees = frees + 1 end,
    }
end

-- classes of the game, loadable with GetAsset (unless "dropped"); FindAllOf by short class name
local SHORT = {}
local function defClass(pkg, name)
    local full = pkg .. "." .. name
    local c = newObj(full, "/Script/CoreUObject.Class")
    c.__meta.GetFullName = function() return "BlueprintGeneratedClass " .. full end
    c.__meta.GetFName = function() return { ToString = function() return name end } end
    CLASS[full] = c
    SHORT[name] = full
    return c
end
local GAMECLASSES = {
    { "/Game/Gameplay/Lobby/GameStartService", "GameStartService_C" },
    { "/Game/Gameplay/Items/Item_Painkillers", "Item_Painkillers_C" },
    { "/Game/Gameplay/Items/Item_Flashlight", "Item_Flashlight_C" },
    { "/Game/Gameplay/ClassifiedMaterials/ObjectiveManager", "ObjectiveManager_C" },
    { "/Game/Gameplay/ClassifiedMaterials/BP_CM_V4", "BP_CM_V4_C" },
    { "/Game/Gameplay/ClassifiedMaterials/BP_Radio", "BP_Radio_C" },
    { "/Game/Gameplay/Generators/BP_GeneratorGameplayNew", "BP_GeneratorGameplayNew_C" },
    { "/Game/Models/lever/Lever_Actor", "Lever_Actor_C" },
    { "/Game/Gameplay/AISpawner", "AISpawner_C" },
    { "/Game/AI/EnemyWaypointSystem/EnemyWaypointActor", "EnemyWaypointActor_C" },
    { "/Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Sky", "Ultra_Dynamic_Sky_C" },
}
local unloadable = {}  -- class name -> true: GetAsset fails
local getAssets = 0
newObj("/Script/AssetRegistry.Default__AssetRegistryHelpers", "/Script/AssetRegistry.AssetRegistryHelpers", {
    GetAsset = function(_, a)
        getAssets = getAssets + 1
        if unloadable[a.AssetName] then return INVALID end
        local full = a.PackageName .. "." .. a.AssetName
        if not isAlive(objects[full]) then defClass(a.PackageName, a.AssetName) end
        return objects[full]
    end,
})
local function dropClass(name) local full = SHORT[name] if full and objects[full] then kill(objects[full]) end end

-- the two hooked functions exist (the Start marker's class is loaded with the level, the game state's with the game)
newObj("/Game/Mods/Nucleus/Map/BP_Marker_Start.BP_Marker_Start_C:ReceiveBeginPlay", "/Script/CoreUObject.Function")
newObj("/Game/FirstPerson/Blueprints/BP_FirstPersonGameState.BP_FirstPersonGameState_C:ReceiveBeginPlay", "/Script/CoreUObject.Function")
for _, k in ipairs({ "Start", "Item", "Intel", "Computer", "Generator", "Lever", "EnemySpawner", "EnemyWaypoint", "Landing", "Map", "Location", "Sky" }) do
    defClass("/Game/Mods/Nucleus/Map/BP_Marker_" .. k, "BP_Marker_" .. k .. "_C")
end
defClass("/Script/Engine.PlayerStart", "PlayerStart")
CLASS["/Script/Engine.PlayerStart"] = nil
SHORT.PlayerStart = "/Script/Engine.PlayerStart"

function FindAllOf(short)
    local out = {}
    for _, o in pairs(objects) do
        if isAlive(o) and o.__meta.__class == SHORT[short] then out[#out + 1] = o end
    end
    if #out == 0 then return nil end
    return out
end

-- the world: IsServer/IsStandalone through the KSL CDO; SpawnActor makes an actor of the class at the transform
local NET = { server = true, standalone = false }
local spawnedCount = 0
local spawnOffset = nil -- { X } to test a failing position check
-- the sky's fakes (story 8): Time of Day writes (or a throwing write, or a readback that differs), Update Replicated Time
-- and the game's own grounding (Ground UDS Actor moves a fresh sky to a trace hit + 90 Z: groundDz, and groundDx for a
-- sky that ends off its marker in X)
local SKY = { calls = 0, throwWrite = false, readOffset = 0, failSpawn = false, groundDz = 0, groundDx = 0 }
newObj("/Script/Engine.Default__KismetSystemLibrary", "/Script/Engine.KismetSystemLibrary", {
    IsServer = function() return NET.server end,
    IsStandalone = function() return NET.standalone end,
})
local WORLDS = {}
local function newWorld(path)
    local w = newObj(path, "/Script/Engine.World")
    local seq = 0
    w.SpawnActor = function(self, cls, at, r)
        local name = cls.__meta.GetFName():ToString()
        if name == "Ultra_Dynamic_Sky_C" and SKY.failSpawn then error("SpawnActor refused (test)", 0) end
        seq = seq + 1
        spawnedCount = spawnedCount + 1
        local a = newObj(path .. ":PersistentLevel." .. name .. "_" .. seq, cls.__meta.__path)
        local loc = { X = at.X + (spawnOffset or 0), Y = at.Y, Z = at.Z }
        if name == "Ultra_Dynamic_Sky_C" then loc.X, loc.Z = loc.X + SKY.groundDx, loc.Z + SKY.groundDz end
        local rr = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
        a.__meta.K2_GetActorLocation = function() return loc end
        a.__meta.K2_GetActorRotation = function() return rr end
        a.__meta.GetWorld = function() return self end
        a.__meta.SetReplicates = function(o, v) o.bReplicates = v end
        a.bReplicates = name ~= "Lever_Actor_C"
        if name == "Ultra_Dynamic_Sky_C" then
            local tod = 600
            a["Animate Time of Day"], a["Time Speed"] = false, 0.0
            a["Update Replicated Time"] = function(self) SKY.calls = SKY.calls + 1 end
            -- Time of Day through the metatable: a write may throw, a read may be off
            local mt = getmetatable(a)
            local idx, nidx = mt.__index, mt.__newindex
            mt.__index = function(t, k) if k == "Time of Day" then return tod + SKY.readOffset end return idx(t, k) end
            mt.__newindex = function(t, k, v)
                if k == "Time of Day" then if SKY.throwWrite then error("Time of Day: write refused (test)", 0) end tod = v return end
                nidx(t, k, v)
            end
        end
        return a
    end
    WORLDS[#WORLDS + 1] = w
    return w
end
local function place(world, name, classPath, at, yaw, fields)
    local a = newObj(world.__meta.__path .. ":PersistentLevel." .. name, classPath, fields)
    local loc, r = { X = at[1], Y = at[2], Z = at[3] }, { Pitch = 0, Yaw = yaw or 0, Roll = 0 }
    a.__meta.K2_GetActorLocation = function() return loc end
    a.__meta.K2_GetActorRotation = function() return r end
    a.__meta.GetWorld = function() return world end
    return a
end
local function marker(world, kind, name, at, yaw, fields) return place(world, name, "/Game/Mods/Nucleus/Map/BP_Marker_" .. kind .. ".BP_Marker_" .. kind .. "_C", at, yaw, fields) end
local function str(s) return { ToString = function() return s end } end

-- The demo level: 24 ground starts + 1 Corrective, one of each kind, two items, two intel areas, eight waypoints.
local function demoLevel(path, opts)
    opts = opts or {}
    local w = newWorld(path)
    for i = 1, (opts.starts or 24) do place(w, string.format("PS_%02d", i), "/Script/Engine.PlayerStart", { i * 100, 0, 0 }, 0, { PlayerStartTag = str(opts.tag and opts.tag(i) or "None") }) end
    for i = 1, (opts.corrective or 1) do place(w, "Lobby_" .. i, "/Script/Engine.PlayerStart", { 0, 0, 45000 }, 0, { PlayerStartTag = str(opts.correctiveTag or "Corrective") }) end
    local start = marker(w, "Start", "DM_Start", { -4200, 0, 0 })
    marker(w, "Item", "DM_Item_Painkillers", { -2000, -600, 0 }, 0, { Item = 0 })
    marker(w, "Item", "DM_Item_Flashlight", { -2000, 600, 0 }, 90, { Item = opts.badItem and 7 or 1 })
    marker(w, "Intel", "DM_Intel_North", { 0, 3000, 0 }, 0, { AreaName = str("Demo North"), UniqueIdentifier = str("DemoIntelNorth"), TaskText = str("") })
    marker(w, "Intel", "DM_Intel_South", { 0, -3000, 0 }, 0, { AreaName = str("Demo South"), UniqueIdentifier = str("DemoIntelSouth"), TaskText = str("") })
    local landing = marker(w, "Landing", "DM_Landing", { -1000, 3500, 0 })
    local rs = objects[path .. ":PersistentLevel.PS_01"]
    local computer = marker(w, "Computer", "DM_Computer", { 1000, 1000, 0 }, 45, { LocationName = str("Demo Computer"), Landing = landing, ReinforcementStart = rs })
    local gen = marker(w, "Generator", "DM_Generator", { 1000, -1000, 0 }, 180, { LocationName = str("Demo Generator") })
    gen.Equipment = arr({ opts.selfEquipment and gen or computer })
    marker(w, "Lever", "DM_Lever", { 1500, -1500, 0 }, 30)
    marker(w, "EnemySpawner", "DM_Spawner", { 4500, 0, 0 })
    for i = 1, 8 do marker(w, "EnemyWaypoint", "DM_Waypoint_" .. i, { i * 500, 2000, 0 }) end
    -- story 8: the Sky marker (turned 30 degrees: the sky spawns with rotation 0 anyway)
    for i = 1, (opts.skies or 1) do marker(w, "Sky", "DM_Sky" .. (i > 1 and ("_" .. i) or ""), { 0, 0, 2000 }, 30, { StartHour = not opts.hourNil and (opts.startHour or 10) or nil }) end
    return w, start
end

-- ---------------------------------------------------------------- core's objectives natives (story 3), faked
-- OBJ[path] = { tasks = { { id, text, ttext, state, tstate } } } once filled; RAW[path] = a describe text to return as
-- is (a hostile host's replicated values on a client). The fakes refuse what the real ones refuse that matters here.
local OBJ, RAW = {}, {}
local nativeCalls = { set = 0, describe = 0, traitor = 0 }
local refuseSet, refuseTraitor = false, false
local MGR_CLASS = "/Game/Gameplay/ClassifiedMaterials/ObjectiveManager.ObjectiveManager_C"
local function liveManager(fn, path)
    local o = objects[path]
    if not isAlive(o) or o.__meta.__class ~= MGR_CLASS then error(fn .. ": " .. tostring(path) .. " is not a live ObjectiveManager_C", 0) end
    return o
end
function Nucleus_SetObjectives(path, area, ...)
    nativeCalls.set = nativeCalls.set + 1
    local o = liveManager("Nucleus_SetObjectives", path)
    if refuseSet then error("Nucleus_SetObjectives: refused (test)", 0) end
    if not NET.server or NET.standalone then error("Nucleus_SetObjectives: not the host's world", 0) end
    if OBJ[path] then error("Nucleus_SetObjectives: " .. path .. " already has 1 objective(s); a manager is filled once only", 0) end
    local a = { ... }
    if #a == 0 or #a % 2 ~= 0 or #a > 128 then error("Nucleus_SetObjectives: bad task count", 0) end
    local t = {}
    for i = 1, #a, 2 do
        if type(a[i]) ~= "string" or type(a[i + 1]) ~= "string" or #a[i + 1] > 256 then error("Nucleus_SetObjectives: bad task", 0) end
        t[#t + 1] = { id = a[i], text = a[i + 1], ttext = a[i + 1], state = false, tstate = false }
    end
    OBJ[path] = { tasks = t }
    o["Area Name"] = FText(area)
    return math.tointeger(#t)
end
function Nucleus_DescribeObjectives(path)
    nativeCalls.describe = nativeCalls.describe + 1
    if RAW[path] then return RAW[path] end
    local o = liveManager("Nucleus_DescribeObjectives", path)
    local d = OBJ[path]
    local area = o["Area Name"] and o["Area Name"]:ToString() or ""
    local out = { string.format("manager\t%d\t0\t1\t%s", d and 1 or 0, area) }
    for i, t in ipairs(d and d.tasks or {}) do
        out[#out + 1] = string.format("task\t0\t%d\t%d\t%s\t%s\t%d\t%s", i - 1, t.state and 1 or 0, t.id, t.text, t.tstate and 1 or 0, t.ttext)
    end
    return table.concat(out, "\n")
end
function Nucleus_SetTraitorTaskState(path, id, state)
    nativeCalls.traitor = nativeCalls.traitor + 1
    liveManager("Nucleus_SetTraitorTaskState", path)
    if refuseTraitor then error("Nucleus_SetTraitorTaskState: refused (test)", 0) end
    local n = 0
    for _, t in ipairs(OBJ[path] and OBJ[path].tasks or {}) do if t.id == id then t.tstate = state n = n + 1 end end
    if n == 0 then error("Nucleus_SetTraitorTaskState: no task with id " .. id, 0) end
    return math.tointeger(n)
end
-- The game's pickup flow on the host: a task's State turns true (RPCUpdateTaskState).
local function pickup(id)
    for _, d in pairs(OBJ) do for _, t in ipairs(d.tasks) do if t.id == id then t.state = true end end end
end

-- the 1 s loop and the cabin sound
local loops, cancelled = {}, 0
function LoopInGameThreadWithDelay(ms, fn) loops[#loops + 1] = { ms = ms, fn = fn } return #loops end
function CancelDelayedAction() cancelled = cancelled + 1 end
local sounds = {}
local soundFails = false
newObj("/Script/Engine.Default__GameplayStatics", "/Script/Engine.GameplayStatics", {
    SpawnSoundAtLocation = function(_, ctx, wave, loc, rot, vol, pitch, t0, att, conc, auto)
        if soundFails then return nil end
        local ac = newObj("/Engine/Transient.AudioComponent_" .. (#sounds + 1), "/Script/Engine.AudioComponent", { Sound = wave, AttenuationSettings = att })
        sounds[#sounds + 1] = { ac = ac, loc = loc, wave = wave, att = att, ctx = ctx }
        return ac
    end,
})

-- ---------------------------------------------------------------- the module
local MS = require("nucleus.map.setup")
MS.alive = isAlive
local logs = {}
local LOGGER = {
    info = function(f, ...) logs[#logs + 1] = string.format(f, ...) end,
    warn = function(f, ...) logs[#logs + 1] = "WARN " .. string.format(f, ...) end,
    error = function(f, ...) logs[#logs + 1] = "ERROR " .. string.format(f, ...) end,
    debug = function(f, ...) logs[#logs + 1] = "DEBUG " .. string.format(f, ...) end,
}
MS.init({ log = LOGGER })
local function lines(rx) local out = {} for _, l in ipairs(logs) do if l:find(rx) then out[#out + 1] = l end end return out end
local function count(rx) return #lines(rx) end
local function dump() for _, l in ipairs(logs) do print("  | " .. l) end end
local function ofClass(world, name)
    local n = 0
    for _, o in pairs(objects) do if isAlive(o) and o.__meta.__class == SHORT[name] and o.__meta.__path:find(world.__meta.__path, 1, true) == 1 then n = n + 1 end end
    return n
end
-- One map load as the engine runs it: InitGameState, the Start marker's BeginPlay, the game state's BeginPlay, LoadMap.
local function load(world, start, opts)
    opts = opts or {}
    logs = {}
    MS.onInitGameState()
    if start then MS.onStartBeginPlay(start) end
    local gs = place(world, "GameState_" .. #logs, "/Game/FirstPerson/Blueprints/BP_FirstPersonGameState.BP_FirstPersonGameState_C", { 0, 0, 0 })
    MS.onGameStateBeginPlay(gs)
    if opts.beforeLoadMap then opts.beforeLoadMap() end
    MS.onLoadMap(world)
end

-- ---------------------------------------------------------------- pure checks
ok(MS.itemKind(0) == "Painkillers" and MS.itemKind(1) == "Flashlight", "item: 0 Painkillers, 1 Flashlight")
ok(MS.itemKind(1.0) == "Flashlight", "item: a float 1.0 is 1")
for _, bad in ipairs({ 2, -1, 0.5, 255, "1", true, 0 / 0 }) do ok(MS.itemKind(bad) == nil, "item: refused " .. tostring(bad)) end
ok(MS.itemKind(nil) == nil, "item: refused nil")
ok(MS.checkText("Demo North", 128) == true, "text: plain")
ok(MS.checkText("", 128) == false and MS.checkText("", 128, true) == true, "text: empty only when allowed")
ok(MS.checkText(string.rep("a", 129), 128) == false and MS.checkText(string.rep("a", 128), 128) == true, "text: 128 cap")
ok(MS.checkText("caf\195\169", 128) == false and MS.checkText("a\nb", 128) == false, "text: non-ASCII and control characters refused")
ok(MS.checkText(nil, 128) == false and MS.checkText(5, 128) == false, "text: non-strings refused")
ok(MS.checkId("DemoIntelNorth") == true and MS.checkId("a.b-c_9") == true, "id: allowed set")
ok(MS.checkId("") == false and MS.checkId("a b") == false and MS.checkId("a/b") == false and MS.checkId(string.rep("x", 65)) == false, "id: empty, space, slash, 65 refused")
ok(MS.checkId(string.rep("x", 64)) == true, "id: 64 allowed")

local function starts(n, corr)
    local l = {}
    for i = 1, n do l[#l + 1] = { name = string.format("PS_%02d", n - i + 1), tag = "None" } end
    for i = 1, corr do l[#l + 1] = { name = "Lobby" .. i, tag = "Corrective" } end
    return l
end
do
    local s, c, p = MS.splitStarts(starts(24, 1))
    ok(#s == 24 and c == 1 and p == nil, "starts: 24 + 1 Corrective is fine", p)
    ok(s[1].name == "PS_01" and s[24].name == "PS_24", "starts: sorted by name")
    s, c, p = MS.splitStarts(starts(20, 1))
    ok(p == nil, "starts: exactly 20 is enough")
    s, c, p = MS.splitStarts(starts(19, 1))
    ok(p ~= nil and p:find("19 PlayerStarts", 1, true) and not p:find("Corrective"), "starts: 19 is too few", p)
    s, c, p = MS.splitStarts(starts(24, 0))
    ok(#s == 24 and c == 0 and p and p:find("0 Corrective", 1, true), "starts: 0 Corrective", p)
    s, c, p = MS.splitStarts(starts(24, 2))
    ok(#s == 24 and c == 2 and p and p:find("2 Corrective", 1, true), "starts: 2 Corrective, both left out", p)
    s, c, p = MS.splitStarts(starts(3, 2))
    ok(p and p:find("3 PlayerStarts", 1, true) and p:find("2 Corrective", 1, true), "starts: both problems in one text", p)
end
-- core story 40: start zones (Zone<n> tags, any number, one picked with equal odds; all ten arrays = the picked zone)
do
    local T = MS.startTag
    ok(T("Corrective") == "corrective" and T("corrective") == "corrective" and T("CORRECTIVE") == "corrective", "zones: Corrective in any case")
    ok(T("Zone1") == 1 and T("zone2") == 2 and T("ZONE3") == 3 and T("Zone01") == 1 and T("Zone10") == 10, "zones: Zone<n> in any case, leading zeros")
    ok(T("Zone11") == 11 and T("Zone100") == 100 and T("Zone999999999") == 999999999 and T("Zone000000000000042") == 42, "zones: above 10 accepted, 9 significant digits")
    ok(T("Zone0") == "bad" and T("Zone00") == "bad" and T("Zone") == "bad" and T("ZoneA") == "bad" and T("ZoneX") == "bad" and T("Zone 1") == "bad"
        and T("Zone1a") == "bad" and T("Zone-1") == "bad" and T("Zone1000000000") == "bad" and T("Zoned") == "bad", "zones: bad zone tags")
    ok(T("None") == nil and T("") == nil and T(nil) == nil and T(5) == nil and T("Lobby") == nil and T("Correctives") == nil and T("Z1") == nil, "zones: untagged")
end
local function zoned(spec)
    -- spec: { { tag, count [, prefix] }, ... } -> PlayerStart entries, numbered in reverse so the sort is checked
    local l = {}
    for _, g in ipairs(spec) do
        for i = g[2], 1, -1 do l[#l + 1] = { name = string.format("%s_%03d", g[3] or g[1], i), tag = g[1] } end
    end
    return l
end
local function pickN(i) local seen = {} return function(n) seen[#seen + 1] = n return i end, seen end
do
    -- single cluster: exactly splitStarts' result, no summary, no pick
    local l = starts(24, 1)
    local a, sumA, cA, pA = MS.planStarts(l, function() error("no pick without zones") end)
    local b, cB, pB = MS.splitStarts(l)
    ok(#a == 24 and sumA == nil and cA == cB and pA == pB and a[1] == b[1] and a[24] == b[24], "plan: single cluster = splitStarts, no summary")
    a, sumA, cA, pA = MS.planStarts(starts(19, 2))
    ok(sumA == nil and pA == select(3, MS.splitStarts(starts(19, 2))), "plan: single cluster problems unchanged", pA)
    -- two zones: picked zone 2, all its 20 starts, sorted; pick gets the zone count
    local pick, seen = pickN(2)
    local list, sum, c, p = MS.planStarts(zoned({ { "Zone1", 20 }, { "Zone2", 20 }, { "None", 2, "U" }, { "Corrective", 1 } }), pick)
    ok(#seen == 1 and seen[1] == 2, "plan: pick called once with the zone count", seen[1])
    ok(p == nil and c == 1 and sum and #sum.zones == 2 and sum.picked == 2 and sum.untagged == 2, "plan: two zones, picked Zone2, 2 untagged", p)
    ok(#list == 20 and list[1].name == "Zone2_001" and list[20].name == "Zone2_020", "plan: the picked zone's starts, name-sorted")
    ok(MS.zoneText(sum) == "Zone1 x20, Zone2 x20", "plan: zone text", MS.zoneText(sum))
    list, sum = MS.planStarts(zoned({ { "Zone1", 20 }, { "Zone2", 20 }, { "Corrective", 1 } }), pickN(1))
    ok(sum.picked == 1 and list[1].name == "Zone1_001", "plan: pick 1 -> Zone1")
    -- ten zones (with gaps: numbers sorted, the pick indexes the sorted list)
    local ten = {}
    for z = 1, 10 do ten[#ten + 1] = { "Zone" .. (z * 3), 20 } end
    ten[#ten + 1] = { "Corrective", 1 }
    pick, seen = pickN(10)
    list, sum, c, p = MS.planStarts(zoned(ten), pick)
    ok(p == nil and #sum.zones == 10 and seen[1] == 10 and sum.picked == 30 and #list == 20 and list[1].tag == "Zone30", "plan: ten zones with gaps, one picked", p)
    -- zone too small: one problem, still filled
    list, sum, c, p = MS.planStarts(zoned({ { "Zone1", 20 }, { "Zone2", 8 }, { "Corrective", 1 } }), pickN(2))
    ok(p == "Zone2: 8 PlayerStarts (need 20+)" and #list == 8 and sum.picked == 2, "plan: a zone under 20 is the problem, the arrays still filled", p)
    -- bad tags: Zone11 is zone 11 with 1 start, ZoneX is a bad tag; one combined text
    list, sum, c, p = MS.planStarts(zoned({ { "Zone1", 20 }, { "Zone2", 20 }, { "Zone11", 1 }, { "ZoneX", 1 }, { "Corrective", 1 } }), pickN(1))
    ok(p and p:find("ZoneX_001 (ZoneX)", 1, true) and p:find("Zone11: 1 PlayerStarts (need 20+)", 1, true) and not p:find("Zone11_001", 1, true), "plan: ZoneX a bad tag, Zone11 under 20, one text", p)
    ok(#sum.zones == 3 and sum.zones[3].n == 11 and sum.untagged == 0 and #list == 20, "plan: the bad-tag start left out, not untagged")
    -- a bad tag in a level without zones: the problem, the start left out, the rest as a single cluster
    list, sum, c, p = MS.planStarts(zoned({ { "None", 24, "PS" }, { "Zone0", 1 }, { "Corrective", 1 } }))
    ok(sum == nil and #list == 24 and c == 1 and p and p:find("Zone0_001 (Zone0)", 1, true), "plan: a bad tag without zones: one problem, left out", p)
    -- mixed case: one zone of 25, lowercase corrective is the lobby start
    list, sum, c, p = MS.planStarts(zoned({ { "zone1", 20, "a" }, { "ZONE1", 5, "b" }, { "corrective", 1 } }), pickN(1))
    ok(p == nil and c == 1 and #sum.zones == 1 and sum.zones[1].count == 25 and #list == 25, "plan: mixed case, one zone of 25, 1 Corrective", p)
    -- zoned with 0 or 2 Corrective: today's Corrective text
    list, sum, c, p = MS.planStarts(zoned({ { "Zone1", 20 } }), pickN(1))
    ok(c == 0 and p == "0 Corrective lobby starts (need exactly 1)" and #list == 20, "plan: zoned, 0 Corrective", p)
    list, sum, c, p = MS.planStarts(zoned({ { "Zone1", 20 }, { "Corrective", 2 } }), pickN(1))
    ok(c == 2 and p == "2 Corrective lobby starts (need exactly 1)", "plan: zoned, 2 Corrective", p)
    -- a pick out of range falls back to the first zone
    list, sum = MS.planStarts(zoned({ { "Zone1", 20 }, { "Zone2", 20 }, { "Corrective", 1 } }), function() return 7 end)
    ok(sum.picked == 1, "plan: an out-of-range pick falls back to the first zone")
    -- the default pick: always a zone that exists, both reached
    local got = {}
    for _ = 1, 200 do local _, s2 = MS.planStarts(zoned({ { "Zone1", 20 }, { "Zone5", 20 }, { "Corrective", 1 } })) got[s2.picked] = true end
    ok(got[1] and got[5] and not got[2], "plan: the default pick reaches both zones")
    -- the OK line's zone list: at most 16, then +N more
    local many = {}
    for z = 1, 18 do many[#many + 1] = { "Zone" .. z, 20 } end
    list, sum = MS.planStarts(zoned(many), pickN(1))
    local zt = MS.zoneText(sum)
    ok(zt:find("Zone16 x20, +2 more", 1, true) and not zt:find("Zone17", 1, true), "plan: 16 zones listed, then +N more", zt)
end
do
    local sp = { ["/L.L:PersistentLevel.C"] = "/L.L:PersistentLevel.Radio_1" }
    local good = { path = "/L.L:PersistentLevel.C", kind = "Computer", world = true }
    local eq = MS.checkEquipment({ good }, "/L.L:PersistentLevel.G", sp)
    ok(eq and eq[1] == "/L.L:PersistentLevel.Radio_1", "equipment: a computer marker maps to its radio")
    local _, why = MS.checkEquipment({ { path = "/L.L:PersistentLevel.G", kind = "Generator", world = true } }, "/L.L:PersistentLevel.G", sp)
    ok(why and why:find("itself", 1, true), "equipment: itself refused", why)
    _, why = MS.checkEquipment({ {} }, "/L.L:PersistentLevel.G", sp)
    ok(why and why:find("empty or not a live actor", 1, true), "equipment: an empty entry refused", why)
    _, why = MS.checkEquipment({ { path = "/L.L:PersistentLevel.Rock", world = true } }, "/L.L:PersistentLevel.G", sp)
    ok(why and why:find("not one of Nucleus's markers", 1, true), "equipment: a non-marker refused", why)
    _, why = MS.checkEquipment({ { path = "/X.X:PersistentLevel.C", kind = "Computer", world = false } }, "/L.L:PersistentLevel.G", sp)
    ok(why and why:find("not in this level", 1, true), "equipment: another level's marker refused", why)
    _, why = MS.checkEquipment({ { path = "/L.L:PersistentLevel.Landing", kind = "Landing", world = true } }, "/L.L:PersistentLevel.G", sp)
    ok(why and why:find("no spawned object", 1, true), "equipment: a marker that spawns nothing refused", why)
    _, why = MS.checkEquipment({ good, good }, "/L.L:PersistentLevel.G", sp)
    ok(why and why:find("twice", 1, true), "equipment: a duplicate refused", why)
    _, why = MS.checkEquipment({}, "/L.L:PersistentLevel.G", sp)
    ok(why and why:find("empty", 1, true), "equipment: no entries refused", why)
    local many = {}
    for i = 1, 65 do many[i] = good end
    _, why = MS.checkEquipment(many, "/L.L:PersistentLevel.G", sp)
    ok(why and why:find("65 entries", 1, true), "equipment: 65 entries refused", why)
end
ok(MS.yawDiff(359.995, 0) < 0.01 and MS.yawDiff(359.995, 0) > -0.01 and MS.yawDiff(-180, 180) == 0 and MS.yawDiff(90, 0) == 90, "yaw: wraps")

-- ---------------------------------------------------------------- install
MS.install()
ok(#initHooks == 1, "install: one InitGameState post-hook")

-- ---------------------------------------------------------------- solo match, every class in memory at BeginPlay
NET.server, NET.standalone = true, false
local menu = newWorld("/Game/Maps/NewMainMenu.NewMainMenu")
logs = {}
MS.onLoadMap(menu)
ok(getAssets >= 10 and count("^OK WIRE") == 0 and count("^FAIL") == 0, "menu: classes preloaded, nothing wired", getAssets)

local w1, s1 = demoLevel("/Game/Mods/DemoMap/Maps/L_DemoMap.L_DemoMap")
spawnedCount = 0
load(w1, s1)
ok(#hooks == 2 and hooks[1].path:find("BP_Marker_Start_C:ReceiveBeginPlay", 1, true) and hooks[2].path:find("BP_FirstPersonGameState_C:ReceiveBeginPlay", 1, true), "hooks: start marker and game state BeginPlay", #hooks)
ok(count("^FAIL") == 0, "solo: no FAIL line", count("^FAIL")) if count("^FAIL") > 0 then dump() end
ok(count("^OK WIRE GameStartService_C at %(%-4200,0,0%), 10 %*Starts arrays x 24 PlayerStarts %(1 Corrective") == 1, "solo: the service, 24 starts, 1 Corrective out")
ok(count("the nuke flight starts from this service %(native on V8%.2%)") == 1 and count("12000") == 0, "solo: the nuke line names the service and claims no 12000")
ok(count("^OK WIRE item marker=DM_Item_Painkillers Item=0 Item_Painkillers_C at ") == 1 and count("^OK WIRE item marker=DM_Item_Flashlight Item=1 Item_Flashlight_C at ") == 1, "solo: each item marker spawns its own item")
ok(count('^OK WIRE ObjectiveManager_C ') == 2 and count('^OK WIRE intel BP_CM_V4_C ') == 2, "solo: two managers, two intel")
ok(count('^OK WIRE BP_Radio_C "Demo Computer" HelicopterLocation=%(%-1000,3500,0%) ReinformantLocation=PS_01') == 1, "solo: the computer wired")
ok(count('^OK WIRE BP_GeneratorGameplayNew_C "Demo Generator" Equipment=1 %(BP_Radio_C%)') == 1, "solo: the generator's Equipment is the radio")
ok(count('^OK WIRE Lever_Actor_C .* bReplicates=true %(spawned with false%)') == 1, "solo: the lever replicates")
ok(count('^OK WIRE AISpawner_C ') == 1 and count('^OK WIRE 8 EnemyWaypointActor_C') == 1 and count('^OK WIRE waypoint marker=') == 8, "solo: spawner and 8 waypoints")
ok(count("^OK POS ") == spawnedCount and spawnedCount == 1 + 2 + 2 + 2 + 1 + 1 + 1 + 1 + 8 + 1, "solo: a position check per spawned object", spawnedCount .. " spawned, " .. count("^OK POS "))
ok(count("^OK POS BP_Radio_C marker=DM_Computer distance=0%.000 yaw=0%.000") == 1, "solo: POS line shape")
ok(count("^ORDER game state BeginPlay: start marker began first=true GameStartService_C present=true") == 1, "solo: ORDER present=true")
ok(count("everything spawned") == 1, "solo: everything at BeginPlay")
do
    local svc = objects[MS.state().service]
    ok(svc and svc.BaseCampStarts:GetArrayNum() == 24 and svc.DrillingRigStarts:GetArrayNum() == 24, "solo: the ten arrays hold the 24 ground starts")
    local corr = false
    for _, ps in ipairs(svc.OilRigStarts) do if ps.PlayerStartTag:ToString() == "Corrective" then corr = true end end
    ok(not corr, "solo: the Corrective start is not in the arrays")
end
do
    local n = 0
    for _, o in pairs(objects) do if isAlive(o) and o.__meta.__class == SHORT.ObjectiveManager_C then n = n + 1 ok(o["Area Name"]:ToString():find("^Demo "), "solo: Area Name set") ok(o.Objectives == nil, "solo: Objectives never written from Lua") end end
    ok(n == 2, "solo: two managers exist", n)
end

-- ---------------------------------------------------------------- the travel's GC dropped the intel classes: deferred to the map load
local w2, s2 = demoLevel("/Game/Mods/DemoMap/Maps/L_DemoMap2.L_DemoMap2")
dropClass("ObjectiveManager_C") dropClass("BP_CM_V4_C")
local intelBefore
load(w2, s2, { beforeLoadMap = function() intelBefore = count('^OK WIRE intel ') end })
ok(intelBefore == 0, "deferred: no intel at BeginPlay")
ok(count("deferred until the map has loaded %(classes not in memory%): intel") == 1, "deferred: logged")
ok(count("^ORDER .*present=true spawned before it: computer,generator,items,lever,service,spawner,waypoints") == 1, "deferred: ORDER names what was there first")
ok(count('^OK WIRE intel BP_CM_V4_C ') == 2 and count("^FAIL") == 0, "deferred: intel spawned in the LoadMap post-hook")

-- the generator waits for a deferred kind it lists
local w3, s3 = demoLevel("/Game/Mods/DemoMap/Maps/L_DemoMap3.L_DemoMap3")
dropClass("BP_Radio_C")
local genBefore
load(w3, s3, { beforeLoadMap = function() genBefore = count('^OK WIRE BP_GeneratorGameplayNew_C') end })
ok(genBefore == 0 and count('^OK WIRE BP_GeneratorGameplayNew_C "Demo Generator" Equipment=1') == 1 and count("^FAIL") == 0, "deferred: the generator waits for the computer it lists")

-- a class that can't load at all: one FAIL line, the rest wired
local w4, s4 = demoLevel("/Game/Mods/DemoMap/Maps/L_DemoMap4.L_DemoMap4")
dropClass("Lever_Actor_C") unloadable.Lever_Actor_C = true
load(w4, s4)
ok(count("^FAIL WIRE lever: class /Game/Models/lever/Lever_Actor%.Lever_Actor_C did not load") == 1 and count("^FAIL") == 1 and count("^OK WIRE AISpawner_C") == 1, "unloadable: one FAIL line, the rest wired")
unloadable.Lever_Actor_C = nil

-- the service's class was dropped: not there at the game state's BeginPlay (ORDER present=false and one FAIL line)
local w4b, s4b = demoLevel("/Game/Mods/DemoMap/Maps/L_DemoMap4b.L_DemoMap4b")
dropClass("GameStartService_C")
load(w4b, s4b)
ok(count("^ORDER .*GameStartService_C present=false") == 1 and count("^FAIL WIRE GameStartService_C was not there at the game state's BeginPlay") == 1 and count("^FAIL") == 1, "no service first: ORDER present=false, one FAIL line")
ok(count("^OK WIRE GameStartService_C at ") == 1, "no service first: spawned after the map load")

-- ---------------------------------------------------------------- bad values: an Equipment entry naming itself, an unknown Item
local w5, s5 = demoLevel("/Game/Mods/DemoMap/Maps/L_Bad.L_Bad", { selfEquipment = true, badItem = true })
spawnedCount = 0
local okRun, errRun = pcall(load, w5, s5)
ok(okRun, "bad values: no Lua error escapes", errRun)
ok(count("^FAIL WIRE BP_GeneratorGameplayNew_C marker=DM_Generator: Equipment%[1%] names the generator itself; skipped") == 1, "bad values: the generator naming itself is one FAIL line")
ok(count("^FAIL WIRE item marker=DM_Item_Flashlight: Item unknown value 7; skipped") == 1, "bad values: the unknown Item is one FAIL line")
ok(count("^FAIL") == 2, "bad values: exactly those two FAIL lines", count("^FAIL"))
ok(ofClass(w5, "BP_GeneratorGameplayNew_C") == 0 and ofClass(w5, "Item_Flashlight_C") == 0, "bad values: those objects skipped")
ok(ofClass(w5, "Item_Painkillers_C") == 1 and count("^OK WIRE BP_Radio_C") == 1 and count("^OK WIRE 8 EnemyWaypointActor_C") == 1, "bad values: the rest wired")

-- bad intel values: an empty area, a bad id, a duplicate id; the computer without a landing
local w6, s6 = demoLevel("/Game/Mods/DemoMap/Maps/L_Bad2.L_Bad2")
marker(w6, "Intel", "DM_Intel_X1", { 0, 0, 0 }, 0, { AreaName = str(""), UniqueIdentifier = str("X1") })
marker(w6, "Intel", "DM_Intel_X2", { 0, 0, 0 }, 0, { AreaName = str("Demo North"), UniqueIdentifier = str("bad id!") })
marker(w6, "Intel", "DM_Intel_X3", { 0, 0, 0 }, 0, { AreaName = str("Demo North"), UniqueIdentifier = str("DemoIntelSouth") })
objects["/Game/Mods/DemoMap/Maps/L_Bad2.L_Bad2:PersistentLevel.DM_Computer"].Landing = nil
load(w6, s6)
ok(count("^FAIL WIRE intel marker=DM_Intel_X1: AreaName empty") == 1 and count("^FAIL WIRE intel marker=DM_Intel_X2: UniqueIdentifier characters outside") == 1, "bad intel: empty area, bad id")
ok(count('already used by') == 1 and count('^OK WIRE intel BP_CM_V4_C ') == 2, "bad intel: a duplicate id skipped, the good two wired")
ok(count("^FAIL WIRE BP_Radio_C marker=DM_Computer: no Landing set; skipped") == 1, "bad computer: no Landing")
ok(count("^FAIL WIRE BP_GeneratorGameplayNew_C marker=DM_Generator: Equipment%[1%] %(Computer marker") == 1, "bad computer: the generator listing it is skipped too")

-- ---------------------------------------------------------------- few starts / Corrective counts: one FAIL line, otherwise as usual
for _, c in ipairs({ { 19, 1, "19 PlayerStarts %(need 20%+%)" }, { 24, 0, "0 Corrective" }, { 24, 2, "2 Corrective" } }) do
    local w, s = demoLevel(string.format("/Game/Mods/DemoMap/Maps/L_S%d_%d.L_S%d_%d", c[1], c[2], c[1], c[2]), { starts = c[1], corrective = c[2] })
    load(w, s)
    ok(count("^FAIL") == 1 and count("^FAIL WIRE PlayerStarts: .*" .. c[3]) == 1, "starts " .. c[1] .. "/" .. c[2] .. ": one FAIL line", table.concat(lines("^FAIL"), " | "))
    ok(count("^OK WIRE GameStartService_C at .* x " .. c[1] .. " PlayerStarts") == 1 and count("^OK WIRE 8 EnemyWaypointActor_C") == 1, "starts " .. c[1] .. "/" .. c[2] .. ": otherwise wired as usual")
end

-- more PlayerStarts than the cap: the arrays stop at the cap, the overflow is reported
do
    local cap = MS.LIMIT.starts
    MS.LIMIT.starts = 22
    local w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_Cap.L_Cap")
    load(w, s)
    MS.LIMIT.starts = cap
    local svc = objects[MS.state().service]
    ok(count("^FAIL WIRE PlayerStarts: .*more than 22 PlayerStarts") == 1, "starts cap: the overflow is one FAIL line", table.concat(lines("^FAIL"), " | "))
    ok(svc and svc.BaseCampStarts:GetArrayNum() <= 22, "starts cap: the arrays stop at the cap", svc and svc.BaseCampStarts:GetArrayNum())
end

-- core story 40: two start zones through the fake service: all ten arrays = the picked zone's starts
do
    local pick = MS.pick
    for _, want in ipairs({ 1, 2 }) do
        MS.pick = function() return want end
        local w, s = demoLevel(string.format("/Game/Mods/DemoMap/Maps/L_Zones%d.L_Zones%d", want, want), { starts = 42, tag = function(i)
            if i <= 20 then return "Zone1" elseif i <= 40 then return "zone2" else return "None" end end })
        load(w, s)
        local svc = objects[MS.state().service]
        ok(count("^FAIL") == 0, "zones " .. want .. ": no FAIL line", table.concat(lines("^FAIL"), " | "))
        ok(count("^OK WIRE GameStartService_C at %(%-4200,0,0%), 2 start zones %(Zone1 x20, Zone2 x20%), picked Zone" .. want
            .. ": 10 %*Starts arrays x 20 PlayerStarts %(1 Corrective lobby start left out, 2 untagged left out%); the nuke flight") == 1,
            "zones " .. want .. ": the OK line names both zones and the pick", table.concat(lines("WIRE GameStartService_C"), " | "))
        local first = want == 1 and "PS_01" or "PS_21"
        local good = svc ~= nil
        for _, prop in ipairs(MS.STARTS) do
            local a = svc and svc[prop]
            if not (a and a:GetArrayNum() == 20 and a[1].__meta.GetFName():ToString() == first) then good = false end
            for _, ps in ipairs(a or {}) do
                if MS.startTag(ps.PlayerStartTag:ToString()) ~= want then good = false end
            end
        end
        ok(good, "zones " .. want .. ": all ten arrays hold the picked zone's 20, name-sorted")
    end
    -- a zoned level with a too-small zone and a bad tag: one FAIL line, still filled
    MS.pick = function() return 1 end
    local w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_ZonesBad.L_ZonesBad", { starts = 29, tag = function(i)
        if i <= 20 then return "Zone1" elseif i <= 28 then return "Zone2" else return "ZoneX" end end })
    load(w, s)
    ok(count("^FAIL") == 1 and count("^FAIL WIRE PlayerStarts: start zone tag not Zone<n> .*PS_29 %(ZoneX%), Zone2: 8 PlayerStarts %(need 20%+%); 20 go into") == 1,
        "zones bad: one FAIL line with the bad tag and the small zone", table.concat(lines("^FAIL"), " | "))
    ok(count("^OK WIRE GameStartService_C at .*, 2 start zones %(Zone1 x20, Zone2 x8%), picked Zone1:") == 1, "zones bad: still filled")
    MS.pick = pick
end

-- a position that is off: FAIL POS
local w7, s7 = demoLevel("/Game/Mods/DemoMap/Maps/L_Off.L_Off")
spawnOffset = 5
load(w7, s7)
spawnOffset = nil
ok(count("^FAIL POS GameStartService_C marker=DM_Start distance=5%.000 yaw=0%.000") == 1 and count("^OK POS ") == 0, "position: an object off its marker fails its check")

-- ---------------------------------------------------------------- the host gate
for _, net in ipairs({ { false, false, "client" }, { true, true, "standalone" } }) do
    NET.server, NET.standalone = net[1], net[2]
    local w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_" .. net[3] .. ".L_" .. net[3])
    spawnedCount = 0
    load(w, s)
    ok(spawnedCount == 0 and count("WIRE") == 0, net[3] .. ": nothing spawned, no WIRE line", spawnedCount)
    ok(count("isHost=false") >= 1, net[3] .. ": isHost=false logged")
end
NET.server, NET.standalone = true, false

-- a second Start marker: one FAIL line, one setup
local w8, s8 = demoLevel("/Game/Mods/DemoMap/Maps/L_Two.L_Two")
local s8b = marker(w8, "Start", "DM_Start_B", { 0, 0, 0 })
spawnedCount = 0
logs = {}
MS.onInitGameState()
MS.onStartBeginPlay(s8)
local afterFirst = spawnedCount
MS.onStartBeginPlay(s8b)
MS.onStartBeginPlay(s8) -- a doubled callback
ok(spawnedCount == afterFirst and count("a second Start marker") == 1, "two start markers: one setup, one FAIL for the other, a doubled callback silent")

-- ---------------------------------------------------------------- stock map, failed travel, a missed BeginPlay
local stock = newWorld("/Game/Maps/SmallMap.SmallMap")
place(stock, "PS_1", "/Script/Engine.PlayerStart", { 0, 0, 0 }, 0, { PlayerStartTag = str("None") })
spawnedCount = 0
load(stock, nil)
ok(spawnedCount == 0 and count("WIRE") == 0 and count("ORDER") == 0, "stock map: nothing spawned, no WIRE or ORDER")
-- (story 9: besides the signal's own line when it changes to none)
ok(count("^DEBUG") <= 1 and count("^[^DW]") - count("^MAPSETUP signal none$") == 0 and count("^MAPSETUP signal none$") <= 1, "stock map: one DEBUG line at most", table.concat(logs, " | "))
ok(MS.signal() == "none", "stock map: the signal is none", MS.signal())

logs = {}
local okNil, errNil = pcall(MS.onLoadMap, nil)
ok(okNil and #logs == 1 and logs[1]:find("no world", 1, true), "failed travel: one line, return", errNil or logs[1])
logs = {}
MS.onLoadMap(INVALID)
ok(#logs == 1, "failed travel: an invalid world is one line too")

local w9 = demoLevel("/Game/Mods/DemoMap/Maps/L_Missed.L_Missed")
load(w9, nil)
ok(count("^FAIL WIRE the start marker's BeginPlay never ran") == 1 and count("^OK WIRE GameStartService_C") == 1, "missed BeginPlay: one FAIL line, then set up after the map load")
ok(MS.signal() == "failed 1 /Game/Mods/DemoMap/Maps/L_Missed.L_Missed", "missed BeginPlay: the signal is failed 1 <world>", MS.signal())

-- the hook bodies: a throwing callback inside the registered hook stays inside it
local okH = pcall(hooks[1].fn, { get = function() error("boom") end })
ok(okH, "hooks: a failing body doesn't escape")

-- ================================================================ story 6: objectives fill, traitor mirror, client Area Name, cabin sound
NET.server, NET.standalone = true, false
local function tick(n) for _ = 1, (n or 1) do MS.tick() end end

-- ---------------------------------------------------------------- pure: text derivation, describe parsing, client area
ok(MS.taskText("DemoIntelNorth") == "Recover the classified material: Demo Intel North", "text: derived from the id as the demo", MS.taskText("DemoIntelNorth"))
ok(MS.taskText("DemoIntelNorth", "") == "Recover the classified material: Demo Intel North", "text: an empty TaskText is derived")
ok(MS.taskText("X", "Find the red folder") == "Find the red folder", "text: TaskText used when set")
ok(MS.taskText("abc_def.9") == "Recover the classified material: abc_def.9", "text: nothing to split")
do
    local d = MS.parseDescribe("manager\t1\t0\t1\tDemo North\textra\ntask\t0\t0\t1\tDemoIntelNorth\tSome text\t0\tImp text\tmore\nother\tline")
    ok(d and d.objectives == 1 and d.selected == 0 and d.rep == true and d.area == "Demo North", "describe: manager line (extra fields ignored)")
    ok(d and #d.tasks == 1 and d.tasks[1].state == true and d.tasks[1].id == "DemoIntelNorth" and d.tasks[1].text == "Some text" and d.tasks[1].tstate == false and d.tasks[1].ttext == "Imp text", "describe: task line (extra fields, other line kinds ignored)")
    local e = MS.parseDescribe("manager\t0\t0\t1\t")
    ok(e and e.objectives == 0 and #e.tasks == 0 and e.area == "", "describe: an empty manager")
    ok(MS.parseDescribe("nonsense") == nil and MS.parseDescribe(nil) == nil and MS.parseDescribe("manager\t1\t0\t1\ta\ntask\tx") == nil, "describe: malformed text refused")
    local many = { "manager\t1\t0\t1\tA" }
    for i = 1, 70 do many[#many + 1] = string.format("task\t0\t%d\t0\tid%d\tt\t0\tt", i - 1, i) end
    local m = MS.parseDescribe(table.concat(many, "\n"))
    ok(m and m.over == true and #m.tasks == 64, "describe: at most 64 tasks read", m and #m.tasks)
end
do
    local idArea = { DemoIntelNorth = "Demo North", DemoIntelSouth = "Demo South", N2 = "Demo North" }
    local function d(ids, over) local t = {} for _, id in ipairs(ids) do t[#t + 1] = { id = id } end return { tasks = t, over = over } end
    ok(MS.areaFor(d({ "DemoIntelNorth", "N2" }), idArea) == "Demo North", "client area: ids of one area")
    local _, why = MS.areaFor(d({ string.rep("x", 65) }), idArea)
    ok(why and why:find("65 characters", 1, true), "client area: an oversized id refused", why)
    _, why = MS.areaFor(d({ "../../x" }), idArea)
    ok(why and why:find("outside", 1, true), "client area: bad characters refused", why)
    _, why = MS.areaFor(d({ "Unknown" }), idArea)
    ok(why and why:find("matches no Intel marker", 1, true), "client area: an unknown id refused", why)
    _, why = MS.areaFor(d({ "DemoIntelNorth", "DemoIntelSouth" }), idArea)
    ok(why and why:find("two areas", 1, true), "client area: ids of two areas refused", why)
    _, why = MS.areaFor(d({ "DemoIntelNorth" }, true), idArea)
    ok(why and why:find("more than 64", 1, true), "client area: more than 64 tasks refused", why)
    _, why = MS.areaFor(d({}), idArea)
    ok(why == "no tasks", "client area: no tasks")
    _, why = MS.areaFor(d({ "__index" }), idArea)
    ok(why and why:find("matches no Intel marker", 1, true), "client area: a metamethod-like id is only a key", why)
end

-- ---------------------------------------------------------------- host: the fill and its readback (solo)
local wf, sf = demoLevel("/Game/Mods/DemoMap/Maps/L_Fill.L_Fill")
-- a TaskText of its own on North, a bad one (257 characters) and a non-printable one on two extra markers
objects["/Game/Mods/DemoMap/Maps/L_Fill.L_Fill:PersistentLevel.DM_Intel_North"].TaskText = str("Find the red folder")
marker(wf, "Intel", "DM_Intel_Long", { 0, 0, 0 }, 0, { AreaName = str("Demo North"), UniqueIdentifier = str("LongText"), TaskText = str(string.rep("a", 257)) })
marker(wf, "Intel", "DM_Intel_Ctl", { 0, 0, 0 }, 0, { AreaName = str("Demo South"), UniqueIdentifier = str("CtlText"), TaskText = str("bad\ttext") })
local okFill, errFill = pcall(load, wf, sf)
ok(okFill, "fill: no Lua error escapes", errFill)
ok(count("^FAIL WIRE intel marker=DM_Intel_Long: TaskText 257 characters, cap 256; skipped") == 1, "fill: an oversized TaskText is one FAIL WIRE line", table.concat(lines("^FAIL"), " | "))
ok(count("^FAIL WIRE intel marker=DM_Intel_Ctl: TaskText not printable ASCII; skipped") == 1, "fill: a non-printable TaskText is one FAIL WIRE line")
ok(count("^FAIL") == 2, "fill: only those two FAIL lines", table.concat(lines("^FAIL"), " | "))
ok(count('^OBJECTIVES "Demo North" before the fill: objectives=0 selected=0') == 1 and count('^OBJECTIVES "Demo South" before the fill: objectives=0 selected=0') == 1, "fill: selected read before the fill is logged")
ok(count('^OK OBJECTIVES "Demo North" filled by Nucleus_SetObjectives: objectives=1 tasks=1 %(DemoIntelNorth%)') == 1, "fill: North filled, the skipped marker not in it")
ok(count('^OK OBJECTIVES "Demo South" filled by Nucleus_SetObjectives: objectives=1 tasks=1 %(DemoIntelSouth%)') == 1, "fill: South filled")
ok(count('^OK OBJECTIVES "Demo North" read back: objectives=1 selected=0 replicates=true area="Demo North" tasks=%[DemoIntelNorth State=false "Find the red folder" imposter "Find the red folder" TraitorState=false%]') == 1, "fill: North read back with its own TaskText as text and imposter text")
ok(count('^OK OBJECTIVES "Demo South" read back: .*DemoIntelSouth State=false "Recover the classified material: Demo Intel South" imposter "Recover the classified material: Demo Intel South"') == 1, "fill: South read back with the derived text")
ok(count("^OK OBJECTIVES") == 4 and #MS.state().filled == 2, "fill: one fill and one readback line per area; two managers registered for the mirror")
ok(count("^OK WIRE intel BP_CM_V4_C ") == 2, "fill: the skipped markers spawn no intel")

-- ---------------------------------------------------------------- the loop: registered from the LoadMap hook (main.lua calls MS.start)
loops = {}
ok(MS.start(wf) == true and #loops == 1 and loops[1].ms == 1000, "loop: registered at 1 s", #loops)
ok(MS.start(wf) == true and #loops == 1, "loop: start again registers nothing new")
logs = {}
loops[1].fn() -- the registered body runs M.tick under pcall
ok(count("TRAITOR") == 0, "mirror: nothing changed, no TRAITOR line")
ok(count("^OK CABIN sound A at %(%-28%.12,%-1452%.65,45578%.62%): /Engine/Transient%.AudioComponent_%d+ %(helicopter%-loop1, ATT_Footstep%)") == 1
    and count("^OK CABIN sound B at %(%-28%.12,489%.37,45752%.87%): ") == 1, "cabin: two sounds at the Corrective start + the stock offsets", table.concat(logs, " | "))
ok(#sounds == 2 and sounds[1].wave.__meta.__path == "/Game/Sounds/helicopter-loop1.helicopter-loop1" and sounds[1].att.__meta.__path == "/Game/RealFootsteps/ATT_Footstep.ATT_Footstep", "cabin: the game's wave and attenuation")
ok(sounds[1].ctx.__meta.__path:find("Lobby_1", 1, true) ~= nil, "cabin: the Corrective start is the world context")
tick(5)
ok(#sounds == 2 and count("CABIN") == 2, "cabin: once per world")

-- a pickup on the host: TraitorState follows within a tick, one line per change
logs = {}
pickup("DemoIntelNorth")
tick()
ok(count('^OK TRAITOR "Demo North" task DemoIntelNorth State=true %-> TraitorState=true %(1 task%)') == 1 and count("TRAITOR") == 1, "mirror: the pickup is one OK TRAITOR line", table.concat(logs, " | "))
do local t = OBJ[MS.state().filled[2].path] or OBJ[MS.state().filled[1].path] ok(t ~= nil, "mirror: the filled managers are known") end
local calls = nativeCalls.traitor
tick(3)
ok(count("TRAITOR") == 1 and nativeCalls.traitor == calls, "mirror: no line or call once TraitorState matches")
-- a refused mirror: one FAIL line, not repeated each second
refuseTraitor = true
pickup("DemoIntelSouth")
tick(3)
refuseTraitor = false
ok(count('^FAIL TRAITOR "Demo South" task DemoIntelSouth State=true: Nucleus_SetTraitorTaskState: refused') == 1, "mirror: a refusal is one FAIL line", table.concat(lines("TRAITOR"), " | "))
-- only core's managers: a level manager with State ~= TraitorState gets no call
do
    local lm = place(wf, "ObjectiveManager_Stock", MGR_CLASS, { 0, 0, 0 })
    OBJ[lm.__meta.__path] = { tasks = { { id = "StockTask", text = "t", ttext = "", state = true, tstate = false } } }
    local before = nativeCalls.traitor
    logs = {}
    tick(2)
    ok(nativeCalls.traitor == before and count("StockTask") == 0, "mirror: a manager core didn't fill is never touched")
end
-- a manager that disappears: dropped once (no repeated lookup), one WARN line
do
    local f = MS.state().filled[1]
    kill(objects[f.path])
    logs = {}
    local before = nativeCalls.describe
    tick(3)
    ok(count("^WARN TRAITOR .*can't be read any more") == 1 and #MS.state().filled == 1, "mirror: a gone manager is dropped with one line", table.concat(logs, " | "))
    ok(nativeCalls.describe - before == 4, "mirror: the gone path is read once, then only the other (2 + 1 + 1)", nativeCalls.describe - before)
end

-- a refused fill: one FAIL line per area, the rest of the setup goes on
refuseSet = true
local wr, sr = demoLevel("/Game/Mods/DemoMap/Maps/L_Refuse.L_Refuse")
load(wr, sr)
refuseSet = false
ok(count('^FAIL OBJECTIVES "Demo North" fill refused: Nucleus_SetObjectives: refused') == 1 and count("^FAIL") == 2, "refused fill: one FAIL line per area", table.concat(lines("^FAIL"), " | "))
ok(count("^OK OBJECTIVES") == 0 and count("^OK WIRE AISpawner_C") == 1 and count("^OK WIRE BP_GeneratorGameplayNew_C") == 1, "refused fill: no OK OBJECTIVES, the rest wired")
ok(#MS.state().filled == 0, "refused fill: nothing for the mirror")

-- ---------------------------------------------------------------- cabin: no Corrective start, two, a wave that doesn't load
for _, c in ipairs({ 0, 2 }) do
    local w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_Cab" .. c .. ".L_Cab" .. c, { corrective = c })
    load(w, s)
    MS.start(w)
    logs = {}
    local before = #sounds
    tick(4)
    ok(#sounds == before and count("^FAIL CABIN sound: " .. c .. " Corrective lobby starts in the level %(need exactly 1%); no cabin sound in this world") == 1 and count("CABIN") == 1, "cabin: " .. c .. " Corrective starts is one line per world, no sound", table.concat(logs, " | "))
end
-- core story 40: a lowercase "corrective" tag is the lobby start (case-insensitive, as the game's FName ==), for the
-- arrays and the cabin sound alike
do
    local w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_CabLow.L_CabLow", { correctiveTag = "corrective" })
    load(w, s)
    ok(count("^FAIL") == 0 and count("^OK WIRE GameStartService_C at .* x 24 PlayerStarts %(1 Corrective lobby start left out%)") == 1, "lowercase corrective: the lobby start, left out of the arrays", table.concat(lines("^FAIL"), " | "))
    MS.start(w)
    logs = {}
    local before = #sounds
    tick(2)
    ok(#sounds == before + 2 and count("^OK CABIN sound A at ") == 1 and count("^FAIL CABIN") == 0, "lowercase corrective: the cabin sound plays", table.concat(logs, " | "))
end
do
    local w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_NoWave.L_NoWave")
    load(w, s)
    dropClass("helicopter-loop1") unloadable["helicopter-loop1"] = true
    logs = {}
    local before = #sounds
    tick(MS.CABIN_TRIES - 1)
    local early = count("CABIN")
    tick(5)
    unloadable["helicopter-loop1"] = nil
    ok(early == 0 and count("^FAIL CABIN sound: not resolved after 30 s %(wave /Game/Sounds/helicopter%-loop1=false") == 1 and count("CABIN") == 1 and #sounds == before, "cabin: retried for 30 s, then one FAIL line", table.concat(logs, " | "))
end

-- ---------------------------------------------------------------- client: Area Name from the replicated ids, cabin unjudged
NET.server, NET.standalone = false, false
local wc, scl = demoLevel("/Game/Mods/DemoMap/Maps/L_Client.L_Client")
load(wc, scl)
ok(MS.state().host == false and MS.start(wc) == true, "client: the loop runs on a client too")
local function clientManager(name, ids, raw)
    local m = place(wc, name, MGR_CLASS, { 0, 0, 0 })
    m["Area Name"] = FText("")
    if raw then RAW[m.__meta.__path] = raw
    elseif ids then
        local t = {}
        for _, id in ipairs(ids) do t[#t + 1] = { id = id, text = "x", ttext = "x", state = false, tstate = false } end
        OBJ[m.__meta.__path] = { tasks = t }
    end
    return m
end
soundFails = true
logs = {}
local traitorBefore = nativeCalls.traitor
local north = clientManager("ObjectiveManager_C_N", { "DemoIntelNorth" })
local south = clientManager("ObjectiveManager_C_S", nil) -- its Objectives hasn't arrived yet
tick()
soundFails = false
ok(north["Area Name"]:ToString() == "Demo North" and count('^OK AREANAME ObjectiveManager_C_N Area Name="Demo North" set locally %(replicated ""; tasks 1%)') == 1, "client: Area Name set from the local markers", table.concat(logs, " | "))
ok(south["Area Name"]:ToString() == "" and count("ObjectiveManager_C_S") == 0, "client: a manager whose Objectives hasn't arrived is left for later")
ok(count("^CABIN sound A at .*SpawnSoundAtLocation gave nil %(no audio device%?%) %(not judged on a client%)") == 1 and count("^FAIL CABIN") == 0, "client: a failed cabin sound is a plain line")
ok(count("TRAITOR") == 0 and nativeCalls.traitor == traitorBefore, "client: no traitor mirror on a client", nativeCalls.traitor - traitorBefore)
OBJ[south.__meta.__path] = { tasks = { { id = "DemoIntelSouth", text = "x", ttext = "x", state = false, tstate = false } } }
tick(3)
ok(south["Area Name"]:ToString() == "Demo South" and count("^OK AREANAME ObjectiveManager_C_S ") == 1 and count("^OK AREANAME") == 2, "client: set once it arrives, one line per manager")
do
    local before = nativeCalls.describe
    tick(3)
    ok(nativeCalls.describe == before, "client: no more reads once every local area is set")
end

-- a client goes back to the menu (a stock map) and loads the same demo world again: InitGameState runs only on the
-- server, so the stock map's LoadMap must reset the per-world state, or the second visit gets no cabin sound, no Area
-- Name, and its Start marker's BeginPlay is taken for a doubled callback
do
    local function clientLoad(world, start)
        logs = {}
        if start then MS.onStartBeginPlay(start) end
        MS.onLoadMap(world)
    end
    clientLoad(stock, nil)
    ok(MS.start(stock) == false and not MS.looping(), "client revisit: the stock map stops the loop")
    north["Area Name"] = FText("")
    south["Area Name"] = FText("")
    local s0 = #sounds
    clientLoad(wc, scl)
    ok(MS.state().started == true and MS.start(wc) == true, "client revisit: the demo world starts again")
    ok(count("second Start marker") == 0, "client revisit: the Start marker's BeginPlay isn't taken for a doubled callback", table.concat(logs, " | "))
    tick(3)
    ok(count("^OK CABIN sound A at ") == 1 and #sounds == s0 + 2, "client revisit: the cabin sound plays again", table.concat(lines("CABIN"), " | "))
    ok(count('^OK AREANAME ObjectiveManager_C_N Area Name="Demo North" set locally') == 1 and count('^OK AREANAME ObjectiveManager_C_S Area Name="Demo South" set locally') == 1,
        "client revisit: Area Name set again on both managers", table.concat(lines("AREANAME"), " | "))
end

-- a marker the host skips for its TaskText isn't counted on a client: the loop stops once the other areas are set
do
    local w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_ClientSkip.L_ClientSkip")
    marker(w, "Intel", "DM_Intel_West", { 0, 0, 0 }, 0, { AreaName = str("Demo West"), UniqueIdentifier = str("WestText"), TaskText = str(string.rep("a", 257)) })
    load(w, s)
    MS.start(w)
    wc = w
    clientManager("ObjectiveManager_C_N2", { "DemoIntelNorth" })
    clientManager("ObjectiveManager_C_S2", { "DemoIntelSouth" })
    tick(2)
    local realFind, looks = FindAllOf, 0
    FindAllOf = function(n, ...) if n == "ObjectiveManager_C" then looks = looks + 1 end return realFind(n, ...) end
    tick(3)
    FindAllOf = realFind
    ok(count("^OK AREANAME") == 2 and looks == 0, "client: an area the host skips (bad TaskText) isn't waited for", looks)
end

-- hostile replicated ids: each manager left alone, one FAIL line, no Lua error
local wh, sh = demoLevel("/Game/Mods/DemoMap/Maps/L_Hostile.L_Hostile")
load(wh, sh)
MS.start(wh)
wc = wh
local hostile = {
    { "H_Long", nil, "manager\t1\t0\t1\t\ntask\t0\t0\t0\t" .. string.rep("A", 200) .. "\tx\t0\tx", "200 characters, cap 64" },
    { "H_Chars", nil, "manager\t1\t0\t1\t\ntask\t0\t0\t0\t../../Game/x\tx\t0\tx", "characters outside" },
    { "H_Unknown", { "NoSuchIntel" }, nil, "matches no Intel marker" },
    { "H_Two", { "DemoIntelNorth", "DemoIntelSouth" }, nil, "two areas" },
}
do
    local many = { "manager\t1\t0\t1\t" }
    for i = 1, 100 do many[#many + 1] = "task\t0\t" .. (i - 1) .. "\t0\tDemoIntelNorth\tx\t0\tx" end
    hostile[#hostile + 1] = { "H_Many", nil, table.concat(many, "\n"), "more than 64 tasks" }
end
local hm = {}
logs = {}
for _, h in ipairs(hostile) do hm[h[1]] = clientManager(h[1], h[2], h[3]) end
local okH2, errH2 = pcall(tick, 3)
ok(okH2, "hostile ids: no Lua error escapes", errH2)
for _, h in ipairs(hostile) do
    ok(count("^FAIL AREANAME " .. h[1] .. ": .*" .. h[4]:gsub("%p", "%%%0") .. ".*; left alone") == 1 and hm[h[1]]["Area Name"]:ToString() == "", "hostile ids: " .. h[1] .. " left alone, one FAIL line", table.concat(lines(h[1]), " | "))
end
ok(count("^OK AREANAME") == 0, "hostile ids: nothing set")
NET.server, NET.standalone = true, false

-- ---------------------------------------------------------------- stock map: the loop stops, no line of these kinds
do
    load(stock, nil)
    local c0 = cancelled
    ok(MS.start(stock) == false and cancelled == c0 + 1 and not MS.looping(), "stock map: the loop is cancelled")
    logs = {}
    tick(3)
    ok(#logs == 0, "stock map: no OBJECTIVES, TRAITOR, AREANAME or CABIN line", table.concat(logs, " | "))
    ok(MS.start(stock) == false and cancelled == c0 + 1, "stock map: stop is idempotent")
end

-- a loop part that throws: one FAIL line per part and world
do
    local w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_Throw.L_Throw")
    load(w, s)
    MS.start(w)
    local realFind = FindAllOf
    FindAllOf = function() error("boom") end
    logs = {}
    local okT = pcall(tick, 3)
    FindAllOf = realFind
    ok(okT and count("^FAIL CABIN loop part threw: ") == 1, "loop: a throwing part is one FAIL line", table.concat(logs, " | "))
    MS.stop()
    ok(not MS.looping(), "loop: stop cancels it")
end

-- the loop follows the LoadMap's world: none (travel failed) or another world's stops it
do
    local w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_World.L_World")
    load(w, s)
    ok(MS.start(w) == true and MS.looping(), "loop: started for the world that holds the Start marker")
    local c0 = cancelled
    ok(MS.start(nil) == false and not MS.looping() and cancelled == c0 + 1, "loop: a LoadMap without a world stops it")
    ok(MS.start(stock) == false and not MS.looping(), "loop: another world stops it")
end

-- the fill natives missing (native part without them): one FAIL line per area, the rest goes on; no mirror
do
    local realSet, realTraitor = Nucleus_SetObjectives, Nucleus_SetTraitorTaskState
    Nucleus_SetObjectives = nil
    local w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_NoNative.L_NoNative")
    local okN, errN = pcall(load, w, s)
    Nucleus_SetObjectives = realSet
    ok(okN, "missing native: no Lua error escapes", errN)
    ok(count('^FAIL OBJECTIVES "Demo North": Nucleus_SetObjectives is missing %(native part%); no tasks filled') == 1 and count("^FAIL") == 2, "missing native: one FAIL OBJECTIVES line per area", table.concat(lines("^FAIL"), " | "))
    ok(count("^OK WIRE AISpawner_C") == 1 and count("^OK WIRE intel BP_CM_V4_C ") == 2 and #MS.state().filled == 0, "missing native: the rest of the setup goes on")
    -- the mirror native missing: one FAIL TRAITOR line per world, no call
    local w2, s2 = demoLevel("/Game/Mods/DemoMap/Maps/L_NoTraitor.L_NoTraitor")
    load(w2, s2)
    MS.start(w2)
    Nucleus_SetTraitorTaskState = nil
    logs = {}
    pickup("DemoIntelNorth")
    tick(3)
    Nucleus_SetTraitorTaskState = realTraitor
    ok(count("^FAIL TRAITOR Nucleus_SetTraitorTaskState is missing") == 1 and count("TRAITOR") == 1, "missing native: one FAIL TRAITOR line per world", table.concat(logs, " | "))
end

-- a readback that differs from the fill: one FAIL OBJECTIVES line, the manager still mirrored
do
    local realD = Nucleus_DescribeObjectives
    Nucleus_DescribeObjectives = function(p)
        local t = realD(p)
        -- after the fill, the imposter's TraitorState reads true (field 7 of each task line)
        if OBJ[p] then return (t:gsub("(\ntask\t[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t[^\t]*\t)0", "%11")) end
        return t
    end
    local w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_Mismatch.L_Mismatch")
    load(w, s)
    Nucleus_DescribeObjectives = realD
    ok(count('^FAIL OBJECTIVES "Demo North" read back: task 1 reads') == 1 and count('^FAIL OBJECTIVES "Demo South" read back: task 1 reads') == 1, "readback mismatch: one FAIL OBJECTIVES line per area", table.concat(lines("OBJECTIVES"), " | "))
    ok(count("^OK OBJECTIVES .* filled by") == 2 and #MS.state().filled == 2, "readback mismatch: the fill stands, the managers are mirrored")
end

-- ================================================================ story 8: the sky (LoadMap phase only)
NET.server, NET.standalone = true, false
SKY.calls = 0
local SKYLINE = "^OK WIRE Ultra_Dynamic_Sky_C at the sky marker: StartHour=10 Time of Day=1000 bReplicates=true Animate Time of Day=false Time Speed=0$"
local function skyLoad(path, opts)
    local w, s = demoLevel(path, opts)
    local before
    local okL, errL = pcall(load, w, s, { beforeLoadMap = function() before = ofClass(w, "Ultra_Dynamic_Sky_C") end })
    return w, okL, errL, before
end

-- the happy path: nothing at BeginPlay (not deferred either), one sky after the map load, its line and position check
-- (grounded by the game on a floor: hit + 90 Z, as in demo-solo)
do
    SKY.groundDz = 90
    local w, okL, errL, before = skyLoad("/Game/Mods/DemoMap/Maps/L_Sky.L_Sky")
    SKY.groundDz = 0
    ok(okL, "sky: no Lua error escapes", errL)
    ok(before == 0, "sky: nothing spawned during the Start marker's BeginPlay (class resident)", before)
    ok(count("everything spawned") == 1 and count("deferred") == 0, "sky: the BeginPlay phase neither spawns nor defers it", table.concat(lines("MAPSETUP"), " | "))
    ok(count("^FAIL") == 0, "sky: no FAIL line", table.concat(lines("^FAIL"), " | "))
    ok(ofClass(w, "Ultra_Dynamic_Sky_C") == 1, "sky: exactly one sky after the map load")
    ok(count(SKYLINE) == 1, "sky: the WIRE line", table.concat(lines("Sky"), " | "))
    ok(count("^OK POS Ultra_Dynamic_Sky_C marker=DM_Sky grounded dz=90%.000 yaw=0%.000$") == 1, "sky: the grounded position check, yaw 0 (the marker is turned 30 degrees)", table.concat(lines("POS Ultra"), " | "))
    ok(count("^OK POS Ultra_Dynamic_Sky_C .*distance=") == 0, "sky: no 0-distance check for the sky")
    ok(SKY.calls == 1, "sky: one Update Replicated Time", SKY.calls)
    local sp = MS.state().spawned["/Game/Mods/DemoMap/Maps/L_Sky.L_Sky:PersistentLevel.DM_Sky"]
    local sky = sp and objects[sp]
    ok(type(sp) == "string" and sky and sky["Time of Day"] == 1000, "sky: W.spawned keeps the sky's path; Time of Day = StartHour * 100")
    ok(sky and sky["Animate Time of Day"] == false and sky["Time Speed"] == 0.0, "sky: Time Speed and Animate Time of Day not touched")
    ok(count("^OK WIRE ") == count("^OK POS ") + 1, "sky: every OK WIRE has an OK POS (but the waypoint count line)", count("^OK WIRE ") .. "/" .. count("^OK POS "))
    -- a doubled LoadMap for the same world: still one sky, no second line
    local c0 = SKY.calls
    MS.onLoadMap(w)
    MS.onLoadMap(w)
    ok(ofClass(w, "Ultra_Dynamic_Sky_C") == 1 and count(SKYLINE) == 1 and SKY.calls == c0, "sky: a doubled LoadMap spawns no second sky")
end

-- grounding: the sky read back at the marker's Z, +90, +140 passes; +141, -61 or X off by 1 is one FAIL POS line (the
-- sky stays, its WIRE line stands, core never moves it)
for i, c in ipairs({
    { "marker Z", 0, 0, true, "0%.000" }, { "+90", 90, 0, true, "90%.000" }, { "+140", 140, 0, true, "140%.000" }, { "-60", -60, 0, true, "%-60%.000" },
    { "+141", 141, 0, false, "141%.000" }, { "-61", -61, 0, false, "%-61%.000" }, { "X off by 1", 90, 1, false, "90%.000" },
}) do
    SKY.groundDz, SKY.groundDx = c[2], c[3]
    local w, okL, errL = skyLoad("/Game/Mods/DemoMap/Maps/L_SkyGround" .. i .. ".L_SkyGround" .. i)
    SKY.groundDz, SKY.groundDx = 0, 0
    ok(okL, "grounding " .. c[1] .. ": no Lua error escapes", errL)
    local want = (c[4] and "^OK" or "^FAIL") .. " POS Ultra_Dynamic_Sky_C marker=DM_Sky grounded dz=" .. c[5] .. " yaw=0%.000"
    ok(count(want) == 1 and count("^FAIL") == (c[4] and 0 or 1), "grounding " .. c[1] .. ": " .. (c[4] and "OK POS" or "one FAIL POS line"), table.concat(lines("POS Ultra"), " | "))
    ok(ofClass(w, "Ultra_Dynamic_Sky_C") == 1 and count(SKYLINE) == 1, "grounding " .. c[1] .. ": one sky, its WIRE line")
end
-- an unreadable position or yaw: one FAIL POS line, no Lua error
do
    logs = {}
    local okG, g = pcall(MS.groundedCheck, nil, 0, { X = 0, Y = 0, Z = 0 }, "Ultra_Dynamic_Sky_C", "DM_Sky")
    local okH, h = pcall(MS.groundedCheck, { X = 0, Y = 0, Z = 90 }, nil, { X = 0, Y = 0, Z = 0 }, "Ultra_Dynamic_Sky_C", "DM_Sky")
    ok(okG and okH and g == false and h == false and count("^FAIL POS Ultra_Dynamic_Sky_C marker=DM_Sky: unreadable$") == 2, "grounding: an unreadable read-back is one FAIL POS line each", table.concat(logs, " | "))
    local okY, y = pcall(MS.groundedCheck, { X = 0, Y = 0, Z = 90 }, 30, { X = 0, Y = 0, Z = 0 }, "Ultra_Dynamic_Sky_C", "DM_Sky")
    ok(okY and y == false and count("^FAIL POS Ultra_Dynamic_Sky_C marker=DM_Sky grounded dz=90%.000 yaw=30%.000") == 1, "grounding: a turned sky fails")
end

-- the level already has a sky: one OK line, nothing spawned, no time set, whatever its Sky markers
for _, c in ipairs({ { 1, "one Sky marker" }, { 0, "no Sky marker" }, { 2, "two Sky markers" } }) do
    local w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_HasSky" .. c[1] .. ".L_HasSky" .. c[1], { skies = c[1] })
    local own = place(w, "LevelSky", SHORT.Ultra_Dynamic_Sky_C, { 0, 0, 0 }, 0, { ["Time of Day"] = 2200 })
    local calls = SKY.calls
    load(w, s)
    ok(count("^OK WIRE sky: the level already has Ultra_Dynamic_Sky_C " .. own.__meta.__path:gsub("%p", "%%%0") .. "; not spawning another$") == 1 and count("^FAIL") == 0,
        "already a sky (" .. c[2] .. "): one OK line, no FAIL", table.concat(lines("sky"), " | "))
    ok(ofClass(w, "Ultra_Dynamic_Sky_C") == 1 and own["Time of Day"] == 2200 and SKY.calls == calls, "already a sky (" .. c[2] .. "): nothing spawned, its time untouched")
end
-- a sky in another world doesn't count
do
    local other = newWorld("/Game/Maps/Other.Other")
    local stray = place(other, "OtherSky", SHORT.Ultra_Dynamic_Sky_C, { 0, 0, 0 })
    local w = skyLoad("/Game/Mods/DemoMap/Maps/L_OtherSky.L_OtherSky")
    ok(ofClass(w, "Ultra_Dynamic_Sky_C") == 1 and count(SKYLINE) == 1, "sky: another world's sky doesn't count")
    kill(stray)
end

-- bad markers: one FAIL line each, no sky, the rest of the setup goes on
local badSky = {
    { "0 markers", { skies = 0 }, "^FAIL WIRE sky: 0 Sky markers in the level %(need 1%)$" },
    { "2 markers", { skies = 2 }, "^FAIL WIRE sky: 2 Sky markers in the level %(need 1%)$" },
    { "nil hour", { hourNil = true }, "^FAIL WIRE sky marker=DM_Sky: StartHour nil isn't 0%.%.24$" },
    { "NaN hour", { startHour = 0 / 0 }, "^FAIL WIRE sky marker=DM_Sky: StartHour nan isn't 0%.%.24$" },
    { "-1", { startHour = -1 }, "^FAIL WIRE sky marker=DM_Sky: StartHour %-1 isn't 0%.%.24$" },
    { "24", { startHour = 24 }, "^FAIL WIRE sky marker=DM_Sky: StartHour 24 isn't 0%.%.24$" },
    { "1e12", { startHour = 1e12 }, "^FAIL WIRE sky marker=DM_Sky: StartHour 1e%+12 isn't 0%.%.24$" },
    { "inf", { startHour = math.huge }, "^FAIL WIRE sky marker=DM_Sky: StartHour inf isn't 0%.%.24$" },
    { "a string", { startHour = "10" }, "^FAIL WIRE sky marker=DM_Sky: StartHour 10 isn't 0%.%.24$" },
}
for i, c in ipairs(badSky) do
    local w, okL, errL = skyLoad("/Game/Mods/DemoMap/Maps/L_BadSky" .. i .. ".L_BadSky" .. i, c[2])
    ok(okL, "bad sky marker " .. c[1] .. ": no Lua error escapes", errL)
    ok(count(c[3]) == 1 and count("^FAIL") == 1, "bad sky marker " .. c[1] .. ": one FAIL line", table.concat(lines("^FAIL"), " | "))
    ok(ofClass(w, "Ultra_Dynamic_Sky_C") == 0 and count("^OK WIRE AISpawner_C") == 1 and count("^OK WIRE 8 EnemyWaypointActor_C") == 1, "bad sky marker " .. c[1] .. ": no sky, the rest wired")
end
ok(MS.checkHour(0) and MS.checkHour(23.99) and not MS.checkHour(24) and not MS.checkHour(-0.01), "sky: StartHour 0 <= h < 24")

-- bad sky: the spawn fails (spawnAt's FAIL line, no sky); the Time of Day write throws or reads back otherwise (one FAIL
-- line, the sky stays, its position still checked)
do
    SKY.failSpawn = true
    local w, okL = skyLoad("/Game/Mods/DemoMap/Maps/L_SkySpawn.L_SkySpawn")
    SKY.failSpawn = false
    ok(okL and count("^FAIL WIRE Ultra_Dynamic_Sky_C marker=DM_Sky: spawn at %(0,0,2000%) failed %(SpawnActor refused %(test%)%)$") == 1 and count("^FAIL") == 1, "bad sky: a failed spawn is one FAIL line", table.concat(lines("^FAIL"), " | "))
    ok(ofClass(w, "Ultra_Dynamic_Sky_C") == 0 and count("Ultra_Dynamic_Sky_C at the sky marker") == 0, "bad sky: a failed spawn, no sky, no OK line")

    SKY.throwWrite = true
    w, okL = skyLoad("/Game/Mods/DemoMap/Maps/L_SkyWrite.L_SkyWrite")
    SKY.throwWrite = false
    ok(okL and count("^FAIL WIRE sky marker=DM_Sky: Time of Day couldn't be set to 1000 %(Time of Day: write refused %(test%)%); the sky keeps 600$") == 1 and count("^FAIL") == 1, "bad sky: a throwing Time of Day write is one FAIL line", table.concat(lines("^FAIL"), " | "))
    ok(ofClass(w, "Ultra_Dynamic_Sky_C") == 1 and count("^OK POS Ultra_Dynamic_Sky_C marker=DM_Sky ") == 1 and count(SKYLINE) == 0, "bad sky: after a failed write the sky stays")

    SKY.readOffset = 5
    w, okL = skyLoad("/Game/Mods/DemoMap/Maps/L_SkyRead.L_SkyRead")
    SKY.readOffset = 0
    ok(okL and count("^FAIL WIRE sky marker=DM_Sky: Time of Day reads 1005 after setting 1000; the sky stays$") == 1 and count("^FAIL") == 1, "bad sky: a readback that differs is one FAIL line", table.concat(lines("^FAIL"), " | "))
    ok(ofClass(w, "Ultra_Dynamic_Sky_C") == 1, "bad sky: after a readback mismatch the sky stays")

    -- Update Replicated Time throws: one WARN line, the sky's line as usual
    local s
    w, s = demoLevel("/Game/Mods/DemoMap/Maps/L_SkyUpd.L_SkyUpd")
    local realSpawn = w.SpawnActor
    w.SpawnActor = function(self, cls, at, r)
        local a = realSpawn(self, cls, at, r)
        if cls.__meta.GetFName():ToString() == "Ultra_Dynamic_Sky_C" then a["Update Replicated Time"] = function() error("no (test)", 0) end end
        return a
    end
    load(w, s)
    ok(count("^WARN MAPSETUP sky: Update Replicated Time failed %(no %(test%)%)") == 1 and count(SKYLINE) == 1 and count("^FAIL") == 0, "bad sky: a failed Update Replicated Time is one WARN line", table.concat(lines("sky"), " | "))
end

-- the sky's class doesn't load: the existing one FAIL line
do
    dropClass("Ultra_Dynamic_Sky_C") unloadable.Ultra_Dynamic_Sky_C = true
    local w, okL = skyLoad("/Game/Mods/DemoMap/Maps/L_SkyClass.L_SkyClass")
    unloadable.Ultra_Dynamic_Sky_C = nil
    ok(okL and count("^FAIL WIRE sky: class /Game/UltraDynamicSky/Blueprints/Ultra_Dynamic_Sky%.Ultra_Dynamic_Sky_C did not load") == 1 and count("^FAIL") == 1, "sky class missing: one FAIL line", table.concat(lines("^FAIL"), " | "))
    ok(ofClass(w, "Ultra_Dynamic_Sky_C") == 0 and count("^OK WIRE AISpawner_C") == 1, "sky class missing: no sky, the rest wired")
    ok(count("MAPSETUP preload: 10 of 11 game classes; missing: Ultra_Dynamic_Sky_C") == 1, "sky class missing: the preload names it", table.concat(lines("preload"), " | "))
end

-- a client and a standalone game: no sky
for _, net in ipairs({ { false, false, "client" }, { true, true, "standalone" } }) do
    NET.server, NET.standalone = net[1], net[2]
    local w, okL = skyLoad("/Game/Mods/DemoMap/Maps/L_Net" .. net[3] .. ".L_Net" .. net[3])
    MS.onLoadMap(w)
    ok(okL and ofClass(w, "Ultra_Dynamic_Sky_C") == 0 and count("[Ss]ky") == 0, net[3] .. ": no sky spawned", table.concat(logs, " | "))
end
NET.server, NET.standalone = true, false

-- a stock map: no sky line, nothing spawned (the sky class resident)
do
    spawnedCount = 0
    load(stock, nil)
    ok(spawnedCount == 0 and ofClass(stock, "Ultra_Dynamic_Sky_C") == 0 and count("[Ss]ky") == 0 and count("WIRE") == 0, "stock map: no sky, no WIRE line")
end

-- a missed BeginPlay: the LoadMap phase spawns the sky too
do
    local w = demoLevel("/Game/Mods/DemoMap/Maps/L_SkyMissed.L_SkyMissed")
    load(w, nil)
    ok(ofClass(w, "Ultra_Dynamic_Sky_C") == 1 and count(SKYLINE) == 1, "missed BeginPlay: the sky spawned after the map load")
end

-- ================================================================ story 9: the dependent signal (<core>.map.setup)
NET.server, NET.standalone = true, false
local pubs = {}
local publishThrows = false
MS.init({ log = LOGGER, publish = function(v)
    if publishThrows then error("SetSharedVariable refused (test)", 0) end
    pubs[#pubs + 1] = v
end })
local function esc(s) return (s:gsub("%p", "%%%0")) end
local function sig(rx) return count("^MAPSETUP signal " .. rx .. "$") end

-- the grammar: none | pending <w> | done <w> | failed <n> <w> (n >= 1), the world last
local function grammar(v)
    if v == "none" then return true end
    local st, rest = tostring(v):match("^(%a+) (.+)$")
    if st == "pending" or st == "done" then return rest:find("^/") ~= nil end
    if st == "failed" then local n, w = rest:match("^(%d+) (/.+)$") return n ~= nil and tonumber(n) >= 1 and w ~= nil end
    return false
end

-- host demo: pending at the Start marker's BeginPlay, done at LoadMap; one line per change
do
    local wp = "/Game/Mods/DemoMap/Maps/L_Sig.L_Sig"
    local w, s = demoLevel(wp)
    pubs = {}
    local atGS
    load(w, s, { beforeLoadMap = function() atGS = MS.signal() end })
    ok(atGS == "pending " .. wp, "signal host: pending <world> after the Start marker's BeginPlay", atGS)
    ok(MS.signal() == "done " .. wp and pubs[#pubs] == "done " .. wp, "signal host: done <world> at LoadMap", MS.signal())
    ok(count("^FAIL") == 0 and sig("pending " .. esc(wp)) == 1 and sig("done " .. esc(wp)) == 1, "signal host: one MAPSETUP signal line per change", table.concat(lines("signal"), " | "))
    local nLines, nPubs = count("^MAPSETUP signal"), #pubs
    for _, v in ipairs(pubs) do ok(grammar(v), "signal host: published value in the grammar", v) end
    -- the doubled LoadMap: value and log unchanged
    MS.onLoadMap(w)
    MS.onLoadMap(w)
    ok(MS.signal() == "done " .. wp and #pubs == nPubs and count("^MAPSETUP signal") == nLines, "signal doubled LoadMap: value and log unchanged")
    -- a later loop failure (the cabin sound) never changes a published done
    MS.start(w)
    soundFails = true
    tick(3)
    soundFails = false
    ok(count("^FAIL CABIN") >= 1 and MS.state().fails >= 1, "signal loop: the cabin sound failed in the loop", table.concat(lines("CABIN"), " | "))
    MS.onLoadMap(w)
    ok(MS.signal() == "done " .. wp and #pubs == nPubs, "signal loop: a loop failure doesn't change done", MS.signal())
    MS.stop()
    -- InitGameState of the next world: none (once; a second InitGameState logs nothing)
    logs = {}
    MS.onInitGameState()
    MS.onInitGameState()
    ok(MS.signal() == "none" and sig("none") == 1 and pubs[#pubs] == "none", "signal: InitGameState publishes none, a repeat logs nothing")
end

-- host failures: two bad markers (an unknown Item, StartHour 25: demo-badmarkers' setup part) -> failed 2 <world>
do
    local wp = "/Game/Mods/DemoMap/Maps/L_SigBad.L_SigBad"
    local w, s = demoLevel(wp, { badItem = true, startHour = 25 })
    load(w, s)
    ok(count("^FAIL WIRE item marker=DM_Item_Flashlight: Item unknown value 7; skipped$") == 1 and count("^FAIL WIRE sky marker=DM_Sky: StartHour 25 isn't 0%.%.24$") == 1, "signal failures: the two FAIL lines", table.concat(lines("^FAIL"), " | "))
    ok(count("^FAIL") == 2 and MS.signal() == "failed 2 " .. wp and sig("failed 2 " .. esc(wp)) == 1, "signal failures: failed <n> <world>, n = the setup's FAIL lines", MS.signal())
end

-- client: done <world> at LoadMap, nothing spawned; a missed BeginPlay too; a second Start marker is failed 1
NET.server, NET.standalone = false, false
do
    local wp = "/Game/Mods/DemoMap/Maps/L_SigClient.L_SigClient"
    local w, s = demoLevel(wp)
    spawnedCount = 0
    local atGS
    load(w, s, { beforeLoadMap = function() atGS = MS.signal() end })
    ok(atGS == "pending " .. wp and MS.signal() == "done " .. wp and spawnedCount == 0, "signal client: pending, then done <world> at LoadMap, nothing spawned", tostring(atGS) .. " / " .. tostring(MS.signal()))
    local n = #pubs
    MS.onLoadMap(w)
    ok(#pubs == n and MS.signal() == "done " .. wp, "signal client: a doubled LoadMap republishes nothing")
    -- a later loop failure on a client (a hostile manager's Area Name) and another LoadMap: still done
    MS.start(w)
    wc = w
    clientManager("ObjectiveManager_C_SigHostile", { "NoSuchIntel" })
    logs = {}
    tick(2)
    MS.onLoadMap(w)
    MS.stop()
    ok(count("^FAIL AREANAME ObjectiveManager_C_SigHostile") == 1 and MS.signal() == "done " .. wp and #pubs == n, "signal client: a loop failure and a later LoadMap don't change done", MS.signal())

    local wp2 = "/Game/Mods/DemoMap/Maps/L_SigClientMissed.L_SigClientMissed"
    local w2 = demoLevel(wp2)
    MS.onLoadMap(stock) -- a client resets on the stock map's LoadMap (no InitGameState there)
    ok(MS.signal() == "none", "signal client: the stock map's LoadMap is none")
    logs = {}
    MS.onLoadMap(w2)
    ok(MS.signal() == "done " .. wp2 and sig("pending " .. esc(wp2)) == 1 and sig("done " .. esc(wp2)) == 1, "signal client: a missed BeginPlay is pending then done at LoadMap", table.concat(lines("signal"), " | "))

    local wp3 = "/Game/Mods/DemoMap/Maps/L_SigClientTwo.L_SigClientTwo"
    local w3, s3 = demoLevel(wp3)
    local s3b = marker(w3, "Start", "DM_Start_B", { 0, 0, 0 })
    MS.onLoadMap(stock)
    logs = {}
    MS.onStartBeginPlay(s3)
    MS.onStartBeginPlay(s3b)
    MS.onLoadMap(w3)
    ok(count("^FAIL WIRE start marker=DM_Start_B: a second Start marker") == 1 and MS.signal() == "failed 1 " .. wp3, "signal client: a second Start marker is failed 1 <world>", MS.signal())
end
NET.server, NET.standalone = true, false

-- stock map and failed travel: none; a failed travel keeps the per-world state
do
    local wp = "/Game/Mods/DemoMap/Maps/L_SigTravel.L_SigTravel"
    local w, s = demoLevel(wp)
    load(w, s)
    ok(MS.signal() == "done " .. wp, "signal travel: done before the failed travel")
    logs = {}
    local okN = pcall(MS.onLoadMap, nil)
    ok(okN and MS.signal() == "none" and sig("none") == 1 and MS.state().world == wp, "signal failed travel: none, the per-world state kept", tostring(MS.signal()) .. " / " .. tostring(MS.state().world))
    MS.onLoadMap(INVALID)
    ok(MS.signal() == "none" and sig("none") == 1, "signal failed travel: an invalid world is none, logged once")
    load(w, s)
    load(stock, nil)
    ok(MS.signal() == "none" and sig("none") == 1, "signal stock map: none", table.concat(lines("signal"), " | "))
    -- LoadMap of a stock world while the value is something else (no InitGameState: a client)
    load(w, s)
    logs = {}
    MS.onLoadMap(stock)
    ok(MS.signal() == "none" and sig("none") == 1, "signal stock map: the stock branch of LoadMap publishes none")
end

-- publish throws: one WARN per world, the setup completes, no error escapes
do
    local wp = "/Game/Mods/DemoMap/Maps/L_SigThrow.L_SigThrow"
    local w, s = demoLevel(wp)
    publishThrows = true
    local okT, errT = pcall(load, w, s)
    publishThrows = false
    ok(okT, "signal publish throws: no error escapes", errT)
    ok(count("^WARN MAPSETUP signal .* couldn't be published %(SetSharedVariable refused %(test%)%); the setup goes on$") == 1, "signal publish throws: one WARN line in this world", table.concat(lines("signal"), " | "))
    ok(count("^OK WIRE GameStartService_C at ") == 1 and count("^OK WIRE 8 EnemyWaypointActor_C") == 1 and count("^FAIL") == 0 and MS.signal() == "done " .. wp, "signal publish throws: the setup completes")
    ok(sig("pending " .. esc(wp)) == 1 and sig("done " .. esc(wp)) == 1, "signal publish throws: each change still logged")
end

-- no publisher (env.publish missing): the value is still kept and logged
do
    MS.init({ log = LOGGER })
    local wp = "/Game/Mods/DemoMap/Maps/L_SigNoPub.L_SigNoPub"
    local w, s = demoLevel(wp)
    local okP = pcall(load, w, s)
    ok(okP and MS.signal() == "done " .. wp and count("^WARN") == 0, "signal without a publisher: kept and logged, no WARN")
    MS.init({ log = LOGGER, publish = function(v) pubs[#pubs + 1] = v end })
end

-- ================================================================ story 9: the bad-input sweep's in-world gaps
-- Each bad value is one FAIL line, that object is skipped, the rest of the setup goes on (signal failed <n>).
local function restWired(what)
    ok(count("^OK WIRE GameStartService_C at ") == 1 and count("^OK WIRE AISpawner_C") == 1 and count("^OK WIRE 8 EnemyWaypointActor_C") == 1 and count("^OK WIRE Lever_Actor_C") == 1,
        what .. ": the rest wired", table.concat(lines("^FAIL"), " | "))
end
-- intel: an oversized (129) AreaName, an empty id, an oversized (65) id
do
    local wp = "/Game/Mods/DemoMap/Maps/L_SweepIntel.L_SweepIntel"
    local w, s = demoLevel(wp)
    marker(w, "Intel", "DM_Intel_A129", { 0, 0, 0 }, 0, { AreaName = str(string.rep("a", 129)), UniqueIdentifier = str("A129") })
    marker(w, "Intel", "DM_Intel_IdEmpty", { 0, 0, 0 }, 0, { AreaName = str("Demo North"), UniqueIdentifier = str("") })
    marker(w, "Intel", "DM_Intel_Id65", { 0, 0, 0 }, 0, { AreaName = str("Demo North"), UniqueIdentifier = str(string.rep("x", 65)) })
    local okL, errL = pcall(load, w, s)
    ok(okL, "sweep intel: no Lua error escapes", errL)
    ok(count("^FAIL WIRE intel marker=DM_Intel_A129: AreaName 129 characters, cap 128; skipped$") == 1, "sweep intel: a 129-character AreaName is one FAIL line", table.concat(lines("^FAIL"), " | "))
    ok(count("^FAIL WIRE intel marker=DM_Intel_IdEmpty: UniqueIdentifier empty; skipped$") == 1, "sweep intel: an empty id is one FAIL line")
    ok(count("^FAIL WIRE intel marker=DM_Intel_Id65: UniqueIdentifier 65 characters, cap 64; skipped$") == 1, "sweep intel: a 65-character id is one FAIL line")
    ok(count("^FAIL") == 3 and count("^OK WIRE intel BP_CM_V4_C ") == 2 and count("^OK WIRE ObjectiveManager_C ") == 2, "sweep intel: those three skipped, the good two wired")
    ok(count("^OK OBJECTIVES .* filled by Nucleus_SetObjectives: objectives=1 tasks=1 ") == 2, "sweep intel: the skipped markers aren't in any task list")
    restWired("sweep intel")
    ok(MS.signal() == "failed 3 " .. wp, "sweep intel: signal failed 3", MS.signal())
end
-- the computer: an oversized (129) LocationName, a Landing that is a marker of another kind or in another level, no
-- ReinforcementStart, one in another level. Its generator lists the lever instead, so only the computer is skipped.
local otherRS = newWorld("/Game/Maps/OtherRS.OtherRS")
local otherPS = place(otherRS, "PS_Other", "/Script/Engine.PlayerStart", { 0, 0, 0 }, 0, { PlayerStartTag = str("None") })
local otherLanding = marker(otherRS, "Landing", "DM_Landing_Other", { 0, 0, 0 })
for i, c in ipairs({
    { "LocationName 129", function(cm) cm.LocationName = str(string.rep("c", 129)) end, "LocationName 129 characters, cap 128" },
    { "Landing of another kind", function(cm, lv) cm.Landing = lv end, "Landing DM_Lever is not a Landing marker in this level" },
    { "Landing in another level", function(cm) cm.Landing = otherLanding end, "Landing DM_Landing_Other is not a Landing marker in this level" },
    { "no ReinforcementStart", function(cm) cm.ReinforcementStart = nil end, "no ReinforcementStart set" },
    { "ReinforcementStart in another level", function(cm) cm.ReinforcementStart = otherPS end, "ReinforcementStart PS_Other is not in this level" },
}) do
    local wp = "/Game/Mods/DemoMap/Maps/L_SweepComp" .. i .. ".L_SweepComp" .. i
    local w, s = demoLevel(wp)
    local lv = objects[wp .. ":PersistentLevel.DM_Lever"]
    objects[wp .. ":PersistentLevel.DM_Generator"].Equipment = arr({ lv })
    c[2](objects[wp .. ":PersistentLevel.DM_Computer"], lv)
    local okL, errL = pcall(load, w, s)
    ok(okL, "sweep computer " .. c[1] .. ": no Lua error escapes", errL)
    ok(count("^FAIL WIRE BP_Radio_C marker=DM_Computer: " .. esc(c[3]) .. "; skipped$") == 1 and count("^FAIL") == 1, "sweep computer " .. c[1] .. ": one FAIL line", table.concat(lines("^FAIL"), " | "))
    ok(ofClass(w, "BP_Radio_C") == 0 and count('^OK WIRE BP_GeneratorGameplayNew_C "Demo Generator" Equipment=1 %(Lever_Actor_C%)') == 1, "sweep computer " .. c[1] .. ": the computer skipped, the generator wired")
    restWired("sweep computer " .. c[1])
    ok(MS.signal() == "failed 1 " .. wp, "sweep computer " .. c[1] .. ": signal failed 1", MS.signal())
end
-- the generator: an oversized (129) LocationName is one FAIL line; an empty one is allowed
for _, c in ipairs({ { "129", string.rep("g", 129), false }, { "empty", "", true } }) do
    local wp = "/Game/Mods/DemoMap/Maps/L_SweepGen" .. c[1] .. ".L_SweepGen" .. c[1]
    local w, s = demoLevel(wp)
    objects[wp .. ":PersistentLevel.DM_Generator"].LocationName = str(c[2])
    local okL, errL = pcall(load, w, s)
    ok(okL, "sweep generator LocationName " .. c[1] .. ": no Lua error escapes", errL)
    if c[3] then
        ok(count("^FAIL") == 0 and count('^OK WIRE BP_GeneratorGameplayNew_C "" Equipment=1 %(BP_Radio_C%)') == 1 and MS.signal() == "done " .. wp, "sweep generator LocationName empty: allowed, wired", table.concat(lines("Generator"), " | "))
    else
        ok(count("^FAIL WIRE BP_GeneratorGameplayNew_C marker=DM_Generator: LocationName 129 characters, cap 128; skipped$") == 1 and count("^FAIL") == 1, "sweep generator LocationName 129: one FAIL line", table.concat(lines("^FAIL"), " | "))
        ok(ofClass(w, "BP_GeneratorGameplayNew_C") == 0 and count("^OK WIRE BP_Radio_C") == 1 and MS.signal() == "failed 1 " .. wp, "sweep generator LocationName 129: skipped, the rest wired")
    end
    restWired("sweep generator LocationName " .. c[1])
end

print(string.format("map_setup_test: %d passed, %d failed", pass, failN))
os.exit(failN == 0 and 0 or 1)
