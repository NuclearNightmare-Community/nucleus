-- Shared state and helpers of core's UI helpers (internal; not public API). One copy per Lua state: every dependent
-- requires its own, so elements, HUD paths and counters are per mod. Holds no UObject between calls: only strings,
-- numbers, weak-handle integers and plain tables (AGENTS.md, "Blueprint mods").
local BASE = (...):gsub("%.ui%.common$", "")
local V = require(BASE .. ".version")

local C = {}
C.NAME = V.name
C.LOWER = V.name:lower()
C.UI = C.LOWER .. ".ui"                -- "nucleus.ui": the prefix of every error message
C.TEXT_PKG = "/Game/Mods/" .. C.NAME .. "/WBP_" .. C.NAME .. "Text"
C.TEXT_SHORT = "WBP_" .. C.NAME .. "Text_C"
C.TEXT_CLASS = C.TEXT_PKG .. "." .. C.TEXT_SHORT
C.HUD_CLASS = "/Game/Graphics/Inventory/InventoryUI.InventoryUI_C"
C.HUD_SHORT = "InventoryUI_C"
-- Story 14: WBP_<Core>Panel (Border "Background" -> Overlay -> VerticalBox "VBox" / HorizontalBox "HBox").
C.PANEL_PKG = "/Game/Mods/" .. C.NAME .. "/WBP_" .. C.NAME .. "Panel"
C.PANEL_SHORT = "WBP_" .. C.NAME .. "Panel_C"
C.PANEL_CLASS = C.PANEL_PKG .. "." .. C.PANEL_SHORT
-- Story 15: WBP_<Core>Button (Button "Btn" -> TextBlock "Label"); its OnClicked calls <Core>_OnClicked on itself.
C.BUTTON_PKG = "/Game/Mods/" .. C.NAME .. "/WBP_" .. C.NAME .. "Button"
C.BUTTON_SHORT = "WBP_" .. C.NAME .. "Button_C"
C.BUTTON_CLASS = C.BUTTON_PKG .. "." .. C.BUTTON_SHORT
C.CLICK_FN = C.BUTTON_CLASS .. ":" .. C.NAME .. "_OnClicked"
C.JOURNAL_PKG = "/Game/Graphics/Journal/Journal"
C.JOURNAL_SHORT = "Journal_C"
C.JOURNAL_CLASS = C.JOURNAL_PKG .. "." .. C.JOURNAL_SHORT
-- Story 21 (Mod Manager story 2): the title-screen menu, the game's own column button class, and core's list, row and
-- window widgets (WBP_<Core>List: SizeBox "Box" -> Border "Background" -> ScrollBox "Scroll" -> VerticalBox "VBox";
-- WBP_<Core>Row: Border "Background" -> HorizontalBox "HBox"; WBP_<Core>Screen: Overlay "Root" -> Border "Backdrop"
-- (hit-testable) + CanvasPanel "Canvas").
C.MENU_PKG = "/Game/Graphics/MainMenu/MainMenu"
C.MENU_SHORT = "MainMenu_C"
C.MENU_CLASS = C.MENU_PKG .. "." .. C.MENU_SHORT
C.GAME_BUTTON_PKG = "/Game/Hyper/UI/Widgets/Generic_Elements/Buttons/UI_Button_Master"
C.GAME_BUTTON_SHORT = "UI_Button_Master_C"
C.GAME_BUTTON_CLASS = C.GAME_BUTTON_PKG .. "." .. C.GAME_BUTTON_SHORT
C.LIST_PKG = "/Game/Mods/" .. C.NAME .. "/WBP_" .. C.NAME .. "List"
C.LIST_SHORT = "WBP_" .. C.NAME .. "List_C"
C.LIST_CLASS = C.LIST_PKG .. "." .. C.LIST_SHORT
C.ROW_PKG = "/Game/Mods/" .. C.NAME .. "/WBP_" .. C.NAME .. "Row"
C.ROW_SHORT = "WBP_" .. C.NAME .. "Row_C"
C.ROW_CLASS = C.ROW_PKG .. "." .. C.ROW_SHORT
-- Core story 36 (0.15.1): the row's OnMouseEnter override calls <Core>_OnHover on itself (focus.lua hooks it).
C.HOVER_FN = C.ROW_CLASS .. ":" .. C.NAME .. "_OnHover"
-- Core story 38 (0.16.0): drag to reorder. The row's OnDragDetected override calls <Core>_OnDragStart and its
-- OnDragCancelled <Core>_OnDragCancel; the list's OnDrop override calls <Core>_OnDrop (reorder.lua hooks all three); the
-- window's OnKeyUp override calls <Core>_OnNavUp (focus.lua: releasing A / Enter drops a held row). WBP_<Core>Lift is a
-- dragged row's lifted copy (SizeBox "Box" -> Border "Background" -> HorizontalBox "HBox").
C.DRAGSTART_FN = C.ROW_CLASS .. ":" .. C.NAME .. "_OnDragStart"
C.DRAGCANCEL_FN = C.ROW_CLASS .. ":" .. C.NAME .. "_OnDragCancel"
C.DROP_FN = C.LIST_CLASS .. ":" .. C.NAME .. "_OnDrop"
C.LIFT_PKG = "/Game/Mods/" .. C.NAME .. "/WBP_" .. C.NAME .. "Lift"
C.LIFT_SHORT = "WBP_" .. C.NAME .. "Lift_C"
C.LIFT_CLASS = C.LIFT_PKG .. "." .. C.LIFT_SHORT
C.SCREEN_PKG = "/Game/Mods/" .. C.NAME .. "/WBP_" .. C.NAME .. "Screen"
C.SCREEN_SHORT = "WBP_" .. C.NAME .. "Screen_C"
C.SCREEN_CLASS = C.SCREEN_PKG .. "." .. C.SCREEN_SHORT
C.NAVUP_FN = C.SCREEN_CLASS .. ":" .. C.NAME .. "_OnNavUp" -- core story 38
-- Story 24 (core 0.8.0): WBP_<Core>Image (SizeBox "Box" -> Image "Img") and core's icon textures (Icons/T_<Key>).
C.IMAGE_PKG = "/Game/Mods/" .. C.NAME .. "/WBP_" .. C.NAME .. "Image"
C.IMAGE_SHORT = "WBP_" .. C.NAME .. "Image_C"
C.IMAGE_CLASS = C.IMAGE_PKG .. "." .. C.IMAGE_SHORT
C.ICON_DIR = "/Game/Mods/" .. C.NAME .. "/Icons"
-- Mod Manager story 4 (core 0.10.0): the controls. A checkbox is an icon-only WBP_<Core>Button (its click hook routes by
-- element kind); WBP_<Core>Choice (prev/next arrows calling <Core>_OnPrev / <Core>_OnNext) and WBP_<Core>Slider (Slider
-- "Bar" synced to EditableText "Box" inside the Blueprint; <Core>_OnSliderEnd at the end of a drag, <Core>_OnSliderCommit
-- when the box commits).
C.CHOICE_PKG = "/Game/Mods/" .. C.NAME .. "/WBP_" .. C.NAME .. "Choice"
C.CHOICE_SHORT = "WBP_" .. C.NAME .. "Choice_C"
C.CHOICE_CLASS = C.CHOICE_PKG .. "." .. C.CHOICE_SHORT
C.PREV_FN = C.CHOICE_CLASS .. ":" .. C.NAME .. "_OnPrev"
C.NEXT_FN = C.CHOICE_CLASS .. ":" .. C.NAME .. "_OnNext"
C.SLIDER_PKG = "/Game/Mods/" .. C.NAME .. "/WBP_" .. C.NAME .. "Slider"
C.SLIDER_SHORT = "WBP_" .. C.NAME .. "Slider_C"
C.SLIDER_CLASS = C.SLIDER_PKG .. "." .. C.SLIDER_SHORT
C.SLIDER_END_FN = C.SLIDER_CLASS .. ":" .. C.NAME .. "_OnSliderEnd"
C.SLIDER_COMMIT_FN = C.SLIDER_CLASS .. ":" .. C.NAME .. "_OnSliderCommit"
-- Core story 31 (UI-13, core 0.13.0): the game's own menu screens as hosts (game.lua), keyed by host name. The first
-- and only one is the create-server screen, built new on every open from the menu's START GAME; its elements go in its
-- root CanvasPanel (CanvasPanel_21). A later screen is one entry here plus its checks.
C.CREATESERVER_PKG = "/Game/Graphics/MainMenu/CreateServer"
C.CREATESERVER_SHORT = "CreateServer_C"
C.CREATESERVER_CLASS = C.CREATESERVER_PKG .. "." .. C.CREATESERVER_SHORT
C.GAME_SCREENS = { createServer = { pkg = C.CREATESERVER_PKG, short = C.CREATESERVER_SHORT, class = C.CREATESERVER_CLASS } }
C.GAME_SCREEN_NAMES = "createServer"        -- the game screens game.watch / game.isOpen take
-- Core story 44 (core 0.22.0): screens game.lua watches for core itself, never public hosts (no placement, no
-- game.watch): the Settings overlay (SettingsMenu_draggable_C, the widget the title screen's OPTIONS and the pause menu
-- add to the viewport; its SettingsMenu_C holds the Controls page), for core's input service (input/screen.lua). Keyed
-- like GAME_SCREENS; game.lua polls the union (WATCHED_SCREENS).
C.SETTINGS_PKG = "/Game/Graphics/MainMenu/SettingsMenu_draggable"
C.SETTINGS_SHORT = "SettingsMenu_draggable_C"
C.SETTINGS_CLASS = C.SETTINGS_PKG .. "." .. C.SETTINGS_SHORT
C.CORE_SCREENS = { settings = { pkg = C.SETTINGS_PKG, short = C.SETTINGS_SHORT, class = C.SETTINGS_CLASS } }
C.WATCHED_SCREENS = {}
for k, v in pairs(C.GAME_SCREENS) do C.WATCHED_SCREENS[k] = v end
for k, v in pairs(C.CORE_SCREENS) do C.WATCHED_SCREENS[k] = v end
C.HOST_NAMES = "createServer, hud, journal, menu, screen" -- the hosts an intent can name (place.lua)
-- Hosts with a cursor: buttons, lists and rows go there. createServer has one too (X.checkHost refuses only hud); this
-- text is kept as it was, since it appears in error texts that stay unchanged (story 31: add-only).
C.CURSOR_HOSTS = "journal, menu, screen"

