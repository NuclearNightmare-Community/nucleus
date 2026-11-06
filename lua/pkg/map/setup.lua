-- The map service's host setup (map service story 5; spec-map-service-v1 map-setup.md "Order and machine").
-- When a level that holds core's Start marker (/Game/Mods/<Core>/Map/BP_Marker_Start) loads, the HOST spawns the
-- game's real classes at the level's markers and wires them, in the order the demo map proved:
--   * every world load (LoadMap post-hook): the game classes are preloaded with AssetRegistryHelpers:GetAsset and held
--     by core's weak handles (a load during the level's BeginPlay died once in the async loader);
--   * RegisterInitGameStatePostHook (after the level loads, before any BeginPlay): the hooks on the Start marker's and
--     the game state's ReceiveBeginPlay;
--   * the Start marker's BeginPlay (level actors begin play before the game state): GameStartService_C first (its 10
--     *Starts arrays from the level's PlayerStarts, the Corrective lobby start left out; the nuke aims at its location
--     + 12000 Z), then every other kind whose classes are still in memory;
--   * the LoadMap post-hook of that world, the same frame: whatever the travel's GC dropped.
-- isHost is IsServer and not IsStandalone, cached per world; a client spawns nothing here. Every spawned object gets
-- one "OK|FAIL WIRE" line and one position check against its marker (distance 0, yaw 0); a bad marker value is one
-- FAIL line and that object is skipped. No UObject is kept between calls (paths, plain values and weak handles only),
-- liveness comes from KismetSystemLibrary:IsValid, every hook body runs under pcall.
-- Story 6: right after each manager spawns, the host fills it through core's <Core>_SetObjectives (one objective, a
-- task per valid Intel marker of its area; text = TaskText, else derived from the id) and reads it back with
-- <Core>_DescribeObjectives. A 1 s game-thread loop (M.start/M.stop, registered from core's LoadMap post-hook in a level
-- with the Start marker) then mirrors each task's State into TraitorState on the host (<Core>_SetTraitorTaskState, only
-- for the managers core filled), sets Area Name on a client from the replicated task ids matched against the local
-- Intel markers (untrusted: lookup keys only), and plays the cabin sound on every machine. The Journal map, flags, the
-- sky and the dependent signal are later stories (7-9).
local BASE = (...):gsub("%.map%.setup$", "")
local V = require(BASE .. ".version")
local REF = require(BASE .. ".ref")

local M = {}
local NAME = V.name

