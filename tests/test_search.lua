-- tests/test_search.lua: ns.Search (acceptance, early stop, restarts, operators, saved weights, per-round
-- streams, plan fields, bandit, per-quest credit, contested outsiders).
local H, M = ...
local test, eq, ok, near = H.test, H.eq, H.ok, H.near

local loaded
local function data()
    if not loaded then
        M.install()
        local ns = {}
        local files = {}
        for _, f in ipairs(H.tocFiles()) do if f:match("^data/") then files[#files + 1] = f end end
        H.loadAddon(files, ns)
        H.loadAddon(H.runtimeFiles(), ns)
        loaded = ns
    end
    return loaded
end

-- Plan the Redridge zone for the level 22 paladin with some settings changed. `wrap(sc, result)`
-- (optional) runs right after the search, before the route is tidied. Returns the plan, the
-- trace frames, and whatever the wrapper saw.
local function plan(settings, rounds, opts)
    opts = opts or {}
    local ns = data()
    local Data = ns.Data
    Data.Init({ faction = "Alliance", class = "PALADIN", clientBuild = ns.data.meta.build }, M.questieDB("Alliance", "PALADIN"))
    Data.BuildIndex()
    local undo = {}
    for k, v in pairs(settings or {}) do
        local mod, key = k:match("^(%a+)%.(.+)$")
        undo[#undo + 1] = { ns[mod], key, ns[mod][key] }
        ns[mod][key] = v
    end
    undo[#undo + 1] = { ns.Planner, "SEARCH_ITERATIONS", ns.Planner.SEARCH_ITERATIONS }
    ns.Planner.SEARCH_ITERATIONS = rounds or 40
    local run, seen = ns.Search.Run, {}
    ns.Search.Run = function(sc)
        if opts.warm then sc.warm = true end
        local res = run(sc)
        seen.sc, seen.result = sc, res
        if opts.after then opts.after(sc, res, seen) end
        return res
    end
    local completed = {}
    for _, id in ipairs(ns.Data.QuestIds()) do
        local q = Data.GetQuest(id)
        if q and q.level > 0 and q.level <= 18 then completed[id] = true end
    end
    local ctx = ns.Zones.Context({ level = 22, faction = "Alliance", class = "PALADIN", raceId = 1, map = 1433,
        x = 0.30, y = 0.44, log = {}, completed = completed, capacity = 40, trace = opts.trace and 1433 or nil })
    local p = ns.Zones.PlanZone(1433, ctx)
    ns.Search.Run = run
    for i = #undo, 1, -1 do undo[i][1][undo[i][2]] = undo[i][3] end
    return p, seen
end

H.suite("Search", function()
    test("the search module exists", function()
        local ns = data()
        ok(type(ns.Search) == "table")
    end)

    test("Accept: annealing and record-to-record, both scales", function()
        local ns = data()
        local S, P = ns.Search, ns.Planner
        local rel = { scale = function(_, x) return x end }
        local abs = { scale = function() return 1000 end }
        local oldT, oldM = P.SEARCH_TEMPERATURE, S.RRT_MARGIN
        P.SEARCH_TEMPERATURE, S.RRT_MARGIN = 0.02, 0.01
        -- anneal: allowance 0.02 * (1 - round/rounds) of the current's scale
        ok(S.Accept("anneal", 99, 100, 120, 0, 100, rel), "within 1% of the current at the start")
        ok(not S.Accept("anneal", 97, 100, 120, 0, 100, rel), "2% under the allowance")
        ok(S.Accept("anneal", 99, 100, 120, 50, 100, rel) and not S.Accept("anneal", 98.9, 100, 120, 50, 100, rel), "the allowance halves")
        ok(S.Accept("anneal", 100, 100, 120, 100, 100, rel), "at the end only not worse")
        ok(not S.Accept("anneal", 99.99, 100, 120, 100, 100, rel))
        ok(S.Accept("anneal", 85, 100, 120, 0, 100, abs), "absolute scale: allowance 20 units")
        ok(not S.Accept("anneal", 75, 100, 120, 0, 100, abs))
        -- rrt: within 1% of the best, whatever the current is
        ok(S.Accept("rrt", 119, 50, 120, 90, 100, rel), "within 1% of the best")
        ok(not S.Accept("rrt", 118, 50, 120, 90, 100, rel))
        ok(S.Accept("rrt", 111, 50, 120, 90, 100, abs), "absolute: 10 units")
        ok(not S.Accept("rrt", 109, 50, 120, 90, 100, abs))
        ok(S.Accept("rrt", 119, 50, 120, 0, 100, rel) == S.Accept("rrt", 119, 50, 120, 100, 100, rel), "no schedule")
        P.SEARCH_TEMPERATURE, S.RRT_MARGIN = oldT, oldM
    end)

    test("early stop ends a search that has stalled, the same way every time", function()
        local a = plan({ ["Search.STALL_ROUNDS"] = 10, ["Search.MIN_ROUNDS"] = 5 }, 100)
        ok(a.search, "the plan was searched")
        ok(a.search.rounds < 100, "stopped early: " .. a.search.rounds)
        ok(a.search.rounds >= 5, "not before the minimum")
        ok(a.search.stopped)
        local b = plan({ ["Search.STALL_ROUNDS"] = 10, ["Search.MIN_ROUNDS"] = 5 }, 100)
        eq(table.concat(a.order, " "), table.concat(b.order, " "))
        eq(a.search.rounds, b.search.rounds)
        local full = plan({}, 100)
        eq(full.search.rounds, 100, "off by default")
        ok(not full.search.stopped)
    end)

    test("a warm search uses the warm stall limits", function()
        local p = plan({ ["Search.STALL_ROUNDS"] = 1000, ["Search.STALL_ROUNDS_WARM"] = 3, ["Search.MIN_ROUNDS_WARM"] = 2 },
            100, { warm = true })
        ok(p.search.rounds < 100 and p.search.rounds >= 2, "rounds " .. p.search.rounds)
        local cold = plan({ ["Search.STALL_ROUNDS"] = 1000, ["Search.STALL_ROUNDS_WARM"] = 3 }, 30)
        eq(cold.search.rounds, 30)
    end)

    test("the extra operators leave a valid route, and are off by default", function()
        local ns = data()
        local seen
        local results = {}
        plan({ ["Search.EXTRA_OPS"] = "all" }, 40, { after = function(sc)
            local r, S = sc.r, ns.Search
            local candidateSet = {}
            for _, m in ipairs(sc.candidates) do candidateSet[m] = true end
            local function routedList()
                local list = {}
                for _, m in ipairs(sc.candidates) do if r.routed[m] then list[#list + 1] = m end end
                return list
            end
            for _, name in ipairs({ "a whole quest chain", "everything at one camp", "the longest detours", "everything at one place" }) do
                local op = S.Operator(name)
                results[name] = { found = op ~= nil, outs = 0, valid = true, orphans = 0, runs = 0, camp = 0 }
                for seed = 1, 20 do
                    local list = routedList()
                    local snap = r:snapshot()
                    local stub = { r = r, sc = sc, seed = seed * 7919 }
                    function stub:rand(n)
                        self.seed = (self.seed * 16807) % 2147483647
                        if n then return self.seed % n + 1 end
                        return self.seed / 2147483647
                    end
                    function stub:takeOut(m) sc.takeOut(m) end
                    -- the stops with their quests, before
                    local before = {}
                    for _, node in ipairs(r.route) do
                        if node.kind == "W" then
                            local qs = {}
                            for _, req in ipairs(node.reqs) do qs[#qs + 1] = req.quest end
                            before[#before + 1] = qs
                        end
                    end
                    if #list >= 2 then
                        op.fn(stub, list, 3)
                        local out = {}
                        for _, m in ipairs(list) do if not r.routed[m] then out[m] = true; results[name].outs = results[name].outs + 1 end end
                        results[name].runs = results[name].runs + 1
                        for _, m in ipairs(list) do
                            if r.routed[m] then
                                for _, d in ipairs(m.deps or {}) do
                                    if candidateSet[d] and not r.routed[d] and out[d] then results[name].orphans = results[name].orphans + 1 end
                                end
                            end
                        end
                        -- camp: some stop has all of its quests out
                        for _, qs in ipairs(before) do
                            local all = #qs > 0
                            for _, q in ipairs(qs) do if not out[q] then all = false end end
                            if all then results[name].camp = results[name].camp + 1; break end
                        end
                        sc.fill(0, nil)
                        if not r:valid() or r:brokenGate() then results[name].valid = false end
                    end
                    sc.restore(snap)
                end
            end
            seen = true
        end })
        ok(seen)
        for name, res in pairs(results) do
            ok(res.found, name .. " exists")
            ok(res.runs > 0, name .. " ran")
            ok(res.outs >= res.runs, name .. " takes at least one quest out each time")
            ok(res.valid, name .. " leaves a valid route after the repair")
            eq(res.orphans, 0, name .. " leaves no follow-up whose prerequisite is out")
        end
        ok(results["everything at one camp"].camp > 0, "a whole camp goes out")
        local off = plan({}, 30)
        local explicit = plan({ ["Search.EXTRA_OPS"] = false }, 30)
        eq(table.concat(off.order, " "), table.concat(explicit.order, " "))
        local on = plan({ ["Search.EXTRA_OPS"] = true }, 30)
        ok(#on.steps > 0 and on.score >= 0)
    end)

    test("restarts: marked frames, one frame per round", function()
        local p = plan({ ["Search.RESTART_AFTER"] = 5 }, 60, { trace = true })
        local frames = p.trace
        ok(frames, "recorded")
        local restarts, rounds = 0, 0
        for _, f in ipairs(frames) do
            if f.restart then restarts = restarts + 1 end
            if f.round then rounds = rounds + 1 end
        end
        ok(restarts > 0, "some round ends with a restart")
        eq(rounds, p.search.rounds, "one frame per round")
        eq(frames[1].kind, "start")
        eq(frames[#frames].kind, "final")
        eq(#frames, rounds + 2)
        local again = plan({ ["Search.RESTART_AFTER"] = 5 }, 60)
        eq(table.concat(p.order, " "), table.concat(again.order, " "), "same plan twice")
    end)

    test("record-to-record and outsiders-once give valid, repeatable plans", function()
        local ns = data()
        for _, s in ipairs({ { ["Search.ACCEPT"] = "rrt" }, { ["Search.OUTSIDERS"] = "once" } }) do
            local a, b = plan(s, 40), plan(s, 40)
            eq(table.concat(a.order, " "), table.concat(b.order, " "))
            ok(#a.steps > 0)
        end
        ok(ns.Search.OUTSIDERS == "once" and ns.Search.ACCEPT == "anneal", "settings restored (the defaults)")
    end)

    test("saved weights: by name, blended towards 1, new operators start at 1", function()
        local ns = data()
        local S = ns.Search
        local oldC = S.WEIGHT_CARRY
        local dw, rw = S.InitWeights(nil)
        for i = 1, #S.DESTROY do eq(dw[i], 1) end
        for i = 1, #S.REGRET do eq(rw[i], 1) end
        S.WEIGHT_CARRY = 1
        local saved = { destroy = { ["any quests"] = 3 }, regret = { [2] = 0.5 } }
        dw, rw = S.InitWeights(saved)
        eq(dw[1], 3); eq(dw[2], 1, "an operator missing from the saved table"); eq(rw[1], 1); eq(rw[2], 0.5)
        S.WEIGHT_CARRY = 0.5
        dw, rw = S.InitWeights(saved)
        eq(dw[1], 2); eq(rw[2], 0.75); eq(dw[#S.DESTROY], 1)
        S.WEIGHT_CARRY = 0.5
        dw, rw = S.InitWeights({ destroy = { ["any quests"] = 0 } })
        eq(dw[1], 0.5, "blended 0 -> half way to 1")
        S.WEIGHT_CARRY = 0.1
        dw = S.InitWeights({ destroy = { ["any quests"] = 0 } })
        ok(dw[1] >= 0.05 and dw[1] <= 1)
        S.WEIGHT_CARRY = 1
        dw = S.InitWeights({ destroy = { ["any quests"] = 0 } })
        eq(dw[1], 0.05, "never below the floor")
        S.WEIGHT_CARRY = oldC
        -- round trip through the export
        local out = S.ExportWeights({ 1, 2, 3, 4, 5, 6, 7, 8 }, { 1, 2, 3 })
        eq(out.destroy["any quests"], 1); eq(out.destroy["a whole quest chain"], 5); eq(out.regret[3], 3)
        S.WEIGHT_CARRY = 1
        dw, rw = S.InitWeights(out)
        for i = 1, 8 do eq(dw[i], i) end
        S.WEIGHT_CARRY = oldC
    end)

    -- the steps of a plan as comparable text
    local function stepsText(p)
        local parts = {}
        for _, st in ipairs(p.steps) do parts[#parts + 1] = tostring(st.kind) .. ":" .. tostring(st.t) .. ":" .. tostring(st.cumXP) end
        return table.concat(parts, " ")
    end
    local function countKeys(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end

    test("streams and the curve are off by default", function()
        local ns = data()
        eq(ns.Search.STREAM, "sequential")
        eq(ns.Search.CURVE, false)
    end)

    test("with STREAM rounds, round t's draws start from the seed and t only", function()
        local ns = data()
        local seeds, originals = {}, {}
        for i, op in ipairs(ns.Search.DESTROY) do
            originals[i] = op.fn
            op.fn = function(S, list, k)
                seeds[#seeds + 1] = S.seed
                return originals[i](S, list, k)
            end
        end
        local fine, p, seen = pcall(plan, { ["Search.STREAM"] = "rounds" }, 30)
        for i, op in ipairs(ns.Search.DESTROY) do op.fn = originals[i] end
        ok(fine, tostring(p))
        local P = 2147483647
        local R = (seen.sc.seed + 7 * ns.Search.SEED_SALT) % P
        if R == 0 then R = 1 end
        ok(#seeds >= 10, "rounds seen: " .. #seeds)
        for t = 1, #seeds do
            R = (R * 48271) % P
            local x = R
            for _ = 1, 3 do x = (x * 16807) % P end -- the round size, the operator and the regret strength
            eq(seeds[t], x, "round " .. t)
        end
    end)

    test("STREAM rounds: the same input gives the same plan, never below the unsearched one", function()
        local a, b = plan({ ["Search.STREAM"] = "rounds" }, 30), plan({ ["Search.STREAM"] = "rounds" }, 30)
        eq(table.concat(a.order, " "), table.concat(b.order, " "))
        eq(a.score, b.score)
        ok(a.plainScore, "searched, so it has its unsearched score")
        ok(a.score >= a.plainScore - 1e-9)
    end)

    test("CURVE records the best worth of every round and changes nothing", function()
        local off, on = plan({}, 30), plan({ ["Search.CURVE"] = true }, 30)
        eq(table.concat(on.order, " "), table.concat(off.order, " "))
        eq(on.score, off.score)
        eq(stepsText(on), stepsText(off))
        eq(off.search.curve, nil)
        local curve = on.search.curve
        ok(curve, "the curve is kept")
        eq(#curve, on.search.rounds)
        ok(curve[0] ~= nil, "round 0: the start")
        for r = 1, #curve do ok(curve[r] >= curve[r - 1] - 1e-12, "round " .. r .. " is not below round " .. (r - 1)) end
    end)

    test("a searched plan carries its unsearched score and the work its search took", function()
        local p = plan({}, 40)
        ok(p.plainScore and p.plainScore <= p.score + 1e-9, "plainScore " .. tostring(p.plainScore))
        ok(p.searchSpent and p.searchSpent > 0 and p.searchSpent < p.work, "searchSpent " .. tostring(p.searchSpent))
        local none = plan({}, 0)
        eq(none.plainScore, nil)
        eq(none.searchSpent, nil)
    end)

    test("learning settings are off by default", function()
        local ns = data()
        local S = ns.Search
        eq(S.BANDIT, false)
        eq(S.EXTRA_OPS, false)
        eq(S.OUTSIDERS, "once")
        eq(S.ARM_STATS, false)
        eq(S.Operator("credit").name, "the quests worth moving")
    end)

    test("with everything off the weights carry no new fields", function()
        local p = plan({}, 30)
        local w = p.search.weights
        eq(w.bandit, nil)
        eq(w.quests, nil)
        eq(p.search.arms, nil)
        eq(w.destroy["the quests worth moving"], nil)
        eq(countKeys(w.destroy), 8)
        eq(#w.regret, 3)
    end)

    test("arm statistics change nothing", function()
        local a, b = plan({}, 40), plan({ ["Search.ARM_STATS"] = true }, 40)
        eq(table.concat(a.order, " "), table.concat(b.order, " "))
        eq(a.search.work, b.search.work)
        ok(H.deepEq(a.search.weights, b.search.weights), "the same weights")
        local arms = b.search.arms
        ok(arms, "arms are kept")
        local nd, nr = 0, 0
        for name, e in pairs(arms.destroy) do
            eq(e.n, e.best + e.better + e.kept + e.rejected, name)
            if e.n > 0 then ok(e.work > 0, name .. " did work") end
            nd = nd + e.n
        end
        for i = 1, 3 do
            local e = arms.regret[i]
            eq(e.n, e.best + e.better + e.kept + e.rejected, "regret " .. i)
            if e.n > 0 then ok(e.work > 0, "regret " .. i .. " did work") end
            nr = nr + e.n
        end
        eq(nd, b.search.rounds)
        eq(nr, b.search.rounds)
    end)

    test("bandit: chance of beating the leader", function()
        local ns = data()
        local S = ns.Search
        local old = { S.BANDIT_PRIOR, S.BANDIT_COST }
        S.BANDIT_PRIOR, S.BANDIT_COST = 2, 1
        local ops = { 1, 2, 3, 4 }
        local B = S.InitBandit(nil, ops)
        local p = S.BanditProbs(B.op, ops)
        for _, i in ipairs(ops) do eq(p[i], 0.5, "no evidence, arm " .. i) end
        B = S.InitBandit(nil, ops)
        for _, i in ipairs(ops) do B.op.s[i], B.op.f[i] = 2, 10 end
        B.op.s[2], B.op.f[2] = 10, 2
        p = S.BanditProbs(B.op, ops)
        eq(p[2], 0.5, "the leader")
        for _, i in ipairs({ 1, 3, 4 }) do ok(p[i] > 0 and p[i] < 0.05, "arm " .. i .. " " .. p[i]) end
        B = S.InitBandit(nil, ops)
        for _, i in ipairs(ops) do B.op.s[i], B.op.f[i], B.op.w[i], B.op.wn[i] = 3, 9, 12000, 12 end
        B.op.w[1] = 24000
        p = S.BanditProbs(B.op, ops)
        ok(p[1] < 0.3, "twice the work: " .. p[1])
        eq(p[2], 0.5)
        S.BANDIT_COST = 0
        p = S.BanditProbs(B.op, ops)
        eq(p[1], 0.5, "per round, work does not count")
        S.BANDIT_PRIOR, S.BANDIT_COST = old[1], old[2]
    end)

    test("bandit: evidence fades, one round counts once", function()
        local ns = data()
        local S = ns.Search
        local old = S.BANDIT_DISCOUNT
        S.BANDIT_DISCOUNT = 0.5
        local B = S.InitBandit(nil, { 1, 2 })
        B.op.s[1], B.op.f[1], B.op.s[2], B.op.f[2] = 4, 4, 2, 2
        S.BanditUpdate(B, { 1, 2 }, 2, 3, 1, 1000)
        S.BANDIT_DISCOUNT = old
        eq(B.op.s[1], 2); eq(B.op.f[1], 2)
        eq(B.op.s[2], 2); eq(B.op.f[2], 1); eq(B.op.w[2], 1000); eq(B.op.wn[2], 1)
        eq(B.rg.s[3], 1); eq(B.rg.f[3], 0); eq(B.rg.s[1], 0)
    end)

    test("bandit: old weights and its own counts load", function()
        local ns = data()
        local S = ns.Search
        local oldC = S.WEIGHT_CARRY
        S.WEIGHT_CARRY = 1
        local B = S.InitBandit({ destroy = { ["any quests"] = 0.7, ["the lowest paying"] = 5 }, regret = { [2] = 0.1 } }, { 1, 2, 3, 4 })
        near(B.op.s[1], 2.5, 1e-9); near(B.op.f[1], 2.5, 1e-9)
        near(B.op.s[3], 4.95, 1e-9)
        eq(B.op.s[2], 0); eq(B.op.f[2], 0)
        near(B.rg.s[2], 0.05, 1e-9)
        eq(B.op.w[1], 0); eq(B.op.wn[1], 0)
        S.WEIGHT_CARRY = 0.5
        B = S.InitBandit({ bandit = { destroy = { ["any quests"] = { s = 4, f = 6, w = 800, wn = 10 } }, regret = {} },
            destroy = { ["any quests"] = 9 } }, { 1, 2, 3, 4 })
        near(B.op.s[1], 2, 1e-9); near(B.op.f[1], 3, 1e-9); near(B.op.w[1], 400, 1e-9); near(B.op.wn[1], 5, 1e-9)
        S.WEIGHT_CARRY = oldC
    end)

    test("bandit: valid, repeatable, both formats", function()
        local ns = data()
        local a, b = plan({ ["Search.BANDIT"] = "beta" }, 40), plan({ ["Search.BANDIT"] = "beta" }, 40)
        eq(table.concat(a.order, " "), table.concat(b.order, " "))
        local w = a.search.weights
        eq(type(w.destroy["any quests"]), "number")
        eq(type(w.regret[1]), "number")
        local e = w.bandit.destroy["any quests"]
        ok(e.s >= 0 and e.f >= 0 and e.w >= 0 and e.wn >= 0, "counts")
        eq(w.bandit.destroy["a whole quest chain"], nil)
        local oldC = ns.Search.WEIGHT_CARRY
        ns.Search.WEIGHT_CARRY = 1
        local dw = ns.Search.InitWeights(w)
        ns.Search.WEIGHT_CARRY = oldC
        for i = 1, 4 do ok(dw[i] > 0, "old weight " .. i) end
        local u = plan({ ["Search.BANDIT"] = "uniform" }, 40)
        ok(#u.steps > 0)
        eq(u.search.weights.bandit, nil)
    end)

    -- ten quests with ids 101..110 for the per-quest model
    local function fakeQuests()
        local qs = {}
        for i = 1, 10 do qs[i] = { id = 100 + i } end
        return qs
    end

    test("credit: noisy-or shares", function()
        local ns = data()
        local S = ns.Search
        local oldD, oldP = S.QUEST_DISCOUNT, S.QUEST_PRIOR
        S.QUEST_DISCOUNT, S.QUEST_PRIOR = 1, 0.5
        local qs = fakeQuests()
        local Q = S.NewQuestModel(qs)
        S.QuestRound(Q, 1)
        near(S.QuestMean(Q, qs[1]), 0.05, 1e-9)
        S.QuestUpdate(Q, { qs[1], qs[2] }, 2, 0)
        eq(Q.f[qs[1]], 1); eq(Q.f[qs[2]], 1); eq(Q.s[qs[1]], 0); eq(Q.F, 2)
        Q.s[qs[3]], Q.S = 3, 3
        S.QuestUpdate(Q, { qs[3], qs[4], qs[5] }, 3, 1)
        local s3 = Q.s[qs[3]] - 3
        ok(s3 > Q.s[qs[4]], "the one with the better record takes more")
        near(Q.s[qs[4]], Q.s[qs[5]], 1e-9)
        near(Q.s[qs[4]] + Q.f[qs[4]], 1, 1e-9)
        local total = s3 + Q.s[qs[4]] + Q.s[qs[5]]
        ok(total >= 1 - 1e-9 and total <= 3 + 1e-9, "a success is shared: " .. total)
        near(Q.S + Q.F, 8, 1e-9)
        -- discount: two rounds at 0.5 a round
        S.QUEST_DISCOUNT = 0.5
        local R = S.NewQuestModel(qs)
        R.s[qs[1]], R.f[qs[1]], R.S, R.F = 4, 8, 4, 8
        S.QuestRound(R, 1)
        S.QuestRound(R, 2)
        S.QuestMean(R, qs[1])
        near(R.s[qs[1]], 1, 1e-9); near(R.f[qs[1]], 2, 1e-9); near(R.S, 1, 1e-9); near(R.F, 2, 1e-9)
        S.QUEST_DISCOUNT, S.QUEST_PRIOR = oldD, oldP
    end)

    test("credit: evidence as a short string", function()
        local ns = data()
        local S = ns.Search
        local q7, q12, q30 = { id = 7 }, { id = 12 }, { id = 30 }
        local Q = S.NewQuestModel({ q7, q12, q30 })
        Q.s[q7], Q.f[q7] = 0.25, 3.5
        Q.s[q30], Q.f[q30] = 2, 10
        local text = S.EncodeQuests(Q, { q7, q12, q30 })
        eq(text, "7:250:3500;30:2000:10000")
        local oldC = S.WEIGHT_CARRY
        S.WEIGHT_CARRY = 0.5
        local R = S.NewQuestModel({ q30, { id = 99 } }, { quests = text })
        S.WEIGHT_CARRY = oldC
        near(R.s[q30], 1, 1e-9); near(R.f[q30], 5, 1e-9); near(R.S, 1, 1e-9); near(R.F, 5, 1e-9)
        eq(next(S.DecodeQuests("junk;;1:x:2")), nil)
        eq(S.EncodeQuests(S.NewQuestModel({ q7, q12 }), { q7, q12 }), nil)
    end)

    test("credit: k quests, one draw each, mostly those that paid", function()
        local ns = data()
        local S = ns.Search
        local op = S.Operator("credit")
        local tries, hits, ran = 40, 0, false
        plan({}, 20, { after = function(sc)
            local r = sc.r
            local function routedList()
                local list = {}
                for _, m in ipairs(sc.candidates) do if r.routed[m] then list[#list + 1] = m end end
                return list
            end
            local first = routedList()
            if #first < 6 then return end
            ran = true
            local Q = S.NewQuestModel(sc.candidates)
            local favourite = first[1]
            for _, m in ipairs(first) do
                if m == favourite then Q.s[m], Q.S = 20, Q.S + 20 else Q.f[m], Q.F = 20, Q.F + 20 end
            end
            for seed = 1, tries do
                local list = routedList()
                local snap = r:snapshot()
                local k = 1 + seed % 3
                local calls = 0
                local stub = { r = r, sc = sc, seed = seed * 7919, quests = Q }
                function stub:rand(n)
                    calls = calls + 1
                    self.seed = (self.seed * 16807) % 2147483647
                    if n then return self.seed % n + 1 end
                    return self.seed / 2147483647
                end
                function stub:takeOut(m) sc.takeOut(m) end
                op.fn(stub, list, k)
                eq(calls, k, "one draw for each quest asked for")
                local out = 0
                for _, m in ipairs(list) do if not r.routed[m] then out = out + 1 end end
                ok(out >= 1, "at least one quest out")
                if not r.routed[favourite] then hits = hits + 1 end
                sc.fill(0, nil)
                ok(r:valid() and not r:brokenGate(), "a valid route after the repair")
                sc.restore(snap)
            end
        end })
        ok(ran, "a route with at least 6 quests")
        ok(hits >= tries / 4, "the quest that paid goes out most often: " .. hits .. " of " .. tries)
    end)

    test("credit: valid, repeatable, evidence saved", function()
        local ns = data()
        local a = plan({ ["Search.EXTRA_OPS"] = "credit" }, 40)
        local b = plan({ ["Search.EXTRA_OPS"] = "credit" }, 40)
        eq(table.concat(a.order, " "), table.concat(b.order, " "))
        local w = a.search.weights
        eq(type(w.destroy["the quests worth moving"]), "number")
        ok(type(w.quests) == "string" and #w.quests > 0, "evidence is saved")
        local last = -1
        for id in w.quests:gmatch("(%d+):%d+:%d+") do
            ok(tonumber(id) > last, "ids increase")
            last = tonumber(id)
        end
        ok(next(ns.Search.DecodeQuests(w.quests)) ~= nil, "it decodes")
    end)

    test("contested outsiders", function()
        local S = data().Search
        ok(S.IsContested(0, 1)); ok(S.IsContested(0, 2))
        ok(not S.IsContested(0, 3)); ok(S.IsContested(1, 3))
        local s = { ["Search.OUTSIDERS"] = "contested" }
        local a, b = plan(s, 40), plan(s, 40)
        eq(table.concat(a.order, " "), table.concat(b.order, " "))
        ok(#a.steps > 0)
    end)
end)