-- An element's host key is "hud", "journal", "menu", or "screen#<window id>" for a window of the screen host: each
-- window is a host of its own (its own canvas, corner stacks and settling), all of kind "screen".
function C.hostKind(host)
    if type(host) == "string" and host:sub(1, 7) == "screen#" then return "screen" end
    return host
end
function C.windowHost(id) return "screen#" .. id end
-- Hosts whose elements default to the game's look (story 21) and that have a cursor; story 31: the game screens too.
function C.gameHost(host) local k = C.hostKind(host) return k == "menu" or k == "screen" or C.gameScreen(k) end
-- Core story 31: whether a host is one of the game's own screens (createServer).
function C.gameScreen(host) return type(host) == "string" and rawget(C.GAME_SCREENS, host) ~= nil end

-- Story 21: the windows of the screen host in this Lua state (screen.lua fills them; place.lua reads them to validate
-- an intent's screen = <window handle>). id -> { id, handle, open, ref (the window widget's weak handle), z, ... }.
C.windows = {}
C.windowOf = setmetatable({}, { __mode = "k" }) -- window handle table -> its record
-- Hosts whose elements are collapsed now (story 21: the menu while its opacity is 0 or another page shows).
C.hostHidden = {}

-- ESlateVisibility
C.VIS = { Visible = 0, Collapsed = 1, Hidden = 2, HitTestInvisible = 3, SelfHitTestInvisible = 4 }
C.VIS_NAME = { [0] = "Visible", [1] = "Collapsed", [2] = "Hidden", [3] = "HitTestInvisible", [4] = "SelfHitTestInvisible" }
function C.drawn(vis) return vis ~= 1 and vis ~= 2 end

