-- UI-2 (story 8) and UI-4 (story 10): text elements on the HUD, kept there through every HUD rebuild. Also the element
-- engine every kind shares: panels (story 14, panel.lua) and buttons (story 15, button.lua) attach, re-attach, place and
-- remove through the functions here.
-- Exposed as core.ui.text on the connect API:
--   create{ id = <string>, text = <string|number|nil>, place = <intent|nil>, style = <style|nil> } -> handle
--   set(handle, text)            setStyle(handle, style)        setVisible(handle, visible)
--   remove(handle)               isShown(handle) -> boolean     stats() -> table (diagnostic copy, not semver API)
-- and core.ui.place(handle, intent) (UI-3, place.lua; any kind).
--
-- Elements are plain Lua state per mod: kind, id, text, intent, resolved style, the caller's visibility wish, and the
-- live widget's weak handle and path. Never a UObject. A text widget is WBP_<Core>Text (Border "Background" -> TextBlock
-- "Text"), tagged with ToolTipText "<core>:<mod>:<id>" and SelfHitTestInvisible, so it can be found again after a HUD
-- rebuild or a hot reload without relying on its text. Panels and buttons carry the same tag in a Blueprint string
-- variable (CoreTag, set with SetTag): a tooltip on them would show while the cursor is over a button. A UI-1 watcher
-- re-attaches every element on each `attached` event; on `lost` it only frees handles whose widget is gone.
--
-- Story 13: elements with place.host = "journal" live on the Journal's map page (journal.lua). Every map open is a new
-- Journal_C, so a journal watcher creates their widgets again on every `opened` (no scan for reuse unless the same
-- Journal comes back), and on `closed` / `lost` frees their handles without touching any widget: no reference to an
-- old Journal or its widgets is kept. They keep their state meanwhile, and isShown is false. Each open's attach is
-- timed per step (canvas lookup, each element, placement; story 14).
--
-- Story 14: a panel's children (el.panel set, no host of their own) live in the panel widget's box. The panel attaches
-- them after itself, in its order, and the per-host loops (attach on a host event, placement, ticks) skip them.
local BASE = (...):gsub("%.ui%.text$", "")
local C = require(BASE .. ".ui.common")
local H = require(BASE .. ".ui.hud")
local J = require(BASE .. ".ui.journal")
local P = require(BASE .. ".ui.place")
local theme = require(BASE .. ".ui.theme")
local D = require(BASE .. ".ui.debug")

local X = {}

-- The hosts an element can sit on: poll() -> host object (valid only in this callback) and whether its elements can
-- be drawn now; canvas(obj) -> the canvas elements go into, or nil.
local HOST = {
    hud = {
        poll = function() local hud, _, vis = H._poll() return hud, hud ~= nil and C.drawn(vis) end,
        canvas = function(hud)
            local ok, c = pcall(function() return hud.OwningCanvas end)
            return ok and C.valid(c) and c or nil
        end,
    },
    journal = {
        poll = function() local j = J._poll() return j, j ~= nil and J._mapPageActive(j) end,
        canvas = function(j) return J._canvasOf(j) end,
    },
}
local MAX_ID = 64
local MAX_TEXT = 256
local MAX_CHILDREN = 32          -- story 14: children per panel
local RETRY_TICKS = 10           -- a failed attach is retried every 10 ticks (5 s), not every tick
local TAG_PREFIX = C.LOWER .. ":" -- full tag: <core>:<modTag>:<id>

local tick = 0
local watching = false
local attachedThisTick = false  -- set by the attached watcher, read by the same tick's onTick
local pendingLog = nil           -- the attach line of the last attached event, logged on the next tick
local pendingDebug = false       -- whether pendingLog is the DEBUG report (all attached) or the INFO one (some failed)
local function flushLog()
    if not pendingLog then return end
    local t = C.pt()
    if pendingDebug then C.log.debug("%s", pendingLog) else C.log.info("%s", pendingLog) end
    C.pa("core.log", t)
    pendingLog = nil
end

-- ---------------------------------------------------------------- kinds
-- Per kind: the widget class, where its tag lives, and how its content and style reach a widget. A fresh widget shows
-- the generator's defaults, so a call that would only restate them is skipped (attach cost per Journal open, story 13).
local function sameStyle(a, b) return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a and a.pad == b.pad end
local function warnFirst(key, fmt, err, ...) C.warnOnce(key, fmt, ..., tostring(err):match("^[^\n]*")) end

local function backgroundStyle(el, w, fresh)
    local s = el.style
    if fresh and s.a == 0 and s.pad == 0 then return end -- the unstyled widget already looks like this
    local ok, err = pcall(function()
        C.count(); w:SetBackground(s.r, s.g, s.b, s.a)
        C.count(); w:SetBackgroundPadding(s.pad)
    end)
    if not ok then warnFirst("style:" .. el.id, "%s '%s': style not applied (is %s's pak current?): %s", err, el.kind, el.id, C.NAME) end
end

local KIND = {
    text = {
        pkg = C.TEXT_PKG, short = C.TEXT_SHORT, cls = C.TEXT_CLASS, toolTipTag = true,
        content = function(el, w, fresh)
            if fresh and el.text == "" then return end
            C.count(); w:SetText(el.text)
        end,
        style = backgroundStyle,
    },
    panel = {
        pkg = C.PANEL_PKG, short = C.PANEL_SHORT, cls = C.PANEL_CLASS,
        content = function() end,
        style = backgroundStyle,
    },
}
X.KIND = KIND -- button.lua adds the button kind

local function kindOfClass(short)
    for k, K in pairs(KIND) do if K.short == short then return k end end
    return nil
end

-- ---------------------------------------------------------------- validation (pure)

local function validId(id, fn)
    if type(id) ~= "string" then C.fail("%s.%s: id must be a string, got %s", C.UI, fn, C.describe(id)) end
    if id == "" then C.fail("%s.%s: id must not be empty", C.UI, fn) end
    if #id > MAX_ID then C.fail("%s.%s: id is %d characters, at most %d", C.UI, fn, #id, MAX_ID) end
    if not id:match("^[A-Za-z0-9_%.%-]+$") then
        C.fail("%s.%s: id %s has characters outside A-Z a-z 0-9 _ . -", C.UI, fn, C.describe(id))
    end
    return id
end

-- Text to show: strings and numbers (tostring); nil is "". Returns the text and whether it was cut.
local function cut(s)
    if #s <= MAX_TEXT then return s, false end
    local okL, n = pcall(utf8.len, s)
    if okL and n then
        if n <= MAX_TEXT then return s, false end
        return s:sub(1, utf8.offset(s, MAX_TEXT + 1) - 1), true
    end
    return s:sub(1, MAX_TEXT), true -- not valid UTF-8: bytes
end
local function validText(text, fn)
    local t = type(text)
    if text == nil then return "", false end
    if t == "string" then return cut(text) end
    if t == "number" then return cut(tostring(text)) end
    C.fail("%s.%s: text must be a string, a number or nil, got %s", C.UI, fn, t)
