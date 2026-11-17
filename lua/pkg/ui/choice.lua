-- UI-11 (Mod Manager story 4, core 0.10.0, core story 26): choices. Exposed as core.ui.choice on the connect API:
--   create{ id = <string>, options = { <string>, ... }, selected = <index|nil>, onChange = <function>,
--           place = <intent|nil>, enabled = <boolean|nil>, tooltip = <tooltip|nil>, widget = "core" | nil } -> handle
--   get(handle) -> index, option    set(handle, index)              setEnabled(handle, enabled)
--   setVisible(handle, visible)     remove(handle)                  isShown(handle) -> boolean
--   setTooltip(handle, <tooltip> | nil)
--   range{ id = <string|nil>, min, max, step, extra = { <string>, ... } | nil } -> options
--
-- A choice shows one of 1-64 options (each 1-64 bytes) between a previous and a next arrow (WBP_<Core>Choice, generated
-- by CoreGen). An arrow steps one option, with no wrap; at its end it is dimmed and ignores clicks, as on the game's
-- MultipleSelectBox_C. The shown option is right from the widget's first frame: core sets it before the widget joins
-- its container. A real arrow click runs onChange(handle, index, option) on the game thread inside pcall, exactly once;
-- set never calls back. A throwing onChange is logged once per choice and the choice keeps working. enabled = false
-- keeps it visible, dimmed (both arrows dimmed, the disabled opacity) and ignores clicks: read-only settings use it.
-- In the game look (the default on menu and screen) the value and the arrows are AlumniSans in the menu's text colours
-- on the worn strip; in the plain look the engine font on a dark box.
--
-- Core story 33 (0.15.0): widget = "game" is the game's own picker (MultipleSelectBox_C), on game-screen hosts only
-- (directly, or in a row, panel or list there; with no place it starts on createServer's canvas, for a game-style
-- row's control = <handle> to move it into the row). Its element is an internal kind (gchoice): a core-tagged
-- WBP_<Core>Row wrapper with no background holding one picker made with WidgetBlueprintLibrary:Create (a tag on the
-- picker itself would show as its tooltip). The options must be distinct (the picker selects by text); the shown
-- option is the picker's DefaultOption (which its PreConstruct shows again on every re-add or rebuild) and
-- SetSelectedOption once it is in the wrapper. tooltip is refused (help belongs on the row's "?"). enabled = false
-- disables the picker (SetIsEnabled, the disabled opacity) and the hook ignores it. Dispatch: one post-hook per Lua
-- state on each of the picker's two arrow handlers, registered from the UI poll once a game choice exists (re-registered
-- when the class is loaded again), filtered to this state's live pickers; a real change runs onChange once in pcall,
-- with the same debounce and throw rules as the core choice (a click it drops puts the picker back on its option).
--
-- Dispatch: each dependent's Lua state registers one post-hook on <class>:<Core>_OnPrev and one on <Core>_OnNext, by
-- full path, from the UI poll once a choice exists (never inside a hook). The hook ignores other mods' widgets in silence
-- (their tag), a widget that isn't the element's current one, and repeats within 250 ms on the same arrow.
--
-- range builds the options of a bounded number range: extra first (e.g. { "Default" }), then min, min + step, ... up to
-- max, each formatted with as many decimals as step and min have; at most 64 strings in all.
local BASE = (...):gsub("%.ui%.choice$", "")
local C = require(BASE .. ".ui.common")
local H = require(BASE .. ".ui.hud")
local P = require(BASE .. ".ui.place")
local X = require(BASE .. ".ui.text")
local A = require(BASE .. ".ui.assets")
local St = require(BASE .. ".ui.strings")
local theme = require(BASE .. ".ui.theme")
local G = require(BASE .. ".ui.game") -- core story 33: the game choice's hook check on the game screens' ticks

local CH = {}
local MAX_OPTIONS, MAX_OPTION_BYTES = 64, 64
local DEBOUNCE_US = 250000
local CREATE_KEYS = { id = true, options = true, selected = true, onChange = true, place = true, enabled = true, tooltip = true, widget = true }
local RANGE_KEYS = { id = true, min = true, max = true, step = true, extra = true }
local S = { clicks = 0, dropped = 0, debounced = 0, ignored = 0, throws = 0, hooked = false }

local function firstLine(e) return (tostring(e):match("^[^\n]*")) end
local function keyList(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, ", ")
end

-- ---------------------------------------------------------------- the kind

local function colourKey(c) return string.format("%.4f,%.4f,%.4f,%.4f", c.r, c.g, c.b, c.a) end

-- The arrows: enabled at neither end while the choice is enabled; the on colour is the look's text colour.
local function applyArrows(el, w)
    local prevOn = el.enabled and el.index > 1
    local nextOn = el.enabled and el.index < #el.options
    local on = el.gameText and theme.game.text or theme.white
    local off = theme.dimmed
    local key = tostring(prevOn) .. tostring(nextOn) .. colourKey(on)
    if key == el.arrowKey then return end
    C.count(); w:SetArrows(prevOn, nextOn, on.r, on.g, on.b, on.a, off.r, off.g, off.b, off.a)
    el.arrowKey = key
end

local function applyValue(el, w)
    local t = el.options[el.index]
    if t == el.shownText then return end
    C.count(); w:SetValueText(t)
    el.shownText = t
end

local function applyEnabled(el, w)
    if el.appliedEnabled == el.enabled then return end
    C.count(); w:SetRenderOpacity(el.enabled and 1 or theme.disabledOpacity)
    el.appliedEnabled = el.enabled
end

-- The look: the game's (worn strip, AlumniSans, the menu's text colours) or the plain one (the engine font, white, on a
-- dark box). A game asset that can't be loaded leaves the plain look (assets.lua warned once).
local function look(el, w)
    local game = X._lookOf(el) == "game"
    local g = theme.game
    if game then
        local strip, font = A.get("mat:strip"), A.get("font:" .. g.controlFont.font)
        if strip and font then
            if el.lookKey == "game" then return end
            local t, c = g.controlTint, g.text
            C.count(); w:SetBackgroundMaterial(strip, t.r, t.g, t.b, t.a, 0)
            C.count(); w:SetValueLook(font, g.controlFont.size, c.r, c.g, c.b, c.a)
            el.lookKey, el.gameText = "game", true
            return
        end
    end
    if el.lookKey == "plain" then return end
    local font = A.get("font:Engine")
    local bg = theme.plainControl
    C.count(); w:SetBackgroundSolid()
    C.count(); w:SetBackground(bg.r, bg.g, bg.b, bg.a)
    if font then C.count(); w:SetValueLook(font, theme.plainControlFont, 1, 1, 1, 1) end
    el.lookKey, el.gameText = "plain", false