-- Set by bind() when connect succeeds (client.lua, before onReady). Until then every public function refuses.
C.bound = false
C.mod = nil      -- the dependent's name as passed to connect{ mod = ... }
C.modTag = nil   -- the same, restricted to tag-safe characters
C.log = nil      -- the dependent's logger (log.new(mod)), shared with core.log
C.ref, C.deref, C.free, C.micros = nil, nil, nil, nil

-- Counters for tests and diagnostics (stats() in hud and text return copies).
-- overlapScheduled, overlapChecks: story 12's automatic checks scheduled (debug only) and overlap checks run.
C.stats = { uobjectCalls = 0, findAllCalls = 0, attachCreated = 0, attachReused = 0, handlesFreed = 0,
    overlapScheduled = 0, overlapChecks = 0 }

function C.bind(api)
    C.mod = tostring(api.mod)
    C.modTag = (C.mod:gsub("[^%w_%.%-]", "_"))
    C.log = api.log
    C.ref, C.deref, C.free, C.micros = api.ref, api.deref, api.free, api.micros
    C.bound = true
end

-- Whether the dependent's logger writes DEBUG lines (core.log.debugEnabled; it can change at any time). Lines that
-- only matter when debugging (the per-attach report) are not even built when it is off.
function C.debugOn() return C.log ~= nil and C.log.debugEnabled == true end

