-- <Core>SkelTest: throwaway dependent that proves core's walking skeleton unattended (spec-core-v0 CAP-8).
-- Never shipped. The skeleton deliberately avoids the UI-helper API (it inserts its text widget into the HUD by hand,
-- so it proves the widget and the natives on their own); ui, bad-input and manual use core.ui.
-- deploy.ps1 installs it as Mods/<Core>SkelTest (from test/SkelTest) and writes the scenario to scenario.txt here.
--
-- skeleton:  calls <Core>_NativeVersion during main.lua; connects through the bootstrap + client.connect; travels
--            menu -> SmallMap?listen -> menu -> SmallMap?listen with OpenLevel. In each world it re-finds the live
--            HUD, shows one text widget anchored to the top-right corner of InventoryUI_C.OwningCanvas, re-finds it by
--            weak handle, checks its layout, and checks that the previous world's widget handle derefs to nil. In
--            each match it also times <Core>_Ref, and makes the hard overlap check (story 12 AC 6): core's overlap walk
--            (ui/debug.lua) must find no drawn widget under the top-right widget.
-- bad-input: menu -> SmallMap?listen; calls every public native, the channel and every core.ui function with bad
--            values (bad-input cases below), on and off the game thread and before connect, and checks each answer
--            against the contract.
-- ui:        the UI helpers (stories 7-10) unattended: menu -> match -> (RemoveAllWidgets and re-add) -> menu -> match,
--            with elements created before the first match, same id twice, set and its no-op, long text, remove, style,
--            setVisible, all four corners and gaps, offset, absolute, a three-element stack, near the crosshair with
--            HideCrosshair, an element moved onto the crosshair reporting it (story 12 AC 2), a late and a throwing
--            watcher, and handles freed across map changes (buildUi below).
-- manual:    for hand testing. Never travels, requests keys, runs timed checks or logs FAIL. Keeps a
--            "<Core> manual: <n>" element in the top-right corner of the HUD through core.ui.text (core re-attaches it
--            whenever the HUD is rebuilt, replaced or put back in the viewport; n counts attaches), and logs reports
--            (core.ui.debug.overlaps) of the drawn widgets its on-screen rectangle overlaps.
-- Keys it can't press itself (Enter for touchdown) go to run.ps1 through request.txt / done.txt next to this file.
-- Never keeps a UObject across steps: only paths, addresses (as integers, never dereferenced) and weak handles.
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local ME = scriptDir:match("([^/\\]+)[/\\][Ss]cripts$")
local CORE = ME:match("^(.-)SkelTest$") -- the one place the core's name comes from: this folder's name
local NEED = "0.2.0"

local function say(fmt, ...) print("[" .. ME .. "] " .. string.format(fmt, ...) .. "\n") end

local SCENARIO = "skeleton"
do
    local f = io.open(scriptDir .. "\\scenario.txt", "r")
    if f then SCENARIO = (f:read("*a") or ""):match("^%s*([%w%-]+)") or SCENARIO; f:close() end
end
say("SCENARIO %s (core %s)", SCENARIO, CORE)

-- 1. Native call during main.lua (before any world exists).
do
    local fn = _G[CORE .. "_NativeVersion"]
    if type(fn) == "function" then
        local ok, v, ue = pcall(fn)
        say("NATIVE main.lua %s_NativeVersion ok=%s version=%s ue4ss=%s", CORE, tostring(ok), tostring(v), tostring(ue))
    else
        say("NATIVE main.lua %s_NativeVersion missing (type=%s)", CORE, type(fn))
    end
    local clock = _G[CORE .. "_ClockMicros"]
    if type(clock) == "function" then
        local ok, us = pcall(clock)
        say("NATIVE main.lua %s_ClockMicros ok=%s type=%s", CORE, tostring(ok), ok and tostring(math.type(us)) or tostring(us))
    end
end

-- 2. The bootstrap every dependent carries (api-contract.md, "Dependent bootstrap").
local mods = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts[/\\]")
package.path = package.path .. ";" .. mods .. "/" .. CORE .. "/Scripts/?.lua"
local okReq, client = pcall(require, CORE:lower() .. ".client")
if not okReq then
    say("%s is not installed. %s will not run. (%s)", CORE, ME, tostring(client))
    if SCENARIO ~= "manual" then say("END result=FAIL failures=1 reason=import") end
    return
end

