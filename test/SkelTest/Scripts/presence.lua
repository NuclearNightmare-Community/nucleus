-- <Core>SkelTest's player-presence part (core story 23, Net-2), loaded by main.lua with dofile (main.lua is at Lua's
-- 200-locals limit). Returns a function taking main.lua's helpers and returning:
--   badInput(phase)  the net-presence-* bad-input cases (menu1 = standalone, match1 = listen host with no client)
--   offThread(P)     presence, watchPresence and compatible off the game thread (versionsCompatible works there)
--   run(scenario)    the pair-run roles, each on its own 250 ms game-thread loop:
--     presence-host         watches skeltest, skeltest-forge and core's own id (PRESENCEEV lines with the server
--                           clock); logs the host's own record; at B's first "joined" step 0's line and COMPAT, at
--                           B's step-3 events steps 1-3, at its step-4 events step 4 and COMPAT (each "PRESENCE
--                           step=k host=<record> b=<record>"), then "PRESENCE forge-done"; then waits for B to
--                           leave: "left" for each of B's mods, presence(B) nil, absent, and no <Core>Presence left.
--     presence-vanilla-host the same watches; once 2 players are in the game state's PlayerArray, waits 20 s and
--                           checks: one <Core>Presence, owned by the other player's controller, and no record or
--                           "joined" for anyone but the local player.
--     presence-client       (B) checks that presence, watchPresence and compatible raise the client error; finds its
--                           own <Core>Presence (with this core's CoreVersion, the moment its core sends the first
--                           report); 5 s later sends the forge sequence on it, 2 s apart, calling <Core>_SV_Report
--                           directly (step 0 core's own report, 1: 33 valid pairs, 2: 9000 x "a", 3: bad pairs,
--                           4: 50 x "<core>=<v>,skeltest=7.7.7" in one tick); 10 s after step 4 logs the server clock and
--                           leaves with GameplayStatics:OpenLevel(world, "NewMainMenu").
-- Never keeps a UObject across ticks.
return function(X)
    local N = {}
    local case, E, step, check, say, CORE = X.case, X.E, X.step, X.check, X.say, X.CORE
    local LOWER = CORE:lower()
    local FN = LOWER .. ".net."
    local PRES_CLASS = "/Game/Mods/" .. CORE .. "/" .. CORE .. "Presence." .. CORE .. "Presence_C"
    local PRES_SHORT = CORE .. "Presence_C"
    local NS = "nuclearnightmare-community.skeltest-ns"
    local CLIENT_ERR = "only the host knows presence (this machine is a client)"
    local function core() return X.core() end
    local function firstLine(e) return (tostring(e):match("^[^\n]*")) end
    local function try(f) local ok, v = pcall(f) if ok then return v end return nil end
    local function GSL() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    local function world() return try(function() return X.pc():GetWorld() end) end
    local function localPC()
        local w = world()
        return w and try(function() return GSL():GetPlayerController(w, 0) end)
    end
    local function localPS() local p = localPC() return p and try(function() return p.PlayerState end) end
    local function localPid() local ps = localPS() return ps and try(function() return ps:GetPlayerId() end) end
    local function pathOf(o) return (o:GetFullName():gsub("^%S+ ", "")) end
    local function serverTime()
        local w = world()
        local t = w and try(function() return w.GameState:GetServerWorldTimeSeconds() end)
        return type(t) == "number" and string.format("%.3f", t) or "?"
    end
    local function players()
        local w = world()
        return w and try(function() return w.GameState.PlayerArray:GetArrayNum() end) or 0
    end
    -- Live, by the KismetSystemLibrary:IsValid UFunction: FindAllOf keeps returning a destroyed actor until the next GC,
    -- and UE4SS's IsValid() still says it's fine (AGENTS.md).
    local function alive(o)
        if not X.valid(o) then return false end
        local ok, r = pcall(function()
            return StaticFindObject("/Script/Engine.KismetSystemLibrary:IsValid")(StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"), o)
        end)
        return ok and r == true
    end
    -- <Core>Presence actors in this machine's current world, by full class path.
    local function presActors()
        local out = {}
        local wp = try(function() return world():GetFullName() end)
        for _, a in ipairs(FindAllOf(PRES_SHORT) or {}) do
            local cp = try(function() return a:GetClass():GetFullName() end)
            local aw = try(function() return a:GetWorld():GetFullName() end)
            if alive(a) and type(cp) == "string" and cp:sub(-#PRES_CLASS) == PRES_CLASS and aw == wp then out[#out + 1] = a end
        end
        return out
    end
    -- A record as a string, from presence() for the ids this test knows (in a fixed order).
    local IDS = { LOWER, "skeltest", "skeltest-forge", NS }
    local function record(pid)
        local out = {}
        for _, id in ipairs(IDS) do
            local okP, v = pcall(core().net.presence, pid, id)
            if okP and v then out[#out + 1] = id .. "=" .. v end
        end
        return #out > 0 and table.concat(out, ",") or "none"
    end

    -- ---------------------------------------------------------------- bad-input
    local WS = {}
    function N.badInput(phase)
        step(phase .. ": presence cases", function()
            local P = phase .. ".net-presence-"
            local net = core().net
            if type(net) ~= "table" or type(net.presence) ~= "function" then check(false, "CASE %s core.net.presence is missing", P) return end
            local f = X.intFn
            local pid = localPid()
            local function pair(v, why) return E.ret(tostring(v) .. ", '" .. tostring(why) .. "'", function(r) return r[1] == v and r[2] == why end) end
            local function is(v) return E.ret("'" .. tostring(v) .. "'", function(r) return r[1] == v end) end
            local PR, WP, CP, VC = FN .. "presence: ", FN .. "watchPresence: ", FN .. "compatible: ", FN .. "versionsCompatible: "
            case(P .. "pid", "the local player's PlayerId [" .. phase .. "]", function() return pid end, E.ret("an integer", function(r) return math.type(r[1]) == "integer" end))
            -- the local player's record is the local list (this test dependent registered skeltest 0.1.0 at connect)
            case(P .. "local-pid", "net.presence(<local PlayerId>, 'skeltest')", f(net.presence)(pid, "skeltest"), is("0.1.0"))
            case(P .. "local-ps", "net.presence(<local PlayerState>, 'skeltest')", f(net.presence)(localPS(), "skeltest"), is("0.1.0"))
            case(P .. "local-core", "net.presence(<local PlayerId>, '" .. LOWER .. "')", f(net.presence)(pid, LOWER), is(core().version))
            case(P .. "absent-pid", "net.presence(999999, 'skeltest')", f(net.presence)(999999, "skeltest"), pair(nil, "absent"))
            case(P .. "absent-mod", "net.presence(<local PlayerId>, 'nosuchmod')", f(net.presence)(pid, "nosuchmod"), pair(nil, "absent"))
            -- a 33-character bare id is a valid legacy net id since 2026-11-14 (up to 64): absent, not an error
            case(P .. "mod-33", "net.presence(<local>, <33-character bare id>)", f(net.presence)(pid, string.rep("a", 33)), pair(nil, "absent"))
            case(P .. "compat-local", "net.compatible(<local PlayerId>, 'skeltest')", f(net.compatible)(pid, "skeltest"), E.ret("true", function(r) return r[1] == true end))
            case(P .. "compat-absent", "net.compatible(999999, 'skeltest')", f(net.compatible)(999999, "skeltest"), pair(false, "absent"))
            case(P .. "compat-nomod", "net.compatible(<local>, 'nosuchmod')", f(net.compatible)(pid, "nosuchmod"), pair(false, "absent"))
            -- bad players
            case(P .. "player-str", "net.presence('x', 'skeltest')", f(net.presence)("x", "skeltest"), E.err(PR .. "player must be a PlayerState or an integer PlayerId, got string"))
            case(P .. "player-nil", "net.presence(nil, 'skeltest')", f(net.presence)(nil, "skeltest"), E.err(PR .. "player must be a PlayerState or an integer PlayerId, got nil"))
            case(P .. "player-float", "net.presence(1.5, 'skeltest')", f(net.presence)(1.5, "skeltest"), E.err(PR .. "player must be a PlayerState or an integer PlayerId, got 1.5"))
            case(P .. "player-bool", "net.presence(true, 'skeltest')", f(net.presence)(true, "skeltest"), E.err(PR .. "player must be a PlayerState or an integer PlayerId, got boolean"))
            case(P .. "player-table", "net.presence({}, 'skeltest')", f(net.presence)({}, "skeltest"), E.err(PR .. "player must be a PlayerState or an integer PlayerId, got table"))
            case(P .. "player-2^40", "net.presence(2^40, 'skeltest')", f(net.presence)(1 << 40, "skeltest"), E.err(PR .. "player id 1099511627776 is outside"))
            case(P .. "player-notps", "net.presence(<the local player controller>, 'skeltest')", f(net.presence)(localPC(), "skeltest"), E.err(PR .. "player is not a PlayerState"))
            do
                -- a dead object: an actor spawned and destroyed just now (pending kill: KismetSystemLibrary:IsValid is false)
                local w = world()
                local a = w and try(function() return w:SpawnActor(StaticFindObject("/Script/Engine.Actor"), { X = 0, Y = 0, Z = -50000 }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
                if a then pcall(function() a:K2_DestroyActor() end) end
                case(P .. "player-dead", "net.presence(<an actor destroyed just now>, 'skeltest')", f(net.presence)(a, "skeltest"), E.err(PR .. "player is not a live object"))
            end
            -- bad mod ids
            case(P .. "mod-num", "net.presence(<local>, 5)", f(net.presence)(pid, 5), E.err(PR .. "modId must be a string, got number"))
            case(P .. "mod-empty", "net.presence(<local>, '')", f(net.presence)(pid, ""), E.err(PR .. "modId is empty"))
            case(P .. "mod-badid", "net.presence(<local>, 'Bad_Id')", f(net.presence)(pid, "Bad_Id"), E.err(PR .. "modId 'Bad_Id' is not a normalized mod id"))
            case(P .. "mod-65", "net.presence(<local>, <65-character bare id>)", f(net.presence)(pid, string.rep("a", 65)), E.err(PR .. "modId 'aaaa"))
            case(P .. "mod-201", "net.presence(<local>, <201 characters>)", f(net.presence)(pid, string.rep("a", 201)), E.err(PR .. "modId is 201 characters, cap 200"))
            case(P .. "three", "net.presence(<local>, 'skeltest', 1)", f(net.presence)(pid, "skeltest", 1), E.err(PR .. "takes 2 arguments (player, modId)"))
            case(P .. "watch-fn", "net.watchPresence('skeltest', 'fn')", f(net.watchPresence)("skeltest", "fn"), E.err(WP .. "fn must be a function, got string"))
            case(P .. "watch-mod", "net.watchPresence(nil, fn)", f(net.watchPresence)(nil, function() end), E.err(WP .. "modId must be a string, got nil"))
            case(P .. "watch-badid", "net.watchPresence('Bad_Id', fn)", f(net.watchPresence)("Bad_Id", function() end), E.err(WP .. "modId 'Bad_Id' is not a normalized mod id"))
            case(P .. "watch-three", "net.watchPresence('skeltest', fn, 1)", f(net.watchPresence)("skeltest", function() end, 1), E.err(WP .. "takes 2 arguments (modId, fn)"))
            do
                local ids = {}
                for _ = 1, 64 do local okI, w = pcall(net.watchPresence, "skeltest", function() end) if okI then ids[#ids + 1] = w end end
                case(P .. "watch-65", "net.watchPresence(...) [65th in this state]", f(net.watchPresence)("skeltest", function() end), E.err(WP .. "64 presence watches in this mod, cap 64"))
                for _, w in ipairs(ids) do pcall(net.unwatch, w) end
            end
            case(P .. "compat-player", "net.compatible('x', 'skeltest')", f(net.compatible)("x", "skeltest"), E.err(CP .. "player must be a PlayerState or an integer PlayerId, got string"))
            case(P .. "compat-mod", "net.compatible(<local>, 5)", f(net.compatible)(pid, 5), E.err(CP .. "modId must be a string, got number"))
            case(P .. "compat-three", "net.compatible(<local>, 'skeltest', 1)", f(net.compatible)(pid, "skeltest", 1), E.err(CP .. "takes 2 arguments (player, modId)"))
            -- versionsCompatible: the matrix rows, malformed versions, netCompat above version, non-strings
            local vc = net.versionsCompatible
            case(P .. "vc-1", "versionsCompatible('0.1.0', nil, '0.1.9', nil)", f(vc)("0.1.0", nil, "0.1.9", nil), E.ret("true", function(r) return r[1] == true end))
            case(P .. "vc-2", "versionsCompatible('1.2.0', nil, '1.9.0', nil)", f(vc)("1.2.0", nil, "1.9.0", nil), E.ret("true", function(r) return r[1] == true end))
            case(P .. "vc-3", "versionsCompatible('0.3.0', '0.1.0', '0.1.0', nil)", f(vc)("0.3.0", "0.1.0", "0.1.0", nil), E.ret("true", function(r) return r[1] == true end))
            case(P .. "vc-4", "versionsCompatible('0.3.0', nil, '0.1.0', nil)", f(vc)("0.3.0", nil, "0.1.0", nil), E.ret("false", function(r) return r[1] == false end))
            case(P .. "vc-short", "versionsCompatible('1.0', nil, '1.0.0', nil)", f(vc)("1.0", nil, "1.0.0", nil), E.err(VC .. "aVersion '1.0' is not a strict <major>.<minor>.<patch> version"))
            case(P .. "vc-1000", "versionsCompatible('1.0.0', nil, '1.0.1000', nil)", f(vc)("1.0.0", nil, "1.0.1000", nil), E.err(VC .. "bVersion '1.0.1000' is not a strict"))
            case(P .. "vc-num", "versionsCompatible(1, nil, '1.0.0', nil)", f(vc)(1, nil, "1.0.0", nil), E.err(VC .. "aVersion must be a string, got number"))
            case(P .. "vc-ncnum", "versionsCompatible('1.0.0', 5, '1.0.0', nil)", f(vc)("1.0.0", 5, "1.0.0", nil), E.err(VC .. "aNetCompat must be a string, got number"))
            case(P .. "vc-above", "versionsCompatible('1.0.0', '1.1.0', '1.0.0', nil)", f(vc)("1.0.0", "1.1.0", "1.0.0", nil), E.err(VC .. "aNetCompat 1.1.0 is above aVersion 1.0.0"))
            case(P .. "vc-five", "versionsCompatible('1.0.0', nil, '1.0.0', nil, 1)", f(vc)("1.0.0", nil, "1.0.0", nil, 1), E.err(VC .. "takes 4 arguments"))
            -- the channel ops directly
            local call = core().call
            local function reply(r1, r2) return E.ret("true, '" .. r2 .. "'", function(r) return r[1] == r1 and r[2] == r2 end) end
            case(P .. "ch-big", "call('net-mod', <300-byte payload>)", function() return call("net-mod", "skeltest-x=" .. string.rep("1", 289)) end, E.callErr("err:bad-request "))
            case(P .. "ch-noeq", "call('net-mod', 'skeltest-x')", function() return call("net-mod", "skeltest-x") end, E.callErr("err:bad-request "))
            case(P .. "ch-badid", "call('net-mod', 'Bad_Id=1.0.0')", function() return call("net-mod", "Bad_Id=1.0.0") end, E.callErr("err:bad-request "))
            case(P .. "ch-badver", "call('net-mod', 'skeltest-x=1.0')", function() return call("net-mod", "skeltest-x=1.0") end, E.callErr("err:bad-request "))
            case(P .. "ch-ncabove", "call('net-mod', 'skeltest-x=1.0.0/1.1.0')", function() return call("net-mod", "skeltest-x=1.0.0/1.1.0") end, E.callErr("err:bad-request "))
            case(P .. "ch-core", "call('net-mod', '" .. LOWER .. "=9.9.9')", function() return call("net-mod", LOWER .. "=9.9.9") end, E.callErr("err:bad-request "))
            case(P .. "ch-none", "call('net-mod')", function() return call("net-mod") end, E.callErr("err:bad-request "))
            case(P .. "ch-long", "call('net-mod', <5000 bytes>)", function() return call("net-mod", string.rep("k", 5000)) end, E.callErr("err:too-long "))
            do
                -- the 33rd entry: fill the list (core, the test dependents and these) to 32, then one more
                local added, last = {}, nil
                for i = 1, 40 do
                    local okR, r = call("net-mod", "skeltest-f" .. i .. "=1.0.0")
                    if okR then added[#added + 1] = "skeltest-f" .. i else last = { okR, r } break end
                end
                case(P .. "ch-33", "call('net-mod', <the 33rd entry>)", function() return last and last[1], last and last[2] end, E.callErr("err:cap 32 entries, cap 32"))
                for _, id in ipairs(added) do call("net-mod-off", id) end
            end
            case(P .. "ch-off-unknown", "call('net-mod-off', 'skeltest-never')", function() return call("net-mod-off", "skeltest-never") end, reply(true, "unknown"))
            case(P .. "ch-off-badid", "call('net-mod-off', 'Bad_Id')", function() return call("net-mod-off", "Bad_Id") end, E.callErr("err:bad-request "))
            case(P .. "ch-off-none", "call('net-mod-off')", function() return call("net-mod-off") end, E.callErr("err:bad-request "))
            -- a namespaced id with netCompat, through the op: in the local record at once, and gone again
            case(P .. "ch-ns", "call('net-mod', '" .. NS .. "=0.3.0/0.1.0')", function() return call("net-mod", NS .. "=0.3.0/0.1.0") end, reply(true, "registered"))
            case(P .. "ns-read", "net.presence(<local>, '" .. NS .. "')", f(net.presence)(pid, NS), is("0.3.0"))
            case(P .. "ch-ns-off", "call('net-mod-off', '" .. NS .. "')", function() return call("net-mod-off", NS) end, reply(true, "removed"))
            case(P .. "ns-gone", "net.presence(<local>, '" .. NS .. "') after net-mod-off", f(net.presence)(pid, NS), pair(nil, "absent"))
            -- no <Core>Presence: none in the menu, none for the host's own controller
            case(P .. "count", CORE .. "Presence actors [" .. phase .. "]", function() return #presActors() end, E.ret("0", function(r) return r[1] == 0 end))
            if phase == "menu1" then
                -- Before the first world: no dependent connects that early (connect waits for core's class, which a
                -- world loads), so the state is reproduced through net/client.lua's test hook: role "none", no snapshot.
                local NC = require(LOWER .. ".net.client")
                local real = NC._getShared
                NC._getShared = function(k)
                    if k == LOWER .. ".net.role" then return "none" end
                    if k == LOWER .. ".net.gen" or k == LOWER .. ".net.presence.gen" then return -7 end
                    if k == LOWER .. ".net.presence" then return "" end
                    return real(k)
                end
                local okA, a1, a2 = pcall(net.presence, pid, "skeltest")
                local okB, b1, b2 = pcall(net.compatible, pid, "skeltest")
                NC._getShared = real
                case(P .. "noworld", "net.presence(<local>, 'skeltest') [no world yet]", function() return okA and a1, okA and a2 end, pair(nil, "no-world"))
                case(P .. "compat-noworld", "net.compatible(<local>, 'skeltest') [no world yet]", function() return okB and b1, okB and b2 end, pair(false, "no-world"))
            end
        end)
        -- watchPresence: the local player's "joined" at the first poll, then unwatch through core.net.unwatch
        step(phase .. ": presence watch", function()
            WS[phase] = { ev = {} }
            local W = WS[phase]
            local okW, id = pcall(core().net.watchPresence, "skeltest", function(ev, p, v, prev) W.ev[#W.ev + 1] = { ev, p, v, prev } end)
            W.id = okW and id or nil
            case(phase .. ".net-presence-watch-ok", "net.watchPresence('skeltest', fn)", function() return okW, id end,
                E.ret("true, an integer id", function(r) return r[1] == true and math.type(r[2]) == "integer" end))
            return function() return #W.ev > 0 end, 5, phase .. " presence watch event"
        end)
        step(phase .. ": presence watch event", function()
            local W = WS[phase]
            local pid = localPid()
            local e = W.ev[1] or {}
            case(phase .. ".net-presence-watch-joined", "watchPresence('skeltest') first event", function() return e[1], e[2], e[3], e[4] end,
                E.ret("'joined', <local PlayerId>, '0.1.0', nil", function(r) return r[1] == "joined" and r[2] == pid and r[3] == "0.1.0" and r[4] == nil end))
            if W.id then
                case(phase .. ".net-presence-unwatch", "net.unwatch(<presence watch id>)", X.intFn(core().net.unwatch)(W.id), E.ret("true", function(r) return r[1] == true end))
                case(phase .. ".net-presence-unwatch-again", "net.unwatch(<presence watch id>) again", X.intFn(core().net.unwatch)(W.id), E.ret("false", function(r) return r[1] == false end))
            end
        end)
    end

    function N.offThread(P)
        local net = core() and core().net
        if type(net) ~= "table" or type(net.presence) ~= "function" then return end
        case(P .. "off-net-presence", "net.presence(...) [off thread]", function() return net.presence(1, "skeltest") end, E.err(FN .. "presence: called off the game thread"))
        case(P .. "off-net-watchPresence", "net.watchPresence(...) [off thread]", function() return net.watchPresence("skeltest", function() end) end, E.err(FN .. "watchPresence: called off the game thread"))
        case(P .. "off-net-compatible", "net.compatible(...) [off thread]", function() return net.compatible(1, "skeltest") end, E.err(FN .. "compatible: called off the game thread"))
        case(P .. "off-net-versionsCompatible", "net.versionsCompatible(...) [off thread, pure]", function() return net.versionsCompatible("0.1.0", nil, "0.1.2", nil) end,
            E.ret("true", function(r) return r[1] == true end))
    end

    -- ---------------------------------------------------------------- pair-run roles
    local R = { checks = 0, failures = 0 }
    local function rcheck(cond, fmt, ...)
        R.checks = R.checks + 1
        if not cond then R.failures = R.failures + 1 end
        say("%s " .. fmt, cond and "OK" or "FAIL", ...)
        return cond
    end
    local function finish(why)
        if R.done then return end
        R.done = true
        say("END result=%s checks=%d failures=%d%s", (R.failures == 0 and R.checks > 0) and "PASS" or "FAIL", R.checks, R.failures, why and (" reason=" .. why) or "")
    end
    local function startWatches()
        R.ev = {}
        for _, id in ipairs({ LOWER, "skeltest", "skeltest-forge" }) do
            local okW, err = pcall(core().net.watchPresence, id, function(ev, p, v, prev)
                R.ev[#R.ev + 1] = { ev = ev, pid = p, mod = id, v = v, prev = prev, at = os.clock() }
                say("PRESENCEEV %s pid=%d mod=%s version=%s previous=%s local=%s server=%s", ev, p, id, tostring(v), tostring(prev), tostring(p == localPid()), serverTime())
            end)
            if not okW then rcheck(false, "PRESENCE watchPresence(%s): %s", id, firstLine(err)) end
        end
    end

    local V = function() return core().version end
    local function hostTick(vanilla)
        local net = core().net
        local now = os.clock()
        if not R.started then
            if net.role() ~= "host" then return end
            local pid = localPid()
            if pid == nil then return end
            R.started, R.t0, R.pid = true, now, pid
            startWatches()
            local own = record(pid)
            rcheck(own == LOWER .. "=" .. V() .. ",skeltest=0.1.0", "PRESENCE host record pid=%d %s server=%s", pid, own, serverTime())
            return
        end
        if vanilla then
            if not R.two and players() >= 2 then R.two = now; say("PRESENCE PlayerArray holds %d players server=%s", players(), serverTime()) end
            if R.two and now - R.two >= 20 then
                local list = presActors()
                local a = list[1]
                local owner = a and try(function() return a:GetOwner() end)
                local mine = localPC()
                local ownerOk = owner ~= nil and X.valid(owner) and mine ~= nil and pathOf(owner) ~= pathOf(mine)
                rcheck(#list == 1 and ownerOk, "PRESENCE vanilla: %sPresence count=%d owned by another player's controller=%s", CORE, #list, tostring(ownerOk))
                local foreign = 0
                for _, e in ipairs(R.ev) do if e.pid ~= R.pid then foreign = foreign + 1 end end
                rcheck(foreign == 0, "PRESENCE vanilla: no event for another player (%d)", foreign)
                rcheck(record(R.pid) == LOWER .. "=" .. V() .. ",skeltest=0.1.0", "PRESENCE vanilla: the host's own record %s", record(R.pid))
                finish()
            elseif not R.two and now - R.t0 >= 600 then rcheck(false, "PRESENCE no second player within 600 s") finish("no-join") end
            return
        end
        -- The forge checks follow B's events, not a clock: B starts its forge 5 s after it SENDS its first report, and on
        -- a real join that first report can reach the host seconds late (B's game stalls right after loading the map),
        -- so a host clock started at B's "joined" runs behind B's steps (pair run 2026-11-14 16:22). Reliable RPCs on one
        -- actor arrive in order, so step 3's events (left skeltest, joined skeltest-forge) come after steps 0-2 were
        -- handled, and no event for B before them means steps 0-2 left B's record unchanged; step 4's events (joined
        -- skeltest 7.7.7, left skeltest-forge) end the sequence.
        local WANT = {
            [0] = LOWER .. "=" .. V() .. ",skeltest=0.1.0",
            [1] = LOWER .. "=" .. V() .. ",skeltest=0.1.0",
            [2] = LOWER .. "=" .. V() .. ",skeltest=0.1.0",
            [3] = LOWER .. "=" .. V() .. ",skeltest-forge=1.0.0",
            [4] = LOWER .. "=" .. V() .. ",skeltest=7.7.7",
        }
        local function stepLine(k, b)
            local h = record(R.pid)
            rcheck(h == LOWER .. "=" .. V() .. ",skeltest=0.1.0" and b == WANT[k], "PRESENCE step=%d host=%s b=%s server=%s", k, h, b, serverTime())
        end
        local function compatLine(want)
            local c1, c2 = net.compatible(R.b, "skeltest")
            local got = tostring(c1) .. (c2 and (" " .. tostring(c2)) or "")
            rcheck(got == want, "COMPAT b=%s", got)
        end
        -- B's events after index i, leaving out its own join (the first "joined" for each id of its joined record)
        local function bEvents(i)
            local out, seen = {}, {}
            for j = 1, #R.ev do
                local e = R.ev[j]
                if e.pid == R.b then
                    local isJoin = e.ev == "joined" and e.prev == nil and R.joinIds[e.mod] and not seen[e.mod]
                    if isJoin then seen[e.mod] = true end
                    if j > i and not isJoin then out[#out + 1] = e end
                end
            end
            return out
        end
        local function desc(list)
            local t = {}
            for _, e in ipairs(list) do t[#t + 1] = e.ev .. ":" .. e.mod .. "=" .. tostring(e.v) .. "<-" .. tostring(e.prev) end
            return table.concat(t, ";")
        end
        if not R.b then
            for _, e in ipairs(R.ev) do
                if e.ev == "joined" and e.pid ~= R.pid then R.b, R.joinAt = e.pid, now break end
            end
            if not R.b and now - R.t0 >= 600 then rcheck(false, "PRESENCE no modded player joined within 600 s") finish("no-join") end
            if not R.b then return end
            local rb = record(R.b)
            rcheck(rb == LOWER .. "=" .. V() .. ",skeltest=0.1.0", "PRESENCE joined b=%d %s server=%s", R.b, rb, serverTime())
            R.joinIds = {}
            for id in rb:gmatch("([^,=]+)=[^,]+") do R.joinIds[id] = true end
            -- step 0 resends B's first report; the record (and compatible) it leaves is the joined one, and step 3's
            -- check below proves nothing changed in between
            stepLine(0, rb)
            compatLine("true")
            R.phase, R.mark = 3, 0
            return
        end
        if R.phase == 3 or R.phase == 4 then
            local evs = bEvents(R.mark)
            if #evs == 0 then
                if now - R.joinAt >= 60 then
                    rcheck(false, "PRESENCE forge: no event for step %d within 60 s of B's join (B's events: %s)", R.phase, desc(bEvents(0)))
                    R.phase, R.forged = nil, now
                    say("PRESENCE forge-done server=%s", serverTime())
                end
                return
            end
            R.batchAt = R.batchAt or now
            if now - R.batchAt < (R.phase == 3 and 0.5 or 1.5) then return end   -- let the batch (and step 4's 49 floods) land
            if R.phase == 3 then
                local ok = #evs == 2
                for _, e in ipairs(evs) do
                    if not ((e.ev == "left" and e.mod == "skeltest" and e.prev == "0.1.0") or (e.ev == "joined" and e.mod == "skeltest-forge" and e.v == "1.0.0")) then ok = false end
                end
                local before = ok and WANT[1] or ("events:" .. desc(evs))
                stepLine(1, before)
                stepLine(2, before)
                stepLine(3, record(R.b))
                R.phase, R.mark, R.batchAt = 4, #R.ev, nil
            else
                stepLine(4, record(R.b))
                compatLine("false incompatible")
                R.phase, R.forged = nil, now
                say("PRESENCE forge-done server=%s", serverTime())
            end
            return
        end
        if R.forged and not R.left then
            local v, why = net.presence(R.b, "skeltest")
            if v == nil and why == "absent" then
                -- presence() reads absent as soon as core drops the record; the "left" events reach the watches a moment
                -- later (same tick, after this loop ran), so wait for both, up to 2 s
                R.absentAt = R.absentAt or now
                local leftMods = {}
                for _, e in ipairs(R.ev) do if e.ev == "left" and e.pid == R.b and e.at >= R.forged then leftMods[#leftMods + 1] = e.mod end end
                table.sort(leftMods)
                local mods = table.concat(leftMods, ",")
                if mods ~= LOWER .. ",skeltest" and now - R.absentAt < 2 then return end
                R.left = now
                rcheck(mods == LOWER .. ",skeltest", "PRESENCE b-left mods=%s presence=%s,%s server=%s", mods, tostring(v), tostring(why), serverTime())
            elseif now - R.forged >= 120 then rcheck(false, "PRESENCE B did not leave within 120 s of forge-done") finish("no-leave") end
            return
        end
        if R.left then
            local n = #presActors()
            if n == 0 then rcheck(true, "PRESENCE %sPresence count=0 after B left server=%s", CORE, serverTime()) finish()
            elseif now - R.left >= 5 then rcheck(false, "PRESENCE %sPresence count=%d 5 s after B left", CORE, n) finish("actor-left") end
        end
    end

    local function ownActor()
        local mine = localPC()
        if not mine then return nil end
        local mp = pathOf(mine)
        for _, a in ipairs(presActors()) do
            local owner = try(function() return a:GetOwner() end)
            local ver = try(function() return a.CoreVersion:ToString() end)
            if try(function() return a:HasAuthority() end) == false and owner and X.valid(owner) and pathOf(owner) == mp and ver == V() then return a end
        end
        return nil
    end

    local function clientTick()
        local net = core().net
        local now = os.clock()
        if R.leftAt then
            -- back in the menu: done
            if net.role() == "standalone" then rcheck(true, "PRESENCECL back in the menu (standalone) server-at-leave=%s", R.leaveServer) finish()
            elseif now - R.leftAt >= 60 then rcheck(false, "PRESENCECL not back in the menu 60 s after OpenLevel") finish("no-menu") end
            return
        end
        if net.role() ~= "client" then
            R.t0 = R.t0 or now
            if now - R.t0 >= 900 then rcheck(false, "PRESENCECL never a client within 900 s") finish("no-join") end
            return
        end
        if not R.raised then
            R.raised = true
            for _, c in ipairs({ { "presence", function() return net.presence(1, "skeltest") end },
                                 { "watchPresence", function() return net.watchPresence("skeltest", function() end) end },
                                 { "compatible", function() return net.compatible(1, "skeltest") end } }) do
                local okC, err = pcall(c[2])
                rcheck(not okC and firstLine(err):find(FN .. c[1] .. ": " .. CLIENT_ERR, 1, true) ~= nil, "PRESENCECL %s raised: %s", c[1], okC and "(did not raise)" or firstLine(err))
            end
        end
        if not R.hold then
            local a = ownActor()
            if a then
                R.hold = now
                say("PRESENCECL holding %s (CoreVersion %s) server=%s", try(function() return a:GetFName():ToString() end) or "?", V(), serverTime())
            end
            return
        end
        local k = R.forge or 0
        if k <= 4 and now - R.hold >= 5 + 2 * k then
            local a = ownActor()
            if not a then rcheck(false, "PRESENCECL forge step %d: lost the own actor", k) finish("no-actor") return end
            local fn = CORE .. "_SV_Report"
            local reports
            if k == 0 then reports = { LOWER .. "=" .. V() .. ",skeltest=0.1.0" }
            elseif k == 1 then
                local parts = {}
                for i = 1, 33 do parts[i] = "skeltest-p" .. i .. "=1.0.0" end
                reports = { table.concat(parts, ",") }
            elseif k == 2 then reports = { string.rep("a", 9000) }
            elseif k == 3 then reports = { LOWER .. "=" .. V() .. ",Bad_Id=1.0.0,skeltest=1.0.1000,1:skeltest=9.9.9,skeltest-forge=1.0.0" }
            else
                reports = {}
                for i = 1, 50 do reports[i] = LOWER .. "=" .. V() .. ",skeltest=7.7.7" end
            end
            local sent = 0
            for _, r in ipairs(reports) do if pcall(function() a[fn](a, r) end) then sent = sent + 1 end end
            rcheck(sent == #reports, "PRESENCECL forge step=%d sent=%d bytes=%d server=%s", k, sent, #reports[1], serverTime())
            R.forge = k + 1
            if k == 4 then R.forged = now end
            return
        end
        if R.forged and now - R.forged >= 10 then
            R.leaveServer = serverTime()
            say("PRESENCECL leaving server=%s", R.leaveServer)
            R.leftAt = now
            local w = world()
            local okL, err = pcall(function() GSL():OpenLevel(w, FName("NewMainMenu"), true, "") end)
            if not okL then rcheck(false, "PRESENCECL OpenLevel failed: %s", firstLine(err)) finish("open-level") end
        end
    end

    function N.run(scenario)
        say("PRESENCEROLE %s (core %s, own id skeltest 0.1.0)", scenario, tostring(core().version))
        local tickFn
        if scenario == "presence-host" then tickFn = function() hostTick(false) end
        elseif scenario == "presence-vanilla-host" then tickFn = function() hostTick(true) end
        else tickFn = clientTick end
        local handle
        local okL, res = pcall(LoopInGameThreadWithDelay, 250, function()
            if R.done then if handle then pcall(CancelDelayedAction, handle) handle = nil end return end
            local ok, err = pcall(tickFn)
            if not ok then
                R.errors = (R.errors or 0) + 1
                if R.errors <= 3 then rcheck(false, "PRESENCEROLE tick threw: %s", firstLine(err)) end
            end
        end)
        if okL then handle = res else say("END result=FAIL checks=0 failures=1 reason=loop (%s)", firstLine(res)) end
    end

    return N
end
