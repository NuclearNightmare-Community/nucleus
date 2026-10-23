-- <Core>SkelTest: throwaway dependent that proves core's walking skeleton unattended (spec-core-v0 CAP-8).
-- Never shipped. It deliberately avoids the UI-helper API: it inserts its text widget into the HUD by hand.
-- deploy.ps1 installs it as Mods/<Core>SkelTest (from test/SkelTest) and writes the scenario to scenario.txt here.
--
-- skeleton:  calls <Core>_NativeVersion during main.lua; connects through the bootstrap + client.connect; travels
--            menu -> SmallMap?listen -> menu -> SmallMap?listen with OpenLevel. In each world it re-finds the live
--            HUD, shows one text widget anchored to the top-right corner of InventoryUI_C.OwningCanvas, re-finds it by
--            weak handle, checks its layout, and checks that the previous world's widget handle derefs to nil. In
--            each match it also times <Core>_Ref.
-- bad-input: menu -> SmallMap?listen; calls every public native and the channel with bad values (bad-input cases
--            below), on and off the game thread, and checks each answer against the contract.
-- manual:    for hand testing. Never travels, requests keys, runs timed checks or logs FAIL. Keeps a
--            "<Core> manual: <n>" text widget in the top-right corner of the live HUD's canvas, attaching again
--            whenever the HUD is rebuilt, replaced or put back in the viewport (n counts attaches), and logs an
--            experimental report of the drawn widgets its on-screen rectangle overlaps.
-- Keys it can't press itself (Enter for touchdown) go to run.ps1 through request.txt / done.txt next to this file.
-- Never keeps a UObject across steps: only paths, addresses (as integers, never dereferenced) and weak handles.
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local ME = scriptDir:match("([^/\\]+)[/\\][Ss]cripts$")
local CORE = ME:match("^(.-)SkelTest$") -- the one place the core's name comes from: this folder's name
local NEED = "0.1.0"

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
    end)
end

local function badInputCases(phase)
    step(phase .. ": native cases", function() nativeCases(phase) end)
    step(phase .. ": channel cases", function() channelCases(phase) end)
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
-- Polls on the game thread every 500 ms. Between ticks it keeps only strings and numbers (paths, counters) and the
-- widget's weak handle; every UObject is re-found inside the tick that uses it. Nothing here travels, presses keys,
-- waits with a deadline or logs FAIL: what the player does is only reported. Every error is caught and logged once
-- per context as "WARN manual <context>: ...".
local MANUAL_TICK_MS = 500
local OVERLAP_CAP = 2000      -- widgets visited per overlap check
local OVERLAP_LINES = 40      -- overlapping widgets logged per check
local NEAR_LINES = 10         -- other drawn widgets in the screen's top-right quarter logged per check
local REPORT_TICKS = { { 2, "+1s" }, { 8, "+4s" } } -- overlap reports after an attach (or the HUD showing)
local VIS = { [0] = "Visible", [1] = "Collapsed", [2] = "Hidden", [3] = "HitTestInvisible", [4] = "SelfHitTestInvisible" }
-- Widget classes that draw something themselves; containers (CanvasPanel, Overlay, SizeBox, ...) draw nothing.
local DRAWN = { "Image", "TextBlock", "RichTextBlock", "ProgressBar", "Border", "Button", "CheckBox", "EditableText",
    "EditableTextBox", "MultiLineEditableText", "MultiLineEditableTextBox", "Slider", "SpinBox", "Throbber",
    "CircularThrobber", "ComboBoxString", "ComboBoxKey" }
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

