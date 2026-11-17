<#
.SYNOPSIS
  Judges one run of core from UE4SS.log.
.DESCRIPTION
  Prints core's, the test dependent's and UE4SS's relevant lines, then checks the patterns the scenario needs.
  A pattern must match somewhere; "!pattern" must match nowhere; "#N|pattern" must match exactly N lines;
  "?pattern" is a soft check: reported as "warn:" when it does not match, without failing the run; "?!pattern" is a soft
  check that it matches nowhere.
  Exit code 1 when any check fails; otherwise prints "All checks passed."
  Core's name, the test dependent's name (<name>SkelTest) and the version come from mod.json.
.EXAMPLE
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.1.2-build26193463\nucleus\skeleton.log -Scenario skeleton
  ./check.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Scenario bad-input
  ./check.ps1 -Log C:\...\my-hand-test.log -Scenario manual
  ./check.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463 -Scenario ui
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.1.2-build26193463\nucleus\ui.vm.log -Scenario ui -Target vm
.NOTES
  -Target vm (a log from run.ps1 -Target vm): the VM's game shares the CPU with the host, so the one timing assertion
  inside a functional scenario, ui's "no steady-state hud tick over 1 ms" (hud slow tick ... steady state), is a soft
  check there; soak judges only timing and is refused.
#>
param(
    [string] $Instance,
    [string] $Log,
    [ValidateSet('skeleton', 'no-native', 'no-pak', 'bad-input', 'ui', 'journal', 'menu', 'createserver', 'gameinsert', 'soak', 'manual', 'net-host', 'net-client', 'net-vanilla-host',
                 'presence-host', 'presence-client', 'presence-vanilla-host')]
    [string] $Scenario = 'skeleton',
    [ValidateSet('host', 'vm')] [string] $Target = 'host'
)
if ($Target -eq 'vm' -and $Scenario -eq 'soak') { Write-Host 'FAIL: soak judges tick timing and is valid only on the host (run.ps1 without -Target vm).'; exit 1 }
# Timing inside functional scenarios: hard on the host, soft in the VM (its game shares the CPU with the host's).
$hard = if ($Target -eq 'vm') { '?!' } else { '!' }
$slowWarnOk = if ($Target -eq 'vm') { 'hud slow tick ' } else { 'hud slow tick .*(; HUD event: |steady state, a Lua GC step ran inside it)' }
$manifest = Get-Content (Join-Path $PSScriptRoot 'mod.json') -Raw | ConvertFrom-Json
$name = $manifest.name
$version = $manifest.version
$t = "${name}SkelTest"
$N = [regex]::Escape($name); $T = [regex]::Escape($t); $Ver = [regex]::Escape($version)
$Floor = [regex]::Escape("$($manifest.compat.floor)")   # story 18: core's compatibility floor, in its READY line
$Peer = [regex]::Escape("${name}SkelPeer")   # story 15's second test dependent (scenario ui)
if (-not $Log) { $Log = Join-Path (Resolve-Path $Instance) 'NuclearNightmare\Binaries\Win64\ue4ss\UE4SS.log' }
if (-not (Test-Path $Log)) { Write-Host "FAIL: no log at $Log"; exit 1 }

$lines = @(Get-Content $Log)
Write-Host "--- $name lines ($Scenario) ---"
$lines | Where-Object {
    $_ -match "\[$N\]|\[$T\]|$N|BPModLoaderMod\] Loading mod: $N" -or
    $_ -match 'Error executing script|threw an exception|removing hook|Unhandled Exception|Failed to load dll|stack traceback|\[script_hook\]'
} | ForEach-Object { $_ -replace '^\[[^\]]+\]\s*', '' -replace '^\[Lua\]\s*', '' }

