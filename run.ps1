<#
.SYNOPSIS
  Runs one scenario end to end: deploy (with the test dependent), launch, serve key requests, wait, close, check.
.DESCRIPTION
  Launches only through the workspace's tools/launch.ps1 (which passes -userdir). Stops when the test dependent logs
  its END line, the game exits (crash), or -TimeoutSec runs out (hang); then closes the game, force-killing it
  (and any crash reporter) after 15 s. The test dependent writes "<seq> key ENTER" (or "<seq> key <A-Z>", the journal
  scenario's map key) to its Scripts/request.txt for
  touchdown; this script posts the key to the game window's message queue (PostMessage WM_KEYDOWN/WM_KEYUP; no
  foreground change and no global input, so it works behind a dialog and never types into another program), then
  writes <seq> to done.txt. "<seq> click <x> <y>" (story 15: a button on the Journal) is a real mouse click at that
  desktop point, as mods/bp-spike/run.ps1 did: it brings the game window to the front and clicks only when it is in
  front (never into another program), so it takes the mouse for a moment. "<seq> shot <label>" is served only in the
  VM (a screenshot); on the host it is acknowledged and skipped. Story 21's menu scenario also asks for "key DOWN" and
  "key UP" (arrow keys, posted like Enter), "move <x> <y>" (the cursor to that desktop point, no click; a hover) and
  "wheel <x> <y> <notches>" (the cursor there, then that many mouse-wheel notches, negative = down, |n| at most 20);
  move and wheel bring the game window to the front first, like a click. Mod Manager story 4's slider adds
  "drag <x1> <y1> <x2> <y2>" (the left button down at the first point, ten moves to the second, up there; to the front
  first, like a click), "type <text>" (1-16 of 0-9 . , a-z -, each posted as WM_CHAR to the game window) and
  "key BACK", "key TAB", "key ESCAPE" (posted like Enter). Core story 27's window keys add "key LEFT" and "key RIGHT"
  (arrow keys, extended, like UP and DOWN). Core story 38 (a row dragged and held in steps) adds "press <x> <y>" (the
  left button down there, kept), "glide <x> <y>" (ten real moves there from where the cursor is, the buttons as they
  are), "release <x> <y>" (the left button up there), "rrelease <x> <y>" (a right press and release there while the left
  button is held; each to the front first, like a click) and "keydown <KEY>" / "keyup <KEY>" (only that half of a
  "key <KEY>" press, posted like it: a key held across other requests).
  Keeps the log as <workspace>/dumps/<copy>/<name lowercase>/<scenario>.log (ignored by git) and runs check.ps1.
  Refuses to start while another runner's test or driver mod is enabled in the copy (the workspace's tools/run-guard:
  the refusal names each and the command that clears it); -AllowOtherDrivers runs anyway.
  Steam must be running. Don't type into the game while it runs.
  -Target vm runs the scenario in the Hyper-V VM NNB instead (tools/vm/vm-sp.ps1, README "Tests in the VM"): the
  host's build/package and the test dependent go into the VM's copy of the same build (staged through
  deploy.ps1 -Staged), the VM's game is launched, Enter is pressed there with tools/vm/vm-key.ps1, and the VM copy is
  put back as it was afterwards. It never builds and never touches the host's game copy or a host game, so it can run
  while someone plays on the host. The log is kept as <scenario>.vm.log and judged with check.ps1 -Target vm. soak
  (timing) is host-only.
