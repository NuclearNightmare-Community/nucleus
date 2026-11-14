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

local clicks = 0
client.connect{
    mod = ME, need = NEED,
    onReady = function(core)
        if SCENARIO == "bad-input" then
            local ok, err = pcall(settingsPeer, core)
            if not ok then say("PEERSET failed: %s", tostring(err)) end
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
