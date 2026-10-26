-- UI-1 (story 7): the live HUD, found and watched. Exposed as core.ui.hud on the connect API.
--   find() -> hud | nil          the in-viewport InventoryUI_C owned by the local player. VALID ONLY UNTIL THE CURRENT
--                                game-thread callback returns: never store it (AGENTS.md, "Blueprint mods").
--   watch(fn) -> token           fn(hud, info), info = { event, reason, path, visible }; event is attached, shown,
--                                hidden or lost (hud is nil for lost)
--   unwatch(token)
--   isVisible() -> boolean       the live HUD exists and is drawn
--   stats() -> table             diagnostic counters (a copy; not part of the semver API)
--
-- HUDs are never searched for on a tick. Their paths are learned from their creation (NotifyOnNewObject) plus one seed
-- FindAllOf per Lua state; ticks re-find the known paths with StaticFindObject (a hash lookup). One poller per Lua
-- state, every 500 ms on the game thread, started by the first watch and stopped when the last watcher unwatches.
--
-- The poller is a LoopInGameThreadWithDelay registered from the game thread (watch() only runs there), never
-- LoopAsync + ExecuteInGameThread. In the pinned UE4SS, ExecuteInGameThread called from the async thread moves the
-- callback onto the mod's hook thread stack (lua_xmove) and pops it into the registry (luaL_ref) while the game thread
-- may be running a C function on that same stack with the Lua lock released (LuaMod.cpp, ExecuteInGameThread; the
-- game-thread side runs callbacks without m_thread_actions_mutex). When the game thread pushes a value in between,
-- luaL_ref stores that value instead: the queued callback is lost for good, and UE4SS later calls whatever was stored
-- (on V8.1.1 a UObject method closure: "A function requiring userdata as param #1 was called without userdata",
-- traceback only "[C]: in ?"). Registering and running on the game thread leaves no second thread to race.
-- During a blocking map load no engine tick runs, so a tick simply waits; when the load ends the loop runs once and
-- re-arms (no backlog).
local BASE = (...):gsub("%.ui%.hud$", "")
local C = require(BASE .. ".ui.common")

local H = {}
local TICK_MS = 500
local MAX_PATHS = 16
local SLOW_US = 1000             -- one tick over this logs a WARN (at most once a minute)
local MINUTE_US = 60 * 1000000

