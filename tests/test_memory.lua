-- tests/test_memory.lua: ns.Memory (plan reuse between re-rankings, warm start) on the real data.
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

H.suite("Memory", function()
    test("the memory module exists", function()
        M.install()
        local ns = { data = {} }
        H.loadAddon(H.runtimeFiles(), ns)
        ok(type(ns.Memory) == "table")
    end)
end)

H.suite("Plan memory (real data)", function()
    local ns, raw
    local completed0, known0
    local function init()
        ns = data()
        -- these tests are about reusing plans; the default leaves it off (it did not pass the
        -- bench's keep rule, see docs/planner.md), so it is switched on here
        ns.Zones.REUSE = true
        ns.Data.Init({ faction = "Alliance", class = "PALADIN", clientBuild = ns.data.meta.build }, M.questieDB("Alliance", "PALADIN"))
        raw = ns.data
        ns.Data.BuildIndex()
        completed0, known0 = {}, {}
        for _, id in ipairs(ns.Data.QuestIds()) do
            local q = ns.Data.GetQuest(id)
            if q and q.level > 0 and q.level <= 18 then completed0[id] = true end
        end
        for id, n in pairs(raw.world.travel.nodes) do
            if n[7] == "n" or n[7] == "a" then known0[id] = true end
        end
        ns.Planner.SEARCH_ITERATIONS = 6 -- the logic under test is not the quality of the route
    end

    -- Redridge, level 22 paladin at Lakeshire (as "Itinerary (real data)")
    local function baseState()
        local completed, known = {}, {}
        for id in pairs(completed0) do completed[id] = true end
        for id in pairs(known0) do known[id] = true end
        return { level = 22, faction = "Alliance", class = "PALADIN", raceId = 1, map = 1433, x = 0.30, y = 0.44,
            log = {}, completed = completed, capacity = 40, knownNodes = known, xp = 3000, ignored = {} }
    end
    local function ctxOf(state, mem, now)
        local st = {}
        for k, v in pairs(state) do st[k] = v end
        st.memory, st.now = mem, now
        return ns.Zones.Context(st)
    end

    -- Count Planner.Plan calls (each is real planning work) while `fn` runs.
    local function counting(fn)
        local plan, calls = ns.Planner.Plan, 0
        ns.Planner.Plan = function(...) calls = calls + 1; return plan(...) end
        local ok_, a, b = pcall(fn)
        ns.Planner.Plan = plan
        if not ok_ then error(a, 0) end
        return calls, a, b
    end

    -- Rank at `base` (now 0), then at the state `modify` makes of a copy (now `now2`).
    -- Returns the first and second ranking, the set of reused maps, the number of plans made by the second.
    local function twice(modify, now2, mem)
        mem = mem or ns.Memory.New()
        local s1 = baseState()
        local r1 = ns.Zones.Rank(ctxOf(s1, mem, 0))
        local s2 = baseState()
        if modify then modify(s2, r1) end
        local calls, r2 = counting(function() return ns.Zones.Rank(ctxOf(s2, mem, now2 or 10)) end)
        local reused = {}
        for _, z in ipairs(r2) do if z.reused then reused[z.map] = true end end
        return r1, r2, reused, calls, mem
    end
    local function others(r) -- the zones that may be reused: all but the one we stand in
        local out = {}
        for _, z in ipairs(r) do if z.map ~= 1433 then out[#out + 1] = z.map end end
        return out
    end
    local function allReused(r1, reused)
        for _, map in ipairs(others(r1)) do if not reused[map] then return false, map end end
        return true
    end
    local function noneReused(reused)
        for map in pairs(reused) do return false, map end
        return true
    end

    test("setup", function() init(); ok(ns.Zones.Rank) end)

    test("without a memory, plans are the same with warm start and reuse on or off", function()
        local state = baseState()
        local function orders(settings)
            local saved = {}
            for k, v in pairs(settings) do saved[k], ns.Planner[k] = ns.Planner[k], v end
            local zsaved = ns.Zones.REUSE
            ns.Zones.REUSE = settings.WARM_START
            local ranked = ns.Zones.Rank(ctxOf(state, nil, nil))
            local out = {}
            for _, z in ipairs(ranked) do out[z.map] = table.concat(z.plan.order, " ") end
            for k, v in pairs(saved) do ns.Planner[k] = v end
            ns.Zones.REUSE = zsaved
            return out
        end
        eq(orders({ WARM_START = true }), orders({ WARM_START = false }))
    end)

    test("a second ranking of the same state reuses every other zone, and plans only the zone we stand in", function()
        local r1, r2, reused, calls = twice()
        local fine, map = allReused(r1, reused)
        ok(fine, "zone " .. tostring(map) .. " is reused")
        eq(calls, 1, "one plan: the home zone")
        for _, z in ipairs(r2) do
            if z.reused then
                for _, a in ipairs(r1) do if a.map == z.map then ok(a.plan == z.plan, "the same plan table") end end
            end
        end
        -- the reused zones keep their order (the zone we stand in was planned again, from its
        -- last plan: it may score a little better and move up)
        eq(others(r2), others(r1))
    end)

    test("a reused zone is not reused without a memory or with reuse off", function()
        local mem = ns.Memory.New()
        ns.Zones.Rank(ctxOf(baseState(), mem, 0))
        ns.Zones.REUSE = false
        local r = ns.Zones.Rank(ctxOf(baseState(), mem, 1))
        ns.Zones.REUSE = true
        for _, z in ipairs(r) do ok(not z.reused) end
        for _, z in ipairs(ns.Zones.Rank(ctxOf(baseState(), nil, 1))) do ok(not z.reused) end
    end)

    test("input: the level", function()
        local _, _, reused = twice(function(s) s.level = 23 end)
        ok(noneReused(reused), "a new level re-plans every zone")
    end)

    test("input: XP moved across the tolerance re-plans, within it reuses", function()
        local unit = ns.Memory.Continuous(ctxOf(baseState(), nil, 0)).unit
        local _, _, within = twice(function(s) s.xp = s.xp + 0.5 * unit end)
        local r1, _, within2 = twice(function(s) s.xp = s.xp + 0.5 * unit end)
        ok(allReused(r1, within) and allReused(r1, within2), "a drift under 10% of a level is reused")
        local _, _, across = twice(function(s) s.xp = s.xp + 1.5 * unit end)
        ok(noneReused(across), "more than 10% of a level is not")
    end)

    test("input: the rested pool appears, and moves", function()
        local _, _, appears = twice(function(s) s.restedPool = 3000 end)
        ok(noneReused(appears), "rested XP appearing re-plans")
        local unit = ns.Memory.Continuous(ctxOf(baseState(), nil, 0)).unit
        local mem = ns.Memory.New()
        local s1 = baseState(); s1.restedPool = 4000
        local r1 = ns.Zones.Rank(ctxOf(s1, mem, 0))
        local s2 = baseState(); s2.restedPool = 4000 - unit -- the bonus is half the pool: a drift of half a unit
        local reused = {}
        for _, z in ipairs(ns.Zones.Rank(ctxOf(s2, mem, 5))) do if z.reused then reused[z.map] = true end end
        ok(allReused(r1, reused), "a small drain is reused")
        local s3 = baseState(); s3.restedPool = 4000 - 4 * unit
        reused = {}
        for _, z in ipairs(ns.Zones.Rank(ctxOf(s3, mem, 6))) do if z.reused then reused[z.map] = true end end
        ok(noneReused(reused), "a large one is not")
    end)

    test("input: XP bonus, group size, flight path learned, capacity", function()
        local _, _, a = twice(function(s) s.xpBonus = 0.05 end)
        ok(noneReused(a), "xp bonus")
        local _, _, b = twice(function(s) s.groupSize = 2 end)
        ok(noneReused(b), "group size")
        local _, _, c = twice(function(s)
            for id in pairs(raw.world.travel.nodes) do
                if not s.knownNodes[id] then s.knownNodes[id] = true; break end
            end
        end)
        ok(noneReused(c), "a flight path learned")
        local _, _, d = twice(function(s) s.capacity = 25 end)
        ok(noneReused(d), "log capacity")
    end)

    -- a zone and one of its quests that no other zone's plan reads
    local function ownQuest(r1)
        local watches = {}
        for _, z in ipairs(r1) do
            if z.plan.inputs then watches[z.map] = ns.Memory.Watch(z.plan.inputs.ids) end
        end
        for _, z in ipairs(r1) do
            if z.map ~= 1433 and z.map > 0 then
                for _, key in ipairs(z.plan.order) do
                    local id = tonumber(key:match("^P:(%d+)$"))
                    if id then
                        local alone = true
                        for map, list in pairs(watches) do
                            if map ~= z.map then
                                for _, w in ipairs(list) do if w == id then alone = false end end
                            end
                        end
                        if alone then return z.map, id end
                    end
                end
            end
        end
    end
    local function onlyOne(r1, reused, x)
        for _, map in ipairs(others(r1)) do
            if map == x then ok(not reused[map], "zone " .. map .. " is planned again")
            else ok(reused[map], "zone " .. map .. " is reused") end
        end
    end
    local function logEntry(id, have)
        local q = ns.Data.GetQuest(id)
        return { id = id, title = q.name, level = q.level, isComplete = false, isFailed = false, objectives = {
            { text = "x", type = "monster", finished = false, have = have or 0, need = 10 } } }
    end

    test("input: a quest of one zone ignored re-plans that zone only", function()
        local mem = ns.Memory.New()
        local r0 = ns.Zones.Rank(ctxOf(baseState(), mem, 0))
        local x, id = ownQuest(r0)
        ok(x and id, "a zone with a quest of its own")
        local r1, _, reused = twice(function(s) s.ignored = { [id] = true } end, 10, mem)
        onlyOne(r1, reused, x)
    end)

    test("input: a quest of one zone accepted re-plans that zone only", function()
        local x, id
        local r1, _, reused = twice(function(s, first)
            x, id = ownQuest(first)
            s.log = { logEntry(id) }
        end)
        ok(x and id)
        onlyOne(r1, reused, x)
    end)

    test("input: progress on a log quest a zone worked with re-plans that zone only", function()
        local mem = ns.Memory.New()
        local x, id
        do -- find the quest on a first ranking, start both rankings with it in the log
            local r0 = ns.Zones.Rank(ctxOf(baseState(), nil, 0))
            x, id = ownQuest(r0)
        end
        ok(x and id)
        local s1 = baseState(); s1.log = { logEntry(id, 1) }
        local r1 = ns.Zones.Rank(ctxOf(s1, mem, 0))
        local used = false
        for _, z in ipairs(r1) do if z.map == x and z.plan.inputs.used[id] then used = true end end
        if used then
            local s2 = baseState(); s2.log = { logEntry(id, 2) }
            local reused = {}
            for _, z in ipairs(ns.Zones.Rank(ctxOf(s2, mem, 5))) do if z.reused then reused[z.map] = true end end
            onlyOne(r1, reused, x)
        else
            -- the quest left the plan of its zone (done in the log is not routed): nothing to check there
            ok(true)
        end
    end)

    test("input: a prerequisite completed re-plans the zone whose quest needs it", function()
        local x, pre
        local r1, _, reused = twice(function(s, first)
            local watches = {}
            for _, z in ipairs(first) do
                if z.plan.inputs then watches[z.map] = ns.Memory.Watch(z.plan.inputs.ids) end
            end
            for _, z in ipairs(first) do
                if z.map ~= 1433 and z.map > 0 and not x then
                    for id in pairs(z.plan.inputs.ids) do
                        local q = ns.Data.GetQuest(id)
                        for _, p in ipairs(q and q.preAll or {}) do
                            if not s.completed[p] and not x then
                                local alone = true
                                for map, list in pairs(watches) do
                                    if map ~= z.map then for _, w in ipairs(list) do if w == p then alone = false end end end
                                end
                                if alone then x, pre = z.map, p end
                            end
                        end
                    end
                end
            end
            if x then s.completed[pre] = true end
        end)
        ok(x, "a zone with a prerequisite of its own")
        onlyOne(r1, reused, x)
    end)

    test("input: learned pace beyond 2% re-plans everything, within it nothing", function()
        local function pace(m) return { c = { n = 20, m = m } } end
        local mem = ns.Memory.New()
        local s1 = baseState(); s1.pace = pace(0)
        local r1 = ns.Zones.Rank(ctxOf(s1, mem, 0))
        local f = ns.Learn.PaceFactor
        ok(math.abs(f(pace(0.01), "c") / f(pace(0), "c") - 1) < 0.02, "setup: a small change")
        ok(math.abs(f(pace(0.3), "c") / f(pace(0), "c") - 1) > 0.05, "setup: a big change")
        local s2 = baseState(); s2.pace = pace(0.01)
        local reused = {}
        for _, z in ipairs(ns.Zones.Rank(ctxOf(s2, mem, 5))) do if z.reused then reused[z.map] = true end end
        ok(allReused(r1, reused), "within 2%")
        local s3 = baseState(); s3.pace = pace(0.3)
        reused = {}
        for _, z in ipairs(ns.Zones.Rank(ctxOf(s3, mem, 6))) do if z.reused then reused[z.map] = true end end
        ok(noneReused(reused), "beyond 2%")
    end)

    test("input: the step-time model", function()
        local function model(w5) return { v = ns.Learn.STEP_VERSION, n = 5, w = { 0, 0, 0, 0, w5, 0, 0, 0, 0 } } end
        local mem = ns.Memory.New()
        local s1 = baseState(); s1.stepModel = model(0.4)
        local r1 = ns.Zones.Rank(ctxOf(s1, mem, 0))
        local s2 = baseState(); s2.stepModel = model(0.405)
        local reused = {}
        for _, z in ipairs(ns.Zones.Rank(ctxOf(s2, mem, 5))) do if z.reused then reused[z.map] = true end end
        ok(allReused(r1, reused), "a weight within 0.02")
        local s3 = baseState(); s3.stepModel = model(0.6)
        reused = {}
        for _, z in ipairs(ns.Zones.Rank(ctxOf(s3, mem, 6))) do if z.reused then reused[z.map] = true end end
        ok(noneReused(reused), "a weight 0.2 away")
        local _, _, none = twice(function(s) s.stepModel = model(0.4) end)
        ok(noneReused(none), "a model where there was none")
    end)

    test("input: time passing beyond the age limit re-plans everything", function()
        local r1, _, reused = twice(nil, ns.Zones.REUSE_MAX_AGE)
        ok(allReused(r1, reused), "exactly at the limit")
        local _, _, old = twice(nil, ns.Zones.REUSE_MAX_AGE + 1)
        ok(noneReused(old), "one second later")
    end)

    test("input: a changed planner setting re-plans everything", function()
        local was = ns.Planner.SEARCH_ITERATIONS
        local _, _, reused = twice(function() ns.Planner.SEARCH_ITERATIONS = was + 1 end)
        ns.Planner.SEARCH_ITERATIONS = was
        ok(noneReused(reused))
    end)

    test("a quest accepted that belongs to another zone leaves this one alone", function()
        -- accepted in the log: a quest from a zone's plan re-plans that zone, the others stay (above);
        -- a log quest the plans never looked at that is not on their maps changes nothing
        local mem = ns.Memory.New()
        local r0 = ns.Zones.Rank(ctxOf(baseState(), mem, 0))
        local before = {}
        for _, z in ipairs(r0) do before[z.map] = z.plan end
        local x, id = ownQuest(r0)
        local s = baseState(); s.log = { logEntry(id) }
        local r = ns.Zones.Rank(ctxOf(s, mem, 3))
        for _, z in ipairs(r) do
            if z.map ~= x and z.map ~= 1433 then ok(z.reused and z.plan == before[z.map], "zone " .. z.map) end
        end
    end)

    test("Memory.Reset forgets everything; old entries are dropped on Store", function()
        local mem = ns.Memory.New()
        local r = ns.Zones.Rank(ctxOf(baseState(), mem, 0))
        ok(next(mem.zones))
        local v = mem.version
        ns.Memory.Reset(mem)
        ok(not next(mem.zones) and mem.version == v + 1)
        for _, z in ipairs(ns.Zones.Rank(ctxOf(baseState(), mem, 10))) do ok(not z.reused, "nothing to reuse after a reset") end
        -- an entry untouched for longer than PRUNE_AGE goes when the next plan is stored
        ns.Zones.Rank(ctxOf(baseState(), mem, 10))
        local old = next(mem.zones)
        ok(old)
        ns.Memory.Store(mem, ctxOf(baseState(), mem, 10 + ns.Memory.PRUNE_AGE + 1), 1431, nil, r[1].plan)
        local kept = 0
        for map, e in pairs(mem.zones) do if e.reuse and map ~= 1431 then kept = kept + 1 end end
        eq(kept, 0, "the others are gone")
    end)

    test("Memory.Watch adds what Data.IsAvailable reads, sorted and without duplicates", function()
        local id, q
        for _, qid in ipairs(ns.Data.QuestIds()) do
            local cand = ns.Data.GetQuest(qid)
            if cand and #cand.preAll > 0 then id, q = qid, cand; break end
        end
        ok(id)
        local w = ns.Memory.Watch({ [id] = true })
        local has = {}
        for i, v in ipairs(w) do has[v] = true; if i > 1 then ok(w[i - 1] < v, "sorted, no duplicates") end end
        ok(has[id])
        for _, p in ipairs(q.preAll) do ok(has[p], "preAll " .. p) end
        eq(ns.Memory.Watch({ id }), w, "a list gives the same as a set")
    end)

    test("Memory.QuestSig: completed, in the log, progress of used quests", function()
        local first
        for _, qid in ipairs(ns.Data.QuestIds()) do first = qid; break end
        local ctx = ctxOf(baseState(), nil, 0)
        local watch = { first }
        local base = ns.Memory.QuestSig(ctx, watch, {})
        ctx.avail.completed[first] = true
        local done = ns.Memory.QuestSig(ctx, watch, {})
        ok(done ~= base, "completed")
        ctx.avail.completed[first] = nil
        ctx.log[first] = logEntry(first, 1)
        local inLog = ns.Memory.QuestSig(ctx, watch, {})
        ok(inLog ~= base and inLog ~= done, "in the log")
        eq(ns.Memory.QuestSig(ctx, watch, {}), inLog, "progress does not show for a quest that is not used")
        local used1 = ns.Memory.QuestSig(ctx, watch, { [first] = true })
        ctx.log[first] = logEntry(first, 2)
        ok(ns.Memory.QuestSig(ctx, watch, { [first] = true }) ~= used1, "progress shows for a used quest")
        ctx.ignored[first] = true
        ok(ns.Memory.QuestSig(ctx, watch, {}) ~= inLog, "ignored")
    end)

    test("Memory.Close: tolerances", function()
        local function c(xp, vec) return { unit = 100, xp = xp, vec = vec or {} } end
        ok(ns.Memory.Close(c(1000), c(1099)))
        ok(not ns.Memory.Close(c(1000), c(1100)))
        ok(not ns.Memory.Close(c(nil), c(1000)))
        ok(ns.Memory.Close(c(1000, { { "a", 100 } }), c(1000, { { "a", 101.9 } })))
        ok(not ns.Memory.Close(c(1000, { { "a", 100 } }), c(1000, { { "a", 103 } })))
        ok(ns.Memory.Close(c(1000, { { "w", 0.4, true } }), c(1000, { { "w", 0.419, true } })))
        ok(not ns.Memory.Close(c(1000, { { "w", 0.4, true } }), c(1000, { { "w", 0.43, true } })))
        ok(not ns.Memory.Close(c(1000, { { "a", 1 } }), c(1000, { { "b", 1 } })), "other names")
    end)

    test("Memory.Seed and Remember: every fifth plan of a zone starts from scratch", function()
        local mem = ns.Memory.New()
        local plan = { order = { "P:1", "T:1" }, search = { weights = { destroy = { x = 1 }, regret = { 1 } } } }
        eq({ ns.Memory.Seed(mem, 7) }, {}, "nothing yet")
        local used = {}
        for i = 1, 11 do
            local seed, weights = ns.Memory.Seed(mem, 7)
            used[i] = seed ~= nil
            if seed then eq(seed, plan.order); eq(weights, plan.search.weights) end
            ns.Memory.Remember(mem, 7, plan, seed ~= nil)
        end
        eq(used, { false, true, true, true, true, false, true, true, true, true, false })
        ns.Memory.Remember(mem, 8, { order = {} }, false)
        eq({ ns.Memory.Seed(mem, 8) }, {}, "an empty plan is no seed")
    end)

    -- ----- warm start -----
    local function wellFormed(plan)
        local at, count = {}, {}
        for i, key in ipairs(plan.order) do
            count[key] = (count[key] or 0) + 1
            at[key] = i
        end
        for key, n in pairs(count) do
            if n > 1 then return false, key .. " twice" end
            local id = key:match("^T:(%d+)$")
            if id and at["P:" .. id] and at["P:" .. id] > at[key] then return false, "turned in before accepted: " .. id end
        end
        for i, step in ipairs(plan.steps) do
            if step.kind == "work" then
                for _, q in ipairs(step.quests) do
                    local p, t = at["P:" .. q.id], at["T:" .. q.id]
                    if not t or t < i or (p and p > i) then return false, "work out of order for " .. q.id end
                end
            end
        end
        return true
    end

    test("a warm start gives a well-formed plan at least as good as the plain route, and the same twice", function()
        local state = baseState()
        local saved = ns.Planner.SEARCH_ITERATIONS
        ns.Planner.SEARCH_ITERATIONS = 40
        local cold = ns.Zones.PlanZone(1431, ctxOf(state, nil, nil))
        ns.Planner.SEARCH_ITERATIONS = 0
        local plain = ns.Zones.PlanZone(1431, ctxOf(state, nil, nil))
        ns.Planner.SEARCH_ITERATIONS = 40
        local warm = ns.Zones.PlanZone(1431, ctxOf(state, nil, nil), nil, nil, { warm = cold.searchOrder, weights = cold.search.weights })
        ok(wellFormed(warm))
        ok(warm.search and warm.search.warm, "the search started warm")
        ok(warm.search.rounds <= ns.Planner.WARM_ROUNDS)
        ok(warm.score >= plain.score, string.format("%.0f against the plain route's %.0f", warm.score, plain.score))
        local again = ns.Zones.PlanZone(1431, ctxOf(state, nil, nil), nil, nil, { warm = cold.searchOrder, weights = cold.search.weights })
        eq(table.concat(again.order, " "), table.concat(warm.order, " "))
        -- with a memory: the same two plans in a row twice give the same orders
        local function chain()
            local mem = ns.Memory.New()
            local a = ns.Zones.PlanZone(1431, ctxOf(state, mem, 0))
            local b = ns.Zones.PlanZone(1431, ctxOf(state, mem, 1))
            return table.concat(a.order, " "), table.concat(b.order, " "), b.search.warm
        end
        local a1, b1, w1 = chain()
        local a2, b2 = chain()
        eq({ a1, b1 }, { a2, b2 })
        ok(w1, "the second plan is warm")
        ns.Planner.SEARCH_ITERATIONS = saved
    end)

    test("a warm start from a seed that no longer fits still gives a valid plan", function()
        local state = baseState()
        local cold = ns.Zones.PlanZone(1431, ctxOf(state, nil, nil))
        local seeds = {}
        -- turned-in quests, unknown ids, keys of no stop
        local junk = { "P:99999999", "T:99999999", "W:nothing", "T:0", "X:1" }
        for _, k in ipairs(cold.order) do junk[#junk + 1] = k end
        seeds[#seeds + 1] = junk
        -- everything backwards
        local back = {}
        for i = #cold.order, 1, -1 do back[#back + 1] = cold.order[i] end
        seeds[#seeds + 1] = back
        -- a seed of quests that are done by now
        local done = baseState()
        for _, k in ipairs(cold.order) do
            local id = tonumber(k:match("^T:(%d+)$"))
            if id then done.completed[id] = true end
        end
        for _, seed in ipairs(seeds) do
            local plan = ns.Zones.PlanZone(1431, ctxOf(done, nil, nil), nil, nil, { warm = seed })
            ok(wellFormed(plan))
            ok(#plan.steps >= 0)
        end
        for _, seed in ipairs(seeds) do
            local plan = ns.Zones.PlanZone(1431, ctxOf(state, nil, nil), nil, nil, { warm = seed })
            ok(wellFormed(plan))
            ok(#plan.steps > 0)
        end
    end)

    test("a warm seed with a quest before the level it needs puts it after the level-up", function()
        local Data = ns.Data
        local completed = {}
        for _, id in ipairs(ns.Data.QuestIds()) do
            local q = Data.GetQuest(id)
            if q and q.level > 0 and q.level <= 3 then completed[id] = true end
        end
        local own = ns.Cost.LevelUps(7, nil, nil, 1)[1]
        local function state(xp)
            return { level = 7, faction = "Alliance", class = "PALADIN", raceId = 1, map = 1429, x = 0.438, y = 0.659,
                log = {}, completed = completed, capacity = 40, xp = xp }
        end
        local gated = 0
        -- the seed is a plan made right after the level-up (quests that need level 8 are in it), the plan is made before
        local after = ns.Zones.PlanZone(1429, ns.Zones.Context((function() local s = state(0); s.level = 8; return s end)()))
        local seed = {}
        for _, k in ipairs(after.order) do seed[#seed + 1] = k end
        local plan = ns.Zones.PlanZone(1429, ns.Zones.Context(state(own - 40)), nil, nil, { warm = seed })
        ok(wellFormed(plan))
        for i, step in ipairs(plan.steps) do
            if step.needLevel and step.needLevel > 7 then
                gated = gated + 1
                local reached
                for j = 1, i - 1 do
                    if plan.steps[j].levelUp and plan.steps[j].levelUp >= step.needLevel then reached = true end
                end
                ok(reached, "step " .. i .. " waits for level " .. step.needLevel)
            end
        end
    end)

    test("reading the memory without writing it: a read-only plan leaves it as it was", function()
        local mem = ns.Memory.New()
        local state = baseState()
        ns.Zones.PlanZone(1431, ctxOf(state, mem, 0))
        local before = H.serialize(mem)
        local plan = ns.Zones.PlanZone(1431, ctxOf(state, mem, 1), nil, nil, { readOnly = true })
        ok(plan.warmSeed, "it did read the earlier plan")
        eq(H.serialize(mem), before)
        ns.Zones.PlanZone(1431, ctxOf(state, mem, 2))
        ok(H.serialize(mem) ~= before, "a normal plan writes it")
    end)

    -- ----- the itinerary -----
    test("an itinerary whose later zones start warm is valid and earns as much as a cold one", function()
        local saved, horizon = ns.Planner.SEARCH_ITERATIONS, ns.Zones.HORIZON
        ns.Planner.SEARCH_ITERATIONS = 40
        -- four hours: in two, staying in one zone is best here (walks between zones follow the
        -- walk table), and there would be no later zone to start warm
        ns.Zones.HORIZON = 4 * 3600
        local state = baseState()
        local ctx = ns.Zones.Context(state)
        local ranked = ns.Zones.Rank(ctx)
        ns.Zones.ITINERARY_WARM = false
        local cold = ns.Zones.Itinerary(state, ctx, ranked)
        ns.Zones.ITINERARY_WARM = true
        local warm = ns.Zones.Itinerary(state, ctx, ranked)
        ns.Planner.SEARCH_ITERATIONS, ns.Zones.HORIZON = saved, horizon
        ok(cold and warm and #warm.segments >= 2)
        -- (40 search rounds: either start can land a few percent apart on a given data build)
        ok(warm.xp >= cold.xp * 0.97, string.format("%d XP warm against %d cold", warm.xp, cold.xp))
        local clock, xp, seen = 0, 0, {}
        for i, seg in ipairs(warm.segments) do
            ok(not seen[seg.map], "no zone twice")
            seen[seg.map] = true
            ok(seg.travel >= 0 and seg.seconds >= ns.Zones.MIN_STAY)
            clock, xp = clock + seg.travel + seg.seconds, xp + seg.xp
            if i < #warm.segments then ok(seg.leaveKey and seg.leaveKey:find("^[TW]:")) else ok(not seg.leave) end
        end
        ok(clock <= warm.horizon + 1)
        ok(math.abs(xp - warm.xp) <= #warm.segments)
    end)

    test("the itinerary does not touch the memory", function()
        local mem = ns.Memory.New()
        local state = baseState()
        local ranked = ns.Zones.Rank(ctxOf(state, mem, 0))
        local before = H.serialize(mem)
        local st = {}
        for k, v in pairs(state) do st[k] = v end
        st.memory, st.now = mem, 0
        ns.Zones.Itinerary(st, ns.Zones.Context(st), ranked)
        eq(H.serialize(mem), before)
    end)
end)
