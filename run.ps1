<#
.SYNOPSIS
  Runs one scenario end to end: deploy (with the test dependent), launch, serve key requests, wait, close, check.
.DESCRIPTION
  Launches only through the workspace's tools/launch.ps1 (which passes -userdir). Stops when the test dependent logs
  its END line, the game exits (crash), or -TimeoutSec runs out (hang); then closes the game, force-killing it
  (and any crash reporter) after 15 s. The test dependent writes "<seq> key ENTER" to its Scripts/request.txt for
  touchdown; this script presses it only if the game window is in front, then writes <seq> to done.txt.
  Keeps the log as <workspace>/dumps/<copy>/<name lowercase>/<scenario>.log (ignored by git) and runs check.ps1.
  Steam must be running. Don't type into the game while it runs.
.EXAMPLE
  ./run.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.0-build26022182 -Scenario skeleton
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [ValidateSet('skeleton', 'no-native', 'no-pak', 'bad-input', 'ui')]
    [string] $Scenario = 'skeleton',
    [int] $TimeoutSec = 0  # 0: 420 s, or 900 s for ui (it travels four times and waits for layout)
)
$ErrorActionPreference = 'Stop'
if ($TimeoutSec -le 0) { $TimeoutSec = if ($Scenario -eq 'ui') { 900 } else { 420 } }
$here     = $PSScriptRoot
$name     = (Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json).name
$testName = "${name}SkelTest"
$inst     = (Resolve-Path $Instance).Path
$root     = Split-Path (Split-Path $inst)
$log      = Join-Path $inst 'NuclearNightmare\Binaries\Win64\ue4ss\UE4SS.log'
$scripts  = Join-Path $inst "NuclearNightmare\Binaries\Win64\ue4ss\Mods\$testName\Scripts"
$outDir   = Join-Path $root "dumps\$(Split-Path $inst -Leaf)\$($name.ToLowerInvariant())"
$exeName  = 'NuclearNightmare-Win64-Shipping'
New-Item -ItemType Directory -Force $outDir | Out-Null

Add-Type -Namespace CoreRun -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@

function Stop-Game {
    $p = Get-Process -Name $exeName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { [void]$p.CloseMainWindow(); if (-not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force } }
    Get-Process -Name 'CrashReportClient*' -ErrorAction SilentlyContinue | Stop-Process -Force
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Process -Name $exeName -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
}
function Get-GameWindow { (Get-Process -Name $exeName -ErrorAction SilentlyContinue | Select-Object -First 1).MainWindowHandle }
function Enter-Game {
    $h = Get-GameWindow
    if (-not $h -or $h -eq [IntPtr]::Zero) { return $false }
    [CoreRun.Win]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [CoreRun.Win]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero) # Alt tap lifts the foreground lock
    [void][CoreRun.Win]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 300
    return ([CoreRun.Win]::GetForegroundWindow() -eq $h)
}
function Invoke-Request([string] $cmd) {
    if ($cmd -eq 'key ENTER') {
        # Never type into another application.
        if (-not (Enter-Game)) { Write-Host '  key skipped: the game window is not in front'; return }
        [CoreRun.Win]::keybd_event(0x0D, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
        [CoreRun.Win]::keybd_event(0x0D, 0, 2, [UIntPtr]::Zero)
        Write-Host '  pressed ENTER'
    } else { Write-Host "  unknown request: $cmd" }
}

if (Get-Process -Name $exeName -ErrorAction SilentlyContinue) { throw 'Nuclear Nightmare is already running; close it first.' }
& (Join-Path $here 'deploy.ps1') -Instance $inst -Test -Scenario $Scenario
Remove-Item $log -ErrorAction SilentlyContinue
$sw = [Diagnostics.Stopwatch]::StartNew()
& (Join-Path $root 'tools\launch.ps1') -Instance $inst

$req = Join-Path $scripts 'request.txt'
$done = Join-Path $scripts 'done.txt'
$lastSeq = 0
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$result = 'timeout (hang?)'
Start-Sleep -Seconds 5
try {
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Name $exeName -ErrorAction SilentlyContinue)) { $result = 'game exited (crash?)'; break }
        if (Test-Path $req) {
            $text = Get-Content $req -Raw -ErrorAction SilentlyContinue
            if ($text -match '^(\d+) (.+)$' -and [int]$Matches[1] -gt $lastSeq) {
                $lastSeq = [int]$Matches[1]
                Write-Host ("[{0,5:N1}s] request {1}: {2}" -f $sw.Elapsed.TotalSeconds, $lastSeq, $Matches[2])
                Invoke-Request $Matches[2]
                Set-Content $done $lastSeq -NoNewline
            }
        }
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern "\[$testName\] END result=" -Quiet)) { $result = 'finished'; break }
        Start-Sleep -Milliseconds 250
    }
} finally {
    Write-Host ("Run {0} after {1:N0} s." -f $result, $sw.Elapsed.TotalSeconds)
    Start-Sleep -Seconds 2
    Stop-Game
}

$kept = Join-Path $outDir "$Scenario.log"
if (Test-Path $log) { Copy-Item $log $kept -Force } else { Write-Host "No UE4SS.log at $log" }
& (Join-Path $here 'check.ps1') -Log $kept -Scenario $Scenario
exit $LASTEXITCODE
