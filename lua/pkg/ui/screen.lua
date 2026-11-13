-- Story 21 (Mod Manager story 2): the screen host, full-screen windows above the title-screen menu that form a stack.
-- Exposed as core.ui.screen on the connect API:
--   open{ id = <string>, close = <boolean|nil> } -> window   opens (or, already open, returns) the window id
--   close(window)                closes it and every window above it (those with reason "parent")
--   isOpen(window) -> boolean    top() -> window | nil (this mod's top window)
--   watch(fn) -> token           fn(window, info), info = { event = opened | closed | lost, id, reason }; closed's
--                                reason: "close" (its Close button), "api" (screen.close), "parent" (a window below it
--                                closed); lost: the menu went (a map change)
--   unwatch(token)
-- Elements go on a window with place = { screen = <window>, corner | absolute }.
--
-- A window is a core-generated WBP_<Core>Screen added to the viewport above everything open: a hit-testable dark
-- backdrop over the whole viewport (it blocks the menu and every window below) and a full-screen canvas for elements.
-- Only the top window takes input: windows below it are made non-hit-testable (HitTestInvisible) until the ones above
-- close, and the new top window gets keyboard focus (SetInputMode_UIOnlyEx + SetKeyboardFocus). A close gives focus to
-- the next window down, else back to the menu, the way the game's own level script gives it (research 1.1). With
-- close = true (the default) core puts its own Close button, in the game's look and the game's language, top-right.
-- Windows open only while the menu host is open; the menu's loss closes them all (lost). A window's elements stay
-- created across closes and attach again on the next open of the same id. At most 8 windows open per dependent.
-- Across dependents a later window sits above (a shared Z counter); each dependent's focus goes back to its own next
-- window, else the menu. Escape doesn't close windows yet (a later story's).
local BASE = (...):gsub("%.ui%.screen$", "")
local C = require(BASE .. ".ui.common")
local M = require(BASE .. ".ui.menu")
local X = require(BASE .. ".ui.text")
local B = require(BASE .. ".ui.button")
local S = require(BASE .. ".ui.strings")
local A = require(BASE .. ".ui.assets")
local theme = require(BASE .. ".ui.theme")

local SC = {}
SC.MAX_OPEN = 8
SC.MAX_IDS = 64
local Z_BASE = 100
local Z_KEY = C.LOWER .. ".ui.screenZ"
local CLOSE_POS = { x = -32, y = 32 }
local INPUT_DO_NOT_LOCK = 0          -- EMouseLockMode::DoNotLock

local order = {}                     -- open window ids of this dependent, bottom first
local T = { opens = 0, closes = 0, lost = 0 }

-- ---------------------------------------------------------------- helpers (game thread)

local function wbl() return C.found("/Script/UMG.Default__WidgetBlueprintLibrary") end
local function widgetOf(rec)
    if not (rec and rec.ref) then return nil end
    local ok, w = pcall(C.deref, rec.ref)
    return ok and w or nil
end
local function ownerOf(mm)
    local ok, pc = pcall(C.call0, mm, "GetOwningPlayer")
    if ok and C.valid(pc) then return pc end
    local okW, p = pcall(function()
        return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(mm:GetWorld(), 0)
    end)
    return okW and C.valid(p) and p or nil
end
local function indexOf(id)
    for i, v in ipairs(order) do if v == id then return i end end
    return nil
end

-- The next Z above every window open in any dependent's Lua state (UE4SS shared variables cross Lua states).
local function nextZ()
    local ok, z = pcall(function() return ModRef:GetSharedVariable(Z_KEY) end)
    z = ok and tonumber(z) or nil
    if not z or z ~= z or z < Z_BASE or z > 1000000 then z = Z_BASE end
    z = math.floor(z) + 1
    pcall(function() ModRef:SetSharedVariable(Z_KEY, z) end)
    return z
end

