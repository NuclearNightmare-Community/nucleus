-- Unit tests for core story 24 (core 0.8.0, Mod Manager CAP-2): text fitting (style.overflow), images and icons
-- (ui.image, icons on buttons, dimmed) and tooltips, outside the game. The fake engine is menu_test.lua's (a live
-- title-screen menu with a window over it), plus the inner widgets story 24 drives (a text's Text and Background, a
-- button's Btn, Box, Label, IconGap and its icon setters, WBP_NucleusImage) and the textures. This checks core's own
-- logic for every row of the story's I/O matrix, not the engine; the in-game proof is run.ps1 -Scenario menu.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/image_test.lua  (here: MiKTeX's texlua)
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.8.0", floor = "0.1.0" } end
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

-- ---------------------------------------------------------------- a live title-screen menu and a window
local mt = X.create{ id = "mt", text = "menu", place = { host = "menu", corner = "top-right" } }
local m1 = build(1)
tick(); tick()
ok(M.isOpen() and X.isShown(mt), "setup: the menu is open")
T.W = SC.open{ id = "W" }
T.list = LS.create{ id = "lst", place = { screen = T.W, absolute = { anchor = "center", x = 0, y = 0 } }, size = { 500, 400 } }
T.row = RS.create{ id = "row", place = { list = T.list } }

-- ---------------------------------------------------------------- the Mod Manager row: image | text fill 4 | text fill 1 | spacer | gear
T.long = string.rep("ModManagerLong", 5):sub(1, 64)
local box = IM.create{ id = "r.on", place = { row = T.row }, image = { icon = "checkbox-on" }, size = 28, tooltip = "ON" }
local name = X.create{ id = "r.name", text = T.long, place = { row = T.row, fill = 4 }, style = { overflow = "ellipsis" } }
local ver = X.create{ id = "r.ver", text = "1.0.0", place = { row = T.row, fill = 1 } }
local gap = IM.create{ id = "r.gap", place = { row = T.row }, size = 28 }
T.hits = 0
local gear = B.create{ id = "r.cfg", place = { row = T.row }, icon = { icon = "gear" }, iconSize = 28, dimmed = true,
    tooltip = { en = "CONFIGURE", de = "KONFIGURIEREN" }, onClick = function() T.hits = T.hits + 1 end }
