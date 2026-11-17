-- Core story 31 (UI-13, core 0.13.0): the game's own menu screens as hosts, keyed by host name. Exposed as
-- core.ui.game on the connect API:
--   watch(host, fn) -> token     fn(screen, info), info = { event, host, path, reason }; event is opened, closed or lost
--                                (screen is nil for closed and lost). VALID ONLY UNTIL THE CURRENT CALLBACK RETURNS:
--                                never store it.
--   unwatch(token)               a token game.watch never issued raises; one it issued is removed (again: nothing)
--   isOpen(host) -> boolean      a screen of that host, of the local player, is in the viewport
-- host is a game screen's name: "createServer" (/Game/Graphics/MainMenu/CreateServer.CreateServer_C) is the first and
-- only one (common.lua, C.GAME_SCREENS: a later screen is one entry there plus its checks). The same names are
-- placement hosts (text.lua): elements placed there get new widgets in the screen's root CanvasPanel on every open.
--
-- The create-server screen is built new on every open from the menu's START GAME, removed by Back and destroyed by the
-- map change after Create. Screens are learned the menu's way (menu.lua): NotifyOnNewObject records a path and a weak
-- handle, one seed FindAllOf per host and Lua state, and the shared 500 ms poll (hud.lua) re-finds them by weak
-- handle. No UObject is kept. Poll-first (story 34): nothing is decided or attached inside any of the game's hooks; no
-- hook is registered on the screen's class at all. opened, and so the elements, arrive within about a second (one or
-- two 500 ms ticks) of the screen appearing.
--
-- Events per host: opened (the first tick that sees a local player's screen in the viewport), closed (it left the
-- viewport but still exists: Back), lost (its object is gone, or a newer screen replaced it). At most one event per
-- host per tick: a screen replaced by another gives lost now, opened on the next tick. A watcher added while a screen
-- is open hears a synthetic opened on the next tick; a dependent's watcher that never heard opened hears no closed or
-- lost.
local BASE = (...):gsub("%.ui%.game$", "")
local C = require(BASE .. ".ui.common")
local H = require(BASE .. ".ui.hud")

local G = {}
local MAX_PATHS = 8

