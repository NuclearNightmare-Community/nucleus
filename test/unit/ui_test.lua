-- Unit tests for core's UI helpers (lua/pkg/ui/), outside the game: UE4SS globals and UMG widgets are stubbed with
-- plain Lua tables, so this checks the helpers' own logic (validation, the HUD state machine, layout math, attach,
-- re-attach, duplicates, orphans, no-op counters), not the engine. The in-game proof is run.ps1 -Scenario ui.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/ui_test.lua
-- (on this workspace's machine: MiKTeX's texlua.exe, which is Lua 5.3).
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

-- ---------------------------------------------------------------- module loading as Mods/Nucleus/Scripts/nucleus/*
package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.2.0" } end
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
    function w:GetParent() return self.parent end
    function w:ForceLayoutPrepass() end
    function w:GetDesiredSize()
        if self.vis == 1 then return vec(0, 0) end
        local lines = 1
        for _ in self.text:gmatch("\n") do lines = lines + 1 end
        return vec(10 * #self.text + 2 * self.pad, 20 * lines + 2 * self.pad)
    end
    function w:GetClass() return { GetFName = function() return { ToString = function() return TEXT_SHORT end } end } end
    return w
end

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
function FindAllOf(cls)
    findAllCount = findAllCount + 1
    local out = {}
    for _, h in ipairs(HUDS) do if h.__alive then out[#out + 1] = h end end
    return out
end
local GS = obj({ GetPlayerController = function() return PC end }, "/Script/Engine.Default__GameplayStatics")
local WBL = obj({ Create = function(_, world, cls, owner) return newText(owner) end }, "/Script/UMG.Default__WidgetBlueprintLibrary")
local TEXTCLASS = obj({}, "/Game/Mods/Nucleus/WBP_NucleusText.WBP_NucleusText_C")
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
local P = require("nucleus.ui.place")
local X = require("nucleus.ui.text")

local logs = {}
local function logger()
    local L = { debugEnabled = true }
    local function emit(level, fmt, ...) logs[#logs + 1] = level .. string.format(fmt, ...) end
    function L.info(f, ...) emit("", f, ...) end
    function L.warn(f, ...) emit("WARN ", f, ...) end
    function L.error(f, ...) emit("ERROR ", f, ...) end
    function L.debug(f, ...) emit("DEBUG ", f, ...) end
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

C.bind{ mod = "TestMod", log = logger(), ref = ref, deref = deref, free = free, micros = micros }

-- ---------------------------------------------------------------- off the game thread
offThread = true
raises(function() X.create{ id = "a" } end, "nucleus.ui.text.create called off the game thread", "off thread: create")
raises(function() H.find() end, "nucleus.ui.hud.find called off the game thread", "off thread: find")
raises(function() P.place({}, {}) end, "nucleus.ui.place called off the game thread", "off thread: place")
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
    { { host = "journal", corner = "top-left" }, "unknown host 'journal' (valid: hud)" },
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
ok(countLogs("widget gone with the HUD; freed handle") == 2, "map change: dead widgets' handles freed (debug)")
local hud2 = newHud(2)
for _, nfy in ipairs(notify) do nfy.fn(hud2) end -- the creation callback learns the new path
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
objects["/Game/Mods/Nucleus/WBP_NucleusText.WBP_NucleusText_C"] = nil
local p1 = X.create{ id = "p1", text = "x" }
X.create{ id = "p1", text = "y" }
tick(); tick()
ok(type(p1) == "table" and countLogs("text 'p1' stays pending") == 1, "pak missing: pending, one WARN")

-- timing: a minute of ticks gives a DEBUG summary; a slow tick a WARN
for _ = 1, 10 do tick() end
clock = clock + 61 * 1000000
tick()
ok(countLogs("^DEBUG hud tick n=") >= 1, "timing: minute summary at debug level")
H._summary()
ok(countLogs("hud tick summary n=") == 1, "timing: unload summary")
ok(countLogs("^DEBUG hud tick n=.* steady n=%d+ avg [%d%.]+ max %d+ us, events n=%d+") >= 1, "timing: steady and event ticks apart")

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
ok(countLogs("hud prof event ticks %(event:us%): lost:%d+ attached:%d+") == 1, "profiler: event ticks in the summary")
H._profile(false)
ok(C.prof == nil, "profiler: nothing left after a tick")

H.unwatch(token); H.unwatch(throws)
ok(asyncUsed == 0, "poller: never LoopAsync or ExecuteInGameThread", asyncUsed)
ok(cancelled == 0 or H.stats().running == true, "poller: a stop cancels its loop")
print(string.format("ui_test: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
