-- Unit tests for the map service's Journal map and area flags (lua/pkg/map/journalmap.lua, map service story 7),
-- outside the game: UE4SS globals, the level's markers, the game's map widgets and classes are fake Lua tables. Moved
-- here from mods/map-spike/tests (the follow-up's layout and data test) and extended: the own-folder picture path, the
-- rectangle and location-name checks, the stock-world guard, the RUName copy, icon centring (fixed, already, other),
-- the missing picture, the game's own rectangle and the loop. The in-game proof is mods/map-spike's demo-solo and
-- demo-nopic. Run from the repo root with any standalone Lua 5.3 or 5.4:
--   lua test/unit/map_journal_test.lua   (on this workspace's machine: MiKTeX's texlua.exe)
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.5.0" } end
package.preload["nucleus.ref"] = function() return { ref = function() return 1 end, deref = function() return nil end, free = function() end } end
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
local objects = {}        -- path -> object
local INVALID = { __alive = false }
local nextAddr = 0x1000
local function fname(n) return { ToString = function() return n end } end
-- An object: plain fields and methods; strict = true makes reading a missing field throw (a marker whose settings
-- can't be read).
local function newObj(path, classFull, fields, strict)
    nextAddr = nextAddr + 0x100
    local o = fields or {}
    o.__alive, o.__path, o.__classFull = true, path, classFull
    local addr = nextAddr
    o.GetFullName = function() return (classFull:match("([^%.]+)$") or "Object") .. " " .. path end
    o.GetFName = function() return fname(path:match("([^%.:]+)$")) end
    o.GetAddress = function() return addr end
    o.GetClass = function()
        return { GetFullName = function() return "BlueprintGeneratedClass " .. classFull end, GetFName = function() return fname(classFull:match("([^%.]+)$")) end }
    end
    if strict then setmetatable(o, { __index = function(_, k) error("no such property " .. tostring(k)) end }) end
    objects[path] = o
    return o
end
local function kill(o) o.__alive = false objects[o.__path] = nil end

function StaticFindObject(path) return objects[path] or INVALID end
function FName(s) return s end
function FindAllOf(short)
    local out = {}
    for _, o in pairs(objects) do
        if o.__alive and type(o.__classFull) == "string" and o.__classFull:match("([^%.]+)$") == short then out[#out + 1] = o end
    end
    return #out > 0 and out or nil
end
local hooks = {}
function RegisterHook(path, fn) hooks[path] = hooks[path] or {} table.insert(hooks[path], fn) return #hooks[path] end
local loops, cancelled = {}, {}
function LoopInGameThreadWithDelay(ms, fn) loops[#loops + 1] = { ms = ms, fn = fn } return #loops end
function CancelDelayedAction(h) cancelled[h] = true end

-- the asset registry: assets[pkg.name] = object (loadable), unless unloadable[name]
local assets, unloadable, getAssets = {}, {}, 0
newObj("/Script/AssetRegistry.Default__AssetRegistryHelpers", "/Script/AssetRegistry.AssetRegistryHelpers", {
    GetAsset = function(_, a)
        getAssets = getAssets + 1
        if unloadable[a.AssetName] then return INVALID end
        return assets[a.PackageName .. "." .. a.AssetName] or INVALID
    end,
})
local function defAsset(pkg, name, classFull, fields)
    local o = newObj(pkg .. "." .. name, classFull, fields)
    assets[pkg .. "." .. name] = o
    return o
end
local CLS = {}
CLS.mapUI = defAsset("/Game/Graphics/Journal/MapUI", "MapUI_C", "/Script/Engine.BlueprintGeneratedClass")
CLS.mapWidget = defAsset("/Game/Graphics/Journal/MapWidget", "MapWidget_C", "/Script/Engine.BlueprintGeneratedClass")
CLS.location = defAsset("/Game/Blueprints/LevelLocationMap", "LevelLocationMap_C", "/Script/Engine.BlueprintGeneratedClass")
-- the Construct functions exist once their classes are loaded
newObj("/Game/Graphics/Journal/MapUI.MapUI_C:Construct", "/Script/CoreUObject.Function")
newObj("/Game/Graphics/Journal/MapWidget.MapWidget_C:Construct", "/Script/CoreUObject.Function")
local LOCATION_CLASS = "/Game/Blueprints/LevelLocationMap.LevelLocationMap_C"
local PIC = "/Game/Mods/DemoMap/Map/T_DemoMapPlan.T_DemoMapPlan"
local tex = defAsset("/Game/Mods/DemoMap/Map/T_DemoMapPlan", "T_DemoMapPlan", "/Script/Engine.Texture2D",
    { Blueprint_GetSizeX = function() return 1024 end, Blueprint_GetSizeY = function() return 1024 end })

-- worlds, markers, spawned actors
local spawned = 0
local function newWorld(path)
    local w
    w = newObj(path, "/Script/Engine.World", {
        SpawnActor = function(_, cls, at)
            spawned = spawned + 1
            local a = newObj(path:gsub("%..*$", "") .. "." .. path:match("([^%./]+)$") .. ":PersistentLevel." .. cls.GetFName():ToString() .. "_" .. spawned,
                cls.__path, { at = at })
            a.GetWorld = function() return w end
            return a
        end,
    })
    return w
end
local markerN = 0
local function marker(world, kind, fields, at, strict)
    markerN = markerN + 1
    local f = fields or {}
    local p = world.__path:gsub("%..*$", "") .. "." .. world.__path:match("([^%./]+)$") .. ":PersistentLevel.M_" .. kind .. "_" .. markerN
    local m = newObj(p, "/Game/Mods/Nucleus/Map/BP_Marker_" .. kind .. ".BP_Marker_" .. kind .. "_C", nil, false)
    for k, v in pairs(f) do m[k] = v end
    m.GetWorld = function() return world end
    local loc = at or { X = 0, Y = 0, Z = 0 }
    m.K2_GetActorLocation = function() return loc end
    if strict then setmetatable(m, { __index = function(_, k) error("no such property " .. tostring(k)) end }) end
    return m
end

-- ---------------------------------------------------------------- the module
local SETUP = require("nucleus.map.setup")
SETUP.alive = function(o) return type(o) == "table" and o.__alive == true end
local JM = require("nucleus.map.journalmap")
local logs = {}
JM.init({ log = {
    info = function(f, ...) logs[#logs + 1] = string.format(f, ...) end,
    warn = function(f, ...) logs[#logs + 1] = "WARN " .. string.format(f, ...) end,
    error = function(f, ...) logs[#logs + 1] = "ERROR " .. string.format(f, ...) end,
    debug = function(f, ...) logs[#logs + 1] = "DEBUG " .. string.format(f, ...) end,
} })
local function count(pat) local n = 0 for _, l in ipairs(logs) do if l:find(pat) then n = n + 1 end end return n end
local function V(x, y) return { X = x, Y = y, Z = 0 } end

-- A demo-like level: Start, Map and three Location markers.
local levelN = 0
local function level(mapFields, locations, opts)
    opts = opts or {}
    levelN = levelN + 1
    local w = newWorld(opts.path or ("/Game/Mods/DemoMap/Maps/L_Test" .. levelN .. ".L_Test" .. levelN))
    if not opts.noStart then marker(w, "Start") end
    for _, mf in ipairs(mapFields or {}) do marker(w, "Map", mf.fields, nil, mf.strict) end
    for _, l in ipairs(locations or {}) do marker(w, "Location", { LocationName = l[1] }, V(l[2] or 0, l[3] or 0)) end
    return w
end
local function goodMap() return { fields = { Picture = PIC, RectMin = V(-6200, -6200), RectMax = V(6200, 6200) } } end
local function enter(w) logs = {} JM.onLoadMap(w) end

-- fake map widgets: an icon is a child with a slot at a position and an alignment
local function icon(x, y, ax, ay, path)
    local a = { X = ax, Y = ay }
    local slot = {
        GetPosition = function() return { X = x, Y = y } end,
        GetAlignment = function() return { X = a.X, Y = a.Y } end,
        SetAlignment = function(_, v) a.X, a.Y = v.X, v.Y end,
    }
    local o = newObj(path or ("/Engine/Transient.Icon_" .. tostring(math.random(1, 1e9))), "/Script/UMG.Image", { Slot = slot })
    o.align = a
    return o
end
local function panel(children)
    return {
        __alive = true, kids = children,
        GetChildrenCount = function(self) return #self.kids end,
        GetChildAt = function(self, i) return self.kids[i + 1] end,
        SetRenderScale = function(self, s) self.scale = s end,
        SetRenderTranslation = function(self, t) self.trans = t end,
    }
end
local uiN = 0
local function mapUI(world, icons15, icons52)
    uiN = uiN + 1
    local slot = { SetPosition = function(self, p) self.pos = p end, SetSize = function(self, s) self.size = s end }
    local ui = newObj("/Engine/Transient.GameInstance:MapUI_C_" .. uiN, "/Game/Graphics/Journal/MapUI.MapUI_C", {
        Image = { Slot = slot, SetBrushFromTexture = function(self, t) self.brush = t end },
        CanvasPanel_15 = panel(icons15 or {}),
        CanvasPanel_52 = panel(icons52 or {}),
        ["Scale X"] = 1, ["Scale Y"] = 1,
    })
    ui.GetWorld = function() return world end
    return ui
end
local function runLoop(n) for _ = 1, n or 1 do for _, l in ipairs(loops) do l.fn() end end end
local function construct(what, obj)
    local fns = hooks["/Game/Graphics/Journal/" .. what .. "." .. what .. "_C:Construct"] or {}
    for _, fn in ipairs(fns) do fn({ get = function() return obj end }) end
    return #fns
end

-- ---------------------------------------------------------------- layout (moved from mods/map-spike/tests)
local st = JM.stockRect()
local L = JM.layout({ minX = st.minX, minY = st.minY, maxX = st.maxX, maxY = st.maxY })
ok(L.full and L.zoom == 1 and L.tx == 0 and L.ty == 0, "layout: the game's own rectangle: picture only, zoom 1, pan 0")
L = JM.layout({ minX = st.minX - 1e6, minY = st.minY - 1e6, maxX = st.maxX + 1e6, maxY = st.maxY + 1e6 })
ok(not L.full and L.zoom == 1 and L.w > JM.STOCK_SLOT.w and math.abs(L.x - JM.toCanvas(st.minX - 1e6, 0)) < 1e-9, "layout: larger than the game's on both axes: placed, zoom 1")
L = JM.layout({ minX = -2500, minY = -2500, maxX = 2500, maxY = 2500 })
ok(not L.full and L.clamped and L.zoom == JM.ZOOM.max, "layout: a 50 m rectangle: clamped at zoom 35", L.zoom)
L = JM.layout({ minX = -6200, minY = -6200, maxX = 6200, maxY = 6200 })
ok(not L.full and not L.clamped and math.abs(L.zoom - 25.65) < 0.01, "layout: the demo map's rectangle: zoom 25.65", L.zoom)
ok(JM.FILL == 0.92 and JM.MAX_MAPS == 4 and JM.PROJ.ox == 352 and JM.PROJ.oy == 220 and JM.PROJ.kx == 0.001704 and JM.PROJ.ky == 0.001767,
    "constants: the follow-up's projection, fill and four-map cap")
-- the layout centres the rectangle in the view
L = JM.layout({ minX = -6200, minY = -6200, maxX = 6200, maxY = 6200 })
local cx = L.zoom * ((L.x + L.w / 2) - JM.VIEW.w / 2) + JM.VIEW.w / 2 + L.tx
local cy = L.zoom * ((L.y + L.h / 2) - JM.VIEW.h / 2) + JM.VIEW.h / 2 + L.ty
ok(math.abs(cx - JM.VIEW.w / 2) < 1e-6 and math.abs(cy - JM.VIEW.h / 2) < 1e-6, "layout: the rectangle's centre lands in the view's centre")

-- ---------------------------------------------------------------- pure checks
ok(JM.mapFolder("/Game/Mods/DemoMap/Maps/L_DemoMap.L_DemoMap") == "/Game/Mods/DemoMap/", "mapFolder: the level's own folder")
ok(JM.mapFolder("/Game/Maps/SmallMap.SmallMap") == nil and JM.mapFolder(nil) == nil, "mapFolder: none outside /Game/Mods/")
local F = "/Game/Mods/DemoMap/"
local pk, nm = JM.checkPicture(PIC, F)
ok(pk == "/Game/Mods/DemoMap/Map/T_DemoMapPlan" and nm == "T_DemoMapPlan", "checkPicture: a path in the map's folder")
for _, c in ipairs({
    { "/Game/Mods/Other/Map/T.T", "another map's folder" }, { "/Game/Graphics/Journal/extra/T.T", "a game path" },
    { "/Game/Mods/DemoMapX/T.T", "a folder that only starts like the map's" }, { "/Game/Mods/DemoMap/.T", "the folder itself" },
    { "/Game/Mods/DemoMap/../Other/T.T", "a path with .." }, { "/Game/Mods/DemoMap//T.T", "a doubled slash" },
    { "/Game/Mods/DemoMap/T", "no object name" }, { "", "empty" }, { 42, "not a string" },
    { "/Game/Mods/DemoMap/" .. string.rep("a", 240) .. ".T", "over 256 characters" },
}) do
    local p, why = JM.checkPicture(c[1], F)
    ok(p == nil and type(why) == "string", "checkPicture refuses " .. c[2], why)
end
ok(JM.checkPicture(PIC, nil) == nil, "checkPicture: refused when the level has no /Game/Mods/<Map>/ folder")
ok(#("/Game/Mods/DemoMap/" .. string.rep("a", 235) .. ".T") <= 256 and JM.checkPicture("/Game/Mods/DemoMap/" .. string.rep("a", 235) .. ".T", F) ~= nil, "checkPicture: 256 characters is allowed")
local r = JM.checkRect(V(-6200, -6200), V(6200, 6200))
ok(r and r.minX == -6200 and r.maxY == 6200, "checkRect: the demo rectangle")
ok(JM.checkRect(V(0, 0), V(100, 100)) ~= nil, "checkRect: exactly 1 m is allowed")
for _, c in ipairs({
    { nil, V(1e4, 1e4), "no RectMin" }, { V(0, 0), nil, "no RectMax" }, { { Y = 0 }, V(1e4, 1e4), "a RectMin without X" },
    { V(0 / 0, 0), V(1e4, 1e4), "NaN" }, { V(0, 0), V(1e9, 1e4), "1e9" }, { V(-math.huge, 0), V(1e4, 1e4), "-inf" },
    { V(0, 0), V(99, 1e4), "under 1 m on X" }, { V(0, 0), V(1e4, 99), "under 1 m on Y" }, { V(1e4, 1e4), V(0, 0), "reversed" },
    { V("1", 0), V(1e4, 1e4), "a string coordinate" },
    { setmetatable({}, { __index = function() error("boom") end }), V(1e4, 1e4), "a vector that throws" },
}) do
    local rr, why = JM.checkRect(c[1], c[2])
    ok(rr == nil and type(why) == "string", "checkRect refuses " .. c[3], why)
end

-- ---------------------------------------------------------------- map data in a world (one FAIL line per world)
local function dataCase(what, maps, wantKey, opts)
    local w = level(maps, {}, opts)
    enter(w)
    local okC, d = pcall(JM.data)
    local n1 = count("^FAIL MAP ")
    pcall(JM.data)
    ok(okC and d == nil and n1 == 1 and count("^FAIL MAP ") == 1 and count("^FAIL MAP " .. wantKey .. " ") == 1,
        "data: " .. what .. ": nil, one FAIL MAP " .. wantKey .. " line, cached, no throw", table.concat(logs, " | "))
end
dataCase("0 Map markers", {}, "marker")
dataCase("2 Map markers", { goodMap(), goodMap() }, "marker")
dataCase("a Picture outside the map's folder", { { fields = { Picture = "/Game/Mods/Other/T.T", RectMin = V(0, 0), RectMax = V(1e4, 1e4) } } }, "picture")
dataCase("a Picture that isn't an object path", { { fields = { Picture = "not a path", RectMin = V(0, 0), RectMax = V(1e4, 1e4) } } }, "picture")
dataCase("a level outside /Game/Mods/", { goodMap() }, "picture", { path = "/Game/Maps/Custom.Custom" })
dataCase("a NaN rectangle", { { fields = { Picture = PIC, RectMin = V(0 / 0, 0), RectMax = V(1e4, 1e4) } } }, "rectangle")
dataCase("an oversized rectangle", { { fields = { Picture = PIC, RectMin = V(-2e9, 0), RectMax = V(1e4, 1e4) } } }, "rectangle")
dataCase("an under-1 m rectangle", { { fields = { Picture = PIC, RectMin = V(0, 0), RectMax = V(50, 50) } } }, "rectangle")
dataCase("a reversed rectangle", { { fields = { Picture = PIC, RectMin = V(1e4, 1e4), RectMax = V(0, 0) } } }, "rectangle")
dataCase("a Map marker whose settings throw", { { fields = {}, strict = true } }, "marker")
local wGood = level({ goodMap() }, {})
enter(wGood)
local d = JM.data()
ok(d and d.pkg == "/Game/Mods/DemoMap/Map/T_DemoMapPlan" and d.name == "T_DemoMapPlan" and d.minX == -6200 and count("^FAIL") == 0, "data: a good Map marker")

-- bad map data: the map stays stock (no picture swap, no slot, no zoom), no Lua error escapes
local wBad = level({ { fields = { Picture = PIC, RectMin = V(0 / 0, 0), RectMax = V(1e4, 1e4) } } }, { { "Area A" } })
enter(wBad)
runLoop(1)
local uiBad = mapUI(wBad)
local nh = construct("MapUI", uiBad)
ok(nh >= 1 and uiBad.Image.brush == nil and uiBad.Image.Slot.pos == nil and uiBad["Scale X"] == 1 and count("^FAIL MAP rectangle") == 1 and count("^ERROR") == 0,
    "bad map data: the map stays stock, one FAIL line", table.concat(logs, " | "))
ok(count("^MAP 1 area flag%(s%) spawned locally") == 1, "bad map data: the flags are still there")
ok(getAssets > 0, "loop: the classes come from the asset registry")

-- ---------------------------------------------------------------- location names and the RUName copy
local w5 = level({ goodMap() }, { { "North", 100, 200 }, { "" }, { string.rep("x", 129) }, { "Caf\195\169" }, { string.rep("y", 128), 5, 6 } })
spawned = 0
enter(w5)
runLoop(1)
local flags = {}
for _, o in pairs(objects) do if o.__alive and o.__classFull == LOCATION_CLASS and o.GetWorld() == w5 then flags[#flags + 1] = o end end
local good = #flags == 2
for _, f in ipairs(flags) do if f.RUName ~= f.Name then good = false end end
ok(good, "flags: one LevelLocationMap_C per good Location marker, RUName = Name", #flags)
local north
for _, f in ipairs(flags) do if f.Name == "North" then north = f end end
ok(north and north.at.X == 100 and north.at.Y == 200 and north.RUName == "North", "flags: North at its marker, RUName North")
ok(count("^FAIL MAP location marker=") == 3, "flags: one FAIL line per bad name (empty, 129 characters, non-ASCII)", count("^FAIL MAP location"))
ok(count("^MAP 2 area flag%(s%) spawned locally: \"North\" at %(100,200%)") == 1, "flags: one line naming the spawned flags", table.concat(logs, " | "))
runLoop(3)
local n2 = 0
for _, o in pairs(objects) do if o.__alive and o.__classFull == LOCATION_CLASS and o.GetWorld() == w5 then n2 = n2 + 1 end end
ok(n2 == 2 and count("^FAIL MAP location marker=") == 3, "flags: once per world (no second spawn, no repeated lines)")

-- ---------------------------------------------------------------- the whole flow on the demo map
JM.stop()
for k in pairs(loops) do loops[k] = nil end
local wDemo = level({ goodMap() }, { { "A", -1000, 3500 }, { "B", 0, 0 }, { "C", 3000, -2000 } })
enter(wDemo)
ok(#loops == 1 and loops[1].ms == 1000 and JM.running(), "demo world: one 1 s game-thread loop")
JM.onLoadMap(wDemo) -- the same world again: fresh state, still one loop
ok(#loops == 1, "demo world again: no second loop")
-- a Construct before the loop's first tick: stock this time, nothing loaded inside the hook
local before = getAssets
local ui0 = mapUI(wDemo)
construct("MapUI", ui0)
ok(getAssets == before and ui0.Image.brush == nil, "a Construct before the first tick: no hook yet or stock, no load")
runLoop(1)
local mk = StaticFindObject(JM.state().data.marker)
ok(mk.KeepPicture == tex and count("^MAP picture " .. PIC:gsub("%p", "%%%0") .. " loaded %(1024 x 1024%)") == 1, "picture: loaded from the loop, kept in KeepPicture", table.concat(logs, " | "))
ok(hooks["/Game/Graphics/Journal/MapUI.MapUI_C:Construct"] and hooks["/Game/Graphics/Journal/MapWidget.MapWidget_C:Construct"], "hooks: both Construct post-hooks registered")
ok(count("^MAP 3 area flag%(s%) spawned locally") == 1, "flags: three spawned")
-- MapUI's Construct: picture, slot, view, icons
local arrow = icon(352, 220, 0, 0)
local flagA = icon(352, 220, 0, 0)
local pre = icon(352, 220, 0.5, 0.5)
local odd = icon(352, 220, 0.3, 0.3)
local elsewhere = icon(10, 10, 0, 0)
local ui1 = mapUI(wDemo, { arrow }, { flagA, pre, odd, elsewhere })
logs = {}
before = getAssets
local realSFO = StaticFindObject
local misses = 0
StaticFindObject = function(p) local o = objects[p] if not o then misses = misses + 1 end return o or INVALID end
construct("MapUI", ui1)
StaticFindObject = realSFO
L = JM.layout(JM.state().data)
ok(ui1.Image.brush == tex, "Construct: MapUI.Image gets the map's picture")
ok(ui1.Image.Slot.pos.X == L.x and ui1.Image.Slot.size.X == L.w, "Construct: Image's slot over the rectangle")
ok(ui1["Scale X"] == L.zoom and ui1["Scale Y"] == L.zoom and ui1.Translation.X == L.tx and ui1.CanvasPanel_15.scale.X == L.zoom and ui1.CanvasPanel_15.trans.Y == L.ty, "Construct: pre-zoomed and panned")
ok(arrow.align.X == 0.5 and flagA.align.Y == 0.5, "centring: icons at the origin with (0, 0) centred")
ok(pre.align.X == 0.5 and odd.align.X == 0.3 and elsewhere.align.X == 0, "centring: already centred, another alignment, and icons elsewhere left as they are")
ok(count("^MAP 1 icon%(s%) already centred") == 1 and count("^MAP 1 icon%(s%) with another alignment") == 1, "centring: one line each for already centred and other", table.concat(logs, " | "))
ok(count("^MAP MapUI_C Construct: picture, slot .* icons centred 2, already 1, other 1") == 1, "Construct: one line", table.concat(logs, " | "))
ok(getAssets == before and misses == 0, "Construct: no asset load and no StaticFindObject miss inside the hook", misses)
-- MapWidget's Construct: the view again
ui1["Scale X"] = 1
local mw = newObj("/Engine/Transient.GameInstance:MapWidget_C_1", "/Game/Graphics/Journal/MapWidget.MapWidget_C", { MapUI = ui1 })
mw.GetWorld = function() return wDemo end
construct("MapWidget", mw)
ok(ui1["Scale X"] == L.zoom and count("^MAP MapWidget_C Construct: view zoom") == 1, "MapWidget Construct: the view again")
-- the loop: an icon added after Construct is centred, logged; the already-centred line stays one per world
local late = icon(352, 220, 0, 0)
table.insert(ui1.CanvasPanel_52.kids, late)
logs = {}
runLoop(1)
ok(late.align.X == 0.5 and count("^MAP centred 1 icon%(s%) added after Construct") == 1, "centreTick: a late icon centred and logged", table.concat(logs, " | "))
ok(count("already centred") == 0, "centreTick: 'already centred' is logged once per world only")
runLoop(1)
ok(count("^MAP centred") == 1, "centreTick: nothing new, no line")
-- a second open of the same widget is remembered once; four maps at most
local nMaps = #JM.state().mapUIs
local again = mapUI(wDemo, {}, {})
construct("MapUI", again)
construct("MapUI", again)
ok(#JM.state().mapUIs == nMaps + 1, "centreTick: the same widget opened twice is remembered once", #JM.state().mapUIs)
for _ = 1, 6 do construct("MapUI", mapUI(wDemo, {}, {})) end
ok(#JM.state().mapUIs == 4, "centreTick: four maps at most", #JM.state().mapUIs)
ok(count("^MAP MapUI_C Construct") <= 3 + 1, "Construct lines: at most three per class and world (plus the earlier one)")
-- a closed map's widget gone: dropped after one miss
for _, p in ipairs(JM.state().mapUIs) do kill(objects[p]) end
runLoop(1)
ok(#JM.state().mapUIs == 0, "centreTick: gone widgets are dropped")
-- SetAlignment that doesn't take: one FAIL line
local stuck = icon(352, 220, 0, 0)
stuck.Slot.SetAlignment = function() end
logs = {}
JM.centreIcons(mapUI(wDemo, { stuck }, {}))
JM.centreIcons(mapUI(wDemo, { stuck }, {}))
ok(count("^FAIL MAP 1 icon%(s%) couldn't be centred") == 1, "centring: SetAlignment that doesn't take is one FAIL line per world")

-- ---------------------------------------------------------------- the game's own rectangle: picture swap only
local wFull = level({ { fields = { Picture = PIC, RectMin = V(st.minX, st.minY), RectMax = V(st.maxX, st.maxY) } } }, {})
enter(wFull)
runLoop(1)
local arrowF = icon(352, 220, 0, 0)
local uiF = mapUI(wFull, { arrowF }, {})
logs = {}
construct("MapUI", uiF)
ok(uiF.Image.brush == tex and uiF.Image.Slot.pos == nil and uiF["Scale X"] == 1 and uiF.Translation == nil and uiF.CanvasPanel_15.scale == nil and arrowF.align.X == 0,
    "the game's own rectangle: picture swap only, zoom 1, pan 0, icons untouched")
ok(count("^MAP MapUI_C Construct: picture only") == 1, "the game's own rectangle: one line")

-- ---------------------------------------------------------------- missing picture
local wMiss = level({ { fields = { Picture = "/Game/Mods/DemoMap/Map/T_NoSuchPicture.T_NoSuchPicture", RectMin = V(-6200, -6200), RectMax = V(6200, 6200) } } }, { { "A" } })
enter(wMiss)
runLoop(3)
local uiM = mapUI(wMiss, { icon(352, 220, 0, 0) }, {})
construct("MapUI", uiM)
local mwM = newObj("/Engine/Transient.GameInstance:MapWidget_C_M", "/Game/Graphics/Journal/MapWidget.MapWidget_C", { MapUI = uiM })
mwM.GetWorld = function() return wMiss end
construct("MapWidget", mwM)
ok(count("^FAIL MAP picture /Game/Mods/DemoMap/Map/T_NoSuchPicture.T_NoSuchPicture didn't load") == 1 and count("^FAIL MAP") == 1, "missing picture: one FAIL MAP picture line", table.concat(logs, " | "))
ok(uiM.Image.brush == nil and uiM.Image.Slot.pos == nil and uiM["Scale X"] == 1 and uiM.CanvasPanel_15.scale == nil, "missing picture: stock picture, slot and zoom")
ok(count("^MAP 1 area flag%(s%) spawned locally") == 1 and count("^ERROR") == 0, "missing picture: flags still there, no fault")
-- a picture that's no longer in memory when the map opens: one FAIL line, stock
enter(wDemo)
runLoop(1)
kill(tex)
local uiG = mapUI(wDemo, {}, {})
construct("MapUI", uiG)
construct("MapUI", mapUI(wDemo, {}, {}))
ok(uiG.Image.brush == nil and count("^FAIL MAP picture .* is no longer in memory") == 1, "picture gone from memory: stock, one FAIL line (latched)")
tex.__alive = true objects[tex.__path] = tex

-- ---------------------------------------------------------------- stock maps
local stock = level({ goodMap() }, { { "A" } }, { noStart = true, path = "/Game/Maps/SmallMap.SmallMap" })
spawned = 0
local nLoops = #loops
enter(stock)
ok(not JM.running() and cancelled[1], "stock map: the loop is stopped (cancelled)")
runLoop(2) -- an old loop callback that still fires does nothing
ok(spawned == 0 and #logs == 0, "stock map: nothing spawned, no line", table.concat(logs, " | "))
local touched = 0
local spy = setmetatable({}, { __index = function() touched = touched + 1 error("touched") end, __newindex = function() touched = touched + 1 error("touched") end })
ok(JM.onMapUIConstruct(spy) == nil and JM.onMapWidgetConstruct(spy) == nil and touched == 0, "stock map: both Construct bodies return without touching the widget")
construct("MapUI", mapUI(stock, {}, {}))
ok(#logs == 0, "stock map: the registered hooks log nothing")
-- a widget of another world while ours is active
enter(wDemo)
local uiOther = mapUI(stock, {}, {})
ok(JM.onMapUIConstruct(uiOther) == nil and uiOther.Image.brush == nil, "a widget of another world: not touched")
-- failed travel
logs = {}
local okNil = pcall(JM.onLoadMap, nil)
ok(okNil and not JM.running() and #logs == 0, "failed travel (no world): the loop stops, no line")
JM.onLoadMap(INVALID)
ok(not JM.running(), "an invalid world: no loop")

-- ---------------------------------------------------------------- classes that don't load
unloadable["MapUI_C"], unloadable["LevelLocationMap_C"] = true, true
local wNoCls = level({ goodMap() }, { { "A" } })
enter(wNoCls)
runLoop(JM.TRIES + 5)
ok(count("^FAIL MAP the map widget classes didn't load in 30 s") == 1 and count("^FAIL MAP class /Game/Blueprints/LevelLocationMap.LevelLocationMap_C didn't load") == 1,
    "classes that don't load: one FAIL line each after 30 s", table.concat(logs, " | "))
unloadable["MapUI_C"], unloadable["LevelLocationMap_C"] = nil, nil

-- ---------------------------------------------------------------- faults: one ERROR line per part and world, nothing escapes
local wFault = level({ goodMap() }, { { "A" } })
enter(wFault)
runLoop(1)
local bad = mapUI(wFault, {}, {})
bad.Image = nil -- reading Image:SetBrushFromTexture throws inside the body
local okH = pcall(construct, "MapUI", bad)
pcall(construct, "MapUI", bad)
ok(okH and count("^ERROR MAP MapUI_C Construct failed") == 1, "a throwing hook body: caught, one ERROR line", table.concat(logs, " | "))
local okCtx = pcall(function() for _, fn in ipairs(hooks["/Game/Graphics/Journal/MapUI.MapUI_C:Construct"]) do fn({ get = function() error("ctx") end }) end end)
ok(okCtx, "a failing hook context stays inside the hook")
local realFind = FindAllOf
FindAllOf = function() error("FindAllOf broke") end
local okE = pcall(enter, level({ goodMap() }, {}))
FindAllOf = realFind
ok(not okE and JM.state().active == false, "onLoadMap with a failing FindAllOf: the error goes to core's main.lua pcall and the old world's state is gone")
local wT = level({ goodMap() }, {})
enter(wT)
FindAllOf = function() error("FindAllOf broke") end
local okL = pcall(runLoop, 2)
FindAllOf = realFind
ok(okL and count("^ERROR MAP flags failed") == 1, "a throwing loop part: caught, one ERROR line per part and world", table.concat(logs, " | "))

-- ---------------------------------------------------------------- a rectangle whose min corner is world (0, 0)
-- Image's slot then sits at the projection's origin (352, 220): the picture isn't an icon and keeps alignment (0, 0).
local wZero = level({ { fields = { Picture = PIC, RectMin = V(0, 0), RectMax = V(6200, 6200) } } }, {})
enter(wZero)
runLoop(1)
local img = icon(352, 220, 0, 0, "/Engine/Transient.GameInstance:MapUI_Zero.WidgetTree.Image")
img.SetBrushFromTexture = function(self, t) self.brush = t end
img.Slot.SetSize = function() end
img.Slot.SetPosition = function() end
local arrowZ = icon(352, 220, 0, 0)
local uiZ = mapUI(wZero, { img, arrowZ }, {})
uiZ.Image = img
logs = {}
construct("MapUI", uiZ)
ok(img.brush == tex and img.align.X == 0 and img.align.Y == 0, "min corner (0, 0): the picture (Image at the origin) keeps alignment (0, 0)", table.concat(logs, " | "))
ok(arrowZ.align.X == 0.5 and arrowZ.align.Y == 0.5 and count("icons centred 1, already 0, other 0") == 1, "min corner (0, 0): the icons are still centred", table.concat(logs, " | "))
runLoop(2)
ok(img.align.X == 0 and count("^MAP centred") == 0, "min corner (0, 0): the loop doesn't centre the picture either")

-- ---------------------------------------------------------------- the Construct function never found: one FAIL line
local fnUI = objects["/Game/Graphics/Journal/MapUI.MapUI_C:Construct"]
objects[fnUI.__path] = nil
local wNoFn = level({ goodMap() }, {})
enter(wNoFn)
runLoop(JM.TRIES + 5)
ok(count("^FAIL MAP the Construct post%-hooks couldn't be registered in 30 s") == 1 and count("^ERROR") == 0, "Construct function missing: one FAIL line after 30 s, then no retries", table.concat(logs, " | "))
objects[fnUI.__path] = fnUI

-- ---------------------------------------------------------------- a class reloaded: its new Construct is hooked again
local nHooks = #hooks[fnUI.__path]
newObj(fnUI.__path, "/Script/CoreUObject.Function") -- a new function object at a new address
local wReload = level({ goodMap() }, {})
enter(wReload)
runLoop(2)
ok(#hooks[fnUI.__path] == nHooks + 1, "class reloaded: the new Construct function is hooked once more", #hooks[fnUI.__path])
local uiR = mapUI(wReload, {}, {})
construct("MapUI", uiR)
ok(uiR.Image.brush == tex, "class reloaded: a Construct in the new world swaps the picture", table.concat(logs, " | "))
runLoop(2)
ok(#hooks[fnUI.__path] == nHooks + 1, "class reloaded: hooked once, not again every tick")

-- stop
JM.stop()
ok(not JM.running(), "stop: the loop is cancelled")

print(string.format("map_journal_test: %d passed, %d failed", pass, failN))
os.exit(failN == 0 and 0 or 1)
