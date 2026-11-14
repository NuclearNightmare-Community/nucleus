<#
.SYNOPSIS
  Core's two-player scenarios for tools/vm/pair.ps1 (the workspace's pair tooling): core.net (core story 22, Net-1),
  the host's replicated values reaching a modded client, and an unmodded client left alone; player presence (core
  story 23, Net-2): a modded client reported, forged reports changing nothing, leaving clearing it, and an unmodded
  client unaffected by its per-player actor.
.DESCRIPTION
  A -ScenarioFile for pair.ps1: dot-sourced by it after its own pair-scenarios.ps1, in the same shape (Summary,
  Prereq, VMSetup, VMRestore, BeforeJoin, AfterJoin, PlaySec, LobbyMinutes, Check, HostModPaths), and adds net and
  net-vanilla to its $PairScenarios (the last lines of this file).
    HostModPaths  core's package (build/package: Mods\<Core> and LogicMods\<Core>.pak) and the test dependent staged
                  with its role, installed into the HOST copy for this run only (core first in mods.txt), removed after.
  Roles (the test dependent's scenario.txt; test/SkelTest/Scripts/net.lua):
    host (A, both scenarios): core + <Core>SkelTest "net-host": publishes skeltest.revivesN = 8 and
               skeltest.enemyDamage = 250 when its host world starts (before B can join), the namespaced fixture key
               through the channel op, and skeltest.enemyDamage = 260 5 s after the game state's PlayerArray first holds
               2 players; logs GetServerWorldTimeSeconds() at each publish.
    net:         B (VM) = core + <Core>SkelTest "net-client": watches both keys, logs the same clock at each watch call,
               reads out of bounds, tries to publish, counts <Core>Net, reads again after the match started.
    net-vanilla: B (VM) = Restore-VMBaseline (UE4SS off, no paks): must stay in the session through PlaySec.
    presence:    host = core + <Core>SkelTest "presence-host"; B (VM) = core + <Core>SkelTest "presence-client" (the
               join, the forge sequence on B's own <Core>Presence, then B leaves with OpenLevel; LeaveAllowed lets the
               run end with one player once the host logged "PRESENCE forge-done").
    presence-vanilla: host = core + <Core>SkelTest "presence-vanilla-host"; B (VM) = Restore-VMBaseline: must stay in
               the session; the host spawns one <Core>Presence owned by B's controller and B never gets a record.
    (test/SkelTest/Scripts/presence.lua)
  Friends-only lobbies only (AGENTS.md "Networking"): pair.ps1's PairDriver creates them and stops the run if the
  flags ever say otherwise. Nothing is sent to anyone but the two test accounts.
  Judging: net -> check.ps1 -Scenario net-host on the host log, -Scenario net-client -Target vm on the VM log, and the
  latency (B's server clock at the 260 watch at most 1.0 s after the host's at the publish); net-vanilla -> pair.ps1's
  own outcome (B at every player-count sample) and check.ps1 -Scenario net-vanilla-host on the host log.
  presence -> check.ps1 -Scenario presence-host / presence-client, the join time (the host's joined event for B at most
  20.0 s of server time after core first saw B's controller) and the leave time (the host's left event at most 20.0 s
  after B's server clock at its OpenLevel); presence-vanilla -> pair.ps1's outcome and check.ps1 presence-vanilla-host.
.EXAMPLE
  # from the workspace's main checkout (core built: mods/Nucleus/build.ps1; dumps\vm.lock held; no game running):
  ./tools/vm/pair.ps1 -Scenario net -ScenarioFile mods/Nucleus/test/pair/nucleus-scenarios.ps1
  ./tools/vm/pair.ps1 -Scenario net-vanilla -ScenarioFile mods/Nucleus/test/pair/nucleus-scenarios.ps1
  ./tools/vm/pair.ps1 -Scenario presence -ScenarioFile mods/Nucleus/test/pair/nucleus-scenarios.ps1
  ./tools/vm/pair.ps1 -Scenario presence-vanilla -ScenarioFile mods/Nucleus/test/pair/nucleus-scenarios.ps1
  # after an aborted run: both games closed, host and VM copies put back
  ./tools/vm/pair.ps1 -Stop -Scenario net -ScenarioFile mods/Nucleus/test/pair/nucleus-scenarios.ps1
#>

$script:NucleusRepo = Split-Path (Split-Path $PSScriptRoot)
$script:NucleusName = (Get-Content (Join-Path $NucleusRepo 'mod.json') -Raw | ConvertFrom-Json).name
$script:NucleusPairPackage = Join-Path $NucleusRepo 'build\package'

# Where Get-NucleusNetStage stages a role (no checks, no side effects).
function Get-NucleusNetStagePath([Parameter(Mandatory)] [ValidateSet('net-host', 'net-client', 'presence-host', 'presence-client', 'presence-vanilla-host')] [string] $Role) {
    Join-Path (Join-Path ([IO.Path]::GetTempPath()) "nn-nucleus-stage-$Role") "${NucleusName}SkelTest"
}

# For VMRestore and -Stop: placeholders named like core, its pak and the test dependent (vm-deploy -Remove uses only
# the names), so cleanup works without build/package and without staging anything.
function Get-NucleusNetRemovePaths {
    $r = Join-Path ([IO.Path]::GetTempPath()) 'nn-nucleus-remove'
    New-Item -ItemType Directory -Force (Join-Path $r $NucleusName), (Join-Path $r "${NucleusName}SkelTest") | Out-Null
    $pak = Join-Path $r "$NucleusName.pak"
    if (-not (Test-Path $pak)) { Set-Content $pak '' -NoNewline }
    @((Join-Path $r "${NucleusName}SkelTest"), (Join-Path $r $NucleusName), $pak)
}

# The test dependent staged with its role: a copy of test/SkelTest named <Core>SkelTest (it takes core's name from its
# folder) with scenario.txt, exactly what deploy.ps1 -Test -Scenario <role> installs. Returns the folder.
function Get-NucleusNetStage([Parameter(Mandatory)] [ValidateSet('net-host', 'net-client', 'presence-host', 'presence-client', 'presence-vanilla-host')] [string] $Role) {
    if (-not (Test-Path (Join-Path $NucleusPairPackage "Mods\$NucleusName\mod.json"))) { throw "No $NucleusName package at $NucleusPairPackage; build it with build.ps1 (not while a game runs)." }
    if (-not (Test-Path (Join-Path $NucleusPairPackage "LogicMods\$NucleusName.pak"))) { throw "No $NucleusName.pak in $NucleusPairPackage\LogicMods; rebuild." }
    $dest = Get-NucleusNetStagePath -Role $Role
    $stage = Split-Path $dest
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item (Join-Path $NucleusRepo 'test\SkelTest') $dest -Recurse
    Remove-Item (Join-Path $dest 'Scripts\request.txt'), (Join-Path $dest 'Scripts\done.txt'), (Join-Path $dest 'settings.json') -ErrorAction SilentlyContinue
    Set-Content (Join-Path $dest 'Scripts\scenario.txt') $Role -NoNewline
    $dest
}

# check.ps1 on one machine's log.
function Get-NucleusNetCheck([string] $Log, [string] $Scenario, [ValidateSet('host', 'vm')] [string] $Target = 'host') {
    if (-not ($Log -and (Test-Path $Log))) { return [ordered]@{ Scenario = $Scenario; Verdict = 'FAIL'; Note = "no log ($Log)" } }
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $NucleusRepo 'check.ps1') -Log $Log -Scenario $Scenario -Target $Target 2>&1 | Out-String
    [ordered]@{ Scenario = $Scenario; Verdict = $(if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }); Failures = @($out -split "`r?`n" | Where-Object { $_ -match '^FAIL' }) }
}

