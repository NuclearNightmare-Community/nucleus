-- The map service's Journal map and area flags (map service story 7; spec-map-service-v1 CAP-9, map-setup.md "Order
-- and machine"), ported from the Journal map follow-up (mods/map-spike map_runtime.lua, merged f817f60). Every
-- machine, in a level that holds core's Start marker (/Game/Mods/<Core>/Map/BP_Marker_Start), reading core's Map and
-- Location markers:
--   * a game-thread loop (LoopInGameThreadWithDelay, 1 s), started from core's LoadMap post-hook (onLoadMap) and
--     stopped on any other world and on unload: one local LevelLocationMap_C per Location marker (the class doesn't
--     replicate; MapUI_C collects flags only at its Construct), the map's picture loaded with AssetRegistryHelpers'
--     GetAsset and kept in the Map marker's KeepPicture (or GC drops it during a long lobby), and the MapUI_C and
--     MapWidget_C Construct post-hooks registered once their classes load;
--   * in those hooks: MapUI.Image gets the map's picture. Unless the picture's rectangle is the game's own, Image's
--     canvas slot is placed over the rectangle in the game's fixed projection, the map is pre-zoomed and panned to it
--     (MapUI's Scale X/Y and Translation, CanvasPanel_15's render transform) and the icons the game still anchors by
--     their top-left corner (alignment (0, 0)) are re-centred;
--   * once a second: icons added after Construct on the maps opened in this world are re-centred.
-- Never inside a Construct hook: an asset load ("Loading is stuck", fatal in the follow-up) or a StaticFindObject miss
-- beyond the one picture lookup, latched per world. Marker values are checked before use; each problem is one
-- "FAIL MAP ..." line per world and that part stays stock. Stock maps get no loop, nothing spawned, and the hook bodies
-- return at once. No UObject is kept between calls (paths and plain values only), liveness comes from
-- KismetSystemLibrary:IsValid, every hook body and loop part runs under pcall (a fault: one ERROR line per part and
-- world). Game classes and members used: tools/diff-dumps.watch.json ("Nucleus map service story 7").
local BASE = (...):gsub("%.map%.journalmap$", "")
local V = require(BASE .. ".version")
local SETUP = require(BASE .. ".map.setup")

local M = {}
local NAME = V.name

