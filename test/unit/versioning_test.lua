-- Unit tests for story 18 (versioning), outside the game: nucleus.semver (minimum-version needs, the caret read as a
-- minimum, the floor), nucleus.features (the feature list and the api shape), nucleus.deprecate, and nucleus.client's
-- connect (need validation, the refusal messages, core.has and core.features on a real api table) with UE4SS's
-- globals stubbed. The in-game proof is run.ps1 -Scenario bad-input (versioning cases) and ui (the deprecated op with
-- two dependents).
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/versioning_test.lua
-- (on this workspace's machine: MiKTeX's texlua.exe, which is Lua 5.3).
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

local VERSION = { name = "Nucleus", version = "0.6.0", floor = "0.1.0" }
package.preload["nucleus.version"] = function() return VERSION end
table.insert(package.searchers, 2, function(name)
    local rest = name:match("^nucleus%.(.+)$")
    if not rest then return nil end
    local path = ROOT .. "/lua/pkg/" .. rest:gsub("%.", "/") .. ".lua"
    local f = io.open(path, "r")
    if not f then return "\n\tno file " .. path end
    f:close()
    return assert(loadfile(path)), path
end)

-- Captured output (print is what nucleus.log writes through); results go to the real print.
local LINES = {}
local realPrint = print
print = function(s) LINES[#LINES + 1] = (tostring(s):gsub("\n$", "")) end
local function linesMatching(pat)
    local n = 0
    for _, l in ipairs(LINES) do if l:find(pat) then n = n + 1 end end
    return n
end

local pass, fail = 0, 0
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else fail = fail + 1; realPrint("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")) end
end
local function eq(got, want, name) ok(got == want, name, "got " .. tostring(got) .. ", want " .. tostring(want)) end

-- ---------------------------------------------------------------- semver
local S = require("nucleus.semver")

-- parseNeed: the accepted forms
for _, c in ipairs({ { ">=0.3.0", 0, 3, 0 }, { "^0.2.0", 0, 2, 0 }, { "0.2.0", 0, 2, 0 }, { ">=1.20.300", 1, 20, 300 }, { ">=0.0.0", 0, 0, 0 },
                     { ">=123456789.0.1", 123456789, 0, 1 } }) do
    local n = S.parseNeed(c[1])
    ok(n and n.major == c[2] and n.minor == c[3] and n.patch == c[4], "parseNeed('" .. c[1] .. "')", n and (n.major .. "." .. n.minor .. "." .. n.patch) or "nil")
