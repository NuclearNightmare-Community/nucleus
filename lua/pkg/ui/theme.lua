-- Core's theme (story 8, "Style"): the presets every mod's elements share, so mods using presets look the same and a
-- later setting can restyle them all at once. Values are plain numbers: colours 0..1, padding in canvas units.
-- Explicit colours in a style override the theme. Read-only for callers; core may change the values in a minor version.
local M = {}

M.background = {
    none = { r = 0, g = 0, b = 0, a = 0 },     -- no box (the default: exactly the unstyled widget)
    dim  = { r = 0, g = 0, b = 0, a = 0.35 },  -- black at 35%
    dark = { r = 0, g = 0, b = 0, a = 0.70 },  -- black at 70%
}
M.backgroundNames = { "none", "dim", "dark" }

M.padding = { none = 0, tight = 4, normal = 8, loose = 12 }
M.paddingNames = { "none", "tight", "normal", "loose" }

-- Padding when a style has a background but names no padding, so a box never hugs the text.
M.paddingWithBackground = "normal"

-- Story 14: a panel with no style is still a visible box.
M.panelDefault = { background = "dim", padding = "normal" }

-- Story 15: buttons. The background is the button's face (a style's background replaces it); hover and pressed are
-- the theme's, whatever the face. A disabled button keeps its face and is drawn at disabledOpacity.
M.button        = { r = 0.10, g = 0.10, b = 0.10, a = 0.85 }
M.buttonHover   = { r = 0.24, g = 0.24, b = 0.24, a = 0.90 }
M.buttonPressed = { r = 0.04, g = 0.04, b = 0.04, a = 0.95 }
M.buttonPadding = "tight"
M.disabledOpacity = 0.45