# No scenario may show an error escaping into UE4SS (a Lua error UE4SS caught and printed with a traceback, a hook
# callback that threw), an SEH fault or C++ exception inside core's natives, or a channel request failing inside core.
$always = @(
    '!Unhandled Exception'
    '!Error executing script'
    '!removing hook'
    '!stack traceback'
    '!\[script_hook\]'
    "!\[$N\] WARN feature list unavailable"   # story 18: the READY line must list the features
    "!\[$N\] native: FAULT"
    "!\[$N\] native: ERROR"
    "!internal error"
    "!\[$N\] WARN CHANNEL request failed"
    "!\[$T\] .*STEP '.*' threw"
    # UE4SS calling a registry value that is not the callback it queued (the cross-thread ExecuteInGameThread race,
    # lua/pkg/ui/hud.lua), and the old poller's lost-tick watchdog: neither may happen any more.
    '!A function requiring userdata as param #1 was called without userdata'
    '!hud tick callback still not run'
    # A successful attach is logged at DEBUG only (lua/pkg/ui/text.lua); INFO is for elements left pending.
    "!\[$T\] ui attach '"
)
$started = @(
    "\[$N\] native: loaded, version $Ver for UE4SS v3\.0\.1-1181-g83330635"
    "\[$N\] READY version=$Ver native=$Ver ue4ss=v3\.0\.1-1181-g83330635 boot=\d+ floor=$Floor features=[a-z][\w.,]*\s*$"
    "\[$N\] CHANNEL hooked .*ModActor_C:${N}_Call"
    "\[$T\] NATIVE main\.lua ${N}_NativeVersion ok=true version=$Ver ue4ss=v3\.0\.1-1181-g83330635"
    "\[$T\] NATIVE main\.lua ${N}_ClockMicros ok=true type=integer"
    "\[$T\] CONNECT ok $N $Ver \(pong $Ver boot=\d+\)"
    "\[$N\] native: GUObjectArray layout: .* scan mode contiguous chunks"
    "\[$N\] native: REF_COST calls=1 "
    "!\[$T\] FAIL "
    "!\[$N\] ERROR"
)
$skeleton = $started + @("\[$T\] SCENARIO skeleton ", "\[$T\] END result=PASS", "!\[$T\] DEBUG ui attach")
# Story 8 AC 11: the Border around the text (alpha 0, padding 0) must not change the unstyled size. 283.8x29.2 canvas
# units is what "Nucleus skeleton: match1" measured with the bare TextBlock (V8.0, 2026-10-23); soft, since another
# core name or font changes it.
$skeleton += "?\[$T\] GEOM match1 .* desired=\(283\.8x29\.2\)"
foreach ($p in 'menu1', 'match1', 'menu2', 'match2') {
    $skeleton += "\[$T\] OK REFIND $p widget by handle -> .*WBP_${N}Text_C"
    $skeleton += "\[$T\] OK PARENT $p widget is in the live HUD canvas \(.*InventoryUI_C.*OwningCanvas\)"
    # The menu's HUD is hidden (nothing of InventoryUI_C is drawn there); every match must put the widget in the
    # canvas's top-right corner.
    $skeleton += if ($p -like 'match*') { "\[$T\] OK CORNER $p widget is in the canvas's top-right corner" } else { "\[$T\] OK (CORNER|HIDDENHUD) $p " }
    if ($p -like 'match*') {
        $skeleton += "\[$T\] REFCOST $p n=200 "
        # Story 12 AC 6: the top-right widget overlaps no drawn game widget (a FAIL line names the widget).
        $skeleton += "\[$T\] OK OVERLAP $p none: "
    }
    if ($p -ne 'menu1') {
        $skeleton += "\[$T\] OK DEREF $p previous widget from \w+ -> nil"
        $skeleton += "\[$T\] OK PATH $p previous widget path resolves=false"
    }
}
$badInput = $started + @(
    "\[$T\] SCENARIO bad-input "
    "!\[$T\] DEBUG ui attach"
    "\[$T\] OK DEREF match1 previous widget from menu1 -> nil"
    "\[$T\] OK CASE match1\.ref-destroyed "
    "\[$T\] OK CASES total=\d+ passed=\d+ failed=0"
    "\[$T\] REFCOST match1 n=200 "
    "\[$T\] OK CLOCKRT match1 "
    "\[$T\] CLOCKCOST match1 n=10000 "
    "\[$T\] END result=PASS"
)
# Every case of each group, in both worlds: the menu and the match after a map change.
foreach ($p in 'menu1', 'match1') {
    foreach ($id in 'nv-ok', 'nv-arg', 'clock-ok', 'clock-mono', 'clock-arg', 'clock-nil', 'clock-str', 'clock-table', 'clock-two',
                    'wrap-clock', 'off-clock', 'ref-nil', 'ref-true', 'ref-table', 'ref-str', 'ref-float', 'ref-2\^53f', 'ref-0', 'ref--1',
                    'ref-2\^53', 'ref-interior', 'ref-misaligned', 'ref-unmappedlo', 'ref-unmappedhi', 'ref-live', 'ref-rand8',
                    'ref-rand64-6', 'deref-live', 'free-1', 'free-2', 'deref-freed', 'deref-nil', 'deref-0', 'deref-2\^53',
                    'deref-rand8', 'free-nil', 'free-0', 'free-rand8', 'wrap-ref-nil', 'ch-ping', 'ch-nil', 'ch-long-client',
                    'chd-long', 'chd-cap', 'chd-cap\+1', 'chd-empty', 'chd-unknown', 'chd-space', 'chd-longop', 'chd-garbage-ascii',
                    'chd-number', 'chd-table', 'chd-bool', 'chd-nil', 'off-nv', 'off-ref', 'off-deref', 'off-free', 'off-freed-deref') {
        $badInput += "\[$T\] OK CASE $p\.$id "
    }
}
# Map service story 17: core's map setup alive() against real UE4SS values (refused: a missing member's placeholder, a
# struct value, a TArray, an out-array entry, nil, a number, a string, a table; live: actor, class, function, world, object).
foreach ($p in 'menu1', 'match1') {
    foreach ($id in 'alive-trivial', 'alive-struct', 'alive-tarray', 'alive-remote', 'alive-nil', 'alive-num', 'alive-str', 'alive-table',
                    'alive-actor', 'alive-class', 'alive-func', 'alive-world', 'alive-obj') {
        $badInput += "\[$T\] OK CASE $p\.$id "
    }
}
# The UI helpers' cases (stories 7-10), in both worlds, and the calls made before connect.
foreach ($p in 'menu1', 'match1') {
    foreach ($id in 'ui-watch-nil', 'ui-watch-str', 'ui-watch-two', 'ui-unwatch-str', 'ui-unwatch-float', 'ui-unwatch-unknown', 'ui-find-arg',
                    'ui-find-ok', 'ui-isvisible-arg', 'ui-watch-ok', 'ui-elements-ok', 'ui-elements-arg', 'ui-create-none', 'ui-create-noid',
                    'ui-create-emptyid', 'ui-create-numid', 'ui-create-65', 'ui-create-space', 'ui-create-text-table', 'ui-create-text-bool',
                    'ui-create-text-func', 'ui-create-place-str', 'ui-create-unknown', 'ui-style-str', 'ui-style-purple', 'ui-style-r-neg',
                    'ui-style-r-2', 'ui-style-r-str', 'ui-style-pad5', 'ui-style-bg', 'ui-create-ok', 'ui-create-64', 'ui-create-num',
                    'ui-handle-write', 'ui-set-text-table', 'ui-setvis-none', 'ui-setvis-yes', 'ui-setvis-1', 'ui-set-h-forged',
                    'ui-setvis-h-table', 'ui-remove-h-nil', 'ui-isshown-h-num', 'ui-place-h-str', 'ui-place-str', 'ui-place-empty',
                    'ui-place-corner-abs', 'ui-place-typo', 'ui-place-corner-bad', 'ui-place-gap-bad', 'ui-place-off-a', 'ui-place-off-huge',
                    'ui-place-off-nan', 'ui-place-off-5000', 'ui-place-off-key', 'ui-place-off-max', 'ui-place-near-mic', 'ui-place-abs-str',
                    'ui-place-abs-anchor', 'ui-place-abs-9000', 'ui-place-abs-offset', 'ui-place-abs-ok', 'ui-remove-ok', 'ui-remove-again',
                    'ui-removed-set', 'ui-removed-isshown', 'ui-removed-setvis', 'ui-removed-place', 'ui-recreate', 'ui-stats', 'ui-hud-stats',
                    'off-ui-create', 'off-ui-set', 'off-ui-setstyle', 'off-ui-setvis', 'off-ui-remove', 'off-ui-isshown', 'off-ui-place',
                    'off-ui-elements', 'off-ui-find', 'off-ui-watch', 'off-ui-unwatch', 'off-ui-isvisible', 'off-ui-after',
                    'ui-overlaps-two', 'ui-overlaps-hidden', 'ui-overlaps-h-table', 'ui-overlaps-h-nil', 'ui-overlaps-h-num',
                    'ui-overlaps-h-str', 'ui-overlaps-h-forged', 'ui-removed-overlaps', 'off-ui-overlaps',
                    # story 13: the journal watcher and the journal host
                    'ui-journal-watch-nil', 'ui-journal-watch-1', 'ui-journal-watch-str', 'ui-journal-watch-table', 'ui-journal-watch-two',
                    'ui-journal-unwatch-forged', 'ui-journal-unwatch-hudtoken', 'ui-journal-unwatch-str', 'ui-journal-unwatch-float',
                    'ui-journal-unwatch-nil', 'ui-journal-unwatch-table', 'ui-journal-unwatch-two', 'ui-journal-isopen-arg',
                    'ui-journal-isopen-ok', 'ui-journal-find-arg', 'ui-journal-find-ok', 'ui-journal-watch-ok', 'ui-journal-stats',
                    'ui-create-journal-near', 'ui-place-host', 'ui-place-host-num', 'ui-place-host-journal-near', 'ui-place-host-journal-ok',
                    'ui-isshown-journal', 'off-ui-journal-watch', 'off-ui-journal-unwatch', 'off-ui-journal-isopen', 'off-ui-journal-find',
                    # story 19: journal regions (the I/O matrix's error rows; a corner in and near each region), elements(host)
                    'ui-elements-bogus', 'ui-elements-two', 'ui-elements-hud', 'ui-elements-journal',
                    'ui-place-region-hud', 'ui-place-inset-hud', 'ui-place-region-spine', 'ui-place-region-num', 'ui-place-inset-huge',
                    'ui-place-inset-num', 'ui-place-near-region-key', 'ui-place-near-inset-key', 'ui-place-abs-region-key', 'ui-place-abs-inset-key',
                    'ui-place-near-hud-map', 'ui-place-journal-near-corner',
                    'ui-place-region-ammo', 'ui-place-region-binder', 'ui-place-region-cover', 'ui-place-region-map',
                    'ui-place-region-map-header', 'ui-place-region-match', 'ui-place-region-page-left', 'ui-place-region-page-right',
                    'ui-place-region-tasks', 'ui-place-near-ammo', 'ui-place-near-binder', 'ui-place-near-cover', 'ui-place-near-map',
                    'ui-place-near-map-header', 'ui-place-near-match', 'ui-place-near-page-left', 'ui-place-near-page-right',
                    'ui-place-near-tasks',
                    # story 14: panels and their reordering (AC 5), and the panel functions off the game thread
                    'ui-panel-create-none', 'ui-panel-create-unknown', 'ui-panel-create-noid', 'ui-panel-layout-grid', 'ui-panel-layout-num',
                    'ui-panel-gap-3', 'ui-panel-gap-huge', 'ui-panel-place-str', 'ui-panel-style-purple', 'ui-panel-create-ok', 'ui-panel-in-panel',
                    'ui-panel-place-in-panel', 'ui-panel-child-num', 'ui-panel-child-str', 'ui-panel-child-forged', 'ui-panel-child-text',
                    'ui-panel-child-corner', 'ui-panel-child-33', 'ui-panel-setvis-yes', 'ui-panel-setstyle-str', 'ui-text-set-on-panel',
                    'ui-panel-id-taken', 'ui-panel-setorder-missing', 'ui-panel-setorder-dup', 'ui-panel-setorder-other', 'ui-panel-setorder-removed',
                    'ui-panel-setorder-nonhandle', 'ui-panel-setorder-forged', 'ui-panel-setorder-nontable', 'ui-panel-setorder-nil',
                    'ui-panel-setorder-holes', 'ui-panel-setorder-two', 'ui-panel-move-0', 'ui-panel-move-n1', 'ui-panel-move-float',
                    'ui-panel-move-str', 'ui-panel-move-nil', 'ui-panel-move-other', 'ui-panel-move-removed', 'ui-panel-move-forged',
                    'ui-panel-order-unchanged', 'ui-panel-move-ok', 'ui-panel-setorder-ok', 'ui-panel-order-arg', 'ui-panel-remove-ok',
                    'ui-panel-remove-again', 'ui-panel-removed-child', 'ui-panel-removed-order', 'ui-panel-removed-intent',
                    'off-ui-panel-create', 'off-ui-panel-setstyle', 'off-ui-panel-setvis', 'off-ui-panel-remove', 'off-ui-panel-isshown',
                    'off-ui-panel-order', 'off-ui-panel-setorder', 'off-ui-panel-move',
                    # story 15: buttons (AC 7) and the button functions off the game thread
                    'ui-button-create-none', 'ui-button-create-unknown', 'ui-button-create-noid', 'ui-button-onclick-missing',
                    'ui-button-onclick-str', 'ui-button-onclick-num', 'ui-button-onclick-table', 'ui-button-label-table',
                    'ui-button-label-bool', 'ui-button-label-65', 'ui-button-host-hud', 'ui-button-host-default', 'ui-button-enabled-yes',
                    'ui-button-enabled-num', 'ui-button-style-pink', 'ui-button-place-str', 'ui-button-in-hud-panel', 'ui-button-create-ok',
                    'ui-button-isshown-closed', 'ui-button-place-hud', 'ui-button-panel-to-hud', 'ui-button-setlabel-table',
                    'ui-button-setlabel-65', 'ui-button-setenabled-yes', 'ui-button-setenabled-nil', 'ui-button-setvis-1',
                    'ui-button-remove-ok', 'ui-button-remove-again', 'ui-button-removed-setlabel', 'ui-button-removed-isshown', 'ui-button-stats',
                    'off-ui-button-create', 'off-ui-button-setlabel', 'off-ui-button-setenabled', 'off-ui-button-setvis',
                    'off-ui-button-remove', 'off-ui-button-isshown') {
        $badInput += "\[$T\] OK CASE $p\.$id "
    }
    foreach ($fn in 'setstyle', 'setvis', 'remove', 'isshown', 'order', 'setorder', 'move') {
        foreach ($h in 'nil', 'num', 'forged', 'text') { $badInput += "\[$T\] OK CASE $p\.ui-panel-$fn-h-$h " }
    }
    foreach ($fn in 'setlabel', 'setenabled', 'setvis', 'remove', 'isshown') {
        foreach ($h in 'nil', 'num', 'forged', 'text') { $badInput += "\[$T\] OK CASE $p\.ui-button-$fn-h-$h " }
    }
}
# Story 21 (Mod Manager story 2, core 0.7.0): the menu entry, the menu and screen hosts, lists, rows and the game look
# with bad values, in both worlds (no title-screen menu is open in either, so screen.open refuses), and every new
# function off the game thread.
foreach ($p in 'menu1', 'match1') {
    foreach ($id in 'mm-entry-none', 'mm-entry-str', 'mm-entry-unknown', 'mm-entry-noid', 'mm-entry-space', 'mm-entry-65', 'mm-label-nil',
                    'mm-label-str', 'mm-label-noen', 'mm-label-lower', 'mm-label-17', 'mm-label-empty', 'mm-label-65', 'mm-label-num',
                    'mm-label-key-digit', 'mm-label-key-long', 'mm-label-key-num', 'mm-onclick-nil', 'mm-onclick-str', 'mm-style-preset',
                    'mm-style-num', 'mm-style-tpreset', 'mm-style-key', 'mm-style-font-500', 'mm-style-font-15', 'mm-style-font-float',
                    'mm-style-color-2', 'mm-style-color-str', 'mm-style-bold', 'mm-style-italic', 'mm-entry-ok', 'mm-entry-second',
                    'mm-remove-nil', 'mm-remove-num', 'mm-remove-forged', 'mm-remove-ok', 'mm-remove-again', 'mm-entry-after-remove',
                    'mm-isopen-arg', 'mm-isopen-ok', 'mm-watch-nil', 'mm-watch-str', 'mm-unwatch-forged', 'mm-unwatch-str', 'mm-watch-ok',
                    'mm-screen-open-none', 'mm-screen-open-unknown', 'mm-screen-open-noid', 'mm-screen-open-close', 'mm-screen-open-nomenu',
                    'mm-screen-close-nil', 'mm-screen-close-num', 'mm-screen-close-forged', 'mm-screen-isopen-nil', 'mm-screen-isopen-num',
                    'mm-screen-isopen-forged', 'mm-screen-top-arg', 'mm-screen-top-ok', 'mm-screen-watch-nil', 'mm-screen-unwatch-forged',
                    'mm-screen-unwatch-float', 'mm-screen-watch-ok', 'mm-elements-menu', 'mm-elements-screen', 'mm-place-screen-num',
                    'mm-place-screen-forged', 'mm-place-menu-near', 'mm-place-menu-region', 'mm-place-fill-alone', 'mm-text-menu-ok',
                    'mm-look-bad', 'mm-font-bad', 'mm-font-plain', 'mm-font-game-ok', 'mm-list-none', 'mm-list-unknown', 'mm-list-size-nil',
                    'mm-list-size-str', 'mm-list-size-w31', 'mm-list-size-h4097', 'mm-list-size-nan', 'mm-list-hud', 'mm-list-hud-default',
                    'mm-list-ok', 'mm-list-in-list', 'mm-list-in-panel', 'mm-row-unknown', 'mm-row-hud', 'mm-row-ok', 'mm-row-in-panel-ok',
                    'mm-row-in-row', 'mm-list-in-row', 'mm-fill-0', 'mm-fill-17', 'mm-fill-str', 'mm-fill-list', 'mm-row-child-17',
                    'mm-button-in-row-ok', 'mm-row-setvis-yes', 'mm-row-isshown-ok', 'mm-list-child-257', 'mm-list-setvis-1',
                    'mm-list-setstyle-game', 'mm-list-isshown-ok', 'mm-list-h-text', 'mm-list-h-forged', 'mm-list-remove-ok',
                    'mm-list-remove-again', 'mm-list-removed-row') {
        $badInput += "\[$T\] OK CASE $p\.ui-$id "
    }
    foreach ($id in 'menu-entry', 'menu-removeentry', 'menu-isopen', 'menu-watch', 'menu-unwatch', 'screen-open', 'screen-close', 'screen-isopen',
                    'screen-top', 'screen-watch', 'screen-unwatch', 'list-create', 'list-setstyle', 'list-setvis', 'list-remove', 'list-isshown',
                    'row-create', 'row-setstyle', 'row-setvis', 'row-remove', 'row-isshown') {
        $badInput += "\[$T\] OK CASE $p\.off-ui-$id "
    }
}
foreach ($id in 'pre-create', 'pre-watch', 'pre-find', 'pre-elements', 'pre-overlaps', 'pre-journal-watch', 'pre-journal-isopen', 'pre-panel-create', 'pre-panel-move', 'pre-button-create', 'pre-game-watch', 'pre-game-unwatch', 'pre-game-isopen') { $badInput += "\[$T\] OK CASE $id " }
$badInput += "\[$T\] OK CASES before-connect recorded=10"
$badInput += "\[$T\] OK CASES game before-connect recorded=3"   # core story 31
# Story 18: versioning. connect's bad needs (AC 5), the compatibility rule on this core (AC 1-3), core.has and
# core.features (AC 4) and the deprecated op (AC 8), in both worlds.
foreach ($p in 'menu1', 'match1') {
    foreach ($id in 'ver-need-missing', 'ver-need-empty', 'ver-need-ge', 'ver-need-gex', 'ver-need-short', 'ver-need-lt', 'ver-need-tilde',
                    'ver-need-300', 'ver-need-num', 'ver-need-table', 'ver-need-space', 'ver-need-10digits', 'ver-opts-nil', 'ver-opts-mod-num',
                    'ver-accept-1', 'ver-accept-2', 'ver-accept-3', 'ver-accept-4', 'ver-accept-5', 'ver-accept-6', 'ver-accept-7', 'ver-accept-8',
                    'ver-core-old', 'ver-core-old-caret', 'ver-floor', 'ver-features-declared', 'ver-features-copy',
                    'ver-has-known-ui\.text', 'ver-has-known-ui\.panel', 'ver-has-known-ui\.button', 'ver-has-known-ui\.journal',
                    'ver-has-known-call', 'ver-has-known-ref', 'ver-has-unknown', 'ver-has-fn', 'ver-has-num', 'ver-has-empty', 'ver-has-300',
                    'ver-has-nil', 'ver-has-none', 'ver-has-table', 'ver-has-bool', 'ver-has-skip', 'ver-deprecated-1', 'ver-deprecated-2',
                    'modid-require', 'modid-nil', 'modid-none', 'modid-num', 'modid-table', 'modid-10k', 'modid-prefix', 'modid-ok') {
        $badInput += "\[$T\] OK CASE $p\.$id "
    }
}
$Probe = [regex]::Escape("${t}Need")
$badInput += @(
    # Each bad need is one clean line from the probe (12 per world), and nothing else from it.
    "#24|\[$Probe\] ERROR connect: need .* will not run\.\s*$"
    "#24|\[$Probe\] "
    "\[$T\] FEATURES [a-z][\w.,]*\s*$"
    # AC 8: one DEPRECATED line for this dependent in the whole session (four calls, two worlds).
    "#1|\[$T\] WARN DEPRECATED channel op 'deprecated-test'; use 'version' instead\."
)
# Map service story 3: the objectives natives. Their bad values in both worlds and off the game thread; the writers
# refused in the standalone menu; in the match a manager of the test's own filled, read back, refused a second fill,
# and one task's TraitorState set and cleared; the forced missing struct member through core's test-only DLL
# (<name>SkelNative); a destroyed manager; and the three called during main.lua, before the first engine tick.
foreach ($p in 'menu1', 'match1') {
    foreach ($id in 'obj-set-noargs', 'obj-set-one', 'obj-set-0tasks', 'obj-set-odd', 'obj-set-65', 'obj-set-64', 'obj-set-path-num',
                    'obj-set-path-float', 'obj-set-area-nil', 'obj-set-id-num', 'obj-set-text-table', 'obj-set-text-bool', 'obj-set-text-func',
                    'obj-set-path-obj', 'obj-set-path-empty', 'obj-set-path-513', 'obj-set-path-512', 'obj-set-path-noslash', 'obj-set-path-utf8',
                    'obj-set-path-ctrl', 'obj-set-area-empty', 'obj-set-area-129', 'obj-set-area-128', 'obj-set-area-utf8', 'obj-set-area-tab',
                    'obj-set-text-empty', 'obj-set-text-257', 'obj-set-text-256', 'obj-set-text-utf8', 'obj-set-id-empty', 'obj-set-id-65',
                    'obj-set-id-64', 'obj-set-id-space', 'obj-set-id-slash', 'obj-set-id-utf8', 'obj-set-dup', 'obj-set-dup-later',
                    'obj-set-missing', 'obj-set-nonmanager', 'obj-set-class', 'obj-set-cdo',
                    'obj-desc-noargs', 'obj-desc-two', 'obj-desc-num', 'obj-desc-nil', 'obj-desc-table', 'obj-desc-empty-path', 'obj-desc-513',
                    'obj-desc-noslash', 'obj-desc-utf8', 'obj-desc-missing', 'obj-desc-nonmanager', 'obj-desc-cdo',
                    'obj-trait-noargs', 'obj-trait-two', 'obj-trait-four', 'obj-trait-path-num', 'obj-trait-id-num', 'obj-trait-id-nil',
                    'obj-trait-state-str', 'obj-trait-state-int', 'obj-trait-state-nil', 'obj-trait-state-table', 'obj-trait-noslash',
                    'obj-trait-id-empty', 'obj-trait-id-65', 'obj-trait-id-space', 'obj-trait-missing', 'obj-trait-nonmanager', 'obj-trait-cdo',
                    'off-obj-set', 'off-obj-set-bad', 'off-obj-desc', 'off-obj-desc-bad', 'off-obj-trait', 'off-obj-trait-bad') {
        $badInput += "\[$T\] OK CASE $p\.$id "
    }
}
foreach ($id in 'obj-set-standalone', 'obj-trait-standalone', 'obj-desc-standalone') { $badInput += "\[$T\] OK CASE menu1\.$id " }
foreach ($id in 'obj-desc-empty', 'obj-trait-unfilled', 'obj-set-ok', 'obj-desc-filled', 'obj-set-second', 'obj-desc-unchanged', 'obj-trait-unknown',
                'obj-desc-after-unknown', 'obj-trait-ok', 'obj-desc-trait', 'obj-trait-off', 'obj-desc-trait-off', 'obj-game-tick', 'obj-desc-game-tick',
                'obj-missing-Actors', 'obj-missing-Tasks', 'obj-missing-State', 'obj-missing-Description', 'obj-missing-UniqueIdentifier',
                'obj-missing-TraitorDescription', 'obj-missing-TraitorState', 'obj-missing-key', 'obj-missing-nowrite', 'obj-missing-control',
                'obj-set-destroyed', 'obj-desc-destroyed', 'obj-trait-destroyed') {
    $badInput += "\[$T\] OK CASE match1\.$id "
}
foreach ($id in 'pre-obj-set', 'pre-obj-desc', 'pre-obj-trait') { $badInput += "\[$T\] OK CASE $id " }
# Map service story 9: the map setup signal (<name>.map.setup) read from the test's own Lua state during main.lua, in
# the menu and in the stock match (listen host): exactly "none" each time.
foreach ($id in 'pre-map-signal', 'menu1.map-signal', 'match1.map-signal') { $badInput += "\[$T\] OK CASE $([regex]::Escape($id)) " }
# Mod Manager story 5: the settings service. core.settings and the ops with bad values in both worlds and off the game
# thread; the title-screen window (test.mode); the cross-state change (SkelPeer sets test.count, this test's watcher
# sees it within 1 s, rev +1); the restart setting; SkelPeer's corrupt settings.json (one WARN), SkelTest's missing one
# (one info line). After the run (with -Instance) the test dependent's settings.json is read back below.
foreach ($p in 'menu1', 'match1') {
    foreach ($id in 'set-get-ok', 'set-get-nil', 'set-get-num', 'set-get-table', 'set-get-empty', 'set-get-unknown', 'set-get-preset', 'set-getall-ok',
                    'set-getall-arg', 'set-set-unknown', 'set-set-keynum', 'set-set-float', 'set-set-61', 'set-set-enum-x', 'set-set-nan', 'set-set-inf',
                    'set-set-bool-str', 'set-set-nilval', 'set-set-table', 'set-set-three', 'set-set-readonly', 'set-set-lobby', 'set-set-flag-ok',
                    'set-get-flag', 'set-set-flag-back', 'set-set-ratio-ok', 'set-set-ratio-back', 'set-set-menu', 'set-watch-nil', 'set-watch-str',
                    'set-unwatch-str', 'set-unwatch-float', 'set-unwatch-unknown', 'set-watch-ok', 'set-describe-dots', 'set-describe-65',
                    'set-describe-nil', 'set-describe-unknown', 'set-describe-core', 'set-describe-own', 'set-setfor-dots', 'set-setfor-65',
                    'set-setfor-unknown', 'set-setfor-core', 'set-setfor-peer-99', 'set-setfor-num', 'ch-set-get-num', 'ch-set-get-table',
                    'chd-set-get-none', 'chd-set-get-empty', 'chd-set-get-dots', 'chd-set-get-slash', 'chd-set-get-65', 'chd-set-get-unknown',
                    'chd-set-get-core', 'chd-set-get-own', 'chd-set-set-none', 'chd-set-set-brace', 'chd-set-set-array', 'chd-set-set-deep',
                    'chd-set-set-long', 'chd-set-set-dup', 'chd-set-set-nomod', 'chd-set-set-dots', 'chd-set-set-novalue', 'chd-set-set-unknownkey',
                    'chd-set-set-badvalue', 'chd-set-set-nan', 'chd-set-set-readonly', 'chd-set-set-unknownmod', 'chd-set-set-garbage',
                    'set-restart-get', 'set-restart-pending',
                    'off-set-get', 'off-set-getall', 'off-set-set', 'off-set-setfor', 'off-set-describe', 'off-set-watch', 'off-set-unwatch') {
        $badInput += "\[$T\] OK CASE $p\.$id "
    }
}
$badInput += @(
    "\[$T\] OK CASE menu1\.set-restart "
    "\[$N\] READY .* features=(\S*,)?settings(,\S*)?\s*$"
    "#1|\[$N\] settings: ${T}: no settings\.json; using the declared defaults\s*$"
    "#1|\[$N\] WARN settings: ${Peer}: settings\.json is corrupt "
    "!\[$N\] WARN settings: $T"
    "!\[$N\] WARN settings: .*could not write"
    "!\[$N\] settings: ${N}: "   # core's own folder declares no settings: no values-file line for it
    "\[$Peer\] PEERGET peer\.level ok=true value=2\s*$"
    "#1|\[$Peer\] PEERSET $T test\.count=42 ok=true result=true\s*$"
    "#1|\[$T\] SETWATCH menu1 key=test\.count value=42 "
    "\[$T\] OK SETX menu1 watcher saw test\.count=42"
    "\[$T\] OK SETX menu1 within 1 s of the peer's set"
    "\[$T\] OK SETX menu1 rev rose by one"
    "\[$T\] OK SETX menu1 get\('test\.count'\) = 42"
    "!\[$T\] WARN settings"
    "!\[$Peer\] (FAIL|ERROR|WARN)"
)
# Core story 22: core.net. Every bad publish/read/watch/unwatch and channel-op row in both worlds and off the game
# thread; the standalone and no-state results and no <name>Net in the menu; in the host match: publish then read at
# once, out of bounds (one line), absent, the namespaced fixture through the channel, exactly one <name>Net
# (replicated, always relevant, authority, no owner, this core's version, the published State), the caps.
foreach ($p in 'menu1', 'match1') {
    foreach ($id in 'net-role', 'net-role-arg', 'net-pub-other', 'net-pub-nodot', 'net-pub-name33', 'net-pub-badchars', 'net-pub-10k', 'net-pub-keynum',
                    'net-pub-nil', 'net-pub-str', 'net-pub-2.5', 'net-pub-nan', 'net-pub-inf', 'net-pub-2^31', 'net-pub-2^53', 'net-pub-three',
                    'net-read-keynum', 'net-read-nodot', 'net-read-badid', 'net-read-minfloat', 'net-read-maxstr', 'net-read-minmax', 'net-read-four',
                    'net-watch-fn', 'net-watch-key', 'net-watch-minmax', 'net-unwatch-str', 'net-unwatch-unknown', 'net-watch-ok', 'net-unwatch-ok',
                    'net-unwatch-again', 'net-watch-65', 'net-ch-noeq', 'net-ch-badid', 'net-ch-badval', 'net-ch-big', 'net-ch-long', 'net-ch-none',
                    'net-modactor', 'net-count', 'off-net-publish', 'off-net-read', 'off-net-watch', 'off-net-unwatch', 'off-net-role') {
        $badInput += "\[$T\] OK CASE $p\.$([regex]::Escape($id)) "
    }
}
foreach ($id in 'net-pub-standalone', 'net-ch-standalone', 'net-read-nostate') { $badInput += "\[$T\] OK CASE menu1\.$([regex]::Escape($id)) " }
foreach ($id in 'net-pub-ok', 'net-read-ok', 'net-pub-dmg', 'net-read-oob', 'net-read-absent', 'net-ch-ns', 'net-read-ns', 'net-actor-rep', 'net-actor-owner',
                'net-actor-version', 'net-actor-state', 'net-pub-17', 'net-ch-65', 'net-pub-65') {
    $badInput += "\[$T\] OK CASE match1\.$([regex]::Escape($id)) "
}
# Core story 23: player presence. Every bad-args row of presence, watchPresence, compatible and versionsCompatible in
# both worlds and off the game thread; the local player's record (the local list) in the menu and the host match;
# absent for PlayerId 999999; the direct net-mod / net-mod-off cases (oversized, no '=', bad id, version and netCompat,
# core's own id, the 33rd entry, an unknown id, the namespaced fixture with netCompat); no <name>Presence in either
# world; the watch's "joined" for the local player; no-world (menu1, through the client's test hook).
foreach ($p in 'menu1', 'match1') {
    foreach ($id in 'pid', 'local-pid', 'local-ps', 'local-core', 'absent-pid', 'absent-mod', 'mod-33', 'compat-local', 'compat-absent', 'compat-nomod',
                    'player-str', 'player-nil', 'player-float', 'player-bool', 'player-table', 'player-2^40', 'player-notps', 'player-dead',
                    'mod-num', 'mod-empty', 'mod-badid', 'mod-65', 'mod-201', 'three', 'watch-fn', 'watch-mod', 'watch-badid', 'watch-three', 'watch-65',
                    'compat-player', 'compat-mod', 'compat-three', 'vc-1', 'vc-2', 'vc-3', 'vc-4', 'vc-short', 'vc-1000', 'vc-num', 'vc-ncnum', 'vc-above',
                    'vc-five', 'ch-big', 'ch-noeq', 'ch-badid', 'ch-badver', 'ch-ncabove', 'ch-core', 'ch-none', 'ch-long', 'ch-33', 'ch-off-unknown',
                    'ch-off-badid', 'ch-off-none', 'ch-ns', 'ns-read', 'ch-ns-off', 'ns-gone', 'count', 'watch-ok', 'watch-joined', 'unwatch', 'unwatch-again') {
        $badInput += "\[$T\] OK CASE $p\.net-presence-$([regex]::Escape($id)) "
    }
    foreach ($id in 'off-net-presence', 'off-net-watchPresence', 'off-net-compatible', 'off-net-versionsCompatible') { $badInput += "\[$T\] OK CASE $p\.$([regex]::Escape($id)) " }
}
foreach ($id in 'noworld', 'compat-noworld') { $badInput += "\[$T\] OK CASE menu1\.net-presence-$([regex]::Escape($id)) " }
$badInput += @(
    "\[$N\] READY .* features=(\S*,)?net,net\.compatible,net\.presence,net\.publish,net\.read,net\.role,net\.unwatch,net\.versionsCompatible,net\.watch,net\.watchPresence(,\S*)?\s*$"
    "\[$T\] $N\.net presence: registered skeltest=0\.1\.0\s*$"
    "\[$N\] PRESENCE local player -?\d+ \(standalone\): $([regex]::Escape($name.ToLower()))=$Ver,"
    "\[$N\] PRESENCE local player -?\d+ \(host\): $([regex]::Escape($name.ToLower()))=$Ver,"
    "!\[$N\] PRESENCE spawned"
    "!\[$N\] (WARN|ERROR) PRESENCE"
    "\[$N\] NET world .*NewMainMenu.* role=standalone"
    "\[$N\] NET world .*SmallMap.* role=host"
    "#1|\[$N\] NET spawned ${N}Net_C_\d+ in .* replicates=true alwaysRelevant=true owner=none "
    "#1|\[$T\] WARN $N\.net: skeltest\.enemyDamage = 250 is outside this mod's bounds 0\.\.200"
)
$NT = [regex]::Escape("${name}SkelNative")
$badInput += @(
    "\[$T\] OK CASES main\.lua objectives recorded=3"
    "\[$NT\] native: loaded \(test only\)"
    "!\[$NT\] native: (ERROR|FAULT)"
    "#1|\[$N\] native: SET .* area='NN Area' objectives=1 tasks=2 \(Objectives replicates=1\)"
    "\[$N\] native: TRAITOR .* task 'nn_b' TraitorState=1 \(1 task\)"
    # A bad manager is one log line, besides the Lua error (story 3's matrix).
    "\[$N\] native: REFUSED ${N}_SetObjectives: .* isn't an ObjectiveManager_C"
    "\[$N\] native: REFUSED ${N}_SetObjectives: no object at /Game/NoSuch/NNNoManager\.NNNoManager"
    "\[$N\] native: REFUSED ${N}_SetObjectives: \S*Default__ObjectiveManager_C is a class default object or archetype"
    "\[$N\] native: REFUSED ${N}_SetObjectives: \S*ObjectiveManager_C_\d+ is being destroyed \(flagged Garbage\)"
    "\[$N\] native: REFUSED ${N}_DescribeObjectives: (\S*ObjectiveManager_C_\d+ is being destroyed|no object at \S*ObjectiveManager_C_\d+)"
    "\[$NT\] native: REFUSED ${N}_SetObjectives: member Description \(name prefix 'Description_'\) is missing from STaskProperties"
    "\[$N\] native: REFUSED ${N}_SetObjectives: .* isn't in the host's world \(net mode: standalone\)"
)
# UI helpers in game (stories 7-10): what run.ps1 -Scenario ui proves unattended. END result=PASS already means every
# check the test made passed; these name the ones the stories' acceptance criteria rest on, plus core's own lines.
$ui = $started + @(
    "\[$T\] SCENARIO ui "
    "\[$T\] END result=PASS"
    "#1|\[$T\] hud seed FindAllOf\(InventoryUI_C\) call 1 "
    "!\[$T\] hud seed FindAllOf\(InventoryUI_C\) call [2-9]"
    "\[$T\] OK UIFINDALL match2 FindAllOf ran 1 time"
    "\[$T\] DEBUG ui attach (.*, )?'pre' created "
    "\[$T\] DEBUG ui attach (.*, )?'pre' reused .*\(HUD back in the viewport\)"
    "\[$T\] EVENT \d+ attached reason=HUD appeared"
    "\[$T\] EVENT \d+ shown "
    "\[$T\] EVENT \d+ lost reason=HUD gone from the viewport"
    "\[$T\] EVENT \d+ attached reason=HUD back in the viewport"
    "#1|\[$T\] WARN hud watcher \d+: "
    "#1|\[$T\] WARN text 'long': text is longer than 256 characters"
    # Story 12: with debug on, the automatic overlap check WARNs per overlapping widget (a diagnostic, allowed here); a
    # check or a widget that fails ("ui overlap check failed", "ui overlap: ... could not be checked") is not.
    "!\[$T\] WARN (?!hud watcher \d+: |text 'long': |ui overlap '|button 'b2' onClick: |DEPRECATED channel op 'deprecated-test'|$slowWarnOk)"
    "\[$T\] OK UIOVERLAP match1 'xcross' \(near the crosshair, offset x=-24\) reports the crosshair "
    "\[$T\] WARN ui overlap 'xcross': \S+[.:]Crosshair \(Image\) "
    "\[$T\] OK UIOVERLAP match1 automatic checks were scheduled"
    "!\[$T\] ERROR"
    "\[$T\] DEBUG hud tick n=\d+ "
    "\[$T\] DEBUG ui (widget\(s\) gone with the HUD; freed handle\(s\) .*'pre' |'pre': new widget .*; freed the handle)"
    # Story 7: steady-state ticks never pass 1 ms. Soft: a tick that handles a HUD event (attach after a new HUD), and
    # a steady tick a step of the Lua collector landed in (that work belongs to the whole Lua state, not to the tick).
    # Soft in the VM (-Target vm).
    "$hard\[$T\] WARN hud slow tick .*steady state\)"
    "?!\[$T\] WARN hud slow tick .*steady state, a Lua GC step"
    "?!\[$T\] WARN hud slow tick .*HUD event"
    "\[$T\] DEBUG hud prof event=attached "
    "?\[$T\] hud tick summary n="
    "\[$T\] UITICK ticks=\d+ "
    "\[$T\] OK UIDEREF match1 "
    "\[$T\] OK UIDEREF menu2 "
    "\[$T\] OK UITAG match1 "
    "\[$T\] OK UIVIS match1 "
    "\[$T\] OK UICORNER match1 'pre' top-right gap=16: "
    "\[$T\] OK UICORNER match1 'c-tl' top-left gap=8: "
    "\[$T\] OK UICORNER match1 'c-bl' bottom-left gap=32: "
    "\[$T\] OK UICORNER match1 'c-br' bottom-right gap=16: "
    "\[$T\] OK UICORNER match1 'pre' top-right gap=16 offsetX=40: "
    "\[$T\] OK UICORNER match2 'pre' top-right gap=16: "
    "\[$T\] OK UISAME match1 one widget"
    "\[$T\] OK UINOOP match1 a second set"
    "\[$T\] OK UILONG match1 "
    "\[$T\] OK UIREMOVE match1 its weak handle was freed"
    "\[$T\] OK UISTYLE match1 dim/normal is 8 units larger"
    "\[$T\] OK UISTYLE match1 background none"
    "\[$T\] OK UIHIDE match1 setVisible\(h, false\)"
    "\[$T\] OK UIABS match1 absolute centre"
    "\[$T\] OK UISTACK match1 pre, s1, s2, s3 stack 16 apart"
    "\[$T\] OK UISTACK match1 an absolute element in top-right moves nothing"
    "\[$T\] OK UISTACK match1 offset \{ x = -40 \} on s2 moves only s2"
    "\[$T\] OK UISTACK match1 hiding s2 closes the gap"
    "\[$T\] OK UISTACK match1 a two-line first element pushes the others down"
    "\[$T\] OK UISTACK match1 removing s2 closes the gap"
    "\[$T\] OK UINEAR match1 right of the crosshair, centred"
    "\[$T\] OK UINEAR match1 HideCrosshair\(true\) collapses the element"
    "\[$T\] OK UINEAR match1 HideCrosshair\(false\) brings it back"
    "\[$T\] OK UILATE match1 "
    "\[$T\] OK UIRAW match1 'pre' reused, not duplicated"
    "\[$T\] OK UIHID match2 'hid' is still hidden on the new HUD"
    "\[$T\] OK UIEVENTS "
    "\[$T\] OK UICLEAN match2 "
    # Story 14: panels on the HUD (AC 1-4, 6), through the RemoveAllWidgets re-add and the map change (AC 3).
    "\[$T\] OK UIPANEL match1 'pv' has exactly one widget"
    "\[$T\] OK UIPANEL match1 the three texts sit in its VBox in creation order"
    "\[$T\] OK UIPANEL match1 shown in order, top to bottom, 8 units"
    "\[$T\] OK UIPANEL match1 one dim box around all three"
    "\[$T\] OK UIPANEL match1 the panel stacks under 'pre'"
    "\[$T\] OK UIHPANEL match1 a horizontal panel lays its children out left to right"
    "\[$T\] OK UIPREMOVE match1 removing a panel removes its children"
    "\[$T\] OK UIPHIDE match1 hiding the middle child closes the gap"
    "\[$T\] OK UIPHIDE match1 hiding the panel hides all three"
    "\[$T\] OK UIPORDER match1 move\(panel, third, 1\) shows the third first"
    "\[$T\] OK UIPORDER match1 setOrder with the reversed list reverses them"
    "\[$T\] OK UIPORDER match1 the same three widgets"
    "\[$T\] OK UIPORDER match1 shown reversed"
    "\[$T\] OK UIPREBUILD match1 "
    "\[$T\] OK UIPMAP match2 "
    "\[$T\] OK UIPREMOVE match2 "
    # Story 15 (end of match2, on the Journal): real OS clicks, Enter, a throwing onClick, a disabled button, another
    # dependent's button (SkelPeer: its callback runs, exactly once; ours don't), two calls in a row.
    "\[$Peer\] CONNECT ok $N $Ver "
    "\[$Peer\] PEER ready: button 'peer' created"
    "#1|\[$Peer\] PEERCLICK \d+ 'peer'"
    "\[$Peer\] PEERCLICK 1 'peer'"
    "!\[$Peer\] (ERROR|WARN (?!DEPRECATED channel op 'deprecated-test'|$slowWarnOk))"
    # Story 18 AC 8: the test-only deprecated op works, and logs one DEPRECATED line per dependent (two calls each).
    "#1|\[$T\] WARN DEPRECATED channel op 'deprecated-test'; use 'version' instead\."
    "#1|\[$Peer\] WARN DEPRECATED channel op 'deprecated-test'; use 'version' instead\."
    "#2|\[$T\] DEPRECATED-OP call \d ok=true reply=$Ver\s*$"
    "#2|\[$Peer\] DEPRECATED-OP call \d ok=true reply=$Ver\s*$"
    "\[$T\] OK BHOOK match2 "
    "\[$T\] OK BPENDING match2 "
    "\[$T\] OK BMAP match2 "
    "\[$T\] OK BTAG match2 "
    "\[$T\] OK BPEER match2 "
    "\[$T\] OK BCLICK match2 a real mouse click on 'b1' ran its onClick exactly once"
    "\[$T\] OK BCLICK match2 a real mouse click on 'b2' ran its onClick exactly once"
    "#1|\[$T\] WARN button 'b2' onClick: .*b2 throws on its first click"
    "\[$T\] OK BTHROW match2 "
    "\[$T\] OK BENTER match2 "
    "\[$T\] OK BDISABLED match2 'b1' looks disabled"
    "\[$T\] OK BDISABLED match2 a real click on the disabled 'b1' ran nothing"
    "\[$T\] OK BENABLED match2 "
    "\[$T\] OK BOWNER match2 "
    "\[$T\] OK BDOUBLE match2 "
    "\[$T\] OK BCLOSED match2 "
    "\[$T\] OK BCLEAN match2 "
)
# Story 13 unattended (run.ps1 -Scenario journal): the Journal's map page as a host, opened and closed with the real
# map key twelve times (ten in a row, after a revive, after a map change). END result=PASS already means every check
# passed; these name what the acceptance criteria rest on. Timing (AC 4 and 6) is judged on the host; soft in the VM.
$soft = if ($Target -eq 'vm') { '?' } else { '' }
$journal = $started + @(
    "\[$T\] SCENARIO journal "
    "\[$T\] END result=PASS"
    "\[$T\] OK MAPKEY IA_Map is bound to the letter [A-Z] in IMC_Default"
    "\[$T\] JTREE open1 journal="
    "\[$T\] JTREE open1 MapWidget="
    "#12|\[$T\] OK JKEY \S+ the real [A-Z] key press opened the map"
    "#12|\[$T\] OK JKEY \S+ the real [A-Z] key press closed the map"
    "#12|\[$T\] OK JNEW \S+ open \d+ is a new Journal_C instance"
    "#12|\[$T\] OK JONE \S+ one widget per element in the map canvas, the panel's two in its box \(jt=1 jpanel=1 jb1=1 jb2=1\)"
    # Story 14 AC 6: the panel's order on every open; reversed while open 5 is open, kept on open 6, back on open 7.
    "#12|\[$T\] OK JORDER (open|revive|match2)\S* the panel's children in the expected order"
    "\[$T\] OK JORDER open5 applies while the map is open: box jb2,jb1"
    "\[$T\] OK JORDER open6 the panel's children in the expected order jb2,jb1"
    "\[$T\] OK JORDER open7 the panel's children in the expected order jb1,jb2"
    "#12|\[$T\] OK JPSHOWN "
    # Story 15 AC 5: one real click on 'jb1' per open (ten in a row, after a revive, after a map change), each once.
    "#12|\[$T\] OK JCLICK \S+ a real click on 'jb1' ran its onClick exactly once"
    "\[$T\] OK JCLICKALL 12 real clicks on 'jb1' over 12 opens"
    "\[$T\] JSTEPS 10 opens, average per step: canvas \d+; "
    "#12|\[$T\] OK JCORNER \S+ 'jt' in the cover's top-right, 16 inward"
    "#12|\[$T\] OK JCLOSED "
    # Story 19: the Journal regions, created after the ten opens and checked on the revive and map-change opens.
    "\[$T\] OK JRPENDING the region elements are created while the map is closed \(11\)"
    # Story 20: exact- and map-region elements are drawn before the poll's opened; content-sized ones stay collapsed.
    "#2|\[$T\] OK JRFIRST (revive|match2)-open 7 of 7 exact- and map-region elements shown with a valid drawn rect at the opened event"
    "#2|\[$T\] OK JRCOLLAPSE (revive|match2)-open no content-sized-region element shown while its region was not painted"
    "#2|\[$T\] OK JRSHOWN (revive|match2)-open every region element shown "
    "#2|\[$T\] JREGION (revive|match2)-open canvas \(0,0\)-\(\d+,10\d\d\)"
    "#18|\[$T\] JREGION (revive|match2)-open region \S+ \(-?\d+,-?\d+\)-\(\d+,\d+\)"
    "#2|\[$T\] OK JRNEAR (revive|match2)-open 'jn' under the map square"
    "#2|\[$T\] OK JRCOVER (revive|match2)-open 'jc' at the cover's bottom-right"
    "#2|\[$T\] OK JRCORNERS (revive|match2)-open 9 of 9 'jr-<region>' texts"
    "\[$T\] OK JEVENTS 10 opens: opened=10 closed=10 lost=0"
    "\[$T\] OK JONE revive-open "
    "\[$T\] OK JONE match2-open "
    "\[$T\] OK JGC opens "
    "\[$T\] OK JGC end "
    "\[$T\] OK JEVENTS all: opened=12 closed=12 lost=0"
    "\[$T\] OK JNEWALL 12 opens, 12 distinct"
    "\[$T\] OK JKEYALL 12 of 12 opens by the real"
    "\[$T\] OK JTRACK "
    "#1|\[$T\] WARN journal watcher \d+: "
    "\[$T\] DEBUG ui journal attach n=4 in \d+ us \(canvas \d+; 'jt' \d+ \(create \d+\); 'jb1' \d+ \(create \d+, in 'jpanel'\); 'jb2' \d+ \(create \d+, in 'jpanel'\); 'jpanel' \d+ \(create \d+, own -?\d+\); place \d+\): 'jt' created .*\(construct\)"
    # Story 20: every open's elements were attached in the Journal's Construct, none at the poll's opened.
    "!\[$T\] DEBUG ui journal attach .*\(Journal opened\)"
    "\[$T\] DEBUG ui journal closed: freed 4 widget handle\(s\)"
    "!\[$T\] ui journal attach left "
    "!\[$T\] WARN (?!journal watcher \d+: |$slowWarnOk)"
    "!\[$T\] ERROR"
    "\[$T\] DEBUG hud tick n=\d+ "
    "\[$T\] JTICK ticks=\d+ "
    "$soft\[$T\] OK JCOSTS "
    "$hard\[$T\] WARN hud slow tick .*steady state\)"
    "?!\[$T\] WARN hud slow tick .*steady state, a Lua GC step"
)
# Story 7 AC 7 unattended: 10 minutes idle in one match with one element and one watcher. The one-minute DEBUG lines
# are judged against story 7's targets below the pattern checks (every event-free window after "SOAK idle": poll
# average under 100 us, steady maximum under 500 us leaving out ticks a Lua collector step landed in; those are
# reported), with the profiler on, so the numbers include its probes.
$soak = $started + @(
    "\[$T\] SCENARIO soak "
    "\[$T\] END result=PASS"
    "#1|\[$T\] hud seed FindAllOf\(InventoryUI_C\) call 1 "
    "\[$T\] SOAK idle "
    "\[$T\] SOAKTICK ticks=\d+ .*findAll=1$"
    "\[$T\] OK SOAKONE "
    "\[$T\] DEBUG ui attach 'soak' created "
    "!\[$T\] WARN (?!ui overlap '|hud slow tick .*(; HUD event: |steady state, a Lua GC step ran inside it))"
    "!\[$T\] ERROR"
    "!\[$T\] WARN hud slow tick .*steady state\)"
    "?!\[$T\] WARN hud slow tick .*steady state, a Lua GC step"
    "?!\[$T\] WARN hud slow tick .*HUD event"
    "?\[$T\] OK SOAKEVENTS "
    "\[$T\] DEBUG hud tick n=\d+ "
    "\[$T\] DEBUG hud prof steady n=\d+ "
)
# Hand testing: only that nothing broke. What the player did (where they went, whether the HUD showed) is not judged;
# the manual test's own caught errors are soft (warn) checks.
# Story 21 (Mod Manager story 2): the menu entry, the menu host and the window stack, one launch written for the VM at
# 1280x720 (run.ps1 -Scenario menu -Target vm). END result=PASS already means every check the test made passed; these
# name the ones the acceptance criteria rest on, plus core's own lines (logged with the test's logger).
$menuChecks = $started + @(
    "\[$T\] SCENARIO menu "
    "\[$T\] OK MSETUP entry and corner text created before any key"
    "\[$T\] OK STARTUP before key: MainMenu_C in viewport=0 "
    "\[$T\] OK STARTUP menu\.isOpen=false, corner text isShown=false"
    # Core registers its menu hooks once, from a poll tick after the first MainMenu_C exists (line order checked below).
    "#1|\[$T\] ui menu hooks registered \(CommonButtonBase:HandleButtonClicked\) after the first menu "
    # Story 34: every menu gets its entry from the poll's opened (within about a second of appearing), the two
    # menus after a map change too; no Lua runs inside MainMenu_C:Construct, so UE4SS never registers a hook on it.
    "#3|\[$T\] ui menu entry 'skel-entry' inserted between OPTIONS and QUIT in \S+ \(poll\), column grew "
    "!\[$T\] ui menu entry 'skel-entry' inserted .*\(construct\)"
    "!Registered script hook .*MainMenu_C:Construct"
    "!\[$T\] WARN ui menu entry"
    "\[$T\] OK MOPEN menu\.isOpen\(\)=true"
    "\[$T\] OK MTEXT corner text isShown on the menu"
    # AC 1 and AC 4: order, pitch, x/width, look (0 fingerprint differences, like OPTIONS vs QUIT) and the backing.
    "\[$T\] OK MORDER menu1 column=\[START GAME, JOIN GAME, CUSTOMIZE, OPTIONS, SKEL ENTRY, QUIT\]"
    "\[$T\] OK MORDER menu2 column=\[START GAME, JOIN GAME, CUSTOMIZE, OPTIONS, SKEL ENTRY, QUIT\]"
    "\[$T\] OK MPITCH menu1 "
    "\[$T\] OK MPITCH menu2 "
    "\[$T\] OK MXW menu1 "
    "\[$T\] OK MXW menu2 "
    "\[$T\] OK MFP menu1 fingerprint diffs entry-vs-OPTIONS=0 \(OPTIONS vs QUIT: 0\)"
    "\[$T\] OK MFP menu2 fingerprint diffs entry-vs-OPTIONS=0 \(OPTIONS vs QUIT: 0\)"
    "\[$T\] OK MGROW menu1 "
    "\[$T\] OK MGROW menu2 "
    "\[$T\] OK MCOVER menu1 "
    "\[$T\] OK MCOVER menu2 "
    "\[$T\] OK MEXTRA menu1 "
    "\[$T\] OK MEXTRA menu2 "
    "\[$T\] OK MEXTRA menu3 "
    # The window stack's limits (I/O matrix: nested windows, a ninth window).
    "\[$T\] OK CASE menu1\.mm-screen-open-ok "
    "\[$T\] OK CASE menu1\.mm-screen-open-again "
    "\[$T\] OK CASE menu1\.mm-screen-handle-write "
    "\[$T\] OK CASE menu1\.mm-screen-open-9 "
    "\[$T\] OK CASE menu1\.mm-screen-top-8 "
    "\[$T\] OK CASE menu1\.mm-screen-isopen-w3 "
    "\[$T\] OK CASE menu1\.mm-screen-close-w1 "
    "\[$T\] OK CASE menu1\.mm-screen-top-none "
    "\[$T\] OK CASE menu1\.mm-screen-isopen-w5 "
    "\[$T\] OK CASE menu1\.mm-screen-close-again "
    "\[$T\] OK MSTACK closed w1 reason api=true, w2\.\.w8 reason parent=7 of 7"
    "\[$T\] OK MSTACK the menu holds keyboard focus"
    # AC 2: keys, hover, the real click.
    "\[$T\] OK MKEY focus on OPTIONS"
    "\[$T\] OK MKEY 1 DOWN: OPTIONS -> SKEL ENTRY"
    "\[$T\] OK MKEY 2 DOWN: SKEL ENTRY -> QUIT"
    "\[$T\] OK MKEY 3 UP: QUIT -> SKEL ENTRY"
    "\[$T\] OK MKEY 4 UP: SKEL ENTRY -> OPTIONS"
    "\[$T\] OK MHOVER "
    "\[$T\] OK MENTRY real click ran onClick exactly once \(1\)"
    "\[$T\] OK MENTRY nothing of the game's opened"
    "#1|\[$T\] MCLICK entry "
    # AC 5-7: the windows.
    "\[$T\] OK MWINA window A open and on top"
    "\[$T\] OK MWINA A's screen widget .* has keyboard focus"
    "\[$T\] OK MWINA A's list holds 40 rows"
    "\[$T\] OK MLOOKGAME fonts: "
    "\[$T\] OK MLOOKGAME brushes: "
    "\[$T\] OK MWINB A's button opened B"
    "\[$T\] OK MWINB B has keyboard focus, A doesn't"
    "\[$T\] OK MWINB A is HitTestInvisible under B"
    "\[$T\] OK MUNDERB "
    "\[$T\] OK MCLOSEB B closed \(reason api\)"
    "\[$T\] OK MCLOSEB A has keyboard focus again"
    "\[$T\] OK MWHEEL scroll offset "
    "\[$T\] OK MCOLS "
    "\[$T\] OK MROW "
    "\[$T\] OK MENTER "
    "\[$T\] OK MCLOSEA Close closed A \(reason close\)"
    "\[$T\] OK MCLOSEA the menu holds keyboard focus"
    "\[$T\] OK MCLOSEA DOWN after the close moves focus into the column"
    # AC 3: OPTIONS and START GAME as without the entry; the menu hidden; no onClick at the entry's last rect.
    "\[$T\] OK MSETTINGS a real click on OPTIONS opened Settings"
    "\[$T\] OK MSETTINGS Settings closed"
    "\[$T\] OK MSTART "
    "\[$T\] OK MHIDDEN the menu's hidden event fired"
    "\[$T\] OK MHIDDEN corner text isShown=false"
    "\[$T\] OK MLASTRECT "
    # The map changes: the menu lost; a window open across a reload lost.
    "\[$T\] OK MLOST "
    "\[$T\] OK MWINC window C lost with the map change"
    "\[$T\] SEVENT \d+ lost id=C "
    # Core story 24 (core 0.8.0): text fitting, images and icons, tooltips, on window IC over the third menu.
    "\[$T\] OK ICWIN window IC open with the icon rows"
    "\[$T\] OK ICCASES ran 70 cases"
    "\[$T\] OK ICHAS core\.has: ui\.image\.create, ui\.overflow, ui\.button\.icon"
    "\[$T\] OK ICROW the five cells of row 1 "
    # IMG: core's icons from core's pak, the five allow-listed game textures loaded by path, the spacer empty.
    "\[$T\] OK IMG ic\.on tex=T_CheckboxOn tint=1\.00,1\.00,1\.00,1\.00"
    "\[$T\] OK IMG ic\.gap tex=none tint=1\.00,1\.00,1\.00,0\.00"
    "\[$T\] OK IMG ic\.g1 tex=checkbox_ticked "
    "\[$T\] OK IMG ic\.g2 tex=checkbox_unticked "
    "\[$T\] OK IMG ic\.g3 tex=T_Settings "
    "\[$T\] OK IMG ic\.g4 tex=reset-icon "
    "\[$T\] OK IMG ic\.g5 tex=T_Question "
    "\[$T\] OK IMG ic\.cfg icon tex=T_Gear tint=0\.36,0\.41,0\.43,0\.55 \(dimmed\)"
    "\[$T\] OK IMG ic\.cfg hover colour 0\.36,0\.41,0\.43,0\.55 "
    # MEASURE: the name cut inside its column, the gear's box exactly 28x28, the image of the same size.
    "\[$T\] OK MEASURE name allotted="
    "\[$T\] OK MEASURE name right="
    "\[$T\] OK MEASURE overflow name policy=1 clipping=1; version \(none\) policy=0 clipping=0"
    "\[$T\] OK MEASURE gear box "
    "\[$T\] OK MEASURE checkbox image "
    "\[$T\] OK MEASURE spacer "
    # TIP: tooltips on the inner widgets, tags unchanged, hit-testable only with a tooltip.
    "\[$T\] OK TIP ic\.cfg Btn tooltip=CONFIGURE, CoreTag "
    "\[$T\] OK TIP ic\.on Img tooltip=ON, Img visibility 0 "
    "\[$T\] OK TIP ic\.ver Text tooltip=VERSION, root ToolTipText=\S+:ic\.ver \(the tag\), Text 0, Background 4"
    "\[$T\] OK TIP ic\.name no tooltip: Text 4, Background 3 "
    "\[$T\] OK TIP ic\.gap no tooltip: Img visibility 3 "
    "\[$T\] OK TIP ic\.dis disabled button: tooltip DISABLED TIP, icon T_Restart, opacity 0\.45"
    "\[$T\] ICDISABLED hovered the disabled button"
    # The dimmed gear still clicks, exactly once.
    "\[$T\] OK ICCLICK the dimmed gear's real click ran onClick exactly once \(1\)"
    "#1|\[$T\] ICCLICK gear "
    "!\[$T\] ICCLICK disabled"
    "\[$T\] OK ICCLOSE window IC closed"
    "!\[$T\] WARN .*(texture|icon|tooltip|overflow)"
    # Mod Manager story 4 (core 0.10.0, UI-11): checkbox, choice and slider-with-number controls on window CT over the
    # third menu, driven by real clicks, a drag and typing (the I/O matrix rows), then SkelPeer's checkbox on the menu.
    "\[$T\] OK CTWIN window CT open with the controls"
    "\[$T\] OK CTCASES ran 85 cases"
    "\[$T\] OK CTHAS core\.has: ui\.slider\.create, ui\.choice\.range, ui\.checkbox\.create"
    "\[$T\] OK CTROW every control is in its row"
    "\[$T\] OK CTCLASS checkbox WBP_${N}Button_C, choice WBP_${N}Choice_C, slider WBP_${N}Slider_C"
    "\[$T\] OK CT checkbox unchecked shows checkbox_unticked"
    "\[$T\] OK CT choice first frame shows ONE, prev enabled=false, next enabled=true"
    "\[$T\] OK CT range shows Default first"
    "\[$T\] OK CT slider s1 bar=150 box=150 hint=DEFAULT \(100\)"
    "\[$T\] OK CT slider s2 bar=5 box=5"
    "\[$T\] OK CT disabled row dimmed "
    "\[$T\] CTSTYLE template="
    "\[$T\] OK CTSTYLE the slider bar matches"
    "\[$T\] OK CT isShown true for the controls"
    # Checkbox click (onChange(h, true) once) and set (no callback).
    "\[$T\] OK CT checkbox click value=true calls=1 shows checkbox_ticked"
    "\[$T\] OK CT checkbox set false then true: no callback \(calls=1\)"
    # Choice arrows: next, next, prev -> option 2, three callbacks; no wrap at 1; the range's next.
    "\[$T\] OK CT choice next next prev value=2 TWO calls=3 shows TWO"
    "\[$T\] OK CT range next value=2 0 calls=1"
    "\[$T\] OK CT choice set\(1\): no callback, prev disabled"
    "\[$T\] OK CT choice prev at option 1 does nothing"
    # Slider: a drag (one callback at its end, the box followed it), typing 57, 999, abc, empty; step 0.5 typed 2.3.
    "\[$T\] OK CT slider drag value=\d+ calls=1"
    "\[$T\] OK CT slider drag box="
    "\[$T\] OK CT slider drag: Lua heard one drag end, no drag frames \(1\)"
    "\[$T\] OK CT slider typed 57 value=57 calls=2 box=57"
    "\[$T\] OK CT slider typed 999 value=200 calls=3 box=200"
    "\[$T\] OK CT slider typed abc value=200 calls=3 box=200"
    "\[$T\] OK CT slider emptied value=nil calls=4 box='' hint=DEFAULT \(100\) bar=100"
    "\[$T\] OK CT slider setDefault\(120\) moved the Default slider to 120"
    "\[$T\] OK CT slider step 0\.5 typed 2\.3 value=2\.5 calls=1"
    # Disabled: dimmed; a click, a drag and typing change nothing, no callback.
    "\[$T\] OK CT disabled click/drag/type: values unchanged \(true, 3, 4; box 4\), calls=0"
    "!\[$T\] CTCB ct\.d"
    # Reopen: values and enabled state kept; the new widget takes clicks, the old ones are gone.
    "\[$T\] OK CTREOPEN the controls are back"
    "\[$T\] OK CTREOPEN values kept: "
    "\[$T\] OK CTREOPEN the disabled row is still disabled"
    "\[$T\] OK CTREOPEN get\(\) unchanged"
    "\[$T\] OK CTREOPEN the new choice widget takes clicks"
    # onChange exactly once per real change: the callback lines this test logged, in all.
    "#1|\[$T\] CTCB ct\.cb "
    "#4|\[$T\] CTCB ct\.ch "
    "#1|\[$T\] CTCB ct\.rg "
    "#4|\[$T\] CTCB ct\.s1 "
    "#1|\[$T\] CTCB ct\.s2 "
    # Two mods: SkelPeer's checkbox heard its own click only; this mod's callbacks didn't run for it.
    "\[$Peer\] PEER ready: checkbox 'peer\.cb' created"
    "#1|\[$Peer\] PEERCB \d+ "
    "\[$Peer\] PEERCB 1 'peer\.cb' true"
    "!\[$Peer\] (ERROR|WARN (?!$slowWarnOk))"
    "\[$T\] OK CTPEER a click on SkelPeer's checkbox ran none of this mod's callbacks"
    # The controls' own failures: none.
    "!\[$T\] WARN (checkbox|choice|slider) "
    "!\[$T\] WARN .*(click handling failed|RegisterHook failed|can't be hooked)"
    "#1|\[$T\] (OK|FAIL) CTSTYLE "
    # Core story 27 (UI-12): the card, BACK, the compact gap, keyboard and gamepad focus (window KB), then story 26's
    # window and a Mod-Manager-shaped one in the card (CARD, GEOM). Each KFOCUS line: the model and HasKeyboardFocus agree.
    "\[$T\] OK KBCASES ran 18 cases"
    "\[$T\] OK KNOCLOSE Escape on a close = false window: it stays open"
    "\[$T\] OK KFOCUS KB kb\.t1 "
    "\[$T\] OK KLOOK the focused TOGGLE shows its focus look"
    "\[$T\] OK KLOOK off: the TOGGLE that lost focus shows its own normal brush again "
    "\[$T\] OK KLOOK repeat: after a UI tick the focused TOGGLE keeps its own style saved "
    "\[$T\] OK CARD KB centred: "
    "\[$T\] OK CARD KB hugs: "
    "\[$T\] OK CARD KB contains: "
    "\[$T\] OK CARD KB padding "
    "\[$T\] OK CARD KB BACK bottom-left "
    "#3|\[$T\] OK KFOCUS KB kb\.t2 "
    "#2|\[$T\] OK KFOCUS KB kb\.g2 "
    "\[$T\] OK KCLICK Enter on the focused TOGGLE ran its onClick exactly once \(1\)"
    "#1|\[$T\] KCB kb\.t2 "
    "!\[$T\] KCB kb\.(t[13-9]|t1[0-2]|g)"
    "\[$T\] OK KFOCUS KB kb\.t10 "
    "\[$T\] OK KSCROLL row 10 "
    "\[$T\] OK KFOCUS KB kb\.t12 "
    "#2|\[$T\] OK KFOCUS KB kb\.ch "
    "\[$T\] OK KCHOICE Right on the focused choice: option 2, onChange 1"
    "\[$T\] OK KCHOICE Enter on the focused choice: nothing changes"
    "#1|\[$T\] KCB kb\.ch "
    "#2|\[$T\] OK KFOCUS KB kb\.sl "
    "\[$T\] OK KSLIDER Right on the Default slider: 6 \(defaultValue \+ step\), onChange 1"
    "\[$T\] OK KSLIDER Left: 5, onChange 2"
    "#2|\[$T\] KCB kb\.sl "
    "\[$T\] OK KFOCUS KB #close:KB "
    "\[$T\] OK KFOCUS KB2 #close:KB2 "
    "\[$T\] OK KCLOSE reason=close Escape closed the top window KB2 only"
    "\[$T\] OK KRETURN KB got its last-focused element back \(#close:KB\)"
    "\[$T\] OK KCLOSE reason=close Escape closed KB, no window left"
    "\[$T\] OK KRETURN the menu holds keyboard focus again"
    "\[$T\] SEVENT \d+ closed id=KB2 reason=close"
    "\[$T\] SEVENT \d+ closed id=KB reason=close"
    "!\[$T\] SEVENT \d+ closed id=KBN reason=close"
    "\[$T\] GEOM CT list box "
    "\[$T\] GEOM CT row ct\.row1 "
    "\[$T\] OK GEOM CT no-clip: "
    "\[$T\] OK GEOM CT-checkbox no-clip: "
    "\[$T\] OK GEOM CT-checkbox fixed-size last children arranged at their desired size"
    "\[$T\] OK CARD CT centred: "
    "\[$T\] OK CARD CT hugs: "
    "\[$T\] OK CARD CT contains: "
    "\[$T\] GEOM KBM row kbm\.r1 "
    "\[$T\] OK GEOM KBM no-clip: "
    "\[$T\] OK GEOM KBM fixed-size last children arranged at their desired size"
    "\[$T\] OK CARD KBM centred: "
    "\[$T\] OK CARD KBM hugs: "
    "\[$T\] OK CARD KBM contains: "
    "\[$T\] OK CARD KBM BACK bottom-left "
    "\[$T\] OK KFOCUS KBM kbm\.g1 "
    # Core story 28: the focused row shows the selection, the others their worn strip; the focused dimmed icon-only gear
    # has a focus face; after DOWN both move to row 2. Core story 30: the strong selection (an instance of it with the
    # theme's fill colours).
    "\[$T\] OK KLOOK row: the focused row kbm\.r1 shows the strong selection "
    "\[$T\] OK KLOOK row: the unfocused row kbm\.r2 shows its worn strip "
    "\[$T\] OK KLOOK face: the focused gear kbm\.g1 shows a focus face "
    "\[$T\] OK KLOOK face off: the unfocused gear kbm\.g2 has no face "
    "\[$T\] OK KFOCUS KBM kbm\.g2 "
    "\[$T\] OK KLOOK row: the focused row kbm\.r2 shows the strong selection "
    "\[$T\] OK KLOOK row: the unfocused row kbm\.r1 shows its worn strip "
    "\[$T\] OK KLOOK face: the focused gear kbm\.g2 shows a focus face "
    "\[$T\] OK KLOOK face off: the unfocused gear kbm\.g1 has no face "
    "\[$T\] OK KBEND every window closed"
    "!\[$T\] WARN .*(window key|focus look|focus face|focus highlight|restoring its own|focus window|focus tick|focusing it failed|focused row|keyboard focus|input mode|clicked element|card|re-fit|BACK button|NavHandled)"
    "\[$T\] END result=PASS"
)
# Core story 24: the ic-* group, on window IC (menu3), and every new function off the game thread.
foreach ($id in 'style-key', 'overflow-bad', 'overflow-num', 'overflow-button', 'overflow-panel', 'overflow-list', 'overflow-row', 'overflow-clip-ok',
                'img-none', 'img-args', 'img-unknown', 'img-id', 'img-kindid', 'img-src-path', 'img-src-long', 'img-src-icon', 'img-src-two',
                'img-src-empty', 'img-src-str', 'img-src-key', 'img-size-3', 'img-size-600', 'img-size-str', 'img-size-inf', 'img-size-key',
                'img-tint', 'img-style-key', 'img-dimmed', 'img-tip-hud', 'img-hud-ok', 'set-empty', 'set-unknown', 'set-dimmed', 'set-src',
                'set-str', 'set-args', 'set-forged', 'set-text', 'set-ok', 'setvis-num', 'setvis-ok', 'isshown-text', 'isshown-ok',
                'remove-forged', 'remove-ok', 'remove-again', 'removed', 'tip-empty', 'tip-513', 'tip-noen', 'tip-ctrl', 'tip-num', 'tip-tag',
                'tip-17', 'tip-args', 'tip-forged', 'btip-text', 'itip-button', 'tip-newline-ok', 'tip-hud', 'tip-place-hud', 'tip-clear-ok',
                'btn-icon-star', 'btn-icon-path', 'btn-iconsize-600', 'btn-iconsize-noicon', 'btn-dimmed', 'btn-tip-empty', 'btn-size',
                'btn-icon-ok',
                'off-image-create', 'off-image-set', 'off-image-setvis', 'off-image-remove', 'off-image-isshown', 'off-image-settip',
                'off-text-settip', 'off-button-settip') {
    $menuChecks += "\[$T\] OK CASE menu3\.ic-$id "
}
# Mod Manager story 4: the ct-* group, on window CT (menu3), and every new function off the game thread.
foreach ($id in 'cb-none', 'cb-args', 'cb-unknown', 'cb-onchange', 'cb-size-8', 'cb-size-65', 'cb-checked', 'cb-enabled', 'cb-hud', 'cb-kindid',
                'cb-set-num', 'cb-get-choice', 'cb-get-forged', 'cb-setenabled', 'cb-setvis', 'cb-isshown-slider', 'cb-tip', 'cb-tip-create', 'cb-place', 'cb-remove-forged', 'cb-remove-slider', 'cb-label-button', 'cb-ok',
                'ch-none', 'ch-unknown', 'ch-empty', 'ch-65', 'ch-nonstring', 'ch-long', 'ch-sel-7', 'ch-sel-0', 'ch-onchange', 'ch-game', 'ch-widget',
                'ch-hud', 'ch-enabled', 'ch-tip-create', 'ch-place', 'ch-hole', 'ch-key', 'ch-setvis', 'ch-remove-forged', 'ch-isshown-checkbox',
                'ch-tip', 'ch-set-7', 'ch-get-slider', 'ch-get-forged', 'ch-setenabled', 'ch-ok',
                'rg-65', 'rg-extra-65', 'rg-step-0', 'rg-minmax', 'rg-inf', 'rg-extra', 'rg-unknown', 'rg-ok',
                'sl-none', 'sl-unknown', 'sl-minmax', 'sl-step-0', 'sl-steps', 'sl-value-out', 'sl-value-nan', 'sl-default-out', 'sl-default-inf',
                'sl-hint-65', 'sl-onchange', 'sl-hud', 'sl-enabled', 'sl-tip-create', 'sl-place', 'sl-setenabled', 'sl-setvis',
                'sl-remove-choice', 'sl-isshown-forged', 'sl-tip', 'sl-set-out', 'sl-set-noarg', 'sl-setdefault-nil', 'sl-setdefault-hint', 'sl-get-checkbox',
                'sl-get-forged', 'sl-ok', 'removed',
                'off-cb-create', 'off-cb-get', 'off-cb-set', 'off-cb-setenabled', 'off-cb-setvis', 'off-cb-remove', 'off-cb-isshown', 'off-cb-settip',
                'off-ch-create', 'off-ch-get', 'off-ch-set', 'off-ch-range', 'off-ch-setenabled', 'off-ch-setvis', 'off-ch-remove', 'off-ch-isshown',
                'off-ch-settip', 'off-sl-create', 'off-sl-get', 'off-sl-set', 'off-sl-setdefault', 'off-sl-setenabled', 'off-sl-setvis', 'off-sl-remove',
                'off-sl-isshown', 'off-sl-settip') {
    $menuChecks += "\[$T\] OK CASE menu3\.ct-$id "
}
# Core story 27: the kb-* group, on window KB (menu3): gap values and texts, every hook-noise row, an off-thread nav call,
# focus with nothing focusable, the feature names.
foreach ($id in 'gap-compact', 'gap-default', 'gap-row-compact', 'gap-tiny', 'gap-row-tiny', 'gap-place-compact', 'gap-panel-compact',
                'nav-dir-99', 'nav-act-neg', 'nav-handled', 'nav-foreign', 'nav-stale', 'nav-throwing-tag', 'nav-closed', 'nofocus', 'nofocus-keys',
                'has-focus', 'nav-offthread') {
    $menuChecks += "\[$T\] OK CASE menu3\.kb-$id "
}
# Core story 31 (UI-13, core 0.13.0): core.ui.game's bad-input group, in both worlds and off the game thread.
$gameCaseIds = @('watch-nope', 'watch-num', 'watch-nil', 'watch-menu', 'watch-case', 'isopen-menu', 'isopen-nil', 'isopen-table', 'isopen-two',
                 'watch-fn5', 'watch-nofn', 'watch-fnstr', 'watch-three', 'unwatch-forged', 'unwatch-menutoken', 'unwatch-float', 'unwatch-str',
                 'unwatch-nil', 'unwatch-two', 'place-near', 'place-region', 'elements', 'isopen-ok', 'watch-ok', 'unwatch-ok', 'unwatch-again', 'has')
