<#
.SYNOPSIS
  Installs core (C++ DLL, Lua, LogicMods pak) into a dev copy of Nuclear Nightmare, or removes it.
.DESCRIPTION
  Installs build/package/ (run build.ps1 first): ue4ss/Mods/<name>/{mod.json,dlls/main.dll,Scripts/} and
  Content/Paks/LogicMods/<name>.pak, and writes "<name> : 1" as the first line of mods.txt. Any previous install of
  core (and of the test dependent) is removed first.
  Refuses unless the installed UE4SS.dll is byte-identical to the pinned zip's, and BPModLoaderMod is present.
  -Test also installs the walking-skeleton test dependent (test/SkelTest, installed as Mods/<name>SkelTest) above Keybinds.
  -Scenario breaks one part on purpose: skeleton (all parts), no-native (no dlls/main.dll), no-pak (no LogicMods pak);
  bad-input, ui and manual install all parts like skeleton. The scenario goes to the test dependent's Scripts/scenario.txt.
  manual is for hand testing: the test dependent never travels or presses keys, and keeps a text widget in the live
  HUD's top-right corner (README.md, "Hand testing").
  Pass the main checkout's instance path when running from a worktree.
.EXAMPLE
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.0-build26022182 -Test
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.0-build26022182 -Test -Scenario manual
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.0-build26022182 -Remove
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [switch] $Test,
    [ValidateSet('skeleton', 'no-native', 'no-pak', 'bad-input', 'ui', 'manual')]
    [string] $Scenario = 'skeleton',
    [switch] $Remove
)
$ErrorActionPreference = 'Stop'
$here      = $PSScriptRoot
$name      = (Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json).name
$testName  = "${name}SkelTest"
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
if (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue) { throw 'Nuclear Nightmare is running; close it first (the DLL is locked while it runs).' }

# Clean slate: no core or test files, no core or test lines.
Remove-Item (Join-Path $modsDir $name), (Join-Path $modsDir $testName) -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $logicMods "$name.pak") -ErrorAction SilentlyContinue
$pattern = '^\s*(' + [regex]::Escape($name) + '|' + [regex]::Escape($testName) + ')\s*:'
$lines = @(Get-Content $modsTxt | Where-Object { $_ -notmatch $pattern })

if ($Remove) {
    Set-Content $modsTxt $lines
    Write-Host "$name removed (and $testName, if it was installed)."
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
}
Set-Content $modsTxt $lines

Write-Host "$name deployed (scenario $Scenario) on the shipped UE4SS.dll (sha256 $($installedHash.Substring(0,12))...):"
Get-ChildItem (Join-Path $modsDir $name) -Recurse -File | ForEach-Object { Write-Host "  Mods/$name/$($_.FullName.Substring((Join-Path $modsDir $name).Length + 1)) ($($_.Length) bytes)" }
Get-ChildItem $logicMods -Filter "$name.pak" | ForEach-Object { Write-Host "  LogicMods/$($_.Name) ($($_.Length) bytes)" }
if ($Test) { Write-Host "  Mods/$testName (test dependent)" }
Write-Host "mods.txt: $(($lines | Where-Object { $_ -match '^\s*\w+\s*:\s*1' }) -join ', ')"