.EXAMPLE
  ./run.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Scenario skeleton
  ./run.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Scenario bad-input -Target vm
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [ValidateSet('skeleton', 'no-native', 'no-pak', 'bad-input', 'ui', 'journal', 'menu', 'createserver', 'gameinsert', 'nativerow', 'intercept', 'scope-host', 'soak')]
    [string] $Scenario = 'skeleton',
    [int] $TimeoutSec = 0, # 0: 420 s, 900 s for ui (it travels four times and waits for layout), menu (about 40 requests and three map loads), createserver (about 30 clicks, a hosted session, a minute in it), gameinsert (about 35 clicks, twelve opens) and nativerow (about 30 clicks, eleven opens, a hover), 1200 s for journal (24 key presses, a revive, a map change), 1000 s for soak (10 min idle); x1.5 in the VM
    [ValidateSet('host', 'vm')] [string] $Target = 'host',
    [switch] $AllowOtherDrivers # run even when another runner's test mod is enabled in the copy (tools/run-guard)
)
$ErrorActionPreference = 'Stop'
# Core story 43: intercept presses Ctrl+R, which only the VM run enables (Invoke-NNBSpRun -HotReload); never on the host.
if ($Scenario -eq 'intercept' -and $Target -ne 'vm') { Write-Host 'refused: the intercept scenario runs only in the VM (-Target vm): it needs UE4SS''s hot reload, which only the VM run turns on.'; exit 1 }
$hostTimeout = switch ($Scenario) { 'ui' { 900 } 'menu' { 900 } 'createserver' { 900 } 'gameinsert' { 900 } 'nativerow' { 900 } 'intercept' { 900 } 'journal' { 1200 } 'soak' { 1000 } default { 420 } }
if ($TimeoutSec -le 0 -and $Target -eq 'host') { $TimeoutSec = $hostTimeout }
$here     = $PSScriptRoot
$name     = (Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json).name
$testName = "${name}SkelTest"
$inst     = (Resolve-Path $Instance).Path
$root     = Split-Path (Split-Path $inst)
. (Join-Path $root 'tools\run-guard\run-guard.ps1')
$log      = Join-Path $inst 'NuclearNightmare\Binaries\Win64\ue4ss\UE4SS.log'
$scripts  = Join-Path $inst "NuclearNightmare\Binaries\Win64\ue4ss\Mods\$testName\Scripts"
$outDir   = Join-Path $root "dumps\$(Split-Path $inst -Leaf)\$($name.ToLowerInvariant())"
$exeName  = 'NuclearNightmare-Win64-Shipping'
New-Item -ItemType Directory -Force $outDir | Out-Null

