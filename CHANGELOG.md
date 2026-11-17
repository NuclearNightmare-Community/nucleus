# Changelog

All notable changes to Nucleus are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). From 0.5.0 a dependent's `need` and `dependsOn` are minimum versions (`>=0.5.0`), so a newer Nucleus never asks dependents to raise them. Up to 0.3.0, below 1.0.0 a dependent connected only to the same minor version (`need = "0.3.0"` accepted 0.3.x).

## [0.14.0] - 2026-11-17

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635.

For players: nothing changes on its own. Mods can now put their own rows inside the create-server screen's world settings list, among the game's rows (for example right after Difficulty), instead of over the screen.

### Added

- A placement intent inside one of the game's own boxes on a game screen (core story 32, UI-14): `{ host = "createServer", container = "<game widget name>", after = "<name>" | before = "<name>" | index = n | at = "end" }`, for every element kind. `container` names a `VerticalBox`, `HorizontalBox` or `ScrollBox` in the open screen's widget tree by its widget name (never a path; for example `VerticalBox_202`, the world settings list); anchors name a direct child of it. Positions count the game's children only: `after` and `before` a named game child, `index = n` before the game's n-th child (1-based, 1 to 256), `at = "end"` after the last; several elements at one position keep their creation order, and another mod's core widgets in the box stay right after the game child they followed.
- How it is done: box panels only append, so at the poll's `opened` core attaches the elements of each box and rebuilds the box once: from the first child out of order, every child is removed and added back in the wanted order, each game child with its own slot values (padding, size, alignment) copied back. Nothing is rebuilt when the order is already right. The game's rows are removed and re-added once per open that way. A re-added row's game pickers (`MultipleSelectBox_C`) run their PreConstruct again, which shows their default option, so core reads each picker's selected index before the row is taken out and sets it back afterwards (`SetSelectedOption`, which runs no game handler): the rows keep the values the game or the player set. The rows are otherwise never changed.
- A create or place of a container element while the screen is open never touches the game's box inside the call: the container is queued and its insert pass runs on the host's next poll tick (within about half a second), one pass per container however many calls. So a dependent calling from one of the game's hooks never rebuilds the list inside it, and several creates give one rebuild. `isShown` is false until then.
- Fallbacks: an anchor that isn't a child of the box puts the element at the end of the box, and an index past the box's last game child does the same; a container that isn't found leaves the element unattached until the next open (`isShown` false), and so does a widget of that name that isn't one of the three box classes (its `WARN` says what it is: `'X' is a <class>, not VerticalBox, HorizontalBox or ScrollBox`). Each logs one `WARN` naming it, once per Lua state.
- `isShown` of a container element means it is in its container on the open, drawn screen and not hidden by `setVisible`; the game may still hide the list itself (the create-server screen's settings list stays hidden until CONFIGURE).
- `core.ui.text.stats()` counts `containerRebuilds`. Feature `ui.place.container` (`core.has`).

### Changed

- The `unknown key` error of an intent lists the new keys: `valid keys: absolute, after, align, at, before, container, corner, fill, gap, host, index, inset, list, near, offset, panel, region, row, screen, side`. No other text changes. A `container` on the `hud`, `journal`, `menu` or `screen` host, with a corner, near or absolute key, or inside a core panel, list or row raises a clean `nucleus.ui.place: ...` error.

## [0.13.0] - 2026-11-17

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635.

For players: nothing changes on its own. Mods can now add their own text, buttons and controls to the game's create-server screen (START GAME), for example extra world settings.

### Added

- `core.ui.game`, the game's own menu screens as hosts, keyed by host name (core story 31, UI-13). The first and only one is `"createServer"`, the create-server screen that START GAME builds new on every open. `watch(host, fn)` returns a token; `fn(screen, info)` gets `info = { event, host, path, reason }` with `event` one of `opened` (the first 500 ms tick that sees a local player's screen in the viewport), `closed` (the screen left the viewport but still exists, as after Back) and `lost` (its object is gone, as after Create's map change, or a newer screen replaced it). The screen is passed only with `opened` and is valid only during that callback. A watcher added while a screen is open hears a synthetic `opened` on the next tick; a watcher that never heard `opened` hears no `closed` or `lost`; at most one event per host per tick; a throwing watcher is logged once and the others still run. `unwatch(token)` raises for a token `game.watch` never issued (an issued one again does nothing); `isOpen(host)` reads the viewport directly, so it can turn true up to one 500 ms tick before watchers hear `opened` (elements attach only at `opened`). Every function refuses before `connect` and off the game thread, and an unknown host raises `nucleus.ui.game.<fn>: unknown game screen <host> (valid: createServer)`.
- The placement host `"createServer"`: text, buttons, panels, lists, rows, images, checkboxes, choices and sliders go on it with `corner` or `absolute` intents (`near` and `region` raise, `elements("createServer")` is empty). Every open gets new widgets in the screen's root canvas (`CanvasPanel_21`), in the game's look by default; on `closed` and `lost` only their handles are freed. Like the menu since 0.12.3, nothing is done inside one of the game's hooks: core registers no hook on the screen's class, and the elements arrive with `opened`, within about a second (one or two ticks) of the screen appearing. The createServer host has no keyboard or gamepad focus navigation yet (the mouse only; windows keep theirs).
- Features `ui.game` and `ui.game.createServer` (`core.has`).

### Changed

- The `unknown host` error lists of `core.ui.place` and `core.ui.elements` now read `valid: createServer, hud, journal, menu, screen`. No other text changes (the "need a host with a cursor (journal, menu, screen)" texts stay as they were, although `createServer` has a cursor too).

## [0.12.3] - 2026-11-17

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635.

For players: removes the cause of a rare crash on the return to the title menu after a match, with a mod that adds a menu entry (Mod Manager's MANAGE MODS) or menu elements. After a match, the entry now appears a moment after the menu shows (QUIT moves down one row then).

### Fixed

- The menu entry and menu elements are no longer added inside `MainMenu_C:Construct`; this removes the path of a rare crash on the return to the menu after a match (core story 34, Lua only, no pak change). Since 0.7.0 every menu after the first got its entry (and its menu elements) inside the menu's `Construct` post-hook, changing the menu's widget tree while the game was still creating it, right after a world teardown and a garbage collection; rarely (about one return in six or rarer), a property read there returned a freed object and the game crashed (`EXCEPTION_ACCESS_VIOLATION` in UE4SS's `IsA`). Now every menu gets them the way the first menu always did, from the 500 ms poll's `opened`, within about a second (one or two ticks) of the menu appearing, and core no longer registers a hook on `MainMenu_C:Construct` at all: no Lua runs in that hook, so the crash path is gone (one test run can't show a crash this rare is fixed; the fix is that its code no longer runs). On a return from a match the entry appears a moment after the menu shows, and QUIT moves down one row then. The entry's look, position, backing growth and clicks are unchanged; the Journal's Construct hooks are unchanged.

## [0.12.2] - 2026-11-17

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635.

For players: in a mod's window, the row you are on with the keyboard or a gamepad is now a clearly visible full-row band.

### Changed

- The focused row's highlight is a full-row band (core story 30, Lua only, no pak change). In 0.12.1 the focused row showed the game's selection material `M_NN_CinematicSelection`, whose own fill is near-black, so on a window's dark card it read only as a thin red line under the row. Now the row shows an instance of that material (`MaterialInstanceDynamic`, its parent `M_NN_CinematicSelection`, the game's grain, wear and red selection line kept) with its fill colours `CinematicBaseColor` and `CinematicWearColor` lifted to a dark red band, at full opacity. One instance per mod's Lua state, shared by every row, kept only as a weak handle and made again after a map change or a garbage collection that took it. It is never made inside core's own key and click handling, control dispatch or a Construct hook, so a key or click that comes first while none exists shows 0.12.1's look until the next UI tick (500 ms). The switch is theme data, not an option or a setting: turning the strong look off means editing `focusRowStrong` in core's `lua/pkg/ui/theme.lua` (default `true`; `false` gives 0.12.1's look exactly), with the colours `focusRowColors` and the tint `focusRowTint` beside it. If the instance can't be made, focused rows keep 0.12.1's look and one `WARN` is logged. Focus faces, buttons, unfocused rows and mouse hover are unchanged.

## [0.12.1] - 2026-11-16

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635.

For players: in a mod's window, the keyboard and gamepad focus can now be seen on every row: the focused row and icon buttons are highlighted.

### Fixed

- The focused row and icon buttons are highlighted (core story 28, Lua only, no pak change). In 0.12.0 focus moved, but on a row whose only focusable is a dimmed or icon-only button (Mod Manager's gear) nothing showed it: the button's focus look (`SetFocusLook`: the hover brush and the hover colours) changes nothing on a dimmed button (hover = normal) or on a game-look icon-only one (no face). Now, while an element holds keyboard focus, the row holding it shows the game's selection material (`M_NN_CinematicSelection`, in the row tint) instead of its own background, at most one row per window; a dimmed button is drawn like its undimmed self (the hover brush and the hover colours) and a game-look icon-only button or checkbox gets the selection material as its face. Both go back to the row's and the element's own style when focus leaves them (focus moves, the window takes it, the element is removed, hidden or disabled, another window covers this one, the window closes), and the UI tick puts them back after a dependent re-styles the focused element or its row. Mouse hover is unchanged (hovering a dimmed button still doesn't light it up; a click focuses it, and while focused it is drawn undimmed); other buttons keep 0.12.0's focus look. A failed widget call logs one `WARN` and focus keeps working; without the game's selection material there is no highlight (`assets.lua`'s one `WARN`).

## [0.12.0] - 2026-11-14

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635.

For players: in a hosted match, the host's mods can tell which other players run the same mods, and in which version, so they only rely on a player's own machine when it can play along. Players without Nucleus are not affected.

For players: a mod's window on the title screen now sits on one panel in the middle of the screen, just big enough for what it shows; its button bottom-left reads BACK; and the keyboard and a gamepad work in it: the arrow keys or the D-pad move between its buttons and controls (the one you are on is highlighted, and a list scrolls to it), Left and Right change a choice or a slider, Enter or A presses a button, and Escape or B closes the window.

### Added

- Player presence in `core.net` (core story 23, Net-2, CAP-12; README, "Player presence"): `presence(player, modId) -> version | nil, "absent" | nil, "no-world"`, `watchPresence(modId, fn) -> id` with `fn(event, playerId, version, previous)` for `"joined"`, `"changed"` and `"left"` (the id works with `core.net.unwatch`), `compatible(player, modId) -> true | false, "absent" | "incompatible" | "no-world"`, and the pure `versionsCompatible(aVersion, aNetCompat, bVersion, bNetCompat) -> boolean`. `player` is a `PlayerState` or its integer `PlayerId`. Presence, its watches and `compatible` are host-side (also in the menu, where only the local player exists) and raise on a client. The local player's record is this machine's own list.
- The optional `mod.json` field `netCompat`: the oldest version of the same mod this version works with over the network (strict `x.y.z`, not above `version`). Without it the default is `0.<minor>.0` for 0.x and `<major>.0.0` from 1.0. Two machines are compatible for a mod when each version is at least the other's `netCompat`; that is the one rule `compatible` and `versionsCompatible` apply.
- `NucleusPresence` in Nucleus's pak (generated by CoreGen; `build.ps1`'s pack guard requires it): replicated, always relevant, a replicated `CoreVersion` set only through `Nucleus_PresenceSetVersion`, and one reliable server event `Nucleus_SV_Report(Report)` whose Blueprint body checks the report's length before any Lua copies it (over 8,192 characters it calls `Nucleus_PresenceIn("", Len)`, otherwise `Nucleus_PresenceIn(Report, Len)`). On the host Nucleus spawns one per client player controller, owned by that controller; none for the host's own controller, none on a client or in the menu. A player leaving loses its record and its actor.
- What a machine reports: Nucleus itself plus every connected dependent, each with its `mod.json` `id`, `version` and `netCompat`, registered at `connect` and removed when the mod unloads. A modded client sends the list once it holds its own `NucleusPresence` and again 2 s after the list changes.
- The channel ops `net-mod:<id>=<version>[/<netCompat>]` and `net-mod-off:<id>`, and the shared variables `nucleus.net.presence` (the snapshot) and `nucleus.net.presence.gen`.
- Features: `net.presence`, `net.watchPresence`, `net.compatible`, `net.versionsCompatible`.
- Windows on a panel (core story 27, UI-12, CAP-7; README, "UI helpers"): a window's content sits on one card (`WBP_NucleusScreen`: the scrim, then a centred Border `Card` with theme colour (0.012, 0.016, 0.020, 0.92) and padding 24 around a SizeBox `Inner` and the window's `Canvas`), sized to the hug of its elements (each corner stack with its inset, stacks side by side or one above the other plus 16 between them, an absolute element where its anchor puts it) before the window's first frame, again whenever an element on the window is created, removed, shown, hidden, re-texted, re-styled or moved, and on the 500 ms tick when a measured size changed. It is clamped to the viewport less 32 units on each side; larger content logs one `WARN` per window id. Not settable by dependents.
- BACK (core's string `back`, English `BACK`; `close` stays in the strings table): core's button on a `close = true` window, the first element of the card's bottom-left corner (a dependent's bottom-left elements stack after it). Its tag stays `...:#close:<id>` and its close's reason stays `close`, so drivers that find it by tag keep working.
- Keyboard and gamepad focus on windows (core story 27; `lua/pkg/ui/focus.lua`): `WBP_NucleusScreen` overrides `OnPreviewKeyDown` (Slate's navigation direction and Accept / Back action, Escape and the gamepad's B always Back; the preview pass, because a focused Button answers the arrow keys in `OnKeyDown` with Slate's own navigation, so they never bubble to the window) and calls the hookable `Nucleus_OnNav`; a key is left to the focused widget for Accept on a button (its own click) and while a text box (the slider's number box) holds focus; each dependent's Lua state post-hooks it once, by full path, from the UI poll, and answers only for its own window. Focus moves over lines of focusable elements (button, checkbox, choice, slider; enabled, visible): a list's rows (a row's focusables left to right), then the window's own, then BACK. Up / Down move between lines (nearest column, no wrap), Left / Right within a line, or step a focused choice (`onChange` once, the end arrow inert) or slider (`value` +- `step`, a Default slider from `defaultValue`); Enter / A clicks the focused button through its own click path; Escape / B closes the top window (reason `close`) when it was opened with `close = true`. Opening a window focuses its first element (also when the dependent builds the window right after `screen.open`); the focused one shows its hover look (`SetFocusLook` on the button, choice and slider widgets); a focused row is scrolled into view; a focused element that is removed, hidden or disabled hands focus to the nearest in its line, else the next line, else BACK; a mouse click moves the focus too; after a close the window below gets its last-focused element back; the UI tick takes focus back when it left the top window. Choice and slider widgets are focusable now (their arrows and bar are not); the window's root stops Slate's own navigation at its edges.
- The list and row gap `compact` (4 units), for `ui.list.create` and `ui.row.create` only.
- Features: `ui.screen.panel`, `ui.screen.focus`, `ui.gap.compact`.
- `nucleus.modid` (distribution story 13; README, "Versioning"): `normalize(id) -> id | nil, message`, the mod id normalizer of `mod-ids.md` (lowercase, `github.com/<owner>.<mod>` -> `<owner>.<mod>`, `[a-z0-9-]` parts, at most 200 bytes; URLs, other hosts and bare ids refused; never raises; messages don't echo the input). It runs the shared cases `test/unit/fixtures/modid-cases.json`, a byte-identical copy of the workspace's `tools/release/tests/modid-cases.json`, with the same results and messages as the release tools' PowerShell normalizer (`test/unit/modid_test.lua`). Pure, so a dependent can `require` it. Its refusal messages changed from the 0.11.0 module's; `netId` and `isNetId` are unchanged. Bad-input cases `modid-*` in the `bad-input` scenario (written; not yet run in the game).

### Fixed

- The right-end checkbox of a row (story 26's controls window) and Mod Manager's gears were cut at the right (core story 27, measured in the VM: each sat 4 units past its row's right edge, inside the list's clipping). Cause: a fixed-size row child (checkbox, icon-only button, image) is centred in its slot, and Slate centres a child at (allotted - size) / 2 + left - right padding, so a gap carried as left padding alone pushed it half a gap (4 units at `tight`) past its slot's right edge. The gap before such a child is now split 3/4 left, 1/4 right (the same total space; the child sits centred in its slot less the gap, also in a `fill` column), and a list's children keep 4 units clear of the list's right edge (`theme.listInset`). Every row's last child now ends 4 units inside the list's visible area, arranged at its own size.

### Changed

- A window's `corner` and `absolute` intents resolve inside its card's inner area, no longer the full-screen canvas (core story 27; windows made for 0.7.0-0.11.0 that placed elements far from the corners, like Mod Manager 0.1.0's `absolute` x 360, now push the card wide: place them by corner, and size lists from the card).
- A list's default gap is `compact` (4 units; was `tight`, 8); a row's stays `tight`. The list and row unknown-gap message lists `(valid: compact, tight, normal, loose)`; placement intents and panels keep `(valid: tight, normal, loose)` and refuse `compact`.
- BACK replaces CLOSE on windows (same tag, same reason `close`), bottom-left on the card instead of top-right on the screen; Escape and the gamepad's B close the top window.
- Nucleus's id is now `nuclearnightmare-community.nucleus` (was `nucleus`), the namespaced form every released mod takes before the first public release (distribution story 13, `mod-ids.md`). Dependents name it in `dependsOn`; the test dependents `SkelTest` and `SkelPeer` do. The folder, `mods.txt` line, `name` and core's own presence entry (its lowercase name) are unchanged.

### Notes

- Presence (core story 23) is add-only: no existing function, channel op or class changed; `compat.floor` is unchanged. Distribution story 13 changes only `nucleus.modid`'s refusal messages and the id (above).
- Everything a client sends is checked on the host: the player is the actor's owner's `PlayerState` (never anything in the report); at most 32 pairs and 8192 bytes (more rejects the whole report); ids normalized (namespaced, or a legacy bare id), versions strict `x.y.z` with each part 0..999 (a bad pair is dropped, the rest kept; on a duplicate id the first wins); at most 1 report per player per second and 10 per minute. Rejects log at most one line per player per minute. A client whose Nucleus version differs from the host's never reports (one line per world). The host keeps at most 64 client records per world.
- A `mod.json` `version` that isn't strict `x.y.z` keeps that mod out of presence (one line at `connect`); an invalid `netCompat`, or one above `version`, is left out (one line at `connect`).
- Test dependent: `test/SkelTest/mod.json`'s `version` is now `0.1.0`.

## [Unreleased] - 0.11.0

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635.

For players: in a hosted match, mods on the host can pass a few numbers (a difficulty setting, say) to the same mods on the other players' machines. Players without Nucleus are not affected.

### Added

- `core.net` (core story 22, Net-1, CAP-11): `publish(key, value)`, `read(key, min, max)`, `watch(key, min, max, fn)`, `unwatch(id)`, `role()` (README, "Host replicated state"). A key is `<mod id>.<name>`: the mod's own `mod.json` `id` (normalized; namespaced or a legacy bare id) and a name of `[A-Za-z0-9_]{1,32}`; a value is a 32-bit integer. Only the host publishes (`publish` raises on a client, returns `false, "standalone"` in the menu and `false, "no-world"` before the first world); every machine reads, each read with the reader's own bounds (`nil, "out-of-bounds"`, `"absent"`, `"no-state"` or `"version"`). Caps: 16 keys per mod, 64 in all, 16 publishing mods per world. Values belong to the world they were published in.
- `NucleusNet` in Nucleus's pak (generated by CoreGen; `build.ps1`'s pack guard requires it): Nucleus's first replicated class (always relevant, two replicated strings `State` and `CoreVersion`, set only through `Nucleus_NetSetState` and `Nucleus_NetSetVersion`). Nucleus spawns one per hosted world, with no owner, never on a client or in the menu. `ModActor` stays local.
- The channel op `net-publish:<key>=<value>` and the shared variables `nucleus.net.role`, `.status`, `.snapshot`, `.gen`.
- `nucleus.modid`, the mod id normalizer (`spec-distribution-v0/mod-ids.md`), with the Mod Manager's test cases.
- Features: `net` and `net.publish`, `net.read`, `net.watch`, `net.unwatch`, `net.role`.

### Notes

- Add-only: no existing function, channel op or class changed.
- A client reads the host's values only when both run exactly the same Nucleus version (the replicated `CoreVersion`); otherwise reads say `"version"` and the client logs one line per world. Everything that arrives is checked again on the client (size, numbers, ids, names, caps) before any mod sees it; bad entries are dropped with at most one log line per key per minute.
- Test dependent: `test/SkelTest/mod.json`'s `id` is now `skeltest` (the id its `core.net` keys use).

## [Unreleased] - 0.10.0

Game: Nuclear Nightmare V8.2.3 (build 26601774). UE4SS: v3.0.1-1181-g83330635.

For players: mods' screens can now have checkboxes, pickers with arrows (one value of a list, or a number) and sliders with a number box you can type into, drawn in the game's own style. A greyed-out control shows a setting you can't change from there.

### Added

- `core.ui.checkbox` (UI-11, core story 26, Mod Manager story 4): `create{ id, checked, onChange, place, enabled, tooltip, size }`, `get`, `set`, `setEnabled`, `setVisible`, `remove`, `isShown`, `setTooltip`. The game's ticked and unticked checkbox textures (loaded by path at runtime, never shipped; Nucleus's `checkbox-on` / `checkbox-off` icons when they can't be loaded), 16 to 64 units (default 28), lit on hover. A real click toggles it and calls `onChange(handle, checked)` once; `set` never calls back.
- `core.ui.choice`: `create{ id, options, selected, onChange, place, enabled, tooltip, widget }`, `get(h) -> index, option`, `set(h, index)`, `setEnabled`, `setVisible`, `remove`, `isShown`, `setTooltip`, and `range{ id, min, max, step, extra }` (at most 64 option strings, `extra` first). 1 to 64 options of 1 to 64 bytes; prev/next arrows step one option without wrapping, the arrow at its end dimmed and inert; the first option shows from the widget's first frame. `onChange(handle, index, option)` once per arrow click. `widget = "game"` (the game's own picker) raises "not available yet"; `"core"` is accepted.
- `core.ui.slider`: `create{ id, min, max, step, value, defaultValue, hint, onChange, place, enabled, tooltip }`, `get(h) -> value | nil`, `set(h, value | nil)`, `setDefault(h, defaultValue[, hint])` (an omitted hint keeps the current one, `nil` clears it), `setEnabled`, `setVisible`, `remove`, `isShown`, `setTooltip`. A slider and a number box synced inside the Blueprint (no Lua per drag frame); Lua hears the end of a drag and the box's commit, parses the text (`.` or `,`), clamps it to `min..max` and rounds it to `min + k * step`; unparsable text restores the last value; an empty box is Default (`nil`: the hint shows, the slider sits at `defaultValue`). `onChange(handle, value)` once per real change, never for `set`, `setDefault` or an unchanged commit. `min < max`, `step > 0`, at most 10,000 steps; the hint at most 64 bytes (the box widens while it shows one). `value` and `defaultValue` are snapped to `min + k * step` on create, `set` and `setDefault`. The bar and handle are copied from the game's Settings menu slider (read live), else the widget's generated copy of that style with one `WARN`.
- `enabled = false` on all three keeps the control visible, dimmed and deaf to input. They go on hosts with a cursor (journal, menu, screen) and in panels, lists and rows (`fill` allowed; a checkbox keeps its size); values and enabled state are re-applied whenever a window or host opens again.
- `WBP_NucleusChoice` and `WBP_NucleusSlider` in Nucleus's pak (generated by CoreGen; `build.ps1`'s pack guard requires them). The checkbox is an icon-only `WBP_NucleusButton`: its click hook routes by element kind.
- Features: the path of every new function (`ui.checkbox.create` ... `ui.slider.setTooltip`, `ui.choice.range`), so `core.has("ui.slider.create")` is true on 0.10.0 and false on 0.9.0.

### Notes

- Add-only: no existing function's behaviour changed. The new functions' error texts follow the usual `nucleus.ui.<fn>: <problem>` form; moving a panel holding a control onto the HUD raises `... holds controls (checkboxes, choices or sliders), which need a host with a cursor ...`.
- Each dependent's Lua state registers the new Blueprint hooks (`Nucleus_OnPrev`, `Nucleus_OnNext`, `Nucleus_OnSliderEnd`, `Nucleus_OnSliderCommit`, and the button click hook for checkboxes) once, from the UI poll, never inside a hook: a control is live for input within about half a second of its creation.
- The slider is not focusable; keyboard edits go through its box. No gamepad pass yet.

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
