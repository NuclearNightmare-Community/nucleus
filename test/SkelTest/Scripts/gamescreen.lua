-- <Core>SkelTest's game-screen part (core story 31, UI-13: core.ui.game and the createServer host), loaded by main.lua
-- with dofile (main.lua is at Lua's 200-locals limit). Returns a function taking main.lua's helpers and returning:
--   cases(phase)        the ui-game-* bad-input cases as one step (every error row of the story's I/O matrix, plus
--                       the control calls); in bad-input (menu1, match1) and in createserver (menu1)
--   offThread(P)        every core.ui.game function off the game thread (inside a LoopAsync block)
--   offThreadStep(phase) offThread on its own LoopAsync, as one step (createserver; bad-input uses main.lua's block)
--   preConnect()        the game functions called before connect (recorded during main.lua in createserver)
--   build()             the createserver scenario, written for the VM at 1280x720 (run.ps1 -Target vm): a watcher, a
--                       text and a checkbox on host createServer before any key; ten times a real click on START GAME,
--                       opened and the text in the screen's root canvas (a new widget each open), a real click on Back,
--                       closed; on the third open a real click on the checkbox (onChange once). Then the bad-input
--                       group, START GAME once more, the session type set to Friends-Only through the screen's own box
--                       (never a public session: Create is not clicked unless the screen says FriendsOnly), a real
--                       click on Create, a non-menu world, closed or lost for that screen; at least 20 s in the match
--                       with the tick profiler on, until one whole one-minute hud tick window lies in it (CSMATCH lines
--                       around it, judged by check.ps1); then menu2 and one more open (opened) and Back.
-- Never keeps a UObject across steps: each step finds what it needs again; only paths and counts are kept.
return function(X)
    local GS = {}
    local case, E, step, check, say, CORE = X.case, X.E, X.step, X.check, X.say, X.CORE
    local LOWER = CORE:lower()
    local FN = LOWER .. ".ui.game."
    local HOST = "createServer"
    local CS_SHORT, MENU_SHORT, START = "CreateServer_C", "MainMenu_C", "UI_Button_Master"
    -- MultipleSelectBox_C's arrows (mods/random-mode's driver): the box's own handlers, which broadcast the selection.
    local BOX_NEXT = "BndEvt__MultipleSelectBox_Button_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
    local BOX_PREV = "BndEvt__MultipleSelectBox_Button_60_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature"
    local OPENS = 10
    local function core() return X.core() end
    local function firstLine(e) return (tostring(e):match("^[^\n]*")) end
    local function try(f) local ok, v = pcall(f) if ok then return v end return nil end
    local function v(o) return o ~= nil and try(function() return o:IsValid() end) == true end
    local function prop(o, k) if not v(o) then return nil end local p = try(function() return o[k] end) return v(p) and p or nil end
    local function pathOf(o) return v(o) and try(function() return (o:GetFullName():gsub("^%S+ ", "")) end) or nil end
    local function fname(o) return v(o) and try(function() return o:GetFName():ToString() end) or "?" end
    local function str(x) return try(function() return x:ToString() end) end
    local function msAfter(sec) local t = os.clock() + sec return function() return os.clock() >= t end end
    local function liveOf(short)
        for _, w in ipairs(FindAllOf(short) or {}) do
            if v(w) and try(function() return w:IsInViewport() end) then return w end
        end
        return nil
    end
    local function center(r) return math.floor((r.l + r.r) / 2 + 0.5), math.floor((r.t + r.b) / 2 + 0.5) end
    local function rootOf(s) local t = try(function() return s.WidgetTree end) return t and prop(t, "RootWidget") or nil end

    -- ---------------------------------------------------------------- bad input
    function GS.cases(phase)
        step(phase .. ": game cases", function()
            local U = core().ui
            local G = U.game
            if not check(type(G) == "table", "CASE %s.ui-game core.ui.game exists", phase) then return end
            local P = phase .. ".ui-game-"
            local f = function(fn, ...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end
            local nop = function() end
            local VALID = "(valid: createServer)"
            case(P .. "watch-nope", "ui.game.watch('nope', fn)", f(G.watch, "nope", nop), E.err(FN .. "watch: unknown game screen 'nope' " .. VALID))
            case(P .. "watch-num", "ui.game.watch(1, fn)", f(G.watch, 1, nop), E.err(FN .. "watch: unknown game screen 1 " .. VALID))
            case(P .. "watch-nil", "ui.game.watch(nil, fn)", f(G.watch, nil, nop), E.err(FN .. "watch: unknown game screen nil " .. VALID))
            case(P .. "watch-menu", "ui.game.watch('menu', fn) [a host, not a game screen]", f(G.watch, "menu", nop), E.err(FN .. "watch: unknown game screen 'menu' " .. VALID))
            case(P .. "watch-case", "ui.game.watch('CreateServer', fn) [names are case-sensitive]", f(G.watch, "CreateServer", nop), E.err(FN .. "watch: unknown game screen 'CreateServer' " .. VALID))
            case(P .. "isopen-menu", "ui.game.isOpen('menu')", f(G.isOpen, "menu"), E.err(FN .. "isOpen: unknown game screen 'menu' " .. VALID))
            case(P .. "isopen-nil", "ui.game.isOpen()", f(G.isOpen), E.err(FN .. "isOpen: unknown game screen nil " .. VALID))
            case(P .. "isopen-table", "ui.game.isOpen({})", f(G.isOpen, {}), E.err(FN .. "isOpen: unknown game screen table " .. VALID))
            case(P .. "isopen-two", "ui.game.isOpen('createServer', 1)", f(G.isOpen, HOST, 1), E.err(FN .. "isOpen: expected 1 argument (host), got 2"))
            case(P .. "watch-fn5", "ui.game.watch('createServer', 5)", f(G.watch, HOST, 5), E.err(FN .. "watch: fn must be a function, got 5"))
            case(P .. "watch-nofn", "ui.game.watch('createServer')", f(G.watch, HOST), E.err(FN .. "watch: fn must be a function, got nil"))
            case(P .. "watch-fnstr", "ui.game.watch('createServer', 'f')", f(G.watch, HOST, "f"), E.err(FN .. "watch: fn must be a function, got 'f'"))
            case(P .. "watch-three", "ui.game.watch('createServer', fn, 1)", f(G.watch, HOST, nop, 1), E.err(FN .. "watch: expected 2 arguments (host, fn), got 3"))
            case(P .. "unwatch-forged", "ui.game.unwatch(99999)", f(G.unwatch, 99999), E.err(FN .. "unwatch: unknown token 99999 (not one game.watch returned)"))
            local okM, mt = pcall(U.menu.watch, nop)
            if okM then
                case(P .. "unwatch-menutoken", "ui.game.unwatch(<a menu.watch token>)", f(G.unwatch, mt), E.err(FN .. "unwatch: unknown token " .. tostring(mt) .. " (not one game.watch returned)"))
                pcall(U.menu.unwatch, mt)
            else
                check(false, "CASE %sunwatch-menutoken could not get a menu.watch token: %s", P, firstLine(mt))
            end
            case(P .. "unwatch-float", "ui.game.unwatch(1.5)", f(G.unwatch, 1.5), E.err(FN .. "unwatch: token must be an integer, got 1.5"))
            case(P .. "unwatch-str", "ui.game.unwatch('1')", f(G.unwatch, "1"), E.err(FN .. "unwatch: token must be an integer, got '1'"))
            case(P .. "unwatch-nil", "ui.game.unwatch(nil)", f(G.unwatch, nil), E.err(FN .. "unwatch: token must be an integer, got nil"))
            case(P .. "unwatch-two", "ui.game.unwatch(1, 2)", f(G.unwatch, 1, 2), E.err(FN .. "unwatch: expected 1 argument (token), got 2"))
            -- the placement rules on the new host: near refused (like menu and screen), a region refused, no named elements
            case(P .. "place-near", "ui.text.create{ place = { host = 'createServer', near = 'crosshair' } }",
                f(U.text.create, { id = "gnear", place = { host = HOST, near = "crosshair" } }), E.err(LOWER .. ".ui.place: near is not available on host 'createServer' (corner or absolute)"))
            case(P .. "place-region", "ui.text.create{ place = { host = 'createServer', corner, region = 'map' } }",
                f(U.text.create, { id = "gnear", place = { host = HOST, corner = "top-left", region = "map" } }), E.err(LOWER .. ".ui.place: region is not available on host 'createServer' (journal only)"))
            case(P .. "elements", "ui.elements('createServer')", f(U.elements, HOST),
                E.ret("an empty table", function(r) return type(r[1]) == "table" and next(r[1]) == nil end))
            -- controls: isOpen (no screen open here), a watch and its unwatch (twice), core.has
            case(P .. "isopen-ok", "ui.game.isOpen('createServer') [none open]", f(G.isOpen, HOST), E.ret("false", function(r) return r.n == 1 and r[1] == false end))
            local tok
            case(P .. "watch-ok", "ui.game.watch('createServer', fn) [control]", function() tok = G.watch(HOST, nop) return tok end,
                E.ret("an integer token", function(r) return math.type(r[1]) == "integer" end))
            if tok then
                case(P .. "unwatch-ok", "ui.game.unwatch(<its token>)", f(G.unwatch, tok), E.none)
                case(P .. "unwatch-again", "ui.game.unwatch(<its token>) [again]", f(G.unwatch, tok), E.none)
            end
            case(P .. "has", "core.has('ui.game.createServer'), core.has('ui.game')", function() return core().has("ui.game.createServer"), core().has("ui.game") end,
                E.ret("true, true", function(r) return r[1] == true and r[2] == true end))
        end)
    end

    function GS.offThread(P)
        local G = core().ui.game
        if type(G) ~= "table" then return end
        for _, c in ipairs({ { "watch", HOST, function() end }, { "unwatch", 1 }, { "isOpen", HOST } }) do
            case(P .. "off-ui-game-" .. c[1]:lower(), "ui.game." .. c[1] .. "(...) [off thread]", function() return G[c[1]](c[2], c[3]) end,
                E.err(FN .. c[1] .. " called off the game thread"))
        end
    end

    function GS.offThreadStep(phase)
        step(phase .. ": game off-thread cases", function()
            local done = false
            LoopAsync(10, function()
                local ok, err = pcall(GS.offThread, phase .. ".")
                if not ok then check(false, "CASE %s.off-game off-thread block threw: %s", phase, firstLine(err)) end
                done = true
                return true
            end)
            return function() return done end, 10, "game off-thread cases"
        end)
    end

    function GS.preConnect()
        step("game before-connect cases", function()
            local list = X.PRE_CONNECT.game or {}
            for _, r in ipairs(list) do
                case(r.id, "ui.game." .. r.fn .. "(...) [before connect]", function() if not r.ok then error(r.err, 0) end return "no error" end,
                    E.err(LOWER .. ".ui: game." .. r.fn .. " called before connect"))
            end
            check(#list == 3, "CASES game before-connect recorded=%d (expected 3)", #list)
        end)
    end

    -- ---------------------------------------------------------------- the createserver scenario
    function GS.build()
        local S = { ev = {}, opens = {}, textPaths = {}, cb = 0, windows = 0 }
        local function count(e) local n = 0 for _, x in ipairs(S.ev) do if x.event == e then n = n + 1 end end return n end
        local function lastOf(e) for i = #S.ev, 1, -1 do if S.ev[i].event == e then return S.ev[i] end end return nil end
        local function screen() return liveOf(CS_SHORT) end
        local function startButton() return prop(liveOf(MENU_SHORT), START) end
        local function clickOn(label, finder)
            step("cs: click " .. label, function()
                local w = finder()
                local r = w and X.absR(w)
                if not check(r ~= nil and r.r > r.l, "CSPOINT %s has a screen rectangle", label) then return end
                local x, y = center(r)
                say("CSCLICKREQ %s at (%d,%d)", label, x, y)
                return X.request(string.format("click %d %d", x, y)), 40, "click " .. label
            end)
        end
        local function shot(label) step("cs: shot " .. label, function() return X.request("shot " .. label), 30, "screenshot " .. label end) end

        -- One open: a real click on START GAME, opened (the n-th), the text and the checkbox in the screen's root canvas.
        local function openOnce(tag, n)
            clickOn(tag .. " START GAME " .. n, startButton)
            step("cs: " .. tag .. " opened " .. n, function()
                return function() return count("opened") >= n end, 10, tag .. " opened " .. n
            end)
            step("cs: " .. tag .. " attached " .. n, function()
                local e = lastOf("opened")
                local s = screen()
                local sp = pathOf(s)
                local canvas = s and rootOf(s)
                local tw, nT = nil, 0
                local cw, nC = nil, 0
                if canvas then tw, nT = X.taggedIn(canvas, "cs-text"); cw, nC = X.taggedIn(canvas, "cs-check") end
                local tp = pathOf(tw)
                local new = tp ~= nil and not S.textPaths[tp]
                if tp then S.textPaths[tp] = true end
                S.opens[n] = e and e.path
                local shown, isOpen = core().ui.text.isShown(S.text), core().ui.game.isOpen(HOST)
                check(e ~= nil and e.path == sp and e.hasScreen and e.host == HOST and fname(canvas) == "CanvasPanel_21" and nT == 1 and nC == 1 and new and shown and isOpen,
                    "CSOPENED %d %s: opened path=%s (live screen %s), text and checkbox once each in its %s (%d, %d), a new text widget %s, isShown=%s, isOpen=%s",
                    n, tag, tostring(e and e.path), tostring(sp), fname(canvas), nT, nC, tostring(tp), tostring(shown), tostring(isOpen))
            end)
        end
        -- A real click on the screen's own Back; closed (the m-th) for the screen of open n.
        local function backOnce(tag, n, m)
            clickOn(tag .. " Back " .. n, function() return prop(screen(), "Back") end)
            step("cs: " .. tag .. " closed " .. n, function()
                return function() return count("closed") >= m end, 10, tag .. " closed " .. n
            end)
            step("cs: " .. tag .. " closed check " .. n, function()
                local e = S.ev[#S.ev]
                local shown, isOpen = core().ui.text.isShown(S.text), core().ui.game.isOpen(HOST)
                check(e ~= nil and e.event == "closed" and e.path == S.opens[n] and not e.hasScreen and not shown and not isOpen and screen() == nil,
                    "CSCLOSED-%s %d closed path=%s (opened %s), no screen passed, isShown=%s, isOpen=%s",
                    tag == "menu1" and "BACK" or tag:upper(), n, tostring(e and e.path), tostring(S.opens[n]), tostring(shown), tostring(isOpen))
            end)
        end

        step("cs: setup", function()
            local U = core().ui
            S.tok = U.game.watch(HOST, function(s, info)
                S.ev[#S.ev + 1] = { event = info.event, path = info.path, reason = info.reason, host = info.host, hasScreen = s ~= nil }
                say("CSEVENT %d %s host=%s path=%s reason=%s", #S.ev, tostring(info.event), tostring(info.host), tostring(info.path), tostring(info.reason))
            end)
            S.text = U.text.create{ id = "cs-text", text = "SKEL CREATE SERVER", place = { host = HOST, corner = "top-right" } }
            S.check = U.checkbox.create{ id = "cs-check", place = { host = HOST, corner = "top-right" },
                onChange = function(_, val) S.cb = S.cb + 1; S.cbv = val; say("CSCHANGE %d %s", S.cb, tostring(val)) end }
            check(S.tok ~= nil and S.text ~= nil and S.check ~= nil, "CSSETUP watcher, text and checkbox on host createServer before any key")
            -- Counts core's one-minute hud tick lines (DEBUG hud tick n=...) for the match's timing window; the logger is
            -- this mod's own (core.log), so the wrapper sees exactly the lines core writes with it.
            local log = core().log
            local orig = log.debug
            log.debug = function(fmt, ...)
                orig(fmt, ...)
                if type(fmt) == "string" and fmt:sub(1, 11) == "hud tick n=" then S.windows = S.windows + 1 end
            end
        end)
        X.waitWorld("menu1", "NewMainMenu", 120)
        -- The press-any-key screen takes keys only once it is up (the menu scenario's way).
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
        step("menu1: none open", function()
            check(core().ui.game.isOpen(HOST) == false and #S.ev == 0 and core().ui.text.isShown(S.text) == false,
                "CSNONE no create-server screen yet: isOpen=false, no event, text not shown")
        end)
        for i = 1, OPENS do
            openOnce("menu1", i)
            if i == 1 then shot("cs-open") end
            if i == 3 then
                step("cs: checkbox before", function() S.cb0 = S.cb end)
                clickOn("checkbox", function() local c = rootOf(screen()) return c and (X.taggedIn(c, "cs-check")) end)
                step("cs: checkbox settle", function() return msAfter(1), 3 end)
                step("cs: checkbox check", function()
                    check(S.cb == S.cb0 + 1 and S.cbv == true and core().ui.checkbox.get(S.check) == true,
                        "CSCHECK a real click on the checkbox on the create-server screen ran onChange once with true (%d call(s), %s)", S.cb - S.cb0, tostring(S.cbv))
                end)
            end
            backOnce("menu1", i, i)
        end
        step("menu1: ten opens", function()
            local seen, n = {}, 0
            for i = 1, OPENS do local p = S.opens[i] if p and not seen[p] then seen[p] = true; n = n + 1 end end
            check(count("opened") == OPENS and count("closed") == OPENS and count("lost") == 0,
                "CSEVENTS %d opens: opened=%d closed=%d lost=%d", OPENS, count("opened"), count("closed"), count("lost"))
            check(n == OPENS, "CSDISTINCT %d opens, %d distinct paths", OPENS, n)
            local tn = 0
            for _ in pairs(S.textPaths) do tn = tn + 1 end
            check(tn == OPENS, "CSNEWTEXT %d opens, %d distinct text widgets", OPENS, tn)
            check(count("lost") == 0, "CSNOLOST no lost before Create")
        end)

        -- The bad-input group: before connect (recorded in main.lua), on the game thread, off it.
        GS.preConnect()
        GS.cases("menu1")
        GS.offThreadStep("menu1")

        -- Create: a friends-only session only (a private Steam lobby; AGENTS.md "Networking"), then the map change.
        openOnce("create", OPENS + 1)
        step("create: friends-only", function()
            local s = screen()
            local box = prop(s, "MultipleSelectBox_4")
            if not check(box ~= nil, "CSFRIENDS the session type box MultipleSelectBox_4 found") then S.abort = true return end
            local function shown() return str(try(function() return box.SelectedOption end)) end
            local dir, clicks = BOX_NEXT, 0
            while shown() ~= "Friends-Only" and clicks < 6 do
                local before = shown()
                pcall(function() box[dir](box) end)
                clicks = clicks + 1
                if shown() == before then dir = BOX_PREV end -- the end of the list: go the other way
            end
            local fo = try(function() return s.FriendsOnly end)
            if not check(fo == true and shown() == "Friends-Only", "CSFRIENDS the screen is set to Friends-Only (FriendsOnly=%s, shown %s, %d click(s))",
                tostring(fo), tostring(shown()), clicks) then S.abort = true end
        end)
        step("create: click Create", function()
            S.preCreate, S.createPath = #S.ev, S.opens[OPENS + 1]
            if S.abort then check(false, "CSCREATE Create not clicked: the screen is not Friends-Only (a public session is never made)") return end
            local r = X.absR(prop(screen(), "Create"))
            if not check(r ~= nil and r.r > r.l, "CSPOINT Create has a screen rectangle") then S.abort = true return end
            local x, y = center(r)
            say("CSCLICKREQ Create at (%d,%d)", x, y)
            return X.request(string.format("click %d %d", x, y)), 40, "click Create"
        end)
        step("match: world", function()
            if S.abort then return end
            return function()
                local w = X.worldName()
                if w ~= "" and not w:find("NewMainMenu", 1, true) then say("WORLD match %s", w:match("/Game/[^ ]+") or "?") return true end
                return false
            end, 150, "a non-menu world after Create"
        end)
        step("match: screen event", function()
            if S.abort then return end
            return function()
                for i = S.preCreate + 1, #S.ev do
                    local e = S.ev[i]
                    if e.path == S.createPath and (e.event == "closed" or e.event == "lost") then S.createEv = e return true end
                end
                return false
            end, 30, "closed or lost after Create"
        end)
        step("match: settle", function() if S.abort then return end return msAfter(5), 10 end)
        step("match: create check", function()
            if S.abort then return end
            local e = S.createEv
            check(e ~= nil and core().ui.game.isOpen(HOST) == false and core().ui.text.isShown(S.text) == false,
                "CSCREATE after Create and the map change: %s for the screen %s (%s); isOpen=false, text not shown",
                tostring(e and e.event), tostring(S.createPath), tostring(e and e.reason))
        end)
        -- The poll's cost with no create-server screen: one whole one-minute hud tick window inside the match (the first
        -- line after the start can hold ticks from before it), at least 20 s.
        step("match: idle start", function()
            if S.abort then return end
            S.w0, S.t0 = S.windows, os.clock()
            say("CSMATCH start (hud tick windows so far %d)", S.w0)
            return function() return S.windows >= S.w0 + 1 end, 75, "first hud tick window line in the match"
        end)
        step("match: idle window", function()
            if S.abort then return end
            say("CSMATCH window 1 after %.0f s", os.clock() - S.t0)
            return function() return S.windows >= S.w0 + 2 and os.clock() - S.t0 >= 20 end, 75, "a whole hud tick window in the match"
        end)
        step("match: idle end", function()
            if S.abort then return end
            say("CSMATCH end after %.0f s (%d window line(s))", os.clock() - S.t0, S.windows - S.w0)
            check(core().ui.game.isOpen(HOST) == false, "CSMATCHNONE no create-server screen in the match")
        end)

        -- The next menu works: one more open (opened, elements attached) and Back.
        X.travel("menu2", X.MENU_MAP, "")
        X.waitWorld("menu2", "NewMainMenu", 150)
        step("menu2: menu", function() return function() return liveOf(MENU_SHORT) ~= nil end, 60, "menu2 menu" end)
        step("menu2: settle", function() S.closed2 = count("closed") return msAfter(3), 6 end)
        openOnce("menu2", OPENS + 2)
        shot("cs-menu2")
        clickOn("menu2 Back", function() return prop(screen(), "Back") end)
        step("cs: menu2 closed", function()
            return function() return count("closed") > S.closed2 end, 10, "menu2 closed"
        end)
        step("cs: menu2 closed check", function()
            local e = S.ev[#S.ev]
            check(e ~= nil and e.event == "closed" and e.path == S.opens[OPENS + 2] and not core().ui.game.isOpen(HOST),
                "CSMENU2 closed path=%s (opened %s)", tostring(e and e.path), tostring(S.opens[OPENS + 2]))
            pcall(core().ui.game.unwatch, S.tok)
        end)
    end

    return GS
end
