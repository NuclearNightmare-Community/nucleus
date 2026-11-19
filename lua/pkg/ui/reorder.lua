-- Core story 38 (0.16.0, UI-16): drag to reorder the rows of a list. Internal: no public function; list.lua and row.lua
-- take the keys (list.create's reorderable and onReorder, row.create's locked, row.setLocked), focus.lua drives the
-- keyboard and gamepad (hold A or Enter on a row) through the shared pieces here, and SkelTest reads RO.stats().
--
-- What moves: only visible, unlocked rows (not game-style rows) of a reorderable list. Every other visible child (a
-- locked row, a text, a button, a lone control) is fixed: it never changes index, and a move stays inside the run of
-- children between the fixed ones around its row (its segment). Hidden children keep their place relative to their
-- neighbours and are never a target. A target (slot) k of a segment with visible movable rows V[1..n] is "before V[k+1]"
-- (k < n) or "after V[n]" (k = n); the slots right before and right after the moved row change nothing.
--
-- Where: only while the list sits in this Lua state's global top open window (a screen host). Elsewhere a row's
-- Blueprint flag Draggable stays false (the UI tick keeps it in sync), so a press on it is Unhandled as before.
--
-- The mouse (UMG's own drag and drop, WBP_<Core>Row / WBP_<Core>List): a left press on a row's own area starts Slate's
-- drag detection (its dead zone); OnDragDetected calls <Core>_OnDragStart, whose post-hook here checks the row and sets
-- the drag up: the row at theme.reorder.sourceOpacity, a lifted copy (WBP_<Core>Lift: the row's size, the band's look,
-- copies of its texts) as the drag visual from the grab point, focus and the band on the row, and a 16 ms game-thread
-- loop (LoopInGameThreadWithDelay) that moves the insertion line (the list's "Line", theme.game.accent) and auto-scrolls
-- near the list's top and bottom edges (theme.reorder.edge, speed proportional to depth up to theme.reorder.speed, also
-- while the pointer is still). OnDrop on the list calls <Core>_OnDrop: a left release over the list drops (one rebuild
-- when the order changed, then onReorder, focus on the moved row); a right release, a release over another list, Escape
-- (Slate's; the row's OnDragCancelled calls <Core>_OnDragCancel), a drop nowhere, B or Back, the window or the list
-- going, or any API change to the list (C.listChanged) cancels: no change, no callback. The loop stops when the drag
-- ends or when WidgetBlueprintLibrary:IsDragDropping() turns false (a drop this state never saw: cancelled).
--
-- Rules of story 37: every hook body runs under pcall with C.inDispatch raised (cached assets and classes only; no hook
-- or LoadMap hook registered there) and one C.warnOnce for a fault; another mod's tag, a stale widget, an off-thread
-- call or an operation that isn't this state's drag is ignored silently and counted. The hooks are registered once per
-- Lua state, by full path, from the UI poll, while the state has a reorderable list; the UI tick also keeps the lift
-- class and the carried row's instance warm then (a cold lift class: the drag shows no copy). onReorder(list, ids) runs
-- through C.callDependent; a throw is logged once per list and the order stays. No UObject is kept between calls: the
-- drag records ids, numbers and the operation's address.
local BASE = (...):gsub("%.ui%.reorder$", "")
local C = require(BASE .. ".ui.common")
local H = require(BASE .. ".ui.hud")
local X = require(BASE .. ".ui.text")
local PN = require(BASE .. ".ui.panel")
local A = require(BASE .. ".ui.assets")
local theme = require(BASE .. ".ui.theme")

local RO = {}
local WBL = "/Script/UMG.Default__WidgetBlueprintLibrary"
local WLL = "/Script/UMG.Default__WidgetLayoutLibrary"
local CDO_PATH = "/Game/Mods/" .. C.NAME .. "/ModActor.Default__ModActor_C"
local PIVOT_MOUSE_DOWN = 0 -- EDragPivot::MouseDown: the copy keeps the grab point under the pointer
local SIZE_AUTO, SIZE_FILL = 0, 1
local S = { drags = 0, drops = 0, dragCancels = 0, reorders = 0, ignored = 0, faults = 0, cbFaults = 0,
    lifts = 0, noLift = 0, interrupts = 0, scrolled = 0, lineMoves = 0, loops = 0, refused = 0,
    hooked = false, hookTries = 0, dragHookOk = false, dropHookOk = false }

local function firstLine(e) return (tostring(e):match("^[^\n]*")) end

-- ---------------------------------------------------------------- the model (pure: element tables only)

-- A row that can be dragged or picked up (in a reorderable list: the caller checks the list).
function RO.movable(ch)
    return ch ~= nil and not ch.removed and ch.kind == "row" and ch.visible == true and ch.locked ~= true and ch.like == nil
end
-- A child that stays where it is and bounds the segments: visible and not movable.
local function fixed(ch) return not ch.removed and ch.visible == true and not RO.movable(ch) end
RO._fixed = fixed

local function indexOf(list, x) for i, v in ipairs(list) do if v == x then return i end end return nil end
RO._indexOf = indexOf

-- segment(children, i) -> lo, hi: the run of children around index i between the fixed children before and after it.
function RO.segment(children, i)
    local lo, hi = i, i
    while lo > 1 and not fixed(children[lo - 1]) do lo = lo - 1 end
    while hi < #children and not fixed(children[hi + 1]) do hi = hi + 1 end
    return lo, hi
end

-- slots(children, i) -> V, p: the visible movable rows of i's segment in order (the targets are the n + 1 places
-- around them) and the position of children[i] among them (nil when it isn't one).
function RO.slots(children, i)
    local lo, hi = RO.segment(children, i)
    local V, p = {}, nil
    for j = lo, hi do
        local ch = children[j]
        if RO.movable(ch) then
            V[#V + 1] = ch
            if j == i then p = #V end
        end
    end
    return V, p
end

-- moved(children, row, k) -> a new children array with row at slot k of its segment, or nil when that changes nothing
-- (k right before or after row itself, out of range, row not movable there).
function RO.moved(children, row, k)
    local i = indexOf(children, row)
    if not i or math.type(k) ~= "integer" then return nil end
    local V, p = RO.slots(children, i)
    if not p or k < 0 or k > #V or k == p - 1 or k == p then return nil end
    local out = {}
    for _, ch in ipairs(children) do if ch ~= row then out[#out + 1] = ch end end
    local ref, after
    if k < #V then ref, after = V[k + 1], false else ref, after = V[#V], true end
    local ri = indexOf(out, ref)
    table.insert(out, after and ri + 1 or ri, row)
    return out
end

-- The slot one visible step up (delta -1) or down (+1) from row, or nil at its segment's edge.
function RO.step(children, row, delta)
    local i = indexOf(children, row)
    if not i then return nil end
    local V, p = RO.slots(children, i)
    if not p then return nil end
    local k = delta < 0 and p - 2 or p + 1
    if k < 0 or k > #V then return nil end
    return k
end

-- The slot a content-space y falls in: the number of V's rows whose middle lies above it (tops / heights by V index).
function RO.slotAt(tops, heights, y)
    local k = 0
    for j = 1, #tops do
        if tops[j] + heights[j] / 2 < y then k = j end
    end
    return k
end

-- The content-space y of slot k: the middle of the gap before V[k + 1], or after V[n].
function RO.slotY(tops, heights, k, gap)
    local n = #tops
    if n == 0 then return 0 end
    if k < n then return math.max(tops[k + 1] - gap / 2, 0) end
    return tops[n] + heights[n] + gap / 2
end

-- The list's children ids, in order (a new array).
function RO.ids(list)
    local out = {}
    for i, ch in ipairs(list.children) do out[i] = ch.id end
    return out
end

-- Whether two child arrays hold the same elements in the same order.
function RO.same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- ---------------------------------------------------------------- applying an order, the callback

-- Applies a new order of list's children (panel.lua's own path: one rebuild of the live box, nothing when the same; no
-- C.listChanged, so no cancel of the move making it). Returns whether it changed.
function RO.apply(list, newChildren)
    return PN._applyOrder(list, newChildren) == true
end

-- onReorder(list, ids), once per finished move that changed the order, through C.callDependent (cached assets only); a
-- throw logs one WARN per list and the order stays.
function RO.fire(list)
    local f = list.onReorder
    if type(f) ~= "function" then return end
    S.reorders = S.reorders + 1
    local ok, err = C.callDependent(f, list.handle, RO.ids(list))
    if not ok then
        S.cbFaults = S.cbFaults + 1
        C.warnOnce("onReorder:" .. list.id, "list '%s' onReorder: %s (the order stays; further failures of this list not logged)", list.id, firstLine(err))
    end
end

-- ---------------------------------------------------------------- where it works

RO.cb = {} -- set by focus.lua: globalTop(rec), focusRow(row, scroll), remember(), carrying(), busy(), tick(),
           -- interrupt(list), dragEnded()

-- The open window record a list sits in, or nil (lists sit directly on a host).
function RO.windowOf(list)
    if not list or list.removed or list.panel then return nil end
    local host = list.place and list.place.host
    if type(host) ~= "string" or C.hostKind(host) ~= "screen" then return nil end
    local rec = C.windows[host:sub(8)]
    if not (rec and rec.open) then return nil end
    return rec
end

-- Whether list's rows can be moved now: reorderable, shown, in this state's global top open window.
function RO.active(list)
    if not (list and list.kind == "list" and list.reorderable == true and list.visible and list.attached) then return false end
    local rec = RO.windowOf(list)
    if not rec then return false end
    if RO.cb.globalTop and not RO.cb.globalTop(rec) then return false end
    return true
end

-- ---------------------------------------------------------------- widgets (game thread)

local function liveWidget(el)
    if not el.ref then return nil end
    local ok, w = pcall(C.deref, el.ref)
    return ok and w or nil
end
RO._liveWidget = liveWidget

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

local function pointer()
    local ok, x, y = pcall(function()
        local p = StaticFindObject(WLL):GetMousePositionOnPlatform()
        return p.X, p.Y
    end)
    if ok and type(x) == "number" and type(y) == "number" and x == x and y == y then return { X = x, Y = y } end
    return nil
end

-- core's geometry functions on its ModActor CDO (layout units from absolute ones). A struct a function returns is
-- copied into a plain { X, Y } before it goes into another call.
local function vec2(v) return { X = v.X, Y = v.Y } end
local function geoFns(cdo)
    local tl, br, toLocal = cdo[C.NAME .. "_AbsTopLeft"], cdo[C.NAME .. "_AbsBottomRight"], cdo[C.NAME .. "_AbsToLocal"]
    return function(w) return vec2(tl(cdo, w)) end, function(w) return vec2(br(cdo, w)) end,
        function(w, a) return vec2(toLocal(cdo, w, a)) end
end
RO._geoFns = geoFns

-- Reads what the drag needs, once at its start, in layout units: the segment's rows (tops in the list's content space,
-- heights) and the visible area's size. nil and why when it can't be measured. The rows' places come from the layout
-- (each visible child's desired height and the list's gap before it, as text.lua applyGaps sets them), not from their
-- geometry: a row scrolled out of view is not painted, so its cached geometry is stale (VM run 1: rows below the view
-- measured at the desktop's origin, every drop landed at the end).
local function measure(list, lw, V)
    local cdo = cdoOf()
    if not cdo then return nil, C.NAME .. "'s ModActor is not loaded" end
    local ok, res = pcall(function()
        local _, br, toLocal = geoFns(cdo)
        local scroll = lw.Scroll
        local g = { tops = {}, heights = {} }
        local at = {}
        local y, first = 0, true
        for _, ch in ipairs(list.children) do
            if not ch.removed and ch.visible then
                local w = liveWidget(ch)
                if w then
                    if not first then y = y + (list.gapUnits or 0) end
                    first = false
                    local d = w:GetDesiredSize()
                    at[ch] = { t = y, h = d.Y }
                    y = y + d.Y
                end
            end
        end
        for j, row in ipairs(V) do
            local a = at[row]
            if not a then error("row '" .. row.id .. "' has no widget", 0) end
            g.tops[j], g.heights[j] = a.t, a.h
        end
        local size = toLocal(scroll, br(scroll))
        g.w, g.h = size.X, size.Y
        g.offset = scroll:GetScrollOffset()
        return g
    end)
    if not ok then return nil, firstLine(res) end
    for j = 1, #res.tops do
        local t, h = res.tops[j], res.heights[j]
        if type(t) ~= "number" or t ~= t or type(h) ~= "number" or h ~= h then return nil, "a row is not laid out yet" end
    end
    if not (type(res.h) == "number" and res.h > 0 and type(res.offset) == "number") then return nil, "the list is not laid out yet" end
    return res
end

-- ---------------------------------------------------------------- the lifted copy

-- WBP_<Core>Lift for row (widget rw): its size, the band's look (the strong instance, else the plain selection; cached
-- only) and copies of its visible texts with their fill weights, placed where they sit in the row. nil when the lift
-- class isn't cached (or anything fails: one WARN); the drag then shows no copy.
local function makeLift(row, rw, size)
    local cls = X._classOf("lift") -- C.inDispatch is raised: the cache only
    if not cls then S.noLift = S.noLift + 1 return nil end
    local ok, res = pcall(function()
        local wbl = StaticFindObject(WBL)
        C.count()
        local lw = wbl:Create(rw, cls, X._ownerFor(rw))
        if not C.valid(lw) then error("creating " .. C.LIFT_SHORT .. " failed", 0) end
        C.count(); lw:SetLiftSize(size.w, size.h)
        local g = theme.game
        local mid = A.focusRowMaterial(rw, true)
        local pad = row.style and row.style.pad or 0
        if mid then
            C.count(); lw:SetBackgroundMaterial(mid, g.focusRowTint.r, g.focusRowTint.g, g.focusRowTint.b, g.focusRowTint.a, pad)
        else
            local m = A.get("mat:selection", true)
            if m then
                C.count(); lw:SetBackgroundMaterial(m, g.rowTint.r, g.rowTint.g, g.rowTint.b, g.rowTint.a, pad)
            else
                local c = g.focusRowColors.CinematicWearColor
                C.count(); lw:SetBackground(c.r, c.g, c.b, 1)
                C.count(); lw:SetBackgroundPadding(pad)
            end
        end
        X._applyRowPad(row, lw)
        local tcls = X._classOf("text")
        if not tcls then return lw end
        local px = select(1, X._rowPad(row))
        local cdo = cdoOf()
        local left = px -- the right edge of what came before, in the row's local units
        local copies = {}
        for _, ch in ipairs(row.children) do
            if ch.kind == "text" and not ch.removed and ch.visible then
                local cw = liveWidget(ch)
                if cw then
                    local x0, x1 = nil, nil
                    if cdo then
                        local okG, a, b = pcall(function()
                            local tl, br, toLocal = geoFns(cdo)
                            return toLocal(rw, tl(cw)).X, toLocal(rw, br(cw)).X
                        end)
                        if okG and type(a) == "number" and type(b) == "number" and a == a and b == b and b >= a then x0, x1 = a, b end
                    end
                    C.count()
                    local tw = wbl:Create(rw, tcls, X._ownerFor(rw))
                    if C.valid(tw) then
                        -- a copy of the element's table, so the text's own look functions draw it without touching the
                        -- element's state
                        local copy = {}
                        for k, v in pairs(ch) do copy[k] = v end
                        copy.ref, copy.matBg, copy.selBg, copy.padKey, copy.alignKept = nil, nil, nil, nil, nil
                        X.KIND.text.content(copy, tw, true)
                        X.KIND.text.style(copy, tw, true)
                        C.count(); lw.HBox:AddChild(tw)
                        local l = x0 and math.max(x0 - left, 0) or (#copies > 0 and (row.gapUnits or 0) or 0)
                        copies[#copies + 1] = { w = tw, l = l, fill = ch.fill }
                        if x1 then left = x1 end
                    end
                end
            end
        end
        local W = size.w
        for j, c in ipairs(copies) do
            local r = (j == #copies and left > px) and math.max(W - px - left, 0) or 0
            C.count()
            c.w.Slot:SetPadding({ Left = c.l, Top = 0, Right = r, Bottom = 0 })
            C.count(); c.w.Slot:SetSize({ SizeRule = c.fill and SIZE_FILL or SIZE_AUTO, Value = c.fill or 1.0 })
            C.count(); c.w.Slot:SetVerticalAlignment(2) -- Center
        end
        return lw
    end)
    if not ok then
        S.faults = S.faults + 1
        C.warnOnce("reorder lift", "the dragged row's lifted copy failed (is %s's pak current?): %s; the drag shows no copy", C.NAME, firstLine(res))
        return nil
    end
    S.lifts = S.lifts + 1
    return res
end

-- ---------------------------------------------------------------- the drag

local drag = nil -- { listId, rowId, opAddr, pickup = { child els }, g = measured, V = { rows }, k, lineY, t }
function RO.dragging() return drag ~= nil end
function RO._drag() return drag end

-- The loop (16 ms) shared with focus.lua's hold and carry: runs while a drag, a hold or a carry is on.
local loop = { gen = 0, running = false, handle = nil }
local function stopLoop()
    if not loop.running then return end
    loop.running = false
    loop.gen = loop.gen + 1
    if loop.handle then pcall(CancelDelayedAction, loop.handle) end
    loop.handle = nil
end
local loopBody -- below
function RO.want()
    if loop.running then return true end
    loop.running = true
    loop.gen = loop.gen + 1
    local mine = loop.gen
    local handle
    local ok, res = pcall(LoopInGameThreadWithDelay, theme.reorder.loopMs, function()
        if mine ~= loop.gen then
            if handle then pcall(CancelDelayedAction, handle) end
            return
        end
        local okB, errB = pcall(loopBody)
        if not okB then
            S.faults = S.faults + 1
            C.warnOnce("reorder loop", "reorder handling failed: %s (further failures not logged)", firstLine(errB))
        end
    end)
    if ok and math.type(res) == "integer" then
        handle = res
        loop.handle = res
        S.loops = S.loops + 1
        return true
    end
    loop.running = false
    loop.gen = loop.gen + 1
    C.warnOnce("reorder loop start", "the reorder loop could not start: %s", ok and ("LoopInGameThreadWithDelay returned " .. tostring(res)) or firstLine(res))
    return false
end
RO._loop = loop

local function setLine(list, lw, y)
    local ok, err = pcall(function()
        local line = lw.Line
        if y == nil then
            if list.lineShown ~= false then C.count(); line:SetVisibility(C.VIS.Collapsed) end
            list.lineShown = false
            return
        end
        if list.lineShown ~= true then
            local a = theme.game.accent
            C.count(); line:SetColorAndOpacity({ R = a.r, G = a.g, B = a.b, A = a.a })
            C.count(); line:SetVisibility(C.VIS.HitTestInvisible)
            list.lineShown = true
        end
        if list.lineY ~= y then
            C.count(); line.Slot:SetPadding({ Left = 0, Top = y, Right = 0, Bottom = 0 })
            list.lineY = y
            S.lineMoves = S.lineMoves + 1
        end
    end)
    if not ok then
        S.faults = S.faults + 1
        C.warnOnce("reorder line", "the insertion line failed (is %s's pak current?): %s", C.NAME, firstLine(err))
    end
end

-- Ends the drag (dropped or cancelled): the row's opacity back, the line hidden, the loop stopped unless a hold or a
-- carry still needs it. Returns the ended drag.
local function finish(cancelled)
    local d = drag
    drag = nil
    if not d then return nil end
    local row, list = C.els[d.rowId], C.els[d.listId]
    local rw = row and liveWidget(row)
    if rw then pcall(function() C.count(); rw:SetRenderOpacity(1) end) end
    local lw = list and liveWidget(list)
    if lw then setLine(list, lw, nil) elseif list then list.lineShown = nil end
    if cancelled then S.dragCancels = S.dragCancels + 1 end
    if not (RO.cb.busy and RO.cb.busy()) then stopLoop() end
    if RO.cb.dragEnded then pcall(RO.cb.dragEnded) end
    return d
end

-- Cancels the drag in this state (no change, no callback). slate: also end Slate's drag (an API change, the window
-- going, B / Back): its OnDragCancelled then finds no drag.
function RO.cancel(slate)
    if not drag then return end
    finish(true)
    if slate then
        local ok = pcall(function() StaticFindObject(WBL):CancelDragDrop() end)
        if not ok then S.faults = S.faults + 1 end
    end
end

-- The pointer's place now: { x, y (in the visible area), inside, cy (in the content), k (target slot) } or nil when
-- unreadable. Both from the last paint's geometry of the visible area and of the content (VBox, always painted).
local function where(d, lw, scroll)
    local cdo = cdoOf()
    local p = pointer()
    if not (cdo and p) then return nil end
    local ok, loc, con = pcall(function()
        local toLocal = cdo[C.NAME .. "_AbsToLocal"]
        return vec2(toLocal(cdo, scroll, p)), vec2(toLocal(cdo, lw.VBox, p))
    end)
    if not ok then return nil end
    local x, y, cy = loc.X, loc.Y, con.Y
    if type(x) ~= "number" or type(y) ~= "number" or type(cy) ~= "number" or x ~= x or y ~= y or cy ~= cy then return nil end
    local inside = x >= 0 and x <= d.g.w and y >= 0 and y <= d.g.h
    return { x = x, y = y, inside = inside, cy = cy, k = RO.slotAt(d.g.tops, d.g.heights, cy) }
end

-- One loop step of a drag: the target slot, the insertion line, auto-scroll.
local function dragStep()
    local d = drag
    local okD, dragging = pcall(function() return StaticFindObject(WBL):IsDragDropping() end)
    if okD and dragging == false then finish(true) return end -- the drag ended without this state seeing its end
    local list, row = C.els[d.listId], C.els[d.rowId]
    if not (list and row and not row.removed and RO.active(list)) then RO.cancel(true) return end
    local lw = liveWidget(list)
    if not lw then RO.cancel(true) return end
    local scroll = lw.Scroll
    local okO, offset = pcall(function() return scroll:GetScrollOffset() end)
    if not (okO and type(offset) == "number") then return end
    local now = C.micros()
    local dt = math.min(math.max((now - (d.t or now)) / 1e6, 0), 0.1)
    d.t = now
    local at = where(d, lw, scroll)
    if not at then return end
    -- auto-scroll: within edge units of the top or the bottom, proportional to depth, while the pointer is over the list
    local r = theme.reorder
    if at.x >= 0 and at.x <= d.g.w and at.y >= 0 and at.y <= d.g.h then
        local v = 0
        if at.y < r.edge then v = -r.speed * (r.edge - at.y) / r.edge
        elseif at.y > d.g.h - r.edge then v = r.speed * (at.y - (d.g.h - r.edge)) / r.edge end
        if v ~= 0 and dt > 0 then
            local okE, maxO = pcall(function() return scroll:GetScrollOffsetOfEnd() end)
            local to = offset + v * dt
            if okE and type(maxO) == "number" then to = math.min(to, maxO) end
            to = math.max(to, 0)
            if math.abs(to - offset) > 1e-3 then
                local okS = pcall(function() C.count(); scroll:SetScrollOffset(to) end)
                if okS then
                    S.scrolled = S.scrolled + 1
                    at.cy = at.cy + (to - offset) -- the content moved under the pointer
                    offset = to
                    at.k = RO.slotAt(d.g.tops, d.g.heights, at.cy)
                end
            end
        end
    end
    d.offset = offset
    if not at.inside then
        d.k = nil
        setLine(list, lw, nil)
        return
    end
    d.k = at.k
    local lineH = r.lineH
    local y = RO.slotY(d.g.tops, d.g.heights, at.k, list.gapUnits or 0) + (at.y - at.cy) - lineH / 2
    y = math.floor(math.min(math.max(y, 0), math.max(d.g.h - lineH, 0)) + 0.5)
    setLine(list, lw, y)
end

loopBody = function()
    if drag then dragStep() end
    if RO.cb.tick then RO.cb.tick() end
    if not drag and not (RO.cb.busy and RO.cb.busy()) then stopLoop() end
end

-- ---------------------------------------------------------------- the hooks

local function ignore() S.ignored = S.ignored + 1 end

-- The element whose live widget w is, by its tag (this mod's) and kind; nil for anything else.
local function mine(w, kind)
    if not C.valid(w) then return nil end
    local okT, tag = pcall(function() return w.CoreTag:ToString() end)
    if not (okT and type(tag) == "string") then return nil end
    local pre = C.LOWER .. ":" .. C.modTag .. ":"
    if tag:sub(1, #pre) ~= pre then return nil end -- another mod's
    local el = C.els[tag:sub(#pre + 1)]
    if not (el and not el.removed and el.kind == kind) then return nil end
    local live = liveWidget(el)
    if not live or live:GetAddress() ~= w:GetAddress() then return nil end -- not its live widget
    return el, tag
end

-- <Core>_OnDragStart's post-hook (the row's OnDragDetected): DragOk only for a movable row of an active list.
local function dragStartBody(ctx)
    if C.offGameThread() then return ignore() end
    local w = ctx:get()
    local row, tag = mine(w, "row")
    if not row then return ignore() end
    local list = row.panel
    if not (list and list.kind == "list" and RO.movable(row) and RO.active(list)) then return ignore() end
    if drag or (RO.cb.carrying and RO.cb.carrying()) then S.refused = S.refused + 1 return end
    local okO, op = pcall(function() return w.DragOp end)
    if not (okO and C.valid(op)) then return ignore() end
    local lw = liveWidget(list)
    if not lw then return ignore() end
    local i = indexOf(list.children, row)
    local V = RO.slots(list.children, i)
    local g, why = measure(list, lw, V)
    if not g then
        S.refused = S.refused + 1
        C.warnOnce("reorder measure", "a row drag was refused: %s", tostring(why))
        return
    end
    local rowSize = { w = g.w, h = g.heights[indexOf(V, row)] or 0 }
    do -- the row's own width (the list's visible width less its inset)
        local cdo = cdoOf()
        local okS, sz = pcall(function() local _, br, toLocal = geoFns(cdo) return toLocal(w, br(w)) end)
        if okS and type(sz.X) == "number" and sz.X == sz.X and sz.X > 0 then rowSize.w = sz.X end
    end
    local pickup = {}
    for j, ch in ipairs(list.children) do pickup[j] = ch end
    local lift = makeLift(row, w, rowSize)
    local okV, errV = pcall(function()
        if lift then
            op.DefaultDragVisual = lift
            op.Pivot = PIVOT_MOUSE_DOWN
            op.Tag = tag
        else
            op.Tag = "" -- no copy: Slate would draw the tag as text
        end
        C.count(); w:SetRenderOpacity(theme.reorder.sourceOpacity)
        w.DragOk = true
    end)
    if not okV then
        S.faults = S.faults + 1
        C.warnOnce("reorder start", "a row drag could not start (is %s's pak current?): %s", C.NAME, firstLine(errV))
        pcall(function() w:SetRenderOpacity(1) end)
        return
    end
    drag = { listId = list.id, rowId = row.id, opAddr = op:GetAddress(), pickup = pickup, g = g, V = V, t = C.micros() }
    S.drags = S.drags + 1
    if RO.cb.focusRow then pcall(RO.cb.focusRow, row, false, true) end
    RO.want()
end

-- <Core>_OnDrop's post-hook (the list's OnDrop): a left release over the drag's own list drops; anything else of this
-- state's drag cancels.
local function dropBody(ctx)
    if C.offGameThread() then return ignore() end
    local w = ctx:get()
    local list = mine(w, "list")
    if not list then return ignore() end -- another mod's list (its own state decides), a stale widget
    local d = drag
    if not d then return ignore() end
    local okO, op, left = pcall(function() return w.DropOp, w.DropLeft end)
    if not (okO and C.valid(op) and op:GetAddress() == d.opAddr) then return ignore() end -- not this state's drag
    local row = C.els[d.rowId]
    if d.listId ~= list.id or left ~= true or not (row and RO.active(list)) then finish(true) return end
    -- the target from where the pointer is now (the loop may be up to 16 ms behind)
    local lw = liveWidget(list)
    local k = d.k
    if lw then
        local at = where(d, lw, lw.Scroll)
        if at then k = at.inside and at.k or nil end
    end
    if k == nil then finish(true) return end -- released outside the list's visible area
    local new = RO.moved(list.children, row, k)
    finish(false)
    S.drops = S.drops + 1
    if new and RO.apply(list, new) then
        if RO.cb.focusRow then pcall(RO.cb.focusRow, row, true, false) end
        RO.fire(list)
    elseif RO.cb.focusRow then pcall(RO.cb.focusRow, row, true, false) end
    if RO.cb.remember then pcall(RO.cb.remember) end
end

-- <Core>_OnDragCancel's post-hook (the row's OnDragCancelled): Escape or a drop nowhere.
local function cancelBody(ctx)
    if C.offGameThread() then return ignore() end
    local w = ctx:get()
    local row = mine(w, "row")
    if not row then return ignore() end
    if not (drag and drag.rowId == row.id) then return ignore() end
    finish(true)
end

local function guarded(body, what)
    return function(ctx)
        C.inDispatch = C.inDispatch + 1 -- cached assets only, no hook registration (story 37's rule)
        local ok, err = pcall(body, ctx)
        C.inDispatch = C.inDispatch - 1
        if not ok then
            S.faults = S.faults + 1
            C.warnOnce("reorder " .. what, "row drag handling failed (%s): %s (further failures not logged)", what, firstLine(err))
        end
    end
end
RO._onDragStart = guarded(dragStartBody, "start")
RO._onDrop = guarded(dropBody, "drop")
RO._onDragCancel = guarded(cancelBody, "cancel")

-- An API change to list (C.listChanged): a drag in it is cancelled first, then a carry or a hold (focus.lua).
function RO.interrupt(list)
    if not list then return end
    if drag and drag.listId == list.id then
        S.interrupts = S.interrupts + 1
        RO.cancel(true)
    end
    if RO.cb.interrupt then RO.cb.interrupt(list) end
end
C.onListChange = RO.interrupt

-- ---------------------------------------------------------------- the UI tick: hooks, flags, warm assets

local function anyReorderable()
    for _, el in ipairs(C.order) do
        if el.kind == "list" and not el.removed and el.reorderable then return el end
    end
    return nil
end
RO._anyReorderable = anyReorderable

-- From the UI poll (never inside a hook), once this state has a reorderable list and the row and list classes are
-- loaded. Each registration once; a failure is one WARN (an old pak: no mouse drag).
local function ensureHooks()
    if S.hooked or X._inHook() then return S.hooked end
    if not (X._classOf("row") and X._classOf("list")) then return false end
    S.hookTries = S.hookTries + 1
    S.hooked = true -- once only (a retry could double a hook)
    local okA, errA = pcall(RegisterHook, C.DRAGSTART_FN, RO._onDragStart)
    local okB, errB = true, nil
    if okA then okB, errB = pcall(RegisterHook, C.DRAGCANCEL_FN, RO._onDragCancel) end
    local okC, errC = pcall(RegisterHook, C.DROP_FN, RO._onDrop)
    S.dragHookOk, S.dropHookOk = okA and okB, okC
    if not (okA and okB and okC) then
        C.warnOnce("reorder hooks", "list rows: RegisterHook for the row drag failed (is %s's pak current?): %s; rows can't be dragged with the mouse",
            C.NAME, firstLine(errA or errB or errC))
    else
        C.log.debug("ui reorder hooks registered on %s, %s, %s", C.DRAGSTART_FN, C.DRAGCANCEL_FN, C.DROP_FN)
    end
    return true
end
RO._ensureHooks = ensureHooks

-- Keeps every row's Blueprint flag Draggable equal to "movable in an active list" (written only when it changes or
-- the widget is new).
local flagsOn = 0 -- rows whose Draggable is true now (the tick keeps syncing while any is)
function RO.sync()
    local n = 0
    for _, el in ipairs(C.order) do
        if el.kind == "list" and not el.removed then
            local on = el.reorderable == true and S.dragHookOk and RO.active(el)
            for _, ch in ipairs(el.children) do
                if ch.kind == "row" and not ch.removed then
                    local want = on and RO.movable(ch) or false
                    if want or ch.dragFlag then
                        local w = liveWidget(ch)
                        if w then
                            local addr = w:GetAddress()
                            if ch.dragFlag ~= want or ch.dragAddr ~= addr then
                                local ok = pcall(function() w.Draggable = want end)
                                if ok then ch.dragFlag, ch.dragAddr = want, addr end
                            end
                        else
                            ch.dragFlag, ch.dragAddr = nil, nil
                        end
                    end
                    if ch.dragFlag then n = n + 1 end
                end
            end
        end
    end
    flagsOn = n
end

-- The lift class, the carried row's instance and core's ModActor kept warm while a reorderable list exists (outside
-- hooks only).
local function warm(list)
    if X._inHook() then return end
    X._classOf("lift")
    cdoOf()
    local w = liveWidget(list)
    if w then pcall(A.carryRowMaterial, w, false) end
end

H._host{ poll = function() end, reset = function() end, dispatch = function()
    local list = anyReorderable()
    if not list and flagsOn == 0 then return nil end
    if list then
        ensureHooks()
        warm(list)
    end
    local ok, err = pcall(RO.sync)
    if not ok then C.warnOnce("reorder sync", "keeping the rows' drag flags failed: %s", firstLine(err)) end
    if list and RO.cb.ensure then pcall(RO.cb.ensure) end
    return nil
end }

function RO.stats()
    local out = {}
    for k, v in pairs(S) do out[k] = v end
    out.dragging = drag ~= nil
    return out
end
RO._S = S
function RO._reset() drag = nil; stopLoop(); cdoRef, cdoMissed = nil, false end -- unit tests
return RO
