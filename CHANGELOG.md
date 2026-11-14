# Changelog

All notable changes to Nucleus are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). From 0.5.0 a dependent's `need` and `dependsOn` are minimum versions (`>=0.5.0`), so a newer Nucleus never asks dependents to raise them. Up to 0.3.0, below 1.0.0 a dependent connected only to the same minor version (`need = "0.3.0"` accepted 0.3.x).

## [Unreleased] - 0.9.0

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635.

For players: mods' settings are kept by Nucleus in each mod's own folder (`Mods/<Mod>/settings.json`), checked every time they're read, and a change reaches the mod while the game runs (the Mod Manager will edit them). A missing settings file means the mod's defaults; a damaged one is ignored with one warning in `UE4SS.log`.

### Added

- The settings service: Nucleus reads each mod's declared settings from its `mod.json` (`settings`: `bool`, `int`, `number`, `enum`, with `default`, `min`, `max`, `step`, `values`, `label`, `help`, `changeable`, `scope`, `source`), keeps their values in `Mods/<Folder>/settings.json` (only values that differ from the defaults; written through `.tmp` and `.bak` so a crash never leaves a half-written file), checks every value against its declaration, and refuses changes outside their window (`menu` outside the title screen; `lobby` always, for now; `restart` saved for the next start; `source` read-only).
- `core.settings`: `get`, `getAll`, `set`, `setFor`, `describe`, `watch`, `unwatch` (README, "Settings service"). `core.has("settings")` is true; `settings` is a listed feature.
- Channel ops `settings-get:<Folder>` and `settings-set:{"mod","key","value"}`, and the shared integer `nucleus.settings.rev` (+1 after every successful write).
- `nucleus.json`, a strict, bounded JSON reader and writer (input 65,536 bytes, depth 16, 4,096 values, strings 1,024 bytes; never runs data as code).

### Notes

- Nothing changes for 0.8.0 callers: every existing call, op, shared variable and test case is as before.

## [Unreleased] - 0.8.0

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635.

For players: mods' screens can show small icons (a checkbox, a gear, a lock, a warning sign, a restart arrow), cut long names with "…" so they stay in their column, grey out a control, and show a tooltip when you hover over something (the Mod Manager's rows use all of these). The icons are placeholders for now; real art replaces them later.

### Added

- `core.ui.image`: `create{ id, place, image, size, style = { tint }, dimmed, tooltip }`, `set(h, { image, dimmed })`, `setVisible`, `remove`, `isShown`, `setTooltip`. An image shows one of Nucleus's own icons (`{ icon = "gear" | "checkbox-on" | "checkbox-off" | "lock" | "warning" | "restart" }`, white textures in Nucleus's pak, tinted at runtime) or one of five allow-listed game textures (`{ game = <path> }`, loaded by path at runtime, never shipped); anything else raises. `size` is a number or `{ w, h }` (4 to 512 units, default 32); an image without a source is an empty cell (a spacer). Images go on every host and in panels, lists and rows, where they keep their size (in a row, centred; with `fill`, centred in their column). A texture that can't be loaded: one `WARN`, the image keeps its size and shows Nucleus's icon for the same meaning (or nothing).
- A text's `style.overflow = "ellipsis" | "clip"`: the text is cut to its box, with `…` for `ellipsis` (where the box is narrower than the text: a row cell with `fill`, a fixed-size parent).
- Buttons take `icon`, `iconSize` (default 24), `dimmed` and `tooltip`. With no label the button is only its icon and its box is exactly `iconSize`; with a label the icon sits left of it. `dimmed` draws the label and icon at the game's disabled colour; hover doesn't brighten it and it still clicks.
- Tooltips: `tooltip` on `button.create` and `image.create`, and `setTooltip(h, tooltip | nil)` on text, buttons and images. A string or a per-language table (`en` required, at most 16 languages, 1 to 512 bytes, plain text), in the engine's tooltip look, on hosts with a cursor only (journal, menu, screen). A text's tag stays in its root `ToolTipText` and never shows on hover.
- `core.has("ui.overflow")`, `core.has("ui.button.icon")` and the path of every new function (`ui.image.create`, `ui.image.set`, `ui.image.setVisible`, `ui.image.remove`, `ui.image.isShown`, `ui.image.setTooltip`, `ui.text.setTooltip`, `ui.button.setTooltip`) are true; `ui.image` is a listed feature.
- Blueprint `WBP_NucleusImage`, Nucleus's icons `Icons/T_Gear`, `T_CheckboxOn`, `T_CheckboxOff`, `T_Lock`, `T_Warning`, `T_Restart` (placeholders drawn by `art/icons/draw.ps1`; `art/icons/README.md` says how real art replaces them), and the button's icon (`SetIcon`, `ClearIcon`, `SetContentColors`).

### Changed

- `unknown style key` now lists `background, font, look, overflow, padding`, and `button.create`'s unknown-key error lists its new keys. Nothing else changes for 0.7.0 callers: a button without an icon, a text without `overflow` and elements without tooltips make the same calls and look the same.

### Notes

- A disabled button (`enabled = false`) shows its tooltip too (seen in the VM).

## [Unreleased] - 0.7.0

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635.

For players: mods can add a button to the title screen's own menu, between OPTIONS and QUIT, that looks like the game's buttons, and open full-screen windows over the menu with scrolling lists in the game's look (the Mod Manager uses this).

### Added

