-- Unit tests for the map service's host setup (lua/pkg/map/setup.lua, map service story 5), outside the game: UE4SS
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
newObj("/Script/Engine.Default__KismetSystemLibrary", "/Script/Engine.KismetSystemLibrary", {
    IsServer = function() return NET.server end,
    IsStandalone = function() return NET.standalone end,
})
local WORLDS = {}
local function newWorld(path)
    local w = newObj(path, "/Script/Engine.World")
    local seq = 0
    w.SpawnActor = function(self, cls, at, r)
        seq = seq + 1
        spawnedCount = spawnedCount + 1
        local name = cls.__meta.GetFName():ToString()
        local a = newObj(path .. ":PersistentLevel." .. name .. "_" .. seq, cls.__meta.__path)
        local loc = { X = at.X + (spawnOffset or 0), Y = at.Y, Z = at.Z }
        local rr = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
        a.__meta.K2_GetActorLocation = function() return loc end
        a.__meta.K2_GetActorRotation = function() return rr end
        a.__meta.GetWorld = function() return self end
        a.__meta.SetReplicates = function(o, v) o.bReplicates = v end
        a.bReplicates = name ~= "Lever_Actor_C"
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
    for i = 1, (opts.starts or 24) do place(w, string.format("PS_%02d", i), "/Script/Engine.PlayerStart", { i * 100, 0, 0 }, 0, { PlayerStartTag = str("None") }) end
    for i = 1, (opts.corrective or 1) do place(w, "Lobby_" .. i, "/Script/Engine.PlayerStart", { 0, 0, 45000 }, 0, { PlayerStartTag = str("Corrective") }) end
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
    return w, start
end

-- ---------------------------------------------------------------- the module
local MS = require("nucleus.map.setup")
MS.alive = isAlive
local logs = {}
MS.init({ log = {
    info = function(f, ...) logs[#logs + 1] = string.format(f, ...) end,
    warn = function(f, ...) logs[#logs + 1] = "WARN " .. string.format(f, ...) end,
    error = function(f, ...) logs[#logs + 1] = "ERROR " .. string.format(f, ...) end,
    debug = function(f, ...) logs[#logs + 1] = "DEBUG " .. string.format(f, ...) end,
} })
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
ok(count("the nuke aims at %(%-4200,0,12000%)") == 1, "solo: the nuke aim is the marker + 12000 Z")
ok(count("^OK WIRE item marker=DM_Item_Painkillers Item=0 Item_Painkillers_C at ") == 1 and count("^OK WIRE item marker=DM_Item_Flashlight Item=1 Item_Flashlight_C at ") == 1, "solo: each item marker spawns its own item")
ok(count('^OK WIRE ObjectiveManager_C ') == 2 and count('^OK WIRE intel BP_CM_V4_C ') == 2, "solo: two managers, two intel")
ok(count('^OK WIRE BP_Radio_C "Demo Computer" HelicopterLocation=%(%-1000,3500,0%) ReinformantLocation=PS_01') == 1, "solo: the computer wired")
ok(count('^OK WIRE BP_GeneratorGameplayNew_C "Demo Generator" Equipment=1 %(BP_Radio_C%)') == 1, "solo: the generator's Equipment is the radio")
ok(count('^OK WIRE Lever_Actor_C .* bReplicates=true %(spawned with false%)') == 1, "solo: the lever replicates")
ok(count('^OK WIRE AISpawner_C ') == 1 and count('^OK WIRE 8 EnemyWaypointActor_C') == 1 and count('^OK WIRE waypoint marker=') == 8, "solo: spawner and 8 waypoints")
ok(count("^OK POS ") == spawnedCount and spawnedCount == 1 + 2 + 2 + 2 + 1 + 1 + 1 + 1 + 8, "solo: a position check per spawned object", spawnedCount .. " spawned, " .. count("^OK POS "))
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
    for _, o in pairs(objects) do if isAlive(o) and o.__meta.__class == SHORT.ObjectiveManager_C then n = n + 1 ok(o["Area Name"]:ToString():find("^Demo "), "solo: Area Name set") ok(o.Objectives == nil, "solo: Objectives left empty (story 6)") end end
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
ok(count("^DEBUG") <= 1 and count("^[^DW]") == 0, "stock map: one DEBUG line at most", table.concat(logs, " | "))

logs = {}
local okNil, errNil = pcall(MS.onLoadMap, nil)
ok(okNil and #logs == 1 and logs[1]:find("no world", 1, true), "failed travel: one line, return", errNil or logs[1])
logs = {}
MS.onLoadMap(INVALID)
ok(#logs == 1, "failed travel: an invalid world is one line too")

local w9 = demoLevel("/Game/Mods/DemoMap/Maps/L_Missed.L_Missed")
load(w9, nil)
ok(count("^FAIL WIRE the start marker's BeginPlay never ran") == 1 and count("^OK WIRE GameStartService_C") == 1, "missed BeginPlay: one FAIL line, then set up after the map load")

-- the hook bodies: a throwing callback inside the registered hook stays inside it
local okH = pcall(hooks[1].fn, { get = function() error("boom") end })
ok(okH, "hooks: a failing body doesn't escape")

print(string.format("map_setup_test: %d passed, %d failed", pass, failN))
os.exit(failN == 0 and 0 or 1)
