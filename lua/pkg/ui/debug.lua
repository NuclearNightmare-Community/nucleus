-- Story 12: overlap diagnostic (debug). Exposed as core.ui.debug on the connect API:
--   overlaps(handle) -> list, info | nil, reason
-- list: every drawn widget whose on-screen rectangle intersects the element's, as { path, class, rect = { l, t, r, b }
-- (screen pixels), element = "<core>:<mod>:<id>" for another Nucleus element (any mod's, this one's other elements
-- too) }; empty when nothing overlaps. info (diagnostic): { checked (widgets visited), drawn (drawn widgets on screen),
-- quadrant (of them in the screen's top-right quarter), fullScreen (overlapping backdrops skipped), errors, capped,
-- roots, via, screen = { w, h }, rect (the element's), nearby (up to 10 drawn widgets within 64 px that don't overlap,
-- same shape as list entries) }. nil plus a reason when it can't check (element hidden or not attached, no live HUD, HUD hidden, not
-- painted yet) or the walk failed (logged once).
--
-- Automatic check: while the dependent's logger has debug on (core.log.debugEnabled), every attach and re-place of an
-- element schedules a check DELAY_TICKS HUD ticks (about 1 s) later, which logs
--   WARN ui overlap '<id>': <widget path> (<class>) <rect>
-- once per element and widget path. With debug off nothing is scheduled, no ticker is registered and no check runs:
-- it costs one boolean read per attach or re-place.
--
-- What is walked (the manual mode's prototype, SkelTest overlapReport, moved here): the live HUD's OwningCanvas and the
-- other top-level viewport widgets (FindAllOf("UserWidget") in the viewport; never GetAllWidgetsOfClass's out array,
-- whose entries point into freed memory: story 17). Collapsed, Hidden and zero-opacity subtrees are pruned; a
-- switcher's active child only. Only widgets that draw something count (an Image or Border with a brush and alpha > 0,
-- non-empty text, buttons, bars, ...); full-screen ones (>= 90% of the screen both ways) are skipped. A Nucleus text
-- widget counts as one unit (its tag names it), never its inner Border/TextBlock. The element's own widget and its
-- subtree are skipped. At most CAP widgets per check. Rectangles come from <Core>_AbsTopLeft / _AbsBottomRight on
-- core's ModActor class default object (Slate's cached geometry: zero until the widget has been painted). Holds no
-- UObject between calls.
local BASE = (...):gsub("%.ui%.debug$", "")
local C = require(BASE .. ".ui.common")
local H = require(BASE .. ".ui.hud")
local J = require(BASE .. ".ui.journal")

local D = {}
D.CAP = 2000                   -- widgets visited per check
D.DELAY_TICKS = 2              -- automatic check: HUD ticks (500 ms each) after an attach or re-place
D.RETRY_TICKS = 2              -- not painted yet: retried this much later ...
D.RETRIES = 3                  -- ... this many times
D.MAX_PAIRS = 4096             -- remembered (element, widget) pairs before the memory is reset
D.FULL = 0.9                   -- a widget at least this share of the screen both ways is a backdrop, not an overlap
D.NEAR_PX = 64                 -- info.nearby: drawn widgets this close (screen pixels) that don't overlap ...
D.NEARBY = 10                  -- ... at most this many
local CDO = "/Game/Mods/" .. C.NAME .. "/ModActor.Default__ModActor_C"
local TAG_PREFIX = C.LOWER .. ":"
-- Widget classes that draw something themselves; containers (CanvasPanel, Overlay, SizeBox, ...) draw nothing.
D.DRAWN = { "Image", "TextBlock", "RichTextBlock", "ProgressBar", "Border", "Button", "CheckBox", "EditableText",
    "EditableTextBox", "MultiLineEditableText", "MultiLineEditableTextBox", "Slider", "SpinBox", "Throbber",
    "CircularThrobber", "ComboBoxString", "ComboBoxKey" }

-- ---------------------------------------------------------------- pure
function D.hasArea(r) return r.r > r.l and r.b > r.t end
function D.intersects(a, b) return math.min(a.r, b.r) > math.max(a.l, b.l) and math.min(a.b, b.b) > math.max(a.t, b.t) end
function D.isFull(r, sw, sh) return r.r - r.l >= D.FULL * sw and r.b - r.t >= D.FULL * sh end
function D.rectStr(r) return string.format("(%.0f,%.0f)-(%.0f,%.0f)", r.l, r.t, r.r, r.b) end

