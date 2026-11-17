-- Story 21 (Mod Manager story 2): the title-screen menu as a host. Exposed as core.ui.menu on the connect API:
--   entry{ id, label, onClick, style } -> handle    a button in the game's own column (entry.lua)
--   removeEntry(handle)                             (entry.lua)
--   isOpen() -> boolean          a MainMenu_C of the local player is in the viewport
--   watch(fn) -> token           fn(menu, info), info = { event, reason, path }; event is opened, hidden, shown or lost
--                                (menu is nil for lost). VALID ONLY UNTIL THE CURRENT CALLBACK RETURNS: never store it.
--   unwatch(token)               a token menu.watch never issued raises; one it issued is removed (again: nothing)
--
-- The host canvas is page 0 (CanvasPanel_17) of the menu's root WidgetSwitcher (WidgetSwitcher_1): the main page
-- with the button column. Every return from a match builds a new MainMenu_C (a full OpenLevel), and the first one
-- exists only after the press-any-key screen (UI_Startup_C), so menus are learned the Journal's way: NotifyOnNewObject
-- records a path and a weak handle, one seed FindAllOf per Lua state, and the shared 500 ms poll (hud.lua) re-finds
-- them by weak handle. No UObject is kept.
--
-- Events: opened (the first tick that sees a menu in the viewport), hidden / shown (its render opacity below 0.01, as
-- under Create Server and Server List, or another page of the switcher active, and back), lost (it left the viewport
-- or was destroyed: a map change). While hidden, every menu element is collapsed (a transparent button would still
-- take clicks); the entry lives in the game's column and hides with it.
--
-- Hooks (CommonButtonBase:HandleButtonClicked, and a MainMenu_C:Construct post-hook only when a want asks for it) are
-- registered from a poll tick once a MainMenu_C exists, never at startup: both host launches of the mini-spike that
-- registered hooks earlier crashed at the first menu (research 9.3; the cause was a GetFName on a null property, 9.1,
-- but registering after the menu exists is the order proven in every VM launch). Every menu gets its entry and
-- elements from the poll's opened, within about a second (one or two 500 ms ticks) of the menu appearing. No user
-- asks for Construct today (story 34): widget work inside it, under the game's own CreateWidget/AddToViewport right
-- after a world teardown and GC, once read a freed object and crashed the game; the machinery stays as a tested
-- opt-in. UE4SS keys a script hook by the function's name chain (LuaMod.cpp, find_function_hook_data), so one
-- registration also fires for the class reloaded after a match.
local BASE = (...):gsub("%.ui%.menu$", "")
local C = require(BASE .. ".ui.common")
local H = require(BASE .. ".ui.hud")

local M = {}
local MAX_PATHS = 8
local CONSTRUCT_FN = C.MENU_CLASS .. ":Construct"
local CLICK_FN = "/Script/CommonUI.CommonButtonBase:HandleButtonClicked"

-- ---- tracked menus: path -> { h = weak handle, owner (nil = not asked yet, true, false) }
local paths = {}                 -- oldest first
local rec = {}
local seeded, notified = false, false
local okNotify, errNotify = nil, nil

