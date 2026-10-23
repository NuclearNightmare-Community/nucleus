-- Weak handles over core's natives (api-contract.md, "C++ natives"). Dependents keep handles, never UObjects.
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
    if type(obj) ~= "userdata" then error("ref: expected a UObject", 2) end
    return native("_Ref")(obj:GetAddress())
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
