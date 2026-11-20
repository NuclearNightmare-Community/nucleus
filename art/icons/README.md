# Core's icons (placeholders)

The eleven PNGs here are **placeholders**: plain shapes drawn by `draw.ps1` with System.Drawing (our own work, no third-party art). They stand in until the user's icon art exists.

| File | Icon key (`{ icon = <key> }`) | Asset in `Nucleus.pak` |
|---|---|---|
| `gear.png` | `gear` | `/Game/Mods/Nucleus/Icons/T_Gear` |
| `checkbox-on.png` | `checkbox-on` | `/Game/Mods/Nucleus/Icons/T_CheckboxOn` |
| `checkbox-off.png` | `checkbox-off` | `/Game/Mods/Nucleus/Icons/T_CheckboxOff` |
| `lock.png` | `lock` | `/Game/Mods/Nucleus/Icons/T_Lock` |
| `warning.png` | `warning` | `/Game/Mods/Nucleus/Icons/T_Warning` |
| `restart.png` | `restart` | `/Game/Mods/Nucleus/Icons/T_Restart` |
| `scope-host.png` | `scope-host` | `/Game/Mods/Nucleus/Icons/T_ScopeHost` |
| `scope-client.png` | `scope-client` | `/Game/Mods/Nucleus/Icons/T_ScopeClient` |
| `scope-host-plus.png` | `scope-host-plus` | `/Game/Mods/Nucleus/Icons/T_ScopeHostPlus` |
| `scope-both.png` | `scope-both` | `/Game/Mods/Nucleus/Icons/T_ScopeBoth` |
| `scope-unknown.png` | `scope-unknown` | `/Game/Mods/Nucleus/Icons/T_ScopeUnknown` |

The five `scope-*` icons (Mod Manager story 12, core 0.21.0) show where a mod runs (its `mod.json` `scope`): a house for the host, a person for a player, a house with a small person for `host-plus`, a house and a person with a plus for `both`, and a question mark in a ring for unknown.

`build.ps1` passes this folder to CoreGen, which imports every PNG as a texture (UserInterface2D, no mips, UI texture group, never streamed) and fails if one is missing. Core tints the textures at runtime (dimmed, game colours), so they must stay **white on a transparent background**.

## Replacing them with real art

1. Draw or export each icon as a **128x128 PNG, white on transparent**. Vector art (SVG) has to be rasterized first: Slate can't draw SVG at runtime.
2. Save it here under the **same file name**, replacing the placeholder. Only art you hold the rights to (or that is open source with a licence that allows shipping) goes here.
3. Run `build.ps1` (its `blueprint` step re-imports the PNGs), then deploy and check them in game.

Don't re-run `draw.ps1` after that: it rewrites all eleven files with the placeholders.
