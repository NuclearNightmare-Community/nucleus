-- Core story 27 (core 0.12.0, UI-12): keyboard and gamepad focus on core's windows. Internal: no public function;
-- screen.lua drives it, and SkelTest reads it through screen.stats() and this module's underscore functions.
--
-- Keys: WBP_<Core>Screen overrides OnPreviewKeyDown. It turns the key into Slate's navigation direction (NavDir: Left
-- 0, Right 1, Up 2, Down 3, Next 4, Previous 5, else 7) and action (NavAction: Accept 0, Back 1, else 3; Escape and the
-- gamepad's B are always Back), calls its hookable counter <Core>_OnNav, and returns Handled when a post-hook set
-- NavHandled. The preview pass runs from the window down to the focused widget, so only the window holding focus sees
-- a key and the game's menu below never does; keyboard and gamepad (D-pad, A, B) share this one path. (OnKeyDown, the
-- bubbling pass, never sees the arrows: a focused Button answers them with Slate's own navigation; measured in the VM.)
-- A key is left to the focused widget when focus sits on something that isn't a navigation target (the slider's text
-- box while typing) and for Accept on a Button (its own click). Each dependent's Lua state
-- registers the post-hook once, by full path, from the UI poll (never inside a hook); it ignores another mod's window
-- (its tag), a widget that isn't the window's live one and out-of-range values, all in silence.
--
-- The model: per window, lines of focusable elements, built from the element registry on every event (no UObject):
-- each list (creation order) gives one line per child (a row's focusables left to right; a lone button, checkbox,
-- choice or slider is its own line); then what sits directly on the window, one line each in creation order (a row
-- there is one line, a panel's focusables one line each); then Back. Focusable: a button (a checkbox, Back), a choice
-- or a slider that is attached, visible down its chain and enabled (dimmed stays focusable). Empty lines are skipped.
--   Up / Down (and Previous / Next): the previous / next line, the nearest column (clamped), no wrap. Always Handled.
--   Left / Right: a focused choice steps its option, a slider its value (value +- step, clamped; a Default slider starts
--   at defaultValue); onChange once per real change. Otherwise the previous / next element of the line, no wrap.
--   Accept: on a button left to the Button, whose own Accept clicks it (onClick once, the click path); on a choice, a
--   slider or the window itself, Handled and nothing changes. Back: closes the top window (reason "close") only when it was opened with close = true.
-- Focus targets: a button's inner Button "Btn", a choice's and a slider's own widget (focusable class defaults). The
-- focused element shows its hover look (SetFocusLook on its widget). Core story 28: a dimmed button or a game-look
-- icon-only one, whose hover look changes nothing, first gets a focus face (button.lua B._focusFace: dimmed looks like
-- its undimmed self, faceless borrows the selection material); and the row holding the focused element shows the
-- game's selection material (M_NN_CinematicSelection) as its background, one row per window (rec.lookRowId). Both go
-- back to the element's and the row's own style when focus leaves them (focus moves, the window widget takes it, the
-- element goes, another window covers this one); the UI tick puts them back after a re-style. Core story 30 (0.12.2):
-- with theme.game.focusRowStrong (default on) the row's highlight is a full-row band, an instance of that material with
-- its near-black fill lifted to theme colours (assets.lua A.focusRowMaterial); the instance is never made inside core's
-- own key and click handling, control dispatch or a Construct hook, so there, with none alive (after a map change or a
-- garbage collection), the row gets the plain selection and the UI tick upgrades it; off: 0.12.1's look.
-- A focused row inside a list is scrolled into view.
-- Core story 36 (0.15.1): the band follows the mouse. WBP_<Core>Row overrides OnMouseEnter and calls its hookable
-- counter <Core>_OnHover (its Background is hit-testable, so the whole row counts). Each Lua state post-hooks it once,
-- by full path, from the UI poll. A real pointer move into a row of this state's global top open window (a screen host,
-- the row's own tag and live widget, a row with a focusable line) moves the model's current element to that row's
-- focusable in the current column (clamped, as Up / Down), without scrolling; keys continue from there. Whichever input
-- moved last owns the band: the platform cursor position is recorded at every handled key, at F.focusWindow, at
-- every click on a window's focusable and at every hover into a row (applied, or the row already holding focus), and an enter at that position (content moving under a still pointer: a window opening, a list
-- scrolling) is ignored; an unreadable position doesn't block. No focus steal: while a text box in the window or
-- anything outside it holds keyboard focus a hover does nothing. The hook body runs with C.inDispatch and hookDepth
-- raised (cached assets only: the tick completes a plain band or a missing face).
-- Core story 39 (0.15.4): a focus chip on the focused control. One input mode per Lua state, "keys" or "mouse", set by
-- the last input: keys by a navigation key on a window (handled or left to the focused widget; the click the Accept key
-- makes a focused Button do is the key's); mouse by a real pointer move into a row of the top window (story 36's rule)
-- and by every click (an element on any host, a window's BACK, the menu entry). Opening or returning to a window keeps
-- the mode: a window opened by a mouse click shows no chip, one opened from the keys the chip on its first control.
-- Every focus look is decided in one place (lookOf) from the mode: in keys mode the focused button, checkbox, choice or
-- slider inside a row draws its own face (button.lua B._chip) or background (a choice's, a slider's) with a second
-- instance of the selection material (assets.lua A.focusChipMaterial), brighter than the band, its icon or text white (a
-- slider's number through its box's content tint); an icon-only one's chip reaches a small padding beyond the icon
-- through a render scale (the layout never moves; a list row is a little taller for it: text.lua X._rowPad). Without an
-- instance (none alive inside core's key and click handling or a dispatch, or it failed) the chip is solid and the UI
-- tick upgrades it (el.chipOn "strong" | "solid"; "pending" while a failed one waits for the tick). In mouse mode only
-- the band and story 27/28's looks show. A change of mode re-applies the current looks at once. Off (focus leaves, the
-- mode changes, the window is covered or closed, a re-style): render scales back to 1 and the kind's own style draws it.
-- Lone controls and BACK keep story 27/28's looks; focusRowStrong doesn't affect the chip. Core story 41 (0.15.5): the
-- chip is light blue, one theme value (theme.game.focusChipColor, #6dd5ed linear), and what is drawn on it (icon,
-- label, a choice's value, a slider's number) is theme.game.focusChipInk.
-- Core story 42 (0.17.1): a chipped checkbox's icon keeps its own colours (the ink tinted its ticked / unticked texture)
-- over a dark box behind it (button.lua iconBack: the button widget's IconBack, so its inside stays dark in the ring),
-- and only real mouse input switches to mouse mode: a hover while the game's CommonInputSubsystem reports gamepad input
-- (its current input type: CommonUI's analog cursor) is ignored, and a click while it does or while its
-- gamepad-simulated click flag is set (clicks only) keeps the mode; the Accept key's own click stays the key's, and
-- every valid navigation key records the pointer (gamepadInput).
-- Each window remembers its last-focused element (by id): after a close the next window down gets it back.
-- Core story 38 (0.16.0, UI-16): rows of a reorderable list move with the keyboard and the gamepad (reorder.lua holds
-- the shared model and the mouse drag). A movable row (reorder.lua's rule) with no focusable of its own is a focus stop
-- itself (its widget made focusable; its look is the band). Holding A or Enter (the Accept key) on a movable row's
-- element (or on such a row) for theme.reorder.holdMs picks the row up: keyboard focus goes to the row's own widget (a
-- held Button is released, so it never clicks), the row shows the carry band (a third instance, assets.lua
-- A.carryRowMaterial, else the strong band until the UI tick upgrades it) and a render translation of theme.reorder.lift
-- to the right. While held, Up / Down (and Next / Previous) move it one visible slot within its segment (one rebuild per
-- step, focus kept on it, scrolled into view; at an edge handled and nothing moves), Left / Right and the key's repeats
-- are handled and do nothing, Back (Escape, B) puts the pickup order back and leaves the window open. Releasing the key
-- (WBP_<Core>Screen's OnKeyUp override calls <Core>_OnNavUp; this state's post-hook, registered once from the UI poll
-- while it has a reorderable list) drops it: onReorder once when the order changed, focus back on the element A went
-- down on. A shorter press is a tap: the control's own action (a button's click on the release; a choice, a slider or a
-- row: nothing), as before. A click, a hover-free focus change, a covered or closed window, or an API change to the
-- list cancels a carry (the pickup order back, no callback). Hovers are ignored during a hold, a carry or a drag. The
-- hold and the carry are checked by reorder.lua's 16 ms loop; the pickup and the key paths run with C.inDispatch
-- raised (cached assets only).
local BASE = (...):gsub("%.ui%.focus$", "")
local C = require(BASE .. ".ui.common")
local H = require(BASE .. ".ui.hud")
local X = require(BASE .. ".ui.text")
local CH = require(BASE .. ".ui.choice")
local SL = require(BASE .. ".ui.slider")
local A = require(BASE .. ".ui.assets")
local B = require(BASE .. ".ui.button")
local theme = require(BASE .. ".ui.theme")
local RO = require(BASE .. ".ui.reorder")

local F = {}
F.DIR = { left = 0, right = 1, up = 2, down = 3, next = 4, previous = 5 }
F.ACT = { accept = 0, back = 1 }
F.NAV_FN = C.SCREEN_CLASS .. ":" .. C.NAME .. "_OnNav"
local FOCUSABLE = { button = true, checkbox = true, choice = true, slider = true }
local INPUT_DO_NOT_LOCK = 0
local S = { navs = 0, handled = 0, ignored = 0, moves = 0, steps = 0, closes = 0, refocus = 0, recovered = 0,
    scrolls = 0, faults = 0, hooked = false, hookTries = 0, rowLooks = 0, faces = 0,
    hovers = 0, hoverIgnored = 0, hoverHooked = false, hoverTries = 0, -- story 36
    chips = 0, chipFaults = 0, -- story 39
    holds = 0, taps = 0, pickups = 0, carryMoves = 0, carryEdges = 0, drops = 0, carryCancels = 0, carryRefocus = 0,
    ups = 0, upHooked = false, upOk = false, upTries = 0 } -- story 38

local function firstLine(e) return (tostring(e):match("^[^\n]*")) end

-- ---------------------------------------------------------------- the model (pure: element tables only)

local function chainVisible(el)
    local n = 0
    while el and n < 4 do
        if not el.visible then return false end
        el, n = el.panel, n + 1
    end
    return true
end

local gripRow -- below
function F.focusable(el)
    if el ~= nil and el.kind == "row" then return gripRow(el) end -- core story 38
    return el ~= nil and not el.removed and FOCUSABLE[el.kind] == true and el.attached == true
        and el.enabled ~= false and chainVisible(el)
end

local function lineOf(container)
    local line = {}
    for _, ch in ipairs(container.children or {}) do
        if F.focusable(ch) then line[#line + 1] = ch end
    end
    return line
end

-- Core story 38: a movable row of a reorderable list that has no focusable of its own is a focus stop itself.
gripRow = function(el)
    if el.removed or el.attached ~= true or not chainVisible(el) then return false end
    local list = el.panel
    if not (list and list.kind == "list" and list.reorderable == true and RO.movable(el)) then return false end
    for _, ch in ipairs(el.children or {}) do
        if ch.kind ~= "row" and F.focusable(ch) then return false end
    end
    return true
end
F._gripRow = function(el) return gripRow(el) end

-- lines(host, backId) -> { { els = { el, ... }, owner = <row or list id | nil> }, ... }
function F.lines(host, backId)
    local lines = {}
    local function push(els, owner) if #els > 0 then lines[#lines + 1] = { els = els, owner = owner } end end
    for _, el in ipairs(C.order) do
        if not el.removed and not el.panel and el.place.host == host and el.kind == "list" and el.visible then
            for _, ch in ipairs(el.children) do
                if not ch.removed then
                    if ch.kind == "row" then
                        if ch.visible then
                            local line = lineOf(ch)
                            if #line == 0 and gripRow(ch) then line = { ch } end -- core story 38: the row itself
                            push(line, ch.id)
                        end
                    elseif F.focusable(ch) then push({ ch }, nil) end
                end
            end
        end
    end
    for _, el in ipairs(C.order) do
        if not el.removed and not el.panel and el.place.host == host and el.id ~= backId then
            if FOCUSABLE[el.kind] then
                if F.focusable(el) then push({ el }, nil) end
            elseif el.kind == "row" and el.visible then push(lineOf(el), el.id)
            elseif el.kind == "panel" and el.visible then
                for _, ch in ipairs(el.children) do
                    if not ch.removed then
                        if ch.kind == "row" then
                            if ch.visible then push(lineOf(ch), ch.id) end
                        elseif F.focusable(ch) then push({ ch }, nil) end
                    end
                end
            end
        end
    end
    local back = backId and C.els[backId] or nil
    if F.focusable(back) then push({ back }, "#back") end
    return lines
end

function F.find(lines, el)
    if not el then return nil end
    for li, l in ipairs(lines) do
        for ci, e in ipairs(l.els) do if e == el then return li, ci end end
    end
    return nil
end

-- One step from (li, ci) in direction dir (F.DIR); no wrap: at an end the position stays.
function F.move(lines, li, ci, dir)
    if dir == F.DIR.up or dir == F.DIR.previous then
        if li > 1 then li = li - 1 end
        ci = math.min(ci, #lines[li].els)
    elseif dir == F.DIR.down or dir == F.DIR.next then
        if li < #lines then li = li + 1 end
        ci = math.min(ci, #lines[li].els)
    elseif dir == F.DIR.left then
        if ci > 1 then ci = ci - 1 end
    elseif dir == F.DIR.right then
        if ci < #lines[li].els then ci = ci + 1 end
    end
    return li, ci
end

-- Where focus goes when the focused element is gone, hidden or disabled: the nearest focusable in its line (its row, if
-- the row is still there), else the line now at its old index (the next one), else the previous one, else Back (the
-- last line). lost = { li, ci, owner }.
function F.recover(lines, lost)
    if #lines == 0 then return nil end
    if lost and lost.owner then
        for _, l in ipairs(lines) do
            if l.owner == lost.owner then return l.els[math.min(lost.ci or 1, #l.els)] end
        end
    end
    local li = math.min(math.max((lost and lost.li) or 1, 1), #lines)
    local l = lines[li]
    return l.els[math.min((lost and lost.ci) or 1, #l.els)]
end

-- ---------------------------------------------------------------- widgets (game thread)

local cb = {} -- set by screen.lua: close(id, reason), windowWidget(rec), owner() -> player controller | nil, isTop(rec),
              -- isGlobalTop(rec) (the top window across every dependent), top()
-- Focus moves outside a key event (a model change) only on the global top window: never take focus from another mod's.
local function globalTop(rec)
    if cb.isGlobalTop then return cb.isGlobalTop(rec) end
    return not cb.isTop or cb.isTop(rec)
end

local function widgetOf(el)
    if not el.ref then return nil end
    local ok, w = pcall(C.deref, el.ref)
    return ok and w or nil
end

-- Core story 38: a row's own widget is made focusable (a grip row, or a carried row), or not again.
-- UUserWidget's SetIsFocusable isn't a UFunction (VM run 1: a TrivialObject); its property bIsFocusable is read live by
-- NativeSupportsKeyboardFocus, so it is written directly.
local function focusableRow(row, w, on)
    if not w then return end
    -- The live widget's own flag decides (an address can be reused by a new widget); row.focusOn only marks that core
    -- set it, for the off path.
    if on then
        local okR, cur = pcall(C.prop, w, "bIsFocusable")
        if okR and cur == true then row.focusOn = true return end
        local ok, err = pcall(function() C.count(); w.bIsFocusable = true end)
        if ok then row.focusOn = true
        else C.warnOnce("focus row widget", "making a row focusable failed: %s", firstLine(err)) end
    elseif row.focusOn then
        pcall(function() C.count(); w.bIsFocusable = false end)
        row.focusOn = nil
    end
end

-- The widget keyboard focus goes to: a button's (and a checkbox's) inner Button, a choice's or a slider's own widget;
-- core story 38: a grip row's own widget.
local function targetOf(el)
    local w = widgetOf(el)
    if not w then return nil end
    if el.kind == "row" then focusableRow(el, w, true) return w end
    if el.kind == "button" or el.kind == "checkbox" then
        local ok, b = pcall(C.prop, w, "Btn")
        return ok and C.valid(b) and b or nil
    end
    return w
end
F._targetOf = targetOf

local function hasFocus(t)
    if not t then return false end
    local ok, yes = pcall(C.call0, t, "HasKeyboardFocus")
    return ok and yes == true
end
F._hasFocus = hasFocus

local function rowOf(el)
    if el and el.kind == "row" then return (not el.removed) and el or nil end -- core story 38: a grip row is its own row
    local p = el and el.panel
    if p and p.kind == "row" and not p.removed then return p end
    return nil
end

-- Core story 39: the input mode ("keys" | "mouse"), one per Lua state, set by the last input (F.input). Every focus
-- look is decided in one place from it (lookOf below). hookDepth: > 0 while this module's OnNav post-hook or F.used (a
-- click, drag end, commit or arrow) runs; a dependent's callback after it is not counted (story 30).
local mode = "keys"
local hookDepth = 0
F._noChip = false -- unit tests only: earlier stories' blocks prove their looks without the chip
local CHIP_KINDS = { button = true, checkbox = true, choice = true, slider = true }
-- The one place a focus look is decided: what el shows (on: it holds the window's focus) in the current input mode.
--   "off"   its own look (not focused)
--   "chip"  keys mode, a button, checkbox, choice or slider inside a row: the focus chip (and its focus look)
--   "face"  a dimmed button or a faceless game-look icon-only one (story 28): the focus face, then its focus look
--   "hover" anything else focused: its focus look (story 27's hover look) only
-- The mouse mode never shows a chip; lone controls and BACK never do.
local function lookOf(el, on)
    if not on then return "off" end
    if not F._noChip and mode == "keys" and CHIP_KINDS[el.kind] == true and rowOf(el) ~= nil then return "chip" end
    if B._needsFace(el) then return "face" end
    return "hover"
end
F._lookOf = lookOf
-- An icon-only control's chip padding: theme.game.focusChipPad, at most half the row's gap and the row's own padding
-- (X._rowPad: a list row's listRowPadX / listRowPadY included), never below 0.
local function chipPad(el)
    local row = rowOf(el)
    if not row then return 0 end
    local px, py = X._rowPad(row)
    local p = math.min(theme.game.focusChipPad, math.floor((row.gapUnits or 0) / 2), px, py)
    return math.max(p, 0)
end
F._chipPad = chipPad
-- The content tint that draws the game's text colour (theme.game.text, the slider box's generated colour) in the chip's
-- ink (theme.game.focusChipInk): a Border's content tint multiplies its content (as the generated FocusTint, which
-- reaches the hover colour).
local function inkTint()
    local t, ink = theme.game.text, theme.game.focusChipInk
    return { R = ink.r / t.r, G = ink.g / t.g, B = ink.b / t.b, A = ink.a }
end
-- A choice's or a slider's chip: its own Background (padding 0, as its look's) from the instance, else solid; a
-- choice's value in the chip's ink (its font from the cache; a miss leaves the chip "solid", so the tick completes it).
-- lookKey "chip": its own look is drawn again by its style. A slider's number takes the ink after its focus look
-- (setLook).
local function chipControl(el, w, mid)
    el.lookKey = "chip"
    if mid then
        local t = theme.game.focusChipTint
        C.count(); w:SetBackgroundMaterial(mid, t.r, t.g, t.b, t.a, 0)
    else
        local c = theme.game.focusChipSolid
        C.count(); w:SetBackgroundSolid()
        C.count(); w:SetBackground(c.r, c.g, c.b, c.a)
    end
    local whole = mid ~= nil
    if el.kind == "choice" then
        local game = el.gameText
        local font = A.get(game and ("font:" .. theme.game.controlFont.font) or "font:Engine", true)
        local ink = theme.game.focusChipInk
        if font then C.count(); w:SetValueLook(font, game and theme.game.controlFont.size or theme.plainControlFont, ink.r, ink.g, ink.b, ink.a)
        else whole = false end
    end
    el.chipOn = whole and "strong" or "solid"
    return true
end
local function chipOn(el, w)
    if el.chipOn == "strong" then return end
    local okM, mid = pcall(A.focusChipMaterial, w, hookDepth > 0)
    if not okM then mid = nil end
    if el.chipOn == "solid" and not mid then return end -- solid already; the tick tries the instance again
    el.chipOn = "pending" -- until the whole chip is on: a failed one is restored on unfocus and tried again by the tick
    local ok, res = pcall(function()
        if el.kind == "button" or el.kind == "checkbox" then return B._chip(el, w, mid, chipPad(el)) end
        return chipControl(el, w, mid)
    end)
    if ok and res then S.chips = S.chips + 1
    elseif ok then el.chipOn = nil -- nothing drawn (a game-look labelled button without an instance keeps its face)
    else
        S.chipFaults = S.chipFaults + 1
        C.warnOnce("focus chip", "'%s': the focus chip failed (is %s's pak current?): %s", el.id, C.NAME, firstLine(res))
    end
end
-- The chip goes: the kind's own style draws it again (a button's style also puts its render scales back to 1).
local function chipOff(el, w)
    if el.kind == "choice" or el.kind == "slider" then el.lookKey = nil end -- its own look is drawn again
    local ok, err = pcall(X.KIND[el.kind].style, el, w, false)
    el.chipOn, el.faceOn = nil, nil
    if not ok then
        S.chipFaults = S.chipFaults + 1
        C.warnOnce("focus chip restore", "'%s': the focus chip could not be removed: %s", el.id, firstLine(err))
    end
end

local function setLook(el, on)
    if el and el.kind == "row" then return end -- core story 38: a grip row's look is the band (setRow)
    local w = el and widgetOf(el)
    if not w then
        if el then el.chipOn = nil end -- its widget is gone (a new one starts without a chip)
        return
    end
    local look = lookOf(el, on)
    -- Core story 39: a look that isn't wanted goes first (unfocused, the other input mode, outside a row): the kind's own
    -- style draws it again (SetColors / SetMaterials turn FocusLook off, so SetFocusLook below sets it afresh).
    if el.chipOn and look ~= "chip" then chipOff(el, w) end
    if el.faceOn and look ~= "face" then
        local okS, errS = pcall(X.KIND[el.kind].style, el, w, false) -- it clears faceOn
        el.faceOn = nil
        if not okS then C.warnOnce("focus face restore", "button '%s': restoring its own look failed: %s", el.id, firstLine(errS)) end
    end
    if look == "chip" then chipOn(el, w) end
    -- Core story 28: a face first where the hover look shows nothing (SetMaterials / SetColors turn FocusLook off).
    if look == "face" and not el.faceOn then
        local okF, res = pcall(B._focusFace, el, w)
        if okF and res then S.faces = S.faces + 1
        elseif not okF then C.warnOnce("focus face", "button '%s': its focus face failed (is %s's pak current?): %s", el.id, C.NAME, firstLine(res)) end
    end
    local ok, err = pcall(function() C.count(); w:SetFocusLook(on) end)
    if not ok then C.warnOnce("focus look", "the focus look failed (is %s's pak current?): %s", C.NAME, firstLine(err)) end
    if look == "chip" and el.kind == "slider" and el.chipOn then
        -- after SetFocusLook (it sets the number box's content tint): the number in the ink
        local okT, errT = pcall(function() C.count(); w.Background:SetContentColorAndOpacity(inkTint()) end)
        if not okT then
            S.chipFaults = S.chipFaults + 1
            C.warnOnce("focus chip", "'%s': the focus chip failed (is %s's pak current?): %s", el.id, C.NAME, firstLine(errT))
        end
    end
end

-- Core story 28: the row holding the focused element. on: the selection material behind it (el.selBg marks it; text.lua
-- clears the mark on any re-style); off: its own background (worn strip, colour or explicit background) through
-- text.lua's own path. True when the row shows the highlight (on) or a live row was restored (off).
-- Core story 30: with theme.game.focusRowStrong the highlight is the strong look (assets.lua A.focusRowMaterial, an
-- instance of the selection material with lifted fill colours, in focusRowTint); while that instance can't be had (none
-- alive inside core's key or click handling, control dispatch or a Construct hook; or it failed) the plain selection in
-- rowTint. row.selBg records which ("strong" | "plain"), so the UI tick upgrades a plain one (hookDepth: above).
local function rowLook(row, on)
    local w = widgetOf(row)
    if not w then return false end
    if on then
        local strong = theme.game.focusRowStrong == true
        if row.selBg == "strong" or (row.selBg and not strong) then return true end
        local m, t, look = nil, nil, nil
        if strong then
            local okM, mid = pcall(A.focusRowMaterial, w, hookDepth > 0)
            if okM and mid then m, t, look = mid, theme.game.focusRowTint, "strong" end
        end
        if not m then
            if row.selBg then return true end -- already the plain selection; the tick tries the strong look again
            m, t, look = A.get("mat:selection"), theme.game.rowTint, "plain"
        end
        if not m then return false end
        local ok, err = pcall(function() C.count(); w:SetBackgroundMaterial(m, t.r, t.g, t.b, t.a, row.style.pad) end)
        if not ok then C.warnOnce("focus row", "row '%s': the focus highlight failed (is %s's pak current?): %s", row.id, C.NAME, firstLine(err)) return false end
        X._applyRowPad(row, w) -- story 39: a list row keeps its taller padding
        row.matBg, row.selBg = true, look
        S.rowLooks = S.rowLooks + 1
        return true
    end
    local ok, err = pcall(X._backgroundStyle, row, w, false)
    row.selBg = nil
    if not ok then C.warnOnce("focus row restore", "row '%s': restoring its own background failed: %s", row.id, firstLine(err)) end
    return true
end
F._rowLook = rowLook

-- The highlighted row of rec's window becomes el's row (nil: none). At most one per window; a row that is gone
-- (removed, or its widget gone) is forgotten without a call.
local function setRow(rec, el)
    local row = rowOf(el)
    local cur = rec.lookRowId
    if cur and not (row and row.id == cur) then
        local old = C.els[cur]
        if old and not old.removed and old.kind == "row" then rowLook(old, false) end
        rec.lookRowId = nil
    end
    if row and rowLook(row, true) then rec.lookRowId = row.id end
end
F._setRow = setRow

-- Core story 28: the window no longer holds focus (another window covers it, or it closed): its focused element and
-- row go back to their own look; the model keeps the element (focusId) for the return.
local windowGone -- core story 38, below
function F.blur(rec)
    windowGone(rec)
    if rec.lookId then
        local old = C.els[rec.lookId]
        if old and not old.removed then setLook(old, false) end
        rec.lookId = nil
    end
    if rec.lookRowId then setRow(rec, nil) end
end

-- The list a focused element sits in (a row in a list, or a list's own child) and the widget to scroll into view.
local function scrollIntoView(el)
    local p = el.panel
    if not p then return end
    local list, item = nil, el
    if p.kind == "list" then list = p
    elseif p.kind == "row" and p.panel and p.panel.kind == "list" then list, item = p.panel, p end
    if not list then return end
    local lw, iw = widgetOf(list), widgetOf(item)
    if not (lw and iw) then return end
    local ok, err = pcall(function()
        local scroll = lw.Scroll
        C.count(); scroll:ScrollWidgetIntoView(iw, false, 0, list.gapUnits or 0) -- IntoView, no animation
    end)
    if not ok then C.warnOnce("scroll into view", "scrolling a focused row into view failed: %s", firstLine(err)) return end
    S.scrolls = S.scrolls + 1
end

local function backIdOf(rec) return "#close:" .. rec.id end
F._backIdOf = backIdOf

-- Moves keyboard focus to el (an element of rec's window): the target gets keyboard focus (and, with mode, the UI input
-- mode), the old look goes, el's look comes, rec remembers el. False when el has no live target. noScroll (story 36: a
-- hover): the list is not scrolled.
local function focusEl(rec, el, lines, mode, noScroll)
    local t = targetOf(el)
    if not t then return false end
    if mode then
        local pc = cb.owner and cb.owner()
        if pc then
            local okM, errM = pcall(function()
                StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_UIOnlyEx(pc, t, INPUT_DO_NOT_LOCK, false)
            end)
            if not okM then C.warnOnce("focus input mode", "setting the window's input mode failed: %s", firstLine(errM)) end
        end
    end
    local okK, errK = pcall(C.call0, t, "SetKeyboardFocus")
    if not okK then C.warnOnce("focus move", "moving keyboard focus to '%s' failed: %s", el.id, firstLine(errK)) end
    if rec.lookId and rec.lookId ~= el.id then
        local old = C.els[rec.lookId]
        if old and not old.removed then setLook(old, false) end
    end
    setLook(el, true)
    setRow(rec, el)
    rec.lookId = el.id
    rec.focusId = el.id
    local li, ci = F.find(lines, el)
    rec.focusPos = li and { li = li, ci = ci, owner = lines[li].owner } or rec.focusPos
    if not noScroll then scrollIntoView(el) end
    S.moves = S.moves + 1
    return true
end

-- The window widget itself takes focus (a window with nothing focusable).
local function focusWindowWidget(rec, mode)
    local w = cb.windowWidget and cb.windowWidget(rec)
    if not w then return end
    if mode then
        local pc = cb.owner and cb.owner()
        if pc then
            local okM, errM = pcall(function()
                StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):SetInputMode_UIOnlyEx(pc, w, INPUT_DO_NOT_LOCK, false)
            end)
            if not okM then C.warnOnce("focus input mode", "setting the window's input mode failed: %s", firstLine(errM)) end
        end
    end
    local okK, errK = pcall(C.call0, w, "SetKeyboardFocus")
    if not okK then C.warnOnce("focus move window", "moving keyboard focus to window '%s' failed: %s", rec.id, firstLine(errK)) end
    if rec.lookId then
        local old = C.els[rec.lookId]
        if old and not old.removed then setLook(old, false) end
        rec.lookId = nil
    end
    setRow(rec, nil)
end

-- Where keyboard focus is in rec's window now: the element whose target holds it (the remembered one first; another
-- one when Slate moved focus, a mouse click or the analog stick: the model follows), "window" when the window widget
-- itself holds it, nil when something else does (a text box).
local function focusedIn(rec, lines)
    local el = rec.focusId and C.els[rec.focusId] or nil
    if el and F.find(lines, el) and hasFocus(targetOf(el)) then return el end
    for _, l in ipairs(lines) do
        for _, e in ipairs(l.els) do
            if e ~= el and hasFocus(targetOf(e)) then
                if rec.lookId ~= e.id then
                    if rec.lookId and C.els[rec.lookId] then setLook(C.els[rec.lookId], false) end
                    setLook(e, true)
                    rec.lookId = e.id
                end
                setRow(rec, e)
                rec.focusId = e.id
                local li, ci = F.find(lines, e)
                rec.focusPos = { li = li, ci = ci, owner = l.owner }
                return e
            end
        end
    end
    local w = cb.windowWidget and cb.windowWidget(rec)
    if w and hasFocus(w) then return "window" end
    return nil
end
F._focusedIn = focusedIn

-- Core story 36: the platform cursor position when the keys or a window last took the band ({ x, y } | nil: unknown). A
-- hover at that position is content moving under a still pointer, not a pointer move.
local pointerAt = nil
local function pointerNow()
    local ok, x, y = pcall(function()
        local p = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetMousePositionOnPlatform()
        return p.X, p.Y
    end)
    if ok and type(x) == "number" and type(y) == "number" and x == x and y == y then return { x = x, y = y } end
    return nil
end
local function rememberPointer() pointerAt = pointerNow() end
local function samePointer()
    if not pointerAt then return false end
    local p = pointerNow()
    if not p then return false end -- unreadable: never blocks a hover
    return math.abs(p.x - pointerAt.x) < 1 and math.abs(p.y - pointerAt.y) < 1
end
-- Core story 42 (0.17.1): is the gamepad the current input? The game runs CommonUI: on gamepad input its analog cursor
-- moves or hides the platform cursor and can turn the Accept button into a simulated mouse click, which would look like
-- a real pointer move or a mouse click here. CommonInputSubsystem (the window's player controller's local player) knows:
-- true while its current input type is Gamepad (ECommonInputType 1); for a click (click true) also when its
-- bIsGamepadSimulatedClick is set. A hover never reads that flag: it can stay set after the simulated click, and a stale
-- flag must not block a real mouse hover (the type reads MouseAndKeyboard as soon as the mouse moves). A missing class
-- or no subsystem: false (story 39's rules); a failing call: false and one WARN naming the focus chip.
-- The class is a native one, found by StaticFindObject; after a miss it is not looked up again in this Lua state (a
-- miss scans every object). No UObject is kept across calls, no asset is loaded and no hook registered.
local CI_CLASS = "/Script/CommonInput.CommonInputSubsystem"
local CI_GAMEPAD = 1
local ciMissing = false
local function gamepadInput(click)
    if ciMissing then return false end
    local ok, yes = pcall(function()
        local cls = StaticFindObject(CI_CLASS)
        if not C.valid(cls) then ciMissing = true return false end
        local pc = cb.owner and cb.owner()
        if not C.valid(pc) then return false end
        local sub = StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary"):GetLocalPlayerSubsystem(pc, cls)
        if not C.valid(sub) then return false end
        if sub:GetCurrentInputType() == CI_GAMEPAD then return true end
        return click == true and sub.bIsGamepadSimulatedClick == true
    end)
    if not ok then
        C.warnOnce("focus chip gamepad", "the focus chip's gamepad check (CommonInputSubsystem) failed: %s", firstLine(yes))
        return false
    end
    return yes == true
end
F._gamepadInput = gamepadInput
F._resetGamepadInput = function() ciMissing = false end
-- Core story 39: the input mode becomes m ("keys" | "mouse"): the last input sets it. A change re-applies the current
-- element's look of every open window of this state that shows one (chip on or off at once). Returns whether it changed.
local function reapply()
    for _, rec in pairs(C.windows) do
        local el = rec.open and rec.lookId and C.els[rec.lookId] or nil
        if el and not el.removed then setLook(el, true) end
    end
end
local function input(m)
    if mode == m then return false end
    mode = m
    reapply()
    return true
end
F._mode = function() return mode end
F._input = input
-- The Accept key on a focused button or checkbox is left to its Button, which clicks itself (on the key's release):
-- that click is the key's, not a mouse click. { id, t }: the element and when (C.micros); any other input clears it.
local acceptKey = nil
local ACCEPT_US = 1500000
-- A click on id (F.used, or C.clickInput: the menu entry (nil), a window's BACK): the mouse, unless it is the click of
-- the Accept key just pressed on that element. Core story 42: and not while the gamepad is the current input or the
-- click is CommonUI's gamepad-simulated one (its Accept button as a click): the mode stays.
local function clickInput(id)
    local a = acceptKey
    acceptKey = nil
    if a and id ~= nil and a.id == id and C.micros and (C.micros() - a.t) < ACCEPT_US then return end
    if gamepadInput(true) then return end
    input("mouse")
end
C.onClickInput = clickInput

-- ---------------------------------------------------------------- core story 38: hold A / Enter to move a row
local hold = nil  -- { recId, id (the element the key went down on), rowId, listId, t (C.micros) }
local carry = nil -- { recId, rowId, listId, id (refocused after), pickup = { the list's children at the pickup } }
F._hold = function() return hold end
F._carry = function() return carry end
local function now() return C.micros and C.micros() or 0 end

-- The row an element would carry (a grip row is its own) and its list: a movable row of a reorderable list in this
-- state's global top window; nil otherwise.
local function carryRowOf(el)
    if type(el) ~= "table" then return nil end
    local row = rowOf(el)
    if not row then return nil end
    local list = row.panel
    if not (list and list.kind == "list" and RO.movable(row) and RO.active(list)) then return nil end
    return row, list
end

-- The carry look on (the carry band, else the strong band, else the plain selection; a render translation to the
-- right) or off (no translation; the row's own background, the caller puts the band back with focusEl).
local function carryLook(rec, row, on)
    local w = row and widgetOf(row)
    if not w then return end
    if on then
        local mid, look = nil, nil
        local okC, m = pcall(A.carryRowMaterial, w, hookDepth > 0)
        if okC and m then mid, look = m, "carry" end
        if not mid then
            local okS, sm = pcall(A.focusRowMaterial, w, true)
            if okS and sm then mid, look = sm, "strong" end
        end
        if not mid then mid, look = A.get("mat:selection"), "plain" end
        if mid and not (row.selBg == "carry" and row.carryBg == look) then
            local t = look == "plain" and theme.game.rowTint or theme.game.focusRowTint
            local ok, err = pcall(function() C.count(); w:SetBackgroundMaterial(mid, t.r, t.g, t.b, t.a, row.style.pad) end)
            if ok then
                X._applyRowPad(row, w)
                row.matBg, row.selBg, row.carryBg = true, "carry", look
            else C.warnOnce("carry look", "row '%s': the carry look failed (is %s's pak current?): %s", row.id, C.NAME, firstLine(err)) end
        end
        local d = theme.reorder.lift
        pcall(function() C.count(); w:SetRenderTranslation({ X = d, Y = 0 }) end)
        return
    end
    pcall(function() C.count(); w:SetRenderTranslation({ X = 0, Y = 0 }) end)
    row.carryBg = nil
    rowLook(row, false)
    if rec and rec.lookRowId == row.id then rec.lookRowId = nil end
end
F._carryLook = carryLook

-- After a drop or a cancel: focus back on the element the key went down on (else the nearest), when the window is
-- still this state's global top.
local function refocus(rec, c)
    if not (rec and rec.open and globalTop(rec)) then return end
    local lines = F.lines(C.windowHost(rec.id), backIdOf(rec))
    local el = C.els[c.id]
    if not (el and F.find(lines, el)) then el = F.recover(lines, rec.focusPos) end
    if el then focusEl(rec, el, lines, false) end
end

local function endCarry(rec, row)
    if not row or row.removed then return end
    carryLook(rec, row, false)
    if not gripRow(row) then focusableRow(row, widgetOf(row), false) end
end

-- Cancels a carry: the pickup order back (when the list still holds the same children), no callback.
local function cancelCarry(restore)
    local c = carry
    if not c then return end
    carry = nil
    local rec, list, row = C.windows[c.recId], C.els[c.listId], C.els[c.rowId]
    if restore and list and not list.removed and #list.children == #c.pickup then
        local same = true
        for _, ch in ipairs(c.pickup) do if ch.panel ~= list or ch.removed then same = false break end end
        if same then RO.apply(list, c.pickup) end
    end
    endCarry(rec, row)
    S.carryCancels = S.carryCancels + 1
    refocus(rec, c)
end
F._cancelCarry = cancelCarry

-- Drops a carry (the key's release): onReorder once when the order changed.
local function dropCarry()
    local c = carry
    if not c then return end
    carry = nil
    local rec, list, row = C.windows[c.recId], C.els[c.listId], C.els[c.rowId]
    endCarry(rec, row)
    S.drops = S.drops + 1
    local changed = list ~= nil and not list.removed and not RO.same(list.children, c.pickup)
    refocus(rec, c)
    rememberPointer() -- story 36: the rows moved under a still pointer
    if changed then RO.fire(list) end
end

-- One step of a carry (delta -1 up, +1 down): one rebuild, focus kept on the row, the row scrolled into view.
local function carryStep(delta)
    local list, row = C.els[carry.listId], C.els[carry.rowId]
    if not (list and row and not list.removed and not row.removed) then cancelCarry(false) return end
    local k = RO.step(list.children, row, delta)
    if not k then S.carryEdges = S.carryEdges + 1 return end
    local new = RO.moved(list.children, row, k)
    if not (new and RO.apply(list, new)) then return end
    S.carryMoves = S.carryMoves + 1
    local rw = widgetOf(row)
    if rw then pcall(C.call0, rw, "SetKeyboardFocus") end -- the rebuild took it out of the tree
    scrollIntoView(row)
end

-- A key while carrying: Back puts it back; Up / Down move it; anything else does nothing. Always handled.
local function carryNav(dir, act)
    if act == F.ACT.back then cancelCarry(true) return true end
    if act == F.ACT.accept then return true end -- the held key's repeats
    if dir == F.DIR.up or dir == F.DIR.previous then carryStep(-1)
    elseif dir == F.DIR.down or dir == F.DIR.next then carryStep(1) end
    return true
end

-- The pickup, from the loop once the key was held long enough: the element still holds keyboard focus (the key is
-- still down), its row is still movable. Keyboard focus goes to the row's own widget.
local function pickUp(h)
    local rec = C.windows[h.recId]
    if not (rec and rec.open and globalTop(rec)) or RO.dragging() then return false end
    local el, row = C.els[h.id], C.els[h.rowId]
    if not (el and row and not el.removed and not row.removed) then return false end
    local r2, list = carryRowOf(el)
    if r2 ~= row or list.id ~= h.listId then return false end
    if not hasFocus(targetOf(el)) then return false end
    local rw = widgetOf(row)
    if not rw then return false end
    focusableRow(row, rw, true)
    local okK = pcall(C.call0, rw, "SetKeyboardFocus")
    if not (okK and hasFocus(rw)) then
        if not gripRow(row) then focusableRow(row, rw, false) end
        C.warnOnce("carry focus", "row '%s': it could not take keyboard focus; it isn't picked up", row.id)
        return false
    end
    local pickup = {}
    for i, ch in ipairs(list.children) do pickup[i] = ch end
    carry = { recId = rec.id, rowId = row.id, listId = list.id, id = el.id, pickup = pickup }
    carryLook(rec, row, true)
    S.pickups = S.pickups + 1
    rememberPointer()
    return true
end

-- reorder.lua's loop (16 ms): a hold held long enough picks up; a carry keeps its row focused (focus nowhere: back on
-- it; on another element of the window: cancelled).
local function loopTick()
    if hold and now() - hold.t >= theme.reorder.holdMs * 1000 then
        local h = hold
        hold = nil
        hookDepth = hookDepth + 1
        C.inDispatch = C.inDispatch + 1 -- the pickup is part of the key path: cached assets only
        local ok, err = pcall(pickUp, h)
        C.inDispatch = C.inDispatch - 1
        hookDepth = hookDepth - 1
        if not ok then S.faults = S.faults + 1; C.warnOnce("carry pickup", "picking a row up failed: %s", firstLine(err)) end
    end
    local c = carry
    if not c then return end
    local rec, row = C.windows[c.recId], C.els[c.rowId]
    if not (rec and rec.open and globalTop(rec)) then cancelCarry(true) return end
    local rw = row and widgetOf(row)
    if not rw then cancelCarry(true) return end
    if hasFocus(rw) then return end
    local lines = F.lines(C.windowHost(rec.id), backIdOf(rec))
    for _, l in ipairs(lines) do
        for _, e in ipairs(l.els) do
            if e ~= row and hasFocus(targetOf(e)) then cancelCarry(true) return end -- focus moved on (not by a hover)
        end
    end
    S.carryRefocus = S.carryRefocus + 1
    pcall(C.call0, rw, "SetKeyboardFocus")
end

-- A change to a list (reorder.lua RO.interrupt): a hold or a carry in it ends (the carry's order back first).
local function interrupt(list)
    if hold and hold.listId == list.id then hold = nil end
    if carry and carry.listId == list.id then cancelCarry(true) end
end
-- A window covered or closed: its hold, carry and drag end.
windowGone = function(rec)
    if hold and hold.recId == rec.id then hold = nil end
    if carry and carry.recId == rec.id then cancelCarry(true) end
    local d = RO._drag()
    if d then
        local list = C.els[d.listId]
        local lrec = list and RO.windowOf(list)
        if not lrec or lrec.id == rec.id then RO.cancel(true) end
    end
end
F.windowClosed = function(rec) windowGone(rec) end

-- Mouse drag (reorder.lua): focus and the band on a row's element in the current column (no scroll at the drag's
-- start, scrolled into view at its drop); the drag is the mouse's input.
local function focusRow(row, scroll, start)
    local list = row.panel
    local rec = RO.windowOf(list)
    if not rec then return end
    if start then input("mouse") end
    local lines = F.lines(C.windowHost(rec.id), backIdOf(rec))
    local li = nil
    for i, l in ipairs(lines) do if l.owner == row.id then li = i break end end
    if not li then return end
    local els = lines[li].els
    local to = els[math.min((rec.focusPos and rec.focusPos.ci) or 1, #els)]
    rec.openFresh = false
    focusEl(rec, to, lines, false, not scroll)
end

-- Focus on open (fresh: its first focusable), and back on a window after the one above it closed (its remembered
-- element, else its first focusable); else the window widget. With the UI input mode. Story 39: the input mode stays
-- (a window opened by a mouse click shows no chip; by keys, the chip on its first control).
function F.focusWindow(rec, fresh)
    rememberPointer() -- story 36: a window opening under a still pointer doesn't take the band
    local lines = F.lines(C.windowHost(rec.id), backIdOf(rec))
    if fresh then rec.focusId, rec.focusPos, rec.lookId, rec.lookRowId = nil, nil, nil, nil end
    -- A dependent opens a window, then builds it: until the next UI tick (or the first key or click) focus follows the
    -- window's first element as elements arrive (F.changed).
    rec.openFresh = fresh == true
    local el = rec.focusId and C.els[rec.focusId] or nil
    if not (el and F.find(lines, el)) then el = lines[1] and lines[1].els[1] or nil end
    if el and focusEl(rec, el, lines, true) then return el end
    focusWindowWidget(rec, true)
    return nil
end

-- A window's model changed (an element created, removed, shown, hidden, disabled): a focused element that is no longer
-- focusable hands focus on (only while the window holds focus).
function F.changed(rec)
    if rec.openFresh then
        if not globalTop(rec) then return end
        local lines = F.lines(C.windowHost(rec.id), backIdOf(rec))
        local first = lines[1] and lines[1].els[1] or nil
        if first and first.id ~= rec.focusId then focusEl(rec, first, lines, true) end
        if first then return end
    end
    if not rec.focusId then return end
    local el = C.els[rec.focusId]
    if el and F.focusable(el) then return end
    local lines = F.lines(C.windowHost(rec.id), backIdOf(rec))
    if el and F.find(lines, el) then return end
    if not globalTop(rec) then return end
    local to = F.recover(lines, rec.focusPos)
    if to then
        S.recovered = S.recovered + 1
        focusEl(rec, to, lines, false)
    else
        rec.focusId = nil
        focusWindowWidget(rec, false)
    end
end

-- The UI tick (500 ms), top window only: keyboard focus left the window (another widget took it): back to the
-- remembered element; the focus look is put back on (a re-style removes it).
function F.tick(rec, w)
    rec.openFresh = false
    if carry and carry.recId == rec.id then
        -- core story 38: a carried row keeps its look; the tick upgrades a strong band to the carry band
        local row = C.els[carry.rowId]
        if row and row.carryBg ~= "carry" then carryLook(rec, row, true) end
        return
    end
    F.changed(rec)
    local okD, inside = pcall(C.call0, w, "HasFocusedDescendants")
    local okK, self = pcall(C.call0, w, "HasKeyboardFocus")
    if not ((okD and inside == true) or (okK and self == true)) then
        S.refocus = S.refocus + 1
        F.focusWindow(rec)
        return
    end
    local el = rec.focusId and C.els[rec.focusId]
    if el and not el.removed then
        if rec.lookId and rec.lookId ~= el.id then
            local old = C.els[rec.lookId]
            if old and not old.removed then setLook(old, false) end
        end
        setLook(el, true); rec.lookId = el.id
        setRow(rec, el) -- story 28: the row's highlight back after a re-style
    elseif rec.lookRowId then setRow(rec, nil) end
end

-- A mouse click (or drag, or commit) on an element of a window: the model's focus moves there.
local used
function F.used(el, noClick)
    hookDepth = hookDepth + 1 -- always inside a click, drag end, commit or arrow hook
    local ok, err = pcall(used, el, noClick)
    hookDepth = hookDepth - 1
    if not ok then error(err, 0) end
end
local navDepth = 0 -- > 0 while a key is handled (a step it causes reaches F.used: still the key's)
used = function(el, noClick)
    hold = nil -- core story 38: a click ends a hold (a tap's own click included) and cancels a carry
    if carry then cancelCarry(true) end
    -- Story 39: a click is the mouse's (on any host: the menu's elements too), unless it is a key's (the Accept key's
    -- click, a step inside the key's own handling).
    if navDepth == 0 and not noClick then clickInput(el and el.id) end
    if not F.focusable(el) then return end
    local host = C.hostOf(el)
    if type(host) ~= "string" or C.hostKind(host) ~= "screen" then return end
    local rec = C.windows[host:sub(8)]
    if not (rec and rec.open) then return end
    rec.openFresh = false
    rememberPointer() -- story 36: a click (and the scroll it can cause) under a still pointer keeps the band
    if rec.focusId == el.id and hasFocus(targetOf(el)) then return end
    -- Keyboard focus moves too: a choice's arrows and a slider's bar aren't focusable, so a click on them leaves Slate's
    -- focus where it was, and the next key would start from there.
    focusEl(rec, el, F.lines(host, backIdOf(rec)), false)
end

-- ---------------------------------------------------------------- one navigation event

local function validDir(d) return math.type(d) == "integer" and d >= 0 and d <= 5 end
local function validAct(a) return math.type(a) == "integer" and (a == 0 or a == 1) end

-- nav(rec, dir, act) -> handled. rec is this mod's open window that received the key.
function F.nav(rec, dir, act)
    dir = math.tointeger(tonumber(dir) or -1)
    act = math.tointeger(tonumber(act) or -1)
    local dOk, aOk = validDir(dir), validAct(act)
    if not dOk and not aOk then S.ignored = S.ignored + 1 return false end
    S.navs = S.navs + 1
    if cb.isTop and not cb.isTop(rec) then
        -- A window below the top one holds focus (a stale focus): give it back to the top one.
        local top = cb.top and cb.top()
        if top and globalTop(top) then F.focusWindow(top) end
        return true
    end
    rec.openFresh = false
    -- Core story 38: a carry takes every key; a mouse drag: Back cancels it, other keys do nothing.
    if carry then
        if carry.recId == rec.id then return carryNav(dir, aOk and act or nil) end
        cancelCarry(true)
    end
    if RO.dragging() then
        if aOk and act == F.ACT.back then RO.cancel(true) end
        return true
    end
    if not (aOk and act == F.ACT.accept) then hold = nil end
    local host = C.windowHost(rec.id)
    local lines = F.lines(host, backIdOf(rec))
    local el = focusedIn(rec, lines)
    if el == nil then return false end -- focus is on something else in the window (a text box): its key (Escape reverts)
    if aOk and act == F.ACT.back then
        if rec.close then
            S.closes = S.closes + 1
            cb.close(rec.id, "close")
        end
        return true
    end
    if el == "window" then
        -- The window itself holds focus: nothing focusable (keys do nothing), or focus came back to it.
        if #lines > 0 and dOk then focusEl(rec, lines[1].els[1], lines, false) end
        return true
    end
    if aOk then
        -- Core story 38: on a movable row's element (or a grip row) the key may be held to pick the row up (the loop
        -- decides); its repeats keep the hold.
        local row, list = carryRowOf(el)
        if row and S.upOk then
            if not (hold and hold.id == el.id) then
                hold = { recId = rec.id, id = el.id, rowId = row.id, listId = list.id, t = now() }
                S.holds = S.holds + 1
                RO.want()
            end
        else
            hold = nil
        end
        -- Accept: a Button clicks itself (its own Accept); on a choice or a slider nothing changes.
        if el.kind == "button" or el.kind == "checkbox" then
            acceptKey = { id = el.id, t = C.micros and C.micros() or 0 } -- story 39: its click is this key's
            return false
        end
        return true
    end
    if dir == F.DIR.left or dir == F.DIR.right then
        local delta = dir == F.DIR.left and -1 or 1
        if el.kind == "choice" or el.kind == "slider" then
            local w = widgetOf(el)
            if w then
                S.steps = S.steps + 1
                if el.kind == "choice" then CH._stepEl(el, w, delta) else SL._nudge(el, w, delta) end
            end
            return true
        end
    end
    local li, ci = F.find(lines, el)
    if not li then return true end
    local nli, nci = F.move(lines, li, ci, dir)
    local to = lines[nli].els[nci]
    if to ~= el or not hasFocus(targetOf(el)) then focusEl(rec, to, lines, false) end
    return true
end

-- The post-hook on <Core>_OnNav. Silent for another mod's window, a stale widget, a closed window and bad values.
local function navBody(ctx)
    if C.offGameThread() then S.ignored = S.ignored + 1 return end
    local w = ctx:get()
    if not C.valid(w) then S.ignored = S.ignored + 1 return end
    local okT, tag = pcall(function() return w.CoreTag:ToString() end)
    if not (okT and type(tag) == "string") then S.ignored = S.ignored + 1 return end
    local mine = C.LOWER .. ":" .. C.modTag .. ":#screen:"
    if tag:sub(1, #mine) ~= mine then S.ignored = S.ignored + 1 return end -- another mod's window
    local rec = C.windows[tag:sub(#mine + 1)]
    if not (rec and rec.open) then S.ignored = S.ignored + 1 return end
    local live = cb.windowWidget and cb.windowWidget(rec)
    if not live or live:GetAddress() ~= w:GetAddress() then S.ignored = S.ignored + 1 return end -- not its live widget
    local okV, dir, act = pcall(function() return w.NavDir, w.NavAction end)
    if not okV then S.ignored = S.ignored + 1 return end
    -- Story 39: a navigation key is an input of the keys (handled or left to the focused widget); an element the key
    -- moves to gets its look in keys mode at once, and the current look is re-applied after (a key that moves nothing,
    -- at the end of a line, brings the chip back too).
    local changed = false
    if validDir(math.tointeger(tonumber(dir) or -1)) or validAct(math.tointeger(tonumber(act) or -1)) then
        acceptKey = nil
        changed = mode ~= "keys"
        mode = "keys"
        -- Core story 42: every valid key records the pointer (handled or left to the focused widget): content moving
        -- under a still pointer after it (an Accept's click, a list rebuilt) is not a hover.
        rememberPointer()
    end
    navDepth = navDepth + 1
    local okN, handled = pcall(F.nav, rec, dir, act)
    navDepth = navDepth - 1
    if changed then reapply() end
    if not okN then error(handled, 0) end
    if handled then
        S.handled = S.handled + 1
        rememberPointer() -- story 36: the keys own the band until the pointer really moves
        local okH, errH = pcall(function() w.NavHandled = true end)
        if not okH then C.warnOnce("nav handled", "window keys: setting NavHandled failed: %s", firstLine(errH)) end
    end
end
local function onNav(ctx)
    hookDepth = hookDepth + 1
    local ok, err = pcall(navBody, ctx)
    hookDepth = hookDepth - 1
    if not ok then
        S.faults = S.faults + 1
        C.warnOnce("nav dispatch", "window key handling failed: %s (further failures not logged)", firstLine(err))
    end
end
F._onNav, F._navBody = onNav, navBody

-- Core story 36: the post-hook on WBP_<Core>Row's <Core>_OnHover (its OnMouseEnter). Silent (counted) for another mod's
-- row, a stale widget, a row of a non-screen host, a closed or covered window, a row without a focusable line, an enter
-- under a still pointer and the row already holding focus; nothing changes while focus is on a text box of the window
-- or outside it.
local function hoverBody(ctx)
    local function ignore() S.hoverIgnored = S.hoverIgnored + 1 end
    if C.offGameThread() then return ignore() end
    if hold or carry or RO.dragging() then return ignore() end -- core story 38
    local w = ctx:get()
    if not C.valid(w) then return ignore() end
    local okT, tag = pcall(function() return w.CoreTag:ToString() end)
    if not (okT and type(tag) == "string") then return ignore() end
    local mine = C.LOWER .. ":" .. C.modTag .. ":"
    if tag:sub(1, #mine) ~= mine then return ignore() end -- another mod's row
    local row = C.els[tag:sub(#mine + 1)]
    if not (row and not row.removed and row.kind == "row") then return ignore() end
    local live = widgetOf(row)
    if not live or live:GetAddress() ~= w:GetAddress() then return ignore() end -- not its live widget
    local host = C.hostOf(row)
    if type(host) ~= "string" or C.hostKind(host) ~= "screen" then return ignore() end
    local rec = C.windows[host:sub(8)]
    if not (rec and rec.open) or not globalTop(rec) then return ignore() end
    if samePointer() then return ignore() end -- content moved under a still pointer
    -- Core story 42: a pointer moved by CommonUI's analog cursor under gamepad input is not the mouse's: focus and mode
    -- stay; the position is recorded so the cursor's next still enter is content moving. The input type only: the
    -- simulated-click flag is for clicks (a stale one must not block a real mouse hover).
    if gamepadInput() then
        rememberPointer()
        return ignore()
    end
    local lines = F.lines(host, backIdOf(rec))
    local li = nil
    for i, l in ipairs(lines) do if l.owner == row.id then li = i break end end
    if not li then return ignore() end -- no focusable in the row
    local cur = focusedIn(rec, lines)
    if cur == nil then return ignore() end -- a text box (or something outside the window) holds keyboard focus
    -- Story 39: a real pointer move into a focusable row of the top window is an input of the mouse: no chip from here
    -- on (an ignored hover, above, changes nothing).
    acceptKey = nil
    input("mouse")
    if cur ~= "window" and F.find(lines, cur) == li then -- the row already holds focus: the pointer owns it now
        rememberPointer()
        return ignore()
    end
    local els = lines[li].els
    local to = els[math.min((rec.focusPos and rec.focusPos.ci) or 1, #els)]
    if not focusEl(rec, to, lines, false, true) then return ignore() end -- no live target
    rec.openFresh = false
    S.hovers = S.hovers + 1
    rememberPointer()
end
local function onHover(ctx)
    hookDepth = hookDepth + 1
    C.inDispatch = C.inDispatch + 1 -- cached assets only, no hook registration (story 37's rule)
    local ok, err = pcall(hoverBody, ctx)
    C.inDispatch = C.inDispatch - 1
    hookDepth = hookDepth - 1
    if not ok then
        S.faults = S.faults + 1
        C.warnOnce("hover dispatch", "window row hover handling failed: %s (further failures not logged)", firstLine(err))
    end
end
F._onHover = onHover

-- Core story 38: the post-hook on <Core>_OnNavUp (the window's OnKeyUp: a key's release no focused widget handled).
-- The Accept key's release drops a carry (handled) or ends a hold (a tap); anything else is left alone. Silent for
-- another mod's window, a stale widget and a closed window, as navBody.
local function navUpBody(ctx)
    if C.offGameThread() then S.ignored = S.ignored + 1 return end
    local w = ctx:get()
    if not C.valid(w) then S.ignored = S.ignored + 1 return end
    local okT, tag = pcall(function() return w.CoreTag:ToString() end)
    if not (okT and type(tag) == "string") then S.ignored = S.ignored + 1 return end
    local mine = C.LOWER .. ":" .. C.modTag .. ":#screen:"
    if tag:sub(1, #mine) ~= mine then S.ignored = S.ignored + 1 return end
    local rec = C.windows[tag:sub(#mine + 1)]
    if not (rec and rec.open) then S.ignored = S.ignored + 1 return end
    local live = cb.windowWidget and cb.windowWidget(rec)
    if not live or live:GetAddress() ~= w:GetAddress() then S.ignored = S.ignored + 1 return end
    local okV, act = pcall(function() return w.NavAction end)
    act = okV and math.tointeger(tonumber(act) or -1) or -1
    if act ~= F.ACT.accept then return end
    S.ups = S.ups + 1
    if carry and carry.recId == rec.id then
        dropCarry()
        local okH, errH = pcall(function() w.NavHandled = true end)
        if not okH then C.warnOnce("nav up handled", "window keys: setting NavHandled failed: %s", firstLine(errH)) end
    elseif hold and hold.recId == rec.id then
        hold = nil
        S.taps = S.taps + 1 -- a tap: the control's own action (or none)
    end
end
local function onNavUp(ctx)
    hookDepth = hookDepth + 1
    C.inDispatch = C.inDispatch + 1 -- cached assets only (story 37's rule); onReorder runs as a dependent callback
    local ok, err = pcall(navUpBody, ctx)
    C.inDispatch = C.inDispatch - 1
    hookDepth = hookDepth - 1
    if not ok then
        S.faults = S.faults + 1
        C.warnOnce("reorder handling", "window key release (reorder handling) failed: %s (further failures not logged)", firstLine(err))
    end
end
F._onNavUp = onNavUp

-- From the UI poll (reorder.lua's dispatch, never inside a hook), once this state has a reorderable list and the window
-- class is loaded. Once; a failure is one WARN (an old pak: a row can't be picked up with the keys).
local function ensureUpHook()
    if S.upHooked or X._inHook() then return end
    if not X._classOf("screen") then return end
    S.upTries = S.upTries + 1
    local ok, err = pcall(RegisterHook, C.NAVUP_FN, onNavUp)
    S.upHooked, S.upOk = true, ok
    if ok then C.log.debug("ui window key release hook registered on %s", C.NAVUP_FN)
    else C.warnOnce("nav up hook", "window keys: RegisterHook(%s) failed (is %s's pak current?): %s; rows can't be picked up with A or Enter", C.NAVUP_FN, C.NAME, firstLine(err)) end
end
F._ensureUpHook = ensureUpHook

RO.cb.globalTop = globalTop
RO.cb.focusRow = focusRow
RO.cb.remember = function() rememberPointer() end
RO.cb.carrying = function() return carry ~= nil end
RO.cb.busy = function() return hold ~= nil or carry ~= nil end
RO.cb.tick = loopTick
RO.cb.interrupt = interrupt
RO.cb.ensure = ensureUpHook

-- From the UI poll (never inside a hook), once this mod has a window and the window class is loaded.
local function ensureHook()
    if S.hooked or X._inHook() then return S.hooked end
    if not X._classOf("screen") then return false end
    S.hookTries = S.hookTries + 1
    local ok, err = pcall(RegisterHook, F.NAV_FN, onNav)
    S.hooked = true -- once only (a retry could double the hook)
    if ok then C.log.debug("ui window key hook registered on %s", F.NAV_FN)
    else C.warnOnce("nav hook", "window keys: RegisterHook(%s) failed: %s", F.NAV_FN, firstLine(err)) end
    return true
end
F._ensureHook = ensureHook
-- Story 36: the same for the row's hover counter, once the row class is loaded.
local function ensureHoverHook()
    if S.hoverHooked or X._inHook() then return S.hoverHooked end
    if not X._classOf("row") then return false end
    S.hoverTries = S.hoverTries + 1
    local ok, err = pcall(RegisterHook, C.HOVER_FN, onHover)
    S.hoverHooked = true -- once only (a retry could double the hook)
    if ok then C.log.debug("ui window row hover hook registered on %s", C.HOVER_FN)
    else C.warnOnce("hover hook", "window rows: RegisterHook(%s) failed (is %s's pak current?): %s; the focus band follows keys and clicks only", C.HOVER_FN, C.NAME, firstLine(err)) end
    return true
end
F._ensureHoverHook = ensureHoverHook
H._host{ poll = function() end, reset = function() end, dispatch = function()
    if (S.hooked and S.hoverHooked) or not next(C.windows) then return nil end
    ensureHook()
    ensureHoverHook()
    return nil
end }

function F.init(callbacks) for k, v in pairs(callbacks) do cb[k] = v end end
function F.stats()
    local out = {}
    for k, v in pairs(S) do out[k] = v end
    return out
end
F._S = S
return F
