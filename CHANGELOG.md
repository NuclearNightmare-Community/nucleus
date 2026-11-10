# Changelog

All notable changes to Nucleus are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). From 0.5.0 a dependent's `need` and `dependsOn` are minimum versions (`>=0.5.0`), so a newer Nucleus never asks dependents to raise them. Up to 0.3.0, below 1.0.0 a dependent connected only to the same minor version (`need = "0.3.0"` accepted 0.3.x).

## [Unreleased]

## [0.5.0] - 2026-11-09

Soft release to a few testers, not released publicly. Game: Nuclear Nightmare V8.2.1 (build 26512322). UE4SS: v3.0.1-1181-g83330635.

For players: nothing changes on the game's own maps. On a custom map built with Nucleus's map markers, Nucleus now does the setup the map needs on its own: the lobby countdown, the start positions, the game's real objects and enemies, the Journal's tasks and map, and day and night. A custom map is a pak and a `mod.json`, with no Lua of its own.

### Added

- The map service. A level that places Nucleus's Start marker gets the game's start setup on its own: the start service before the game state begins, the ten player-start lists filled from the level's PlayerStarts, and every player teleported to the map's ground starts when the lobby countdown ends. Stock maps are untouched.
- Twelve map markers for map authors, `BP_Marker_<Kind>` under `/Game/Mods/Nucleus/Map/` in Nucleus's pak: Start, Item, Intel, Computer, Generator, Lever, EnemySpawner, EnemyWaypoint, Landing, Map, Location and Sky, plus the Item marker's list `E_MarkerItem` (Painkillers, Flashlight). On the host Nucleus spawns the game's real class at each marker and wires them together: items, intel areas and intel, the nuke computer and its landing, the generator and its equipment, the lever, the game's own enemy spawner and the enemy waypoints. Clients get them by replication. A map's pak only refers to the markers and never carries them.
- Each marker carries 8 static and 2 skeletal editor-only preview slots and an editor icon, for the authoring kit's previews. They are stripped from the cooked pak.
- Intel tasks: on the host each intel area's task list is filled from its Intel markers (`TaskText`, or a text derived from the id), so the Journal lists every area and its tasks on every machine and ticks them through the game's own pickup flow. The imposter's task rows are kept in step with everyone else's.
- Fixes for what the game doesn't replicate on a custom map: each client sets the intel areas' Area Name from its own level, and every machine plays the lobby cabin's sound.
- The Journal map on custom maps: the map's own picture and world rectangle from the Map marker, pre-zoomed to it, the game's icons centred on their spots, and clickable area flags from Location markers, on every machine.
- Real day and night on custom maps: the host spawns the game's sky at the Sky marker at its `StartHour` (never a second one if the level has its own sky), so the Journal clock works.
- Natives `Nucleus_SetObjectives`, `Nucleus_DescribeObjectives` and `Nucleus_SetTraitorTaskState` in Nucleus's own DLL: they replace the separate `MapObjectives` C++ mod. They run on the game thread only, refuse a client or standalone world, and prove the task manager is a live object before touching it.
- The map setup signal for dependents, the shared variable `nucleus.map.setup`: `none`, `pending <world>`, `done <world>` or `failed <n> <world>`, on every machine. A dependent learns that the setup on its machine finished, and whether it succeeded, without reading core's internals. `nucleus.map` reports whether the map service itself started, and `core.has("map.setup")` is true.
- Feature checks for optional features: `core.has(name)` and `core.features()`, generated from the API that `connect`'s `onReady` receives, and the `READY` log line lists the same names (`floor=` and `features=`).
- Every bad marker value (an unknown item, a bad area name or id, a missing landing, a bad picture path or rectangle, and so on) is one `FAIL` line in the log and that marker is skipped; the game keeps running. Ids that arrive from the host on a client are used only as length-checked lookup keys.
- `LICENSE` (MIT) and this changelog.

### Changed

- Dependents declare a minimum version, `"dependsOn": [{ "id": "nucleus", "version": ">=0.5.0" }]` and `connect{ need = ">=0.5.0" }`; any newer Nucleus satisfies it. Older `^0.2.0` and `^0.3.0` strings (and a bare `"0.3.0"`) are read as `>=` and keep loading, so clock and markers need no re-release. Any other form is refused at once with one log line; `connect` returns `false, message` and never raises. The refusal message names the side that is too old: `Update Nucleus.` or, below core's floor (`mod.json` `compat.floor`, 0.1.0), `Update <mod>.`
- Core only ever adds public API; a replaced API keeps working and logs one `DEPRECATED` line per dependent per session.
- Nucleus's pak now holds `/Game/Mods/Nucleus/Map/` as well. The name Nucleus is final: released maps name these paths, so it can't change.
- The markers' layout is frozen: settings and `E_MarkerItem` values are only ever appended, never renamed, removed or reordered (cooked levels store a marker's values by position).

### Fixed

- `alive()` in core's map code no longer hands values that aren't UObjects (a missing member's placeholder, a struct, an array, an out-array entry) to the game's validity check, which read them as objects and could crash the game. They now count as not alive, with no call into the game.
- `core.ui.debug.overlaps` no longer reads `GetAllWidgetsOfClass`'s out array, whose entries point into freed memory in the pinned UE4SS; it walks the viewport's widgets instead.

### Known limits

- The map service is verified in solo matches on the demo map. A two-player match on a custom map with this version is not verified yet (map service story 11); more than two players and enemies other than the Psycho are not verified at all.
- A custom map can't be chosen from the game's menu or lobby yet.
- On a client the helicopter and its waypoint fly to the world origin (the game doesn't replicate their target).
- Late joiners and respawned players appear in the cabin, high above the map.
- By day the game's enemy spawner places no enemy on Easy, on stock maps too; enemies come at night.

## [0.4.0] - Not released

Skipped: the versioning planned as 0.4.0 (core story 18) ships in 0.5.0.

## [0.3.0] - 2026-10-27

Not released publicly. Game: Nuclear Nightmare V8.1.5 (build 26357084). UE4SS: v3.0.1-1181-g83330635.

### Added

- `core.ui.journal`: the Journal's map page as a host for UI elements (`host = "journal"`), with `watch`, `unwatch`, `isOpen` and `find`.
- `core.ui.panel`: panels that hold other elements (`place = { panel = ... }`), vertical or horizontal, with `order`, `setOrder` and `move` for reordering.
- `core.ui.button`: buttons with click callbacks (`onClick`), on hosts with a cursor (the Journal).

### Changed

- The native part carries the version too; core refuses to start when `main.dll` and the Lua differ.
- Dependents need `need = "0.3.0"` (and `dependsOn` `^0.3.0`); a dependent asking for 0.2.0 is refused with one log line.

## [0.2.0] - 2026-10-24

Not released publicly.

### Added

- `core.ui`: HUD UI helpers (`hud`, `text`, `place`, `debug.overlaps`) that re-attach elements whenever the game rebuilds the HUD.
- `Nucleus_ClockMicros` and `core.clock.micros()`: a monotonic microsecond clock usable from any thread.

### Changed

- Dependents need `need = "0.2.0"`.

## [0.1.0] - 2026-10-23

Not released publicly.

### Added

- The core: a C++ DLL with weak object handles (`Nucleus_Ref`, `Nucleus_Deref`, `Nucleus_RefFree`), a LogicMods Blueprint pak with the `Nucleus_Call` channel, and Lua with the dependent bootstrap, `connect` and logging.

[Unreleased]: https://github.com/NuclearNightmare-Community/nucleus/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/NuclearNightmare-Community/nucleus/releases/tag/v0.5.0
