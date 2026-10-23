<#
.SYNOPSIS
  Builds core's three parts and stages them as one package: C++ DLL, Lua, LogicMods pak.
.DESCRIPTION
  Every name-bearing identifier comes from mod.json "name" (and "version"). Steps, each timed, logs in build/logs/:
    native     VS 2026 + CMake + Ninja against the pinned UE4SS source (-Ue4ssSrc), Game__Shipping__Win64, target
               CoreNative only. Then mods/cpp-spike/abi-check.ps1 must report no missing imports.
    blueprint  UE 5.6 (-Engine): compile the editor-only generator, run -run=NNCoreGen -CoreName=<name>, cook,
               repak pack --version V11 (uncompressed) /Game/Mods/<name>/ as <name>.pak.
    lua        Stage lua/main.lua and lua/pkg/ as Scripts/main.lua and Scripts/<lowercase name>/, plus a generated
               Scripts/<lowercase name>/version.lua.
    package    build/package/Mods/<name>/{mod.json,dlls/main.dll,Scripts/} and build/package/LogicMods/<name>.pak.
  Never builds anything into or copies UE4SS.dll. Only our own generated assets go into the pak.
  -Ue4ssSrc defaults to ue4ss-src/ here, then ue4ss-src/ in this repo's main checkout. It must be the pinned
  commit with submodules (tools/README.md, "UE4SS C++ mods"); clone it as mods/cpp-spike/build.ps1 does.
.EXAMPLE
  ./build.ps1
  ./build.ps1 -Steps lua,package
#>
param(
    [ValidateSet('native', 'blueprint', 'lua', 'package')]
    [string[]] $Steps = @('native', 'blueprint', 'lua', 'package'),
    [string] $Ue4ssSrc,
    [string] $Engine = 'C:\Program Files\Epic Games\UE_5.6',
    [switch] $Clean
)
$ErrorActionPreference = 'Stop'
$here     = $PSScriptRoot
$manifest = Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json
$name     = $manifest.name
$lower    = $name.ToLowerInvariant()
$version  = $manifest.version
if ($name -notmatch '^[A-Za-z][A-Za-z0-9]{1,31}$') { throw "mod.json name '$name' must be letters and digits (it becomes C++, Lua and asset names)" }
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "mod.json version '$version' is not plain semver" }

$pinned   = '8333063595fa3c49ad307f3b0f732accbb760d25'   # v3.0.1-1181-g83330635
$vcvars   = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$out      = Join-Path $here 'build'
$logs     = Join-Path $out 'logs'
$nativeB  = Join-Path $out 'native'
$proj     = Join-Path $here 'unreal\NuclearNightmare'
$uproj    = Join-Path $proj 'NuclearNightmare.uproject'

# The workspace root holds tools/launch.ps1; this repo sits under its mods/ (possibly inside a worktree).
$root = $here
while ($root -and -not (Test-Path (Join-Path $root 'tools\launch.ps1'))) { $root = Split-Path $root }
if (-not $root) { throw "Workspace root (with tools/launch.ps1) not found above $here" }
$repak = Join-Path $root 'tools\repak\repak.exe'
if (-not (Test-Path $repak)) {
    $mainWs = (git -C $root worktree list --porcelain | Select-Object -First 1) -replace '^worktree ', ''
    $repak = Join-Path $mainWs 'tools\repak\repak.exe'
}
$abiCheck = Join-Path $root 'mods\cpp-spike\abi-check.ps1'

if ($Clean) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $logs | Out-Null

$timings = [ordered]@{}
function Step([string] $step, [scriptblock] $body) {
    if ($Steps -notcontains $step) { return }
    Write-Host "== $step"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $body
    $timings[$step] = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Write-Host ("   {0} took {1} s" -f $step, $timings[$step])
}
function Run([string] $log, [string] $exe, [string[]] $argv) {
    & $exe @argv *> (Join-Path $logs $log)
    if ($LASTEXITCODE) {
        Get-Content (Join-Path $logs $log) | Select-String -Pattern 'error|Error|failed|FAILED' | Select-Object -Last 30 | ForEach-Object { Write-Host $_.Line }
        throw "$log failed with exit code $LASTEXITCODE (full log: build/logs/$log)"
    }
}