foreach ($p in 'menu1', 'match1') {
    foreach ($id in $gameCaseIds) { $badInput += "\[$T\] OK CASE $p\.ui-game-$id " }
    foreach ($id in 'watch', 'unwatch', 'isopen') { $badInput += "\[$T\] OK CASE $p\.off-ui-game-$id " }
}
# Core story 32 (UI-14, core 0.14.0): the game-container intent's bad-input group (gameinsert.lua), in both worlds.
$insCaseIds = @('cont-num', 'cont-empty', 'cont-65', 'cont-path', 'cont-digit', 'anchor-num', 'anchor-empty', 'anchor-65', 'anchor-name',
                'anchor-table', 'two', 'two-at', 'none', 'index-0', 'index-frac', 'index-257', 'index-nan', 'index-str', 'at-start', 'corner',
                'gap', 'near', 'absolute', 'offset', 'hud', 'menu', 'journal', 'screen', 'key', 'nocont', 'panel', 'list', 'row', 'ok', 'place-bad', 'place-hud',
                'isshown', 'remove', 'has')
foreach ($p in 'menu1', 'match1') {
    foreach ($id in $insCaseIds) { $badInput += "\[$T\] OK CASE $p\.ui-ins-$id " }
}
# Core story 31: the create-server screen as a host, one launch written for the VM at 1280x720 (run.ps1 -Scenario
# createserver -Target vm). END result=PASS already means every check the test made passed; these name the ones the
# acceptance criteria rest on.
$createServer = $started + @(
    "\[$T\] SCENARIO createserver "
    "\[$T\] OK CSSETUP watcher, text and checkbox on host createServer before any key"
    "\[$T\] OK CSNONE no create-server screen yet"
    # AC 1: ten real opens and Backs: ten opened (each with the text and the checkbox in CanvasPanel_21, a new text
    # widget each time), ten closed, ten distinct screens, no lost.
    "#10|\[$T\] OK CSOPENED \d+ menu1: "
    "#10|\[$T\] OK CSCLOSED-BACK \d+ closed "
    "\[$T\] OK CSEVENTS 10 opens: opened=10 closed=10 lost=0"
    "\[$T\] OK CSDISTINCT 10 opens, 10 distinct paths"
    "\[$T\] OK CSNEWTEXT 10 opens, 10 distinct text widgets"
    "\[$T\] OK CSNOLOST no lost before Create"
    "\[$T\] OK CSCHECK a real click on the checkbox "
    "#1|\[$T\] CSCHANGE 1 true"
    # Poll-first (story 34): no hook on the screen's class.
    "!Registered script hook .*CreateServer_C"
    # AC 2: Create (friends-only only), the map change: closed or lost, no error after it; the next menu works.
    "\[$T\] OK CSOPENED 11 create: "
    "\[$T\] OK CSFRIENDS the screen is set to Friends-Only \(FriendsOnly=true, "
    "\[$T\] WORLD match "
    "\[$T\] OK CSCREATE after Create and the map change: (closed|lost) for the screen "
    "\[$T\] OK CSMATCHNONE "
    "\[$T\] CSMATCH window 1 "
    "\[$T\] CSMATCH end "
    "\[$T\] WORLD menu2 "
    "\[$T\] OK CSOPENED 12 menu2: "
    "\[$T\] OK CSMENU2 closed "
    # AC 4: the bad-input group (before connect, on the game thread, off it).
    "\[$T\] OK CASES game before-connect recorded=3"
    "\[$T\] DEBUG hud tick n=\d+ "
    "!\[$T\] WARN (?!$slowWarnOk)"
    "!\[$T\] ERROR"
    "\[$T\] END result=PASS"
)
foreach ($id in 'pre-game-watch', 'pre-game-unwatch', 'pre-game-isopen') { $createServer += "\[$T\] OK CASE $id " }
foreach ($id in $gameCaseIds) { $createServer += "\[$T\] OK CASE menu1\.ui-game-$id " }
foreach ($id in 'watch', 'unwatch', 'isopen') { $createServer += "\[$T\] OK CASE menu1\.off-ui-game-$id " }
# Core story 32: elements inside the create-server screen's settings list (VerticalBox_202), one launch written for the
# VM at 1280x720 (run.ps1 -Scenario gameinsert -Target vm). END result=PASS already means every check the test made
# passed; these name the ones the acceptance criteria rest on. No session is made (Create is never clicked).
$gameInsert = $started + @(
    "\[$T\] SCENARIO gameinsert "
    "\[$T\] OK GISETUP "
    "\[$T\] OK GISNAP VerticalBox_202 before any container element: \d+ game rows, none of ours \(0\)"
    # Review loop 1 (Design Note 8): made while open, attached on the next tick, one rebuild for all of them.
    "\[$T\] OK GICREATE 21 texts and a checkbox made while the screen is open: none attached in the call \(true\), .*; 1 rebuild\(s\) for all"
    # AC 1-2: five after Overlay_28 (children 2-6), fourteen after Overlay_738, in creation order; every game row's order
    # and slot values against the snapshot; one widget per element. Made while open, ten opens, the final open, after
    # the picker clicks, after the preset and after the late creates.
    "#15|\[$T\] OK GIORDER "
    "#15|\[$T\] OK GISLOTS .*: \d+ game rows in their order with the snapshot's slot values"
    "#15|\[$T\] OK GIONE "
    # Ten opens by real clicks: one rebuild per open, new widgets each time.
    "#10|\[$T\] OK GIREBUILD open \d+: VerticalBox_202 rebuilt 1 time\(s\)"
    "#10|\[$T\] OK GINEW open \d+: "
    "\[$T\] OK GITEN 10 opens by real clicks: .*; 10 distinct screens, 10 distinct knob widgets, lost=0"
    "#12|\[$T\] OK GIOPENED \d+ "
    "#12|\[$T\] OK GICLOSED \d+ "
    "\[$T\] OK GIEVENTS opened=12 closed=12 lost=0"
    # AC 3: the unknown anchor (last) and the unknown container (not attached): one WARN each in the whole run.
    "#1|\[$T\] WARN ui createServer: anchor 'Overlay_NOPE' is not a child of 'VerticalBox_202'"
    "#1|\[$T\] WARN ui createServer: container 'VerticalBox_NOPE' is missing"
    # AC 4: the game's own controls after the rebuild.
    "\[$T\] OK GICONFIG "
    "\[$T\] OK GIDIFF a real click on the Difficulty picker's arrow changed it"
    "\[$T\] OK GILOBBY a real click on Lobby Time's arrow"
    "\[$T\] OK GIPNAME "
    "\[$T\] OK GISAVE a real click on SAVE WORLD PRESET saved "
    "\[$T\] OK GILOBBY2 "
    "\[$T\] OK GILOAD loading "
    "\[$T\] OK GIDELETE a real click on DELETE removed "
    # AC 5 (review loop 1): the checkbox in the list takes a real click; two creates while open with Lobby Time changed:
    # one rebuild on the next tick, Lobby Time (a rebuilt row) keeps the player's value.
    "\[$T\] OK GICB a real click on the checkbox in VerticalBox_202 \(at end\) ran onChange once with true \(1 call"
    "\[$T\] OK GILATELOBBY "
    "\[$T\] OK GILATE two texts made while open: not attached in the call \(true\), .*, 1 rebuild\(s\) for both"
    "\[$T\] OK GILATEKEEP "
    # Poll-first (story 34): no hook on the screen's class.
    "!Registered script hook .*CreateServer_C"
    "!\[$T\] WARN (?!$slowWarnOk|ui createServer: anchor 'Overlay_NOPE' |ui createServer: container 'VerticalBox_NOPE' )"
    "!\[$T\] ERROR"
    "\[$T\] END result=PASS"
)
foreach ($id in $insCaseIds) { $gameInsert += "\[$T\] OK CASE menu1\.ui-ins-$id " }
$manual = @(
    "\[$T\] SCENARIO manual "
    "\[$T\] CONNECT ok $N $Ver "
    "\[$T\] ATTACH 1 "
    "\[$T\] DEBUG ui attach 'manual' (created|reused) "
    "!\[$T\] FAIL "
    "!\[$T\] ERROR"
    "!\[$N\] ERROR"
    "?!\[$T\] WARN manual "
)
# Core story 22: the pair-run roles (test/pair/nucleus-scenarios.ps1). net-host / net-vanilla-host judge the host's log
# (the host can't tell a modded B from a vanilla one, so both are the same checks), net-client B's.
$netHost = $started + @(
    "\[$T\] SCENARIO net-host "
    "\[$T\] NETROLE net-host "
    "\[$N\] NET world .* role=host"
    "\[$N\] NET spawned ${N}Net_C_\d+ in .* replicates=true alwaysRelevant=true owner=none "
    "\[$T\] NETPUB skeltest\.revivesN=8 ok=true result=true server=\S+ us=\d+ players=[01]\s*$"
    "\[$T\] NETPUB skeltest\.enemyDamage=250 ok=true result=true server=\S+ us=\d+ players=[01]\s*$"
    "\[$T\] NETPUB nuclearnightmare-community\.skeltest-ns\.x=1 ok=true result=published "
    "\[$T\] NETHOST PlayerArray holds 2 players "
    "\[$T\] NETPUB skeltest\.enemyDamage=260 ok=true result=true server=\S+ us=\d+ players=2\s*$"
    "\[$T\] OK NETHOST ${N}Net count=1 authority=true"
    "\[$T\] END result=PASS"
    "!\[$N\] (ERROR|WARN) NET"
)
$netClient = $started + @(
    "\[$T\] SCENARIO net-client "
    "\[$T\] NETROLE net-client "
    "\[$N\] NET world .* role=client"
    "\[$N\] NET holding ${N}Net_C_\d+ \(NotifyOnNewObject\) "
    "!\[$N\] NET spawned"
    "\[$T\] NETWATCH skeltest\.revivesN value=8 why=nil role=client "
    "\[$T\] NETWATCH skeltest\.enemyDamage value=250 why=nil role=client "
    "\[$T\] NETWATCH skeltest\.enemyDamage value=260 why=nil role=client "
    "\[$T\] NETWATCH nuclearnightmare-community\.skeltest-ns\.x value=1 why=nil role=client "
    "\[$T\] OK NETCLIENT read enemyDamage 0\.\.200 -> nil, out-of-bounds"
    "#1|\[$T\] WARN $N\.net: skeltest\.enemyDamage = \d+ is outside this mod's bounds 0\.\.200"
    "\[$T\] OK NETCLIENT publish raised: $([regex]::Escape($name.ToLower()))\.net\.publish: only the host publishes \(this machine is a client\)"
    "\[$T\] OK NETCLIENT channel op on a client -> err:client "
    "\[$T\] OK NETCLIENT ${N}Net count=1 authority=false"
    "\[$T\] OK NETCLIENT after the match started: revivesN=8 enemyDamage=2[56]0 "
    "\[$T\] OK NETCLIENT watch saw enemyDamage=260"
    "\[$T\] END result=PASS"
    "!\[$N\] WARN NET (ignoring|dropped)"
    "!\[$N\] ERROR"
)
# Core story 23: the presence pair-run roles (test/pair/nucleus-scenarios.ps1). presence-host judges the host's log of
# the presence run (join, the forge sequence, B's leave), presence-client B's, presence-vanilla-host the host's log with
# an unmodded B. The cross-machine timings (join within 2 s of the controller, leave within 2 s) are computed by the
# scenario's Check from both logs.
$Lo = [regex]::Escape($name.ToLower())
$presenceCommon = $started + @(
    "\[$N\] NET world .* role=host"
    "\[$N\] PRESENCE hooked .*${N}Presence_C:${N}_PresenceIn"
    "\[$N\] PRESENCE saw controller \S+ \(player \S+\) server=[\d.]+ "
    "#1|\[$N\] PRESENCE spawned ${N}Presence_C_\d+ for \S+ \(player \S+, try 1\) replicates=true alwaysRelevant=true owner=\S+ server="
    "!\[$N\] PRESENCE spawned ${N}Presence_C_\d+ .* owner=none "
    "\[$T\] OK PRESENCE host record pid=-?\d+ $Lo=$Ver,skeltest=0\.1\.0 "
    "\[$T\] END result=PASS"
    "!\[$N\] ERROR"
)
$presenceHost = $presenceCommon + @(
    "\[$T\] SCENARIO presence-host "
    "\[$T\] PRESENCEROLE presence-host "
    "\[$T\] PRESENCEEV joined pid=-?\d+ mod=skeltest version=0\.1\.0 previous=nil local=false server=[\d.]+"
    "\[$T\] OK PRESENCE joined b=-?\d+ $Lo=$Ver,skeltest=0\.1\.0 "
    "\[$T\] OK PRESENCE step=0 host=$Lo=$Ver,skeltest=0\.1\.0 b=$Lo=$Ver,skeltest=0\.1\.0 "
    "\[$T\] OK PRESENCE step=1 host=$Lo=$Ver,skeltest=0\.1\.0 b=$Lo=$Ver,skeltest=0\.1\.0 "
    "\[$T\] OK PRESENCE step=2 host=$Lo=$Ver,skeltest=0\.1\.0 b=$Lo=$Ver,skeltest=0\.1\.0 "
    "\[$T\] OK PRESENCE step=3 host=$Lo=$Ver,skeltest=0\.1\.0 b=$Lo=$Ver,skeltest-forge=1\.0\.0 "
    "\[$T\] OK PRESENCE step=4 host=$Lo=$Ver,skeltest=0\.1\.0 b=$Lo=$Ver,skeltest=7\.7\.7 "
    "\[$T\] OK COMPAT b=true\s*$"
    "\[$T\] OK COMPAT b=false incompatible\s*$"
    "\[$T\] PRESENCE forge-done "
    "#1|\[$N\] WARN PRESENCE (rejected|dropped) "
    "\[$T\] PRESENCEEV left pid=-?\d+ mod=$Lo version=nil previous=$Ver local=false "
    "\[$T\] PRESENCEEV left pid=-?\d+ mod=skeltest version=nil previous=7\.7\.7 local=false "
    "\[$T\] OK PRESENCE b-left mods=$Lo,skeltest presence=nil,absent "
    "\[$N\] PRESENCE player -?\d+ left \(\S+\): 2 mod\(s\) removed \($Lo=$Ver,skeltest=7\.7\.7\); destroyed ${N}Presence_C_\d+ "
    "\[$T\] OK PRESENCE ${N}Presence count=0 after B left "
)
$presenceVanillaHost = $presenceCommon + @(
    "\[$T\] SCENARIO presence-vanilla-host "
    "\[$T\] PRESENCEROLE presence-vanilla-host "
    "\[$T\] OK PRESENCE vanilla: ${N}Presence count=1 owned by another player's controller=true"
    "\[$T\] OK PRESENCE vanilla: no event for another player \(0\)"
    "!\[$N\] PRESENCE record player "
    "!\[$T\] PRESENCEEV joined .* local=false "
)
$presenceClient = $started + @(
    "\[$T\] SCENARIO presence-client "
    "\[$T\] PRESENCEROLE presence-client "
    "\[$N\] NET world .* role=client"
    "\[$N\] PRESENCE holding ${N}Presence_C_\d+ \((NotifyOnNewObject|FindAllOf)\) "
    "#1|\[$N\] PRESENCE report sent \(first\) on ${N}Presence_C_\d+: $Lo=$Ver,skeltest=0\.1\.0 server="
    "!\[$N\] PRESENCE spawned"
    "!\[$N\] WARN PRESENCE ignoring"
    "\[$T\] OK PRESENCECL presence raised: $Lo\.net\.presence: only the host knows presence \(this machine is a client\)"
    "\[$T\] OK PRESENCECL watchPresence raised: $Lo\.net\.watchPresence: only the host knows presence \(this machine is a client\)"
    "\[$T\] OK PRESENCECL compatible raised: $Lo\.net\.compatible: only the host knows presence \(this machine is a client\)"
    "\[$T\] PRESENCECL holding ${N}Presence_C_\d+ "
    "\[$T\] OK PRESENCECL forge step=0 sent=1 "
    "\[$T\] OK PRESENCECL forge step=1 sent=1 "
    "\[$T\] OK PRESENCECL forge step=2 sent=1 bytes=9000 "
    "\[$T\] OK PRESENCECL forge step=3 sent=1 "
    "\[$T\] OK PRESENCECL forge step=4 sent=50 "
    "\[$T\] PRESENCECL leaving server=[\d.]+"
    "\[$T\] OK PRESENCECL back in the menu"
    "\[$T\] END result=PASS"
    "!\[$N\] ERROR"
)
$expect = @{
    'presence-host' = $presenceHost
    'presence-vanilla-host' = $presenceVanillaHost
    'presence-client' = $presenceClient
    'net-host'  = $netHost
    'net-vanilla-host' = $netHost
    'net-client' = $netClient
    'skeleton'  = $skeleton
    'ui'        = $ui
    'journal'   = $journal
    'menu'      = $menuChecks
    'createserver' = $createServer
    'gameinsert' = $gameInsert
    'soak'      = $soak
    'manual'    = $manual
    'bad-input' = $badInput
    'no-native' = @(
        "#1|\[$N\] "
        "\[$N\] ERROR native part is not loaded"
        "\[$T\] NATIVE main\.lua ${N}_NativeVersion missing"
        "\[$T\] ERROR $N's native part is not loaded .* $T will not run\."
        "!\[$N\] CHANNEL hooked"
        "\[$T\] SIGNAL $([regex]::Escape($name.ToLower()))\.map\.setup=none\s*$" # map service story 9: the signal stays none
        "\[$T\] END result=FAIL .*reason=connect"
    )
    'no-pak' = @(
        "\[$N\] READY version=$Ver"
        "#1|\[$N\] ERROR MISSING $N's Blueprint content is not installed"
        "\[$T\] ERROR $N's Blueprint content is not installed \(Content/Paks/LogicMods/$N\.pak\)\. $T will not run\."
        "!\[$N\] CHANNEL hooked"
        "\[$T\] SIGNAL $([regex]::Escape($name.ToLower()))\.map\.setup=none\s*$" # map service story 9: the signal stays none
        "\[$T\] END result=FAIL .*reason=connect"
    )
}

