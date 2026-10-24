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

return M
