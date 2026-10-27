-- UI-6 (story 14): panels. Exposed as core.ui.panel on the connect API:
--   create{ id = <string>, place = <intent|nil>, style = <style|nil>, layout = "vertical" | "horizontal" | nil,
--           gap = "tight" | "normal" | "loose" | nil } -> handle
--   setStyle(handle, style)        setVisible(handle, visible)       remove(handle)        isShown(handle) -> boolean
--   order(handle) -> { childHandle, ... }                the children, in display order (a fresh table)
--   setOrder(handle, { childHandle, ... })               every current child exactly once, nothing else
--   move(handle, child, index)                           one child to position index (1 to the child count)
--
-- A panel is one box (WBP_<Core>Panel: Border "Background" holding a VerticalBox "VBox" or HorizontalBox "HBox") that
-- holds a mod's elements: any element goes inside with place = { panel = <panel handle> }, at the end, the panel's gap
-- (default "tight") before it. The panel itself is placed like any element (corner, near, absolute; on any host), and
-- its default style is dim with normal padding, so an unstyled panel is still visible as a box. One level only: no
-- panel inside a panel. At most 32 children.
--
-- Hiding a panel hides its children; removing it removes them (their handles raise "was removed"). A child's own
-- setVisible(false) collapses only that child (the gap closes). Reordering validates everything first, then rebuilds
-- the box once on the game thread with the same widgets (box panels only append: InsertChildAt isn't reflected,
-- docs/blueprint-mods.md Q4); an unchanged order makes no UObject call. The order survives every re-attach (UI-4) and
-- every Journal open (story 13): children are attached in it.
local BASE = (...):gsub("%.ui%.panel$", "")
local C = require(BASE .. ".ui.common")
local P = require(BASE .. ".ui.place")
local X = require(BASE .. ".ui.text")

local PN = {}
local LAYOUTS = { vertical = true, horizontal = true }
local CREATE_KEYS = { id = true, place = true, style = true, layout = true, gap = true }

local function validLayout(v, fn)
    if v == nil then return "vertical" end
    if type(v) ~= "string" or not LAYOUTS[v] then C.fail("%s.%s: unknown layout %s (valid: vertical, horizontal)", C.UI, fn, C.describe(v)) end
    return v
end
local function validGap(v, fn)
    if v == nil then return "tight" end
    if type(v) ~= "string" or not P._GAP[v] then C.fail("%s.%s: unknown gap %s (valid: %s)", C.UI, fn, C.describe(v), P._GAP_NAMES) end
    return v
end

-- Moves the children's widgets to the other box after a layout change (live panels only), then re-applies the gaps.
local function applyLayout(el)
    local w = X._liveWidget(el)
    if not w then return end
    local box = X._boxOf(el, w)
    if box then X._rebuildBox(el, box) end
    X._resized(el)
end

function PN.create(opts)
    C.enter("panel.create")
    if type(opts) ~= "table" then C.fail("%s.panel.create: expected a table { id = ..., place = ..., style = ..., layout = ..., gap = ... }, got %s", C.UI, C.describe(opts)) end
    for k in pairs(opts) do
        if not CREATE_KEYS[k] then C.fail("%s.panel.create: unknown key %s (valid: gap, id, layout, place, style)", C.UI, C.describe(k)) end
    end
    local id = X._validId(opts.id, "panel.create")
    if opts.place ~= nil and type(opts.place) ~= "table" then
        C.fail("%s.panel.create: place must be a table or nil, got %s", C.UI, C.describe(opts.place))
    end
    if opts.place ~= nil and opts.place.panel ~= nil then C.fail("%s.panel.create: a panel can't go inside a panel (one level only)", C.UI) end
    local intent = opts.place or { corner = "top-right" }
    local place = P.validate(intent)
    local style = X.resolveStyle(opts.style, "panel")
    local layout = validLayout(opts.layout, "panel.create")
    local gap = validGap(opts.gap, "panel.create")
    local el = X._existing(id, "panel", "panel.create")
    if X.checkHost then X.checkHost("panel", place.host, "panel.create", el) end
    if el then
        -- Same id: the new style, layout, gap and intent; children, order and visibility unchanged.
        X._setStyle(el, style)
        if el.layout ~= layout then el.layout = layout; applyLayout(el) end
        if el.gap ~= gap then
            el.gap, el.gapUnits = gap, P._GAP[gap]
            X._applyGaps(el)
            X._resized(el)
        end
        P.place(el.handle, intent)
        return el.handle
    end
    el = X._new("panel", id, { style = style, layout = layout, gap = gap, gapUnits = P._GAP[gap], children = {} }, place)
    return el.handle
end

function PN.setStyle(h, style)
    C.enter("panel.setStyle")
    local el = C.element(h, "panel.setStyle", "panel")
    X._setStyle(el, X.resolveStyle(style, "panel"))
