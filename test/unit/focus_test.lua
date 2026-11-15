-- Unit tests for core story 27 (core 0.12.0, UI-12): a window's card (the hug rule at 1280x720, 1920x1080 and
-- 3440x1440, the clamp), BACK, the "compact" gap, and keyboard and gamepad focus (lines, Up/Down/Left/Right, a choice's
-- and a slider's adjust, Accept, Back, removal and return, the UI tick, hook noise), outside the game. The fake engine
-- is controls_test.lua's (a live title-screen menu with a window over it, core's controls), plus keyboard focus, the
-- card's parts and the window's key variables. The in-game proof is run.ps1 -Scenario menu (the kb-* cases, KFOCUS).
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/focus_test.lua  (here: MiKTeX's texlua)
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.12.0", floor = "0.1.0" } end
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


-- ---------------------------------------------------------------- story 4: the controls' widgets, the template, the modules
local CK = require("nucleus.ui.checkbox")
local CH = require("nucleus.ui.choice")
local SL = require("nucleus.ui.slider")
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
function T.fire(sub, w) clock = clock + 300000; fireHook(sub, w) end
T.CLICK, T.PREV, T.NEXT = "WBP_NucleusButton_C:Nucleus_OnClicked", "WBP_NucleusChoice_C:Nucleus_OnPrev", "WBP_NucleusChoice_C:Nucleus_OnNext"
T.END, T.COMMIT = "WBP_NucleusSlider_C:Nucleus_OnSliderEnd", "WBP_NucleusSlider_C:Nucleus_OnSliderCommit"
T.TICKED = "/Game/Graphics/MainMenu/Textures/checkbox_ticked.checkbox_ticked"
T.UNTICKED = "/Game/Graphics/MainMenu/Textures/checkbox_unticked.checkbox_unticked"
function T.iconPath(w) return w.icon and w.icon[1] and w.icon[1].__path end
T.log = {} -- onChange calls: { id, h, a, b }
function T.rec(id) return function(h, a, b) T.log[#T.log + 1] = { id = id, h = h, a = a, b = b } end end
function T.ncalls(id) local n = 0 for _, e in ipairs(T.log) do if e.id == id then n = n + 1 end end return n end
function T.last(id) for i = #T.log, 1, -1 do if T.log[i].id == id then return T.log[i] end end end
function T.count() local n = 0 for _ in pairs(C.els) do n = n + 1 end return n end
function T.bad(fn, text, name)
    local before = T.count()
    raises(fn, text, name)
    ok(T.count() == before, name .. ": nothing created")
end

-- ---------------------------------------------------------------- a live title-screen menu and a window
local mt = X.create{ id = "mt", text = "menu", place = { host = "menu", corner = "top-right" } }
build(1)
tick(); tick()
ok(M.isOpen() and X.isShown(mt), "setup: the menu is open")
T.W = SC.open{ id = "W" }
T.list = LS.create{ id = "lst", place = { screen = T.W, absolute = { anchor = "center", x = 0, y = 0 } }, size = { 700, 500 } }
T.row = RS.create{ id = "row", place = { list = T.list } }

-- ---------------------------------------------------------------- core story 27: the focus fakes
-- Keyboard focus: one widget at a time (F.focus). A button's inner Btn, a choice's and a slider's own widget, and the
-- window take it; SetFocusLook is recorded; the window's card parts (Card, Inner) record their calls; the viewport is
-- the VM's 1280x720 at scale 1 unless a test changes it.
local FO = require("nucleus.ui.focus")
local theme27 = require("nucleus.ui.theme")
T.vp = { w = 1280, h = 720, scale = 1 }
obj({ GetViewportSize = function() return vec(T.vp.w, T.vp.h) end, GetViewportScale = function() return T.vp.scale end },
    "/Script/UMG.Default__WidgetLayoutLibrary")
local function focusable(o)
    o.__alive = o.__alive == nil and true or o.__alive
    function o:SetKeyboardFocus() F.focus = self end
    function o:HasKeyboardFocus() return F.focus == self end
    return o
end
do
    local WBL = F.objects["/Script/UMG.Default__WidgetBlueprintLibrary"]
    local base = WBL.Create
    WBL.Create = function(self, world, c, owner)
        local w = base(self, world, c, owner)
        if w.__class == "WBP_NucleusButton_C" then
            focusable(w.Btn)
            w.Btn.__addr = w.__addr + 1
            function w:SetFocusLook(on) self.focusLook = on; self.looks = (self.looks or 0) + 1 end
        elseif w.__class == "WBP_NucleusChoice_C" or w.__class == "WBP_NucleusSlider_C" then
            focusable(w)
            function w:SetFocusLook(on) self.focusLook = on; self.looks = (self.looks or 0) + 1 end
        elseif w.__class == "WBP_NucleusScreen_C" then
            focusable(w)
            w.Card = { SetBrushColor = function(s, col) s.color = col end, SetPadding = function(s, m) s.padding = m end }
            w.Inner = { SetWidthOverride = function(s, v) s.w = v; s.calls = (s.calls or 0) + 1 end, SetHeightOverride = function(s, v) s.h = v end }
            w.NavDir, w.NavAction, w.NavHandled = 7, 3, false
            function w:HasFocusedDescendants()
                local f = F.focus
                local n = 0
                while f and n < 8 do
                    if f == self then return true end
                    f = f.parent or (f.owner and f.owner.parent) or nil
                    n = n + 1
                end
                return false
            end
        elseif w.__class == "WBP_NucleusList_C" then
            w.Scroll.into = {}
            function w.Scroll:ScrollWidgetIntoView(target, anim, dest, pad) self.into[#self.into + 1] = { target = target, anim = anim, dest = dest, pad = pad } end
        end
        if w.Btn then w.Btn.owner = w end
        return w
    end
end
local NAV = "WBP_NucleusScreen_C:Nucleus_OnNav"
-- Presses a key on the window: the Blueprint sets NavDir / NavAction, NavHandled false, calls <Core>_OnNav (the hooks
-- run), then returns Handled iff NavHandled.
function T.key(w, dir, act)
    w.NavDir, w.NavAction, w.NavHandled = dir, act, false
    fireHook(NAV, w)
    return w.NavHandled
end
local D, A = FO.DIR, FO.ACT
local INV_DIR, INV_ACT = 7, 3
function T.screenOf(id)
    for _, o in pairs(handles) do if type(o) == "table" and o.__class == "WBP_NucleusScreen_C" and o.tag:find("#screen:" .. id, 1, true) and o.__alive then return o end end
    return nil
end
function T.focusedId(w) return SC.stats().focus end
function T.btn(id) local w = T.tagged(id) return w and w.Btn end
function T.agree(id)
    local el = C.els[id]
    local t = el and FO._targetOf(el)
    return SC.stats().focus == id and t ~= nil and F.focus == t
end

-- ---------------------------------------------------------------- pure: the hug rule at the three viewports
do
    local SG = theme27.window.stackGap
    -- a title (top-left), a list (top-left, below it), BACK (bottom-left), two buttons (bottom-right)
    local items = {
        { corner = "top-left", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 300, h = 40 },
        { corner = "top-left", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 700, h = 420 },
        { corner = "bottom-left", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 90, h = 44 },
        { corner = "bottom-right", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 120, h = 44 },
        { corner = "bottom-right", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 120, h = 44 },
    }
    local W, H = SC._hug(items, SG)
    ok(W == 716 and H == (16 + 40 + 16 + 420) + SG + (16 + 44), "hug: width from the widest stack, height from the left stacks plus the gap", W .. "x" .. H)
    local W2 = SC._hug({ { absolute = { anchor = "top-left", x = 360, y = 40 }, w = 560, h = 30 } }, SG)
    ok(W2 == 920, "hug: an absolute element at top-left needs x + w", W2)
    local W3, H3 = SC._hug({ { absolute = { anchor = "center", x = -20, y = 10 }, w = 600, h = 400 } }, SG)
    ok(W3 == 640 and H3 == 420, "hug: a centred absolute element needs w + 2|x|", W3 .. "x" .. H3)
    local W4 = SC._hug({ { corner = "top-left", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 100, h = 10 },
        { corner = "top-right", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 100, h = 10 } }, SG)
    ok(W4 == 116 + SG + 116, "hug: two stacks side by side add up, a gap between", W4)
    ok(select(1, SC._hug({}, SG)) == 0, "hug: nothing, nothing")
    for _, vp in ipairs({ { 1280, 720, 1 }, { 1920, 1080, 1 }, { 3440, 1440, 1440 / 1080 } }) do
        local vw, vh = vp[1] / vp[3], vp[2] / vp[3]
        local w, h, clamped = SC._clamp(W, H, vw, vh, theme27.window.padding, theme27.window.margin)
        local fits = W + 2 * 24 <= vw - 64 and H + 2 * 24 <= vh - 64
        ok(clamped == not fits and w <= vw - 64 - 48 and h <= vh - 64 - 48 and (fits and w == W and h == H or not fits),
            string.format("hug at %dx%d: %s", vp[1], vp[2], fits and "fits unclamped" or "clamped to the viewport less 64"), w .. "x" .. h)
        local cw, ch, c2 = SC._clamp(4000, 300, vw, vh, 24, 32)
        ok(c2 and cw == vw - 64 - 48 and ch == 300, string.format("oversized at %dx%d: a 4000-wide list clamps to the viewport - 64", vp[1], vp[2]), cw)
    end
end

-- ---------------------------------------------------------------- pure: moves and recovery
do
    local a, b, c, d, e = { id = "a" }, { id = "b" }, { id = "c" }, { id = "d" }, { id = "back" }
    local lines = { { els = { a, b }, owner = "r1" }, { els = { c }, owner = nil }, { els = { d, a, b }, owner = "r3" }, { els = { e }, owner = "#back" } }
    ok(select(1, FO.move(lines, 1, 2, D.down)) == 2 and select(2, FO.move(lines, 1, 2, D.down)) == 1, "move: Down to a shorter line clamps the column")
    ok(select(2, FO.move(lines, 2, 1, D.down)) == 1, "move: Down keeps the nearest column")
    ok(select(1, FO.move(lines, 4, 1, D.down)) == 4, "move: Down at Back stays (no wrap)")
    ok(select(1, FO.move(lines, 1, 1, D.up)) == 1, "move: Up at the first line stays")
    ok(select(2, FO.move(lines, 3, 3, D.right)) == 3 and select(2, FO.move(lines, 3, 1, D.left)) == 1, "move: Left / Right stop at the line's ends")
    ok(select(1, FO.move(lines, 2, 1, D.next)) == 3 and select(1, FO.move(lines, 2, 1, D.previous)) == 1, "move: Next / Previous are Down / Up")
    ok(FO.recover(lines, { li = 1, ci = 3, owner = "r3" }) == b and FO.recover(lines, { li = 1, ci = 9, owner = "r1" }) == b, "recover: its row is still there: the nearest in it")
    ok(FO.recover(lines, { li = 2, ci = 1 }) == c, "recover: a lone button gone: the line now at its index (the next)")
    ok(FO.recover(lines, { li = 9, ci = 1 }) == e, "recover: past the end: the previous line (Back)")
    ok(FO.recover({}, { li = 1, ci = 1 }) == nil, "recover: nothing focusable: nil")
end

-- ---------------------------------------------------------------- a live window: lines, keys, adjust, Back
T.W2 = SC.open{ id = "K" }
local wk = T.screenOf("K")
tick() -- the poll registers the key hook
ok(hookCount("Nucleus_OnNav") == 1, "keys: one hook on <Core>_OnNav, registered from the poll", hookCount("Nucleus_OnNav"))
ok(wk.Card.color and T.near(wk.Card.color.A, 0.92) and wk.Card.padding.Left == 24, "card: the game look's colour, padding 24")
local L1 = LS.create{ id = "kl", place = { screen = T.W2, corner = "top-left" }, size = { 600, 300 } }
local rowsK, toggles, gears = {}, {}, {}
for i = 1, 3 do
    rowsK[i] = RS.create{ id = "kr" .. i, place = { list = L1 } }
    toggles[i] = B.create{ id = "kt" .. i, label = "T" .. i, place = { row = rowsK[i] }, onClick = T.rec("kt" .. i) }
    X.create{ id = "kx" .. i, text = "name", place = { row = rowsK[i], fill = 4 } }
    gears[i] = B.create{ id = "kg" .. i, label = "G" .. i, place = { row = rowsK[i] }, onClick = T.rec("kg" .. i) }
end
local kch = CH.create{ id = "kch", options = { "LOW", "MID", "HIGH" }, selected = 1, place = { screen = T.W2, corner = "top-right" }, onChange = T.rec("kch") }
local ksl = SL.create{ id = "ksl", min = 0, max = 10, step = 1, defaultValue = 5, place = { screen = T.W2, corner = "top-right" }, onChange = T.rec("ksl") }
local lines = FO.lines(C.windowHost("K"), "#close:K")
local function ids(l) local o = {} for _, e in ipairs(l.els) do o[#o + 1] = e.id end return table.concat(o, "|") end
ok(#lines == 6 and ids(lines[1]) == "kt1|kg1" and ids(lines[3]) == "kt3|kg3" and ids(lines[4]) == "kch" and ids(lines[5]) == "ksl" and ids(lines[6]) == "#close:K",
    "lines: one per row (focusables left to right, text skipped), then the window's own, then Back", #lines)
ok(wk.Inner.w and wk.Inner.w >= 600 and wk.Inner.h > 300, "card: re-fitted as elements joined", wk.Inner.w)
-- re-open so the first line gets focus on open
SC.close(T.W2)
T.W2 = SC.open{ id = "K" }
wk = T.screenOf("K")
ok(T.agree("kt1") and T.tagged("kt1").focusLook == true, "open: focus on the first row's first focusable, highlighted", SC.stats().focus)
ok(T.key(wk, D.down, INV_ACT) and T.agree("kt2"), "Down: the next line, same column")
ok(T.key(wk, D.right, INV_ACT) and T.agree("kg2") and T.tagged("kt2").focusLook == false and T.tagged("kg2").focusLook == true, "Right: the gear; the text is skipped; the look moves")
ok(T.key(wk, D.right, INV_ACT) and T.agree("kg2"), "Right at the line's end: stays")
ok(T.key(wk, D.left, INV_ACT) and T.agree("kt2"), "Left: back to the toggle")
ok(T.key(wk, D.up, INV_ACT) and T.key(wk, D.up, INV_ACT) and T.agree("kt1"), "Up twice: the first line, stays there")
local lw = T.tagged("kl")
ok(#lw.Scroll.into >= 1 and lw.Scroll.into[#lw.Scroll.into].target == T.tagged("kr1") and lw.Scroll.into[#lw.Scroll.into].anim == false, "scroll: the focused row is scrolled into view, no animation")
-- down to the choice
T.key(wk, D.down, INV_ACT); T.key(wk, D.down, INV_ACT); T.key(wk, D.down, INV_ACT)
ok(T.agree("kch") and T.tagged("kch").focusLook == true, "Down: from the last row to the choice (its own widget)")
clock = clock + 300000
ok(T.key(wk, D.right, INV_ACT) and CH.get(kch) == 2 and T.ncalls("kch") == 1 and T.agree("kch"), "Right on a choice: the next option, onChange once, focus stays")
clock = clock + 300000
T.key(wk, D.right, INV_ACT); clock = clock + 300000
ok(T.key(wk, D.right, INV_ACT) and CH.get(kch) == 3 and T.ncalls("kch") == 2, "Right on a choice at its end: inert, no onChange")
ok(T.key(wk, INV_DIR, A.accept) and CH.get(kch) == 3 and T.agree("kch"), "Accept on a choice: Handled, nothing changes")
T.key(wk, D.down, INV_ACT)
ok(T.agree("ksl"), "Down: the slider")
ok(T.key(wk, D.right, INV_ACT) and SL.get(ksl) == 6 and T.ncalls("ksl") == 1, "Right on a Default slider: defaultValue + step, onChange once", SL.get(ksl))
ok(T.key(wk, D.left, INV_ACT) and T.key(wk, D.left, INV_ACT) and SL.get(ksl) == 4 and T.ncalls("ksl") == 3, "Left twice: value - step each, onChange each")
SL.set(ksl, 10)
ok(T.key(wk, D.right, INV_ACT) and SL.get(ksl) == 10 and T.ncalls("ksl") == 3, "Right at max: clamped, no onChange")
T.key(wk, D.down, INV_ACT)
ok(T.agree("#close:K"), "Down: Back is the last line")
ok(T.key(wk, D.down, INV_ACT) and T.agree("#close:K"), "Down at Back: stays (Handled)")
-- Accept on a focused Button is the Button's own click (the hook): onClick once
T.key(wk, D.up, INV_ACT); T.key(wk, D.up, INV_ACT); T.key(wk, D.up, INV_ACT)
ok(T.agree("kt3"), "Up from Back: the last row, nearest column")
T.fire(T.CLICK, T.tagged("kt3"))
ok(T.ncalls("kt3") == 1, "Enter / A on a focused button (its Button clicks): onClick once")
-- a mouse click moves the model's focus
T.fire(T.CLICK, T.tagged("kg1"))
ok(SC.stats().focus == "kg1" and T.tagged("kg1").focusLook == true and T.tagged("kt3").focusLook == false, "a mouse click moves the model's focus there")
F.focus = T.tagged("kg1").Btn
-- the focused element removed, hidden, disabled
B.setEnabled(gears[1], false)
ok(T.agree("kt1"), "disabled: focus to the nearest in its line", SC.stats().focus)
B.setVisible(toggles[1], false)
ok(T.agree("kt2"), "hidden (its line now empty): the line at its index (the next)", SC.stats().focus)
B.remove(toggles[2])
ok(T.agree("kg2"), "removed: the nearest in its row", SC.stats().focus)
B.setEnabled(gears[1], true); B.setVisible(toggles[1], true)

-- ---------------------------------------------------------------- Escape / B, stacked windows, focus return
T.key(wk, D.down, INV_ACT)
local remembered = SC.stats().focus
local W3 = SC.open{ id = "K2" }
local wk2 = T.screenOf("K2")
ok(T.agree("#close:K2"), "a second window: focus on its only focusable (Back)")
ok(T.key(wk, D.down, INV_ACT) and T.agree("#close:K2"), "a key on the window below: Handled, focus back to the top window")
local closedWith = nil
local tok = SC.watch(function(_, info) if info.event == "closed" then closedWith = info.id .. ":" .. tostring(info.reason) end end)
ok(T.key(wk2, INV_DIR, A.back) and closedWith == "K2:close", "Escape / B: the top window closes, reason close", closedWith)
ok(SC.top() == T.W2 and T.agree(remembered), "after the close: the window below gets its last-focused element back", SC.stats().focus)
local W4 = SC.open{ id = "K3", close = false }
local wk3 = T.screenOf("K3")
ok(F.focus == wk3, "no focusables (close = false, only text): the window widget itself is focused")
X.create{ id = "k3t", text = "only text", place = { screen = W4, corner = "top-left" } }
closedWith = nil
ok(T.key(wk3, INV_DIR, A.back) and closedWith == nil and SC.isOpen(W4), "Escape on a close = false window: Handled, nothing closes")
ok(T.key(wk3, D.down, INV_ACT) and F.focus == wk3, "keys on a window with nothing focusable: Handled, nothing moves")
SC.close(W4)
SC.unwatch(tok)

-- ---------------------------------------------------------------- hook noise
do
    local before = SC.stats().focus
    ok(T.key(wk, 99, INV_ACT) == false and SC.stats().focus == before, "NavDir 99: Unhandled, ignored")
    ok(T.key(wk, INV_DIR, -1) == false, "NavAction -1: Unhandled, ignored")
    ok(T.key(wk, "x", nil) == false, "a non-number: Unhandled")
    local other = T.screenOf("K")
    local fake = setmetatable({}, { __index = other })
    local foreign = { __alive = true, __addr = 0x77, tag = "nucleus:OtherMod:#screen:K", NavDir = D.down, NavAction = INV_ACT, NavHandled = false }
    foreign.CoreTag = { ToString = function() return foreign.tag end }
    foreign.GetAddress = function(self) return self.__addr end
    foreign.IsValid = function() return true end
    fireHook(NAV, foreign)
    ok(foreign.NavHandled == false and SC.stats().focus == before, "another mod's window: ignored in silence")
    local stale = { __alive = true, __addr = 0x78, tag = wk.tag, NavDir = D.down, NavAction = INV_ACT, NavHandled = false }
    stale.CoreTag = { ToString = function() return stale.tag end }
    stale.GetAddress = function(self) return self.__addr end
    fireHook(NAV, stale)
    ok(stale.NavHandled == false and SC.stats().focus == before, "a stale window widget: ignored")
    local dead = { __alive = false }
    fireHook(NAV, dead)
    ok(true, "a dead widget: no error")
    local n0 = countLogs("window key handling failed")
    fireHook(NAV, { __alive = true, CoreTag = { ToString = function() error("boom") end } })
    ok(countLogs("window key handling failed") == n0, "a throwing tag read: ignored in silence")
    -- a window closed mid-event: the record is not open
    local W5 = SC.open{ id = "K5" }
    local w5 = T.screenOf("K5")
    SC.close(W5)
    w5.__alive = true
    ok(T.key(w5, D.down, INV_ACT) == false, "a window closed mid-event: ignored")
    -- off the game thread: ignored
    _G.Nucleus_Deref = function() error("Nucleus_Deref called off the game thread") end
    ok(T.key(wk, D.down, INV_ACT) == false, "an off-thread call: ignored")
    _G.Nucleus_Deref = function() return nil end
    ok(FO.stats().faults == 0, "no fault logged for noise")
end

-- ---------------------------------------------------------------- compact gap, placement texts
do
    local lc = LS.create{ id = "kgap", place = { screen = T.W2, corner = "top-left" }, size = { 200, 100 } }
    ok(C.els["kgap"].gapUnits == 4 and C.els["kgap"].gap == "compact", "list: the default gap is compact (4)")
    LS.remove(lc)
    raises(function() LS.create{ id = "kgap2", place = { screen = T.W2, corner = "top-left" }, size = { 200, 100 }, gap = "tiny" } end,
        "nucleus.ui.list.create: unknown gap 'tiny' (valid: compact, tight, normal, loose)", "list: gap 'tiny' raises with the new list")
    raises(function() RS.create{ id = "kgap3", place = { list = L1 }, gap = "tiny" } end,
        "nucleus.ui.row.create: unknown gap 'tiny' (valid: compact, tight, normal, loose)", "row: gap 'tiny' raises with the new list")
    raises(function() X.create{ id = "kgap4", text = "x", place = { screen = T.W2, corner = "top-left", gap = "compact" } } end,
        "nucleus.ui.place: unknown gap 'compact' (valid: tight, normal, loose)", "placement: compact raises with the unchanged list")
    local r = RS.create{ id = "kgap5", place = { list = L1 }, gap = "compact" }
    ok(C.els["kgap5"].gapUnits == 4, "row: gap compact is 4")
    ok(C.els["kr1"].gap == "tight", "row: the default stays tight")
    RS.remove(r)
end

-- ---------------------------------------------------------------- oversized content: one WARN per window id
do
    local n0 = countLogs("is larger than the viewport allows")
    local big = LS.create{ id = "kbig", place = { screen = T.W2, corner = "top-left" }, size = { 4000, 100 } }
    ok(countLogs("is larger than the viewport allows") == n0 + 1 and wk.Inner.w == 1280 - 64 - 48, "oversized: the card clamps to the viewport - 64, one WARN", wk.Inner.w)
    LS.create{ id = "kbig", place = { screen = T.W2, corner = "top-left" }, size = { 4096, 100 } }
    ok(countLogs("is larger than the viewport allows") == n0 + 1, "oversized again: no second WARN for the window")
    LS.remove(big)
end

-- ---------------------------------------------------------------- the tick: focus taken away comes back
F.focus = nil
tick()
ok(F.focus ~= nil and SC.stats().focus ~= nil and T.agree(SC.stats().focus), "tick: keyboard focus left the window: back to the remembered element", SC.stats().focus)

-- ---------------------------------------------------------------- preview keys: what is left to the focused widget
do
    local W6 = SC.open{ id = "K6" }
    local w6 = T.screenOf("K6")
    -- built after the open: focus follows the first element until the next tick
    local L6 = LS.create{ id = "k6l", place = { screen = W6, corner = "top-left" }, size = { 300, 200 } }
    local r6 = RS.create{ id = "k6r", place = { list = L6 } }
    B.create{ id = "k6b", label = "B", place = { row = r6 }, onClick = T.rec("k6b") }
    local cb6 = CK.create{ id = "k6c", place = { row = r6 }, onChange = T.rec("k6c") }
    ok(T.agree("k6b"), "open then build: focus follows the window's first element", SC.stats().focus)
    ok(T.key(w6, INV_DIR, A.accept) == false, "Accept on a focused button: left to the Button (Unhandled)")
    T.key(w6, D.right, INV_ACT)
    ok(T.agree("k6c") and T.key(w6, INV_DIR, A.accept) == false, "Accept on a focused checkbox: left to its Button too")
    local box = { __alive = true }
    F.focus = box -- a text box inside the window holds focus
    ok(T.key(w6, D.down, INV_ACT) == false and T.key(w6, INV_DIR, A.back) == false and SC.isOpen(W6), "a text box holds focus: every key is left to it (Escape doesn't close)")
    F.focus = T.tagged("k6b").Btn
    -- the gap split for a fixed-size child in a row, the list inset
    local rw = T.tagged("k6r")
    local cw = T.tagged("k6c")
    ok(cw.Slot.Padding.Left == 6 and cw.Slot.Padding.Right == 2 and cw.Slot.HorizontalAlignment == 2,
        "a fixed-size row child: its gap split 3/4 left, 1/4 right (centred inside its slot less the gap)", cw.Slot.Padding.Left .. "/" .. cw.Slot.Padding.Right)
    ok(T.tagged("k6b").Slot.Padding.Left == 0 and rw.Slot.Padding.Right == 4, "a list's children keep 4 units clear of its right edge")
    SC.close(W6)
end

-- ---------------------------------------------------------------- review fixes
-- (1) A reopened window with unchanged content: its new widget's Inner gets the hug size again.
do
    local W7 = SC.open{ id = "K7" }
    X.create{ id = "k7t", text = "SAME", place = { screen = W7, corner = "top-left" } }
    local w7 = T.screenOf("K7")
    local hugW, hugH = w7.Inner.w, w7.Inner.h
    SC.close(W7)
    SC.open{ id = "K7" }
    local w7b = T.screenOf("K7")
    ok(w7b ~= w7 and hugW and w7b.Inner.w == hugW and w7b.Inner.h == hugH, "reopen with unchanged content: the new widget's Inner gets the hug size again", tostring(w7b.Inner.w))
    SC.close(W7)
end

-- (2) Slate moved focus to another element (the analog stick): the model adopts it on the next key, the look follows.
do
    local W8 = SC.open{ id = "K8" }
    local L8 = LS.create{ id = "k8l", place = { screen = W8, corner = "top-left" }, size = { 300, 200 } }
    for i = 1, 3 do
        local r = RS.create{ id = "k8r" .. i, place = { list = L8 } }
        B.create{ id = "k8b" .. i, label = "B" .. i, place = { row = r }, onClick = T.rec("k8b" .. i) }
    end
    local w8 = T.screenOf("K8")
    ok(T.agree("k8b1"), "stick: the model starts on row 1")
    F.focus = T.tagged("k8b2").Btn -- Slate's own navigation moved focus to row 2
    ok(T.key(w8, D.down, INV_ACT) and T.agree("k8b3"), "stick: the model adopted row 2 and Down moved on from there (row 3)", SC.stats().focus)
    ok(T.tagged("k8b1").focusLook == false and T.tagged("k8b3").focusLook == true, "stick: the focus look left row 1 and followed the model")
    SC.close(W8)
end

-- (3) Interleaved windows of two mods (shared Z): a close gives focus to this mod's next window only when it is the
-- global top; a lost top window leaves the next one the global top.
do
    local function setShared(k, v) ModRef:SetSharedVariable(k, v) end
    local ZK = SC._OPEN_Z_KEY
    local A1 = SC.open{ id = "ZA1" }
    local za1 = T.screenOf("ZA1")
    local zA1 = za1.z
    -- another mod opens its window above (z + 1): the shared registry and counter say so
    local other = zA1 + 1
    setShared(ZK, (ModRef:GetSharedVariable(ZK) or "") .. "," .. other)
    setShared("nucleus.ui.screenZ", other)
    local A3 = SC.open{ id = "ZA3" }
    ok(T.screenOf("ZA3").z == other + 1, "interleaved: this mod's second window above the other mod's")
    F.focus = "other mod's window" -- focus sits in the other mod's window under ours
    SC.close(A3)
    ok(F.focus == "other mod's window", "interleaved: closing our top window doesn't focus our lower one under the other mod's")
    tick()
    ok(F.focus == "other mod's window", "interleaved: our lower window's tick doesn't take focus from the other mod's")
    -- the other mod closes its window: ours is the global top again and its tick takes focus back
    local list = {}
    for _, z in ipairs(SC._openZs()) do if z ~= other then list[#list + 1] = tostring(z) end end
    setShared(ZK, table.concat(list, ","))
    tick()
    ok(SC.stats().focus ~= nil and T.agree(SC.stats().focus), "interleaved: once the other mod's window closed, our window takes focus back", SC.stats().focus)
    -- the lost path: our top window's widget dies; the one below is the global top and focused
    local A4 = SC.open{ id = "ZA4" }
    local za4 = T.screenOf("ZA4")
    za4.__alive = false
    tick()
    local zs = SC._openZs()
    local has4 = false
    for _, z in ipairs(zs) do if z == za4.z then has4 = true end end
    ok(not has4 and SC.top() == A1 and SC.stats().focus ~= nil and T.agree(SC.stats().focus), "lost: the dead window left the registry; the one below is the global top and focused", SC.stats().focus)
    SC.close(A1)
    local left = false
    for _, z in ipairs(SC._openZs()) do if z == zA1 then left = true end end
    ok(not left, "closed: its Z left the registry")
    _ = A4
end

-- (4) Building into an open window: one prepass and re-fit per frame, not one per element.
do
    local queue = {}
    ExecuteInGameThreadWithDelay = function(_, fn) queue[#queue + 1] = fn end
    local W9 = SC.open{ id = "K9" }
    local w9 = T.screenOf("K9")
    local n = 0
    w9.ForceLayoutPrepass = function() n = n + 1 end
    local L9 = LS.create{ id = "k9l", place = { screen = W9, corner = "top-left" }, size = { 300, 200 } }
    for i = 1, 20 do
        local r = RS.create{ id = "k9r" .. i, place = { list = L9 } }
        X.create{ id = "k9t" .. i, text = "ROW " .. i, place = { row = r, fill = 1 } }
    end
    ok(n == 0 and #queue == 1, "burst: 41 creates schedule one re-fit, none run yet", n .. " prepasses, " .. #queue .. " scheduled")
    local before = w9.Inner.calls or 0
    for _, fn in ipairs(queue) do fn() end
    queue = {}
    ok(n == 1 and (w9.Inner.calls or 0) == before + 1, "burst: the frame runs one prepass and one re-fit", n)
    X.create{ id = "k9x", text = "ONE MORE", place = { screen = W9, corner = "top-right" } }
    ok(#queue == 1, "after the frame: the next change schedules again")
    for _, fn in ipairs(queue) do fn() end
    ExecuteInGameThreadWithDelay = nil
    SC.close(W9)
end

print(string.format("focus_test: %d passed, %d failed", pass, failN))
if failN > 0 then os.exit(1) end
