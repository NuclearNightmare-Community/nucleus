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
-- bad-input: menu -> SmallMap?listen; calls every public native, the channel, connect's need, core.has and every core.ui function with bad
--            values (bad-input cases below), on and off the game thread and before connect, and checks each answer
--            against the contract. The objectives natives (map service story 3) also run for real on a manager the
--            test spawns on the host, and the forced missing struct member through core's test-only DLL
--            (test/SkelNative). The map setup signal (<core>.map.setup, map service story 9) is read during main.lua,
--            in the menu and in the stock match: "none" each time.
-- ui:        the UI helpers (stories 7-10) unattended: menu -> match -> (RemoveAllWidgets and re-add) -> menu -> match,
--            with elements created before the first match, same id twice, set and its no-op, long text, remove, style,
--            setVisible, all four corners and gaps, offset, absolute, a three-element stack, near the crosshair with
--            HideCrosshair, an element moved onto the crosshair reporting it (story 12 AC 2), a late and a throwing
--            watcher, and handles freed across map changes (buildUi below).
-- ui also runs story 15 at its end: on the Journal (map opened by the real key), a panel with two buttons and a text,
--            real OS clicks on each (run.ps1 "click x y"), Enter on a focused button, a throwing onClick, a disabled
--            button, a button of a second test dependent (<Core>SkelPeer), and two calls in a row (the 250 ms debounce).
-- manual:    for hand testing. Never travels, requests keys, runs timed checks or logs FAIL. Keeps a
--            "<Core> manual: <n>" element in the top-right corner of the HUD through core.ui.text (core re-attaches it
--            whenever the HUD is rebuilt, replaced or put back in the viewport; n counts attaches), and logs reports
--            (core.ui.debug.overlaps) of the drawn widgets its on-screen rectangle overlaps.
-- Keys it can't press itself (Enter for touchdown) go to run.ps1 through request.txt / done.txt next to this file.
-- Never keeps a UObject across steps: only paths, addresses (as integers, never dereferenced) and weak handles.
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local ME = scriptDir:match("([^/\\]+)[/\\][Ss]cripts$")
local CORE = ME:match("^(.-)SkelTest$") -- the one place the core's name comes from: this folder's name
local NEED = ">=0.5.0" -- core.has and core.features (story 18); any core at or above it, down to core's floor

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
    try("pre-journal-watch", "ui.journal.watch(fn) [before connect]", "journal", "watch", function() end)
    try("pre-journal-isopen", "ui.journal.isOpen() [before connect]", "journal", "isOpen")
    try("pre-panel-create", "ui.panel.create{ id = 'early' } [before connect]", "panel", "create", { id = "early" })
    try("pre-panel-move", "ui.panel.move({}, {}, 1) [before connect]", "panel", "move", {}, {}, 1)
    try("pre-button-create", "ui.button.create{ id = 'early' } [before connect]", "button", "create", { id = "early" })
end
-- Core story 31: the game-screen functions before connect (bad-input and createserver; reported by gamescreen.lua).
-- In a field of PRE_CONNECT: main.lua is at the 200-locals limit.
if SCENARIO == "bad-input" or SCENARIO == "createserver" then
    PRE_CONNECT.game = {}
    local okM, m = pcall(require, CORE:lower() .. ".ui.game")
    for _, c in ipairs({ { "pre-game-watch", "watch", "createServer", function() end }, { "pre-game-unwatch", "unwatch", 1 }, { "pre-game-isopen", "isOpen", "createServer" } }) do
        local r = okM and table.pack(pcall(m[c[2]], c[3], c[4])) or { false, "require failed: " .. tostring(m) }
        PRE_CONNECT.game[#PRE_CONNECT.game + 1] = { id = c[1], fn = c[2], ok = r[1], err = r[2] }
    end
end

-- 4. The objectives natives called during main.lua, before the first engine tick (bad-input): allowed, so each must
-- get as far as the lookup and fail there cleanly ("no object at ..."). Reported as cases once the scenario runs.
local PRE_NATIVE = {}
if SCENARIO == "bad-input" then
    local missing = "/Game/NoSuch/NNNoManager.NNNoManager"
    local function try(id, desc, suffix, ...)
        local fn = _G[CORE .. suffix]
        if type(fn) ~= "function" then PRE_NATIVE[#PRE_NATIVE + 1] = { id = id, desc = desc, ok = false, err = CORE .. suffix .. " is missing" } return end
        local r = table.pack(pcall(fn, ...))
        PRE_NATIVE[#PRE_NATIVE + 1] = { id = id, desc = desc, ok = r[1], err = r[2], name = CORE .. suffix }
    end
    try("pre-obj-set", CORE .. "_SetObjectives(<missing>, area, id, text) [main.lua]", "_SetObjectives", missing, "A", "a", "t")
    try("pre-obj-desc", CORE .. "_DescribeObjectives(<missing>) [main.lua]", "_DescribeObjectives", missing)
    try("pre-obj-trait", CORE .. "_SetTraitorTaskState(<missing>, id, true) [main.lua]", "_SetTraitorTaskState", missing, "a", true)
end

-- 5. The map setup signal (map service story 9) read during main.lua: core's main.lua (first in mods.txt) publishes
-- "none" before any world exists. Read-only: the signal takes no input. Reported as a case once the scenario runs.
local SETUP_KEY = CORE:lower() .. ".map.setup"
local function readSignal()
    local okS, v = pcall(function() return ModRef:GetSharedVariable(SETUP_KEY) end)
    if not okS then error("GetSharedVariable(" .. SETUP_KEY .. ") threw: " .. tostring(v):match("^[^\n]*"), 0) end
    return v
end
local PRE_SIGNAL
if SCENARIO == "bad-input" then PRE_SIGNAL = table.pack(pcall(readSignal)) end

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
-- The map setup signal (map service story 9) outside a map with core's Start marker: exactly the string "none".
E.signalNone = { what = "exactly the string 'none'", test = function(ok, r) return ok and r.n == 1 and type(r[1]) == "string" and r[1] == "none" end }
-- client.call: false plus a reply starting with prefix.
function E.callErr(prefix) return { what = "false, '" .. prefix .. "...'", test = function(ok, r) return ok and r[1] == false and type(r[2]) == "string" and r[2]:sub(1, #prefix) == prefix end } end

local cases = { total = 0, passed = 0 }
local uiOffThreadCases -- defined with the UI cases below
local panelCases -- story 14, defined with the UI cases below
local buttonCases -- story 15, defined with the UI cases below
local objectivesOffThreadCases -- map service story 3, defined with the objectives cases below
local SETS = {} -- Mod Manager story 5: the settings cases (one table: main.lua is at the 200-locals limit)
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
    case(P .. "ch-version", "call(\"version\") [control]", function() return core.call("version") end, E.ret("true, version", function(r) return r[1] == true and r[2] == core.version end))
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
                objectivesOffThreadCases(P)
                SETS.offThread(P)
                SETS.NET.offThread(P) -- core story 22
                SETS.PRES.offThread(P) -- core story 23
                SETS.GAME.offThread(P) -- core story 31
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

-- Story 14: panels with bad values (AC 5), on the game thread. Every element made here is removed again.
local PANEL_CASE_IDS = {}
panelCases = function(P, f, okRet)
    local U, T, PN = core.ui, core.ui.text, core.ui.panel
    local UI = CORE:lower() .. ".ui"
    local function pcase(id, desc, fn, expect) PANEL_CASE_IDS[#PANEL_CASE_IDS + 1] = id; case(P .. id, desc, fn, expect) end
    local PC, PL = UI .. ".panel.create: ", UI .. ".place: "
    local away = function(y) return { absolute = { anchor = "center", x = 0, y = y } } end
    pcase("panel-create-none", "ui.panel.create()", f(PN.create), E.err(PC .. "expected a table"))
    pcase("panel-create-unknown", "ui.panel.create{ id = 'bp', lay = 'x' }", f(PN.create, { id = "bp", lay = "x" }), E.err(PC .. "unknown key 'lay' (valid: gap, id, layout, place, style)"))
    pcase("panel-create-noid", "ui.panel.create{}", f(PN.create, {}), E.err(PC .. "id must be a string, got nil"))
    pcase("panel-layout-grid", "ui.panel.create{ layout = 'grid' }", f(PN.create, { id = "bp", layout = "grid" }), E.err(PC .. "unknown layout 'grid' (valid: vertical, horizontal)"))
    pcase("panel-layout-num", "ui.panel.create{ layout = 1 }", f(PN.create, { id = "bp", layout = 1 }), E.err(PC .. "unknown layout 1"))
    pcase("panel-gap-3", "ui.panel.create{ gap = 3 }", f(PN.create, { id = "bp", gap = 3 }), E.err(PC .. "unknown gap 3 (valid: tight, normal, loose)"))
    pcase("panel-gap-huge", "ui.panel.create{ gap = 'huge' }", f(PN.create, { id = "bp", gap = "huge" }), E.err(PC .. "unknown gap 'huge'"))
    pcase("panel-place-str", "ui.panel.create{ place = 'top-right' }", f(PN.create, { id = "bp", place = "top-right" }), E.err(PC .. "place must be a table or nil, got 'top-right'"))
    pcase("panel-style-purple", "ui.panel.create{ style = { background = 'purple' } }", f(PN.create, { id = "bp", style = { background = "purple" } }), E.err(UI .. ".panel: unknown background 'purple'"))
    local pa, pb
    pcase("panel-create-ok", "ui.panel.create{ id = 'bpa' } [control]", function()
        pa = PN.create{ id = "bpa", place = away(140) }
        return pa
    end, E.ret("a handle { id = 'bpa' }", function(r) return type(r[1]) == "table" and r[1].id == "bpa" end))
    if not pa then return end
    pcase("panel-in-panel", "ui.panel.create{ place = { panel = <panel> } }", f(PN.create, { id = "bp", place = { panel = pa } }), E.err(PC .. "a panel can't go inside a panel (one level only)"))
    pb = PN.create{ id = "bpb", place = away(180), layout = "horizontal" }
    pcase("panel-place-in-panel", "ui.place(<panel>, { panel = <panel> })", f(U.place, pa, { panel = pb }), E.err(PL .. "a panel can't go inside a panel (one level only)"))
    local k = {}
    for i = 1, 3 do k[i] = T.create{ id = "bk" .. i, text = "k" .. i, place = { panel = pa } } end
    local o1 = T.create{ id = "bo1", text = "o", place = { panel = pb } }
    local kx = T.create{ id = "bkx", text = "x", place = { panel = pa } }
    T.remove(kx)
    -- the panel in an intent
    pcase("panel-child-num", "ui.text.create{ place = { panel = 5 } }", f(T.create, { id = "bc", place = { panel = 5 } }), E.err(PL .. "panel must be a panel handle, got 5"))
    pcase("panel-child-str", "ui.text.create{ place = { panel = 'bpa' } }", f(T.create, { id = "bc", place = { panel = "bpa" } }), E.err(PL .. "panel must be a panel handle, got 'bpa'"))
    pcase("panel-child-forged", "ui.text.create{ place = { panel = { id = 'bpa' } } } [forged]", f(T.create, { id = "bc", place = { panel = { id = "bpa" } } }), E.err(PL .. "panel is not a panel handle"))
    pcase("panel-child-text", "ui.text.create{ place = { panel = <text handle> } }", f(T.create, { id = "bc", place = { panel = k[1] } }), E.err(PL .. "panel is a text element ('bk1'), not a panel"))
    pcase("panel-child-corner", "ui.text.create{ place = { panel = <panel>, corner = 'top-left' } }", f(T.create, { id = "bc", place = { panel = pa, corner = "top-left" } }), E.err(PL .. "corner is not allowed with panel"))
    -- the 33rd child
    pcase("panel-child-33", "ui.text.create{ place = { panel = <panel with 32 children> } } [the 33rd]", function()
        local made = {}
        for i = 1, 29 do made[i] = T.create{ id = "bm" .. i, text = "m", place = { panel = pa } } end
        local ok, err = pcall(T.create, { id = "bm30", text = "m", place = { panel = pa } })
        for _, m in ipairs(made) do T.remove(m) end
        if not ok then error(err, 0) end
    end, E.err(PL .. "panel 'bpa' already has 32 children (at most 32)"))
    -- every panel function with handles that aren't panels
    local forged = { id = "bpa" }
    local fns = {
        { "setstyle", "panel.setStyle", PN.setStyle, nil }, { "setvis", "panel.setVisible", PN.setVisible, true },
        { "remove", "panel.remove", PN.remove, nil }, { "isshown", "panel.isShown", PN.isShown, nil },
        { "order", "panel.order", PN.order, nil }, { "setorder", "panel.setOrder", PN.setOrder, {} }, { "move", "panel.move", PN.move, k[1] },
    }
    for _, d in ipairs(fns) do
        local key, name, fn, arg = d[1], d[2], d[3], d[4]
        local pre = UI .. "." .. name .. ": "
        pcase("panel-" .. key .. "-h-nil", "ui." .. name .. "(nil, ...)", f(fn, nil, arg), E.err(pre .. "expected a panel handle, got nil"))
        pcase("panel-" .. key .. "-h-num", "ui." .. name .. "(42, ...)", f(fn, 42, arg), E.err(pre .. "expected a panel handle, got 42"))
        pcase("panel-" .. key .. "-h-forged", "ui." .. name .. "({ id = 'bpa' }, ...) [forged]", f(fn, forged, arg), E.err(pre .. "not a panel handle"))
        pcase("panel-" .. key .. "-h-text", "ui." .. name .. "(<text handle>, ...)", f(fn, k[1], arg), E.err(pre .. "not a panel handle ('bk1' is a text element)"))
    end
    pcase("panel-setvis-yes", "ui.panel.setVisible(p, 'yes')", f(PN.setVisible, pa, "yes"), E.err(UI .. ".panel.setVisible: visible must be a boolean, got string"))
    pcase("panel-setstyle-str", "ui.panel.setStyle(p, 'dim')", f(PN.setStyle, pa, "dim"), E.err(UI .. ".panel: style must be a table"))
    pcase("text-set-on-panel", "ui.text.set(<panel handle>, 'x')", f(T.set, pa, "x"), E.err(UI .. ".text.set: not a text element handle ('bpa' is a panel)"))
    pcase("panel-id-taken", "ui.text.create{ id = 'bpa' } [a panel's id]", f(T.create, { id = "bpa" }), E.err(UI .. ".text.create: id 'bpa' is already a panel of this mod"))
    -- reorder (AC 5): each refused, the order unchanged
    local SO, MV = UI .. ".panel.setOrder: ", UI .. ".panel.move: "
    pcase("panel-setorder-missing", "ui.panel.setOrder(p, { k2, k1 }) [a child missing]", f(PN.setOrder, pa, { k[2], k[1] }), E.err(SO .. "order has 2 handle(s) but panel 'bpa' has 3 child(ren)"))
    pcase("panel-setorder-dup", "ui.panel.setOrder(p, { k2, k1, k1 }) [a duplicate]", f(PN.setOrder, pa, { k[2], k[1], k[1] }), E.err(SO .. "order[3] ('bk1') appears twice"))
    pcase("panel-setorder-other", "ui.panel.setOrder(p, { k2, k1, <another panel's child> })", f(PN.setOrder, pa, { k[2], k[1], o1 }), E.err(SO .. "order[3] ('bo1') is not a child of panel 'bpa'"))
    pcase("panel-setorder-removed", "ui.panel.setOrder(p, { k2, k1, <removed child> })", f(PN.setOrder, pa, { k[2], k[1], kx }), E.err(SO .. "order[3]: handle 'bkx' was removed"))
    pcase("panel-setorder-nonhandle", "ui.panel.setOrder(p, { k2, k1, 5 })", f(PN.setOrder, pa, { k[2], k[1], 5 }), E.err(SO .. "order[3] is not a child handle, got 5"))
    pcase("panel-setorder-forged", "ui.panel.setOrder(p, { k2, k1, { id = 'bk3' } }) [forged]", f(PN.setOrder, pa, { k[2], k[1], { id = "bk3" } }), E.err(SO .. "order[3] is not an element handle"))
    pcase("panel-setorder-nontable", "ui.panel.setOrder(p, 'bk1,bk2,bk3')", f(PN.setOrder, pa, "bk1,bk2,bk3"), E.err(SO .. "order must be a table of the panel's child handles, got 'bk1,bk2,bk3'"))
    pcase("panel-setorder-nil", "ui.panel.setOrder(p, nil)", f(PN.setOrder, pa, nil), E.err(SO .. "order must be a table of the panel's child handles, got nil"))
    pcase("panel-setorder-holes", "ui.panel.setOrder(p, { k2, k1, k3, x = 1 })", f(PN.setOrder, pa, { k[2], k[1], k[3], x = 1 }), E.err(SO .. "order must be a list (keys 1 to n), got key 'x'"))
    pcase("panel-setorder-two", "ui.panel.setOrder(p, order, 1)", f(PN.setOrder, pa, { k[1], k[2], k[3] }, 1), E.err(SO .. "expected 2 arguments (handle, order), got 3"))
    pcase("panel-move-0", "ui.panel.move(p, k1, 0)", f(PN.move, pa, k[1], 0), E.err(MV .. "index 0 is out of range (1 to 3)"))
    pcase("panel-move-n1", "ui.panel.move(p, k1, 4) [count + 1]", f(PN.move, pa, k[1], 4), E.err(MV .. "index 4 is out of range (1 to 3)"))
    pcase("panel-move-float", "ui.panel.move(p, k1, 1.5)", f(PN.move, pa, k[1], 1.5), E.err(MV .. "index must be an integer from 1 to 3, got 1.5"))
    pcase("panel-move-str", "ui.panel.move(p, k1, '1')", f(PN.move, pa, k[1], "1"), E.err(MV .. "index must be an integer from 1 to 3, got '1'"))
    pcase("panel-move-nil", "ui.panel.move(p, k1, nil)", f(PN.move, pa, k[1], nil), E.err(MV .. "index must be an integer from 1 to 3, got nil"))
    pcase("panel-move-other", "ui.panel.move(p, <another panel's child>, 1)", f(PN.move, pa, o1, 1), E.err(MV .. "'bo1' is not a child of panel 'bpa'"))
    pcase("panel-move-removed", "ui.panel.move(p, <removed child>, 1)", f(PN.move, pa, kx, 1), E.err(UI .. ".text: handle 'bkx' was removed"))
    pcase("panel-move-forged", "ui.panel.move(p, { id = 'bk1' }, 1) [forged child]", f(PN.move, pa, { id = "bk1" }, 1), E.err(MV .. "not an element handle"))
    pcase("panel-order-unchanged", "ui.panel.order(p) [control: every refused call left the order]", f(PN.order, pa),
        E.ret("{ bk1, bk2, bk3 }", function(r) local o = r[1] return type(o) == "table" and #o == 3 and rawequal(o[1], k[1]) and rawequal(o[2], k[2]) and rawequal(o[3], k[3]) end))
    pcase("panel-move-ok", "ui.panel.move(p, k3, 1) [control]", f(PN.move, pa, k[3], 1), E.none)
    pcase("panel-setorder-ok", "ui.panel.setOrder(p, { k1, k2, k3 }) [control]", f(PN.setOrder, pa, { k[1], k[2], k[3] }), E.none)
    pcase("panel-order-arg", "ui.panel.order(p, 1)", f(PN.order, pa, 1), E.err(UI .. ".panel.order: expected 1 argument (handle), got 2"))
    -- removing the panel removes its children; their handles and the panel's raise
    pcase("panel-remove-ok", "ui.panel.remove(p) [control]", f(PN.remove, pa), E.none)
    pcase("panel-remove-again", "ui.panel.remove(p) [again]", f(PN.remove, pa), E.none)
    pcase("panel-removed-child", "ui.text.set(<child of a removed panel>, 'x')", f(T.set, k[2], "x"), E.err(UI .. ".text: handle 'bk2' was removed"))
    pcase("panel-removed-order", "ui.panel.order(<removed>)", f(PN.order, pa), E.err(UI .. ".panel: handle 'bpa' was removed"))
    pcase("panel-removed-intent", "ui.text.create{ place = { panel = <removed panel> } }", f(T.create, { id = "bc", place = { panel = pa } }), E.err(UI .. ".panel: handle 'bpa' was removed"))
    PN.remove(pb)
end

-- Story 15: buttons with bad values (AC 7), on the game thread. Every element made here is removed again.
buttonCases = function(P, f)
    local U, T, PN, B = core.ui, core.ui.text, core.ui.panel, core.ui.button
    local UI = CORE:lower() .. ".ui"
    local BC = UI .. ".button.create: "
    local jp = { host = "journal", corner = "top-left" }
    local nop = function() end
    case(P .. "button-create-none", "ui.button.create()", f(B.create), E.err(BC .. "expected a table"))
    case(P .. "button-create-unknown", "ui.button.create{ ..., colour = 1 }", f(B.create, { id = "bb", onClick = nop, place = jp, colour = 1 }), E.err(BC .. "unknown key 'colour' (valid: dimmed, enabled, icon, iconSize, id, label, onClick, place, style, tooltip)"))
    case(P .. "button-create-noid", "ui.button.create{ onClick = fn }", f(B.create, { onClick = nop, place = jp }), E.err(BC .. "id must be a string, got nil"))
    case(P .. "button-onclick-missing", "ui.button.create{ id, label, place } [no onClick]", f(B.create, { id = "bb", label = "x", place = jp }), E.err(BC .. "onClick must be a function, got nil"))
    case(P .. "button-onclick-str", "ui.button.create{ onClick = 'f' }", f(B.create, { id = "bb", label = "x", place = jp, onClick = "f" }), E.err(BC .. "onClick must be a function, got 'f'"))
    case(P .. "button-onclick-num", "ui.button.create{ onClick = 1 }", f(B.create, { id = "bb", label = "x", place = jp, onClick = 1 }), E.err(BC .. "onClick must be a function, got 1"))
    case(P .. "button-onclick-table", "ui.button.create{ onClick = {} }", f(B.create, { id = "bb", label = "x", place = jp, onClick = {} }), E.err(BC .. "onClick must be a function, got table"))
    case(P .. "button-label-table", "ui.button.create{ label = {} }", f(B.create, { id = "bb", label = {}, place = jp, onClick = nop }), E.err(BC .. "label must be a string, a number or nil, got table"))
    case(P .. "button-label-bool", "ui.button.create{ label = true }", f(B.create, { id = "bb", label = true, place = jp, onClick = nop }), E.err(BC .. "label must be a string, a number or nil, got boolean"))
    case(P .. "button-label-65", "ui.button.create{ label = <65 chars> }", f(B.create, { id = "bb", label = string.rep("x", 65), place = jp, onClick = nop }), E.err(BC .. "label is 65 characters, at most 64"))
    case(P .. "button-host-hud", "ui.button.create{ place = { host = 'hud', corner = 'top-left' } }", f(B.create, { id = "bb", label = "x", place = { host = "hud", corner = "top-left" }, onClick = nop }),
        E.err(BC .. "buttons need a host with a cursor (journal, menu, screen); see input mode, story 16"))
    case(P .. "button-host-default", "ui.button.create{ no place: the HUD }", f(B.create, { id = "bb", label = "x", onClick = nop }), E.err(BC .. "buttons need a host with a cursor (journal, menu, screen)"))
    case(P .. "button-enabled-yes", "ui.button.create{ enabled = 'yes' }", f(B.create, { id = "bb", label = "x", place = jp, onClick = nop, enabled = "yes" }), E.err(BC .. "enabled must be a boolean or nil, got 'yes'"))
    case(P .. "button-enabled-num", "ui.button.create{ enabled = 1 }", f(B.create, { id = "bb", label = "x", place = jp, onClick = nop, enabled = 1 }), E.err(BC .. "enabled must be a boolean or nil, got 1"))
    case(P .. "button-style-pink", "ui.button.create{ style = { background = 'pink' } }", f(B.create, { id = "bb", label = "x", place = jp, onClick = nop, style = { background = "pink" } }), E.err(UI .. ".button: unknown background 'pink'"))
    case(P .. "button-place-str", "ui.button.create{ place = 'journal' }", f(B.create, { id = "bb", label = "x", place = "journal", onClick = nop }), E.err(BC .. "place must be a table or nil, got 'journal'"))
    local hp = PN.create{ id = "bhp", place = { absolute = { anchor = "center", x = 0, y = 220 } } }
    case(P .. "button-in-hud-panel", "ui.button.create{ place = { panel = <panel on the HUD> } }", f(B.create, { id = "bb", label = "x", place = { panel = hp }, onClick = nop }), E.err(BC .. "buttons need a host with a cursor (journal, menu, screen)"))
    PN.remove(hp)
    local bb
    case(P .. "button-create-ok", "ui.button.create{ id = 'bb', place = journal } [control: pending on the closed Journal]", function()
        bb = B.create{ id = "bb", label = string.rep("y", 64), place = jp, onClick = nop }
        return bb
    end, E.ret("a handle { id = 'bb' }", function(r) return type(r[1]) == "table" and r[1].id == "bb" end))
    if not bb then return end
    case(P .. "button-isshown-closed", "ui.button.isShown(b) [control: the Journal is closed]", f(B.isShown, bb), E.ret("false", function(r) return r[1] == false end))
    case(P .. "button-place-hud", "ui.place(b, { host = 'hud', corner = 'top-left' })", f(U.place, bb, { host = "hud", corner = "top-left" }), E.err(UI .. ".place: buttons need a host with a cursor (journal, menu, screen)"))
    local jpan = PN.create{ id = "bjp", place = { host = "journal", corner = "bottom-left" } }
    B.create{ id = "bb2", label = "z", place = { panel = jpan }, onClick = nop }
    case(P .. "button-panel-to-hud", "ui.place(<panel holding a button>, { host = 'hud', ... })", f(U.place, jpan, { host = "hud", corner = "top-left" }),
        E.err(UI .. ".place: panel 'bjp' holds buttons, which need a host with a cursor (journal, menu, screen); see input mode, story 16"))
    PN.remove(jpan)
    case(P .. "button-setlabel-table", "ui.button.setLabel(b, {})", f(B.setLabel, bb, {}), E.err(UI .. ".button.setLabel: label must be a string, a number or nil, got table"))
    case(P .. "button-setlabel-65", "ui.button.setLabel(b, <65 chars>)", f(B.setLabel, bb, string.rep("z", 65)), E.err(UI .. ".button.setLabel: label is 65 characters, at most 64"))
    case(P .. "button-setenabled-yes", "ui.button.setEnabled(b, 'yes')", f(B.setEnabled, bb, "yes"), E.err(UI .. ".button.setEnabled: enabled must be a boolean, got 'yes'"))
    case(P .. "button-setenabled-nil", "ui.button.setEnabled(b)", f(B.setEnabled, bb), E.err(UI .. ".button.setEnabled: enabled must be a boolean, got nil"))
    case(P .. "button-setvis-1", "ui.button.setVisible(b, 1)", f(B.setVisible, bb, 1), E.err(UI .. ".button.setVisible: visible must be a boolean, got number"))
    local th = T.create{ id = "btx", text = "t", place = { absolute = { anchor = "center", x = 0, y = 240 } } }
    local fns = { { "setlabel", "button.setLabel", B.setLabel, "x" }, { "setenabled", "button.setEnabled", B.setEnabled, true },
        { "setvis", "button.setVisible", B.setVisible, true }, { "remove", "button.remove", B.remove, nil }, { "isshown", "button.isShown", B.isShown, nil } }
    for _, d in ipairs(fns) do
        local key, name, fn, arg = d[1], d[2], d[3], d[4]
        local pre = UI .. "." .. name .. ": "
        case(P .. "button-" .. key .. "-h-nil", "ui." .. name .. "(nil, ...)", f(fn, nil, arg), E.err(pre .. "expected a button handle, got nil"))
        case(P .. "button-" .. key .. "-h-num", "ui." .. name .. "(42, ...)", f(fn, 42, arg), E.err(pre .. "expected a button handle, got 42"))
        case(P .. "button-" .. key .. "-h-forged", "ui." .. name .. "({ id = 'bb' }, ...) [forged]", f(fn, { id = "bb" }, arg), E.err(pre .. "not a button handle"))
        case(P .. "button-" .. key .. "-h-text", "ui." .. name .. "(<text handle>, ...)", f(fn, th, arg), E.err(pre .. "not a button handle ('btx' is a text element)"))
    end
    T.remove(th)
    case(P .. "button-remove-ok", "ui.button.remove(b) [control]", f(B.remove, bb), E.none)
    case(P .. "button-remove-again", "ui.button.remove(b) [again]", f(B.remove, bb), E.none)
    case(P .. "button-removed-setlabel", "ui.button.setLabel(<removed>, 'x')", f(B.setLabel, bb, "x"), E.err(UI .. ".button: handle 'bb' was removed"))
    case(P .. "button-removed-isshown", "ui.button.isShown(<removed>)", f(B.isShown, bb), E.err(UI .. ".button: handle 'bb' was removed"))
    case(P .. "button-stats", "ui.button.stats() [control]", f(B.stats), E.ret("a table, hooked", function(r) return type(r[1]) == "table" and r[1].hooked == true and r[1].hookTries == 1 end))
end

-- Story 21 (Mod Manager story 2, core 0.7.0): the menu entry, the menu and screen hosts, lists, rows and the game look
-- with bad values, on the game thread. The title-screen menu is not open in either world of this scenario (menu1 is
-- the startup screen, match1 a match), so screen.open refuses everywhere here; its successful paths (and the ninth
-- window) run in the menu scenario. Containers are made on the closed Journal (no widgets). Everything made is removed.
local MM_CASE_IDS = {}
local function mmCases(P, f)
    local U = core.ui
    local UI = CORE:lower() .. ".ui"
    local nop = function() end
    local function mcase(id, desc, fn, expect) MM_CASE_IDS[#MM_CASE_IDS + 1] = id; case(P .. id, desc, fn, expect) end
    local ME_ = UI .. ".menu.entry: "
    local L = { en = "SKEL BAD" }
    local NIL = {}
    local function entry(over)
        local o = { id = "be", label = L, onClick = nop }
        for k, v in pairs(over) do if v == NIL then o[k] = nil else o[k] = v end end
        return f(U.menu.entry, o)
    end
    -- menu.entry: the argument, keys, id, label, onClick
    mcase("mm-entry-none", "ui.menu.entry()", f(U.menu.entry), E.err(ME_ .. "expected a table { id = ..., label = ..., onClick = ..., style = ... }, got nil"))
    mcase("mm-entry-str", "ui.menu.entry('x')", f(U.menu.entry, "x"), E.err(ME_ .. "expected a table { id = ..., label = ..., onClick = ..., style = ... }, got 'x'"))
    mcase("mm-entry-unknown", "ui.menu.entry{ ..., place = {} }", entry({ place = {} }), E.err(ME_ .. "unknown key 'place' (valid: id, label, onClick, style)"))
    mcase("mm-entry-noid", "ui.menu.entry{ no id }", entry({ id = NIL }), E.err(ME_ .. "id must be a string, got nil"))
    mcase("mm-entry-space", "ui.menu.entry{ id = 'a b' }", entry({ id = "a b" }), E.err(ME_ .. "id 'a b' has characters outside A-Z a-z 0-9 _ . -"))
    mcase("mm-entry-65", "ui.menu.entry{ id = <65 chars> }", entry({ id = string.rep("e", 65) }), E.err(ME_ .. "id is 65 characters, at most 64"))
    local LB = 'label must be a table of strings by language, like { en = "MANAGE MODS" }, got '
    mcase("mm-label-nil", "ui.menu.entry{ no label }", entry({ label = NIL }), E.err(ME_ .. LB .. "nil"))
    mcase("mm-label-str", "ui.menu.entry{ label = 'MODS' }", entry({ label = "MODS" }), E.err(ME_ .. LB .. "'MODS'"))
    mcase("mm-label-noen", "ui.menu.entry{ label = { es = 'MODS' } }", entry({ label = { es = "MODS" } }), E.err(ME_ .. "label needs an en string (the fallback)"))
    mcase("mm-label-lower", "ui.menu.entry{ label = { en = 'Manage Mods' } }", entry({ label = { en = "Manage Mods" } }), E.err(ME_ .. "label.en must be upper case like the menu's own labels, got 'Manage Mods'"))
    local many = { en = "MODS" }
    for i = 1, 16 do many["l" .. string.char(96 + i)] = "X" end
    mcase("mm-label-17", "ui.menu.entry{ label = <17 languages> }", entry({ label = many }), E.err(ME_ .. "label has 17 languages, at most 16"))
    mcase("mm-label-empty", "ui.menu.entry{ label = { en = '' } }", entry({ label = { en = "" } }), E.err(ME_ .. "label.en must be a string of 1 to 64 bytes, got ''"))
    mcase("mm-label-65", "ui.menu.entry{ label = { en = <65 bytes> } }", entry({ label = { en = string.rep("M", 65) } }), E.err(ME_ .. "label.en must be a string of 1 to 64 bytes"))
    mcase("mm-label-num", "ui.menu.entry{ label = { en = 'MODS', es = 5 } }", entry({ label = { en = "MODS", es = 5 } }), E.err(ME_ .. "label.es must be a string of 1 to 64 bytes, got 5"))
    mcase("mm-label-key-digit", "ui.menu.entry{ label = { en = 'MODS', zh1 = 'X' } }", entry({ label = { en = "MODS", zh1 = "X" } }), E.err(ME_ .. "label key 'zh1' is not a language tag (letters and -, at most 16 characters)"))
    mcase("mm-label-key-long", "ui.menu.entry{ label = { en = 'MODS', <17-letter key> = 'X' } }", entry({ label = { en = "MODS", [string.rep("a", 17)] = "X" } }), E.err(ME_ .. "label key '" .. string.rep("a", 17) .. "' is not a language tag"))
    mcase("mm-label-key-num", "ui.menu.entry{ label = { en = 'MODS', [1] = 'X' } }", entry({ label = { en = "MODS", [1] = "X" } }), E.err(ME_ .. "label key 1 is not a language tag"))
    mcase("mm-onclick-nil", "ui.menu.entry{ no onClick }", entry({ onClick = NIL }), E.err(ME_ .. "onClick must be a function, got nil"))
    mcase("mm-onclick-str", "ui.menu.entry{ onClick = 'f' }", entry({ onClick = "f" }), E.err(ME_ .. "onClick must be a function, got 'f'"))
    -- style: presets and the bounded overrides
    mcase("mm-style-preset", "ui.menu.entry{ style = 'big' }", entry({ style = "big" }), E.err(ME_ .. "unknown style preset 'big' (valid: options, primary)"))
    mcase("mm-style-num", "ui.menu.entry{ style = 5 }", entry({ style = 5 }), E.err(ME_ .. "style must be a preset name or a table { preset = ..., ... }, got 5"))
    mcase("mm-style-tpreset", "ui.menu.entry{ style = { preset = 'big' } }", entry({ style = { preset = "big" } }), E.err(ME_ .. "unknown style preset 'big' (valid: options, primary)"))
    mcase("mm-style-key", "ui.menu.entry{ style = { size = 26 } }", entry({ style = { size = 26 } }), E.err(ME_ .. "unknown style key 'size' (valid: bold, fontSize, hoverColor, italic, preset, textColor)"))
    mcase("mm-style-font-500", "ui.menu.entry{ style = { fontSize = 500 } }", entry({ style = { fontSize = 500 } }), E.err(ME_ .. "style.fontSize must be an integer from 16 to 28, got 500"))
    mcase("mm-style-font-15", "ui.menu.entry{ style = { fontSize = 15 } }", entry({ style = { fontSize = 15 } }), E.err(ME_ .. "style.fontSize must be an integer from 16 to 28, got 15"))
    mcase("mm-style-font-float", "ui.menu.entry{ style = { fontSize = 22.5 } }", entry({ style = { fontSize = 22.5 } }), E.err(ME_ .. "style.fontSize must be an integer from 16 to 28, got 22.5"))
    mcase("mm-style-color-2", "ui.menu.entry{ style = { textColor = { 1, 2, 0, 1 } } }", entry({ style = { textColor = { 1, 2, 0, 1 } } }), E.err(ME_ .. "style.textColor.g must be a number from 0 to 1, got 2"))
    mcase("mm-style-color-str", "ui.menu.entry{ style = { hoverColor = { r = 'x', g = 0, b = 0 } } }", entry({ style = { hoverColor = { r = "x", g = 0, b = 0 } } }), E.err(ME_ .. "style.hoverColor.r must be a number from 0 to 1, got 'x'"))
    mcase("mm-style-bold", "ui.menu.entry{ style = { bold = 'yes' } }", entry({ style = { bold = "yes" } }), E.err(ME_ .. "style.bold must be a boolean, got 'yes'"))
    mcase("mm-style-italic", "ui.menu.entry{ style = { italic = 1 } }", entry({ style = { italic = 1 } }), E.err(ME_ .. "style.italic must be a boolean, got 1"))
    -- one entry per mod; removeEntry
    local e1
    mcase("mm-entry-ok", "ui.menu.entry{ id = 'be', style = { preset = 'options', textColor = { 1, 0.5, 0, 1 }, fontSize = 26 } } [control]", function()
        e1 = U.menu.entry{ id = "be", label = { en = "SKEL BAD", es = "SKEL MALO", ["zh-Hans"] = "SKEL" }, onClick = nop, style = { preset = "options", textColor = { 1, 0.5, 0, 1 }, fontSize = 26 } }
        return e1
    end, E.ret("a handle { id = 'be' }", function(r) return type(r[1]) == "table" and r[1].id == "be" end))
    if e1 then
        mcase("mm-entry-second", "ui.menu.entry{ id = 'be2' } [a second entry]", entry({ id = "be2" }), E.err(ME_ .. "this mod already has a menu entry ('be'); remove it first"))
        local RE = UI .. ".menu.removeEntry: not a menu entry handle (use the handle that menu.entry returned)"
        mcase("mm-remove-nil", "ui.menu.removeEntry(nil)", f(U.menu.removeEntry, nil), E.err(RE))
        mcase("mm-remove-num", "ui.menu.removeEntry(5)", f(U.menu.removeEntry, 5), E.err(RE))
        mcase("mm-remove-forged", "ui.menu.removeEntry({ id = 'be' }) [forged]", f(U.menu.removeEntry, { id = "be" }), E.err(RE))
        mcase("mm-remove-ok", "ui.menu.removeEntry(e) [control]", f(U.menu.removeEntry, e1), E.none)
        mcase("mm-remove-again", "ui.menu.removeEntry(e) [again]", f(U.menu.removeEntry, e1), E.none)
        mcase("mm-entry-after-remove", "ui.menu.entry{ id = 'be3', style = 'primary' } after removeEntry [control]", function()
            local e = U.menu.entry{ id = "be3", label = L, onClick = nop, style = "primary" }
            U.menu.removeEntry(e)
            return e.id
        end, E.ret("'be3'", function(r) return r[1] == "be3" end))
    end
    -- menu.isOpen, watch, unwatch
    local MW = UI .. ".menu."
    mcase("mm-isopen-arg", "ui.menu.isOpen(1)", f(U.menu.isOpen, 1), E.err(MW .. "isOpen: expected 0 arguments, got 1"))
    mcase("mm-isopen-ok", "ui.menu.isOpen() [control: no title-screen menu]", f(U.menu.isOpen), E.ret("false", function(r) return r[1] == false end))
    mcase("mm-watch-nil", "ui.menu.watch(nil)", f(U.menu.watch, nil), E.err(MW .. "watch: fn must be a function, got nil"))
    mcase("mm-watch-str", "ui.menu.watch('x')", f(U.menu.watch, "x"), E.err(MW .. "watch: fn must be a function, got 'x'"))
    mcase("mm-unwatch-forged", "ui.menu.unwatch(2^40)", f(U.menu.unwatch, 1 << 40), E.err(MW .. "unwatch: unknown token 1099511627776 (not one menu.watch returned)"))
    mcase("mm-unwatch-str", "ui.menu.unwatch('x')", f(U.menu.unwatch, "x"), E.err(MW .. "unwatch: token must be an integer, got 'x'"))
    mcase("mm-watch-ok", "ui.menu.watch(fn) then unwatch twice [control]", function() local t = U.menu.watch(nop) U.menu.unwatch(t) U.menu.unwatch(t) return t end,
        E.ret("a positive integer token", function(r) return math.type(r[1]) == "integer" and r[1] > 0 end))
    -- screen: no window without the title-screen menu; handles that aren't windows
    local SW = UI .. ".screen."
    mcase("mm-screen-open-none", "ui.screen.open()", f(U.screen.open), E.err(SW .. "open: expected a table { id = ..., close = ... }, got nil"))
    mcase("mm-screen-open-unknown", "ui.screen.open{ id = 'w', modal = true }", f(U.screen.open, { id = "w", modal = true }), E.err(SW .. "open: unknown key 'modal' (valid: close, id)"))
    mcase("mm-screen-open-noid", "ui.screen.open{}", f(U.screen.open, {}), E.err(SW .. "open: id must be a string, got nil"))
    mcase("mm-screen-open-close", "ui.screen.open{ id = 'w', close = 'yes' }", f(U.screen.open, { id = "w", close = "yes" }), E.err(SW .. "open: close must be a boolean or nil, got 'yes'"))
    mcase("mm-screen-open-nomenu", "ui.screen.open{ id = 'w' } [no title-screen menu]", f(U.screen.open, { id = "w" }), E.err(SW .. "open: the title-screen menu is not open (windows open only over it)"))
    for _, d in ipairs({ { "close", "close", U.screen.close }, { "isopen", "isOpen", U.screen.isOpen } }) do
        local key, nm, fn = d[1], d[2], d[3]
        mcase("mm-screen-" .. key .. "-nil", "ui.screen." .. nm .. "(nil)", f(fn, nil), E.err(SW .. nm .. ": expected a window handle, got nil"))
        mcase("mm-screen-" .. key .. "-num", "ui.screen." .. nm .. "(5)", f(fn, 5), E.err(SW .. nm .. ": expected a window handle, got 5"))
        mcase("mm-screen-" .. key .. "-forged", "ui.screen." .. nm .. "({ id = 'w' }) [forged]", f(fn, { id = "w" }), E.err(SW .. nm .. ": not a window handle (use the handle that screen.open returned)"))
    end
    mcase("mm-screen-top-arg", "ui.screen.top(1)", f(U.screen.top, 1), E.err(SW .. "top: expected 0 arguments, got 1"))
    mcase("mm-screen-top-ok", "ui.screen.top() [control: no window]", f(U.screen.top), E.nilret)
    mcase("mm-screen-watch-nil", "ui.screen.watch(nil)", f(U.screen.watch, nil), E.err(SW .. "watch: fn must be a function, got nil"))
    mcase("mm-screen-unwatch-forged", "ui.screen.unwatch(2^40)", f(U.screen.unwatch, 1 << 40), E.err(SW .. "unwatch: unknown token 1099511627776 (not one screen.watch returned)"))
    mcase("mm-screen-unwatch-float", "ui.screen.unwatch(1.5)", f(U.screen.unwatch, 1.5), E.err(SW .. "unwatch: token must be an integer, got 1.5"))
    mcase("mm-screen-watch-ok", "ui.screen.watch(fn) then unwatch twice [control]", function() local t = U.screen.watch(nop) U.screen.unwatch(t) U.screen.unwatch(t) return t end,
        E.ret("a positive integer token", function(r) return math.type(r[1]) == "integer" and r[1] > 0 end))
    -- hosts in intents and elements(host)
    local PL = UI .. ".place: "
    local T = U.text
    mcase("mm-elements-menu", "ui.elements('menu') [control]", f(U.elements, "menu"), E.ret("{}", function(r) return type(r[1]) == "table" and next(r[1]) == nil end))
    mcase("mm-elements-screen", "ui.elements('screen') [control]", f(U.elements, "screen"), E.ret("{}", function(r) return type(r[1]) == "table" and next(r[1]) == nil end))
    mcase("mm-place-screen-num", "ui.text.create{ place = { screen = 5, corner } }", f(T.create, { id = "bm", place = { screen = 5, corner = "top-left" } }), E.err(PL .. "screen must be a window handle, got 5"))
    mcase("mm-place-screen-forged", "ui.text.create{ place = { screen = { id = 'w' }, corner } }", f(T.create, { id = "bm", place = { screen = { id = "w" }, corner = "top-left" } }), E.err(PL .. "screen must be a window handle"))
    mcase("mm-place-menu-near", "ui.text.create{ place = { host = 'menu', near = 'crosshair' } }", f(T.create, { id = "bm", place = { host = "menu", near = "crosshair" } }), E.err(PL .. "near is not available on host 'menu' (corner or absolute)"))
    mcase("mm-place-menu-region", "ui.text.create{ place = { host = 'menu', corner, region = 'map' } }", f(T.create, { id = "bm", place = { host = "menu", corner = "top-left", region = "map" } }), E.err(PL .. "region is not available on host 'menu' (journal only)"))
    mcase("mm-place-fill-alone", "ui.text.create{ place = { corner, fill = 2 } }", f(T.create, { id = "bm", place = { corner = "top-left", fill = 2 } }), E.err(PL .. "fill is allowed only with row"))
    local tm
    mcase("mm-text-menu-ok", "ui.text.create{ place = { host = 'menu', corner = 'top-left' } } [control: pending]", function()
        tm = T.create{ id = "bm", text = "m", place = { host = "menu", corner = "top-left" } }
        return T.isShown(tm)
    end, E.ret("false (no title-screen menu)", function(r) return r[1] == false end))
    -- look and font
    local ST = UI .. ".text: "
    mcase("mm-look-bad", "ui.text.create{ style = { look = 'shiny' } }", f(T.create, { id = "bm2", style = { look = "shiny" } }), E.err(ST .. "unknown look 'shiny' (valid: game, plain)"))
    mcase("mm-font-bad", "ui.text.create{ style = { look = 'game', font = 'huge' } }", f(T.create, { id = "bm2", style = { look = "game", font = "huge" } }), E.err(ST .. "unknown font 'huge' (valid: title, heading, body, small)"))
    mcase("mm-font-plain", "ui.text.create{ style = { look = 'plain', font = 'title' } }", f(T.create, { id = "bm2", style = { look = "plain", font = "title" } }), E.err(ST .. "font needs look = 'game' (got look 'plain')"))
    if tm then
        mcase("mm-font-game-ok", "ui.text.setStyle(t, { look = 'game', font = 'heading' }) [control]", f(T.setStyle, tm, { look = "game", font = "heading" }), E.none)
        T.remove(tm)
    end
    -- lists
    local LS, LC = U.list, UI .. ".list.create: "
    local jp = { host = "journal", corner = "top-left" }
    local sz = { w = 400, h = 300 }
    mcase("mm-list-none", "ui.list.create()", f(LS.create), E.err(LC .. "expected a table"))
    mcase("mm-list-unknown", "ui.list.create{ ..., rows = 3 }", f(LS.create, { id = "bl", place = jp, size = sz, rows = 3 }), E.err(LC .. "unknown key 'rows' (valid: gap, id, place, size, style)"))
    mcase("mm-list-size-nil", "ui.list.create{ no size }", f(LS.create, { id = "bl", place = jp }), E.err(LC .. "size must be a table { w = 32..4096, h = 32..4096 }, got nil"))
    mcase("mm-list-size-str", "ui.list.create{ size = '400x300' }", f(LS.create, { id = "bl", place = jp, size = "400x300" }), E.err(LC .. "size must be a table { w = 32..4096, h = 32..4096 }, got '400x300'"))
    mcase("mm-list-size-w31", "ui.list.create{ size = { w = 31, h = 300 } }", f(LS.create, { id = "bl", place = jp, size = { w = 31, h = 300 } }), E.err(LC .. "size.w must be a number from 32 to 4096, got 31"))
    mcase("mm-list-size-h4097", "ui.list.create{ size = { 400, 4097 } }", f(LS.create, { id = "bl", place = jp, size = { 400, 4097 } }), E.err(LC .. "size.h must be a number from 32 to 4096, got 4097"))
    mcase("mm-list-size-nan", "ui.list.create{ size = { w = 0/0, h = 300 } }", f(LS.create, { id = "bl", place = jp, size = { w = 0 / 0, h = 300 } }), E.err(LC .. "size.w must be a number from 32 to 4096, got NaN"))
    mcase("mm-list-hud", "ui.list.create{ place = { host = 'hud', corner } }", f(LS.create, { id = "bl", place = { host = "hud", corner = "top-left" }, size = sz }), E.err(LC .. "lists need a host with a cursor (journal, menu, screen); see input mode, story 16"))
    mcase("mm-list-hud-default", "ui.list.create{ no place: the HUD }", f(LS.create, { id = "bl", size = sz }), E.err(LC .. "lists need a host with a cursor (journal, menu, screen)"))
    local la
    mcase("mm-list-ok", "ui.list.create{ id = 'bla', journal, size = { 400, 300 } } [control]", function()
        la = LS.create{ id = "bla", place = jp, size = { 400, 300 }, gap = "tight" }
        return la
    end, E.ret("a handle { id = 'bla' }", function(r) return type(r[1]) == "table" and r[1].id == "bla" end))
    if not la then return end
    local pj = U.panel.create{ id = "blp", place = { host = "journal", corner = "bottom-left" } }
    mcase("mm-list-in-list", "ui.list.create{ place = { list = <list> } }", f(LS.create, { id = "bl", place = { list = la }, size = sz }), E.err(LC .. "a list can't go inside a panel, list or row"))
    mcase("mm-list-in-panel", "ui.list.create{ place = { panel = <panel> } }", f(LS.create, { id = "bl", place = { panel = pj }, size = sz }), E.err(LC .. "a list can't go inside a panel, list or row"))
    -- rows
    local RS, RC = U.row, UI .. ".row.create: "
    mcase("mm-row-unknown", "ui.row.create{ ..., size = 1 }", f(RS.create, { id = "br", place = { list = la }, size = 1 }), E.err(RC .. "unknown key 'size' (valid: gap, id, place, style)"))
    mcase("mm-row-hud", "ui.row.create{ place = { host = 'hud', corner } }", f(RS.create, { id = "br", place = { host = "hud", corner = "top-left" } }), E.err(RC .. "rows need a host with a cursor (journal, menu, screen); see input mode, story 16"))
    local ra
    mcase("mm-row-ok", "ui.row.create{ id = 'bra', place = { list = <list> } } [control]", function()
        ra = RS.create{ id = "bra", place = { list = la } }
        return ra
    end, E.ret("a handle { id = 'bra' }", function(r) return type(r[1]) == "table" and r[1].id == "bra" end))
    mcase("mm-row-in-panel-ok", "ui.row.create{ id = 'brp', place = { panel = <panel> } } [control]", function()
        return RS.create{ id = "brp", place = { panel = pj } }
    end, E.ret("a handle { id = 'brp' }", function(r) return type(r[1]) == "table" and r[1].id == "brp" end))
    if ra then
        mcase("mm-row-in-row", "ui.row.create{ place = { row = <row> } }", f(RS.create, { id = "br", place = { row = ra } }), E.err(RC .. "a row can't go inside a row"))
        mcase("mm-list-in-row", "ui.list.create{ place = { row = <row> } }", f(LS.create, { id = "bl", place = { row = ra }, size = sz }), E.err(LC .. "a list can't go inside a panel, list or row"))
        mcase("mm-fill-0", "ui.text.create{ place = { row = r, fill = 0 } }", f(T.create, { id = "bt", place = { row = ra, fill = 0 } }), E.err(PL .. "fill must be a number from 0.1 to 16, got 0"))
        mcase("mm-fill-17", "ui.text.create{ place = { row = r, fill = 17 } }", f(T.create, { id = "bt", place = { row = ra, fill = 17 } }), E.err(PL .. "fill must be a number from 0.1 to 16, got 17"))
        mcase("mm-fill-str", "ui.text.create{ place = { row = r, fill = 'x' } }", f(T.create, { id = "bt", place = { row = ra, fill = "x" } }), E.err(PL .. "fill must be a number from 0.1 to 16, got 'x'"))
        mcase("mm-fill-list", "ui.text.create{ place = { list = l, fill = 2 } }", f(T.create, { id = "bt", place = { list = la, fill = 2 } }), E.err(PL .. "fill is allowed only with row"))
        mcase("mm-row-child-17", "ui.text.create{ place = { row = <row with 16 children> } } [the 17th]", function()
            local made = {}
            for i = 1, 16 do made[i] = T.create{ id = "brc" .. i, text = "c", place = { row = ra, fill = i == 1 and 3 or nil } } end
            local ok, err = pcall(T.create, { id = "brc17", text = "c", place = { row = ra } })
            for _, m in ipairs(made) do T.remove(m) end
            if not ok then error(err, 0) end
        end, E.err(PL .. "row 'bra' already has 16 children (at most 16)"))
        mcase("mm-button-in-row-ok", "ui.button.create{ place = { row = r, fill = 1 } } [control]", function()
            local b = U.button.create{ id = "brb", label = "x", place = { row = ra, fill = 1 }, onClick = nop }
            U.button.remove(b)
            return b.id
        end, E.ret("'brb'", function(r) return r[1] == "brb" end))
        mcase("mm-row-setvis-yes", "ui.row.setVisible(r, 'yes')", f(RS.setVisible, ra, "yes"), E.err(UI .. ".row.setVisible: visible must be a boolean, got string"))
        mcase("mm-row-isshown-ok", "ui.row.isShown(r) [control: the Journal is closed]", f(RS.isShown, ra), E.ret("false", function(r) return r[1] == false end))
    end
    mcase("mm-list-child-257", "ui.text.create{ place = { list = <list with 256 children> } } [the 257th]", function()
        local made = {}
        local base = ra and 1 or 0 -- 'bra' is one child already
        for i = 1, 256 - base do made[i] = T.create{ id = "blc" .. i, text = "c", place = { list = la } } end
        local ok, err = pcall(T.create, { id = "blc257", text = "c", place = { list = la } })
        for _, m in ipairs(made) do T.remove(m) end
        if not ok then error(err, 0) end
    end, E.err(PL .. "list 'bla' already has 256 children (at most 256)"))
    mcase("mm-list-setvis-1", "ui.list.setVisible(l, 1)", f(LS.setVisible, la, 1), E.err(UI .. ".list.setVisible: visible must be a boolean, got number"))
    mcase("mm-list-setstyle-game", "ui.list.setStyle(l, { look = 'game' }) [control]", f(LS.setStyle, la, { look = "game" }), E.none)
    mcase("mm-list-isshown-ok", "ui.list.isShown(l) [control: the Journal is closed]", f(LS.isShown, la), E.ret("false", function(r) return r[1] == false end))
    mcase("mm-list-h-text", "ui.list.isShown(<text handle>)", function()
        local th = T.create{ id = "blt", text = "t", place = { absolute = { anchor = "center", x = 0, y = 280 } } }
        local ok, err = pcall(LS.isShown, th)
        T.remove(th)
        if not ok then error(err, 0) end
    end, E.err(UI .. ".list.isShown: not a list handle"))
    mcase("mm-list-h-forged", "ui.list.remove({ id = 'bla' }) [forged]", f(LS.remove, { id = "bla" }), E.err(UI .. ".list.remove: not a list handle"))
    mcase("mm-list-remove-ok", "ui.list.remove(l) [control: its rows go too]", f(LS.remove, la), E.none)
    mcase("mm-list-remove-again", "ui.list.remove(l) [again]", f(LS.remove, la), E.none)
    if ra then mcase("mm-list-removed-row", "ui.row.isShown(<row of a removed list>)", f(RS.isShown, ra), E.err(UI .. ".row: handle 'bra' was removed")) end
    U.panel.remove(pj) -- its row 'brp' goes with it
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

    -- UI-5 journal (story 13): the watcher's functions, and the journal host in intents.
    local JW = UI .. ".journal."
    case(P .. "journal-watch-nil", "ui.journal.watch(nil)", f(U.journal.watch, nil), E.err(JW .. "watch: fn must be a function, got nil"))
    case(P .. "journal-watch-1", "ui.journal.watch(1)", f(U.journal.watch, 1), E.err(JW .. "watch: fn must be a function, got 1"))
    case(P .. "journal-watch-str", "ui.journal.watch(\"x\")", f(U.journal.watch, "x"), E.err(JW .. "watch: fn must be a function, got 'x'"))
    case(P .. "journal-watch-table", "ui.journal.watch({})", f(U.journal.watch, {}), E.err(JW .. "watch: fn must be a function, got table"))
    case(P .. "journal-watch-two", "ui.journal.watch(fn, 1)", f(U.journal.watch, nop, 1), E.err(JW .. "watch: expected 1 argument (fn), got 2"))
    case(P .. "journal-unwatch-forged", "ui.journal.unwatch(2^40) [forged token]", f(U.journal.unwatch, 1 << 40), E.err(JW .. "unwatch: unknown token 1099511627776 (not one journal.watch returned)"))
    case(P .. "journal-unwatch-hudtoken", "ui.journal.unwatch(<a hud.watch token>)", function()
        local t = U.hud.watch(nop)
        local ok, err = pcall(U.journal.unwatch, t)
        U.hud.unwatch(t)
        if not ok then error(err, 0) end
    end, E.err(JW .. "unwatch: unknown token"))
    case(P .. "journal-unwatch-str", "ui.journal.unwatch(\"x\")", f(U.journal.unwatch, "x"), E.err(JW .. "unwatch: token must be an integer, got 'x'"))
    case(P .. "journal-unwatch-float", "ui.journal.unwatch(1.5)", f(U.journal.unwatch, 1.5), E.err(JW .. "unwatch: token must be an integer, got 1.5"))
    case(P .. "journal-unwatch-nil", "ui.journal.unwatch(nil)", f(U.journal.unwatch, nil), E.err(JW .. "unwatch: token must be an integer, got nil"))
    case(P .. "journal-unwatch-table", "ui.journal.unwatch({})", f(U.journal.unwatch, {}), E.err(JW .. "unwatch: token must be an integer, got table"))
    case(P .. "journal-unwatch-two", "ui.journal.unwatch(1, 2)", f(U.journal.unwatch, 1, 2), E.err(JW .. "unwatch: expected 1 argument (token), got 2"))
    case(P .. "journal-isopen-arg", "ui.journal.isOpen(1)", f(U.journal.isOpen, 1), E.err(JW .. "isOpen: expected 0 arguments, got 1"))
    case(P .. "journal-isopen-ok", "ui.journal.isOpen() [control]", f(U.journal.isOpen), E.ret("false (the map is closed)", function(r) return r[1] == false end))
    case(P .. "journal-find-arg", "ui.journal.find(true)", f(U.journal.find, true), E.err(JW .. "find: expected 0 arguments, got 1"))
    case(P .. "journal-find-ok", "ui.journal.find() [control]", f(U.journal.find), E.nilret)
    case(P .. "journal-watch-ok", "ui.journal.watch(fn) then unwatch twice [control]", function() local t = U.journal.watch(nop) U.journal.unwatch(t) U.journal.unwatch(t) return t end,
        E.ret("a positive integer token", function(r) return math.type(r[1]) == "integer" and r[1] > 0 end))
    case(P .. "journal-stats", "ui.journal.stats() [control]", f(U.journal.stats), E.ret("a table, closed", function(r) return type(r[1]) == "table" and r[1].open == false end))
    case(P .. "create-journal-near", "ui.text.create{ id = 'bj', place = { host = 'journal', near = 'crosshair' } }",
        f(T.create, { id = "bj", place = { host = "journal", near = "crosshair" } }), E.err(UI .. ".place: unknown near region 'crosshair' (valid: ammo, binder, cover, map, map-header, match, page-left, page-right, tasks)"))

    -- UI-3 elements()
    case(P .. "elements-ok", "ui.elements() [control]", f(U.elements), E.ret("{ crosshair = ... }", function(r) return type(r[1]) == "table" and type(r[1].crosshair) == "string" and r[1].mic == nil end))
    case(P .. "elements-arg", "ui.elements(1)", f(U.elements, 1), E.err(UI .. ".elements: unknown host 1 (valid: createServer, hud, journal, menu, screen)"))
    -- story 19: elements(host)
    case(P .. "elements-bogus", "ui.elements('bogus')", f(U.elements, "bogus"), E.err(UI .. ".elements: unknown host 'bogus' (valid: createServer, hud, journal, menu, screen)"))
    case(P .. "elements-two", "ui.elements('hud', 2)", f(U.elements, "hud", 2), E.err(UI .. ".elements: expected 0 or 1 arguments, got 2"))
    case(P .. "elements-hud", "ui.elements('hud') [control]", f(U.elements, "hud"), E.ret("{ crosshair = ... }", function(r) return type(r[1]) == "table" and type(r[1].crosshair) == "string" and r[1].map == nil end))
    case(P .. "elements-journal", "ui.elements('journal') [control]", f(U.elements, "journal"), E.ret("the nine journal regions", function(r)
        if type(r[1]) ~= "table" or r[1].crosshair ~= nil then return false end
        local n = 0
        for _, d in pairs(r[1]) do if type(d) ~= "string" then return false end n = n + 1 end
        return n == 9 and r[1].map ~= nil and r[1]["page-left"] ~= nil
    end))

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
    case(P .. "style-bg", "create{ style = { bg = 'dim' } }", f(T.create, { id = "bi", style = { bg = "dim" } }), E.err(ST .. "unknown style key 'bg' (valid: background, font, look, overflow, padding)"))

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
    pc_("host", "{ host = 'Journal', corner }", { host = "Journal", corner = "top-left" }, E.err(PL .. "unknown host 'Journal' (valid: createServer, hud, journal, menu, screen)"))
    pc_("host-num", "{ host = 5, corner }", { host = 5, corner = "top-left" }, E.err(PL .. "unknown host 5 (valid: createServer, hud, journal, menu, screen)"))
    pc_("host-journal-near", "{ host = 'journal', near = 'crosshair' }", { host = "journal", near = "crosshair" }, E.err(PL .. "unknown near region 'crosshair' (valid: ammo, binder, cover, map, map-header, match, page-left, page-right, tasks)"))
    -- story 19: journal regions (the I/O matrix's error rows)
    local RN = "(valid: ammo, binder, cover, map, map-header, match, page-left, page-right, tasks)"
    pc_("region-hud", "{ corner, region = 'map' }", { corner = "top-left", region = "map" }, E.err(PL .. "region is not available on host 'hud' (journal only)"))
    pc_("inset-hud", "{ corner, inset = 'tight' }", { corner = "top-left", inset = "tight" }, E.err(PL .. "inset is not available on host 'hud' (journal only)"))
    pc_("region-spine", "{ host = 'journal', corner, region = 'spine' }", { host = "journal", corner = "top-left", region = "spine" }, E.err(PL .. "unknown region 'spine' " .. RN))
    pc_("region-num", "{ host = 'journal', corner, region = 1 }", { host = "journal", corner = "top-left", region = 1 }, E.err(PL .. "unknown region 1 " .. RN))
    pc_("inset-huge", "{ host = 'journal', corner, inset = 'huge' }", { host = "journal", corner = "top-left", inset = "huge" }, E.err(PL .. "unknown inset 'huge' (valid: tight, normal, loose)"))
    pc_("inset-num", "{ host = 'journal', corner, inset = 8 }", { host = "journal", corner = "top-left", inset = 8 }, E.err(PL .. "unknown inset 8 (valid: tight, normal, loose)"))
    pc_("near-region-key", "{ host = 'journal', near = 'map', region = 'map' }", { host = "journal", near = "map", region = "map" }, E.err(PL .. "region is not allowed with near (valid keys: align, gap, host, near, offset, screen, side)"))
    pc_("near-inset-key", "{ host = 'journal', near = 'map', inset = 'tight' }", { host = "journal", near = "map", inset = "tight" }, E.err(PL .. "inset is not allowed with near"))
    pc_("abs-region-key", "{ host = 'journal', absolute, region = 'map' }", { host = "journal", absolute = { x = 0, y = 0 }, region = "map" }, E.err(PL .. "region is not allowed with absolute (valid keys: absolute, host, screen)"))
    pc_("abs-inset-key", "{ host = 'journal', absolute, inset = 'tight' }", { host = "journal", absolute = { x = 0, y = 0 }, inset = "tight" }, E.err(PL .. "inset is not allowed with absolute (valid keys: absolute, host, screen)"))
    pc_("near-hud-map", "{ near = 'map' }", { near = "map" }, E.err(PL .. "unknown near element 'map' (valid: crosshair)"))
    pc_("journal-near-corner", "{ host = 'journal', near = 'map', corner }", { host = "journal", near = "map", corner = "top-left" }, E.err(PL .. "an intent needs exactly one of corner, near or absolute (got corner and near)"))
    for _, r in ipairs({ "ammo", "binder", "cover", "map", "map-header", "match", "page-left", "page-right", "tasks" }) do
        pc_("region-" .. r, "{ host = 'journal', corner = 'top-left', region = '" .. r .. "', inset = 'tight' } [control]", { host = "journal", corner = "top-left", region = r, inset = "tight" }, E.none)
        pc_("near-" .. r, "{ host = 'journal', near = '" .. r .. "', side = 'below' } [control]", { host = "journal", near = r, side = "below" }, E.none)
    end
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
    pc_("host-journal-ok", "{ host = 'journal', corner = 'top-left' } [control: moved to the closed Journal]", { host = "journal", corner = "top-left" }, E.none)
    case(P .. "isshown-journal", "ui.text.isShown(h) [control: on the closed Journal]", f(T.isShown, h), E.ret("false", function(r) return r[1] == false end))
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
    panelCases(P, f, okRet)
    buttonCases(P, f)
    mmCases(P, f)
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
    off("journal-watch", "journal.watch", U.journal.watch, function() end)
    off("journal-unwatch", "journal.unwatch", U.journal.unwatch, 1)
    off("journal-isopen", "journal.isOpen", U.journal.isOpen)
    off("journal-find", "journal.find", U.journal.find)
    -- story 14: the off-thread check comes before any argument check, so a forged handle is enough
    off("panel-create", "panel.create", U.panel.create, { id = "off" })
    off("panel-setstyle", "panel.setStyle", U.panel.setStyle, {}, nil)
    off("panel-setvis", "panel.setVisible", U.panel.setVisible, {}, true)
    off("panel-remove", "panel.remove", U.panel.remove, {})
    off("panel-isshown", "panel.isShown", U.panel.isShown, {})
    off("panel-order", "panel.order", U.panel.order, {})
    off("panel-setorder", "panel.setOrder", U.panel.setOrder, {}, {})
    off("panel-move", "panel.move", U.panel.move, {}, {}, 1)
    -- story 15
    off("button-create", "button.create", U.button.create, { id = "off" })
    off("button-setlabel", "button.setLabel", U.button.setLabel, {}, "x")
    off("button-setenabled", "button.setEnabled", U.button.setEnabled, {}, true)
    off("button-setvis", "button.setVisible", U.button.setVisible, {}, true)
    off("button-remove", "button.remove", U.button.remove, {})
    off("button-isshown", "button.isShown", U.button.isShown, {})
    -- story 21 (Mod Manager story 2): the menu entry, the menu and screen hosts, lists and rows
    off("menu-entry", "menu.entry", U.menu.entry, { id = "off" })
    off("menu-removeentry", "menu.removeEntry", U.menu.removeEntry, {})
    off("menu-isopen", "menu.isOpen", U.menu.isOpen)
    off("menu-watch", "menu.watch", U.menu.watch, function() end)
    off("menu-unwatch", "menu.unwatch", U.menu.unwatch, 1)
    off("screen-open", "screen.open", U.screen.open, { id = "off" })
    off("screen-close", "screen.close", U.screen.close, {})
    off("screen-isopen", "screen.isOpen", U.screen.isOpen, {})
    off("screen-top", "screen.top", U.screen.top)
    off("screen-watch", "screen.watch", U.screen.watch, function() end)
    off("screen-unwatch", "screen.unwatch", U.screen.unwatch, 1)
    off("list-create", "list.create", U.list.create, { id = "off" })
    off("list-setstyle", "list.setStyle", U.list.setStyle, {}, nil)
    off("list-setvis", "list.setVisible", U.list.setVisible, {}, true)
    off("list-remove", "list.remove", U.list.remove, {})
    off("list-isshown", "list.isShown", U.list.isShown, {})
    off("row-create", "row.create", U.row.create, { id = "off" })
    off("row-setstyle", "row.setStyle", U.row.setStyle, {}, nil)
    off("row-setvis", "row.setVisible", U.row.setVisible, {}, true)
    off("row-remove", "row.remove", U.row.remove, {})
    off("row-isshown", "row.isShown", U.row.isShown, {})
end

local function preConnectCases()
    step("before-connect cases", function()
        local UI = CORE:lower() .. ".ui"
        local want = { create = "text.create", watch = "hud.watch", find = "hud.find", elements = "elements", overlaps = "debug.overlaps",
            ["pre-journal-watch"] = "journal.watch", ["pre-journal-isopen"] = "journal.isOpen",
            ["pre-panel-create"] = "panel.create", ["pre-panel-move"] = "panel.move", ["pre-button-create"] = "button.create" }
        for _, r in ipairs(PRE_CONNECT) do
            case(r.id, r.desc, function() if not r.ok then error(r.err, 0) end return "no error" end,
                E.err(UI .. ": " .. tostring(want[r.id] or want[r.fn]) .. " called before connect"))
        end
        check(#PRE_CONNECT == 10, "CASES before-connect recorded=%d (expected 10)", #PRE_CONNECT)
        for _, r in ipairs(PRE_NATIVE) do
            case(r.id, r.desc, function() if not r.ok then error(r.err, 0) end return "no error" end,
                E.err(tostring(r.name) .. ": no object at /Game/NoSuch/NNNoManager.NNNoManager"))
        end
        check(#PRE_NATIVE == 3, "CASES main.lua objectives recorded=%d (expected 3)", #PRE_NATIVE)
        case("pre-map-signal", "GetSharedVariable(\"" .. SETUP_KEY .. "\") [main.lua]", function()
            if not PRE_SIGNAL then error("not recorded during main.lua", 0) end
            if not PRE_SIGNAL[1] then error(PRE_SIGNAL[2], 0) end
            return PRE_SIGNAL[2]
        end, E.signalNone)
    end)
end

-- ---------------------------------------------------------------- objectives natives (map service story 3)
-- <Core>_SetObjectives, _DescribeObjectives and _SetTraitorTaskState with bad values (map-setup.md "bad-input cases",
-- Natives), and in the match the real thing on a manager this test spawned itself on the host: fill, read back, a
-- second fill refused, one task's TraitorState set and cleared. The forced missing struct member goes through core's
-- test-only DLL (test/SkelNative, <Core>SkelNative_SetObjectivesMissing), never through a public native. Every manager
-- spawned here is destroyed again in the same step; only paths are kept.
local OBJ_PKG, OBJ_SHORT = "/Game/Gameplay/ClassifiedMaterials/ObjectiveManager", "ObjectiveManager_C"
local OBJ_CLASS = OBJ_PKG .. "." .. OBJ_SHORT
local OBJ_CDO = OBJ_PKG .. ".Default__" .. OBJ_SHORT
local OBJ_MISSING = "/Game/NoSuch/NNNoManager.NNNoManager"
local OBJ_KEYS = { "Actors", "Tasks", "State", "Description", "UniqueIdentifier", "TraitorDescription", "TraitorState" }

local function objClass()
    local cls = found(OBJ_CLASS)
    if cls then return cls end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    cls = helpers:GetAsset({ PackageName = FName(OBJ_PKG), AssetName = FName(OBJ_SHORT) })
    return valid(cls) and cls or nil
end
local function spawnManager(z)
    local cls = objClass()
    if not cls then return nil end
    local a = pc():GetWorld():SpawnActor(cls, { X = 0, Y = 0, Z = z or -50000 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    return valid(a) and a or nil
end
-- <Core>_DescribeObjectives' text as { objectives, selected, net, area, tasks = { ... }, byId }.
local function parseObjectives(text)
    local d = { tasks = {}, byId = {} }
    for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
        local f = {}
        for v in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = v end
        if f[1] == "manager" then
            d.objectives, d.selected, d.net, d.area = tonumber(f[2]), tonumber(f[3]), f[4], f[5]
        elseif f[1] == "task" then
            local t = { objective = tonumber(f[2]), index = tonumber(f[3]), state = f[4], id = f[5], text = f[6], traitorState = f[7], traitorText = f[8] }
            d.tasks[#d.tasks + 1] = t
            d.byId[t.id or ""] = t
        end
    end
    return d
end
local function taskArgs(n, prefix)
    local a = {}
    for i = 1, n do a[#a + 1] = (prefix or "t") .. i; a[#a + 1] = "Task " .. i end
    return a
end
local function described(pred, what)
    return E.ret(what, function(r) return r.n == 1 and type(r[1]) == "string" and pred(parseObjectives(r[1])) end)
end

local function objectivesCases(phase)
    local P = phase .. "."
    local SET, DESC, TRAIT = native("_SetObjectives"), native("_DescribeObjectives"), native("_SetTraitorTaskState")
    local nSET, nDESC, nTRAIT = CORE .. "_SetObjectives", CORE .. "_DescribeObjectives", CORE .. "_SetTraitorTaskState"
    if not check(type(SET) == "function" and type(DESC) == "function" and type(TRAIT) == "function",
        "CASE %sobj-natives %s, %s and %s exist", P, nSET, nDESC, nTRAIT) then return end
    local fs, fd, ft = intFn(SET), intFn(DESC), intFn(TRAIT)
    local M = OBJ_MISSING
    local okCls = check(objClass() ~= nil, "CASE %sobj-class %s loaded for the CDO and spawn cases", P, OBJ_CLASS)

    -- SetObjectives: counts, types, sizes, characters, duplicates. A path that names nothing comes last, so a check
    -- that let a bad value through ends in "no object at" instead of the expected error.
    local eS = function(t) return E.err(nSET .. ": " .. t) end
    case(P .. "obj-set-noargs", nSET .. "()", fs(), eS("expected (managerPath, areaName, id1, text1, ...), got 0 arguments"))
    case(P .. "obj-set-one", nSET .. "(path)", fs(M), eS("expected (managerPath, areaName, id1, text1, ...), got 1 argument"))
    case(P .. "obj-set-0tasks", nSET .. "(path, area) [0 tasks]", fs(M, "A"), eS("1..64 tasks, got 0"))
    case(P .. "obj-set-odd", nSET .. "(path, area, id) [no text]", fs(M, "A", "a"), eS("each task is an id and a text; got 3 arguments (an odd count)"))
    case(P .. "obj-set-65", nSET .. "(path, area, <65 tasks>)", fs(M, "A", table.unpack(taskArgs(65))), eS("1..64 tasks, got 65"))
    case(P .. "obj-set-64", nSET .. "(<missing>, area, <64 tasks>) [64 is allowed]", fs(M, "A", table.unpack(taskArgs(64))), eS("no object at " .. M))
    case(P .. "obj-set-path-num", nSET .. "(42, area, id, text)", fs(42, "A", "a", "t"), eS("argument 1 (managerPath) must be a string, got an integer"))
    case(P .. "obj-set-path-float", nSET .. "(1.5, area, id, text)", fs(1.5, "A", "a", "t"), eS("argument 1 (managerPath) must be a string, got a float"))
    case(P .. "obj-set-area-nil", nSET .. "(path, nil, id, text)", fs(M, nil, "a", "t"), eS("argument 2 (areaName) must be a string, got nil"))
    case(P .. "obj-set-id-num", nSET .. "(path, area, 7, text)", fs(M, "A", 7, "t"), eS("argument 3 (task id) must be a string, got an integer"))
    case(P .. "obj-set-text-table", nSET .. "(path, area, id, {})", fs(M, "A", "a", {}), eS("argument 4 (task text) must be a string, got a table"))
    case(P .. "obj-set-text-bool", nSET .. "(path, area, id, text, id, true)", fs(M, "A", "a", "t", "b", true), eS("argument 6 (task text) must be a string, got a boolean"))
    case(P .. "obj-set-text-func", nSET .. "(path, area, id, print)", fs(M, "A", "a", print), eS("argument 4 (task text) must be a string, got a function"))
    local hud = found(S.hudPath)
    if hud then case(P .. "obj-set-path-obj", nSET .. "(<HUD object itself>, area, id, text)", fs(hud, "A", "a", "t"), eS("argument 1 (managerPath) must be a string, got a userdata")) end
    case(P .. "obj-set-path-empty", nSET .. "(\"\", ...)", fs("", "A", "a", "t"), eS("manager path must be 1..512 characters, got 0"))
    case(P .. "obj-set-path-513", nSET .. "(<513 characters>, ...)", fs("/" .. string.rep("a", 512), "A", "a", "t"), eS("manager path must be 1..512 characters, got 513"))
    case(P .. "obj-set-path-512", nSET .. "(<512 characters>, ...) [allowed]", fs("/" .. string.rep("a", 511), "A", "a", "t"), eS("no object at /aaaa"))
    case(P .. "obj-set-path-noslash", nSET .. "(\"Game/X.Y\", ...)", fs("Game/X.Y", "A", "a", "t"), eS("manager path must be an object path starting with '/'"))
    case(P .. "obj-set-path-utf8", nSET .. "(\"/Game/\\xC3\\xA9\", ...)", fs("/Game/\xC3\xA9", "A", "a", "t"), eS("manager path must be printable ASCII"))
    case(P .. "obj-set-path-ctrl", nSET .. "(\"/Game/a\\nb\", ...)", fs("/Game/a\nb", "A", "a", "t"), eS("manager path must be printable ASCII"))
    case(P .. "obj-set-area-empty", nSET .. "(path, \"\", ...)", fs(M, "", "a", "t"), eS("area name must be 1..128 characters, got 0"))
    case(P .. "obj-set-area-129", nSET .. "(path, <129 characters>, ...)", fs(M, string.rep("x", 129), "a", "t"), eS("area name must be 1..128 characters, got 129"))
    case(P .. "obj-set-area-128", nSET .. "(<missing>, <128 characters>, ...) [allowed]", fs(M, string.rep("x", 128), "a", "t"), eS("no object at " .. M))
    case(P .. "obj-set-area-utf8", nSET .. "(path, \"\\xFF\", ...)", fs(M, "\xFF", "a", "t"), eS("area name must be printable ASCII"))
    case(P .. "obj-set-area-tab", nSET .. "(path, \"a\\tb\", ...)", fs(M, "a\tb", "a", "t"), eS("area name must be printable ASCII"))
    case(P .. "obj-set-text-empty", nSET .. "(path, area, id, \"\")", fs(M, "A", "a", ""), eS("task text must be 1..256 characters, got 0"))
    case(P .. "obj-set-text-257", nSET .. "(path, area, id, <257 characters>)", fs(M, "A", "a", string.rep("x", 257)), eS("task text must be 1..256 characters, got 257"))
    case(P .. "obj-set-text-256", nSET .. "(<missing>, area, id, <256 characters>) [allowed]", fs(M, "A", "a", string.rep("x", 256)), eS("no object at " .. M))
    case(P .. "obj-set-text-utf8", nSET .. "(path, area, id, \"caf\\xC3\\xA9\")", fs(M, "A", "a", "caf\xC3\xA9"), eS("task text must be printable ASCII"))
    case(P .. "obj-set-id-empty", nSET .. "(path, area, \"\", text)", fs(M, "A", "", "t"), eS("task id must be 1..64 characters, got 0"))
    case(P .. "obj-set-id-65", nSET .. "(path, area, <65 characters>, text)", fs(M, "A", string.rep("i", 65), "t"), eS("task id must be 1..64 characters, got 65"))
    case(P .. "obj-set-id-64", nSET .. "(<missing>, area, <64 characters>, text) [allowed]", fs(M, "A", string.rep("i", 64), "t"), eS("no object at " .. M))
    case(P .. "obj-set-id-space", nSET .. "(path, area, \"a b\", text)", fs(M, "A", "a b", "t"), eS("task id 'a b' may hold only letters, digits, '_', '-' and '.'"))
    case(P .. "obj-set-id-slash", nSET .. "(path, area, \"a/b\", text)", fs(M, "A", "a/b", "t"), eS("task id 'a/b' may hold only letters"))
    case(P .. "obj-set-id-utf8", nSET .. "(path, area, \"\\xC3\\xA9\", text)", fs(M, "A", "\xC3\xA9", "t"), eS("task id '??' may hold only letters"))
    case(P .. "obj-set-dup", nSET .. "(path, area, \"a\", text, \"a\", text)", fs(M, "A", "a", "t", "a", "u"), eS("task id 'a' given twice"))
    case(P .. "obj-set-dup-later", nSET .. "(path, area, a, b, c, b) [ids 2 and 4 equal]", fs(M, "A", "a", "t", "b", "t", "c", "t", "b", "t"), eS("task id 'b' given twice"))
    -- The object: missing, not a manager, the class itself, the class default object.
    case(P .. "obj-set-missing", nSET .. "(<path to nothing>, ...)", fs(M, "A", "a", "t"), eS("no object at " .. M))
    if S.hudPath then case(P .. "obj-set-nonmanager", nSET .. "(<the HUD's path>, ...)", fs(S.hudPath, "A", "a", "t"), eS(S.hudPath .. " isn't an ObjectiveManager_C")) end
    if okCls then
        case(P .. "obj-set-class", nSET .. "(<ObjectiveManager_C's class>, ...)", fs(OBJ_CLASS, "A", "a", "t"), eS(OBJ_CLASS .. " isn't an ObjectiveManager_C"))
        case(P .. "obj-set-cdo", nSET .. "(<ObjectiveManager_C's CDO>, ...)", fs(OBJ_CDO, "A", "a", "t"), eS(OBJ_CDO .. " is a class default object or archetype"))
    end

    -- DescribeObjectives.
    local eD = function(t) return E.err(nDESC .. ": " .. t) end
    case(P .. "obj-desc-noargs", nDESC .. "()", fd(), eD("expected 1 argument (managerPath), got 0"))
    case(P .. "obj-desc-two", nDESC .. "(path, path)", fd(M, M), eD("expected 1 argument (managerPath), got 2"))
    case(P .. "obj-desc-num", nDESC .. "(42)", fd(42), eD("argument 1 (managerPath) must be a string, got an integer"))
    case(P .. "obj-desc-nil", nDESC .. "(nil)", fd(nil), eD("argument 1 (managerPath) must be a string, got nil"))
    case(P .. "obj-desc-table", nDESC .. "({})", fd({}), eD("argument 1 (managerPath) must be a string, got a table"))
    case(P .. "obj-desc-empty-path", nDESC .. "(\"\")", fd(""), eD("manager path must be 1..512 characters, got 0"))
    case(P .. "obj-desc-513", nDESC .. "(<513 characters>)", fd("/" .. string.rep("a", 512)), eD("manager path must be 1..512 characters, got 513"))
    case(P .. "obj-desc-noslash", nDESC .. "(\"x\")", fd("x"), eD("manager path must be an object path starting with '/'"))
    case(P .. "obj-desc-utf8", nDESC .. "(\"/\\xC3\\xA9\")", fd("/\xC3\xA9"), eD("manager path must be printable ASCII"))
    case(P .. "obj-desc-missing", nDESC .. "(<path to nothing>)", fd(M), eD("no object at " .. M))
    if S.hudPath then case(P .. "obj-desc-nonmanager", nDESC .. "(<the HUD's path>)", fd(S.hudPath), eD(S.hudPath .. " isn't an ObjectiveManager_C")) end
    if okCls then case(P .. "obj-desc-cdo", nDESC .. "(<ObjectiveManager_C's CDO>)", fd(OBJ_CDO), eD(OBJ_CDO .. " is a class default object or archetype")) end

    -- SetTraitorTaskState.
    local eT = function(t) return E.err(nTRAIT .. ": " .. t) end
    case(P .. "obj-trait-noargs", nTRAIT .. "()", ft(), eT("expected 3 arguments (managerPath, taskId, state), got 0"))
    case(P .. "obj-trait-two", nTRAIT .. "(path, id)", ft(M, "a"), eT("expected 3 arguments (managerPath, taskId, state), got 2"))
    case(P .. "obj-trait-four", nTRAIT .. "(path, id, true, 1)", ft(M, "a", true, 1), eT("expected 3 arguments (managerPath, taskId, state), got 4"))
    case(P .. "obj-trait-path-num", nTRAIT .. "(42, id, true)", ft(42, "a", true), eT("argument 1 (managerPath) must be a string, got an integer"))
    case(P .. "obj-trait-id-num", nTRAIT .. "(path, 7, true)", ft(M, 7, true), eT("argument 2 (taskId) must be a string, got an integer"))
    case(P .. "obj-trait-id-nil", nTRAIT .. "(path, nil, true)", ft(M, nil, true), eT("argument 2 (taskId) must be a string, got nil"))
    case(P .. "obj-trait-state-str", nTRAIT .. "(path, id, \"true\")", ft(M, "a", "true"), eT("argument 3 (state) must be a boolean, got a string"))
    case(P .. "obj-trait-state-int", nTRAIT .. "(path, id, 1)", ft(M, "a", 1), eT("argument 3 (state) must be a boolean, got an integer"))
    case(P .. "obj-trait-state-nil", nTRAIT .. "(path, id, nil)", ft(M, "a", nil), eT("argument 3 (state) must be a boolean, got nil"))
    case(P .. "obj-trait-state-table", nTRAIT .. "(path, id, {})", ft(M, "a", {}), eT("argument 3 (state) must be a boolean, got a table"))
    case(P .. "obj-trait-noslash", nTRAIT .. "(\"x\", id, true)", ft("x", "a", true), eT("manager path must be an object path starting with '/'"))
    case(P .. "obj-trait-id-empty", nTRAIT .. "(path, \"\", true)", ft(M, "", true), eT("task id must be 1..64 characters, got 0"))
    case(P .. "obj-trait-id-65", nTRAIT .. "(path, <65 characters>, true)", ft(M, string.rep("i", 65), true), eT("task id must be 1..64 characters, got 65"))
    case(P .. "obj-trait-id-space", nTRAIT .. "(path, \"a b\", true)", ft(M, "a b", true), eT("task id 'a b' may hold only letters"))
    case(P .. "obj-trait-missing", nTRAIT .. "(<path to nothing>, id, true)", ft(M, "a", true), eT("no object at " .. M))
    if S.hudPath then case(P .. "obj-trait-nonmanager", nTRAIT .. "(<the HUD's path>, id, true)", ft(S.hudPath, "a", true), eT(S.hudPath .. " isn't an ObjectiveManager_C")) end
    if okCls then case(P .. "obj-trait-cdo", nTRAIT .. "(<ObjectiveManager_C's CDO>, id, true)", ft(OBJ_CDO, "a", true), eT(OBJ_CDO .. " is a class default object or archetype")) end

    if not okCls then return end
    local onHost = phase:find("^match") ~= nil
    if not onHost then
        -- The menu is a standalone world: the writers refuse a manager there; the readback works on any machine.
        local m = spawnManager()
        if not check(m ~= nil, "CASE %sobj-spawn-menu spawned an ObjectiveManager_C in the menu", P) then return end
        local path = pathOf(m)
        case(P .. "obj-set-standalone", nSET .. "(<manager in the standalone menu>, ...)", fs(path, "A", "a", "t"), eS(path .. " isn't in the host's world (net mode: standalone)"))
        case(P .. "obj-trait-standalone", nTRAIT .. "(<manager in the standalone menu>, id, true)", ft(path, "a", true), eT(path .. " isn't in the host's world (net mode: standalone)"))
        case(P .. "obj-desc-standalone", nDESC .. "(<manager in the standalone menu>) [read only: allowed]", fd(path),
            described(function(d) return d.objectives == 0 and #d.tasks == 0 end, "the readback of an empty manager"))
        pcall(function() m:K2_DestroyActor() end)
        return
    end

    -- On the host (SmallMap?listen): a manager of our own, filled, read back and ticked.
    local m = spawnManager()
    if not check(m ~= nil, "CASE %sobj-spawn spawned an ObjectiveManager_C on the host", P) then return end
    local path = pathOf(m)
    local ours = { [path] = true } -- every manager this test spawns (the stock readback below skips them)
    say("OBJECTIVES %s our manager %s", phase, path)
    case(P .. "obj-desc-empty", nDESC .. "(<our new manager>)", fd(path),
        described(function(d) return d.objectives == 0 and #d.tasks == 0 and d.net == "1" end, "objectives 0, no tasks, Objectives replicates"))
    case(P .. "obj-trait-unfilled", nTRAIT .. "(<our unfilled manager>, id, true)", ft(path, "nn_a", true), eT(path .. " has no objectives yet; fill it with " .. nSET .. " first"))
    case(P .. "obj-set-ok", nSET .. "(<our manager>, \"NN Area\", nn_a, ..., nn_b, ...) [control]", fs(path, "NN Area", "nn_a", "Task A text", "nn_b", "Task B text"),
        E.ret("2 (the task count)", function(r) return r.n == 1 and r[1] == 2 end))
    local function filled(d)
        local a, b = d.byId.nn_a, d.byId.nn_b
        return d.objectives == 1 and #d.tasks == 2 and d.area == "NN Area" and a ~= nil and b ~= nil and a.objective == 0 and a.index == 0 and b.index == 1
            and a.text == "Task A text" and a.traitorText == "Task A text" and b.text == "Task B text" and b.traitorText == "Task B text"
            and a.state == "0" and b.state == "0" and a.traitorState == "0" and b.traitorState == "0"
    end
    case(P .. "obj-desc-filled", nDESC .. "(<our filled manager>)", fd(path),
        described(filled, "1 objective, area 'NN Area', nn_a and nn_b with State and TraitorState 0 and TraitorDescription = Description"))
    case(P .. "obj-set-second", nSET .. "(<our filled manager>, ...) [second fill]", fs(path, "Other", "x", "y"), eS(path .. " already has 1 objective(s); a manager is filled once only"))
    case(P .. "obj-desc-unchanged", nDESC .. "(<our manager>) [after the refused second fill]", fd(path), described(filled, "the same as before"))
    case(P .. "obj-trait-unknown", nTRAIT .. "(<our manager>, \"nn_z\", true) [unknown id]", ft(path, "nn_z", true), eT(path .. " has no task with id 'nn_z'"))
    case(P .. "obj-desc-after-unknown", nDESC .. "(<our manager>) [after the unknown id]", fd(path), described(filled, "the same as before"))
    case(P .. "obj-trait-ok", nTRAIT .. "(<our manager>, \"nn_b\", true) [control]", ft(path, "nn_b", true), E.ret("1 (task set)", function(r) return r.n == 1 and r[1] == 1 end))
    case(P .. "obj-desc-trait", nDESC .. "(<our manager>) [after TraitorState nn_b = true]", fd(path), described(function(d)
        local a, b = d.byId.nn_a, d.byId.nn_b
        return a ~= nil and b ~= nil and b.traitorState == "1" and a.traitorState == "0" and a.state == "0" and b.state == "0"
    end, "nn_b TraitorState 1, nn_a 0, State untouched"))
    case(P .. "obj-trait-off", nTRAIT .. "(<our manager>, \"nn_b\", false) [control]", ft(path, "nn_b", false), E.ret("1 (task set)", function(r) return r.n == 1 and r[1] == 1 end))
    case(P .. "obj-desc-trait-off", nDESC .. "(<our manager>) [after TraitorState nn_b = false]", fd(path), described(filled, "back as filled"))
    -- The game's own tick on our fill: UpdateTaskState finds the task by UniqueIdentifier in Objectives[Selected
    -- Objective] and ignores TaskNumber when the id isn't empty (decompile V8.1.5, ObjectiveManager_C.cpp).
    case(P .. "obj-game-tick", "ObjectiveManager_C:UpdateTaskState(0, true, \"nn_a\") [the game's own function]",
        function() m:UpdateTaskState(0, true, "nn_a") return "called" end, E.ret("the call returns", function(r) return r[1] == "called" end))
    case(P .. "obj-desc-game-tick", nDESC .. "(<our manager>) [after the game's UpdateTaskState nn_a]", fd(path), described(function(d)
        local a, b = d.byId.nn_a, d.byId.nn_b
        return a ~= nil and b ~= nil and a.state == "1" and b.state == "0"
    end, "nn_a State 1, nn_b State 0"))

    -- The forced missing struct member (core's test-only DLL): each member refused, nothing written.
    local MISS, nMISS = _G[CORE .. "SkelNative_SetObjectivesMissing"], CORE .. "SkelNative_SetObjectivesMissing"
    if check(type(MISS) == "function", "CASE %sobj-missing-native %s exists (core's test-only DLL test/SkelNative)", P, nMISS) then
        local m2 = spawnManager(-50500)
        if check(m2 ~= nil, "CASE %sobj-spawn-2 spawned a second ObjectiveManager_C", P) then
            local p2 = pathOf(m2)
            ours[p2] = true
            local fm = intFn(MISS)
            for _, key in ipairs(OBJ_KEYS) do
                case(P .. "obj-missing-" .. key, nMISS .. "(\"" .. key .. "\", <unfilled manager>, ...)", fm(key, p2, "NN Area", "nn_a", "Task A text"),
                    eS("member " .. key .. " (name prefix '" .. key .. "_') is missing from "))
            end
            case(P .. "obj-missing-key", nMISS .. "(\"Nope\", ...)", fm("Nope", p2, "A", "a", "t"), E.err(nMISS .. ": unknown member key 'Nope'"))
            case(P .. "obj-missing-nowrite", nDESC .. "(<the manager after the forced misses>)", fd(p2),
                described(function(d) return d.objectives == 0 and #d.tasks == 0 end, "objectives 0: nothing was written"))
            case(P .. "obj-missing-control", nSET .. "(<the same manager>, ...) [control: the real fill works]", fs(p2, "NN Area", "nn_a", "Task A text"),
                E.ret("1", function(r) return r.n == 1 and r[1] == 1 end))
            pcall(function() m2:K2_DestroyActor() end)
        end
    end

    -- A destroyed manager: K2_DestroyActor flags it Garbage; its path may still resolve until the next GC.
    local m3 = spawnManager(-51000)
    if check(m3 ~= nil, "CASE %sobj-spawn-3 spawned a third ObjectiveManager_C", P) then
        local p3 = pathOf(m3)
        ours[p3] = true
        m3:K2_DestroyActor()
        m3 = nil
        local gone = E.errAny({ p3 .. " is being destroyed", "no object at " .. p3 })
        case(P .. "obj-set-destroyed", nSET .. "(<manager destroyed just now>, ...)", fs(p3, "A", "a", "t"), gone)
        case(P .. "obj-desc-destroyed", nDESC .. "(<manager destroyed just now>)", fd(p3), gone)
        case(P .. "obj-trait-destroyed", nTRAIT .. "(<manager destroyed just now>, id, true)", ft(p3, "a", true), gone)
    end

    -- The game's own managers in this map: the readback works on them (logged, not judged).
    for _, a in ipairs(FindAllOf(OBJ_SHORT) or {}) do
        local okP, ap = pcall(pathOf, a)
        if okP and not ours[ap] and not ap:find("Default__", 1, true) then
            local okD, text = pcall(DESC, ap)
            say("OBJECTIVES %s stock manager %s: %s", phase, ap, okD and (tostring(text):gsub("\n", " | ")) or ("error: " .. firstLine(text)))
            break
        end
    end
    pcall(function() m:K2_DestroyActor() end)
end

-- Off the game thread (inside offThreadCases' LoopAsync): every objectives native refuses, whatever it is given.
objectivesOffThreadCases = function(P)
    local SET, DESC, TRAIT = native("_SetObjectives"), native("_DescribeObjectives"), native("_SetTraitorTaskState")
    local nSET, nDESC, nTRAIT = CORE .. "_SetObjectives", CORE .. "_DescribeObjectives", CORE .. "_SetTraitorTaskState"
    if type(SET) ~= "function" or type(DESC) ~= "function" or type(TRAIT) ~= "function" then
        check(false, "CASE %soff-obj the objectives natives are missing", P)
        return
    end
    case(P .. "off-obj-set", nSET .. "(path, area, id, text) [off thread]", function() return SET(OBJ_MISSING, "A", "a", "t") end, E.err(nSET .. " refused: called off the game thread"))
    case(P .. "off-obj-set-bad", nSET .. "(nil) [off thread]", function() return SET(nil) end, E.err(nSET .. " refused: called off the game thread"))
    case(P .. "off-obj-desc", nDESC .. "(path) [off thread]", function() return DESC(OBJ_MISSING) end, E.err(nDESC .. " refused: called off the game thread"))
    case(P .. "off-obj-desc-bad", nDESC .. "() [off thread]", function() return DESC() end, E.err(nDESC .. " refused: called off the game thread"))
    case(P .. "off-obj-trait", nTRAIT .. "(path, id, true) [off thread]", function() return TRAIT(OBJ_MISSING, "a", true) end, E.err(nTRAIT .. " refused: called off the game thread"))
    case(P .. "off-obj-trait-bad", nTRAIT .. "(1, 2, 3) [off thread]", function() return TRAIT(1, 2, 3) end, E.err(nTRAIT .. " refused: called off the game thread"))
end

-- Map service story 17: core's M.alive (lua/pkg/map/setup.lua) against real UE4SS values. The module is loaded in this
-- Lua state with require, so the exact shipped function runs (it requires only .version and .ref and registers nothing
-- at load). Each case first proves its input is the kind it names, else it fails as "input wasn't a <kind> (type=...)".
-- The out array's entry is touched only by type() and alive: never compared, unwrapped or kept. Nothing here outlives
-- the step.
local KSL_CDO_PATH = "/Script/Engine.Default__KismetSystemLibrary"
local KSL_ISVALID_PATH = "/Script/Engine.KismetSystemLibrary:IsValid"
local function u4type(v)
    if type(v) ~= "userdata" then return false, type(v) end
    local ok, t = pcall(function() return v:type() end)
    return ok, ok and tostring(t) or ("err:" .. firstLine(t))
end
-- fetch() -> the input; kind(v) -> true or the reason it isn't that kind. Returns the case function.
local function aliveOf(SETUP, kindName, fetch, kind)
    return function()
        local v = fetch()
        local okK, why = kind(v)
        if not okK then error(string.format("input wasn't a %s (type=%s)", kindName, tostring(why))) end
        return SETUP.alive(v)
    end
end
local function wrapperKind(name)
    return function(v)
        local ok, t = u4type(v)
        if ok and t == name then return true end
        return false, t
    end
end
local function aliveCases(phase)
    local P = phase .. ".alive-"
    local okS, SETUP = pcall(require, CORE:lower() .. ".map.setup")
    if not check(okS and type(SETUP) == "table" and type(SETUP.alive) == "function",
        "CASE %smodule %s.map.setup loaded in this state with an alive function (%s)", P, CORE:lower(), okS and type(SETUP) or firstLine(SETUP)) then
        return
    end
    local refused = E.ret("false", function(r) return r.n == 1 and r[1] == false end)
    local live = E.ret("true", function(r) return r.n == 1 and r[1] == true end)
    local function world() local p = pc() return valid(p) and p:GetWorld() or nil end
    -- a missing member: UE4SS's placeholder, a userdata whose type() raises (a TrivialObject)
    case(P .. "trivial", "alive(pc()[\"Found Player2\"]) [missing member]", aliveOf(SETUP, "missing member's placeholder",
        function() return pc()["Found Player2"] end,
        function(v)
            if type(v) ~= "userdata" then return false, type(v) end
            local ok, t = u4type(v)
            if ok then return false, t end
            return true
        end), refused)
    case(P .. "struct", "alive(pc().ControlRotation) [struct value]", aliveOf(SETUP, "UScriptStruct",
        function() return pc().ControlRotation end, wrapperKind("UScriptStruct")), refused)
    case(P .. "tarray", "alive(world.GameState.PlayerArray) [array]", aliveOf(SETUP, "TArray",
        function() return world().GameState.PlayerArray end, wrapperKind("TArray")), refused)
    case(P .. "remote", "alive(GetAllActorsOfClass(world, PlayerController, out) out[1]) [out-array entry]", aliveOf(SETUP, "RemoteUnrealParam",
        function()
            local out = {}
            GS():GetAllActorsOfClass(world(), StaticFindObject("/Script/Engine.PlayerController"), out)
            return out[1]
        end, wrapperKind("RemoteUnrealParam")), refused)
    case(P .. "nil", "alive(nil)", aliveOf(SETUP, "nil", function() return nil end, function(v) return v == nil, type(v) end), refused)
    case(P .. "num", "alive(1)", aliveOf(SETUP, "number", function() return 1 end, function(v) return type(v) == "number", type(v) end), refused)
    case(P .. "str", "alive(\"x\")", aliveOf(SETUP, "string", function() return "x" end, function(v) return type(v) == "string", type(v) end), refused)
    case(P .. "table", "alive({})", aliveOf(SETUP, "table", function() return {} end, function(v) return type(v) == "table", type(v) end), refused)
    case(P .. "actor", "alive(pc()) [AActor]", aliveOf(SETUP, "AActor", function() return pc() end, wrapperKind("AActor")), live)
    case(P .. "class", "alive(pc():GetClass()) [UClass]", aliveOf(SETUP, "UClass", function() return pc():GetClass() end, wrapperKind("UClass")), live)
    case(P .. "func", "alive(KismetSystemLibrary:IsValid) [UFunction]", aliveOf(SETUP, "UFunction",
        function() return StaticFindObject(KSL_ISVALID_PATH) end, wrapperKind("UFunction")), live)
    case(P .. "world", "alive(pc():GetWorld()) [UWorld]", aliveOf(SETUP, "UWorld", function() return world() end, wrapperKind("UWorld")), live)
    case(P .. "obj", "alive(KismetSystemLibrary's CDO) [UObject]", aliveOf(SETUP, "UObject",
        function() return StaticFindObject(KSL_CDO_PATH) end, wrapperKind("UObject")), live)
end

-- ---------------------------------------------------------------- versioning (story 18)
-- connect's need (AC 5: each bad one refused at once with one clean line, false + the message, onFail once, no raise),
-- core.has and core.features (AC 4), the compatibility rule on this core (AC 1-3, through the client's own message
-- builder; the floor case passes a floor of 0.3.0 as a test build would), and a deprecated op (AC 8: works, and logs
-- one DEPRECATED line per dependent per session; check.ps1 counts it across both worlds).
-- The bad-need connects use a probe mod name, so their lines aren't the test dependent's; none of them gets far
-- enough to start a connect loop.
local PROBE = ME .. "Need"
local featuresLogged = false
local function versionCases(phase)
    local P = phase .. "."
    local function probe(opts)
        return function()
            local calls, got = 0, nil
            if type(opts) == "table" then opts.onFail = function(m) calls = calls + 1; got = m end end
            local ok, msg = client.connect(opts)
            return ok, msg, calls, got
        end
    end
    -- false, "<text>... <probe> will not run.", onFail called once with the same message (without the tail)
    local function refused(text)
        return E.ret("false, '..." .. text .. "... will not run.', onFail once", function(r)
            return r[1] == false and type(r[2]) == "string" and r[2]:find(text, 1, true) ~= nil
                and r[2]:find(" will not run.", 1, true) ~= nil and r[3] == 1 and type(r[4]) == "string" and r[2]:sub(1, #r[4]) == r[4]
        end)
    end
    local NB = "connect: need "
    case(P .. "ver-need-missing", "connect{ mod, no need }", probe({ mod = PROBE }), refused(NB .. "must be a string like '>=0.5.0', got nil"))
    case(P .. "ver-need-empty", "connect{ need = '' }", probe({ mod = PROBE, need = "" }), refused(NB .. "'' is empty"))
    case(P .. "ver-need-ge", "connect{ need = '>=' }", probe({ mod = PROBE, need = ">=" }), refused(NB .. "'>=' is not a minimum version"))
    case(P .. "ver-need-gex", "connect{ need = '>=x' }", probe({ mod = PROBE, need = ">=x" }), refused(NB .. "'>=x' is not a minimum version"))
    case(P .. "ver-need-short", "connect{ need = '>=1.2' }", probe({ mod = PROBE, need = ">=1.2" }), refused(NB .. "'>=1.2' is not a minimum version"))
    case(P .. "ver-need-lt", "connect{ need = '<0.3.0' }", probe({ mod = PROBE, need = "<0.3.0" }), refused(NB .. "'<0.3.0' is not a minimum version"))
    case(P .. "ver-need-tilde", "connect{ need = '~0.3.0' }", probe({ mod = PROBE, need = "~0.3.0" }), refused(NB .. "'~0.3.0' is not a minimum version"))
    case(P .. "ver-need-300", "connect{ need = <300 chars> }", probe({ mod = PROBE, need = ">=" .. string.rep("9", 298) }), refused("is 300 bytes, cap 64"))
    case(P .. "ver-need-num", "connect{ need = 3 }", probe({ mod = PROBE, need = 3 }), refused(NB .. "must be a string like '>=0.5.0', got number"))
    case(P .. "ver-need-table", "connect{ need = {} }", probe({ mod = PROBE, need = {} }), refused(NB .. "must be a string like '>=0.5.0', got table"))
    case(P .. "ver-need-space", "connect{ need = '>= 0.3.0' }", probe({ mod = PROBE, need = ">= 0.3.0" }), refused(NB .. "'>= 0.3.0' is not a minimum version"))
    case(P .. "ver-need-10digits", "connect{ need = '>=1234567890.0.0' }", probe({ mod = PROBE, need = ">=1234567890.0.0" }), refused("is not a minimum version"))
    case(P .. "ver-opts-nil", "connect(nil)", function() return client.connect(nil) end,
        E.ret("false, 'connect{ ... } needs a table ...'", function(r) return r[1] == false and tostring(r[2]):find("needs a table with a string mod, got nil", 1, true) ~= nil end))
    case(P .. "ver-opts-mod-num", "connect{ mod = 5 }", probe({ mod = 5, need = ">=0.1.0" }),
        E.ret("false, '... got table with mod number', onFail once", function(r) return r[1] == false and tostring(r[2]):find("got table with mod number", 1, true) ~= nil and r[3] == 1 end))

    -- AC 1-3 on this core: the client's own message builder (nil = compatible).
    local function compat(need, floor) return function() return client._compatMessage(core.version, need, PROBE, floor) end end
    for i, need in ipairs({ ">=0.1.0", ">=0.2.0", ">=0.3.0", ">=" .. core.version, "^0.2.0", "^0.3.0", "0.2.0", "0.3.0" }) do
        case(P .. "ver-accept-" .. i, "compatible(" .. need .. ") [core " .. tostring(core.version) .. "]", compat(need, "0.1.0"), E.nilret)
    end
    local OLD = string.format("%s %s is older than %s needs (", CORE, tostring(core.version), PROBE)
    case(P .. "ver-core-old", "compatible(>=99.0.0)", compat(">=99.0.0", "0.1.0"), E.ret("'" .. OLD .. ">=99.0.0). Update " .. CORE .. ".'", function(r) return r[1] == OLD .. ">=99.0.0). Update " .. CORE .. "." end))
    case(P .. "ver-core-old-caret", "compatible(^99.0.0)", compat("^99.0.0", "0.1.0"), E.ret("'" .. OLD .. "^99.0.0). Update " .. CORE .. ".'", function(r) return r[1] == OLD .. "^99.0.0). Update " .. CORE .. "." end))
    local FL = string.format("%s was made for %s >=0.2.0, which this %s %s no longer supports (oldest: 0.3.0). Update %s.", PROBE, CORE, CORE, tostring(core.version), PROBE)
    case(P .. "ver-floor", "compatible(>=0.2.0) [floor 0.3.0]", compat(">=0.2.0", "0.3.0"), E.ret("'" .. FL .. "'", function(r) return r[1] == FL end))

    -- AC 4: core.has and core.features.
    local function has(...) local a = table.pack(...) return function() return core.has(table.unpack(a, 1, a.n)) end end
    local isTrue = E.ret("true", function(r) return r.n == 1 and r[1] == true end)
    local isFalse = E.ret("false", function(r) return r.n == 1 and r[1] == false end)
    local okF, list = pcall(core.features)
    local listed = okF and type(list) == "table" and #list > 0
    check(listed, "CASE %s core.features() -> %s (expected a non-empty list)", P .. "ver-features", okF and tostring(type(list)) or ("error: " .. firstLine(list)))
    if listed then
        for _, name in ipairs(list) do case(P .. "ver-has-" .. name, "core.has('" .. name .. "')", has(name), isTrue) end
        local okD, declared = pcall(function() return require(CORE:lower() .. ".features").declared() end)
        case(P .. "ver-features-declared", "core.features() == the READY line's list", function() return table.concat(list, ",") end,
            E.ret(okD and table.concat(declared, ",") or "declared() failed", function(r) return okD and r[1] == table.concat(declared, ",") end))
        case(P .. "ver-features-copy", "core.features() returns a fresh table", function()
            local a = core.features(); a[1] = "changed"; a[#a + 1] = "extra"
            return table.concat(core.features(), ",")
        end, E.ret("the list unchanged", function(r) return r[1] == table.concat(list, ",") end))
        if not featuresLogged then featuresLogged = true; say("FEATURES %s", table.concat(list, ",")) end
    end
    for _, n in ipairs({ "ui.text", "ui.panel", "ui.button", "ui.journal", "call", "ref" }) do
        case(P .. "ver-has-known-" .. n, "core.has('" .. n .. "') [AC 4 names]", has(n), isTrue)
    end
    case(P .. "ver-has-unknown", "core.has('ui.nosuch')", has("ui.nosuch"), isFalse)
    case(P .. "ver-has-fn", "core.has('ui.text.create') [a function of a module is not a feature]", has("ui.text.create"), isFalse)
    case(P .. "ver-has-num", "core.has(42)", has(42), isFalse)
    case(P .. "ver-has-empty", "core.has('')", has(""), isFalse)
    case(P .. "ver-has-300", "core.has(<300 chars>)", has(string.rep("u", 300)), isFalse)
    case(P .. "ver-has-nil", "core.has(nil)", has(nil), isFalse)
    case(P .. "ver-has-none", "core.has()", has(), isFalse)
    case(P .. "ver-has-table", "core.has({})", has({}), isFalse)
    -- Distribution story 13: nucleus.modid, a pure module dependents load with require (the rule and its messages are
    -- checked offline by test/unit/modid_test.lua on the shared cases; here: it loads in a dependent's state and never
    -- raises on bad input).
    do
        local okM, MID = pcall(require, CORE:lower() .. ".modid")
        check(okM and type(MID) == "table" and type(MID.normalize) == "function", "CASE %s require('%s.modid') -> %s (expected the module)",
            P .. "modid-require", CORE:lower(), okM and type(MID) or ("error: " .. firstLine(MID)))
        if okM and type(MID) == "table" and type(MID.normalize) == "function" then
            local function norm(...) local a = table.pack(...) return function() return MID.normalize(table.unpack(a, 1, a.n)) end end
            local function refused(msg) return E.ret("nil, '" .. msg .. "'", function(r) return r[1] == nil and r[2] == msg end) end
            case(P .. "modid-nil", "modid.normalize(nil)", norm(nil), refused(MID.ERR.type))
            case(P .. "modid-none", "modid.normalize()", norm(), refused(MID.ERR.type))
            case(P .. "modid-num", "modid.normalize(5)", norm(5), refused(MID.ERR.type))
            case(P .. "modid-table", "modid.normalize({})", norm({}), refused(MID.ERR.type))
            case(P .. "modid-10k", "modid.normalize(<10 kB>)", norm(string.rep("a", 10240)), refused(MID.ERR.long))
            case(P .. "modid-prefix", "modid.normalize('github.com/')", norm("github.com/"), refused(MID.ERR.bare))
            case(P .. "modid-ok", "modid.normalize('GitHub.com/NuclearNightmare-Community.Nucleus')", norm("GitHub.com/NuclearNightmare-Community.Nucleus"),
                E.ret("'nuclearnightmare-community.nucleus'", function(r) return r[1] == "nuclearnightmare-community.nucleus" end))
        end
    end
    case(P .. "ver-has-bool", "core.has(true)", has(true), isFalse)
    case(P .. "ver-has-skip", "core.has('version') [data, not a feature]", has("version"), isFalse)

    -- AC 8: the test-only deprecated op still works (answered like "version"), twice per world.
    for i = 1, 2 do
        case(P .. "ver-deprecated-" .. i, "call(\"deprecated-test\")", function() return core.call("deprecated-test") end,
            E.ret("true, version", function(r) return r[1] == true and r[2] == core.version end))
    end
end

-- ---------------------------------------------------------------- settings service (Mod Manager story 5)
-- core.settings and the channel ops settings-get / settings-set with bad values (the story's matrix row "Bad calls"),
-- in both worlds, plus the windows (test.mode is a "menu" setting: allowed at menu1, locked in match1; test.lobby is
-- always locked in v1). This mod's folder is <Core>SkelTest; its mod.json declares the seven test.* settings. Every
-- value a case changes is put back, except test.mode (b, set at menu1), test.boot (77, the restart case) and
-- test.count (42, set by <Core>SkelPeer): check.ps1 reads them from settings.json after the run.
SETS.REV = CORE:lower() .. ".settings.rev"
SETS.WATCHING = CORE:lower() .. ".test.settings.watching" -- test-only cue for SkelPeer (1: watcher registered)
SETS.PEER_AT = CORE:lower() .. ".test.settings.peerAt"   -- test-only: <Core>_ClockMicros() when SkelPeer set it
SETS.PEER = CORE .. "SkelPeer"
-- Core story 22: core.net's bad-input cases and the pair-run roles net-host / net-client (net.lua next to this file;
-- kept in a field: main.lua is at the 200-locals limit).
SETS.NET = dofile(scriptDir .. "\\net.lua")({ case = case, E = E, step = step, check = check, say = say, CORE = CORE,
    core = function() return core end, intFn = intFn, pc = pc, valid = valid })
-- Core story 23: player presence's bad-input cases and the pair-run roles presence-host / presence-client /
-- presence-vanilla-host (presence.lua next to this file).
SETS.PRES = dofile(scriptDir .. "\\presence.lua")({ case = case, E = E, step = step, check = check, say = say, CORE = CORE,
    core = function() return core end, intFn = intFn, pc = pc, valid = valid })
function SETS.cases(phase)
    local P = phase .. "."
    local ST = core.settings
    if type(ST) ~= "table" then check(false, "CASE %s core.settings is missing", P .. "set") return end
    local FN = CORE:lower() .. ".settings."
    local f = intFn
    local function isTrue(r) return r[1] == true end
    case(P .. "set-get-ok", "settings.get('test.flag') [control]", f(ST.get)("test.flag"), E.ret("false (the default)", function(r) return r[1] == false end))
    case(P .. "set-get-nil", "settings.get(nil)", f(ST.get)(nil), E.err(FN .. "get: key must be a string, got nil"))
    case(P .. "set-get-num", "settings.get(42)", f(ST.get)(42), E.err(FN .. "get: key must be a string, got number"))
    case(P .. "set-get-table", "settings.get({})", f(ST.get)({}), E.err(FN .. "get: key must be a string, got table"))
    case(P .. "set-get-empty", "settings.get('')", f(ST.get)(""), E.err(FN .. "get: key '' must be 1 to 64 bytes"))
    case(P .. "set-get-unknown", "settings.get('nope')", f(ST.get)("nope"), E.err(FN .. "get: unknown key 'nope'"))
    case(P .. "set-get-preset", "settings.get('test.preset') [read-only]", f(ST.get)("test.preset"), E.nilret)
    case(P .. "set-getall-ok", "settings.getAll()", f(ST.getAll)(), E.ret("a table with test.count", function(r) return type(r[1]) == "table" and math.type(r[1]["test.count"]) == "integer" end))
    case(P .. "set-getall-arg", "settings.getAll(1)", f(ST.getAll)(1), E.err(FN .. "getAll: takes no arguments"))
    case(P .. "set-set-unknown", "settings.set('nope', 1)", f(ST.set)("nope", 1), E.err(FN .. "set: unknown key 'nope'"))
    case(P .. "set-set-keynum", "settings.set(5, 1)", f(ST.set)(5, 1), E.err(FN .. "set: key must be a string, got number"))
    case(P .. "set-set-float", "settings.set('test.count', 2.5)", f(ST.set)("test.count", 2.5), E.err(FN .. "set: bad value: test.count must be an integer"))
    case(P .. "set-set-61", "settings.set('test.count', 61)", f(ST.set)("test.count", 61), E.err(FN .. "set: bad value: test.count must be from 1 to 60"))
    case(P .. "set-set-enum-x", "settings.set('test.mode', 'x')", f(ST.set)("test.mode", "x"), E.err(FN .. "set: bad value: test.mode must be one of a|b|c"))
    case(P .. "set-set-nan", "settings.set('test.ratio', 0/0)", f(ST.set)("test.ratio", 0 / 0), E.err(FN .. "set: value must be finite"))
    case(P .. "set-set-inf", "settings.set('test.ratio', math.huge)", f(ST.set)("test.ratio", math.huge), E.err(FN .. "set: value must be finite"))
    case(P .. "set-set-bool-str", "settings.set('test.flag', 'yes')", f(ST.set)("test.flag", "yes"), E.err(FN .. "set: bad value: test.flag must be true or false"))
    case(P .. "set-set-nilval", "settings.set('test.flag', nil)", f(ST.set)("test.flag", nil), E.err(FN .. "set: value must be a boolean, number or string, got nil"))
    case(P .. "set-set-table", "settings.set('test.flag', {})", f(ST.set)("test.flag", {}), E.err(FN .. "set: value must be a boolean, number or string, got table"))
    case(P .. "set-set-three", "settings.set('test.flag', true, 1)", f(ST.set)("test.flag", true, 1), E.err(FN .. "set: takes 2 arguments"))
    case(P .. "set-set-readonly", "settings.set('test.preset', 3)", f(ST.set)("test.preset", 3), E.callErr("read-only "))
    case(P .. "set-set-lobby", "settings.set('test.lobby', true)", f(ST.set)("test.lobby", true), E.callErr("locked "))
    case(P .. "set-set-flag-ok", "settings.set('test.flag', true)", f(ST.set)("test.flag", true), E.ret("true", isTrue))
    case(P .. "set-get-flag", "settings.get('test.flag') after the set", f(ST.get)("test.flag"), E.ret("true", isTrue))
    case(P .. "set-set-flag-back", "settings.set('test.flag', false)", f(ST.set)("test.flag", false), E.ret("true", isTrue))
    case(P .. "set-set-ratio-ok", "settings.set('test.ratio', 1.25)", f(ST.set)("test.ratio", 1.25), E.ret("true", isTrue))
    case(P .. "set-set-ratio-back", "settings.set('test.ratio', 0.5)", f(ST.set)("test.ratio", 0.5), E.ret("true", isTrue))
    if phase == "menu1" then
        case(P .. "set-set-menu", "settings.set('test.mode', 'b') [title screen]", f(ST.set)("test.mode", "b"), E.ret("true", isTrue))
    else
        case(P .. "set-set-menu", "settings.set('test.mode', 'c') [match]", f(ST.set)("test.mode", "c"), E.callErr("locked "))
    end
    case(P .. "set-watch-nil", "settings.watch(nil)", f(ST.watch)(nil), E.err(FN .. "watch: expected a function, got nil"))
    case(P .. "set-watch-str", "settings.watch('f')", f(ST.watch)("f"), E.err(FN .. "watch: expected a function, got string"))
    case(P .. "set-unwatch-str", "settings.unwatch('1')", f(ST.unwatch)("1"), E.err(FN .. "unwatch: token must be an integer, got string"))
    case(P .. "set-unwatch-float", "settings.unwatch(1.5)", f(ST.unwatch)(1.5), E.err(FN .. "unwatch: token must be an integer, got float"))
    case(P .. "set-unwatch-unknown", "settings.unwatch(987654)", f(ST.unwatch)(987654), E.ret("false", function(r) return r[1] == false end))
    case(P .. "set-watch-ok", "settings.watch(fn) then unwatch(token)", function()
        local t = ST.watch(function() end)
        return ST.unwatch(t)
    end, E.ret("true", isTrue))
    case(P .. "set-describe-dots", "settings.describe('..\\\\x')", f(ST.describe)("..\\x"), E.err(FN .. "describe: folder '..\\x' must match"))
    case(P .. "set-describe-65", "settings.describe(<65 chars>)", f(ST.describe)(string.rep("a", 65)), E.err(FN .. "describe: folder '"))
    case(P .. "set-describe-nil", "settings.describe(nil)", f(ST.describe)(nil), E.err(FN .. "describe: folder must be a string, got nil"))
    case(P .. "set-describe-unknown", "settings.describe('NoSuchModXyz')", f(ST.describe)("NoSuchModXyz"),
        E.ret("nil, 'unknown-mod ...'", function(r) return r[1] == nil and type(r[2]) == "string" and r[2]:find("^unknown%-mod ") ~= nil end))
    case(P .. "set-describe-core", "settings.describe('" .. CORE .. "') [no settings]", f(ST.describe)(CORE),
        E.ret("nil, 'no-settings ...'", function(r) return r[1] == nil and type(r[2]) == "string" and r[2]:find("^no%-settings ") ~= nil end))
    case(P .. "set-describe-own", "settings.describe('" .. ME .. "')", f(ST.describe)(ME), E.ret("7 settings, test.preset read-only", function(r)
        local d = r[1]
        return type(d) == "table" and d.folder == ME and #d.settings == 7 and d.settings[7].key == "test.preset" and d.settings[7].readOnly == true
            and d.settings[7].value == nil and d.settings[1].key == "test.flag"
    end))
    case(P .. "set-setfor-dots", "settings.setFor('..\\\\x', 'a', 1)", f(ST.setFor)("..\\x", "a", 1), E.err(FN .. "setFor: folder '..\\x' must match"))
    case(P .. "set-setfor-65", "settings.setFor(<65 chars>, 'a', 1)", f(ST.setFor)(string.rep("a", 65), "a", 1), E.err(FN .. "setFor: folder '"))
    case(P .. "set-setfor-unknown", "settings.setFor('NoSuchModXyz', 'a', 1)", f(ST.setFor)("NoSuchModXyz", "a", 1), E.err(FN .. "setFor: unknown-mod "))
    case(P .. "set-setfor-core", "settings.setFor('" .. CORE .. "', 'a', 1)", f(ST.setFor)(CORE, "a", 1), E.err(FN .. "setFor: no-settings "))
    case(P .. "set-setfor-peer-99", "settings.setFor('" .. SETS.PEER .. "', 'peer.level', 99)", f(ST.setFor)(SETS.PEER, "peer.level", 99),
        E.err(FN .. "setFor: bad value: peer.level must be from 1 to 9"))
    case(P .. "set-setfor-num", "settings.setFor(5, 'a', 1)", f(ST.setFor)(5, "a", 1), E.err(FN .. "setFor: folder must be a string, got number"))
    -- The ops through core.call (dependents' path) and straight on the class default object.
    case(P .. "ch-set-get-num", "call('settings-get', 42)", function() return core.call("settings-get", 42) end, E.callErr("err:unknown-mod 42"))
    case(P .. "ch-set-get-table", "call('settings-get', {})", function() return core.call("settings-get", {}) end, E.callErr("err:bad-request payload must be"))
    local cdo = found(ACTOR_CDO)
    if not cdo then check(false, "CASE %s channel class default object not found", P .. "chd-set") return end
    local CALL = CORE .. "_Call"
    local function direct(req) return function() local v = cdo[CALL](cdo, req) if type(v) == "userdata" then return v:ToString() end return v end end
    case(P .. "chd-set-get-none", CALL .. "(\"settings-get\") [direct]", direct("settings-get"), E.reply("err:bad-request "))
    case(P .. "chd-set-get-empty", CALL .. "(\"settings-get:\") [direct]", direct("settings-get:"), E.reply("err:bad-request "))
    case(P .. "chd-set-get-dots", CALL .. "(\"settings-get:..\\\\x\") [direct]", direct("settings-get:..\\x"), E.reply("err:bad-request folder must match"))
    case(P .. "chd-set-get-slash", CALL .. "(\"settings-get:a/b\") [direct]", direct("settings-get:a/b"), E.reply("err:bad-request "))
    case(P .. "chd-set-get-65", CALL .. "(\"settings-get:\"..<65 chars>) [direct]", direct("settings-get:" .. string.rep("a", 65)), E.reply("err:bad-request "))
    case(P .. "chd-set-get-unknown", CALL .. "(\"settings-get:NoSuchModXyz\") [direct]", direct("settings-get:NoSuchModXyz"), E.reply("err:unknown-mod NoSuchModXyz"))
    case(P .. "chd-set-get-core", CALL .. "(\"settings-get:" .. CORE .. "\") [direct]", direct("settings-get:" .. CORE), E.reply("err:no-settings "))
    case(P .. "chd-set-get-own", CALL .. "(\"settings-get:" .. ME .. "\") [direct]", direct("settings-get:" .. ME), E.reply("ok:{\"id\":"))
    case(P .. "chd-set-set-none", CALL .. "(\"settings-set\") [direct]", direct("settings-set"), E.reply("err:bad-request "))
    case(P .. "chd-set-set-brace", CALL .. "(\"settings-set:{\") [direct]", direct("settings-set:{"), E.reply("err:bad-request payload: 1:1 unterminated object"))
    case(P .. "chd-set-set-array", CALL .. "(\"settings-set:[]\") [direct]", direct("settings-set:[]"), E.reply("err:bad-request payload must be a JSON object"))
    case(P .. "chd-set-set-deep", CALL .. "(\"settings-set:\"..<40 x '['>) [direct]", direct("settings-set:" .. string.rep("[", 40)), E.reply("err:bad-request payload: "))
    case(P .. "chd-set-set-long", CALL .. "(\"settings-set:\"..<4100 bytes>) [direct]", direct("settings-set:" .. string.rep("{", 4100)), E.reply("err:too-long 4113 bytes, cap 4096"))
    case(P .. "chd-set-set-dup", CALL .. "(<duplicate key>) [direct]", direct('settings-set:{"mod":"' .. ME .. '","key":"test.flag","key":"x","value":true}'), E.reply("err:bad-request payload: "))
    case(P .. "chd-set-set-nomod", CALL .. "(<no mod>) [direct]", direct('settings-set:{"key":"test.flag","value":true}'), E.reply("err:bad-request mod must be a string"))
    case(P .. "chd-set-set-dots", CALL .. "(<mod ..\\\\x>) [direct]", direct('settings-set:{"mod":"..\\\\x","key":"a","value":1}'), E.reply("err:bad-request mod must match"))
    case(P .. "chd-set-set-novalue", CALL .. "(<value null>) [direct]", direct('settings-set:{"mod":"' .. ME .. '","key":"test.flag","value":null}'), E.reply("err:bad-request value must be"))
    case(P .. "chd-set-set-unknownkey", CALL .. "(<unknown key>) [direct]", direct('settings-set:{"mod":"' .. ME .. '","key":"nope","value":1}'), E.reply("err:unknown-key 'nope' in " .. ME))
    case(P .. "chd-set-set-badvalue", CALL .. "(<test.count 61>) [direct]", direct('settings-set:{"mod":"' .. ME .. '","key":"test.count","value":61}'), E.reply("err:bad-value test.count must be from 1 to 60"))
    case(P .. "chd-set-set-nan", CALL .. "(<value NaN>) [direct]", direct('settings-set:{"mod":"' .. ME .. '","key":"test.ratio","value":NaN}'), E.reply("err:bad-request payload: "))
    case(P .. "chd-set-set-readonly", CALL .. "(<test.preset>) [direct]", direct('settings-set:{"mod":"' .. ME .. '","key":"test.preset","value":1}'), E.reply("err:read-only test.preset"))
    case(P .. "chd-set-set-unknownmod", CALL .. "(<mod NoSuchModXyz>) [direct]", direct('settings-set:{"mod":"NoSuchModXyz","key":"a","value":1}'), E.reply("err:unknown-mod "))
    local garbage = {}
    for i = 1, 200 do garbage[i] = string.char(math.random(1, 127)) end
    case(P .. "chd-set-set-garbage", CALL .. "(\"settings-set:\"..<200 random ASCII bytes>) [direct]", direct("settings-set:" .. table.concat(garbage)), E.reply("err:"))
end

-- Mod Manager story 5 AC 1: SkelPeer (another Lua state) changes this mod's int setting at the menu; this mod's
-- watcher must see the new value within 1 s, with the revision one higher. SkelPeer waits for the cue SETS.WATCHING.
function SETS.crossState(phase)
    step(phase .. ": settings cross-state", function()
        local X = { rev0 = math.tointeger(ModRef:GetSharedVariable(SETS.REV)) }
        S.setx = X
        X.token = core.settings.watch(function(k, v)
            if k ~= "test.count" or X.seen then return end
            local at = math.tointeger(ModRef:GetSharedVariable(SETS.PEER_AT))
            local now = native("_ClockMicros")()
            X.seen = { v = v, dt = at and (now - at) or nil, rev = math.tointeger(ModRef:GetSharedVariable(SETS.REV)) }
            say("SETWATCH %s key=%s value=%s dt_ms=%s rev=%s", phase, k, tostring(v), X.seen.dt and string.format("%.0f", X.seen.dt / 1000) or "?", tostring(X.seen.rev))
        end)
        ModRef:SetSharedVariable(SETS.WATCHING, 1)
        say("SETX %s watching (rev %s); cue for %s set", phase, tostring(X.rev0), SETS.PEER)
        return function() return X.seen ~= nil end, 20, "SkelPeer's setFor reaching this watcher"
    end)
    step(phase .. ": settings cross-state checks", function()
        local X = S.setx
        local s = X.seen or {}
        check(s.v == 42, "SETX %s watcher saw test.count=42 (got %s)", phase, tostring(s.v))
        check(s.dt ~= nil and s.dt <= 1000000, "SETX %s within 1 s of the peer's set (%s ms)", phase, s.dt and string.format("%.0f", s.dt / 1000) or "?")
        check(X.rev0 ~= nil and s.rev == X.rev0 + 1, "SETX %s rev rose by one (%s -> %s)", phase, tostring(X.rev0), tostring(s.rev))
        local okG, g = pcall(core.settings.get, "test.count")
        check(okG and g == 42, "SETX %s get('test.count') = 42 (%s)", phase, tostring(g))
        pcall(core.settings.unwatch, X.token)
        ModRef:SetSharedVariable(SETS.WATCHING, 2)
    end)
end

-- A restart setting: saved, but get keeps the session's value and describe shows pendingRestart (menu1); still so in
-- match1.
function SETS.restart(phase)
    step(phase .. ": settings restart", function()
        local P = phase .. "."
        local ST = core.settings
        local function bootEntry()
            local d = ST.describe(ME)
            for _, e in ipairs(d.settings) do if e.key == "test.boot" then return e end end
        end
        if phase == "menu1" then
            case(P .. "set-restart", "settings.set('test.boot', 77) [restart]", function() return ST.set("test.boot", 77) end, E.ret("true", function(r) return r[1] == true end))
        end
        case(P .. "set-restart-get", "settings.get('test.boot') [restart, saved 77]", function() return ST.get("test.boot") end, E.ret("10 (the session's value)", function(r) return r[1] == 10 end))
        case(P .. "set-restart-pending", "describe('" .. ME .. "') test.boot", function() local e = bootEntry() return e.value, e.pendingRestart, e.saved end,
            E.ret("10, true, 77", function(r) return r[1] == 10 and r[2] == true and r[3] == 77 end))
    end)
end

-- Off the game thread (called inside offThreadCases' LoopAsync block): every core.settings function refuses.
function SETS.offThread(P)
    local ST = core.settings
    if type(ST) ~= "table" then return end
    for _, fn in ipairs({ "get", "getAll", "set", "setFor", "describe", "watch", "unwatch" }) do
        case(P .. "off-set-" .. fn:lower(), "settings." .. fn .. "(...) [off thread]", function() return ST[fn]("test.flag", true, 1) end,
            E.err(CORE:lower() .. ".settings." .. fn .. ": called off the game thread"))
    end
end

local function badInputCases(phase)
    step(phase .. ": versioning cases", function() versionCases(phase) end)
    step(phase .. ": native cases", function() nativeCases(phase) end)
    step(phase .. ": channel cases", function() channelCases(phase) end)
    step(phase .. ": ui cases", function() uiCases(phase) end)
    step(phase .. ": objectives cases", function() objectivesCases(phase) end)
    -- Map service story 9: the map setup signal, read from this Lua state (menu1 and the stock SmallMap: none).
    step(phase .. ": map signal case", function()
        case(phase .. ".map-signal", "GetSharedVariable(\"" .. SETUP_KEY .. "\") [" .. phase .. "]", readSignal, E.signalNone)
    end)
    step(phase .. ": alive cases", function() aliveCases(phase) end)
    -- Mod Manager story 5: the settings service. At menu1 first the cross-state change (SkelPeer -> this watcher),
    -- before any own set moves the revision.
    if phase == "menu1" then SETS.crossState(phase) end
    step(phase .. ": settings cases", function() SETS.cases(phase) end)
    SETS.restart(phase)
    SETS.NET.badInput(phase) -- core story 22
    SETS.PRES.badInput(phase) -- core story 23
    SETS.GAME.cases(phase) -- core story 31
    SETS.INS.cases(phase) -- core story 32
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
    SETS.GAME.preConnect() -- core story 31
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

-- ---- story 14 helpers: panels. A panel widget is WBP_<Core>Panel_C, tagged in its CoreTag variable; its children sit
-- in its VBox (vertical) or HBox (horizontal). Screen rectangles come from core's geometry functions on ModActor's CDO.
local PANEL_SHORT = "WBP_" .. CORE .. "Panel_C"
local BUTTON_SHORT = "WBP_" .. CORE .. "Button_C"
local function clsOf(o) local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end) return ok and n or "?" end
-- The tag of any core widget (text: ToolTipText; panel and button: CoreTag), or nil.
local function tagOfWidget(c)
    local k = clsOf(c)
    local ok, t
    if k == TEXT_SHORT then ok, t = pcall(function() return c.ToolTipText:ToString() end)
    elseif k == PANEL_SHORT or k == BUTTON_SHORT then ok, t = pcall(function() return c.CoreTag:ToString() end) end
    return ok and t or nil
end
-- Our widgets for one id among a container's children (any core class): the first and how many.
local function taggedIn(container, id)
    local tag = core.ui.text.tagOf(id)
    local first, n = nil, 0
    for i = 0, container:GetChildrenCount() - 1 do
        local c = container:GetChildAt(i)
        if valid(c) and tagOfWidget(c) == tag then n = n + 1; first = first or c end
    end
    return first, n
end
-- The element ids of a box's children, in order ("a,b,c").
local function boxIds(box)
    local t = {}
    for i = 0, box:GetChildrenCount() - 1 do
        local c = box:GetChildAt(i)
        local tag = valid(c) and tagOfWidget(c)
        t[#t + 1] = tag and tag:match("[^:]+$") or "?"
    end
    return table.concat(t, ",")
end
-- Screen rectangle (desktop pixels) from Slate's cached geometry, or nil.
local function absR(w)
    local cdo = found(ACTOR_CDO)
    if not (cdo and valid(w)) then return nil end
    local ok, r = pcall(function()
        local a, b = cdo[CORE .. "_AbsTopLeft"](cdo, w), cdo[CORE .. "_AbsBottomRight"](cdo, w)
        return { l = a.X, t = a.Y, r = b.X, b = b.Y }
    end)
    return ok and r or nil
end
local function rsA(r) return r and string.format("(%.0f,%.0f)-(%.0f,%.0f)", r.l, r.t, r.r, r.b) or "?" end
local function scaleOf() local hud = core.ui.hud.find() return hud and WLL():GetViewportScale(hud:GetWorld()) or 1 end
local function nearPx(a, b) return math.abs(a - b) <= 1.5 end
-- The live HUD's panel widget for an id (one expected), its box, and the children's rectangles by id.
local function hudPanel(id)
    local hud = core.ui.hud.find()
    if not hud then return nil, 0 end
    return taggedIn(hud.OwningCanvas, id)
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
        if not check(hits ~= nil, "UIOVERLAP match1 'xcross' could be checked (%s)", hits and "yes" or tostring(UIS.xWhy)) then return end
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

    -- Story 14: panels on the HUD. AC 1: a vertical panel in the top-right corner (it stacks under 'pre') with three
    -- texts; AC 4: a horizontal one bottom-left. Kept until match2 (AC 3: the rebuild and the map change below).
    local PN = function() return core.ui.panel end
    step("match1: panels", function()
        UIS.pv = PN().create{ id = "pv", place = { corner = "top-right" } }
        UIS.pv1 = uiCreate("pv1", { text = "panel one", place = { panel = UIS.pv } })
        UIS.pv2 = uiCreate("pv2", { text = "panel two, longer", place = { panel = UIS.pv } })
        UIS.pv3 = uiCreate("pv3", { text = "panel three", place = { panel = UIS.pv } })
        UIS.ph = PN().create{ id = "ph", place = { corner = "bottom-left" }, layout = "horizontal", style = { background = "dark" } }
        for i = 1, 3 do UIS["ph" .. i] = uiCreate("ph" .. i, { text = "h" .. i, place = { panel = UIS.ph } }) end
        return afterMs(1500), 3, "panel layout"
    end)
    -- Rectangles of a panel's children, in screen pixels, by id.
    local function kids(pw, ids)
        local box = pw.VBox
        local out = {}
        for _, id in ipairs(ids) do local w = taggedIn(box, id) out[id] = w and absR(w) end
        return out
    end
    step("match1: panel check", function()
        local pw, n = hudPanel("pv")
        if not check(pw ~= nil and n == 1, "UIPANEL match1 'pv' has exactly one widget in the HUD canvas (found %d, class %s)", n, pw and clsOf(pw) or "?") then return end
        local box = pw.VBox
        local _, n1 = taggedIn(box, "pv1"); local _, n2 = taggedIn(box, "pv2"); local _, n3 = taggedIn(box, "pv3")
        check(boxIds(box) == "pv1,pv2,pv3" and n1 == 1 and n2 == 1 and n3 == 1 and pw.HBox:GetChildrenCount() == 0,
            "UIPANEL match1 the three texts sit in its VBox in creation order (%s), one widget each", boxIds(box))
        local s = scaleOf()
        local P_, r = absR(pw), kids(pw, { "pv1", "pv2", "pv3" })
        local inside = P_ and r.pv1 and r.pv3 and r.pv1.t >= P_.t and r.pv3.b <= P_.b + 0.5 and r.pv1.l >= P_.l and r.pv2.r <= P_.r + 0.5
        check(r.pv1 and r.pv2 and r.pv3 and nearPx(r.pv2.t, r.pv1.b + 8 * s) and nearPx(r.pv3.t, r.pv2.b + 8 * s),
            "UIPANEL match1 shown in order, top to bottom, 8 units (tight) apart: %s %s %s (scale %.3f)", rsA(r.pv1), rsA(r.pv2), rsA(r.pv3), s)
        local col, pad = pw.Background.BrushColor, pw.Background.Padding
        check(inside and near(col.A, 0.35) and near(pad.Left, 8) and P_ and nearPx(r.pv1.t, P_.t + 8 * s),
            "UIPANEL match1 one dim box around all three: panel %s brush alpha %.2f padding %.0f", rsA(P_), col.A, pad.Left)
        local pre = widgetOf("pre")
        local rp = pre and absR(pre)
        check(rp and P_ and nearPx(P_.t, rp.b + 16 * s) and nearPx(P_.r, rp.r), "UIPANEL match1 the panel stacks under 'pre' in the top-right corner, 16 apart: pre %s panel %s", rsA(rp), rsA(P_))
        check(PN().isShown(UIS.pv) and T().isShown(UIS.pv2), "UIPANEL match1 isShown: the panel and its children")
        -- AC 4: left to right
        local hw, hn = hudPanel("ph")
        if check(hw ~= nil and hn == 1, "UIHPANEL match1 'ph' has exactly one widget (found %d)", hn) then
            local hb = hw.HBox
            local h1, h2, h3 = absR(taggedIn(hb, "ph1")), absR(taggedIn(hb, "ph2")), absR(taggedIn(hb, "ph3"))
            check(boxIds(hb) == "ph1,ph2,ph3" and h1 and h2 and h3 and nearPx(h2.l, h1.r + 8 * s) and nearPx(h3.l, h2.r + 8 * s) and nearPx(h1.t, h3.t),
                "UIHPANEL match1 a horizontal panel lays its children out left to right, 8 apart: %s %s %s", rsA(h1), rsA(h2), rsA(h3))
        end
        PN().remove(UIS.ph)
        local okR, errR = pcall(T().isShown, UIS.ph2)
        check(select(2, hudPanel("ph")) == 0 and not okR and firstLine(errR):find("handle 'ph2' was removed", 1, true) ~= nil,
            "UIPREMOVE match1 removing a panel removes its children: no widget left, a child's handle raises (%s)", firstLine(errR))
        -- AC 2: hide the middle child: the gap closes
        T().setVisible(UIS.pv2, false)
        return afterMs(1000), 3, "layout"
    end)
    step("match1: panel hide child", function()
        local pw = hudPanel("pv")
        local s = scaleOf()
        local r = kids(pw, { "pv1", "pv3" })
        local w2 = taggedIn(pw.VBox, "pv2")
        check(r.pv1 and r.pv3 and nearPx(r.pv3.t, r.pv1.b + 8 * s) and w2 and tonumber(w2:GetVisibility()) == 1 and T().isShown(UIS.pv2) == false,
            "UIPHIDE match1 hiding the middle child closes the gap: pv1 %s pv3 %s, pv2 collapsed", rsA(r.pv1), rsA(r.pv3))
        T().setVisible(UIS.pv2, true)
        PN().setVisible(UIS.pv, false)
        check(PN().isShown(UIS.pv) == false and T().isShown(UIS.pv1) == false and T().isShown(UIS.pv2) == false and T().isShown(UIS.pv3) == false
            and tonumber(pw:GetVisibility()) == 1, "UIPHIDE match1 hiding the panel hides all three (panel collapsed, isShown false)")
        PN().setVisible(UIS.pv, true)
        -- AC 6: reorder
        UIS.pvW = {}
        for _, id in ipairs({ "pv1", "pv2", "pv3" }) do UIS.pvW[id] = pathOf(taggedIn(pw.VBox, id)) end
        UIS.created0 = uiStats().attachCreated
        PN().move(UIS.pv, UIS.pv3, 1)
        return afterMs(1000), 3, "layout"
    end)
    step("match1: panel reorder", function()
        local pw = hudPanel("pv")
        local s = scaleOf()
        local r = kids(pw, { "pv1", "pv2", "pv3" })
        check(boxIds(pw.VBox) == "pv3,pv1,pv2" and r.pv3 and r.pv1 and r.pv2 and nearPx(r.pv1.t, r.pv3.b + 8 * s) and nearPx(r.pv2.t, r.pv1.b + 8 * s),
            "UIPORDER match1 move(panel, third, 1) shows the third first: %s; %s %s %s", boxIds(pw.VBox), rsA(r.pv3), rsA(r.pv1), rsA(r.pv2))
        PN().setOrder(UIS.pv, { UIS.pv2, UIS.pv1, UIS.pv3 })
        local o = PN().order(UIS.pv)
        check(boxIds(pw.VBox) == "pv2,pv1,pv3" and #o == 3 and rawequal(o[1], UIS.pv2) and rawequal(o[2], UIS.pv1) and rawequal(o[3], UIS.pv3),
            "UIPORDER match1 setOrder with the reversed list reverses them, and order() returns the new order (%s)", boxIds(pw.VBox))
        local same = true
        for _, id in ipairs({ "pv1", "pv2", "pv3" }) do if pathOf(taggedIn(pw.VBox, id)) ~= UIS.pvW[id] then same = false end end
        check(same and uiStats().attachCreated == UIS.created0, "UIPORDER match1 the same three widgets (no new widget: created %d -> %d)", UIS.created0, uiStats().attachCreated)
        local c0 = uiStats().uobjectCalls
        PN().setOrder(UIS.pv, { UIS.pv2, UIS.pv1, UIS.pv3 })
        PN().move(UIS.pv, UIS.pv1, 2)
        check(uiStats().uobjectCalls == c0, "UINOOP match1 an unchanged order made %d UObject calls", uiStats().uobjectCalls - c0)
        return afterMs(1000), 3, "layout"
    end)
    step("match1: panel reorder layout", function()
        local pw = hudPanel("pv")
        local s = scaleOf()
        local r = kids(pw, { "pv1", "pv2", "pv3" })
        check(r.pv2 and r.pv1 and r.pv3 and nearPx(r.pv1.t, r.pv2.b + 8 * s) and nearPx(r.pv3.t, r.pv1.b + 8 * s),
            "UIPORDER match1 shown reversed: %s %s %s", rsA(r.pv2), rsA(r.pv1), rsA(r.pv3))
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
        -- Story 14 AC 3: the panel and its children back, reused, in the same order, one widget each.
        local pw, pn = hudPanel("pv")
        local ones = pw and select(2, taggedIn(pw.VBox, "pv1")) == 1 and select(2, taggedIn(pw.VBox, "pv2")) == 1 and select(2, taggedIn(pw.VBox, "pv3")) == 1
        check(pw ~= nil and pn == 1 and ones and boxIds(pw.VBox) == "pv2,pv1,pv3" and pathOf(taggedIn(pw.VBox, "pv1")) == UIS.pvW.pv1,
            "UIPREBUILD match1 after RemoveAllWidgets and re-add: one panel widget (%d), children reused in the same order (%s)", pn, pw and boxIds(pw.VBox) or "?")
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
        say("UISTATS elements=%d created=%d reused=%d freed=%d uobjectCalls=%d panelRebuilds=%s", s.elements, s.attachCreated, s.attachReused, s.handlesFreed, s.uobjectCalls, tostring(s.panelRebuilds))
        -- Story 14 AC 3: after the map change the panel is back with its children in the same order, one widget each.
        local pw, pn = hudPanel("pv")
        local ones = pw and select(2, taggedIn(pw.VBox, "pv1")) == 1 and select(2, taggedIn(pw.VBox, "pv2")) == 1 and select(2, taggedIn(pw.VBox, "pv3")) == 1
        check(pw ~= nil and pn == 1 and ones and boxIds(pw.VBox) == "pv2,pv1,pv3" and core.ui.panel.isShown(UIS.pv),
            "UIPMAP match2 after the map change: one panel widget (%d), its children in the same order (%s), one widget each", pn, pw and boxIds(pw.VBox) or "?")
        core.ui.panel.remove(UIS.pv)
        local okR, errR = pcall(T().set, UIS.pv1, "x")
        check(select(2, hudPanel("pv")) == 0 and not okR and firstLine(errR):find("handle 'pv1' was removed", 1, true) ~= nil,
            "UIPREMOVE match2 removing the panel removes all three (%s)", firstLine(errR))
        T().remove(UIS.pre); T().remove(UIS.hid)
        core.ui.hud.unwatch(UIS.thrower)
        core.ui.hud.unwatch(UIS.recorder)
        check(uiStats().elements == 0, "UICLEAN match2 every element removed")
    end)
end

-- ---------------------------------------------------------------- journal (story 13, unattended)
-- The Journal's map page as a host. menu -> match, Enter at touchdown, the lobby countdown cut to 2 s (the map key
-- works only once the game has started), then the map opened and closed with the REAL map key ten times: the key
-- IA_Map is bound to (read from IMC_Default) goes to run.ps1 as "key <letter>", which posts it to the game window, so
-- the game's own input path opens it. Each open must be a new Journal_C with exactly one widget per element in the
-- map page's canvas; the first open also logs the Journal's widget tree (which canvas is the map page). Then a death
-- and revive (the game's own, V8.1.5+: a real kill, then the radio's reinforcement of the dead body; JR.jRevive), a map
-- change, a GC count of live core widgets, and the cost lines. Never keeps a Journal or widget across steps.
local JOURNAL_CLASS_PATH = "/Game/Graphics/Journal/Journal.Journal_C"
local JEV = { list = {}, count = {} }
local JS = { seen = {}, opens = 0, keyOpens = 0, attach = {}, steps = {} }
-- One text top-right, and a panel bottom-right holding two buttons (story 13 AC 6's panel with two buttons and a
-- text; story 15). Every open clicks jb1 through the OS (story 15 AC 5: every click runs once).
local J_IDS = { "jt", "jpanel", "jb1", "jb2" }
local J_TOP = { "jt", "jpanel" }       -- in the map canvas
local J_KIDS = { "jb1", "jb2" }        -- in jpanel's VBox
local OPENS = 10

local function jrecorder(j, info)
    JEV.list[#JEV.list + 1] = { event = info.event, reason = info.reason, path = info.path, page = info.page }
    JEV.count[info.event] = (JEV.count[info.event] or 0) + 1
    if info.event == "opened" then JS.openedAt = core.clock.micros() end
    say("JEVENT %d %s reason=%s page=%s journal=%s", #JEV.list, info.event, tostring(info.reason), tostring(info.page), tostring(info.path))
    if info.event == "opened" then JS.first = JS.rgn and JS.firstFrame(j) or nil end
end
local function jcount(e) return JEV.count[e] or 0 end

local function mapCanvasOf(j)
    local ok, c = pcall(function() return j.MapWidget.WidgetTree.RootWidget end)
    return ok and valid(c) and c or nil
end
local function cls(o) local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end) return ok and n or "?" end
local function absRect(w)
    local cdo = found(ACTOR_CDO)
    if not (cdo and valid(w)) then return "?" end
    local ok, s = pcall(function()
        local a, b = cdo[CORE .. "_AbsTopLeft"](cdo, w), cdo[CORE .. "_AbsBottomRight"](cdo, w)
        return string.format("(%.0f,%.0f)-(%.0f,%.0f)", a.X, a.Y, b.X, b.Y)
    end)
    return ok and s or "?"
end

-- Story 19: the Journal regions as the test measures them itself, in the host canvas's units, through core's
-- <Core>_RectIn: every region's widget reached the way the story names it (binder: the union of the two papers).
local RG = { "ammo", "binder", "cover", "map", "map-header", "match", "page-left", "page-right", "tasks" }
-- Content-sized regions: measured after the first paint, collapsed until then (story 20: map is computed before it).
local RG_MEASURED = { ["map-header"] = true, match = true, tasks = true, ammo = true }
-- Story 20: elements on exact regions and the computed map, attached in the Journal's Construct: drawn before the poll
-- sees the Journal, so shown with a valid drawn rect at the opened event.
local RG_FIRST = { "jn", "jc", "jr-cover", "jr-binder", "jr-page-left", "jr-page-right", "jr-map" }
local RG_TEXT = { ammo = "A", binder = "B", cover = "C", map = "M", ["map-header"] = "H", match = "P", ["page-left"] = "L", ["page-right"] = "R", tasks = "T" }
local function rectIn(canvas, w)
    local cdo = found(ACTOR_CDO)
    if not (cdo and valid(canvas) and valid(w)) then return nil end
    local ok, r = pcall(function()
        local fn = cdo[CORE .. "_RectIn"]
        local a, b = fn(cdo, canvas, w, { X = 0, Y = 0 }), fn(cdo, canvas, w, { X = 1, Y = 1 })
        return { l = a.X, t = a.Y, r = b.X, b = b.Y }
    end)
    return ok and r or nil
end
local function regionWidget(mw, name)
    if name == "cover" then return mw.NN_BinderCover end
    if name == "page-left" then return mw.NN_LeftFieldPaper end
    if name == "page-right" then return mw.NN_RightFieldPaper end
    if name == "map" then return mw.MapUI end
    if name == "ammo" then return mw.NN_AmmoCarbonBacking end
    if name == "map-header" then return mw.TextBlock_86:GetParent():GetParent() end
    if name == "match" then return mw.StackBox_1:GetParent():GetParent() end
    if name == "tasks" then return mw.GraphicsScroll:GetParent():GetParent():GetParent() end
end
local function regionRects(j, canvas)
    local out = {}
    local okM, mw = pcall(function() return j.MapWidget end)
    if not (okM and valid(mw)) then return out end
    for _, name in ipairs(RG) do
        if name ~= "binder" then
            local ok, w = pcall(regionWidget, mw, name)
            out[name] = ok and valid(w) and rectIn(canvas, w) or nil
        end
    end
    local L, R = out["page-left"], out["page-right"]
    if L and R then out.binder = { l = L.l, t = math.min(L.t, R.t), r = R.r, b = math.max(L.b, R.b) } end
    return out
end
local function rvalid(r) return r ~= nil and r.r - r.l > 1 and r.b - r.t > 1 end
-- Story 20, at the opened event: which RG_FIRST elements are shown with a valid drawn rect (a field, not a local: the
-- main chunk is near Lua's locals limit).
JS.firstFrame = function(j)
    local canvas = j and mapCanvasOf(j)
    local out = { good = 0, bad = {} }
    for _, id in ipairs(RG_FIRST) do
        local ew = canvas and taggedIn(canvas, id)
        local r = ew and rectIn(canvas, ew)
        if JS.rgn[id] and core.ui.text.isShown(JS.rgn[id]) and rvalid(r) then out.good = out.good + 1
        else out.bad[#out.bad + 1] = string.format("%s shown=%s rect=%s", id, tostring(JS.rgn[id] and core.ui.text.isShown(JS.rgn[id])), rsA(r)) end
    end
    return out
end
local function w1(a, b) return a ~= nil and b ~= nil and math.abs(a - b) <= 1 end

-- The game state's lobby countdown, cut to 2 s on this (listen server) host: the character opens the map only when
-- LobbyMinutes and LobbySeconds are both 0.
local function lobbyOver(phase)
    step(phase .. ": end the lobby", function()
        local gs = GS():GetGameState(pc())
        if not valid(gs) then check(false, "LOBBY %s game state found", phase) return end
        local m, s = gs.LobbyMinutes, gs.LobbySeconds
        say("LOBBY %s countdown %s:%s; set to 0:02", phase, tostring(m), tostring(s))
        if (tonumber(m) or 0) > 0 or (tonumber(s) or 0) > 2 then pcall(function() gs.LobbyMinutes = 0; gs.LobbySeconds = 2 end) end
        return function()
            local g = GS():GetGameState(pc())
            return valid(g) and (tonumber(g.LobbyMinutes) or 1) <= 0 and (tonumber(g.LobbySeconds) or 1) <= 0
        end, 20, phase .. " lobby countdown over"
    end)
    step(phase .. ": lobby settle", function() return after(3), 5, "settle" end)
end

-- The key IA_Map is bound to, from IMC_Default (a capital letter), else M.
local function readMapKey()
    step("map key", function()
        local key, all = nil, {}
        local ok, err = pcall(function()
            local imc = StaticFindObject("/Game/FirstPerson/Input/IMC_Default.IMC_Default")
            if not valid(imc) then error("IMC_Default not loaded") end
            imc.Mappings:ForEach(function(_, e)
                local m = e:get()
                local a = m.Action
                if valid(a) and pathOf(a):find("IA_Map.IA_Map", 1, true) then
                    local k = m.Key.KeyName:ToString()
                    all[#all + 1] = k
                    if not key and k:match("^[A-Z]$") then key = k end
                end
            end)
        end)
        JS.key = key or "M"
        say("MAPKEY %s (IA_Map keys in IMC_Default: %s%s)", JS.key, table.concat(all, ", "), ok and "" or ("; read failed: " .. firstLine(err)))
        check(key ~= nil, "MAPKEY IA_Map is bound to the letter %s in IMC_Default", JS.key)
    end)
end

-- Fallback when the key did nothing: the character's own open path, from Lua (decompile BP_FirstPersonCharacter_C
-- ~15040), so the rest of the run still has a Journal. A key failure is still a FAIL.
local function openViaLua()
    local c = pc()
    local p = c and c:K2_GetPawn()
    if not (valid(c) and valid(p)) then return false end
    local cls_ = found(JOURNAL_CLASS_PATH)
    local lib = StaticFindObject("/Script/NuclearNightmare.Default__NNPreparedWidgetLibrary")
    local ok = pcall(function()
        local j = lib:GetPreparedWidget(p, cls_, c)
        j.Controller = c; j.OpenWithMap = true; j.Character = p; p.Map = j
        j:AddToViewport(0)
        WBL():SetInputMode_GameAndUIEx(c, j, 0, false, true)
        c.bShowMouseCursor = true
    end)
    return ok
end
local function closeViaLua()
    local j = core.ui.journal.find()
    if not j then return end
    pcall(function()
        local c = pc()
        WBL():SetInputMode_GameOnly(c, true)
        c.bShowMouseCursor = false
        j:RemoveFromParent()
    end)
end

local function probeTree(phase, j)
    local ok, err = pcall(function()
        local root = j.WidgetTree.RootWidget
        say("JTREE %s journal=%s root=%s (%s) rect=%s", phase, pathOf(j), pathOf(root), cls(root), absRect(j))
        local sw = j.WidgetSwitcher_0
        local n = sw:GetChildrenCount()
        say("JTREE %s WidgetSwitcher_0 children=%d active=%d (%s) rect=%s", phase, n, sw:GetActiveWidgetIndex(), cls(sw:GetActiveWidget()), absRect(sw))
        for i = 0, n - 1 do local ch = sw:GetChildAt(i) say("JTREE %s   switcher child %d: %s (%s) rect=%s", phase, i, pathOf(ch):match("[^.:]+$"), cls(ch), absRect(ch)) end
        local m = j.MapWidget
        local mroot = m.WidgetTree.RootWidget
        local mn = mroot.GetChildrenCount and mroot:GetChildrenCount() or -1
        say("JTREE %s MapWidget=%s (%s) root=%s (%s) children=%d rect=%s", phase, pathOf(m):match("[^.:]+$"), cls(m), pathOf(mroot):match("[^.:]+$"), cls(mroot), mn, absRect(mroot))
        for i = 0, mn - 1 do local ch = mroot:GetChildAt(i) say("JTREE %s   map root child %d: %s (%s) rect=%s", phase, i, pathOf(ch):match("[^.:]+$"), cls(ch), absRect(ch)) end
        local okU, mu = pcall(function() return m.MapUI end)
        if okU and valid(mu) then say("JTREE %s MapUI=%s rect=%s", phase, cls(mu), absRect(mu)) end
    end)
    if not ok then say("JTREE %s failed: %s", phase, firstLine(err)) end
end

-- Story 14: one open's attach steps (journal.stats().attachSteps) as a line, and their averages over several opens.
local function stepsLine(s)
    if type(s) ~= "table" or type(s.items) ~= "table" then return "?" end
    local parts = { string.format("canvas %d", s.canvas or -1) }
    for _, it in ipairs(s.items) do
        parts[#parts + 1] = string.format("'%s' %d (create %d%s)", it.id, it.us, it.create, it.panel and (", in '" .. it.panel .. "'") or "")
    end
    parts[#parts + 1] = string.format("place %d", s.place or -1)
    return table.concat(parts, "; ")
end
local function stepsAvg(list)
    local n, canvas, place, by, order = 0, 0, 0, {}, {}
    for _, s in ipairs(list) do
        if type(s) == "table" and type(s.items) == "table" then
            n = n + 1
            canvas, place = canvas + s.canvas, place + s.place
            for _, it in ipairs(s.items) do
                if not by[it.id] then by[it.id] = { us = 0, create = 0, n = 0 }; order[#order + 1] = it.id end
                local b = by[it.id]
                b.us, b.create, b.n = b.us + it.us, b.create + it.create, b.n + 1
            end
        end
    end
    if n == 0 then return "none" end
    local parts = { string.format("canvas %.0f", canvas / n) }
    for _, id in ipairs(order) do
        local b = by[id]
        parts[#parts + 1] = string.format("'%s' %.0f (create %.0f)", id, b.us / b.n, b.create / b.n)
    end
    parts[#parts + 1] = string.format("place %.0f", place / n)
    return table.concat(parts, "; ")
end

-- One open: the map key (or Lua when asked), then the opened event; checks on the next steps.
local function openMap(phase, viaKey)
    step(phase .. ": open", function()
        JS.openedBefore = jcount("opened")
        if viaKey then
            say("JKEY %s pressing %s to open the map", phase, JS.key)
            return request("key " .. JS.key), 30, phase .. " map key served"
        end
        say("JOPEN %s through the game's own calls from Lua", phase)
        openViaLua()
    end)
    step(phase .. ": opened", function()
        return function() return jcount("opened") > JS.openedBefore end, 10, phase .. " opened event"
    end)
    step(phase .. ": opened check", function()
        local got = jcount("opened") > JS.openedBefore
        if viaKey then
            JS.keyOpens = JS.keyOpens + (got and 1 or 0)
            check(got, "JKEY %s the real %s key press opened the map (opened events %d -> %d)", phase, JS.key, JS.openedBefore, jcount("opened"))
            if not got then say("JOPEN %s falling back to the game's own calls from Lua", phase) openViaLua() return after(2), 5, "lua open" end
        end
    end)
    -- Story 19: once the region elements exist, poll (every 250 ms) until all are shown; a measured-region element
    -- must never be shown while the test's own reading of its region is still invalid (not painted).
    step(phase .. ": regions shown", function()
        if not JS.rgn then return end
        JS.rgnBad, JS.rgnShownUs, JS.rgnPolls = {}, nil, 0
        return function()
            local j = core.ui.journal.find()
            local canvas = j and mapCanvasOf(j)
            if not canvas then return false end
            JS.rgnPolls = JS.rgnPolls + 1
            local rr = regionRects(j, canvas)
            local all = true
            for id, region in pairs(JS.rgnOf) do
                local shown = core.ui.text.isShown(JS.rgn[id])
                if shown and RG_MEASURED[region] and not rvalid(rr[region]) then JS.rgnBad[#JS.rgnBad + 1] = id end
                if not shown then all = false end
            end
            if all then JS.rgnShownUs = core.clock.micros() - (JS.openedAt or 0) end
            return all
        end, 6, phase .. " region elements shown"
    end)
    step(phase .. ": regions shown check", function()
        if not JS.rgn then return end
        local f = JS.first
        check(f ~= nil and f.good == #RG_FIRST, "JRFIRST %s %d of %d exact- and map-region elements shown with a valid drawn rect at the opened event (drawn before the poll saw the Journal)%s",
            phase, f and f.good or 0, #RG_FIRST, f and #f.bad > 0 and (": " .. table.concat(f.bad, "; ")) or "")
        check(#JS.rgnBad == 0, "JRCOLLAPSE %s no content-sized-region element shown while its region was not painted (%d polls; shown early: %s)", phase, JS.rgnPolls, table.concat(JS.rgnBad, ","))
        local us = JS.rgnShownUs
        check(us ~= nil and us <= 2500000, "JRSHOWN %s every region element shown %.2f s after the opened event (within 2.5 s: 4 journal ticks of 500 ms plus one tick of poll jitter)", phase, (us or -1) / 1e6)
    end)
    step(phase .. ": settle", function() return afterMs(1200), 3, "layout" end)
    step(phase .. ": check", function()
        local j = core.ui.journal.find()
        if not check(j ~= nil and core.ui.journal.isOpen(), "JOPEN %s journal.find() and isOpen() see the open Journal", phase) then return end
        local p = pathOf(j)
        JS.opens = JS.opens + 1
        check(not JS.seen[p], "JNEW %s open %d is a new Journal_C instance (%s; %d distinct so far)", phase, JS.opens, p, (function() local n = 0 for _ in pairs(JS.seen) do n = n + 1 end return n end)())
        JS.seen[p] = true
        if JS.opens == 1 then probeTree(phase, j) end
        local canvas = mapCanvasOf(j)
        if not check(canvas ~= nil, "JCANVAS %s the map page's root canvas found", phase) then return end
        local all = true
        local counts = {}
        for _, id in ipairs(J_TOP) do
            local _, n = taggedIn(canvas, id)
            counts[#counts + 1] = id .. "=" .. n
            if n ~= 1 then all = false end
        end
        local pw = taggedIn(canvas, "jpanel")
        local box = pw and pw.VBox
        for _, id in ipairs(J_KIDS) do
            local n = box and select(2, taggedIn(box, id)) or 0
            counts[#counts + 1] = id .. "=" .. n
            if n ~= 1 then all = false end
        end
        check(all, "JONE %s one widget per element in the map canvas, the panel's two in its box (%s)", phase, table.concat(counts, " "))
        -- Story 14 AC 6: the panel's order on every open (a reorder made while open or closed shows on the next open).
        if box then
            check(boxIds(box) == JS.order, "JORDER %s the panel's children in the expected order %s (box: %s)", phase, JS.order, boxIds(box))
            check(core.ui.panel.isShown(JS.h.jpanel) and core.ui.button.isShown(JS.h.jb1) and core.ui.button.isShown(JS.h.jb2), "JPSHOWN %s the panel and its buttons are shown on the map", phase)
        end
        check(core.ui.text.isShown(JS.h.jt) == true, "JSHOWN %s 'jt' isShown=true while the map is open", phase)
        local w = taggedIn(canvas, "jt")
        if w then
            -- Story 19 (0.6.0): a plain journal corner is the cover's; checked on the drawn rect, in canvas units.
            local cover = regionRects(j, canvas).cover
            local r = rectIn(canvas, w)
            check(rvalid(cover) and rvalid(r) and w1(r.r, cover.r - 16) and w1(r.t, cover.t + 16) and w:IsVisible(),
                "JCORNER %s 'jt' in the cover's top-right, 16 inward: jt=%s cover=%s (canvas units) screen=%s canvas=%s", phase, rsA(r), rsA(cover), absRect(w), absRect(canvas))
        end
        -- Story 19: the region elements, once they exist (JREGION lines and checks, all within 1 canvas unit).
        if JS.rgn then
            local rr = regionRects(j, canvas)
            local cr = rectIn(canvas, canvas)
            say("JREGION %s canvas %s", phase, rsA(cr))
            for _, name in ipairs(RG) do say("JREGION %s region %s %s", phase, name, rsA(rr[name])) end
            local er = {}
            for id in pairs(JS.rgn) do
                local ew = taggedIn(canvas, id)
                er[id] = ew and rectIn(canvas, ew) or nil
                say("JREGION %s element %s %s", phase, id, rsA(er[id]))
            end
            local m, pl, n = rr.map, rr["page-left"], er.jn
            check(rvalid(m) and rvalid(pl) and rvalid(n) and w1(n.t, m.b + 8) and w1((n.l + n.r) / 2, (m.l + m.r) / 2)
                and n.l >= pl.l - 1 and n.r <= pl.r + 1 and n.t >= pl.t - 1 and n.b <= pl.b + 1,
                "JRNEAR %s 'jn' under the map square, centred, 8 below (jn=%s map=%s), inside page-left %s", phase, rsA(n), rsA(m), rsA(pl))
            local c, jc = rr.cover, er.jc
            check(rvalid(c) and rvalid(jc) and w1(jc.r, c.r - 16) and w1(jc.b, c.b - 16),
                "JRCOVER %s 'jc' at the cover's bottom-right - (16,16): jc=%s cover=%s", phase, rsA(jc), rsA(c))
            local good, bad = 0, {}
            for _, name in ipairs(RG) do
                local id, r, e = "jr-" .. name, rr[name], er["jr-" .. name]
                if rvalid(r) and rvalid(e) and w1(e.l, r.l + 8) and w1(e.t, r.t + 8) then good = good + 1
                else bad[#bad + 1] = string.format("%s=%s in %s", id, rsA(e), rsA(r)) end
            end
            check(good == #RG, "JRCORNERS %s %d of %d 'jr-<region>' texts at their region's top-left + (8,8)%s", phase, good, #RG, #bad > 0 and (": " .. table.concat(bad, "; ")) or "")
        end
        local st = core.ui.journal.stats()
        JS.attach[#JS.attach + 1] = st.attachLast
        JS.steps[#JS.steps + 1] = st.attachSteps
        say("JCOST %s attach of %d elements on this open: %d us (avg %.0f, max %d over %d opens); steps: %s", phase, st.attachElements, st.attachLast, st.attachAvg, st.attachMax, st.attachOpens, stepsLine(st.attachSteps))
    end)
end

-- Story 15 AC 5: one real click on jb1 per open, through the OS; its onClick must run exactly once.
local function jclick(phase)
    step(phase .. ": click", function()
        local j = core.ui.journal.find()
        local canvas = j and mapCanvasOf(j)
        local pw = canvas and taggedIn(canvas, "jpanel")
        local w = pw and taggedIn(pw.VBox, "jb1")
        local r = w and absR(w)
        JS.clickBefore = JS.clicks.jb1 or 0
        if not check(r ~= nil and r.r > r.l, "JPOINT %s 'jb1' has a screen rectangle %s", phase, rsA(r)) then return end
        local x, y = math.floor((r.l + r.r) / 2 + 0.5), math.floor((r.t + r.b) / 2 + 0.5)
        return request(string.format("click %d %d", x, y)), 40, phase .. " click served"
    end)
    step(phase .. ": click settle", function() return afterMs(800), 3, "click settle" end)
    step(phase .. ": click check", function()
        local n = JS.clicks.jb1 or 0
        check(n == JS.clickBefore + 1, "JCLICK %s a real click on 'jb1' ran its onClick exactly once (%d -> %d)", phase, JS.clickBefore, n)
    end)
end

-- Story 14: a reorder of the Journal's panel while the map is open (it applies at once) or closed (next open).
local function reorderJournal(phase, ids, open)
    step(phase .. ": reorder", function()
        local list = {}
        for i, id in ipairs(ids) do list[i] = JS.h[id] end
        core.ui.panel.setOrder(JS.h.jpanel, list)
        JS.order = table.concat(ids, ",")
        local o = core.ui.panel.order(JS.h.jpanel)
        local got = {}
        for i, h in ipairs(o) do got[i] = h.id end
        check(table.concat(got, ",") == JS.order, "JORDER %s order() returns %s after setOrder", phase, table.concat(got, ","))
        if open then
            local j = core.ui.journal.find()
            local canvas = j and mapCanvasOf(j)
            local pw = canvas and taggedIn(canvas, "jpanel")
            check(pw ~= nil and boxIds(pw.VBox) == JS.order, "JORDER %s applies while the map is open: box %s (expected %s)", phase, pw and boxIds(pw.VBox) or "?", JS.order)
        end
    end)
end

local function closeMap(phase, viaKey)
    step(phase .. ": close", function()
        JS.closedBefore = jcount("closed")
        if viaKey then
            say("JKEY %s pressing %s to close the map", phase, JS.key)
            return request("key " .. JS.key), 30, phase .. " map key served"
        end
        closeViaLua()
    end)
    step(phase .. ": closed", function()
        return function() return jcount("closed") > JS.closedBefore end, 10, phase .. " closed event"
    end)
    step(phase .. ": closed check", function()
        local got = jcount("closed") > JS.closedBefore
        if viaKey then
            check(got, "JKEY %s the real %s key press closed the map", phase, JS.key)
            if not got then closeViaLua() return after(2), 5, "lua close" end
        end
        check(core.ui.journal.isOpen() == false and core.ui.text.isShown(JS.h.jt) == false, "JCLOSED %s isOpen=false, 'jt' isShown=false", phase)
    end)
    step(phase .. ": pause", function() return afterMs(700), 3, "pause" end)
end

-- Counts live core text widgets of the journal elements (and live Journals), after a forced GC.
local function gcCount(phase)
    step(phase .. ": gc", function()
        StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
        return after(3), 6, "gc"
    end)
    step(phase .. ": gc count", function()
        local n, journals = 0, 0
        local mine = {}
        local ids = 0
        for _, id in ipairs(J_IDS) do mine[core.ui.text.tagOf(id)] = true; ids = ids + 1 end
        for id in pairs(JS.rgn or {}) do mine[core.ui.text.tagOf(id)] = true; ids = ids + 1 end
        for _, short in ipairs({ TEXT_SHORT, PANEL_SHORT, BUTTON_SHORT }) do
            for _, w in ipairs(FindAllOf(short) or {}) do
                if valid(w) and mine[tagOfWidget(w) or ""] then n = n + 1 end
            end
        end
        for _, j in ipairs(FindAllOf("Journal_C") or {}) do if valid(j) and not pathOf(j):find("Default__", 1, true) then journals = journals + 1 end end
        check(n <= ids, "JGC %s %d live journal element widget(s) after %d opens and a GC (at most %d: one Journal's worth); %d Journal_C alive",
            phase, n, JS.opens, ids, journals)
    end)
end

-- ---------------------------------------------------------------- journal: a real death and revive (V8.1.5+)
-- Ported from the workspace's mods/waypoints driver (README "The driver's kill (V8.1.5+)", its revive scenario). Since
-- V8.1.5 neither DeathEvent() nor the radio acts on a living character: DeathEvent's MoreDeathFX starts with the native
-- gate NNDeathFadeLibrary:CanBeginTerminalDeathEffects (false while Health > 0), and the radio's native
-- AdmitRadioCandidate checks the queued dead body. So, solo host: the game state's EOGLock holds the match (stands in
-- for a living teammate; else the last death ends it), one CallDamageEvent(1000) on the own pawn kills it, the game's
-- whole death runs (DIED right away; the controller's pawn becomes Spectator_C about 12 s later), then
-- BP_Radio_C:ReinforceSpecficPlayer(dead body) spawns and possesses a new character, as the computer's reinforcement
-- button does. Only if the character is still possessed after KILL_FALLBACK s does the test set Health 0 and call
-- DeathEvent itself (a FALLBACK line, not a check). EOGLock is released once the new pawn has a visible HUD.
-- One local table (the main chunk is at Lua's 200-local limit).
local JR = { KILL_FALLBACK = 30, KILL_TIMEOUT = 60, SPECTATOR = "Spectator_C" }
function JR.classOf(o) local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end) return ok and n or "?" end
function JR.myPawn() local c = pc() if not valid(c) then return nil end local p = c:K2_GetPawn() return valid(p) and p or nil end
function JR.hpOf(p) local ok, h = pcall(function() return p.Health end) return ok and tonumber(h) or nil end
-- NNDeathFadeLibrary:CanBeginTerminalDeathEffects called as a UFunction on the class default object: "true", "false",
-- "?" (not found) or "error".
function JR.deathGate(p)
    local nn = "/Script/NuclearNightmare."
    local lib, f = StaticFindObject(nn .. "Default__NNDeathFadeLibrary"), StaticFindObject(nn .. "NNDeathFadeLibrary:CanBeginTerminalDeathEffects")
    if not (valid(lib) and valid(f)) then return "?" end
    local ok, r = pcall(function() return f(lib, p) end)
    return ok and tostring(r) or "error"
end
function JR.holdMatch(phase, on)
    local okG, gs = pcall(function() return GS():GetGameState(pc()) end)
    local ok = okG and valid(gs) and pcall(function() gs.EOGLock = on end)
    say("SOLO %s EOGLock=%s ok=%s", phase, tostring(on), tostring(ok))
end
function JR.jRevive(phase)
    step(phase .. ": hold the match and kill", function()
        JR.holdMatch(phase, true)
        local target = JR.myPawn()
        if not target then check(false, "KILL %s the own pawn found", phase) return end
        JS.killed, JS.pawnBefore = pathOf(target), pathOf(target)
        JS.dying, JS.left = nil, nil
        local t0, stuck = os.clock(), false
        say("KILL %s before guard=%s hp=%s", phase, JR.deathGate(target), tostring(JR.hpOf(target)))
        local ok, err = pcall(function() target:CallDamageEvent(1000) end)
        say("KILL %s %s CallDamageEvent(1000) ok=%s %s", phase, JS.killed, tostring(ok), ok and "" or firstLine(err))
        return function()
            local t = os.clock() - t0
            if not JS.dying then
                local body = found(JS.killed)
                local g, h = body and JR.deathGate(body), body and JR.hpOf(body)
                if h and h <= 0 and g == "true" then JS.dying = t; say("DYING %s +%.1f s guard=%s hp=%s", phase, t, g, tostring(h)) end
            end
            local p = JR.myPawn()
            if p and pathOf(p) == JS.killed then
                if not stuck and t > JR.KILL_FALLBACK then
                    stuck = true
                    local body = found(JS.killed)
                    if body then
                        local okH = pcall(function() body.Health = 0 end)
                        local okD, eD = pcall(function() body:DeathEvent() end)
                        say("KILL %s FALLBACK still possessed after %.0f s: Health 0 (ok=%s) + DeathEvent ok=%s %s", phase, t, tostring(okH), tostring(okD), okD and "" or firstLine(eD))
                    end
                end
                return false
            end
            if not p then return false end -- between pawns
            JS.left = { t = t, class = JR.classOf(p), path = pathOf(p) }
            say("LEFT %s +%.1f s the controller's pawn is %s (%s) fallback=%s", phase, t, JS.left.class, JS.left.path, tostring(stuck))
            return true
        end, JR.KILL_TIMEOUT, phase .. " death (the controller leaves the character)"
    end)
    step(phase .. ": died", function()
        check(JS.dying ~= nil, "DIED %s the character took the game's death: Health <= 0 and the terminal-death gate open%s", phase,
            JS.dying and string.format(" (+%.1f s)", JS.dying) or "")
        local l = JS.left
        check(l ~= nil and l.class == JR.SPECTATOR, "SPECTATOR %s the controller's pawn became %s%s", phase, JR.SPECTATOR,
            l and string.format(" (%s at +%.1f s)", l.class, l.t) or " (it never left the character)")
    end)
    step(phase .. ": reinforce", function()
        local body = found(JS.killed)
        local radio = FindFirstOf("BP_Radio_C")
        if not (body and valid(radio)) then check(false, "REINFORCE %s dead body and radio found", phase) return end
        local okR, eR = pcall(function() radio:ReinforceSpecficPlayer(body) end)
        say("REINFORCE %s ReinforceSpecficPlayer(dead body %s) ok=%s %s", phase, JS.killed:match("[^.]+$"), tostring(okR), okR and "" or firstLine(eR))
        return function()
            local np = JR.myPawn()
            return np ~= nil and pathOf(np) ~= JS.pawnBefore and JR.classOf(np) ~= JR.SPECTATOR and core.ui.hud.isVisible()
        end, 90, phase .. ": a new pawn with a visible HUD"
    end)
    step(phase .. ": release the match", function()
        JR.holdMatch(phase, false)
        local np = JR.myPawn()
        say("NEWPAWN %s %s (was %s)", phase, np and pathOf(np) or "none", tostring(JS.pawnBefore))
        return after(3), 5, "settle"
    end)
end

local function buildJournal()
    step("journal: watch and create", function()
        UIS.t0 = os.time()
        UIS.jrec = core.ui.journal.watch(jrecorder)
        UIS.jthrow = core.ui.journal.watch(function() error("test journal watcher throws on purpose") end)
        JS.h = {}
        JS.h.jt = core.ui.text.create{ id = "jt", text = CORE .. " journal", place = { host = "journal", corner = "top-right" } }
        -- Story 19: the panel sits in the right page's bottom-right; the cover's bottom-right (a plain journal corner
        -- since 0.6.0) borders the perk strip, which no test element may cover.
        JS.h.jpanel = core.ui.panel.create{ id = "jpanel", place = { host = "journal", corner = "bottom-right", region = "page-right", inset = "tight" } }
        JS.clicks = {}
        for i, id in ipairs(J_KIDS) do
            JS.h[id] = core.ui.button.create{ id = id, label = "Button " .. i, place = { panel = JS.h.jpanel },
                onClick = function() JS.clicks[id] = (JS.clicks[id] or 0) + 1 end }
        end
        JS.order = table.concat(J_KIDS, ",")
        check(core.ui.text.isShown(JS.h.jt) == false and core.ui.journal.isOpen() == false, "JPENDING menu1 journal elements created, not shown (no Journal)")
    end)
    waitWorld("menu1", "NewMainMenu", 120)
    travel("match1", MATCH_MAP, "listen")
    waitWorld("match1", "SmallMap", 150)
    touchdown("match1")
    step("match1: hud", function() return function() return core.ui.hud.isVisible() end, 120, "match1 HUD visible" end)
    lobbyOver("match1")
    readMapKey()
    -- AC 1: ten opens and closes in a row, every one by the real key press.
    for i = 1, OPENS do
        openMap("open" .. i, true)
        if i == 1 then step("open1: shot", function() return request("shot journal-open1"), 30, "screenshot" end) end
        jclick("open" .. i)
        -- Story 14 AC 6: reversed while open 5 is open; kept on open 6; back while closed, shown on open 7.
        if i == 5 then
            reorderJournal("open5", { J_KIDS[2], J_KIDS[1] }, true)
            step("open5: shot", function() return request("shot journal-open5-reordered"), 30, "screenshot" end)
        end
        closeMap("close" .. i, true)
        if i == 6 then reorderJournal("close6", { J_KIDS[1], J_KIDS[2] }, false) end
    end
    step("opens: events", function()
        -- AC 3: opened and closed once per open and close.
        check(jcount("opened") == OPENS and jcount("closed") == OPENS and jcount("lost") == 0,
            "JEVENTS %d opens: opened=%d closed=%d lost=%d", OPENS, jcount("opened"), jcount("closed"), jcount("lost"))
        local max, sum = 0, 0
        for _, us in ipairs(JS.attach) do sum = sum + us; if us > max then max = us end end
        -- AC 6: under 2 ms per open (timing: judged on the host; reported in the VM).
        say("%s JCOSTS %d opens: attach avg %.0f us, max %d us (target under 2000 us per open)", max < 2000 and "OK" or "SLOW", #JS.attach, #JS.attach > 0 and sum / #JS.attach or 0, max)
        say("JSTEPS %d opens, average per step: %s", #JS.steps, stepsAvg(JS.steps))
    end)
    gcCount("opens")
    -- Story 19: the Journal regions, from here on checked on every open (revive, map change).
    step("regions: create", function()
        JS.rgn, JS.rgnOf = {}, {}
        JS.rgn.jn = core.ui.text.create{ id = "jn", text = CORE .. " under the map", place = { host = "journal", near = "map", side = "below", gap = "tight" } }
        JS.rgnOf.jn = "map"
        JS.rgn.jc = core.ui.text.create{ id = "jc", text = "jc", place = { host = "journal", corner = "bottom-right" } }
        JS.rgnOf.jc = "cover"
        for _, name in ipairs(RG) do
            local id = "jr-" .. name
            JS.rgn[id] = core.ui.text.create{ id = id, text = RG_TEXT[name], place = { host = "journal", corner = "top-left", region = name, inset = "tight" } }
            JS.rgnOf[id] = name
        end
        local k, shown = 0, {}
        for id, rh in pairs(JS.rgn) do
            k = k + 1
            if core.ui.text.isShown(rh) ~= false then shown[#shown + 1] = id end
        end
        check(#shown == 0, "JRPENDING the region elements are created while the map is closed (%d)%s", k, #shown > 0 and ("; shown: " .. table.concat(shown, ",")) or "")
    end)
    -- AC 2: a death and revive (the game's own, V8.1.5+), then the map again.
    JR.jRevive("revive")
    openMap("revive-open", true)
    jclick("revive-open")
    closeMap("revive-close", true)
    -- AC 2: a map change.
    travel("menu2", MENU_MAP, "")
    waitWorld("menu2", "NewMainMenu", 150)
    travel("match2", MATCH_MAP, "listen")
    waitWorld("match2", "SmallMap", 150)
    touchdown("match2")
    step("match2: hud", function() return function() return core.ui.hud.isVisible() end, 120, "match2 HUD visible" end)
    lobbyOver("match2")
    openMap("match2-open", true)
    jclick("match2-open")
    closeMap("match2-close", true)
    -- AC 4: the cost while the map is closed: wait for a one-minute tick window with the map closed.
    step("closed: tick window", function()
        JS.closedSince = os.time()
        say("JWAIT waiting 65 s with the map closed for a one-minute hud tick summary")
        return function() return os.time() >= JS.closedSince + 65 end, 80, "closed one-minute window"
    end)
    step("closed: report", function()
        local st = core.ui.hud.stats()
        local js = core.ui.journal.stats()
        say("JTICK ticks=%d poll avg=%.1f max=%d us, watchers avg=%.1f max=%d us; steady n=%d avg=%.1f max=%d us; journal tracked=%d opens=%d closes=%d lost=%d findAll=%d",
            st.ticks, st.pollAvg, st.pollMax, st.watchAvg, st.watchMax, st.steadyTicks, st.steadyAvg, st.steadyMax, js.tracked, js.opens, js.closes, js.lost, js.findAllCalls)
        check(js.tracked <= 1, "JTRACK while closed at most one Journal is tracked (%d)", js.tracked)
        check(jcount("opened") == OPENS + 2 and jcount("closed") == OPENS + 2, "JEVENTS all: opened=%d closed=%d lost=%d (expected %d each)", jcount("opened"), jcount("closed"), jcount("lost"), OPENS + 2)
        local distinct = 0
        for _ in pairs(JS.seen) do distinct = distinct + 1 end
        check(distinct == JS.opens, "JNEWALL %d opens, %d distinct Journal_C instances", JS.opens, distinct)
        check(JS.keyOpens == JS.opens, "JKEYALL %d of %d opens by the real %s key press", JS.keyOpens, JS.opens, JS.key)
        local bs = core.ui.button.stats()
        check((JS.clicks.jb1 or 0) == JS.opens and (JS.clicks.jb2 or 0) == 0 and bs.hookTries == 1,
            "JCLICKALL %d real clicks on 'jb1' over %d opens (a revive and a map change among them) ran its onClick %d time(s); 'jb2' %d; one hook (tries %d, clicks %d, dropped %d, debounced %d, ignored %d)",
            JS.opens, JS.opens, JS.clicks.jb1 or 0, JS.clicks.jb2 or 0, bs.hookTries, bs.clicks, bs.dropped, bs.debounced, bs.ignored)
        core.ui.text.remove(JS.h.jt)
        core.ui.panel.remove(JS.h.jpanel) -- and its children
        for _, rh in pairs(JS.rgn or {}) do core.ui.text.remove(rh) end
        core.ui.journal.unwatch(UIS.jthrow)
        core.ui.journal.unwatch(UIS.jrec)
    end)
    gcCount("end")
end

-- ---------------------------------------------------------------- ui, story 15: buttons on the Journal (unattended)
-- At the end of the ui scenario (match2): a panel with two buttons and a text on the Journal's map page, the map opened
-- by the real key, then real OS clicks (run.ps1 / vm-click "click x y" at each button's centre, from core's geometry
-- functions), Enter on a focused button, a throwing onClick, a disabled button, a button of the second test dependent
-- (<Core>SkelPeer), and two calls in a row. Each click is checked by the callback counts and the widget's own
-- ClickCount (the Blueprint saw it too).
local BS = { hits = {} }
local function bcount(id) return BS.hits[id] or 0 end
local function bhit(id) return function(h) BS.hits[id] = bcount(id) + 1; say("BHIT '%s' %d (handle %s)", id, BS.hits[id], tostring(h and h.id)) end end
local function mapCanvasNow() local j = core.ui.journal.find() return j and mapCanvasOf(j) end
local function inPanelOnMap(id)
    local canvas = mapCanvasNow()
    local pw = canvas and taggedIn(canvas, "bpanel")
    if not pw then return nil, 0 end
    return taggedIn(pw.VBox, id)
end
local function peerWidget()
    local canvas = mapCanvasNow()
    if not canvas then return nil end
    local want = CORE:lower() .. ":" .. CORE .. "SkelPeer:peer"
    for i = 0, canvas:GetChildrenCount() - 1 do
        local c = canvas:GetChildAt(i)
        if valid(c) and tagOfWidget(c) == want then return c end
    end
    return nil
end
local function clicksOf(w) local ok, n = pcall(function() return w.ClickCount end) return ok and tonumber(n) or -1 end
-- A real click on a widget's centre (finder() returns it), then a pause for the hook.
local function clickOn(phase, what, finder)
    step(phase .. ": click", function()
        local w = finder()
        local r = w and absR(w)
        if not check(r ~= nil and r.r > r.l, "BPOINT %s %s has a screen rectangle %s", phase, what, rsA(r)) then return end
        BS.wclicks = clicksOf(w)
        local x, y = math.floor((r.l + r.r) / 2 + 0.5), math.floor((r.t + r.b) / 2 + 0.5)
        say("BCLICKREQ %s clicking %s at (%d,%d), rectangle %s", phase, what, x, y, rsA(r))
        return request(string.format("click %d %d", x, y)), 40, phase .. " click served"
    end)
    step(phase .. ": settle", function() return afterMs(800), 3, "click settle" end)
end

local function buildButtons()
    local B = function() return core.ui.button end
    step("buttons: create", function()
        BS.p = core.ui.panel.create{ id = "bpanel", place = { host = "journal", corner = "bottom-right" } }
        BS.b1 = B().create{ id = "b1", label = "Button one", place = { panel = BS.p }, onClick = bhit("b1") }
        BS.b2 = B().create{ id = "b2", label = "Button two", place = { panel = BS.p }, onClick = function(h)
            BS.hits.b2 = bcount("b2") + 1
            say("BHIT 'b2' %d (handle %s)", BS.hits.b2, tostring(h and h.id))
            if BS.hits.b2 == 1 then error("b2 throws on its first click, on purpose") end
        end }
        BS.bt = core.ui.text.create{ id = "bt", text = "Nucleus buttons", place = { panel = BS.p } }
        local st = B().stats()
        check(st.hooked == true and st.hookTries == 1, "BHOOK match2 one click hook in this Lua state, registered at the first button.create (hooked=%s tries=%d)", tostring(st.hooked), st.hookTries)
        check(B().isShown(BS.b1) == false, "BPENDING match2 the buttons wait for the map to open")
    end)
    lobbyOver("match2")
    readMapKey()
    step("buttons: open", function() say("BKEY pressing %s to open the map", JS.key) return request("key " .. JS.key), 30, "map key served" end)
    step("buttons: opened", function() return function() return core.ui.journal.isOpen() end, 10, "map open" end)
    step("buttons: settle", function() return afterMs(1500), 3, "layout" end)
    step("buttons: on the map", function()
        local canvas = mapCanvasNow()
        local _, np = taggedIn(canvas, "bpanel")
        local _, n1 = inPanelOnMap("b1"); local _, n2 = inPanelOnMap("b2"); local _, nt = inPanelOnMap("bt")
        check(np == 1 and n1 == 1 and n2 == 1 and nt == 1 and B().isShown(BS.b1) and B().isShown(BS.b2),
            "BMAP match2 a panel with two buttons and a text on the map page, one widget each (bpanel=%d b1=%d b2=%d bt=%d)", np, n1, n2, nt)
        local w1 = inPanelOnMap("b1")
        check(w1 and clsOf(w1) == BUTTON_SHORT and tagOfWidget(w1) == core.ui.text.tagOf("b1"), "BTAG match2 'b1' is a %s tagged %s", w1 and clsOf(w1) or "?", w1 and tostring(tagOfWidget(w1)) or "?")
        local peer = peerWidget()
        check(peer ~= nil, "BPEER match2 the second test dependent's button is on the map page (%s)", peer and pathOf(peer) or "not found")
        return request("shot buttons-open"), 30, "screenshot"
    end)
    -- AC 1: a real click on each button runs its onClick exactly once
    clickOn("click-b1", "'b1'", function() return inPanelOnMap("b1") end)
    step("click-b1: check", function()
        local w = inPanelOnMap("b1")
        check(bcount("b1") == 1 and clicksOf(w) == BS.wclicks + 1, "BCLICK match2 a real mouse click on 'b1' ran its onClick exactly once (onClick %d, widget ClickCount %d -> %d)", bcount("b1"), BS.wclicks, clicksOf(w))
    end)
    -- AC 3: a throwing onClick logs one WARN, and the next click works
    clickOn("click-b2", "'b2'", function() return inPanelOnMap("b2") end)
    step("click-b2: check", function()
        check(bcount("b2") == 1, "BCLICK match2 a real mouse click on 'b2' ran its onClick exactly once (it threw: %d)", bcount("b2"))
    end)
    clickOn("click-b2-again", "'b2'", function() return inPanelOnMap("b2") end)
    step("click-b2-again: check", function()
        local st = B().stats()
        check(bcount("b2") == 2 and st.throws == 1, "BTHROW match2 after the throwing onClick the next click works (onClick %d, throws %d)", bcount("b2"), st.throws)
    end)
    -- AC 1: Enter on a focused button counts as one click
    step("enter-b1: focus", function()
        local w = inPanelOnMap("b1")
        BS.before, BS.wclicks = bcount("b1"), clicksOf(w)
        local ok, err = pcall(function() w.Btn:SetKeyboardFocus() end)
        local okF, has = pcall(function() return w.Btn:HasKeyboardFocus() end)
        say("BFOCUS match2 'b1' SetKeyboardFocus ok=%s hasKeyboardFocus=%s%s", tostring(ok), tostring(okF and has), ok and "" or (" " .. firstLine(err)))
        return request("key ENTER"), 30, "Enter served"
    end)
    step("enter-b1: settle", function() return afterMs(800), 3, "Enter settle" end)
    step("enter-b1: check", function()
        local w = inPanelOnMap("b1")
        check(bcount("b1") == BS.before + 1, "BENTER match2 Enter on the focused 'b1' counted as one click (onClick %d -> %d, widget ClickCount %d -> %d)", BS.before, bcount("b1"), BS.wclicks, clicksOf(w))
    end)
    -- AC 4: a disabled button runs nothing and looks disabled; enabling it restores clicks
    step("disable-b1", function() B().setEnabled(BS.b1, false) return afterMs(700), 3, "redraw" end)
    step("disable-b1: look", function()
        local w = inPanelOnMap("b1")
        local okE, en = pcall(function() return w.Btn:GetIsEnabled() end)
        local op = w:GetRenderOpacity()
        check(okE and en == false and math.abs(op - 0.45) < 0.01, "BDISABLED match2 'b1' looks disabled (Btn enabled=%s, opacity %.2f)", tostring(en), op)
        BS.before = bcount("b1")
        return request("shot buttons-disabled"), 30, "screenshot"
    end)
    clickOn("click-disabled", "'b1' (disabled)", function() return inPanelOnMap("b1") end)
    step("click-disabled: check", function()
        local w = inPanelOnMap("b1")
        check(bcount("b1") == BS.before and clicksOf(w) == BS.wclicks, "BDISABLED match2 a real click on the disabled 'b1' ran nothing (onClick %d, widget ClickCount %d -> %d)", bcount("b1"), BS.wclicks, clicksOf(w))
        B().setEnabled(BS.b1, true)
    end)
    clickOn("click-enabled", "'b1' (enabled again)", function() return inPanelOnMap("b1") end)
    step("click-enabled: check", function()
        local w = inPanelOnMap("b1")
        check(bcount("b1") == BS.before + 1 and math.abs(w:GetRenderOpacity() - 1) < 0.01, "BENABLED match2 enabled again: the next click runs once (onClick %d -> %d)", BS.before, bcount("b1"))
    end)
    -- AC 2: a click on the other dependent's button runs only its callback (check.ps1 counts its PEERCLICK line)
    step("peer: before", function() BS.ours = bcount("b1") + bcount("b2") end)
    clickOn("click-peer", "the second dependent's button", peerWidget)
    step("click-peer: check", function()
        check(bcount("b1") + bcount("b2") == BS.ours, "BOWNER match2 a click on the second dependent's button ran none of ours (b1 %d, b2 %d)", bcount("b1"), bcount("b2"))
    end)
    -- Two calls in a row (no OS click can be that quick on demand): the 250 ms debounce lets one through
    step("double", function()
        local w = inPanelOnMap("b1")
        local st0 = B().stats()
        BS.before = bcount("b1")
        local fn = CORE .. "_OnClicked"
        local ok1 = pcall(function() w[fn](w) end)
        local ok2 = pcall(function() w[fn](w) end)
        local st1 = B().stats()
        check(ok1 and ok2 and bcount("b1") - BS.before <= 1 and (bcount("b1") - BS.before == 0 or st1.debounced == st0.debounced + 1),
            "BDOUBLE match2 two %s calls in a row ran onClick %d time(s) (debounced %d -> %d)", fn, bcount("b1") - BS.before, st0.debounced, st1.debounced)
    end)
    step("buttons: close", function() return request("key " .. JS.key), 30, "map key served" end)
    step("buttons: closed", function() return function() return not core.ui.journal.isOpen() end, 10, "map closed" end)
    step("buttons: clean", function()
        check(B().isShown(BS.b1) == false, "BCLOSED match2 the map closed: 'b1' isShown=false")
        local st = B().stats()
        say("BSTATS clicks=%d dropped=%d debounced=%d ignored=%d throws=%d hookTries=%d", st.clicks, st.dropped, st.debounced, st.ignored, st.throws, st.hookTries)
        core.ui.panel.remove(BS.p)
        check(core.ui.text.stats().elements == 0 and st.hookTries == 1, "BCLEAN match2 every element removed; one hook all along")
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

-- ---------------------------------------------------------------- menu (story 21 = Mod Manager story 2, one launch)
-- Written for the VM at 1280x720 (run.ps1 -Target vm). Before any key: the entry { en = "SKEL ENTRY" } and a corner text
-- on host "menu". Then: Enter past the startup screen; the column's order, pitch, x/width and look (field-by-field
-- fingerprints, mods/menu-spike's, against OPTIONS; OPTIONS vs QUIT is the baseline) and the grown backing; the window
-- stack's limits (eight windows, a ninth refused, closing the first closes the rest); keyboard focus OPTIONS -> entry ->
-- QUIT and back; hover; a real click on the entry opens window A (a 40-row list of rows: three texts fill 3/1/1 and a
-- button); A's button opens B; clicks on A while B is up reach nothing; B closed; the wheel scrolls A's list; a row
-- button reaches only its row; Enter while A is open starts nothing; A's Close; OPTIONS (Settings) and START GAME
-- (Create Server: the menu hidden, the corner text collapsed); a click where the entry was; a round trip to Tower
-- Island (the entry inserted from the poll on the new menu); a window open across a reload (lost). Never keeps a UObject:
-- every step finds what it needs again, and calls a method on an object read from a property only after valid()
-- (the 0x18 crash, docs/mod-manager-research.md section 9).
local function buildMenu()
    local UI = core.ui
    local MM = { ev = {}, sev = {}, clicks = 0, rowHits = {}, aopen = 0, built = false, builtB = false }
    local OPT, QUIT, START = "UI_Button_Master_2", "UI_Button_Master_3", "UI_Button_Master"
    local TEMPLATE = { UI_Button_Master = true, UI_Button_Master_1 = true, UI_Button_Master_6 = true, UI_Button_Master_2 = true, UI_Button_Master_3 = true }
    local WANT_ORDER = { "START GAME", "JOIN GAME", "CUSTOMIZE", "OPTIONS", "SKEL ENTRY", "QUIT" }
    local SCREEN_SHORT, LIST_SHORT, ROW_SHORT = "WBP_" .. CORE .. "Screen_C", "WBP_" .. CORE .. "List_C", "WBP_" .. CORE .. "Row_C"
    local TEXT_S, BUTTON_S = "WBP_" .. CORE .. "Text_C", "WBP_" .. CORE .. "Button_C"
    -- The stock V8.2.3 sizes of the column's frame (mods/menu-spike section 9.6, layout units): grown by the column's growth.
    local STOCK_OV0_H, STOCK_BACK_H = 250, 282
    local ROWS = 40

    local function v(o)
        if o == nil then return false end
        local ok, y = pcall(function() return o:IsValid() end)
        return ok and y == true
    end
    local function try(fn) local ok, r = pcall(fn) if ok then return r end return nil end
    local function fname(w) if not v(w) then return "?" end return try(function() return w:GetFName():ToString() end) or "?" end
    local function cname(w) if not v(w) then return "?" end return try(function() return w:GetClass():GetFName():ToString() end) or "?" end
    local function prop(o, k) if not v(o) then return nil end local p = try(function() return o[k] end) return v(p) and p or nil end
    local function msAfter(sec) local t = os.clock() + sec return function() return os.clock() >= t end end
    local function bool(x) return x and "true" or "false" end
    local function liveOf(short)
        for _, w in ipairs(FindAllOf(short) or {}) do
            if v(w) and try(function() return w:IsInViewport() end) then return w end
        end
        return nil
    end
    local function liveAll(short)
        local out = {}
        for _, w in ipairs(FindAllOf(short) or {}) do
            if v(w) and try(function() return w:IsInViewport() end) then out[#out + 1] = w end
        end
        return out
    end
    local function menu() return liveOf("MainMenu_C") end
    local function center(r) return math.floor((r.l + r.r) / 2 + 0.5), math.floor((r.t + r.b) / 2 + 0.5) end
    local function scale(mm) return try(function() return WLL():GetViewportScale(mm) end) or 1 end
    local function visOf(w) return v(w) and try(function() return w:GetVisibility() end) or -1 end
    local function count(short) return #liveAll(short) end
    local function ctag(w)
        local k = cname(w)
        if k == TEXT_S then return try(function() return w.ToolTipText:ToString() end) end
        if k:sub(1, #("WBP_" .. CORE)) == "WBP_" .. CORE then return try(function() return w.CoreTag:ToString() end) end
        return nil
    end
    local function childTagged(container, id)
        if not v(container) then return nil end
        local tag = UI.text.tagOf(id)
        local n = try(function() return container:GetChildrenCount() end) or 0
        for i = 0, n - 1 do
            local c = try(function() return container:GetChildAt(i) end)
            if v(c) and ctag(c) == tag then return c end
        end
        return nil
    end
    local function textIn(w) return try(function() return w.ButtonText:GetText():ToString() end) end
    local function focused(w) return v(w) and (try(function() return w:HasKeyboardFocus() end) == true or try(function() return w:HasFocusedDescendants() end) == true or try(function() return w:HasAnyUserFocus() end) == true) end
    local function hasKeyFocus(w) return v(w) and (try(function() return w:HasKeyboardFocus() end) == true or try(function() return w:HasFocusedDescendants() end) == true) end

    -- ---- the column
    local function column(mm) return prop(mm, "VerticalBox_104") end
    local function entryOf(mm)
        local vb = column(mm)
        local n = vb and (try(function() return vb:GetChildrenCount() end) or 0) or 0
        for i = 0, n - 1 do
            local c = try(function() return vb:GetChildAt(i) end)
            if v(c) and not TEMPLATE[fname(c)] and textIn(c) == "SKEL ENTRY" then return c end
        end
        return nil
    end
    local function extras(mm)
        local vb, out = column(mm), 0
        local n = vb and (try(function() return vb:GetChildrenCount() end) or 0) or 0
        for i = 0, n - 1 do if not TEMPLATE[fname(try(function() return vb:GetChildAt(i) end))] then out = out + 1 end end
        return out
    end
    local function focusOwner()
        local mm = menu()
        local vb = column(mm)
        local own = {}
        local n = vb and (try(function() return vb:GetChildrenCount() end) or 0) or 0
        for i = 0, n - 1 do
            local w = try(function() return vb:GetChildAt(i) end)
            if focused(w) then own[#own + 1] = (textIn(w) or fname(w)) end
        end
        return #own > 0 and table.concat(own, ",") or "none"
    end

    -- mods/menu-spike's fingerprint: one button's look, key -> string, read from the live widget.
    local COPY_PROPS = {
        "Button Type Selection", "Transform Policy", "In Height Override", "In Width Override", "Do not ovverride with sizebox",
        "In Horizontal Alignment", "Text Style", "Icon Type Selection", "Use Icon instead of text", "Show_NumberText",
        "Show input action widget", "Style", "MinWidth", "MinHeight", "MaxWidth", "MaxHeight", "bApplyAlphaOnDisable", "bSelectable",
        "bShouldSelectUponReceivingFocus", "bInteractableWhenSelected", "bToggleable", "bTriggerClickedAfterSelection",
        "ClickMethod", "TouchMethod", "PressMethod", "PressedSlateSoundOverride", "ClickedSlateSoundOverride", "HoveredSlateSoundOverride",
    }
    local function oname(o) if not v(o) then return "nil" end return fname(o) end
    local function v2(x) return x and string.format("%.1fx%.1f", x.X, x.Y) or "?" end
    local function col(c) return c and string.format("%.2f,%.2f,%.2f,%.2f", c.R, c.G, c.B, c.A) or "?" end
    local function fingerprint(b)
        local f = {}
        local function put(k, fn) local ok, x = pcall(fn) f[k] = ok and tostring(x) or ("err:" .. firstLine(x)) end
        for _, k in ipairs(COPY_PROPS) do
            put(k, function()
                local x = b[k]
                if type(x) == "userdata" then
                    -- An object property: its name only when it is a live object (a null one is "null"; GetFName on it would
                    -- crash). A struct has no IsValid, so it falls through.
                    local okV, isV = pcall(function() return x:IsValid() end)
                    if okV then return isV == true and oname(x) or "null" end
                    local okS, s = pcall(function() return x.SoundObject end)
                    if okS then return "sound:" .. oname(s) end
                end
                return x
            end)
        end
        put("GetStyle", function() return oname(b:GetStyle()) end)
        put("CurrentTextStyleClass", function() return oname(b:GetCurrentTextStyleClass()) end)
        put("vis", function() return b:GetVisibility() end)
        put("enabled", function() return b:GetIsEnabled() end)
        local t = prop(b, "ButtonText")
        put("text.Style", function() return oname(t.Style) end)
        put("text.Font", function() local fi = t.Font return string.format("%s/%s/%s", oname(fi.FontObject), fi.TypefaceFontName:ToString(), tostring(fi.Size)) end)
        put("text.Color", function() return col(t.ColorAndOpacity.SpecifiedColor) .. " rule=" .. tostring(t.ColorAndOpacity.ColorUseRule) end)
        put("text.Shadow", function() return v2(t.ShadowOffset) .. " " .. col(t.ShadowColorAndOpacity) end)
        put("text.Transform", function() return t.TextTransformPolicy end)
        put("text.Justify", function() return t.Justification end)
        put("text.vis", function() return t:GetVisibility() end)
        put("sizebox", function() local s = prop(b, "SizeBox_Master") return string.format("h=%s/%s w=%s/%s", tostring(s.bOverride_HeightOverride), tostring(s.HeightOverride), tostring(s.bOverride_WidthOverride), tostring(s.WidthOverride)) end)
        put("stroke", function() local i = prop(b, "StrokeImage") local br = i.Brush return string.format("%s size=%s tint=%s drawAs=%s vis=%s", oname(br.ResourceObject), v2(br.ImageSize), col(br.TintColor.SpecifiedColor), tostring(br.DrawAs), tostring(i:GetVisibility())) end)
        put("desired", function() b:ForceLayoutPrepass() return v2(b:GetDesiredSize()) end)
        return f
    end
    local function diff(a, b)
        local out, keys = {}, {}
        for k in pairs(a) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do if a[k] ~= b[k] then out[#out + 1] = string.format("%s: %s | %s", k, a[k], tostring(b[k])) end end
        return out
    end

    -- The column's order, pitch, x/width and look, and the backing (AC 1, and again after the reload: AC 4).
    local function columnChecks(phase)
        local mm = menu()
        if not check(mm ~= nil, "MCOL %s a live MainMenu_C", phase) then return end
        local vb, opt, quit, ent = column(mm), prop(mm, OPT), prop(mm, QUIT), entryOf(mm)
        if not check(ent ~= nil, "MCOL %s the entry 'SKEL ENTRY' is in VerticalBox_104", phase) then return end
        local sc = scale(mm)
        local labels, rows = {}, {}
        local n = try(function() return vb:GetChildrenCount() end) or 0
        for i = 0, n - 1 do
            local c = try(function() return vb:GetChildAt(i) end)
            labels[#labels + 1] = textIn(c) or fname(c)
            rows[#rows + 1] = absR(c)
        end
        local orderOk = #labels == #WANT_ORDER
        for i, w in ipairs(WANT_ORDER) do if labels[i] ~= w then orderOk = false end end
        check(orderOk, "MORDER %s column=[%s] (expected %s)", phase, table.concat(labels, ", "), table.concat(WANT_ORDER, ", "))
        local pitches, pitchOk = {}, true
        for i = 2, #rows do
            if rows[i] and rows[i - 1] then pitches[#pitches + 1] = (rows[i].t - rows[i - 1].t) / sc end
        end
        for i = 2, #pitches do if math.abs(pitches[i] - pitches[1]) > 1 then pitchOk = false end end
        local ps = {}
        for i, p in ipairs(pitches) do ps[i] = string.format("%.1f", p) end
        check(pitchOk and #pitches == #rows - 1, "MPITCH %s row pitches (units) [%s] equal within 1", phase, table.concat(ps, ","))
        local er, orr, qr = absR(ent), absR(opt), absR(quit)
        check(er and orr and math.abs(er.l - orr.l) <= sc and math.abs((er.r - er.l) - (orr.r - orr.l)) <= sc,
            "MXW %s entry x/width %s vs OPTIONS %s (desktop px, within 1 unit)", phase, rsA(er), rsA(orr))
        -- Look: the mouse is away (a neutral point), so every button shows its normal state.
        local fo, fq, fe = fingerprint(opt), fingerprint(quit), fingerprint(ent)
        local d, dq = diff(fo, fe), diff(fo, fq)
        for _, l in ipairs(d) do say("MLOOK %s diff OPTIONS|entry %s", phase, l) end
        for _, l in ipairs(dq) do say("MLOOK %s diff OPTIONS|QUIT %s", phase, l) end
        check(#d == #dq and #d == 0, "MFP %s fingerprint diffs entry-vs-OPTIONS=%d (OPTIONS vs QUIT: %d)", phase, #d, #dq)
        -- The backing: Overlay_0 and NN_FieldNavigationBacking grew by the column's growth (the entry's row pitch).
        local growth = (er and qr) and (qr.t - er.t) / sc or 0
        local ov0, back = prop(mm, "Overlay_0"), prop(mm, "NN_FieldNavigationBacking")
        local ovH = try(function() return ov0.Slot:GetSize().Y end) or -1
        local bkH = try(function() return back.Slot:GetSize().Y end) or -1
        check(math.abs(ovH - (STOCK_OV0_H + growth)) <= 1 and math.abs(bkH - (STOCK_BACK_H + growth)) <= 1,
            "MGROW %s column grew %.1f units; Overlay_0 %.1f (stock %d), NN_FieldNavigationBacking %.1f (stock %d)", phase, growth, ovH, STOCK_OV0_H, bkH, STOCK_BACK_H)
        local br = absR(back)
        check(br and qr and br.b >= qr.b and br.t <= (er and er.t or 0), "MCOVER %s backing %s covers the entry and QUIT %s", phase, rsA(br), rsA(qr))
        check(extras(mm) == 1, "MEXTRA %s column has exactly one extra child (%d)", phase, extras(mm))
        MM.entryR = er
    end

    -- ---- the screen widgets: each window's WBP_<Core>Screen in the viewport, found by an element of ours in its Canvas.
    local function screenWith(id)
        for _, s in ipairs(liveAll(SCREEN_SHORT)) do
            local c = prop(s, "Canvas")
            if childTagged(c, id) then return s, c end
        end
        return nil
    end
    local function closeButtonIn(canvas)
        local n = v(canvas) and (try(function() return canvas:GetChildrenCount() end) or 0) or 0
        for i = 0, n - 1 do
            local c = try(function() return canvas:GetChildAt(i) end)
            -- core story 27: BACK replaces CLOSE (the tag #close:<id> stays)
            if cname(c) == BUTTON_S and try(function() return c.Label:GetText():ToString() end) == "BACK" then return c end
        end
        return nil
    end
    local function listWidget()
        local _, c = screenWith("alist")
        return childTagged(c, "alist")
    end
    local function rowWidget(i)
        local lw = listWidget()
        return childTagged(prop(lw, "VBox"), "r" .. i), lw
    end
    local function cellOf(rw, id) return childTagged(prop(rw, "HBox"), id) end

    -- ---- events
    local function sevAfter(since, event, id, reason)
        return function()
            for i = since + 1, #MM.sev do
                local e = MM.sev[i]
                if e.event == event and e.id == id and (not reason or e.reason == reason) then return true end
            end
            return false
        end
    end
    local function mevCount(e) local n = 0 for _, x in ipairs(MM.ev) do if x.event == e then n = n + 1 end end return n end

    -- ---- the windows' content (made once, in A's first open: elements stay created across closes)
    local function openB()
        MM.B = UI.screen.open{ id = "B", close = true }
        if not MM.builtB then
            MM.builtB = true
            UI.text.create{ id = "btext", text = "SKEL WINDOW B", place = { screen = MM.B, corner = "top-left" }, style = { font = "heading" } }
        end
    end
    local function openA()
        MM.A = UI.screen.open{ id = "A", close = true }
        if MM.built then return end
        MM.built = true
        UI.text.create{ id = "atitle", text = "SKEL WINDOW A", place = { screen = MM.A, corner = "top-left" }, style = { font = "title" } }
        UI.button.create{ id = "aopen", label = "OPEN B", place = { screen = MM.A, corner = "bottom-left" },
            onClick = function() MM.aopen = MM.aopen + 1 say("MCLICK aopen %d", MM.aopen) openB() end }
        -- core story 27: in a corner, under the title (a centred absolute list would cover the card's corners now)
        local L = UI.list.create{ id = "alist", place = { screen = MM.A, corner = "top-left" }, size = { w = 900, h = 440 }, gap = "tight" }
        for i = 1, ROWS do
            local r = UI.row.create{ id = "r" .. i, place = { list = L } }
            UI.text.create{ id = "c1-" .. i, text = "SKEL MOD " .. i, place = { row = r, fill = 3 }, style = { font = "body" } }
            UI.text.create{ id = "c2-" .. i, text = "1.0." .. i, place = { row = r, fill = 1 }, style = { font = "body" } }
            UI.text.create{ id = "c3-" .. i, text = "ON", place = { row = r, fill = 1 }, style = { font = "small" } }
            UI.button.create{ id = "rb" .. i, label = "PICK", place = { row = r },
                onClick = function() MM.rowHits[i] = (MM.rowHits[i] or 0) + 1 say("MCLICK row %d %d", i, MM.rowHits[i]) end }
        end
    end
    local function rowHitSum() local s = 0 for _, n in pairs(MM.rowHits) do s = s + n end return s end

    -- ---- step helpers
    local function clickAt(label, finder)
        step("menu: click " .. label, function()
            local x, y = finder()
            if not check(x ~= nil, "MPOINT %s has a point to click", label) then return end
            say("MCLICKREQ %s at (%d,%d)", label, x, y)
            return request(string.format("click %d %d", x, y)), 40, "click " .. label
        end)
        step("menu: settle " .. label, function() return msAfter(1.5), 4 end)
    end
    local function widgetPoint(finder) return function() local r = absR(finder()) if r and r.r > r.l then return center(r) end end end
    local function neutral()
        local r = absR(prop(prop(menu(), "WidgetTree"), "RootWidget"))
        if r and r.r > r.l then return math.floor(r.l + (r.r - r.l) * 0.62), math.floor(r.t + (r.b - r.t) * 0.55) end
    end
    local function moveTo(label, finder)
        step("menu: move " .. label, function()
            local x, y = finder()
            if not x then say("MMOVE %s skipped (no point)", label) return end
            return request(string.format("move %d %d", x, y)), 30, "move " .. label
        end)
        step("menu: move settle " .. label, function() return msAfter(0.8), 3 end)
    end
    local function shot(label) step("menu: shot " .. label, function() return request("shot " .. label), 30, "screenshot " .. label end) end
    local function key(k, label, want)
        step("menu: key " .. label, function()
            local from = focusOwner()
            local done = request("key " .. k)
            local t
            return function()
                if not done() then return false end
                t = t or os.clock() + 0.7
                if os.clock() < t then return false end
                local to = focusOwner()
                if want then check(to == want, "MKEY %s %s: %s -> %s (expected %s)", label, k, from, to, want)
                else say("MKEY %s %s: %s -> %s", label, k, from, to) end
                MM.lastFocus = to
                return true
            end, 30, "key " .. k
        end)
    end

    -- ---- before any key: the entry and a corner text, the watchers
    step("menu: setup", function()
        MM.mtok = UI.menu.watch(function(_, info)
            MM.ev[#MM.ev + 1] = { event = info.event, reason = info.reason, path = info.path }
            say("MEVENT %d %s reason=%s path=%s", #MM.ev, tostring(info.event), tostring(info.reason), tostring(info.path))
        end)
        MM.stok = UI.screen.watch(function(_, info)
            MM.sev[#MM.sev + 1] = { event = info.event, id = info.id, reason = info.reason }
            say("SEVENT %d %s id=%s reason=%s", #MM.sev, tostring(info.event), tostring(info.id), tostring(info.reason))
        end)
        MM.entry = UI.menu.entry{ id = "skel-entry", label = { en = "SKEL ENTRY", es = "SKEL ENTRADA" }, style = "options",
            onClick = function()
                MM.clicks = MM.clicks + 1
                say("MCLICK entry %d", MM.clicks)
                local ok, err = pcall(openA)
                if not ok then say("MOPEN A failed: %s", firstLine(err)) end
            end }
        MM.mtext = UI.text.create{ id = "mtext", text = "SKEL MENU TEXT", place = { host = "menu", corner = "top-right" } }
        check(MM.entry ~= nil and MM.entry.id == "skel-entry", "MSETUP entry and corner text created before any key")
    end)
    waitWorld("menu1", "NewMainMenu", 120)
    -- The press-any-key screen (UI_Startup_C) takes keys only once it is up: wait for it, then a moment, then Enter,
    -- again every 15 s until a MainMenu_C exists (mods/menu-spike's way; one early Enter was lost in the VM).
    step("menu1: startup screen", function()
        local deadline = os.clock() + 60
        return function()
            if liveOf("UI_Startup_C") or menu() then return true end
            return os.clock() > deadline
        end, 65, "startup screen"
    end)
    step("menu1: startup settle", function() return msAfter(2), 4 end)
    step("menu1: startup", function()
        local n = count("MainMenu_C")
        check(n == 0, "STARTUP before key: MainMenu_C in viewport=%d (no menu yet, so no menu hook may be registered)", n)
        check(UI.menu.isOpen() == false and UI.text.isShown(MM.mtext) == false, "STARTUP menu.isOpen=false, corner text isShown=false")
        say("STARTUP requesting Enter (startup screen up: %s)", bool(liveOf("UI_Startup_C") ~= nil))
        local done = request("key ENTER")
        local deadline, tries = os.clock() + 15, 1
        return function()
            if menu() then return true end
            if os.clock() > deadline and done() and tries < 4 then
                tries, deadline = tries + 1, os.clock() + 15
                say("STARTUP no menu yet; Enter again (%d)", tries)
                done = request("key ENTER")
            end
            return false
        end, 70, "menu after Enter"
    end)
    step("menu1: menu opened", function()
        return function()
            local mm = menu()
            return mm ~= nil and mevCount("opened") >= 1 and entryOf(mm) ~= nil
        end, 60, "menu opened with the entry"
    end)
    step("menu1: menu settle", function() return msAfter(3), 6 end)
    step("menu1: opened", function()
        check(UI.menu.isOpen() == true, "MOPEN menu.isOpen()=true; opened events=%d", mevCount("opened"))
        check(UI.text.isShown(MM.mtext) == true, "MTEXT corner text isShown on the menu")
    end)
    moveTo("away", neutral)
    step("menu1: column", function() columnChecks("menu1") end)
    shot("menu-column")

    -- ---- the window stack's limits (needs the live menu): eight windows, a ninth refused, close the first
    step("menu1: stack limits", function()
        local f = function(fn, ...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end
        local SW = CORE:lower() .. ".ui.screen.open: "
        local ws = {}
        case("menu1.mm-screen-open-ok", "ui.screen.open{ id = 'w1' } [control]", function() ws[1] = UI.screen.open{ id = "w1", close = false } return ws[1] end,
            E.ret("a window handle { id = 'w1' }", function(r) return type(r[1]) == "table" and r[1].id == "w1" end))
        if not ws[1] then return end
        case("menu1.mm-screen-open-again", "ui.screen.open{ id = 'w1' } [already open]", f(UI.screen.open, { id = "w1" }),
            E.ret("the same handle", function(r) return rawequal(r[1], ws[1]) end))
        case("menu1.mm-screen-handle-write", "window.id = 'x'", function() ws[1].id = "x" end, E.errAny({ "read-only", "read only" }))
        for i = 2, 8 do ws[i] = UI.screen.open{ id = "w" .. i, close = false } end
        case("menu1.mm-screen-open-9", "ui.screen.open{ id = 'w9' } [a ninth window]", f(UI.screen.open, { id = "w9" }), E.err(SW .. "this mod already has 8 windows open (at most 8)"))
        case("menu1.mm-screen-top-8", "ui.screen.top() [control: w8]", f(UI.screen.top), E.ret("w8", function(r) return rawequal(r[1], ws[8]) end))
        case("menu1.mm-screen-isopen-w3", "ui.screen.isOpen(w3) [control]", f(UI.screen.isOpen, ws[3]), E.ret("true", function(r) return r[1] == true end))
        MM.stackSince = #MM.sev
        case("menu1.mm-screen-close-w1", "ui.screen.close(w1) [closes w2..w8 first]", f(UI.screen.close, ws[1]), E.none)
        case("menu1.mm-screen-top-none", "ui.screen.top() [control: none]", f(UI.screen.top), E.nilret)
        case("menu1.mm-screen-isopen-w5", "ui.screen.isOpen(w5) [control: closed]", f(UI.screen.isOpen, ws[5]), E.ret("false", function(r) return r[1] == false end))
        case("menu1.mm-screen-close-again", "ui.screen.close(w1) [again]", f(UI.screen.close, ws[1]), E.none)
        return msAfter(1), 3
    end)
    step("menu1: stack events", function()
        local okA = sevAfter(MM.stackSince or 0, "closed", "w1", "api")()
        local parents = 0
        for i = 2, 8 do if sevAfter(MM.stackSince or 0, "closed", "w" .. i, "parent")() then parents = parents + 1 end end
        check(okA and parents == 7, "MSTACK closed w1 reason api=%s, w2..w8 reason parent=%d of 7", bool(okA), parents)
        check(#liveAll(SCREEN_SHORT) == 0, "MSTACK no screen widget left in the viewport (%d)", #liveAll(SCREEN_SHORT))
        check(hasKeyFocus(menu()), "MSTACK the menu holds keyboard focus after the last window closed")
    end)

    -- ---- keyboard: OPTIONS -> DOWN -> entry -> DOWN -> QUIT -> UP -> entry -> UP -> OPTIONS
    step("menu1: focus OPTIONS", function()
        local o = prop(menu(), OPT)
        pcall(function() o:SetKeyboardFocus() end)
        return msAfter(0.6), 2
    end)
    step("menu1: focus OPTIONS check", function() check(focusOwner() == "OPTIONS", "MKEY focus on OPTIONS (%s)", focusOwner()) end)
    shot("menu-focus-options")
    key("DOWN", "1", "SKEL ENTRY")
    shot("menu-focus-entry")
    key("DOWN", "2", "QUIT")
    key("UP", "3", "SKEL ENTRY")
    key("UP", "4", "OPTIONS")

    -- ---- hover: the entry hovered shows the same text state as a hovered OPTIONS
    moveTo("entry", widgetPoint(function() return entryOf(menu()) end))
    step("menu1: hover entry", function() MM.hoverEntry = fingerprint(entryOf(menu()))["text.Color"] end)
    shot("menu-hover-entry")
    moveTo("options", widgetPoint(function() return prop(menu(), OPT) end))
    step("menu1: hover options", function()
        MM.hoverOpt = fingerprint(prop(menu(), OPT))["text.Color"]
        check(MM.hoverEntry ~= nil and MM.hoverEntry == MM.hoverOpt, "MHOVER hovered entry text %s, hovered OPTIONS text %s", tostring(MM.hoverEntry), tostring(MM.hoverOpt))
    end)
    shot("menu-hover-options")
    moveTo("away2", neutral)

    -- ---- a real click on the entry: window A, nothing of the game's
    clickAt("entry", widgetPoint(function() return entryOf(menu()) end))
    step("menu1: entry clicked", function()
        local mm = menu()
        local page = try(function() return mm.WidgetSwitcher_1:GetActiveWidgetIndex() end)
        check(MM.clicks == 1, "MENTRY real click ran onClick exactly once (%d)", MM.clicks)
        check(count("SettingsMenu_draggable_C") == 0 and count("CreateServer_C") == 0 and page == 0,
            "MENTRY nothing of the game's opened (Settings %d, CreateServer_C %d, menu page %s)", count("SettingsMenu_draggable_C"), count("CreateServer_C"), tostring(page))
        check(MM.A ~= nil and UI.screen.isOpen(MM.A) == true and rawequal(UI.screen.top(), MM.A), "MWINA window A open and on top")
        return msAfter(1.5), 4
    end)
    step("menu1: window A", function()
        local s = screenWith("alist")
        check(s ~= nil and hasKeyFocus(s), "MWINA A's screen widget %s has keyboard focus", fname(s))
        local lw = listWidget()
        local n = lw and try(function() return lw.VBox:GetChildrenCount() end) or 0
        check(n == ROWS, "MWINA A's list holds %d rows (%d)", ROWS, n)
        -- The game look (AC 7): row texts in AlumniSans, row brushes and the Close button on the Remaster materials.
        local rw = rowWidget(1)
        local c1 = cellOf(rw, "c1-1")
        local font = try(function() return oname(c1.Text.Font.FontObject) end) or "?"
        -- core story 28: row 1 holds the focused PICK and shows the selection; row 2 shows a row's own worn strip
        local rowBrush = try(function() return oname(rowWidget(2).Background.Background.ResourceObject) end) or "?"
        local cb = closeButtonIn(prop(s, "Canvas"))
        -- core story 27: a focused BACK shows its hover brush as its normal one; its own style is then SavedStyle
        local cbStyle = try(function() return cb.FocusLook end) == true and try(function() return cb.SavedStyle end) or try(function() return cb.Btn.WidgetStyle end)
        local cbN = try(function() return oname(cbStyle.Normal.ResourceObject) end) or "?"
        local cbH = try(function() return oname(cb.Btn.WidgetStyle.Hovered.ResourceObject) end) or "?"
        local cbF = try(function() return oname(cb.Label.Font.FontObject) end) or "?"
        check(font:find("AlumniSans", 1, true) ~= nil and cbF:find("AlumniSans", 1, true) ~= nil, "MLOOKGAME fonts: row text %s, Close label %s (AlumniSans)", font, cbF)
        check(rowBrush:find("M_NN_WornStrip", 1, true) ~= nil and cbN:find("M_NN_WornStrip", 1, true) ~= nil and cbH:find("M_NN_CinematicSelection", 1, true) ~= nil,
            "MLOOKGAME brushes: row %s, Close normal %s, Close hovered %s", rowBrush, cbN, cbH)
    end)
    shot("menu-window-a")

    -- ---- A's button opens B; B has focus, A takes no hits; a click on A's rows reaches nothing
    clickAt("A open-B", widgetPoint(function() local _, c = screenWith("atitle") return childTagged(c, "aopen") end))
    step("menu1: window B", function()
        check(MM.aopen == 1 and MM.B ~= nil and UI.screen.isOpen(MM.B) and rawequal(UI.screen.top(), MM.B), "MWINB A's button opened B (clicks %d), B on top", MM.aopen)
        local sb, sa = screenWith("btext"), screenWith("atitle")
        check(sb ~= nil and hasKeyFocus(sb) and not hasKeyFocus(sa), "MWINB B has keyboard focus, A doesn't")
        check(visOf(sa) == 3, "MWINB A is HitTestInvisible under B (visibility %s)", tostring(visOf(sa)))
        MM.hitsBefore, MM.clicksBefore = rowHitSum(), MM.clicks
    end)
    shot("menu-window-b")
    clickAt("A row under B", widgetPoint(function() return cellOf(rowWidget(1), "rb1") end))
    step("menu1: under B", function()
        check(rowHitSum() == MM.hitsBefore and MM.clicks == MM.clicksBefore and MM.aopen == 1, "MUNDERB a click on A's row while B is up reached nothing (row hits %d, entry %d, open-B %d)", rowHitSum(), MM.clicks, MM.aopen)
        MM.bSince = #MM.sev
        UI.screen.close(MM.B)
        return msAfter(1), 3
    end)
    step("menu1: B closed", function()
        check(sevAfter(MM.bSince, "closed", "B", "api")() and not UI.screen.isOpen(MM.B), "MCLOSEB B closed (reason api)")
        local sa = screenWith("atitle")
        check(sa ~= nil and hasKeyFocus(sa) and visOf(sa) ~= 3, "MCLOSEB A has keyboard focus again and takes hits (visibility %s)", tostring(visOf(sa)))
        local lw = listWidget()
        MM.off0 = try(function() return lw.Scroll:GetScrollOffset() end) or -1
    end)

    -- ---- the wheel scrolls A's list; rows line up; a row button reaches only its row
    step("menu1: wheel", function()
        local r = absR(listWidget())
        if not check(r ~= nil and r.r > r.l, "MWHEEL A's list has a rectangle %s", rsA(r)) then return end
        local x, y = center(r)
        return request(string.format("wheel %d %d -3", x, y)), 40, "wheel"
    end)
    step("menu1: wheel settle", function() return msAfter(1.5), 4 end)
    step("menu1: wheel check", function()
        local lw = listWidget()
        local off = try(function() return lw.Scroll:GetScrollOffset() end) or -1
        check(MM.off0 == 0 and off > 0, "MWHEEL scroll offset %.1f -> %.1f", MM.off0 or -1, off)
        -- Every fully visible row: its three texts start at the same x as in the first visible row (within 1 unit).
        local lr = absR(lw)
        local sc = scale(menu())
        local base, n, worst, firstVis = nil, 0, 0, nil
        for i = 1, ROWS do
            local rw = rowWidget(i)
            local rr = absR(rw)
            if rr and lr and rr.t >= lr.t and rr.b <= lr.b and rr.b > rr.t then
                firstVis = firstVis or i
                local xs = {}
                for k, id in ipairs({ "c1-", "c2-", "c3-" }) do local cr = absR(cellOf(rw, id .. i)) xs[k] = cr and cr.l or -1e9 end
                if not base then base = xs else for k = 1, 3 do worst = math.max(worst, math.abs(xs[k] - base[k]) / sc) end end
                n = n + 1
            end
        end
        check(n >= 3 and worst <= 1, "MCOLS %d visible rows: their three texts start at the same x (worst %.2f units)", n, worst)
        MM.visRow = firstVis
    end)
    clickAt("row button", widgetPoint(function() return MM.visRow and cellOf(rowWidget(MM.visRow), "rb" .. MM.visRow) end))
    step("menu1: row button", function()
        local k = MM.visRow or 0
        check((MM.rowHits[k] or 0) == 1 and rowHitSum() == 1, "MROW a real click on row %d's button reached only its onClick (that row %d, all rows %d)", k, MM.rowHits[k] or 0, rowHitSum())
        MM.cs0 = count("CreateServer_C")
    end)
    -- ---- Enter while A is open starts nothing (A holds the focus, not the menu's buttons)
    step("menu1: enter on A", function() return request("key ENTER"), 30, "enter on A" end)
    step("menu1: enter settle", function() return msAfter(1.5), 4 end)
    step("menu1: enter check", function()
        check(count("CreateServer_C") == 0 and UI.screen.isOpen(MM.A), "MENTER Enter with A open created no CreateServer_C (%d) and A stays open", count("CreateServer_C"))
        MM.aSince = #MM.sev
    end)
    -- ---- A's Close button: closed (close), the menu has focus again, DOWN still moves in the column
    clickAt("A close", widgetPoint(function() local _, c = screenWith("atitle") return closeButtonIn(c) end))
    step("menu1: A closed", function()
        check(sevAfter(MM.aSince, "closed", "A", "close")() and not UI.screen.isOpen(MM.A) and #liveAll(SCREEN_SHORT) == 0, "MCLOSEA Close closed A (reason close), no screen widget left")
        check(hasKeyFocus(menu()), "MCLOSEA the menu holds keyboard focus")
    end)
    step("menu1: down after close", function()
        local done = request("key DOWN")
        local t
        return function()
            if not done() then return false end
            t = t or os.clock() + 0.7
            if os.clock() < t then return false end
            check(focusOwner() ~= "none", "MCLOSEA DOWN after the close moves focus into the column (%s)", focusOwner())
            return true
        end, 30, "down after close"
    end)
    moveTo("away3", neutral)

    -- ---- OPTIONS: Settings opens (closed through its own ExitSelf); START GAME: Create Server, the menu hidden
    clickAt("OPTIONS", widgetPoint(function() return prop(menu(), OPT) end))
    step("menu1: settings", function()
        local s = liveOf("SettingsMenu_draggable_C")
        check(s ~= nil and MM.clicks == 1, "MSETTINGS a real click on OPTIONS opened Settings (entry onClick still %d)", MM.clicks)
        if s then pcall(function() s:ExitSelf() end) end
        return msAfter(1), 3
    end)
    step("menu1: settings closed", function() check(liveOf("SettingsMenu_draggable_C") == nil, "MSETTINGS Settings closed through its own ExitSelf") MM.hidden0 = mevCount("hidden") end)
    clickAt("START GAME", widgetPoint(function() return prop(menu(), START) end))
    step("menu1: start game", function()
        check(count("CreateServer_C") == 1, "MSTART a real click on START GAME opened Create Server (%d)", count("CreateServer_C"))
        return function() return mevCount("hidden") > MM.hidden0 end, 5, "menu hidden"
    end)
    step("menu1: hidden", function()
        check(mevCount("hidden") > MM.hidden0, "MHIDDEN the menu's hidden event fired")
        local mm = menu()
        local canvas = try(function() return mm.WidgetTree.RootWidget:GetWidgetAtIndex(0) end)
        local w = childTagged(canvas, "mtext")
        check(UI.text.isShown(MM.mtext) == false and visOf(w) == 1, "MHIDDEN corner text isShown=false, its widget Collapsed (%s)", tostring(visOf(w)))
        MM.clicksBefore = MM.clicks
    end)
    clickAt("entry's last rect", function() if MM.entryR then return center(MM.entryR) end end)
    step("menu1: last rect", function() check(MM.clicks == MM.clicksBefore, "MLASTRECT a click where the entry was calls no onClick (%d)", MM.clicks) end)

    -- ---- Tower Island and back: the new menu gets its entry from the poll's opened (story 34)
    step("menu1: before travel", function() MM.lost0 = mevCount("lost") MM.open0 = mevCount("opened") end)
    travel("match", MATCH_MAP, "listen")
    waitWorld("match", "SmallMap", 150)
    step("match: settle", function() return msAfter(6), 10 end)
    step("match: menu lost", function() check(mevCount("lost") > MM.lost0 and UI.menu.isOpen() == false, "MLOST the menu's lost event fired on the map change") end)
    travel("menu2", MENU_MAP, "")
    waitWorld("menu2", "NewMainMenu", 150)
    step("menu2: menu opened", function()
        return function() local mm = menu() return mm ~= nil and mevCount("opened") > MM.open0 and entryOf(mm) ~= nil end, 60, "new menu with the entry"
    end)
    step("menu2: settle", function() return msAfter(3), 6 end)
    moveTo("away4", neutral)
    step("menu2: column", function() columnChecks("menu2") end)
    shot("menu-reload")

    -- ---- a window open across a map change: lost
    step("menu2: window C", function()
        MM.C = UI.screen.open{ id = "C", close = true }
        UI.text.create{ id = "ctext", text = "SKEL WINDOW C", place = { screen = MM.C, corner = "top-left" } }
        MM.cSince = #MM.sev
        check(UI.screen.isOpen(MM.C), "MWINC window C open before the reload")
        MM.open1 = mevCount("opened")
    end)
    travel("menu3", MENU_MAP, "")
    waitWorld("menu3", "NewMainMenu", 150)
    step("menu3: menu opened", function()
        return function() local mm = menu() return mm ~= nil and mevCount("opened") > MM.open1 and entryOf(mm) ~= nil end, 60, "third menu"
    end)
    step("menu3: lost", function()
        check(sevAfter(MM.cSince, "lost", "C")() and not UI.screen.isOpen(MM.C) and UI.screen.top() == nil and #liveAll(SCREEN_SHORT) == 0,
            "MWINC window C lost with the map change (its widget gone, top() nil)")
        check(extras(menu()) == 1, "MEXTRA menu3 column has exactly one extra child (%d)", extras(menu()))
        UI.menu.unwatch(MM.mtok)
        UI.screen.unwatch(MM.stok)
    end)

    -- ---- core story 24 (core 0.8.0): text fitting, images and icons, tooltips, on a window over the third menu.
    -- The ic-* bad-input group (every new function and key, each one off the game thread, the new unknown-style-key
    -- text), then the Mod Manager's row (checkbox image 28 | name text fill 4 ellipsis | version text fill 1 | spacer 28
    -- | icon-only gear button 28, dimmed, tooltip), one image per allow-listed game texture, and a disabled button with an
    -- icon and a tooltip. Every line is a check: IMG (texture and tint), MEASURE (allotted vs desired width, right edge vs
    -- the next column, the gear's box), TIP (tooltip and tag reads), the gear's click; shots ic-tooltip and ic-row.
    local function iconSteps()
        local IC = { hits = 0, cases = 0 }
        local UIP = CORE:lower() .. ".ui"
        local LONG = ("SkelModManagerLongNameThatIsCutWithAnEllipsisAtTheColumnEdge0123"):sub(1, 64)
        local GAME = {
            { "g1", "/Game/Graphics/MainMenu/Textures/checkbox_ticked.checkbox_ticked", "checkbox_ticked" },
            { "g2", "/Game/Graphics/MainMenu/Textures/checkbox_unticked.checkbox_unticked", "checkbox_unticked" },
            { "g3", "/Game/AntizeVOIPSystem/Widgets/Settings/T_Settings.T_Settings", "T_Settings" },
            { "g4", "/Game/HexTree/Widgets/reset-icon.reset-icon", "reset-icon" },
            { "g5", "/Game/HexTree/Textures/T_Question.T_Question", "T_Question" },
        }
        local DIM = { 0.36, 0.41, 0.43, 0.55 }
        local function f(fn, ...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end
        local function icase(id, desc, fn, expect) IC.cases = IC.cases + 1; case("menu3.ic-" .. id, desc, fn, expect) end
        local function col4(c) if not c then return "?" end return string.format("%.2f,%.2f,%.2f,%.2f", c.R, c.G, c.B, c.A) end
        local function near4(c, want) return c ~= nil and math.abs(c.R - want[1]) < 0.01 and math.abs(c.G - want[2]) < 0.01 and math.abs(c.B - want[3]) < 0.01 and math.abs(c.A - want[4]) < 0.01 end
        local function resName(img) return try(function() local o = img.Brush.ResourceObject if v(o) then return fname(o) end return "none" end) or "?" end
        local function tip(w) return try(function() return w.ToolTipText:ToString() end) end
        local function icWin() local _, c = screenWith("ic.title") return c end
        local function listW() return childTagged(icWin(), "ic.list") end
        local function rowW(n) return childTagged(prop(listW(), "VBox"), "ic.row" .. n) end
        local function cell(n, id) return childTagged(prop(rowW(n), "HBox"), id) end

        step("ic: window", function()
            IC.W = UI.screen.open{ id = "IC", close = true }
            UI.text.create{ id = "ic.title", text = "SKEL ICONS", place = { screen = IC.W, corner = "top-left" }, style = { font = "title" } }
            IC.list = UI.list.create{ id = "ic.list", place = { screen = IC.W, absolute = { anchor = "center", x = 0, y = 0 } }, size = { w = 900, h = 300 }, gap = "tight" }
            IC.row1 = UI.row.create{ id = "ic.row1", place = { list = IC.list } }
            IC.on = UI.image.create{ id = "ic.on", place = { row = IC.row1 }, image = { icon = "checkbox-on" }, size = 28, tooltip = "ON" }
            IC.name = UI.text.create{ id = "ic.name", text = LONG, place = { row = IC.row1, fill = 4 }, style = { overflow = "ellipsis" } }
            IC.ver = UI.text.create{ id = "ic.ver", text = "1.0.0", place = { row = IC.row1, fill = 1 } }
            IC.gap = UI.image.create{ id = "ic.gap", place = { row = IC.row1 }, size = 28 }
            IC.cfg = UI.button.create{ id = "ic.cfg", place = { row = IC.row1 }, icon = { icon = "gear" }, iconSize = 28, dimmed = true,
                tooltip = { en = "CONFIGURE", de = "KONFIGURIEREN" }, onClick = function() IC.hits = IC.hits + 1 say("ICCLICK gear %d", IC.hits) end }
            UI.text.setTooltip(IC.ver, "VERSION")
            IC.row2 = UI.row.create{ id = "ic.row2", place = { list = IC.list } }
            for _, g in ipairs(GAME) do UI.image.create{ id = "ic." .. g[1], place = { row = IC.row2 }, image = { game = g[2] }, size = 40 } end
            IC.row3 = UI.row.create{ id = "ic.row3", place = { list = IC.list } }
            IC.dis = UI.button.create{ id = "ic.dis", label = "RESET", place = { row = IC.row3 }, icon = { icon = "restart" }, enabled = false,
                tooltip = "DISABLED TIP", onClick = function() say("ICCLICK disabled") end }
            check(UI.screen.isOpen(IC.W), "ICWIN window IC open with the icon rows")
            return msAfter(1.5), 4
        end)

        -- ---- the ic-* bad-input group: every new function and key (the window is open, so cursor hosts are live)
        step("ic: cases", function()
            local T, B, IM, PN = UI.text, UI.button, UI.image, UI.panel
            local ST, IMC, IMS = UIP .. ".text: ", UIP .. ".image.create: ", UIP .. ".image.set: "
            local BC = UIP .. ".button.create: "
            local nop = function() end
            local rp = { row = IC.row3 }
            local function img(o) o.id = o.id or "ic.bad"; o.place = o.place or rp return f(IM.create, o) end
            local function btn(o) o.id = o.id or "ic.badb"; o.place = o.place or rp; o.onClick = o.onClick or nop return f(B.create, o) end
            local TH = "tooltip needs a host with a cursor (journal, menu, screen), got 'hud'"
            -- text style: overflow
            icase("style-key", "ui.text.create{ style = { bg = 'dim' } } [the new unknown-key list]", f(T.create, { id = "ic.bt", style = { bg = "dim" } }), E.err(ST .. "unknown style key 'bg' (valid: background, font, look, overflow, padding)"))
            icase("overflow-bad", "ui.text.setStyle(t, { overflow = 'fade' })", f(T.setStyle, IC.ver, { overflow = "fade" }), E.err(ST .. "unknown overflow 'fade' (valid: ellipsis, clip)"))
            icase("overflow-num", "ui.text.setStyle(t, { overflow = 1 })", f(T.setStyle, IC.ver, { overflow = 1 }), E.err(ST .. "unknown overflow 1 (valid: ellipsis, clip)"))
            icase("overflow-button", "ui.button.create{ style = { overflow = 'clip' } }", btn({ label = "x", style = { overflow = "clip" } }), E.err(UIP .. ".button: style key overflow is available on text only"))
            icase("overflow-panel", "ui.panel.create{ style = { overflow = 'clip' } }", f(PN.create, { id = "ic.bp", place = { screen = IC.W, corner = "top-right" }, style = { overflow = "clip" } }), E.err(UIP .. ".panel: style key overflow is available on text only"))
            icase("overflow-list", "ui.list.setStyle(l, { overflow = 'clip' })", f(UI.list.setStyle, IC.list, { overflow = "clip" }), E.err(UIP .. ".list: style key overflow is available on text only"))
            icase("overflow-row", "ui.row.setStyle(r, { overflow = 'ellipsis' })", f(UI.row.setStyle, IC.row3, { overflow = "ellipsis" }), E.err(UIP .. ".row: style key overflow is available on text only"))
            icase("overflow-clip-ok", "ui.text.setStyle(ver, { overflow = 'clip' }) then nil [control]", function() T.setStyle(IC.ver, { overflow = "clip" }) T.setStyle(IC.ver, nil) end, E.none)
            -- image.create: the argument, keys, sources, sizes, style, dimmed, tooltip, host
            icase("img-none", "ui.image.create()", f(IM.create), E.err(IMC .. "expected a table { id = ..., place = ..., image = ..., size = ... }, got nil"))
            icase("img-args", "ui.image.create({ id = 'x' }, 2)", f(IM.create, { id = "ic.bad" }, 2), E.err(IMC .. "expected 1 argument (a table), got 2"))
            icase("img-unknown", "ui.image.create{ ..., colour = 1 }", img({ colour = 1 }), E.err(IMC .. "unknown key 'colour' (valid: dimmed, id, image, place, size, style, tooltip)"))
            icase("img-id", "ui.image.create{ id = 'a b' }", img({ id = "a b" }), E.err(IMC .. "id 'a b' has characters outside A-Z a-z 0-9 _ . -"))
            icase("img-kindid", "ui.image.create{ id = 'ic.ver' } [a text's id]", img({ id = "ic.ver" }), E.err(IMC .. "id 'ic.ver' is already a text element of this mod"))
            icase("img-src-path", "ui.image.create{ image = { game = '/Game/Foo.Foo' } }", img({ image = { game = "/Game/Foo.Foo" } }), E.err(IMC .. "game texture '/Game/Foo.Foo' is not allow-listed (valid: /Game/Graphics/MainMenu/Textures/checkbox_ticked.checkbox_ticked, "))
            icase("img-src-long", "ui.image.create{ image = { game = <200 characters> } }", img({ image = { game = "/Game/" .. string.rep("a", 200) } }), E.err(IMC .. "game texture '/Game/" .. string.rep("a", 58) .. "'... is not allow-listed"))
            icase("img-src-icon", "ui.image.create{ image = { icon = 'star' } }", img({ image = { icon = "star" } }), E.err(IMC .. "unknown icon 'star' (valid: checkbox-off, checkbox-on, gear, lock, restart, warning)"))
            icase("img-src-two", "ui.image.create{ image = { icon = 'gear', game = <path> } }", img({ image = { icon = "gear", game = GAME[1][2] } }), E.err(IMC .. "image must have exactly one key, icon or game (got icon and game)"))
            icase("img-src-empty", "ui.image.create{ image = {} }", img({ image = {} }), E.err(IMC .. "image must have exactly one key, icon or game (got none)"))
            icase("img-src-str", "ui.image.create{ image = 'gear' }", img({ image = "gear" }), E.err(IMC .. "image must be { icon = <key> } or { game = <path> }, got 'gear'"))
            icase("img-src-key", "ui.image.create{ image = { path = 'x' } }", img({ image = { path = "x" } }), E.err(IMC .. "unknown key 'path' in image (valid: game, icon)"))
            local SZ = IMC .. "size must be a number from 4 to 512, or { w, h } with each from 4 to 512 "
            icase("img-size-3", "ui.image.create{ size = 3 }", img({ size = 3 }), E.err(SZ .. "(got 3)"))
            icase("img-size-600", "ui.image.create{ size = { w = 600 } }", img({ size = { w = 600 } }), E.err(SZ .. "(w is 600)"))
            icase("img-size-str", "ui.image.create{ size = 'big' }", img({ size = "big" }), E.err(SZ .. "(got 'big')"))
            icase("img-size-inf", "ui.image.create{ size = { 1/0, 4 } }", img({ size = { 1 / 0, 4 } }), E.err(SZ .. "(w is "))
            icase("img-size-key", "ui.image.create{ size = { x = 4 } }", img({ size = { x = 4 } }), E.err(SZ .. "(unknown key 'x'; valid: w, h)"))
            icase("img-tint", "ui.image.create{ style = { tint = { r = 2, g = 0, b = 0 } } }", img({ style = { tint = { r = 2, g = 0, b = 0 } } }), E.err(IMC .. "style.tint.r must be a number from 0 to 1, got 2"))
            icase("img-style-key", "ui.image.create{ style = { background = 'dim' } }", img({ style = { background = "dim" } }), E.err(IMC .. "unknown style key 'background' (valid: tint)"))
            icase("img-dimmed", "ui.image.create{ dimmed = 'yes' }", img({ dimmed = "yes" }), E.err(IMC .. "dimmed must be a boolean or nil, got 'yes'"))
            icase("img-tip-hud", "ui.image.create{ (the HUD), tooltip = 'x' }", f(IM.create, { id = "ic.bad", image = { icon = "gear" }, tooltip = "x" }), E.err(UIP .. ".image: " .. TH))
            icase("img-hud-ok", "ui.image.create{ (the HUD), icon warning, size { 20, 24 } } then remove [control]", function()
                local h = IM.create{ id = "ic.hud", image = { icon = "warning" }, size = { 20, 24 } }
                IM.remove(h) IM.remove(h)
                return h.id
            end, E.ret("'ic.hud'", function(r) return r[1] == "ic.hud" end))
            -- image.set, setVisible, remove, isShown
            local tmp = IM.create{ id = "ic.tmp", place = rp, image = { icon = "lock" } }
            icase("set-empty", "ui.image.set(i, {})", f(IM.set, tmp, {}), E.err(IMS .. "changes is empty (give image, dimmed or both)"))
            icase("set-unknown", "ui.image.set(i, { size = 3 })", f(IM.set, tmp, { size = 3 }), E.err(IMS .. "unknown key 'size' (valid: dimmed, image)"))
            icase("set-dimmed", "ui.image.set(i, { dimmed = 'no' })", f(IM.set, tmp, { dimmed = "no" }), E.err(IMS .. "dimmed must be a boolean, got 'no'"))
            icase("set-src", "ui.image.set(i, { image = { icon = 'star' } })", f(IM.set, tmp, { image = { icon = "star" } }), E.err(IMS .. "unknown icon 'star'"))
            icase("set-str", "ui.image.set(i, 'x')", f(IM.set, tmp, "x"), E.err(IMS .. "changes must be a table { image = <source> | false, dimmed = <boolean> }, got 'x'"))
            icase("set-args", "ui.image.set(i, {}, 1)", f(IM.set, tmp, {}, 1), E.err(IMS .. "expected 2 arguments (handle, changes), got 3"))
            icase("set-forged", "ui.image.set({ id = 'ic.tmp' }, ...) [forged]", f(IM.set, { id = "ic.tmp" }, { dimmed = true }), E.err(IMS .. "not an image handle (use the handle that image.create returned)"))
            icase("set-text", "ui.image.set(<text handle>, ...)", f(IM.set, IC.ver, { dimmed = true }), E.err(IMS .. "not an image handle ('ic.ver' is a text element)"))
            icase("set-ok", "ui.image.set(i, { image = false, dimmed = true }) then { image = { game = <path> } } [control]", function()
                IM.set(tmp, { image = false, dimmed = true }) IM.set(tmp, { image = { game = GAME[4][2] }, dimmed = false })
            end, E.none)
            icase("setvis-num", "ui.image.setVisible(i, 1)", f(IM.setVisible, tmp, 1), E.err(UIP .. ".image.setVisible: visible must be a boolean, got number"))
            icase("setvis-ok", "ui.image.setVisible(i, false) then true [control]", function() IM.setVisible(tmp, false) IM.setVisible(tmp, true) end, E.none)
            icase("isshown-text", "ui.image.isShown(<text handle>)", f(IM.isShown, IC.ver), E.err(UIP .. ".image.isShown: not an image handle ('ic.ver' is a text element)"))
            icase("isshown-ok", "ui.image.isShown(i) [control: on the open window]", f(IM.isShown, tmp), E.ret("true", function(r) return r[1] == true end))
            icase("remove-forged", "ui.image.remove({ id = 'ic.tmp' }) [forged]", f(IM.remove, { id = "ic.tmp" }), E.err(UIP .. ".image.remove: not an image handle"))
            icase("remove-ok", "ui.image.remove(i) [control]", f(IM.remove, tmp), E.none)
            icase("remove-again", "ui.image.remove(i) [again]", f(IM.remove, tmp), E.none)
            icase("removed", "ui.image.isShown(<removed image>)", f(IM.isShown, tmp), E.err(UIP .. ".image: handle 'ic.tmp' was removed"))
            -- tooltips (setTooltip on text, button, image)
            local TT = UIP .. ".text.setTooltip: "
            icase("tip-empty", "ui.text.setTooltip(t, '')", f(T.setTooltip, IC.ver, ""), E.err(TT .. "tooltip must be a string of 1 to 512 bytes, got 0 bytes"))
            icase("tip-513", "ui.text.setTooltip(t, <513 bytes>)", f(T.setTooltip, IC.ver, string.rep("x", 513)), E.err(TT .. "tooltip must be a string of 1 to 512 bytes, got 513 bytes"))
            icase("tip-noen", "ui.text.setTooltip(t, { de = 'x' })", f(T.setTooltip, IC.ver, { de = "x" }), E.err(TT .. "tooltip needs an en string (the fallback)"))
            icase("tip-ctrl", "ui.text.setTooltip(t, 'a\\1b')", f(T.setTooltip, IC.ver, "a\1b"), E.err(TT .. "tooltip has the control byte 0x01 at byte 2"))
            icase("tip-num", "ui.text.setTooltip(t, 5)", f(T.setTooltip, IC.ver, 5), E.err(TT .. "tooltip must be a string or a table of strings by language, like { en = \"...\" }, got 5"))
            icase("tip-tag", "ui.text.setTooltip(t, { en = 'x', zh1 = 'y' })", f(T.setTooltip, IC.ver, { en = "x", zh1 = "y" }), E.err(TT .. "tooltip key 'zh1' is not a language tag"))
            local many = { en = "x" }
            for i = 1, 16 do many["l" .. string.char(96 + i)] = "y" end
            icase("tip-17", "ui.text.setTooltip(t, <17 languages>)", f(T.setTooltip, IC.ver, many), E.err(TT .. "tooltip has 17 languages, at most 16"))
            icase("tip-args", "ui.text.setTooltip(t, 'a', 3)", f(T.setTooltip, IC.ver, "a", 3), E.err(TT .. "expected 2 arguments (handle, tooltip), got 3"))
            icase("tip-forged", "ui.text.setTooltip({ id = 'x' }, 'a')", f(T.setTooltip, { id = "x" }, "a"), E.err(TT .. "not an element handle"))
            icase("btip-text", "ui.button.setTooltip(<text handle>, 'a')", f(B.setTooltip, IC.ver, "a"), E.err(UIP .. ".button.setTooltip: not a button handle ('ic.ver' is a text element)"))
            icase("itip-button", "ui.image.setTooltip(<button handle>, 'a')", f(IM.setTooltip, IC.cfg, "a"), E.err(UIP .. ".image.setTooltip: not an image handle ('ic.cfg' is a button)"))
            icase("tip-newline-ok", "ui.image.setTooltip(on, 'ON\\nCHECKED') then 'ON' [control: a newline is allowed]", function() IM.setTooltip(IC.on, "ON\nCHECKED") IM.setTooltip(IC.on, "ON") end, E.none)
            -- tooltips need a cursor host
            local ht = T.create{ id = "ic.ht", text = "hud" }
            icase("tip-hud", "ui.text.setTooltip(<HUD text>, 'x')", f(T.setTooltip, ht, "x"), E.err(UIP .. ".text: " .. TH))
            T.remove(ht)
            local tt = T.create{ id = "ic.tt", text = "t", place = { screen = IC.W, corner = "bottom-left" } }
            T.setTooltip(tt, "x")
            icase("tip-place-hud", "ui.place(<text with a tooltip>, { host = 'hud', corner })", f(UI.place, tt, { host = "hud", corner = "top-left" }), E.err(UIP .. ".text: " .. TH))
            icase("tip-clear-ok", "ui.text.setTooltip(t, nil) then place on the HUD [control]", function() T.setTooltip(tt, nil) UI.place(tt, { host = "hud", corner = "top-left" }) T.remove(tt) end, E.none)
            -- button icons, dimmed, tooltip
            icase("btn-icon-star", "ui.button.create{ icon = { icon = 'star' } }", btn({ icon = { icon = "star" } }), E.err(BC .. "unknown icon 'star'"))
            icase("btn-icon-path", "ui.button.create{ icon = { game = '/Game/Foo.Foo' } }", btn({ icon = { game = "/Game/Foo.Foo" } }), E.err(BC .. "game texture '/Game/Foo.Foo' is not allow-listed"))
            icase("btn-iconsize-600", "ui.button.create{ icon, iconSize = 600 }", btn({ icon = { icon = "gear" }, iconSize = 600 }), E.err(BC .. "iconSize must be a number from 4 to 512"))
            icase("btn-iconsize-noicon", "ui.button.create{ iconSize = 28 } [no icon]", btn({ iconSize = 28 }), E.err(BC .. "iconSize needs an icon"))
            icase("btn-dimmed", "ui.button.create{ dimmed = 1 }", btn({ dimmed = 1 }), E.err(BC .. "dimmed must be a boolean or nil, got 1"))
            icase("btn-tip-empty", "ui.button.create{ tooltip = '' }", btn({ tooltip = "" }), E.err(BC .. "tooltip must be a string of 1 to 512 bytes, got 0 bytes"))
            icase("btn-size", "ui.button.create{ size = 28 } [no size on buttons]", btn({ size = 28 }), E.err(BC .. "unknown key 'size' (valid: dimmed, enabled, icon, iconSize, id, label, onClick, place, style, tooltip)"))
            icase("btn-icon-ok", "ui.button.create{ icon = { game = <reset-icon> }, label = 'X' } then remove [control]", function()
                local b = B.create{ id = "ic.okb", label = "X", place = rp, icon = { game = GAME[4][2] }, onClick = nop }
                B.remove(b)
                return b.id
            end, E.ret("'ic.okb'", function(r) return r[1] == "ic.okb" end))
            check(true, "ICCASES ran %d cases", IC.cases)
        end)

        -- ---- every new function off the game thread
        step("ic: off-thread", function()
            local done = false
            LoopAsync(10, function()
                local ok, err = pcall(function()
                    local function off(key, name, fn, ...)
                        local a = table.pack(...)
                        IC.cases = IC.cases + 1
                        case("menu3.ic-off-" .. key, "ui." .. name .. "(...) [off thread]", function() return fn(table.unpack(a, 1, a.n)) end, E.err(UIP .. "." .. name .. " called off the game thread"))
                    end
                    off("image-create", "image.create", UI.image.create, { id = "off" })
                    off("image-set", "image.set", UI.image.set, {}, { dimmed = true })
                    off("image-setvis", "image.setVisible", UI.image.setVisible, {}, true)
                    off("image-remove", "image.remove", UI.image.remove, {})
                    off("image-isshown", "image.isShown", UI.image.isShown, {})
                    off("image-settip", "image.setTooltip", UI.image.setTooltip, {}, "x")
                    off("text-settip", "text.setTooltip", UI.text.setTooltip, {}, "x")
                    off("button-settip", "button.setTooltip", UI.button.setTooltip, {}, "x")
                end)
                if not ok then check(false, "CASE menu3.ic-off block threw: %s", firstLine(err)) end
                done = true
                return true
            end)
            return function() return done end, 10, "ic off-thread cases"
        end)
        step("ic: features", function()
            check(core.has("ui.image.create") and core.has("ui.overflow") and core.has("ui.button.icon") and core.has("ui.image")
                and core.has("ui.text.setTooltip") and core.has("ui.button.setTooltip"), "ICHAS core.has: ui.image.create, ui.overflow, ui.button.icon, ui.image, ui.text.setTooltip, ui.button.setTooltip")
            return msAfter(1), 3
        end)

        -- ---- the row read back from the live widgets
        step("ic: read", function()
            local sc = scale(menu())
            local onW, nameW, verW, gapW, cfgW = cell(1, "ic.on"), cell(1, "ic.name"), cell(1, "ic.ver"), cell(1, "ic.gap"), cell(1, "ic.cfg")
            if not check(onW and nameW and verW and gapW and cfgW, "ICROW the five cells of row 1 are in its HBox, in the list on window IC") then return end
            -- IMG: texture and tint of every image, and the gear's icon
            local function img(id, w, wantTex, wantTint)
                local i = prop(w, "Img")
                local tex, c = resName(i), try(function() return i.ColorAndOpacity end)
                check(tex == wantTex and near4(c, wantTint), "IMG %s tex=%s tint=%s", id, tex, col4(c))
            end
            img("ic.on", onW, "T_CheckboxOn", { 1, 1, 1, 1 })
            img("ic.gap", gapW, "none", { 1, 1, 1, 0 })
            for _, g in ipairs(GAME) do img("ic." .. g[1], cell(2, "ic." .. g[1]), g[3], { 1, 1, 1, 1 }) end
            -- core story 28: the gear is window IC's first focusable, so it holds focus and shows its focus face (its
            -- undimmed colours). Its own dimmed look is read with the window's focus look cleared (the next UI tick
            -- puts the face back).
            local LOc = CORE:lower()
            pcall(function() require(LOc .. ".ui.focus").blur(require(LOc .. ".ui.common").windows["IC"]) end)
            local icon = prop(cfgW, "Icon")
            local ic = try(function() return icon.ColorAndOpacity end)
            check(resName(icon) == "T_Gear" and near4(ic, DIM), "IMG ic.cfg icon tex=%s tint=%s (dimmed)", resName(icon), col4(ic))
            local hv = try(function() return cfgW.HoverTextColor end)
            check(near4(hv, DIM), "IMG ic.cfg hover colour %s (dimmed: hover doesn't brighten)", col4(hv))
            -- MEASURE: the name is cut inside its column; the gear's box is 28x28
            pcall(function() nameW.Text:ForceLayoutPrepass() end)
            local nr, vr = absR(nameW), absR(verW)
            local allotted = nr and (nr.r - nr.l) / sc or -1
            local desired = try(function() return nameW.Text:GetDesiredSize().X end) or -1
            check(desired > allotted + 1 and allotted > 0, "MEASURE name allotted=%.1f desired=%.1f (cut)", allotted, desired)
            check(nr and vr and nr.r <= vr.l + 0.5, "MEASURE name right=%.1f verLeft=%.1f (desktop px; no overlap)", nr and nr.r or -1, vr and vr.l or -1)
            local pol = try(function() return nameW.Text.TextOverflowPolicy end)
            local clip = try(function() return nameW.Text.Clipping end)
            local vpol, vclip = try(function() return verW.Text.TextOverflowPolicy end), try(function() return verW.Text.Clipping end)
            check(tonumber(pol) == 1 and tonumber(clip) == 1 and tonumber(vpol) == 0 and tonumber(vclip) == 0, "MEASURE overflow name policy=%s clipping=%s; version (none) policy=%s clipping=%s", tostring(pol), tostring(clip), tostring(vpol), tostring(vclip))
            local gr, br = absR(cfgW), absR(onW)
            local gw, gh = gr and (gr.r - gr.l) / sc or -1, gr and (gr.b - gr.t) / sc or -1
            check(math.abs(gw - 28) <= 1 and math.abs(gh - 28) <= 1, "MEASURE gear box %.1fx%.1f units (28x28)", gw, gh)
            local bw, bh = br and (br.r - br.l) / sc or -1, br and (br.b - br.t) / sc or -1
            check(math.abs(bw - 28) <= 1 and math.abs(bh - 28) <= 1 and gr and br and math.abs((gr.b - gr.t) - (br.b - br.t)) <= 1, "MEASURE checkbox image %.1fx%.1f units, the gear's height", bw, bh)
            local spR = absR(gapW)
            check(spR and math.abs((spR.r - spR.l) / sc - 28) <= 1, "MEASURE spacer %.1f units wide (28)", spR and (spR.r - spR.l) / sc or -1)
            -- TIP: tooltips on the inner widgets, tags unchanged
            local tagOf = UI.text.tagOf
            check(tip(prop(cfgW, "Btn")) == "CONFIGURE" and try(function() return cfgW.CoreTag:ToString() end) == tagOf("ic.cfg"), "TIP ic.cfg Btn tooltip=%s, CoreTag %s", tostring(tip(prop(cfgW, "Btn"))), tostring(try(function() return cfgW.CoreTag:ToString() end)))
            check(tip(prop(onW, "Img")) == "ON" and visOf(prop(onW, "Img")) == 0 and try(function() return onW.CoreTag:ToString() end) == tagOf("ic.on"), "TIP ic.on Img tooltip=%s, Img visibility %s (Visible), CoreTag unchanged", tostring(tip(prop(onW, "Img"))), tostring(visOf(prop(onW, "Img"))))
            check(tip(prop(verW, "Text")) == "VERSION" and tip(verW) == tagOf("ic.ver") and visOf(prop(verW, "Text")) == 0 and visOf(prop(verW, "Background")) == 4,
                "TIP ic.ver Text tooltip=%s, root ToolTipText=%s (the tag), Text %s, Background %s", tostring(tip(prop(verW, "Text"))), tostring(tip(verW)), tostring(visOf(prop(verW, "Text"))), tostring(visOf(prop(verW, "Background"))))
            check(tip(nameW) == tagOf("ic.name") and (tip(prop(nameW, "Text")) or "") == "" and visOf(prop(nameW, "Text")) == 4 and visOf(prop(nameW, "Background")) == 3,
                "TIP ic.name no tooltip: Text %s, Background %s (hit-test invisible), root ToolTipText the tag", tostring(visOf(prop(nameW, "Text"))), tostring(visOf(prop(nameW, "Background"))))
            check(visOf(prop(gapW, "Img")) == 3, "TIP ic.gap no tooltip: Img visibility %s (HitTestInvisible)", tostring(visOf(prop(gapW, "Img"))))
            local dw = cell(3, "ic.dis")
            check(tip(prop(dw, "Btn")) == "DISABLED TIP" and resName(prop(dw, "Icon")) == "T_Restart" and math.abs((try(function() return dw:GetRenderOpacity() end) or 0) - 0.45) < 0.01,
                "TIP ic.dis disabled button: tooltip %s, icon %s, opacity %.2f", tostring(tip(prop(dw, "Btn"))), resName(prop(dw, "Icon")), try(function() return dw:GetRenderOpacity() end) or -1)
        end)
        moveTo("ic gear", widgetPoint(function() return cell(1, "ic.cfg") end))
        step("ic: tooltip wait", function() return msAfter(1.5), 4 end)
        shot("ic-tooltip")
        moveTo("ic disabled", widgetPoint(function() return cell(3, "ic.dis") end))
        step("ic: disabled tooltip wait", function() return msAfter(1.5), 4 end)
        shot("ic-tooltip-disabled")
        step("ic: disabled tooltip", function() say("ICDISABLED hovered the disabled button with a tooltip; see sp-ic-tooltip-disabled.png (recorded, not judged)") end)
        moveTo("ic away", neutral)
        shot("ic-row")
        clickAt("ic gear", widgetPoint(function() return cell(1, "ic.cfg") end))
        step("ic: gear clicked", function()
            check(IC.hits == 1, "ICCLICK the dimmed gear's real click ran onClick exactly once (%d)", IC.hits)
            check(UI.screen.isOpen(IC.W), "ICCLICK window IC still open")
            UI.screen.close(IC.W)
            return msAfter(1), 3
        end)
        step("ic: closed", function()
            check(not UI.screen.isOpen(IC.W) and #liveAll(SCREEN_SHORT) == 0, "ICCLOSE window IC closed, no screen widget left")
        end)
    end
    iconSteps()
    -- ---- Mod Manager story 4 (core 0.10.0, UI-11): checkbox, choice and slider-with-number controls, on window CT over
    -- the third menu. The ct-* bad-input group (every new function and key, each new function off the game thread), then
    -- real input: clicks on the checkbox and the choices' arrows, a drag on the slider, typing into its box (57, 999,
    -- abc, empty; 2.3 on the 0.5-step slider), the disabled row (clicks, a drag and typing do nothing), a reopen of the
    -- window (values and enabled state kept), and SkelPeer's checkbox on the menu (each mod gets only its own callbacks).
    -- CT lines are checks (value and callback count); shots ct-hover and ct-controls.
    MM.controlSteps = function()
        local CT = { n = {}, last = {}, cases = 0 }
        local UIP = CORE:lower() .. ".ui"
        local OPTS = { "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX" }
        local CHOICE_S, SLIDER_S = "WBP_" .. CORE .. "Choice_C", "WBP_" .. CORE .. "Slider_C"
        local function f(fn, ...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end
        local function ccase(id, desc, fn, expect) CT.cases = CT.cases + 1; case("menu3.ct-" .. id, desc, fn, expect) end
        local function rec(id) return function(_, a, b)
            CT.n[id] = (CT.n[id] or 0) + 1
            CT.last[id] = { a = a, b = b }
            say("CTCB %s %d %s%s", id, CT.n[id], tostring(a), b ~= nil and (" " .. tostring(b)) or "")
        end end
        local function calls(id) return CT.n[id] or 0 end
        local function ctWin() local _, c = screenWith("ct.title") return c end
        local function listW() return childTagged(ctWin(), "ct.list") end
        local function rowW(n) return childTagged(prop(listW(), "VBox"), "ct.row" .. n) end
        local function cell(n, id) return childTagged(prop(rowW(n), "HBox"), id) end
        local function txt(w) return try(function() return w:GetText():ToString() end) end
        local function iconOf(w) return try(function() local o = w.Icon.Brush.ResourceObject if v(o) then return fname(o) end return "none" end) or "?" end
        local function enabledOf(w) return try(function() return w:GetIsEnabled() end) end
        local function opacity(w) return try(function() return w:GetRenderOpacity() end) or -1 end
        local function num(x) return x == nil and "nil" or string.format("%g", x) end
        local function pointOf(w, fx, fy)
            local r = absR(w)
            if not (r and r.r > r.l) then return nil end
            return math.floor(r.l + (r.r - r.l) * fx + 0.5), math.floor(r.t + (r.b - r.t) * fy + 0.5)
        end
        local function at(finder, fx, fy) return function() return pointOf(finder(), fx or 0.5, fy or 0.5) end end
        -- one request step, then a settle
        local function req(label, cmdOf, settle)
            step("ct: " .. label, function()
                local cmd = cmdOf()
                if not check(cmd ~= nil, "CTPOINT %s has a point", label) then return end
                say("CTREQ %s: %s", label, cmd)
                return request(cmd), 40, label
            end)
            step("ct: settle " .. label, function() return msAfter(settle or 1.2), 4 end)
        end
        local function click(label, finder, fx, fy)
            req(label, function() local x, y = at(finder, fx, fy)() if x then return string.format("click %d %d", x, y) end end)
        end
        -- Types into a slider's box: a click on it (the box selects all its text when focused), then the text, which
        -- replaces the selection, or Backspace to empty it, then Enter. noEnter: a disabled box takes no focus, so Enter
        -- would reach the menu instead; it is left out there.
        local function typeInto(label, finder, text, noEnter)
            click(label .. " focus", function() return prop(finder(), "Box") end, 0.85, 0.5)
            if text == "" then req(label .. " back", function() return "key BACK" end, 0.8)
            else req(label .. " type", function() return "type " .. text end, 0.8) end
            if not noEnter then req(label .. " enter", function() return "key ENTER" end) end
        end
        local function sliderState(w)
            return try(function() return w.Bar:GetValue() end), txt(prop(w, "Box")) or "?", try(function() return w.Box:GetHintText():ToString() end) or "?"
        end

        step("ct: window", function()
            local UIx = UI
            CT.W = UIx.screen.open{ id = "CT", close = true }
            UIx.text.create{ id = "ct.title", text = "SKEL CONTROLS", place = { screen = CT.W, corner = "top-left" }, style = { font = "title" } }
            CT.list = UIx.list.create{ id = "ct.list", place = { screen = CT.W, corner = "top-left" }, size = { w = 900, h = 420 }, gap = "tight" }
            local function row(n, label)
                local r = UIx.row.create{ id = "ct.row" .. n, place = { list = CT.list } }
                UIx.text.create{ id = "ct.l" .. n, text = label, place = { row = r, fill = 2 } }
                return r
            end
            local r1 = row(1, "CHECKBOX")
            CT.cb = UIx.checkbox.create{ id = "ct.cb", place = { row = r1 }, onChange = rec("ct.cb"), tooltip = "TOGGLE" }
            local r2 = row(2, "CHOICE")
            CT.ch = UIx.choice.create{ id = "ct.ch", place = { row = r2, fill = 3 }, options = OPTS, selected = 1, onChange = rec("ct.ch") }
            local r3 = row(3, "RANGE")
            CT.rg = UIx.choice.create{ id = "ct.rg", place = { row = r3, fill = 3 }, options = UIx.choice.range{ min = 0, max = 20, step = 1, extra = { "Default" } }, onChange = rec("ct.rg") }
            local r4 = row(4, "SLIDER 0-200")
            CT.s1 = UIx.slider.create{ id = "ct.s1", place = { row = r4, fill = 3 }, min = 0, max = 200, step = 1, value = 150, defaultValue = 100, hint = "DEFAULT (100)", onChange = rec("ct.s1") }
            local r5 = row(5, "SLIDER 0-10 BY 0.5")
            CT.s2 = UIx.slider.create{ id = "ct.s2", place = { row = r5, fill = 3 }, min = 0, max = 10, step = 0.5, value = 5, onChange = rec("ct.s2") }
            local r6 = row(6, "DISABLED")
            CT.dcb = UIx.checkbox.create{ id = "ct.dcb", place = { row = r6 }, checked = true, enabled = false, onChange = rec("ct.dcb") }
            CT.dch = UIx.choice.create{ id = "ct.dch", place = { row = r6, fill = 1 }, options = OPTS, selected = 3, enabled = false, onChange = rec("ct.dch") }
            CT.dsl = UIx.slider.create{ id = "ct.dsl", place = { row = r6, fill = 2 }, min = 0, max = 10, step = 1, value = 4, enabled = false, onChange = rec("ct.dsl") }
            check(UIx.screen.isOpen(CT.W), "CTWIN window CT open with the controls")
            return msAfter(2), 5 -- the hooks are registered from the UI poll
        end)

        -- ---- the ct-* bad-input group (draft 21 AC 8 plus wrong-kind handles, unknown keys, widget = 'game', size = 8)
        step("ct: cases", function()
            local CK, CHx, SLx = UI.checkbox, UI.choice, UI.slider
            local KC, HC, SC, RG = UIP .. ".checkbox.create: ", UIP .. ".choice.create: ", UIP .. ".slider.create: ", UIP .. ".choice.range: "
            local nop = function() end
            local rp = { row = UI.row.create{ id = "ct.row7", place = { list = CT.list } } }
            local function cb(o) o.id = o.id or "ct.bad"; o.place = o.place or rp; if o.onChange == nil then o.onChange = nop elseif o.onChange == false then o.onChange = nil end return f(CK.create, o) end
            local function ch(o) o.id = o.id or "ct.bad"; o.place = o.place or rp; if o.options == nil then o.options = OPTS end; if o.onChange == nil then o.onChange = nop elseif o.onChange == false then o.onChange = nil end return f(CHx.create, o) end
            local function sl(o) o.id = o.id or "ct.bad"; o.place = o.place or rp; if o.onChange == nil then o.onChange = nop elseif o.onChange == false then o.onChange = nil end; o.min = o.min or 0; o.max = o.max or 10; o.step = o.step or 1 return f(SLx.create, o) end
            local HUD = { host = "hud", corner = "top-left" }
            -- checkbox
            ccase("cb-none", "ui.checkbox.create()", f(CK.create), E.err(KC .. "expected a table"))
            ccase("cb-args", "ui.checkbox.create({...}, 2)", f(CK.create, { id = "ct.bad", onChange = nop }, 2), E.err(KC .. "expected 1 argument (a table), got 2"))
            ccase("cb-unknown", "ui.checkbox.create{ label = 'x' }", cb({ label = "x" }), E.err(KC .. "unknown key 'label' (valid: checked, enabled, id, onChange, place, size, tooltip)"))
            ccase("cb-onchange", "ui.checkbox.create{ no onChange }", cb({ onChange = false }), E.err(KC .. "onChange must be a function, got nil"))
            ccase("cb-size-8", "ui.checkbox.create{ size = 8 }", cb({ size = 8 }), E.err(KC .. "size must be a number from 16 to 64, got 8"))
            ccase("cb-size-65", "ui.checkbox.create{ size = 65 }", cb({ size = 65 }), E.err(KC .. "size must be a number from 16 to 64, got 65"))
            ccase("cb-checked", "ui.checkbox.create{ checked = 1 }", cb({ checked = 1 }), E.err(KC .. "checked must be a boolean or nil, got 1"))
            ccase("cb-enabled", "ui.checkbox.create{ enabled = 'no' }", cb({ enabled = "no" }), E.err(KC .. "enabled must be a boolean or nil, got 'no'"))
            ccase("cb-hud", "ui.checkbox.create{ place = <hud corner> }", cb({ place = HUD }), E.err(KC .. "checkboxes need a host with a cursor (journal, menu, screen)"))
            ccase("cb-kindid", "ui.checkbox.create{ id = 'ct.ch' } [a choice's id]", cb({ id = "ct.ch" }), E.err(KC .. "id 'ct.ch' is already a choice of this mod"))
            ccase("cb-set-num", "ui.checkbox.set(cb, 1)", f(CK.set, CT.cb, 1), E.err(UIP .. ".checkbox.set: checked must be a boolean, got 1"))
            ccase("cb-get-choice", "ui.checkbox.get(<choice handle>)", f(CK.get, CT.ch), E.err(UIP .. ".checkbox.get: not a checkbox handle ('ct.ch' is a choice)"))
            ccase("cb-get-forged", "ui.checkbox.get({ id = 'ct.cb' }) [forged]", f(CK.get, { id = "ct.cb" }), E.err(UIP .. ".checkbox.get: not a checkbox handle (use the handle that checkbox.create returned)"))
            ccase("cb-setenabled", "ui.checkbox.setEnabled(cb, nil)", f(CK.setEnabled, CT.cb, nil), E.err(UIP .. ".checkbox.setEnabled: enabled must be a boolean, got nil"))
            ccase("cb-setvis", "ui.checkbox.setVisible(cb, 1)", f(CK.setVisible, CT.cb, 1), E.err(UIP .. ".checkbox.setVisible: visible must be a boolean, got number"))
            ccase("cb-isshown-slider", "ui.checkbox.isShown(<slider handle>)", f(CK.isShown, CT.s1), E.err(UIP .. ".checkbox.isShown: not a checkbox handle ('ct.s1' is a slider)"))
            ccase("cb-tip", "ui.checkbox.setTooltip(cb, '')", f(CK.setTooltip, CT.cb, ""), E.err(UIP .. ".checkbox.setTooltip: tooltip must be a string of 1 to 512 bytes"))
            ccase("cb-tip-create", "ui.checkbox.create{ tooltip = 5 }", cb({ tooltip = 5 }), E.err(KC .. "tooltip must be a string or a table of strings by language"))
            ccase("cb-place", "ui.checkbox.create{ place = 'menu' }", cb({ place = "menu" }), E.err(KC .. "place must be a table or nil, got 'menu'"))
            ccase("cb-remove-forged", "ui.checkbox.remove({ id = 'ct.cb' }) [forged]", f(CK.remove, { id = "ct.cb" }), E.err(UIP .. ".checkbox.remove: not a checkbox handle"))
            ccase("cb-remove-slider", "ui.checkbox.remove(<slider handle>)", f(CK.remove, CT.s1), E.err(UIP .. ".checkbox.remove: not a checkbox handle ('ct.s1' is a slider)"))
            ccase("cb-label-button", "ui.button.setLabel(<checkbox handle>, 'x')", f(UI.button.setLabel, CT.cb, "x"), E.err(UIP .. ".button.setLabel: not a button handle ('ct.cb' is a checkbox)"))
            ccase("cb-ok", "ui.checkbox.create{ size = 16 } then set, get, remove [control]", function()
                local h = CK.create{ id = "ct.okc", place = rp, size = 16, onChange = nop }
                CK.set(h, true)
                local g = CK.get(h)
                CK.remove(h) CK.remove(h)
                return g
            end, E.ret("true", function(r) return r[1] == true end))
            -- choice
            ccase("ch-none", "ui.choice.create()", f(CHx.create), E.err(HC .. "expected a table"))
            ccase("ch-unknown", "ui.choice.create{ values = 1 }", ch({ values = 1 }), E.err(HC .. "unknown key 'values' (valid: enabled, id, onChange, options, place, selected, tooltip, widget)"))
            ccase("ch-empty", "ui.choice.create{ options = {} }", ch({ options = {} }), E.err(HC .. "options is empty (1 to 64 strings)"))
            local many = {}
            for k = 1, 65 do many[k] = "O" .. k end
            ccase("ch-65", "ui.choice.create{ options = <65 strings> }", ch({ options = many }), E.err(HC .. "options has 65 entries, at most 64"))
            ccase("ch-nonstring", "ui.choice.create{ options = { 'A', 2 } }", ch({ options = { "A", 2 } }), E.err(HC .. "options[2] must be a string of 1 to 64 bytes, got 2"))
            ccase("ch-long", "ui.choice.create{ options = { <65 bytes> } }", ch({ options = { string.rep("x", 65) } }), E.err(HC .. "options[1] must be a string of 1 to 64 bytes"))
            ccase("ch-sel-7", "ui.choice.create{ selected = 7 } [6 options]", ch({ selected = 7 }), E.err(HC .. "selected must be an integer from 1 to 6, got 7"))
            ccase("ch-sel-0", "ui.choice.create{ selected = 0 }", ch({ selected = 0 }), E.err(HC .. "selected must be an integer from 1 to 6, got 0"))
            ccase("ch-onchange", "ui.choice.create{ no onChange }", ch({ onChange = false }), E.err(HC .. "onChange must be a function, got nil"))
            ccase("ch-game", "ui.choice.create{ widget = 'game' } [off a game screen]", ch({ widget = "game" }), E.err(HC .. "widget 'game' needs a game screen host (createServer), got '"))
            ccase("ch-widget", "ui.choice.create{ widget = 'fancy' }", ch({ widget = "fancy" }), E.err(HC .. "unknown widget 'fancy' (valid: core)"))
            ccase("ch-hud", "ui.choice.create{ place = <hud corner> }", ch({ place = HUD }), E.err(HC .. "choices need a host with a cursor (journal, menu, screen)"))
            ccase("ch-enabled", "ui.choice.create{ enabled = 'no' }", ch({ enabled = "no" }), E.err(HC .. "enabled must be a boolean or nil, got 'no'"))
            ccase("ch-tip-create", "ui.choice.create{ tooltip = '' }", ch({ tooltip = "" }), E.err(HC .. "tooltip must be a string of 1 to 512 bytes, got 0 bytes"))
            ccase("ch-place", "ui.choice.create{ place = 5 }", ch({ place = 5 }), E.err(HC .. "place must be a table or nil, got 5"))
            ccase("ch-hole", "ui.choice.create{ options = { 'A', [3] = 'C' } }", ch({ options = { "A", [3] = "C" } }), E.err(HC .. "options must be a list (keys 1..n), it has a hole at 2"))
            ccase("ch-key", "ui.choice.create{ options = { 'A', x = 'B' } }", ch({ options = { "A", x = "B" } }), E.err(HC .. "options must be a list (keys 1..n), got the key 'x'"))
            ccase("ch-setvis", "ui.choice.setVisible(ch, 1)", f(CHx.setVisible, CT.ch, 1), E.err(UIP .. ".choice.setVisible: visible must be a boolean, got number"))
            ccase("ch-remove-forged", "ui.choice.remove({ id = 'ct.ch' }) [forged]", f(CHx.remove, { id = "ct.ch" }), E.err(UIP .. ".choice.remove: not a choice handle"))
            ccase("ch-isshown-checkbox", "ui.choice.isShown(<checkbox handle>)", f(CHx.isShown, CT.cb), E.err(UIP .. ".choice.isShown: not a choice handle ('ct.cb' is a checkbox)"))
            ccase("ch-tip", "ui.choice.setTooltip(ch, '')", f(CHx.setTooltip, CT.ch, ""), E.err(UIP .. ".choice.setTooltip: tooltip must be a string of 1 to 512 bytes"))
            ccase("ch-set-7", "ui.choice.set(ch, 7)", f(CHx.set, CT.ch, 7), E.err(UIP .. ".choice.set: index must be an integer from 1 to 6, got 7"))
            ccase("ch-get-slider", "ui.choice.get(<slider handle>)", f(CHx.get, CT.s1), E.err(UIP .. ".choice.get: not a choice handle ('ct.s1' is a slider)"))
            ccase("ch-get-forged", "ui.choice.get({ id = 'ct.ch' }) [forged]", f(CHx.get, { id = "ct.ch" }), E.err(UIP .. ".choice.get: not a choice handle (use the handle that choice.create returned)"))
            ccase("ch-setenabled", "ui.choice.setEnabled(ch, 'no')", f(CHx.setEnabled, CT.ch, "no"), E.err(UIP .. ".choice.setEnabled: enabled must be a boolean, got 'no'"))
            ccase("ch-ok", "ui.choice.create{ widget = 'core' } then set, get, remove [control]", function()
                local h = CHx.create{ id = "ct.okh", place = rp, options = { "X", "Y" }, widget = "core", onChange = nop }
                CHx.set(h, 2)
                local i, o = CHx.get(h)
                CHx.remove(h) CHx.remove(h)
                return i, o
            end, E.ret("2, 'Y'", function(r) return r[1] == 2 and r[2] == "Y" end))
            -- range
            ccase("rg-65", "ui.choice.range{ 0..64 step 1 }", f(CHx.range, { min = 0, max = 64, step = 1 }), E.err(RG .. "the range has 65 options, at most 64"))
            ccase("rg-extra-65", "ui.choice.range{ 0..63, extra = { 'Default' } }", f(CHx.range, { min = 0, max = 63, step = 1, extra = { "Default" } }), E.err(RG .. "the range has 65 options (1 extra), at most 64"))
            ccase("rg-step-0", "ui.choice.range{ step = 0 }", f(CHx.range, { min = 0, max = 10, step = 0 }), E.err(RG .. "step must be greater than 0, got 0"))
            ccase("rg-minmax", "ui.choice.range{ min = 5, max = 1 }", f(CHx.range, { min = 5, max = 1, step = 1 }), E.err(RG .. "min (5) is greater than max (1)"))
            ccase("rg-inf", "ui.choice.range{ max = 1/0 }", f(CHx.range, { min = 0, max = 1 / 0, step = 1 }), E.err(RG .. "max must be a finite number, got inf"))
            ccase("rg-extra", "ui.choice.range{ extra = { 5 } }", f(CHx.range, { min = 0, max = 2, step = 1, extra = { 5 } }), E.err(RG .. "extra[1] must be a string of 1 to 64 bytes, got 5"))
            ccase("rg-unknown", "ui.choice.range{ size = 1 }", f(CHx.range, { min = 0, max = 2, step = 1, size = 1 }), E.err(RG .. "unknown key 'size' (valid: extra, id, max, min, step)"))
            ccase("rg-ok", "ui.choice.range{ 0..20, extra = { 'Default' } } [control]", function() local r = CHx.range{ id = "ct.r", min = 0, max = 20, step = 1, extra = { "Default" } } return #r, r[1] end,
                E.ret("22, 'Default'", function(r) return r[1] == 22 and r[2] == "Default" end))
            -- slider
            ccase("sl-none", "ui.slider.create()", f(SLx.create), E.err(SC .. "expected a table"))
            ccase("sl-unknown", "ui.slider.create{ width = 3 }", sl({ width = 3 }), E.err(SC .. "unknown key 'width' (valid: defaultValue, enabled, hint, id, max, min, onChange, place, step, tooltip, value)"))
            ccase("sl-minmax", "ui.slider.create{ min = 6, max = 5 }", sl({ min = 6, max = 5 }), E.err(SC .. "min (6) must be less than max (5)"))
            ccase("sl-step-0", "ui.slider.create{ step = 0 }", sl({ step = 0 }), E.err(SC .. "step must be greater than 0, got 0"))
            ccase("sl-steps", "ui.slider.create{ 0..10001 step 1 }", sl({ max = 10001 }), E.err(SC .. "min..max in steps of 1 is 10001 steps, at most 10000"))
            ccase("sl-value-out", "ui.slider.create{ value = 11 } [0..10]", sl({ value = 11 }), E.err(SC .. "value 11 is outside 0..10"))
            ccase("sl-value-nan", "ui.slider.create{ value = 0/0 }", sl({ value = 0 / 0 }), E.err(SC .. "value must be a finite number or nil, got NaN"))
            ccase("sl-default-out", "ui.slider.create{ defaultValue = -1 }", sl({ defaultValue = -1 }), E.err(SC .. "defaultValue -1 is outside 0..10"))
            ccase("sl-default-inf", "ui.slider.create{ defaultValue = 1/0 }", sl({ defaultValue = 1 / 0 }), E.err(SC .. "defaultValue must be a finite number, got inf"))
            ccase("sl-hint-65", "ui.slider.create{ hint = <65 bytes> }", sl({ hint = string.rep("h", 65) }), E.err(SC .. "hint must be a string of at most 64 bytes or nil, got 65 bytes"))
            ccase("sl-onchange", "ui.slider.create{ no onChange }", sl({ onChange = false }), E.err(SC .. "onChange must be a function, got nil"))
            ccase("sl-hud", "ui.slider.create{ place = <hud corner> }", sl({ place = HUD }), E.err(SC .. "sliders need a host with a cursor (journal, menu, screen)"))
            ccase("sl-enabled", "ui.slider.create{ enabled = 1 }", sl({ enabled = 1 }), E.err(SC .. "enabled must be a boolean or nil, got 1"))
            ccase("sl-tip-create", "ui.slider.create{ tooltip = { de = 'x' } }", sl({ tooltip = { de = "x" } }), E.err(SC .. "tooltip needs an en string (the fallback)"))
            ccase("sl-place", "ui.slider.create{ place = 'row' }", sl({ place = "row" }), E.err(SC .. "place must be a table or nil, got 'row'"))
            ccase("sl-setenabled", "ui.slider.setEnabled(s1, 0)", f(SLx.setEnabled, CT.s1, 0), E.err(UIP .. ".slider.setEnabled: enabled must be a boolean, got 0"))
            ccase("sl-setvis", "ui.slider.setVisible(s1, 'yes')", f(SLx.setVisible, CT.s1, "yes"), E.err(UIP .. ".slider.setVisible: visible must be a boolean, got string"))
            ccase("sl-remove-choice", "ui.slider.remove(<choice handle>)", f(SLx.remove, CT.ch), E.err(UIP .. ".slider.remove: not a slider handle ('ct.ch' is a choice)"))
            ccase("sl-isshown-forged", "ui.slider.isShown({ id = 'ct.s1' }) [forged]", f(SLx.isShown, { id = "ct.s1" }), E.err(UIP .. ".slider.isShown: not a slider handle"))
            ccase("sl-tip", "ui.slider.setTooltip(s1, 5)", f(SLx.setTooltip, CT.s1, 5), E.err(UIP .. ".slider.setTooltip: tooltip must be a string or a table of strings by language"))
            ccase("sl-set-out", "ui.slider.set(s1, 201)", f(SLx.set, CT.s1, 201), E.err(UIP .. ".slider.set: value 201 is outside 0..200"))
            ccase("sl-set-noarg", "ui.slider.set(s1)", f(SLx.set, CT.s1), E.err(UIP .. ".slider.set: expected 2 arguments (handle, value or nil), got 1"))
            ccase("sl-setdefault-nil", "ui.slider.setDefault(s1, nil)", f(SLx.setDefault, CT.s1, nil), E.err(UIP .. ".slider.setDefault: defaultValue must be a finite number, got nil"))
            ccase("sl-setdefault-hint", "ui.slider.setDefault(s1, 5, <65 bytes>)", f(SLx.setDefault, CT.s1, 5, string.rep("h", 65)), E.err(UIP .. ".slider.setDefault: hint must be a string of at most 64 bytes"))
            ccase("sl-get-checkbox", "ui.slider.get(<checkbox handle>)", f(SLx.get, CT.cb), E.err(UIP .. ".slider.get: not a slider handle ('ct.cb' is a checkbox)"))
            ccase("sl-get-forged", "ui.slider.get({ id = 'ct.s1' }) [forged]", f(SLx.get, { id = "ct.s1" }), E.err(UIP .. ".slider.get: not a slider handle (use the handle that slider.create returned)"))
            ccase("sl-ok", "ui.slider.create{ 0..1 step 0.1 } then set(nil), setDefault, get, remove [control]", function()
                local h = SLx.create{ id = "ct.oks", place = rp, min = 0, max = 1, step = 0.1, value = 0.5, onChange = nop }
                SLx.set(h, nil) SLx.setDefault(h, 0.3, "D")
                local g = SLx.get(h)
                SLx.remove(h) SLx.remove(h)
                return g
            end, E.nilret)
            UI.row.remove(rp.row)
            ccase("removed", "ui.choice.get(<a removed choice>)", function()
                local h = CHx.create{ id = "ct.gone", place = { list = CT.list }, options = { "X" }, onChange = nop }
                CHx.remove(h)
                return CHx.get(h)
            end, E.err(UIP .. ".choice: handle 'ct.gone' was removed"))
            check(true, "CTCASES ran %d cases", CT.cases)
        end)
        step("ct: off-thread", function()
            local done = false
            LoopAsync(10, function()
                local ok, err = pcall(function()
                    local function off(key, name, fn, ...)
                        local a = table.pack(...)
                        CT.cases = CT.cases + 1
                        case("menu3.ct-off-" .. key, "ui." .. name .. "(...) [off thread]", function() return fn(table.unpack(a, 1, a.n)) end, E.err(UIP .. "." .. name .. " called off the game thread"))
                    end
                    off("cb-create", "checkbox.create", UI.checkbox.create, { id = "off" })
                    off("cb-get", "checkbox.get", UI.checkbox.get, {})
                    off("cb-set", "checkbox.set", UI.checkbox.set, {}, true)
                    off("cb-setenabled", "checkbox.setEnabled", UI.checkbox.setEnabled, {}, true)
                    off("cb-setvis", "checkbox.setVisible", UI.checkbox.setVisible, {}, true)
                    off("cb-remove", "checkbox.remove", UI.checkbox.remove, {})
                    off("cb-isshown", "checkbox.isShown", UI.checkbox.isShown, {})
                    off("cb-settip", "checkbox.setTooltip", UI.checkbox.setTooltip, {}, "x")
                    off("ch-create", "choice.create", UI.choice.create, { id = "off" })
                    off("ch-get", "choice.get", UI.choice.get, {})
                    off("ch-set", "choice.set", UI.choice.set, {}, 1)
                    off("ch-range", "choice.range", UI.choice.range, { min = 0, max = 1, step = 1 })
                    off("ch-setenabled", "choice.setEnabled", UI.choice.setEnabled, {}, true)
                    off("ch-setvis", "choice.setVisible", UI.choice.setVisible, {}, true)
                    off("ch-remove", "choice.remove", UI.choice.remove, {})
                    off("ch-isshown", "choice.isShown", UI.choice.isShown, {})
                    off("ch-settip", "choice.setTooltip", UI.choice.setTooltip, {}, "x")
                    off("sl-create", "slider.create", UI.slider.create, { id = "off" })
                    off("sl-get", "slider.get", UI.slider.get, {})
                    off("sl-set", "slider.set", UI.slider.set, {}, 1)
                    off("sl-setdefault", "slider.setDefault", UI.slider.setDefault, {}, 1)
                    off("sl-setenabled", "slider.setEnabled", UI.slider.setEnabled, {}, true)
                    off("sl-setvis", "slider.setVisible", UI.slider.setVisible, {}, true)
                    off("sl-remove", "slider.remove", UI.slider.remove, {})
                    off("sl-isshown", "slider.isShown", UI.slider.isShown, {})
                    off("sl-settip", "slider.setTooltip", UI.slider.setTooltip, {}, "x")
                end)
                if not ok then check(false, "CASE menu3.ct-off block threw: %s", firstLine(err)) end
                done = true
                return true
            end)
            return function() return done end, 10, "ct off-thread cases"
        end)
        step("ct: features", function()
            check(core.has("ui.slider.create") and core.has("ui.choice.range") and core.has("ui.checkbox.create") and core.has("ui.slider.setDefault"),
                "CTHAS core.has: ui.slider.create, ui.choice.range, ui.checkbox.create, ui.slider.setDefault")
        end)

        -- ---- the controls as created, read from the live widgets
        step("ct: read", function()
            local cbW, chW, rgW, s1W, s2W = cell(1, "ct.cb"), cell(2, "ct.ch"), cell(3, "ct.rg"), cell(4, "ct.s1"), cell(5, "ct.s2")
            local dcbW, dchW, dslW = cell(6, "ct.dcb"), cell(6, "ct.dch"), cell(6, "ct.dsl")
            if not check(cbW and chW and rgW and s1W and s2W and dcbW and dchW and dslW, "CTROW every control is in its row on window CT") then return end
            check(cname(cbW) == BUTTON_S and cname(chW) == CHOICE_S and cname(s1W) == SLIDER_S, "CTCLASS checkbox %s, choice %s, slider %s", cname(cbW), cname(chW), cname(s1W))
            check(iconOf(cbW) == "checkbox_unticked", "CT checkbox unchecked shows %s", iconOf(cbW))
            check(txt(prop(chW, "Value")) == "ONE" and enabledOf(prop(chW, "Prev")) == false and enabledOf(prop(chW, "Next")) == true,
                "CT choice first frame shows %s, prev enabled=%s, next enabled=%s", tostring(txt(prop(chW, "Value"))), tostring(enabledOf(prop(chW, "Prev"))), tostring(enabledOf(prop(chW, "Next"))))
            check(txt(prop(rgW, "Value")) == "Default", "CT range shows %s first", tostring(txt(prop(rgW, "Value"))))
            local bv, bt, bh = sliderState(s1W)
            check(bv and math.abs(bv - 150) < 0.01 and bt == "150" and bh == "DEFAULT (100)", "CT slider s1 bar=%s box=%s hint=%s", num(bv), bt, bh)
            local v2, t2 = sliderState(s2W)
            check(v2 and math.abs(v2 - 5) < 0.01 and t2 == "5", "CT slider s2 bar=%s box=%s", num(v2), t2)
            check(math.abs(opacity(dcbW) - 0.45) < 0.01 and math.abs(opacity(dchW) - 0.45) < 0.01 and math.abs(opacity(dslW) - 0.45) < 0.01
                and enabledOf(prop(dslW, "Bar")) == false and enabledOf(prop(dslW, "Box")) == false and enabledOf(prop(dchW, "Next")) == false,
                "CT disabled row dimmed (opacity %.2f/%.2f/%.2f), slider bar and box and choice arrows disabled", opacity(dcbW), opacity(dchW), opacity(dslW))
            -- the look: the slider's bar style copied from the game's Settings slider, or the generated copy and one WARN
            local tmpl = found("/Game/Graphics/MainMenu/SettingsMenu.SettingsMenu_C:WidgetTree.Slider")
            local function thick(w) return try(function() return w.WidgetStyle.BarThickness end) end
            local function tint(w) return try(function() local c = w.WidgetStyle.NormalBarImage.TintColor.SpecifiedColor return string.format("%.2f,%.2f,%.2f,%.2f", c.R, c.G, c.B, c.A) end) end
            local bar = prop(s1W, "Bar")
            say("CTSTYLE template=%s bar thickness=%s tint=%s; template thickness=%s tint=%s", tmpl and "found" or "missing", tostring(thick(bar)), tostring(tint(bar)), tostring(tmpl and thick(tmpl)), tostring(tmpl and tint(tmpl)))
            check(tmpl == nil or (thick(bar) == thick(tmpl) and tint(bar) == tint(tmpl)), "CTSTYLE the slider bar matches the game's Settings slider (or the template is missing: one WARN)")
            check(UI.slider.isShown(CT.s1) and UI.choice.isShown(CT.ch) and UI.checkbox.isShown(CT.cb), "CT isShown true for the controls on the open window")
        end)

        -- ---- the checkbox: a real click
        click("checkbox", function() return cell(1, "ct.cb") end)
        step("ct: checkbox clicked", function()
            check(UI.checkbox.get(CT.cb) == true and calls("ct.cb") == 1 and CT.last["ct.cb"].a == true and iconOf(cell(1, "ct.cb")) == "checkbox_ticked",
                "CT checkbox click value=%s calls=%d shows %s", tostring(UI.checkbox.get(CT.cb)), calls("ct.cb"), iconOf(cell(1, "ct.cb")))
            UI.checkbox.set(CT.cb, false)
            UI.checkbox.set(CT.cb, true)
            check(calls("ct.cb") == 1 and iconOf(cell(1, "ct.cb")) == "checkbox_ticked", "CT checkbox set false then true: no callback (calls=%d)", calls("ct.cb"))
        end)
        -- ---- the choice: next, next, prev; the range: next
        click("choice next 1", function() return prop(cell(2, "ct.ch"), "Next") end)
        click("choice next 2", function() return prop(cell(2, "ct.ch"), "Next") end)
        click("choice prev", function() return prop(cell(2, "ct.ch"), "Prev") end)
        click("range next", function() return prop(cell(3, "ct.rg"), "Next") end)
        step("ct: choices clicked", function()
            local i, o = UI.choice.get(CT.ch)
            check(i == 2 and o == "TWO" and calls("ct.ch") == 3 and CT.last["ct.ch"].a == 2 and txt(prop(cell(2, "ct.ch"), "Value")) == "TWO",
                "CT choice next next prev value=%s %s calls=%d shows %s", tostring(i), tostring(o), calls("ct.ch"), tostring(txt(prop(cell(2, "ct.ch"), "Value"))))
            local ri, ro = UI.choice.get(CT.rg)
            check(ri == 2 and ro == "0" and calls("ct.rg") == 1, "CT range next value=%s %s calls=%d", tostring(ri), tostring(ro), calls("ct.rg"))
            UI.choice.set(CT.ch, 1)
            check(calls("ct.ch") == 3 and enabledOf(prop(cell(2, "ct.ch"), "Prev")) == false, "CT choice set(1): no callback, prev disabled at the first option")
        end)
        click("choice prev at 1", function() return prop(cell(2, "ct.ch"), "Prev") end)
        step("ct: choice at 1", function()
            check(UI.choice.get(CT.ch) == 1 and calls("ct.ch") == 3, "CT choice prev at option 1 does nothing (no wrap; calls=%d)", calls("ct.ch"))
            UI.choice.set(CT.ch, 2)
        end)
        -- ---- the slider: a drag from the handle to 30% of the bar
        req("slider drag", function()
            local bar = prop(cell(4, "ct.s1"), "Bar")
            local x1, y = pointOf(bar, 0.75, 0.5) -- 150 of 0..200
            local x2 = pointOf(bar, 0.3, 0.5)
            CT.s1Ends = try(function() return cell(4, "ct.s1").EndCount end) -- the widget's own count of <Core>_OnSliderEnd calls
            if x1 then return string.format("drag %d %d %d %d", x1, y, x2, y) end
        end, 1.5)
        step("ct: slider dragged", function()
            local w = cell(4, "ct.s1")
            local val, box = sliderState(w)
            local got = UI.slider.get(CT.s1)
            check(got ~= nil and got ~= 150 and got >= 40 and got <= 80 and math.floor(got) == got and calls("ct.s1") == 1 and CT.last["ct.s1"].a == got,
                "CT slider drag value=%s calls=%d", num(got), calls("ct.s1"))
            check(box == string.format("%d", got or -1) and val and math.abs(val - (got or -1)) < 0.01, "CT slider drag box=%s bar=%s (the box followed the drag)", box, num(val))
            local ends = (try(function() return w.EndCount end) or -1) - (CT.s1Ends or 0)
            check(ends == 1 and calls("ct.s1") == 1, "CT slider drag: Lua heard one drag end, no drag frames (%d)", ends)
        end)
        -- ---- typing: 57, 999, abc, empty
        local function s1() return cell(4, "ct.s1") end
        typeInto("s1 57", s1, "57")
        step("ct: s1 57", function()
            local _, box = sliderState(s1())
            check(UI.slider.get(CT.s1) == 57 and calls("ct.s1") == 2 and box == "57", "CT slider typed 57 value=%s calls=%d box=%s", num(UI.slider.get(CT.s1)), calls("ct.s1"), box)
        end)
        typeInto("s1 999", s1, "999")
        step("ct: s1 999", function()
            local val, box = sliderState(s1())
            check(UI.slider.get(CT.s1) == 200 and calls("ct.s1") == 3 and box == "200" and val and math.abs(val - 200) < 0.01, "CT slider typed 999 value=%s calls=%d box=%s", num(UI.slider.get(CT.s1)), calls("ct.s1"), box)
        end)
        typeInto("s1 abc", s1, "abc")
        step("ct: s1 abc", function()
            local _, box = sliderState(s1())
            check(UI.slider.get(CT.s1) == 200 and calls("ct.s1") == 3 and box == "200", "CT slider typed abc value=%s calls=%d box=%s (the last value restored)", num(UI.slider.get(CT.s1)), calls("ct.s1"), box)
        end)
        typeInto("s1 empty", s1, "")
        step("ct: s1 empty", function()
            local val, box, hint = sliderState(s1())
            check(UI.slider.get(CT.s1) == nil and calls("ct.s1") == 4 and CT.last["ct.s1"].a == nil and box == "" and hint == "DEFAULT (100)" and val and math.abs(val - 100) < 0.01,
                "CT slider emptied value=%s calls=%d box='%s' hint=%s bar=%s (Default)", num(UI.slider.get(CT.s1)), calls("ct.s1"), box, hint, num(val))
            UI.slider.setDefault(CT.s1, 120, "DEFAULT (120)")
            local v2, _, h2 = sliderState(s1())
            check(calls("ct.s1") == 4 and v2 and math.abs(v2 - 120) < 0.01 and h2 == "DEFAULT (120)", "CT slider setDefault(120) moved the Default slider to %s, hint %s, no callback", num(v2), h2)
        end)
        typeInto("s2 2.3", function() return cell(5, "ct.s2") end, "2.3")
        step("ct: s2 2.3", function()
            local _, box = sliderState(cell(5, "ct.s2"))
            check(UI.slider.get(CT.s2) == 2.5 and calls("ct.s2") == 1 and (box == "2.5" or box == "2,5"), "CT slider step 0.5 typed 2.3 value=%s calls=%d box=%s", num(UI.slider.get(CT.s2)), calls("ct.s2"), box)
        end)
        -- ---- the disabled row: a click, a click on next, a drag and typing change nothing
        click("disabled checkbox", function() return cell(6, "ct.dcb") end)
        click("disabled next", function() return prop(cell(6, "ct.dch"), "Next") end)
        req("disabled drag", function()
            local bar = prop(cell(6, "ct.dsl"), "Bar")
            local x1, y = pointOf(bar, 0.4, 0.5)
            local x2 = pointOf(bar, 0.9, 0.5)
            if x1 then return string.format("drag %d %d %d %d", x1, y, x2, y) end
        end, 1.5)
        typeInto("disabled box", function() return cell(6, "ct.dsl") end, "9", true)
        step("ct: disabled", function()
            local val, box = sliderState(cell(6, "ct.dsl"))
            check(UI.checkbox.get(CT.dcb) == true and UI.choice.get(CT.dch) == 3 and UI.slider.get(CT.dsl) == 4 and box == "4" and val and math.abs(val - 4) < 0.01
                and calls("ct.dcb") + calls("ct.dch") + calls("ct.dsl") == 0, "CT disabled click/drag/type: values unchanged (true, 3, 4; box %s), calls=%d", box, calls("ct.dcb") + calls("ct.dch") + calls("ct.dsl"))
        end)
        -- ---- the look in a screenshot: hover the checkbox (lit), then the whole window
        req("hover checkbox", function() local x, y = at(function() return cell(1, "ct.cb") end)() if x then return string.format("move %d %d", x, y) end end, 1.5)
        shot("ct-hover")
        moveTo("ct away", neutral)
        shot("ct-controls")
        -- ---- close and reopen: values and enabled state kept
        step("ct: reopen", function()
            CT.before = { cb = UI.checkbox.get(CT.cb), ch = UI.choice.get(CT.ch), rg = UI.choice.get(CT.rg), s1 = UI.slider.get(CT.s1), s2 = UI.slider.get(CT.s2) }
            UI.screen.close(CT.W)
            CT.W = UI.screen.open{ id = "CT", close = true }
            return msAfter(1.5), 4
        end)
        step("ct: reopened", function()
            local cbW, chW, rgW, s1W, s2W = cell(1, "ct.cb"), cell(2, "ct.ch"), cell(3, "ct.rg"), cell(4, "ct.s1"), cell(5, "ct.s2")
            if not check(cbW and chW and rgW and s1W and s2W, "CTREOPEN the controls are back on window CT") then return end
            local v1, b1, h1 = sliderState(s1W)
            local v2, b2 = sliderState(s2W)
            check(iconOf(cbW) == "checkbox_ticked" and txt(prop(chW, "Value")) == "TWO" and txt(prop(rgW, "Value")) == "0"
                and b1 == "" and h1 == "DEFAULT (120)" and v1 and math.abs(v1 - 120) < 0.01 and v2 and math.abs(v2 - 2.5) < 0.01 and (b2 == "2.5" or b2 == "2,5"),
                "CTREOPEN values kept: checkbox %s, choice %s, range %s, s1 box '%s' hint %s bar %s, s2 %s", iconOf(cbW), tostring(txt(prop(chW, "Value"))), tostring(txt(prop(rgW, "Value"))), b1, h1, num(v1), b2)
            check(math.abs(opacity(cell(6, "ct.dcb")) - 0.45) < 0.01 and enabledOf(prop(cell(6, "ct.dsl"), "Bar")) == false and enabledOf(prop(cell(6, "ct.dch"), "Next")) == false,
                "CTREOPEN the disabled row is still disabled")
            check(UI.checkbox.get(CT.cb) == CT.before.cb and UI.choice.get(CT.ch) == CT.before.ch and UI.slider.get(CT.s1) == CT.before.s1, "CTREOPEN get() unchanged by the reopen")
        end)
        click("choice next after reopen", function() return prop(cell(2, "ct.ch"), "Next") end)
        step("ct: after reopen", function()
            check(UI.choice.get(CT.ch) == 3 and calls("ct.ch") == 4, "CTREOPEN the new choice widget takes clicks (value %s, calls %d)", tostring(UI.choice.get(CT.ch)), calls("ct.ch"))
            UI.screen.close(CT.W)
            CT.peerCalls = calls("ct.cb")
            return msAfter(1), 3
        end)
        -- ---- two mods: SkelPeer's checkbox on the menu; only SkelPeer's callback runs
        local function peerBox()
            local want = CORE:lower() .. ":" .. CORE .. "SkelPeer:peer.cb"
            for _, w in ipairs(FindAllOf(BUTTON_S) or {}) do
                if v(w) and try(function() return w.CoreTag:ToString() end) == want and absR(w) then return w end
            end
            return nil
        end
        click("peer checkbox", peerBox)
        step("ct: peer", function()
            check(peerBox() ~= nil and calls("ct.cb") == CT.peerCalls and calls("ct.ch") == 4, "CTPEER a click on SkelPeer's checkbox ran none of this mod's callbacks (checkbox calls %d)", calls("ct.cb"))
            say("CTPEER clicked SkelPeer's checkbox (its PEERCB line is checked by check.ps1)")
        end)
    end
    MM.controlSteps()
    -- ---- core story 27 (UI-12): the card, BACK, the "compact" gap and keyboard / gamepad focus, over the third menu.
    -- The kb-* bad-input group (gap values and texts, every hook-noise row, an off-thread nav call, focus with nothing
    -- focusable), then a key walk on window KB (12 rows TOGGLE | name | gear in a 300-high list, a choice and a slider)
    -- with real keys: KFOCUS <window> <id> after every key (the focus model and the target's HasKeyboardFocus agree),
    -- KCLICK, KCHOICE, KSLIDER, KSCROLL, KCLOSE and KRETURN; CARD (centred, hugging, padded) and GEOM (no row child cut
    -- at the right) on story 26's window and a Mod-Manager-shaped one. Shots kb-panel, kb-focus, kb-back, kb-controls,
    -- kb-mm-rows. Hung off MM (main.lua is at Lua's 200-locals limit).
    MM.kbSteps = function()
        local KB = { n = {}, cases = 0 }
        local LO = CORE:lower()
        local UIP = LO .. ".ui"
        local FO = require(LO .. ".ui.focus")
        local CC = require(LO .. ".ui.common")
        local SCR = require(LO .. ".ui.screen")
        local NROWS = 12
        local function f(fn, ...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end
        local function kcase(id, desc, fn, expect) KB.cases = KB.cases + 1; case("menu3.kb-" .. id, desc, fn, expect) end
        local function hits(id) return KB.n[id] or 0 end
        local function hit(id) return function() KB.n[id] = (KB.n[id] or 0) + 1 say("KCB %s %d", id, KB.n[id]) end end
        local function win(tagId) local s, c = screenWith(tagId) return s, c end
        local function sizeOf(w) local d = try(function() return w:GetDesiredSize() end) return d and d.X or -1, d and d.Y or -1 end

        -- KFOCUS: the model's element is want, and its target holds keyboard focus.
        local function kfocus(window, want)
            local id = SCR.stats().focus
            local el = CC.els[want]
            local t = el and FO._targetOf(el)
            local has = t ~= nil and FO._hasFocus(t)
            check(id == want and has, "KFOCUS %s %s (model %s, HasKeyboardFocus %s)", window, want, tostring(id), bool(has))
        end
        -- One real key, then (0.8 s later) the checks.
        local function kkey(k, label, after)
            step("kb: key " .. label, function()
                local done = request("key " .. k)
                local t
                return function()
                    if not done() then return false end
                    t = t or os.clock() + 0.8
                    if os.clock() < t then return false end
                    local ok, err = pcall(after)
                    if not ok then check(false, "KSTEP %s threw: %s", label, firstLine(err)) end
                    return true
                end, 30, "key " .. label
            end)
        end

        -- CARD: the card centred in the viewport (within 1 unit), its inner area the content's hug, the padding 24.
        local function cardCheck(window, tagId)
            local s = win(tagId)
            local sc = scale(menu())
            local root, card, inner = absR(s), absR(prop(s, "Card")), absR(prop(s, "Inner"))
            local st = SCR.stats().card
            if not check(root and card and inner and st, "CARD %s measurable (root %s, card %s, inner %s)", window, rsA(root), rsA(card), rsA(inner)) then return end
            local dx = ((card.l + card.r) / 2 - (root.l + root.r) / 2) / sc
            local dy = ((card.t + card.b) / 2 - (root.t + root.b) / 2) / sc
            check(math.abs(dx) <= 1 and math.abs(dy) <= 1, "CARD %s centred: offset (%.2f, %.2f) units", window, dx, dy)
            local iw, ih = (inner.r - inner.l) / sc, (inner.b - inner.t) / sc
            check(math.abs(iw - st.w) <= 1 and math.abs(ih - st.h) <= 1 and (st.clamped or (math.abs(st.w - st.contentW) < 0.01 and math.abs(st.h - st.contentH) < 0.01)),
                "CARD %s hugs: inner %.1fx%.1f, hug %.1fx%.1f (content %.1fx%.1f, clamped %s)", window, iw, ih, st.w, st.h, st.contentW, st.contentH, bool(st.clamped))
            local pl, pt = (inner.l - card.l) / sc, (inner.t - card.t) / sc
            local pr, pb = (card.r - inner.r) / sc, (card.b - inner.b) / sc
            check(math.abs(pl - 24) <= 1 and math.abs(pt - 24) <= 1 and math.abs(pr - 24) <= 1 and math.abs(pb - 24) <= 1,
                "CARD %s padding %.1f/%.1f/%.1f/%.1f (24)", window, pl, pt, pr, pb)
            local back = childTagged(prop(s, "Canvas"), "#close:" .. window)
            local br = absR(back)
            check(back ~= nil and br and math.abs((br.l - inner.l) / sc - 16) <= 1 and math.abs((inner.b - br.b) / sc - 16) <= 1
                and try(function() return back.Label:GetText():ToString() end) == "BACK",
                "CARD %s BACK bottom-left (%s in %s), label BACK", window, rsA(br), rsA(inner))
            -- Independent of refit's numbers: every visible element placed on the window (corner or absolute) lies inside
            -- Inner's rectangle (1 unit), and the extremes reach Inner's right and bottom less the corner inset (16, the
            -- default gap: a corner element keeps it from its own edges), so the card is neither cut nor loose.
            local host = CC.windowHost(window)
            local n, outside, maxR, maxB = 0, 0, -1e9, -1e9
            for _, el in ipairs(CC.order) do
                if not el.removed and not el.panel and el.visible and el.place.host == host and (el.place.corner or el.place.absolute) then
                    local w = el.ref and CC.deref(el.ref)
                    local r = w and absR(w)
                    if r and r.r > r.l then
                        n = n + 1
                        if r.l < inner.l - sc or r.t < inner.t - sc or r.r > inner.r + sc or r.b > inner.b + sc then
                            outside = outside + 1
                            say("CARD %s element '%s' %s outside inner %s", window, el.id, rsA(r), rsA(inner))
                        end
                        maxR, maxB = math.max(maxR, r.r), math.max(maxB, r.b)
                    end
                end
            end
            local gapR, gapB = (inner.r - maxR) / sc, (inner.b - maxB) / sc
            check(n >= 2 and outside == 0 and gapR >= -1 and gapR <= 16 + 1 and gapB >= -1 and gapB <= 16 + 1,
                "CARD %s contains: %d elements inside inner %s, %d outside; space right %.1f, bottom %.1f (0..16 within 1)", window, n, rsA(inner), outside, gapR, gapB)
        end

        -- GEOM: per fully visible row of a list, its last child: arranged vs desired size and right edge vs the list's
        -- visible right (the ScrollBox's and its content's, whichever is smaller), layout units.
        local function geom(window, lw, rowIds, lastIds, fixed)
            local sc = scale(menu())
            local scroll, vbox = prop(lw, "Scroll"), prop(lw, "VBox")
            local sr, vr = absR(scroll), absR(vbox)
            if not check(sr and vr, "GEOM %s list measurable (scroll %s, content %s)", window, rsA(sr), rsA(vr)) then return end
            local visR = math.min(sr.r, vr.r)
            local bw, bh = sizeOf(prop(lw, "Box"))
            say("GEOM %s list box desired %.1fx%.1f scroll %.1fx%.1f content %.1fx%.1f scrollRight %.1f contentRight %.1f",
                window, bw, bh, (sr.r - sr.l) / sc, (sr.b - sr.t) / sc, (vr.r - vr.l) / sc, (vr.b - vr.t) / sc, sr.r / sc, vr.r / sc)
            local n, worstRight, worstSize = 0, -1e9, 0
            for i, rid in ipairs(rowIds) do
                local rw = childTagged(vbox, rid)
                local rr = absR(rw)
                if rr and rr.t >= sr.t - 0.5 and rr.b <= sr.b + 0.5 and rr.b > rr.t then
                    local hb = prop(rw, "HBox")
                    local hr = absR(hb)
                    local last = childTagged(hb, lastIds[i])
                    local lr = absR(last)
                    local dw, dh = sizeOf(last)
                    if lr and hr then
                        local aw, ah = (lr.r - lr.l) / sc, (lr.b - lr.t) / sc
                        local gap = (visR - lr.r) / sc
                        say("GEOM %s row %s rowRect %s hbox %s (right %.1f) last %s arranged %.1fx%.1f desired %.1fx%.1f right %.1f visibleRight %.1f space %.1f",
                            window, rid, rsA(rr), rsA(hr), hr.r / sc, lastIds[i], aw, ah, dw, dh, lr.r / sc, visR / sc, gap)
                        n = n + 1
                        worstRight = math.max(worstRight, -gap)
                        if fixed then worstSize = math.max(worstSize, math.abs(aw - dw), math.abs(ah - dh)) end
                    end
                end
            end
            check(n >= 1 and worstRight <= -4 + 0.01, "GEOM %s no-clip: %d visible rows, every last child's right edge at least 4 units inside the visible right (worst space %.1f)", window, n, -worstRight)
            if fixed then check(n >= 1 and worstSize <= 0.5, "GEOM %s fixed-size last children arranged at their desired size (worst %.2f units)", window, worstSize) end
        end

        -- ---- the kb-* group
        step("kb: cases", function()
            local LC, RC = UIP .. ".list.create: ", UIP .. ".row.create: "
            KB.stok = UI.screen.watch(function(_, info)
                MM.sev[#MM.sev + 1] = { event = info.event, id = info.id, reason = info.reason }
                say("SEVENT %d %s id=%s reason=%s", #MM.sev, tostring(info.event), tostring(info.id), tostring(info.reason))
            end)
            KB.W = UI.screen.open{ id = "KB", close = true }
            UI.text.create{ id = "kb.title", text = "SKEL KEYS", place = { screen = KB.W, corner = "top-left" }, style = { font = "title" } }
            kcase("gap-compact", "ui.list.create{ gap = 'compact' } [control]", function()
                local h = UI.list.create{ id = "kb.gl", place = { screen = KB.W, corner = "top-right" }, size = { w = 100, h = 60 }, gap = "compact" }
                local units = CC.els["kb.gl"] and CC.els["kb.gl"].gapUnits
                UI.list.remove(h)
                return units
            end, E.ret("4", function(r) return r[1] == 4 end))
            kcase("gap-default", "ui.list.create{} [default gap]", function()
                local h = UI.list.create{ id = "kb.gd", place = { screen = KB.W, corner = "top-right" }, size = { w = 100, h = 60 } }
                local g = CC.els["kb.gd"] and CC.els["kb.gd"].gap
                UI.list.remove(h)
                return g
            end, E.ret("'compact'", function(r) return r[1] == "compact" end))
            kcase("gap-row-compact", "ui.row.create{ gap = 'compact' } [control]", function()
                local L = UI.list.create{ id = "kb.gr", place = { screen = KB.W, corner = "top-right" }, size = { w = 100, h = 60 } }
                local r = UI.row.create{ id = "kb.grr", place = { list = L }, gap = "compact" }
                local u, d = CC.els["kb.grr"].gapUnits, nil
                local r2 = UI.row.create{ id = "kb.grd", place = { list = L } }
                d = CC.els["kb.grd"].gap
                UI.row.remove(r) UI.row.remove(r2) UI.list.remove(L)
                return u, d
            end, E.ret("4, 'tight'", function(r) return r[1] == 4 and r[2] == "tight" end))
            kcase("gap-tiny", "ui.list.create{ gap = 'tiny' }", f(UI.list.create, { id = "kb.gt", place = { screen = KB.W, corner = "top-right" }, size = { w = 100, h = 60 }, gap = "tiny" }),
                E.err(LC .. "unknown gap 'tiny' (valid: compact, tight, normal, loose)"))
            kcase("gap-row-tiny", "ui.row.create{ gap = 'tiny' }", f(UI.row.create, { id = "kb.gt2", place = { screen = KB.W, corner = "top-right" }, gap = "tiny" }),
                E.err(RC .. "unknown gap 'tiny' (valid: compact, tight, normal, loose)"))
            kcase("gap-place-compact", "place = { corner, gap = 'compact' }", f(UI.text.create, { id = "kb.gp", text = "x", place = { screen = KB.W, corner = "top-right", gap = "compact" } }),
                E.err(UIP .. ".place: unknown gap 'compact' (valid: tight, normal, loose)"))
            kcase("gap-panel-compact", "ui.panel.create{ gap = 'compact' }", f(UI.panel.create, { id = "kb.gpp", place = { screen = KB.W, corner = "top-right" }, gap = "compact" }),
                E.err("unknown gap 'compact' (valid: tight, normal, loose)"))
            -- hook noise, through the hook's own function with KB's live widget (and stand-ins for the rest)
            local s = win("kb.title")
            local function nav(w, dir, act)
                return function()
                    pcall(function() w.NavDir = dir; w.NavAction = act; w.NavHandled = false end)
                    local before = SCR.stats().focus
                    FO._onNav({ get = function() return w end })
                    local handled = try(function() return w.NavHandled end)
                    return handled, SCR.stats().focus == before
                end
            end
            local unhandled = E.ret("false, focus unchanged", function(r) return r[1] == false and r[2] == true end)
            kcase("nav-dir-99", "<Core>_OnNav with NavDir 99, NavAction 3", nav(s, 99, 3), unhandled)
            kcase("nav-act-neg", "<Core>_OnNav with NavDir 7, NavAction -1", nav(s, 7, -1), unhandled)
            kcase("nav-handled", "<Core>_OnNav with NavDir Down [control]", nav(s, 3, 3), E.ret("true", function(r) return r[1] == true end))
            local foreign = { NavDir = 3, NavAction = 3, NavHandled = false, IsValid = function() return true end, GetAddress = function() return 1 end,
                CoreTag = { ToString = function() return LO .. ":OtherMod:#screen:KB" end } }
            kcase("nav-foreign", "<Core>_OnNav on another mod's window", nav(foreign, 3, 3), unhandled)
            local stale = { NavDir = 3, NavAction = 3, NavHandled = false, IsValid = function() return true end, GetAddress = function() return 2 end,
                CoreTag = { ToString = function() return LO .. ":" .. CORE .. "SkelTest:#screen:KB" end } }
            kcase("nav-stale", "<Core>_OnNav on a stale widget tagged as KB", nav(stale, 3, 3), unhandled)
            local throwing = { IsValid = function() return true end, CoreTag = { ToString = function() error("boom") end } }
            kcase("nav-throwing-tag", "<Core>_OnNav on a widget whose tag read throws", nav(throwing, 3, 3), E.ret("no handled, no fault", function(r) return r[1] ~= true and FO.stats().faults == 0 end))
            KB.X = UI.screen.open{ id = "KBX", close = true }
            UI.text.create{ id = "kbx.t", text = "X", place = { screen = KB.X, corner = "top-left" } }
            local sx = win("kbx.t")
            UI.screen.close(KB.X)
            kcase("nav-closed", "<Core>_OnNav on a window closed mid-event", nav(sx, 3, 3), unhandled)
            KB.N = UI.screen.open{ id = "KBN", close = false }
            UI.text.create{ id = "kbn.t", text = "NOTHING TO FOCUS", place = { screen = KB.N, corner = "top-left" } }
            kcase("nofocus", "a window with only text and close = false: the window itself holds focus", function()
                local sn = win("kbn.t")
                return try(function() return sn:HasKeyboardFocus() end), SCR.stats().focus
            end, E.ret("true, nil", function(r) return r[1] == true and r[2] == nil end))
            kcase("nofocus-keys", "<Core>_OnNav Down on it: Handled, nothing moves", nav(win("kbn.t"), 3, 3), E.ret("true", function(r) return r[1] == true end))
            kcase("has-focus", "core.has('ui.screen.focus'), ('ui.screen.panel'), ('ui.gap.compact')", function()
                return core.has("ui.screen.focus"), core.has("ui.screen.panel"), core.has("ui.gap.compact")
            end, E.ret("true, true, true", function(r) return r[1] == true and r[2] == true and r[3] == true end))
            return msAfter(0.5), 3
        end)
        -- Escape on the close = false window: nothing closes.
        kkey("ESCAPE", "escape on KBN", function()
            check(UI.screen.isOpen(KB.N) and rawequal(UI.screen.top(), KB.N) and count("CreateServer_C") == 0, "KNOCLOSE Escape on a close = false window: it stays open")
            UI.screen.close(KB.N)
        end)
        step("kb: off-thread", function()
            local done = false
            LoopAsync(10, function()
                local ok, err = pcall(function()
                    local before = FO.stats().ignored
                    local fake = { IsValid = function() return true end }
                    KB.cases = KB.cases + 1
                    case("menu3.kb-nav-offthread", "<Core>_OnNav [off thread]", function()
                        FO._onNav({ get = function() return fake end })
                        return FO.stats().ignored > before, FO.stats().faults
                    end, E.ret("ignored, no fault", function(r) return r[1] == true and r[2] == 0 end))
                end)
                if not ok then check(false, "CASE menu3.kb-off block threw: %s", firstLine(err)) end
                done = true
                return true
            end)
            return function() return done end, 10, "kb off-thread case"
        end)
        step("kb: cases done", function() check(true, "KBCASES ran %d cases", KB.cases) end)

        -- ---- window KB: 12 rows TOGGLE | name | gear in a 300-high list, a choice and a slider, BACK
        step("kb: window", function()
            local L = UI.list.create{ id = "kb.list", place = { screen = KB.W, corner = "top-left" }, size = { w = 640, h = 300 } }
            for i = 1, NROWS do
                local r = UI.row.create{ id = "kb.r" .. i, place = { list = L } }
                UI.button.create{ id = "kb.t" .. i, label = "TOGGLE", place = { row = r }, onClick = hit("kb.t" .. i) }
                UI.text.create{ id = "kb.x" .. i, text = "SKEL KEY ROW " .. i, place = { row = r, fill = 4 }, style = { overflow = "ellipsis" } }
                UI.button.create{ id = "kb.g" .. i, icon = { icon = "gear" }, iconSize = 28, dimmed = true, place = { row = r }, onClick = hit("kb.g" .. i) }
            end
            KB.ch = UI.choice.create{ id = "kb.ch", options = { "LOW", "MID", "HIGH" }, selected = 1, place = { screen = KB.W, corner = "top-right" },
                onChange = function(_, i) KB.n["kb.ch"] = hits("kb.ch") + 1 say("KCB kb.ch %d %d", KB.n["kb.ch"], i) end }
            KB.sl = UI.slider.create{ id = "kb.sl", min = 0, max = 10, step = 1, defaultValue = 5, hint = "DEFAULT (5)", place = { screen = KB.W, corner = "top-right" },
                onChange = function(_, v) KB.n["kb.sl"] = hits("kb.sl") + 1 say("KCB kb.sl %d %s", KB.n["kb.sl"], tostring(v)) end }
            -- reopen, so focus goes where an open puts it
            UI.screen.close(KB.W)
            KB.W = UI.screen.open{ id = "KB", close = true }
            return msAfter(1.5), 4
        end)
        step("kb: opened", function()
            kfocus("KB", "kb.t1")
            local t1 = childTagged(prop(childTagged(prop(childTagged(prop(win("kb.title"), "Canvas"), "kb.list"), "VBox"), "kb.r1"), "HBox"), "kb.t1")
            check(try(function() return t1.FocusLook end) == true, "KLOOK the focused TOGGLE shows its focus look")
            cardCheck("KB", "kb.title")
        end)
        shot("kb-panel")
        kkey("DOWN", "down 1", function() kfocus("KB", "kb.t2") end)
        -- KLOOK off and repeat: the TOGGLE that lost focus shows its own brush again; a TOGGLE focused across a UI tick (its
        -- look set again) keeps its own style in SavedStyle, not the hover look.
        local function kbToggle(i)
            return childTagged(prop(childTagged(prop(childTagged(prop(win("kb.title"), "Canvas"), "kb.list"), "VBox"), "kb.r" .. i), "HBox"), "kb.t" .. i)
        end
        kkey("RIGHT", "right 1", function()
            kfocus("KB", "kb.g2")
            local t2 = kbToggle(2)
            local n = try(function() return oname(t2.Btn.WidgetStyle.Normal.ResourceObject) end) or "?"
            check(try(function() return t2.FocusLook end) == false and n:find("M_NN_WornStrip", 1, true) ~= nil,
                "KLOOK off: the TOGGLE that lost focus shows its own normal brush again (%s)", n)
        end)
        kkey("RIGHT", "right 2", function() kfocus("KB", "kb.g2") end)
        kkey("LEFT", "left 1", function() kfocus("KB", "kb.t2") end)
        step("kb: look kept across a tick", function()
            local t = os.clock() + 0.7 -- at least one 500 ms UI tick re-applies the focus look
            return function()
                if os.clock() < t then return false end
                local t2 = kbToggle(2)
                local sv = try(function() return oname(t2.SavedStyle.Normal.ResourceObject) end) or "?"
                local cur = try(function() return oname(t2.Btn.WidgetStyle.Normal.ResourceObject) end) or "?"
                check(try(function() return t2.FocusLook end) == true and sv:find("M_NN_WornStrip", 1, true) ~= nil and cur:find("M_NN_CinematicSelection", 1, true) ~= nil,
                    "KLOOK repeat: after a UI tick the focused TOGGLE keeps its own style saved (%s) and shows the hover brush (%s)", sv, cur)
                return true
            end, 5, "look kept across a tick"
        end)
        kkey("ENTER", "enter 1", function()
            check(hits("kb.t2") == 1 and hits("kb.t1") == 0, "KCLICK Enter on the focused TOGGLE ran its onClick exactly once (%d)", hits("kb.t2"))
            kfocus("KB", "kb.t2")
        end)
        shot("kb-focus")
        for i = 3, 10 do kkey("DOWN", "down to row " .. i, function() kfocus("KB", "kb.t" .. i) end) end
        step("kb: scroll", function()
            local lw = childTagged(prop(win("kb.title"), "Canvas"), "kb.list")
            local sr, rr = absR(prop(lw, "Scroll")), absR(childTagged(prop(lw, "VBox"), "kb.r10"))
            local off = try(function() return lw.Scroll:GetScrollOffset() end) or -1
            check(sr and rr and off > 0 and rr.t >= sr.t - 0.5 and rr.b <= sr.b + 0.5, "KSCROLL row 10 %s fully inside the list's visible area %s (offset %.1f)", rsA(rr), rsA(sr), off)
        end)
        kkey("DOWN", "down to row 11", function() kfocus("KB", "kb.t11") end)
        kkey("DOWN", "down to row 12", function() kfocus("KB", "kb.t12") end)
        kkey("DOWN", "down to the choice", function() kfocus("KB", "kb.ch") end)
        kkey("RIGHT", "right on the choice", function()
            check(UI.choice.get(KB.ch) == 2 and hits("kb.ch") == 1, "KCHOICE Right on the focused choice: option %s, onChange %d", tostring(UI.choice.get(KB.ch)), hits("kb.ch"))
            kfocus("KB", "kb.ch")
        end)
        kkey("ENTER", "enter on the choice", function()
            check(UI.choice.get(KB.ch) == 2 and hits("kb.ch") == 1, "KCHOICE Enter on the focused choice: nothing changes")
        end)
        kkey("DOWN", "down to the slider", function() kfocus("KB", "kb.sl") end)
        kkey("RIGHT", "right on the slider", function()
            check(UI.slider.get(KB.sl) == 6 and hits("kb.sl") == 1, "KSLIDER Right on the Default slider: %s (defaultValue + step), onChange %d", tostring(UI.slider.get(KB.sl)), hits("kb.sl"))
        end)
        kkey("LEFT", "left on the slider", function()
            check(UI.slider.get(KB.sl) == 5 and hits("kb.sl") == 2, "KSLIDER Left: %s, onChange %d", tostring(UI.slider.get(KB.sl)), hits("kb.sl"))
            kfocus("KB", "kb.sl")
        end)
        kkey("DOWN", "down to back", function() kfocus("KB", "#close:KB") end)
        shot("kb-back")
        step("kb: window KB2", function()
            KB.since = #MM.sev
            KB.W2 = UI.screen.open{ id = "KB2", close = true }
            UI.text.create{ id = "kb2.t", text = "SKEL KEYS TWO", place = { screen = KB.W2, corner = "top-left" }, style = { font = "heading" } }
            return msAfter(1.2), 4
        end)
        step("kb: KB2 focus", function() kfocus("KB2", "#close:KB2") end)
        kkey("ESCAPE", "escape on KB2", function()
            check(sevAfter(KB.since, "closed", "KB2", "close")() and not UI.screen.isOpen(KB.W2) and UI.screen.isOpen(KB.W), "KCLOSE reason=close Escape closed the top window KB2 only")
            check(SCR.stats().focus == "#close:KB" and FO._hasFocus(FO._targetOf(CC.els["#close:KB"])), "KRETURN KB got its last-focused element back (%s)", tostring(SCR.stats().focus))
            KB.since = #MM.sev
        end)
        kkey("ESCAPE", "escape on KB", function()
            check(sevAfter(KB.since, "closed", "KB", "close")() and not UI.screen.isOpen(KB.W) and #liveAll(SCREEN_SHORT) == 0, "KCLOSE reason=close Escape closed KB, no window left")
            check(hasKeyFocus(menu()), "KRETURN the menu holds keyboard focus again")
        end)

        -- ---- story 26's window in the card, and a Mod-Manager-shaped window: CARD, GEOM, shots
        step("kb: controls window", function()
            KB.CT = UI.screen.open{ id = "CT", close = true }
            return msAfter(1.5), 4
        end)
        step("kb: controls geometry", function()
            local _, c = screenWith("ct.title")
            local lw = childTagged(c, "ct.list")
            local rows, lasts = {}, {}
            for n, last in ipairs({ "ct.cb", "ct.ch", "ct.rg", "ct.s1", "ct.s2", "ct.dsl" }) do rows[n], lasts[n] = "ct.row" .. n, last end
            geom("CT", lw, rows, lasts, false)
            geom("CT-checkbox", lw, { "ct.row1" }, { "ct.cb" }, true)
            cardCheck("CT", "ct.title")
        end)
        shot("kb-controls")
        step("kb: controls close", function() UI.screen.close(KB.CT) return msAfter(0.8), 3 end)
        step("kb: mod manager rows", function()
            KB.MM = UI.screen.open{ id = "KBM", close = true }
            UI.text.create{ id = "kbm.h", text = "MANAGE MODS", place = { screen = KB.MM, corner = "top-left" }, style = { font = "title" } }
            local L = UI.list.create{ id = "kbm.list", place = { screen = KB.MM, corner = "top-left" }, size = { w = 720, h = 400 } }
            for i = 1, 8 do
                local r = UI.row.create{ id = "kbm.r" .. i, place = { list = L } }
                UI.image.create{ id = "kbm.i" .. i, image = { game = "/Game/Graphics/MainMenu/Textures/checkbox_ticked.checkbox_ticked" }, size = 28, place = { row = r } }
                UI.text.create{ id = "kbm.n" .. i, text = "A MOD WITH A RATHER LONG NAME NUMBER " .. i, place = { row = r, fill = 4 }, style = { overflow = "ellipsis" } }
                UI.text.create{ id = "kbm.v" .. i, text = "1.0." .. i, place = { row = r, fill = 1 } }
                UI.text.create{ id = "kbm.s" .. i, text = "ACTIVE", place = { row = r, fill = 1 }, style = { font = "small" } }
                UI.button.create{ id = "kbm.g" .. i, icon = { icon = "gear" }, iconSize = 28, dimmed = true, place = { row = r }, onClick = hit("kbm.g" .. i) }
            end
            return msAfter(1.5), 4
        end)
        step("kb: mod manager geometry", function()
            local _, c = screenWith("kbm.h")
            local lw = childTagged(c, "kbm.list")
            local rows, lasts = {}, {}
            for i = 1, 8 do rows[i], lasts[i] = "kbm.r" .. i, "kbm.g" .. i end
            geom("KBM", lw, rows, lasts, true)
            cardCheck("KBM", "kbm.h")
            kfocus("KBM", "kbm.g1")
        end)
        -- Core story 28: the focused row shows the game's selection material, the others their worn strip; the focused
        -- dimmed icon-only gear has a focus face (the selection as its brush while FocusLook is on), the others none.
        KB.mmRow = function(i)
            local _, c = screenWith("kbm.h")
            return childTagged(prop(childTagged(c, "kbm.list"), "VBox"), "kbm.r" .. i)
        end
        KB.mmLook = function(sel, other)
            local rs = KB.mmRow(sel)
            local ro = KB.mmRow(other)
            local bs = try(function() return oname(rs.Background.Background.ResourceObject) end) or "?"
            local bo = try(function() return oname(ro.Background.Background.ResourceObject) end) or "?"
            local tg = require(LO .. ".ui.theme").game
            if tg.focusRowStrong then
                -- Core story 30: the strong look, an instance of the selection material with the theme's fill colours.
                local mi = try(function() return rs.Background.Background.ResourceObject end)
                local par = try(function() return oname(mi.Parent) end) or "?"
                local mc = cname(mi) -- an unnamed instance is named MID_<parent>_<n>; its class tells
                local want = tg.focusRowColors.CinematicBaseColor
                local c = try(function() return mi:K2_GetVectorParameterValue(FName("CinematicBaseColor")) end)
                local cr, cg, cb = try(function() return c.R end), try(function() return c.G end), try(function() return c.B end)
                local near = function(a, b) return type(a) == "number" and math.abs(a - b) < 0.002 end
                check(mc == "MaterialInstanceDynamic" and par:find("M_NN_CinematicSelection", 1, true) ~= nil
                    and near(cr, want.r) and near(cg, want.g) and near(cb, want.b),
                    "KLOOK row: the focused row kbm.r%d shows the strong selection (%s %s, parent %s, base %s,%s,%s)", sel, mc, bs, par,
                    tostring(cr), tostring(cg), tostring(cb))
            else
                check(bs:find("M_NN_CinematicSelection", 1, true) ~= nil, "KLOOK row: the focused row kbm.r%d shows the selection (%s)", sel, bs)
            end
            check(bo:find("M_NN_WornStrip", 1, true) ~= nil, "KLOOK row: the unfocused row kbm.r%d shows its worn strip (%s)", other, bo)
            local gs = childTagged(prop(rs, "HBox"), "kbm.g" .. sel)
            local go = childTagged(prop(ro, "HBox"), "kbm.g" .. other)
            local fs = try(function() return oname(gs.Btn.WidgetStyle.Normal.ResourceObject) end) or "?"
            local fo = try(function() return oname(go.Btn.WidgetStyle.Normal.ResourceObject) end) or "?"
            check(try(function() return gs.FocusLook end) == true and fs:find("M_NN_CinematicSelection", 1, true) ~= nil,
                "KLOOK face: the focused gear kbm.g%d shows a focus face (%s)", sel, fs)
            check(try(function() return go.FocusLook end) == false and fo:find("M_NN_CinematicSelection", 1, true) == nil,
                "KLOOK face off: the unfocused gear kbm.g%d has no face (%s)", other, fo)
        end
        step("kb: mod manager focus look", function() KB.mmLook(1, 2) end)
        shot("kb-mm-rows")
        kkey("DOWN", "mm down", function()
            kfocus("KBM", "kbm.g2")
            KB.mmLook(2, 1)
        end)
        shot("kb-mm-rows-down")
        step("kb: mod manager close", function()
            UI.screen.close(KB.MM)
            UI.screen.unwatch(KB.stok)
            check(#liveAll(SCREEN_SHORT) == 0, "KBEND every window closed")
            return msAfter(0.8), 3
        end)
    end
    MM.kbSteps()
end

-- Core story 31: core.ui.game's bad-input cases and the createserver scenario (gamescreen.lua next to this file).
SETS.GAME = dofile(scriptDir .. "\\gamescreen.lua")({ case = case, E = E, step = step, check = check, say = say, CORE = CORE,
    core = function() return core end, absR = absR, request = request, waitWorld = waitWorld, travel = travel,
    worldName = worldName, taggedIn = taggedIn, PRE_CONNECT = PRE_CONNECT, MENU_MAP = MENU_MAP })
-- Core story 32: the game-container bad-input cases and the gameinsert scenario (gameinsert.lua; gamescreen.lua's helpers).
SETS.INS = dofile(scriptDir .. "\\gameinsert.lua")({ case = case, E = E, step = step, check = check, say = say, CORE = CORE,
    core = function() return core end, absR = absR, request = request, waitWorld = waitWorld, worldName = worldName, taggedIn = taggedIn, tagOfWidget = tagOfWidget }, SETS.GAME)

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
        -- Core story 22: the pair-run roles run on their own loop (no steps, no travel: PairDriver drives the session).
        if SCENARIO == "net-host" or SCENARIO == "net-client" then SETS.NET.run(SCENARIO) return end
        if SCENARIO:match("^presence%-") then SETS.PRES.run(SCENARIO) return end -- core story 23
        if SCENARIO == "bad-input" then buildBadInput()
        elseif SCENARIO == "menu" then
            buildMenu() -- story 21 (Mod Manager story 2): the menu entry, the menu host and the window stack
        elseif SCENARIO == "createserver" then
            -- Core story 31: the create-server screen as a host; the tick profiler and DEBUG lines for the match's timing
            core.log.debugEnabled = true
            profile(true)
            SETS.GAME.build()
        elseif SCENARIO == "gameinsert" then
            -- Core story 32: elements inside the create-server screen's settings list (its insert cases in menu1)
            SETS.INS.build()
        elseif SCENARIO == "journal" then
            core.log.debugEnabled = true -- the journal attach lines (cost per open) are DEBUG; no profiler: real costs
            buildJournal()
        elseif SCENARIO == "ui" or SCENARIO == "soak" then
            core.log.debugEnabled = true -- the helpers' DEBUG lines (tick summaries, freed handles) are part of the check
            profile(true)
            if SCENARIO == "ui" then
                -- Story 18 AC 8 with two dependents: the test-only deprecated op, twice here and twice in the peer;
                -- check.ps1 wants one DEPRECATED line from each.
                for i = 1, 2 do
                    local okD, v = core.call("deprecated-test")
                    say("DEPRECATED-OP call %d ok=%s reply=%s", i, tostring(okD), tostring(v))
                end
                buildUi() buildButtons()
            else buildSoak() end
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
        -- Map service story 9: core's map service doesn't run here (no-native: core stops before starting it; no-pak:
        -- no level with its Start marker), so its map setup signal must still read "none" (check.ps1).
        if SCENARIO == "no-native" or SCENARIO == "no-pak" then
            local okS, v = pcall(readSignal)
            say("SIGNAL %s=%s", SETUP_KEY, okS and tostring(v) or ("unreadable: " .. firstLine(v)))
        end
        if SCENARIO ~= "manual" then say("END result=FAIL checks=0 failures=1 reason=connect") end
    end,
}
say("LOADED main.lua done; waiting for connect")
