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
    [ValidateSet('skeleton', 'no-native', 'no-pak', 'bad-input', 'ui', 'journal', 'soak', 'manual')]
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
    "\[$N\] READY version=$Ver native=$Ver ue4ss=v3\.0\.1-1181-g83330635"
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
foreach ($id in 'pre-create', 'pre-watch', 'pre-find', 'pre-elements', 'pre-overlaps', 'pre-journal-watch', 'pre-journal-isopen', 'pre-panel-create', 'pre-panel-move', 'pre-button-create') { $badInput += "\[$T\] OK CASE $id " }
$badInput += "\[$T\] OK CASES before-connect recorded=10"
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
    "!\[$T\] WARN (?!hud watcher \d+: |text 'long': |ui overlap '|button 'b2' onClick: |$slowWarnOk)"
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
    "!\[$Peer\] (ERROR|WARN (?!$slowWarnOk))"
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
    "#12|\[$T\] OK JCORNER "
    "#12|\[$T\] OK JCLOSED "
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
    "\[$T\] DEBUG ui journal attach n=4 in \d+ us \(canvas \d+; 'jt' \d+ \(create \d+\); 'jb1' \d+ \(create \d+, in 'jpanel'\); 'jb2' \d+ \(create \d+, in 'jpanel'\); 'jpanel' \d+ \(create \d+, own -?\d+\); place \d+\): 'jt' created "
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
$expect = @{
    'skeleton'  = $skeleton
    'ui'        = $ui
    'journal'   = $journal
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
