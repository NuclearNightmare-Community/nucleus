# Nucleus

Core shared library for Nuclear Nightmare mods: a C++ DLL (weak object handles, a monotonic clock), a LogicMods Blueprint pak (the `Nucleus_Call` channel and the text widget `WBP_NucleusText`) and Lua (bootstrap, `connect`, logging, and the HUD UI helpers `core.ui`).

Spec, API contract and stories: `_bmad-output/specs/spec-core-v0/` in the workspace repo (they still say `NNCore`, the old working name).

```powershell
$inst = 'C:\...\nuclear-nightmare\game-instances\v8.1.1-build26172444'   # absolute, also from a worktree
./build.ps1                                   # native + blueprint + lua + package (needs VS 2026, UE 5.6, ue4ss-src)
./deploy.ps1 -Instance $inst                  # core only; -Test adds the test dependent; -Remove takes it all out
./run.ps1 -Instance $inst -Scenario skeleton  # unattended in-game run + check.ps1 (also no-native, no-pak, bad-input, ui)
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

## Hand testing

The `manual` scenario is for playing the game yourself with core and the test dependent installed. The test dependent never travels, presses keys or runs timed checks, and never logs `FAIL` for anything you do. It connects to core (`CONNECT ok`, or one line saying why it can't) and keeps a `Nucleus manual: <n>` label in the top-right corner of the HUD through `core.ui.text`, so core attaches it again whenever the game rebuilds or replaces the HUD: first match, back to the menu, new match, death and revive (core logs `ui attach 'manual' created|reused ...` each time). `n` counts the attaches. Each attach logs one `ATTACH` line with the HUD, whether it is visible (the menu and the lobby hide it; that's expected) and the label's rectangle. The UI helpers' `DEBUG` lines are on: a `hud tick n=... avg=... max=...` summary once a minute (story 7's 10-minute cost check reads these). While the HUD is visible, it also logs an experimental `OVERLAP` report about 1 s and 4 s after an attach: every drawn widget whose on-screen rectangle intersects the label's (`OVERLAP none (...)` when nothing does), plus `OVERLAP near` lines for the other drawn widgets in the screen's top-right quarter.

```powershell
cd <workspace>\mods\Nucleus
$inst = '<workspace>\game-instances\v8.1.1-build26172444'
./build.ps1                                     # once, if build/package/ is missing or out of date
./deploy.ps1 -Instance $inst -Test -Scenario manual
..\..\tools\launch.ps1 -Instance $inst          # play; quit the game when done
./check.ps1 -Instance $inst -Scenario manual    # nothing broke: no errors, CONNECT ok, at least one ATTACH
./deploy.ps1 -Instance $inst -Remove            # take core and the test dependent out again
```

The log is `ue4ss\UE4SS.log` in the copy's `NuclearNightmare\Binaries\Win64`, and every launch overwrites it. Save a copy before launching again, and check the copy:

```powershell
$log = "$inst\NuclearNightmare\Binaries\Win64\ue4ss\UE4SS.log"
Copy-Item $log "..\..\dumps\v8.1.1-build26172444\nucleus\manual-$(Get-Date -Format yyyyMMdd-HHmm).log"
./check.ps1 -Log "..\..\dumps\v8.1.1-build26172444\nucleus\manual-<stamp>.log" -Scenario manual
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

Every native validates its arguments and answers bad input with one Lua error naming the function and the problem (for example `Nucleus_Ref: address 0x10000 is not a live UObject (not in GUObjectArray)`). `Nucleus_Ref` never reads through the address it gets: it looks it up in `GUObjectArray` by pointer comparison (a scan; its cost is logged as `REF_COST` at call counts 1, 2, 4, ...). Engine-memory reads run under SEH as a last resort; a fault is logged as `native: FAULT ...` and the call fails cleanly. Handles are integers in `1 .. 2^53-1`; anything outside that range is an error, an unknown handle in range is `nil` (`Deref`) or ignored (`RefFree`).

## UI helpers (`core.ui`)

Reached on the API that `connect`'s `onReady` receives; each dependent runs its own copy in its own Lua state. Contract: `ui-helpers-contract.md` and stories 7-10 in the workspace spec (where they disagree, the stories win). Every function runs only on the game thread (`<lowercase>.ui.<fn> called off the game thread`) and only after `connect` (`<lowercase>.ui: <fn> called before connect`), validates its input first and raises one clean error naming the function and the problem. Nothing keeps a UObject between calls: paths, weak handles and plain tables only.

`core.ui` is new public API in core 0.2.0. Under the caret rule below 1.0.0 (same minor, `semver.lua`), a dependent connects with `need = "0.2.0"`; one that still asks for `0.1.x` is refused by core 0.2.0 and has to raise its `need`.

