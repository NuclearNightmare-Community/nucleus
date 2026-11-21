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
    "ui.look", -- story 21 (0.7.0): style.look = "game" | "plain" and a text's style.font; buttons, lists and rows on the menu and screen hosts
    -- story 24 (0.8.0): a text's style.overflow; icon, iconSize and dimmed on buttons; and the path of every new
    -- function (ui.image is a module, so the rule lists only "ui.image"; setTooltip is new inside ui.text and ui.button)
    "ui.overflow", "ui.button.icon",
    "ui.image.create", "ui.image.set", "ui.image.setVisible", "ui.image.remove", "ui.image.isShown", "ui.image.setTooltip",
    "ui.text.setTooltip", "ui.button.setTooltip",
    -- Mod Manager story 4 (core story 26, UI-11): the controls, each a module, so every function's path by hand
    "ui.checkbox.create", "ui.checkbox.get", "ui.checkbox.set", "ui.checkbox.setEnabled", "ui.checkbox.setVisible",
    "ui.checkbox.remove", "ui.checkbox.isShown", "ui.checkbox.setTooltip",
    "ui.choice.create", "ui.choice.get", "ui.choice.set", "ui.choice.range", "ui.choice.setEnabled", "ui.choice.setVisible",
    "ui.choice.remove", "ui.choice.isShown", "ui.choice.setTooltip",
    "ui.slider.create", "ui.slider.get", "ui.slider.set", "ui.slider.setDefault", "ui.slider.setEnabled", "ui.slider.setVisible",
    "ui.slider.remove", "ui.slider.isShown", "ui.slider.setTooltip",
    -- core story 22 (0.11.0, Net-1): core.net is a module, so every function's path by hand
    "net.publish", "net.read", "net.watch", "net.unwatch", "net.role",
    -- core story 23 (Net-2): player presence and the netCompat rule, new functions of the core.net module
    "net.presence", "net.watchPresence", "net.compatible", "net.versionsCompatible",
    -- core story 27 (UI-12): a window's content on a hugging card (corner and absolute intents inside it), BACK, keyboard
    -- and gamepad focus with Escape / B closing the top window, and the list and row gap "compact"
    "ui.screen.panel", "ui.screen.focus", "ui.gap.compact",
    -- core story 31 (0.13.0, UI-13): the game screens as hosts; createServer is the first (ui.game itself, a new
    -- module, is listed by the rule; this names the host, so a later screen adds its own name)
    "ui.game.createServer",
    -- core story 32 (0.14.0, UI-14): an intent inside a game container (container, after, before, index, at)
    "ui.place.container",
    -- core story 33 (0.15.0, UI-15): game-style rows (row.create's like, label, help, control; ui.row is a module, so
    -- its new functions by hand) and the game's own picker (choice.create's widget = "game")
    "ui.row.like", "ui.row.setLabel", "ui.row.setHelp", "ui.choice.game",
    -- core story 38 (0.16.0, UI-16): drag to reorder rows in a list (list.create's reorderable and onReorder, row.create's
    -- locked; ui.row is a module, so its new setLocked by hand)
    "ui.list.reorderable", "ui.row.setLocked",
    -- core story 43 (0.18.0, CAP-13): function interception (core.fn is a module, so its entry point by hand)
    "fn.intercept",
    -- core story 44 (0.22.0, CAP-14): mod controls in the game's Controls menu (core.input is a module, so its entry
    -- point by hand)
    "input.control",
    -- Mod Manager v2 story 4 (0.25.0): the single-line text box (core.ui.textbox is a module, so every function's path
    -- by hand; the rule lists "ui.textbox" itself)
    "ui.textbox.create", "ui.textbox.set", "ui.textbox.get", "ui.textbox.setEnabled", "ui.textbox.setVisible",
    "ui.textbox.remove", "ui.textbox.isShown", "ui.textbox.setTooltip",
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
    { "text.setTooltip", "text", "setTooltip" }, -- story 24
    -- story 14 (core 0.3.0): panels, with reordering
    { "panel.create", "panel", "create" }, { "panel.setStyle", "panel", "setStyle" }, { "panel.setVisible", "panel", "setVisible" },
    { "panel.remove", "panel", "remove" }, { "panel.isShown", "panel", "isShown" }, { "panel.order", "panel", "order" },
    { "panel.setOrder", "panel", "setOrder" }, { "panel.move", "panel", "move" },
    -- story 15 (core 0.3.0): buttons with click callbacks (on hosts with a cursor: the Journal)
    { "button.create", "button", "create" }, { "button.setLabel", "button", "setLabel" }, { "button.setEnabled", "button", "setEnabled" },
    { "button.setVisible", "button", "setVisible" }, { "button.remove", "button", "remove" }, { "button.isShown", "button", "isShown" },
    { "button.stats", "button", "stats" },
    { "button.setTooltip", "button", "setTooltip" }, -- story 24
    -- story 21 (core 0.7.0, Mod Manager story 2): the title-screen menu (host and entry), windows, lists and rows
    { "menu.entry", "entry", "entry" }, { "menu.removeEntry", "entry", "removeEntry" },
    { "menu.isOpen", "menu", "isOpen" }, { "menu.watch", "menu", "watch" }, { "menu.unwatch", "menu", "unwatch" },
    { "screen.open", "screen", "open" }, { "screen.close", "screen", "close" }, { "screen.isOpen", "screen", "isOpen" },
    { "screen.top", "screen", "top" }, { "screen.watch", "screen", "watch" }, { "screen.unwatch", "screen", "unwatch" },
    { "list.create", "list", "create" }, { "list.setStyle", "list", "setStyle" }, { "list.setVisible", "list", "setVisible" },
    { "list.remove", "list", "remove" }, { "list.isShown", "list", "isShown" },
    { "row.create", "row", "create" }, { "row.setStyle", "row", "setStyle" }, { "row.setVisible", "row", "setVisible" },
    { "row.remove", "row", "remove" }, { "row.isShown", "row", "isShown" },
    { "row.setLabel", "row", "setLabel" }, { "row.setHelp", "row", "setHelp" }, -- core story 33 (0.15.0): game-style rows
    { "row.setLocked", "row", "setLocked" }, -- core story 38 (0.16.0): a row that can't be dragged in a reorderable list
    -- story 24 (core 0.8.0, Mod Manager CAP-2): images and icons
    { "image.create", "image", "create" }, { "image.set", "image", "set" }, { "image.setVisible", "image", "setVisible" },
    { "image.remove", "image", "remove" }, { "image.isShown", "image", "isShown" }, { "image.setTooltip", "image", "setTooltip" },
    -- Mod Manager story 4 (core story 26, UI-11): checkbox, choice and slider-with-number controls
    { "checkbox.create", "checkbox", "create" }, { "checkbox.get", "checkbox", "get" }, { "checkbox.set", "checkbox", "set" },
    { "checkbox.setEnabled", "checkbox", "setEnabled" }, { "checkbox.setVisible", "checkbox", "setVisible" },
    { "checkbox.remove", "checkbox", "remove" }, { "checkbox.isShown", "checkbox", "isShown" }, { "checkbox.setTooltip", "checkbox", "setTooltip" },
    { "choice.create", "choice", "create" }, { "choice.get", "choice", "get" }, { "choice.set", "choice", "set" },
    { "choice.range", "choice", "range" }, { "choice.setEnabled", "choice", "setEnabled" }, { "choice.setVisible", "choice", "setVisible" },
    { "choice.remove", "choice", "remove" }, { "choice.isShown", "choice", "isShown" }, { "choice.setTooltip", "choice", "setTooltip" },
    { "slider.create", "slider", "create" }, { "slider.get", "slider", "get" }, { "slider.set", "slider", "set" },
    { "slider.setDefault", "slider", "setDefault" }, { "slider.setEnabled", "slider", "setEnabled" }, { "slider.setVisible", "slider", "setVisible" },
    { "slider.remove", "slider", "remove" }, { "slider.isShown", "slider", "isShown" }, { "slider.setTooltip", "slider", "setTooltip" },
    -- Mod Manager v2 story 4 (core 0.25.0): the single-line text box
    { "textbox.create", "textbox", "create" }, { "textbox.set", "textbox", "set" }, { "textbox.get", "textbox", "get" },
    { "textbox.setEnabled", "textbox", "setEnabled" }, { "textbox.setVisible", "textbox", "setVisible" },
    { "textbox.remove", "textbox", "remove" }, { "textbox.isShown", "textbox", "isShown" }, { "textbox.setTooltip", "textbox", "setTooltip" },
    -- core story 31 (core 0.13.0, UI-13): the game screens as hosts (createServer)
    { "game.watch", "game", "watch" }, { "game.unwatch", "game", "unwatch" }, { "game.isOpen", "game", "isOpen" },
    { "place", "place", "place" },
    { "elements", "place", "elements" },
    { "debug.overlaps", "debug", "overlaps" }, -- story 12: a diagnostic for testing a mod's UI
}

-- The rest of the api table (client.lua sets these by hand): name -> "function" | "module".
-- settings: Mod Manager story 5 (core.settings, a module: get, getAll, set, setFor, describe, watch, unwatch).
-- net: core story 22 (core.net, a module: publish, read, watch, unwatch, role; story 23 adds presence, watchPresence,
-- compatible, versionsCompatible).
-- fn: core story 43 (core.fn, a module: intercept, release, runOriginal, list).
-- restart: core story 45 (core.restart, a module: mode, start; Mod Manager story 8's RESTART NOW).
-- input: core story 44 (core.input, a module: control, release, list, state).
-- catalog: Mod Manager v2 story 2 (core.catalog, a module: refresh, download, poll; v2 story 5 adds stage, story 6 unstage).
-- apply: Mod Manager v2 story 3 (core.apply, a module: status, start, ack).
M.BASE = { call = "function", ref = "function", deref = "function", free = "function", clock = "module", settings = "module", net = "module", fn = "module",
    restart = "module", input = "module", catalog = "module", apply = "module" }

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
