-- One-line, mod-tagged logging for core and its dependents (api-contract.md, "<core>.log").
-- UE4SS.log shows only the first line of a multi-line print, so every message is flattened to one line.
local M = {}

local function render(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) .. " [log format error: " .. tostring(msg) .. "]" end
    return (msg:gsub("\r?\n", " | "))
end

-- log.new(tag, { debug = false }) -> logger with info, warn, error, debug.
function M.new(tag, opts)
    local prefix = "[" .. tostring(tag) .. "] "
    local L = { debugEnabled = (opts and opts.debug) == true }
    local function emit(level, fmt, ...)
        print(prefix .. level .. render(fmt, ...) .. "\n")
    end
    function L.info(fmt, ...) emit("", fmt, ...) end
    function L.warn(fmt, ...) emit("WARN ", fmt, ...) end
    function L.error(fmt, ...) emit("ERROR ", fmt, ...) end
    function L.debug(fmt, ...) if L.debugEnabled then emit("DEBUG ", fmt, ...) end end
    return L
end

return M
