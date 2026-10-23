# Nucleus

Core shared library for Nuclear Nightmare mods: a C++ DLL (weak object handles), a LogicMods Blueprint pak (the `Nucleus_Call` channel and the text widget `WBP_NucleusText`) and Lua (bootstrap, `connect`, logging).

Spec, API contract and stories: `_bmad-output/specs/spec-core-v0/` in the workspace repo (they still say `NNCore`, the old working name).

```powershell
$inst = 'C:\...\nuclear-nightmare\game-instances\v8.0-build26022182'   # absolute, also from a worktree
./build.ps1                                   # native + blueprint + lua + package (needs VS 2026, UE 5.6, ue4ss-src)
./deploy.ps1 -Instance $inst                  # core only; -Test adds the test dependent; -Remove takes it all out
./run.ps1 -Instance $inst -Scenario skeleton  # unattended in-game run + check.ps1 (also no-native, no-pak, bad-input)
./check.ps1 -Instance $inst -Scenario skeleton
```

`ue4ss-src/` (ignored) is the pinned UE4SS commit with submodules, as `mods/cpp-spike/build.ps1` clones it; `build.ps1 -Ue4ssSrc <path>` points elsewhere. `run.ps1` presses Enter in the game window for touchdown; don't type into the game while it runs. Run logs are kept in `dumps/<copy>/nucleus/<scenario>.log` in the workspace.

## Scenarios

| Scenario | What it proves |
|---|---|
| `skeleton` | menu → match → menu → match: natives from `main.lua`, `connect`, the text widget anchored to the top-right corner of `InventoryUI_C.OwningCanvas` in every match, weak handles across map changes, `Nucleus_Ref` cost |
| `no-native` | no `main.dll`: one error line from core, one from the dependent |
| `no-pak` | no LogicMods pak: one `MISSING` line, the dependent gives up |
| `bad-input` | every native and the channel called with bad values, on and off the game thread; each case logs `OK CASE <id> ...` |
| `manual` | for hand testing (below), not for `run.ps1`: `check.ps1` only checks that nothing broke |

## Hand testing

The `manual` scenario is for playing the game yourself with core and the test dependent installed. The test dependent never travels, presses keys or runs timed checks, and never logs `FAIL` for anything you do. It connects to core (`CONNECT ok`, or one line saying why it can't) and keeps a `Nucleus manual: <n>` label in the top-right corner of the HUD, attaching it again whenever the game rebuilds or replaces the HUD: first match, back to the menu, new match, death and revive. `n` counts the attaches. Each attach logs one `ATTACH` line with the HUD, whether it is visible (the menu and the lobby hide it; that's expected) and the label's rectangle. While the HUD is visible, it also logs an experimental `OVERLAP` report about 1 s and 4 s after an attach: every drawn widget whose on-screen rectangle intersects the label's (`OVERLAP none (...)` when nothing does), plus `OVERLAP near` lines for the other drawn widgets in the screen's top-right quarter.

```powershell
cd <workspace>\mods\Nucleus
$inst = '<workspace>\game-instances\v8.0-build26022182'
./build.ps1                                     # once, if build/package/ is missing or out of date
./deploy.ps1 -Instance $inst -Test -Scenario manual
..\..\tools\launch.ps1 -Instance $inst          # play; quit the game when done
./check.ps1 -Instance $inst -Scenario manual    # nothing broke: no errors, CONNECT ok, at least one ATTACH
./deploy.ps1 -Instance $inst -Remove            # take core and the test dependent out again
```

The log is `ue4ss\UE4SS.log` in the copy's `NuclearNightmare\Binaries\Win64`, and every launch overwrites it. Save a copy before launching again, and check the copy:

```powershell
$log = "$inst\NuclearNightmare\Binaries\Win64\ue4ss\UE4SS.log"
Copy-Item $log "..\..\dumps\v8.0-build26022182\nucleus\manual-$(Get-Date -Format yyyyMMdd-HHmm).log"
./check.ps1 -Log "..\..\dumps\v8.0-build26022182\nucleus\manual-<stamp>.log" -Scenario manual
```

`run.ps1` doesn't take `manual`: it waits for an end the manual test never reaches.

## Renaming

The name is `mod.json` `name` (and `id`, its lowercase form). Change it there and rebuild; nothing else spells it:

| Part | Where the name comes from |
|---|---|
| C++ (`Nucleus_NativeVersion`, `_Ref`, `_Deref`, `_RefFree`, log prefix) | `CORE_NAME` in `native/src/core_config.hpp.in`, filled by CMake from `-DCORE_NAME` (`build.ps1` reads `mod.json`) |
| Blueprint (`/Game/Mods/<name>/ModActor`, `<name>_Call`, `<name>_Abs*`, `WBP_<name>Text`) | the `-CoreName=` argument of the `CoreGen` commandlet (`build.ps1` passes `mod.json` `name`) |
| Pak (`Content/Paks/LogicMods/<name>.pak`) and install folder (`Mods/<name>/`) | `build.ps1` and `deploy.ps1`, from `mod.json` |
| Core's Lua (`[<name>]` log prefix, channel path, shared variables `<lowercase>.state`) | the folder it runs from (`Mods/<name>/Scripts/main.lua`) |
| Lua modules (`<lowercase>.client`, `.log`, `.ref`, `.semver`) | `build.ps1` stages them as `Scripts/<lowercase>/` and writes `Scripts/<lowercase>/version.lua` |
| Test dependent (`<name>SkelTest`) | `deploy.ps1` installs `test/SkelTest` as `Mods/<name>SkelTest`; the test reads the name from that folder |
| `run.ps1`, `check.ps1`, log folder `dumps/<copy>/<lowercase>/` | `mod.json` |

Generic names that don't carry core's name, and so never change: the CMake target `CoreNative`, the Unreal module and commandlet `CoreGen`, the Unreal project `NuclearNightmare`. Real dependents keep their own `CORE` constant in their bootstrap and must update it.

## Native hardening

Every native validates its arguments and answers bad input with one Lua error naming the function and the problem (for example `Nucleus_Ref: address 0x10000 is not a live UObject (not in GUObjectArray)`). `Nucleus_Ref` never reads through the address it gets: it looks it up in `GUObjectArray` by pointer comparison (a scan; its cost is logged as `REF_COST` at call counts 1, 2, 4, ...). Engine-memory reads run under SEH as a last resort; a fault is logged as `native: FAULT ...` and the call fails cleanly. Handles are integers in `1 .. 2^53-1`; anything outside that range is an error, an unknown handle in range is `nil` (`Deref`) or ignored (`RefFree`).