# AC 2: B's GetServerWorldTimeSeconds() when its watch saw enemyDamage = 260, against the host's at the publish.
function Get-NucleusNetLatency([string] $HostLog, [string] $VMLog) {
    $T = [regex]::Escape("${NucleusName}SkelTest")
    $h = Select-String -Path $HostLog -Pattern "\[$T\] NETPUB skeltest\.enemyDamage=260 ok=true .* server=([\d.]+) " -ErrorAction SilentlyContinue | Select-Object -First 1
    $c = Select-String -Path $VMLog -Pattern "\[$T\] NETWATCH skeltest\.enemyDamage value=260 .* server=([\d.]+) " -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $h -or -not $c) { return [ordered]@{ Verdict = 'FAIL'; Note = "missing: host NETPUB 260 $([bool]$h), client NETWATCH 260 $([bool]$c)" } }
    $hs = [double]::Parse($h.Matches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    $cs = [double]::Parse($c.Matches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    $d = $cs - $hs
    [ordered]@{ Verdict = $(if ($d -le 1.0) { 'PASS' } else { 'FAIL' }); HostServerSec = $hs; ClientServerSec = $cs; DeltaSec = [math]::Round($d, 3); Limit = 1.0 }
}

# Story 23 AC (join): the host's PRESENCEEV joined for B (skeltest) against core's first 'saw controller' line, both
# on the host's GetServerWorldTimeSeconds(); at most 20.0 s (user 2026-11-14: the VM's map-load stall alone is 5-6 s), logged as DeltaSec.
function Get-NucleusPresenceJoin([string] $HostLog) {
    $N = [regex]::Escape($NucleusName); $T = [regex]::Escape("${NucleusName}SkelTest")
    $s = Select-String -Path $HostLog -Pattern "\[$N\] PRESENCE saw controller \S+ \(player \S+\) server=([\d.]+) " -ErrorAction SilentlyContinue | Select-Object -First 1
    $j = Select-String -Path $HostLog -Pattern "\[$T\] PRESENCEEV joined pid=-?\d+ mod=skeltest version=0\.1\.0 previous=nil local=false server=([\d.]+)" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $s -or -not $j) { return [ordered]@{ Verdict = 'FAIL'; Note = "missing: saw controller $([bool]$s), joined $([bool]$j)" } }
    $a = [double]::Parse($s.Matches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    $b = [double]::Parse($j.Matches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    $d = $b - $a
    [ordered]@{ Verdict = $(if ($d -ge 0 -and $d -le 20.0) { 'PASS' } else { 'FAIL' }); SawControllerSec = $a; JoinedSec = $b; DeltaSec = [math]::Round($d, 3); Limit = 20.0 }
}

# Story 23 AC (leave): the host's PRESENCEEV left for B's skeltest 7.7.7 (B's real leave, after forge step 4; step 3's
# left of skeltest 0.1.0 doesn't count) against B's server clock as it called OpenLevel; at most 20.0 s (the host's connection close after OpenLevel took 6-11 s), and never earlier
# than B's leaving line.
function Get-NucleusPresenceLeave([string] $HostLog, [string] $VMLog) {
    $T = [regex]::Escape("${NucleusName}SkelTest")
    $c = Select-String -Path $VMLog -Pattern "\[$T\] PRESENCECL leaving server=([\d.]+)" -ErrorAction SilentlyContinue | Select-Object -First 1
    $h = Select-String -Path $HostLog -Pattern "\[$T\] PRESENCEEV left pid=-?\d+ mod=skeltest version=nil previous=7\.7\.7 local=false server=([\d.]+)" -ErrorAction SilentlyContinue | Select-Object -Last 1
    if (-not $c -or -not $h) { return [ordered]@{ Verdict = 'FAIL'; Note = "missing: client leaving $([bool]$c), host left $([bool]$h)" } }
    $cs = [double]::Parse($c.Matches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    $hs = [double]::Parse($h.Matches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    $d = $hs - $cs
    [ordered]@{ Verdict = $(if ($d -ge 0 -and $d -le 20.0) { 'PASS' } else { 'FAIL' }); ClientLeavingSec = $cs; HostLeftSec = $hs; DeltaSec = [math]::Round($d, 3); Limit = 20.0 }
}

function Get-NucleusNetNotJoined {
    if ($result -and -not $result.Joined) {
        [ordered]@{ Verdict = 'FAIL'; Note = "not judged: B never joined (pair outcome: $($result.Outcome))" }
    }
}

$script:NucleusNetPrereq = {
    # The host copy must not have core or its test dependent of its own (pair.ps1 installs them for the run).
    $own = @($NucleusName, "${NucleusName}SkelTest", "${NucleusName}SkelPeer", "${NucleusName}SkelNative" | Where-Object { Test-Path (Join-Path $modsDir $_) }) +
        @("$NucleusName.pak" | Where-Object { Test-Path (Join-Path $inst "NuclearNightmare\Content\Paks\LogicMods\$_") })
    if ($own.Count) { throw "The net scenarios need a host copy without $NucleusName; found $($own -join ', ') in $inst. Remove them first (deploy.ps1 -Remove)." }
}

$script:NucleusPairScenarios = @{
    'net' = @{
        Summary = "Core story 22: A (host) = $NucleusName + SkelTest net-host publishes revivesN=8 and enemyDamage=250 before B joins and enemyDamage=260 5 s after 2 players; B (VM) = $NucleusName + SkelTest net-client reads both within 1 s of holding the actor, sees 260 within 1.0 s of server time, reads 0..200 as out-of-bounds, can't publish, never spawns the actor"
        Prereq = $NucleusNetPrereq
        HostModPaths = { @($NucleusPairPackage, (Get-NucleusNetStage -Role 'net-host')) }
        VMSetup = {
            $client = Get-NucleusNetStage -Role 'net-client'
            Restore-VMBaseline
            Invoke-VMDeploy -UE4SS On
            # Core first in mods.txt, then the test dependent (vm-deploy adds each above Keybinds in turn).
            & (Join-Path $Workspace 'tools/vm/vm-deploy.ps1') -Path $NucleusPairPackage -First
            Invoke-VMDeploy -Path $client
        }
        VMRestore = {
            Invoke-VMDeploy -Remove -Path (Get-NucleusNetRemovePaths)
            Restore-VMBaseline
        }
        AfterJoin = {
            Wait-HostLine "\[$([regex]::Escape("${NucleusName}SkelTest"))\] NETPUB skeltest\.enemyDamage=260 " 120 | Out-Null
            $script:LastAction = @{ Name = 'host published 260'; Time = Get-Date }
            Save-ShotAt -Seconds 3 -Name 'net-260' -Expect 'B in the lobby as normal; no error dialog'
        }
        PlaySec = 60; LobbyMinutes = 1
        Check = {
            $nj = Get-NucleusNetNotJoined; if ($nj) { return $nj }
            $hostLog = Join-Path $outDir "$Label.host.UE4SS.log"
            $r = [ordered]@{
                Host = (Get-NucleusNetCheck $hostLog 'net-host')
                Client = (Get-NucleusNetCheck $vmLogPath 'net-client' -Target vm)
                Latency = (Get-NucleusNetLatency $hostLog $vmLogPath)
                Session = $result.Outcome
            }
            $r.Verdict = if ($r.Host.Verdict -eq 'PASS' -and $r.Client.Verdict -eq 'PASS' -and $r.Latency.Verdict -eq 'PASS' -and $result.Outcome -eq 'PASS') { 'PASS' } else { 'FAIL' }
            $r
        }
    }
    'net-vanilla' = @{
        Summary = "Core story 22: A (host) = $NucleusName + SkelTest net-host (spawns ${NucleusName}Net, publishes as in net); B (VM) vanilla (UE4SS off, no paks) stays in the session at every sample through PlaySec"
        Prereq = $NucleusNetPrereq
        HostModPaths = { @($NucleusPairPackage, (Get-NucleusNetStage -Role 'net-host')) }
        VMSetup = { Restore-VMBaseline }
        VMRestore = { Restore-VMBaseline }
        AfterJoin = {
            Wait-HostLine "\[$([regex]::Escape("${NucleusName}SkelTest"))\] NETPUB skeltest\.enemyDamage=260 " 120 | Out-Null
            $script:LastAction = @{ Name = 'host published 260'; Time = Get-Date }
            Save-ShotAt -Seconds 3 -Name 'vanilla-260' -Expect 'B (vanilla) in the lobby as normal; no error dialog, no disconnect message'
        }
        PlaySec = 60; LobbyMinutes = 1
        Check = {
            $nj = Get-NucleusNetNotJoined; if ($nj) { return $nj }
            $r = [ordered]@{
                Host = (Get-NucleusNetCheck (Join-Path $outDir "$Label.host.UE4SS.log") 'net-vanilla-host')
                Session = $result.Outcome
                PlayersDuringPlay = ($result.PlayersDuringPlay -join ',')
            }
            $r.Verdict = if ($r.Host.Verdict -eq 'PASS' -and $result.Outcome -eq 'PASS') { 'PASS' } else { 'FAIL' }
            $r
        }
    }
}

# Core story 23: player presence.
$script:NucleusPairScenarios['presence'] = @{
    Summary = "Core story 23: A (host) = $NucleusName + SkelTest presence-host; B (VM) = $NucleusName + SkelTest presence-client: B reported with skeltest=0.1.0 within 2 s of its controller, the forge sequence (33 pairs, 9000 characters, bad pairs, a 50-report flood) changes nothing else and logs once, compatible true then false, B leaves (OpenLevel) and its record and actor go"
    Prereq = $NucleusNetPrereq
    HostModPaths = { @($NucleusPairPackage, (Get-NucleusNetStage -Role 'presence-host')) }
    VMSetup = {
        $client = Get-NucleusNetStage -Role 'presence-client'
        Restore-VMBaseline
        Invoke-VMDeploy -UE4SS On
        & (Join-Path $Workspace 'tools/vm/vm-deploy.ps1') -Path $NucleusPairPackage -First
        Invoke-VMDeploy -Path $client
    }
    VMRestore = {
        Invoke-VMDeploy -Remove -Path (Get-NucleusNetRemovePaths)
        Restore-VMBaseline
    }
    AfterJoin = {
        $T = [regex]::Escape("${NucleusName}SkelTest")
        Wait-HostLine "\[$T\] PRESENCE forge-done " 120 | Out-Null
        $script:LastAction = @{ Name = 'forge done'; Time = Get-Date }
        Save-ShotAt -Seconds 2 -Name 'presence-forged' -Expect 'B in the lobby as normal; no error dialog'
        Wait-HostLine "\[$T\] END result=" 60 | Out-Null
    }
    # B leaves on purpose 10 s after the last forge step: from the host's forge-done line on, one player is fine.
    LeaveAllowed = { [bool](Find-HostLine "\[$([regex]::Escape("${NucleusName}SkelTest"))\] PRESENCE forge-done") }
    PlaySec = 30; LobbyMinutes = 1
    Check = {
        $nj = Get-NucleusNetNotJoined; if ($nj) { return $nj }
        $hostLog = Join-Path $outDir "$Label.host.UE4SS.log"
        $r = [ordered]@{
            Host = (Get-NucleusNetCheck $hostLog 'presence-host')
            Client = (Get-NucleusNetCheck $vmLogPath 'presence-client' -Target vm)
            Join = (Get-NucleusPresenceJoin $hostLog)
            Leave = (Get-NucleusPresenceLeave $hostLog $vmLogPath)
            Session = $result.Outcome
        }
        $r.Verdict = if ($r.Host.Verdict -eq 'PASS' -and $r.Client.Verdict -eq 'PASS' -and $r.Join.Verdict -eq 'PASS' -and $r.Leave.Verdict -eq 'PASS' -and $result.Outcome -eq 'PASS') { 'PASS' } else { 'FAIL' }
        $r
    }
}
$script:NucleusPairScenarios['presence-vanilla'] = @{
    Summary = "Core story 23: A (host) = $NucleusName + SkelTest presence-vanilla-host (spawns one ${NucleusName}Presence owned by B's controller); B (VM) vanilla (UE4SS off, no paks) stays in the session at every sample through PlaySec and never gets a record"
    Prereq = $NucleusNetPrereq
    HostModPaths = { @($NucleusPairPackage, (Get-NucleusNetStage -Role 'presence-vanilla-host')) }
    VMSetup = { Restore-VMBaseline }
    VMRestore = { Restore-VMBaseline }
    AfterJoin = {
        Wait-HostLine "\[$([regex]::Escape("${NucleusName}SkelTest"))\] END result=" 120 | Out-Null
        $script:LastAction = @{ Name = 'presence-vanilla-host done'; Time = Get-Date }
        Save-ShotAt -Seconds 2 -Name 'presence-vanilla' -Expect 'B (vanilla) in the lobby as normal; no error dialog, no disconnect message'
    }
    PlaySec = 60; LobbyMinutes = 1
    Check = {
        $nj = Get-NucleusNetNotJoined; if ($nj) { return $nj }
        $r = [ordered]@{
            Host = (Get-NucleusNetCheck (Join-Path $outDir "$Label.host.UE4SS.log") 'presence-vanilla-host')
            Session = $result.Outcome
            PlayersDuringPlay = ($result.PlayersDuringPlay -join ',')
        }
        $r.Verdict = if ($r.Host.Verdict -eq 'PASS' -and $result.Outcome -eq 'PASS') { 'PASS' } else { 'FAIL' }
        $r
    }
}

# Into pair.ps1's table (it checks that no built-in scenario is replaced); a test may dot-source this file without it.
if ($script:PairScenarios -is [hashtable]) { foreach ($k in $NucleusPairScenarios.Keys) { $script:PairScenarios[$k] = $NucleusPairScenarios[$k] } }
