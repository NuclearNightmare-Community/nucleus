-- Unit tests for Mod Manager story 4 (core 0.10.0, core story 26, UI-11): checkbox, choice and slider-with-number
-- controls, outside the game. The fake engine is image_test.lua's (a live title-screen menu with a window over it), plus
-- core's WBP_NucleusChoice and WBP_NucleusSlider and the game's Settings slider template. This checks core's own logic
-- for every row of the story's I/O matrix (validation limits, range building, the slider's parse, clamp and round,
-- onChange exactly once per real change), not the engine; the in-game proof is run.ps1 -Scenario menu (CT lines).
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/controls_test.lua  (here: MiKTeX's texlua)
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.10.0", floor = "0.1.0" } end
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

-- ---------------------------------------------------------------- checkbox
local cb = CK.create{ id = "cb", place = { row = T.row }, onChange = T.rec("cb") }
local cbw = T.tagged("cb")
ok(cbw and cbw.__class == "WBP_NucleusButton_C", "checkbox: an icon-only button widget")
ok(T.iconPath(cbw) == T.UNTICKED and cbw.icon[2] == 28 and cbw.icon[3] == 28, "checkbox: the game's unticked texture at 28x28", T.iconPath(cbw))
ok(cbw.Box.wo == 28 and cbw.Label.vis == 1 and cbw.colors and cbw.colors[4] == 0, "checkbox: its box exactly 28, no label, no face (game look)")
ok(cbw.content and T.near(cbw.content[1], theme.game.text.r) and T.near(cbw.content[5], theme.game.textHover.r), "checkbox: lit on hover like an icon-only button")
ok(cbw.Slot.VerticalAlignment == 2, "checkbox: keeps its size in a row")
ok(CK.get(cb) == false, "checkbox: get() false by default")
tick()
ok(hookCount(T.CLICK) >= 1, "checkbox: the button click hook is registered from the poll")
T.fire(T.CLICK, cbw)
ok(CK.get(cb) == true and T.iconPath(cbw) == T.TICKED, "checkbox click: ticked")
ok(T.ncalls("cb") == 1 and T.last("cb").a == true and T.last("cb").h == cb, "checkbox click: onChange(h, true) once")
CK.set(cb, false)
ok(CK.get(cb) == false and T.iconPath(cbw) == T.UNTICKED and T.ncalls("cb") == 1, "checkbox set(false): unticked, no callback")
local n0 = C.stats.uobjectCalls
CK.set(cb, false)
ok(C.stats.uobjectCalls == n0, "checkbox set: the same state again makes no UObject call")
-- a throwing callback: one WARN, the checkbox keeps working
T.throws = 0
local cbt = CK.create{ id = "cbt", place = { row = T.row }, checked = true, onChange = function() T.throws = T.throws + 1 error("boom") end }
local cbtw = T.tagged("cbt")
T.fire(T.CLICK, cbtw); T.fire(T.CLICK, cbtw)
ok(T.throws == 2 and CK.get(cbt) == true and countLogs("WARN checkbox 'cbt' onChange: ") == 1 and countLogs("boom") == 1, "checkbox: a throwing onChange is logged once and the checkbox keeps working")
-- the texture swap inside the hook reads the cache only; a miss is applied on the next tick
A._reset()
local g0 = F.getAssets
T.fire(T.CLICK, cbw)
ok(F.getAssets == g0 and CK.get(cb) == true and T.iconPath(cbw) == T.UNTICKED, "checkbox click with a cold cache: no load inside the hook")
tick()
ok(T.iconPath(cbw) == T.TICKED, "checkbox click with a cold cache: the ticked texture on the next tick")
CK.set(cb, false)
-- disabled: dimmed, clicks ignored
local cbd = CK.create{ id = "cbd", place = { row = T.row }, enabled = false, size = 40, onChange = T.rec("cbd") }
local cbdw = T.tagged("cbd")
T.fire(T.CLICK, cbdw)
ok(T.ncalls("cbd") == 0 and CK.get(cbd) == false and cbdw.opacity == theme.disabledOpacity and cbdw.enabled == false and cbdw.icon[2] == 40,
    "checkbox enabled = false: dimmed, a click changes nothing, no callback; size 40")
-- the missing game texture: core's own icon
A._reset()
F.missing[T.TICKED] = true
local cbm = CK.create{ id = "cbm", place = { row = T.row }, checked = true, onChange = T.rec("cbm") }
ok(T.tagged("cbm").icon[1].__asset == "T_CheckboxOn", "checkbox: core's checkbox-on icon when the game texture can't be loaded")
F.missing[T.TICKED] = nil
CK.remove(cbm)
-- class-to-kind: the button class names the button kind; a checkbox's widget still belongs to it
ok(X._kindOfClass("WBP_NucleusButton_C") == "button" and X._sameClass("checkbox", "button") and not X._sameClass("checkbox", "choice"), "class-to-kind: the checkbox shares the button's class")

-- ---------------------------------------------------------------- choice
T.OPTS = { "A", "B", "C", "D", "E", "F" }
local hooksBefore = hookCount(T.PREV)
local ch = CH.create{ id = "ch", place = { row = T.row, fill = 2 }, options = T.OPTS, selected = 1, onChange = T.rec("ch") }
local chw = T.tagged("ch")
ok(chw and chw.value == "A" and chw.valueSets == 1, "choice: the first option shown at create (no blank picker)")
ok(chw.arrows[1] == false and chw.arrows[2] == true, "choice at 1: prev dimmed and inert, next on")
ok(chw.mat and chw.look and chw.look[2] == theme.game.controlFont.size and T.near(chw.look[3], theme.game.text.r), "choice: the game look (worn strip, AlumniSans, the menu's text colour)")
ok(chw.Slot.Size.SizeRule == 1 and chw.Slot.Size.Value == 2 and chw.Slot.VerticalAlignment == 0, "choice: fills its column (fill 2)")
ok(hookCount(T.PREV) == hooksBefore, "choice: no hook registered at create")
tick()
ok(hookCount(T.PREV) == 1 and hookCount(T.NEXT) == 1, "choice: prev and next hooks registered once, from the poll")
tick()
ok(hookCount(T.PREV) == 1, "choice: not registered twice")
T.fire(T.NEXT, chw); T.fire(T.NEXT, chw); T.fire(T.PREV, chw)
local i, o = CH.get(ch)
ok(i == 2 and o == "B" and chw.value == "B", "choice: next, next, prev shows option 2")
ok(T.ncalls("ch") == 3 and T.log[#T.log - 1].a == 3 and T.log[#T.log - 1].b == "C" and T.last("ch").a == 2 and T.last("ch").b == "B", "choice: three callbacks (2), (3, 'C'), (2, 'B')")
CH.set(ch, 1)
T.fire(T.PREV, chw)
ok(CH.get(ch) == 1 and T.ncalls("ch") == 3 and chw.arrows[1] == false, "choice at 1: prev does nothing (no wrap), no callback")
CH.set(ch, 6)
ok(chw.value == "F" and chw.arrows[2] == false and chw.arrows[1] == true and T.ncalls("ch") == 3, "choice set(6): last option, next dimmed, no callback")
T.fire(T.NEXT, chw)
ok(CH.get(ch) == 6 and T.ncalls("ch") == 3, "choice at the end: next does nothing")
-- a repeat within 250 ms is one click
CH.set(ch, 3)
T.fire(T.NEXT, chw); fireHook(T.NEXT, chw)
ok(CH.get(ch) == 4 and T.ncalls("ch") == 4, "choice: two clicks within 250 ms on one arrow step once")
fireHook(T.PREV, chw)
ok(CH.get(ch) == 3 and T.ncalls("ch") == 5, "choice: a click on the other arrow within 250 ms still steps (debounce per arrow)")
CH.set(ch, 1)
T.fire(T.PREV, chw); fireHook(T.NEXT, chw)
ok(CH.get(ch) == 2 and T.ncalls("ch") == 6, "choice: a click on the inert end arrow doesn't delay the other one")
fireHook(T.PREV, chw)
ok(CH.get(ch) == 1 and T.ncalls("ch") == 7, "choice: the inert click set no time for its arrow")
CH.set(ch, 4)
-- disabled
local chd = CH.create{ id = "chd", place = { row = T.row }, options = T.OPTS, selected = 3, enabled = false, onChange = T.rec("chd") }
local chdw = T.tagged("chd")
T.fire(T.NEXT, chdw)
ok(T.ncalls("chd") == 0 and CH.get(chd) == 3 and chdw.arrows[1] == false and chdw.arrows[2] == false and chdw.opacity == theme.disabledOpacity,
    "choice enabled = false: both arrows dimmed, opacity, a click ignored")
CH.setEnabled(chd, true)
ok(chdw.arrows[1] == true and chdw.arrows[2] == true and chdw.opacity == 1, "choice setEnabled(true): arrows back")
CH.setEnabled(chd, false)
-- another mod's widget and a stale one are ignored in silence
do
    local other = T.newChoiceW()
    other:SetTag("nucleus:OtherMod:ch")
    local s0 = CH._S.ignored
    T.fire(T.NEXT, other)
    ok(CH._S.ignored == s0 + 1 and CH.get(ch) == 4, "choice: another mod's widget ignored")
    local stale = T.newChoiceW()
    stale:SetTag("nucleus:TestMod:ch")
    T.fire(T.NEXT, stale)
    ok(CH._S.ignored == s0 + 2 and CH.get(ch) == 4, "choice: a widget that isn't the element's current one ignored")
end
-- a throwing onChange
local cht = CH.create{ id = "cht", place = { row = T.row }, options = { "x", "y", "z" }, onChange = function() error("bad choice") end }
local chtw = T.tagged("cht")
T.fire(T.NEXT, chtw); T.fire(T.NEXT, chtw)
ok(CH.get(cht) == 3 and countLogs("WARN choice 'cht' onChange: ") == 1 and countLogs("bad choice") == 1, "choice: a throwing onChange is logged once and the choice keeps working")
-- range
local r = CH.range{ min = 0, max = 20, step = 1, extra = { "Default" } }
ok(#r == 22 and r[1] == "Default" and r[2] == "0" and r[22] == "20", "range 0..20 step 1 with Default: 22 strings, Default first", #r)
r = CH.range{ id = "r1", min = 0, max = 2, step = 0.5 }
ok(table.concat(r, ",") == "0.0,0.5,1.0,1.5,2.0", "range 0..2 step 0.5: one decimal", table.concat(r, ","))
r = CH.range{ min = -1, max = 1, step = 1 }
ok(table.concat(r, ",") == "-1,0,1", "range -1..1: no -0")
ok(#CH.range{ min = 1, max = 64, step = 1 } == 64, "range: 64 options allowed")
-- re-create with the same id
CH.create{ id = "ch", place = { row = T.row, fill = 2 }, options = { "P", "Q" }, selected = 2, onChange = T.rec("ch") }
ok(T.tagged("ch") == chw and chw.value == "Q" and chw.arrows[1] == true and chw.arrows[2] == false, "choice: same id updates options and selection on the same widget")
CH.create{ id = "ch", place = { row = T.row, fill = 2 }, options = T.OPTS, selected = 4, onChange = T.rec("ch") }

-- ---------------------------------------------------------------- slider
local sl = SL.create{ id = "sl", place = { row = T.row, fill = 3 }, min = 0, max = 200, step = 1, value = 100, defaultValue = 50, hint = "DEFAULT (50)", onChange = T.rec("sl") }
local slw = T.tagged("sl")
ok(slw and slw.range[1] == 0 and slw.range[2] == 200 and slw.range[3] == 1 and slw.range[4] == 0, "slider: range 0..200 step 1, no decimals")
ok(slw.barValue == 100 and slw.text == "100" and slw.hint == "DEFAULT (50)", "slider: value 100 shown, hint set")
ok(slw.boxW == SL._BOX_HINT_W, "slider: the box is wide enough for its hint", slw.boxW)
ok(slw.copied == T.TEMPLATE, "slider: the game's Settings slider style copied from its template")
ok(slw.mat and slw.look and slw.look[2] == theme.game.controlFont.size, "slider: the number box in the game look")
tick()
ok(hookCount(T.END) == 1 and hookCount(T.COMMIT) == 1, "slider: end and commit hooks registered once, from the poll")
-- a drag (the Blueprint writes the box every frame; Lua hears only the end)
slw.barValue, slw.text = 57.3, "57"
local sets0 = slw.sets
T.fire(T.END, slw)
ok(SL.get(sl) == 57 and T.ncalls("sl") == 1 and T.last("sl").a == 57 and slw.text == "57" and slw.sets == sets0 + 1, "slider drag end: 57, one callback")
T.fire(T.END, slw)
ok(T.ncalls("sl") == 1, "slider drag end without a change: no callback")
-- typing
slw.text = "57"; T.fire(T.COMMIT, slw)
ok(T.ncalls("sl") == 1, "slider commit of the same value: no callback")
slw.text = " 120 "; T.fire(T.COMMIT, slw)
ok(SL.get(sl) == 120 and T.ncalls("sl") == 2 and slw.barValue == 120, "slider typed 120 + Enter: 120, one callback")
slw.text = "999"; T.fire(T.COMMIT, slw)
ok(SL.get(sl) == 200 and slw.text == "200" and T.ncalls("sl") == 3, "slider typed 999: clamped to 200")
slw.text = "-5"; T.fire(T.COMMIT, slw)
ok(SL.get(sl) == 0 and T.ncalls("sl") == 4, "slider typed -5: clamped to 0")
slw.text = "abc"; T.fire(T.COMMIT, slw)
ok(SL.get(sl) == 0 and slw.text == "0" and T.ncalls("sl") == 4, "slider typed abc: the last value restored, no callback")
for _, bad in ipairs({ "1e3", "inf", "nan", "--1", "1.2.3", ".", "0x10" }) do
    slw.text = bad; T.fire(T.COMMIT, slw)
    ok(SL.get(sl) == 0 and T.ncalls("sl") == 4, "slider typed " .. bad .. ": restored, no callback")
end
slw.text = ""; T.fire(T.COMMIT, slw)
ok(SL.get(sl) == nil and slw.text == "" and slw.barValue == 50 and slw.hint == "DEFAULT (50)" and T.ncalls("sl") == 5 and T.last("sl").a == nil,
    "slider emptied: Default (nil), hint shown, bar at defaultValue, callback with nil")
slw.text = "  "; T.fire(T.COMMIT, slw)
ok(T.ncalls("sl") == 5, "slider committed empty again: no callback")
-- a click on a Default slider's handle that doesn't move it keeps Default
slw.barValue = 50; T.fire(T.END, slw)
ok(SL.get(sl) == nil and T.ncalls("sl") == 5 and slw.text == "", "slider at Default, drag end at the default: still Default, no callback")
-- setDefault moves a Default slider, leaves a custom one alone; set never calls back
SL.setDefault(sl, 80, "DEFAULT (80)")
ok(slw.barValue == 80 and slw.hint == "DEFAULT (80)" and T.ncalls("sl") == 5, "setDefault on a Default slider: moved to 80, new hint, no callback")
SL.set(sl, 33)
ok(SL.get(sl) == 33 and slw.text == "33" and T.ncalls("sl") == 5, "set(33): shown, no callback")
SL.setDefault(sl, 90)
ok(slw.barValue == 33 and slw.hint == "DEFAULT (80)" and T.ncalls("sl") == 5, "setDefault on a custom value: left alone; no hint argument keeps the hint")
SL.setDefault(sl, 90, nil)
ok(slw.hint == "" and slw.boxW == SL._BOX_W, "setDefault with an explicit nil hint: cleared, the box narrow again")
SL.set(sl, nil)
ok(SL.get(sl) == nil and slw.barValue == 90 and slw.text == "" and T.ncalls("sl") == 5, "set(nil): Default at 90, no callback")
-- step 0.5 and the comma
local sh = SL.create{ id = "sh", place = { row = T.row }, min = 0, max = 10, step = 0.5, onChange = T.rec("sh") }
local shw = T.tagged("sh")
ok(shw.range[4] == 1 and shw.text == "" and shw.barValue == 0, "slider 0..10 step 0.5: one decimal; no value: Default at min")
shw.text = "2.3"; T.fire(T.COMMIT, shw)
ok(SL.get(sh) == 2.5 and shw.text == "2.5" and T.ncalls("sh") == 1, "slider step 0.5: 2.3 becomes 2.5")
shw.text = "7,7"; T.fire(T.COMMIT, shw)
ok(SL.get(sh) == 7.5 and T.ncalls("sh") == 2, "slider: ',' as the decimal mark (7,7 -> 7.5)")
shw.barValue = 4.26; T.fire(T.END, shw)
ok(SL.get(sh) == 4.5 and T.ncalls("sh") == 3, "slider drag end at 4.26: snapped to 4.5")
-- off-grid values are snapped to min + k * step (create, set, setDefault): an unedited commit or a still click is no change
do
    local so = SL.create{ id = "so", place = { row = T.row }, min = 0, max = 10, step = 0.5, value = 2.3, defaultValue = 7.3, onChange = T.rec("so") }
    local sow = T.tagged("so")
    ok(SL.get(so) == 2.5 and sow.text == "2.5", "snap: value 2.3 on create is 2.5")
    sow.text = "2.5"; T.fire(T.COMMIT, sow)
    sow.barValue = 2.5; T.fire(T.END, sow)
    ok(T.ncalls("so") == 0, "snap: an unedited commit and a still click are no change")
    SL.set(so, 4.2)
    ok(SL.get(so) == 4 and T.ncalls("so") == 0, "snap: set(4.2) is 4.0, no callback")
    SL.set(so, nil)
    ok(sow.barValue == 7.5, "snap: defaultValue 7.3 on create is 7.5")
    sow.barValue = 7.5; T.fire(T.END, sow)
    ok(SL.get(so) == nil and T.ncalls("so") == 0, "snap: a still click on the snapped default keeps Default")
    SL.setDefault(so, 1.1)
    ok(sow.barValue == 1 and T.ncalls("so") == 0, "snap: setDefault(1.1) is 1.0")
    SL.remove(so)
end
-- pure helpers
ok(SL._snap(10.3, 0.3, 10, 1) == 9.3 and SL._snap(0.1, 0.3, 10, 1) == 0.3 and SL._snap(5.2, 0, 10, 0.1) == 5.2, "snap: min + k*step, never past max")
local st, v = SL._parse("12,5")
ok(st == "ok" and v == 12.5 and SL._parse("") == "empty" and SL._parse("x") == "bad" and SL._parse("+3") == "ok", "parse: comma, empty, bad, sign")
-- a throwing onChange
local stt = SL.create{ id = "stt", place = { list = T.list }, min = 0, max = 10, step = 1, onChange = function() error("bad slider") end }
local sttw = T.tagged("stt")
sttw.text = "3"; T.fire(T.COMMIT, sttw)
sttw.text = "4"; T.fire(T.COMMIT, sttw)
ok(SL.get(stt) == 4 and countLogs("WARN slider 'stt' onChange: ") == 1 and countLogs("bad slider") == 1, "slider: a throwing onChange is logged once and the slider keeps working")
-- disabled
local sd = SL.create{ id = "sd", place = { list = T.list }, min = 0, max = 10, step = 1, value = 5, enabled = false, onChange = T.rec("sd") }
local sdw = T.tagged("sd")
sdw.text = "9"; T.fire(T.COMMIT, sdw)
sdw.barValue = 2; T.fire(T.END, sdw)
ok(SL.get(sd) == 5 and T.ncalls("sd") == 0 and sdw.enabled == false and sdw.opacity == theme.disabledOpacity, "slider enabled = false: disabled, dimmed, input ignored")
-- another mod's slider
do
    local other = T.newSliderW()
    other:SetTag("nucleus:OtherMod:sl")
    other.text = "7"
    local s0 = SL._S.ignored
    T.fire(T.COMMIT, other)
    ok(SL.get(sl) == nil and SL._S.ignored == s0 + 1, "slider: another mod's widget ignored")
end

-- ---------------------------------------------------------------- reopen: values and enabled state re-applied
CK.set(cb, true)
SL.set(sl, 150)
CH.set(ch, 5)
SC.close(T.W)
T.W = SC.open{ id = "W" }
local cbw2, chw2, slw2, sdw2, chdw2 = T.tagged("cb"), T.tagged("ch"), T.tagged("sl"), T.tagged("sd"), T.tagged("chd")
ok(cbw2 and cbw2 ~= cbw and T.iconPath(cbw2) == T.TICKED, "reopen: checkbox ticked on its new widget")
ok(chw2 and chw2 ~= chw and chw2.value == "E" and chw2.arrows[1] == true, "reopen: choice shows option 5")
ok(slw2 and slw2 ~= slw and slw2.barValue == 150 and slw2.text == "150" and slw2.hint == "", "reopen: slider at 150")
ok(sdw2.enabled == false and sdw2.opacity == theme.disabledOpacity and chdw2.opacity == theme.disabledOpacity and T.tagged("cbd").opacity == theme.disabledOpacity, "reopen: disabled controls stay disabled")
T.fire(T.NEXT, chw2)
ok(CH.get(ch) == 6, "reopen: the new choice widget takes clicks")
T.fire(T.PREV, chw)
ok(CH.get(ch) == 6, "reopen: the old widget is ignored")

-- ---------------------------------------------------------------- tooltips
CH.setTooltip(ch, "PICK")
ok(chw2.Frame.tip == "PICK" and chw2.Background.vis == 0, "choice tooltip: on Frame, Background hit-testable")
CH.setTooltip(ch, nil)
ok(chw2.Frame.tip == "" and chw2.Background.vis == 4, "choice tooltip cleared")
SL.setTooltip(sl, "DRAG")
ok(slw2.Frame.tip == "DRAG", "slider tooltip: on Frame")
CK.setTooltip(cb, "TOGGLE")
ok(cbw2.Btn.tip == "TOGGLE", "checkbox tooltip: on Btn")

-- ---------------------------------------------------------------- bad input
T.nop = function() end
T.KC, T.HC, T.SC, T.RG = "nucleus.ui.checkbox.create: ", "nucleus.ui.choice.create: ", "nucleus.ui.slider.create: ", "nucleus.ui.choice.range: "
T.rp = { row = T.row }
function T.cbo(o) o.id = o.id or "b1"; o.place = o.place or T.rp; if o.onChange == nil then o.onChange = T.nop end; if o.onChange == false then o.onChange = nil end return function() CK.create(o) end end
function T.cho(o) o.id = o.id or "c1"; o.place = o.place or T.rp; if o.options == nil then o.options = T.OPTS end; if o.onChange == nil then o.onChange = T.nop end; if o.onChange == false then o.onChange = nil end return function() CH.create(o) end end
function T.sld(o) o.id = o.id or "s1"; o.place = o.place or T.rp; if o.onChange == nil then o.onChange = T.nop end; o.min = o.min or 0; o.max = o.max or 10; o.step = o.step or 1 return function() SL.create(o) end end
-- checkbox
T.bad(function() CK.create() end, T.KC .. "expected a table", "checkbox.create(nil)")
T.bad(function() CK.create({ id = "b1", onChange = T.nop }, 2) end, T.KC .. "expected 1 argument (a table), got 2", "checkbox.create two args")
T.bad(T.cbo({ label = "x" }), T.KC .. "unknown key 'label' (valid: checked, enabled, id, onChange, place, size, tooltip)", "checkbox unknown key")
T.bad(T.cbo({ onChange = false }), T.KC .. "onChange must be a function, got nil", "checkbox no onChange")
T.bad(T.cbo({ onChange = "f" }), T.KC .. "onChange must be a function, got 'f'", "checkbox onChange string")
T.bad(T.cbo({ size = 8 }), T.KC .. "size must be a number from 16 to 64, got 8", "checkbox size 8")
T.bad(T.cbo({ size = 65 }), T.KC .. "size must be a number from 16 to 64, got 65", "checkbox size 65")
T.bad(T.cbo({ size = 0 / 0 }), T.KC .. "size must be a number from 16 to 64, got NaN", "checkbox size NaN")
T.bad(T.cbo({ checked = 1 }), T.KC .. "checked must be a boolean or nil, got 1", "checkbox checked 1")
T.bad(T.cbo({ enabled = "no" }), T.KC .. "enabled must be a boolean or nil, got 'no'", "checkbox enabled string")
T.bad(T.cbo({ place = { host = "hud", corner = "top-left" } }), "nucleus.ui.checkbox.create: checkboxes need a host with a cursor (journal, menu, screen)", "checkbox on the HUD")
T.bad(T.cbo({ id = "ch" }), T.KC .. "id 'ch' is already a choice of this mod", "checkbox with a choice's id")
raises(function() CK.set(cb, 1) end, "nucleus.ui.checkbox.set: checked must be a boolean, got 1", "checkbox.set 1")
raises(function() CK.set(cb, true, 2) end, "nucleus.ui.checkbox.set: expected 2 arguments (handle, checked), got 3", "checkbox.set three args")
raises(function() CK.get(ch) end, "nucleus.ui.checkbox.get: not a checkbox handle ('ch' is a choice)", "checkbox.get(choice)")
raises(function() CK.get({ id = "cb" }) end, "nucleus.ui.checkbox.get: not a checkbox handle (use the handle that checkbox.create returned)", "checkbox.get forged")
raises(function() CK.setEnabled(cb, nil) end, "nucleus.ui.checkbox.setEnabled: enabled must be a boolean, got nil", "checkbox.setEnabled nil")
raises(function() CK.setVisible(cb, 1) end, "nucleus.ui.checkbox.setVisible: visible must be a boolean, got number", "checkbox.setVisible 1")
raises(function() CK.isShown(sl) end, "nucleus.ui.checkbox.isShown: not a checkbox handle ('sl' is a slider)", "checkbox.isShown(slider)")
raises(function() B.setLabel(cb, "x") end, "nucleus.ui.button.setLabel: not a button handle ('cb' is a checkbox)", "button.setLabel(checkbox)")
-- choice
T.bad(function() CH.create() end, T.HC .. "expected a table", "choice.create(nil)")
T.bad(T.cho({ values = 1 }), T.HC .. "unknown key 'values' (valid: enabled, id, onChange, options, place, selected, tooltip, widget)", "choice unknown key")
T.bad(T.cho({ options = {} }), T.HC .. "options is empty (1 to 64 strings)", "choice no options")
T.bad(T.cho({ options = "A" }), T.HC .. "options must be a list of 1 to 64 strings, got 'A'", "choice options string")
do
    local many = {}
    for k = 1, 65 do many[k] = "o" .. k end
    T.bad(T.cho({ options = many }), T.HC .. "options has 65 entries, at most 64", "choice 65 options")
end
T.bad(T.cho({ options = { "A", 2 } }), T.HC .. "options[2] must be a string of 1 to 64 bytes, got 2", "choice non-string option")
T.bad(T.cho({ options = { "A", "" } }), T.HC .. "options[2] must be a string of 1 to 64 bytes, got ''", "choice empty option")
T.bad(T.cho({ options = { string.rep("x", 65) } }), T.HC .. "options[1] must be a string of 1 to 64 bytes", "choice 65-byte option")
T.bad(T.cho({ options = { "A", x = "B" } }), T.HC .. "options must be a list (keys 1..n), got the key 'x'", "choice option with a key")
T.bad(T.cho({ options = { "A", [3] = "C" } }), T.HC .. "options must be a list (keys 1..n), it has a hole at 2", "choice options with a hole")
T.bad(T.cho({ selected = 7 }), T.HC .. "selected must be an integer from 1 to 6, got 7", "choice selected 7")
T.bad(T.cho({ selected = 0 }), T.HC .. "selected must be an integer from 1 to 6, got 0", "choice selected 0")
T.bad(T.cho({ selected = 1.5 }), T.HC .. "selected must be an integer from 1 to 6, got 1.5", "choice selected 1.5")
T.bad(T.cho({ onChange = false }), T.HC .. "onChange must be a function, got nil", "choice no onChange")
T.bad(T.cho({ widget = "game" }), T.HC .. "widget 'game' is not available yet", "choice widget game")
T.bad(T.cho({ widget = "fancy" }), T.HC .. "unknown widget 'fancy' (valid: core)", "choice widget fancy")
T.bad(T.cho({ place = { host = "hud", corner = "top-left" } }), "nucleus.ui.choice.create: choices need a host with a cursor (journal, menu, screen)", "choice on the HUD")
ok(pcall(CH.create, { id = "c2", options = T.OPTS, onChange = T.nop, place = T.rp, widget = "core" }), "choice widget = 'core' accepted")
CH.remove(C.els.c2.handle)
raises(function() CH.set(ch, 7) end, "nucleus.ui.choice.set: index must be an integer from 1 to 6, got 7", "choice.set 7")
raises(function() CH.set(ch, "2") end, "nucleus.ui.choice.set: index must be an integer from 1 to 6, got '2'", "choice.set '2'")
raises(function() CH.get(sl) end, "nucleus.ui.choice.get: not a choice handle ('sl' is a slider)", "choice.get(slider)")
raises(function() CH.get(ch, 1) end, "nucleus.ui.choice.get: expected 1 argument (handle), got 2", "choice.get two args")
-- range
raises(function() CH.range{ min = 0, max = 64, step = 1 } end, T.RG .. "the range has 65 options, at most 64", "range 65 options")
raises(function() CH.range{ min = 0, max = 63, step = 1, extra = { "Default" } } end, T.RG .. "the range has 65 options (1 extra), at most 64", "range 64 + 1 extra")
raises(function() CH.range{ min = 0, max = 10, step = 0 } end, T.RG .. "step must be greater than 0, got 0", "range step 0")
raises(function() CH.range{ min = 0, max = 10, step = -1 } end, T.RG .. "step must be greater than 0, got -1", "range step -1")
raises(function() CH.range{ min = 5, max = 1, step = 1 } end, T.RG .. "min (5) is greater than max (1)", "range min > max")
raises(function() CH.range{ min = 0, max = 1 / 0, step = 1 } end, T.RG .. "max must be a finite number, got inf", "range max inf")
raises(function() CH.range{ min = 0, max = 1e300, step = 1e-300 } end, T.RG .. "the range has ", "range huge count")
raises(function() CH.range{ min = 0, max = 2, step = 1, extra = { 5 } } end, T.RG .. "extra[1] must be a string of 1 to 64 bytes, got 5", "range non-string extra")
raises(function() CH.range{ min = 0, max = 2, step = 1, extra = "Default" } end, T.RG .. "extra must be a list of strings or nil, got 'Default'", "range extra string")
raises(function() CH.range{ min = 0, max = 2, step = 1, size = 1 } end, T.RG .. "unknown key 'size' (valid: extra, id, max, min, step)", "range unknown key")
raises(function() CH.range{ id = "a b", min = 0, max = 2, step = 1 } end, "nucleus.ui.choice.range: id 'a b' has characters outside", "range bad id")
raises(function() CH.range(5) end, T.RG .. "expected a table", "range not a table")
-- slider
T.bad(function() SL.create() end, T.SC .. "expected a table", "slider.create(nil)")
T.bad(T.sld({ width = 3 }), T.SC .. "unknown key 'width' (valid: defaultValue, enabled, hint, id, max, min, onChange, place, step, tooltip, value)", "slider unknown key")
T.bad(T.sld({ min = 5, max = 5 }), T.SC .. "min (5) must be less than max (5)", "slider min == max")
T.bad(T.sld({ min = 6, max = 5 }), T.SC .. "min (6) must be less than max (5)", "slider min > max")
T.bad(T.sld({ step = -1 }), T.SC .. "step must be greater than 0, got -1", "slider step -1")
T.bad(T.sld({ step = 1 / 0 }), T.SC .. "step must be a finite number, got inf", "slider step inf")
T.bad(T.sld({ max = 10001, step = 1 }), T.SC .. "min..max in steps of 1 is 10001 steps, at most 10000", "slider 10001 steps")
ok(pcall(SL.create, { id = "s10k", place = T.rp, min = 0, max = 10000, step = 1, onChange = T.nop }), "slider: 10,000 steps allowed")
SL.remove(C.els.s10k.handle)
T.bad(T.sld({ value = 11 }), T.SC .. "value 11 is outside 0..10", "slider value outside")
T.bad(T.sld({ value = 0 / 0 }), T.SC .. "value must be a finite number or nil, got NaN", "slider value NaN")
T.bad(T.sld({ defaultValue = -1 }), T.SC .. "defaultValue -1 is outside 0..10", "slider default outside")
T.bad(T.sld({ defaultValue = 1 / 0 }), T.SC .. "defaultValue must be a finite number, got inf", "slider default inf")
T.bad(T.sld({ hint = string.rep("h", 65) }), T.SC .. "hint must be a string of at most 64 bytes or nil, got 65 bytes", "slider hint 65 bytes")
T.bad(T.sld({ hint = 5 }), T.SC .. "hint must be a string of at most 64 bytes or nil, got 5", "slider hint number")
T.bad(T.sld({ onChange = "f" }), T.SC .. "onChange must be a function, got 'f'", "slider onChange string")
T.bad(T.sld({ min = "0" }), T.SC .. "min must be a finite number, got '0'", "slider min string")
T.bad(T.sld({ place = { host = "hud", corner = "top-left" } }), "nucleus.ui.slider.create: sliders need a host with a cursor (journal, menu, screen)", "slider on the HUD")
raises(function() SL.set(sl, 201) end, "nucleus.ui.slider.set: value 201 is outside 0..200", "slider.set 201")
raises(function() SL.set(sl) end, "nucleus.ui.slider.set: expected 2 arguments (handle, value or nil), got 1", "slider.set no value")
raises(function() SL.set(sl, "5") end, "nucleus.ui.slider.set: value must be a finite number or nil, got '5'", "slider.set string")
raises(function() SL.setDefault(sl, nil) end, "nucleus.ui.slider.setDefault: defaultValue must be a finite number, got nil", "slider.setDefault nil")
raises(function() SL.setDefault(sl, 5, string.rep("h", 65)) end, "nucleus.ui.slider.setDefault: hint must be a string of at most 64 bytes", "slider.setDefault long hint")
raises(function() SL.setDefault(sl, 5, "x", 1) end, "nucleus.ui.slider.setDefault: expected 2 or 3 arguments (handle, defaultValue, hint), got 4", "slider.setDefault four args")
raises(function() SL.get(cb) end, "nucleus.ui.slider.get: not a slider handle ('cb' is a checkbox)", "slider.get(checkbox)")
raises(function() SL.setEnabled(sl, 0) end, "nucleus.ui.slider.setEnabled: enabled must be a boolean, got 0", "slider.setEnabled 0")
raises(function() SL.setTooltip(sl, "") end, "nucleus.ui.slider.setTooltip: tooltip must be a string of 1 to 512 bytes", "slider.setTooltip empty")
-- a panel holding a control can't move to the HUD
do
    local PNm = require("nucleus.ui.panel")
    local jp = PNm.create{ id = "jp", place = { host = "journal", corner = "bottom-left" } }
    CK.create{ id = "jcb", place = { panel = jp }, onChange = T.nop }
    raises(function() P.place(jp, { host = "hud", corner = "top-left" }) end, "panel 'jp' holds controls (checkboxes, choices or sliders), which need a host with a cursor", "a panel with a checkbox can't go to the HUD")
    PNm.remove(jp)
end
-- removed handles; off the game thread; before connect
CK.remove(cbd); CK.remove(cbd)
raises(function() CK.get(cbd) end, "nucleus.ui.checkbox: handle 'cbd' was removed", "checkbox removed")
CH.remove(chd)
raises(function() CH.set(chd, 1) end, "nucleus.ui.choice: handle 'chd' was removed", "choice removed")
SL.remove(sd)
raises(function() SL.get(sd) end, "nucleus.ui.slider: handle 'sd' was removed", "slider removed")
do
    local saved = _G.Nucleus_Deref
    _G.Nucleus_Deref = function() error("Nucleus_Deref refused: called off the game thread") end
    for _, d in ipairs({ { "checkbox.create", function() CK.create{ id = "o", onChange = T.nop } end }, { "checkbox.get", function() CK.get(cb) end },
        { "checkbox.set", function() CK.set(cb, true) end }, { "choice.create", function() CH.create{ id = "o" } end },
        { "choice.range", function() CH.range{ min = 0, max = 1, step = 1 } end }, { "choice.set", function() CH.set(ch, 1) end },
        { "slider.create", function() SL.create{ id = "o" } end }, { "slider.set", function() SL.set(sl, 1) end },
        { "slider.setDefault", function() SL.setDefault(sl, 1) end }, { "slider.get", function() SL.get(sl) end } }) do
        raises(d[2], "nucleus.ui." .. d[1] .. " called off the game thread", "off thread: " .. d[1])
    end
    _G.Nucleus_Deref = saved
    C.bound = false
    raises(function() SL.create{ id = "o" } end, "nucleus.ui: slider.create called before connect", "before connect: slider.create")
    raises(function() CH.range{ min = 0, max = 1, step = 1 } end, "nucleus.ui: choice.range called before connect", "before connect: choice.range")
    C.bound = true
end
ok(SL.get(sl) == 150 and CH.get(ch) == 6 and CK.get(cb) == true, "the controls survived the refused calls")

-- ---------------------------------------------------------------- the template missing: one WARN, the generated style stays
do
    A._reset()
    F.objects[T.TPATH] = nil
    SL.create{ id = "nt1", place = T.rp, min = 0, max = 1, step = 0.1, onChange = T.nop }
    SL.create{ id = "nt2", place = T.rp, min = 0, max = 1, step = 0.1, onChange = T.nop }
    ok(T.tagged("nt1").copied == nil and T.tagged("nt2").copied == nil and countLogs("WARN the game's Settings slider (") == 1, "template missing: generated style kept, one WARN")
    F.objects[T.TPATH] = T.TEMPLATE
end
-- inside a hook the template comes from the cache only; a miss is copied on the next tick
do
    A._reset()
    M._inHook = true
    SL.create{ id = "nt3", place = T.rp, min = 0, max = 1, step = 0.1, onChange = T.nop }
    M._inHook = nil
    local w3 = T.tagged("nt3")
    ok(w3 and w3.copied == nil, "template inside a hook: not loaded there")
    tick()
    ok(w3 and w3.copied == T.TEMPLATE, "template inside a hook: copied on the next tick")
end
-- a template collected after it was copied (a map change) is looked up again, with no WARN
do
    A._reset()
    SL.create{ id = "nt4", place = T.rp, min = 0, max = 1, step = 0.1, onChange = T.nop }
    ok(T.tagged("nt4").copied == T.TEMPLATE, "template stale: the first slider copies it")
    local w0 = countLogs("WARN the game's Settings slider (")
    kill(T.TEMPLATE)
    local fresh = obj({ __asset = "Slider" }, T.TPATH)
    SL.create{ id = "nt5", place = T.rp, min = 0, max = 1, step = 0.1, onChange = T.nop }
    ok(T.tagged("nt5").copied == fresh and countLogs("WARN the game's Settings slider (") == w0, "template stale: a stale handle is looked up again, no WARN")
    T.TEMPLATE = fresh
end

-- ---------------------------------------------------------------- same id: checkbox and slider update the same widget
do
    local h = CK.create{ id = "cbs", place = T.rp, onChange = T.rec("cbs") }
    local w = T.tagged("cbs")
    local h2 = CK.create{ id = "cbs", place = T.rp, checked = true, size = 40, enabled = false, onChange = T.rec("cbs2") }
    ok(h2 == h and T.tagged("cbs") == w and CK.get(h) == true and T.iconPath(w) == T.TICKED and w.icon[2] == 40, "checkbox: same id updates state and size on the same widget")
    ok(w.opacity == theme.disabledOpacity and w.enabled == false, "checkbox: same id applies enabled = false")
    CK.create{ id = "cbs", place = T.rp, checked = false, onChange = T.rec("cbs2") }
    T.fire(T.CLICK, w)
    ok(CK.get(h) == true and T.ncalls("cbs") == 0 and T.ncalls("cbs2") == 1, "checkbox: same id re-enables, and the new onChange hears the next click")
end
do
    local h = SL.create{ id = "sls", place = T.rp, min = 0, max = 10, step = 1, value = 5, onChange = T.rec("sls") }
    local w = T.tagged("sls")
    local h2 = SL.create{ id = "sls", place = T.rp, min = 0, max = 2, step = 0.5, value = 1.5, defaultValue = 1, hint = "DEFAULT (1)", onChange = T.rec("sls2") }
    ok(h2 == h and T.tagged("sls") == w and w.range[2] == 2 and w.range[3] == 0.5 and w.range[4] == 1, "slider: same id updates the range on the same widget")
    ok(SL.get(h) == 1.5 and w.barValue == 1.5 and w.text == "1.5" and w.hint == "DEFAULT (1)" and w.boxW == SL._BOX_HINT_W, "slider: same id updates the value and the hint")
    w.text = "0.5"; T.fire(T.COMMIT, w)
    ok(SL.get(h) == 0.5 and T.ncalls("sls") == 0 and T.ncalls("sls2") == 1, "slider: same id, the new onChange hears the next commit")
end

print(string.format("controls_test: %d passed, %d failed", pass, failN))
if failN > 0 then os.exit(1) end