-- Only the top window takes input: Visible on top, HitTestInvisible below.
local function setTop(rec, top)
    local w = widgetOf(rec)
    if w then pcall(function() w:SetVisibility(top and C.VIS.Visible or C.VIS.HitTestInvisible) end) end
end

local function focusWindow(rec)
    local w = widgetOf(rec)
    if not w then return end
    local mm = M._poll()
    local pc = mm and ownerOf(mm)
    if pc then pcall(function() wbl():SetInputMode_UIOnlyEx(pc, w, INPUT_DO_NOT_LOCK, false) end) end
    pcall(C.call0, w, "SetKeyboardFocus")
end

-- Focus back to the menu, as NewMainMenu's level script gives it (research 1.1).
local function focusMenu()
    local mm = M._poll()
    if not mm then return end
    local pc = ownerOf(mm)
    if pc then pcall(function() wbl():SetInputMode_UIOnlyEx(pc, mm, INPUT_DO_NOT_LOCK, true) end) end
    pcall(C.call0, mm, "SetKeyboardFocus")
end

-- ---------------------------------------------------------------- watchers

local watchers = {}
local issued = {}
local nextToken = 0

local function dispatch(rec, info)
    local list = {}
    for i, w in ipairs(watchers) do list[i] = w end
    for _, w in ipairs(list) do
        if not w.dead then
            local ok, err = pcall(w.fn, rec and rec.handle or nil, info)
            if not ok and not w.warned then
                w.warned = true
                if C.log then C.log.warn("screen watcher %d: %s", w.token, tostring(err):match("^[^\n]*")) end
            end
        end
    end
    for i = #watchers, 1, -1 do if watchers[i].dead then table.remove(watchers, i) end end
end

-- ---------------------------------------------------------------- open and close

local closeById -- below

-- Core's Close button, top-right in the window's canvas, in the game's look with core's localized label.
local function addCloseButton(rec, mm, canvas)
    local cls = X._classOf("button")
    if not cls then C.warnOnce("close class", "window '%s': the Close button's class is not loaded; the window has no Close button", rec.id) return end
    local owner = ownerOf(mm)
    local b = wbl():Create(mm, cls, owner)
    if not C.valid(b) then return end
    local id = rec.id
    pcall(function() b:SetTag(C.LOWER .. ":" .. C.modTag .. ":#close:" .. id) end)
    pcall(function() b:SetLabel(S.core("close")) end)
    B._styleGame(b)
    pcall(function() b:SetVisibility(C.VIS.SelfHitTestInvisible) end)
    local okA, slot = pcall(function() return canvas:AddChildToCanvas(b) end)
    if okA and C.valid(slot) then
        pcall(function()
            slot:SetAutoSize(true)
            slot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
            slot:SetAlignment({ X = 1, Y = 0 })
            slot:SetPosition({ X = CLOSE_POS.x, Y = CLOSE_POS.y })
            slot:SetZOrder(1000)
        end)
    end
    B._internal["#close:" .. id] = function() closeById(id, "close") end
    B._ensureHook()
end

local function closeOne(rec, reason, event)
    local i = indexOf(rec.id)
    if i then table.remove(order, i) end
    X._detachHost(C.windowHost(rec.id))
    local w = widgetOf(rec)
    if w then pcall(C.call0, w, "RemoveFromParent") end
    if rec.ref then pcall(C.free, rec.ref) end
    rec.ref, rec.open = nil, false
    if event == "lost" then T.lost = T.lost + 1 else T.closes = T.closes + 1 end
    dispatch(rec, { event = event or "closed", id = rec.id, reason = reason })
end