-- ---- tracked HUDs: path strings plus a weak handle each, oldest first
-- A tick re-finds each HUD by its weak handle (<Core>_Deref: a lookup in core's table, nil once the object is gone),
-- not by StaticFindObject(path): in the pinned UE4SS a StaticFindObject that misses falls back to a scan of every
-- object (UObjectGlobals.cpp FindObject, "A miss falls through to the scan"), 4-6.5 ms on V8.1.2 in the first tick
-- after a map change. The path stays as the fallback for a HUD learned before connect (no natives yet).
local paths = {}                 -- list of path strings
local known = {}                 -- path -> true
local handleOf = {}              -- path -> weak handle
local localOwned = {}            -- path -> true once its owning player was found to be the local one
local seeded = false
local droppedLiveWarned = false

local function isTemplate(p)
    return p:find("Default__", 1, true) ~= nil or p:sub(1, #"/Game/Graphics/Inventory/InventoryUI.") == "/Game/Graphics/Inventory/InventoryUI."
end

local function forget(p)
    if handleOf[p] and C.free then pcall(C.free, handleOf[p]) end
    known[p], handleOf[p], localOwned[p] = nil, nil, nil
end

-- The live HUD object for a tracked path, or nil. Never scans once the path has a handle.
local function resolve(p)
    local h = handleOf[p]
    if h then
        local ok, w = pcall(C.deref, h)
        return ok and w or nil
    end
    local w = C.found(p)
    if w and C.ref then
        local ok, nh = pcall(C.ref, w)
        if ok then handleOf[p] = nh end
    end
    return w
end

-- Adds a path (and a handle to obj when the natives are bound); at the cap, drops paths that no longer resolve
-- first, then the oldest.
local function track(p, obj)
    if type(p) ~= "string" or known[p] or isTemplate(p) then return end
    if #paths >= MAX_PATHS then
        for i = #paths, 1, -1 do
            if not resolve(paths[i]) then forget(paths[i]); table.remove(paths, i) end
        end
    end
    if #paths >= MAX_PATHS then
        local old = table.remove(paths, 1)
        local wasLive = resolve(old) ~= nil
        forget(old)
        if wasLive and not droppedLiveWarned then
            droppedLiveWarned = true
            if C.log then C.log.warn("hud tracking is full (%d paths): dropped a live HUD %s; is something creating HUDs in a loop?", MAX_PATHS, old) end
        end
    end
    paths[#paths + 1] = p
    known[p] = true
    if obj and C.ref then
        local ok, h = pcall(C.ref, obj)
        if ok then handleOf[p] = h end
    end
end

-- 1. Learn new HUDs from their creation. Only its path is read and a weak handle taken (an address lookup in
-- GUObjectArray): nothing is called on the widget, which may still be under construction. The pinned UE4SS runs
-- these callbacks on the game thread, from its engine-tick processing. Never returns true (that would unregister).
local okNotify, errNotify = pcall(NotifyOnNewObject, C.HUD_CLASS, function(obj)
    pcall(function() track(C.pathOf(obj), obj) end)
    return false
end)

-- 2. Seed once per Lua state: the HUDs that existed before this module loaded (hot reload, a late first use).
local function seed()
    if seeded then return end
    seeded = true
    local t0 = C.micros and C.micros() or 0
    C.stats.findAllCalls = C.stats.findAllCalls + 1
    local list = FindAllOf(C.HUD_SHORT) or {}
    local n = 0
    for _, w in ipairs(list) do
        if C.valid(w) then n = n + 1; track(C.pathOf(w), w) end
    end
    local dt = C.micros and (C.micros() - t0) or 0
    if C.log then C.log.info("hud seed FindAllOf(%s) call %d found %d HUD(s) in %d us; new HUDs come from their creation callback%s",
        C.HUD_SHORT, C.stats.findAllCalls, n, dt, okNotify and "" or (" (NOT registered: " .. tostring(errNotify) .. ")")) end
end

-- The local player's controller, by address (0 if none).
local function localPcAddr(world)
    local ok, a = pcall(function()
        local pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(world, 0)
        return C.valid(pc) and pc:GetAddress() or 0
    end)
    return ok and a or 0
end

-- 3. The live HUD: of the tracked paths that resolve, the in-viewport one owned by the local player, first by path
-- order. Paths that no longer resolve are dropped. Returns hud, path, visibility (ESlateVisibility number).
local function poll()
    local live = {}
    for i = #paths, 1, -1 do
        local p = paths[i]
        local t = C.pt()
        local w = resolve(p)
        C.pa("poll.find", t)
        if not w then
            forget(p); table.remove(paths, i)
        else
            t = C.pt()
            local ok, inVp = pcall(function() return w:IsInViewport() end)
            C.pa("poll.viewport", t)
            if ok and inVp then live[#live + 1] = { w = w, p = p } end
        end
    end
    if #live == 0 then return nil end
    table.sort(live, function(a, b) return a.p < b.p end)
    -- Ownership: a HUD owned by the local player controller first; one whose owner can't be read (between worlds)
    -- second; never one owned by another controller.
    local pcAddr, fallback
    for _, c in ipairs(live) do
        -- A widget's owning player never changes, so a path once found to belong to the local player is not asked
        -- again (the ownership check is most of a steady tick's UObject calls); only that its owner still exists (a
        -- HUD left over from the last world would have lost it). Cleared when the path stops resolving.
        local t
        if localOwned[c.p] then
            t = C.pt()
            local okO, owner = pcall(function() return c.w:GetOwningPlayer() end)
            local still = okO and C.valid(owner)
            C.pa("poll.ownerCached", t)
            if still then
                t = C.pt()
                local vis = tonumber(c.w:GetVisibility()) or 0
                C.pa("poll.vis", t)
                return c.w, c.p, vis
            end
            localOwned[c.p] = nil
        end
        t = C.pt()
        local okO, owner = pcall(function() return c.w:GetOwningPlayer() end)
        if okO and C.valid(owner) then
            pcAddr = pcAddr or localPcAddr(c.w:GetWorld())
            local okL, isLocal = pcall(function() return owner:IsLocalController() end)
            local mine = (pcAddr ~= 0 and owner:GetAddress() == pcAddr) or (pcAddr == 0 and okL and isLocal)
            C.pa("poll.owner", t)
            if mine then
                localOwned[c.p] = true
                t = C.pt()
                local vis = tonumber(c.w:GetVisibility()) or 0
                C.pa("poll.vis", t)
                return c.w, c.p, vis
            end
        else
            C.pa("poll.owner", t)
            if not fallback then fallback = c end
        end
    end
    if fallback then return fallback.w, fallback.p, tonumber(fallback.w:GetVisibility()) or 0 end
    return nil
end

-- ---- public: find, isVisible

function H.find(...)
    C.enter("hud.find")
    if select("#", ...) > 0 then C.fail("%s.hud.find: expected 0 arguments, got %d", C.UI, select("#", ...)) end
    seed()
    local hud = poll()
    return hud
end

function H.isVisible(...)
    C.enter("hud.isVisible")
    if select("#", ...) > 0 then C.fail("%s.hud.isVisible: expected 0 arguments, got %d", C.UI, select("#", ...)) end
    seed()
    local hud, _, vis = poll()
    return hud ~= nil and C.drawn(vis)
end

-- ---- the watcher

local watchers = {}              -- list of { token, fn, internal, needAttached, dead, warned }
local nextToken = 0
local S = {                      -- poller state: strings, numbers, booleans only
    gen = 0, running = false, loop = nil, -- loop: the LoopInGameThreadWithDelay handle
    path = nil, visible = nil,    -- the attached HUD
    cand = nil,                   -- a new path seen once
    gonePath = nil,               -- the last HUD that left (for "back in the viewport")
}
-- Tick timing. Every tick counts in n/poll/watch; "event" ticks (a HUD event was dispatched, or an element was
-- re-attached) are also counted apart from "steady" ones (nothing changed), because only steady ticks repeat.
local function newTiming()
    return { n = 0, pollSum = 0, pollMax = 0, watchSum = 0, watchMax = 0,
        stN = 0, stSum = 0, stMax = 0, evN = 0, evSum = 0, evMax = 0 }
end
local T = newTiming()            -- the current one-minute window
T.windowStart, T.lastSlowWarn = nil, nil
local TOT = newTiming()          -- since the poller first started
local tickers = {}               -- internal per-tick callbacks (text.lua): fn(hud, path)
local preparers = {}             -- internal (text.lua): fn() on the tick that first sees a new HUD, a tick before attached

local function deliver(w, hud, info)
    if w.dead then return end
    local t = C.pt()
    local ok, err = pcall(w.fn, hud, info)
    if t then C.pa(w.internal and "watch.core" or ("watch.dependent#" .. w.token), t) end
    if not ok and not w.warned then
        w.warned = true
        if C.log then C.log.warn("hud watcher %d: %s", w.token, tostring(err):match("^[^\n]*")) end
    end
end

local function compact()
    for i = #watchers, 1, -1 do if watchers[i].dead then table.remove(watchers, i) end end
end

local function dispatch(hud, info, onlyFresh)
    local list = {}
    for i, w in ipairs(watchers) do list[i] = w end -- watchers added during dispatch wait for the next tick
    for _, w in ipairs(list) do
        if not w.dead then
            if info.event == "attached" then
                if not onlyFresh or w.needAttached then w.needAttached = false; deliver(w, hud, info) end
            elseif not w.needAttached then
                deliver(w, hud, info) -- a watcher that never heard attached gets no lost/shown/hidden
            end
        end
    end
    compact()
end

local function decide(hud, path, vis)
    if not hud then
        S.cand = nil
        if S.path then
            local was = S.path
            S.gonePath, S.path, S.visible = was, nil, nil
            return { event = "lost", reason = "HUD gone from the viewport", path = was, visible = false }
        end
        return nil
    end
    local visible = C.drawn(vis)
    if path ~= S.path then
        -- A new, replaced or returning HUD counts on the second tick that sees it, so one the game replaces at once
        -- is skipped.
        if S.cand ~= path then S.cand, S.prepare = path, true return nil end
        S.cand = nil
        local reason = (S.path and ("HUD replaced (was " .. S.path .. ")"))
            or (path == S.gonePath and "HUD back in the viewport") or "HUD appeared"
        S.path, S.visible = path, visible
        return { event = "attached", reason = reason, path = path, visible = visible }
    end
    S.cand = nil
    if visible ~= S.visible then
        local was = S.visible
        S.visible = visible
        return { event = visible and "shown" or "hidden", path = path, visible = visible,
            reason = string.format("HUD visibility %s -> %s", was and "drawn" or "not drawn", C.VIS_NAME[vis] or tostring(vis)) }
    end
    return nil
end

local function addTiming(t, pollUs, watchUs, event)
    local total = pollUs + watchUs
    t.n = t.n + 1
    t.pollSum, t.watchSum = t.pollSum + pollUs, t.watchSum + watchUs
    if pollUs > t.pollMax then t.pollMax = pollUs end
    if watchUs > t.watchMax then t.watchMax = watchUs end
    if event then
        t.evN, t.evSum = t.evN + 1, t.evSum + total
        if total > t.evMax then t.evMax = total end
    else
        t.stN, t.stSum = t.stN + 1, t.stSum + total
        if total > t.stMax then t.stMax = total end
    end
end

local function avg(sum, n) return n > 0 and sum / n or 0 end

local function account(pollUs, watchUs, now, event)
    addTiming(T, pollUs, watchUs, event)
    addTiming(TOT, pollUs, watchUs, event)
    local total = pollUs + watchUs
    if total > SLOW_US and (T.lastSlowWarn == nil or now - T.lastSlowWarn >= MINUTE_US) then
        T.lastSlowWarn = now
        if C.log then C.log.warn("hud slow tick %d us (poll %d us, watchers %d us; %s)", total, pollUs, watchUs,
            event and ("HUD event: " .. event) or "steady state") end
    end
    T.windowStart = T.windowStart or now
    if now - T.windowStart >= MINUTE_US then
        if C.log then C.log.debug("hud tick n=%d avg=%.1f max=%d (poll avg %.1f max %d, watchers avg %.1f max %d) us findAll=%d paths=%d; steady n=%d avg %.1f max %d us, events n=%d avg %.1f max %d us",
            T.n, (T.pollSum + T.watchSum) / T.n, math.max(T.pollMax, T.watchMax), T.pollSum / T.n, T.pollMax, T.watchSum / T.n, T.watchMax,
            C.stats.findAllCalls, #paths, T.stN, avg(T.stSum, T.stN), T.stMax, T.evN, avg(T.evSum, T.evN), T.evMax) end
        local keep = T.lastSlowWarn
        T = newTiming()
        T.windowStart, T.lastSlowWarn = now, keep
    end
end

-- ---- profiler output (only while hud._profile(true)): every event tick as one line, steady ticks aggregated per phase
-- once a minute, and every event tick's total in the unload summary.
local PR = { n = 0, sum = 0, max = 0, phases = {}, windowStart = nil, events = {} }
local MAX_EVENT_RECORDS = 64

local function phaseList(cur, calls, fmtOne)
    local keys = {}
    for k in pairs(cur) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return cur[a] > cur[b] end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = fmtOne(k, cur[k], calls and calls[k]) end
    return table.concat(parts, " ")
end

local function profReport(prof, pollUs, watchUs, now, event)
    if not C.log then return end
    local total = pollUs + watchUs
    if event then
        if #PR.events < MAX_EVENT_RECORDS then PR.events[#PR.events + 1] = string.format("%s:%d", event, total) end
        C.log.debug("hud prof event=%s total=%d us (poll %d, watchers %d); phases (us, calls; nested ones count in their parent too): %s",
            event, total, pollUs, watchUs, phaseList(prof.cur, prof.calls, function(k, us, n) return string.format("%s=%d(%d)", k, us, n or 0) end))
        return
    end
    PR.n, PR.sum = PR.n + 1, PR.sum + total
    if total > PR.max then PR.max = total end
    for k, us in pairs(prof.cur) do
        local a = PR.phases[k] or { sum = 0, max = 0 }
        PR.phases[k] = a
        a.sum = a.sum + us
        if us > a.max then a.max = us end
    end
    PR.windowStart = PR.windowStart or now
    if now - PR.windowStart >= MINUTE_US and PR.n > 0 then
        local sums, maxes = {}, {}
        for k, a in pairs(PR.phases) do sums[k], maxes[k] = a.sum, a.max end
        C.log.debug("hud prof steady n=%d avg=%.1f max=%d us; phases avg/max (us): %s", PR.n, PR.sum / PR.n, PR.max,
            phaseList(sums, nil, function(k, s) return string.format("%s=%.1f/%d", k, s / PR.n, maxes[k]) end))
        PR.n, PR.sum, PR.max, PR.phases, PR.windowStart = 0, 0, 0, {}, now
    end
end

local function tick()
    local prof = C.profOn and { cur = {}, calls = {} } or nil
    C.prof, C.tickEvent = prof, nil
    local t0 = C.micros()
    local hud, path, vis = poll()
    local t1 = C.micros()
    local info = decide(hud, path, vis)
    local event = info and info.event
    if S.prepare then
        -- A new HUD was seen once; it is attached on the next tick. Work that doesn't need it (loading the widget
        -- class) is done now, so the attach tick carries less.
        S.prepare = false
        for _, f in ipairs(preparers) do
            local t = C.pt()
            local ok, err = pcall(f)
            C.pa("prepare", t)
            if not ok then C.warnOnce("hud prepare", "hud prepare failed: %s (further failures not logged)", tostring(err):match("^[^\n]*")) end
        end
        event = event or "prepare"
    end
    if info then
        dispatch(info.event ~= "lost" and hud or nil, info, false)
    elseif S.path and hud and path == S.path then
        -- Late watchers hear about the current HUD on the next tick (at most one event per watcher per tick).
        local fresh = false
        for _, w in ipairs(watchers) do if w.needAttached and not w.dead then fresh = true break end end
        if fresh then
            event = "attached (late watcher)"
            dispatch(hud, { event = "attached", reason = "late watcher: HUD already live", path = path, visible = S.visible }, true)
        end
    end
    if S.path and hud and path == S.path then
        for _, f in ipairs(tickers) do
            local ok, err = pcall(f, hud, path)
            if not ok then C.warnOnce("hud ticker", "hud tick work failed: %s (further failures not logged)", tostring(err):match("^[^\n]*")) end
        end
    end
    local t2 = C.micros()
    C.prof = nil
    event = event or C.tickEvent -- text.lua sets it when a tick re-attached an element
    account(t1 - t0, t2 - t1, t2, event)
    if prof then profReport(prof, t1 - t0, t2 - t1, t2, event) end
end

local function startPoller()
    if S.running then return end
    S.running = true
    S.gen = S.gen + 1
    local gen = S.gen
    S.path, S.visible, S.cand = nil, nil, nil
    seed()
    -- On the game thread (watch() is game-thread only), so UE4SS's cross-thread ExecuteInGameThread race (top of
    -- this file) can't lose a tick. A loop that outlives a stop (gen changed) cancels itself on its next run.
    local handle
    local ok, res = pcall(LoopInGameThreadWithDelay, TICK_MS, function()
        if gen ~= S.gen then
            if handle then pcall(CancelDelayedAction, handle) end
            return
        end
        local okT, errT = pcall(tick)
        C.prof = nil
        if not okT then C.warnOnce("hud tick", "hud tick failed: %s (further failures not logged)", tostring(errT):match("^[^\n]*")) end
    end)
    if ok and math.type(res) == "integer" then
        handle = res
        S.loop = res
    else
        S.running = false
        C.warnOnce("hud loop", "hud poller could not start: %s", ok and ("LoopInGameThreadWithDelay returned " .. tostring(res)) or tostring(res))
    end
end

local function stopPoller()
    if not S.running then return end
    S.running = false
    S.gen = S.gen + 1
    S.path, S.visible, S.cand = nil, nil, nil
    if S.loop then pcall(CancelDelayedAction, S.loop) end
    S.loop = nil
end

local function addWatcher(fn, internal)
    nextToken = nextToken + 1
    local w = { token = nextToken, fn = fn, internal = internal, needAttached = true }
    watchers[#watchers + 1] = w
    startPoller()
    return w.token
end

function H.watch(fn, ...)
    C.enter("hud.watch")
    if type(fn) ~= "function" then C.fail("%s.hud.watch: fn must be a function, got %s", C.UI, C.describe(fn)) end
    if select("#", ...) > 0 then C.fail("%s.hud.watch: expected 1 argument (fn), got %d", C.UI, 1 + select("#", ...)) end
    return addWatcher(fn, false)
end

function H.unwatch(token, ...)
    C.enter("hud.unwatch")
    if math.type(token) ~= "integer" then C.fail("%s.hud.unwatch: token must be an integer, got %s", C.UI, C.describe(token)) end
    if select("#", ...) > 0 then C.fail("%s.hud.unwatch: expected 1 argument (token), got %d", C.UI, 1 + select("#", ...)) end
    local any = false
    for _, w in ipairs(watchers) do
        if w.token == token and not w.internal then w.dead = true end
        if not w.dead then any = true end
    end
    -- Removal takes effect after the event being dispatched (dispatch compacts); outside a dispatch, now.
    compact()
    if not any then stopPoller() end
end

function H.stats()
    return {
        findAllCalls = C.stats.findAllCalls, tracked = #paths, watchers = #watchers, running = S.running,
        ticks = TOT.n, pollAvg = avg(TOT.pollSum, TOT.n), pollMax = TOT.pollMax,
        watchAvg = avg(TOT.watchSum, TOT.n), watchMax = TOT.watchMax, attachedPath = S.path,
        steadyTicks = TOT.stN, steadyAvg = avg(TOT.stSum, TOT.stN), steadyMax = TOT.stMax,
        eventTicks = TOT.evN, eventAvg = avg(TOT.evSum, TOT.evN), eventMax = TOT.evMax,
    }
end

-- ---- internal (text.lua)
function H._watch(fn) return addWatcher(fn, true) end
function H._ticker(fn) tickers[#tickers + 1] = fn end
function H._prepare(fn) preparers[#preparers + 1] = fn end
function H._poll() seed() return poll() end

-- Diagnostic (not semver API): the per-phase tick profiler. Off by default; costs two clock reads per probe when on.
function H._profile(on) C.profOn = on == true end

-- The summary line at unload.
function H._summary()
    if not C.log or TOT.n == 0 then return end
    C.log.info("hud tick summary n=%d poll avg %.1f max %d us, watchers avg %.1f max %d us, findAll=%d; steady n=%d avg %.1f max %d us, events n=%d avg %.1f max %d us",
        TOT.n, TOT.pollSum / TOT.n, TOT.pollMax, TOT.watchSum / TOT.n, TOT.watchMax, C.stats.findAllCalls,
        TOT.stN, avg(TOT.stSum, TOT.stN), TOT.stMax, TOT.evN, avg(TOT.evSum, TOT.evN), TOT.evMax)
    if C.profOn and #PR.events > 0 then C.log.info("hud prof event ticks (event:us): %s", table.concat(PR.events, " ")) end
end

-- For unit tests only: the pure state machine.
H._decide, H._S = decide, S

return H
