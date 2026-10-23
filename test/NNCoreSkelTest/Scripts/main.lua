-- NNCoreSkelTest: throwaway dependent that proves core's walking skeleton unattended (spec-core-v0 CAP-8).
-- Never shipped. It deliberately avoids the UI-helper API: it inserts its text widget into the HUD by hand.
--   1. calls <Core>_NativeVersion during main.lua
--   2. connects through the bootstrap + client.connect
--   3. menu -> SmallMap?listen -> menu -> SmallMap?listen with OpenLevel; in each world it re-finds the live HUD,
--      shows one text widget in InventoryUI_C.OwningCanvas next to the mic indicator, re-finds it by weak handle,
--      logs its rectangle relative to the mic, and checks that the previous world's widget handle derefs to nil.
-- Keys it can't press itself (Enter for touchdown) go to run.ps1 through request.txt / done.txt next to this file.
-- Never keeps a UObject across steps: only paths and weak handles live in S.
local CORE, NEED, ME = "NNCore", "0.1.0", "NNCoreSkelTest"

local function say(fmt, ...) print("[" .. ME .. "] " .. string.format(fmt, ...) .. "\n") end

-- 1. Native call during main.lua (before any world exists).
do
    local fn = _G[CORE .. "_NativeVersion"]
    if type(fn) == "function" then
        local ok, v, ue = pcall(fn)
        say("NATIVE main.lua %s_NativeVersion ok=%s version=%s ue4ss=%s", CORE, tostring(ok), tostring(v), tostring(ue))
    else
        say("NATIVE main.lua %s_NativeVersion missing (type=%s)", CORE, type(fn))
    end
end

-- 2. The bootstrap every dependent carries (api-contract.md, "Dependent bootstrap").
local mods = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts[/\\]")
package.path = package.path .. ";" .. mods .. "/" .. CORE .. "/Scripts/?.lua"
local okReq, client = pcall(require, CORE:lower() .. ".client")
if not okReq then
    say("%s is not installed. %s will not run. (%s)", CORE, ME, tostring(client))
    say("END result=FAIL failures=1 reason=import")
    return
end

local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local REQ, DONE = scriptDir .. "\\request.txt", scriptDir .. "\\done.txt"
os.remove(REQ); os.remove(DONE)

local MENU_MAP = "/Game/Maps/NewMainMenu"
local MATCH_MAP = "/Game/Maps/SmallLoweIsland/SmallMap"
local TEXT_PKG = "/Game/Mods/" .. CORE .. "/WBP_" .. CORE .. "Text"
local TEXT_CLASS = TEXT_PKG .. ".WBP_" .. CORE .. "Text_C"
local ACTOR_CDO = "/Game/Mods/" .. CORE .. "/ModActor.Default__ModActor_C"

local core -- set in onReady: the api table (no UObjects inside)
local S = { failures = 0, checks = 0 }

local function valid(o) return o ~= nil and o:IsValid() end
local function found(path) local o = path and StaticFindObject(path) return valid(o) and o or nil end
local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end
local function v2(v) return v and string.format("(%.0f,%.0f)", v.X, v.Y) or "nil" end
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
local function cdo() return found(ACTOR_CDO) end

local function liveHud()
    local n, hit = 0, nil
    for _, w in ipairs(FindAllOf("InventoryUI_C") or {}) do
        if valid(w) and w:IsInViewport() then n = n + 1; hit = hit or w end
    end
    return hit, n
end

local function mic()
    local p = pc()
    if valid(p) then
        local ok, w = pcall(function() return p.AudioCaptureWidget end)
        if ok and valid(w) then return w, "PlayerController.AudioCaptureWidget" end
    end
    local w = FindFirstOf("CurrentlyTalking_C")
    if valid(w) then return w, "FindFirstOf(CurrentlyTalking_C)" end
    return nil, "none"
end

local function rect(w)
    local c = cdo()
    local tl = c["" .. CORE .. "_AbsTopLeft"](c, w)
    local br = c["" .. CORE .. "_AbsBottomRight"](c, w)
    return { x = tl.X, y = tl.Y, w = br.X - tl.X, h = br.Y - tl.Y }
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
        S.prev = nil
    end)
end