-- Raises a clean error: no position prefix, so the first line is exactly the message.
function C.fail(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    error(ok and msg or tostring(fmt), 0)
end

-- Off the game thread? The natives know the game thread (after the first engine tick); Lua doesn't. <Core>_Deref of
-- a handle that is in range but never issued is the cheapest call that refuses off the game thread and returns nil on
-- it, touching no UObject.
local PROBE = (1 << 53) - 1
local function offGameThread()
    local deref = _G[C.NAME .. "_Deref"]
    if type(deref) ~= "function" then return false end
    local ok, err = pcall(deref, PROBE)
    return not ok and tostring(err):find("off the game thread", 1, true) ~= nil
end
C.offGameThread = offGameThread

-- The boundary check of every public function: connected, and on the game thread. fn is e.g. "text.create".
function C.enter(fn)
    if not C.bound then C.fail("%s: %s called before connect", C.UI, fn) end
    if offGameThread() then C.fail("%s.%s called off the game thread", C.UI, fn) end
end

-- Describes a value for an error message without echoing much of it.
function C.describe(v)
    local t = type(v)
    if t == "string" then
        local s = v:sub(1, 32):gsub("[^%w%p ]", "?")
        return string.format("'%s'%s", s, #v > 32 and "..." or "")
    end
    if t == "number" then
        if v ~= v then return "NaN" end
        return tostring(v)
    end
    return t
end

-- ---- UObject helpers (call only inside the game-thread callback that found the object)
-- Hot-path helpers take their object as an argument instead of capturing it in a closure: a tick allocates as
-- little as possible, because every allocation brings the Lua collector closer to a step inside the tick.
local function isValidOf(o) return o:IsValid() end
function C.valid(o)
    if o == nil or type(o) ~= "userdata" then return false end
    local ok, yes = pcall(isValidOf, o)
    return ok and yes == true
end
function C.call0(o, name) return o[name](o) end   -- pcall(C.call0, o, "Fn") calls o:Fn() without a closure
function C.prop(o, name) return o[name] end
function C.found(path)
    if type(path) ~= "string" then return nil end
    local o = StaticFindObject(path)
    return C.valid(o) and o or nil
end
function C.pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end
function C.addr(o) return o:GetAddress() end
function C.count() C.stats.uobjectCalls = C.stats.uobjectCalls + 1 end

-- ---- tick profiler (diagnostic; off unless hud._profile(true)). Times named phases of one HUD tick with the
-- microsecond clock. Every probe is `local t = C.pt()` ... `C.pa("phase", t)`; with the profiler off C.pt() returns nil
-- and C.pa does nothing, so the cost when off is two function calls per probe.
C.prof = nil                     -- nil, or { cur = { phase -> us }, calls = { phase -> n } } while a tick runs
C.profOn = false
function C.pt() if C.prof then return C.micros() end end
function C.pa(key, t0)
    local p = C.prof
    if p and t0 then
        local dt = C.micros() - t0
        p.cur[key] = (p.cur[key] or 0) + dt
        p.calls[key] = (p.calls[key] or 0) + 1
        return dt
    end
end

-- Mod Manager story 4: > 0 while core's own click and control dispatch runs (inside a UE4SS script hook). Hooks are not
-- registered then (the poll does it) and core's own asset reads there use the cache only.
C.inDispatch = 0

-- Core story 37: a dependent's callback from a control's hook (checkbox, choice and slider onChange, button onClick),
-- under pcall with C.inDispatch raised, so whatever it does there reads cached assets and classes only and registers no
-- hook (X._inHook honours the flag; a miss is applied or attached on the next UI tick). Lowered in every case (a
-- throw included); returns pcall's ok, err.
function C.callDependent(fn, ...)
    C.inDispatch = C.inDispatch + 1
    local ok, err = pcall(fn, ...)
    C.inDispatch = C.inDispatch - 1
    return ok, err
end

-- Core story 27: fn(el, noClick) run (under pcall) when a click, a drag end or a commit reached one of this mod's elements, so a
-- window's keyboard focus model follows the mouse (focus.lua sets it). noClick (core story 39: a slider box's commit,
-- which Enter makes too): not a click input. nil: nothing.
C.onUse = nil
function C.used(el, noClick)
    local f = C.onUse
    if not f then return end
    local ok, err = pcall(f, el, noClick)
    if not ok then C.warnOnce("focus use", "moving the focus to a clicked element failed: %s", (tostring(err):match("^[^\n]*"))) end
end

-- Core story 39: a click on one of this mod's widgets that isn't an element (the menu entry, a window's BACK): the
-- input mode becomes "mouse" (focus.lua sets C.onClickInput). Never raises.
C.onClickInput = nil
function C.clickInput(id)
    local f = C.onClickInput
    if not f then return end
    local ok, err = pcall(f, id)
    if not ok then C.warnOnce("focus input", "the input mode after a click was not set: %s", (tostring(err):match("^[^\n]*"))) end
end

-- Core story 38: fn(list) run first by every change a dependent makes to a list (its order, a child added, removed,
-- shown or hidden, a row's lock, its reorderable flag, its removal): a drag or a carry in that list is cancelled before
-- the change (reorder.lua sets it). Never raises.
C.onListChange = nil
function C.listChanged(el)
    local f = C.onListChange
    if not f or not el then return end
    local ok, err = pcall(f, el)
    if not ok then C.warnOnce("reorder interrupt", "cancelling a reorder after a list change failed: %s", (tostring(err):match("^[^\n]*"))) end
end

-- One log line per key for the life of this Lua state.
local warned = {}
function C.warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    if C.log then C.log.warn(fmt, ...) end
end
function C.forgetWarning(key) warned[key] = nil end

-- ---- element registry (filled by text.lua, panel.lua, button.lua; read by place.lua)
-- An element is a plain table: kind ("text", "panel", "button"), id, place, style, visible, ref/path of its live
-- widget. A panel's children (story 14) have el.panel = the panel element and el.place = { inPanel = true } (no host:
-- every per-host loop skips them; their panel attaches and places them).
C.els = {}                                  -- id -> element (removed ones are dropped); ids are unique across kinds
C.order = {}                                -- elements in creation order (for corner stacking)
C.handleOf = setmetatable({}, { __mode = "k" })  -- handle table -> element
C.removedHandle = setmetatable({}, { __mode = "k" }) -- handle table -> id, after remove
C.removedKind = setmetatable({}, { __mode = "k" })   -- handle table -> kind, after remove
C.seq = 0

-- The host an element is drawn on: its own, or its container's (story 21: a row in a list holds texts two levels down).
-- el.panel is the element's container: a panel, a list or a row (story 21); containers have el.children.
function C.hostOf(el)
    local n = 0
    while el.panel and n < 4 do el = el.panel; n = n + 1 end
    return el.place.host
end
function C.isContainer(el) return el.children ~= nil end

local ARTICLE = { text = "a text element", panel = "a panel", button = "a button", list = "a list", row = "a row", image = "an image",
    checkbox = "a checkbox", choice = "a choice", slider = "a slider", -- Mod Manager story 4: the controls
    gchoice = "a choice" } -- core story 33: a choice with widget = "game" (an internal kind; public functions call it a choice)
C.ARTICLE = ARTICLE
-- Core story 33 (0.15.0): the kind a public function and an error name for an element's kind (internal kinds by the
-- public one they belong to).
local PUBLIC_KIND = { gchoice = "choice" }
function C.publicKind(kind) return PUBLIC_KIND[kind] or kind end
-- Core story 33: the game's picker (MultipleSelectBox_C) a game choice holds, and its two arrow handlers (next, prev).
C.MSB_CLASS = "/Game/Graphics/MainMenu/Components/MultipleSelectBox.MultipleSelectBox_C"
C.MSB_SHORT = "MultipleSelectBox_C"
C.MSB_NEXT_FN = C.MSB_CLASS .. ":BndEvt__MultipleSelectBox_Button_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
C.MSB_PREV_FN = C.MSB_CLASS .. ":BndEvt__MultipleSelectBox_Button_60_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature"
-- Story 21: functions that take a panel also take a list or a row (setStyle, setVisible, remove, isShown).
local CONTAINER = { panel = true, list = true, row = true }

-- The element behind a handle, or a clean error. fn is e.g. "text.set"; kind, when given, is the kind the function
-- takes ("text", "panel", "button", "list", "row", "image"); nil takes any element. "panel" also takes a list or a row.
function C.element(h, fn, kind)
    if type(h) ~= "table" then
        C.fail("%s.%s: expected %s handle, got %s", C.UI, fn, (kind == nil or kind == "text") and "an element" or ARTICLE[kind], C.describe(h))
    end
    local id = C.removedHandle[h]
    if id then C.fail("%s.%s: handle '%s' was removed", C.UI, C.removedKind[h] or "text", id) end
    local el = C.handleOf[h]
    if not el then
        if kind == nil or kind == "text" then C.fail("%s.%s: not an element handle (use the handle that text.create returned)", C.UI, fn) end
        C.fail("%s.%s: not %s handle (use the handle that %s.create returned)", C.UI, fn, ARTICLE[kind], kind)
    end
    if kind and el.kind ~= kind and not (kind == "panel" and CONTAINER[el.kind]) and not (kind == "choice" and el.kind == "gchoice") then
        C.fail("%s.%s: not %s handle ('%s' is %s)", C.UI, fn, ARTICLE[kind], el.id, ARTICLE[el.kind])
    end
    return el
end

return C
