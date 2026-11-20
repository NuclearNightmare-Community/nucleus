-- <Core>SkelTest's input part (core story 44, CAP-14: core.input and the game's Controls menu), loaded by main.lua with
-- dofile (main.lua is at Lua's 200-locals limit). Takes main.lua's helpers and returns:
--   preConnect()     the four core.input calls recorded during main.lua (before connect) as cases
--   badInput(phase)  the in-* bad-input cases as one step: every error row of the story's matrix through core.input
--                    (types, id, label, action, key and gamepad classes, near, the caps of 8 per mod and 64 in all, an
--                    action under another id), each input-* channel op with a malformed payload, state and release on an
--                    unknown id; in bad-input (menu1, match1)
--   offThread(P)     every core.input function off the game thread (inside main.lua's LoopAsync block)
--   build(scenario)  the controls and controls-restart scenarios, written for the VM (run.ps1 -Target vm):
--     controls (run.ps1 moves any EnhancedInputUserSettings.sav aside first): at the title, the test builds an
--       InputAction at runtime (/Engine/Transient.IA_SkelTestControl, as the planning probe did) and writes the dead row
--       skeltest:gone (its own context registered, J mapped with MapPlayerKey, saved, unregistered); then declares
--       toggle (F9, Gamepad_FaceButton_Right, near Sprint), far (near a row that doesn't exist), notia (an object that
--       isn't an InputAction), later (an action that doesn't exist yet) and owned (an action whose key settings already
--       name another row: refused, the name left alone). Opens the Controls page as the title
--       screen's OPTIONS does (SettingsMenu_draggable_C, AddToViewport): toggle directly after Sprint in Movement with
--       F9 and the gamepad default, both selectors allowing gamepad keys while Sprint's don't, far at the end of
--       General, skeltest:gone collapsed, no visible row of an undeclared control. A real capture on slot 0 (focus,
--       Enter, K) and a gamepad capture on slot 1 (focus, Enter, SetSelectedKey Gamepad_FaceButton_Top). The page
--       again (later now built: active from the screen-open retry). later2 declared, its action built just before the
--       travel. Tower Island (SmallMap?listen): the context is added again, later2 active (the map load's retry),
--       keydown K -> state true, keyup -> false; far released and its action declared again as far2 (active); the page
--       opened as the pause menu does: toggle after Sprint, far hidden.
--     controls-restart (after controls; run.ps1 moves the .sav aside afterwards): toggle declared again with its
--       defaults: the row shows K and the gamepad key bound in controls, QueryKeysMappedToAction holds K and not F9;
--       skeltest:gone (declared by no one) is collapsed, and the .sav still holds it.
-- Never keeps a UObject across steps: each step finds what it needs again; only paths, names and numbers are kept.
return function(X)
    local CT = {}
    local case, E, step, check, say, CORE = X.case, X.E, X.step, X.check, X.say, X.CORE
    local LOWER = CORE:lower()
    local FN = LOWER .. ".input."
    local function core() return X.core() end
    local ACTOR_CDO = "/Game/Mods/" .. CORE .. "/ModActor.Default__ModActor_C"
    local CALL = CORE .. "_Call"

    local MOD = "skeltest" -- test/SkelTest/mod.json id
    local IA = { toggle = "/Engine/Transient.IA_SkelTestControl", far = "/Engine/Transient.IA_SkelTestFar",
        later = "/Engine/Transient.IA_SkelTestLater", gone = "/Engine/Transient.IA_SkelTestGone",
        owned = "/Engine/Transient.IA_SkelTestOwned", later2 = "/Engine/Transient.IA_SkelTestLater2" }
    local OWNER = "SkelTestOwner" -- the row name owned's action already carries (as a game action such as IA_Jump does)
    local NOTIA = "/Script/Engine.Default__GameplayStatics"
    local GONE = MOD .. ":gone"
    local TOGGLE = MOD .. ":toggle"
    local DRAG_CLS = "/Game/Graphics/MainMenu/SettingsMenu_draggable.SettingsMenu_draggable_C"
    local ROW_SHORT = "ActionMappingLabelButton_C"
    local CATS = { "General", "Movement", "Inventory", "Vehicle", "Imposter" }
    local SAV = (X.scriptDir:match("^(.*)\\NuclearNightmare\\Binaries\\") or "") .. "\\_userdir\\Saved\\SaveGames\\EnhancedInputUserSettings.sav"

    -- ---------------------------------------------------------------- helpers
    local function try(f, ...) local ok, v = pcall(f, ...) if ok then return v end return nil end
    local function firstLine(e) return (tostring(e):match("^[^\n]*")) end
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
    local function found(p) local o = StaticFindObject(p) return valid(o) and o or nil end
    local function pathOf(o) return try(function() return (o:GetFullName():gsub("^%S+ ", "")) end) or "?" end
    local function classOf(o) return try(function() return o:GetClass():GetFName():ToString() end) or "?" end
    local function keyName(k) return try(function() return k.KeyName:ToString() end) or "?" end
    local function msAfter(sec) local t = os.clock() + sec return function() return os.clock() >= t end end
    local function flags() local f = 0 pcall(function() f = EObjectFlags.RF_Public | EObjectFlags.RF_MarkAsRootSet end) return f end

    local function pc()
        for _, c in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(c) and try(function() return c:IsLocalPlayerController() end) == true then return c end
        end
        return nil
    end
    local function subsystem()
        local c = pc()
        local cls = found("/Script/EnhancedInput.EnhancedInputLocalPlayerSubsystem")
        local sbl = found("/Script/Engine.Default__SubsystemBlueprintLibrary")
        if not (c and cls and sbl) then return nil end
        local s = try(function() return sbl:GetLocalPlayerSubSystemFromPlayerController(c, cls) end)
        return valid(s) and s or nil
    end
    local function settings() local s = subsystem() local us = s and try(function() return s:GetUserSettings() end) return valid(us) and us or nil end

    local function buildIA(path)
        local o = found(path)
        if o then return o end
        local cls, outer = found("/Script/EnhancedInput.InputAction"), found("/Engine/Transient")
        return StaticConstructObject(cls, outer, FName(path:match("%.([^%.]+)$")), flags())
    end
    local function queryKeys(path)
        local s, ia = subsystem(), found(path)
        if not (s and ia) then return "" end
        local r = {}
        pcall(function()
            local t = s:QueryKeysMappedToAction(ia)
            if type(t) == "table" then for _, k in pairs(t) do r[#r + 1] = keyName(U(k)) end
            else t:ForEach(function(_, k) r[#r + 1] = keyName(U(k)) end) end
        end)
        table.sort(r)
        return "," .. table.concat(r, ",") .. ","
    end
    local function hasKey(list, k) return list:find("," .. k .. ",", 1, true) ~= nil end
    local function savText()
        local fh = io.open(SAV, "rb")
        if not fh then return nil end
        local d = fh:read("*a") fh:close()
        return d
    end
    local function listEntry(id)
        local ok, l = pcall(core().input.list)
        if not ok then return nil end
        for _, e in ipairs(l) do if e.id == id then return e end end
        return nil
    end

    -- ---- the Controls page (as the title screen's OPTIONS and the pause menu open it: Create + AddToViewport)
    local function overlay()
        for _, d in ipairs(FindAllOf("SettingsMenu_draggable_C") or {}) do
            if valid(d) and not pathOf(d):find("Default__", 1, true) and try(function() return d:IsInViewport() end) == true then return d end
        end
        return nil
    end
    local function menuOf() local d = overlay() local m = d and try(function() return d.SettingsMenu end) return valid(m) and m or nil end
    local function openPage(tag)
        local cls = found(DRAG_CLS)
        local c = pc()
        local wbl = found("/Script/UMG.Default__WidgetBlueprintLibrary")
        local ok, err = pcall(function()
            local w = wbl:Create(c:GetWorld(), cls, c)
            w:AddToViewport(50)
        end)
        say("CTPAGE %s opened=%s%s", tag, tostring(ok), ok and "" or (" " .. firstLine(err)))
    end
    local function showControls()
        local m = menuOf()
        if not m then return false end
        return pcall(function()
            local w, sw = m.ControlsMenu, m.WidgetSwitcher_0
            local child, guard = w, 0
            while valid(child) and guard < 12 do
                local p = child:GetParent()
                if valid(p) and pathOf(p) == pathOf(sw) then break end
                child, guard = p, guard + 1
            end
            sw:SetActiveWidget(child)
        end)
    end
    local function closePage()
        for _, d in ipairs(FindAllOf("SettingsMenu_draggable_C") or {}) do
            if valid(d) and not pathOf(d):find("Default__", 1, true) then pcall(function() d:RemoveFromParent() end) end
        end
    end
    local function mappingOf(row) return try(function() return row.KeyMap.MappingName:ToString() end) end
    -- Every row on the page: { box, index, name, row-path, visible, label, sel0, sel1, gp0, gp1 }
    local function rows()
        local m = menuOf()
        local out = {}
        if not m then return out end
        local boxes = {}
        for _, cat in ipairs(CATS) do boxes[#boxes + 1] = cat end
        boxes[#boxes + 1] = "ControlsMenu"
        for _, bn in ipairs(boxes) do
            local b = try(function() return m[bn] end)
            local n = b and (try(function() return b:GetChildrenCount() end) or 0) or 0
            for i = 0, n - 1 do
                local c = try(function() return b:GetChildAt(i) end)
                if valid(c) and classOf(c) == ROW_SHORT then
                    out[#out + 1] = { box = bn, index = i, name = mappingOf(c) or "?", path = pathOf(c),
                        visible = try(function() return c:GetVisibility() end) ~= 1,
                        label = try(function() return c.KeyMap.DisplayName:ToString() end) or "",
                        sel0 = try(function() return keyName(c.InputKeySelector_128.SelectedKey.Key) end) or "?",
                        sel1 = try(function() return keyName(c.InputKeySelector.SelectedKey.Key) end) or "?",
                        gp0 = try(function() return c.InputKeySelector_128.bAllowGamepadKeys end),
                        gp1 = try(function() return c.InputKeySelector.bAllowGamepadKeys end) }
                end
            end
        end
        return out
    end
    local function rowOf(list, name) for _, r in ipairs(list) do if r.name == name then return r end end return nil end
    local function boxCount(name) local m = menuOf() local b = m and try(function() return m[name] end) return b and (try(function() return b:GetChildrenCount() end) or 0) or 0 end

    -- The page checks shared by every open: toggle after Sprint (with its keys), gamepad keys on core rows only, dead
    -- rows hidden, no visible row of an undeclared control.
    local function pageChecks(tag, want)
        local list = rows()
        local t, sp = rowOf(list, TOGGLE), rowOf(list, "Sprint")
        check(t ~= nil and sp ~= nil and t.box == "Movement" and sp.box == "Movement" and t.index == sp.index + 1,
            "CTPLACE %s toggle directly after Sprint in Movement (toggle %s[%s], Sprint %s[%s])", tag, t and t.box or "-", t and t.index or "-", sp and sp.box or "-", sp and sp.index or "-")
        check(t ~= nil and t.visible and t.label == "Skel Toggle", "CTLABEL %s toggle shows its label (%q, visible=%s)", tag, t and t.label or "-", tostring(t and t.visible))
        check(t ~= nil and t.sel0 == want.k0 and t.sel1 == want.k1, "CTKEYS %s toggle shows %s and %s (%s, %s)", tag, want.k0, want.k1, t and t.sel0 or "-", t and t.sel1 or "-")
        check(t ~= nil and t.gp0 == true and t.gp1 == true, "CTGAMEPAD %s toggle's selectors allow gamepad keys (%s, %s)", tag, tostring(t and t.gp0), tostring(t and t.gp1))
        check(sp ~= nil and sp.gp0 == false and sp.gp1 == false, "CTGAMEPAD %s Sprint's selectors don't (%s, %s)", tag, tostring(sp and sp.gp0), tostring(sp and sp.gp1))
        local stray = {}
        for _, r in ipairs(list) do
            if r.visible and (r.name:find(":", 1, true) and not want.visible[r.name] or r.label == "") then stray[#stray + 1] = r.name .. "@" .. r.box end
        end
        check(#stray == 0, "CTDEAD %s no visible row of an undeclared control and no unlabeled row (%s)", tag, #stray == 0 and "none" or table.concat(stray, ", "))
        for _, name in ipairs(want.hidden or {}) do
            local r = rowOf(list, name)
            check(r ~= nil and not r.visible, "CTDEAD %s %s is on the page and collapsed (%s)", tag, name, r and (r.box .. "[" .. r.index .. "] visible=" .. tostring(r.visible)) or "missing")
        end
        say("CTROWS %s %d rows; toggle %s", tag, #list, t and (t.box .. "[" .. t.index .. "]") or "missing")
        return list
    end
    local function waitPass(tag)
        -- the poll (500 ms) sees the overlay, core runs its pass; then the checks
        return msAfter(2.5), 5, tag .. " page pass"
    end

    -- ---------------------------------------------------------------- before connect, bad input, off thread
    function CT.preConnect(rec)
        step("before-connect input cases", function()
            for _, r in ipairs(rec or {}) do
                case(r.id, "input." .. r.fn .. "(...) [before connect]", function() if not r.ok then error(r.err, 0) end return "no error" end,
                    E.err(FN .. r.fn .. ": called before connect"))
            end
            check(rec ~= nil and #rec == 4, "CASES before-connect input recorded=%d (expected 4)", rec and #rec or 0)
        end)
    end

    local GOOD = { id = "bad", action = "/Engine/Transient.IA_SkelTestBad", label = "Bad", key = "F9", gamepad = "Gamepad_FaceButton_Right", near = "Sprint" }
    local function with(over)
        local t = {}
        for k, v in pairs(GOOD) do t[k] = v end
        for k, v in pairs(over) do if v == "<nil>" then t[k] = nil else t[k] = v end end
        return t
    end
    function CT.badInput(phase)
        step(phase .. ": input cases", function()
            local IN = core().input
            local P = phase .. ".in-"
            if not check(type(IN) == "table", "CASE %s core.input exists", P .. "api") then return end
            local function ctl(id, over, expect) case(P .. id, "input.control{...} " .. id, function() return IN.control(with(over)) end, expect) end
            local C = FN .. "control: "
            case(P .. "c-nil", "input.control(nil)", function() return IN.control(nil) end, E.err(C .. "expected a table { id, action, label, key, gamepad, near }, got nil"))
            case(P .. "c-str", "input.control('x')", function() return IN.control("x") end, E.err(C .. "expected a table"))
            case(P .. "c-two", "input.control(t, 1)", function() return IN.control(with({}), 1) end, E.err(C .. "expected 1 argument (a table), got 2"))
            ctl("c-unknown", { extra = 1 }, E.err(C .. "unknown key 'extra'"))
            ctl("c-id-nil", { id = "<nil>" }, E.err(C .. "id must be a string, got nil"))
            ctl("c-id-num", { id = 5 }, E.err(C .. "id must be a string, got 5"))
            ctl("c-id-upper", { id = "Bad" }, E.err(C .. "id 'Bad' must match ^[a-z0-9][a-z0-9-]{0,31}$"))
            ctl("c-id-33", { id = string.rep("a", 33) }, E.err(C .. "id '"))
            ctl("c-id-colon", { id = "a:b" }, E.err(C .. "id 'a:b' must match"))
            ctl("c-label-nil", { label = "<nil>" }, E.err(C .. "label must be a string, got nil"))
            ctl("c-label-empty", { label = "" }, E.err(C .. "label is empty"))
            ctl("c-label-49", { label = string.rep("x", 49) }, E.err(C .. "label is 49 characters, cap 48"))
            ctl("c-label-nl", { label = "a\nb" }, E.err(C .. "label has a control character"))
            ctl("c-label-utf8", { label = "\xFF" }, E.err(C .. "label is not valid UTF-8"))
            ctl("c-action-num", { action = 1 }, E.err(C .. "action must be a string"))
            ctl("c-action-noslash", { action = "Engine/Transient.X" }, E.err(C .. "action 'Engine/Transient.X' must be an object path"))
            ctl("c-action-colon", { action = "/Engine/Transient.X:Y" }, E.err(C .. "action '/Engine/Transient.X:Y' must be an object path"))
            ctl("c-action-257", { action = "/" .. string.rep("a", 256) }, E.err(C .. "action '/aaaaaaaa"))
            ctl("c-key-num", { key = 5 }, E.err(C .. "key must be a string (a key name), got 5"))
            ctl("c-key-space", { key = "Left Alt" }, E.err(C .. "key 'Left Alt' is not a key name"))
            ctl("c-key-unknown", { key = "NoSuchKey" }, E.err(C .. "key 'NoSuchKey' is not a valid key"))
            ctl("c-key-gamepad", { key = "Gamepad_FaceButton_Top" }, E.err(C .. "key 'Gamepad_FaceButton_Top' is not a keyboard or mouse key"))
            ctl("c-gp-keyboard", { gamepad = "K" }, E.err(C .. "gamepad 'K' is not a gamepad key"))
            ctl("c-gp-mouse", { gamepad = "LeftMouseButton" }, E.err(C .. "gamepad 'LeftMouseButton' is not a gamepad key"))
            ctl("c-gp-unknown", { gamepad = "Gamepad_Nope" }, E.err(C .. "gamepad 'Gamepad_Nope' is not a valid key"))
            ctl("c-near-num", { near = 3 }, E.err(C .. "near must be a string or nil, got 3"))
            ctl("c-near-empty", { near = "" }, E.err(C .. "near '' must be 1 to 64 characters"))
            ctl("c-near-65", { near = string.rep("n", 65) }, E.err(C .. "near 'nnnnnnnn"))
            -- the action under another id
            ctl("c-dup-first", { id = "dup1", action = "/Engine/Transient.IA_SkelTestDup" }, E.ret("true", function(r) return r[1] == true end))
            ctl("c-dup-again", { id = "dup1", action = "/Engine/Transient.IA_SkelTestDup" }, E.ret("true (re-declared)", function(r) return r[1] == true end))
            ctl("c-dup-other", { id = "dup2", action = "/Engine/Transient.IA_SkelTestDup" }, E.err(C .. "action '/Engine/Transient.IA_SkelTestDup' is already declared as 'skeltest:dup1'"))
            case(P .. "r-dup", "input.release('dup1')", function() return IN.release("dup1") end, E.ret("true", function(r) return r[1] == true end))
            -- 8 per mod
            for i = 1, 8 do ctl("c-cap-" .. i, { id = "cap" .. i, action = "/Engine/Transient.IA_SkelTestCap" .. i }, E.ret("true", function(r) return r[1] == true end)) end
            ctl("c-cap-9", { id = "cap9", action = "/Engine/Transient.IA_SkelTestCap9" }, E.err(C .. "skeltest already has 8 controls (cap 8 per mod)"))
            case(P .. "r-cap", "input.release('cap1'..'cap8')", function()
                local n = 0
                for i = 1, 8 do if IN.release("cap" .. i) then n = n + 1 end end
                return n
            end, E.ret("8", function(r) return r[1] == 8 end))
            -- 64 in all, from eight mods (straight on the channel: the caller's mod id is in the payload)
            local cdo = found(ACTOR_CDO)
            local function direct(req) return function() local v = cdo[CALL](cdo, req) if type(v) == "userdata" then return v:ToString() end return v end end
            local function ctlReq(mod, id, n)
                return string.format('input-control:{"mod":"%s","id":"%s","action":"/Engine/Transient.IA_SkelTestAll%d","label":"All %d","key":"F9","gamepad":"Gamepad_FaceButton_Right"}', mod, id, n, n)
            end
            if check(cdo ~= nil, "CASE %s channel class default object found", P .. "chd") then
                case(P .. "c-cap-all", "64 controls from eight mods [direct]", function()
                    local okN, n = 0, 0
                    for m = 1, 8 do for i = 1, 8 do n = n + 1; if direct(ctlReq("capm" .. m .. ".x", "c" .. i, n))() == "ok:declared" then okN = okN + 1 end end end
                    return okN
                end, E.ret("64", function(r) return r[1] == 64 end))
                case(P .. "c-cap-65", "the 65th control [direct]", direct(ctlReq("capm9.x", "c1", 65)), E.reply("err:cap 64 controls in all (cap 64)"))
                case(P .. "r-cap-all", "input-release all of the eight mods [direct]", function()
                    local n = 0
                    for m = 1, 8 do if direct('input-release:{"mod":"capm' .. m .. '.x","all":true}')() == "ok:true" then n = n + 1 end end
                    return n
                end, E.ret("8", function(r) return r[1] == 8 end))
                local ID = '"mod":"skeltest"'
                case(P .. "chd-none", CALL .. "(\"input-control\") [direct]", direct("input-control"), E.reply("err:bad-request input-control needs a JSON object payload"))
                case(P .. "chd-brace", CALL .. "(\"input-control:{\") [direct]", direct("input-control:{"), E.reply("err:bad-request payload: "))
                case(P .. "chd-array", CALL .. "(\"input-control:[]\") [direct]", direct("input-control:[]"), E.reply("err:bad-request payload must be a JSON object"))
                case(P .. "chd-deep", CALL .. "(<nested object>) [direct]", direct('input-control:{' .. ID .. ',"id":{"a":1}}'), E.reply("err:bad-request payload: "))
                case(P .. "chd-nomod", CALL .. "(<no mod>) [direct]", direct('input-control:{"id":"x"}'), E.reply("err:bad-request mod must be a mod id"))
                case(P .. "chd-badmod", CALL .. "(<mod ..\\\\x>) [direct]", direct('input-control:{"mod":"..\\\\x","id":"x"}'), E.reply("err:bad-request mod must be a mod id"))
                case(P .. "chd-unknown", CALL .. "(<unknown field>) [direct]", direct('input-control:{' .. ID .. ',"id":"x","extra":1}'), E.reply("err:bad-request unknown key 'extra'"))
                case(P .. "chd-nearnull", CALL .. "(<near null>) [direct]", direct('input-control:{' .. ID .. ',"id":"x","action":"/Engine/Transient.X","label":"X","key":"F9","gamepad":"Gamepad_FaceButton_Right","near":null}'), E.reply("err:bad-request near must be a string or nil"))
                case(P .. "chd-keyclass", CALL .. "(<key a gamepad key>) [direct]", direct('input-control:{' .. ID .. ',"id":"x","action":"/Engine/Transient.X","label":"X","key":"Gamepad_FaceButton_Top","gamepad":"Gamepad_FaceButton_Right"}'), E.reply("err:bad-request key 'Gamepad_FaceButton_Top' is not a keyboard or mouse key"))
                case(P .. "chd-rel-noid", CALL .. "(\"input-release:{mod}\") [direct]", direct('input-release:{' .. ID .. '}'), E.reply("err:bad-request id must be a string, got nil"))
                case(P .. "chd-rel-all-false", CALL .. "(<all false>) [direct]", direct('input-release:{' .. ID .. ',"all":false}'), E.reply("err:bad-request all must be true"))
                case(P .. "chd-rel-unknown", CALL .. "(<unknown id>) [direct]", direct('input-release:{' .. ID .. ',"id":"nope"}'), E.reply("ok:false"))
                case(P .. "chd-state-none", CALL .. "(\"input-state\") [direct]", direct("input-state"), E.reply("err:bad-request input-state needs a JSON object payload"))
                case(P .. "chd-state-unknown", CALL .. "(<state of an unknown id>) [direct]", direct('input-state:{' .. ID .. ',"id":"nope"}'), E.reply("err:unknown-control unknown control 'nope' (declare it with control first)"))
                case(P .. "chd-state-badid", CALL .. "(<state of a bad id>) [direct]", direct('input-state:{' .. ID .. ',"id":"A B"}'), E.reply("err:bad-request id 'A B' must match"))
                case(P .. "chd-list-none", CALL .. "(\"input-list\") [direct]", direct("input-list"), E.reply("err:bad-request input-list needs a JSON object payload"))
                case(P .. "chd-list-extra", CALL .. "(<list with an id>) [direct]", direct('input-list:{' .. ID .. ',"id":"x"}'), E.reply("err:bad-request unknown key 'id'"))
                local garbage = {}
                for i = 1, 200 do garbage[i] = string.char(math.random(1, 127)) end
                case(P .. "chd-garbage", CALL .. "(\"input-control:\"..<200 random ASCII bytes>) [direct]", direct("input-control:" .. table.concat(garbage)), E.reply("err:"))
                case(P .. "chd-long", CALL .. "(\"input-control:\"..<4100 bytes>) [direct]", direct("input-control:" .. string.rep("{", 4100)), E.reply("err:too-long "))
            end
            -- release, state, list
            local R, S, L = FN .. "release: ", FN .. "state: ", FN .. "list: "
            case(P .. "r-none", "input.release()", function() return IN.release() end, E.err(R .. "expected 1 argument (id), got 0"))
            case(P .. "r-two", "input.release('a', 'b')", function() return IN.release("a", "b") end, E.err(R .. "expected 1 argument (id), got 2"))
            case(P .. "r-num", "input.release(5)", function() return IN.release(5) end, E.err(R .. "id must be a string, got 5"))
            case(P .. "r-bad", "input.release('Bad')", function() return IN.release("Bad") end, E.err(R .. "id 'Bad' must match"))
            case(P .. "r-unknown", "input.release('nope')", function() return IN.release("nope") end, E.ret("false", function(r) return r[1] == false end))
            case(P .. "s-none", "input.state()", function() return IN.state() end, E.err(S .. "expected 1 argument (id), got 0"))
            case(P .. "s-nil", "input.state(nil)", function() return IN.state(nil) end, E.err(S .. "id must be a string, got nil"))
            case(P .. "s-table", "input.state({})", function() return IN.state({}) end, E.err(S .. "id must be a string, got table"))
            case(P .. "s-unknown", "input.state('nope')", function() return IN.state("nope") end, E.err(S .. "unknown control 'nope' (declare it with control first)"))
            case(P .. "l-arg", "input.list(1)", function() return IN.list(1) end, E.err(L .. "takes no arguments"))
            case(P .. "l-ok", "input.list()", function() return IN.list() end, E.ret("an empty list (everything released)", function(r) return type(r[1]) == "table" and #r[1] == 0 end))
            case(P .. "has", "core.has('input.control')", function() return core().has("input.control"), core().has("input") end,
                E.ret("true, true", function(r) return r[1] == true and r[2] == true end))
        end)
    end

    function CT.offThread(P)
        local IN = core().input
        if type(IN) ~= "table" then return end
        case(P .. "off-in-control", "input.control{...} [off thread]", function() return IN.control(with({ id = "off" })) end, E.err(FN .. "control: called off the game thread"))
        case(P .. "off-in-release", "input.release('x') [off thread]", function() return IN.release("x") end, E.err(FN .. "release: called off the game thread"))
        case(P .. "off-in-state", "input.state('x') [off thread]", function() return IN.state("x") end, E.err(FN .. "state: called off the game thread"))
        case(P .. "off-in-list", "input.list() [off thread]", function() return IN.list() end, E.err(FN .. "list: called off the game thread"))
    end

    -- ---------------------------------------------------------------- the scenarios
    local C = {} -- what later steps need: plain values only

    local function declareToggle()
        return core().input.control{ id = "toggle", action = IA.toggle, label = "Skel Toggle", key = "F9", gamepad = "Gamepad_FaceButton_Right", near = "Sprint" }
    end

    -- The dead row skeltest:gone: its own context, registered by the test (not core), J mapped, saved, unregistered.
    local function writeGone()
        local us = settings()
        if not us then error("no user settings", 0) end
        local ia = buildIA(IA.gone)
        local pm = try(function() return ia.PlayerMappableKeySettings end)
        if not valid(pm) then pm = StaticConstructObject(found("/Script/EnhancedInput.PlayerMappableKeySettings"), ia, FName("PMKS_SkelTestGone"), flags()) end
        pm.Name = FName(GONE)
        pm.DisplayName = FText("Skel Gone")
        pm.DisplayCategory = FText("General")
        ia.PlayerMappableKeySettings = pm
        local imc = found("/Engine/Transient.IMC_SkelTestGone")
        if not imc then imc = StaticConstructObject(found("/Script/EnhancedInput.InputMappingContext"), found("/Engine/Transient"), FName("IMC_SkelTestGone"), flags()) end
        imc:UnmapAll()
        imc:MapKey(ia, { KeyName = FName("F8") })
        us:RegisterInputMappingContext(imc)
        us:MapPlayerKey({ MappingName = FName(GONE), Slot = 0, NewKey = { KeyName = FName("J") }, HardwareDeviceId = FName("None"),
            ProfileIdString = "", bCreateMatchingSlotIfNeeded = true, bDeferOnSettingsChangedBroadcast = false }, {})
        us:ApplySettings()
        us:SaveSettings()
        us:UnregisterInputMappingContext(imc)
    end

    -- owned's action: key settings already named OWNER, so core must refuse it and leave the name alone
    local function buildOwned()
        local ia = buildIA(IA.owned)
        local pm = StaticConstructObject(found("/Script/EnhancedInput.PlayerMappableKeySettings"), ia, FName("PMKS_SkelTestOwned"), flags())
        pm.Name = FName(OWNER)
        ia.PlayerMappableKeySettings = pm
    end
    local function ownerOf(path)
        local ia = found(path)
        local pm = ia and try(function() return ia.PlayerMappableKeySettings end)
        return valid(pm) and try(function() return pm.Name:ToString() end) or "-"
    end

    local function waitActive(tag, id, sec)
        step(tag .. ": " .. id .. " active", function()
            return function() local e = listEntry(id) return e ~= nil and e.active end, sec or 15, tag .. " " .. id .. " active"
        end)
    end

    local function capture(tag, selector, key, viaSet)
        step(tag .. ": focus " .. selector, function()
            local t
            for _, r in ipairs(rows()) do if r.name == TOGGLE then t = r end end
            local row = t and found(t.path)
            local sel = row and try(function() return row[selector] end)
            if not valid(sel) then check(false, "CTCAPTURE %s %s found", tag, selector) C.noCapture = true return end
            C.noCapture = false
            C.sel = pathOf(sel)
            local ok, err = pcall(function() sel:SetKeyboardFocus() end)
            check(ok and try(function() return sel:HasKeyboardFocus() end) == true, "CTCAPTURE %s %s has keyboard focus%s", tag, selector, ok and "" or (" (" .. firstLine(err) .. ")"))
            return msAfter(0.5), 2
        end)
        step(tag .. ": Enter on " .. selector, function()
            if C.noCapture then return end
            return X.request("key ENTER"), 40, tag .. " Enter"
        end)
        step(tag .. ": selecting", function() if C.noCapture then return end return msAfter(1), 2 end)
        step(tag .. ": " .. key .. " into " .. selector, function()
            if C.noCapture then return end
            local sel = found(C.sel)
            local selecting = try(function() return sel:GetIsSelectingKey() end)
            check(selecting == true, "CTCAPTURE %s %s is selecting a key after Enter (%s)", tag, selector, tostring(selecting))
            if viaSet then
                -- what a gamepad press does in the selector (the VM has no gamepad): the Slate selector reports the key
                local ok, err = pcall(function() sel:SetSelectedKey({ Key = { KeyName = FName(key) }, bShift = false, bCtrl = false, bAlt = false, bCmd = false }) end)
                check(ok, "CTCAPTURE %s SetSelectedKey(%s)%s", tag, key, ok and "" or (" failed: " .. firstLine(err)))
                return msAfter(1), 2
            end
            return X.request("key " .. key), 40, tag .. " key " .. key
        end)
        step(tag .. ": settle", function() if C.noCapture then return end return msAfter(1.5), 3 end)
    end

    local function controls()
        local W = X.waitWorld
        W("menu1", "NewMainMenu", 240)
        step("menu1: settle", function() return msAfter(4), 6 end)
        step("menu1: setup", function()
            local before = savText()
            check(before == nil or not before:find(MOD .. ":", 1, true), "CTSAV menu1 no skeltest row saved before the run (%s)", before and (#before .. " bytes") or "no .sav")
            local okB, errB = pcall(function() buildIA(IA.toggle) buildIA(IA.far) end)
            check(okB and found(IA.toggle) ~= nil and found(IA.far) ~= nil, "CTSETUP menu1 runtime actions built%s", okB and "" or (" (" .. firstLine(errB) .. ")"))
            local okG, errG = pcall(writeGone)
            local sav = savText()
            check(okG and sav ~= nil and sav:find(GONE, 1, true) ~= nil, "CTSETUP menu1 the dead row %s written and saved%s", GONE, okG and "" or (" (" .. firstLine(errG) .. ")"))
            local IN = core().input
            check(declareToggle() == true, "CTDECLARE toggle (F9, Gamepad_FaceButton_Right, near Sprint)")
            check(IN.control{ id = "far", action = IA.far, label = "Skel Far", key = "F7", gamepad = "Gamepad_DPad_Down", near = "NoSuchRow" } == true, "CTDECLARE far (near a row that doesn't exist)")
            check(IN.control{ id = "notia", action = NOTIA, label = "Skel Not IA", key = "F6", gamepad = "Gamepad_DPad_Up" } == true, "CTDECLARE notia (not an InputAction; accepted, refused at runtime)")
            check(IN.control{ id = "later", action = IA.later, label = "Skel Later", key = "F5", gamepad = "Gamepad_DPad_Left", near = "Jump" } == true, "CTDECLARE later (its action doesn't exist yet)")
            local okO, errO = pcall(buildOwned)
            check(okO and ownerOf(IA.owned) == OWNER, "CTSETUP menu1 owned's action built with key settings named %s%s", OWNER, okO and "" or (" (" .. firstLine(errO) .. ")"))
            check(IN.control{ id = "owned", action = IA.owned, label = "Skel Owned", key = "F3", gamepad = "Gamepad_DPad_Right" } == true, "CTDECLARE owned (its action belongs to another row; accepted, refused at runtime)")
        end)
        waitActive("menu1", "toggle")
        waitActive("menu1", "far")
        step("menu1: declared state", function()
            local t = listEntry("toggle")
            check(t and t.key == "F9" and t.gamepad == "Gamepad_FaceButton_Right", "CTLIST menu1 toggle F9 / Gamepad_FaceButton_Right (%s / %s)", t and t.key or "-", t and t.gamepad or "-")
            local q = queryKeys(IA.toggle)
            check(hasKey(q, "F9") and hasKey(q, "Gamepad_FaceButton_Right"), "CTQUERY menu1 QueryKeysMappedToAction(toggle) = %s", q)
            local n, l = listEntry("notia"), listEntry("later")
            check(n and not n.active and l and not l.active, "CTLIST menu1 notia and later inactive (%s, %s)", tostring(n and n.active), tostring(l and l.active))
            local o = listEntry("owned")
            check(o and not o.active and ownerOf(IA.owned) == OWNER, "CTOWNED menu1 owned inactive and its action's row name unchanged (%s, %s)", tostring(o and o.active), ownerOf(IA.owned))
            local okS, s = pcall(core().input.state, "toggle")
            check(okS and s == false, "CTSTATE menu1 toggle not triggered (%s)", tostring(s))
        end)
        -- the first page
        step("menu1: open page", function() openPage("menu1") return msAfter(1.5), 3 end)
        step("menu1: controls tab", function() check(showControls(), "CTPAGE menu1 Controls tab shown") return waitPass("menu1") end)
        step("menu1: page", function()
            pageChecks("menu1", { k0 = "F9", k1 = "Gamepad_FaceButton_Right", visible = { [TOGGLE] = true, [MOD .. ":far"] = true }, hidden = { GONE } })
            local list = rows()
            local far = rowOf(list, MOD .. ":far")
            check(far ~= nil and far.box == "General" and far.index == boxCount("General") - 1, "CTPLACE menu1 far at the end of General (%s[%s] of %d)", far and far.box or "-", far and far.index or "-", boxCount("General"))
            return X.request("shot ct-menu1"), 40, "shot"
        end)
        -- the probe's surprise, reproduced on far: a keyboard key in the gamepad slot leaves the gamepad default live
        step("menu1: surprise", function()
            local us = settings()
            pcall(function()
                us:MapPlayerKey({ MappingName = FName(MOD .. ":far"), Slot = 1, NewKey = { KeyName = FName("L") }, HardwareDeviceId = FName("None"),
                    ProfileIdString = "", bCreateMatchingSlotIfNeeded = true, bDeferOnSettingsChangedBroadcast = false }, {})
                us:ApplySettings()
            end)
            return msAfter(0.5), 2
        end)
        step("menu1: surprise keys", function()
            local q = queryKeys(IA.far)
            say("CTSURPRISE far: L into the gamepad slot -> keys %s (gamepad default still live: %s)", q, tostring(hasKey(q, "Gamepad_DPad_Down")))
        end)
        capture("menu1 keyboard", "InputKeySelector_128", "K", false)
        step("menu1: after K", function()
            local t = listEntry("toggle")
            local q = queryKeys(IA.toggle)
            check(t and t.key == "K", "CTCAPKEY menu1 list() reports key K (%s)", t and t.key or "-")
            check(hasKey(q, "K") and not hasKey(q, "F9"), "CTCAPKEY menu1 QueryKeysMappedToAction holds K and not F9 (%s)", q)
        end)
        capture("menu1 gamepad", "InputKeySelector", "Gamepad_FaceButton_Top", true)
        step("menu1: after gamepad", function()
            local t = listEntry("toggle")
            local q = queryKeys(IA.toggle)
            check(t and t.gamepad == "Gamepad_FaceButton_Top", "CTCAPPAD menu1 list() reports gamepad Gamepad_FaceButton_Top (%s)", t and t.gamepad or "-")
            check(hasKey(q, "Gamepad_FaceButton_Top") and not hasKey(q, "Gamepad_FaceButton_Right"), "CTCAPPAD menu1 the replaced button is no longer live (%s)", q)
            closePage()
            -- later's action exists now; the next open retries it
            local okB = pcall(buildIA, IA.later)
            check(okB and found(IA.later) ~= nil, "CTSETUP menu1 later's action built")
            return msAfter(1), 2
        end)
        step("menu1: open page 2", function() openPage("menu1b") return msAfter(1.5), 3 end)
        step("menu1: controls tab 2", function() check(showControls(), "CTPAGE menu1b Controls tab shown") return waitPass("menu1b") end)
        step("menu1: page 2", function()
            pageChecks("menu1b", { k0 = "K", k1 = "Gamepad_FaceButton_Top", visible = { [TOGGLE] = true, [MOD .. ":far"] = true }, hidden = { GONE } })
        end)
        waitActive("menu1", "later", 10)
        -- a registry change while the page is open: core's "controls changed" pass hides a released row and shows it
        -- again once the control is declared again and active
        local FAR = MOD .. ":far"
        local function declareFar() return core().input.control{ id = "far", action = IA.far, label = "Skel Far", key = "F7", gamepad = "Gamepad_DPad_Down", near = "NoSuchRow" } end
        step("menu1: release far (page open)", function()
            check(core().input.release("far") == true, "CTLIVE menu1 far released with the page open")
            return msAfter(2), 4
        end)
        step("menu1: far hidden", function()
            local r = rowOf(rows(), FAR)
            check(r ~= nil and not r.visible, "CTLIVE menu1 far's row collapsed by the next pass (%s)", r and ("visible=" .. tostring(r.visible)) or "missing")
            check(declareFar() == true, "CTLIVE menu1 far declared again")
        end)
        waitActive("menu1", "far", 10)
        step("menu1: far pass", function() return msAfter(2), 4 end)
        step("menu1: far shown", function()
            local r = rowOf(rows(), FAR)
            check(r ~= nil and r.visible, "CTLIVE menu1 far's row visible again once active (%s)", r and ("visible=" .. tostring(r.visible)) or "missing")
        end)
        step("menu1: close", function() closePage() return msAfter(1), 2 end)
        -- later2: declared before its action exists, the action built just before the travel with no page opened in
        -- between, so only the map load's retry can activate it
        step("menu1: declare later2", function()
            check(core().input.control{ id = "later2", action = IA.later2, label = "Skel Later Two", key = "F2", gamepad = "Gamepad_DPad_Up" } == true, "CTDECLARE later2 (its action doesn't exist yet)")
            return msAfter(1.5), 3
        end)
        step("menu1: build later2", function()
            local l = listEntry("later2")
            check(l and not l.active, "CTLIST menu1 later2 inactive before the travel (%s)", tostring(l and l.active))
            local okB = pcall(buildIA, IA.later2)
            check(okB and found(IA.later2) ~= nil, "CTSETUP menu1 later2's action built")
        end)
        -- Tower Island
        X.travel("match1", X.MATCH_MAP, "listen")
        W("match1", "SmallMap", 180)
        step("match1: pawn", function()
            return function()
                local c = pc()
                local p = c and try(function() return c:K2_GetPawn() end)
                return valid(p) and classOf(p) == "BP_FirstPersonCharacter_C"
            end, 180, "match1 pawn"
        end)
        step("match1: settle", function() return msAfter(4), 6 end)
        step("match1: context again", function()
            return function() return hasKey(queryKeys(IA.toggle), "K") end, 15, "match1 toggle's keys live again after the map load"
        end)
        step("match1: idle", function()
            local q = queryKeys(IA.toggle)
            check(hasKey(q, "K") and hasKey(q, "Gamepad_FaceButton_Top"), "CTMATCH match1 toggle's context added again: %s", q)
            local okS, s = pcall(core().input.state, "toggle")
            check(okS and s == false, "CTSTATE match1 idle: false (%s)", tostring(s))
            local l, ql = listEntry("later2"), queryKeys(IA.later2)
            check(l and l.active and hasKey(ql, "F2"), "CTRETRY match1 later2 active after the map load (%s, %s)", tostring(l and l.active), ql)
        end)
        step("match1: keydown K", function() return X.request("keydown K"), 40, "keydown K" end)
        step("match1: hold", function() return msAfter(0.8), 2 end)
        step("match1: held", function()
            local okS, s = pcall(core().input.state, "toggle")
            check(okS and s == true, "CTSTATE match1 K held: true (%s)", tostring(s))
        end)
        step("match1: keyup K", function() return X.request("keyup K"), 40, "keyup K" end)
        step("match1: release settle", function() return msAfter(0.8), 2 end)
        step("match1: released", function()
            local okS, s = pcall(core().input.state, "toggle")
            check(okS and s == false, "CTSTATE match1 K released: false (%s)", tostring(s))
            check(core().input.release("far") == true, "CTRELEASE match1 far released")
            -- far's action, declared again under another id: core takes back the row name it gave it for far
            check(core().input.control{ id = "far2", action = IA.far, label = "Skel Far Two", key = "F4", gamepad = "Gamepad_DPad_Right" } == true, "CTDECLARE far2 (far's action under a new id)")
            return msAfter(1), 2
        end)
        waitActive("match1", "far2", 10)
        step("match1: far2", function()
            local q = queryKeys(IA.far)
            check(ownerOf(IA.far) == MOD .. ":far2" and hasKey(q, "F4") and not hasKey(q, "F7"), "CTRECLAIM match1 far's action now belongs to far2 (%s, %s)", ownerOf(IA.far), q)
        end)
        step("match1: open page", function() openPage("match1") return msAfter(1.5), 3 end)
        step("match1: controls tab", function() check(showControls(), "CTPAGE match1 Controls tab shown") return waitPass("match1") end)
        step("match1: page", function()
            pageChecks("match1", { k0 = "K", k1 = "Gamepad_FaceButton_Top", visible = { [TOGGLE] = true, [MOD .. ":later"] = true, [MOD .. ":later2"] = true, [MOD .. ":far2"] = true }, hidden = { GONE, MOD .. ":far" } })
            return X.request("shot ct-match1"), 40, "shot"
        end)
        step("match1: close", function() closePage() return msAfter(1), 2 end)
        step("match1: sav", function()
            local sav = savText()
            check(sav ~= nil and sav:find(TOGGLE, 1, true) ~= nil and sav:find(GONE, 1, true) ~= nil, "CTSAV match1 the .sav holds %s and %s", TOGGLE, GONE)
        end)
    end

    local function restart()
        local W = X.waitWorld
        W("menu1", "NewMainMenu", 240)
        step("menu1: settle", function() return msAfter(4), 6 end)
        step("menu1: declare again", function()
            local sav = savText()
            check(sav ~= nil and sav:find(TOGGLE, 1, true) ~= nil and sav:find(GONE, 1, true) ~= nil, "CTSAV restart the .sav from controls holds %s and %s", TOGGLE, GONE)
            pcall(buildIA, IA.toggle)
            check(declareToggle() == true, "CTDECLARE restart toggle again with its defaults (F9, Gamepad_FaceButton_Right)")
        end)
        waitActive("restart", "toggle")
        step("restart: keys", function()
            local t = listEntry("toggle")
            local q = queryKeys(IA.toggle)
            check(t and t.key == "K" and t.gamepad == "Gamepad_FaceButton_Top", "CTRESTART list() reports K / Gamepad_FaceButton_Top (%s / %s)", t and t.key or "-", t and t.gamepad or "-")
            check(hasKey(q, "K") and not hasKey(q, "F9") and hasKey(q, "Gamepad_FaceButton_Top"), "CTRESTART QueryKeysMappedToAction holds K and not F9 (%s)", q)
        end)
        step("restart: open page", function() openPage("restart") return msAfter(1.5), 3 end)
        step("restart: controls tab", function() check(showControls(), "CTPAGE restart Controls tab shown") return waitPass("restart") end)
        step("restart: page", function()
            pageChecks("restart", { k0 = "K", k1 = "Gamepad_FaceButton_Top", visible = { [TOGGLE] = true }, hidden = { GONE } })
            local g = rowOf(rows(), GONE)
            say("CTGONE restart %s in %s (label %q)", GONE, g and g.box or "-", g and g.label or "-")
            return X.request("shot ct-restart"), 40, "shot"
        end)
        step("restart: close", function() closePage() return msAfter(1), 2 end)
        step("restart: sav", function()
            local sav = savText()
            check(sav ~= nil and sav:find(GONE, 1, true) ~= nil, "CTSAV restart the .sav still holds %s", GONE)
        end)
    end

    function CT.build(scenario)
        if scenario == "controls-restart" then restart() else controls() end
    end

    return CT
end