Step 'native' {
    if (-not $Ue4ssSrc) {
        $Ue4ssSrc = Join-Path $here 'ue4ss-src'
        if (-not (Test-Path $Ue4ssSrc)) {
            $mainRepo = (git -C $here worktree list --porcelain | Select-Object -First 1) -replace '^worktree ', ''
            $Ue4ssSrc = Join-Path $mainRepo 'ue4ss-src'
        }
    }
    $Ue4ssSrc = (Resolve-Path $Ue4ssSrc).Path
    $head = (& git -C $Ue4ssSrc rev-parse HEAD).Trim()
    if ($head -ne $pinned) { throw "$Ue4ssSrc is at $head, not the pinned $pinned" }
    if (-not (Test-Path (Join-Path $Ue4ssSrc 'deps\first\Unreal\CMakeLists.txt'))) { throw "$Ue4ssSrc has no submodules; run git submodule update --init --recursive there" }

    if (-not (Test-Path $vcvars)) { throw "VS 2026 Build Tools not found ($vcvars); see tools/README.md" }
    cmd /c "`"$vcvars`" >nul && set" | ForEach-Object { if ($_ -match '^([^=]+)=(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2] } }
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if ((Test-Path $cargoBin) -and ($env:PATH -notlike "*$cargoBin*")) { $env:PATH = "$cargoBin;$env:PATH" }
    foreach ($tool in 'cl', 'cmake', 'ninja', 'cargo') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool is not on PATH; see tools/README.md" }
    }
    $src = Join-Path $here 'native'
    Run 'native-configure.log' cmake @('-S', $src, '-B', $nativeB, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Game__Shipping__Win64',
        "-DUE4SS_SRC=$($Ue4ssSrc -replace '\\', '/')", "-DCORE_NAME=$name", "-DCORE_VERSION=$version")
    Run 'native-build.log' cmake @('--build', $nativeB, '--target', 'CoreNative')
    $dll = Get-ChildItem $nativeB -Recurse -Filter 'CoreNative.dll' | Where-Object { $_.FullName -notlike '*\_deps\*' } | Select-Object -First 1
    if (-not $dll) { throw 'CoreNative.dll was not produced' }
    $staged = Join-Path $out 'native-out'
    New-Item -ItemType Directory -Force $staged | Out-Null
    Copy-Item $dll.FullName (Join-Path $staged 'main.dll') -Force
    Write-Host ("   main.dll {0:N0} bytes" -f $dll.Length)
    & $abiCheck -Dll (Join-Path $staged 'main.dll')
    if ($LASTEXITCODE) { throw 'abi-check.ps1 reports imports the shipped UE4SS.dll lacks' }
}

Step 'blueprint' {
    $editor   = Join-Path $Engine 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe'
    $buildBat = Join-Path $Engine 'Engine\Build\BatchFiles\Build.bat'
    if (-not (Test-Path $editor)) { throw "UE 5.6 not found at $Engine (pass -Engine)" }
    if (-not (Test-Path $repak)) { throw 'repak not found (tools/README.md)' }
    if ($uproj.Length -gt 140) { Write-Warning "Unreal project path is $($uproj.Length) characters; UBT may hit the 260-character limit" }
    Run 'bp-compile.log' $buildBat @('NuclearNightmareEditor', 'Win64', 'Development', "-Project=$uproj", '-WaitMutex')
    Remove-Item (Join-Path $proj 'Content\Mods') -Recurse -Force -ErrorAction SilentlyContinue
    Run 'bp-generate.log' $editor @($uproj, '-run=NNCoreGen', "-CoreName=$name", '-unattended', '-nopause', '-nosplash', '-stdout', '-NoLogTimes')
    $cookedRoot = Join-Path $proj 'Saved\Cooked\Windows\NuclearNightmare\Content\Mods'
    Remove-Item $cookedRoot -Recurse -Force -ErrorAction SilentlyContinue
    Run 'bp-cook.log' $editor @($uproj, '-run=cook', '-targetplatform=Windows', '-unversioned', '-unattended', '-nopause', '-nosplash', '-stdout', '-NoLogTimes')
    $cooked = Join-Path $cookedRoot $name
    if (-not (Test-Path $cooked)) { throw "Nothing cooked at $cooked" }
    # Pak paths are relative to the mount point ../../../: stage as NuclearNightmare/Content/Mods/<name>/...
    $stage = Join-Path $out 'bp-stage'
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    $dest = Join-Path $stage "NuclearNightmare\Content\Mods\$name"
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item "$cooked\*" $dest -Recurse
    $pak = Join-Path $out "$name.pak"
    & $repak pack --version V11 -q $stage $pak
    if ($LASTEXITCODE) { throw 'repak pack failed' }
    Write-Host "   $name.pak:"; & $repak list $pak | ForEach-Object { Write-Host "     $_" }
}

Step 'lua' {
    $scripts = Join-Path $out 'lua-out\Scripts'
    Remove-Item (Split-Path $scripts) -Recurse -Force -ErrorAction SilentlyContinue
    $pkg = Join-Path $scripts $lower
    New-Item -ItemType Directory -Force $pkg | Out-Null
    Copy-Item (Join-Path $here 'lua\main.lua') $scripts
    Copy-Item (Join-Path $here 'lua\pkg\*.lua') $pkg
    Set-Content (Join-Path $pkg 'version.lua') "-- Generated by build.ps1 from mod.json; do not edit.`nreturn { name = `"$name`", version = `"$version`" }"
}

Step 'package' {
    $pkgRoot = Join-Path $out 'package'
    Remove-Item $pkgRoot -Recurse -Force -ErrorAction SilentlyContinue
    $modDir = Join-Path $pkgRoot "Mods\$name"
    New-Item -ItemType Directory -Force (Join-Path $modDir 'dlls'), (Join-Path $pkgRoot 'LogicMods') | Out-Null
    $parts = @{
        'main.dll'    = Join-Path $out 'native-out\main.dll'
        'Scripts'     = Join-Path $out 'lua-out\Scripts'
        "$name.pak"   = Join-Path $out "$name.pak"
    }
    foreach ($p in $parts.GetEnumerator()) { if (-not (Test-Path $p.Value)) { throw "Missing $($p.Key) ($($p.Value)); run its build step" } }
    Copy-Item (Join-Path $here 'mod.json') $modDir
    Copy-Item $parts['main.dll'] (Join-Path $modDir 'dlls\main.dll')
    Copy-Item $parts['Scripts'] $modDir -Recurse
    Copy-Item $parts["$name.pak"] (Join-Path $pkgRoot 'LogicMods')
    Get-ChildItem $pkgRoot -Recurse -File | ForEach-Object {
        Write-Host ("   {0,-48} {1,10:N0} bytes" -f $_.FullName.Substring($pkgRoot.Length + 1), $_.Length)
    }
}

Write-Host '== timings (s)'
$timings.GetEnumerator() | ForEach-Object { Write-Host ("   {0,-9} {1}" -f $_.Key, $_.Value) }
