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
#>
param(
    [string] $Instance,
    [string] $Log,
    [ValidateSet('skeleton', 'no-native', 'no-pak', 'bad-input', 'ui', 'soak', 'manual')]
    [string] $Scenario = 'skeleton'
)
$manifest = Get-Content (Join-Path $PSScriptRoot 'mod.json') -Raw | ConvertFrom-Json
$name = $manifest.name
$version = $manifest.version
$t = "${name}SkelTest"
$N = [regex]::Escape($name); $T = [regex]::Escape($t); $Ver = [regex]::Escape($version)
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
    if ($p -like 'match*') { $skeleton += "\[$T\] REFCOST $p n=200 " }
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
                    'off-ui-elements', 'off-ui-find', 'off-ui-watch', 'off-ui-unwatch', 'off-ui-isvisible', 'off-ui-after') {
        $badInput += "\[$T\] OK CASE $p\.$id "
    }
}
foreach ($id in 'pre-create', 'pre-watch', 'pre-find', 'pre-elements') { $badInput += "\[$T\] OK CASE $id " }
$badInput += "\[$T\] OK CASES before-connect recorded=4"
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
    "!\[$T\] WARN (?!hud watcher \d+: |text 'long': |hud slow tick .*(; HUD event: |steady state, a Lua GC step ran inside it))"
    "!\[$T\] ERROR"
    "\[$T\] DEBUG hud tick n=\d+ "
    "\[$T\] DEBUG ui (widget\(s\) gone with the HUD; freed handle\(s\) .*'pre' |'pre': new widget .*; freed the handle)"
    # Story 7: steady-state ticks never pass 1 ms. Soft: a tick that handles a HUD event (attach after a new HUD), and
    # a steady tick a step of the Lua collector landed in (that work belongs to the whole Lua state, not to the tick).
    "!\[$T\] WARN hud slow tick .*steady state\)"
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
    "!\[$T\] WARN (?!hud slow tick .*(; HUD event: |steady state, a Lua GC step ran inside it))"
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
    'soak'      = $soak
    'manual'    = $manual
    'bad-input' = $badInput
    'no-native' = @(
        "#1|\[$N\] "
        "\[$N\] ERROR native part is not loaded"
        "\[$T\] NATIVE main\.lua ${N}_NativeVersion missing"
        "\[$T\] ERROR $N's native part is not loaded .* $T will not run\."
        "!\[$N\] CHANNEL hooked"
        "\[$T\] END result=FAIL .*reason=connect"
    )
    'no-pak' = @(
        "\[$N\] READY version=$Ver"
        "#1|\[$N\] ERROR MISSING $N's Blueprint content is not installed"
        "\[$T\] ERROR $N's Blueprint content is not installed \(Content/Paks/LogicMods/$N\.pak\)\. $T will not run\."
        "!\[$N\] CHANNEL hooked"
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