-- ---------------------------------------------------------------- constants (manual checks after each game patch)
-- The game's map projection, inline in MapUI_C's Blueprint code (decompiled V8.1.5): every icon is added to
-- CanvasPanel_52 at SetPosition(352, 220) and moved by SetRenderTranslation(X * 0.001704, Y * 0.001767), world X to
-- the right and world Y down.
M.PROJ = { ox = 352, oy = 220, kx = 0.001704, ky = 0.001767 }
-- MapUI_C's widget tree (V8.1.5): the picture Image's stock canvas slot (CanvasPanelSlot_6 in CanvasPanel_15, the root,
-- whose child CanvasPanel_52 fills it, so both share one origin); the map view (MapWidget's SizeBox NN_FieldMapPlane,
-- 736 x 611, which MapUI and its root fill; the root's render pivot is its centre); UpdateMapZoom's clamp 1..35.
M.STOCK_SLOT = { x = 2.333332, y = 0.9999962, w = 733.6667, h = 610 }
M.VIEW = { w = 736, h = 611 }
M.ZOOM = { min = 1, max = 35 }
M.FILL = 0.92 -- the share of the view the pre-zoomed rectangle fills on its tighter axis
M.MAX_MAPS = 4 -- the maps opened in a world whose late icons the loop re-centres
M.CENTRE = { X = 0.5, Y = 0.5 }

M.CLASS = {
    mapUI = { "/Game/Graphics/Journal/MapUI", "MapUI_C" },
    mapWidget = { "/Game/Graphics/Journal/MapWidget", "MapWidget_C" },
    location = { "/Game/Blueprints/LevelLocationMap", "LevelLocationMap_C" },
}
M.KIND = { start = "Start", map = "Map", location = "Location" }
M.LIMIT = { picture = 256, location = SETUP.LIMIT.location, coord = 1e9, minSize = 100, markers = SETUP.LIMIT.markers }
M.TICK_MS = 1000
M.TRIES = 30 -- loop ticks (seconds) a class may take to load before one FAIL line
M.LOG_CONSTRUCT = 3 -- Construct lines per hooked class and world

local HELPERS = "/Script/AssetRegistry.Default__AssetRegistryHelpers"

-- ---------------------------------------------------------------- helpers
local log = { info = print, warn = print, error = print, debug = function() end }
function M.init(env) if env and env.log then log = env.log end end

local function alive(o) return SETUP.alive(o) end
local function try(f) local ok, v = pcall(f) if ok then return v end return nil end
local function firstLine(e) return (tostring(e):match("^[^\n]*")) end
local function pathOf(o) local full = o:GetFullName() return full:match("^%S+%s+(.+)$") or full end
local function fname(o) return try(function() return o:GetFName():ToString() end) or "?" end
local function str(v)
    if type(v) == "string" then return v end
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and type(s) == "string" and s or nil
end
local function num(v) return type(v) == "number" and v == v and v > -M.LIMIT.coord and v < M.LIMIT.coord end
local function near(a, b) return math.abs(a - b) < 1e-3 end
local function worldOf(a) return try(function() return pathOf(a:GetWorld()) end) end

-- Per-world state: paths and plain values only. W.active: this world holds core's Start marker.
local W
local function newWorld(wp, active)
    W = { world = wp, active = active, faults = {}, fails = {}, logs = {}, mapUIs = {}, centredByUs = {}, tries = {} }
end
newWorld(nil, false)
function M.state() return W end

-- One "FAIL MAP ..." line per key and world.
local function failOnce(key, fmt, ...)
    if W.fails[key] then return end
    W.fails[key] = true
    log.info("FAIL MAP " .. fmt, ...)
end
-- A fault (a Lua error in a hook body or loop part): one ERROR line per part and world.
local function fault(part, err)
    if W.faults[part] then return end
    W.faults[part] = true
    log.error("MAP %s failed: %s (not logged again in this world)", part, firstLine(err))
end
local function guard(part, f, ...)
    local ok, err = pcall(f, ...)
    if not ok then fault(part, err) end
    return ok
end

-- One kind of core's markers in world wp (by full class path, so another mod's class of the same short name doesn't
-- count), sorted by name, capped.
local function markersOf(kind, wp)
    local cp, out = SETUP.markerClass(kind), {}
    for _, a in ipairs(FindAllOf(SETUP.markerShort(kind)) or {}) do
        if alive(a) and try(function() return a:GetClass():GetFullName():find(cp, 1, true) ~= nil end) and worldOf(a) == wp then
            out[#out + 1] = a
        end
    end
    table.sort(out, function(x, y) return fname(x) < fname(y) end)
    for i = #out, M.LIMIT.markers + 1, -1 do out[i] = nil end
    return out
end
-- A game class (or the picture) by package and name through the asset registry: the one that's loaded, else a load.
-- Only from the loop, never from a Construct hook.
local function getAsset(pkg, name)
    local helpers = StaticFindObject(HELPERS)
    local ok, o = pcall(function() return helpers:GetAsset({ PackageName = FName(pkg), AssetName = FName(name) }) end)
    if ok and alive(o) then return o end
    return nil, ok and "not found" or firstLine(o)
end

-- ---------------------------------------------------------------- pure functions (unit-tested)
-- The game's canvas point for a world point (CanvasPanel_15/52 units, before the map's zoom and pan).
function M.toCanvas(x, y) return M.PROJ.ox + x * M.PROJ.kx, M.PROJ.oy + y * M.PROJ.ky end
-- The world rectangle the stock picture covers (the inverse projection of its slot).
function M.stockRect()
    local s, p = M.STOCK_SLOT, M.PROJ
    return { minX = (s.x - p.ox) / p.kx, minY = (s.y - p.oy) / p.ky, maxX = (s.x + s.w - p.ox) / p.kx, maxY = (s.y + s.h - p.oy) / p.ky }
end

