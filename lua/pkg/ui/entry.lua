-- Story 21 (Mod Manager story 2): a dependent's entry in the title-screen menu's own button column. Exposed as
-- core.ui.menu.entry and core.ui.menu.removeEntry:
--   entry{ id = <string>, label = { en = "MANAGE MODS", ["zh-Hans"] = ..., ... }, onClick = <function>,
--          style = "options" | "primary" | { preset = <name>, textColor, hoverColor, fontSize, bold, italic } } -> handle
--   removeEntry(handle)          takes the entry out of a live menu and shrinks the backing again; idempotent
--
-- The entry is one of the game's own buttons (UI_Button_Master_C), created by core and inserted into the column
-- VerticalBox_104 directly above QUIT (UI_Button_Master_3), so it sits between OPTIONS (UI_Button_Master_2) and QUIT;
-- entries of several dependents stack above QUIT in the order they attach. One entry per dependent. The order of
-- operations is the mini-spike's, proven in the VM (docs/mod-manager-research.md 9.5, 9.6):
--   1. the button class is loaded (the menu uses it) and found with StaticFindObject (a hit);
--   2. the column, OPTIONS and QUIT are found by name; both must be children of the column, else one WARN per Lua
--      state and nothing is added;
--   3. Create, then BEFORE the add copy the style source's instance properties (PreConstruct pushes them on the add)
--      and set Button Text to the label for the game's language;
--   4. QUIT's VerticalBoxSlot is saved, QUIT taken out, the entry and QUIT added back, both given QUIT's slot (box
--      panels only append; the menu binds clicks by widget and never reads child indices, research 9.2);
--   5. the style again through the button's own unhover path (SetStyle, BP_OnUnhovered, OnUnhovered), then the source's
--      text colour (the unhover path left it white in the spike);
--   6. Overlay_0's and NN_FieldNavigationBacking's canvas slots grow by the column's growth (or QUIT's height plus its
--      vertical padding when the column can't be measured yet).
-- Every object read from a property is checked valid before any method is called on it, GetFName and GetClass
-- included: a method on a null object reads address 0x18 and crashes the game (research 9.1; OPTIONS's Text Style
-- reads null and is copied as null, never dereferenced).
--
-- When: every menu gets its entry from the poll's opened, within about a second (one or two 500 ms ticks) of the
-- menu appearing. Nothing runs inside MainMenu_C:Construct (story 34): mutating the menu's widget tree there, under
-- the game's own CreateWidget/AddToViewport right after a world teardown and GC, once read a freed object and crashed
-- the game. So the column doesn't show without the entry and then jump (story 35), the creation callback schedules a
-- hide for the next engine tick: one write, the column's render opacity to 0, while the game still keeps Overlay_0
-- collapsed (0.25 s after Construct); the poll's opened writes the saved opacity back right after the insert. Holds of
-- several dependents are shared through one UE4SS shared variable; a 2 s cap shows the column anyway with one WARN
-- (see "no pop-in" below). Each insertion is recorded per Lua state as menu path -> the entry widget's name; a menu with a record is
-- skipped, so repeated opened events never insert twice. The record goes with the menu. Clicks come through one
-- RegisterHook per Lua state on CommonButtonBase:HandleButtonClicked, filtered by the clicked widget's name against
-- the live menu's record (never a kept UObject); a match runs onClick(handle) under pcall, once per click.
local BASE = (...):gsub("%.ui%.entry$", "")
local C = require(BASE .. ".ui.common")
local M = require(BASE .. ".ui.menu")
local S = require(BASE .. ".ui.strings")
local A = require(BASE .. ".ui.assets")

