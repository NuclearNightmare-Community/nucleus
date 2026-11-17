-- Story 21 (Mod Manager story 2): rows. Exposed as core.ui.row on the connect API:
--   create{ id = <string>, place = <intent>, style = <style|nil>, gap = "compact" | "tight" | "normal" | "loose" | nil,
--           like = <game row name|nil>, label = <label|nil>, help = <help|nil>, control = <control handle|nil> } -> handle
-- (core story 27: "compact" is 4 units; a row's default stays "tight")
--   setStyle(handle, style)    setVisible(handle, visible)    remove(handle)    isShown(handle) -> boolean
--   setLabel(handle, label)    setHelp(handle, help | nil)     (core story 33: game-style rows only)
-- (panel.setStyle, setVisible, remove and isShown take a row too, and core.ui.place moves it.)
--
-- A row is WBP_<Core>Row: Border "Background" -> HorizontalBox "HBox". It is placed { list = h }, { panel = h } or by
-- any host intent (a host with a cursor: journal, menu, screen). Its children, text and buttons, go in with
-- place = { row = <handle>, fill = 0.1..16 | nil }, at most 16: fill gives the child a Fill slot with that weight
-- (equal weights across the rows of one list line up as columns, since every row has the list's width); no fill is
-- Auto (the child's own width). No list or row inside a row. In the game look (the default on menu and screen) a row
-- has the menu's worn-strip background.
--
-- Core story 33 (0.15.0): a game-style row. like names one of the game's own rows on a game screen (createServer's
-- Overlay_28, the Difficulty row); the row must sit directly on that game screen (its canvas or a game container, never
-- inside a core panel, list or row). It is still core's tagged row widget, but at every attach core reads the named game
-- row and copies its look onto native widgets it builds in the row: the background, the label's and the "?"'s font,
-- colour and justification, every inner slot, and the row's own slot in the game box (text.lua). label (a string or a
-- table of strings by language, 1-64 bytes each) is the row's label; help (a tooltip: a string or a language table,
-- 1-512 bytes, at most 8 lines each) shows on hovering the "?" in the game's own tooltip widget; control (a checkbox,
-- choice, slider or button handle of this mod) is placed into the row, where the game row's control sits: the same as
-- place(control, { row = h }), so the row's children (at most 16) all go there, before the "?". label, help and control
-- need like. A like name that isn't a game row on the open screen gives core's game look and one WARN.
local BASE = (...):gsub("%.ui%.row$", "")
local C = require(BASE .. ".ui.common")
local P = require(BASE .. ".ui.place")
local X = require(BASE .. ".ui.text")
local St = require(BASE .. ".ui.strings")

local R = {}
local CREATE_KEYS = { id = true, place = true, style = true, gap = true, like = true, label = true, help = true, control = true }
local LIKE_MAX = 64
local CONTROL_KINDS = { checkbox = true, choice = true, gchoice = true, slider = true, button = true }

local function validGap(v)
    if v == nil then return "tight" end
    if type(v) ~= "string" or not P._LIST_GAP[v] then C.fail("%s.row.create: unknown gap %s (valid: %s)", C.UI, C.describe(v), P._LIST_GAP_NAMES) end
    return v
end

-- Core story 33: like is a game widget's name (as a container intent's names).
local function validLike(v, pre)
    if type(v) ~= "string" then C.fail("%s: like must be a game widget's name (a string), got %s", pre, C.describe(v)) end
    if v == "" then C.fail("%s: like must not be empty", pre) end
    if #v > LIKE_MAX then C.fail("%s: like is %d characters, at most %d", pre, #v, LIKE_MAX) end
    if not v:match("^[A-Za-z_][A-Za-z0-9_]*$") then
        C.fail("%s: like %s is not a widget name (letters, digits and _, not starting with a digit)", pre, C.describe(v))
    end
    return v
end

-- Core story 33: control is a live checkbox, choice, slider or button handle of this mod.
local function validControl(h, pre)
    if type(h) ~= "table" then C.fail("%s: control must be a checkbox, choice, slider or button handle, got %s", pre, C.describe(h)) end
    local rid = C.removedHandle[h]
    if rid then C.fail("%s: control handle '%s' was removed", pre, rid) end
    local el = C.handleOf[h]
    if not el then C.fail("%s: control is not an element handle of this mod (use the handle that checkbox, choice, slider or button.create returned)", pre) end
    if not CONTROL_KINDS[el.kind] then
        C.fail("%s: control '%s' is %s, not a checkbox, choice, slider or button", pre, el.id, C.ARTICLE[el.kind] or el.kind)
    end
    return el