end

X.KIND.choice = {
    pkg = C.CHOICE_PKG, short = C.CHOICE_SHORT, cls = C.CHOICE_CLASS,
    content = function(el, w, fresh)
        if fresh then el.shownText, el.arrowKey, el.appliedEnabled = nil, nil, true end
        applyValue(el, w)
        applyEnabled(el, w)
        X._applyTooltip(el, w, fresh)
    end,
    style = function(el, w, fresh)
        if fresh then el.lookKey, el.arrowKey = nil, nil end
        local ok, err = pcall(look, el, w)
        if not ok then C.warnOnce("look:" .. el.id, "choice '%s': its look was not applied (is %s's pak current?): %s", el.id, C.NAME, firstLine(err)) end
        applyArrows(el, w) -- the arrows' colour follows the look
    end,
}

local function refresh(el)
    local w = X._liveWidget(el)
    if not w then return end
    local ok, err = pcall(function()
        applyValue(el, w)
        applyArrows(el, w)
        applyEnabled(el, w)
    end)
    if not ok then C.warnOnce("choice:" .. el.id, "choice '%s': update failed (is %s's pak current?): %s", el.id, C.NAME, firstLine(err)) end
end

-- ---------------------------------------------------------------- the arrows' hooks (one each per Lua state)

local function chainVisible(el)
    local n = 0
    while el and n < 4 do
        if not el.visible then return false end
        el, n = el.panel, n + 1
    end
    return true
end

