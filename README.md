# NNCore (working name)

Core shared library for Nuclear Nightmare mods: a C++ DLL (weak object handles), a LogicMods Blueprint pak (the `NNCore_Call` channel and a text widget) and Lua (bootstrap, `connect`, logging). `NNCore` is a stand-in until core is named; every name-bearing identifier comes from `mod.json` `name`.

Spec, API contract and stories: `_bmad-output/specs/spec-core-v0/` in the workspace repo.

```powershell
$inst = 'C:\...\nuclear-nightmare\game-instances\v8.0-build26022182'   # absolute, also from a worktree
./build.ps1                                   # native + blueprint + lua + package (needs VS 2026, UE 5.6, ue4ss-src)
./deploy.ps1 -Instance $inst                  # core only; -Test adds the walking-skeleton dependent; -Remove takes it all out
./run.ps1 -Instance $inst -Scenario skeleton  # unattended in-game run + check.ps1 (also no-native, no-pak)
./check.ps1 -Instance $inst -Scenario skeleton
```

`ue4ss-src/` (ignored) is the pinned UE4SS commit with submodules, as `mods/cpp-spike/build.ps1` clones it; `build.ps1 -Ue4ssSrc <path>` points elsewhere. `run.ps1` presses Enter in the game window for touchdown; don't type into the game while it runs.