-- Closes a window and every window above it (top first, reason "parent"), then gives focus to the next window down,
-- else to the menu.
local function closeRec(rec, reason)
    local idx = indexOf(rec.id)
    if not idx then return end
    for i = #order, idx + 1, -1 do
        local above = C.windows[order[i]]
        if above then closeOne(above, "parent") end
    end
    closeOne(rec, reason)
    local top = order[#order] and C.windows[order[#order]] or nil
    if top then setTop(top, true); focusWindow(top) else focusMenu() end
end
closeById = function(id, reason)
    local rec = C.windows[id]
    if rec and rec.open then closeRec(rec, reason) end
end

-- Every window lost with the menu (top first).
local function loseAll(reason)
    for i = #order, 1, -1 do
        local rec = C.windows[order[i]]
        if rec then closeOne(rec, reason, "lost") end
    end
    order = {}
end

local watchingMenu = false
local function ensureMenu()
    if watchingMenu then return end
    watchingMenu = true
    M._watch(function(_, info)
        if info.event == "lost" then loseAll("the menu is gone (" .. tostring(info.reason) .. ")") end
    end)
    -- A window widget that is gone while open (another mod removed it): lost.
    M._ticker(function()
        for i = #order, 1, -1 do
            local rec = C.windows[order[i]]
            if rec then
                local w = widgetOf(rec)
                if w then X._tickHost(C.windowHost(rec.id), w)
                else
                    closeOne(rec, "its widget is gone", "lost")
                    if #order > 0 then local top = C.windows[order[#order]] setTop(top, true) end
                end
            end
        end
    end)
end

local function newHandle(id)
    return setmetatable({}, {
        __index = { id = id },
        __newindex = function() error(C.UI .. ".screen: window handles are read-only", 2) end,
        __metatable = "window handle",
        __tostring = function() return "window '" .. id .. "'" end,
    })
end

local OPEN_KEYS = { id = true, close = true }

function SC.open(opts, ...)
    C.enter("screen.open")
    local pre = C.UI .. ".screen.open"
    if type(opts) ~= "table" then C.fail("%s: expected a table { id = ..., close = ... }, got %s", pre, C.describe(opts)) end
    if select("#", ...) > 0 then C.fail("%s: expected 1 argument (a table), got %d", pre, 1 + select("#", ...)) end
    for k in pairs(opts) do
        if not OPEN_KEYS[k] then C.fail("%s: unknown key %s (valid: close, id)", pre, C.describe(k)) end
    end
    local id = X._validId(opts.id, "screen.open")
    if opts.close ~= nil and type(opts.close) ~= "boolean" then C.fail("%s: close must be a boolean or nil, got %s", pre, C.describe(opts.close)) end
    if M._inHook then C.fail("%s: called inside the menu's Construct", pre) end
    ensureMenu()
    local mm = M._poll()
    if not mm then C.fail("%s: the title-screen menu is not open (windows open only over it)", pre) end
    local rec = C.windows[id]
    if rec and rec.open and widgetOf(rec) then return rec.handle end
    if #order >= SC.MAX_OPEN then C.fail("%s: this mod already has %d windows open (at most %d)", pre, #order, SC.MAX_OPEN) end
    if not rec then
        local n = 0
        for _ in pairs(C.windows) do n = n + 1 end
        if n >= SC.MAX_IDS then C.fail("%s: this mod already has %d window ids (at most %d)", pre, n, SC.MAX_IDS) end
        rec = { id = id, handle = newHandle(id), open = false }
        C.windows[id] = rec
        C.windowOf[rec.handle] = rec
    end
    rec.close = opts.close ~= false
    local cls = X._classOf("screen")
    if not cls then C.fail("%s: %s is not loaded (is Content/Paks/LogicMods/%s.pak installed?)", pre, C.SCREEN_CLASS, C.NAME) end
    A.ensureLoadMapHook()
    local w = wbl():Create(mm, cls, ownerOf(mm))
    if not C.valid(w) then C.fail("%s: creating %s failed", pre, C.SCREEN_SHORT) end
    pcall(function() w:SetTag(C.LOWER .. ":" .. C.modTag .. ":#screen:" .. id) end)
    pcall(function() w:SetIsFocusable(true) end)
    local bd = theme.backdrop
    pcall(function() w:SetBackdrop(bd.r, bd.g, bd.b, bd.a) end)
    rec.z = nextZ()
    w:AddToViewport(rec.z)
    rec.ref = C.ref(w)
    rec.open = true
    for _, oid in ipairs(order) do setTop(C.windows[oid], false) end
    order[#order + 1] = id
    setTop(rec, true)
    local okC, canvas = pcall(C.prop, w, "Canvas")
    if okC and C.valid(canvas) then
        if rec.close then
            local ok, err = pcall(addCloseButton, rec, mm, canvas)
            if not ok then C.warnOnce("close button", "window '%s': its Close button failed: %s", id, tostring(err):match("^[^\n]*")) end
        end
        X._attachHost(C.windowHost(id), w, canvas, "window opened")
    else
        C.warnOnce("screen canvas", "window '%s': its widget has no Canvas (is %s's pak current?); its elements stay pending", id, C.NAME)
    end
    focusWindow(rec)
    T.opens = T.opens + 1
    dispatch(rec, { event = "opened", id = id, reason = "screen.open" })
    return rec.handle
end

local function windowArg(h, fn)
    if type(h) ~= "table" then C.fail("%s.screen.%s: expected a window handle, got %s", C.UI, fn, C.describe(h)) end
    local rec = C.windowOf[h]
    if not rec then C.fail("%s.screen.%s: not a window handle (use the handle that screen.open returned)", C.UI, fn) end
    return rec
end

function SC.close(h, ...)
    C.enter("screen.close")
    local rec = windowArg(h, "close")
    if select("#", ...) > 0 then C.fail("%s.screen.close: expected 1 argument (window), got %d", C.UI, 1 + select("#", ...)) end
    if rec.open then closeRec(rec, "api") end
end

function SC.isOpen(h, ...)
    C.enter("screen.isOpen")
    local rec = windowArg(h, "isOpen")
    if select("#", ...) > 0 then C.fail("%s.screen.isOpen: expected 1 argument (window), got %d", C.UI, 1 + select("#", ...)) end
    return rec.open == true and widgetOf(rec) ~= nil
end

function SC.top(...)
    C.enter("screen.top")
    if select("#", ...) > 0 then C.fail("%s.screen.top: expected 0 arguments, got %d", C.UI, select("#", ...)) end
    local id = order[#order]
    return id and C.windows[id] and C.windows[id].handle or nil
end

function SC.watch(fn, ...)
    C.enter("screen.watch")
    if type(fn) ~= "function" then C.fail("%s.screen.watch: fn must be a function, got %s", C.UI, C.describe(fn)) end
    if select("#", ...) > 0 then C.fail("%s.screen.watch: expected 1 argument (fn), got %d", C.UI, 1 + select("#", ...)) end
    ensureMenu()
    nextToken = nextToken + 1
    watchers[#watchers + 1] = { token = nextToken, fn = fn }
    issued[nextToken] = true
    return nextToken
end

function SC.unwatch(token, ...)
    C.enter("screen.unwatch")
    if math.type(token) ~= "integer" then C.fail("%s.screen.unwatch: token must be an integer, got %s", C.UI, C.describe(token)) end
    if select("#", ...) > 0 then C.fail("%s.screen.unwatch: expected 1 argument (token), got %d", C.UI, 1 + select("#", ...)) end
    if not issued[token] then C.fail("%s.screen.unwatch: unknown token %d (not one screen.watch returned)", C.UI, token) end
    for _, w in ipairs(watchers) do if w.token == token then w.dead = true end end
    for i = #watchers, 1, -1 do if watchers[i].dead then table.remove(watchers, i) end end
end

function SC.stats() return { open = #order, opens = T.opens, closes = T.closes, lost = T.lost } end

-- For unit tests only.
function SC._order() return order end
SC._closeById, SC._loseAll = function(id, reason) return closeById(id, reason) end, loseAll
return SC
