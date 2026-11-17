-- <Core>SkelTest's game-style rows part (core story 33, UI-15: row.create's like, label, help and control, row.setLabel,
-- row.setHelp, and choice.create's widget = "game"), loaded by main.lua with dofile after gameinsert.lua (main.lua is
-- at Lua's 200-locals limit). Takes main.lua's helpers plus GS (gamescreen.lua's module, for its shared helpers) and
-- returns:
--   cases(phase)   the ui-nr-* bad-input cases as one step (every error row of the story's I/O matrix, plus the control
--                  calls); in bad-input (menu1, match1) and in nativerow (menu1)
--   build()        the nativerow scenario, written for the VM at 1280x720 (run.ps1 -Target vm): in setup, before any
--                  key, a game choice (six options, the third selected) and a game-style row like Overlay_28 holding it
--                  with three-line help, a second one holding a core checkbox, and one like Overlay_NOPE, all after
--                  Overlay_28 in VerticalBox_202; menu1 and its cases; ten opens by real clicks on START GAME: each
--                  like row's copied values equal the live Difficulty row's (NRLOOK, logged per open), one widget and
--                  one set of parts per row, the game choice showing its option, the fallback row present; Back. Then
--                  one more open: CONFIGURE, a screenshot (nr-rows, the Difficulty row next to ours), the cursor moved
--                  over our "?" (a real hover) and a screenshot (nr-tip), the "?"'s ToolTipWidget a W_ToolTip3_C whose
--                  Description has three lines; a real click on the game choice's next arrow (onChange once with the
--                  next index); set (shown, no callback); CONFIRM and Back.
-- Never keeps a UObject across steps: each step finds what it needs again; only paths, names, counts and values are kept.
-- Never clicks Create: no session is made.
return function(X, GS)
    local NR = {}
    local case, E, step, check, say, CORE = X.case, X.E, X.step, X.check, X.say, X.CORE
    local U8 = GS.util
    local try, v, prop, pathOf, fname, str, msAfter, liveOf, center, rootOf, firstLine =
        U8.try, U8.v, U8.prop, U8.pathOf, U8.fname, U8.str, U8.msAfter, U8.liveOf, U8.center, U8.rootOf, U8.firstLine
    local LOWER = CORE:lower()
    local RC = LOWER .. ".ui.row.create: "
    local CC = LOWER .. ".ui.choice.create: "
    local HOST = "createServer"
    local VB = "VerticalBox_202"
    local OPENS = 10
    local ROW_SHORT = "WBP_" .. CORE .. "Row_C"
    local OPTS = { "Default", "Off", "Low", "Medium", "High", "Max" }
    local HELP3 = "How hard enemies hit (SkelTest).\nDefault keeps the game's value.\nRange 0-200."
    local function core() return X.core() end

    -- ---------------------------------------------------------------- bad input
    function NR.cases(phase)
        step(phase .. ": native row cases", function()
            local U = core().ui
            local P = phase .. ".ui-nr-"
            local nop = function() end
            local IN = { host = HOST, container = VB, after = "Overlay_28" }
            local L65 = string.rep("a", 65)
            local function mk(o) o.id = o.id or "gnr"; if o.place == false then o.place = nil else o.place = o.place or IN end return function() return U.row.create(o) end end
            local rows = {
                { "key", "nope = 1", { like = "Overlay_28", nope = 1 }, "unknown key 'nope' (valid: control, gap, help, id, label, like, place, style)" },
                { "like-num", "like = 28", { like = 28 }, "like must be a game widget's name (a string), got 28" },
                { "like-empty", "like = ''", { like = "" }, "like must not be empty" },
                { "like-65", "like of 65 characters", { like = L65 }, "like is 65 characters, at most 64" },
                { "like-space", "like = 'Over lay'", { like = "Over lay" }, "like 'Over lay' is not a widget name" },
                { "like-digit", "like = '9Row'", { like = "9Row" }, "like '9Row' is not a widget name" },
                { "like-table", "like = {}", { like = {} }, "like must be a game widget's name (a string), got table" },
                { "label-nolike", "label without like", { label = "X" }, "label needs like = <game row name>" },
                { "help-nolike", "help without like", { help = "X" }, "help needs like = <game row name>" },
                { "two-nolike", "label and help without like", { label = "X", help = "Y" }, "label and help need like = <game row name>" },
                { "label-num", "label = 5", { like = "Overlay_28", label = 5 }, "label must be a string or a table of strings by language" },
                { "label-empty", "label = ''", { like = "Overlay_28", label = "" }, "label must be a string of 1 to 64 bytes, got 0 bytes" },
                { "label-65", "label of 65 bytes", { like = "Overlay_28", label = L65 }, "label must be a string of 1 to 64 bytes, got 65 bytes" },
                { "label-nl", "label with a newline", { like = "Overlay_28", label = "a\nb" }, "label has the control byte 0x0A at byte 2" },
                { "label-noen", "label = { de = 'X' }", { like = "Overlay_28", label = { de = "X" } }, "label needs an en string (the fallback)" },
                { "label-lang", "label with key '1x'", { like = "Overlay_28", label = { en = "X", ["1x"] = "Y" } }, "label key '1x' is not a language tag" },
                { "help-num", "help = 5", { like = "Overlay_28", help = 5 }, "help must be a string or a table of strings by language" },
                { "help-513", "help of 513 bytes", { like = "Overlay_28", help = string.rep("h", 513) }, "help must be a string of 1 to 512 bytes, got 513 bytes" },
                { "help-9", "help of 9 lines", { like = "Overlay_28", help = "1\n2\n3\n4\n5\n6\n7\n8\n9" }, "help has 9 lines, at most 8" },
                { "help-de9", "help.de of 9 lines", { like = "Overlay_28", help = { en = "a", de = "1\n2\n3\n4\n5\n6\n7\n8\n9" } }, "help.de has 9 lines, at most 8" },
                { "help-tab", "help with a tab", { like = "Overlay_28", help = "a\tb" }, "help has the control byte 0x09 at byte 2" },
                { "help-noen", "help = { de = 'x' }", { like = "Overlay_28", help = { de = "x" } }, "help needs an en string (the fallback)" },
                { "host-menu", "like on host menu", { like = "Overlay_28", place = { host = "menu", corner = "top-left" } }, "like needs a game screen host (createServer), got 'menu'" },
                { "host-journal", "like on host journal", { like = "Overlay_28", place = { host = "journal", corner = "top-left" } }, "like needs a game screen host (createServer), got 'journal'" },
                { "host-hud", "like with no place (hud)", { like = "Overlay_28", place = false }, "like needs a game screen host (createServer), got 'hud'" },
                { "ctl-num", "control = 5", { like = "Overlay_28", control = 5 }, "control must be a checkbox, choice, slider or button handle, got 5" },
                { "ctl-forged", "control = {}", { like = "Overlay_28", control = {} }, "control is not an element handle of this mod" },
            }
            for _, r in ipairs(rows) do case(P .. r[1], "ui.row.create{ " .. r[2] .. " }", mk(r[3]), E.err(RC .. r[4])) end
            -- inside core containers; controls of the wrong kind, removed, or without like
            local okL, lst = pcall(U.list.create, { id = "gnr-list", place = { host = HOST, corner = "top-left" }, size = { w = 300, h = 200 } })
            local okP, pnl = pcall(U.panel.create, { id = "gnr-panel", place = { host = HOST, corner = "top-left" } })
            local okT, tx = pcall(U.text.create, { id = "gnr-text", text = "x", place = { host = HOST, corner = "top-left" } })
            local okC, gone = pcall(U.checkbox.create, { id = "gnr-cb", place = { host = HOST, corner = "top-left" }, onChange = nop })
            if check(okL and okP and okT and okC, "CASE %ssetup a list, a panel, a text and a checkbox on createServer (%s)", P, firstLine(okL and (okP and (okT and (okC and "" or gone) or tx) or pnl) or lst)) then
                pcall(U.checkbox.remove, gone)
                case(P .. "in-list", "ui.row.create{ like, place = { list = <list> } }", mk({ like = "Overlay_28", place = { list = lst } }), E.err(RC .. "a row with like can't go inside a panel, list or row"))
                case(P .. "in-panel", "ui.row.create{ like, place = { panel = <panel> } }", mk({ like = "Overlay_28", place = { panel = pnl } }), E.err(RC .. "a row with like can't go inside a panel, list or row"))
                case(P .. "ctl-text", "ui.row.create{ like, control = <text> }", mk({ like = "Overlay_28", control = tx }), E.err(RC .. "control 'gnr-text' is a text element, not a checkbox, choice, slider or button"))
                case(P .. "ctl-list", "ui.row.create{ like, control = <list> }", mk({ like = "Overlay_28", control = lst }), E.err(RC .. "control 'gnr-list' is a list, not a checkbox, choice, slider or button"))
                case(P .. "ctl-removed", "ui.row.create{ like, control = <removed checkbox> }", mk({ like = "Overlay_28", control = gone }), E.err(RC .. "control handle 'gnr-cb' was removed"))
                case(P .. "ctl-nolike", "ui.row.create{ control = <text> } [no like]", mk({ control = tx }), E.err(RC .. "control needs like = <game row name>"))
                -- setLabel / setHelp
                local okR, plain = pcall(U.row.create, { id = "gnr-plain", place = { list = lst } })
                local okK, lr = pcall(U.row.create, { id = "gnr-like", like = "Overlay_28", label = "L", place = IN })
                if check(okR and okK, "CASE %ssetup a plain row and a game-style row (%s)", P, firstLine(okR and (okK and "" or lr) or plain)) then
                    local SL, SH = LOWER .. ".ui.row.setLabel: ", LOWER .. ".ui.row.setHelp: "
                    local function f(fn, ...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end
                    case(P .. "setlabel-plain", "ui.row.setLabel(<row without like>, 'X')", f(U.row.setLabel, plain, "X"), E.err(SL .. "row 'gnr-plain' is not a game-style row (made without like)"))
                    case(P .. "sethelp-plain", "ui.row.setHelp(<row without like>, 'X')", f(U.row.setHelp, plain, "X"), E.err(SH .. "row 'gnr-plain' is not a game-style row (made without like)"))
                    case(P .. "setlabel-num", "ui.row.setLabel(h, 5)", f(U.row.setLabel, lr, 5), E.err(SL .. "label must be a string or a table of strings by language"))
                    case(P .. "setlabel-nil", "ui.row.setLabel(h, nil)", f(U.row.setLabel, lr, nil), E.err(SL .. "label must be a string or a table of strings by language, like { en = \"Enemy Damage\" }, got nil"))
                    case(P .. "setlabel-65", "ui.row.setLabel(h, <65 bytes>)", f(U.row.setLabel, lr, L65), E.err(SL .. "label must be a string of 1 to 64 bytes, got 65 bytes"))
                    case(P .. "setlabel-none", "ui.row.setLabel(h)", f(U.row.setLabel, lr), E.err(SL .. "expected 2 arguments (handle, label), got 1"))
                    case(P .. "setlabel-three", "ui.row.setLabel(h, 'a', 'b')", f(U.row.setLabel, lr, "a", "b"), E.err(SL .. "expected 2 arguments (handle, label), got 3"))
                    case(P .. "sethelp-9", "ui.row.setHelp(h, <9 lines>)", f(U.row.setHelp, lr, "1\n2\n3\n4\n5\n6\n7\n8\n9"), E.err(SH .. "help has 9 lines, at most 8"))
                    case(P .. "sethelp-513", "ui.row.setHelp(h, <513 bytes>)", f(U.row.setHelp, lr, string.rep("h", 513)), E.err(SH .. "help must be a string of 1 to 512 bytes, got 513 bytes"))
                    case(P .. "sethelp-none", "ui.row.setHelp(h)", f(U.row.setHelp, lr), E.err(SH .. "expected 2 arguments (handle, help), got 1"))
                    case(P .. "setlabel-text", "ui.row.setLabel(<text>, 'X')", f(U.row.setLabel, tx, "X"), E.err(SL .. "not a row handle ('gnr-text' is a text element)"))
                    case(P .. "sethelp-forged", "ui.row.setHelp({}, 'X')", f(U.row.setHelp, {}, "X"), E.err(SH .. "not a row handle"))
                    case(P .. "place-menu", "ui.place(<like row>, { host = 'menu', corner })", f(U.place, lr, { host = "menu", corner = "top-left" }), E.err(LOWER .. ".ui.place: like needs a game screen host (createServer), got 'menu'"))
                    case(P .. "place-list", "ui.place(<like row>, { list = <list> })", f(U.place, lr, { list = lst }), E.err(LOWER .. ".ui.place: a row with like can't go inside a panel, list or row"))
                    case(P .. "same-id", "ui.row.create{ id = <like row's>, no like }", mk({ id = "gnr-like" }), E.err(RC .. "id 'gnr-like' is already a row with like; remove it first"))
                    -- the controls: valid calls on the pending row
                    case(P .. "ok", "ui.row.create{ like = 'Overlay_28', label, help, place = <VerticalBox_202 after Overlay_28> } [control]",
                        mk({ id = "gnr-ok", like = "Overlay_28", label = "Ok Row", help = "a\nb\nc" }), E.ret("a handle", function(r) return type(r[1]) == "table" end))
                    case(P .. "setlabel-ok", "ui.row.setLabel(h, { en = 'Label', de = 'Etikett' })", f(U.row.setLabel, lr, { en = "Label", de = "Etikett" }), E.none)
                    case(P .. "sethelp-ok", "ui.row.setHelp(h, 'one\\ntwo')", f(U.row.setHelp, lr, "one\ntwo"), E.none)
                    case(P .. "sethelp-nil", "ui.row.setHelp(h, nil)", f(U.row.setHelp, lr, nil), E.none)
                    case(P .. "isshown", "ui.row.isShown(h) [no create-server screen open]", f(U.row.isShown, lr), E.ret("false", function(r) return r[1] == false end))
                    case(P .. "remove", "ui.row.remove(h)", f(U.row.remove, lr), E.none)
                    case(P .. "setlabel-removed", "ui.row.setLabel(<removed>, 'X')", f(U.row.setLabel, lr, "X"), E.err(LOWER .. ".ui.row: handle 'gnr-like' was removed"))
                    pcall(U.row.remove, plain)
                    for _, id in ipairs({ "gnr-ok" }) do pcall(function() local h = core().ui.row.create{ id = id, like = "Overlay_28", place = IN } core().ui.row.remove(h) end) end
                end
                -- the game choice
                local function ch(o) o.id = o.id or "gnr-ch"; o.options = o.options or OPTS; o.onChange = o.onChange or nop return function() return U.choice.create(o) end end
                local cs = {
                    { "gc-menu", "widget 'game' on host menu", { widget = "game", place = { host = "menu", corner = "top-left" } }, "widget 'game' needs a game screen host (createServer), got 'menu'" },
                    { "gc-hud", "widget 'game' on the hud", { widget = "game", place = { corner = "top-left" } }, "widget 'game' needs a game screen host (createServer), got 'hud'" },
                    { "gc-tooltip", "widget 'game' with a tooltip", { widget = "game", tooltip = "x", place = { host = HOST, corner = "top-left" } }, "tooltip is not available with widget 'game'" },
                    { "gc-dup", "widget 'game' with options A, B, A", { widget = "game", options = { "A", "B", "A" }, place = { host = HOST, corner = "top-left" } }, "options[3] 'A' repeats options[1] (widget 'game' needs distinct options" },
                    { "gc-widget", "widget = 'fancy'", { widget = "fancy", place = { host = HOST, corner = "top-left" } }, "unknown widget 'fancy' (valid: core)" },
                }
                for _, r in ipairs(cs) do case(P .. r[1], "ui.choice.create{ " .. r[2] .. " }", ch(r[3]), E.err(CC .. r[4])) end
                local okJ, jl = pcall(U.list.create, { id = "gnr-jlist", place = { host = "journal", corner = "top-left" }, size = { w = 300, h = 200 } })
                local okG, gc = pcall(U.choice.create, { id = "gnr-gc", widget = "game", options = OPTS, onChange = nop })
                if check(okJ and okG, "CASE %ssetup a journal list and a game choice (%s)", P, firstLine(okJ and (okG and "" or gc) or jl)) then
                    local function f(fn, ...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end
                    case(P .. "gc-list", "ui.choice.create{ widget = 'game', place = { list = <journal list> } }", ch({ widget = "game", place = { list = jl } }),
                        E.err(CC .. "widget 'game' needs a game screen host (createServer), got 'journal'"))
                    case(P .. "gc-settooltip", "ui.choice.setTooltip(<game choice>, 'x')", f(U.choice.setTooltip, gc, "x"),
                        E.err(LOWER .. ".ui.choice.setTooltip: choice 'gnr-gc' has widget 'game', which takes no tooltip"))
                    case(P .. "gc-settooltip-nil", "ui.choice.setTooltip(<game choice>, nil)", f(U.choice.setTooltip, gc, nil), E.none)
                    case(P .. "gc-sameid", "ui.choice.create{ id = <game choice's>, widget = 'core' }", ch({ id = "gnr-gc", place = { host = HOST, corner = "top-left" } }),
                        E.err(CC .. "id 'gnr-gc' is already a choice with widget 'game'"))
                    case(P .. "gc-place-menu", "ui.place(<game choice>, { host = 'menu', corner })", f(U.place, gc, { host = "menu", corner = "top-left" }),
                        E.err(LOWER .. ".ui.place: widget 'game' needs a game screen host (createServer), got 'menu'"))
                    local okJR, jr = pcall(U.row.create, { id = "gnr-jrow", place = { list = jl } })
                    if okJR then
                        case(P .. "gc-place-row", "ui.place(<game choice>, { row = <journal row> })", f(U.place, gc, { row = jr }),
                            E.err(LOWER .. ".ui.place: widget 'game' needs a game screen host (createServer), got 'journal'"))
                        pcall(U.row.remove, jr)
                    end
                    case(P .. "gc-get", "ui.choice.get(<game choice>)", f(U.choice.get, gc), E.ret("1, 'Default'", function(r) return r[1] == 1 and r[2] == "Default" end))
                    case(P .. "gc-set", "ui.choice.set(<game choice>, 3)", f(U.choice.set, gc, 3), E.none)
                    case(P .. "gc-ctl", "ui.row.create{ like, control = <game choice> } [control]", mk({ id = "gnr-gcrow", like = "Overlay_28", label = "Game Choice", control = gc }),
                        E.ret("a handle", function(r) return type(r[1]) == "table" end))
                    pcall(U.choice.remove, gc)
                    pcall(function() U.row.remove(U.row.create{ id = "gnr-gcrow", like = "Overlay_28", place = IN }) end)
                    pcall(U.list.remove, jl)
                end
                pcall(U.list.remove, lst); pcall(U.panel.remove, pnl); pcall(U.text.remove, tx)
            end
            for _, n in ipairs({ "ui.row.like", "ui.row.setLabel", "ui.row.setHelp", "ui.choice.game" }) do
                case(P .. "has-" .. n:gsub("^ui%.", ""):gsub("%.", "-"), "core.has('" .. n .. "')", function() return core().has(n) end, E.ret("true", function(r) return r[1] == true end))
            end
        end)
    end

    -- ---------------------------------------------------------------- the nativerow scenario
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
    local function clsName(o) return try(function() return o:GetClass():GetFName():ToString() end) or "?" end
    -- Our row widgets in a box: id -> { widgets }
    local function rowsIn(box)
        local out = {}
        local mine = LOWER .. ":" .. "[^:]+:(.+)$"
        local n = try(function() return box:GetChildrenCount() end) or 0
        for i = 0, n - 1 do
            local c = try(function() return box:GetChildAt(i) end)
            if v(c) and clsName(c) == ROW_SHORT then
                local tag = try(function() return c.CoreTag:ToString() end)
                local id = type(tag) == "string" and tag:match("^" .. mine) or nil
                if id then out[id] = out[id] or {}; table.insert(out[id], { w = c, index = i }) end
            end
        end
        return out
    end
    local function childOf(w, i) local c = try(function() return w:GetChildAt(i) end) return v(c) and c or nil end
    local function count(w) return try(function() return w:GetChildrenCount() end) or -1 end
    -- Values as text, for logging and comparing.
    local function n3(x) return x and string.format("%.3f", tonumber(x) or 0) or "?" end
    local function lin(c) return c and (n3(try(function() return c.R end)) .. "," .. n3(try(function() return c.G end)) .. "," .. n3(try(function() return c.B end)) .. "," .. n3(try(function() return c.A end))) or "?" end
    local function brushKey(b)
        if not b then return "?" end
        local res = try(function() return b.ResourceObject end)
        return string.format("res=%s size=%s,%s draw=%s margin=%s,%s,%s,%s tint=%s", tostring(v(res) and pathOf(res) or "none"),
            n3(try(function() return b.ImageSize.X end)), n3(try(function() return b.ImageSize.Y end)), tostring(try(function() return b.DrawAs end)),
            n3(try(function() return b.Margin.Left end)), n3(try(function() return b.Margin.Top end)), n3(try(function() return b.Margin.Right end)), n3(try(function() return b.Margin.Bottom end)),
            lin(try(function() return b.TintColor.SpecifiedColor end)))
    end
    local function textKey(t)
        if not v(t) then return "?" end
        local f = try(function() return t.Font end)
        local fo = f and try(function() return f.FontObject end)
        return string.format("font=%s size=%s face=%s colour=%s just=%s", tostring(v(fo) and fname(fo) or "none"), n3(f and try(function() return f.Size end)),
            tostring(f and str(try(function() return f.TypefaceFontName end))), lin(try(function() return t.ColorAndOpacity.SpecifiedColor end)), tostring(try(function() return t.Justification end)))
    end
    local function slotKey(w)
        local s = prop(w, "Slot")
        if not s then return "?" end
        local p = try(function() local m = s.Padding return string.format("%g,%g,%g,%g", m.Left, m.Top, m.Right, m.Bottom) end) or "?"
        local z = try(function() local q = s.Size return string.format("%s/%g", tostring(q.SizeRule), q.Value) end) or "-"
        local h = try(function() return tostring(s.HorizontalAlignment) end) or "?"
        local va = try(function() return tostring(s.VerticalAlignment) end) or "?"
        return "pad=" .. p .. " size=" .. z .. " ha=" .. h .. " va=" .. va
    end
    local function overlaySlotKey(w)
        local s = prop(w, "Slot")
        if not s then return "?" end
        local p = try(function() local m = s.Padding return string.format("%g,%g,%g,%g", m.Left, m.Top, m.Right, m.Bottom) end) or "?"
        return "pad=" .. p .. " ha=" .. tostring(try(function() return s.HorizontalAlignment end)) .. " va=" .. tostring(try(function() return s.VerticalAlignment end))
    end
    local function borderKey(b)
        local p = try(function() local m = b.Padding return string.format("%g,%g,%g,%g", m.Left, m.Top, m.Right, m.Bottom) end) or "?"
        return "pad=" .. p .. " ha=" .. tostring(try(function() return b.HorizontalAlignment end)) .. " va=" .. tostring(try(function() return b.VerticalAlignment end))
    end
    -- The Difficulty row's values (the game's), and one of our rows' (the same keys).
    local function gameLook(row)
        local img, hb
        for i = 0, count(row) - 1 do
            local c = childOf(row, i)
            local k = c and clsName(c)
            if k == "Image" and not img then img = c elseif k == "HorizontalBox" and not hb then hb = c end
        end
        if not (img and hb) then return nil end
        local lbl, inner = childOf(hb, 0), childOf(hb, 1)
        local ctl, q = inner and childOf(inner, 0), inner and childOf(inner, count(inner) - 1)
        return { height = n3(try(function() return img.Brush.ImageSize.Y end)), brush = brushKey(try(function() return img.Brush end)), tint = lin(try(function() return img.ColorAndOpacity end)), bpad = overlaySlotKey(hb),
            label = textKey(lbl), help = textKey(q), slabel = slotKey(lbl), sinner = slotKey(inner), sctl = slotKey(ctl), shelp = slotKey(q), srow = slotKey(row) }
    end
    local function ourLook(w)
        local bg = prop(w, "Background")
        local hb = prop(w, "HBox")
        local lbl, inner = hb and childOf(hb, 0), hb and childOf(hb, 1)
        local holder, q = inner and childOf(inner, 0), inner and childOf(inner, 1)
        local sp = hb and childOf(hb, 2)
        if not (bg and lbl and inner and holder and q) then return nil end
        return { height = n3(sp and try(function() return sp.Size.Y end)), brush = brushKey(try(function() return bg.Background end)), tint = lin(try(function() return bg.BrushColor end)), bpad = borderKey(bg),
            label = textKey(lbl), help = textKey(q), slabel = slotKey(lbl), sinner = slotKey(inner), sctl = slotKey(holder), shelp = slotKey(q), srow = slotKey(w),
            parts = count(hb) .. "/" .. count(inner) .. "/" .. count(holder), holder = holder, q = q, lbl = lbl }
    end
    local KEYS = { "height", "brush", "tint", "bpad", "label", "help", "slabel", "sinner", "sctl", "shelp", "srow" }

    function NR.build()
        local S = { ev = {}, opens = {}, paths = {}, n = 0, allOk = true }
        local function countEv(e) local k = 0 for _, x in ipairs(S.ev) do if x.event == e then k = k + 1 end end return k end
        local function lastOf(e) for i = #S.ev, 1, -1 do if S.ev[i].event == e then return S.ev[i] end end return nil end
        local function screen() return liveOf(U8.CS_SHORT) end
        local function vbOf() local s = screen() local r = s and rootOf(s) return r and findIn(r, VB) or nil end
        local function clickAt(label, finder)
            step("nr: click " .. label, function()
                local w = finder()
                local r = w and X.absR(w)
                if not check(r ~= nil and r.r > r.l, "NRPOINT %s has a screen rectangle", label) then return end
                local x, y = center(r)
                say("NRCLICKREQ %s at (%d,%d)", label, x, y)
                return X.request(string.format("click %d %d", x, y)), 40, "click " .. label
            end)
        end
        local function shot(label) step("nr: shot " .. label, function() return X.request("shot " .. label), 30, "screenshot " .. label end) end
        local function settle(label, sec) step("nr: settle " .. label, function() return msAfter(sec), sec + 3 end) end
        local function rowW(id) local vb = vbOf() local l = vb and rowsIn(vb)[id] return l and l[1] and l[1].w or nil end
        local function pickerOf(id)
            local o = rowW(id) and ourLook(rowW(id))
            local wrap = o and childOf(o.holder, 0)
            local hb = wrap and prop(wrap, "HBox")
            local m = hb and childOf(hb, 0)
            return m and clsName(m) == "MultipleSelectBox_C" and m or nil
        end

        step("nr: setup", function()
            local U = core().ui
            S.tok = U.game.watch(HOST, function(s, info)
                S.ev[#S.ev + 1] = { event = info.event, path = info.path }
                say("NREVENT %d %s path=%s", #S.ev, tostring(info.event), tostring(info.path))
            end)
            S.calls = {}
            S.gc = U.choice.create{ id = "nr-gc", widget = "game", options = OPTS, selected = 3,
                onChange = function(h, i, o) S.calls[#S.calls + 1] = { i = i, o = o }; say("NRCHANGE %d %s", i, tostring(o)) end }
            local IN = { host = HOST, container = VB, after = "Overlay_28" }
            S.r1 = U.row.create{ id = "nr-r1", like = "Overlay_28", label = "Enemy Damage (Skel)", help = HELP3, control = S.gc, place = IN }
            S.cb = U.checkbox.create{ id = "nr-cb", onChange = function() end, place = { host = HOST, corner = "top-left" } }
            S.r2 = U.row.create{ id = "nr-r2", like = "Overlay_28", label = "Damage Spread (Skel)", help = "One line of help.", control = S.cb, place = IN }
            S.r3 = U.row.create{ id = "nr-r3", like = "Overlay_NOPE", label = "No Like Row (Skel)", help = "Fallback help.", place = IN }
            check(S.tok ~= nil and S.r1 and S.r2 and S.r3 and U.row.isShown(S.r1) == false,
                "NRSETUP a game choice and three game-style rows after Overlay_28 (one like Overlay_NOPE) before any key, pending")
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
        NR.cases("menu1")
        local function startButton() return prop(liveOf(U8.MENU_SHORT), U8.START) end
        local function openOnce(label, n)
            clickAt(label .. " START GAME " .. n, startButton)
            step("nr: opened " .. n, function() return function() return countEv("opened") >= n end, 10, label .. " opened " .. n end)
            settle("attach " .. n, 0.6) -- the insert pass and the arrow hooks' check run on the opened tick and the next
            step("nr: opened check " .. n, function()
                local e = lastOf("opened")
                S.opens[n] = e and e.path
                check(e ~= nil and e.path == pathOf(screen()), "NROPENED %d %s: opened path=%s", n, label, tostring(e and e.path))
            end)
        end
        local function backOnce(label, n)
            clickAt(label .. " Back " .. n, function() return prop(screen(), "Back") end)
            step("nr: closed " .. n, function() return function() return countEv("closed") >= n end, 10, label .. " closed " .. n end)
        end
        -- One open's checks: each like row's copied values equal the Difficulty row's (NRLOOK per row), one widget and
        -- one set of parts per row, the game choice's option, the fallback row present.
        local function verify(n)
            local vb = vbOf()
            if not check(vb ~= nil, "NRLIST open %d: %s found", n, VB) then S.allOk = false return end
            local src = findIn(vb, "Overlay_28")
            local g = src and gameLook(src)
            if not check(g ~= nil, "NRGAME open %d: the Difficulty row Overlay_28 is a game row", n) then S.allOk = false return end
            local rows = rowsIn(vb)
            local oneOk = true
            for _, id in ipairs({ "nr-r1", "nr-r2", "nr-r3" }) do if not rows[id] or #rows[id] ~= 1 then oneOk = false end end
            local idx = rows["nr-r1"] and rows["nr-r1"][1].index
            check(oneOk and idx == 2, "NRONE open %d: one widget per row (r1 at child %s, right after Overlay_28)", n, tostring(idx))
            local lookOk = true
            for _, id in ipairs({ "nr-r1", "nr-r2" }) do
                local o = ourLook(rows[id] and rows[id][1].w)
                local bad = {}
                if not o then bad[1] = "parts missing" else
                    for _, k in ipairs(KEYS) do if o[k] ~= g[k] then bad[#bad + 1] = k .. ": ours " .. tostring(o[k]) .. " game " .. tostring(g[k]) end end
                    if o.parts ~= "3/2/1" then bad[#bad + 1] = "parts " .. o.parts end
                end
                if #bad > 0 then lookOk = false end
                check(#bad == 0, "NRLOOK open %d %s: copied values equal the Difficulty row's%s", n, id, #bad == 0 and "" or (": " .. table.concat(bad, "; ")))
                if n == 1 or #bad > 0 then
                    for _, k in ipairs(KEYS) do say("NRVAL open %d %s %s ours=%s game=%s", n, id, k, tostring(o and o[k]), tostring(g[k])) end
                end
            end
            local m = pickerOf("nr-r1")
            local sel, def = m and str(try(function() return m.SelectedOption end)), m and str(try(function() return m.DefaultOption end))
            local want = OPTS[core().ui.choice.get(S.gc)]
            check(m ~= nil and sel == want and def == want, "NRPICK open %d: the game choice shows its option (%s; selected %s, default %s)", n, tostring(want), tostring(sel), tostring(def))
            local o3 = ourLook(rows["nr-r3"] and rows["nr-r3"][1].w)
            check(o3 ~= nil and str(try(function() return o3.lbl:GetText() end)) == "No Like Row (Skel)" and str(try(function() return o3.q:GetText() end)) == "?",
                "NRFALLBACK open %d: the Overlay_NOPE row has its label and \"?\"", n)
            local path = rows["nr-r1"] and pathOf(rows["nr-r1"][1].w)
            local new = path ~= nil and not S.paths[path]
            if path then S.paths[path] = true end
            check(new and core().ui.row.isShown(S.r1) and core().ui.choice.isShown(S.gc), "NRNEW open %d: a new row widget (%s), row and game choice shown", n, tostring(path))
            S.allOk = S.allOk and oneOk and lookOk and m ~= nil and sel == want and new
        end

        for n = 1, OPENS do
            openOnce("menu1", n)
            step("nr: open check " .. n, function() verify(n) end)
            backOnce("menu1", n)
        end
        step("nr: ten opens", function()
            local seen, k = {}, 0
            for i = 1, OPENS do local p = S.opens[i] if p and not seen[p] then seen[p] = true; k = k + 1 end end
            local pk = 0
            for _ in pairs(S.paths) do pk = pk + 1 end
            local st = core().ui.text.stats()
            check(S.allOk and k == OPENS and pk == OPENS and countEv("lost") == 0,
                "NRTEN %d opens by real clicks: every row once with its look re-copied, the game choice showing its option; %d distinct screens, %d distinct row widgets, lost=%d (likeCopies=%d likeFallbacks=%d gameTips=%d)",
                OPENS, k, pk, countEv("lost"), st.likeCopies, st.likeFallbacks, st.gameTips)
        end)

        -- The final open: CONFIGURE, the rows' screenshot, a real hover over our "?", a real click on the next arrow, set.
        local FINAL = OPENS + 1
        openOnce("menu1", FINAL)
        step("nr: final check", function() verify(FINAL) end)
        clickAt("CONFIGURE", function() return prop(screen(), "Button_216") end)
        settle("configure", 1.5)
        step("nr: configure check", function()
            local s = screen()
            local sb = s and rootOf(s) and findIn(rootOf(s), "ScrollBox_54")
            if sb then pcall(function() sb:ScrollToStart() end) end
            local vis = try(function() return prop(s, "Overlay_0"):GetVisibility() end)
            check(vis ~= nil and vis ~= 1 and vis ~= 2, "NRCONFIG CONFIGURE shows the world settings (Overlay_0 visibility %s)", tostring(vis))
        end)
        settle("scroll", 1)
        shot("nr-rows")
        step("nr: hover", function()
            local o = ourLook(rowW("nr-r1"))
            local r = o and X.absR(o.q)
            if not check(r ~= nil and r.r > r.l, "NRQPOINT our \"?\" has a screen rectangle") then return end
            local x, y = center(r)
            say("NRMOVE the \"?\" of nr-r1 at (%d,%d)", x, y)
            return X.request(string.format("move %d %d", x, y)), 40, "move over the ?"
        end)
        settle("hover", 2)
        shot("nr-tip")
        step("nr: tooltip check", function()
            local o = ourLook(rowW("nr-r1"))
            local tip = o and prop(o.q, "ToolTipWidget")
            local desc = tip and str(try(function() return tip.Description end))
            local lines = desc and select(2, desc:gsub("\n", "")) + 1 or 0
            local vis = o and try(function() return o.q:GetVisibility() end)
            check(tip ~= nil and clsName(tip) == "W_ToolTip3_C" and desc == HELP3 and lines == 3 and vis == 0,
                "NRTIP the \"?\"'s ToolTipWidget is a %s whose Description has %d lines (Visible %s)", tip and clsName(tip) or "nil", lines, tostring(vis == 0))
            local hov = o and try(function() return o.q:IsHovered() end)
            say("NRHOVER the \"?\" IsHovered=%s", tostring(hov))
        end)
        -- the next arrow of our game picker: a real click
        step("nr: arrow before", function() S.c0 = #S.calls; S.i0 = core().ui.choice.get(S.gc) end)
        clickAt("game choice next arrow", function() local m = pickerOf("nr-r1") return m and prop(m, "Button") end)
        settle("arrow", 1)
        step("nr: arrow check", function()
            local m = pickerOf("nr-r1")
            local sel = m and str(try(function() return m.SelectedOption end))
            local c = S.calls[#S.calls]
            check(#S.calls == S.c0 + 1 and c and c.i == S.i0 + 1 and c.o == OPTS[S.i0 + 1] and core().ui.choice.get(S.gc) == S.i0 + 1 and sel == OPTS[S.i0 + 1],
                "NRARROW a real click on the game choice's next arrow ran onChange once with %s (%s; %d call(s); the picker shows %s)",
                tostring(c and c.i), tostring(c and c.o), #S.calls - S.c0, tostring(sel))
        end)
        step("nr: set", function()
            local c0 = #S.calls
            core().ui.choice.set(S.gc, 2)
            local m = pickerOf("nr-r1")
            local sel, def = m and str(try(function() return m.SelectedOption end)), m and str(try(function() return m.DefaultOption end))
            check(#S.calls == c0 and sel == OPTS[2] and def == OPTS[2] and core().ui.choice.get(S.gc) == 2,
                "NRSET set(h, 2) shows %s with no callback (%d call(s))", tostring(sel), #S.calls - c0)
        end)
        settle("set", 1)
        shot("nr-set")
        clickAt("CONFIRM WORLD SETTINGS", function() return prop(screen(), "Create_3") end)
        settle("confirm", 1)
        backOnce("menu1", FINAL)
        step("nr: end", function()
            check(countEv("opened") == FINAL and countEv("closed") == FINAL and countEv("lost") == 0,
                "NREVENTS opened=%d closed=%d lost=%d (expected %d, %d, 0)", countEv("opened"), countEv("closed"), countEv("lost"), FINAL, FINAL)
            local U = core().ui
            for _, h in ipairs({ S.r1, S.r2, S.r3 }) do pcall(U.row.remove, h) end
            pcall(U.choice.remove, S.gc); pcall(U.checkbox.remove, S.cb)
            pcall(U.game.unwatch, S.tok)
        end)
    end

    return NR
end