local E = {}
local FN = "menu.entry"
local COLUMN, OPTIONS, QUIT, PRIMARY = "VerticalBox_104", "UI_Button_Master_2", "UI_Button_Master_3", "UI_Button_Master"
local BACKINGS = { "Overlay_0", "NN_FieldNavigationBacking" }
local PRESETS = { options = OPTIONS, primary = PRIMARY }
local PRESET_NAMES = "options, primary"
local STYLE_KEYS = { preset = true, textColor = true, hoverColor = true, fontSize = true, bold = true, italic = true }
local STYLE_KEY_NAMES = "bold, fontSize, hoverColor, italic, preset, textColor"
-- fontSize: about 70% to 130% of the measured preset size (OPTIONS: AlumniSans-SemiBold 22, research 9.1).
E.FONT_MIN, E.FONT_MAX = 16, 28
local DEBOUNCE_US = 250000
local MAX_DELTA = 400            -- a column growth beyond this is not one button: measured wrong
-- The instance properties the menu's template sets per button (PreConstruct reads them) and CommonButtonBase's own:
-- the mini-spike's list, which gave 0 fingerprint differences against OPTIONS.
local COPY_PROPS = {
    "Button Type Selection", "Transform Policy", "In Height Override", "In Width Override", "Do not ovverride with sizebox",
    "In Horizontal Alignment", "Text Style", "Icon Type Selection", "Use Icon instead of text", "Show_NumberText",
    "Show input action widget", "Button is deactivated on construct with timeout", "Style",
    "MinWidth", "MinHeight", "MaxWidth", "MaxHeight", "bHideInputAction", "bApplyAlphaOnDisable", "bSelectable",
    "bShouldSelectUponReceivingFocus", "bInteractableWhenSelected", "bToggleable", "bTriggerClickedAfterSelection",
    "ClickMethod", "TouchMethod", "PressMethod", "InputPriority",
    "PressedSlateSoundOverride", "ClickedSlateSoundOverride", "HoveredSlateSoundOverride",
}
E.COPY_PROPS = COPY_PROPS

local ent = nil                  -- { id, label, onClick, style, handle, clicks, lastClick, warnedClick }
local records = {}               -- menu path -> { btn, delta, grown, how, growPending, failed }
local issued = setmetatable({}, { __mode = "k" })   -- handle -> true (every handle entry() returned)
local removed = setmetatable({}, { __mode = "k" })  -- handle -> true once removed
local T = { inserted = 0, clicks = 0, ignored = 0, debounced = 0 }

-- ---------------------------------------------------------------- validation (pure)

local function pre() return C.UI .. "." .. FN end

local function unit(v, what, comp)
    if type(v) ~= "number" or v ~= v or v < 0 or v > 1 then
        C.fail("%s: style.%s.%s must be a number from 0 to 1, got %s", pre(), what, comp, C.describe(v))
    end
    return v + 0.0
end

-- A colour: { r, g, b, a } by position (a optional) or by name (r, g, b, a; a optional).
local function color(v, what)
    if type(v) ~= "table" then C.fail("%s: style.%s must be a colour table { r, g, b, a } with components 0 to 1, got %s", pre(), what, C.describe(v)) end
    if v[1] ~= nil then
        for k in pairs(v) do
            if math.type(k) ~= "integer" or k < 1 or k > 4 then C.fail("%s: unknown key %s in style.%s (valid: 1 to 4, or r, g, b, a)", pre(), C.describe(k), what) end
        end
        return { r = unit(v[1], what, "r"), g = unit(v[2], what, "g"), b = unit(v[3], what, "b"), a = v[4] == nil and 1.0 or unit(v[4], what, "a") }
    end
    for k in pairs(v) do
        if k ~= "r" and k ~= "g" and k ~= "b" and k ~= "a" then C.fail("%s: unknown key %s in style.%s (valid: r, g, b, a)", pre(), C.describe(k), what) end
    end
    return { r = unit(v.r, what, "r"), g = unit(v.g, what, "g"), b = unit(v.b, what, "b"), a = v.a == nil and 1.0 or unit(v.a, what, "a") }
end

-- Resolves an entry style to { preset, textColor, hoverColor, fontSize, bold, italic } (all but preset optional).
function E.resolveStyle(style)
    if style == nil then return { preset = "options" } end
    if type(style) == "string" then
        if not PRESETS[style] then C.fail("%s: unknown style preset %s (valid: %s)", pre(), C.describe(style), PRESET_NAMES) end
        return { preset = style }
    end
    if type(style) ~= "table" then C.fail("%s: style must be a preset name or a table { preset = ..., ... }, got %s", pre(), C.describe(style)) end
    for k in pairs(style) do
        if type(k) ~= "string" or not STYLE_KEYS[k] then C.fail("%s: unknown style key %s (valid: %s)", pre(), C.describe(k), STYLE_KEY_NAMES) end
    end
    local out = { preset = style.preset == nil and "options" or style.preset }
    if type(out.preset) ~= "string" or not PRESETS[out.preset] then C.fail("%s: unknown style preset %s (valid: %s)", pre(), C.describe(style.preset), PRESET_NAMES) end
    if style.textColor ~= nil then out.textColor = color(style.textColor, "textColor") end
    if style.hoverColor ~= nil then out.hoverColor = color(style.hoverColor, "hoverColor") end
    if style.fontSize ~= nil then
        local f = style.fontSize
        if math.type(f) ~= "integer" or f < E.FONT_MIN or f > E.FONT_MAX then
            C.fail("%s: style.fontSize must be an integer from %d to %d, got %s", pre(), E.FONT_MIN, E.FONT_MAX, C.describe(f))
        end
        out.fontSize = f
    end
    for _, k in ipairs({ "bold", "italic" }) do
        if style[k] ~= nil then
            if type(style[k]) ~= "boolean" then C.fail("%s: style.%s must be a boolean, got %s", pre(), k, C.describe(style[k])) end
            out[k] = style[k]
        end
    end
    return out
