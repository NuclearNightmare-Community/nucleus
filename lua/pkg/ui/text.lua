-- UI-2 (story 8) and UI-4 (story 10): text elements on the HUD, kept there through every HUD rebuild. Also the element
-- engine every kind shares: panels (story 14, panel.lua) and buttons (story 15, button.lua) attach, re-attach, place and
-- remove through the functions here.
-- Exposed as core.ui.text on the connect API:
--   create{ id = <string>, text = <string|number|nil>, place = <intent|nil>, style = <style|nil> } -> handle
--   set(handle, text)            setStyle(handle, style)        setVisible(handle, visible)
--   remove(handle)               isShown(handle) -> boolean     stats() -> table (diagnostic copy, not semver API)
-- and core.ui.place(handle, intent) (UI-3, place.lua; any kind).
--
-- Elements are plain Lua state per mod: kind, id, text, intent, resolved style, the caller's visibility wish, and the
-- live widget's weak handle and path. Never a UObject. A text widget is WBP_<Core>Text (Border "Background" -> TextBlock
-- "Text"), tagged with ToolTipText "<core>:<mod>:<id>" and SelfHitTestInvisible, so it can be found again after a HUD
-- rebuild or a hot reload without relying on its text. Panels and buttons carry the same tag in a Blueprint string
-- variable (CoreTag, set with SetTag): a tooltip on them would show while the cursor is over a button. A UI-1 watcher
-- re-attaches every element on each `attached` event; on `lost` it only frees handles whose widget is gone.
--
-- Story 13: elements with place.host = "journal" live on the Journal's map page (journal.lua). Every map open is a new
-- Journal_C, so a journal watcher creates their widgets again on every `opened` (no scan for reuse unless the same
-- Journal comes back), and on `closed` / `lost` frees their handles without touching any widget: no reference to an
-- old Journal or its widgets is kept. They keep their state meanwhile, and isShown is false. Each open's attach is
-- timed per step (canvas lookup, each element, placement; story 14).
--
-- Story 14: a panel's children (el.panel set, no host of their own) live in the panel widget's box. The panel attaches
-- them after itself, in its order, and the per-host loops (attach on a host event, placement, ticks) skip them.
--
-- Story 21 (Mod Manager story 2): two more hosts, "menu" (the title-screen menu's main page, menu.lua) and "screen"
-- (core's windows, screen.lua; each window is a host of its own, "screen#<id>"), and two more containers: a list
-- (WBP_<Core>List, scrolling, a fixed size) and a row (WBP_<Core>Row, horizontal). A container is any element with
-- children (el.children): a panel, a list or a row; el.panel is an element's container. A row can sit in a list or a
-- panel, so a text in a row is two levels down; everything else is one level. And the game's look (style.look):
-- the Remaster fonts, colours and materials, loaded by path at runtime (assets.lua), the default on menu and screen.
--
-- Story 24 (core 0.8.0): a text's style.overflow ("ellipsis" | "clip" | nil) sets the TextBlock's overflow policy and
-- clips it to its box (nil: the engine's defaults, the 0.7.0 look); images (image.lua, a kind of their own); and
-- tooltips on text, buttons and images. A tooltip goes on the element's inner widget (a text's "Text", a button's
-- "Btn", an image's "Img"), never on a text's root, whose ToolTipText is its tag: Slate shows the tooltip of the
-- deepest hovered widget that has one, so the inner widget is made hit-testable only while it has a tooltip (a text's
-- Background SelfHitTestInvisible and Text Visible; an image's Img Visible), and otherwise stays HitTestInvisible, so
-- the hover never walks up to the tag. Tooltips need a host with a cursor (journal, menu, screen).
--
-- Core story 31 (core 0.13.0): the game's own screens as hosts (game.lua; first "createServer"): every open is a new
-- screen, so its elements get new widgets in its root canvas at the poll's opened, and closed / lost free their
-- handles, as for a window. They have a cursor and the game look, like the menu.
--
-- Core story 32 (core 0.14.0): on a game screen an element can also sit inside one of the game's own boxes, at a
-- position among the game's children (place { container = <name>, after | before | index | at }); the insert pass
-- (below ensureMenu) attaches it there and rebuilds the box once per open.
local BASE = (...):gsub("%.ui%.text$", "")
local C = require(BASE .. ".ui.common")
local H = require(BASE .. ".ui.hud")
local J = require(BASE .. ".ui.journal")
local M = require(BASE .. ".ui.menu")
local G = require(BASE .. ".ui.game") -- core story 31: the game screens (createServer)
local P = require(BASE .. ".ui.place")
local A = require(BASE .. ".ui.assets")
local theme = require(BASE .. ".ui.theme")
local D = require(BASE .. ".ui.debug")
local S = require(BASE .. ".ui.strings")

local X = {}

-- The hosts an element can sit on: poll() -> host object (valid only in this callback) and whether its elements can
-- be drawn now; canvas(obj) -> the canvas elements go into, or nil.
local HOST = {
    hud = {
        poll = function() local hud, _, vis = H._poll() return hud, hud ~= nil and C.drawn(vis) end,
        canvas = function(hud)
            local ok, c = pcall(function() return hud.OwningCanvas end)
            return ok and C.valid(c) and c or nil
        end,
    },
    journal = {
        poll = function() local j = J._poll() return j, j ~= nil and J._mapPageActive(j) end,
        canvas = function(j) return J._canvasOf(j) end,
    },
    -- Story 21: the title-screen menu's main page.
    menu = {
        poll = function() local m = M._poll() return m, m ~= nil and not M._hiddenOf(m) end,
        canvas = function(m) return M._canvasOf(m) end,
    },
}
-- Core story 31: the game screens (createServer): the open screen of the local player and its root CanvasPanel.
for host in pairs(C.GAME_SCREENS) do
    HOST[host] = {
        -- only a screen the poll has decided opened: an element made between the screen appearing and that tick waits for
        -- opened, so the closed or lost that follows always frees what was attached (a newer screen that replaced it
        -- waits for its own opened too)
        poll = function()
            local open = G._openNow(host)
            if not open then return nil end
            local s, p = G._poll(host)
            if p ~= open then return nil end
            return s, s ~= nil
        end,
        canvas = function(s) return G._canvasOf(host, s) end,
    }
end
-- Story 21: a window of the screen host ("screen#<id>"): its widget while it is open, and its Canvas.
local windowAdapters = {}
local function windowCanvas(w)
    local ok, c = pcall(C.prop, w, "Canvas")
    return ok and C.valid(c) and c or nil
end
local function hostA(host)
    local a = HOST[host]
    if a then return a end
    if C.hostKind(host) ~= "screen" then return nil end
    a = windowAdapters[host]
    if not a then
        local id = host:sub(8)
        a = {
            poll = function()
                local rec = C.windows[id]
                if not (rec and rec.open and rec.ref) then return nil end
                local ok, w = pcall(C.deref, rec.ref)
                if not (ok and w) then return nil end
                return w, true
            end,
            canvas = windowCanvas,
        }
        windowAdapters[host] = a
    end
    return a
end
X._hostA = hostA
local MAX_ID = 64
local MAX_TEXT = 256
local MAX_CHILDREN = 32          -- story 14: children per panel
local CHILD_CAP = { panel = 32, list = 256, row = 16 } -- story 21: children per container
local RETRY_TICKS = 10           -- a failed attach is retried every 10 ticks (5 s), not every tick
local TAG_PREFIX = C.LOWER .. ":" -- full tag: <core>:<modTag>:<id>

local tick = 0
local watching = false
local attachedThisTick = false  -- set by the attached watcher, read by the same tick's onTick
local pendingLog = nil           -- the attach line of the last attached event, logged on the next tick
local pendingDebug = false       -- whether pendingLog is the DEBUG report (all attached) or the INFO one (some failed)
local function flushLog()
    if not pendingLog then return end
    local t = C.pt()
    if pendingDebug then C.log.debug("%s", pendingLog) else C.log.info("%s", pendingLog) end
    C.pa("core.log", t)
    pendingLog = nil
end

-- ---------------------------------------------------------------- kinds
-- Per kind: the widget class, where its tag lives, and how its content and style reach a widget. A fresh widget shows
-- the generator's defaults, so a call that would only restate them is skipped (attach cost per Journal open, story 13).
local function sameStyle(a, b) return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a and a.pad == b.pad end
local function warnFirst(key, fmt, err, ...)
    -- every caller's argument, then the first line of err (a "..." mid-list would keep only its first value)
    local args = table.pack(...)
    args[args.n + 1] = tostring(err):match("^[^\n]*")
    C.warnOnce(key, fmt, table.unpack(args, 1, args.n + 1))
end

-- Story 21: the look an element is drawn in: its style's look, else the game's on the menu and screen hosts and the
-- plain one elsewhere.
local function lookOf(el)
    if el.style.look then return el.style.look end
    return C.gameHost(C.hostOf(el)) and "game" or "plain"
end
X._lookOf = lookOf

-- A game asset for the look (assets.lua): the cache only inside a hook; nil (plain look, one WARN) when missing.
local function gameAsset(key) return A.get(key) end

-- Story 21: a game-look background (a material) or the plain one (a colour). Only rows get the worn strip by default
-- in the game look; an explicit background is a colour in both looks. el.matBg: the widget shows a material now.
-- Core story 28: el.selBg marks a row showing focus.lua's selection highlight; any re-style draws its own background
-- again, so the mark goes (the UI tick puts the highlight back while the row holds focus).
local function backgroundStyle(el, w, fresh)
    local s = el.style
    el.selBg = nil
    local game = lookOf(el) == "game"
    if game and el.kind == "row" and not s.explicitBg then
        local mat = gameAsset("mat:strip")
        if mat then
            local t = theme.game.rowTint
            local ok, err = pcall(function() C.count(); w:SetBackgroundMaterial(mat, t.r, t.g, t.b, t.a, s.pad) end)
            if ok then el.matBg = true return end
            warnFirst("style:" .. el.id, "%s '%s': the game look's background failed (is %s's pak current?): %s", err, el.kind, el.id, C.NAME)
        end
    end
    if fresh and s.a == 0 and s.pad == 0 and not el.matBg then return end -- the unstyled widget already looks like this
    local ok, err = pcall(function()
        if el.matBg then C.count(); w:SetBackgroundSolid(); el.matBg = nil end
        C.count(); w:SetBackground(s.r, s.g, s.b, s.a)
        C.count(); w:SetBackgroundPadding(s.pad)
    end)
    if not ok then warnFirst("style:" .. el.id, "%s '%s': style not applied (is %s's pak current?): %s", err, el.kind, el.id, C.NAME) end
end
X._backgroundStyle = backgroundStyle -- core story 28: focus.lua restores a row's own background

-- Story 21: a text's font and colour in the game look (style.font, default body); back to the generator's defaults
-- (white, drop shadow, size 18) when it goes plain again.
local PLAIN_TEXT = { size = 18, r = 1, g = 1, b = 1, a = 1, shadowA = 0.85 }
local function textLook(el, w, fresh)
    if lookOf(el) == "game" then
        local f = theme.game.textFonts[el.style.font or "body"]
        local font = gameAsset("font:" .. f.font)
        if font then
            local c = theme.game.text
            local ok, err = pcall(function()
                C.count(); w:SetFontObject(font, f.size)
                C.count(); w:SetTextColor(c.r, c.g, c.b, c.a, theme.game.shadowA)
            end)
            if ok then el.gameText = true else warnFirst("look:" .. el.id, "text '%s': the game look failed (is %s's pak current?): %s", err, el.id, C.NAME) end
        end
        return
    end
    if el.gameText then
        el.gameText = nil
        pcall(function()
            local font = gameAsset("font:Engine") -- the engine's default font (Roboto), at the generator's size
            if font then C.count(); w:SetFontObject(font, PLAIN_TEXT.size) end
            C.count(); w:SetTextColor(PLAIN_TEXT.r, PLAIN_TEXT.g, PLAIN_TEXT.b, PLAIN_TEXT.a, PLAIN_TEXT.shadowA)
        end)
    end
end

-- Story 24: a text's overflow. TextBlock overflow policy (ETextOverflowPolicy: Clip 0, Ellipsis 1) and clipping
-- (EWidgetClipping: Inherit 0, ClipToBounds 1) on its "Text"; nil is the engine's defaults (Clip, Inherit), which a
-- fresh widget already has, so no call. el.appliedOverflow: what the widget has now (nil: the defaults).
local OVERFLOW = { ellipsis = { policy = 1, clip = 1 }, clip = { policy = 0, clip = 1 }, none = { policy = 0, clip = 0 } }
local function overflowStyle(el, w, fresh)
    if fresh then el.appliedOverflow = nil end
    local want = el.style.overflow
    if want == el.appliedOverflow then return end
    local o = OVERFLOW[want or "none"]
    local ok, err = pcall(function()
        local t = w.Text
        C.count(); t:SetTextOverflowPolicy(o.policy)
        C.count(); t:SetClipping(o.clip)
    end)
    if ok then el.appliedOverflow = want
    else warnFirst("overflow:" .. el.id, "text '%s': overflow %s not applied: %s", err, el.id, tostring(want)) end
end

-- Story 24: the tooltip on an element's inner widget, in the current language (picked on every apply). el.appliedTip:
-- the string the widget shows now (nil: none, as a fresh widget). The inner widget is hit-testable only while it has
-- one (top of this file).
-- Mod Manager story 4: a checkbox's on its Btn (it is a button widget), a choice's and a slider's on their Frame (the
-- arrows, the bar and the box are its hit-testable children, so hovering any of them finds it; a choice's Background
-- is made hit-testable while it has one, so its value text shows it too).
local TIP_INNER = { text = "Text", button = "Btn", image = "Img", checkbox = "Btn", choice = "Frame", slider = "Frame" }
local function applyTooltip(el, w, fresh)
    if fresh then el.appliedTip = nil end
    local s = el.tooltip and S.pick(el.tooltip) or nil
    if s == el.appliedTip then return end
    local ok, err = pcall(function()
        local inner = w[TIP_INNER[el.kind]]
        C.count(); inner:SetToolTipText(FText(s or ""))
        if el.kind == "text" then
            -- On: the Background lets hits through to the Text, which takes them. Off: the generator's (Background
            -- HitTestInvisible, so the whole subtree; Text SelfHitTestInvisible).
            C.count(); w.Background:SetVisibility(s and C.VIS.SelfHitTestInvisible or C.VIS.HitTestInvisible)
            C.count(); inner:SetVisibility(s and C.VIS.Visible or C.VIS.SelfHitTestInvisible)
        elseif el.kind == "image" then
            C.count(); inner:SetVisibility(s and C.VIS.Visible or C.VIS.HitTestInvisible)
        elseif el.kind == "choice" then
            C.count(); w.Background:SetVisibility(s and C.VIS.Visible or C.VIS.SelfHitTestInvisible)
        end
    end)
    if ok then el.appliedTip = s
    else warnFirst("tip:" .. el.id, "%s '%s': tooltip not applied (is %s's pak current?): %s", err, el.kind, el.id, C.NAME) end
end
X._applyTooltip = applyTooltip

local KIND = {
    text = {
        pkg = C.TEXT_PKG, short = C.TEXT_SHORT, cls = C.TEXT_CLASS, toolTipTag = true,
        content = function(el, w, fresh)
            if not (fresh and el.text == "") then C.count(); w:SetText(el.text) end
            applyTooltip(el, w, fresh)
        end,
        style = function(el, w, fresh)
            backgroundStyle(el, w, fresh)
            textLook(el, w, fresh)
            overflowStyle(el, w, fresh)
        end,
    },
    panel = {
        pkg = C.PANEL_PKG, short = C.PANEL_SHORT, cls = C.PANEL_CLASS,
        content = function() end,
        style = backgroundStyle,
    },
    -- Story 21: a scrolling list of a fixed size, and a row.
    list = {
        pkg = C.LIST_PKG, short = C.LIST_SHORT, cls = C.LIST_CLASS,
        content = function(el, w, fresh)
            local key = el.size.w .. "x" .. el.size.h
            if el.sizeKey == key and not fresh then return end
            C.count(); w:SetListSize(el.size.w, el.size.h)
            el.sizeKey = key
        end,
        style = backgroundStyle,
    },
    -- Core story 33: a game-style row (el.like) builds its native parts and copies its look (below, with the insert pass).
    row = {
        pkg = C.ROW_PKG, short = C.ROW_SHORT, cls = C.ROW_CLASS,
        content = function(el, w, fresh) if el.like then X._likeContent(el, w, fresh) end end,
        style = function(el, w, fresh)
            if el.like then X._likeStyle(el, w, fresh) else backgroundStyle(el, w, fresh) end
        end,
    },
}
X.KIND = KIND -- button.lua adds the button kind
-- Widget classes that are not element kinds (story 21: the window).
local EXTRA_CLASS = { screen = { pkg = C.SCREEN_PKG, short = C.SCREEN_SHORT } }

-- Mod Manager story 4: a checkbox is a button widget, so two kinds share one class. A widget's class names a kind (the
-- first of them, in a fixed order) only to read its tag; whether it belongs to an element compares classes (sameClass).
local KIND_ORDER = { "text", "panel", "button", "list", "row", "image", "checkbox", "choice", "slider" }
local function kindOfClass(short)
    for _, k in ipairs(KIND_ORDER) do
        local K = KIND[k]
        if K and K.short == short then return k end
    end
    for k, K in pairs(KIND) do if K.short == short then return k end end
    return nil
end
local function sameClass(a, b) return a == b or (KIND[a] ~= nil and KIND[b] ~= nil and KIND[a].short == KIND[b].short) end
X._kindOfClass, X._sameClass = kindOfClass, sameClass

-- ---------------------------------------------------------------- validation (pure)

local function validId(id, fn)
    if type(id) ~= "string" then C.fail("%s.%s: id must be a string, got %s", C.UI, fn, C.describe(id)) end
    if id == "" then C.fail("%s.%s: id must not be empty", C.UI, fn) end
    if #id > MAX_ID then C.fail("%s.%s: id is %d characters, at most %d", C.UI, fn, #id, MAX_ID) end
    if not id:match("^[A-Za-z0-9_%.%-]+$") then
        C.fail("%s.%s: id %s has characters outside A-Z a-z 0-9 _ . -", C.UI, fn, C.describe(id))
    end
    return id
end

-- Text to show: strings and numbers (tostring); nil is "". Returns the text and whether it was cut.
local function cut(s)
    if #s <= MAX_TEXT then return s, false end
    local okL, n = pcall(utf8.len, s)
    if okL and n then
        if n <= MAX_TEXT then return s, false end
        return s:sub(1, utf8.offset(s, MAX_TEXT + 1) - 1), true
    end
    return s:sub(1, MAX_TEXT), true -- not valid UTF-8: bytes
end
local function validText(text, fn)
    local t = type(text)
    if text == nil then return "", false end
    if t == "string" then return cut(text) end
    if t == "number" then return cut(tostring(text)) end
    C.fail("%s.%s: text must be a string, a number or nil, got %s", C.UI, fn, t)
end

local function unit(v, what, pre)
    if type(v) ~= "number" or v ~= v or v < 0 or v > 1 then
        C.fail("%s: background.%s must be a number from 0 to 1, got %s", pre, what, C.describe(v))
    end
    return v + 0.0
end

-- Resolves a style to { r, g, b, a, pad } (colour 0..1, padding in canvas units). kind (default "text") picks the
-- error prefix and the defaults: text has no box, a panel is dim with normal padding (story 14), a button is the
-- theme's face with its hover and pressed colours (story 15).
local LOOKS = { game = true, plain = true }
local STYLE_KEYS = { background = true, padding = true, look = true, font = true, overflow = true }
local OVERFLOWS = { ellipsis = true, clip = true }
function X.resolveStyle(style, kind)
    kind = kind or "text"
    local pre = C.UI .. "." .. kind
    if style == nil then
        if kind == "text" then return { r = 0, g = 0, b = 0, a = 0, pad = 0 } end
        if kind == "panel" then style = theme.panelDefault
        elseif kind == "list" then style = theme.listDefault
        else style = {} end
    end
    if type(style) ~= "table" then C.fail("%s: style must be a table { background = ..., padding = ... }, got %s", pre, C.describe(style)) end
    for k in pairs(style) do
        if not STYLE_KEYS[k] then C.fail("%s: unknown style key %s (valid: background, font, look, overflow, padding)", pre, C.describe(k)) end
    end
    -- Story 24: overflow, on a text only (it fits a text to its box: a row column with fill, a fixed-size parent).
    local overflow = style.overflow
    if overflow ~= nil then
        if kind ~= "text" then C.fail("%s: style key overflow is available on text only", pre) end
        if type(overflow) ~= "string" or not OVERFLOWS[overflow] then C.fail("%s: unknown overflow %s (valid: ellipsis, clip)", pre, C.describe(overflow)) end
    end
    -- Story 21: the look (nil: the host's default) and, on a text, its font (game look only).
    local look = style.look
    if look ~= nil and (type(look) ~= "string" or not LOOKS[look]) then C.fail("%s: unknown look %s (valid: game, plain)", pre, C.describe(look)) end
    local font = style.font
    if font ~= nil then
        if kind ~= "text" then C.fail("%s: unknown style key 'font' (valid: background, look, padding; font is for text)", pre) end
        if type(font) ~= "string" or not theme.game.textFonts[font] then
            C.fail("%s: unknown font %s (valid: %s)", pre, C.describe(font), table.concat(theme.game.textFontNames, ", "))
        end
        if look == "plain" then C.fail("%s: font needs look = 'game' (got look 'plain')", pre) end
    end
    local bg, col = style.background, nil
    if bg == nil then bg = kind == "button" and theme.button or "none" end
    if type(bg) == "string" then
        local p = theme.background[bg]
        if not p then C.fail("%s: unknown background %s (valid: %s, or { r = 0..1, g = 0..1, b = 0..1, a = 0..1 })", pre, C.describe(bg), table.concat(theme.backgroundNames, ", ")) end
        col = { r = p.r, g = p.g, b = p.b, a = p.a }
    elseif type(bg) == "table" then
        for k in pairs(bg) do
            if k ~= "r" and k ~= "g" and k ~= "b" and k ~= "a" then C.fail("%s: unknown background key %s (valid: r, g, b, a)", pre, C.describe(k)) end
        end
        col = { r = unit(bg.r, "r", pre), g = unit(bg.g, "g", pre), b = unit(bg.b, "b", pre), a = bg.a == nil and 1.0 or unit(bg.a, "a", pre) }
    else
        C.fail("%s: background must be a preset name or a colour table, got %s", pre, C.describe(bg))
    end
    local pad = style.padding
    if pad == nil then
        if kind == "button" then pad = theme.buttonPadding
        else pad = (col.a > 0) and theme.paddingWithBackground or "none" end
    end
    if type(pad) ~= "string" or theme.padding[pad] == nil then
        C.fail("%s: unknown padding %s (valid: %s)", pre, C.describe(pad), table.concat(theme.paddingNames, ", "))
    end
    col.pad = theme.padding[pad]
    col.look, col.font, col.explicitBg, col.overflow = look, font, style.background ~= nil, overflow
    if kind == "button" then
        local h, q = theme.buttonHover, theme.buttonPressed
        col.hover = { r = h.r, g = h.g, b = h.b, a = h.a }
        col.pressed = { r = q.r, g = q.g, b = q.b, a = q.a }
    end
    return col
end

-- ---------------------------------------------------------------- handles

local function newHandle(id, kind)
    kind = C.publicKind(kind) -- core story 33: a game choice's handle is a choice's
    return setmetatable({}, {
        __index = { id = id },
        __newindex = function() error(C.UI .. "." .. kind .. ": element handles are read-only", 2) end,
        __metatable = "element handle",
        __tostring = function() return (kind == "text" and "element '" or (kind .. " '")) .. id .. "'" end,
    })
end

-- ---------------------------------------------------------------- widget helpers (game thread)

local function tagOf(id) return TAG_PREFIX .. C.modTag .. ":" .. id end

-- The widget class of a kind, kept as a weak handle between ticks. Never StaticFindObject(<class path>): when the class
-- isn't loaded that misses, and a miss in the pinned UE4SS scans every object (4-5 ms per call on V8.1.2, twice per HUD
-- event with two elements). GetAsset returns the loaded class at once and loads it otherwise.
local classRefs = {}
local inHookNow = function() return false end -- story 20: X._inHook, set below
local function classOf(kind)
    local K = KIND[kind] or EXTRA_CLASS[kind]
    local r = classRefs[kind]
    if r then
        local okD, cls = pcall(C.deref, r)
        if okD and cls then return cls end
        pcall(C.free, r)
        classRefs[kind] = nil
    end
    -- Story 20: inside the Journal's Construct hook only a cached class is used: never GetAsset (a load there is fatal).
    -- Story 21: the same inside the menu's.
    if inHookNow() or M._inHook then return nil end
    local t = C.pt()
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    local ok, got = pcall(function()
        return helpers:GetAsset({ PackageName = FName(K.pkg), AssetName = FName(K.short) })
    end)
    C.pa("class.load", t)
    if not (ok and C.valid(got)) then return nil end
    local okR, h = pcall(C.ref, got)
    if okR then classRefs[kind] = h end
    return got
end
X._classOf = classOf

-- Core story 37: elements whose class missed the cache inside a dependent's callback (C.inDispatch > 0), in order;
-- attached on the next UI tick (outside any hook, flushDeferred below). While it isn't empty, or a LoadMap hook request
-- waits (assets.lua), the queue holds one keep token, so the loop runs without a HUD watcher (DW-71).
local deferred = { list = {}, set = {} }
local deferKeep = nil
local function deferSync()
    local want = #deferred.list > 0 or A._loadMapWanted()
    if want and not deferKeep then deferKeep = H._keep()
    elseif not want and deferKeep then
        local k = deferKeep
        deferKeep = nil
        H._release(k)
    end
end
local function deferAttach(el)
    if not deferred.set[el] then
        deferred.set[el] = true
        deferred.list[#deferred.list + 1] = el
    end
    deferSync()
end
A.onDeferred = deferSync

-- live(el) -> the element's widget when it sits in this container (a host canvas, or a panel's box), else nil.
local function liveIn(container)
    local caddr = container:GetAddress()
    return function(el)
        if not el.ref then return nil end
        local w = C.deref(el.ref)
        if not w then return nil end
        local okP, p = pcall(function() return w:GetParent() end)
        if okP and C.valid(p) and p:GetAddress() == caddr then return w end
        return nil
    end
end

-- The tag a widget of one of our kinds carries, or nil.
local function readTag(w, kind)
    local ok, t
    if KIND[kind].toolTipTag then ok, t = pcall(function() return w.ToolTipText:ToString() end)
    else ok, t = pcall(function() return w.CoreTag:ToString() end) end
    return ok and type(t) == "string" and t or nil
end
X._readTag = readTag

-- Our widgets among a container's direct children: byId[id] = { widgets in child order }, orphans = { widget, id }.
-- belongs(el): whether an element's widget belongs in this container; a tagged widget of any other element (one of
-- this mod's that is now elsewhere, or that it no longer has) is an orphan here.
local function scan(container, belongs)
    local byId, orphans = {}, {}
    local mine = TAG_PREFIX .. C.modTag .. ":"
    local n = container:GetChildrenCount()
    for i = 0, n - 1 do
        local c = container:GetChildAt(i)
        if C.valid(c) then
            local okC, cls = pcall(function() return c:GetClass():GetFName():ToString() end)
            local kind = okC and kindOfClass(cls) or nil
            if kind then
                local tag = readTag(c, kind)
                if tag and tag:sub(1, #mine) == mine then
                    local id = tag:sub(#mine + 1)
                    local el = C.els[id]
                    if el and not el.removed and sameClass(el.kind, kind) and belongs(el) then
                        byId[id] = byId[id] or {}
                        table.insert(byId[id], c)
                    else
                        orphans[#orphans + 1] = { w = c, id = id }
                    end
                end
            end
        end
    end
    return byId, orphans
end
local function onHost(host) return function(el) return el.panel == nil and el.place.host == host end end
local function inPanel(p) return function(el) return el.panel == p end end

local function setTag(w, el)
    local tag = tagOf(el.id)
    local ok
    if KIND[el.kind].toolTipTag then
        ok = pcall(function() C.count(); w:SetToolTipText(FText(tag)) end)
        if not ok then ok = pcall(function() C.count(); w.ToolTipText = FText(tag) end) end
    else
        ok = pcall(function() C.count(); w:SetTag(tag) end)
    end
    if not ok then C.warnOnce("tag:" .. el.id, "%s '%s': could not set its tag; it may be duplicated after a HUD rebuild", el.kind, el.id) end
end

local function freeRef(el)
    if el.ref then
        pcall(C.free, el.ref)
        C.stats.handlesFreed = C.stats.handlesFreed + 1
    end
    el.ref, el.path = nil, nil
end
-- Core story 33: what went with an element's widget (detached, removed, its host gone): a game choice's picker (a weak
-- handle too) and a game-style row's applied label and help.
local function dropParts(el)
    if el.msbRef then pcall(C.free, el.msbRef); el.msbRef = nil end
    el.appliedLabel, el.appliedHelp, el.shownIndex = nil, nil, nil
end
X._dropParts = dropParts

local function removeWidget(w)
    pcall(function() C.count(); w:RemoveFromParent() end)
end

local function liveWidget(el) return el.ref and C.deref(el.ref) or nil end

-- ---------------------------------------------------------------- panels: the box and its children (story 14)

-- The box a container's children go into (a panel: VBox or HBox of WBP_<Core>Panel; story 21: a list's VBox inside its
-- ScrollBox, a row's HBox), and, for a panel, the other one (other: a list or a row has none).
local function boxOf(p, w, other)
    local ok, b
    -- Core story 33: a game-style row's children go into its holder (between the label and the "?").
    if p.like and not other then
        local parts = X._likeParts(w)
        if parts then return parts.holder end
    end
    if p.kind == "list" or p.kind == "row" then
        if other then return nil end
        ok, b = pcall(function() if p.kind == "row" then return w.HBox end return w.VBox end)
    else
        local horiz = p.layout == "horizontal"
        if other then horiz = not horiz end
        ok, b = pcall(function() if horiz then return w.HBox end return w.VBox end)
    end
    return ok and C.valid(b) and b or nil
end
X._boxOf = boxOf

-- Box slot paddings: the first visible child 0, every later visible one the container's gap before it (top in a
-- vertical one, left in a horizontal one). Hidden children are collapsed: the box skips them and their padding.
-- Story 21: a row's child also gets its fill (a Fill slot with that weight: equal weights line up as columns; none:
-- Auto).
local SIZE_AUTO, SIZE_FILL = 0, 1
-- Story 24: an image, or a button that is only an icon, keeps its own size in a box (a box slot fills across by
-- default, which would stretch it): centred in a horizontal box (a row; in its column when it has a fill), at the
-- start of a vertical one. Other children keep the 0.7.0 slots. EVerticalAlignment Center 2, EHorizontalAlignment
-- Center 2 / Left 1; Fill 0 for both.
-- Mod Manager story 4: a checkbox too (an icon-only button); a choice and a slider fill like a text.
local function keepsSize(ch) return ch.kind == "image" or ch.kind == "checkbox" or (ch.kind == "button" and ch.icon ~= nil and ch.label == "") end
local function applyGaps(p)
    local first = true
    local horiz = p.layout == "horizontal"
    local isRow = p.kind == "row"
    for _, ch in ipairs(p.children) do
        if not ch.removed and ch.visible then
            local w = liveWidget(ch)
            if w then
                local pad = first and 0 or p.gapUnits
                first = false
                local fixed = keepsSize(ch)
                -- Core story 27 (the clipped checkbox and gear, measured in the VM): Slate centres a child at
                -- (allotted - size) / 2 + left - right padding, so a gap carried as left padding alone put a centred
                -- fixed-size child half a gap past its slot's right edge (4 units at "tight", cut off at a list's edge).
                -- Split 3/4 left, 1/4 right it sits centred in the slot less the gap, with the same total space. And a
                -- list's children keep theme.listInset clear of its right edge (the scrollbar side).
                local left, right = pad, 0
                if horiz and fixed then left, right = pad * 0.75, pad * 0.25 end
                local inset = (not horiz and p.kind == "list") and theme.listInset or 0
                -- Core story 33: in a game-style row's holder (which takes the game control's Fill slot) a child with no
                -- fill fills it too, as the game's control does (its picker's ScaleBox then scales like the game's).
                local fill = ch.fill or (p.like and 1.0 or nil)
                local key = (isRow and (tostring(pad) .. "/" .. tostring(fill)) or tostring(pad)) .. (fixed and "/k" or "") .. (inset > 0 and ("/i" .. inset) or "")
                if ch.padKey ~= key then
                    local ok, err = pcall(function()
                        C.count()
                        w.Slot:SetPadding(horiz and { Left = left, Top = 0, Right = right, Bottom = 0 } or { Left = 0, Top = pad, Right = inset, Bottom = 0 })
                        if isRow then
                            C.count()
                            w.Slot:SetSize({ SizeRule = fill and SIZE_FILL or SIZE_AUTO, Value = fill or 1.0 })
                        end
                        if fixed or ch.alignKept then
                            C.count()
                            if horiz then
                                w.Slot:SetVerticalAlignment(fixed and 2 or 0)
                                C.count(); w.Slot:SetHorizontalAlignment(fixed and 2 or 0) -- a Fill slot (fill = n) centres it in its column
                            else
                                w.Slot:SetHorizontalAlignment(fixed and 1 or 0)
                            end
                            ch.alignKept = fixed
                        end
                    end)
                    if ok then ch.padKey = key else warnFirst("gap:" .. p.id, "panel '%s': setting a child's gap failed: %s", err, p.id) end
                end
            end
        end
    end
