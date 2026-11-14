-- <Core>SkelTest's core.net part (core story 22, Net-1), loaded by main.lua with dofile (main.lua is at Lua's 200-locals
-- limit). Returns a function taking main.lua's helpers and returning:
--   badInput(phase)  the net-* bad-input cases as one step (menu1 = standalone, match1 = listen host)
--   offThread(P)     every core.net function off the game thread (inside main.lua's LoopAsync block)
--   run(scenario)    the pair-run roles, each on its own 250 ms game-thread loop:
--     net-host    publishes skeltest.revivesN = 8, skeltest.enemyDamage = 250 and the namespaced fixture key as soon
--                 as this machine hosts a world (before B can join), and skeltest.enemyDamage = 260 5 s after the game
--                 state's PlayerArray first holds 2 players; logs GameStateBase:GetServerWorldTimeSeconds() at each
--                 publish (NETPUB lines); checks there is exactly one <Core>Net, with authority.
--     net-client  watches revivesN (0..20) and enemyDamage (0..2000) and logs each call with the same clock
--                 (NETWATCH lines); reads enemyDamage with bounds 0..200 (out-of-bounds, one log line), publishes (must
--                 raise the client error), counts <Core>Net (exactly one, without authority), and reads both values
--                 again after the match started.
-- The test keys are skeltest.* (this mod's own mod.json id). The namespaced key goes through the channel op directly
-- (the op takes any valid id from this process; the public API never does).
return function(X)
    local N = {}
    local case, E, step, check, say, CORE = X.case, X.E, X.step, X.check, X.say, X.CORE
    local LOWER = CORE:lower()
    local FN = LOWER .. ".net."
    local NET_CLASS = "/Game/Mods/" .. CORE .. "/" .. CORE .. "Net." .. CORE .. "Net_C"
    local NET_SHORT = CORE .. "Net_C"
    local MODACTOR_CDO = "/Game/Mods/" .. CORE .. "/ModActor.Default__ModActor_C"
    local NS_KEY = "nuclearnightmare-community.skeltest-ns.x"
    local function core() return X.core() end
    local function firstLine(e) return (tostring(e):match("^[^\n]*")) end
    local function try(f) local ok, v = pcall(f) if ok then return v end return nil end
    local function micros() return _G[CORE .. "_ClockMicros"]() end

    -- <Core>Net actors in this machine's current world, by full class path.
    local function netActors()
        local out = {}
        local world = try(function() return X.pc():GetWorld():GetFullName() end)
        for _, a in ipairs(FindAllOf(NET_SHORT) or {}) do
            local cp = try(function() return a:GetClass():GetFullName() end)
            local wp = try(function() return a:GetWorld():GetFullName() end)
            if X.valid(a) and type(cp) == "string" and cp:sub(-#NET_CLASS) == NET_CLASS and wp == world then out[#out + 1] = a end
        end
        return out
    end
    local function gameState() return try(function() return X.pc():GetWorld().GameState end) end
    local function serverTime()
        local gs = gameState()
        local t = gs and try(function() return gs:GetServerWorldTimeSeconds() end)
        return type(t) == "number" and string.format("%.3f", t) or "?"
    end
    local function players()
        local gs = gameState()
        return gs and try(function() return gs.PlayerArray:GetArrayNum() end) or 0
    end

    -- ---------------------------------------------------------------- bad-input
    function N.badInput(phase)
        step(phase .. ": net cases", function()
            local P = phase .. "."
            local net = core().net
            if type(net) ~= "table" then check(false, "CASE %snet core.net is missing", P) return end
            local f = X.intFn
            local host = phase ~= "menu1"
            local function isTrue(r) return r[1] == true end
            local function pair(v, why) return E.ret(tostring(v) .. ", '" .. tostring(why) .. "'", function(r) return r[1] == v and r[2] == why end) end
            -- role
            case(P .. "net-role", "net.role() [" .. phase .. "]", f(net.role)(), E.ret(host and "'host'" or "'standalone'", function(r) return r[1] == (host and "host" or "standalone") end))
            case(P .. "net-role-arg", "net.role(1)", f(net.role)(1), E.err(FN .. "role: takes no arguments"))
            -- bad publish (each raises one clean error, in both worlds: the arguments are checked before the role)
            local PB = FN .. "publish: "
            case(P .. "net-pub-other", "net.publish('other.revivesN', 8)", f(net.publish)("other.revivesN", 8), E.err(PB .. "key 'other.revivesN' must start with this mod's own id 'skeltest.'"))
            case(P .. "net-pub-nodot", "net.publish('nodot', 8)", f(net.publish)("nodot", 8), E.err(PB .. "key 'nodot' must be <mod id>.<name>"))
            case(P .. "net-pub-name33", "net.publish('skeltest.<33 chars>', 8)", f(net.publish)("skeltest." .. string.rep("a", 33), 8), E.err("must match [A-Za-z0-9_]{1,32}"))
            case(P .. "net-pub-badchars", "net.publish('skeltest.a-b', 8)", f(net.publish)("skeltest.a-b", 8), E.err(PB .. "name 'a-b' must match [A-Za-z0-9_]{1,32}"))
            case(P .. "net-pub-10k", "net.publish(<10 kB key>, 8)", f(net.publish)(string.rep("k", 10240), 8), E.err(PB .. "key is 10240 bytes, cap 233"))
            case(P .. "net-pub-keynum", "net.publish(5, 8)", f(net.publish)(5, 8), E.err(PB .. "key must be a string, got number"))
            case(P .. "net-pub-nil", "net.publish('skeltest.x', nil)", f(net.publish)("skeltest.x", nil), E.err(PB .. "value must be an integer, got nil"))
            case(P .. "net-pub-str", "net.publish('skeltest.x', '8')", f(net.publish)("skeltest.x", "8"), E.err(PB .. "value must be an integer, got string"))
            case(P .. "net-pub-2.5", "net.publish('skeltest.x', 2.5)", f(net.publish)("skeltest.x", 2.5), E.err(PB .. "value must be an integer, got 2.5"))
            case(P .. "net-pub-nan", "net.publish('skeltest.x', 0/0)", f(net.publish)("skeltest.x", 0 / 0), E.err(PB .. "value must be an integer, got NaN"))
            case(P .. "net-pub-inf", "net.publish('skeltest.x', math.huge)", f(net.publish)("skeltest.x", math.huge), E.err(PB .. "value must be an integer, got inf"))
            case(P .. "net-pub-2^31", "net.publish('skeltest.x', 2^31)", f(net.publish)("skeltest.x", 2 ^ 31), E.err(PB .. "value must be in -2147483648..2147483647"))
            case(P .. "net-pub-2^53", "net.publish('skeltest.x', 2^53)", f(net.publish)("skeltest.x", 2 ^ 53), E.err(PB .. "value must be in -2147483648..2147483647"))
            case(P .. "net-pub-three", "net.publish('skeltest.x', 1, 2)", f(net.publish)("skeltest.x", 1, 2), E.err(PB .. "takes 2 arguments"))
            -- bad read / watch / unwatch
            local RB, WB, UB = FN .. "read: ", FN .. "watch: ", FN .. "unwatch: "
            case(P .. "net-read-keynum", "net.read(5, 0, 1)", f(net.read)(5, 0, 1), E.err(RB .. "key must be a string, got number"))
            case(P .. "net-read-nodot", "net.read('nodot', 0, 1)", f(net.read)("nodot", 0, 1), E.err(RB .. "key 'nodot' must be <mod id>.<name>"))
            case(P .. "net-read-badid", "net.read('Bad..Id.x', 0, 1)", f(net.read)("Bad..Id.x", 0, 1), E.err(RB .. "key 'Bad..Id.x': mod id"))
            case(P .. "net-read-minfloat", "net.read('skeltest.x', 0.5, 1)", f(net.read)("skeltest.x", 0.5, 1), E.err(RB .. "min must be an integer, got 0.5"))
            case(P .. "net-read-maxstr", "net.read('skeltest.x', 0, '1')", f(net.read)("skeltest.x", 0, "1"), E.err(RB .. "max must be an integer, got string"))
            case(P .. "net-read-minmax", "net.read('skeltest.x', 5, 1)", f(net.read)("skeltest.x", 5, 1), E.err(RB .. "min 5 is greater than max 1"))
            case(P .. "net-read-four", "net.read('skeltest.x', 0, 1, 2)", f(net.read)("skeltest.x", 0, 1, 2), E.err(RB .. "takes 3 arguments"))
            case(P .. "net-watch-fn", "net.watch('skeltest.x', 0, 1, 'fn')", f(net.watch)("skeltest.x", 0, 1, "fn"), E.err(WB .. "fn must be a function, got string"))
            case(P .. "net-watch-key", "net.watch(nil, 0, 1, fn)", f(net.watch)(nil, 0, 1, function() end), E.err(WB .. "key must be a string, got nil"))
            case(P .. "net-watch-minmax", "net.watch('skeltest.x', 2, 1, fn)", f(net.watch)("skeltest.x", 2, 1, function() end), E.err(WB .. "min 2 is greater than max 1"))
            case(P .. "net-unwatch-str", "net.unwatch('1')", f(net.unwatch)("1"), E.err(UB .. "id must be a number, got string"))
            case(P .. "net-unwatch-unknown", "net.unwatch(987654)", f(net.unwatch)(987654), E.ret("false", function(r) return r[1] == false end))
            -- watch: an id, then unwatch true and again false; the 65th watch in this state raises
            do
                local okW, id = pcall(net.watch, "skeltest.x", 0, 1, function() end)
                case(P .. "net-watch-ok", "net.watch('skeltest.x', 0, 1, fn)", function() return okW, id end,
                    E.ret("true, an integer id", function(r) return r[1] == true and math.type(r[2]) == "integer" end))
                if okW then
                    case(P .. "net-unwatch-ok", "net.unwatch(<that id>)", f(net.unwatch)(id), E.ret("true", isTrue))
                    case(P .. "net-unwatch-again", "net.unwatch(<that id>) again", f(net.unwatch)(id), E.ret("false", function(r) return r[1] == false end))
                end
                local ids = {}
                for i = 1, 64 do local okI, w = pcall(net.watch, "skeltest.x", 0, 1, function() end) if okI then ids[#ids + 1] = w end end
                case(P .. "net-watch-65", "net.watch(...) [65th in this state]", f(net.watch)("skeltest.x", 0, 1, function() end), E.err(WB .. "64 watches in this mod, cap 64"))
                for _, w in ipairs(ids) do pcall(net.unwatch, w) end
            end
            -- the channel op directly
            local call = core().call
            case(P .. "net-ch-noeq", "call('net-publish', 'skeltest.x')", function() return call("net-publish", "skeltest.x") end, E.callErr("err:bad-request "))
            case(P .. "net-ch-badid", "call('net-publish', 'Bad..Id.x=1')", function() return call("net-publish", "Bad..Id.x=1") end, E.callErr("err:bad-request "))
            case(P .. "net-ch-badval", "call('net-publish', 'skeltest.x=1.5')", function() return call("net-publish", "skeltest.x=1.5") end, E.callErr("err:bad-request "))
            case(P .. "net-ch-big", "call('net-publish', <300-byte payload>)", function() return call("net-publish", "skeltest.x=" .. string.rep("1", 289)) end, E.callErr("err:bad-request "))
            case(P .. "net-ch-long", "call('net-publish', <5000 bytes>)", function() return call("net-publish", string.rep("k", 5000)) end, E.callErr("err:too-long "))
            case(P .. "net-ch-none", "call('net-publish')", function() return call("net-publish") end, E.callErr("err:bad-request "))
            -- the ModActor stays local (never replicated)
            case(P .. "net-modactor", "ModActor CDO bReplicates", function() return StaticFindObject(MODACTOR_CDO).bReplicates end, E.ret("false", function(r) return r[1] == false end))
            if not host then
                case(P .. "net-pub-standalone", "net.publish('skeltest.revivesN', 8) [standalone]", f(net.publish)("skeltest.revivesN", 8), pair(false, "standalone"))
                case(P .. "net-ch-standalone", "call('net-publish', 'skeltest.x=1') [standalone]", function() return call("net-publish", "skeltest.x=1") end, E.callErr("err:standalone "))
                case(P .. "net-read-nostate", "net.read('skeltest.revivesN', 0, 20) [standalone]", f(net.read)("skeltest.revivesN", 0, 20), pair(nil, "no-state"))
                case(P .. "net-count", CORE .. "Net actors [menu]", function() return #netActors() end, E.ret("0", function(r) return r[1] == 0 end))
                return
            end
            -- host: publish then read at once; out of bounds; absent; the namespaced fixture through the channel
            case(P .. "net-pub-ok", "net.publish('skeltest.revivesN', 8) [host]", f(net.publish)("skeltest.revivesN", 8), E.ret("true", isTrue))
            case(P .. "net-read-ok", "net.read('skeltest.revivesN', 0, 20) [host, at once]", f(net.read)("skeltest.revivesN", 0, 20), E.ret("8", function(r) return r[1] == 8 end))
            case(P .. "net-pub-dmg", "net.publish('skeltest.enemyDamage', 250)", f(net.publish)("skeltest.enemyDamage", 250), E.ret("true", isTrue))
            case(P .. "net-read-oob", "net.read('skeltest.enemyDamage', 0, 200)", f(net.read)("skeltest.enemyDamage", 0, 200), pair(nil, "out-of-bounds"))
            case(P .. "net-read-absent", "net.read('skeltest.never', 0, 200)", f(net.read)("skeltest.never", 0, 200), pair(nil, "absent"))
            case(P .. "net-ch-ns", "call('net-publish', '" .. NS_KEY .. "=1')", function() return call("net-publish", NS_KEY .. "=1") end,
                E.ret("true, 'published'", function(r) return r[1] == true and r[2] == "published" end))
            case(P .. "net-read-ns", "net.read('" .. NS_KEY .. "', 0, 1)", f(net.read)(NS_KEY, 0, 1), E.ret("1", function(r) return r[1] == 1 end))
            -- the actor: exactly one, replicated, always relevant, with authority, no owner, holding this core's version and the values
            local list = netActors()
            case(P .. "net-count", CORE .. "Net actors [host match]", function() return #list end, E.ret("1", function(r) return r[1] == 1 end))
            local a = list[1]
            if a then
                case(P .. "net-actor-rep", CORE .. "Net bReplicates / bAlwaysRelevant / HasAuthority", function() return a.bReplicates, a.bAlwaysRelevant, a:HasAuthority() end,
                    E.ret("true, true, true", function(r) return r[1] == true and r[2] == true and r[3] == true end))
                case(P .. "net-actor-owner", CORE .. "Net:GetOwner()", function() return X.valid(a:GetOwner()) end, E.ret("false (no owner)", function(r) return r[1] == false end))
                case(P .. "net-actor-version", CORE .. "Net.CoreVersion", function() return a.CoreVersion:ToString() end, E.ret("'" .. core().version .. "'", function(r) return r[1] == core().version end))
                case(P .. "net-actor-state", CORE .. "Net.State", function() return a.State:ToString() end,
                    E.ret("'#1=skeltest,1.revivesN=8,1.enemyDamage=250,#2=" .. "nuclearnightmare-community.skeltest-ns,2.x=1'", function(r)
                        return r[1] == "#1=skeltest,1.revivesN=8,1.enemyDamage=250,#2=nuclearnightmare-community.skeltest-ns,2.x=1" end))
            end
            -- caps: the 17th own key, then the 65th key in all (through the channel, under other ids)
            for i = 3, 16 do pcall(net.publish, "skeltest.k" .. i, i) end
            case(P .. "net-pub-17", "net.publish('skeltest.k17', 17) [17th own key]", f(net.publish)("skeltest.k17", 17), E.err(PB .. "skeltest has 16 keys, cap 16 per mod"))
            for i = 1, 47 do call("net-publish", "skeltest-m" .. ((i - 1) // 16 + 1) .. ".k" .. i .. "=1") end
            case(P .. "net-ch-65", "call('net-publish', 'skeltest-m9.x=1') [65th key in all]", function() return call("net-publish", "skeltest-m9.x=1") end, E.callErr("err:cap 64 keys in this world, cap 64"))
            case(P .. "net-pub-65", "net.publish('skeltest.k3', 99) [an existing key at the cap]", f(net.publish)("skeltest.k3", 99), E.ret("true", isTrue))
        end)
    end

    function N.offThread(P)
        local net = core() and core().net
        if type(net) ~= "table" then return end
        for _, fn in ipairs({ "publish", "read", "watch", "unwatch", "role" }) do
            case(P .. "off-net-" .. fn, "net." .. fn .. "(...) [off thread]", function() return net[fn]("skeltest.x", 0, 1, function() end) end,
                E.err(FN .. fn .. ": called off the game thread"))
        end
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

    local function publishLogged(key, value)
        local ok, r1, r2 = pcall(core().net.publish, key, value)
        say("NETPUB %s=%d ok=%s result=%s%s server=%s us=%d players=%d", key, value, tostring(ok), tostring(r1), r2 and ("," .. tostring(r2)) or "", serverTime(), micros(), players())
        return ok and r1 == true
    end

    local function hostTick()
        local net = core().net
        local now = os.clock()
        if not R.first then
            if net.role() ~= "host" then return end
            R.first = true
            R.t0 = now
            rcheck(publishLogged("skeltest.revivesN", 8), "NETHOST published revivesN=8 at the host world's start")
            rcheck(publishLogged("skeltest.enemyDamage", 250), "NETHOST published enemyDamage=250 at the host world's start")
            local okC, r = core().call("net-publish", NS_KEY .. "=1")
            say("NETPUB %s=1 ok=%s result=%s server=%s us=%d (channel op)", NS_KEY, tostring(okC), tostring(r), serverTime(), micros())
            rcheck(okC, "NETHOST published the namespaced fixture key through the channel op")
            return
        end
        if not R.counted and now - R.t0 >= 2 then
            R.counted = true
            local list = netActors()
            local a = list[1]
            rcheck(#list == 1 and a and a:HasAuthority() == true, "NETHOST %sNet count=%d authority=%s", CORE, #list, tostring(a and a:HasAuthority()))
        end
        if not R.two and players() >= 2 then
            R.two = now
            say("NETHOST PlayerArray holds %d players server=%s", players(), serverTime())
        end
        if R.two and not R.late and now - R.two >= 5 then
            R.late = now
            rcheck(publishLogged("skeltest.enemyDamage", 260), "NETHOST published enemyDamage=260 5 s after 2 players")
        end
        if R.late and now - R.late >= 30 then finish() end
        if not R.two and now - R.t0 >= 600 then rcheck(false, "NETHOST no second player within 600 s") finish("no-join") end
    end

    local function clientTick()
        local net = core().net
        local now = os.clock()
        if not R.watching then
            R.watching = true
            R.t0 = now
            R.last = {}
            for _, w in ipairs({ { "skeltest.revivesN", 0, 20 }, { "skeltest.enemyDamage", 0, 2000 }, { NS_KEY, 0, 1 } }) do
                local key = w[1]
                local okW, err = pcall(net.watch, key, w[2], w[3], function(v, why)
                    R.last[key] = v
                    say("NETWATCH %s value=%s why=%s role=%s server=%s us=%d", key, tostring(v), tostring(why), net.role(), serverTime(), micros())
                end)
                if not okW then rcheck(false, "NETCLIENT watch %s: %s", key, firstLine(err)) end
            end
            return
        end
        if net.role() ~= "client" then
            if now - R.t0 >= 900 then rcheck(false, "NETCLIENT never a client within 900 s") finish("no-join") end
            return
        end
        if not R.got and R.last["skeltest.revivesN"] == 8 and R.last["skeltest.enemyDamage"] then
            R.got = now
            rcheck(true, "NETCLIENT revivesN=8 and enemyDamage=%s read through the watches", tostring(R.last["skeltest.enemyDamage"]))
            -- the reader's own bounds: 0..200 is out of bounds for 250 (or 260); read twice, core logs one line
            local v1, w1 = net.read("skeltest.enemyDamage", 0, 200)
            local v2, w2 = net.read("skeltest.enemyDamage", 0, 200)
            rcheck(v1 == nil and w1 == "out-of-bounds" and v2 == nil and w2 == "out-of-bounds", "NETCLIENT read enemyDamage 0..200 -> %s, %s (twice)", tostring(v1), tostring(w1))
            local okP, err = pcall(net.publish, "skeltest.revivesN", 1)
            rcheck(not okP and firstLine(err):find(FN .. "publish: only the host publishes (this machine is a client)", 1, true) ~= nil,
                "NETCLIENT publish raised: %s", okP and "(did not raise)" or firstLine(err))
            local okC, r = core().call("net-publish", "skeltest.revivesN=1")
            rcheck(not okC and tostring(r):sub(1, 11) == "err:client ", "NETCLIENT channel op on a client -> %s", tostring(r))
            rcheck(net.read(NS_KEY, 0, 1) == 1, "NETCLIENT read %s = %s", NS_KEY, tostring(net.read(NS_KEY, 0, 1)))
            local list = netActors()
            local a = list[1]
            rcheck(#list == 1 and a and a:HasAuthority() == false, "NETCLIENT %sNet count=%d authority=%s (the host's, never spawned here)", CORE, #list, tostring(a and a:HasAuthority()))
        end
        if R.got and not R.late and R.last["skeltest.enemyDamage"] == 260 then R.late = now end
        -- after the match started (the game state's StartedGame?, replicated), both values are still read
        if R.got and not R.after then
            local gs = gameState()
            local started = gs and try(function() return gs["StartedGame?"] end)
            if started == true then
                R.after = now
                local a, b = net.read("skeltest.revivesN", 0, 20), net.read("skeltest.enemyDamage", 0, 2000)
                rcheck(a == 8 and (b == 250 or b == 260), "NETCLIENT after the match started: revivesN=%s enemyDamage=%s server=%s", tostring(a), tostring(b), serverTime())
            elseif now - R.got >= 300 then
                rcheck(false, "NETCLIENT the match did not start within 300 s of the values (StartedGame?=%s)", tostring(started))
                finish("no-start")
            end
        end
        if R.after and R.late then
            rcheck(true, "NETCLIENT watch saw enemyDamage=260")
            finish()
        elseif R.after and now - R.after >= 120 then
            rcheck(false, "NETCLIENT the watch never saw enemyDamage=260")
            finish("no-260")
        end
    end

    function N.run(scenario)
        say("NETROLE %s (core %s, own id skeltest)", scenario, tostring(core().version))
        local tickFn = scenario == "net-host" and hostTick or clientTick
        local handle
        local okL, res = pcall(LoopInGameThreadWithDelay, 250, function()
            if R.done then if handle then pcall(CancelDelayedAction, handle) handle = nil end return end
            local ok, err = pcall(tickFn)
            if not ok then
                R.errors = (R.errors or 0) + 1
                if R.errors <= 3 then rcheck(false, "NETROLE tick threw: %s", firstLine(err)) end
            end
        end)
        if okL then handle = res else say("END result=FAIL checks=0 failures=1 reason=loop (%s)", firstLine(res)) end
    end

    return N
end
