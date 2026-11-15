-- tests/test_objective_2.lua: the objective on the real data, part 2 of 2 (see test_objective.lua):
-- polish, the search with dinkelbach and polish, and nearby insertion places (Planner.NEAR_K).
local H, M = ...
local test, eq, ok = H.test, H.eq, H.ok

local O_ = require("objective_env")(H, M)
local data, state, MAPS, with, captured, order = O_.data, O_.state, O_.MAPS, O_.with, O_.captured, O_.order
local rnd, randomMove, wellFormed = O_.rnd, O_.randomMove, O_.wellFormed

H.suite("Objective", function()
    test("polish never lowers the objective; the route stays valid and no gate is broken by it, every round", function()
        local ns = data()
        local O = ns.Objective
        for _, mode in ipairs({ "worth", "dinkelbach" }) do
            for _, kind in ipairs({ "redridge", "goldshire" }) do
                local polished, lowered, rounds, bad = 0, 0, 0, nil
                local polish = O.Polish
                local settings = { { "Objective", "MODE", mode }, { "Objective", "POLISH", true }, { "Objective", "CHECK", true } }
                with(settings, function()
                    O.Polish = function(r, ev, touched, S)
                        local before = ev:eval()
                        -- (a repair can leave a stop before its level: the round is then judged
                        -- and thrown out; polish leaves such a route alone)
                        local brokenBefore = r:brokenGate() ~= nil
                        polish(r, ev, touched, S)
                        local after = ev:eval()
                        rounds = rounds + 1
                        if after > before then polished = polished + 1 end
                        if after < before - 1e-9 * math.max(math.abs(before), 1e-9) then lowered = lowered + 1 end
                        if not r:valid() or (not brokenBefore and r:brokenGate()) then bad = bad or ("round " .. rounds) end
                        if brokenBefore and after ~= before then bad = bad or ("moved a broken route, round " .. rounds) end
                        for k, node in ipairs(r.route) do
                            if r.pos[node] ~= k then bad = bad or ("pos at round " .. rounds) end
                        end
                    end
                    local okay, err = pcall(captured, state(kind), MAPS[kind][1])
                    O.Polish = polish
                    if not okay then error(err, 0) end
                end)
                eq(bad, nil, mode .. " " .. kind)
                eq(lowered, 0, mode .. " " .. kind .. ": polish lowered the objective")
                ok(rounds >= 20, "rounds polished: " .. rounds)
            end
        end
    end)

    test("the search on real data with dinkelbach and polish: same plan twice, rules kept, never worse than unsearched", function()
        local ns = data()
        for _, kind in ipairs({ "redridge", "goldshire" }) do
            local st = state(kind)
            for _, map in ipairs(MAPS[kind]) do
                local a, b, plain
                with({ { "Objective", "MODE", "dinkelbach" }, { "Objective", "POLISH", true } }, function()
                    a = ns.Zones.PlanZone(map, ns.Zones.Context(st))
                    b = ns.Zones.PlanZone(map, ns.Zones.Context(st))
                end)
                with({ { "Planner", "SEARCH_ITERATIONS", 0 }, { "Planner", "EXACT_WINDOW", 0 } }, function()
                    plain = ns.Zones.PlanZone(map, ns.Zones.Context(st))
                end)
                eq(order(a), order(b), kind .. " " .. map .. " is deterministic")
                local fine, why = wellFormed(a)
                ok(fine, kind .. " " .. map .. ": " .. tostring(why))
                ok(a.score >= plain.score, string.format("%s %d: %.0f against %.0f unsearched", kind, map, a.score, plain.score))
            end
        end
    end)

    -- Nearby insertion places (Planner.NEAR_K)
    test("NEAR_K off or huge: the plans are the same as with every place tried", function()
        local ns = data()
        for kind, maps in pairs(MAPS) do
            local st = state(kind)
            for _, map in ipairs(maps) do
                local off, nilK, huge
                with({ { "Planner", "NEAR_K", nil } }, function() off = ns.Zones.PlanZone(map, ns.Zones.Context(st)) end)
                with({ { "Planner", "NEAR_K", 0 } }, function() nilK = ns.Zones.PlanZone(map, ns.Zones.Context(st)) end)
                with({ { "Planner", "NEAR_K", 1000 } }, function() huge = ns.Zones.PlanZone(map, ns.Zones.Context(st)) end)
                eq(order(nilK), order(off), kind .. " " .. map .. " K=0")
                eq(order(huge), order(off), kind .. " " .. map .. " K=1000")
                eq(huge.score, off.score, kind .. " " .. map .. " score")
            end
        end
    end)

    test("NEAR_K = 10: rules kept, same plan twice, never worse than unsearched", function()
        local ns = data()
        for _, kind in ipairs({ "redridge", "goldshire" }) do
            local st = state(kind)
            for _, map in ipairs(MAPS[kind]) do
                local a, b, plain
                with({ { "Planner", "NEAR_K", 10 } }, function()
                    a = ns.Zones.PlanZone(map, ns.Zones.Context(st))
                    b = ns.Zones.PlanZone(map, ns.Zones.Context(st))
                end)
                with({ { "Planner", "NEAR_K", 10 }, { "Planner", "SEARCH_ITERATIONS", 0 }, { "Planner", "EXACT_WINDOW", 0 } }, function()
                    plain = ns.Zones.PlanZone(map, ns.Zones.Context(st))
                end)
                eq(order(a), order(b), kind .. " " .. map .. " is deterministic")
                local fine, why = wellFormed(a)
                ok(fine, kind .. " " .. map .. ": " .. tostring(why))
                ok(a.score >= plain.score, string.format("%s %d: %.0f against %.0f unsearched", kind, map, a.score, plain.score))
            end
        end
    end)

    test("NEAR_SCOPE search: the unsearched route is built with every place; nearK only inside rounds", function()
        local ns = data()
        for _, kind in ipairs({ "redridge", "goldshire" }) do
            local st = state(kind)
            for _, map in ipairs(MAPS[kind]) do
                local off, plain, searched
                local noSearch = { { "Planner", "SEARCH_ITERATIONS", 0 }, { "Planner", "EXACT_WINDOW", 0 } }
                with({ { "Planner", "NEAR_K", nil }, noSearch[1], noSearch[2] }, function()
                    off = ns.Zones.PlanZone(map, ns.Zones.Context(st))
                end)
                with({ { "Planner", "NEAR_K", 6 }, { "Planner", "NEAR_SCOPE", "search" }, noSearch[1], noSearch[2] }, function()
                    plain = ns.Zones.PlanZone(map, ns.Zones.Context(st))
                end)
                eq(order(plain), order(off), kind .. " " .. map .. " unsearched = K off")
                eq(plain.score, off.score, kind .. " " .. map .. " unsearched score")
                local inside, outside, fills = {}, nil, 0
                local run, sc0 = ns.Search.Run, nil
                ns.Search.Run = function(sc)
                    local f = sc.fill
                    sc.fill = function(...) fills = fills + 1; f(...); end
                    local inner = sc.takeOut
                    sc0 = sc
                    local orig = sc.r.nearCandidates
                    sc.r.nearCandidates = function(self, ...)
                        inside[#inside + 1] = self.nearK or false
                        return orig(self, ...)
                    end
                    local res = run(sc)
                    sc.r.nearCandidates = nil
                    outside = sc.r.nearK
                    return res
                end
                local okay, err = pcall(function()
                    with({ { "Planner", "NEAR_K", 6 }, { "Planner", "NEAR_SCOPE", "search" } }, function()
                        searched = ns.Zones.PlanZone(map, ns.Zones.Context(st))
                    end)
                end)
                ns.Search.Run = run
                if not okay then error(err, 0) end
                ok(searched.score >= plain.score, string.format("%s %d: %.0f against %.0f", kind, map, searched.score, plain.score))
                eq(outside, nil, kind .. " " .. map .. " r.nearK cleared after the search")
                if fills > 0 then
                    local any = false
                    for _, v in ipairs(inside) do if v == 6 then any = true end end
                    ok(any, "nearby places used inside a round")
                end
            end
        end
    end)

    test("best with NEAR_K: a place from the candidate set, never cheaper than the exact best", function()
        local ns = data()
        local P = ns.Planner
        local sc = captured(state("redridge"), 1433)
        local r = sc.r
        local old, oldScope = P.NEAR_K, P.NEAR_SCOPE
        P.NEAR_SCOPE = "all"
        local same, checked = 0, 0
        for _ = 1, 200 do
            local i = 2 + rnd(#r.route - 1) - 1
            local node = r.route[i]
            if node and i >= 2 then
                r:unplace(node)
                local lo, hi = r:bounds(node, true)
                if lo <= hi then
                    P.NEAR_K = nil
                    local xp, xd = r:best(node, lo, hi)
                    P.NEAR_K = 3
                    local cands = r:nearCandidates(node, nil, lo, hi)
                    local kp, kd = r:best(node, lo, hi)
                    P.NEAR_K = old
                    if cands then
                        local inSet = false
                        for _, c in ipairs(cands) do
                            if c == kp then inSet = true end
                            ok(c >= lo and c <= hi, "candidate in range")
                        end
                        ok(inSet, "the chosen place is a candidate")
                        ok(kd >= xd - 1e-9, "never cheaper than the exact best")
                        local exactIn = false
                        for _, c in ipairs(cands) do if c == xp then exactIn = true end end
                        if exactIn then eq(kd, xd, "exact best in the set") ; same = same + 1 end
                        checked = checked + 1
                    end
                end
                r:place(node, i - 1)
            end
        end
        P.NEAR_K, P.NEAR_SCOPE = old, oldScope
        ok(checked > 100, "checked " .. checked)
        ok(same > 0)
    end)
end)