-- Story 21 (Mod Manager story 2): lists, rows and windows.
M.listDefault = { background = "dim", padding = "normal" } -- an unstyled list is a visible box, like a panel
M.listInset = 4 -- core story 27: a list's children keep 4 units clear of its right edge (nothing cut at the scrollbar side)
-- Core story 39 (0.15.4, the user's answer 2026-11-18): a row in a list is a little taller, so a 28-unit icon no longer
-- fills it: listRowPadY more padding above and below its content than its style gives, and listRowPadX on each side
-- (the list's scroll area clips at its edge, so the focus chip on a row's first control needs room there too). The
-- focus chip uses that room.
M.listRowPadY = 4
M.listRowPadX = 4
M.backdrop = { r = 0, g = 0, b = 0, a = 0.85 }               -- a window's backdrop over the whole viewport
-- Core story 27 (core 0.12.0): the card a window's content sits on, centred and hugging the content plus padding.
-- Internal: dependents can't set it. background.game in the game look, background.plain when the game look's assets
-- can't be loaded; margin: the least space left between the card and each viewport edge (larger content is clamped).
M.window = {
    background = { game = { r = 0.012, g = 0.016, b = 0.020, a = 0.92 }, plain = { r = 0.05, g = 0.05, b = 0.05, a = 0.90 } },
    padding = 24,
    margin = 32,
    stackGap = 16,   -- between two non-empty corner stacks side by side or one above the other (the hug rule)
}

-- Story 21: the game's own look (style.look = "game", the default on the menu and screen hosts), copied from the
-- title screen's Remaster styles (docs/mod-manager-research.md 1.4). The game's assets are referenced by path and
-- loaded at runtime; nothing of the game's is shipped. An asset that fails to load leaves that element in the plain
-- look (one WARN per asset).
M.game = {
    fonts = {   -- asset paths: package and asset name (AssetRegistryHelpers:GetAsset)
        ExtraBold = { pkg = "/Game/Fonts/Remaster/AlumniSans-ExtraBold_Font", name = "AlumniSans-ExtraBold_Font" },
        SemiBold  = { pkg = "/Game/Fonts/Remaster/AlumniSans-SemiBold_Font", name = "AlumniSans-SemiBold_Font" },
        Regular   = { pkg = "/Game/Fonts/Remaster/AlumniSans-Regular_Font", name = "AlumniSans-Regular_Font" },
    },
    materials = {
        strip     = { pkg = "/Game/Graphics/MainMenu/Styles/Remaster/M_NN_WornStrip", name = "M_NN_WornStrip" },
        selection = { pkg = "/Game/Graphics/MainMenu/Styles/Remaster/M_NN_CinematicSelection", name = "M_NN_CinematicSelection" },
    },
    -- text styles: style.font on a game-look text (default body)
    textFonts = {
        title   = { font = "ExtraBold", size = 34 },
        heading = { font = "SemiBold", size = 26 },
        body    = { font = "Regular", size = 22 },
        small   = { font = "Regular", size = 18 },
    },
    textFontNames = { "title", "heading", "body", "small" },
    buttonFont = { font = "SemiBold", size = 22 },         -- the menu's secondary buttons (OPTIONS, QUIT)
    text         = { r = 0.82, g = 0.85, b = 0.84, a = 1 },
    textHover    = { r = 0.96, g = 0.97, b = 0.94, a = 1 },
    textDisabled = { r = 0.36, g = 0.41, b = 0.43, a = 0.55 },
    shadowA = 0,                                           -- the game's texts have no shadow
    buttonTint = { r = 1, g = 1, b = 1, a = 0.52 },        -- M_NN_WornStrip on a button
    rowTint = { r = 1, g = 1, b = 1, a = 0.72 },           -- M_NN_WornStrip behind a row
    -- Core story 30 (0.12.2): the focused row's strong look, a full-row band. On: a dynamic instance of the selection
    -- material (M_NN_CinematicSelection, whose own fill is near-black) with these fill colours, in focusRowTint.
    -- false: 0.12.1's look (the selection material itself, in rowTint). The colours are the story's start values,
    -- chosen for a visible dark red band under light text.
    focusRowStrong = true,
    focusRowColors = {                                     -- the material's vector parameters, set on the instance
        CinematicBaseColor = { r = 0.10, g = 0.012, b = 0.006, a = 1 },
        CinematicWearColor = { r = 0.16, g = 0.02, b = 0.01, a = 1 },
    },
    focusRowTint = { r = 1, g = 1, b = 1, a = 1 },         -- the workspace's docs/game-ui-components.md 3.3: hovered M_NN_CinematicSelection, tint alpha 1.0
    -- Core story 38 (0.16.0): drag to reorder. accent: the insertion line; carryRowColors: a row picked up with the
    -- keyboard or gamepad (a third instance of the selection material, hotter than the band, in focusRowTint).
    accent = { r = 0.96, g = 0.97, b = 0.94, a = 1 },
    carryRowColors = {
        CinematicBaseColor = { r = 0.30, g = 0.06, b = 0.02, a = 1 },
        CinematicWearColor = { r = 0.45, g = 0.10, b = 0.03, a = 1 },
    },
    -- Core story 39 (0.15.4): the focus chip. While the keyboard or gamepad owns the focus, the focused control inside a
    -- row draws its own face (button, checkbox) or background (choice, slider) with a second instance of the selection
    -- material, its fill clearly brighter than the band (focusChipColors, in focusChipTint), its icon or text in
    -- focusChipInk (story 41).
    -- Without an instance (none alive inside core's key and click handling, or creating it failed) the chip is the solid
    -- focusChipSolid (a brush colour, no asset). An icon-only control's chip reaches focusChipPad units beyond its icon
    -- (at most half the row's gap and the row's own padding, listRowPadX / listRowPadY included). The colours were
    -- retuned from the first VM shots (2026-11-18) to a light red; core story 41 (0.15.5) made it light blue, because the
    -- red was hard to tell from the game's red tick behind a ticked checkbox. Shown only while the input mode is keys
    -- (focus.lua).
    -- focusChipColor is the one chip colour: #6dd5ed, linear (the material's vector parameters and Slate brush colours
    -- are FLinearColor): sRGB c/255 -> ((c/255 + 0.055) / 1.055)^2.4 = 109 -> 0.1529, 213 -> 0.6654, 237 -> 0.8469.
    -- focusChipColors (base and wear) and focusChipSolid are derived from it below; focusChipInk (the chip's icon, label,
    -- choice value and slider number) is set with the derived values below.
    focusChipColor = { r = 0.1529, g = 0.6654, b = 0.8469, a = 1 },
    focusChipTint = { r = 1, g = 1, b = 1, a = 1 },
    focusChipPad = 4,
    buttonPadding = { l = 12, t = 4, r = 12, b = 4 },
    buttonMinHeight = 44,
    -- Mod Manager story 4: the controls. A choice's value and arrows and a slider's number box in AlumniSans (the
    -- Settings menu's body font) in the menu's text colours, on the worn strip; the slider's bar and handle copied from
    -- the Settings menu's own slider (its widget-tree template, read live), else WBP_<Core>Slider's generated copy of it
    -- (bar 2 px (0.44, 0.51, 0.52, 0.8), hover (0.7, 0.79, 0.79, 1); handle 8x20 (0.86, 0.92, 0.89, 1), hover (1, 1, 0.97, 1)).
    controlFont = { font = "Regular", size = 22 },
    controlTint = { r = 1, g = 1, b = 1, a = 0.52 },       -- M_NN_WornStrip behind a choice and a slider's number box
    sliderTemplate = { pkg = "/Game/Graphics/MainMenu/SettingsMenu", name = "SettingsMenu_C", sub = "WidgetTree.Slider" },
    -- Core story 33 (0.15.0): game-style rows. The game's tooltip widget (the create-server screen's "?" tooltips; its
    -- Description FText is shown, wrapped at 400) and the game's picker (choice widget = "game"); and the look a
    -- game-style row falls back to when its like row isn't a game row: the worn strip (rowTint), the body font in the
    -- menu's text colour, these slots (HorizontalBoxSlot padding l, t, r, b; size Fill 1 for the label, Auto otherwise;
    -- vertical alignment Center).
    tooltipWidget = { pkg = "/Game/HexTree/Widgets/Elements/W_ToolTip3", name = "W_ToolTip3_C" },
    pickerWidget = { pkg = "/Game/Graphics/MainMenu/Components/MultipleSelectBox", name = "MultipleSelectBox_C" },
    likeFallback = { labelPad = { l = 12, t = 4, r = 12, b = 4 }, helpPad = { l = 8, t = 0, r = 12, b = 0 } },
}