local function isTemplate(p)
    return p:find("Default__", 1, true) ~= nil or p:sub(1, #C.MENU_PKG + 1) == C.MENU_PKG .. "."
end

local function forget(i)
    local p = paths[i]
    local r = rec[p]
    if r and r.h and C.free then pcall(C.free, r.h) end
    rec[p] = nil
    table.remove(paths, i)
end

local function track(p, obj)
    if type(p) ~= "string" or rec[p] or isTemplate(p) then return end
    if #paths >= MAX_PATHS then
        for i = 1, #paths do
            if paths[i] ~= M._openPath then forget(i) break end
        end
    end
    local r = {}
    if obj and C.ref then
        local ok, h = pcall(C.ref, obj)
        if ok then r.h = h end
    end
    if not r.h then return end -- no natives yet (before connect)
    paths[#paths + 1] = p
    rec[p] = r
end
M._track = track

-- Learn new menus from their creation (only the path and a weak handle; nothing is called on the widget). Registered
-- at the first use of the menu host in this Lua state, before the first menu exists. Never returns true.
local function ensureNotify()
    if notified then return end
    notified = true
    okNotify, errNotify = pcall(NotifyOnNewObject, C.MENU_CLASS, function(obj)
        pcall(function() track(C.pathOf(obj), obj) end)
        return false
    end)
end

local function seed()
    if seeded then return end
    seeded = true
    ensureNotify()
    C.stats.menuFindAllCalls = (C.stats.menuFindAllCalls or 0) + 1
    local n = 0
    for _, w in ipairs(FindAllOf(C.MENU_SHORT) or {}) do
        if C.valid(w) then n = n + 1; track(C.pathOf(w), w) end
    end
    if C.log then C.log.debug("menu seed FindAllOf(%s) found %d menu(s); new ones come from their creation callback%s",
        C.MENU_SHORT, n, okNotify ~= false and "" or (" (NOT registered: " .. tostring(errNotify) .. ")")) end
end

-- ---- reading one menu (inside the game-thread callback that found it). Every object read from a property is checked
-- with C.valid before any method is called on it (a method on a null object reads address 0x18 and crashes the game,
-- research 9.1).
local function inViewportOf(w) return w:IsInViewport() end
local function ownerOf(w)
    local pc = w:GetOwningPlayer()
    if not C.valid(pc) then return nil end -- the menu is created with no owner: the local player's anyway
    return pc:IsLocalController() == true
end
M._ownerOf = ownerOf

local function rootOf(m)
    local ok, root = pcall(function() return m.WidgetTree.RootWidget end)
    return ok and C.valid(root) and root or nil
end

local function isA(o, path)
    local cls = C.found(path) -- a hash hit; never kept between calls
    if not cls then return false end
    local ok, yes = pcall(function() return o:IsA(cls) end)
    return ok and yes == true
end

local function className(o)
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end

-- The host canvas: page 0 of the root WidgetSwitcher when it is a CanvasPanel, else nil (one WARN per Lua state).
function M._canvasOf(m)
    local root = rootOf(m)
    if not root then C.warnOnce("menu noroot", "the menu has no root widget; menu elements stay pending") return nil end
    if not isA(root, "/Script/UMG.WidgetSwitcher") then
        C.warnOnce("menu notswitcher", "the menu's root is %s, not a WidgetSwitcher; menu elements stay pending (the entry still inserts)", className(root))
        return nil
    end
    local ok, page = pcall(function() return root:GetWidgetAtIndex(0) end)
    if not (ok and C.valid(page)) then C.warnOnce("menu nopage", "the menu's switcher has no page 0; menu elements stay pending") return nil end
    if not isA(page, "/Script/UMG.CanvasPanel") then
        C.warnOnce("menu notcanvas", "the menu's page 0 is %s, not a CanvasPanel; menu elements stay pending (the entry still inserts)", className(page))
        return nil
    end
    return page
end

-- Whether the menu is hidden now: render opacity below 0.01 (Create Server, Server List), or another page of the
-- root switcher active (clothing, matchmaking, ...).
function M._hiddenOf(m)
    local okO, op = pcall(function() return m:GetRenderOpacity() end)
    if okO and type(op) == "number" and op < 0.01 then return true end
    local root = rootOf(m)
    if root then
        local okI, idx = pcall(function() return root:GetActiveWidgetIndex() end)
        if okI and type(idx) == "number" and idx ~= 0 then return true end
    end
    return false
end

-- ---- the poll: the newest live menu of the local player in the viewport. Returns menu, path. Paths whose menu is gone
-- are dropped.
local function pollOpen()
    local hit, hitPath
    for i = #paths, 1, -1 do
        local p = paths[i]
        local r = rec[p]
        local okD, w = pcall(C.deref, r and r.h)
        if not (okD and w) then
            forget(i)
        elseif not hit then
            local ok, inVp = pcall(inViewportOf, w)
            if ok and inVp then
                if r.owner == nil then
                    local okO, mine = pcall(ownerOf, w)
                    if okO then r.owner = mine end
                end
                if r.owner ~= false then hit, hitPath = w, p end
            end
        end
    end
    return hit, hitPath
end

-- ---- hooks, registered from the poll once a menu exists
local construct = {}             -- internal fn(menu, path) run inside the Construct post-hook (no user today)
-- Never ask for Construct to change a widget tree (story 34 crash: a freed object read inside the menu's Construct
-- after a map change); attach and insert from the poll's opened instead.
local wants = {}                 -- internal fn() -> needConstruct, needClick (text.lua, entry.lua)
local clickers = {}              -- internal fn(widget) run inside the HandleButtonClicked hook (entry.lua)
local HK = { construct = false, click = false, constructKey = nil, tries = 0 }
M._inHook = false

function M._onConstruct(fn) construct[#construct + 1] = fn end
function M._onClick(fn) clickers[#clickers + 1] = fn end
function M._wants(fn) wants[#wants + 1] = fn end

local function constructBody(ctx)
    local m = ctx:get()
    if not C.valid(m) then return end
    if className(m) ~= C.MENU_SHORT then return end
    local okO, mine = pcall(ownerOf, m)
    if okO and mine == false then return end -- a remote player's menu: never ours
    local path = C.pathOf(m)
    track(path, m)
    for _, f in ipairs(construct) do
        local ok, err = pcall(f, m, path)
        if not ok then C.warnOnce("menu construct", "menu Construct hook work failed: %s; the poll handles that menu", tostring(err):match("^[^\n]*")) end
    end
end
local function onConstruct(ctx)
    M._inHook = true
    local ok, err = pcall(constructBody, ctx)
    M._inHook = false
    if not ok then C.warnOnce("menu construct body", "menu Construct hook failed: %s; the poll handles that menu", tostring(err):match("^[^\n]*")) end
end
local function onClick(ctx)
    local ok, err = pcall(function()
        local w = ctx:get()
        if not C.valid(w) then return end
        for _, f in ipairs(clickers) do f(w) end
    end)
    if not ok then C.warnOnce("menu click", "menu click handling failed: %s (further failures not logged)", tostring(err):match("^[^\n]*")) end
end

local function ensureHooks(menuPath)
    local needC, needK = false, false
    for _, f in ipairs(wants) do
        local okW, c, k = pcall(f)
        if okW then needC, needK = needC or c == true, needK or k == true end
    end
    local did = {}
    if needC and not HK.construct then
        local fn = C.found(CONSTRUCT_FN)
        if fn then
            HK.tries = HK.tries + 1
            local okH, err = pcall(RegisterHook, CONSTRUCT_FN, onConstruct)
            if okH then
                HK.construct = true
                local okK, key = pcall(C.addr, fn)
                HK.constructKey = okK and key or nil
                did[#did + 1] = "MainMenu_C:Construct"
            else
                HK.construct = "failed"
                C.warnOnce("menu construct hook", "menu: RegisterHook(%s) failed: %s; the poll handles each menu", CONSTRUCT_FN, tostring(err):match("^[^\n]*"))
            end
        else
            -- Never looked up again: a StaticFindObject miss scans every object (research 8.1, hud.lua).
            HK.construct = "missing"
            C.warnOnce("menu construct fn", "menu: %s not found; the poll handles each menu", CONSTRUCT_FN)
        end
    end
    if needK and not HK.click then
        local okH, err = pcall(RegisterHook, CLICK_FN, onClick)
        if okH then HK.click = true; did[#did + 1] = "CommonButtonBase:HandleButtonClicked"
        else
            HK.click = "failed"
            C.warnOnce("menu click hook", "menu entry: RegisterHook(%s) failed: %s; its clicks are not caught", CLICK_FN, tostring(err):match("^[^\n]*"))
        end
    end
    if #did > 0 and C.log then C.log.info("ui menu hooks registered (%s) after the first menu %s", table.concat(did, ", "), tostring(menuPath)) end
end
function M._hooks() return { construct = HK.construct, click = HK.click, constructKey = HK.constructKey, tries = HK.tries } end

-- ---- the watcher
local watchers = {}              -- { token, fn, internal, needOpened, dead, warned }
local issued = {}
local nextToken = 0
local S = { path = nil, hidden = nil, pending = nil }
local tickers = {}               -- internal fn(menu) per tick while a menu is open, on ticks without an event
local cur = nil

local function deliver(w, m, info)
    if w.dead then return end
    local ok, err = pcall(w.fn, m, info)
    if not ok and not w.warned then
        w.warned = true
        if C.log then C.log.warn("menu watcher %d: %s", w.token, tostring(err):match("^[^\n]*")) end
    end
end

local function compact()
    for i = #watchers, 1, -1 do if watchers[i].dead then table.remove(watchers, i) end end
end

-- Internal watchers (core's elements, the entry, the windows) first, then the dependent's: a dependent hearing opened
-- finds the entry and the elements already there.
local function dispatch(m, info, onlyFresh)
    local list = {}
    for _, w in ipairs(watchers) do if w.internal then list[#list + 1] = w end end
    for _, w in ipairs(watchers) do if not w.internal then list[#list + 1] = w end end
    for _, w in ipairs(list) do
        if not w.dead then
            if info.event == "opened" then
                if not onlyFresh or w.needOpened then w.needOpened = false; deliver(w, m, info) end
            elseif not w.needOpened or w.internal then
                -- core's own watchers hear every event (a window opened after the menu must still hear lost)
                deliver(w, info.event ~= "lost" and m or nil, info)
            end
        end
    end
    compact()
end

-- At most one event per tick. A menu replaced by another one gives lost now, opened next tick.
local function decide(m, p)
    if S.path then
        if p == S.path then
            local hidden = M._hiddenOf(m)
            if hidden ~= S.hidden then
                S.hidden = hidden
                C.hostHidden.menu = hidden or nil
                return { event = hidden and "hidden" or "shown", path = p,
                    reason = hidden and "the menu is hidden (render opacity 0 or another page)" or "the menu shows its main page again" }
            end
            return nil
        end
        local was = S.path
        S.path, S.hidden, M._openPath = nil, nil, nil
        C.hostHidden.menu = nil
        return { event = "lost", path = was, reason = p and "another menu replaced it" or "the menu is gone (a map change)" }
    end
    if not m then return nil end
    S.path, S.hidden, M._openPath = p, M._hiddenOf(m), p
    C.hostHidden.menu = S.hidden or nil
    return { event = "opened", path = p, reason = "menu opened", hidden = S.hidden }
end
M._decide, M._S = decide, S

local function pollStep()
    seed()
    local m, p = pollOpen()
    if m then
        local ok, err = pcall(ensureHooks, p)
        if not ok then C.warnOnce("menu hooks", "menu hooks: %s", tostring(err):match("^[^\n]*")) end
    end
    S.pending = decide(m, p)
    cur = m
end
local function dispatchStep()
    local info, m = S.pending, cur
    S.pending, cur = nil, nil
    local ev = nil
    if info then
        dispatch(info.event ~= "lost" and m or nil, info, false)
        ev = "menu " .. info.event
    elseif m and S.path then
        local fresh = false
        for _, w in ipairs(watchers) do if w.needOpened and not w.dead then fresh = true break end end
        if fresh then
            ev = "menu opened (late watcher)"
            dispatch(m, { event = "opened", reason = "late watcher: menu already open", path = S.path, hidden = S.hidden }, true)
        end
    end
    if m and S.path and not info then
        for _, f in ipairs(tickers) do
            local ok, err = pcall(f, m)
            if not ok then C.warnOnce("menu ticker", "menu tick work failed: %s (further failures not logged)", tostring(err):match("^[^\n]*")) end
        end
    end
    return ev
end
local function reset()
    S.path, S.pending, S.hidden, M._openPath, cur = nil, nil, nil, nil, nil
    C.hostHidden.menu = nil
end

local registered = false
local keepToken = nil
local function addWatcher(fn, internal)
    if not registered then
        registered = true
        H._host{ poll = pollStep, dispatch = dispatchStep, reset = reset }
    end
    ensureNotify()
    nextToken = nextToken + 1
    local w = { token = nextToken, fn = fn, internal = internal, needOpened = true }
    watchers[#watchers + 1] = w
    if not internal then issued[w.token] = true end
    if not keepToken then keepToken = H._keep() end
    return w.token
end

-- ---- public: isOpen, watch, unwatch
function M.isOpen(...)
    C.enter("menu.isOpen")
    if select("#", ...) > 0 then C.fail("%s.menu.isOpen: expected 0 arguments, got %d", C.UI, select("#", ...)) end
    seed()
    return pollOpen() ~= nil
end

function M.watch(fn, ...)
    C.enter("menu.watch")
    if type(fn) ~= "function" then C.fail("%s.menu.watch: fn must be a function, got %s", C.UI, C.describe(fn)) end
    if select("#", ...) > 0 then C.fail("%s.menu.watch: expected 1 argument (fn), got %d", C.UI, 1 + select("#", ...)) end
    return addWatcher(fn, false)
end

function M.unwatch(token, ...)
    C.enter("menu.unwatch")
    if math.type(token) ~= "integer" then C.fail("%s.menu.unwatch: token must be an integer, got %s", C.UI, C.describe(token)) end
    if select("#", ...) > 0 then C.fail("%s.menu.unwatch: expected 1 argument (token), got %d", C.UI, 1 + select("#", ...)) end
    if not issued[token] then C.fail("%s.menu.unwatch: unknown token %d (not one menu.watch returned)", C.UI, token) end
    for _, w in ipairs(watchers) do
        if w.token == token and not w.internal then w.dead = true end
    end
    compact()
end

-- ---- internal (text.lua, entry.lua, screen.lua)
function M._watch(fn) return addWatcher(fn, true) end
function M._ticker(fn) tickers[#tickers + 1] = fn end
-- The live menu now (valid only in this callback) and its path, or nil.
function M._poll() seed() return pollOpen() end
-- The menu the host has open (path), as of the last tick; nil while none.
function M._openNow() return S.path end
function M._hiddenNow() return S.hidden == true end

-- For unit tests only.
M._rec, M._paths, M._onConstructHook, M._onClickHook, M._ensureHooks = rec, paths, onConstruct, onClick, ensureHooks
function M._resetForTests()
    for i = #paths, 1, -1 do forget(i) end
    S.path, S.hidden, S.pending, M._openPath = nil, nil, nil, nil
    HK.construct, HK.click, HK.constructKey, HK.tries = false, false, nil, 0
    C.hostHidden.menu = nil
end
return M