end

function PN.setVisible(h, visible)
    C.enter("panel.setVisible")
    local el = C.element(h, "panel.setVisible", "panel")
    if type(visible) ~= "boolean" then C.fail("%s.panel.setVisible: visible must be a boolean, got %s", C.UI, type(visible)) end
    X._setVisible(el, visible)
end

function PN.remove(h)
    C.enter("panel.remove")
    if type(h) == "table" and C.removedHandle[h] then return end -- idempotent
    local el = C.element(h, "panel.remove", "panel")
    X._remove(el)
end

function PN.isShown(h)
    C.enter("panel.isShown")
    local el = C.element(h, "panel.isShown", "panel")
    return X._shown(el)
end

function PN.order(h, ...)
    C.enter("panel.order")
    local el = C.element(h, "panel.order", "panel")
    if select("#", ...) > 0 then C.fail("%s.panel.order: expected 1 argument (handle), got %d", C.UI, 1 + select("#", ...)) end
    local out = {}
    for _, ch in ipairs(el.children) do out[#out + 1] = ch.handle end
    return out
end

-- The new order as a list of child elements, from a caller's list of handles; raises before anything changes.
local function readOrder(el, list)
    local fn = "panel.setOrder"
    if type(list) ~= "table" then C.fail("%s.%s: order must be a table of the panel's child handles, got %s", C.UI, fn, C.describe(list)) end
    local n = #el.children
    local count = 0
    for k in pairs(list) do
        if math.type(k) ~= "integer" or k < 1 then C.fail("%s.%s: order must be a list (keys 1 to n), got key %s", C.UI, fn, C.describe(k)) end
        count = count + 1
    end
    if count ~= #list then C.fail("%s.%s: order must be a list without holes", C.UI, fn) end
    if count ~= n then C.fail("%s.%s: order has %d handle(s) but panel '%s' has %d child(ren); give each exactly once", C.UI, fn, count, el.id, n) end
    local seen, out = {}, {}
    for i = 1, count do
        local ch = list[i]
        if type(ch) ~= "table" then C.fail("%s.%s: order[%d] is not a child handle, got %s", C.UI, fn, i, C.describe(ch)) end
        local rid = C.removedHandle[ch]
        if rid then C.fail("%s.%s: order[%d]: handle '%s' was removed", C.UI, fn, i, rid) end
        local cel = C.handleOf[ch]
        if not cel then C.fail("%s.%s: order[%d] is not an element handle", C.UI, fn, i) end
        if cel.panel ~= el then C.fail("%s.%s: order[%d] ('%s') is not a child of panel '%s'", C.UI, fn, i, cel.id, el.id) end
        if seen[cel] then C.fail("%s.%s: order[%d] ('%s') appears twice", C.UI, fn, i, cel.id) end
        seen[cel] = true
        out[i] = cel
    end
    return out
end

-- Applies a validated order: one rebuild of the live box, or nothing when the order is the same.
local function applyOrder(el, newList)
    local same = true
    for i, ch in ipairs(newList) do if el.children[i] ~= ch then same = false break end end
    if same then return end
    el.children = newList
    local w = X._liveWidget(el)
    if not w then return end -- pending or closed: the next attach uses the new order
    local box = X._boxOf(el, w)
    if box then X._rebuildBox(el, box) end
end

function PN.setOrder(h, list, ...)
    C.enter("panel.setOrder")
    local el = C.element(h, "panel.setOrder", "panel")
    if select("#", ...) > 0 then C.fail("%s.panel.setOrder: expected 2 arguments (handle, order), got %d", C.UI, 2 + select("#", ...)) end
    applyOrder(el, readOrder(el, list))
end

function PN.move(h, child, index, ...)
    C.enter("panel.move")
    local el = C.element(h, "panel.move", "panel")
    if select("#", ...) > 0 then C.fail("%s.panel.move: expected 3 arguments (handle, child, index), got %d", C.UI, 3 + select("#", ...)) end
    local cel = C.element(child, "panel.move")
    if cel.panel ~= el then C.fail("%s.panel.move: '%s' is not a child of panel '%s'", C.UI, cel.id, el.id) end
    local n = #el.children
    if math.type(index) ~= "integer" then C.fail("%s.panel.move: index must be an integer from 1 to %d, got %s", C.UI, n, C.describe(index)) end
    if index < 1 or index > n then C.fail("%s.panel.move: index %d is out of range (1 to %d)", C.UI, index, n) end
    local cur
    for i, ch in ipairs(el.children) do if ch == cel then cur = i break end end
    if cur == index then return end
    local list = {}
    for i, ch in ipairs(el.children) do list[i] = ch end
    table.remove(list, cur)
    table.insert(list, index, cel)
    applyOrder(el, list)
end

return PN
