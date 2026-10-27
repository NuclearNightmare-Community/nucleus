-- <Core>SkelPeer: a second throwaway dependent for story 15 AC 2 (two dependents, each owning a button: a click runs
-- only the owner's callback). Never shipped. deploy.ps1 -Test installs it as Mods/<Core>SkelPeer next to the test
-- dependent (scenario ui). It connects to core, puts one button "peer" on the Journal's map page (top-left), and logs
-- one PEERCLICK line per click it receives; the test dependent clicks it through the OS and checks that its own
-- callbacks did not run, check.ps1 that the peer's ran exactly once. It never travels, presses keys or logs FAIL.
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local ME = scriptDir:match("([^/\\]+)[/\\][Ss]cripts$")
local CORE = ME:match("^(.-)SkelPeer$") -- the one place the core's name comes from: this folder's name
local NEED = "0.2.0"

local function say(fmt, ...) print("[" .. ME .. "] " .. string.format(fmt, ...) .. "\n") end

local mods = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts[/\\]")
package.path = package.path .. ";" .. mods .. "/" .. CORE .. "/Scripts/?.lua"
local okReq, client = pcall(require, CORE:lower() .. ".client")
if not okReq then say("%s is not installed (%s)", CORE, tostring(client)) return end

local clicks = 0
client.connect{
    mod = ME, need = NEED,
    onReady = function(core)
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