end

function R.create(opts, ...)
    C.enter("row.create")
    local pre = C.UI .. ".row.create"
    if type(opts) ~= "table" then C.fail("%s: expected a table { id = ..., place = ..., style = ..., gap = ... }, got %s", pre, C.describe(opts)) end
    if select("#", ...) > 0 then C.fail("%s: expected 1 argument (a table), got %d", pre, 1 + select("#", ...)) end
    for k in pairs(opts) do
        if not CREATE_KEYS[k] then C.fail("%s: unknown key %s (valid: control, gap, help, id, label, like, place, style)", pre, C.describe(k)) end
    end
    local id = X._validId(opts.id, "row.create")
    if opts.place ~= nil and type(opts.place) ~= "table" then C.fail("%s: place must be a table or nil, got %s", pre, C.describe(opts.place)) end
    -- Core story 33: like, label, help, control.
    local like, label, help, ctl
    if opts.like == nil then
        local got = {}
        for _, k in ipairs({ "label", "help", "control" }) do if opts[k] ~= nil then got[#got + 1] = k end end
        if #got > 0 then C.fail("%s: %s %s like = <game row name> (a game-style row)", pre, table.concat(got, " and "), #got == 1 and "needs" or "need") end
    else
        like = validLike(opts.like, pre)
        if opts.label ~= nil then label = St.validateRowLabel(opts.label, pre) end
        help = St.validateHelp(opts.help, pre)
        if opts.control ~= nil then ctl = validControl(opts.control, pre) end
    end
    local intent = opts.place or { corner = "top-right" }
    local place = P.validate(intent)
    if like then X._checkGameOnly(nil, place, "row.create", true) end
    if place.panelEl then X._checkJoin(place.panelEl, "row", "row.create")
    else X.checkHost("row", place.host, "row.create") end
    local style = X.resolveStyle(opts.style, "row")
    local gap = validGap(opts.gap)
    local el = X._existing(id, "row", "row.create")
    if el then
        if (el.like ~= nil) ~= (like ~= nil) then
            C.fail("%s: id '%s' is already a row %s like; remove it first to change that", pre, id, el.like and "with" or "without")
        end
        if like then el.like, el.label, el.help = like, label, help end
        X._setStyle(el, style)
        if el.gap ~= gap then el.gap, el.gapUnits = gap, P._LIST_GAP[gap]; X._applyGaps(el); X._resized(el) end
        P.place(el.handle, intent)
        if like then
            X._likeRefresh(el)
            if ctl and ctl.panel ~= el then P.place(ctl.handle, { row = el.handle }) end
        end
        return el.handle
    end
    el = X._new("row", id, { style = style, layout = "horizontal", gap = gap, gapUnits = P._LIST_GAP[gap], children = {},
        like = like, label = label, help = help }, place)
    if ctl and ctl.panel ~= el then P.place(ctl.handle, { row = el.handle }) end
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

-- Core story 33: a game-style row's label and help, applied at once when it is live (else at its next attach).
local function likeRow(h, fn, nargs, want)
    C.enter("row." .. fn)
    local el = C.element(h, "row." .. fn, "row")
    if nargs ~= want then C.fail("%s.row.%s: expected %d arguments (handle, %s), got %d", C.UI, fn, want, fn == "setLabel" and "label" or "help", nargs) end
    if not el.like then C.fail("%s.row.%s: row '%s' is not a game-style row (made without like)", C.UI, fn, el.id) end
    return el
end

function R.setLabel(h, ...)
    local el = likeRow(h, "setLabel", 1 + select("#", ...), 2)
    el.label = St.validateRowLabel((...), C.UI .. ".row.setLabel")
    X._likeRefresh(el)
end

function R.setHelp(h, ...)
    local el = likeRow(h, "setHelp", 1 + select("#", ...), 2)
    el.help = St.validateHelp((...), C.UI .. ".row.setHelp")
    X._likeRefresh(el)
end

return R