local function showWidget(phase)
    step(phase .. ": show widget", function()
        local hud = found(S.hudPath)
        if not check(hud ~= nil, "HUD %s re-found by path %s", phase, tostring(S.hudPath)) then return end
        local cls = textClass()
        if not check(cls ~= nil, "TEXTCLASS %s loaded %s", phase, TEXT_CLASS) then return end
        local w = WBL():Create(hud:GetWorld() or pc():GetWorld(), cls, pc())
        if not check(valid(w), "CREATE %s text widget", phase) then return end
        w:SetText(CORE .. " skeleton: " .. phase)
        local slot = hud.OwningCanvas:AddChildToCanvas(w)
        slot:SetAutoSize(true)
        slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
        slot:SetAlignment({ X = 0, Y = 0.5 })
        slot:SetPosition({ X = 200, Y = 200 })
        S.cur = { phase = phase, handle = core.ref(w), path = pathOf(w) }
        say("WIDGET %s created %s parent=%s", phase, S.cur.path, pathOf(w:GetParent()))
        return after(1), 3, "layout"
    end)
    step(phase .. ": wait for mic", function()
        local t0 = os.time()
        return function()
            if mic() then say("MIC %s present after %ds", phase, os.time() - t0) return true end
            return false
        end, phase:find("match") and 30 or 5, phase .. " mic indicator (optional)"
    end)
    step(phase .. ": place near mic", function()
        if not S.cur then return end
        local w = core.deref(S.cur.handle)
        if not check(w ~= nil, "REFIND %s widget by handle before placing", phase) then return end
        local m, via = mic()
        S.micVia = via
        if not m then say("MIC %s not found; widget stays at its default spot", phase) return end
        local mr = rect(m)
        say("MIC %s via=%s path=%s rect abs=(%.0f,%.0f) size=(%.0f,%.0f) inViewport=%s", phase, via, pathOf(m), mr.x, mr.y, mr.w, mr.h, tostring(m:IsInViewport()))
        if mr.w <= 0 or mr.h <= 0 then say("MIC %s has no layout yet; widget stays at its default spot", phase) return end
        -- Right of the mic, vertically centred: absolute point -> the HUD canvas's local space.
        local hud = found(S.hudPath)
        local c = cdo()
        local localPt = c[CORE .. "_AbsToLocal"](c, hud.OwningCanvas, { X = mr.x + mr.w + 8, Y = mr.y + mr.h / 2 })
        w.Slot:SetPosition({ X = localPt.X, Y = localPt.Y })
        say("PLACE %s canvasLocal=%s", phase, v2(localPt))
        return after(1), 3, "layout after placing"
    end)
    step(phase .. ": refind and measure", function()
        if not S.cur then return end
        local w = core.deref(S.cur.handle)
        if not check(w ~= nil and pathOf(w) == S.cur.path, "REFIND %s widget by handle -> %s", phase, w and pathOf(w) or "nil") then return end
        local hud = found(S.hudPath)
        local parent = w:GetParent()
        check(valid(parent) and hud ~= nil and pathOf(parent) == pathOf(hud.OwningCanvas),
            "PARENT %s widget is in the live HUD canvas (%s)", phase, valid(parent) and pathOf(parent) or "none")
        local r = rect(w)
        local cr = rect(hud.OwningCanvas)
        say("HOST %s HUD visibility=%s canvas abs=(%.0f,%.0f) size=(%.0f,%.0f)", phase, tostring(hud:GetVisibility()), cr.x, cr.y, cr.w, cr.h)
        -- ESlateVisibility 1 = Collapsed, 2 = Hidden: the game hides the whole HUD (the main menu does), so children
        -- are parented but neither laid out nor drawn.
        local vis = tonumber(hud:GetVisibility())
        if vis == 1 or vis == 2 then
            check(r.w <= 0, "HIDDENHUD %s the game hides InventoryUI_C here (visibility=%d); the widget is parented but not drawn", phase, vis)
        else
            check(r.w > 0 and r.h > 0, "LAYOUT %s widget rect abs=(%.0f,%.0f) size=(%.0f,%.0f) visible=%s", phase, r.x, r.y, r.w, r.h, tostring(w:IsVisible()))
        end
        local m = mic()
        if m then
            local mr = rect(m)
            say("GEOM %s widget=(%.0f,%.0f %.0fx%.0f) mic=(%.0f,%.0f %.0fx%.0f) widgetMinusMic=(%.0f,%.0f) gapRightOfMic=%.0f centreDy=%.0f",
                phase, r.x, r.y, r.w, r.h, mr.x, mr.y, mr.w, mr.h, r.x - mr.x, r.y - mr.y, r.x - (mr.x + mr.w),
                (r.y + r.h / 2) - (mr.y + mr.h / 2))
        else
            say("GEOM %s widget=(%.0f,%.0f %.0fx%.0f) mic=none (no CurrentlyTalking_C exists; see MIC_HOOK lines) hudCanvas=(%.0f,%.0f %.0fx%.0f)",
                phase, r.x, r.y, r.w, r.h, cr.x, cr.y, cr.w, cr.h)
        end
        S.prev, S.cur = S.cur, nil
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

local function buildSteps()
    waitWorld("menu1", "NewMainMenu", 120)
    waitHud("menu1", 60)
    showWidget("menu1")
    travel("match1", MATCH_MAP, "listen")
    waitWorld("match1", "SmallMap", 150)
    checkPrevious("match1")
    touchdown("match1")
    waitHud("match1", 90)
    showWidget("match1")
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
                if waiting.what:find("(optional)", 1, true) then say("WAITED %s: not there", waiting.what)
                else check(false, "TIMEOUT %s", waiting.what) end
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

-- Every creation of the mic indicator, to learn when the game shows it (UI-3 places "near mic" relative to it).
pcall(function()
    NotifyOnNewObject("/Game/Graphics/Voice/CurrentlyTalking.CurrentlyTalking_C", function(obj)
        say("MIC_HOOK CurrentlyTalking_C created %s world=%s", obj:GetFullName(), worldName():match("/Game/[^ ]+") or "?")
    end)
end)

client.connect{
    mod = ME, need = NEED,
    onReady = function(api)
        core = api
        buildSteps()
        LoopAsync(250, function()
            ExecuteInGameThread(tick)
            return finished
        end)
    end,
    onFail = function(msg)
        say("END result=FAIL checks=0 failures=1 reason=connect")
    end,
}
say("LOADED main.lua done; waiting for connect")
