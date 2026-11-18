-- Unit tests for core story 33 (UI-15, core 0.15.0): game-style rows (row.create's like, label, help and control;
-- row.setLabel, row.setHelp) and the game's own picker (choice.create's widget = "game"), outside the game. The fake
-- engine is insert_test.lua's (core's widgets, the create-server screen built new on every open with its settings list
-- VerticalBox_202), with the Difficulty row (Overlay_28) built as the game builds it (Image_23, HorizontalBox_4 >
-- [TextBlock_8, HorizontalBox_53 > [MultipleSelectBox_6, TextBlock_57 "?"]], every slot with its own values), the UMG
-- classes core constructs, the game's picker (string Items / SelectedOption / DefaultOption; PreConstruct on a re-add)
-- and its tooltip widget. It checks every row of the story's I/O matrix: the values copied (brush, tint, fonts, colours,
-- justification, every slot, the row's own slot), the control in the holder before the "?", the tooltip widget with the
-- help as Description (three lines kept), the fallbacks (like missing or not a game row, the tooltip class missing:
-- one WARN each), ten opens with one widget set each, the game choice showing its option after a PreConstruct reset,
-- an arrow click giving one onChange, other pickers ignored, set with no callback, and the bad input. The in-game proof
-- is run.ps1 -Scenario nativerow.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/likerow_test.lua  (here: MiKTeX's texlua)
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.15.0", floor = "0.1.0" } end
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

-- ---------------------------------------------------------------- story 24: core's widgets with their new parts
local IM = require("nucleus.ui.image")
local theme = require("nucleus.ui.theme")
local T = {}                     -- this file's own helpers and state (the main chunk is near Lua's 200-locals limit)
T.IMAGECLASS = cls("/Game/Mods/Nucleus/WBP_NucleusImage.WBP_NucleusImage_C")
-- An inner widget (a text's Text and Background, a button's Btn, Box, Label, IconGap, an image's Img).
function T.inner(vis)
    local i = { vis = vis, tip = "", calls = 0 }
    function i:SetVisibility(v) self.vis = v; self.calls = self.calls + 1 end
    function i:SetToolTipText(t) self.tip = t.s; self.calls = self.calls + 1 end
    function i:SetTextOverflowPolicy(p) self.policy = p; self.calls = self.calls + 1 end
    function i:SetClipping(c) self.clip = c; self.calls = self.calls + 1 end
    function i:SetWidthOverride(v) self.wo = v end
    function i:SetHeightOverride(v) self.ho = v end
    function i:ClearWidthOverride() self.wo = nil end
    function i:ClearHeightOverride() self.ho = nil end
    return i
end
function T.decorate(w)
    if w.__class == "WBP_NucleusText_C" then
        w.Text, w.Background = T.inner(4), T.inner(3) -- the generator's: Background HitTestInvisible, Text SelfHitTestInvisible
        w.Text.policy, w.Text.clip = 0, 0
    elseif w.__class == "WBP_NucleusButton_C" then
        w.Btn, w.Box, w.Label, w.IconGap = T.inner(0), T.inner(4), T.inner(3), T.inner(1)
        function w:SetIcon(t, W, H) self.icon = { t, W, H } end
        function w:ClearIcon() self.icon = nil; self.cleared = (self.cleared or 0) + 1 end
        function w:SetContentColors(...) self.content = { ... } end
    end
    return w
end
function T.newImageW()
    local w = widget("WBP_NucleusImage_C", "/Engine/Transient.WBP_NucleusImage_C_" .. (F.addr + 0x100), 32)
    tagged(w)
    w.Img = T.inner(3)
    w.size = { 32, 32 }
    function w:SetImageTexture(t) self.tex = t; self.texCalls = (self.texCalls or 0) + 1 end
    function w:ClearImageTexture() self.tex = nil; self.clears = (self.clears or 0) + 1 end
    function w:SetImageSize(W, H) self.size = { W, H } end
    function w:SetImageTint(r, g, b, a) self.tint = { r, g, b, a } end
    return w
end
do
    local WBL = F.objects["/Script/UMG.Default__WidgetBlueprintLibrary"]
    local base = WBL.Create
    WBL.Create = function(self, world, c, owner)
        if c == T.IMAGECLASS then return T.newImageW() end
        return T.decorate(base(self, world, c, owner))
    end
end
-- Textures: core's icons in its pak, and the game's allow-listed ones.
for key, name in pairs(theme.icons) do
    local p = "/Game/Mods/Nucleus/Icons/" .. name .. "." .. name
    F.assets[p] = obj({ __asset = name, key = key }, p)
end
for _, p in ipairs(theme.gameTextureNames) do F.assets[p] = obj({ __asset = p:match("[^.]+$") }, p) end
T.GAME = {
    ticked = "/Game/Graphics/MainMenu/Textures/checkbox_ticked.checkbox_ticked",
    unticked = "/Game/Graphics/MainMenu/Textures/checkbox_unticked.checkbox_unticked",
    settings = "/Game/AntizeVOIPSystem/Widgets/Settings/T_Settings.T_Settings",
    reset = "/Game/HexTree/Widgets/reset-icon.reset-icon",
    question = "/Game/HexTree/Textures/T_Question.T_Question",
}
function T.tagged(id)
    local want = "nucleus:TestMod:" .. id
    for _, o in pairs(handles) do
        if type(o) == "table" and o.__alive and (o.tag == want or o.tip == want) then return o end
    end
    return nil
end
function T.near(a, b) return math.abs(a - b) < 1e-6 end
function T.tintIs(t, c) return t and T.near(t[1], c.r) and T.near(t[2], c.g) and T.near(t[3], c.b) and T.near(t[4], c.a) end
T.DIM = theme.game.textDisabled
T.calls = function() return C.stats.uobjectCalls end


-- ---------------------------------------------------------------- story 31: the create-server screen and the modules
local CK = require("nucleus.ui.checkbox")
local G = require("nucleus.ui.game")
-- the controls' widgets (controls_test.lua's fakes): a slider on the screen
T.SL = require("nucleus.ui.slider")
T.BN = require("nucleus.ui.button")
T.CHOICECLASS = cls("/Game/Mods/Nucleus/WBP_NucleusChoice.WBP_NucleusChoice_C")
T.SLIDERCLASS = cls("/Game/Mods/Nucleus/WBP_NucleusSlider.WBP_NucleusSlider_C")
F.assets["/Game/Graphics/MainMenu/SettingsMenu.SettingsMenu_C"] = obj({ __asset = "SettingsMenu_C" }, "/Game/Graphics/MainMenu/SettingsMenu.SettingsMenu_C")
T.TPATH = "/Game/Graphics/MainMenu/SettingsMenu.SettingsMenu_C:WidgetTree.Slider"
T.TEMPLATE = obj({ __asset = "Slider" }, T.TPATH)
function T.newChoiceW()
    local w = widget("WBP_NucleusChoice_C", "/Engine/Transient.WBP_NucleusChoice_C_" .. (F.addr + 0x100), 40)
    tagged(w)
    w.Frame, w.Background = T.inner(4), T.inner(4)
    w.valueSets = 0
    function w:SetValueText(t) self.value = t; self.valueSets = self.valueSets + 1 end
    function w:SetArrows(p, n, ...) self.arrows = { p, n, ... } end
    function w:SetValueLook(f, size, ...) self.look = { f, size, ... } end
    function w:SetRenderOpacity(o) self.opacity = o end
    return w
end
function T.newSliderW()
    local w = widget("WBP_NucleusSlider_C", "/Engine/Transient.WBP_NucleusSlider_C_" .. (F.addr + 0x100), 40)
    tagged(w)
    w.Frame = T.inner(4)
    w.barValue, w.text, w.hint, w.sets = 0, "", "", 0
    w.Bar = { GetValue = function() return w.barValue end }
    w.Box = { GetText = function() return { ToString = function() return w.text end } end }
    function w:SetRange(a, b, s, d) self.range = { a, b, s, d } end
    function w:SetSliderValue(v)
        self.barValue = v; self.sets = self.sets + 1
        local d = self.range and self.range[4] or 0
        self.text = string.format("%." .. d .. "f", v)
    end
    function w:SetSliderEmpty(v) self.barValue = v; self.text = ""; self.sets = self.sets + 1 end
    function w:SetHint(h) self.hint = h end
    function w:SetBoxWidth(v) self.boxW = v end
    function w:SetEnabledState(e) self.enabled = e end
    function w:SetBoxLook(f, size) self.look = { f, size } end
    function w:CopySliderStyle(t) self.copied = t; self.copies = (self.copies or 0) + 1 end
    function w:SetRenderOpacity(o) self.opacity = o end
    return w