T.boxW, T.nameW, T.verW, T.gapW, T.gearW = T.tagged("r.on"), T.tagged("r.name"), T.tagged("r.ver"), T.tagged("r.gap"), T.tagged("r.cfg")
ok(T.boxW and T.nameW and T.verW and T.gapW and T.gearW, "row: every cell has a widget")
local rowW = T.tagged("row")
ok(rowW and #rowW.HBox.children == 5 and rowW.HBox.children[1] == T.boxW and rowW.HBox.children[5] == T.gearW, "row: five cells in order")
ok(T.nameW.Slot.Size.SizeRule == 1 and T.nameW.Slot.Size.Value == 4 and T.verW.Slot.Size.Value == 1 and T.boxW.Slot.Size.SizeRule == 0, "row: fill 4 and 1 for the texts, Auto for the image")
ok(T.boxW.Slot.VerticalAlignment == 2 and T.gapW.Slot.VerticalAlignment == 2 and T.gearW.Slot.VerticalAlignment == 2, "row: the images and the icon-only button keep their size (centred across the row)")
ok(T.nameW.Slot.VerticalAlignment == 0 and T.verW.Slot.VerticalAlignment == 0, "row: texts keep the 0.7.0 slot (fill)")
-- core icon
ok(T.boxW.tex and T.boxW.tex.__asset == "T_CheckboxOn" and T.boxW.size[1] == 28 and T.boxW.size[2] == 28, "core icon: checkbox-on at 28x28 from core's pak")
ok(T.tintIs(T.boxW.tint, theme.imageTint), "core icon: white (the texture as it is)")
-- ellipsis
ok(T.nameW.Text.policy == 1 and T.nameW.Text.clip == 1, "ellipsis: overflow policy Ellipsis and ClipToBounds on the Text")
ok(T.verW.Text.calls == 0, "overflow off: no overflow or clipping call (the engine's defaults)")
-- spacer
ok(T.gapW.tex == nil and T.gapW.texCalls == nil and T.gapW.size[1] == 28 and T.gapW.tint and T.gapW.tint[4] == 0, "spacer: an empty 28x28 cell, nothing drawn")
-- icon-only button, dimmed, tooltip
ok(T.gearW.icon and T.gearW.icon[1].__asset == "T_Gear" and T.gearW.icon[2] == 28 and T.gearW.icon[3] == 28, "icon-only button: the gear at 28x28")
ok(T.gearW.Box.wo == 28 and T.gearW.Box.ho == 28 and T.gearW.Label.vis == 1 and T.gearW.IconGap.vis == 1, "icon-only button: its box exactly 28x28, no label, no gap")
ok(T.gearW.colors and T.gearW.colors[13] == 0 and T.gearW.colors[4] == 0, "icon-only button (game look): no face, no content padding")
local c = T.gearW.content
ok(c and T.near(c[1], T.DIM.r) and T.near(c[4], T.DIM.a) and T.near(c[5], T.DIM.r) and T.near(c[8], T.DIM.a), "dimmed: label and icon at the disabled colour, hover too")
ok(T.gearW.Btn.tip == "CONFIGURE" and T.gearW.tag == "nucleus:TestMod:r.cfg", "tooltip: on the inner Btn (en), CoreTag unchanged")
ok(T.boxW.Img.tip == "ON" and T.boxW.Img.vis == 0 and T.boxW.tag == "nucleus:TestMod:r.on", "tooltip on an image: Img Visible, CoreTag unchanged")
-- a dimmed gear still clicks
clock = clock + 300000
fireHook("WBP_NucleusButton_C:Nucleus_OnClicked", T.gearW)
ok(T.hits == 1, "dimmed: still clickable, onClick once")

-- ---------------------------------------------------------------- tooltips: language, text, clearing, tags
F.lang = "de"
B.setTooltip(gear, { en = "CONFIGURE", de = "KONFIGURIEREN" })
ok(T.gearW.Btn.tip == "KONFIGURIEREN", "tooltip: picked by the current language on apply")
F.lang = "en"
X.setTooltip(ver, "Version")
ok(T.verW.Text.tip == "Version" and T.verW.Text.vis == 0 and T.verW.Background.vis == 4, "text tooltip: on Text, Text Visible, Background SelfHitTestInvisible")
ok(T.verW.tip == "nucleus:TestMod:r.ver", "text tooltip: the root's ToolTipText is still the tag")
local n0 = T.calls()
X.setTooltip(ver, "Version")
ok(T.calls() == n0, "text tooltip: the same again makes no UObject call")
X.setTooltip(ver, nil)
ok(T.verW.Text.tip == "" and T.verW.Text.vis == 4 and T.verW.Background.vis == 3, "tooltip cleared: back to HitTestInvisible (no tag on hover)")
IM.setTooltip(box, nil)
ok(T.boxW.Img.tip == "" and T.boxW.Img.vis == 3, "image tooltip cleared: Img HitTestInvisible")
IM.setTooltip(box, "ON")
-- bad tooltips
local TT = "nucleus.ui.text.setTooltip: "
raises(function() X.setTooltip(ver, "") end, TT .. "tooltip must be a string of 1 to 512 bytes, got 0 bytes", "tooltip: empty")
raises(function() X.setTooltip(ver, string.rep("x", 513)) end, TT .. "tooltip must be a string of 1 to 512 bytes, got 513 bytes", "tooltip: 513 bytes")
raises(function() X.setTooltip(ver, { de = "x" }) end, TT .. "tooltip needs an en string (the fallback)", "tooltip: no en")
raises(function() X.setTooltip(ver, "a\1b") end, TT .. "tooltip has the control byte 0x01 at byte 2", "tooltip: a control byte")
raises(function() X.setTooltip(ver, 5) end, TT .. "tooltip must be a string or a table of strings by language", "tooltip: a number")
raises(function() X.setTooltip(ver, { en = "x", de = 5 }) end, TT .. "tooltip.de must be a string of 1 to 512 bytes, got 5", "tooltip: a number in the table")
raises(function() X.setTooltip(ver, { en = "x", zh1 = "y" }) end, TT .. "tooltip key 'zh1' is not a language tag", "tooltip: a bad tag")
do
    local many = { en = "x" }
    for i = 1, 16 do many["l" .. string.char(96 + i)] = "y" end
    raises(function() X.setTooltip(ver, many) end, TT .. "tooltip has 17 languages, at most 16", "tooltip: 17 languages")
end
ok(pcall(X.setTooltip, ver, "two\nlines"), "tooltip: a newline is allowed")
X.setTooltip(ver, nil)
raises(function() X.setTooltip(ver, "a", 3) end, TT .. "expected 2 arguments (handle, tooltip), got 3", "tooltip: three arguments")
raises(function() X.setTooltip({ id = "x" }, "a") end, "nucleus.ui.text.setTooltip: not an element handle", "tooltip: a forged handle")
raises(function() B.setTooltip(name, "a") end, "nucleus.ui.button.setTooltip: not a button handle ('r.name' is a text element)", "button.setTooltip: a text handle")
raises(function() IM.setTooltip(gear, "a") end, "nucleus.ui.image.setTooltip: not an image handle ('r.cfg' is a button)", "image.setTooltip: a button handle")

-- ---------------------------------------------------------------- tooltips need a cursor host
local hudText = X.create{ id = "ht", text = "hud" } -- the HUD (top-right)
local TH = "tooltip needs a host with a cursor (journal, menu, screen), got 'hud'"
raises(function() X.setTooltip(hudText, "x") end, "nucleus.ui.text: " .. TH, "tooltip on a HUD text raises")
ok(C.els.ht.tooltip == nil, "tooltip on a HUD text: element unchanged")
raises(function() IM.create{ id = "hi", image = { icon = "gear" }, tooltip = "x" } end, "nucleus.ui.image: " .. TH, "image with a tooltip on the HUD raises")
ok(C.els.hi == nil, "image with a tooltip on the HUD: nothing created")
local tipText = X.create{ id = "tt", text = "tip", place = { screen = T.W, corner = "top-left" } }
X.setTooltip(tipText, "x")
raises(function() P.place(tipText, { host = "hud", corner = "top-left" }) end, "nucleus.ui.text: " .. TH, "place of a tooltip text to the HUD raises")
ok(C.els.tt.place.window == "W", "place of a tooltip text to the HUD: element unchanged")
local PNm = require("nucleus.ui.panel")
local hp = PNm.create{ id = "hp", place = { host = "hud", corner = "bottom-left" } }
raises(function() P.place(tipText, { panel = hp }) end, "nucleus.ui.text: " .. TH, "a tooltip text joining a panel on the HUD raises")
raises(function() IM.create{ id = "hi2", place = { panel = hp }, tooltip = "x" } end, "nucleus.ui.image: " .. TH, "a new image with a tooltip in a panel on the HUD raises")
local jp = PNm.create{ id = "jp", place = { host = "journal", corner = "bottom-left" } }
X.create{ id = "jt", text = "j", place = { panel = jp } }
X.setTooltip(C.els.jt.handle, "x")
raises(function() P.place(jp, { host = "hud", corner = "top-left" }) end, "nucleus.ui.panel: " .. TH, "a panel holding a tooltip moving to the HUD raises")
local hudImg = IM.create{ id = "himg", image = { icon = "warning" }, size = { w = 20, h = 24 } }
ok(hudImg.id == "himg", "an image without a tooltip goes on the HUD")
PNm.remove(hp); PNm.remove(jp); X.remove(hudText); X.remove(tipText)

-- ---------------------------------------------------------------- overflow: same style no call, off again, other kinds raise
n0 = T.calls()
X.setStyle(name, { overflow = "ellipsis" })
ok(T.calls() == n0, "overflow: the same style again makes no UObject call")
X.setStyle(name, { overflow = "clip" })
ok(T.nameW.Text.policy == 0 and T.nameW.Text.clip == 1, "overflow clip: policy Clip, ClipToBounds")
X.setStyle(name, nil)
ok(T.nameW.Text.policy == 0 and T.nameW.Text.clip == 0, "overflow nil after clip: the engine's defaults again")
X.setStyle(name, { overflow = "ellipsis" })
raises(function() B.create{ id = "bo", label = "x", place = { row = T.row }, onClick = function() end, style = { overflow = "clip" } } end, "nucleus.ui.button: style key overflow is available on text only", "overflow on a button")
raises(function() PNm.create{ id = "po", place = { host = "journal", corner = "top-left" }, style = { overflow = "clip" } } end, "nucleus.ui.panel: style key overflow is available on text only", "overflow on a panel")
raises(function() LS.setStyle(T.list, { overflow = "clip" }) end, "nucleus.ui.list: style key overflow is available on text only", "overflow on a list")
raises(function() RS.setStyle(T.row, { overflow = "ellipsis" }) end, "nucleus.ui.row: style key overflow is available on text only", "overflow on a row")
raises(function() X.setStyle(name, { overflow = "fade" }) end, "nucleus.ui.text: unknown overflow 'fade' (valid: ellipsis, clip)", "overflow: unknown value")
raises(function() X.setStyle(name, { overflow = true }) end, "nucleus.ui.text: unknown overflow boolean (valid: ellipsis, clip)", "overflow: a boolean")
raises(function() X.setStyle(name, { bg = 1 }) end, "nucleus.ui.text: unknown style key 'bg' (valid: background, font, look, overflow, padding)", "style: the new unknown-key list")
-- a HUD corner text: no overflow call (the 0.7.0 look)
ok(X.resolveStyle(nil).overflow == nil, "overflow: none by default")

-- ---------------------------------------------------------------- sources and sizes
local IC = "nucleus.ui.image.create: "
local function img(o) o.id = o.id or "bad"; o.place = o.place or { row = T.row } return function() IM.create(o) end end
local GAMES = table.concat(theme.gameTextureNames, ", ")
raises(img({ image = { game = "/Game/Foo.Foo" } }), IC .. "game texture '/Game/Foo.Foo' is not allow-listed (valid: " .. GAMES .. ")", "source: a path not on the list")
raises(img({ image = { icon = "star" } }), IC .. "unknown icon 'star' (valid: checkbox-off, checkbox-on, gear, lock, restart, warning)", "source: an unknown icon")
raises(img({ image = { icon = "gear", game = T.GAME.ticked } }), IC .. "image must have exactly one key, icon or game (got icon and game)", "source: two keys")
raises(img({ image = {} }), IC .. "image must have exactly one key, icon or game (got none)", "source: no key")
raises(img({ image = "gear" }), IC .. "image must be { icon = <key> } or { game = <path> }, got 'gear'", "source: a string")
raises(img({ image = { path = "x" } }), IC .. "unknown key 'path' in image (valid: game, icon)", "source: an unknown key")
do
    local long = "/Game/" .. string.rep("a", 200) .. ".x"
    local okL, e = pcall(img({ image = { game = long } }))
    ok(not okL and e:find("'" .. long:sub(1, 64) .. "'...", 1, true) and not e:find(long:sub(1, 65), 1, true), "source: a long path is echoed only up to 64 characters", e)
end
raises(img({ size = 3 }), IC .. "size must be a number from 4 to 512, or { w, h } with each from 4 to 512 (got 3)", "size: 3")
raises(img({ size = { w = 600 } }), IC .. "size must be a number from 4 to 512, or { w, h } with each from 4 to 512 (w is 600)", "size: { w = 600 }")
raises(img({ size = "big" }), IC .. "size must be a number from 4 to 512, or { w, h } with each from 4 to 512 (got 'big')", "size: 'big'")
raises(img({ size = { 1 / 0, 4 } }), IC .. "size must be a number from 4 to 512", "size: { inf, 4 }")
raises(img({ size = { w = 0 / 0, h = 4 } }), "(w is NaN)", "size: NaN")
raises(img({ size = { x = 4 } }), IC .. "size must be a number from 4 to 512, or { w, h } with each from 4 to 512 (unknown key 'x'; valid: w, h)", "size: an unknown key")
raises(img({ style = { tint = { r = 2, g = 0, b = 0 } } }), IC .. "style.tint.r must be a number from 0 to 1, got 2", "style: tint out of range")
raises(img({ style = { background = "dim" } }), IC .. "unknown style key 'background' (valid: tint)", "style: an unknown key")
raises(img({ style = { tint = { 1, 1, 1 } } }), IC .. "unknown key 1 in style.tint (valid: r, g, b, a)", "style: a positional tint")
raises(img({ dimmed = "yes" }), IC .. "dimmed must be a boolean or nil, got 'yes'", "dimmed: a string")
raises(img({ colour = 1 }), IC .. "unknown key 'colour' (valid: dimmed, id, image, place, size, style, tooltip)", "create: an unknown key")
raises(function() IM.create("x") end, IC .. "expected a table", "create: not a table")
raises(function() IM.create({ id = "a" }, 2) end, IC .. "expected 1 argument (a table), got 2", "create: two arguments")
raises(img({ id = "r.name" }), IC .. "id 'r.name' is already a text element of this mod", "ids are shared with every kind")
ok(C.els.bad == nil, "bad sources and sizes: nothing created")
ok(IM.create{ id = "sz", place = { row = T.row }, size = { w = 4, h = 512 } }, "size: 4 and 512 are allowed")
IM.remove(C.els.sz.handle)
-- button icons
local BC = "nucleus.ui.button.create: "
local function btn(o) o.id = o.id or "bb"; o.place = o.place or { row = T.row }; o.onClick = o.onClick or function() end return function() B.create(o) end end
raises(btn({ icon = { icon = "star" } }), BC .. "unknown icon 'star'", "button: an unknown icon")
raises(btn({ icon = { game = "/Game/Foo.Foo" } }), BC .. "game texture '/Game/Foo.Foo' is not allow-listed", "button: a game path not on the list")
raises(btn({ icon = { icon = "gear" }, iconSize = 600 }), BC .. "iconSize must be a number from 4 to 512", "button: iconSize 600")
raises(btn({ iconSize = 28 }), BC .. "iconSize needs an icon", "button: iconSize without an icon")
raises(btn({ dimmed = 1 }), BC .. "dimmed must be a boolean or nil, got 1", "button: dimmed a number")
raises(btn({ tooltip = "" }), BC .. "tooltip must be a string of 1 to 512 bytes", "button: an empty tooltip")
raises(btn({ size = 28 }), BC .. "unknown key 'size' (valid: dimmed, enabled, icon, iconSize, id, label, onClick, place, style, tooltip)", "button: no size beyond iconSize")
ok(C.els.bb == nil, "bad button icons: nothing created")

-- ---------------------------------------------------------------- game textures, and a missing one
T.gameImgs = {}
for k, p in pairs(T.GAME) do
    IM.create{ id = "g." .. k, place = { list = T.list }, image = { game = p } }
    local w = T.tagged("g." .. k)
    ok(w and w.tex and w.tex.__path == p, "game texture " .. k .. ": loaded by path", w and w.tex and w.tex.__path)
    ok(w and w.Slot.HorizontalAlignment == 1, "image in a list: at the start, not stretched across (" .. k .. ")")
end
F.missing[T.GAME.settings] = true
F.missing[T.GAME.question] = true
A._reset()
IM.create{ id = "m.set", place = { list = T.list }, image = { game = T.GAME.settings }, size = 30 }
IM.create{ id = "m.set2", place = { list = T.list }, image = { game = T.GAME.settings } }
IM.create{ id = "m.q", place = { list = T.list }, image = { game = T.GAME.question }, size = 30 }
local ms, mq = T.tagged("m.set"), T.tagged("m.q")
ok(ms.tex and ms.tex.__asset == "T_Gear" and ms.size[1] == 30, "missing texture: core's gear instead, same size")
ok(mq.tex == nil and mq.size[1] == 30 and mq.tint[4] == 0, "missing texture without a core icon: nothing, same size")
ok(countLogs("WARN the game texture T_Settings (") == 1 and countLogs("show Nucleus's gear icon instead") == 1, "missing texture: one WARN per texture", countLogs("WARN the game texture T_Settings"))
ok(countLogs("WARN the game texture T_Question (") == 1, "missing texture: T_Question's own WARN")
F.missing[T.GAME.settings], F.missing[T.GAME.question] = nil, nil

-- ---------------------------------------------------------------- dimmed and set
local d1 = IM.create{ id = "d1", place = { list = T.list }, image = { icon = "lock" }, dimmed = true }
local dw = T.tagged("d1")
ok(T.tintIs(dw.tint, T.DIM), "dimmed image: drawn at the disabled colour", dw.tint and table.concat(dw.tint, ","))
IM.set(d1, { dimmed = false })
ok(T.tintIs(dw.tint, theme.imageTint), "set dimmed = false: the style's tint again")
n0 = T.calls()
IM.set(d1, { dimmed = false, image = { icon = "lock" } })
ok(T.calls() == n0, "set: unchanged values make no UObject call")
IM.set(d1, { image = { icon = "restart" } })
ok(dw.tex.__asset == "T_Restart", "set: a new source")
IM.set(d1, { image = false })
ok(dw.tex == nil and dw.clears == 1 and dw.tint[4] == 0, "set image = false: cleared, nothing drawn")
local ST = "nucleus.ui.image.set: "
raises(function() IM.set(d1, {}) end, ST .. "changes is empty (give image, dimmed or both)", "set: an empty table")
raises(function() IM.set(d1, { size = 3 }) end, ST .. "unknown key 'size' (valid: dimmed, image)", "set: an unknown key")
raises(function() IM.set(d1, { dimmed = "no" }) end, ST .. "dimmed must be a boolean, got 'no'", "set: dimmed a string")
raises(function() IM.set(d1, { image = { icon = "star" } }) end, ST .. "unknown icon 'star'", "set: a bad source")
raises(function() IM.set(d1, "x") end, ST .. "changes must be a table", "set: not a table")
raises(function() IM.set(d1, {}, 1) end, ST .. "expected 2 arguments (handle, changes), got 3", "set: three arguments")
raises(function() IM.set({ id = "d1" }, { dimmed = true }) end, ST .. "not an image handle (use the handle that image.create returned)", "set: a forged handle")
raises(function() IM.set(name, { dimmed = true }) end, ST .. "not an image handle ('r.name' is a text element)", "set: a text handle")
raises(function() IM.setVisible(d1, 1) end, "nucleus.ui.image.setVisible: visible must be a boolean, got number", "setVisible: a number")
IM.setVisible(d1, false)
ok(dw.vis == 1 and not IM.isShown(d1), "setVisible(false): collapsed, not shown")
IM.setVisible(d1, true)
ok(IM.isShown(d1), "setVisible(true): shown")
IM.remove(d1)
IM.remove(d1)
raises(function() IM.isShown(d1) end, "nucleus.ui.image: handle 'd1' was removed", "remove: the handle raises after")
-- a button with an icon and a label; then icon only; enabled = false
local both = B.create{ id = "both", label = "OPEN", place = { list = T.list }, icon = { icon = "restart" }, onClick = function() end }
local bw = T.tagged("both")
ok(bw.icon and bw.icon[2] == 24 and bw.IconGap.vis == 3 and bw.Label.vis == 3 and bw.Box.wo == nil, "icon and label: the icon (24) left of the label, the gap shown")
B.setLabel(both, "")
ok(bw.Box.wo == 24 and bw.Label.vis == 1 and bw.IconGap.vis == 1 and bw.colors[13] == 0, "label to '': icon only, box exactly 24x24")
ok(bw.Slot.HorizontalAlignment == 1, "label to '': the icon-only button keeps its size in the list")
B.setLabel(both, "OPEN")
ok(bw.Box.wo == nil and bw.Label.vis == 3 and bw.IconGap.vis == 3, "label back: icon and label again")
ok(bw.Slot.HorizontalAlignment == 0, "label back: the button fills its slot again (the 0.7.0 slot)")
B.setEnabled(both, false)
ok(bw.opacity == theme.disabledOpacity, "enabled = false: the whole button (its icon too) at the disabled opacity")
B.create{ id = "both", label = "OPEN", place = { list = T.list }, onClick = function() end }
ok(bw.icon == nil and bw.IconGap.vis == 1 and bw.Label.vis == 3, "re-create without an icon: the 0.7.0 button")
local plainBtn = B.create{ id = "plain", label = "X", place = { list = T.list }, onClick = function() end }
ok(T.tagged("plain").content == nil and T.tagged("plain").Btn.calls == 0 and T.tagged("plain").Slot.HorizontalAlignment == 0, "a 0.7.0 button: no icon, colour, tooltip or alignment change")

-- ---------------------------------------------------------------- a texture missed inside a hook: applied on the next tick
A._reset()
M._inHook = true
local g0 = F.getAssets
IM.create{ id = "hook", place = { list = T.list }, image = { icon = "warning" } }
B.create{ id = "hookb", place = { list = T.list }, icon = { icon = "lock" }, onClick = function() end }
M._inHook = nil
local hw, hb = T.tagged("hook"), T.tagged("hookb")
ok(F.getAssets == g0 and hw and hw.tex == nil and hw.tint[4] == 0 and hb.icon == nil, "inside a hook: no load, nothing drawn yet")
tick()
ok(hw.tex and hw.tex.__asset == "T_Warning" and hw.tint[4] == 1 and hb.icon and hb.icon[1].__asset == "T_Lock", "the next UI tick: applied")
ok(F.getAssets > g0, "the next UI tick: loaded outside the hook")
-- preload: a texture in use is loaded by the dependent's LoadMap post-hook
A._reset()
local g1 = F.getAssets
for _, f in ipairs(F.loadMap) do f() end
ok(F.getAssets > g1 and A._used["tex:warning"] and A._used["gtex:" .. T.GAME.reset], "LoadMap preload: the textures in use")
ok(not A._used["tex:" .. "nothere"], "LoadMap preload: only what is used")

-- ---------------------------------------------------------------- a new window open: everything re-attaches with the same look
SC.close(T.W)
T.W = SC.open{ id = "W" }
T.boxW, T.nameW, T.gearW = T.tagged("r.on"), T.tagged("r.name"), T.tagged("r.cfg")
ok(T.boxW.tex.__asset == "T_CheckboxOn" and T.boxW.Img.tip == "ON" and T.nameW.Text.policy == 1 and T.gearW.Btn.tip == "CONFIGURE"
    and T.gearW.Box.wo == 28 and T.gearW.content and T.near(T.gearW.content[1], T.DIM.r), "re-open: icons, ellipsis, tooltips, dimmed again")

-- ---------------------------------------------------------------- off the game thread and before connect
do
    local saved = _G.Nucleus_Deref
    _G.Nucleus_Deref = function() error("Nucleus_Deref refused: called off the game thread") end
    for _, d in ipairs({ { "image.create", function() IM.create{ id = "o" } end }, { "image.set", function() IM.set(box, { dimmed = true }) end },
        { "image.setVisible", function() IM.setVisible(box, true) end }, { "image.remove", function() IM.remove(box) end },
        { "image.isShown", function() IM.isShown(box) end }, { "image.setTooltip", function() IM.setTooltip(box, "x") end },
        { "text.setTooltip", function() X.setTooltip(ver, "x") end }, { "button.setTooltip", function() B.setTooltip(gear, "x") end } }) do
        raises(d[2], "nucleus.ui." .. d[1] .. " called off the game thread", "off thread: " .. d[1])
    end
    _G.Nucleus_Deref = saved
    C.bound = false
    raises(function() IM.create{ id = "o" } end, "nucleus.ui: image.create called before connect", "before connect: image.create")
    C.bound = true
end
ok(IM.isShown(box), "the image survived the refused calls")

print(string.format("image_test: %d passed, %d failed", pass, failN))
if failN > 0 then os.exit(1) end
