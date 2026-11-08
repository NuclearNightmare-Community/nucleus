-- Deprecations (story 18: core only ever adds). A replaced API keeps working; the first use in a dependent's Lua state
-- logs one line naming the replacement, and later uses log nothing. Each dependent loads its own copy of this module,
-- so that is once per dependent per session (a hot reload of the dependent starts a new session for it).
-- Removal happens only in a breaking major, announced in the changelog (README, "Versioning").
local M = {}

-- Channel ops that are deprecated: op -> replacement op. client.call warns before forwarding them.
-- "deprecated-test" is test-only (the bad-input scenario's deprecation case): core answers it like "version". It is
-- not public API; dependents never use it.
M.OPS = { ["deprecated-test"] = "version" }

local seen = {}

-- warn(log, what, replacement) -> true when this call logged. log: a nucleus.log logger (or nil: plain print).
-- Never raises.
function M.warn(log, what, replacement)
    what, replacement = tostring(what), tostring(replacement)
    if seen[what] then return false end
    seen[what] = true
    local msg = string.format("DEPRECATED %s; use %s instead. It keeps working until a breaking major release.", what, replacement)
    local ok = type(log) == "table" and type(log.warn) == "function" and pcall(log.warn, "%s", msg)
    if not ok then pcall(print, "[deprecated] WARN " .. msg .. "\n") end
    return true
end

-- wrap(getLog, what, replacement, fn) -> a function that warns once, then calls fn with the same arguments.
-- getLog() returns the logger at call time (the dependent's, once connected).
function M.wrap(getLog, what, replacement, fn)
    return function(...)
        local okL, log = pcall(getLog)
        M.warn(okL and log or nil, what, replacement)
        return fn(...)
    end
end

-- Test hook for the unit tests: forget what was logged.
function M._reset() seen = {} end

return M
