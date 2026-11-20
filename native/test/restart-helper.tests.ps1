<#
.SYNOPSIS
  Tests core's relaunch helper (core story 45, Mod Manager story 8) without launching any game or Steam.
.DESCRIPTION
  Drives the test build build/native-out/test/<name>RestartTest.exe (CORE_RESTART_TEST: --record writes what it would
  launch to a file instead, --timeout-ms shortens the 120 s wait, --probe-mode prints the restart rule's answer), which
  build.ps1's native step makes; the shipped build/native-out/bin/<name>Restart.exe is only given bad arguments.
    - direct: waits for a sleeping child (pwsh -NoProfile -c Start-Sleep 3, a SYNCHRONIZE handle it inherits, as core's
      DLL gives it the game's) and records exe, cwd and the exact tail, byte for byte, with paths that have spaces,
      -userdir="C:\a b\_userdir", doubled and trailing spaces; it returns only after the child exited
    - steam: records steam://rungameid/2909110
    - the timeout: a child that outlives --timeout-ms 1000 -> exit 3, nothing recorded
    - bad argv (unknown, missing, repeated, malformed, out of range, not a handle) -> non-zero, nothing recorded
    - --probe-mode over temp layouts: manifest -> steam, steam_appid.txt -> direct, both -> steam, neither -> none,
      an exe outside <root>\NuclearNightmare\Binaries\Win64 -> direct or none
    - the shipped helper refuses the test-only options and bad argv (exit 2), and so launches nothing
.EXAMPLE
  pwsh -NoProfile -File native/test/restart-helper.tests.ps1
#>
param([string] $TestExe, [string] $ShippedExe)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$name = (Get-Content (Join-Path $repo 'mod.json') -Raw | ConvertFrom-Json).name
if (-not $TestExe) { $TestExe = Join-Path $repo "build\native-out\test\$($name)RestartTest.exe" }
if (-not $ShippedExe) { $ShippedExe = Join-Path $repo "build\native-out\bin\$($name)Restart.exe" }
foreach ($f in $TestExe, $ShippedExe) { if (-not (Test-Path -LiteralPath $f)) { Write-Host "FAIL: $f not found; run build.ps1 -Steps native first"; exit 1 } }

Add-Type -Namespace RestartTest -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern System.IntPtr OpenProcess(uint access, bool inherit, int pid);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(System.IntPtr h);
'@
$SYNCHRONIZE = 0x00100000

$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $label, $detail) {
    if ($cond) { $script:passed++; Write-Host "ok:   $label" } else { $script:failed++; Write-Host "FAIL: $label$(if ($null -ne $detail) { " -- $detail" })" }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) "$name-restart-$PID"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force $tmp | Out-Null
$rec = Join-Path $tmp 'record.txt'

# Starts exe with a raw argument string (the command line is "<exe>" <args>, nothing re-quoted). .NET's CreateProcess
# inherits every inheritable handle, so a handle opened with inherit = true reaches the helper. Returns exit code and
# elapsed seconds; -1 when it did not exit within $limitSec.
function Invoke-Helper([string] $exe, [string] $argStr, [int] $limitSec = 30) {
    $psi = [Diagnostics.ProcessStartInfo]::new($exe)
    $psi.Arguments = $argStr
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($limitSec * 1000)) { $p.Kill(); return [pscustomobject]@{ Code = -1; Sec = $sw.Elapsed.TotalSeconds; Out = '' } }
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Sec = $sw.Elapsed.TotalSeconds; Out = $out.Result }
}
# A sleeping child and an inheritable SYNCHRONIZE handle to it.
function New-Sleeper([int] $sec) {
    $p = Start-Process pwsh -ArgumentList '-NoProfile', '-c', "Start-Sleep $sec" -WindowStyle Hidden -PassThru
    $h = [RestartTest.Native]::OpenProcess($SYNCHRONIZE, $true, $p.Id)
    if ($h -eq [IntPtr]::Zero) { throw "OpenProcess($($p.Id)) failed" }
    [pscustomobject]@{ Process = $p; Handle = $h }
}
function Read-Record { if (Test-Path -LiteralPath $rec) { [IO.File]::ReadAllText($rec, [Text.UTF8Encoding]::new($false)) } else { $null } }

