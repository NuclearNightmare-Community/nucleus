-- UI-2 (story 8) and UI-4 (story 10): text elements on the HUD, kept there through every HUD rebuild.
-- Exposed as core.ui.text on the connect API:
--   create{ id = <string>, text = <string|number|nil>, place = <intent|nil>, style = <style|nil> } -> handle
--   set(handle, text)            setStyle(handle, style)        setVisible(handle, visible)
--   remove(handle)               isShown(handle) -> boolean     stats() -> table (diagnostic copy, not semver API)
-- and core.ui.place(handle, intent) (UI-3, place.lua).
--
-- Elements are plain Lua state per mod: id, text, intent, resolved style, the caller's visibility wish, and the live
-- widget's weak handle and path. Never a UObject. The widget is WBP_<Core>Text (Border "Background" -> TextBlock
-- "Text"), tagged with ToolTipText "<core>:<mod>:<id>" and SelfHitTestInvisible, so it can be found again after a
-- HUD rebuild or a hot reload without relying on its text. A UI-1 watcher re-attaches every element on each
-- `attached` event; on `lost` it only frees handles whose widget is gone.
local BASE = (...):gsub("%.ui%.text$", "")
local C = require(BASE .. ".ui.common")
local H = require(BASE .. ".ui.hud")
local P = require(BASE .. ".ui.place")
local theme = require(BASE .. ".ui.theme")

local X = {}
local MAX_ID = 64
local MAX_TEXT = 256
local RETRY_TICKS = 10           -- a failed attach is retried every 10 ticks (5 s), not every tick
local TAG_PREFIX = C.LOWER .. ":" -- full tag: <core>:<modTag>:<id>

local tick = 0
local watching = false
local attachedThisTick = false  -- set by the attached watcher, read by the same tick's onTick
local pendingLog = nil           -- the attach line of the last attached event, logged on the next tick
local function flushLog()
    if not pendingLog then return end
    local t = C.pt()
    C.log.info("%s", pendingLog)
    C.pa("core.log", t)
    pendingLog = nil
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

local function unit(v, what)
    if type(v) ~= "number" or v ~= v or v < 0 or v > 1 then
        C.fail("%s.text: background.%s must be a number from 0 to 1, got %s", C.UI, what, C.describe(v))
    end
    return v + 0.0
end

-- Resolves a style to { r, g, b, a, pad } (colour 0..1, padding in canvas units). nil is the default: no box.
function X.resolveStyle(style)
    if style == nil then return { r = 0, g = 0, b = 0, a = 0, pad = 0 } end
    if type(style) ~= "table" then C.fail("%s.text: style must be a table { background = ..., padding = ... }, got %s", C.UI, C.describe(style)) end
    for k in pairs(style) do
        if k ~= "background" and k ~= "padding" then C.fail("%s.text: unknown style key %s (valid: background, padding)", C.UI, C.describe(k)) end
    end
    local bg, col = style.background, nil
    if bg == nil then bg = "none" end
    if type(bg) == "string" then
        local p = theme.background[bg]
        if not p then C.fail("%s.text: unknown background %s (valid: %s, or { r = 0..1, g = 0..1, b = 0..1, a = 0..1 })", C.UI, C.describe(bg), table.concat(theme.backgroundNames, ", ")) end
        col = { r = p.r, g = p.g, b = p.b, a = p.a }
    elseif type(bg) == "table" then
        for k in pairs(bg) do
            if k ~= "r" and k ~= "g" and k ~= "b" and k ~= "a" then C.fail("%s.text: unknown background key %s (valid: r, g, b, a)", C.UI, C.describe(k)) end
        end
        col = { r = unit(bg.r, "r"), g = unit(bg.g, "g"), b = unit(bg.b, "b"), a = bg.a == nil and 1.0 or unit(bg.a, "a") }
    else
        C.fail("%s.text: background must be a preset name or a colour table, got %s", C.UI, C.describe(bg))
    end
    local pad = style.padding
    if pad == nil then pad = (col.a > 0) and theme.paddingWithBackground or "none" end
    if type(pad) ~= "string" or theme.padding[pad] == nil then
        C.fail("%s.text: unknown padding %s (valid: %s)", C.UI, C.describe(pad), table.concat(theme.paddingNames, ", "))
    end
    col.pad = theme.padding[pad]
    return col
