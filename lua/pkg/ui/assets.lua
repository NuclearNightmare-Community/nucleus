-- Story 21 (Mod Manager story 2): the game's assets core's UI uses by path, loaded at runtime and never shipped: the
-- Remaster fonts and materials of the game look (theme.game) and the engine font (a text going back to plain).
-- Internal; not public API.
--
-- Each asset is loaded with AssetRegistryHelpers:GetAsset (returns a loaded asset at once, loads it otherwise; never a
-- StaticFindObject miss) and kept only as a weak handle (<Core>_Ref): nothing keeps it alive, so after a map change
-- the handle may deref to nil and the asset is loaded again (core's own classes are unloaded after a map change,
-- research 8.1). Inside a hook (a Construct post-hook) only the cache is read: an asset load there is fatal.
--
-- Loads happen in a LoadMap post-hook of the dependent's own Lua state (registered once, at the first use of the menu,
-- the screen host or the game look), so they are cached before the next map's menu is constructed, and on poll ticks.
-- An asset that can't be loaded logs one WARN per asset per Lua state; the element using it keeps the plain look.
local BASE = (...):gsub("%.ui%.assets$", "")
local C = require(BASE .. ".ui.common")
local theme = require(BASE .. ".ui.theme")

local A = {}

-- key -> { pkg, name, what }. The menu's own classes are not here: they exist whenever a menu does (a hit for
-- StaticFindObject), and loading them on every map (the match too) would only cost.
local SPEC = {}
-- The engine's default font: a text that goes from the game look back to the plain one.
SPEC["font:Engine"] = { pkg = "/Engine/EngineFonts/Roboto", name = "Roboto", what = "the engine font Roboto" }
for k, v in pairs(theme.game.fonts) do SPEC["font:" .. k] = { pkg = v.pkg, name = v.name, what = "the game font " .. v.name } end
for k, v in pairs(theme.game.materials) do SPEC["mat:" .. k] = { pkg = v.pkg, name = v.name, what = "the game material " .. v.name } end
A.SPEC = SPEC

local refs = {}                  -- key -> weak handle
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

-- The asset for key, or nil (one WARN per asset when it can't be loaded). cachedOnly, or inside a hook: the cache only.
function A.get(key, cachedOnly)
    local o = cached(key)
    if o then A.stats.hits = A.stats.hits + 1 return o end
    if cachedOnly or inHook() then A.stats.misses = A.stats.misses + 1 return nil end
    local s = SPEC[key]
    if not s then return nil end
    A.stats.loads = A.stats.loads + 1
    local helpers = C.found("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    local ok, got = pcall(function()
        return helpers:GetAsset({ PackageName = FName(s.pkg), AssetName = FName(s.name) })
    end)
    if not (ok and C.valid(got)) then
        C.warnOnce("asset:" .. key, "%s (%s.%s) could not be loaded; elements that use it keep the plain look", s.what, s.pkg, s.name)
        return nil
    end
    if C.ref then
        local okR, h = pcall(C.ref, got)
        if okR then refs[key] = h end
    end
    return got
end

-- Loads every game-look asset (fonts and materials) and the engine font; extra(), when set, loads more (text.lua:
-- core's widget classes in use). Never raises.
A.extra = nil
function A.preload()
    for key in pairs(SPEC) do pcall(A.get, key) end
    if A.extra then pcall(A.extra) end
end

-- The dependent's own LoadMap post-hook (once per Lua state): preloads before the new map's widgets are constructed.
local loadMapHooked = false
function A.ensureLoadMapHook()
    if loadMapHooked then return end
    loadMapHooked = true
    local ok, err = pcall(RegisterLoadMapPostHook, function()
        local okP, errP = pcall(A.preload)
        if not okP then C.warnOnce("preload", "ui asset preload after a map load failed: %s", tostring(errP):match("^[^\n]*")) end
    end)
    if not ok then
        C.warnOnce("loadmap hook", "ui: RegisterLoadMapPostHook failed (%s); assets load on poll ticks only, so a new menu's entry may appear a tick late", tostring(err):match("^[^\n]*"))
    end
end

function A._reset() for k in pairs(refs) do refs[k] = nil end loadMapHooked = false end -- unit tests
return A
