-- UI-3 (story 9): placement by intent. Exposed as core.ui.place(handle, intent) and core.ui.elements([host]).
--
--   { host = "hud" | "journal", corner = "top-left" | "top-right" | "bottom-left" | "bottom-right",
--     gap = "tight" | "normal" | "loose", offset = { x = <number>, y = <number> } }
--   { host = "journal", corner = <corner>, region = <region>, inset = <gap>, gap = <gap>, offset = { x, y } }
--   { host = "hud", near = "crosshair", side = "right" | "left" | "above" | "below",
--     align = "center" | "start" | "end", gap = <gap>, offset = { x, y } }
--   { host = "journal", near = <region>, side = ..., align = ..., gap = <gap>, offset = { x, y } }
--   { host = "hud" | "journal", absolute = { anchor = <corner> | "center", x = <number>, y = <number> } }
--
--   { panel = <panel handle> }        (story 14) inside a panel: the panel arranges it; no other key goes with it
--
-- host "journal" (story 13) is the Journal's map page (journal.lua). Story 19 (core 0.6.0, CAP-10): named regions of
-- the open Journal (REGIONS below). A journal corner sits inside a region (a plain journal corner means "cover"), and
-- a journal near names a region. Exact regions (cover, page-left, page-right, binder) come from their stretched canvas
-- slots: the element gets a point anchor on the region's edge, valid before the first paint and at any resolution.
-- Measured regions (map, map-header, match, tasks, ammo) sit inside box panels: their rectangle comes from core's
-- ModActor helper <Core>_RectIn after the first paint; until it is valid the element stays collapsed. They are re-read
-- every journal tick until valid, then every REGION_TICKS ticks, and re-placed only when the rectangle changes.
--
-- All numbers are canvas units (screen pixels / the game's DPI scale). Defaults: host "hud", gap "normal",
-- side "right", align "center", absolute anchor "top-left", inset = gap. Elements of one mod in the same corner (of
-- the same host and region) stack in creation order: the first sits inset from both edges, each later one gap after
-- the previous; absolute elements and hidden ones take no space. No cross-mod stacking in v0.
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

-- Story 19: regions of the open Journal, reached from Journal_C.MapWidget (V8.2.1 tree). kind "exact": a direct child
-- of the host canvas with stretched anchors (its slot gives the edges); "union": binder, edge by edge from the two page
-- papers; "measured": a widget inside box panels (prop, then GetParent ups times, of class cls when given), measured
-- with <Core>_RectIn after the first paint.
local REGIONS = {
    cover = { kind = "exact", prop = "NN_BinderCover", path = "MapWidget.NN_BinderCover",
        desc = "the dark binder cover the pages sit on (NN_BinderCover); exact" },
    ["page-left"] = { kind = "exact", prop = "NN_LeftFieldPaper", path = "MapWidget.NN_LeftFieldPaper",
        desc = "the left page paper, with the map (NN_LeftFieldPaper); exact" },
    ["page-right"] = { kind = "exact", prop = "NN_RightFieldPaper", path = "MapWidget.NN_RightFieldPaper",
        desc = "the right page paper: match, tasks, ammo (NN_RightFieldPaper); exact" },
    binder = { kind = "union", path = "MapWidget.NN_LeftFieldPaper + NN_RightFieldPaper",
        desc = "both pages with the spine: the outer edges of the two page papers; exact" },
    map = { kind = "measured", prop = "MapUI", ups = 0, path = "MapWidget.MapUI",
        desc = "the map square (MapUI in NN_FieldMapPlane, 736x611 at scale 1; zoom and pan never move it); measured" },
    ["map-header"] = { kind = "measured", prop = "TextBlock_86", ups = 2, cls = "Border", path = "MapWidget.TextBlock_86 parent parent (Border)",
        desc = "the MAP / time / DAY bar above the map; measured" },
    match = { kind = "measured", prop = "StackBox_1", ups = 2, cls = "VerticalBox", path = "MapWidget.StackBox_1 parent parent (VerticalBox)",
        desc = "the MATCH block with the player list; measured" },
    tasks = { kind = "measured", prop = "GraphicsScroll", ups = 3, cls = "HorizontalBox", path = "MapWidget.GraphicsScroll parent parent parent (HorizontalBox)",
        desc = "the CLASSIFIED MATERIALS block (tasks); measured" },
    ammo = { kind = "measured", prop = "NN_AmmoCarbonBacking", ups = 0, path = "MapWidget.NN_AmmoCarbonBacking",
        desc = "the dark AMMO box (NN_AmmoCarbonBacking); measured" },
}
local REGION_NAMES = "ammo, binder, cover, map, map-header, match, page-left, page-right, tasks"
local JOURNAL_CORNER_REGION = "cover" -- a plain journal corner (no region) is a corner of the cover (0.6.0)

local KEYS = {
    corner = { host = true, corner = true, gap = true, offset = true, region = true, inset = true },
    near = { host = true, near = true, side = true, align = true, gap = true, offset = true },
    absolute = { host = true, absolute = true },
}

local ALL_KEYS = { host = true, corner = true, near = true, absolute = true, gap = true, side = true, align = true, offset = true, panel = true,
    region = true, inset = true }
local ALL_KEY_NAMES = "absolute, align, corner, gap, host, inset, near, offset, panel, region, side"

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

-- Story 14: the panel element an intent names, or a clean error.
local function panelOf(ph)
    if type(ph) ~= "table" then bad("panel must be a panel handle, got %s", C.describe(ph)) end
    local rid = C.removedHandle[ph]
    if rid then C.fail("%s.%s: handle '%s' was removed", C.UI, C.removedKind[ph] or "panel", rid) end
    local pel = C.handleOf[ph]
    if not pel then bad("panel is not a panel handle (use the handle that panel.create returned)") end
    if pel.kind ~= "panel" then bad("panel is %s ('%s'), not a panel", C.ARTICLE[pel.kind], pel.id) end
    return pel
end

-- Validates an intent and returns a normalized copy (plain values only). Raises nucleus.ui.place: <problem>.
-- A panel intent comes back as { panelEl = <the panel element> } (the caller checks the panel's limits).
function P.validate(intent)
    if type(intent) ~= "table" then bad("intent must be a table, got %s", C.describe(intent)) end
    for k in pairs(intent) do
        if type(k) ~= "string" or not ALL_KEYS[k] then bad("unknown key %s in an intent (valid keys: %s)", C.describe(k), ALL_KEY_NAMES) end
    end
    if intent.panel ~= nil then
        for k in pairs(intent) do
            if k ~= "panel" then bad("%s is not allowed with panel (the panel arranges its children; valid keys: panel)", k) end
        end
        return { panelEl = panelOf(intent.panel) }
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
    if host ~= "hud" and host ~= "journal" then bad("unknown host %s (valid: %s)", C.describe(host), C.HOST_NAMES) end
    if kind == "corner" and host ~= "journal" then
        if intent.region ~= nil then bad("region is not available on host '%s' (journal only)", host) end
        if intent.inset ~= nil then bad("inset is not available on host '%s' (journal only)", host) end
    end

    local out = { host = host }
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
        -- Story 19: the region (journal only; a plain journal corner is the cover's) and the inset (default: the gap).
        out.inset, out.insetUnits = out.gap, out.gapUnits
        if host == "journal" then
            local r = intent.region
            if r == nil then r = JOURNAL_CORNER_REGION end
            if type(r) ~= "string" or not REGIONS[r] then bad("unknown region %s (valid: %s)", C.describe(r), REGION_NAMES) end
            out.region = r
            local ins = intent.inset
            if ins ~= nil then
                if type(ins) ~= "string" or not GAP[ins] then bad("unknown inset %s (valid: %s)", C.describe(ins), GAP_NAMES) end
                out.inset, out.insetUnits = ins, GAP[ins]
            end
        end
    elseif kind == "near" then
        local n = intent.near
        if host == "journal" then
            if type(n) ~= "string" or not REGIONS[n] then bad("unknown near region %s (valid: %s)", C.describe(n), REGION_NAMES) end
        elseif type(n) ~= "string" or not ELEMENTS[n] then bad("unknown near element %s (valid: %s)", C.describe(n), ELEMENT_NAMES) end
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

-- Corner stack: items = list of { gap = <units>, inset = <units|nil>, height = <canvas units>, offset = {x,y} } in
-- creation order, all visible and in one corner. The first item sits inset from both edges, each later one gap after
-- the previous; each item's cross-axis distance is its own inset (story 19; inset defaults to gap, which gives the
-- story 9 numbers). Returns, per item, the slot's anchors/alignment (one point) and position from that corner.
function P.stack(corner, items)
    local c = CORNERS[corner]
    local out, along = {}, 0
    for i, it in ipairs(items) do
        local inset = it.inset or it.gap
        along = along + (i == 1 and inset or it.gap)
        out[i] = { ax = c.ax, ay = c.ay, alx = c.ax, aly = c.ay,
            x = c.sx * inset + it.offset.x, y = c.sy * along + it.offset.y }
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

-- Story 19: a region rectangle is four edges, each { a = <anchor fraction>, o = <canvas units> }: the edge sits at
-- a * (canvas size) + o. Exact regions have the slot's anchors; measured ones have a = 0 and the measured position.
local ZERO = { x = 0, y = 0 }

-- A corner stack's slots inside region r: each item's anchor moves to the region's corner and its position by that
-- edge's offset. s = P.stack(corner, items).
function P.inRegion(corner, s, r)
    local c = CORNERS[corner]
    local ex = c.ax == 0 and r.l or r.r
    local ey = c.ay == 0 and r.t or r.b
    local out = {}
    for i, it in ipairs(s) do
        out[i] = { ax = ex.a, ay = ey.a, alx = it.alx, aly = it.aly, x = it.x + ex.o, y = it.y + ey.o }
    end
    return out
end

-- Near a region: P.near on the edges' anchors (zero gap and offset) gives the anchor point, P.near on their offsets
-- the position; both are linear in the edges, so the result is exact at any aspect. Returns the slot (alx, aly, x, y)
-- and its anchor point.
function P.nearRegion(r, side, align, gap, offset)
    local A = P.near({ l = r.l.a, t = r.t.a, r = r.r.a, b = r.b.a }, side, align, 0, ZERO)
    local O = P.near({ l = r.l.o, t = r.t.o, r = r.r.o, b = r.b.o }, side, align, gap, offset)
    return O, A.x, A.y
end

function P.rectKey(r)
    return string.format("%g,%g,%g,%g,%g,%g,%g,%g", r.l.a, r.l.o, r.t.a, r.t.o, r.r.a, r.r.o, r.b.a, r.b.o)
end

-- binder: per edge, the outer edge of the two page papers (left of page-left, right of page-right, the smaller top,
-- the larger bottom). Each edge comes from one paper and edges compare by anchor, then by offset: exact while the
-- papers share an edge's anchor or have zero offsets (V8.2.1: both); with different anchors and non-zero offsets the
-- anchor comparison can pick the inner edge at some aspects.
local function less(e, f) return e.a < f.a or (e.a == f.a and e.o < f.o) end
function P.union(L, R)
    return { l = L.l, r = R.r, t = less(R.t, L.t) and R.t or L.t, b = less(L.b, R.b) and R.b or L.b }
end

-- A measured rectangle is valid when every value is finite and it is more than 1 unit wide and tall.
function P.validRect(l, t, r, b)
    for _, v in ipairs({ l, t, r, b }) do if not finite(v) then return false end end
    return r - l > 1 and b - t > 1
end

-- ---- reading regions (game thread). A context is one journal callback's view: the live Journal, the host canvas
-- (or nil: looked up on first use), and the regions read so far (each region is read at most once per context, so at
-- most once per tick). Nothing in it outlives the callback.
function P.journalCtx(j, canvas) return { j = j, canvas = canvas, rects = {}, why = {} } end

local function className(o)
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or nil
end

local function ctxMap(ctx)
    if ctx.mw == nil then
        local ok, m = pcall(C.prop, ctx.j, "MapWidget")
        ctx.mw = ok and C.valid(m) and m or false
    end
    return ctx.mw or nil
end

local function ctxCanvas(ctx)
    if not ctx.canvas then
        local mw = ctxMap(ctx)
        local ok, c = false, nil
        if mw then ok, c = pcall(function() return mw.WidgetTree.RootWidget end) end
        ctx.canvas = ok and C.valid(c) and c or false
    end
    return ctx.canvas or nil
end

local function missing(name, what)
    C.warnOnce("region:" .. name, "journal region '%s': %s (%s); its elements stay collapsed", name, what, REGIONS[name].path)
    return nil, "missing"
end

-- An exact region: its widget's CanvasPanelSlot, stretched on both axes; the edges from the live anchors and offsets.
local function exactRegion(ctx, name)
    local spec = REGIONS[name]
    local mw = ctxMap(ctx)
    if not mw then return nil, "no map page" end
    local okW, w = pcall(C.prop, mw, spec.prop)
    if not (okW and C.valid(w)) then return missing(name, "its widget is missing") end
    local okS, slot = pcall(C.prop, w, "Slot")
    if not (okS and slot ~= nil and className(slot) == "CanvasPanelSlot") then return missing(name, "its widget is not in a CanvasPanelSlot") end
    local okR, an, off = pcall(function() return slot:GetAnchors(), slot:GetOffsets() end)
    if not (okR and an and off) then return missing(name, "its slot could not be read") end
    local nx, ny, xx, xy = an.Minimum.X, an.Minimum.Y, an.Maximum.X, an.Maximum.Y
    local L, T, R, B = off.Left, off.Top, off.Right, off.Bottom
    for _, v in ipairs({ nx, ny, xx, xy, L, T, R, B }) do
        if not finite(v) then return missing(name, "its slot has a non-number anchor or offset") end
    end
    if nx == xx or ny == xy then return missing(name, "its slot is not stretched on both axes") end
    return { l = { a = nx, o = L }, t = { a = ny, o = T }, r = { a = xx, o = -R }, b = { a = xy, o = -B } }
end

-- Core's ModActor CDO, kept as a weak handle. A miss is remembered until the next Journal open, so a missing pak
-- never turns into a StaticFindObject miss (a full object scan) on every tick.
local CDO_PATH = "/Game/Mods/" .. C.NAME .. "/ModActor.Default__ModActor_C"
local cdoRef, cdoMissed = nil, false
local function cdoOf()
    if cdoRef then
        local okD, o = pcall(C.deref, cdoRef)
        if okD and o then return o end
        pcall(C.free, cdoRef)
        cdoRef = nil
    end
    if cdoMissed then return nil end
    local o = C.found(CDO_PATH)
    if not o then cdoMissed = true return nil end
    local okR, h = pcall(C.ref, o)
    if okR then cdoRef = h end
    return o
end

-- A measured region: its widget (prop, then GetParent ups times, of class cls), measured in the host canvas's units
-- with <Core>_RectIn. nil, "not painted yet" until the rectangle is valid.
local function measuredRegion(ctx, name)
    local spec = REGIONS[name]
    local mw = ctxMap(ctx)
    if not mw then return nil, "no map page" end
    local okW, w = pcall(C.prop, mw, spec.prop)
    if not (okW and C.valid(w)) then return missing(name, "its widget is missing") end
    for _ = 1, spec.ups do
        local okP, p = pcall(C.call0, w, "GetParent")
        if not (okP and C.valid(p)) then return missing(name, "its widget's parent is missing") end
        w = p
    end
    if spec.cls and className(w) ~= spec.cls then return missing(name, "found a " .. tostring(className(w)) .. ", not a " .. spec.cls) end
    local canvas = ctxCanvas(ctx)
    if not canvas then return nil, "no host canvas" end
    local cdo = cdoOf()
    if not cdo then
        C.warnOnce("region-cdo", "journal regions: %s's ModActor is not loaded; measured regions stay collapsed", C.NAME)
        return nil, "core's ModActor is not loaded"
    end
    local okM, tl, br = pcall(function()
        local fn = cdo[C.NAME .. "_RectIn"]
        return fn(cdo, canvas, w, { X = 0, Y = 0 }), fn(cdo, canvas, w, { X = 1, Y = 1 })
    end)
    if not okM then
        C.warnOnce("region-rectin", "journal regions: %s_RectIn failed (is %s's pak current?): %s", C.NAME, C.NAME, tostring(tl):match("^[^\n]*"))
        return nil, "measuring failed"
    end
    local okV, l, t, r, b = pcall(function() return tl.X, tl.Y, br.X, br.Y end)
    if not (okV and P.validRect(l, t, r, b)) then return nil, "not painted yet" end
    return { l = { a = 0, o = l }, t = { a = 0, o = t }, r = { a = 0, o = r }, b = { a = 0, o = b } }
end

-- Per open: which measured regions have been valid (re-read every tick until then), and the journal tick counter.
local regionOk = {}
local jtickNo = 0

local function readRegion(ctx, name)
    local kind = REGIONS[name].kind
    if kind == "exact" then return exactRegion(ctx, name) end
    if kind == "union" then
        local L, wl = P.region("page-left", ctx)
        if not L then return nil, wl end
        local R, wr = P.region("page-right", ctx)
        if not R then return nil, wr end
        return P.union(L, R)
    end
    local r, why = measuredRegion(ctx, name)
    regionOk[name] = r ~= nil or nil
    return r, why
end

-- The region's rectangle in this context, or nil and why. Read once per context; never raises.
function P.region(name, ctx)
    if not ctx then return nil, "no Journal" end
    local got = ctx.rects[name]
    if got == nil then
        local t = C.pt()
        local ok, r, why = pcall(readRegion, ctx, name)
        C.pa("place.region", t)
        if not ok then
            C.warnOnce("region-fail:" .. name, "journal region '%s' could not be read: %s", name, tostring(r):match("^[^\n]*"))
            r, why = nil, "failed"
        end
        got = r or false
        ctx.rects[name], ctx.why[name] = got, why
    end
    return got or nil, ctx.why[name]
end

-- ---- applying to widgets (game thread; called by text.lua)

local function setSlot(el, w, s, ax, ay)
    local key = string.format("%g,%g,%g,%g,%g,%g", ax, ay, s.alx, s.aly, s.x, s.y)
    if el.slotKey == key then return end
    local t = C.pt()
    local slot = w.Slot
    C.count(); slot:SetAutoSize(true)
    C.count(); slot:SetAnchors({ Minimum = { X = ax, Y = ay }, Maximum = { X = ax, Y = ay } })
    C.count(); slot:SetAlignment({ X = s.alx, Y = s.aly })
    C.count(); slot:SetPosition({ X = s.x, Y = s.y })
    el.slotKey = key
    C.pa("place.slot", t)
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
    local t = C.pt()
    C.count(); w:SetVisibility(want)
    el.appliedVis = want
    C.pa("place.vis", t)
end

-- Places one near or absolute element (corner elements go through restack). ctx: the journal context (journal only).
local function placeSingle(el, w, hud, ctx)
    local pl = el.place
    if pl.absolute then
        local s = P.absolute(pl.absolute)
        setSlot(el, w, s, s.ax, s.ay)
        el.nearAbsent = false
    elseif pl.near and pl.host == "journal" then
        local r, why = P.region(pl.near, ctx)
        el.nearAbsent = r == nil
        el.nearWhy = why
        if r then
            local s, ax, ay = P.nearRegion(r, pl.side, pl.align, pl.gapUnits, pl.offset)
            setSlot(el, w, s, ax, ay)
            el.nearRect = P.rectKey(r)
        else
            el.nearRect = nil
        end
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
    local t = C.pt()
    if prepass then pcall(function() C.count(); w:ForceLayoutPrepass() end) end
    C.pa("place.prepass", t)
    t = C.pt()
    local ds = w:GetDesiredSize()
    C.pa("place.measure", t)
    return tonumber(ds.Y) or 0
end

-- The key of a corner stack: (region, corner); the host is the settle table's. Interned, so ticks allocate nothing.
local SKEYS = {}
local function skeyOf(corner, region)
    local byR = SKEYS[region or ""]
    if not byR then byR = {}; SKEYS[region or ""] = byR end
    local k = byR[corner]
    if not k then k = (region or "") .. "|" .. corner; byR[corner] = k end
    return k
end
P.skeyOf = skeyOf
local stackRect = {} -- journal stack key -> the region rectangle key it was last placed in (measured regions)

-- Re-stacks one corner of this mod on one host (story 19: of one region, on the journal). live(el) -> widget or nil
-- (text.lua: live in that host's canvas). ctx: the journal context (journal only). When the region isn't available
-- (missing, or a measured one not painted yet), the stack's elements are collapsed.
function P.restack(host, corner, live, prepass, region, ctx)
    local items, ws, els = {}, {}, {}
    local r, why = nil, nil
    if region then r, why = P.region(region, ctx) end
    local absent = region ~= nil and r == nil
    for _, el in ipairs(C.order) do
        if not el.removed and el.place.corner == corner and el.place.host == host and el.place.region == region then
            local w = live(el)
            if w then
                el.nearAbsent, el.nearWhy = absent, why
                P.applyVisibility(el, w)
                if el.visible and not absent then
                    items[#items + 1] = { gap = el.place.gapUnits, inset = el.place.insetUnits, offset = el.place.offset, height = 0 }
                    ws[#ws + 1], els[#els + 1] = w, el
                end
            end
        end
    end
    if region then stackRect[skeyOf(corner, region)] = r and P.rectKey(r) or nil end
    if absent then return end
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
    if r then out = P.inRegion(corner, out, r) end
    for i, s in ipairs(out) do setSlot(els[i], ws[i], s, s.ax, s.ay) end
    P.settle(host, corner, region) -- Slate may measure later than this: re-check the heights for a few ticks
end

-- Places an element whose widget is live now. Corner elements re-stack their whole corner (on their host, in their
-- region). hostObj is the live HUD or Journal (near elements read the HUD's named elements from it); ctx the journal
-- context (journal only).
function P.apply(el, w, hostObj, live, prepass, ctx)
    if el.place.corner then
        el.nearAbsent = false
        P.restack(el.place.host, el.place.corner, live, prepass, el.place.region, ctx)
    else
        placeSingle(el, w, hostObj, ctx)
    end
end

-- Per tick (text.lua). Steady state must cost next to nothing (story 7: a tick under 0.5 ms), so:
-- * near elements: every tick only whether their element is drawn (three reads; story 9 re-checks presence every
--   tick); its rectangle is re-read every NEAR_RECT_TICKS ticks, or at once when it comes back;
-- * corner stacks: heights are re-measured only for SETTLE_TICKS ticks after the corner was stacked (an attach, a
--   HUD shown, a set or setStyle), which is when Slate's measure arrives. Text changes go through set/setStyle,
--   which re-stack on their own; nothing else changes an element's height;
-- * journal regions (story 19): a measured region is re-read every journal tick until it is valid, then every
--   REGION_TICKS journal ticks (a window resize); its elements are re-placed only when its rectangle changed. Exact
--   regions are anchors: nothing to follow.
local NEAR_RECT_TICKS = 4
local REGION_TICKS = 4
local SETTLE_TICKS = 4
local settle = { hud = {}, journal = {} } -- host -> stack key (region|corner) -> ticks left to re-measure
local tickNo = 0

-- Marks one stack of a host (corner and region), or every stack of the host (corner nil), for re-measuring on the
-- next SETTLE_TICKS ticks.
function P.settle(host, corner, region)
    local s = settle[host]
    if not s then return end
    if corner then s[skeyOf(corner, region)] = SETTLE_TICKS return end
    if host == "hud" then
        for c in pairs(CORNERS) do s[skeyOf(c, nil)] = SETTLE_TICKS end
        return
    end
    for _, el in ipairs(C.order) do
        if not el.removed and el.place.host == host and el.place.corner then s[skeyOf(el.place.corner, el.place.region)] = SETTLE_TICKS end
    end
end

-- Story 19: a new Journal (or none): measured regions are unknown again (zero until its first paint), the journal
-- tick counter restarts, and a missing ModActor is looked for again.
function P.journalReset()
    for k in pairs(regionOk) do regionOk[k] = nil end
    for k in pairs(stackRect) do stackRect[k] = nil end
    jtickNo = 0
    cdoMissed = false
end

local function nearDrawn(hud, name)
    local target = hud[ELEMENTS[name].prop]
    if not C.valid(target) then return false end
    if not C.drawn(tonumber(target:GetVisibility()) or 0) then return false end
    if name == "crosshair" then
        local okH, hiding = pcall(function() return hud.HidingCrosshair end)
        if okH and hiding == true then return false end
    end
    return true
end

local function isMeasured(name) return name ~= nil and REGIONS[name] ~= nil and REGIONS[name].kind == "measured" end

-- Journal regions on one journal tick: re-reads the measured regions that are due (each at most once: ctx caches) and
-- re-places what a changed rectangle moves.
local function regionTick(j, live, ctx)
    jtickNo = jtickNo + 1
    local due = jtickNo % REGION_TICKS == 0
    local restacks = nil -- stack key -> an element of that stack
    for _, el in ipairs(C.order) do
        if not el.removed and el.place.host == "journal" then
            local pl = el.place
            local name = pl.near or pl.region
            -- due, not valid yet, or already read this tick (an earlier element of this tick may just have made it valid)
            if isMeasured(name) and (due or not regionOk[name] or ctx.rects[name] ~= nil) then
                local r = P.region(name, ctx)
                local key = r and P.rectKey(r) or nil
                if pl.near then
                    local w = live(el)
                    if w and (key ~= el.nearRect or (key == nil) ~= (el.nearAbsent == true)) then
                        local ok, err = pcall(placeSingle, el, w, j, ctx)
                        if not ok then C.warnOnce("place:" .. el.id, "place '%s' failed: %s", el.id, tostring(err):match("^[^\n]*")) end
                    end
                elseif pl.corner then
                    local k = skeyOf(pl.corner, pl.region)
                    if key ~= stackRect[k] and live(el) then restacks = restacks or {}; restacks[k] = el end
                end
            end
        end
    end
    if not restacks then return end
    for k, el in pairs(restacks) do
        local ok, err = pcall(P.restack, "journal", el.place.corner, live, true, el.place.region, ctx)
        if not ok then C.warnOnce("stack:journal" .. k, "stacking journal %s failed: %s", k, tostring(err):match("^[^\n]*")) end
    end
end

-- One host's per-tick work: host is "hud" or "journal", hostObj the live HUD or Journal. ctx (journal only, optional):
-- the journal context; made here when not given (its canvas is looked up only when a measured region is read).
function P.tick(host, hostObj, live, ctx)
    if host == "hud" then tickNo = tickNo + 1
    else
        ctx = ctx or P.journalCtx(hostObj, nil)
        regionTick(hostObj, live, ctx)
    end
    local hs = settle[host]
    local stacks = nil -- stack key -> list of { el, w } (visible, live), only for stacks still settling; made on demand
    for _, el in ipairs(C.order) do
        if not el.removed and el.place.host == host then
            local pl = el.place
            if pl.near and host == "hud" then
                local w = live(el)
                if w then
                    local t = C.pt()
                    local okD, drawn = pcall(nearDrawn, hostObj, pl.near)
                    drawn = okD and drawn
                    C.pa("place.nearCheck", t)
                    local wasAbsent = el.nearAbsent == true
                    if drawn == wasAbsent or (drawn and tickNo % NEAR_RECT_TICKS == 0) then
                        t = C.pt()
                        local okR, r = pcall(nearTarget, hostObj, pl.near)
                        local key = okR and r and not r.stretched and string.format("%g,%g,%g,%g,%g,%g", r.l, r.t, r.r, r.b, r.ax, r.ay) or nil
                        if (key == nil) ~= wasAbsent or key ~= el.nearRect then placeSingle(el, w, hostObj) end
                        C.pa("place.nearRect", t)
                    end
                end
            elseif pl.corner and el.visible and not el.nearAbsent then
                local k = skeyOf(pl.corner, pl.region)
                if (hs[k] or 0) > 0 then
                    local w = live(el)
                    if w then
                        stacks = stacks or {}
                        local list = stacks[k] or {}
                        stacks[k] = list
                        list[#list + 1] = { el = el, w = w }
                    end
                end
            end
        end
    end
    for k, n in pairs(hs) do hs[k] = n > 1 and n - 1 or nil end
    -- Only a stack holding two or more elements can be pushed around by a height change.
    if not stacks then return end
    for _, list in pairs(stacks) do
        if #list >= 2 then
            local dirty = false
            for i = 1, #list - 1 do
                if heightOf(list[i].w, false) ~= list[i].el.stackHeight then dirty = true end
            end
            local pl = list[1].el.place
            if dirty then P.restack(host, pl.corner, live, false, pl.region, ctx) end
        end
    end
end

-- ---- public

-- elements([host]) -> { <name> = <description> } (a fresh table each call): no argument or "hud", the HUD's named
-- elements (story 9); "journal", the Journal's regions (story 19).
function P.elements(...)
    C.enter("elements")
    local n = select("#", ...)
    if n > 1 then C.fail("%s.elements: expected 0 or 1 arguments, got %d", C.UI, n) end
    local host = ...
    if host == nil then host = "hud" end
    if host ~= "hud" and host ~= "journal" then C.fail("%s.elements: unknown host %s (valid: %s)", C.UI, C.describe(host), C.HOST_NAMES) end
    local out = {}
    for k, v in pairs(host == "hud" and ELEMENTS or REGIONS) do out[k] = v.desc end
    return out
end

-- place(handle, intent): stores the intent; re-places now when the element is live. Set by text.lua (it needs the
-- element registry and attach).
P.place = nil

P._GAP, P._CORNERS, P._GAP_NAMES = GAP, CORNERS, GAP_NAMES
P._REGIONS, P._REGION_NAMES, P._regionOk = REGIONS, REGION_NAMES, regionOk
function P._jtick() return jtickNo end
return P
