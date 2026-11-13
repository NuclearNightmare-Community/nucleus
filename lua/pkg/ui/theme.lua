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
M.backdrop = { r = 0, g = 0, b = 0, a = 0.85 }               -- a window's backdrop over the whole viewport

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
    buttonPadding = { l = 12, t = 4, r = 12, b = 4 },
    buttonMinHeight = 44,
}

return M
