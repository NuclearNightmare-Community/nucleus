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
-- Core story 30: the material library; an instance records its parent and vector parameters. F.midFail: "create"
-- (throws), "nil" (returns nothing) or "set" (SetVectorParameterValue throws).
F.mids = {}
obj({ CreateDynamicMaterialInstance = function(_, wc, parent, name, flags)
    if F.midFail == "create" then error("CreateDynamicMaterialInstance: boom") end
    if F.midFail == "nil" then return INVALID end
    local mi = obj({ __class = "MaterialInstanceDynamic", Parent = parent, params = {}, wc = wc, name = name, flags = flags,
        SetVectorParameterValue = function(self, n, c)
            if F.midFail == "set" then error("SetVectorParameterValue: boom") end
            self.params[n] = c
        end })
    F.mids[#F.mids + 1] = mi
    return mi
end }, "/Script/Engine.Default__KismetMaterialLibrary")

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
    -- core story 39: a render scale (a button's Btn and Content); throwScale makes it raise
    function i:SetRenderScale(v)
        if self.throwScale then error("SetRenderScale: boom") end
        self.scale = { v.X, v.Y }; self.scaleCalls = (self.scaleCalls or 0) + 1
    end
    return i
end
function T.decorate(w)
    if w.__class == "WBP_NucleusText_C" then
        w.Text, w.Background = T.inner(4), T.inner(3) -- the generator's: Background HitTestInvisible, Text SelfHitTestInvisible
        w.Text.policy, w.Text.clip = 0, 0
    elseif w.__class == "WBP_NucleusButton_C" then
        w.Btn, w.Box, w.Label, w.IconGap, w.Content = T.inner(0), T.inner(4), T.inner(3), T.inner(1), T.inner(3)
        function w:SetIcon(t, W, H) self.icon = { t, W, H } end
        function w:ClearIcon() self.icon = nil; self.cleared = (self.cleared or 0) + 1 end
        function w:SetContentColors(...) self.content = { ... } end
        -- core story 42: the box behind the icon (show, r, g, b, a), its calls counted
        function w:SetIconBack(...) self.back = { ... }; self.backCalls = (self.backCalls or 0) + 1 end
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
FO._noChip = true -- core story 39: the blocks before story 39's prove their looks without the focus chip
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
    -- the list spans the width, so the bottom-right buttons (diagonal to it) go below it, not over its lower right
    ok(W == 716 and H == (16 + 40 + 16 + 420) + SG + (16 + 44 + 16 + 44), "hug: width from the widest stack, height from the list plus the gap plus the bottom-right stack", W .. "x" .. H)
    local W2 = SC._hug({ { absolute = { anchor = "top-left", x = 360, y = 40 }, w = 560, h = 30 } }, SG)
    ok(W2 == 920, "hug: an absolute element at top-left needs x + w", W2)
    local W3, H3 = SC._hug({ { absolute = { anchor = "center", x = -20, y = 10 }, w = 600, h = 400 } }, SG)
    ok(W3 == 640 and H3 == 420, "hug: a centred absolute element needs w + 2|x|", W3 .. "x" .. H3)
    local W4 = SC._hug({ { corner = "top-left", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 100, h = 10 },
        { corner = "top-right", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 100, h = 10 } }, SG)
    ok(W4 == 116 + SG + 116, "hug: two stacks side by side add up, a gap between", W4)
    ok(select(1, SC._hug({}, SG)) == 0, "hug: nothing, nothing")
    -- diagonal stacks that fit neither side by side nor one above the other: one goes above the other (BACK under a
    -- top-right list, not over it)
    local W5, H5 = SC._hug({ { corner = "top-right", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 600, h = 300 },
        { corner = "bottom-left", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 90, h = 44 } }, SG)
    ok(W5 == 616 and H5 == 316 + SG + 60, "hug: a top-right list and BACK bottom-left: BACK below the list", W5 .. "x" .. H5)
    local W6, H6 = SC._hug({ { corner = "top-left", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 600, h = 300 },
        { corner = "bottom-right", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 90, h = 44 } }, SG)
    ok(W6 == 616 and H6 == 316 + SG + 60, "hug: a top-left list and a bottom-right button: the button below the list", W6 .. "x" .. H6)
    local W7, H7 = SC._hug({ { corner = "top-left", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 100, h = 300 },
        { corner = "top-right", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 500, h = 400 },
        { corner = "bottom-right", inset = 16, gap = 16, offset = { x = 0, y = 0 }, w = 90, h = 44 } }, SG)
    ok(W7 == 116 + SG + 516 and H7 == 416 + SG + 60, "hug: diagonal stacks side by side already: the height only from the column sums", W7 .. "x" .. H7)
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
-- a click on a choice's arrow or a slider's drag end moves the focus there, keyboard focus included (their arrows and
-- bar aren't focusable, so Slate's focus would stay on the button)
tick() -- the poll registers the choice's and the slider's hooks
T.fire(T.PREV, T.tagged("kch"))
ok(T.agree("kch") and T.tagged("kch").focusLook == true and T.tagged("kg1").focusLook == false, "a click on a choice's arrow: the focus (model and keyboard) on the choice", SC.stats().focus)
ok(T.key(wk, D.down, INV_ACT) and T.agree("ksl"), "Down after that click: from the choice to the slider", SC.stats().focus)
T.fire(T.CLICK, T.tagged("kg1"))
T.fire(T.END, T.tagged("ksl"))
ok(T.agree("ksl") and T.tagged("kg1").focusLook == false, "a slider's drag end: the focus on the slider", SC.stats().focus)
-- a focused choice or slider disabled: focus handed on at once (before any tick)
SL.setEnabled(ksl, false)
ok(T.agree("#close:K"), "a focused slider disabled: the line now at its index (Back)", SC.stats().focus)
SL.setEnabled(ksl, true)
T.fire(T.NEXT, T.tagged("kch"))
CH.setEnabled(kch, false)
ok(T.agree("ksl"), "a focused choice disabled: the line now at its index (the slider)", SC.stats().focus)
CH.setEnabled(kch, true)
T.fire(T.CLICK, T.tagged("kg1"))
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
    T.key(w6, D.right, INV_ACT)
    CK.setEnabled(cb6, false)
    ok(T.agree("k6b"), "a focused checkbox disabled: focus to the nearest in its line", SC.stats().focus)
    CK.setEnabled(cb6, true)
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

-- ---------------------------------------------------------------- core story 28: the focused row and the focus face
-- Fakes as the Blueprint: SetColors and SetMaterials (a fresh style) turn FocusLook off; calls are counted per widget.
do
    local WBL = F.objects["/Script/UMG.Default__WidgetBlueprintLibrary"]
    local base = WBL.Create
    WBL.Create = function(self, world, c, owner)
        local w = base(self, world, c, owner)
        if w.__class == "WBP_NucleusButton_C" then
            local sc, sm = w.SetColors, w.SetMaterials
            function w:SetColors(...) self.focusLook = false; self.colorCalls = (self.colorCalls or 0) + 1; self.lastFace = "colors"; return sc(self, ...) end
            function w:SetMaterials(...) self.focusLook = false; self.matCalls = (self.matCalls or 0) + 1; self.lastFace = "mats"; return sm(self, ...) end
        end
        if w.SetBackgroundMaterial then
            local sbm = w.SetBackgroundMaterial
            function w:SetBackgroundMaterial(...)
                self.bgMatCalls = (self.bgMatCalls or 0) + 1
                if self.throwBg then error("SetBackgroundMaterial: boom") end
                return sbm(self, ...)
            end
        end
        return w
    end
end
T.SEL = F.assets["/Game/Graphics/MainMenu/Styles/Remaster/M_NN_CinematicSelection.M_NN_CinematicSelection"]
T.STRIP = F.assets["/Game/Graphics/MainMenu/Styles/Remaster/M_NN_WornStrip.M_NN_WornStrip"]
function T.matOf(id) local w = T.tagged(id) return w and w.mat end
function T.selected(id) return T.matOf(id) == T.SEL end
function T.strip(id) return T.matOf(id) == T.STRIP end
function T.gearFaced(id)
    local w = T.tagged(id)
    local g = theme.game
    return w ~= nil and w.mats ~= nil and w.mats[1] == T.SEL and w.mats[2] == T.SEL and w.mats[11] == 0 and w.focusLook == true
        and T.near(w.content[1], g.text.r) and T.near(w.content[5], g.textHover.r)
end
function T.gearOwn(id)
    local w = T.tagged(id)
    return w ~= nil and w.colors ~= nil and w.colors[4] == 0 and w.colors[13] == 0 and T.near(w.content[1], T.DIM.r) and T.near(w.content[5], T.DIM.r)
        and w.focusLook == false
end
theme.game.focusRowStrong = false -- core story 30: story 28's block proves 0.12.1's look (the switch off)
T.mids28 = #F.mids
do
    local R = SC.open{ id = "R28" }
    local wr = T.screenOf("R28")
    local rec = C.windows["R28"]
    local L = LS.create{ id = "r28l", place = { screen = R, corner = "top-left" }, size = { 600, 400 } }
    local rows, gears = {}, {}
    for i = 1, 3 do
        rows[i] = RS.create{ id = "r28r" .. i, place = { list = L } }
        IM.create{ id = "r28i" .. i, place = { row = rows[i] }, image = { icon = "checkbox-on" }, size = 28 }
        X.create{ id = "r28n" .. i, text = "MOD " .. i, place = { row = rows[i], fill = 4 } }
        gears[i] = B.create{ id = "r28g" .. i, place = { row = rows[i] }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r28g" .. i) }
    end
    -- row 4: a gear and a checkbox (two focusables in a row); row 5: an explicit background; row 6: the plain look
    rows[4] = RS.create{ id = "r28r4", place = { list = L } }
    gears[4] = B.create{ id = "r28g4", place = { row = rows[4] }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r28g4") }
    local cb4 = CK.create{ id = "r28c4", place = { row = rows[4] }, onChange = T.rec("r28c4") }
    rows[5] = RS.create{ id = "r28r5", place = { list = L }, style = { background = { r = 0.2, g = 0.3, b = 0.4, a = 0.5 } } }
    gears[5] = B.create{ id = "r28g5", label = "TOGGLE", place = { row = rows[5] }, onClick = T.rec("r28g5") }
    rows[6] = RS.create{ id = "r28r6", place = { list = L }, style = { look = "plain" } }
    gears[6] = B.create{ id = "r28g6", label = "PLAIN", place = { row = rows[6] }, onClick = T.rec("r28g6") }
    tick() -- open then build: the tick settles focus on the first element
    -- Row focus: r1 highlighted, the others their worn strip; the dimmed icon-only gear has a face
    ok(T.agree("r28g1") and T.selected("r28r1") and T.strip("r28r2") and T.strip("r28r3") and rec.lookRowId == "r28r1",
        "story 28 open: the focused element's row shows the selection, the others the worn strip", tostring(T.matOf("r28r1")))
    local r1w = T.tagged("r28r1")
    ok(T.tintIs(r1w.matTint, theme.game.rowTint), "story 28 open: the highlight in the row tint")
    ok(T.gearFaced("r28g1"), "story 28 open: the dimmed icon-only gear gets a face (selection, no padding, the undimmed colours) and the focus look")
    ok(T.gearOwn("r28g2"), "story 28 open: the other gears keep their own look (no face, dimmed)")
    -- Down: r2 highlighted, r1 back to the worn strip in the same tint and padding
    local padBefore = T.tagged("r28r2").pad
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r28g2") and T.selected("r28r2") and T.strip("r28r1") and rec.lookRowId == "r28r2",
        "story 28 Down: the highlight moves to row 2, row 1 shows its worn strip again")
    ok(T.tintIs(r1w.matTint, theme.game.rowTint) and r1w.pad == padBefore, "story 28 Down: row 1's strip in its own tint and padding")
    ok(T.gearOwn("r28g1") and T.gearFaced("r28g2"), "story 28 Down: the old gear's own look back, the new one faced")
    -- Same row: Left / Right inside one row keeps the highlight; the face follows the element
    T.key(wr, D.down, INV_ACT); T.key(wr, D.down, INV_ACT)
    ok(T.agree("r28g4") and T.selected("r28r4"), "story 28 same row: on row 4's gear")
    local n4 = T.tagged("r28r4").bgMatCalls or 0
    local cw = T.tagged("r28c4")
    ok(T.key(wr, D.right, INV_ACT) and T.agree("r28c4") and T.selected("r28r4") and (T.tagged("r28r4").bgMatCalls or 0) == n4,
        "story 28 same row: Right to the checkbox, the row stays highlighted (no call)")
    ok(T.gearOwn("r28g4") and cw.mats and cw.mats[1] == T.SEL and cw.focusLook == true, "story 28 same row: the gear's own look back, the checkbox (faceless) faced")
    local g4 = T.tagged("r28g4")
    local gc = g4.colorCalls
    ok(T.key(wr, D.left, INV_ACT) and T.agree("r28g4") and cw.colors and cw.colors[4] == 0 and cw.focusLook == false and g4.colorCalls == gc and T.gearFaced("r28g4"),
        "story 28 same row: Left back: the checkbox's own (faceless) look, the gear faced again")
    -- Explicit row: selection while focused, its own colour (SetBackgroundSolid + colour) after
    T.key(wr, D.down, INV_ACT)
    local t5 = T.tagged("r28g5")
    ok(T.agree("r28g5") and T.selected("r28r5"), "story 28 explicit row: the selection while focused")
    ok(t5.matCalls == 1 and t5.focusLook == true and FO.stats().faces > 0, "story 28 labelled TOGGLE: no face call, the story 27 look", t5.matCalls)
    T.key(wr, D.down, INV_ACT)
    local r5 = T.tagged("r28r5")
    ok(r5.mat == nil and r5.bg and T.near(r5.bg[1], 0.2) and T.near(r5.bg[4], 0.5), "story 28 explicit row: its own colour after (solid + colour)")
    ok(T.agree("r28g6") and T.selected("r28r6"), "story 28 plain row: the selection while focused")
    -- To BACK: no row highlighted; BACK has its own look
    local facesBefore = FO.stats().faces
    T.key(wr, D.down, INV_ACT)
    local r6 = T.tagged("r28r6")
    ok(T.agree("#close:R28") and rec.lookRowId == nil and r6.mat == nil and r6.bg ~= nil, "story 28 to BACK: no row highlighted, the plain row its own colour")
    local nsel = 0
    for i = 1, 6 do if T.selected("r28r" .. i) then nsel = nsel + 1 end end
    ok(nsel == 0 and FO.stats().faces == facesBefore and T.tagged("#close:R28").focusLook == true, "story 28 to BACK: no row selected, BACK's own focus look (no face)")
    -- Re-style while focused: the next tick shows the highlight and the face again
    T.key(wr, D.up, INV_ACT); T.key(wr, D.up, INV_ACT); T.key(wr, D.up, INV_ACT); T.key(wr, D.up, INV_ACT); T.key(wr, D.up, INV_ACT)
    ok(T.agree("r28g2") and T.selected("r28r2"), "story 28 re-style: on row 2's gear")
    RS.setStyle(rows[2], { padding = "tight" })
    B.create{ id = "r28g2", place = { row = rows[2] }, icon = { icon = "gear" }, iconSize = 28, dimmed = false, onClick = T.rec("r28g2") }
    B.create{ id = "r28g2", place = { row = rows[2] }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r28g2") }
    ok(T.strip("r28r2") and not T.gearFaced("r28g2"), "story 28 re-style: the row and the gear show their own style at once")
    tick()
    ok(T.selected("r28r2") and T.gearFaced("r28g2") and rec.lookRowId == "r28r2", "story 28 re-style: the tick puts the highlight and the face back")
    local calls = T.tagged("r28r2").bgMatCalls
    tick()
    ok(T.tagged("r28r2").bgMatCalls == calls, "story 28 tick: nothing re-styled, no widget call for the row")
    -- ... and with focus inside the window (as in the game): the tick's own branch, not a refocus
    local hfd = wr.HasFocusedDescendants
    wr.HasFocusedDescendants = function() return true end
    local refocus = FO.stats().refocus
    RS.setStyle(rows[2], {})
    ok(T.strip("r28r2"), "story 28 re-style inside: the row shows its own strip at once")
    tick()
    ok(T.selected("r28r2") and rec.lookRowId == "r28r2" and FO.stats().refocus == refocus, "story 28 re-style inside: the tick puts the highlight back without a refocus")
    wr.HasFocusedDescendants = hfd
    -- Focused element removed while its row stays: the recovered element is in another row, the highlight follows
    B.remove(gears[2])
    ok(T.agree("r28g3") and T.selected("r28r3") and T.strip("r28r2") and rec.lookRowId == "r28r3", "story 28 removed: focus to the next row, the old row loses the highlight", SC.stats().focus)
    -- ... and the recovered element in the same row: the highlight stays
    T.key(wr, D.down, INV_ACT); T.key(wr, D.right, INV_ACT)
    ok(T.agree("r28c4"), "story 28 removed (same row): on the checkbox")
    CK.remove(cb4)
    ok(T.agree("r28g4") and T.selected("r28r4") and rec.lookRowId == "r28r4", "story 28 removed (same row): the gear, its row still highlighted")
    -- Row removed: no call on the dead row, nothing recorded for it
    local deadW = T.tagged("r28r4")
    local deadCalls = deadW.bgMatCalls
    RS.remove(rows[4])
    ok(rec.lookRowId ~= "r28r4" and deadW.bgMatCalls == deadCalls, "story 28 row removed: no call on it, not recorded", tostring(rec.lookRowId))
    -- A covering window: the lower one shows no highlight or face; back on return
    T.key(wr, D.up, INV_ACT)
    ok(T.agree("r28g3") and T.selected("r28r3"), "story 28 cover: on row 3")
    local R2 = SC.open{ id = "R28b" }
    ok(T.strip("r28r3") and T.gearOwn("r28g3") and rec.lookRowId == nil, "story 28 cover: the covered window's row and gear show their own look")
    SC.close(R2)
    ok(T.agree("r28g3") and T.selected("r28r3") and T.gearFaced("r28g3"), "story 28 cover: after the close, the highlight and the face come back")
    -- Widget call fails: one WARN, focus keeps working
    local w1 = T.tagged("r28r1")
    w1.throwBg = true
    local n0 = countLogs("the focus highlight failed")
    T.key(wr, D.up, INV_ACT)
    ok(T.agree("r28g1") and countLogs("the focus highlight failed") == n0 + 1 and rec.lookRowId == nil, "story 28 throwing setter: one WARN, focus moved")
    tick(); T.key(wr, D.down, INV_ACT); T.key(wr, D.up, INV_ACT)
    ok(T.agree("r28g1") and countLogs("the focus highlight failed") == n0 + 1, "story 28 throwing setter: logged once only")
    w1.throwBg = false
    tick()
    ok(T.selected("r28r1"), "story 28 throwing setter fixed: the tick highlights the row")
    -- Dimmed labelled buttons: a game-look one gets its undimmed game face, a plain-look one its hover colours
    local r7 = RS.create{ id = "r28r7", place = { list = L } }
    B.create{ id = "r28d7", label = "DIM", dimmed = true, place = { row = r7 }, onClick = T.rec("r28d7") }
    local r8 = RS.create{ id = "r28r8", place = { list = L } }
    B.create{ id = "r28p8", label = "PLAIN DIM", dimmed = true, style = { look = "plain" }, place = { row = r8 }, onClick = T.rec("r28p8") }
    local d7, p8 = T.tagged("r28d7"), T.tagged("r28p8")
    local g = theme.game
    local function same4(t, a, b) return T.near(t[a], t[b]) and T.near(t[a + 1], t[b + 1]) and T.near(t[a + 2], t[b + 2]) and T.near(t[a + 3], t[b + 3]) end
    ok(d7.mats and d7.mats[2] == T.STRIP and T.near(d7.content[1], T.DIM.r) and T.near(d7.content[5], T.DIM.r), "story 28 dimmed game button: its own look first (strip on hover, dim colours)")
    T.fire(T.CLICK, d7)
    ok(T.agree("r28d7") and d7.mats[1] == T.STRIP and d7.mats[2] == T.SEL and d7.focusLook == true
        and T.near(d7.content[1], g.text.r) and T.near(d7.content[5], g.textHover.r), "story 28 dimmed game button focused: the undimmed face (selection on hover, game text / hover colours)")
    T.fire(T.CLICK, p8)
    ok(T.agree("r28p8") and p8.colors and not same4(p8.colors, 1, 5) and p8.focusLook == true
        and T.near(p8.content[1], 1) and T.near(p8.content[5], 1) and T.near(p8.content[8], 1), "story 28 dimmed plain button focused: its hover colour, white content")
    ok(d7.mats[2] == T.STRIP and d7.focusLook == false and T.near(d7.content[1], T.DIM.r) and T.near(d7.content[5], T.DIM.r),
        "story 28 dimmed game button unfocused: its own dimmed look back (hover = normal, dim colours)")
    T.fire(T.CLICK, T.tagged("r28g1"))
    ok(T.agree("r28g1") and same4(p8.colors, 1, 5) and p8.focusLook == false and T.near(p8.content[1], T.DIM.r) and T.near(p8.content[5], T.DIM.r),
        "story 28 dimmed plain button unfocused: its own dimmed look back (hover = normal, dim colours)")
    -- Another mod's window on top (the shared Z registry): this window's tick clears its look; back once it is gone
    F.focus = T.tagged("r28g1").Btn
    tick()
    ok(T.selected("r28r1") and T.gearFaced("r28g1"), "story 28 interleaved: highlighted before")
    local ZK = SC._OPEN_Z_KEY
    local other = T.screenOf("R28").z + 100
    local before = ModRef:GetSharedVariable(ZK) or ""
    ModRef:SetSharedVariable(ZK, before .. "," .. other)
    tick()
    ok(T.strip("r28r1") and T.gearOwn("r28g1") and rec.lookRowId == nil, "story 28 interleaved: another mod's window on top: the row's strip, the gear's own look, nothing recorded")
    ModRef:SetSharedVariable(ZK, before)
    tick()
    ok(T.selected("r28r1") and T.gearFaced("r28g1") and rec.lookRowId == "r28r1", "story 28 interleaved: the other window gone: the highlight and the face are back")
    -- Window closed: nothing stays recorded
    SC.close(R)
    ok(rec.lookRowId == nil and rec.lookId == nil, "story 28 window closed: nothing recorded")
    -- The last focusable removed (close = false: no BACK): the window widget takes focus, the row loses the highlight
    local K2 = SC.open{ id = "R28k", close = false }
    local Lk = LS.create{ id = "r28kl", place = { screen = K2, corner = "top-left" }, size = { 300, 200 } }
    local rk = RS.create{ id = "r28kr", place = { list = Lk } }
    local gk = B.create{ id = "r28kg", place = { row = rk }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r28kg") }
    tick()
    local reck = C.windows["R28k"]
    ok(T.agree("r28kg") and T.selected("r28kr") and reck.lookRowId == "r28kr", "story 28 window widget: the gear focused, its row highlighted")
    B.remove(gk)
    ok(F.focus == T.screenOf("R28k") and T.strip("r28kr") and reck.lookRowId == nil, "story 28 window widget: the row's own strip, nothing recorded")
    tick()
    ok(T.strip("r28kr") and reck.lookRowId == nil, "story 28 window widget: still after a tick")
    SC.close(K2)
    -- Material missing: no highlight or face; assets.lua's one WARN; focus still moves
    require("nucleus.ui.assets")._reset()
    local SELP = "/Game/Graphics/MainMenu/Styles/Remaster/M_NN_CinematicSelection.M_NN_CinematicSelection"
    F.missing[SELP] = true
    local nW = countLogs("could not be loaded")
    local M2 = SC.open{ id = "R28m" }
    local wm = T.screenOf("R28m")
    local Lm = LS.create{ id = "r28ml", place = { screen = M2, corner = "top-left" }, size = { 300, 200 } }
    for i = 1, 2 do
        local r = RS.create{ id = "r28mr" .. i, place = { list = Lm } }
        B.create{ id = "r28mg" .. i, place = { row = r }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r28mg" .. i) }
    end
    tick()
    ok(T.agree("r28mg1") and not T.selected("r28mr1") and T.tagged("r28mg1").mats == nil and C.windows["R28m"].lookRowId == nil,
        "story 28 material missing: no row highlight, no face")
    ok(T.key(wm, D.down, INV_ACT) and T.agree("r28mg2"), "story 28 material missing: focus still moves")
    tick()
    ok(countLogs("could not be loaded") == nW + 1, "story 28 material missing: assets.lua's one WARN", countLogs("could not be loaded") - nW)
    SC.close(M2)
    F.missing[SELP] = nil
    require("nucleus.ui.assets")._reset()
    ok(FO.stats().faults == 0, "story 28: no fault in the focus path")
end
ok(#F.mids == T.mids28, "story 28 (switch off): no instance created", #F.mids - T.mids28)
theme.game.focusRowStrong = true

-- ---------------------------------------------------------------- core story 30: the strong full-row look
function T.strong(id) local m = T.matOf(id) return m ~= nil and m.__class == "MaterialInstanceDynamic" and m.Parent == T.SEL end
do
    local AS = require("nucleus.ui.assets")
    AS._reset()
    for k in pairs(F.mids) do F.mids[k] = nil end
    local g = theme.game
    local R = SC.open{ id = "R30" }
    local wr = T.screenOf("R30")
    local rec = C.windows["R30"]
    local L = LS.create{ id = "r30l", place = { screen = R, corner = "top-left" }, size = { 600, 400 } }
    local rows = {}
    for i = 1, 3 do
        rows[i] = RS.create{ id = "r30r" .. i, place = { list = L } }
        X.create{ id = "r30n" .. i, text = "MOD " .. i, place = { row = rows[i], fill = 4 } }
        B.create{ id = "r30g" .. i, place = { row = rows[i] }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r30g" .. i) }
    end
    tick()
    -- Strong on (default): r1 shows the instance (parent the selection, theme fill colours, focusRowTint), others the strip
    local mi = T.matOf("r30r1")
    ok(T.agree("r30g1") and T.strong("r30r1") and T.strip("r30r2") and T.strip("r30r3") and rec.lookRowId == "r30r1",
        "story 30 open: the focused row shows the strong instance, the others the worn strip", tostring(mi and mi.__class))
    local function colourIs(c, t) return c ~= nil and T.near(c.R, t.r) and T.near(c.G, t.g) and T.near(c.B, t.b) and T.near(c.A, t.a) end
    ok(mi and colourIs(mi.params.CinematicBaseColor, g.focusRowColors.CinematicBaseColor) and colourIs(mi.params.CinematicWearColor, g.focusRowColors.CinematicWearColor),
        "story 30 open: the instance's fill colours are the theme's")
    ok(mi and mi.name == "None" and mi.flags == 1 and mi.wc == T.tagged("r30r1"), "story 30 open: unnamed, transient, the row as world context")
    ok(T.tintIs(T.tagged("r30r1").matTint, g.focusRowTint) and T.gearFaced("r30g1"), "story 30 open: in focusRowTint; the gear's face unchanged")
    -- DOWN: r2 strong, r1 its own worn strip (same tint, padding); the instance reused
    local r1w = T.tagged("r30r1")
    local pad = r1w.pad
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r30g2") and T.strong("r30r2") and T.strip("r30r1") and rec.lookRowId == "r30r2",
        "story 30 Down: row 2 strong, row 1 its worn strip")
    ok(T.tintIs(r1w.matTint, g.rowTint) and r1w.pad == pad, "story 30 Down: row 1's strip in its own tint and padding")
    T.key(wr, D.down, INV_ACT); T.key(wr, D.up, INV_ACT); T.key(wr, D.up, INV_ACT)
    ok(T.agree("r30g1") and T.strong("r30r1") and #F.mids == 1 and T.matOf("r30r1") == mi, "story 30 reused: one instance across moves", #F.mids)
    -- Re-style while focused: the tick puts the strong look back (same instance)
    RS.setStyle(rows[1], { padding = "tight" })
    ok(T.strip("r30r1"), "story 30 re-style: the row's own strip at once")
    tick()
    ok(T.strong("r30r1") and #F.mids == 1, "story 30 re-style: the tick puts the strong look back")
    -- Instance collected (map change, GC): inside the OnNav hook the plain selection; the tick makes a new one
    kill(mi)
    T.key(wr, D.down, INV_ACT)
    ok(T.agree("r30g2") and T.selected("r30r2") and T.tintIs(T.tagged("r30r2").matTint, g.rowTint) and #F.mids == 1,
        "story 30 in a hook, no instance: the plain selection in rowTint, nothing created", #F.mids)
    tick()
    ok(T.strong("r30r2") and #F.mids == 2 and T.matOf("r30r2") == F.mids[2] and T.tintIs(T.tagged("r30r2").matTint, g.focusRowTint),
        "story 30 collected: the tick makes a new instance and upgrades the row", #F.mids)
    local n2 = T.tagged("r30r2").bgMatCalls or 0
    tick()
    ok((T.tagged("r30r2").bgMatCalls or 0) == n2, "story 30 tick: strong already, no widget call")
    -- A click (a script hook) on another row with none alive: plain now, strong on the tick
    kill(F.mids[2])
    T.fire(T.CLICK, T.tagged("r30g3"))
    ok(T.agree("r30g3") and T.selected("r30r3") and T.strip("r30r2") and #F.mids == 2, "story 30 click, no instance: the plain selection, nothing created in the hook", #F.mids)
    tick()
    ok(T.strong("r30r3") and #F.mids == 3, "story 30 click: the tick upgrades it", #F.mids)
    -- Unfocus / close: the row's own background, no call on a dead row
    local r3w = T.tagged("r30r3")
    T.key(wr, D.down, INV_ACT)
    ok(T.agree("#close:R30") and T.strip("r30r3") and rec.lookRowId == nil, "story 30 to BACK: the row's own strip")
    T.key(wr, D.up, INV_ACT)
    ok(T.agree("r30g3") and T.strong("r30r3"), "story 30 back up: strong again")
    local calls = r3w.bgMatCalls
    RS.remove(rows[3])
    ok(rec.lookRowId ~= "r30r3" and r3w.bgMatCalls == calls, "story 30 row removed: no call on it", tostring(rec.lookRowId))
    SC.close(R)
    ok(rec.lookRowId == nil, "story 30 window closed: nothing recorded")
    -- Creation fails (throws, returns nothing, a parameter setter throws): the plain selection, one WARN, not retried
    for _, mode in ipairs({ "create", "nil", "set" }) do
        AS._reset()
        C.forgetWarning("asset:focus row")
        F.midFail = mode
        local nW = countLogs("strong look")
        local made = #F.mids
        local W = SC.open{ id = "R30" .. mode }
        local Lf = LS.create{ id = "r30fl" .. mode, place = { screen = W, corner = "top-left" }, size = { 300, 200 } }
        for i = 1, 2 do
            local r = RS.create{ id = "r30f" .. mode .. i, place = { list = Lf } }
            B.create{ id = "r30fg" .. mode .. i, place = { row = r }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r30fg" .. mode .. i) }
        end
        tick()
        ok(T.agree("r30fg" .. mode .. "1") and T.selected("r30f" .. mode .. "1") and T.tintIs(T.tagged("r30f" .. mode .. "1").matTint, g.rowTint),
            "story 30 creation fails (" .. mode .. "): the plain selection")
        tick(); T.key(T.screenOf("R30" .. mode), D.down, INV_ACT); tick()
        ok(T.agree("r30fg" .. mode .. "2") and T.selected("r30f" .. mode .. "2") and countLogs("strong look") == nW + 1
            and #F.mids - made == (mode == "set" and 1 or 0), "story 30 creation fails (" .. mode .. "): one WARN, not tried again", countLogs("strong look") - nW)
        SC.close(W)
    end
    F.midFail = nil
    -- Inside core's control dispatch (C.inDispatch), outside onNav / F.used, with none alive: the plain selection, nothing
    -- made; outside it the tick makes one
    AS._reset()
    do
        local W = SC.open{ id = "R30d" }
        local Ld = LS.create{ id = "r30dl", place = { screen = W, corner = "top-left" }, size = { 300, 200 } }
        local gd = {}
        for i = 1, 2 do
            local r = RS.create{ id = "r30dr" .. i, place = { list = Ld } }
            gd[i] = B.create{ id = "r30dg" .. i, place = { row = r }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r30dg" .. i) }
        end
        tick()
        ok(T.agree("r30dg1") and T.strong("r30dr1"), "story 30 dispatch: row 1 strong first")
        kill(T.matOf("r30dr1"))
        local made = #F.mids
        C.inDispatch = 1
        B.remove(gd[1])
        C.inDispatch = 0
        ok(T.agree("r30dg2") and T.selected("r30dr2") and T.tintIs(T.tagged("r30dr2").matTint, g.rowTint) and #F.mids == made,
            "story 30 dispatch, no instance: the recovered row gets the plain selection, nothing made", #F.mids - made)
        tick()
        ok(T.strong("r30dr2") and #F.mids == made + 1, "story 30 dispatch: the tick makes one and upgrades the row", #F.mids - made)
        SC.close(W)
    end
    -- Material missing: no row highlight (0.12.1 behaviour), assets.lua's WARN, no instance
    AS._reset()
    local SELP = "/Game/Graphics/MainMenu/Styles/Remaster/M_NN_CinematicSelection.M_NN_CinematicSelection"
    F.missing[SELP] = true
    C.forgetWarning("asset:mat:selection")
    local nW = countLogs("could not be loaded")
    local made = #F.mids
    local M2 = SC.open{ id = "R30m" }
    local Lm = LS.create{ id = "r30ml", place = { screen = M2, corner = "top-left" }, size = { 300, 200 } }
    local rm = RS.create{ id = "r30mr", place = { list = Lm } }
    B.create{ id = "r30mg", place = { row = rm }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r30mg") }
    tick()
    ok(T.agree("r30mg") and T.strip("r30mr") and C.windows["R30m"].lookRowId == nil and #F.mids == made, "story 30 material missing: no row highlight, no instance")
    ok(countLogs("could not be loaded") == nW + 1, "story 30 material missing: assets.lua's one WARN", countLogs("could not be loaded") - nW)
    SC.close(M2)
    F.missing[SELP] = nil
    AS._reset()
    ok(FO.stats().faults == 0, "story 30: no fault in the focus path")
end

-- ---------------------------------------------------------------- core story 36: the focus band follows the mouse
-- The platform cursor (WidgetLayoutLibrary:GetMousePositionOnPlatform): F.mouse = { x, y }; F.mouseFail "throw" or
-- "nil". T.hover(w) moves nothing: it is the row's OnMouseEnter calling <Core>_OnHover (the hooks run).
F.mouse = { x = 10, y = 10 }
F.objects["/Script/UMG.Default__WidgetLayoutLibrary"].GetMousePositionOnPlatform = function()
    if F.mouseFail == "throw" then error("GetMousePositionOnPlatform: boom") end
    if F.mouseFail == "nil" then return nil end
    return vec(F.mouse.x, F.mouse.y)
end
T.HOVER = "WBP_NucleusRow_C:Nucleus_OnHover"
function T.hover(w) fireHook(T.HOVER, w) end
function T.move(dx, dy) F.mouse = { x = F.mouse.x + (dx or 37), y = F.mouse.y + (dy or 41) } end
function T.ign() return FO.stats().hoverIgnored end
do
    local AS = require("nucleus.ui.assets")
    AS._reset()
    local R = SC.open{ id = "R36" }
    local wr = T.screenOf("R36")
    local rec = C.windows["R36"]
    local L = LS.create{ id = "r36l", place = { screen = R, corner = "top-left" }, size = { 600, 400 } }
    local rows = {}
    for i = 1, 6 do
        rows[i] = RS.create{ id = "r36r" .. i, place = { list = L } }
        X.create{ id = "r36n" .. i, text = "MOD " .. i, place = { row = rows[i], fill = 4 } }
        B.create{ id = "r36g" .. i, place = { row = rows[i] }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r36g" .. i) }
    end
    -- row 7: two focusables (a gear, a checkbox); row 8: text only (no focusable)
    rows[7] = RS.create{ id = "r36r7", place = { list = L } }
    B.create{ id = "r36g7", place = { row = rows[7] }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r36g7") }
    CK.create{ id = "r36c7", place = { row = rows[7] }, onChange = T.rec("r36c7") }
    rows[8] = RS.create{ id = "r36r8", place = { list = L } }
    X.create{ id = "r36n8", text = "NO CONTROL", place = { row = rows[8], fill = 4 } }
    tick()
    ok(hookCount("Nucleus_OnHover") == 1 and FO.stats().hoverHooked == true, "story 36: one hook on the row's <Core>_OnHover, registered from the poll", hookCount("Nucleus_OnHover"))
    ok(T.agree("r36g1") and T.strong("r36r1"), "story 36 setup: r1's gear focused, r1 strong")
    -- Hover a row: r4's gear takes keyboard focus and the focus look, r4 the band, r1 its own strip; no scroll, no load
    local lw = T.tagged("r36l")
    local scrolls, loads, gets, hovers = #lw.Scroll.into, AS.stats.loads, F.getAssets, FO.stats().hovers
    T.move()
    T.hover(T.tagged("r36r4"))
    ok(T.agree("r36g4") and rec.focusId == "r36g4" and T.strong("r36r4") and T.strip("r36r1") and rec.lookRowId == "r36r4",
        "story 36 hover: r4's gear holds focus, r4 the band, r1 its own strip", SC.stats().focus)
    ok(T.gearFaced("r36g4") and T.gearOwn("r36g1"), "story 36 hover: the focus look moved with it")
    ok(#lw.Scroll.into == scrolls and FO.stats().hovers == hovers + 1, "story 36 hover: the list is not scrolled", #lw.Scroll.into - scrolls)
    ok(AS.stats.loads == loads and F.getAssets == gets, "story 36 hover: no asset load inside the hook", AS.stats.loads - loads)
    ok(C.inDispatch == 0, "story 36 hover: the dispatch depth is back to 0", C.inDispatch)
    -- Keys continue from there (the pointer moved a little inside r4 first: no enter)
    T.move(3, 2)
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r36g5") and T.strong("r36r5") and T.strip("r36r4"), "story 36 keys continue: DOWN after the hover goes to r5")
    -- Pointer still: an enter at the position of the last key (the list scrolled under the pointer) is ignored
    local ign = T.ign()
    T.hover(T.tagged("r36r2"))
    ok(T.agree("r36g5") and T.strong("r36r5") and T.ign() == ign + 1, "story 36 pointer still: an enter at the key's pointer position is ignored")
    -- Same row: nothing changes
    local n5 = T.tagged("r36r5").bgMatCalls or 0
    local moves = FO.stats().moves
    T.move()
    T.hover(T.tagged("r36r5"))
    ok(T.agree("r36g5") and (T.tagged("r36r5").bgMatCalls or 0) == n5 and FO.stats().moves == moves and T.ign() == ign + 2,
        "story 36 same row: nothing changes")
    -- Typing: the slider's text box (not a model element) holds keyboard focus: the box keeps it
    local box = { __alive = true }
    local before = F.focus
    F.focus = box
    T.move()
    T.hover(T.tagged("r36r2"))
    ok(F.focus == box and rec.focusId == "r36g5" and T.strong("r36r5") and T.ign() == ign + 3, "story 36 typing: a text box keeps focus, nothing changes")
    -- ... and keyboard focus outside the window: the same
    F.focus = PC
    T.move()
    T.hover(T.tagged("r36r2"))
    ok(rec.focusId == "r36g5" and T.ign() == ign + 4, "story 36 focus outside the window: nothing changes")
    F.focus = before
    ok(T.agree("r36g5"), "story 36 typing: focus back on r5's gear")
    -- Not ours: another mod's row, a stale widget, a widget that isn't the row's live one, a row without a focusable,
    -- a row of a non-screen host, a covered window's row, off the game thread
    ign = T.ign()
    T.move()
    local other = tagged(widget("WBP_NucleusRow_C", "/Engine/Transient.WBP_NucleusRow_C_other"))
    other.tag = "nucleus:OtherMod:r36r2"
    T.hover(other)
    local copy = tagged(widget("WBP_NucleusRow_C", "/Engine/Transient.WBP_NucleusRow_C_copy"))
    copy.tag = "nucleus:TestMod:r36r2"
    T.hover(copy)
    kill(copy)
    T.hover(copy)
    local untagged = widget("WBP_NucleusRow_C", "/Engine/Transient.WBP_NucleusRow_C_untagged")
    T.hover(untagged)
    T.hover(T.tagged("r36r8"))
    T.hover(T.tagged("r36n2")) -- a text's tag, not a row
    local LM = LS.create{ id = "r36ml", place = { host = "menu", corner = "top-left" }, size = { 300, 200 } }
    local rmenu = RS.create{ id = "r36mr", place = { list = LM } }
    B.create{ id = "r36mg", label = "MENU", place = { row = rmenu }, onClick = T.rec("r36mg") }
    tick()
    T.hover(T.tagged("r36mr"))
    ok(T.agree("r36g5") and T.strong("r36r5") and T.ign() == ign + 7 and FO.stats().faults == 0, "story 36 not ours: another mod's row, a copy, a stale or untagged widget, a row without a focusable, a text, a menu row: ignored", T.ign() - ign)
    LS.remove(LM)
    -- Another mod's window on top (the shared Z registry) while keyboard focus is still here: ignored
    T.move()
    local ZK = SC._OPEN_Z_KEY
    local zBefore = ModRef:GetSharedVariable(ZK) or ""
    ModRef:SetSharedVariable(ZK, zBefore .. "," .. (T.screenOf("R36").z + 100))
    local ignZ = T.ign()
    F.focus = T.btn("r36g5")
    T.hover(T.tagged("r36r2"))
    ok(rec.focusId == "r36g5" and F.focus == T.btn("r36g5") and T.ign() == ignZ + 1, "story 36 another mod's window on top: ignored")
    ModRef:SetSharedVariable(ZK, zBefore)
    tick()
    ok(T.agree("r36g5"), "story 36 another mod's window gone: still on r5")
    T.move()
    local R2 = SC.open{ id = "R36b" }
    local L2 = LS.create{ id = "r36bl", place = { screen = R2, corner = "top-left" }, size = { 300, 200 } }
    local rb = RS.create{ id = "r36br", place = { list = L2 } }
    B.create{ id = "r36bg", place = { row = rb }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r36bg") }
    local rb2 = RS.create{ id = "r36br2", place = { list = L2 } }
    B.create{ id = "r36bg2", place = { row = rb2 }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r36bg2") }
    tick()
    ok(T.agree("r36bg"), "story 36 covered: the top window holds focus")
    -- the window opened under a still pointer: an enter on its second row at that position is ignored too
    local ign2 = T.ign()
    T.hover(T.tagged("r36br2"))
    ok(T.ign() == ign2 + 1 and T.agree("r36bg"), "story 36 pointer still: a window opened under the pointer ignores the enter")
    T.move()
    T.hover(T.tagged("r36r2"))
    ok(T.agree("r36bg") and rec.focusId == "r36g5" and T.ign() == ign2 + 2, "story 36 covered: a covered window's row is ignored")
    local deref = Nucleus_Deref
    Nucleus_Deref = function() error("Nucleus_Deref: called off the game thread") end
    T.hover(T.tagged("r36br"))
    Nucleus_Deref = deref
    ok(T.agree("r36bg") and T.ign() == ign2 + 3, "story 36 off the game thread: ignored")
    SC.close(R2)
    ok(T.agree("r36g5") and T.strong("r36r5"), "story 36 covered: back on r5 after the close")
    -- Column: focus in column 2 of a 2-focusable row; hover a 1-focusable row: its only focusable
    T.move()
    T.hover(T.tagged("r36r7"))
    ok(T.agree("r36g7") and T.strong("r36r7"), "story 36 column: a hover lands on column 1 from column 1")
    ok(T.key(wr, D.right, INV_ACT) and T.agree("r36c7"), "story 36 column: RIGHT to the checkbox (column 2)")
    T.move()
    T.hover(T.tagged("r36r6"))
    ok(T.agree("r36g6") and T.strong("r36r6") and T.strip("r36r7"), "story 36 column: from column 2, a 1-focusable row gives its only focusable")
    -- Inside the hook, no instance alive: the plain band now (the material is cached), no load; strong on the tick
    kill(T.matOf("r36r6"))
    loads, gets = AS.stats.loads, F.getAssets
    local made = #F.mids
    T.move()
    T.hover(T.tagged("r36r3"))
    ok(T.agree("r36g3") and T.selected("r36r3") and T.tintIs(T.tagged("r36r3").matTint, theme.game.rowTint) and #F.mids == made
        and AS.stats.loads == loads and F.getAssets == gets, "story 36 in the hook, no instance: the plain band, nothing made or loaded", #F.mids - made)
    tick()
    ok(T.strong("r36r3") and #F.mids == made + 1, "story 36 in the hook: the tick makes the strong band", #F.mids - made)
    -- ... and nothing cached at all (assets reset): no load in the hook, no band yet (r3 loses its band; its strip needs
    -- the material too: a plain colour until it is re-styled); the tick completes the band and the face
    AS._reset()
    gets = F.getAssets
    T.move()
    T.hover(T.tagged("r36r4"))
    ok(T.agree("r36g4") and F.getAssets == gets and not T.selected("r36r4") and not T.strong("r36r4") and not T.strong("r36r3") and not T.selected("r36r3"),
        "story 36 in the hook, nothing cached: focus moves, no GetAsset, no band yet", F.getAssets - gets)
    tick()
    ok(T.strong("r36r4") and T.gearFaced("r36g4") and rec.lookRowId == "r36r4", "story 36 nothing cached: the tick completes the band and the face")
    T.key(wr, D.up, INV_ACT)
    -- Position unreadable (throws / returns nothing), now or at the key: the hover applies, even without a move
    local steps = { throw = { "r36g2", "r36r4", "r36g3", "r36r5" }, ["nil"] = { "r36g4", "r36r6", "r36g5", "r36r1" } }
    for _, mode in ipairs({ "throw", "nil" }) do
        local s = steps[mode]
        F.mouseFail = nil
        T.key(wr, D.up, INV_ACT)
        F.mouseFail = mode
        T.hover(T.tagged(s[2]))
        ok(SC.stats().focus == s[2]:gsub("r36r", "r36g") and T.strong(s[2]), "story 36 position unreadable now (" .. mode .. "): the hover applies", SC.stats().focus)
        T.key(wr, D.up, INV_ACT)
        ok(T.agree(s[3]), "story 36 position unreadable (" .. mode .. "): UP", SC.stats().focus)
        T.hover(T.tagged(s[4]))
        ok(SC.stats().focus == s[4]:gsub("r36r", "r36g") and T.strong(s[4]), "story 36 position unreadable at the key (" .. mode .. "): the hover applies", SC.stats().focus)
    end
    F.mouseFail = nil
    -- Body fails: one WARN, counted, the depth counters back
    local faults = FO.stats().faults
    local nW = countLogs("hover handling failed")
    FO._onHover({ get = function() error("ctx: boom") end })
    FO._onHover({ get = function() error("ctx: boom") end })
    ok(FO.stats().faults == faults + 2 and countLogs("hover handling failed") == nW + 1 and C.inDispatch == 0, "story 36 body fails: one WARN, each counted", FO.stats().faults - faults)
    T.move()
    T.hover(T.tagged("r36r5"))
    ok(T.agree("r36g5") and T.strong("r36r5"), "story 36 body fails: the next hover works")
    -- Old pak: no <Core>_OnHover on the row class: one WARN from RegisterHook, keys and clicks unchanged
    local S36 = FO._S
    local rh = RegisterHook
    RegisterHook = function(p, f) if p:find("_OnHover", 1, true) then error("RegisterHook: function not found") end return rh(p, f) end
    S36.hoverHooked = false
    local nH, nWarn = hookCount("Nucleus_OnHover"), countLogs("window rows: RegisterHook")
    tick(); tick()
    RegisterHook = rh
    ok(S36.hoverHooked == true and hookCount("Nucleus_OnHover") == nH and countLogs("window rows: RegisterHook") == nWarn + 1,
        "story 36 old pak: one WARN, tried once", countLogs("window rows: RegisterHook") - nWarn)
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r36g6"), "story 36 old pak: keys unchanged")
    T.fire(T.CLICK, T.tagged("r36g2"))
    ok(T.agree("r36g2") and T.strong("r36r2"), "story 36 old pak: clicks unchanged")
    -- A click records the pointer: an enter at that position (the clicked row scrolled into view) is ignored
    T.move()
    T.fire(T.CLICK, T.tagged("r36g6"))
    local ignC = T.ign()
    T.hover(T.tagged("r36r3"))
    ok(T.agree("r36g6") and T.strong("r36r6") and T.ign() == ignC + 1, "story 36 click: an enter at the click's pointer position is ignored", SC.stats().focus)
    -- An enter into the focused row records the pointer: a following enter at that position is ignored
    T.move()
    T.hover(T.tagged("r36r6"))
    T.hover(T.tagged("r36r2"))
    ok(T.agree("r36g6") and T.strong("r36r6") and T.ign() == ignC + 3, "story 36 same row: the pointer is recorded, a following enter at it is ignored", SC.stats().focus)
    -- The window widget itself holds focus: the hover moves focus to the hovered row's focusable
    F.focus = T.screenOf("R36")
    T.move()
    T.hover(T.tagged("r36r4"))
    ok(T.agree("r36g4") and T.strong("r36r4") and T.strip("r36r6") and rec.lookRowId == "r36r4", "story 36 window holds focus: the hover moves it to the row's focusable", SC.stats().focus)
    SC.close(R)
    ok(rec.lookRowId == nil, "story 36 window closed: nothing recorded")
end

-- ---------------------------------------------------------------- core story 39: a focus chip on the focused control
-- A chip is a button's (a checkbox's) face from an instance of the selection material in the chip colours (normal and
-- hover brush), its content in the ink (story 41), an icon-only one's Btn scaled by s and its Content by 1 / s; a choice's or a
-- slider's Background from that instance (a slider's number in the ink through its box's content tint). One input mode per
-- Lua state (FO._mode): keys from a navigation key, mouse from a real pointer move into a row and from every click.
-- T.chipMid(id): the instance a control shows, or nil.
function T.isChipMid(m)
    if not (m and m.__class == "MaterialInstanceDynamic" and m.Parent == T.SEL) then return false end
    local c, t = m.params.CinematicBaseColor, theme.game.focusChipColors.CinematicBaseColor
    return c ~= nil and T.near(c.R, t.r) and T.near(c.G, t.g) and T.near(c.B, t.b)
end
function T.chipMid(id)
    local w = T.tagged(id)
    if not w then return nil end
    if w.Btn then return (w.lastFace == "mats" and w.mats and T.isChipMid(w.mats[1]) and w.mats[2] == w.mats[1]) and w.mats[1] or nil end
    return T.isChipMid(w.mat) and w.mat or nil
end
function T.scaleIs(i, sx, sy) return i.scale ~= nil and T.near(i.scale[1], sx) and T.near(i.scale[2], sy or sx) end
-- A chipped button: the instance as both brushes, the focus look on, content in the chip's ink (story 41:
-- theme.game.focusChipInk), scale s (1: none set or 1).
function T.inkIs(c, i) local k = theme.game.focusChipInk; return T.near(c[i], k.r) and T.near(c[i + 1], k.g) and T.near(c[i + 2], k.b) and T.near(c[i + 3], k.a) end
-- Core story 42: a checkbox's content keeps its own colours on the chip (dimmed, the game's text / text hover, or white).
function T.colIs(c, i, k) return T.near(c[i], k.r) and T.near(c[i + 1], k.g) and T.near(c[i + 2], k.b) and T.near(c[i + 3], k.a) end
function T.ownIs(el, c)
    local n, h = theme.white, theme.white
    if el.dimmed then n, h = theme.dimmed, theme.dimmed elseif el.gameFace then n, h = theme.game.text, theme.game.textHover end
    return T.colIs(c, 1, n) and T.colIs(c, 5, h)
end
function T.contentOk(id, c)
    if C.els[id].kind == "checkbox" then return T.ownIs(C.els[id], c) end
    return T.inkIs(c, 1) and T.inkIs(c, 5)
end
-- Core story 42: a checkbox's IconBack shown in theme.game.focusChipBack (true), hidden or never shown (false).
function T.backShown(w)
    local b, k = w.back, theme.game.focusChipBack
    return b ~= nil and b[1] == true and T.near(b[2], k.r) and T.near(b[3], k.g) and T.near(b[4], k.b) and T.near(b[5], k.a)
end
function T.backHidden(w) return w.back == nil or w.back[1] == false end
function T.chipped(id, s)
    local w = T.tagged(id)
    if not (w and T.chipMid(id) and w.focusLook == true and w.content) then return false end
    if not T.contentOk(id, w.content) then return false end
    if C.els[id].kind == "checkbox" and not (T.noBackOk or T.backShown(w)) then return false end
    if C.els[id].kind ~= "checkbox" and w.back ~= nil then return false end -- only a checkbox ever shows it
    if s and s ~= 1 then return T.scaleIs(w.Btn, s) and T.scaleIs(w.Content, 1 / s) end
    return w.Btn.scale == nil or T.scaleIs(w.Btn, 1)
end
-- A button without the chip: no chip brush, render scales 1 (or never set).
function T.plainScale(w) return (w.Btn.scale == nil or T.scaleIs(w.Btn, 1)) and (w.Content.scale == nil or T.scaleIs(w.Content, 1)) end
function T.noChip(id)
    local w = T.tagged(id)
    return w ~= nil and T.chipMid(id) == nil and (not w.Btn or T.plainScale(w)) and (C.els[id] and C.els[id].chipOn == nil) and T.backHidden(w)
end
-- An element whose live widget shows a chip (a closed window's elements keep no widget: a new one starts without it).
function T.anyChip() for _, el in pairs(C.els) do if el.chipOn and T.tagged(el.id) then return el.id end end return nil end
-- The checkbox's own look (game look, icon only: no face, the game's text colours) after a chip.
function T.cbOwn(id)
    local w = T.tagged(id)
    return w ~= nil and w.colors ~= nil and w.colors[4] == 0 and w.focusLook == false and T.plainScale(w)
        and T.near(w.content[1], theme.game.text.r) and C.els[id].chipOn == nil and T.backHidden(w)
end
-- A slider's number box content tint: the chip's ink (theme.game.focusChipInk) over the game's text colour, or nil.
function T.inkNumber(id)
    local w = T.tagged(id)
    local t, c, k = w and w.Background and w.Background.tint, theme.game.text, theme.game.focusChipInk
    return t ~= nil and T.near(t.R * c.r, k.r) and T.near(t.G * c.g, k.g) and T.near(t.B * c.b, k.b) and T.near(t.A, k.a)
end
T.S39 = 36 / 28 -- iconSize 28, p = 4 (listRowPadX / Y 4, tight gap 8): (28 + 2 * 4) / 28
do
    -- Story 39's fakes: a row's Background Border (SetPadding) and a slider's (SetContentColorAndOpacity).
    local WBL = F.objects["/Script/UMG.Default__WidgetBlueprintLibrary"]
    local base = WBL.Create
    WBL.Create = function(self, world, c, owner)
        local w = base(self, world, c, owner)
        if w.__class == "WBP_NucleusRow_C" then
            w.Background = { SetPadding = function(s, m) s.pad = { m.Left, m.Top, m.Right, m.Bottom }; s.calls = (s.calls or 0) + 1 end }
            -- as the Blueprint: the background functions set the same padding all round
            local sbm, sbp = w.SetBackgroundMaterial, w.SetBackgroundPadding
            function w:SetBackgroundMaterial(m, r, g, b, a, p) self.Background.pad = { p, p, p, p }; return sbm(self, m, r, g, b, a, p) end
            function w:SetBackgroundPadding(p) self.Background.pad = { p, p, p, p }; return sbp(self, p) end
        elseif w.__class == "WBP_NucleusSlider_C" then
            w.Background = { SetContentColorAndOpacity = function(s, col)
                if s.throw then error("SetContentColorAndOpacity: boom") end
                s.tint = col
            end }
            local sfl = w.SetFocusLook
            function w:SetFocusLook(on) self.Background.tint = nil; return sfl(self, on) end -- the generated tint replaces ours
        end
        return w
    end
end
do
    local AS = require("nucleus.ui.assets")
    AS._reset()
    FO._noChip = false
    local faults0 = FO.stats().faults
    C.forgetWarning("focus chip")
    local g = theme.game
    FO._input("keys")
    local R = SC.open{ id = "R39" }
    local wr = T.screenOf("R39")
    local rec = C.windows["R39"]
    local L = LS.create{ id = "r39l", place = { screen = R, corner = "top-left" }, size = { 600, 500 } }
    local rows = {}
    for i = 1, 4 do -- a checkbox and a gear in an unstyled list row (listRowPad 4) with a tight gap (8): p = 4
        rows[i] = RS.create{ id = "r39r" .. i, place = { list = L } }
        CK.create{ id = "r39c" .. i, place = { row = rows[i] }, onChange = T.rec("r39c" .. i) }
        X.create{ id = "r39n" .. i, text = "MOD " .. i, place = { row = rows[i], fill = 4 } }
        B.create{ id = "r39g" .. i, place = { row = rows[i] }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r39g" .. i) }
    end
    rows[5] = RS.create{ id = "r39r5", place = { list = L } }
    CH.create{ id = "r39ch", options = { "LOW", "MID", "HIGH" }, selected = 1, place = { row = rows[5] }, onChange = T.rec("r39ch") }
    rows[6] = RS.create{ id = "r39r6", place = { list = L } }
    SL.create{ id = "r39sl", min = 0, max = 10, step = 1, defaultValue = 5, place = { row = rows[6] }, onChange = T.rec("r39sl") }
    rows[7] = RS.create{ id = "r39r7", place = { list = L }, gap = "compact" }
    B.create{ id = "r39g7", place = { row = rows[7] }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r39g7") }
    rows[8] = RS.create{ id = "r39r8", place = { list = L } }
    B.create{ id = "r39b8", label = "TOGGLE", place = { row = rows[8] }, onClick = T.rec("r39b8") }
    B.create{ id = "r39lone", place = { screen = R, corner = "bottom-right" }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r39lone") }
    local rowOff = RS.create{ id = "r39off", place = { screen = R, corner = "top-right" } } -- a row outside a list
    X.create{ id = "r39offt", text = "NOT IN A LIST", place = { row = rowOff } }
    -- Plain-look list rows (the solid background branch): unstyled (padding 0) and padded (tight 4)
    local rp0 = RS.create{ id = "r39p0", place = { list = L }, style = { look = "plain" } }
    X.create{ id = "r39p0t", text = "PLAIN", place = { row = rp0 } }
    local rp4 = RS.create{ id = "r39p4", place = { list = L }, style = { look = "plain", padding = "tight" } }
    X.create{ id = "r39p4t", text = "PLAIN 4", place = { row = rp4 } }
    tick()
    -- Taller list rows: the row's Background padding is its style's (0) plus listRowPadX / listRowPadY; not outside a list
    local rb = T.tagged("r39r2").Background
    ok(theme.listRowPadX == 4 and theme.listRowPadY == 4 and rb.pad and rb.pad[1] == 4 and rb.pad[2] == 4 and rb.pad[3] == 4 and rb.pad[4] == 4,
        "story 39 list row: its padding grows by listRowPadX / listRowPadY", rb.pad and table.concat(rb.pad, ","))
    local op = T.tagged("r39off").Background.pad
    ok((op == nil or (op[1] == 0 and op[2] == 0)) and select(2, X._rowPad(C.els["r39off"])) == 0, "story 39 a row outside a list: no extra padding")
    local function padIs(id, p) local q = T.tagged(id).Background.pad return q ~= nil and q[1] == p and q[2] == p and q[3] == p and q[4] == p end
    ok(padIs("r39p0", 4) and padIs("r39p4", 8), "story 39 plain list rows: style padding plus listRowPadX / Y on the first build",
        table.concat(T.tagged("r39p0").Background.pad or {}, ",") .. " / " .. table.concat(T.tagged("r39p4").Background.pad or {}, ","))
    X._backgroundStyle(C.els["r39p0"], T.tagged("r39p0"), false)
    X._backgroundStyle(C.els["r39p4"], T.tagged("r39p4"), false)
    ok(padIs("r39p0", 4) and padIs("r39p4", 8) and T.tagged("r39p4").mat == nil, "story 39 plain list rows: the same after a re-style (solid background)")
    -- Keys on a row: the window opens (keys mode) on r1's checkbox: the chip (its own instance, not the band's), the ink, scaled
    local cw = T.tagged("r39c1")
    local mid = T.chipMid("r39c1")
    ok(FO._mode() == "keys" and T.agree("r39c1") and T.chipped("r39c1", T.S39) and T.strong("r39r1"), "story 39 open in keys mode: r1's checkbox has the chip (scale s, content 1 / s), r1 the band")
    ok(T.tagged("r39r1").Background.pad[2] == 4, "story 39 band: the focused list row keeps its taller padding")
    ok(mid and mid ~= T.matOf("r39r1") and mid.name == "None" and mid.flags == 1 and T.tintIs({ cw.mats[3], cw.mats[4], cw.mats[5], cw.mats[6] }, g.focusChipTint),
        "story 39 open: an unnamed transient instance of its own, in focusChipTint")
    local cbase = mid and mid.params.CinematicWearColor
    ok(cbase and T.near(cbase.R, g.focusChipColors.CinematicWearColor.r), "story 39 open: the chip's wear colour is the theme's")
    -- Story 41: one chip colour, #6dd5ed in linear, drives the instance's base and wear and the solid chip
    do
        local function lin(c) c = c / 255; return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
        local function isCol(c, k) return c ~= nil and T.near(c.R or c.r, k.r) and T.near(c.G or c.g, k.g) and T.near(c.B or c.b, k.b) and T.near(c.A or c.a, k.a) end
        local k = g.focusChipColor
        ok(math.abs(k.r - lin(0x6d)) < 1e-3 and math.abs(k.g - lin(0xd5)) < 1e-3 and math.abs(k.b - lin(0xed)) < 1e-3 and k.a == 1,
            "story 41 focusChipColor is #6dd5ed in linear", string.format("%.4f %.4f %.4f", k.r, k.g, k.b))
        ok(mid and isCol(mid.params.CinematicBaseColor, k) and isCol(mid.params.CinematicWearColor, k), "story 41 the chip instance's base and wear are focusChipColor")
        ok(isCol(g.focusChipColors.CinematicBaseColor, k) and isCol(g.focusChipColors.CinematicWearColor, k) and isCol(g.focusChipSolid, k),
            "story 41 the theme's chip colours and solid chip derive from focusChipColor")
        ok(g.focusChipColors.CinematicBaseColor ~= k and g.focusChipSolid ~= k, "story 41 the derived colours are copies (no shared table)")
    end
    ok(cw.mats[7] == 0 and cw.mats[8] == 0 and cw.mats[9] == 0 and cw.mats[10] == 0 and cw.mats[11] == 0, "story 39 open: the icon-only face keeps its own padding and minimum height (0)")
    ok(T.noChip("r39g1") and T.tagged("r39g1").mats == nil, "story 39 open: r1's gear keeps its own look")
    ok(FO._chipPad(C.els["r39c1"]) == 4, "story 39 p = min(4, gap 8 / 2, row pad 0 + 4)", FO._chipPad(C.els["r39c1"]))
    -- Right / Left
    ok(T.key(wr, D.right, INV_ACT) and T.agree("r39g1") and T.chipped("r39g1", T.S39) and T.cbOwn("r39c1"), "story 39 RIGHT: the gear gets the chip, the checkbox its own look and scale 1")
    ok(T.chipMid("r39g1") == mid, "story 39 RIGHT: the same instance")
    ok(T.key(wr, D.left, INV_ACT) and T.agree("r39c1") and T.chipped("r39c1", T.S39) and T.noChip("r39g1") and T.gearOwn("r39g1"), "story 39 LEFT: back on the checkbox; the gear's own dimmed look")
    -- Up / Down: r2's control in the same column; r1's control and row restored
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r39c2") and T.chipped("r39c2", T.S39) and T.cbOwn("r39c1") and T.strong("r39r2") and T.strip("r39r1"),
        "story 39 DOWN: r2's checkbox gets the chip, r1's checkbox and row their own look")
    ok(T.tagged("r39r1").Background.pad[2] == 4, "story 39 DOWN: the unfocused row keeps its taller padding")
    -- Hover: focus and band on r4, no chip anywhere (mouse mode)
    T.move()
    T.hover(T.tagged("r39r4"))
    ok(T.agree("r39c4") and T.strong("r39r4") and FO._mode() == "mouse" and T.anyChip() == nil and T.cbOwn("r39c2"), "story 39 hover: focus and band on r4, no chip anywhere", T.anyChip())
    local c4 = T.tagged("r39c4")
    ok(c4.mats and c4.mats[1] == T.SEL and c4.focusLook == true and T.plainScale(c4), "story 39 hover: r4's checkbox shows story 28's face (selection, no scale)")
    -- A key at a line end (LEFT from column 1): nothing moves, the chip comes back at once
    ok(T.key(wr, D.left, INV_ACT) and T.agree("r39c4") and FO._mode() == "keys" and T.chipped("r39c4", T.S39), "story 39 key at a line end after a hover: the chip on the same element at once")
    -- Hover into the row already holding focus: mouse mode, the chip goes
    T.move()
    T.hover(T.tagged("r39r4"))
    ok(T.agree("r39c4") and FO._mode() == "mouse" and T.noChip("r39c4") and c4.focusLook == true, "story 39 same-row hover: the chip goes, the focus look stays")
    -- An enter under a still pointer (content moving) is no input: the mode stays
    T.key(wr, D.left, INV_ACT)
    T.hover(T.tagged("r39r3"))
    ok(T.agree("r39c4") and FO._mode() == "keys" and T.chipped("r39c4", T.S39), "story 39 still pointer: an enter is no input, the chip stays")
    -- Key after hover: DOWN brings the chip on the new element
    T.move()
    T.hover(T.tagged("r39r3"))
    ok(T.agree("r39c3") and T.noChip("r39c3"), "story 39 hover r3: no chip")
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r39c4") and T.chipped("r39c4", T.S39) and T.noChip("r39c3"), "story 39 DOWN after a hover: the chip on the new element at once")
    -- Click with a pointer move on r3's gear: focus there, no chip
    T.move()
    T.fire(T.CLICK, T.tagged("r39g3"))
    ok(T.agree("r39g3") and FO._mode() == "mouse" and T.anyChip() == nil and T.cbOwn("r39c4"), "story 39 click with a move: focus on r3's gear, no chip", T.anyChip())
    -- A click always counts as mouse: also with the pointer still, after a key
    T.key(wr, D.left, INV_ACT)
    ok(T.agree("r39c3") and FO._mode() == "keys" and T.chipped("r39c3", T.S39), "story 39 key: r3's checkbox chipped")
    T.fire(T.CLICK, T.tagged("r39g3"))
    ok(T.agree("r39g3") and FO._mode() == "mouse" and T.anyChip() == nil, "story 39 click with the pointer still: mouse, no chip", T.anyChip())
    -- Clicking the already-focused control after a key: mouse, its chip goes at once
    T.key(wr, D.left, INV_ACT); T.key(wr, D.right, INV_ACT)
    ok(T.agree("r39g3") and T.chipped("r39g3", T.S39), "story 39 keys back on r3's gear: chipped")
    T.fire(T.CLICK, T.tagged("r39g3"))
    ok(T.agree("r39g3") and FO._mode() == "mouse" and T.noChip("r39g3"), "story 39 click on the focused control: mouse, its chip goes")
    -- Accept (Enter / gamepad A): left to the Button, whose click is the key's: onChange once, the chip stays
    T.key(wr, D.left, INV_ACT)
    local nch = T.ncalls("r39c3")
    ok(T.key(wr, INV_DIR, A.accept) == false and FO._mode() == "keys", "story 39 accept: left to the Button, keys mode")
    T.fire(T.CLICK, T.tagged("r39c3"))
    ok(T.ncalls("r39c3") == nch + 1 and T.agree("r39c3") and FO._mode() == "keys" and T.chipped("r39c3", T.S39), "story 39 accept's click: onChange once, the chip stays")
    -- The accept counts once: the next click is the mouse's
    T.fire(T.CLICK, T.tagged("r39c3"))
    ok(FO._mode() == "mouse" and T.noChip("r39c3"), "story 39 accept counts once: the next click is the mouse's")
    -- A click on another element after an accept, or a late one, is the mouse's
    T.key(wr, INV_DIR, A.accept)
    T.fire(T.CLICK, T.tagged("r39g3"))
    ok(FO._mode() == "mouse" and T.agree("r39g3"), "story 39 accept, then a click elsewhere: mouse")
    T.key(wr, D.left, INV_ACT)
    T.key(wr, INV_DIR, A.accept)
    clock = clock + 2000000
    T.fire(T.CLICK, T.tagged("r39c3"))
    ok(FO._mode() == "mouse" and T.noChip("r39c3"), "story 39 accept, a click 2 s later: mouse")
    -- Another key after an accept cancels it: a click on that element then is the mouse's
    T.key(wr, D.left, INV_ACT)
    T.key(wr, INV_DIR, A.accept)
    T.key(wr, D.right, INV_ACT); T.key(wr, D.left, INV_ACT)
    T.fire(T.CLICK, T.tagged("r39c3"))
    ok(FO._mode() == "mouse" and T.noChip("r39c3"), "story 39 accept, another key, then a click: mouse")
    -- A key left to a text box (keyboard focus on something else in the window) is still an input of the keys
    local keep = F.focus
    F.focus = { HasKeyboardFocus = function() return true end }
    ok(T.key(wr, D.down, INV_ACT) == false and FO._mode() == "keys", "story 39 a key left to a text box: keys mode")
    F.focus = keep
    T.key(wr, D.left, INV_ACT)
    ok(T.agree("r39c3") and T.chipped("r39c3", T.S39), "story 39 keys again: r3's checkbox chipped")
    -- Choice and slider in a row (keys): their Background is the chip, no scale, text in the ink
    T.key(wr, D.down, INV_ACT)
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r39ch") and T.chipMid("r39ch") == mid and T.tagged("r39ch").pad == 0 and T.tintIs(T.tagged("r39ch").matTint, g.focusChipTint),
        "story 39 keys, choice in a row: its Background is the chip")
    local chw = T.tagged("r39ch")
    ok(chw.look and T.inkIs(chw.look, 3) and chw.focusLook == true, "story 39 keys, choice: its value in the chip's ink, its focus look on")
    ok(T.key(wr, D.right, INV_ACT) and T.agree("r39ch") and T.chipMid("r39ch") == mid and T.last("r39ch") ~= nil and FO._mode() == "keys", "story 39 keys, choice: RIGHT steps it, the chip stays")
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r39sl") and T.chipMid("r39sl") == mid and T.tagged("r39sl").pad == 0 and T.inkNumber("r39sl") and T.tagged("r39sl").focusLook == true,
        "story 39 keys, slider in a row: its Background is the chip, its number in the ink")
    ok(T.matOf("r39ch") == T.STRIP and C.els["r39ch"].chipOn == nil and chw.look and T.near(chw.look[3], g.text.r), "story 39 choice unfocused: its own strip and text colour")
    ok(T.key(wr, D.right, INV_ACT) and T.agree("r39sl") and T.inkNumber("r39sl") and T.chipMid("r39sl") == mid, "story 39 keys, slider: RIGHT nudges it, the chip and the ink number stay")
    -- A hover while a text box of the window holds keyboard focus (typing in the slider's number box) changes nothing:
    -- the mode stays keys, the chip stays
    local keepF = F.focus
    F.focus = { HasKeyboardFocus = function() return true end }
    T.move()
    T.hover(T.tagged("r39r5"))
    ok(FO._mode() == "keys" and C.els["r39sl"].chipOn == "strong" and T.inkNumber("r39sl"), "story 39 hover while a text box holds focus: mode keys, the chip stays")
    F.focus = keepF
    -- A commit of the number box (Enter) is no click: keys mode, the chip stays
    T.tagged("r39sl").text = "7"
    T.fire(T.COMMIT, T.tagged("r39sl"))
    ok(T.agree("r39sl") and FO._mode() == "keys" and C.els["r39sl"].chipOn == "strong" and T.chipMid("r39sl") == mid, "story 39 slider commit: keys mode, the chip stays")
    -- The same controls in mouse mode: no chip, their own look with the focus look (story 27)
    T.move()
    T.hover(T.tagged("r39r5"))
    ok(T.agree("r39ch") and FO._mode() == "mouse" and T.matOf("r39ch") == T.STRIP and chw.focusLook == true and C.els["r39ch"].chipOn == nil and T.near(chw.look[3], g.text.r),
        "story 39 mouse, choice: no chip, its own strip and the focus look")
    ok(T.matOf("r39sl") == T.STRIP and C.els["r39sl"].chipOn == nil and not T.inkNumber("r39sl") and T.tagged("r39sl").focusLook == false, "story 39 slider unfocused: its own strip, its number its own")
    T.move()
    T.hover(T.tagged("r39r6"))
    ok(T.agree("r39sl") and T.matOf("r39sl") == T.STRIP and C.els["r39sl"].chipOn == nil and T.tagged("r39sl").focusLook == true and not T.inkNumber("r39sl"),
        "story 39 mouse, slider: no chip, its own strip and the focus look")
    T.move()
    T.hover(T.tagged("r39r8"))
    local bw = T.tagged("r39b8")
    ok(T.agree("r39b8") and C.els["r39b8"].chipOn == nil and bw.focusLook == true and T.chipMid("r39b8") == nil, "story 39 mouse, labelled button: no chip, its focus look")
    -- Every control kind in both modes, through the one decision (lookOf)
    local kinds = { { "r39c1", "chip", "face" }, { "r39g1", "chip", "face" }, { "r39ch", "chip", "hover" }, { "r39sl", "chip", "hover" },
        { "r39b8", "chip", "hover" }, { "r39lone", "face", "face" }, { "#close:R39", "hover", "hover" } }
    for _, m in ipairs({ "keys", "mouse" }) do
        FO._input(m)
        for _, k in ipairs(kinds) do
            local want = m == "keys" and k[2] or k[3]
            ok(FO._lookOf(C.els[k[1]], true) == want and FO._lookOf(C.els[k[1]], false) == "off", "story 39 lookOf " .. m .. " " .. k[1] .. ": " .. want, FO._lookOf(C.els[k[1]], true))
        end
    end
    ok(FO._lookOf({ kind = "gchoice", panel = C.els["r39r5"] }, true) == "hover", "story 39 lookOf: the game picker never gets a chip")
    -- A mode change re-applies the current look at once: keys gives the chip on the hovered labelled button
    FO._input("keys")
    ok(T.agree("r39b8") and T.chipped("r39b8"), "story 39 mode change to keys: the focused labelled button chipped at once")
    ok(bw.mats[7] == g.buttonPadding.l and bw.mats[8] == g.buttonPadding.t and bw.mats[11] == g.buttonMinHeight and bw.Btn.scale == nil, "story 39 labelled button: its own padding and minimum height, no scale")
    -- Narrow gap: a compact row (gap 4): p = 2
    ok(T.key(wr, D.up, INV_ACT) and T.agree("r39g7") and FO._chipPad(C.els["r39g7"]) == 2 and T.chipped("r39g7", 32 / 28), "story 39 narrow gap: p = 2", FO._chipPad(C.els["r39g7"]))
    ok(C.els["r39b8"].chipOn == nil and bw.focusLook == false and T.chipMid("r39b8") == nil, "story 39 labelled button unfocused: its own look")
    -- Lone control and BACK: no chip (story 28's looks)
    T.key(wr, D.down, INV_ACT)
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r39lone") and T.noChip("r39lone") and T.gearFaced("r39lone"), "story 39 lone control: no chip, story 28's face")
    ok(T.key(wr, D.down, INV_ACT) and T.agree("#close:R39") and T.anyChip() == nil and T.tagged("#close:R39").focusLook == true, "story 39 BACK: no chip, its own focus look")
    -- Switch off: the plain band, the chip unchanged
    for _ = 1, 12 do T.key(wr, D.up, INV_ACT) end
    ok(T.agree("r39c1") and FO._mode() == "keys", "story 39 back on r1's checkbox")
    -- BACK of a window over this one, clicked for real (its internal button): after the Accept key, the key's (the chip
    -- below stays); without it, the mouse's (no chip on the window below)
    SC.open{ id = "R39x" }
    ok(T.agree("#close:R39x") and FO._mode() == "keys", "story 39 upper window: its BACK holds focus")
    T.key(T.screenOf("R39x"), INV_DIR, A.accept)
    T.fire(T.CLICK, T.tagged("#close:R39x"))
    ok(C.windows["R39x"] == nil or not C.windows["R39x"].open, "story 39 accept on BACK, its real click: the upper window closed")
    ok(FO._mode() == "keys" and T.agree("r39c1") and T.chipped("r39c1", T.S39), "story 39 accept on BACK, its real click: keys mode, the chip below")
    SC.open{ id = "R39x" }
    T.fire(T.CLICK, T.tagged("#close:R39x"))
    ok(FO._mode() == "mouse" and T.agree("r39c1") and T.noChip("r39c1") and T.anyChip() == nil, "story 39 a real click on BACK: mouse mode, no chip on the window below", T.anyChip())
    T.key(wr, D.left, INV_ACT)
    ok(FO._mode() == "keys" and T.chipped("r39c1", T.S39), "story 39 a key after: the chip back")
    g.focusRowStrong = false
    T.key(wr, D.down, INV_ACT)
    ok(T.agree("r39c2") and T.selected("r39r2") and T.chipped("r39c2", T.S39) and T.chipMid("r39c2") == mid, "story 39 switch off: the plain band, the chip unchanged")
    g.focusRowStrong = true
    T.key(wr, D.up, INV_ACT)
    -- Re-style while focused: its own look at once, scale 1; the tick puts the chip back
    B.create{ id = "r39g1", place = { row = rows[1] }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r39g1") }
    T.key(wr, D.right, INV_ACT)
    ok(T.agree("r39g1") and T.chipped("r39g1", T.S39), "story 39 re-style: on r1's gear, chipped")
    B.create{ id = "r39g1", place = { row = rows[1] }, icon = { icon = "gear" }, iconSize = 28, dimmed = false, onClick = T.rec("r39g1") }
    local g1 = T.tagged("r39g1")
    ok(C.els["r39g1"].chipOn == nil and T.plainScale(g1) and T.chipMid("r39g1") == nil, "story 39 re-style: its own look at once, scale 1")
    tick()
    ok(T.chipped("r39g1", T.S39), "story 39 re-style: the tick puts the chip back")
    local mc = g1.matCalls
    tick()
    ok(g1.matCalls == mc, "story 39 tick: chipped already, no widget call")
    -- Re-style of a focused choice and slider: their own look at once, the tick puts the chip back
    for _ = 1, 4 do T.key(wr, D.down, INV_ACT) end
    ok(T.agree("r39ch") and T.chipMid("r39ch") == mid, "story 39 re-style: on the choice, chipped")
    X.KIND.choice.style(C.els["r39ch"], T.tagged("r39ch"), false) -- a re-style (as text.lua's restyle pass)
    ok(C.els["r39ch"].chipOn == nil and T.chipMid("r39ch") == nil, "story 39 re-style: the choice's own look at once")
    tick()
    ok(T.chipMid("r39ch") == mid and C.els["r39ch"].chipOn ~= nil, "story 39 re-style: the tick puts the choice's chip back")
    T.key(wr, D.down, INV_ACT)
    X.KIND.slider.style(C.els["r39sl"], T.tagged("r39sl"), false)
    ok(C.els["r39sl"].chipOn == nil and T.chipMid("r39sl") == nil, "story 39 re-style: the slider's own look at once")
    tick()
    ok(T.chipMid("r39sl") == mid and T.inkNumber("r39sl"), "story 39 re-style: the tick puts the slider's chip and ink number back")
    for _ = 1, 5 do T.key(wr, D.up, INV_ACT) end
    ok(T.agree("r39c1"), "story 39 back on r1's checkbox", SC.stats().focus)
    -- No instance in a hook: a solid chip now, no asset load; the instance chip after the tick
    T.key(wr, D.left, INV_ACT)
    kill(mid)
    local loads, gets, made = AS.stats.loads, F.getAssets, #F.mids
    T.key(wr, D.down, INV_ACT)
    local c2 = T.tagged("r39c2")
    local sol = g.focusChipSolid
    ok(T.agree("r39c2") and C.els["r39c2"].chipOn == "solid" and c2.colors and T.near(c2.colors[1], sol.r) and T.near(c2.colors[4], sol.a) and c2.colors[13] == 0
        and T.scaleIs(c2.Btn, T.S39) and T.contentOk("r39c2", c2.content), "story 39 in a hook, no instance: a solid chip now (a checkbox: its own colours, story 42; scaled)")
    ok(AS.stats.loads == loads and F.getAssets == gets and #F.mids == made, "story 39 in a hook: no asset load, nothing made", AS.stats.loads - loads)
    tick()
    ok(T.chipped("r39c2", T.S39) and C.els["r39c2"].chipOn == "strong" and #F.mids >= made + 1, "story 39 in a hook: the tick upgrades it to the instance chip")
    mid = T.chipMid("r39c2")
    -- Element gone: the recovered element gets the chip; a dead widget is skipped without a call
    local c2calls = c2.matCalls
    CK.remove(C.els["r39c2"].handle)
    ok(T.agree("r39g2") and T.chipped("r39g2", T.S39) and c2.matCalls == c2calls, "story 39 element removed: the chip on the recovered element, none on the dead one")
    -- Cover: the covered window's control loses the chip; back on return
    local R2 = SC.open{ id = "R39b" }
    local g2 = T.tagged("r39g2")
    ok(T.noChip("r39g2") and T.gearOwn("r39g2") and T.plainScale(g2), "story 39 cover: the covered control's own look, scale 1")
    SC.close(R2)
    ok(T.agree("r39g2") and T.chipped("r39g2", T.S39), "story 39 cover: the chip back after the close")
    -- Widget call fails: SetRenderScale throws: one WARN, the chip's face on, focus unchanged; the tick retries
    local nW = countLogs("the focus chip failed")
    local faults = FO.stats().chipFaults
    T.tagged("r39g3").Btn.throwScale = true
    T.key(wr, D.down, INV_ACT) -- r2 has one control left: r3's first column
    T.key(wr, D.right, INV_ACT)
    T.key(wr, D.left, INV_ACT); T.key(wr, D.right, INV_ACT)
    ok(T.agree("r39g3") and T.chipMid("r39g3") ~= nil and C.els["r39g3"].chipOn == "pending" and countLogs("the focus chip failed") == nW + 1 and FO.stats().chipFaults > faults,
        "story 39 SetRenderScale throws: the chip's face, one WARN, focus moved", countLogs("the focus chip failed") - nW)
    T.tagged("r39g3").Btn.throwScale = false
    tick()
    ok(T.agree("r39g3") and T.chipped("r39g3", T.S39) and C.els["r39g3"].chipOn == "strong", "story 39 SetRenderScale fixed: the tick completes the chip")
    T.tagged("r39g3").Btn.throwScale = true
    C.forgetWarning("focus chip scale")
    local nS = countLogs("focus chip")
    T.key(wr, D.up, INV_ACT)
    ok(T.agree("r39g2") and C.els["r39g3"].chipOn == nil and T.chipMid("r39g3") == nil and T.gearOwn("r39g3") and countLogs("focus chip") == nS + 1,
        "story 39 a scale that can't be reset: its own look, one WARN", countLogs("focus chip") - nS)
    T.tagged("r39g3").Btn.throwScale = false
    -- Close: own look, scale 1
    SC.close(R)
    ok(rec.lookId == nil and rec.lookRowId == nil and C.els["r39g2"].ref == nil, "story 39 window closed: its widgets went with it, nothing recorded")
    -- Reopened by the keys: the new widgets start without a chip; the keys put it on the first control
    R = SC.open{ id = "R39" }
    tick()
    local first = SC.stats().focus
    ok(first ~= nil and C.els[first].chipOn == "strong" and T.chipped(first, T.S39) and #T.tagged(first).Btn.scale == 2, "story 39 reopened in keys mode: the first control chipped on its new widget", first)
    SC.close(R)
    -- A window opened by a mouse click: no chip until a key
    local Rm = SC.open{ id = "R39m" }
    local nl, Rn
    B.create{ id = "r39open", label = "OPEN", place = { screen = Rm, corner = "top-left" }, onClick = function()
        Rn = SC.open{ id = "R39n" }
        nl = LS.create{ id = "r39nl", place = { screen = Rn, corner = "top-left" }, size = { 300, 200 } }
        for i = 1, 2 do
            local r = RS.create{ id = "r39nr" .. i, place = { list = nl } }
            B.create{ id = "r39ng" .. i, place = { row = r }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = function() end }
        end
    end }
    tick()
    T.key(T.screenOf("R39m"), D.up, INV_ACT)
    ok(FO._mode() == "keys" and T.agree("r39open"), "story 39 mouse open: keys first")
    T.fire(T.CLICK, T.tagged("r39open"))
    tick()
    ok(nl ~= nil and FO._mode() == "mouse" and T.agree("r39ng1") and T.noChip("r39ng1") and T.gearFaced("r39ng1") and T.anyChip() == nil,
        "story 39 a window opened by a mouse click: the first control without a chip (story 28's face)", T.anyChip())
    ok(T.key(T.screenOf("R39n"), D.down, INV_ACT) and T.agree("r39ng2") and T.chipped("r39ng2", T.S39), "story 39 then a key: the chip")
    SC.close(Rn)
    SC.close(Rm)
    -- The menu entry's click (C.clickInput without an element): mouse
    FO._input("keys")
    C.clickInput()
    ok(FO._mode() == "mouse", "story 39 the menu entry's click: mouse mode")
    FO._input("keys")
    -- Creation fails: a solid chip for the session, one WARN
    AS._reset()
    C.forgetWarning("asset:focus chip")
    C.forgetWarning("asset:focus row")
    F.midFail = "create"
    local nC = countLogs("focus chip (an instance")
    local W = SC.open{ id = "R39f" }
    local Lf = LS.create{ id = "r39fl", place = { screen = W, corner = "top-left" }, size = { 300, 200 } }
    for i = 1, 2 do
        local r = RS.create{ id = "r39fr" .. i, place = { list = Lf } }
        B.create{ id = "r39fg" .. i, place = { row = r }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r39fg" .. i) }
    end
    tick(); T.key(T.screenOf("R39f"), D.down, INV_ACT); tick()
    local fw = T.tagged("r39fg2")
    ok(T.agree("r39fg2") and C.els["r39fg2"].chipOn == "solid" and fw.colors and T.near(fw.colors[1], g.focusChipSolid.r) and countLogs("focus chip (an instance") == nC + 1,
        "story 39 creation fails: a solid chip, one WARN", countLogs("focus chip (an instance") - nC)
    F.midFail = nil
    tick()
    ok(C.els["r39fg2"].chipOn == "solid", "story 39 creation fails: solid for the session")
    -- Mutation check (the mode rule): mouse mode takes every chip off at once, keys puts it back at once
    FO._input("mouse")
    ok(T.anyChip() == nil and T.noChip("r39fg2"), "story 39 mouse mode: no chip anywhere, at once", T.anyChip())
    tick()
    ok(T.anyChip() == nil, "story 39 mouse mode: the tick adds none")
    FO._input("keys")
    ok(C.els["r39fg2"].chipOn == "solid", "story 39 keys mode: the chip back at once")
    SC.close(W)
    AS._reset()
    ok(FO.stats().faults == faults0 and C.inDispatch == 0, "story 39: no fault in the focus path", FO.stats().faults - faults0)
    ok(FO.stats().chips > 0, "story 39: chips counted", FO.stats().chips)
end

-- ---------------------------------------------------------------- core story 42: the tick readable, the chip after a gamepad press
-- A chipped checkbox draws its icon in its own colours (only the chip behind it changes); a hover or a click switches to
-- mouse mode only when the gamepad is not the current input (the game's CommonInputSubsystem). Fakes:
-- SubsystemBlueprintLibrary:GetLocalPlayerSubsystem(pc, class) -> F.ciSub (F.ciFail "throw" | "nil"), the native class
-- /Script/CommonInput.CommonInputSubsystem (T.CI_CLASS), StaticFindObject lookups of it counted (F.ciLookups).
T.CI_CLASS = "/Script/CommonInput.CommonInputSubsystem"
F.ciLookups, F.ciPcs = 0, {}
do
    local sfo = StaticFindObject
    StaticFindObject = function(p)
        if p == T.CI_CLASS then F.ciLookups = F.ciLookups + 1 end
        return sfo(p)
    end
    obj({ GetLocalPlayerSubsystem = function(_, pc, c)
        F.ciPcs[#F.ciPcs + 1] = pc
        if F.ciFail == "throw" then error("GetLocalPlayerSubsystem: boom") end
        if F.ciFail == "nil" or c ~= F.objects[T.CI_CLASS] then return nil end
        return F.ciSub
    end }, "/Script/Engine.Default__SubsystemBlueprintLibrary")
    F.ciSub = obj({ type = 0, bIsGamepadSimulatedClick = false,
        GetCurrentInputType = function(self) if self.throw then error("GetCurrentInputType: boom") end return self.type end })
end
-- The checkbox's own colours on its content and not the ink (a dark ink must not tint the ticked / unticked texture).
function T.cbChipOwn(id)
    local w = T.tagged(id)
    return T.chipped(id, T.S39) and T.ownIs(C.els[id], w.content) and not T.inkIs(w.content, 1)
end
do
    local AS = require("nucleus.ui.assets")
    AS._reset()
    FO._noChip = false
    FO._resetGamepadInput()
    local faults0 = FO.stats().faults
    local CI = F.objects[T.CI_CLASS] or obj({}, T.CI_CLASS)
    local sub = F.ciSub
    sub.type, sub.bIsGamepadSimulatedClick, F.ciFail = 0, false, nil
    FO._input("keys")
    local R = SC.open{ id = "R42" }
    local wr = T.screenOf("R42")
    local L = LS.create{ id = "r42l", place = { screen = R, corner = "top-left" }, size = { 600, 400 } }
    for i = 1, 3 do -- r1 unticked, r2 ticked, r3 unticked; each with a gear
        local r = RS.create{ id = "r42r" .. i, place = { list = L } }
        CK.create{ id = "r42c" .. i, checked = i == 2, place = { row = r }, onChange = T.rec("r42c" .. i) }
        X.create{ id = "r42n" .. i, text = "MOD " .. i, place = { row = r, fill = 4 } }
        B.create{ id = "r42g" .. i, place = { row = r }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r42g" .. i) }
    end
    tick()
    -- (1) Chipped checkbox: its own colours, ticked or unticked; a chipped gear keeps the ink
    ok(T.agree("r42c1") and C.els["r42c1"].checked == false and T.cbChipOwn("r42c1"), "story 42 chipped unticked checkbox: the chip, content in its own colours (not the ink)")
    local cw = T.tagged("r42c1")
    ok(T.colIs(cw.content, 1, theme.game.text) and T.colIs(cw.content, 5, theme.game.textHover), "story 42 chipped checkbox: the game's text / text hover colours, as unfocused")
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r42c2") and C.els["r42c2"].checked == true and T.cbChipOwn("r42c2"), "story 42 chipped ticked checkbox: content in its own colours")
    ok(T.cbOwn("r42c1"), "story 42 unfocused checkbox: its own look back")
    ok(T.key(wr, D.right, INV_ACT) and T.agree("r42g2") and T.chipped("r42g2", T.S39) and T.inkIs(T.tagged("r42g2").content, 1), "story 42 chipped gear: content in focusChipInk (unchanged)")
    ok(T.key(wr, D.left, INV_ACT) and T.agree("r42c2") and T.cbChipOwn("r42c2"), "story 42 back on the ticked checkbox")
    -- IconBack (option A): shown in focusChipBack behind a chipped checkbox, ticked or unticked; hidden when the chip
    -- leaves; never on any other kind
    ok(T.backShown(T.tagged("r42c2")) and T.backHidden(T.tagged("r42c1")) and T.tagged("r42c1").backCalls == 2,
        "story 42 IconBack: shown behind the chipped ticked box, hidden again on the unticked one it left", T.tagged("r42c1").backCalls)
    ok(T.tagged("r42g2").back == nil and T.tagged("r42g1").back == nil, "story 42 IconBack: a chipped gear never shows it")
    local bc = T.tagged("r42c2").backCalls
    tick()
    ok(T.tagged("r42c2").backCalls == bc and T.backShown(T.tagged("r42c2")), "story 42 IconBack: the tick doesn't call it again while it shows")
    -- (2) Enter / A on a checkbox: onChange once, keys, the chip stays (the box's state in its own colours)
    local n2 = T.ncalls("r42c2")
    T.key(wr, INV_DIR, A.accept)
    T.fire(T.CLICK, T.tagged("r42c2"))
    ok(T.ncalls("r42c2") == n2 + 1 and C.els["r42c2"].checked == false and FO._mode() == "keys" and T.cbChipOwn("r42c2"), "story 42 accept and its click: onChange once, keys, the chip stays")
    T.key(wr, INV_DIR, A.accept)
    T.fire(T.CLICK, T.tagged("r42c2"))
    ok(T.ncalls("r42c2") == n2 + 2 and C.els["r42c2"].checked == true and FO._mode() == "keys" and T.cbChipOwn("r42c2"), "story 42 accept again: ticked, the chip stays")
    -- Every valid key records the pointer, also one left to the Button: content moving under it after is no hover
    local ign = T.ign()
    T.move()
    T.key(wr, INV_DIR, A.accept) -- left to the Button (not handled): the pointer recorded all the same
    T.hover(T.tagged("r42r3")) -- before the Button's click (on the key's release)
    ok(T.agree("r42c2") and FO._mode() == "keys" and T.cbChipOwn("r42c2") and T.ign() == ign + 1, "story 42 accept: the pointer recorded, a still enter after is ignored")
    T.fire(T.CLICK, T.tagged("r42c2"))
    ok(FO._mode() == "keys" and T.cbChipOwn("r42c2") and C.els["r42c2"].checked == false, "story 42 accept: its click after, keys, the chip stays")
    -- (3) Gamepad click: CommonInput says Gamepad: keys, the chip stays (on the clicked control)
    sub.type = 1
    F.ciPcs = {}
    T.move()
    T.fire(T.CLICK, T.tagged("r42g2"))
    ok(T.agree("r42g2") and FO._mode() == "keys" and T.chipped("r42g2", T.S39), "story 42 gamepad click: keys, the chip on the clicked control")
    ok(F.ciPcs[1] == PC, "story 42 gamepad: the subsystem asked with the window's player controller (the owner's)")
    -- A simulated click (CommonUI's Accept as a click) while the type already reads MouseAndKeyboard
    sub.type, sub.bIsGamepadSimulatedClick = 0, true
    T.move()
    T.fire(T.CLICK, T.tagged("r42c2"))
    ok(T.agree("r42c2") and FO._mode() == "keys" and T.cbChipOwn("r42c2"), "story 42 gamepad-simulated click: keys, the chip stays")
    -- A stale flag (still set, type MouseAndKeyboard) never blocks a real mouse hover: the flag is read on clicks only
    ok(FO._gamepadInput() == false and FO._gamepadInput(true) == true, "story 42 the simulated-click flag counts for a click only")
    T.move()
    T.hover(T.tagged("r42r3"))
    ok(T.agree("r42c3") and FO._mode() == "mouse" and T.anyChip() == nil, "story 42 stale flag on a moved hover: mouse mode (a real mouse), no chip", T.anyChip())
    T.key(wr, D.up, INV_ACT)
    ok(FO._mode() == "keys" and T.agree("r42c2") and T.cbChipOwn("r42c2"), "story 42 stale flag: a key brings keys and the chip back")
    -- The flag alone still keeps keys on a click
    T.move()
    T.fire(T.CLICK, T.tagged("r42c2"))
    ok(T.agree("r42c2") and FO._mode() == "keys" and T.cbChipOwn("r42c2"), "story 42 the flag alone on a click: keys, the chip stays")
    sub.bIsGamepadSimulatedClick = false
    -- (4) Gamepad cursor move: a hover is ignored (focus, mode, chip unchanged), the pointer re-recorded
    sub.type = 1
    ign = T.ign()
    local hv = FO.stats().hovers
    T.move()
    T.hover(T.tagged("r42r3"))
    ok(T.agree("r42c2") and FO._mode() == "keys" and T.cbChipOwn("r42c2") and T.ign() == ign + 1 and FO.stats().hovers == hv, "story 42 gamepad hover: ignored, focus and chip unchanged")
    sub.type = 0
    T.hover(T.tagged("r42r3"))
    ok(T.agree("r42c2") and FO._mode() == "keys" and T.ign() == ign + 2, "story 42 gamepad hover: the pointer re-recorded (a still enter after is content moving)")
    -- (5) Real mouse: CommonInput says MouseAndKeyboard: a moved hover and a click switch to mouse (story 39)
    T.move()
    T.hover(T.tagged("r42r3"))
    ok(T.agree("r42c3") and FO._mode() == "mouse" and T.anyChip() == nil, "story 42 real mouse hover: mouse mode, no chip", T.anyChip())
    ok(T.backHidden(T.tagged("r42c2")) and T.backHidden(T.tagged("r42c3")), "story 42 IconBack: mouse mode hides it (no chip, no dark box)")
    T.key(wr, D.up, INV_ACT)
    ok(FO._mode() == "keys" and T.agree("r42c2") and T.cbChipOwn("r42c2"), "story 42 a key: keys again, the chip")
    T.move()
    T.fire(T.CLICK, T.tagged("r42g2"))
    ok(T.agree("r42g2") and FO._mode() == "mouse" and T.noChip("r42g2"), "story 42 real mouse click: mouse mode, no chip")
    -- The menu entry's click (no element) under gamepad input: keys stay
    FO._input("keys")
    sub.type = 1
    C.clickInput()
    ok(FO._mode() == "keys", "story 42 the menu entry's click under gamepad input: keys stay")
    sub.type = 0
    C.clickInput()
    ok(FO._mode() == "mouse", "story 42 the menu entry's click under mouse input: mouse")
    -- (6) No CommonInput: no subsystem, a throwing call: story 39's rules (a click is the mouse's)
    for _, case in ipairs({ { "nil", false }, { "throw", false }, { nil, true } }) do
        FO._input("keys")
        F.ciFail, sub.throw = case[1], case[2]
        sub.type = 1
        C.clickInput()
        ok(FO._mode() == "mouse", "story 42 no CommonInput (" .. tostring(case[1] or "GetCurrentInputType throws") .. "): a click is the mouse's")
    end
    F.ciFail, sub.throw, sub.type = nil, false, 0
    ok(FO._gamepadInput() == false, "story 42 MouseAndKeyboard: not gamepad")
    -- A failing call is logged: GetLocalPlayerSubsystem throws: false and one WARN naming the focus chip
    C.forgetWarning("focus chip gamepad")
    local nG = countLogs("focus chip's gamepad check")
    F.ciFail, sub.type = "throw", 1
    ok(FO._gamepadInput() == false and FO._gamepadInput() == false and countLogs("focus chip's gamepad check") == nG + 1
        and countLogs("GetLocalPlayerSubsystem: boom") >= 1, "story 42 GetLocalPlayerSubsystem throws: false, one WARN naming the call", countLogs("focus chip's gamepad check") - nG)
    F.ciFail, sub.type = nil, 0
    local nS = countLogs("focus chip's gamepad check")
    F.ciFail = "nil"
    ok(FO._gamepadInput() == false and countLogs("focus chip's gamepad check") == nS, "story 42 no subsystem: false, silent")
    F.ciFail = nil
    -- The class missing: false, looked up once in this Lua state (a miss is a full scan)
    F.objects[T.CI_CLASS] = nil
    FO._resetGamepadInput()
    sub.type = 1
    local lk = F.ciLookups
    FO._input("keys")
    C.clickInput()
    ok(FO._mode() == "mouse" and F.ciLookups == lk + 1, "story 42 class missing: a click is the mouse's, the class looked up once", F.ciLookups - lk)
    FO._input("keys")
    C.clickInput()
    T.key(wr, D.down, INV_ACT)
    T.move()
    T.hover(T.tagged("r42r1"))
    ok(FO._mode() == "mouse" and F.ciLookups == lk + 1, "story 42 class missing: not looked up again", F.ciLookups - lk)
    F.objects[T.CI_CLASS] = CI
    FO._resetGamepadInput()
    sub.type = 0
    -- (7) An old pak (no SetIconBack on the widget): the chip and the box's own colours, one WARN naming the focus
    -- chip, and it is not shown again in this Lua state (on any checkbox); a hide still runs. Mouse mode here.
    local w1, w2, w3 = T.tagged("r42c1"), T.tagged("r42c2"), T.tagged("r42c3")
    ok(FO._mode() == "mouse" and T.backHidden(w1) and T.backHidden(w2) and T.backHidden(w3), "story 42 old pak: starts with no IconBack shown")
    FO._input("keys")
    T.key(wr, D.up, INV_ACT); T.key(wr, D.up, INV_ACT); T.key(wr, D.up, INV_ACT); T.key(wr, D.left, INV_ACT); T.key(wr, D.down, INV_ACT)
    ok(T.agree("r42c2") and T.backShown(w2), "story 42 old pak: r2's checkbox chipped, IconBack shown")
    -- the latch set while r2's IconBack shows: r1's widget has no SetIconBack and gets a chip
    w1.SetIconBack = nil
    C.forgetWarning("focus chip back")
    local nB = countLogs("the focus chip's dark inside")
    -- the call's own error (the WARN's text names SetIconBack itself, so match the error, not the name)
    local nE = countLogs("attempt to call")
    B._chip(C.els["r42c1"], w1, nil, 0)
    B._style(C.els["r42c1"], w1, false)
    ok(countLogs("the focus chip's dark inside") == nB + 1 and countLogs("attempt to call") == nE + 1, "story 42 old pak: one WARN with the call's error", countLogs("the focus chip's dark inside") - nB)
    local b2 = w2.backCalls
    T.key(wr, D.right, INV_ACT)
    ok(T.agree("r42g2") and w2.backCalls == b2 + 1 and T.backHidden(w2) and C.els["r42c2"].backOn == nil, "story 42 old pak: the latch set, a shown IconBack is still hidden when its chip leaves")
    T.noBackOk = true
    local b3 = w3.backCalls or 0
    b2 = w2.backCalls
    T.key(wr, D.left, INV_ACT)
    ok(T.agree("r42c2") and T.cbChipOwn("r42c2") and w2.backCalls == b2, "story 42 old pak: not shown again (r2), the chip in its own colours")
    T.key(wr, D.down, INV_ACT)
    ok(T.agree("r42c3") and T.cbChipOwn("r42c3") and (w3.backCalls or 0) == b3 and countLogs("the focus chip's dark inside") == nB + 1,
        "story 42 old pak: not shown again (another checkbox), no second WARN", (w3.backCalls or 0) - b3)
    T.noBackOk = nil
    B._resetIconBack()
    SC.close(R)
    FO._input("keys")
    AS._reset()
    ok(FO.stats().faults == faults0 and C.inDispatch == 0, "story 42: no fault in the focus path", FO.stats().faults - faults0)
end

-- ---------------------------------------------------------------- core story 38: drag to reorder rows in a list
-- Fakes: a row widget takes keyboard focus (SetIsFocusable / SetKeyboardFocus) and records its render translation and
-- opacity and the Blueprint's Draggable / DragOp / DragOk; a list has its insertion line (Line), DropOp / DropLeft and a
-- scrollable Scroll; WBP_NucleusLift; WidgetBlueprintLibrary's IsDragDropping / CancelDragDrop (F.dragging); core's
-- ModActor CDO with the geometry functions. Geometry (layout units = absolute): a list's visible area is at (100, 100)
-- with its size, its rows stacked from there (their height, the slot's top padding as the gap) less the scroll offset,
-- a row's texts at x = row + 10 + 150 * (index - 1), 140 wide.
T.LIFTCLASS = cls("/Game/Mods/Nucleus/WBP_NucleusLift.WBP_NucleusLift_C")
F.dragging, F.dragCancels, F.ops = false, 0, 0
do
    local WBL = F.objects["/Script/UMG.Default__WidgetBlueprintLibrary"]
    WBL.IsDragDropping = function() return F.dragging end
    WBL.CancelDragDrop = function() F.dragCancels = F.dragCancels + 1; F.dragging = false end
    local base = WBL.Create
    WBL.Create = function(self, world, c, owner)
        if c == T.LIFTCLASS then
            local w = widget("WBP_NucleusLift_C", "/Engine/Transient.WBP_NucleusLift_C_" .. (F.addr + 0x100))
            w.HBox = newBox("HorizontalBox", w.__path .. ".WidgetTree.HBox", true)
            w.Background = { SetPadding = function(s, m) s.pad = { m.Left, m.Top, m.Right, m.Bottom } end }
            function w:SetLiftSize(W, H) self.size = { W, H } end
            function w:SetBackgroundMaterial(m, r, g, b, a, p) self.mat = m; self.pad = p end
            function w:SetBackground(r, g, b, a) self.bg = { r, g, b, a } end
            function w:SetBackgroundPadding(p) self.pad = p end
            F.lifts = (F.lifts or 0) + 1
            return w
        end
        local w = base(self, world, c, owner)
        if w.__class == "WBP_NucleusRow_C" then
            w.Draggable, w.DragOk = false, false
            function w:SetKeyboardFocus() if self.bIsFocusable then F.focus = self end end
            function w:HasKeyboardFocus() return F.focus == self end
            function w:SetRenderTranslation(v) self.shift = { v.X, v.Y } end
            function w:SetRenderOpacity(o) self.opacity = o end
        elseif w.__class == "WBP_NucleusList_C" then
            w.VBox.owner, w.Scroll.owner = w, w
            w.Scroll.kind = "scroll"
            function w.Scroll:SetScrollOffset(v) self.offset = v; self.sets = (self.sets or 0) + 1 end
            function w.Scroll:GetScrollOffsetOfEnd()
                local H = 0
                for _, c in ipairs(w.VBox.children) do if c.vis ~= 1 then H = H + c.h + c.Slot.Padding.Top end end
                return math.max(H - w.h, 0)
            end
            w.Line = { vis = 1, sets = 0 }
            w.Line.Slot = { SetPadding = function(s, m) s.top = m.Top; w.Line.sets = w.Line.sets + 1 end }
            function w.Line:SetVisibility(v) self.vis = v end
            function w.Line:SetColorAndOpacity(c) self.color = c end
        end
        return w
    end
end
-- Absolute rectangle of a fake widget: x, y, w, h.
function T.geo(o)
    if o.kind == "scroll" then local lw = o.owner return 100, 100, lw.wd, lw.h end
    if o.owner and o.owner.VBox == o then return 100, 100 - o.owner.Scroll.offset, o.owner.wd, 1000 end
    local p = o.parent
    if p and p.owner and p.owner.VBox == p then
        local x, y = T.geo(p)
        for _, c in ipairs(p.children) do
            if c.vis ~= 1 then
                y = y + c.Slot.Padding.Top
                if c == o then return x, y, p.owner.wd, c.h end
                y = y + c.h
            end
        end
    end
    if p and p.horiz then -- a text in a row's HBox
        for _, cand in pairs(handles) do
            if type(cand) == "table" and cand.HBox == p and cand.__class == "WBP_NucleusRow_C" then
                local x, y, _, h = T.geo(cand)
                for i, c in ipairs(p.children) do if c == o then return x + 10 + 150 * (i - 1), y, 140, h end end
            end
        end
    end
    return 0, 0, o.wd or 100, o.h or 30
end
obj({
    Nucleus_AbsTopLeft = function(_, w)
        local x, y = T.geo(w)
        -- F.stale: a row out of the list's view was never painted (its cached geometry at the origin)
        if F.stale and w.__class == "WBP_NucleusRow_C" and w.parent and w.parent.owner and (y < 100 or y >= 100 + w.parent.owner.h) then return vec(0, 0) end
        return vec(x, y)
    end,
    Nucleus_AbsBottomRight = function(_, w) local x, y, wd, h = T.geo(w) return vec(x + wd, y + h) end,
    Nucleus_AbsToLocal = function(_, w, a) local x, y = T.geo(w) return vec(a.X - x, a.Y - y) end,
}, "/Game/Mods/Nucleus/ModActor.Default__ModActor_C")
T.NAVUP, T.DSTART, T.DCANCEL, T.DROP = "WBP_NucleusScreen_C:Nucleus_OnNavUp", "WBP_NucleusRow_C:Nucleus_OnDragStart",
    "WBP_NucleusRow_C:Nucleus_OnDragCancel", "WBP_NucleusList_C:Nucleus_OnDrop"
-- A hook by its exact path's end (<Core>_OnNav is a prefix of <Core>_OnNavUp).
function T.fireExact(sub, w)
    for _, h in ipairs(F.hooks) do if h.path:sub(-#sub) == sub then h.fn({ get = function() return w end }) end end
end
function T.key(w, dir, act)
    w.NavDir, w.NavAction, w.NavHandled = dir, act, false
    T.fireExact(NAV, w)
    return w.NavHandled
end
-- The window's OnKeyUp: NavAction from the key, NavHandled false, <Core>_OnNavUp, Handled iff NavHandled.
function T.keyUp(w, act)
    w.NavDir, w.NavAction, w.NavHandled = INV_DIR, act, false
    fireHook(T.NAVUP, w)
    return w.NavHandled
end
-- The row's OnDragDetected: a new operation, DragOk false, <Core>_OnDragStart; returns DragOk and the operation.
function T.dragStart(id)
    local w = T.tagged(id)
    F.ops = F.ops + 1
    w.DragOp = obj({ __class = "DragDropOperation", Tag = "", Pivot = 5 })
    w.DragOk = false
    F.dragging = true
    fireHook(T.DSTART, w)
    if not w.DragOk then F.dragging = false end
    return w.DragOk, w.DragOp
end
function T.drop(listId, op, left)
    local lw = T.tagged(listId)
    lw.DropOp, lw.DropLeft = op, left ~= false
    fireHook(T.DROP, lw)
    F.dragging = false
end
function T.dragCancel(id) fireHook(T.DCANCEL, T.tagged(id)); F.dragging = false end
-- The pointer over the list (local y in its visible area), x 50 units in.
function T.at(listId, y, x) local lw = T.tagged(listId) F.mouse = { x = 100 + (x or 50), y = 100 + y }; return lw end
-- The local y of row id's top (or its middle with mid) in its list's visible area.
function T.rowY(id, mid) local w = T.tagged(id) local _, y, _, h = T.geo(w) return y - 100 + (mid and h / 2 or 0) end
function T.ids(listId) local out = {} for i, ch in ipairs(C.els[listId].children) do out[i] = ch.id end return table.concat(out, " ") end
function T.box(listId) local out = {} for i, w in ipairs(T.tagged(listId).VBox.children) do out[i] = w.tag:match("[^:]+$") end return table.concat(out, " ") end
function T.roTick() local RO = require("nucleus.ui.reorder") local f = RO._loop.handle and F.loops[RO._loop.handle] if f then f() end end
T.cbs = {}

do
    local RO = require("nucleus.ui.reorder")
    local AS = require("nucleus.ui.assets")
    AS._reset()
    FO._noChip = true
    FO._input("keys")
    local faults0, roFaults0 = FO.stats().faults, RO.stats().faults
    -- Old pak first: the row has no <Core>_OnDragStart (its RegisterHook fails): one WARN, no mouse drag; keys work.
    local realRegister = RegisterHook
    RegisterHook = function(p, f)
        if p:find("Nucleus_OnDragStart", 1, true) then error("UFunction not found: " .. p) end
        return realRegister(p, f)
    end
    local nWarn = countLogs("rows can't be dragged with the mouse")
    local R = SC.open{ id = "R38" }
    local wr = T.screenOf("R38")
    local rec = C.windows["R38"]
    local cbIn = {}
    local L = LS.create{ id = "r38l", place = { screen = R, corner = "top-left" }, size = { 600, 200 }, reorderable = true,
        onReorder = function(h, ids)
            T.cbs[#T.cbs + 1] = { h = h, ids = table.concat(ids, " ") }
            cbIn[#cbIn + 1] = C.inDispatch
            if T.cbThrow then error("boom in onReorder") end
        end }
    local rows = {}
    for i = 1, 8 do
        rows[i] = RS.create{ id = "r38r" .. i, place = { list = L }, locked = (i == 1) or nil }
        X.create{ id = "r38n" .. i, text = "MOD " .. i, place = { row = rows[i], fill = 4 } }
        if i % 2 == 0 then CK.create{ id = "r38c" .. i, place = { row = rows[i] }, onChange = T.rec("r38c" .. i) } end
    end
    rows[9] = RS.create{ id = "r38r9", place = { list = L } }
    CH.create{ id = "r38ch", options = { "LOW", "MID", "HIGH" }, selected = 1, place = { row = rows[9] }, onChange = T.rec("r38ch") }
    rows[10] = RS.create{ id = "r38r10", place = { list = L } }
    SL.create{ id = "r38sl", min = 0, max = 10, step = 1, defaultValue = 5, place = { row = rows[10] }, onChange = T.rec("r38sl") }
    tick(); tick()
    RegisterHook = realRegister
    ok(countLogs("rows can't be dragged with the mouse") == nWarn + 1 and RO.stats().dragHookOk == false, "story 38 old pak: one WARN, no mouse drag")
    ok(T.tagged("r38r3").Draggable == false, "story 38 old pak: rows stay undraggable")
    ok(hookCount("Nucleus_OnNavUp") == 1 and FO.stats().upOk == true, "story 38: one hook on the window's <Core>_OnNavUp, registered from the poll", hookCount("Nucleus_OnNavUp"))
    -- the keys still carry with the old pak: hold Enter on r4's checkbox
    FO._input("keys")
    ok(T.agree("r38c2"), "story 38 setup: focus on r2's checkbox (r1 is locked and text-only: no stop)", SC.stats().focus)
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r38r3"), "story 38 a text-only movable row is a focus stop itself", SC.stats().focus)
    ok(T.tagged("r38r3").bIsFocusable == true and F.focus == T.tagged("r38r3"), "story 38 grip row: its own widget focusable and focused")
    ok(T.strong("r38r3") or T.selected("r38r3"), "story 38 grip row: the band on it")
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r38c4"), "story 38 Down to r4's checkbox")
    T.key(wr, INV_DIR, A.accept)
    ok(FO._hold() ~= nil and FO._hold().id == "r38c4", "story 38 old pak: the hold starts on r4's checkbox")
    clock = clock + 500000
    T.roTick()
    ok(FO._carry() ~= nil and FO._carry().rowId == "r38r4", "story 38 old pak: the keyboard carry works", FO._carry() and FO._carry().rowId)
    T.keyUp(wr, A.accept)
    ok(FO._carry() == nil and #T.cbs == 0, "story 38 old pak: release drops; unchanged order, no callback")
    -- An older pak without <Core>_OnNavUp (follow-up review): one WARN, and a held Accept never picks a row up
    local US = FO._S
    local wasHooked, wasOk = US.upHooked, US.upOk
    local nUp = countLogs("rows can't be picked up with A or Enter")
    RegisterHook = function(p, f)
        if p:find("Nucleus_OnNavUp", 1, true) then error("UFunction not found: " .. p) end
        return realRegister(p, f)
    end
    US.upHooked = false
    tick()
    RegisterHook = realRegister
    ok(countLogs("rows can't be picked up with A or Enter") == nUp + 1 and FO.stats().upOk == false, "story 38 no OnNavUp: one WARN, upOk false")
    ok(T.key(wr, D.up, INV_ACT) and T.agree("r38r3"), "story 38 no OnNavUp: on r3's own stop")
    T.key(wr, INV_DIR, A.accept); clock = clock + 500000; T.roTick()
    ok(FO._hold() == nil and FO._carry() == nil, "story 38 no OnNavUp: a held Accept picks nothing up")
    T.keyUp(wr, A.accept)
    US.upHooked, US.upOk = wasHooked, wasOk
    ok(T.key(wr, D.down, INV_ACT) and T.agree("r38c4"), "story 38 no OnNavUp: back on r4's checkbox")
    -- the real pak's hooks (a fresh registration, as on a new pak)
    RO._S.hooked = false
    tick(); tick()
    ok(hookCount("Nucleus_OnDragStart") == 1 and hookCount("Nucleus_OnDragCancel") == 1 and hookCount("Nucleus_OnDrop") >= 1 and RO.stats().dragHookOk,
        "story 38: one hook each on the row's and the list's drag counters", hookCount("Nucleus_OnDragStart") .. hookCount("Nucleus_OnDragCancel") .. hookCount("Nucleus_OnDrop"))
    ok(T.tagged("r38r3").Draggable == true and T.tagged("r38r1").Draggable == false, "story 38 sync: movable rows Draggable, the locked r1 not")
    RO._S.dropHookOk = false -- follow-up review: no drop hook, no drag (a drop could never land)
    RO.sync()
    ok(T.tagged("r38r3").Draggable == false, "story 38 sync: without the drop hook no row is Draggable")
    RO._S.dropHookOk = true
    RO.sync()
    ok(T.tagged("r38r3").Draggable == true, "story 38 sync: Draggable again with the drop hook")

    -- Pure: segments and slots
    do
        local function r(id, o) local e = { id = id, kind = "row", visible = true, removed = false } for k, v in pairs(o or {}) do e[k] = v end return e end
        local a, b, cl, d, e = r("a"), r("b"), r("c", { locked = true }), r("d"), r("e")
        local t = { id = "t", kind = "text", visible = true, removed = false }
        local h = r("h", { visible = false })
        local ch = { a, b, cl, d, h, e, t }
        local lo, hi = RO.segment(ch, 1)
        ok(lo == 1 and hi == 2, "story 38 segment: a locked row bounds it", lo .. "," .. hi)
        lo, hi = RO.segment(ch, 4)
        ok(lo == 4 and hi == 6, "story 38 segment: a hidden row inside, a text bounds it", lo .. "," .. hi)
        local V, p = RO.slots(ch, 4)
        ok(#V == 2 and V[1] == d and V[2] == e and p == 1, "story 38 slots: hidden rows are never a target")
        ok(RO.moved(ch, d, 0) == nil and RO.moved(ch, d, 1) == nil, "story 38 moved: just above or below itself changes nothing")
        local m = RO.moved(ch, d, 2)
        ok(m and m[4] == h and m[5] == e and m[6] == d and m[3] == cl and m[7] == t, "story 38 moved: d after e; the hidden row keeps its place, the fixed ones their index")
        ok(RO.step(ch, a, -1) == nil and RO.step(ch, b, 1) == nil and RO.step(ch, b, -1) == 0, "story 38 step: the segment's edges")
        ok(RO.slotAt({ 0, 34, 68 }, { 30, 30, 30 }, 40) == 1 and RO.slotAt({ 0, 34, 68 }, { 30, 30, 30 }, 60) == 2, "story 38 slotAt: by row middles")
        ok(RO.slotY({ 0, 34 }, { 30, 30 }, 1, 4) == 32 and RO.slotY({ 0, 34 }, { 30, 30 }, 2, 4) == 66, "story 38 slotY: in the gap, and after the last row")
    end

    -- Keyboard: tap vs hold on every control kind (a checkbox, a choice, a slider, a grip row)
    T.log = {}
    local nck = T.ncalls("r38c4")
    ok(T.key(wr, INV_DIR, A.accept) == false and FO._hold() ~= nil, "story 38 tap checkbox: Accept left to the Button, a hold starts")
    T.fire(T.CLICK, T.tagged("r38c4")) -- the Button's own click on the key's release
    ok(FO._hold() == nil and T.ncalls("r38c4") == nck + 1, "story 38 tap checkbox: it toggles once, the hold ends")
    clock = clock + 500000
    T.roTick()
    ok(FO._carry() == nil and #T.cbs == 0, "story 38 tap checkbox: no pickup")
    -- a grip row tap
    T.key(wr, D.up, INV_ACT)
    ok(T.agree("r38r3"), "story 38 Up: back on the grip row r3")
    ok(T.key(wr, INV_DIR, A.accept) == true and FO._hold() ~= nil, "story 38 tap grip row: handled, a hold starts")
    ok(T.keyUp(wr, A.accept) == false and FO._hold() == nil and FO.stats().taps >= 1, "story 38 tap grip row: the release ends the hold, unhandled")
    -- the choice and the slider: tap (nothing), hold (pickup) and back
    for _, k in ipairs({ { "r38ch", "r38r9" }, { "r38sl", "r38r10" } }) do
        FO._input("keys")
        local lines = FO.lines(C.windowHost("R38"), "#close:R38")
        local el = C.els[k[1]]
        -- move to it with Down
        for _ = 1, 12 do if T.agree(k[1]) then break end T.key(wr, D.down, INV_ACT) end
        ok(T.agree(k[1]), "story 38 setup: " .. k[1] .. " focused")
        local nk = T.ncalls(k[1])
        ok(T.key(wr, INV_DIR, A.accept) == true and T.keyUp(wr, A.accept) == false and T.ncalls(k[1]) == nk, "story 38 tap " .. k[1] .. ": handled, nothing changes")
        T.key(wr, INV_DIR, A.accept)
        clock = clock + 500000
        T.roTick()
        ok(FO._carry() and FO._carry().rowId == k[2] and F.focus == T.tagged(k[2]), "story 38 hold " .. k[1] .. ": its row is picked up, focus on the row")
        ok(T.keyUp(wr, A.accept) == true and FO._carry() == nil and T.agree(k[1]) and T.ncalls(k[1]) == nk, "story 38 hold " .. k[1] .. ": release drops, focus back, no change")
    end
    ok(#T.cbs == 0, "story 38: no callback without an order change", #T.cbs)
    -- A plain button (a gear in r6): a tap clicks once; a hold picks the row up and the release drops it without a click
    B.create{ id = "r38g6", place = { row = rows[6] }, icon = { icon = "gear" }, iconSize = 28, dimmed = true, onClick = T.rec("r38g6") }
    tick()
    FO.used(C.els["r38g6"], true)
    FO._input("keys")
    ok(T.agree("r38g6"), "story 38 setup: r6's gear focused", SC.stats().focus)
    local ng = T.ncalls("r38g6")
    ok(T.key(wr, INV_DIR, A.accept) == false and FO._hold() ~= nil, "story 38 tap button: Accept left to the Button, a hold starts")
    T.fire(T.CLICK, T.tagged("r38g6")) -- the Button's own click on the key's release
    clock = clock + 500000
    T.roTick()
    ok(T.ncalls("r38g6") == ng + 1 and FO._hold() == nil and FO._carry() == nil, "story 38 tap button: it clicks once, no pickup")
    T.key(wr, INV_DIR, A.accept)
    clock = clock + 500000
    T.roTick()
    ok(FO._carry() and FO._carry().rowId == "r38r6" and F.focus == T.tagged("r38r6"), "story 38 hold button: its row is picked up, focus on the row")
    ok(T.keyUp(wr, A.accept) == true and FO._carry() == nil and T.ncalls("r38g6") == ng + 1 and T.agree("r38g6"),
        "story 38 hold button: the release drops it, no click, focus back on the gear")
    -- A checkbox: a hold picks up and drops without toggling
    FO.used(C.els["r38c4"], true)
    FO._input("keys")
    local nc4, was4 = T.ncalls("r38c4"), C.els["r38c4"].checked
    T.key(wr, INV_DIR, A.accept)
    clock = clock + 500000
    T.roTick()
    ok(FO._carry() and FO._carry().rowId == "r38r4", "story 38 hold checkbox: its row is picked up")
    ok(T.keyUp(wr, A.accept) == true and FO._carry() == nil and T.ncalls("r38c4") == nc4 and C.els["r38c4"].checked == was4 and T.agree("r38c4"),
        "story 38 hold checkbox: the release drops it without toggling")
    ok(#T.cbs == 0, "story 38 tap and hold on a button and a checkbox: no callback", #T.cbs)

    -- Carry: grip focused (r3); Enter, Down, Down, Enter -> moved 2 down live, one onReorder at the drop
    for _ = 1, 12 do if T.agree("r38r3") then break end T.key(wr, D.up, INV_ACT) end
    ok(T.agree("r38r3"), "story 38 carry setup: r3 focused")
    local loads, gets = AS.stats.loads, F.getAssets
    AS._reset() -- cold: no carry instance, no strong one either
    T.key(wr, INV_DIR, A.accept)
    clock = clock + 300000
    T.roTick()
    ok(FO._carry() == nil and FO._hold() ~= nil, "story 38 hold: not yet at 0.3 s")
    clock = clock + 150000
    T.roTick()
    local rw = T.tagged("r38r3")
    ok(FO._carry() and FO.stats().pickups >= 1 and rw.shift and rw.shift[1] == theme.reorder.lift, "story 38 pickup: the row lifted by theme.reorder.lift", rw.shift and rw.shift[1])
    ok(C.els["r38r3"].carryBg ~= "carry", "story 38 cold: no carry instance inside the key path", C.els["r38r3"].carryBg)
    ok(F.getAssets == gets, "story 38 pickup: no GetAsset inside the key path", F.getAssets - gets)
    ok(T.key(wr, D.down, INV_ACT) and T.ids("r38l") == "r38r1 r38r2 r38r4 r38r3 r38r5 r38r6 r38r7 r38r8 r38r9 r38r10", "story 38 carry Down: r3 one slot down, live", T.ids("r38l"))
    ok(T.box("r38l") == T.ids("r38l") and F.focus == rw, "story 38 carry Down: the box rebuilt, focus kept on the row")
    ok(T.key(wr, D.down, INV_ACT) and T.ids("r38l") == "r38r1 r38r2 r38r4 r38r5 r38r3 r38r6 r38r7 r38r8 r38r9 r38r10", "story 38 carry Down again", T.ids("r38l"))
    ok(#T.cbs == 0, "story 38 carry: no callback while held")
    ok(T.key(wr, D.left, INV_ACT) and T.key(wr, D.right, INV_ACT) and T.ids("r38l"):find("r38r5 r38r3", 1, true), "story 38 carry Left / Right: handled, nothing")
    ok(T.key(wr, INV_DIR, A.accept) and FO._carry() ~= nil, "story 38 carry: the held key's repeat is handled")
    tick() -- the UI tick upgrades the carry band
    ok(C.els["r38r3"].carryBg == "carry" and T.matOf("r38r3") and T.matOf("r38r3").params and T.matOf("r38r3").params.CinematicBaseColor.R == theme.game.carryRowColors.CinematicBaseColor.r,
        "story 38 tick: the carry band upgraded", C.els["r38r3"].carryBg)
    loads, gets = AS.stats.loads, F.getAssets
    ok(T.keyUp(wr, A.accept) == true and #T.cbs == 1 and T.cbs[1].ids == "r38r1 r38r2 r38r4 r38r5 r38r3 r38r6 r38r7 r38r8 r38r9 r38r10" and T.cbs[1].h == L,
        "story 38 drop: one onReorder(list, ids) with the new order", T.cbs[1] and T.cbs[1].ids)
    ok(cbIn[1] and cbIn[1] > 0, "story 38 onReorder runs with C.inDispatch raised", cbIn[1])
    ok(rw.shift[1] == 0 and T.agree("r38r3") and (T.strong("r38r3") or T.selected("r38r3")), "story 38 drop: the lift goes, focus and the band on r3")
    ok(AS.stats.loads == loads and F.getAssets == gets and C.inDispatch == 0, "story 38 drop: no asset load in the release hook, the dispatch depth back to 0", F.getAssets - gets)
    -- Carry cancel: Enter, Down, Escape -> the pickup order back, the window open, no callback
    T.key(wr, INV_DIR, A.accept); clock = clock + 500000; T.roTick()
    ok(T.key(wr, D.down, INV_ACT) and T.ids("r38l"):find("r38r6 r38r3", 1, true), "story 38 cancel: moved first", T.ids("r38l"))
    ok(T.key(wr, INV_DIR, A.back) and FO._carry() == nil and T.ids("r38l") == T.cbs[1].ids and rec.open and #T.cbs == 1, "story 38 carry cancel: Escape restores, the window stays, no callback", T.ids("r38l"))
    ok(T.box("r38l") == T.ids("r38l") and T.agree("r38r3"), "story 38 carry cancel: the box rebuilt, focus on r3")
    ok(T.keyUp(wr, A.accept) == false, "story 38 the release after a cancel: nothing")
    -- Edge: Up at the segment top (r2 is the first movable row: r1 locked)
    for _ = 1, 12 do if T.agree("r38c2") then break end T.key(wr, D.up, INV_ACT) end
    T.key(wr, INV_DIR, A.accept); clock = clock + 500000; T.roTick()
    local before = T.ids("r38l")
    local edges = FO.stats().carryEdges
    ok(FO._carry() and FO._carry().rowId == "r38r2" and T.key(wr, D.up, INV_ACT) and T.ids("r38l") == before and FO.stats().carryEdges == edges + 1,
        "story 38 carry edge: Up at the segment top is handled, nothing moves")
    ok(T.keyUp(wr, A.accept) and #T.cbs == 1, "story 38 carry edge: the drop changes nothing, no callback")
    -- Hover during a carry: ignored
    T.key(wr, INV_DIR, A.accept); clock = clock + 500000; T.roTick()
    local ign = FO.stats().hoverIgnored
    T.move(); T.hover(T.tagged("r38r6"))
    ok(FO._carry() ~= nil and FO.stats().hoverIgnored == ign + 1 and F.focus == T.tagged("r38r2"), "story 38 a hover during a carry is ignored")
    -- Interrupted: a click cancels (pickup order back, no callback)
    T.key(wr, D.down, INV_ACT)
    T.fire(T.CLICK, T.tagged("r38c6"))
    ok(FO._carry() == nil and T.ids("r38l") == before and #T.cbs == 1, "story 38 interrupted: a click cancels, the order back", T.ids("r38l"))
    -- Interrupted: an API setOrder during a carry (carry restored first, then the new order; no callback)
    for _ = 1, 12 do if T.agree("r38c2") then break end T.key(wr, D.up, INV_ACT) end
    T.key(wr, INV_DIR, A.accept); clock = clock + 500000; T.roTick()
    T.key(wr, D.down, INV_ACT)
    local PNL = require("nucleus.ui.panel")
    local order = PNL.order(L)
    order[4], order[5] = order[5], order[4] -- the order the dependent read during the carry, two rows swapped
    local want = {}
    for i, h in ipairs(order) do want[i] = h.id end
    PNL.setOrder(L, order)
    ok(FO._carry() == nil and T.ids("r38l") == table.concat(want, " ") and #T.cbs == 1 and C.els["r38r2"].carryBg == nil,
        "story 38 interrupted: setOrder cancels the carry first, its own order applies, no callback", T.ids("r38l"))
    ok(T.keyUp(wr, A.accept) == false and #T.cbs == 1, "story 38 interrupted: setOrder never calls onReorder")
    -- Interrupted: panel.move during a carry: the pickup order back first, then that one move
    for _ = 1, 12 do if T.agree("r38c2") then break end T.key(wr, D.up, INV_ACT) end
    T.key(wr, INV_DIR, A.accept); clock = clock + 500000; T.roTick()
    local pick = {}
    for i, ch in ipairs(C.els["r38l"].children) do pick[i] = ch.id end
    T.key(wr, D.down, INV_ACT)
    ok(FO._carry() ~= nil and T.ids("r38l") ~= table.concat(pick, " "), "story 38 move setup: carried one slot down")
    for i, id in ipairs(pick) do if id == "r38r9" then table.remove(pick, i) break end end
    table.insert(pick, 2, "r38r9")
    PNL.move(L, C.els["r38r9"].handle, 2)
    ok(FO._carry() == nil and T.ids("r38l") == table.concat(pick, " ") and #T.cbs == 1,
        "story 38 interrupted: panel.move cancels the carry first, then only its own move applies, no callback", T.ids("r38l"))
    T.keyUp(wr, A.accept)
    -- Interrupted: a child removed; a row locked; a hover-free focus change
    for _, how in ipairs({ "remove", "lock", "focus" }) do
        for _ = 1, 12 do if T.agree("r38c2") then break end T.key(wr, D.up, INV_ACT) end
        T.key(wr, INV_DIR, A.accept); clock = clock + 500000; T.roTick()
        T.key(wr, D.down, INV_ACT)
        local was = T.ids("r38l")
        ok(FO._carry() ~= nil, "story 38 interrupted " .. how .. ": carrying")
        if how == "remove" then
            local tmp = RS.create{ id = "r38tmp", place = { list = L } }
            ok(FO._carry() == nil, "story 38 interrupted: a child added cancels")
            RS.remove(tmp)
        elseif how == "lock" then
            RS.setLocked(rows[8], true)
            ok(FO._carry() == nil and T.tagged("r38r2").shift[1] == 0, "story 38 interrupted: a lock cancels")
            RS.setLocked(rows[8], false)
        else
            F.focus = T.btn("r38c6")
            T.roTick()
        end
        ok(FO._carry() == nil and #T.cbs == 1, "story 38 interrupted " .. how .. ": cancelled, no callback")
        T.keyUp(wr, A.accept)
    end
    -- Interrupted (follow-up review): a sibling removed, a same-id row.create that locks, a same-id list.create that
    -- turns reorderable off; each cancels the carry, the pickup order comes back (minus a removed row), no callback
    T.tmp38 = RS.create{ id = "r38tmp", place = { list = L } }
    tick()
    for _, how in ipairs({ "sibling", "relock", "unreorderable" }) do
        for _ = 1, 12 do if T.agree("r38c2") then break end T.key(wr, D.up, INV_ACT) end
        T.key(wr, INV_DIR, A.accept); clock = clock + 500000; T.roTick()
        local pick = {}
        for _, ch in ipairs(C.els["r38l"].children) do if not (how == "sibling" and ch.id == "r38tmp") then pick[#pick + 1] = ch.id end end
        T.key(wr, D.down, INV_ACT)
        ok(FO._carry() ~= nil, "story 38 interrupted " .. how .. ": carrying")
        if how == "sibling" then
            RS.remove(T.tmp38)
        elseif how == "relock" then
            RS.create{ id = "r38r8", place = { list = L }, locked = true }
        else
            LS.create{ id = "r38l", place = { screen = R, corner = "top-left" }, size = { 600, 200 }, reorderable = false }
        end
        ok(FO._carry() == nil and T.ids("r38l") == table.concat(pick, " ") and #T.cbs == 1,
            "story 38 interrupted " .. how .. ": cancelled, the pickup order back, no callback", T.ids("r38l"))
        ok(T.keyUp(wr, A.accept) == false and #T.cbs == 1, "story 38 interrupted " .. how .. ": the release drops nothing")
        if how == "relock" then
            RS.create{ id = "r38r8", place = { list = L }, locked = false }
        elseif how == "unreorderable" then
            LS.create{ id = "r38l", place = { screen = R, corner = "top-left" }, size = { 600, 200 }, reorderable = true,
                onReorder = function(h, ids)
                    T.cbs[#T.cbs + 1] = { h = h, ids = table.concat(ids, " ") }
                    cbIn[#cbIn + 1] = C.inDispatch
                    if T.cbThrow then error("boom in onReorder") end
                end }
        end
        tick()
    end
    T.tmp38 = nil
    -- Interrupted: a covered window
    for _ = 1, 12 do if T.agree("r38c2") then break end T.key(wr, D.up, INV_ACT) end
    T.key(wr, INV_DIR, A.accept); clock = clock + 500000; T.roTick()
    local W2 = SC.open{ id = "R38top" }
    ok(FO._carry() == nil and C.els["r38r2"].carryBg == nil and T.tagged("r38r2").shift[1] == 0, "story 38 interrupted: a covered window cancels")
    SC.close(W2)
    tick()
    -- Callback throws: the order stays, one WARN per list
    T.cbThrow = true
    local nW = countLogs("list 'r38l' onReorder")
    for _ = 1, 2 do
        for _ = 1, 12 do if T.agree("r38c2") then break end T.key(wr, D.up, INV_ACT) end
        T.key(wr, INV_DIR, A.accept); clock = clock + 500000; T.roTick()
        local was = T.ids("r38l")
        T.key(wr, D.down, INV_ACT)
        local moved = T.ids("r38l")
        T.keyUp(wr, A.accept)
        ok(T.ids("r38l") == moved and moved ~= was, "story 38 callback throws: the order stays")
    end
    ok(countLogs("list 'r38l' onReorder") == nW + 1 and C.inDispatch == 0, "story 38 callback throws: one WARN per list", countLogs("list 'r38l' onReorder") - nW)
    T.cbThrow = nil
    T.cbs = {}

    -- Mouse: r3 dragged between r5 and r6 -> r1 r2 r4 r5 r3 r6...; one onReorder; focus on r3's line
    LS.create{ id = "r38l", place = { screen = R, corner = "top-left" }, size = { 600, 200 }, reorderable = true,
        onReorder = function(h, ids) T.cbs[#T.cbs + 1] = { h = h, ids = table.concat(ids, " ") } end }
    local base = { "r38r1", "r38r2", "r38r3", "r38r4", "r38r5", "r38r6", "r38r7", "r38r8", "r38r9", "r38r10" }
    local hs = {}
    for i, id in ipairs(base) do hs[i] = C.els[id].handle end
    PNL.setOrder(L, hs)
    tick()
    loads, gets = AS.stats.loads, F.getAssets
    local lifts = F.lifts or 0
    F.stale = true -- VM run 1: rows out of view have no painted geometry; the drag must not depend on it
    local okD, op = T.dragStart("r38r3")
    rw = T.tagged("r38r3")
    ok(okD == true and op.DefaultDragVisual and op.DefaultDragVisual.__class == "WBP_NucleusLift_C" and op.Pivot == 0 and op.Tag == rw.tag,
        "story 38 drag start: DragOk, the lift as the visual from the grab point, the row's tag")
    local lift = op.DefaultDragVisual
    ok(rw.opacity == theme.reorder.sourceOpacity and RO.stats().dragging, "story 38 drag: the source at 40%", rw.opacity)
    ok(#lift.HBox.children == 1 and lift.HBox.children[1].text == "MOD 3" and lift.HBox.children[1].Slot.Size.SizeRule == 1 and lift.HBox.children[1].Slot.Size.Value == 4,
        "story 38 lift: a copy of the row's text, its fill weight")
    ok(lift.size and lift.size[2] == rw.h and lift.mat ~= nil, "story 38 lift: the row's size, the band's look", lift.size and table.concat(lift.size, "x"))
    ok(AS.stats.loads == loads and F.getAssets == gets, "story 38 drag start: no asset load in the hook", F.getAssets - gets)
    ok(T.agree("r38r3") and C.inDispatch == 0, "story 38 drag: focus and the band on r3")
    T.at("r38l", (T.rowY("r38r5", true) + T.rowY("r38r6", true)) / 2)
    T.roTick()
    local lw = T.tagged("r38l")
    ok(lw.Line.vis == 3 and lw.Line.color and lw.Line.color.R == theme.game.accent.r and math.abs(lw.Line.Slot.top - (T.rowY("r38r6") - 2 - 1)) <= 1,
        "story 38 drag: the accent line at the slot between r5 and r6", lw.Line.Slot.top)
    loads, gets = AS.stats.loads, F.getAssets
    T.drop("r38l", op, true)
    ok(AS.stats.loads == loads and F.getAssets == gets, "story 38 mouse drop: no asset load in the hook", F.getAssets - gets)
    ok(T.ids("r38l") == "r38r1 r38r2 r38r4 r38r5 r38r3 r38r6 r38r7 r38r8 r38r9 r38r10" and #T.cbs == 1 and T.cbs[1].ids == T.ids("r38l"),
        "story 38 mouse drop: r3 between r5 and r6, one onReorder with the same ids", T.ids("r38l"))
    ok(rw.opacity == 1 and lw.Line.vis == 1 and not RO.stats().dragging and T.agree("r38r3"), "story 38 mouse drop: opacity back, the line hidden, focus on r3")
    -- Same slot: directly above itself -> no rebuild, no callback
    local rebuilds = C.stats.panelRebuilds
    okD, op = T.dragStart("r38r3")
    T.at("r38l", T.rowY("r38r3") - 1)
    T.roTick()
    T.drop("r38l", op, true)
    ok(#T.cbs == 1 and C.stats.panelRebuilds == rebuilds, "story 38 same slot: no rebuild, no callback")
    -- Locked barrier: drag r3 above r1 -> the line below r1; the drop puts r3 at index 2
    okD, op = T.dragStart("r38r3")
    T.at("r38l", 2)
    T.roTick()
    ok(lw.Line.Slot.top >= T.rowY("r38r2") - 4, "story 38 locked barrier: the line clamps below r1", lw.Line.Slot.top)
    T.drop("r38l", op, true)
    ok(T.ids("r38l"):sub(1, 17) == "r38r1 r38r3 r38r2" and #T.cbs == 2, "story 38 locked barrier: r3 at index 2", T.ids("r38l"))
    -- Cancel: Escape (the row's OnDragCancelled), a right release, a release outside, B
    local cancels = RO.stats().dragCancels
    for _, how in ipairs({ "escape", "right", "outside", "b" }) do
        local was = T.ids("r38l")
        okD, op = T.dragStart("r38r4")
        T.at("r38l", T.rowY("r38r7", true))
        T.roTick()
        if how == "escape" then T.dragCancel("r38r4")
        elseif how == "right" then T.drop("r38l", op, false)
        elseif how == "outside" then T.at("r38l", 400); T.drop("r38l", op, true)
        else
            ok(T.key(wr, INV_DIR, A.back) and rec.open, "story 38 B during a drag: handled, the window stays")
            ok(F.dragCancels > 0 and not F.dragging, "story 38 B: Slate's drag cancelled")
            T.dragCancel("r38r4")
        end
        ok(okD and T.ids("r38l") == was and #T.cbs == 2 and T.tagged("r38r4").opacity == 1 and lw.Line.vis == 1 and not RO.stats().dragging,
            "story 38 cancel (" .. how .. "): order unchanged, no callback, opacity back, line hidden", T.ids("r38l"))
    end
    ok(RO.stats().dragCancels == cancels + 4, "story 38 cancel: four counted", RO.stats().dragCancels - cancels)
    ok(rec.open, "story 38 cancel: the window stays open")
    -- Auto-scroll: the pointer held in the bottom 32 units scrolls to the end; the drop lands at a later slot
    okD, op = T.dragStart("r38r2")
    T.at("r38l", 200 - 8)
    local o0 = lw.Scroll.offset
    for _ = 1, 40 do clock = clock + 16000; T.roTick() end
    ok(lw.Scroll.offset > o0 and math.abs(lw.Scroll.offset - lw.Scroll:GetScrollOffsetOfEnd()) < 1e-6, "story 38 auto-scroll: the offset grows to the end", lw.Scroll.offset)
    T.at("r38l", T.rowY("r38r9", true) + 1)
    T.drop("r38l", op, true)
    ok(T.ids("r38l"):find("r38r9 r38r2 r38r10", 1, true) and #T.cbs == 3, "story 38 auto-scroll: the drop lands at a slot that was off-screen", T.ids("r38l"))
    lw.Scroll.offset = 0
    -- Interrupted drag: an API change cancels it (Slate's drag too)
    okD, op = T.dragStart("r38r4")
    local dc = F.dragCancels
    RS.setVisible(rows[7], false)
    ok(not RO.stats().dragging and F.dragCancels == dc + 1 and T.tagged("r38r4").opacity == 1, "story 38 interrupted drag: an API change cancels it")
    T.dragCancel("r38r4")
    RS.setVisible(rows[7], true)
    -- IsDragDropping turns false without an end this state saw: the loop cancels
    okD, op = T.dragStart("r38r4")
    F.dragging = false
    T.roTick()
    ok(not RO.stats().dragging and #T.cbs == 3, "story 38 loop: IsDragDropping false ends the drag, no callback")
    -- Cold lift class: the drag runs without a copy, no GetAsset in the hook
    kill(T.LIFTCLASS)
    gets = F.getAssets
    okD, op = T.dragStart("r38r4")
    ok(okD and op.DefaultDragVisual == nil and op.Tag == "" and F.getAssets == gets, "story 38 cold lift class: no copy, no GetAsset", F.getAssets - gets)
    T.dragCancel("r38r4")
    T.LIFTCLASS = cls("/Game/Mods/Nucleus/WBP_NucleusLift.WBP_NucleusLift_C")
    tick()
    -- Foreign or stale: another mod's row, a stale widget, an off-thread hook, another mod's list, an operation not ours
    local ign0 = RO.stats().ignored
    local other = tagged(widget("WBP_NucleusRow_C", "/Engine/Transient.WBP_NucleusRow_C_o38"))
    other.tag = "nucleus:OtherMod:r38r3"
    other.DragOp, other.DragOk = obj({}), false
    fireHook(T.DSTART, other)
    ok(other.DragOk == false, "story 38 foreign row: DragOk stays false")
    local copy = tagged(widget("WBP_NucleusRow_C", "/Engine/Transient.WBP_NucleusRow_C_c38"))
    copy.tag = "nucleus:TestMod:r38r3"
    copy.DragOp, copy.DragOk = obj({}), false
    fireHook(T.DSTART, copy)
    ok(copy.DragOk == false, "story 38 stale widget: DragOk stays false")
    local realDeref = _G.Nucleus_Deref
    _G.Nucleus_Deref = function() error("off the game thread") end
    local rw4 = T.tagged("r38r4")
    rw4.DragOp, rw4.DragOk = obj({}), false
    fireHook(T.DSTART, rw4)
    _G.Nucleus_Deref = realDeref
    ok(rw4.DragOk == false, "story 38 off-thread: DragOk stays false")
    okD, op = T.dragStart("r38r4")
    local olw = tagged(widget("WBP_NucleusList_C", "/Engine/Transient.WBP_NucleusList_C_o38"))
    olw.tag = "nucleus:OtherMod:r38l"
    olw.DropOp, olw.DropLeft = op, true
    fireHook(T.DROP, olw)
    ok(RO.stats().dragging, "story 38 another mod's list: ignored (its own state decides)")
    lw.DropOp, lw.DropLeft = obj({}), true
    fireHook(T.DROP, lw)
    ok(RO.stats().dragging and #T.cbs == 3, "story 38 an operation not this state's: ignored")
    T.dragCancel("r38r4")
    ok(RO.stats().ignored >= ign0 + 5, "story 38 foreign or stale: counted", RO.stats().ignored - ign0)
    -- Hover during a drag: ignored
    okD, op = T.dragStart("r38r4")
    ign = FO.stats().hoverIgnored
    T.move(); T.hover(T.tagged("r38r6"))
    ok(FO.stats().hoverIgnored == ign + 1, "story 38 a hover during a drag is ignored")
    T.dragCancel("r38r4")
    -- Elsewhere: not the top window -> no flag, a drag start refused
    local Wc = SC.open{ id = "R38c" }
    tick()
    ok(T.tagged("r38r4").Draggable == false, "story 38 covered: Draggable off")
    okD = T.dragStart("r38r4")
    ok(okD == false, "story 38 covered: a drag start is refused")
    SC.close(Wc)
    tick()
    ok(T.tagged("r38r4").Draggable == true, "story 38 top again: Draggable on")
    -- reorderable off (same-id create): flags off; a list on another host: no effect
    LS.create{ id = "r38l", place = { screen = R, corner = "top-left" }, size = { 600, 200 } }
    tick()
    ok(T.tagged("r38r4").Draggable == false and C.els["r38l"].onReorder == nil, "story 38 same-id create: reorderable off, the flags follow")
    ok(not FO._gripRow(C.els["r38r3"]), "story 38 reorderable off: no grip stop")
    LS.create{ id = "r38l", place = { screen = R, corner = "top-left" }, size = { 600, 200 }, reorderable = true }
    tick()
    ok(T.tagged("r38r4").Draggable == true, "story 38 same-id create: reorderable on again")
    -- A row's widget replaced by a new one at the same address: its flags are written again (the live widget decides)
    do
        local WBL = F.objects["/Script/UMG.Default__WidgetBlueprintLibrary"]
        for _, id in ipairs({ "r38r3", "r38r5" }) do
            local el = C.els[id]
            local old = handles[el.ref]
            local nw = WBL:Create(nil, ROWCLASS)
            nw.__addr, nw.tag, nw.parent, nw.Slot = old.__addr, old.tag, old.parent, old.Slot
            handles[el.ref] = nw
            if id == "r38r3" then
                ok(FO._targetOf(el) == nw and nw.bIsFocusable == true, "story 38 reused address: a grip row's new widget is made focusable")
            else
                RO.sync()
                ok(nw.Draggable == true, "story 38 reused address: a movable row's new widget gets Draggable")
            end
            handles[el.ref] = old
        end
    end
    SC.close(R)
    ok(FO.stats().faults == faults0 and RO.stats().faults == roFaults0 and C.inDispatch == 0, "story 38: no fault", RO.stats().faults - roFaults0)
end

-- ---------------------------------------------------------------- Mod Manager v2 story 4: the text box and the focus model
do
    local TBm = require("nucleus.ui.textbox")
    local TBCLASS = cls("/Game/Mods/Nucleus/WBP_NucleusTextbox.WBP_NucleusTextbox_C")
    local function newTextboxW()
        local w = widget("WBP_NucleusTextbox_C", "/Engine/Transient.WBP_NucleusTextbox_C_" .. (F.addr + 0x100), 40)
        tagged(w)
        w.Frame = T.inner(4)
        w.text, w.hint = "", ""
        local box = focusable({ __alive = true })
        box.parent = w
        function box:GetText() return { ToString = function() return w.text end } end
        w.Box = box
        function w:SetBoxText(t) self.text = t end
        function w:SetHint(h) self.hint = h end
        function w:SetWidth(v) self.width = v end
        function w:SetEnabledState(e) self.enabled = e end
        function w:SetBoxLook(f, size) self.look = { f, size } end
        function w:SetRenderOpacity(o) self.opacity = o end
        focusable(w)
        function w:SetFocusLook(on) self.focusLook = on; self.looks = (self.looks or 0) + 1 end
        return w
    end
    local WBL = F.objects["/Script/UMG.Default__WidgetBlueprintLibrary"]
    local base = WBL.Create
    WBL.Create = function(self, world, c, owner)
        if c == TBCLASS then return newTextboxW() end
        return base(self, world, c, owner)
    end
    local CHG, COM = "WBP_NucleusTextbox_C:Nucleus_OnTextboxChanged", "WBP_NucleusTextbox_C:Nucleus_OnTextboxCommit"
    local faults0 = FO.stats().faults
    local queue = {}
    ExecuteInGameThreadWithDelay = function(_, fn) queue[#queue + 1] = fn end
    local function runQueue() local q = queue; queue = {}; for _, f in ipairs(q) do f() end end
    local commits = {}
    local W = SC.open{ id = "TBW" }
    local wk = T.screenOf("TBW")
    local lst = LS.create{ id = "tbl", place = { screen = W, corner = "top-left" }, size = { 600, 300 } }
    local r1 = RS.create{ id = "tbr1", place = { list = lst } }
    local tb = TBm.create{ id = "ftb", place = { row = r1, fill = 1 }, hint = "SEARCH", onChange = T.rec("ftb"),
        onCommit = function(_, t) commits[#commits + 1] = t end }
    local r2 = RS.create{ id = "tbr2", place = { list = lst } }
    local bt = B.create{ id = "fbt", label = "DETAILS", place = { row = r2 }, onClick = function() end }
    tick()
    local w = T.tagged("ftb")
    ok(w ~= nil and C.els["ftb"] and FO.focusable(C.els["ftb"]), "v2 story 4: a text box is focusable")
    ok(T.agree("ftb"), "v2 story 4: the text box (the first line) holds focus on open", SC.stats().focus)
    -- Accept: the EditableText takes keyboard focus (typing)
    local types0 = FO.stats().types
    ok(T.key(wk, INV_DIR, A.accept) == true and F.focus == w.Box and FO.stats().types == types0 + 1, "v2 story 4: Accept on the field gives the box keyboard focus")
    ok(FO._typingIn(FO.lines(C.windowHost("TBW"), "#close:TBW")) == C.els["ftb"], "v2 story 4: the model sees the box being typed in")
    -- while typing every key but Escape is the box's
    ok(T.key(wk, D.down, INV_ACT) == false and F.focus == w.Box, "v2 story 4 typing: Down is left to the box")
    ok(T.key(wk, INV_DIR, A.accept) == false and F.focus == w.Box, "v2 story 4 typing: Accept (Enter, Space) is left to the box")
    ok(T.key(wk, D.left, INV_ACT) == false and F.focus == w.Box, "v2 story 4 typing: Left is left to the box (the caret)")
    -- typing reports through the change hook: onChange, focus stays in the box
    w.text = "clo"; fireHook(CHG, w)
    ok(TBm.get(tb) == "clo" and T.ncalls("ftb") == 1 and F.focus == w.Box, "v2 story 4 typing: onChange('clo'), keyboard focus stays in the box")
    -- Escape while typing: back to the field, the text kept, the window open
    local leaves0 = FO.stats().leaves
    ok(T.key(wk, INV_DIR, A.back) == true and F.focus == w and SC.isOpen(W) and FO.stats().leaves == leaves0 + 1 and TBm.get(tb) == "clo",
        "v2 story 4: Escape while typing leaves the box for the field, keeps the text, the window stays open")
    ok(T.agree("ftb"), "v2 story 4: the model is on the field after Escape")
    -- Down from the field: the next line (the button)
    ok(T.key(wk, D.down, INV_ACT) and T.agree("fbt"), "v2 story 4: Down from the field reaches the next row's button")
    -- A mouse click into the box while the model is elsewhere: typing moves the model there without stealing keyboard focus
    F.focus = w.Box
    w.text = "clock"; fireHook(CHG, w)
    ok(SC.stats().focus == "ftb" and F.focus == w.Box and T.ncalls("ftb") == 2, "v2 story 4: typing after a click moves the model to the field, the box keeps focus")
    ok(w.focusLook == true and T.tagged("fbt").focusLook == false, "v2 story 4: the field shows the focus look, the button lost it")
    -- Enter commits; the box's focus is cleared; focus goes back to the field
    clock = clock + 300000
    fireHook(COM, w)
    F.focus = nil -- ClearKeyboardFocusOnCommit
    local hb0 = FO.stats().handBacks
    ok(#commits == 1 and commits[1] == "clock" and #queue >= 1, "v2 story 4: Enter commits 'clock' and schedules the hand-back", #commits .. "/" .. tostring(commits[1]) .. "/" .. #queue)
    runQueue()
    ok(F.focus == w and T.agree("ftb") and FO.stats().handBacks == hb0 + 1, "v2 story 4: after the commit keyboard focus is back on the field")
    -- The focus clear's own commit (same text, at once) is the same commit
    fireHook(COM, w)
    ok(#commits == 1, "v2 story 4: the focus clear's second commit of the same text is not another onCommit")
    runQueue()
    -- A commit because a click moved focus to a button: focus stays on the button
    F.focus = w.Box
    w.text = "hud"; fireHook(CHG, w)
    F.focus = T.btn("fbt")
    clock = clock + 300000
    fireHook(COM, w)
    runQueue()
    ok(F.focus == T.btn("fbt") and commits[#commits] == "hud", "v2 story 4: a commit by a click elsewhere leaves keyboard focus where the click put it")
    -- Back on the field, Escape (not typing) closes the window
    F.focus = w
    ok(T.key(wk, INV_DIR, A.back) == true and not SC.isOpen(W), "v2 story 4: Escape on the field (not typing) closes the window")
    -- after the window went, a scheduled hand-back does nothing
    clock = clock + 300000
    fireHook(COM, w)
    runQueue()
    ok(SC.isOpen(W) == false, "v2 story 4: a hand-back after the window closed does nothing")
    ExecuteInGameThreadWithDelay = nil
    ok(FO.stats().faults == faults0 and C.inDispatch == 0, "v2 story 4: no fault")
end

print(string.format("focus_test: %d passed, %d failed", pass, failN))
if failN > 0 then os.exit(1) end
