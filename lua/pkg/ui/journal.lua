-- UI-5 (story 13): the Journal's map page as a host. Exposed as core.ui.journal on the connect API:
--   find() -> journal | nil      the local player's Journal_C while it is in the viewport. VALID ONLY UNTIL THE
--                                current game-thread callback returns: never store it (AGENTS.md, "Blueprint mods").
--   watch(fn) -> token           fn(journal, info), info = { event, reason, path, page }; event is opened, closed or
--                                lost (journal is nil for closed and lost); page is "map" when the map page shows
--   unwatch(token)               a token journal.watch never issued raises; one it issued is removed (again: nothing)
--   isOpen() -> boolean          a Journal of the local player is in the viewport
--   stats() -> table             diagnostic counters (a copy; not part of the semver API)
--
-- The host is the map page: the root canvas of Journal_C.MapWidget (MapWidget_C, the map child of WidgetSwitcher_0),
-- not the whole Journal. Elements placed there show only while the map page does.
--
-- Every map open creates a new Journal_C (V8.1.2: markers' probe, and story 13's real-key check). So Journals are
-- learned from their creation (NotifyOnNewObject records a path and a weak handle; nothing is called on the widget),
-- plus one seed FindAllOf per Lua state at the first watch, and a tick only re-finds the few known ones by weak handle
-- (<Core>_Deref): never StaticFindObject, never a search. A Journal that was shown and then left the viewport is
-- closed for good; only the most recent closed one stays tracked, re-checked every REOPEN_TICKS ticks in case the game
-- ever shows the same one again, and older ones are forgotten. So while the map is closed a tick costs nothing when
-- the game creates the Journal at open, and two engine reads every few ticks otherwise.
--
-- The poll and the events run inside UI-1's poller (hud.lua): one game-thread loop per Lua state, every 500 ms
-- (LoopInGameThreadWithDelay, never LoopAsync + ExecuteInGameThread). An open is accepted on the first tick that sees
-- the Journal in the viewport (the HUD waits two ticks; a map the player opened should show its elements at once).
local BASE = (...):gsub("%.ui%.journal$", "")
local C = require(BASE .. ".ui.common")
local H = require(BASE .. ".ui.hud")

local J = {}
local MAX_PATHS = 8
local REOPEN_TICKS = 4           -- the last closed Journal is re-checked every 4 ticks (2 s)

-- ---- tracked Journals: path -> { h = weak handle, shown, closed, owner (nil = not asked yet, true, false) }
local paths = {}                 -- path strings, oldest first
local rec = {}                   -- path -> record
local lastClosed = nil           -- path of the most recent closed Journal
local seeded = false
local jtick = 0