-- Where the picture goes and how the map is pre-zoomed: the slot (canvas units), whether the rectangle is the game's
-- own (then only the picture is swapped), the zoom S and the pan T that put the rectangle's centre in the view's
-- centre: the root's render transform is p' = S (p - pivot) + pivot + T, pivot the view's centre.
function M.layout(d)
    local x0, y0 = M.toCanvas(d.minX, d.minY)
    local x1, y1 = M.toCanvas(d.maxX, d.maxY)
    local L = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    local st = M.stockRect()
    -- Only the game's own rectangle (within 1 m) keeps the stock slot; any other rectangle, larger ones included, is
    -- placed in the projection (a larger one at zoom 1, the clamp's lower end).
    local e = 100
    L.full = math.abs(d.minX - st.minX) <= e and math.abs(d.minY - st.minY) <= e and math.abs(d.maxX - st.maxX) <= e and math.abs(d.maxY - st.maxY) <= e
    if L.full then L.zoom, L.tx, L.ty = 1, 0, 0 return L end
    local s = math.min(M.VIEW.w / L.w, M.VIEW.h / L.h) * M.FILL
    L.clamped = s > M.ZOOM.max
    L.zoom = math.max(M.ZOOM.min, math.min(M.ZOOM.max, s))
    local px, py = M.VIEW.w / 2, M.VIEW.h / 2
    L.tx = L.zoom * (px - (L.x + L.w / 2))
    L.ty = L.zoom * (py - (L.y + L.h / 2))
    return L
end

-- The level's own folder, /Game/Mods/<Map>/, from its world path; nil for a level outside /Game/Mods/.
function M.mapFolder(worldPath)
    if type(worldPath) ~= "string" then return nil end
    return worldPath:match("^(/Game/Mods/[%w_%-]+/)")
end
-- The Map marker's Picture: an object path /Game/Mods/<Map>/...<package>.<name> under folder, at most 256 characters.
-- Returns package and name, or nil and why.
function M.checkPicture(pic, folder)
    if type(pic) ~= "string" then return nil, "isn't a string (" .. type(pic) .. ")" end
    if #pic == 0 then return nil, "is empty" end
    if #pic > M.LIMIT.picture then return nil, string.format("is %d characters, cap %d", #pic, M.LIMIT.picture) end
    if not folder then return nil, "can't be checked: the level isn't under /Game/Mods/<Map>/" end
    local pkg, name = pic:match("^(/Game/[%w_/%-]+)%.([%w_]+)$")
    if not pkg then return nil, "isn't an object path /Game/<package>.<name>" end
    if pkg:find("//", 1, true) or pkg:sub(-1) == "/" then return nil, "isn't an object path /Game/<package>.<name>" end
    if pkg:sub(1, #folder) ~= folder or #pkg <= #folder then return nil, "isn't in the level's own folder " .. folder end
    return pkg, name
end
-- The Map marker's RectMin/RectMax: finite, under 1e9, at least 1 m on each axis, min below max. Returns
-- { minX, minY, maxX, maxY } or nil and why.
function M.checkRect(lo, hi)
    local function c(v, k) if v == nil then return nil end return try(function() return v[k] end) end
    local r = { minX = c(lo, "X"), minY = c(lo, "Y"), maxX = c(hi, "X"), maxY = c(hi, "Y") }
    local txt = string.format("(%s,%s)-(%s,%s)", tostring(r.minX), tostring(r.minY), tostring(r.maxX), tostring(r.maxY))
    if not (num(r.minX) and num(r.minY) and num(r.maxX) and num(r.maxY)) then return nil, txt .. " isn't finite numbers under 1e9" end
    if r.maxX - r.minX < M.LIMIT.minSize or r.maxY - r.minY < M.LIMIT.minSize then
        return nil, txt .. " isn't at least 1 m on each axis with min below max"
    end
    return r
end

-- ---------------------------------------------------------------- map data (from the loop)
-- The level's map data from its one Map marker, validated, cached per world as plain values:
-- { picture, pkg, name, minX, minY, maxX, maxY, marker = <marker path> }; nil and why when it's unusable (one FAIL
-- line). Level actors are there by the LoadMap post-hook, so no marker means none.
function M.data()
    if W.data then return W.data end
    if W.dataErr then return nil, W.dataErr end
    local ms = markersOf(M.KIND.map, W.world)
    local why, key
    if #ms ~= 1 then
        key, why = "marker", string.format("%d Map markers in the level (need exactly 1)", #ms)
    else
        local m = ms[1]
        local okR, pic, lo, hi = pcall(function() return m.Picture, m.RectMin, m.RectMax end)
        if not okR then
            key, why = "marker", string.format("the Map marker %s's settings can't be read (%s)", fname(m), firstLine(pic))
        else
            pic = str(pic)
            local pkg, name = M.checkPicture(pic, M.mapFolder(W.world))
            local r, whyR = M.checkRect(lo, hi)
            if not pkg then key, why = "picture", string.format("%q %s", SETUP.quote(pic), name)
            elseif not r then key, why = "rectangle", "RectMin/RectMax " .. whyR
            else
                r.picture, r.pkg, r.name, r.marker = pic, pkg, name, pathOf(m)
                W.data = r
                return r
            end
        end
    end
    W.dataErr = why
    failOnce(key, "%s %s; the Journal map stays stock", key, why)
    return nil, why
end

-- ---------------------------------------------------------------- picture (loop) and its lookup (hook)
local function missingPicture(d, why)
    if W.picMiss then return end
    W.picMiss = true
    failOnce("picture", "picture %s %s; the Journal map keeps the game's picture", d.picture, why)
end
-- Loaded once per world from the loop and referenced from the Map marker's KeepPicture (a level actor), or GC drops
-- it before anyone opens the Journal (the follow-up's first pair run, a 3-minute lobby).
function M.pictureTick()
    if W.picLoaded or W.picMiss or W.dataErr then return end
    local d = M.data()
    if not d then return end
    local t, why = getAsset(d.pkg, d.name)
    local cls = t and try(function() return t:GetClass():GetFName():ToString() end)
    if not t or cls ~= "Texture2D" then return missingPicture(d, "didn't load (" .. tostring(t and (cls or "class unreadable") or why) .. ")") end
    local m = StaticFindObject(d.marker)
    local okK = alive(m) and pcall(function() m.KeepPicture = t end)
    if not (okK and alive(try(function() return m.KeepPicture end))) then return missingPicture(d, "couldn't be kept from GC (the Map marker's KeepPicture)") end
    W.picLoaded = d.picture
    log.info("MAP picture %s loaded (%s x %s)", d.picture, tostring(try(function() return t:Blueprint_GetSizeX() end)), tostring(try(function() return t:Blueprint_GetSizeY() end)))
end
-- In a Construct hook: the loaded picture, or nil (not loaded yet: stock this time). The one lookup by path; a miss is
-- latched for the world.
local function picture(d)
    if W.picMiss or W.picLoaded ~= d.picture then return nil end
    local t = StaticFindObject(d.picture)
    if alive(t) then return t end
    missingPicture(d, "is no longer in memory")
    return nil
end

-- ---------------------------------------------------------------- the view and icon centring
-- MapUI's own zoom and pan variables (its wheel and drag events add to them) and the root's render transform.
local function applyView(ui, L)
    ui["Scale X"] = L.zoom
    ui["Scale Y"] = L.zoom
    ui.Translation = { X = L.tx, Y = L.ty }
    local root = ui.CanvasPanel_15
    root:SetRenderScale({ X = L.zoom, Y = L.zoom })
    root:SetRenderTranslation({ X = L.tx, Y = L.ty })
end

-- MapUI_C attaches every icon by the top-left corner of its box (canvas slot alignment (0, 0)), so each is drawn half
-- a box down-right of its spot (likely a game bug; docs/custom-maps.md). On a map whose rectangle isn't the game's own
-- each icon whose alignment still reads (0, 0) gets (0.5, 0.5). An icon is a child of CanvasPanel_15 or CanvasPanel_52
-- whose slot position is the projection's origin (352, 220): the player arrow, the waypoint, every icon MapUI_C adds.
-- One the game already centred is left alone, logged once per world (the fix isn't needed for it). MapUI.Image (the
-- picture) is never an icon: its slot sits at the origin when the rectangle's min corner is world (0, 0).
function M.centreIcons(ui)
    local r = { fixed = 0, already = 0, other = 0, failed = 0 }
    local imagePath = try(function() return pathOf(ui.Image) end)
    for _, cn in ipairs({ "CanvasPanel_15", "CanvasPanel_52" }) do
        local c = try(function() return ui[cn] end)
        local n = (alive(c) and try(function() return c:GetChildrenCount() end)) or 0
        if type(n) ~= "number" then n = 0 end
        for i = 0, n - 1 do
            local ch = try(function() return c:GetChildAt(i) end)
            if imagePath and alive(ch) and try(function() return pathOf(ch) end) == imagePath then ch = nil end
            local slot = alive(ch) and try(function() return ch.Slot end)
            local ok, p, a = pcall(function() local q = slot:GetPosition() local al = slot:GetAlignment() return { X = q.X, Y = q.Y }, { X = al.X, Y = al.Y } end)
            if ok and near(p.X, M.PROJ.ox) and near(p.Y, M.PROJ.oy) then
                local key = try(function() return pathOf(ch) end) or tostring(ch)
                if W.centredByUs[key] then
                    -- ours already
                elseif near(a.X, 0) and near(a.Y, 0) then
                    local okS, b = pcall(function() slot:SetAlignment(M.CENTRE) local q = slot:GetAlignment() return { X = q.X, Y = q.Y } end)
                    if okS and near(b.X, 0.5) and near(b.Y, 0.5) then W.centredByUs[key] = true r.fixed = r.fixed + 1 else r.failed = r.failed + 1 end
                elseif near(a.X, 0.5) and near(a.Y, 0.5) then r.already = r.already + 1
                else r.other = r.other + 1 end
            end
        end
    end
    if r.already > 0 and not W.centreNotNeeded then
        W.centreNotNeeded = true
        log.info("MAP %d icon(s) already centred (alignment 0.5, 0.5) by the game: the centring fix isn't needed for them", r.already)
    end
    if r.other > 0 and not W.centreOther then W.centreOther = true log.info("MAP %d icon(s) with another alignment left as they are", r.other) end
    if r.failed > 0 then failOnce("centring", "%d icon(s) couldn't be centred (SetAlignment didn't take)", r.failed) end
    return r
end
-- Every second, the maps this world opened (paths from the Construct hook): icons added after Construct. A map whose
-- widget is gone is dropped (one miss).
function M.centreTick()
    if #W.mapUIs == 0 then return end
    local keep = {}
    for _, path in ipairs(W.mapUIs) do
        local ui = StaticFindObject(path)
        if alive(ui) then
            keep[#keep + 1] = path
            local r = M.centreIcons(ui)
            if r.fixed > 0 then log.info("MAP centred %d icon(s) added after Construct", r.fixed) end
        end
    end
    W.mapUIs = keep
end
local function rememberMap(path)
    for _, p in ipairs(W.mapUIs) do if p == path then return end end
    W.mapUIs[#W.mapUIs + 1] = path
    while #W.mapUIs > M.MAX_MAPS do table.remove(W.mapUIs, 1) end
end

-- ---------------------------------------------------------------- hook bodies
-- Whether a Construct hook acts: only in the active world (one with core's Start marker), and only for a widget of
-- that world when its world can be read.
local function ours(w)
    if not W.active then return false end
    local wp = try(function() return pathOf(w:GetWorld()) end)
    return wp == nil or wp == W.world
end
-- MapUI_C:Construct post-hook body: the picture, its slot and the view. Returns a short description for the log, or
-- nil when it doesn't act. Map data is only read here when the loop has already read it.
function M.onMapUIConstruct(ui)
    if not ours(ui) then return nil end
    local d = W.data
    if not d then return "stock (" .. (W.dataErr and "bad map data" or "map data not read yet") .. ")" end
    local tex = picture(d)
    if not tex then return "stock (" .. (W.picMiss and "picture missing" or "picture not loaded yet") .. ")" end
    local L = M.layout(d)
    ui.Image:SetBrushFromTexture(tex, false)
    W.applied = (W.applied or 0) + 1
    if L.full then return "picture only (the game's own rectangle)" end
    local slot = ui.Image.Slot
    slot:SetPosition({ X = L.x, Y = L.y })
    slot:SetSize({ X = L.w, Y = L.h })
    applyView(ui, L)
    local r = M.centreIcons(ui)
    rememberMap(pathOf(ui))
    return string.format("picture, slot (%.2f,%.2f) %.2f x %.2f, zoom %.2f%s, pan (%.1f,%.1f), icons centred %d, already %d, other %d",
        L.x, L.y, L.w, L.h, L.zoom, L.clamped and " (clamped)" or "", L.tx, L.ty, r.fixed, r.already, r.other)
end
-- MapWidget_C:Construct post-hook body (it runs after its MapUI child's Construct and after the native part of its own
-- construction): the view again, in case anything reset it there; only when the picture is ours.
function M.onMapWidgetConstruct(mw)
    if not ours(mw) then return nil end
    local d = W.data
    if not d or W.picMiss or W.picLoaded ~= d.picture then return "stock" end
    local L = M.layout(d)
    if L.full then return "picture only" end
    local ui = mw.MapUI
    if not alive(ui) then return "no MapUI" end
    applyView(ui, L)
    return string.format("view zoom %.2f pan (%.1f,%.1f)", L.zoom, L.tx, L.ty)
end

-- ---------------------------------------------------------------- the loop's parts
-- Construct post-hooks, registered once per function (by address: a class reloaded after a map change has a new
-- function and is hooked again; the bodies are idempotent, so a doubled callback is harmless).
local hooked = {}
local function hookOnce(cls, what, body)
    local fnPath = cls[1] .. "." .. cls[2] .. ":Construct"
    local fn = StaticFindObject(fnPath)
    if not alive(fn) then return false end
    local key = tostring(try(function() return fn:GetAddress() end))
    if hooked[fnPath] == key then return true end
    local okH, e = pcall(RegisterHook, fnPath, function(ctx)
        local ok, r = pcall(function() return body(ctx:get()) end)
        if not ok then fault(what .. " Construct", r)
        elseif r ~= nil then
            W.logs[what] = (W.logs[what] or 0) + 1
            if W.logs[what] <= M.LOG_CONSTRUCT then log.info("MAP %s Construct: %s", what, r) end
        end
    end)
    if okH then hooked[fnPath] = key log.debug("MAP hooked %s", fnPath)
    elseif not W.fails["hook " .. fnPath] then W.fails["hook " .. fnPath] = true log.error("MAP could not hook %s: %s", fnPath, firstLine(e)) end
    return okH
end
function M.hooksTick()
    if W.hooked then return end
    W.tries.hooks = (W.tries.hooks or 0) + 1
    local a, b = getAsset(M.CLASS.mapUI[1], M.CLASS.mapUI[2]), getAsset(M.CLASS.mapWidget[1], M.CLASS.mapWidget[2])
    if not (a and b) then
        if W.tries.hooks >= M.TRIES then
            W.hooked = "failed"
            failOnce("hooks", "the map widget classes didn't load in %d s (MapUI_C %s, MapWidget_C %s); the Journal map stays stock", M.TRIES, tostring(a ~= nil), tostring(b ~= nil))
        end
        return
    end
    local h1 = hookOnce(M.CLASS.mapUI, "MapUI_C", M.onMapUIConstruct)
    local h2 = hookOnce(M.CLASS.mapWidget, "MapWidget_C", M.onMapWidgetConstruct)
    W.hooked = (h1 and h2) or nil
    if not W.hooked and W.tries.hooks >= M.TRIES then
        W.hooked = "failed"
        failOnce("hooks", "the Construct post-hooks couldn't be registered in %d s (MapUI_C %s, MapWidget_C %s); the Journal map stays stock", M.TRIES, tostring(h1), tostring(h2))
    end
end

-- Flags: one LevelLocationMap_C per Location marker, spawned on this machine only (the class doesn't replicate). Name
-- is the marker's LocationName and RUName the same text (MapUI_C shows RUName when the culture is "ru"). Once per
-- world; a bad name is one FAIL line and no flag for that marker.
function M.flagsTick()
    if W.flagsDone then return end
    W.tries.flags = (W.tries.flags or 0) + 1
    local cls = getAsset(M.CLASS.location[1], M.CLASS.location[2])
    if not cls then
        if W.tries.flags >= M.TRIES then
            W.flagsDone = true
            failOnce("flags", "class %s.%s didn't load in %d s; no area flags", M.CLASS.location[1], M.CLASS.location[2], M.TRIES)
        end
        return
    end
    W.flagsDone = true
    local ms = markersOf(M.KIND.location, W.world)
    if #ms == 0 then log.info("MAP no Location markers in the level; no area flags") return end
    local flags = {}
    for _, m in ipairs(ms) do
        local name = str(try(function() return m.LocationName end))
        local okN, whyN = SETUP.checkText(name, M.LIMIT.location)
        if not okN then failOnce("location " .. fname(m), "location marker=%s: LocationName %s; no flag for it", fname(m), whyN)
        else
            local okA, a, pos = pcall(function()
                local at = m:K2_GetActorLocation()
                local p = { X = at.X, Y = at.Y, Z = at.Z }
                return m:GetWorld():SpawnActor(cls, p, { Pitch = 0, Yaw = 0, Roll = 0 }), p
            end)
            if okA and alive(a) then
                local okS, errS = pcall(function() a.Name = name a.RUName = name end)
                local gotN, gotR = str(try(function() return a.Name end)), str(try(function() return a.RUName end))
                if okS and gotN == name and gotR == name then
                    flags[#flags + 1] = string.format("%q at (%.0f,%.0f)", name, pos.X, pos.Y)
                else failOnce("flag " .. fname(m), "flag %q: Name/RUName read %q/%q (%s)", name, tostring(gotN), tostring(gotR), okS and "set" or firstLine(errS)) end
            else failOnce("flag " .. fname(m), "flag %q: SpawnActor failed (%s)", name, okA and "no actor" or firstLine(a)) end
        end
    end
    log.info("MAP %d area flag(s) spawned locally: %s", #flags, table.concat(flags, ", "))
end

local function tick()
    if not W.active then return end
    guard("hooks", M.hooksTick)
    guard("flags", M.flagsTick)
    guard("picture", M.pictureTick)
    guard("centring", M.centreTick)
end
M.tick = tick

-- ---------------------------------------------------------------- the loop (game thread)
local loop = { gen = 0, running = false, handle = nil }
function M.running() return loop.running end
function M.start()
    if loop.running then return true end
    loop.gen = loop.gen + 1
    local gen, handle = loop.gen, nil
    local ok, res = pcall(LoopInGameThreadWithDelay, M.TICK_MS, function()
        if gen ~= loop.gen then
            if handle then pcall(CancelDelayedAction, handle) end
            return
        end
        local okT, errT = pcall(tick)
        if not okT then fault("tick", errT) end
    end)
    if not ok then
        log.error("MAP the Journal map loop could not start: %s", firstLine(res))
        return false
    end
    if math.type(res) == "integer" then handle = res loop.handle = res end
    loop.running = true
    return true
end
function M.stop()
    loop.gen = loop.gen + 1
    if loop.handle then pcall(CancelDelayedAction, loop.handle) end
    loop.handle, loop.running = nil, false
end

-- Core's LoadMap post-hook (world: the loaded UWorld, or nil when travel failed). A world with core's Start marker
-- gets fresh state and the loop; any other world stops it.
function M.onLoadMap(world)
    newWorld(nil, false) -- first: whatever happens below, the previous world's state is gone
    if not alive(world) then M.stop() return end
    local wp = pathOf(world)
    if #markersOf(M.KIND.start, wp) == 0 then newWorld(wp, false) M.stop() return end
    newWorld(wp, true)
    M.start()
end

return M
