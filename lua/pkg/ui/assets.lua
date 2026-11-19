-- Story 21 (Mod Manager story 2): the game's assets core's UI uses by path, loaded at runtime and never shipped: the
-- Remaster fonts and materials of the game look (theme.game) and the engine font (a text going back to plain).
-- Story 24 (core 0.8.0): also textures for images and button icons: core's own icons in core's pak ("tex:<key>") and
-- the allow-listed game textures ("gtex:<path>", theme.gameTextures). Internal; not public API.
--
-- Each asset is loaded with AssetRegistryHelpers:GetAsset (returns a loaded asset at once, loads it otherwise; never a
-- StaticFindObject miss) and kept only as a weak handle (<Core>_Ref): nothing keeps it alive, so after a map change
-- the handle may deref to nil and the asset is loaded again (core's own classes are unloaded after a map change,
-- research 8.1). Inside a hook (a Construct post-hook) only the cache is read: an asset load there is fatal.
--
-- Loads happen in a LoadMap post-hook of the dependent's own Lua state (registered once, at the first use of the menu,
-- the screen host, the game look or a texture), so they are cached before the next map's Journal is constructed, and on
-- poll ticks. Fonts and materials are preloaded always; a texture only once an element of this state has used it. An
-- asset that can't be loaded logs one WARN per asset per Lua state; the element using it falls back (plain look, or
-- core's icon for the same meaning).
local BASE = (...):gsub("%.ui%.assets$", "")
local C = require(BASE .. ".ui.common")
local theme = require(BASE .. ".ui.theme")

local A = {}

-- key -> { pkg, name, what, after, lazy }. after: what the WARN says happens instead; lazy: preloaded only once used.
-- The menu's own classes are not here: they exist whenever a menu does (a hit for StaticFindObject), and loading them
-- on every map (the match too) would only cost.
local SPEC = {}
local LOOK = "elements that use it keep the plain look"
-- The engine's default font: a text that goes from the game look back to the plain one.
SPEC["font:Engine"] = { pkg = "/Engine/EngineFonts/Roboto", name = "Roboto", what = "the engine font Roboto", after = LOOK }
for k, v in pairs(theme.game.fonts) do SPEC["font:" .. k] = { pkg = v.pkg, name = v.name, what = "the game font " .. v.name, after = LOOK } end
for k, v in pairs(theme.game.materials) do SPEC["mat:" .. k] = { pkg = v.pkg, name = v.name, what = "the game material " .. v.name, after = LOOK } end
-- Story 24: core's icons (its own pak) and the allow-listed game textures.
for key, asset in pairs(theme.icons) do
    SPEC["tex:" .. key] = { pkg = C.ICON_DIR .. "/" .. asset, name = asset, lazy = true, what = C.NAME .. "'s icon " .. key,
        after = "images and icons that use it show nothing (is " .. C.NAME .. "'s pak current?)" }
end
for path, fallback in pairs(theme.gameTextures) do
    local pkg, name = path:match("^(.+)%.([^./]+)$")
    SPEC["gtex:" .. path] = { pkg = pkg, name = name, lazy = true, what = "the game texture " .. name,
        after = fallback and ("images and icons that use it show " .. C.NAME .. "'s " .. fallback .. " icon instead")
            or "images and icons that use it show nothing" }
end
-- Mod Manager story 4: the game's Settings menu class, whose widget-tree template slider ("WidgetTree.Slider") core's
-- slider copies its style from (theme.game.sliderTemplate). Loaded only once a slider is used.
do
    local t = theme.game.sliderTemplate
    SPEC["cls:settings"] = { pkg = t.pkg, name = t.name, lazy = true, what = "the game's Settings menu class " .. t.name,
        after = "sliders keep " .. C.NAME .. "'s copy of the game's slider style" }
end
-- Core story 33 (0.15.0): the game's tooltip widget (a game-style row's "?" shows its help in it) and the game's picker
-- (choice widget = "game"). Loaded only once used (a game-style row with help, a game choice).
do
    local t = theme.game.tooltipWidget
    SPEC["cls:tooltip3"] = { pkg = t.pkg, name = t.name, lazy = true, what = "the game's tooltip widget " .. t.name,
        after = "game-style rows show their help as a plain tooltip" }
    local p = theme.game.pickerWidget
    SPEC["cls:msb"] = { pkg = p.pkg, name = p.name, lazy = true, what = "the game's picker " .. p.name,
        after = "game choices (widget = 'game') stay empty" }
