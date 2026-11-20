-- core.input (core story 44, CAP-14): a dependent's own controls in the game's Controls menu. Runs in the dependent's
-- own Lua state (each mod has its own copy); core's Lua state does the work (input/service.lua), reached through the
-- channel ops input-control, input-release, input-state and input-list. The validation below is shared: the service
-- runs the same checks on every request it gets, since any mod can call the channel.
--
--   control{ id, action, label, key, gamepad, near } -> true
--       Declares (or, with the same id, re-declares) a control. id: ^[a-z0-9][a-z0-9-]{0,31}$. action: the object path
--       of the mod's InputAction (1-256 bytes of letters, digits, _ . / -, starting with /). label: the row's name,
--       1-48 characters, no control characters. key: a keyboard or mouse key (slot 0), gamepad: a gamepad key (slot 1),
--       both key names as Unreal spells them (LeftAlt, Gamepad_FaceButton_Right). near: the mapping name of the game
--       row this one follows (Sprint), or nil for the end of General. The mapping name is "<mod.json id>:<id>". The
--       action is resolved and the row registered on core's next tick; a later failure is logged by core, not raised.
--   release(id) -> boolean    true: released (the row is hidden from the next open; the player's binding stays saved)
--   list() -> { { id, label, key, gamepad, active } ... }   this mod's controls; key and gamepad are the current keys
--   state(id) -> boolean      the action is triggered now (the key is held)
-- Errors are raised as "<core>.input.<fn>: <problem>". Game thread only, after connect.
local BASE = (...):gsub("%.input$", "")
local V = require(BASE .. ".version")
local json = require(BASE .. ".json")
local modid = require(BASE .. ".modid")

local NAME, LOWER = V.name, V.name:lower()
local I = {}
local API = {}
I.API = API

I.MAX_PER_MOD, I.MAX_TOTAL = 8, 64
I.MAX_ID, I.MAX_LABEL, I.MAX_ACTION, I.MAX_NEAR, I.MAX_KEY = 32, 48, 256, 64, 64
I.KEYS = { "id", "action", "label", "key", "gamepad", "near" }
local KEYSET = { id = true, action = true, label = true, key = true, gamepad = true, near = true }
local KEYLIST = "id, action, label, key, gamepad, near"

-- ---------------------------------------------------------------- shared validation (pure; no UE4SS)

function I.describe(v)
    local t = type(v)
    if t == "string" then
        local s = v:sub(1, 32):gsub("[^%w%p ]", "?")
        return string.format("'%s'%s", s, #v > 32 and "..." or "")
    end
    if t == "number" then return v ~= v and "NaN" or tostring(v) end
    return t
end
local describe = I.describe

-- checkId(id) -> nil | problem
function I.checkId(id)
    if type(id) ~= "string" then return "id must be a string, got " .. describe(id) end
    if #id < 1 or #id > I.MAX_ID or not id:match("^[a-z0-9][a-z0-9%-]*$") then
        return "id " .. describe(id) .. " must match ^[a-z0-9][a-z0-9-]{0,31}$"
    end
    return nil
end

local function hasControl(s) return s:find("[%z\1-\31\127]") ~= nil end

function I.checkLabel(label)
    if type(label) ~= "string" then return "label must be a string, got " .. describe(label) end
    if #label == 0 then return "label is empty" end
    local n = utf8.len(label)
    if not n then return "label is not valid UTF-8" end
    if n > I.MAX_LABEL then return string.format("label is %d characters, cap %d", n, I.MAX_LABEL) end
    if hasControl(label) then return "label has a control character" end
    return nil
end

function I.checkAction(path)
    if type(path) ~= "string" then return "action must be a string (an InputAction's object path), got " .. describe(path) end
    if #path < 2 or #path > I.MAX_ACTION or path:sub(1, 1) ~= "/" or path:find("[^%w_%./%-]") then
        return "action " .. describe(path) .. " must be an object path: 2 to 256 bytes of letters, digits, _ . / -, starting with /"
    end
    return nil
end

-- A key name's form (what FName gets); its class is checked by keyCheck.
function I.checkKeyName(what, name)
    if type(name) ~= "string" then return what .. " must be a string (a key name), got " .. describe(name) end
    if #name < 1 or #name > I.MAX_KEY or name:find("[^%w_]") then
        return what .. " " .. describe(name) .. " is not a key name (1 to 64 letters, digits or _)"
    end
    return nil
end

function I.checkNear(near)
    if near == nil then return nil end
    if type(near) ~= "string" then return "near must be a string or nil, got " .. describe(near) end
    local n = utf8.len(near)
    if #near == 0 or not n or n > I.MAX_NEAR or hasControl(near) then
        return "near " .. describe(near) .. " must be 1 to 64 characters without control characters"
    end
    return nil
end

-- The mapping name of a control: "<mod id>:<control id>" (the Enhanced Input row's name and the .sav key).
function I.mappingName(mod, id) return mod .. ":" .. id end

-- validate(opts, keyCheck) -> decl | nil, problem. keyCheck(name, want) -> nil | problem, where want is "key" (a
-- keyboard or mouse key) or "gamepad"; it runs only on names of the right form. decl is a plain copy (strings only).
function I.validate(opts, keyCheck)
    if type(opts) ~= "table" then return nil, "expected a table { " .. KEYLIST .. " }, got " .. describe(opts) end
    for k in pairs(opts) do
        if not KEYSET[k] then return nil, "unknown key " .. describe(k) .. " (" .. KEYLIST .. ")" end
    end
    local why = I.checkId(opts.id) or I.checkAction(opts.action) or I.checkLabel(opts.label)
        or I.checkKeyName("key", opts.key) or I.checkKeyName("gamepad", opts.gamepad) or I.checkNear(opts.near)
    if why then return nil, why end
    if keyCheck then
        why = keyCheck(opts.key, "key") or keyCheck(opts.gamepad, "gamepad")
        if why then return nil, why end
    end
    return { id = opts.id, action = opts.action, label = opts.label, key = opts.key, gamepad = opts.gamepad, near = opts.near }
end

-- ---------------------------------------------------------------- key classes (game thread: KismetInputLibrary)
I.KIL = "/Script/Engine.Default__KismetInputLibrary"

-- keyClass(name) -> "gamepad" | "mouse" | "keyboard" | "other", or nil when the name is no valid key. name must have
-- passed checkKeyName.
function I.keyClass(name)
    local K = StaticFindObject(I.KIL)
    if not K or not K:IsValid() then error("KismetInputLibrary is not loaded", 0) end
    local key = { KeyName = FName(name) }
    if K:Key_IsValid(key) ~= true then return nil end
    if K:Key_IsGamepadKey(key) == true then return "gamepad" end
    if K:Key_IsMouseButton(key) == true then return "mouse" end
    if K:Key_IsKeyboardKey(key) == true then return "keyboard" end
    return "other"
end

-- The keyCheck validate takes in the game: key must be a keyboard key or a mouse button, gamepad a gamepad key.
function I.keyCheck(name, want)
    local ok, cls = pcall(I.keyClass, name)
    if not ok then return want .. " " .. describe(name) .. " could not be checked (" .. tostring(cls):match("^[^\n]*") .. ")" end
    if cls == nil then return want .. " " .. describe(name) .. " is not a valid key" end
    if want == "gamepad" then
        if cls ~= "gamepad" then return "gamepad " .. describe(name) .. " is not a gamepad key" end
    elseif cls ~= "keyboard" and cls ~= "mouse" then
        return "key " .. describe(name) .. " is not a keyboard or mouse key"
    end
    return nil
end

-- ---------------------------------------------------------------- the dependent's API

local B = { bound = false } -- call, log, id (own mod.json id; nil when unknown), idWhy, unloadChained

local function fail(fn, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    error(LOWER .. ".input." .. fn .. ": " .. (ok and msg or tostring(fmt)), 0)
end

local PROBE = (1 << 53) - 1 -- a handle never issued: <Core>_Deref refuses it off the game thread, returns nil on it
local function offGameThread()
    local deref = _G[NAME .. "_Deref"]
    if type(deref) ~= "function" then return false end
    local ok, err = pcall(deref, PROBE)
    return not ok and tostring(err):find("off the game thread", 1, true) ~= nil
end

local function enter(fn)
    if not B.bound then fail(fn, "called before connect") end
    if offGameThread() then fail(fn, "called off the game thread") end
end

local function ownId(fn)
    if not B.id then fail(fn, "own mod id unknown (%s); add an \"id\" to this mod's mod.json", tostring(B.idWhy or "no mod.json")) end
    return B.id
end

-- A channel reply "err:<code> <message>" as the problem text (the message; the code when there is none).
local function problemOf(reply)
    local s = tostring(reply)
    local code, msg = s:match("^err:([%w%-]+) (.*)$")
    if code then return msg end
    code = s:match("^err:([%w%-]+)$")
    if code then return code end
    return s
end

local function request(fn, op, t, keys)
    local payload, why = json.encodeFlat(t, keys)
    if not payload then fail(fn, "request could not be encoded (%s)", tostring(why)) end
    local ok, reply = B.call(op, payload)
    if not ok then fail(fn, "%s", problemOf(reply)) end
    return reply
end

-- Releases every control of this mod when its Lua stops (chained in front of any OnUnload already set, once).
local function chainUnload()
    if B.unloadChained then return end
    B.unloadChained = true
    local id, call = B.id, B.call
    pcall(function()
        local prev = ModRef.OnUnload
        ModRef.OnUnload = function(...)
            pcall(function()
                local payload = json.encodeFlat({ mod = id, all = true }, { "mod", "all" })
                if payload then call("input-release", payload) end
            end)
            if type(prev) == "function" then return prev(...) end
        end
    end)
end

function API.control(opts, ...)
    if not B.bound then fail("control", "called before connect") end
    if select("#", ...) ~= 0 then fail("control", "expected 1 argument (a table), got %d", 1 + select("#", ...)) end
    local d, why = I.validate(opts, nil)
    if not d then fail("control", "%s", why) end
    enter("control")
    why = I.keyCheck(d.key, "key") or I.keyCheck(d.gamepad, "gamepad")
    if why then fail("control", "%s", why) end
    d.mod = ownId("control")
    request("control", "input-control", d, { "mod", "id", "action", "label", "key", "gamepad", "near" })
    chainUnload()
    return true
end

local function idArg(fn, id, n)
    if n ~= 1 then fail(fn, "expected 1 argument (id), got %d", n) end
    local why = I.checkId(id)
    if why then fail(fn, "%s", why) end
end

function API.release(...)
    local n, id = select("#", ...), ...
    if not B.bound then fail("release", "called before connect") end
    idArg("release", id, n)
    enter("release")
    local reply = request("release", "input-release", { mod = ownId("release"), id = id }, { "mod", "id" })
    return reply == "true"
end

function API.state(...)
    local n, id = select("#", ...), ...
    if not B.bound then fail("state", "called before connect") end
    idArg("state", id, n)
    enter("state")
    local reply = request("state", "input-state", { mod = ownId("state"), id = id }, { "mod", "id" })
    return reply == "true"
end

function API.list(...)
    if not B.bound then fail("list", "called before connect") end
    if select("#", ...) ~= 0 then fail("list", "takes no arguments") end
    enter("list")
    local reply = request("list", "input-list", { mod = ownId("list") }, { "mod" })
    local arr = json.decode(reply, { maxBytes = 65536, maxDepth = 3, maxValues = 1024, maxString = 256 })
    local out = {}
    if not json.isArray(arr) then fail("list", "core's reply is not a list") end
    for _, e in ipairs(arr) do
        if type(e) == "table" then
            out[#out + 1] = { id = e.id, label = e.label, key = e.key, gamepad = e.gamepad, active = e.active == true }
        end
    end
    return out
end

-- bind{ call, log, id, idWhy }: called by client.connect once core answers (id: this mod's mod.json id, or nil and why).
function I.bind(b)
    B = { bound = true, call = b.call, log = b.log, id = b.id, idWhy = b.idWhy }
end

-- For unit tests only.
function I._reset() B = { bound = false } end
I._problemOf = problemOf

-- modid is used by the service (the mod field of every request).
I.isModId = function(s) return type(s) == "string" and #s <= modid.MAX and modid.isNetId(s) end

return I