if ($Target -eq 'vm') {
    . (Join-Path $root 'tools\vm\vm-sp.ps1')
    # Timing scenarios judge tick costs: valid only on the host, with the VM's game closed.
    Assert-NNBSpScenario -Scenario $Scenario -HostOnly 'soak'
    $kept = Join-Path $outDir "$Scenario.vm.log"
    Remove-Item $kept -ErrorAction SilentlyContinue
    # A refusal of the guard (the VM copy's mods.txt, in the stage) ends the run before anything is installed there.
    try {
        $run = Invoke-NNBSpRun -Instance $inst -TestMod $testName -Mods $name, $testName, "${name}SkelPeer", "${name}SkelNative" -Paks "$name.pak" `
            -EndPattern "\[$testName\] END result=" -TimeoutSec (Get-NNBSpTimeout $hostTimeout $TimeoutSec) -LogOut $kept -HotReload:($Scenario -eq 'intercept') -Prepare {
                param($stage)
                $refusal = Get-RunGuardRefusal -Workspace $root -Instance $stage -Owner $name -Bypass:$AllowOtherDrivers -Vm
                if ($refusal) { throw $refusal }
                & (Join-Path $here 'deploy.ps1') -Instance $stage -Test -Scenario $Scenario -Staged
            }
    } catch { if ("$($_.Exception.Message)".StartsWith('refused: ')) { Write-Host $_.Exception.Message; exit 1 }; throw }
    if (-not $run.Log) { Write-Host 'No UE4SS.log from the VM.'; exit 1 }
    & (Join-Path $here 'check.ps1') -Log $kept -Scenario $Scenario -Target vm
    exit $LASTEXITCODE
}

Add-Type -Namespace CoreRun -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, System.UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr v);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
public struct POINT { public int X; public int Y; }
'@
# Slate's absolute coordinates (the test's click points) are physical desktop pixels: see the same pixels.
[void][CoreRun.Win]::SetProcessDpiAwarenessContext([IntPtr](-4))

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
# The game window's handle once it is in front (brought there first), else zero (and why, on the console).
function Get-FrontGameWindow([string] $what) {
    $p = Get-OurGame
    $h = if ($p) { $p.MainWindowHandle } else { [IntPtr]::Zero }
    if ($h -eq [IntPtr]::Zero) { Write-Host "  $what skipped: no game window"; return [IntPtr]::Zero }
    if ([CoreRun.Win]::GetForegroundWindow() -ne $h) {
        [CoreRun.Win]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [CoreRun.Win]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero) # an Alt tap lifts the foreground lock
        [void][CoreRun.Win]::SetForegroundWindow($h)
        Start-Sleep -Milliseconds 300
    }
    if ([CoreRun.Win]::GetForegroundWindow() -ne $h) { Write-Host "  $what skipped: the game window is not in front"; return [IntPtr]::Zero }
    return $h
}
# The cursor to a desktop point on the game only (story 21's hover checks): no button.
function Invoke-Move([int] $x, [int] $y) {
    $h = Get-FrontGameWindow 'move'
    if ($h -eq [IntPtr]::Zero) { return }
    [void][CoreRun.Win]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 100
    [CoreRun.Win]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero); [CoreRun.Win]::mouse_event(0x0001, -1, 0, 0, [UIntPtr]::Zero) # a real move event
    Write-Host "  moved the cursor to ($x, $y)"
}
# Mouse-wheel notches over a desktop point on the game only (story 21's list): negative scrolls down.
function Invoke-Wheel([int] $x, [int] $y, [int] $notches) {
    $h = Get-FrontGameWindow 'wheel'
    if ($h -eq [IntPtr]::Zero) { return }
    [void][CoreRun.Win]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 150
    [CoreRun.Win]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero); [CoreRun.Win]::mouse_event(0x0001, -1, 0, 0, [UIntPtr]::Zero)
    $step = if ($notches -lt 0) { -120 } else { 120 }
    for ($i = 0; $i -lt [Math]::Abs($notches); $i++) {
        if ([CoreRun.Win]::GetForegroundWindow() -ne $h) { Write-Host '  wheel stopped: the game window lost the front'; return }
        [CoreRun.Win]::mouse_event(0x0800, 0, 0, [uint32][BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$step), 0), [UIntPtr]::Zero) # MOUSEEVENTF_WHEEL
        Start-Sleep -Milliseconds 80
    }
    Write-Host "  wheel $notches notch(es) at ($x, $y)"
}
# A real mouse click on the game only: the game window is brought to the front and clicked only when it is in front.
function Invoke-Click([int] $x, [int] $y) {
    $h = Get-FrontGameWindow 'click'
    if ($h -eq [IntPtr]::Zero) { return }
    [void][CoreRun.Win]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 150
    [CoreRun.Win]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero); [CoreRun.Win]::mouse_event(0x0001, -1, 0, 0, [UIntPtr]::Zero) # hover
    Start-Sleep -Milliseconds 150
    if ([CoreRun.Win]::GetForegroundWindow() -ne $h) { Write-Host '  click skipped: the game window lost the front'; return }
    [CoreRun.Win]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
    [CoreRun.Win]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Write-Host "  clicked at ($x, $y)"
}

# A drag on the game only (Mod Manager story 4's slider): the button down at the start, ten real moves, up at the end.
function Invoke-Drag([int] $x, [int] $y, [int] $x2, [int] $y2) {
    $h = Get-FrontGameWindow 'drag'
    if ($h -eq [IntPtr]::Zero) { return }
    [void][CoreRun.Win]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 150
    [CoreRun.Win]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero); [CoreRun.Win]::mouse_event(0x0001, -1, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 150
    if ([CoreRun.Win]::GetForegroundWindow() -ne $h) { Write-Host '  drag skipped: the game window lost the front'; return }
    [CoreRun.Win]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 120
    for ($i = 1; $i -le 10; $i++) {
        [void][CoreRun.Win]::SetCursorPos([int][Math]::Round($x + ($x2 - $x) * $i / 10), [int][Math]::Round($y + ($y2 - $y) * $i / 10))
        [CoreRun.Win]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero); [CoreRun.Win]::mouse_event(0x0001, -1, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 40
    }
    Start-Sleep -Milliseconds 120
    [CoreRun.Win]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Write-Host "  dragged ($x, $y) -> ($x2, $y2)"
}

# Core story 38: one step of a drag on the game only (to the front first, like a click): Press (the left button down at
# the point, kept), Glide (ten real moves there from where the cursor is), Release (the left button up there), RRelease
# (a right press and release there while the left button is held).
function Invoke-Step([string] $mode, [int] $x, [int] $y) {
    $h = Get-FrontGameWindow $mode.ToLowerInvariant()
    if ($h -eq [IntPtr]::Zero) { return }
    if ($mode -eq 'Glide') {
        $from = New-Object CoreRun.Win+POINT
        [void][CoreRun.Win]::GetCursorPos([ref]$from)
        for ($i = 1; $i -le 10; $i++) {
            [void][CoreRun.Win]::SetCursorPos([int][Math]::Round($from.X + ($x - $from.X) * $i / 10), [int][Math]::Round($from.Y + ($y - $from.Y) * $i / 10))
            [CoreRun.Win]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero); [CoreRun.Win]::mouse_event(0x0001, -1, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 40
        }
        Write-Host "  glided ($($from.X), $($from.Y)) -> ($x, $y)"
        return
    }
    [void][CoreRun.Win]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 150
    [CoreRun.Win]::mouse_event(0x0001, 1, 0, 0, [UIntPtr]::Zero); [CoreRun.Win]::mouse_event(0x0001, -1, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 150
    if ([CoreRun.Win]::GetForegroundWindow() -ne $h) { Write-Host "  $mode skipped: the game window lost the front"; return }
    switch ($mode) {
        'Press' { [CoreRun.Win]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero); $script:leftHeld = $true }
        'Release' { [CoreRun.Win]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero); $script:leftHeld = $false }
        'RRelease' { [CoreRun.Win]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80; [CoreRun.Win]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero) }
    }
    Write-Host "  $mode at ($x, $y)"
}

function Invoke-Request([string] $cmd) {
    # 'key ENTER' (touchdown), 'key <A-Z>' (the journal scenario's map key), 'key UP' / 'key DOWN', 'click <x> <y>'
    # (story 15), 'move <x> <y>' and 'wheel <x> <y> <notches>' (story 21), 'drag <x1> <y1> <x2> <y2>', 'type <text>' and
    # 'key BACK' / 'key TAB' / 'key ESCAPE' (Mod Manager story 4), 'shot <label>' (VM only); anything else is ignored.
    if ($cmd -cmatch '^click (\d{1,5}) (\d{1,5})$') {
        $x = [int]$Matches[1]; $y = [int]$Matches[2]
        if ($x -le 16383 -and $y -le 16383) { Invoke-Click $x $y } else { Write-Host "  click skipped: ($x, $y) out of range" }
        return
    }
    if ($cmd -cmatch '^move (\d{1,5}) (\d{1,5})$') {
        $x = [int]$Matches[1]; $y = [int]$Matches[2]
        if ($x -le 16383 -and $y -le 16383) { Invoke-Move $x $y } else { Write-Host "  move skipped: ($x, $y) out of range" }
        return
    }
    if ($cmd -cmatch '^wheel (\d{1,5}) (\d{1,5}) (-?\d{1,2})$') {
        $x = [int]$Matches[1]; $y = [int]$Matches[2]; $n = [int]$Matches[3]
        if ($x -le 16383 -and $y -le 16383 -and $n -ne 0 -and [Math]::Abs($n) -le 20) { Invoke-Wheel $x $y $n } else { Write-Host "  wheel skipped: ($x, $y) or $n notches out of range" }
        return
    }
    if ($cmd -cmatch '^(press|glide|release|rrelease) (\d{1,5}) (\d{1,5})$') { # core story 38
        $mode = @{ press = 'Press'; glide = 'Glide'; release = 'Release'; rrelease = 'RRelease' }[$Matches[1]]
        $x = [int]$Matches[2]; $y = [int]$Matches[3]
        if ($x -le 16383 -and $y -le 16383) { Invoke-Step $mode $x $y } else { Write-Host "  $($Matches[1]) skipped: ($x, $y) out of range" }
        return
    }
    if ($cmd -cmatch '^drag (\d{1,5}) (\d{1,5}) (\d{1,5}) (\d{1,5})$') {
        $p = 1..4 | ForEach-Object { [int]$Matches[$_] }
        if (-not ($p | Where-Object { $_ -gt 16383 })) { Invoke-Drag $p[0] $p[1] $p[2] $p[3] } else { Write-Host "  drag skipped: a point out of range" }
        return
    }
    if ($cmd -cmatch '^type ([0-9.,a-z-]{1,16})$') {
        $text = $Matches[1]
        $g = Get-OurGame
        $hw = if ($g) { $g.MainWindowHandle } else { [IntPtr]::Zero }
        if ($hw -eq [IntPtr]::Zero) { Write-Host '  type skipped: no game window'; return }
        foreach ($c in $text.ToCharArray()) { [void][CoreRun.Win]::PostMessage($hw, 0x0102, [IntPtr][int]$c, [IntPtr]1); Start-Sleep -Milliseconds 30 } # WM_CHAR
        Write-Host "  typed '$text' into the game window"
        return
    }
    if ($cmd -cmatch '^shot [A-Za-z0-9._-]{1,40}$') { Write-Host "  $cmd skipped (screenshots only in the VM)"; return }
    $vk, $scan, $label = $null, $null, $null
    $ext = 0
    # Core story 38: "keydown <KEY>" / "keyup <KEY>" post only that half of "key <KEY>".
    $half = 0
    if ($cmd -cmatch '^key(down|up) ([A-Z]+)$') { $half = if ($Matches[1] -ceq 'down') { 1 } else { 2 }; $cmd = 'key ' + $Matches[2] }
    if ($cmd -ceq 'key ENTER') { $vk, $scan, $label = 0x0D, 0x1C, 'ENTER' }
    elseif ($cmd -ceq 'key UP') { $vk, $scan, $label, $ext = 0x26, 0x48, 'UP', 1 }      # arrow keys are extended keys
    elseif ($cmd -ceq 'key DOWN') { $vk, $scan, $label, $ext = 0x28, 0x50, 'DOWN', 1 }
    elseif ($cmd -ceq 'key LEFT') { $vk, $scan, $label, $ext = 0x25, 0x4B, 'LEFT', 1 }    # core story 27: window navigation
    elseif ($cmd -ceq 'key RIGHT') { $vk, $scan, $label, $ext = 0x27, 0x4D, 'RIGHT', 1 }
    elseif ($cmd -ceq 'key BACK') { $vk, $scan, $label = 0x08, 0x0E, 'BACK' }     # Mod Manager story 4: the slider box
    elseif ($cmd -ceq 'key TAB') { $vk, $scan, $label = 0x09, 0x0F, 'TAB' }
    elseif ($cmd -ceq 'key ESCAPE') { $vk, $scan, $label = 0x1B, 0x01, 'ESCAPE' }
    elseif ($cmd -cmatch '^key ([A-Z])$') {
        $letter = $Matches[1]
        # Set-1 scan codes of a US layout; the virtual key of a letter is its ASCII code.
        $scans = @{ Q = 0x10; W = 0x11; E = 0x12; R = 0x13; T = 0x14; Y = 0x15; U = 0x16; I = 0x17; O = 0x18; P = 0x19
            A = 0x1E; S = 0x1F; D = 0x20; F = 0x21; G = 0x22; H = 0x23; J = 0x24; K = 0x25; L = 0x26
            Z = 0x2C; X = 0x2D; C = 0x2E; V = 0x2F; B = 0x30; N = 0x31; M = 0x32 }
        $vk, $scan, $label = [int][char]$letter, $scans[$letter], $letter
    }
    if ($null -eq $vk) { Write-Host "  unknown request: $cmd"; return }
    # Posted to the game window's own message queue: no foreground change, no global keystroke, so it reaches the
    # game even behind another window or a system dialog, and can never type into another program.
    $p = Get-OurGame
    $h = if ($p) { $p.MainWindowHandle } else { [IntPtr]::Zero }
    if ($h -eq [IntPtr]::Zero) { Write-Host '  key skipped: no game window'; return }
    $e = [int64]$ext -shl 24
    if ($half -eq 1) {
        $down = [CoreRun.Win]::PostMessage($h, 0x0100, [IntPtr]$vk, [IntPtr](1 -bor ($scan -shl 16) -bor $e))
        Write-Host ("  posted {0} down only to the game window ({1})" -f $label, $down); return
    }
    if ($half -eq 2) {
        $up = [CoreRun.Win]::PostMessage($h, 0x0101, [IntPtr]$vk, [IntPtr]([int64]0xC0000001 -bor ([int64]$scan -shl 16) -bor $e))
        Write-Host ("  posted {0} up only to the game window ({1})" -f $label, $up); return
    }
    $down = [CoreRun.Win]::PostMessage($h, 0x0100, [IntPtr]$vk, [IntPtr](1 -bor ($scan -shl 16) -bor $e))                         # WM_KEYDOWN
    Start-Sleep -Milliseconds 80
    $up = [CoreRun.Win]::PostMessage($h, 0x0101, [IntPtr]$vk, [IntPtr]([int64]0xC0000001 -bor ([int64]$scan -shl 16) -bor $e))    # WM_KEYUP
    Write-Host ("  posted {0} to the game window (down={1} up={2})" -f $label, $down, $up)
}

# A test mod another runner left enabled would fail this run in confusing ways.
$refusal = Get-RunGuardRefusal -Workspace $root -Instance $inst -Owner $name -Bypass:$AllowOtherDrivers
if ($refusal) { Write-Host $refusal; exit 1 }
if (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue) { throw 'Nuclear Nightmare is already running (a dev copy or the real game); not launching.' }
& (Join-Path $here 'deploy.ps1') -Instance $inst -Test -Scenario $Scenario
Remove-Item $log -ErrorAction SilentlyContinue
$sw = [Diagnostics.Stopwatch]::StartNew()
& (Join-Path $root 'tools\launch.ps1') -Instance $inst

$req = Join-Path $scripts 'request.txt'
$done = Join-Path $scripts 'done.txt'
$lastSeq = 0
$script:leftHeld = $false # core story 38: a 'press' not yet released
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
    # core story 38: a run that ends between a press and its release lets go of the left button
    if ($script:leftHeld) { [CoreRun.Win]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero); $script:leftHeld = $false; Write-Host '  left button released at the end of the run' }
    Write-Host ("Run {0} after {1:N0} s." -f $result, $sw.Elapsed.TotalSeconds)
    Start-Sleep -Seconds 2
    Stop-Game
}

$kept = Join-Path $outDir "$Scenario.log"
if (Test-Path $log) { Copy-Item $log $kept -Force } else { Write-Host "No UE4SS.log at $log" }
# -Instance too: bad-input reads the test dependent's settings.json back from the copy (Mod Manager story 5).
& (Join-Path $here 'check.ps1') -Log $kept -Scenario $Scenario -Instance $inst
exit $LASTEXITCODE
