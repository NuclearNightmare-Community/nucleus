-- Unit tests for core story 44 (core.input, CAP-14), outside the game: every validation row of the story's I/O matrix
-- (input.lua's shared checks, the key classes through a stubbed KismetInputLibrary), the mapping name and its object
-- name, the service's channel ops (malformed payloads, the caps of 8 per mod and 64 in all, an action declared under
-- another id, a re-declaration, release one / all / unknown, state and list), the dependent's API (before connect, off
-- the game thread, the error format, the requests it sends) and the Controls page's order (input/screen.lua plan).
-- The in-game proof is run.ps1 -Scenario controls / controls-restart / bad-input -Target vm.
-- Run from the repo root with any standalone Lua 5.3 or 5.4:  lua test/unit/input_test.lua  (here: MiKTeX's texlua)
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."

package.preload["nucleus.version"] = function() return { name = "Nucleus", version = "0.22.0", floor = "0.1.0" } end
table.insert(package.searchers, 2, function(name)
    local rest = name:match("^nucleus%.(.+)$")
    if not rest then return nil end
    local path = ROOT .. "/lua/pkg/" .. rest:gsub("%.", "/") .. ".lua"
    local f = io.open(path, "r")
    if not f then return "\n\tno file " .. path end
    f:close()
    return assert(loadfile(path)), path
end)

local pass, fail = 0, 0
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")) end
end
local function eq(got, want, name) ok(got == want, name, "got " .. tostring(got) .. ", want " .. tostring(want)) end
local function errOf(f, ...) local okC, e = pcall(f, ...) return not okC and tostring(e) or nil end
local function has(s, part) return type(s) == "string" and s:find(part, 1, true) ~= nil end

-- ---------------------------------------------------------------- stubbed engine: KismetInputLibrary, FName, threads
local KEYS = { LeftAlt = "keyboard", K = "keyboard", F9 = "keyboard", LeftMouseButton = "mouse", ThumbMouseButton = "mouse",
    Gamepad_FaceButton_Right = "gamepad", Gamepad_FaceButton_Top = "gamepad", Gamepad_Left2D = "gamepad", Touch1 = "other" }
local KIL = { valid = true }
function KIL:IsValid() return self.valid end
function KIL:Key_IsValid(k) return KEYS[k.KeyName] ~= nil end
function KIL:Key_IsGamepadKey(k) return KEYS[k.KeyName] == "gamepad" end
function KIL:Key_IsMouseButton(k) return KEYS[k.KeyName] == "mouse" end
function KIL:Key_IsKeyboardKey(k) return KEYS[k.KeyName] == "keyboard" end
_G.FName = function(s) return s end
_G.StaticFindObject = function(path) if path == "/Script/Engine.Default__KismetInputLibrary" then return KIL end return nil end
local OFF = false
_G.Nucleus_Deref = function() if OFF then error("Nucleus_Deref refused: called off the game thread", 0) end return nil end
_G.ModRef = { OnUnload = nil }

local I = require("nucleus.input")
local json = require("nucleus.json")

-- ---------------------------------------------------------------- shared validation (the matrix's bad-input row)
local GOOD = { id = "toggle", action = "/Game/Mods/ToggleSprint/IA_ToggleSprint.IA_ToggleSprint", label = "Toggle Sprint",
    key = "LeftAlt", gamepad = "Gamepad_FaceButton_Right", near = "Sprint" }
local function with(over)
    local t = {}
    for k, v in pairs(GOOD) do t[k] = v end
    for k, v in pairs(over) do if v == "<nil>" then t[k] = nil else t[k] = v end end
    return t
end
local function why(over, keyCheck)
    local d, w = I.validate(with(over), keyCheck)
    return d, w
end
do
    local d, w = I.validate(GOOD, I.keyCheck)
    ok(d ~= nil and w == nil, "validate: the matrix's declare row passes", w)
    eq(d and d.near, "Sprint", "validate: a plain copy keeps near")
    local function bad(over, part, name)
        local dd, ww = why(over, I.keyCheck)
        ok(dd == nil and has(ww, part), name, ww)
    end
    ok(select(2, I.validate(nil)) == "expected a table { id, action, label, key, gamepad, near }, got nil", "validate: nil")
    ok(has(select(2, I.validate("x")), "got 'x'"), "validate: a string")
    bad({ extra = 1 }, "unknown key 'extra' (id, action, label, key, gamepad, near)", "validate: unknown key")
    bad({ id = "<nil>" }, "id must be a string, got nil", "validate: id missing")
    bad({ id = 5 }, "id must be a string, got 5", "validate: id a number")
    bad({ id = "" }, "must match ^[a-z0-9][a-z0-9-]{0,31}$", "validate: id empty")
    bad({ id = "Toggle" }, "must match", "validate: id upper case")
    bad({ id = "-toggle" }, "must match", "validate: id starting with -")
    bad({ id = "a_b" }, "must match", "validate: id with _")
    bad({ id = "a:b" }, "must match", "validate: id with :")
    bad({ id = string.rep("a", 33) }, "must match", "validate: id 33 bytes")
    ok(why({ id = string.rep("a", 32) }, I.keyCheck) ~= nil, "validate: id 32 bytes is fine")
    ok(why({ id = "0-x" }, I.keyCheck) ~= nil, "validate: id 0-x is fine")
    bad({ label = "<nil>" }, "label must be a string, got nil", "validate: label missing")
    bad({ label = {} }, "label must be a string, got table", "validate: label a table")
    bad({ label = "" }, "label is empty", "validate: label empty")
    bad({ label = string.rep("x", 49) }, "label is 49 characters, cap 48", "validate: label 49 characters")
    ok(why({ label = string.rep("x", 48) }, I.keyCheck) ~= nil, "validate: label 48 characters is fine")
    ok(why({ label = string.rep("\xC3\xA9", 48) }, I.keyCheck) ~= nil, "validate: label of 48 two-byte characters (96 bytes) is fine")
    bad({ label = string.rep("\xC3\xA9", 49) }, "label is 49 characters", "validate: label of 49 two-byte characters")
    bad({ label = "a\nb" }, "label has a control character", "validate: label with a newline")
    bad({ label = "a\tb" }, "label has a control character", "validate: label with a tab")
    bad({ label = "a\0b" }, "label has a control character", "validate: label with NUL")
    bad({ label = "a\127" }, "label has a control character", "validate: label with DEL")
    bad({ label = "\xFF\xFE" }, "label is not valid UTF-8", "validate: label not UTF-8")
    bad({ action = "<nil>" }, "action must be a string", "validate: action missing")
    bad({ action = 3 }, "action must be a string", "validate: action a number")
    bad({ action = "Game/IA.IA" }, "must be an object path", "validate: action without a leading /")
    bad({ action = "/" }, "must be an object path", "validate: action /")
    bad({ action = "/Game/IA.IA:Sub" }, "must be an object path", "validate: action with :")
    bad({ action = "/Game/I A.IA" }, "must be an object path", "validate: action with a space")
    bad({ action = "/Game/..\\x" }, "must be an object path", "validate: action with a backslash")
    bad({ action = "/" .. string.rep("a", 256) }, "must be an object path", "validate: action 257 bytes")
    ok(why({ action = "/" .. string.rep("a", 255) }, I.keyCheck) ~= nil, "validate: action 256 bytes is fine")
    bad({ key = "<nil>" }, "key must be a string (a key name), got nil", "validate: key missing")
    bad({ key = 7 }, "key must be a string (a key name), got 7", "validate: key a number")
    bad({ key = "" }, "is not a key name", "validate: key empty")
    bad({ key = "Left Alt" }, "is not a key name", "validate: key with a space")
    bad({ key = string.rep("A", 65) }, "is not a key name", "validate: key 65 bytes")
    bad({ key = "NoSuchKey" }, "key 'NoSuchKey' is not a valid key", "validate: key unknown to the engine")
    bad({ key = "Gamepad_FaceButton_Top" }, "key 'Gamepad_FaceButton_Top' is not a keyboard or mouse key", "validate: key a gamepad key")
    bad({ key = "Touch1" }, "is not a keyboard or mouse key", "validate: key a touch key")
    ok(why({ key = "LeftMouseButton" }, I.keyCheck) ~= nil, "validate: key a mouse button is fine")
    bad({ gamepad = "<nil>" }, "gamepad must be a string (a key name), got nil", "validate: gamepad missing")
    bad({ gamepad = true }, "gamepad must be a string", "validate: gamepad a boolean")
    bad({ gamepad = "K" }, "gamepad 'K' is not a gamepad key", "validate: gamepad a keyboard key")
    bad({ gamepad = "LeftMouseButton" }, "is not a gamepad key", "validate: gamepad a mouse button")
    bad({ gamepad = "Gamepad_Nope" }, "gamepad 'Gamepad_Nope' is not a valid key", "validate: gamepad unknown to the engine")
    ok(why({ gamepad = "Gamepad_Left2D" }, I.keyCheck) ~= nil, "validate: gamepad an axis is a gamepad key")
    ok(why({ near = "<nil>" }, I.keyCheck) ~= nil, "validate: near nil is fine (the end of General)")
    bad({ near = 1 }, "near must be a string or nil, got 1", "validate: near a number")
    bad({ near = "" }, "must be 1 to 64 characters", "validate: near empty")
    bad({ near = string.rep("n", 65) }, "must be 1 to 64 characters", "validate: near 65 characters")
    bad({ near = "a\nb" }, "must be 1 to 64 characters without control characters", "validate: near with a newline")
    ok(why({ near = "Hide HUD" }, I.keyCheck) ~= nil, "validate: near with a space is fine")
    -- the class check is skipped without keyCheck (the dependent checks forms first, classes on the game thread)
    ok(why({ key = "NoSuchKey" }, nil) ~= nil, "validate: no keyCheck, no class check")
    -- KismetInputLibrary missing: a clean problem, no raise
    KIL.valid = false
    local _, w = why({}, I.keyCheck)
    ok(has(w, "could not be checked (KismetInputLibrary is not loaded)"), "keyCheck: the library missing is a problem", w)
    KIL.valid = true
end
eq(I.mappingName("nuclearnightmare-community.toggle-sprint", "toggle"), "nuclearnightmare-community.toggle-sprint:toggle", "mappingName: <mod id>:<id>")
eq(I.mappingName("skeltest", "gone"), "skeltest:gone", "mappingName: a legacy bare id")
ok(I.isModId("skeltest") and I.isModId("a.b") and not I.isModId("A.b") and not I.isModId("a b") and not I.isModId(5) and not I.isModId(string.rep("a", 65)),
    "isModId: normalized or legacy bare ids only")

-- ---------------------------------------------------------------- the service's ops
local SV = require("nucleus.input.service")
local LOG = {}
local log = { info = function(f, ...) LOG[#LOG + 1] = "INFO " .. string.format(f, ...) end,
    warn = function(f, ...) LOG[#LOG + 1] = "WARN " .. string.format(f, ...) end,
    error = function(f, ...) LOG[#LOG + 1] = "ERROR " .. string.format(f, ...) end }
SV.init({ log = log, ref = function() return 1 end, deref = function() return nil end, free = function() end, now = function() return 0 end })
local function ctl(mod, over)
    local t = with(over or {})
    t.mod = mod
    return SV.op("input-control", json.encodeFlat(t, { "mod", "id", "action", "label", "key", "gamepad", "near" }))
end
local function op(name, t, keys) return SV.op(name, json.encodeFlat(t, keys)) end
do
    SV._reset()
    eq(SV.op("input-control", nil), "err:bad-request input-control needs a JSON object payload", "op: no payload")
    eq(SV.op("input-control", ""), "err:bad-request input-control needs a JSON object payload", "op: empty payload")
    ok(has(SV.op("input-control", "{"), "err:bad-request payload: "), "op: not JSON")
    eq(SV.op("input-control", "[]"), "err:bad-request payload must be a JSON object", "op: an array")
    eq(SV.op("input-control", "5"), "err:bad-request payload must be a JSON object", "op: a number")
    ok(has(SV.op("input-control", '{"mod":"a","x":{"y":1}}'), "err:bad-request payload: "), "op: a nested object (depth 2)")
    ok(has(SV.op("input-control", '{"mod":"a","mod":"b"}'), "err:bad-request payload: "), "op: a duplicate key")
    ok(has(SV.op("input-control", '{"id":"x"}'), "err:bad-request mod must be a mod id"), "op: no mod")
    ok(has(SV.op("input-control", '{"mod":"Bad Mod"}'), "err:bad-request mod must be a mod id"), "op: a bad mod")
    ok(has(SV.op("input-control", '{"mod":"a.b","id":"x","near":null}'), "err:bad-request "), "op: near null")
    ok(has(SV.op("input-nope", '{"mod":"a.b"}'), "err:bad-request unknown input op"), "op: unknown op")
    ok(has(SV.op("input-control", '{"mod":"' .. string.rep("a", 600) .. '"}'), "err:bad-request payload: "), "op: a string over the cap")
    ok(has(SV.op("input-control", '{"mod":"a.b","id":"toggle","extra":"1"}'), "err:bad-request unknown key 'extra'"), "control: unknown field")
    ok(has(ctl("a.b", { key = "Gamepad_FaceButton_Top" }), "err:bad-request key 'Gamepad_FaceButton_Top' is not a keyboard or mouse key"), "control: the service checks key classes too")
    eq(#SV._S.order, 0, "control: nothing registered by refused requests")
    -- declare, then the same again, then a change
    eq(ctl("a.b"), "ok:declared", "control: the declare row")
    eq(#SV._S.order, 1, "control: one entry")
    local e = SV._S.reg["a.b:toggle"]
    ok(e and e.status == "pending" and e.tryNow == true and SV._S.window ~= nil, "control: pending, tried on the next tick (window open)")
    eq(SV.rowInfo("a.b:toggle"), nil, "rowInfo: nil while pending")
    eq(ctl("a.b"), "ok:unchanged", "control: the same declaration again is unchanged")
    local g = SV.gen()
    e.status, e.built, e.imc, e.nearFound = "active", true, SV.imcPath("a.b:toggle"), true
    local inf = SV.rowInfo("a.b:toggle")
    ok(inf and inf.near == "Sprint" and inf.nearFound == true and inf.order == e.seq, "rowInfo: an active control's near and order")
    eq(ctl("a.b", { label = "Toggle Run" }), "ok:declared", "control: a changed declaration replaces the earlier one")
    ok(SV._S.reg["a.b:toggle"].label == "Toggle Run" and SV._S.reg["a.b:toggle"].status == "pending", "control: re-declared, pending again")
    eq(#SV._S.teardown, 1, "control: the built context is queued for release before the rebuild")
    eq(SV._S.teardown[1].imc, "/Engine/Transient.IMC_a_2Eb_3Atoggle", "control: the context's path")
    ok(SV.gen() > g, "control: the registry generation moved")
    eq(#SV._S.order, 1, "control: still one entry")
    -- the action declared under another id
    ok(has(ctl("a.b", { id = "other" }), "err:conflict action '/Game/Mods/ToggleSprint/IA_Toggl'... is already declared as 'a.b:toggle'"), "control: the action under another id")
    ok(has(ctl("c.d", { id = "toggle" }), "err:conflict "), "control: the action under another mod's id")
    -- caps: 8 per mod
    SV._reset()
    for i = 1, 8 do eq(ctl("a.b", { id = "c" .. i, action = "/Game/A/IA_" .. i .. ".IA_" .. i }), "ok:declared", "cap: control " .. i .. " of a.b") end
    ok(has(ctl("a.b", { id = "c9", action = "/Game/A/IA_9.IA_9" }), "err:cap a.b already has 8 controls (cap 8 per mod)"), "cap: a ninth control of one mod")
    eq(ctl("a.b", { id = "c3", action = "/Game/A/IA_3.IA_3", label = "Again" }), "ok:declared", "cap: re-declaring one of the eight is fine")
    -- caps: 64 in all
    SV._reset()
    local n = 0
    for m = 1, 8 do
        for i = 1, 8 do
            n = n + 1
            ctl("m" .. m .. ".x", { id = "c" .. i, action = "/Game/A/IA_" .. n .. ".IA_" .. n })
        end
    end
    eq(#SV._S.order, 64, "cap: 64 controls from eight mods")
    ok(has(ctl("m9.x", { id = "c1", action = "/Game/A/IA_65.IA_65" }), "err:cap 64 controls in all (cap 64)"), "cap: the 65th control")
    -- release one, all, unknown
    SV._reset()
    ctl("a.b"); ctl("a.b", { id = "two", action = "/Game/A/IA_2.IA_2" }); ctl("c.d", { id = "three", action = "/Game/A/IA_3.IA_3" })
    SV._S.reg["a.b:toggle"].built, SV._S.reg["a.b:toggle"].imc = true, SV.imcPath("a.b:toggle")
    eq(op("input-release", { mod = "a.b", id = "nope" }, { "mod", "id" }), "ok:false", "release: an unknown id is false")
    eq(op("input-release", { mod = "a.b", id = "toggle" }, { "mod", "id" }), "ok:true", "release: one control")
    eq(op("input-release", { mod = "a.b", id = "toggle" }, { "mod", "id" }), "ok:false", "release: the same again is false")
    eq(#SV._S.teardown, 1, "release: a built control's context is queued for the tick")
    ok(has(op("input-release", { mod = "a.b", id = "Bad" }, { "mod", "id" }), "err:bad-request id 'Bad' must match"), "release: a bad id")
    ok(has(op("input-release", { mod = "a.b" }, { "mod" }), "err:bad-request id must be a string"), "release: no id")
    ok(has(op("input-release", { mod = "a.b", all = false }, { "mod", "all" }), "err:bad-request all must be true"), "release: all false")
    ok(has(op("input-release", { mod = "a.b", all = true, id = "two" }, { "mod", "all", "id" }), "err:bad-request all must be true and comes without id"), "release: all with an id")
    eq(op("input-release", { mod = "a.b", all = true }, { "mod", "all" }), "ok:true", "release: all of a mod")
    eq(#SV._S.order, 1, "release: the other mod's control stays")
    eq(op("input-release", { mod = "a.b", all = true }, { "mod", "all" }), "ok:false", "release: all again is false")
    -- state
    ok(has(op("input-state", { mod = "c.d", id = "nope" }, { "mod", "id" }), "err:unknown-control unknown control 'nope'"), "state: an unknown id")
    ok(has(op("input-state", { mod = "c.d", id = 5 }, { "mod", "id" }), "err:bad-request id must be a string, got 5"), "state: a number id")
    eq(op("input-state", { mod = "c.d", id = "three" }, { "mod", "id" }), "ok:false", "state: a pending control is not triggered")
    ok(has(op("input-state", { mod = "c.d", id = "three", x = 1 }, { "mod", "id", "x" }), "err:bad-request unknown key 'x'"), "state: an unknown field")
    -- list (pending: the declared keys)
    local r = op("input-list", { mod = "c.d" }, { "mod" })
    ok(r:sub(1, 3) == "ok:", "list: ok", r)
    local arr = json.decode(r:sub(4))
    ok(json.isArray(arr) and #arr == 1 and arr[1].id == "three" and arr[1].key == "LeftAlt" and arr[1].gamepad == "Gamepad_FaceButton_Right" and arr[1].active == false,
        "list: one pending control with its declared keys", r)
    eq(op("input-list", { mod = "a.b" }, { "mod" }), "ok:[]", "list: a mod with none")
    ok(has(op("input-list", { mod = "a.b", id = "x" }, { "mod", "id" }), "err:bad-request unknown key 'id'"), "list: an unknown field")
end
-- object names: one-to-one, letters and digits only
do
    eq(SV.encode("a.b:c-d"), "a_2Eb_3Ac_2Dd", "encode: . : - as _<hex>")
    ok(SV.encode("x.a-b:c") ~= SV.encode("x.a:b-c"), "encode: one-to-one")
    ok(not SV.encode("nuclearnightmare-community.toggle-sprint:toggle"):find("[^%w_]"), "encode: only letters, digits and _")
end

-- ---------------------------------------------------------------- the dependent's API
do
    I._reset()
    local A = I.API
    eq(errOf(A.control, GOOD), "nucleus.input.control: called before connect", "api: control before connect")
    eq(errOf(A.release, "toggle"), "nucleus.input.release: called before connect", "api: release before connect")
    eq(errOf(A.state, "toggle"), "nucleus.input.state: called before connect", "api: state before connect")
    eq(errOf(A.list), "nucleus.input.list: called before connect", "api: list before connect")
    local SENT = {}
    local REPLY = { ok = true, text = "declared" }
    I.bind({ call = function(o, p) SENT[#SENT + 1] = { op = o, payload = p } return REPLY.ok, REPLY.text end, log = log, id = "a.b" })
    eq(A.control(GOOD), true, "api: control returns true")
    eq(SENT[1].op, "input-control", "api: control sends input-control")
    local t = json.decode(SENT[1].payload)
    ok(t.mod == "a.b" and t.id == "toggle" and t.near == "Sprint" and t.key == "LeftAlt", "api: control's payload carries the mod id and the fields", SENT[1].payload)
    ok(type(ModRef.OnUnload) == "function", "api: the first control chains OnUnload")
    local prevCalled = 0
    local chained = ModRef.OnUnload
    eq(A.control(with({ near = "<nil>" })), true, "api: control without near")
    ok(ModRef.OnUnload == chained, "api: OnUnload chained once")
    eq(errOf(A.control, GOOD, 1), "nucleus.input.control: expected 1 argument (a table), got 2", "api: control with two arguments")
    eq(errOf(A.control, with({ id = "Bad" })), "nucleus.input.control: id 'Bad' must match ^[a-z0-9][a-z0-9-]{0,31}$", "api: control with a bad id")
    eq(errOf(A.control, with({ gamepad = "K" })), "nucleus.input.control: gamepad 'K' is not a gamepad key", "api: control with a keyboard gamepad key")
    REPLY.ok, REPLY.text = false, "err:cap a.b already has 8 controls (cap 8 per mod)"
    eq(errOf(A.control, GOOD), "nucleus.input.control: a.b already has 8 controls (cap 8 per mod)", "api: a refusal becomes the error")
    REPLY.ok, REPLY.text = false, "err:not-ready loading"
    eq(errOf(A.control, GOOD), "nucleus.input.control: loading", "api: core not ready")
    REPLY.ok, REPLY.text = false, "channel class not loaded"
    eq(errOf(A.control, GOOD), "nucleus.input.control: channel class not loaded", "api: no channel")
    OFF = true
    eq(errOf(A.control, GOOD), "nucleus.input.control: called off the game thread", "api: control off the game thread")
    eq(errOf(A.release, "toggle"), "nucleus.input.release: called off the game thread", "api: release off the game thread")
    eq(errOf(A.state, "toggle"), "nucleus.input.state: called off the game thread", "api: state off the game thread")
    eq(errOf(A.list), "nucleus.input.list: called off the game thread", "api: list off the game thread")
    OFF = false
    REPLY.ok, REPLY.text = true, "true"
    eq(A.release("toggle"), true, "api: release true")
    REPLY.text = "false"
    eq(A.release("toggle"), false, "api: release false")
    eq(errOf(A.release), "nucleus.input.release: expected 1 argument (id), got 0", "api: release()")
    eq(errOf(A.release, "a", "b"), "nucleus.input.release: expected 1 argument (id), got 2", "api: release with two")
    eq(errOf(A.release, 5), "nucleus.input.release: id must be a string, got 5", "api: release(5)")
    eq(errOf(A.state, nil), "nucleus.input.state: id must be a string, got nil", "api: state(nil)")
    REPLY.ok, REPLY.text = false, "err:unknown-control unknown control 'nope' (declare it with control first)"
    eq(errOf(A.state, "nope"), "nucleus.input.state: unknown control 'nope' (declare it with control first)", "api: state of an unknown id raises")
    REPLY.ok, REPLY.text = true, "true"
    eq(A.state("toggle"), true, "api: state true")
    REPLY.text = '[{"id":"toggle","label":"Toggle Sprint","key":"K","gamepad":"Gamepad_FaceButton_Top","active":true}]'
    local l = A.list()
    ok(#l == 1 and l[1].id == "toggle" and l[1].key == "K" and l[1].gamepad == "Gamepad_FaceButton_Top" and l[1].active == true, "api: list parses core's reply")
    eq(errOf(A.list, 1), "nucleus.input.list: takes no arguments", "api: list(1)")
    REPLY.text = "{}"
    eq(errOf(A.list), "nucleus.input.list: core's reply is not a list", "api: list with a bad reply")
    -- the unload chain sends input-release all
    local n0 = #SENT
    ModRef.OnUnload()
    local last = SENT[#SENT]
    ok(#SENT == n0 + 1 and last.op == "input-release" and json.decode(last.payload).all == true and json.decode(last.payload).mod == "a.b", "api: OnUnload releases all of this mod")
    -- no own id
    I._reset()
    I.bind({ call = function() return true, "x" end, log = log, id = nil, idWhy = "no Mods/X/mod.json" })
    eq(errOf(A.control, GOOD), "nucleus.input.control: own mod id unknown (no Mods/X/mod.json); add an \"id\" to this mod's mod.json", "api: no mod id")
    eq(prevCalled, 0, "api: (no stray OnUnload call)")
end

-- ---------------------------------------------------------------- the Controls page's order (input/screen.lua)
do
    local SC = require("nucleus.input.screen")
    local INFO = { ["a:x"] = { order = 1, near = "Sprint", nearFound = true }, ["a:y"] = { order = 2, near = "Sprint", nearFound = true },
        ["a:z"] = { order = 3, near = "Gone", nearFound = false } }
    local function info(name) return INFO[name] end
    local function kids(list)
        local out = {}
        for _, n in ipairs(list) do out[#out + 1] = { name = n, core = INFO[n] ~= nil } end
        return out
    end
    local function order(list)
        local c = kids(list)
        local want, first = SC.plan(c, info)
        if not want then return "none", first end
        local names = {}
        for _, i in ipairs(want) do names[#names + 1] = list[i] end
        return table.concat(names, ","), first
    end
    local o, f = order({ "", "a:x", "Jump", "Sprint", "Crouch" })
    eq(o, ",Jump,Sprint,a:x,Crouch", "plan: a core row at the top moves after Sprint")
    eq(f, 2, "plan: from the second child")
    o, f = order({ "", "Jump", "Sprint", "a:x", "Crouch" })
    eq(f, nil, "plan: already after Sprint: nothing to move")
    o = order({ "", "a:y", "Jump", "a:x", "Sprint" })
    eq(o, ",Jump,Sprint,a:x,a:y", "plan: two after one row keep their declaration order")
    o = order({ "", "a:z", "Interact", "Ping" })
    eq(o, ",Interact,Ping,a:z", "plan: near missing: the end of the box")
    o = order({ "", "Jump", "dead:row", "Sprint" })
    eq(o, "none", "plan: no core row, no plan (a dead row is a game child)")
    o = order({ "", "a:x", "dead:row", "Sprint", "Crouch" })
    eq(o, ",dead:row,Sprint,a:x,Crouch", "plan: a dead row stays where it was among the game's")
end

print(string.format("input_test: %d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