end

local function unit(v, what, pre)
    if type(v) ~= "number" or v ~= v or v < 0 or v > 1 then
        C.fail("%s: background.%s must be a number from 0 to 1, got %s", pre, what, C.describe(v))
    end
    return v + 0.0
end

-- Resolves a style to { r, g, b, a, pad } (colour 0..1, padding in canvas units). kind (default "text") picks the
-- error prefix and the defaults: text has no box, a panel is dim with normal padding (story 14), a button is the
-- theme's face with its hover and pressed colours (story 15).
function X.resolveStyle(style, kind)
    kind = kind or "text"
    local pre = C.UI .. "." .. kind
    if style == nil then
        if kind == "text" then return { r = 0, g = 0, b = 0, a = 0, pad = 0 } end
        if kind == "panel" then style = theme.panelDefault else style = {} end
    end
    if type(style) ~= "table" then C.fail("%s: style must be a table { background = ..., padding = ... }, got %s", pre, C.describe(style)) end
    for k in pairs(style) do
        if k ~= "background" and k ~= "padding" then C.fail("%s: unknown style key %s (valid: background, padding)", pre, C.describe(k)) end
    end
    local bg, col = style.background, nil
    if bg == nil then bg = kind == "button" and theme.button or "none" end
    if type(bg) == "string" then
        local p = theme.background[bg]
        if not p then C.fail("%s: unknown background %s (valid: %s, or { r = 0..1, g = 0..1, b = 0..1, a = 0..1 })", pre, C.describe(bg), table.concat(theme.backgroundNames, ", ")) end
        col = { r = p.r, g = p.g, b = p.b, a = p.a }
    elseif type(bg) == "table" then
        for k in pairs(bg) do
            if k ~= "r" and k ~= "g" and k ~= "b" and k ~= "a" then C.fail("%s: unknown background key %s (valid: r, g, b, a)", pre, C.describe(k)) end
        end
        col = { r = unit(bg.r, "r", pre), g = unit(bg.g, "g", pre), b = unit(bg.b, "b", pre), a = bg.a == nil and 1.0 or unit(bg.a, "a", pre) }
    else
        C.fail("%s: background must be a preset name or a colour table, got %s", pre, C.describe(bg))
    end
    local pad = style.padding
    if pad == nil then
        if kind == "button" then pad = theme.buttonPadding
        else pad = (col.a > 0) and theme.paddingWithBackground or "none" end
    end
    if type(pad) ~= "string" or theme.padding[pad] == nil then
        C.fail("%s: unknown padding %s (valid: %s)", pre, C.describe(pad), table.concat(theme.paddingNames, ", "))
    end
    col.pad = theme.padding[pad]
    if kind == "button" then
        local h, q = theme.buttonHover, theme.buttonPressed
        col.hover = { r = h.r, g = h.g, b = h.b, a = h.a }
        col.pressed = { r = q.r, g = q.g, b = q.b, a = q.a }
    end
    return col
end

-- ---------------------------------------------------------------- handles

local function newHandle(id, kind)
    return setmetatable({}, {
        __index = { id = id },
        __newindex = function() error(C.UI .. "." .. kind .. ": element handles are read-only", 2) end,
        __metatable = "element handle",
        __tostring = function() return (kind == "text" and "element '" or (kind .. " '")) .. id .. "'" end,
    })
end

-- ---------------------------------------------------------------- widget helpers (game thread)

local function tagOf(id) return TAG_PREFIX .. C.modTag .. ":" .. id end

-- The widget class of a kind, kept as a weak handle between ticks. Never StaticFindObject(<class path>): when the class
-- isn't loaded that misses, and a miss in the pinned UE4SS scans every object (4-5 ms per call on V8.1.2, twice per HUD
-- event with two elements). GetAsset returns the loaded class at once and loads it otherwise.
local classRefs = {}
local function classOf(kind)
    local K = KIND[kind]
    local r = classRefs[kind]
    if r then
        local okD, cls = pcall(C.deref, r)
        if okD and cls then return cls end
        pcall(C.free, r)
        classRefs[kind] = nil
    end
    local t = C.pt()
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    local ok, got = pcall(function()
        return helpers:GetAsset({ PackageName = FName(K.pkg), AssetName = FName(K.short) })
    end)
    C.pa("class.load", t)
    if not (ok and C.valid(got)) then return nil end
    local okR, h = pcall(C.ref, got)
    if okR then classRefs[kind] = h end
    return got
end
X._classOf = classOf

-- live(el) -> the element's widget when it sits in this container (a host canvas, or a panel's box), else nil.
local function liveIn(container)
    local caddr = container:GetAddress()
    return function(el)
        if not el.ref then return nil end
        local w = C.deref(el.ref)
        if not w then return nil end
        local okP, p = pcall(function() return w:GetParent() end)
        if okP and C.valid(p) and p:GetAddress() == caddr then return w end
        return nil
    end
end

-- The tag a widget of one of our kinds carries, or nil.
local function readTag(w, kind)
    local ok, t
    if KIND[kind].toolTipTag then ok, t = pcall(function() return w.ToolTipText:ToString() end)
    else ok, t = pcall(function() return w.CoreTag:ToString() end) end
    return ok and type(t) == "string" and t or nil
end
X._readTag = readTag