$failed = 0
$warned = 0
Write-Host "--- checks ($Scenario) ---"
foreach ($pattern in ($always + $expect[$Scenario])) {
    if ($pattern.StartsWith('#')) {
        $count, $p = $pattern.Substring(1) -split '\|', 2
        $hits = @($lines | Where-Object { $_ -match $p }).Count
        $ok = $hits -eq [int]$count
        $label = "$pattern (found $hits)"
    } elseif ($pattern.StartsWith('?!')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(2) }) { Write-Host "warn: $pattern"; $warned++ } else { Write-Host "ok:   $pattern" }
        continue
    } elseif ($pattern.StartsWith('?')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(1) }) { Write-Host "ok:   $pattern" } else { Write-Host "warn: $pattern"; $warned++ }
        continue
    } elseif ($pattern.StartsWith('!')) {
        $ok = -not ($lines | Where-Object { $_ -match $pattern.Substring(1) })
        $label = $pattern
    } else {
        $ok = [bool]($lines | Where-Object { $_ -match $pattern })
        $label = $pattern
    }
    if ($ok) { Write-Host "ok:   $label" } else { Write-Host "FAIL: $label"; $failed++ }
}
if ($Scenario -eq 'bad-input') {
    # Story 18 AC 4: core.features() in the test dependent equals the list core's READY line shows.
    $ready = @($lines | Where-Object { $_ -match "\[$N\] READY .* features=(\S+)" } | ForEach-Object { $Matches[1] }) | Select-Object -Last 1
    $seen = @($lines | Where-Object { $_ -match "\[$T\] FEATURES (\S+)" } | ForEach-Object { $Matches[1] }) | Select-Object -Last 1
    if ($ready -and $ready -eq $seen) { Write-Host "ok:   core.features() equals the READY line's features ($ready)" }
    else { Write-Host "FAIL: core.features() ($seen) differs from the READY line's features ($ready)"; $failed++ }
}
if ($Scenario -eq 'bad-input') {
    # Mod Manager story 5 AC 1: the test dependent's settings.json after the run holds the values set during it
    # (SkelPeer's test.count, the title-screen test.mode, the restart test.boot) and nothing else, with no .tmp or .bak.
    if ($Instance) {
        $sdir = Join-Path (Resolve-Path $Instance) "NuclearNightmare\Binaries\Win64\ue4ss\Mods\$t"
        $sfile = Join-Path $sdir 'settings.json'
        $vals = $null
        try { $vals = Get-Content $sfile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { }
        $want = [ordered]@{ 'test.count' = 42; 'test.mode' = 'b'; 'test.boot' = 77 }
        $okVals = $vals -and $vals.Count -eq $want.Count -and -not @($want.Keys | Where-Object { $vals[$_] -ne $want[$_] })
        $raw = if (Test-Path $sfile) { (Get-Content $sfile -Raw) } else { '(missing)' }
        if ($okVals) { Write-Host "ok:   $t's settings.json holds test.count=42, test.mode=b, test.boot=77 and nothing else ($raw)" }
        else { Write-Host "FAIL: $t's settings.json should hold test.count=42, test.mode=b, test.boot=77 and nothing else; it holds $raw"; $failed++ }
        $left = @('settings.json.tmp', 'settings.json.bak' | Where-Object { Test-Path (Join-Path $sdir $_) })
        if (-not $left) { Write-Host "ok:   no settings.json.tmp or .bak left in Mods/$t" }
        else { Write-Host "FAIL: left in Mods/$($t): $($left -join ', ')"; $failed++ }
    } else { Write-Host "warn: no -Instance: $t's settings.json not read back"; $warned++ }
}
if ($Scenario -eq 'net-client') {
    # Core story 22 AC 1: B reads both values within 1 s of core first holding the host's <name>Net (one clock: core's
    # ClockMicros, read by core's state and by the test dependent in the same process).
    $hold = @($lines | Where-Object { $_ -match "\[$N\] NET holding .* us=(\d+)" } | ForEach-Object { [int64]$Matches[1] }) | Select-Object -First 1
    foreach ($k in @(@('revivesN', '8'), @('enemyDamage', '250'))) {
        $at = @($lines | Where-Object { $_ -match "\[$T\] NETWATCH skeltest\.$($k[0]) value=$($k[1]) .* us=(\d+)" } | ForEach-Object { [int64]$Matches[1] }) | Select-Object -First 1
        if ($null -ne $hold -and $null -ne $at -and ($at - $hold) -le 1000000) { Write-Host ("ok:   B read {0}={1} {2:N0} us after core first held the actor (limit 1 s)" -f $k[0], $k[1], ($at - $hold)) }
        else { Write-Host "FAIL: B's read of $($k[0])=$($k[1]) (us=$at) is not within 1 s of core first holding the actor (us=$hold)"; $failed++ }
    }
}
if ($Scenario -eq 'menu') {
    # Story 21: no menu hook before a MainMenu_C exists. The test logs STARTUP while none is in the viewport, just before
    # it presses Enter; core's one hooks line must come after it.
    $startup = [Array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match "\[$T\] OK STARTUP before key: MainMenu_C in viewport=0 " })
    $hooks = [Array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match "\[$T\] ui menu hooks registered " })
    if ($startup -ge 0 -and $hooks -gt $startup) { Write-Host "ok:   core's menu hooks registered after the startup screen (line $($hooks + 1) > $($startup + 1))" }
    else { Write-Host "FAIL: core's menu hooks line ($($hooks + 1)) is not after the STARTUP line ($($startup + 1))"; $failed++ }
}
if ($Scenario -eq 'createserver') {
    # Core story 31 AC 3: the poll's cost in the match after Create (no create-server screen, the game host still
    # polled): the one-minute hud tick lines between "CSMATCH window 1" (logged after the first line in the match, which
    # can hold ticks from before it) and "CSMATCH end" lie wholly in the match. UI-1's targets: poll avg < 100 us,
    # steady max without a Lua GC step < 500 us; hard on the host, soft (warn) in the VM like the other timing checks.
    $from = [Array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match "\[$T\] CSMATCH window 1 " })
    $to = [Array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match "\[$T\] CSMATCH end " })
    $windows = 0
    if ($from -ge 0 -and $to -gt $from) {
        foreach ($l in $lines[$from..$to]) {
            if ($l -match "\[$T\] DEBUG hud tick n=(\d+) .*poll avg ([\d.]+) max (\d+), .*steady n=(\d+) avg ([\d.]+) max (\d+) us \(max (\d+) us without a Lua GC step; (\d+) tick\(s\) with one\), events n=(\d+)") {
                $windows++
                $ok = ([double]$Matches[2] -lt 100) -and ([int]$Matches[7] -lt 500)
                $tag = if ($ok) { 'ok:  ' } elseif ($Target -eq 'vm') { 'warn:' } else { 'FAIL:' }
                Write-Host ("{0} match window {1}: poll avg {2} max {3} us; steady n={4} avg {5} max {6} us, {7} us without a Lua GC step ({8} tick(s) with one); events n={9} (targets: poll avg < 100, steady max without GC < 500)" -f $tag, $windows, $Matches[2], $Matches[3], $Matches[4], $Matches[5], $Matches[6], $Matches[7], $Matches[8], $Matches[9])
                if (-not $ok) { if ($Target -eq 'vm') { $warned++ } else { $failed++ } }
            }
        }
    }
    if ($windows -lt 1) { Write-Host "FAIL: no whole hud tick window in the match (between CSMATCH window 1 and CSMATCH end)"; $failed++ }
}
if ($Scenario -eq 'soak') {
    # Story 7 AC 7: the one-minute windows that lie wholly in the idle match (the first one after "SOAK idle" may
    # still hold the touchdown's HUD events, so only windows with no event tick count).
    $idle = [Array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match "\[$T\] SOAK idle " })
    $windows = 0
    if ($idle -ge 0) {
        foreach ($l in $lines[$idle..($lines.Count - 1)]) {
            if ($l -match "\[$T\] DEBUG hud tick n=(\d+) .*poll avg ([\d.]+) max (\d+), .*steady n=(\d+) avg ([\d.]+) max (\d+) us \(max (\d+) us without a Lua GC step; (\d+) tick\(s\) with one\), events n=(\d+)") {
                if ([int]$Matches[9] -gt 0) { continue }
                $windows++
                $ok = ([double]$Matches[2] -lt 100) -and ([int]$Matches[7] -lt 500)
                Write-Host ("{0} window {1}: steady n={2} avg {3} max {4} us, {5} us without a Lua GC step ({6} tick(s) with one); poll avg {7} max {8} us (targets: poll avg < 100, max without GC < 500)" -f $(if ($ok) { 'ok:  ' } else { 'FAIL:' }), $windows, $Matches[4], $Matches[5], $Matches[6], $Matches[7], $Matches[8], $Matches[2], $Matches[3])
                if (-not $ok) { $failed++ }
            }
        }
    }
    if ($windows -lt 8) { Write-Host "FAIL: only $windows event-free one-minute window(s) in the idle match (expected at least 8)"; $failed++ }
}
if ($failed) { Write-Host "$failed check(s) failed."; exit 1 }
Write-Host ("All checks passed{0}." -f $(if ($warned) { " ($warned soft check(s) not met)" } else { '' }))
