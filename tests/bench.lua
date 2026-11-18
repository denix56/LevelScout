-- tests/bench.lua: how good are the planner's routes, and what do they cost to compute?
-- Plans a fixed set of imagined characters on the real data with several planner settings.
-- THE MEASURE: XP actually earned over the next two hours (Zones.Itinerary: Zones.HORIZON = 2 hours
-- across up to 3 zones), judged PAIRED against base: for every (character, salt) pair the % difference
-- to base on the same character and salt. Printed per config: the total XP (sum over characters, mean
-- over salts), % vs base, the mean of the paired differences, its standard error (sd / sqrt(n), n =
-- characters x salts), the worst character (mean over salts of its % difference), how many characters
-- are worse than -0.5%, work and CPU. A second line gives the same for the best-ranked zone's route
-- in its first 120 minutes. The zone-score columns (mean / worst / top zone % vs the unsearched plan)
-- are secondary and come after.
-- VERDICT per config versus base (on the itinerary line; with ITIN=0 on the 120-minute line):
--   "better"              the paired mean is above 2 SE and no character is below -1%
--   "worse"               the paired mean is below -2 SE, or a character is below -2%
--   "no clear difference" otherwise
-- (docs/planner.md, "How a change is judged": a change is kept on a "better" with SALTS="0 1 2 3 4".)
-- Usage (from the repo root):
--   .tools/bin/lua5.1 tests/bench.lua            compare the settings below
--   REF=4000 .tools/bin/lua5.1 tests/bench.lua   also run a long search as the reference
--   VERBOSE=1 ...                                one line per zone
--   ROUNDS="40 250" ...                          more configs: searches of that many rounds
--   ONLY=3 ...                                   one character only (its number in the list)
-- More options:
--   SET="name:Module.KEY=value,Module.KEY=value;name2:..."   add configs; Module is Planner,
--        Search, Objective or Zones; a value is a number, true, false, nil or a string.
--        Example: SET="dink:Objective.MODE=dinkelbach;rrt:Search.ACCEPT=rrt,Search.RRT_MARGIN=0.01"
--   ONLYSET=1     skip the built-in configs except "old" and "search+exact" (shown as "base")
--   BASE_SET="Module.KEY=value,..."   with ONLYSET: overrides for the "base" config, parsed like SET
--        (so base can be a flag off, and a change is judged against it directly)
--   DUMP=1        per character and salt: one line per ranked zone (map, score, xp, seconds, order) and one for
--        the itinerary (maps, leave keys, xp), so two runs can be diffed
--   BUDGET="0.25 0.5 1 2"   per config, one run per multiple of the search work "base" spent on
--        each zone (a zone's plan.search.work), rounds capped at 100000; adds a curve table
--   SALTS="0 1 2 3 4"       run every config once per Search.SEED_SALT; shows the mean over salts
--        and the standard error of the mean-zone figure
--   REPEAT=3      CPU ms = the minimum over repeats (scores are deterministic, time is noisy)
--   CHARS=2       the held-out second set of eight characters
--   ITIN=0        skip the itinerary (on by default; the headline then uses the 120-minute XP)
-- Columns: "work k" = thousand work units (plan.work, summed over zones, deterministic);
-- "ms/kwork" = CPU ms per thousand work units, starred when it differs from base by over 20%.
local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."
package.path = root .. "/tests/?.lua;" .. package.path
local print = function(...) io.write(table.concat({ ... }, " "), "\n") end
local H = require("harness")
local M = require("mocks")
M.install()

-- level, side, class, race, map, x, y
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

-- CHARS=2: a second, held-out set of characters (to check that a change found on the first set carries over)
if os.getenv("CHARS") == "2" then
    CHARACTERS = {
        { 10, "Alliance", "HUNTER", 3, 1426, 46.8, 52.4, "Dun Morogh, Kharanos" },
        { 18, "Alliance", "DRUID", 4, 1439, 37.0, 44.0, "Darkshore, Auberdine" },
        { 26, "Alliance", "PRIEST", 1, 1437, 10.0, 59.0, "Wetlands, Menethil" },
        { 38, "Alliance", "MAGE", 7, 1434, 27.0, 77.0, "Stranglethorn, Booty Bay" },
        { 9, "Horde", "WARRIOR", 6, 1412, 48.0, 59.0, "Mulgore, Bloodhoof" },
        { 17, "Horde", "ROGUE", 5, 1421, 45.0, 41.0, "Silverpine, Sepulcher" },
        { 29, "Horde", "HUNTER", 8, 1440, 73.0, 61.0, "Ashenvale, Splintertree" },
        { 40, "Horde", "SHAMAN", 2, 1434, 27.0, 77.0, "Stranglethorn, Booty Bay" },
    }
end

-- A config is { name, overrides } with overrides = list of { Module, KEY, value } applied to the
-- freshly loaded addon: { "Planner", "EXACT_WINDOW", 0 } sets ns.Planner.EXACT_WINDOW = 0.
local function planner(t)
    local list = {}
    for k, v in pairs(t) do list[#list + 1] = { "Planner", k, v } end
    table.sort(list, function(a, b) return a[2] < b[2] end)
    return list
end

local function parseValue(v)
    if v == "true" then return true elseif v == "false" then return false elseif v == "nil" then return nil end
    return tonumber(v) or v
end
local MODULES = { Planner = true, Search = true, Objective = true, Zones = true }
-- "Module.KEY=value,Module.KEY=value" as a list of { Module, KEY, value }
local function parseOverrides(rest)
    local list = {}
    for item in rest:gmatch("[^,]+") do
        local mod, key, value = item:match("^%s*(%a+)%.([%w_]+)=(.*)$")
        assert(mod and MODULES[mod], "SET: unknown module in '" .. item .. "'")
        list[#list + 1] = { mod, key, parseValue(value) }
    end
    return list
end

local ONLYSET = os.getenv("ONLYSET") and os.getenv("ONLYSET") ~= "" and os.getenv("ONLYSET") ~= "0"
local CONFIGS = {
    { "old", planner({ SEARCH_ITERATIONS = 0, EXACT_WINDOW = 0 }) },
}
local BASE -- index of the config the budgets and the cost calibration refer to
if ONLYSET then
    CONFIGS[2] = { "base", os.getenv("BASE_SET") and parseOverrides(os.getenv("BASE_SET")) or {} }
    BASE = 2
else
    CONFIGS[2] = { "search", planner({ EXACT_WINDOW = 0 }) }
    CONFIGS[3] = { "search+exact", {} }
    CONFIGS[4] = { "today's level", planner({ LEVELS_AHEAD = 0 }) } -- as above, but valued without level-ups (scores are not comparable: see CPU)
    BASE = 3
    if os.getenv("ROUNDS") then -- compare search lengths: ROUNDS="40 250"
        for n in os.getenv("ROUNDS"):gmatch("%d+") do
            CONFIGS[#CONFIGS + 1] = { "search " .. n, planner({ SEARCH_ITERATIONS = tonumber(n) }) }
        end
    end
    if os.getenv("REF") then
        CONFIGS[#CONFIGS + 1] = { "reference", planner({ SEARCH_ITERATIONS = tonumber(os.getenv("REF")) }) }
    end
end
local REFERENCE
for ci, c in ipairs(CONFIGS) do if c[1] == "reference" then REFERENCE = ci end end

if os.getenv("SET") then
    for spec in os.getenv("SET"):gmatch("[^;]+") do
        local name, rest = spec:match("^%s*([^:]+):(.*)$")
        assert(name, "SET: expected name:Module.KEY=value in '" .. spec .. "'")
        CONFIGS[#CONFIGS + 1] = { name, parseOverrides(rest) }
    end
end

local function numbers(name, default)
    local out = {}
    for n in (os.getenv(name) or default):gmatch("%-?[%d%.]+") do out[#out + 1] = tonumber(n) end
    return out
end
local only = os.getenv("ONLY") and tonumber(os.getenv("ONLY"))
local SALTS = numbers("SALTS", "0")
local BUDGETS = os.getenv("BUDGET") and numbers("BUDGET", "") or {}
local REPEAT = math.max(1, tonumber(os.getenv("REPEAT")) or 1)
local ITIN = os.getenv("ITIN") ~= "0" and os.getenv("ITIN") ~= ""
local DUMP = os.getenv("DUMP") and os.getenv("DUMP") ~= "" and os.getenv("DUMP") ~= "0"

-- XP earned in the first `limit` seconds of a plan: its steps in order (the zone switch included in
-- their times), the step under way when time runs out counting its share; nothing after the route's end.
local function xpWithin(plan, limit)
    if not plan then return 0 end
    local prevT, prevXP = 0, 0
    for _, step in ipairs(plan.steps) do
        if step.t >= limit then
            local span = step.t - prevT
            return prevXP + (span > 0 and (limit - prevT) / span or 0) * (step.cumXP - prevXP)
        end
        prevT, prevXP = step.t, step.cumXP
    end
    return prevXP
end

-- salt: Search.SEED_SALT; budget: { [map] = work units } for one search per zone (rounds uncapped)
local function run(char, overrides, salt, budget)
    M.reset(); M.install()
    local ns = H.loadAddon()
    local level, faction, class, race, map, x, y = unpack(char)
    ns.Data.Init({ faction = faction, class = class, clientBuild = ns.data.meta.build }, M.questieDB(faction, class))
    ns.Data.BuildIndex()
    for _, o in ipairs(overrides) do ns[o[1]][o[2]] = o[3] end
    ns.Search.SEED_SALT = salt or 0
    local completed = {}
    for _, id in ipairs(ns.Data.QuestIds()) do
        local q = ns.Data.GetQuest(id)
        if q and q.level > 0 and q.level <= level - 4 then completed[id] = true end
    end
    local state = { level = level, faction = faction, class = class, raceId = race, map = map, x = x / 100, y = y / 100,
        log = {}, completed = completed, capacity = 40, knownNodes = {} }
    for id, n in pairs(ns.data.world.travel.nodes) do
        if n[7] == "n" or n[7] == (faction == "Alliance" and "a" or "h") then state.knownNodes[id] = true end
    end
    local last, longest = os.clock(), 0
    state.checkpoint = function()
        local now = os.clock()
        if now - last > longest then longest = now - last end
        last = now
    end
    local origPlan
    if budget then -- Rank plans every zone through ns.Zones.PlanZone: hand each its own search budget
        origPlan = ns.Zones.PlanZone
        local plan = origPlan
        ns.Zones.PlanZone = function(zone, ctx, ...)
            local was, wasWork = ctx.searchRounds, ctx.searchWork
            if budget[zone] then ctx.searchRounds, ctx.searchWork = 100000, budget[zone] end
            local result = plan(zone, ctx, ...)
            ctx.searchRounds, ctx.searchWork = was, wasWork
            return result
        end
    end
    local t0 = os.clock()
    last = t0
    local ctx = ns.Zones.Context(state)
    local bootMs, bootstrap = 0, ns.Zones.Bootstrap
    ns.Zones.Bootstrap = function(...) -- (the surplus goal's first pass: timed apart)
        local b0 = os.clock()
        local a, b = bootstrap(...)
        bootMs = bootMs + (os.clock() - b0) * 1000
        return a, b
    end
    local ranked = ns.Zones.Rank(ctx)
    ns.Zones.Bootstrap = bootstrap
    local out = { ms = (os.clock() - t0) * 1000, longest = longest * 1000, zones = {}, order = {}, work = 0, searchWork = {},
        bootWork = ctx.bootstrapWork or 0, bootMs = bootMs }
    out.work = out.bootWork
    if budget then ns.Zones.PlanZone = origPlan end -- (the itinerary below plans with its own settings)
    for _, z in ipairs(ranked) do
        out.zones[z.map] = { score = z.plan.score, full = z.plan.fullRate, quests = z.plan.quests, steps = #z.plan.steps }
        out.order[#out.order + 1] = z.map
        out.work = out.work + (z.plan.work or 0)
        if z.plan.search then out.searchWork[z.map] = z.plan.search.work end
    end
    -- the neutral measure: XP earned following the best-ranked zone's route (stopping mid-step pro rata)
    local top = ranked[1] and ranked[1].plan
    out.top = ranked[1] and ranked[1].map
    out.xp60, out.xp120 = xpWithin(top, 3600), xpWithin(top, 7200)
    if ITIN then
        -- (the work of every plan the itinerary makes: its later zones planned again, the quests taken along)
        local plan, itinWork = ns.Zones.PlanZone, 0
        ns.Zones.PlanZone = function(...)
            local p = plan(...)
            itinWork = itinWork + (p.work or 0)
            return p
        end
        local planSeam = ns.Zones.PlanSeam -- (the way across planned together: its search is itinerary work too)
        ns.Zones.PlanSeam = function(...)
            local a, w = planSeam(...)
            itinWork = itinWork + (w or 0)
            return a, w
        end
        local t1 = os.clock()
        local it = ns.Zones.Itinerary(state, ctx, ranked)
        out.itinMs = (os.clock() - t1) * 1000
        ns.Zones.PlanZone, ns.Zones.PlanSeam = plan, planSeam
        out.itinXP = it and it.xp or 0
        out.itinWork = itinWork
        out.border = it and it.border
        out.seam, out.seamInfo = it and it.seam, it and it.seamInfo
        if DUMP and it then
            local maps, keys = {}, {}
            for i, seg in ipairs(it.segments) do maps[i], keys[i] = seg.map, seg.leaveKey or "-" end
            out.dumpItin = string.format("itinerary %s  leave %s  xp %.2f%s", table.concat(maps, ">"), table.concat(keys, " "), it.xp,
                it.border and ("  border " .. table.concat(it.border.ids, ",")) or "")
            if it.seam then
                out.dumpItin = out.dumpItin .. "  seam " .. table.concat(it.seam.keys, ",") .. " | " .. table.concat(it.seam.head, ",")
            end
        end
    end
    if DUMP then
        out.dump = {}
        for _, z in ipairs(ranked) do
            out.dump[#out.dump + 1] = string.format("zone %d  score %.2f  xp %.2f  seconds %.1f  %s", z.map, z.plan.score or 0,
                z.plan.xp or 0, z.plan.seconds or 0, table.concat(z.plan.order or {}, " "))
        end
    end
    return out
end

-- The minimum CPU time over REPEAT identical runs (scores and work are deterministic).
local function measured(char, overrides, salt, budget)
    local out = run(char, overrides, salt, budget)
    for _ = 2, REPEAT do
        local again = run(char, overrides, salt, budget)
        out.ms, out.longest = math.min(out.ms, again.ms), math.min(out.longest, again.longest)
        if out.itinMs then out.itinMs = math.min(out.itinMs, again.itinMs) end
    end
    return out
end

-- results[ci][i][si] = the plain run of config ci, character i, salt SALTS[si]
local results = {}
for ci, config in ipairs(CONFIGS) do
    results[ci] = {}
    for i, char in ipairs(CHARACTERS) do
        if not only or only == i then
            results[ci][i] = {}
            for si, salt in ipairs(SALTS) do
                -- without a search (the first config) the salt changes nothing: run it once
                results[ci][i][si] = (ci == 1 and si > 1) and results[ci][i][1] or measured(char, config[2], salt)
            end
        end
    end
end

-- budgeted[ci][bi][i][si]: every config but "old", with a search budget of BUDGETS[bi] x what base spent
local budgeted = {}
if #BUDGETS > 0 then
    for ci = 2, #CONFIGS do
        budgeted[ci] = {}
        for bi, mult in ipairs(BUDGETS) do
            budgeted[ci][bi] = {}
            for i, char in ipairs(CHARACTERS) do
                if not only or only == i then
                    budgeted[ci][bi][i] = {}
                    local baseRun = results[BASE][i][1]
                    local budget = {}
                    for map, w in pairs(baseRun.searchWork) do budget[map] = math.max(1, mult * w) end
                    for si, salt in ipairs(SALTS) do
                        budgeted[ci][bi][i][si] = measured(char, CONFIGS[ci][2], salt, budget)
                    end
                end
            end
        end
    end
end

local function pct(a, b) return b > 0 and (a / b - 1) * 100 or 0 end
local function sortedMaps(zones)
    local maps = {}
    for map in pairs(zones) do maps[#maps + 1] = map end
    table.sort(maps)
    return maps
end

-- One run against the "old" run of the same character: sum, count, best, worst, top-zone gain.
local function compare(base, res, verbose, name)
    local sum, n, best, worst = 0, 0, -1e9, 1e9
    for _, map in ipairs(sortedMaps(base.zones)) do
        local z, mine = base.zones[map], res.zones[map]
        if mine and z.score > 0 then
            local d = pct(mine.score, z.score)
            sum, n, best, worst = sum + d, n + 1, math.max(best, d), math.min(worst, d)
            if verbose then
                print(string.format("    map %5d  %-13s %7.0f XP/h (%+5.1f%%)  whole route %7.0f XP/h  %2d quests %3d steps",
                    map, name, mine.score, d, mine.full, mine.quests, mine.steps))
            end
        end
    end
    local top = pct(res.zones[res.order[1]] and res.zones[res.order[1]].score or 0, base.zones[base.order[1]] and base.zones[base.order[1]].score or 0)
    return sum, n, best, worst, top
end

local function mean(list)
    local s = 0
    for _, v in ipairs(list) do s = s + v end
    return #list > 0 and s / #list or 0
end
local function sem(list)
    if #list < 2 then return nil end
    local m, ss = mean(list), 0
    for _, v in ipairs(list) do ss = ss + (v - m) ^ 2 end
    return math.sqrt(ss / (#list - 1)) / math.sqrt(#list)
end

-- Per config: aggregates over characters (and per salt, for the standard error).
local totals = {}
local header = string.format("%-28s %-13s %8s %8s %8s %9s %9s %8s %8s %9s", "character", "settings", "best", "mean", "worst", "top zone", "CPU ms", "stall ms", "work k", "ms/kwork")
if ITIN then header = header .. string.format(" %9s %8s %10s", "itin XP", "itin ms", "itin work k") end
print(header)
-- ratio of CPU ms to work for base, per character: the calibration other configs are held to
local calibration = {}
for i in ipairs(CHARACTERS) do
    local b = results[BASE][i]
    if b and b[1].work > 0 then calibration[i] = b[1].ms / (b[1].work / 1000) end
end
for i, char in ipairs(CHARACTERS) do
    for ci, config in ipairs(CONFIGS) do
        local runs = results[ci][i]
        if runs then
            local bests, means, worsts, tops, mss, longs, works, itinXP, itinMs, itinWork = {}, {}, {}, {}, {}, {}, {}, {}, {}, {}
            for si = 1, #SALTS do
                local res = runs[si]
                local sum, n, best, worst, top = compare(results[1][i][1], res, os.getenv("VERBOSE") and si == 1, config[1])
                bests[si], means[si], worsts[si], tops[si] = best, n > 0 and sum / n or 0, worst, top
                mss[si], longs[si], works[si] = res.ms, res.longest, res.work
                itinXP[si], itinMs[si], itinWork[si] = res.itinXP or 0, res.itinMs or 0, res.itinWork or 0
                local t = totals[ci] or { sum = {}, n = {}, top = {}, chars = 0, ms = 0, longest = 0, worst = 1e9, work = 0, itinXP = 0, itinMs = 0, itinWork = 0 }
                totals[ci] = t
                t.sum[si], t.n[si], t.top[si] = (t.sum[si] or 0) + sum, (t.n[si] or 0) + n, (t.top[si] or 0) + top
                t.worst = math.min(t.worst, worst)
            end
            local t = totals[ci]
            t.chars, t.ms, t.longest = t.chars + 1, t.ms + mean(mss), math.max(t.longest, mean(longs))
            t.work, t.itinXP, t.itinMs = t.work + mean(works), t.itinXP + mean(itinXP), t.itinMs + mean(itinMs)
            t.itinWork = t.itinWork + mean(itinWork)
            local work = mean(works)
            local ratio = work > 0 and mean(mss) / (work / 1000) or 0
            local flag = (calibration[i] and ratio > 0 and math.abs(ratio / calibration[i] - 1) > 0.2) and "*" or " "
            local line = string.format("%-28s %-13s %+7.1f%% %+7.1f%% %+7.1f%% %+8.1f%% %9.0f %8.1f %8.0f %8.2f%s",
                ci == 1 and (char[1] .. " " .. char[8]) or "", config[1], mean(bests), mean(means), mean(worsts), mean(tops),
                mean(mss), mean(longs), work / 1000, ratio, flag)
            if ITIN then line = line .. string.format(" %9.0f %8.0f %10.0f", mean(itinXP), mean(itinMs), mean(itinWork) / 1000) end
            print(line)
            if DUMP then
                for si, salt in ipairs(SALTS) do
                    print(string.format("  DUMP %s %s salt %s", char[1] .. " " .. char[8], config[1], tostring(salt)))
                    for _, l in ipairs(runs[si].dump or {}) do print("    " .. l) end
                    if runs[si].dumpItin then print("    " .. runs[si].dumpItin) end
                end
            end
        end
    end
end

-- The headline: XP earned over the next two hours, judged PAIRED against base. For every
-- (character, salt) pair the % difference to base on the same character and salt; their mean, its
-- standard error (sd / sqrt(n)), the worst character (mean over salts of its % difference) and how
-- many characters are worse than -0.5%. Measure: the itinerary's 2-hour XP (ITIN=0: the top zone's
-- 120-minute XP instead); second line: the top zone's route in its first 120 minutes.
local function paired(ci, field)
    local all, perCharMean, worseThanHalf = {}, {}, 0
    local sumMine, sumBase = 0, 0
    for i in ipairs(CHARACTERS) do
        local runs = results[ci][i]
        if runs then
            local ds, mine, base = {}, {}, {}
            for si = 1, #SALTS do
                local a, b = runs[si][field] or 0, results[BASE][i][si][field] or 0
                mine[si], base[si] = a, b
                if b > 0 then ds[#ds + 1] = pct(a, b); all[#all + 1] = ds[#ds] end
            end
            sumMine, sumBase = sumMine + mean(mine), sumBase + mean(base)
            if #ds > 0 then
                perCharMean[#perCharMean + 1] = mean(ds)
                if mean(ds) < -0.5 then worseThanHalf = worseThanHalf + 1 end
            end
        end
    end
    local worst = 1e9
    for _, v in ipairs(perCharMean) do worst = math.min(worst, v) end
    return { xp = sumMine, vs = pct(sumMine, sumBase), mean = mean(all), se = sem(all) or 0, worst = worst < 1e9 and worst or 0,
        worse = worseThanHalf, n = #all }
end
local function verdict(p)
    if p.mean < -2 * p.se or p.worst < -2 then return "worse" end
    if p.mean > 2 * p.se and p.worst >= -1 then return "better" end
    return "no clear difference"
end
local MEASURE = ITIN and "itinerary" or "top zone 120 min"
print("")
print("HEADLINE: XP earned over the next 2 hours, paired against base (same character and salt); sum over characters, mean over salts")
print(string.format("%-13s %-17s %9s %8s %8s %7s %7s %6s  %8s %8s%s  %s", "settings", "measure", "XP", "vs base", "paired", "+-SE", "worst", "n<-.5", "work k", "CPU ms", ITIN and string.format(" %8s", "itin wk") or "", "verdict"))
local seen = {}
for ci, config in ipairs(CONFIGS) do
    if totals[ci] then
        local t = totals[ci]
        local p1, p2 = paired(ci, "itinXP"), paired(ci, "xp120")
        local judged = ITIN and p1 or p2
        local cost = string.format("%8.0f %8.0f", t.work / t.chars / 1000, t.ms / t.chars)
        if ITIN then cost = cost .. string.format(" %8.0f", t.itinWork / t.chars / 1000) end
        local v = ci == BASE and "(base)" or verdict(judged)
        if ITIN then
            print(string.format("%-13s %-17s %9.0f %+7.1f%% %+7.2f%% %7.2f %+6.1f%% %3d/%-2d %s  %s", config[1], "itinerary 2 h", p1.xp, p1.vs, p1.mean, p1.se, p1.worst, p1.worse, t.chars, cost, v))
            print(string.format("%-13s %-17s %9.0f %+7.1f%% %+7.2f%% %7.2f %+6.1f%% %3d/%-2d", "", "top zone 120 min", p2.xp, p2.vs, p2.mean, p2.se, p2.worst, p2.worse, t.chars))
        else
            print(string.format("%-13s %-17s %9.0f %+7.1f%% %+7.2f%% %7.2f %+6.1f%% %3d/%-2d %s  %s", config[1], "top zone 120 min", p2.xp, p2.vs, p2.mean, p2.se, p2.worst, p2.worse, t.chars, cost, v))
        end
    end
end
local nChars = totals[BASE] and totals[BASE].chars or #CHARACTERS
-- Quests taken along across a zone border (Zones.BORDER): in how many runs, how many, what they add, what they cost.
if ITIN then
    for ci, config in ipairs(CONFIGS) do
        local t = totals[ci]
        if t and ci ~= 1 then
            local runsN, took, quests, gainXP, gainBase = 0, 0, 0, 0, 0
            local workMine, workBase = 0, 0
            for i in ipairs(CHARACTERS) do
                for si = 1, #SALTS do
                    local r, b = results[ci][i] and results[ci][i][si], results[BASE][i] and results[BASE][i][si]
                    if r then
                        runsN = runsN + 1
                        workMine, workBase = workMine + (r.itinWork or 0), workBase + ((b and b.itinWork) or 0)
                        if r.border then
                            took, quests = took + 1, quests + #r.border.ids
                            gainXP, gainBase = gainXP + (r.border.gain or 0), gainBase + ((b and b.itinXP) or 0)
                        end
                    end
                end
            end
            print(string.format("BORDER %s: quests taken along in %d of %d runs (%.1f quests per such run, +%.0f XP = +%.1f%% when taken); itinerary planning work %.0f k per run (%+.0f%% vs base)",
                config[1], took, runsN, took > 0 and quests / took or 0, took > 0 and gainXP / took or 0,
                gainBase > 0 and gainXP / gainBase * 100 or 0, runsN > 0 and workMine / runsN / 1000 or 0,
                workBase > 0 and (workMine / workBase - 1) * 100 or 0))
        end
    end
end
-- The way across a zone border planned together (Zones.SEAM): where the gate was on, where it ran, where it was
-- taken, which sides moved, and what it cost.
if ITIN then
    for ci, config in ipairs(CONFIGS) do
        local t = totals[ci]
        if t and ci ~= 1 then
            local runsN, on, ran, taken, new, kept = 0, 0, 0, 0, 0, 0
            local off = { one = 0, dungeon = 0, empty = 0, far = 0, short = 0, apart = 0 }
            local sideA, sideB, both, outA, outB, added = 0, 0, 0, 0, 0, 0
            local legN, leg1, leg2, leaveN, leave1, leave2 = 0, 0, 0, 0, 0, 0
            local gainXP, gainBase = 0, 0
            local proxyN, proxyXP, planXP = 0, 0, 0
            local searchN, searchWork, workMine, workBase = 0, 0, 0, 0
            for i in ipairs(CHARACTERS) do
                for si = 1, #SALTS do
                    local r, b = results[ci][i] and results[ci][i][si], results[BASE][i] and results[BASE][i][si]
                    if r then
                        runsN = runsN + 1
                        workMine, workBase = workMine + (r.itinWork or 0), workBase + ((b and b.itinWork) or 0)
                        local info = r.seamInfo
                        if not info then
                            off.one = off.one + 1
                        elseif info.gated then
                            off[info.gated] = (off[info.gated] or 0) + 1
                        else
                            on = on + 1
                        end
                        if info and info.ran then
                            ran = ran + 1
                            searchN, searchWork = searchN + 1, searchWork + (info.work or 0)
                        end
                        if info and info.newXP and info.proxyBest and info.proxyStart then
                            proxyN = proxyN + 1
                            proxyXP, planXP = proxyXP + (info.proxyBest - info.proxyStart), planXP + (info.newXP - info.stitchedXP)
                        end
                        if r.seam and info then
                            taken = taken + 1
                            if info.won == "kept" then kept = kept + 1 else new = new + 1 end
                            if info.changedA then sideA = sideA + 1 end
                            if info.changedB then sideB = sideB + 1 end
                            if info.changedA and info.changedB then both = both + 1 end
                            outA, outB, added = outA + (info.deferredA or 0), outB + (info.deferredB or 0), added + (info.added or 0)
                            if info.legBefore and info.legAfter then legN, leg1, leg2 = legN + 1, leg1 + info.legBefore, leg2 + info.legAfter end
                            if info.leaveBefore and info.leaveAfter then
                                leaveN, leave1, leave2 = leaveN + 1, leave1 + info.leaveBefore, leave2 + info.leaveAfter
                            end
                            gainXP, gainBase = gainXP + (r.seam.gain or 0), gainBase + ((b and b.itinXP) or 0)
                        end
                    end
                end
            end
            print(string.format("SEAM %s: gate on in %d of %d runs (off: one zone %d, dungeon %d, empty %d, far %d, short %d, apart %d); searched in %d,",
                config[1], on, runsN, off.one, off.dungeon, off.empty, off.far, off.short, off.apart, ran))
            print(string.format("  taken in %d (new %d, kept %d); per taken run: first side changed %d, next side changed %d, both %d;",
                taken, new, kept, sideA, sideB, both))
            print(string.format("  quests left out A %d / B %d, added %d; leg across %.0f -> %.0f s; first zone left after %.0f -> %.0f s;",
                outA, outB, added, legN > 0 and leg1 / legN or 0, legN > 0 and leg2 / legN or 0,
                leaveN > 0 and leave1 / leaveN or 0, leaveN > 0 and leave2 / leaveN or 0))
            print(string.format("  +%.0f XP = +%.1f%% when taken; the stretch's own figure said %+.0f XP where a new way was judged, the plans gave %+.0f;",
                taken > 0 and gainXP / taken or 0, gainBase > 0 and gainXP / gainBase * 100 or 0,
                proxyN > 0 and proxyXP / proxyN or 0, proxyN > 0 and planXP / proxyN or 0))
            print(string.format("  search work %.0f k per run where it ran; itinerary work %+.0f%% vs base",
                searchN > 0 and searchWork / searchN / 1000 or 0, workBase > 0 and (workMine / workBase - 1) * 100 or 0))
        end
    end
end
print(string.format("(%d characters x %d salts = %d pairs per config; CPU is the minimum over REPEAT=%d runs on a possibly shared machine: indicative only; measure for the verdict: %s)",
    nChars, #SALTS, nChars * #SALTS, REPEAT, MEASURE))
print("")
print("SECONDARY: zone scores (best XP/h over at least an hour, per zone, against the unsearched plan)")
print("")
print(string.format("%-13s %12s %12s %12s %12s %10s %9s %9s%s", "settings", "mean zone", "worst zone", "top zone", "CPU ms/char", "stall ms", "work k/ch", "ms/kwork",
    (#SALTS > 1 and "   (mean zone: standard error)" or "") .. (REFERENCE and "   gap closed" or "")))
local function meanZone(t, si) return t.n[si] > 0 and t.sum[si] / t.n[si] or 0 end
local function overall(t)
    local per = {}
    for si = 1, #SALTS do per[si] = meanZone(t, si) end
    return mean(per), sem(per)
end
for ci, config in ipairs(CONFIGS) do
    local t = totals[ci]
    if t then
        local mz, se = overall(t)
        local tops = {}
        for si = 1, #SALTS do tops[si] = t.top[si] / t.chars end
        local ratio = t.work > 0 and t.ms / (t.work / 1000) or 0
        local line = string.format("%-13s %+11.1f%% %+11.1f%% %+11.1f%% %12.0f %10.1f %9.0f %9.2f", config[1], mz, t.worst, mean(tops),
            t.ms / t.chars, t.longest, t.work / t.chars / 1000, ratio)
        if se then line = line .. string.format("   +-%.2f", se) end
        if REFERENCE and totals[BASE] then
            local b, r = overall(totals[BASE]), overall(totals[REFERENCE])
            if ci ~= 1 and r ~= b then line = line .. string.format("   %+.0f%%", (mz - b) / (r - b) * 100) end
        end
        print(line)
    end
end

if #BUDGETS > 0 then
    print("")
    print("Per-zone search budget as a multiple of base's search work: mean zone % vs old (worst zone % in parentheses)")
    local line = string.format("%-13s", "settings")
    for _, mult in ipairs(BUDGETS) do line = line .. string.format(" %17s", "x" .. mult) end
    print(line)
    for ci = 2, #CONFIGS do
        line = string.format("%-13s", CONFIGS[ci][1])
        for bi in ipairs(BUDGETS) do
            local perSalt, worst = {}, 1e9
            for si = 1, #SALTS do
                local sum, n = 0, 0
                for i in ipairs(CHARACTERS) do
                    local res = budgeted[ci][bi][i] and budgeted[ci][bi][i][si]
                    if res then
                        local s, k, _, w = compare(results[1][i][1], res)
                        sum, n, worst = sum + s, n + k, math.min(worst, w)
                    end
                end
                perSalt[si] = n > 0 and sum / n or 0
            end
            line = line .. string.format(" %+8.1f%% (%+5.1f%%)", mean(perSalt), worst)
        end
        print(line)
    end
end

if os.getenv("VERBOSE") then
    print("per character, XP 60 / 120 / itinerary (mean over salts)")
    for i, char in ipairs(CHARACTERS) do
        for ci, config in ipairs(CONFIGS) do
            if results[ci][i] then
                print(string.format("  %-22s %-13s %8.0f %8.0f %8.0f", char[1] .. " " .. char[8]:sub(1, 16), config[1],
                    perChar(ci, "xp60")[i], perChar(ci, "xp120")[i], perChar(ci, "itinXP")[i]))
            end
        end
    end
end