end

local function sameStyle(a, b) return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a and a.pad == b.pad end

-- ---------------------------------------------------------------- handles

local function newHandle(id)
    return setmetatable({}, {
        __index = { id = id },
        __newindex = function() error(C.UI .. ".text: element handles are read-only", 2) end,
        __metatable = "element handle",
        __tostring = function() return "element '" .. id .. "'" end,
    })
end

-- ---------------------------------------------------------------- widget helpers (game thread)

local function tagOf(id) return TAG_PREFIX .. C.modTag .. ":" .. id end

-- The widget class, kept as a weak handle between ticks. Never StaticFindObject(C.TEXT_CLASS): when the class isn't
-- loaded that misses, and a miss in the pinned UE4SS scans every object (4-5 ms per call on V8.1.2, twice per HUD
-- event with two elements). GetAsset returns the loaded class at once and loads it otherwise.
local classRef = nil
local function textClass()
    if classRef then
        local okD, cls = pcall(C.deref, classRef)
        if okD and cls then return cls end
        pcall(C.free, classRef)
        classRef = nil
    end
    local t = C.pt()
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    local ok, got = pcall(function()
        return helpers:GetAsset({ PackageName = FName(C.TEXT_PKG), AssetName = FName(C.TEXT_SHORT) })
    end)
    C.pa("class.load", t)
    if not (ok and C.valid(got)) then return nil end
    local okR, h = pcall(C.ref, got)
    if okR then classRef = h end
    return got
end

local function canvasOf(hud)
    local ok, c = pcall(function() return hud.OwningCanvas end)
    return ok and C.valid(c) and c or nil
end

-- live(el) -> the element's widget when it sits in this canvas, else nil.
local function liveIn(canvas)
    local caddr = canvas:GetAddress()
    return function(el)
        if not el.ref then return nil end
        local w = C.deref(el.ref)
        if not w then return nil end
        local okP, p = pcall(function() return w:GetParent() end)
        if okP and C.valid(p) and p:GetAddress() == caddr then return w end
        return nil
    end
end

-- Our widgets among the canvas's direct children: byId[id] = { widgets in child order }, orphans = { widget, id }.
local function readTag(w)
    local ok, t = pcall(function() return w.ToolTipText:ToString() end)
    return ok and type(t) == "string" and t or nil
