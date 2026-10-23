-- Weak handles over core's natives (api-contract.md, "C++ natives"). Dependents keep handles, never UObjects.
-- The natives validate everything themselves; these wrappers only turn a non-object into a clean error.
local V = require((...):gsub("%.ref$", "") .. ".version")

local M = {}
local NAME = V.name

local function native(suffix)
    local fn = _G[NAME .. suffix]
    if type(fn) ~= "function" then error(NAME .. "'s native part is not loaded (" .. NAME .. suffix .. " missing)", 3) end
    return fn
end

-- ref(obj) -> handle. obj must be live now (just found or created); game thread only after load.
function M.ref(obj)
    if type(obj) ~= "userdata" then error("ref: expected a UObject, got " .. type(obj), 2) end
    local ok, addr = pcall(function() return obj:GetAddress() end)
    if not ok or math.type(addr) ~= "integer" then error("ref: expected a UObject (it has no GetAddress)", 2) end
    return native("_Ref")(addr)
end

-- deref(handle) -> obj or nil. nil once the object is gone, its slot reused, or the handle freed.
function M.deref(handle)
    if handle == nil then return nil end
    return native("_Deref")(handle)
end

function M.free(handle)
    if handle ~= nil then native("_RefFree")(handle) end
end

return M
