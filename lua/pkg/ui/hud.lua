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
local BASE = (...):gsub("%.ui%.hud$", "")
local C = require(BASE .. ".ui.common")

local H = {}
local TICK_MS = 500
local MAX_PATHS = 16
local SLOW_US = 1000             -- one tick over this logs a WARN (at most once a minute)
local MINUTE_US = 60 * 1000000
local LOST_TICK_S = 3              -- a queued tick that hasn't run after this many seconds is given up and re-queued

-- ---- tracked HUD paths (strings only), oldest first
local paths = {}                 -- list of path strings
local known = {}                 -- path -> true
local seeded = false
local droppedLiveWarned = false

local function isTemplate(p)
    return p:find("Default__", 1, true) ~= nil or p:sub(1, #"/Game/Graphics/Inventory/InventoryUI.") == "/Game/Graphics/Inventory/InventoryUI."
end

-- Adds a path; at the cap, drops paths that no longer resolve first, then the oldest. resolveOk: whether this runs where
-- StaticFindObject may be called (not inside the creation callback).
local function track(p, resolveOk)
    if type(p) ~= "string" or known[p] or isTemplate(p) then return end
    if #paths >= MAX_PATHS and resolveOk then
        for i = #paths, 1, -1 do
            if not C.found(paths[i]) then known[paths[i]] = nil; table.remove(paths, i) end
        end
    end
    if #paths >= MAX_PATHS then
        local old = table.remove(paths, 1)
        known[old] = nil
        if resolveOk and C.found(old) and not droppedLiveWarned then
            droppedLiveWarned = true
            if C.log then C.log.warn("hud tracking is full (%d paths): dropped a live HUD %s; is something creating HUDs in a loop?", MAX_PATHS, old) end
        end
    end
    paths[#paths + 1] = p
    known[p] = true
end

-- 1. Learn new HUDs from their creation. Only the path is recorded: the widget is still being constructed, so nothing
-- is called on it but GetFullName. Never returns true (that would unregister the callback).
local okNotify, errNotify = pcall(NotifyOnNewObject, C.HUD_CLASS, function(obj)
    pcall(function() track(C.pathOf(obj), false) end)
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
        if C.valid(w) then n = n + 1; track(C.pathOf(w), true) end
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
        local w = C.found(p)
        if not w then
            known[p] = nil; table.remove(paths, i)
        else
            local ok, inVp = pcall(function() return w:IsInViewport() end)
            if ok and inVp then live[#live + 1] = { w = w, p = p } end
        end
    end
    if #live == 0 then return nil end
    table.sort(live, function(a, b) return a.p < b.p end)
    -- Ownership: a HUD owned by the local player controller first; one whose owner can't be read (between worlds)
    -- second; never one owned by another controller.
    local pcAddr, fallback
    for _, c in ipairs(live) do
        local okO, owner = pcall(function() return c.w:GetOwningPlayer() end)
        if okO and C.valid(owner) then
            pcAddr = pcAddr or localPcAddr(c.w:GetWorld())
            local okL, isLocal = pcall(function() return owner:IsLocalController() end)
            if (pcAddr ~= 0 and owner:GetAddress() == pcAddr) or (pcAddr == 0 and okL and isLocal) then
                return c.w, c.p, tonumber(c.w:GetVisibility()) or 0
            end
        elseif not fallback then
            fallback = c
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
    gen = 0, running = false, queued = false,
    path = nil, visible = nil,    -- the attached HUD
    cand = nil,                   -- a new path seen once
    gonePath = nil,               -- the last HUD that left (for "back in the viewport")
}
local T = { n = 0, pollSum = 0, pollMax = 0, watchSum = 0, watchMax = 0, windowStart = nil, lastSlowWarn = nil }
local TOT = { n = 0, pollSum = 0, pollMax = 0, watchSum = 0, watchMax = 0 }
local tickers = {}               -- internal per-tick callbacks (text.lua): fn(hud, path)

local function deliver(w, hud, info)
    if w.dead then return end
    local ok, err = pcall(w.fn, hud, info)
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
        if S.cand ~= path then S.cand = path return nil end
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

local function account(pollUs, watchUs, now)
    for _, t in ipairs({ T, TOT }) do
        t.n = t.n + 1
        t.pollSum, t.watchSum = t.pollSum + pollUs, t.watchSum + watchUs
        if pollUs > t.pollMax then t.pollMax = pollUs end
        if watchUs > t.watchMax then t.watchMax = watchUs end
    end
    local total = pollUs + watchUs
    if total > SLOW_US and (T.lastSlowWarn == nil or now - T.lastSlowWarn >= MINUTE_US) then
        T.lastSlowWarn = now
        if C.log then C.log.warn("hud slow tick %d us (poll %d us, watchers %d us)", total, pollUs, watchUs) end
    end
    T.windowStart = T.windowStart or now
    if now - T.windowStart >= MINUTE_US then
        if C.log then C.log.debug("hud tick n=%d avg=%.1f max=%d (poll avg %.1f max %d, watchers avg %.1f max %d) us findAll=%d paths=%d",
            T.n, (T.pollSum + T.watchSum) / T.n, math.max(T.pollMax, T.watchMax), T.pollSum / T.n, T.pollMax, T.watchSum / T.n, T.watchMax,
            C.stats.findAllCalls, #paths) end
        T.n, T.pollSum, T.pollMax, T.watchSum, T.watchMax, T.windowStart = 0, 0, 0, 0, 0, now
    end
end

local function tick()
    local t0 = C.micros()
    local hud, path, vis = poll()
    local t1 = C.micros()
    local info = decide(hud, path, vis)
    if info then
        dispatch(info.event ~= "lost" and hud or nil, info, false)
    elseif S.path and hud and path == S.path then
        -- Late watchers hear about the current HUD on the next tick (at most one event per watcher per tick).
        local fresh = false
        for _, w in ipairs(watchers) do if w.needAttached and not w.dead then fresh = true break end end
        if fresh then dispatch(hud, { event = "attached", reason = "late watcher: HUD already live", path = path, visible = S.visible }, true) end
    end
    if S.path and hud and path == S.path then
        for _, f in ipairs(tickers) do
            local ok, err = pcall(f, hud, path)
            if not ok then C.warnOnce("hud ticker", "hud tick work failed: %s (further failures not logged)", tostring(err):match("^[^\n]*")) end
        end
    end
    local t2 = C.micros()
    account(t1 - t0, t2 - t1, t2)
end

local function startPoller()
    if S.running then return end
    S.running = true
    S.gen = S.gen + 1
    local gen = S.gen
    S.path, S.visible, S.cand, S.queued = nil, nil, nil, false
    seed()
    local ok, err = pcall(LoopAsync, TICK_MS, function()
        if gen ~= S.gen then return true end
        -- Watchdog: UE4SS may never run a queued game-thread callback (seen on V8.1.1 right after another callback
        -- failed inside UE4SS). Without this, S.queued would stay true and the poller would stop for good.
        if S.queued and os.time() - (S.queuedAt or 0) >= LOST_TICK_S then
            S.queued = false
            S.lostTicks = (S.lostTicks or 0) + 1
            C.warnOnce("hud lost tick", "hud tick callback still not run %d s after it was queued (a map load, or UE4SS dropped it); queuing another (further ones not logged)", LOST_TICK_S)
        end
        if not S.queued then
            S.queued, S.queuedAt = true, os.time()
            local okE, errE = pcall(ExecuteInGameThread, function()
                if gen == S.gen then
                    local okT, errT = pcall(tick)
                    if not okT then C.warnOnce("hud tick", "hud tick failed: %s (further failures not logged)", tostring(errT):match("^[^\n]*")) end
                end
                S.queued = false
            end)
            if not okE then S.queued = false; C.warnOnce("hud schedule", "hud tick could not reach the game thread: %s", tostring(errE)) end
        end
        return false
    end)
    if not ok then S.running = false; C.warnOnce("hud loop", "hud poller could not start: %s", tostring(err)) end
end

local function stopPoller()
    if not S.running then return end
    S.running = false
    S.gen = S.gen + 1
    S.path, S.visible, S.cand = nil, nil, nil
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
        ticks = TOT.n, pollAvg = TOT.n > 0 and TOT.pollSum / TOT.n or 0, pollMax = TOT.pollMax,
        watchAvg = TOT.n > 0 and TOT.watchSum / TOT.n or 0, watchMax = TOT.watchMax, attachedPath = S.path,
    }
end

-- ---- internal (text.lua)
function H._watch(fn) return addWatcher(fn, true) end
function H._ticker(fn) tickers[#tickers + 1] = fn end
function H._poll() seed() return poll() end

-- The summary line at unload.
function H._summary()
    if not C.log or TOT.n == 0 then return end
    C.log.info("hud tick summary n=%d poll avg %.1f max %d us, watchers avg %.1f max %d us, findAll=%d",
        TOT.n, TOT.pollSum / TOT.n, TOT.pollMax, TOT.watchSum / TOT.n, TOT.watchMax, C.stats.findAllCalls)
end

-- For unit tests only: the pure state machine.
H._decide, H._S = decide, S

return H