local function isTemplate(p)
    return p:find("Default__", 1, true) ~= nil or p:sub(1, #C.JOURNAL_PKG + 1) == C.JOURNAL_PKG .. "."
end

local function forget(i)
    local p = paths[i]
    local r = rec[p]
    if r and r.h and C.free then pcall(C.free, r.h) end
    rec[p] = nil
    if lastClosed == p then lastClosed = nil end
    table.remove(paths, i)
end

local function indexOf(p)
    for i = 1, #paths do if paths[i] == p then return i end end
    return nil
end

local function track(p, obj)
    if type(p) ~= "string" or rec[p] or isTemplate(p) then return end
    if #paths >= MAX_PATHS then
        -- Drop the oldest one that isn't the open one (S.path, below) first.
        for i = 1, #paths do
            if paths[i] ~= J._openPath then forget(i) break end
        end
    end
    local r = { shown = false, closed = false }
    if obj and C.ref then
        local ok, h = pcall(C.ref, obj)
        if ok then r.h = h end
    end
    if not r.h then return end -- no natives yet (before connect): a path alone would need StaticFindObject on ticks
    paths[#paths + 1] = p
    rec[p] = r
end

-- Learn new Journals from their creation. Only the path is read and a weak handle taken; nothing is called on the
-- widget, which is still being constructed. Never returns true (that would unregister).
local okNotify, errNotify = pcall(NotifyOnNewObject, C.JOURNAL_CLASS, function(obj)
    pcall(function() track(C.pathOf(obj), obj) end)
    return false
end)

local function seed()
    if seeded then return end
    seeded = true
    local t0 = C.micros and C.micros() or 0
    C.stats.journalFindAllCalls = (C.stats.journalFindAllCalls or 0) + 1
    local n = 0
    for _, w in ipairs(FindAllOf(C.JOURNAL_SHORT) or {}) do
        if C.valid(w) then n = n + 1; track(C.pathOf(w), w) end
    end
    local dt = C.micros and (C.micros() - t0) or 0
    if C.log then C.log.debug("journal seed FindAllOf(%s) found %d Journal(s) in %d us; new ones come from their creation callback%s",
        C.JOURNAL_SHORT, n, dt, okNotify and "" or (" (NOT registered: " .. tostring(errNotify) .. ")")) end
end

-- ---- reading one Journal (call inside the game-thread callback that found it)
local function inViewportOf(w) return w:IsInViewport() end
local function isLocalOwner(w)
    local pc = w:GetOwningPlayer()
    if not C.valid(pc) then return nil end -- between worlds: ask again later
    return pc:IsLocalController() == true
end

-- The map page widget (Journal_C.MapWidget), or nil.
local function mapWidgetOf(j)
    local ok, m = pcall(function() return j.MapWidget end)
    return ok and C.valid(m) and m or nil
end

-- The host canvas: the root CanvasPanel of the map page, or nil (with one WARN naming what was found instead).
function J._canvasOf(j)
    local m = mapWidgetOf(j)
    if not m then C.warnOnce("journal nomap", "the Journal has no MapWidget; journal elements stay pending") return nil end
    local ok, root = pcall(function() return m.WidgetTree.RootWidget end)
    if not (ok and C.valid(root)) then C.warnOnce("journal noroot", "the Journal's MapWidget has no root widget; journal elements stay pending") return nil end
    local canvasClass = C.found("/Script/UMG.CanvasPanel") -- a hash hit; never kept between calls
    local okA, isCanvas = pcall(function() return root:IsA(canvasClass) end)
    if not (okA and isCanvas) then
        local okN, cls = pcall(function() return root:GetClass():GetFName():ToString() end)
        C.warnOnce("journal notcanvas", "the Journal's map page root is %s, not a CanvasPanel; journal elements stay pending", okN and cls or "?")
        return nil
    end
    return root
end

-- Whether the Journal shows its map page: WidgetSwitcher_0's active widget is MapWidget.
function J._mapPageActive(j)
    local ok, yes = pcall(function()
        local sw, m = j.WidgetSwitcher_0, j.MapWidget
        if not (C.valid(sw) and C.valid(m)) then return false end
        local a = sw:GetActiveWidget()
        return C.valid(a) and a:GetAddress() == m:GetAddress()
    end)
    return ok and yes == true
end

-- ---- the poll: the open Journal (in the viewport, owned by the local player), newest first. Returns journal, path.
-- Marks Journals that were shown and left the viewport as closed; keeps only the most recent closed one.
local function pollOpen(skipClosed)
    local hit, hitPath, closedNow
    for i = #paths, 1, -1 do
        local p = paths[i]
        local r = rec[p]
        if r and not (skipClosed and r.closed and p ~= J._openPath) then
            local t = C.pt()
            local okD, w = pcall(C.deref, r.h)
            C.pa("journal.find", t)
            if not (okD and w) then
                forget(i)
            else
                t = C.pt()
                local ok, inVp = pcall(inViewportOf, w)
                C.pa("journal.viewport", t)
                if ok and inVp then
                    if r.owner == nil then
                        local okO, mine = pcall(isLocalOwner, w)
                        if okO then r.owner = mine end
                    end
                    if r.owner ~= false and not hit then hit, hitPath = w, p end
                elseif r.shown and not r.closed then
                    r.closed = true
                    closedNow = closedNow or {}
                    closedNow[#closedNow + 1] = p -- newest first
                end
            end
        end
    end
    if closedNow then
        -- Only the most recent closed Journal stays tracked; older closed ones are forgotten.
        local keep = closedNow[1]
        local drop = {}
        if lastClosed and lastClosed ~= keep then drop[#drop + 1] = lastClosed end
        for k = 2, #closedNow do drop[#drop + 1] = closedNow[k] end
        lastClosed = keep
        for _, p in ipairs(drop) do
            local k = indexOf(p)
            if k then forget(k) end
        end
    end
    return hit, hitPath
end

local function poll()
    jtick = jtick + 1
    return pollOpen(jtick % REOPEN_TICKS ~= 0)
end

-- ---- public: find, isOpen

function J.find(...)
    C.enter("journal.find")
    if select("#", ...) > 0 then C.fail("%s.journal.find: expected 0 arguments, got %d", C.UI, select("#", ...)) end
    seed()
    local j = pollOpen(false)
    return j
end

function J.isOpen(...)
    C.enter("journal.isOpen")
    if select("#", ...) > 0 then C.fail("%s.journal.isOpen: expected 0 arguments, got %d", C.UI, select("#", ...)) end
    seed()
    return pollOpen(false) ~= nil
end

-- ---- the watcher

local watchers = {}              -- list of { token, fn, internal, needOpened, dead, warned }
local issued = {}                -- token -> true for every token journal.watch handed out (forged ones raise)
local nextToken = 0
local S = { path = nil, pending = nil } -- path: the open Journal; pending: the event decided this tick
local T = { opens = 0, closes = 0, lost = 0, attachN = 0, attachSum = 0, attachMax = 0, attachLast = 0, attachEls = 0 }
local tickers = {}               -- internal (text.lua): fn(journal) per tick while a Journal is open

local function deliver(w, j, info)
    if w.dead then return end
    local t = C.pt()
    local ok, err = pcall(w.fn, j, info)
    if t then C.pa(w.internal and "journal.watch.core" or ("journal.watch.dependent#" .. w.token), t) end
    if not ok and not w.warned then
        w.warned = true
        if C.log then C.log.warn("journal watcher %d: %s", w.token, tostring(err):match("^[^\n]*")) end
    end
end

local function compact()
    for i = #watchers, 1, -1 do if watchers[i].dead then table.remove(watchers, i) end end
end

local function dispatch(j, info, onlyFresh)
    local list = {}
    for i, w in ipairs(watchers) do list[i] = w end -- watchers added during dispatch wait for the next tick
    for _, w in ipairs(list) do
        if not w.dead then
            if info.event == "opened" then
                if not onlyFresh or w.needOpened then w.needOpened = false; deliver(w, j, info) end
            elseif not w.needOpened then
                deliver(w, nil, info) -- a watcher that never heard opened gets no closed/lost
            end
        end
    end
    compact()
end

-- The state machine: at most one event per tick. A Journal replaced by another one gives closed now, opened next tick.
local function decide(j, p)
    if S.path then
        if p == S.path then return nil end
        local was = S.path
        S.path, J._openPath = nil, nil
        if rec[was] then
            return { event = "closed", path = was, reason = p and "another Journal opened" or "Journal left the viewport" }
        end
        return { event = "lost", path = was, reason = "Journal gone (destroyed)" }
    end
    if not j then return nil end
    local r = rec[p]
    local again = r and r.shown
    if r then r.shown, r.closed = true, false end
    if lastClosed == p then lastClosed = nil end
    S.path, J._openPath = p, p
    return { event = "opened", path = p, reason = again and "the same Journal opened again" or "Journal opened",
        page = J._mapPageActive(j) and "map" or "other", reopened = again or false }
end

-- Called by hud.lua's tick: poll (timed with the HUD's poll), then dispatch (timed with the watchers).
local cur = nil                  -- the open Journal during one tick only; emptied by dispatchStep
local function pollStep()
    seed()
    local j, p = poll()
    S.pending = decide(j, p)
    cur = j
    if S.pending then
        local e = S.pending.event
        if e == "opened" then T.opens = T.opens + 1 elseif e == "closed" then T.closes = T.closes + 1 else T.lost = T.lost + 1 end
    end
end
local function dispatchStep()
    local info, j = S.pending, cur
    S.pending, cur = nil, nil
    local ev = nil
    if info then
        dispatch(info.event == "opened" and j or nil, info, false)
        ev = "journal " .. info.event
    elseif j and S.path then
        local fresh = false
        for _, w in ipairs(watchers) do if w.needOpened and not w.dead then fresh = true break end end
        if fresh then
            ev = "journal opened (late watcher)"
            dispatch(j, { event = "opened", reason = "late watcher: Journal already open", path = S.path,
                page = J._mapPageActive(j) and "map" or "other", reopened = false }, true)
        end
    end
    -- Per-tick work only on ticks without an event: the tick that opened did the attach (and its log line waits).
    if j and S.path and not info then
        for _, f in ipairs(tickers) do
            local ok, err = pcall(f, j)
            if not ok then C.warnOnce("journal ticker", "journal tick work failed: %s (further failures not logged)", tostring(err):match("^[^\n]*")) end
        end
    end
    return ev
end
local function reset()
    S.path, S.pending, J._openPath, cur = nil, nil, nil, nil
end

local registered = false
local keepToken = nil
local function addWatcher(fn, internal)
    if not registered then
        registered = true
        H._host{ poll = pollStep, dispatch = dispatchStep, reset = reset }
    end
    nextToken = nextToken + 1
    local w = { token = nextToken, fn = fn, internal = internal, needOpened = true }
    watchers[#watchers + 1] = w
    if not internal then issued[w.token] = true end
    if not keepToken then keepToken = H._keep() end
    return w.token
end

function J.watch(fn, ...)
    C.enter("journal.watch")
    if type(fn) ~= "function" then C.fail("%s.journal.watch: fn must be a function, got %s", C.UI, C.describe(fn)) end
    if select("#", ...) > 0 then C.fail("%s.journal.watch: expected 1 argument (fn), got %d", C.UI, 1 + select("#", ...)) end
    return addWatcher(fn, false)
end

function J.unwatch(token, ...)
    C.enter("journal.unwatch")
    if math.type(token) ~= "integer" then C.fail("%s.journal.unwatch: token must be an integer, got %s", C.UI, C.describe(token)) end
    if select("#", ...) > 0 then C.fail("%s.journal.unwatch: expected 1 argument (token), got %d", C.UI, 1 + select("#", ...)) end
    if not issued[token] then C.fail("%s.journal.unwatch: unknown token %d (not one journal.watch returned)", C.UI, token) end
    local any = false
    for _, w in ipairs(watchers) do
        if w.token == token and not w.internal then w.dead = true end
        if not w.dead then any = true end
    end
    compact() -- removal takes effect after the event being dispatched (dispatch compacts); outside a dispatch, now
    if not any and keepToken then H._release(keepToken); keepToken = nil end
end

function J.stats()
    return { tracked = #paths, watchers = #watchers, open = S.path ~= nil, openPath = S.path, lastClosed = lastClosed,
        opens = T.opens, closes = T.closes, lost = T.lost, findAllCalls = C.stats.journalFindAllCalls or 0,
        attachOpens = T.attachN, attachAvg = T.attachN > 0 and T.attachSum / T.attachN or 0, attachMax = T.attachMax,
        attachLast = T.attachLast, attachElements = T.attachEls, attachSteps = T.steps }
end

-- ---- internal (text.lua)
function J._watch(fn) return addWatcher(fn, true) end
function J._ticker(fn) tickers[#tickers + 1] = fn end
function J._poll() seed() return pollOpen(false) end
-- The attach cost of one open (story 13 AC 6): us on the game thread for n elements, and (story 14) its steps:
-- { canvas = us, place = us, items = { { id, us, create, panel }, ... } } (stats() hands out this table; diagnostic).
function J._recordAttach(us, n, steps)
    T.attachN, T.attachSum, T.attachLast, T.attachEls, T.steps = T.attachN + 1, T.attachSum + us, us, n, steps
    if us > T.attachMax then T.attachMax = us end
end

-- For unit tests only.
J._decide, J._S, J._rec, J._paths = decide, S, rec, paths
J._track = track
return J
