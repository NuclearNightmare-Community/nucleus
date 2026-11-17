-- Unit tests for core story 32 (UI-14, core 0.14.0): elements inserted into a game container at a position, outside the
-- game. The fake engine is game_test.lua's (core's widgets, the create-server screen built new on every open), with the
-- screen's settings list: CanvasPanel_21 > Overlay_0 > ScrollBox_54 > VerticalBox_202 holding 26 game rows, each with
-- its own slot values. This checks core's own logic: P.insertOrder (the positions), the intent's validation, and the
-- insert pass (one rebuild for two anchors, slot values kept, none when already ordered, ten opens without duplicates,
-- one WARN per unknown anchor or container, place and remove; review loop 1: the rows' pickers keep their value across
-- the rebuild, a create / place while open is queued to the next tick (one pass for several), a ScrollBox container,
-- a checkbox and a button in the container, the refusals with near / absolute / list / row); the in-game proof is
-- run.ps1 -Scenario gameinsert.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/insert_test.lua  (here: MiKTeX's texlua)
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.14.0", floor = "0.1.0" } end
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

-- ---- P.insertOrder (pure): the matrix's position rows
do
    local function ord(game, items)
        local o, m, pe = P.insertOrder(game, items)
        local t = {}
        for _, e in ipairs(o) do t[#t + 1] = e.game and game[e.game] or ("#" .. e.item) end
        return table.concat(t, ","), table.concat(m, ","), table.concat(pe, ",")
    end
    local g = { "A", "B", "C" }
    ok(ord(g, { { after = "A" }, { after = "A" } }) == "A,#1,#2,B,C", "insertOrder: after A, two items in creation order")
    ok(ord(g, { { before = "B" } }) == "A,#1,B,C", "insertOrder: before B")
    ok(ord(g, { { index = 1 } }) == "#1,A,B,C", "insertOrder: index 1 is before the first game child")
    ok(ord(g, { { index = 3 } }) == "A,B,#1,C", "insertOrder: index 3 is before the third")
    ok(ord(g, { { at = "end" } }) == "A,B,C,#1", "insertOrder: at end")
    local o, m = ord(g, { { after = "NOPE" }, { at = "end" } })
    ok(o == "A,B,C,#1,#2" and m == "1", "insertOrder: a missing anchor goes to the end (creation order there), reported", o .. " / " .. m)
    local o2, m2 = ord(g, { { before = "NOPE" } })
    ok(o2 == "A,B,C,#1" and m2 == "1", "insertOrder: a missing before anchor too")
    local o3, _, pe = ord(g, { { index = 4 }, { index = 200 } })
    ok(o3 == "A,B,C,#1,#2" and pe == "1,2", "insertOrder: an index past the end goes to the end, reported", o3 .. " / " .. pe)
    ok(ord(g, { { before = "B" }, { after = "A" }, { index = 2 } }) == "A,#1,#2,#3,B,C", "insertOrder: one gap, three ways, creation order")
    ok(ord(g, { { after = "C" }, { at = "end" } }) == "A,B,C,#1,#2", "insertOrder: after the last and at end share the end")
    ok(ord({}, { { index = 1 }, { at = "end" } }) == "#1,#2", "insertOrder: an empty container")
    ok(ord(g, {}) == "A,B,C", "insertOrder: no items, the game's order")
end

-- ---- validation: one clean nucleus.ui.place error, nothing created
do
    local function bad(intent, text, name)
        raises(function() X.create{ id = "badins", place = intent } end, PL .. text, "validate: " .. name)
    end
    local L65 = string.rep("a", 65)
    bad({ host = CSH, container = 5, after = "Overlay_28" }, "container must be a game widget's name (a string), got 5", "a number container")
    bad({ host = CSH, container = "", after = "Overlay_28" }, "container must not be empty", "an empty container")
    bad({ host = CSH, container = L65, after = "Overlay_28" }, "container is 65 characters, at most 64", "a 65-character container")
    bad({ host = CSH, container = "Vertical Box", after = "Overlay_28" }, "container 'Vertical Box' is not a widget name", "a container with a space")
    bad({ host = CSH, container = "1Box", after = "Overlay_28" }, "container '1Box' is not a widget name", "a container starting with a digit")
    bad({ host = CSH, container = "A.B", after = "Overlay_28" }, "container 'A.B' is not a widget name", "a path, not a name")
    bad({ host = CSH, container = VB, after = 28 }, "after must be a game widget's name (a string), got 28", "a number anchor")
    bad({ host = CSH, container = VB, after = "" }, "after must not be empty", "an empty anchor")
    bad({ host = CSH, container = VB, before = L65 }, "before is 65 characters, at most 64", "a 65-character anchor")
    bad({ host = CSH, container = VB, before = "a-b" }, "before 'a-b' is not a widget name", "a non-identifier anchor")
    bad({ host = CSH, container = VB, after = "A", index = 2 }, "container needs exactly one of after, before, index or at (got after and index)", "after and index")
    bad({ host = CSH, container = VB, after = "A", before = "B" }, "container needs exactly one of after, before, index or at (got after and before)", "after and before")
    bad({ host = CSH, container = VB, index = 1, at = "end" }, "container needs exactly one of after, before, index or at (got index and at)", "index and at")
    bad({ host = CSH, container = VB }, "container needs exactly one of after, before, index or at (got none)", "no position")
    bad({ host = CSH, container = VB, index = 0 }, "index 0 is out of range (1 to 256)", "index 0")
    bad({ host = CSH, container = VB, index = 257 }, "index 257 is out of range (1 to 256)", "index 257")
    bad({ host = CSH, container = VB, index = -1 }, "index -1 is out of range (1 to 256)", "index -1")
    bad({ host = CSH, container = VB, index = 1.5 }, "index must be a whole number from 1 to 256, got 1.5", "index 1.5")
    bad({ host = CSH, container = VB, index = 0 / 0 }, "index must be a whole number from 1 to 256, got NaN", "index NaN")
    bad({ host = CSH, container = VB, index = math.huge }, "index must be a whole number from 1 to 256, got inf", "index inf")
    bad({ host = CSH, container = VB, index = "1" }, "index must be a whole number from 1 to 256, got '1'", "index a string")
    bad({ host = CSH, container = VB, at = "start" }, "unknown at 'start' (valid: end)", "at start")
    bad({ host = CSH, container = VB, at = 1 }, "unknown at 1 (valid: end)", "at a number")
    bad({ host = CSH, container = VB, after = "A", corner = "top-left" }, "corner is not allowed with container (valid keys: after, at, before, container, host, index)", "container with corner")
    bad({ host = CSH, container = VB, after = "A", gap = "tight" }, "gap is not allowed with container (valid keys: after, at, before, container, host, index)", "container with gap")
    bad({ host = CSH, container = VB, after = "A", offset = { x = 1 } }, "offset is not allowed with container", "container with offset")
    bad({ container = VB, after = "A" }, "container is not available on host 'hud' (game screens only: createServer)", "container on the default host")
    bad({ host = "hud", container = VB, after = "A" }, "container is not available on host 'hud' (game screens only: createServer)", "container on hud")
    bad({ host = "menu", container = VB, after = "A" }, "container is not available on host 'menu' (game screens only: createServer)", "container on menu")
    bad({ host = "journal", container = VB, after = "A" }, "container is not available on host 'journal' (game screens only: createServer)", "container on journal")
    bad({ host = "screen", container = VB, after = "A" }, "container is not available on host 'screen' (game screens only: createServer)", "container on screen")
    bad({ host = "moon", container = VB, after = "A" }, "unknown host 'moon' (valid: createServer, hud, journal, menu, screen)", "container on an unknown host")
    bad({ host = CSH, container = VB, after = "A", foo = 1 }, "unknown key 'foo' in an intent (valid keys: absolute, after, align, at, before, container, corner, fill, gap, host, index, inset, list, near, offset, panel, region, row, screen, side)", "an unknown key")
    bad({ host = CSH, after = "Overlay_28" }, "after needs container = <game widget name>", "after without container")
    bad({ host = CSH, index = 1 }, "index needs container = <game widget name>", "index without container")
    bad({ host = CSH, corner = "top-left", at = "end" }, "at needs container = <game widget name>", "at with a corner, no container")
    bad({ host = CSH, after = "A", before = "B" }, "after and before need container = <game widget name>", "two positions, no container")
    ok(C.els.badins == nil, "validate: the refused calls created nothing")
    -- inside a core container: refused by the container rules (core's containers keep { panel | list | row = handle })
    local PN = require("nucleus.ui.panel")
    local pnl = PN.create{ id = "inspanel", place = { host = CSH, corner = "top-left" } }
    raises(function() X.create{ id = "badins", place = { panel = pnl, container = VB } } end, PL .. "container is not allowed with panel", "validate: container inside a core panel")
    PN.remove(pnl)
    -- the normalized intent
    local n = P.validate({ host = CSH, container = VB, index = 3.0 })
    ok(n.host == CSH and n.container == VB and math.type(n.index) == "integer" and n.index == 3 and n.corner == nil, "validate: normalized { host, container, index } (3.0 -> 3)")
    ok(P.validate({ host = CSH, container = "ScrollBox_54", at = "end" }).at == "end", "validate: at end")
end

-- ---- the engine: five after Overlay_28, fourteen after Overlay_738, made before the first open
-- (story 31's corner elements are game_test.lua's; this file starts with none)
local K, EN = {}, {}
for i = 1, 5 do K[i] = X.create{ id = "k" .. i, text = "KNOB " .. i, place = { host = CSH, container = VB, after = "Overlay_28" } } end
for i = 1, 14 do EN[i] = X.create{ id = "e" .. i, text = "ENEMY " .. i, place = { host = CSH, container = VB, after = "Overlay_738" } } end
ok(X.isShown(K[1]) == false and C.els.k1.ref == nil, "before an open: pending, no widget")
function I.wantOrder(extra)
    local t = { "Overlay_10", "Overlay_28" }
    for i = 1, 5 do t[#t + 1] = "k" .. i end
    for i = 3, 16 do t[#t + 1] = I.ROWS[i] end
    for i = 1, 14 do t[#t + 1] = "e" .. i end
    for i = 17, 26 do t[#t + 1] = I.ROWS[i] end
    for _, e in ipairs(extra or {}) do t[#t + 1] = e end
    return table.concat(t, ",")
end
local r0 = I.rebuilds()
local s1 = T.open(101)
tick()
ok(I.list(s1.vb) == I.wantOrder(), "open: knobs at 2-6, enemies right after Overlay_738, creation order", I.list(s1.vb))
ok(I.indexOf(s1.vb, "k1") == 2 and I.indexOf(s1.vb, "k5") == 6, "open: the knobs are children 2-6 (0-based)")
ok(I.indexOf(s1.vb, "e1") == I.indexOf(s1.vb, "Overlay_738") + 1, "open: e1 right after Overlay_738")
local okG, whyG = I.gameOk(s1.vb)
ok(okG, "open: every game row keeps its order and slot values", whyG)
ok(I.rebuilds() == r0 + 1, "open: two anchors, one rebuild", I.rebuilds() - r0)
ok(I.removes == 24, "open: the rebuild starts at the first child out of order (header and Difficulty untouched)", I.removes)
ok(X.isShown(K[1]) == true and X.isShown(EN[14]) == true, "open: isShown true")
do
    local all1 = true
    for i = 1, 5 do if I.count(s1.vb, "k" .. i) ~= 1 then all1 = false end end
    for i = 1, 14 do if I.count(s1.vb, "e" .. i) ~= 1 then all1 = false end end
    ok(all1, "open: one widget per element")
end
ok(#s1.canvas.children == 2, "open: nothing of ours in the root canvas", #s1.canvas.children)
-- later ticks and a second pass: nothing changes, no rebuild (already ordered)
tick(); tick()
local r1 = I.rebuilds()
ok(I.list(s1.vb) == I.wantOrder() and r1 == r0 + 1, "later ticks: no change, no rebuild")
I.removes = 0
X._insertPass(CSH, s1, nil, "test")
ok(I.rebuilds() == r1 and I.removes == 0 and I.list(s1.vb) == I.wantOrder(), "a second pass on an ordered box: no rebuild, nothing removed")

-- made while open: an unknown anchor (end, one WARN), an unknown container (not attached, one WARN), a widget that isn't a box
-- (each queued to the host's next poll tick)
local xa = X.create{ id = "xa", text = "NOPE ANCHOR", place = { host = CSH, container = VB, after = "Overlay_NOPE" } }
ok(I.list(s1.vb) == I.wantOrder() and X.isShown(xa) == false and C.els.xa.ref == nil, "made while open: nothing in the dependent's call (queued)")
tick()
ok(I.list(s1.vb) == I.wantOrder({ "xa" }) and X.isShown(xa) == true, "unknown anchor: at the end of the container on the next tick", I.list(s1.vb))
ok(I.rebuilds() == r1, "unknown anchor while open: appended, no rebuild")
ok(countLogs("WARN ui createServer: anchor 'Overlay_NOPE' is not a child of 'VerticalBox_202'") == 1, "unknown anchor: one WARN naming it")
local xc = X.create{ id = "xc", text = "NOPE BOX", place = { host = CSH, container = "VerticalBox_NOPE", after = "Overlay_28" } }
tick()
ok(X.isShown(xc) == false and C.els.xc.ref == nil and C.els.xc.attached == false, "unknown container: not attached, isShown false")
ok(countLogs("WARN ui createServer: container 'VerticalBox_NOPE' is missing") == 1 and countLogs("'xc'") >= 1, "unknown container: one WARN naming it and the element")
local xi = X.create{ id = "xi", text = "NOT A BOX", place = { host = CSH, container = "Image_5", at = "end" } }
tick()
ok(X.isShown(xi) == false and countLogs("WARN ui createServer: 'Image_5' is a Image, not a VerticalBox, HorizontalBox or ScrollBox; 'xi' stay(s) pending") == 1,
    "a container that is not a box: one WARN saying what it is (not 'missing')")
ok(countLogs("container 'Image_5' is missing") == 0, "a container that is not a box: not called missing")
-- a HorizontalBox works too
local hx = X.create{ id = "hx", text = "IN HB", place = { host = CSH, container = "HorizontalBox_9", at = "end" } }
tick()
ok(I.list(s1.hb) == "hx" and X.isShown(hx) == true, "a HorizontalBox container: attached", I.list(s1.hb))

-- Back: closed; handles freed
s1:RemoveFromParent()
tick()
ok(C.els.k1.ref == nil and C.els.e1.ref == nil and C.els.xa.ref == nil and X.isShown(K[1]) == false, "Back: handles freed, isShown false")

-- ---- ten opens: the same order and slot values, one rebuild each, one new widget per element, no duplicates
do
    local prev, allNew, allOrder, allSlots, allOne, allRebuild = {}, true, true, true, true, true
    for n = 1, 10 do
        local s = T.open(110 + n)
        local rb = I.rebuilds()
        tick()
        if I.list(s.vb) ~= I.wantOrder({ "xa" }) then allOrder = false; print("order " .. n .. ": " .. I.list(s.vb)) end
        local g, why = I.gameOk(s.vb)
        if not g then allSlots = false; print("slots " .. n .. ": " .. tostring(why)) end
        if I.rebuilds() ~= rb + 1 then allRebuild = false end
        for _, id in ipairs({ "k1", "k3", "e7", "e14", "xa" }) do
            if I.count(s.vb, id) ~= 1 then allOne = false end
            local w = C.els[id].ref and handles[C.els[id].ref]
            if not w or w == prev[id] then allNew = false end
            prev[id] = w
        end
        tick(); tick()
        if I.list(s.vb) ~= I.wantOrder({ "xa" }) then allOrder = false end
        s:RemoveFromParent()
        tick()
    end
    ok(allOrder, "ten opens: the same order every time")
    ok(allSlots, "ten opens: every game row's order and slot values unchanged")
    ok(allRebuild, "ten opens: exactly one rebuild per open")
    ok(allOne and allNew, "ten opens: one widget per element, a new one every open")
    ok(countLogs("anchor 'Overlay_NOPE'") == 1 and countLogs("container 'VerticalBox_NOPE'") == 1, "ten opens: still one WARN each for the whole run")
    ok(X.isShown(xc) == false, "ten opens: the unknown container's element never attached")
end
X.remove(xc); X.remove(xi); X.remove(hx)

-- ---- index, before and at end; a past-end index; another mod's widget; place and remove
do
    local ib = X.create{ id = "ib", text = "FIRST", place = { host = CSH, container = VB, index = 1 } }
    local bb = X.create{ id = "bb", text = "BEFORE LOBBY", place = { host = CSH, container = VB, before = "Overlay_27" } }
    local ae = X.create{ id = "ae", text = "LAST", place = { host = CSH, container = VB, at = "end" } }
    local pe = X.create{ id = "pe", text = "PAST", place = { host = CSH, container = VB, index = 200 } }
    local s = T.open(130)
    -- another mod's core widget after Overlay_29, before the poll
    local other = newText()
    other.tip = "nucleus:OtherMod:z"
    local vb = s.vb
    other.parent = vb
    other.Slot = boxSlot()
    other.Slot.Padding = { Left = 9, Top = 9, Right = 9, Bottom = 9 }
    table.insert(vb.children, I.POS.Overlay_29 + 1, other)
    tick()
    local names = I.names(vb)
    ok(names[1] == "ib" and names[2] == "Overlay_10", "index 1: before game child 1", I.list(vb))
    ok(I.indexOf(vb, "bb") == I.indexOf(vb, "k5") + 1 and I.indexOf(vb, "Overlay_27") == I.indexOf(vb, "bb") + 1,
        "before Overlay_27: right before it (after the knobs placed after Overlay_28: same gap, creation order)", I.list(vb))
    ok(names[#names] == "pe" and names[#names - 1] == "ae" and names[#names - 2] == "xa", "at end and the past-end index: last, in creation order", I.list(vb))
    ok(countLogs("WARN ui createServer: index 200 is past the end of 'VerticalBox_202' (26 game children)") == 1, "past-end index: one WARN")
    ok(I.indexOf(vb, "nucleus:OtherMod:z") == I.indexOf(vb, "Overlay_29") + 1, "another mod's widget: still right after the game row it followed", I.list(vb))
    ok(other.Slot.Padding.Left == 9, "another mod's widget: its slot values kept")
    local g, why = I.gameOk(vb)
    ok(g, "index/before/end: every game row's order and slot values unchanged", why)
    -- place: before Overlay_10 (index 1's gap: k1 is older than ib, so first)
    local rb = I.rebuilds()
    P.place(K[1], { host = CSH, container = VB, before = "Overlay_10" })
    ok(I.count(vb, "k1") == 0 and I.rebuilds() == rb, "place into a container while open: taken out now, put back on the next tick (no rebuild in the call)")
    tick()
    names = I.names(vb)
    ok(names[1] == "k1" and names[2] == "ib" and I.count(vb, "k1") == 1, "place: k1 moves before Overlay_10 (creation order before ib)", I.list(vb))
    ok(I.rebuilds() == rb + 1, "place: one rebuild")
    P.place(K[1], { host = CSH, container = VB, before = "Overlay_10" })
    tick()
    ok(I.rebuilds() == rb + 1 and I.names(vb)[1] == "k1", "place: the same intent changes nothing")
    P.place(K[1], { host = CSH, corner = "top-left" })
    ok(I.count(vb, "k1") == 0 and T.inCanvas(s, "k1") ~= nil and X.isShown(K[1]) == true, "place: out of the container into a corner")
    P.place(K[1], { host = CSH, container = VB, after = "Overlay_28" })
    tick()
    ok(T.inCanvas(s, "k1") == nil and I.indexOf(vb, "k1") == I.indexOf(vb, "Overlay_28") + 1 and I.indexOf(vb, "k2") == I.indexOf(vb, "k1") + 1,
        "place: back after Overlay_28, first of the knobs again (creation order)", I.list(vb))
    g, why = I.gameOk(vb)
    ok(g, "place: game rows unchanged", why)
    -- setVisible and remove
    X.setVisible(K[2], false)
    ok(handles[C.els.k2.ref].vis == C.VIS.Collapsed and X.isShown(K[2]) == false, "setVisible false: collapsed in the box")
    X.setVisible(K[2], true)
    ok(X.isShown(K[2]) == true, "setVisible true: shown")
    X.remove(ib)
    ok(I.count(vb, "ib") == 0 and I.names(vb)[1] == "Overlay_10", "remove: the widget leaves the box", I.list(vb))
    X.remove(bb); X.remove(ae); X.remove(pe)
    s:RemoveFromParent()
    tick()
end

-- ---- a fresh open after the moves: the knobs back in their place
do
    local s = T.open(140)
    tick()
    ok(I.indexOf(s.vb, "k1") == 2, "a fresh open after the moves: knobs back at 2-6", I.list(s.vb))
    s:RemoveFromParent()
    tick()
end

-- ---- review loop 1: the rows' pickers keep their value across the rebuild (Design Note 7)
do
    local s = T.open(150)
    -- CreateServer's Construct sets the pickers from the GameInstance (SetSelectedOption, before core's opened)
    s.pickers.Overlay_27:SetSelectedOption(3)
    s.pickers.Overlay_28:SetSelectedOption(2)
    local pre27, pre28 = s.pickers.Overlay_27.pre, s.pickers.Overlay_28.pre
    tick()
    ok(I.list(s.vb) == I.wantOrder({ "xa" }), "pickers: the list in its order", I.list(s.vb))
    ok(s.pickers.Overlay_27.pre == pre27 + 1, "pickers: Lobby Time's row was re-added (its PreConstruct ran again)")
    ok(s.pickers.Overlay_27.sel == 3, "pickers: a rebuilt row's picker keeps its value (Lobby Time 3, not its default 0)", s.pickers.Overlay_27.sel)
    ok(s.pickers.Overlay_28.pre == pre28 and s.pickers.Overlay_28.sel == 2, "pickers: Difficulty (before the first change) is not rebuilt and keeps its value")
    -- the player changes Lobby Time, then a dependent makes two elements while open: one pass on the next tick
    s.pickers.Overlay_27:SetSelectedOption(5)
    local rb, sets = I.rebuilds(), s.pickers.Overlay_27.sets
    local n1 = X.create{ id = "n1", text = "NEW 1", place = { host = CSH, container = VB, after = "Overlay_28" } }
    local n2 = X.create{ id = "n2", text = "NEW 2", place = { host = CSH, container = VB, after = "Overlay_28" } }
    local n3 = X.create{ id = "n3", text = "NEW 3", place = { host = CSH, container = VB, after = "Overlay_28" } }
    ok(I.rebuilds() == rb and I.count(s.vb, "n1") == 0 and X.isShown(n1) == false, "three creates while open: no rebuild, nothing attached until the tick")
    tick()
    ok(I.rebuilds() == rb + 1, "three creates while open: one rebuild on the next tick", I.rebuilds() - rb)
    ok(I.indexOf(s.vb, "n1") == I.indexOf(s.vb, "k5") + 1 and I.indexOf(s.vb, "n3") == I.indexOf(s.vb, "n1") + 2 and X.isShown(n3) == true,
        "three creates while open: in place after the knobs, creation order", I.list(s.vb))
    ok(s.pickers.Overlay_27.sel == 5 and s.pickers.Overlay_27.sets == sets + 1, "three creates while open: Lobby Time still shows the player's value (put back once)")
    ok(X.stats().pickerRestores >= 1, "stats: pickerRestores counts the restores")
    local g, why = I.gameOk(s.vb)
    ok(g, "three creates while open: game rows' order and slot values kept", why)
    tick(); tick()
    ok(I.rebuilds() == rb + 1, "three creates while open: no further pass on later ticks")
    X.remove(n1); X.remove(n2); X.remove(n3)
    s:RemoveFromParent()
    tick()
end
-- the same without the restore: the picker would show its default (the check above fails without restorePickers)
do
    local s = T.open(151)
    s.pickers.Overlay_27:SetSelectedOption(3)
    local box = s.vb
    local row
    for _, c in ipairs(box.children) do if I.nameOf(c) == "Overlay_27" then row = c end end
    box:RemoveChild(row); box:AddChild(row)
    ok(s.pickers.Overlay_27.sel == 0, "pickers (the fake): a plain re-add resets the picker to its default")
    s:RemoveFromParent()
    tick()
end

-- ---- review loop 1: a ScrollBox container (position and slot values)
do
    local sx = X.create{ id = "sx", text = "IN SCROLL", place = { host = CSH, container = "ScrollBox_54", index = 1 } }
    local s = T.open(160)
    tick()
    local sb = s.vb.parent
    ok(I.list(sb) == "sx,VerticalBox_202", "ScrollBox: index 1 before its game child", I.list(sb))
    local vs = s.vb.Slot
    ok(vs.Padding.Left == 7 and vs.Padding.Top == 8 and vs.Padding.Right == 9 and vs.Padding.Bottom == 10 and vs.HorizontalAlignment == 2
        and vs.VerticalAlignment == 3 and vs.Size.SizeRule == 1 and vs.Size.Value == 0.5, "ScrollBox: the re-added game child keeps its slot values")
    ok(X.isShown(sx) == true, "ScrollBox: isShown true")
    ok(I.list(s.vb) == I.wantOrder({ "xa" }), "ScrollBox: the list inside it still in order", I.list(s.vb))
    X.remove(sx)
    s:RemoveFromParent()
    tick()
end

-- ---- review loop 1: a checkbox and a button in the container (attached, shown, the checkbox takes a click)
do
    T.log = {}
    local cb = CK.create{ id = "icb", place = { host = CSH, container = VB, at = "end" }, onChange = function(h, v) T.log[#T.log + 1] = { h = h, v = v } end }
    local bt = T.BN.create{ id = "ibt", label = "GO", place = { host = CSH, container = VB, after = "Overlay_33" }, onClick = function() T.log[#T.log + 1] = "click" end }
    local s = T.open(170)
    tick()
    local names = I.names(s.vb)
    ok(names[#names] == "icb" and I.indexOf(s.vb, "ibt") == I.indexOf(s.vb, "Overlay_33") + 1, "checkbox at end and button after Overlay_33: in place", I.list(s.vb))
    ok(CK.isShown(cb) == true and T.BN.isShown(bt) == true, "checkbox and button: isShown true")
    local cw
    for _, c in ipairs(s.vb.children) do if I.nameOf(c) == "icb" then cw = c end end
    T.fire(T.CLICK, cw)
    ok(CK.get(cb) == true and #T.log == 1 and T.log[1].v == true, "checkbox in the container: a click runs onChange once")
    CK.remove(cb); T.BN.remove(bt)
    s:RemoveFromParent()
    tick()
end

-- ---- review loop 1: refusals of container with near, absolute, offset, list and row
do
    local function bad(intent, text, name)
        raises(function() X.create{ id = "badins2", place = intent } end, PL .. text, "validate: " .. name)
    end
    bad({ host = CSH, container = VB, after = "A", near = "crosshair" }, "near is not allowed with container", "container with near")
    bad({ host = CSH, container = VB, after = "A", absolute = { anchor = "center", x = 0, y = 0 } }, "absolute is not allowed with container", "container with absolute")
    bad({ host = CSH, container = VB, after = "A", offset = { x = 1, y = 1 } }, "offset is not allowed with container", "container with offset")
    local lh = LS.create{ id = "inslist", place = { host = CSH, corner = "top-left" }, size = { w = 400, h = 300 } }
    raises(function() X.create{ id = "badins2", place = { list = lh, container = VB } } end, PL .. "container is not allowed with list", "validate: container inside a core list")
    local rh = RS.create{ id = "insrow", place = { list = lh } }
    raises(function() X.create{ id = "badins2", place = { row = rh, container = VB } } end, PL .. "container is not allowed with row", "validate: container inside a core row")
    RS.remove(rh); LS.remove(lh)
    ok(C.els.badins2 == nil, "validate: the refused calls created nothing")
end

-- ---- stats and features
ok(type(X.stats().containerRebuilds) == "number", "stats: containerRebuilds")
local FE = require("nucleus.features")
ok(FE.set(FE.declared())["ui.place.container"] == true, "features: ui.place.container")

print(string.format("insert_test: %d passed, %d failed", pass, failN))
if failN > 0 then os.exit(1) end