end
do
    local WBL = F.objects["/Script/UMG.Default__WidgetBlueprintLibrary"]
    local base = WBL.Create
    WBL.Create = function(self, world, c, owner)
        if c == T.CHOICECLASS then return T.newChoiceW() end
        if c == T.SLIDERCLASS then return T.newSliderW() end
        return base(self, world, c, owner)
    end
end
T.CLICK = "WBP_NucleusButton_C:Nucleus_OnClicked"
function T.fire(sub, w) clock = clock + 300000; fireHook(sub, w) end
cls("/Game/Graphics/MainMenu/CreateServer.CreateServer_C")
F.screens = {}
-- CreateServer_C: root CanvasPanel_21; Back is RemoveFromParent (out of the viewport, still alive until a GC).
function T.newCS(n, opts)
    opts = opts or {}
    local path = "/Engine/Transient.GameEngine_1:GameInstance_1.CreateServer_C_" .. n
    local s = widget("CreateServer_C", path)
    s.__name = "CreateServer_C_" .. n
    s.inViewport = true
    local root = opts.rootClass and widget(opts.rootClass, path .. ".WidgetTree.Overlay_9") or newCanvas(path .. ".WidgetTree.CanvasPanel_21")
    s.WidgetTree = { RootWidget = root }
    s.canvas = root
    function s:IsInViewport() return self.inViewport end
    function s:GetOwningPlayer() return opts.owner end
    function s:GetWorld() return WORLD end
    function s:RemoveFromParent() self.inViewport = false end
    F.screens[#F.screens + 1] = s
    return s
end
-- A screen built by the game (START GAME): the creation callback sees it.
function T.notify(s)
    for _, nt in ipairs(F.notify) do if nt.cls:find("CreateServer_C", 1, true) then nt.fn(s) end end
    return s
end
function T.open(n, opts) return T.notify(T.newCS(n, opts)) end
do
    local base = FindAllOf
    FindAllOf = function(c)
        if c == "CreateServer_C" then
            F.findAll = F.findAll + 1
            local out = {}
            for _, s in ipairs(F.screens) do if s.__alive then out[#out + 1] = s end end
            return out
        end
        return base(c)
    end
end
-- Our widget of one id in a screen's canvas (by its tag), or nil; and how many there are.
function T.inCanvas(s, id)
    local want = "nucleus:TestMod:" .. id
    for _, c in ipairs(s.canvas.children or {}) do if c.__alive and (c.tag == want or c.tip == want) then return c end end
    return nil
end
function T.countIn(s, id)
    local want, n = "nucleus:TestMod:" .. id, 0
    for _, c in ipairs(s.canvas.children or {}) do if c.tag == want or c.tip == want then n = n + 1 end end
    return n
end
T.ev = {}                        -- events per watcher name: { event, path, reason, host, screen }
function T.watcher(name)
    T.ev[name] = {}
    return function(s, info) table.insert(T.ev[name], { event = info.event, path = info.path, reason = info.reason, host = info.host, screen = s }) end
end
function T.evs(name) local t = {} for _, e in ipairs(T.ev[name] or {}) do t[#t + 1] = e.event end return table.concat(t, ",") end
function T.lastEv(name) local l = T.ev[name] return l[#l] end
local GP = "nucleus.ui.game."
local CSH = "createServer"

-- ---------------------------------------------------------------- story 32: the settings list in the screen
local I = { removes = 0, adds = 0 }
-- 26 game rows: the header, Difficulty (Overlay_28), Lobby Time (Overlay_27), ..., the enemy slots (Overlay_738, 16th),
-- Enemy Random Frequency (Overlay_33), ...
I.ROWS = { "Overlay_10", "Overlay_28", "Overlay_27", "Overlay_29" }
for i = 5, 15 do I.ROWS[#I.ROWS + 1] = "Overlay_" .. (100 + i) end
I.ROWS[#I.ROWS + 1] = "Overlay_738"
I.ROWS[#I.ROWS + 1] = "Overlay_33"
for i = 18, 26 do I.ROWS[#I.ROWS + 1] = "Overlay_" .. (200 + i) end
assert(#I.ROWS == 26)
I.POS = {}
for i, n in ipairs(I.ROWS) do I.POS[n] = i end
-- a box whose AddChild moves a parented widget (UPanelWidget::AddChild) and that has RemoveChild; counted
function I.box(cls, path, horiz)
    local b = newBox(cls, path, horiz)
    local add = b.AddChild
    function b:AddChild(w)
        if w.parent then w:RemoveFromParent() end
        I.adds = I.adds + 1
        local sl = add(self, w)
        if w.onAdded then w:onAdded() end -- UMG rebuilds a re-added widget: a user widget's PreConstruct runs again
        return sl
    end
    function b:RemoveChild(w)
        for i, c in ipairs(self.children) do
            if c == w then table.remove(self.children, i); w.parent = nil; I.removes = I.removes + 1 return true end
        end
        return false
    end
    return b
end
-- every game row's own slot values (distinct per row)
function I.slotOf(i)
    return { Padding = { Left = i, Top = i + 0.5, Right = 2 * i, Bottom = 3 }, HorizontalAlignment = i % 4, VerticalAlignment = (i + 1) % 4,
        Size = { SizeRule = i % 2, Value = 1 + i / 10 } }
end
-- The game's picker (MultipleSelectBox_C): GetSelectedIndex, SetSelectedOption (no broadcast), and PreConstruct, which
-- puts back DefaultOption (MultipleSelectBox_C.cpp:76) whenever the widget is rebuilt (a re-add).
function I.picker(path, def)
    local pk = widget("MultipleSelectBox_C", path)
    pk.def, pk.sel, pk.pre, pk.sets = def, def, 0, 0
    function pk:GetSelectedIndex() return self.sel end
    function pk:SetSelectedOption(i) self.sel = i; self.sets = self.sets + 1 end
    function pk:PreConstruct() self.sel = self.def; self.pre = self.pre + 1 end
    return pk
end
-- rows with a picker: Difficulty (MultipleSelectBox_6, default 1 Normal) and Lobby Time (MultipleSelectBox_5, default 0)
I.PICKERS = { Overlay_28 = { "MultipleSelectBox_6", 1 }, Overlay_27 = { "MultipleSelectBox_5", 0 } }
-- CreateServer_C as the game builds it: CanvasPanel_21 > Overlay_0 > ScrollBox_54 > VerticalBox_202 (26 rows), an empty
-- HorizontalBox_9, and Image_5 (not a box). VerticalBox_202's own slot in the ScrollBox has its own values.
do
    local baseCS = T.newCS
    T.newCS = function(n, opts)
        local s = baseCS(n, opts)
        if opts and opts.rootClass then return s end
        local p = s.__path .. ".WidgetTree."
        local ov = I.box("Overlay", p .. "Overlay_0")
        s.canvas:AddChildToCanvas(ov)
        s.canvas:AddChildToCanvas(widget("Image", p .. "Image_5"))
        local sb = I.box("ScrollBox", p .. "ScrollBox_54")
        ov:AddChild(sb)
        local vb = I.box("VerticalBox", p .. "VerticalBox_202")
        sb:AddChild(vb)
        local hb = I.box("HorizontalBox", p .. "HorizontalBox_9", true)
        ov:AddChild(hb)
        local vs = vb.Slot
        vs.Padding, vs.HorizontalAlignment, vs.VerticalAlignment, vs.Size = { Left = 7, Top = 8, Right = 9, Bottom = 10 }, 2, 3, { SizeRule = 1, Value = 0.5 }
        s.pickers = {}
        for i, nm in ipairs(I.ROWS) do
            local r
            if I.PICKERS[nm] then
                r = I.box("Overlay", p .. nm)
                local inner = I.box("HorizontalBox", p .. nm .. "_HB", true)
                r:AddChild(inner)
                local pk = I.picker(p .. I.PICKERS[nm][1], I.PICKERS[nm][2])
                inner:AddChild(pk)
                s.pickers[nm] = pk
                function r:onAdded() pk:PreConstruct() end
            else
                r = widget("Overlay", p .. nm)
            end
            local sl = vb:AddChild(r)
            local v = I.slotOf(i)
            sl.Padding, sl.HorizontalAlignment, sl.VerticalAlignment, sl.Size = v.Padding, v.HorizontalAlignment, v.VerticalAlignment, v.Size
        end
        s.vb, s.hb = vb, hb
        I.adds, I.removes = 0, 0
        return s
    end
end
-- a child's id (ours: from the tag) or widget name (the game's)
function I.nameOf(c)
    local t = (c.tag ~= nil and c.tag ~= "" and c.tag) or (c.tip ~= nil and c.tip ~= "" and c.tip) or nil
    if t then return t:match("^nucleus:TestMod:(.+)$") or t end
    return c:GetFName():ToString()
end
function I.names(box) local t = {} for _, c in ipairs(box.children) do t[#t + 1] = I.nameOf(c) end return t end
function I.list(box) return table.concat(I.names(box), ",") end
function I.indexOf(box, name) for i, n in ipairs(I.names(box)) do if n == name then return i - 1 end end return nil end
function I.count(box, name) local k = 0 for _, n in ipairs(I.names(box)) do if n == name then k = k + 1 end end return k end
-- the game rows keep their order and their own slot values
function I.gameOk(box)
    local seen = 0
    for _, c in ipairs(box.children) do
        local i = I.POS[I.nameOf(c)]
        if i then
            seen = seen + 1
            if i ~= seen then return false, "row " .. I.nameOf(c) .. " at game position " .. seen end
            local v, s = I.slotOf(i), c.Slot
            if s.Padding.Left ~= v.Padding.Left or s.Padding.Top ~= v.Padding.Top or s.Padding.Right ~= v.Padding.Right or s.Padding.Bottom ~= v.Padding.Bottom
                or s.HorizontalAlignment ~= v.HorizontalAlignment or s.VerticalAlignment ~= v.VerticalAlignment
                or s.Size.SizeRule ~= v.Size.SizeRule or s.Size.Value ~= v.Size.Value then
                return false, "row " .. I.nameOf(c) .. "'s slot changed"
            end
        end
    end
    if seen ~= 26 then return false, seen .. " game rows" end
    return true
end
function I.rebuilds() return X.stats().containerRebuilds end
local VB = "VerticalBox_202"
local PL = "nucleus.ui.place: "

-- ---------------------------------------------------------------- core story 33: the fakes it adds
local CH = require("nucleus.ui.choice")
local Q = { tips = 0 }            -- this part's own helpers and state
-- UMG classes core constructs (StaticConstructObject) and the game classes it creates (WidgetBlueprintLibrary:Create)
cls("/Script/UMG.TextBlock", "TextBlock")
cls("/Script/UMG.HorizontalBox", "HorizontalBox")
cls("/Script/UMG.Spacer", "Spacer")
Q.MSBCLASS = cls("/Game/Graphics/MainMenu/Components/MultipleSelectBox.MultipleSelectBox_C")
Q.TIPCLASS = cls("/Game/HexTree/Widgets/Elements/W_ToolTip3.W_ToolTip3_C")
Q.TIPPATH = "/Game/HexTree/Widgets/Elements/W_ToolTip3.W_ToolTip3_C"
obj({}, C.MSB_NEXT_FN)
obj({}, C.MSB_PREV_FN)
obj({ SetTextPropertyByName = function(_, o, name, t) o[name] = t end }, "/Script/Engine.Default__KismetSystemLibrary")
Q.MEDIUM = obj({ __asset = "AlumniSans-Medium_Font" }, "/Game/Fonts/Remaster/AlumniSans-Medium_Font.AlumniSans-Medium_Font")
Q.XBOLD = F.assets["/Game/Fonts/Remaster/AlumniSans-ExtraBold_Font.AlumniSans-ExtraBold_Font"]
Q.REGULAR = F.assets["/Game/Fonts/Remaster/AlumniSans-Regular_Font.AlumniSans-Regular_Font"]
Q.STRIP = F.assets["/Game/Graphics/MainMenu/Styles/Remaster/M_NN_WornStrip.M_NN_WornStrip"]

-- A UMG TextBlock
function Q.textBlock(path, name)
    local t = widget("TextBlock", path)
    t.__name = name
    t.text, t.Justification = "", 0
    function t:SetText(x) self.text = x.s end
    function t:GetText() return { ToString = function() return t.text end } end
    function t:SetFont(f) self.Font = f end
    function t:SetColorAndOpacity(c) self.ColorAndOpacity = c end
    function t:SetJustification(j) self.Justification = j end
    function t:SetToolTip(w) self.ToolTipWidget = w end
    function t:SetToolTipText(x) self.tipText = x.s end
    return t
end
function StaticConstructObject(c, outer, name)
    Q.constructs = (Q.constructs or 0) + 1
    local path = "/Engine/Transient." .. tostring(name) .. "_" .. (F.addr + 0x100)
    if c.__isClass == "TextBlock" then return Q.textBlock(path, name) end
    if c.__isClass == "Spacer" then
        local sp = widget("Spacer", path)
        sp.__name = name
        function sp:SetSize(v) self.Size = { X = v.X, Y = v.Y } end
        return sp
    end
    if c.__isClass == "HorizontalBox" then
        local b = I.box("HorizontalBox", path, true)
        b.__name = name
        return b
    end
    error("StaticConstructObject: unexpected class")
end
-- The game's picker: Items, SelectedOption and DefaultOption are strings (MultipleSelectBox_C.cpp); PreConstruct shows
-- DefaultOption again whenever the widget is rebuilt (a re-add); an arrow click moves the selection, then the post-hooks.
function Q.msb(path)
    local m = widget("MultipleSelectBox_C", path)
    m.Items, m.SelectedOption, m.DefaultOption, m.enabled, m.pre, m.sets = {}, "", "", true, 0, 0
    function m:AddOption(o, _) table.insert(self.Items, o) end
    function m:GetSelectedIndex() for i, o in ipairs(self.Items) do if o == self.SelectedOption then return i - 1 end end return -1 end
    function m:SetSelectedOption(i) self.SelectedOption = self.Items[i + 1]; self.sets = self.sets + 1 end
    function m:PreConstruct() self.SelectedOption = self.DefaultOption; self.pre = self.pre + 1 end
    function m:SetIsEnabled(e) self.enabled = e end
    function m:SetRenderOpacity(o) self.opacity = o end
    function m:click(delta, advance)
        if advance ~= false then clock = clock + 300000 end
        local i = self:GetSelectedIndex() + delta
        if self.Items[i + 1] then self.SelectedOption = self.Items[i + 1] end
        fireHook(delta > 0 and "Button_K2Node_ComponentBoundEvent_0" or "Button_60_K2Node_ComponentBoundEvent_1", self)
    end
    return m
end
-- UMG rebuilds a re-added widget's whole subtree: every user widget's PreConstruct inside runs again.
function Q.rebuildTree(w, d)
    d = d or 0
    if d > 8 or type(w) ~= "table" then return end
    if w.__class == "MultipleSelectBox_C" and w.PreConstruct then w:PreConstruct() return end
    for _, k in ipairs({ "HBox" }) do if w[k] then Q.rebuildTree(w[k], d + 1) end end
    for _, c in ipairs(w.children or {}) do Q.rebuildTree(c, d + 1) end
end
do
    local WBL = F.objects["/Script/UMG.Default__WidgetBlueprintLibrary"]
    local base = WBL.Create
    WBL.Create = function(self, world, c, owner)
        if c == Q.MSBCLASS then
            local m = Q.msb("/Engine/Transient.MultipleSelectBox_C_" .. (F.addr + 0x100))
            Q.lastMsb = m
            return m
        end
        if c == Q.TIPCLASS then
            local t = widget("W_ToolTip3_C", "/Engine/Transient.W_ToolTip3_C_" .. (F.addr + 0x100))
            Q.tips = Q.tips + 1
            return t
        end
        local w = base(self, world, c, owner)
        if c == ROWCLASS then
            -- WBP_<Core>Row: its Border "Background" and its WidgetTree
            w.Background = { vis = 4 }
            function w.Background:SetBrush(b) self.Brush = b end
            function w.Background:SetBrushColor(c2) self.BrushColor = c2 end
            function w.Background:SetPadding(p) self.Padding = p end
            function w.Background:SetHorizontalAlignment(a) self.HA = a end
            function w.Background:SetVerticalAlignment(a) self.VA = a end
            function w.Background:SetVisibility(v) self.vis = v end
            w.WidgetTree = obj({}, w.__path .. ".WidgetTree")
            function w:onAdded() Q.rebuildTree(self) end
        end
        return w
    end
end

-- The Difficulty row as the game builds it (presets-and-ui.md "A row"): Overlay_28 > [Image_23, HorizontalBox_4 >
-- [TextBlock_8, HorizontalBox_53 > [MultipleSelectBox_6, TextBlock_57 "?"]]], each slot with its own values.
Q.BRUSH = { ResourceObject = Q.STRIP, ImageSize = { X = 128, Y = 44 }, DrawAs = 2, Margin = { Left = 0.24, Top = 0.24, Right = 0.24, Bottom = 0.24 } }
Q.TINT = { R = 1, G = 1, B = 1, A = 0.72 }
Q.LFONT = { FontObject = Q.MEDIUM, Size = 22 }
Q.QFONT = { FontObject = Q.XBOLD, Size = 22 }
Q.LCOL = { SpecifiedColor = { R = 0.917, G = 0.933, B = 0.929, A = 1 }, ColorUseRule = 0 }
Q.QCOL = { SpecifiedColor = { R = 0.82, G = 0.85, B = 0.84, A = 1 }, ColorUseRule = 0 }
Q.SLOTS = {
    hbox = { Padding = { Left = 12, Top = 2, Right = 12, Bottom = 2 }, HorizontalAlignment = 0, VerticalAlignment = 2 },
    label = { Padding = { Left = 4, Top = 5, Right = 0, Bottom = 5 }, Size = { SizeRule = 1, Value = 1 }, HorizontalAlignment = 0, VerticalAlignment = 2 },
    inner = { Padding = { Left = 0, Top = 0, Right = 6, Bottom = 0 }, Size = { SizeRule = 0, Value = 1 }, HorizontalAlignment = 2, VerticalAlignment = 2 },
    control = { Padding = { Left = 0, Top = 0, Right = 8, Bottom = 0 }, Size = { SizeRule = 0, Value = 1 }, HorizontalAlignment = 0, VerticalAlignment = 2 },
    help = { Padding = { Left = 10, Top = 0, Right = 0, Bottom = 0 }, Size = { SizeRule = 0, Value = 1 }, HorizontalAlignment = 0, VerticalAlignment = 2 },
}
local function setSlot(sl, v) for k, x in pairs(v) do sl[k] = x end end
I.PICKERS.Overlay_28 = nil
do
    local baseCS = T.newCS
    T.newCS = function(n, opts)
        local s = baseCS(n, opts)
        if opts and opts.rootClass then return s end
        local p = s.__path .. ".WidgetTree."
        local vb = s.vb
        local k, old
        for i, c in ipairs(vb.children) do if c:GetFName():ToString() == "Overlay_28" then k, old = i, c end end
        local row = I.box("Overlay", p .. "Overlay_28")
        local img = widget("Image", p .. "Image_23")
        img.Brush, img.ColorAndOpacity = Q.BRUSH, Q.TINT
        row:AddChild(img)
        local hb = I.box("HorizontalBox", p .. "HorizontalBox_4", true)
        setSlot(row:AddChild(hb), Q.SLOTS.hbox)
        local lbl = Q.textBlock(p .. "TextBlock_8")
        lbl.text, lbl.Font, lbl.ColorAndOpacity, lbl.Justification = "Difficulty", Q.LFONT, Q.LCOL, 0
        setSlot(hb:AddChild(lbl), Q.SLOTS.label)
        local inner = I.box("HorizontalBox", p .. "HorizontalBox_53", true)
        setSlot(hb:AddChild(inner), Q.SLOTS.inner)
        local pk = I.picker(p .. "MultipleSelectBox_6", 1)
        setSlot(inner:AddChild(pk), Q.SLOTS.control)
        local q = Q.textBlock(p .. "TextBlock_57")
        q.text, q.Font, q.ColorAndOpacity, q.Justification = "?", Q.QFONT, Q.QCOL, 1
        setSlot(inner:AddChild(q), Q.SLOTS.help)
        row.parent, row.Slot = vb, old.Slot
        vb.children[k] = row
        s.pickers.Overlay_28 = pk
        function row:onAdded() pk:PreConstruct() end
        I.adds, I.removes = 0, 0
        return s
    end
end
-- our row widget in a box, by element id
function Q.ours(box, id)
    for _, c in ipairs(box.children) do if I.nameOf(c) == id then return c end end
    return nil
end
function Q.parts(w)
    local hb = w.HBox
    local inner = hb.children[2]
    return { label = hb.children[1], inner = inner, holder = inner and inner.children[1], help = inner and inner.children[2], height = hb.children[3], n = #hb.children }
end
function Q.sameSlot(sl, v)
    if not sl then return false end
    for k, x in pairs(v) do
        local y = sl[k]
        if type(x) == "table" then
            for kk, xx in pairs(x) do if type(y) ~= "table" or y[kk] ~= xx then return false end end
        elseif y ~= x then return false end
    end
    return true
end
function Q.calls(path) local n = 0 for _, h in ipairs(F.hooks) do if h.path == path then n = n + 1 end end return n end
local RC = "nucleus.ui.row.create: "
local CC = "nucleus.ui.choice.create: "
local OPTS = { "Default", "Off", "Low", "Medium", "High", "Max" }
local HELP3 = "How hard enemies hit.\nDefault keeps the game's value.\nRange 0-200."

-- ---------------------------------------------------------------- bad input (the matrix's last row)
do
    local function bad(o, text, name) raises(function() RS.create(o) end, RC .. text, "bad input: " .. name) end
    local IN = { host = CSH, container = VB, after = "Overlay_28" }
    local L65 = string.rep("a", 65)
    bad({ id = "bx", like = "Overlay_28", nope = 1, place = IN }, "unknown key 'nope' (valid: control, gap, help, id, label, like, place, style)", "an unknown key lists the new keys")
    bad({ id = "bx", like = 28, place = IN }, "like must be a game widget's name (a string), got 28", "like a number")
    bad({ id = "bx", like = "", place = IN }, "like must not be empty", "like empty")
    bad({ id = "bx", like = L65, place = IN }, "like is 65 characters, at most 64", "like 65 characters")
    bad({ id = "bx", like = "Over lay", place = IN }, "like 'Over lay' is not a widget name", "like with a space")
    bad({ id = "bx", like = "9Row", place = IN }, "like '9Row' is not a widget name", "like starting with a digit")
    bad({ id = "bx", like = {}, place = IN }, "like must be a game widget's name (a string), got table", "like a table")
    bad({ id = "bx", label = "X", place = IN }, "label needs like = <game row name>", "label without like")
    bad({ id = "bx", help = "X", place = IN }, "help needs like = <game row name>", "help without like")
    bad({ id = "bx", label = "X", help = "Y", place = IN }, "label and help need like = <game row name>", "label and help without like")
    bad({ id = "bx", like = "Overlay_28", label = 5, place = IN }, "label must be a string or a table of strings by language", "label a number")
    bad({ id = "bx", like = "Overlay_28", label = "", place = IN }, "label must be a string of 1 to 64 bytes, got 0 bytes", "label empty")
    bad({ id = "bx", like = "Overlay_28", label = L65, place = IN }, "label must be a string of 1 to 64 bytes, got 65 bytes", "label 65 bytes")
    bad({ id = "bx", like = "Overlay_28", label = "a\nb", place = IN }, "label has the control byte 0x0A at byte 2", "label with a newline")
    bad({ id = "bx", like = "Overlay_28", label = { de = "X" }, place = IN }, "label needs an en string (the fallback)", "label table without en")
    bad({ id = "bx", like = "Overlay_28", label = { en = L65 }, place = IN }, "label.en must be a string of 1 to 64 bytes, got 65 bytes", "label.en 65 bytes")
    bad({ id = "bx", like = "Overlay_28", label = { en = "X", ["1x"] = "Y" }, place = IN }, "label key '1x' is not a language tag", "label with a bad language key")
    bad({ id = "bx", like = "Overlay_28", help = 5, place = IN }, "help must be a string or a table of strings by language", "help a number")
    bad({ id = "bx", like = "Overlay_28", help = string.rep("h", 513), place = IN }, "help must be a string of 1 to 512 bytes, got 513 bytes", "help 513 bytes")
    bad({ id = "bx", like = "Overlay_28", help = "1\n2\n3\n4\n5\n6\n7\n8\n9", place = IN }, "help has 9 lines, at most 8", "help 9 lines")
    bad({ id = "bx", like = "Overlay_28", help = { en = "a", de = "1\n2\n3\n4\n5\n6\n7\n8\n9" }, place = IN }, "help.de has 9 lines, at most 8", "help.de 9 lines")
    bad({ id = "bx", like = "Overlay_28", help = "a\tb", place = IN }, "help has the control byte 0x09 at byte 2", "help with a tab")
    bad({ id = "bx", like = "Overlay_28", help = { de = "x" }, place = IN }, "help needs an en string (the fallback)", "help table without en")
    bad({ id = "bx", like = "Overlay_28", place = { host = "menu", corner = "top-left" } }, "like needs a game screen host (createServer), got 'menu'", "like on the menu")
    bad({ id = "bx", like = "Overlay_28", place = { host = "journal", corner = "top-left" } }, "like needs a game screen host (createServer), got 'journal'", "like on the journal")
    bad({ id = "bx", like = "Overlay_28" }, "like needs a game screen host (createServer), got 'hud'", "like with no place (hud)")
    local lst = LS.create{ id = "bl.list", place = { host = CSH, corner = "top-left" }, size = { w = 300, h = 200 } }
    bad({ id = "bx", like = "Overlay_28", place = { list = lst } }, "a row with like can't go inside a panel, list or row", "like inside a core list")
    local PN = require("nucleus.ui.panel")
    local pnl = PN.create{ id = "bl.panel", place = { host = CSH, corner = "top-left" } }
    bad({ id = "bx", like = "Overlay_28", place = { panel = pnl } }, "a row with like can't go inside a panel, list or row", "like inside a core panel")
    -- control
    local tx = X.create{ id = "bl.text", text = "x", place = { host = CSH, corner = "top-left" } }
    bad({ id = "bx", like = "Overlay_28", control = 5, place = IN }, "control must be a checkbox, choice, slider or button handle, got 5", "control a number")
    bad({ id = "bx", like = "Overlay_28", control = {}, place = IN }, "control is not an element handle of this mod", "control a forged table")
    bad({ id = "bx", like = "Overlay_28", control = tx, place = IN }, "control 'bl.text' is a text element, not a checkbox, choice, slider or button", "control a text")
    bad({ id = "bx", like = "Overlay_28", control = lst, place = IN }, "control 'bl.list' is a list, not a checkbox, choice, slider or button", "control a list")
    local gone = CK.create{ id = "bl.cb", place = { host = CSH, corner = "top-left" }, onChange = function() end }
    CK.remove(gone)
    bad({ id = "bx", like = "Overlay_28", control = gone, place = IN }, "control handle 'bl.cb' was removed", "control removed")
    bad({ id = "bx", control = tx, place = IN }, "control needs like = <game row name>", "control without like")
    ok(C.els.bx == nil, "bad input: nothing created")
    -- setLabel / setHelp
    local plain = RS.create{ id = "bl.plain", place = { list = lst } }
    raises(function() RS.setLabel(plain, "X") end, "nucleus.ui.row.setLabel: row 'bl.plain' is not a game-style row (made without like)", "bad input: setLabel on a row without like")
    raises(function() RS.setHelp(plain, "X") end, "nucleus.ui.row.setHelp: row 'bl.plain' is not a game-style row (made without like)", "bad input: setHelp on a row without like")
    local lr = RS.create{ id = "bl.like", like = "Overlay_28", label = "L", place = IN }
    raises(function() RS.setLabel(lr, 5) end, "nucleus.ui.row.setLabel: label must be a string or a table of strings by language", "bad input: setLabel a number")
    raises(function() RS.setLabel(lr, nil) end, "nucleus.ui.row.setLabel: label must be a string or a table of strings by language, like { en = \"Enemy Damage\" }, got nil", "bad input: setLabel nil")
    raises(function() RS.setLabel(lr, L65) end, "nucleus.ui.row.setLabel: label must be a string of 1 to 64 bytes, got 65 bytes", "bad input: setLabel 65 bytes")
    raises(function() RS.setLabel(lr) end, "nucleus.ui.row.setLabel: expected 2 arguments (handle, label), got 1", "bad input: setLabel with no label")
    raises(function() RS.setLabel(lr, "a", "b") end, "nucleus.ui.row.setLabel: expected 2 arguments (handle, label), got 3", "bad input: setLabel with three")
    raises(function() RS.setHelp(lr, "1\n2\n3\n4\n5\n6\n7\n8\n9") end, "nucleus.ui.row.setHelp: help has 9 lines, at most 8", "bad input: setHelp 9 lines")
    raises(function() RS.setHelp(lr, string.rep("h", 513)) end, "nucleus.ui.row.setHelp: help must be a string of 1 to 512 bytes, got 513 bytes", "bad input: setHelp 513 bytes")
    raises(function() RS.setHelp(lr) end, "nucleus.ui.row.setHelp: expected 2 arguments (handle, help), got 1", "bad input: setHelp with no help")
    raises(function() RS.setLabel(tx, "X") end, "nucleus.ui.row.setLabel: not a row handle ('bl.text' is a text element)", "bad input: setLabel on a text")
    raises(function() RS.setHelp({}, "X") end, "nucleus.ui.row.setHelp: not a row handle", "bad input: setHelp on a forged handle")
    -- moving a game-style row off its game screen, or into a core container
    raises(function() P.place(lr, { host = "menu", corner = "top-left" }) end, "nucleus.ui.place: like needs a game screen host (createServer), got 'menu'", "bad input: place a like row on the menu")
    raises(function() P.place(lr, { list = lst }) end, "nucleus.ui.place: a row with like can't go inside a panel, list or row", "bad input: place a like row in a list")
    raises(function() RS.create{ id = "bl.like", place = IN } end, "id 'bl.like' is already a row with like; remove it first", "bad input: the same id without like")
    RS.remove(lr); RS.remove(plain)
    raises(function() RS.setLabel(lr, "X") end, "nucleus.ui.row: handle 'bl.like' was removed", "bad input: setLabel on a removed row")
    -- the game choice
    local function cbad(o, text, name)
        o.options = o.options or OPTS
        o.onChange = o.onChange or function() end
        o.id = o.id or "bc"
        raises(function() CH.create(o) end, CC .. text, "bad input: " .. name)
    end
    cbad({ widget = "game", place = { host = "menu", corner = "top-left" } }, "widget 'game' needs a game screen host (createServer), got 'menu'", "game choice on the menu")
    cbad({ widget = "game", place = { corner = "top-left" } }, "widget 'game' needs a game screen host (createServer), got 'hud'", "game choice on the hud")
    local sl = LS.create{ id = "bl.slist", place = { host = "journal", corner = "top-left" }, size = { w = 300, h = 200 } }
    cbad({ widget = "game", place = { list = sl } }, "widget 'game' needs a game screen host (createServer), got 'journal'", "game choice in a list on the journal")
    cbad({ widget = "game", tooltip = "x", place = { host = CSH, corner = "top-left" } }, "tooltip is not available with widget 'game'", "game choice with a tooltip")
    cbad({ widget = "game", options = { "A", "B", "A" }, place = { host = CSH, corner = "top-left" } }, "options[3] 'A' repeats options[1] (widget 'game' needs distinct options", "game choice with duplicate options")
    cbad({ widget = "fancy", place = { host = CSH, corner = "top-left" } }, "unknown widget 'fancy' (valid: core)", "an unknown widget keeps its text")
    local gc = CH.create{ id = "bl.gc", widget = "game", options = OPTS, onChange = function() end }
    raises(function() CH.setTooltip(gc, "x") end, "nucleus.ui.choice.setTooltip: choice 'bl.gc' has widget 'game', which takes no tooltip", "bad input: setTooltip on a game choice")
    ok(pcall(CH.setTooltip, gc, nil), "setTooltip(nil) on a game choice: nothing to clear, no error")
    raises(function() CH.create{ id = "bl.gc", options = OPTS, onChange = function() end, place = { host = CSH, corner = "top-left" } } end,
        CC .. "id 'bl.gc' is already a choice with widget 'game'", "bad input: the same id as a core choice")
    raises(function() P.place(gc, { host = "menu", corner = "top-left" }) end, "nucleus.ui.place: widget 'game' needs a game screen host (createServer), got 'menu'", "bad input: place a game choice on the menu")
    local mrow = RS.create{ id = "bl.mrow", place = { list = sl } }
    raises(function() P.place(gc, { row = mrow }) end, "nucleus.ui.place: widget 'game' needs a game screen host (createServer), got 'journal'", "bad input: place a game choice into a row on the journal")
    ok(tostring(gc) == "choice 'bl.gc'" and CH.get(gc) == 1, "a game choice's handle is a choice's (tostring, get)")
    raises(function() CK.get(gc) end, "not a checkbox handle ('bl.gc' is a choice)", "a game choice named as a choice in errors")
    CH.remove(gc)
    raises(function() CH.get(gc) end, "nucleus.ui.choice: handle 'bl.gc' was removed", "a removed game choice: the choice's text")
    RS.remove(mrow); LS.remove(sl); LS.remove(lst); PN.remove(pnl); X.remove(tx)
end

-- ---------------------------------------------------------------- the tooltip class missing (before any load)
do
    F.missing[Q.TIPPATH] = true
    local r = RS.create{ id = "tm", like = "Overlay_28", label = "No Tip Class", help = "plain help", place = { host = CSH, container = VB, after = "Overlay_28" } }
    local s = T.open(300)
    tick()
    local w = Q.ours(s.vb, "tm")
    local p = w and Q.parts(w)
    ok(p and p.help.tipText == "plain help" and p.help.ToolTipWidget == nil and p.help.vis == C.VIS.Visible,
        "tooltip class missing: the \"?\" gets SetToolTipText(help), Visible for the hover")
    ok(countLogs("WARN the game's tooltip widget W_ToolTip3_C (/Game/HexTree/Widgets/Elements/W_ToolTip3.W_ToolTip3_C) could not be loaded") == 1,
        "tooltip class missing: one WARN")
    s:RemoveFromParent(); tick()
    local s2 = T.open(301); tick()
    ok(countLogs("W_ToolTip3_C (/Game/HexTree") == 1, "tooltip class missing: still one WARN after another open")
    s2:RemoveFromParent(); tick()
    RS.remove(r)
    F.missing[Q.TIPPATH] = nil
end

-- ---------------------------------------------------------------- the like row, a game choice, a core checkbox, a fallback
local LOG = {}
local gch = CH.create{ id = "nr.c", widget = "game", options = OPTS, selected = 3, onChange = function(h, i, o) LOG[#LOG + 1] = { h = h, i = i, o = o } end }
local like1 = RS.create{ id = "nr.r1", like = "Overlay_28", label = "Enemy Damage", help = HELP3, control = gch,
    place = { host = CSH, container = VB, after = "Overlay_28" } }
local cbx = CK.create{ id = "nr.cb", onChange = function() end, place = { host = CSH, corner = "top-left" } }
local like2 = RS.create{ id = "nr.r2", like = "Overlay_28", label = { en = "Damage Spread", de = "Streuung" }, help = { en = "spread", de = "Streuung hilfe" }, control = cbx,
    place = { host = CSH, container = VB, after = "Overlay_28" } }
local nope = RS.create{ id = "nr.r3", like = "Overlay_NOPE", label = "Not Like", help = "x", place = { host = CSH, container = VB, after = "Overlay_28" } }
ok(C.els["nr.c"].panel == C.els["nr.r1"] and C.els["nr.cb"].panel == C.els["nr.r2"], "control: placed into its row (place(control, { row = h }))")
ok(CH.isShown(gch) == false and RS.isShown(like1) == false, "before an open: pending")

do
    local s = T.open(310)
    local tips0 = X.stats().gameTips
    tick()
    local vb = s.vb
    ok(I.indexOf(vb, "nr.r1") == 2 and I.indexOf(vb, "nr.r2") == 3 and I.indexOf(vb, "nr.r3") == 4, "the rows right after the Difficulty row, in creation order", I.list(vb))
    local g, why = I.gameOk(vb)
    ok(g, "every game row keeps its order and slot values", why)
    local w = Q.ours(vb, "nr.r1")
    local p = Q.parts(w)
    ok(p.n == 3 and p.height.__class == "Spacer" and p.height.Size and p.height.Size.X == 0 and p.height.Size.Y == 44 and #p.inner.children == 2 and p.holder.__class == "HorizontalBox" and p.help.__class == "TextBlock" and p.label.__class == "TextBlock",
        "like row: native parts: label TextBlock, inner HorizontalBox [holder HorizontalBox, \"?\" TextBlock]")
    ok(p.label.text == "Enemy Damage" and p.help.text == "?", "like row: label and \"?\" texts")
    -- the look, copied from the live Difficulty row
    local bg = w.Background
    ok(bg.Brush == Q.BRUSH and bg.BrushColor == Q.TINT, "copied: the background Image's brush and tint onto the Border")
    ok(Q.sameSlot({ Padding = bg.Padding, HorizontalAlignment = bg.HA, VerticalAlignment = bg.VA }, Q.SLOTS.hbox), "copied: the game HorizontalBox's overlay slot onto the Border's padding and alignment")
    ok(p.label.Font == Q.LFONT and p.label.ColorAndOpacity == Q.LCOL and p.label.Justification == 0, "copied: the label's font, colour and justification")
    ok(p.help.Font == Q.QFONT and p.help.ColorAndOpacity == Q.QCOL and p.help.Justification == 1, "copied: the \"?\"'s font, colour and justification")
    ok(Q.sameSlot(p.label.Slot, Q.SLOTS.label) and Q.sameSlot(p.inner.Slot, Q.SLOTS.inner) and Q.sameSlot(p.holder.Slot, Q.SLOTS.control)
        and Q.sameSlot(p.help.Slot, Q.SLOTS.help), "copied: every inner slot (label, inner box, the control's to the holder, \"?\")")
    ok(Q.sameSlot(w.Slot, I.slotOf(2)), "copied: the row's own slot in the game box is the Difficulty row's")
    ok(w.mat == nil, "copied: no worn-strip material of core's own")
    -- the control where the game's picker sits, before the "?"
    local wrap = p.holder.children[1]
    ok(#p.holder.children == 1 and I.nameOf(wrap) == "nr.c" and p.inner.children[2] == p.help, "the control in the holder, before the \"?\"")
    ok(wrap.Slot.Size.SizeRule == 1 and wrap.HBox.children[1].Slot.Size.SizeRule == 1,
        "the control fills the holder and the game's picker fills its wrapper (as the game's control fills its slot)")
    -- the tooltip
    local tip = p.help.ToolTipWidget
    ok(tip ~= nil and tip.__class == "W_ToolTip3_C" and tip.Description and tip.Description.s == HELP3, "help: the \"?\"'s tooltip is a W_ToolTip3_C with the help as its Description")
    ok(select(2, tip.Description.s:gsub("\n", "")) == 2, "help: three lines kept as three lines")
    ok(p.help.vis == C.VIS.Visible and p.label.vis == C.VIS.SelfHitTestInvisible, "help: the \"?\" Visible (hover), the label not hit-testable")
    ok(X.stats().gameTips == tips0 + 3, "help: one tooltip widget per row with help per attach (three rows)", X.stats().gameTips - tips0)
    -- the game choice: shown from its first frame and after the rebuild's re-add
    local m = wrap.HBox.children[1]
    ok(m and m.__class == "MultipleSelectBox_C" and #m.Items == 6 and m.Items[3] == "Low", "game choice: the game's picker with the six options")
    ok(m.DefaultOption == "Low" and m.SelectedOption == "Low" and m:GetSelectedIndex() == 2, "game choice: shows option 3 (DefaultOption, selected)")
    ok(m.pre >= 1, "game choice: its PreConstruct ran again on the rebuild's re-add (the fake), and it still shows option 3", m.pre)
    ok(CH.isShown(gch) == true and RS.isShown(like1) == true, "isShown: the row and its game choice")
    -- the checkbox row
    local w2 = Q.ours(vb, "nr.r2")
    local p2 = Q.parts(w2)
    ok(I.nameOf(p2.holder.children[1]) == "nr.cb" and CK.isShown(cbx) == true, "a core checkbox as a like row's control: in its holder")
    ok(p2.label.text == "Damage Spread" and p2.help.ToolTipWidget.Description.s == "spread", "a language table: the en strings")
    -- the fallback
    local w3 = Q.ours(vb, "nr.r3")
    local p3 = Q.parts(w3)
    ok(p3.n == 3 and p3.label.text == "Not Like" and p3.help.text == "?", "like missing: label and \"?\" present")
    ok(w3.mat == Q.STRIP and w3.Background.Brush == nil, "like missing: core's worn strip (game look), nothing copied")
    ok(p3.label.Font and p3.label.Font.FontObject == Q.REGULAR and p3.label.Font.Size == 22 and p3.help.Font.FontObject == Q.REGULAR,
        "like missing: theme body font (Regular 22) on the label and the \"?\"")
    ok(p3.label.ColorAndOpacity.SpecifiedColor.R == theme.game.text.r, "like missing: the menu's text colour")
    ok(countLogs("WARN ui createServer: row 'nr.r3' is like 'Overlay_NOPE', which is not a game row on the open screen (no widget of that name is in the open screen); it is drawn in Nucleus's game look") == 1,
        "like missing: one WARN naming it")
    ok(X.stats().likeCopies >= 2 and X.stats().likeFallbacks >= 1, "stats: likeCopies, likeFallbacks")
    ok(hookCount("MultipleSelectBox_C:BndEvt__MultipleSelectBox_Button_K2Node") == 1 and hookCount("MultipleSelectBox_C:BndEvt__MultipleSelectBox_Button_60_K2Node") == 1,
        "game choice: one post-hook on each arrow handler, registered from the poll")

    -- a real arrow click: onChange once with the new index; the picker's DefaultOption follows
    m:click(1)
    ok(#LOG == 1 and LOG[1].i == 4 and LOG[1].o == "Medium" and LOG[1].h == gch and CH.get(gch) == 4, "next arrow: onChange once with the new index (4, Medium)")
    ok(m.DefaultOption == "Medium", "next arrow: DefaultOption follows (a later rebuild keeps it)")
    -- a repeat within 250 ms on the same arrow: one click; the picker goes back to the element's option
    m:click(1, false)
    ok(#LOG == 1 and m.SelectedOption == "Medium" and CH.stats().gameDebounced == 1, "a repeat within 250 ms: no callback, the picker put back")
    m:click(-1)
    ok(#LOG == 2 and LOG[2].i == 3 and CH.get(gch) == 3, "previous arrow: onChange once (3)")
    -- set: shown, no callback
    CH.set(gch, 6)
    ok(#LOG == 2 and m.SelectedOption == "Max" and m.DefaultOption == "Max" and CH.get(gch) == 6, "set: shown at once (selected and DefaultOption), no callback")
    -- the game's own picker and a stranger's: ignored
    local ig = CH.stats().gameIgnored
    fireHook("Button_K2Node_ComponentBoundEvent_0", s.pickers.Overlay_28)
    local stranger = Q.msb("/Engine/Transient.OtherMod_MSB")
    stranger:AddOption("A", {}); stranger:AddOption("B", {})
    stranger:click(1)
    ok(#LOG == 2 and CH.stats().gameIgnored == ig + 2, "the game's own picker and another state's: ignored")
    -- disabled: SetIsEnabled(false), dimmed; a click is put back
    CH.setEnabled(gch, false)
    ok(m.enabled == false and m.opacity == theme.disabledOpacity, "setEnabled false: the picker disabled and dimmed")
    m:click(-1)
    ok(#LOG == 2 and m.SelectedOption == "Max", "disabled: a click changes nothing, the picker put back")
    CH.setEnabled(gch, true)
    ok(m.enabled == true and m.opacity == 1, "setEnabled true")
    -- a throwing onChange: logged once, the dispatch counter back to 0, the choice keeps working
    CH.set(gch, 3)
    local good = C.els["nr.c"].onChange
    C.els["nr.c"].onChange = function() error("boom from the dependent") end
    local th0, n0 = CH.stats().gameThrows, #LOG
    m:click(1)
    m:click(-1)
    ok(CH.stats().gameThrows == th0 + 2 and C.inDispatch == 0, "a throwing onChange: both clicks counted as throws, inDispatch back to 0")
    ok(countLogs("WARN choice 'nr.c' onChange:") == 1, "a throwing onChange: exactly one WARN")
    C.els["nr.c"].onChange = good
    m:click(1)
    ok(#LOG == n0 + 1 and LOG[#LOG].i == 4, "after a throwing onChange: a later click with a good callback runs it")
    CH.set(gch, 3)
    -- core story 37: the game picker's onChange runs as inside a hook: a cold window class is not loaded there
    do
        for k, o in pairs(handles) do if o == SCREENCLASS then handles[k] = nil end end
        local inside, cls, g0
        C.els["nr.c"].onChange = function() inside = X._inHook() and C.inDispatch > 0; g0 = F.getAssets; cls = X._classOf("screen") end
        m:click(1)
        ok(inside and cls == nil and F.getAssets == g0, "story 37: the game picker's onChange runs as inside a hook (cache only, no load)")
        ok(C.inDispatch == 0 and not X._inHook(), "story 37: the flag is lowered after the game picker's onChange")
        C.els["nr.c"].onChange = good
        CH.set(gch, 3)
    end
    -- setLabel / setHelp while live
    local t1 = X.stats().gameTips
    RS.setLabel(like1, "Enemy Dmg")
    ok(p.label.text == "Enemy Dmg", "setLabel: applied at once")
    RS.setHelp(like1, "one line")
    ok(p.help.ToolTipWidget.Description.s == "one line" and X.stats().gameTips == t1 + 1, "setHelp: a new tooltip widget with the new Description")
    RS.setHelp(like1, nil)
    ok(p.help.vis == C.VIS.Hidden, "setHelp nil: the \"?\" hidden (no hover)")
    RS.setHelp(like1, HELP3)
    RS.setLabel(like1, "Enemy Damage")
    ok(p.help.vis == C.VIS.Visible and p.help.ToolTipWidget.Description.s == HELP3, "setHelp again: shown")
    -- a create with the same id while open: the new label, help and control at once
    local cb2 = CK.create{ id = "nr.cb2", onChange = function() end, place = { host = CSH, corner = "top-left" } }
    RS.create{ id = "nr.r2", like = "Overlay_28", label = "Spread Again", help = "new help", control = cb2, place = { host = CSH, container = VB, after = "Overlay_28" } }
    local p2b = Q.parts(Q.ours(vb, "nr.r2"))
    ok(p2b.label.text == "Spread Again" and p2b.help.ToolTipWidget.Description.s == "new help", "same-id create while open: label and help updated")
    ok(#p2b.holder.children == 2 and I.nameOf(p2b.holder.children[2]) == "nr.cb2" and C.els["nr.cb2"].panel == C.els["nr.r2"],
        "same-id create while open: the new control in the holder")
    CK.remove(cb2)
    RS.create{ id = "nr.r2", like = "Overlay_28", label = { en = "Damage Spread", de = "Streuung" }, help = { en = "spread", de = "Streuung hilfe" },
        place = { host = CSH, container = VB, after = "Overlay_28" } }
    -- a second pass on the open screen (no rebuild): the look copied again, no new widget
    local before = Q.constructs
    X._insertPass(CSH, s, nil, "test")
    ok(Q.constructs == before and Q.ours(vb, "nr.r1") == w and #Q.parts(w).inner.children == 2, "a second pass: the same widget and parts, nothing constructed")
    s:RemoveFromParent()
    tick()
    ok(C.els["nr.c"].msbRef == nil and C.els["nr.r1"].ref == nil, "Back: the row's and the picker's handles freed")
    -- a stale picker (the closed screen's): ignored
    local ig2, l2 = CH.stats().gameIgnored, #LOG
    m:click(1)
    ok(#LOG == l2 and CH.stats().gameIgnored == ig2 + 1, "a stale picker after Back: ignored", #LOG .. " " .. (CH.stats().gameIgnored - ig2))
end

-- ---------------------------------------------------------------- ten opens: one widget set each, the look re-copied
do
    local allOne, allLook, allSel, allNew, allTip, prev = true, true, true, true, true, {}
    local copies0 = X.stats().likeCopies
    for n = 1, 10 do
        local s = T.open(320 + n)
        local t0 = X.stats().gameTips
        tick()
        local vb = s.vb
        for _, id in ipairs({ "nr.r1", "nr.r2", "nr.r3" }) do
            if I.count(vb, id) ~= 1 then allOne = false end
            local w = Q.ours(vb, id)
            local p = w and Q.parts(w)
            if not p or p.n ~= 3 or #p.inner.children ~= 2 or #p.holder.children ~= (id == "nr.r3" and 0 or 1) then allOne = false end
            if w == prev[id] then allNew = false end
            prev[id] = w
        end
        local w = Q.ours(vb, "nr.r1")
        local p = Q.parts(w)
        if not (w.Background.Brush == Q.BRUSH and p.label.Font == Q.LFONT and Q.sameSlot(w.Slot, I.slotOf(2))) then allLook = false end
        local m = p.holder.children[1].HBox.children[1]
        if not (m.SelectedOption == "Low" and m.DefaultOption == "Low") then allSel = false; print("sel " .. n .. ": " .. tostring(m.SelectedOption)) end
        if X.stats().gameTips ~= t0 + 3 then allTip = false end
        local g = I.gameOk(vb)
        if not g then allOne = false end
        tick(); tick()
        s:RemoveFromParent()
        tick()
    end
    ok(allOne, "ten opens: every row present once, one set of parts each, its control in its holder")
    ok(allNew, "ten opens: a new widget every open")
    ok(allLook, "ten opens: the look re-copied every open")
    ok(allSel, "ten opens: the game choice shows its option every open")
    ok(allTip, "ten opens: one tooltip widget per row with help per open")
    ok(X.stats().likeCopies == copies0 + 20, "ten opens: two copies per open (the fallback row copies nothing)", X.stats().likeCopies - copies0)
    ok(countLogs("is like 'Overlay_NOPE'") == 1, "ten opens: still one WARN for Overlay_NOPE")
    ok(hookCount("MultipleSelectBox_C:BndEvt__MultipleSelectBox_Button_K2Node") == 1, "ten opens: the arrow hooks registered once")
end

-- ---------------------------------------------------------------- the arrow hooks: a class reload, a half-failed registration
do
    local NEXT = "MultipleSelectBox_C:BndEvt__MultipleSelectBox_Button_K2Node"
    local PREV = "MultipleSelectBox_C:BndEvt__MultipleSelectBox_Button_60_K2Node"
    local n0, p0 = hookCount(NEXT), hookCount(PREV)
    obj({}, C.MSB_NEXT_FN) -- the class loaded anew: the handler at a new address
    local s = T.open(335)
    tick()
    ok(hookCount(NEXT) == n0 + 1 and hookCount(PREV) == p0 + 1 and CH.stats().gameHooked == true, "class reload: one new registration per arrow")
    local m = Q.parts(Q.ours(s.vb, "nr.r1")).holder.children[1].HBox.children[1]
    local c0 = #LOG
    m:click(1)
    ok(#LOG == c0 + 1, "class reload: a click still calls onChange once", #LOG - c0)
    CH.set(gch, 3)
    s:RemoveFromParent(); tick()
    -- a half-failed registration: one WARN, never retried, gameHooked false
    obj({}, C.MSB_NEXT_FN)
    local real, tries = RegisterHook, 0
    RegisterHook = function(path, f)
        tries = tries + 1
        if path == C.MSB_PREV_FN then error("hook refused (test)") end
        return real(path, f)
    end
    local s2 = T.open(336)
    tick(); tick()
    ok(countLogs("WARN game choice arrows: RegisterHook failed:") == 1 and countLogs("hook refused (test)") == 1 and CH.stats().gameHooked == false, "a half-failed registration: one WARN, gameHooked false", countLogs("RegisterHook failed") .. " " .. tostring(CH.stats().gameHooked))
    local t1 = tries
    s2:RemoveFromParent(); tick()
    local s3 = T.open(337)
    tick(); tick()
    ok(tries == t1 and t1 == 2, "a half-failed registration: not tried again on later ticks and opens", tries)
    s3:RemoveFromParent(); tick()
    RegisterHook = real
end

-- ---------------------------------------------------------------- the language re-picked at the next attach; a like that isn't a game row
do
    F.lang = "de"
    local s = T.open(340)
    tick()
    local p = Q.parts(Q.ours(s.vb, "nr.r2"))
    ok(p.label.text == "Streuung" and p.help.ToolTipWidget.Description.s == "Streuung hilfe", "language: label and help re-picked (de) at the attach")
    s:RemoveFromParent(); tick()
    F.lang = "en"
    local nr = RS.create{ id = "nr.r4", like = "Overlay_29", label = "Plain Overlay", place = { host = CSH, container = VB, at = "end" } }
    local s2 = T.open(341)
    tick()
    ok(countLogs("WARN ui createServer: row 'nr.r4' is like 'Overlay_29', which is not a game row on the open screen (it is a Overlay") == 0
        and countLogs("row 'nr.r4' is like 'Overlay_29', which is not a game row on the open screen (it holds no Image and HorizontalBox)") == 1,
        "a like widget that isn't a game row: one WARN saying why")
    local w4 = Q.ours(s2.vb, "nr.r4")
    ok(w4 and w4.mat == Q.STRIP and Q.parts(w4).label.text == "Plain Overlay", "a like widget that isn't a game row: core's game look")
    -- a canvas-placed like row: drawn on the screen's canvas, look copied (no row slot to copy)
    local cr = RS.create{ id = "nr.r5", like = "Overlay_28", label = "On Canvas", place = { host = CSH, corner = "top-left" } }
    ok(T.inCanvas(s2, "nr.r5") ~= nil and T.inCanvas(s2, "nr.r5").Background.Brush == Q.BRUSH, "a like row on the screen's canvas: attached at once, look copied")
    RS.remove(cr); RS.remove(nr)
    s2:RemoveFromParent(); tick()
end

-- ---------------------------------------------------------------- a game choice's options changed (same id): a new picker
do
    CH.create{ id = "nr.c", widget = "game", options = { "One", "Two" }, selected = 2, onChange = function() end }
    P.place(gch, { row = like1 })
    local s = T.open(350)
    tick()
    local m = Q.parts(Q.ours(s.vb, "nr.r1")).holder.children[1].HBox.children[1]
    ok(m and #m.Items == 2 and m.SelectedOption == "Two", "same id, new options: the picker shows the new ones")
    s:RemoveFromParent(); tick()
end

-- ---------------------------------------------------------------- off the game thread
do
    local saved = _G.Nucleus_Deref
    _G.Nucleus_Deref = function() error("Nucleus_Deref refused: called off the game thread") end
    for _, d in ipairs({ { "row.setLabel", function() RS.setLabel(like1, "X") end }, { "row.setHelp", function() RS.setHelp(like1, "X") end },
        { "row.create", function() RS.create{ id = "ot", like = "Overlay_28", place = { host = CSH, container = VB, after = "Overlay_28" } } end },
        { "choice.create", function() CH.create{ id = "ot", widget = "game", options = OPTS, onChange = function() end } end } }) do
        raises(d[2], "nucleus.ui." .. d[1] .. " called off the game thread", "off thread: " .. d[1])
    end
    _G.Nucleus_Deref = saved
end

-- ---------------------------------------------------------------- features
local FE = require("nucleus.features")
for _, n in ipairs({ "ui.row.like", "ui.row.setLabel", "ui.row.setHelp", "ui.choice.game" }) do
    ok(FE.set(FE.declared())[n] == true, "features: " .. n)
end
ok(countLogs("ERROR") == 0, "no ERROR line")
do
    local warns = {}
    -- (the fake clock adds 1 ms per reading, so a soft "hud slow tick" line is the fake's, not core's)
    for _, l in ipairs(logs) do if l:find("^WARN") and not l:find("^WARN hud slow tick") then warns[#warns + 1] = l end end
    ok(#warns == 5, "exactly five WARNs in the run: the tooltip class missing, Overlay_NOPE, the throwing onChange, the half-failed hook, Overlay_29 (each once)", table.concat(warns, " | "))
end

print(string.format("likerow_test: %d passed, %d failed", pass, failN))
