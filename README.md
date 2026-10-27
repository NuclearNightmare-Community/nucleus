# Nucleus

Core shared library for Nuclear Nightmare mods: a C++ DLL (weak object handles, a monotonic clock), a LogicMods Blueprint pak (the `Nucleus_Call` channel and the text widget `WBP_NucleusText`) and Lua (bootstrap, `connect`, logging, and the HUD UI helpers `core.ui`).

Spec, API contract and stories: `_bmad-output/specs/spec-core-v0/` in the workspace repo (they still say `NNCore`, the old working name).

```powershell
$inst = 'C:\...\nuclear-nightmare\game-instances\v8.1.2-build26193463'   # absolute, also from a worktree
./build.ps1                                   # native + blueprint + lua + package (needs VS 2026, UE 5.6, ue4ss-src)
./deploy.ps1 -Instance $inst                  # core only; -Test adds the test dependent; -Remove takes it all out
./run.ps1 -Instance $inst -Scenario skeleton  # unattended in-game run + check.ps1 (also no-native, no-pak, bad-input, ui, soak)
./run.ps1 -Instance $inst -Scenario skeleton -Target vm   # the same in the Hyper-V VM, while you play (below)
./check.ps1 -Instance $inst -Scenario skeleton
```

`ue4ss-src/` (ignored) is the pinned UE4SS commit with submodules, as `mods/cpp-spike/build.ps1` clones it; `build.ps1 -Ue4ssSrc <path>` points elsewhere. `run.ps1` posts Enter to the game window's message queue for touchdown (no foreground change, so a dialog in front doesn't block it and nothing is typed into another program), and only ever stops the game under the instance; don't type into the game while it runs. Run logs are kept in `dumps/<copy>/nucleus/<scenario>.log` in the workspace.

## Scenarios

| Scenario | What it proves |
|---|---|
| `skeleton` | menu → match → menu → match: natives from `main.lua`, `connect`, the text widget anchored to the top-right corner of `InventoryUI_C.OwningCanvas` in every match, weak handles across map changes, `Nucleus_Ref` cost |
| `no-native` | no `main.dll`: one error line from core, one from the dependent |
| `no-pak` | no LogicMods pak: one `MISSING` line, the dependent gives up |
| `bad-input` | every native, the channel and every `core.ui` function called with bad values, on and off the game thread (and the UI helpers before `connect`); each case logs `OK CASE <id> ...` |
| `ui` | the UI helpers (stories 7-10) unattended, menu → match → `RemoveAllWidgets` and re-add → menu → match: an element created before the first match, the same id twice, `set` and its no-op, long text, `remove`, style, `setVisible` across map changes, all four corners and gaps, `offset`, `absolute`, a three-element stack (offset, hide, grow, remove), `near` the crosshair with `HideCrosshair`, a late and a throwing watcher, old handles freed, `FindAllOf` exactly once, tick timing lines. Several minutes; `run.ps1` gives it 900 s |
| `soak` | story 7 AC 7 unattended: menu, match, Enter at touchdown, then 10 minutes idle in the match with one element and one watcher; `check.ps1` fails any steady-state slow tick and any event-free minute window whose steady maximum is 500 us or more or whose poll average is 100 us or more. `run.ps1` gives it 1000 s |
| `manual` | for hand testing (below), not for `run.ps1`: `check.ps1` only checks that nothing broke |

## Tests in the VM

`run.ps1 -Target vm` runs a scenario in the Hyper-V VM `NNB` (account B; workspace `tools/vm/README.md`, "Single-player tests in the VM") instead of on the host, so it can run while you play on the host with your own account:

```powershell
./run.ps1 -Instance $inst -Scenario skeleton -Target vm
./run.ps1 -Instance $inst -Scenario bad-input -Target vm
./check.ps1 -Log <workspace>\dumps\v8.1.2-build26193463\nucleus\skeleton.vm.log -Scenario skeleton -Target vm
```

