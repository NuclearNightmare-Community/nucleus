-- UI-11 (Mod Manager story 4, core 0.10.0, core story 26): checkboxes. Exposed as core.ui.checkbox on the connect API:
--   create{ id = <string>, checked = <boolean|nil>, onChange = <function>, place = <intent|nil>, enabled = <boolean|nil>,
--           tooltip = <tooltip|nil>, size = 16..64 | nil } -> handle
--   get(handle) -> boolean          set(handle, checked)            setEnabled(handle, enabled)
--   setVisible(handle, visible)     remove(handle)                  isShown(handle) -> boolean
--   setTooltip(handle, <tooltip> | nil)
--
-- A checkbox is an icon-only WBP_<Core>Button (button.lua): the game's checkbox_ticked / checkbox_unticked textures (the
-- allow-listed game textures, loaded by path at runtime and never shipped; core's checkbox-on / checkbox-off icons when
-- they can't be loaded), size x size canvas units (default 28), lit on hover like an icon-only button. It keeps its
-- size in panels, lists and rows. A real click toggles it and runs onChange(handle, checked) on the game thread inside
-- pcall, exactly once per click (the button hook's 250 ms repeat rule applies); set never calls back. A throwing
-- onChange is logged once per checkbox and the checkbox keeps working. enabled = false keeps it visible, dimmed (the
-- disabled opacity, like a disabled button) and ignores clicks: read-only settings use it.
--
-- The click arrives through the button widget's one click hook per Lua state (button.lua), registered from the UI poll
-- once a checkbox exists, never inside a hook; the dispatch routes by element kind. Inside that hook the new texture
-- comes from the asset cache only (both textures are loaded when the checkbox is created and preloaded after every map
-- load); a miss is applied on the next 500 ms tick. Only on hosts with a cursor (journal, menu, screen).
local BASE = (...):gsub("%.ui%.checkbox$", "")
local C = require(BASE .. ".ui.common")
local H = require(BASE .. ".ui.hud")
local P = require(BASE .. ".ui.place")
local X = require(BASE .. ".ui.text")
local A = require(BASE .. ".ui.assets")
local I = require(BASE .. ".ui.image")
local B = require(BASE .. ".ui.button")
local St = require(BASE .. ".ui.strings")
local theme = require(BASE .. ".ui.theme")

local K = {}
local SIZE_MIN, SIZE_MAX = 16, 64
local CREATE_KEYS = { id = true, checked = true, onChange = true, place = true, enabled = true, tooltip = true, size = true }
local S = { toggles = 0, throws = 0 }

local function firstLine(e) return (tostring(e):match("^[^\n]*")) end
local function sourceFor(checked) return checked and theme.checkboxOn or theme.checkboxOff end

-- ---------------------------------------------------------------- the kind (the button widget, icon only)

local function sync(el)
    el.icon = sourceFor(el.checked)
    el.label = ""
end

X.KIND.checkbox = {
    pkg = C.BUTTON_PKG, short = C.BUTTON_SHORT, cls = C.BUTTON_CLASS,
    content = function(el, w, fresh)
        sync(el)
        B._content(el, w, fresh)
    end,
    style = function(el, w, fresh) B._style(el, w, fresh) end,
}

-- The icon for the current state on the live widget (set, and a click).
local function applyState(el, w)
    sync(el)
    B._applyIcon(el, w, false)
end

-- A click that passed the button hook's checks (its own tag and live widget, enabled, visible, not a repeat).
B._kindDispatch.checkbox = function(el, w)
    el.checked = not el.checked
    S.toggles = S.toggles + 1
    C.inDispatch = C.inDispatch + 1
    local okA, errA = pcall(applyState, el, w)
    C.inDispatch = C.inDispatch - 1
    if not okA then C.warnOnce("checkbox:" .. el.id, "checkbox '%s': showing its state failed: %s", el.id, firstLine(errA)) end
    if C.debugOn() then C.log.debug("ui checkbox '%s' clicked: %s", el.id, tostring(el.checked)) end
    local ok, err = pcall(el.onChange, el.handle, el.checked)
    if not ok then
        S.throws = S.throws + 1
        if not el.warnedChange then
            el.warnedChange = true
            C.log.warn("checkbox '%s' onChange: %s", el.id, firstLine(err))
        end
    end
end

-- The button widget's click hook, from the UI poll (never inside a hook) once a checkbox exists.
local hookDone = false
H._host{ poll = function() end, reset = function() end, dispatch = function()
    if hookDone then return nil end
    for _, el in ipairs(C.order) do
        if el.kind == "checkbox" and not el.removed then
            if not X._inHook() then hookDone = B._ensureHook() end
            return nil
        end
    end
    return nil
end }

-- ---------------------------------------------------------------- validation

local function validSize(v, pre)
    if v == nil then return theme.checkboxSize + 0.0 end
    if type(v) ~= "number" or v ~= v or v < SIZE_MIN or v > SIZE_MAX then
        C.fail("%s: size must be a number from %d to %d, got %s", pre, SIZE_MIN, SIZE_MAX, C.describe(v))
    end
    return v + 0.0
end

local function validBool(v, pre, what, default)
    if v == nil then return default end
    if type(v) ~= "boolean" then C.fail("%s: %s must be a boolean or nil, got %s", pre, what, C.describe(v)) end
    return v
end

local function keyList(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, ", ")
end
K._keyList = keyList

-- ---------------------------------------------------------------- public

function K.create(opts, ...)
    C.enter("checkbox.create")
    local pre = C.UI .. ".checkbox.create"
    if type(opts) ~= "table" then C.fail("%s: expected a table { id = ..., checked = ..., onChange = ..., place = ... }, got %s", pre, C.describe(opts)) end
    if select("#", ...) > 0 then C.fail("%s: expected 1 argument (a table), got %d", pre, 1 + select("#", ...)) end
    for k in pairs(opts) do
        if not CREATE_KEYS[k] then C.fail("%s: unknown key %s (valid: %s)", pre, C.describe(k), keyList(CREATE_KEYS)) end
    end
    local id = X._validId(opts.id, "checkbox.create")
    local checked = validBool(opts.checked, pre, "checked", false)
    if type(opts.onChange) ~= "function" then C.fail("%s: onChange must be a function, got %s", pre, C.describe(opts.onChange)) end
    local enabled = validBool(opts.enabled, pre, "enabled", true)
    local size = validSize(opts.size, pre)
    local tooltip = St.validateTooltip(opts.tooltip, pre)
    if opts.place ~= nil and type(opts.place) ~= "table" then C.fail("%s: place must be a table or nil, got %s", pre, C.describe(opts.place)) end
    local intent = opts.place or { corner = "top-right" }
    local place = P.validate(intent)
    if not place.panelEl then X.checkHost("checkbox", place.host, "checkbox.create") end
    X._checkTipHost("checkbox", place.panelEl and C.hostOf(place.panelEl) or place.host, tooltip ~= nil)
    -- Both textures are loaded now (outside any hook) and preloaded after every map load, so a click finds them cached.
    A.ensureLoadMapHook()
    for _, src in ipairs({ theme.checkboxOn, theme.checkboxOff }) do
        local okR, errR = pcall(I._resolve, src)
        if not okR then C.warnOnce("checkbox textures", "checkbox: loading %s failed: %s; a click shows it on the next tick", src.game, firstLine(errR)) end
    end
    local el = X._existing(id, "checkbox", "checkbox.create")
    if el then
        -- Same id: the new state, callback, size, tooltip, enabled state and intent; visibility unchanged.
        el.onChange = opts.onChange
        local resize = el.iconSize.w ~= size
        el.checked, el.iconSize, el.tooltip = checked, { w = size, h = size }, tooltip
        local w = X._liveWidget(el)
        if w then
            local ok, err = pcall(function()
                applyState(el, w)
                X._applyTooltip(el, w, false)
            end)
            if not ok then C.warnOnce("checkbox:" .. el.id, "checkbox '%s': update failed (is %s's pak current?): %s", el.id, C.NAME, firstLine(err)) end
            if resize then
                if el.panel then X._applyGaps(el.panel) end
                X._resized(el)
            end
        end
        K.setEnabled(el.handle, enabled)
        P.place(el.handle, intent)
        return el.handle
    end
    if place.panelEl then X._checkJoin(place.panelEl, "checkbox", "checkbox.create", nil, tooltip ~= nil) end
    el = X._new("checkbox", id, { checked = checked, onChange = opts.onChange, enabled = enabled, tooltip = tooltip,
        icon = sourceFor(checked), label = "", iconSize = { w = size, h = size }, dimmed = false,
        style = X.resolveStyle(nil, "button") }, place)
    return el.handle
end

function K.get(h, ...)
    C.enter("checkbox.get")
    local el = C.element(h, "checkbox.get", "checkbox")
    if select("#", ...) > 0 then C.fail("%s.checkbox.get: expected 1 argument (handle), got %d", C.UI, 1 + select("#", ...)) end
    return el.checked
end

function K.set(h, checked, ...)
    C.enter("checkbox.set")
    local el = C.element(h, "checkbox.set", "checkbox")
    if select("#", ...) > 0 then C.fail("%s.checkbox.set: expected 2 arguments (handle, checked), got %d", C.UI, 2 + select("#", ...)) end
    if type(checked) ~= "boolean" then C.fail("%s.checkbox.set: checked must be a boolean, got %s", C.UI, C.describe(checked)) end
    if checked == el.checked then return end -- no UObject call
    el.checked = checked
    local w = X._liveWidget(el)
    if w then
        local ok, err = pcall(applyState, el, w)
        if not ok then C.warnOnce("checkbox:" .. el.id, "checkbox '%s': showing its state failed: %s", el.id, firstLine(err)) end
    end
end

function K.setEnabled(h, enabled)
    C.enter("checkbox.setEnabled")
    local el = C.element(h, "checkbox.setEnabled", "checkbox")
    if type(enabled) ~= "boolean" then C.fail("%s.checkbox.setEnabled: enabled must be a boolean, got %s", C.UI, C.describe(enabled)) end
    if enabled == el.enabled then return end
    el.enabled = enabled
    local w = X._liveWidget(el)
    if w then
        local ok, err = pcall(function()
            C.count(); w:SetEnabledState(enabled)
            C.count(); w:SetRenderOpacity(enabled and 1 or theme.disabledOpacity)
            el.appliedEnabled = enabled
        end)
        if not ok then C.warnOnce("enabled:" .. el.id, "checkbox '%s': SetEnabledState failed: %s", el.id, firstLine(err)) end
    end
end

function K.setVisible(h, visible)
    C.enter("checkbox.setVisible")
    local el = C.element(h, "checkbox.setVisible", "checkbox")
    if type(visible) ~= "boolean" then C.fail("%s.checkbox.setVisible: visible must be a boolean, got %s", C.UI, type(visible)) end
    X._setVisible(el, visible)
end

function K.remove(h)
    C.enter("checkbox.remove")
    if type(h) == "table" and C.removedHandle[h] then return end -- idempotent
    local el = C.element(h, "checkbox.remove", "checkbox")
    X._remove(el)
end

function K.isShown(h)
    C.enter("checkbox.isShown")
    local el = C.element(h, "checkbox.isShown", "checkbox")
    return X._shown(el)
end

function K.setTooltip(h, ...) return X._setTooltipOf("checkbox", h, (...), 1 + select("#", ...)) end

function K.stats() return { toggles = S.toggles, throws = S.throws, hooked = hookDone } end
K._S = S -- unit tests
return K
