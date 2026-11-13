-- Unit tests for core story 21 (Mod Manager story 2): the menu host, the menu entry, the window stack, lists, rows
-- and the game look, outside the game. UE4SS globals, the title-screen menu (MainMenu_C with its column
-- VerticalBox_104 and UI_Button_Master_C buttons) and core's widgets are stubbed with plain Lua tables, so this checks
-- core's own logic for every row of the story's I/O matrix, not the engine. The in-game proof is run.ps1 -Scenario
-- menu. Its own file: ui_test.lua's main chunk is at Lua's 200-locals limit.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/menu_test.lua  (here: MiKTeX's texlua)
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.7.0", floor = "0.1.0" } end
table.insert(package.searchers, 2, function(name)
    local rest = name:match("^nucleus%.(.+)$")
    if not rest then return nil end
    local path = ROOT .. "/lua/pkg/" .. rest:gsub("%.", "/") .. ".lua"
    local f = io.open(path, "r")
    if not f then return "\n\tno file " .. path end
    f:close()
    return assert(loadfile(path)), path
end)

-- ---------------------------------------------------------------- fake engine
local F = {}                     -- the fake engine's state
F.addr, F.objects, F.hooks, F.notify, F.loadMap, F.loops = 0x1000, {}, {}, {}, {}, {}
F.getAssets, F.findAll, F.inputModes, F.missing, F.lang = 0, 0, {}, {}, "en"
F.nullCalls = 0                  -- methods called on a null object read from a property (the 0x18 crash)

local function obj(o, path)
    F.addr = F.addr + 0x100
    o.__alive, o.__addr, o.__path = true, F.addr, path or ("/Engine/Transient.Obj_" .. F.addr)
    o.GetAddress = function(self) return self.__addr end
    o.GetFullName = function(self) return (self.__class or "Object") .. " " .. self.__path end
    o.IsValid = function(self) return self.__alive end
    F.objects[o.__path] = o
    return o
end
local function kill(o) o.__alive = false; F.objects[o.__path] = nil end
local function vec(x, y) return { X = x, Y = y } end
local function fn(s) return { ToString = function() return s end } end
local function classOf(name) return { GetFName = function() return fn(name) end } end

-- A null object property (OPTIONS's Text Style): not valid; any other method crashes the game (counted here).
local NULLOBJ = setmetatable({ IsValid = function() return false end }, {
    __index = function() F.nullCalls = F.nullCalls + 1; return function() error("0x18: method on a null object", 0) end end,
})

-- Generic widget: parent, slot, visibility, a desired size.
local function widget(cls, path, h)
    local w = { __class = cls, vis = 0, h = h or 30, wd = 100 }
    obj(w, path)
    function w:GetParent() return self.parent end
    function w:RemoveFromParent()
        local p = self.parent
        if p then for i, c in ipairs(p.children) do if c == self then table.remove(p.children, i) break end end end
        self.parent = nil
    end
    function w:SetVisibility(v) self.vis = v end
    function w:GetVisibility() return self.vis end
    function w:ForceLayoutPrepass() end
    function w:GetDesiredSize() if self.vis == 1 or F.unmeasured then return vec(0, 0) end return vec(self.wd, self.h) end
    function w:GetClass() return classOf(self.__class) end
    function w:GetFName() return fn(self.__name or self.__path:match("[^.:]+$")) end
    function w:IsA(c) return c and c.__isClass == self.__class end
    function w:GetRenderOpacity() return self.opacity or 1 end
    return w
end

local function canvasSlot(x, y, wd, h)
    local s = { anchors = { Minimum = vec(0, 0), Maximum = vec(0, 0) }, alignment = vec(0, 0), position = vec(x or 0, y or 0), auto = false, size = vec(wd or 100, h or 30), z = 0 }
    function s:SetAutoSize(v) self.auto = v end
    function s:GetAutoSize() return self.auto end
    function s:SetAnchors(a) self.anchors = { Minimum = vec(a.Minimum.X, a.Minimum.Y), Maximum = vec(a.Maximum.X, a.Maximum.Y) } end
    function s:SetAlignment(a) self.alignment = vec(a.X, a.Y) end
    function s:SetPosition(p) self.position = vec(p.X, p.Y) end
    function s:SetZOrder(z) self.z = z end
    function s:GetAnchors() return self.anchors end
    function s:GetAlignment() return self.alignment end
    function s:GetPosition() return self.position end
    function s:GetSize() return self.size end
    function s:SetSize(v) self.size = vec(v.X, v.Y) end
    function s:GetClass() return classOf("CanvasPanelSlot") end
    s.__alive = true
    s.IsValid = function() return true end
    return s
end
local function newCanvas(path)
    local c = widget("CanvasPanel", path)
    c.children = {}
    function c:GetChildrenCount() return #self.children end
    function c:GetChildAt(i) return self.children[i + 1] end
    function c:AddChildToCanvas(w) w.parent = self; w.Slot = canvasSlot(); table.insert(self.children, w); return w.Slot end
    return c
end
local function boxSlot()
    local s = { Padding = { Left = 0, Top = 0, Right = 0, Bottom = 0 }, HorizontalAlignment = 0, VerticalAlignment = 0, Size = { SizeRule = 0, Value = 1 } }
    function s:SetPadding(m) self.Padding = { Left = m.Left, Top = m.Top, Right = m.Right, Bottom = m.Bottom } end
    function s:SetHorizontalAlignment(v) self.HorizontalAlignment = v end
    function s:SetVerticalAlignment(v) self.VerticalAlignment = v end
    function s:SetSize(v) self.Size = { SizeRule = v.SizeRule, Value = v.Value } end
    function s:GetClass() return classOf("VerticalBoxSlot") end
    s.__alive = true
    s.IsValid = function() return true end
    return s
end
local function newBox(cls, path, horiz)
    local b = widget(cls, path)
    b.children, b.horiz = {}, horiz
    function b:GetChildrenCount() return #self.children end
    function b:GetChildAt(i) return self.children[i + 1] end
    function b:AddChild(w) w.parent = self; w.Slot = boxSlot(); table.insert(self.children, w); return w.Slot end
    b.AddChildToVerticalBox = b.AddChild
    function b:GetDesiredSize()
        if F.unmeasured then return vec(0, 0) end
        local H = 0
        for _, c in ipairs(self.children) do
            local d = c:GetDesiredSize()
            H = H + d.Y + c.Slot.Padding.Top + c.Slot.Padding.Bottom
        end
        return vec(344, H)
    end
    return b
end

-- Classes (StaticFindObject / GetAsset targets) and UMG classes for IsA.
local function cls(path, isClass) local c = obj({ __isClass = isClass }, path) return c end
cls("/Script/UMG.WidgetSwitcher", "WidgetSwitcher")
cls("/Script/UMG.CanvasPanel", "CanvasPanel")
local GAMEBTN = cls("/Game/Hyper/UI/Widgets/Generic_Elements/Buttons/UI_Button_Master.UI_Button_Master_C")
local MENUCLASS = cls("/Game/Graphics/MainMenu/MainMenu.MainMenu_C")
obj({}, "/Game/Graphics/MainMenu/MainMenu.MainMenu_C:Construct")
local TEXTCLASS = cls("/Game/Mods/Nucleus/WBP_NucleusText.WBP_NucleusText_C")
local BUTTONCLASS = cls("/Game/Mods/Nucleus/WBP_NucleusButton.WBP_NucleusButton_C")
local PANELCLASS = cls("/Game/Mods/Nucleus/WBP_NucleusPanel.WBP_NucleusPanel_C")
local LISTCLASS = cls("/Game/Mods/Nucleus/WBP_NucleusList.WBP_NucleusList_C")
local ROWCLASS = cls("/Game/Mods/Nucleus/WBP_NucleusRow.WBP_NucleusRow_C")
local SCREENCLASS = cls("/Game/Mods/Nucleus/WBP_NucleusScreen.WBP_NucleusScreen_C")
F.assets = {}
for _, a in ipairs({ "/Game/Fonts/Remaster/AlumniSans-ExtraBold_Font.AlumniSans-ExtraBold_Font", "/Game/Fonts/Remaster/AlumniSans-SemiBold_Font.AlumniSans-SemiBold_Font",
    "/Game/Fonts/Remaster/AlumniSans-Regular_Font.AlumniSans-Regular_Font", "/Engine/EngineFonts/Roboto.Roboto",
    "/Game/Graphics/MainMenu/Styles/Remaster/M_NN_WornStrip.M_NN_WornStrip", "/Game/Graphics/MainMenu/Styles/Remaster/M_NN_CinematicSelection.M_NN_CinematicSelection" }) do
    F.assets[a] = obj({ __asset = a:match("[^.]+$") }, a)
end

-- Core's widgets
local function tagged(w)
    w.tag = ""
    function w:SetTag(t) self.tag = t end
    w.CoreTag = setmetatable({}, { __index = function(_, k) if k == "ToString" then return function() return w.tag end end end })
    function w:SetBackground(r, g, b, a) self.bg = { r, g, b, a } end
    function w:SetBackgroundPadding(p) self.pad = p end
    function w:SetBackgroundMaterial(m, r, g, b, a, p) self.mat = m; self.matTint = { r, g, b, a }; self.pad = p end
    function w:SetBackgroundSolid() self.mat = nil end
    return w
end
local function newText()
    local w = widget("WBP_NucleusText_C", "/Engine/Transient.WBP_NucleusText_C_" .. (F.addr + 0x100), 24)
    w.text, w.tip = "", ""
    tagged(w)
    function w:SetText(t) self.text = t end
    function w:SetToolTipText(t) self.tip = t.s end
    w.ToolTipText = setmetatable({}, { __index = function(_, k) if k == "ToString" then return function() return w.tip end end end })
    function w:SetFontObject(f, size) self.font, self.size = f, size end
    function w:SetTextColor(r, g, b, a, sa) self.color = { r, g, b, a, sa } end
    return w
end
local function newButtonW()
    local w = widget("WBP_NucleusButton_C", "/Engine/Transient.WBP_NucleusButton_C_" .. (F.addr + 0x100), 44)
    tagged(w)
    function w:SetLabel(t) self.label = t end
    function w:SetEnabledState(e) self.enabled = e end
    function w:SetRenderOpacity(o) self.opacity = o end
    function w:SetColors(...) self.colors = { ... } end
    function w:SetMaterials(n, h, ...) self.mats = { n, h, ... } end
    function w:SetLabelLook(f, ...) self.labelLook = { f, ... } end
    return w
end
local function newContainerW(c, boxName, horiz)
    local w = widget(c, "/Engine/Transient." .. c .. "_" .. (F.addr + 0x100))
    tagged(w)
    w[boxName] = newBox(horiz and "HorizontalBox" or "VerticalBox", w.__path .. ".WidgetTree." .. boxName, horiz)
    if c == "WBP_NucleusPanel_C" then w.HBox = newBox("HorizontalBox", w.__path .. ".WidgetTree.HBox", true) end
    function w:SetListSize(W, H) self.listSize = { W, H }; self.wd, self.h = W, H end
    w.Scroll = { offset = 0, GetScrollOffset = function(s) return s.offset end }
    return w
end
local function newScreenW()
    local w = widget("WBP_NucleusScreen_C", "/Engine/Transient.WBP_NucleusScreen_C_" .. (F.addr + 0x100))
    tagged(w)
    w.Canvas = newCanvas(w.__path .. ".WidgetTree.Canvas")
    function w:SetIsFocusable(v) self.focusable = v end
    function w:GetWorld() return F.objects["/Game/Maps/NewMainMenu.NewMainMenu"] end
    function w:GetOwningPlayer() return nil end
    function w:SetBackdrop(...) self.backdrop = { ... } end
    function w:AddToViewport(z) self.z, self.inViewport = z, true end
    function w:IsInViewport() return self.inViewport end
    function w:SetKeyboardFocus() F.focus = self end
    local rm = w.RemoveFromParent
    function w:RemoveFromParent() self.inViewport = false; rm(self) end
    return w
end

-- The game's column button: the template's instance properties, a text with style and colour.
local PROPS = { "Button Type Selection", "Transform Policy", "In Height Override", "In Width Override", "Do not ovverride with sizebox",
    "In Horizontal Alignment", "Icon Type Selection", "Use Icon instead of text", "Show_NumberText", "Show input action widget",
    "MinWidth", "MinHeight", "MaxWidth", "MaxHeight" }
local STYLE_SECONDARY = obj({ __class = "BP_NNRemasterMenuSecondary_C" }, "/Game/Graphics/MainMenu/Styles/Remaster/BP_NNRemasterMenuSecondary.BP_NNRemasterMenuSecondary_C")
local function newGameButton(name, label, path)
    local b = widget("UI_Button_Master_C", path or ("/Engine/Transient.UI_Button_Master_C_" .. (F.addr + 0x100)), 44)
    b.__name = name
    for i, k in ipairs(PROPS) do b[k] = name and i or 0 end
    b.Style = name and STYLE_SECONDARY or nil
    b["Text Style"] = NULLOBJ
    b["Button Text"] = label
    b.ButtonText = obj({ ColorAndOpacity = { SpecifiedColor = { R = 0.82, G = 0.85, B = 0.84, A = 1 } },
        Font = { FontObject = F.assets["/Game/Fonts/Remaster/AlumniSans-SemiBold_Font.AlumniSans-SemiBold_Font"], Size = 22, TypefaceFontName = fn("Default"), LetterSpacing = 0 } })
    function b.ButtonText:SetColorAndOpacity(c) self.ColorAndOpacity = c end
    function b.ButtonText:SetFont(f) self.Font = f end
    function b:SetStyle(s) self.styleSet = s end
    function b:BP_OnUnhovered() self.unhovered = (self.unhovered or 0) + 1 end
    function b:OnUnhovered() self.ButtonText.ColorAndOpacity = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 } } end -- the spike's white
    return b