end
local function scan(canvas)
    local byId, orphans = {}, {}
    local mine = TAG_PREFIX .. C.modTag .. ":"
    local n = canvas:GetChildrenCount()
    for i = 0, n - 1 do
        local c = canvas:GetChildAt(i)
        if C.valid(c) then
            local okC, cls = pcall(function() return c:GetClass():GetFName():ToString() end)
            if okC and cls == C.TEXT_SHORT then
                local tag = readTag(c)
                if tag and tag:sub(1, #mine) == mine then
                    local id = tag:sub(#mine + 1)
                    local el = C.els[id]
                    if el and not el.removed then
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

local function setTag(w, id)
    local tag = tagOf(id)
    local ok = pcall(function() C.count(); w:SetToolTipText(FText(tag)) end)
    if not ok then ok = pcall(function() C.count(); w.ToolTipText = FText(tag) end) end
    if not ok then C.warnOnce("tag:" .. id, "text '%s': could not set its tag (ToolTipText); it may be duplicated after a HUD rebuild", id) end
end

local function applyText(el, w)
    C.count(); w:SetText(el.text)
end

local function applyStyle(el, w)
    local s = el.style
    local ok, err = pcall(function()
        C.count(); w:SetBackground(s.r, s.g, s.b, s.a)
        C.count(); w:SetBackgroundPadding(s.pad)
    end)
    if not ok then C.warnOnce("style:" .. el.id, "text '%s': style not applied (is %s's pak current?): %s", el.id, C.NAME, tostring(err):match("^[^\n]*")) end
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

-- ---------------------------------------------------------------- attach (UI-2) and re-attach (UI-4)

-- Puts one element's widget into the canvas: reuses the element's own widget or one tagged with its id, else creates
-- one. Then re-applies text and style; placement and visibility follow in placeAll. Raises on failure (callers pcall).
local function attachOne(el, hud, canvas, byId, reason, report)
    local t = C.pt()
    local live = liveIn(canvas)
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
    if extra > 0 then C.log.warn("text '%s': removed %d duplicate widget(s) from the HUD canvas", el.id, extra) end
    byId[el.id] = nil
    if not w then
        t = C.pt()
        local cls = textClass()
        C.pa("attach.class", t)
        if not cls then
            C.warnOnce("pak:" .. el.id, "text '%s' stays pending: %s is not loaded (is Content/Paks/LogicMods/%s.pak installed?)", el.id, C.TEXT_CLASS, C.NAME)
            return false
        end
        t = C.pt()
        local owner
        local okO, o = pcall(function() return hud:GetOwningPlayer() end)
        if okO and C.valid(o) then owner = o end
        local world = hud:GetWorld()
        if not owner then
            local okP, pc = pcall(function() return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(world, 0) end)
            if okP and C.valid(pc) then owner = pc end
        end
        C.pa("attach.owner", t)
        if not owner then return false end -- between worlds; the next HUD event tries again
        C.count()
        t = C.pt()
        w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(world, cls, owner)
        C.pa("attach.create", t)
        if not C.valid(w) then error("creating " .. C.TEXT_SHORT .. " failed") end
        t = C.pt()
        setTag(w, el.id)
        C.pa("attach.tag", t)
        el.appliedVis = nil
        t = C.pt()
        P.applyVisibility(el, w) -- before it joins the canvas, so a hidden element never flashes
        C.pa("attach.vis", t)
        t = C.pt()
        C.count(); canvas:AddChildToCanvas(w)
        C.pa("attach.add", t)
        how = "created"
        C.stats.attachCreated = C.stats.attachCreated + 1
    else
        C.stats.attachReused = C.stats.attachReused + 1
    end
    t = C.pt()
    applyText(el, w)
    C.pa("attach.text", t)
    t = C.pt()
    applyStyle(el, w)
    C.pa("attach.style", t)
    t = C.pt()
    local path = C.pathOf(w)
    if path ~= el.path or not el.ref then
        if el.ref then C.log.debug("ui '%s': new widget %s; freed the handle %s of the old one (%s)", el.id, path, tostring(el.ref), tostring(el.path)) end
        freeRef(el)
        el.ref, el.path = C.ref(w), path
    end
    C.pa("attach.ref", t)
    el.attached, el.slotKey, el.appliedVis, el.retryAt = true, nil, nil, nil
    if report then
        report[#report + 1] = string.format("'%s' %s %s", el.id, how, path)
    else
        t = C.pt()
        C.log.info("ui attach '%s' %s %s (%s)", el.id, how, path, reason)
        C.pa("attach.log", t)
    end
    return true
end

-- Places every live element: corners re-stack once each, near and absolute elements on their own.
local function placeAll(hud, canvas, prepass)
    local live = liveIn(canvas)
    local corners = {}
    for _, el in ipairs(C.order) do
        if not el.removed then
            local w = live(el)
            if w then
                if el.place.corner then corners[el.place.corner] = true
                else
                    local ok, err = pcall(P.apply, el, w, hud, live, prepass)
                    if not ok then C.warnOnce("place:" .. el.id, "place '%s' failed: %s", el.id, tostring(err):match("^[^\n]*")) end
                end
            end
        end
    end
    for corner in pairs(corners) do
        local ok, err = pcall(P.restack, corner, live, prepass)
        if not ok then C.warnOnce("stack:" .. corner, "stacking %s failed: %s", corner, tostring(err):match("^[^\n]*")) end
    end
end

-- Can a size change of this element move another one? Only when a later visible element shares its corner stack
-- (the last element's height moves nothing). Near and absolute positions don't depend on the element's own size.
local function sizeMatters(el)
    local corner = el.place.corner
    if not corner or not el.visible then return false end
    local after = false
    for _, e in ipairs(C.order) do
        if e == el then after = true
        elseif after and not e.removed and e.visible and e.place.corner == corner then return true end
    end
    return false
end

-- Re-places what one element's change can move: its corner's stack, or the element alone.
local function replace(el)
    local hud = H._poll()
    if not hud then return end
    local canvas = canvasOf(hud)
    if not canvas then return end
    local live = liveIn(canvas)
    local w = live(el)
    if el.place.corner then
        pcall(P.restack, el.place.corner, live, true)
    elseif w then
        local ok, err = pcall(P.apply, el, w, hud, live, true)
        if not ok then C.warnOnce("place:" .. el.id, "place '%s' failed: %s", el.id, tostring(err):match("^[^\n]*")) end
    end
end

local function restackCorner(corner)
    if not corner then return end
    local hud = H._poll()
    local canvas = hud and canvasOf(hud)
    if canvas then pcall(P.restack, corner, liveIn(canvas), true) end
end

-- UI-1 watcher: the behaviour behind create and place (story 10).
local function onHud(hud, info)
    flushLog()
    if info.event == "attached" then
        local t = C.pt()
        local canvas = canvasOf(hud)
        C.pa("core.canvas", t)
        if not canvas then C.warnOnce("nocanvas", "the HUD has no OwningCanvas (%s); elements stay pending", tostring(info.path)) return end
        t = C.pt()
        local okS, byId, orphans = pcall(scan, canvas)
        C.pa("core.scan", t)
        if not okS then C.warnOnce("scan", "scanning the HUD canvas failed: %s", tostring(byId)) byId, orphans = {}, {} end
        -- Orphans: widgets tagged with this mod but an id it doesn't know (a hot reload's leftovers, or removed
        -- elements on a HUD that came back). Removed, never adopted.
        if #orphans > 0 then
            local ids = {}
            for i, o in ipairs(orphans) do removeWidget(o.w); if i <= 8 then ids[#ids + 1] = o.id end end
            C.log.info("ui removed %d orphan widget(s) of %s from the HUD canvas (ids: %s%s)", #orphans, C.mod, table.concat(ids, ", "), #orphans > 8 and ", ..." or "")
        end
        -- One log line for the whole event, not one per element: a UE4SS log line costs 150-500 us on the game
        -- thread (measured on V8.1.2 with the console enabled).
        local report = {}
        for _, el in ipairs(C.order) do
            if not el.removed then
                t = C.pt()
                local ok, res = pcall(attachOne, el, hud, canvas, byId, info.reason, report)
                C.pa("core.attach", t)
                if not ok or not res then el.attached, el.retryAt = false, tick + RETRY_TICKS end
                if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) end
            end
        end
        t = C.pt()
        placeAll(hud, canvas, true)
        C.pa("core.placeAll", t)
        -- Logged on the next tick: the line costs 0.3-0.8 ms on V8.1.2 (the attach tick's largest item), so it gets a
        -- tick of its own.
        if #report > 0 then pendingLog = string.format("ui attach %s (%s)", table.concat(report, ", "), tostring(info.reason)) end
        attachedThisTick = true
    elseif info.event == "lost" then
        -- Never touch the widgets: there may be none, and the old ones are the game's to clean up.
        local freed = {}
        for _, el in ipairs(C.order) do
            el.attached = false
            if el.ref then
                local okD, w = pcall(C.deref, el.ref)
                if okD and w == nil then
                    freed[#freed + 1] = string.format("'%s' %s", el.id, tostring(el.ref))
                    freeRef(el)
                end
            end
        end
        if #freed > 0 then C.log.debug("ui widget(s) gone with the HUD; freed handle(s) %s", table.concat(freed, ", ")) end
    elseif info.event == "shown" then
        P.settle() -- children of a HUD that was hidden may only now be measured: re-check stack heights
    end
    -- hidden: nothing to do; the elements share the HUD's visibility.
end

-- Per tick while a HUD is attached: re-attach an element whose widget is gone or left the canvas, follow near
-- elements and settling stacks. Steady state is one native Deref per element: whether a widget is still a child
-- of the live canvas (GetParent, a UFunction call per element) is checked only every MEMBER_TICKS ticks, since
-- nothing but another mod's RemoveFromParent takes it out between HUD events. Nothing runs on the tick that just
-- handled an attached event (the watcher did all of it).
local MEMBER_TICKS = 10          -- 5 s
local function onTick(hud)
    tick = tick + 1
    if attachedThisTick then attachedThisTick = false return end
    if pendingLog then flushLog() C.tickEvent = "attach log" return end
    local full = tick % MEMBER_TICKS == 0
    local t = C.pt()
    local live
    if full then
        local canvas = canvasOf(hud)
        if not canvas then return end
        live = liveIn(canvas)
    else
        live = function(el) return el.ref and C.deref(el.ref) or nil end
    end
    local cache = {}
    local function liveOnce(el)
        local w = cache[el]
        if w == nil then w = live(el) or false; cache[el] = w end
        return w or nil
    end
    local missing = false
    for _, el in ipairs(C.order) do
        if not el.removed and (el.retryAt == nil or tick >= el.retryAt) and not liveOnce(el) then missing = true break end
    end
    C.pa(full and "tick.membersFull" or "tick.members", t)
    if missing then
        C.tickEvent = "re-attach"
        t = C.pt()
        local canvas = canvasOf(hud)
        if canvas then
            local strict = liveIn(canvas)
            local okS, byId = pcall(scan, canvas)
            if not okS then byId = {} end
            local any = false
            for _, el in ipairs(C.order) do
                if not el.removed and not strict(el) and (el.retryAt == nil or tick >= el.retryAt) then
                    local ok, res = pcall(attachOne, el, hud, canvas, byId, "its widget left the HUD canvas")
                    if not ok or not res then
                        el.retryAt = tick + RETRY_TICKS
                        if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) end
                    else
                        any = true
                    end
                end
            end
            if any then placeAll(hud, canvas, true) end
            cache = {}
            live = strict
        end
        C.pa("tick.reattach", t)
    end
    t = C.pt()
    P.tick(hud, liveOnce)
    C.pa("tick.place", t)
end

local function ensureWatching()
    if watching then return end
    watching = true
    H._watch(onHud)
    H._ticker(onTick)
    -- The widget class is loaded again after a map change (nothing keeps it alive): do that on the tick before the
    -- attach.
    H._prepare(function() if #C.order > 0 then textClass() end end)
end

-- Attaches one element now when a HUD is live (create, or place on a pending element).
local function attachNow(el, reason)
    local hud = H._poll()
    if not hud then return end
    local canvas = canvasOf(hud)
    if not canvas then return end
    local okS, byId = pcall(scan, canvas)
    if not okS then byId = {} end
    local ok, res = pcall(attachOne, el, hud, canvas, byId, reason)
    if not ok or not res then el.retryAt = tick + RETRY_TICKS end
    if not ok then C.warnOnce("attach:" .. el.id, "attach %s: %s", el.id, tostring(res):match("^[^\n]*")) return end
    if res then placeAll(hud, canvas, true) end
end

-- ---------------------------------------------------------------- public

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
    ensureWatching()

    local el = C.els[id]
    if el and not el.removed then
        -- Same id: the new text, intent and style, as set, place and setStyle would apply them; visible unchanged.
        X.set(el.handle, text)
        X.setStyle(el.handle, opts.style)
        P.place(el.handle, opts.place or { corner = "top-right" })
        return el.handle
    end
    C.seq = C.seq + 1
    el = { id = id, text = text, place = place, style = style, visible = true, removed = false, warnedLong = false,
        ref = nil, path = nil, attached = false, seq = C.seq }
    if long then
        el.warnedLong = true
        C.log.warn("text '%s': text is longer than %d characters; showing the first %d", id, MAX_TEXT, MAX_TEXT)
    end
    el.handle = newHandle(id)
    C.els[id] = el
    C.order[#C.order + 1] = el
    C.handleOf[el.handle] = el
    attachNow(el, "create")
    return el.handle
end

function X.set(h, text, ...)
    C.enter("text.set")
    local el = C.element(h, "text.set")
    local t, long = validText(text, "text.set")
    if long and not el.warnedLong then
        el.warnedLong = true
        C.log.warn("text '%s': text is longer than %d characters; showing the first %d", el.id, MAX_TEXT, MAX_TEXT)
    end
    if t == el.text then return end -- no UObject call: what keeps a once-a-second clock cheap
    el.text = t
    local w = el.ref and C.deref(el.ref)
    if w then
        local ok, err = pcall(applyText, el, w)
        if not ok then C.warnOnce("set:" .. el.id, "text '%s': SetText failed: %s", el.id, tostring(err):match("^[^\n]*")) end
        if sizeMatters(el) then replace(el) end -- the size may have changed: the elements after it move
    end
end

function X.setStyle(h, style)
    C.enter("text.setStyle")
    local el = C.element(h, "text.setStyle")
    local s = X.resolveStyle(style)
    if sameStyle(s, el.style) then return end
    el.style = s
    local w = el.ref and C.deref(el.ref)
    if w then
        applyStyle(el, w)
        if sizeMatters(el) then replace(el) end
    end
end

function X.setVisible(h, visible)
    C.enter("text.setVisible")
    local el = C.element(h, "text.setVisible")
    if type(visible) ~= "boolean" then C.fail("%s.text.setVisible: visible must be a boolean, got %s", C.UI, type(visible)) end
    if el.visible == visible then return end
    el.visible = visible
    local w = el.ref and C.deref(el.ref)
    if w then
        local ok, err = pcall(P.applyVisibility, el, w)
        if not ok then C.warnOnce("vis:" .. el.id, "text '%s': SetVisibility failed: %s", el.id, tostring(err):match("^[^\n]*")) end
        if el.place.corner then restackCorner(el.place.corner) end -- a hidden element takes no space
    end
end

function X.remove(h)
    C.enter("text.remove")
    if type(h) == "table" and C.removedHandle[h] then return end -- idempotent
    local el = C.element(h, "text.remove")
    local w = el.ref and C.deref(el.ref)
    if w then removeWidget(w) end
    freeRef(el)
    el.removed, el.attached = true, false
    C.els[el.id] = nil
    for i, e in ipairs(C.order) do if e == el then table.remove(C.order, i) break end end
    C.handleOf[h] = nil
    C.removedHandle[h] = el.id
    if w and el.place.corner then restackCorner(el.place.corner) end
end

function X.isShown(h)
    C.enter("text.isShown")
    local el = C.element(h, "text.isShown")
    if not el.visible or el.nearAbsent or not el.ref then return false end
    local w = C.deref(el.ref)
    if not w then return false end
    local hud, _, vis = H._poll()
    if not hud or not C.drawn(vis) then return false end
    local canvas = canvasOf(hud)
    if not canvas then return false end
    local okP, p = pcall(function() return w:GetParent() end)
    if not (okP and C.valid(p) and p:GetAddress() == canvas:GetAddress()) then return false end
    return C.drawn(tonumber(w:GetVisibility()) or 0)
end

-- UI-3: place(handle, intent). Pending: stores the intent; attach applies it. Live: re-places now.
P.place = function(h, intent)
    C.enter("place")
    local el = C.element(h, "place")
    local pl = P.validate(intent)
    local oldCorner = el.place.corner
    el.place = pl
    el.slotKey, el.nearAbsent = nil, false
    if el.ref and C.deref(el.ref) then
        local hud = H._poll()
        local canvas = hud and canvasOf(hud)
        if canvas then
            if oldCorner and oldCorner ~= pl.corner then pcall(P.restack, oldCorner, liveIn(canvas), true) end
            placeAll(hud, canvas, true)
        end
    elseif not el.attached then
        attachNow(el, "place")
    end
end

function X.stats()
    local n = 0
    for _ in pairs(C.els) do n = n + 1 end
    return { elements = n, uobjectCalls = C.stats.uobjectCalls, attachCreated = C.stats.attachCreated,
        attachReused = C.stats.attachReused, handlesFreed = C.stats.handlesFreed, findAllCalls = C.stats.findAllCalls }
end

-- The tag a widget of this mod's element carries (for tests and diagnostics).
function X.tagOf(id) return tagOf(id) end

X._validId, X._validText = validId, validText
return X
