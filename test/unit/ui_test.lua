-- Unit tests for core's UI helpers (lua/pkg/ui/), outside the game: UE4SS globals and UMG widgets are stubbed with
-- plain Lua tables, so this checks the helpers' own logic (validation, the HUD state machine, layout math, attach,
-- re-attach, duplicates, orphans, no-op counters), not the engine. The in-game proof is run.ps1 -Scenario ui.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/ui_test.lua
-- (on this workspace's machine: MiKTeX's texlua.exe, which is Lua 5.3).
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

-- ---------------------------------------------------------------- module loading as Mods/Nucleus/Scripts/nucleus/*
package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.5.0", floor = "0.1.0" } end
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
local nextAddr = 0x1000
local objects = {}          -- path -> object
local function obj(o, path)
    nextAddr = nextAddr + 0x100
    o.__alive, o.__addr, o.__path = true, nextAddr, path or ("/Engine/Transient.Obj_" .. nextAddr)
    o.GetAddress = function(self) return self.__addr end
    o.GetFullName = function(self) return (self.__class or "Object") .. " " .. self.__path end
    o.IsValid = function(self) return self.__alive end
    objects[o.__path] = o
    return o
end
local function kill(o) o.__alive = false; objects[o.__path] = nil end

local function vec(x, y) return { X = x, Y = y } end
local function newSlot()
    local s = { anchors = { Minimum = vec(0, 0), Maximum = vec(0, 0) }, alignment = vec(0, 0), position = vec(0, 0), auto = false, size = vec(100, 30) }
    function s:SetAutoSize(v) self.auto = v end
    function s:GetAutoSize() return self.auto end
    function s:SetAnchors(a) self.anchors = { Minimum = vec(a.Minimum.X, a.Minimum.Y), Maximum = vec(a.Maximum.X, a.Maximum.Y) } end
    function s:SetAlignment(a) self.alignment = vec(a.X, a.Y) end
    function s:SetPosition(p) self.position = vec(p.X, p.Y) end
    function s:GetAnchors() return self.anchors end
    function s:GetAlignment() return self.alignment end
    function s:GetPosition() return self.position end
    function s:GetSize() return self.size end
    return s
end

local TEXT_SHORT = "WBP_NucleusText_C"
local CALLS = 0
PARENT_CALLS = 0
local function newText(owner)
    local w = { __class = TEXT_SHORT, text = "", bg = { 0, 0, 0, 0 }, pad = 0, vis = 0, tip = "" }
    obj(w, "/Engine/Transient.GameEngine_1:GameInstance_1." .. TEXT_SHORT .. "_" .. nextAddr)
    w.Text = { GetText = function() return { ToString = function() return w.text end } end }
    function w:SetText(t) CALLS = CALLS + 1; self.text = t end
    function w:SetBackground(r, g, b, a) self.bg = { r, g, b, a } end
    function w:SetBackgroundPadding(p) self.pad = p end
    function w:SetToolTipText(t) self.tip = t.s end
    w.ToolTipText = setmetatable({}, { __index = function(_, k) if k == "ToString" then return function() return w.tip end end end })
    function w:SetVisibility(v) self.vis = v end
    function w:GetVisibility() return self.vis end
    function w:RemoveFromParent()
        local p = self.parent
        if p then for i, c in ipairs(p.children) do if c == self then table.remove(p.children, i) break end end end
        self.parent = nil
    end
    function w:GetParent() PARENT_CALLS = PARENT_CALLS + 1; return self.parent end
    function w:ForceLayoutPrepass() end
    function w:GetDesiredSize()
        if self.vis == 1 then return vec(0, 0) end
        local lines = 1
        for _ in self.text:gmatch("\n") do lines = lines + 1 end
        return vec(10 * #self.text + 2 * self.pad, 20 * lines + 2 * self.pad)
    end
    function w:GetClass() return { GetFName = function() return { ToString = function() return TEXT_SHORT end } end } end
    function w:GetRenderOpacity() return 1 end -- story 12's walk
    function w:IsA() return false end
    return w
end

-- Story 14: box panels (VerticalBox / HorizontalBox) and the panel widget WBP_NucleusPanel_C.
local BOX_ADDS = 0
local function newBoxSlot()
    local s = { pad = { Left = 0, Top = 0, Right = 0, Bottom = 0 } }
    function s:SetPadding(m) self.pad = { Left = m.Left, Top = m.Top, Right = m.Right, Bottom = m.Bottom } end
    return s
end
local function newBox(path, horiz)
    local b = { children = {}, horiz = horiz }
    obj(b, path)
    function b:GetChildrenCount() return #self.children end
    function b:GetChildAt(i) return self.children[i + 1] end
    function b:AddChild(w) BOX_ADDS = BOX_ADDS + 1; w.parent = self; w.Slot = newBoxSlot(); table.insert(self.children, w); return w.Slot end
    return b
end
local PANEL_SHORT = "WBP_NucleusPanel_C"
local function newPanelW()
    local w = { __class = PANEL_SHORT, bg = { 0, 0, 0, 0 }, pad = 0, vis = 0, tag = "" }
    obj(w, "/Engine/Transient.GameEngine_1:GameInstance_1." .. PANEL_SHORT .. "_" .. nextAddr)
    w.VBox = newBox(w.__path .. ".WidgetTree.VBox", false)
    w.HBox = newBox(w.__path .. ".WidgetTree.HBox", true)
    function w:SetBackground(r, g, b, a) self.bg = { r, g, b, a } end
    function w:SetBackgroundPadding(p) self.pad = p end
    function w:SetTag(t) self.tag = t end
    w.CoreTag = setmetatable({}, { __index = function(_, k) if k == "ToString" then return function() return w.tag end end end })
    function w:SetVisibility(v) self.vis = v end
    function w:GetVisibility() return self.vis end
    function w:RemoveFromParent()
        local p = self.parent
        if p then for i, c in ipairs(p.children) do if c == self then table.remove(p.children, i) break end end end
        self.parent = nil
    end
    function w:GetParent() PARENT_CALLS = PARENT_CALLS + 1; return self.parent end
    function w:ForceLayoutPrepass() end
    function w:GetDesiredSize()
        if self.vis == 1 then return vec(0, 0) end
        local W, Hh = 0, 0
        for _, box in ipairs({ self.VBox, self.HBox }) do
            for _, c in ipairs(box.children) do
                if c.vis ~= 1 then
                    local d = c:GetDesiredSize()
                    if box.horiz then W = W + d.X + c.Slot.pad.Left; Hh = math.max(Hh, d.Y)
                    else Hh = Hh + d.Y + c.Slot.pad.Top; W = math.max(W, d.X) end
                end
            end
        end
        return vec(W + 2 * self.pad, Hh + 2 * self.pad)
    end
    function w:GetClass() return { GetFName = function() return { ToString = function() return PANEL_SHORT end } end } end
    function w:GetRenderOpacity() return 1 end
    function w:IsA() return false end
    return w
end

-- Story 15: the button widget WBP_NucleusButton_C (globals: the main chunk is at Lua's 200-locals limit).
BUTTON_SHORT = "WBP_NucleusButton_C"
function newButtonW()
    local w = { __class = BUTTON_SHORT, label = "", vis = 0, tag = "", enabled = true, opacity = 1, enabledCalls = 0, clicks = 0 }
    obj(w, "/Engine/Transient.GameEngine_1:GameInstance_1." .. BUTTON_SHORT .. "_" .. nextAddr)
    function w:SetLabel(t) self.label = t end
    function w:SetEnabledState(e) self.enabledCalls = self.enabledCalls + 1; self.enabled = e end
    function w:SetRenderOpacity(o) self.opacity = o end
    function w:SetColors(...) self.colors = { ... } end
    function w:SetTag(t) self.tag = t end
    w.CoreTag = setmetatable({}, { __index = function(_, k) if k == "ToString" then return function() return w.tag end end end })
    function w:SetVisibility(v) self.vis = v end
    function w:GetVisibility() return self.vis end
    function w:RemoveFromParent()
        local p = self.parent
        if p then for i, c in ipairs(p.children) do if c == self then table.remove(p.children, i) break end end end
        self.parent = nil
    end
    function w:GetParent() PARENT_CALLS = PARENT_CALLS + 1; return self.parent end
    function w:ForceLayoutPrepass() end
    function w:GetDesiredSize() if self.vis == 1 then return vec(0, 0) end return vec(10 * #self.label + 8, 28) end
    function w:GetClass() return { GetFName = function() return { ToString = function() return BUTTON_SHORT end } end } end
    function w:GetRenderOpacity() return self.opacity end
    function w:IsA() return false end
    return w
end
HOOKS = {}
function RegisterHook(path, fn) HOOKS[#HOOKS + 1] = { path = path, fn = fn } return #HOOKS, #HOOKS end

local function newCanvas(path)
    local c = { children = {} }
    obj(c, path)
    function c:GetChildrenCount() return #self.children end
    function c:GetChildAt(i) return self.children[i + 1] end
    function c:AddChildToCanvas(w) w.parent = self; w.Slot = newSlot(); table.insert(self.children, w); return w.Slot end
    return c
end

local PC = obj({ IsLocalController = function() return true end }, "/Game/Maps/SmallMap.SmallMap:PersistentLevel.PC_1")
local WORLD = obj({}, "/Game/Maps/SmallMap.SmallMap")
local HUDS = {}
local function newHud(n)
    local path = "/Engine/Transient.GameEngine_1:GameInstance_1.InventoryUI_C_" .. n
    local h = { __class = "InventoryUI_C", inViewport = true, vis = 4, HidingCrosshair = false }
    obj(h, path)
    h.OwningCanvas = newCanvas(path .. ".WidgetTree_1.OwningCanvas")
    local cross = { vis = 4 }
    obj(cross, path .. ".WidgetTree_1.Crosshair")
    cross.Slot = newSlot()
    cross.Slot.anchors = { Minimum = vec(0.5, 0.5), Maximum = vec(0.5, 0.5) }
    cross.Slot.position = vec(-5, -5)
    cross.Slot.size = vec(10, 10)
    function cross:GetVisibility() return self.vis end
    function cross:GetDesiredSize() return vec(10, 10) end
    h.Crosshair = cross
    function h:IsInViewport() return self.inViewport end
    function h:GetOwningPlayer() return PC end
    function h:GetWorld() return WORLD end
    function h:GetVisibility() return self.vis end
    HUDS[#HUDS + 1] = h
    return h
end

-- UE4SS globals
local notify = {}
function NotifyOnNewObject(cls, fn) notify[#notify + 1] = { cls = cls, fn = fn } end
local findAllCount = 0
local JOURNALS = {}
local TOPS = {} -- top-level UserWidgets for the overlap walk (story 17: FindAllOf("UserWidget") + IsInViewport only)
function FindAllOf(cls)
    if cls == "Journal_C" then
        local out = {}
        for _, j in ipairs(JOURNALS) do if j.__alive then out[#out + 1] = j end end
        return out
    end
    if cls == "UserWidget" then -- the overlap walk's roots, not a HUD seed: not counted
        local out = {}
        for _, x in ipairs(TOPS) do out[#out + 1] = x end
        return out
    end
    findAllCount = findAllCount + 1
    local out = {}
    for _, h in ipairs(HUDS) do if h.__alive then out[#out + 1] = h end end
    return out
end
local GS = obj({ GetPlayerController = function() return PC end }, "/Script/Engine.Default__GameplayStatics")
local PANELCLASS
local WBL = obj({ Create = function(_, world, cls, owner)
    if cls == PANELCLASS then return newPanelW() end
    if cls == BUTTONCLASS then return newButtonW() end
    return newText(owner)
end }, "/Script/UMG.Default__WidgetBlueprintLibrary")
local TEXTCLASS = obj({}, "/Game/Mods/Nucleus/WBP_NucleusText.WBP_NucleusText_C")
PANELCLASS = obj({}, "/Game/Mods/Nucleus/WBP_NucleusPanel.WBP_NucleusPanel_C")
BUTTONCLASS = obj({}, "/Game/Mods/Nucleus/WBP_NucleusButton.WBP_NucleusButton_C")
obj({ GetAsset = function(_, a) return objects[a.PackageName .. "." .. a.AssetName] or { IsValid = function() return false end } end }, "/Script/AssetRegistry.Default__AssetRegistryHelpers")
local INVALID = { IsValid = function() return false end }
function StaticFindObject(path) return objects[path] or INVALID end
function FName(s) return s end
function FText(s) return { s = s } end
local loops = {}
-- The poller must never use the async thread (hud.lua, top): LoopAsync and ExecuteInGameThread fail the test.
local asyncUsed = 0
function LoopAsync() asyncUsed = asyncUsed + 1 end
function ExecuteInGameThread() asyncUsed = asyncUsed + 1 end
function LoopInGameThreadWithDelay(ms, fn) loops[#loops + 1] = fn; return #loops end
local cancelled = 0
function CancelDelayedAction(h) if loops[h] then loops[h] = function() end; cancelled = cancelled + 1 end return true end
ModRef = {}
local offThread = false
function Nucleus_Deref(h)
    if offThread then error("Nucleus_Deref refused: called off the game thread", 0) end
    return nil
end

-- ---------------------------------------------------------------- the modules under test
local C = require("nucleus.ui.common")
C.valid = function(o) return type(o) == "table" and o.__alive == true end
local H = require("nucleus.ui.hud")
local J = require("nucleus.ui.journal")
local P = require("nucleus.ui.place")
local X = require("nucleus.ui.text")
local PN = require("nucleus.ui.panel")

local logs = {}
local function logger()
    local L = { debugEnabled = true }
    local function emit(level, fmt, ...) logs[#logs + 1] = level .. string.format(fmt, ...) end
    function L.info(f, ...) emit("", f, ...) end
    function L.warn(f, ...) emit("WARN ", f, ...) end
    function L.error(f, ...) emit("ERROR ", f, ...) end
    function L.debug(f, ...) if L.debugEnabled then emit("DEBUG ", f, ...) end end
    return L
end
local handles, nextHandle, freed = {}, 0, 0
local function ref(o) nextHandle = nextHandle + 1; handles[nextHandle] = o; return nextHandle end
local function deref(h) local o = handles[h] return (o and o.__alive) and o or nil end
local function free(h) if handles[h] then freed = freed + 1 end handles[h] = nil end
local clock = 0
local function micros() clock = clock + 7 return clock end

-- ---------------------------------------------------------------- tiny test runner
local pass, fail = 0, 0
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
end
local function raises(fn, text, name)
    local r, e = pcall(fn)
    ok(not r and tostring(e):find(text, 1, true) ~= nil, name, r and "no error" or e)
end
local function countLogs(pat) local n = 0 for _, l in ipairs(logs) do if l:find(pat) then n = n + 1 end end return n end
local function tick() for _, f in ipairs(loops) do f() end end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- ---------------------------------------------------------------- before connect
raises(function() X.create{ id = "a" } end, "nucleus.ui: text.create called before connect", "before connect: create")
raises(function() H.watch(function() end) end, "nucleus.ui: hud.watch called before connect", "before connect: watch")
raises(function() P.elements() end, "nucleus.ui: elements called before connect", "before connect: elements")
raises(function() J.watch(function() end) end, "nucleus.ui: journal.watch called before connect", "before connect: journal.watch")
raises(function() J.isOpen() end, "nucleus.ui: journal.isOpen called before connect", "before connect: journal.isOpen")
raises(function() PN.create{ id = "p" } end, "nucleus.ui: panel.create called before connect", "before connect: panel.create")
raises(function() PN.move({}, {}, 1) end, "nucleus.ui: panel.move called before connect", "before connect: panel.move")
raises(function() require("nucleus.ui.button").create{ id = "b" } end, "nucleus.ui: button.create called before connect", "before connect: button.create")

C.bind{ mod = "TestMod", log = logger(), ref = ref, deref = deref, free = free, micros = micros }

-- ---------------------------------------------------------------- off the game thread
offThread = true
raises(function() X.create{ id = "a" } end, "nucleus.ui.text.create called off the game thread", "off thread: create")
raises(function() H.find() end, "nucleus.ui.hud.find called off the game thread", "off thread: find")
raises(function() P.place({}, {}) end, "nucleus.ui.place called off the game thread", "off thread: place")
raises(function() J.watch(function() end) end, "nucleus.ui.journal.watch called off the game thread", "off thread: journal.watch")
raises(function() J.unwatch(1) end, "nucleus.ui.journal.unwatch called off the game thread", "off thread: journal.unwatch")
raises(function() J.isOpen() end, "nucleus.ui.journal.isOpen called off the game thread", "off thread: journal.isOpen")
raises(function() J.find() end, "nucleus.ui.journal.find called off the game thread", "off thread: journal.find")
raises(function() PN.create{ id = "p" } end, "nucleus.ui.panel.create called off the game thread", "off thread: panel.create")
raises(function() PN.setOrder({}, {}) end, "nucleus.ui.panel.setOrder called off the game thread", "off thread: panel.setOrder")
raises(function() PN.move({}, {}, 1) end, "nucleus.ui.panel.move called off the game thread", "off thread: panel.move")
raises(function() PN.order({}) end, "nucleus.ui.panel.order called off the game thread", "off thread: panel.order")
for _, fn in ipairs({ "create", "setLabel", "setEnabled", "setVisible", "remove", "isShown" }) do
    raises(function() require("nucleus.ui.button")[fn]({}, true) end, "nucleus.ui.button." .. fn .. " called off the game thread", "off thread: button." .. fn)
end
offThread = false

-- ---------------------------------------------------------------- validation (pure)
local v = P.validate({ corner = "top-right" })
ok(v.host == "hud" and v.corner == "top-right" and v.gapUnits == 16 and v.offset.x == 0 and v.offset.y == 0, "validate: corner defaults")
v = P.validate({ near = "crosshair" })
ok(v.side == "right" and v.align == "center" and v.gapUnits == 16, "validate: near defaults")
v = P.validate({ absolute = {} })
ok(v.absolute.anchor == "top-left" and v.absolute.x == 0 and v.absolute.y == 0, "validate: absolute defaults")
ok(P.validate({ corner = "top-left", gap = "tight" }).gapUnits == 8 and P.validate({ corner = "top-left", gap = "loose" }).gapUnits == 32, "validate: gaps 8/32")
local PL = "nucleus.ui.place: "
local bad = {
    { "x", "intent must be a table, got 'x'" },
    { {}, "an intent needs exactly one of corner, near or absolute (got none)" },
    { { corner = "top-right", absolute = {} }, "an intent needs exactly one of corner, near or absolute (got corner and absolute)" },
    { { conrer = "top-right" }, "unknown key 'conrer' in an intent" },
    { { corner = "middle" }, "unknown corner 'middle' (valid: top-left, top-right, bottom-left, bottom-right)" },
    { { corner = "top-left", gap = 16 }, "unknown gap 16" },
    { { corner = "top-left", side = "left" }, "side is not allowed with corner" },
    { { absolute = {}, offset = { x = 1 } }, "offset is not allowed with absolute" },
    { { absolute = {}, gap = "tight" }, "gap is not allowed with absolute" },
    { { corner = "top-left", offset = { x = "a" } }, "offset.x must be a number, got 'a'" },
    { { corner = "top-left", offset = { x = math.huge } }, "offset.x must be a finite number" },
    { { corner = "top-left", offset = { x = 0 / 0 } }, "offset.x must be a finite number, got NaN" },
    { { corner = "top-left", offset = { x = 5000 } }, "offset.x 5000 is out of range (within +-4096 canvas units)" },
    { { corner = "top-left", offset = { z = 1 } }, "unknown key 'z' in offset" },
    { { absolute = { anchor = "middle" } }, "unknown anchor 'middle'" },
    { { absolute = { x = 9000 } }, "absolute.x 9000 is out of range (within +-8192 canvas units)" },
    { { absolute = "center" }, "absolute must be a table" },
    { { near = "mic" }, "unknown near element 'mic' (valid: crosshair)" },
    { { near = "crosshair", side = "up" }, "unknown side 'up'" },
    { { near = "crosshair", align = "middle" }, "unknown align 'middle'" },
    { { host = "Journal", corner = "top-left" }, "unknown host 'Journal' (valid: hud, journal)" },
    { { host = 5, corner = "top-left" }, "unknown host 5 (valid: hud, journal)" },
    { { host = "journal", near = "crosshair" }, "near is not available on host 'journal' (it has no named elements yet; use corner or absolute)" },
}
for i, b in ipairs(bad) do raises(function() P.validate(b[1]) end, PL .. b[2], "validate bad " .. i) end
ok(pcall(P.validate, { corner = "top-left", offset = { x = 4096, y = -4096 } }), "validate: offset at the bound")

local s = X.resolveStyle(nil)
ok(s.a == 0 and s.pad == 0, "style: default is no box, no padding")
s = X.resolveStyle({ background = "dim" })
ok(near(s.a, 0.35) and s.pad == 8, "style: dim gets normal padding by default")
s = X.resolveStyle({ background = "dark", padding = "loose" })
ok(near(s.a, 0.7) and s.pad == 12, "style: dark/loose")
s = X.resolveStyle({ background = { r = 0.2, g = 0.4, b = 1 } })
ok(s.r == 0.2 and s.b == 1 and s.a == 1 and s.pad == 8, "style: explicit colour, a defaults to 1")
s = X.resolveStyle({ padding = "tight" })
ok(s.a == 0 and s.pad == 4, "style: padding without background")
raises(function() X.resolveStyle("dim") end, "nucleus.ui.text: style must be a table", "style: string")
raises(function() X.resolveStyle({ background = "purple" }) end, "nucleus.ui.text: unknown background 'purple' (valid: none, dim, dark", "style: purple")
raises(function() X.resolveStyle({ background = { r = -1, g = 0, b = 0 } }) end, "background.r must be a number from 0 to 1, got -1", "style: -1")
raises(function() X.resolveStyle({ background = { r = 2, g = 0, b = 0 } }) end, "background.r must be a number from 0 to 1, got 2", "style: 2")
raises(function() X.resolveStyle({ background = { r = "x", g = 0, b = 0 } }) end, "got 'x'", "style: 'x'")
raises(function() X.resolveStyle({ padding = 5 }) end, "unknown padding 5 (valid: none, tight, normal, loose)", "style: padding 5")
raises(function() X.resolveStyle({ bg = "dim" }) end, "unknown style key 'bg' (valid: background, padding)", "style: bg")

raises(function() X._validId("", "text.create") end, "id must not be empty", "id: empty")
raises(function() X._validId(string.rep("a", 65), "text.create") end, "id is 65 characters, at most 64", "id: 65")
raises(function() X._validId("a b", "text.create") end, "has characters outside", "id: space")
ok(X._validId(string.rep("a", 64), "x") and X._validId("clock.time-1_A", "x"), "id: 64 chars and punctuation ok")
local t, long = X._validText(string.rep("a", 300), "text.set")
ok(#t == 256 and long, "text: cut at 256")
t, long = X._validText(string.rep("\195\169", 300), "text.set")
ok(utf8.len(t) == 256 and long, "text: cut at 256 characters, not bytes")
t = X._validText(12.5, "text.set")
ok(t == "12.5", "text: numbers")
ok(X._validText(nil, "x") == "", "text: nil is empty")
raises(function() X._validText({}, "text.set") end, "nucleus.ui.text.set: text must be a string, a number or nil, got table", "text: table")

-- ---------------------------------------------------------------- layout math
local st = P.stack("top-right", {
    { gap = 16, height = 20, offset = { x = 0, y = 0 } },
    { gap = 16, height = 40, offset = { x = -40, y = 0 } },
    { gap = 8, height = 20, offset = { x = 0, y = 0 } },
})
ok(st[1].x == -16 and st[1].y == 16 and st[1].ax == 1 and st[1].ay == 0 and st[1].alx == 1 and st[1].aly == 0, "stack: first top-right")
ok(st[2].x == -56 and st[2].y == 52, "stack: second, offset moves only it")
ok(st[3].x == -8 and st[3].y == 100, "stack: third below the second, its own gap")
st = P.stack("bottom-left", { { gap = 32, height = 20, offset = { x = 0, y = 0 } }, { gap = 32, height = 20, offset = { x = 0, y = 0 } } })
ok(st[1].x == 32 and st[1].y == -32 and st[2].y == -84 and st[1].ay == 1 and st[1].aly == 1, "stack: bottom-left goes up")
local n = P.near({ l = -5, t = -5, r = 5, b = 5 }, "right", "center", 16, { x = 0, y = 0 })
ok(n.x == 21 and n.y == 0 and n.alx == 0 and n.aly == 0.5, "near: right/center")
n = P.near({ l = -5, t = -5, r = 5, b = 5 }, "above", "start", 8, { x = 1, y = 2 })
ok(n.x == -4 and n.y == -11 and n.alx == 0 and n.aly == 1, "near: above/start with offset")
local a = P.absolute({ anchor = "center", x = 0, y = -200 })
ok(a.ax == 0.5 and a.alx == 0.5 and a.y == -200, "absolute: centre")

-- ---------------------------------------------------------------- HUD state machine
local S = H._S
local function reset() S.path, S.visible, S.cand, S.gonePath = nil, nil, nil, nil end
reset()
ok(H._decide({}, "A", 4) == nil, "decide: first sight of a HUD is only a candidate")
local e = H._decide({}, "A", 2)
ok(e and e.event == "attached" and e.reason == "HUD appeared" and e.visible == false, "decide: second tick attaches (hidden)")
e = H._decide({}, "A", 4)
ok(e and e.event == "shown", "decide: shown")
e = H._decide(nil)
ok(e and e.event == "lost" and e.path == "A", "decide: lost")
ok(H._decide(nil) == nil, "decide: lost only once")
ok(H._decide({}, "A", 4) == nil, "decide: back, first tick")
e = H._decide({}, "A", 4)
ok(e and e.reason == "HUD back in the viewport", "decide: back in the viewport")
ok(H._decide({}, "B", 4) == nil, "decide: replacement candidate")
ok(H._decide({}, "C", 4) == nil, "decide: a HUD replaced at once is skipped")
e = H._decide({}, "C", 4)
ok(e and e.event == "attached" and e.reason:find("HUD replaced (was A)", 1, true), "decide: replaced")
reset()

-- ---------------------------------------------------------------- end to end on the fake HUD
local hud1 = newHud(1)
hud1.vis = 2 -- the menu/lobby hides it
local events = {}
local token = H.watch(function(h, info) events[#events + 1] = info.event .. ":" .. info.reason end)
ok(findAllCount == 1, "seed: FindAllOf once on the first watch", findAllCount)
local throws = H.watch(function() error("boom") end)
local h = X.create{ id = "a", text = "hello" }
ok(type(h) == "table" and h.id == "a", "create: handle")
raises(function() h.id = "b" end, "element handles are read-only", "handle: read-only")
local canvas = hud1.OwningCanvas
ok(#canvas.children == 1 and canvas.children[1].text == "hello" and canvas.children[1].tip == "nucleus:TestMod:a", "create: attached now, tagged")
ok(X.isShown(h) == false, "isShown: false while the HUD is hidden")
tick(); tick()
ok(events[1] == "attached:HUD appeared", "watch: attached on the second tick", events[1])
ok(countLogs("WARN hud watcher %d+: ") == 1, "watch: a throwing watcher is logged once")
hud1.vis = 4
tick()
ok(events[2] and events[2]:sub(1, 6) == "shown:", "watch: shown", events[2])
ok(X.isShown(h) == true, "isShown: true in the match")
local w = canvas.children[1]
ok(w.Slot.anchors.Minimum.X == 1 and w.Slot.position.X == -16 and w.Slot.position.Y == 16 and w.Slot.auto, "place: default top-right corner")
ok(w.vis == 4, "visibility: SelfHitTestInvisible")
tick()
ok(countLogs("WARN hud watcher") == 1, "watch: still logged only once")

-- same id twice, set no-op
local h2 = X.create{ id = "a", text = "bye" }
ok(rawequal(h, h2) and #canvas.children == 1 and w.text == "bye", "create: same id, same handle, one widget")
local c0 = C.stats.uobjectCalls
X.set(h, "bye")
ok(C.stats.uobjectCalls == c0, "set: same text makes no UObject call")
X.set(h, string.rep("x", 300)); X.set(h, string.rep("y", 300))
ok(#w.text == 256 and countLogs("longer than 256") == 1, "set: long text cut, one WARN")
X.set(h, "a")

-- stack of three, hide, remove
local b = X.create{ id = "b", text = "bbbb" }
local c = X.create{ id = "c", text = "cc" }
local wb, wc
for _, ch in ipairs(canvas.children) do if ch.tip:sub(-2) == ":b" then wb = ch elseif ch.tip:sub(-2) == ":c" then wc = ch end end
ok(wb.Slot.position.Y == 16 + 20 + 16 and wc.Slot.position.Y == 16 + 20 + 16 + 20 + 16, "stack: b and c below a", wb.Slot.position.Y .. "," .. wc.Slot.position.Y)
X.setVisible(b, false)
ok(wb.vis == 1 and wc.Slot.position.Y == 52, "stack: hiding b closes the gap", wc.Slot.position.Y)
c0 = C.stats.uobjectCalls
X.setVisible(b, false)
ok(C.stats.uobjectCalls == c0, "setVisible: same value makes no UObject call")
X.setVisible(b, true)
ok(wb.vis == 4 and wc.Slot.position.Y == 88, "stack: showing b opens it again")
X.set(h, "two\nlines")
ok(wb.Slot.position.Y == 16 + 40 + 16, "stack: a taller first element pushes the others down", wb.Slot.position.Y)
X.set(h, "a")
P.place(b, { corner = "top-right", offset = { x = -40 } })
ok(wb.Slot.position.X == -56 and wc.Slot.position.X == -16 and wc.Slot.position.Y == 88, "stack: offset moves only that element")
P.place(b, { corner = "top-right" })
local abs = X.create{ id = "abs", text = "z", place = { absolute = { anchor = "top-right", x = -16, y = 16 } } }
ok(wc.Slot.position.Y == 88, "stack: an absolute element takes no space")
X.remove(abs)
local freed0 = freed
X.remove(b)
ok(wc.Slot.position.Y == 52 and wb.parent == nil and freed == freed0 + 1, "remove: closes the gap, frees the handle")
X.remove(b)
raises(function() X.isShown(b) end, "nucleus.ui.text: handle 'b' was removed", "remove: isShown raises")
raises(function() X.set(b, "x") end, "handle 'b' was removed", "remove: set raises")
raises(function() X.setVisible(b, true) end, "handle 'b' was removed", "remove: setVisible raises")
raises(function() X.set({ id = "a" }, "x") end, "nucleus.ui.text.set: not an element handle", "handle: forged")
raises(function() X.set(nil, "x") end, "nucleus.ui.text.set: expected an element handle, got nil", "handle: nil")
raises(function() X.setVisible(h, "yes") end, "nucleus.ui.text.setVisible: visible must be a boolean, got string", "setVisible: string")

-- near the crosshair, HideCrosshair
local nr = X.create{ id = "n", text = "near", place = { near = "crosshair", side = "right" } }
local wn
for _, ch in ipairs(canvas.children) do if ch.tip:sub(-2) == ":n" then wn = ch end end
ok(wn.Slot.anchors.Minimum.X == 0.5 and wn.Slot.position.X == 21 and wn.Slot.position.Y == 0 and wn.Slot.alignment.Y == 0.5, "near: right of the crosshair")
hud1.Crosshair.vis = 1
tick()
ok(wn.vis == 1 and X.isShown(nr) == false, "near: crosshair collapsed -> ours collapsed")
hud1.Crosshair.vis = 4
tick()
ok(wn.vis == 4 and X.isShown(nr) == true, "near: crosshair back -> ours back")
X.remove(nr)

-- RemoveAllWidgets and re-add: lost, then attached "back", reused (no duplicate)
hud1.inViewport = false
tick()
ok(events[#events] == "lost:HUD gone from the viewport", "rebuild: lost", events[#events])
hud1.inViewport = true
tick(); tick()
ok(events[#events] == "attached:HUD back in the viewport", "rebuild: attached back", events[#events])
local tagged = 0
for _, ch in ipairs(canvas.children) do if ch.tip:find("^nucleus:TestMod:") then tagged = tagged + 1 end end
ok(tagged == 2 and countLogs("ui attach 'a' reused") >= 1, "rebuild: reused, not duplicated", tagged)
tick() -- the next tick writes the event's attach line
ok(countLogs("^ui attach ") == 0 and countLogs("^DEBUG ui attach 'a' reused .*'c' reused .*%(HUD back in the viewport%)") >= 1, "attach line: one DEBUG line per event, no INFO line")

-- with debug off, a successful attach logs nothing (the report is not even built)
C.log.debugEnabled = false
local nLogs = #logs
hud1.inViewport = false; tick(); hud1.inViewport = true; tick(); tick(); tick()
ok(events[#events] == "attached:HUD back in the viewport" and #logs == nLogs, "attach line: nothing logged with debug off", #logs - nLogs)
C.log.debugEnabled = true

-- duplicates and orphans on the next attached
local dup = newText(PC); canvas:AddChildToCanvas(dup); dup.tip = "nucleus:TestMod:a"
local orphan = newText(PC); canvas:AddChildToCanvas(orphan); orphan.tip = "nucleus:TestMod:gone"
local other = newText(PC); canvas:AddChildToCanvas(other); other.tip = "nucleus:OtherMod:a"
hud1.inViewport = false; tick(); hud1.inViewport = true; tick(); tick()
ok(dup.parent == nil and orphan.parent == nil and other.parent == canvas, "rebuild: duplicate and orphan removed, other mod's widget kept")
ok(countLogs("removed 1 duplicate") == 1 and countLogs("removed 1 orphan") == 1, "rebuild: one WARN for the duplicate, one line for the orphan")

-- map change: the HUD dies, a new one appears; handles of dead widgets are freed; setVisible wish survives
X.setVisible(c, false)
for _, ch in ipairs(canvas.children) do kill(ch) end
kill(canvas); kill(hud1)
tick()
ok(events[#events] == "lost:HUD gone from the viewport", "map change: lost")
ok(countLogs("widget%(s%) gone with the HUD; freed handle%(s%) 'a' %d+, 'c' %d+") == 1, "map change: dead widgets' handles freed (debug)")
local hud2 = newHud(2)
for _, nfy in ipairs(notify) do if nfy.cls:find("InventoryUI", 1, true) then nfy.fn(hud2) end end -- the creation callback learns the new path
tick(); tick()
ok(findAllCount == 1, "map change: no second FindAllOf", findAllCount)
ok(events[#events] == "attached:HUD appeared", "map change: attached the new HUD", events[#events])
local c2 = hud2.OwningCanvas
local wa2, wc2
for _, ch in ipairs(c2.children) do if ch.tip:sub(-2) == ":a" then wa2 = ch elseif ch.tip:sub(-2) == ":c" then wc2 = ch end end
ok(#c2.children == 2 and wa2.text == "a" and wc2.vis == 1, "map change: re-created with text, hidden one still hidden")
ok(X.isShown(c) == false and X.isShown(h) == true, "map change: isShown")

-- a late watcher, unwatch
local late = {}
local lt = H.watch(function(_, info) late[#late + 1] = info.event end)
tick()
ok(late[1] == "attached", "late watcher: attached on the next tick")
H.unwatch(lt); H.unwatch(lt); H.unwatch(1 << 40)
tick()
ok(#late == 1, "unwatch: no more events")
raises(function() H.unwatch("x") end, "nucleus.ui.hud.unwatch: token must be an integer, got 'x'", "unwatch: string")
raises(function() H.watch(1) end, "nucleus.ui.hud.watch: fn must be a function, got 1", "watch: number")

-- pak missing: pending, one WARN per element
kill(TEXTCLASS) -- unloaded: its weak handle derefs to nil, GetAsset finds nothing
local p1 = X.create{ id = "p1", text = "x" }
X.create{ id = "p1", text = "y" }
tick(); tick()
ok(type(p1) == "table" and countLogs("text 'p1' stays pending") == 1, "pak missing: pending, one WARN")
-- an attach event that leaves an element pending logs one INFO line naming it, debug on or off
C.log.debugEnabled = false
hud2.inViewport = false; tick(); hud2.inViewport = true; tick(); tick(); tick()
ok(countLogs("^ui attach left 'p1' pending, retried in 10 ticks; attached 'a' reused .*%(HUD back in the viewport%)$") == 0
   and countLogs("^ui attach left 'p1' pending, retried in 10 ticks %(HUD back in the viewport%)$") == 1, "attach line: INFO line for a pending element, debug off")
C.log.debugEnabled = true
hud2.inViewport = false; tick(); hud2.inViewport = true; tick(); tick(); tick()
ok(countLogs("^ui attach left 'p1' pending, retried in 10 ticks; attached 'a' reused .*%(HUD back in the viewport%)$") == 1, "attach line: INFO line for a pending element names the attached ones with debug on")

-- timing: a minute of ticks gives a DEBUG summary; a slow tick a WARN
for _ = 1, 10 do tick() end
clock = clock + 61 * 1000000
tick()
ok(countLogs("^DEBUG hud tick n=") >= 1, "timing: minute summary at debug level")
H._summary()
ok(countLogs("hud tick summary n=") == 1, "timing: unload summary")
ok(countLogs("^DEBUG hud tick n=.* steady n=%d+ avg [%d%.]+ max %d+ us %(max %d+ us without a Lua GC step; %d+ tick%(s%) with one%), events n=%d+") >= 1, "timing: steady and event ticks apart")

-- steady state: canvas membership (GetParent) is checked once per 10 ticks, not per element per tick. The pending
-- element (pak missing above) goes first: its retry every RETRY_TICKS checks membership too, on a tick that depends
-- on how many ticks ran before, which is not what this measures.
X.remove(p1)
local live0 = 0
for _, e in pairs(C.els) do if e.ref and deref(e.ref) then live0 = live0 + 1 end end
PARENT_CALLS = 0
local pc0 = {}
for i = 1, 20 do local b = PARENT_CALLS; tick(); pc0[#pc0+1] = PARENT_CALLS - b end
local busyTicks = 0
for _, n in ipairs(pc0) do if n > 0 then busyTicks = busyTicks + 1 end end
ok(live0 > 0 and busyTicks <= 2, "steady: GetParent only on one tick in 10", table.concat(pc0, ","))

-- profiler: off by default; on, an event tick is one line and steady ticks one line a minute
ok(countLogs("hud prof") == 0, "profiler: off by default")
H._profile(true)
local cur; for _, x in ipairs(HUDS) do if x.__alive and x.inViewport then cur = x end end
cur.inViewport = false; tick() -- lost: an event tick
ok(countLogs("^DEBUG hud prof event=lost total=%d+ us .*poll%.find=") == 1, "profiler: event tick line", logs[#logs])
cur.inViewport = true; tick(); tick() -- back in the viewport: attached, re-attach work
ok(countLogs("^DEBUG hud prof event=attached .*watch%.core=") == 1, "profiler: attach tick names core's watcher")
for _ = 1, 3 do tick() end
clock = clock + 61 * 1000000
tick()
ok(countLogs("^DEBUG hud prof steady n=%d+ avg=") == 1, "profiler: steady minute line")
H._summary()
ok(countLogs("hud prof event ticks %(event:us%): lost:%d+ prepare:%d+ attached:%d+") == 1, "profiler: event ticks in the summary")
H._profile(false)
ok(C.prof == nil, "profiler: nothing left after a tick")

-- ---------------------------------------------------------------- story 12: overlap diagnostic (ui/debug.lua)
local D = require("nucleus.ui.debug")
-- pure parts
local function R(l, t, r, b) return { l = l, t = t, r = r, b = b } end
ok(D.intersects(R(0, 0, 10, 10), R(5, 5, 15, 15)) and D.intersects(R(5, 5, 15, 15), R(0, 0, 10, 10)), "overlap: intersecting rectangles")
ok(not D.intersects(R(0, 0, 10, 10), R(10, 0, 20, 10)) and not D.intersects(R(0, 0, 10, 10), R(0, 10, 10, 20)), "overlap: touching edges don't overlap")
ok(D.intersects(R(0, 0, 100, 100), R(40, 40, 50, 50)), "overlap: containment overlaps")
ok(D.hasArea(R(0, 0, 1, 1)) and not D.hasArea(R(5, 5, 5, 9)) and not D.hasArea(R(0, 0, 0, 0)), "overlap: area")
ok(D.isFull(R(0, 0, 950, 950), 1000, 1000) and not D.isFull(R(0, 0, 1000, 500), 1000, 1000), "overlap: full-screen is 90% both ways")
ok(D.rectStr(R(1.4, 2.6, 3, 4)) == "(1,3)-(3,4)", "overlap: rect string", D.rectStr(R(1.4, 2.6, 3, 4)))
do
    local order = {}
    local v, capped, errs, first = D.walk({ 1 }, function(x, push)
        order[#order + 1] = x
        if x == 1 then push(3); push(2) end
        if x == 3 then error("bad widget") end
    end, 100)
    ok(v == 3 and not capped and errs == 1 and tostring(first):find("bad widget", 1, true) and table.concat(order, ",") == "1,2,3", "walk: depth first, an error counted and passed over", table.concat(order, ","))
    local v2, capped2 = D.walk({ 1 }, function(x, push) push(x + 1); push(x + 2) end, 50)
    ok(v2 == 50 and capped2, "walk: capped", v2)
    local s = D.sortHits({ { path = "b", rect = R(0, 0, 10, 10) }, { path = "a", rect = R(0, 0, 2, 2) }, { path = "c", rect = R(0, 0, 2, 2) } })
    ok(s[1].path == "a" and s[2].path == "c" and s[3].path == "b", "sortHits: smallest first, then by path")
end

-- the walk on a fake HUD: on-screen rectangles come from core's ModActor CDO (<Core>_AbsTopLeft / _AbsBottomRight)
local ABS = setmetatable({}, { __mode = "k" })
local CDO = obj({}, "/Game/Mods/Nucleus/ModActor.Default__ModActor_C")
local absFail = nil -- a widget whose rectangle read raises
function CDO.Nucleus_AbsTopLeft(_, x) if x == absFail then error("geometry read failed") end local r = ABS[x] or R(0, 0, 0, 0) return vec(r.l, r.t) end
function CDO.Nucleus_AbsBottomRight(_, x) local r = ABS[x] or R(0, 0, 0, 0) return vec(r.r, r.b) end
for _, n in ipairs({ "Image", "TextBlock", "Border", "Button", "UserWidget", "PanelWidget", "WidgetSwitcher" }) do obj({ name = n }, "/Script/UMG." .. n) end
local function gw(kind, rect, isa)
    local x = { __class = kind, vis = 0, opacity = 1, isa = { [kind] = true } }
    for _, k in ipairs(isa or {}) do x.isa[k] = true end
    obj(x, "/Game/Test/W.W:WidgetTree." .. kind .. "_" .. nextAddr)
    ABS[x] = rect
    function x:GetVisibility() return self.vis end
    function x:GetRenderOpacity() return self.opacity end
    function x:GetClass() local k = self.__class return { GetFName = function() return { ToString = function() return k end } end } end
    function x:IsA(c) return self.isa[c.name] == true end
    if kind == "Image" then x.Brush, x.ColorAndOpacity = { DrawAs = 3 }, { A = 1 } end
    if kind == "TextBlock" then x.txt = "t"; function x:GetText() local s = self return { ToString = function() return s.txt end } end end
    x.children = {}
    function x:GetChildrenCount() return #self.children end
    function x:GetChildAt(i) return self.children[i + 1] end
    return x
end

local hudN = H._poll()
local cv = hudN.OwningCanvas
-- the HUD canvas as a panel the walk can read
cv.isa = { PanelWidget = true, CanvasPanel = true }
function cv:GetVisibility() return 0 end
function cv:GetRenderOpacity() return 1 end
function cv:GetClass() return { GetFName = function() return { ToString = function() return "CanvasPanel" end } end } end
function cv:IsA(c) return self.isa[c.name] == true end
ABS[cv] = R(0, 0, 1000, 600)
local function put(x) x.parent = cv; cv.children[#cv.children + 1] = x return x end
for _, ch in ipairs(cv.children) do ABS[ch] = R(0, 0, 0, 0) end -- earlier elements: not painted, never in the way

TEXTCLASS.__alive = true; objects[TEXTCLASS.__path] = TEXTCLASS -- the pak is back (unloaded in "pak missing" above)
C.log.debugEnabled = false
local sched0, checks0, ovLogs0 = C.stats.overlapScheduled, C.stats.overlapChecks, countLogs("ui overlap")
local ov = X.create{ id = "ov", text = "overlap", place = { corner = "top-right" } }
local function widgetOfId(id) local el = C.els[id] return el and el.ref and deref(el.ref) end
local ovW = widgetOfId("ov")
ABS[ovW] = R(900, 16, 1000, 46)
local imgHit = put(gw("Image", R(950, 20, 980, 40)))
put(gw("Image", R(0, 0, 50, 50)))                                    -- elsewhere
local hidden = put(gw("Image", R(950, 20, 980, 40))); hidden.vis = 1 -- collapsed: pruned
local clear = put(gw("Image", R(950, 20, 980, 40))); clear.ColorAndOpacity.A = 0 -- draws nothing
local faded = put(gw("Image", R(950, 20, 980, 40))); faded.opacity = 0
put(gw("Image", R(0, 0, 1000, 600)))                                 -- a full-screen backdrop
local panel = put(gw("Overlay", R(800, 0, 1000, 100), { "PanelWidget" }))
local inner = gw("TextBlock", R(960, 10, 990, 30)); panel.children[1] = inner
local emptyText = gw("TextBlock", R(960, 10, 990, 30)); emptyText.txt = ""; panel.children[2] = emptyText
local hidPanel = put(gw("Overlay", R(800, 0, 1000, 100), { "PanelWidget" })); hidPanel.vis = 2
hidPanel.children[1] = gw("Image", R(950, 20, 980, 40))
local otherEl = put(newText(PC)); otherEl.tip = "nucleus:OtherMod:x"; ABS[otherEl] = R(880, 30, 960, 60)
local popup = gw("PopupUI_C", R(0, 0, 1000, 600), { "UserWidget" })
local popImg = gw("Image", R(990, 40, 1000, 50))
popup.WidgetTree = obj({ RootWidget = popImg }, "/Game/Test/Popup.WidgetTree")
function popup:IsInViewport() return self.inViewport ~= false end
TOPS[1] = popup
local offscreen = gw("OffscreenUI_C", R(0, 0, 1000, 600), { "UserWidget" }) -- not in the viewport: never a root
local offImg = gw("Image", R(940, 20, 990, 40)) -- would overlap the element if its widget were walked
offscreen.WidgetTree = obj({ RootWidget = offImg }, "/Game/Test/Offscreen.WidgetTree")
function offscreen:IsInViewport() return false end
TOPS[2] = offscreen
TOPS[3] = hudN -- the live HUD is in the viewport too: its canvas is already a root, so it must not be added again
local nearMiss = put(gw("Image", R(850, 16, 890, 40))) -- 10 px left of the element: context, not an overlap

-- story 12 AC 4: with debug off nothing is scheduled and no check runs, through attach, re-place, hide and show
P.place(ov, { corner = "top-right", gap = "tight" }); P.place(ov, { corner = "top-right" })
X.setVisible(ov, false); X.setVisible(ov, true)
hudN.inViewport = false; tick(); hudN.inViewport = true; tick(); tick(); tick(); tick(); tick()
ovW = widgetOfId("ov"); ABS[ovW] = R(900, 16, 1000, 46)
ok(C.stats.overlapScheduled == sched0 and C.stats.overlapChecks == checks0 and countLogs("ui overlap") == ovLogs0, "auto check: off with debug off (counters unchanged)",
    (C.stats.overlapScheduled - sched0) .. " scheduled, " .. (C.stats.overlapChecks - checks0) .. " checks")
ok(X.stats().overlapScheduled == sched0 and X.stats().overlapChecks == checks0, "stats: overlap counters")

-- overlaps(handle): the drawn widgets under the element; the element's own subtree, hidden, clear and full-screen ones not
local hits, info = D.overlaps(ov)
local byPath = {}
for _, hh in ipairs(hits or {}) do byPath[hh.path] = hh end
ok(type(hits) == "table" and #hits == 4, "overlaps: four hits", hits and #hits or info)
ok(byPath[C.pathOf(imgHit)] and byPath[C.pathOf(imgHit)].class == "Image" and near(byPath[C.pathOf(imgHit)].rect.l, 950), "overlaps: a game image, with class and rect")
ok(byPath[C.pathOf(inner)] ~= nil and byPath[C.pathOf(emptyText)] == nil, "overlaps: text inside a panel; empty text draws nothing")
ok(byPath[C.pathOf(otherEl)] and byPath[C.pathOf(otherEl)].element == "nucleus:OtherMod:x", "overlaps: another mod's Nucleus element counts, named by its tag")
ok(byPath[C.pathOf(popImg)] ~= nil, "overlaps: a top-level widget's tree is walked")
ok(byPath[C.pathOf(offImg)] == nil, "overlaps: a UserWidget outside the viewport isn't a root")
ok(info and info.via == "FindAllOf(UserWidget)" and info.roots == 2, "overlaps: roots from FindAllOf(UserWidget) in the viewport (story 17)", info and (tostring(info.via) .. " roots=" .. tostring(info.roots)))
ok(byPath[C.pathOf(hidden)] == nil and byPath[C.pathOf(clear)] == nil and byPath[C.pathOf(faded)] == nil and byPath[C.pathOf(hidPanel.children[1])] == nil,
    "overlaps: collapsed, clear, transparent and hidden-panel widgets don't count")
ok(info and info.fullScreen == 1 and info.screen.w == 1000 and info.screen.h == 600 and not info.capped and info.errors == 0, "overlaps: info (full-screen skipped, screen size)")
ok(hits and hits[1].path == C.pathOf(popImg), "overlaps: smallest first")
ok(info and #info.nearby == 1 and info.nearby[1].path == C.pathOf(nearMiss), "overlaps: info.nearby lists the near miss only", info and #info.nearby)
local fresh = D.overlaps(ov)
ok(fresh ~= hits and fresh[1] ~= hits[1], "overlaps: fresh tables each call")
for _, hh in ipairs(hits) do
    local plain = true
    for _, v in pairs(hh) do if type(v) == "userdata" or (type(v) == "table" and v.__alive ~= nil) then plain = false end end
    ok(plain, "overlaps: entries hold no UObject (" .. hh.path .. ")")
end
-- the same check for a widget the caller placed itself (the skeleton scenario's hand-made widget)
local sk = put(gw("Image", R(0, 500, 40, 540)))
local skHits = D._check(hudN, sk)
ok(type(skHits) == "table" and #skHits == 0, "overlaps: _check of a widget clear of everything", skHits and #skHits)
cv.children[#cv.children] = nil; sk.parent = nil

-- nil plus a reason when it can't check
X.setVisible(ov, false)
local n1, why1 = D.overlaps(ov)
ok(n1 == nil and tostring(why1):find("hidden", 1, true), "overlaps: hidden element -> nil, reason", why1)
X.setVisible(ov, true)
hudN.vis = 2
local n2, why2 = D.overlaps(ov)
ok(n2 == nil and why2 == "the HUD is hidden", "overlaps: hidden HUD -> nil, reason", why2)
hudN.vis = 4
ABS[ovW] = R(0, 0, 0, 0)
local n3, why3 = D.overlaps(ov)
ok(n3 == nil and tostring(why3):find("not painted", 1, true), "overlaps: not painted yet -> nil, reason", why3)
ABS[ovW] = R(900, 16, 1000, 46)

-- AC 5: a widget that fails is counted and logged once; a check that fails returns nil and logs once; the element is untouched
absFail = imgHit
local h5, i5 = D.overlaps(ov)
ok(type(h5) == "table" and #h5 == 3 and i5.errors == 1 and countLogs("^WARN ui overlap: 1 widget%(s%) could not be checked, first: .*geometry read failed") == 1, "robust: a failing widget is skipped and logged", i5 and i5.errors)
D.overlaps(ov)
ok(countLogs("could not be checked") == 1, "robust: logged once")
absFail = ovW
local h6, why6 = D.overlaps(ov)
ok(h6 == nil and tostring(why6):find("the check failed: ", 1, true) and countLogs("^WARN ui overlap check failed: ") == 1, "robust: a failing check -> nil, reason, one WARN", why6)
D.overlaps(ov)
ok(countLogs("^WARN ui overlap check failed: ") == 1 and X.isShown(ov) == true and ovW.parent == cv, "robust: logged once; the element is untouched")
absFail = nil

-- bad input (AGENTS.md: every public entry point)
raises(function() D.overlaps(nil) end, "nucleus.ui.debug.overlaps: expected an element handle, got nil", "overlaps: nil")
raises(function() D.overlaps("ov") end, "nucleus.ui.debug.overlaps: expected an element handle, got 'ov'", "overlaps: string")
raises(function() D.overlaps(42) end, "nucleus.ui.debug.overlaps: expected an element handle, got 42", "overlaps: number")
raises(function() D.overlaps({ id = "ov" }) end, "nucleus.ui.debug.overlaps: not an element handle", "overlaps: forged handle")
raises(function() D.overlaps(ov, 1) end, "nucleus.ui.debug.overlaps: expected 1 argument (handle), got 2", "overlaps: extra argument")
offThread = true
raises(function() D.overlaps(ov) end, "nucleus.ui.debug.overlaps called off the game thread", "overlaps: off the game thread")
offThread = false
C.bound = false
raises(function() D.overlaps(ov) end, "nucleus.ui: debug.overlaps called before connect", "overlaps: before connect")
C.bound = true
local gone = X.create{ id = "gone" }; X.remove(gone)
raises(function() D.overlaps(gone) end, "handle 'gone' was removed", "overlaps: removed handle")

-- automatic check with debug on: about 1 s (two ticks) after an attach or re-place, one WARN per element and widget
C.log.debugEnabled = true
local nWarn = countLogs("^WARN ui overlap 'ov': ")
P.place(ov, { corner = "top-right", gap = "tight" })
ovW = widgetOfId("ov"); ABS[ovW] = R(900, 16, 1000, 46)
ok(C.stats.overlapScheduled > sched0, "auto check: scheduled on a re-place")
tick()
ok(countLogs("^WARN ui overlap 'ov': ") == nWarn, "auto check: not before its delay")
for _ = 1, 10 do tick() end -- the corner's other elements are checked first (one check per tick, creation order)
ok(countLogs("^WARN ui overlap 'ov': ") == nWarn + 4, "auto check: one WARN per overlapping widget", countLogs("^WARN ui overlap 'ov': ") - nWarn)
ok(countLogs("^WARN ui overlap 'ov': .*OtherMod") == 0 and countLogs("^WARN ui overlap 'ov': " .. C.pathOf(otherEl):gsub("%p", "%%%0") .. " %(WBP_NucleusText_C%) %(880,30%)%-%(960,60%)$") == 1,
    "auto check: names the widget, its class and rect")
ok(countLogs("^DEBUG ui overlap 'ov' checked %(place%): 4 overlap%(s%), 4 new;") == 1, "auto check: one DEBUG summary", logs[#logs])
P.place(ov, { corner = "top-right" }); for _ = 1, 10 do tick() end
ok(countLogs("^WARN ui overlap 'ov': ") == nWarn + 4, "auto check: once per pair (a re-place logs nothing new)")
local late2 = put(gw("Image", R(905, 20, 915, 30)))
hudN.vis = 2; tick(); hudN.vis = 4; for _ = 1, 12 do tick() end
ok(countLogs("^WARN ui overlap 'ov': ") == nWarn + 5 and countLogs("^WARN ui overlap 'ov': " .. C.pathOf(late2):gsub("%p", "%%%0")) == 1, "auto check: HUD shown again checks again; only the new pair is logged")
-- not painted: retried, then one DEBUG line
ABS[ovW] = R(0, 0, 0, 0)
X.setVisible(ov, false); X.setVisible(ov, true)
for _ = 1, 24 do tick() end
ok(countLogs("^DEBUG ui overlap 'ov' not checked %(re%-stack%): not painted yet") == 1, "auto check: not painted -> retried, then one DEBUG line")
X.remove(ov)
C.log.debugEnabled = true


-- ---------------------------------------------------------------- story 13: the Journal's map page as a host
-- Fake Journal_C: MapWidget (its WidgetTree.RootWidget a CanvasPanel), WidgetSwitcher_0 showing MapWidget.
local CANVASCLASS = objects["/Script/UMG.CanvasPanel"] or obj({ name = "CanvasPanel" }, "/Script/UMG.CanvasPanel")
local VP_CALLS = 0
local function newJournal(n)
    local path = "/Engine/Transient.GameEngine_1:GameInstance_1.Journal_C_" .. n
    local j = { __class = "Journal_C", inViewport = false }
    obj(j, path)
    local root = newCanvas(path .. ".WidgetTree_1.CanvasPanel_22")
    function root:IsA(c) return c and c.name == "CanvasPanel" end
    local map = obj({ WidgetTree = { RootWidget = root } }, path .. ".WidgetTree_1.MapWidget")
    j.MapWidget = map
    local other = obj({}, path .. ".WidgetTree_1.Other")
    j.WidgetSwitcher_0 = obj({ active = map }, path .. ".WidgetTree_1.WidgetSwitcher_0")
    function j.WidgetSwitcher_0:GetActiveWidget() return self.active end
    j.otherPage = other
    function j:IsInViewport() VP_CALLS = VP_CALLS + 1; return self.inViewport end
    function j:GetOwningPlayer() return PC end
    function j:GetWorld() return WORLD end
    JOURNALS[#JOURNALS + 1] = j
    return j
end
-- The game's open: a new Journal (the creation callback fires), then AddToViewport.
local function created(j) for _, nfy in ipairs(notify) do if nfy.cls:find("Journal_C", 1, true) then nfy.fn(j) end end end
local function openNew(n) local j = newJournal(n); created(j); j.inViewport = true; return j end
local function tagsIn(cv)
    local t = {}
    for _, ch in ipairs(cv.children) do if type(ch.tip) == "string" and ch.tip:find("^nucleus:TestMod:") then t[#t + 1] = ch.tip:match("[^:]+$") end end
    table.sort(t)
    return table.concat(t, ",")
end
local function canvasOfJ(j) return j.MapWidget.WidgetTree.RootWidget end

-- validation and bad input
v = P.validate({ host = "journal", corner = "bottom-right", gap = "tight" })
ok(v.host == "journal" and v.corner == "bottom-right" and v.gapUnits == 8, "journal: intent validates")
ok(P.validate({ host = "journal", absolute = { anchor = "center", x = 1, y = 2 } }).host == "journal", "journal: absolute intent")
raises(function() J.watch(nil) end, "nucleus.ui.journal.watch: fn must be a function, got nil", "journal: watch(nil)")
raises(function() J.watch("x") end, "nucleus.ui.journal.watch: fn must be a function, got 'x'", "journal: watch('x')")
raises(function() J.watch(function() end, 1) end, "nucleus.ui.journal.watch: expected 1 argument (fn), got 2", "journal: watch extra")
raises(function() J.unwatch("x") end, "nucleus.ui.journal.unwatch: token must be an integer, got 'x'", "journal: unwatch('x')")
raises(function() J.unwatch(1.5) end, "nucleus.ui.journal.unwatch: token must be an integer, got 1.5", "journal: unwatch(1.5)")
raises(function() J.unwatch({}) end, "nucleus.ui.journal.unwatch: token must be an integer, got table", "journal: unwatch({})")
raises(function() J.unwatch(1 << 40) end, "nucleus.ui.journal.unwatch: unknown token 1099511627776 (not one journal.watch returned)", "journal: forged token")
raises(function() J.unwatch(token) end, "unknown token", "journal: a hud token is not a journal token")
raises(function() J.unwatch(1, 2) end, "nucleus.ui.journal.unwatch: expected 1 argument (token), got 2", "journal: unwatch extra")
raises(function() J.isOpen(1) end, "nucleus.ui.journal.isOpen: expected 0 arguments, got 1", "journal: isOpen(1)")
raises(function() J.find(true) end, "nucleus.ui.journal.find: expected 0 arguments, got 1", "journal: find(true)")
ok(J.isOpen() == false and J.find() == nil, "journal: closed before any open")

-- elements before any open: pending, not shown, no widget anywhere
local jev = {}
local jt = J.watch(function(j, info) jev[#jev + 1] = info.event .. ":" .. tostring(info.page) .. ":" .. tostring(j ~= nil) end)
local jthrow = J.watch(function() error("journal boom") end)
local ja = X.create{ id = "ja", text = "on the map", place = { host = "journal", corner = "top-right" } }
local jb = X.create{ id = "jb", text = "b1", place = { host = "journal", corner = "bottom-right" } }
local jc = X.create{ id = "jc", text = "b22", place = { host = "journal", corner = "bottom-right" } }
ok(X.isShown(ja) == false and C.els.ja.ref == nil, "journal: pending while closed")
local hudNow = H._poll()
ok(not tagsIn(hudNow.OwningCanvas):find("ja", 1, true), "journal: never put on the HUD", tagsIn(hudNow.OwningCanvas))

-- open 1: opened on the first tick that sees it; three widgets in the map page's canvas, placed
local j1 = openNew(1)
local freedJ = freed
tick()
ok(jev[1] == "opened:map:true", "journal: opened on the first tick, map page", jev[1])
ok(countLogs("WARN journal watcher %d+: .*journal boom") == 1, "journal: a throwing watcher is logged once")
local cv1 = canvasOfJ(j1)
ok(tagsIn(cv1) == "ja,jb,jc", "journal: one widget per element in the map canvas", tagsIn(cv1))
ok(J.isOpen() == true and J.find() == j1 and X.isShown(ja) == true, "journal: isOpen, find, isShown")
local wja = widgetOfId("ja")
ok(wja.parent == cv1 and wja.Slot.anchors.Minimum.X == 1 and wja.Slot.position.X == -16 and wja.Slot.position.Y == 16, "journal: top-right of the map canvas")
local wjb, wjc = widgetOfId("jb"), widgetOfId("jc")
ok(wjb.Slot.anchors.Minimum.Y == 1 and wjb.Slot.position.Y == -16 and wjc.Slot.position.Y == -(16 + 20 + 16), "journal: bottom-right stack, per host", wjc.Slot.position.Y)
ok(J.stats().attachOpens == 1 and J.stats().attachElements == 3 and J.stats().attachLast > 0, "journal: attach timed per open")
tick()
ok(countLogs("^DEBUG ui journal attach n=3 in %d+ us %(canvas %d+; 'ja' %d+ %(create %d+%); .*; place %d+%): 'ja' created") == 1, "journal: one DEBUG attach line on the next tick, with its steps")
ok(J.stats().attachSteps and #J.stats().attachSteps.items == 3 and J.stats().attachSteps.items[1].id == "ja", "journal: per-step timing in stats")
-- a late watcher hears opened on the next tick
local lateJ = {}
local jl = J.watch(function(_, info) lateJ[#lateJ + 1] = info.event end)
tick()
ok(lateJ[1] == "opened", "journal: late watcher gets opened")
J.unwatch(jl); J.unwatch(jl)
-- another page of the Journal: not shown
j1.WidgetSwitcher_0.active = j1.otherPage
ok(X.isShown(ja) == false, "journal: another page -> isShown false")
j1.WidgetSwitcher_0.active = j1.MapWidget

-- close 1: closed; handles freed, widgets untouched
j1.inViewport = false
tick()
ok(jev[#jev] == "closed:nil:false" and X.isShown(ja) == false and J.isOpen() == false, "journal: closed", jev[#jev])
ok(freed == freedJ + 0 + 3 or freed >= freedJ + 3, "journal: handles freed on close", freed - freedJ)
ok(C.els.ja.ref == nil and wja.parent == cv1 and #cv1.children == 3, "journal: no handle kept, the old Journal's widgets untouched")
tick() -- the closed line goes out on a HUD tick
ok(countLogs("^DEBUG ui journal closed: freed 3 widget handle%(s%)") == 1, "journal: closed line")

-- opens 2..4 (each a new Journal): one widget each per open, opened/closed once each
for n = 2, 4 do
    local jn = openNew(n)
    tick()
    ok(tagsIn(canvasOfJ(jn)) == "ja,jb,jc" and X.isShown(ja), "journal: open " .. n .. " has one widget per element", tagsIn(canvasOfJ(jn)))
    jn.inViewport = false
    tick()
end
local nOpened, nClosed = 0, 0
for _, e in ipairs(jev) do if e:find("^opened") then nOpened = nOpened + 1 elseif e:find("^closed") then nClosed = nClosed + 1 end end
ok(nOpened == 4 and nClosed == 4, "journal: opened and closed once per open and close", nOpened .. "/" .. nClosed)
ok(J.stats().tracked <= 1 and J.stats().lastClosed ~= nil, "journal: only the last closed Journal stays tracked", J.stats().tracked)

-- cost while closed: the last closed Journal is read every 4th tick only
VP_CALLS = 0
for _ = 1, 8 do tick() end
ok(VP_CALLS == 2, "journal: closed -> IsInViewport every 4 ticks", VP_CALLS)

-- the same Journal shown again (never seen on V8.1.2): reopened, its widgets reused, no duplicate
local j4 = JOURNALS[4]
j4.inViewport = true
for _ = 1, 4 do tick() end
ok(jev[#jev]:find("^opened") and tagsIn(canvasOfJ(j4)) == "ja,jb,jc", "journal: same Journal again -> reused, no duplicate", tagsIn(canvasOfJ(j4)))
j4.inViewport = false; tick()

-- lost: destroyed while open (a map change)
local j5 = openNew(5)
tick()
for _, ch in ipairs(canvasOfJ(j5).children) do kill(ch) end
kill(j5)
tick()
ok(jev[#jev] == "lost:nil:false" and X.isShown(ja) == false, "journal: lost", jev[#jev])

-- a hidden element stays hidden on the next open; text set while closed shows on the next open
X.setVisible(jb, false)
X.set(ja, "changed")
local j6 = openNew(6)
tick()
ok(widgetOfId("ja").text == "changed" and widgetOfId("jb").vis == 1 and widgetOfId("jc").Slot.position.Y == -16, "journal: state kept across opens (text, hidden closes the gap)")
X.setVisible(jb, true)
ok(widgetOfId("jc").Slot.position.Y == -(16 + 20 + 16), "journal: setVisible while open re-stacks the journal corner")

-- place: hud -> journal moves the widget off the HUD; journal -> hud brings it back
local mv = X.create{ id = "mv", text = "move me" }
ok(tagsIn(hudNow.OwningCanvas):find("mv", 1, true) ~= nil, "place: on the HUD first")
P.place(mv, { host = "journal", corner = "top-left" })
ok(not tagsIn(hudNow.OwningCanvas):find("mv", 1, true) and tagsIn(canvasOfJ(j6)):find("mv", 1, true), "place: hud -> journal while open", tagsIn(canvasOfJ(j6)))
P.place(mv, { host = "hud", corner = "top-left" })
ok(tagsIn(hudNow.OwningCanvas):find("mv", 1, true) and not tagsIn(canvasOfJ(j6)):find("mv", 1, true), "place: journal -> hud")
raises(function() P.place(mv, { host = "journal", near = "crosshair" }) end, "near is not available on host 'journal'", "place: near on the journal")
X.remove(mv)
-- overlaps on a journal element walks the Journal; on a closed one, a reason
local okOv, why = D.overlaps(ja)
ok(okOv == nil or type(okOv) == "table", "overlaps: journal element checked or explained", why)
j6.inViewport = false; tick()
local n7, why7 = D.overlaps(ja)
ok(n7 == nil and tostring(why7):find("not attached", 1, true), "overlaps: closed Journal -> nil, reason", why7)

-- unwatch: the dependent's watchers go; the poller keeps running for core's own journal elements
J.unwatch(jt); J.unwatch(jthrow)
local before = #jev
local j7 = openNew(7); tick()
ok(#jev == before and tagsIn(canvasOfJ(j7)) == "ja,jb,jc", "journal: unwatched -> no events; elements still attach")
j7.inViewport = false; tick()
X.remove(ja); X.remove(jb); X.remove(jc)
ok(J.stats().closes >= 6 and J.stats().findAllCalls == 1, "journal: counters; one seed FindAllOf", J.stats().findAllCalls)

-- ---------------------------------------------------------------- story 14: panels (ui/panel.lua)
local function panelTests() -- a function: the main chunk is at Lua's 200-locals limit
local hudP = H._poll()
local cvP = hudP.OwningCanvas
local function boxIds(box)
    local t = {}
    for _, ch in ipairs(box.children) do t[#t + 1] = ((ch.tip and ch.tip ~= "") and ch.tip or ch.tag or ""):match("[^:]+$") end
    return table.concat(t, ",")
end
local function pads(box, side)
    local t = {}
    for _, ch in ipairs(box.children) do if ch.vis ~= 1 then t[#t + 1] = tostring(ch.Slot.pad[side]) end end
    return table.concat(t, ",")
end

-- bad input (AC 5)
local PNC = "nucleus.ui.panel.create: "
raises(function() PN.create() end, PNC .. "expected a table", "panel: create()")
raises(function() PN.create{ id = "bp", lay = "x" } end, PNC .. "unknown key 'lay' (valid: gap, id, layout, place, style)", "panel: unknown key")
raises(function() PN.create{ id = "bp", layout = "grid" } end, PNC .. "unknown layout 'grid' (valid: vertical, horizontal)", "panel: layout grid")
raises(function() PN.create{ id = "bp", layout = 1 } end, PNC .. "unknown layout 1", "panel: layout 1")
raises(function() PN.create{ id = "bp", gap = 3 } end, PNC .. "unknown gap 3 (valid: tight, normal, loose)", "panel: gap 3")
raises(function() PN.create{ id = "bp", place = "top-left" } end, PNC .. "place must be a table or nil, got 'top-left'", "panel: place string")
raises(function() PN.create{ id = "bp", style = { background = "purple" } } end, "nucleus.ui.panel: unknown background 'purple'", "panel: style prefix")
ok(C.els.bp == nil, "panel: nothing made by a refused create")

-- AC 1: a vertical panel with three texts, in order, one dim box
local pv = PN.create{ id = "pv", place = { corner = "top-left" } }
raises(function() PN.create{ id = "pv9", place = { panel = pv } } end, PNC .. "a panel can't go inside a panel (one level only)", "panel: panel in a panel (create)")
local pv1 = X.create{ id = "pv1", text = "one", place = { panel = pv } }
local pv2 = X.create{ id = "pv2", text = "two two", place = { panel = pv } }
local pv3 = X.create{ id = "pv3", text = "three", place = { panel = pv } }
local wpv = widgetOfId("pv")
ok(wpv and wpv.parent == cvP and wpv.tag == "nucleus:TestMod:pv", "panel: one widget in the HUD canvas, tagged (CoreTag)")
ok(boxIds(wpv.VBox) == "pv1,pv2,pv3" and #wpv.HBox.children == 0, "panel: children in its VBox, in order", boxIds(wpv.VBox))
ok(pads(wpv.VBox, "Top") == "0,8,8", "panel: gap tight before every child but the first", pads(wpv.VBox, "Top"))
ok(near(wpv.bg[4], 0.35) and wpv.pad == 8, "panel: default style dim, normal padding")
ok(wpv.Slot.anchors.Minimum.X == 0 and wpv.Slot.position.X == 16 and wpv.Slot.position.Y == 16, "panel: placed like any element (top-left)")
ok(PN.isShown(pv) and X.isShown(pv2), "panel: isShown for the panel and a child")
ok(wpv:GetDesiredSize().Y == 8 + 20 + 8 + 20 + 8 + 20 + 8, "panel: one box around all three", wpv:GetDesiredSize().Y)
-- AC 2: hide the middle child: its gap goes; hide the panel: all hidden; show again
X.setVisible(pv2, false)
ok(widgetOfId("pv2").vis == 1 and pads(wpv.VBox, "Top") == "0,8" and X.isShown(pv2) == false, "panel: hiding the middle child closes the gap", pads(wpv.VBox, "Top"))
X.setVisible(pv1, false)
ok(pads(wpv.VBox, "Top") == "0", "panel: the first visible child has no gap", pads(wpv.VBox, "Top"))
X.setVisible(pv1, true); X.setVisible(pv2, true)
ok(pads(wpv.VBox, "Top") == "0,8,8", "panel: gaps back", pads(wpv.VBox, "Top"))
PN.setVisible(pv, false)
ok(wpv.vis == 1 and not PN.isShown(pv) and not X.isShown(pv1) and not X.isShown(pv3), "panel: hiding the panel hides its children")
PN.setVisible(pv, true)
ok(X.isShown(pv1) and X.isShown(pv3), "panel: showing it shows them again")
raises(function() PN.setVisible(pv, "yes") end, "nucleus.ui.panel.setVisible: visible must be a boolean, got string", "panel: setVisible('yes')")

-- bad place intents with panels (AC 5)
local PLC = "nucleus.ui.place: "
raises(function() X.create{ id = "bx", place = { panel = 5 } } end, PLC .. "panel must be a panel handle, got 5", "panel: non-handle 5")
raises(function() X.create{ id = "bx", place = { panel = "pv" } } end, PLC .. "panel must be a panel handle, got 'pv'", "panel: non-handle string")
raises(function() X.create{ id = "bx", place = { panel = {} } } end, PLC .. "panel is not a panel handle", "panel: forged table")
raises(function() X.create{ id = "bx", place = { panel = pv1 } } end, PLC .. "panel is a text element ('pv1'), not a panel", "panel: a text handle as panel")
raises(function() X.create{ id = "bx", place = { panel = pv, corner = "top-left" } } end, PLC .. "corner is not allowed with panel", "panel: panel with corner")
raises(function() P.place(pv, { panel = pv }) end, PLC .. "a panel can't go inside a panel (one level only)", "panel: place a panel in a panel")
raises(function() X.set(pv, "x") end, "nucleus.ui.text.set: not a text element handle ('pv' is a panel)", "panel: text.set on a panel")
raises(function() PN.order(pv1) end, "nucleus.ui.panel.order: not a panel handle ('pv1' is a text element)", "panel: order on a text")
raises(function() PN.order(nil) end, "nucleus.ui.panel.order: expected a panel handle, got nil", "panel: order(nil)")
raises(function() PN.order({}) end, "nucleus.ui.panel.order: not a panel handle (use the handle that panel.create returned)", "panel: order(forged)")
raises(function() X.create{ id = "pv", text = "x" } end, "nucleus.ui.text.create: id 'pv' is already a panel of this mod", "panel: id taken by another kind")
ok(C.els.bx == nil, "panel: nothing made by refused creates")

-- AC 6: reorder. move third to 1; setOrder reversed; order(); the same widgets; no-op makes no call
local w1, w2, w3 = widgetOfId("pv1"), widgetOfId("pv2"), widgetOfId("pv3")
local created0 = C.stats.attachCreated
PN.move(pv, pv3, 1)
ok(boxIds(wpv.VBox) == "pv3,pv1,pv2" and pads(wpv.VBox, "Top") == "0,8,8", "reorder: move(third, 1) puts it first", boxIds(wpv.VBox))
local o = PN.order(pv)
ok(#o == 3 and rawequal(o[1], pv3) and rawequal(o[2], pv1) and rawequal(o[3], pv2), "reorder: order() returns the new order")
PN.setOrder(pv, { pv2, pv1, pv3 })
ok(boxIds(wpv.VBox) == "pv2,pv1,pv3", "reorder: setOrder reverses", boxIds(wpv.VBox))
ok(widgetOfId("pv1") == w1 and widgetOfId("pv2") == w2 and widgetOfId("pv3") == w3 and C.stats.attachCreated == created0, "reorder: the same three widgets, none created")
local c0 = C.stats.uobjectCalls
PN.setOrder(pv, { pv2, pv1, pv3 }); PN.move(pv, pv1, 2)
ok(C.stats.uobjectCalls == c0, "reorder: an unchanged order makes no UObject call")
-- bad reorders leave the order unchanged
local other = PN.create{ id = "po", place = { corner = "bottom-left" }, layout = "horizontal", gap = "normal" }
local po1 = X.create{ id = "po1", text = "a", place = { panel = other } }
local gone = X.create{ id = "gone", text = "g", place = { panel = pv } }
X.remove(gone)
local SO, MV = "nucleus.ui.panel.setOrder: ", "nucleus.ui.panel.move: "
raises(function() PN.setOrder(pv, { pv2, pv1 }) end, SO .. "order has 2 handle(s) but panel 'pv' has 3 child(ren)", "setOrder: a child missing")
raises(function() PN.setOrder(pv, { pv2, pv1, pv1 }) end, SO .. "order[3] ('pv1') appears twice", "setOrder: a duplicate")
raises(function() PN.setOrder(pv, { pv2, pv1, po1 }) end, SO .. "order[3] ('po1') is not a child of panel 'pv'", "setOrder: another panel's child")
raises(function() PN.setOrder(pv, { pv2, pv1, gone }) end, SO .. "order[3]: handle 'gone' was removed", "setOrder: a removed child")
raises(function() PN.setOrder(pv, { pv2, pv1, 5 }) end, SO .. "order[3] is not a child handle, got 5", "setOrder: a non-handle")
raises(function() PN.setOrder(pv, { pv2, pv1, {} }) end, SO .. "order[3] is not an element handle", "setOrder: a forged handle")
raises(function() PN.setOrder(pv, "pv1,pv2,pv3") end, SO .. "order must be a table of the panel's child handles, got 'pv1,pv2,pv3'", "setOrder: a non-table")
raises(function() PN.setOrder(pv, { pv2, pv1, pv3, x = 1 }) end, SO .. "order must be a list (keys 1 to n), got key 'x'", "setOrder: a non-list key")
raises(function() PN.move(pv, pv1, 0) end, MV .. "index 0 is out of range (1 to 3)", "move: index 0")
raises(function() PN.move(pv, pv1, 4) end, MV .. "index 4 is out of range (1 to 3)", "move: count + 1")
raises(function() PN.move(pv, pv1, 1.5) end, MV .. "index must be an integer from 1 to 3, got 1.5", "move: 1.5")
raises(function() PN.move(pv, pv1, "1") end, MV .. "index must be an integer from 1 to 3, got '1'", "move: '1'")
raises(function() PN.move(pv, po1, 1) end, MV .. "'po1' is not a child of panel 'pv'", "move: another panel's child")
raises(function() PN.move(pv, gone, 1) end, "handle 'gone' was removed", "move: a removed child")
raises(function() PN.move(pv, pv1, 1, 2) end, MV .. "expected 3 arguments (handle, child, index), got 4", "move: extra argument")
ok(boxIds(wpv.VBox) == "pv2,pv1,pv3" and PN.order(pv)[1] == pv2, "reorder: refused calls left the order unchanged", boxIds(wpv.VBox))

-- AC 4: a horizontal panel lays its children out left to right
local po2 = X.create{ id = "po2", text = "bb", place = { panel = other } }
local po3 = X.create{ id = "po3", text = "ccc", place = { panel = other } }
local wpo = widgetOfId("po")
ok(boxIds(wpo.HBox) == "po1,po2,po3" and #wpo.VBox.children == 0 and pads(wpo.HBox, "Left") == "0,16,16", "horizontal: HBox, left to right, normal gap", pads(wpo.HBox, "Left"))
ok(wpo:GetDesiredSize().X == 10 + 16 + 20 + 16 + 30 + 2 * 8, "horizontal: widths add up", wpo:GetDesiredSize().X)

-- a hidden child keeps its position through a reorder; the 33rd child is refused
X.setVisible(pv1, false)
PN.move(pv, pv3, 1)
ok(boxIds(wpv.VBox) == "pv3,pv2,pv1" and widgetOfId("pv1").vis == 1, "reorder: a hidden child moves with the order", boxIds(wpv.VBox))
X.setVisible(pv1, true)
PN.setOrder(pv, { pv2, pv1, pv3 })
local many = {}
for i = 1, 29 do many[i] = X.create{ id = "m" .. i, text = "m", place = { panel = other } } end
ok(#PN.order(other) == 32, "limit: 32 children fit", #PN.order(other))
raises(function() X.create{ id = "m30", text = "m", place = { panel = other } } end, PLC .. "panel 'po' already has 32 children (at most 32)", "limit: a 33rd child")
raises(function() P.place(pv1, { panel = other }) end, PLC .. "panel 'po' already has 32 children (at most 32)", "limit: a 33rd child by place")
ok(C.els.m30 == nil and pv1 and PN.order(pv)[2] == pv1, "limit: nothing changed")
for _, m in ipairs(many) do X.remove(m) end
ok(#PN.order(other) == 3 and #wpo.HBox.children == 3, "remove: children removed from the box", #wpo.HBox.children)

-- a child's text grows: the panel grows; same id again; move between panels and out to a host
X.set(pv1, "a much longer text")
ok(wpv:GetDesiredSize().X == 10 * #"a much longer text" + 16, "child: set grows the panel", wpv:GetDesiredSize().X)
local again = X.create{ id = "pv1", text = "one", place = { panel = pv } }
ok(rawequal(again, pv1) and boxIds(wpv.VBox) == "pv2,pv1,pv3", "child: create with the same id keeps its position")
P.place(pv2, { panel = other })
ok(boxIds(wpv.VBox) == "pv1,pv3" and boxIds(wpo.HBox) == "po1,po2,po3,pv2" and pads(wpv.VBox, "Top") == "0,8", "place: from one panel to another, at the end", boxIds(wpo.HBox))
P.place(pv2, { absolute = { anchor = "center", x = 5, y = 32 } })
local wpv2 = widgetOfId("pv2")
ok(boxIds(wpo.HBox) == "po1,po2,po3" and wpv2.parent == cvP and wpv2.Slot.position.Y == 32 and wpv2.Slot.anchors.Minimum.X == 0.5, "place: out of a panel onto the HUD", tostring(wpv2 and wpv2.Slot.position.Y))
P.place(pv2, { panel = pv })
PN.move(pv, pv2, 1)
ok(boxIds(wpv.VBox) == "pv2,pv1,pv3" and widgetOfId("pv2").parent == wpv.VBox, "place: back into the panel, then moved first", boxIds(wpv.VBox))
local pdup = PN.create{ id = "pv", place = { corner = "top-left" }, gap = "loose" }
ok(rawequal(pdup, pv) and pads(wpv.VBox, "Top") == "0,32,32", "panel: the same id with a new gap re-gaps the children", pads(wpv.VBox, "Top"))
PN.create{ id = "pv", place = { corner = "top-left" }, layout = "horizontal" }
ok(#wpv.VBox.children == 0 and boxIds(wpv.HBox) == "pv2,pv1,pv3" and pads(wpv.HBox, "Left") == "0,8,8", "panel: a layout change moves the same widgets to the other box", boxIds(wpv.HBox))
PN.create{ id = "pv", place = { corner = "top-left" } }
ok(boxIds(wpv.VBox) == "pv2,pv1,pv3" and widgetOfId("pv1") == w1, "panel: and back", boxIds(wpv.VBox))
PN.setStyle(pv, { background = "dark", padding = "loose" })
ok(near(wpv.bg[4], 0.7) and wpv.pad == 12, "panel: setStyle")
c0 = C.stats.uobjectCalls
PN.setStyle(pv, { background = "dark", padding = "loose" })
ok(C.stats.uobjectCalls == c0, "panel: the same style again makes no UObject call")

-- AC 3: RemoveAllWidgets and re-add (the same HUD back): reused, same order, one widget each
hudP.inViewport = false; tick(); hudP.inViewport = true; tick(); tick()
local nP = 0
for _, ch in ipairs(cvP.children) do if ch.tag == "nucleus:TestMod:pv" then nP = nP + 1 end end
ok(nP == 1 and widgetOfId("pv") == wpv and boxIds(wpv.VBox) == "pv2,pv1,pv3" and widgetOfId("pv1") == w1, "rebuild: panel and children reused, order kept", boxIds(wpv.VBox))
-- a child's widget gone (another mod removed it): the HUD tick re-attaches it in its place
w3:RemoveFromParent(); kill(w3)
for _ = 1, 3 do tick() end
ok(boxIds(wpv.VBox) == "pv2,pv1,pv3" and widgetOfId("pv3") ~= w3 and widgetOfId("pv3").parent == wpv.VBox, "re-attach: a lost child comes back in its place", boxIds(wpv.VBox))
-- a duplicate and an orphan in the box are removed on the next attach
local dupT = newText(PC); wpv.VBox:AddChild(dupT); dupT.tip = "nucleus:TestMod:pv1"
local orphT = newText(PC); wpv.VBox:AddChild(orphT); orphT.tip = "nucleus:TestMod:nobody"
hudP.inViewport = false; tick(); hudP.inViewport = true; tick(); tick()
ok(dupT.parent == nil and orphT.parent == nil and boxIds(wpv.VBox) == "pv2,pv1,pv3", "rebuild: duplicate and orphan removed from the box", boxIds(wpv.VBox))
-- map change: a new HUD; new widgets in the same order
for _, ch in ipairs(cvP.children) do kill(ch) end
kill(cvP); kill(hudP)
tick()
local hudQ = newHud(3)
for _, nfy in ipairs(notify) do if nfy.cls:find("InventoryUI", 1, true) then nfy.fn(hudQ) end end
tick(); tick()
local wq = widgetOfId("pv")
ok(wq and wq ~= wpv and wq.parent == hudQ.OwningCanvas and boxIds(wq.VBox) == "pv2,pv1,pv3" and pads(wq.VBox, "Top") == "0,8,8", "map change: a new panel, children in the same order", wq and boxIds(wq.VBox))
ok(near(wq.bg[4], 0.7) and wq.pad == 12, "map change: style kept")

-- remove: the panel and its children go; their handles raise
local freedP = freed
PN.remove(pv)
ok(wq.parent == nil and C.els.pv1 == nil and C.els.pv == nil and freed >= freedP + 4, "remove: the panel and its children")
raises(function() X.set(pv1, "x") end, "nucleus.ui.text: handle 'pv1' was removed", "remove: a child's handle raises")
raises(function() PN.order(pv) end, "nucleus.ui.panel: handle 'pv' was removed", "remove: the panel's handle raises")
raises(function() X.create{ id = "bx", place = { panel = pv } } end, "nucleus.ui.panel: handle 'pv' was removed", "remove: a removed panel in an intent")
PN.remove(pv)
ok(true, "remove: idempotent")

-- the Journal: a panel with two texts; per open new widgets in order; a reorder while open and on the next open
local jp = PN.create{ id = "jp", place = { host = "journal", corner = "bottom-right" } }
local jq1 = X.create{ id = "jq1", text = "first", place = { panel = jp } }
local jq2 = X.create{ id = "jq2", text = "second", place = { panel = jp } }
ok(not PN.isShown(jp) and C.els.jq1.ref == nil, "journal panel: pending while closed")
local j8 = openNew(8); tick()
local wjp = widgetOfId("jp")
ok(wjp and wjp.parent == canvasOfJ(j8) and boxIds(wjp.VBox) == "jq1,jq2" and X.isShown(jq2), "journal panel: on the map page with its children", wjp and boxIds(wjp.VBox))
local st = J.stats().attachSteps
local names = {}
for _, it in ipairs(st.items) do names[#names + 1] = it.id .. (it.panel and ("@" .. it.panel) or "") end
ok(table.concat(names, ",") == "jq1@jp,jq2@jp,jp" and st.canvas >= 0 and st.place >= 0 and J.stats().attachElements == 3, "journal panel: steps per element, children within their panel", table.concat(names, ","))
tick()
ok(countLogs("^DEBUG ui journal attach n=3 in %d+ us %(canvas %d+; 'jq1' %d+ %(create %d+, in 'jp'%); 'jq2' %d+ %(create %d+, in 'jp'%); 'jp' %d+ %(create %d+, own %-?%d+%); place %d+%)") == 1, "journal panel: the DEBUG line names every step")
PN.move(jp, jq2, 1)
ok(boxIds(wjp.VBox) == "jq2,jq1", "journal panel: a reorder applies while open")
j8.inViewport = false; tick()
local j9 = openNew(9); tick()
ok(boxIds(widgetOfId("jp").VBox) == "jq2,jq1" and widgetOfId("jp") ~= wjp, "journal panel: and on the next open", boxIds(widgetOfId("jp").VBox))
j9.inViewport = false; tick()
PN.setOrder(jp, { jq1, jq2 })
local j10 = openNew(10); tick()
ok(boxIds(widgetOfId("jp").VBox) == "jq1,jq2", "journal panel: a reorder while closed shows on the next open")
j10.inViewport = false; tick()
PN.remove(jp)
ok(C.els.jq1 == nil, "journal panel: removed")
PN.remove(other)
end
panelTests()

-- ---------------------------------------------------------------- story 15: buttons (ui/button.lua)
local function buttonTests()
local BN = require("nucleus.ui.button")
local function clickW(w) for _, hk in ipairs(HOOKS) do hk.fn({ get = function() return w end }) end end
local hits = {}
local function counter(name) return function(h) hits[name] = (hits[name] or 0) + 1; hits[name .. ".h"] = h end end
local BC, PLC = "nucleus.ui.button.create: ", "nucleus.ui.place: "
local jplace = { host = "journal", corner = "top-left" }

-- bad input (AC 7)
raises(function() BN.create() end, BC .. "expected a table", "button: create()")
raises(function() BN.create{ id = "bb", onClick = counter("x"), place = jplace, colour = 1 } end, BC .. "unknown key 'colour' (valid: enabled, id, label, onClick, place, style)", "button: unknown key")
raises(function() BN.create{ id = "bb", label = "x", place = jplace } end, BC .. "onClick must be a function, got nil", "button: onClick missing")
raises(function() BN.create{ id = "bb", label = "x", place = jplace, onClick = "f" } end, BC .. "onClick must be a function, got 'f'", "button: onClick a string")
raises(function() BN.create{ id = "bb", label = {}, place = jplace, onClick = counter("x") } end, BC .. "label must be a string, a number or nil, got table", "button: label a table")
raises(function() BN.create{ id = "bb", label = string.rep("x", 65), place = jplace, onClick = counter("x") } end, BC .. "label is 65 characters, at most 64", "button: 65-character label")
raises(function() BN.create{ id = "bb", label = "x", place = { host = "hud", corner = "top-left" }, onClick = counter("x") } end, BC .. "buttons need a host with a cursor (journal); see input mode, story 16", "button: host hud")
raises(function() BN.create{ id = "bb", label = "x", onClick = counter("x") } end, BC .. "buttons need a host with a cursor (journal)", "button: default place is the HUD")
raises(function() BN.create{ id = "bb", label = "x", place = jplace, onClick = counter("x"), enabled = "yes" } end, BC .. "enabled must be a boolean or nil, got 'yes'", "button: enabled 'yes'")
raises(function() BN.create{ id = "bb", label = "x", place = jplace, onClick = counter("x"), style = { background = "pink" } } end, "nucleus.ui.button: unknown background 'pink'", "button: style prefix")
local hudPanel = PN.create{ id = "bhp", place = { corner = "top-left" } }
raises(function() BN.create{ id = "bb", label = "x", place = { panel = hudPanel }, onClick = counter("x") } end, BC .. "buttons need a host with a cursor (journal)", "button: into a HUD panel")
PN.remove(hudPanel)
ok(C.els.bb == nil and #HOOKS == 0, "button: nothing made, no hook, by refused creates")

-- a panel with two buttons and a text on the Journal (AC 1), created while closed
local bp = PN.create{ id = "bp", place = { host = "journal", corner = "bottom-right" } }
local b1 = BN.create{ id = "b1", label = "One", place = { panel = bp }, onClick = counter("b1") }
local b2 = BN.create{ id = "b2", label = 22, place = { panel = bp }, onClick = function(h) hits.b2 = (hits.b2 or 0) + 1; error("b2 throws on purpose") end }
local bt = X.create{ id = "bt", text = "text", place = { panel = bp } }
ok(#HOOKS == 1 and HOOKS[1].path == "/Game/Mods/Nucleus/WBP_NucleusButton.WBP_NucleusButton_C:Nucleus_OnClicked", "button: one click hook per Lua state, by full path", HOOKS[1] and HOOKS[1].path)
raises(function() P.place(bp, { host = "hud", corner = "top-left" }) end, PLC .. "panel 'bp' holds buttons, which need a host with a cursor (journal); see input mode, story 16", "button: a panel holding buttons can't go to the HUD")
raises(function() P.place(b1, { host = "hud", corner = "top-left" }) end, PLC .. "buttons need a host with a cursor (journal)", "button: place on the HUD")
ok(not BN.isShown(b1) and C.els.b1.ref == nil, "button: pending while the Journal is closed")
local jb = openNew(20); tick()
local wbp = widgetOfId("bp")
local wb1, wb2 = widgetOfId("b1"), widgetOfId("b2")
ok(wbp and wbp.parent == canvasOfJ(jb), "button: the panel on the map page")
ok(wb1 and wb1.parent == wbp.VBox and wb2.parent == wbp.VBox and widgetOfId("bt").parent == wbp.VBox, "button: both buttons and the text in the panel's box")
ok(wb1.tag == "nucleus:TestMod:b1" and wb1.label == "One" and wb2.label == "22", "button: tag in CoreTag, labels (a number is text)")
ok(wb1.colors and near(wb1.colors[4], 0.85) and near(wb1.colors[8], 0.9) and near(wb1.colors[12], 0.95) and wb1.colors[13] == 4, "button: theme face, hover, pressed and tight padding", wb1.colors and table.concat(wb1.colors, ","))
ok(wb1.enabledCalls == 0 and wb1.opacity == 1, "button: an enabled new button makes no enabled-state call")
ok(BN.isShown(b1) and BN.isShown(b2), "button: isShown on the open map")

-- a click runs onClick once with its handle; a repeat within 250 ms counts once; the next one later counts
clickW(wb1)
ok(hits.b1 == 1 and rawequal(hits["b1.h"], b1) and wb1.clicks == 0, "click: onClick(handle) runs once")
clock = clock + 100000
clickW(wb1)
ok(hits.b1 == 1 and BN.stats().debounced == 1, "click: a repeat within 250 ms is dropped")
clock = clock + 300000
clickW(wb1)
ok(hits.b1 == 2 and BN.stats().clicks == 2, "click: the next click later counts")
-- a throwing onClick: one WARN per button, the hook keeps working (AC 3)
clock = clock + 300000; clickW(wb2)
clock = clock + 300000; clickW(wb2)
ok(hits.b2 == 2 and countLogs("^WARN button 'b2' onClick: .*b2 throws on purpose") == 1 and BN.stats().throws == 2, "click: a throwing onClick logs one WARN; the next click still runs it")
clock = clock + 300000; clickW(wb1)
ok(hits.b1 == 3, "click: other buttons unaffected by a throwing one")
-- disabled (AC 4): no call, drawn dim; enabled again: clicks again
BN.setEnabled(b1, false)
ok(wb1.enabled == false and near(wb1.opacity, 0.45), "disabled: SetEnabledState(false), drawn at the theme's opacity")
clock = clock + 300000; clickW(wb1)
ok(hits.b1 == 3 and BN.stats().dropped >= 1, "disabled: a click runs nothing")
local c0 = C.stats.uobjectCalls
BN.setEnabled(b1, false)
ok(C.stats.uobjectCalls == c0, "disabled: the same state again makes no UObject call")
BN.setEnabled(b1, true)
ok(wb1.enabled == true and wb1.opacity == 1, "enabled again: opaque")
clock = clock + 300000; clickW(wb1)
ok(hits.b1 == 4, "enabled again: clicks run")
-- hidden button, hidden panel: dropped
BN.setVisible(b1, false)
clock = clock + 300000; clickW(wb1)
BN.setVisible(b1, true)
PN.setVisible(bp, false)
clock = clock + 300000; clickW(wb1)
PN.setVisible(bp, true)
ok(hits.b1 == 4, "hidden: clicks on a hidden button or in a hidden panel are dropped")
-- another mod's button and a forged tag: ignored in silence (AC 2)
local other = newButtonW(); other.tag = "nucleus:OtherMod:b1"
local logs0 = #logs
clock = clock + 300000; clickW(other)
local junk = newButtonW(); junk.tag = "something else"
clickW(junk)
ok(hits.b1 == 4 and #logs == logs0 and BN.stats().ignored >= 2, "dispatch: another mod's button is ignored in silence")
-- a hook context that fails: logged once, nothing escapes
for _, hk in ipairs(HOOKS) do hk.fn({ get = function() error("bad context") end }) end
ok(countLogs("^WARN button click handling failed: .*bad context") == 1, "dispatch: a failing context is caught and logged once")
-- labels: set, no-op, validation
BN.setLabel(b1, "Uno")
ok(wb1.label == "Uno", "setLabel: applied")
c0 = C.stats.uobjectCalls
BN.setLabel(b1, "Uno")
ok(C.stats.uobjectCalls == c0, "setLabel: the same label makes no UObject call")
raises(function() BN.setLabel(b1, {}) end, "nucleus.ui.button.setLabel: label must be a string, a number or nil, got table", "setLabel: a table")
raises(function() BN.setLabel(b1, string.rep("é", 65)) end, "nucleus.ui.button.setLabel: label is 65 characters, at most 64", "setLabel: 65 UTF-8 characters")
BN.setLabel(b1, string.rep("é", 64))
ok(wb1.label == string.rep("é", 64), "setLabel: 64 UTF-8 characters fit")
BN.setLabel(b1, "One")
raises(function() BN.setEnabled(b1, "yes") end, "nucleus.ui.button.setEnabled: enabled must be a boolean, got 'yes'", "setEnabled: 'yes'")
raises(function() BN.setEnabled(b1) end, "nucleus.ui.button.setEnabled: enabled must be a boolean, got nil", "setEnabled: nil")
raises(function() BN.setVisible(b1, 1) end, "nucleus.ui.button.setVisible: visible must be a boolean, got number", "setVisible: 1")
raises(function() BN.setLabel({ id = "b1" }, "x") end, "nucleus.ui.button.setLabel: not a button handle (use the handle that button.create returned)", "button: forged handle")
raises(function() BN.setLabel(nil, "x") end, "nucleus.ui.button.setLabel: expected a button handle, got nil", "button: nil handle")
raises(function() BN.setEnabled(bt, true) end, "nucleus.ui.button.setEnabled: not a button handle ('bt' is a text element)", "button: a text handle")
raises(function() X.set(b1, "x") end, "nucleus.ui.text.set: not a text element handle ('b1' is a button)", "button: text.set on a button")
-- same id again: same handle, new callback, no second hook
local hookN = #HOOKS
local b1again = BN.create{ id = "b1", label = "One", place = { panel = bp }, onClick = counter("b1new") }
clock = clock + 300000; clickW(wb1)
ok(rawequal(b1again, b1) and hits.b1new == 1 and hits.b1 == 4 and #HOOKS == hookN, "button: create with the same id swaps the callback; still one hook")
-- the next open: new widgets; an old widget of b1 is ignored; order and state kept
jb.inViewport = false; tick()
BN.setEnabled(b2, false)
local jb2 = openNew(21); tick()
local wb1n, wb2n = widgetOfId("b1"), widgetOfId("b2")
ok(wb1n ~= wb1 and wb2n.enabled == false and near(wb2n.opacity, 0.45), "next open: new widgets, the disabled state applied")
clock = clock + 300000; clickW(wb1)
ok(hits.b1new == 1 and BN.stats().ignored >= 3, "next open: a click on the old Journal's widget is ignored")
clock = clock + 300000; clickW(wb1n)
ok(hits.b1new == 2, "next open: the new widget clicks")
-- remove: its handle raises; its widget is ignored
BN.remove(b2)
BN.remove(b2)
raises(function() BN.setLabel(b2, "x") end, "nucleus.ui.button: handle 'b2' was removed", "remove: a removed handle raises")
clock = clock + 300000; clickW(wb2n)
ok(hits.b2 == 2, "remove: its widget no longer runs anything")
jb2.inViewport = false; tick()
PN.remove(bp)
ok(C.els.b1 == nil and C.els.bt == nil and #HOOKS == 1, "remove: the panel with its buttons; the hook stays registered")
end
buttonTests()

H.unwatch(token); H.unwatch(throws)
ok(asyncUsed == 0, "poller: never LoopAsync or ExecuteInGameThread", asyncUsed)
ok(cancelled == 0 or H.stats().running == true, "poller: a stop cancels its loop")
print(string.format("ui_test: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
