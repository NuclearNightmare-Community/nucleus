-- <Core>SkelTest's catalog part (Mod Manager v2 story 2: <Core>_CatalogRefresh, <Core>_CatalogDownload, <Core>_CatalogPoll
-- and core.catalog), loaded by main.lua with dofile (main.lua is at Lua's 200-locals limit). Takes main.lua's helpers and
-- returns:
--   badInput(phase)  the cat-* cases: every native's argument checks (count, types, floats, ranges, the id normalizer,
--                    semver, sizes) and the core.catalog wrappers; at menu1 also the flow: a download before any refresh
--                    is "no verified catalog", one refresh started, a second start and a download while it runs are
--                    "busy", the job polled until done (the game thread keeps ticking: the largest gap between polls is
--                    logged and must stay under 1 s), and its outcome well-formed: a known code, a message, a payload
--                    that decodes with core's JSON reader and holds the detail lines (and on ok the source, base and
--                    verified index). Whatever the live catalog or the network answers is accepted if well-formed: no
--                    test depends on it. A download after it is "not in the catalog" (ok) or "no verified catalog".
--   offThread(P)     the same natives off the game thread (inside main.lua's LoopAsync block): none touches a UObject,
--                    so argument errors and answers are the same as on the game thread
return function(X)
    local CAT = {}
    local case, E, step, check, say, CORE = X.case, X.E, X.step, X.check, X.say, X.CORE
    local nR, nD, nP = CORE .. "_CatalogRefresh", CORE .. "_CatalogDownload", CORE .. "_CatalogPoll"
    local function R(...) return _G[nR](...) end
    local function D(...) return _G[nD](...) end
    local function Pl(...) return _G[nP](...) end
    local function f(fn, ...) local a = table.pack(...) return function() return fn(table.unpack(a, 1, a.n)) end end
    local MAXJOB = (1 << 53) - 1
    local CODES = { ok = true, error = true, ["bad-signature"] = true, ["unknown-key"] = true, ["serial-rollback"] = true, ["schema-too-new"] = true,
        ["invalid-index"] = true, ["url-not-allowed"] = true }
    local function nilReason(why) return E.ret("nil, \"" .. why .. "\"", function(r) return r.n == 2 and r[1] == nil and r[2] == why end) end

    -- Argument checks of the three natives and the wrappers; P ends in "." (phase prefix).
    local function argCases(P, tag)
        local t = tag or ""
        for _, b in ipairs({ { "1", 1 }, { "nil", nil }, { "str", "x" }, { "table", {} }, { "two", 1, 2 } }) do
            local args = b[1] == "nil" and function() return nil end or function() return table.unpack(b, 2, math.max(#b, 2)) end
            case(P .. "cat-refresh-" .. b[1], nR .. "(" .. b[1] .. ")" .. t, function() return R(args()) end, E.err(nR .. ": takes no arguments"))
        end
        case(P .. "cat-dl-none", nD .. "()" .. t, f(D), E.err(nD .. ": expected 2 arguments (id, version), got 0"))
        case(P .. "cat-dl-one", nD .. "(\"a.b\")" .. t, f(D, "a.b"), E.err(nD .. ": expected 2 arguments (id, version), got 1"))
        case(P .. "cat-dl-three", nD .. "(\"a.b\", \"1.0.0\", 1)" .. t, f(D, "a.b", "1.0.0", 1), E.err(nD .. ": expected 2 arguments (id, version), got 3"))
        case(P .. "cat-dl-id-int", nD .. "(1, \"1.0.0\")" .. t, f(D, 1, "1.0.0"), E.err(nD .. ": argument 1 (id) must be a string, got an integer"))
        case(P .. "cat-dl-id-nil", nD .. "(nil, \"1.0.0\")" .. t, f(D, nil, "1.0.0"), E.err(nD .. ": argument 1 (id) must be a string, got nil"))
        case(P .. "cat-dl-id-table", nD .. "({}, \"1.0.0\")" .. t, f(D, {}, "1.0.0"), E.err(nD .. ": argument 1 (id) must be a string, got a table"))
        case(P .. "cat-dl-ver-int", nD .. "(\"a.b\", 1)" .. t, f(D, "a.b", 1), E.err(nD .. ": argument 2 (version) must be a string, got an integer"))
        case(P .. "cat-dl-ver-float", nD .. "(\"a.b\", 1.5)" .. t, f(D, "a.b", 1.5), E.err(nD .. ": argument 2 (version) must be a string, got a float"))
        case(P .. "cat-dl-ver-bool", nD .. "(\"a.b\", true)" .. t, f(D, "a.b", true), E.err(nD .. ": argument 2 (version) must be a string, got a boolean"))
        case(P .. "cat-dl-id-bare", nD .. "(\"nucleus\", \"1.0.0\")" .. t, f(D, "nucleus", "1.0.0"), E.err(nD .. ": argument 1 (id): an id needs a namespace"))
        case(P .. "cat-dl-id-url", nD .. "(\"https://github.com/a.b\", \"1.0.0\")" .. t, f(D, "https://github.com/a.b", "1.0.0"), E.err(nD .. ": argument 1 (id): an id is not a URL"))
        case(P .. "cat-dl-id-empty", nD .. "(\"\", \"1.0.0\")" .. t, f(D, "", "1.0.0"), E.err(nD .. ": argument 1 (id): an id must not be empty"))
        local long = ("a"):rep(100) .. "." .. ("b"):rep(100)
        case(P .. "cat-dl-id-201", nD .. "(<201-byte id>)" .. t, f(D, long, "1.0.0"), E.err(nD .. ": argument 1 (id): an id must be at most 200 bytes"))
        case(P .. "cat-dl-id-huge", nD .. "(<1 MiB id>)" .. t, f(D, ("a"):rep(1 << 20), "1.0.0"), E.err(nD .. ": argument 1 (id): an id must be at most 200 bytes"))
        case(P .. "cat-dl-ver-semver", nD .. "(\"a.b\", \"1.0\")" .. t, f(D, "a.b", "1.0"), E.err(nD .. ": argument 2 (version) is not semver: '1.0'"))
        case(P .. "cat-dl-ver-empty", nD .. "(\"a.b\", \"\")" .. t, f(D, "a.b", ""), E.err(nD .. ": argument 2 (version) is not semver: ''"))
        case(P .. "cat-dl-ver-lead0", nD .. "(\"a.b\", \"01.0.0\")" .. t, f(D, "a.b", "01.0.0"), E.err(nD .. ": argument 2 (version) is not semver"))
        case(P .. "cat-dl-ver-ctrl", nD .. "(\"a.b\", \"1.0.0\\1\")" .. t, f(D, "a.b", "1.0.0\1"), E.err(nD .. ": argument 2 (version) is not semver: '1.0.0?'"))
        case(P .. "cat-dl-ver-129", nD .. "(\"a.b\", <129 bytes>)" .. t, f(D, "a.b", "1.0.0-" .. ("x"):rep(123)), E.err(nD .. ": argument 2 (version) must be at most 128 bytes, got 129"))
        case(P .. "cat-poll-none", nP .. "()" .. t, f(Pl), E.err(nP .. ": expected 1 argument (job), got 0"))
        case(P .. "cat-poll-two", nP .. "(1, 2)" .. t, f(Pl, 1, 2), E.err(nP .. ": expected 1 argument (job), got 2"))
        case(P .. "cat-poll-nil", nP .. "(nil)" .. t, f(Pl, nil), E.err(nP .. ": argument 1 (job) must be an integer, got nil"))
        case(P .. "cat-poll-float", nP .. "(1.5)" .. t, f(Pl, 1.5), E.err(nP .. ": argument 1 (job) must be an integer, got a float"))
        case(P .. "cat-poll-1.0", nP .. "(1.0)" .. t, f(Pl, 1.0), E.err(nP .. ": argument 1 (job) must be an integer, got a float"))
        case(P .. "cat-poll-numstr", nP .. "(\"1\")" .. t, f(Pl, "1"), E.err(nP .. ": argument 1 (job) must be an integer, got a string"))
        case(P .. "cat-poll-0", nP .. "(0)" .. t, f(Pl, 0), E.err(nP .. ": job 0 is out of range (1.." .. MAXJOB .. ")"))
        case(P .. "cat-poll--1", nP .. "(-1)" .. t, f(Pl, -1), E.err(nP .. ": job -1 is out of range"))
        case(P .. "cat-poll-2^53", nP .. "(2^53)" .. t, f(Pl, 1 << 53), E.err(nP .. ": job 9007199254740992 is out of range"))
        case(P .. "cat-poll-minint", nP .. "(math.mininteger)" .. t, f(Pl, math.mininteger), E.err(nP .. ": job " .. math.mininteger .. " is out of range"))
        case(P .. "cat-poll-max", nP .. "(2^53-1) [never issued]" .. t, f(Pl, MAXJOB), nilReason("unknown job"))
    end

    local function wrapperCases(P)
        local core = X.core()
        case(P .. "cat-has", "core.has(\"catalog\")", function() return core.has("catalog") end, E.ret("true", function(r) return r[1] == true end))
        case(P .. "cat-wrap-poll-float", "core.catalog.poll(1.5)", function() return core.catalog.poll(1.5) end, nilReason("bad job"))
        case(P .. "cat-wrap-poll-max", "core.catalog.poll(2^53-1)", function() return core.catalog.poll(MAXJOB) end, nilReason("unknown job"))
        case(P .. "cat-wrap-dl-nul", "core.catalog.download(\"a.b\\0x\", \"1.0.0\")", function() return core.catalog.download("a.b\0x", "1.0.0") end,
            nilReason("bad arguments: id must not contain a NUL byte"))
        case(P .. "cat-wrap-dl-bare", "core.catalog.download(\"nucleus\", \"1.0.0\")", function() return core.catalog.download("nucleus", "1.0.0") end,
            E.ret("nil, \"error: ... an id needs a namespace ...\"", function(r) return r[1] == nil and type(r[2]) == "string" and r[2]:find("an id needs a namespace", 1, true) ~= nil end))
    end

    function CAT.badInput(phase)
        local P = phase .. "."
        step(phase .. ": catalog cases", function()
            argCases(P)
            wrapperCases(P)
        end)
        if phase ~= "menu1" then return end
        -- The flow, once per run: a download before any refresh, a refresh polled until done, a download after it.
        local S = {}
        step(phase .. ": catalog refresh", function()
            case(P .. "cat-dl-unverified", nD .. "(\"nobody.nothing\", \"1.0.0\") [before any refresh]", f(D, "nobody.nothing", "1.0.0"), nilReason("no verified catalog"))
            local r = table.pack(pcall(R))
            S.job = r[1] and math.type(r[2]) == "integer" and r[2] or nil
            case(P .. "cat-refresh", nR .. "() [starts the job]", function() return table.unpack(r, 2, r.n) end,
                E.ret("a job id (an integer >= 1)", function(x) return x.n == 1 and math.type(x[1]) == "integer" and x[1] >= 1 end))
            if not S.job then return end
            -- Busy until it is done: the worker takes the network round trips, so these run while it is queued or running.
            case(P .. "cat-refresh-busy", nR .. "() [while a job runs]", f(R), nilReason("busy"))
            case(P .. "cat-dl-busy", nD .. "(\"nobody.nothing\", \"1.0.0\") [while a job runs]", f(D, "nobody.nothing", "1.0.0"), nilReason("busy"))
            case(P .. "cat-wrap-refresh-busy", "core.catalog.refresh() [while a job runs]", function() return X.core().catalog.refresh() end, nilReason("busy"))
            S.last, S.gap, S.polls = X.clock(), 0, 0
            say("CATALOG refresh job %d started", S.job)
        end)
        step(phase .. ": catalog refresh done", function()
            if not S.job then return end
            -- Polled once per step tick; the gap between two polls shows the game thread never waits for the worker.
            return function()
                local now = X.clock()
                S.gap = math.max(S.gap, now - S.last)
                S.last = now
                S.polls = S.polls + 1
                local ok, st = pcall(Pl, S.job)
                if not ok then S.err = st return true end
                return st == "done"
            end, 90, "catalog refresh job"
        end)
        step(phase .. ": catalog refresh result", function()
            if not S.job then return end
            check(not S.err, "CASE %s cat-poll-raise %s(%d) raised: %s", P, nP, S.job, tostring(S.err))
            local gapMs = S.gap / 1000
            say("CATALOG polls=%d largest gap between polls=%.1f ms", S.polls, gapMs)
            case(P .. "cat-poll-gap", "largest gap between polls of the running job [game thread never waits]", function() return gapMs end,
                E.ret("under 1000 ms", function(r) return r[1] < 1000 end))
            local raw = table.pack(pcall(Pl, S.job))
            case(P .. "cat-poll-done", nP .. "(" .. S.job .. ") [done]", function() return table.unpack(raw, 2, raw.n) end,
                E.ret("\"done\", a known outcome, a message, a payload string", function(r)
                    return r.n == 4 and r[1] == "done" and CODES[r[2]] == true and type(r[3]) == "string" and #r[3] > 0 and type(r[4]) == "string"
                end))
            local st, res = X.core().catalog.poll(S.job)
            local okShape = st == "done" and type(res) == "table" and type(res.payload) == "table" and type(res.payload.details) == "table" and #res.payload.details >= 1
            if okShape and res.outcome == "ok" then
                local p = res.payload
                okShape = (p.source == "network" or p.source == "copy") and type(p.index) == "table" and math.type(p.index.serial) == "integer" and
                    type(p.index_issued) == "string"
            end
            S.outcome = type(res) == "table" and res.outcome or nil
            say("CATALOG refresh outcome=%s message=%s source=%s", tostring(S.outcome), type(res) == "table" and tostring(res.message) or "?",
                type(res) == "table" and type(res.payload) == "table" and tostring(res.payload.source) or "-")
            if type(res) == "table" and type(res.payload) == "table" and type(res.payload.details) == "table" then
                for i, d in ipairs(res.payload.details) do if i <= 12 then say("CATALOG detail %s", tostring(d)) end end
            end
            case(P .. "cat-wrap-poll-done", "core.catalog.poll(" .. S.job .. ") [done, payload decoded]", function() return st, res end,
                E.ret("\"done\", { outcome, message, payload with details (and on ok source, index, index_issued) }", function() return okShape end))
            local want = S.outcome == "ok" and "not in the catalog" or "no verified catalog"
            case(P .. "cat-dl-after", nD .. "(\"nobody.nothing\", \"1.0.0\") [after the refresh: " .. tostring(S.outcome) .. "]", f(D, "nobody.nothing", "1.0.0"), nilReason(want))
            case(P .. "cat-poll-again", nP .. "(" .. S.job .. ") [kept after reading]", f(Pl, S.job), E.ret("\"done\" again", function(r) return r[1] == "done" end))
        end)
    end

    -- Inside main.lua's LoopAsync block (UE4SS's async thread).
    function CAT.offThread(P)
        argCases(P .. "off-", " [off thread]")
    end

    return CAT
end