end

-- The title-screen menu: WidgetSwitcher_1 -> page 0 CanvasPanel_17 holding Overlay_0 (-> VerticalBox_104) and the
-- column's backing.
F.menus = {}
local PC = obj({ IsLocalController = function() return true end }, "/Game/Maps/NewMainMenu.NewMainMenu:PersistentLevel.PC_1")
local WORLD = obj({}, "/Game/Maps/NewMainMenu.NewMainMenu")
local function newMenu(n, opts)
    opts = opts or {}
    local path = "/Engine/Transient.GameEngine_1:GameInstance_1.MainMenu_C_" .. n
    local m = widget("MainMenu_C", path)
    m.__name = "MainMenu_C_" .. n
    m.inViewport, m.opacity = true, 1
    local sw = widget(opts.rootClass or "WidgetSwitcher", path .. ".WidgetTree.WidgetSwitcher_1")
    sw.active = 0
    local page = opts.pageClass and widget(opts.pageClass, path .. ".WidgetTree.CanvasPanel_17") or newCanvas(path .. ".WidgetTree.CanvasPanel_17")
    function sw:GetWidgetAtIndex(i) if i == 0 then return page end return nil end
    function sw:GetActiveWidgetIndex() return self.active end
    m.WidgetTree = { RootWidget = sw }
    m.switcher, m.page = sw, page
    local vb = newBox("VerticalBox", path .. ".WidgetTree.VerticalBox_104", false)
    m.VerticalBox_104 = vb
    local names = { { "UI_Button_Master", "START GAME" }, { "UI_Button_Master_1", "JOIN GAME" }, { "UI_Button_Master_6", "CUSTOMIZE" },
        { "UI_Button_Master_2", "OPTIONS" }, { "UI_Button_Master_3", "QUIT" } }
    for _, nm in ipairs(names) do
        local b = newGameButton(nm[1], nm[2], path .. ".WidgetTree." .. nm[1])
        m[nm[1]] = b
        local s = vb:AddChild(b)
        s.Padding = { Left = 0, Top = 3, Right = 0, Bottom = 3 }
        s.VerticalAlignment = 2
    end
    for _, nm in ipairs({ { "Overlay_0", 344, 250 }, { "NN_FieldNavigationBacking", 376, 282 } }) do
        local w = widget("Image", path .. ".WidgetTree." .. nm[1])
        w.Slot = canvasSlot(64, 350, nm[2], nm[3])
        m[nm[1]] = w
    end
    function m:IsInViewport() return self.inViewport end
    function m:GetOwningPlayer() return opts.owner end
    function m:GetWorld() return WORLD end
    function m:SetKeyboardFocus() F.focus = self end
    F.menus[#F.menus + 1] = m
    return m
end
-- A menu built by the game: the creation callback (NotifyOnNewObject) sees it.
local function build(n, opts)
    local m = newMenu(n, opts)
    for _, nt in ipairs(F.notify) do if nt.cls:find("MainMenu_C", 1, true) then nt.fn(m) end end
    return m
end
local function column(m)
    local out = {}
    for _, c in ipairs(m.VerticalBox_104.children) do out[#out + 1] = c["Button Text"] and (type(c["Button Text"]) == "table" and c["Button Text"].s or c["Button Text"]) or "?" end
    return table.concat(out, ",")
end

-- UE4SS globals
function NotifyOnNewObject(c, f) F.notify[#F.notify + 1] = { cls = c, fn = f } end
function RegisterHook(p, f) F.hooks[#F.hooks + 1] = { path = p, fn = f } return #F.hooks, #F.hooks end
function RegisterLoadMapPostHook(f) F.loadMap[#F.loadMap + 1] = f end
function FindAllOf(c)
    F.findAll = F.findAll + 1
    if c == "MainMenu_C" then local out = {} for _, m in ipairs(F.menus) do if m.__alive then out[#out + 1] = m end end return out end
    return {}
end
local INVALID = { IsValid = function() return false end }
function StaticFindObject(p) return F.objects[p] or INVALID end
function FName(s) return s end
function FText(s) return { s = s } end
function LoopInGameThreadWithDelay(_, f) F.loops[#F.loops + 1] = f return #F.loops end
function CancelDelayedAction() return true end
function LoopAsync() error("LoopAsync used") end
function ExecuteInGameThread() error("ExecuteInGameThread used") end
local shared = {}
ModRef = { GetSharedVariable = function(_, k) return shared[k] end, SetSharedVariable = function(_, k, v) shared[k] = v end }
function Nucleus_Deref() return nil end
obj({ GetPlayerController = function() return PC end }, "/Script/Engine.Default__GameplayStatics")
obj({ GetCurrentLanguage = function() return fn(F.lang) end }, "/Script/Engine.Default__KismetInternationalizationLibrary")
obj({ GetAsset = function(_, a)
    F.getAssets = F.getAssets + 1
    local p = a.PackageName .. "." .. a.AssetName
    if F.missing[p] then return INVALID end
    return F.objects[p] or INVALID
end }, "/Script/AssetRegistry.Default__AssetRegistryHelpers")
obj({
    Create = function(_, _, c)
        if c == PANELCLASS then return newContainerW("WBP_NucleusPanel_C", "VBox", false) end
        if c == LISTCLASS then return newContainerW("WBP_NucleusList_C", "VBox", false) end
        if c == ROWCLASS then return newContainerW("WBP_NucleusRow_C", "HBox", true) end
        if c == BUTTONCLASS then return newButtonW() end
        if c == SCREENCLASS then return newScreenW() end
        if c == GAMEBTN then return newGameButton(nil, nil) end
        return newText()
    end,
    SetInputMode_UIOnlyEx = function(_, pc, w, lock, flush) F.inputModes[#F.inputModes + 1] = { w = w, lock = lock, flush = flush } end,
}, "/Script/UMG.Default__WidgetBlueprintLibrary")

-- ---------------------------------------------------------------- the modules under test
local C = require("nucleus.ui.common")
C.valid = function(o) return type(o) == "table" and o.__alive == true end
local M = require("nucleus.ui.menu")
local E = require("nucleus.ui.entry")
local SC = require("nucleus.ui.screen")
local X = require("nucleus.ui.text")
local LS = require("nucleus.ui.list")
local RS = require("nucleus.ui.row")
local P = require("nucleus.ui.place")
local S = require("nucleus.ui.strings")
local A = require("nucleus.ui.assets")
local B = require("nucleus.ui.button")

local logs = {}
local L = { debugEnabled = false }
function L.info(f, ...) logs[#logs + 1] = string.format(f, ...) end
function L.warn(f, ...) logs[#logs + 1] = "WARN " .. string.format(f, ...) end
function L.error(f, ...) logs[#logs + 1] = "ERROR " .. string.format(f, ...) end
function L.debug(f, ...) if L.debugEnabled then logs[#logs + 1] = "DEBUG " .. string.format(f, ...) end end
local handles, nh = {}, 0
local function ref(o) nh = nh + 1; handles[nh] = o; return nh end
local function deref(h) local o = handles[h] return (o and o.__alive) and o or nil end
local function free(h) handles[h] = nil end
local clock = 0
local function micros() clock = clock + 1000 return clock end

local pass, failN = 0, 0
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else failN = failN + 1; print("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")) end
end
local function raises(f, text, name)
    local r, e = pcall(f)
    ok(not r and tostring(e):find(text, 1, true) ~= nil, name, r and "no error" or e)
end
local function countLogs(pat) local n = 0 for _, l in ipairs(logs) do if l:find(pat, 1, true) then n = n + 1 end end return n end
local function tick() for _, f in ipairs(F.loops) do f() end end
local function hookCount(sub) local n = 0 for _, h in ipairs(F.hooks) do if h.path:find(sub, 1, true) then n = n + 1 end end return n end
local function fireHook(sub, w)
    for _, h in ipairs(F.hooks) do if h.path:find(sub, 1, true) then h.fn({ get = function() return w end }) end end
end

C.bind{ mod = "TestMod", log = L, ref = ref, deref = deref, free = free, micros = micros }

-- ---------------------------------------------------------------- strings: language choice, labels
F.lang = "zh-Hans"
ok(S.pick({ en = "MODS", zh = "ZH" }) == "ZH", "language: zh-Hans falls back to its prefix zh")
ok(S.pick({ en = "MODS", ["zh-Hans"] = "HANS", zh = "ZH" }) == "HANS", "language: the exact tag first")
ok(S.pick({ en = "MODS", ["zh-hans"] = "HANS" }) == "HANS", "language: a tag in another case still matches")
F.lang = "pt-BR"
ok(S.pick({ en = "MODS", PT = "PT" }) == "PT", "language: the prefix in another case still matches")
F.lang = "cs"
ok(S.pick({ en = "MODS", zh = "ZH" }) == "MODS", "language: unknown -> en")
F.lang = "en"
ok(S.core("close") == "CLOSE", "core strings: CLOSE")
local EP = "nucleus.ui.menu.entry: "
local function label(l) return function() S.validateLabel(l, "menu.entry") end end
raises(label("MODS"), EP .. "label must be a table of strings by language", "label: not a table")
raises(label({ es = "MODS" }), EP .. "label needs an en string (the fallback)", "label: no en")
raises(label({ en = "Mods" }), EP .. "label.en must be upper case like the menu's own labels, got 'Mods'", "label: lower-case en")
local many = { en = "M" }
for i = 1, 16 do many["l" .. string.char(96 + i)] = "X" end
raises(label(many), EP .. "label has 17 languages, at most 16", "label: 17 languages")
raises(label({ en = "" }), EP .. "label.en must be a string of 1 to 64 bytes, got ''", "label: empty")
raises(label({ en = string.rep("M", 65) }), EP .. "label.en must be a string of 1 to 64 bytes", "label: 65 bytes")
raises(label({ en = "M", ["zh_1"] = "X" }), EP .. "label key 'zh_1' is not a language tag", "label: bad key")
raises(label({ en = "M", [string.rep("a", 17)] = "X" }), "is not a language tag", "label: 17-character key")
ok(pcall(label({ en = "MANAGE MODS", ["zh-Hans"] = "x", es = "GESTIONAR" })), "label: a good table")

-- ---------------------------------------------------------------- entry style validation
local function st(s) return function() return E.resolveStyle(s) end end
ok(E.resolveStyle(nil).preset == "options" and E.resolveStyle("primary").preset == "primary", "style: default options, primary")
local r = E.resolveStyle({ preset = "options", textColor = { 1, 0.5, 0, 1 }, fontSize = 26 })
ok(r.textColor.g == 0.5 and r.fontSize == 26, "style: textColor by position and fontSize 26")
ok(E.resolveStyle({ hoverColor = { r = 1, g = 1, b = 1 } }).hoverColor.a == 1, "style: a named colour, a defaults to 1")
raises(st("big"), EP .. "unknown style preset 'big' (valid: options, primary)", "style: unknown preset")
raises(st({ size = 1 }), EP .. "unknown style key 'size' (valid: bold, fontSize, hoverColor, italic, preset, textColor)", "style: unknown key")
raises(st({ fontSize = 500 }), EP .. "style.fontSize must be an integer from 16 to 28, got 500", "style: fontSize 500")
raises(st({ fontSize = 22.5 }), EP .. "style.fontSize must be an integer from 16 to 28, got 22.5", "style: fontSize not an integer")
raises(st({ textColor = { 1, 2, 0, 1 } }), EP .. "style.textColor.g must be a number from 0 to 1, got 2", "style: colour component 2")
raises(st({ bold = "yes" }), EP .. "style.bold must be a boolean, got 'yes'", "style: bold 'yes'")
raises(st(5), EP .. "style must be a preset name or a table", "style: a number")

-- ---------------------------------------------------------------- startup screen: entry and element before any menu
local clicks = 0
local entryH = E.entry{ id = "mods", label = { en = "MANAGE MODS", zh = "MODS-ZH" }, onClick = function(h) clicks = clicks + 1; F.clickedHandle = h end }
ok(entryH.id == "mods", "entry: a handle { id }")
raises(function() E.entry{ id = "two", label = { en = "TWO" }, onClick = function() end } end, EP .. "this mod already has a menu entry ('mods'); remove it first", "entry: a second one raises")
raises(function() E.entry{ id = "x", label = { en = "X" }, onClick = "f" } end, EP .. "onClick must be a function, got 'f'", "entry: onClick not a function")
raises(function() E.removeEntry({ id = "mods" }) end, "nucleus.ui.menu.removeEntry: not a menu entry handle", "removeEntry: a foreign handle")
local mtext = X.create{ id = "mt", text = "corner", place = { host = "menu", corner = "top-right" } }
tick(); tick()
ok(not M.isOpen() and not X.isShown(mtext), "startup: no menu, the element pending and not shown")
ok(hookCount("MainMenu_C:Construct") == 0 and hookCount("HandleButtonClicked") == 0, "startup: no menu hook registered before a menu exists")
ok(#F.loadMap == 1, "startup: one LoadMap post-hook in the dependent's state")
ok(#F.notify >= 1, "startup: menus learned from their creation")

-- ---------------------------------------------------------------- the first menu: hooks from the poll, entry late
local m1 = build(1)
tick()
ok(hookCount("MainMenu_C:Construct") == 1 and hookCount("HandleButtonClicked") == 1, "first menu: both hooks registered from the poll")
ok(countLogs("ui menu hooks registered (MainMenu_C:Construct, CommonButtonBase:HandleButtonClicked) after the first menu") == 1, "first menu: the hooks line")
ok(column(m1) == "START GAME,JOIN GAME,CUSTOMIZE,OPTIONS,MANAGE MODS,QUIT", "first menu: the entry between OPTIONS and QUIT", column(m1))
ok(countLogs("ui menu entry 'mods' inserted between OPTIONS and QUIT in MainMenu_C_1 (poll), column grew 50 units") == 1, "first menu: inserted late (poll), grew 50", logs[#logs])
ok(m1.Overlay_0.Slot.size.Y == 300 and m1.NN_FieldNavigationBacking.Slot.size.Y == 332, "first menu: the backing grew by 50", m1.Overlay_0.Slot.size.Y)
local ent = m1.VerticalBox_104.children[5]
local quit = m1.VerticalBox_104.children[6]
ok(ent.Slot.Padding.Top == 3 and ent.Slot.VerticalAlignment == 2 and quit.Slot.Padding.Bottom == 3, "first menu: both slots are QUIT's")
ok(ent["Button Type Selection"] == m1.UI_Button_Master_2["Button Type Selection"] and ent.MaxHeight == m1.UI_Button_Master_2.MaxHeight, "first menu: OPTIONS's properties copied before the add")
ok(ent["Text Style"] == NULLOBJ and F.nullCalls == 0, "null Text Style: copied as null, never called")
ok(ent.styleSet == STYLE_SECONDARY and ent.unhovered == 1, "style through the unhover path")
ok(ent.ButtonText.ColorAndOpacity.SpecifiedColor.R == 0.82, "text colour: OPTIONS's copied over the white the unhover left")
ok(ent["Button Text"].s == "MANAGE MODS", "label: en")
ok(m1.page.children[1] and m1.page.children[1].text == "corner" and X.isShown(mtext), "first menu: the corner text attached in page 0")
ok(m1.page.children[1].font and m1.page.children[1].font.__asset == "AlumniSans-Regular_Font" and m1.page.children[1].color[5] == 0, "game look: menu text in AlumniSans, no shadow")
ok(M.isOpen(), "menu.isOpen")

-- poll and hook both see the menu: no second insert
fireHook("MainMenu_C:Construct", m1)
tick()
ok(#m1.VerticalBox_104.children == 6 and #m1.page.children == 1, "poll and hook: no second insert, no second widget")

-- ---------------------------------------------------------------- clicks
fireHook("HandleButtonClicked", ent)
ok(clicks == 1 and F.clickedHandle == entryH, "click: onClick once with the handle")
fireHook("HandleButtonClicked", ent)
ok(clicks == 1, "click: a repeat within 250 ms is one click")
clock = clock + 300000
fireHook("HandleButtonClicked", m1.UI_Button_Master_2)
ok(clicks == 1, "click: OPTIONS is not ours")
fireHook("HandleButtonClicked", ent)
ok(clicks == 2, "click: the next real click")

-- ---------------------------------------------------------------- hidden and shown (Create Server, Server List)
m1.opacity = 0
tick()
ok(m1.page.children[1].vis == 1 and not X.isShown(mtext), "hidden: the menu's elements collapse at opacity 0")
m1.opacity = 1
tick()
ok(m1.page.children[1].vis == 4 and X.isShown(mtext), "shown: back")
m1.switcher.active = 2
tick()
ok(m1.page.children[1].vis == 1, "hidden: another page of the switcher")
m1.switcher.active = 0
tick()

-- ---------------------------------------------------------------- windows: a stack over the menu
local events = {}
SC.watch(function(w, info) events[#events + 1] = info.event .. ":" .. info.id .. ":" .. tostring(info.reason) end)
local A1 = SC.open{ id = "A" }
local wa = handles[#handles] -- not used: find the screen widget instead
local function screenOf(id)
    for _, o in pairs(handles) do if o.__class == "WBP_NucleusScreen_C" and o.tag:find("#screen:" .. id, 1, true) then return o end end
    return nil
end
wa = screenOf("A")
ok(wa and wa.inViewport and wa.vis == 0 and wa.z == 101 and F.focus == wa, "open A: in the viewport, on top, focused", wa and wa.z)
ok(wa.Canvas.children[1] and wa.Canvas.children[1].label == "CLOSE" and wa.Canvas.children[1].mats, "open A: core's Close button, game look, CLOSE")
ok(SC.open{ id = "A" } == A1, "open A again: the same handle, nothing changes")
local list = LS.create{ id = "lst", place = { screen = A1, absolute = { anchor = "center", x = 0, y = 0 } }, size = { 600, 400 } }
local listW = wa.Canvas.children[2]
ok(listW and listW.__class == "WBP_NucleusList_C" and listW.listSize[1] == 600, "list on A: sized")
local rows = {}
for i = 1, 3 do
    rows[i] = RS.create{ id = "r" .. i, place = { list = list } }
    X.create{ id = "r" .. i .. "a", text = "name", place = { row = rows[i], fill = 3 } }
    X.create{ id = "r" .. i .. "b", text = "1.0", place = { row = rows[i], fill = 1 } }
end
ok(#listW.VBox.children == 3 and #listW.VBox.children[1].HBox.children == 2, "rows in the list, texts in the rows")
local cell = listW.VBox.children[1].HBox.children[1]
ok(cell.Slot.Size.SizeRule == 1 and cell.Slot.Size.Value == 3 and listW.VBox.children[1].HBox.children[2].Slot.Size.Value == 1, "fill: Fill slots with weights 3 and 1")
ok(listW.VBox.children[1].mat and listW.VBox.children[1].mat.__asset == "M_NN_WornStrip" and listW.VBox.children[1].matTint[4] == 0.72, "game look: a row has the worn strip at 0.72")
local B1 = SC.open{ id = "B" }
local wb = screenOf("B")
ok(wb.z == 102 and wb.vis == 0 and wa.vis == 3 and F.focus == wb and SC.top() == B1, "open B: on top with focus; A not hit-testable")
-- closing A closes B first (parent), then A; focus back to the menu
SC.close(A1)
ok(table.concat(events, " ") == "opened:A:screen.open opened:B:screen.open closed:B:parent closed:A:api", "close A: B closed first (parent)", table.concat(events, " "))
ok(not wa.inViewport and not wb.inViewport and F.focus == m1 and F.inputModes[#F.inputModes].w == m1 and F.inputModes[#F.inputModes].flush == true, "close A: focus back to the menu, UIOnly")
ok(not SC.isOpen(A1) and SC.top() == nil and not LS.isShown(list), "closed: isOpen false, the list not shown")
-- re-open A: its elements come back
SC.open{ id = "A" }
wa = screenOf("A")
ok(wa.Canvas.children[2] and wa.Canvas.children[2].__class == "WBP_NucleusList_C" and #wa.Canvas.children[2].VBox.children == 3, "re-open A: its list and rows re-attach")
-- the Close button closes with reason close
events = {}
local closeBtn = wa.Canvas.children[1]
fireHook("WBP_NucleusButton_C:Nucleus_OnClicked", closeBtn)
ok(events[1] == "closed:A:close", "Close button: closed with reason close", events[1])
-- 8 windows at most
for i = 1, 8 do SC.open{ id = "w" .. i } end
raises(function() SC.open{ id = "w9" } end, "nucleus.ui.screen.open: this mod already has 8 windows open (at most 8)", "a ninth window raises")
events = {}
-- the menu's loss closes them all (lost)
kill(m1)
tick()
ok(#events == 8 and events[1] == "lost:w8:the menu is gone (the menu is gone (a map change))" or (#events == 8 and events[1]:find("^lost:w8")), "menu lost: every window lost, top first", events[1])
ok(SC.top() == nil, "menu lost: no window")
raises(function() SC.open{ id = "A" } end, "nucleus.ui.screen.open: the title-screen menu is not open (windows open only over it)", "screen.open without a menu raises")

-- ---------------------------------------------------------------- return from a match: the entry inside Construct
-- The match world: the old menu is gone; core's widget classes unloaded; the LoadMap post-hook loads them again.
local before = F.getAssets
for _, f in ipairs(F.loadMap) do f() end
ok(F.getAssets > before, "LoadMap post-hook: assets loaded")
local m2 = newMenu(2)
local gaInHook = F.getAssets
-- The game constructs the new menu: the creation callback, then Construct's post-hook (before the poll sees it).
for _, nt in ipairs(F.notify) do if nt.cls:find("MainMenu_C", 1, true) then nt.fn(m2) end end
fireHook("MainMenu_C:Construct", m2)
ok(F.getAssets == gaInHook, "Construct hook: no asset load inside the hook")
ok(column(m2) == "START GAME,JOIN GAME,CUSTOMIZE,OPTIONS,MANAGE MODS,QUIT", "return from a match: inserted inside Construct")
ok(countLogs("in MainMenu_C_2 (construct)") == 1, "return from a match: reason construct")
ok(#m2.page.children == 1, "return from a match: the menu text attached in Construct")
fireHook("MainMenu_C:Construct", m2)
tick(); tick()
ok(#m2.VerticalBox_104.children == 6 and #m2.page.children == 1, "Construct twice and the poll: exactly one extra child, one widget")
ok(countLogs("(poll)") == 1, "return from a match: no poll insert")

-- removeEntry: out of the live menu, the backing shrinks back
local grownTo = m2.Overlay_0.Slot.size.Y
E.removeEntry(entryH)
ok(column(m2) == "START GAME,JOIN GAME,CUSTOMIZE,OPTIONS,QUIT" and m2.Overlay_0.Slot.size.Y == grownTo - 50 and m2.NN_FieldNavigationBacking.Slot.size.Y == 282, "removeEntry: out, the backing back to its size")
ok(m2.UI_Button_Master_3.Slot.Padding.Top == 3, "removeEntry: QUIT's slot unchanged")
ok(pcall(E.removeEntry, entryH), "removeEntry: again, nothing")

-- ---------------------------------------------------------------- column not measurable in Construct: QUIT's height + padding
local e2 = E.entry{ id = "m2", label = { en = "TWO" }, onClick = function() end, style = "primary" }
F.unmeasured = true
local m3 = newMenu(3)
for _, nt in ipairs(F.notify) do if nt.cls:find("MainMenu_C", 1, true) then nt.fn(m3) end end
fireHook("MainMenu_C:Construct", m3)
ok(column(m3):find("OPTIONS,TWO,QUIT", 1, true) and countLogs("column grew (measured on the next tick)") == 1, "unmeasurable: inserted, growth deferred")
F.unmeasured = false
kill(m2)
tick(); tick()
ok(m3.Overlay_0.Slot.size.Y == 300, "unmeasurable: grown on the next tick from the entry's height + padding", m3.Overlay_0.Slot.size.Y)
local e2w = m3.VerticalBox_104.children[5]
ok(e2w.styleSet == STYLE_SECONDARY and e2w["Button Type Selection"] == m3.UI_Button_Master["Button Type Selection"], "primary: the first button's properties")
E.removeEntry(e2)

-- ---------------------------------------------------------------- two dependents: entries stack above QUIT in attach order
local m4 = build(4)
local other = newGameButton(nil, "OTHER MOD")
local vb4 = m4.VerticalBox_104
local q4 = m4.UI_Button_Master_3
q4:RemoveFromParent(); vb4:AddChild(other); vb4:AddChild(q4) -- another dependent's entry, attached first
kill(m3)
tick(); tick()
local e3 = E.entry{ id = "m3", label = { en = "THIRD" }, onClick = function() end }
ok(column(m4) == "START GAME,JOIN GAME,CUSTOMIZE,OPTIONS,OTHER MOD,THIRD,QUIT", "two dependents: both above QUIT in attach order", column(m4))
E.removeEntry(e3)

-- ---------------------------------------------------------------- OPTIONS or QUIT missing: one WARN, nothing changed
local m5 = newMenu(5)
m5.UI_Button_Master_3:RemoveFromParent() -- renamed by a patch: not in the column
local o5 = m5.Overlay_0.Slot.size.Y
kill(m4)
for _, nt in ipairs(F.notify) do if nt.cls:find("MainMenu_C", 1, true) then nt.fn(m5) end end
local e4 = E.entry{ id = "m4", label = { en = "FOUR" }, onClick = function() end }
tick(); tick()
ok(countLogs("WARN ui menu entry: OPTIONS (UI_Button_Master_2) or QUIT (UI_Button_Master_3) is missing") == 1, "missing QUIT: one WARN")
ok(#m5.VerticalBox_104.children == 4 and m5.Overlay_0.Slot.size.Y == o5, "missing QUIT: no entry, no slot changed")
E.removeEntry(e4)

-- ---------------------------------------------------------------- root not a canvas: WARN, host closed, entry still inserts
local m6 = newMenu(6, { pageClass = "Image" })
kill(m5)
for _, nt in ipairs(F.notify) do if nt.cls:find("MainMenu_C", 1, true) then nt.fn(m6) end end
local e5 = E.entry{ id = "m5", label = { en = "FIVE" }, onClick = function() end }
tick(); tick()
ok(countLogs("WARN the menu's page 0 is Image, not a CanvasPanel") == 1 and not X.isShown(mtext), "page 0 not a canvas: one WARN, the host stays closed")
ok(column(m6):find("FIVE,QUIT", 1, true), "page 0 not a canvas: the entry still inserts")
E.removeEntry(e5)

-- ---------------------------------------------------------------- Construct hook body: odd contexts
local before7 = #F.menus
fireHook("MainMenu_C:Construct", nil)
fireHook("MainMenu_C:Construct", newText())
local remote = newMenu(7, { owner = obj({ IsLocalController = function() return false end }) })
local e6 = E.entry{ id = "m6", label = { en = "SIX" }, onClick = function() end }
fireHook("MainMenu_C:Construct", remote)
ok(#remote.VerticalBox_104.children == 5 and #F.menus == before7 + 1, "Construct hook: nil, a foreign widget and a remote player's menu are ignored")
E.removeEntry(e6)

-- ---------------------------------------------------------------- nesting and caps
kill(m6); kill(remote)
tick(); tick()
local PL = "nucleus.ui.place: "
local pnl = require("nucleus.ui.panel").create{ id = "pn", place = { host = "journal", corner = "top-left" } }
local l2 = LS.create{ id = "l2", place = { host = "journal", corner = "bottom-left" }, size = { w = 300, h = 200 } }
local r2 = RS.create{ id = "rr", place = { list = l2 } }
raises(function() LS.create{ id = "l3", place = { row = r2 }, size = { 100, 100 } } end, "nucleus.ui.list.create: a list can't go inside a panel, list or row", "list in a row")
raises(function() LS.create{ id = "l3", place = { panel = pnl }, size = { 100, 100 } } end, "nucleus.ui.list.create: a list can't go inside a panel, list or row", "list in a panel")
raises(function() RS.create{ id = "r3", place = { row = r2 } } end, "nucleus.ui.row.create: a row can't go inside a row", "row in a row")
raises(function() require("nucleus.ui.panel").create{ id = "p3", place = { list = l2 } } end, "nucleus.ui.panel.create: a panel can't go inside a list or row", "panel in a list")
raises(function() LS.create{ id = "l3", place = { host = "hud", corner = "top-left" }, size = { 100, 100 } } end, "nucleus.ui.list.create: lists need a host with a cursor (journal, menu, screen)", "list on hud")
raises(function() RS.create{ id = "r3", place = { host = "hud", corner = "top-left" } } end, "nucleus.ui.row.create: rows need a host with a cursor (journal, menu, screen)", "row on hud")
raises(function() LS.create{ id = "l3", place = { host = "journal", corner = "top-left" }, size = { 31, 100 } } end, "nucleus.ui.list.create: size.w must be a number from 32 to 4096, got 31", "size out of range")
raises(function() LS.create{ id = "l3", place = { host = "journal", corner = "top-left" }, size = "big" } end, "nucleus.ui.list.create: size must be a table", "size not a table")
raises(function() X.create{ id = "t3", place = { row = r2, fill = 0 } } end, PL .. "fill must be a number from 0.1 to 16, got 0", "fill 0")
raises(function() X.create{ id = "t3", place = { row = r2, fill = 17 } } end, PL .. "fill must be a number from 0.1 to 16, got 17", "fill 17")
raises(function() X.create{ id = "t3", place = { list = l2, fill = 1 } } end, PL .. "fill is allowed only with row", "fill without a row")
for i = 1, 16 do X.create{ id = "rc" .. i, text = "c", place = { row = r2 } } end
raises(function() X.create{ id = "rc17", place = { row = r2 } } end, PL .. "row 'rr' already has 16 children (at most 16)", "row: 17th child")
for i = 2, 256 do X.create{ id = "lc" .. i, text = "c", place = { list = l2 } } end
raises(function() X.create{ id = "lc257", place = { list = l2 } } end, PL .. "list 'l2' already has 256 children (at most 256)", "list: 257th child")
raises(function() X.create{ id = "t3", place = { host = "menu", near = "crosshair" } } end, PL .. "near is not available on host 'menu' (corner or absolute)", "near on menu")
raises(function() X.create{ id = "t3", place = { screen = 5, corner = "top-left" } } end, PL .. "screen must be a window handle, got 5", "screen: not a window")
raises(function() X.create{ id = "t3", place = { host = "screen", corner = "top-left" } } end, PL .. "host 'screen' needs screen = <window handle>", "host screen without a window")
raises(function() X.create{ id = "t3", place = { host = "moon", corner = "top-left" } } end, PL .. "unknown host 'moon' (valid: hud, journal, menu, screen)", "unknown host")
raises(function() X.create{ id = "t3", style = { look = "shiny" } } end, "nucleus.ui.text: unknown look 'shiny' (valid: game, plain)", "unknown look")
raises(function() X.create{ id = "t3", style = { look = "game", font = "huge" } } end, "nucleus.ui.text: unknown font 'huge' (valid: title, heading, body, small)", "unknown font")
raises(function() X.create{ id = "t3", style = { look = "plain", font = "title" } } end, "nucleus.ui.text: font needs look = 'game' (got look 'plain')", "font with the plain look")
ok(next(P.elements("menu")) == nil and next(P.elements("screen")) == nil, "elements(menu|screen): none")
-- panel functions take lists and rows
ok(pcall(require("nucleus.ui.panel").setVisible, l2, false) and pcall(require("nucleus.ui.panel").isShown, r2), "panel.setVisible / isShown take a list and a row")
LS.remove(l2)
raises(function() RS.isShown(r2) end, "nucleus.ui.row: handle 'rr' was removed", "a removed list's row is removed")

-- ---------------------------------------------------------------- style overrides, a localized label, focus to the next window
F.lang = "zh-Hans"
local e7 = E.entry{ id = "m7", label = { en = "SEVEN", zh = "QI" }, onClick = function() end,
    style = { preset = "options", textColor = { 1, 0.5, 0, 1 }, hoverColor = { 0, 1, 0 }, fontSize = 26 } }
local m9 = build(9)
for _, mm in ipairs(F.menus) do if mm ~= m9 then kill(mm) end end
tick(); tick(); tick()
local e7w = E._findChild(m9.VerticalBox_104, (function() for _, r9 in pairs(E._records) do if r9.btn then return r9.btn end end end)())
ok(e7w and e7w["Button Text"].s == "QI", "language: the entry's label in zh for zh-Hans")
ok(e7w and e7w.ButtonText.ColorAndOpacity.SpecifiedColor.G == 0.5 and e7w.ButtonText.Font.Size == 26, "override: textColor and fontSize after the preset")
ok(hookCount("UI_Button_Master_C:BP_OnHovered") == 1 and hookCount("UI_Button_Master_C:BP_OnUnhovered") == 1, "override: hover hooks registered from the poll")
fireHook("UI_Button_Master_C:BP_OnHovered", e7w)
ok(e7w.ButtonText.ColorAndOpacity.SpecifiedColor.G == 1 and e7w.ButtonText.ColorAndOpacity.SpecifiedColor.R == 0, "override: hoverColor on hover")
fireHook("UI_Button_Master_C:BP_OnUnhovered", e7w)
ok(e7w.ButtonText.ColorAndOpacity.SpecifiedColor.G == 0.5, "override: textColor again on unhover")
E.removeEntry(e7)
-- bold / italic: the preset font's typeface names (Regular and Bold here), else one WARN and the preset's typeface
local function liveEntry() for _, r in pairs(E._records) do if r.btn then return E._findChild(m9.VerticalBox_104, r.btn) end end end
F.assets["/Game/Fonts/Remaster/AlumniSans-SemiBold_Font.AlumniSans-SemiBold_Font"].CompositeFont =
    { DefaultTypeface = { Fonts = { { Name = fn("Regular") }, { Name = fn("Bold") } } } }
local e8 = E.entry{ id = "m8", label = { en = "EIGHT" }, onClick = function() end, style = { preset = "options", bold = true } }
local e8w = liveEntry()
ok(e8w and e8w.ButtonText.Font.TypefaceFontName == "Bold", "override: bold sets the font's Bold typeface")
E.removeEntry(e8)
local e8i = E.entry{ id = "m8i", label = { en = "EIGHT" }, onClick = function() end, style = { preset = "options", italic = true } }
local e8iw = liveEntry()
ok(e8iw and e8iw.ButtonText.Font.TypefaceFontName == "Default" and countLogs("the preset's font has no italic typeface; style.italic refused") == 1,
    "override: italic on a font without Italic: one WARN, the preset's typeface kept")
E.removeEntry(e8i)
-- an onClick that removes its own entry and then fails: its error is logged, not lost in the click hook
local e9
e9 = E.entry{ id = "m9", label = { en = "NINE" }, onClick = function() E.removeEntry(e9); error("boom") end }
fireHook("CommonButtonBase:HandleButtonClicked", liveEntry())
ok(countLogs("menu entry 'm9' onClick: ") == 1 and countLogs("menu click handling failed") == 0, "onClick that removes its entry and fails: its own WARN", logs[#logs])
F.lang = "en"
local WA = SC.open{ id = "A" }
local WB = SC.open{ id = "B", close = false }
local wa2, wb2 = screenOf("A"), screenOf("B")
ok(#wb2.Canvas.children == 0, "close = false: no Close button")
SC.close(WB)
ok(F.focus == wa2 and wa2.vis == 0 and SC.top() == WA, "close B: focus and input back to A, A on top")
SC.close(WA)
ok(F.focus == m9, "close A: focus back to the menu")

-- ---------------------------------------------------------------- (a) a button in a row in a list: hidden containers drop clicks
local function widgetTagged(id)
    for _, o in pairs(handles) do
        local t = type(o) == "table" and ((o.tip ~= nil and o.tip ~= "" and o.tip) or o.tag) or nil
        if t and t:sub(-#id - 1) == ":" .. id and o.__alive then return o end
    end
    return nil
end
local WT = SC.open{ id = "T" }
local lt = LS.create{ id = "lt", place = { screen = WT, corner = "top-left" }, size = { 300, 200 } }
local rt = RS.create{ id = "rt", place = { list = lt } }
local hits = 0
B.create{ id = "bt", label = "GO", place = { row = rt, fill = 1 }, onClick = function() hits = hits + 1 end }
local btw = widgetTagged("bt")
ok(btw ~= nil, "nested button: its widget exists")
local d0 = B.stats().dropped
LS.setVisible(lt, false)
clock = clock + 300000
fireHook("WBP_NucleusButton_C:Nucleus_OnClicked", btw)
ok(hits == 0 and B.stats().dropped == d0 + 1, "nested button: a hidden list drops the click", B.stats().dropped)
LS.setVisible(lt, true); RS.setVisible(rt, false)
clock = clock + 300000
fireHook("WBP_NucleusButton_C:Nucleus_OnClicked", btw)
ok(hits == 0 and B.stats().dropped == d0 + 2, "nested button: a hidden row drops the click")
RS.setVisible(rt, true)
clock = clock + 300000
fireHook("WBP_NucleusButton_C:Nucleus_OnClicked", btw)
ok(hits == 1, "nested button: visible again, the click runs")

-- ---------------------------------------------------------------- (b) a panel holding a row (with or without a button) stays off the HUD
local PNm = require("nucleus.ui.panel")
local pb = PNm.create{ id = "pb", place = { host = "journal", corner = "top-left" } }
local rb = RS.create{ id = "rb", place = { panel = pb } }
B.create{ id = "bb2", label = "X", place = { row = rb }, onClick = function() end }
raises(function() P.place(pb, { host = "hud", corner = "top-left" }) end, "nucleus.ui.place: panel 'pb' holds buttons, which need a host with a cursor (journal, menu, screen)", "panel with a row with a button: not to the HUD")
local pr = PNm.create{ id = "pr", place = { host = "journal", corner = "bottom-left" } }
RS.create{ id = "rr2", place = { panel = pr } }
raises(function() P.place(pr, { host = "hud", corner = "top-left" }) end, "nucleus.ui.place: panel 'pr' holds rows or lists, which need a host with a cursor (journal, menu, screen)", "panel with only a row: not to the HUD")
PNm.remove(pb); PNm.remove(pr)

-- ---------------------------------------------------------------- (c) game look back to plain: engine font at 18, plain colours
local mtw = widgetTagged("mt")
ok(mtw and mtw.font and mtw.font.__asset == "AlumniSans-Regular_Font", "plain switch: the menu text starts in the game look")
X.setStyle(mtext, { look = "plain" })
ok(mtw.font.__asset == "Roboto" and mtw.size == 18 and mtw.color[1] == 1 and mtw.color[4] == 1 and mtw.color[5] == 0.85, "plain switch: text back to Roboto 18, white with its shadow")
local gb = B.create{ id = "gb", label = "G", place = { screen = WT, corner = "bottom-left" }, onClick = function() end }
local gbw = widgetTagged("gb")
ok(gbw and gbw.mats ~= nil, "plain switch: the window button starts in the game look")
X._setStyle(C.handleOf[gb], X.resolveStyle({ look = "plain" }, "button"))
ok(gbw.labelLook[1].__asset == "Roboto" and gbw.labelLook[2] == 18 and gbw.labelLook[3] == 1 and gbw.labelLook[11] == 0.85 and gbw.colors ~= nil, "plain switch: button label Roboto 18 white with shadow, plain colours")
SC.close(WT)
X.setStyle(mtext, nil) -- back to the host default (game) for the asset-missing case below

-- ---------------------------------------------------------------- (d) the dependent unloads: the entry leaves the live menu
E.entry{ id = "un", label = { en = "UNLOAD" }, onClick = function() end }
ok(#m9.VerticalBox_104.children == 6 and m9.Overlay_0.Slot.size.Y == 300, "unload: the entry was inserted")
E._unload()
ok(column(m9) == "START GAME,JOIN GAME,CUSTOMIZE,OPTIONS,QUIT" and m9.Overlay_0.Slot.size.Y == 250 and m9.NN_FieldNavigationBacking.Slot.size.Y == 282 and E.stats().entry == nil, "unload: the column and the backing back to stock")

-- ---------------------------------------------------------------- (f) a lower window's widget gone: lost, the next one on top and focused
local events2 = {}
SC.watch(function(_, info) events2[#events2 + 1] = info.event .. ":" .. info.id end)
local WA2 = SC.open{ id = "A" }
SC.open{ id = "B" }
local wa3, wb3 = screenOf("A"), screenOf("B")
kill(wb3)
tick()
ok(events2[#events2] == "lost:B" and SC.top() == WA2 and wa3.vis == 0 and F.focus == wa3, "widget gone: B lost, A on top, hit-testable and focused", events2[#events2])
SC.close(WA2)

-- ---------------------------------------------------------------- (g) at most 64 window ids
local nIds = 0
for _ in pairs(C.windows) do nIds = nIds + 1 end
for i = nIds + 1, 64 do SC.close(SC.open{ id = "id" .. i }) end
raises(function() SC.open{ id = "id65" } end, "nucleus.ui.screen.open: this mod already has 64 window ids (at most 64)", "a 65th window id raises")

-- ---------------------------------------------------------------- (e) a late watcher, hidden and shown, lost
local mev = {}
M.watch(function(m, info) mev[#mev + 1] = { e = info.event, r = info.reason, m = m } end)
tick()
ok(mev[1] and mev[1].e == "opened" and mev[1].r == "late watcher: menu already open" and mev[1].m == m9, "late watcher: opened on the next tick", mev[1] and mev[1].r)
m9.opacity = 0; tick()
m9.opacity = 1; tick()
ok(mev[2] and mev[2].e == "hidden" and mev[3] and mev[3].e == "shown", "watcher: hidden then shown")
kill(m9); tick()
ok(mev[4] and mev[4].e == "lost" and mev[4].m == nil, "watcher: lost with menu nil")

-- ---------------------------------------------------------------- asset missing: plain look, one WARN
F.missing["/Game/Fonts/Remaster/AlumniSans-Regular_Font.AlumniSans-Regular_Font"] = true
A._reset()
local m8 = build(8)
tick(); tick()
local tw = m8.page.children[1]
ok(tw and tw.text == "corner" and tw.font == nil, "asset missing: the text attaches in the plain look")
ok(countLogs("WARN the game font AlumniSans-Regular_Font (/Game/Fonts/Remaster/AlumniSans-Regular_Font.AlumniSans-Regular_Font) could not be loaded") == 1, "asset missing: one WARN")

print(string.format("menu_test: %d passed, %d failed", pass, failN))
if failN > 0 then os.exit(1) end