end

local function hasOverrides(st)
    return st.textColor ~= nil or st.hoverColor ~= nil or st.fontSize ~= nil or st.bold ~= nil or st.italic ~= nil
end

local ID_OK = "^[A-Za-z0-9_%.%-]+$"
local function validId(id)
    if type(id) ~= "string" then C.fail("%s: id must be a string, got %s", pre(), C.describe(id)) end
    if id == "" then C.fail("%s: id must not be empty", pre()) end
    if #id > 64 then C.fail("%s: id is %d characters, at most 64", pre(), #id) end
    if not id:match(ID_OK) then C.fail("%s: id %s has characters outside A-Z a-z 0-9 _ . -", pre(), C.describe(id)) end
    return id
end

-- ---------------------------------------------------------------- widget helpers (game thread)

local function prop(o, k)
    local ok, v = pcall(C.prop, o, k)
    if ok then return v end
    return nil
end
-- A name, only of a live object (never a method on an unchecked one).
local function fname(o)
    if not C.valid(o) then return nil end
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    return ok and n or nil
end
local function cname(o)
    if not C.valid(o) then return nil end
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or nil
end
local function sameObj(a, b)
    if not (C.valid(a) and C.valid(b)) then return false end
    local ok, yes = pcall(function() return a:GetAddress() == b:GetAddress() end)
    return ok and yes
end
local function parentIs(w, box)
    local ok, p = pcall(C.call0, w, "GetParent")
    return ok and sameObj(p, box)
end
local function desiredY(w)
    if not C.valid(w) then return nil end
    pcall(C.call0, w, "ForceLayoutPrepass")
    local ok, y = pcall(function() return w:GetDesiredSize().Y end)
    y = ok and tonumber(y) or nil
    if y and y == y and y > 0.5 then return y end
    return nil
end
local function ownerOf(mm)
    local ok, pc = pcall(C.call0, mm, "GetOwningPlayer")
    if ok and C.valid(pc) then return pc end
    local okW, p = pcall(function()
        return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(mm:GetWorld(), 0)
    end)
    if okW and C.valid(p) then return p end
    return nil
end

local function readSlot(s)
    local ok, saved = pcall(function()
        local p = s.Padding
        return { pad = { Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom }, h = s.HorizontalAlignment,
            v = s.VerticalAlignment, rule = s.Size.SizeRule, value = s.Size.Value }
    end)
    return ok and saved or nil
end
local function writeSlot(saved, s)
    if not (saved and C.valid(s)) then return end
    s:SetPadding(saved.pad)
    s:SetHorizontalAlignment(saved.h)
    s:SetVerticalAlignment(saved.v)
    s:SetSize({ SizeRule = saved.rule, Value = saved.value })
end

-- Grows (or, with a negative delta, shrinks) the canvas slot height of Overlay_0 and NN_FieldNavigationBacking.
local function growBacking(mm, delta)
    local done = {}
    for _, nm in ipairs(BACKINGS) do
        local w = prop(mm, nm)
        local s = C.valid(w) and prop(w, "Slot") or nil
        if C.valid(s) and cname(s) == "CanvasPanelSlot" then
            local ok = pcall(function()
                local sz = s:GetSize()
                s:SetSize({ X = sz.X, Y = sz.Y + delta })
            end)
            if ok then done[#done + 1] = nm end
        end
    end
    return done
end

-- The style source for this entry in this menu: OPTIONS, or the column's first button for "primary" (which must be a
-- UI_Button_Master_C child of the column; else one WARN and OPTIONS).
local function sourceOf(mm, vb, opt)
    if ent.style.preset ~= "primary" then return opt end
    local p = prop(mm, PRIMARY)
    if C.valid(p) and cname(p) == C.GAME_BUTTON_SHORT and parentIs(p, vb) then return p end
    C.warnOnce("entry primary", "ui menu entry: the column's first button (%s) is missing or not a %s in %s; the entry uses the options style", PRIMARY, C.GAME_BUTTON_SHORT, COLUMN)
    return opt
end