-- Depth-first walk from roots, last pushed first, at most cap visits. visit(x, push) may raise: the error is counted and
-- the walk goes on. Returns visited, whether the cap stopped it, the error count and the first error.
function D.walk(roots, visit, cap)
    local stack = {}
    for i = #roots, 1, -1 do stack[#stack + 1] = roots[i] end
    local function push(x) stack[#stack + 1] = x end
    local visited, errors, firstErr = 0, 0, nil
    while #stack > 0 and visited < cap do
        local x = table.remove(stack)
        visited = visited + 1
        local ok, err = pcall(visit, x, push)
        if not ok then errors = errors + 1; firstErr = firstErr or err end
    end
    return visited, #stack > 0, errors, firstErr
end

-- Sorts hits by area, smallest first (a small widget under the element is the likely collision; large panels last).
function D.sortHits(hits)
    table.sort(hits, function(a, b)
        local aa, ab = (a.rect.r - a.rect.l) * (a.rect.b - a.rect.t), (b.rect.r - b.rect.l) * (b.rect.b - b.rect.t)
        if aa ~= ab then return aa < ab end
        return a.path < b.path
    end)
    return hits
end

-- ---------------------------------------------------------------- engine (call inside one game-thread callback)
local function absRect(cdo, w)
    local tl = cdo[C.NAME .. "_AbsTopLeft"](cdo, w)
    local br = cdo[C.NAME .. "_AbsBottomRight"](cdo, w)
    return { l = tl.X, t = tl.Y, r = br.X, b = br.Y }
end

local function drawsSomething(w, kind)
    local ok, yes = pcall(function()
        if kind == "Border" then return tonumber(w.Background.DrawAs) ~= 0 and w.BrushColor.A > 0 end
        if kind == "Image" then return tonumber(w.Brush.DrawAs) ~= 0 and w.ColorAndOpacity.A > 0 end
        if kind == "TextBlock" then return w:GetText():ToString() ~= "" end
        return true
    end)
    return not ok or yes -- when in doubt, report it
end

local function readTag(w)
    local ok, t = pcall(function() return w.ToolTipText:ToString() end)
    return ok and type(t) == "string" and t or nil
end
-- Panels and buttons (stories 14-15) carry their tag in the Blueprint variable CoreTag (a tooltip would show on hover).
local function readCoreTag(w)
    local ok, t = pcall(function() return w.CoreTag:ToString() end)
    return ok and type(t) == "string" and t or nil
end

-- Top-level viewport widgets other than the HUD, pushed as roots. Returns how many and the method.
-- Map service story 17: no WidgetBlueprintLibrary:GetAllWidgetsOfClass. UE4SS hands its out array back as
-- RemoteUnrealParam entries that point into the call's freed parameter buffer (docs/custom-maps.md, "Story 16"), so
-- reading or unwrapping them reads freed memory. FindAllOf returns the UObjects themselves.
local function topLevel(hudAddr, add)
    local n = 0
    for _, x in ipairs(FindAllOf("UserWidget") or {}) do
        if C.valid(x) and x:IsInViewport() and x:GetAddress() ~= hudAddr then n = n + 1; add(x) end
    end
    return n, "FindAllOf(UserWidget)"
end

-- The check for one widget w on the live HUD hud. Returns hits, info or nil, reason. Raises only on a broken engine
-- call outside the per-widget walk (callers pcall). journal: the open Journal instead of a HUD (story 13); then only
-- the Journal is walked (it covers the screen, so the HUD and other top-level widgets under it don't count), and the
-- screen is the Journal's own rectangle.
function D._check(hud, w, journal)
    C.stats.overlapChecks = (C.stats.overlapChecks or 0) + 1
    local cdo = C.found(CDO)
    if not cdo then return nil, "core's ModActor is not loaded" end
    local canvas = journal or hud.OwningCanvas
    if not C.valid(canvas) then return nil, journal and "the Journal is gone" or "the HUD has no OwningCanvas" end
    local mine = absRect(cdo, w)
    if not D.hasArea(mine) then return nil, "not painted yet (no on-screen geometry)" end
    local screen = absRect(cdo, canvas)
    local sw, sh = screen.r - screen.l, screen.b - screen.t
    if sw <= 0 or sh <= 0 then return nil, journal and "not painted yet (the Journal has no on-screen geometry)" or "not painted yet (the HUD canvas has no on-screen geometry)" end

    local classes = {}
    for _, n in ipairs(D.DRAWN) do
        local c = C.found("/Script/UMG." .. n)
        if c then classes[#classes + 1] = { name = n, cls = c } end
    end
    local UW, PANEL, SWITCH = C.found("/Script/UMG.UserWidget"), C.found("/Script/UMG.PanelWidget"), C.found("/Script/UMG.WidgetSwitcher")
    local ownAddr = w:GetAddress()

    local roots = { canvas }
    local tops, via = 0, "none"
    if UW and not journal then
        local okT, n, how = pcall(topLevel, hud:GetAddress(), function(x) roots[#roots + 1] = x end)
        if okT then tops, via = n, how end
    end

    local seen, hits, nearby = {}, {}, {}
    local drawn, quadrant, full = 0, 0, 0
    local topRight = { l = screen.l + sw / 2, t = screen.t, r = screen.r, b = screen.t + sh / 2 }
    -- Context, not overlaps: drawn widgets within NEAR_PX of the element (a near miss at another resolution).
    local near = { l = mine.l - D.NEAR_PX, t = mine.t - D.NEAR_PX, r = mine.r + D.NEAR_PX, b = mine.b + D.NEAR_PX }
    local function visit(x, push)
        if not C.valid(x) then return end
        local addr = x:GetAddress()
        if seen[addr] or addr == ownAddr then return end -- the element itself and everything inside it are skipped
        seen[addr] = true
        local vis = tonumber(x:GetVisibility())
        if vis == 1 or vis == 2 or x:GetRenderOpacity() <= 0 then return end -- not drawn, nor anything inside
        local clsName = x:GetClass():GetFName():ToString()
        local tag = (clsName == C.TEXT_SHORT and readTag(x)) or ((clsName == C.PANEL_SHORT or clsName == C.BUTTON_SHORT or clsName == C.CHOICE_SHORT or clsName == C.SLIDER_SHORT or clsName == C.TEXTBOX_SHORT) and readCoreTag(x)) or nil
        local element = tag and tag:sub(1, #TAG_PREFIX) == TAG_PREFIX and tag or nil
        local kind = element and "element" or nil
        if not kind then
            for _, c in ipairs(classes) do if x:IsA(c.cls) then kind = c.name break end end
        end
        if kind and (element or drawsSomething(x, kind)) then
            local r = absRect(cdo, x)
            if D.hasArea(r) then
                drawn = drawn + 1
                if D.intersects(r, topRight) then quadrant = quadrant + 1 end
                if D.intersects(r, mine) then
                    if D.isFull(r, sw, sh) then full = full + 1
                    else hits[#hits + 1] = { path = C.pathOf(x), class = clsName, rect = r, element = element } end
                elseif #nearby < D.NEARBY and D.intersects(r, near) and not D.isFull(r, sw, sh) then
                    nearby[#nearby + 1] = { path = C.pathOf(x), class = clsName, rect = r, element = element }
                end
            end
        end
        if element then return end -- another Nucleus element is one unit (a panel with everything in it, too)
        if UW and x:IsA(UW) then
            local tree = x.WidgetTree
            if C.valid(tree) then push(tree.RootWidget) end
        elseif SWITCH and x:IsA(SWITCH) then
            push(x:GetActiveWidget())
        elseif PANEL and x:IsA(PANEL) then
            for i = x:GetChildrenCount() - 1, 0, -1 do push(x:GetChildAt(i)) end
        end
    end
    local visited, capped, errors, firstErr = D.walk(roots, visit, D.CAP)
    if errors > 0 then C.warnOnce("overlap visit", "ui overlap: %d widget(s) could not be checked, first: %s (further failures not logged)", errors, tostring(firstErr):match("^[^\n]*")) end
    return D.sortHits(hits), { checked = visited, drawn = drawn, quadrant = quadrant, fullScreen = full, errors = errors,
        capped = capped, roots = 1 + tops, via = via, screen = { w = sw, h = sh }, rect = mine, nearby = D.sortHits(nearby) }
end

-- The check for an element, or nil and why not.
local function checkElement(el)
    if el.removed then return nil, "the element was removed" end
    if el.panel then return nil, "the element is inside panel '" .. el.panel.id .. "' (check the panel)" end
    if not el.visible then return nil, "the element is hidden (setVisible false)" end
    if el.nearAbsent then return nil, "the element is collapsed (its near target or journal region is not drawn)" end
    local w = el.ref and C.deref(el.ref)
    if el.place.host == "journal" then
        if not w then return nil, "the element is not attached (the Journal is closed)" end
        local j = J._poll()
        if not j then return nil, "the Journal is not open" end
        if not J._mapPageActive(j) then return nil, "the Journal is not on its map page" end
        local canvas = J._canvasOf(j)
        local okP, p = pcall(function() return w:GetParent() end)
        if not (okP and C.valid(p) and canvas and p:GetAddress() == canvas:GetAddress()) then return nil, "the element is not in the open Journal's map page" end
        return D._check(nil, w, j)
    end
    if not w then return nil, "the element is not attached to a HUD" end
    local hud, _, vis = H._poll()
    if not hud then return nil, "no live HUD" end
    if not C.drawn(vis) then return nil, "the HUD is hidden" end
    local okP, p = pcall(function() return w:GetParent() end)
    local canvas = hud.OwningCanvas
    if not (okP and C.valid(p) and C.valid(canvas) and p:GetAddress() == canvas:GetAddress()) then return nil, "the element is not in the live HUD canvas" end
    return D._check(hud, w)
end

-- Runs a check under pcall: a failure logs once and returns nil, reason; it never touches the element.
local function guarded(el)
    local r = table.pack(pcall(checkElement, el))
    if r[1] then return r[2], r[3] end
    local msg = tostring(r[2]):match("^[^\n]*")
    C.warnOnce("overlap", "ui overlap check failed: %s (further failures not logged)", msg)
    return nil, "the check failed: " .. msg
end

-- ---------------------------------------------------------------- automatic check (debug only)
local pending = {}               -- element -> { at = tick, why = string, tries = n }
local warnedPairs, nPairs = {}, 0
local dtick = 0
local ticking = false

local function onTick()
    dtick = dtick + 1
    if next(pending) == nil then return end
    -- Removed elements (no longer in C.order) are dropped; the rest go in creation order (deterministic, unlike
    -- pairs over table keys).
    for el in pairs(pending) do if el.removed then pending[el] = nil end end
    -- One check per tick at most: a check is a walk of tens to hundreds of widgets (milliseconds).
    for _, el in ipairs(C.order) do
        local p = pending[el]
        if p and dtick >= p.at then
            pending[el] = nil
            if not C.debugOn() then return end
            C.tickEvent = "overlap check" -- an event tick for the timing summary, not a steady one
            local hits, info = guarded(el)
            if hits == nil then
                if tostring(info):find("not painted", 1, true) and p.tries < D.RETRIES then
                    pending[el] = { at = dtick + D.RETRY_TICKS, why = p.why, tries = p.tries + 1 }
                else
                    C.log.debug("ui overlap '%s' not checked (%s): %s", el.id, p.why, tostring(info))
                end
                return
            end
            local new = 0
            for _, h in ipairs(hits) do
                local key = el.id .. "|" .. h.path
                if not warnedPairs[key] then
                    if nPairs >= D.MAX_PAIRS then warnedPairs, nPairs = {}, 0 end
                    warnedPairs[key], nPairs = true, nPairs + 1
                    new = new + 1
                    C.log.warn("ui overlap '%s': %s (%s) %s", el.id, h.path, h.class, D.rectStr(h.rect))
                end
            end
            C.log.debug("ui overlap '%s' checked (%s): %d overlap(s), %d new; %d widgets visited, %d drawn, screen %.0fx%.0f%s",
                el.id, p.why, #hits, new, info.checked, info.drawn, info.screen.w, info.screen.h, info.capped and ", capped" or "")
            return
        end
    end
end

-- Schedules the automatic check for one element (text.lua, on attach and re-place). Does nothing with debug off.
-- HUD elements only: a Journal is open for seconds and is a new one each time, so its elements are checked on demand
-- (overlaps(handle)) and never automatically.
function D.schedule(el, why)
    if not C.debugOn() or el == nil or el.removed or el.place.host ~= "hud" then return end
    if not ticking then
        ticking = true
        H._ticker(function() local ok, err = pcall(onTick) if not ok then C.warnOnce("overlap tick", "ui overlap tick failed: %s", tostring(err):match("^[^\n]*")) end end)
    end
    C.stats.overlapScheduled = (C.stats.overlapScheduled or 0) + 1
    local p = pending[el]
    if p then p.at, p.tries = dtick + D.DELAY_TICKS, 0 return end
    pending[el] = { at = dtick + D.DELAY_TICKS, why = why or "?", tries = 0 }
end

-- ---------------------------------------------------------------- public

function D.overlaps(h, ...)
    C.enter("debug.overlaps")
    local el = C.element(h, "debug.overlaps")
    if select("#", ...) > 0 then C.fail("%s.debug.overlaps: expected 1 argument (handle), got %d", C.UI, 1 + select("#", ...)) end
    return guarded(el)
end

-- For tests: the automatic check's state.
function D._state() return { pending = pending, warnedPairs = warnedPairs, tick = dtick, ticking = ticking } end
return D
