<#
.SYNOPSIS
  Builds core's three parts and stages them as one package: C++ DLL, Lua, LogicMods pak.
.DESCRIPTION
  Every name-bearing identifier comes from mod.json "name" (and "version"). Steps, each timed, logs in build/logs/:
    native     VS 2026 + CMake + Ninja against the pinned UE4SS source (-Ue4ssSrc), Game__Shipping__Win64, targets
               CoreNative (main.dll) and CoreNativeTest (core's test-only DLL, test/SkelNative; build/native-out/test/,
               never packaged), <name>Restart (the relaunch helper, core story 45: build/native-out/bin/) and
               <name>RestartTest (its test build, build/native-out/test/, never packaged) and <name>CatalogTest (the
               catalog code's console test build, Mod Manager v2 story 2: build/native-out/test/, never packaged). Then
               mods/cpp-spike/abi-check.ps1 must report no missing imports for both DLLs, the helper and the catalog test
               exe may import only Windows system DLLs (dumpbin /dependents), and Windows Defender scans main.dll and the
               helper (MpCmdRun -Scan -ScanType 3 -File
               -DisableRemediation; exit 2, a threat, refuses the build; build/logs/defender.txt records each result).
    blueprint  UE 5.6 (-Engine): compile the editor-only generator, run -run=CoreGen -CoreName=<name>, cook,
               repak pack --version V11 (uncompressed) /Game/Mods/<name>/ as <name>.pak.
               Map markers (map service story 4): CoreGen also writes /Game/Mods/<name>/Map/ (the twelve
               BP_Marker_<Kind> and E_MarkerItem) and their layout (-Layout=build/logs/layout-generated.txt): per
               marker its components, its properties in order with their types, its functions, and the enum's
               entries. That layout must equal the committed golden file unreal/map-markers.layout line for line: the
               layout is frozen (cooked levels store a placed marker's values by position), so any difference fails.
               Author template (-Template, default the workspace's mods/map-spike/unreal/NuclearNightmare): it carries
               committed copies of the 13 uncooked files at Content/Mods/<name>/Map/. -RefreshTemplate rewrites them
               from this build; without it they are left alone. Either way their layout is read back (CoreGen
               -LayoutOnly on the copies, swapped in for the generated files and swapped back) and must equal the
               golden file too; uncooked packages aren't byte-identical across runs, so layout, not bytes.
               Icons (core story 24): CoreGen imports art/icons/*.png (-IconDir) as /Game/Mods/<name>/Icons/T_<Key>;
               the pak must hold every icon ($iconAssets) and WBP_<name>Image (and every other widget, WBP_<name>Choice and
               WBP_<name>Slider since Mod Manager story 4, WBP_<name>Textbox since Mod Manager v2 story 4).
               Pack guard: the pak may hold only Content/Mods/<name>/ and must hold all 13; no staged file may name a
               /Game path outside /Game/Mods/<name>/, and no cooked marker may name BasicShapes, _Preview,
               EditorResources or a component template <Name>_GEN_VARIABLE other than DefaultSceneRoot's (the one
               component that isn't editor-only): its editor-only preview slots and icon must be stripped.
    lua        Stage lua/main.lua and lua/pkg/ (with lua/pkg/ui/, lua/pkg/map/, lua/pkg/settings/, lua/pkg/net/ and lua/pkg/input/) as Scripts/main.lua and Scripts/<lowercase name>/, plus a generated
               Scripts/<lowercase name>/version.lua.
    package    build/package/Mods/<name>/{mod.json,dlls/main.dll,bin/<name>Restart.exe,Scripts/,LICENSES/monocypher.txt}
               and build/package/LogicMods/<name>.pak. LICENSES/monocypher.txt is Monocypher's LICENCE.md (main.dll
               contains Monocypher, CC0-1.0 OR BSD-2-Clause; native/third_party/monocypher-4.0.2/README.md).
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
    # The author template project (an Unreal project folder) whose committed Content/Mods/<name>/Map/ copies are checked.
    [string] $Template,
    # Rewrite the template's 13 map files (12 markers and E_MarkerItem) from this build.
    [switch] $RefreshTemplate,
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
# Story 18: the compatibility floor, the oldest need (">=X.Y.Z") this core still serves; raised only in a breaking major.
$floor    = "$($manifest.compat.floor)"
if ($floor -notmatch '^\d+\.\d+\.\d+$') { throw "mod.json compat.floor '$floor' is not plain semver (story 18: the oldest need this core serves)" }
if ([version]$floor -gt [version]$version) { throw "mod.json compat.floor $floor is above version $version" }

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
# -RefreshTemplate writes files: only into a template named explicitly. From a Nucleus worktree the default is the main
# checkout's map-spike, which a refresh must never rewrite behind the user's back.
if ($RefreshTemplate -and -not $PSBoundParameters.ContainsKey('Template')) {
    throw "-RefreshTemplate rewrites the template's map files, so it needs -Template <the template project> passed explicitly (the default would be $(Join-Path $root 'mods\map-spike\unreal\NuclearNightmare'))"
}
if (-not $Template) { $Template = Join-Path $root 'mods\map-spike\unreal\NuclearNightmare' }
# The map markers' kinds (CoreGenCommandlet.cpp BuildMarkers) and the Item enum: the assets under /Game/Mods/<name>/Map/.
$markerKinds = 'Start', 'Item', 'Intel', 'Computer', 'Generator', 'Lever', 'EnemySpawner', 'EnemyWaypoint', 'Landing', 'Map', 'Location', 'Sky'
$mapAssets   = @($markerKinds | ForEach-Object { "BP_Marker_$_" }) + 'E_MarkerItem'
$golden      = Join-Path $here 'unreal\map-markers.layout'
# Core story 24: core's icons (art/icons/<file>.png -> Icons/T_<Asset>) and the widgets the pak must hold.
$iconDir     = Join-Path $here 'art\icons'
$iconAssets  = 'T_Gear', 'T_CheckboxOn', 'T_CheckboxOff', 'T_Lock', 'T_Warning', 'T_Restart',
               'T_ScopeHost', 'T_ScopeClient', 'T_ScopeHostPlus', 'T_ScopeBoth', 'T_ScopeUnknown'
$iconFiles   = 'gear', 'checkbox-on', 'checkbox-off', 'lock', 'warning', 'restart',
               'scope-host', 'scope-client', 'scope-host-plus', 'scope-both', 'scope-unknown'

# The layout lines of a CoreGen -Layout= file, or of the golden file: every line but blanks and # comments.
function Get-Layout([string] $file) { @(Get-Content $file | Where-Object { $_.Trim() -and -not $_.StartsWith('#') }) }
# Throws when $file's layout differs from the golden file's, naming the first differing lines and $hint.
function Assert-Layout([string] $file, [string] $what, [string] $hint) {
    if (-not (Test-Path $golden)) { throw "No golden layout file at $golden" }
    if (-not (Test-Path $file)) { throw "No layout written for $what ($file)" }
    $want = Get-Layout $golden
    $have = Get-Layout $file
    $diff = @()
    for ($i = 0; $i -lt [math]::Max($want.Count, $have.Count); $i++) {
        $w = if ($i -lt $want.Count) { $want[$i] } else { '(nothing)' }
        $h = if ($i -lt $have.Count) { $have[$i] } else { '(nothing)' }
        if ($w -cne $h) { $diff += "line $($i + 1): want '$w', have '$h'" }
    }
    if ($diff) {
        throw "The layout of $what differs from the golden file $golden ($($diff.Count) lines; full layout: $file):`n  $(($diff | Select-Object -First 12) -join "`n  ")`n$hint"
    }
    Write-Host "   layout of $what = golden ($($want.Count) lines): OK"
}

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
    Run 'native-build.log' cmake @('--build', $nativeB, '--target', 'CoreNative', 'CoreNativeTest', "$($name)Restart", "$($name)RestartTest", "$($name)CatalogTest")
    $staged = Join-Path $out 'native-out'
    # Core's DLL (shipped) and core's test-only DLL (test/SkelNative; deploy.ps1 -Test installs it, never packaged).
    foreach ($t in @(@{ Name = 'CoreNative'; Out = 'main.dll' }, @{ Name = 'CoreNativeTest'; Out = 'test\main.dll' })) {
        $dll = Get-ChildItem $nativeB -Recurse -Filter "$($t.Name).dll" | Where-Object { $_.FullName -notlike '*\_deps\*' } | Select-Object -First 1
        if (-not $dll) { throw "$($t.Name).dll was not produced" }
        $dest = Join-Path $staged $t.Out
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Copy-Item $dll.FullName $dest -Force
        Write-Host ("   {0} {1:N0} bytes ({2})" -f $t.Out, $dll.Length, $t.Name)
        & $abiCheck -Dll $dest
        if ($LASTEXITCODE) { throw "abi-check.ps1 reports imports the shipped UE4SS.dll lacks ($($t.Name))" }
    }
    # Core story 45: the relaunch helper (shipped as bin/<name>Restart.exe) and its test build (never packaged); Mod Manager
    # v2 story 2: the catalog test exe (never packaged; it may also import WinHTTP and CNG, as main.dll's catalog code does).
    foreach ($t in @(@{ Name = "$($name)Restart"; Out = "bin\$($name)Restart.exe" }, @{ Name = "$($name)RestartTest"; Out = "test\$($name)RestartTest.exe" },
                     @{ Name = "$($name)CatalogTest"; Out = "test\$($name)CatalogTest.exe"; Net = $true })) {
        $exe = Get-ChildItem $nativeB -Recurse -Filter "$($t.Name).exe" | Where-Object { $_.FullName -notlike '*\_deps\*' } | Select-Object -First 1
        if (-not $exe) { throw "$($t.Name).exe was not produced" }
        $dest = Join-Path $staged $t.Out
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Copy-Item $exe.FullName $dest -Force
        Write-Host ("   {0} {1:N0} bytes ({2})" -f $t.Out, $exe.Length, $t.Name)
        # Windows system libraries only (the C runtime is linked in statically): never UE4SS, never anything of ours.
        $deps = @(& dumpbin /nologo /dependents $dest | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.dll$' })
        # Mod Manager v2 story 3: the helper applies staged changes and hashes them with Windows CNG (bcrypt).
        $allowed = if ($t.Net) { '^(?i:kernel32|user32|shell32|ole32|advapi32|winhttp|bcrypt|crypt32|api-ms-win-[a-z0-9-]+)\.dll$' } else { '^(?i:kernel32|user32|shell32|ole32|advapi32|bcrypt|api-ms-win-[a-z0-9-]+)\.dll$' }
        $foreign = @($deps | Where-Object { $_ -notmatch $allowed })
        if (-not $deps -or $foreign) { throw "$($t.Name).exe imports $(if ($foreign) { $foreign -join ', ' } else { 'nothing readable' }); only Windows system DLLs are allowed" }
        Write-Host "   $($t.Out) imports: $($deps -join ', ')"
    }
    # Windows Defender scans what ships (main.dll and the helper); a detection refuses the build. Never an exclusion,
    # never an online scanner (story 8).
    # build/logs/defender.txt: one line per scan, written as each result comes in (before any refusal), so a detection's
    # evidence is on record and no earlier build's file survives.
    $defLog = Join-Path $logs 'defender.txt'
    Remove-Item -LiteralPath $defLog -ErrorAction SilentlyContinue
    $scanner = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) { Add-Content $defLog "ERROR scanner not found: $scanner"; throw "Windows Defender's scanner not found: $scanner" }
    $ver = ''
    try {
        $st = Get-MpComputerStatus -ErrorAction Stop
        $ver = " signatures=$($st.AntivirusSignatureVersion) engine=$($st.AMEngineVersion) platform=$($st.AMProductVersion)"
    } catch { }
    foreach ($rel in 'main.dll', "bin\$($name)Restart.exe") {
        $f = Join-Path $staged $rel
        $sha = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        $text = (@(& $scanner -Scan -ScanType 3 -File $f -DisableRemediation 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' | ')
        $code = $LASTEXITCODE
        $same = (Test-Path -LiteralPath $f -PathType Leaf) -and (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -eq $sha
        $result = if ($code -eq 2) { "THREAT (MpCmdRun exit 2): $text" } elseif ($code -ne 0) { "FAILED (MpCmdRun exit $code): $text" } elseif (-not $same) { "CHANGED or gone after the scan: $text" } else { 'no threats found' }
        $line = "SCAN $($rel -replace '\\', '/') sha256=$sha result=$result$ver"
        Add-Content $defLog $line
        Write-Host "   defender: $line"
        if ($code -eq 2) { throw "Windows Defender flagged $rel`: $text (story 8: stop, set the story blocked with this evidence; never add an exclusion)" }
        if ($code -ne 0) { throw "Windows Defender's scan of $rel failed (MpCmdRun exit $code): $text" }
        if (-not $same) { throw "$rel is gone or changed after the Windows Defender scan: $text" }
    }
}

Step 'blueprint' {
    # -Name="value" arguments go to the editor verbatim (FParse::Value reads a quoted value whole, so a path with a space
    # works); the standard argument mode would escape the quotes.
    $PSNativeCommandArgumentPassing = 'Legacy'
    $editor   = Join-Path $Engine 'Engine\Binaries\Win64\UnrealEditor-Cmd.exe'
    $buildBat = Join-Path $Engine 'Engine\Build\BatchFiles\Build.bat'
    if (-not (Test-Path $editor)) { throw "UE 5.6 not found at $Engine (pass -Engine)" }
    if (-not (Test-Path $repak)) { throw 'repak not found (tools/README.md)' }
    if ($uproj.Length -gt 140) { Write-Warning "Unreal project path is $($uproj.Length) characters; UBT may hit the 260-character limit" }
    Run 'bp-compile.log' $buildBat @('NuclearNightmareEditor', 'Win64', 'Development', "-Project=$uproj", '-WaitMutex')
    Remove-Item (Join-Path $proj 'Content\Mods') -Recurse -Force -ErrorAction SilentlyContinue
    $layoutGen = Join-Path $logs 'layout-generated.txt'
    Remove-Item $layoutGen -ErrorAction SilentlyContinue
    $noIcon = @($iconFiles | Where-Object { -not (Test-Path (Join-Path $iconDir "$_.png")) })
    if ($noIcon) { throw "Missing icon PNGs in $($iconDir): $($noIcon -join ', ') (art/icons/README.md)" }
    Run 'bp-generate.log' $editor @($uproj, '-run=CoreGen', "-CoreName=$name", "-Layout=`"$layoutGen`"", "-IconDir=`"$iconDir`"", '-unattended', '-nopause', '-nosplash', '-stdout', '-NoLogTimes')
    Select-String -Path (Join-Path $logs 'bp-generate.log') -Pattern 'ICON /Game' -CaseSensitive | ForEach-Object { Write-Host "   $($_.Line -replace '^.*?ICON', 'ICON')" }
    Select-String -Path (Join-Path $logs 'bp-generate.log') -Pattern 'MARKER .*(enum|markers and)' -CaseSensitive | ForEach-Object { Write-Host "   $($_.Line -replace '^.*?MARKER', 'MARKER')" }
    $mapSrc = Join-Path $proj "Content\Mods\$name\Map"
    $want = @($mapAssets | ForEach-Object { "$_.uasset" } | Sort-Object)
    $have = @(Get-ChildItem $mapSrc -File -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object)
    if (($have -join '|') -cne ($want -join '|')) { throw "CoreGen wrote $($have -join ', ') under $mapSrc; want exactly $($want -join ', ')" }
    Assert-Layout $layoutGen "the generated markers (/Game/Mods/$name/Map/)" ("The markers' layout is frozen once released (map service story 4): restore it in CoreGenCommandlet.cpp BuildMarkers. " +
        "Only before the first release, and only for an intended change, copy $layoutGen over the golden file, then rebuild with -RefreshTemplate.")

    # The author template's committed copies (never generated a second time there): rewritten only with -RefreshTemplate.
    $tplHint = "Rewrite them with: build.ps1 -Steps blueprint -RefreshTemplate -Template <the template project>, then commit them in the workspace."
    if (-not (Test-Path (Join-Path $Template 'NuclearNightmare.uproject'))) { throw "No template project at $Template (pass -Template <Unreal project folder>)" }
    $mapDst = Join-Path $Template "Content\Mods\$name\Map"
    if ($RefreshTemplate) {
        Remove-Item $mapDst -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $mapDst | Out-Null
        Copy-Item (Join-Path $mapSrc '*.uasset') $mapDst
        Write-Host "   template: -RefreshTemplate wrote the $($want.Count) map files to $mapDst"
    }
    $dstNames = @(Get-ChildItem $mapDst -File -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object)
    if (($dstNames -join '|') -cne ($want -join '|')) { throw "The template's $mapDst holds $(if ($dstNames) { $dstNames -join ', ' } else { 'nothing' }); want exactly $($want -join ', '). $tplHint" }
    # Read the copies' layout back in this project: swap them in for the generated files, then swap those back.
    $keep = Join-Path $out 'map-generated'
    Remove-Item $keep -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item $mapSrc $keep -Recurse
    $layoutTpl = Join-Path $logs 'layout-template.txt'
    Remove-Item $layoutTpl -ErrorAction SilentlyContinue
    try {
        Remove-Item (Join-Path $mapSrc '*') -Force
        Copy-Item (Join-Path $mapDst '*.uasset') $mapSrc
        Run 'bp-layout-template.log' $editor @($uproj, '-run=CoreGen', "-CoreName=$name", '-LayoutOnly', "-Layout=`"$layoutTpl`"", '-unattended', '-nopause', '-nosplash', '-stdout', '-NoLogTimes')
    } finally {
        Remove-Item (Join-Path $mapSrc '*') -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $keep '*') $mapSrc
    }
    Assert-Layout $layoutTpl "the template's copies ($mapDst)" $tplHint
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
    # Pack guard: no staged file names a /Game path outside our own folder, and the cooked markers carry no preview.
    function Text($f) { [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($f.FullName)) }
    foreach ($f in Get-ChildItem $stage -Recurse -File) {
        $g = @([regex]::Matches((Text $f), '/Game/[A-Za-z0-9_/\-]+') | ForEach-Object Value | Where-Object { $_ -notlike "/Game/Mods/$name/*" } | Sort-Object -Unique)
        if ($g) { throw "Refusing: the cooked $($f.Name) names /Game paths outside /Game/Mods/$($name): $($g -join ', ')" }
    }
    $cookedMap = Join-Path $dest 'Map'
    foreach ($a in $mapAssets) {
        $files = @(Get-ChildItem $cookedMap -File -Filter "$a.*" -ErrorAction SilentlyContinue)
        if (-not ($files | Where-Object Extension -eq '.uasset')) { throw "$a was not cooked (no $a.uasset under $cookedMap)" }
        if ($a -like 'BP_Marker_*') {
            $t = ($files | ForEach-Object { Text $_ }) -join ''
            # The root (not editor-only) keeps its template DefaultSceneRoot_GEN_VARIABLE; any other template is a slot or the icon.
            $hit = [regex]::Match($t, 'BasicShapes|_Preview|EditorResources|\w*(?<!DefaultSceneRoot)_GEN_VARIABLE', 'IgnoreCase')
            if ($hit.Success) { throw "Refusing: the cooked $a names $($hit.Value) (its editor-only preview slots or icon were not stripped)" }
        }
    }
    Write-Host "   $($mapAssets.Count) map assets cooked; no preview or icon, no foreign /Game path: OK"
    $pak = Join-Path $out "$name.pak"
    & $repak pack --version V11 -q $stage $pak
    if ($LASTEXITCODE) { throw 'repak pack failed' }
    $list = @(& $repak list $pak)
    $foreign = @($list | Where-Object { $_ -notlike "NuclearNightmare/Content/Mods/$name/*" })
    if ($foreign) { Remove-Item $pak; throw "Refusing: $name.pak would hold files outside Content/Mods/$($name): $($foreign -join ', ')" }
    $missing = @($mapAssets | Where-Object { $list -notcontains "NuclearNightmare/Content/Mods/$name/Map/$_.uasset" })
    # Core story 24: every icon ($iconAssets; the scope icons since Mod Manager story 12) and every widget, the image's included. Mod Manager story 4: the choice and the slider.
    # Core story 38: the lift (a dragged row's copy). Mod Manager v2 story 4: the text box.
    $missing += @($iconAssets | Where-Object { $list -notcontains "NuclearNightmare/Content/Mods/$name/Icons/$_.uasset" } | ForEach-Object { "Icons/$_" })
    $missing += @('Text', 'Panel', 'Button', 'List', 'Row', 'Lift', 'Screen', 'Image', 'Choice', 'Slider', 'Textbox' | ForEach-Object { "WBP_$name$_" } |
        Where-Object { $list -notcontains "NuclearNightmare/Content/Mods/$name/$_.uasset" })
    # Core story 22: the replicated host state <name>Net; core story 23: the per-player <name>Presence (a missing class
    # must fail the build).
    $missing += @("$($name)Net", "$($name)Presence" | Where-Object { $list -notcontains "NuclearNightmare/Content/Mods/$name/$_.uasset" })
    if ($missing) { Remove-Item $pak; throw "Refusing: $name.pak lacks $($missing -join ', ')" }
    Write-Host "   $name.pak:"; $list | ForEach-Object { Write-Host "     $_" }
}

Step 'lua' {
    $scripts = Join-Path $out 'lua-out\Scripts'
    Remove-Item (Split-Path $scripts) -Recurse -Force -ErrorAction SilentlyContinue
    $pkg = Join-Path $scripts $lower
    New-Item -ItemType Directory -Force $pkg | Out-Null
    Copy-Item (Join-Path $here 'lua\main.lua') $scripts
    Copy-Item (Join-Path $here 'lua\pkg\*.lua') $pkg
    # UI helpers: Scripts/<lowercase name>/ui/*.lua, required as <lowercase name>.ui.<module>
    New-Item -ItemType Directory -Force (Join-Path $pkg 'ui') | Out-Null
    Copy-Item (Join-Path $here 'lua\pkg\ui\*.lua') (Join-Path $pkg 'ui')
    # The map service: Scripts/<lowercase name>/map/*.lua, required as <lowercase name>.map.<module>
    New-Item -ItemType Directory -Force (Join-Path $pkg 'map') | Out-Null
    Copy-Item (Join-Path $here 'lua\pkg\map\*.lua') (Join-Path $pkg 'map')
    # The settings service (Mod Manager story 5): Scripts/<lowercase name>/settings/*.lua (store and schema run in core's
    # state, client in each dependent's); json.lua comes with lua/pkg/*.lua above.
    New-Item -ItemType Directory -Force (Join-Path $pkg 'settings') | Out-Null
    Copy-Item (Join-Path $here 'lua\pkg\settings\*.lua') (Join-Path $pkg 'settings')
    # Core story 22 (Net-1): Scripts/<lowercase name>/net/*.lua (state is pure; host runs in core's state, client in
    # each dependent's); modid.lua (the id normalizer) comes with lua/pkg/*.lua above.
    New-Item -ItemType Directory -Force (Join-Path $pkg 'net') | Out-Null
    Copy-Item (Join-Path $here 'lua\pkg\net\*.lua') (Join-Path $pkg 'net')
    # Core story 44: Scripts/<lowercase name>/input/*.lua (service and screen run in core's state; input.lua, the
    # dependent's API and the shared checks, comes with lua/pkg/*.lua above).
    New-Item -ItemType Directory -Force (Join-Path $pkg 'input') | Out-Null
    Copy-Item (Join-Path $here 'lua\pkg\input\*.lua') (Join-Path $pkg 'input')
    foreach ($f in 'json.lua', 'restart.lua', 'catalog.lua', 'apply.lua', 'input.lua', 'input\service.lua', 'input\screen.lua', 'settings\store.lua', 'settings\schema.lua', 'settings\client.lua', 'modid.lua', 'net\state.lua', 'net\host.lua', 'net\client.lua',
                'net\presence.lua', 'net\players.lua') {
        if (-not (Test-Path (Join-Path $pkg $f))) { throw "lua step: $f was not staged" }
    }
    Set-Content (Join-Path $pkg 'version.lua') "-- Generated by build.ps1 from mod.json; do not edit.`nreturn { name = `"$name`", version = `"$version`", floor = `"$floor`" }"
}

Step 'package' {
    $pkgRoot = Join-Path $out 'package'
    Remove-Item $pkgRoot -Recurse -Force -ErrorAction SilentlyContinue
    $modDir = Join-Path $pkgRoot "Mods\$name"
    New-Item -ItemType Directory -Force (Join-Path $modDir 'dlls'), (Join-Path $modDir 'bin'), (Join-Path $modDir 'LICENSES'), (Join-Path $pkgRoot 'LogicMods') | Out-Null
    $parts = @{
        'main.dll'    = Join-Path $out 'native-out\main.dll'
        'helper'      = Join-Path $out "native-out\bin\$($name)Restart.exe"
        'Scripts'     = Join-Path $out 'lua-out\Scripts'
        "$name.pak"   = Join-Path $out "$name.pak"
        'monocypher'  = Join-Path $here 'native\third_party\monocypher-4.0.2\LICENCE.md'
    }
    foreach ($p in $parts.GetEnumerator()) { if (-not (Test-Path $p.Value)) { throw "Missing $($p.Key) ($($p.Value)); run its build step" } }
    Copy-Item (Join-Path $here 'mod.json') $modDir
    Copy-Item $parts['main.dll'] (Join-Path $modDir 'dlls\main.dll')
    Copy-Item $parts['helper'] (Join-Path $modDir "bin\$($name)Restart.exe")
    # Mod Manager v2 story 2: main.dll contains Monocypher; its licence notice ships with it.
    Copy-Item $parts['monocypher'] (Join-Path $modDir 'LICENSES\monocypher.txt')
    Copy-Item $parts['Scripts'] $modDir -Recurse
    Copy-Item $parts["$name.pak"] (Join-Path $pkgRoot 'LogicMods')
    Get-ChildItem $pkgRoot -Recurse -File | ForEach-Object {
        Write-Host ("   {0,-48} {1,10:N0} bytes" -f $_.FullName.Substring($pkgRoot.Length + 1), $_.Length)
    }
}

Write-Host '== timings (s)'
$timings.GetEnumerator() | ForEach-Object { Write-Host ("   {0,-9} {1}" -f $_.Key, $_.Value) }
