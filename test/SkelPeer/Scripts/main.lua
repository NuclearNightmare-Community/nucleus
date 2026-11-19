-- <Core>SkelPeer: a second throwaway dependent. Never shipped. deploy.ps1 -Test installs it as Mods/<Core>SkelPeer next
-- to the test dependent (scenarios ui and bad-input) and writes the scenario to Scripts/scenario.txt here.
-- ui (story 15 AC 2: two dependents, each owning a button; a click runs only the owner's callback): it connects to
-- core, puts one button "peer" on the Journal's map page (top-left), and logs one PEERCLICK line per click it
-- receives; the test dependent clicks it through the OS and checks that its own callbacks did not run, check.ps1 that
-- the peer's ran exactly once.
-- bad-input (Mod Manager story 5, the settings service from another Lua state): reads its own setting (deploy.ps1
-- wrote a corrupt settings.json: core falls back to the default with one WARN), then waits at the menu for the test
-- dependent's cue (<core>.test.settings.watching = 1, its watcher registered) and changes the test dependent's int
-- setting with core.settings.setFor; the test dependent's watcher must see it within 1 s.
-- menu (Mod Manager story 4: two mods' controls on one screen): one checkbox "peer.cb" on the title-screen menu
-- (bottom-right); it logs one PEERCB line per change it hears. The test dependent clicks it through the OS with its own
-- controls live; check.ps1 checks that the peer heard exactly its own click and none of the test dependent's.
-- intercept (core story 43: several dependents): in pass 1 an any skip on the Bat card's click, and card A's click
-- (held by the test dependent) refused, logged as PEERFN lines; nothing in pass 2. The test dependent then stops it
-- with UninstallMod.
-- It never travels, presses keys or logs FAIL.
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local ME = scriptDir:match("([^/\\]+)[/\\][Ss]cripts$")
local CORE = ME:match("^(.-)SkelPeer$") -- the one place the core's name comes from: this folder's name
local NEED = "^0.3.0" -- the old caret form on purpose (story 18 item 4: read as >=0.3.0)

local function say(fmt, ...) print("[" .. ME .. "] " .. string.format(fmt, ...) .. "\n") end

local SCENARIO = "ui"
do
    local f = io.open(scriptDir .. "\\scenario.txt", "r")
    if f then SCENARIO = (f:read("*a") or ""):match("^%s*([%w%-]+)") or SCENARIO; f:close() end
end

local mods = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts[/\\]")
package.path = package.path .. ";" .. mods .. "/" .. CORE .. "/Scripts/?.lua"
local okReq, client = pcall(require, CORE:lower() .. ".client")
if not okReq then say("%s is not installed (%s)", CORE, tostring(client)) return end

local WATCHING = CORE:lower() .. ".test.settings.watching"
local PEER_AT = CORE:lower() .. ".test.settings.peerAt"
local TARGET = CORE .. "SkelTest"

-- Mod Manager story 5: once the test dependent's watcher is registered, set its int setting from this Lua state.
local function settingsPeer(core)
    local okG, v = pcall(core.settings.get, "peer.level")
    say("PEERGET peer.level ok=%s value=%s", tostring(okG), tostring(v))
    local handle
    local done = false
    local okL, res = pcall(LoopInGameThreadWithDelay, 250, function()
        if done then if handle then pcall(CancelDelayedAction, handle) end return end
        local okW, cue = pcall(function() return ModRef:GetSharedVariable(WATCHING) end)
        if not okW or cue ~= 1 then return end
        done = true
        local now = _G[CORE .. "_ClockMicros"]()
        ModRef:SetSharedVariable(PEER_AT, now)
        local okS, r, why = pcall(core.settings.setFor, TARGET, "test.count", 42)
        say("PEERSET %s test.count=42 ok=%s result=%s%s", TARGET, tostring(okS), tostring(r), why and (" " .. tostring(why)) or "")
        if handle then pcall(CancelDelayedAction, handle) end
    end)
    if okL then handle = res else say("PEERSET could not start its loop: %s", tostring(res)) end
end

-- Core story 43 (intercept, pass 1): once the test dependent's rule on card A's click is in (cue <core>.test.fn.cue = 1)
-- and the create-world screen is open, an any skip on the Bat card's click, then card A's click, which the test
-- dependent holds: refused. Sets <core>.test.fn.peer to 1 (done) or 2 (something unexpected). Pass 2 (after the
-- test dependent's Ctrl+R; its Scripts/intercept-pass.txt exists): nothing.
local FN_CUE, FN_DONE = CORE:lower() .. ".test.fn.cue", CORE:lower() .. ".test.fn.peer"
local function interceptPeer(core)
    local pf = io.open(mods .. "/" .. TARGET .. "/Scripts/intercept-pass.txt", "r")
    if pf then pf:close() say("PEERFN pass 2: nothing to do") return end
    local CLICK = "BndEvt__EnemySlot_Button_Button_48_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
    local A_CLICK = "/Game/Graphics/MainMenu/EnemySelect/EnemySlot_Button.EnemySlot_Button_C:" .. CLICK
    local BAT_CLICK = "/Game/Graphics/MainMenu/EnemySelect/BatSlot_Button1.BatSlot_Button1_C:" .. CLICK
    local handle
    local done = false
    local function try(f) local ok, v = pcall(f) if ok then return v end return nil end
    local okL, res = pcall(LoopInGameThreadWithDelay, 250, function()
        if done then if handle then pcall(CancelDelayedAction, handle) end return end
        if try(function() return ModRef:GetSharedVariable(FN_CUE) end) ~= 1 then return end
        local screen
        for _, w in ipairs(FindAllOf("CreateServer_C") or {}) do
            if try(function() return w:IsValid() and w:IsInViewport() end) then screen = w end
        end
        if not screen then return end
        done = true
        local result = 2
        local ok, err = pcall(function()
            local cardA
            local arr = screen.EnemySlotButtons
            for i = 1, arr:GetArrayNum() do
                local c = arr[i]
                if c:IsValid() and c.EnemyType == 0 then cardA = c end
            end
            local id = core.fn.intercept{ fn = BAT_CLICK, action = "skip" }
            say("PEERFN bat any skip id=%s", tostring(id))
            local okA, errA = pcall(core.fn.intercept, { fn = A_CLICK, target = cardA, action = "skip" })
            if okA then say("PEERFN UNEXPECTED card A's click was not refused (rule %s)", tostring(errA))
            else say("PEERFN refused: %s", tostring(errA)) result = 1 end
        end)
        if not ok then say("PEERFN failed: %s", tostring(err)) end
        ModRef:SetSharedVariable(FN_DONE, result)
        if handle then pcall(CancelDelayedAction, handle) end
    end)
    if okL then handle = res else say("PEERFN could not start its loop: %s", tostring(res)) end
end

local clicks = 0
client.connect{
    mod = ME, need = NEED,
    onReady = function(core)
        if SCENARIO == "intercept" then
            local ok, err = pcall(interceptPeer, core)
            if not ok then say("PEERFN failed: %s", tostring(err)) end
            return
        end
        if SCENARIO == "bad-input" then
            local ok, err = pcall(settingsPeer, core)
            if not ok then say("PEERSET failed: %s", tostring(err)) end
            return
        end
        if SCENARIO == "menu" then
            local changes = 0
            local okC, hc = pcall(core.ui.checkbox.create, {
                id = "peer.cb", place = { host = "menu", corner = "bottom-right" },
                onChange = function(handle, checked)
                    changes = changes + 1
                    say("PEERCB %d '%s' %s", changes, tostring(handle.id), tostring(checked))
                end,
            })
            say("PEER ready: checkbox %s", okC and ("'" .. hc.id .. "' created") or ("failed: " .. tostring(hc)))
            return
        end
        -- Story 18 AC 8: the test-only deprecated op, twice; one DEPRECATED line for this dependent (check.ps1, ui).
        for i = 1, 2 do
            local okD, v = core.call("deprecated-test")
            say("DEPRECATED-OP call %d ok=%s reply=%s", i, tostring(okD), tostring(v))
        end
        local ok, h = pcall(core.ui.button.create, {
            id = "peer", label = "Peer button", place = { host = "journal", corner = "top-left" },
            onClick = function(handle)
                clicks = clicks + 1
                say("PEERCLICK %d '%s'", clicks, tostring(handle.id))
            end,
        })
        say("PEER ready: button %s", ok and ("'" .. h.id .. "' created") or ("failed: " .. tostring(h)))
    end,
    onFail = function(msg) say("PEER could not connect: %s", tostring(msg)) end,
}
