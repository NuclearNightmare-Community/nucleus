-- Story 21 (Mod Manager story 2): scrolling lists. Exposed as core.ui.list on the connect API:
--   create{ id = <string>, place = <intent>, size = { w = 32..4096, h = 32..4096 } (or { w, h }),
--           style = <style|nil>, gap = "compact" | "tight" | "normal" | "loose" | nil } -> handle
-- Core story 27: gap "compact" (4 units) is the default between a list's children (it was "tight", 8).
--   setStyle(handle, style)    setVisible(handle, visible)    remove(handle)    isShown(handle) -> boolean
-- (panel.setStyle, setVisible, remove and isShown take a list too, and core.ui.place moves it.)
--
-- A list is WBP_<Core>List: SizeBox "Box" (the list's size, in canvas units) -> Border "Background" -> ScrollBox
-- "Scroll" -> VerticalBox "VBox". Its children go in with place = { list = <handle> }, in creation order, at most 256:
-- text, buttons and rows (a row fills the list's width, so its fill weights line up as columns across rows). The
-- mouse wheel scrolls it natively. A list sits on a host with a cursor (journal, menu, screen) and inside nothing.
-- Removing a child closes the gap; reordering rebuilds the box like a panel (panel.setOrder / move take a list).
--
-- Core story 38 (0.16.0, UI-16): create{ ..., reorderable = <boolean|nil>, onReorder = <function(list, ids)|nil> } lets
-- the player reorder the list's rows: with the mouse (drag a row by its own area; a press on a control stays the
-- control's) and with the keyboard or a gamepad (hold A or Enter on a row about 0.4 s to pick it up, Up / Down move it
-- while held, releasing drops it, B or Escape puts it back; a short press is the control's own action). Only visible,
-- unlocked rows move (row.create's locked, row.setLocked); a locked row and any child that isn't a row stay where they
-- are, and a move never crosses them. Core moves the rows and calls onReorder(list, ids) once per finished move that
-- changed the order (ids: a new array of every child's id in the new order), inside a dependent callback (cached assets
-- only); the dependent decides what the order means and saves it. panel.setOrder / move never call it. reorderable
-- works only while the list sits in the mod's top open window (a screen host); elsewhere it has no effect.
-- onReorder needs reorderable = true.
local BASE = (...):gsub("%.ui%.list$", "")
local C = require(BASE .. ".ui.common")
local P = require(BASE .. ".ui.place")
local X = require(BASE .. ".ui.text")

local L = {}
local SIZE_MIN, SIZE_MAX = 32, 4096
local CREATE_KEYS = { id = true, place = true, size = true, style = true, gap = true, reorderable = true, onReorder = true }

local function validSize(v)
    local pre = C.UI .. ".list.create"
    if type(v) ~= "table" then C.fail("%s: size must be a table { w = 32..4096, h = 32..4096 }, got %s", pre, C.describe(v)) end
    local w, h
    if v[1] ~= nil or v[2] ~= nil then w, h = v[1], v[2] else w, h = v.w, v.h end
    for k in pairs(v) do
        if k ~= 1 and k ~= 2 and k ~= "w" and k ~= "h" then C.fail("%s: unknown key %s in size (valid: w, h)", pre, C.describe(k)) end
    end
    for _, d in ipairs({ { "w", w }, { "h", h } }) do
        local x = d[2]
        if type(x) ~= "number" or x ~= x or x < SIZE_MIN or x > SIZE_MAX then
            C.fail("%s: size.%s must be a number from %d to %d, got %s", pre, d[1], SIZE_MIN, SIZE_MAX, C.describe(x))
        end
    end
    return { w = w + 0.0, h = h + 0.0 }
end

local function validGap(v)
    if v == nil then return "compact" end
    if type(v) ~= "string" or not P._LIST_GAP[v] then C.fail("%s.list.create: unknown gap %s (valid: %s)", C.UI, C.describe(v), P._LIST_GAP_NAMES) end
    return v
end

function L.create(opts, ...)
    C.enter("list.create")
    local pre = C.UI .. ".list.create"
    if type(opts) ~= "table" then C.fail("%s: expected a table { id = ..., place = ..., size = { w, h }, style = ..., gap = ... }, got %s", pre, C.describe(opts)) end
    if select("#", ...) > 0 then C.fail("%s: expected 1 argument (a table), got %d", pre, 1 + select("#", ...)) end
    for k in pairs(opts) do
        if not CREATE_KEYS[k] then C.fail("%s: unknown key %s (valid: gap, id, onReorder, place, reorderable, size, style)", pre, C.describe(k)) end
    end
    -- Core story 38: reorderable and onReorder.
    if opts.reorderable ~= nil and type(opts.reorderable) ~= "boolean" then
        C.fail("%s: reorderable must be a boolean or nil, got %s", pre, C.describe(opts.reorderable))
    end
    if opts.onReorder ~= nil and type(opts.onReorder) ~= "function" then
        C.fail("%s: onReorder must be a function or nil, got %s", pre, C.describe(opts.onReorder))
    end
    if opts.onReorder ~= nil and opts.reorderable ~= true then C.fail("%s: onReorder needs reorderable = true", pre) end
    local reorderable = opts.reorderable == true
    local id = X._validId(opts.id, "list.create")
    if opts.place ~= nil and type(opts.place) ~= "table" then C.fail("%s: place must be a table or nil, got %s", pre, C.describe(opts.place)) end
    local size = validSize(opts.size)
    local intent = opts.place or { corner = "top-right" }
    local place = P.validate(intent)
    if place.panelEl then X._checkJoin(place.panelEl, "list", "list.create") end -- raises: a list goes inside nothing
    X.checkHost("list", place.host, "list.create")
    local style = X.resolveStyle(opts.style, "list")
    local gap = validGap(opts.gap)
    local el = X._existing(id, "list", "list.create")
    if el then
        -- Same id: the new size, style, gap and intent; children, order and visibility unchanged. Core story 38: the new
        -- reorderable and onReorder (a change of reorderable cancels a drag or a carry in it).
        if el.reorderable ~= reorderable then C.listChanged(el) end
        el.reorderable, el.onReorder = reorderable, opts.onReorder
        el.size = size
        local w = X._liveWidget(el)
        if w then pcall(X.KIND.list.content, el, w, false); X._resized(el) end
        X._setStyle(el, style)
        if el.gap ~= gap then el.gap, el.gapUnits = gap, P._LIST_GAP[gap]; X._applyGaps(el); X._resized(el) end
        P.place(el.handle, intent)
        return el.handle
    end
    el = X._new("list", id, { style = style, layout = "vertical", gap = gap, gapUnits = P._LIST_GAP[gap], size = size, children = {},
        reorderable = reorderable, onReorder = opts.onReorder }, place)
    return el.handle
end

function L.setStyle(h, style)
    C.enter("list.setStyle")
    local el = C.element(h, "list.setStyle", "list")
    X._setStyle(el, X.resolveStyle(style, "list"))
end

function L.setVisible(h, visible)
    C.enter("list.setVisible")
    local el = C.element(h, "list.setVisible", "list")
    if type(visible) ~= "boolean" then C.fail("%s.list.setVisible: visible must be a boolean, got %s", C.UI, type(visible)) end
    X._setVisible(el, visible)
end

function L.remove(h)
    C.enter("list.remove")
    if type(h) == "table" and C.removedHandle[h] then return end -- idempotent
    local el = C.element(h, "list.remove", "list")
    X._remove(el)
end

function L.isShown(h)
    C.enter("list.isShown")
    local el = C.element(h, "list.isShown", "list")
    return X._shown(el)
end

return L
