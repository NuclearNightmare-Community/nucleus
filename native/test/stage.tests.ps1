<#
.SYNOPSIS
  Tests staging installs from the catalog (Mod Manager v2 story 5: <Core>_CatalogStage's code) through the catalog
  test exe's -Stage, without the game and without the live catalog.
.DESCRIPTION
  Builds release-style zips at run time with .NET ZipArchive (byte patches for bad headers), lists them in an index
  signed at run time with test keys, serves them through the local HTTPS fixture server (story 2's
  tools/release/tests/https-fixture-server.ps1) and stages them into a temporary install layout (-Root, story 3's
  layout). Every row of the story's I/O matrix but Bad Lua input (run.ps1 -Scenario bad-input has those):
    - a plain install: put lines at install-layout targets, modstxt <Name> on, staged files named by their SHA-256, the
      payload {txn, owners, ops}
    - dependencies: three pairs in one stage, in input order (a missing one and a too-old Nucleus, then the target)
    - tampered and truncated downloads: hash-mismatch / size-mismatch; plan.txt and staged\ byte-identical, no new
      staged file, nothing left in downloads\
    - bad zips: zip64, encrypted, method 12, a wrong CRC, "..", "\", a duplicate name without case, two Mods/ names, a
      name other than the index name, UE4SS.dll, settings.json, no mod.json, another id in mod.json, an entry outside
      the layout: bad-zip / bad-layout / name-mismatch / id-mismatch; nothing staged
    - bombs: an entry inflating past its declared size, a declared size past the caps: too-large
    - a folder taken by another id: folder-in-use; a newer version on disk: downgrade
    - a second install before the restart: merged, a new txn, the earlier owner kept; the same mod again: its old
      operations replaced and staged files nothing references removed
    - apply.lock held: applying; a journal without done: interrupted; a revoked version: revoked; an unknown version:
      not-in-catalog
    - then story 3's helper (<Core>RestartTest --apply --root) applies a staged plan: the zip's files in the tree,
      the mods.txt line above Keybinds : 1, installed.txt; a later stage of a version lacking a file gets its delete
      line (with the recorded SHA-256), and the next apply removes it
  Mod Manager v2 story 6 (updates, revocations, removals; -Unstage, <Core>_CatalogUnstage's code):
    - removal refused before anything is staged: base-pack (Nucleus, Mod Manager), not-installed, changed,
      not-in-catalog (an unknown id; a version neither installed.txt nor the index knows), applying; plan.txt and
      staged\ byte-identical
    - revocation match: a newer installed version whose revoked entry has another sha256 is not revoked (downgrade
      refused); one revoked and no longer in the index allows the downgrade (no deletes: its files are unknown)
    - revoked, older fix: an installer-installed revoked 0.4.0 -> 0.3.1, the delete for the file only 0.4.0 had taken
      from 0.4.0's own verified release (downloaded although revoked, only read); a plain update of an
      installer-installed mod gets its delete the same way
    - uninstall: a pending install of the same owner replaced, a delete per owned file, modstxt remove, an edited file
      kept (kept=1), the payload {txn, owners [{id, version, name, files, kept}], ops}; then the helper applies it all
      (tree and mods.txt checked); an uninstall from installed.txt's records, after whose apply installed.txt has lost
      the owner's records
    - review cases: the installed version's own release listed but answering 404 refuses both the removal and the
      update (unreachable; plan.txt, staged\ and downloads\ unchanged); installed.txt naming a settings.json never
      gets it deleted (player data), and it stays on disk after the apply
    - core self-update: the core package's own id (dlls\main.dll, bin\<Core>Restart.exe) over an older core, applied
      with --root (a plain put: the helper's own image is outside the layout); update, dep too old: a mod update and
      the core update it needs in one stage (owners=2, the core first), applied; revoked, newer fix: revoked 0.4.0 ->
      0.6.0 with the delete from 0.4.0's verified release, applied
    - unstage refusals with a plan staged: interrupted before the job; -NoPrecheck under apply.lock held and with a
      journal without done (the job's own refusal at write time); plan.txt and staged\ byte-identical, no download left
  Prints ok:/FAIL: lines and exits 1 on any failure. Needs minisign on PATH and this workspace; under NN_CI=1 it skips.
.EXAMPLE
  pwsh -NoProfile -File native/test/stage.tests.ps1
#>
param([string] $TestExe, [string] $HelperExe, [string] $Minisign)
$ErrorActionPreference = 'Stop'
if ($env:NN_CI -eq '1') { Write-Host 'SKIP: stage.tests.ps1 needs the native build and the workspace (NN_CI=1)'; exit 0 }
$repo = Split-Path (Split-Path $PSScriptRoot)
$name = (Get-Content (Join-Path $repo 'mod.json') -Raw | ConvertFrom-Json).name
$coreSlug = $name.ToLowerInvariant()
$CORE = "nuclearnightmare-community.$coreSlug"   # the catalog's id of the core package
if (-not $TestExe) { $TestExe = Join-Path $repo "build\native-out\test\$($name)CatalogTest.exe" }
if (-not $HelperExe) { $HelperExe = Join-Path $repo "build\native-out\test\$($name)RestartTest.exe" }
foreach ($f in $TestExe, $HelperExe) { if (-not (Test-Path -LiteralPath $f)) { Write-Host "FAIL: $f not found; run build.ps1 -Steps native first"; exit 1 } }
$TestExe = (Resolve-Path -LiteralPath $TestExe).Path
$ws = $repo
while ($ws -and -not (Test-Path (Join-Path $ws 'tools\launch.ps1'))) { $ws = Split-Path $ws }
if (-not $ws) { Write-Host 'FAIL: the workspace (with tools/launch.ps1) was not found above this repo'; exit 1 }
$tests = Join-Path $ws 'tools\release\tests'
if (-not $Minisign) {
    $cmd = Get-Command minisign -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { Write-Host 'FAIL: minisign not found on PATH (winget install jedisct1.minisign); or pass -Minisign'; exit 1 }
    $Minisign = $cmd.Source
}
$pwsh = (Get-Process -Id $PID).Path
Add-Type -AssemblyName System.IO.Compression
if (-not ('StageTest.Native' -as [type])) {
    Add-Type -Namespace StageTest -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern System.IntPtr OpenProcess(uint access, bool inherit, int pid);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(System.IntPtr h);
'@
}

$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $label, $detail) {
    if ($cond) { $script:passed++; Write-Host "ok:   $label" } else { $script:failed++; Write-Host "FAIL: $label$(if ($null -ne $detail) { " -- $detail" })" }
}
function Run-Exe { $script:out = @(& $TestExe @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE }
function Outcome { if ($script:out.Count) { $script:out[0] } else { '' } }
function Has-Line([string] $text) { [bool]($script:out | Where-Object { $_.Contains($text) }) }
function Shown { ($script:out | Select-Object -First 14) -join ' | ' }
function Payload { $l = $script:out | Where-Object { $_.StartsWith('payload: ') } | Select-Object -First 1; if ($l) { $l.Substring(9) | ConvertFrom-Json -AsHashtable } }
$utf8 = [Text.UTF8Encoding]::new($false)
function Sha([byte[]] $b) { if ($null -eq $b) { $b = [byte[]]::new(0) }; [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($b)).ToLowerInvariant() }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "$name-stage-$PID"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null
$server = $null
try {
    # ---------------------------------------------------------------- zips
    $site = Join-Path $tmp 'site'
    New-Item -ItemType Directory -Force $site | Out-Null
    $M = 'NuclearNightmare/Binaries/Win64/ue4ss/Mods'
    $P = 'NuclearNightmare/Content/Paks'
    # entries: @{ Name; Text | Bytes; Store }
    function New-ZipBytes([object[]] $entries) {
        $ms = [IO.MemoryStream]::new()
        $za = [IO.Compression.ZipArchive]::new($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
        foreach ($e in $entries) {
            $level = if ($e.Store) { [IO.Compression.CompressionLevel]::NoCompression } else { [IO.Compression.CompressionLevel]::Optimal }
            $ze = $za.CreateEntry($e.Name, $level)
            $b = if ($e.ContainsKey('Bytes')) { [byte[]]$e.Bytes } else { $utf8.GetBytes([string]$e.Text) }
            if ($null -eq $b) { $b = [byte[]]::new(0) }
            $s = $ze.Open(); $s.Write($b, 0, $b.Length); $s.Dispose()
        }
        $za.Dispose()
        ,$ms.ToArray()
    }
    function U16([byte[]] $b, [int] $o) { [int]$b[$o] -bor ([int]$b[$o + 1] -shl 8) }
    function U32([byte[]] $b, [int] $o) { [long]$b[$o] -bor ([long]$b[$o + 1] -shl 8) -bor ([long]$b[$o + 2] -shl 16) -bor ([long]$b[$o + 3] -shl 24) }
    function Put16([byte[]] $b, [int] $o, [int] $v) { $b[$o] = $v -band 0xFF; $b[$o + 1] = ($v -shr 8) -band 0xFF }
    function Put32([byte[]] $b, [int] $o, [long] $v) { for ($i = 0; $i -lt 4; $i++) { $b[$o + $i] = ($v -shr (8 * $i)) -band 0xFF } }
    # The central and local header offsets of each entry (no comment: the EOCD is the last 22 bytes).
    function Zip-Layout([byte[]] $b) {
        $e = $b.Length - 22
        $n = U16 $b ($e + 10); $pos = [int](U32 $b ($e + 16))
        $list = @()
        for ($k = 0; $k -lt $n; $k++) {
            $list += [pscustomobject]@{ Central = $pos; Local = [int](U32 $b ($pos + 42)) }
            $pos += 46 + (U16 $b ($pos + 28)) + (U16 $b ($pos + 30)) + (U16 $b ($pos + 32))
        }
        [pscustomobject]@{ Eocd = $e; Entries = $list }
    }
    $zips = [ordered]@{}   # file name -> bytes (served under site/)
    function Add-Zip([string] $file, [byte[]] $bytes) { $zips[$file] = $bytes; [IO.File]::WriteAllBytes((Join-Path $site $file), $bytes) }

    function ModJson([string] $id, [string] $nm, [string] $v) { "{`"id`":`"$id`",`"name`":`"$nm`",`"version`":`"$v`"}" }
    $HC = 'nuclearnightmare-community.hud-clock'
    Add-Zip 'hud-clock-0.3.0.zip' (New-ZipBytes @(
            @{ Name = "$M/HudClock/mod.json"; Text = (ModJson $HC 'HudClock' '0.3.0') },
            @{ Name = "$M/HudClock/Scripts/main.lua"; Text = 'print("clock 0.3.0")' },
            @{ Name = "$M/HudClock/Scripts/extra.lua"; Text = 'print("extra")' }))
    Add-Zip 'hud-clock-0.4.0.zip' (New-ZipBytes @(
            @{ Name = "$M/HudClock/mod.json"; Text = (ModJson $HC 'HudClock' '0.4.0') },
            @{ Name = "$M/HudClock/Scripts/main.lua"; Text = 'print("clock 0.4.0")' }))
    Add-Zip 'core-0.30.0.zip' (New-ZipBytes @(
            @{ Name = "$M/$name/mod.json"; Text = (ModJson $CORE $name '0.30.0') },
            @{ Name = "$M/$name/Scripts/core.lua"; Text = 'return {}' },
            @{ Name = "$P/LogicMods/$name.pak"; Text = 'new core pak' }))
    Add-Zip 'alpha-1.0.0.zip' (New-ZipBytes @(
            @{ Name = "$M/Alpha/mod.json"; Text = (ModJson 'nuclearnightmare-community.alpha' 'Alpha' '1.0.0') },
            @{ Name = "$M/Alpha/Scripts/main.lua"; Text = ('-- alpha' * 400); Store = $true },
            @{ Name = "$M/Alpha/empty.txt"; Text = ''; Store = $true },
            @{ Name = "$P/LogicMods/Alpha.pak"; Bytes = [byte[]](1..200 | ForEach-Object { $_ % 7 }) },
            @{ Name = "$P/Alpha_P.pak"; Text = 'alpha base pak' }))
    $BADID = 'nuclearnightmare-community.bad'
    function BadBase([object[]] $more = @()) {
        @(@{ Name = "$M/Bad/mod.json"; Text = (ModJson $BADID 'Bad' '1.0.0') }, @{ Name = "$M/Bad/Scripts/main.lua"; Text = 'print("bad")' }) + $more
    }
    $bad = [ordered]@{}
    $b = New-ZipBytes (BadBase); $L = Zip-Layout $b; Put16 $b ($L.Eocd + 8) 0xFFFF; Put16 $b ($L.Eocd + 10) 0xFFFF
    $bad['1.0.1'] = @{ Bytes = $b; Want = 'bad-zip'; What = 'zip64 (entry count 0xFFFF)' }
    $b = New-ZipBytes (BadBase); $L = Zip-Layout $b; foreach ($o in @(($L.Entries[1].Central + 8), ($L.Entries[1].Local + 6))) { $b[$o] = $b[$o] -bor 1 }
    $bad['1.0.2'] = @{ Bytes = $b; Want = 'bad-zip'; What = 'encrypted (flag bit 0)' }
    $b = New-ZipBytes (BadBase); $L = Zip-Layout $b; Put16 $b ($L.Entries[1].Central + 10) 12; Put16 $b ($L.Entries[1].Local + 8) 12
    $bad['1.0.3'] = @{ Bytes = $b; Want = 'bad-zip'; What = 'compression method 12' }
    $b = New-ZipBytes (BadBase); $L = Zip-Layout $b; $b[$L.Entries[1].Central + 16] = $b[$L.Entries[1].Central + 16] -bxor 0xFF
    $bad['1.0.4'] = @{ Bytes = $b; Want = 'bad-zip'; What = 'a wrong CRC-32' }
    $bad['1.0.5'] = @{ Bytes = (New-ZipBytes (BadBase @(@{ Name = "$M/Bad/../Bad/x.lua"; Text = 'x' }))); Want = 'bad-zip'; What = 'a ".." segment' }
    $bad['1.0.6'] = @{ Bytes = (New-ZipBytes (BadBase @(@{ Name = "$M/Bad/Scripts\x.lua"; Text = 'x' }))); Want = 'bad-zip'; What = 'a "\" in a name' }
    $bad['1.0.7'] = @{ Bytes = (New-ZipBytes (BadBase @(@{ Name = "$M/Bad/Scripts/MAIN.lua"; Text = 'x' }))); Want = 'bad-zip'; What = 'two names equal without case' }
    $bad['1.0.8'] = @{ Bytes = (New-ZipBytes (BadBase @(@{ Name = "$M/Other/x.lua"; Text = 'x' }))); Want = 'bad-layout'; What = 'two Mods/ folders' }
    $bad['1.0.9'] = @{ Bytes = (New-ZipBytes @(@{ Name = "$M/Good/mod.json"; Text = (ModJson $BADID 'Good' '1.0.9') }, @{ Name = "$M/Good/x.lua"; Text = 'x' })); Want = 'name-mismatch'; What = 'a folder other than the index name' }
    $bad['1.0.10'] = @{ Bytes = (New-ZipBytes (BadBase @(@{ Name = "$M/Bad/UE4SS.dll"; Text = 'x' }))); Want = 'bad-layout'; What = 'UE4SS.dll' }
    $bad['1.0.11'] = @{ Bytes = (New-ZipBytes (BadBase @(@{ Name = "$M/Bad/settings.json"; Text = '{}' }))); Want = 'bad-layout'; What = 'settings.json' }
    $bad['1.0.12'] = @{ Bytes = (New-ZipBytes @(@{ Name = "$M/Bad/Scripts/main.lua"; Text = 'x' })); Want = 'bad-layout'; What = 'no mod.json' }
    $bad['1.0.13'] = @{ Bytes = (New-ZipBytes @(@{ Name = "$M/Bad/mod.json"; Text = (ModJson 'someone.else' 'Bad' '1.0.13') }, @{ Name = "$M/Bad/x.lua"; Text = 'x' })); Want = 'id-mismatch'; What = 'another id in mod.json' }
    $b = New-ZipBytes (BadBase @(@{ Name = "$M/Bad/zeros.bin"; Bytes = [byte[]]::new(100000) })); $L = Zip-Layout $b
    Put32 $b ($L.Entries[2].Central + 24) 1000; Put32 $b ($L.Entries[2].Local + 22) 1000
    $bad['1.0.14'] = @{ Bytes = $b; Want = 'too-large'; What = 'an entry inflating past its declared size (bomb)' }
    $b = New-ZipBytes (BadBase); $L = Zip-Layout $b; Put32 $b ($L.Entries[1].Central + 24) (300MB)
    $bad['1.0.15'] = @{ Bytes = $b; Want = 'too-large'; What = 'a declared size over 256 MiB' }
    $bad['1.0.16'] = @{ Bytes = (New-ZipBytes (BadBase @(@{ Name = 'README.txt'; Text = 'x' }))); Want = 'bad-layout'; What = 'an entry outside the layout' }
    $bad['1.0.17'] = @{ Bytes = (New-ZipBytes (BadBase @(@{ Name = "$P/LogicMods/Other.pak"; Text = 'x' }))); Want = 'name-mismatch'; What = 'a LogicMods pak named otherwise' }
    $bad['1.0.18'] = @{ Bytes = (New-ZipBytes (BadBase @(@{ Name = "$M/Bad/sub/../../../../../evil.txt"; Text = 'x' }))); Want = 'bad-zip'; What = 'a path climbing out' }
    $bad['1.0.19'] = @{ Bytes = [byte[]](1..64); Want = 'bad-zip'; What = 'not a zip' }
    foreach ($v in $bad.Keys) { Add-Zip "bad-$v.zip" $bad[$v].Bytes }
    Add-Zip 'taken-1.0.0.zip' (New-ZipBytes @(@{ Name = "$M/Taken/mod.json"; Text = (ModJson 'nuclearnightmare-community.taken' 'Taken' '1.0.0') }, @{ Name = "$M/Taken/a.lua"; Text = 'a' }))
    Add-Zip 'downy-1.0.0.zip' (New-ZipBytes @(@{ Name = "$M/Downy/mod.json"; Text = (ModJson 'nuclearnightmare-community.downy' 'Downy' '1.0.0') }, @{ Name = "$M/Downy/a.lua"; Text = 'a' }))
    $tamperOk = New-ZipBytes @(@{ Name = "$M/Tamper/mod.json"; Text = (ModJson 'nuclearnightmare-community.tamper' 'Tamper' '1.0.0') }, @{ Name = "$M/Tamper/a.lua"; Text = 'a' })
    Add-Zip 'tamper-short.zip' ([byte[]]$tamperOk[0..($tamperOk.Length - 2)])
    $flip = [byte[]]$tamperOk.Clone(); $flip[10] = $flip[10] -bxor 0xFF
    Add-Zip 'tamper-flip.zip' $flip
    # Story 6: updates, revocations and removals.
    $REV = 'nuclearnightmare-community.rev'; $UPD = 'nuclearnightmare-community.upd'; $WM = 'nuclearnightmare-community.whistle-mute'
    Add-Zip 'rev-0.4.0.zip' (New-ZipBytes @(@{ Name = "$M/Rev/mod.json"; Text = (ModJson $REV 'Rev' '0.4.0') }, @{ Name = "$M/Rev/Scripts/main.lua"; Text = 'print("rev 0.4.0")' },
            @{ Name = "$M/Rev/Scripts/old.lua"; Text = 'print("only in 0.4.0")' }))
    Add-Zip 'rev-0.3.1.zip' (New-ZipBytes @(@{ Name = "$M/Rev/mod.json"; Text = (ModJson $REV 'Rev' '0.3.1') }, @{ Name = "$M/Rev/Scripts/main.lua"; Text = 'print("rev 0.3.1")' }))
    Add-Zip 'rev-0.6.0.zip' (New-ZipBytes @(@{ Name = "$M/Rev/mod.json"; Text = (ModJson $REV 'Rev' '0.6.0') }, @{ Name = "$M/Rev/Scripts/main.lua"; Text = 'print("rev 0.6.0")' }))
    Add-Zip 'upd-1.0.0.zip' (New-ZipBytes @(@{ Name = "$M/Upd/mod.json"; Text = (ModJson $UPD 'Upd' '1.0.0') }, @{ Name = "$M/Upd/a.lua"; Text = 'a 1.0.0' }, @{ Name = "$M/Upd/b.lua"; Text = 'b 1.0.0' }))
    Add-Zip 'upd-1.1.0.zip' (New-ZipBytes @(@{ Name = "$M/Upd/mod.json"; Text = (ModJson $UPD 'Upd' '1.1.0') }, @{ Name = "$M/Upd/a.lua"; Text = 'a 1.1.0' }))
    Add-Zip 'wm-0.2.1.zip' (New-ZipBytes @(@{ Name = "$M/WhistleMute/mod.json"; Text = (ModJson $WM 'WhistleMute' '0.2.1') }, @{ Name = "$M/WhistleMute/Scripts/main.lua"; Text = 'print("wm")' },
            @{ Name = "$M/WhistleMute/Scripts/b.lua"; Text = 'print("wm b")' }, @{ Name = "$P/LogicMods/WhistleMute.pak"; Text = 'wm pak' }))
    # Story 6 review: an installed version whose own release the server no longer has (404), and player data on disk.
    $GONE = 'nuclearnightmare-community.gone'; $PD = 'nuclearnightmare-community.pd'
    Add-Zip 'gone-1.0.0.zip' (New-ZipBytes @(@{ Name = "$M/Gone/mod.json"; Text = (ModJson $GONE 'Gone' '1.0.0') }, @{ Name = "$M/Gone/a.lua"; Text = 'gone 1.0.0' }))
    Add-Zip 'gone-1.1.0.zip' (New-ZipBytes @(@{ Name = "$M/Gone/mod.json"; Text = (ModJson $GONE 'Gone' '1.1.0') }, @{ Name = "$M/Gone/a.lua"; Text = 'gone 1.1.0' }))
    Add-Zip 'pd-1.0.0.zip' (New-ZipBytes @(@{ Name = "$M/Pd/mod.json"; Text = (ModJson $PD 'Pd' '1.0.0') }, @{ Name = "$M/Pd/Scripts/main.lua"; Text = 'print("pd")' }))
    # Story 6 review: the core's own update (its DLL and relaunch helper), an update that needs it, a revoked version's
    # newer fix (Rev 0.4.0 -> 0.6.0, above).
    $CM = "$M/$name"
    Add-Zip 'core-0.31.0.zip' (New-ZipBytes @(
            @{ Name = "$CM/mod.json"; Text = (ModJson $CORE $name '0.31.0') },
            @{ Name = "$CM/dlls/main.dll"; Bytes = [byte[]](1..300 | ForEach-Object { ($_ * 7) % 256 }) },
            @{ Name = "$CM/bin/$($name)Restart.exe"; Bytes = [byte[]](1..200 | ForEach-Object { ($_ * 13) % 256 }) },
            @{ Name = "$P/LogicMods/$name.pak"; Text = 'core pak 0.31.0' }))
    Add-Zip 'upd-1.2.0.zip' (New-ZipBytes @(@{ Name = "$M/Upd/mod.json"; Text = (ModJson $UPD 'Upd' '1.2.0') }, @{ Name = "$M/Upd/a.lua"; Text = 'a 1.2.0' }))

    # ---------------------------------------------------------------- the signed index, the fixture server
    $keys = @{}
    foreach ($role in 'release', 'backup', 'revoke') {
        $pub = Join-Path $tmp "$role.pub"; $sec = Join-Path $tmp "$role.key"
        $null = & $Minisign -G -W -p $pub -s $sec 2>&1
        if ($LASTEXITCODE) { throw "minisign -G failed for $role" }
        $keys[$role] = @{ Pub = (Get-Content $pub)[1].Trim(); Sec = $sec }
    }
    $trustFile = Join-Path $tmp 'trusted-keys.json'
    ConvertTo-Json @(foreach ($role in 'release', 'backup', 'revoke') { [ordered]@{ role = $role; name = "fixture-$role"; key = $keys[$role].Pub } }) |
        Set-Content -LiteralPath $trustFile -Encoding utf8NoBOM
    function Sign([string] $file, [string] $role) {
        $o = & $Minisign -S -s $keys[$role].Sec -m $file -t 'stage.tests' 2>&1
        if ($LASTEXITCODE) { throw "minisign -S failed: $o" }
    }
    $map = [ordered]@{}
    function Ver([string] $mod, [string] $v, [string] $file, [byte[]] $declared) {
        $url = "https://github.com/NuclearNightmare-Community/$mod/releases/download/v$v/$mod-$v.zip"
        $map[$url] = @{ status = 200; file = "site/$file" }
        if (-not $declared) { $declared = $zips[$file] }
        [ordered]@{ version = $v; scope = 'client'; url = $url; sha256 = (Sha $declared); size = $declared.Length; published = '2026-11-21T10:00:00Z' }
    }
    function Pkg([string] $mod, [string] $nm, [object[]] $versions) {
        [ordered]@{ id = "nuclearnightmare-community.$mod"; name = $nm; description = "The $nm fixture."; categories = @('qol'); kind = 'mod'
            publisher = 'NuclearNightmare-Community'; repo = "NuclearNightmare-Community/$mod"; versions = $versions }
    }
    $packages = @(
        (Pkg 'hud-clock' 'HudClock' @((Ver 'hud-clock' '0.4.0' 'hud-clock-0.4.0.zip'), (Ver 'hud-clock' '0.3.0' 'hud-clock-0.3.0.zip'), (Ver 'hud-clock' '0.1.0' 'hud-clock-0.3.0.zip'))),
        (Pkg $coreSlug $name @((Ver $coreSlug '0.31.0' 'core-0.31.0.zip'), (Ver $coreSlug '0.30.0' 'core-0.30.0.zip'))),
        (Pkg 'alpha' 'Alpha' @((Ver 'alpha' '1.0.0' 'alpha-1.0.0.zip'))),
        (Pkg 'bad' 'Bad' @(foreach ($v in $bad.Keys) { Ver 'bad' $v "bad-$v.zip" })),
        (Pkg 'taken' 'Taken' @((Ver 'taken' '1.0.0' 'taken-1.0.0.zip'))),
        (Pkg 'downy' 'Downy' @((Ver 'downy' '1.0.0' 'downy-1.0.0.zip'))),
        (Pkg 'tamper' 'Tamper' @((Ver 'tamper' '1.0.0' 'tamper-short.zip' $tamperOk), (Ver 'tamper' '1.0.1' 'tamper-flip.zip' $tamperOk))),
        (Pkg 'rev' 'Rev' @((Ver 'rev' '0.6.0' 'rev-0.6.0.zip'), (Ver 'rev' '0.4.0' 'rev-0.4.0.zip'), (Ver 'rev' '0.3.1' 'rev-0.3.1.zip'))),
        (Pkg 'upd' 'Upd' @((Ver 'upd' '1.2.0' 'upd-1.2.0.zip'), (Ver 'upd' '1.1.0' 'upd-1.1.0.zip'), (Ver 'upd' '1.0.0' 'upd-1.0.0.zip'))),
        (Pkg 'whistle-mute' 'WhistleMute' @((Ver 'whistle-mute' '0.2.1' 'wm-0.2.1.zip'))),
        (Pkg 'gone' 'Gone' @((Ver 'gone' '1.1.0' 'gone-1.1.0.zip'), (Ver 'gone' '1.0.0' 'gone-1.0.0.zip'))),
        (Pkg 'pd' 'Pd' @((Ver 'pd' '1.0.0' 'pd-1.0.0.zip'))))
    # Story 6 review: the server no longer has Gone 1.0.0's release (listed in the index, answered 404).
    $map['https://github.com/NuclearNightmare-Community/gone/releases/download/v1.0.0/gone-1.0.0.zip'] = @{ status = 404 }
    $ix = [ordered]@{ schema = 2; serial = 7; issued = '2026-11-21T10:00:00Z'; packages = $packages }
    $ixFile = Join-Path $tmp 'index.json'
    $ix | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $ixFile -Encoding utf8NoBOM
    Sign $ixFile 'release'
    $rv = [ordered]@{ schema = 1; serial = 1; issued = '2026-11-21T10:00:00Z'; revoked = @(
            [ordered]@{ id = $HC; version = '0.1.0'; sha256 = (Sha $zips['hud-clock-0.3.0.zip']); reason = 'broken'; action = 'block' },
            # Story 6: an installed version is revoked when the revoked sha256 is the index's for it (any case) ...
            [ordered]@{ id = $REV; version = '0.4.0'; sha256 = (Sha $zips['rev-0.4.0.zip']).ToUpperInvariant(); reason = 'crash on map load'; action = 'disable' },
            # ... not when it differs ...
            [ordered]@{ id = $REV; version = '0.6.0'; sha256 = ('ab' * 32); reason = 'another build'; action = 'block' },
            # ... and also when the index no longer lists that version.
            [ordered]@{ id = $REV; version = '0.7.0'; sha256 = ('cd' * 32); reason = 'withdrawn'; action = 'block' }) }
    $rvFile = Join-Path $tmp 'revoked.json'
    $rv | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $rvFile -Encoding utf8NoBOM
    Sign $rvFile 'revoke'
    $mapFile = Join-Path $tmp 'map.json'
    $map | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $mapFile -Encoding utf8NoBOM
    $control = Join-Path $tmp 'control.txt'
    Set-Content -LiteralPath $control -Value $mapFile -Encoding utf8NoBOM
    $serverLog = Join-Path $tmp 'server.log'
    $server = Start-Process $pwsh -PassThru -WindowStyle Hidden -RedirectStandardOutput $serverLog -RedirectStandardError (Join-Path $tmp 'server.err') -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-File', (Join-Path $tests 'https-fixture-server.ps1'), '-ControlFile', $control, '-ParentPid', $PID)
    $port = $null; $cert = $null
    $deadline = [datetime]::UtcNow.AddSeconds(60)
    while (-not ($port -and $cert)) {
        if ([datetime]::UtcNow -gt $deadline -or $server.HasExited) { throw "the fixture server did not start: $(Get-Content $serverLog -Raw -ErrorAction SilentlyContinue)" }
        Start-Sleep -Milliseconds 200
        foreach ($l in @(Get-Content -LiteralPath $serverLog -ErrorAction SilentlyContinue)) {
            if ($l -match '^port: (\d+)$') { $port = $Matches[1] }
            if ($l -match '^cert: ([0-9a-f]{64})$') { $cert = $Matches[1] }
        }
    }
    $net = @('-Index', $ixFile, '-Revoked', $rvFile, '-Proxy', "127.0.0.1:$port", '-PinCert', $cert, '-TrustedKeys', $trustFile)

    # ---------------------------------------------------------------- the layout (story 3's apply.tests.ps1 shape)
    $root = Join-Path $tmp 'game root'
    $win64 = Join-Path $root 'NuclearNightmare\Binaries\Win64'
    $mods = Join-Path $win64 'ue4ss\Mods'
    $modsTxt = Join-Path $mods 'mods.txt'
    $data = Join-Path $win64 "ue4ss\$($name)Data"
    $staged = Join-Path $data 'staged'
    $planFile = Join-Path $staged 'plan.txt'
    $paks = Join-Path $root 'NuclearNightmare\Content\Paks'
    $stockTxt = "`u{FEFF}$name : 1`r`nBPModLoaderMod : 1`r`nKeybinds : 1`r`n"
    function Reset-Layout {
        if (Test-Path $root) { cmd /c rmdir /s /q "`"$root`"" | Out-Null }
        foreach ($d in $mods, $data, (Join-Path $paks 'LogicMods'), (Join-Path $mods "$name\bin"), (Join-Path $mods 'BPModLoaderMod'), (Join-Path $mods 'Keybinds')) { New-Item -ItemType Directory -Force $d | Out-Null }
        [IO.File]::WriteAllText($modsTxt, $stockTxt, $utf8)
        [IO.File]::WriteAllText((Join-Path $paks "LogicMods\$name.pak"), 'core pak')
        [IO.File]::WriteAllText((Join-Path $mods "$name\mod.json"), (ModJson $CORE $name '0.25.0'), $utf8)
    }
    function Stage([string[]] $pairs) { Run-Exe -Stage @pairs -Root $root @net }
    # Every file under staged\ (and downloads\): relative path -> SHA-256.
    function Snap([string] $dir) {
        $m = [ordered]@{}
        if (Test-Path -LiteralPath $dir) {
            Get-ChildItem -LiteralPath $dir -Recurse -Force -File | Sort-Object FullName | ForEach-Object { $m[$_.FullName.Substring($dir.Length)] = (Get-FileHash -LiteralPath $_.FullName).Hash }
        }
        $m
    }
    function Same($a, $b) { if ($a.Count -ne $b.Count) { return $false }; foreach ($k in $a.Keys) { if (-not $b.Contains($k) -or $a[$k] -ne $b[$k]) { return $false } }; $true }
    function PlanLines { if (Test-Path -LiteralPath $planFile) { @([IO.File]::ReadAllText($planFile) -split "`n" | Where-Object { $_ }) } else { @() } }
    function PlanTxn { $t = PlanLines | Where-Object { $_ -like "txn`t*" } | Select-Object -First 1; if ($t) { $t.Substring(4) } }
    function StagedFiles { @(Get-ChildItem -LiteralPath (Join-Path $staged 'files') -File -ErrorAction SilentlyContinue | ForEach-Object Name) }
    $HCM = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\HudClock'
    function ZipEntryBytes([string] $file, [string] $entry) {
        $za = [IO.Compression.ZipArchive]::new([IO.MemoryStream]::new($zips[$file]), [IO.Compression.ZipArchiveMode]::Read)
        try { $e = $za.GetEntry($entry); $s = $e.Open(); $ms = [IO.MemoryStream]::new(); $s.CopyTo($ms); $s.Dispose(); ,$ms.ToArray() } finally { $za.Dispose() }
    }

    # ---------------------------------------------------------------- a plain install
    Reset-Layout
    Stage $HC, '0.3.0'
    $pl = Payload
    $lines = PlanLines
    $mainSha = Sha (ZipEntryBytes 'hud-clock-0.3.0.zip' "$M/HudClock/Scripts/main.lua")
    $extraSha = Sha (ZipEntryBytes 'hud-clock-0.3.0.zip' "$M/HudClock/Scripts/extra.lua")
    $puts = @($lines | Where-Object { $_ -like "put`t*" })
    Ok ((Outcome) -eq 'outcome: ok' -and $script:code -eq 0 -and $puts.Count -eq 3 -and ($lines -ccontains "put`tHudClock`t$mainSha`t$((ZipEntryBytes 'hud-clock-0.3.0.zip' "$M/HudClock/Scripts/main.lua").Length)`t$HCM\Scripts\main.lua") -and
        ($lines -ccontains "modstxt`tHudClock`ton") -and $lines[0] -ceq "nucleus-plan`t1" -and (PlanTxn) -cmatch '^[0-9a-f]{32}$') 'plain install: ok, put lines at install-layout targets and modstxt HudClock on' "$(Shown); plan: $($lines -join ' / ')"
    $files = StagedFiles
    Ok ($files.Count -eq 3 -and ($files -contains $mainSha) -and ($files -contains $extraSha) -and
        ((Get-FileHash -LiteralPath (Join-Path $staged "files\$mainSha")).Hash -eq $mainSha.ToUpperInvariant())) 'plain install: staged files named by their SHA-256, each matching' ($files -join ', ')
    Ok ($pl -and $pl.txn -ceq (PlanTxn) -and $pl.ops -eq 4 -and $pl.owners.Count -eq 1 -and $pl.owners[0].id -ceq $HC -and $pl.owners[0].version -ceq '0.3.0' -and
        $pl.owners[0].name -ceq 'HudClock' -and $pl.owners[0].files -eq 3 -and $pl.owners[0].bytes -gt 0) 'plain install: payload {txn, owners [{id, version, name, files, bytes}], ops}' (Shown)
    Ok (@(Get-ChildItem -LiteralPath (Join-Path $data 'downloads') -File -ErrorAction SilentlyContinue).Count -eq 0 -and -not (Test-Path (Join-Path $data 'apply.lock')) -and
        -not (Test-Path "$planFile.tmp")) 'plain install: the used download deleted, no lock or temporary file left' ((Get-ChildItem -Recurse $data -File | ForEach-Object Name) -join ', ')

    # ---------------------------------------------------------------- refusals leave the staged plan byte-identical
    $before = Snap $staged
    function Refused([string[]] $pairs, [string] $want, [string] $what, [string] $text) {
        Stage $pairs
        $after = Snap $staged
        $dl = @(Get-ChildItem -LiteralPath (Join-Path $data 'downloads') -File -Force -ErrorAction SilentlyContinue)
        Ok ((Outcome) -eq "outcome: $want" -and $script:code -eq 1 -and (Same $before $after) -and $dl.Count -eq 0 -and (-not $text -or (Has-Line $text)) -and
            -not (Test-Path (Join-Path $data 'apply.lock'))) "${what}: $want; plan.txt and staged\ byte-identical, nothing new kept" "$(Shown); downloads: $($dl.Name -join ', ')"
    }
    Refused @('nuclearnightmare-community.tamper', '1.0.0') 'size-mismatch' 'a truncated download'
    Refused @('nuclearnightmare-community.tamper', '1.0.1') 'hash-mismatch' 'a tampered download (one byte changed)'
    foreach ($v in $bad.Keys) { Refused @($BADID, $v) $bad[$v].Want "bad zip $v ($($bad[$v].What))" }
    # A good pair before a bad one: nothing of either is staged.
    Refused @('nuclearnightmare-community.alpha', '1.0.0', $BADID, '1.0.8') 'bad-layout' 'a good pair, then a bad one'
    Refused @($HC, '0.1.0') 'revoked' 'a revoked version' 'is revoked (block)'
    Refused @($HC, '9.9.9') 'not-in-catalog' 'an unknown version'
    # A folder another mod holds; a newer version on disk.
    New-Item -ItemType Directory -Force (Join-Path $mods 'Taken'), (Join-Path $mods 'Downy') | Out-Null
    [IO.File]::WriteAllText((Join-Path $mods 'Taken\mod.json'), (ModJson 'someone.else' 'Taken' '1.0.0'), $utf8)
    [IO.File]::WriteAllText((Join-Path $mods 'Downy\mod.json'), (ModJson 'nuclearnightmare-community.downy' 'Downy' '2.0.0'), $utf8)
    Refused @('nuclearnightmare-community.taken', '1.0.0') 'folder-in-use' 'a folder holding another id' 'holds someone.else'
    Refused @('nuclearnightmare-community.downy', '1.0.0') 'downgrade' 'a newer version on disk' 'holds 2.0.0'
    # apply.lock held; a journal without done.
    $lock = [IO.File]::Open((Join-Path $data 'apply.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Stage 'nuclearnightmare-community.alpha', '1.0.0'
        Ok ((Outcome) -eq 'outcome: applying' -and (Same $before (Snap $staged))) 'apply.lock held: applying, nothing staged' (Shown)
        # The job's own check once the downloads are done (-NoPrecheck skips the checks before them).
        Run-Exe -Stage 'nuclearnightmare-community.alpha' '1.0.0' -Root $root @net -NoPrecheck
        Ok ((Outcome) -eq 'outcome: applying' -and (Has-Line 'apply.lock is held') -and (Same $before (Snap $staged)) -and
            @(Get-ChildItem -LiteralPath (Join-Path $data 'downloads') -File -Force -ErrorAction SilentlyContinue).Count -eq 0) 'apply.lock held at write time (-NoPrecheck): applying from the job, staged\ unchanged, the download removed' (Shown)
    } finally { $lock.Dispose(); Remove-Item -LiteralPath (Join-Path $data 'apply.lock') -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force (Join-Path $data 'rollback') | Out-Null
    [IO.File]::WriteAllText((Join-Path $data 'rollback\journal.txt'), "nucleus-journal`t1`ntxn`t$('ab' * 16)`n", $utf8)
    Stage 'nuclearnightmare-community.alpha', '1.0.0'
    Ok ((Outcome) -eq 'outcome: interrupted' -and (Same $before (Snap $staged))) 'a journal without done: interrupted, nothing staged' (Shown)
    Run-Exe -Stage 'nuclearnightmare-community.alpha' '1.0.0' -Root $root @net -NoPrecheck
    Ok ((Outcome) -eq 'outcome: interrupted' -and (Has-Line 'cut short (found under apply.lock)') -and (Same $before (Snap $staged)) -and
        -not (Test-Path (Join-Path $data 'apply.lock'))) 'a journal without done found under the lock (-NoPrecheck): interrupted from the job, staged\ unchanged' (Shown)
    Remove-Item -LiteralPath (Join-Path $data 'rollback') -Recurse -Force

    # ---------------------------------------------------------------- merges
    $txn1 = PlanTxn
    Stage 'nuclearnightmare-community.alpha', '1.0.0'
    $lines = PlanLines
    $txn2 = PlanTxn
    Ok ((Outcome) -eq 'outcome: ok' -and $txn2 -cne $txn1 -and @($lines | Where-Object { $_ -like "put`tHudClock`t*" }).Count -eq 3 -and ($lines -ccontains "modstxt`tHudClock`ton") -and
        @($lines | Where-Object { $_ -like "put`tAlpha`t*" }).Count -eq 5 -and ($lines -ccontains "modstxt`tAlpha`ton") -and
        ($lines | Where-Object { $_ -like "put`tAlpha`t*`tNuclearNightmare\Content\Paks\LogicMods\Alpha.pak" }) -and
        ($lines | Where-Object { $_ -like "put`tAlpha`t*`t0`tNuclearNightmare\Binaries\Win64\ue4ss\Mods\Alpha\empty.txt" })) 'a second install before the restart: merged, a new txn, HudClock kept' "$(Shown); plan: $($lines -join ' / ')"
    Stage $HC, '0.4.0'
    $lines = PlanLines
    $newMain = Sha (ZipEntryBytes 'hud-clock-0.4.0.zip' "$M/HudClock/Scripts/main.lua")
    $files = StagedFiles
    Ok ((Outcome) -eq 'outcome: ok' -and @($lines | Where-Object { $_ -like "put`tHudClock`t*" }).Count -eq 2 -and ($lines -ccontains "put`tHudClock`t$newMain`t$((ZipEntryBytes 'hud-clock-0.4.0.zip' "$M/HudClock/Scripts/main.lua").Length)`t$HCM\Scripts\main.lua") -and
        -not ($lines | Where-Object { $_ -like '*extra.lua' }) -and @($lines | Where-Object { $_ -like "modstxt`tHudClock`t*" }).Count -eq 1 -and
        @($lines | Where-Object { $_ -like "put`tAlpha`t*" }).Count -eq 5) 'the same mod again: its old operations replaced, Alpha kept' "plan: $($lines -join ' / ')"
    Ok (($files -notcontains $mainSha) -and ($files -notcontains $extraSha) -and ($files -contains $newMain) -and (Has-Line "removed: staged file $extraSha")) 'the same mod again: staged files nothing references removed' ($files -join ', ')

    # ---------------------------------------------------------------- dependencies first, then apply with story 3's helper
    Reset-Layout
    Stage $CORE, '0.30.0', 'nuclearnightmare-community.alpha', '1.0.0', $HC, '0.3.0'
    $pl = Payload
    Ok ((Outcome) -eq 'outcome: ok' -and $pl.owners.Count -eq 3 -and $pl.owners[0].name -ceq $name -and $pl.owners[1].name -ceq 'Alpha' -and $pl.owners[2].name -ceq 'HudClock' -and
        $pl.ops -eq ((PlanLines).Count - 2)) 'missing and too-old dependencies: one stage, three owners in input order (deps first)' (Shown)
    function Apply {
        $s = Start-Process ping -ArgumentList '-n', '2', '127.0.0.1' -WindowStyle Hidden -PassThru
        $h = [StageTest.Native]::OpenProcess(0x00100000, $true, $s.Id)
        $psi = [Diagnostics.ProcessStartInfo]::new($HelperExe)
        $psi.Arguments = "--wait $([int64]$h) --apply --mode none --cwd `"C:\a b`" --exe `"C:\a b\g.exe`" --root `"$root`" --record `"$(Join-Path $tmp 'record.txt')`" -- g.exe"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $p = [Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEnd()
        if (-not $p.WaitForExit(120000)) { $p.Kill() }
        [void][StageTest.Native]::CloseHandle($h)
        $o.Trim()
    }
    $applied = Apply
    $result = if (Test-Path (Join-Path $data 'apply-result.txt')) { [IO.File]::ReadAllText((Join-Path $data 'apply-result.txt')) } else { '' }
    $txt = [IO.File]::ReadAllText($modsTxt)
    $want = @{
        "$HCM\Scripts\main.lua" = 'hud-clock-0.3.0.zip|' + "$M/HudClock/Scripts/main.lua"
        "$HCM\Scripts\extra.lua" = 'hud-clock-0.3.0.zip|' + "$M/HudClock/Scripts/extra.lua"
        "$HCM\mod.json" = 'hud-clock-0.3.0.zip|' + "$M/HudClock/mod.json"
        'NuclearNightmare\Content\Paks\LogicMods\Alpha.pak' = 'alpha-1.0.0.zip|' + "$P/LogicMods/Alpha.pak"
        'NuclearNightmare\Content\Paks\Alpha_P.pak' = 'alpha-1.0.0.zip|' + "$P/Alpha_P.pak"
        'NuclearNightmare\Binaries\Win64\ue4ss\Mods\Alpha\empty.txt' = 'alpha-1.0.0.zip|' + "$M/Alpha/empty.txt"
        "NuclearNightmare\Content\Paks\LogicMods\$name.pak" = 'core-0.30.0.zip|' + "$P/LogicMods/$name.pak"
    }
    $wrong = @()
    foreach ($k in $want.Keys) {
        $zf, $en = $want[$k] -split '\|'
        $f = Join-Path $root $k
        if (-not (Test-Path -LiteralPath $f) -or (Get-FileHash -LiteralPath $f).Hash -ne (Sha (ZipEntryBytes $zf $en)).ToUpperInvariant()) { $wrong += $k }
    }
    $i1 = $txt.IndexOf("HudClock : 1`r`n"); $i2 = $txt.IndexOf("Alpha : 1`r`n"); $ik = $txt.IndexOf('Keybinds : 1')
    Ok ($result -match "(?m)^outcome`tapplied" -and -not $wrong -and -not (Test-Path $planFile) -and $i1 -ge 0 -and $i2 -ge 0 -and $i1 -lt $ik -and $i2 -lt $ik) "story 3's helper applies the staged plan: the zips' files in the tree, mods.txt lines above Keybinds : 1" "helper: $applied; result: $($result -replace "`n", ' / '); wrong: $($wrong -join ', '); mods.txt: $($txt -replace "`r`n", ' / ')"
    $inst = [IO.File]::ReadAllText((Join-Path $data 'installed.txt'))
    Ok ($inst.Contains("HudClock`t$extraSha`t$HCM\Scripts\extra.lua")) 'installed.txt records the applied files by owner' ($inst -replace "`n", ' / ')

    # A later version lacking a file: its delete line, with the recorded SHA-256; the next apply removes the file.
    Stage $HC, '0.4.0'
    $lines = PlanLines
    Ok ((Outcome) -eq 'outcome: ok' -and ($lines -ccontains "delete`tHudClock`t$extraSha`t$HCM\Scripts\extra.lua") -and @($lines | Where-Object { $_ -like "delete`t*" }).Count -eq 1) 'a version lacking a recorded file: delete <Owner> <recorded sha256> <target>' "plan: $($lines -join ' / ')"
    $applied = Apply
    $result = [IO.File]::ReadAllText((Join-Path $data 'apply-result.txt'))
    Ok ($result -match "(?m)^outcome`tapplied" -and -not (Test-Path -LiteralPath (Join-Path $root "$HCM\Scripts\extra.lua")) -and
        ([IO.File]::ReadAllText((Join-Path $root "$HCM\Scripts\main.lua")) -ceq 'print("clock 0.4.0")')) 'the next apply: main.lua updated, extra.lua removed' "helper: $applied; $($result -replace "`n", ' / ')"
    # Now 0.4.0 is on disk: 0.3.0 is a downgrade.
    $before = Snap $staged
    Refused @($HC, '0.3.0') 'downgrade' 'an older version than the one installed'

    # ================================================================ story 6: updates, revocations and removals
    function Unstage([string] $id, [string] $v, [string[]] $more = @()) { Run-Exe -Unstage $id $v -Root $root @net @more }
    function RefusedU([string] $id, [string] $v, [string] $want, [string] $what, [string] $text) {
        Unstage $id $v
        $after = Snap $staged
        $dl = @(Get-ChildItem -LiteralPath (Join-Path $data 'downloads') -File -Force -ErrorAction SilentlyContinue)
        Ok ((Outcome) -eq "outcome: $want" -and $script:code -eq 1 -and (Same $before $after) -and $dl.Count -eq 0 -and (-not $text -or (Has-Line $text)) -and
            -not (Test-Path (Join-Path $data 'apply.lock'))) "unstage ${what}: $want; plan.txt and staged\ byte-identical, nothing new kept" "$(Shown); downloads: $($dl.Name -join ', ')"
    }
    # The installer's layout: a release zip's files written into the tree (no installed.txt records), a mods.txt line.
    function Install-Zip([string] $file, [string] $line) {
        $za = [IO.Compression.ZipArchive]::new([IO.MemoryStream]::new($zips[$file]), [IO.Compression.ZipArchiveMode]::Read)
        try {
            foreach ($e in $za.Entries) {
                $dest = Join-Path $root ($e.FullName -replace '/', '\')
                New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
                $s = $e.Open(); $fs = [IO.File]::Create($dest); $s.CopyTo($fs); $fs.Dispose(); $s.Dispose()
            }
        } finally { $za.Dispose() }
        if ($line) { $t = [IO.File]::ReadAllText($modsTxt); [IO.File]::WriteAllText($modsTxt, $t.Replace('Keybinds : 1', "$line : 1`r`nKeybinds : 1"), $utf8) }
    }
    $RVM = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\Rev'
    $UPM = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\Upd'
    $WMM = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\WhistleMute'
    function DeleteLines { @(PlanLines | Where-Object { $_ -like "delete`t*" }) }

    # Base pack, not installed, changed, not in the catalog: refused before anything is staged.
    $before = Snap $staged
    RefusedU $CORE '0.30.0' 'base-pack' $name 'the installer removes'
    RefusedU 'NuclearNightmare-Community.Mod-Manager' '0.7.0' 'base-pack' 'Mod Manager'
    RefusedU $WM '0.2.1' 'not-installed' 'a mod that is not installed' 'is not there'
    Install-Zip 'wm-0.2.1.zip' 'WhistleMute'
    RefusedU $WM '0.2.0' 'changed' 'another version than the one installed' 'holds 0.2.1'
    RefusedU 'nuclearnightmare-community.nothing' '1.0.0' 'not-in-catalog' 'an id the catalog lacks'
    New-Item -ItemType Directory -Force (Join-Path $mods 'Rev') | Out-Null
    [IO.File]::WriteAllText((Join-Path $mods 'Rev\mod.json'), (ModJson $REV 'Rev' '0.9.0'), $utf8)
    RefusedU $REV '0.9.0' 'not-in-catalog' 'a version neither installed.txt nor the catalog knows' 'not in installed.txt nor in the catalog'
    $lock = [IO.File]::Open((Join-Path $data 'apply.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Unstage $WM '0.2.1'
        Ok ((Outcome) -eq 'outcome: applying' -and (Same $before (Snap $staged))) 'unstage while apply.lock is held: applying, nothing staged' (Shown)
    } finally { $lock.Dispose(); Remove-Item -LiteralPath (Join-Path $data 'apply.lock') -ErrorAction SilentlyContinue }

    # Revocation and downgrades: a newer installed version is a downgrade unless it is revoked (the index's sha256).
    [IO.File]::WriteAllText((Join-Path $mods 'Rev\mod.json'), (ModJson $REV 'Rev' '0.6.0'), $utf8)
    Refused @($REV, '0.3.1') 'downgrade' 'away from 0.6.0, whose revoked entry has another sha256 (not revoked)' 'holds 0.6.0'
    [IO.File]::WriteAllText((Join-Path $mods 'Rev\mod.json'), (ModJson $REV 'Rev' '0.7.0'), $utf8)
    Stage $REV, '0.3.1'
    Ok ((Outcome) -eq 'outcome: ok' -and (Has-Line 'downgrade allowed: the installed nuclearnightmare-community.rev 0.7.0 is revoked') -and (DeleteLines).Count -eq 0 -and
        (Has-Line 'is not in installed.txt nor in the catalog; no files of it are deleted')) 'away from 0.7.0, revoked and no longer in the index: the downgrade is staged (no deletes: its files are unknown)' (Shown)
    # Back to the plan before, for the next cases: unstage of the pending Rev isn't possible (0.7.0 on disk is not in
    # the catalog), so the plan is rebuilt by staging Rev from a revoked 0.4.0 on disk.
    Remove-Item -LiteralPath (Join-Path $mods 'Rev') -Recurse -Force
    Install-Zip 'rev-0.4.0.zip' 'Rev'
    Install-Zip 'upd-1.0.0.zip' 'Upd'
    # Revoked, older fix: installer-installed 0.4.0 (no installed.txt records) -> 0.3.1. The deletes come from 0.4.0's own
    # verified release, downloaded although it is revoked (only read), and the update is allowed only because it is revoked.
    Stage $REV, '0.3.1'
    $oldSha = Sha (ZipEntryBytes 'rev-0.4.0.zip' "$M/Rev/Scripts/old.lua")
    $dels = DeleteLines
    Ok ((Outcome) -eq 'outcome: ok' -and $dels.Count -eq 1 -and ($dels -ccontains "delete`tRev`t$oldSha`t$RVM\Scripts\old.lua") -and (Has-Line 'downgrade allowed') -and
        (Has-Line 'files listed (release zip)') -and ((PlanLines) -ccontains "modstxt`tRev`ton") -and
        @(Get-ChildItem -LiteralPath (Join-Path $data 'downloads') -File -ErrorAction SilentlyContinue).Count -eq 0) 'revoked, older fix: 0.4.0 -> 0.3.1 staged, delete for the file only 0.4.0 had (from its verified release), downloads cleaned' "$(Shown); deletes: $($dels -join ' / ')"
    # A plain update of an installer-installed mod: 1.0.0 -> 1.1.0, delete for b.lua (only 1.0.0 had it).
    Stage $UPD, '1.1.0'
    $bSha = Sha (ZipEntryBytes 'upd-1.0.0.zip' "$M/Upd/b.lua")
    $dels = @(DeleteLines | Where-Object { $_ -like "delete`tUpd`t*" })
    Ok ((Outcome) -eq 'outcome: ok' -and $dels.Count -eq 1 -and ($dels -ccontains "delete`tUpd`t$bSha`t$UPM\b.lua") -and
        @(PlanLines | Where-Object { $_ -like "put`tRev`t*" }).Count -eq 2) 'update 1.0.0 -> 1.1.0 (installer layout): new puts, delete for b.lua, Rev kept' "$(Shown); plan: $((PlanLines) -join ' / ')"
    # Uninstall with one owned file edited on disk: kept (kept=1), the rest deleted, modstxt remove. A pending install of
    # the same owner is replaced first: WhistleMute staged again, then unstaged.
    Stage $WM, '0.2.1'
    Ok ((Outcome) -eq 'outcome: ok' -and @(PlanLines | Where-Object { $_ -like "put`tWhistleMute`t*" }).Count -eq 4) 'a pending (re)install of WhistleMute staged' (Shown)
    [IO.File]::WriteAllText((Join-Path $root "$WMM\Scripts\b.lua"), 'print("edited by the player")', $utf8)
    Unstage $WM '0.2.1'
    $pl = Payload
    $lines = PlanLines
    $wmDels = @($lines | Where-Object { $_ -like "delete`tWhistleMute`t*" })
    $wmFiles = StagedFiles
    Ok ((Outcome) -eq 'outcome: ok' -and $wmDels.Count -eq 3 -and -not ($wmDels | Where-Object { $_ -like '*b.lua' }) -and ($lines -ccontains "modstxt`tWhistleMute`tremove") -and
        -not ($lines | Where-Object { $_ -like "put`tWhistleMute`t*" }) -and -not ($lines -ccontains "modstxt`tWhistleMute`ton") -and
        ($lines | Where-Object { $_ -like "delete`tWhistleMute`t*`tNuclearNightmare\Content\Paks\LogicMods\WhistleMute.pak" })) 'uninstall: a delete per owned file and modstxt remove, the pending install replaced, the edited file kept' "$(Shown); plan: $($lines -join ' / ')"
    Ok ($pl -and $pl.txn -ceq (PlanTxn) -and $pl.ops -eq ($lines.Count - 2) -and $pl.owners.Count -eq 1 -and $pl.owners[0].id -ceq $WM -and $pl.owners[0].version -ceq '0.2.1' -and
        $pl.owners[0].name -ceq 'WhistleMute' -and $pl.owners[0].files -eq 3 -and $pl.owners[0].kept -eq 1 -and (Has-Line 'kept: ')) 'uninstall: payload {txn, owners [{id, version, name, files, kept=1}], ops}' (Shown)
    $wmMain = Sha (ZipEntryBytes 'wm-0.2.1.zip' "$M/WhistleMute/Scripts/main.lua")
    Ok (($wmFiles -notcontains $wmMain) -and (Has-Line "removed: staged file $wmMain")) 'uninstall: the replaced install''s staged files removed' ($wmFiles -join ', ')
    # Apply: Rev 0.3.1 without old.lua, Upd 1.1.0 without b.lua, WhistleMute gone but the edited file, its line removed.
    $applied = Apply
    $result = [IO.File]::ReadAllText((Join-Path $data 'apply-result.txt'))
    $txt = [IO.File]::ReadAllText($modsTxt)
    Ok ($result -match "(?m)^outcome`tapplied" -and -not (Test-Path -LiteralPath (Join-Path $root "$RVM\Scripts\old.lua")) -and
        ([IO.File]::ReadAllText((Join-Path $root "$RVM\Scripts\main.lua")) -ceq 'print("rev 0.3.1")') -and -not (Test-Path -LiteralPath (Join-Path $root "$UPM\b.lua")) -and
        ([IO.File]::ReadAllText((Join-Path $root "$UPM\a.lua")) -ceq 'a 1.1.0')) 'apply: Rev 0.3.1 in place and old.lua gone, Upd 1.1.0 and b.lua gone' "helper: $applied; $($result -replace "`n", ' / ')"
    Ok (-not (Test-Path -LiteralPath (Join-Path $root "$WMM\mod.json")) -and -not (Test-Path -LiteralPath (Join-Path $root "$WMM\Scripts\main.lua")) -and
        -not (Test-Path -LiteralPath (Join-Path $paks 'LogicMods\WhistleMute.pak')) -and (Test-Path -LiteralPath (Join-Path $root "$WMM\Scripts\b.lua")) -and
        -not $txt.Contains('WhistleMute') -and $txt.Contains("Rev : 1`r`n") -and $txt.Contains("Upd : 1`r`n")) 'apply: WhistleMute''s files and mods.txt line gone, the edited file kept' ($txt -replace "`r`n", ' / ')
    # Uninstall through installed.txt: HudClock 0.4.0 (applied by the helper above); after the apply its records are gone.
    $inst = [IO.File]::ReadAllText((Join-Path $data 'installed.txt'))
    Ok ($inst.Contains("HudClock`t") -and $inst.Contains("Rev`t")) 'installed.txt records HudClock and the updated Rev' ($inst -replace "`n", ' / ')
    Unstage $HC '0.4.0'
    $dels = DeleteLines
    Ok ((Outcome) -eq 'outcome: ok' -and $dels.Count -eq 2 -and (Has-Line 'files listed (installed.txt)') -and ((PlanLines) -ccontains "modstxt`tHudClock`tremove") -and
        ($dels -ccontains "delete`tHudClock`t$newMain`t$HCM\Scripts\main.lua")) 'uninstall from installed.txt: a delete per recorded file with its recorded SHA-256' "$(Shown); deletes: $($dels -join ' / ')"
    $applied = Apply
    $result = [IO.File]::ReadAllText((Join-Path $data 'apply-result.txt'))
    $inst = [IO.File]::ReadAllText((Join-Path $data 'installed.txt'))
    Ok ($result -match "(?m)^outcome`tapplied" -and -not (Test-Path -LiteralPath (Join-Path $root "$HCM\mod.json")) -and -not $inst.Contains("HudClock`t") -and $inst.Contains("Rev`t") -and
        -not [IO.File]::ReadAllText($modsTxt).Contains('HudClock')) 'apply: HudClock removed, its installed.txt records and mods.txt line gone, Rev''s records kept' "helper: $applied; installed: $($inst -replace "`n", ' / ')"

    # Story 6 review: the installed version's own release is listed but can't be downloaded (404): the removal and the
    # update are refused, plan.txt and staged\ byte-identical, no zip left in downloads\.
    Install-Zip 'gone-1.0.0.zip' 'Gone'
    $before = Snap $staged
    Unstage $GONE '1.0.0'
    $goneOutcome = Outcome
    RefusedU $GONE '1.0.0' ($goneOutcome -replace '^outcome: ', '') 'Gone 1.0.0 whose release answers 404'
    Ok ($goneOutcome -eq 'outcome: unreachable') 'unstage: a 404 for the installed release is unreachable (a download refusal)' (Shown)
    Refused @($GONE, '1.1.0') ($goneOutcome -replace '^outcome: ', '') 'update Gone 1.0.0 -> 1.1.0 whose installed release answers 404'
    Ok (Test-Path -LiteralPath (Join-Path $mods 'Gone\a.lua')) 'the refused update and removal left Gone on disk' $null

    # Story 6 review: player data is never listed. installed.txt naming Pd's settings.json (with its hash on disk):
    # the uninstall deletes main.lua and mod.json, never settings.json, which stays on disk after the apply.
    Install-Zip 'pd-1.0.0.zip' 'Pd'
    $pdSettings = Join-Path $mods 'Pd\settings.json'
    [IO.File]::WriteAllText($pdSettings, '{"x":1}', $utf8)
    $PDM = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\Pd'
    $recs = foreach ($rel in 'mod.json', 'Scripts\main.lua', 'settings.json') { "Pd`t$(Sha ([IO.File]::ReadAllBytes((Join-Path $root "$PDM\$rel"))))`t$PDM\$rel" }
    $instFile = Join-Path $data 'installed.txt'
    $it = [IO.File]::ReadAllText($instFile); if (-not $it.EndsWith("`n")) { $it += "`n" }
    [IO.File]::WriteAllText($instFile, $it + ($recs -join "`n") + "`n", $utf8)
    Unstage $PD '1.0.0'
    $pl = Payload
    $pdDels = @(DeleteLines | Where-Object { $_ -like "delete`tPd`t*" })
    Ok ((Outcome) -eq 'outcome: ok' -and $pdDels.Count -eq 2 -and -not ($pdDels | Where-Object { $_ -like '*settings.json' }) -and $pl -and $pl.owners[0].files -eq 2 -and
        $pl.owners[0].kept -eq 0) 'uninstall: installed.txt naming settings.json lists only mod.json and main.lua (player data never listed)' "$(Shown); deletes: $($pdDels -join ' / ')"
    $applied = Apply
    Ok ((Test-Path -LiteralPath $pdSettings) -and -not (Test-Path -LiteralPath (Join-Path $mods 'Pd\mod.json')) -and -not (Test-Path -LiteralPath (Join-Path $mods 'Pd\Scripts'))) 'apply: Pd removed but its settings.json, which stays in Mods/Pd/' "helper: $applied"

    # ================================================================ story 6 review: the matrix's update rows, unstage refusals
    function TreeSha([string] $rel) { $f = Join-Path $root $rel; if (Test-Path -LiteralPath $f) { Sha ([IO.File]::ReadAllBytes($f)) } }
    function NoDownloads { @(Get-ChildItem -LiteralPath (Join-Path $data 'downloads') -File -Force -ErrorAction SilentlyContinue).Count -eq 0 }
    # Nucleus self-update: the core package's own id over an installed older core (0.25.0, Reset-Layout; not in the
    # index, so no deletes), its dlls\main.dll and bin\<Core>Restart.exe staged like any mod's files. With --root the
    # helper runs from build\native-out\test\, so the put to the layout's bin\<Core>Restart.exe is not its own image: a
    # plain put (the rename aside of the running image is apply.tests.ps1's self-update case).
    Reset-Layout
    $CMW = "NuclearNightmare\Binaries\Win64\ue4ss\Mods\$name"
    New-Item -ItemType Directory -Force (Join-Path $root "$CMW\dlls") | Out-Null
    [IO.File]::WriteAllText((Join-Path $root "$CMW\dlls\main.dll"), 'old core dll')
    [IO.File]::WriteAllText((Join-Path $root "$CMW\bin\$($name)Restart.exe"), 'old helper')
    Stage $CORE, '0.31.0'
    $pl = Payload
    $lines = PlanLines
    $dllB = ZipEntryBytes 'core-0.31.0.zip' "$CM/dlls/main.dll"; $exeB = ZipEntryBytes 'core-0.31.0.zip' "$CM/bin/$($name)Restart.exe"
    $dllSha = Sha $dllB; $exeSha = Sha $exeB
    Ok ((Outcome) -eq 'outcome: ok' -and $script:code -eq 0 -and $pl.owners.Count -eq 1 -and $pl.owners[0].id -ceq $CORE -and $pl.owners[0].name -ceq $name -and
        $pl.owners[0].version -ceq '0.31.0' -and ($lines -ccontains "put`t$name`t$dllSha`t$($dllB.Length)`t$CMW\dlls\main.dll") -and
        ($lines -ccontains "put`t$name`t$exeSha`t$($exeB.Length)`t$CMW\bin\$($name)Restart.exe") -and (DeleteLines).Count -eq 0) 'core self-update: the core''s own id stages ok, main.dll and the relaunch helper put' "$(Shown); plan: $($lines -join ' / ')"
    $applied = Apply
    $result = if (Test-Path (Join-Path $data 'apply-result.txt')) { [IO.File]::ReadAllText((Join-Path $data 'apply-result.txt')) } else { '' }
    $inst = [IO.File]::ReadAllText((Join-Path $data 'installed.txt'))
    $txt = [IO.File]::ReadAllText($modsTxt)
    Ok ($result -match "(?m)^outcome`tapplied" -and (TreeSha "$CMW\dlls\main.dll") -ceq $dllSha -and (TreeSha "$CMW\bin\$($name)Restart.exe") -ceq $exeSha -and
        (TreeSha "$CMW\mod.json") -ceq (Sha (ZipEntryBytes 'core-0.31.0.zip' "$CM/mod.json")) -and
        @(Get-ChildItem -LiteralPath (Join-Path $root "$CMW\bin") -Filter '*.old' -File -ErrorAction SilentlyContinue).Count -eq 0 -and -not (Test-Path $planFile) -and
        $inst.Contains("$name`t$dllSha`t$CMW\dlls\main.dll") -and $inst.Contains("$name`t$exeSha`t$CMW\bin\$($name)Restart.exe") -and
        ([regex]::Matches($txt, "(?m)^$([regex]::Escape($name)) : 1\r$")).Count -eq 1) 'core self-update applied (--root): the new main.dll and helper in place, no .old, installed.txt records them, one mods.txt line' "helper: $applied; result: $($result -replace "`n", ' / '); installed: $($inst -replace "`n", ' / ')"

    # Update, dep too old: Upd 1.0.0 (installer layout) -> 1.2.0 and the core 0.25.0 -> 0.31.0 it needs, in one stage.
    Reset-Layout
    Install-Zip 'upd-1.0.0.zip' 'Upd'
    Stage $CORE, '0.31.0', $UPD, '1.2.0'
    $pl = Payload
    $lines = PlanLines
    $dels = DeleteLines
    Ok ((Outcome) -eq 'outcome: ok' -and $pl.owners.Count -eq 2 -and $pl.owners[0].name -ceq $name -and $pl.owners[1].name -ceq 'Upd' -and $pl.ops -eq ($lines.Count - 2) -and
        @($lines | Where-Object { $_ -like "put`t$name`t*" }).Count -eq 4 -and @($lines | Where-Object { $_ -like "put`tUpd`t*" }).Count -eq 2 -and
        $dels.Count -eq 1 -and ($dels -ccontains "delete`tUpd`t$bSha`t$UPM\b.lua")) 'update, dep too old: one stage, owners=2 (the core first), the plan holds both, delete for b.lua' "$(Shown); plan: $($lines -join ' / ')"
    $applied = Apply
    $result = [IO.File]::ReadAllText((Join-Path $data 'apply-result.txt'))
    Ok ($result -match "(?m)^outcome`tapplied" -and (TreeSha "$CMW\dlls\main.dll") -ceq $dllSha -and ([IO.File]::ReadAllText((Join-Path $root "$UPM\a.lua")) -ceq 'a 1.2.0') -and
        -not (Test-Path -LiteralPath (Join-Path $root "$UPM\b.lua"))) 'update, dep too old applied: the core 0.31.0 and Upd 1.2.0 in place, b.lua gone' "helper: $applied; $($result -replace "`n", ' / ')"

    # Revoked, newer fix: an installer-installed revoked Rev 0.4.0 -> 0.6.0 (no downgrade involved); the delete for the
    # file only 0.4.0 had comes from 0.4.0's own verified release (installed.txt has no Rev records).
    Install-Zip 'rev-0.4.0.zip' 'Rev'
    Stage $REV, '0.6.0'
    $dels = DeleteLines
    Ok ((Outcome) -eq 'outcome: ok' -and $dels.Count -eq 1 -and ($dels -ccontains "delete`tRev`t$oldSha`t$RVM\Scripts\old.lua") -and -not (Has-Line 'downgrade allowed') -and
        (Has-Line 'files listed (release zip)') -and ((PlanLines) -ccontains "modstxt`tRev`ton") -and (NoDownloads)) 'revoked, newer fix: 0.4.0 -> 0.6.0 staged, delete for the file only 0.4.0 had (from its verified release)' "$(Shown); deletes: $($dels -join ' / ')"
    $applied = Apply
    $result = [IO.File]::ReadAllText((Join-Path $data 'apply-result.txt'))
    Ok ($result -match "(?m)^outcome`tapplied" -and -not (Test-Path -LiteralPath (Join-Path $root "$RVM\Scripts\old.lua")) -and
        ([IO.File]::ReadAllText((Join-Path $root "$RVM\Scripts\main.lua")) -ceq 'print("rev 0.6.0")')) 'revoked, newer fix applied: Rev 0.6.0 in place, old.lua gone' "helper: $applied; $($result -replace "`n", ' / ')"

    # Unstage refusals with a staged plan in place: interrupted (before the job), then -NoPrecheck under apply.lock held
    # and with a journal without done (the job's own check at write time). WhistleMute is installer-installed, so the
    # -NoPrecheck runs download its release first; that download is removed again.
    Install-Zip 'wm-0.2.1.zip' 'WhistleMute'
    Stage $HC, '0.3.0'
    Ok ((Outcome) -eq 'outcome: ok') 'a staged plan for the unstage refusals' (Shown)
    $before = Snap $staged
    $lock = [IO.File]::Open((Join-Path $data 'apply.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Unstage $WM '0.2.1' @('-NoPrecheck')
        Ok ((Outcome) -eq 'outcome: applying' -and $script:code -eq 1 -and (Has-Line 'apply.lock is held') -and (Same $before (Snap $staged)) -and (NoDownloads)) 'unstage, apply.lock held at write time (-NoPrecheck): applying from the job, plan.txt and staged\ byte-identical, the download removed' (Shown)
    } finally { $lock.Dispose(); Remove-Item -LiteralPath (Join-Path $data 'apply.lock') -ErrorAction SilentlyContinue }
    $rb = Join-Path $data 'rollback'
    if (Test-Path -LiteralPath $rb) { Remove-Item -LiteralPath $rb -Recurse -Force }
    New-Item -ItemType Directory -Force $rb | Out-Null
    [IO.File]::WriteAllText((Join-Path $rb 'journal.txt'), "nucleus-journal`t1`ntxn`t$('ab' * 16)`n", $utf8)
    RefusedU $WM '0.2.1' 'interrupted' 'a journal without done'
    Unstage $WM '0.2.1' @('-NoPrecheck')
    Ok ((Outcome) -eq 'outcome: interrupted' -and $script:code -eq 1 -and (Has-Line 'cut short (found under apply.lock)') -and (Same $before (Snap $staged)) -and (NoDownloads) -and
        -not (Test-Path (Join-Path $data 'apply.lock'))) 'unstage, a journal without done found under the lock (-NoPrecheck): interrupted from the job, plan.txt and staged\ byte-identical' (Shown)
    Remove-Item -LiteralPath $rb -Recurse -Force
} catch {
    $script:failed++
    Write-Host "FAIL: runner failure: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
} finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "stage.tests: $($script:passed) passed, $($script:failed) failed"
if ($script:failed) { exit 1 }
exit 0