| Module | What it does |
|---|---|
| `lua/pkg/ui/hud.lua` (UI-1) | `core.ui.hud.find()` returns the live HUD or `nil`, valid only inside the current game-thread callback. `watch(fn)` returns a token; `fn(hud, info)` gets `info = { event, reason, path, visible }` with `event` one of `attached`, `shown`, `hidden`, `lost`. Also `unwatch(token)`, `isVisible()` and `stats()` (diagnostic). One poller per Lua state, every 500 ms on the game thread; a new HUD path counts on the second tick that sees it. HUD paths come from `NotifyOnNewObject` on `InventoryUI_C` plus one seed `FindAllOf` per Lua state (logged as `hud seed FindAllOf(...) call 1 ... in <n> us`); ticks only `StaticFindObject` the known paths (at most 16). Ticks are timed with `core.clock.micros()`: `DEBUG hud tick n=... avg=... max=...` once a minute, `WARN hud slow tick` over 1 ms at most once a minute, a `hud tick summary` at unload. A throwing watcher is logged once (`WARN hud watcher <token>: ...`). The poller is a `LoopInGameThreadWithDelay` registered from the game thread, never `LoopAsync` + `ExecuteInGameThread`: in the pinned UE4SS an `ExecuteInGameThread` from the async thread can register a value the game thread pushed at the same moment instead of the callback, so the callback is lost and UE4SS later calls the stray value (`A function requiring userdata as param #1 was called without userdata`, traceback `[C]: in ?`). `connect`, core's own class check and the test dependent use game-thread loops for the same reason; dependents should too. During a blocking map load no tick runs (no engine tick); the loop resumes once, without a backlog. Ticks are counted as steady (nothing changed) or event ticks (a HUD event or a re-attach); the minute line and the summary show both. `hud._profile(true)` (diagnostic, used by the ui, soak and manual scenarios) times each phase: a `DEBUG hud prof event=...` line per event tick and a `DEBUG hud prof steady ...` line a minute |
| `lua/pkg/ui/text.lua` (UI-2, UI-4) | `core.ui.text.create{ id, text, place, style }` returns a handle; `set(h, text)`, `setStyle(h, style)`, `setVisible(h, bool)`, `remove(h)`, `isShown(h)`, and `stats()` and `tagOf(id)` (diagnostic). Ids are 1-64 of `A-Z a-z 0-9 _ . -`; text is a string, a number or nil, cut at 256 characters with one `WARN` per element; an unchanged text, style or visibility makes no UObject call. Handles are read-only `{ id = ... }` tables. A UI-1 watcher re-attaches every element on each `attached` (reusing its widget or the one tagged with its id, removing duplicates and this mod's orphans) and re-applies text, style, visibility and placement; on `lost` it only frees handles whose widget is gone. Each widget's `ToolTipText` is `<lowercase>:<mod>:<id>`, and it is `SelfHitTestInvisible` |
| `lua/pkg/ui/place.lua` (UI-3) | `core.ui.place(h, intent)` and `core.ui.elements()`. Intents: `{ corner, gap, offset = { x, y } }`, `{ near = "crosshair", side, align, gap, offset }` or `{ absolute = { anchor, x, y } }`. Gaps are tight 8, normal 16, loose 32 canvas units; offsets stay within ±4096 and absolute positions within ±8192; unknown keys and values raise. One mod's corner elements stack in creation order, `gap` apart; hidden and absolute ones take no space, and there is no cross-mod stacking in v0. A `near` element collapses while its element is absent or collapsed, re-checked every tick |
| `lua/pkg/ui/theme.lua` | Style presets. Background `none`, `dim` (35% black), `dark` (70% black), or `{ r, g, b, a }` (0..1, `a` defaults to 1); padding `none`, `tight`, `normal`, `loose` = 0, 4, 8, 12 canvas units, `normal` by default when there is a background |
| `lua/pkg/ui/common.lua` | Internal: the per-state element registry, boundary checks and counters |

`WBP_<name>Text`, generated by `CoreGen`, is `Border "Background"` (hit-test invisible, alpha 0, padding 0) holding `TextBlock "Text"`, with `SetText(NewText)`, `SetBackground(R, G, B, A)` and `SetBackgroundPadding(Padding)`. Story 8 calls the last one `SetPadding`, but `UUserWidget` already has a native `SetPadding(FMargin)`, so the generator refuses that name.

Unit tests of the helpers' own logic (validation, the HUD state machine, layout math, attach, re-attach, duplicates, orphans, no-op counters) run outside the game, with UE4SS and UMG stubbed in plain Lua: `lua test/unit/ui_test.lua` from the repo root, with any standalone Lua 5.3 or 5.4 (MiKTeX's `texlua.exe` is one). They don't replace `run.ps1 -Scenario ui`.