-- The bold / italic typeface name of a font object, or nil when the font has none.
local function typefaceOf(fontObj, bold, italic)
    local want = (bold and italic) and { "Bold Italic", "BoldItalic" } or bold and { "Bold" } or italic and { "Italic" } or nil
    if not want then return nil end
    local ok, name = pcall(function()
        local fonts = fontObj.CompositeFont.DefaultTypeface.Fonts
        local n = #fonts
        for i = 1, n do
            local nm = fonts[i].Name:ToString()
            for _, w in ipairs(want) do if nm == w then return nm end end
        end
        return nil
    end)
    return ok and name or nil
end

-- The style's overrides on a live entry widget (after the preset; again after each hover, which re-applies the
-- preset's text style). hovered: the hover colour instead of the text colour.
local function applyOverrides(g, hovered)
    local st = ent and ent.style
    if not (st and hasOverrides(st)) then return end
    local text = prop(g, "ButtonText")
    if not C.valid(text) then return end
    local col = hovered and st.hoverColor or (not hovered and st.textColor) or nil
    if col then
        pcall(function() text:SetColorAndOpacity({ SpecifiedColor = { R = col.r, G = col.g, B = col.b, A = col.a }, ColorUseRule = 0 }) end)
    end
    if st.fontSize or st.bold or st.italic then
        local ok, err = pcall(function()
            local f = text.Font
            local fo = f.FontObject
            if not C.valid(fo) then return end
            local tf = f.TypefaceFontName:ToString()
            if st.bold or st.italic then
                local t = typefaceOf(fo, st.bold, st.italic)
                if t then tf = t
                else C.warnOnce("entry typeface", "ui menu entry: the preset's font has no %s typeface; style.%s refused", (st.bold and st.italic) and "bold italic" or st.bold and "bold" or "italic", st.bold and "bold" or "italic") end
            end
            local info = { FontObject = fo, TypefaceFontName = FName(tf), Size = st.fontSize or f.Size, LetterSpacing = f.LetterSpacing }
            local fm = f.FontMaterial
            if C.valid(fm) then info.FontMaterial = fm end
            text:SetFont(info)
        end)
        if not ok then C.warnOnce("entry font", "ui menu entry: the font override could not be applied: %s", tostring(err):match("^[^\n]*")) end
    end
end

-- The menu's own buttons re-apply their text style and colour on every hover (research 9.2): overrides go on again
-- after each, from post-hooks on the button class's hover events (registered from a poll tick, only when the style has
-- overrides).
local hoverHooked = false
local function ensureHoverHooks()
    if hoverHooked or not (ent and hasOverrides(ent.style)) then return end
    hoverHooked = true
    for _, ev in ipairs({ { "BP_OnHovered", true }, { "BP_OnUnhovered", false } }) do
        local fnPath = C.GAME_BUTTON_CLASS .. ":" .. ev[1]
        local hovered = ev[2]
        local ok, err = pcall(RegisterHook, fnPath, function(ctx)
            local okB, errB = pcall(function()
                local w = ctx:get()
                if not (ent and C.valid(w)) then return end
                local path = M._openNow()
                local r = path and records[path]
                if r and r.btn and fname(w) == r.btn then applyOverrides(w, hovered) end
            end)
            if not okB then C.warnOnce("entry hover", "ui menu entry: hover handling failed: %s", tostring(errB):match("^[^\n]*")) end
        end)
        if not ok then C.warnOnce("entry hover hook", "ui menu entry: RegisterHook(%s) failed: %s; style overrides may be lost on hover", fnPath, tostring(err):match("^[^\n]*")) end
    end
end

-- ---------------------------------------------------------------- insertion (steps 2-6)

local function findChild(vb, name)
    local okN, n = pcall(C.call0, vb, "GetChildrenCount")
    if not okN then return nil end
    for i = 0, (tonumber(n) or 0) - 1 do
        local okC, c = pcall(function() return vb:GetChildAt(i) end)
        if okC and fname(c) == name then return c end
    end
    return nil
end

-- A growth that couldn't be measured at the poll's insert: measured from the laid-out entry on a later tick.
local function finishGrow(mm, r)
    if not r.growPending then return end
    local vb = prop(mm, COLUMN)
    if not C.valid(vb) then return end
    local g = findChild(vb, r.btn)
    local h = desiredY(g)
    if not h then return end
    local s = prop(g, "Slot")
    local saved = C.valid(s) and readSlot(s) or nil
    local d = h + (saved and (saved.pad.Top + saved.pad.Bottom) or 0)
    r.growPending, r.delta = false, d
    r.grown = growBacking(mm, d)
    if C.log then C.log.debug("ui menu entry '%s': column growth measured late, %.1f units", ent and ent.id or "?", d) end
