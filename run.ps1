<#
.SYNOPSIS
  Runs one scenario end to end: deploy (with the test dependent), launch, serve key requests, wait, close, check.
.DESCRIPTION
  Launches only through the workspace's tools/launch.ps1 (which passes -userdir). Stops when the test dependent logs
  its END line, the game exits (crash), or -TimeoutSec runs out (hang); then closes the game, force-killing it
  (and any crash reporter) after 15 s. The test dependent writes "<seq> key ENTER" to its Scripts/request.txt for
  touchdown; this script posts the key to the game window's message queue (PostMessage WM_KEYDOWN/WM_KEYUP; no
  foreground change and no global input, so it works behind a dialog and never types into another program), then
  writes <seq> to done.txt.
  Keeps the log as <workspace>/dumps/<copy>/<name lowercase>/<scenario>.log (ignored by git) and runs check.ps1.
  Steam must be running. Don't type into the game while it runs.
.EXAMPLE
  ./run.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.1-build26172444 -Scenario skeleton
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [ValidateSet('skeleton', 'no-native', 'no-pak', 'bad-input', 'ui', 'soak')]
    [string] $Scenario = 'skeleton',
    [int] $TimeoutSec = 0  # 0: 420 s, 900 s for ui (it travels four times and waits for layout), 1000 s for soak (10 min idle)
)
$ErrorActionPreference = 'Stop'
if ($TimeoutSec -le 0) { $TimeoutSec = switch ($Scenario) { 'ui' { 900 } 'soak' { 1000 } default { 420 } } }
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
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);
'@

# Only the game this script started: the Shipping exe under this instance. Never the real install (the player may
# start it while a run is going), never another copy.
function Get-OurGame { Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($inst, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1 }
function Stop-Game {
    $p = Get-OurGame
    if ($p) { [void]$p.CloseMainWindow(); if (-not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force } }
    Get-Process -Name 'CrashReportClient*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($inst, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-OurGame) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
}
function Invoke-Request([string] $cmd) {
    if ($cmd -eq 'key ENTER') {
        # Posted to the game window's own message queue: no foreground change, no global keystroke, so it reaches the
        # game even behind another window or a system dialog, and can never type into another program.
        $p = Get-OurGame
        $h = if ($p) { $p.MainWindowHandle } else { [IntPtr]::Zero }
        if ($h -eq [IntPtr]::Zero) { Write-Host '  key skipped: no game window'; return }
        $down = [CoreRun.Win]::PostMessage($h, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001)            # WM_KEYDOWN, VK_RETURN, scan 0x1C
        Start-Sleep -Milliseconds 80
        $up = [CoreRun.Win]::PostMessage($h, 0x0101, [IntPtr]0x0D, [IntPtr]([int64]0xC01C0001))   # WM_KEYUP
        Write-Host ("  posted ENTER to the game window (down={0} up={1})" -f $down, $up)
    } else { Write-Host "  unknown request: $cmd" }
}

if (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue) { throw 'Nuclear Nightmare is already running (a dev copy or the real game); not launching.' }
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
        if (-not (Get-OurGame)) { $result = 'game exited (crash?)'; break }
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