-- Core story 38 (0.16.0): drag to reorder rows in a list. edge: the auto-scroll zone at a list's top and bottom (units);
-- speed: the auto-scroll speed at the edge itself (units per second, proportional to the pointer's depth in the zone);
-- lineH: the insertion line's height; lift: a carried row's render translation to the right; sourceOpacity: a dragged
-- row's opacity while its copy follows the pointer; holdMs: how long A or Enter is held on a row to pick it up (a
-- shorter press is a tap: the control's own action); loopMs: the drag and hold loop's period.
M.reorder = { edge = 32, speed = 600, lineH = 2, lift = 8, sourceOpacity = 0.4, holdMs = 400, loopMs = 16 }

-- Story 24 (core 0.8.0, Mod Manager CAP-2): images and icons. Core's own icons are white on transparent 128x128
-- textures in core's pak (/Game/Mods/<Core>/Icons/T_<Key in CamelCase>), tinted at runtime; key -> asset name.
M.icons = {
    gear = "T_Gear", ["checkbox-on"] = "T_CheckboxOn", ["checkbox-off"] = "T_CheckboxOff",
    lock = "T_Lock", warning = "T_Warning", restart = "T_Restart",
}
M.iconNames = { "checkbox-off", "checkbox-on", "gear", "lock", "restart", "warning" }
-- The game's textures an image may name ({ game = <path> }), loaded by path at runtime and never shipped (each one is in
-- the workspace's tools/diff-dumps.watch.json). Path -> core's icon for the same meaning (shown when the texture can't
-- be loaded), or false when core has none.
M.gameTextures = {
    ["/Game/Graphics/MainMenu/Textures/checkbox_ticked.checkbox_ticked"] = "checkbox-on",
    ["/Game/Graphics/MainMenu/Textures/checkbox_unticked.checkbox_unticked"] = "checkbox-off",
    ["/Game/AntizeVOIPSystem/Widgets/Settings/T_Settings.T_Settings"] = "gear",
    ["/Game/HexTree/Widgets/reset-icon.reset-icon"] = "restart",
    ["/Game/HexTree/Textures/T_Question.T_Question"] = false,
}
M.gameTextureNames = {
    "/Game/Graphics/MainMenu/Textures/checkbox_ticked.checkbox_ticked",
    "/Game/Graphics/MainMenu/Textures/checkbox_unticked.checkbox_unticked",
    "/Game/AntizeVOIPSystem/Widgets/Settings/T_Settings.T_Settings",
    "/Game/HexTree/Widgets/reset-icon.reset-icon",
    "/Game/HexTree/Textures/T_Question.T_Question",
}
M.imageSize = 32                                   -- an image's default size (square), canvas units
M.iconSize = 24                                    -- a button icon's default size
M.iconGap = 8                                      -- between a button's icon and its label (core's widget, fixed)
M.imageTint = { r = 1, g = 1, b = 1, a = 1 }       -- an image's default tint: the texture as it is
M.dimmed = M.game.textDisabled                     -- dimmed = true: the game's disabled colour
M.white = { r = 1, g = 1, b = 1, a = 1 }           -- a plain button's label and icon (the generator's)
-- Core story 41 (0.15.5): the focus chip's derived values (theme.game.focusChipColor above). Readers such as Mod
-- Manager's screen driver read focusChipColors.CinematicBaseColor: the table keeps story 39's shape.
do
    local g = M.game
    local function copy(c) return { r = c.r, g = c.g, b = c.b, a = c.a } end
    g.focusChipColors = {                          -- the material's vector parameters, set on the chip instance
        CinematicBaseColor = copy(g.focusChipColor),
        CinematicWearColor = copy(g.focusChipColor),
    }
    g.focusChipSolid = copy(g.focusChipColor)      -- the chip without an instance (a brush colour)
    -- the content on the chip (story 41): near-black, sRGB #101418 (the panel as drawn in the VM shot), linear, because
    -- white read poorly on the light blue in the first VM shot (sp-mm-chip-cfg.png: white gear on #6dd5ed, contrast about
    -- 1.7:1)
    g.focusChipInk = { r = 0.0052, g = 0.0070, b = 0.0091, a = 1 }
    -- Core story 42 (0.17.1): behind a chipped checkbox's icon (WBP_<Core>Button's IconBack), so its transparent inside
    -- stays as dark as unfocused instead of showing the light chip: the panel as an unfocused checkbox shows it through
    -- its inside (the card, theme.window's game background, over the row; sRGB #101418 in the VM shot, the same value
    -- as focusChipInk), opaque.
    g.focusChipBack = copy(g.focusChipInk)
end

-- Mod Manager story 4 (core 0.10.0): the controls. A checkbox shows the game's checkbox textures (falling back to core's
-- checkbox-on / checkbox-off icons when they can't be loaded), sizes 16-64 (default 28).
M.checkboxOn = { game = "/Game/Graphics/MainMenu/Textures/checkbox_ticked.checkbox_ticked" }
M.checkboxOff = { game = "/Game/Graphics/MainMenu/Textures/checkbox_unticked.checkbox_unticked" }
M.checkboxSize = 28
M.plainControl = { r = 0.10, g = 0.10, b = 0.10, a = 0.85 } -- a plain-look choice's and number box's background (a button's face)
M.plainControlFont = 18                                      -- the engine font's size in the plain look (the generator's)

return M
