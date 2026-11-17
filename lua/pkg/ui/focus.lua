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
-- Each window remembers its last-focused element (by id): after a close the next window down gets it back.
local BASE = (...):gsub("%.ui%.focus$", "")
local C = require(BASE .. ".ui.common")
local H = require(BASE .. ".ui.hud")
local X = require(BASE .. ".ui.text")
local CH = require(BASE .. ".ui.choice")
local SL = require(BASE .. ".ui.slider")
local A = require(BASE .. ".ui.assets")
local B = require(BASE .. ".ui.button")
local theme = require(BASE .. ".ui.theme")

local F = {}
F.DIR = { left = 0, right = 1, up = 2, down = 3, next = 4, previous = 5 }
F.ACT = { accept = 0, back = 1 }
F.NAV_FN = C.SCREEN_CLASS .. ":" .. C.NAME .. "_OnNav"
local FOCUSABLE = { button = true, checkbox = true, choice = true, slider = true }
local INPUT_DO_NOT_LOCK = 0
local S = { navs = 0, handled = 0, ignored = 0, moves = 0, steps = 0, closes = 0, refocus = 0, recovered = 0,
    scrolls = 0, faults = 0, hooked = false, hookTries = 0, rowLooks = 0, faces = 0 }

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

function F.focusable(el)
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

-- lines(host, backId) -> { { els = { el, ... }, owner = <row or list id | nil> }, ... }
function F.lines(host, backId)
    local lines = {}
    local function push(els, owner) if #els > 0 then lines[#lines + 1] = { els = els, owner = owner } end end
    for _, el in ipairs(C.order) do
        if not el.removed and not el.panel and el.place.host == host and el.kind == "list" and el.visible then
            for _, ch in ipairs(el.children) do
                if not ch.removed then
                    if ch.kind == "row" then
                        if ch.visible then push(lineOf(ch), ch.id) end
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

-- The widget keyboard focus goes to: a button's (and a checkbox's) inner Button, a choice's or a slider's own widget.
local function targetOf(el)
    local w = widgetOf(el)
    if not w then return nil end
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

local function setLook(el, on)
    local w = el and widgetOf(el)
    if not w then return end
    -- Core story 28: a face first where the hover look shows nothing (SetMaterials / SetColors turn FocusLook off).
    if on and not el.faceOn and B._needsFace(el) then
        local okF, res = pcall(B._focusFace, el, w)
        if okF and res then S.faces = S.faces + 1
        elseif not okF then C.warnOnce("focus face", "button '%s': its focus face failed (is %s's pak current?): %s", el.id, C.NAME, firstLine(res)) end
    end
    local ok, err = pcall(function() C.count(); w:SetFocusLook(on) end)
    if not ok then C.warnOnce("focus look", "the focus look failed (is %s's pak current?): %s", C.NAME, firstLine(err)) end
    if not on and el.faceOn then
        -- the kind's own style draws it again (it clears faceOn)
        local okS, errS = pcall(X.KIND[el.kind].style, el, w, false)
        el.faceOn = nil
        if not okS then C.warnOnce("focus face restore", "button '%s': restoring its own look failed: %s", el.id, firstLine(errS)) end
    end
end

-- Core story 28: the row holding the focused element. on: the selection material behind it (el.selBg marks it; text.lua
-- clears the mark on any re-style); off: its own background (worn strip, colour or explicit background) through
-- text.lua's own path. True when the row shows the highlight (on) or a live row was restored (off).
-- Core story 30: with theme.game.focusRowStrong the highlight is the strong look (assets.lua A.focusRowMaterial, an
-- instance of the selection material with lifted fill colours, in focusRowTint); while that instance can't be had (none
-- alive inside core's key or click handling, control dispatch or a Construct hook; or it failed) the plain selection in
-- rowTint. row.selBg records which ("strong" | "plain"), so the UI tick upgrades a plain one. hookDepth: > 0 while this
-- module's OnNav post-hook or F.used (a click, drag end, commit or arrow) runs; a dependent's callback after it is not
-- counted.
local hookDepth = 0
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

local function rowOf(el)
    local p = el and el.panel
    if p and p.kind == "row" and not p.removed then return p end
    return nil
end

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
function F.blur(rec)
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
-- mode), the old look goes, el's look comes, rec remembers el. False when el has no live target.
local function focusEl(rec, el, lines, mode)
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
    scrollIntoView(el)
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

-- Focus on open (fresh: its first focusable), and back on a window after the one above it closed (its remembered
-- element, else its first focusable); else the window widget. With the UI input mode.
function F.focusWindow(rec, fresh)
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
function F.used(el)
    hookDepth = hookDepth + 1 -- always inside a click, drag end, commit or arrow hook
    local ok, err = pcall(used, el)
    hookDepth = hookDepth - 1
    if not ok then error(err, 0) end
end
used = function(el)
    if not F.focusable(el) then return end
    local host = C.hostOf(el)
    if type(host) ~= "string" or C.hostKind(host) ~= "screen" then return end
    local rec = C.windows[host:sub(8)]
    if not (rec and rec.open) then return end
    rec.openFresh = false
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
        -- Accept: a Button clicks itself (its own Accept); on a choice or a slider nothing changes.
        return not (el.kind == "button" or el.kind == "checkbox")
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
    if F.nav(rec, dir, act) then
        S.handled = S.handled + 1
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
H._host{ poll = function() end, reset = function() end, dispatch = function()
    if S.hooked or not next(C.windows) then return nil end
    ensureHook()
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
