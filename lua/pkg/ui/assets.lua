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
-- the screen host, the game look or a texture), so they are cached before the next map's menu is constructed, and on
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
    if cachedOnly or inHook() then A.stats.misses = A.stats.misses + 1 return nil, "uncached" end
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

function A._reset() for k in pairs(refs) do refs[k] = nil end for k in pairs(used) do used[k] = nil end loadMapHooked = false end -- unit tests
A._used = used -- unit tests
return A