local function step(ctx, delta)
    local w = ctx:get()
    if not C.valid(w) then return end
    local tag = X._readTag(w, "choice")
    local mine = C.LOWER .. ":" .. C.modTag .. ":"
    if not tag or tag:sub(1, #mine) ~= mine then S.ignored = S.ignored + 1 return end -- another mod's choice
    local el = C.els[tag:sub(#mine + 1)]
    if not el or el.removed or el.kind ~= "choice" then S.ignored = S.ignored + 1 return end
    local cur = el.ref and C.deref(el.ref)
    if not cur or cur:GetAddress() ~= w:GetAddress() then S.ignored = S.ignored + 1 return end -- not its live widget
    C.used(el) -- core story 27: a window's focus follows the mouse
    return CH._stepEl(el, w, delta)
end

-- Core story 27: one step of a validated choice (an arrow click, or Left / Right on the focused choice): the same
-- enabled, visibility, debounce and end-of-range rules, onChange once.
function CH._stepEl(el, w, delta)
    if not el.enabled or not chainVisible(el) then S.dropped = S.dropped + 1 return end
    -- A repeat within 250 ms on the same arrow is one click; each arrow has its own time, set only by a click that
    -- changed the option (an inert end arrow's click never delays the other arrow).
    local now = C.micros()
    el.lastStep = el.lastStep or {}
    local last = el.lastStep[delta]
    if last and now - last < DEBOUNCE_US then S.debounced = S.debounced + 1 return end
    local new = el.index + delta
    if new < 1 or new > #el.options then S.dropped = S.dropped + 1 return end -- no wrap: the arrow at its end is inert
    el.lastStep[delta] = now
    el.index = new
    S.clicks = S.clicks + 1
    C.inDispatch = C.inDispatch + 1
    local okA, errA = pcall(function() applyValue(el, w) applyArrows(el, w) end)
    C.inDispatch = C.inDispatch - 1
    if not okA then C.warnOnce("choice:" .. el.id, "choice '%s': showing its option failed: %s", el.id, firstLine(errA)) end
    if C.debugOn() then C.log.debug("ui choice '%s' -> %d", el.id, new) end
    local ok, err = pcall(el.onChange, el.handle, new, el.options[new])
    if not ok then
        S.throws = S.throws + 1
        if not el.warnedChange then
            el.warnedChange = true
            C.log.warn("choice '%s' onChange: %s", el.id, firstLine(err))
        end
    end
end

local function onPrev(ctx)
    local ok, err = pcall(step, ctx, -1)
    if not ok then C.warnOnce("choice dispatch", "choice click handling failed: %s (further failures not logged)", firstLine(err)) end
end
local function onNext(ctx)
    local ok, err = pcall(step, ctx, 1)
    if not ok then C.warnOnce("choice dispatch", "choice click handling failed: %s (further failures not logged)", firstLine(err)) end
end

-- From the UI poll (never inside a hook), once a choice exists and its class is loaded.
local function ensureHooks()
    if S.hooked or X._inHook() then return S.hooked end
    if not X._classOf("choice") then
        C.warnOnce("choice hook class", "choice clicks can't be hooked yet: %s is not loaded (is Content/Paks/LogicMods/%s.pak installed?); retried at the next poll", C.CHOICE_CLASS, C.NAME)
        return false
    end
    local okP, errP = pcall(RegisterHook, C.PREV_FN, onPrev)
    local okN, errN = pcall(RegisterHook, C.NEXT_FN, onNext)
    if okP and okN then
        S.hooked = true
        C.log.debug("ui choice hooks registered on %s and %s", C.PREV_FN, C.NEXT_FN)
    else
        S.hooked = true -- a half-registered pair would double one arrow on a retry; one WARN instead
        C.warnOnce("choice hook", "choice arrows: RegisterHook failed: %s", firstLine(okP and errN or errP))
    end
    return S.hooked
end
H._host{ poll = function() end, reset = function() end, dispatch = function()
    if S.hooked then return nil end
    for _, el in ipairs(C.order) do
        if el.kind == "choice" and not el.removed then ensureHooks() return nil end
    end
    return nil
end }

-- ---------------------------------------------------------------- core story 33: the game's picker (widget = "game")
local GS = { clicks = 0, dropped = 0, debounced = 0, ignored = 0, throws = 0, hookKey = nil, hookedOk = false, hookChecks = 0, needCheck = false, ticking = {} }
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"

local function classNameOf(w)
    local ok, n = pcall(function() return w:GetClass():GetFName():ToString() end)
    return ok and n or nil
end
local function msbOf(el)
    if not el.msbRef then return nil end
    local ok, o = pcall(C.deref, el.msbRef)
    return ok and o or nil
end
local function optionsKey(opts) return table.concat(opts, "\0") end
local function selectedOf(m)
    local ok, i = pcall(function() return m:GetSelectedIndex() end)
    return ok and math.tointeger(tonumber(i)) or nil
end

-- The picker shows el.index: DefaultOption (what PreConstruct shows on every re-add) and the selection now.
local function gShow(el, m)
    C.count(); m.DefaultOption = el.options[el.index]
    if selectedOf(m) ~= el.index - 1 then C.count(); m:SetSelectedOption(el.index - 1) end
    el.shownIndex = el.index
end
local function gEnabled(el, m)
    if el.appliedEnabled == el.enabled then return end
    C.count(); m:SetIsEnabled(el.enabled)
    C.count(); m:SetRenderOpacity(el.enabled and 1 or theme.disabledOpacity)
    el.appliedEnabled = el.enabled
end

-- A new picker with el's options into the wrapper w's HBox (raises).
local function newPicker(el, w)
    local cls, why = A.get("cls:msb")
    if not cls then return nil, why end -- assets.lua warned once (missing); the choice shows nothing
    local s = X._attachHostObj()
    C.count()
    local m = StaticFindObject(WBL):Create(s or w, cls, X._ownerFor(w))
    if not C.valid(m) then error("creating " .. C.MSB_SHORT .. " failed", 0) end
    for _, o in ipairs(el.options) do C.count(); m:AddOption(o, {}) end
    C.count(); m.DefaultOption = el.options[el.index]
    C.count()
    local slot = w.HBox:AddChild(m)
    -- the picker fills its wrapper, as the game's fills its row's control slot (its ScaleBox then scales like the game's)
    pcall(function() C.count(); slot:SetSize({ SizeRule = 1, Value = 1 }) end)
    el.itemsKey, el.appliedEnabled = optionsKey(el.options), nil
    return m
end

-- The wrapper's picker (its HBox's first child), or nil.
local function pickerIn(w)
    local ok, m = pcall(function()
        local hb = w.HBox
        if hb:GetChildrenCount() < 1 then return nil end
        return hb:GetChildAt(0)
    end)
    if ok and C.valid(m) and classNameOf(m) == C.MSB_SHORT then return m end
    return nil
end

local function keepRef(el, m)
    local cur = msbOf(el)
    if cur and cur:GetAddress() == m:GetAddress() then return end
    if el.msbRef then pcall(C.free, el.msbRef); el.msbRef = nil end
    local ok, h = pcall(C.ref, m)
    if ok then el.msbRef = h end
end

X.KIND.gchoice = {
    pkg = C.ROW_PKG, short = C.ROW_SHORT, cls = C.ROW_CLASS,
    content = function(el, w, fresh)
        if fresh then el.appliedEnabled, el.itemsKey = nil, nil end
        local m = not fresh and pickerIn(w) or nil
        if m and el.itemsKey ~= optionsKey(el.options) then -- new options (a create with the same id): a new picker
            pcall(function() C.count(); m:RemoveFromParent() end)
            m = nil
        end
        if not m then
            m = newPicker(el, w)
            if not m then return end
        end
        keepRef(el, m)
        gShow(el, m)
        gEnabled(el, m)
        GS.needCheck = true
    end,
    style = function() end, -- the wrapper has no background; the picker draws itself
}

local function gRefresh(el)
    local w = X._liveWidget(el)
    if not w then return end
    local ok, err = pcall(X.KIND.gchoice.content, el, w, false)
    if not ok then C.warnOnce("choice:" .. el.id, "choice '%s': update failed: %s", el.id, firstLine(err)) end
end

-- A click on one of a picker's arrows (post-hook: the picker already moved). delta: +1 next, -1 previous.
local function gStep(ctx, delta)
    local m = ctx:get()
    if not C.valid(m) then return end
    local a = m:GetAddress()
    local el = nil
    for _, e in ipairs(C.order) do
        if e.kind == "gchoice" and not e.removed and e.msbRef then
            local cur = msbOf(e)
            if cur and cur:GetAddress() == a then el = e break end
        end
    end
    if not el then GS.ignored = GS.ignored + 1 return end -- the game's own picker, another mod's, or a stale one
    local i = selectedOf(m)
    local new = i and i + 1
    local function back()
        pcall(function() C.count(); m.DefaultOption = el.options[el.index]; C.count(); m:SetSelectedOption(el.index - 1) end)
    end
    if not new or new == el.index then GS.dropped = GS.dropped + 1 return end
    if not el.enabled or not chainVisible(el) or new < 1 or new > #el.options then back(); GS.dropped = GS.dropped + 1 return end
    local now = C.micros()
    el.lastStep = el.lastStep or {}
    local last = el.lastStep[delta]
    if last and now - last < DEBOUNCE_US then back(); GS.debounced = GS.debounced + 1 return end
    el.lastStep[delta] = now
    el.index, el.shownIndex = new, new
    pcall(function() C.count(); m.DefaultOption = el.options[new] end)
    GS.clicks = GS.clicks + 1
    C.used(el)
    if C.debugOn() then C.log.debug("ui game choice '%s' -> %d", el.id, new) end
    C.inDispatch = C.inDispatch + 1
    local ok, err = pcall(el.onChange, el.handle, new, el.options[new])
    C.inDispatch = C.inDispatch - 1
    if not ok then
        GS.throws = GS.throws + 1
        if not el.warnedChange then
            el.warnedChange = true
            C.log.warn("choice '%s' onChange: %s", el.id, firstLine(err))
        end
    end
end
local function onGNext(ctx)
    local ok, err = pcall(gStep, ctx, 1)
    if not ok then C.warnOnce("game choice dispatch", "game choice click handling failed: %s (further failures not logged)", firstLine(err)) end
end
local function onGPrev(ctx)
    local ok, err = pcall(gStep, ctx, -1)
    if not ok then C.warnOnce("game choice dispatch", "game choice click handling failed: %s (further failures not logged)", firstLine(err)) end
end

-- From the poll (a game screen's opened and ticks; never inside a hook), once a game choice exists: the picker's class
-- loaded (GetAsset), its arrow handlers hooked, again when the class was loaded anew (keyed by the next handler's address).
local function anyGameChoice()
    for _, el in ipairs(C.order) do if el.kind == "gchoice" and not el.removed then return true end end
    return false
end
local function ensureGameHooks()
    if X._inHook() or not anyGameChoice() then return end
    GS.hookChecks = GS.hookChecks + 1
    local cls = A.get("cls:msb")
    if not cls then return end
    local fn = C.found(C.MSB_NEXT_FN)
    if not fn then
        C.warnOnce("game choice hook fn", "game choice arrows: %s is not there (the game changed its picker?); game choices' clicks don't call onChange", C.MSB_NEXT_FN)
        return
    end
    local okK, key = pcall(C.addr, fn)
    if not okK or key == GS.hookKey then return end
    local okN, errN = pcall(RegisterHook, C.MSB_NEXT_FN, onGNext)
    local okP, errP = pcall(RegisterHook, C.MSB_PREV_FN, onGPrev)
    GS.hookKey = key -- a half-registered pair is not tried again (it would double one arrow); one WARN instead
    GS.hookedOk = okN and okP
    if okN and okP then C.log.debug("ui game choice hooks registered on %s's arrows", C.MSB_SHORT)
    else C.warnOnce("game choice hook", "game choice arrows: RegisterHook failed: %s", firstLine(okN and errP or errN)) end
end
local function watchGame(host)
    if GS.ticking[host] then return end
    GS.ticking[host] = true
    G._watch(host, function(_, info)
        if info.event ~= "opened" then return end
        GS.needCheck = true
        local ok, err = pcall(ensureGameHooks)
        if not ok then C.warnOnce("game choice hook check", "game choice arrows: the hook check failed: %s", firstLine(err)) end
    end)
    G._ticker(host, function()
        if not GS.needCheck then return end
        GS.needCheck = false
        local ok, err = pcall(ensureGameHooks)
        if not ok then C.warnOnce("game choice hook check", "game choice arrows: the hook check failed: %s", firstLine(err)) end
    end)
end

-- ---------------------------------------------------------------- validation

local function validOptions(v, pre)
    if type(v) ~= "table" then C.fail("%s: options must be a list of 1 to %d strings, got %s", pre, MAX_OPTIONS, C.describe(v)) end
    local n = 0
    for k in pairs(v) do
        n = n + 1
        if math.type(k) ~= "integer" or k < 1 then C.fail("%s: options must be a list (keys 1..n), got the key %s", pre, C.describe(k)) end
    end
    if n == 0 then C.fail("%s: options is empty (1 to %d strings)", pre, MAX_OPTIONS) end
    if n > MAX_OPTIONS then C.fail("%s: options has %d entries, at most %d", pre, n, MAX_OPTIONS) end
    local out = {}
    for i = 1, n do
        local o = v[i]
        if o == nil then C.fail("%s: options must be a list (keys 1..n), it has a hole at %d", pre, i) end
        if type(o) ~= "string" or #o < 1 or #o > MAX_OPTION_BYTES then
            C.fail("%s: options[%d] must be a string of 1 to %d bytes, got %s", pre, i, MAX_OPTION_BYTES, C.describe(o))
        end
        out[i] = o
    end
    return out
end

local function validIndex(v, n, pre, what)
    if math.type(v) ~= "integer" or v < 1 or v > n then
        C.fail("%s: %s must be an integer from 1 to %d, got %s", pre, what, n, C.describe(v))
    end
    return v
end

local function validBool(v, pre, what, default)
    if v == nil then return default end
    if type(v) ~= "boolean" then C.fail("%s: %s must be a boolean or nil, got %s", pre, what, C.describe(v)) end
    return v
end

-- ---------------------------------------------------------------- public

function CH.create(opts, ...)
    C.enter("choice.create")
    local pre = C.UI .. ".choice.create"
    if type(opts) ~= "table" then C.fail("%s: expected a table { id = ..., options = ..., selected = ..., onChange = ..., place = ... }, got %s", pre, C.describe(opts)) end
    if select("#", ...) > 0 then C.fail("%s: expected 1 argument (a table), got %d", pre, 1 + select("#", ...)) end
    for k in pairs(opts) do
        if not CREATE_KEYS[k] then C.fail("%s: unknown key %s (valid: %s)", pre, C.describe(k), keyList(CREATE_KEYS)) end
    end
    local id = X._validId(opts.id, "choice.create")
    local game = false
    if opts.widget ~= nil then
        if opts.widget == "game" then game = true
        elseif opts.widget ~= "core" then C.fail("%s: unknown widget %s (valid: core)", pre, C.describe(opts.widget)) end
    end
    local options = validOptions(opts.options, pre)
    if game then
        -- core story 33: the game's picker selects by text, so its options must be distinct
        local seen = {}
        for i, o in ipairs(options) do
            if seen[o] then C.fail("%s: options[%d] %s repeats options[%d] (widget 'game' needs distinct options: the game's picker selects by text)", pre, i, C.describe(o), seen[o]) end
            seen[o] = i
        end
        if opts.tooltip ~= nil then C.fail("%s: tooltip is not available with widget 'game' (put the help on its game-style row: row.create{ help = ... })", pre) end
    end
    local index = opts.selected == nil and 1 or validIndex(opts.selected, #options, pre, "selected")
    if type(opts.onChange) ~= "function" then C.fail("%s: onChange must be a function, got %s", pre, C.describe(opts.onChange)) end
    local enabled = validBool(opts.enabled, pre, "enabled", true)
    local tooltip = St.validateTooltip(opts.tooltip, pre)
    if opts.place ~= nil and type(opts.place) ~= "table" then C.fail("%s: place must be a table or nil, got %s", pre, C.describe(opts.place)) end
    -- core story 33: a game choice with no place starts on the first game screen's canvas (a game-style row's control
    -- moves it into the row)
    local intent = opts.place or (game and { host = "createServer", corner = "top-right" } or { corner = "top-right" })
    local place = P.validate(intent)
    if game then X._checkGameOnly(nil, place, "choice.create", false, "gchoice") end
    if not place.panelEl then X.checkHost("choice", place.host, "choice.create") end
    X._checkTipHost("choice", place.panelEl and C.hostOf(place.panelEl) or place.host, tooltip ~= nil)
    local kind = game and "gchoice" or "choice"
    local prior = C.els[id]
    if prior and not prior.removed and (prior.kind == "choice" or prior.kind == "gchoice") and prior.kind ~= kind then
        C.fail("%s: id '%s' is already a choice with widget '%s'; remove it first to change its widget", pre, id, prior.kind == "gchoice" and "game" or "core")
    end
    local el = X._existing(id, kind, "choice.create")
    if el and game then
        el.options, el.index, el.onChange, el.enabled = options, index, opts.onChange, enabled
        gRefresh(el)
        P.place(el.handle, intent)
        return el.handle
    end
    if el then
        -- Same id: the new options, selection, callback, enabled state, tooltip and intent; visibility unchanged.
        el.options, el.index, el.onChange, el.enabled, el.tooltip = options, index, opts.onChange, enabled, tooltip
        refresh(el)
        local w = X._liveWidget(el)
        if w then
            local okT, errT = pcall(X._applyTooltip, el, w, false)
            if not okT then C.warnOnce("choice:" .. el.id, "choice '%s': tooltip not applied (is %s's pak current?): %s", el.id, C.NAME, firstLine(errT)) end
        end
        P.place(el.handle, intent)
        return el.handle
    end
    if place.panelEl then X._checkJoin(place.panelEl, "choice", "choice.create", nil, tooltip ~= nil) end
    A.ensureLoadMapHook()
    el = X._new(kind, id, { options = options, index = index, onChange = opts.onChange, enabled = enabled, tooltip = tooltip,
        style = X.resolveStyle(nil, "choice") }, place)
    if game then
        watchGame(C.hostOf(el))
        GS.needCheck = true
    end
    return el.handle
end

function CH.get(h, ...)
    C.enter("choice.get")
    local el = C.element(h, "choice.get", "choice")
    if select("#", ...) > 0 then C.fail("%s.choice.get: expected 1 argument (handle), got %d", C.UI, 1 + select("#", ...)) end
    return el.index, el.options[el.index]
end

function CH.set(h, index, ...)
    C.enter("choice.set")
    local el = C.element(h, "choice.set", "choice")
    if select("#", ...) > 0 then C.fail("%s.choice.set: expected 2 arguments (handle, index), got %d", C.UI, 2 + select("#", ...)) end
    validIndex(index, #el.options, C.UI .. ".choice.set", "index")
    if index == el.index then return end -- no UObject call
    el.index = index
    if el.kind == "gchoice" then gRefresh(el) else refresh(el) end
end

function CH.setEnabled(h, enabled)
    C.enter("choice.setEnabled")
    local el = C.element(h, "choice.setEnabled", "choice")
    if type(enabled) ~= "boolean" then C.fail("%s.choice.setEnabled: enabled must be a boolean, got %s", C.UI, C.describe(enabled)) end
    if enabled == el.enabled then return end
    el.enabled = enabled
    if el.kind == "gchoice" then gRefresh(el) else refresh(el) end
    X._hostChanged(C.hostOf(el)) -- core story 27: a disabled focused element hands keyboard focus on
end

function CH.setVisible(h, visible)
    C.enter("choice.setVisible")
    local el = C.element(h, "choice.setVisible", "choice")
    if type(visible) ~= "boolean" then C.fail("%s.choice.setVisible: visible must be a boolean, got %s", C.UI, type(visible)) end
    X._setVisible(el, visible)
end

function CH.remove(h)
    C.enter("choice.remove")
    if type(h) == "table" and C.removedHandle[h] then return end -- idempotent
    local el = C.element(h, "choice.remove", "choice")
    X._remove(el)
end

function CH.isShown(h)
    C.enter("choice.isShown")
    local el = C.element(h, "choice.isShown", "choice")
    return X._shown(el)
end

function CH.setTooltip(h, ...)
    -- core story 33: a game choice has no tooltip of its own (its game-style row's "?" has the help)
    local gel = type(h) == "table" and C.handleOf[h] or nil
    if gel and gel.kind == "gchoice" then
        C.enter("choice.setTooltip")
        local n = 1 + select("#", ...)
        if n > 2 then C.fail("%s.choice.setTooltip: expected 2 arguments (handle, tooltip), got %d", C.UI, n) end
        if (...) ~= nil then
            C.fail("%s.choice.setTooltip: choice '%s' has widget 'game', which takes no tooltip (put the help on its game-style row: row.setHelp)", C.UI, gel.id)
        end
        return
    end
    return X._setTooltipOf("choice", h, (...), 1 + select("#", ...))
end

-- ---------------------------------------------------------------- range

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- Decimals a number shows in %.10g (0 for an integer value), at most 6.
local function decimalsOf(v)
    local s = string.format("%.10g", v)
    if s:find("e", 1, true) then return 6 end
    local frac = s:match("%.(%d+)$")
    return frac and math.min(#frac, 6) or 0
end
CH._decimalsOf = decimalsOf

-- The number shown for value v with d decimals ("-0" never shown).
local function fmt(v, d)
    local s = string.format("%." .. d .. "f", v)
    if s:match("^%-0%.?0*$") then s = s:sub(2) end
    return s
end
CH._fmt = fmt

function CH.range(opts, ...)
    C.enter("choice.range")
    local pre = C.UI .. ".choice.range"
    if type(opts) ~= "table" then C.fail("%s: expected a table { min = ..., max = ..., step = ..., extra = ... }, got %s", pre, C.describe(opts)) end
    if select("#", ...) > 0 then C.fail("%s: expected 1 argument (a table), got %d", pre, 1 + select("#", ...)) end
    for k in pairs(opts) do
        if not RANGE_KEYS[k] then C.fail("%s: unknown key %s (valid: %s)", pre, C.describe(k), keyList(RANGE_KEYS)) end
    end
    if opts.id ~= nil then X._validId(opts.id, "choice.range") end
    for _, k in ipairs({ "min", "max", "step" }) do
        if not finite(opts[k]) then C.fail("%s: %s must be a finite number, got %s", pre, k, C.describe(opts[k])) end
    end
    local min, max, stp = opts.min, opts.max, opts.step
    if stp <= 0 then C.fail("%s: step must be greater than 0, got %s", pre, C.describe(stp)) end
    if min > max then C.fail("%s: min (%s) is greater than max (%s)", pre, C.describe(min), C.describe(max)) end
    local extra = {}
    if opts.extra ~= nil then
        if type(opts.extra) ~= "table" then C.fail("%s: extra must be a list of strings or nil, got %s", pre, C.describe(opts.extra)) end
        local n = 0
        for k in pairs(opts.extra) do
            n = n + 1
            if math.type(k) ~= "integer" or k < 1 then C.fail("%s: extra must be a list (keys 1..n), got the key %s", pre, C.describe(k)) end
        end
        for i = 1, n do
            local o = opts.extra[i]
            if type(o) ~= "string" or #o < 1 or #o > MAX_OPTION_BYTES then
                C.fail("%s: extra[%d] must be a string of 1 to %d bytes, got %s", pre, i, MAX_OPTION_BYTES, C.describe(o))
            end
            extra[i] = o
        end
    end
    local count = math.floor((max - min) / stp + 1e-9) + 1
    if count + #extra > MAX_OPTIONS then
        C.fail("%s: the range has %.0f options%s, at most %d", pre, count + #extra, #extra > 0 and string.format(" (%d extra)", #extra) or "", MAX_OPTIONS)
    end
    local d = math.max(decimalsOf(stp), decimalsOf(min))
    local out = {}
    for i, o in ipairs(extra) do out[i] = o end
    for k = 0, count - 1 do out[#out + 1] = fmt(min + k * stp, d) end
    return out
end

function CH.stats()
    return { clicks = S.clicks, dropped = S.dropped, debounced = S.debounced, ignored = S.ignored, throws = S.throws, hooked = S.hooked,
        -- core story 33: the game choices' arrow clicks
        gameClicks = GS.clicks, gameDropped = GS.dropped, gameDebounced = GS.debounced, gameIgnored = GS.ignored, gameThrows = GS.throws,
        gameHooked = GS.hookedOk }
end
CH._prev, CH._next, CH._S, CH._ensureHooks = onPrev, onNext, S, ensureHooks -- unit tests
CH._gNext, CH._gPrev, CH._GS, CH._ensureGameHooks = onGNext, onGPrev, GS, ensureGameHooks -- unit tests (core story 33)
return CH
