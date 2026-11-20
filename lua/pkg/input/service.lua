-- core.input's owner (core story 44, CAP-14), in core's own Lua state: the registry of every dependent's declared
-- controls, the channel ops input-control, input-release, input-state and input-list (main.lua routes them here), and
-- the work on core's own game-thread tick. Players bind the controls in the game's Controls menu like any game control:
-- the game draws the row, captures the key and saves it (MapPlayerKey, ApplySettings, SaveSettings into the engine's
-- EnhancedInputUserSettings.sav); core never stores a key itself and never changes a game control.
--
-- Per control (mapping name "<mod id>:<control id>", input.lua):
--   - the action is resolved on the tick, never inside a call: StaticFindObject, then AssetRegistryHelpers:GetAsset for
--     a /Game path. First at the next tick after the declaration; when that fails, again at each map load and each
--     open of the Settings overlay, with one WARN after the first failed retry. Not an InputAction: one ERROR, and the
--     control stays inactive.
--   - core gives the action a PlayerMappableKeySettings (outer: the action; Name = the mapping name, DisplayName = the
--     label, DisplayCategory = the category of the near row, else General with one WARN per control per session), and
--     builds one mapping context /Engine/Transient.IMC_<encoded name> (rooted): mapping 1 the keyboard or mouse key
--     (slot 0), mapping 2 the gamepad key (slot 1).
--   - RegisterInputMappingContext once (the player's saved keys apply to the row), then AddMappingContext at priority 0
--     (as IMC_Default), and again after every map load once the player controller exists: polled for up to 10 s, then
--     one WARN. A key a game control uses is allowed: both fire, as with the game's own shared keys.
--   - release (or the dependent's Lua stopping): RemoveMappingContext and UnregisterInputMappingContext on the next tick.
--     The player's row stays in the profile and the .sav; the Controls page pass (input/screen.lua) hides it.
-- Holds no UObject between calls: paths, plus weak handles (core's natives) of the player controller and the input
-- subsystem.
local BASE = (...):gsub("%.input%.service$", "")
local V = require(BASE .. ".version")
local I = require(BASE .. ".input")
local json = require(BASE .. ".json")

local NAME = V.name
local M = {}

M.WINDOW_S = 10          -- how long after a map load (or a declaration, or a screen open) the controller is waited for
M.TICK_MS = 250
M.CAPS = { maxBytes = 4096, maxDepth = 1, maxValues = 16, maxString = 512 }
M.SUB_CLASS = "/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem"
M.IA_CLASS = "/Script/EnhancedInput.InputAction"
M.IMC_CLASS = "/Script/EnhancedInput.InputMappingContext"
M.PMKS_CLASS = "/Script/EnhancedInput.PlayerMappableKeySettings"
M.TRANSIENT = "/Engine/Transient"
local SBL = "/Script/Engine.Default__SubsystemBlueprintLibrary"
local ARH = "/Script/AssetRegistry.Default__AssetRegistryHelpers"
local KSL_ISVALID, KSL_CDO = "/Script/Engine.KismetSystemLibrary:IsValid", "/Script/Engine.Default__KismetSystemLibrary"
local OPTS = { bIgnoreAllPressedKeysUntilRelease = true, bForceImmediately = true, bNotifyUserSettings = false }
local CATSET = { General = true, Movement = true, Inventory = true, Vehicle = true, Imposter = true }
local TRIGGERED = 1      -- ETriggerEvent::Triggered

-- reg: mapping name -> entry; order: mapping names in declaration order; gen: +1 on every change (the page pass
-- reruns); teardown: { imc = path } queued for the tick; window: { deadline, why } while the tick waits for the
-- player controller.
local S = { reg = {}, order = {}, gen = 0, seq = 0, teardown = {}, window = nil, pcH = nil, subH = nil, pcNext = 0, warned = {} }
local E = { log = nil, ref = nil, deref = nil, free = nil, now = os.clock }

-- Seams (the unit tests replace them).
M._keyCheck = function(name, want) return I.keyCheck(name, want) end

local function firstLine(e) return (tostring(e):match("^[^\n]*")) end
local function try(f, ...) local ok, v = pcall(f, ...) if ok then return v end return nil end
local function U(x)
    if type(x) == "userdata" then
        local ok, v = pcall(function() return x:get() end)
        if ok and v ~= nil then return v end
    end
    return x
end
local function valid(o)
    if type(o) ~= "userdata" then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
-- Valid and not marked as garbage (FindAllOf keeps returning destroyed actors until the next GC; AGENTS.md).
local function alive(o)
    if not valid(o) then return false end
    local ok, r = pcall(function() return StaticFindObject(KSL_ISVALID)(StaticFindObject(KSL_CDO), o) end)
    return ok and r == true
end
local function found(path)
    local o = StaticFindObject(path)
    return valid(o) and o or nil
end
local function quote(s) return (tostring(s):sub(1, 64):gsub("[^%w%p ]", "?")) end
local function warnOnce(key, fmt, ...)
    if S.warned[key] then return end
    S.warned[key] = true
    if E.log then E.log.warn(fmt, ...) end
end

-- An object name for the mapping name: letters and digits kept, every other byte as _<hex> (one-to-one: the mapping
-- name has no _).
function M.encode(name) return (name:gsub("[^%w]", function(c) return string.format("_%02X", c:byte()) end)) end
function M.imcPath(name) return M.TRANSIENT .. ".IMC_" .. M.encode(name) end

-- ---------------------------------------------------------------- the player controller and the input subsystem

local function livePc()
    local p = S.pcH and try(E.deref, S.pcH)
    if p then return p end
    if S.pcH then pcall(E.free, S.pcH); S.pcH = nil end
    local t = E.now()
    if t < S.pcNext then return nil end
    S.pcNext = t + 1
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if alive(c) and try(function() return c:IsLocalPlayerController() end) == true then
            local okR, h = pcall(E.ref, c)
            if okR then S.pcH = h end
            return c
        end
    end
    return nil
end

local function liveSub()
    local s = S.subH and try(E.deref, S.subH)
    if s then return s end
    if S.subH then pcall(E.free, S.subH); S.subH = nil end
    local pc = livePc()
    if not pc then return nil end
    local cls, sbl = found(M.SUB_CLASS), found(SBL)
    if not (cls and sbl) then return nil end
    s = try(function() return sbl:GetLocalPlayerSubSystemFromPlayerController(pc, cls) end)
    if not valid(s) then return nil end
    local okR, h = pcall(E.ref, s)
    if okR then S.subH = h end
    return s
end

local function settingsOf(sub)
    local us = try(function() return sub:GetUserSettings() end)
    return valid(us) and us or nil
end

-- The profile's rows: calls fn(name, row) for each (row: the FKeyMappingRow).
local function eachRow(us, fn)
    local p = try(function() return us:GetActiveKeyProfile() end)
    if not valid(p) then return false end
    local ok = pcall(function()
        p.PlayerMappedKeys:ForEach(function(k, v)
            local name = try(function() return U(k):ToString() end)
            if name then fn(name, U(v)) end
        end)
    end)
    return ok
end

-- The category of the near row (a game row's DisplayCategory, one of the page's five boxes), or nil.
local function categoryOf(us, near)
    if not near then return nil end
    local cat
    eachRow(us, function(name, row)
        if cat or name ~= near then return end
        pcall(function()
            row.Mappings:ForEach(function(e)
                if cat then return end
                local c = try(function() return U(e).DisplayCategory:ToString() end)
                if c and CATSET[c] then cat = c end
            end)
        end)
    end)
    return cat
end

-- The current keys of a control's row: slot 0, slot 1 (nil when the row has none).
local function rowKeys(us, mapping)
    local k0, k1
    eachRow(us, function(name, row)
        if name ~= mapping then return end
        pcall(function()
            row.Mappings:ForEach(function(e)
                local m = U(e)
                local slot = try(function() return m.Slot end)
                local key = try(function() return m.CurrentKey.KeyName:ToString() end)
                if slot == 0 then k0 = key elseif slot == 1 then k1 = key end
            end)
        end)
    end)
    return k0, k1
end

-- ---------------------------------------------------------------- activation (the tick)

local function openWindow(why)
    local deadline = E.now() + M.WINDOW_S
    if S.window then
        if deadline > S.window.deadline then S.window.deadline = deadline end
        return
    end
    S.window = { deadline = deadline, why = why }
end

local function resolve(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    if path:sub(1, 6) ~= "/Game/" then return nil end
    local pkg, asset = path:match("^(.+)%.([^%./]+)$")
    if not pkg then return nil end
    local helpers = found(ARH)
    if not helpers then return nil end
    o = try(function() return helpers:GetAsset({ PackageName = FName(pkg), AssetName = FName(asset) }) end)
    return valid(o) and o or nil
end

local function isA(o, path)
    local cls = found(path)
    if not cls then return false end
    return try(function() return o:IsA(cls) end) == true
end

local function flags()
    local f = 0
    pcall(function() local F = rawget(_G, "EObjectFlags") f = F.RF_Public | F.RF_MarkAsRootSet end)
    return f
end

local function activate(e, sub, us)
    e.tries = (e.tries or 0) + 1
    local ia = resolve(e.action)
    if not ia then
        if e.tries >= 2 and not e.warnedResolve then
            e.warnedResolve = true
            E.log.warn("INPUT %s: action %s is not loaded (tried %d times); retrying at each map load and when the Controls screen opens", e.name, e.action, e.tries)
        end
        return
    end
    if not isA(ia, M.IA_CLASS) then
        e.status = "failed"
        E.log.error("INPUT %s: %s is a %s, not an InputAction; the control stays inactive", e.name, e.action, try(function() return ia:GetClass():GetFName():ToString() end) or "?")
        return
    end
    local cat = categoryOf(us, e.near)
    e.nearFound = cat ~= nil
    if not cat then
        cat = "General"
        if e.near and not e.warnedNear then
            e.warnedNear = true
            E.log.warn("INPUT %s: near '%s' names no game row in the Controls menu; the row goes at the end of General", e.name, quote(e.near))
        end
    end
    e.category = cat
    local enc = M.encode(e.name)
    local f = flags()
    local pm = try(function() return ia.PlayerMappableKeySettings end)
    if not valid(pm) then
        local cls = found(M.PMKS_CLASS)
        if not cls then error("PlayerMappableKeySettings class not found", 0) end
        pm = StaticConstructObject(cls, ia, FName("PMKS_" .. enc), f)
        if not valid(pm) then error("PlayerMappableKeySettings construction failed", 0) end
    end
    pm.Name = FName(e.name)
    pm.DisplayName = FText(e.label)
    pm.DisplayCategory = FText(cat)
    ia.PlayerMappableKeySettings = pm
    local imcPath = M.imcPath(e.name)
    local imc = found(imcPath)
    if not imc then
        local cls, outer = found(M.IMC_CLASS), found(M.TRANSIENT)
        if not (cls and outer) then error("InputMappingContext class or /Engine/Transient not found", 0) end
        imc = StaticConstructObject(cls, outer, FName("IMC_" .. enc), f)
        if not valid(imc) then error("InputMappingContext construction failed", 0) end
    end
    imc:UnmapAll()
    imc:MapKey(ia, { KeyName = FName(e.key) })
    imc:MapKey(ia, { KeyName = FName(e.gamepad) })
    e.imc = imcPath
    us:RegisterInputMappingContext(imc)
    sub:AddMappingContext(imc, 0, OPTS)
    e.built, e.status = true, "active"
    S.gen = S.gen + 1
    E.log.info("INPUT %s active: '%s' %s / %s in %s %s %s", e.name, quote(e.label), e.key, e.gamepad, cat,
        e.nearFound and "after" or "at the end", e.nearFound and quote(e.near) or "")
end

local function readd(e, sub)
    local imc = e.imc and found(e.imc)
    if not imc then return false end
    sub:AddMappingContext(imc, 0, OPTS)
    return true
end

local function teardown(sub, us)
    for _, td in ipairs(S.teardown) do
        local imc = found(td.imc)
        if imc then
            local okR, errR = pcall(function() sub:RemoveMappingContext(imc, OPTS) end)
            local okU, errU = pcall(function() us:UnregisterInputMappingContext(imc) end)
            if not (okR and okU) then
                E.log.warn("INPUT %s: release failed (%s)", td.name, firstLine(okR and errU or errR))
            else
                E.log.info("INPUT %s released", td.name)
            end
        end
    end
    S.teardown = {}
end

function M.tick()
    local needSub = #S.teardown > 0 or S.window ~= nil
    if not needSub then return end
    local sub = liveSub()
    local us = sub and settingsOf(sub)
    if not us then
        if S.window and E.now() > S.window.deadline then
            local n = 0
            for _, name in ipairs(S.order) do local e = S.reg[name] if e.status == "active" or e.tryNow then n = n + 1 end end
            if n > 0 then E.log.warn("INPUT no player controller within %d s (%s); %d control(s) inactive until the next map load or Controls screen", M.WINDOW_S, S.window.why, n) end
            S.window = nil
        end
        return
    end
    if #S.teardown > 0 then teardown(sub, us) end
    if S.window then
        for _, name in ipairs(S.order) do
            local e = S.reg[name]
            if e and e.tryNow then
                e.tryNow = false
                local ok, err = pcall(activate, e, sub, us)
                if not ok then
                    e.status = "failed"
                    E.log.error("INPUT %s could not be activated: %s; the control stays inactive", e.name, firstLine(err))
                end
            elseif e and e.status == "active" and e.needAdd then
                e.needAdd = false
                local ok, err = pcall(readd, e, sub)
                if not ok then E.log.warn("INPUT %s: AddMappingContext after the map load failed: %s", e.name, firstLine(err)) end
            end
        end
        S.window = nil
    end
end

-- Every control not active yet (and not failed) tries again on the next tick with a controller (map load, screen open).
local function retryPending(why)
    local any = false
    for _, name in ipairs(S.order) do
        local e = S.reg[name]
        if e.status == "pending" then e.tryNow = true; any = true end
    end
    if any then openWindow(why) end
end

function M.onLoadMap()
    if S.pcH then pcall(E.free, S.pcH); S.pcH = nil end
    S.pcNext = 0
    local any = false
    for _, name in ipairs(S.order) do
        local e = S.reg[name]
        if e.status == "active" then e.needAdd = true; any = true end
    end
    retryPending("map load")
    if any then openWindow("map load") end
end

function M.onScreenOpen() retryPending("Controls screen opened") end

-- ---------------------------------------------------------------- the channel ops

local function countOf(mod)
    local n = 0
    for _, name in ipairs(S.order) do if S.reg[name].mod == mod then n = n + 1 end end
    return n
end

local function drop(name)
    local e = S.reg[name]
    if not e then return false end
    S.reg[name] = nil
    for i, n in ipairs(S.order) do if n == name then table.remove(S.order, i) break end end
    if e.built then S.teardown[#S.teardown + 1] = { imc = e.imc, name = name } end
    S.gen = S.gen + 1
    return true
end

local function onlyKeys(t, allowed)
    for k in pairs(t) do
        if not allowed[k] then return "unknown key " .. I.describe(k) end
    end
    return nil
end

local CONTROL_KEYS = { mod = true, id = true, action = true, label = true, key = true, gamepad = true, near = true }
local function opControl(t)
    local why = onlyKeys(t, CONTROL_KEYS)
    if why then return "err:bad-request " .. why end
    local d
    d, why = I.validate({ id = t.id, action = t.action, label = t.label, key = t.key, gamepad = t.gamepad, near = t.near }, M._keyCheck)
    if not d then return "err:bad-request " .. why end
    local name = I.mappingName(t.mod, d.id)
    for _, n in ipairs(S.order) do
        if n ~= name and S.reg[n].action == d.action then
            return "err:conflict action " .. I.describe(d.action) .. " is already declared as '" .. n .. "'"
        end
    end
    local e = S.reg[name]
    if e then
        if e.action == d.action and e.label == d.label and e.key == d.key and e.gamepad == d.gamepad and e.near == d.near and e.status ~= "failed" then
            return "ok:unchanged"
        end
        if e.built then S.teardown[#S.teardown + 1] = { imc = e.imc, name = name } end
    else
        if countOf(t.mod) >= I.MAX_PER_MOD then
            return string.format("err:cap %s already has %d controls (cap %d per mod)", t.mod, I.MAX_PER_MOD, I.MAX_PER_MOD)
        end
        if #S.order >= I.MAX_TOTAL then
            return string.format("err:cap %d controls in all (cap %d)", #S.order, I.MAX_TOTAL)
        end
        S.seq = S.seq + 1
        e = { name = name, mod = t.mod, id = d.id, seq = S.seq }
        S.reg[name] = e
        S.order[#S.order + 1] = name
    end
    e.action, e.label, e.key, e.gamepad, e.near = d.action, d.label, d.key, d.gamepad, d.near
    e.status, e.built, e.tries, e.tryNow, e.needAdd, e.warnedResolve = "pending", false, 0, true, false, false
    S.gen = S.gen + 1
    openWindow("declared")
    if E.log then E.log.info("INPUT %s declared: action %s, '%s', %s / %s, near %s", name, d.action, quote(d.label), d.key, d.gamepad, d.near and ("'" .. quote(d.near) .. "'") or "none") end
    return "ok:declared"
end

local RELEASE_KEYS = { mod = true, id = true, all = true }
local function opRelease(t)
    local why = onlyKeys(t, RELEASE_KEYS)
    if why then return "err:bad-request " .. why end
    if t.all ~= nil then
        if t.all ~= true or t.id ~= nil then return "err:bad-request all must be true and comes without id" end
        local names = {}
        for _, name in ipairs(S.order) do if S.reg[name].mod == t.mod then names[#names + 1] = name end end
        for _, name in ipairs(names) do drop(name) end
        if #names > 0 and E.log then E.log.info("INPUT released %d control(s) of %s (its Lua stopped)", #names, t.mod) end
        return #names > 0 and "ok:true" or "ok:false"
    end
    why = I.checkId(t.id)
    if why then return "err:bad-request " .. why end
    return drop(I.mappingName(t.mod, t.id)) and "ok:true" or "ok:false"
end

local function triggered(e)
    local pc = livePc()
    if not pc then return false end
    local pi = try(function() return pc.PlayerInput end)
    local ia = found(e.action)
    if not (valid(pi) and ia) then return false end
    local addr = ia:GetAddress()
    local hit = false
    pi.ActionInstanceData:ForEach(function(k, v)
        if hit then return end
        local a = U(k)
        if valid(a) and a:GetAddress() == addr then
            hit = try(function() return U(v).TriggerEvent end) == TRIGGERED
        end
    end)
    return hit
end

local ID_KEYS = { mod = true, id = true }
local function opState(t)
    local why = onlyKeys(t, ID_KEYS) or I.checkId(t.id)
    if why then return "err:bad-request " .. why end
    local e = S.reg[I.mappingName(t.mod, t.id)]
    if not e then return "err:unknown-control unknown control " .. I.describe(t.id) .. " (declare it with control first)" end
    if e.status ~= "active" then return "ok:false" end
    local ok, r = pcall(triggered, e)
    if not ok then
        warnOnce("state", "INPUT state of %s could not be read: %s (further failures not logged)", e.name, firstLine(r))
        return "ok:false"
    end
    return r and "ok:true" or "ok:false"
end

local LIST_KEYS = { mod = true }
local ENTRY_ORDER = { "id", "label", "key", "gamepad", "active" }
local function opList(t)
    local why = onlyKeys(t, LIST_KEYS)
    if why then return "err:bad-request " .. why end
    local out, orders = json.array({}), {}
    local us
    for _, name in ipairs(S.order) do
        local e = S.reg[name]
        if e.mod == t.mod then
            local k0, k1
            if e.status == "active" then
                if us == nil then
                    local sub = try(liveSub)
                    us = sub and settingsOf(sub) or false
                end
                if us then
                    local ok, a, b = pcall(rowKeys, us, name)
                    if ok then k0, k1 = a, b end
                end
            end
            local o = { id = e.id, label = e.label, key = k0 or e.key, gamepad = k1 or e.gamepad, active = e.status == "active" }
            orders[o] = ENTRY_ORDER
            out[#out + 1] = o
        end
    end
    local text, err = json.encode(out, orders)
    if not text then return "err:internal list could not be encoded (" .. tostring(err) .. ")" end
    return "ok:" .. text
end

local OPS = { ["input-control"] = opControl, ["input-release"] = opRelease, ["input-state"] = opState, ["input-list"] = opList }
M.OPS = OPS

-- op(op, payload) -> reply. payload: a flat JSON object with the caller's mod id ("mod") and the op's fields.
function M.op(op, payload)
    local f = OPS[op]
    if not f then return "err:bad-request unknown input op" end
    if type(payload) ~= "string" or payload == "" then return "err:bad-request " .. op .. " needs a JSON object payload" end
    local t, err = json.decode(payload, M.CAPS)
    if t == nil then return "err:bad-request payload: " .. tostring(err) end
    if type(t) ~= "table" or json.isArray(t) then return "err:bad-request payload must be a JSON object" end
    if not I.isModId(t.mod) then return "err:bad-request mod must be a mod id (mod.json id), got " .. I.describe(t.mod) end
    return f(t)
end

-- The Controls page pass's view of the registry: the info of an active control's mapping name, else nil.
function M.rowInfo(name)
    local e = S.reg[name]
    if not e or e.status ~= "active" then return nil end
    return { order = e.seq, near = e.near, nearFound = e.nearFound == true }
end
function M.gen() return S.gen end

-- ---------------------------------------------------------------- the Controls page and the loop

-- One page pass (input/screen.lua) on the live overlay (valid only in this callback).
local function passOn(screen, why)
    S.passGen = S.gen
    local SC = require(BASE .. ".input.screen")
    local st, err = SC.pass(screen, M.rowInfo)
    if not st then warnOnce("pass", "INPUT Controls page pass skipped: %s", tostring(err)) return end
    E.log.info("INPUT Controls page (%s): %d rows, %d of core (%d moved in %d box(es), %d selector(s) now allow gamepad keys), %d dead row(s) hidden",
        why, st.rows, st.core, st.moved, st.boxes, st.gamepad, st.hidden)
end

-- The shared poll (ui/game.lua) in core's own state: the Settings overlay as core's internal host "settings". Started
-- from the first map load (game thread), once.
function M.startScreen()
    if S.screenOn then return end
    S.screenOn = true
    local C = require(BASE .. ".ui.common")
    local G = require(BASE .. ".ui.game")
    if not C.bound then C.bind{ mod = NAME, log = E.log, ref = E.ref, deref = E.deref, free = E.free, micros = E.micros } end
    G._watch("settings", function(screen, info)
        if info.event ~= "opened" or not screen then return end
        local ok, err = pcall(passOn, screen, "opened")
        if not ok then warnOnce("pass error", "INPUT Controls page pass failed: %s (further failures not logged)", firstLine(err)) end
        pcall(M.onScreenOpen)
    end)
    G._ticker("settings", function(screen)
        if S.passGen == S.gen then return end
        local ok, err = pcall(passOn, screen, "controls changed")
        if not ok then warnOnce("pass error", "INPUT Controls page pass failed: %s (further failures not logged)", firstLine(err)) end
    end)
end

-- core's tick: a game-thread loop, registered once from the game thread (the LoadMap post-hook).
function M.start()
    if S.loop then return end
    local ok, res = pcall(LoopInGameThreadWithDelay, M.TICK_MS, function()
        local okT, errT = pcall(M.tick)
        if not okT then warnOnce("tick", "INPUT tick failed: %s (further failures not logged)", firstLine(errT)) end
    end)
    if ok and math.type(res) == "integer" then S.loop = res
    else E.log.error("INPUT loop could not start: %s", ok and ("LoopInGameThreadWithDelay returned " .. tostring(res)) or firstLine(res)) end
end

-- init{ log, ref, deref, free, micros, now }
function M.init(env)
    E.log, E.ref, E.deref, E.free, E.micros = env.log, env.ref, env.deref, env.free, env.micros
    if env.now then E.now = env.now end
end

-- Lua stopping (core's OnUnload): every control's context released now, as far as the game thread allows.
function M.unload()
    for _, name in ipairs(S.order) do
        local e = S.reg[name]
        if e.built then S.teardown[#S.teardown + 1] = { imc = e.imc, name = name } end
    end
    S.reg, S.order = {}, {}
    pcall(function()
        local sub = liveSub()
        local us = sub and settingsOf(sub)
        if us then teardown(sub, us) end
    end)
    if S.pcH then pcall(E.free, S.pcH) end
    if S.subH then pcall(E.free, S.subH) end
    S.pcH, S.subH = nil, nil
    if S.loop then pcall(CancelDelayedAction, S.loop); S.loop = nil end
end

-- For unit tests only.
M._S = S
function M._reset()
    S.reg, S.order, S.gen, S.seq, S.teardown, S.window, S.pcH, S.subH, S.pcNext, S.warned = {}, {}, 0, 0, {}, nil, nil, nil, 0, {}
end

return M
