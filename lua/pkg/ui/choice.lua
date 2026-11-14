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
-- widget = "game" (the game's own MultipleSelectBox_C, for game-screen hosts) is not available yet and raises; the key
-- is accepted with "core" so that later addition stays add-only.
--
-- Dispatch: each dependent's Lua state registers one post-hook on <class>:<Core>_OnPrev and one on <Core>_OnNext, by
-- full path, from the UI poll once a choice exists (never inside a hook). The hook ignores other mods' widgets in silence
-- (their tag), a widget that isn't the element's current one, and repeats within 250 ms.
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
    if not el.enabled or not chainVisible(el) then S.dropped = S.dropped + 1 return end
    local now = C.micros()
    if el.lastClick and now - el.lastClick < DEBOUNCE_US then S.debounced = S.debounced + 1 return end
    el.lastClick = now
    local new = el.index + delta
    if new < 1 or new > #el.options then S.dropped = S.dropped + 1 return end -- no wrap: the arrow at its end is inert
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
    if opts.widget ~= nil then
        if opts.widget == "game" then C.fail("%s: widget 'game' is not available yet (the game's picker comes with game-screen hosts); use 'core' or leave it out", pre) end
        if opts.widget ~= "core" then C.fail("%s: unknown widget %s (valid: core)", pre, C.describe(opts.widget)) end
    end
    local options = validOptions(opts.options, pre)
    local index = opts.selected == nil and 1 or validIndex(opts.selected, #options, pre, "selected")
    if type(opts.onChange) ~= "function" then C.fail("%s: onChange must be a function, got %s", pre, C.describe(opts.onChange)) end
    local enabled = validBool(opts.enabled, pre, "enabled", true)
    local tooltip = St.validateTooltip(opts.tooltip, pre)
    if opts.place ~= nil and type(opts.place) ~= "table" then C.fail("%s: place must be a table or nil, got %s", pre, C.describe(opts.place)) end
    local intent = opts.place or { corner = "top-right" }
    local place = P.validate(intent)
    if not place.panelEl then X.checkHost("choice", place.host, "choice.create") end
    X._checkTipHost("choice", place.panelEl and C.hostOf(place.panelEl) or place.host, tooltip ~= nil)
    local el = X._existing(id, "choice", "choice.create")
    if el then
        -- Same id: the new options, selection, callback, enabled state, tooltip and intent; visibility unchanged.
        el.options, el.index, el.onChange, el.enabled, el.tooltip = options, index, opts.onChange, enabled, tooltip
        refresh(el)
        local w = X._liveWidget(el)
        if w then pcall(X._applyTooltip, el, w, false) end
        P.place(el.handle, intent)
        return el.handle
    end
    if place.panelEl then X._checkJoin(place.panelEl, "choice", "choice.create", nil, tooltip ~= nil) end
    A.ensureLoadMapHook()
    el = X._new("choice", id, { options = options, index = index, onChange = opts.onChange, enabled = enabled, tooltip = tooltip,
        style = X.resolveStyle(nil, "choice") }, place)
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
    refresh(el)
end

function CH.setEnabled(h, enabled)
    C.enter("choice.setEnabled")
    local el = C.element(h, "choice.setEnabled", "choice")
    if type(enabled) ~= "boolean" then C.fail("%s.choice.setEnabled: enabled must be a boolean, got %s", C.UI, C.describe(enabled)) end
    if enabled == el.enabled then return end
    el.enabled = enabled
    refresh(el)
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

function CH.setTooltip(h, ...) return X._setTooltipOf("choice", h, (...), 1 + select("#", ...)) end

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

function CH.stats() return { clicks = S.clicks, dropped = S.dropped, debounced = S.debounced, ignored = S.ignored, throws = S.throws, hooked = S.hooked } end
CH._prev, CH._next, CH._S, CH._ensureHooks = onPrev, onNext, S, ensureHooks -- unit tests
return CH
