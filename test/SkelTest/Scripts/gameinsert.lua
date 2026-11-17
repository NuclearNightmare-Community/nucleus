-- <Core>SkelTest's game-container part (core story 32, UI-14: place { host = "createServer", container, after | before |
-- index | at }), loaded by main.lua with dofile after gamescreen.lua (main.lua is at Lua's 200-locals limit). Takes
-- main.lua's helpers plus GS (gamescreen.lua's module, for its shared helpers) and returns:
--   cases(phase)   the ui-ins-* bad-input cases as one step (every error row of the story's I/O matrix, plus the control
--                  calls); in bad-input (menu1, match1) and in gameinsert (menu1)
--   build()        the gameinsert scenario, written for the VM at 1280x720 (run.ps1 -Target vm): menu1; a real click on
--                  START GAME with no container element, VerticalBox_202 snapshotted (names, slot values); while open,
--                  a checkbox at the end, five texts after Overlay_28, fourteen after Overlay_738, one after an unknown
--                  anchor and one in an unknown container (none attached inside the call; all on the next tick, one
--                  rebuild for all); a real click on Back. Ten real opens: the order, the game rows' slot values
--                  against the snapshot, one rebuild per open, one widget per element (a new one each open); Back.
--                  Then one more open: CONFIGURE, a screenshot, the list scrolled to its end and a real click on the
--                  checkbox (onChange once), a real click on the Difficulty picker's arrow and on Lobby Time's (a
--                  rebuilt row), values changed; a preset saved under a unique name, Lobby Time changed, the preset
--                  loaded (Lobby Time restored) and deleted (the preset count back); with Lobby Time at a non-default
--                  value, two more texts after Overlay_28 made while open: on the next tick in place, one rebuild for
--                  both, Lobby Time still showing its value (core restores the rebuilt rows' pickers); CONFIRM, Back.
-- Never keeps a UObject across steps: each step finds what it needs again; only paths, names and counts are kept.
-- Never clicks Create: no session is made.
return function(X, GS)
    local IN = {}
    local case, E, step, check, say, CORE = X.case, X.E, X.step, X.check, X.say, X.CORE
    local U8 = GS.util
    local try, v, prop, pathOf, fname, str, msAfter, liveOf, center, rootOf, firstLine =
        U8.try, U8.v, U8.prop, U8.pathOf, U8.fname, U8.str, U8.msAfter, U8.liveOf, U8.center, U8.rootOf, U8.firstLine
    local LOWER = CORE:lower()
    local PL = LOWER .. ".ui.place: "
    local HOST = "createServer"
    local VB = "VerticalBox_202"
    local OPENS = 10
    local function core() return X.core() end

    -- ---------------------------------------------------------------- bad input
    function IN.cases(phase)
        step(phase .. ": insert cases", function()
            local U = core().ui
            local P = phase .. ".ui-ins-"
            local function mk(place) return function() return U.text.create{ id = "gins", text = "x", place = place } end end
            local L65 = string.rep("a", 65)
            local ONE = "container needs exactly one of after, before, index or at"
            local KEYS = "(valid keys: after, at, before, container, host, index)"
            local rows = {
                { "cont-num", "container = 5", { host = HOST, container = 5, after = "Overlay_28" }, "container must be a game widget's name (a string), got 5" },
                { "cont-empty", "container = ''", { host = HOST, container = "", after = "Overlay_28" }, "container must not be empty" },
                { "cont-65", "container of 65 characters", { host = HOST, container = L65, after = "Overlay_28" }, "container is 65 characters, at most 64" },
                { "cont-path", "container = 'ScrollBox_54.VerticalBox_202' [a path, not a name]", { host = HOST, container = "ScrollBox_54.VerticalBox_202", after = "Overlay_28" }, "container 'ScrollBox_54.VerticalBox_202' is not a widget name" },
                { "cont-digit", "container = '2Box'", { host = HOST, container = "2Box", after = "Overlay_28" }, "container '2Box' is not a widget name" },
                { "anchor-num", "after = 28", { host = HOST, container = VB, after = 28 }, "after must be a game widget's name (a string), got 28" },
                { "anchor-empty", "before = ''", { host = HOST, container = VB, before = "" }, "before must not be empty" },
                { "anchor-65", "after of 65 characters", { host = HOST, container = VB, after = L65 }, "after is 65 characters, at most 64" },
                { "anchor-name", "before = 'a-b'", { host = HOST, container = VB, before = "a-b" }, "before 'a-b' is not a widget name" },
                { "anchor-table", "after = {}", { host = HOST, container = VB, after = {} }, "after must be a game widget's name (a string), got table" },
                { "two", "after and index", { host = HOST, container = VB, after = "Overlay_28", index = 2 }, ONE .. " (got after and index)" },
                { "two-at", "before and at", { host = HOST, container = VB, before = "Overlay_28", at = "end" }, ONE .. " (got before and at)" },
                { "none", "no position", { host = HOST, container = VB }, ONE .. " (got none)" },
                { "index-0", "index = 0", { host = HOST, container = VB, index = 0 }, "index 0 is out of range (1 to 256)" },
                { "index-frac", "index = 1.5", { host = HOST, container = VB, index = 1.5 }, "index must be a whole number from 1 to 256, got 1.5" },
                { "index-257", "index = 257", { host = HOST, container = VB, index = 257 }, "index 257 is out of range (1 to 256)" },
                { "index-nan", "index = NaN", { host = HOST, container = VB, index = 0 / 0 }, "index must be a whole number from 1 to 256, got NaN" },
                { "index-str", "index = '1'", { host = HOST, container = VB, index = "1" }, "index must be a whole number from 1 to 256, got '1'" },
                { "at-start", "at = 'start'", { host = HOST, container = VB, at = "start" }, "unknown at 'start' (valid: end)" },
                { "corner", "container with corner", { host = HOST, container = VB, after = "Overlay_28", corner = "top-left" }, "corner is not allowed with container " .. KEYS },
                { "gap", "container with gap", { host = HOST, container = VB, after = "Overlay_28", gap = "tight" }, "gap is not allowed with container " .. KEYS },
                { "near", "container with near", { host = HOST, container = VB, after = "Overlay_28", near = "crosshair" }, "near is not allowed with container " .. KEYS },
                { "absolute", "container with absolute", { host = HOST, container = VB, after = "Overlay_28", absolute = { anchor = "center", x = 0, y = 0 } }, "absolute is not allowed with container " .. KEYS },
                { "offset", "container with offset", { host = HOST, container = VB, after = "Overlay_28", offset = { x = 1, y = 1 } }, "offset is not allowed with container " .. KEYS },
                { "hud", "container on the default host (hud)", { container = VB, after = "Overlay_28" }, "container is not available on host 'hud' (game screens only: createServer)" },
                { "menu", "container on host menu", { host = "menu", container = VB, after = "Overlay_28" }, "container is not available on host 'menu' (game screens only: createServer)" },
                { "journal", "container on host journal", { host = "journal", container = VB, after = "Overlay_28" }, "container is not available on host 'journal' (game screens only: createServer)" },
                { "screen", "container on host screen", { host = "screen", container = VB, after = "Overlay_28" }, "container is not available on host 'screen' (game screens only: createServer)" },
                { "key", "an unknown key with container", { host = HOST, container = VB, after = "Overlay_28", foo = 1 }, "unknown key 'foo' in an intent (valid keys: absolute, after, align, at, before, container, corner, fill, gap, host, index, inset" },
                { "nocont", "after without container", { host = HOST, after = "Overlay_28" }, "after needs container = <game widget name>" },
            }
            for _, r in ipairs(rows) do
                case(P .. r[1], "ui.text.create{ place = { " .. r[2] .. " } }", mk(r[3]), E.err(PL .. r[4]))
            end
            -- inside a core container: the core container rules refuse it
            local okP, pnl = pcall(U.panel.create, { id = "gins-panel", place = { host = HOST, corner = "top-left" } })
            if okP then
                case(P .. "panel", "ui.text.create{ place = { panel = <panel>, container = ... } }", mk({ panel = pnl, container = VB }), E.err(PL .. "container is not allowed with panel"))
                pcall(U.panel.remove, pnl)
            else
                check(false, "CASE %spanel could not create a panel: %s", P, firstLine(pnl))
            end
            -- inside a core list or row: refused the same way
            local okL, lst = pcall(U.list.create, { id = "gins-list", place = { host = HOST, corner = "top-left" }, size = { w = 400, h = 300 } })
            if okL then
                case(P .. "list", "ui.text.create{ place = { list = <list>, container = ... } }", mk({ list = lst, container = VB }), E.err(PL .. "container is not allowed with list"))
                local okR, rw = pcall(U.row.create, { id = "gins-row", place = { list = lst } })
                if okR then
                    case(P .. "row", "ui.text.create{ place = { row = <row>, container = ... } }", mk({ row = rw, container = VB }), E.err(PL .. "container is not allowed with row"))
                    pcall(U.row.remove, rw)
                else
                    check(false, "CASE %srow could not create a row: %s", P, firstLine(rw))
                end
                pcall(U.list.remove, lst)
            else
                check(false, "CASE %slist could not create a list: %s", P, firstLine(lst))
            end
            -- controls: a valid one (pending: no screen open here), a bad place on it, isShown, remove, core.has
            local h
            case(P .. "ok", "ui.text.create{ place = { host = 'createServer', container = 'VerticalBox_202', after = 'Overlay_28' } } [control]",
                function() h = U.text.create{ id = "gins-ok", text = "x", place = { host = HOST, container = VB, after = "Overlay_28" } } return h end,
                E.ret("a handle", function(r) return type(r[1]) == "table" end))
            if h then
                case(P .. "place-bad", "ui.place(h, { host = 'createServer', container = 'VerticalBox_202', index = 0 })",
                    function() return U.place(h, { host = HOST, container = VB, index = 0 }) end, E.err(PL .. "index 0 is out of range (1 to 256)"))
                case(P .. "place-hud", "ui.place(h, { container = 'VerticalBox_202', at = 'end' }) [default host hud]",
                    function() return U.place(h, { container = VB, at = "end" }) end, E.err(PL .. "container is not available on host 'hud'"))
                case(P .. "isshown", "ui.text.isShown(h) [no create-server screen open]", function() return U.text.isShown(h) end,
                    E.ret("false", function(r) return r[1] == false end))
                case(P .. "remove", "ui.text.remove(h)", function() return U.text.remove(h) end, E.none)
            end
            case(P .. "has", "core.has('ui.place.container')", function() return core().has("ui.place.container") end,
                E.ret("true", function(r) return r[1] == true end))
        end)
    end

    -- ---------------------------------------------------------------- the gameinsert scenario
    -- A widget by name in a tree (bounded), or nil.
    local function findIn(root, name)
        local stack, seen = { root }, 0
        while #stack > 0 and seen < 4096 do
            local w = table.remove(stack)
            seen = seen + 1
            if fname(w) == name then return w end
            local n = try(function() return w:GetChildrenCount() end) or 0
            for i = n - 1, 0, -1 do
                local c = try(function() return w:GetChildAt(i) end)
                if v(c) then stack[#stack + 1] = c end
            end
        end
        return nil
    end
    -- A child's element id (one of ours, any core class: from its tag) or nil.
    local function idOf(c)
        local t = try(function() return X.tagOfWidget(c) end)
        return type(t) == "string" and t:match("^" .. LOWER .. ":[^:]+:(.+)$") or nil
    end
    local function slotKey(c)
        local s = prop(c, "Slot")
        if not s then return "?" end
        local p = try(function() local m = s.Padding return string.format("%g,%g,%g,%g", m.Left, m.Top, m.Right, m.Bottom) end) or "?"
        local z = try(function() local q = s.Size return string.format("%s/%g", tostring(q.SizeRule), q.Value) end) or "?"
        local h = try(function() return tostring(s.HorizontalAlignment) end) or "?"
        local w = try(function() return tostring(s.VerticalAlignment) end) or "?"
        return "pad=" .. p .. " size=" .. z .. " ha=" .. h .. " va=" .. w
    end
    -- The game pickers (MultipleSelectBox_C) inside a game row, as "name=option;..." (a bounded walk; user widgets not entered).
    local function picksOf(row)
        local out, stack, seen = {}, { row }, 0
        while #stack > 0 and seen < 64 do
            local w = table.remove(stack)
            seen = seen + 1
            local cls = try(function() return w:GetClass():GetFName():ToString() end)
            if cls == "MultipleSelectBox_C" then
                out[#out + 1] = fname(w) .. "=" .. tostring(str(try(function() return w.SelectedOption end)))
            else
                local n = try(function() return w:GetChildrenCount() end) or 0
                for i = n - 1, 0, -1 do
                    local c = try(function() return w:GetChildAt(i) end)
                    if v(c) then stack[#stack + 1] = c end
                end
            end
        end
        return table.concat(out, ";")
    end
    -- The list's children: { name (id for ours), ours, path, slot, picks }.
    local function listOf(vb)
        local out = {}
        local n = try(function() return vb:GetChildrenCount() end) or 0
        for i = 0, n - 1 do
            local c = try(function() return vb:GetChildAt(i) end)
            if v(c) then
                local id = idOf(c)
                out[#out + 1] = { name = id or fname(c), ours = id ~= nil, path = pathOf(c), slot = id and "" or slotKey(c), picks = id and "" or picksOf(c) }
            end
        end
        return out
    end
    local function names(l) local t = {} for _, e in ipairs(l) do t[#t + 1] = e.name end return table.concat(t, ",") end

    function IN.build()
        local S = { ev = {}, opens = {}, kPaths = {}, ePaths = {}, late = {}, cbn = 0 }
        local function count(e) local n = 0 for _, x in ipairs(S.ev) do if x.event == e then n = n + 1 end end return n end
        local function lastOf(e) for i = #S.ev, 1, -1 do if S.ev[i].event == e then return S.ev[i] end end return nil end
        local function screen() return liveOf(U8.CS_SHORT) end
        local function vbOf() local s = screen() local r = s and rootOf(s) return r and findIn(r, VB) or nil end
        local function rebuilds() return core().ui.text.stats().containerRebuilds end
        local function clickAt(label, finder)
            step("gi: click " .. label, function()
                local w = finder()
                local r = w and X.absR(w)
                if not check(r ~= nil and r.r > r.l, "GIPOINT %s has a screen rectangle", label) then return end
                local x, y = center(r)
                say("GICLICKREQ %s at (%d,%d)", label, x, y)
                return X.request(string.format("click %d %d", x, y)), 40, "click " .. label
            end)
        end
        local function shot(label) step("gi: shot " .. label, function() return X.request("shot " .. label), 30, "screenshot " .. label end) end
        local function settle(label, sec) step("gi: settle " .. label, function() return msAfter(sec), sec + 3 end) end
        -- The wanted order: the snapshot's game rows with five knobs (and the late texts) after Overlay_28, fourteen
        -- enemies after Overlay_738, then the checkbox (at end) and the unknown anchor's text, in creation order.
        local function wanted()
            local t = {}
            for _, g in ipairs(S.snap) do
                t[#t + 1] = g.name
                if g.name == "Overlay_28" then
                    for i = 1, 5 do t[#t + 1] = "gi-k" .. i end
                    for i = 1, #S.late do t[#t + 1] = "gi-n" .. i end
                end
                if g.name == "Overlay_738" then for i = 1, 14 do t[#t + 1] = "gi-e" .. i end end
            end
            t[#t + 1] = "gi-cb"
            t[#t + 1] = "gi-xa"
            return table.concat(t, ",")
        end
        -- The game rows' order and slot values against the snapshot; one widget per element.
        -- pickWant (row name -> "name=option;..."): when given, every game row's pickers must show those options after
        -- the rebuild (core puts them back; one GIPICKS line).
        local function verify(label, pickWant)
            local vb = vbOf()
            if not check(vb ~= nil, "GILIST %s %s found", label, VB) then return false end
            local l = listOf(vb)
            local got = names(l)
            local orderOk = got == wanted()
            local games, seen, slotsOk, bad = {}, {}, true, nil
            for _, e in ipairs(l) do
                if e.ours then seen[e.name] = (seen[e.name] or 0) + 1 else games[#games + 1] = e end
            end
            if #games ~= #S.snap then slotsOk, bad = false, string.format("%d game rows, snapshot %d", #games, #S.snap) end
            for i = 1, math.min(#games, #S.snap) do
                if games[i].name ~= S.snap[i].name or games[i].slot ~= S.snap[i].slot then
                    slotsOk, bad = false, string.format("%s %s (snapshot %s %s)", games[i].name, games[i].slot, S.snap[i].name, S.snap[i].slot)
                    break
                end
            end
            local one = true
            for _, id in ipairs(S.ids) do if seen[id] ~= 1 then one = false end end
            local kIdx = nil
            for i, e in ipairs(l) do if e.name == "gi-k1" then kIdx = i - 1 break end end
            check(orderOk and kIdx == 2, "GIORDER %s: knobs at children 2-6, the enemies right after Overlay_738, creation order, the unknown anchor's text last (k1 at %s)%s",
                label, tostring(kIdx), orderOk and "" or (": got " .. got))
            check(slotsOk, "GISLOTS %s: %d game rows in their order with the snapshot's slot values%s", label, #games, slotsOk and "" or (": " .. tostring(bad)))
            check(one and seen["gi-xc"] == nil, "GIONE %s: one widget per element (%d ids), none for the unknown container's", label, #S.ids)
            if pickWant then
                local pOk, pBad, np = true, nil, 0
                for _, g in ipairs(games) do
                    local want = pickWant[g.name]
                    if g.picks ~= "" then np = np + select(2, g.picks:gsub("=", "")) end
                    if want ~= nil and g.picks ~= want then pOk, pBad = false, string.format("%s %s (want %s)", g.name, g.picks, want) break end
                end
                check(pOk and np > 0, "GIPICKS %s: %d game pickers in the rebuilt list show their options from before the rebuild%s", label, np, pOk and "" or (": " .. tostring(pBad)))
            end
            S.lastList = got
            return orderOk and slotsOk and one, l
        end

        step("gi: setup", function()
            S.tok = core().ui.game.watch(HOST, function(s, info)
                S.ev[#S.ev + 1] = { event = info.event, path = info.path, reason = info.reason, hasScreen = s ~= nil }
                say("GIEVENT %d %s path=%s", #S.ev, tostring(info.event), tostring(info.path))
            end)
            check(S.tok ~= nil, "GISETUP a watcher on host createServer and no container element yet")
        end)
        X.waitWorld("menu1", "NewMainMenu", 120)
        step("menu1: startup screen", function()
            local deadline = os.clock() + 60
            return function() return liveOf("UI_Startup_C") ~= nil or liveOf(U8.MENU_SHORT) ~= nil or os.clock() > deadline end, 65, "startup screen"
        end)
        settle("startup", 2)
        step("menu1: startup", function()
            if liveOf(U8.MENU_SHORT) then return end
            local done = X.request("key ENTER")
            local deadline, tries = os.clock() + 15, 1
            return function()
                if liveOf(U8.MENU_SHORT) then return true end
                if os.clock() > deadline and done() and tries < 4 then
                    tries, deadline = tries + 1, os.clock() + 15
                    say("STARTUP no menu yet; Enter again (%d)", tries)
                    done = X.request("key ENTER")
                end
                return false
            end, 70, "menu after Enter"
        end)
        settle("menu", 3)
        IN.cases("menu1")
        local function startButton() return prop(liveOf(U8.MENU_SHORT), U8.START) end
        local function openOnce(label, n)
            step("gi: before open " .. n, function() S.r0 = rebuilds() end)
            clickAt(label .. " START GAME " .. n, startButton)
            step("gi: opened " .. n, function() return function() return count("opened") >= n end, 10, label .. " opened " .. n end)
            step("gi: opened check " .. n, function()
                local e = lastOf("opened")
                S.opens[n] = e and e.path
                check(e ~= nil and e.path == pathOf(screen()), "GIOPENED %d %s: opened path=%s", n, label, tostring(e and e.path))
            end)
        end
        local function backOnce(label, n)
            clickAt(label .. " Back " .. n, function() return prop(screen(), "Back") end)
            step("gi: closed " .. n, function() return function() return count("closed") >= n end, 10, label .. " closed " .. n end)
            step("gi: closed check " .. n, function()
                local e = S.ev[#S.ev]
                check(e ~= nil and e.event == "closed" and e.path == S.opens[n] and screen() == nil and core().ui.text.isShown(S.k[1]) == false,
                    "GICLOSED %d %s: closed path=%s, no screen, knob not shown", n, label, tostring(e and e.path))
            end)
        end

        -- Open 1: the stock list (no container element yet; 29 rows on V8.2.3, 26 on V8.1.2), snapshotted; then the elements, made while it is open.
        openOnce("menu1", 1)
        step("gi: snapshot", function()
            local vb = vbOf()
            if not check(vb ~= nil, "GISNAP %s found in the open screen", VB) then S.abort = true return end
            local l = listOf(vb)
            S.snap = {}
            local ours = 0
            for _, e in ipairs(l) do if e.ours then ours = ours + 1 else S.snap[#S.snap + 1] = e end end
            local has = {}
            for _, e in ipairs(S.snap) do has[e.name] = true end
            check(ours == 0 and #S.snap >= 3 and has.Overlay_28 and has.Overlay_27 and has.Overlay_738 and S.snap[2].name == "Overlay_28",
                "GISNAP %s before any container element: %d game rows, none of ours (%d), Overlay_28 second, Overlay_27 and Overlay_738 present", VB, #S.snap, ours)
            S.snapPicks = {}
            for i, e in ipairs(S.snap) do S.snapPicks[e.name] = e.picks; say("GISNAPROW %d %s %s %s", i - 1, e.name, e.slot, e.picks) end
        end)
        step("gi: create while open", function()
            if S.abort then return end
            local T = core().ui.text
            S.k, S.e, S.ids = {}, {}, {}
            S.rc = rebuilds()
            -- the checkbox first: at the end, before the unknown anchor's text (creation order)
            S.cb = core().ui.checkbox.create{ id = "gi-cb", place = { host = HOST, container = VB, at = "end" },
                onChange = function(_, val) S.cbn = S.cbn + 1; S.cbv = val end }
            S.ids[#S.ids + 1] = "gi-cb"
            for i = 1, 5 do
                S.k[i] = T.create{ id = "gi-k" .. i, text = "SKEL KNOB " .. i, place = { host = HOST, container = VB, after = "Overlay_28" } }
                S.ids[#S.ids + 1] = "gi-k" .. i
            end
            for i = 1, 14 do
                S.e[i] = T.create{ id = "gi-e" .. i, text = "SKEL ENEMY " .. i, place = { host = HOST, container = VB, after = "Overlay_738" } }
                S.ids[#S.ids + 1] = "gi-e" .. i
            end
            S.xa = T.create{ id = "gi-xa", text = "SKEL NO ANCHOR", place = { host = HOST, container = VB, after = "Overlay_NOPE" } }
            S.ids[#S.ids + 1] = "gi-xa"
            S.xc = T.create{ id = "gi-xc", text = "SKEL NO BOX", place = { host = HOST, container = "VerticalBox_NOPE", after = "Overlay_28" } }
            -- queued: nothing attached inside the call, no rebuild yet (Design Note 8)
            S.inCall = not T.isShown(S.k[1]) and not T.isShown(S.xa) and not core().ui.checkbox.isShown(S.cb) and rebuilds() == S.rc
        end)
        step("gi: created on the tick", function()
            if S.abort then return end
            local deadline = os.clock() + 5
            return function()
                local T = core().ui.text
                return (T.isShown(S.k[1]) and T.isShown(S.e[14]) and T.isShown(S.xa)) or os.clock() > deadline
            end, 8, "created elements attached"
        end)
        step("gi: created tick check", function()
            if S.abort then return end
            local T = core().ui.text
            local d = rebuilds() - S.rc
            check(S.inCall and T.isShown(S.k[1]) and T.isShown(S.e[14]) and T.isShown(S.xa) and core().ui.checkbox.isShown(S.cb) and not T.isShown(S.xc) and d == 1,
                "GICREATE 21 texts and a checkbox made while the screen is open: none attached in the call (%s), all on the next tick in %s, the unknown container's not; %d rebuild(s) for all",
                tostring(S.inCall), VB, d)
        end)
        step("gi: created check", function()
            if S.abort then return end
            verify("created", S.snapPicks)
        end)
        backOnce("menu1", 1)

        -- Ten opens by real clicks: the same order and slots, one rebuild each, one new widget per element.
        for n = 2, OPENS + 1 do
            openOnce("menu1", n)
            step("gi: open check " .. n, function()
                if S.abort then return end
                local okV = verify("open " .. n, S.snapPicks)
                local d = rebuilds() - S.r0
                check(d == 1, "GIREBUILD open %d: %s rebuilt %d time(s) for two anchors (expected 1)", n, VB, d)
                local T = core().ui.text
                local vb = vbOf()
                local kp = vb and pathOf((X.taggedIn(vb, "gi-k1")))
                local ep = vb and pathOf((X.taggedIn(vb, "gi-e14")))
                local new = kp ~= nil and ep ~= nil and not S.kPaths[kp] and not S.ePaths[ep]
                if kp then S.kPaths[kp] = true end
                if ep then S.ePaths[ep] = true end
                check(new and T.isShown(S.k[1]) and T.isShown(S.xa) and core().ui.checkbox.isShown(S.cb) and not T.isShown(S.xc),
                    "GINEW open %d: new widgets (%s), knob, checkbox and unknown-anchor text shown, the unknown container's not", n, tostring(kp))
                S.allOk = (S.allOk ~= false) and okV and d == 1 and new
            end)
            if n == 2 then shot("gi-open") end
            backOnce("menu1", n)
        end
        step("gi: ten opens", function()
            local seen, n = {}, 0
            for i = 2, OPENS + 1 do local p = S.opens[i] if p and not seen[p] then seen[p] = true; n = n + 1 end end
            local kn = 0
            for _ in pairs(S.kPaths) do kn = kn + 1 end
            check(S.allOk == true and n == OPENS and kn == OPENS and count("lost") == 0,
                "GITEN %d opens by real clicks: order, slots, one rebuild and new widgets every time; %d distinct screens, %d distinct knob widgets, lost=%d",
                OPENS, n, kn, count("lost"))
        end)

        -- The game's own controls after the rebuild: CONFIGURE, the Difficulty and Lobby Time pickers, a preset.
        local FINAL = OPENS + 2
        openOnce("menu1", FINAL)
        step("gi: final check", function() if S.abort then return end verify("final", S.snapPicks) end)
        clickAt("CONFIGURE", function() return prop(screen(), "Button_216") end)
        settle("configure", 1.5)
        step("gi: configure check", function()
            local s = screen()
            local sb = s and rootOf(s) and findIn(rootOf(s), "ScrollBox_54")
            if sb then pcall(function() sb:ScrollToStart() end) end
            local vis = try(function() return prop(s, "Overlay_0"):GetVisibility() end)
            check(vis ~= nil and vis ~= 1 and vis ~= 2, "GICONFIG CONFIGURE shows the world settings (Overlay_0 visibility %s)", tostring(vis))
        end)
        settle("scroll", 1)
        shot("gi-configure")
        -- The checkbox at the end of the list: scrolled into view, a real click runs its onChange once.
        local function cbWidget() local vb = vbOf() return vb and (X.taggedIn(vb, "gi-cb")) end
        step("gi: checkbox into view", function()
            local s = screen()
            local sb = s and rootOf(s) and findIn(rootOf(s), "ScrollBox_54")
            local w = cbWidget()
            local okS = sb ~= nil and w ~= nil and pcall(function() sb:ScrollWidgetIntoView(w, false, 0, 0) end)
            if not okS and sb then pcall(function() sb:ScrollToEnd() end) end
            S.cbn0 = S.cbn
            say("GICBSCROLL into view %s", tostring(okS))
        end)
        settle("checkbox scroll", 1)
        clickAt("checkbox", cbWidget)
        settle("checkbox", 1)
        step("gi: checkbox check", function()
            check(S.cbn == S.cbn0 + 1 and S.cbv == true and core().ui.checkbox.get(S.cb) == true,
                "GICB a real click on the checkbox in %s (at end) ran onChange once with true (%d call(s), %s)", VB, S.cbn - S.cbn0, tostring(S.cbv))
            local s = screen()
            local sb = s and rootOf(s) and findIn(rootOf(s), "ScrollBox_54")
            if sb then pcall(function() sb:ScrollToStart() end) end
        end)
        settle("scroll back", 1)
        -- A picker's arrow that is drawn now (next, else prev): the box's Button / Button_60.
        local function arrowOf(boxName)
            local box = prop(screen(), boxName)
            local nx, pv = prop(box, "Button"), prop(box, "Button_60")
            local function drawn(w) local vv = try(function() return w:GetVisibility() end) return vv ~= nil and vv ~= 1 and vv ~= 2 end
            if nx and drawn(nx) then return nx end
            return pv
        end
        local function optionOf(boxName) return str(try(function() return prop(screen(), boxName).SelectedOption end)) end
        step("gi: difficulty before", function() S.diff0 = optionOf("MultipleSelectBox_6") end)
        clickAt("Difficulty arrow", function() return arrowOf("MultipleSelectBox_6") end)
        settle("difficulty", 1)
        step("gi: difficulty check", function()
            local now = optionOf("MultipleSelectBox_6")
            check(now ~= nil and S.diff0 ~= nil and now ~= S.diff0, "GIDIFF a real click on the Difficulty picker's arrow changed it (%s -> %s)", tostring(S.diff0), tostring(now))
        end)
        step("gi: lobby before", function() S.lobby0 = optionOf("MultipleSelectBox_5") end)
        clickAt("Lobby Time arrow", function() return arrowOf("MultipleSelectBox_5") end)
        settle("lobby", 1)
        step("gi: lobby check", function()
            S.lobby1 = optionOf("MultipleSelectBox_5")
            check(S.lobby1 ~= nil and S.lobby0 ~= nil and S.lobby1 ~= S.lobby0,
                "GILOBBY a real click on Lobby Time's arrow (a rebuilt row) changed it (%s -> %s)", tostring(S.lobby0), tostring(S.lobby1))
            S.layout = verify("after the clicks")
        end)
        -- A preset: saved under a unique name, Lobby Time changed, the preset loaded (Lobby Time back), deleted.
        local function presetCount()
            return try(function()
                local a = prop(screen(), "PresetsSavObj").Presets
                local n = try(function() return #a end)
                return n or a:GetArrayNum()
            end)
        end
        step("gi: preset name", function()
            S.pname = string.format("SkelIns%d", os.time() % 1000000)
            S.pc0 = presetCount()
            local s = screen()
            local okT = pcall(function() prop(s, "EditableText"):SetText(FText(S.pname)) end)
            local okS = pcall(function() s.PresetName = S.pname end)
            local got = str(try(function() return s.PresetName end))
            check(S.pc0 ~= nil and got == S.pname, "GIPNAME preset name %s set (PresetName=%s, text %s, %s presets before)", S.pname, tostring(got), tostring(okT and okS), tostring(S.pc0))
        end)
        clickAt("SAVE WORLD PRESET", function() return prop(screen(), "Create_1") end)
        settle("save", 1.5)
        step("gi: save check", function()
            local n = presetCount()
            local sel = optionOf("MultipleSelectBox_11")
            check(n ~= nil and S.pc0 ~= nil and n == S.pc0 + 1 and sel == S.pname,
                "GISAVE a real click on SAVE WORLD PRESET saved '%s' (%s -> %s presets, selected %s)", S.pname, tostring(S.pc0), tostring(n), tostring(sel))
        end)
        clickAt("Lobby Time arrow again", function() return arrowOf("MultipleSelectBox_5") end)
        settle("lobby again", 1)
        step("gi: lobby changed", function()
            S.lobby2 = optionOf("MultipleSelectBox_5")
            check(S.lobby2 ~= nil and S.lobby2 ~= S.lobby1, "GILOBBY2 Lobby Time changed after the save (%s -> %s)", tostring(S.lobby1), tostring(S.lobby2))
        end)
        -- Load: the selector away and back through its own arrow handlers (each broadcasts the selection, as a click does).
        step("gi: load preset", function()
            local box = prop(screen(), "MultipleSelectBox_11")
            if not check(box ~= nil, "GILOAD the preset selector MultipleSelectBox_11 found") then return end
            pcall(function() box[U8.BOX_PREV](box) end)
            local away = optionOf("MultipleSelectBox_11")
            local steps = 0
            while optionOf("MultipleSelectBox_11") ~= S.pname and steps < 64 do
                pcall(function() box[U8.BOX_NEXT](box) end)
                steps = steps + 1
            end
            S.loaded = optionOf("MultipleSelectBox_11")
            say("GILOADSEL away=%s back=%s after %d step(s)", tostring(away), tostring(S.loaded), steps)
        end)
        settle("load", 1)
        step("gi: load check", function()
            local now = optionOf("MultipleSelectBox_5")
            check(S.loaded == S.pname and now == S.lobby1, "GILOAD loading '%s' restored Lobby Time (%s; saved %s, changed to %s)",
                S.pname, tostring(now), tostring(S.lobby1), tostring(S.lobby2))
        end)
        clickAt("DELETE preset", function() return prop(screen(), "Create_4") end)
        settle("delete", 1.5)
        step("gi: delete check", function()
            local n = presetCount()
            check(n ~= nil and n == S.pc0, "GIDELETE a real click on DELETE removed '%s' (%s presets, %s before the save)", S.pname, tostring(n), tostring(S.pc0))
            verify("after the preset")
        end)
        shot("gi-preset")
        -- With Lobby Time at a non-default value, a dependent makes two more texts while the screen is open: on the
        -- next tick they are in place after one rebuild, and Lobby Time (a rebuilt row) still shows the player's value.
        step("gi: late creates", function()
            if S.abort then return end
            S.lobbyL = optionOf("MultipleSelectBox_5")
            S.rl = rebuilds()
            S.pr0 = core().ui.text.stats().pickerRestores
            S.latePicks = {}
            local vb0 = vbOf()
            for _, e in ipairs(vb0 and listOf(vb0) or {}) do if not e.ours then S.latePicks[e.name] = e.picks end end
            local T = core().ui.text
            for i = 1, 2 do
                S.late[i] = T.create{ id = "gi-n" .. i, text = "SKEL LATE " .. i, place = { host = HOST, container = VB, after = "Overlay_28" } }
                S.ids[#S.ids + 1] = "gi-n" .. i
            end
            S.lateInCall = not T.isShown(S.late[1]) and rebuilds() == S.rl
        end)
        step("gi: late tick", function()
            if S.abort then return end
            local deadline = os.clock() + 5
            return function() return core().ui.text.isShown(S.late[2]) or os.clock() > deadline end, 8, "late texts attached"
        end)
        settle("late", 0.5)
        step("gi: late check", function()
            if S.abort then return end
            local now = optionOf("MultipleSelectBox_5")
            local d = rebuilds() - S.rl
            local okV = verify("after the late creates", S.latePicks)
            local pr = core().ui.text.stats().pickerRestores
            check(type(pr) == "number" and type(S.pr0) == "number" and pr > S.pr0,
                "GIRESTORE core put back %d game picker option(s) in the late rebuild (ui.text.stats().pickerRestores %s -> %s)", (pr or 0) - (S.pr0 or 0), tostring(S.pr0), tostring(pr))
            check(S.lobbyL ~= nil and S.lobbyL ~= S.lobby0, "GILATELOBBY Lobby Time at a non-default value before the creates (%s; %s at open)", tostring(S.lobbyL), tostring(S.lobby0))
            check(S.lateInCall and okV and d == 1, "GILATE two texts made while open: not attached in the call (%s), in place after the knobs on the next tick, %d rebuild(s) for both",
                tostring(S.lateInCall), d)
            check(now ~= nil and now == S.lobbyL, "GILATEKEEP Lobby Time (a rebuilt row) still shows %s after the rebuild (now %s)", tostring(S.lobbyL), tostring(now))
        end)
        shot("gi-late")
        clickAt("CONFIRM WORLD SETTINGS", function() return prop(screen(), "Create_3") end)
        settle("confirm", 1)
        backOnce("menu1", FINAL)
        step("gi: end", function()
            check(count("opened") == FINAL and count("closed") == FINAL and count("lost") == 0,
                "GIEVENTS opened=%d closed=%d lost=%d (expected %d, %d, 0)", count("opened"), count("closed"), count("lost"), FINAL, FINAL)
            local T = core().ui.text
            for _, h in ipairs(S.k or {}) do pcall(T.remove, h) end
            for _, h in ipairs(S.e or {}) do pcall(T.remove, h) end
            pcall(T.remove, S.xa); pcall(T.remove, S.xc)
            for _, h in ipairs(S.late) do pcall(T.remove, h) end
            pcall(core().ui.checkbox.remove, S.cb)
            pcall(core().ui.game.unwatch, S.tok)
        end)
    end

    return IN
end