try {
    # ---- direct: waits, then records the tail byte for byte
    $tail = '"C:\x y\NuclearNightmare-Win64-Shipping.exe"  -userdir="C:\a b\_userdir" -windowed -ResX=1280   +connect_lobby 1 '
    $s = New-Sleeper 3
    Remove-Item $rec -ErrorAction SilentlyContinue
    $r = Invoke-Helper $TestExe "--wait $([int64]$s.Handle) --mode direct --cwd `"C:\a b\Win64`" --exe `"C:\x y\NuclearNightmare-Win64-Shipping.exe`" --record `"$rec`" -- $tail"
    $childGone = $s.Process.HasExited
    [void][RestartTest.Native]::CloseHandle($s.Handle)
    Ok ($r.Code -eq 0) 'direct: exit 0' $r.Code
    Ok ($childGone -and $r.Sec -ge 2) "direct: returned only after the child exited ($([math]::Round($r.Sec, 1)) s)" $r.Sec
    $want = "direct exe=C:\x y\NuclearNightmare-Win64-Shipping.exe cwd=C:\a b\Win64 cmdline=$tail`n"
    $got = Read-Record
    Ok ($got -ceq $want) 'direct: the record holds exe, cwd and the tail byte for byte (spaces in paths, -userdir="C:\a b\_userdir", doubled and trailing spaces)' "got [$got]"

    # ---- a cwd at a drive root (trailing backslash inside quotes)
    $s = New-Sleeper 1
    Remove-Item $rec -ErrorAction SilentlyContinue
    $r = Invoke-Helper $TestExe "--wait $([int64]$s.Handle) --mode direct --cwd `"C:\`" --exe `"C:\g.exe`" --record `"$rec`" -- g.exe -a"
    [void][RestartTest.Native]::CloseHandle($s.Handle)
    Ok ($r.Code -eq 0 -and (Read-Record) -ceq "direct exe=C:\g.exe cwd=C:\ cmdline=g.exe -a`n") 'direct: a drive-root cwd ("C:\")' "exit $($r.Code), [$(Read-Record)]"

    # ---- steam: records the URL
    $s = New-Sleeper 1
    Remove-Item $rec -ErrorAction SilentlyContinue
    $r = Invoke-Helper $TestExe "--wait $([int64]$s.Handle) --mode steam --cwd `"C:\a b`" --exe `"C:\x y\g.exe`" --record `"$rec`" -- `"C:\x y\g.exe`" -userdir=x"
    [void][RestartTest.Native]::CloseHandle($s.Handle)
    Ok ($r.Code -eq 0 -and (Read-Record) -ceq "steam steam://rungameid/2909110`n") 'steam: records steam://rungameid/2909110' "exit $($r.Code), [$(Read-Record)]"

    # ---- the timeout: the child outlives it; nothing recorded
    $s = New-Sleeper 15
    Remove-Item $rec -ErrorAction SilentlyContinue
    $r = Invoke-Helper $TestExe "--wait $([int64]$s.Handle) --mode direct --cwd `"C:\a`" --exe `"C:\a\g.exe`" --record `"$rec`" --timeout-ms 1000 -- g.exe"
    $alive = -not $s.Process.HasExited
    [void][RestartTest.Native]::CloseHandle($s.Handle)
    Stop-Process -Id $s.Process.Id -Force -ErrorAction SilentlyContinue
    Ok ($r.Code -eq 3 -and $alive -and $r.Sec -lt 10 -and -not (Test-Path $rec)) "timeout: exit 3 after about 1 s, the child still running, nothing recorded ($([math]::Round($r.Sec, 1)) s)" "exit $($r.Code)"

    # ---- bad argv: non-zero, nothing recorded (each with a live handle where one is needed)
    $s = New-Sleeper 30
    $h = [int64]$s.Handle
    $ok = "--mode direct --cwd `"C:\a`" --exe `"C:\a\g.exe`" --record `"$rec`""
    $bad = [ordered]@{
        'no arguments'            = ''
        'unknown option'          = "--wait $h $ok --foo x -- g.exe"
        'no --wait'               = "$ok -- g.exe"
        'no --mode'               = "--wait $h --cwd `"C:\a`" --exe `"C:\a\g.exe`" --record `"$rec`" -- g.exe"
        'mode cmd'                = "--wait $h --mode cmd --cwd `"C:\a`" --exe `"C:\a\g.exe`" --record `"$rec`" -- g.exe"
        'no --cwd'                = "--wait $h --mode direct --exe `"C:\a\g.exe`" --record `"$rec`" -- g.exe"
        'no --exe'                = "--wait $h --mode direct --cwd `"C:\a`" --record `"$rec`" -- g.exe"
        'no tail'                 = "--wait $h $ok"
        'empty tail'              = "--wait $h $ok -- "
        'repeated --mode'         = "--wait $h --mode direct $ok -- g.exe"
        'relative cwd'            = "--wait $h --mode direct --cwd `"a b`" --exe `"C:\a\g.exe`" --record `"$rec`" -- g.exe"
        'relative exe'            = "--wait $h --mode direct --cwd `"C:\a`" --exe g.exe --record `"$rec`" -- g.exe"
        'unterminated quote'      = "--wait $h --mode direct --cwd `"C:\a --exe `"C:\a\g.exe`" --record `"$rec`" -- g.exe"
        'quote inside a token'    = "--wait $h --mode direct --cwd C:\a`"b`" --exe `"C:\a\g.exe`" --record `"$rec`" -- g.exe"
        'quoted option name'      = "`"--wait`" $h $ok -- g.exe"
        'option without value'    = "--wait $h $ok --mode"
        'wait not a number'       = "--wait x1 $ok -- g.exe"
        'wait 0'                  = "--wait 0 $ok -- g.exe"
        'wait oversized'          = "--wait 99999999999999999999 $ok -- g.exe"
        'wait not a handle'       = "--wait 999996 $ok -- g.exe"
        'timeout oversized'       = "--wait $h $ok --timeout-ms 600001 -- g.exe"
        'probe with other args'   = "--probe-mode `"C:\a\g.exe`" --wait $h -- g.exe"
        'oversized cwd'           = "--wait $h --mode direct --cwd `"C:\$('a' * 32760)`" --exe `"C:\a\g.exe`" -- g.exe"
    }
    foreach ($k in $bad.Keys) {
        Remove-Item $rec -ErrorAction SilentlyContinue
        $r = $null
        try { $r = Invoke-Helper $TestExe $bad[$k] 15 } catch { $r = [pscustomobject]@{ Code = 'start refused'; Sec = 0 } }
        # (an oversized command line is refused by Windows itself before the helper runs: also nothing launched)
        Ok ($r.Code -ne 0 -and $r.Code -ne -1 -and -not (Test-Path $rec)) "bad argv: $k -> non-zero, nothing recorded" "exit $($r.Code)"
    }
    [void][RestartTest.Native]::CloseHandle($s.Handle)
    Stop-Process -Id $s.Process.Id -Force -ErrorAction SilentlyContinue

    # ---- --probe-mode over temp layouts
    function Layout([string] $label, [bool] $manifest, [bool] $appid, [switch] $Flat) {
        $root = Join-Path $tmp "probe-$label\steamapps\common\Nuclear Nightmare"
        $win64 = if ($Flat) { Join-Path $root 'Game\Bin' } else { Join-Path $root 'NuclearNightmare\Binaries\Win64' }
        New-Item -ItemType Directory -Force $win64 | Out-Null
        if ($manifest) { Set-Content (Join-Path $tmp "probe-$label\steamapps\appmanifest_2909110.acf") '"AppState" { }' }
        if ($appid) { Set-Content (Join-Path $win64 'steam_appid.txt') '2909110' -NoNewline }
        Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe'
    }
    $cases = @(
        @{ L = 'manifest'; M = $true; A = $false; Want = 'steam' }
        @{ L = 'appid'; M = $false; A = $true; Want = 'direct' }
        @{ L = 'both'; M = $true; A = $true; Want = 'steam' }
        @{ L = 'neither'; M = $false; A = $false; Want = 'none' }
        @{ L = 'flat-manifest'; M = $true; A = $false; Want = 'none'; Flat = $true }
        @{ L = 'flat-both'; M = $true; A = $true; Want = 'direct'; Flat = $true }
    )
    foreach ($c in $cases) {
        $exe = Layout $c.L $c.M $c.A -Flat:([bool]$c.Flat)
        $r = Invoke-Helper $TestExe "--probe-mode `"$exe`""
        Ok ($r.Code -eq 0 -and $r.Out.Trim() -ceq $c.Want) "probe: $($c.L) -> $($c.Want)" "exit $($r.Code), '$($r.Out.Trim())'"
    }

    # ---- the shipped helper: no test options, bad argv refused (exit 2); it never got anything it could launch
    $s = New-Sleeper 30
    $h = [int64]$s.Handle
    foreach ($pair in @(
            @('probe-mode', "--probe-mode `"C:\a\g.exe`""),
            @('record', "--wait $h --mode direct --cwd `"C:\a`" --exe `"C:\a\g.exe`" --record `"$rec`" -- g.exe"),
            @('timeout-ms', "--wait $h --mode direct --cwd `"C:\a`" --exe `"C:\a\g.exe`" --timeout-ms 1000 -- g.exe"),
            @('no tail', "--wait $h --mode steam --cwd `"C:\a`" --exe `"C:\a\g.exe`""),
            # (direct with an exe that doesn't exist: even a handle that happened to be valid could launch nothing)
            @('not a handle', "--wait 999996 --mode direct --cwd `"C:\a`" --exe `"C:\$name-no-such-dir\g.exe`" -- g.exe"))) {
        $r = Invoke-Helper $ShippedExe $pair[1] 15
        Ok ($r.Code -eq 2) "shipped helper: $($pair[0]) -> exit 2" "exit $($r.Code)"
    }
    [void][RestartTest.Native]::CloseHandle($s.Handle)
    Stop-Process -Id $s.Process.Id -Force -ErrorAction SilentlyContinue
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "restart-helper.tests: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