-- ---------------------------------------------------------------- constants (tools/diff-dumps.watch.json)
function M.markerClass(kind) return "/Game/Mods/" .. NAME .. "/Map/BP_Marker_" .. kind .. ".BP_Marker_" .. kind .. "_C" end
function M.markerShort(kind) return "BP_Marker_" .. kind .. "_C" end
M.GAME = {
    service = { "/Game/Gameplay/Lobby/GameStartService", "GameStartService_C" },
    Painkillers = { "/Game/Gameplay/Items/Item_Painkillers", "Item_Painkillers_C" },
    Flashlight = { "/Game/Gameplay/Items/Item_Flashlight", "Item_Flashlight_C" },
    manager = { "/Game/Gameplay/ClassifiedMaterials/ObjectiveManager", "ObjectiveManager_C" },
    intel = { "/Game/Gameplay/ClassifiedMaterials/BP_CM_V4", "BP_CM_V4_C" },
    radio = { "/Game/Gameplay/ClassifiedMaterials/BP_Radio", "BP_Radio_C" },
    generator = { "/Game/Gameplay/Generators/BP_GeneratorGameplayNew", "BP_GeneratorGameplayNew_C" },
    lever = { "/Game/Models/lever/Lever_Actor", "Lever_Actor_C" },
    spawner = { "/Game/Gameplay/AISpawner", "AISpawner_C" },
    waypoint = { "/Game/AI/EnemyWaypointSystem/EnemyWaypointActor", "EnemyWaypointActor_C" },
}
M.GAME_ORDER = { "service", "Painkillers", "Flashlight", "manager", "intel", "radio", "generator", "lever", "spawner", "waypoint" }
-- E_MarkerItem (core's golden layout, add-only): value -> GAME key.
M.ITEM = { [0] = "Painkillers", [1] = "Flashlight" }
-- GameStartService_C's ten start arrays; all ten must be filled.
M.STARTS = { "BaseCampStarts", "ResearchCenterStarts", "AirportStarts", "SlaughterHouseStarts", "BaseCampStarts2",
    "OilRigStarts", "ShelterStarts", "UndergroundStarts", "MedbayStarts", "DrillingRigStarts" }
M.CORRECTIVE = "Corrective"
M.MIN_STARTS = 20
M.NUKE_Z = 12000
-- Caps on what a level may hold (marker values are checked before use; story 9 adds the full bad-input sweep).
M.LIMIT = { markers = 256, starts = 1024, equipment = 64, area = 128, id = 64, location = 128, text = 256, tasks = 64 }
-- Position check tolerance: the float round trip of a spawn transform.
M.EPS = 0.01

-- Story 6: an intel task's text when the marker's TaskText is empty (the demo loader's derivation).
M.TASK_PREFIX = "Recover the classified material: "
-- The 1 s loop and the cabin sound: the game's wave and attenuation at the stock spots (SmallMap's AmbientSound_57/58),
-- offsets from the Corrective PlayerStart; retried once a second for up to 30 s per world.
M.TICK_MS = 1000
M.CABIN_TRIES = 30
M.CABIN = {
    wave = { "/Game/Sounds/helicopter-loop1", "helicopter-loop1" },
    attenuation = { "/Game/RealFootsteps/ATT_Footstep", "ATT_Footstep" },
    spots = {
        { name = "A", delta = { X = -28.12253, Y = -1452.6485, Z = 578.62 } },
        { name = "B", delta = { X = -28.12253, Y = 489.3703, Z = 752.874 } },
    },
}

local KSL_CDO = "/Script/Engine.Default__KismetSystemLibrary"
local KSL_ISVALID = "/Script/Engine.KismetSystemLibrary:IsValid"
local HELPERS = "/Script/AssetRegistry.Default__AssetRegistryHelpers"
local GSL_CDO = "/Script/Engine.Default__GameplayStatics"
local GS_CLASS = "/Game/FirstPerson/Blueprints/BP_FirstPersonGameState.BP_FirstPersonGameState_C"
M.START_FN = M.markerClass("Start") .. ":ReceiveBeginPlay"
M.GS_FN = GS_CLASS .. ":ReceiveBeginPlay"

-- ---------------------------------------------------------------- pure checks (unit-tested)
local function firstLine(e) return (tostring(e):match("^[^\n]*")) end
local function quote(s) return (tostring(s):sub(1, 64):gsub("[^%w%p ]", "?")) end
M.quote = quote

-- Printable ASCII text of at most max bytes; empty allowed only with allowEmpty.
function M.checkText(s, max, allowEmpty)
    if type(s) ~= "string" then return false, "not a string (" .. type(s) .. ")" end
    if #s == 0 then if allowEmpty then return true end return false, "empty" end
    if #s > max then return false, string.format("%d characters, cap %d", #s, max) end
    if s:find("[^ -~]") then return false, "not printable ASCII" end
    return true
end
-- An intel id: 1..64 of [A-Za-z0-9_.-] (the objectives native's id set).
function M.checkId(s)
    if type(s) ~= "string" then return false, "not a string (" .. type(s) .. ")" end
    if #s == 0 then return false, "empty" end
    if #s > M.LIMIT.id then return false, string.format("%d characters, cap %d", #s, M.LIMIT.id) end
    if s:find("[^%w_%.%-]") then return false, "characters outside [A-Za-z0-9_.-]" end
    return true
end
-- The Item marker's value -> GAME key, or nil and why.
function M.itemKind(raw)
    if type(raw) ~= "number" or raw ~= raw then return nil, "not a number (" .. type(raw) .. ")" end
    local i = math.tointeger(raw)
    if not i then return nil, "not an integer (" .. tostring(raw) .. ")" end
    local k = M.ITEM[i]
    if not k then return nil, "unknown value " .. i end
    return k
end
-- PlayerStarts { { name, tag, ... } }: the ones for the *Starts arrays (sorted by name, Corrective left out), the
-- Corrective count, and one problem text or nil (fewer than 20 starts, or not exactly one Corrective).
function M.splitStarts(list)
    local starts, corrective = {}, 0
    for _, ps in ipairs(list) do
        if ps.tag == M.CORRECTIVE then corrective = corrective + 1 else starts[#starts + 1] = ps end
    end
    table.sort(starts, function(a, b) return a.name < b.name end)
    local bad = {}
    if #starts < M.MIN_STARTS then bad[#bad + 1] = string.format("%d PlayerStarts (need %d+)", #starts, M.MIN_STARTS) end
    if corrective ~= 1 then bad[#bad + 1] = string.format("%d Corrective lobby starts (need exactly 1)", corrective) end
    return starts, corrective, #bad > 0 and table.concat(bad, ", ") or nil
end
-- A generator's Equipment entries { { path, kind, world } } (kind: the marker kind of the entry's class, or nil;
-- world: whether it is in this level) against its own path and the spawned objects (marker path -> actor path).
-- Returns the actor paths, or nil and why (the first bad entry).
function M.checkEquipment(entries, selfPath, spawned)
    if #entries == 0 then return nil, "Equipment is empty" end
    if #entries > M.LIMIT.equipment then return nil, string.format("Equipment has %d entries, cap %d", #entries, M.LIMIT.equipment) end
    local out, seen = {}, {}
    for i, e in ipairs(entries) do
        if not e.path then return nil, string.format("Equipment[%d] is empty or not a live actor", i) end
        if e.path == selfPath then return nil, string.format("Equipment[%d] names the generator itself", i) end
        if not e.kind then return nil, string.format("Equipment[%d] (%s) is not one of %s's markers", i, quote(e.path), NAME) end
        if not e.world then return nil, string.format("Equipment[%d] (%s) is not in this level", i, quote(e.path)) end
        if seen[e.path] then return nil, string.format("Equipment[%d] (%s) is listed twice", i, quote(e.path)) end
        seen[e.path] = true
        local a = spawned[e.path]
        if not a then return nil, string.format("Equipment[%d] (%s marker %s) has no spawned object", i, e.kind, quote(e.path)) end
        out[#out + 1] = a
    end
    return out
end
-- An intel task's text: the marker's TaskText, or when empty "Recover the classified material: " + the id split at
-- lower->upper case ("DemoIntelNorth" -> "... Demo Intel North"), as the demo loader derives it.
function M.taskText(id, text)
    if type(text) == "string" and text ~= "" then return text end
    return M.TASK_PREFIX .. (tostring(id):gsub("(%l)(%u)", "%1 %2"))
end
-- <Core>_DescribeObjectives' text -> { objectives, selected, rep, area, tasks = { { objective, index, state, id, text,
-- tstate, ttext } }, over }, or nil and why. Extra fields and other line kinds are ignored (the format is add-only);
-- at most LIMIT.tasks task lines are read (over = true when there are more). On a client the values come from another
-- player: they are only compared and used as lookup keys.
function M.parseDescribe(s)
    if type(s) ~= "string" then return nil, "not a string (" .. type(s) .. ")" end
    local d = { tasks = {}, over = false }
    local first = true
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        if first then
            first = false
            local o, sel, rep, area = line:match("^manager\t(%-?%d+)\t(%-?%d+)\t([01])\t([^\t]*)")
            if not o then return nil, "no manager line" end
            d.objectives, d.selected, d.rep, d.area = tonumber(o), tonumber(sel), rep == "1", area
        elseif line:find("^task\t") then
            if #d.tasks >= M.LIMIT.tasks then d.over = true break end
            local o, i, st, id, tx, ts, tt = line:match("^task\t(%d+)\t(%d+)\t([01])\t([^\t]*)\t([^\t]*)\t([01])\t([^\t]*)")
            if not o then return nil, string.format("task line %d is malformed", #d.tasks + 1) end
            d.tasks[#d.tasks + 1] = { objective = tonumber(o), index = tonumber(i), state = st == "1", id = id, text = tx, tstate = ts == "1", ttext = tt }
        end
    end
    return d
end
-- The host's readback against what it filled (tasks { { id, text } }): true, or false and why.
function M.checkReadback(d, area, tasks)
    if d.objectives ~= 1 then return false, string.format("%s objectives (want 1)", tostring(d.objectives)) end
    if d.selected ~= 0 then return false, string.format("selected=%s (want 0)", tostring(d.selected)) end
    if d.area ~= area then return false, string.format("Area Name %q (want %q)", tostring(d.area), area) end
    if #d.tasks ~= #tasks or d.over then return false, string.format("%d tasks (want %d)", #d.tasks, #tasks) end
    for i, want in ipairs(tasks) do
        local t = d.tasks[i]
        if t.objective ~= 0 or t.id ~= want.id or t.text ~= want.text or t.ttext ~= want.text or t.state or t.tstate then
            return false, string.format("task %d reads %s %q imposter %q State=%s TraitorState=%s (want %s %q)", i, quote(t.id), t.text, t.ttext,
                tostring(t.state), tostring(t.tstate), want.id, want.text)
        end
    end
    return true
end
-- One line's worth of a readback.
function M.describeText(d)
    local parts = {}
    for _, t in ipairs(d.tasks) do parts[#parts + 1] = string.format("%s State=%s %q imposter %q TraitorState=%s", quote(t.id), tostring(t.state), t.text, t.ttext, tostring(t.tstate)) end
    return string.format("objectives=%s selected=%s replicates=%s area=%q tasks=[%s]", tostring(d.objectives), tostring(d.selected), tostring(d.rep), d.area, table.concat(parts, "; "))
end
-- A client's manager: the area its replicated task ids name among the local Intel markers (idArea: id -> area), or nil
-- and why. Untrusted input: every id passes checkId before it is used as a key; more than LIMIT.tasks tasks, a bad or
-- unknown id, or ids of two areas are refused.
function M.areaFor(d, idArea)
    if d.over then return nil, string.format("more than %d tasks", M.LIMIT.tasks) end
    if #d.tasks == 0 then return nil, "no tasks" end
    local area
    for i, t in ipairs(d.tasks) do
        local okI, why = M.checkId(t.id)
        if not okI then return nil, string.format("task %d's id %s (%s)", i, why, quote(t.id)) end
        local a = idArea[t.id]
        if not a then return nil, string.format("task %d's id %s matches no Intel marker here", i, t.id) end
        if area and a ~= area then return nil, string.format("its ids name two areas (%q and %q)", area, a) end
        area = a
    end
    return area
end

-- Yaw difference in degrees, normalized to [-180, 180).
function M.yawDiff(a, b)
    local d = (a - b) % 360
    if d >= 180 then d = d - 360 end
    return d
end

-- ---------------------------------------------------------------- engine helpers
local log = { info = print, warn = print, error = print, debug = function() end }
function M.init(env) if env and env.log then log = env.log end end

-- Liveness through the UFunction (never UE4SS's obj:IsValid(), which checks only the address). Tests replace it.
function M.alive(o)
    if type(o) ~= "userdata" then return false end
    local ok, r = pcall(function() return StaticFindObject(KSL_ISVALID)(StaticFindObject(KSL_CDO), o) end)
    return ok and r == true
end
local function alive(o) return M.alive(o) end
local function try(f) local ok, v = pcall(f) if ok then return v end return nil end
local function pathOf(o) local full = o:GetFullName() return full:match("^%S+%s+(.+)$") or full end
local function fname(o) return try(function() return o:GetFName():ToString() end) or "?" end
local function str(v)
    if type(v) == "string" then return v end
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and type(s) == "string" and s or nil
end
local function xyz(v) return { X = v.X, Y = v.Y, Z = v.Z } end
local function rot(r) return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end
local function vec(v) return string.format("(%.0f,%.0f,%.0f)", v.X, v.Y, v.Z) end
local function dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
local function worldOf(a) return try(function() return pathOf(a:GetWorld()) end) end

-- Per-world state: paths and plain values only. Reset in InitGameState (once per world, before any BeginPlay).
local W = {}
local function newWorld(wp) W = { world = wp, done = {}, deferred = {}, spawned = {}, filled = {}, objects = 0, fails = 0, poss = 0 } end
local function ok(fmt, ...) W.objects = (W.objects or 0) + 1 log.info("OK " .. fmt, ...) end
local function fail(fmt, ...) W.fails = (W.fails or 0) + 1 log.info("FAIL " .. fmt, ...) end
function M.state() return W end

-- isHost, cached per world (AGENTS.md "Networking"): set in the LoadMap post-hook, computed at the Start marker's
-- BeginPlay (which comes first) when the cache is for another world.
local hostCache = {}
function M.isHost(world, fresh)
    local wp = pathOf(world)
    if not fresh and hostCache.world == wp then return hostCache.value end
    local k = StaticFindObject(KSL_CDO)
    local v = k:IsServer(world) == true and k:IsStandalone(world) ~= true
    hostCache = { world = wp, value = v }
    return v
end

-- Game classes by weak handle (core's Nucleus_Ref): a handle that derefs to nil means GC dropped the class.
local classes = {}
local function loadClass(key, allowLoad)
    local h = classes[key]
    if h ~= nil then
        local c = try(function() return REF.deref(h) end)
        if alive(c) then return c end
        pcall(REF.free, h)
        classes[key] = nil
    end
    if not allowLoad then return nil end
    local p = M.GAME[key]
    local helpers = StaticFindObject(HELPERS)
    local okG, cls = pcall(function() return helpers:GetAsset({ PackageName = FName(p[1]), AssetName = FName(p[2]) }) end)
    if not okG or not alive(cls) then return nil, okG and "not found" or firstLine(cls) end
    local okR, hr = pcall(REF.ref, cls)
    if okR then classes[key] = hr else log.warn("MAPSETUP no weak handle for %s: %s", p[2], firstLine(hr)) end
    return cls
end
-- Every world load: the classes the setup spawns, so they are likely in memory at the next level's BeginPlay.
function M.preload()
    local n, miss = 0, {}
    for _, k in ipairs(M.GAME_ORDER) do
        local c, why = loadClass(k, true)
        if c then n = n + 1 else miss[#miss + 1] = M.GAME[k][2] .. " (" .. tostring(why) .. ")" end
    end
    if #miss > 0 then log.warn("MAPSETUP preload: %d of %d game classes; missing: %s", n, #M.GAME_ORDER, table.concat(miss, ", ")) end
    return n
end

-- One kind's markers in the world (by full class path; another mod's class of the same short name doesn't count),
-- sorted by name, capped.
local function markersOf(kind, wp)
    local cp = M.markerClass(kind)
    local out = {}
    for _, a in ipairs(FindAllOf(M.markerShort(kind)) or {}) do
        if alive(a) and try(function() return a:GetClass():GetFullName():find(cp, 1, true) ~= nil end) and worldOf(a) == wp then
            out[#out + 1] = a
        end
    end
    table.sort(out, function(x, y) return fname(x) < fname(y) end)
    if #out > M.LIMIT.markers then
        fail("WIRE %d %s markers in the level, cap %d; the rest are skipped", #out, kind, M.LIMIT.markers)
        for i = #out, M.LIMIT.markers + 1, -1 do out[i] = nil end
    end
    return out
end
-- The marker kind of an actor's class, when it is one of core's markers.
local function kindOf(a)
    local cp = try(function() return a:GetClass():GetFullName() end)
    if type(cp) ~= "string" then return nil end
    local k = cp:match("/Game/Mods/" .. NAME .. "/Map/BP_Marker_(%w+)%.BP_Marker_%w+_C$")
    return k
end

-- Spawns cls at the marker's own transform; nil (and one FAIL line) when it fails.
local function spawnAt(world, cls, m, what)
    local at, r = xyz(m:K2_GetActorLocation()), rot(m:K2_GetActorRotation())
    local okS, a = pcall(function() return world:SpawnActor(cls, at, r) end)
    if not okS or not alive(a) then
        fail("WIRE %s marker=%s: spawn at %s failed (%s)", what, fname(m), vec(at), okS and "no actor" or firstLine(a))
        return nil
    end
    return a, at, r
end
-- The position check: the object stands at its marker (distance 0, yaw 0).
local function posCheck(a, at, r, what, m)
    local okP, got, yaw = pcall(function() return xyz(a:K2_GetActorLocation()), a:K2_GetActorRotation().Yaw end)
    W.poss = (W.poss or 0) + 1
    if not okP then return fail("POS %s marker=%s: unreadable (%s)", what, fname(m), firstLine(got)) end
    local d, dy = dist(got, at), M.yawDiff(yaw, r.Yaw)
    local good = d <= M.EPS and math.abs(dy) <= M.EPS
    log.info("%s POS %s marker=%s distance=%.3f yaw=%.3f", good and "OK" or "FAIL", what, fname(m), d, dy)
    if not good then W.fails = (W.fails or 0) + 1 end
end
-- Sets an object array property from a Lua list; returns the resulting length.
local function setArray(o, prop, list)
    local okA, errA = pcall(function() o[prop] = list end)
    local n = try(function() return o[prop]:GetArrayNum() end)
    if n ~= #list then log.warn("MAPSETUP set %s: %s (length %s, want %d)", prop, okA and "ok" or firstLine(errA), tostring(n), #list) end
    return n
end
-- A marker's string setting (FString), or nil.
local function setting(m, prop) return str(try(function() return m[prop] end)) end

-- ---------------------------------------------------------------- objectives (story 6; core's natives)
local function native(suffix) local f = _G[NAME .. suffix] if type(f) == "function" then return f end return nil end
-- A manager read back through <Core>_DescribeObjectives: the parsed table, or nil and why.
local function describePath(path)
    local f = native("_DescribeObjectives")
    if not f then return nil, NAME .. "_DescribeObjectives is missing (native part)" end
    local okD, s = pcall(f, path)
    if not okD then return nil, firstLine(s) end
    return M.parseDescribe(s)
end
-- Host, right after a manager spawned: one objective, a task per valid Intel marker of its area (list { { id, text } }),
-- then the readback. A refusal is one FAIL line and the rest of the setup goes on.
local function fillManager(mgrPath, area, list)
    local set = native("_SetObjectives")
    if not set then return fail("OBJECTIVES %q: %s_SetObjectives is missing (native part); no tasks filled", area, NAME) end
    local d0, e0 = describePath(mgrPath)
    log.info("OBJECTIVES %q before the fill: %s", area, d0 and string.format("objectives=%s selected=%s", tostring(d0.objectives), tostring(d0.selected)) or ("unreadable (" .. tostring(e0) .. ")"))
    local args, tasks, ids = {}, {}, {}
    for _, e in ipairs(list) do
        local text = M.taskText(e.id, e.text)
        tasks[#tasks + 1] = { id = e.id, text = text }
        ids[#ids + 1] = e.id
        args[#args + 1] = e.id
        args[#args + 1] = text
    end
    local okS, n = pcall(set, mgrPath, area, table.unpack(args))
    if not okS then return fail("OBJECTIVES %q fill refused: %s", area, firstLine(n)) end
    if n ~= #tasks then return fail("OBJECTIVES %q filled by %s_SetObjectives: %s tasks (want %d)", area, NAME, tostring(n), #tasks) end
    log.info("OK OBJECTIVES %q filled by %s_SetObjectives: objectives=1 tasks=%d (%s)", area, NAME, n, table.concat(ids, ","))
    W.filled[#W.filled + 1] = { path = mgrPath, area = area, last = {} }
    local d, e = describePath(mgrPath)
    if not d then return fail("OBJECTIVES %q read back: %s", area, tostring(e)) end
    local good, why = M.checkReadback(d, area, tasks)
    if good then log.info("OK OBJECTIVES %q read back: %s", area, M.describeText(d))
    else fail("OBJECTIVES %q read back: %s; %s", area, why, M.describeText(d)) end
end

-- ---------------------------------------------------------------- the sections (host)
-- Each runs once per world when its classes are available: during the Start marker's BeginPlay only classes still in
-- memory are used (phase "beginplay"; the rest is deferred), after the map load they are loaded (phase "loadmap").
local SECTIONS = {} -- { name, keys, fn }
local KIND_SECTION = { Item = "items", Intel = "intel", Computer = "computer", Lever = "lever", EnemySpawner = "spawner", EnemyWaypoint = "waypoints", Generator = "generator" }

SECTIONS[#SECTIONS + 1] = { "service", { "service" }, function(world, cls)
    local list, over = {}, false
    for _, ps in ipairs(FindAllOf("PlayerStart") or {}) do
        if alive(ps) and worldOf(ps) == W.world then
            if #list >= M.LIMIT.starts then over = true break end
            list[#list + 1] = { name = fname(ps), tag = str(try(function() return ps.PlayerStartTag end)) or "", path = pathOf(ps) }
        end
    end
    local starts, corrective, problem = M.splitStarts(list)
    if over then problem = (problem and problem .. ", " or "") .. string.format("more than %d PlayerStarts", M.LIMIT.starts) end
    if problem then fail("WIRE PlayerStarts: %s; %d go into the *Starts arrays", problem, #starts) end
    local sm = W.startMarker and StaticFindObject(W.startMarker)
    if not alive(sm) then return fail("WIRE GameStartService_C: the start marker is gone") end
    local svc, at, r = spawnAt(world, cls.service, sm, "GameStartService_C")
    if not svc then return end
    local objs = {}
    for _, s in ipairs(starts) do local o = StaticFindObject(s.path) if alive(o) then objs[#objs + 1] = o end end
    local bad = {}
    for _, prop in ipairs(M.STARTS) do
        local n = setArray(svc, prop, objs)
        if n ~= #objs then bad[#bad + 1] = prop .. "=" .. tostring(n) end
    end
    W.service = pathOf(svc)
    W.spawned[pathOf(sm)] = W.service
    if #bad == 0 then
        ok("WIRE GameStartService_C at %s, 10 *Starts arrays x %d PlayerStarts (%d Corrective lobby start left out); the nuke aims at %s",
            vec(at), #objs, corrective, vec({ X = at.X, Y = at.Y, Z = at.Z + M.NUKE_Z }))
    else
        fail("WIRE GameStartService_C at %s: *Starts arrays not filled (%s)", vec(at), table.concat(bad, ", "))
    end
    posCheck(svc, at, r, "GameStartService_C", sm)
end }

SECTIONS[#SECTIONS + 1] = { "items", { "Painkillers", "Flashlight" }, function(world, cls)
    for _, m in ipairs(markersOf("Item", W.world)) do
        local raw = try(function() return m.Item end)
        local kind, why = M.itemKind(raw)
        if not kind then fail("WIRE item marker=%s: Item %s; skipped", fname(m), why)
        else
            local it, at, r = spawnAt(world, cls[kind], m, M.GAME[kind][2])
            if it then
                W.spawned[pathOf(m)] = pathOf(it)
                ok("WIRE item marker=%s Item=%d %s at %s replicates=%s", fname(m), math.tointeger(raw), M.GAME[kind][2], vec(at), tostring(try(function() return it.bReplicates end)))
                posCheck(it, at, r, M.GAME[kind][2], m)
            end
        end
    end
end }

SECTIONS[#SECTIONS + 1] = { "intel", { "manager", "intel" }, function(world, cls)
    local areas, order, ids = {}, {}, {}
    for _, m in ipairs(markersOf("Intel", W.world)) do
        local area, id = setting(m, "AreaName"), setting(m, "UniqueIdentifier")
        local text = setting(m, "TaskText") or "" -- empty: the text is derived from the id
        local okA, whyA = M.checkText(area, M.LIMIT.area)
        local okI, whyI = M.checkId(id)
        local okT, whyT = M.checkText(text, M.LIMIT.text, true)
        if not okA then fail("WIRE intel marker=%s: AreaName %s; skipped", fname(m), whyA)
        elseif not okI then fail("WIRE intel marker=%s: UniqueIdentifier %s; skipped", fname(m), whyI)
        elseif not okT then fail("WIRE intel marker=%s: TaskText %s; skipped", fname(m), whyT)
        elseif ids[id] then fail("WIRE intel marker=%s: UniqueIdentifier %q is already used by %s; skipped", fname(m), id, ids[id])
        else
            ids[id] = fname(m)
            if not areas[area] then areas[area] = {} order[#order + 1] = area end
            table.insert(areas[area], { m = m, id = id, text = text })
        end
    end
    for _, area in ipairs(order) do
        local list = areas[area]
        local first = list[1].m
        local mgr, at, r = spawnAt(world, cls.manager, first, "ObjectiveManager_C")
        if mgr then
            -- Area Name from Lua (an FText property); Objectives only through core's native (a Lua write to the struct
            -- array crashes the pinned UE4SS), which sets Area Name again.
            pcall(function() mgr["Area Name"] = FText(area) end)
            local got = str(try(function() return mgr["Area Name"] end))
            if got == area then ok("WIRE ObjectiveManager_C %q Area Name=%s at %s (marker=%s)", area, got, vec(at), fname(first))
            else fail("WIRE ObjectiveManager_C %q: Area Name reads %q", area, tostring(got)) end
            posCheck(mgr, at, r, "ObjectiveManager_C", first)
            local okF, errF = pcall(fillManager, pathOf(mgr), area, list)
            if not okF then fail("OBJECTIVES %q fill threw: %s", area, firstLine(errF)) end
        end
        for _, e in ipairs(list) do
            local intel, iat, ir = spawnAt(world, cls.intel, e.m, "BP_CM_V4_C")
            if intel then
                pcall(function() intel.UniqueIdentifer = e.id end)
                if mgr then pcall(function() intel.ObjectiveManager = mgr end) end
                local gotId = str(try(function() return intel.UniqueIdentifer end))
                local gotMgr = mgr ~= nil and alive(try(function() return intel.ObjectiveManager end))
                W.spawned[pathOf(e.m)] = pathOf(intel)
                if gotId == e.id and gotMgr then ok("WIRE intel BP_CM_V4_C %s in %q at %s (manager true)", e.id, area, vec(iat))
                else fail("WIRE intel BP_CM_V4_C %s in %q: UniqueIdentifer=%q manager=%s", e.id, area, tostring(gotId), tostring(gotMgr)) end
                posCheck(intel, iat, ir, "BP_CM_V4_C", e.m)
            end
        end
    end
end }

SECTIONS[#SECTIONS + 1] = { "computer", { "radio" }, function(world, cls)
    for _, cm in ipairs(markersOf("Computer", W.world)) do
        local name = setting(cm, "LocationName")
        local okN, whyN = M.checkText(name, M.LIMIT.location, true)
        local landing = try(function() return cm.Landing end)
        local start = try(function() return cm.ReinforcementStart end)
        local why
        if not okN then why = "LocationName " .. whyN
        elseif not alive(landing) then why = "no Landing set"
        elseif kindOf(landing) ~= "Landing" or worldOf(landing) ~= W.world then why = "Landing " .. quote(fname(landing)) .. " is not a Landing marker in this level"
        elseif not alive(start) then why = "no ReinforcementStart set"
        elseif worldOf(start) ~= W.world then why = "ReinforcementStart " .. quote(fname(start)) .. " is not in this level" end
        if why then fail("WIRE BP_Radio_C marker=%s: %s; skipped", fname(cm), why)
        else
            local landAt = xyz(landing:K2_GetActorLocation())
            local radio, at, r = spawnAt(world, cls.radio, cm, "BP_Radio_C")
            if radio then
                pcall(function() radio["Location Name"] = name end)
                pcall(function() radio.HelicopterLocation = landAt end)
                pcall(function() radio.ReinformantLocation = start end)
                local gotName = str(try(function() return radio["Location Name"] end))
                local gotHeli = try(function() return xyz(radio.HelicopterLocation) end)
                local gotStart = try(function() return radio.ReinformantLocation end)
                W.spawned[pathOf(cm)] = pathOf(radio)
                if gotName == name and gotHeli and dist(gotHeli, landAt) <= M.EPS and alive(gotStart) and pathOf(gotStart) == pathOf(start) then
                    ok("WIRE BP_Radio_C %q HelicopterLocation=%s ReinformantLocation=%s", name, vec(gotHeli), fname(start))
                else
                    fail("WIRE BP_Radio_C %q: Location Name=%q HelicopterLocation=%s ReinformantLocation=%s", name, tostring(gotName),
                        gotHeli and vec(gotHeli) or "?", alive(gotStart) and fname(gotStart) or "none")
                end
                posCheck(radio, at, r, "BP_Radio_C", cm)
            end
        end
    end
end }

SECTIONS[#SECTIONS + 1] = { "lever", { "lever" }, function(world, cls)
    for _, m in ipairs(markersOf("Lever", W.world)) do
        local lever, at, r = spawnAt(world, cls.lever, m, "Lever_Actor_C")
        if lever then
            -- A runtime-spawned lever must replicate, or MultiInteract can't name it to clients.
            local rep = try(function() return lever.bReplicates end)
            if rep ~= true then pcall(function() lever:SetReplicates(true) end) end
            local rep2 = try(function() return lever.bReplicates end)
            W.spawned[pathOf(m)] = pathOf(lever)
            if rep2 == true then ok("WIRE Lever_Actor_C at %s bReplicates=true (spawned with %s)", vec(at), tostring(rep))
            else fail("WIRE Lever_Actor_C at %s: bReplicates=%s", vec(at), tostring(rep2)) end
            posCheck(lever, at, r, "Lever_Actor_C", m)
        end
    end
end }

SECTIONS[#SECTIONS + 1] = { "spawner", { "spawner" }, function(world, cls)
    for _, m in ipairs(markersOf("EnemySpawner", W.world)) do
        -- Left as stock: nothing emptied or substituted (the demo's one-Psycho step stays in its driver).
        local sp, at, r = spawnAt(world, cls.spawner, m, "AISpawner_C")
        if sp then
            W.spawned[pathOf(m)] = pathOf(sp)
            ok("WIRE AISpawner_C at %s (stock)", vec(at))
            posCheck(sp, at, r, "AISpawner_C", m)
        end
    end
end }

SECTIONS[#SECTIONS + 1] = { "waypoints", { "waypoint" }, function(world, cls)
    local n = 0
    local list = markersOf("EnemyWaypoint", W.world)
    for _, m in ipairs(list) do
        local wpA, at, r = spawnAt(world, cls.waypoint, m, "EnemyWaypointActor_C")
        if wpA then
            n = n + 1
            W.spawned[pathOf(m)] = pathOf(wpA)
            ok("WIRE waypoint marker=%s EnemyWaypointActor_C at %s", fname(m), vec(at))
            posCheck(wpA, at, r, "EnemyWaypointActor_C", m)
        end
    end
    -- The game state gathers EnemyWaypointActor_C once, at the match start; the Psycho needs at least one.
    if n >= 1 then log.info("OK WIRE %d EnemyWaypointActor_C", n)
    else fail("WIRE 0 EnemyWaypointActor_C (%d EnemyWaypoint markers; the enemy needs at least one)", #list) end
end }

-- Last: its Equipment names the actors spawned from other markers. During BeginPlay it waits (returns "defer") while
-- a section it depends on is deferred.
SECTIONS[#SECTIONS + 1] = { "generator", { "generator" }, function(world, cls, phase)
    local gens = markersOf("Generator", W.world)
    local plans = {}
    for _, gm in ipairs(gens) do
        local entries = {}
        local n = try(function() return gm.Equipment:GetArrayNum() end)
        if type(n) ~= "number" then n = 0 end
        if n > M.LIMIT.equipment then
            entries = nil
            fail("WIRE BP_GeneratorGameplayNew_C marker=%s: Equipment has %d entries, cap %d; skipped", fname(gm), n, M.LIMIT.equipment)
        else
            for i = 1, n do
                local e = try(function() return gm.Equipment[i] end)
                if alive(e) then
                    local k = kindOf(e)
                    entries[#entries + 1] = { path = pathOf(e), kind = k, world = worldOf(e) == W.world }
                    if phase == "beginplay" and k and KIND_SECTION[k] and W.deferred[KIND_SECTION[k]] then return "defer" end
                else entries[#entries + 1] = {} end
            end
        end
        plans[#plans + 1] = { m = gm, entries = entries }
    end
    for _, p in ipairs(plans) do
        local gm = p.m
        if p.entries then
            local name = setting(gm, "LocationName")
            local okN, whyN = M.checkText(name, M.LIMIT.location, true)
            local eq, why = M.checkEquipment(p.entries, pathOf(gm), W.spawned)
            if not okN then fail("WIRE BP_GeneratorGameplayNew_C marker=%s: LocationName %s; skipped", fname(gm), whyN)
            elseif not eq then fail("WIRE BP_GeneratorGameplayNew_C marker=%s: %s; skipped", fname(gm), why)
            else
                local objs = {}
                for _, ap in ipairs(eq) do local o = StaticFindObject(ap) if alive(o) then objs[#objs + 1] = o end end
                if #objs ~= #eq then fail("WIRE BP_GeneratorGameplayNew_C marker=%s: %d of %d Equipment objects are gone; skipped", fname(gm), #eq - #objs, #eq)
                else
                    local gen, at, r = spawnAt(world, cls.generator, gm, "BP_GeneratorGameplayNew_C")
                    if gen then
                        pcall(function() gen["Location Name"] = name end)
                        local got = setArray(gen, "Equipment", objs)
                        W.spawned[pathOf(gm)] = pathOf(gen)
                        local gotName = str(try(function() return gen["Location Name"] end))
                        local names = {}
                        for _, o in ipairs(objs) do names[#names + 1] = try(function() return o:GetClass():GetFName():ToString() end) or "?" end
                        if got == #objs and gotName == name then
                            ok("WIRE BP_GeneratorGameplayNew_C %q Equipment=%d (%s) PoweredOn?=%s", name, got, table.concat(names, ", "), tostring(try(function() return gen["PoweredOn?"] end)))
                        else fail("WIRE BP_GeneratorGameplayNew_C %q: Equipment=%s of %d, Location Name=%q", name, tostring(got), #objs, tostring(gotName)) end
                        posCheck(gen, at, r, "BP_GeneratorGameplayNew_C", gm)
                    end
                end
            end
        end
    end
end }

local function runSections(world, phase)
    for _, s in ipairs(SECTIONS) do
        local name, keys, fn = s[1], s[2], s[3]
        if not W.done[name] then
            local cls, missing = {}, nil
            for _, k in ipairs(keys) do
                local c, why = loadClass(k, phase ~= "beginplay")
                -- The service must be there at BeginPlay: one lookup of the class itself if its handle is gone (one
                -- StaticFindObject per world, not on a hot path).
                if not c and phase == "beginplay" and k == "service" then
                    local p = M.GAME.service
                    local f = StaticFindObject(p[1] .. "." .. p[2])
                    if alive(f) then c = f end
                end
                if not c then missing = { k, why } break end
                cls[k] = c
            end
            if missing and phase == "beginplay" then
                W.deferred[name] = true
            elseif missing then
                W.done[name], W.deferred[name] = true, nil
                fail("WIRE %s: class %s.%s did not load (%s); nothing of it spawned", name, M.GAME[missing[1]][1], M.GAME[missing[1]][2], tostring(missing[2]))
            else
                W.done[name], W.deferred[name] = true, nil
                local okF, r = pcall(fn, world, cls, phase)
                if not okF then fail("WIRE %s threw: %s", name, firstLine(r))
                elseif r == "defer" then W.done[name], W.deferred[name] = nil, true end
            end
        end
    end
    local def = {}
    for k in pairs(W.deferred) do def[#def + 1] = k end
    table.sort(def)
    return def
end

-- ---------------------------------------------------------------- the 1 s loop (story 6; every machine in a level with the Start marker)
-- Host: each core-filled manager's tasks whose State differs from TraitorState get <Core>_SetTraitorTaskState (one
-- OK|FAIL TRAITOR line per change; a manager that can no longer be read is dropped with one WARN line).
local function traitorTick()
    if #W.filled == 0 then return end
    local set = native("_SetTraitorTaskState")
    if not set then
        if not W.traitorMissing then W.traitorMissing = true fail("TRAITOR %s_SetTraitorTaskState is missing (native part); an imposter's tasks stay unticked", NAME) end
        return
    end
    for i = #W.filled, 1, -1 do
        local f = W.filled[i]
        local d, e = describePath(f.path)
        if not d then
            table.remove(W.filled, i) -- the path is dropped: no repeated lookup of a gone manager
            log.warn("TRAITOR %q: the manager can't be read any more (%s); not mirrored from now on", f.area, tostring(e))
        else
            for _, t in ipairs(d.tasks) do
                if t.state ~= t.tstate and f.last[t.id] ~= t.state then
                    f.last[t.id] = t.state -- one attempt per change
                    local okS, n = pcall(set, f.path, t.id, t.state)
                    if okS and math.type(n) == "integer" and n >= 1 then
                        log.info("OK TRAITOR %q task %s State=%s -> TraitorState=%s (%d task%s)", f.area, t.id, tostring(t.state), tostring(t.state), n, n == 1 and "" or "s")
                    else
                        fail("TRAITOR %q task %s State=%s: %s", f.area, quote(t.id), tostring(t.state), okS and (NAME .. "_SetTraitorTaskState set " .. tostring(n) .. " tasks") or firstLine(n))
                    end
                end
            end
        end
    end
end

-- Client: the local Intel markers' id -> AreaName (level actors: the same on every machine), once per world.
local function localIntel()
    if W.idArea then return W.idArea, W.areaCount end
    local map, seen, n = {}, {}, 0
    for _, m in ipairs(markersOf("Intel", W.world)) do
        local area, id = setting(m, "AreaName"), setting(m, "UniqueIdentifier")
        if M.checkText(area, M.LIMIT.area) and M.checkId(id) and map[id] == nil then
            map[id] = area
            if not seen[area] then seen[area] = true n = n + 1 end
        end
    end
    W.idArea, W.areaCount = map, n
    return map, n
end
-- Client: each ObjectiveManager_C of this world whose Objectives has arrived gets its Area Name from the local markers
-- its task ids name (Area Name isn't replicated). One OK|FAIL AREANAME line per manager; a refused one is left alone.
-- Stops looking once every local area is set or LIMIT.markers managers were handled.
local function areaNameTick()
    local idArea, nAreas = localIntel()
    W.areaDone = W.areaDone or {}
    W.areaSet = W.areaSet or {}
    W.areaHandled = W.areaHandled or 0
    if nAreas == 0 or (W.areaSetCount or 0) >= nAreas or W.areaHandled >= M.LIMIT.markers then return end
    if not native("_DescribeObjectives") then
        if not W.areaMissing then W.areaMissing = true fail("AREANAME %s_DescribeObjectives is missing (native part); Area Name stays unset here", NAME) end
        return
    end
    for _, mgr in ipairs(FindAllOf(M.GAME.manager[2]) or {}) do
        if W.areaHandled >= M.LIMIT.markers then break end
        local path = alive(mgr) and worldOf(mgr) == W.world and try(function() return pathOf(mgr) end)
        if path and not W.areaDone[path] then
            local d, e = describePath(path)
            if not d then
                W.areaDone[path], W.areaHandled = true, W.areaHandled + 1
                fail("AREANAME %s: unreadable (%s); left alone", fname(mgr), tostring(e))
            elseif (d.objectives or 0) >= 1 or #d.tasks > 0 then
                W.areaDone[path], W.areaHandled = true, W.areaHandled + 1
                local area, why = M.areaFor(d, idArea)
                if not area then
                    fail("AREANAME %s: %s; left alone", fname(mgr), why)
                elseif d.area == area then
                    log.info("OK AREANAME %s Area Name=%q already (tasks %d)", fname(mgr), area, #d.tasks)
                    if not W.areaSet[area] then W.areaSet[area] = true W.areaSetCount = (W.areaSetCount or 0) + 1 end
                else
                    pcall(function() mgr["Area Name"] = FText(area) end)
                    local d2 = describePath(path)
                    if d2 and d2.area == area then
                        log.info("OK AREANAME %s Area Name=%q set locally (replicated %q; tasks %d)", fname(mgr), area, d.area, #d.tasks)
                        if not W.areaSet[area] then W.areaSet[area] = true W.areaSetCount = (W.areaSetCount or 0) + 1 end
                    else
                        fail("AREANAME %s: set %q, reads %q", fname(mgr), area, tostring(d2 and d2.area))
                    end
                end
            end
        end
    end
end

-- Every machine: the cabin sound (a local effect, no actor), once per world, retried once a second for up to
-- M.CABIN_TRIES s. A failure is a FAIL line on the host and a plain line on a client (not judged there).
local function cabinLine(fmt, ...)
    if W.host then fail("CABIN " .. fmt, ...) else log.info("CABIN " .. fmt .. " (not judged on a client)", ...) end
end
local function loadAsset(p)
    local helpers = StaticFindObject(HELPERS)
    local okG, o = pcall(function() return helpers:GetAsset({ PackageName = FName(p[1]), AssetName = FName(p[2]) }) end)
    if okG and alive(o) then return o end
    return nil
end
local function cabinTick()
    local C = W.cabin
    if not C then C = { tries = 0 } W.cabin = C end
    if C.done then return end
    C.tries = C.tries + 1
    if not C.start then
        local list = {}
        for _, ps in ipairs(FindAllOf("PlayerStart") or {}) do
            if #list >= M.LIMIT.starts then break end
            if alive(ps) and worldOf(ps) == W.world and str(try(function() return ps.PlayerStartTag end)) == M.CORRECTIVE then list[#list + 1] = pathOf(ps) end
        end
        if #list ~= 1 then
            C.done = true
            return cabinLine("sound: %d Corrective lobby starts in the level (need exactly 1); no cabin sound in this world", #list)
        end
        C.start = list[1]
    end
    local st = StaticFindObject(C.start)
    if not alive(st) then
        C.done = true -- dropped: not looked up again
        return cabinLine("sound: the Corrective lobby start %s is gone; no cabin sound in this world", quote(C.start))
    end
    local wave, att = loadAsset(M.CABIN.wave), loadAsset(M.CABIN.attenuation)
    if not (wave and att) then
        if C.tries >= M.CABIN_TRIES then
            C.done = true
            cabinLine("sound: not resolved after %d s (wave %s=%s, attenuation %s=%s); no cabin sound in this world", C.tries,
                M.CABIN.wave[1], tostring(wave ~= nil), M.CABIN.attenuation[1], tostring(att ~= nil))
        end
        return
    end
    C.done = true
    local at = xyz(st:K2_GetActorLocation())
    local gsl = StaticFindObject(GSL_CDO)
    for _, sp in ipairs(M.CABIN.spots) do
        local loc = { X = at.X + sp.delta.X, Y = at.Y + sp.delta.Y, Z = at.Z + sp.delta.Z }
        local okS, ac = pcall(function() return gsl:SpawnSoundAtLocation(st, wave, loc, { Pitch = 0, Yaw = 0, Roll = 0 }, 1.0, 1.0, 0.0, att, nil, true) end)
        local where = string.format("(%.2f,%.2f,%.2f)", loc.X, loc.Y, loc.Z)
        if okS and alive(ac) then
            log.info("OK CABIN sound %s at %s: %s (%s, %s)", sp.name, where, pathOf(ac), M.CABIN.wave[2], M.CABIN.attenuation[2])
        else
            cabinLine("sound %s at %s: SpawnSoundAtLocation gave %s (no audio device?)", sp.name, where, okS and tostring(ac) or firstLine(ac))
        end
    end
end

-- One loop tick: every part under pcall, a fault logged once per part and world.
local PARTS = {
    { "TRAITOR", function() return W.host end, traitorTick },
    { "AREANAME", function() return not W.host end, areaNameTick },
    { "CABIN", function() return true end, cabinTick },
}
function M.tick()
    if not W.started or not W.world then return end
    W.ticks = (W.ticks or 0) + 1
    for _, p in ipairs(PARTS) do
        if p[2]() then
            local okP, err = pcall(p[3])
            if not okP then
                W.tickErr = W.tickErr or {}
                if not W.tickErr[p[1]] then W.tickErr[p[1]] = true fail("%s loop part threw: %s", p[1], firstLine(err)) end
            end
        end
    end
end
-- The loop: registered from core's LoadMap post-hook (the game thread; never from an async callback) while the
-- world holds the Start marker, cancelled otherwise and on unload.
local loopHandle
function M.start()
    if not W.started then M.stop() return false end
    if loopHandle then return true end
    local okL, h = pcall(LoopInGameThreadWithDelay, M.TICK_MS, function()
        local okT, err = pcall(M.tick)
        if not okT and not W.loopErr then W.loopErr = true log.error("MAPSETUP loop tick failed: %s", firstLine(err)) end
    end)
    if okL and h ~= nil then loopHandle = h return true end
    log.error("MAPSETUP the 1 s loop could not be registered: %s", okL and ("LoopInGameThreadWithDelay returned " .. tostring(h)) or firstLine(h))
    return false
end
function M.stop()
    if loopHandle ~= nil then pcall(CancelDelayedAction, loopHandle) loopHandle = nil end
end
function M.looping() return loopHandle ~= nil end

-- ---------------------------------------------------------------- hooks
-- The Start marker's ReceiveBeginPlay (every machine; only the host spawns).
function M.onStartBeginPlay(marker)
    if not alive(marker) then return end
    local world = marker:GetWorld()
    local wp = pathOf(world)
    if W.world ~= wp then newWorld(wp) end
    if W.started then
        if pathOf(marker) == W.startMarker then return end -- the same marker again (a doubled hook callback)
        return fail("WIRE start marker=%s: a second Start marker in the level (need exactly 1); only %s sets up", fname(marker), W.startName or "?")
    end
    W.started, W.startMarker, W.startName = true, pathOf(marker), fname(marker)
    W.host = M.isHost(world, true) -- fresh: a cache from an earlier world of the same path may be another role's
    log.info("MAPSETUP start marker %s began play in %s; isHost=%s", W.startName, wp, tostring(W.host))
    if not W.host then return end
    local t0 = os.clock()
    local def = runSections(world, "beginplay")
    log.info("MAPSETUP host: BeginPlay part in %.0f ms%s", (os.clock() - t0) * 1000,
        #def > 0 and ("; deferred until the map has loaded (classes not in memory): " .. table.concat(def, ", ")) or "; everything spawned")
end

-- The game state's ReceiveBeginPlay: the ORDER line (did GameStartService_C exist first?).
function M.onGameStateBeginPlay(gs)
    if not alive(gs) then return end
    local wp = worldOf(gs)
    if W.world ~= wp or not W.started or W.orderLogged then return end
    W.orderLogged = true
    local svc = W.service and StaticFindObject(W.service)
    local done = {}
    for k in pairs(W.done) do done[#done + 1] = k end
    table.sort(done)
    log.info("ORDER game state BeginPlay: start marker began first=true GameStartService_C present=%s spawned before it: %s (isHost=%s)",
        tostring(alive(svc)), table.concat(done, ","), tostring(W.host))
    if W.host and not alive(svc) then fail("WIRE GameStartService_C was not there at the game state's BeginPlay; the countdown won't start") end
end

-- The LoadMap post-hook (world: the loaded UWorld, or nil when travel failed).
function M.onLoadMap(world)
    if not alive(world) then
        log.info("MAPSETUP LoadMap gave no world (the travel failed); nothing to set up")
        return
    end
    M.preload()
    local wp = pathOf(world)
    local host = M.isHost(world, true)
    if W.world ~= wp or not W.started then
        -- The Start marker didn't begin play in this world: a stock map (nothing to do), or the hook missed it.
        local sm = markersOf("Start", wp)
        if #sm == 0 then log.debug("MAPSETUP %s has no %s start marker; nothing to set up", wp, NAME) return end
        newWorld(wp)
        W.started, W.startMarker, W.startName, W.host = true, pathOf(sm[1]), fname(sm[1]), host
        if not host then return end
        fail("WIRE the start marker's BeginPlay never ran in %s (hook missing?); setting up now, after the game state's BeginPlay", wp)
    end
    W.host = host
    if not host then return end
    if next(W.deferred) == nil and W.loadMapDone then return end
    W.loadMapDone = true
    local t0 = os.clock()
    local def = runSections(world, "loadmap")
    log.info("MAPSETUP host: done in %.0f ms (after the map load): %d objects wired, %d position checks, %d failures%s", (os.clock() - t0) * 1000,
        W.objects or 0, W.poss or 0, W.fails or 0, #def > 0 and ("; still deferred: " .. table.concat(def, ", ")) or "")
end

-- Hooks on the marker's and the game state's BeginPlay, registered once per function (by address: a class reloaded
-- after a map change has a new function and is hooked again; the per-world state keeps a doubled callback harmless).
local hooked = {}
local function hookOnce(fnPath, cb)
    local fn = StaticFindObject(fnPath)
    if not alive(fn) then return false end
    local key = tostring(try(function() return fn:GetAddress() end))
    if hooked[fnPath] == key then return true end
    local okH, e = pcall(RegisterHook, fnPath, function(ctx)
        local okC, err = pcall(function() cb(ctx:get()) end)
        if not okC then log.error("MAPSETUP %s hook failed: %s", fnPath, firstLine(err)) end
    end)
    if okH then hooked[fnPath] = key log.debug("MAPSETUP hooked %s", fnPath)
    else log.error("MAPSETUP could not hook %s: %s", fnPath, firstLine(e)) end
    return okH
end
function M.onInitGameState()
    newWorld(nil)
    hostCache = {}
    hookOnce(M.START_FN, M.onStartBeginPlay)
    hookOnce(M.GS_FN, M.onGameStateBeginPlay)
end

-- Registers the InitGameState post-hook (once, from core's main.lua). The LoadMap post-hook is core's own.
function M.install()
    RegisterInitGameStatePostHook(function()
        local okI, err = pcall(M.onInitGameState)
        if not okI then log.error("MAPSETUP InitGameState hook failed: %s", firstLine(err)) end
    end)
end

return M