end

-- Puts the panel's live child widgets into box in the panel's order: every one is taken out and added back (box
-- panels only append; InsertChildAt isn't reflected). The same widgets: none is created or destroyed.
local function rebuildBox(p, box)
    local ws = {}
    for _, ch in ipairs(p.children) do
        local w = not ch.removed and liveWidget(ch)
        if w then ws[#ws + 1] = w end
    end
    for _, w in ipairs(ws) do removeWidget(w) end
    for _, w in ipairs(ws) do
        local ok, err = pcall(function() C.count(); box:AddChild(w) end)
        if not ok then warnFirst("rebuild:" .. p.id, "panel '%s': putting a child back failed: %s", err, p.id) end
    end
    for _, ch in ipairs(p.children) do ch.padKey = "0" end -- new slots
    C.stats.panelRebuilds = (C.stats.panelRebuilds or 0) + 1
    applyGaps(p)
end
X._rebuildBox = rebuildBox

-- Whether the box already holds the panel's live children in its order; rebuilds it when not.
local function ensureOrder(p, box)
    local want = {}
    for _, ch in ipairs(p.children) do
        local w = not ch.removed and liveWidget(ch)
        if w then want[#want + 1] = w:GetAddress() end
    end
    local n = box:GetChildrenCount()
    local same = n == #want
    if same then
        for i = 1, n do
            local c = box:GetChildAt(i - 1)
            if not (C.valid(c) and c:GetAddress() == want[i]) then same = false break end
        end
    end
    if not same then rebuildBox(p, box) end
    return not same
end

-- A child that should be attached but whose widget is gone (Deref only); story 21: at any depth (a row in a list).
local function childMissing(p)
    for _, ch in ipairs(p.children) do
        if not ch.removed and (ch.retryAt == nil or tick >= ch.retryAt) then
            if not liveWidget(ch) then return true end
            if ch.children and childMissing(ch) then return true end
        end
    end
    return false
end

-- ---------------------------------------------------------------- attach (UI-2) and re-attach (UI-4)

local attachChildren -- below

-- The ids of a container's children (at any depth) that are not attached, appended to pending (at most 8 kept).
function X._pendingChildren(p, pending)
    for _, ch in ipairs(p.children) do
        if not ch.removed then
            if not ch.attached then
                pending = pending or {}
                if #pending < 8 then pending[#pending + 1] = "'" .. ch.id .. "'" end
            elseif ch.children then
                pending = X._pendingChildren(ch, pending)
            end
        end
    end
    return pending
end

-- Puts one element's widget into its container (a host canvas, or its panel's box; hostObj: the live HUD or Journal):
-- reuses the element's own widget or one tagged with its id, else creates one. Then re-applies content and style;
-- placement and visibility follow in placeAll (children: in attachChildren). A panel then attaches its children.
-- steps (optional): per-element timing { id, us, create, panel } appended after each element. Raises on failure
-- (callers pcall).
local attachOneBody -- below
-- Core story 33: the host object of the attach running now (the open game screen for a game-style row and a game
-- choice: where the like row is read, and the world and owner of the widgets they create), or nil outside an attach.
-- Valid only during that attach; never kept.
local curHostObj = nil
function X._attachHostObj() return curHostObj end
local function attachOne(el, hostObj, container, byId, reason, report, steps)
    local prev = curHostObj
    curHostObj = hostObj
    local ok, res = pcall(attachOneBody, el, hostObj, container, byId, reason, report, steps)
    curHostObj = prev
    if not ok then error(res, 0) end
    return res
end
attachOneBody = function(el, hostObj, container, byId, reason, report, steps)
    local tStep = steps and C.micros()
    local tCreate = 0
    local t = C.pt()
    local live = liveIn(container)
    local w = live(el)
    local tagged = byId[el.id] or {}
    local how = "reused"
    if not w and #tagged > 0 then w = tagged[1] end
    -- Never two: keep the one in use (or the first tagged one) and remove the rest.
    local extra = 0
    if w then
        local keep = w:GetAddress()
        for _, d in ipairs(tagged) do
            if d:GetAddress() ~= keep then removeWidget(d); extra = extra + 1 end
        end
    end
    C.pa("attach.find", t)
    if extra > 0 then
        C.log.warn("%s '%s': removed %d duplicate widget(s) from the %s", el.kind, el.id, extra,
            el.panel and ("panel '" .. el.panel.id .. "'") or (el.place.host .. " canvas"))
    end
    byId[el.id] = nil
    local fresh = false
    if not w then
        local tc = steps and C.micros()
        t = C.pt()
        local cls = classOf(el.kind)
        C.pa("attach.class", t)
        if not cls then
            -- Core story 37: inside a dependent's callback, attached on the next UI tick (no load inside the hook).
            if C.inDispatch > 0 then deferAttach(el) return false end
            if inHookNow() then return false end -- story 20: not cached; attached at the poll's opened
            C.warnOnce("pak:" .. el.id, "%s '%s' stays pending: %s is not loaded (is Content/Paks/LogicMods/%s.pak installed?)", el.kind, el.id, KIND[el.kind].cls, C.NAME)
            return false
        end
        t = C.pt()
        local owner
        local okO, o = pcall(function() return hostObj:GetOwningPlayer() end)
        if okO and C.valid(o) then owner = o end
        local world = hostObj:GetWorld()
        if not owner then
            local okP, pc = pcall(function() return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(world, 0) end)
            if okP and C.valid(pc) then owner = pc end
        end
        C.pa("attach.owner", t)
        if not owner then return false end -- between worlds; the next host event tries again
        C.count()
        t = C.pt()
        w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(world, cls, owner)
        C.pa("attach.create", t)
        if not C.valid(w) then error("creating " .. KIND[el.kind].short .. " failed") end
        if steps then tCreate = C.micros() - tc end
        t = C.pt()
        setTag(w, el)
        C.pa("attach.tag", t)
        el.appliedVis = nil
        t = C.pt()
        P.applyVisibility(el, w) -- before it joins the container, so a hidden element never flashes
        C.pa("attach.vis", t)
        t = C.pt()
        -- Core story 32: an element in a game container joins it in the insert pass, at its position (never appended here).
        if el.panel then C.count(); container:AddChild(w)
        elseif not el.place.container then C.count(); container:AddChildToCanvas(w) end
        C.pa("attach.add", t)
        how, fresh = "created", true
        C.stats.attachCreated = C.stats.attachCreated + 1
    else
        C.stats.attachReused = C.stats.attachReused + 1
    end
    el.lastHow = how
    t = C.pt()
    KIND[el.kind].content(el, w, fresh)
    C.pa("attach.text", t)
    t = C.pt()
    KIND[el.kind].style(el, w, fresh)
    C.pa("attach.style", t)
    t = C.pt()
    local path = C.pathOf(w)
    if path ~= el.path or not el.ref then
        if el.ref then C.log.debug("ui '%s': new widget %s; freed the handle %s of the old one (%s)", el.id, path, tostring(el.ref), tostring(el.path)) end
        freeRef(el)
        el.ref, el.path = C.ref(w), path
    end
    C.pa("attach.ref", t)
    el.attached, el.slotKey, el.retryAt = true, nil, nil
    -- A fresh widget got its visibility before it joined; a reused one gets it again (placeAll, attachChildren).
    if not fresh then el.appliedVis = nil end
    if el.panel then el.padKey = fresh and "0" or nil end
    if el.children then attachChildren(el, w, hostObj, fresh, reason, report, steps) end
    if C.debugOn() and not el.panel and not el.place.container then D.schedule(el, "attach") end -- story 12: overlap check about 1 s later (debug only, HUD only)
    -- DEBUG only: a log line costs 0.3-0.8 ms on the game thread, and a successful attach is routine. Failures keep
    -- their INFO/WARN lines (onHud, warnOnce).
    if report then
        if report.build then report[#report + 1] = string.format("'%s' %s %s", el.id, how, path) end
    elseif C.debugOn() then
        t = C.pt()
        C.log.debug("ui attach '%s' %s %s (%s)", el.id, how, path, reason)
        C.pa("attach.log", t)
    end
    if steps then steps[#steps + 1] = { id = el.id, us = C.micros() - tStep, create = tCreate, panel = el.panel and el.panel.id or nil } end
    return true
end

-- A panel's children, into its box in the panel's order, after the panel itself (story 14). A fresh panel holds
-- nothing yet, so its box is not scanned and its order is right by construction; a reused one is scanned for our tags
-- (duplicates and orphans go) and its order checked.
attachChildren = function(p, pw, hostObj, fresh, reason, report, steps)
    local box = boxOf(p, pw)
    if not box then
        C.warnOnce("nobox:" .. p.id, "%s '%s': its widget has no %s; its children stay pending (is %s's pak current?)", p.kind, p.id, p.layout == "horizontal" and "HBox" or "VBox", C.NAME)
        return
    end
    local byId = {}
    if not fresh then
        local okS, b, orphans = pcall(scan, box, inPanel(p))
        if okS then
            byId = b
            for _, o in ipairs(orphans) do removeWidget(o.w) end
        end
        -- After a layout change our widgets may still sit in the other box: they move to this one.
        local other = boxOf(p, pw, true)
        if other and other:GetChildrenCount() > 0 then
            local okO, bo = pcall(scan, other, inPanel(p))
            if okO then
                for _, list in pairs(bo) do for _, w in ipairs(list) do removeWidget(w) end end
            end
        end
    end
    local anyReused = false
    for _, ch in ipairs(p.children) do
        if not ch.removed then
            local ok, res = pcall(attachOne, ch, hostObj, box, byId, reason, report, steps)
            if not ok or not res then
                ch.attached, ch.retryAt = false, tick + RETRY_TICKS
                if not ok then C.warnOnce("attach:" .. ch.id, "attach %s: %s", ch.id, tostring(res):match("^[^\n]*")) end
            elseif ch.lastHow == "reused" then
                anyReused = true
            end
        end
    end
    if anyReused then ensureOrder(p, box) end
    applyGaps(p)
    for _, ch in ipairs(p.children) do
        local w = not ch.removed and liveWidget(ch)
        if w then pcall(P.applyVisibility, ch, w) end
    end
end

-- The journal context (story 19 regions) for one call on a host, or nil on the HUD.
local function ctxFor(host, obj, canvas, prepaint) return host == "journal" and P.journalCtx(obj, canvas, prepaint) or nil end

-- Places every live element of one host: each corner stack (story 19: per region) re-stacks once, near and absolute
-- elements on their own. Journal regions are read at most once (one context). Story 20: prepaint, inside the Journal's
-- Construct (measured regions read as not painted); only (a set of elements, or nil for all): just those, and the
-- corner stacks they are in.
local function placeAll(host, hostObj, canvas, prepass, prepaint, only)
    local live = liveIn(canvas)
    local ctx = ctxFor(host, hostObj, canvas, prepaint)
    local stacks = {}
    for _, el in ipairs(C.order) do
        if not el.removed and el.place.host == host and (only == nil or only[el]) then
            local w = live(el)
            if w then
                if el.place.corner then stacks[P.skeyOf(el.place.corner, el.place.region)] = el.place
                else
                    local ok, err = pcall(P.apply, el, w, hostObj, live, prepass, ctx)
                    if not ok then C.warnOnce("place:" .. el.id, "place '%s' failed: %s", el.id, tostring(err):match("^[^\n]*")) end
                end
            end
        end
    end
    for k, pl in pairs(stacks) do
        local ok, err = pcall(P.restack, host, pl.corner, live, prepass, pl.region, ctx)
        if not ok then C.warnOnce("stack:" .. host .. k, "stacking %s %s failed: %s", host, k, tostring(err):match("^[^\n]*")) end
    end
end

-- Can a size change of this element move another one? Only when a later visible element shares its corner stack
-- (same host, corner and region; the last element's height moves nothing). Near and absolute positions don't depend
-- on the element's own size. A panel's child moves what its panel moves.
local function sizeMatters(el)
    if el.panel then return el.visible and sizeMatters(el.panel) end
    local corner = el.place.corner
    if not corner or not el.visible then return false end
    local after = false
    for _, e in ipairs(C.order) do
        if e == el then after = true
        elseif after and not e.removed and e.visible and e.place.corner == corner and e.place.host == el.place.host
            and e.place.region == el.place.region then return true end
    end
    return false
end

-- Story 12 (debug only): an element's re-place also moves the rest of its corner stack; check them all.
local function checkCorner(host, corner, why, region)
    if not C.debugOn() then return end
    for _, e in ipairs(C.order) do
        if not e.removed and e.place.corner == corner and e.place.host == host and e.place.region == region then D.schedule(e, why) end
    end
end

-- The live object and canvas of a host, or nil.
local function liveHost(host)
    local ad = hostA(host)
    if not ad then return nil end
    local obj = ad.poll()
    if not obj then return nil end
    local canvas = ad.canvas(obj)
    if not canvas then return nil end
    return obj, canvas
end

-- Re-places what one element's change can move: its corner's stack, or the element alone (a child: its panel).
local function replace(el)
    if el.panel then return replace(el.panel) end
    local host = el.place.host
    local obj, canvas = liveHost(host)
    if not obj then return end
    local live = liveIn(canvas)
    local w = live(el)
    local ctx = ctxFor(host, obj, canvas)
    if el.place.corner then
        pcall(P.restack, host, el.place.corner, live, true, el.place.region, ctx)
        checkCorner(host, el.place.corner, "re-stack", el.place.region)
    elseif w then
        local ok, err = pcall(P.apply, el, w, obj, live, true, ctx)
        if not ok then C.warnOnce("place:" .. el.id, "place '%s' failed: %s", el.id, tostring(err):match("^[^\n]*")) end
        if C.debugOn() then D.schedule(el, "re-place") end
    end
end
-- Core story 27: a window's card hugs its content, so screen.lua re-fits it whenever an element on a window is created,
-- removed, shown, hidden, re-texted, re-styled or moved (X._onHostChange, set by screen.lua). host: the element's host
-- before the change. Never raises.
X._onHostChange = nil
local function firstLineOf(e) return (tostring(e):match("^[^\n]*")) end
local function hostChanged(host)
    local f = X._onHostChange
    if not f or type(host) ~= "string" or C.hostKind(host) ~= "screen" then return end
    local ok, err = pcall(f, host)
    if not ok then C.warnOnce("refit " .. host, "re-fitting %s failed: %s", host, firstLineOf(err)) end
end
X._hostChanged = hostChanged
local function resized(el)
    if sizeMatters(el) then replace(el) end
    hostChanged(C.hostOf(el))
end
X._resized = resized

local function restackCorner(host, corner, region)
    if not corner then return end
    checkCorner(host, corner, "re-stack", region)
    local obj, canvas = liveHost(host)
    if obj then pcall(P.restack, host, corner, liveIn(canvas), true, region, ctxFor(host, obj, canvas)) end
end

-- Story 13: the line of the last Journal event, logged on a later tick (an open Journal's, or the next HUD tick once
-- it has closed): a log line costs 0.3-0.8 ms and would double the measured attach.
local journalLog = nil
local function flushJournalLog()
    local l = journalLog
    journalLog = nil
    if l.info then C.log.info("%s", l.text) else C.log.debug("%s", l.text) end
end

-- Elements a host event touches: those on the host, and their panels' children.
local function forHost(host, fn)
    for _, el in ipairs(C.order) do
        if C.hostOf(el) == host then fn(el) end
    end
end

-- UI-1 watcher: the behaviour behind create and place on the HUD (story 10). Only elements with host "hud" (and their
-- panels' children, which their panels attach).
local function onHud(hud, info)
    flushLog()
    if info.event == "attached" then
        local t = C.pt()
        local canvas = HOST.hud.canvas(hud)
        C.pa("core.canvas", t)
        if not canvas then C.warnOnce("nocanvas", "the HUD has no OwningCanvas (%s); elements stay pending", tostring(info.path)) return end
        t = C.pt()
        local okS, byId, orphans = pcall(scan, canvas, onHost("hud"))
        C.pa("core.scan", t)
        if not okS then C.warnOnce("scan", "scanning the HUD canvas failed: %s", tostring(byId)) byId, orphans = {}, {} end
        -- Orphans: widgets tagged with this mod but an id it doesn't know (a hot reload's leftovers, or removed
        -- elements on a HUD that came back), or of an element now on another host or in a panel. Removed, never adopted.
        if #orphans > 0 then
            local ids = {}
            for i, o in ipairs(orphans) do removeWidget(o.w); if i <= 8 then ids[#ids + 1] = o.id end end
            C.log.info("ui removed %d orphan widget(s) of %s from the HUD canvas (ids: %s%s)", #orphans, C.mod, table.concat(ids, ", "), #orphans > 8 and ", ..." or "")
        end
        -- One log line for the whole event, not one per element: a UE4SS log line costs 150-500 us on the game
        -- thread (measured on V8.1.2 with the console enabled). The full report is DEBUG and is only built while
        -- debug is on; an event where an element stayed pending always gets one short INFO line naming them.
        local report = { build = C.debugOn() }
        local pending = nil
        for _, el in ipairs(C.order) do
            if not el.removed and el.place.host == "hud" then
                t = C.pt()
                local ok, res = pcall(attachOne, el, hud, canvas, byId, info.reason, report)
                C.pa("core.attach", t)
                if not ok or not res then
                    el.attached, el.retryAt = false, tick + RETRY_TICKS
                    pending = pending or {}
                    if #pending < 8 then pending[#pending + 1] = "'" .. el.id .. "'" end
                end
                if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) end
                if ok and res and el.children then pending = X._pendingChildren(el, pending) end
            end
        end
        t = C.pt()
        placeAll("hud", hud, canvas, true)
        C.pa("core.placeAll", t)
        -- Logged on the next tick: the line costs 0.3-0.8 ms on V8.1.2 (the attach tick's largest item), so it gets a
        -- tick of its own.
        if pending then
            pendingDebug = false
            pendingLog = string.format("ui attach left %s pending, retried in %d ticks%s (%s)", table.concat(pending, ", "), RETRY_TICKS,
                #report > 0 and ("; attached " .. table.concat(report, ", ")) or "", tostring(info.reason))
        elseif #report > 0 then
            pendingDebug = true
            pendingLog = string.format("ui attach %s (%s)", table.concat(report, ", "), tostring(info.reason))
        end
        attachedThisTick = true
    elseif info.event == "lost" then
        -- Never touch the widgets: there may be none, and the old ones are the game's to clean up.
        local freed = {}
        forHost("hud", function(el)
            el.attached = false
            if el.ref then
                local okD, w = pcall(C.deref, el.ref)
                if okD and w == nil then
                    freed[#freed + 1] = string.format("'%s' %s", el.id, tostring(el.ref))
                    freeRef(el); dropParts(el)
                end
            end
        end)
        if #freed > 0 then C.log.debug("ui widget(s) gone with the HUD; freed handle(s) %s", table.concat(freed, ", ")) end
    elseif info.event == "shown" then
        P.settle("hud") -- children of a HUD that was hidden may only now be measured: re-check stack heights
        if C.debugOn() then for _, el in ipairs(C.order) do D.schedule(el, "HUD shown") end end
    end
    -- hidden: nothing to do; the elements share the HUD's visibility.
end

-- Per tick while a HUD is attached: re-attach an element whose widget is gone or left the canvas (a panel also when
-- one of its children's widgets is gone), follow near elements and settling stacks. Steady state is one native Deref
-- per element: whether a widget is still a child of the live canvas (GetParent, a UFunction call per element) is
-- checked only every MEMBER_TICKS ticks, since nothing but another mod's RemoveFromParent takes it out between HUD
-- events. Nothing runs on the tick that just handled an attached event (the watcher did all of it). Only elements with
-- host "hud".
local MEMBER_TICKS = 10          -- 5 s
-- Liveness within one tick, memoised; emptied at the end of the tick (no widget kept between callbacks). Module-level
-- functions and one reused table: the steady path allocates nothing of its own.
local tickSeen = {}              -- element -> widget | false, this tick only
local tickStrict = nil           -- liveIn(canvas) on a full membership tick, else nil (Deref only)
local function liveNow(el)
    local w = tickSeen[el]
    if w == nil then
        if tickStrict then w = tickStrict(el) or false
        else w = (el.ref and C.deref(el.ref)) or false end
        tickSeen[el] = w
    end
    return w or nil
end
local function endTick()
    for k in pairs(tickSeen) do tickSeen[k] = nil end
    tickStrict = nil
end

local function onTickBody(hud)
    tick = tick + 1
    if attachedThisTick then attachedThisTick = false return end
    if pendingLog then flushLog() C.tickEvent = "attach log" return end
    if journalLog and J._S.path == nil then flushJournalLog() C.tickEvent = "journal log" return end
    local full = tick % MEMBER_TICKS == 0
    local t = C.pt()
    if full then
        local canvas = HOST.hud.canvas(hud)
        if not canvas then return end
        tickStrict = liveIn(canvas)
    end
    local missing = false
    for _, el in ipairs(C.order) do
        if not el.removed and el.place.host == "hud" and (el.retryAt == nil or tick >= el.retryAt) then
            if not liveNow(el) or (el.children ~= nil and childMissing(el)) then missing = true break end
        end
    end
    C.pa(full and "tick.membersFull" or "tick.members", t)
    if missing then
        C.tickEvent = "re-attach"
        t = C.pt()
        local canvas = HOST.hud.canvas(hud)
        if canvas then
            local strict = liveIn(canvas)
            local okS, byId = pcall(scan, canvas, onHost("hud"))
            if not okS then byId = {} end
            local any = false
            for _, el in ipairs(C.order) do
                if not el.removed and el.place.host == "hud" and (el.retryAt == nil or tick >= el.retryAt)
                    and (not strict(el) or (el.children ~= nil and childMissing(el))) then
                    local ok, res = pcall(attachOne, el, hud, canvas, byId, "its widget left the HUD canvas")
                    if not ok or not res then
                        el.retryAt = tick + RETRY_TICKS
                        if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) end
                    else
                        any = true
                    end
                end
            end
            if any then placeAll("hud", hud, canvas, true) end
            endTick()
            tickStrict = strict
        end
        C.pa("tick.reattach", t)
    end
    t = C.pt()
    P.tick("hud", hud, liveNow)
    C.pa("tick.place", t)
end

local function onTick(hud)
    local ok, err = pcall(onTickBody, hud)
    endTick()
    if not ok then error(err, 0) end
    X._ensureConstructHook() -- story 20: a no-op once checked for this HUD
end

-- ---------------------------------------------------------------- the Journal host (story 13)
-- Each open is a new Journal_C: every journal element gets a new widget in the map page's canvas (a panel's children
-- in its box), then placement. The attach is timed with the microsecond clock (story 13 AC 6: under 2 ms on the game
-- thread), per step since story 14: the canvas lookup, each element (its Create call apart; a panel's own time without
-- its children), and the placement. It is reported in one line on the next tick (a log line costs 0.3-0.8 ms; it
-- would double the measured work): DEBUG when all attached, INFO when an element stayed pending.
local function stepsText(s)
    local parts = { string.format("canvas %d", s.canvas) }
    local inPanelUs = {}
    for _, it in ipairs(s.items) do
        if it.panel then inPanelUs[it.panel] = (inPanelUs[it.panel] or 0) + it.us end
    end
    for _, it in ipairs(s.items) do
        local extra = { string.format("create %d", it.create) }
        if it.panel then extra[#extra + 1] = "in '" .. it.panel .. "'" end
        if inPanelUs[it.id] then extra[#extra + 1] = string.format("own %d", it.us - inPanelUs[it.id]) end
        parts[#parts + 1] = string.format("'%s' %d (%s)", it.id, it.us, table.concat(extra, ", "))
    end
    parts[#parts + 1] = string.format("place %d", s.place)
    return table.concat(parts, "; ")
end
X._stepsText = stepsText

-- Story 20: Journals whose elements were attached in their Construct post-hook, by path: what that attach did, for the
-- attach line written at the poll's opened. Cleared at that Journal's closed / lost; an opened forgets the others.
local constructed = {}
local inHook = false             -- inside the Construct hook: classes from the cache only (classOf), no hook registered
-- Story 21: or inside the menu's Construct. Core story 37: or inside core's dispatch work and a dependent's callback
-- from a control's hook (C.inDispatch, common.lua C.callDependent).
function X._inHook() return inHook or M._inHook == true or C.inDispatch > 0 end
inHookNow = X._inHook

-- Attaches the journal elements into the Journal's canvas (story 13; shared by the Construct hook and opened since
-- story 20). skipLive: leave elements whose widget is already live in this canvas (with all their panel children)
-- alone. Returns n (elements, panel children included), pending ids (or nil), the report and per-element steps, and
-- the set of elements it attached (for placement).
local function liveChildrenMissing(p)
    for _, ch in ipairs(p.children) do
        if not ch.removed then
            if not liveWidget(ch) then return true end
            if ch.children and liveChildrenMissing(ch) then return true end
        end
    end
    return false
end
-- A container's children (any depth) after its attach: counted, marked with the host object's path, and the ones
-- left pending listed (retried at the next open, not RETRY_TICKS later).
local function noteChildren(p, jpath, n, pending)
    for _, ch in ipairs(p.children) do
        if not ch.removed then
            n = n + 1
            if ch.attached then
                ch.jpath = jpath
                if ch.children then n, pending = noteChildren(ch, jpath, n, pending) end
            else
                ch.retryAt = nil
                pending = pending or {}
                if #pending < 8 then pending[#pending + 1] = "'" .. ch.id .. "'" end
            end
        end
    end
    return n, pending
end
-- Story 21: the same for any host whose object is new on each open (the journal, the menu, a window): host is its key.
local function attachHostEls(host, obj, canvas, byId, reason, skipLive, jpath)
    local report = { build = C.debugOn() }
    local steps = {}
    local n, pending, did = 0, nil, {}
    local live = liveIn(canvas)
    for _, el in ipairs(C.order) do
        -- core story 32: an element in a game container attaches in the insert pass for its container
        if not el.removed and el.place.host == host and not el.place.container then
            n = n + 1
            if not (skipLive and live(el) and not (el.children ~= nil and liveChildrenMissing(el))) then
                local ok, res = pcall(attachOne, el, obj, canvas, byId, reason, report, steps)
                if not ok or not res then
                    el.attached = false
                    pending = pending or {}
                    if #pending < 8 then pending[#pending + 1] = "'" .. el.id .. "'" end
                else
                    did[el] = true
                    el.jpath = jpath
                end
                if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) end
            end
            if el.children then n, pending = noteChildren(el, jpath, n, pending) end
        end
    end
    return n, pending, report, steps, did
end
local function attachJournal(j, canvas, byId, reason, skipLive, jpath)
    return attachHostEls("journal", j, canvas, byId, reason, skipLive, jpath)
end

local function attachLine(n, dt, s, report, pending, reason)
    if pending then
        return { info = true, text = string.format("ui journal attach left %s pending until the next open (%d element(s), %d us)", table.concat(pending, ", "), n, dt) }
    elseif C.debugOn() then
        return { text = string.format("ui journal attach n=%d in %d us (%s): %s (%s)", n, dt, stepsText(s), table.concat(report, ", "), tostring(reason)) }
    end
    return nil
end

local probeLine -- story 20's probe, below
local function onJournal(j, info)
    if info.event == "opened" then
        local okP, errP = pcall(probeLine, info) -- debug only; never stops the attach
        if not okP then C.warnOnce("journal probe", "journal probe line failed: %s", tostring(errP):match("^[^\n]*")) end
        X._ensureConstructHook() -- story 20: when no HUD tick has checked it yet
        if journalLog then flushJournalLog() end -- an earlier event's line goes first
        local t0 = C.micros()
        local canvas = J._canvasOf(j)
        if not canvas then return end -- J._canvasOf warned once; the elements stay pending until the next open
        local tCanvas = C.micros() - t0
        local cons = constructed[info.path]
        for p in pairs(constructed) do if p ~= info.path then constructed[p] = nil end end
        if cons then
            -- Story 20: attached in Construct, before the first paint. Its regions are this Journal's already (no
            -- reset), and nothing still live in its canvas is attached or placed again: only what the hook left (a
            -- class that wasn't cached) or what was created since.
            local n, pending, report, steps, did = attachJournal(j, canvas, {}, info.reason, true, info.path)
            local tp = C.micros()
            if next(did) then placeAll("journal", j, canvas, true, false, did) end
            local now = C.micros()
            local line
            if pending then line = attachLine(n, now - t0, nil, nil, pending, info.reason)
            elseif cons.line then
                local extra = #report > 0 and ("; at opened: " .. table.concat(report, ", ") .. " (" .. tostring(info.reason) .. ")") or ""
                line = { info = cons.line.info, text = cons.line.text .. extra }
            elseif next(did) then
                line = attachLine(n, now - t0, { canvas = tCanvas, place = now - tp, items = steps }, report, nil, info.reason)
            end
            if line then journalLog = line; flushJournalLog() end
            return
        end
        P.journalReset() -- story 19: a new Journal; its measured regions are unknown until its first paint
        -- A new Journal holds none of our widgets, so nothing is scanned. Only when the same Journal comes back
        -- (never seen on V8.1.2) are its children scanned for our tags, so nothing is duplicated.
        local byId = {}
        if info.reopened then
            local okS, b, orphans = pcall(scan, canvas, onHost("journal"))
            if okS then
                byId = b
                for _, o in ipairs(orphans) do removeWidget(o.w) end
            end
        end
        local n, pending, report, steps = attachJournal(j, canvas, byId, info.reason, false, info.path)
        if n == 0 then return end
        local tp = C.micros()
        placeAll("journal", j, canvas, true)
        local now = C.micros()
        local dt = now - t0
        local s = { canvas = tCanvas, place = now - tp, items = steps }
        J._recordAttach(dt, n, s)
        -- Story 20: written now, so the next journal tick reads regions (it used to wait for a tick of its own).
        journalLog = attachLine(n, dt, s, report, pending, info.reason)
        if journalLog then flushJournalLog() end
    else
        -- closed or lost: the Journal is out of the viewport for good (each open is a new one). Its widgets are never
        -- touched, only our handles to them are freed; the elements keep their state for the next open. Story 20: a
        -- newer Journal already attached in its Construct (opened on the next tick) keeps its elements and regions.
        local newer = nil
        for p in pairs(constructed) do if p ~= info.path then newer = p end end
        constructed[info.path] = nil
        local freed = 0
        if not newer then P.journalReset() end
        forHost("journal", function(el)
            if newer and el.jpath == newer and el.ref then return end
            if el.ref then freed = freed + 1 end
            freeRef(el); dropParts(el)
            el.attached, el.slotKey, el.appliedVis, el.stackHeight, el.padKey = false, nil, nil, nil, nil
            el.nearRect, el.jpath = nil, nil
        end)
        if freed > 0 and C.debugOn() then journalLog = { text = string.format("ui journal %s: freed %d widget handle(s) (%s)", info.event, freed, tostring(info.reason)) } end
    end
end

-- Story 20: the Construct post-hook's attach (body of onConstruct, under pcall there). Only a live Journal_C of a
-- local controller with its map canvas; then every journal element whose class is cached, placed with the pre-paint
-- rules (exact regions and the computed map; content-sized regions collapsed until measured). Calls no dependent's
-- code; journal.watch events stay on the poll.
local function constructAttach(j, canvas, path)
    local t0 = C.micros()
    J._track(path, j)
    local again = constructed[path] ~= nil
    P.journalReset() -- this Journal's regions: the computed map, content-sized ones unknown until painted
    local byId = {}
    if again then -- a second Construct of the same Journal: reuse what is there, never a second widget
        local okS, b, orphans = pcall(scan, canvas, onHost("journal"))
        if okS then
            byId = b
            for _, o in ipairs(orphans) do removeWidget(o.w) end
        end
    end
    local tCanvas = C.micros() - t0
    inHook = true
    local ok, n, pending, report, steps = pcall(attachJournal, j, canvas, byId, "construct", false, path)
    inHook = false
    if not ok then error(n, 0) end
    local tp = C.micros()
    placeAll("journal", j, canvas, true, true)
    local now = C.micros()
    local dt = now - t0
    local s = { canvas = tCanvas, place = now - tp, items = steps }
    J._recordAttach(dt, n, s)
    -- Pending ones (a class not cached) are attached at opened; the line is written there.
    constructed[path] = { line = not pending and attachLine(n, dt, s, report, nil, "construct") or nil }
end

local function liveRef(el) return el.ref and C.deref(el.ref) or nil end
local function onJournalTick(j)
    if journalLog then flushJournalLog() end -- story 20: the flush no longer takes the tick's place work
    X._probeTick(j)
    -- Corner stacks re-measured for a few ticks after the open (Slate measures late); story 19: measured regions
    -- re-read until valid, then every 4 ticks.
    P.tick("journal", j, liveRef)
end

-- ---------------------------------------------------------------- story 20: the Journal's Construct post-hook
-- Registered from a poll tick (never inside a hook), once a journal element exists and AssetRegistryHelpers:GetAsset
-- returned the Journal class, keyed by the function's address: a class reloaded after a map change is hooked again
-- (re-checked when a new HUD is prepared). A failed registration logs one WARN; the poll path keeps working.
local CONSTRUCT_FN = C.JOURNAL_CLASS .. ":Construct"
local JH = { key = nil, checked = false, tries = 0 }
X._pollHooks = {}                -- fn() run with the Construct hook check (button.lua: its click hook)
local onConstruct                -- below

local function anyJournalElement()
    for _, el in ipairs(C.order) do
        if not el.removed and C.hostOf(el) == "journal" then return true end
    end
    return false
end

local function ensureConstructHook()
    if JH.checked or not anyJournalElement() then return end
    JH.checked = true
    for _, f in ipairs(X._pollHooks) do pcall(f) end
    local helpers = C.found("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    local okA, cls = pcall(function()
        return helpers:GetAsset({ PackageName = FName(C.JOURNAL_PKG), AssetName = FName(C.JOURNAL_SHORT) })
    end)
    if not (okA and C.valid(cls)) then return end -- not loaded: retried on the next prepared HUD (never per tick: a miss scans every object)
    local fn = C.found(CONSTRUCT_FN)
    if not fn then return end
    local okK, key = pcall(C.addr, fn)
    if not okK then return end
    if JH.key == key then return end
    JH.tries = JH.tries + 1
    local okH, err = pcall(RegisterHook, CONSTRUCT_FN, function(ctx) onConstruct(ctx) end)
    if okH then
        JH.key = key
        if C.log then C.log.debug("ui journal Construct hook registered on %s", CONSTRUCT_FN) end
    else
        C.warnOnce("construct hook", "journal elements: RegisterHook(%s) failed: %s; they attach when the poll sees the Journal", CONSTRUCT_FN, tostring(err):match("^[^\n]*"))
    end
end
X._ensureConstructHook = ensureConstructHook
function X._constructHook() return { key = JH.key, checked = JH.checked, tries = JH.tries } end
function X._constructHookRecheck() JH.checked = false end -- tests: what a new HUD's prepare does

-- The probe (story 20's gate; DEBUG only): what the hook saw, logged at the poll's opened, then the drawn map and
-- canvas on the first 4 journal ticks.
local probe = nil
probeLine = function(info)
    local p = probe
    if not (p and C.debugOn()) then return end
    if p.path ~= info.path then return end
    local i = p.inputs
    C.log.debug("JPROBE construct inViewport=%s hdr=%s canvas=%s map=%s%s; opened %d us after Construct",
        tostring(p.inVp), i and string.format("%.2f", i.hdr) or "?", i and string.format("%.1fx%.1f", i.W, i.H) or "?",
        p.rect and P._rectStr(p.rect) or "?", p.why and (" (" .. tostring(p.why) .. ")") or "", C.micros() - p.us)
    p.ticks = 0
end
function X._probeTick(j)
    local p = probe
    if not (p and p.ticks and p.ticks < 4 and C.debugOn()) then return end
    p.ticks = p.ticks + 1
    local canvas = J._canvasOf(j)
    if not canvas then return end
    local ctx = P.journalCtx(j, canvas)
    local okM, mu = pcall(function() return j.MapWidget.MapUI end)
    local m = okM and C.valid(mu) and P._rectIn(ctx, mu) or nil
    local c = P._rectIn(ctx, canvas)
    C.log.debug("JPROBE tick %d drawn map=%s canvas=%s", p.ticks, m and P._rectStr(m) or "?", c and P._rectStr(c) or "?")
end

local function constructBody(ctx)
    local j = ctx:get()
    if not C.valid(j) then return end
    local okN, cn = pcall(function() return j:GetClass():GetFName():ToString() end)
    if not (okN and cn == C.JOURNAL_SHORT) then return end
    local okO, pc = pcall(C.call0, j, "GetOwningPlayer")
    if not (okO and C.valid(pc)) then return end
    local okL, isLocal = pcall(C.call0, pc, "IsLocalController")
    if not (okL and isLocal == true) then return end
    if not anyJournalElement() then return end
    local canvas = J._canvasOf(j)
    if not canvas then return end
    local us = C.micros()
    local path = C.pathOf(j)
    constructAttach(j, canvas, path)
    if C.debugOn() then
        local okV, inVp = pcall(C.call0, j, "IsInViewport")
        local pctx = P.journalCtx(j, canvas, true)
        local r, why = P._computedMap(pctx)
        probe = { path = path, us = us, inVp = okV and inVp, inputs = pctx.mapInputs, rect = r, why = why }
    end
end

onConstruct = function(ctx)
    local ok, err = pcall(constructBody, ctx)
    if not ok then C.warnOnce("construct body", "journal Construct hook failed: %s; the poll attaches that Journal's elements", tostring(err):match("^[^\n]*")) end
end

local journalWatching = false
local function ensureJournal()
    if journalWatching then return end
    journalWatching = true
    J._watch(onJournal)
    J._ticker(onJournalTick)
end

local function ensureWatching()
    if watching then return end
    watching = true
    H._watch(onHud)
    H._ticker(onTick)
    -- The widget classes are loaded again after a map change (nothing keeps them alive): do that on the tick before
    -- the attach, for every kind in use.
    H._prepare(function()
        local need = {}
        for _, el in ipairs(C.order) do need[el.kind] = true end
        for kind in pairs(need) do classOf(kind) end
        JH.checked = false -- story 20: a new HUD (often a new world): is the Journal class the hooked one?
        ensureConstructHook()
    end)
end
local ensureMenu -- story 21, below
local ensureGame -- core story 31, below
local function ensureHost(el)
    ensureWatching()
    local host = C.hostOf(el)
    if host == "journal" then ensureJournal()
    elseif C.gameScreen(host) then ensureGame(host) -- core story 31
    elseif C.gameHost(host) then ensureMenu() end
    -- Story 21: the game look's assets are loaded in this state's LoadMap post-hook from now on.
    if C.gameHost(host) or (el.style and el.style.look == "game") then A.ensureLoadMapHook() end
end
X._ensureHost = ensureHost

-- Attaches one element now when its host is live (create, or place on a pending element). A container's child attaches
-- into its container's box when the container's widget is live; otherwise it waits for its container.
local function attachNow(el, reason)
    if el.panel then
        local p = el.panel
        local pw = liveWidget(p)
        if not pw then return end
        local obj = liveHost(C.hostOf(p))
        if not obj then return end
        local box = boxOf(p, pw)
        if not box then return end
        local ok, res = pcall(attachOne, el, obj, box, {}, reason)
        if not ok or not res then el.retryAt = tick + RETRY_TICKS end
        if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) return end
        if not res then return end
        ensureOrder(p, box) -- appended at the end; anywhere else in the order, the box is rebuilt
        applyGaps(p)
        local w = liveWidget(el)
        if w then pcall(P.applyVisibility, el, w) end
        resized(p)
        return
    end
    local host = el.place.host
    -- Core story 32: an element in a game container attaches by the insert pass for its container, on the host's next
    -- poll tick (never inside the dependent's call, so never inside a hook it calls from); the poll's opened runs it too.
    if el.place.container then
        X._queueInsert(host, el.place.container)
        return
    end
    local obj, canvas = liveHost(host)
    if not obj then return end
    local byId = {}
    if host == "hud" then
        local okS, b = pcall(scan, canvas, onHost("hud"))
        if okS then byId = b end
    end
    local ok, res = pcall(attachOne, el, obj, canvas, byId, reason)
    if not ok or not res then el.retryAt = tick + RETRY_TICKS end
    if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) return end
    if res then placeAll(host, obj, canvas, true) end
end
X._attachNow = attachNow

-- Core story 37: the UI tick (outside any hook) attaches the elements deferred from a dependent's callback (each one not
-- removed and not live yet; the class loads normally here), registers a LoadMap hook asked for there, and reloads the
-- window class (a weak handle) while this state has elements on the game's hosts, so a button's onClick can open a window.
local function flushDeferred()
    if X._inHook() then return nil end
    if A._loadMapWanted() then A.ensureLoadMapHook() end
    if #deferred.list > 0 then
        local items = deferred.list
        deferred.list, deferred.set = {}, {}
        for _, el in ipairs(items) do
            if not el.removed and not liveWidget(el) then attachNow(el, "deferred from a callback") end
        end
    end
    deferSync()
    for _, el in ipairs(C.order) do
        if not el.removed and C.gameHost(C.hostOf(el)) then classOf("screen") break end -- menu, windows, game screens
    end
    return nil
end
H._host{ poll = function() end, reset = function() end, dispatch = flushDeferred }
X._flushDeferred = flushDeferred -- unit tests
X._deferred = function() return #deferred.list, deferKeep end -- unit tests

-- ---------------------------------------------------------------- story 21: the menu host and the windows
-- Like the Journal: every menu is new (each return from a match builds one), so its elements get new widgets on each
-- from the poll's opened, within about a second (one or two 500 ms ticks) of the menu appearing (never inside
-- MainMenu_C:Construct, story 34), and on lost only their handles are freed. While the menu is hidden (opacity 0
-- under Create Server, another page) its elements are collapsed.

-- Frees the handles of every element on a host (children included) and marks them detached; never touches widgets
-- (they went with their host). keepPath: elements attached to this host object stay (a newer menu's).
local function releaseHost(host, keepPath)
    local freed = 0
    forHost(host, function(el)
        if keepPath and el.jpath == keepPath and el.ref then return end
        if el.ref then freed = freed + 1 end
        freeRef(el); dropParts(el)
        el.attached, el.slotKey, el.appliedVis, el.stackHeight, el.padKey = false, nil, nil, nil, nil
        el.nearRect, el.jpath, el.sizeKey, el.matBg, el.gameText = nil, nil, nil, nil, nil
        el.selBg, el.faceOn = nil, nil -- core story 28: the focus highlight and face went with the widget
        if el.appliedEnabled ~= nil then el.appliedEnabled = nil end
    end)
    return freed
end

-- Re-applies the wanted visibility of a host's top-level elements (the host was hidden or shown).
local function revisit(host)
    for _, el in ipairs(C.order) do
        if not el.removed and el.place.host == host then
            local w = liveWidget(el)
            if w then
                el.appliedVis = nil
                local ok, err = pcall(P.applyVisibility, el, w)
                if not ok then C.warnOnce("vis:" .. el.id, "%s '%s': SetVisibility failed: %s", el.kind, el.id, tostring(err):match("^[^\n]*")) end
            end
        end
    end
end

-- The poll's events for the menu host.
local function onMenu(m, info)
    if info.event == "opened" then
        local canvas = M._canvasOf(m)
        if not canvas then return end -- _canvasOf warned once; the host stays closed (the entry still inserts)
        local t0 = C.micros()
        local n, pending, report, _, did = attachHostEls("menu", m, canvas, {}, info.reason, false, info.path)
        if n == 0 then return end
        if next(did) then placeAll("menu", m, canvas, true, false) end
        if info.hidden then revisit("menu") end
        if pending then
            C.log.info("ui menu attach left %s pending until the next menu (%d element(s))", table.concat(pending, ", "), n)
        elseif C.debugOn() then
            C.log.debug("ui menu attach n=%d in %d us: %s (%s)", n, C.micros() - t0, table.concat(report, ", "), tostring(info.reason))
        end
    elseif info.event == "hidden" or info.event == "shown" then
        revisit("menu")
        if info.event == "shown" then P.settle("menu") end
    elseif info.event == "lost" then
        local freed = releaseHost("menu", nil)
        if freed > 0 and C.debugOn() then C.log.debug("ui menu lost: freed %d widget handle(s) (%s)", freed, tostring(info.reason)) end
    end
end

local function onMenuTick(m)
    P.tick("menu", m, function(el) return el.ref and C.deref(el.ref) or nil end)
end

local menuWatching = false
ensureMenu = function()
    if menuWatching then return end
    menuWatching = true
    M._watch(onMenu)
    M._ticker(onMenuTick)
end

-- A window opened (screen.lua): every element on it gets a widget in its canvas, then placement.
function X._attachHost(host, obj, canvas, reason)
    local n, pending = attachHostEls(host, obj, canvas, {}, reason, false, nil)
    if n > 0 then placeAll(host, obj, canvas, true) end
    if pending then C.log.info("ui %s attach left %s pending (%d element(s))", host, table.concat(pending, ", "), n) end
    return n
end
-- A window closed or lost (screen.lua): its elements' handles are freed; they keep their state for the next open.
function X._detachHost(host) return releaseHost(host) end
-- Per menu tick for an open window: corner stacks still settling.
function X._tickHost(host, obj)
    P.tick(host, obj, function(el) return el.ref and C.deref(el.ref) or nil end)
end
X._ensureMenu = function() ensureMenu() end

-- ---------------------------------------------------------------- core story 32: insert into a game container
-- An element placed { host = <game screen>, container = <name>, after | before | index | at } lives in one of the game's
-- own boxes (a VerticalBox, HorizontalBox or ScrollBox), found by name in the open screen's widget tree (a bounded
-- walk). Box panels only append (InsertChildAt isn't reflected), so the insert pass attaches every element of the box,
-- works out the wanted order (P.insertOrder: positions count the game's children only), and rebuilds the box once:
-- from the first child out of order, every child is removed and added back in the wanted order, each game child with
-- its saved slot values (padding, size, alignment; plain Lua values). Nothing is rebuilt when the order is right. The
-- game's children are never changed otherwise. Another mod's core widgets in the box follow the game child before them.
-- Runs at the poll's opened, and on the host's next poll tick after a dependent's create / place while the screen is
-- open (queued, one pass per container per tick however many calls; never inside the dependent's call, so never inside
-- a hook it calls from). A re-added game row's Blueprint pickers (MultipleSelectBox_C) run their PreConstruct again,
-- which puts back their default option, so the pass reads each picker's selected index before taking the row out and
-- sets it again after the re-add (SetSelectedOption: no broadcast, no game handler runs). A missing anchor puts the
-- element at the end and a missing container leaves it pending until the next open, each with one WARN for the life
-- of the Lua state.
local INSERT_CLASSES = { VerticalBox = true, HorizontalBox = true, ScrollBox = true }
local INSERT_CLASS_NAMES = "a VerticalBox, HorizontalBox or ScrollBox"
local WALK_MAX, WALK_DEPTH = 4096, 32
-- The pickers inside one game row: at most PICK_WALK widgets and PICK_DEPTH levels are looked at.
local PICKER_CLASS = "MultipleSelectBox_C"
local PICK_WALK, PICK_DEPTH = 64, 8
-- host -> { path = <the screen's path>, refs = { name -> weak handle of the box }, missing = { name -> why } }
local boxCache = {}

local function widgetNameOf(w)
    local ok, n = pcall(function() return w:GetFName():ToString() end)
    return ok and type(n) == "string" and n or nil
end
local function classNameOf(w)
    local ok, n = pcall(function() return w:GetClass():GetFName():ToString() end)
    return ok and type(n) == "string" and n or nil
end
local function childCountOf(w)
    local ok, n = pcall(function() return w:GetChildrenCount() end)
    return ok and tonumber(n) or 0
end
local function childAt(w, i)
    local ok, c = pcall(function() return w:GetChildAt(i) end)
    return ok and C.valid(c) and c or nil
end

-- The widgets named in want (name -> true; left of them), depth-first from root in child order: the first of each name.
-- At most WALK_MAX widgets and WALK_DEPTH levels; user widgets inside (a picker) are not entered (no children).
local function findNamed(root, want, left)
    local found = {}
    local ws, ds = { root }, { 0 }
    local seen = 0
    while #ws > 0 and left > 0 do
        local w, d = ws[#ws], ds[#ds]
        ws[#ws], ds[#ds] = nil, nil
        seen = seen + 1
        if seen > WALK_MAX then
            C.warnOnce("insert walk", "ui: the open screen has more than %d widgets; containers past them are not found", WALK_MAX)
            break
        end
        local nm = widgetNameOf(w)
        if nm and want[nm] and not found[nm] then found[nm] = w; left = left - 1 end
        if d < WALK_DEPTH then
            for i = childCountOf(w) - 1, 0, -1 do
                local c = childAt(w, i)
                if c then ws[#ws + 1], ds[#ds + 1] = c, d + 1 end
            end
        end
    end
    return found
end

local function dropBoxes(host)
    local bc = boxCache[host]
    if not bc then return end
    for _, r in pairs(bc.refs) do pcall(C.free, r) end
    for _, r in pairs(bc.like) do pcall(C.free, r) end -- core story 33
    boxCache[host] = nil
end

-- The cache of the open screen s (a new one per screen). Core story 33: like rows (name -> weak handle) and like names
-- not found (name -> true) are kept there too, until the next open.
local function cacheOf(host, s)
    local sp = C.pathOf(s)
    local bc = boxCache[host]
    if not bc or bc.path ~= sp then
        dropBoxes(host)
        bc = { path = sp, refs = {}, missing = {}, like = {}, likeMissing = {} }
        boxCache[host] = bc
    end
    return bc
end

-- Core story 33: the widget named name on the open screen s (any class; valid only in this callback), or nil. Found
-- once per open (the bounded walk) and kept as a weak handle; a name not found is not looked for again in that open.
local function namedOf(host, s, name)
    local bc = cacheOf(host, s)
    local r = bc.like[name]
    if r then
        local okD, w = pcall(C.deref, r)
        if okD and w then return w end
        pcall(C.free, r); bc.like[name] = nil
    end
    if bc.likeMissing[name] then return nil end
    local root = G._rootOf(host, s)
    if not root then return nil end -- no root now (G warned): looked for again later, not remembered as missing
    local w = findNamed(root, { [name] = true }, 1)[name]
    if not w then bc.likeMissing[name] = true return nil end
    local okR, h = pcall(C.ref, w)
    if okR then bc.like[name] = h end
    return w
end

-- The boxes of names (a list) on the open screen s: name -> box (valid only in this callback). Found once per open
-- and kept as weak handles; a name not found (or not a box) is remembered as missing until the next open.
local function boxesOf(host, s, names)
    local bc = cacheOf(host, s)
    local out, want, left = {}, {}, 0
    for _, nm in ipairs(names) do
        local r = bc.refs[nm]
        local okD, w = pcall(C.deref, r)
        if r and okD and w then out[nm] = w
        elseif not bc.missing[nm] then
            if r then pcall(C.free, r); bc.refs[nm] = nil end
            want[nm] = true
            left = left + 1
        end
    end
    if left > 0 then
        local root = G._rootOf(host, s)
        local found = root and findNamed(root, want, left) or {}
        for nm in pairs(want) do
            local w = found[nm]
            local cls = w and classNameOf(w)
            if w and INSERT_CLASSES[cls] then
                out[nm] = w
                local okR, h = pcall(C.ref, w)
                if okR then bc.refs[nm] = h end
            else
                bc.missing[nm] = w and { notBox = tostring(cls) } or { why = "no widget of that name is in the open screen" }
            end
        end
    end
    return out, bc.missing
end

-- A box child's slot values (plain numbers; nil for what can't be read).
local function saveSlot(w)
    local okS, s = pcall(C.prop, w, "Slot")
    if not (okS and s ~= nil) then return nil end
    local v = {}
    pcall(function()
        local p = s.Padding
        local m = { Left = tonumber(p.Left), Top = tonumber(p.Top), Right = tonumber(p.Right), Bottom = tonumber(p.Bottom) }
        if m.Left and m.Top and m.Right and m.Bottom then v.pad = m end
    end)
    pcall(function()
        local z = s.Size
        local r, val = tonumber(z.SizeRule), tonumber(z.Value)
        if r and val then v.size = { SizeRule = r, Value = val } end
    end)
    pcall(function() v.ha = tonumber(s.HorizontalAlignment) end)
    pcall(function() v.va = tonumber(s.VerticalAlignment) end)
    return v
end
local function restoreSlot(w, v, name)
    local okS, s = pcall(C.prop, w, "Slot")
    if not (okS and s ~= nil) then return end
    local function set(fn, arg)
        if arg == nil then return end
        local ok, err = pcall(function() C.count(); s[fn](s, arg) end)
        if not ok then C.warnOnce("insert slot " .. name .. fn, "ui: restoring a game child's %s in '%s' failed: %s", fn, name, firstLineOf(err)) end
    end
    set("SetPadding", v.pad)
    set("SetSize", v.size)
    set("SetHorizontalAlignment", v.ha)
    set("SetVerticalAlignment", v.va)
end

-- The Blueprint pickers (MultipleSelectBox_C) inside a game child, with their selected index (0-based; plain numbers;
-- the widgets are used only within this pass). A bounded walk through panels; user widgets are not entered.
local function pickersOf(c)
    local out = {}
    local ws, ds = { c }, { 0 }
    local seen = 0
    while #ws > 0 and seen < PICK_WALK do
        local w, d = ws[#ws], ds[#ds]
        ws[#ws], ds[#ds] = nil, nil
        seen = seen + 1
        if classNameOf(w) == PICKER_CLASS then
            local ok, i = pcall(function() C.count(); return w:GetSelectedIndex() end)
            i = ok and math.tointeger(tonumber(i)) or nil
            if i and i >= 0 then out[#out + 1] = { w = w, index = i } end
        elseif d < PICK_DEPTH then
            for k = childCountOf(w) - 1, 0, -1 do
                local ch = childAt(w, k)
                if ch then ws[#ws + 1], ds[#ds + 1] = ch, d + 1 end
            end
        end
    end
    return out
end
-- After a re-add: each picker back on the index it had (only when its PreConstruct changed it).
local function restorePickers(list, name)
    for _, pk in ipairs(list) do
        local okR, now = pcall(function() C.count(); return pk.w:GetSelectedIndex() end)
        if not (okR and math.tointeger(tonumber(now)) == pk.index) then
            local ok, err = pcall(function() C.count(); pk.w:SetSelectedOption(pk.index) end)
            if ok then C.stats.pickerRestores = (C.stats.pickerRestores or 0) + 1
            else C.warnOnce("insert picker " .. name, "ui: putting back a game picker's option in '%s' failed: %s", name, firstLineOf(err)) end
        end
    end
end

-- A box child's core tag (any mod's), or nil for a game widget.
local function coreTagOf(c)
    local kind = kindOfClass(classNameOf(c) or "")
    if not kind then return nil end
    local t = readTag(c, kind)
    if t and t:sub(1, #TAG_PREFIX) == TAG_PREFIX then return t end
    return nil
end

-- ---------------------------------------------------------------- core story 33: game-style rows
-- A row made with like = <game row name> (row.lua) is still core's tagged WBP_<Core>Row (Border "Background" ->
-- HorizontalBox "HBox"), on a game screen only. Inside HBox core builds native UMG widgets (StaticConstructObject in the
-- row's WidgetTree): a label TextBlock and an inner HorizontalBox holding the holder (a HorizontalBox, the row's
-- children box: the control goes there, filling it) and the "?" TextBlock, and a Spacer as tall as the game row's background image (a Border ignores its brush's size). At every attach it reads the named game row on the open
-- screen and copies its look: the background Image's brush and tint to the Border (SetBrush, SetBrushColor), the
-- game HorizontalBox's overlay slot to the Border's padding and content alignment, the label's and the "?"'s font,
-- colour and justification, and every inner slot (label, inner box, the game control's slot to the holder, "?"); in
-- a game container, the row's own slot gets the like row's slot values (the insert pass). Nothing is kept between
-- ticks but plain values; no game widget is changed. A like name that isn't a game row (an Overlay holding an Image and
-- a HorizontalBox; in that, a TextBlock then a HorizontalBox, whose first non-TextBlock child is the control and last
-- TextBlock the "?") gives core's game look instead (the worn strip, the body font in the menu's text colour), with
-- one WARN naming it per Lua state. help goes on the "?" in the game's tooltip widget (W_ToolTip3_C, created with
-- WidgetBlueprintLibrary:Create, its Description set), once per attach and per help or language change, never per
-- hover; when that class can't be loaded, as plain tooltip text (assets.lua's one WARN).
local LIKE_LABEL, LIKE_INNER, LIKE_HOLDER, LIKE_HELP, LIKE_HEIGHT = C.NAME .. "LikeLabel", C.NAME .. "LikeInner", C.NAME .. "LikeHolder", C.NAME .. "LikeHelp", C.NAME .. "LikeHeight"
local UMG_TEXT, UMG_HBOX, UMG_SPACER = "/Script/UMG.TextBlock", "/Script/UMG.HorizontalBox", "/Script/UMG.Spacer"
local KSL_CDO = "/Script/Engine.Default__KismetSystemLibrary"
local SIZE_RULE_AUTO, SIZE_RULE_FILL, VALIGN_CENTER = 0, 1, 2
local likeSeq = 0

-- Our row's parts { hbox, label, inner, holder, help } (valid only in this callback), or nil when not built.
local function likeParts(w)
    local ok, r = pcall(function()
        local hb = w.HBox
        if not C.valid(hb) or hb:GetChildrenCount() < 2 then return nil end
        local lbl, inner = hb:GetChildAt(0), hb:GetChildAt(1)
        if not (C.valid(lbl) and C.valid(inner)) then return nil end
        if (widgetNameOf(lbl) or ""):find(LIKE_LABEL, 1, true) ~= 1 then return nil end
        if inner:GetChildrenCount() < 2 then return nil end
        local holder, q = inner:GetChildAt(0), inner:GetChildAt(1)
        if not (C.valid(holder) and C.valid(q)) then return nil end
        local h = hb:GetChildrenCount() > 2 and hb:GetChildAt(2) or nil
        return { hbox = hb, label = lbl, inner = inner, holder = holder, help = q, height = C.valid(h) and h or nil }
    end)
    return ok and r or nil
end
X._likeParts = likeParts

local function newUmg(path, outer, base)
    local cls = C.found(path)
    if not cls then error(path .. " is not there", 0) end
    likeSeq = likeSeq + 1
    C.count()
    local o = StaticConstructObject(cls, outer, FName(base .. "_" .. likeSeq))
    if not C.valid(o) then error("constructing " .. path .. " failed", 0) end
    return o
end

-- Builds the parts into a row widget's HBox (a fresh widget holds none).
local function buildLike(w)
    local okT, tree = pcall(C.prop, w, "WidgetTree")
    local outer = (okT and C.valid(tree)) and tree or w
    local hb = w.HBox
    local lbl = newUmg(UMG_TEXT, outer, LIKE_LABEL)
    local inner = newUmg(UMG_HBOX, outer, LIKE_INNER)
    local holder = newUmg(UMG_HBOX, outer, LIKE_HOLDER)
    local q = newUmg(UMG_TEXT, outer, LIKE_HELP)
    local height = newUmg(UMG_SPACER, outer, LIKE_HEIGHT)
    C.count(); hb:AddChild(lbl)
    C.count(); hb:AddChild(inner)
    C.count(); hb:AddChild(height) -- no width; its height is the background image's (copyLook)
    C.count(); inner:AddChild(holder)
    C.count(); inner:AddChild(q)
    C.count(); lbl:SetVisibility(C.VIS.SelfHitTestInvisible)
    C.count(); inner:SetVisibility(C.VIS.SelfHitTestInvisible)
    C.count(); holder:SetVisibility(C.VIS.SelfHitTestInvisible)
    C.count(); q:SetText(FText("?"))
    C.count(); q:SetVisibility(C.VIS.Hidden) -- shown (Visible, for the hover) once there is help; Hidden keeps its space
    return { hbox = hb, label = lbl, inner = inner, holder = holder, help = q, height = height }
end

-- The parts of a game row src (valid only in this callback), or nil and why it isn't one (Design Note 3).
local function gameRowParts(src)
    local cls = classNameOf(src)
    if cls ~= "Overlay" then return nil, "it is a " .. tostring(cls) .. ", not an Overlay" end
    local img, hb
    for i = 0, childCountOf(src) - 1 do
        local c = childAt(src, i)
        local cn = c and classNameOf(c)
        if cn == "Image" and not img then img = c elseif cn == "HorizontalBox" and not hb then hb = c end
    end
    if not (img and hb) then return nil, "it holds no Image and HorizontalBox" end
    local lbl, inner
    for i = 0, childCountOf(hb) - 1 do
        local c = childAt(hb, i)
        local cn = c and classNameOf(c)
        if not lbl then
            if cn == "TextBlock" then lbl = c end
        elseif cn == "HorizontalBox" then inner = c break end
    end
    if not (lbl and inner) then return nil, "its HorizontalBox holds no label TextBlock followed by a HorizontalBox" end
    local ctl, q
    for i = 0, childCountOf(inner) - 1 do
        local c = childAt(inner, i)
        local cn = c and classNameOf(c)
        if cn == "TextBlock" then q = c elseif c and not ctl then ctl = c end
    end
    if not (ctl and q) then return nil, "its inner HorizontalBox holds no control and \"?\" TextBlock" end
    return { row = src, image = img, hbox = hb, label = lbl, inner = inner, control = ctl, help = q }
end
X._gameRowParts = gameRowParts

-- One slot's values onto a widget's slot (plain values from saveSlot); what names it in the WARN.
local function copySlot(w, v, el, what)
    if not v then return end
    local okS, s = pcall(C.prop, w, "Slot")
    if not (okS and s ~= nil) then return end
    local function set(fn, arg)
        if arg == nil then return end
        local ok, err = pcall(function() C.count(); s[fn](s, arg) end)
        if not ok then C.warnOnce("like slot " .. el.id .. what .. fn, "row '%s': copying the like row's %s %s failed: %s", el.id, what, fn, firstLineOf(err)) end
    end
    set("SetPadding", v.pad)
    set("SetSize", v.size)
    set("SetHorizontalAlignment", v.ha)
    set("SetVerticalAlignment", v.va)
end

local function copyText(dst, src)
    C.count(); dst:SetFont(src.Font)
    C.count(); dst:SetColorAndOpacity(src.ColorAndOpacity)
    C.count(); dst:SetJustification(src.Justification)
end

-- The like row's look onto our row (raises; the caller falls back).
local function copyLook(el, w, parts, g)
    local bg = w.Background
    C.count(); bg:SetBrush(g.image.Brush)
    C.count(); bg:SetBrushColor(g.image.ColorAndOpacity)
    -- A Border ignores its brush's size, an Image doesn't: the game row is as tall as its background image (the brush's
    -- ImageSize), and its picker's ScaleBox scales to that height, so the row's spacer gets that height.
    if parts.height then
        local hy = tonumber(g.image.Brush.ImageSize.Y)
        C.count(); parts.height:SetSize({ X = 0, Y = hy or 0 })
    end
    local hs = saveSlot(g.hbox) or {}
    C.count(); bg:SetPadding(hs.pad or { Left = 0, Top = 0, Right = 0, Bottom = 0 })
    if hs.ha then C.count(); bg:SetHorizontalAlignment(hs.ha) end
    if hs.va then C.count(); bg:SetVerticalAlignment(hs.va) end
    copyText(parts.label, g.label)
    copyText(parts.help, g.help)
    copySlot(parts.label, saveSlot(g.label), el, "label")
    copySlot(parts.inner, saveSlot(g.inner), el, "inner box")
    copySlot(parts.holder, saveSlot(g.control), el, "control")
    copySlot(parts.help, saveSlot(g.help), el, "\"?\"")
end

-- Core's game look for a row whose like isn't a game row (Design Note 4).
local function fallbackLook(el, w, parts, fresh)
    backgroundStyle(el, w, fresh) -- the worn strip (rowTint), as every game-look row
    local f = theme.game.textFonts.body
    local font = gameAsset("font:" .. f.font)
    local c = theme.game.text
    for _, t in ipairs({ parts.label, parts.help }) do
        if font then C.count(); t:SetFont({ FontObject = font, Size = f.size, TypefaceFontName = FName("Default"), LetterSpacing = 0 }) end
        C.count(); t:SetColorAndOpacity({ SpecifiedColor = { R = c.r, G = c.g, B = c.b, A = c.a }, ColorUseRule = 0 })
    end
    local lf = theme.game.likeFallback
    local function m(p) return { Left = p.l, Top = p.t, Right = p.r, Bottom = p.b } end
    local zero = { Left = 0, Top = 0, Right = 0, Bottom = 0 }
    copySlot(parts.label, { pad = m(lf.labelPad), size = { SizeRule = SIZE_RULE_FILL, Value = 1 }, va = VALIGN_CENTER }, el, "label")
    copySlot(parts.inner, { pad = zero, size = { SizeRule = SIZE_RULE_AUTO, Value = 1 }, va = VALIGN_CENTER }, el, "inner box")
    copySlot(parts.holder, { pad = zero, size = { SizeRule = SIZE_RULE_AUTO, Value = 1 }, va = VALIGN_CENTER }, el, "control")
    copySlot(parts.help, { pad = m(lf.helpPad), size = { SizeRule = SIZE_RULE_AUTO, Value = 1 }, va = VALIGN_CENTER }, el, "\"?\"")
end

-- The open screen a game-style row reads its like row from: the attach's host object, else the live host.
local function screenFor(el)
    if curHostObj then return curHostObj end
    local s = liveHost(C.hostOf(el))
    return s
end

-- The like row's parts on the open screen, or nil and why.
local function likeSource(el, s)
    local host = C.hostOf(el)
    s = s or screenFor(el)
    if not s then return nil, "the screen is not open" end
    local src = namedOf(host, s, el.like)
    if not src then return nil, "no widget of that name is in the open screen" end
    return gameRowParts(src)
end

X._likeStyle = function(el, w, fresh)
    el.selBg = nil
    local parts = likeParts(w)
    if not parts then backgroundStyle(el, w, fresh) return end -- not built (likeContent warned): the plain row look
    local host = C.hostOf(el)
    local g, why = likeSource(el)
    if g then
        local ok, err = pcall(copyLook, el, w, parts, g)
        if ok then
            el.matBg, el.likeLook = nil, "copied"
            C.stats.likeCopies = (C.stats.likeCopies or 0) + 1
            if C.debugOn() then C.log.debug("ui %s: row '%s' copied its look from '%s'", host, el.id, el.like) end
            return
        end
        why = "copying its look failed: " .. firstLineOf(err)
    end
    C.warnOnce("like " .. host .. "|" .. el.like,
        "ui %s: row '%s' is like '%s', which is not a game row on the open screen (%s); it is drawn in %s's game look",
        host, el.id, el.like, tostring(why), C.NAME)
    C.stats.likeFallbacks = (C.stats.likeFallbacks or 0) + 1
    el.likeLook = "fallback"
    local ok, err = pcall(fallbackLook, el, w, parts, fresh)
    if not ok then warnFirst("like fallback:" .. el.id, "row '%s': core's game look was not applied: %s", err, el.id) end
end

-- The owning player for a widget core creates inside a row (the tooltip widget): the screen's, else player 0's.
local function ownerFor(w)
    local s = curHostObj
    if s then
        local okO, o = pcall(function() return s:GetOwningPlayer() end)
        if okO and C.valid(o) then return o end
    end
    local okP, pc = pcall(function() return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(w:GetWorld(), 0) end)
    return okP and C.valid(pc) and pc or nil
end
X._ownerFor = ownerFor

-- The "?"'s help: the game's tooltip widget with the help as its Description (Design Note 7), else plain tooltip text.
local function applyHelp(el, w, parts)
    local s = el.help and S.pick(el.help) or nil
    if s == el.appliedHelp then return end
    local q = parts.help
    if not s then
        C.count(); q:SetVisibility(C.VIS.Hidden)
        el.appliedHelp = nil
        return
    end
    local tip = nil
    local cls = A.get("cls:tooltip3")
    if cls then
        local ok, err = pcall(function()
            C.count()
            local t = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(w, cls, ownerFor(w))
            if not C.valid(t) then error("creating " .. theme.game.tooltipWidget.name .. " failed", 0) end
            local okK = pcall(function() C.count(); C.found(KSL_CDO):SetTextPropertyByName(t, FName("Description"), FText(s)) end)
            if not okK then C.count(); t.Description = FText(s) end
            C.count(); q:SetToolTip(t)
            tip = t
        end)
        if ok then
            C.stats.gameTips = (C.stats.gameTips or 0) + 1
        else
            tip = nil
            warnFirst("like tip:" .. el.id, "row '%s': the game's tooltip widget could not be made (%s); its help shows as a plain tooltip", err, el.id)
        end
    end
    local ok, err = pcall(function()
        if not tip then
            pcall(function() C.count(); q:SetToolTip(nil) end) -- an earlier tooltip widget would win over the text
            C.count(); q:SetToolTipText(FText(s))
        end
        C.count(); q:SetVisibility(C.VIS.Visible)
    end)
    if ok then el.appliedHelp = s
    else warnFirst("like help:" .. el.id, "row '%s': its help was not applied: %s", err, el.id) end
end

X._likeContent = function(el, w, fresh)
    if fresh then el.appliedLabel, el.appliedHelp = nil, nil end
    local parts = likeParts(w)
    if not parts then
        local ok, res = pcall(buildLike, w)
        if not ok then warnFirst("like build:" .. el.id, "row '%s': building its game-style parts failed (its children go in its box): %s", res, el.id) return end
        parts = res
        el.appliedLabel, el.appliedHelp = nil, nil
    end
    local label = el.label and S.pick(el.label) or ""
    if label ~= el.appliedLabel then
        local ok, err = pcall(function() C.count(); parts.label:SetText(FText(label)) end)
        if ok then el.appliedLabel = label else warnFirst("like label:" .. el.id, "row '%s': its label was not applied: %s", err, el.id) end
    end
    applyHelp(el, w, parts)
end

-- setLabel / setHelp on a live row (row.lua): the label and the help again, no look copy.
function X._likeRefresh(el)
    local w = liveWidget(el)
    if not w then return end
    local parts = likeParts(w)
    if not parts then return end
    local ok, err = pcall(function()
        local label = el.label and S.pick(el.label) or ""
        if label ~= el.appliedLabel then C.count(); parts.label:SetText(FText(label)); el.appliedLabel = label end
        applyHelp(el, w, parts)
    end)
    if not ok then warnFirst("like label:" .. el.id, "row '%s': its label or help was not applied: %s", err, el.id) end
end

-- In a game container: the row's own slot gets the like row's slot values (after it joined the box).
local function likeRowSlot(el, w, s)
    local g = likeSource(el, s)
    if not g then return end
    copySlot(w, saveSlot(g.row), el, "row slot")
end

local function idsOf(els)
    local ids = {}
    for i, el in ipairs(els) do
        if i > 8 then ids[#ids + 1] = "..." break end
        ids[#ids + 1] = "'" .. el.id .. "'"
    end
    return table.concat(ids, ", ")
end

-- One box: attach its elements (els, creation order), then put the box in the wanted order (one rebuild at most).
-- Returns the number attached.
local function insertBox(host, s, name, box, els, reason)
    local belongs = function(el) return not el.panel and el.place.host == host and el.place.container == name end
    local okS, byId, orphans = pcall(scan, box, belongs)
    if okS then
        for _, o in ipairs(orphans) do removeWidget(o.w) end
    else
        byId = {}
    end
    local items, ws, done = {}, {}, {}
    for _, el in ipairs(els) do
        local ok, res = pcall(attachOne, el, s, box, byId, reason)
        local w = ok and res and liveWidget(el) or nil
        if w then
            local pl = el.place
            items[#items + 1] = { after = pl.after, before = pl.before, index = pl.index, at = pl.at }
            ws[#ws + 1], done[#done + 1] = w, el
        else
            el.attached = false
            if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, firstLineOf(res)) end
        end
    end
    -- The box as it is: our widgets, then the game's children (units: a game child and the other mods' core widgets
    -- after it; those before the first game child lead).
    local ours = {}
    for _, w in ipairs(ws) do ours[w:GetAddress()] = true end
    local cur, units, lead, gameNames = {}, {}, {}, {}
    for i = 0, childCountOf(box) - 1 do
        local c = childAt(box, i)
        if c then
            cur[#cur + 1] = c
            if not ours[c:GetAddress()] then
                if coreTagOf(c) then
                    if #units == 0 then lead[#lead + 1] = c else table.insert(units[#units], c) end
                else
                    units[#units + 1] = { c }
                    gameNames[#gameNames + 1] = widgetNameOf(c) or ""
                end
            end
        end
    end
    local order, missing, pastEnd = P.insertOrder(gameNames, items)
    for _, k in ipairs(missing) do
        local a = items[k].after or items[k].before
        C.warnOnce("insert anchor " .. host .. "|" .. name .. "|" .. a,
            "ui %s: anchor '%s' is not a child of '%s'; %s '%s' (and any other element placed at it) goes to the end of '%s'",
            host, a, name, done[k].kind, done[k].id, name)
    end
    for _, k in ipairs(pastEnd) do
        C.warnOnce("insert index " .. host .. "|" .. name .. "|" .. items[k].index,
            "ui %s: index %d is past the end of '%s' (%d game children); %s '%s' goes to the end",
            host, items[k].index, name, #gameNames, done[k].kind, done[k].id)
    end
    local want = {}
    for _, c in ipairs(lead) do want[#want + 1] = c end
    for _, o in ipairs(order) do
        if o.game then for _, c in ipairs(units[o.game]) do want[#want + 1] = c end
        else want[#want + 1] = ws[o.item] end
    end
    local k = 1
    while k <= #cur and k <= #want and cur[k]:GetAddress() == want[k]:GetAddress() do k = k + 1 end
    if k <= #want or k <= #cur then
        -- From the first child out of order: save the game's slots, take every child out, add them back in order.
        local saved, picks, removed = {}, {}, 0
        for i = k, #cur do
            local c = cur[i]
            local a = c:GetAddress()
            -- core story 33: another mod's core widgets (a game-style row with a game choice) restore themselves
            if not ours[a] then saved[a] = saveSlot(c); if not coreTagOf(c) then picks[a] = pickersOf(c) end end
            local ok, err = pcall(function() C.count(); return box:RemoveChild(c) end)
            if ok then removed = removed + 1
            else C.warnOnce("insert remove " .. host .. "|" .. name, "ui %s: taking a child out of '%s' failed: %s", host, name, firstLineOf(err)) end
        end
        for i = k, #want do
            local c = want[i]
            local ok, err = pcall(function() C.count(); box:AddChild(c) end)
            if ok then
                local a = c:GetAddress()
                local v = saved[a]
                if v then restoreSlot(c, v, name) end
                if picks[a] and #picks[a] > 0 then restorePickers(picks[a], name) end
            else
                C.warnOnce("insert add " .. host .. "|" .. name, "ui %s: putting a child back into '%s' failed: %s", host, name, firstLineOf(err))
            end
        end
        if removed > 0 then C.stats.containerRebuilds = (C.stats.containerRebuilds or 0) + 1 end
    end
    for _, el in ipairs(done) do
        local w = liveWidget(el)
        if w and el.like then likeRowSlot(el, w, s) end -- core story 33: the like row's slot values
        if w then
            el.appliedVis = nil
            local ok, err = pcall(P.applyVisibility, el, w)
            if not ok then C.warnOnce("vis:" .. el.id, "%s '%s': SetVisibility failed: %s", el.kind, el.id, firstLineOf(err)) end
        end
    end
    return #done
end

-- The insert pass of a game screen's host (s: the open screen, valid only in this callback): every container element,
-- or only those of one container. Returns the number of elements attached.
local function insertPass(host, s, only, reason)
    local byName, names = {}, {}
    for _, el in ipairs(C.order) do
        local pl = el.place
        if not el.removed and not el.panel and pl.host == host and pl.container and (only == nil or pl.container == only) then
            local list = byName[pl.container]
            if not list then list = {}; byName[pl.container] = list; names[#names + 1] = pl.container end
            list[#list + 1] = el
        end
    end
    if #names == 0 then return 0 end
    local boxes, missing = boxesOf(host, s, names)
    local n = 0
    for _, nm in ipairs(names) do
        local els = byName[nm]
        local box = boxes[nm]
        if box then
            local ok, res = pcall(insertBox, host, s, nm, box, els, reason)
            if ok then n = n + res
            else C.warnOnce("insert " .. host .. "|" .. nm, "ui %s: inserting into '%s' failed: %s", host, nm, firstLineOf(res)) end
        else
            for _, el in ipairs(els) do
                local w = liveWidget(el)
                if w then removeWidget(w) end
                freeRef(el); dropParts(el)
                el.attached = false
            end
            local why = missing[nm] or {}
            if why.notBox then
                C.warnOnce("insert container " .. host .. "|" .. nm,
                    "ui %s: '%s' is a %s, not %s; %s stay(s) pending until the next open",
                    host, nm, why.notBox, INSERT_CLASS_NAMES, idsOf(els))
            else
                C.warnOnce("insert container " .. host .. "|" .. nm,
                    "ui %s: container '%s' is missing (%s; it must be %s, by name); %s stay(s) pending until the next open",
                    host, nm, tostring(why.why), INSERT_CLASS_NAMES, idsOf(els))
            end
        end
    end
    return n
end
X._insertPass = insertPass

-- create / place while a game screen is open: the containers to pass on the host's next poll tick (host -> { list, set }).
local insertQueue = {}
function X._queueInsert(host, name)
    local q = insertQueue[host]
    if not q then q = { list = {}, set = {} }; insertQueue[host] = q end
    if not q.set[name] then q.set[name] = true; q.list[#q.list + 1] = name end
end
-- The host's poll tick (a screen open, no event this tick): one insert pass per queued container.
local function runQueued(host, s)
    local q = insertQueue[host]
    if not q then return end
    insertQueue[host] = nil
    for _, nm in ipairs(q.list) do insertPass(host, s, nm, "queued create / place") end
end

-- Core story 31: the game screens (createServer). Like a window: every open is a new screen, so its elements get new
-- widgets in its root canvas at the poll's opened (never inside a hook of the game's), and on closed or lost only their
-- handles are freed (the widgets went, or go, with the screen). Corner stacks settle on the screen's ticks. Core story
-- 32: then the insert pass puts the container elements into the game's boxes.
local gameWatching = {}
ensureGame = function(host)
    if gameWatching[host] then return end
    gameWatching[host] = true
    G._watch(host, function(s, info)
        if info.event == "opened" then
            local t0 = C.micros()
            dropBoxes(host)
            insertQueue[host] = nil -- the full pass below covers every container
            local n = 0
            local canvas = G._canvasOf(host, s) -- nil: _canvasOf warned once; those elements stay pending until the next open
            if canvas then n = X._attachHost(host, s, canvas, info.reason) end
            n = n + insertPass(host, s, nil, info.reason)
            if n > 0 and C.debugOn() then C.log.debug("ui %s attach n=%d in %d us (%s)", host, n, C.micros() - t0, tostring(info.reason)) end
        else
            dropBoxes(host)
            insertQueue[host] = nil
            local freed = X._detachHost(host)
            if freed > 0 and C.debugOn() then C.log.debug("ui %s %s: freed %d widget handle(s) (%s)", host, info.event, freed, tostring(info.reason)) end
        end
    end)
    G._ticker(host, function(s)
        local okQ, errQ = pcall(runQueued, host, s)
        if not okQ then C.warnOnce("insert queue " .. host, "ui %s: the queued insert pass failed: %s", host, firstLineOf(errQ)) end
        X._tickHost(host, s)
    end)
end
X._ensureGame = function(host) ensureGame(host) end

-- ---------------------------------------------------------------- the element registry (all kinds)

-- Story 24: whether an element (or, for a container, anything in it) has a tooltip.
local function holdsTip(el)
    if el.tooltip then return true end
    for _, ch in ipairs(el.children or {}) do
        if not ch.removed and holdsTip(ch) then return true end
    end
    return false
end
X._holdsTip = holdsTip
-- Story 24: a tooltip needs a host with a cursor; raises nucleus.ui.<kind>: ... for one on the HUD.
function X._checkTipHost(kind, host, hasTip)
    if hasTip and host == "hud" then
        C.fail("%s.%s: tooltip needs a host with a cursor (%s), got 'hud'", C.UI, kind, C.CURSOR_HOSTS)
    end
end

-- Story 14: whether a container can take one more child; raises otherwise. kind: the joining element's kind.
-- Story 21 nesting: a panel takes text, buttons and rows; a list takes text, buttons and rows; a row takes text and
-- buttons. A list goes inside nothing; a panel inside no container. Story 24: images go where text goes (panel, list,
-- row); el (an existing element) or hasTip (a new one's): a tooltip can't join a container on the HUD.
local function checkJoin(p, kind, fn, el, hasTip)
    if kind == "list" then C.fail("%s.%s: a list can't go inside a panel, list or row", C.UI, fn) end
    if kind == "panel" then
        if p.kind == "panel" then C.fail("%s.%s: a panel can't go inside a panel (one level only)", C.UI, fn) end
        C.fail("%s.%s: a panel can't go inside a list or row", C.UI, fn)
    end
    if kind == "row" and p.kind == "row" then C.fail("%s.%s: a row can't go inside a row", C.UI, fn) end
    local n = 0
    for _, ch in ipairs(p.children) do if not ch.removed then n = n + 1 end end
    local cap = CHILD_CAP[p.kind] or MAX_CHILDREN
    if n >= cap then C.fail("%s.place: %s '%s' already has %d children (at most %d)", C.UI, p.kind, p.id, n, cap) end
    if X.checkHost then X.checkHost(kind, C.hostOf(p), fn) end
    X._checkTipHost(kind, C.hostOf(p), hasTip or (el ~= nil and holdsTip(el)))
end
X._checkJoin = checkJoin

-- Core story 33: a game-style row sits directly on a game screen (its canvas or one of its game containers), never in
-- a core panel, list or row; a game choice (and so a container holding one) only on a game screen, directly or in a
-- row, panel or list there. pl: a validated intent; fn: the error prefix ("row.create", "place", ...). Raises.
local function holdsGameChoice(el)
    for _, ch in ipairs(el.children or {}) do
        if not ch.removed and (ch.kind == "gchoice" or holdsGameChoice(ch)) then return true end
    end
    return false
end
function X._checkGameOnly(el, pl, fn, isLike, kind)
    local host = pl.panelEl and C.hostOf(pl.panelEl) or pl.host
    if isLike or (el and el.like) then
        if pl.panelEl then
            C.fail("%s.%s: a row with like can't go inside a panel, list or row (place it on a game screen: %s)", C.UI, fn, C.GAME_SCREEN_NAMES)
        end
        if not C.gameScreen(host) then
            C.fail("%s.%s: like needs a game screen host (%s), got '%s'", C.UI, fn, C.GAME_SCREEN_NAMES, tostring(host))
        end
    end
    if (kind or (el and el.kind)) == "gchoice" or (el and holdsGameChoice(el)) then
        if not C.gameScreen(host) then
            C.fail("%s.%s: widget 'game' needs a game screen host (%s), got '%s'", C.UI, fn, C.GAME_SCREEN_NAMES, tostring(host))
        end
    end
end

-- A new element of a kind: registered, in creation order. place is a validated intent ({ panelEl = ... } for a panel).
function X._new(kind, id, fields, place)
    C.seq = C.seq + 1
    local el = fields
    el.kind, el.id, el.visible, el.removed, el.attached, el.seq = kind, id, true, false, false, C.seq
    if place.panelEl then
        el.panel, el.place, el.fill = place.panelEl, { inPanel = true }, place.fill
        local list = place.panelEl.children
        list[#list + 1] = el
    else
        el.place = place
    end
    el.handle = newHandle(id, kind)
    C.els[id] = el
    C.order[#C.order + 1] = el
    C.handleOf[el.handle] = el
    ensureHost(el)
    attachNow(el, "create")
    hostChanged(C.hostOf(el))
    return el
end

-- The existing element with this id for a create of kind, or nil; raises when the id belongs to another kind.
function X._existing(id, kind, fn)
    local el = C.els[id]
    if el and not el.removed then
        if el.kind ~= kind then C.fail("%s.%s: id '%s' is already %s of this mod", C.UI, fn, id, C.ARTICLE[el.kind]) end
        return el
    end
    return nil
end

-- Takes an element out of where it is (a host canvas or a panel): its widget leaves, its handle is freed, and the
-- place it left closes up. Its state stays.
local function detach(el)
    local wasHost = C.hostOf(el)
    local w = liveWidget(el)
    if w then removeWidget(w) end
    freeRef(el); dropParts(el)
    el.attached, el.slotKey, el.appliedVis, el.nearAbsent, el.retryAt, el.padKey = false, nil, nil, false, nil, nil
    if el.panel then
        local p = el.panel
        for i, ch in ipairs(p.children) do if ch == el then table.remove(p.children, i) break end end
        el.panel = nil
        if w then applyGaps(p); resized(p) end
    elseif w and el.place.corner then
        restackCorner(el.place.host, el.place.corner, el.place.region)
    end
    if w then hostChanged(wasHost) end
end

-- Removes an element for good (a panel with its children: their handles raise "was removed" from then on).
local function removeEl(el, underRemovedPanel)
    local wasHost = C.hostOf(el)
    local w = liveWidget(el)
    if w and not underRemovedPanel then removeWidget(w) end -- a child goes with its panel's widget
    freeRef(el); dropParts(el)
    el.removed, el.attached = true, false
    C.els[el.id] = nil
    for i, e in ipairs(C.order) do if e == el then table.remove(C.order, i) break end end
    C.handleOf[el.handle] = nil
    C.removedHandle[el.handle] = el.id
    C.removedKind[el.handle] = C.publicKind(el.kind)
    if el.children then
        local kids = el.children
        el.children = {}
        for _, ch in ipairs(kids) do removeEl(ch, true) end
    end
    if el.panel and not underRemovedPanel then
        local p = el.panel
        for i, ch in ipairs(p.children) do if ch == el then table.remove(p.children, i) break end end
        if w then applyGaps(p); resized(p) end
    elseif w and not el.panel and el.place.corner then
        restackCorner(el.place.host, el.place.corner, el.place.region)
    end
    if not underRemovedPanel then hostChanged(wasHost) end
end
X._remove = removeEl

-- Whether the element is drawn now: its widget exists in its container (the host's live canvas, or its panel's box),
-- it isn't hidden by setVisible (nor its panel), and the host is drawn (the HUD visible, the Journal open on its map
-- page).
local function shown(el)
    if not el.visible or el.nearAbsent or not el.ref then return false end
    local w = C.deref(el.ref)
    if not w then return false end
    local container
    if el.panel then
        if not shown(el.panel) then return false end
        local pw = liveWidget(el.panel)
        container = pw and boxOf(el.panel, pw)
    elseif el.place.container then
        -- Core story 32: its parent is the named game box of the open screen, and the screen is drawn.
        local ad = hostA(el.place.host)
        if not ad then return false end
        local obj, drawn = ad.poll()
        if not obj or not drawn then return false end
        local okP, p = pcall(function() return w:GetParent() end)
        if not (okP and C.valid(p) and widgetNameOf(p) == el.place.container) then return false end
        local okA, sp, pp = pcall(function() return C.pathOf(obj), C.pathOf(p) end)
        if not (okA and pp:sub(1, #sp + 1) == sp .. ".") then return false end
        return C.drawn(tonumber(w:GetVisibility()) or 0)
    else
        local ad = hostA(el.place.host)
        if not ad then return false end
        local obj, drawn = ad.poll()
        if not obj or not drawn then return false end
        container = ad.canvas(obj)
    end
    if not container then return false end
    local okP, p = pcall(function() return w:GetParent() end)
    if not (okP and C.valid(p) and p:GetAddress() == container:GetAddress()) then return false end
    return C.drawn(tonumber(w:GetVisibility()) or 0)
end
X._shown = shown

-- setVisible for any kind (the caller checked the handle and the value).
function X._setVisible(el, visible)
    if el.visible == visible then return end
    el.visible = visible
    local w = liveWidget(el)
    if w then
        local ok, err = pcall(P.applyVisibility, el, w)
        if not ok then C.warnOnce("vis:" .. el.id, "%s '%s': SetVisibility failed: %s", el.kind, el.id, tostring(err):match("^[^\n]*")) end
        if el.panel then
            applyGaps(el.panel) -- the first visible child has no gap before it
            resized(el.panel)   -- the panel's size changed: what follows it in its corner moves
        elseif el.place.corner then restackCorner(el.place.host, el.place.corner, el.place.region) -- a hidden element takes no space
        elseif visible and C.debugOn() then D.schedule(el, "shown") end
    end
    hostChanged(C.hostOf(el))
end

-- setStyle for any kind: s is a resolved style.
local function sameFull(a, b)
    if not sameStyle(a, b) or (a.hover == nil) ~= (b.hover == nil) then return false end
    return a.hover == nil or (sameStyle(a.hover, b.hover) and sameStyle(a.pressed, b.pressed))
end
function X._setStyle(el, s)
    if sameFull(s, el.style) and s.look == el.style.look and s.font == el.style.font and s.explicitBg == el.style.explicitBg
        and s.overflow == el.style.overflow then return end
    el.style = s
    local w = liveWidget(el)
    if w then
        KIND[el.kind].style(el, w, false)
        resized(el)
    end
end


-- ---------------------------------------------------------------- public: text

local CREATE_KEYS = { id = true, text = true, place = true, style = true }

function X.create(opts)
    C.enter("text.create")
    if type(opts) ~= "table" then C.fail("%s.text.create: expected a table { id = ..., text = ..., place = ..., style = ... }, got %s", C.UI, C.describe(opts)) end
    for k in pairs(opts) do
        if not CREATE_KEYS[k] then C.fail("%s.text.create: unknown key %s (valid: id, text, place, style)", C.UI, C.describe(k)) end
    end
    local id = validId(opts.id, "text.create")
    local text, long = validText(opts.text, "text.create")
    if opts.place ~= nil and type(opts.place) ~= "table" then
        C.fail("%s.text.create: place must be a table or nil, got %s", C.UI, C.describe(opts.place))
    end
    local place = opts.place ~= nil and P.validate(opts.place) or P.validate({ corner = "top-right" })
    local style = X.resolveStyle(opts.style)
    local el = X._existing(id, "text", "text.create")
    if el then
        -- Same id: the new text, intent and style, as set, place and setStyle would apply them; visible unchanged.
        X.set(el.handle, text)
        X.setStyle(el.handle, opts.style)
        P.place(el.handle, opts.place or { corner = "top-right" })
        return el.handle
    end
    if place.panelEl then checkJoin(place.panelEl, "text", "text.create") end
    el = X._new("text", id, { text = text, style = style, warnedLong = long }, place)
    if long then C.log.warn("text '%s': text is longer than %d characters; showing the first %d", id, MAX_TEXT, MAX_TEXT) end
    return el.handle
end

function X.set(h, text, ...)
    C.enter("text.set")
    local el = C.element(h, "text.set", "text")
    local t, long = validText(text, "text.set")
    if long and not el.warnedLong then
        el.warnedLong = true
        C.log.warn("text '%s': text is longer than %d characters; showing the first %d", el.id, MAX_TEXT, MAX_TEXT)
    end
    if t == el.text then return end -- no UObject call: what keeps a once-a-second clock cheap
    el.text = t
    local w = liveWidget(el)
    if w then
        local ok, err = pcall(KIND.text.content, el, w, false)
        if not ok then C.warnOnce("set:" .. el.id, "text '%s': SetText failed: %s", el.id, tostring(err):match("^[^\n]*")) end
        resized(el) -- the size may have changed: the elements after it (or after its panel) move
    end
end

function X.setStyle(h, style)
    C.enter("text.setStyle")
    local el = C.element(h, "text.setStyle", "text")
    X._setStyle(el, X.resolveStyle(style))
end

function X.setVisible(h, visible)
    C.enter("text.setVisible")
    local el = C.element(h, "text.setVisible", "text")
    if type(visible) ~= "boolean" then C.fail("%s.text.setVisible: visible must be a boolean, got %s", C.UI, type(visible)) end
    X._setVisible(el, visible)
end

function X.remove(h)
    C.enter("text.remove")
    if type(h) == "table" and C.removedHandle[h] then return end -- idempotent
    local el = C.element(h, "text.remove", "text")
    removeEl(el)
end

function X.isShown(h)
    C.enter("text.isShown")
    local el = C.element(h, "text.isShown", "text")
    return shown(el)
end

-- Story 24: setTooltip for any kind that has one (text, button, image): validated (strings.lua) and checked against
-- the element's host before anything changes; nil clears it. Applied now when the widget is live, else at its attach.
function X._setTooltipOf(kind, h, tip, nargs)
    local fn = kind .. ".setTooltip"
    C.enter(fn)
    local el = C.element(h, fn, kind)
    if nargs > 2 then C.fail("%s.%s: expected 2 arguments (handle, tooltip), got %d", C.UI, fn, nargs) end
    local t = S.validateTooltip(tip, C.UI .. "." .. fn)
    X._checkTipHost(kind, C.hostOf(el), t ~= nil)
    el.tooltip = t
    local w = liveWidget(el)
    if w then applyTooltip(el, w, false) end
end
function X.setTooltip(h, ...) return X._setTooltipOf("text", h, (...), 1 + select("#", ...)) end

-- UI-3: place(handle, intent), any kind. Pending: stores the intent; attach applies it. Live: re-places now. A new
-- host moves the element: its widget leaves the old host's canvas, the old corner closes up, and it attaches on the
-- new host now (or when that host next appears). Story 14: { panel = p } moves it into a panel (at the end; already
-- there: nothing changes), and a host intent takes a child out of its panel.
local placeImpl -- below
P.place = function(h, intent)
    C.enter("place")
    local el = C.element(h, "place")
    local pl = P.validate(intent)
    local before = C.hostOf(el)
    placeImpl(el, pl)
    hostChanged(before)
    local after = C.hostOf(el)
    if after ~= before then hostChanged(after) end
end
placeImpl = function(el, pl)
    X._checkGameOnly(el, pl, "place") -- core story 33
    if pl.panelEl then
        local p = pl.panelEl
        if p == el.panel then
            -- Story 21: the same row with another fill weight changes only the slot.
            if el.fill ~= pl.fill then el.fill, el.padKey = pl.fill, nil; applyGaps(p); resized(p) end
            return
        end
        checkJoin(p, el.kind, "place", el)
        detach(el)
        el.panel, el.place, el.fill = p, { inPanel = true }, pl.fill
        p.children[#p.children + 1] = el
        ensureHost(el)
        attachNow(el, "place in " .. p.kind .. " '" .. p.id .. "'")
        return
    end
    if X.checkHost then X.checkHost(el.kind, pl.host, "place", el) end
    X._checkTipHost(el.kind, pl.host, holdsTip(el)) -- story 24
    if el.panel then
        detach(el)
        el.place, el.fill = pl, nil
        ensureHost(el)
        attachNow(el, "place on host " .. pl.host)
        return
    end
    local oldHost, oldCorner, oldRegion = el.place.host, el.place.corner, el.place.region
    if oldHost ~= pl.host then
        detach(el)
        el.place = pl
        ensureHost(el)
        attachNow(el, "place on host " .. pl.host)
        return
    end
    -- Core story 32: into, out of, or within a game container: the same place changes nothing; any other takes the
    -- widget out (its box closes up) and attaches it again where it now belongs.
    if el.place.container or pl.container then
        if el.place.container and pl.container and P.sameInsert(el.place, pl) then
            if not el.attached then attachNow(el, "place") end
            return
        end
        detach(el)
        el.place = pl
        ensureHost(el)
        attachNow(el, "place in container " .. tostring(pl.container or pl.corner or "canvas"))
        return
    end
    el.place = pl
    el.slotKey, el.nearAbsent = nil, false
    if liveWidget(el) then
        local obj, canvas = liveHost(pl.host)
        if obj then
            if oldCorner and (oldCorner ~= pl.corner or oldRegion ~= pl.region) then
                pcall(P.restack, pl.host, oldCorner, liveIn(canvas), true, oldRegion, ctxFor(pl.host, obj, canvas))
                checkCorner(pl.host, oldCorner, "re-stack", oldRegion)
            end
            placeAll(pl.host, obj, canvas, true)
            if pl.corner then checkCorner(pl.host, pl.corner, "place", pl.region) elseif C.debugOn() then D.schedule(el, "place") end
        end
    elseif not el.attached then
        attachNow(el, "place")
    end
end

function X.stats()
    local n = 0
    for _ in pairs(C.els) do n = n + 1 end
    return { elements = n, uobjectCalls = C.stats.uobjectCalls, attachCreated = C.stats.attachCreated,
        attachReused = C.stats.attachReused, handlesFreed = C.stats.handlesFreed, findAllCalls = C.stats.findAllCalls,
        overlapScheduled = C.stats.overlapScheduled, overlapChecks = C.stats.overlapChecks,
        panelRebuilds = C.stats.panelRebuilds or 0, containerRebuilds = C.stats.containerRebuilds or 0,
        pickerRestores = C.stats.pickerRestores or 0,
        -- core story 33: game-style rows' look copies and fallbacks, and the game tooltip widgets made for their help
        likeCopies = C.stats.likeCopies or 0, likeFallbacks = C.stats.likeFallbacks or 0, gameTips = C.stats.gameTips or 0 }
end

-- The tag a widget of this mod's element carries (for tests and diagnostics).
function X.tagOf(id) return tagOf(id) end

-- Story 21: assets.lua reads the cache only inside a hook, and its LoadMap preload also loads core's widget classes
-- in use (they are unloaded after a map change, research 8.1), so a new Journal's Construct finds them cached.
A.setHookCheck(X._inHook)
A.extra = function()
    local need = {}
    for _, el in ipairs(C.order) do if not el.removed then need[el.kind] = true end end
    for kind in pairs(need) do classOf(kind) end
    if next(C.windows) then classOf("screen"); classOf("button") end
end

X._validId, X._validText, X._sameStyle, X._sameFull = validId, validText, sameStyle, sameFull
X._liveWidget, X._applyGaps, X._ensureOrder = liveWidget, applyGaps, ensureOrder
X._MAX_CHILDREN = MAX_CHILDREN
return X