-- ---- per host: the tracked screens, oldest first (path -> { h = weak handle, owner }), and the poll's state.
local ST = {}
local ORDER = {}                 -- host names, sorted: the order of the poll and the dispatch
for host in pairs(C.GAME_SCREENS) do
    ORDER[#ORDER + 1] = host
    ST[host] = { paths = {}, rec = {}, seeded = false, notified = false, okNotify = nil, errNotify = nil, active = false,
        path = nil, pending = nil, cur = nil }
end
table.sort(ORDER)

local function spec(host) return C.GAME_SCREENS[host] end

local function isTemplate(host, p)
    local pkg = spec(host).pkg
    return p:find("Default__", 1, true) ~= nil or p:sub(1, #pkg + 1) == pkg .. "."
end

local function forget(st, i)
    local p = st.paths[i]
    local r = st.rec[p]
    if r and r.h and C.free then pcall(C.free, r.h) end
    st.rec[p] = nil
    table.remove(st.paths, i)
end

local function track(host, p, obj)
    local st = ST[host]
    if type(p) ~= "string" or st.rec[p] or isTemplate(host, p) then return end
    if #st.paths >= MAX_PATHS then
        for i = 1, #st.paths do
            if st.paths[i] ~= st.path then forget(st, i) break end
        end
    end
    local r = {}
    if obj and C.ref then
        local ok, h = pcall(C.ref, obj)
        if ok then r.h = h end
    end
    if not r.h then return end -- no natives yet (before connect)
    st.paths[#st.paths + 1] = p
    st.rec[p] = r
end

-- Learn new screens from their creation (only the path and a weak handle; nothing is called on the widget, which is
-- still being constructed). Registered at the first use of the host in this Lua state. Never returns true.
local function ensureNotify(host)
    local st = ST[host]
    if st.notified then return end
    st.notified = true
    st.okNotify, st.errNotify = pcall(NotifyOnNewObject, spec(host).class, function(obj)
        pcall(function() track(host, C.pathOf(obj), obj) end)
        return false
    end)
end

local function seed(host)
    local st = ST[host]
    if st.seeded then return end
    st.seeded = true
    ensureNotify(host)
    local short = spec(host).short
    C.stats.gameFindAllCalls = (C.stats.gameFindAllCalls or 0) + 1
    local n = 0
    for _, w in ipairs(FindAllOf(short) or {}) do
        if C.valid(w) then n = n + 1; track(host, C.pathOf(w), w) end
    end
    if C.log then C.log.debug("game %s seed FindAllOf(%s) found %d screen(s); new ones come from their creation callback%s",
        host, short, n, st.okNotify ~= false and "" or (" (NOT registered: " .. tostring(st.errNotify) .. ")")) end
end

-- ---- reading one screen (inside the game-thread callback that found it). Every object read from a property is checked
-- with C.valid before any method is called on it.
local function inViewportOf(w) return w:IsInViewport() end
local function ownerOf(w)
    local pc = w:GetOwningPlayer()
    if not C.valid(pc) then return nil end -- created with no owner: the local player's anyway
    return pc:IsLocalController() == true
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

-- The host canvas: the screen's root widget (WidgetTree.RootWidget) when it is a CanvasPanel (CanvasPanel_21 on the
-- create-server screen), else nil (one WARN per host and Lua state).
function G._canvasOf(host, obj)
    local ok, root = pcall(function() return obj.WidgetTree.RootWidget end)
    if not (ok and C.valid(root)) then
        C.warnOnce("game noroot " .. host, "the %s screen has no root widget; its elements stay pending", host)
        return nil
    end
    if not isA(root, "/Script/UMG.CanvasPanel") then
        C.warnOnce("game notcanvas " .. host, "the %s screen's root is %s, not a CanvasPanel; its elements stay pending", host, className(root))
        return nil
    end
    return root
end

-- ---- the poll: the newest live screen of the local player in the viewport. Returns screen, path. Paths whose screen
-- is gone are dropped.
local function pollOpen(host)
    local st = ST[host]
    local hit, hitPath
    for i = #st.paths, 1, -1 do
        local p = st.paths[i]
        local r = st.rec[p]
        local okD, w = pcall(C.deref, r and r.h)
        if not (okD and w) then
            forget(st, i)
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

-- ---- the watchers (every host in one list; tokens are unique across hosts)
local watchers = {}              -- { token, host, fn, internal, needOpened, dead, warned }
local issued = {}                -- token -> true for the dependent's own watchers
local nextToken = 0
local tickers = {}               -- host -> { internal fn(screen) per tick while a screen is open, on ticks without an event }

local function deliver(w, s, info)
    if w.dead then return end
    local ok, err = pcall(w.fn, s, info)
    if not ok and not w.warned then
        w.warned = true
        if C.log then C.log.warn("game watcher %d (%s): %s", w.token, w.host, tostring(err):match("^[^\n]*")) end
    end
end

local function compact()
    for i = #watchers, 1, -1 do if watchers[i].dead then table.remove(watchers, i) end end
end

-- Internal watchers (core's elements) first, then the dependent's: a dependent hearing opened finds the elements
-- already there. onlyFresh: a synthetic opened for watchers that haven't heard one.
local function dispatch(host, s, info, onlyFresh)
    local list = {}
    for _, w in ipairs(watchers) do if w.host == host and w.internal then list[#list + 1] = w end end
    for _, w in ipairs(watchers) do if w.host == host and not w.internal then list[#list + 1] = w end end
    for _, w in ipairs(list) do
        if not w.dead then
            if info.event == "opened" then
                if not onlyFresh or w.needOpened then w.needOpened = false; deliver(w, s, info) end
            elseif not w.needOpened or w.internal then
                -- core's own watchers hear every event; the screen goes only with opened
                deliver(w, nil, info)
            end
        end
    end
    compact()
end

-- At most one event per host per tick. s, p: the screen the poll found (nil, nil: none). A screen replaced by another
-- one gives lost now, opened next tick; one that left the viewport but is still tracked (alive) gives closed.
local function decide(host, s, p)
    local st = ST[host]
    if st.path then
        if p == st.path then return nil end
        local was = st.path
        st.path = nil
        if p then return { event = "lost", host = host, path = was, reason = "a newer " .. host .. " screen replaced it" } end
        if st.rec[was] then return { event = "closed", host = host, path = was, reason = "the screen left the viewport" } end
        return { event = "lost", host = host, path = was, reason = "the screen is gone (a map change)" }
    end
    if not s then return nil end
    st.path = p
    return { event = "opened", host = host, path = p, reason = host .. " screen opened" }
end

local function pollStep()
    for _, host in ipairs(ORDER) do
        local st = ST[host]
        if st.active then
            seed(host)
            local s, p = pollOpen(host)
            st.pending = decide(host, s, p)
            st.cur = s
        end
    end
end

local function dispatchStep()
    local ev = nil
    for _, host in ipairs(ORDER) do
        local st = ST[host]
        if st.active then
            local info, s = st.pending, st.cur
            st.pending, st.cur = nil, nil
            if info then
                dispatch(host, info.event == "opened" and s or nil, info, false)
                ev = ev or ("game " .. host .. " " .. info.event)
            elseif s and st.path then
                local fresh = false
                for _, w in ipairs(watchers) do if w.host == host and w.needOpened and not w.dead then fresh = true break end end
                if fresh then
                    ev = ev or ("game " .. host .. " opened (late watcher)")
                    dispatch(host, s, { event = "opened", host = host, path = st.path, reason = "late watcher: screen already open" }, true)
                end
                for _, f in ipairs(tickers[host] or {}) do
                    local ok, err = pcall(f, s)
                    if not ok then C.warnOnce("game ticker " .. host, "game %s tick work failed: %s (further failures not logged)", host, tostring(err):match("^[^\n]*")) end
                end
            end
        end
    end
    return ev
end

local function reset()
    for _, host in ipairs(ORDER) do
        local st = ST[host]
        st.path, st.pending, st.cur = nil, nil, nil
    end
end

local registered = false
local keepToken = nil
-- The first watch or element of a host: its creation callback, the poll (joined to hud.lua's loop) and the loop kept
-- running without a HUD watcher.
local function activate(host)
    ST[host].active = true
    if not registered then
        registered = true
        H._host{ poll = pollStep, dispatch = dispatchStep, reset = reset }
    end
    ensureNotify(host)
    if not keepToken then keepToken = H._keep() end
end

local function addWatcher(host, fn, internal)
    activate(host)
    nextToken = nextToken + 1
    local w = { token = nextToken, host = host, fn = fn, internal = internal, needOpened = true }
    watchers[#watchers + 1] = w
    if not internal then issued[w.token] = true end
    return w.token
end

-- ---- public: watch, unwatch, isOpen
local function checkHost(host, fn)
    if not C.gameScreen(host) then
        C.fail("%s.game.%s: unknown game screen %s (valid: %s)", C.UI, fn, C.describe(host), C.GAME_SCREEN_NAMES)
    end
end

function G.watch(host, fn, ...)
    C.enter("game.watch")
    checkHost(host, "watch")
    if type(fn) ~= "function" then C.fail("%s.game.watch: fn must be a function, got %s", C.UI, C.describe(fn)) end
    if select("#", ...) > 0 then C.fail("%s.game.watch: expected 2 arguments (host, fn), got %d", C.UI, 2 + select("#", ...)) end
    return addWatcher(host, fn, false)
end

function G.unwatch(token, ...)
    C.enter("game.unwatch")
    if math.type(token) ~= "integer" then C.fail("%s.game.unwatch: token must be an integer, got %s", C.UI, C.describe(token)) end
    if select("#", ...) > 0 then C.fail("%s.game.unwatch: expected 1 argument (token), got %d", C.UI, 1 + select("#", ...)) end
    if not issued[token] then C.fail("%s.game.unwatch: unknown token %d (not one game.watch returned)", C.UI, token) end
    for _, w in ipairs(watchers) do
        if w.token == token and not w.internal then w.dead = true end
    end
    compact()
end

function G.isOpen(host, ...)
    C.enter("game.isOpen")
    checkHost(host, "isOpen")
    if select("#", ...) > 0 then C.fail("%s.game.isOpen: expected 1 argument (host), got %d", C.UI, 1 + select("#", ...)) end
    seed(host)
    return pollOpen(host) ~= nil
end

-- ---- internal (text.lua)
function G._watch(host, fn) return addWatcher(host, fn, true) end
function G._ticker(host, fn)
    activate(host)
    tickers[host] = tickers[host] or {}
    table.insert(tickers[host], fn)
end
-- The live screen now (valid only in this callback) and its path, or nil.
function G._poll(host) seed(host) return pollOpen(host) end
-- The screen the host has open (path), as of the last tick; nil while none.
function G._openNow(host) return ST[host] and ST[host].path or nil end

-- For unit tests only.
G._ST, G._decide, G._track, G._MAX_PATHS = ST, decide, track, MAX_PATHS
function G._resetForTests()
    for _, host in ipairs(ORDER) do
        local st = ST[host]
        for i = #st.paths, 1, -1 do forget(st, i) end
        st.path, st.pending, st.cur = nil, nil, nil
    end
end
return G
