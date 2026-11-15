-- tests/test_search.lua: ns.Search (acceptance, early stop, restarts, operators, saved weights).
local H, M = ...
local test, eq, ok = H.test, H.eq, H.ok

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
end)