local function isOurs(w)
    if not valid(w) then return false end
    if M.widgetPath and pathOf(w) == M.widgetPath then return true end
    -- Also one left by an earlier Lua state of this mod (hot reload): our class and our text.
    if w:GetClass():GetFName():ToString() ~= "WBP_" .. CORE .. "Text_C" then return false end
    local ok, t = pcall(function() return w.Text:GetText():ToString() end)
    return ok and type(t) == "string" and t:sub(1, #MANUAL_PREFIX) == MANUAL_PREFIX
end

-- Our widget among the canvas's direct children (the first one) and how many of ours there are.
local function oursIn(canvas)
    local first, n = nil, 0
    for i = 0, canvas:GetChildrenCount() - 1 do
        local c = canvas:GetChildAt(i)
        if isOurs(c) then n = n + 1; first = first or c end
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

local function attach(hud, nLive, reason)
    local canvas = hud.OwningCanvas
    if not valid(canvas) then warnOnce("attach", "the HUD has no OwningCanvas: " .. pathOf(hud)) return end
    local w, mine = oursIn(canvas)
    local how = "reused"
    if not w then
        local cls = textClass()
        if not cls then warnOnce("attach", "text widget class not found: " .. TEXT_CLASS) return end
        local owner = hud:GetOwningPlayer()
        if not valid(owner) then owner = pc() end
        if not valid(owner) then return end -- between worlds; the next tick tries again
        w = WBL():Create(hud:GetWorld(), cls, owner)
        if not valid(w) then warnOnce("attach", "creating the text widget failed") return end
        canvas:AddChildToCanvas(w)
        how, mine = "created", 1
    end
    local slot = w.Slot
    slot:SetAutoSize(true)
    slot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
    slot:SetAlignment({ X = 1, Y = 0 })
    slot:SetPosition({ X = -MARGIN, Y = MARGIN })
    M.count = M.count + 1
    w:SetText(MANUAL_PREFIX .. M.count)
    pcall(function() w:ForceLayoutPrepass() end) -- so the desired size is measured before the first paint
    local path = pathOf(w)
    if path ~= M.widgetPath then
        local okF, errF = pcall(core.free, M.handle)
        if not okF then warnOnce("free", errF) end
        M.handle, M.widgetPath = core.ref(w), path
    end
    M.hudPath, M.lastHudPath = pathOf(hud), pathOf(hud)
    local vis, shown = hudVis(hud)
    M.hudShown = shown
    local okR, rect = pcall(cornerRect, w, hud)
    say("ATTACH %d %s widget=%s hud=%s hudVisible=%s visibility=%s liveHuds=%d oursInCanvas=%d %s world=%s reason=%s",
        M.count, how, path, M.hudPath, tostring(shown), VIS[vis] or tostring(vis), nLive, mine,
        okR and rect or ("rect=? (" .. firstLine(rect) .. ")"), worldName():match("/Game/[^ ]+") or "?", reason)
    M.reports = shown and scheduleReports("attach " .. M.count) or {}
end

-- ---- experimental overlap report
local function absRect(cdo, w)
    local tl = cdo[CORE .. "_AbsTopLeft"](cdo, w)
    local br = cdo[CORE .. "_AbsBottomRight"](cdo, w)
    return { l = tl.X, t = tl.Y, r = br.X, b = br.Y }
end
local function rectStr(r) return string.format("(%.0f,%.0f)-(%.0f,%.0f)", r.l, r.t, r.r, r.b) end
local function hasArea(r) return r.r > r.l and r.b > r.t end
local function intersects(a, b) return math.min(a.r, b.r) > math.max(a.l, b.l) and math.min(a.b, b.b) > math.max(a.t, b.t) end

local function drawsSomething(w, kind)
    local ok, yes = pcall(function()
        if kind == "Border" then return tonumber(w.Background.DrawAs) ~= 0 and w.BrushColor.A > 0 end
        if kind == "Image" then return tonumber(w.Brush.DrawAs) ~= 0 and w.ColorAndOpacity.A > 0 end
        if kind == "TextBlock" then return w:GetText():ToString() ~= "" end
        return true
    end)
    return not ok or yes -- when in doubt, report it
end

-- Top-level viewport widgets other than the HUD: WidgetBlueprintLibrary.GetAllWidgetsOfClass (TopLevelOnly) when
-- UE4SS hands its out array back, otherwise every UserWidget FindAllOf returns that is in the viewport.
-- Returns the count and the method used.
local function topLevelWidgets(world, uwClass, push)
    local n = 0
    local function take(x)
        if type(x) ~= "userdata" then return end
        -- Array elements may come back wrapped (a RemoteUnrealParam with get()) instead of as the UObject itself.
        if x.IsValid == nil and x.get ~= nil then x = x:get() end
        if valid(x) and pathOf(x) ~= M.hudPath then n = n + 1; push(x) end
    end
    local ok, err = pcall(function()
        local out = {}
        WBL():GetAllWidgetsOfClass(world, out, uwClass, true)
        local arr = out.FoundWidgets
        if arr == nil and out[1] ~= nil then arr = out end
        if arr == nil then
            local keys = {}
            for k, v in pairs(out) do keys[#keys + 1] = tostring(k) .. "=" .. type(v) if #keys >= 8 then break end end
            error("no FoundWidgets in the out table (keys: " .. (#keys > 0 and table.concat(keys, ", ") or "none") .. ")")
        end
        if type(arr) == "table" then
            for _, x in ipairs(arr) do take(x) end
        else
            arr:ForEach(function(_, e) take(e:get()) end)
        end
    end)
    if ok then return n, "GetAllWidgetsOfClass" end
    warnOnce("overlap GetAllWidgetsOfClass", err)
    n = 0
    for _, x in ipairs(FindAllOf("UserWidget") or {}) do
        if valid(x) and x:IsInViewport() then take(x) end
    end
    return n, "FindAllOf(UserWidget) in viewport"
end

local function overlapReport(label)
    local hud = found(M.hudPath)
    if not hud then say("OVERLAP skipped (%s): the HUD is gone", label) return end
    local _, shown = hudVis(hud)
    if not shown then say("OVERLAP skipped (%s): the HUD is hidden", label) return end
    local ours = core.deref(M.handle)
    if not ours then say("OVERLAP skipped (%s): our widget is gone", label) return end
    local cdo = found(ACTOR_CDO)
    if not cdo then warnOnce("overlap", "core's ModActor class default object not found: " .. ACTOR_CDO) return end
    local mine = absRect(cdo, ours)
    if not hasArea(mine) then say("OVERLAP skipped (%s): our widget has no on-screen geometry yet %s", label, rectStr(mine)) return end
    local screen = absRect(cdo, hud.OwningCanvas)
    local sw, sh = screen.r - screen.l, screen.b - screen.t

    local classes = {}
    for _, n in ipairs(DRAWN) do
        local c = found("/Script/UMG." .. n)
        if c then classes[#classes + 1] = { name = n, cls = c } end
    end
    local UW, PANEL, SWITCH = found("/Script/UMG.UserWidget"), found("/Script/UMG.PanelWidget"), found("/Script/UMG.WidgetSwitcher")

    local stack = { hud.OwningCanvas }
    local function push(x) stack[#stack + 1] = x end
    local okT, tops, via = pcall(topLevelWidgets, hud:GetWorld(), UW, push)
    if not okT then warnOnce("overlap top-level widgets", tops); tops, via = "?", "failed" end

    -- drawn: drawn widgets with an on-screen rectangle; quadrant: those of them in the screen's top-right quarter.
    local seen, visited, hits, full, errors, drawn, quadrant, near = {}, 0, {}, 0, 0, 0, 0, {}
    local topRight = { l = screen.l + sw / 2, t = screen.t, r = screen.r, b = screen.t + sh / 2 }
    local function visit(x)
        if not valid(x) then return end
        local p = pathOf(x)
        if seen[p] or p == M.widgetPath then return end -- our widget and everything inside it are skipped
        seen[p] = true
        local vis = tonumber(x:GetVisibility())
        if vis == 1 or vis == 2 or x:GetRenderOpacity() <= 0 then return end -- not drawn, nor anything inside
        local kind
        for _, c in ipairs(classes) do if x:IsA(c.cls) then kind = c.name break end end
        if kind and drawsSomething(x, kind) then
            local r = absRect(cdo, x)
            if hasArea(r) then
                drawn = drawn + 1
                if intersects(r, topRight) then quadrant = quadrant + 1 end
            end
            local isFull = r.r - r.l >= 0.9 * sw and r.b - r.t >= 0.9 * sh
            local entry = { path = p, cls = x:GetClass():GetFName():ToString(), rect = r, vis = VIS[vis] or tostring(vis) }
            if hasArea(r) and intersects(r, mine) then
                if isFull then full = full + 1 else hits[#hits + 1] = entry end
            elseif hasArea(r) and not isFull and intersects(r, topRight) then
                near[#near + 1] = entry
            end
        end
        if UW and x:IsA(UW) then
            local tree = x.WidgetTree
            if valid(tree) then push(tree.RootWidget) end
        elseif SWITCH and x:IsA(SWITCH) then
            push(x:GetActiveWidget())
        elseif PANEL and x:IsA(PANEL) then
            for i = x:GetChildrenCount() - 1, 0, -1 do push(x:GetChildAt(i)) end
        end
    end
    while #stack > 0 and visited < OVERLAP_CAP do
        local x = table.remove(stack)
        visited = visited + 1
        local ok, err = pcall(visit, x)
        if not ok then errors = errors + 1; warnOnce("overlap visit", err) end
    end

    say("OVERLAP check (%s) ours=%s screen=(%.0fx%.0f) roots=HUD canvas + %s top-level widget(s) via %s", label, rectStr(mine), sw, sh, tostring(tops), tostring(via))
    for i = 1, math.min(#hits, OVERLAP_LINES) do
        local h = hits[i]
        say("OVERLAP %s class=%s rect=%s visibility=%s", h.path, h.cls, rectStr(h.rect), h.vis)
    end
    -- Context, not overlaps: the other drawn widgets in the screen's top-right quarter (short names).
    for i = 1, math.min(#near, NEAR_LINES) do
        local h = near[i]
        say("OVERLAP near %s class=%s rect=%s visibility=%s", h.path:match("[^%.:]+$") or h.path, h.cls, rectStr(h.rect), h.vis)
    end
    local extra = string.format(", %d drawn on screen, %d of them in the top-right quarter%s%s%s%s", drawn, quadrant,
        full > 0 and (", " .. full .. " full-screen skipped") or "",
        errors > 0 and (", " .. errors .. " error(s)") or "",
        #stack > 0 and (", capped at " .. OVERLAP_CAP) or "",
        #hits > OVERLAP_LINES and (", only " .. OVERLAP_LINES .. " listed") or "")
    if #hits == 0 then say("OVERLAP none (checked %d widgets%s; %s)", visited, extra, label)
    else say("OVERLAP found %d (checked %d widgets%s; %s)", #hits, visited, extra, label) end
end

local function manualTick()
    M.tick = M.tick + 1
    local hud, nLive = liveHud()
    if not hud then
        if M.hudPath then say("HUD gone from the viewport (was %s); waiting for a live HUD", M.hudPath) end
        M.hudPath, M.cand, M.reports = nil, nil, {}
        return
    end
    local path = pathOf(hud)
    if path ~= M.hudPath then
        -- A new, replaced or returning HUD: attach on the second tick that sees it, so a HUD the game replaces
        -- right away is skipped.
        if M.cand ~= path then M.cand = path return end
        M.cand = nil
        local reason = (M.hudPath and ("HUD replaced (was " .. M.hudPath .. ")"))
            or (path == M.lastHudPath and "HUD back in the viewport") or "HUD appeared"
        attach(hud, nLive, reason)
        return
    end
    M.cand = nil
    local canvas = hud.OwningCanvas
    if valid(canvas) and not oursIn(canvas) then attach(hud, nLive, "our widget left the HUD canvas") return end
    local vis, shown = hudVis(hud)
    if shown ~= M.hudShown then
        M.hudShown = shown
        say("HUD %s now (visibility=%s, %s, attach %d)", shown and "visible" or "hidden", VIS[vis] or tostring(vis), path, M.count)
        M.reports = shown and scheduleReports("shown at attach " .. M.count) or {}
    end
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
    say("MANUAL hand-testing mode: no travel, no keys, no timed checks; keeps '%s<n>' in the live HUD's top-right corner", MANUAL_PREFIX)
    local queued = false
    LoopAsync(MANUAL_TICK_MS, function()
        if not queued then
            queued = true
            local okE, errE = pcall(ExecuteInGameThread, function()
                local ok, err = pcall(manualTick)
                if not ok then warnOnce("tick", err) end
                queued = false
            end)
            if not okE then queued = false; warnOnce("scheduling", errE) end
        end
        return false
    end)
end

client.connect{
    mod = ME, need = NEED,
    onReady = function(api)
        core = api
        if SCENARIO == "manual" then startManual() return end
        if SCENARIO == "bad-input" then buildBadInput() else buildSkeleton() end
        LoopAsync(250, function()
            ExecuteInGameThread(tick)
            return finished
        end)
    end,
    onFail = function(msg)
        -- client.connect has already logged the one-line reason.
        if SCENARIO ~= "manual" then say("END result=FAIL checks=0 failures=1 reason=connect") end
    end,
}
say("LOADED main.lua done; waiting for connect")
