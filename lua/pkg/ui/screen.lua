-- Story 21 (Mod Manager story 2): the screen host, full-screen windows above the title-screen menu that form a stack.
-- Exposed as core.ui.screen on the connect API:
--   open{ id = <string>, close = <boolean|nil> } -> window   opens (or, already open, returns) the window id
--   close(window)                closes it and every window above it (those with reason "parent")
--   isOpen(window) -> boolean    top() -> window | nil (this mod's top window)
--   watch(fn) -> token           fn(window, info), info = { event = opened | closed | lost, id, reason }; closed's
--                                reason: "close" (its Close button), "api" (screen.close), "parent" (a window below it
--                                closed); lost: the menu went (a map change)
--   unwatch(token)
-- Elements go on a window with place = { screen = <window>, corner | absolute }.
--
-- A window is a core-generated WBP_<Core>Screen added to the viewport above everything open: a hit-testable dark
-- backdrop over the whole viewport (it blocks the menu and every window below) and a full-screen canvas for elements.
-- Only the top window takes input: windows below it are made non-hit-testable (HitTestInvisible) until the ones above
-- close, and the new top window gets keyboard focus (SetInputMode_UIOnlyEx + SetKeyboardFocus). A close gives focus to
-- the next window down, else back to the menu, the way the game's own level script gives it (research 1.1). With
-- close = true (the default) core puts its own Close button, in the game's look and the game's language, top-right.
-- Windows open only while the menu host is open; the menu's loss closes them all (lost). A window's elements stay
-- created across closes and attach again on the next open of the same id. At most 8 windows open per dependent.
-- Across dependents a later window sits above (a shared Z counter); each dependent's focus goes back to its own next
-- window, else the menu.
--
-- Core story 27 (core 0.12.0, UI-12): the card, BACK and the keys.
-- * The window's content sits on one card (WBP_<Core>Screen: Overlay "Root" -> Border "Backdrop" (the scrim) and Border
--   "Card", centred both ways, theme.window's colour and padding -> SizeBox "Inner" -> CanvasPanel "Canvas"). A
--   window's corner and absolute intents resolve inside Canvas, the card's inner area. The card hugs the content: Inner
--   is sized to the hug rule (SC._hug) after a layout prepass, before the window's first frame, again whenever an
--   element on the window is created, removed, shown, hidden, re-texted, re-styled or moved (text.lua's
--   X._onHostChange), and on the 500 ms tick when a measured size changed. It is clamped to the viewport less
--   theme.window.margin on each side; larger content logs one WARN per window id.
-- * BACK (core's string "back") replaces CLOSE: a core button element "#close:<id>" (the tag, and so close's reason and
--   drivers that find it by tag, are unchanged), the first element of the card's bottom-left corner; a dependent's
--   bottom-left elements stack after it by the corner rule. close = false: no BACK (the element is hidden).
-- * Keys and focus: focus.lua. Opening a window focuses its first focusable element; Escape and the gamepad's B close
--   the top window (reason "close") when it was opened with close = true; after a close the next window down gets its
--   last-focused element back.
local BASE = (...):gsub("%.ui%.screen$", "")
local C = require(BASE .. ".ui.common")
local M = require(BASE .. ".ui.menu")
local X = require(BASE .. ".ui.text")
local B = require(BASE .. ".ui.button")
local S = require(BASE .. ".ui.strings")
local A = require(BASE .. ".ui.assets")
local P = require(BASE .. ".ui.place")
local F = require(BASE .. ".ui.focus")
local theme = require(BASE .. ".ui.theme")

local SC = {}
SC.MAX_OPEN = 8
SC.MAX_IDS = 64
local Z_BASE = 100
local Z_KEY = C.LOWER .. ".ui.screenZ"
-- Core story 27: the Z of the window that should hold keyboard focus (the top open window across dependents), kept by
-- opens and closes; only that window's UI tick takes focus back.
local FOCUS_Z_KEY = C.LOWER .. ".ui.screenFocusZ"
local function focusZ()
    local ok, z = pcall(function() return ModRef:GetSharedVariable(FOCUS_Z_KEY) end)
    return ok and tonumber(z) or nil
end
local function setFocusZ(z) pcall(function() ModRef:SetSharedVariable(FOCUS_Z_KEY, z or 0) end) end
local WLL = "/Script/UMG.Default__WidgetLayoutLibrary"
local INPUT_DO_NOT_LOCK = 0          -- EMouseLockMode::DoNotLock

local order = {}                     -- open window ids of this dependent, bottom first
local T = { opens = 0, closes = 0, lost = 0 }

-- ---------------------------------------------------------------- helpers (game thread)

local function wbl() return C.found("/Script/UMG.Default__WidgetBlueprintLibrary") end
local function widgetOf(rec)
    if not (rec and rec.ref) then return nil end
    local ok, w = pcall(C.deref, rec.ref)
    return ok and w or nil
end
local function ownerOf(mm)
    local ok, pc = pcall(C.call0, mm, "GetOwningPlayer")
    if ok and C.valid(pc) then return pc end
    local okW, p = pcall(function()
        return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(mm:GetWorld(), 0)
    end)
    return okW and C.valid(p) and p or nil
end
local function indexOf(id)
    for i, v in ipairs(order) do if v == id then return i end end
    return nil
end

-- The next Z above every window open in any dependent's Lua state (UE4SS shared variables cross Lua states).
local function nextZ()
    local ok, z = pcall(function() return ModRef:GetSharedVariable(Z_KEY) end)
    z = ok and tonumber(z) or nil
    if not z or z ~= z or z < Z_BASE or z > 1000000 then z = Z_BASE end
    z = math.floor(z) + 1
    pcall(function() ModRef:SetSharedVariable(Z_KEY, z) end)
    return z
end

-- Only the top window takes input: Visible on top, HitTestInvisible below.
local function setTop(rec, top)
    local w = widgetOf(rec)
    if w then pcall(function() w:SetVisibility(top and C.VIS.Visible or C.VIS.HitTestInvisible) end) end
end

-- Core story 27: focus goes to the window's remembered element, else its first focusable, else the window (focus.lua).
local function focusWindow(rec, fresh)
    if not widgetOf(rec) then return end
    local ok, err = pcall(F.focusWindow, rec, fresh)
    if not ok then C.warnOnce("focus window", "window '%s': focusing it failed: %s", rec.id, tostring(err):match("^[^\n]*")) end
end

-- Focus back to the menu, as NewMainMenu's level script gives it (research 1.1).
local function focusMenu()
    local mm = M._poll()
    if not mm then return end
    local pc = ownerOf(mm)
    if pc then pcall(function() wbl():SetInputMode_UIOnlyEx(pc, mm, INPUT_DO_NOT_LOCK, true) end) end
    pcall(C.call0, mm, "SetKeyboardFocus")
end

-- ---------------------------------------------------------------- watchers

local watchers = {}
local issued = {}
local nextToken = 0

local function dispatch(rec, info)
    local list = {}
    for i, w in ipairs(watchers) do list[i] = w end
    for _, w in ipairs(list) do
        if not w.dead then
            local ok, err = pcall(w.fn, rec and rec.handle or nil, info)
            if not ok and not w.warned then
                w.warned = true
                if C.log then C.log.warn("screen watcher %d: %s", w.token, tostring(err):match("^[^\n]*")) end
            end
        end
    end
    for i = #watchers, 1, -1 do if watchers[i].dead then table.remove(watchers, i) end end
end

-- ---------------------------------------------------------------- open and close

local closeById -- below
local isGlobalTop -- below

-- ---------------------------------------------------------------- the card (core story 27)

-- The hug rule (pure). items, in creation order: { corner = <corner>, inset = <units>, gap = <units>, offset = { x, y },
-- w, h } for a corner element, { absolute = { anchor, x, y }, w, h } for an absolute one (visible ones only). Each corner
-- stack's width and height include its inset and offsets as placed (P.stack); stacks side by side or one above the
-- other add up, with stackGap between two non-empty ones. An absolute element needs the inner area to hold it at its
-- anchor: top-left x + w, top-right w - x, centre w + 2|x| (and the same for y). Returns the inner width and height.
function SC._hug(items, stackGap)
    local st = {}
    for c in pairs(P._CORNERS) do st[c] = { w = 0, h = 0, along = 0, n = 0 } end
    local W, H = 0, 0
    local function need(a, pos, size)
        if a == 0 then return pos + size elseif a == 1 then return size - pos end
        return size + 2 * math.abs(pos)
    end
    for _, it in ipairs(items) do
        local w, h = math.max(tonumber(it.w) or 0, 0), math.max(tonumber(it.h) or 0, 0)
        if it.corner and st[it.corner] then
            local c, s = P._CORNERS[it.corner], st[it.corner]
            local inset = it.inset or it.gap or 0
            s.along = s.along + (s.n == 0 and inset or (it.gap or 0))
            s.n = s.n + 1
            local off = it.offset or { x = 0, y = 0 }
            s.w = math.max(s.w, inset + c.sx * off.x + w)
            s.h = math.max(s.h, s.along + c.sy * off.y + h)
            s.along = s.along + h
        elseif it.absolute then
            local an = P._ANCHORS[it.absolute.anchor] or { 0, 0 }
            W = math.max(W, need(an[1], it.absolute.x, w))
            H = math.max(H, need(an[2], it.absolute.y, h))
        end
    end
    local function sum(a, b)
        if a <= 0 then return b elseif b <= 0 then return a end
        return a + stackGap + b
    end
    local tl, tr, bl, br = st["top-left"], st["top-right"], st["bottom-left"], st["bottom-right"]
    W = math.max(W, sum(tl.w, tr.w), sum(bl.w, br.w))
    H = math.max(H, sum(tl.h, bl.h), sum(tr.h, br.h))
    return W, H
end

-- The inner size clamped so the card (inner + padding) leaves margin on each side of the viewport (all layout units).
-- Returns w, h and whether either was clamped.
function SC._clamp(W, H, vw, vh, pad, margin)
    local mw, mh = vw - 2 * margin - 2 * pad, vh - 2 * margin - 2 * pad
    local w, h = W, H
    if mw > 0 and w > mw then w = mw end
    if mh > 0 and h > mh then h = mh end
    return math.max(w, 0), math.max(h, 0), w ~= W or h ~= H
end

-- The viewport in layout units (size / DPI scale), or nil.
local function viewportOf(w)
    local ok, vs, sc = pcall(function()
        local l = StaticFindObject(WLL)
        return l:GetViewportSize(w), l:GetViewportScale(w)
    end)
    sc = ok and tonumber(sc) or nil
    if not (ok and vs and sc and sc > 0) then return nil end
    local vw, vh = tonumber(vs.X), tonumber(vs.Y)
    if not (vw and vh) then return nil end
    return vw / sc, vh / sc
end

local function sizeOf(w)
    local ok, ds = pcall(function() return w:GetDesiredSize() end)
    if ok and ds then return tonumber(ds.X) or 0, tonumber(ds.Y) or 0 end
    return 0, 0
end

local function firstLine(e) return (tostring(e):match("^[^\n]*")) end

-- Sizes the card's inner area to the hug of the window's elements. prepass: lay the window out first (open, a change);
-- the tick reads the sizes Slate cached. Calls Inner only when the size changed.
local function refit(rec, prepass)
    local w = widgetOf(rec)
    if not w then return end
    if prepass then pcall(function() C.count(); w:ForceLayoutPrepass() end) end
    local host = C.windowHost(rec.id)
    local items = {}
    for _, el in ipairs(C.order) do
        if not el.removed and not el.panel and el.place.host == host and el.visible and (el.place.corner or el.place.absolute) then
            local ew = el.ref and C.deref(el.ref)
            if ew then
                local ww, hh = sizeOf(ew)
                if el.place.corner then
                    items[#items + 1] = { corner = el.place.corner, inset = el.place.insetUnits, gap = el.place.gapUnits, offset = el.place.offset, w = ww, h = hh }
                else
                    items[#items + 1] = { absolute = el.place.absolute, w = ww, h = hh }
                end
            end
        end
    end
    local W, H = SC._hug(items, theme.window.stackGap)
    local cw, ch, clamped = W, H, false
    local vw, vh = viewportOf(w)
    if vw then cw, ch, clamped = SC._clamp(W, H, vw, vh, theme.window.padding, theme.window.margin) end
    if clamped then
        C.warnOnce("card:" .. rec.id, "window '%s': its content (%.0f x %.0f) is larger than the viewport allows; the card is clamped to %.0f x %.0f",
            rec.id, W, H, cw + 2 * theme.window.padding, ch + 2 * theme.window.padding)
    end
    rec.card = { w = cw, h = ch, contentW = W, contentH = H, vw = vw, vh = vh, clamped = clamped }
    local key = string.format("%.2fx%.2f", cw, ch)
    if key == rec.cardKey then return end
    local ok, err = pcall(function()
        local inner = w.Inner
        C.count(); inner:SetWidthOverride(cw)
        C.count(); inner:SetHeightOverride(ch)
    end)
    if ok then rec.cardKey = key
    else C.warnOnce("card size", "window '%s': sizing its card failed (is %s's pak current?): %s", rec.id, C.NAME, firstLine(err)) end
end
SC._refit = refit

-- The card's look: theme.window's colour (the game look's, or the plain one when the game look's assets can't be
-- loaded) and padding.
local function styleCard(w)
    local game = A.get("mat:strip") ~= nil
    local bg = game and theme.window.background.game or theme.window.background.plain
    local pad = theme.window.padding
    local ok, err = pcall(function()
        local card = w.Card
        C.count(); card:SetBrushColor({ R = bg.r, G = bg.g, B = bg.b, A = bg.a })
        C.count(); card:SetPadding({ Left = pad, Top = pad, Right = pad, Bottom = pad })
    end)
    if not ok then C.warnOnce("card look", "a window's card look failed (is %s's pak current?): %s", C.NAME, firstLine(err)) end
end

-- ---------------------------------------------------------------- BACK (core story 27)

-- Core's BACK button: a button element "#close:<id>" on the window (ids of dependents' elements can't start with "#"),
-- created on the window's first open, first in the card's bottom-left corner (moved to the front of the creation
-- order). Its click goes through the button hook's internal path (B._internal) to a close with reason "close". Hidden
-- (no space) while the window is open with close = false. Its label is core's "back" string in the game's language.
local function ensureBack(rec)
    local id = F._backIdOf(rec)
    local el = C.els[id]
    if not el then
        local place = P.validate({ screen = rec.handle, corner = "bottom-left" })
        el = X._new("button", id, { label = S.core("back"), style = X.resolveStyle(nil, "button"), onClick = function() end,
            enabled = true, iconSize = { w = theme.iconSize, h = theme.iconSize }, dimmed = false, coreBack = true }, place)
        for i, e in ipairs(C.order) do if e == el then table.remove(C.order, i) break end end
        table.insert(C.order, 1, el)
    end
    el.label = S.core("back")
    el.visible = rec.close == true
    local wid = rec.id
    B._internal[id] = function() closeById(wid, "close") end
    B._ensureHook()
    return el
end

local function closeOne(rec, reason, event)
    local i = indexOf(rec.id)
    if i then table.remove(order, i) end
    X._detachHost(C.windowHost(rec.id))
    local w = widgetOf(rec)
    if w then pcall(C.call0, w, "RemoveFromParent") end
    if rec.ref then pcall(C.free, rec.ref) end
    rec.ref, rec.open = nil, false
    if event == "lost" then T.lost = T.lost + 1 else T.closes = T.closes + 1 end
    dispatch(rec, { event = event or "closed", id = rec.id, reason = reason })
end

-- Closes a window and every window above it (top first, reason "parent"), then gives focus to the next window down,
-- else to the menu.
local function closeRec(rec, reason)
    local idx = indexOf(rec.id)
    if not idx then return end
    local fz, myTop = focusZ(), order[#order] and C.windows[order[#order]] or nil
    for i = #order, idx + 1, -1 do
        local above = C.windows[order[i]]
        if above then closeOne(above, "parent") end
    end
    closeOne(rec, reason)
    local top = order[#order] and C.windows[order[#order]] or nil
    if myTop and myTop.z and fz and myTop.z >= fz then setFocusZ(top and top.z or 0) end -- it held focus: the next one does
    if top then setTop(top, true); focusWindow(top) else focusMenu() end
end
closeById = function(id, reason)
    local rec = C.windows[id]
    if rec and rec.open then closeRec(rec, reason) end
end

-- Every window lost with the menu (top first).
local function loseAll(reason)
    for i = #order, 1, -1 do
        local rec = C.windows[order[i]]
        if rec then closeOne(rec, reason, "lost") end
    end
    order = {}
    setFocusZ(0)
end

-- Whether rec is the top window across every dependent (the shared Z counter's last value): only then does the tick
-- take keyboard focus back.
isGlobalTop = function(rec)
    local z = focusZ()
    return z == nil or rec.z == nil or rec.z >= z
end

local watchingMenu = false
local function ensureMenu()
    if watchingMenu then return end
    watchingMenu = true
    M._watch(function(_, info)
        if info.event == "lost" then loseAll("the menu is gone (" .. tostring(info.reason) .. ")") end
    end)
    -- A window widget that is gone while open (another mod removed it): lost.
    M._ticker(function()
        for i = #order, 1, -1 do
            local rec = C.windows[order[i]]
            if rec then
                local w = widgetOf(rec)
                if w then
                    X._tickHost(C.windowHost(rec.id), w)
                    local okR, errR = pcall(refit, rec, false)
                    if not okR then C.warnOnce("refit tick", "window '%s': re-fitting its card failed: %s", rec.id, tostring(errR):match("^[^\n]*")) end
                    if i == #order and isGlobalTop(rec) then
                        local okF, errF = pcall(F.tick, rec, w)
                        if not okF then C.warnOnce("focus tick", "window '%s': its focus tick failed: %s", rec.id, tostring(errF):match("^[^\n]*")) end
                    end
                else
                    closeOne(rec, "its widget is gone", "lost")
                    local top = order[#order] and C.windows[order[#order]] or nil
                    if top then setTop(top, true); focusWindow(top) else focusMenu() end
                end
            end
        end
    end)
end

local function newHandle(id)
    return setmetatable({}, {
        __index = { id = id },
        __newindex = function() error(C.UI .. ".screen: window handles are read-only", 2) end,
        __metatable = "window handle",
        __tostring = function() return "window '" .. id .. "'" end,
    })
end

local OPEN_KEYS = { id = true, close = true }

function SC.open(opts, ...)
    C.enter("screen.open")
    local pre = C.UI .. ".screen.open"
    if type(opts) ~= "table" then C.fail("%s: expected a table { id = ..., close = ... }, got %s", pre, C.describe(opts)) end
    if select("#", ...) > 0 then C.fail("%s: expected 1 argument (a table), got %d", pre, 1 + select("#", ...)) end
    for k in pairs(opts) do
        if not OPEN_KEYS[k] then C.fail("%s: unknown key %s (valid: close, id)", pre, C.describe(k)) end
    end
    local id = X._validId(opts.id, "screen.open")
    if opts.close ~= nil and type(opts.close) ~= "boolean" then C.fail("%s: close must be a boolean or nil, got %s", pre, C.describe(opts.close)) end
    if M._inHook then C.fail("%s: called inside the menu's Construct", pre) end
    ensureMenu()
    local mm = M._poll()
    if not mm then C.fail("%s: the title-screen menu is not open (windows open only over it)", pre) end
    local rec = C.windows[id]
    if rec and rec.open and widgetOf(rec) then return rec.handle end
    if #order >= SC.MAX_OPEN then C.fail("%s: this mod already has %d windows open (at most %d)", pre, #order, SC.MAX_OPEN) end
    if not rec then
        local n = 0
        for _ in pairs(C.windows) do n = n + 1 end
        if n >= SC.MAX_IDS then C.fail("%s: this mod already has %d window ids (at most %d)", pre, n, SC.MAX_IDS) end
        rec = { id = id, handle = newHandle(id), open = false }
        C.windows[id] = rec
        C.windowOf[rec.handle] = rec
    end
    rec.close = opts.close ~= false
    local okB, errB = pcall(ensureBack, rec) -- pending until the window is live below: attached with the rest
    if not okB then C.warnOnce("back button", "window '%s': its BACK button failed: %s", id, tostring(errB):match("^[^\n]*")) end
    local cls = X._classOf("screen")
    if not cls then C.fail("%s: %s is not loaded (is Content/Paks/LogicMods/%s.pak installed?)", pre, C.SCREEN_CLASS, C.NAME) end
    A.ensureLoadMapHook()
    local w = wbl():Create(mm, cls, ownerOf(mm))
    if not C.valid(w) then C.fail("%s: creating %s failed", pre, C.SCREEN_SHORT) end
    pcall(function() w:SetTag(C.LOWER .. ":" .. C.modTag .. ":#screen:" .. id) end)
    pcall(function() w:SetIsFocusable(true) end)
    local bd = theme.backdrop
    pcall(function() w:SetBackdrop(bd.r, bd.g, bd.b, bd.a) end)
    styleCard(w)
    rec.z = nextZ()
    setFocusZ(rec.z)
    w:AddToViewport(rec.z)
    rec.ref = C.ref(w)
    rec.open = true
    for _, oid in ipairs(order) do setTop(C.windows[oid], false) end
    order[#order + 1] = id
    setTop(rec, true)
    local okC, canvas = pcall(C.prop, w, "Canvas")
    if okC and C.valid(canvas) then
        X._attachHost(C.windowHost(id), w, canvas, "window opened")
        refit(rec, true) -- before the window's first frame
    else
        C.warnOnce("screen canvas", "window '%s': its widget has no Canvas (is %s's pak current?); its elements stay pending", id, C.NAME)
    end
    focusWindow(rec, true)
    T.opens = T.opens + 1
    dispatch(rec, { event = "opened", id = id, reason = "screen.open" })
    return rec.handle
end

local function windowArg(h, fn)
    if type(h) ~= "table" then C.fail("%s.screen.%s: expected a window handle, got %s", C.UI, fn, C.describe(h)) end
    local rec = C.windowOf[h]
    if not rec then C.fail("%s.screen.%s: not a window handle (use the handle that screen.open returned)", C.UI, fn) end
    return rec
end

function SC.close(h, ...)
    C.enter("screen.close")
    local rec = windowArg(h, "close")
    if select("#", ...) > 0 then C.fail("%s.screen.close: expected 1 argument (window), got %d", C.UI, 1 + select("#", ...)) end
    if rec.open then closeRec(rec, "api") end
end

function SC.isOpen(h, ...)
    C.enter("screen.isOpen")
    local rec = windowArg(h, "isOpen")
    if select("#", ...) > 0 then C.fail("%s.screen.isOpen: expected 1 argument (window), got %d", C.UI, 1 + select("#", ...)) end
    return rec.open == true and widgetOf(rec) ~= nil
end

function SC.top(...)
    C.enter("screen.top")
    if select("#", ...) > 0 then C.fail("%s.screen.top: expected 0 arguments, got %d", C.UI, select("#", ...)) end
    local id = order[#order]
    return id and C.windows[id] and C.windows[id].handle or nil
end

function SC.watch(fn, ...)
    C.enter("screen.watch")
    if type(fn) ~= "function" then C.fail("%s.screen.watch: fn must be a function, got %s", C.UI, C.describe(fn)) end
    if select("#", ...) > 0 then C.fail("%s.screen.watch: expected 1 argument (fn), got %d", C.UI, 1 + select("#", ...)) end
    ensureMenu()
    nextToken = nextToken + 1
    watchers[#watchers + 1] = { token = nextToken, fn = fn }
    issued[nextToken] = true
    return nextToken
end

function SC.unwatch(token, ...)
    C.enter("screen.unwatch")
    if math.type(token) ~= "integer" then C.fail("%s.screen.unwatch: token must be an integer, got %s", C.UI, C.describe(token)) end
    if select("#", ...) > 0 then C.fail("%s.screen.unwatch: expected 1 argument (token), got %d", C.UI, 1 + select("#", ...)) end
    if not issued[token] then C.fail("%s.screen.unwatch: unknown token %d (not one screen.watch returned)", C.UI, token) end
    for _, w in ipairs(watchers) do if w.token == token then w.dead = true end end
    for i = #watchers, 1, -1 do if watchers[i].dead then table.remove(watchers, i) end end
end

-- Diagnostic copy, not semver API. Core story 27: focus = the id of the element the top window's focus model holds,
-- card = its card's inner size and the content's hug size, nav = focus.lua's counters.
function SC.stats()
    local top = order[#order] and C.windows[order[#order]] or nil
    local card = top and top.card or nil
    return { open = #order, opens = T.opens, closes = T.closes, lost = T.lost, focus = top and top.focusId or nil,
        card = card and { w = card.w, h = card.h, contentW = card.contentW, contentH = card.contentH, clamped = card.clamped } or nil,
        nav = F.stats() }
end

-- Core story 27: the focus model's callbacks, and the engine's change notice (a window's element changed: re-fit its
-- card, and hand focus on when the focused element is no longer focusable).
F.init{
    close = function(id, reason) return closeById(id, reason) end,
    windowWidget = function(rec) return widgetOf(rec) end,
    owner = function() local mm = M._poll() return mm and ownerOf(mm) or nil end,
    isTop = function(rec) return order[#order] == rec.id end,
    top = function() local id = order[#order] return id and C.windows[id] or nil end,
}
X._onHostChange = function(host)
    local rec = C.windows[host:sub(8)]
    if not (rec and rec.open and rec.ref) then return end
    refit(rec, true)
    F.changed(rec)
end
C.onUse = F.used

-- For unit tests only.
function SC._order() return order end
SC._closeById, SC._loseAll = function(id, reason) return closeById(id, reason) end, loseAll
return SC