end

-- Inserts the entry into one menu. how: "poll" (the poll's opened) or "call" (entry() with a menu already open).
-- Raises only on a broken invariant (callers pcall).
local function insert(mm, path, how)
    if not ent or records[path] then return false end
    local vb, opt, quit = prop(mm, COLUMN), prop(mm, OPTIONS), prop(mm, QUIT)
    if not (C.valid(vb) and C.valid(opt) and C.valid(quit) and parentIs(opt, vb) and parentIs(quit, vb)) then
        records[path] = { failed = true }
        C.warnOnce("entry parts", "ui menu entry: OPTIONS (%s) or QUIT (%s) is missing or not in the menu's column %s; no entry added (did a game patch rename them?)", OPTIONS, QUIT, COLUMN)
        return false
    end
    local cls = C.found(C.GAME_BUTTON_CLASS) -- the menu's buttons are of this class: always a hit here
    if not cls then return false end
    local src = sourceOf(mm, vb, opt)
    local h0 = desiredY(vb)
    local owner = ownerOf(mm)
    if not owner then return false end -- between worlds; the next opened tries again
    local g = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(mm, cls, owner)
    if not C.valid(g) then error("creating " .. C.GAME_BUTTON_SHORT .. " failed") end
    -- 3. Instance properties before the add (copied as they are: a null object is copied as null, never called).
    local notCopied = 0
    for _, k in ipairs(COPY_PROPS) do
        if not pcall(function() g[k] = src[k] end) then notCopied = notCopied + 1 end
    end
    local label = S.pick(ent.label)
    pcall(function() g["Button Text"] = FText(label) end)
    -- 4. Reorder: QUIT out, the entry in, QUIT back, both with QUIT's slot.
    local qs = prop(quit, "Slot")
    local saved = C.valid(qs) and readSlot(qs) or nil
    if not saved then error("QUIT's slot could not be read") end
    quit:RemoveFromParent()
    local okA, slotA = pcall(function() return vb:AddChildToVerticalBox(g) end)
    local okQ, slotQ = pcall(function() return vb:AddChildToVerticalBox(quit) end)
    if not okQ then error("QUIT could not be added back: " .. tostring(slotQ)) end
    pcall(writeSlot, saved, slotQ)
    if not okA then error("the entry could not be added: " .. tostring(slotA)) end
    pcall(writeSlot, saved, slotA)
    -- 5. The style through the button's own unhover path, then the source's text colour.
    local st = prop(src, "Style")
    if C.valid(st) then pcall(function() g:SetStyle(st) end) end
    pcall(C.call0, g, "BP_OnUnhovered")
    pcall(C.call0, g, "OnUnhovered")
    local srcText, gText = prop(src, "ButtonText"), prop(g, "ButtonText")
    if C.valid(srcText) and C.valid(gText) then
        pcall(function() gText:SetColorAndOpacity(srcText.ColorAndOpacity) end)
    end
    applyOverrides(g, false)
    -- 6. The backing grows by the column's growth.
    local h1 = desiredY(vb)
    local delta = (h0 and h1 and h1 - h0 > 0.5 and h1 - h0 < MAX_DELTA) and (h1 - h0) or nil
    if not delta then
        local qh = desiredY(quit)
        if qh then delta = qh + saved.pad.Top + saved.pad.Bottom end
    end
    local r = { btn = fname(g), how = how }
    if delta and delta < MAX_DELTA then
        r.delta = delta
        r.grown = growBacking(mm, delta)
    else
        r.growPending = true -- nothing laid out yet: measured from the entry on the next tick
    end
    records[path] = r
    T.inserted = T.inserted + 1
    if C.log then
        C.log.info("ui menu entry '%s' inserted between OPTIONS and QUIT in %s (%s), column grew %s units%s", ent.id, tostring(fname(mm)), how,
            r.delta and string.format("%.0f", r.delta) or "(measured on the next tick)", notCopied > 0 and string.format("; %d properties not copied", notCopied) or "")
    end
    return true
end
E._insert = insert

-- Takes the entry out of the live menu and shrinks the backing by its growth; QUIT's slot is unchanged.
local function takeOut()
    local mm, path = M._poll()
    if not mm then return end
    local r = records[path]
    if not (r and r.btn) then return end
    local vb = prop(mm, COLUMN)
    local g = C.valid(vb) and findChild(vb, r.btn) or nil
    if g then pcall(C.call0, g, "RemoveFromParent") end
    if r.delta and r.grown and #r.grown > 0 then growBacking(mm, -r.delta) end
end

-- ---------------------------------------------------------------- no pop-in: the column hidden until the entry is in
-- Story 35. The creation callback (menu.lua _onCreated) only schedules hideNow for the next engine tick; the game keeps
-- Overlay_0 Collapsed for 0.25 s after Construct, so the hide lands before the column is first drawn. hideNow makes one
-- write (the column's render opacity to 0) and records a hold in a UE4SS shared variable that every dependent's state
-- reads: "<path>|<saved opacity>|<t0 micros>|<modTag>,<modTag>...". A second dependent joins the hold instead of
-- writing. Each holder releases after its poll insert (whatever it returned or raised), on lost, removeEntry and
-- unload; the last one writes the saved opacity back. A hold older than HOLD_CAP_US on the open menu is shown anyway
-- by any state's poll, with one WARN. Nothing here runs inside a hook.
local HOLD_KEY = C.LOWER .. ".ui.menuHold"
local HOLD_MAX_IDS, HOLD_MAX_LEN = 16, 4096
local HOLD_CAP_US = 2000000
local held = {}                  -- path -> true while this state holds (or joined) the shared hold on that menu
local born = {}                  -- path -> micros at its creation callback (for the debug line), until hideNow runs
local bornN = 0
local capWarned = {}             -- path -> true once the cap fired for that menu

local function parseHold(v)
    if type(v) ~= "string" or v == "" or #v > HOLD_MAX_LEN then return nil end
    local path, sv, st, si = v:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if not path then return nil end
    local saved, t0 = tonumber(sv), math.tointeger(tonumber(st))
    if not (saved and saved == saved and saved >= 0 and saved <= 1 and t0) then return nil end
    local ids = {}
    for id in (si .. ","):gmatch("([^,]*),") do
        if not id:match("^[%w_%.%-]+$") or #ids >= HOLD_MAX_IDS then return nil end
        ids[#ids + 1] = id
    end
    if #ids == 0 then return nil end
    return { path = path, saved = saved, t0 = t0, ids = ids }
end
E._parseHold = parseHold

local function readHold()
    local ok, v = pcall(function() return ModRef:GetSharedVariable(HOLD_KEY) end)
    return ok and parseHold(v) or nil
end
local function writeHold(h)
    local v = h and string.format("%s|%.4g|%d|%s", h.path, h.saved, h.t0, table.concat(h.ids, ",")) or ""
    pcall(function() ModRef:SetSharedVariable(HOLD_KEY, v) end)
end
local function hasId(h, id)
    for _, x in ipairs(h.ids) do if x == id then return true end end
    return false
end

local function setOpacity(mm, v)
    local vb = mm and prop(mm, COLUMN)
    if not C.valid(vb) then return false end
    return (pcall(function() vb:SetRenderOpacity(v) end))
end

-- The scheduled action (next engine tick, outside every widget call stack): one write, the column's opacity to 0.
local function hideNow(path)
    local b = born[path]
    if b then born[path] = nil; bornN = bornN - 1 end
    if not ent or records[path] then return end
    local h = readHold()
    if h and h.path == path then
        if held[path] or hasId(h, C.modTag) then held[path] = true return end
        if #h.ids >= HOLD_MAX_IDS then return end
        h.ids[#h.ids + 1] = C.modTag
        writeHold(h)
        held[path] = true
        if C.debugOn() then C.log.debug("ui menu entry '%s': the column of %s is already hidden by %s; joined the hold", ent.id, path:match("[^.]+$"), h.ids[1]) end
        return
    end
    local mm = M._menuOf(path)
    if not mm then return end
    local vb = prop(mm, COLUMN)
    if not C.valid(vb) then return end
    local okO, op = pcall(C.call0, vb, "GetRenderOpacity")
    if not (okO and type(op) == "number" and op == op) then return end
    op = math.max(0, math.min(1, op))
    local ov = prop(mm, "Overlay_0")
    local okV, vis = false, nil
    if C.valid(ov) then okV, vis = pcall(C.call0, ov, "GetVisibility") end
    local okW = pcall(function() vb:SetRenderOpacity(0) end)
    if not okW then return end
    local t0 = C.micros()
    writeHold({ path = path, saved = op, t0 = t0, ids = { C.modTag } })
    held[path] = true
    if C.debugOn() then
        C.log.debug("ui menu entry '%s': hid the column of %s until the entry is in (1 frame, %s ms after its creation; Overlay_0 %s, opacity was %.2f)",
            ent.id, path:match("[^.]+$"), b and string.format("%.1f", (t0 - b) / 1000) or "?",
            okV and type(vis) == "number" and (C.VIS_NAME[vis] or tostring(vis)) or "?", op)
    end
end
E._hideNow = hideNow

-- From the creation callback: schedules hideNow for the next engine tick (only with an entry in this state).
local function hideLater(path)
    if not ent then return end
    local sched = ExecuteInGameThreadAfterFrames
    local ok, err = false, "ExecuteInGameThreadAfterFrames is not available"
    if type(sched) == "function" then
        ok, err = pcall(sched, 1, function()
            local okH, errH = pcall(hideNow, path)
            if not okH then C.warnOnce("entry hide", "ui menu entry: hiding the column until the entry is in failed: %s", tostring(errH):match("^[^\n]*")) end
        end)
    end
    if not ok then
        C.warnOnce("entry hide sched", "ui menu entry: can't schedule the column hide (%s); the column shows a moment before the entry is in", tostring(err):match("^[^\n]*"))
        return
    end
    if bornN >= 8 then born, bornN = {}, 0 end
    if not born[path] then bornN = bornN + 1 end
    born[path] = C.micros()
end

-- This state lets go of its hold on path; the last holder writes the saved opacity back (write: the menu is live).
local function release(path, write, mm)
    if not (path and held[path]) then return end
    held[path] = nil
    local h = readHold()
    if not (h and h.path == path) then return end -- replaced by a newer menu's hold, or shown by the cap
    local ids = {}
    for _, x in ipairs(h.ids) do if x ~= C.modTag then ids[#ids + 1] = x end end
    if #ids > 0 then h.ids = ids; writeHold(h) return end
    writeHold(nil)
    if not write then return end
    mm = mm or M._menuOf(path)
    if setOpacity(mm, h.saved) and C.debugOn() then
        C.log.debug("ui menu entry: showed the column of %s again (hidden %.0f ms)", path:match("[^.]+$"), (C.micros() - h.t0) / 1000)
    end
end

-- On the open menu: a hold older than HOLD_CAP_US is shown anyway (the saved opacity), cleared, with one WARN.
local function capCheck(path, mm)
    if not path then return end
    local h = readHold()
    if not (h and h.path == path) then return end
    local age = C.micros() - h.t0
    if age >= 0 and age < HOLD_CAP_US then return end
    writeHold(nil)
    held[path] = nil
    setOpacity(mm, h.saved)
    if not capWarned[path] then
        capWarned[path] = true
        C.log.warn("ui menu entry: the menu column of %s was still hidden %.1f s after the menu appeared, waiting for %s; shown anyway",
            path:match("[^.]+$"), math.max(age, 0) / 1e6, table.concat(h.ids, ", "))
    end
end

-- A held menu destroyed before its opened (or whose lost this state never heard): released, no write.
local function releaseGone(openPath)
    for p in pairs(held) do
        if p ~= openPath and not M._menuOf(p) then release(p, false) end -- clearing a field while traversing is allowed
    end
end

-- removeEntry, unload: every hold of this state goes (shown when no other holder is left).
local function releaseAll()
    local list = {}
    for p in pairs(held) do list[#list + 1] = p end
    for _, p in ipairs(list) do
        local ok, err = pcall(release, p, true)
        if not ok then held[p] = nil; C.warnOnce("entry release", "ui menu entry: showing the column again failed: %s", tostring(err):match("^[^\n]*")) end
    end
end

-- ---------------------------------------------------------------- hooks and events (menu.lua drives them)

-- No Construct hook: the entry arrives from the poll's opened on every menu (story 34).
M._wants(function() return false, ent ~= nil end)
M._onClick(function(w)
    if not ent then return end
    local path = M._openNow()
    local r = path and records[path]
    if not (r and r.btn) then return end
    if fname(w) ~= r.btn then T.ignored = T.ignored + 1 return end
    local now = C.micros()
    if ent.lastClick and now - ent.lastClick < DEBOUNCE_US then T.debounced = T.debounced + 1 return end
    ent.lastClick = now
    ent.clicks = ent.clicks + 1
    T.clicks = T.clicks + 1
    if C.debugOn() then C.log.debug("ui menu entry '%s' clicked (%d)", ent.id, ent.clicks) end
    local e = ent -- onClick may call removeEntry, which clears ent
    local ok, err = pcall(e.onClick, e.handle)
    if not ok and not e.warnedClick then
        e.warnedClick = true
        C.log.warn("menu entry '%s' onClick: %s", e.id, tostring(err):match("^[^\n]*"))
    end
end)

local watching = false
local function ensureWatching()
    if watching then return end
    watching = true
    M._watch(function(mm, info)
        if info.event == "opened" then
            if ent then
                local r = records[info.path]
                if r then finishGrow(mm, r)
                else
                    local ok, err = pcall(insert, mm, info.path, "poll")
                    if not ok then C.warnOnce("entry insert", "ui menu entry: inserting failed: %s", tostring(err):match("^[^\n]*")) end
                end
                ensureHoverHooks()
            end
            release(info.path, true, mm) -- after the insert, whatever it returned or raised: never a stuck hide
            capCheck(info.path, mm)
        elseif info.event == "lost" then
            records[info.path] = nil -- the record goes with the menu
            release(info.path, false) -- the menu is gone: no write
            releaseGone(nil)
            capWarned[info.path] = nil
        end
    end)
    M._ticker(function(mm)
        local path = M._openNow()
        local r = path and records[path]
        if r then finishGrow(mm, r) end
        release(path, true, mm) -- a hide that landed after this menu's opened (its insert already tried)
        releaseGone(path)
        capCheck(path, mm)
    end)
    M._onCreated(hideLater)
end

-- ---------------------------------------------------------------- public

local CREATE_KEYS = { id = true, label = true, onClick = true, style = true }

local function newHandle(id)
    return setmetatable({}, {
        __index = { id = id },
        __newindex = function() error(C.UI .. ".menu: entry handles are read-only", 2) end,
        __metatable = "menu entry handle",
        __tostring = function() return "menu entry '" .. id .. "'" end,
    })
end

function E.entry(opts, ...)
    C.enter(FN)
    if type(opts) ~= "table" then C.fail("%s: expected a table { id = ..., label = ..., onClick = ..., style = ... }, got %s", pre(), C.describe(opts)) end
    if select("#", ...) > 0 then C.fail("%s: expected 1 argument (a table), got %d", pre(), 1 + select("#", ...)) end
    for k in pairs(opts) do
        if not CREATE_KEYS[k] then C.fail("%s: unknown key %s (valid: id, label, onClick, style)", pre(), C.describe(k)) end
    end
    local id = validId(opts.id)
    local label = S.validateLabel(opts.label, FN)
    if type(opts.onClick) ~= "function" then C.fail("%s: onClick must be a function, got %s", pre(), C.describe(opts.onClick)) end
    local style = E.resolveStyle(opts.style)
    if ent then C.fail("%s: this mod already has a menu entry ('%s'); remove it first", pre(), ent.id) end
    local h = newHandle(id)
    issued[h] = true
    ent = { id = id, label = label, onClick = opts.onClick, style = style, handle = h, clicks = 0 }
    ensureWatching()
    A.ensureLoadMapHook()
    -- A menu already open (entry() after the first menu): insert now; the click hook registers on the next poll tick.
    local mm, path = M._poll()
    if mm and not M._inHook then
        local ok, err = pcall(insert, mm, path, "call")
        if not ok then C.warnOnce("entry insert", "ui menu entry: inserting failed: %s", tostring(err):match("^[^\n]*")) end
        ensureHoverHooks() -- a menu exists here, so this is not a hook before the menu
    end
    return h
end

function E.removeEntry(h, ...)
    C.enter("menu.removeEntry")
    if select("#", ...) > 0 then C.fail("%s.menu.removeEntry: expected 1 argument (handle), got %d", C.UI, 1 + select("#", ...)) end
    if type(h) == "table" and removed[h] then return end -- idempotent
    if type(h) ~= "table" or not issued[h] then
        C.fail("%s.menu.removeEntry: not a menu entry handle (use the handle that menu.entry returned)", C.UI)
    end
    local ok, err = pcall(takeOut)
    if not ok then C.warnOnce("entry remove", "ui menu entry: taking it out of the menu failed: %s", tostring(err):match("^[^\n]*")) end
    for p in pairs(records) do records[p] = nil end
    removed[h] = true
    ent = nil
    releaseAll()
end

-- Internal (client.lua): the dependent unloads (hot reload): its entry leaves the live menu.
function E._unload()
    if not ent then return end
    pcall(takeOut)
    for p in pairs(records) do records[p] = nil end
    ent = nil
    releaseAll()
end

function E.stats()
    local n = 0
    for _ in pairs(records) do n = n + 1 end
    return { inserted = T.inserted, clicks = T.clicks, ignored = T.ignored, debounced = T.debounced, records = n, entry = ent and ent.id or nil }
end

-- For unit tests only.
E._records = records
E._HOLD_KEY = HOLD_KEY
function E._hold() return readHold() end
function E._held() return held end
function E._entry() return ent end
E._applyOverrides, E._findChild, E._hasOverrides = applyOverrides, findChild, hasOverrides
return E
