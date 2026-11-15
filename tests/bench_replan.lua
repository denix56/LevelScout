-- tests/bench_replan.lua: what plan memory (reuse between re-rankings, warm start) saves and costs
-- over a sequence of re-plans, and what the itinerary's later zones gain from a warm start.
-- Usage (from the repo root):
--   .tools/bin/lua5.1 tests/bench_replan.lua
-- Options (environment):
--   ADVANCE="600 120"   seconds between two re-rankings (the state is projected to the first step at
--                       least that many seconds into the shown route); one run per value. Default "600 120".
--   LEAVE=turnin        project to the first turn-in at least that far instead (usually 20+ minutes away)
--   STEPS=8             re-rankings per character
--   ONLY=3              one character only (its number in tests/bench.lua's list)
--   ITIN=0              skip the itinerary part (default: on)
--   ITINROUNDS="nil 40 60 80"   rounds of the itinerary's re-plans to compare (default "nil 40")
--   XPTOL=0.05 MAXAGE=180   tighter reuse (Memory.XP_TOLERANCE, Zones.REUSE_MAX_AGE)
--   NOISE=1             for each reused zone also plan it cold from scratch with another random seed at
--                       the same state: the staleness figure contains the search's own run-to-run noise,
--                       this prints how large that is
--   VERBOSE=1           one line per step
-- Every step has the same state for both ways of planning, taken from the route the cold ranking shows:
--   cold   Zones.Rank / Zones.PlanZone without a memory (what the planner did before),
--   memory Zones.Rank with a memory: other zones reused while they still stand, searches warm.
-- At each step the memory way also does a "quick re-plan" of the shown zone half way to the next
-- step (as the Engine does on quest progress); cold 120 rounds, cold 60 rounds and warm are compared
-- there. Work is the deterministic work unit (plan.work); ms is CPU and only indicative.
local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."
package.path = root .. "/tests/?.lua;" .. package.path
local print = function(...) io.write(table.concat({ ... }, " "), "\n") end
local H = require("harness")
local M = require("mocks")
M.install()

local CHARACTERS = {
    { 7, "Alliance", "WARRIOR", 1, 1429, 43.8, 65.9, "Elwynn, Goldshire" },
    { 15, "Alliance", "MAGE", 1, 1436, 56.3, 47.5, "Westfall, Sentinel Hill" },
    { 22, "Alliance", "PALADIN", 1, 1433, 30.0, 44.0, "Redridge, Lakeshire" },
    { 31, "Alliance", "ROGUE", 1, 1431, 75.0, 45.0, "Duskwood, Darkshire" },
    { 35, "Alliance", "HUNTER", 3, 1424, 50.0, 58.0, "Hillsbrad, Southshore" },
    { 42, "Alliance", "WARRIOR", 1, 1446, 51.0, 28.0, "Tanaris, Gadgetzan" },
    { 12, "Horde", "SHAMAN", 2, 1413, 52.0, 30.0, "Barrens, Crossroads" },
    { 25, "Horde", "WARLOCK", 5, 1424, 62.0, 20.0, "Hillsbrad, Tarren Mill" },
}

local function numbers(name, default)
    local out = {}
    for n in (os.getenv(name) or default):gmatch("%-?[%d%.]+") do out[#out + 1] = tonumber(n) end
    return out
end
local ADVANCES = numbers("ADVANCE", "600 120")
local STEPS = tonumber(os.getenv("STEPS")) or 8
local only = os.getenv("ONLY") and tonumber(os.getenv("ONLY"))
local ITIN = os.getenv("ITIN") ~= "0"
local NOISE = os.getenv("NOISE") and os.getenv("NOISE") ~= "" and os.getenv("NOISE") ~= "0"
local XPTOL, MAXAGE = tonumber(os.getenv("XPTOL")), tonumber(os.getenv("MAXAGE"))
local VERBOSE = os.getenv("VERBOSE") and os.getenv("VERBOSE") ~= "" and os.getenv("VERBOSE") ~= "0"
local ITIN_ROUNDS = {}
for item in (os.getenv("ITINROUNDS") or "nil 40"):gmatch("%S+") do ITIN_ROUNDS[#ITIN_ROUNDS + 1] = tonumber(item) or false end

local function mean(list)
    local s = 0
    for _, v in ipairs(list) do s = s + v end
    return #list > 0 and s / #list or 0
end
local function maxOf(list)
    local m = 0
    for _, v in ipairs(list) do if v > m then m = v end end
    return m
end

local function setup(char)
    M.reset(); M.install()
    local ns = H.loadAddon()
    if XPTOL then ns.Memory.XP_TOLERANCE = XPTOL end
    if MAXAGE then ns.Zones.REUSE_MAX_AGE = MAXAGE end
    local level, faction, class, race, map, x, y = unpack(char)
    ns.Data.Init({ faction = faction, class = class, clientBuild = ns.data.meta.build }, M.questieDB(faction, class))
    ns.Data.BuildIndex()
    local completed = {}
    for _, id in ipairs(ns.Data.QuestIds()) do
        local q = ns.Data.GetQuest(id)
        if q and q.level > 0 and q.level <= level - 4 then completed[id] = true end
    end
    local state = { level = level, faction = faction, class = class, raceId = race, map = map, x = x / 100, y = y / 100,
        log = {}, completed = completed, capacity = 40, knownNodes = {}, now = 0 }
    for id, n in pairs(ns.data.world.travel.nodes) do
        if n[7] == "n" or n[7] == (faction == "Alliance" and "a" or "h") then state.knownNodes[id] = true end
    end
    return ns, state
end

local function withMemory(state, mem, now)
    local st = {}
    for k, v in pairs(state) do st[k] = v end
    st.memory, st.now = mem, now
    return st
end

-- seconds from the start of the plan (now) to finishing step i
local function since(plan, i) return plan.steps[i].t end
-- The step the state is projected to: the first step at least `seconds` into the route. (The
-- first turn-in is usually 20 minutes or more away: the planner batches accepts, then the work,
-- then the turn-ins. LEAVE=turnin takes the first turn-in as the design's text says.)
local TURNIN = os.getenv("LEAVE") == "turnin"
local function leaveAt(plan, seconds)
    for i, s in ipairs(plan.steps) do
        if (not TURNIN or s.kind == "turnin") and since(plan, i) >= seconds then return i end
    end
end

local function rankWork(ranked)
    local w, n, reused = 0, 0, 0
    for _, z in ipairs(ranked) do
        n = n + 1
        if z.reused then reused = reused + 1 else w = w + (z.plan.work or 0) end
    end
    return w, n, reused
end

local function timed(fn)
    local t0 = os.clock()
    local a, b = fn()
    return a, b, (os.clock() - t0) * 1000
end

local function pct(a, b) return b > 0 and (a / b - 1) * 100 or 0 end

-- One character, one ADVANCE. Returns the per-step records and the states for the itinerary part.
local function sequence(char, advance)
    local ns, state = setup(char)
    local Zones = ns.Zones
    local mem = ns.Memory.New()
    local clock = 0
    local rec = { steps = {}, states = {} }
    local prevLevel = state.level
    for step = 0, STEPS - 1 do
        state.now = clock
        rec.states[step] = withMemory(state, nil, clock)
        local s = { step = step, levelUp = state.level ~= prevLevel }
        prevLevel = state.level
        -- cold
        local ctxC = Zones.Context(withMemory(state, nil, clock))
        local rankedC, _, msC = timed(function() return Zones.Rank(ctxC), nil end)
        s.workC, s.zones = rankWork(rankedC)
        s.msC = msC
        -- memory
        local ctxM = Zones.Context(withMemory(state, mem, clock))
        local rankedM, _, msM = timed(function() return Zones.Rank(ctxM), nil end)
        s.workM, _, s.reused = rankWork(rankedM)
        s.msM = msM
        -- staleness of reused zones, quality of the others, the top zone
        local byMap = {}
        for _, z in ipairs(rankedC) do byMap[z.map] = z.plan end
        s.stale, s.warmQ = {}, {}
        for _, z in ipairs(rankedM) do
            local c = byMap[z.map]
            if c and c.score > 0 then
                if z.reused then
                    s.stale[#s.stale + 1] = math.abs(z.plan.score - c.score) / c.score * 100
                else
                    s.warmQ[#s.warmQ + 1] = pct(z.plan.score, c.score)
                end
            end
        end
        local why = {}
        for _, z in ipairs(rankedM) do if z.why and z.why ~= "none" then why[#why + 1] = z.map .. ":" .. z.why end end
        s.why = table.concat(why, " ")
        s.noise = {}
        if NOISE then
            ns.Search.SEED_SALT = 1
            local again = {}
            for _, z in ipairs(Zones.Rank(ctxC)) do again[z.map] = z.plan end
            for _, z in ipairs(rankedM) do
                local c, p = byMap[z.map], again[z.map]
                if z.reused and c and p and c.score > 0 then s.noise[#s.noise + 1] = math.abs(p.score - c.score) / c.score * 100 end
            end
            ns.Search.SEED_SALT = 0
        end
        s.sameTop = (rankedC[1] and rankedM[1] and rankedC[1].map == rankedM[1].map) and 1 or 0
        -- the shown zone, as the Engine picks it
        local shownMap
        local function planOf(ranked, map)
            for _, z in ipairs(ranked) do if z.map == map then return z.plan end end
        end
        local here = planOf(rankedC, state.map)
        shownMap = (here and #here.steps > 0) and state.map or (rankedC[1] and rankedC[1].map)
        local shown = shownMap and planOf(rankedC, shownMap)
        rec.steps[#rec.steps + 1] = s
        if not shown or #shown.steps == 0 then break end
        local leave = leaveAt(shown, advance)
        if not leave then break end
        -- a quick re-plan of the shown zone half way: the state there, three ways
        local mid = leaveAt(shown, advance / 2)
        if mid and mid < leave then
            local midState = Zones.Project(withMemory(state, nil, clock), ctxC, shown, mid, nil)
            midState.carried = nil
            local midNow = clock + shown.steps[mid].t
            midState.now = midNow
            local base = withMemory(midState, nil, midNow)
            local cold120, w120 = (function()
                local ctx = Zones.Context(base)
                local p = Zones.PlanZone(shownMap, ctx, nil, nil, { warm = false, readOnly = true })
                return p, p.work
            end)()
            local cold60, w60 = (function()
                local ctx = Zones.Context(base)
                ctx.searchRounds = 60
                local p = Zones.PlanZone(shownMap, ctx, nil, nil, { warm = false, readOnly = true })
                return p, p.work
            end)()
            local ctx = Zones.Context(withMemory(midState, mem, midNow))
            local warm = Zones.PlanZone(shownMap, ctx)
            s.quick = { w120 = w120, w60 = w60, wWarm = warm.work, used = warm.search and warm.search.warm or false,
                vs120 = pct(warm.score, cold120.score), vs60 = pct(warm.score, cold60.score), s60vs120 = pct(cold60.score, cold120.score) }
        end
        -- on to the next state
        local nextState = Zones.Project(withMemory(state, nil, clock), ctxC, shown, leave, nil)
        nextState.carried = nil
        clock = clock + shown.steps[leave].t
        nextState.memory = nil
        state = nextState
    end
    return rec, ns
end

-- Itinerary at a stored state: XP and work for each setting of (rounds, warm).
local function itinerary(ns, state, settings)
    local Zones = ns.Zones
    local ctx = Zones.Context(state)
    local ranked = Zones.Rank(ctx)
    local out = {}
    local plan = Zones.PlanZone
    for i, set in ipairs(settings) do
        Zones.ITINERARY_ROUNDS = set.rounds
        Zones.ITINERARY_WARM = set.warm
        local work = 0
        Zones.PlanZone = function(...)
            local p = plan(...)
            work = work + (p.work or 0)
            return p
        end
        local t0 = os.clock()
        local it = Zones.Itinerary(state, ctx, ranked)
        out[i] = { xp = it and it.xp or 0, work = work, ms = (os.clock() - t0) * 1000, segs = it and #it.segments or 0 }
        Zones.PlanZone = plan
    end
    Zones.ITINERARY_ROUNDS, Zones.ITINERARY_WARM = nil, true
    return out
end

local totalsByAdvance = {}
for _, advance in ipairs(ADVANCES) do
    print(string.format("=== ADVANCE %d s, %d steps ===", advance, STEPS))
    local agg = { workC = 0, workM = 0, workCnl = 0, workMnl = 0, ms = { 0, 0 }, zones = 0, reused = 0, stale = {}, warmQ = {},
        top = {}, quick = {}, steps = 0, stepsNL = 0 }
    for i, char in ipairs(CHARACTERS) do
        if not only or only == i then
            local rec, ns = sequence(char, advance)
            print(string.format("%-28s %d steps", char[1] .. " " .. char[8], #rec.steps))
            for _, s in ipairs(rec.steps) do
                agg.steps = agg.steps + 1
                agg.workC, agg.workM = agg.workC + s.workC, agg.workM + s.workM
                if s.step > 0 then
                    agg.ms[1], agg.ms[2] = agg.ms[1] + s.msC, agg.ms[2] + s.msM
                    agg.zones, agg.reused = agg.zones + s.zones, agg.reused + s.reused
                    agg.top[#agg.top + 1] = s.sameTop
                    for _, v in ipairs(s.stale) do agg.stale[#agg.stale + 1] = v end
                    for _, v in ipairs(s.warmQ) do agg.warmQ[#agg.warmQ + 1] = v end
                    agg.noise = agg.noise or {}
                    for _, v in ipairs(s.noise) do agg.noise[#agg.noise + 1] = v end
                    if not s.levelUp then
                        agg.stepsNL = agg.stepsNL + 1
                        agg.workCnl, agg.workMnl = agg.workCnl + s.workC, agg.workMnl + s.workM
                    end
                end
                if s.quick then agg.quick[#agg.quick + 1] = s.quick end
                if VERBOSE then
                    local q = s.quick
                    if s.why ~= "" then print("      not reused: " .. s.why) end
                    print(string.format("   step %d%s  rank work cold %6.0fk mem %6.0fk  reused %d/%d  ms %5.0f/%5.0f  stale mean %.2f%% max %.2f%%  warm-vs-cold %+.2f%%%s",
                        s.step, s.levelUp and " (level up)" or "", s.workC / 1000, s.workM / 1000, s.reused, s.zones, s.msC, s.msM,
                        mean(s.stale), maxOf(s.stale), mean(s.warmQ),
                        q and string.format("   quick: work %.0fk cold120 / %.0fk cold60 / %.0fk warm%s, score %+.2f%% vs 120, %+.2f%% vs 60",
                            q.w120 / 1000, q.w60 / 1000, q.wWarm / 1000, q.used and "" or " (cold)", q.vs120, q.vs60) or ""))
                end
            end
            if ITIN then
                local settings = {}
                for _, r in ipairs(ITIN_ROUNDS) do
                    settings[#settings + 1] = { rounds = r or nil, warm = false, name = (r and tostring(r) or "full") .. " cold" }
                    settings[#settings + 1] = { rounds = r or nil, warm = true, name = (r and tostring(r) or "full") .. " warm" }
                end
                for _, at in ipairs({ 0, 4 }) do
                    local state = rec.states[at]
                    if state then
                        local res = itinerary(ns, state, settings)
                        agg.itin = agg.itin or {}
                        for k, r in ipairs(res) do
                            local t = agg.itin[k] or { name = settings[k].name, xp = 0, work = 0, ms = 0, n = 0 }
                            agg.itin[k] = t
                            t.xp, t.work, t.ms, t.n = t.xp + r.xp, t.work + r.work, t.ms + r.ms, t.n + 1
                            if VERBOSE then print(string.format("   itinerary at step %d, %-10s XP %6d  re-plan work %6.0fk  %5.0f ms  %d zones", at, settings[k].name, r.xp, r.work / 1000, r.ms, r.segs)) end
                        end
                    end
                end
            end
        end
    end
    totalsByAdvance[advance] = agg
    print("")
    print(string.format("Ranking (steps after the first): work cold %.0fk, memory %.0fk (%+.0f%%); without level-up steps: cold %.0fk, memory %.0fk (%+.0f%%)",
        agg.workC / 1000, agg.workM / 1000, pct(agg.workM, agg.workC), agg.workCnl / 1000, agg.workMnl / 1000, pct(agg.workMnl, agg.workCnl)))
    print(string.format("   (step 0 included in the totals above; the memory is empty there) zones reused %d of %d (%.0f%%); CPU ms cold %.0f, memory %.0f (indicative)",
        agg.reused, agg.zones, agg.zones > 0 and agg.reused / agg.zones * 100 or 0, agg.ms[1], agg.ms[2]))
    print(string.format("Staleness of reused zones: mean %.2f%%, max %.2f%% of the fresh score (n=%d); top-ranked zone same as fresh in %.0f%% of steps",
        mean(agg.stale), maxOf(agg.stale), #agg.stale, mean(agg.top) * 100))
    if agg.noise and #agg.noise > 0 then
        print(string.format("   search noise (same zones, cold, another random seed, same state): mean %.2f%%, max %.2f%% (n=%d)", mean(agg.noise), maxOf(agg.noise), #agg.noise))
    end
    print(string.format("Zones planned warm in a ranking vs the cold plan of the same state: mean %+.2f%% (n=%d)", mean(agg.warmQ), #agg.warmQ))
    if #agg.quick > 0 then
        local w120, w60, wW, v120, v60, s60, used = {}, {}, {}, {}, {}, {}, 0
        for _, q in ipairs(agg.quick) do
            w120[#w120 + 1], w60[#w60 + 1], wW[#wW + 1] = q.w120, q.w60, q.wWarm
            v120[#v120 + 1], v60[#v60 + 1], s60[#s60 + 1] = q.vs120, q.vs60, q.s60vs120
            if q.used then used = used + 1 end
        end
        print(string.format("Quick re-plan of the shown zone (n=%d, %d warm): work cold120 %.0fk, cold60 %.0fk, warm %.0fk (%+.0f%% vs cold120);",
            #agg.quick, used, mean(w120) / 1000, mean(w60) / 1000, mean(wW) / 1000, pct(mean(wW), mean(w120))))
        print(string.format("   score: warm vs cold120 %+.2f%% (worst %+.2f%%), warm vs cold60 %+.2f%% (worst %+.2f%%); cold60 vs cold120 %+.2f%%",
            mean(v120), math.min(unpack(v120)), mean(v60), math.min(unpack(v60)), mean(s60)))
    end
    if agg.itin then
        print("Itinerary (states of step 0 and 4 of every character): XP and the work of the re-planned later zones")
        local base = agg.itin[1]
        for _, t in ipairs(agg.itin) do
            print(string.format("   %-10s XP %9.0f (%+.2f%% vs %s)  re-plan work %7.0fk  ms %7.0f", t.name, t.xp, pct(t.xp, base.xp), base.name, t.work / 1000, t.ms))
        end
    end
    print("")
end
