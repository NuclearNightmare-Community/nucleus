-- Unit tests for core story 31 (UI-13, core 0.13.0): the game's own screens as hosts (core.ui.game, the createServer
-- host), outside the game. The fake engine is controls_test.lua's (a live title-screen menu, core's widgets, the
-- textures), plus the game's CreateServer_C (root CanvasPanel_21) built new on every open. This checks core's own logic
-- for every row of the story's I/O matrix (the event state machine, late and never-opened watchers, forged tokens, a
-- throwing watcher, MAX_PATHS, elements following every open, the bad-input errors), not the engine; the in-game proof
-- is run.ps1 -Scenario createserver.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/game_test.lua  (here: MiKTeX's texlua)
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.13.0", floor = "0.1.0" } end
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

-- ---- before connect and off the game thread: the C.enter texts
C.bound = false
raises(function() G.watch(CSH, function() end) end, "nucleus.ui: game.watch called before connect", "before connect: watch")
raises(function() G.unwatch(1) end, "nucleus.ui: game.unwatch called before connect", "before connect: unwatch")
raises(function() G.isOpen(CSH) end, "nucleus.ui: game.isOpen called before connect", "before connect: isOpen")
C.bound = true
do
    local saved = Nucleus_Deref
    Nucleus_Deref = function() error("Nucleus_Deref refused: called off the game thread", 0) end
    raises(function() G.watch(CSH, function() end) end, "nucleus.ui.game.watch called off the game thread", "off thread: watch")
    raises(function() G.unwatch(1) end, "nucleus.ui.game.unwatch called off the game thread", "off thread: unwatch")
    raises(function() G.isOpen(CSH) end, "nucleus.ui.game.isOpen called off the game thread", "off thread: isOpen")
    Nucleus_Deref = saved
end

-- ---- bad input (the I/O matrix's error rows)
raises(function() G.watch("nope", function() end) end, GP .. "watch: unknown game screen 'nope' (valid: createServer)", "watch: unknown host")
raises(function() G.watch(1, function() end) end, GP .. "watch: unknown game screen 1 (valid: createServer)", "watch: a number host")
raises(function() G.watch(nil, function() end) end, GP .. "watch: unknown game screen nil (valid: createServer)", "watch: nil host")
raises(function() G.watch("CreateServer", function() end) end, GP .. "watch: unknown game screen 'CreateServer'", "watch: host names are case-sensitive")
raises(function() G.watch("menu", function() end) end, GP .. "watch: unknown game screen 'menu'", "watch: menu is not a game screen")
raises(function() G.isOpen("menu") end, GP .. "isOpen: unknown game screen 'menu' (valid: createServer)", "isOpen: menu")
raises(function() G.isOpen() end, GP .. "isOpen: unknown game screen nil", "isOpen: no host")
raises(function() G.isOpen(CSH, 1) end, GP .. "isOpen: expected 1 argument (host), got 2", "isOpen: two arguments")
raises(function() G.watch(CSH, 5) end, GP .. "watch: fn must be a function, got 5", "watch: fn 5")
raises(function() G.watch(CSH) end, GP .. "watch: fn must be a function, got nil", "watch: no fn")
raises(function() G.watch(CSH, function() end, 1) end, GP .. "watch: expected 2 arguments (host, fn), got 3", "watch: extra argument")
raises(function() G.unwatch(99999) end, GP .. "unwatch: unknown token 99999 (not one game.watch returned)", "unwatch: forged token")
raises(function() G.unwatch(M.watch(function() end)) end, "(not one game.watch returned)", "unwatch: a menu.watch token")
raises(function() G.unwatch(1.5) end, GP .. "unwatch: token must be an integer, got 1.5", "unwatch: 1.5")
raises(function() G.unwatch("1") end, GP .. "unwatch: token must be an integer, got '1'", "unwatch: a string")
raises(function() G.unwatch(nil) end, GP .. "unwatch: token must be an integer, got nil", "unwatch: nil")
raises(function() G.unwatch(1, 2) end, GP .. "unwatch: expected 1 argument (token), got 2", "unwatch: two arguments")
-- placement: near is refused like on menu/screen; elements("createServer") names nothing
raises(function() X.create{ id = "bad", place = { host = CSH, near = "crosshair" } } end, "nucleus.ui.place: near is not available on host 'createServer' (corner or absolute)", "place: near on createServer")
raises(function() X.create{ id = "bad", place = { host = CSH, corner = "top-left", region = "map" } } end, "region is not available on host 'createServer'", "place: region on createServer")
raises(function() X.create{ id = "bad", place = { host = "moon", corner = "top-left" } } end, "unknown host 'moon' (valid: createServer, hud, journal, menu, screen)", "place: unknown host names createServer")
ok(next(P.elements(CSH)) == nil, "elements('createServer'): no named elements")
ok(C.els.bad == nil, "the refused calls created nothing")

-- ---- nothing open yet: isOpen false; no hook on the screen's class, ever
ok(G.isOpen(CSH) == false, "isOpen: false with no screen")
local w1 = G.watch(CSH, T.watcher("A"))
ok(math.type(w1) == "integer", "watch: an integer token")
-- a menu.watch token never names a game watcher, even once game tokens exist (they come from their own range)
do
    local mt
    for _ = 1, 3 do mt = M.watch(function() end) end
    raises(function() G.unwatch(mt) end, "(not one game.watch returned)", "unwatch: a menu.watch token after a game.watch")
    ok(w1 > 1 << 20 and w1 ~= mt, "game tokens: their own range", w1)
end
-- elements on the host before any open: a text and a checkbox (story 26's control), in a corner
local tx = X.create{ id = "cst", text = "SKEL CS", place = { host = CSH, corner = "bottom-right" } }
T.log = {}
local cb = CK.create{ id = "csc", place = { host = CSH, corner = "bottom-right" }, onChange = function(h, v) T.log[#T.log + 1] = { h = h, v = v } end }
ok(X.isShown(tx) == false and CK.isShown(cb) == false, "elements: not shown while no screen is open")
tick(); tick()
ok(T.evs("A") == "", "no screen: no event", T.evs("A"))

-- ---- open: opened with the path and the screen; the elements in its canvas
local s1 = T.open(1)
ok(G.isOpen(CSH) == true, "isOpen: true once a screen is in the viewport (before the tick)")
tick()
ok(T.evs("A") == "opened" and T.ev.A[1].path == s1.__path and T.ev.A[1].host == CSH and rawequal(T.ev.A[1].screen, s1), "open: opened with the path, host and screen", T.evs("A"))
ok(type(T.ev.A[1].reason) == "string", "open: a reason")
local t1, c1 = T.inCanvas(s1, "cst"), T.inCanvas(s1, "csc")
ok(t1 ~= nil and c1 ~= nil, "open: the text and the checkbox are in the screen's CanvasPanel_21")
ok(X.isShown(tx) == true and CK.isShown(cb) == true, "open: isShown true")
ok(t1 and t1.Slot.anchors.Minimum.X == 1 and t1.Slot.anchors.Minimum.Y == 1, "open: the text sits in the bottom-right corner")
ok(t1 and t1.font ~= nil, "open: the game look (a game font) by default")
ok(hookCount("CreateServer") == 0, "no hook is ever registered on CreateServer_C")
tick(); tick()
ok(T.evs("A") == "opened", "open: no repeat event on later ticks", T.evs("A"))
ok(#s1.canvas.children == 2, "open: later ticks add no widget", #s1.canvas.children)

-- the checkbox works on the screen (its click hook is registered from the poll)
ok(hookCount(T.CLICK) >= 1, "checkbox: the button click hook is registered from the poll")
T.fire(T.CLICK, c1)
ok(CK.get(cb) == true and #T.log == 1 and T.log[1].v == true and T.log[1].h == cb, "checkbox click on the screen: onChange(h, true) once")

-- ---- a late watcher: a synthetic opened next tick, to it only
local w2 = G.watch(CSH, T.watcher("B"))
ok(T.evs("B") == "", "late watcher: nothing at once")
tick()
ok(T.evs("B") == "opened" and rawequal(T.ev.B[1].screen, s1) and T.ev.B[1].reason:find("late watcher", 1, true) ~= nil, "late watcher: a synthetic opened next tick", T.evs("B"))
ok(T.evs("A") == "opened", "late watcher: the first watcher hears nothing new", T.evs("A"))

-- ---- Back: closed (the screen still exists); the elements' handles are freed
s1:RemoveFromParent()
ok(G.isOpen(CSH) == false, "isOpen: false after Back")
tick()
ok(T.evs("A") == "opened,closed" and T.ev.A[2].path == s1.__path and T.ev.A[2].screen == nil, "Back: closed, no screen", T.evs("A"))
ok(T.evs("B") == "opened,closed", "Back: the late watcher hears closed too", T.evs("B"))
ok(X.isShown(tx) == false and CK.isShown(cb) == false and C.els.cst.ref == nil and C.els.csc.ref == nil, "Back: handles freed, isShown false")
tick()
ok(T.evs("A") == "opened,closed", "Back: one closed only")

-- ---- ten opens: ten opened, ten closed, ten distinct paths, a new widget every open, no lost
do
    local paths, widgets, okNew = {}, {}, true
    for i = 2, 11 do
        local s = T.open(i)
        tick()
        local w = T.inCanvas(s, "cst")
        if not w or widgets[w] or w == t1 then okNew = false end
        if w then widgets[w] = true end
        paths[T.lastEv("A").path] = true
        s:RemoveFromParent()
        tick()
    end
    local n = 0
    for _ in pairs(paths) do n = n + 1 end
    local o, c, l = 0, 0, 0
    for _, e in ipairs(T.ev.A) do if e.event == "opened" then o = o + 1 elseif e.event == "closed" then c = c + 1 else l = l + 1 end end
    ok(o == 11 and c == 11 and l == 0, "ten more opens: opened 11, closed 11, lost 0", string.format("%d/%d/%d", o, c, l))
    ok(n == 10 and okNew, "ten more opens: ten distinct paths, a new text widget each time", n)
end
ok(#G._ST.createServer.paths <= G._MAX_PATHS, "MAX_PATHS: at most 8 screens tracked", #G._ST.createServer.paths)

-- ---- a screen replaced by a newer one: lost now, opened next tick (one event per tick)
local s20 = T.open(20)
tick()
ok(T.lastEv("A").event == "opened" and T.lastEv("A").path == s20.__path, "replace: s20 opened")
local nA = #T.ev.A
local s21 = T.open(21)
tick()
ok(#T.ev.A == nA + 1 and T.lastEv("A").event == "lost" and T.lastEv("A").path == s20.__path and T.lastEv("A").reason:find("replaced", 1, true) ~= nil,
    "replace: lost for the old one, one event this tick", T.evs("A"))
tick()
ok(#T.ev.A == nA + 2 and T.lastEv("A").event == "opened" and T.lastEv("A").path == s21.__path and T.inCanvas(s21, "cst") ~= nil,
    "replace: opened for the newer one next tick, its elements attached")

-- ---- lost: the object is gone (a map change destroyed it)
s20:RemoveFromParent() -- (the replaced one left the viewport too)
kill(s21)
tick()
ok(T.lastEv("A").event == "lost" and T.lastEv("A").path == s21.__path and T.lastEv("A").reason:find("gone", 1, true) ~= nil, "map change: lost when the object is gone")
ok(C.els.cst.ref == nil, "map change: the handles freed")
local nA1 = #T.ev.A
tick()
ok(#T.ev.A == nA1, "map change: nothing after lost")
tick()

-- ---- a watcher that never heard opened hears no closed / lost
local s30 = T.open(30)
tick()
local w3 = G.watch(CSH, T.watcher("C"))
s30:RemoveFromParent() -- closes before the tick that would give the late watcher its opened
tick()
ok(T.evs("C") == "" and T.lastEv("A").event == "closed", "never-opened watcher: no closed (the others hear it)", T.evs("C"))

-- ---- a throwing watcher: the others still run; one WARN
local w4 = G.watch(CSH, function() error("boom") end)
local nB = #T.ev.B
local s31 = T.open(31)
tick()
s31:RemoveFromParent()
tick()
ok(#T.ev.B == nB + 2, "throwing watcher: the other watchers still hear opened and closed")
ok(countLogs("WARN game watcher " .. w4 .. " (createServer): ") == 1 and countLogs("boom") == 1, "throwing watcher: one WARN for two failures")

-- ---- unwatch: the dependent's token removed; again is nothing
G.unwatch(w2)
local nB2 = #T.ev.B
local s32 = T.open(32)
tick()
ok(#T.ev.B == nB2, "unwatch: the watcher hears nothing more")
ok(pcall(G.unwatch, w2), "unwatch: the same token again is nothing")
G.unwatch(w3); G.unwatch(w4)
s32:RemoveFromParent()
tick()
-- a remote player's screen is not ours
local REMOTE = obj({ IsLocalController = function() return false end })
local nA2 = #T.ev.A
local s33 = T.open(33, { owner = REMOTE })
tick()
ok(#T.ev.A == nA2 and G.isOpen(CSH) == false, "remote owner: no opened, isOpen false")
s33:RemoveFromParent()
-- a screen whose root isn't a CanvasPanel: opened still, the elements stay pending, one WARN
local s34 = T.open(34, { rootClass = "Overlay" })
tick()
ok(T.lastEv("A").event == "opened" and T.lastEv("A").path == s34.__path, "root not a canvas: opened still")
ok(X.isShown(tx) == false and countLogs("WARN the createServer screen's root is Overlay, not a CanvasPanel") == 1, "root not a canvas: elements pending, one WARN")
s34:RemoveFromParent()
tick()
-- an element made while a screen is open attaches at once (no duplicate on the next tick)
local s35 = T.open(35)
tick()
local tx2 = X.create{ id = "cst2", text = "LATE", place = { host = CSH, corner = "top-left" } }
ok(X.isShown(tx2) == true and T.inCanvas(s35, "cst2") ~= nil, "element made while open: attached at once")
tick(); tick()
ok(T.countIn(s35, "cst2") == 1, "element made while open: exactly one widget", T.countIn(s35, "cst2"))
-- MAX_PATHS: many screens created without a tick; the open one is never dropped
for i = 40, 52 do T.notify(T.newCS(i)) end
ok(#G._ST.createServer.paths == G._MAX_PATHS and G._ST.createServer.rec[s35.__path] ~= nil, "MAX_PATHS: 8 tracked, the open screen kept", #G._ST.createServer.paths)
-- the decide state machine on its own: one event per call
do
    local st = G._ST.createServer
    local saved = st.path
    st.path = nil
    local e = G._decide(CSH, s35, s35.__path)
    ok(e and e.event == "opened" and e.host == CSH, "decide: opened")
    ok(G._decide(CSH, s35, s35.__path) == nil, "decide: the same screen again: nothing")
    st.path = "/x/gone"
    e = G._decide(CSH, nil, nil)
    ok(e and e.event == "lost" and st.path == nil, "decide: an untracked path that left: lost")
    st.path = saved
end
-- the feature list names the module and the host
local FE = require("nucleus.features")
ok(FE.set(FE.declared())["ui.game"] and FE.set(FE.declared())["ui.game.createServer"], "features: ui.game and ui.game.createServer")

print(string.format("game_test: %d passed, %d failed", pass, failN))
if failN > 0 then os.exit(1) end