end
A.SPEC = SPEC

local refs = {}                  -- key -> weak handle
local used = {}                  -- lazy keys an element of this state has asked for: preloaded from then on
local inHook = function() return false end
A.stats = { loads = 0, hits = 0, misses = 0 }

function A.setHookCheck(fn) inHook = fn end

local function cached(key)
    local r = refs[key]
    if not r then return nil end
    local ok, o = pcall(C.deref, r)
    if ok and o then return o end
    pcall(C.free, r)
    refs[key] = nil
    return nil
end

-- The asset for key, or nil and why: "uncached" (cachedOnly, or inside a hook, and not in the cache: try again outside
-- the hook), "missing" (it can't be loaded: one WARN per asset) or "unknown" (no such key).
function A.get(key, cachedOnly)
    local s = SPEC[key]
    if s and s.lazy then used[key] = true end
    local o = cached(key)
    if o then A.stats.hits = A.stats.hits + 1 return o end
    if not s then return nil, "unknown" end
    -- Mod Manager story 4: inside core's own click and control dispatch (a script hook) the cache only, too.
    if cachedOnly or inHook() or C.inDispatch > 0 then A.stats.misses = A.stats.misses + 1 return nil, "uncached" end
    A.stats.loads = A.stats.loads + 1
    local helpers = C.found("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    local ok, got = pcall(function()
        return helpers:GetAsset({ PackageName = FName(s.pkg), AssetName = FName(s.name) })
    end)
    if not (ok and C.valid(got)) then
        C.warnOnce("asset:" .. key, "%s (%s.%s) could not be loaded; %s", s.what, s.pkg, s.name, s.after)
        return nil, "missing"
    end
    if C.ref then
        local okR, h = pcall(C.ref, got)
        if okR then refs[key] = h end
    end
    return got
end

-- Mod Manager story 4: the game's Settings slider template (a Slider in SettingsMenu_C's widget tree), or nil and why:
-- "uncached" (inside a hook and not cached yet: try on the next tick) or "missing" (the class or its template is not
-- there: one WARN per Lua state; sliders keep the generated style). The class is loaded with GetAsset (never a
-- StaticFindObject miss); only once it is loaded is its template looked up, and a template that isn't there is not
-- looked up again in this Lua state (a miss scans every object).
local tmplRef, tmplMissing = nil, false
function A.sliderTemplate()
    if tmplRef then
        local ok, o = pcall(C.deref, tmplRef)
        if ok and o then return o end
        pcall(C.free, tmplRef)
        tmplRef = nil
    end
    if tmplMissing then return nil, "missing" end
    local cls, why = A.get("cls:settings")
    if not cls then return nil, why end
    local t = theme.game.sliderTemplate
    local path = t.pkg .. "." .. t.name .. ":" .. t.sub
    local o = C.found(path)
    if not o then
        tmplMissing = true
        C.warnOnce("asset:slider template", "the game's Settings slider (%s) is not there; sliders keep %s's copy of the game's slider style", path, C.NAME)
        return nil, "missing"
    end
    if C.ref then
        local okR, h = pcall(C.ref, o)
        if okR then tmplRef = h end
    end
    return o
end