-- Our widgets among a container's direct children: byId[id] = { widgets in child order }, orphans = { widget, id }.
-- belongs(el): whether an element's widget belongs in this container; a tagged widget of any other element (one of
-- this mod's that is now elsewhere, or that it no longer has) is an orphan here.
local function scan(container, belongs)
    local byId, orphans = {}, {}
    local mine = TAG_PREFIX .. C.modTag .. ":"
    local n = container:GetChildrenCount()
    for i = 0, n - 1 do
        local c = container:GetChildAt(i)
        if C.valid(c) then
            local okC, cls = pcall(function() return c:GetClass():GetFName():ToString() end)
            local kind = okC and kindOfClass(cls) or nil
            if kind then
                local tag = readTag(c, kind)
                if tag and tag:sub(1, #mine) == mine then
                    local id = tag:sub(#mine + 1)
                    local el = C.els[id]
                    if el and not el.removed and el.kind == kind and belongs(el) then
                        byId[id] = byId[id] or {}
                        table.insert(byId[id], c)
                    else
                        orphans[#orphans + 1] = { w = c, id = id }
                    end
                end
            end
        end
    end
    return byId, orphans
end
local function onHost(host) return function(el) return el.panel == nil and el.place.host == host end end
local function inPanel(p) return function(el) return el.panel == p end end

local function setTag(w, el)
    local tag = tagOf(el.id)
    local ok
    if KIND[el.kind].toolTipTag then
        ok = pcall(function() C.count(); w:SetToolTipText(FText(tag)) end)
        if not ok then ok = pcall(function() C.count(); w.ToolTipText = FText(tag) end) end
    else
        ok = pcall(function() C.count(); w:SetTag(tag) end)
    end
    if not ok then C.warnOnce("tag:" .. el.id, "%s '%s': could not set its tag; it may be duplicated after a HUD rebuild", el.kind, el.id) end
end

local function freeRef(el)
    if el.ref then
        pcall(C.free, el.ref)
        C.stats.handlesFreed = C.stats.handlesFreed + 1
    end
    el.ref, el.path = nil, nil
end

local function removeWidget(w)
    pcall(function() C.count(); w:RemoveFromParent() end)
end

local function liveWidget(el) return el.ref and C.deref(el.ref) or nil end

-- ---------------------------------------------------------------- panels: the box and its children (story 14)

-- The box a panel's children go into (VBox or HBox of WBP_<Core>Panel), and the other one.
local function boxOf(p, w, other)
    local horiz = p.layout == "horizontal"
    if other then horiz = not horiz end
    local ok, b = pcall(function() if horiz then return w.HBox end return w.VBox end)
    return ok and C.valid(b) and b or nil
end
X._boxOf = boxOf

-- Box slot paddings: the first visible child 0, every later visible one the panel's gap before it (top in a vertical
-- panel, left in a horizontal one). Hidden children are collapsed: the box skips them and their padding.
local function applyGaps(p)
    local first = true
    local horiz = p.layout == "horizontal"
    for _, ch in ipairs(p.children) do
        if not ch.removed and ch.visible then
            local w = liveWidget(ch)
            if w then
                local pad = first and 0 or p.gapUnits
                first = false
                local key = tostring(pad)
                if ch.padKey ~= key then
                    local ok, err = pcall(function()
                        C.count()
                        w.Slot:SetPadding(horiz and { Left = pad, Top = 0, Right = 0, Bottom = 0 } or { Left = 0, Top = pad, Right = 0, Bottom = 0 })
                    end)
                    if ok then ch.padKey = key else warnFirst("gap:" .. p.id, "panel '%s': setting a child's gap failed: %s", err, p.id) end
                end
            end
        end
    end
end

-- Puts the panel's live child widgets into box in the panel's order: every one is taken out and added back (box
-- panels only append; InsertChildAt isn't reflected). The same widgets: none is created or destroyed.
local function rebuildBox(p, box)
    local ws = {}
    for _, ch in ipairs(p.children) do
        local w = not ch.removed and liveWidget(ch)
        if w then ws[#ws + 1] = w end
    end
    for _, w in ipairs(ws) do removeWidget(w) end
    for _, w in ipairs(ws) do
        local ok, err = pcall(function() C.count(); box:AddChild(w) end)
        if not ok then warnFirst("rebuild:" .. p.id, "panel '%s': putting a child back failed: %s", err, p.id) end
    end
    for _, ch in ipairs(p.children) do ch.padKey = "0" end -- new slots
    C.stats.panelRebuilds = (C.stats.panelRebuilds or 0) + 1
    applyGaps(p)
end
X._rebuildBox = rebuildBox

-- Whether the box already holds the panel's live children in its order; rebuilds it when not.
local function ensureOrder(p, box)
    local want = {}
    for _, ch in ipairs(p.children) do
        local w = not ch.removed and liveWidget(ch)
        if w then want[#want + 1] = w:GetAddress() end
    end
    local n = box:GetChildrenCount()
    local same = n == #want
    if same then
        for i = 1, n do
            local c = box:GetChildAt(i - 1)
            if not (C.valid(c) and c:GetAddress() == want[i]) then same = false break end
        end
    end
    if not same then rebuildBox(p, box) end
    return not same
end

-- A child that should be attached but whose widget is gone (Deref only).
local function childMissing(p)
    for _, ch in ipairs(p.children) do
        if not ch.removed and (ch.retryAt == nil or tick >= ch.retryAt) and not liveWidget(ch) then return true end
    end
    return false
end

-- ---------------------------------------------------------------- attach (UI-2) and re-attach (UI-4)

local attachChildren -- below

-- Puts one element's widget into its container (a host canvas, or its panel's box; hostObj: the live HUD or Journal):
-- reuses the element's own widget or one tagged with its id, else creates one. Then re-applies content and style;
-- placement and visibility follow in placeAll (children: in attachChildren). A panel then attaches its children.
-- steps (optional): per-element timing { id, us, create, panel } appended after each element. Raises on failure
-- (callers pcall).
local function attachOne(el, hostObj, container, byId, reason, report, steps)
    local tStep = steps and C.micros()
    local tCreate = 0
    local t = C.pt()
    local live = liveIn(container)
    local w = live(el)
    local tagged = byId[el.id] or {}
    local how = "reused"
    if not w and #tagged > 0 then w = tagged[1] end
    -- Never two: keep the one in use (or the first tagged one) and remove the rest.
    local extra = 0
    if w then
        local keep = w:GetAddress()
        for _, d in ipairs(tagged) do
            if d:GetAddress() ~= keep then removeWidget(d); extra = extra + 1 end
        end
    end
    C.pa("attach.find", t)
    if extra > 0 then
        C.log.warn("%s '%s': removed %d duplicate widget(s) from the %s", el.kind, el.id, extra,
            el.panel and ("panel '" .. el.panel.id .. "'") or (el.place.host .. " canvas"))
    end
    byId[el.id] = nil
    local fresh = false
    if not w then
        local tc = steps and C.micros()
        t = C.pt()
        local cls = classOf(el.kind)
        C.pa("attach.class", t)
        if not cls then
            C.warnOnce("pak:" .. el.id, "%s '%s' stays pending: %s is not loaded (is Content/Paks/LogicMods/%s.pak installed?)", el.kind, el.id, KIND[el.kind].cls, C.NAME)
            return false
        end
        t = C.pt()
        local owner
        local okO, o = pcall(function() return hostObj:GetOwningPlayer() end)
        if okO and C.valid(o) then owner = o end
        local world = hostObj:GetWorld()
        if not owner then
            local okP, pc = pcall(function() return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(world, 0) end)
            if okP and C.valid(pc) then owner = pc end
        end
        C.pa("attach.owner", t)
        if not owner then return false end -- between worlds; the next host event tries again
        C.count()
        t = C.pt()
        w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(world, cls, owner)
        C.pa("attach.create", t)
        if not C.valid(w) then error("creating " .. KIND[el.kind].short .. " failed") end
        if steps then tCreate = C.micros() - tc end
        t = C.pt()
        setTag(w, el)
        C.pa("attach.tag", t)
        el.appliedVis = nil
        t = C.pt()
        P.applyVisibility(el, w) -- before it joins the container, so a hidden element never flashes
        C.pa("attach.vis", t)
        t = C.pt()
        if el.panel then C.count(); container:AddChild(w) else C.count(); container:AddChildToCanvas(w) end
        C.pa("attach.add", t)
        how, fresh = "created", true
        C.stats.attachCreated = C.stats.attachCreated + 1
    else
        C.stats.attachReused = C.stats.attachReused + 1
    end
    el.lastHow = how
    t = C.pt()
    KIND[el.kind].content(el, w, fresh)
    C.pa("attach.text", t)
    t = C.pt()
    KIND[el.kind].style(el, w, fresh)
    C.pa("attach.style", t)
    t = C.pt()
    local path = C.pathOf(w)
    if path ~= el.path or not el.ref then
        if el.ref then C.log.debug("ui '%s': new widget %s; freed the handle %s of the old one (%s)", el.id, path, tostring(el.ref), tostring(el.path)) end
        freeRef(el)
        el.ref, el.path = C.ref(w), path
    end
    C.pa("attach.ref", t)
    el.attached, el.slotKey, el.retryAt = true, nil, nil
    -- A fresh widget got its visibility before it joined; a reused one gets it again (placeAll, attachChildren).
    if not fresh then el.appliedVis = nil end
    if el.panel then el.padKey = fresh and "0" or nil end
    if el.kind == "panel" then attachChildren(el, w, hostObj, fresh, reason, report, steps) end
    if C.debugOn() and not el.panel then D.schedule(el, "attach") end -- story 12: overlap check about 1 s later (debug only, HUD only)
    -- DEBUG only: a log line costs 0.3-0.8 ms on the game thread, and a successful attach is routine. Failures keep
    -- their INFO/WARN lines (onHud, warnOnce).
    if report then
        if report.build then report[#report + 1] = string.format("'%s' %s %s", el.id, how, path) end
    elseif C.debugOn() then
        t = C.pt()
        C.log.debug("ui attach '%s' %s %s (%s)", el.id, how, path, reason)
        C.pa("attach.log", t)
    end
    if steps then steps[#steps + 1] = { id = el.id, us = C.micros() - tStep, create = tCreate, panel = el.panel and el.panel.id or nil } end
    return true
end

-- A panel's children, into its box in the panel's order, after the panel itself (story 14). A fresh panel holds
-- nothing yet, so its box is not scanned and its order is right by construction; a reused one is scanned for our tags
-- (duplicates and orphans go) and its order checked.
attachChildren = function(p, pw, hostObj, fresh, reason, report, steps)
    local box = boxOf(p, pw)
    if not box then
        C.warnOnce("nobox:" .. p.id, "panel '%s': its widget has no %s; its children stay pending (is %s's pak current?)", p.id, p.layout == "horizontal" and "HBox" or "VBox", C.NAME)
        return
    end
    local byId = {}
    if not fresh then
        local okS, b, orphans = pcall(scan, box, inPanel(p))
        if okS then
            byId = b
            for _, o in ipairs(orphans) do removeWidget(o.w) end
        end
        -- After a layout change our widgets may still sit in the other box: they move to this one.
        local other = boxOf(p, pw, true)
        if other and other:GetChildrenCount() > 0 then
            local okO, bo = pcall(scan, other, inPanel(p))
            if okO then
                for _, list in pairs(bo) do for _, w in ipairs(list) do removeWidget(w) end end
            end
        end
    end
    local anyReused = false
    for _, ch in ipairs(p.children) do
        if not ch.removed then
            local ok, res = pcall(attachOne, ch, hostObj, box, byId, reason, report, steps)
            if not ok or not res then
                ch.attached, ch.retryAt = false, tick + RETRY_TICKS
                if not ok then C.warnOnce("attach:" .. ch.id, "attach %s: %s", ch.id, tostring(res):match("^[^\n]*")) end
            elseif ch.lastHow == "reused" then
                anyReused = true
            end
        end
    end
    if anyReused then ensureOrder(p, box) end
    applyGaps(p)
    for _, ch in ipairs(p.children) do
        local w = not ch.removed and liveWidget(ch)
        if w then pcall(P.applyVisibility, ch, w) end
    end
end

-- The journal context (story 19 regions) for one call on a host, or nil on the HUD.
local function ctxFor(host, obj, canvas) return host == "journal" and P.journalCtx(obj, canvas) or nil end

-- Places every live element of one host: each corner stack (story 19: per region) re-stacks once, near and absolute
-- elements on their own. Journal regions are read at most once (one context).
local function placeAll(host, hostObj, canvas, prepass)
    local live = liveIn(canvas)
    local ctx = ctxFor(host, hostObj, canvas)
    local stacks = {}
    for _, el in ipairs(C.order) do
        if not el.removed and el.place.host == host then
            local w = live(el)
            if w then
                if el.place.corner then stacks[P.skeyOf(el.place.corner, el.place.region)] = el.place
                else
                    local ok, err = pcall(P.apply, el, w, hostObj, live, prepass, ctx)
                    if not ok then C.warnOnce("place:" .. el.id, "place '%s' failed: %s", el.id, tostring(err):match("^[^\n]*")) end
                end
            end
        end
    end
    for k, pl in pairs(stacks) do
        local ok, err = pcall(P.restack, host, pl.corner, live, prepass, pl.region, ctx)
        if not ok then C.warnOnce("stack:" .. host .. k, "stacking %s %s failed: %s", host, k, tostring(err):match("^[^\n]*")) end
    end
end

-- Can a size change of this element move another one? Only when a later visible element shares its corner stack
-- (same host, corner and region; the last element's height moves nothing). Near and absolute positions don't depend
-- on the element's own size. A panel's child moves what its panel moves.
local function sizeMatters(el)
    if el.panel then return el.visible and sizeMatters(el.panel) end
    local corner = el.place.corner
    if not corner or not el.visible then return false end
    local after = false
    for _, e in ipairs(C.order) do
        if e == el then after = true
        elseif after and not e.removed and e.visible and e.place.corner == corner and e.place.host == el.place.host
            and e.place.region == el.place.region then return true end
    end
    return false
end

-- Story 12 (debug only): an element's re-place also moves the rest of its corner stack; check them all.
local function checkCorner(host, corner, why, region)
    if not C.debugOn() then return end
    for _, e in ipairs(C.order) do
        if not e.removed and e.place.corner == corner and e.place.host == host and e.place.region == region then D.schedule(e, why) end
    end
end

-- The live object and canvas of a host, or nil.
local function liveHost(host)
    local A = HOST[host]
    local obj = A.poll()
    if not obj then return nil end
    local canvas = A.canvas(obj)
    if not canvas then return nil end
    return obj, canvas
end

-- Re-places what one element's change can move: its corner's stack, or the element alone (a child: its panel).
local function replace(el)
    if el.panel then return replace(el.panel) end
    local host = el.place.host
    local obj, canvas = liveHost(host)
    if not obj then return end
    local live = liveIn(canvas)
    local w = live(el)
    local ctx = ctxFor(host, obj, canvas)
    if el.place.corner then
        pcall(P.restack, host, el.place.corner, live, true, el.place.region, ctx)
        checkCorner(host, el.place.corner, "re-stack", el.place.region)
    elseif w then
        local ok, err = pcall(P.apply, el, w, obj, live, true, ctx)
        if not ok then C.warnOnce("place:" .. el.id, "place '%s' failed: %s", el.id, tostring(err):match("^[^\n]*")) end
        if C.debugOn() then D.schedule(el, "re-place") end
    end
end
local function resized(el) if sizeMatters(el) then replace(el) end end
X._resized = resized

local function restackCorner(host, corner, region)
    if not corner then return end
    checkCorner(host, corner, "re-stack", region)
    local obj, canvas = liveHost(host)
    if obj then pcall(P.restack, host, corner, liveIn(canvas), true, region, ctxFor(host, obj, canvas)) end
end

-- Story 13: the line of the last Journal event, logged on a later tick (an open Journal's, or the next HUD tick once
-- it has closed): a log line costs 0.3-0.8 ms and would double the measured attach.
local journalLog = nil
local function flushJournalLog()
    local l = journalLog
    journalLog = nil
    if l.info then C.log.info("%s", l.text) else C.log.debug("%s", l.text) end
end

-- Elements a host event touches: those on the host, and their panels' children.
local function forHost(host, fn)
    for _, el in ipairs(C.order) do
        if C.hostOf(el) == host then fn(el) end
    end
end

-- UI-1 watcher: the behaviour behind create and place on the HUD (story 10). Only elements with host "hud" (and their
-- panels' children, which their panels attach).
local function onHud(hud, info)
    flushLog()
    if info.event == "attached" then
        local t = C.pt()
        local canvas = HOST.hud.canvas(hud)
        C.pa("core.canvas", t)
        if not canvas then C.warnOnce("nocanvas", "the HUD has no OwningCanvas (%s); elements stay pending", tostring(info.path)) return end
        t = C.pt()
        local okS, byId, orphans = pcall(scan, canvas, onHost("hud"))
        C.pa("core.scan", t)
        if not okS then C.warnOnce("scan", "scanning the HUD canvas failed: %s", tostring(byId)) byId, orphans = {}, {} end
        -- Orphans: widgets tagged with this mod but an id it doesn't know (a hot reload's leftovers, or removed
        -- elements on a HUD that came back), or of an element now on another host or in a panel. Removed, never adopted.
        if #orphans > 0 then
            local ids = {}
            for i, o in ipairs(orphans) do removeWidget(o.w); if i <= 8 then ids[#ids + 1] = o.id end end
            C.log.info("ui removed %d orphan widget(s) of %s from the HUD canvas (ids: %s%s)", #orphans, C.mod, table.concat(ids, ", "), #orphans > 8 and ", ..." or "")
        end
        -- One log line for the whole event, not one per element: a UE4SS log line costs 150-500 us on the game
        -- thread (measured on V8.1.2 with the console enabled). The full report is DEBUG and is only built while
        -- debug is on; an event where an element stayed pending always gets one short INFO line naming them.
        local report = { build = C.debugOn() }
        local pending = nil
        for _, el in ipairs(C.order) do
            if not el.removed and el.place.host == "hud" then
                t = C.pt()
                local ok, res = pcall(attachOne, el, hud, canvas, byId, info.reason, report)
                C.pa("core.attach", t)
                if not ok or not res then
                    el.attached, el.retryAt = false, tick + RETRY_TICKS
                    pending = pending or {}
                    if #pending < 8 then pending[#pending + 1] = "'" .. el.id .. "'" end
                end
                if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) end
                if ok and res and el.kind == "panel" then
                    for _, ch in ipairs(el.children) do
                        if not ch.removed and not ch.attached then
                            pending = pending or {}
                            if #pending < 8 then pending[#pending + 1] = "'" .. ch.id .. "'" end
                        end
                    end
                end
            end
        end
        t = C.pt()
        placeAll("hud", hud, canvas, true)
        C.pa("core.placeAll", t)
        -- Logged on the next tick: the line costs 0.3-0.8 ms on V8.1.2 (the attach tick's largest item), so it gets a
        -- tick of its own.
        if pending then
            pendingDebug = false
            pendingLog = string.format("ui attach left %s pending, retried in %d ticks%s (%s)", table.concat(pending, ", "), RETRY_TICKS,
                #report > 0 and ("; attached " .. table.concat(report, ", ")) or "", tostring(info.reason))
        elseif #report > 0 then
            pendingDebug = true
            pendingLog = string.format("ui attach %s (%s)", table.concat(report, ", "), tostring(info.reason))
        end
        attachedThisTick = true
    elseif info.event == "lost" then
        -- Never touch the widgets: there may be none, and the old ones are the game's to clean up.
        local freed = {}
        forHost("hud", function(el)
            el.attached = false
            if el.ref then
                local okD, w = pcall(C.deref, el.ref)
                if okD and w == nil then
                    freed[#freed + 1] = string.format("'%s' %s", el.id, tostring(el.ref))
                    freeRef(el)
                end
            end
        end)
        if #freed > 0 then C.log.debug("ui widget(s) gone with the HUD; freed handle(s) %s", table.concat(freed, ", ")) end
    elseif info.event == "shown" then
        P.settle("hud") -- children of a HUD that was hidden may only now be measured: re-check stack heights
        if C.debugOn() then for _, el in ipairs(C.order) do D.schedule(el, "HUD shown") end end
    end
    -- hidden: nothing to do; the elements share the HUD's visibility.
end

-- Per tick while a HUD is attached: re-attach an element whose widget is gone or left the canvas (a panel also when
-- one of its children's widgets is gone), follow near elements and settling stacks. Steady state is one native Deref
-- per element: whether a widget is still a child of the live canvas (GetParent, a UFunction call per element) is
-- checked only every MEMBER_TICKS ticks, since nothing but another mod's RemoveFromParent takes it out between HUD
-- events. Nothing runs on the tick that just handled an attached event (the watcher did all of it). Only elements with
-- host "hud".
local MEMBER_TICKS = 10          -- 5 s
-- Liveness within one tick, memoised; emptied at the end of the tick (no widget kept between callbacks). Module-level
-- functions and one reused table: the steady path allocates nothing of its own.
local tickSeen = {}              -- element -> widget | false, this tick only
local tickStrict = nil           -- liveIn(canvas) on a full membership tick, else nil (Deref only)
local function liveNow(el)
    local w = tickSeen[el]
    if w == nil then
        if tickStrict then w = tickStrict(el) or false
        else w = (el.ref and C.deref(el.ref)) or false end
        tickSeen[el] = w
    end
    return w or nil
end
local function endTick()
    for k in pairs(tickSeen) do tickSeen[k] = nil end
    tickStrict = nil
end

local function onTickBody(hud)
    tick = tick + 1
    if attachedThisTick then attachedThisTick = false return end
    if pendingLog then flushLog() C.tickEvent = "attach log" return end
    if journalLog and J._S.path == nil then flushJournalLog() C.tickEvent = "journal log" return end
    local full = tick % MEMBER_TICKS == 0
    local t = C.pt()
    if full then
        local canvas = HOST.hud.canvas(hud)
        if not canvas then return end
        tickStrict = liveIn(canvas)
    end
    local missing = false
    for _, el in ipairs(C.order) do
        if not el.removed and el.place.host == "hud" and (el.retryAt == nil or tick >= el.retryAt) then
            if not liveNow(el) or (el.kind == "panel" and childMissing(el)) then missing = true break end
        end
    end
    C.pa(full and "tick.membersFull" or "tick.members", t)
    if missing then
        C.tickEvent = "re-attach"
        t = C.pt()
        local canvas = HOST.hud.canvas(hud)
        if canvas then
            local strict = liveIn(canvas)
            local okS, byId = pcall(scan, canvas, onHost("hud"))
            if not okS then byId = {} end
            local any = false
            for _, el in ipairs(C.order) do
                if not el.removed and el.place.host == "hud" and (el.retryAt == nil or tick >= el.retryAt)
                    and (not strict(el) or (el.kind == "panel" and childMissing(el))) then
                    local ok, res = pcall(attachOne, el, hud, canvas, byId, "its widget left the HUD canvas")
                    if not ok or not res then
                        el.retryAt = tick + RETRY_TICKS
                        if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) end
                    else
                        any = true
                    end
                end
            end
            if any then placeAll("hud", hud, canvas, true) end
            endTick()
            tickStrict = strict
        end
        C.pa("tick.reattach", t)
    end
    t = C.pt()
    P.tick("hud", hud, liveNow)
    C.pa("tick.place", t)
end

local function onTick(hud)
    local ok, err = pcall(onTickBody, hud)
    endTick()
    if not ok then error(err, 0) end
end

-- ---------------------------------------------------------------- the Journal host (story 13)
-- Each open is a new Journal_C: every journal element gets a new widget in the map page's canvas (a panel's children
-- in its box), then placement. The attach is timed with the microsecond clock (story 13 AC 6: under 2 ms on the game
-- thread), per step since story 14: the canvas lookup, each element (its Create call apart; a panel's own time without
-- its children), and the placement. It is reported in one line on the next tick (a log line costs 0.3-0.8 ms; it
-- would double the measured work): DEBUG when all attached, INFO when an element stayed pending.
local function stepsText(s)
    local parts = { string.format("canvas %d", s.canvas) }
    local inPanelUs = {}
    for _, it in ipairs(s.items) do
        if it.panel then inPanelUs[it.panel] = (inPanelUs[it.panel] or 0) + it.us end
    end
    for _, it in ipairs(s.items) do
        local extra = { string.format("create %d", it.create) }
        if it.panel then extra[#extra + 1] = "in '" .. it.panel .. "'" end
        if inPanelUs[it.id] then extra[#extra + 1] = string.format("own %d", it.us - inPanelUs[it.id]) end
        parts[#parts + 1] = string.format("'%s' %d (%s)", it.id, it.us, table.concat(extra, ", "))
    end
    parts[#parts + 1] = string.format("place %d", s.place)
    return table.concat(parts, "; ")
end
X._stepsText = stepsText

local function onJournal(j, info)
    if info.event == "opened" then
        local t0 = C.micros()
        local canvas = J._canvasOf(j)
        if not canvas then return end -- J._canvasOf warned once; the elements stay pending until the next open
        local tCanvas = C.micros() - t0
        P.journalReset() -- story 19: a new Journal; its measured regions are unknown until its first paint
        -- A new Journal holds none of our widgets, so nothing is scanned. Only when the same Journal comes back
        -- (never seen on V8.1.2) are its children scanned for our tags, so nothing is duplicated.
        local byId = {}
        if info.reopened then
            local okS, b, orphans = pcall(scan, canvas, onHost("journal"))
            if okS then
                byId = b
                for _, o in ipairs(orphans) do removeWidget(o.w) end
            end
        end
        local report = { build = C.debugOn() }
        local steps = {}
        local n, pending = 0, nil
        for _, el in ipairs(C.order) do
            if not el.removed and el.place.host == "journal" then
                n = n + 1
                local ok, res = pcall(attachOne, el, j, canvas, byId, info.reason, report, steps)
                if not ok or not res then
                    el.attached = false
                    pending = pending or {}
                    if #pending < 8 then pending[#pending + 1] = "'" .. el.id .. "'" end
                end
                if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) end
                if el.kind == "panel" then
                    for _, ch in ipairs(el.children) do
                        if not ch.removed then
                            n = n + 1
                            if not ch.attached then
                                pending = pending or {}
                                if #pending < 8 then pending[#pending + 1] = "'" .. ch.id .. "'" end
                            end
                        end
                    end
                end
            end
        end
        if n == 0 then return end
        local tp = C.micros()
        placeAll("journal", j, canvas, true)
        local now = C.micros()
        local dt = now - t0
        local s = { canvas = tCanvas, place = now - tp, items = steps }
        J._recordAttach(dt, n, s)
        if pending then
            journalLog = { info = true, text = string.format("ui journal attach left %s pending until the next open (%d element(s), %d us)", table.concat(pending, ", "), n, dt) }
        elseif C.debugOn() then
            journalLog = { text = string.format("ui journal attach n=%d in %d us (%s): %s (%s)", n, dt, stepsText(s), table.concat(report, ", "), tostring(info.reason)) }
        end
    else
        -- closed or lost: the Journal is out of the viewport for good (each open is a new one). Its widgets are never
        -- touched, only our handles to them are freed; the elements keep their state for the next open.
        local freed = 0
        P.journalReset()
        forHost("journal", function(el)
            if el.ref then freed = freed + 1 end
            freeRef(el)
            el.attached, el.slotKey, el.appliedVis, el.stackHeight, el.padKey = false, nil, nil, nil, nil
            el.nearRect = nil
        end)
        if freed > 0 and C.debugOn() then journalLog = { text = string.format("ui journal %s: freed %d widget handle(s) (%s)", info.event, freed, tostring(info.reason)) } end
    end
end

local function liveRef(el) return el.ref and C.deref(el.ref) or nil end
local function onJournalTick(j)
    if journalLog then flushJournalLog() return end
    -- Corner stacks re-measured for a few ticks after the open (Slate measures late); story 19: measured regions
    -- re-read until valid, then every 4 ticks.
    P.tick("journal", j, liveRef)
end

local journalWatching = false
local function ensureJournal()
    if journalWatching then return end
    journalWatching = true
    J._watch(onJournal)
    J._ticker(onJournalTick)
end

local function ensureWatching()
    if watching then return end
    watching = true
    H._watch(onHud)
    H._ticker(onTick)
    -- The widget classes are loaded again after a map change (nothing keeps them alive): do that on the tick before
    -- the attach, for every kind in use.
    H._prepare(function()
        local need = {}
        for _, el in ipairs(C.order) do need[el.kind] = true end
        for kind in pairs(need) do classOf(kind) end
    end)
end
local function ensureHost(el)
    ensureWatching()
    if C.hostOf(el) == "journal" then ensureJournal() end
end
X._ensureHost = ensureHost

-- Attaches one element now when its host is live (create, or place on a pending element). A panel's child attaches
-- into its panel's box when the panel's widget is live; otherwise it waits for its panel.
local function attachNow(el, reason)
    if el.panel then
        local p = el.panel
        local pw = liveWidget(p)
        if not pw then return end
        local obj = liveHost(p.place.host)
        if not obj then return end
        local box = boxOf(p, pw)
        if not box then return end
        local ok, res = pcall(attachOne, el, obj, box, {}, reason)
        if not ok or not res then el.retryAt = tick + RETRY_TICKS end
        if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) return end
        if not res then return end
        ensureOrder(p, box) -- appended at the end; anywhere else in the order, the box is rebuilt
        applyGaps(p)
        local w = liveWidget(el)
        if w then pcall(P.applyVisibility, el, w) end
        resized(p)
        return
    end
    local host = el.place.host
    local obj, canvas = liveHost(host)
    if not obj then return end
    local byId = {}
    if host == "hud" then
        local okS, b = pcall(scan, canvas, onHost("hud"))
        if okS then byId = b end
    end
    local ok, res = pcall(attachOne, el, obj, canvas, byId, reason)
    if not ok or not res then el.retryAt = tick + RETRY_TICKS end
    if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) return end
    if res then placeAll(host, obj, canvas, true) end
end
X._attachNow = attachNow

-- ---------------------------------------------------------------- the element registry (all kinds)

-- Story 14: whether a panel can take one more child; raises otherwise. kind: the joining element's kind.
local function checkJoin(p, kind, fn)
    if kind == "panel" then C.fail("%s.%s: a panel can't go inside a panel (one level only)", C.UI, fn) end
    local n = 0
    for _, ch in ipairs(p.children) do if not ch.removed then n = n + 1 end end
    if n >= MAX_CHILDREN then C.fail("%s.place: panel '%s' already has %d children (at most %d)", C.UI, p.id, n, MAX_CHILDREN) end
    if X.checkHost then X.checkHost(kind, p.place.host, fn) end
end
X._checkJoin = checkJoin

-- A new element of a kind: registered, in creation order. place is a validated intent ({ panelEl = ... } for a panel).
function X._new(kind, id, fields, place)
    C.seq = C.seq + 1
    local el = fields
    el.kind, el.id, el.visible, el.removed, el.attached, el.seq = kind, id, true, false, false, C.seq
    if place.panelEl then
        el.panel, el.place = place.panelEl, { inPanel = true }
        local list = place.panelEl.children
        list[#list + 1] = el
    else
        el.place = place
    end
    el.handle = newHandle(id, kind)
    C.els[id] = el
    C.order[#C.order + 1] = el
    C.handleOf[el.handle] = el
    ensureHost(el)
    attachNow(el, "create")
    return el
end

-- The existing element with this id for a create of kind, or nil; raises when the id belongs to another kind.
function X._existing(id, kind, fn)
    local el = C.els[id]
    if el and not el.removed then
        if el.kind ~= kind then C.fail("%s.%s: id '%s' is already %s of this mod", C.UI, fn, id, C.ARTICLE[el.kind]) end
        return el
    end
    return nil
end

-- Takes an element out of where it is (a host canvas or a panel): its widget leaves, its handle is freed, and the
-- place it left closes up. Its state stays.
local function detach(el)
    local w = liveWidget(el)
    if w then removeWidget(w) end
    freeRef(el)
    el.attached, el.slotKey, el.appliedVis, el.nearAbsent, el.retryAt, el.padKey = false, nil, nil, false, nil, nil
    if el.panel then
        local p = el.panel
        for i, ch in ipairs(p.children) do if ch == el then table.remove(p.children, i) break end end
        el.panel = nil
        if w then applyGaps(p); resized(p) end
    elseif w and el.place.corner then
        restackCorner(el.place.host, el.place.corner, el.place.region)
    end
end

-- Removes an element for good (a panel with its children: their handles raise "was removed" from then on).
local function removeEl(el, underRemovedPanel)
    local w = liveWidget(el)
    if w and not underRemovedPanel then removeWidget(w) end -- a child goes with its panel's widget
    freeRef(el)
    el.removed, el.attached = true, false
    C.els[el.id] = nil
    for i, e in ipairs(C.order) do if e == el then table.remove(C.order, i) break end end
    C.handleOf[el.handle] = nil
    C.removedHandle[el.handle] = el.id
    C.removedKind[el.handle] = el.kind
    if el.kind == "panel" then
        for _, ch in ipairs(el.children) do removeEl(ch, true) end
        el.children = {}
    end
    if el.panel and not underRemovedPanel then
        local p = el.panel
        for i, ch in ipairs(p.children) do if ch == el then table.remove(p.children, i) break end end
        if w then applyGaps(p); resized(p) end
    elseif w and not el.panel and el.place.corner then
        restackCorner(el.place.host, el.place.corner, el.place.region)
    end
end
X._remove = removeEl

-- Whether the element is drawn now: its widget exists in its container (the host's live canvas, or its panel's box),
-- it isn't hidden by setVisible (nor its panel), and the host is drawn (the HUD visible, the Journal open on its map
-- page).
local function shown(el)
    if not el.visible or el.nearAbsent or not el.ref then return false end
    local w = C.deref(el.ref)
    if not w then return false end
    local container
    if el.panel then
        if not shown(el.panel) then return false end
        local pw = liveWidget(el.panel)
        container = pw and boxOf(el.panel, pw)
    else
        local A = HOST[el.place.host]
        local obj, drawn = A.poll()
        if not obj or not drawn then return false end
        container = A.canvas(obj)
    end
    if not container then return false end
    local okP, p = pcall(function() return w:GetParent() end)
    if not (okP and C.valid(p) and p:GetAddress() == container:GetAddress()) then return false end
    return C.drawn(tonumber(w:GetVisibility()) or 0)
end
X._shown = shown

-- setVisible for any kind (the caller checked the handle and the value).
function X._setVisible(el, visible)
    if el.visible == visible then return end
    el.visible = visible
    local w = liveWidget(el)
    if w then
        local ok, err = pcall(P.applyVisibility, el, w)
        if not ok then C.warnOnce("vis:" .. el.id, "%s '%s': SetVisibility failed: %s", el.kind, el.id, tostring(err):match("^[^\n]*")) end
        if el.panel then
            applyGaps(el.panel) -- the first visible child has no gap before it
            resized(el.panel)   -- the panel's size changed: what follows it in its corner moves
        elseif el.place.corner then restackCorner(el.place.host, el.place.corner, el.place.region) -- a hidden element takes no space
        elseif visible and C.debugOn() then D.schedule(el, "shown") end
    end
end

-- setStyle for any kind: s is a resolved style.
local function sameFull(a, b)
    if not sameStyle(a, b) or (a.hover == nil) ~= (b.hover == nil) then return false end
    return a.hover == nil or (sameStyle(a.hover, b.hover) and sameStyle(a.pressed, b.pressed))
end
function X._setStyle(el, s)
    if sameFull(s, el.style) then return end
    el.style = s
    local w = liveWidget(el)
    if w then
        KIND[el.kind].style(el, w, false)
        resized(el)
    end
end

-- ---------------------------------------------------------------- public: text

local CREATE_KEYS = { id = true, text = true, place = true, style = true }

function X.create(opts)
    C.enter("text.create")
    if type(opts) ~= "table" then C.fail("%s.text.create: expected a table { id = ..., text = ..., place = ..., style = ... }, got %s", C.UI, C.describe(opts)) end
    for k in pairs(opts) do
        if not CREATE_KEYS[k] then C.fail("%s.text.create: unknown key %s (valid: id, text, place, style)", C.UI, C.describe(k)) end
    end
    local id = validId(opts.id, "text.create")
    local text, long = validText(opts.text, "text.create")
    if opts.place ~= nil and type(opts.place) ~= "table" then
        C.fail("%s.text.create: place must be a table or nil, got %s", C.UI, C.describe(opts.place))
    end
    local place = opts.place ~= nil and P.validate(opts.place) or P.validate({ corner = "top-right" })
    local style = X.resolveStyle(opts.style)
    local el = X._existing(id, "text", "text.create")
    if el then
        -- Same id: the new text, intent and style, as set, place and setStyle would apply them; visible unchanged.
        X.set(el.handle, text)
        X.setStyle(el.handle, opts.style)
        P.place(el.handle, opts.place or { corner = "top-right" })
        return el.handle
    end
    if place.panelEl then checkJoin(place.panelEl, "text", "text.create") end
    el = X._new("text", id, { text = text, style = style, warnedLong = long }, place)
    if long then C.log.warn("text '%s': text is longer than %d characters; showing the first %d", id, MAX_TEXT, MAX_TEXT) end
    return el.handle
end

function X.set(h, text, ...)
    C.enter("text.set")
    local el = C.element(h, "text.set", "text")
    local t, long = validText(text, "text.set")
    if long and not el.warnedLong then
        el.warnedLong = true
        C.log.warn("text '%s': text is longer than %d characters; showing the first %d", el.id, MAX_TEXT, MAX_TEXT)
    end
    if t == el.text then return end -- no UObject call: what keeps a once-a-second clock cheap
    el.text = t
    local w = liveWidget(el)
    if w then
        local ok, err = pcall(KIND.text.content, el, w, false)
        if not ok then C.warnOnce("set:" .. el.id, "text '%s': SetText failed: %s", el.id, tostring(err):match("^[^\n]*")) end
        resized(el) -- the size may have changed: the elements after it (or after its panel) move
    end
end

function X.setStyle(h, style)
    C.enter("text.setStyle")
    local el = C.element(h, "text.setStyle", "text")
    X._setStyle(el, X.resolveStyle(style))
end

function X.setVisible(h, visible)
    C.enter("text.setVisible")
    local el = C.element(h, "text.setVisible", "text")
    if type(visible) ~= "boolean" then C.fail("%s.text.setVisible: visible must be a boolean, got %s", C.UI, type(visible)) end
    X._setVisible(el, visible)
end

function X.remove(h)
    C.enter("text.remove")
    if type(h) == "table" and C.removedHandle[h] then return end -- idempotent
    local el = C.element(h, "text.remove", "text")
    removeEl(el)
end

function X.isShown(h)
    C.enter("text.isShown")
    local el = C.element(h, "text.isShown", "text")
    return shown(el)
end

-- UI-3: place(handle, intent), any kind. Pending: stores the intent; attach applies it. Live: re-places now. A new
-- host moves the element: its widget leaves the old host's canvas, the old corner closes up, and it attaches on the
-- new host now (or when that host next appears). Story 14: { panel = p } moves it into a panel (at the end; already
-- there: nothing changes), and a host intent takes a child out of its panel.
P.place = function(h, intent)
    C.enter("place")
    local el = C.element(h, "place")
    local pl = P.validate(intent)
    if pl.panelEl then
        local p = pl.panelEl
        if el.kind == "panel" then C.fail("%s.place: a panel can't go inside a panel (one level only)", C.UI) end
        if p == el.panel then return end
        checkJoin(p, el.kind, "place")
        detach(el)
        el.panel, el.place = p, { inPanel = true }
        p.children[#p.children + 1] = el
        ensureHost(el)
        attachNow(el, "place in panel '" .. p.id .. "'")
        return
    end
    if X.checkHost then X.checkHost(el.kind, pl.host, "place", el) end
    if el.panel then
        detach(el)
        el.place = pl
        ensureHost(el)
        attachNow(el, "place on host " .. pl.host)
        return
    end
    local oldHost, oldCorner, oldRegion = el.place.host, el.place.corner, el.place.region
    if pl.host == "journal" then ensureJournal() end
    if oldHost ~= pl.host then
        detach(el)
        el.place = pl
        attachNow(el, "place on host " .. pl.host)
        return
    end
    el.place = pl
    el.slotKey, el.nearAbsent = nil, false
    if liveWidget(el) then
        local obj, canvas = liveHost(pl.host)
        if obj then
            if oldCorner and (oldCorner ~= pl.corner or oldRegion ~= pl.region) then
                pcall(P.restack, pl.host, oldCorner, liveIn(canvas), true, oldRegion, ctxFor(pl.host, obj, canvas))
                checkCorner(pl.host, oldCorner, "re-stack", oldRegion)
            end
            placeAll(pl.host, obj, canvas, true)
            if pl.corner then checkCorner(pl.host, pl.corner, "place", pl.region) elseif C.debugOn() then D.schedule(el, "place") end
        end
    elseif not el.attached then
        attachNow(el, "place")
    end
end

function X.stats()
    local n = 0
    for _ in pairs(C.els) do n = n + 1 end
    return { elements = n, uobjectCalls = C.stats.uobjectCalls, attachCreated = C.stats.attachCreated,
        attachReused = C.stats.attachReused, handlesFreed = C.stats.handlesFreed, findAllCalls = C.stats.findAllCalls,
        overlapScheduled = C.stats.overlapScheduled, overlapChecks = C.stats.overlapChecks,
        panelRebuilds = C.stats.panelRebuilds or 0 }
end

-- The tag a widget of this mod's element carries (for tests and diagnostics).
function X.tagOf(id) return tagOf(id) end

X._validId, X._validText, X._sameStyle, X._sameFull = validId, validText, sameStyle, sameFull
X._liveWidget, X._applyGaps, X._ensureOrder = liveWidget, applyGaps, ensureOrder
X._MAX_CHILDREN = MAX_CHILDREN
return X
