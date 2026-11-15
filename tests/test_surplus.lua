-- tests/test_surplus.lua: the "surplus" goal (Planner.GOAL = "surplus"): a route's value is the best
-- of XP(k) - R * time(k) over its leaving points (R = XP per second to be had elsewhere).
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

-- A level `level` Alliance paladin in zone `map` (position x, y); `extra` is added to the state.
local function stateFor(level, map, extra)
    local ns = data()
    local Data = ns.Data
    Data.Init({ faction = "Alliance", class = "PALADIN", clientBuild = ns.data.meta.build }, M.questieDB("Alliance", "PALADIN"))
    Data.BuildIndex()
    local completed = {}
    for _, id in ipairs(ns.Data.QuestIds()) do
        local q = Data.GetQuest(id)
        if q and q.level > 0 and q.level <= level - 4 then completed[id] = true end
    end
    local state = { level = level, faction = "Alliance", class = "PALADIN", raceId = 1, map = map, x = 0.30, y = 0.44,
        log = {}, completed = completed, capacity = 40 }
    for k, v in pairs(extra or {}) do state[k] = v end
    return state
end

-- Settings applied for the duration of `fn` ("Mod.KEY" = value).
local function with(settings, fn)
    local ns = data()
    local undo = {}
    for k, v in pairs(settings) do
        local mod, key = k:match("^(%a+)%.(.+)$")
        undo[#undo + 1] = { ns[mod], key, ns[mod][key] }
        ns[mod][key] = v
    end
    local a, b, c = fn()
    for i = #undo, 1, -1 do undo[i][1][undo[i][2]] = undo[i][3] end
    return a, b, c
end

-- Plan `map` for `state`; `altRate` goes to ctx. `hook(sc, result)` runs right after the search.
local function plan(state, map, altRate, settings, hook)
    local ns = data()
    settings = settings or {}
    return with(settings, function()
        local run = ns.Search.Run
        if hook then
            ns.Search.Run = function(sc)
                local res = run(sc)
                hook(sc, res)
                return res
            end
        end
        local ctx = ns.Zones.Context(state)
        ctx.altRate = altRate
        local p = ns.Zones.PlanZone(map, ctx, nil, nil, { readOnly = true, warm = false })
        ns.Search.Run = run
        return p, ctx
    end)
end

-- the value of leaving after each step, worked out from the plan's own steps (time includes the overhead)
local function direct(p, R)
    local best, at = -R * p.overhead, nil
    local top, topAt = -math.huge, nil
    for i, step in ipairs(p.steps) do
        local v = step.cumXP - R * step.t
        if v > top then top, topAt = v, i end
        if v > best then best, at = v, i end
    end
    return best, at, top, topAt
end

local function rng(seed)
    return function()
        seed = (seed * 16807) % 2147483647
        return seed / 2147483647
    end
end

H.suite("Surplus goal", function()
    test("a plan's value is the best XP(k) - R * time(k), the peak its argmax (level-ups, rested XP)", function()
        local rand = rng(12345)
        local levelUps = 0
        for _, c in ipairs({ { 22, 1433 }, { 12, 1429 }, { 30, 1431 }, { 22, 1431 } }) do
            local state = stateFor(c[1], c[2], { restedPool = 6000, xp = 0, xpMax = 20000 })
            if c[1] == 22 then state.xp, state.xpMax = 19500, 20000 end -- a level-up comes early on the route
            for _ = 1, 3 do
                local R = (2 + 8 * rand()) -- XP per second
                local p = with({ ["Planner.GOAL"] = "surplus", ["Planner.SEARCH_ITERATIONS"] = 12 }, function()
                    return plan(state, c[2], R)
                end)
                ok(#p.steps > 3, "a route to value")
                for _, step in ipairs(p.steps) do if step.levelUp then levelUps = levelUps + 1 end end
                local v, at, top, topAt = direct(p, R)
                near(p.value, v, 1e-6, "value")
                eq(p.R, R, "R is remembered")
                near(p.bestValue, top, 1e-6, "best value over the steps")
                eq(p.peak, topAt, "peak is the argmax over the steps")
                eq(p.stay, at == nil or nil, "staying put is best only when no step beats it")
                near(p.rate, p.steps[p.peak].cumXP / p.steps[p.peak].t * 3600, 1e-6, "rate: XP per hour up to the peak")
                eq(p.score, p.rate, "score is the rate")
                ok(p.todayScore and p.todayScore > 0, "today's score is kept")
                eq(p.tailStart, p.stay and 1 or p.peak + 1, "the steps after the leaving point are the tail")
            end
        end
        ok(levelUps > 0, "some route went through a level-up: " .. levelUps)
    end)

    test("R:surplus and the search's objective agree with a direct computation on the route", function()
        local ns = data()
        local state = stateFor(22, 1433, { restedPool = 8000, xp = 19000, xpMax = 20000 })
        local rand = rng(777)
        local checked = 0
        for _ = 1, 3 do
            local R = 3 + 6 * rand()
            plan(state, 1433, R, { ["Planner.GOAL"] = "surplus", ["Planner.SEARCH_ITERATIONS"] = 10 }, function(sc)
                local r = sc.r
                -- the route's own sums, as R:score makes them
                local t, xp, pool, d, nextUp = sc.overhead or 0, 0, r.restedBonus, 0, r.ups[1]
                local best, at = -R * t, nil
                for i = 2, #r.route do
                    local node = r.route[i]
                    local s, gain = r:value(node, nil, d)
                    if node.kind == "W" then
                        local b = math.min(gain, pool)
                        pool, gain = pool - b, gain + b
                    end
                    t = t + r:tt(r.route[i - 1], node) + s
                    xp = xp + gain
                    while nextUp and xp >= nextUp do d = d + 1; nextUp = r.ups[d + 1] end
                    if gain > 0 and xp - R * t > best then best, at = xp - R * t, i end
                end
                local v, vat, vt, vxp = r:surplus(sc.overhead, R)
                near(v, best, 1e-6, "R:surplus value")
                eq(vat, at, "R:surplus leaving point")
                near(vt, t, 1e-6, "end time")
                near(vxp, xp, 1e-6, "end XP")
                local ev = ns.Objective.New(r, sc.overhead)
                eq(ev.mode, "surplus")
                local obj, worth = ev:eval()
                near(obj, R + best / ns.Planner.MIN_HORIZON, 1e-9, "objective is R + V / H")
                eq(worth, obj, "the best route is kept by the same number")
                near(ev:scale(obj), math.max(obj, R), 1e-12, "margins are relative to it")
                near(ev:objOf(select(3, ev:eval())), obj, 1e-12)
                checked = checked + 1
            end)
        end
        eq(checked, 3, "the hook ran for every plan")
    end)

    test("Zones.Rank works R out from a first pass without the search when none is given", function()
        local ns = data()
        local state = stateFor(22, 1433)
        local best = with({ ["Planner.GOAL"] = "rate" }, function()
            local ctx = ns.Zones.Context(state)
            ctx.searchRounds = 0
            return ns.Zones.Rank(ctx)[1].plan.score / 3600
        end)
        local ctx, ranked = with({ ["Planner.GOAL"] = "surplus", ["Planner.SEARCH_ITERATIONS"] = 10 }, function()
            local ctx = ns.Zones.Context(state)
            return ctx, ns.Zones.Rank(ctx)
        end)
        near(ctx.altRate, best, 1e-9, "R = the best zone's unsearched score / 3600")
        ok(ctx.bootstrapWork and ctx.bootstrapWork > 0, "the pass is counted")
        eq(ctx.goal, nil, "the context is put back as it was")
        eq(ctx.searchRounds, nil)
        for _, z in ipairs(ranked) do near(z.plan.R, best * ns.Planner.ALT_SHARE, 1e-9, "every zone is planned against R") end
        for i = 2, #ranked do
            ok(ranked[i - 1].plan.value >= ranked[i].plan.value - 1e-9, "ranked by value")
        end
        -- given R: no first pass
        local given = with({ ["Planner.GOAL"] = "surplus", ["Planner.SEARCH_ITERATIONS"] = 10 }, function()
            local c = ns.Zones.Context(stateFor(22, 1433, { altRate = 5 }))
            ns.Zones.Rank(c)
            return c
        end)
        eq(given.altRate, 5)
        eq(given.bootstrapWork, nil, "no first pass when R is given")
        -- under "rate" nothing is worked out
        local plain = with({ ["Planner.GOAL"] = "rate", ["Planner.SEARCH_ITERATIONS"] = 10 }, function()
            local c = ns.Zones.Context(stateFor(22, 1433))
            ns.Zones.Rank(c)
            return c
        end)
        eq(plain.altRate, nil)
    end)

    test("ALT_SHARE scales R", function()
        local state = stateFor(22, 1433)
        local p = plan(state, 1433, 4, { ["Planner.GOAL"] = "surplus", ["Planner.ALT_SHARE"] = 0.9, ["Planner.SEARCH_ITERATIONS"] = 0 })
        near(p.R, 3.6, 1e-12)
    end)

    test("staying put is worth -R * overhead; with R = 0 the whole route's best XP counts", function()
        local state = stateFor(22, 1431) -- another zone than the one we stand in: 120 s to switch
        local p = plan(state, 1433, 1000, { ["Planner.GOAL"] = "surplus", ["Planner.SEARCH_ITERATIONS"] = 0 })
        eq(p.overhead, 120)
        ok(p.stay, "nothing beats leaving at once")
        near(p.value, -1000 * 120, 1e-6)
        ok(p.value >= p.bestValue)
        local q = plan(state, 1433, 0, { ["Planner.GOAL"] = "surplus", ["Planner.SEARCH_ITERATIONS"] = 0 })
        ok(not q.stay)
        near(q.value, q.xp, 1e-6, "no alternative: the whole route")
    end)

    test("a searched plan is never worth less than the unsearched one, by value", function()
        for _, c in ipairs({ { 22, 1433 }, { 15, 1436 }, { 30, 1431 } }) do
            local state = stateFor(c[1], c[2])
            local with0 = plan(state, c[2], 4, { ["Planner.GOAL"] = "surplus", ["Planner.SEARCH_ITERATIONS"] = 0 })
            for _, R in ipairs({ 2, 4, 8 }) do
                local none = plan(state, c[2], R, { ["Planner.GOAL"] = "surplus", ["Planner.SEARCH_ITERATIONS"] = 0 })
                local found = plan(state, c[2], R, { ["Planner.GOAL"] = "surplus", ["Planner.SEARCH_ITERATIONS"] = 30 })
                ok(found.value >= none.value - 1e-6, string.format("map %d R %g: %.1f vs %.1f", c[2], R, found.value, none.value))
            end
            ok(with0.value ~= nil)
        end
    end)

    test("the same situation gives the same plan", function()
        local state = stateFor(22, 1433)
        local settings = { ["Planner.GOAL"] = "surplus", ["Planner.SEARCH_ITERATIONS"] = 25 }
        local a = plan(state, 1433, 4, settings)
        local b = plan(state, 1433, 4, settings)
        eq(table.concat(a.order, ","), table.concat(b.order, ","))
        eq(a.value, b.value)
        eq(a.work, b.work)
    end)

    test("under the rate goal the plans are the same with or without an alternative rate", function()
        local state = stateFor(22, 1433)
        local settings = { ["Planner.GOAL"] = "rate", ["Planner.SEARCH_ITERATIONS"] = 25 }
        local a = plan(state, 1433, nil, settings)
        local b = plan(state, 1433, 9, settings)
        eq(table.concat(a.order, ","), table.concat(b.order, ","))
        eq(a.score, b.score)
        eq(a.work, b.work)
        eq(a.value, nil, "no surplus fields")
        eq(a.todayScore, nil)
        -- and the default is today's goal
        eq(data().Planner.GOAL, "rate")
    end)

    test("the itinerary runs under the surplus goal and plans later zones against the same R", function()
        local ns = data()
        local state = stateFor(22, 1433)
        local it, ctx = with({ ["Planner.GOAL"] = "surplus", ["Planner.SEARCH_ITERATIONS"] = 15 }, function()
            local ctx = ns.Zones.Context(state)
            local ranked = ns.Zones.Rank(ctx)
            return ns.Zones.Itinerary(state, ctx, ranked), ctx
        end)
        ok(ctx.altRate and ctx.altRate > 0)
        ok(it and it.xp > 0, "an itinerary")
    end)
end)