-- Core story 30 (0.12.2): the focused row's strong look, a dynamic instance of the selection material with
-- theme.game.focusRowColors as its fill, or nil and why: "uncached" (none alive and cachedOnly (core's own key and click
-- handling, focus.lua), core's control dispatch (C.inDispatch) or a Construct hook: the UI tick creates it), "missing"
-- (the selection material can't be loaded: assets.lua's WARN), "failed" (creating or colouring it failed: one WARN, not
-- tried again in this Lua state). A dependent's own callback (its onClick, inside the click hook) may create it. One
-- instance per Lua state, shared by every row while it lives, kept only as a weak handle: made again after a map
-- change or a garbage collection that took it while no row showed it.
-- Unnamed (OptionalName None: a reused name collides) and transient. w: the world context (the row's widget).
-- Core story 39 (0.15.4): the focus chip is a second such instance (theme.game.focusChipColors), under the same rules,
-- with its own handle and failed flag (A.focusChipMaterial). Core story 38 (0.16.0): a carried row's look is a third
-- (theme.game.carryRowColors, A.carryRowMaterial).
local KML = "/Script/Engine.Default__KismetMaterialLibrary"
local MID_TRANSIENT = 1 -- EMIDCreationFlags::Transient: the transient package is its outer
local mids = {
    row = { colors = "focusRowColors", key = "asset:focus row",
        what = "the focused row's strong look", after = "focused rows show the plain selection" },
    chip = { colors = "focusChipColors", key = "asset:focus chip",
        what = "the focus chip", after = "focused controls show a solid focus chip" },
    -- Core story 38 (0.16.0): a row picked up with the keyboard or gamepad (theme.game.carryRowColors)
    carry = { colors = "carryRowColors", key = "asset:carry row",
        what = "the carried row's look", after = "carried rows show the focused row's band" },
}
local function instance(slot, w, cachedOnly)
    if slot.ref then
        local ok, o = pcall(C.deref, slot.ref)
        if ok and o then return o end
        pcall(C.free, slot.ref)
        slot.ref = nil
    end
    if slot.failed then return nil, "failed" end
    if cachedOnly or inHook() or C.inDispatch > 0 then return nil, "uncached" end
    local m, why = A.get("mat:selection")
    if not m then return nil, why end
    local ok, mid = pcall(function()
        local lib = C.found(KML)
        if not lib then error("KismetMaterialLibrary is not there", 0) end
        C.count()
        local o = lib:CreateDynamicMaterialInstance(w, m, FName("None"), MID_TRANSIENT)
        if not C.valid(o) then error("CreateDynamicMaterialInstance returned nothing", 0) end
        for name, c in pairs(theme.game[slot.colors]) do
            C.count(); o:SetVectorParameterValue(FName(name), { R = c.r, G = c.g, B = c.b, A = c.a })
        end
        return o
    end)
    if not ok then
        slot.failed = true
        C.warnOnce(slot.key, "%s (an instance of %s) could not be made; %s: %s",
            slot.what, theme.game.materials.selection.name, slot.after, (tostring(mid):match("^[^\n]*")))
        return nil, "failed"
    end
    if C.ref then
        local okR, h = pcall(C.ref, mid)
        if okR then slot.ref = h end
    end
    return mid
end
function A.focusRowMaterial(w, cachedOnly) return instance(mids.row, w, cachedOnly) end
function A.focusChipMaterial(w, cachedOnly) return instance(mids.chip, w, cachedOnly) end
function A.carryRowMaterial(w, cachedOnly) return instance(mids.carry, w, cachedOnly) end

-- Loads every game-look asset (fonts and materials), the engine font and the textures in use; extra(), when set,
-- loads more (text.lua: core's widget classes in use). Never raises.
A.extra = nil
function A.preload()
    for key, s in pairs(SPEC) do
        if not s.lazy or used[key] then pcall(A.get, key) end
    end
    if A.extra then pcall(A.extra) end
end

-- The dependent's own LoadMap post-hook (once per Lua state): preloads before the new map's widgets are constructed.
-- Core story 37: asked inside a hook (a dependent's callback, a Construct): no RegisterLoadMapPostHook there; remembered,
-- and the next UI tick (outside hooks) registers it (text.lua).
local loadMapHooked, loadMapWanted = false, false
A.onDeferred = nil -- fn(), set by text.lua: a request was remembered (keeps the UI loop running until it is done)
function A._loadMapWanted() return loadMapWanted end
function A.ensureLoadMapHook()
    if loadMapHooked then return end
    if inHook() or C.inDispatch > 0 then
        if not loadMapWanted then
            loadMapWanted = true
            if A.onDeferred then pcall(A.onDeferred) end
        end
        return
    end
    loadMapHooked, loadMapWanted = true, false
    local ok, err = pcall(RegisterLoadMapPostHook, function()
        local okP, errP = pcall(A.preload)
        if not okP then C.warnOnce("preload", "ui asset preload after a map load failed: %s", tostring(errP):match("^[^\n]*")) end
    end)
    if not ok then
        C.warnOnce("loadmap hook", "ui: RegisterLoadMapPostHook failed (%s); assets load on poll ticks only, so a new menu's entry may appear a tick late", tostring(err):match("^[^\n]*"))
    end
end

function A._reset() for k in pairs(refs) do refs[k] = nil end for k in pairs(used) do used[k] = nil end loadMapHooked, loadMapWanted = false, false; tmplRef, tmplMissing = nil, false; for _, m in pairs(mids) do m.ref, m.failed = nil, false end end -- unit tests
A._used = used -- unit tests
return A
