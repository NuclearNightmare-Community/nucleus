<#
.SYNOPSIS
  Installs core (C++ DLL, Lua, LogicMods pak) into a dev copy of Nuclear Nightmare, or removes it.
.DESCRIPTION
  Installs build/package/ (run build.ps1 first): ue4ss/Mods/<name>/{mod.json,dlls/main.dll,Scripts/} and
  Content/Paks/LogicMods/<name>.pak, and writes "<name> : 1" as the first line of mods.txt. Any previous install of
  core (and of the test dependent) is removed first.
  Refuses unless the installed UE4SS.dll is byte-identical to the pinned zip's, and BPModLoaderMod is present.
  -Test also installs the walking-skeleton test dependent (test/SkelTest, installed as Mods/<name>SkelTest) above Keybinds,
  and for scenarios ui, bad-input, menu (Mod Manager story 4: a second mod's checkbox) and intercept (core story 43: a second mod's rule) the second test dependent (test/SkelPeer, as Mods/<name>SkelPeer; story 15: a button of
  another mod; Mod Manager story 5: a settings change from another Lua state, with a corrupt settings.json of its own).
  Each test dependent's mod.json (settings declarations) is installed with it.
  scope-host (distribution story 14) installs the second test dependent too, with its installed mod.json "scope" set to
  "host" (the source keeps "client"), so core's host gate keeps it dormant until the machine hosts.
  For scenario bad-input it also installs core's test-only C++ part (test/SkelNative, built by build.ps1 as
  build/native-out/test/main.dll, never packaged) as Mods/<name>SkelNative: the forced missing struct member case.
  -Scenario breaks one part on purpose: skeleton (all parts), no-native (no dlls/main.dll), no-pak (no LogicMods pak);
  bad-input, ui, journal, menu, createserver (core story 31), gameinsert (core story 32), nativerow (core story 33), intercept
  (core story 43, with the second test dependent), soak and manual install all parts like skeleton. The scenario goes to the test dependent's Scripts/scenario.txt.
  net-host and net-client (core story 22) are the pair-run roles of test/pair/nucleus-scenarios.ps1 (all parts, the
  test dependent only; its mod.json "id" is skeltest, the id its core.net keys use); they run in a pair.ps1 session.
  presence-host, presence-client and presence-vanilla-host (core story 23) are the presence pair-run roles, installed
  the same way (the test dependent's mod.json "version" 0.1.0 is what presence reports).
  manual is for hand testing: the test dependent never travels or presses keys, and keeps a text widget in the live
  HUD's top-right corner (README.md, "Hand testing").
  -Staged: $Instance is the host-side staging folder of a VM run (run.ps1 -Target vm, tools/vm/vm-sp.ps1), not a game
  copy; only the running-game check is skipped (no game runs from it, and the host's game may be in use meanwhile).
  Pass the main checkout's instance path when running from a worktree.
.EXAMPLE
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Test
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Test -Scenario manual
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Remove
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [switch] $Test,
    [ValidateSet('skeleton', 'no-native', 'no-pak', 'bad-input', 'ui', 'journal', 'menu', 'createserver', 'gameinsert', 'nativerow', 'intercept', 'scope-host', 'soak', 'manual', 'net-host', 'net-client',
                 'presence-host', 'presence-client', 'presence-vanilla-host')]
    [string] $Scenario = 'skeleton',
    [switch] $Remove,
    [switch] $Staged
)
$ErrorActionPreference = 'Stop'
$here      = $PSScriptRoot
$name      = (Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json).name
$testName  = "${name}SkelTest"
$peerName  = "${name}SkelPeer"
$nativeTestName = "${name}SkelNative"
$inst      = (Resolve-Path $Instance).Path
$root      = Split-Path (Split-Path $inst)
$win64     = Join-Path $inst 'NuclearNightmare\Binaries\Win64'
$ue4ss     = Join-Path $win64 'ue4ss'
$modsDir   = Join-Path $ue4ss 'Mods'
$modsTxt   = Join-Path $modsDir 'mods.txt'
$logicMods = Join-Path $inst 'NuclearNightmare\Content\Paks\LogicMods'
$pkg       = Join-Path $here 'build\package'

if (-not (Test-Path (Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe'))) { throw "Not a game instance: $inst" }
if (-not (Test-Path (Join-Path $ue4ss 'UE4SS.dll'))) { throw "UE4SS is not installed in $win64" }
if (-not $Staged -and (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue)) { throw 'Nuclear Nightmare is running; close it first (the DLL is locked while it runs).' }

# Clean slate: no core or test files, no core or test lines.
Remove-Item (Join-Path $modsDir $name), (Join-Path $modsDir $testName), (Join-Path $modsDir $peerName), (Join-Path $modsDir $nativeTestName) -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $logicMods "$name.pak") -ErrorAction SilentlyContinue
$pattern = '^\s*(' + [regex]::Escape($name) + '|' + [regex]::Escape($testName) + '|' + [regex]::Escape($peerName) + '|' + [regex]::Escape($nativeTestName) + ')\s*:'
$lines = @(Get-Content $modsTxt | Where-Object { $_ -notmatch $pattern })

if ($Remove) {
    Set-Content $modsTxt $lines
    Write-Host "$name removed (and $testName, $peerName and $nativeTestName, if they were installed)."
    return
}

# Core's C++ part must run on the shipped UE4SS.dll, never on one we built.
$zip = Join-Path $root 'tools\_downloads\ue4ss-1181-g83330635\UE4SS_v3.0.1-1181-g83330635.zip'
if (-not (Test-Path $zip)) { throw "Pinned UE4SS zip not found at $zip (is $inst inside the workspace's game-instances/?)" }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    $entry = $z.Entries | Where-Object FullName -eq 'ue4ss/UE4SS.dll'
    $sha = [Security.Cryptography.SHA256]::Create()
    $s = $entry.Open(); $zipHash = [BitConverter]::ToString($sha.ComputeHash($s)).Replace('-', ''); $s.Dispose()
} finally { $z.Dispose() }
$installedHash = (Get-FileHash (Join-Path $ue4ss 'UE4SS.dll') -Algorithm SHA256).Hash
if ($installedHash -ne $zipHash) { throw "UE4SS.dll in $ue4ss is not the shipped one from $zip" }
if (-not (Test-Path (Join-Path $modsDir 'BPModLoaderMod'))) { throw "BPModLoaderMod is missing from $modsDir" }
if (-not ($lines -match '^\s*BPModLoaderMod\s*:\s*1')) { Write-Warning 'BPModLoaderMod is disabled in mods.txt; core will load its Blueprint class itself.' }

foreach ($p in "Mods\$name\dlls\main.dll", "Mods\$name\Scripts\main.lua", "LogicMods\$name.pak") {
    if (-not (Test-Path (Join-Path $pkg $p))) { throw "build/package/$p is missing; run build.ps1 first" }
}

# Core's files.
Copy-Item (Join-Path $pkg "Mods\$name") $modsDir -Recurse -Force
New-Item -ItemType Directory -Force $logicMods | Out-Null
switch ($Scenario) {
    'no-native' { Remove-Item (Join-Path $modsDir "$name\dlls") -Recurse -Force }
    'no-pak'    { }
    default     { }
}
if ($Scenario -ne 'no-pak') { Copy-Item (Join-Path $pkg "LogicMods\$name.pak") $logicMods -Force }

# mods.txt: core is the very first line; the test dependent goes above the built-in Keybinds entry.
$lines = @("$name : 1") + $lines
if ($Test) {
    # The test takes core's name from its installed folder name (<name>SkelTest), so the source folder is name-free.
    Copy-Item (Join-Path $here 'test\SkelTest') (Join-Path $modsDir $testName) -Recurse -Force
    Set-Content (Join-Path $modsDir "$testName\Scripts\scenario.txt") $Scenario -NoNewline
    $i = [Array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match '^\s*Keybinds\s*:' })
    $lines = if ($i -ge 0) { @($lines[0..($i-1)]) + "$testName : 1" + @($lines[$i..($lines.Count-1)]) } else { @($lines) + "$testName : 1" }
    if ($Scenario -in 'ui', 'bad-input', 'menu', 'intercept', 'scope-host') {
        Copy-Item (Join-Path $here 'test\SkelPeer') (Join-Path $modsDir $peerName) -Recurse -Force
        Set-Content (Join-Path $modsDir "$peerName\Scripts\scenario.txt") $Scenario -NoNewline
        # Distribution story 14: the installed peer is a host-scoped mod (one "scope" line rewritten, the rest kept).
        if ($Scenario -eq 'scope-host') {
            $peerJson = Join-Path $modsDir "$peerName\mod.json"
            $text = [IO.File]::ReadAllText($peerJson)
            $rx = [regex] '"scope"\s*:\s*"client"'
            if ($rx.Matches($text).Count -ne 1) { throw "test/SkelPeer/mod.json has no single `"scope`": `"client`" to set to host" }
            [IO.File]::WriteAllText($peerJson, $rx.Replace($text, '"scope": "host"', 1))
        }
        # Mod Manager story 5: bad-input starts the peer with a corrupt settings.json (core must use the defaults and log
        # exactly one WARN for it). The test dependent starts with none (its folder was just replaced).
        if ($Scenario -eq 'bad-input') { [IO.File]::WriteAllText((Join-Path $modsDir "$peerName\settings.json"), '{"peer.level": ') }
        $i = [Array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match '^\s*Keybinds\s*:' })
        $lines = if ($i -ge 0) { @($lines[0..($i-1)]) + "$peerName : 1" + @($lines[$i..($lines.Count-1)]) } else { @($lines) + "$peerName : 1" }
    }
    if ($Scenario -eq 'bad-input') {
        $testDll = Join-Path $here 'build\native-out\test\main.dll'
        if (-not (Test-Path $testDll)) { throw "build/native-out/test/main.dll is missing; run build.ps1 first (its native step builds core's test-only DLL)" }
        New-Item -ItemType Directory -Force (Join-Path $modsDir "$nativeTestName\dlls") | Out-Null
        Copy-Item $testDll (Join-Path $modsDir "$nativeTestName\dlls\main.dll") -Force
        $i = [Array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match '^\s*Keybinds\s*:' })
        $lines = if ($i -ge 0) { @($lines[0..($i-1)]) + "$nativeTestName : 1" + @($lines[$i..($lines.Count-1)]) } else { @($lines) + "$nativeTestName : 1" }
    }
}
Set-Content $modsTxt $lines

Write-Host "$name deployed (scenario $Scenario) on the shipped UE4SS.dll (sha256 $($installedHash.Substring(0,12))...):"
Get-ChildItem (Join-Path $modsDir $name) -Recurse -File | ForEach-Object { Write-Host "  Mods/$name/$($_.FullName.Substring((Join-Path $modsDir $name).Length + 1)) ($($_.Length) bytes)" }
Get-ChildItem $logicMods -Filter "$name.pak" | ForEach-Object { Write-Host "  LogicMods/$($_.Name) ($($_.Length) bytes)" }
if ($Test) { Write-Host "  Mods/$testName (test dependent)$(if ($Scenario -in 'ui', 'bad-input', 'menu', 'intercept', 'scope-host') { " and Mods/$peerName (second test dependent)" })$(if ($Scenario -eq 'bad-input') { " and Mods/$nativeTestName (core's test-only DLL)" })" }
Write-Host "mods.txt: $(($lines | Where-Object { $_ -match '^\s*\w+\s*:\s*1' }) -join ', ')"