-- 3. UI helpers called before connect (bad-input): each must raise "<core>.ui: <fn> called before connect".
-- Recorded now, reported as cases once the scenario runs.
local PRE_CONNECT = {}
if SCENARIO == "bad-input" then
    local function try(id, desc, modName, fnName, ...)
        local okM, m = pcall(require, CORE:lower() .. ".ui." .. modName)
        local args = table.pack(...)
        if not okM then PRE_CONNECT[#PRE_CONNECT + 1] = { id = id, desc = desc, ok = false, err = "require failed: " .. tostring(m) } return end
        local r = table.pack(pcall(m[fnName], table.unpack(args, 1, args.n)))
        PRE_CONNECT[#PRE_CONNECT + 1] = { id = id, desc = desc, ok = r[1], err = r[2], fn = fnName }
    end
    try("pre-create", "ui.text.create{ id = 'early' } [before connect]", "text", "create", { id = "early" })
    try("pre-watch", "ui.hud.watch(fn) [before connect]", "hud", "watch", function() end)
    try("pre-find", "ui.hud.find() [before connect]", "hud", "find")
    try("pre-elements", "ui.elements() [before connect]", "place", "elements")
    try("pre-overlaps", "ui.debug.overlaps({}) [before connect]", "debug", "overlaps", {})
end

local REQ, DONE = scriptDir .. "\\request.txt", scriptDir .. "\\done.txt"
os.remove(REQ); os.remove(DONE)

local MENU_MAP = "/Game/Maps/NewMainMenu"
local MATCH_MAP = "/Game/Maps/SmallLoweIsland/SmallMap"
local TEXT_PKG = "/Game/Mods/" .. CORE .. "/WBP_" .. CORE .. "Text"
local TEXT_CLASS = TEXT_PKG .. ".WBP_" .. CORE .. "Text_C"
local ACTOR_CDO = "/Game/Mods/" .. CORE .. "/ModActor.Default__ModActor_C"
local MARGIN = 16 -- canvas units between the widget and the canvas's top and right edges

local core -- set in onReady: the api table (no UObjects inside)
local S = { failures = 0, checks = 0 }

local function valid(o) return o ~= nil and o:IsValid() end
local function found(path) local o = path and StaticFindObject(path) return valid(o) and o or nil end
local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end
local function check(cond, fmt, ...)
    S.checks = S.checks + 1
    if not cond then S.failures = S.failures + 1 end
    say("%s " .. fmt, cond and "OK" or "FAIL", ...)
    return cond
end
local function pc() return FindFirstOf("PlayerController") end
local function worldName() local p = pc() return valid(p) and p:GetWorld():GetFullName() or "" end
local function GS() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
local function WBL() return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary") end
local function WLL() return StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end
local function native(suffix) return _G[CORE .. suffix] end

local function liveHud()
    local n, hit = 0, nil
    for _, w in ipairs(FindAllOf("InventoryUI_C") or {}) do
        if valid(w) and w:IsInViewport() then n = n + 1; hit = hit or w end
    end
    return hit, n
end

local function textClass()
    local cls = found(TEXT_CLASS)
    if cls then return cls end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    cls = helpers:GetAsset({ PackageName = FName(TEXT_PKG), AssetName = FName("WBP_" .. CORE .. "Text_C") })
    return valid(cls) and cls or nil
end

local seq = 0
local function request(cmd)
    seq = seq + 1
    local f = io.open(REQ, "w"); f:write(seq .. " " .. cmd); f:close()
    local mine = seq
    return function()
        local d = io.open(DONE, "r")
        if not d then return false end
        local s = d:read("*a"); d:close()
        return tonumber(s) == mine
    end
end
local function after(sec) local t = os.time() + sec return function() return os.time() >= t end end

-- ---------------------------------------------------------------- steps
local steps = {}
local function step(name, fn) steps[#steps + 1] = { name = name, fn = fn } end

local function waitWorld(phase, mapPart, timeout)
    step(phase .. ": world", function()
        return function()
            if worldName():find(mapPart, 1, true) then say("WORLD %s %s", phase, worldName():match("/Game/[^ ]+") or "?") return true end
            return false
        end, timeout, phase .. " world " .. mapPart
    end)
end

local function waitHud(phase, timeout)
    step(phase .. ": hud", function()
        local since
        return function()
            local hud, n = liveHud()
            if hud then
                since = since or os.time()
                -- Let the HUD settle (the match HUD is rebuilt right after touchdown).
                if os.time() - since >= 3 then
                    S.hudPath = pathOf(hud)
                    say("HUD %s live=%s inViewportCount=%d", phase, S.hudPath, n)
                    return true
                end
            end
            return false
        end, timeout, phase .. " live HUD"
    end)
end

-- The previous world's widget must be gone: its weak handle derefs to nil, and its path no longer resolves.
local function checkPrevious(phase)
    step(phase .. ": previous widget gone", function()
        if not S.prev then return end
        local obj = core.deref(S.prev.handle)
        if obj ~= nil then
            say("DEREF %s previous (%s) still alive right after travel; forcing GC", phase, S.prev.phase)
            StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
            return after(2), 5, "gc"
        end
    end)
    step(phase .. ": previous widget deref", function()
        if not S.prev then return end
        local obj = core.deref(S.prev.handle)
        check(obj == nil, "DEREF %s previous widget from %s -> %s", phase, S.prev.phase, obj == nil and "nil" or pathOf(obj))
        check(found(S.prev.path) == nil, "PATH %s previous widget path resolves=%s (%s)", phase, tostring(found(S.prev.path) ~= nil), S.prev.path)
        core.free(S.prev.handle)
        S.gone = S.prev -- its address (an integer) is kept for the bad-input "destroyed widget" case
        S.prev = nil
    end)
end

-- Creates the text widget in the live HUD's canvas, anchored to the canvas's top-right corner.
local function createWidget(phase)
    local hud = found(S.hudPath)
    if not check(hud ~= nil, "HUD %s re-found by path %s", phase, tostring(S.hudPath)) then return end
    local cls = textClass()
    if not check(cls ~= nil, "TEXTCLASS %s loaded %s", phase, TEXT_CLASS) then return end
    local w = WBL():Create(hud:GetWorld() or pc():GetWorld(), cls, pc())
    if not check(valid(w), "CREATE %s text widget", phase) then return end
    w:SetText(CORE .. " skeleton: " .. phase)
    local slot = hud.OwningCanvas:AddChildToCanvas(w)
    slot:SetAutoSize(true)
    slot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
    slot:SetAlignment({ X = 1, Y = 0 })
    slot:SetPosition({ X = -MARGIN, Y = MARGIN })
    S.cur = { phase = phase, handle = core.ref(w), path = pathOf(w), address = w:GetAddress() }
    say("WIDGET %s created %s parent=%s anchors=(1,0) alignment=(1,0) position=(%d,%d)", phase, S.cur.path, pathOf(w:GetParent()), -MARGIN, MARGIN)
    return after(1), 3, "layout"
end

local function near(a, b) return math.abs(a - b) <= 0.5 end

-- Hard check: the widget sits in the canvas's top-right corner, MARGIN from both edges, and inside the canvas.
-- Its rectangle in canvas space comes from what the game reports: the slot's anchors, alignment and position read
-- back from the slot, the widget's desired size (non-zero only once Slate has measured it), and the canvas's size
-- (the viewport in pixels divided by the viewport's DPI scale; InventoryUI_C fills the viewport).
local function checkCorner(phase, w, hud)
    local slot = w.Slot
    local an, al, pos = slot:GetAnchors(), slot:GetAlignment(), slot:GetPosition()
    local ds = w:GetDesiredSize()
    local world = hud:GetWorld()
    local vp, scale = WLL():GetViewportSize(world), WLL():GetViewportScale(world)
    local cw, ch = vp.X / scale, vp.Y / scale
    local left = an.Minimum.X * cw + pos.X - al.X * ds.X
    local top = an.Minimum.Y * ch + pos.Y - al.Y * ds.Y
    local right, bottom = left + ds.X, top + ds.Y
    say("GEOM %s canvas=(%.0fx%.0f) viewport=(%.0fx%.0f) dpi=%.3f anchors=(%.2f,%.2f)-(%.2f,%.2f) alignment=(%.2f,%.2f) position=(%.1f,%.1f) desired=(%.1fx%.1f) rect=(%.1f,%.1f)-(%.1f,%.1f)",
        phase, cw, ch, vp.X, vp.Y, scale, an.Minimum.X, an.Minimum.Y, an.Maximum.X, an.Maximum.Y, al.X, al.Y, pos.X, pos.Y, ds.X, ds.Y, left, top, right, bottom)
    local slotOk = near(an.Minimum.X, 1) and near(an.Maximum.X, 1) and near(an.Minimum.Y, 0) and near(an.Maximum.Y, 0)
        and near(al.X, 1) and near(al.Y, 0) and near(pos.X, -MARGIN) and near(pos.Y, MARGIN)
    local measured = ds.X > 0 and ds.Y > 0 and cw > 0 and ch > 0
    local corner = near(cw - right, MARGIN) and near(top, MARGIN)
    local inside = left >= 0 and top >= 0 and right <= cw and bottom <= ch
    local topRight = left > cw / 2 and bottom < ch / 2
    check(slotOk and measured and corner and inside and topRight and w:IsVisible(),
        "CORNER %s widget is in the canvas's top-right corner: rect=(%.0f,%.0f)-(%.0f,%.0f) gapRight=%.1f gapTop=%.1f canvas=(%.0fx%.0f) slot=%s measured=%s inside=%s visible=%s",
        phase, left, top, right, bottom, cw - right, top, cw, ch, tostring(slotOk), tostring(measured), tostring(inside), tostring(w:IsVisible()))
end

-- Story 12 AC 6, the hard overlap check: the top-right widget must overlap no drawn game widget. The check is core's
-- (ui/debug.lua, the engine behind core.ui.debug.overlaps), run on this hand-made widget; it waits until Slate has
-- painted the widget (geometry is zero before). One FAIL line per overlapping widget, naming it.
local function rectStr(r) return string.format("(%.0f,%.0f)-(%.0f,%.0f)", r.l, r.t, r.r, r.b) end
local function shortList(list, n)
    local out = {}
    for i = 1, math.min(#list, n) do
        local h = list[i]
        out[#out + 1] = string.format("%s (%s) %s", h.path:match("[^%.:]+$") or h.path, h.class, rectStr(h.rect))
    end
    return #out > 0 and table.concat(out, "; ") or "none"
end
local function line1(e) return (tostring(e):match("^[^\n]*")) end
local function overlapCheck(phase)
    step(phase .. ": overlap wait", function()
        S.ov = nil
        if not S.prev then return end
        local okD, Dm = pcall(require, CORE:lower() .. ".ui.debug")
        if not okD then S.ov = { why = "core's ui.debug did not load: " .. line1(Dm) } return end
        return function()
            local w, hud = core.deref(S.prev.handle), found(S.hudPath)
            if not (w and hud) then S.ov = { why = "the widget or the HUD is gone" } return true end
            local ok, hits, info = pcall(Dm._check, hud, w)
            if not ok then S.ov = { why = "the check raised: " .. line1(hits) } return true end
            if hits == nil and tostring(info):find("not painted", 1, true) then S.ov = { why = info } return false end
            S.ov = hits and { hits = hits, info = info } or { why = info }
            return true
        end, 10, phase .. " overlap check (widget painted)"
    end)
    step(phase .. ": overlap", function()
        local ov = S.ov or { why = "no result" }
        if not ov.hits then check(false, "OVERLAP %s could not check the top-right widget: %s", phase, tostring(ov.why)) return end
        local i = ov.info
        say("OVERLAP %s ours=%s screen=(%.0fx%.0f) checked=%d drawn=%d topRightQuarter=%d fullScreenSkipped=%d roots=%d via %s errors=%d capped=%s",
            phase, rectStr(i.rect), i.screen.w, i.screen.h, i.checked, i.drawn, i.quadrant, i.fullScreen, i.roots, tostring(i.via), i.errors, tostring(i.capped))
        say("OVERLAP %s nearby (within 64 px, not overlapping): %s", phase, shortList(i.nearby, 10))
        for n, h in ipairs(ov.hits) do
            check(false, "OVERLAP %s the top-right widget overlaps %s (%s) %s%s", phase, h.path, h.class, rectStr(h.rect), h.element and (" element " .. h.element) or "")
            if n >= 20 then break end
        end
        if #ov.hits == 0 then
            check(i.checked > 0 and not i.capped, "OVERLAP %s none: the top-right widget overlaps no drawn widget (checked %d widgets, %d drawn, screen %.0fx%.0f%s)",
                phase, i.checked, i.drawn, i.screen.w, i.screen.h, i.capped and ", CAPPED" or "")
        end
    end)
end

local function showWidget(phase)
    step(phase .. ": show widget", function() return createWidget(phase) end)
    step(phase .. ": refind and check", function()
        if not S.cur then return end
        local w = core.deref(S.cur.handle)
        if not check(w ~= nil and pathOf(w) == S.cur.path, "REFIND %s widget by handle -> %s", phase, w and pathOf(w) or "nil") then return end
        local hud = found(S.hudPath)
        local parent = w:GetParent()
        check(valid(parent) and hud ~= nil and pathOf(parent) == pathOf(hud.OwningCanvas),
            "PARENT %s widget is in the live HUD canvas (%s)", phase, valid(parent) and pathOf(parent) or "none")
        -- ESlateVisibility 1 = Collapsed, 2 = Hidden: the game hides the whole HUD (the main menu does), so children
        -- are parented but neither laid out nor drawn.
        local vis = tonumber(hud:GetVisibility())
        say("HOST %s HUD visibility=%s", phase, tostring(vis))
        if vis == 1 or vis == 2 then
            check(not phase:find("match", 1, true), "HIDDENHUD %s the game hides InventoryUI_C here (visibility=%d); the widget is parented but not drawn", phase, vis)
        else
            checkCorner(phase, w, hud)
        end
        S.prev, S.cur = S.cur, nil
    end)
    if phase:find("match", 1, true) then overlapCheck(phase) end
end

-- Cost of <Core>_Ref (a GUObjectArray scan) on a live object in this world.
local function refCost(phase, n)
    step(phase .. ": ref cost", function()
        local hud = found(S.hudPath)
        if not hud then return end
        local ref, free = native("_Ref"), native("_RefFree")
        local addr = hud:GetAddress()
        local handles = {}
        local t0 = os.clock()
        for i = 1, n do handles[i] = ref(addr) end
        local dt = os.clock() - t0
        for i = 1, n do free(handles[i]) end
        say("REFCOST %s n=%d total=%.1f ms avg=%.3f ms per call (Lua os.clock; see native REF_COST lines for per-call ns)", phase, n, dt * 1000, dt * 1000 / n)
    end)
end

local function travel(phase, map, options)
    step(phase .. ": travel", function()
        say("TRAVEL %s OpenLevel %s%s", phase, map, options ~= "" and ("?" .. options) or "")
        GS():OpenLevel(pc(), FName(map), true, options)
        return after(3), 5, "travel start"
    end)
end

local function touchdown(phase)
    step(phase .. ": touchdown", function()
        say("TOUCHDOWN %s requesting Enter", phase)
        return request("key ENTER"), 20, "touchdown key"
    end)
end

-- ---------------------------------------------------------------- bad-input cases
-- Each case calls one thing and states what the contract says it must produce. Logged one per line:
--   OK|FAIL CASE <id> <call> -> <what happened> (expected <what>)
local function firstLine(e) return (tostring(e):match("^[^\n]*")) end
local function show(v)
    if type(v) == "string" then
        local s = v:sub(1, 48):gsub("[^%w%p ]", "?")
        return string.format("%q%s", s, #v > 48 and ("..(" .. #v .. " bytes)") or "")
    end
    if type(v) == "userdata" then local ok, p = pcall(pathOf, v) return ok and ("<" .. p .. ">") or "<userdata>" end
    return tostring(v)
end
local function showAll(t)
    local parts = {}
    for i = 1, t.n do parts[i] = show(t[i]) end
    return table.concat(parts, ", ")
end

local E = {}
-- A clean Lua error whose first line contains text (plain match).
function E.err(text) return { what = "error containing '" .. text .. "'", test = function(ok, r) return not ok and firstLine(r[1]):find(text, 1, true) ~= nil end } end
-- A clean Lua error containing any of the texts.
function E.errAny(list) return { what = "error containing one of '" .. table.concat(list, "' / '") .. "'", test = function(ok, r)
    if ok then return false end
    for _, t in ipairs(list) do if firstLine(r[1]):find(t, 1, true) then return true end end
    return false
end } end
E.none = { what = "no return value", test = function(ok, r) return ok and r.n == 0 end }
E.nilret = { what = "nil", test = function(ok, r) return ok and r.n == 1 and r[1] == nil end }
function E.ret(what, pred) return { what = what, test = function(ok, r) return ok and pred(r) end } end
-- A channel reply (the call returns a string) that starts with prefix.
function E.reply(prefix) return { what = "reply starting '" .. prefix .. "'", test = function(ok, r) return ok and type(r[1]) == "string" and r[1]:sub(1, #prefix) == prefix end } end
-- client.call: false plus a reply starting with prefix.
function E.callErr(prefix) return { what = "false, '" .. prefix .. "...'", test = function(ok, r) return ok and r[1] == false and type(r[2]) == "string" and r[2]:sub(1, #prefix) == prefix end } end

local cases = { total = 0, passed = 0 }
local uiOffThreadCases -- defined with the UI cases below
local function case(id, desc, fn, expect)
    local r = table.pack(pcall(fn))
    local ok = table.remove(r, 1); r.n = r.n - 1
    local got = ok and ("returned (" .. showAll(r) .. ")") or ("error: " .. firstLine(r[1]))
    local pass = expect.test(ok, r)
    cases.total = cases.total + 1
    if pass then cases.passed = cases.passed + 1 end
    check(pass, "CASE %s %s -> %s (expected %s)", id, desc, got, expect.what)
end

local function intFn(fn) return function(...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end end

-- The type and range cases every native gets. name = function name, call = native, what = argument name.
local function typeCases(prefix, name, call, what)
    local f = intFn(call)
    case(prefix .. "-noargs", name .. "()", f(), E.err(name .. ": expected 1 argument (" .. what .. "), got 0"))
    case(prefix .. "-two", name .. "(1, 2)", f(1, 2), E.err(name .. ": expected 1 argument (" .. what .. "), got 2"))
    case(prefix .. "-nil", name .. "(nil)", f(nil), E.err(name .. ": argument 1 (" .. what .. ") must be an integer, got nil"))
    case(prefix .. "-true", name .. "(true)", f(true), E.err(name .. ": argument 1 (" .. what .. ") must be an integer, got a boolean"))
    case(prefix .. "-false", name .. "(false)", f(false), E.err(name .. ": argument 1 (" .. what .. ") must be an integer, got a boolean"))
    case(prefix .. "-table", name .. "({})", f({}), E.err(name .. ": argument 1 (" .. what .. ") must be an integer, got a table"))
    case(prefix .. "-numstr", name .. "(\"12345\")", f("12345"), E.err(name .. ": argument 1 (" .. what .. ") must be an integer, got a string"))
    case(prefix .. "-str", name .. "(\"abc\")", f("abc"), E.err(name .. ": argument 1 (" .. what .. ") must be an integer, got a string"))
    case(prefix .. "-float", name .. "(1.5)", f(1.5), E.err(name .. ": argument 1 (" .. what .. ") must be an integer, got a float"))
    case(prefix .. "-2^53f", name .. "(2^53) [float]", f(2 ^ 53), E.err(name .. ": argument 1 (" .. what .. ") must be an integer, got a float"))
    case(prefix .. "-func", name .. "(print)", f(print), E.err(name .. ": argument 1 (" .. what .. ") must be an integer, got a function"))
    local hud = found(S.hudPath)
    if hud then case(prefix .. "-obj", name .. "(<HUD object itself>)", f(hud), E.err(name .. ": argument 1 (" .. what .. ") must be an integer, got a userdata")) end
end

local function handleCases(prefix, name, call, unknownExpect)
    local f = intFn(call)
    typeCases(prefix, name, call, "handle")
    case(prefix .. "-0", name .. "(0)", f(0), E.err(name .. ": handle 0 is out of range"))
    case(prefix .. "--1", name .. "(-1)", f(-1), E.err(name .. ": handle -1 is out of range"))
    case(prefix .. "-2^53", name .. "(2^53) [integer]", f(1 << 53), E.err(name .. ": handle 9007199254740992 is out of range"))
    case(prefix .. "-maxint", name .. "(math.maxinteger)", f(math.maxinteger), E.err(name .. ": handle " .. math.maxinteger .. " is out of range"))
    case(prefix .. "-minint", name .. "(math.mininteger)", f(math.mininteger), E.err(name .. ": handle " .. math.mininteger .. " is out of range"))
    case(prefix .. "-2^53-1", name .. "(2^53-1) [never issued]", f((1 << 53) - 1), unknownExpect)
    for i = 1, 8 do
        local h = math.random(1000000000, (1 << 53) - 1)
        case(prefix .. "-rand" .. i, name .. "(" .. h .. ") [random, never issued]", f(h), unknownExpect)
    end
    for i = 1, 4 do
        local h = math.random(math.mininteger, -1)
        case(prefix .. "-randneg" .. i, name .. "(" .. h .. ") [random negative]", f(h), E.err(name .. ": handle " .. h .. " is out of range"))
    end
end

local function nativeCases(phase)
    local NV, REF, DEREF, FREE = native("_NativeVersion"), native("_Ref"), native("_Deref"), native("_RefFree")
    local nNV, nREF, nDEREF, nFREE = CORE .. "_NativeVersion", CORE .. "_Ref", CORE .. "_Deref", CORE .. "_RefFree"
    local P = phase .. "."
    math.randomseed(20261023)

    -- NativeVersion: no arguments.
    case(P .. "nv-ok", nNV .. "()", NV, E.ret("two strings (version, ue4ss)", function(r) return r.n == 2 and type(r[1]) == "string" and type(r[2]) == "string" end))
    case(P .. "nv-arg", nNV .. "(1)", function() return NV(1) end, E.err(nNV .. ": expected 0 arguments, got 1"))
    case(P .. "nv-nil", nNV .. "(nil)", function() return NV(nil) end, E.err(nNV .. ": expected 0 arguments, got 1"))

    -- ClockMicros: no arguments; a positive integer that never goes backwards.
    local CM, nCM = native("_ClockMicros"), CORE .. "_ClockMicros"
    local isMicros = function(r) return r.n == 1 and math.type(r[1]) == "integer" and r[1] > 0 end
    case(P .. "clock-ok", nCM .. "()", CM, E.ret("one integer > 0", isMicros))
    case(P .. "clock-mono", nCM .. "() twice", function() local a = CM() local b = CM() return a, b, b >= a end,
        E.ret("second >= first", function(r) return r[3] == true end))
    case(P .. "clock-arg", nCM .. "(1)", function() return CM(1) end, E.err(nCM .. ": expected 0 arguments, got 1"))
    case(P .. "clock-nil", nCM .. "(nil)", function() return CM(nil) end, E.err(nCM .. ": expected 0 arguments, got 1"))
    case(P .. "clock-str", nCM .. "(\"x\")", function() return CM("x") end, E.err(nCM .. ": expected 0 arguments, got 1"))
    case(P .. "clock-table", nCM .. "({})", function() return CM({}) end, E.err(nCM .. ": expected 0 arguments, got 1"))
    case(P .. "clock-two", nCM .. "(1, 2)", function() return CM(1, 2) end, E.err(nCM .. ": expected 0 arguments, got 2"))
    case(P .. "wrap-clock", "core.clock.micros()", function() return core.clock.micros() end, E.ret("one integer > 0", isMicros))

    -- Ref: types, then addresses that are not live UObjects.
    typeCases(P .. "ref", nREF, REF, "address")
    local fr = intFn(REF)
    case(P .. "ref-0", nREF .. "(0)", fr(0), E.err(nREF .. ": address is null (0)"))
    case(P .. "ref--1", nREF .. "(-1)", fr(-1), E.err(nREF .. ": address -1 is not a live UObject (outside the user address space)"))
    case(P .. "ref-2^53", nREF .. "(2^53) [integer]", fr(1 << 53), E.err(nREF .. ": address 9007199254740992 is not a live UObject (outside the user address space)"))
    case(P .. "ref-maxint", nREF .. "(math.maxinteger)", fr(math.maxinteger), E.err("is not a live UObject (outside the user address space)"))
    case(P .. "ref-minint", nREF .. "(math.mininteger)", fr(math.mininteger), E.err("is not a live UObject (outside the user address space)"))
    case(P .. "ref-low", nREF .. "(0x1000) [null page]", fr(0x1000), E.err("is not a live UObject (outside the user address space)"))
    case(P .. "ref-unmappedlo", nREF .. "(0x10000) [unmapped]", fr(0x10000), E.err(nREF .. ": address 0x10000 is not a live UObject (not in GUObjectArray)"))
    case(P .. "ref-unmappedhi", nREF .. "(0x7FFFFFFF0000) [unmapped]", fr(0x7FFFFFFF0000), E.err(nREF .. ": address 0x7FFFFFFF0000 is not a live UObject (not in GUObjectArray)"))
    local hud = found(S.hudPath)
    if hud then
        local a = hud:GetAddress()
        case(P .. "ref-interior", nREF .. "(<HUD address>+8) [inside a UObject, not one]", fr(a + 8), E.err("is not a live UObject (not in GUObjectArray)"))
        case(P .. "ref-interior64", nREF .. "(<HUD address>+64) [inside a UObject, not one]", fr(a + 64), E.err("is not a live UObject (not in GUObjectArray)"))
        case(P .. "ref-misaligned", nREF .. "(<HUD address>+1)", fr(a + 1), E.err("is not a live UObject (misaligned)"))
        -- Control: a live UObject's address works, and its handle behaves (deref, free, double free, deref freed).
        local h
        case(P .. "ref-live", nREF .. "(<HUD address>) [control: live UObject]", function() h = REF(a) return h end,
            E.ret("a positive integer handle", function(r) return r.n == 1 and math.type(r[1]) == "integer" and r[1] > 0 end))
        if h then
            case(P .. "deref-live", nDEREF .. "(" .. h .. ") [control]", function() return DEREF(h) end,
                E.ret("the HUD", function(r) return r.n == 1 and valid(r[1]) and pathOf(r[1]) == S.hudPath end))
            case(P .. "free-1", nFREE .. "(" .. h .. ")", function() return FREE(h) end, E.none)
            case(P .. "free-2", nFREE .. "(" .. h .. ") [double free]", function() return FREE(h) end, E.none)
            case(P .. "deref-freed", nDEREF .. "(" .. h .. ") [freed]", function() return DEREF(h) end, E.nilret)
        end
    end
    for i = 1, 8 do
        local a = math.random(0x10000, 0x7FFFFFFFFFFF) & ~7
        case(P .. "ref-rand" .. i, string.format("%s(0x%X) [random aligned]", nREF, a), fr(a), E.err("is not a live UObject (not in GUObjectArray)"))
    end
    for i = 1, 6 do
        local a = math.random(math.mininteger, math.maxinteger)
        case(P .. "ref-rand64-" .. i, string.format("%s(%d) [random 64-bit]", nREF, a), fr(a), E.errAny({ "(outside the user address space)", "(misaligned)", "(not in GUObjectArray)" }))
    end

    handleCases(P .. "deref", nDEREF, DEREF, E.nilret)
    handleCases(P .. "free", nFREE, FREE, E.none)

    -- The Lua wrappers dependents use.
    case(P .. "wrap-ref-nil", "core.ref(nil)", function() return core.ref(nil) end, E.err("ref: expected a UObject, got nil"))
    case(P .. "wrap-ref-str", "core.ref(\"x\")", function() return core.ref("x") end, E.err("ref: expected a UObject, got string"))
    case(P .. "wrap-ref-num", "core.ref(12345)", function() return core.ref(12345) end, E.err("ref: expected a UObject, got number"))
    case(P .. "wrap-deref-nil", "core.deref(nil)", function() return core.deref(nil) end, E.nilret)
    case(P .. "wrap-free-nil", "core.free(nil)", function() return core.free(nil) end, E.none)
    case(P .. "wrap-deref-str", "core.deref(\"1\")", function() return core.deref("1") end, E.err(nDEREF .. ": argument 1 (handle) must be an integer, got a string"))
end

-- Channel: through client.call (dependents' path) and straight on the class default object (bypasses the client).
local function channelCases(phase)
    local P = phase .. "."
    local cdo = found(ACTOR_CDO)
    local CALL = CORE .. "_Call"
    local function asString(v) if type(v) == "userdata" then return v:ToString() end return v end
    local function direct(req) return function() return asString(cdo[CALL](cdo, req)) end end
    local function directRaw(...) local a = table.pack(...) return function() return cdo[CALL](cdo, table.unpack(a, 1, a.n)) end end
    case(P .. "ch-ping", "call(\"ping\") [control]", function() return core.call("ping") end, E.ret("true, 'pong ...'", function(r) return r[1] == true and tostring(r[2]):find("^pong ") ~= nil end))
    case(P .. "ch-version", "call(\"version\") [control]", function() return core.call("version") end, E.ret("true, version", function(r) return r[1] == true and r[2] == NEED end))
    case(P .. "ch-nil", "call(nil)", function() return core.call(nil) end, E.callErr("err:bad-request op must be a string"))
    case(P .. "ch-table", "call({})", function() return core.call({}) end, E.callErr("err:bad-request op must be a string"))
    case(P .. "ch-num", "call(42)", function() return core.call(42) end, E.callErr("err:bad-request op must be a string"))
    case(P .. "ch-payload-table", "call(\"ping\", {})", function() return core.call("ping", {}) end, E.callErr("err:bad-request payload must be a string or number"))
    case(P .. "ch-unknown", "call(\"nosuchop\")", function() return core.call("nosuchop") end, E.callErr("err:unknown-op nosuchop"))
    case(P .. "ch-long-client", "call(<5000 bytes>)", function() return core.call(string.rep("a", 5000)) end, E.callErr("err:too-long 5000 bytes, cap 4096"))
    if not cdo then check(false, "CASE %s channel class default object not found", P .. "ch-direct") return end
    case(P .. "chd-long", CALL .. "(<5000 bytes>) [direct]", direct(string.rep("a", 5000)), E.reply("err:too-long 5000 bytes, cap 4096"))
    case(P .. "chd-long-payload", CALL .. "(\"ping:\"..<4100 bytes>) [direct]", direct("ping:" .. string.rep("p", 4100)), E.reply("err:too-long 4105 bytes, cap 4096"))
    case(P .. "chd-cap", CALL .. "(\"ping:\"..<4091 bytes>) [direct, exactly 4096]", direct("ping:" .. string.rep("p", 4091)), E.reply("ok:pong "))
    case(P .. "chd-cap+1", CALL .. "(\"ping:\"..<4092 bytes>) [direct, 4097]", direct("ping:" .. string.rep("p", 4092)), E.reply("err:too-long 4097 bytes, cap 4096"))
    case(P .. "chd-empty", CALL .. "(\"\") [direct]", direct(""), E.reply("err:bad-request empty request"))
    case(P .. "chd-unknown", CALL .. "(\"nosuchop\") [direct]", direct("nosuchop"), E.reply("err:unknown-op nosuchop"))
    case(P .. "chd-space", CALL .. "(\"ping garbage\") [direct]", direct("ping garbage"), E.reply("err:bad-request malformed request"))
    case(P .. "chd-colon", CALL .. "(\":ping\") [direct]", direct(":ping"), E.reply("err:bad-request malformed request"))
    case(P .. "chd-ctrl", CALL .. "(\"\\1\\2\\3garbage\") [direct]", direct("\1\2\3garbage"), E.reply("err:bad-request malformed request"))
    case(P .. "chd-longop", CALL .. "(<100-byte op>) [direct]", direct(string.rep("x", 100)), E.reply("err:bad-request op is 100 bytes, cap 64"))
    case(P .. "chd-longop-unknown", CALL .. "(<64-byte op>) [direct]", direct(string.rep("y", 64)), E.reply("err:unknown-op " .. string.rep("y", 64)))
    case(P .. "chd-punct", CALL .. "(\"%s%d{}[]\") [direct]", direct("%s%d{}[]"), E.reply("err:bad-request malformed request"))
    local garbage = {}
    for i = 1, 200 do garbage[i] = string.char(math.random(1, 127)) end
    case(P .. "chd-garbage-ascii", CALL .. "(<200 random ASCII bytes>) [direct]", direct(table.concat(garbage)), E.reply("err:"))
    -- Non-strings never reach core: UE4SS refuses to convert them to the FString parameter, in the caller, with a
    -- Lua error "[push_strproperty] Error: ..." (numbers included). The hook does not run.
    case(P .. "chd-number", CALL .. "(123) [direct]", directRaw(123), E.err("[push_strproperty] Error"))
    case(P .. "chd-table", CALL .. "({}) [direct]", directRaw({}), E.err("[push_strproperty] Error"))
    case(P .. "chd-bool", CALL .. "(true) [direct]", directRaw(true), E.err("[push_strproperty] Error"))
    case(P .. "chd-nil", CALL .. "(nil) [direct]", directRaw(nil), E.err("[push_strproperty] Error"))
end

-- Off the game thread: LoopAsync runs on UE4SS's async thread. Ref and Deref must refuse; RefFree and NativeVersion
-- are allowed anywhere. No channel or UObject call is made here (the channel is game-thread only by contract).
local function offThreadCases(phase)
    step(phase .. ": off-thread cases", function()
        local hud = found(S.hudPath)
        local addr = hud and hud:GetAddress()
        local h = hud and core.ref(hud)
        S.offHandle = h
        local P = phase .. "."
        -- A UI element made on the game thread, for the off-thread UI cases.
        local okU, uh = pcall(core.ui.text.create, { id = "off-h", text = "off", place = { absolute = { anchor = "center", x = 0, y = 300 } } })
        S.uiOffHandle = okU and uh or nil
        if not okU then check(false, "CASE %s could not create the off-thread UI element: %s", P .. "off-ui", firstLine(uh)) end
        local NV, REF, DEREF, FREE = native("_NativeVersion"), native("_Ref"), native("_Deref"), native("_RefFree")
        local CM = native("_ClockMicros")
        local nREF, nDEREF, nFREE = CORE .. "_Ref", CORE .. "_Deref", CORE .. "_RefFree"
        local doneOff = false
        LoopAsync(10, function()
            local ok, err = pcall(function()
                case(P .. "off-nv", CORE .. "_NativeVersion() [off thread]", NV, E.ret("two strings", function(r) return r.n == 2 end))
                case(P .. "off-clock", CORE .. "_ClockMicros() [off thread]", CM, E.ret("one integer > 0", function(r) return r.n == 1 and math.type(r[1]) == "integer" and r[1] > 0 end))
                if addr then case(P .. "off-ref", nREF .. "(<HUD address>) [off thread]", function() return REF(addr) end, E.err(nREF .. " refused: called off the game thread")) end
                case(P .. "off-ref-bad", nREF .. "(nil) [off thread]", function() return REF(nil) end, E.err(nREF .. " refused: called off the game thread"))
                if h then case(P .. "off-deref", nDEREF .. "(" .. h .. ") [off thread]", function() return DEREF(h) end, E.err(nDEREF .. " refused: called off the game thread")) end
                if h then case(P .. "off-free", nFREE .. "(" .. h .. ") [off thread, allowed]", function() return FREE(h) end, E.none) end
                case(P .. "off-free-bad", nFREE .. "(\"x\") [off thread]", function() return FREE("x") end, E.err(nFREE .. ": argument 1 (handle) must be an integer, got a string"))
                if S.uiOffHandle then uiOffThreadCases(P, S.uiOffHandle) end
            end)
            if not ok then check(false, "CASE %s off-thread block threw: %s", P .. "off", firstLine(err)) end
            doneOff = true
            return true
        end)
        return function() return doneOff end, 10, "off-thread cases"
    end)
    step(phase .. ": off-thread freed handle", function()
        -- The handle freed off the thread is gone on the game thread too.
        local h = S.offHandle
        if h then case(phase .. ".off-freed-deref", CORE .. "_Deref(" .. h .. ") [game thread, freed off thread]", function() return native("_Deref")(h) end, E.nilret) end
        -- The element survived every refused call; it is still ours and removable.
        if S.uiOffHandle then
            case(phase .. ".off-ui-after", "ui.text.remove(<element the off-thread calls targeted>) [game thread]", function() return core.ui.text.remove(S.uiOffHandle) end, E.none)
            S.uiOffHandle = nil
        end
    end)
end

-- UI helpers (stories 7-10): every public function with bad values, on the game thread. Elements made here are
-- removed again at the end. Expected messages are the exact first lines the contract gives.
local function uiCases(phase)
    local P = phase .. ".ui-"
    local U, T = core.ui, core.ui.text
    local UI = CORE:lower() .. ".ui"
    local function f(fn, ...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end
    local nop = function() end
    local okRet = E.ret("success", function() return true end)

    -- UI-1 hud
    case(P .. "watch-nil", "ui.hud.watch(nil)", f(U.hud.watch, nil), E.err(UI .. ".hud.watch: fn must be a function, got nil"))
    case(P .. "watch-1", "ui.hud.watch(1)", f(U.hud.watch, 1), E.err(UI .. ".hud.watch: fn must be a function, got 1"))
    case(P .. "watch-str", "ui.hud.watch(\"x\")", f(U.hud.watch, "x"), E.err(UI .. ".hud.watch: fn must be a function, got 'x'"))
    case(P .. "watch-table", "ui.hud.watch({})", f(U.hud.watch, {}), E.err(UI .. ".hud.watch: fn must be a function, got table"))
    case(P .. "watch-two", "ui.hud.watch(fn, 1)", f(U.hud.watch, nop, 1), E.err(UI .. ".hud.watch: expected 1 argument (fn), got 2"))
    case(P .. "unwatch-str", "ui.hud.unwatch(\"x\")", f(U.hud.unwatch, "x"), E.err(UI .. ".hud.unwatch: token must be an integer, got 'x'"))
    case(P .. "unwatch-float", "ui.hud.unwatch(1.5)", f(U.hud.unwatch, 1.5), E.err(UI .. ".hud.unwatch: token must be an integer, got 1.5"))
    case(P .. "unwatch-nil", "ui.hud.unwatch(nil)", f(U.hud.unwatch, nil), E.err(UI .. ".hud.unwatch: token must be an integer, got nil"))
    case(P .. "unwatch-table", "ui.hud.unwatch({})", f(U.hud.unwatch, {}), E.err(UI .. ".hud.unwatch: token must be an integer, got table"))
    case(P .. "unwatch-unknown", "ui.hud.unwatch(2^40) [never issued]", f(U.hud.unwatch, 1 << 40), E.none)
    case(P .. "find-arg", "ui.hud.find(1)", f(U.hud.find, 1), E.err(UI .. ".hud.find: expected 0 arguments, got 1"))
    case(P .. "find-ok", "ui.hud.find() [control]", f(U.hud.find), E.ret("a HUD or nil", function(r) return r.n == 1 and (r[1] == nil or valid(r[1])) end))
    case(P .. "isvisible-arg", "ui.hud.isVisible(true)", f(U.hud.isVisible, true), E.err(UI .. ".hud.isVisible: expected 0 arguments, got 1"))
    case(P .. "isvisible-ok", "ui.hud.isVisible() [control]", f(U.hud.isVisible), E.ret("a boolean", function(r) return type(r[1]) == "boolean" end))
    -- a watcher registered and unwatched again (control)
    case(P .. "watch-ok", "ui.hud.watch(fn) then unwatch [control]", function() local t = U.hud.watch(nop) U.hud.unwatch(t) U.hud.unwatch(t) return t end,
        E.ret("a positive integer token", function(r) return math.type(r[1]) == "integer" and r[1] > 0 end))

    -- UI-3 elements()
    case(P .. "elements-ok", "ui.elements() [control]", f(U.elements), E.ret("{ crosshair = ... }", function(r) return type(r[1]) == "table" and type(r[1].crosshair) == "string" and r[1].mic == nil end))
    case(P .. "elements-arg", "ui.elements(1)", f(U.elements, 1), E.err(UI .. ".elements: expected 0 arguments, got 1"))

    -- UI-2 create: the argument, id, text, place, unknown keys
    local CR = UI .. ".text.create: "
    case(P .. "create-none", "ui.text.create()", f(T.create), E.err(CR .. "expected a table"))
    case(P .. "create-str", "ui.text.create(\"a\")", f(T.create, "a"), E.err(CR .. "expected a table"))
    case(P .. "create-noid", "ui.text.create{}", f(T.create, {}), E.err(CR .. "id must be a string, got nil"))
    case(P .. "create-emptyid", "ui.text.create{ id = '' }", f(T.create, { id = "" }), E.err(CR .. "id must not be empty"))
    case(P .. "create-numid", "ui.text.create{ id = 5 }", f(T.create, { id = 5 }), E.err(CR .. "id must be a string, got 5"))
    case(P .. "create-tableid", "ui.text.create{ id = {} }", f(T.create, { id = {} }), E.err(CR .. "id must be a string, got table"))
    case(P .. "create-65", "ui.text.create{ id = <65 chars> }", f(T.create, { id = string.rep("a", 65) }), E.err(CR .. "id is 65 characters, at most 64"))
    case(P .. "create-space", "ui.text.create{ id = 'a b' }", f(T.create, { id = "a b" }), E.err(CR .. "id 'a b' has characters outside A-Z a-z 0-9 _ . -"))
    case(P .. "create-colon", "ui.text.create{ id = 'a:b' }", f(T.create, { id = "a:b" }), E.err("has characters outside A-Z a-z 0-9 _ . -"))
    case(P .. "create-utf8", "ui.text.create{ id = '\\195\\169' }", f(T.create, { id = "\195\169" }), E.err("has characters outside A-Z a-z 0-9 _ . -"))
    case(P .. "create-text-table", "ui.text.create{ id = 'bi', text = {} }", f(T.create, { id = "bi", text = {} }), E.err(CR .. "text must be a string, a number or nil, got table"))
    case(P .. "create-text-bool", "ui.text.create{ id = 'bi', text = true }", f(T.create, { id = "bi", text = true }), E.err(CR .. "text must be a string, a number or nil, got boolean"))
    case(P .. "create-text-func", "ui.text.create{ id = 'bi', text = print }", f(T.create, { id = "bi", text = print }), E.err(CR .. "text must be a string, a number or nil, got function"))
    case(P .. "create-place-str", "ui.text.create{ id = 'bi', place = 'top-right' }", f(T.create, { id = "bi", place = "top-right" }), E.err(CR .. "place must be a table or nil, got 'top-right'"))
    case(P .. "create-place-bad", "ui.text.create{ id = 'bi', place = { corner = 'middle' } }", f(T.create, { id = "bi", place = { corner = "middle" } }), E.err(UI .. ".place: unknown corner 'middle'"))
    case(P .. "create-unknown", "ui.text.create{ id = 'bi', txt = 'x' }", f(T.create, { id = "bi", txt = "x" }), E.err(CR .. "unknown key 'txt' (valid: id, text, place, style)"))
    -- style (story 8 AC 12)
    local ST = UI .. ".text: "
    case(P .. "style-str", "create{ style = 'dim' }", f(T.create, { id = "bi", style = "dim" }), E.err(ST .. "style must be a table"))
    case(P .. "style-purple", "create{ style = { background = 'purple' } }", f(T.create, { id = "bi", style = { background = "purple" } }), E.err(ST .. "unknown background 'purple' (valid: none, dim, dark"))
    case(P .. "style-r-neg", "create{ style = { background = { r = -1, g = 0, b = 0 } } }", f(T.create, { id = "bi", style = { background = { r = -1, g = 0, b = 0 } } }), E.err(ST .. "background.r must be a number from 0 to 1, got -1"))
    case(P .. "style-r-2", "create{ style = { background = { r = 2, g = 0, b = 0 } } }", f(T.create, { id = "bi", style = { background = { r = 2, g = 0, b = 0 } } }), E.err(ST .. "background.r must be a number from 0 to 1, got 2"))
    case(P .. "style-r-str", "create{ style = { background = { r = 'x', g = 0, b = 0 } } }", f(T.create, { id = "bi", style = { background = { r = "x", g = 0, b = 0 } } }), E.err(ST .. "background.r must be a number from 0 to 1, got 'x'"))
    case(P .. "style-g-nil", "create{ style = { background = { r = 0, b = 0 } } }", f(T.create, { id = "bi", style = { background = { r = 0, b = 0 } } }), E.err(ST .. "background.g must be a number from 0 to 1, got nil"))
    case(P .. "style-a-nan", "create{ style = { background = { r = 0, g = 0, b = 0, a = 0/0 } } }", f(T.create, { id = "bi", style = { background = { r = 0, g = 0, b = 0, a = 0 / 0 } } }), E.err(ST .. "background.a must be a number from 0 to 1, got NaN"))
    case(P .. "style-bgkey", "create{ style = { background = { r = 0, g = 0, b = 0, x = 1 } } }", f(T.create, { id = "bi", style = { background = { r = 0, g = 0, b = 0, x = 1 } } }), E.err(ST .. "unknown background key 'x' (valid: r, g, b, a)"))
    case(P .. "style-bgbool", "create{ style = { background = true } }", f(T.create, { id = "bi", style = { background = true } }), E.err(ST .. "background must be a preset name or a colour table, got boolean"))
    case(P .. "style-pad5", "create{ style = { padding = 5 } }", f(T.create, { id = "bi", style = { padding = 5 } }), E.err(ST .. "unknown padding 5 (valid: none, tight, normal, loose)"))
    case(P .. "style-padhuge", "create{ style = { padding = 'huge' } }", f(T.create, { id = "bi", style = { padding = "huge" } }), E.err(ST .. "unknown padding 'huge'"))
    case(P .. "style-bg", "create{ style = { bg = 'dim' } }", f(T.create, { id = "bi", style = { bg = "dim" } }), E.err(ST .. "unknown style key 'bg' (valid: background, padding)"))

    -- A real element for the handle cases (out of the way: absolute, below the centre).
    local h
    case(P .. "create-ok", "ui.text.create{ id = 'bi' } [control]", function()
        h = T.create{ id = "bi", text = "bad-input", place = { absolute = { anchor = "center", x = 0, y = 260 } } }
        return h
    end, E.ret("a handle { id = 'bi' }", function(r) return type(r[1]) == "table" and r[1].id == "bi" end))
    case(P .. "create-64", "ui.text.create{ id = <64 chars> } [control]", function() local x = T.create{ id = string.rep("b", 64) } T.remove(x) return x.id end,
        E.ret("ok", function(r) return r[1] == string.rep("b", 64) end))
    case(P .. "create-num", "ui.text.create{ id = 'bi', text = 42 } [control: numbers are text]", f(T.create, { id = "bi", text = 42, place = { absolute = { anchor = "center", x = 0, y = 260 } } }),
        E.ret("the same handle", function(r) return rawequal(r[1], h) end))
    if not h then return end
    case(P .. "handle-write", "handle.id = 'x'", function() h.id = "x" end, E.err(UI .. ".text: element handles are read-only"))
    case(P .. "handle-new", "handle.foo = 1", function() h.foo = 1 end, E.err(UI .. ".text: element handles are read-only"))
    case(P .. "handle-id", "handle.id [control]", function() return h.id end, E.ret("'bi'", function(r) return r[1] == "bi" end))
    case(P .. "set-text-table", "ui.text.set(h, {})", f(T.set, h, {}), E.err(UI .. ".text.set: text must be a string, a number or nil, got table"))
    case(P .. "set-text-bool", "ui.text.set(h, false)", f(T.set, h, false), E.err(UI .. ".text.set: text must be a string, a number or nil, got boolean"))
    case(P .. "set-ok", "ui.text.set(h, nil) [control: nil is '']", f(T.set, h, nil), E.none)
    case(P .. "setstyle-str", "ui.text.setStyle(h, 'dark')", f(T.setStyle, h, "dark"), E.err(UI .. ".text: style must be a table"))
    case(P .. "setstyle-ok", "ui.text.setStyle(h, { background = 'dark' }) [control]", f(T.setStyle, h, { background = "dark" }), E.none)
    case(P .. "setvis-none", "ui.text.setVisible(h)", f(T.setVisible, h), E.err(UI .. ".text.setVisible: visible must be a boolean, got nil"))
    case(P .. "setvis-yes", "ui.text.setVisible(h, 'yes')", f(T.setVisible, h, "yes"), E.err(UI .. ".text.setVisible: visible must be a boolean, got string"))
    case(P .. "setvis-1", "ui.text.setVisible(h, 1)", f(T.setVisible, h, 1), E.err(UI .. ".text.setVisible: visible must be a boolean, got number"))
    case(P .. "setvis-ok", "ui.text.setVisible(h, false) [control]", f(T.setVisible, h, false), E.none)
    case(P .. "isshown-ok", "ui.text.isShown(h) [control: hidden]", f(T.isShown, h), E.ret("false", function(r) return r[1] == false end))
    -- story 12: debug.overlaps
    case(P .. "overlaps-two", "ui.debug.overlaps(h, 1)", f(U.debug.overlaps, h, 1), E.err(UI .. ".debug.overlaps: expected 1 argument (handle), got 2"))
    case(P .. "overlaps-hidden", "ui.debug.overlaps(h) [control: hidden element]", f(U.debug.overlaps, h),
        E.ret("nil and a reason naming it hidden", function(r) return r[1] == nil and type(r[2]) == "string" and r[2]:find("hidden", 1, true) ~= nil end))

    -- Handles that aren't ours, for every function that takes one.
    local forged = { id = "bi" }
    local fns = {
        { "set", "text.set", T.set, "x" }, { "setstyle", "text.setStyle", T.setStyle, nil }, { "setvis", "text.setVisible", T.setVisible, true },
        { "remove", "text.remove", T.remove, nil }, { "isshown", "text.isShown", T.isShown, nil }, { "place", "place", U.place, { corner = "top-left" } },
        { "overlaps", "debug.overlaps", U.debug.overlaps, nil },
    }
    for _, d in ipairs(fns) do
        local key, name, fn, arg = d[1], d[2], d[3], d[4]
        local pre = UI .. "." .. name .. ": "
        case(P .. key .. "-h-table", "ui." .. name .. "({}, ...)", f(fn, {}, arg), E.err(pre .. "not an element handle"))
        case(P .. key .. "-h-nil", "ui." .. name .. "(nil, ...)", f(fn, nil, arg), E.err(pre .. "expected an element handle, got nil"))
        case(P .. key .. "-h-num", "ui." .. name .. "(42, ...)", f(fn, 42, arg), E.err(pre .. "expected an element handle, got 42"))
        case(P .. key .. "-h-str", "ui." .. name .. "('bi', ...)", f(fn, "bi", arg), E.err(pre .. "expected an element handle, got 'bi'"))
        case(P .. key .. "-h-forged", "ui." .. name .. "({ id = 'bi' }, ...) [forged]", f(fn, forged, arg), E.err(pre .. "not an element handle"))
    end

    -- UI-3 intents (story 9 AC 6), through place(h, intent).
    local PL = UI .. ".place: "
    local function pc_(id, desc, intent, expect) case(P .. "place-" .. id, "ui.place(h, " .. desc .. ")", f(U.place, h, intent), expect) end
    pc_("str", "'top-right'", "top-right", E.err(PL .. "intent must be a table, got 'top-right'"))
    pc_("nil", "nil", nil, E.err(PL .. "intent must be a table, got nil"))
    pc_("empty", "{}", {}, E.err(PL .. "an intent needs exactly one of corner, near or absolute (got none)"))
    pc_("corner-abs", "{ corner, absolute }", { corner = "top-right", absolute = { x = 0, y = 0 } }, E.err(PL .. "an intent needs exactly one of corner, near or absolute (got corner and absolute)"))
    pc_("corner-near", "{ corner, near }", { corner = "top-right", near = "crosshair" }, E.err("(got corner and near)"))
    pc_("typo", "{ conrer = 'top-right' }", { conrer = "top-right" }, E.err(PL .. "unknown key 'conrer' in an intent"))
    pc_("corner-bad", "{ corner = 'middle' }", { corner = "middle" }, E.err(PL .. "unknown corner 'middle' (valid: top-left, top-right, bottom-left, bottom-right)"))
    pc_("corner-num", "{ corner = 1 }", { corner = 1 }, E.err(PL .. "unknown corner 1"))
    pc_("gap-bad", "{ corner, gap = 'huge' }", { corner = "top-left", gap = "huge" }, E.err(PL .. "unknown gap 'huge' (valid: tight, normal, loose)"))
    pc_("gap-num", "{ corner, gap = 16 }", { corner = "top-left", gap = 16 }, E.err(PL .. "unknown gap 16"))
    pc_("host", "{ host = 'journal', corner }", { host = "journal", corner = "top-left" }, E.err(PL .. "unknown host 'journal' (valid: hud)"))
    pc_("side-corner", "{ corner, side = 'left' }", { corner = "top-left", side = "left" }, E.err(PL .. "side is not allowed with corner"))
    pc_("off-str", "{ corner, offset = 'x' }", { corner = "top-left", offset = "x" }, E.err(PL .. "offset must be a table"))
    pc_("off-a", "{ corner, offset = { x = 'a' } }", { corner = "top-left", offset = { x = "a" } }, E.err(PL .. "offset.x must be a number, got 'a'"))
    pc_("off-huge", "{ corner, offset = { x = math.huge } }", { corner = "top-left", offset = { x = math.huge } }, E.err(PL .. "offset.x must be a finite number"))
    pc_("off-ninf", "{ corner, offset = { y = -math.huge } }", { corner = "top-left", offset = { y = -math.huge } }, E.err(PL .. "offset.y must be a finite number"))
    pc_("off-nan", "{ corner, offset = { x = 0/0 } }", { corner = "top-left", offset = { x = 0 / 0 } }, E.err(PL .. "offset.x must be a finite number, got NaN"))
    pc_("off-5000", "{ corner, offset = { x = 5000 } }", { corner = "top-left", offset = { x = 5000 } }, E.err(PL .. "offset.x 5000 is out of range (within +-4096 canvas units)"))
    pc_("off-y", "{ corner, offset = { y = -4097 } }", { corner = "top-left", offset = { y = -4097 } }, E.err(PL .. "offset.y -4097 is out of range"))
    pc_("off-key", "{ corner, offset = { z = 1 } }", { corner = "top-left", offset = { z = 1 } }, E.err(PL .. "unknown key 'z' in offset (valid keys: x, y)"))
    pc_("off-max", "{ corner, offset = { x = 4096, y = -4096 } } [control]", { corner = "top-left", offset = { x = 4096, y = -4096 } }, E.none)
    pc_("near-mic", "{ near = 'mic' }", { near = "mic" }, E.err(PL .. "unknown near element 'mic' (valid: crosshair)"))
    pc_("near-side", "{ near, side = 'up' }", { near = "crosshair", side = "up" }, E.err(PL .. "unknown side 'up' (valid: right, left, above, below)"))
    pc_("near-align", "{ near, align = 'middle' }", { near = "crosshair", align = "middle" }, E.err(PL .. "unknown align 'middle' (valid: center, start, end)"))
    pc_("abs-str", "{ absolute = 'center' }", { absolute = "center" }, E.err(PL .. "absolute must be a table"))
    pc_("abs-anchor", "{ absolute = { anchor = 'middle' } }", { absolute = { anchor = "middle" } }, E.err(PL .. "unknown anchor 'middle' (valid: top-left, top-right, bottom-left, bottom-right, center)"))
    pc_("abs-9000", "{ absolute = { x = 9000 } }", { absolute = { x = 9000 } }, E.err(PL .. "absolute.x 9000 is out of range (within +-8192 canvas units)"))
    pc_("abs-huge", "{ absolute = { y = math.huge } }", { absolute = { y = math.huge } }, E.err(PL .. "absolute.y must be a finite number"))
    pc_("abs-nan", "{ absolute = { x = 0/0 } }", { absolute = { x = 0 / 0 } }, E.err(PL .. "absolute.x must be a finite number, got NaN"))
    pc_("abs-key", "{ absolute = { left = 1 } }", { absolute = { left = 1 } }, E.err(PL .. "unknown key 'left' in absolute (valid keys: anchor, x, y)"))
    pc_("abs-offset", "{ absolute, offset = { x = 1 } }", { absolute = { x = 0, y = 0 }, offset = { x = 1 } }, E.err(PL .. "offset is not allowed with absolute"))
    pc_("abs-gap", "{ absolute, gap = 'tight' }", { absolute = { x = 0, y = 0 }, gap = "tight" }, E.err(PL .. "gap is not allowed with absolute"))
    pc_("abs-ok", "{ absolute = { anchor = 'center', x = 0, y = 260 } } [control]", { absolute = { anchor = "center", x = 0, y = 260 } }, E.none)

    -- Removed handles (story 8 AC 6, 14): every function raises "handle 'bi' was removed"; remove again does nothing.
    case(P .. "remove-ok", "ui.text.remove(h) [control]", f(T.remove, h), E.none)
    case(P .. "remove-again", "ui.text.remove(h) [again]", f(T.remove, h), E.none)
    local RM = UI .. ".text: handle 'bi' was removed"
    case(P .. "removed-set", "ui.text.set(<removed>, 'x')", f(T.set, h, "x"), E.err(RM))
    case(P .. "removed-isshown", "ui.text.isShown(<removed>)", f(T.isShown, h), E.err(RM))
    case(P .. "removed-setvis", "ui.text.setVisible(<removed>, true)", f(T.setVisible, h, true), E.err(RM))
    case(P .. "removed-setstyle", "ui.text.setStyle(<removed>, nil)", f(T.setStyle, h, nil), E.err(RM))
    case(P .. "removed-place", "ui.place(<removed>, { corner = 'top-left' })", f(U.place, h, { corner = "top-left" }), E.err(RM))
    case(P .. "removed-overlaps", "ui.debug.overlaps(<removed>)", f(U.debug.overlaps, h), E.err(RM))
    case(P .. "recreate", "ui.text.create{ id = 'bi' } after remove [control: a fresh element]", function()
        local h2 = T.create{ id = "bi", place = { absolute = { anchor = "center", x = 0, y = 260 } } }
        local fresh = not rawequal(h2, h)
        T.remove(h2)
        return fresh
    end, E.ret("a new handle", function(r) return r[1] == true end))
    case(P .. "stats", "ui.text.stats() [control]", f(T.stats), E.ret("a table with elements = 0", function(r) return type(r[1]) == "table" and r[1].elements == 0 end))
    case(P .. "hud-stats", "ui.hud.stats() [control]", f(U.hud.stats), E.ret("findAllCalls == 1", function(r) return type(r[1]) == "table" and r[1].findAllCalls == 1 end))
end

-- Off the game thread (LoopAsync), each UI function must raise "<core>.ui.<fn> called off the game thread".
uiOffThreadCases = function(P, h)
    local U, T = core.ui, core.ui.text
    local UI = CORE:lower() .. ".ui"
    local function off(key, name, fn, ...)
        local a = table.pack(...)
        case(P .. "off-ui-" .. key, "ui." .. name .. "(...) [off thread]", function() return fn(table.unpack(a, 1, a.n)) end, E.err(UI .. "." .. name .. " called off the game thread"))
    end
    off("create", "text.create", T.create, { id = "off" })
    off("set", "text.set", T.set, h, "x")
    off("setstyle", "text.setStyle", T.setStyle, h, nil)
    off("setvis", "text.setVisible", T.setVisible, h, false)
    off("remove", "text.remove", T.remove, h)
    off("isshown", "text.isShown", T.isShown, h)
    off("place", "place", U.place, h, { corner = "top-left" })
    off("elements", "elements", U.elements)
    off("find", "hud.find", U.hud.find)
    off("watch", "hud.watch", U.hud.watch, function() end)
    off("unwatch", "hud.unwatch", U.hud.unwatch, 1)
    off("isvisible", "hud.isVisible", U.hud.isVisible)
    off("overlaps", "debug.overlaps", U.debug.overlaps, h)
end

local function preConnectCases()
    step("before-connect cases", function()
        local UI = CORE:lower() .. ".ui"
        local want = { create = "text.create", watch = "hud.watch", find = "hud.find", elements = "elements", overlaps = "debug.overlaps" }
        for _, r in ipairs(PRE_CONNECT) do
            case(r.id, r.desc, function() if not r.ok then error(r.err, 0) end return "no error" end,
                E.err(UI .. ": " .. tostring(want[r.fn]) .. " called before connect"))
        end
        check(#PRE_CONNECT == 5, "CASES before-connect recorded=%d (expected 5)", #PRE_CONNECT)
    end)
end

local function badInputCases(phase)
    step(phase .. ": native cases", function() nativeCases(phase) end)
    step(phase .. ": channel cases", function() channelCases(phase) end)
    step(phase .. ": ui cases", function() uiCases(phase) end)
    offThreadCases(phase)
end

-- The widget from the previous world, destroyed by the map change: its address must not be referenced again, or
-- (if the allocator already reused it for another object) must reference that other object, never the old one.
local function destroyedCase(phase)
    step(phase .. ": destroyed widget case", function()
        local REF, DEREF, FREE = native("_Ref"), native("_Deref"), native("_RefFree")
        if not check(S.gone ~= nil, "CASE %s.ref-destroyed have a destroyed widget's address", phase) then return end
        local a, old = S.gone.address, S.gone.path
        local ok, r = pcall(REF, a)
        local desc = string.format("%s_Ref(0x%X) [widget from %s, destroyed by the map change]", CORE, a, S.gone.phase)
        cases.total = cases.total + 1
        if not ok then
            local pass = firstLine(r):find("is not a live UObject", 1, true) ~= nil
            if pass then cases.passed = cases.passed + 1 end
            check(pass, "CASE %s.ref-destroyed %s -> error: %s (expected error 'is not a live UObject', or a handle to a different object)", phase, desc, firstLine(r))
        else
            local obj = DEREF(r)
            local now = obj and pathOf(obj) or "nil"
            FREE(r)
            local pass = now ~= old
            if pass then cases.passed = cases.passed + 1 end
            check(pass, "CASE %s.ref-destroyed %s -> handle to %s, address reused (expected never the old widget %s)", phase, desc, now, old)
        end
    end)
end

-- <Core>_ClockMicros against real time across a 2 s wait (os.clock is wall time in the MSVC C runtime), then the
-- cost of one call, timed over 10,000 calls by the clock itself (Lua loop overhead included).
local function clockChecks(phase)
    local t
    step(phase .. ": clock start", function()
        local CM = native("_ClockMicros")
        t = { us = CM(), c = os.clock() }
        return function() return os.clock() - t.c >= 2 end, 10, "clock wait"
    end)
    step(phase .. ": clock vs real time", function()
        local CM = native("_ClockMicros")
        local us, c = CM(), os.clock()
        local dUs, dReal = (us - t.us) / 1e6, c - t.c
        local ratio = dUs / dReal
        check(ratio >= 0.8 and ratio <= 1.2, "CLOCKRT %s ClockMicros delta=%.6f s os.clock delta=%.3f s ratio=%.4f (expected 0.8..1.2)", phase, dUs, dReal, ratio)
        local N = 10000
        local a = CM()
        for _ = 1, N do CM() end
        local b = CM()
        local wrap = core.clock.micros
        for _ = 1, N do wrap() end
        local c2 = CM()
        say("CLOCKCOST %s n=%d native=%.1f ns per call wrapper=%.1f ns per call (Lua loop included, timed by ClockMicros)", phase, N, (b - a) * 1000 / N, (c2 - b) * 1000 / N)
    end)
end

local function buildSkeleton()
    waitWorld("menu1", "NewMainMenu", 120)
    waitHud("menu1", 60)
    showWidget("menu1")
    travel("match1", MATCH_MAP, "listen")
    waitWorld("match1", "SmallMap", 150)
    checkPrevious("match1")
    touchdown("match1")
    waitHud("match1", 90)
    showWidget("match1")
    refCost("match1", 200)
    travel("menu2", MENU_MAP, "")
    waitWorld("menu2", "NewMainMenu", 150)
    checkPrevious("menu2")
    waitHud("menu2", 60)
    showWidget("menu2")
    travel("match2", MATCH_MAP, "listen")
    waitWorld("match2", "SmallMap", 150)
    checkPrevious("match2")
    touchdown("match2")
    waitHud("match2", 90)
    showWidget("match2")
    refCost("match2", 200)
end

local function buildBadInput()
    preConnectCases()
    waitWorld("menu1", "NewMainMenu", 120)
    waitHud("menu1", 60)
    step("menu1: widget to destroy", function() return createWidget("menu1") end)
    step("menu1: keep widget", function() S.prev, S.cur = S.cur, nil end)
    badInputCases("menu1")
    travel("match1", MATCH_MAP, "listen")
    waitWorld("match1", "SmallMap", 150)
    checkPrevious("match1")
    touchdown("match1")
    waitHud("match1", 90)
    destroyedCase("match1")
    badInputCases("match1")
    refCost("match1", 200)
    clockChecks("match1")
    step("summary", function()
        check(cases.total > 0 and cases.passed == cases.total, "CASES total=%d passed=%d failed=%d", cases.total, cases.passed, cases.total - cases.passed)
    end)
end

-- ---------------------------------------------------------------- ui (stories 7-10, unattended)
-- Exercises core.ui the way a dependent does, and checks what it did from the outside: the HUD canvas's children
-- (found by their tag, which also checks the tag), their slots and measured sizes, the watcher's events and the
-- helpers' counters. Never calls FindAllOf for the HUD: only core.ui.hud.find().
local TEXT_SHORT = "WBP_" .. CORE .. "Text_C"
local EV = { list = {}, count = {} }
local UIS = {} -- handles and remembered numbers; no UObjects

local function afterMs(ms) local t = os.clock() + ms / 1000 return function() return os.clock() >= t end end

local function recorder(_, info)
    EV.list[#EV.list + 1] = { event = info.event, reason = info.reason, path = info.path, visible = info.visible }
    EV.count[info.event] = (EV.count[info.event] or 0) + 1
    if info.path then EV.hudPath = info.path end
    say("EVENT %d %s reason=%s visible=%s hud=%s", #EV.list, info.event, tostring(info.reason), tostring(info.visible), tostring(info.path))
end
-- Waits for an event (optionally with a reason containing text) after event number since.
local function eventAfter(since, event, reasonPart)
    return function()
        for i = since + 1, #EV.list do
            local e = EV.list[i]
            if e.event == event and (not reasonPart or tostring(e.reason):find(reasonPart, 1, true)) then return true end
        end
        return false
    end
end

-- Our widgets for one element id among the live canvas's children, by tag: the first and how many.
local function widgetOf(id)
    local hud = core.ui.hud.find()
    if not hud then return nil, 0 end
    local canvas = hud.OwningCanvas
    local tag = core.ui.text.tagOf(id)
    local first, n = nil, 0
    for i = 0, canvas:GetChildrenCount() - 1 do
        local c = canvas:GetChildAt(i)
        if valid(c) and c:GetClass():GetFName():ToString() == TEXT_SHORT then
            local ok, t = pcall(function() return c.ToolTipText:ToString() end)
            if ok and t == tag then n = n + 1; first = first or c end
        end
    end
    return first, n
end

local function canvasSize(hud)
    local world = hud:GetWorld()
    local vp, scale = WLL():GetViewportSize(world), WLL():GetViewportScale(world)
    return vp.X / scale, vp.Y / scale, scale
end

-- A widget's rectangle in canvas space, from its slot (point anchors) and its measured size.
local function canvasRect(w, hud, size)
    pcall(function() w:ForceLayoutPrepass() end)
    local slot = w.Slot
    local an, al, pos = slot:GetAnchors(), slot:GetAlignment(), slot:GetPosition()
    local ds = size or w:GetDesiredSize()
    local cw, ch = canvasSize(hud)
    local l = an.Minimum.X * cw + pos.X - al.X * ds.X
    local t = an.Minimum.Y * ch + pos.Y - al.Y * ds.Y
    return { l = l, t = t, r = l + ds.X, b = t + ds.Y, w = ds.X, h = ds.Y, cw = cw, ch = ch, px = pos.X, py = pos.Y,
        ax = an.Minimum.X, ay = an.Minimum.Y, alx = al.X, aly = al.Y }
end
local function rs(r) return string.format("(%.1f,%.1f)-(%.1f,%.1f)", r.l, r.t, r.r, r.b) end

local function textOf(w) local ok, t = pcall(function() return w.Text:GetText():ToString() end) return ok and t or nil end

local function uiStats() return core.ui.text.stats() end

-- Checks an element's inset from its corner's two edges, and that it lies inside the canvas.
local function checkInset(phase, id, corner, gap, extraX)
    local hud = core.ui.hud.find()
    local w, n = widgetOf(id)
    if not check(hud ~= nil and w ~= nil and n == 1, "UIONE %s '%s' has exactly one widget in the live canvas (found %d)", phase, id, n) then return end
    local r = canvasRect(w, hud)
    local gx = corner:find("left", 1, true) and r.l or (r.cw - r.r)
    local gy = corner:find("top", 1, true) and r.t or (r.ch - r.b)
    local inside = r.l >= 0 and r.t >= 0 and r.r <= r.cw and r.b <= r.ch and r.w > 0 and r.h > 0
    check(near(gx, gap + (extraX or 0)) and near(gy, gap) and inside,
        "UICORNER %s '%s' %s gap=%d%s: rect=%s gapX=%.1f gapY=%.1f canvas=(%.0fx%.0f) inside=%s",
        phase, id, corner, gap, extraX and (" offsetX=" .. extraX) or "", rs(r), gx, gy, r.cw, r.ch, tostring(inside))
end

local function uiCreate(id, opts)
    opts = opts or {}
    opts.id = id
    local h = core.ui.text.create(opts)
    UIS[id] = h
    return h
end

local function buildUi()
    local T = function() return core.ui.text end

    -- menu1: an element created right after connect (story 8 AC 2), a hidden one for the map changes (AC 13).
    step("menu1: create before the HUD", function()
        local h = uiCreate("pre", { text = "pre-match" })
        check(type(h) == "table" and h.id == "pre", "UICREATE menu1 create{ id = 'pre' } returned a handle (id=%s)", tostring(h and h.id))
        check(T().isShown(h) == false, "UISHOWN menu1 'pre' isShown=false before any match (HUD hidden or absent)")
        local hid = uiCreate("hid", { text = "hidden across map changes", place = { corner = "bottom-left" } })
        T().setVisible(hid, false)
        -- The recorder, and a watcher that always throws (story 7 AC 5: logged once, the others still hear).
        UIS.t0 = os.time() -- the HUD poller (and its one-minute tick window) is running from here at the latest
        UIS.recorder = core.ui.hud.watch(recorder)
        UIS.thrower = core.ui.hud.watch(function() error("test watcher throws on purpose") end)
    end)
    waitWorld("menu1", "NewMainMenu", 120)
    step("menu1: attached", function() return eventAfter(0, "attached"), 60, "menu1 attached event" end)
    step("menu1: element on the menu HUD", function()
        local w, n = widgetOf("pre")
        check(w ~= nil and n == 1, "UIONE menu1 'pre' attached to the menu HUD (widgets=%d)", n)
        check(core.ui.hud.isVisible() == false, "UIHUD menu1 isVisible=false at the menu (find=%s)", tostring(core.ui.hud.find() ~= nil))
        check(T().isShown(UIS.pre) == false, "UISHOWN menu1 'pre' isShown=false at the menu")
        if w then UIS.oldPre = { handle = core.ref(w), path = pathOf(w) } end
        UIS.evMenu1 = #EV.list
    end)

    -- match1: lobby -> match; the element comes back on the match HUD (story 10 AC 1, 3).
    travel("match1", MATCH_MAP, "listen")
    waitWorld("match1", "SmallMap", 150)
    step("match1: old widget gone", function()
        if not UIS.oldPre then return end
        if core.deref(UIS.oldPre.handle) ~= nil then
            StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
            return after(2), 5, "gc"
        end
    end)
    step("match1: old widget deref", function()
        if not UIS.oldPre then return end
        check(core.deref(UIS.oldPre.handle) == nil, "UIDEREF match1 the menu's 'pre' widget derefs to nil after the map change (%s)", UIS.oldPre.path)
        core.free(UIS.oldPre.handle)
        UIS.oldPre = nil
    end)
    touchdown("match1")
    step("match1: shown", function() return function() return T().isShown(UIS.pre) end, 120, "match1 'pre' isShown" end)
    step("match1: settle", function() return afterMs(1500), 3, "settle" end)
    step("match1: one widget, top-right, tag", function()
        local w, n = widgetOf("pre")
        check(w ~= nil and n == 1, "UIONE match1 'pre' exactly one widget in the match HUD canvas (found %d)", n)
        if not w then return end
        local okT, tag = pcall(function() return w.ToolTipText:ToString() end)
        check(okT and tag == T().tagOf("pre"), "UITAG match1 ToolTipText reads back %s (expected %s)", tostring(tag), T().tagOf("pre"))
        check(tonumber(w:GetVisibility()) == 4, "UIVIS match1 'pre' widget is SelfHitTestInvisible (visibility=%s)", tostring(w:GetVisibility()))
        check(textOf(w) == "pre-match", "UITEXT match1 'pre' shows %q", tostring(textOf(w)))
        check(core.ui.hud.isVisible() == true, "UIHUD match1 isVisible=true in the match")
        checkInset("match1", "pre", "top-right", 16)
    end)

    -- Same id twice (story 8 AC 3), set and its no-op (AC 4), long text (AC 5).
    step("match1: same id twice", function()
        local h2 = uiCreate("pre", { text = "bye" })
        local w, n = widgetOf("pre")
        check(rawequal(h2, UIS.pre) or false, "UISAME match1 create{ id = 'pre' } again returned the same handle")
        UIS.pre = h2
        check(w ~= nil and n == 1 and textOf(w) == "bye", "UISAME match1 one widget for 'pre' (found %d), showing %q", n, tostring(w and textOf(w)))
    end)
    step("match1: set and no-op", function()
        local h = UIS.pre
        T().set(h, "x")
        local c0 = uiStats().uobjectCalls
        T().set(h, "x")
        local c1 = uiStats().uobjectCalls
        local w = widgetOf("pre")
        check(w ~= nil and textOf(w) == "x", "UISET match1 set(h, 'x') shows %q", tostring(w and textOf(w)))
        check(c1 == c0, "UINOOP match1 a second set(h, 'x') made %d UObject calls (expected 0)", c1 - c0)
        T().set(h, "pre-match")
    end)
    step("match1: long text", function()
        local h = uiCreate("long", { text = string.rep("L", 300), place = { absolute = { anchor = "center", x = 0, y = 300 } } })
        T().set(h, string.rep("M", 300))
        T().set(h, string.rep("N", 300))
        local w = widgetOf("long")
        local t = w and textOf(w)
        check(t ~= nil and #t == 256 and t == string.rep("N", 256), "UILONG match1 a 300-character text shows the first 256 (length %s)", tostring(t and #t))
        T().remove(h)
    end)

    -- Remove (story 8 AC 6).
    step("match1: remove", function()
        local h = uiCreate("rm", { text = "to remove", place = { absolute = { anchor = "center", x = 0, y = 340 } } })
        local w0, n0 = widgetOf("rm")
        local freed0 = uiStats().handlesFreed
        T().remove(h)
        local _, n1 = widgetOf("rm")
        local okS, errS = pcall(T().isShown, h)
        local okR = pcall(T().remove, h)
        check(n0 == 1 and n1 == 0, "UIREMOVE match1 remove(h) took the widget off the HUD (widgets %d -> %d)", n0, n1)
        check(not okS and firstLine(errS):find("handle 'rm' was removed", 1, true) ~= nil, "UIREMOVE match1 isShown(<removed>) raises: %s", firstLine(errS))
        check(okR, "UIREMOVE match1 a second remove(h) does nothing")
        check(uiStats().handlesFreed == freed0 + 1, "UIREMOVE match1 its weak handle was freed (freed %d -> %d)", freed0, uiStats().handlesFreed)
    end)

    -- Style (story 8 AC 10, 11 in part): a box of the right colour and padding; none equals the unstyled size.
    step("match1: style", function()
        uiCreate("sty0", { text = "style", place = { absolute = { anchor = "center", x = -300, y = 0 } } })
        uiCreate("sty", { text = "style", place = { absolute = { anchor = "center", x = 300, y = 0 } }, style = { background = "dim", padding = "normal" } })
        return afterMs(1000), 3, "layout"
    end)
    step("match1: style check", function()
        local hud = core.ui.hud.find()
        local w0, w1 = widgetOf("sty0"), widgetOf("sty")
        if not check(w0 and w1, "UISTYLE match1 both style widgets exist") then return end
        local r0, r1 = canvasRect(w0, hud), canvasRect(w1, hud)
        local bg = w1.Background
        local col, pad = bg.BrushColor, bg.Padding
        check(near(col.A, 0.35) and near(col.R, 0) and near(pad.Left, 8) and near(pad.Top, 8),
            "UISTYLE match1 dim/normal: brush=(%.2f,%.2f,%.2f,%.2f) padding=%.1f", col.R, col.G, col.B, col.A, pad.Left)
        check(near(r1.w, r0.w + 16) and near(r1.h, r0.h + 16), "UISTYLE match1 dim/normal is 8 units larger on each side: %.1fx%.1f vs unstyled %.1fx%.1f", r1.w, r1.h, r0.w, r0.h)
        local c0 = w0.Background.BrushColor
        check(near(c0.A, 0) and near(w0.Background.Padding.Left, 0), "UISTYLE match1 unstyled: alpha=%.2f padding=%.1f", c0.A, w0.Background.Padding.Left)
        T().setStyle(UIS.sty, { background = { r = 0.2, g = 0.4, b = 1, a = 0.5 } })
        col = w1.Background.BrushColor
        check(near(col.R, 0.2) and near(col.G, 0.4) and near(col.B, 1) and near(col.A, 0.5) and near(w1.Background.Padding.Left, 8),
            "UISTYLE match1 explicit blue: brush=(%.2f,%.2f,%.2f,%.2f) padding=%.1f (normal by default with a background)", col.R, col.G, col.B, col.A, w1.Background.Padding.Left)
        local c1 = uiStats().uobjectCalls
        T().setStyle(UIS.sty, { background = { r = 0.2, g = 0.4, b = 1, a = 0.5 } })
        check(uiStats().uobjectCalls == c1, "UINOOP match1 the same style again made %d UObject calls", uiStats().uobjectCalls - c1)
        T().setStyle(UIS.sty, { background = "none" })
        local r2 = canvasRect(w1, hud)
        check(near(w1.Background.BrushColor.A, 0) and near(r2.w, r0.w) and near(r2.h, r0.h), "UISTYLE match1 background none: alpha=%.2f size %.1fx%.1f equals unstyled %.1fx%.1f",
            w1.Background.BrushColor.A, r2.w, r2.h, r0.w, r0.h)
        T().remove(UIS.sty0); T().remove(UIS.sty)
    end)

    -- setVisible (story 8 AC 13).
    step("match1: setVisible", function()
        local h = UIS.pre
        T().setVisible(h, false)
        local w = widgetOf("pre")
        check(T().isShown(h) == false and w ~= nil and tonumber(w:GetVisibility()) == 1, "UIHIDE match1 setVisible(h, false): isShown=false, widget Collapsed (%s)", tostring(w and w:GetVisibility()))
        local c0 = uiStats().uobjectCalls
        T().setVisible(h, false)
        check(uiStats().uobjectCalls == c0, "UINOOP match1 setVisible(h, false) again made %d UObject calls", uiStats().uobjectCalls - c0)
        T().setVisible(h, true)
        check(T().isShown(h) == true and textOf(w) == "pre-match", "UIHIDE match1 setVisible(h, true): isShown=true, text %q", tostring(textOf(w)))
    end)

    -- Corners and gaps (story 9 AC 1, 2). 'hid' sits hidden in bottom-left, first in that stack: it takes no space.
    step("match1: corners", function()
        uiCreate("c-tl", { text = "top-left tight", place = { corner = "top-left", gap = "tight" } })
        uiCreate("c-bl", { text = "bottom-left loose", place = { corner = "bottom-left", gap = "loose" } })
        uiCreate("c-br", { text = "bottom-right normal", place = { corner = "bottom-right" } })
        return afterMs(1000), 3, "layout"
    end)
    step("match1: corners check", function()
        checkInset("match1", "c-tl", "top-left", 8)
        checkInset("match1", "c-bl", "bottom-left", 32)
        checkInset("match1", "c-br", "bottom-right", 16)
        checkInset("match1", "pre", "top-right", 16)
        core.ui.place(UIS.pre, { corner = "top-right", gap = "loose" })
        checkInset("match1", "pre", "top-right", 32)
        core.ui.place(UIS.pre, { corner = "top-right", gap = "tight" })
        checkInset("match1", "pre", "top-right", 8)
        core.ui.place(UIS.pre, { corner = "top-right" })
        T().remove(UIS["c-tl"]); T().remove(UIS["c-bl"]); T().remove(UIS["c-br"])
    end)

    -- Offset (story 9 AC 7) and absolute (AC 8).
    step("match1: offset and absolute", function()
        core.ui.place(UIS.pre, { corner = "top-right", offset = { x = -40 } })
        checkInset("match1", "pre", "top-right", 16, 40)
        core.ui.place(UIS.pre, { corner = "top-right" })
        uiCreate("abs", { text = "absolute centre", place = { absolute = { anchor = "center", x = 0, y = -200 } } })
        return afterMs(1000), 3, "layout"
    end)
    step("match1: absolute check", function()
        local hud = core.ui.hud.find()
        local w = widgetOf("abs")
        if not check(w ~= nil, "UIABS match1 'abs' widget exists") then return end
        local r = canvasRect(w, hud)
        local cx, cy = (r.l + r.r) / 2, (r.t + r.b) / 2
        check(near(cx, r.cw / 2) and near(cy, r.ch / 2 - 200) and near(r.alx, 0.5) and near(r.aly, 0.5),
            "UIABS match1 absolute centre (0,-200): centre=(%.1f,%.1f) canvas centre=(%.1f,%.1f)", cx, cy, r.cw / 2, r.ch / 2)
        T().remove(UIS.abs)
    end)

    -- A three-element stack under 'pre' in the top-right corner (story 9 AC 3, 7, 8; story 8 AC 13).
    local function stackRects()
        local hud = core.ui.hud.find()
        local out = {}
        for _, id in ipairs({ "pre", "s1", "s2", "s3" }) do
            local w = widgetOf(id)
            out[id] = w and canvasRect(w, hud) or nil
        end
        return out
    end
    local function stacked(a, b, gap) return a and b and near(b.t, a.b + gap) end
    step("match1: stack", function()
        uiCreate("s1", { text = "stack one" })
        uiCreate("s2", { text = "stack two" })
        uiCreate("s3", { text = "stack three" })
        return afterMs(1500), 3, "layout"
    end)
    step("match1: stack check", function()
        local r = stackRects()
        check(stacked(r.pre, r.s1, 16) and stacked(r.s1, r.s2, 16) and stacked(r.s2, r.s3, 16),
            "UISTACK match1 pre, s1, s2, s3 stack 16 apart: %s %s %s %s", r.pre and rs(r.pre) or "?", r.s1 and rs(r.s1) or "?", r.s2 and rs(r.s2) or "?", r.s3 and rs(r.s3) or "?")
        UIS.stackBefore = r
        -- An absolute element in the same corner is ignored by the stack.
        uiCreate("abs-tr", { text = "absolute in the corner", place = { absolute = { anchor = "top-right", x = -400, y = 16 } } })
        local r2 = stackRects()
        check(near(r2.s1.t, r.s1.t) and near(r2.s3.t, r.s3.t), "UISTACK match1 an absolute element in top-right moves nothing (s1 top %.1f -> %.1f, s3 %.1f -> %.1f)", r.s1.t, r2.s1.t, r.s3.t, r2.s3.t)
        T().remove(UIS["abs-tr"])
        -- Offset the middle one: only it moves.
        core.ui.place(UIS.s2, { corner = "top-right", offset = { x = -40 } })
        local r3 = stackRects()
        check(near(r3.s2.r, r.s2.r - 40) and near(r3.s2.t, r.s2.t) and near(r3.s1.t, r.s1.t) and near(r3.s3.t, r.s3.t) and near(r3.s3.r, r.s3.r),
            "UISTACK match1 offset { x = -40 } on s2 moves only s2 (s2 right %.1f -> %.1f, s3 top %.1f -> %.1f)", r.s2.r, r3.s2.r, r.s3.t, r3.s3.t)
        core.ui.place(UIS.s2, { corner = "top-right" })
        -- Hide the middle one: the gap closes; show it: it opens again.
        T().setVisible(UIS.s2, false)
        local r4 = stackRects()
        check(stacked(r4.s1, r4.s3, 16), "UISTACK match1 hiding s2 closes the gap: s1 %s s3 %s", rs(r4.s1), rs(r4.s3))
        T().setVisible(UIS.s2, true)
        local r5 = stackRects()
        check(stacked(r5.s1, r5.s2, 16) and stacked(r5.s2, r5.s3, 16), "UISTACK match1 showing s2 again restores the stack")
        -- Lengthen the first one (two lines): the others move down.
        T().set(UIS.pre, "pre-match\nsecond line")
        return afterMs(1500), 3, "layout"
    end)
    step("match1: stack grows", function()
        local r = stackRects()
        local before = UIS.stackBefore
        check(r.s1.t > before.s1.t + 5 and stacked(r.pre, r.s1, 16) and stacked(r.s1, r.s2, 16),
            "UISTACK match1 a two-line first element pushes the others down (s1 top %.1f -> %.1f)", before.s1.t, r.s1.t)
        T().set(UIS.pre, "pre-match")
        T().remove(UIS.s2)
        return afterMs(1000), 3, "layout"
    end)
    step("match1: stack after remove", function()
        local r = stackRects()
        check(stacked(r.pre, r.s1, 16) and stacked(r.s1, r.s3, 16) and r.s2 == nil, "UISTACK match1 removing s2 closes the gap: s1 %s s3 %s", rs(r.s1), rs(r.s3))
        T().remove(UIS.s1); T().remove(UIS.s3)
    end)

    -- Near the crosshair (story 9 AC 4, 5).
    step("match1: near", function()
        uiCreate("near", { text = "right of the crosshair", place = { near = "crosshair", side = "right" } })
        return afterMs(1000), 3, "layout"
    end)
    step("match1: near check", function()
        local hud = core.ui.hud.find()
        local w = widgetOf("near")
        local cross = hud.Crosshair
        if not check(w ~= nil and valid(cross), "UINEAR match1 'near' widget and the crosshair exist") then return end
        local cslot = cross.Slot
        local auto = pcall(function() return cslot:GetAutoSize() end) and cslot:GetAutoSize()
        local rc = canvasRect(cross, hud, auto and cross:GetDesiredSize() or cslot:GetSize())
        local r = canvasRect(w, hud)
        check(near(r.l, rc.r + 16) and near((r.t + r.b) / 2, (rc.t + rc.b) / 2) and near(r.ax, rc.ax) and near(r.ay, rc.ay),
            "UINEAR match1 right of the crosshair, centred: ours=%s crosshair=%s anchors=(%.2f,%.2f)", rs(r), rs(rc), r.ax, r.ay)
        hud:HideCrosshair(true)
        return afterMs(1500), 3, "near collapse"
    end)
    step("match1: near hidden", function()
        local w = widgetOf("near")
        check(w ~= nil and tonumber(w:GetVisibility()) == 1 and T().isShown(UIS.near) == false,
            "UINEAR match1 HideCrosshair(true) collapses the element (visibility=%s)", tostring(w and w:GetVisibility()))
        core.ui.hud.find():HideCrosshair(false)
        return afterMs(1500), 3, "near back"
    end)
    step("match1: near back", function()
        local w = widgetOf("near")
        check(w ~= nil and tonumber(w:GetVisibility()) == 4 and T().isShown(UIS.near) == true,
            "UINEAR match1 HideCrosshair(false) brings it back (visibility=%s)", tostring(w and w:GetVisibility()))
        T().remove(UIS.near)
    end)

    -- Story 12 AC 2: an element moved onto the crosshair reports it, through core.ui.debug.overlaps and (debug is on
    -- here) the automatic check's WARN about 1 s after the attach.
    step("match1: onto the crosshair", function()
        uiCreate("xcross", { text = "on the crosshair", place = { near = "crosshair", side = "right", gap = "normal", offset = { x = -24 } } })
        local okP, n = pcall(function() return core.ui.text.stats().overlapScheduled end)
        UIS.xSched = okP and n or -1
        return afterMs(1500), 3, "layout and the automatic check"
    end)
    step("match1: overlap wait", function()
        local deadline = os.clock() + 5
        return function()
            local hits, info = core.ui.debug.overlaps(UIS.xcross)
            UIS.xHits, UIS.xWhy = hits, info
            return hits ~= nil or not tostring(info):find("not painted", 1, true) or os.clock() > deadline
        end, 8, "xcross painted"
    end)
    step("match1: overlap check", function()
        local hud = core.ui.hud.find()
        local cross = hud and hud.Crosshair
        local cpath = valid(cross) and pathOf(cross) or "?"
        local hits = UIS.xHits
        if not check(hits ~= nil, "UIOVERLAP match1 'xcross' could be checked (%s)", tostring(UIS.xWhy)) then return end
        local found_, names = false, {}
        for i, h in ipairs(hits) do
            if h.path == cpath or h.path:sub(1, #cpath + 1) == cpath .. "." then found_ = true end
            if i <= 6 then names[#names + 1] = (h.path:match("[^%.:]+$") or h.path) .. " (" .. h.class .. ")" end
        end
        check(found_, "UIOVERLAP match1 'xcross' (near the crosshair, offset x=-24) reports the crosshair %s: %d hit(s): %s",
            cpath:match("[^%.:]+$") or cpath, #hits, table.concat(names, ", "))
        local sched = core.ui.text.stats().overlapScheduled
        check(UIS.xSched > 0 and sched >= UIS.xSched, "UIOVERLAP match1 automatic checks were scheduled with debug on (%s, now %s)", tostring(UIS.xSched), tostring(sched))
        T().remove(UIS.xcross)
    end)

    -- A late watcher (story 7 AC 4).
    step("match1: late watcher", function()
        UIS.late = {}
        UIS.lateToken = core.ui.hud.watch(function(_, info) UIS.late[#UIS.late + 1] = info.event .. ":" .. tostring(info.reason) end)
        return afterMs(1500), 3, "late watcher"
    end)
    step("match1: late watcher check", function()
        check(UIS.late[1] ~= nil and UIS.late[1]:sub(1, 9) == "attached:", "UILATE match1 a watcher registered while the HUD is live gets attached on the next tick (%s)", tostring(UIS.late[1]))
        core.ui.hud.unwatch(UIS.lateToken)
    end)

    -- RemoveAllWidgets and re-add (story 7 AC 3, story 10 AC 4): lost, then attached "HUD back in the viewport", reused.
    step("match1: RemoveAllWidgets", function()
        local w = widgetOf("pre")
        UIS.prePath = w and pathOf(w)
        UIS.evBefore = #EV.list
        local hud = core.ui.hud.find()
        WLL():RemoveAllWidgets(hud:GetWorld())
        return eventAfter(UIS.evBefore, "lost"), 10, "lost after RemoveAllWidgets"
    end)
    step("match1: re-add the HUD", function()
        local hud = found(EV.hudPath)
        if not check(hud ~= nil, "UIRAW match1 the HUD still exists after RemoveAllWidgets (%s)", tostring(EV.hudPath)) then return end
        hud:AddToViewport(0)
        return eventAfter(UIS.evBefore, "attached", "HUD back in the viewport"), 10, "attached back in the viewport"
    end)
    step("match1: reused", function() return function() return T().isShown(UIS.pre) end, 10, "'pre' shown again" end)
    step("match1: reused check", function()
        local w, n = widgetOf("pre")
        check(w ~= nil and n == 1 and pathOf(w) == UIS.prePath, "UIRAW match1 'pre' reused, not duplicated (widgets=%d, same widget=%s)", n, tostring(w and pathOf(w) == UIS.prePath))
        local hid, nh = widgetOf("hid")
        check(hid ~= nil and nh == 1 and tonumber(hid:GetVisibility()) == 1 and T().isShown(UIS.hid) == false, "UIHID match1 'hid' still hidden (widgets=%d)", nh)
        local wp = widgetOf("pre")
        UIS.oldPre = wp and { handle = core.ref(wp), path = pathOf(wp) } or nil
    end)

    -- hidden / shown on the same HUD (story 7 AC 2), made here rather than relied on: whether the lobby's hidden HUD
    -- lasts the two ticks an attach takes depends on load timing.
    step("match1: hide the HUD", function()
        local hud = core.ui.hud.find()
        UIS.hudVis = tonumber(hud:GetVisibility()) or 0
        UIS.evBefore = #EV.list
        hud:SetVisibility(2) -- Hidden
        return eventAfter(UIS.evBefore, "hidden"), 10, "hidden after SetVisibility(Hidden)"
    end)
    step("match1: show the HUD", function()
        check(core.ui.hud.isVisible() == false and T().isShown(UIS.pre) == false, "UIHUDHIDE match1 HUD hidden: isVisible=false, 'pre' isShown=false")
        core.ui.hud.find():SetVisibility(UIS.hudVis)
        return eventAfter(UIS.evBefore, "shown"), 10, "shown after restoring visibility"
    end)
    step("match1: shown again", function()
        check(core.ui.hud.isVisible() == true and T().isShown(UIS.pre) == true, "UIHUDSHOW match1 HUD visibility restored (%d): isVisible=true, 'pre' isShown=true", UIS.hudVis)
    end)

    -- Map changes: menu2 and match2 (story 10 AC 3, story 8 AC 13), with the handle of the old widget freed.
    travel("menu2", MENU_MAP, "")
    waitWorld("menu2", "NewMainMenu", 150)
    step("menu2: old widget gone", function()
        if UIS.oldPre and core.deref(UIS.oldPre.handle) ~= nil then
            StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
            return after(2), 5, "gc"
        end
    end)
    step("menu2: old widget deref", function()
        if not UIS.oldPre then return end
        check(core.deref(UIS.oldPre.handle) == nil, "UIDEREF menu2 the match's 'pre' widget derefs to nil after the map change")
        core.free(UIS.oldPre.handle)
        UIS.oldPre = nil
    end)
    step("menu2: attached", function() return function() local _, n = widgetOf("pre") return n == 1 end, 60, "menu2 'pre' attached" end)
    step("menu2: check", function()
        local _, n = widgetOf("pre")
        check(n == 1 and T().isShown(UIS.pre) == false, "UIONE menu2 'pre' attached to the menu HUD once (widgets=%d), not shown", n)
    end)
    travel("match2", MATCH_MAP, "listen")
    waitWorld("match2", "SmallMap", 150)
    touchdown("match2")
    step("match2: shown", function() return function() return T().isShown(UIS.pre) end, 120, "match2 'pre' isShown" end)
    step("match2: settle", function() return afterMs(1500), 3, "settle" end)
    -- The helpers log their DEBUG tick summary once a minute (check.ps1 requires one), and on V8.1.2 the scenario gets
    -- here in under a minute; wait in the live match until the first one-minute window has closed.
    step("match2: one tick summary", function()
        say("UIWAIT match2 waiting for the first one-minute hud tick summary (%d s since the first watcher)", os.time() - UIS.t0)
        return function() return os.time() >= UIS.t0 + 63 end, 75, "first hud tick summary window"
    end)
    step("match2: check", function()
        local _, n = widgetOf("pre")
        check(n == 1, "UIONE match2 'pre' exactly one widget (found %d)", n)
        checkInset("match2", "pre", "top-right", 16)
        local hid, nh = widgetOf("hid")
        check(hid ~= nil and nh == 1 and tonumber(hid:GetVisibility()) == 1 and T().isShown(UIS.hid) == false,
            "UIHID match2 'hid' is still hidden on the new HUD (widgets=%d)", nh)
        T().setVisible(UIS.hid, true)
        check(T().isShown(UIS.hid) == true, "UIHID match2 setVisible(hid, true) shows it")
        local st = core.ui.hud.stats()
        check(st.findAllCalls == 1, "UIFINDALL match2 FindAllOf ran %d time(s) in this Lua state (expected exactly 1, the seed)", st.findAllCalls)
        -- Reported, not judged: this run crosses map changes, where the game itself hitches. Story 7 AC 7 (10 minutes in
        -- one match) is a hand check; check.ps1 only soft-checks the poll maximum.
        say("UITICK ticks=%d poll avg=%.1f max=%d us, watchers avg=%.1f max=%d us", st.ticks, st.pollAvg, st.pollMax, st.watchAvg, st.watchMax)
        check((EV.count.attached or 0) >= 4 and (EV.count.lost or 0) >= 3 and (EV.count.shown or 0) >= 1,
            "UIEVENTS attached=%d shown=%d hidden=%d lost=%d", EV.count.attached or 0, EV.count.shown or 0, EV.count.hidden or 0, EV.count.lost or 0)
        local s = uiStats()
        say("UISTATS elements=%d created=%d reused=%d freed=%d uobjectCalls=%d", s.elements, s.attachCreated, s.attachReused, s.handlesFreed, s.uobjectCalls)
        T().remove(UIS.pre); T().remove(UIS.hid)
        core.ui.hud.unwatch(UIS.thrower)
        core.ui.hud.unwatch(UIS.recorder)
        check(uiStats().elements == 0, "UICLEAN match2 every element removed")
    end)
end

-- ---------------------------------------------------------------- soak (story 7 AC 7, unattended)
-- menu -> match, Enter at touchdown, then SOAK_S seconds idle in the match with one element and one watcher, the way
-- a real dependent sits there. The helpers' one-minute DEBUG tick lines (and the profiler's) are the measurement;
-- check.ps1 judges them. Never travels again and never touches the HUD itself.
local SOAK_S = 600
local function buildSoak()
    step("soak: watch and create", function()
        UIS.recorder = core.ui.hud.watch(recorder)
        uiCreate("soak", { text = CORE .. " soak" })
    end)
    waitWorld("menu1", "NewMainMenu", 120)
    travel("match1", MATCH_MAP, "listen")
    waitWorld("match1", "SmallMap", 150)
    touchdown("match1")
    step("match1: shown", function() return function() return core.ui.text.isShown(UIS.soak) end, 120, "match1 'soak' isShown" end)
    -- Ten idle minutes get the player killed (V8.1.2's monsters), and death takes the HUD away: god mode, through the
    -- cheat manager CheatManagerEnablerMod puts on the controller.
    step("match1: god mode", function()
        local ok, err = pcall(function() pc().CheatManager:God() end)
        say("SOAKGOD %s", ok and "ok (CheatManager:God)" or ("not available: " .. firstLine(err)))
    end)
    -- What one UE4SS call costs here, for the tick's budget: n calls of each, average and worst single call (us).
    step("match1: call costs", function()
        local hud = core.ui.hud.find()
        if not hud then return end
        local h = core.ref(hud)
        local micros = core.clock.micros
        local function bench(name, fn)
            local n, sum, max = 300, 0, 0
            for _ = 1, n do
                local t0 = micros(); fn(); local dt = micros() - t0
                sum = sum + dt; if dt > max then max = dt end
            end
            say("SOAKBENCH %-34s avg %6.2f max %5d us (n=%d)", name, sum / n, max, n)
        end
        bench("hud:GetVisibility()", function() return hud:GetVisibility() end)
        bench("hud.Visibility (property)", function() return hud.Visibility end)
        bench("hud:IsInViewport()", function() return hud:IsInViewport() end)
        bench("pcall(closure: IsInViewport)", function() return pcall(function() return hud:IsInViewport() end) end)
        bench("hud:GetOwningPlayer()", function() return hud:GetOwningPlayer() end)
        bench("hud:IsValid()", function() return hud:IsValid() end)
        bench("core.deref(handle)", function() return core.deref(h) end)
        bench("StaticFindObject(hud path) hit", function() return StaticFindObject(EV.hudPath) end)
        bench("micros() alone", function() end)
        core.free(h)
    end)
    step("match1: idle", function()
        UIS.soakStart = os.time()
        UIS.soakLost = EV.count.lost or 0
        say("SOAK idle %d s in the match from here", SOAK_S)
        return function() return os.time() >= UIS.soakStart + SOAK_S end, SOAK_S + 30, "soak idle"
    end)
    step("match1: report", function()
        -- About 7 minutes into an idle match on V8.1.2 the game restarts the player (ClientRestart, god mode or not)
        -- and leaves no HUD in the viewport; that is the game, reported but not judged. Without a HUD there is no
        -- canvas to count widgets in.
        local lostIdle = (EV.count.lost or 0) - UIS.soakLost
        if lostIdle == 0 then
            local _, n = widgetOf("soak")
            check(n == 1 and core.ui.text.isShown(UIS.soak), "SOAKONE match1 'soak' still shown, one widget (found %d)", n)
        else
            check(core.ui.text.isShown(UIS.soak) == false, "SOAKONE match1 the game took the HUD away %d time(s) while idle; 'soak' isShown=false", lostIdle)
        end
        local st = core.ui.hud.stats()
        say("SOAKTICK ticks=%d poll avg=%.1f max=%d us, watchers avg=%.1f max=%d us; steady n=%d avg=%.1f max=%d us; events n=%d avg=%.1f max=%d us; findAll=%d",
            st.ticks, st.pollAvg, st.pollMax, st.watchAvg, st.watchMax, st.steadyTicks, st.steadyAvg, st.steadyMax,
            st.eventTicks, st.eventAvg, st.eventMax, st.findAllCalls)
        say("%s SOAKEVENTS HUD lost while idle %d time(s); attached=%d shown=%d hidden=%d lost=%d", (EV.count.lost or 0) == UIS.soakLost and "OK" or "NOTE", (EV.count.lost or 0) - UIS.soakLost, EV.count.attached or 0, EV.count.shown or 0, EV.count.hidden or 0, EV.count.lost or 0)
    end)
end

-- ---------------------------------------------------------------- runner (game thread, every 250 ms)
local idx, waiting, busy, finished = 0, nil, false, false
local function finish()
    finished = true
    say("END result=%s checks=%d failures=%d", (S.failures == 0 and S.checks > 0) and "PASS" or "FAIL", S.checks, S.failures)
end
local function tick()
    if busy or finished then return end
    busy = true
    local ok, err = pcall(function()
        if waiting then
            if not waiting.pred() then
                if os.time() <= waiting.deadline then return end
                check(false, "TIMEOUT %s", waiting.what)
            end
            waiting = nil
        end
        idx = idx + 1
        local s = steps[idx]
        if not s then finish() return end
        local pred, timeout, what = s.fn()
        if pred then waiting = { pred = pred, deadline = os.time() + (timeout or 10), what = what or s.name } end
    end)
    if not ok then
        check(false, "STEP '%s' threw: %s", steps[idx] and steps[idx].name or "?", tostring(err))
        waiting = nil
    end
    busy = false
end

-- ---------------------------------------------------------------- manual (hand testing)
-- Runs on core's UI helpers (stories 7-10): one element "manual" ("<Core> manual: <n>") in the top-right corner,
-- created once with core.ui.text.create; core re-attaches it after every HUD rebuild and logs "DEBUG ui attach 'manual'
-- created|reused ...". A core.ui.hud watcher logs every HUD event; on attached, n counts the attaches and an ATTACH
-- line reports the HUD, its visibility, the element's widget (found by its tag) and its rectangle. Overlap reports
-- (core.ui.debug.overlaps, story 12) follow about 1 s and 4 s after an attach or the HUD showing, from a 500 ms
-- game-thread loop; with debug on, core's own automatic check also logs "WARN ui overlap 'manual': ..." once per
-- overlapping widget. The helpers' DEBUG lines (tick summaries once a minute) are on. Nothing here travels, presses keys, waits with a deadline or logs FAIL: what
-- the player does is only reported. Every error is caught and logged once per context as "WARN manual <context>: ...".
local MANUAL_TICK_MS = 500
local OVERLAP_LINES = 40      -- overlapping widgets logged per report
local REPORT_TICKS = { { 2, "+1s" }, { 8, "+4s" } } -- overlap reports after an attach (or the HUD showing)
local VIS = { [0] = "Visible", [1] = "Collapsed", [2] = "Hidden", [3] = "HitTestInvisible", [4] = "SelfHitTestInvisible" }
local MANUAL_PREFIX = CORE .. " manual: "

local M = { count = 0, tick = 0, warned = {}, reports = {} }

local function warnOnce(context, err)
    if M.warned[context] then return end
    M.warned[context] = true
    say("WARN manual %s: %s (further warnings for this are not logged)", context, firstLine(err))
end

local function hudVis(hud)
    local vis = tonumber(hud:GetVisibility()) or -1
    return vis, not (vis == 1 or vis == 2)
end

-- The element's widget among the live canvas's direct children, found by its tag, and how many carry the tag.
local function manualWidget(hud)
    local canvas = hud.OwningCanvas
    if not valid(canvas) then return nil, 0 end
    local tag = core.ui.text.tagOf("manual")
    local first, n = nil, 0
    for i = 0, canvas:GetChildrenCount() - 1 do
        local c = canvas:GetChildAt(i)
        if valid(c) and c:GetClass():GetFName():ToString() == "WBP_" .. CORE .. "Text_C" then
            local ok, t = pcall(function() return c.ToolTipText:ToString() end)
            if ok and t == tag then n = n + 1; first = first or c end
        end
    end
    return first, n
end

-- The widget's rectangle in canvas space, computed like the skeleton's CORNER check.
local function cornerRect(w, hud)
    local slot = w.Slot
    local an, al, pos = slot:GetAnchors(), slot:GetAlignment(), slot:GetPosition()
    local ds = w:GetDesiredSize()
    local world = hud:GetWorld()
    local vp, scale = WLL():GetViewportSize(world), WLL():GetViewportScale(world)
    local cw, ch = vp.X / scale, vp.Y / scale
    local left = an.Minimum.X * cw + pos.X - al.X * ds.X
    local top = an.Minimum.Y * ch + pos.Y - al.Y * ds.Y
    return string.format("rect=(%.1f,%.1f)-(%.1f,%.1f) desired=(%.1fx%.1f) gapRight=%.1f gapTop=%.1f canvas=(%.0fx%.0f) dpi=%.3f",
        left, top, left + ds.X, top + ds.Y, ds.X, ds.Y, cw - (left + ds.X), top, cw, ch, scale)
end

local function scheduleReports(what)
    local list = {}
    for _, r in ipairs(REPORT_TICKS) do list[#list + 1] = { at = M.tick + r[1], label = what .. " " .. r[2] } end
    return list
end

-- core.ui.hud watcher. Registered after the element exists, so core's own watcher (registered by create) has already
-- re-attached the element when this one hears "attached".
local function onHudEvent(hud, info)
    if info.event == "attached" then
        M.count = M.count + 1
        core.ui.text.set(M.handle, MANUAL_PREFIX .. M.count)
        M.hudPath = info.path
        local w, mine = manualWidget(hud)
        M.widgetPath = w and pathOf(w) or nil
        local vis, shown = hudVis(hud)
        local okR, rect = false, "no widget in the canvas"
        if w then
            pcall(function() w:ForceLayoutPrepass() end) -- so the desired size is measured before the first paint
            okR, rect = pcall(cornerRect, w, hud)
        end
        say("ATTACH %d widget=%s hud=%s hudVisible=%s visibility=%s oursInCanvas=%d shown=%s %s world=%s reason=%s",
            M.count, tostring(M.widgetPath), tostring(M.hudPath), tostring(shown), VIS[vis] or tostring(vis), mine,
            tostring(core.ui.text.isShown(M.handle)), okR and rect or ("rect=? (" .. firstLine(rect) .. ")"),
            worldName():match("/Game/[^ ]+") or "?", tostring(info.reason))
        M.reports = shown and scheduleReports("attach " .. M.count) or {}
    elseif info.event == "lost" then
        say("HUD gone from the viewport (was %s); waiting for a live HUD", tostring(info.path))
        M.hudPath, M.reports = nil, {}
    else
        say("HUD %s now (%s, %s, attach %d)", info.event == "shown" and "visible" or "hidden", tostring(info.reason), tostring(info.path), M.count)
        M.reports = info.event == "shown" and scheduleReports("shown at attach " .. M.count) or {}
    end
end

-- ---- overlap report: core.ui.debug.overlaps (story 12; the prototype that lived here moved into core's ui/debug.lua)
local function rectStr(r) return string.format("(%.0f,%.0f)-(%.0f,%.0f)", r.l, r.t, r.r, r.b) end
local function overlapReport(label)
    local hits, info = core.ui.debug.overlaps(M.handle)
    if not hits then say("OVERLAP skipped (%s): %s", label, tostring(info)) return end
    say("OVERLAP check (%s) ours=%s screen=(%.0fx%.0f) roots=%d via %s", label, rectStr(info.rect), info.screen.w, info.screen.h, info.roots, tostring(info.via))
    for i = 1, math.min(#hits, OVERLAP_LINES) do
        local h = hits[i]
        say("OVERLAP %s class=%s rect=%s%s", h.path, h.class, rectStr(h.rect), h.element and (" element=" .. h.element) or "")
    end
    -- Context, not overlaps: drawn widgets within 64 px of the element (short names).
    for _, h in ipairs(info.nearby) do
        say("OVERLAP near %s class=%s rect=%s", h.path:match("[^%.:]+$") or h.path, h.class, rectStr(h.rect))
    end
    local extra = string.format(", %d drawn on screen, %d of them in the top-right quarter%s%s%s%s", info.drawn, info.quadrant,
        info.fullScreen > 0 and (", " .. info.fullScreen .. " full-screen skipped") or "",
        info.errors > 0 and (", " .. info.errors .. " error(s)") or "",
        info.capped and ", capped" or "",
        #hits > OVERLAP_LINES and (", only " .. OVERLAP_LINES .. " listed") or "")
    if #hits == 0 then say("OVERLAP none (checked %d widgets%s; %s)", info.checked, extra, label)
    else say("OVERLAP found %d (checked %d widgets%s; %s)", #hits, info.checked, extra, label) end
end

local function manualTick()
    M.tick = M.tick + 1
    for i = #M.reports, 1, -1 do
        local r = M.reports[i]
        if M.tick >= r.at then
            table.remove(M.reports, i)
            local ok, err = pcall(overlapReport, r.label)
            if not ok then warnOnce("overlap", err) end
        end
    end
end

local function startManual()
    say("MANUAL hand-testing mode on core's UI helpers: no travel, no keys, no timed checks; keeps '%s<n>' in the live HUD's top-right corner", MANUAL_PREFIX)
    core.log.debugEnabled = true
    local okC, h = pcall(core.ui.text.create, { id = "manual", text = MANUAL_PREFIX .. 0 })
    if not okC then warnOnce("create", h) return end
    M.handle = h
    local okW, errW = pcall(core.ui.hud.watch, function(hud, info)
        local ok, err = pcall(onHudEvent, hud, info)
        if not ok then warnOnce("event " .. tostring(info and info.event), err) end
    end)
    if not okW then warnOnce("watch", errW) end
    -- A game-thread loop registered from the game thread (onReady runs there): never LoopAsync + ExecuteInGameThread,
    -- which can lose callbacks in the pinned UE4SS (core's ui/hud.lua explains the race).
    local okL, errL = pcall(LoopInGameThreadWithDelay, MANUAL_TICK_MS, function()
        local ok, err = pcall(manualTick)
        if not ok then warnOnce("tick", err) end
    end)
    if not okL then warnOnce("scheduling", errL) end
end

-- The helpers' per-phase tick profiler (diagnostic, not core's public API): the same module instance core.ui uses,
-- since both live in this Lua state.
local function profile(on)
    local ok, err = pcall(function() require(CORE:lower() .. ".ui.hud")._profile(on) end)
    if not ok then say("WARN could not switch the UI tick profiler: %s", firstLine(err)) end
end

client.connect{
    mod = ME, need = NEED,
    onReady = function(api)
        core = api
        if SCENARIO == "manual" then profile(true) startManual() return end
        if SCENARIO == "bad-input" then buildBadInput()
        elseif SCENARIO == "ui" or SCENARIO == "soak" then
            core.log.debugEnabled = true -- the helpers' DEBUG lines (tick summaries, freed handles) are part of the check
            profile(true)
            if SCENARIO == "ui" then buildUi() else buildSoak() end
        else buildSkeleton() end
        -- The runner: a game-thread loop registered here on the game thread, cancelled once finished. Never
        -- LoopAsync + ExecuteInGameThread (core's ui/hud.lua: the pinned UE4SS can lose such callbacks).
        local runner
        local okL, res = pcall(LoopInGameThreadWithDelay, 250, function()
            tick()
            if finished and runner then pcall(CancelDelayedAction, runner); runner = nil end
        end)
        if okL then runner = res else say("END result=FAIL checks=0 failures=1 reason=runner (%s)", firstLine(res)) end
    end,
    onFail = function(msg)
        -- client.connect has already logged the one-line reason.
        if SCENARIO ~= "manual" then say("END result=FAIL checks=0 failures=1 reason=connect") end
    end,
}
say("LOADED main.lua done; waiting for connect")