- `-Instance` is still the host's copy (absolute, also from a worktree): it names the build and finds the workspace's `tools/`. The VM's copy (`C:\nn\<same name>`) must be the same build; the run refuses otherwise. Nothing of the host copy is read except its exe size, and no host game is started, stopped or checked.
- What's installed is what `deploy.ps1 -Test -Scenario <s>` would install, from this repo's `build/package` (the VM path never builds): `deploy.ps1 -Staged` writes it into a host-side staging folder, which `tools/vm/vm-sp.ps1` copies into the VM copy. UE4SS is switched on for the run; afterwards the VM copy is put back exactly as it was (UE4SS off, no mods), also after a crash or a time limit. An interrupted run is undone by the next one, or by `tools/vm/vm-sp-restore.ps1`.
- Enter at touchdown: the test dependent's `request.txt`/`done.txt` are polled in the VM copy over PowerShell Direct, and the key is posted with `tools/vm/vm-key.ps1`.
- Time limits are the host's times 1.5 (the VM's game is slower), unless `-TimeoutSec` is given. The log is kept as `dumps/<copy>/nucleus/<scenario>.vm.log`.
- In the VM: `skeleton`, `bad-input`, `no-native`, `no-pak`, `ui`. Host only: `soak` (it judges tick costs; refused with `-Target vm`). `check.ps1 -Target vm` makes the one timing assertion inside a functional scenario soft: `ui`'s "no steady-state hud tick over 1 ms" (`WARN hud slow tick ... steady state`) shows as `warn:` instead of failing. `manual` is a hand test and isn't run by `run.ps1` anywhere.
- Builds still happen on the host (`build.ps1`, CPU-heavy: the game you're playing may stutter meanwhile), and the VM's game itself shares the host's CPU and GPU.

## Hand testing

The `manual` scenario is for playing the game yourself with core and the test dependent installed. The test dependent never travels, presses keys or runs timed checks, and never logs `FAIL` for anything you do. It connects to core (`CONNECT ok`, or one line saying why it can't) and keeps a `Nucleus manual: <n>` label in the top-right corner of the HUD through `core.ui.text`, so core attaches it again whenever the game rebuilds or replaces the HUD: first match, back to the menu, new match, death and revive (core logs `DEBUG ui attach 'manual' created|reused ...` each time). `n` counts the attaches. Each attach logs one `ATTACH` line with the HUD, whether it is visible (the menu and the lobby hide it; that's expected) and the label's rectangle. The UI helpers' `DEBUG` lines are on: a `hud tick n=... avg=... max=...` summary once a minute (story 7's 10-minute cost check reads these). While the HUD is visible, it also logs an experimental `OVERLAP` report about 1 s and 4 s after an attach: every drawn widget whose on-screen rectangle intersects the label's (`OVERLAP none (...)` when nothing does), plus `OVERLAP near` lines for the other drawn widgets in the screen's top-right quarter.

```powershell
cd <workspace>\mods\Nucleus
$inst = '<workspace>\game-instances\v8.1.2-build26193463'
./build.ps1                                     # once, if build/package/ is missing or out of date
./deploy.ps1 -Instance $inst -Test -Scenario manual
..\..\tools\launch.ps1 -Instance $inst          # play; quit the game when done
./check.ps1 -Instance $inst -Scenario manual    # nothing broke: no errors, CONNECT ok, at least one ATTACH
./deploy.ps1 -Instance $inst -Remove            # take core and the test dependent out again
```

The log is `ue4ss\UE4SS.log` in the copy's `NuclearNightmare\Binaries\Win64`, and every launch overwrites it. Save a copy before launching again, and check the copy:

```powershell
$log = "$inst\NuclearNightmare\Binaries\Win64\ue4ss\UE4SS.log"
Copy-Item $log "..\..\dumps\v8.1.2-build26193463\nucleus\manual-$(Get-Date -Format yyyyMMdd-HHmm).log"
./check.ps1 -Log "..\..\dumps\v8.1.2-build26193463\nucleus\manual-<stamp>.log" -Scenario manual
```

`run.ps1` doesn't take `manual`: it waits for an end the manual test never reaches.

## Renaming

The name is `mod.json` `name` (and `id`, its lowercase form). Change it there and rebuild; nothing else spells it:

| Part | Where the name comes from |
|---|---|
| C++ (`Nucleus_NativeVersion`, `_ClockMicros`, `_Ref`, `_Deref`, `_RefFree`, log prefix) | `CORE_NAME` in `native/src/core_config.hpp.in`, filled by CMake from `-DCORE_NAME` (`build.ps1` reads `mod.json`) |
| Blueprint (`/Game/Mods/<name>/ModActor`, `<name>_Call`, `<name>_Abs*`, `WBP_<name>Text`) | the `-CoreName=` argument of the `CoreGen` commandlet (`build.ps1` passes `mod.json` `name`) |
| Pak (`Content/Paks/LogicMods/<name>.pak`) and install folder (`Mods/<name>/`) | `build.ps1` and `deploy.ps1`, from `mod.json` |
| Core's Lua (`[<name>]` log prefix, channel path, shared variables `<lowercase>.state`) | the folder it runs from (`Mods/<name>/Scripts/main.lua`) |
| Lua modules (`<lowercase>.client`, `.clock`, `.log`, `.ref`, `.semver`, `.ui.*`) | `build.ps1` stages them as `Scripts/<lowercase>/` (the UI helpers as `Scripts/<lowercase>/ui/`) and writes `Scripts/<lowercase>/version.lua`; the UI helpers' error prefix (`<lowercase>.ui`) and widget tag prefix come from it |
| Test dependent (`<name>SkelTest`) | `deploy.ps1` installs `test/SkelTest` as `Mods/<name>SkelTest`; the test reads the name from that folder |
| `run.ps1`, `check.ps1`, log folder `dumps/<copy>/<lowercase>/` | `mod.json` |

Generic names that don't carry core's name, and so never change: the CMake target `CoreNative`, the Unreal module and commandlet `CoreGen`, the Unreal project `NuclearNightmare`. Real dependents keep their own `CORE` constant in their bootstrap and must update it.

## Natives

Registered into every Lua mod's state before its `main.lua` runs (names from `CORE_NAME`):

| Native | Returns | Threads |
|---|---|---|
| `Nucleus_NativeVersion()` | core's version, the UE4SS build it was built for (two strings) | any |
| `Nucleus_ClockMicros()` | microseconds from a monotonic clock (`QueryPerformanceCounter`), a Lua integer. The epoch is arbitrary: only the difference between two calls means anything. No allocation, lock or logging; wrapped as `<lowercase>.clock` `micros()` and `core.clock.micros()` in the `connect` API | any, also during `main.lua` |
| `Nucleus_Ref(address)` | a weak handle (integer) to the live UObject at `address` | game thread |
| `Nucleus_Deref(handle)` | the object, or `nil` once it is gone | game thread |
| `Nucleus_RefFree(handle)` | nothing; idempotent | any |

Natives that take no arguments refuse any (`<fn>: expected 0 arguments, got N`).

## Native hardening

Every native validates its arguments and answers bad input with one Lua error naming the function and the problem (for example `Nucleus_Ref: address 0x10000 is not a live UObject (not in GUObjectArray)`). `Nucleus_Ref` never reads through the address it gets: it looks it up in `GUObjectArray` by pointer comparison (a scan from the last slot down: objects created since the game started usually sit near the end, though the array reuses freed slots, so after a map change a new object can sit anywhere; a miss still compares every slot; its cost is logged as `REF_COST` at call counts 1, 2, 4, ...). Engine-memory reads run under SEH as a last resort; a fault is logged as `native: FAULT ...` and the call fails cleanly. Handles are integers in `1 .. 2^53-1`; anything outside that range is an error, an unknown handle in range is `nil` (`Deref`) or ignored (`RefFree`).

## UI helpers (`core.ui`)

Reached on the API that `connect`'s `onReady` receives; each dependent runs its own copy in its own Lua state. Contract: `ui-helpers-contract.md` and stories 7-10 in the workspace spec (where they disagree, the stories win). Every function runs only on the game thread (`<lowercase>.ui.<fn> called off the game thread`) and only after `connect` (`<lowercase>.ui: <fn> called before connect`), validates its input first and raises one clean error naming the function and the problem. Nothing keeps a UObject between calls: paths, weak handles and plain tables only.

`core.ui` is new public API in core 0.2.0. Under the caret rule below 1.0.0 (same minor, `semver.lua`), a dependent connects with `need = "0.2.0"`; one that still asks for `0.1.x` is refused by core 0.2.0 and has to raise its `need`.

| Module | What it does |
|---|---|
| `lua/pkg/ui/hud.lua` (UI-1) | `core.ui.hud.find()` returns the live HUD or `nil`, valid only inside the current game-thread callback. `watch(fn)` returns a token; `fn(hud, info)` gets `info = { event, reason, path, visible }` with `event` one of `attached`, `shown`, `hidden`, `lost`. Also `unwatch(token)`, `isVisible()` and `stats()` (diagnostic). One poller per Lua state, every 500 ms on the game thread; a new HUD path counts on the second tick that sees it. HUD paths come from `NotifyOnNewObject` on `InventoryUI_C` plus one seed `FindAllOf` per Lua state (logged as `hud seed FindAllOf(...) call 1 ... in <n> us`); ticks re-find the known HUDs (at most 16) by weak handle, never by `StaticFindObject`: in the pinned UE4SS a `StaticFindObject` that misses scans every object (4-6.5 ms on V8.1.2), as it did for the old HUD's path after every map change. A steady tick makes three engine reads (`Deref`, `IsInViewport`, the `Visibility` property; ownership is checked once per HUD until it leaves the viewport), each 15-30 us in a tick, and allocates almost nothing. Ticks are timed with `core.clock.micros()`: `DEBUG hud tick n=... avg=... max=...` once a minute, `WARN hud slow tick` over 1 ms at most once a minute, a `hud tick summary` at unload. A throwing watcher is logged once (`WARN hud watcher <token>: ...`). The poller is a `LoopInGameThreadWithDelay` registered from the game thread, never `LoopAsync` + `ExecuteInGameThread`: in the pinned UE4SS an `ExecuteInGameThread` from the async thread can register a value the game thread pushed at the same moment instead of the callback, so the callback is lost and UE4SS later calls the stray value (`A function requiring userdata as param #1 was called without userdata`, traceback `[C]: in ?`). Reproduced on V8.1.2 with a minimal mod (async-thread `ExecuteInGameThread` every 10 ms while the game thread runs UObject calls): both runs crashed inside UE4SS within 7 s, one after `Ref was not function`; queuing from the game thread, or with the game thread idle, lost none of 3495 and 6301 callbacks. No watchdog: a game-thread loop has no queued callback to lose. `connect`, core's own class check and the test dependent use game-thread loops for the same reason; dependents should too. During a blocking map load no tick runs (no engine tick); the loop resumes once, without a backlog. Ticks are counted as steady (nothing changed) or event ticks (a HUD event or a re-attach); the minute line and the summary show both, and the steady maximum without the ticks a step of the Lua collector landed in (the heap shrank during the tick), with their count. On the V8.1.2 soak every steady tick over 0.5 ms was such a tick: that work belongs to the whole Lua state (the dependent's allocations), not to the tick. `hud._profile(true)` (diagnostic, used by the ui, soak and manual scenarios) times each phase: a `DEBUG hud prof event=...` line per event tick and a `DEBUG hud prof steady ...` line a minute |
| `lua/pkg/ui/text.lua` (UI-2, UI-4) | `core.ui.text.create{ id, text, place, style }` returns a handle; `set(h, text)`, `setStyle(h, style)`, `setVisible(h, bool)`, `remove(h)`, `isShown(h)`, and `stats()` and `tagOf(id)` (diagnostic). Ids are 1-64 of `A-Z a-z 0-9 _ . -`; text is a string, a number or nil, cut at 256 characters with one `WARN` per element; an unchanged text, style or visibility makes no UObject call. Handles are read-only `{ id = ... }` tables. A UI-1 watcher re-attaches every element on each `attached` (reusing its widget or the one tagged with its id, removing duplicates and this mod's orphans) and re-applies text, style, visibility and placement; on `lost` it only frees handles whose widget is gone. Each widget's `ToolTipText` is `<lowercase>:<mod>:<id>`, and it is `SelfHitTestInvisible`. The widget class is held by weak handle and loaded with `GetAsset` (never looked up by path, see above) on the tick that first sees a new HUD, one tick before the attach; nothing keeps it loaded across a map change, so that costs 0.5-0.8 ms once per map. Each attach event logs one `DEBUG ui attach '<id>' created|reused <path>, ...` line for all elements, on the tick after the attach (a log line costs 0.3-0.8 ms), only while `core.log.debugEnabled` is on; with it off the line is not even built. An attach event that leaves an element pending (pak missing, no owning player) always logs one INFO line, `ui attach left '<id>', ... pending, retried in 10 ticks (<reason>)`, besides the WARN naming the cause. Between HUD events a tick checks each widget by `Deref` only; canvas membership (`GetParent`) every 10 ticks, `near` rectangles every 4, stack heights for 4 ticks after a re-stack |
| `lua/pkg/ui/place.lua` (UI-3) | `core.ui.place(h, intent)` and `core.ui.elements()`. Intents: `{ corner, gap, offset = { x, y } }`, `{ near = "crosshair", side, align, gap, offset }` or `{ absolute = { anchor, x, y } }`. Gaps are tight 8, normal 16, loose 32 canvas units; offsets stay within ±4096 and absolute positions within ±8192; unknown keys and values raise. One mod's corner elements stack in creation order, `gap` apart; hidden and absolute ones take no space, and there is no cross-mod stacking in v0. A `near` element collapses while its element is absent or collapsed, re-checked every tick |
| `lua/pkg/ui/theme.lua` | Style presets. Background `none`, `dim` (35% black), `dark` (70% black), or `{ r, g, b, a }` (0..1, `a` defaults to 1); padding `none`, `tight`, `normal`, `loose` = 0, 4, 8, 12 canvas units, `normal` by default when there is a background |
| `lua/pkg/ui/common.lua` | Internal: the per-state element registry, boundary checks and counters |

`WBP_<name>Text`, generated by `CoreGen`, is `Border "Background"` (hit-test invisible, alpha 0, padding 0) holding `TextBlock "Text"`, with `SetText(NewText)`, `SetBackground(R, G, B, A)` and `SetBackgroundPadding(Padding)`. Story 8 calls the last one `SetPadding`, but `UUserWidget` already has a native `SetPadding(FMargin)`, so the generator refuses that name.

Unit tests of the helpers' own logic (validation, the HUD state machine, layout math, attach, re-attach, duplicates, orphans, no-op counters) run outside the game, with UE4SS and UMG stubbed in plain Lua: `lua test/unit/ui_test.lua` from the repo root, with any standalone Lua 5.3 or 5.4 (MiKTeX's `texlua.exe` is one). They don't replace `run.ps1 -Scenario ui`.
