-- <Core>SkelTest's staged-change part (Mod Manager v2 story 3: <Core>_ApplyStatus, <Core>_ApplyStart, <Core>_ApplyAck
-- and core.apply), loaded by main.lua with dofile (main.lua is at Lua's 200-locals limit). Takes main.lua's helpers and
-- returns:
--   badInput(phase)  the apply-* cases: every native's argument checks (Status and Start take none; Ack exactly one
--                    string of 32 lowercase hex digits) and the core.apply wrappers; the dev copy has nothing staged and
--                    no result, so status() is "none", "none", start() is nil, "nothing staged" (no helper is ever
--                    started here: the run closes the game) and ack() is nil, "no result"
--   offThread(P)     the same natives off the game thread (inside main.lua's LoopAsync block): none touches a UObject,
--                    so the answers are the same as on the game thread
return function(X)
    local AP = {}
    local case, E, step, CORE = X.case, X.E, X.step, X.CORE
    local nS, nB, nA = CORE .. "_ApplyStatus", CORE .. "_ApplyStart", CORE .. "_ApplyAck"
    local function St(...) return _G[nS](...) end
    local function Sb(...) return _G[nB](...) end
    local function Ak(...) return _G[nA](...) end
    local function f(fn, ...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end
    local TXN = "0123456789abcdef0123456789abcdef"
    local function nilReason(why) return E.ret("nil, \"" .. why .. "\"", function(r) return r.n == 2 and r[1] == nil and r[2] == why end) end
    local isNone = E.ret("\"none\", \"none\", \"\", \"\", \"\", \"0\", \"0\"", function(r)
        return r.n == 7 and r[1] == "none" and r[2] == "none" and r[3] == "" and r[4] == "" and r[5] == "" and r[6] == "0" and r[7] == "0"
    end)

    -- Argument checks of the three natives and their answers on the dev copy; P ends in "." (phase prefix).
    local function argCases(P, tag)
        local t = tag or ""
        case(P .. "apply-status", nS .. "() [dev copy]" .. t, f(St), isNone)
        case(P .. "apply-start", nB .. "() [nothing staged]" .. t, f(Sb), nilReason("nothing staged"))
        case(P .. "apply-ack", nA .. "(<32 hex>) [no result]" .. t, f(Ak, TXN), nilReason("no result"))
        for _, b in ipairs({ { "1", 1 }, { "nil", nil }, { "str", "x" }, { "table", {} }, { "true", true }, { "two", 1, 2 } }) do
            local args = b[1] == "nil" and function() return nil end or function() return table.unpack(b, 2, math.max(#b, 2)) end
            case(P .. "apply-status-" .. b[1], nS .. "(" .. b[1] .. ")" .. t, function() return St(args()) end, E.err(nS .. ": takes no arguments"))
            case(P .. "apply-start-" .. b[1], nB .. "(" .. b[1] .. ")" .. t, function() return Sb(args()) end, E.err(nB .. ": takes no arguments"))
        end
        local HEX = nA .. ": argument 1 (txn) must be 32 lowercase hex digits"
        case(P .. "apply-ack-none", nA .. "()" .. t, f(Ak), E.err(nA .. ": expected 1 argument (txn), got 0"))
        case(P .. "apply-ack-two", nA .. "(<32 hex>, 1)" .. t, f(Ak, TXN, 1), E.err(nA .. ": expected 1 argument (txn), got 2"))
        case(P .. "apply-ack-nil", nA .. "(nil)" .. t, f(Ak, nil), E.err(nA .. ": argument 1 (txn) must be a string, got nil"))
        case(P .. "apply-ack-int", nA .. "(1)" .. t, f(Ak, 1), E.err(nA .. ": argument 1 (txn) must be a string, got an integer"))
        case(P .. "apply-ack-table", nA .. "({})" .. t, f(Ak, {}), E.err(nA .. ": argument 1 (txn) must be a string, got a table"))
        case(P .. "apply-ack-short", nA .. "(<31 hex>)" .. t, f(Ak, TXN:sub(2)), E.err(HEX))
        case(P .. "apply-ack-long", nA .. "(<33 hex>)" .. t, f(Ak, TXN .. "0"), E.err(HEX))
        case(P .. "apply-ack-upper", nA .. "(<32 upper-case hex>)" .. t, f(Ak, TXN:upper()), E.err(HEX))
        case(P .. "apply-ack-path", nA .. "(\"..\\\\..\\\\x\")" .. t, f(Ak, "..\\..\\x"), E.err(HEX))
        case(P .. "apply-ack-nul", nA .. "(<31 hex .. NUL>)" .. t, f(Ak, TXN:sub(2) .. "\0"), E.err(HEX))
        case(P .. "apply-ack-huge", nA .. "(<1 MiB>)" .. t, f(Ak, ("a"):rep(1 << 20)), E.err(HEX))
    end

    local function wrapperCases(P)
        local core = X.core()
        case(P .. "apply-has", "core.has(\"apply\")", function() return core.has("apply") end, E.ret("true", function(r) return r[1] == true end))
        case(P .. "apply-wrap-status", "core.apply.status() [dev copy]", function() return core.apply.status() end,
            E.ret("{ staged = \"none\", result = \"none\", attempts = 0, changes = 0 }", function(r)
                local s = r[1]
                return r.n == 1 and type(s) == "table" and s.staged == "none" and s.result == "none" and s.txn == "" and s.attempts == 0 and s.changes == 0
            end))
        case(P .. "apply-wrap-start", "core.apply.start() [nothing staged]", function() return core.apply.start() end, nilReason("nothing staged"))
        case(P .. "apply-wrap-ack-bad", "core.apply.ack(\"x\")", function() return core.apply.ack("x") end, nilReason("bad txn"))
        case(P .. "apply-wrap-ack", "core.apply.ack(<32 hex>) [no result]", function() return core.apply.ack(TXN) end, nilReason("no result"))
    end

    function AP.badInput(phase)
        local P = phase .. "."
        step(phase .. ": apply cases", function()
            argCases(P)
            wrapperCases(P)
        end)
    end

    function AP.offThread(P)
        argCases(P .. "off-", " [off thread]")
    end

    return AP
end
