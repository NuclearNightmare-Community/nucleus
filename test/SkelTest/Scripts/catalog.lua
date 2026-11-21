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
--                    Mod Manager v2 story 5 (<Core>_CatalogStage, core.catalog.stage): the cat-stage-* argument cases
--                    (count, odd count, types, the normalizer, semver, sizes, an id twice) and the wrappers; at menu1 a
--                    stage before any refresh is "no verified index", one while the refresh runs "busy", and one after it
--                    of a pair no catalog has a job whose outcome is not-in-catalog (or "no verified index" when the
--                    refresh wasn't ok): nothing is ever staged in the dev copy.
--                    Mod Manager v2 story 6 (<Core>_CatalogUnstage, core.catalog.unstage): the cat-unstage-* argument
--                    cases and wrappers; at menu1 "no verified index" before the refresh, "busy" while it runs, and after
--                    it an unstage of an id no catalog has ends not-in-catalog (or "no verified index").
--   offThread(P)     the same natives off the game thread (inside main.lua's LoopAsync block): none touches a UObject,
--                    so argument errors and answers are the same as on the game thread
return function(X)
    local CAT = {}
    local case, E, step, check, say, CORE = X.case, X.E, X.step, X.check, X.say, X.CORE
    local nR, nD, nP = CORE .. "_CatalogRefresh", CORE .. "_CatalogDownload", CORE .. "_CatalogPoll"
    local nS, nU = CORE .. "_CatalogStage", CORE .. "_CatalogUnstage"
    local function Un(...) return _G[nU](...) end
    local function St(...) return _G[nS](...) end
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
        -- Mod Manager v2 story 5: <Core>_CatalogStage(id1, v1, ..., idN, vN), N 1..16.
        local cnt = nS .. ": expected 1 to 16 (id, version) pairs (2 to 32 arguments), got "
        case(P .. "cat-stage-none", nS .. "()" .. t, f(St), E.err(cnt .. "0"))
        case(P .. "cat-stage-one", nS .. "(\"a.b\")" .. t, f(St, "a.b"), E.err(cnt .. "1"))
        case(P .. "cat-stage-odd", nS .. "(\"a.b\", \"1.0.0\", \"c.d\")" .. t, f(St, "a.b", "1.0.0", "c.d"), E.err(nS .. ": expected (id, version) pairs, got an odd count of 3 arguments"))
        local many = {}
        for i = 1, 17 do many[#many + 1] = "o.m" .. i; many[#many + 1] = "1.0.0" end
        case(P .. "cat-stage-17", nS .. "(<17 pairs>)" .. t, function() return St(table.unpack(many, 1, 34)) end, E.err(cnt .. "34"))
        case(P .. "cat-stage-33", nS .. "(<33 arguments>)" .. t, function() return St(table.unpack(many, 1, 33)) end, E.err(cnt .. "33"))
        case(P .. "cat-stage-id-int", nS .. "(1, \"1.0.0\")" .. t, f(St, 1, "1.0.0"), E.err(nS .. ": argument 1 (id) must be a string, got an integer"))
        case(P .. "cat-stage-ver-nil", nS .. "(\"a.b\", nil)" .. t, f(St, "a.b", nil), E.err(nS .. ": argument 2 (version) must be a string, got nil"))
        case(P .. "cat-stage-id3-table", nS .. "(\"a.b\", \"1.0.0\", {}, \"1.0.0\")" .. t, f(St, "a.b", "1.0.0", {}, "1.0.0"),
            E.err(nS .. ": argument 3 (id) must be a string, got a table"))
        case(P .. "cat-stage-ver4-float", nS .. "(\"a.b\", \"1.0.0\", \"c.d\", 1.5)" .. t, f(St, "a.b", "1.0.0", "c.d", 1.5),
            E.err(nS .. ": argument 4 (version) must be a string, got a float"))
        case(P .. "cat-stage-ver-bool", nS .. "(\"a.b\", true)" .. t, f(St, "a.b", true), E.err(nS .. ": argument 2 (version) must be a string, got a boolean"))
        case(P .. "cat-stage-id-bare", nS .. "(\"nucleus\", \"1.0.0\")" .. t, f(St, "nucleus", "1.0.0"), E.err(nS .. ": argument 1 (id): an id needs a namespace"))
        case(P .. "cat-stage-id-empty", nS .. "(\"\", \"1.0.0\")" .. t, f(St, "", "1.0.0"), E.err(nS .. ": argument 1 (id): an id must not be empty"))
        case(P .. "cat-stage-id-201", nS .. "(<201-byte id>)" .. t, f(St, long, "1.0.0"), E.err(nS .. ": argument 1 (id): an id must be at most 200 bytes"))
        case(P .. "cat-stage-id-huge", nS .. "(<1 MiB id>)" .. t, f(St, ("a"):rep(1 << 20), "1.0.0"), E.err(nS .. ": argument 1 (id): an id must be at most 200 bytes"))
        case(P .. "cat-stage-ver-semver", nS .. "(\"a.b\", \"1.0\")" .. t, f(St, "a.b", "1.0"), E.err(nS .. ": argument 2 (version) is not semver: '1.0'"))
        case(P .. "cat-stage-ver2-semver", nS .. "(\"a.b\", \"1.0.0\", \"c.d\", \"x\")" .. t, f(St, "a.b", "1.0.0", "c.d", "x"),
            E.err(nS .. ": argument 4 (version) is not semver: 'x'"))
        case(P .. "cat-stage-ver-129", nS .. "(\"a.b\", <129 bytes>)" .. t, f(St, "a.b", "1.0.0-" .. ("x"):rep(123)), E.err(nS .. ": argument 2 (version) must be at most 128 bytes, got 129"))
        case(P .. "cat-stage-ver-ctrl", nS .. "(\"a.b\", \"1.0.0\\1\")" .. t, f(St, "a.b", "1.0.0\1"), E.err(nS .. ": argument 2 (version) is not semver: '1.0.0?'"))
        case(P .. "cat-stage-dup", nS .. "(\"a.b\", \"1.0.0\", \"A.B\", \"2.0.0\")" .. t, f(St, "a.b", "1.0.0", "A.B", "2.0.0"),
            E.err(nS .. ": argument 3 (id): a.b is listed twice"))
        -- Mod Manager v2 story 6: <Core>_CatalogUnstage(id, version), the checks of one Stage pair, exactly 2 arguments.
        local cntU = nU .. ": expected 2 arguments (id, version), got "
        case(P .. "cat-unstage-none", nU .. "()" .. t, f(Un), E.err(cntU .. "0"))
        case(P .. "cat-unstage-one", nU .. "(\"a.b\")" .. t, f(Un, "a.b"), E.err(cntU .. "1"))
        case(P .. "cat-unstage-three", nU .. "(\"a.b\", \"1.0.0\", \"c.d\")" .. t, f(Un, "a.b", "1.0.0", "c.d"), E.err(cntU .. "3"))
        case(P .. "cat-unstage-id-int", nU .. "(1, \"1.0.0\")" .. t, f(Un, 1, "1.0.0"), E.err(nU .. ": argument 1 (id) must be a string, got an integer"))
        case(P .. "cat-unstage-id-nil", nU .. "(nil, \"1.0.0\")" .. t, f(Un, nil, "1.0.0"), E.err(nU .. ": argument 1 (id) must be a string, got nil"))
        case(P .. "cat-unstage-id-table", nU .. "({}, \"1.0.0\")" .. t, f(Un, {}, "1.0.0"), E.err(nU .. ": argument 1 (id) must be a string, got a table"))
        case(P .. "cat-unstage-ver-float", nU .. "(\"a.b\", 1.5)" .. t, f(Un, "a.b", 1.5), E.err(nU .. ": argument 2 (version) must be a string, got a float"))
        case(P .. "cat-unstage-ver-bool", nU .. "(\"a.b\", true)" .. t, f(Un, "a.b", true), E.err(nU .. ": argument 2 (version) must be a string, got a boolean"))
        case(P .. "cat-unstage-id-bare", nU .. "(\"nucleus\", \"1.0.0\")" .. t, f(Un, "nucleus", "1.0.0"), E.err(nU .. ": argument 1 (id): an id needs a namespace"))
        case(P .. "cat-unstage-id-empty", nU .. "(\"\", \"1.0.0\")" .. t, f(Un, "", "1.0.0"), E.err(nU .. ": argument 1 (id): an id must not be empty"))
        case(P .. "cat-unstage-id-201", nU .. "(<201-byte id>)" .. t, f(Un, long, "1.0.0"), E.err(nU .. ": argument 1 (id): an id must be at most 200 bytes"))
        case(P .. "cat-unstage-id-huge", nU .. "(<1 MiB id>)" .. t, f(Un, ("a"):rep(1 << 20), "1.0.0"), E.err(nU .. ": argument 1 (id): an id must be at most 200 bytes"))
        case(P .. "cat-unstage-ver-semver", nU .. "(\"a.b\", \"1.0\")" .. t, f(Un, "a.b", "1.0"), E.err(nU .. ": argument 2 (version) is not semver: '1.0'"))
        case(P .. "cat-unstage-ver-empty", nU .. "(\"a.b\", \"\")" .. t, f(Un, "a.b", ""), E.err(nU .. ": argument 2 (version) is not semver: ''"))
        case(P .. "cat-unstage-ver-129", nU .. "(\"a.b\", <129 bytes>)" .. t, f(Un, "a.b", "1.0.0-" .. ("x"):rep(123)), E.err(nU .. ": argument 2 (version) must be at most 128 bytes, got 129"))
        case(P .. "cat-unstage-ver-ctrl", nU .. "(\"a.b\", \"1.0.0\\1\")" .. t, f(Un, "a.b", "1.0.0\1"), E.err(nU .. ": argument 2 (version) is not semver: '1.0.0?'"))
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
        -- Mod Manager v2 story 5: core.catalog.stage checks its list before any native call.
        case(P .. "cat-wrap-stage-empty", "core.catalog.stage({})", function() return core.catalog.stage({}) end, nilReason("bad arguments: list must not be empty"))
        case(P .. "cat-wrap-stage-str", "core.catalog.stage(\"a.b\")", function() return core.catalog.stage("a.b") end,
            nilReason("bad arguments: list must be a table of { id, version }"))
        case(P .. "cat-wrap-stage-nul", "core.catalog.stage({ { id = \"a.b\\0\", version = \"1.0.0\" } })",
            function() return core.catalog.stage({ { id = "a.b\0", version = "1.0.0" } }) end, nilReason("bad arguments: entry 1's id must not contain a NUL byte"))
        case(P .. "cat-wrap-stage-dup", "core.catalog.stage({ a.b, A.B })", function() return core.catalog.stage({ { id = "a.b", version = "1.0.0" }, { id = "A.B", version = "1.0.0" } }) end,
            E.ret("nil, \"error: ... listed twice\"", function(r) return r[1] == nil and type(r[2]) == "string" and r[2]:find("is listed twice", 1, true) ~= nil end))
        -- Mod Manager v2 story 6: core.catalog.unstage checks its arguments before any native call.
        case(P .. "cat-wrap-unstage-nul", "core.catalog.unstage(\"a.b\\0\", \"1.0.0\")", function() return core.catalog.unstage("a.b\0", "1.0.0") end,
            nilReason("bad arguments: id must not contain a NUL byte"))
        case(P .. "cat-wrap-unstage-num", "core.catalog.unstage(\"a.b\", 1)", function() return core.catalog.unstage("a.b", 1) end, nilReason("bad arguments: version must be a string"))
        case(P .. "cat-wrap-unstage-bare", "core.catalog.unstage(\"nucleus\", \"1.0.0\")", function() return core.catalog.unstage("nucleus", "1.0.0") end,
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
            case(P .. "cat-stage-unverified", nS .. "(\"nobody.nothing\", \"1.0.0\") [before any refresh]", f(St, "nobody.nothing", "1.0.0"), nilReason("no verified index"))
            case(P .. "cat-unstage-unverified", nU .. "(\"nobody.nothing\", \"1.0.0\") [before any refresh]", f(Un, "nobody.nothing", "1.0.0"), nilReason("no verified index"))
            local r = table.pack(pcall(R))
            S.job = r[1] and math.type(r[2]) == "integer" and r[2] or nil
            case(P .. "cat-refresh", nR .. "() [starts the job]", function() return table.unpack(r, 2, r.n) end,
                E.ret("a job id (an integer >= 1)", function(x) return x.n == 1 and math.type(x[1]) == "integer" and x[1] >= 1 end))
            if not S.job then return end
            -- Busy until it is done: the worker takes the network round trips, so these run while it is queued or running.
            case(P .. "cat-refresh-busy", nR .. "() [while a job runs]", f(R), nilReason("busy"))
            case(P .. "cat-dl-busy", nD .. "(\"nobody.nothing\", \"1.0.0\") [while a job runs]", f(D, "nobody.nothing", "1.0.0"), nilReason("busy"))
            case(P .. "cat-stage-busy", nS .. "(\"nobody.nothing\", \"1.0.0\") [while a job runs]", f(St, "nobody.nothing", "1.0.0"), nilReason("busy"))
            case(P .. "cat-unstage-busy", nU .. "(\"nobody.nothing\", \"1.0.0\") [while a job runs]", f(Un, "nobody.nothing", "1.0.0"), nilReason("busy"))
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
            end, 150, "catalog refresh job"
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
            -- Mod Manager v2 story 5: a stage of a pair no catalog has: a job (ok refresh) that ends not-in-catalog, or
            -- "no verified index"; nothing is staged either way.
            local sr = table.pack(pcall(St, "nobody.nothing", "1.0.0"))
            S.stageJob = sr[1] and math.type(sr[2]) == "integer" and sr[2] or nil
            case(P .. "cat-stage-after", nS .. "(\"nobody.nothing\", \"1.0.0\") [after the refresh: " .. tostring(S.outcome) .. "]", function() return table.unpack(sr, 2, sr.n) end,
                S.outcome == "ok" and E.ret("a job id", function(x) return x.n == 1 and math.type(x[1]) == "integer" and x[1] >= 1 end) or nilReason("no verified index"))
        end)
        step(phase .. ": catalog stage done", function()
            if not S.stageJob then return end
            return function()
                local ok, st = pcall(Pl, S.stageJob)
                if not ok then S.stageErr = st return true end
                return st == "done"
            end, 150, "catalog stage job"
        end)
        step(phase .. ": catalog stage result", function()
            if not S.stageJob then return end
            check(not S.stageErr, "CASE %s cat-stage-raise %s(%d) raised: %s", P, nP, S.stageJob, tostring(S.stageErr))
            local raw = table.pack(pcall(Pl, S.stageJob))
            case(P .. "cat-stage-poll", nP .. "(" .. S.stageJob .. ") [the stage of a pair no catalog has]", function() return table.unpack(raw, 2, raw.n) end,
                E.ret("\"done\", \"not-in-catalog\", a message, a payload naming the pair", function(r)
                    return r.n == 4 and r[1] == "done" and r[2] == "not-in-catalog" and type(r[3]) == "string" and type(r[4]) == "string" and r[4]:find("nobody.nothing", 1, true) ~= nil
                end))
            say("CATALOG stage outcome=%s message=%s", tostring(raw[3]), tostring(raw[4]))
        end)
        -- Mod Manager v2 story 6: an unstage of an id no catalog has: a job that ends not-in-catalog (ok refresh), or
        -- "no verified index"; nothing is ever staged in the dev copy.
        step(phase .. ": catalog unstage", function()
            local ur = table.pack(pcall(Un, "nobody.nothing", "1.0.0"))
            S.unJob = ur[1] and math.type(ur[2]) == "integer" and ur[2] or nil
            case(P .. "cat-unstage-after", nU .. "(\"nobody.nothing\", \"1.0.0\") [after the refresh: " .. tostring(S.outcome) .. "]", function() return table.unpack(ur, 2, ur.n) end,
                S.outcome == "ok" and E.ret("a job id", function(x) return x.n == 1 and math.type(x[1]) == "integer" and x[1] >= 1 end) or nilReason("no verified index"))
        end)
        step(phase .. ": catalog unstage done", function()
            if not S.unJob then return end
            return function()
                local ok, st = pcall(Pl, S.unJob)
                if not ok then S.unErr = st return true end
                return st == "done"
            end, 150, "catalog unstage job"
        end)
        step(phase .. ": catalog unstage result", function()
            if not S.unJob then return end
            check(not S.unErr, "CASE %s cat-unstage-raise %s(%d) raised: %s", P, nP, S.unJob, tostring(S.unErr))
            local raw = table.pack(pcall(Pl, S.unJob))
            case(P .. "cat-unstage-poll", nP .. "(" .. S.unJob .. ") [the unstage of an id no catalog has]", function() return table.unpack(raw, 2, raw.n) end,
                E.ret("\"done\", \"not-in-catalog\", a message, a payload naming the id", function(r)
                    return r.n == 4 and r[1] == "done" and r[2] == "not-in-catalog" and type(r[3]) == "string" and type(r[4]) == "string" and r[4]:find("nobody.nothing", 1, true) ~= nil
                end))
            say("CATALOG unstage outcome=%s message=%s", tostring(raw[3]), tostring(raw[4]))
        end)
    end

    -- Inside main.lua's LoopAsync block (UE4SS's async thread).
    function CAT.offThread(P)
        argCases(P .. "off-", " [off thread]")
    end

    return CAT
end
