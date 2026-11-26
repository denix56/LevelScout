-- tests/test_objective.lua: ns.Objective (the objective, delta evaluation, polish) and the route caches
-- (ns.Planner.VALUE_CACHE) behind it, on the real data. Part 1 of 2 (part 2: test_objective_2.lua;
-- the setup both share: tests/objective_env.lua).
local H, M = ...
local test, eq, ok = H.test, H.eq, H.ok

local O_ = require("objective_env")(H, M)
local data, state, MAPS, with, captured, order = O_.data, O_.state, O_.MAPS, O_.with, O_.captured, O_.order
local rnd, randomMove, wellFormed = O_.rnd, O_.randomMove, O_.wellFormed

H.suite("Objective", function()
    test("the objective module exists", function()
        local ns = data()
        ok(type(ns.Objective) == "table")
        eq(ns.Objective.MODE, "worth")
        eq(ns.Objective.POLISH, false)
    end)

    test("with the caches on or off the plans are the same", function()
        local ns = data()
        for kind, maps in pairs(MAPS) do
            local st = state(kind)
            for _, map in ipairs(maps) do
                local on, off
                with({ { "Planner", "VALUE_CACHE", true } }, function() on = ns.Zones.PlanZone(map, ns.Zones.Context(st)) end)
                with({ { "Planner", "VALUE_CACHE", false } }, function() off = ns.Zones.PlanZone(map, ns.Zones.Context(st)) end)
                eq(order(on), order(off), kind .. " " .. map)
                eq(on.score, off.score, kind .. " " .. map .. " score")
            end
        end
    end)

    test("profile, gateIndex, score, worth read the same with the cache as computed from scratch", function()
        local ns = data()
        local P = ns.Planner
        for _, kind in ipairs({ "redridge", "goldshire" }) do
            local sc = captured(state(kind, kind == "goldshire" and { restedPool = 1500 } or nil), MAPS[kind][1])
            local r = sc.r
            for n = 1, 200 do
                local i, len, p = randomMove(r)
                if i then r:shift(i, len, p) end
                P.VALUE_CACHE = true
                local cp, cs, cw = r:profile(), r:score(sc.overhead), r:worth(sc.overhead)
                local cg = {}
                for g = 0, 3 do cg[g] = r:gateIndex(g) end
                -- a stop's remembered value must be what a fresh calculation gives, also for `skip`
                local node = r.route[1 + rnd(#r.route - 1)]
                local d = rnd(3) - 1
                local v1 = { r:value(node, nil, d) }
                local skip = node.kind == "W" and node.reqs[1].quest or nil
                local v1s = { r:value(node, skip, d) }
                P.VALUE_CACHE = false
                local fp, fs, fw = r:profile(), r:score(sc.overhead), r:worth(sc.overhead)
                eq(cp, fp, "profile " .. kind)
                eq(cs, fs, "score")
                eq(cw, fw, "worth")
                for g = 0, 3 do eq(cg[g], r:gateIndex(g), "gateIndex " .. g) end
                eq(v1, { r:value(node, nil, d) }, "value")
                eq(v1s, { r:value(node, skip, d) }, "value without a quest")
                P.VALUE_CACHE = true
            end
        end
    end)

    test("shift then unshift puts the route, pos and version back", function()
        local sc = captured(state("redridge"), 1433)
        local r = sc.r
        for _ = 1, 100 do
            local i, len, p = randomMove(r)
            if i then
                local before = {}
                for k, node in ipairs(r.route) do before[k] = node end
                local v = r:shift(i, len, p)
                for k, node in ipairs(r.route) do eq(r.pos[node], k, "pos after shift") end
                ok(r.version ~= v)
                r:unshift(i, len, p, v)
                eq(r.version, v)
                for k, node in ipairs(before) do ok(r.route[k] == node and r.pos[node] == k, "restored at " .. k) end
                ok(r:valid())
            end
        end
    end)

    test("runBounds is what improve works out with the run taken out", function()
        local sc = captured(state("redridge"), 1433)
        local r = sc.r
        for _ = 1, 60 do
            local len = rnd(3)
            local i = 1 + rnd(#r.route - len)
            if i >= 2 then
                local lo, hi = r:runBounds(i, len)
                local seg = {}
                for k = 1, len do seg[k] = r.route[i + k - 1] end
                for k = len, 1, -1 do r:unplace(seg[k]) end
                local l2, h2 = 1, #r.route
                for k = 1, len do
                    local l, h = r:bounds(seg[k], true)
                    if l > l2 then l2 = l end
                    if h < h2 then h2 = h end
                end
                eq({ lo, hi }, { l2, h2 }, "run at " .. i .. " of " .. len)
                for k = 1, len do r:place(seg[k], i - 1 + k - 1) end
            end
        end
    end)

    -- evalFrom after a move equals a fresh evaluation, in both modes, shortcut on and off.
    local function deltaChecks(kind, extra, mode)
        local ns = data()
        local O = ns.Objective
        local saved = { O.MODE, O.CHECK, O.SHORTCUT }
        O.MODE, O.CHECK = mode, true
        local okay, err = pcall(function()
            local sc = captured(state(kind, extra), MAPS[kind][1])
            local r = sc.r
            local ev = O.New(r, sc.overhead)
            if mode == "dinkelbach" then ev.R = ev.R * 0.9 end
            ev:commit()
            local moves, broken = 0, 0
            for _ = 1, 200 do
                local i, len, p = randomMove(r)
                if i then
                    local v = r:shift(i, len, p)
                    local fresh = ev:eval()
                    local from, same = math.min(i, p + 1), math.max(i + len, p + len + 1)
                    O.SHORTCUT = true
                    local a = ev:evalFrom(from, same)
                    O.SHORTCUT = false
                    local b = ev:evalFrom(from, same)
                    local c = ev:evalFrom(2)
                    for _, got in ipairs({ a, b, c }) do
                        ok(math.abs(got - fresh) <= 1e-9 * math.max(math.abs(fresh), 1e-9),
                            string.format("%s %s: %.12g against %.12g", kind, mode, got, fresh))
                    end
                    if mode == "dinkelbach" and fresh < 0 then
                        broken = broken + 1
                        eq(a, fresh, "a move that breaks a gate")
                    end
                    moves = moves + 1
                    r:unshift(i, len, p, v)
                end
            end
            ok(moves > 100, "moves tried: " .. moves)
        end)
        O.MODE, O.CHECK, O.SHORTCUT = saved[1], saved[2], saved[3]
        if not okay then error(err, 0) end
    end

    for _, mode in ipairs({ "worth", "dinkelbach" }) do
        test("evalFrom equals a full evaluation: Redridge, " .. mode, function() deltaChecks("redridge", nil, mode) end)
        test("evalFrom equals a full evaluation: Goldshire (level-ups, gated quests), " .. mode, function()
            deltaChecks("goldshire", nil, mode)
        end)
        test("evalFrom equals a full evaluation: Goldshire with rested XP, " .. mode, function()
            deltaChecks("goldshire", { restedPool = 2000 }, mode)
        end)
        test("evalFrom equals a full evaluation: Goldshire 10 XP short of a level, " .. mode, function()
            deltaChecks("goldshire", { xp = 1490, xpMax = 1500, restedPool = 800 }, mode)
        end)
    end

    test("worth mode gives today's worth; a broken gate gives today's worth too", function()
        local ns = data()
        -- (on the route the search ended on: the tidy-up lets a quest for a later level wait when
        -- dropping slow quests leaves it before its level, so the plan's own route may have none)
        local sc, _, best = captured(state("goldshire"), 1429)
        sc.restore(best)
        local r = sc.r
        local ev = ns.Objective.New(r, sc.overhead)
        local obj, worth = ev:eval()
        eq(obj, r:worth(sc.overhead))
        eq(worth, obj)
        local broke = 0
        for _ = 1, 200 do
            local i, len, p = randomMove(r)
            if i then
                local v = r:shift(i, len, p)
                if r:brokenGate() then
                    broke = broke + 1
                    eq((ev:eval()), r:worth(sc.overhead))
                end
                r:unshift(i, len, p, v)
            end
        end
        -- (few random moves break a gate: the route has one quest for a later level, a few in a
        -- thousand moves; so break one on purpose too: its accept as early as the order rules allow)
        local snap = r:snapshot()
        for _, m in ipairs(sc.candidates) do
            if m.gate and r.routed[m] and m.P and not r:brokenGate() then
                r:unplace(m.P)
                r:place(m.P, (r:bounds(m.P, true)))
                if r:brokenGate() then
                    broke = broke + 1
                    eq((ev:eval()), r:worth(sc.overhead))
                end
                sc.restore(snap)
            end
        end
        ok(broke > 0, "some moves broke a gate")
    end)

    test("dinkelbach: the true worth from the prefix pass is today's worth, to the last digit", function()
        local ns = data()
        local O = ns.Objective
        for _, kind in ipairs({ "redridge", "goldshire" }) do
            local sc = captured(state(kind), MAPS[kind][1])
            local r = sc.r
            with({ { "Objective", "MODE", "dinkelbach" } }, function()
                local ev = O.New(r, sc.overhead)
                for _ = 1, 100 do
                    local i, len, p = randomMove(r)
                    if i then r:shift(i, len, p) end
                    local _, worth, memo = ev:eval()
                    eq(worth, r:worth(sc.overhead), kind .. " worth")
                    eq(memo.score ~= nil and memo.score or 0, (r:score(sc.overhead)), kind .. " score")
                end
            end)
        end
    end)

    test("dinkelbach with no tail: the objective is above R exactly when the score is", function()
        local ns = data()
        local O = ns.Objective
        for _, kind in ipairs({ "redridge", "goldshire" }) do
            local sc = captured(state(kind), MAPS[kind][1])
            local r = sc.r
            with({ { "Objective", "MODE", "dinkelbach" }, { "Planner", "TAIL_WEIGHT", 0 } }, function()
                local ev = O.New(r, sc.overhead)
                local score = r:score(sc.overhead)
                for _, f in ipairs({ 0.5, 0.9, 0.99, 1.01, 1.1, 2 }) do
                    ev.R = score * f
                    local obj = ev:eval()
                    ok((obj > ev.R) == (score > ev.R), kind .. " factor " .. f)
                end
            end)
        end
    end)

    test("dinkelbach: objOf(memo) equals eval() once R has moved; R only goes up", function()
        local ns = data()
        local O = ns.Objective
        local sc = captured(state("redridge"), 1433)
        local r = sc.r
        with({ { "Objective", "MODE", "dinkelbach" } }, function()
            local ev = O.New(r, sc.overhead)
            local obj0, worth, memo = ev:eval()
            eq(ev:objOf(memo), obj0)
            local R0 = ev.R
            ev.R = R0 * 0.5
            ok(not ev:newEpoch(O.EPOCH - 1, { score = R0 * 3 }), "only at the end of an epoch")
            ok(ev:newEpoch(O.EPOCH, { score = R0 * 3 }), "R is raised")
            eq(ev.R, R0 * 3)
            local obj1, _, memo1 = ev:eval()
            eq(ev:objOf(memo1), obj1)
            eq(ev:objOf(memo), (function() local o = ev:eval(); return o end)())
            ok(not ev:newEpoch(2 * O.EPOCH, { score = R0 }), "R never goes down")
            eq(ev.R, R0 * 3)
        end)
    end)
end)