- `core.ui.menu`, the title-screen menu as a host (`host = "menu"`, corner or absolute): `isOpen()`, `watch(fn)` with the events `opened`, `hidden`, `shown` and `lost`, and `unwatch(token)`. While the menu is hidden (Create Server, Server List, another page) its elements are collapsed.
- `core.ui.menu.entry{ id, label, onClick, style }` and `removeEntry(handle)`: one of the game's own buttons in the menu's column, directly above QUIT, styled like OPTIONS (`"options"`, the default) or like the column's first button (`"primary"`), with optional `textColor`, `hoverColor`, `fontSize` (16 to 28), `bold` and `italic`. One per mod; several mods' entries stack above QUIT in the order they attach, and the column's backing grows to fit. The label is a per-language table (`en` required, upper case); the game's language picks the string (tags match in any case).
- `core.ui.screen`: full-screen windows over the menu that form a stack (`open{ id, close }`, `close`, `isOpen`, `top`, `watch`, `unwatch`). Only the top window takes input and keyboard focus; closing a window closes the ones above it and gives focus back to the next window down or the menu. A Close button (`CLOSE`, in the game's language) by default. Elements go on a window with `place = { screen = <window>, corner | absolute }`.
- `core.ui.list` (a scrolling list of a fixed size; children with `place = { list = h }`, at most 256) and `core.ui.row` (a horizontal row in a list, a panel or on a host; children with `place = { row = h, fill = <weight> }`, at most 16; equal weights line up as columns).
- The game's look: `style.look = "game" | "plain"` (the game's look is the default on the menu and windows), and a text's `style.font = "title" | "heading" | "body" | "small"`. The game's fonts and materials are used by path at runtime; nothing of the game's is shipped. If one can't be loaded the element keeps the plain look (one `WARN`).
- Lists, rows and buttons on the menu and on windows (hosts with a cursor). `panel.setStyle`, `setVisible`, `remove`, `isShown`, `order`, `setOrder` and `move` also take a list or a row.
- `core.has("ui.look")` is true; `ui.menu`, `ui.screen`, `ui.list` and `ui.row` are listed features.
- Blueprint widgets `WBP_NucleusList`, `WBP_NucleusRow` and `WBP_NucleusScreen`, and setters on the text, panel and button widgets that take a font or material object.

### Changed

- Error texts that list the hosts now read `valid: hud, journal, menu, screen`, and a button on the HUD raises `buttons need a host with a cursor (journal, menu, screen); ...`. `unknown style key` now lists `background, font, look, padding`, and the valid keys of an intent include `fill, list, row, screen`.
- `WBP_NucleusButton`'s root is now a SizeBox (for the game look's minimum height); its functions are unchanged.

## [0.6.0] - 2026-11-11

Soft release to a few testers, not released publicly. Game: Nuclear Nightmare V8.2.1 (build 26512322). UE4SS: v3.0.1-1181-g83330635.

For players: mods that put buttons or text on the map (the Journal) can now place them on the binder itself, on a page, under the map square or beside the match, task and ammo panels, instead of in the corners of the screen around it.

### Added

- Named Journal regions for `core.ui.place`: `cover`, `binder`, `page-left`, `page-right`, `map`, `map-header`, `match`, `tasks` and `ammo`. A journal intent can put an element in a corner of a region (`{ host = "journal", corner = ..., region = ..., inset = ... }`) or next to one (`{ host = "journal", near = <region>, side, align, gap }`). `inset` takes the gap names (`tight`, `normal`, `loose`) and defaults to `gap`; the first element of a region corner sits `inset` from both edges and each later one stacks `gap` after it.
- The cover, the two pages and the binder are exact: they follow the binder's own anchors, so they hold at any resolution and before the map is drawn. The map square is computed from the binder's own layout before the map is drawn, at any aspect ratio (the map shrinks just below 16:9 and the region with it), and checked once against the drawn map; if the game's layout changes so it can't be computed, it is measured instead, with one `WARN`. The header bar and the match, task and ammo panels are measured once the map is drawn; an element placed by one of them stays hidden until then (at most about 2 s after the map opens) and follows the panel when it moves.
- Journal elements appear with the Journal: they are attached while the game builds it, before its first frame, instead of up to about 1.5 s after it opens. Elements on the cover, the pages, the binder and the map square are drawn in the Journal's first frame. The `opened` event of `core.ui.journal.watch` still comes when core sees the open Journal, as before.
- `core.ui.elements(host)`: `elements("journal")` lists the nine regions; `elements()` and `elements("hud")` return the HUD's elements as before.
- `core.has("ui.journal.regions")` is true.
- The Blueprint helper `Nucleus_RectIn(Canvas, Widget, Frac)` on Nucleus's ModActor: a point of a widget's rectangle in a canvas's local units.
- A region whose widget is missing or has changed after a game patch logs one `WARN` naming it, and its elements stay hidden; nothing raises.

### Changed

- A plain journal `corner` (no `region`) is now a corner of `cover`, the dark binder cover, instead of a corner of the screen outside the binder. Mods that used a journal corner need no change; their elements move onto the binder. Keep wide elements out of `cover`'s bottom corners: the strip under the pages holds the player's perks.
- A journal `near` names a region: `{ host = "journal", near = "crosshair" }` now raises `unknown near region 'crosshair' (valid: ...)` instead of `near is not available on host 'journal'`, and `elements(1)` raises `unknown host 1 (valid: hud, journal)` instead of `expected 0 arguments, got 1`. HUD placement is unchanged.

## [0.5.0] - 2026-11-09

Built for the soft release but never handed out: 0.6.0 replaced it before any files were sent. Not released publicly. Game: Nuclear Nightmare V8.2.1 (build 26512322). UE4SS: v3.0.1-1181-g83330635.

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

[0.6.0]: https://github.com/NuclearNightmare-Community/nucleus/releases/tag/v0.6.0
[0.5.0]: https://github.com/NuclearNightmare-Community/nucleus/releases/tag/v0.5.0
