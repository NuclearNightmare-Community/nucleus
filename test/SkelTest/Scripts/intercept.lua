-- <Core>SkelTest's function-interception part (core story 43, CAP-13: <Core>_FnIntercept/_FnRelease/_FnSuspend/_FnList
-- and core.fn), loaded by main.lua with dofile (main.lua is at Lua's 200-locals limit). Takes main.lua's helpers plus GS
-- (gamescreen.lua's module, for its shared helpers) and returns:
--   badInput(phase)  the fn-* bad-input cases as one step (argument validation, the allowlist, not loaded, the
--                    core.fn wrappers); in bad-input (menu1, match1)
--   offThread(P)     every interception native and core.fn call off the game thread (inside a LoopAsync block)
--   build()          the intercept scenario, written for the VM at 1280x720 (run.ps1 -Scenario intercept -Target vm).
--     Pass 1: menu1, a real click on START GAME (Create Server open) and on CONFIGURE (the world settings, where
--     the cards are; scrolled into view before each real click or hover), then the story's matrix rows in order:
--       skip a click     a skip rule on card A's click (onCall): a real mouse click, Enter on the focused card (the
--                        gamepad-style press: Slate's accept key broadcasts OnClicked) and a Lua call; A's Available
--                        and its GI.EnemyDefinitions entry unchanged each time, seen/applied +1, onCall(A) once, next frame
--       other card       a real click on card B toggles it (and a second one puts it back)
--       replace tooltip  a replace rule on A's GetToolTipWidget with a TextBlock "NUCLEUS TIP" (outer: the game
--                        instance): the Lua call returns it, B returns a W_ToolTip_EnemySelect_C; a real hover over A
--                        raises applied; screenshot fn-tip
--       any vs exact     an any skip on GetToolTipWidget as well: A -> the TextBlock, B -> nil; then released
--       runOriginal      runOriginal(click rule, A's click) toggles A; the next real click is skipped again; a raising f
--                        is re-raised and the rule resumed; A put back with runOriginal
--       two mods         <Core>SkelPeer (cue <core>.test.fn.cue) installs an any skip on the Bat card's click and is
--                        refused card A's click (its PEERFN line); the Bat card's click is skipped
--       fn-live-*        the bad-input cases that need the screen: target of the wrong class, freed or unknown target
--                        and value handles, a value of the wrong class, replace on a function with no return value, the
--                        16-per-mod cap, another mod's rule id (release and suspend) and key, the same key again
--       dependent stops  UninstallMod("<Core>SkelPeer"): its rule is gone and the Bat card toggles
--       core reload      two rules left installed; Scripts/intercept-pass.txt written and a "hotreload" request
--                        (Ctrl+R): Lua stops and core's DLL unloads
--       after runOriginal: a suspension left on is cleared by the next tick (FNTICKCLEAR); the tooltip rule's value
--                        swapped (same key) and released on the game thread, each followed by a forced GC (FNSWAPVAL,
--                        FNRELFREE), then installed again; a rule on a spare card a forced GC collects is dropped by
--                        the next install (FNPRUNE)
--     Pass 2 (main.lua runs again after the reload; intercept-pass.txt says so): FnList empty, card A and the Bat card
--     toggle again (each put back); the replacement released off the game thread at the reload is still kept by the
--     game instance after a forced GC (FN2KEPT). check.ps1 finds the old instance's released, kept and unloading lines.
--   Cards are always left as found. Create is never clicked: no session is made.
-- Never keeps a UObject across steps: each step finds what it needs again; only paths, handles and numbers are kept.
return function(X, GS)
    local FN = {}
    local case, E, step, check, say, CORE = X.case, X.E, X.step, X.check, X.say, X.CORE
    local U8 = GS.util
    local try, v, prop, liveOf, center, msAfter, firstLine = U8.try, U8.v, U8.prop, U8.liveOf, U8.center, U8.msAfter, U8.firstLine
    local LOWER = CORE:lower()
    local PEER = CORE .. "SkelPeer"
    local ME = CORE .. "SkelTest"
    local function core() return X.core() end
    local function nat(s) return _G[CORE .. s] end
    local nI, nR, nS, nL = CORE .. "_FnIntercept", CORE .. "_FnRelease", CORE .. "_FnSuspend", CORE .. "_FnList"
    local MAXH = (1 << 53) - 1

    local CLICK = "BndEvt__EnemySlot_Button_Button_48_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
    local ES = "/Game/Graphics/MainMenu/EnemySelect/EnemySlot_Button.EnemySlot_Button_C:"
    local BS = "/Game/Graphics/MainMenu/EnemySelect/BatSlot_Button1.BatSlot_Button1_C:"
    local P_CLICK, P_TIP, P_BCLICK, P_BTIP = ES .. CLICK, ES .. "GetToolTipWidget", BS .. CLICK, BS .. "GetToolTipWidget"
    FN.PATHS = { click = P_CLICK, tip = P_TIP, batClick = P_BCLICK, batTip = P_BTIP }
    local A_TYPE, B_TYPE = 0, 2 -- card A: the Stalker; card B: the Meek (both on by default; turning one off passes SafetyCheck)
    local GI_ENEMY, GI_AVAIL = "Enemy_3_BF4B99684B79D5A4DE353F8502DF2C75", "Available_4_B44B8C5E42AE5E7A47C7978FEF8D6593"
    local CUE, PEER_DONE = LOWER .. ".test.fn.cue", LOWER .. ".test.fn.peer"
    local PASS_FILE = X.scriptDir .. "\\intercept-pass.txt"
    local TIP_TEXT = "NUCLEUS TIP"

    -- ---------------------------------------------------------------- bad input
    function FN.badInput(phase)
        step(phase .. ": fn cases", function()
            local I, R, S, L = nat("_FnIntercept"), nat("_FnRelease"), nat("_FnSuspend"), nat("_FnList")
            local P = phase .. ".fn-"
            local function f(fn, ...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end
            local ARG4 = nI .. ": expected 4 arguments (path, target, action, value), got "
            local TGT = nI .. ": argument 2 (target) must be an integer (a handle, or 0 for any instance), got "
            local VAL = nI .. ": argument 4 (value) must be nil or an integer handle, got "
            local function allow(p) return nI .. ": '" .. p .. "' is not on the allowlist" end
            -- <Core>_FnIntercept: counts and types (taken in order: path, target, action, value)
            case(P .. "i-noargs", nI .. "()", f(I), E.err(ARG4 .. "0"))
            case(P .. "i-three", nI .. "(path, 0, 'skip')", f(I, P_CLICK, 0, "skip"), E.err(ARG4 .. "3"))
            case(P .. "i-five", nI .. "(path, 0, 'skip', nil, 1)", f(I, P_CLICK, 0, "skip", nil, 1), E.err(ARG4 .. "5"))
            case(P .. "i-path-nil", nI .. "(nil, 0, 'skip', nil)", f(I, nil, 0, "skip", nil), E.err(nI .. ": argument 1 (path) must be a string, got nil"))
            case(P .. "i-path-num", nI .. "(5, 0, 'skip', nil)", f(I, 5, 0, "skip", nil), E.err(nI .. ": argument 1 (path) must be a string, got an integer"))
            case(P .. "i-path-table", nI .. "({}, 0, 'skip', nil)", f(I, {}, 0, "skip", nil), E.err(nI .. ": argument 1 (path) must be a string, got a table"))
            case(P .. "i-target-str", nI .. "(path, '0', 'skip', nil)", f(I, P_CLICK, "0", "skip", nil), E.err(TGT .. "a string"))
            case(P .. "i-target-float", nI .. "(path, 1.5, 'skip', nil)", f(I, P_CLICK, 1.5, "skip", nil), E.err(TGT .. "a float"))
            case(P .. "i-target-nil", nI .. "(path, nil, 'skip', nil)", f(I, P_CLICK, nil, "skip", nil), E.err(TGT .. "nil"))
            case(P .. "i-target-bool", nI .. "(path, true, 'skip', nil)", f(I, P_CLICK, true, "skip", nil), E.err(TGT .. "a boolean"))
            case(P .. "i-action-nil", nI .. "(path, 0, nil, nil)", f(I, P_CLICK, 0, nil, nil), E.err(nI .. ": argument 3 (action) must be a string, got nil"))
            case(P .. "i-action-num", nI .. "(path, 0, 1, nil)", f(I, P_CLICK, 0, 1, nil), E.err(nI .. ": argument 3 (action) must be a string, got an integer"))
            case(P .. "i-value-str", nI .. "(tip, 0, 'replace', '1')", f(I, P_TIP, 0, "replace", "1"), E.err(VAL .. "a string"))
            case(P .. "i-value-float", nI .. "(tip, 0, 'replace', 1.5)", f(I, P_TIP, 0, "replace", 1.5), E.err(VAL .. "a float"))
            case(P .. "i-value-table", nI .. "(tip, 0, 'replace', {})", f(I, P_TIP, 0, "replace", {}), E.err(VAL .. "a table"))
            -- the path: size and the allowlist
            case(P .. "i-path-empty", nI .. "('', 0, 'skip', nil)", f(I, "", 0, "skip", nil), E.err(nI .. ": path must be 1..512 bytes, got 0"))
            case(P .. "i-path-513", nI .. "(<513 bytes>, 0, 'skip', nil)", f(I, string.rep("a", 513), 0, "skip", nil), E.err(nI .. ": path must be 1..512 bytes, got 513"))
            case(P .. "i-path-4k", nI .. "(<4096 bytes>, 0, 'skip', nil)", f(I, string.rep("/", 4096), 0, "skip", nil), E.err(nI .. ": path must be 1..512 bytes, got 4096"))
            case(P .. "i-offlist", nI .. "('/Game/Foo.Foo_C:Bar', ...)", f(I, "/Game/Foo.Foo_C:Bar", 0, "skip", nil), E.err(allow("/Game/Foo.Foo_C:Bar")))
            case(P .. "i-offlist-case", nI .. "(<click path lowercased>, ...)", f(I, P_CLICK:lower(), 0, "skip", nil), E.err("' is not on the allowlist"))
            case(P .. "i-offlist-space", nI .. "(<tip path>..' ', ...)", f(I, P_TIP .. " ", 0, "skip", nil), E.err("' is not on the allowlist"))
            case(P .. "i-offlist-native", nI .. "('/Script/Engine.KismetSystemLibrary:IsValid', ...) [a native function]",
                f(I, "/Script/Engine.KismetSystemLibrary:IsValid", 0, "skip", nil), E.err(allow("/Script/Engine.KismetSystemLibrary:IsValid")))
            case(P .. "i-offlist-ctrl", nI .. "('\\1\\2\\3x', ...)", f(I, "\1\2\3x", 0, "skip", nil), E.err(allow("???x")))
            case(P .. "i-offlist-512", nI .. "(<512 slashes>, ...)", f(I, string.rep("/", 512), 0, "skip", nil), E.err("' is not on the allowlist"))
            case(P .. "i-offlist-class", nI .. "(<the card class, no function>, ...)", f(I, ES:sub(1, -2), 0, "skip", nil), E.err("' is not on the allowlist"))
            -- target and action values
            local RANGE = " is out of range (0 for any instance, or 1.." .. MAXH .. ")"
            case(P .. "i-target-neg", nI .. "(path, -1, 'skip', nil)", f(I, P_CLICK, -1, "skip", nil), E.err(nI .. ": target handle -1" .. RANGE))
            case(P .. "i-target-2^53", nI .. "(path, 2^53, 'skip', nil)", f(I, P_CLICK, 1 << 53, "skip", nil), E.err(nI .. ": target handle 9007199254740992" .. RANGE))
            case(P .. "i-target-minint", nI .. "(path, math.mininteger, 'skip', nil)", f(I, P_CLICK, math.mininteger, "skip", nil), E.err(nI .. ": target handle " .. math.mininteger .. RANGE))
            case(P .. "i-action-bad", nI .. "(path, 0, 'Skip', nil)", f(I, P_CLICK, 0, "Skip", nil), E.err(nI .. ": action must be 'skip' or 'replace', got 'Skip'"))
            case(P .. "i-action-empty", nI .. "(path, 0, '', nil)", f(I, P_CLICK, 0, "", nil), E.err(nI .. ": action must be 'skip' or 'replace', got ''"))
            case(P .. "i-skip-value", nI .. "(path, 0, 'skip', 5)", f(I, P_CLICK, 0, "skip", 5), E.err(nI .. ": value must be nil for 'skip'"))
            case(P .. "i-replace-noreturn", nI .. "(click, 0, 'replace', 5) [the click returns nothing]", f(I, P_CLICK, 0, "replace", 5),
                E.err(nI .. ": 'replace' needs a function that returns an object; " .. P_CLICK .. " returns nothing"))
            case(P .. "i-replace-novalue", nI .. "(tip, 0, 'replace', nil)", f(I, P_TIP, 0, "replace", nil), E.err(nI .. ": 'replace' needs a value (a live handle)"))
            case(P .. "i-replace-value0", nI .. "(tip, 0, 'replace', 0)", f(I, P_TIP, 0, "replace", 0), E.err(nI .. ": value handle 0 is out of range (1.." .. MAXH .. ")"))
            case(P .. "i-replace-valueneg", nI .. "(tip, 0, 'replace', -5)", f(I, P_TIP, 0, "replace", -5), E.err(nI .. ": value handle -5 is out of range (1.." .. MAXH .. ")"))
            -- Not loaded: the Bat card's tooltip function exists only once the create-world screen has loaded its class.
            -- When something already loaded it, the call is a control instead (an any skip, released at once).
            local found = StaticFindObject(P_BTIP) -- a miss is an invalid wrapper, not nil
            local loaded = found ~= nil and try(function() return found:IsValid() end) == true
            if not loaded then
                case(P .. "i-notloaded", nI .. "(<Bat tooltip>, 0, 'skip', nil) [class not loaded]", f(I, P_BTIP, 0, "skip", nil),
                    E.err(nI .. ": " .. P_BTIP .. " is not loaded (open the screen that uses it first)"))
            else
                local id
                case(P .. "i-notloaded", nI .. "(<Bat tooltip>, 0, 'skip', nil) [class already loaded: a control]", function() id = I(P_BTIP, 0, "skip", nil) return id end,
                    E.ret("an integer id", function(r) return math.type(r[1]) == "integer" and r[1] > 0 end))
                if id then pcall(R, id) end
            end
            -- <Core>_FnRelease
            local IDR = " is out of range (1.." .. MAXH .. ")"
            case(P .. "r-noargs", nR .. "()", f(R), E.err(nR .. ": expected 1 argument (id), got 0"))
            case(P .. "r-two", nR .. "(1, 2)", f(R, 1, 2), E.err(nR .. ": expected 1 argument (id), got 2"))
            case(P .. "r-nil", nR .. "(nil)", f(R, nil), E.err(nR .. ": argument 1 (id) must be an integer, got nil"))
            case(P .. "r-str", nR .. "('1')", f(R, "1"), E.err(nR .. ": argument 1 (id) must be an integer, got a string"))
            case(P .. "r-float", nR .. "(1.5)", f(R, 1.5), E.err(nR .. ": argument 1 (id) must be an integer, got a float"))
            case(P .. "r-0", nR .. "(0)", f(R, 0), E.err(nR .. ": id 0" .. IDR))
            case(P .. "r-neg", nR .. "(-1)", f(R, -1), E.err(nR .. ": id -1" .. IDR))
            case(P .. "r-2^53", nR .. "(2^53)", f(R, 1 << 53), E.err(nR .. ": id 9007199254740992" .. IDR))
            case(P .. "r-maxint", nR .. "(math.maxinteger)", f(R, math.maxinteger), E.err(nR .. ": id " .. math.maxinteger .. IDR))
            local isFalse = E.ret("false", function(r) return r.n == 1 and r[1] == false end)
            case(P .. "r-unknown", nR .. "(2^53-1) [never issued]", f(R, MAXH), isFalse)
            math.randomseed(20261119)
            for i = 1, 4 do
                local h = math.random(1000000000, MAXH)
                case(P .. "r-rand" .. i, nR .. "(" .. h .. ") [random, never issued]", f(R, h), isFalse)
            end
            -- <Core>_FnSuspend
            case(P .. "s-noargs", nS .. "()", f(S), E.err(nS .. ": expected 2 arguments (id, on), got 0"))
            case(P .. "s-one", nS .. "(1)", f(S, 1), E.err(nS .. ": expected 2 arguments (id, on), got 1"))
            case(P .. "s-three", nS .. "(1, true, 1)", f(S, 1, true, 1), E.err(nS .. ": expected 2 arguments (id, on), got 3"))
            case(P .. "s-id-str", nS .. "('1', true)", f(S, "1", true), E.err(nS .. ": argument 1 (id) must be an integer, got a string"))
            case(P .. "s-id-0", nS .. "(0, true)", f(S, 0, true), E.err(nS .. ": id 0" .. IDR))
            case(P .. "s-on-nil", nS .. "(1, nil)", f(S, 1, nil), E.err(nS .. ": argument 2 (on) must be a boolean, got nil"))
            case(P .. "s-on-int", nS .. "(1, 1)", f(S, 1, 1), E.err(nS .. ": argument 2 (on) must be a boolean, got an integer"))
            case(P .. "s-on-str", nS .. "(1, 'true')", f(S, 1, "true"), E.err(nS .. ": argument 2 (on) must be a boolean, got a string"))
            case(P .. "s-unknown", nS .. "(2^53-1, true) [never issued]", f(S, MAXH, true), E.err(nS .. ": no rule " .. MAXH))
            -- <Core>_FnList
            case(P .. "l-arg", nL .. "(1)", f(L, 1), E.err(nL .. ": expected 0 arguments, got 1"))
            case(P .. "l-nil", nL .. "(nil)", f(L, nil), E.err(nL .. ": expected 0 arguments, got 1"))
            case(P .. "l-ok", nL .. "() [control]", f(L), E.ret("a string", function(r) return r.n == 1 and type(r[1]) == "string" end))
            -- core.fn (the wrappers dependents use)
            local W = core().fn
            if not check(type(W) == "table", "CASE %sw core.fn exists", P) then return end
            case(P .. "w-nil", "fn.intercept(nil)", f(W.intercept, nil), E.err("fn.intercept: expected a table { fn, target, action, value, onCall }, got nil"))
            case(P .. "w-nofn", "fn.intercept{ action = 'skip' }", f(W.intercept, { action = "skip" }), E.err("fn.intercept: fn must be a string (an allowlisted function path), got nil"))
            case(P .. "w-target-num", "fn.intercept{ fn, target = 5, action = 'skip' }", f(W.intercept, { fn = P_CLICK, target = 5, action = "skip" }),
                E.err("fn.intercept: target must be a UObject or nil (any instance), got 5"))
            case(P .. "w-value-str", "fn.intercept{ fn = tip, action = 'replace', value = 'x' }", f(W.intercept, { fn = P_TIP, action = "replace", value = "x" }),
                E.err("fn.intercept: value must be a UObject or nil, got 'x'"))
            case(P .. "w-oncall-num", "fn.intercept{ fn, action = 'skip', onCall = 1 }", f(W.intercept, { fn = P_CLICK, action = "skip", onCall = 1 }),
                E.err("fn.intercept: onCall must be a function or nil, got 1"))
            case(P .. "w-mod", "fn.intercept{ fn, action = 'skip', mod = '" .. PEER .. "' } [no owner argument]", f(W.intercept, { fn = P_CLICK, action = "skip", mod = PEER }),
                E.err("fn.intercept: unknown key 'mod' (fn, target, action, value, onCall)"))
            case(P .. "w-offlist", "fn.intercept{ fn = '/Game/Foo.Foo_C:Bar', action = 'skip' }", f(W.intercept, { fn = "/Game/Foo.Foo_C:Bar", action = "skip" }),
                E.err("fn.intercept: '/Game/Foo.Foo_C:Bar' is not on the allowlist"))
            case(P .. "w-action", "fn.intercept{ fn, action = 'drop' }", f(W.intercept, { fn = P_CLICK, action = "drop" }),
                E.err("fn.intercept: action must be 'skip' or 'replace', got 'drop'"))
            case(P .. "w-release-str", "fn.release('1')", f(W.release, "1"), E.err("fn.release: id must be an integer (one intercept returned), got '1'"))
            case(P .. "w-release-unknown", "fn.release(2^53-1)", f(W.release, MAXH), isFalse)
            case(P .. "w-run-nil", "fn.runOriginal(1, nil)", f(W.runOriginal, 1, nil), E.err("fn.runOriginal: f must be a function, got nil"))
            case(P .. "w-run-unknown", "fn.runOriginal(2^53-1, f)", f(W.runOriginal, MAXH, function() end), E.err("fn.runOriginal: no rule " .. MAXH))
            case(P .. "w-list-arg", "fn.list(1)", f(W.list, 1), E.err("fn.list: expected 0 arguments, got 1"))
            case(P .. "w-list-ok", "fn.list() [control]", f(W.list), E.ret("a table", function(r) return r.n == 1 and type(r[1]) == "table" end))
            case(P .. "w-has", "core.has('fn.intercept'), core.has('fn')", function() return core().has("fn.intercept"), core().has("fn") end,
                E.ret("true, true", function(r) return r[1] == true and r[2] == true end))
        end)
    end

    function FN.offThread(P)
        local I, R, S, L = nat("_FnIntercept"), nat("_FnRelease"), nat("_FnSuspend"), nat("_FnList")
        local W = core().fn
        local REF = " refused: called off the game thread"
        case(P .. "off-fn-intercept", nI .. "(path, 0, 'skip', nil) [off thread]", function() return I(P_CLICK, 0, "skip", nil) end, E.err(nI .. REF))
        case(P .. "off-fn-release", nR .. "(1) [off thread]", function() return R(1) end, E.err(nR .. REF))
        case(P .. "off-fn-suspend", nS .. "(1, true) [off thread]", function() return S(1, true) end, E.err(nS .. REF))
        case(P .. "off-fn-list", nL .. "() [off thread, allowed]", function() return L() end, E.ret("a string", function(r) return r.n == 1 and type(r[1]) == "string" end))
        if type(W) ~= "table" then return end
        case(P .. "off-fn-w-intercept", "fn.intercept{...} [off thread]", function() return W.intercept{ fn = P_CLICK, action = "skip" } end, E.err("fn.intercept: called off the game thread"))
        case(P .. "off-fn-w-release", "fn.release(1) [off thread]", function() return W.release(1) end, E.err("fn.release: called off the game thread"))
        case(P .. "off-fn-w-run", "fn.runOriginal(1, f) [off thread]", function() return W.runOriginal(1, function() end) end, E.err("fn.runOriginal: called off the game thread"))
    end

    -- ---------------------------------------------------------------- the intercept scenario
    local CS_SHORT, MENU_SHORT, START = U8.CS_SHORT, U8.MENU_SHORT, U8.START
    local function screen() return liveOf(CS_SHORT) end
    local function gi() local g = FindFirstOf("BP_GameInstance_C") return v(g) and g or nil end
    -- A card by key: "A", "B" (EnemyType), or "bat".
    local function card(key)
        local s = screen()
        if not s then return nil end
        if key == "bat" then return prop(s, "BatSlot") end
        local want = key == "A" and A_TYPE or B_TYPE
        local arr = try(function() return s.EnemySlotButtons end)
        if not arr then return nil end
        local n = try(function() return arr:GetArrayNum() end) or 0
        for i = 1, n do
            local c = try(function() return arr[i] end)
            if v(c) and try(function() return c.EnemyType end) == want then return c end
        end
        return nil
    end
    -- "<card Available>/<game instance value>" (the Bat: Available / not DisableBats), or nil.
    local function state(key)
        local c, g = card(key), gi()
        if not (c and g) then return nil end
        local avail = try(function() return c.Available end)
        local giv
        if key == "bat" then
            local d = try(function() return g.DisableBats end)
            if d ~= nil then giv = not d end
        else
            local want = key == "A" and A_TYPE or B_TYPE
            try(function()
                local defs = g.EnemyDefinitions
                for i = 1, defs:GetArrayNum() do
                    local e = defs[i]
                    if e[GI_ENEMY] == want then giv = e[GI_AVAIL] break end
                end
            end)
        end
        if avail == nil or giv == nil then return nil end
        return tostring(avail) .. "/" .. tostring(giv)
    end
    local function flipped(s) if not s then return nil end local a, b = s:match("^(%a+)/(%a+)$") return tostring(a ~= "true") .. "/" .. tostring(b ~= "true") end
    local function callClick(key) local c = card(key) if c then c[CLICK](c) end return c ~= nil end
    local function ruleById(id) for _, r in ipairs(core().fn.list()) do if r.id == id then return r end end return nil end
    local function counts(id) local r = ruleById(id) return r and r.seen or -1, r and r.applied or -1 end
    local function addrOf(o) return v(o) and try(function() return o:GetAddress() end) or nil end
    -- Liveness through KismetSystemLibrary:IsValid as a UFunction (AGENTS.md: UE4SS's IsValid() passes destroyed objects).
    local function kslAlive(o)
        if o == nil then return false end
        return try(function()
            return StaticFindObject("/Script/Engine.KismetSystemLibrary:IsValid")(StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"), o)
        end) == true
    end

    local function clickOn(label, finder)
        step("fn: click " .. label, function()
            local w = finder()
            local r = w and X.absR(w)
            if not check(r ~= nil and r.r > r.l, "FNPOINT %s has a screen rectangle", label) then return end
            local x, y = center(r)
            say("FNCLICKREQ %s at (%d,%d)", label, x, y)
            return X.request(string.format("click %d %d", x, y)), 40, "click " .. label
        end)
    end
    local function settle(label, sec) step("fn: settle " .. label, function() return msAfter(sec), sec + 3 end) end
    -- The cards sit in the world settings list (CONFIGURE), below the fold at 720p: scrolled into view before a real
    -- click or hover, then a moment for the layout.
    local function intoView(label, key)
        step("fn: into view " .. label, function()
            local sb, c = prop(screen(), "ScrollBox_54"), card(key)
            local ok = sb ~= nil and c ~= nil and pcall(function() sb:ScrollWidgetIntoView(c, false, 0, 0) end)
            if not ok then say("FNSCROLL %s not scrolled into view", label) end
            return msAfter(0.6), 3
        end)
    end
    local function clickCard(label, key)
        intoView(label, key)
        clickOn(label, function() return card(key) end)
    end

    local function startup()
        X.waitWorld("menu1", "NewMainMenu", 120)
        step("menu1: startup screen", function()
            local deadline = os.clock() + 60
            return function() return liveOf("UI_Startup_C") ~= nil or liveOf(MENU_SHORT) ~= nil or os.clock() > deadline end, 65, "startup screen"
        end)
        step("menu1: startup settle", function() return msAfter(2), 4 end)
        step("menu1: startup", function()
            if liveOf(MENU_SHORT) then return end
            local done = X.request("key ENTER")
            local deadline, tries = os.clock() + 15, 1
            return function()
                if liveOf(MENU_SHORT) then return true end
                if os.clock() > deadline and done() and tries < 4 then
                    tries, deadline = tries + 1, os.clock() + 15
                    say("STARTUP no menu yet; Enter again (%d)", tries)
                    done = X.request("key ENTER")
                end
                return false
            end, 70, "menu after Enter"
        end)
        step("menu1: menu settle", function() return msAfter(3), 6 end)
    end

    local function build1()
        local T = { calls = 0, lastAddr = nil, gcs = 0 }
        local W -- core.fn, set in the first step
        -- A forced garbage collection (KismetSystemLibrary:CollectGarbage, run by the engine on its next tick): the
        -- replacement TextBlock, held by the tooltip rule, must still be what card A's GetToolTipWidget returns, while
        -- a control TextBlock with the same outer that nothing holds must be gone (proof that the collection ran).
        local function gcCheck(label)
            step("fn: gc " .. label, function()
                T.gcs = T.gcs + 1
                local ctl = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), gi(), FName("NucleusFnGcControl" .. T.gcs))
                T.ctlH = core().ref(ctl)
                StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
                return msAfter(2), 5
            end)
            step("fn: gc check " .. label, function()
                local ctlGone = core().deref(T.ctlH) == nil
                core().free(T.ctlH)
                local ra = card("A"):GetToolTipWidget()
                local kept = addrOf(ra) == T.tbAddr and core().deref(T.tbH) ~= nil
                check(ctlGone and kept, "FNGC %s: after a forced garbage collection the unheld control TextBlock is gone (%s) and the rule's replacement is still card A's tooltip (%s)",
                    label, tostring(ctlGone), tostring(kept))
            end)
        end
        startup()
        clickOn("START GAME", function() return prop(liveOf(MENU_SHORT), START) end)
        step("fn: screen open", function() return function() return screen() ~= nil and card("A") ~= nil and card("B") ~= nil and card("bat") ~= nil end, 15, "Create Server with its cards" end)
        settle("open", 2)
        clickOn("CONFIGURE", function() return prop(screen(), "Button_216") end)
        settle("configure", 1.5)
        intoView("cards", "A")
        step("fn: cards", function()
            W = core().fn
            T.a0, T.b0, T.bat0 = state("A"), state("B"), state("bat")
            T.addrA = addrOf(card("A"))
            check(T.a0 ~= nil and T.b0 ~= nil and T.bat0 ~= nil and T.a0:match("^(%a+)/%1$") ~= nil,
                "FNCARDS card A (EnemyType %d) %s, card B (EnemyType %d) %s, the Bat card %s (card/game instance)", A_TYPE, tostring(T.a0), B_TYPE, tostring(T.b0), tostring(T.bat0))
        end)

        -- ---- row 1: skip a click (a real click, Enter on the focused card, a Lua call)
        step("fn: skip rule", function()
            T.click = W.intercept{ fn = P_CLICK, target = card("A"), action = "skip", onCall = function(o)
                T.calls = T.calls + 1
                T.lastAddr = addrOf(o)
                say("FNONCALL %d addr=%s", T.calls, tostring(T.lastAddr))
            end }
            local r = ruleById(T.click)
            check(math.type(T.click) == "integer" and r ~= nil and r.mod == ME and r.action == "skip" and r.target ~= "any" and r.seen == 0 and r.applied == 0,
                "FNSKIP rule %s on card A's click: mod=%s target=%s action=%s seen=%s applied=%s", tostring(T.click), tostring(r and r.mod), tostring(r and r.target),
                tostring(r and r.action), tostring(r and r.seen), tostring(r and r.applied))
            ModRef:SetSharedVariable(CUE, 1) -- SkelPeer may now try card A's click (row "two mods")
        end)
        local function skipped(label, how)
            step("fn: before " .. label, function() T.s0, T.ap0 = counts(T.click); T.c0 = T.calls end)
            how()
            settle(label, 1.5)
            step("fn: check " .. label, function()
                local s1, ap1 = counts(T.click)
                local st = state("A")
                check(st == T.a0 and s1 == T.s0 + 1 and ap1 == T.ap0 + 1 and T.calls == T.c0 + 1 and T.lastAddr == T.addrA,
                    "FNSKIPPED %s: card A %s (was %s), seen %d->%d, applied %d->%d, onCall %d->%d with card A (%s)", label, tostring(st), tostring(T.a0),
                    T.s0, s1, T.ap0, ap1, T.c0, T.calls, tostring(T.lastAddr == T.addrA))
            end)
        end
        skipped("real-click", function() clickCard("card A", "A") end)
        skipped("enter", function()
            step("fn: focus card A", function()
                local b = prop(card("A"), "Button_48")
                check(b ~= nil and try(function() b:SetKeyboardFocus() return true end) == true, "FNFOCUS card A's Button_48 has the keyboard focus")
                return msAfter(0.5), 3
            end)
            step("fn: Enter on card A", function() return X.request("key ENTER"), 30, "Enter on card A" end)
        end)
        skipped("lua", function()
            step("fn: Lua call", function()
                local c0 = T.calls
                local ok = callClick("A")
                check(ok and T.calls == c0, "FNLUACALL card A's click called from Lua; onCall not run inside the call (%d)", T.calls - c0)
            end)
        end)

        -- ---- row 2: another card toggles normally (and is put back)
        step("fn: B before", function() T.sb0 = counts(T.click) end)
        clickCard("card B", "B")
        settle("B", 1.5)
        step("fn: B check", function()
            local st, s1 = state("B"), counts(T.click)
            check(st == flipped(T.b0) and s1 == T.sb0, "FNOTHER a real click on card B toggled it (%s -> %s); A's rule saw nothing (seen %d)", tostring(T.b0), tostring(st), s1)
        end)
        clickCard("card B back", "B")
        settle("B back", 1.5)
        step("fn: B restored", function() check(state("B") == T.b0, "FNOTHERBACK card B put back (%s)", tostring(state("B"))) end)

        -- ---- row 3: replace the tooltip with a TextBlock
        step("fn: tip rule", function()
            local g = gi()
            local tb = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), g, FName("NucleusFnTip"))
            tb:SetText(FText(TIP_TEXT))
            T.tbAddr = addrOf(tb)
            T.tbH = core().ref(tb)
            T.tip = W.intercept{ fn = P_TIP, target = card("A"), action = "replace", value = tb }
            local a, b = card("A"), card("B")
            local ra, rb = a:GetToolTipWidget(), b:GetToolTipWidget()
            local bClass = v(rb) and try(function() return rb:GetClass():GetFName():ToString() end) or "nil"
            check(addrOf(ra) == T.tbAddr, "FNTIPA card A's GetToolTipWidget() from Lua -> the TextBlock (%s)", tostring(addrOf(ra) == T.tbAddr))
            check(bClass == "W_ToolTip_EnemySelect_C", "FNTIPB card B's GetToolTipWidget() -> %s", bClass)
        end)
        gcCheck("install")
        intoView("hover", "A")
        step("fn: hover before", function() T.th0 = select(2, counts(T.tip)) end)
        step("fn: hover A", function()
            local r = X.absR(card("A"))
            if not check(r ~= nil and r.r > r.l, "FNPOINT card A for the hover") then return end
            local x, y = center(r)
            return X.request(string.format("move %d %d", x, y)), 40, "hover card A"
        end)
        settle("hover", 2.5)
        step("fn: tip shot", function() return X.request("shot fn-tip"), 30, "screenshot fn-tip" end)
        step("fn: hover check", function()
            local th1 = select(2, counts(T.tip))
            check(th1 > T.th0, "FNHOVER a real hover over card A: the tooltip rule applied %d -> %d", T.th0, th1)
        end)
        step("fn: hover away", function() return X.request("move 4 4"), 40, "move away" end)
        settle("away", 1)
        -- A forced garbage collection after the hover: the replacement must survive it (it is held by the rule), while a
        -- control TextBlock nobody holds is collected, which proves the collection ran.
        gcCheck("hover")

        -- ---- row 4: an any skip next to the exact replace
        step("fn: any vs exact", function()
            T.anyTip = W.intercept{ fn = P_TIP, action = "skip" }
            local ra, rb = card("A"):GetToolTipWidget(), card("B"):GetToolTipWidget()
            check(addrOf(ra) == T.tbAddr and not v(rb), "FNANY with an any skip as well: card A -> the TextBlock (%s), card B -> %s",
                tostring(addrOf(ra) == T.tbAddr), v(rb) and "an object" or "nil")
            check(W.release(T.anyTip) == true, "FNANYREL the any skip released")
        end)

        -- ---- row 5: runOriginal
        step("fn: runOriginal", function()
            local c0, s0, ap0 = T.calls, counts(T.click)
            W.runOriginal(T.click, function() callClick("A") end)
            local st, s1, ap1 = state("A"), counts(T.click)
            check(st == flipped(T.a0) and s1 == s0 + 1 and ap1 == ap0, "FNRUNORIG runOriginal(A's click) toggled card A (%s -> %s); seen %d->%d, applied %d->%d",
                tostring(T.a0), tostring(st), s0, s1, ap0, ap1)
            T.c1 = c0
        end)
        settle("runOriginal", 1)
        step("fn: runOriginal no onCall", function() check(T.calls == T.c1, "FNRUNORIGQUIET no onCall for the call runOriginal let through (%d)", T.calls - T.c1) end)
        step("fn: after runOriginal before", function() T.ap2 = select(2, counts(T.click)) end)
        clickCard("card A again", "A")
        settle("A again", 1.5)
        step("fn: skipped again", function()
            local st, ap = state("A"), select(2, counts(T.click))
            check(st == flipped(T.a0) and ap == T.ap2 + 1, "FNAGAIN the next real click on card A is skipped again (%s, applied %d->%d)", tostring(st), T.ap2, ap)
        end)
        step("fn: runOriginal raises", function()
            local ok, err = pcall(W.runOriginal, T.click, function() error("fn-test raise", 0) end)
            local r = ruleById(T.click)
            local ap0 = r and r.applied or -1
            callClick("A")
            local st, ap1 = state("A"), select(2, counts(T.click))
            check(not ok and err == "fn-test raise" and r and r.suspended == false and st == flipped(T.a0) and ap1 == ap0 + 1,
                "FNRAISE runOriginal re-raised f's error (%s), the rule resumed (suspended=%s), the next Lua call skipped (%s, applied %d->%d)",
                tostring(err), tostring(r and r.suspended), tostring(st), ap0, ap1)
        end)
        -- A suspension nobody resumes is cleared at the next engine tick.
        step("fn: suspend left on", function()
            nat("_FnSuspend")(T.click, true)
            return msAfter(0.5), 3
        end)
        step("fn: tick clear", function()
            local r = ruleById(T.click)
            local ap0 = r and r.applied or -1
            callClick("A")
            local ap1 = select(2, counts(T.click))
            check(r ~= nil and r.suspended == false and ap1 == ap0 + 1, "FNTICKCLEAR a suspension left on is cleared by the next engine tick (suspended=%s, a Lua call applied %d->%d)",
                tostring(r and r.suspended), ap0, ap1)
        end)
        step("fn: A back", function()
            W.runOriginal(T.click, function() callClick("A") end)
            check(state("A") == T.a0, "FNABACK card A put back with runOriginal (%s)", tostring(state("A")))
        end)

        -- The same key with a new replacement: the game instance holds the new one and lets the old one go; a release
        -- on the game thread lets the last one go. Then the tooltip rule is installed again for the reload.
        local function newTip(name)
            local tb = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), gi(), FName(name))
            tb:SetText(FText(TIP_TEXT))
            return tb
        end
        step("fn: swap value", function()
            local tb2 = newTip("NucleusFnTip2")
            T.tb2Addr, T.tb2H = addrOf(tb2), core().ref(tb2)
            T.swapId = W.intercept{ fn = P_TIP, target = card("A"), action = "replace", value = tb2 }
            StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
            return msAfter(2), 5
        end)
        step("fn: swap check", function()
            local ra = card("A"):GetToolTipWidget()
            local oldGone = core().deref(T.tbH) == nil
            check(T.swapId == T.tip and addrOf(ra) == T.tb2Addr and oldGone, "FNSWAPVAL the same key with a new TextBlock keeps rule %s (%s); after a forced GC card A's tooltip is the new one (%s) and the old one is gone (%s)",
                tostring(T.tip), tostring(T.swapId), tostring(addrOf(ra) == T.tb2Addr), tostring(oldGone))
            T.relOk = W.release(T.tip)
            StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
            return msAfter(2), 5
        end)
        step("fn: release frees", function()
            local gone = core().deref(T.tb2H) == nil
            core().free(T.tb2H)
            check(T.relOk == true and gone, "FNRELFREE release(%s) -> %s; after a forced GC its TextBlock is gone (%s)", tostring(T.tip), tostring(T.relOk), tostring(gone))
            local tb3 = newTip("NucleusFnTip3")
            T.tbAddr, T.tbH = addrOf(tb3), core().ref(tb3)
            T.tip = W.intercept{ fn = P_TIP, target = card("A"), action = "replace", value = tb3 }
            check(addrOf(card("A"):GetToolTipWidget()) == T.tbAddr, "FNTIPAGAIN the tooltip rule installed again (rule %s)", tostring(T.tip))
        end)

        -- A rule ends with its target: a skip on a spare card (outer: the game instance, never shown) that a forced GC
        -- collects is dropped by the next install (any rule's), leaves FnList and stops counting toward the cap.
        local function mineCount() local n = 0 for _, r in ipairs(W.list()) do if r.mod == ME then n = n + 1 end end return n end
        step("fn: prune install", function()
            T.mine0 = mineCount()
            local spare = StaticConstructObject(StaticFindObject(ES:sub(1, -2)), gi(), FName("NucleusFnSpareCard"))
            T.spareH = core().ref(spare)
            T.spare = W.intercept{ fn = P_CLICK, target = spare, action = "skip" }
            T.mine1 = mineCount()
            StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
            return msAfter(2), 5
        end)
        step("fn: prune check", function()
            local gone = core().deref(T.spareH) == nil
            core().free(T.spareH)
            local listed = ruleById(T.spare) ~= nil
            local idB = W.intercept{ fn = P_TIP, target = card("B"), action = "skip" }
            local dropped = ruleById(T.spare) == nil
            local relB = W.release(idB)
            local relSpare = W.release(T.spare)
            check(gone and listed and dropped and relB == true and relSpare == false and T.mine1 == T.mine0 + 1 and mineCount() == T.mine0,
                "FNPRUNE the spare card's rule %s (card collected %s, still listed before an install %s) is dropped by the next install (%s); release -> %s; %s's rules %d -> %d -> %d",
                tostring(T.spare), tostring(gone), tostring(listed), tostring(dropped), tostring(relSpare), ME, T.mine0, T.mine1, mineCount())
        end)

        -- ---- row 6: two mods (SkelPeer's any skip on the Bat click; its refusal of card A's click)
        step("fn: peer", function()
            return function() return (math.tointeger(ModRef:GetSharedVariable(PEER_DONE)) or 0) ~= 0 end, 30, "SkelPeer's interception step"
        end)
        step("fn: peer rule", function()
            local peerRule
            for _, r in ipairs(W.list()) do if r.mod == PEER then peerRule = r end end
            T.peer = peerRule and peerRule.id
            check(math.tointeger(ModRef:GetSharedVariable(PEER_DONE)) == 1 and peerRule ~= nil and peerRule.fn == P_BCLICK and peerRule.target == "any" and peerRule.action == "skip",
                "FNPEER %s holds an any skip on the Bat card's click (rule %s)", PEER, tostring(T.peer))
            local st0 = state("bat")
            callClick("bat")
            check(state("bat") == T.bat0 and st0 == T.bat0, "FNPEERBAT the Bat card's click from Lua is skipped by %s's rule (%s)", PEER, tostring(state("bat")))
        end)

        -- ---- fn-live-*: the bad-input cases that need the screen
        step("fn: live cases", function()
            local I, R, S = nat("_FnIntercept"), nat("_FnRelease"), nat("_FnSuspend")
            local P = "cs.fn-live-"
            local function f(fn, ...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end
            local hBat, hB, hGi = core().ref(card("bat")), core().ref(card("B")), core().ref(gi())
            case(P .. "target-class", nI .. "(click, <the Bat card>, 'skip', nil) [not an EnemySlot_Button_C]", f(I, P_CLICK, hBat, "skip", nil), E.err("is not a EnemySlot_Button_C"))
            local hFreed = core().ref(card("B"))
            core().free(hFreed)
            case(P .. "target-freed", nI .. "(click, <a freed handle>, 'skip', nil)", f(I, P_CLICK, hFreed, "skip", nil),
                E.err(nI .. ": target handle " .. hFreed .. " is not a live object (unknown or freed)"))
            case(P .. "target-unknown", nI .. "(click, 2^53-1, 'skip', nil) [never issued]", f(I, P_CLICK, MAXH, "skip", nil),
                E.err(nI .. ": target handle " .. MAXH .. " is not a live object (unknown or freed)"))
            local vFreed = core().ref(card("B"))
            core().free(vFreed)
            case(P .. "value-dead", nI .. "(tip, <card B>, 'replace', <a freed handle>)", f(I, P_TIP, hB, "replace", vFreed),
                E.err(nI .. ": value handle " .. vFreed .. " is not a live object (unknown or freed)"))
            case(P .. "value-class", nI .. "(tip, <card B>, 'replace', <the game instance>) [not a Widget]", f(I, P_TIP, hB, "replace", hGi), E.err("is not a Widget"))
            -- a replacement nothing can keep alive: a TextBlock in /Engine/Transient has no game instance (no world)
            local loose = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), StaticFindObject("/Engine/Transient"), FName("NucleusFnLoose"))
            local hLoose = core().ref(loose)
            case(P .. "value-nogi", nI .. "(tip, <card B>, 'replace', <a TextBlock in /Engine/Transient>) [no game instance]", f(I, P_TIP, hB, "replace", hLoose),
                E.err("has no game instance to keep it alive (create it with the game instance as its outer)"))
            core().free(hLoose)
            -- a replacement whose outer is the player controller: no game instance in its outer chain, found through
            -- GameplayStatics:GetGameInstance (the fallback); installed on card B's tooltip, then released
            local pcObj = FindFirstOf("PlayerController")
            if kslAlive(pcObj) then
                local worldTb = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), pcObj, FName("NucleusFnWorldTip"))
                local hWorld = core().ref(worldTb)
                local idW
                case(P .. "value-world", nI .. "(tip, <card B>, 'replace', <a TextBlock whose outer is the player controller>) [GetGameInstance fallback]",
                    function() idW = I(P_TIP, hB, "replace", hWorld) return idW end,
                    E.ret("an integer id", function(r) return math.type(r[1]) == "integer" and r[1] > 0 end))
                if idW then check(R(idW) == true, "FNWORLDREL the player-controller TextBlock's rule %s released", tostring(idW)) end
                core().free(hWorld)
            else
                check(false, "CASE %svalue-world no live player controller", P)
            end
            case(P .. "noreturn", nI .. "(click, <card B>, 'replace', <a TextBlock>) [the click returns nothing]", f(I, P_CLICK, hB, "replace", T.tbH),
                E.err(nI .. ": 'replace' needs a function that returns an object; " .. P_CLICK .. " returns nothing"))
            case(P .. "tip-bat-class", nI .. "(Bat tooltip, <card B>, 'skip', nil) [an EnemySlot card on the Bat function]", f(I, P_BTIP, hB, "skip", nil), E.err("is not a BatSlot_Button1_C"))
            -- another mod's rule: its id and its key
            if T.peer then
                case(P .. "other-release", nR .. "(<" .. PEER .. "'s rule>)", f(R, T.peer), E.err(nR .. ": rule " .. T.peer .. " belongs to " .. PEER .. ", not " .. ME))
                case(P .. "other-suspend", nS .. "(<" .. PEER .. "'s rule>, true)", f(S, T.peer, true), E.err(nS .. ": rule " .. T.peer .. " belongs to " .. PEER .. ", not " .. ME))
                case(P .. "other-wrelease", "fn.release(<" .. PEER .. "'s rule>)", f(W.release, T.peer), E.err("fn.release: rule " .. T.peer .. " belongs to " .. PEER .. ", not " .. ME))
                case(P .. "other-key", "fn.intercept{ Bat click, any, skip } [" .. PEER .. "'s key]", f(W.intercept, { fn = P_BCLICK, action = "skip" }),
                    E.err("fn.intercept: " .. P_BCLICK .. " on any is already intercepted by " .. PEER))
            else
                check(false, "CASE %sother-* %s's rule not found", P, PEER)
            end
            -- the same key again: the rule is replaced and keeps its id
            case(P .. "same-key", "fn.intercept{ click, card A, skip } again [same key]", function()
                return W.intercept{ fn = P_CLICK, target = card("A"), action = "skip", onCall = function(o) T.calls = T.calls + 1; T.lastAddr = addrOf(o) end }
            end, E.ret("the same id " .. tostring(T.click), function(r) return r[1] == T.click end))
            -- the cap: 16 rules per mod (fillers on keys nobody uses here, released after)
            local keys = {}
            local s = screen()
            local arr = s and try(function() return s.EnemySlotButtons end)
            local n = arr and (try(function() return arr:GetArrayNum() end) or 0) or 0
            for i = 1, n do
                local c = try(function() return arr[i] end)
                local t = c and try(function() return c.EnemyType end)
                if v(c) and t ~= A_TYPE then
                    keys[#keys + 1] = { P_TIP, c }
                    keys[#keys + 1] = { P_CLICK, c }
                end
            end
            keys[#keys + 1] = { P_BTIP, card("bat") }
            keys[#keys + 1] = { P_BCLICK, card("bat") }
            local mine = 0
            for _, r in ipairs(W.list()) do if r.mod == ME then mine = mine + 1 end end
            local fillers, k = {}, 1
            while mine < 16 and k <= #keys do
                local okF, id = pcall(W.intercept, { fn = keys[k][1], target = keys[k][2], action = "skip" })
                if okF then fillers[#fillers + 1] = id; mine = mine + 1 else say("FNCAP filler %d refused: %s", k, firstLine(id)) end
                k = k + 1
            end
            if check(mine == 16 and k <= #keys, "FNCAP %d rules of %s (%d fillers), a key left for the 17th", mine, ME, #fillers) then
                case(P .. "cap-mod", "fn.intercept{...} [a 17th rule of " .. ME .. "]", f(W.intercept, { fn = keys[k][1], target = keys[k][2], action = "skip" }),
                    E.err("fn.intercept: " .. ME .. " has too many rules (16 per mod)"))
            end
            local released = 0
            for _, id in ipairs(fillers) do if W.release(id) == true then released = released + 1 end end
            check(released == #fillers, "FNCAPREL %d of %d fillers released", released, #fillers)
            for _, h in ipairs({ hBat, hB, hGi }) do core().free(h) end
        end)

        -- ---- row 7: the dependent stops
        step("fn: uninstall peer", function()
            say("FNUNINSTALL %s", PEER)
            UninstallMod(PEER)
            return function()
                for _, r in ipairs(core().fn.list()) do if r.mod == PEER then return false end end
                return true
            end, 20, PEER .. "'s rules gone"
        end)
        step("fn: peer gone", function()
            local st0 = state("bat")
            callClick("bat")
            local st1 = state("bat")
            callClick("bat")
            local st2 = state("bat")
            check(st1 == flipped(T.bat0) and st2 == T.bat0, "FNPEERGONE %s's rules are gone and the Bat card toggles from Lua (%s -> %s -> %s)", PEER, tostring(st0), tostring(st1), tostring(st2))
        end)

        -- ---- row 8: core reload with two rules installed
        step("fn: before reload", function()
            local mine, other = 0, 0
            for _, r in ipairs(W.list()) do if r.mod == ME then mine = mine + 1 else other = other + 1 end end
            check(mine == 2 and other == 0 and state("A") == T.a0 and state("B") == T.b0 and state("bat") == T.bat0,
                "FNPRERELOAD %d rules of %s and %d of others installed; the cards as found (A %s, B %s, Bat %s)", mine, ME, other, tostring(state("A")), tostring(state("B")), tostring(state("bat")))
            pcall(core().free, T.tbH)
            local fh = io.open(PASS_FILE, "w")
            if fh then fh:write("1"); fh:close() end
            say("FNRELOAD writing %s and asking for Ctrl+R", PASS_FILE)
        end)
        step("fn: hot reload", function()
            local done = X.request("hotreload")
            -- After Ctrl+R this Lua state is gone; the step only ends (TIMEOUT, a FAIL) if the reload never comes.
            return function() return false and done() end, 90, "hot reload (Ctrl+R)"
        end)
    end

    local function build2()
        local T2 = {}
        step("fn2: screen", function() return function() return screen() ~= nil and card("A") ~= nil and card("bat") ~= nil end, 30, "Create Server still open after the reload" end)
        step("fn2: checks", function()
            os.remove(PASS_FILE)
            local raw = nat("_FnList")()
            local list = core().fn.list()
            check(raw == "" and #list == 0, "FN2EMPTY after the reload FnList is empty (%d bytes, %d rules)", #raw, #list)
            for _, key in ipairs({ "A", "bat" }) do
                local s0 = state(key)
                callClick(key)
                local s1 = state(key)
                callClick(key)
                local s2 = state(key)
                check(s0 ~= nil and s1 == flipped(s0) and s2 == s0, "FN2TOGGLE card %s toggles again (%s -> %s -> %s)", key, tostring(s0), tostring(s1), tostring(s2))
            end
            -- The reload released pass 1's tooltip rule off the game thread (UE4SS's event-loop thread), so the game
            -- instance still keeps its TextBlock (the documented, bounded leak): a forced GC leaves it.
            local g = gi()
            T2.tipPath = g and (g:GetFullName():gsub("^%S+ ", "")) .. ".NucleusFnTip3"
            local tb = T2.tipPath and StaticFindObject(T2.tipPath)
            T2.tipBefore = tb ~= nil and kslAlive(tb)
            StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
            return msAfter(2), 5
        end)
        step("fn2: kept", function()
            local tb = T2.tipPath and StaticFindObject(T2.tipPath)
            local alive = tb ~= nil and kslAlive(tb)
            check(T2.tipBefore == true and alive, "FN2KEPT after the reload and a forced garbage collection pass 1's replacement, released off the game thread, is still kept by the game instance (before %s, after %s)",
                tostring(T2.tipBefore), tostring(alive))
        end)
    end

    function FN.build()
        local fh = io.open(PASS_FILE, "r")
        local pass2 = fh ~= nil
        if fh then fh:close() end
        say("FNPASS %d", pass2 and 2 or 1)
        if pass2 then build2() else build1() end
    end

    return FN
end
