-- Monotonic clock over core's native (api-contract.md, "C++ natives"). Any thread, also during main.lua.
-- micros() -> integer microseconds. The epoch is arbitrary: only the difference between two calls means anything.
local V = require((...):gsub("%.clock$", "") .. ".version")

local M = {}
local KEY = V.name .. "_ClockMicros" -- built once, so a call is one global lookup plus the native

-- The native is looked up on every call (never cached): a hot reload registers a new one.
function M.micros()
    local fn = _G[KEY]
    if fn == nil then error(V.name .. "'s native part is not loaded (" .. KEY .. " missing)", 2) end
    return fn()
end

return M
