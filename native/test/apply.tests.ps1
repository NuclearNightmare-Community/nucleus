<#
.SYNOPSIS
  Tests applying staged changes (Mod Manager v2 story 3) with the relaunch helper's test build against a temporary
  install layout, without any game.
.DESCRIPTION
  Drives build/native-out/test/<name>RestartTest.exe in apply mode (--apply; --root <dir> puts the layout under a temp
  folder, --fail-after / --crash-after force a failure or an interruption) and the shipped build/native-out/bin/
  <name>Restart.exe (self-update and bad argv only). Plans are written with native/test/New-StagedPlan.ps1. Every row of
  the story's I/O matrix except Restart now (that one is the Mod Manager's VM run), plus the relaunch request:
    - applied: mod files, a LogicMods pak and a base pak put, mods.txt edited (BOM and CRLF kept, the line above
      Keybinds), installed.txt written, staged\ cleared, the rollback copies kept; a delete (with its hash) and
      "modstxt remove" afterwards, emptied folders gone
    - a locked target (a .NET FileStream with FileShare.Read): every earlier step undone, the tree byte-identical,
      failed/locked with the path, the plan still staged; attempts 2, then the third failure discards it to failed\
    - a staged file that doesn't match: discarded at once, nothing written; a hashed delete whose file changed: failed
    - bad plans and targets (.., absolute, ADS, a junction, a stock mod, mods.txt by put, outside the layout, device
      names, malformed lines, limits): discarded as bad-plan before any write
    - another game exe under <root>: 60 s, then failed/game-running, no attempt counted, the plan stays
    - interrupted (--crash-after): the next helper rolls back first (byte-identical), then applies
    - --fail-after: rolled back at every step count
    - self-update: a put to the helper's own image renames the running copy to bin\<name>Restart.<txn>.old (put back
      on a rollback); a later helper deletes it
    - relaunch.txt: relaunched only when it names the waited game and this helper (not with --mode none); deleted
      either way
    - bad argv for apply mode (test and shipped builds)
  Prints ok:/FAIL: lines and exits 1 on any failure. Then runs restart-helper.tests.ps1 (story 8's cases).
.EXAMPLE
  pwsh -NoProfile -File native/test/apply.tests.ps1
#>
param([string] $TestExe, [string] $ShippedExe, [switch] $SkipRestartTests)
$ErrorActionPreference = 'Stop'
if ($env:NN_CI -eq '1') { Write-Host 'SKIP: apply.tests.ps1 needs the native build (NN_CI=1)'; exit 0 }
$repo = Split-Path (Split-Path $PSScriptRoot)
$name = (Get-Content (Join-Path $repo 'mod.json') -Raw | ConvertFrom-Json).name
if (-not $TestExe) { $TestExe = Join-Path $repo "build\native-out\test\$($name)RestartTest.exe" }
if (-not $ShippedExe) { $ShippedExe = Join-Path $repo "build\native-out\bin\$($name)Restart.exe" }
foreach ($f in $TestExe, $ShippedExe) { if (-not (Test-Path -LiteralPath $f)) { Write-Host "FAIL: $f not found; run build.ps1 -Steps native first"; exit 1 } }
$planTool = Join-Path $PSScriptRoot 'New-StagedPlan.ps1'

if (-not ('ApplyTest.Native' -as [type])) {
    Add-Type -Namespace ApplyTest -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern System.IntPtr OpenProcess(uint access, bool inherit, int pid);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(System.IntPtr h);
'@
}
$SYNCHRONIZE = 0x00100000
$QUERY_LIMITED = 0x1000

$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $label, $detail) {
    if ($cond) { $script:passed++; Write-Host "ok:   $label" } else { $script:failed++; Write-Host "FAIL: $label$(if ($null -ne $detail) { " -- $detail" })" }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) "$name-apply-$PID"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null
$rec = Join-Path $tmp 'record.txt'
$utf8 = [Text.UTF8Encoding]::new($false)

