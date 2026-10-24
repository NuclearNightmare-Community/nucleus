-- UI-3 (story 9): placement by intent. Exposed as core.ui.place(handle, intent) and core.ui.elements().
--
--   { host = "hud", corner = "top-left" | "top-right" | "bottom-left" | "bottom-right",
--     gap = "tight" | "normal" | "loose", offset = { x = <number>, y = <number> } }
--   { host = "hud", near = "crosshair", side = "right" | "left" | "above" | "below",
--     align = "center" | "start" | "end", gap = <gap>, offset = { x, y } }
--   { host = "hud", absolute = { anchor = <corner> | "center", x = <number>, y = <number> } }
--
-- All numbers are canvas units (screen pixels / the game's DPI scale). Defaults: host "hud", gap "normal",
-- side "right", align "center", absolute anchor "top-left". Elements of one mod in the same corner stack in creation
-- order, gap apart; absolute elements and hidden ones take no space. No cross-mod stacking in v0.
local BASE = (...):gsub("%.ui%.place$", "")
local C = require(BASE .. ".ui.common")

local P = {}

local GAP = { tight = 8, normal = 16, loose = 32 }
local GAP_NAMES = "tight, normal, loose"
local CORNERS = {
    ["top-left"]     = { ax = 0, ay = 0, sx = 1,  sy = 1 },
    ["top-right"]    = { ax = 1, ay = 0, sx = -1, sy = 1 },
    ["bottom-left"]  = { ax = 0, ay = 1, sx = 1,  sy = -1 },
    ["bottom-right"] = { ax = 1, ay = 1, sx = -1, sy = -1 },
}
local CORNER_NAMES = "top-left, top-right, bottom-left, bottom-right"
local ANCHORS = {
    ["top-left"] = { 0, 0 }, ["top-right"] = { 1, 0 }, ["bottom-left"] = { 0, 1 }, ["bottom-right"] = { 1, 1 },
    center = { 0.5, 0.5 },
}
local ANCHOR_NAMES = "top-left, top-right, bottom-left, bottom-right, center"
local SIDES = { right = true, left = true, above = true, below = true }
local SIDE_NAMES = "right, left, above, below"
local ALIGNS = { center = true, start = true, ["end"] = true }
local ALIGN_NAMES = "center, start, end"
local OFFSET_MAX, ABSOLUTE_MAX = 4096, 8192

-- Elements a `near` intent can name: short name -> { description, the HUD property it reads }.
local ELEMENTS = {
    crosshair = { desc = "the HUD crosshair (inside the HUD canvas)", prop = "Crosshair" },
}
local ELEMENT_NAMES = "crosshair"

local KEYS = {
    corner = { host = true, corner = true, gap = true, offset = true },
    near = { host = true, near = true, side = true, align = true, gap = true, offset = true },
    absolute = { host = true, absolute = true },
}

local ALL_KEYS = { host = true, corner = true, near = true, absolute = true, gap = true, side = true, align = true, offset = true }
local ALL_KEY_NAMES = "absolute, align, corner, gap, host, near, offset, side"

P.DEFAULT = { host = "hud", corner = "top-right", gap = "normal", gapUnits = 16, offset = { x = 0, y = 0 } }

local function bad(fmt, ...) C.fail("%s.place: " .. fmt, C.UI, ...) end

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

local function number(v, what, max)
    if v == nil then return 0 end
    if type(v) ~= "number" then bad("%s must be a number, got %s", what, C.describe(v)) end
    if not finite(v) then bad("%s must be a finite number, got %s", what, C.describe(v)) end
    if v < -max or v > max then bad("%s %s is out of range (within +-%d canvas units)", what, C.describe(v), max) end
    return v + 0.0
end

local function sortedKeys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = tostring(k) end
    table.sort(ks)
    return table.concat(ks, ", ")
end

-- Validates an intent and returns a normalized copy (plain values only). Raises nucleus.ui.place: <problem>.
function P.validate(intent)
    if type(intent) ~= "table" then bad("intent must be a table, got %s", C.describe(intent)) end
    for k in pairs(intent) do
        if type(k) ~= "string" or not ALL_KEYS[k] then bad("unknown key %s in an intent (valid keys: %s)", C.describe(k), ALL_KEY_NAMES) end
    end
    local kinds = {}
    if intent.corner ~= nil then kinds[#kinds + 1] = "corner" end
    if intent.near ~= nil then kinds[#kinds + 1] = "near" end
    if intent.absolute ~= nil then kinds[#kinds + 1] = "absolute" end
    if #kinds ~= 1 then
        bad("an intent needs exactly one of corner, near or absolute (got %s)", #kinds == 0 and "none" or table.concat(kinds, " and "))
    end
    local kind = kinds[1]
    for k in pairs(intent) do
        if not KEYS[kind][k] then bad("%s is not allowed with %s (valid keys: %s)", k, kind, sortedKeys(KEYS[kind])) end
    end
    local host = intent.host
    if host == nil then host = "hud" end
    if host ~= "hud" then bad("unknown host %s (valid: hud)", C.describe(host)) end

    local out = { host = "hud" }
    if kind ~= "absolute" then
        local gap = intent.gap
        if gap == nil then gap = "normal" end
        if type(gap) ~= "string" or not GAP[gap] then bad("unknown gap %s (valid: %s)", C.describe(gap), GAP_NAMES) end
        out.gap, out.gapUnits = gap, GAP[gap]
        local off = intent.offset
        if off == nil then
            out.offset = { x = 0, y = 0 }
        else
            if type(off) ~= "table" then bad("offset must be a table { x = <number>, y = <number> }, got %s", C.describe(off)) end
            for k in pairs(off) do
                if k ~= "x" and k ~= "y" then bad("unknown key %s in offset (valid keys: x, y)", C.describe(k)) end
            end
            out.offset = { x = number(off.x, "offset.x", OFFSET_MAX), y = number(off.y, "offset.y", OFFSET_MAX) }
        end
    end
    if kind == "corner" then
        local c = intent.corner
        if type(c) ~= "string" or not CORNERS[c] then bad("unknown corner %s (valid: %s)", C.describe(c), CORNER_NAMES) end
        out.corner = c
    elseif kind == "near" then
        local n = intent.near
        if type(n) ~= "string" or not ELEMENTS[n] then bad("unknown near element %s (valid: %s)", C.describe(n), ELEMENT_NAMES) end
        local side, align = intent.side, intent.align
        if side == nil then side = "right" end
        if align == nil then align = "center" end
        if type(side) ~= "string" or not SIDES[side] then bad("unknown side %s (valid: %s)", C.describe(side), SIDE_NAMES) end
        if type(align) ~= "string" or not ALIGNS[align] then bad("unknown align %s (valid: %s)", C.describe(align), ALIGN_NAMES) end
        out.near, out.side, out.align = n, side, align
    else
        local a = intent.absolute
        if type(a) ~= "table" then bad("absolute must be a table { anchor = <anchor>, x = <number>, y = <number> }, got %s", C.describe(a)) end
        for k in pairs(a) do
            if k ~= "anchor" and k ~= "x" and k ~= "y" then bad("unknown key %s in absolute (valid keys: anchor, x, y)", C.describe(k)) end
        end
        local anchor = a.anchor
        if anchor == nil then anchor = "top-left" end
        if type(anchor) ~= "string" or not ANCHORS[anchor] then bad("unknown anchor %s (valid: %s)", C.describe(anchor), ANCHOR_NAMES) end
        out.absolute = { anchor = anchor, x = number(a.x, "absolute.x", ABSOLUTE_MAX), y = number(a.y, "absolute.y", ABSOLUTE_MAX) }
    end
    return out
end

-- ---- pure layout math (unit-tested without the game)

-- Corner stack: items = list of { gap = <units>, height = <canvas units>, offset = {x,y} } in creation order, all
-- visible and in one corner. Returns, per item, the slot's anchors/alignment (one point) and position.
function P.stack(corner, items)
    local c = CORNERS[corner]
    local out, along = {}, 0
    for i, it in ipairs(items) do
        along = along + it.gap
        out[i] = { ax = c.ax, ay = c.ay, alx = c.ax, aly = c.ay,
            x = c.sx * it.gap + it.offset.x, y = c.sy * along + it.offset.y }
        along = along + it.height
    end
    return out
end

-- Near an element: rect = { l, t, r, b } of the element in its anchor's frame (slot position minus alignment * size).
-- Returns our slot's alignment and position in the same frame; the caller copies the element's anchors.
function P.near(rect, side, align, gap, offset)
    local alx, aly, x, y
    local cx, cy = (rect.l + rect.r) / 2, (rect.t + rect.b) / 2
    if side == "right" or side == "left" then
        if side == "right" then alx, x = 0, rect.r + gap else alx, x = 1, rect.l - gap end
        if align == "center" then aly, y = 0.5, cy elseif align == "start" then aly, y = 0, rect.t else aly, y = 1, rect.b end
    else
        if side == "below" then aly, y = 0, rect.b + gap else aly, y = 1, rect.t - gap end
        if align == "center" then alx, x = 0.5, cx elseif align == "start" then alx, x = 0, rect.l else alx, x = 1, rect.r end
    end
    return { alx = alx, aly = aly, x = x + offset.x, y = y + offset.y }
end

function P.absolute(a)
    local an = ANCHORS[a.anchor]
    return { ax = an[1], ay = an[2], alx = an[1], aly = an[2], x = a.x, y = a.y }
end

-- ---- applying to widgets (game thread; called by text.lua)

local function setSlot(el, w, s, ax, ay)
    local key = string.format("%g,%g,%g,%g,%g,%g", ax, ay, s.alx, s.aly, s.x, s.y)
    if el.slotKey == key then return end
    local slot = w.Slot
    C.count(); slot:SetAutoSize(true)
    C.count(); slot:SetAnchors({ Minimum = { X = ax, Y = ay }, Maximum = { X = ax, Y = ay } })
    C.count(); slot:SetAlignment({ X = s.alx, Y = s.aly })
    C.count(); slot:SetPosition({ X = s.x, Y = s.y })
    el.slotKey = key
end

-- The near element's rectangle in its anchor's frame, and its anchors; nil when it is absent or not drawn.
local function nearTarget(hud, name)
    local spec = ELEMENTS[name]
    local target = hud[spec.prop]
    if not C.valid(target) then return nil, "absent" end
    local vis = tonumber(target:GetVisibility()) or 0
    if not C.drawn(vis) then return nil, "collapsed" end
    if name == "crosshair" then
        local okH, hiding = pcall(function() return hud.HidingCrosshair end)
        if okH and hiding == true then return nil, "hidden by the game" end
    end
    local slot = target.Slot
    local an, al, pos = slot:GetAnchors(), slot:GetAlignment(), slot:GetPosition()
    local size
    local okA, auto = pcall(function() return slot:GetAutoSize() end)
    if okA and auto then size = target:GetDesiredSize() else size = slot:GetSize() end
    local l, t = pos.X - al.X * size.X, pos.Y - al.Y * size.Y
    return { l = l, t = t, r = l + size.X, b = t + size.Y,
        ax = an.Minimum.X, ay = an.Minimum.Y, stretched = an.Minimum.X ~= an.Maximum.X or an.Minimum.Y ~= an.Maximum.Y }
end

-- The visibility an element's widget should have: hidden by setVisible, or collapsed because its near element is
-- absent; otherwise SelfHitTestInvisible (shown, and never hit-tested, so its tag tooltip never shows).
function P.wantedVisibility(el)
    if not el.visible or el.nearAbsent then return C.VIS.Collapsed end
    return C.VIS.SelfHitTestInvisible
end

function P.applyVisibility(el, w)
    local want = P.wantedVisibility(el)
    if el.appliedVis == want then return end
    C.count(); w:SetVisibility(want)
    el.appliedVis = want
end

-- Places one near or absolute element (corner elements go through restack).
local function placeSingle(el, w, hud)
    local pl = el.place
    if pl.absolute then
        local s = P.absolute(pl.absolute)
        setSlot(el, w, s, s.ax, s.ay)
        el.nearAbsent = false
    elseif pl.near then
        local r, why = nearTarget(hud, pl.near)
        if r and r.stretched then
            r, why = nil, "stretched anchors (not supported)"
            C.warnOnce("near-stretch:" .. pl.near, "place '%s': %s has stretched anchors; near placement needs point anchors, so the element stays collapsed", el.id, pl.near)
        end
        el.nearAbsent = r == nil
        el.nearWhy = why
        if r then
            local s = P.near(r, pl.side, pl.align, pl.gapUnits, pl.offset)
            setSlot(el, w, s, r.ax, r.ay)
            el.nearRect = string.format("%g,%g,%g,%g,%g,%g", r.l, r.t, r.r, r.b, r.ax, r.ay)
        else
            el.nearRect = nil
        end
    end
    P.applyVisibility(el, w)
end

-- Height of a live widget for stacking (desired size after a layout prepass when asked).
local function heightOf(w, prepass)
    if prepass then pcall(function() C.count(); w:ForceLayoutPrepass() end) end
    local ds = w:GetDesiredSize()
    return tonumber(ds.Y) or 0
end

-- Re-stacks one corner of this mod. live(el) -> widget or nil (text.lua: live in the current HUD canvas).
function P.restack(corner, live, prepass)
    local items, ws, els = {}, {}, {}
    for _, el in ipairs(C.order) do
        if not el.removed and el.place.corner == corner then
            local w = live(el)
            if w then
                P.applyVisibility(el, w)
                if el.visible then
                    items[#items + 1] = { gap = el.place.gapUnits, offset = el.place.offset, height = 0 }
                    ws[#ws + 1], els[#els + 1] = w, el
                end
            end
        end
    end
    -- Only elements with a successor are measured: the last one's height moves nothing.
    for i = 1, #items do
        if i < #items then
            items[i].height = heightOf(ws[i], prepass)
            els[i].stackHeight = items[i].height
        else
            els[i].stackHeight = nil
        end
    end
    local out = P.stack(corner, items)
    for i, s in ipairs(out) do setSlot(els[i], ws[i], s, s.ax, s.ay) end
end

-- Places an element whose widget is live now. Corner elements re-stack their whole corner.
function P.apply(el, w, hud, live, prepass)
    if el.place.corner then
        el.nearAbsent = false
        P.restack(el.place.corner, live, prepass)
    else
        placeSingle(el, w, hud)
    end
end

-- Per tick (text.lua): near elements follow their element's presence and rectangle; stacks follow height changes.
function P.tick(hud, live)
    local stacks = {} -- corner -> list of { el, w } (visible, live)
    for _, el in ipairs(C.order) do
        if not el.removed then
            local w = live(el)
            if w then
                local pl = el.place
                if pl.near then
                    local okR, r = pcall(nearTarget, hud, pl.near)
                    local key = okR and r and not r.stretched and string.format("%g,%g,%g,%g,%g,%g", r.l, r.t, r.r, r.b, r.ax, r.ay) or nil
                    if (key == nil) ~= (el.nearAbsent == true) or key ~= el.nearRect then placeSingle(el, w, hud) end
                elseif pl.corner and el.visible then
                    local list = stacks[pl.corner] or {}
                    stacks[pl.corner] = list
                    list[#list + 1] = { el = el, w = w }
                end
            end
        end
    end
    -- Only a corner holding two or more elements can be pushed around by a height change.
    for corner, list in pairs(stacks) do
        if #list >= 2 then
            local dirty = false
            for i = 1, #list - 1 do
                if heightOf(list[i].w, false) ~= list[i].el.stackHeight then dirty = true end
            end
            if dirty then P.restack(corner, live, false) end
        end
    end
end

-- ---- public

-- elements() -> { <name> = <description> } (a fresh table each call)
function P.elements(...)
    C.enter("elements")
    if select("#", ...) > 0 then C.fail("%s.elements: expected 0 arguments, got %d", C.UI, select("#", ...)) end
    local out = {}
    for k, v in pairs(ELEMENTS) do out[k] = v.desc end
    return out
end

-- place(handle, intent): stores the intent; re-places now when the element is live. Set by text.lua (it needs the
-- element registry and attach).
P.place = nil

P._GAP, P._CORNERS = GAP, CORNERS
return P
