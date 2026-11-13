-- Story 21 (Mod Manager story 2): rows. Exposed as core.ui.row on the connect API:
--   create{ id = <string>, place = <intent>, style = <style|nil>, gap = "tight" | "normal" | "loose" | nil } -> handle
--   setStyle(handle, style)    setVisible(handle, visible)    remove(handle)    isShown(handle) -> boolean
-- (panel.setStyle, setVisible, remove and isShown take a row too, and core.ui.place moves it.)
--
-- A row is WBP_<Core>Row: Border "Background" -> HorizontalBox "HBox". It is placed { list = h }, { panel = h } or by
-- any host intent (a host with a cursor: journal, menu, screen). Its children, text and buttons, go in with
-- place = { row = <handle>, fill = 0.1..16 | nil }, at most 16: fill gives the child a Fill slot with that weight
-- (equal weights across the rows of one list line up as columns, since every row has the list's width); no fill is
-- Auto (the child's own width). No list or row inside a row. In the game look (the default on menu and screen) a row
-- has the menu's worn-strip background.
local BASE = (...):gsub("%.ui%.row$", "")
local C = require(BASE .. ".ui.common")
local P = require(BASE .. ".ui.place")
local X = require(BASE .. ".ui.text")

local R = {}
local CREATE_KEYS = { id = true, place = true, style = true, gap = true }

local function validGap(v)
    if v == nil then return "tight" end
    if type(v) ~= "string" or not P._GAP[v] then C.fail("%s.row.create: unknown gap %s (valid: %s)", C.UI, C.describe(v), P._GAP_NAMES) end
    return v
end

function R.create(opts, ...)
    C.enter("row.create")
    local pre = C.UI .. ".row.create"
    if type(opts) ~= "table" then C.fail("%s: expected a table { id = ..., place = ..., style = ..., gap = ... }, got %s", pre, C.describe(opts)) end
    if select("#", ...) > 0 then C.fail("%s: expected 1 argument (a table), got %d", pre, 1 + select("#", ...)) end
    for k in pairs(opts) do
        if not CREATE_KEYS[k] then C.fail("%s: unknown key %s (valid: gap, id, place, style)", pre, C.describe(k)) end
    end
    local id = X._validId(opts.id, "row.create")
    if opts.place ~= nil and type(opts.place) ~= "table" then C.fail("%s: place must be a table or nil, got %s", pre, C.describe(opts.place)) end
    local intent = opts.place or { corner = "top-right" }
    local place = P.validate(intent)
    if place.panelEl then X._checkJoin(place.panelEl, "row", "row.create")
    else X.checkHost("row", place.host, "row.create") end
    local style = X.resolveStyle(opts.style, "row")
    local gap = validGap(opts.gap)
    local el = X._existing(id, "row", "row.create")
    if el then
        X._setStyle(el, style)
        if el.gap ~= gap then el.gap, el.gapUnits = gap, P._GAP[gap]; X._applyGaps(el); X._resized(el) end
        P.place(el.handle, intent)
        return el.handle
    end
    el = X._new("row", id, { style = style, layout = "horizontal", gap = gap, gapUnits = P._GAP[gap], children = {} }, place)
    return el.handle
end

function R.setStyle(h, style)
    C.enter("row.setStyle")
    local el = C.element(h, "row.setStyle", "row")
    X._setStyle(el, X.resolveStyle(style, "row"))
end

function R.setVisible(h, visible)
    C.enter("row.setVisible")
    local el = C.element(h, "row.setVisible", "row")
    if type(visible) ~= "boolean" then C.fail("%s.row.setVisible: visible must be a boolean, got %s", C.UI, type(visible)) end
    X._setVisible(el, visible)
end

function R.remove(h)
    C.enter("row.remove")
    if type(h) == "table" and C.removedHandle[h] then return end -- idempotent
    local el = C.element(h, "row.remove", "row")
    X._remove(el)
end

function R.isShown(h)
    C.enter("row.isShown")
    local el = C.element(h, "row.isShown", "row")
    return X._shown(el)
end

return R