# ---------------------------------------------------------------- the layout
$root = Join-Path $tmp 'game root'
$win64 = Join-Path $root 'NuclearNightmare\Binaries\Win64'
$ue4ss = Join-Path $win64 'ue4ss'
$mods = Join-Path $ue4ss 'Mods'
$modsTxt = Join-Path $mods 'mods.txt'
$data = Join-Path $ue4ss "$($name)Data"
$paks = Join-Path $root 'NuclearNightmare\Content\Paks'
$logic = Join-Path $paks 'LogicMods'
$bin = Join-Path $mods "$name\bin"
$stockTxt = "`u{FEFF}$name : 1`r`nBPModLoaderMod : 1`r`n; a comment line`r`nKeybinds : 1`r`n"
function Reset-Layout {
    if (Test-Path $root) { cmd /c rmdir /s /q "`"$root`"" | Out-Null }
    foreach ($d in $mods, $data, $logic, $bin, (Join-Path $mods 'BPModLoaderMod'), (Join-Path $mods 'Keybinds')) { New-Item -ItemType Directory -Force $d | Out-Null }
    [IO.File]::WriteAllText($modsTxt, $stockTxt, $utf8)
    [IO.File]::WriteAllText((Join-Path $paks 'NuclearNightmare-Windows.pak'), 'game pak')
    [IO.File]::WriteAllText((Join-Path $logic "$name.pak"), 'core pak')
    [IO.File]::WriteAllText((Join-Path $mods 'BPModLoaderMod\main.lua'), 'stock')
}
function Rel([string] $p) { $p.Substring($root.Length + 1) }
# Every file under <root> outside the data folder: relative path -> SHA-256; folders as "<dir>\".
function Snapshot {
    $map = [ordered]@{}
    Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { -not $_.FullName.StartsWith($data, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { $map[(Rel $_.FullName) + '\'] = 'dir' } else { $map[(Rel $_.FullName)] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    }
    $map
}
function Same($a, $b) {
    if ($a.Count -ne $b.Count) { return $false }
    foreach ($k in $a.Keys) { if (-not $b.Contains($k) -or $a[$k] -ne $b[$k]) { return $false } }
    $true
}
function Diff($a, $b) { @(@($a.Keys | Where-Object { -not $b.Contains($_) -or $a[$_] -ne $b[$_] }) + @($b.Keys | Where-Object { -not $a.Contains($_) })) -join ', ' }
function Stage([object[]] $ops, [string] $txn) { $p = @{ Data = $data; Ops = $ops }; if ($txn) { $p.Txn = $txn }; & $planTool @p }
function StageRaw([string] $text) { & $planTool -Data $data -Raw $text | Out-Null }
function Result { $f = Join-Path $data 'apply-result.txt'; if (Test-Path $f) { [IO.File]::ReadAllText($f) } else { '' } }
function ResultOf([string] $key) { if ((Result) -match "(?m)^$key`t(.*)$") { $Matches[1].TrimEnd("`r") } else { $null } }
function Staged { Test-Path (Join-Path $data 'staged\plan.txt') }
function Text([string] $p) { if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } else { $null } }

# A short-lived process to wait on (about 1 s), and an inheritable handle to it.
function New-Sleeper([int] $sec = 1, [switch] $Query) {
    $p = Start-Process ping -ArgumentList '-n', ($sec + 1), '127.0.0.1' -WindowStyle Hidden -PassThru
    $access = $SYNCHRONIZE; if ($Query) { $access = $access -bor $QUERY_LIMITED }
    $h = [ApplyTest.Native]::OpenProcess($access, $true, $p.Id)
    if ($h -eq [IntPtr]::Zero) { throw "OpenProcess($($p.Id)) failed" }
    [pscustomobject]@{ Process = $p; Handle = $h }
}
# Starts exe with a raw argument string; returns exit code, stdout and seconds; -1 when it didn't exit in time.
function Start-Helper([string] $exe, [string] $argStr) {
    $psi = [Diagnostics.ProcessStartInfo]::new($exe)
    $psi.Arguments = $argStr
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($psi)
    [pscustomobject]@{ Process = $p; Out = $p.StandardOutput.ReadToEndAsync(); Watch = [Diagnostics.Stopwatch]::StartNew() }
}
function Wait-Helper($h, [int] $limitSec = 120) {
    if (-not $h.Process.WaitForExit($limitSec * 1000)) { $h.Process.Kill(); return [pscustomobject]@{ Code = -1; Out = ''; Sec = $h.Watch.Elapsed.TotalSeconds } }
    $h.Process.WaitForExit()
    [pscustomobject]@{ Code = $h.Process.ExitCode; Out = $h.Out.Result.Trim(); Sec = $h.Watch.Elapsed.TotalSeconds }
}
# One apply: waits for a fresh sleeper, applies, returns { Code; Out }.
function Apply([string] $extra = '', [string] $exe = $TestExe, [switch] $NoRoot, [string] $mode = 'direct') {
    $s = New-Sleeper 1
    $rootArg = if ($NoRoot) { '' } else { " --root `"$root`"" }
    $h = Start-Helper $exe "--wait $([int64]$s.Handle) --apply --mode $mode --cwd `"C:\a b`" --exe `"C:\a b\g.exe`"$rootArg --record `"$rec`" $extra -- g.exe -x"
    $r = Wait-Helper $h
    [void][ApplyTest.Native]::CloseHandle($s.Handle)
    $r
}

$A_LUA = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\Scripts\main.lua'
$A_JSON = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\mod.json'
$A_LOGIC = 'NuclearNightmare\Content\Paks\LogicMods\ModA.pak'
$A_BASE = 'NuclearNightmare\Content\Paks\ModA_P.pak'
$EXIST = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModX\Scripts\main.lua'
$Y_BASE = 'NuclearNightmare\Content\Paks\ModY_P.pak'
$planA = @(
    @{ Op = 'put'; Owner = 'ModA'; Target = $A_JSON; Text = '{"name":"ModA"}' },
    @{ Op = 'put'; Owner = 'ModA'; Target = $A_LUA; Text = 'print("[ModA] loaded\n")' },
    @{ Op = 'put'; Owner = 'ModA'; Target = $A_LOGIC; Text = 'logic pak A' },
    @{ Op = 'put'; Owner = 'ModA'; Target = $A_BASE; Text = 'base pak A' },
    @{ Op = 'modstxt'; Name = 'ModA'; Value = 'on' })

try {
    # ================================================================ applied
    Reset-Layout
    $txn = Stage $planA
    $r = Apply
    Ok ($r.Code -eq 0 -and $r.Out -match '^apply applied ') 'applied: exit 0, "apply applied"' "$($r.Code) [$($r.Out)]"
    Ok ((ResultOf 'outcome') -eq 'applied' -and (ResultOf 'txn') -eq $txn -and (ResultOf 'reason') -eq '-' -and (ResultOf 'attempts') -eq '1') 'applied: apply-result.txt (txn, applied, reason -, attempts 1)' (Result)
    Ok ((Text (Join-Path $root $A_LUA)) -ceq 'print("[ModA] loaded\n")' -and (Text (Join-Path $root $A_JSON)) -ceq '{"name":"ModA"}' -and (Text (Join-Path $root $A_LOGIC)) -ceq 'logic pak A' -and (Text (Join-Path $root $A_BASE)) -ceq 'base pak A') 'applied: every file in place, byte for byte'
    $want = "`u{FEFF}$name : 1`r`nBPModLoaderMod : 1`r`n; a comment line`r`nModA : 1`r`nKeybinds : 1`r`n"
    Ok ([IO.File]::ReadAllText($modsTxt, $utf8) -ceq $want) 'applied: mods.txt keeps the BOM and CRLF, "ModA : 1" above Keybinds' ([IO.File]::ReadAllText($modsTxt))
    Ok (-not (Test-Path (Join-Path $data 'staged'))) 'applied: staged\ cleared'
    $journal = Text (Join-Path $data 'rollback\journal.txt')
    Ok ($journal -and $journal.TrimEnd().EndsWith('done') -and (Test-Path (Join-Path $data 'rollback\files'))) 'applied: the journal ends with done; the rollback copies are kept'
    $inst = Text (Join-Path $data 'installed.txt')
    $shaLua = (Get-FileHash -LiteralPath (Join-Path $root $A_LUA) -Algorithm SHA256).Hash.ToLowerInvariant()
    Ok ($inst -and $inst.StartsWith("nucleus-installed`t1`n") -and $inst.Contains("ModA`t$shaLua`t$A_LUA`n") -and ([regex]::Matches($inst, "`n").Count -eq 5)) 'applied: installed.txt names owner, SHA-256 and target of each of the 4 files' $inst
    Ok (-not (Get-ChildItem -LiteralPath $root -Recurse -Filter '*.tmp' | Where-Object { $_.FullName -notlike "$data*" })) 'applied: no .tmp left beside a target'
    $r = Apply
    Ok ($r.Code -eq 0 -and $r.Out -match '^apply none \| nothing staged') 'applied: the next helper finds nothing staged' $r.Out
    Ok (-not (Test-Path $rec)) 'applied: no relaunch without relaunch.txt'

    # ---- a delete (hash checked), modstxt remove, folders emptied by it removed, installed.txt updated
    $before = Snapshot
    $shaJson = (Get-FileHash -LiteralPath (Join-Path $root $A_JSON) -Algorithm SHA256).Hash.ToLowerInvariant()
    Stage @(
        @{ Op = 'delete'; Owner = 'ModA'; Target = $A_LUA; Sha256 = $shaLua },
        @{ Op = 'delete'; Owner = 'ModA'; Target = $A_JSON; Sha256 = $shaJson },
        @{ Op = 'delete'; Owner = 'ModA'; Target = $A_LOGIC },
        @{ Op = 'delete'; Owner = 'ModA'; Target = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\gone.txt' },
        @{ Op = 'modstxt'; Name = 'ModA'; Value = 'remove' }) | Out-Null
    $r = Apply
    Ok ((ResultOf 'outcome') -eq 'applied') 'delete: applied' $r.Out
    Ok (-not (Test-Path (Join-Path $mods 'ModA')) -and -not (Test-Path (Join-Path $root $A_LOGIC)) -and (Test-Path $logic) -and (Test-Path (Join-Path $root $A_BASE))) 'delete: the files gone, ModA\ (emptied) removed, LogicMods\ kept, the base pak untouched; a missing file is no error'
    Ok ([IO.File]::ReadAllText($modsTxt, $utf8) -ceq $stockTxt) 'delete: "modstxt remove" takes the line out again (bytes as before)'
    $inst = Text (Join-Path $data 'installed.txt')
    Ok ($inst -ceq "nucleus-installed`t1`nModA`t$((Get-FileHash -LiteralPath (Join-Path $root $A_BASE) -Algorithm SHA256).Hash.ToLowerInvariant())`t$A_BASE`n") 'delete: installed.txt keeps only the base pak' $inst

    # ================================================================ locked target
    Reset-Layout
    New-Item -ItemType Directory -Force (Split-Path (Join-Path $root $EXIST)) | Out-Null
    [IO.File]::WriteAllText((Join-Path $root $EXIST), 'old X')
    [IO.File]::WriteAllText((Join-Path $data 'installed.txt'), "nucleus-installed`t1`n")
    $before = Snapshot
    $lockedPlan = @(
        @{ Op = 'put'; Owner = 'ModA'; Target = $A_LUA; Text = 'new A' },
        @{ Op = 'put'; Owner = 'ModA'; Target = $A_BASE; Text = 'base A' },
        @{ Op = 'modstxt'; Name = 'ModA'; Value = 'on' },
        @{ Op = 'put'; Owner = 'ModX'; Target = $EXIST; Text = 'new X' })
    $txnL = Stage $lockedPlan
    $fs = [IO.File]::Open((Join-Path $root $EXIST), 'Open', 'Read', 'Read')
    try {
        $r = Apply
        Ok ((ResultOf 'outcome') -eq 'failed' -and (ResultOf 'reason') -eq 'locked' -and (ResultOf 'path') -eq $EXIST -and (ResultOf 'attempts') -eq '1') 'locked: failed, reason locked, the path named, attempts 1' (Result)
        $after = Snapshot
        Ok (Same $before $after) 'locked: every earlier step undone, the tree byte-identical (files and folders)' (Diff $before $after)
        Ok ([IO.File]::ReadAllText($modsTxt, $utf8) -ceq $stockTxt) 'locked: mods.txt as before'
        Ok ((Staged) -and (Text (Join-Path $data 'staged\attempts.txt')) -ceq "$txnL`t1`n") 'locked: the plan still staged, attempts.txt 1'
        Ok ((Text (Join-Path $data 'installed.txt')) -ceq "nucleus-installed`t1`n") 'locked: installed.txt as before'
        Ok (-not (Test-Path (Join-Path $data 'rollback'))) 'locked: no rollback copies left after a complete rollback'
        $r = Apply
        Ok ((ResultOf 'outcome') -eq 'failed' -and (ResultOf 'attempts') -eq '2' -and (Same $before (Snapshot))) 'locked again: failed, attempts 2, byte-identical'
        $r = Apply
        Ok ((ResultOf 'outcome') -eq 'discarded' -and (ResultOf 'reason') -eq 'locked' -and (ResultOf 'attempts') -eq '3') 'third failure: discarded (reason locked, attempts 3)' (Result)
        Ok (-not (Staged) -and (Test-Path (Join-Path $data 'failed\plan.txt')) -and (Same $before (Snapshot))) 'third failure: the plan moved to failed\, nothing applied'
    } finally { $fs.Dispose() }
    # Only the latest discarded plan is kept.
    StageRaw "nucleus-plan`t1`ntxn`t$('a' * 32)`nbogus`n"
    $r = Apply
    Ok ((ResultOf 'outcome') -eq 'discarded' -and (Text (Join-Path $data 'failed\plan.txt')) -match 'bogus' -and -not (Get-ChildItem (Join-Path $data 'failed') -Recurse -File | Where-Object { $_.Name -ne 'plan.txt' })) 'failed\ holds only the latest discarded plan'

    # ================================================================ a staged file that doesn't match
    Reset-Layout
    $before = Snapshot
    $null = Stage $planA
    $f = Get-ChildItem (Join-Path $data 'staged\files') | Select-Object -First 1
    $bytes = [IO.File]::ReadAllBytes($f.FullName); $bytes[0] = $bytes[0] -bxor 1; [IO.File]::WriteAllBytes($f.FullName, $bytes)
    $r = Apply
    Ok ((ResultOf 'outcome') -eq 'discarded' -and (ResultOf 'reason') -eq 'staged-file-mismatch' -and (ResultOf 'attempts') -eq '0') 'tampered (same size): discarded at once, staged-file-mismatch' (Result)
    Ok ((Same $before (Snapshot)) -and -not (Staged) -and (Test-Path (Join-Path $data 'failed\plan.txt'))) 'tampered: nothing written; the plan in failed\'
    $null = Stage $planA
    $f = Get-ChildItem (Join-Path $data 'staged\files') | Select-Object -First 1
    [IO.File]::AppendAllText($f.FullName, 'x')
    $r = Apply
    Ok ((ResultOf 'reason') -eq 'staged-file-mismatch' -and (Same $before (Snapshot))) 'tampered (size): discarded, nothing written'
    $null = Stage $planA
    Remove-Item (Get-ChildItem (Join-Path $data 'staged\files') | Select-Object -First 1).FullName
    $r = Apply
    Ok ((ResultOf 'reason') -eq 'staged-file-mismatch' -and (Same $before (Snapshot))) 'a staged file missing: discarded, nothing written'

    # ---- a hashed delete whose file changed: failed (target-changed), nothing written
    [IO.File]::WriteAllText((Join-Path $root $A_BASE), 'someone else''s pak')
    $before = Snapshot
    $null = Stage @(@{ Op = 'put'; Owner = 'ModA'; Target = $A_LUA; Text = 'x' }, @{ Op = 'delete'; Owner = 'ModA'; Target = $A_BASE; Sha256 = ('0' * 64) })
    $r = Apply
    Ok ((ResultOf 'outcome') -eq 'failed' -and (ResultOf 'reason') -eq 'target-changed' -and (ResultOf 'path') -eq $A_BASE -and (ResultOf 'attempts') -eq '1' -and (Same $before (Snapshot)) -and (Staged)) 'delete of a changed file: failed target-changed, nothing written, still staged' (Result)

    # ================================================================ bad plans and targets
    Reset-Layout
    $junction = Join-Path $mods 'ModJ'
    $elsewhere = Join-Path $tmp 'elsewhere'
    New-Item -ItemType Directory -Force $elsewhere | Out-Null
    cmd /c mklink /J "`"$junction`"" "`"$elsewhere`"" | Out-Null
    $before = Snapshot
    $badTargets = [ordered]@{
        '..'                  = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\..\..\evil.dll'
        '.'                   = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\.\x.lua'
        'absolute'            = 'C:\Windows\evil.dll'
        'UNC'                 = '\\server\share\x.lua'
        'leading separator'   = '\NuclearNightmare\Content\Paks\ModA_P.pak'
        'ADS'                 = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\x.lua:stream'
        'forward slash'       = 'NuclearNightmare/Binaries/Win64/ue4ss/Mods/ModA/x.lua'
        'junction'            = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModJ\x.lua'
        'stock mod'           = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\BPModLoaderMod\main.lua'
        'stock mod (case)'    = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\keybinds\x.lua'
        'mods.txt by put'     = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\mods.txt'
        'data folder'         = "NuclearNightmare\Binaries\Win64\ue4ss\$($name)Data\installed.txt"
        'outside the layout'  = 'NuclearNightmare\Binaries\Win64\evil.dll'
        'UE4SS.dll'           = 'NuclearNightmare\Binaries\Win64\ue4ss\UE4SS.dll'
        'device name'         = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\CON.lua'
        'COM1'                = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\com1'
        'trailing dot'        = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\x.lua.'
        'trailing space'      = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\x.lua '
        'name with a dot'     = 'NuclearNightmare\Content\Paks\LogicMods\Mod.A.pak'
        'pak not _P'          = 'NuclearNightmare\Content\Paks\ModA.pak'
        'nested LogicMods'    = 'NuclearNightmare\Content\Paks\LogicMods\x\ModA.pak'
        'no file in mod'      = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA'
        'nine components'     = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\1\2\3\4\5\6\7\8\9'
        'long component'      = "NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\$('a' * 65)"
        'empty component'     = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\\x.lua'
        'wildcard'            = 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\*.lua'
    }
    foreach ($k in $badTargets.Keys) {
        $null = Stage @(@{ Op = 'put'; Owner = 'ModA'; Target = $A_LUA; Text = 'first' }, @{ Op = 'put'; Owner = 'ModA'; Target = $badTargets[$k]; Text = 'bad' })
        $r = Apply
        Ok ((ResultOf 'outcome') -eq 'discarded' -and (ResultOf 'reason') -eq 'bad-plan' -and (Same $before (Snapshot)) -and -not (Test-Path (Join-Path $elsewhere 'x.lua'))) "bad target ($k): discarded bad-plan before any write" "$(Result) | $(Diff $before (Snapshot))"
    }
    $sha0 = 'a' * 64
    $txn0 = 'b' * 32
    $badPlans = [ordered]@{
        'unknown op'          = "nucleus-plan`t1`ntxn`t$txn0`nmove`tModA`t$A_LUA`n"
        'BOM'                 = "`u{FEFF}nucleus-plan`t1`ntxn`t$txn0`nmodstxt`tModA`ton`n"
        'version 2'           = "nucleus-plan`t2`ntxn`t$txn0`nmodstxt`tModA`ton`n"
        'no txn'              = "nucleus-plan`t1`nmodstxt`tModA`ton`n"
        'upper-case txn'      = "nucleus-plan`t1`ntxn`t$($txn0.ToUpper())`nmodstxt`tModA`ton`n"
        'no operation'        = "nucleus-plan`t1`ntxn`t$txn0`n"
        'empty line'          = "nucleus-plan`t1`ntxn`t$txn0`n`nmodstxt`tModA`ton`n"
        'extra field'         = "nucleus-plan`t1`ntxn`t$txn0`nmodstxt`tModA`ton`tx`n"
        'modstxt off'         = "nucleus-plan`t1`ntxn`t$txn0`nmodstxt`tModA`toff`n"
        'modstxt stock'       = "nucleus-plan`t1`ntxn`t$txn0`nmodstxt`tKeybinds`tremove`n"
        'modstxt twice'       = "nucleus-plan`t1`ntxn`t$txn0`nmodstxt`tModA`ton`nmodstxt`tmoda`tremove`n"
        'bad owner'           = "nucleus-plan`t1`ntxn`t$txn0`nput`t1ModA`t$sha0`t1`t$A_LUA`n"
        'upper-case sha'      = "nucleus-plan`t1`ntxn`t$txn0`nput`tModA`t$($sha0.ToUpper())`t1`t$A_LUA`n"
        'size with sign'      = "nucleus-plan`t1`ntxn`t$txn0`nput`tModA`t$sha0`t+1`t$A_LUA`n"
        'size leading zero'   = "nucleus-plan`t1`ntxn`t$txn0`nput`tModA`t$sha0`t01`t$A_LUA`n"
        'sizes over 512 MiB'  = "nucleus-plan`t1`ntxn`t$txn0`nput`tModA`t$sha0`t300000000`t$A_LUA`nput`tModA`t$sha0`t300000000`t$A_BASE`n"
        'one target twice'    = "nucleus-plan`t1`ntxn`t$txn0`nput`tModA`t$sha0`t1`t$A_LUA`ndelete`tModA`t-`t$($A_LUA.ToUpper())`n"
        'a NUL byte'          = "nucleus-plan`t1`ntxn`t$txn0`nmodstxt`tModA`0`ton`n"
        'a lone CR'           = "nucleus-plan`t1`ntxn`t$txn0`rmodstxt`tModA`ton`n"
        'non-ASCII'           = "nucleus-plan`t1`ntxn`t$txn0`nmodstxt`tModÄ`ton`n"
        '1025 operations'     = "nucleus-plan`t1`ntxn`t$txn0`n" + ((1..1025 | ForEach-Object { "delete`tModA`t-`tNuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\f$_.lua" }) -join "`n") + "`n"
        'over 1 MiB'          = "nucleus-plan`t1`ntxn`t$txn0`nmodstxt`tModA`ton`n" + ('x' * (1024 * 1024))
    }
    foreach ($k in $badPlans.Keys) {
        StageRaw $badPlans[$k]
        $r = Apply
        Ok ((ResultOf 'outcome') -eq 'discarded' -and (ResultOf 'reason') -eq 'bad-plan' -and (Same $before (Snapshot)) -and -not (Staged)) "bad plan ($k): discarded bad-plan, nothing written" (Result)
    }
    # The limits themselves are accepted: 1024 operations.
    StageRaw ("nucleus-plan`t1`ntxn`t$txn0`n" + ((1..1024 | ForEach-Object { "delete`tModA`t-`tNuclearNightmare\Binaries\Win64\ue4ss\Mods\ModA\f$_.lua" }) -join "`r`n") + "`r`n")
    $r = Apply
    Ok ((ResultOf 'outcome') -eq 'applied') '1024 operations (CRLF lines) are accepted' (Result)
    cmd /c rmdir "`"$junction`"" | Out-Null

    # ================================================================ --fail-after: rolled back at every step
    Reset-Layout
    New-Item -ItemType Directory -Force (Split-Path (Join-Path $root $EXIST)) | Out-Null
    [IO.File]::WriteAllText((Join-Path $root $EXIST), 'old X')
    [IO.File]::WriteAllText((Join-Path $root $Y_BASE), 'pak Y')
    $before = Snapshot
    $modsBefore = [IO.File]::ReadAllBytes($modsTxt)
    $steps = @($planA) + @(@{ Op = 'put'; Owner = 'ModX'; Target = $EXIST; Text = 'new X' }, @{ Op = 'delete'; Owner = 'ModY'; Target = $Y_BASE })
    $allOk = $true; $detail = ''
    foreach ($n in 0..6) {
        $t = Stage $steps
        Remove-Item (Join-Path $data 'staged\attempts.txt') -ErrorAction SilentlyContinue
        $r = Apply "--fail-after $n"
        $same = Same $before (Snapshot)
        if (-not ((ResultOf 'outcome') -eq 'failed' -and (ResultOf 'reason') -eq 'io-error' -and $same -and (Staged) -and [Linq.Enumerable]::SequenceEqual($modsBefore, [IO.File]::ReadAllBytes($modsTxt)))) {
            $allOk = $false; $detail += "[n=$n $(ResultOf 'outcome')/$(ResultOf 'reason') $(Diff $before (Snapshot))] "
        }
    }
    Ok $allOk '--fail-after 0..6: every step rolled back byte-identically (files, folders, mods.txt), plan still staged' $detail

    # ================================================================ interrupted (--crash-after), then recovery
    foreach ($n in 1, 3, 5) {
        Reset-Layout
        New-Item -ItemType Directory -Force (Split-Path (Join-Path $root $EXIST)) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root $EXIST), 'old X')
        [IO.File]::WriteAllText((Join-Path $root $Y_BASE), 'pak Y')
        $before = Snapshot
        $t = Stage $steps
        $r = Apply "--crash-after $n"
        $journal = Text (Join-Path $data 'rollback\journal.txt')
        Ok ($r.Code -eq 9 -and $journal -and -not $journal.TrimEnd().EndsWith('done') -and -not (Same $before (Snapshot))) "crash after $n writes: the process ended mid-apply, the journal has no done" "exit $($r.Code)"
        Move-Item (Join-Path $data 'staged\plan.txt') (Join-Path $tmp 'plan.saved') -Force
        $r = Apply
        Ok ((Same $before (Snapshot)) -and -not (Test-Path (Join-Path $data 'rollback'))) "crash after $n writes: the next helper rolls everything back first (byte-identical)" (Diff $before (Snapshot))
        Move-Item (Join-Path $tmp 'plan.saved') (Join-Path $data 'staged\plan.txt') -Force
        $null = Apply "--crash-after $n"
        $r = Apply
        Ok ((ResultOf 'outcome') -eq 'applied' -and (ResultOf 'txn') -eq $t -and (Text (Join-Path $root $EXIST)) -ceq 'new X' -and -not (Test-Path (Join-Path $root $Y_BASE)) -and (Text (Join-Path $root $A_BASE)) -ceq 'base pak A') "crash after $n writes: recovery, then the plan applied" (Result)
    }
    # A journal whose last line was cut short (no newline): that step never began.
    Reset-Layout
    $before = Snapshot
    New-Item -ItemType Directory -Force (Join-Path $data 'rollback\files') | Out-Null
    [IO.File]::WriteAllText((Join-Path $data 'rollback\journal.txt'), "nucleus-journal`t1`ntxn`t$txn0`nabsent`t$A_BASE`nsav")
    [IO.File]::WriteAllText((Join-Path $root $A_BASE), 'half-written')
    $r = Apply
    Ok ((Same $before (Snapshot)) -and -not (Test-Path (Join-Path $data 'rollback'))) 'a torn last journal line is ignored; the earlier steps are rolled back' (Diff $before (Snapshot))
    # A journal naming a path outside the allowed targets: never acted on.
    [IO.File]::WriteAllText((Join-Path $win64 'keep.dll'), 'keep')
    New-Item -ItemType Directory -Force (Join-Path $data 'rollback') | Out-Null
    [IO.File]::WriteAllText((Join-Path $data 'rollback\journal.txt'), "nucleus-journal`t1`ntxn`t$txn0`nabsent`tNuclearNightmare\Binaries\Win64\keep.dll`n")
    $r = Apply
    Ok ((Text (Join-Path $win64 'keep.dll')) -eq 'keep' -and (ResultOf 'reason') -eq 'rollback-incomplete' -and (Test-Path (Join-Path $data 'rollback\journal.txt'))) 'a journal naming a path outside the targets: refused (rollback-incomplete), nothing touched' (Result)
    Remove-Item (Join-Path $data 'rollback') -Recurse -Force

    # ================================================================ another game exe under <root>
    Reset-Layout
    $gameExe = Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe'
    Copy-Item (Get-Command ping).Source $gameExe
    $game = Start-Process $gameExe -ArgumentList '-n', '100', '127.0.0.1' -WindowStyle Hidden -PassThru
    try {
        $before = Snapshot
        $txnG = Stage $planA
        $r = Apply
        Ok ((ResultOf 'outcome') -eq 'failed' -and (ResultOf 'reason') -eq 'game-running' -and (ResultOf 'attempts') -eq '0' -and (ResultOf 'txn') -eq $txnG) 'game running: failed, game-running, no attempt counted' (Result)
        Ok ($r.Sec -ge 60 -and $r.Sec -lt 90) "game running: waited about 60 s ($([math]::Round($r.Sec)) s)" $r.Sec
        Ok ((Staged) -and (Same $before (Snapshot)) -and -not (Test-Path (Join-Path $data 'staged\attempts.txt'))) 'game running: the plan stays, nothing written'
    } finally { Stop-Process -Id $game.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    $r = Apply
    Ok ((ResultOf 'outcome') -eq 'applied') 'game gone: the next helper applies it'
    Remove-Item $gameExe -Force

    # ================================================================ self-update (the shipped helper replaces the running test copy)
    Reset-Layout
    $selfExe = Join-Path $bin "$($name)Restart.exe"
    Copy-Item $TestExe $selfExe
    $selfRel = Rel $selfExe
    $newBytes = [IO.File]::ReadAllBytes($ShippedExe)
    $txnS = Stage @(@{ Op = 'put'; Owner = $name; Target = $selfRel; Bytes = $newBytes }, @{ Op = 'put'; Owner = $name; Target = $A_LUA; Text = 'with update' })
    $r = Apply -exe $selfExe -NoRoot
    $old = Join-Path $bin "$($name)Restart.$txnS.old"
    Ok ((ResultOf 'outcome') -eq 'applied' -and (Get-FileHash $selfExe).Hash -eq (Get-FileHash $ShippedExe).Hash) 'self-update: the helper image replaced (its own path, from its module path)' (Result)
    Ok ((Test-Path $old) -and (Get-FileHash $old).Hash -eq (Get-FileHash $TestExe).Hash) 'self-update: the running copy renamed to bin\<name>Restart.<txn>.old'
    $s = New-Sleeper 1
    $h = Start-Helper $selfExe "--wait $([int64]$s.Handle) --apply --mode none --cwd `"C:\a`" --exe `"C:\a\g.exe`" -- g.exe"
    $r = Wait-Helper $h
    [void][ApplyTest.Native]::CloseHandle($s.Handle)
    Ok ($r.Code -eq 0 -and -not (Test-Path $old)) 'self-update: a later helper (the new shipped one) deletes the .old' "exit $($r.Code)"
    # A self-update rolled back: the rename is put back.
    Copy-Item $TestExe $selfExe -Force
    New-Item -ItemType Directory -Force (Split-Path (Join-Path $root $EXIST)) | Out-Null
    [IO.File]::WriteAllText((Join-Path $root $EXIST), 'old X')
    $before = Snapshot
    $txnS = Stage @(@{ Op = 'put'; Owner = $name; Target = $selfRel; Bytes = $newBytes }, @{ Op = 'put'; Owner = 'ModX'; Target = $EXIST; Text = 'new X' })
    $fs = [IO.File]::Open((Join-Path $root $EXIST), 'Open', 'Read', 'Read')
    try { $r = Apply -exe $selfExe -NoRoot } finally { $fs.Dispose() }
    Ok ((ResultOf 'reason') -eq 'locked' -and (Same $before (Snapshot)) -and -not (Test-Path (Join-Path $bin "$($name)Restart.$txnS.old"))) 'self-update rolled back: the running copy back in place, no .old' (Diff $before (Snapshot))

    # ================================================================ relaunch.txt
    Reset-Layout
    function Relaunch-Case([string] $label, [scriptblock] $content, [string] $mode, [bool] $want) {
        Remove-Item $rec -ErrorAction SilentlyContinue
        $null = Stage @(@{ Op = 'put'; Owner = 'ModA'; Target = $A_LUA; Text = "x $label" })
        $s = New-Sleeper 3 -Query
        $h = Start-Helper $TestExe "--wait $([int64]$s.Handle) --apply --mode $mode --cwd `"C:\a b`" --exe `"C:\a b\g.exe`" --root `"$root`" --record `"$rec`" -- g.exe -userdir=`"C:\u`""
        [IO.File]::WriteAllText((Join-Path $data 'relaunch.txt'), (& $content $s.Process.Id $h.Process.Id))
        $r = Wait-Helper $h
        [void][ApplyTest.Native]::CloseHandle($s.Handle)
        $got = Text $rec
        $expect = if ($mode -eq 'steam') { "steam steam://rungameid/2909110`n" } else { "direct exe=C:\a b\g.exe cwd=C:\a b cmdline=g.exe -userdir=`"C:\u`"`n" }
        Ok ((ResultOf 'outcome') -eq 'applied' -and (($want -and $got -ceq $expect) -or (-not $want -and $null -eq $got)) -and -not (Test-Path (Join-Path $data 'relaunch.txt'))) "relaunch: $label" "[$got] $(Result)"
    }
    Relaunch-Case 'names the game and this helper -> relaunched (direct, the tail byte for byte), after the apply' { param($g, $hp) "nucleus-relaunch`t1`ngame`t$g`nhelper`t$hp`n" } 'direct' $true
    Relaunch-Case 'steam' { param($g, $hp) "nucleus-relaunch`t1`ngame`t$g`nhelper`t$hp`n" } 'steam' $true
    Relaunch-Case '--mode none -> never relaunched, file deleted' { param($g, $hp) "nucleus-relaunch`t1`ngame`t$g`nhelper`t$hp`n" } 'none' $false
    Relaunch-Case 'another helper -> not relaunched, file deleted' { param($g, $hp) "nucleus-relaunch`t1`ngame`t$g`nhelper`t$($hp + 4)`n" } 'direct' $false
    Relaunch-Case 'another game -> not relaunched' { param($g, $hp) "nucleus-relaunch`t1`ngame`t$($g + 4)`nhelper`t$hp`n" } 'direct' $false
    Relaunch-Case 'garbage -> not relaunched' { param($g, $hp) "relaunch please" } 'direct' $false
    # Relaunched even after a failed apply.
    Remove-Item $rec -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force (Split-Path (Join-Path $root $EXIST)) | Out-Null
    [IO.File]::WriteAllText((Join-Path $root $EXIST), 'old X')
    $null = Stage @(@{ Op = 'put'; Owner = 'ModX'; Target = $EXIST; Text = 'new X' })
    $fs = [IO.File]::Open((Join-Path $root $EXIST), 'Open', 'Read', 'Read')
    try {
        $s = New-Sleeper 3 -Query
        $h = Start-Helper $TestExe "--wait $([int64]$s.Handle) --apply --mode direct --cwd `"C:\a`" --exe `"C:\a\g.exe`" --root `"$root`" --record `"$rec`" -- g.exe"
        [IO.File]::WriteAllText((Join-Path $data 'relaunch.txt'), "nucleus-relaunch`t1`ngame`t$($s.Process.Id)`nhelper`t$($h.Process.Id)`n")
        $r = Wait-Helper $h
        [void][ApplyTest.Native]::CloseHandle($s.Handle)
    } finally { $fs.Dispose() }
    Ok ((ResultOf 'outcome') -eq 'failed' -and (Text $rec) -ceq "direct exe=C:\a\g.exe cwd=C:\a cmdline=g.exe`n") 'relaunch: also after a failed apply'

    # ================================================================ apply mode: no timeout; bad argv
    Reset-Layout
    $null = Stage $planA
    $s = New-Sleeper 4
    $h = Start-Helper $TestExe "--wait $([int64]$s.Handle) --apply --mode direct --cwd `"C:\a`" --exe `"C:\a\g.exe`" --root `"$root`" -- g.exe"
    $r = Wait-Helper $h
    [void][ApplyTest.Native]::CloseHandle($s.Handle)
    Ok ($r.Code -eq 0 -and $r.Sec -ge 4 -and (ResultOf 'outcome') -eq 'applied') "apply mode waits for the game however long ($([math]::Round($r.Sec, 1)) s)"
    $s = New-Sleeper 30
    $hh = [int64]$s.Handle
    $bad = [ordered]@{
        '--apply twice'               = "--wait $hh --apply --apply --mode direct --cwd `"C:\a`" --exe `"C:\a\g.exe`" --root `"$root`" -- g.exe"
        '--mode none without --apply' = "--wait $hh --mode none --cwd `"C:\a`" --exe `"C:\a\g.exe`" --record `"$rec`" -- g.exe"
        '--apply with --timeout-ms'   = "--wait $hh --apply --mode direct --cwd `"C:\a`" --exe `"C:\a\g.exe`" --root `"$root`" --timeout-ms 1000 -- g.exe"
        '--root without --apply'      = "--wait $hh --mode direct --cwd `"C:\a`" --exe `"C:\a\g.exe`" --root `"$root`" --record `"$rec`" -- g.exe"
        '--fail-after without --apply' = "--wait $hh --mode direct --cwd `"C:\a`" --exe `"C:\a\g.exe`" --fail-after 1 --record `"$rec`" -- g.exe"
        'relative --root'             = "--wait $hh --apply --mode direct --cwd `"C:\a`" --exe `"C:\a\g.exe`" --root rel -- g.exe"
        '--apply given a value'       = "--wait $hh --apply yes --mode direct --cwd `"C:\a`" --exe `"C:\a\g.exe`" --root `"$root`" -- g.exe"
        '--mode cmd'                  = "--wait $hh --apply --mode cmd --cwd `"C:\a`" --exe `"C:\a\g.exe`" --root `"$root`" -- g.exe"
        'no tail'                     = "--wait $hh --apply --mode none --cwd `"C:\a`" --exe `"C:\a\g.exe`" --root `"$root`""
    }
    $null = Stage $planA
    $before = Snapshot
    foreach ($k in $bad.Keys) {
        Remove-Item $rec -ErrorAction SilentlyContinue
        $r = Wait-Helper (Start-Helper $TestExe $bad[$k]) 15
        Ok ($r.Code -eq 2 -and -not (Test-Path $rec) -and (Staged) -and (Same $before (Snapshot))) "bad argv: $k -> exit 2, nothing applied or launched" "exit $($r.Code)"
    }
    foreach ($pair in @(@('--root', "--wait $hh --apply --mode none --cwd `"C:\a`" --exe `"C:\a\g.exe`" --root `"$root`" -- g.exe"),
                        @('--fail-after', "--wait $hh --apply --mode none --cwd `"C:\a`" --exe `"C:\a\g.exe`" --fail-after 1 -- g.exe"),
                        @('--crash-after', "--wait $hh --apply --mode none --cwd `"C:\a`" --exe `"C:\a\g.exe`" --crash-after 1 -- g.exe"))) {
        $r = Wait-Helper (Start-Helper $ShippedExe $pair[1]) 15
        Ok ($r.Code -eq 2) "shipped helper: $($pair[0]) -> exit 2" "exit $($r.Code)"
    }
    # The shipped helper outside the install layout applies nothing (exit 7).
    $r = Wait-Helper (Start-Helper $ShippedExe "--wait $hh --apply --mode none --cwd `"C:\a`" --exe `"C:\a\g.exe`" -- g.exe") 15
    Ok ($r.Code -eq 7 -and (Staged)) 'shipped helper outside Mods\<name>\bin\: exit 7, nothing applied' "exit $($r.Code)"
    [void][ApplyTest.Native]::CloseHandle($s.Handle)
    Stop-Process -Id $s.Process.Id -Force -ErrorAction SilentlyContinue
} finally {
    if (Test-Path $root) { cmd /c rmdir /s /q "`"$root`"" | Out-Null }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "apply.tests: $script:passed passed, $script:failed failed"
$code = if ($script:failed) { 1 } else { 0 }
if (-not $SkipRestartTests) {
    & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'restart-helper.tests.ps1') -TestExe $TestExe -ShippedExe $ShippedExe
    if ($LASTEXITCODE -ne 0) { $code = 1 }
}
exit $code