end
-- parseNeed: refused, never raising (AC 5's list and more)
local refusedNeeds = { { nil, "got nil" }, { "", "is empty" }, { ">=", "is not a minimum" }, { ">=x", "is not a minimum" }, { ">=1.2", "is not a minimum" },
    { "<0.3.0", "is not a minimum" }, { "~0.3.0", "is not a minimum" }, { string.rep("1", 300), "is 300 bytes, cap 64" }, { 3, "got number" },
    { {}, "got table" }, { true, "got boolean" }, { ">= 0.3.0", "is not a minimum" }, { ">=0.3.0 ", "is not a minimum" }, { " >=0.3.0", "is not a minimum" },
    { ">=0.3", "is not a minimum" }, { ">=0.3.0.1", "is not a minimum" }, { ">=0.3.0-beta", "is not a minimum" }, { ">=-1.0.0", "is not a minimum" },
    { ">=1234567890.0.0", "is not a minimum" }, { "^^0.3.0", "is not a minimum" }, { ">=^0.3.0", "is not a minimum" }, { "=0.3.0", "is not a minimum" },
    { ">0.3.0", "is not a minimum" }, { ">=0.3.x", "is not a minimum" }, { "0.3.0\0", "is not a minimum" }, { "v0.3.0", "is not a minimum" } }
for i, c in ipairs(refusedNeeds) do
    local okP, n, why = pcall(S.parseNeed, c[1])
    ok(okP and n == nil and type(why) == "string" and why:find(c[2], 1, true), "parseNeed refuses case " .. i .. " (" .. tostring(c[1]):sub(1, 20) .. ")", tostring(why))
end
eq(select(2, S.parseNeed(">=" .. string.rep("9", 62))), "is not a minimum version (want '>=X.Y.Z')", "parseNeed: exactly 64 bytes is checked, not capped")
ok(select(2, S.parseNeed(">=" .. string.rep("9", 63))):find("is 65 bytes, cap 64", 1, true), "parseNeed: 65 bytes is over the cap")

-- compare
eq(S.compare("0.4.0", "0.3.9"), 1, "compare: minor beats patch")
eq(S.compare("0.4.0", "0.4.0"), 0, "compare: equal")
eq(S.compare("0.10.0", "0.9.0"), 1, "compare: numeric, not lexical")
eq(S.compare("1.0.0", "0.99.99"), 1, "compare: major first")
eq(S.compare("x", "0.1.0"), nil, "compare: unparsable is nil")

-- AC 1: core 0.4.0 accepts older needs, caret and bare included
for _, need in ipairs({ ">=0.1.0", ">=0.2.0", ">=0.3.0", ">=0.4.0", "^0.2.0", "^0.3.0", "0.2.0", "0.3.0", "^0.4.0" }) do
    ok(S.check("0.4.0", need, "0.1.0") == true, "AC 1: 0.4.0 accepts " .. need)
    ok(S.satisfies("0.4.0", need), "AC 1: satisfies(0.4.0, " .. need .. ")")
end
-- newer cores keep accepting (core only ever adds)
for _, have in ipairs({ "0.4.1", "0.5.0", "0.99.0", "1.0.0", "2.3.4" }) do
    ok(S.check(have, ">=0.2.0", "0.1.0") == true, "a newer core " .. have .. " accepts >=0.2.0")
end
-- AC 2: too old a core
for _, need in ipairs({ ">=0.5.0", "^0.5.0", "0.5.0", ">=0.4.1", ">=1.0.0" }) do
    local r, kind = S.check("0.4.0", need, "0.1.0")
    ok(r == false and kind == "core-too-old", "AC 2: 0.4.0 refuses " .. need .. " as core-too-old", kind)
end
-- AC 3: below the floor (a test build with floor 0.3.0)
do
    local r, kind = S.check("0.4.0", ">=0.2.0", "0.3.0")
    ok(r == false and kind == "mod-too-old", "AC 3: floor 0.3.0 refuses >=0.2.0 as mod-too-old", kind)
    ok(S.check("0.4.0", ">=0.3.0", "0.3.0") == true, "AC 3: the floor itself is served")
    ok(S.check("0.4.0", "^0.2.0", "0.3.0") == false, "AC 3: a caret need below the floor is refused too")
    ok(S.check("0.4.0", ">=0.2.0", nil) == true, "no floor: no floor check")
    ok(S.check("0.4.0", ">=0.2.0", "junk") == true, "an unparsable floor is no floor")
    ok(not S.satisfies("0.4.0", ">=0.2.0", "0.3.0"), "satisfies with a floor")
end
do
    local r, kind = S.check("0.4.0", ">=x", "0.1.0"); ok(r == false and kind == "bad-need", "check: bad need", kind)
    r, kind = S.check(nil, ">=0.1.0", "0.1.0"); ok(r == false and kind == "bad-have", "check: bad have (nil)", kind)
    r, kind = S.check("0.4", ">=0.1.0", "0.1.0"); ok(r == false and kind == "bad-have", "check: bad have (0.4)", kind)
    ok(pcall(S.check, {}, {}, {}), "check never raises")
end
-- parse is unchanged (public since 0.1.0)
ok(S.parse("1.2.3").major == 1 and S.parse(">=1.2.3") == nil and S.parse(5) == nil, "parse: plain X.Y.Z only, as before")

-- ---------------------------------------------------------------- features
local F = require("nucleus.features")
local declared = F.declared()
local want = { "call", "clock", "deref",
    -- core story 43 (0.18.0): core.fn, a module, its entry point hand-named
    "fn", "fn.intercept",
    "free",
    -- core story 44 (0.22.0): core.input, a module, its entry point hand-named
    "input", "input.control",
    "map.setup",
    -- core story 22 (0.11.0): core.net, a module, its functions hand-named; core story 23 (0.12.0): presence, netCompat
    "net", "net.compatible", "net.presence", "net.publish", "net.read", "net.role", "net.unwatch", "net.versionsCompatible", "net.watch",
    "net.watchPresence",
    "ref",
    -- core story 45 (0.20.0): core.restart, a module (mode, start)
    "restart",
    "settings", "ui", "ui.button", "ui.button.icon", "ui.button.setTooltip",
    -- Mod Manager story 4 (0.10.0): the controls, every function hand-named
    "ui.checkbox", "ui.checkbox.create", "ui.checkbox.get", "ui.checkbox.isShown", "ui.checkbox.remove", "ui.checkbox.set", "ui.checkbox.setEnabled",
    "ui.checkbox.setTooltip", "ui.checkbox.setVisible",
    "ui.choice", "ui.choice.create", "ui.choice.game", "ui.choice.get", "ui.choice.isShown", "ui.choice.range", "ui.choice.remove", "ui.choice.set", "ui.choice.setEnabled",
    "ui.choice.setTooltip", "ui.choice.setVisible",
    "ui.debug", "ui.elements",
    -- core story 31 (0.13.0): the game screens as hosts (ui.game by the rule, its first host hand-named)
    "ui.game", "ui.game.createServer",
    "ui.gap.compact", "ui.hud",
    "ui.image", "ui.image.create", "ui.image.isShown", "ui.image.remove", "ui.image.set", "ui.image.setTooltip", "ui.image.setVisible",
    "ui.journal", "ui.journal.regions", "ui.list",
    -- core story 38 (0.16.0): drag to reorder rows in a list
    "ui.list.reorderable",
    "ui.look", "ui.menu", "ui.overflow", "ui.panel", "ui.place",
    -- core story 32 (0.14.0): game containers
    "ui.place.container",
    "ui.row",
    -- core story 33 (0.15.0): game-style rows and the game's picker (ui.choice.game above)
    "ui.row.like", "ui.row.setHelp", "ui.row.setLabel",
    "ui.row.setLocked", -- core story 38
    "ui.screen",
    -- core story 27 (0.12.0): the window card, keys and focus
    "ui.screen.focus", "ui.screen.panel",
    "ui.slider", "ui.slider.create", "ui.slider.get", "ui.slider.isShown", "ui.slider.remove", "ui.slider.set", "ui.slider.setDefault", "ui.slider.setEnabled",
    "ui.slider.setTooltip", "ui.slider.setVisible",
    "ui.text", "ui.text.setTooltip" }
eq(table.concat(declared, ","), table.concat(want, ","), "declared(): the 0.20.0 feature list (map.setup, ui.journal.regions, ui.look, story 24's, story 4's, story 22's, story 23's, story 27's, story 31's, story 32's, story 33's, story 38's and story 43's names hand-named; settings, net, fn, restart), sorted")
-- Core story 44: a 0.21.x core's list answers false for input and input.control; this one true.
do
    local old = {}
    for _, n in ipairs(want) do if n ~= "input" and n ~= "input.control" then old[#old + 1] = n end end
    ok(F.set(old)["input.control"] == nil and F.set(declared)["input"] == true and F.set(declared)["input.control"] == true,
        "0.22.0: input and input.control are features, a 0.21.x core's list has neither")
end
-- Core story 45: a 0.19.x core's list answers false for restart; this one true.
do
    local old = {}
    for _, n in ipairs(want) do if n ~= "restart" then old[#old + 1] = n end end
    ok(F.set(old)["restart"] == nil and F.set(declared)["restart"] == true, "0.20.0: restart is a feature, a 0.19.x core's list has none")
end
-- Core story 43: a 0.17.x core's list answers false for fn and fn.intercept; this one true.
do
    local old = {}
    for _, n in ipairs(want) do if not n:match("^fn") then old[#old + 1] = n end end
    ok(F.set(old)["fn"] == nil and F.set(old)["fn.intercept"] == nil, "a 0.17.x core: core.has('fn.intercept') is false")
    ok(F.set(declared)["fn"] == true and F.set(declared)["fn.intercept"] == true, "0.18.0: fn and fn.intercept are features")
end
-- Core story 38: a 0.15.x core's list answers false for reorderable lists and row.setLocked; this one true.
do
    local new = { ["ui.list.reorderable"] = true, ["ui.row.setLocked"] = true }
    local old = {}
    for _, n in ipairs(want) do if not new[n] then old[#old + 1] = n end end
    for n in pairs(new) do
        ok(F.set(old)[n] == nil, "a 0.15.x core: core.has('" .. n .. "') is false")
        ok(F.set(declared)[n] == true, "0.16.0: " .. n .. " is a feature")
    end
end
-- Core story 33: a 0.14.x core's list answers false for the game-style rows and the game picker; this one true.
do
    local new = { ["ui.row.like"] = true, ["ui.row.setLabel"] = true, ["ui.row.setHelp"] = true, ["ui.choice.game"] = true }
    local later = { ["ui.list.reorderable"] = true, ["ui.row.setLocked"] = true } -- core story 38 (0.16.0)
    local old = {}
    for _, n in ipairs(want) do if not new[n] and not later[n] then old[#old + 1] = n end end
    for n in pairs(new) do
        ok(F.set(old)[n] == nil, "a 0.14.x core: core.has('" .. n .. "') is false")
        ok(F.set(declared)[n] == true, "0.15.0: " .. n .. " is a feature")
    end
end
-- Core story 32: a 0.13.x core's list answers false for ui.place.container; this one true.
do
    local old = {}
    for _, n in ipairs(want) do if n ~= "ui.place.container" then old[#old + 1] = n end end
    ok(F.set(old)["ui.place.container"] == nil, "a 0.13.x core: core.has('ui.place.container') is false")
    ok(F.set(declared)["ui.place.container"] == true, "0.14.0: ui.place.container is a feature")
end
-- Core story 31: a 0.12.x core's list answers false for ui.game and ui.game.createServer; this one true.
do
    local old = {}
    for _, n in ipairs(want) do if not n:match("^ui%.game") then old[#old + 1] = n end end
    ok(F.set(old)["ui.game.createServer"] == nil and F.set(old)["ui.game"] == nil, "a 0.12.x core: core.has('ui.game.createServer') is false")
    ok(F.set(declared)["ui.game"] == true and F.set(declared)["ui.game.createServer"] == true, "0.13.0: ui.game and ui.game.createServer are features")
end
-- Core story 27 (AC 5): a 0.11.0 core's list answers false for ui.screen.focus; this one true.
do
    local old = {}
    for _, n in ipairs(want) do if n ~= "ui.screen.focus" and n ~= "ui.screen.panel" and n ~= "ui.gap.compact" then old[#old + 1] = n end end
    ok(F.set(old)["ui.screen.focus"] == nil, "a 0.11.0 core: core.has('ui.screen.focus') is false")
    ok(F.set(declared)["ui.screen.focus"] == true and F.set(declared)["ui.screen.panel"] == true and F.set(declared)["ui.gap.compact"] == true,
        "0.12.0: ui.screen.focus, ui.screen.panel and ui.gap.compact are features")
end
-- Mod Manager story 4 (AC 4): a 0.9.0 core's list answers false for ui.slider.create; this one true.
do
    local old = {}
    for _, n in ipairs(want) do if not n:match("^ui%.checkbox") and not n:match("^ui%.choice") and not n:match("^ui%.slider") then old[#old + 1] = n end end
    ok(F.set(old)["ui.slider.create"] == nil, "a 0.9.0 core: core.has('ui.slider.create') is false")
    ok(F.set(declared)["ui.slider.create"] and F.set(declared)["ui.choice.range"] and F.set(declared)["ui.checkbox.create"], "this core: core.has('ui.slider.create'), 'ui.choice.range', 'ui.checkbox.create' are true")
end
-- Story 24: what a dependent asks core.has for (AC 5).
do
    local set = F.set(declared)
    for _, n in ipairs({ "ui.image.create", "ui.overflow", "ui.button.icon", "ui.image", "ui.text.setTooltip", "ui.button.setTooltip", "ui.image.set" }) do
        ok(set[n] == true, "story 24: core.has('" .. n .. "') is true")
    end
end
for i = 2, #declared do ok(declared[i - 1] < declared[i], "declared() is sorted and unique at " .. i) end
-- the rule
do
    local f = function() end
    local savedHand = F.HAND; F.HAND = {}
    local got = F.fromApi({ name = "N", version = "1", log = { info = f }, has = f, features = f, call = f,
        mod = { a = f, b = f }, ns = { leaf = f, sub = { x = f }, deep = { m = { y = f } } } })
    eq(table.concat(got, ","), "call,mod,ns,ns.deep,ns.deep.m,ns.leaf,ns.sub", "fromApi: the naming rule (modules not expanded, data skipped)")
    F.HAND = savedHand
    eq(#F.fromApi(nil), #F.HAND, "fromApi(nil): only the hand-named list")
    local saved = F.HAND
    F.HAND = { "ui.panel.reorder" }
    ok(table.concat(F.declared(), ","):find("ui.panel.reorder", 1, true), "HAND entries are listed")
    F.HAND = saved
end
do
    local ui, missing = F.buildUi({ hud = { find = function() end } })
    ok(type(ui.hud) == "table" and type(ui.hud.find) == "function" and ui.text == nil, "buildUi: only what exists")
    ok(#missing == #F.UI - 1, "buildUi: the rest is named missing", #missing)
end

-- ---------------------------------------------------------------- deprecate
local D = require("nucleus.deprecate")
do
    local logged = {}
    local log = { warn = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end }
    ok(D.warn(log, "x()", "y()") == true and D.warn(log, "x()", "y()") == false, "deprecate.warn: once per name")
    eq(#logged, 1, "deprecate.warn: one line")
    ok(logged[1]:find("^DEPRECATED x%(%); use y%(%) instead%.") ~= nil, "deprecate.warn: names the replacement", logged[1])
    D.warn(log, "z()", "w()"); eq(#logged, 2, "deprecate.warn: another name logs its own line")
    local calls = 0
    local w = D.wrap(function() return log end, "old()", "new()", function(a, b) calls = calls + 1 return a + b end)
    eq(w(1, 2), 3, "deprecate.wrap: still works"); eq(w(2, 2), 4, "deprecate.wrap: still works twice")
    eq(calls, 2, "deprecate.wrap: calls through"); eq(#logged, 3, "deprecate.wrap: logs once")
    ok(pcall(D.warn, { warn = function() error("boom") end }, "q", "r"), "deprecate.warn: a throwing logger doesn't escape")
    D._reset()
    eq(D.OPS["deprecated-test"], "version", "the test-only deprecated op maps to version")
end

-- ---------------------------------------------------------------- client (UE4SS stubbed)
local shared = {}
ModRef = { GetSharedVariable = function(_, k) return shared[k] end, SetSharedVariable = function(_, k, v) shared[k] = v end }
local loops = {}
function LoopInGameThreadWithDelay(_, fn) loops[#loops + 1] = fn return #loops end
function CancelDelayedAction(h) loops[h] = function() end return true end
function RegisterHook() return 1, 1 end
function NotifyOnNewObject() end
function FindAllOf() return nil end
function FName(s) return s end
function FText(s) return { s = s } end
function LoopAsync() end
function ExecuteInGameThread() end
function ExecuteInGameThreadWithDelay() end
local CALLS = {}
local cdo = { IsValid = function() return true end,
    Nucleus_Call = function(_, req)
        CALLS[#CALLS + 1] = req
        if req == "ping" then return "ok:pong " .. tostring(shared["nucleus.version"]) .. " boot=1" end
        if req == "version" or req == "deprecated-test" then return "ok:" .. tostring(shared["nucleus.version"]) end
        return "err:unknown-op " .. req
    end }
local cls = { IsValid = function() return true end }
local INVALID = { IsValid = function() return false end }
function StaticFindObject(path)
    if path == "/Game/Mods/Nucleus/ModActor.Default__ModActor_C" then return cdo end
    if path == "/Game/Mods/Nucleus/ModActor.ModActor_C" then return cls end
    return INVALID
end
Nucleus_NativeVersion = function() return "0.6.0", "v3.0.1-1181-g83330635" end
Nucleus_ClockMicros = function() return 0 end

local Cl = require("nucleus.client")
local function runLoops() for i = 1, #loops do loops[i]() end end

-- every UI function features.UI names exists in the real modules
for _, e in ipairs(F.UI) do
    local okM, m = pcall(require, "nucleus.ui." .. e[2])
    ok(okM and type(m[e[3]]) == "function", "features.UI: ui." .. e[2] .. "." .. e[3] .. " exists", okM and type(m[e[3]]) or m)
end

-- AC 5: connect's bad needs: false, the message, onFail once, one line, no loop, no raise
local function probe(need, setNeed)
    local before, loopsBefore, calls, got = #LINES, #loops, 0, nil
    local opts = { mod = "Probe", onFail = function(m) calls = calls + 1; got = m end }
    if setNeed then opts.need = need end
    local okC, r, msg = pcall(Cl.connect, opts)
    return okC, r, msg, calls, got, #LINES - before, #loops - loopsBefore
end
for i, c in ipairs(refusedNeeds) do
    local okC, r, msg, calls, got, nLines, nLoops = probe(c[1], true)
    ok(okC and r == false and type(msg) == "string" and msg:find("connect: need ", 1, true) and msg:find(c[2], 1, true)
        and msg:find(" Probe will not run.", 1, true) and calls == 1 and got and msg:sub(1, #got) == got and nLines == 1 and nLoops == 0,
        "AC 5: connect refuses bad need " .. i .. " (" .. tostring(c[1]):sub(1, 20) .. ")", tostring(msg) .. " calls=" .. calls .. " lines=" .. nLines .. " loops=" .. nLoops)
end
do
    local okC, r, msg, calls = probe(nil, false)
    ok(okC and r == false and msg:find("must be a string like '>=0.5.0', got nil", 1, true) and calls == 1, "AC 5: connect with no need", msg)
    ok(LINES[#LINES]:find("^%[Probe%] ERROR connect: need must be a string") ~= nil, "AC 5: the line is the mod's, at ERROR", LINES[#LINES])
    local _, _, m300 = probe(string.rep("a", 300), true)
    ok(#m300 < 400 and m300:find(string.rep("a", 64) .. "' is 300 bytes", 1, true), "AC 5: a 300-char need is echoed capped at 64", #m300)
    local _, _, mctl = probe("\1\2>=", true)
    ok(not mctl:find("[%c]"), "AC 5: control bytes in a need aren't echoed", mctl)
end
do
    local okC, r, msg = pcall(Cl.connect, nil)
    ok(okC and r == false and msg:find("needs a table with a string mod, got nil", 1, true), "connect(nil): false, message, no raise", msg)
    local calls = 0
    okC, r, msg = pcall(Cl.connect, { mod = 5, need = ">=0.1.0", onFail = function() calls = calls + 1 end })
    ok(okC and r == false and msg:find("got table with mod number", 1, true) and calls == 1, "connect{ mod = 5 }: false, onFail once", msg)
    ok(LINES[#LINES]:find("^%[Nucleus client%] ERROR ") ~= nil, "connect{ mod = 5 }: one line, tagged by the client", LINES[#LINES])
    okC, r = pcall(Cl.connect, "x")
    ok(okC and r == false, "connect('x'): false, no raise")
end

-- AC 1-3: the refusal messages, exactly
eq(Cl._compatMessage("0.4.0", ">=0.3.0", "Clock", "0.1.0"), nil, "compatible: nil")
eq(Cl._compatMessage("0.4.0", "^0.2.0", "Clock", "0.1.0"), nil, "compatible: an old caret need")
eq(Cl._compatMessage("0.4.0", ">=0.5.0", "Clock", "0.1.0"), "Nucleus 0.4.0 is older than Clock needs (>=0.5.0). Update Nucleus.", "AC 2: the 'Update Nucleus' message")
eq(Cl._compatMessage("0.4.0", "^0.5.0", "Clock", "0.1.0"), "Nucleus 0.4.0 is older than Clock needs (^0.5.0). Update Nucleus.", "AC 2: caret, 'Update Nucleus'")
eq(Cl._compatMessage("0.4.0", ">=0.2.0", "Clock", "0.3.0"),
    "Clock was made for Nucleus >=0.2.0, which this Nucleus 0.4.0 no longer supports (oldest: 0.3.0). Update Clock.", "AC 3: the 'Update <mod>' message")
eq(Cl._compatMessage("junk\1", ">=0.2.0", "Clock", "0.1.0"), "Nucleus reports version 'junk?', which isn't X.Y.Z; reinstall Nucleus.", "an unparsable core version")

-- A full connect: a too-old core, through the loop (the attempt reads the published version)
local function connectWith(version, need)
    shared["nucleus.state"], shared["nucleus.version"] = "ready", version
    local res = { ready = nil, failed = nil }
    local r = Cl.connect{ mod = "Dep", need = need, onReady = function(core) res.ready = core end, onFail = function(m) res.failed = m end }
    runLoops()
    return r, res
end
do
    local r, res = connectWith("0.4.0", ">=0.5.0")
    ok(r == true and res.ready == nil and res.failed == "Nucleus 0.4.0 is older than Dep needs (>=0.5.0). Update Nucleus.", "AC 2 via connect: refused in the loop", res.failed)
    ok(LINES[#LINES] == "[Dep] ERROR Nucleus 0.4.0 is older than Dep needs (>=0.5.0). Update Nucleus. Dep will not run.", "AC 2 via connect: the one line", LINES[#LINES])
end

-- The real connect: core.has and core.features over a real api table (AC 4)
local core
do
    local r, res = connectWith("0.5.0", "^0.3.0")
    core = res.ready
    ok(r == true and type(core) == "table", "connect with an old caret need on 0.5.0: onReady", res.failed)
end
if core then
    eq(table.concat(core.features(), ","), table.concat(declared, ","), "AC 4: core.features() equals declared() (the READY line)")
    for _, n in ipairs(core.features()) do ok(core.has(n) == true, "AC 4: core.has('" .. n .. "')") end
    for _, n in ipairs({ "ui.text", "ui.panel", "ui.button", "ui.journal" }) do ok(core.has(n) == true, "AC 4: the story's names: " .. n) end
    for i, bad in ipairs({ "ui.nosuch", "ui.text.create", "version", "name", "log", "has", "features", "", string.rep("u", 300), 42, {}, true, false }) do
        local okH, v = pcall(core.has, bad)
        ok(okH and v == false, "AC 4/5: core.has(bad " .. i .. ") is false without error", tostring(v))
    end
    local okN, vN = pcall(core.has); ok(okN and vN == false, "AC 5: core.has() is false")
    local okN2, vN2 = pcall(core.has, nil); ok(okN2 and vN2 == false, "AC 5: core.has(nil) is false")
    local a = core.features(); a[1] = "x"; a[#a + 1] = "y"
    eq(table.concat(core.features(), ","), table.concat(declared, ","), "core.features() returns a fresh copy")
    ok(core.has("x") == false and core.has("y") == false, "changing the copy changes nothing")
    -- AC 8: the deprecated op works and logs one DEPRECATED line for this dependent
    local before = linesMatching("DEPRECATED")
    local ok1, v1 = core.call("deprecated-test")
    local ok2, v2 = core.call("deprecated-test")
    ok(ok1 and v1 == "0.5.0" and ok2 and v2 == "0.5.0", "AC 8: the deprecated op still works", tostring(v1) .. " " .. tostring(v2))
    eq(linesMatching("DEPRECATED") - before, 1, "AC 8: one DEPRECATED line for two calls")
    ok(LINES[#LINES]:find("^%[Dep%] WARN DEPRECATED channel op 'deprecated%-test'; use 'version' instead%.") ~= nil, "AC 8: tagged with the dependent, names the replacement", LINES[#LINES])
    local ok3 = core.call("version"); ok(ok3, "the replacement works")
    eq(linesMatching("DEPRECATED") - before, 1, "AC 8: the replacement logs nothing")
    -- the old surface is all still there (guard: core only ever adds)
    for _, k in ipairs({ "name", "version", "log", "call", "ref", "deref", "free", "clock" }) do ok(core[k] ~= nil, "api keeps " .. k) end
end

-- ---------------------------------------------------------------- the host gate (distribution story 14)
eq(Cl._dormant("host", nil, false), true, "_dormant: host scope, no role yet: dormant")
eq(Cl._dormant("host", "none", false), true, "_dormant: host scope at the title (role none): dormant")
eq(Cl._dormant("host", "client", false), true, "_dormant: host scope on a client: dormant")
eq(Cl._dormant("host", "standalone", false), true, "_dormant: host scope, standalone: dormant")
eq(Cl._dormant("host", "host", false), false, "_dormant: host scope while hosting: ready")
eq(Cl._dormant("host", "client", true), false, "_dormant: dormant = false opts out")
for _, sc in ipairs({ "client", "host-plus", "both", "all", "Host", "", "either" }) do
    eq(Cl._dormant(sc, "client", false), false, "_dormant: scope '" .. sc .. "' never waits")
end
eq(Cl._dormant(nil, "client", false), false, "_dormant: a missing scope never waits")
eq(Cl._dormant(42, "client", false), false, "_dormant: a non-string scope never waits")

-- The gate through connect: mod.json read through core.net's ownManifest (stubbed here), the role from the shared variable.
do
    local NetC = require("nucleus.net.client")
    local realFind, realMan = NetC.findOwn, NetC.ownManifest
    local scopeNow
    NetC.findOwn = function() return "D", "Dep" end
    NetC.ownManifest = function() return { id = "a.dep", version = "0.1.0", scope = scopeNow, notes = {} } end
    local function gated(scope, role, extra)
        scopeNow = scope
        shared["nucleus.state"], shared["nucleus.version"], shared["nucleus.net.role"] = "ready", "0.6.0", role
        local res = { ready = 0, failed = nil }
        local o = { mod = "Gate", need = ">=0.1.0", onReady = function() res.ready = res.ready + 1 end, onFail = function(m) res.failed = m end }
        for k, v in pairs(extra or {}) do o[k] = v end
        local r = Cl.connect(o)
        return r, res
    end
    local pings = function() local n = 0 for _, c in ipairs(CALLS) do if c == "ping" then n = n + 1 end end return n end

    local before = linesMatching("CONNECT dormant")
    local r, res = gated("host", "none")
    runLoops(); runLoops(); runLoops()
    ok(r == true and res.ready == 0 and res.failed == nil, "gate: a host mod at the title gets no onReady", res.failed)
    eq(linesMatching("CONNECT dormant") - before, 1, "gate: one dormant line for three attempts")
    ok(linesMatching("^%[Gate%] CONNECT dormant Gate: scope host, waiting until this machine hosts$") >= 1, "gate: the dormant line's text", LINES[#LINES])
    local p0 = pings(); runLoops(); eq(pings() - p0, 0, "gate: a dormant attempt doesn't call core")
    shared["nucleus.net.role"] = "client"; runLoops()
    ok(res.ready == 0 and res.failed == nil, "gate: still dormant on a client")
    local okBefore = linesMatching("CONNECT ok")
    shared["nucleus.net.role"] = "host"; runLoops()
    eq(res.ready, 1, "gate: onReady once this machine hosts")
    eq(linesMatching("CONNECT ok") - okBefore, 1, "gate: CONNECT ok after hosting")
    shared["nucleus.net.role"] = "client"; runLoops(); shared["nucleus.net.role"] = "host"; runLoops()
    eq(res.ready, 1, "gate: onReady exactly once (per machine, not per world)")

    r, res = gated("host", "none", { dormant = false })
    runLoops()
    eq(res.ready, 1, "gate: dormant = false gets onReady at once")
    for _, sc in ipairs({ "client", "host-plus", "both", "all" }) do
        r, res = gated(sc, "none")
        runLoops()
        eq(res.ready, 1, "gate: scope '" .. sc .. "' gets onReady at the title")
    end
    r, res = gated(nil, "client")
    runLoops()
    eq(res.ready, 1, "gate: a missing scope gets onReady")
    local warnBefore = linesMatching("dormant must be false or left out")
    r, res = gated("host", "none", { dormant = "no" })
    runLoops()
    ok(res.ready == 0 and linesMatching("dormant must be false or left out") - warnBefore == 1, "gate: a non-boolean dormant is reported once and ignored")
    shared["nucleus.net.role"] = "host"; runLoops()
    eq(res.ready, 1, "gate: ... and the gate still applies")
    NetC.findOwn, NetC.ownManifest = realFind, realMan
    shared["nucleus.net.role"] = nil
end

print = realPrint
print(string.format("versioning_test: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
