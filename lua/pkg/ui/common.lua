-- Shared state and helpers of core's UI helpers (internal; not public API). One copy per Lua state: every dependent
-- requires its own, so elements, HUD paths and counters are per mod. Holds no UObject between calls: only strings,
-- numbers, weak-handle integers and plain tables (AGENTS.md, "Blueprint mods").
local BASE = (...):gsub("%.ui%.common$", "")
local V = require(BASE .. ".version")

local C = {}
C.NAME = V.name
C.LOWER = V.name:lower()
C.UI = C.LOWER .. ".ui"                -- "nucleus.ui": the prefix of every error message
C.TEXT_PKG = "/Game/Mods/" .. C.NAME .. "/WBP_" .. C.NAME .. "Text"
C.TEXT_SHORT = "WBP_" .. C.NAME .. "Text_C"
C.TEXT_CLASS = C.TEXT_PKG .. "." .. C.TEXT_SHORT
C.HUD_CLASS = "/Game/Graphics/Inventory/InventoryUI.InventoryUI_C"
C.HUD_SHORT = "InventoryUI_C"

-- ESlateVisibility
C.VIS = { Visible = 0, Collapsed = 1, Hidden = 2, HitTestInvisible = 3, SelfHitTestInvisible = 4 }
C.VIS_NAME = { [0] = "Visible", [1] = "Collapsed", [2] = "Hidden", [3] = "HitTestInvisible", [4] = "SelfHitTestInvisible" }
function C.drawn(vis) return vis ~= 1 and vis ~= 2 end

-- Set by bind() when connect succeeds (client.lua, before onReady). Until then every public function refuses.
C.bound = false
C.mod = nil      -- the dependent's name as passed to connect{ mod = ... }
C.modTag = nil   -- the same, restricted to tag-safe characters
C.log = nil      -- the dependent's logger (log.new(mod)), shared with core.log
C.ref, C.deref, C.free, C.micros = nil, nil, nil, nil

-- Counters for tests and diagnostics (stats() in hud and text return copies).
-- overlapScheduled, overlapChecks: story 12's automatic checks scheduled (debug only) and overlap checks run.
C.stats = { uobjectCalls = 0, findAllCalls = 0, attachCreated = 0, attachReused = 0, handlesFreed = 0,
    overlapScheduled = 0, overlapChecks = 0 }

function C.bind(api)
    C.mod = tostring(api.mod)
    C.modTag = (C.mod:gsub("[^%w_%.%-]", "_"))
    C.log = api.log
    C.ref, C.deref, C.free, C.micros = api.ref, api.deref, api.free, api.micros
    C.bound = true
end

-- Whether the dependent's logger writes DEBUG lines (core.log.debugEnabled; it can change at any time). Lines that
-- only matter when debugging (the per-attach report) are not even built when it is off.
function C.debugOn() return C.log ~= nil and C.log.debugEnabled == true end

-- Raises a clean error: no position prefix, so the first line is exactly the message.
function C.fail(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    error(ok and msg or tostring(fmt), 0)
end

-- Off the game thread? The natives know the game thread (after the first engine tick); Lua doesn't. <Core>_Deref of
-- a handle that is in range but never issued is the cheapest call that refuses off the game thread and returns nil on
-- it, touching no UObject.
local PROBE = (1 << 53) - 1
local function offGameThread()
    local deref = _G[C.NAME .. "_Deref"]
    if type(deref) ~= "function" then return false end
    local ok, err = pcall(deref, PROBE)
    return not ok and tostring(err):find("off the game thread", 1, true) ~= nil
end
C.offGameThread = offGameThread

-- The boundary check of every public function: connected, and on the game thread. fn is e.g. "text.create".
function C.enter(fn)
    if not C.bound then C.fail("%s: %s called before connect", C.UI, fn) end
    if offGameThread() then C.fail("%s.%s called off the game thread", C.UI, fn) end
end

-- Describes a value for an error message without echoing much of it.
function C.describe(v)
    local t = type(v)
    if t == "string" then
        local s = v:sub(1, 32):gsub("[^%w%p ]", "?")
        return string.format("'%s'%s", s, #v > 32 and "..." or "")
    end
    if t == "number" then
        if v ~= v then return "NaN" end
        return tostring(v)
    end
    return t
end

-- ---- UObject helpers (call only inside the game-thread callback that found the object)
-- Hot-path helpers take their object as an argument instead of capturing it in a closure: a tick allocates as
-- little as possible, because every allocation brings the Lua collector closer to a step inside the tick.
local function isValidOf(o) return o:IsValid() end
function C.valid(o)
    if o == nil or type(o) ~= "userdata" then return false end
    local ok, yes = pcall(isValidOf, o)
    return ok and yes == true
end
function C.call0(o, name) return o[name](o) end   -- pcall(C.call0, o, "Fn") calls o:Fn() without a closure
function C.prop(o, name) return o[name] end
function C.found(path)
    if type(path) ~= "string" then return nil end
    local o = StaticFindObject(path)
    return C.valid(o) and o or nil
end
function C.pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end
function C.addr(o) return o:GetAddress() end
function C.count() C.stats.uobjectCalls = C.stats.uobjectCalls + 1 end

-- ---- tick profiler (diagnostic; off unless hud._profile(true)). Times named phases of one HUD tick with the
-- microsecond clock. Every probe is `local t = C.pt()` ... `C.pa("phase", t)`; with the profiler off C.pt() returns nil
-- and C.pa does nothing, so the cost when off is two function calls per probe.
C.prof = nil                     -- nil, or { cur = { phase -> us }, calls = { phase -> n } } while a tick runs
C.profOn = false
function C.pt() if C.prof then return C.micros() end end
function C.pa(key, t0)
    local p = C.prof
    if p and t0 then
        local dt = C.micros() - t0
        p.cur[key] = (p.cur[key] or 0) + dt
        p.calls[key] = (p.calls[key] or 0) + 1
        return dt
    end
end

-- One log line per key for the life of this Lua state.
local warned = {}
function C.warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    if C.log then C.log.warn(fmt, ...) end
end
function C.forgetWarning(key) warned[key] = nil end

-- ---- element registry (filled by text.lua; read by place.lua)
C.els = {}                                  -- id -> element (removed ones are dropped)
C.order = {}                                -- elements in creation order (for corner stacking)
C.handleOf = setmetatable({}, { __mode = "k" })  -- handle table -> element
C.removedHandle = setmetatable({}, { __mode = "k" }) -- handle table -> id, after remove
C.seq = 0

-- The element behind a handle, or a clean error. fn is e.g. "text.set".
function C.element(h, fn)
    if type(h) ~= "table" then C.fail("%s.%s: expected an element handle, got %s", C.UI, fn, C.describe(h)) end
    local id = C.removedHandle[h]
    if id then C.fail("%s.text: handle '%s' was removed", C.UI, id) end
    local el = C.handleOf[h]
    if not el then C.fail("%s.%s: not an element handle (use the handle that text.create returned)", C.UI, fn) end
    return el
end

return C
