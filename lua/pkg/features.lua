-- Feature names for core.has(name) and core.features() (story 18), and the shape of the api table connect hands to
-- onReady, so core's own READY line (main.lua, which builds no api table) lists exactly what a dependent's core.has
-- answers for.
--
-- Names are API paths, generated from the api table by one rule (fromApi): every function directly on the api table
-- (call, ref, ...), every table on it, and inside a table that holds other tables (a namespace, like ui) every
-- table and function, recursively; a table holding only functions (a module, like ui.text) is listed by its own path
-- and its functions are not. Plus HAND: changes inside an existing API that the path can't show ("ui.panel.reorder"
-- style), each added by the story that makes the change, with a changelog entry (README, "Versioning").
-- The minimum version stays the normal way to depend on a feature; core.has is for features a mod can do without.
local M = {}

M.MAX_NAME = 64 -- longest name core.has looks up; longer names are simply not features

-- Fields of the api table that aren't features: data, the mod's own logger, and the feature calls themselves.
local SKIP = { name = true, version = true, log = true, has = true, features = true }

-- Hand-named features. Add-only: a name, once shipped, stays (story 18: core only ever adds).
M.HAND = {
    "map.setup", -- map service (0.5.0): the nucleus.map.setup shared variable, outside the api table (user 2026-11-08)
    "ui.journal.regions", -- story 19 (0.6.0): named Journal regions in core.ui.place (region, inset, near = <region>) and elements("journal")
}

-- The UI part of the api table: path -> { module, function } (client.lua builds api.ui from this).
M.UI = {
    { "hud.find", "hud", "find" }, { "hud.watch", "hud", "watch" }, { "hud.unwatch", "hud", "unwatch" },
    { "hud.isVisible", "hud", "isVisible" }, { "hud.stats", "hud", "stats" },
    -- story 13 (core 0.3.0): the Journal's map page as a host
    { "journal.find", "journal", "find" }, { "journal.watch", "journal", "watch" }, { "journal.unwatch", "journal", "unwatch" },
    { "journal.isOpen", "journal", "isOpen" }, { "journal.stats", "journal", "stats" },
    { "text.create", "text", "create" }, { "text.set", "text", "set" }, { "text.setStyle", "text", "setStyle" },
    { "text.setVisible", "text", "setVisible" }, { "text.remove", "text", "remove" }, { "text.isShown", "text", "isShown" },
    { "text.stats", "text", "stats" }, { "text.tagOf", "text", "tagOf" },
    -- story 14 (core 0.3.0): panels, with reordering
    { "panel.create", "panel", "create" }, { "panel.setStyle", "panel", "setStyle" }, { "panel.setVisible", "panel", "setVisible" },
    { "panel.remove", "panel", "remove" }, { "panel.isShown", "panel", "isShown" }, { "panel.order", "panel", "order" },
    { "panel.setOrder", "panel", "setOrder" }, { "panel.move", "panel", "move" },
    -- story 15 (core 0.3.0): buttons with click callbacks (on hosts with a cursor: the Journal)
    { "button.create", "button", "create" }, { "button.setLabel", "button", "setLabel" }, { "button.setEnabled", "button", "setEnabled" },
    { "button.setVisible", "button", "setVisible" }, { "button.remove", "button", "remove" }, { "button.isShown", "button", "isShown" },
    { "button.stats", "button", "stats" },
    { "place", "place", "place" },
    { "elements", "place", "elements" },
    { "debug.overlaps", "debug", "overlaps" }, -- story 12: a diagnostic for testing a mod's UI
}

-- The rest of the api table (client.lua sets these by hand): name -> "function" | "module".
M.BASE = { call = "function", ref = "function", deref = "function", free = "function", clock = "module" }

-- buildUi(U) -> ui table, missing: U maps module names to loaded modules. A function missing from its module is left
-- out (and named in missing), so the generated feature list never claims it.
function M.buildUi(U)
    local ui, missing = {}, {}
    for _, e in ipairs(M.UI) do
        local path, mod, fn = e[1], e[2], e[3]
        local f = type(U[mod]) == "table" and U[mod][fn] or nil
        if type(f) == "function" then
            local t, last = ui, nil
            for part in path:gmatch("[^.]+") do
                if last then t[last] = t[last] or {}; t = t[last] end
                last = part
            end
            t[last] = f
        else
            missing[#missing + 1] = path
        end
    end
    return ui, missing
end

local function isModule(t)
    for _, v in pairs(t) do if type(v) == "table" then return false end end
    return true
end

local function walk(t, prefix, out)
    for k, v in pairs(t) do
        if type(k) == "string" and not (prefix == "" and SKIP[k]) then
            local path = prefix == "" and k or (prefix .. "." .. k)
            if type(v) == "function" then out[#out + 1] = path
            elseif type(v) == "table" then
                out[#out + 1] = path
                if not isModule(v) then walk(v, path, out) end
            end
        end
    end
end

-- fromApi(api) -> sorted list of feature names (the rule above, plus HAND).
function M.fromApi(api)
    local out = {}
    if type(api) == "table" then walk(api, "", out) end
    for _, h in ipairs(M.HAND) do out[#out + 1] = h end
    table.sort(out)
    return out
end

-- declared() -> sorted list: what fromApi gives for a complete api table (every UI function present). main.lua's
-- READY line; the unit test checks it against a real client api.
function M.declared()
    local stub = function() end
    local api = {}
    for k, kind in pairs(M.BASE) do api[k] = kind == "module" and { fn = stub } or stub end
    local U = {}
    for _, e in ipairs(M.UI) do U[e[2]] = U[e[2]] or {}; U[e[2]][e[3]] = stub end
    api.ui = M.buildUi(U)
    return M.fromApi(api)
end

-- set(list) -> name -> true
function M.set(list)
    local s = {}
    for _, n in ipairs(list) do s[n] = true end
    return s
end

return M
