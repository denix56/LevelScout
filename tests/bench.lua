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
-- VERDICT per config versus base (on the itinerary; with ITIN=0 on the 120-minute XP). The decisive block is
-- "PAIRED BY CHARACTER": each character's mean difference over its salts, the mean of those, its standard error
-- from the character means, and the bar t x SE (Student t, C - 1 degrees of freedom; tests/benchstats.lua):
--   "identical"           every pair has the same XP (a pure speed-up)
--   "better"              the mean is above the bar and no character is harmed by more than 1%
--   "worse"               the mean is below minus the bar, or a character is harmed by more than 2%
--   "no clear difference" otherwise
-- (a character is harmed by h% when its mean is below -h and below 0 beyond its own noise; the rule of the
-- old headline, 2 SE on all pairs and a point rule per character, is printed as the last column and in the
-- HEADLINE block.) docs/planner.md, "How a change is judged": a change is kept on a "better" with SALTS="0 1 2 3 4".
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
--   CHARS=2       the held-out second set of eight characters; CHARS=all both sets (16)
--   CRN=1         common random numbers: every config's search, base included, draws round t's numbers
--                 from a sequence of its own (Search.STREAM = "rounds"); see the correlation line
--   SEQ=1         sequential: salts in steps until every config is settled; LOOKS="3" (salt counts to
--                 look at besides the last), SE_TARGET=0.2; SALTS defaults to "0 1 2 3 4 5" then
--   ALPHA=0.05    two-sided level of the verdict (shared out over the looks with SEQ=1)
--   POWER_DELTA=0.5   the difference in points the power line is worked out for (80% power)
--   RAW=file      every run's figures as tab-separated text (config, character, salt, XP, work, CPU)
--   RACE_DRY=1    what Zones.RACE would skip, from base's own runs (RACE_Q="0.2 0.3 0.5 0.75 1", RACE_KEEP)
--   HEARTH_READY=0   seconds until the hearthstone is ready at the start (state.hearth.ready; used with Planner.HEARTH)
--   HEARTH_CD=...    its cooldown in seconds (default: Planner.HEARTH_COOLDOWN)
--   BIND=town|capital|none   where it is bound: the hub of the character's side nearest to it (default), the side's
--        capital (the first hub of map 1453 / 1454), or nowhere (no state.hearth). Every config gets the same
--        state; the stone is used only where Planner.HEARTH is on, e.g. SET="hearth:Planner.HEARTH=true"
--   ARMS=1        per removal and regret strength (ranked zones' searches): rounds, outcomes, work, quests
--                 taken out (Search.ARM_STATS), and a prior to paste into Search.BANDIT_PRIORS
-- Columns: "work k" = thousand work units (plan.work, summed over zones, deterministic);
-- "ms/kwork" = CPU ms per thousand work units, starred when it differs from base by over 20%.
local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."
package.path = root .. "/tests/?.lua;" .. package.path
local BS = require("benchstats")
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
local SECOND = {
    { 10, "Alliance", "HUNTER", 3, 1426, 46.8, 52.4, "Dun Morogh, Kharanos" },
    { 18, "Alliance", "DRUID", 4, 1439, 37.0, 44.0, "Darkshore, Auberdine" },
    { 26, "Alliance", "PRIEST", 1, 1437, 10.0, 59.0, "Wetlands, Menethil" },
    { 38, "Alliance", "MAGE", 7, 1434, 27.0, 77.0, "Stranglethorn, Booty Bay" },
    { 9, "Horde", "WARRIOR", 6, 1412, 48.0, 59.0, "Mulgore, Bloodhoof" },
    { 17, "Horde", "ROGUE", 5, 1421, 45.0, 41.0, "Silverpine, Sepulcher" },
    { 29, "Horde", "HUNTER", 8, 1440, 73.0, 61.0, "Ashenvale, Splintertree" },
    { 40, "Horde", "SHAMAN", 2, 1434, 27.0, 77.0, "Stranglethorn, Booty Bay" },
}
if os.getenv("CHARS") == "2" then CHARACTERS = SECOND
elseif os.getenv("CHARS") == "all" then for _, c in ipairs(SECOND) do CHARACTERS[#CHARACTERS + 1] = c end end

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
local function flag(name) local v = os.getenv(name); return v ~= nil and v ~= "" and v ~= "0" end
local CRN, SEQ, RACE_DRY, ARMS = flag("CRN"), flag("SEQ"), flag("RACE_DRY"), flag("ARMS")
local ALPHA = tonumber(os.getenv("ALPHA")) or 0.05
local SE_TARGET = tonumber(os.getenv("SE_TARGET")) or 0.2
local POWER_DELTA = tonumber(os.getenv("POWER_DELTA")) or 0.5
local SALTS = numbers("SALTS", SEQ and "0 1 2 3 4 5" or "0")
local LOOKS = {}
if SEQ then
    local seenLook = {}
    for _, n in ipairs(numbers("LOOKS", "3")) do
        n = math.floor(n)
        if n >= 2 and n < #SALTS and not seenLook[n] then seenLook[n] = true; LOOKS[#LOOKS + 1] = n end
    end
    table.sort(LOOKS)
    LOOKS[#LOOKS + 1] = #SALTS
end
local BUDGETS = os.getenv("BUDGET") and numbers("BUDGET", "") or {}
local REPEAT = math.max(1, tonumber(os.getenv("REPEAT")) or 1)
local ITIN = os.getenv("ITIN") ~= "0" and os.getenv("ITIN") ~= ""
local DUMP = os.getenv("DUMP") and os.getenv("DUMP") ~= "" and os.getenv("DUMP") ~= "0"
local JUDGED = ITIN and "itinXP" or "xp120"
local HEARTH_READY = tonumber(os.getenv("HEARTH_READY")) or 0
local HEARTH_CD = tonumber(os.getenv("HEARTH_CD"))
local BIND = os.getenv("BIND")
if not BIND or BIND == "" then BIND = "town" end
assert(BIND == "town" or BIND == "capital" or BIND == "none", "BIND: town, capital or none")

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

local ARM_FIELDS = { "n", "best", "better", "kept", "rejected", "work", "picked" }
local function addArms(into, name, e)
    local t = into[name]
    if not t then t = {}; for _, f in ipairs(ARM_FIELDS) do t[f] = 0 end; into[name] = t end
    for _, f in ipairs(ARM_FIELDS) do t[f] = t[f] + (e[f] or 0) end
end

-- salt: Search.SEED_SALT; budget: { [map] = work units } for one search per zone (rounds uncapped)
local function run(char, overrides, salt, budget)
    M.reset(); M.install()
    local ns = H.loadAddon()
    local level, faction, class, race, map, x, y = unpack(char)
    ns.Data.Init({ faction = faction, class = class, clientBuild = ns.data.meta.build }, M.questieDB(faction, class))
    ns.Data.BuildIndex()
    if CRN then ns.Search.STREAM = "rounds" end
    if RACE_DRY then ns.Search.CURVE = true end
    for _, o in ipairs(overrides) do ns[o[1]][o[2]] = o[3] end
    ns.Search.SEED_SALT = salt or 0
    if ARMS then ns.Search.ARM_STATS = true end
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
    -- The hearthstone, bound as BIND says (the planner uses it only with Planner.HEARTH on).
    if BIND ~= "none" then
        ns.Geo.Init(ns.Data.World())
        local side = faction == "Alliance" and "a" or "h"
        local hub, hubMap
        if BIND == "capital" then
            hubMap = faction == "Alliance" and 1453 or 1454
            local info = ns.Zones.Info(hubMap, side)
            hub = info and info.hubs[1]
        else
            hubMap = map
            local info, here, bestD = ns.Zones.Info(map, side), ns.Geo.Loc(map, x, y), nil
            for _, h in ipairs(info and info.hubs or {}) do
                if h.side == side or h.side == "b" then
                    local d = ns.Geo.Dist(here, ns.Geo.Loc(map, h.x, h.y))
                    if d and (not bestD or d < bestD) then hub, bestD = h, d end
                end
            end
        end
        if hub then
            state.hearth = { name = hub.name, map = hubMap, x = hub.x / 100, y = hub.y / 100, ready = HEARTH_READY, cd = HEARTH_CD }
        end
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
        local hn, hs = ns.Zones.HearthUses(z.plan)
        out.hearthN, out.hearthSaved = (out.hearthN or 0) + hn, (out.hearthSaved or 0) + hs
        if z.plan.search then out.searchWork[z.map] = z.plan.search.work end
    end
    if ARMS then
        out.arms = {}
        for _, z in ipairs(ranked) do
            local a = z.plan.search and z.plan.search.arms
            if a then
                for name, e in pairs(a.destroy) do addArms(out.arms, name, e) end
                for i, e in pairs(a.regret) do addArms(out.arms, "regret #" .. i, e) end
            end
        end
    end
    if RACE_DRY then
        out.race = { K = ns.Zones.RACE_KEEP or ns.Zones.ITINERARY_ZONES, rankWork = 0, zones = {} }
        for _, z in ipairs(ranked) do
            local p = z.plan
            out.race.rankWork = out.race.rankWork + (p.work or 0)
            out.race.zones[#out.race.zones + 1] = { map = z.map, score = p.score, plain = p.plainScore,
                spent = p.searchSpent or 0, steps = #p.steps, keep = (z.map == state.map or z.forced) and true or false,
                curve = p.search and p.search.curve or nil }
        end
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
        out.itinHearthN, out.itinHearthSaved = 0, 0
        for _, seg in ipairs(it and it.segments or {}) do
            local hn, hs = ns.Zones.HearthUses(seg.plan, seg.leave or seg.last)
            out.itinHearthN, out.itinHearthSaved = out.itinHearthN + hn, out.itinHearthSaved + hs
        end
        out.seam, out.seamInfo = it and it.seam, it and it.seamInfo
        if DUMP and it then
            local maps, keys = {}, {}
            for i, seg in ipairs(it.segments) do maps[i], keys[i] = seg.map, seg.leaveKey or "-" end
            out.dumpItin = string.format("itinerary %s  leave %s  xp %.2f%s", table.concat(maps, ">"), table.concat(keys, " "), it.xp,
                it.border and ("  border " .. table.concat(it.border.ids, ",")) or "")
            if it.seam then
                out.dumpItin = out.dumpItin .. "  seam " .. table.concat(it.seam.keys, ",") .. " | " .. table.concat(it.seam.head, ",")
            end
            if out.itinHearthN > 0 then out.dumpItin = out.dumpItin .. string.format("  hearth %d/%.0f", out.itinHearthN, out.itinHearthSaved) end
        end
    end
    if DUMP then
        out.dump = {}
        for _, z in ipairs(ranked) do
            local hn, hs = ns.Zones.HearthUses(z.plan)
            out.dump[#out.dump + 1] = string.format("zone %d  score %.2f  xp %.2f  seconds %.1f  %s%s", z.map, z.plan.score or 0,
                z.plan.xp or 0, z.plan.seconds or 0, table.concat(z.plan.order or {}, " "),
                hn > 0 and string.format("  hearth %d/%.0f", hn, hs) or "")
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
-- Running order does not matter: every run reloads the addon.
local results = {}
for ci in ipairs(CONFIGS) do
    results[ci] = {}
    for i in ipairs(CHARACTERS) do if not only or only == i then results[ci][i] = {} end end
end
local function runSalts(from, to)
    for si = from, to do
        for ci, config in ipairs(CONFIGS) do
            for i, char in ipairs(CHARACTERS) do
                local runs = results[ci][i]
                if runs then
                    -- without a search (the first config) the salt changes nothing: run it once
                    runs[si] = (ci == 1 and si > 1) and runs[1] or measured(char, config[2], SALTS[si])
                end
            end
        end
    end
end
-- The paired differences to base of config ci on `field`, clustered by character, over the first nSalts
-- salts (looks = how many looks the level is shared out over). See tests/benchstats.lua.
local function clusteredFor(ci, field, nSalts, looks)
    local chars = {}
    for i, char in ipairs(CHARACTERS) do
        local runs, base = results[ci][i], results[BASE][i]
        if runs and base then
            local ch = { label = char[1] .. " " .. char[8], n = nSalts, a = {}, b = {} }
            for si = 1, nSalts do
                if runs[si] and base[si] then ch.a[si], ch.b[si] = runs[si][field] or 0, base[si][field] or 0 end
            end
            chars[#chars + 1] = ch
        end
    end
    return BS.clustered(chars, { alpha = ALPHA, looks = looks or 1 })
end
local SEQ_RESULT = {} -- [ci] = { verdict, salts, look, reason }
if SEQ then
    local K, done = #LOOKS, 0
    for k, n in ipairs(LOOKS) do
        runSalts(done + 1, n); done = n
        print(string.format("SEQUENTIAL: look %d of %d after %d salts (each look at alpha %.4g: bar = t(%d df) x SE; settled: better, worse, identical or SE <= %.2f)",
            k, K, n, ALPHA / K, math.max(1, #CHARACTERS - 1), SE_TARGET))
        local open = 0
        for ci, config in ipairs(CONFIGS) do
            if ci ~= BASE and not SEQ_RESULT[ci] then
                local st = clusteredFor(ci, JUDGED, n, K)
                local v, reason = BS.verdict(st), nil
                if v == "better" or v == "worse" or v == "identical" then reason = "settled: " .. v
                elseif st.se and st.se <= SE_TARGET then v, reason = "no clear difference", string.format("settled: SE under %.2f", SE_TARGET)
                elseif k == K then reason = "last look: " .. v end
                print(string.format("  %-13s %+7.2f%% +-%5.2f bar %5.2f  %s", config[1], st.mean or 0, st.se or 0, st.bar or 0, reason or "open"))
                if reason then SEQ_RESULT[ci] = { verdict = v, salts = n, look = k, reason = reason } else open = open + 1 end
            end
        end
        if open == 0 then
            for si = #SALTS, n + 1, -1 do SALTS[si] = nil end -- (every table below covers the salts run)
            print(string.format("SEQUENTIAL: stopped after look %d of %d (%d salts)%s", k, K, n, k < K and ": every config settled" or ""))
            break
        end
    end
else
    runSalts(1, #SALTS)
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
-- The hearthstone (Planner.HEARTH): in how many itineraries it is used, how often, the seconds it saves.
if ITIN then
    for ci, config in ipairs(CONFIGS) do
        local t = totals[ci]
        if t and ci ~= 1 then
            local runsN, used, uses, saved, rankedN, rankedSaved = 0, 0, 0, 0, 0, 0
            for i in ipairs(CHARACTERS) do
                for si = 1, #SALTS do
                    local r = results[ci][i] and results[ci][i][si]
                    if r then
                        runsN = runsN + 1
                        if (r.itinHearthN or 0) > 0 then used = used + 1 end
                        uses, saved = uses + (r.itinHearthN or 0), saved + (r.itinHearthSaved or 0)
                        rankedN, rankedSaved = rankedN + (r.hearthN or 0), rankedSaved + (r.hearthSaved or 0)
                    end
                end
            end
            if runsN > 0 and rankedN + uses > 0 then
                print(string.format("HEARTH %s: the stone used in %d of %d runs' itineraries (%.2f uses, %.0f s saved per run); ranked plans %.1f uses per run (%.0f s)",
                    config[1], used, runsN, uses / runsN, saved / runsN, rankedN / runsN, rankedSaved / runsN))
            end
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
print(string.format("PAIRED BY CHARACTER (decides): each character's mean %% difference to base over its salts; the mean of those, its SE from the character means, bar = t x SE (two-sided %.3g%s)",
    ALPHA, SEQ and string.format(", shared over %d looks", #LOOKS) or ""))
print(string.format("%-13s %-17s %8s %6s %6s %7s %7s %9s  %-26s %s", "settings", "measure", "mean", "+-SE", "bar", "worst", "harmed", "same", "verdict", "old rule"))
local function row(name, measure, st, v, old)
    return string.format("%-13s %-17s %+7.2f%% %6.2f %6.2f %+6.1f%% %3d/%-3d %4d/%-4d  %-26s %s", name, measure,
        st.mean or 0, st.se or 0, st.bar or 0, st.worst or 0, st.harmed1, st.C, st.same, st.pairs, v, old)
end
local LABEL = ITIN and "itinerary" or "top zone 120 min"
for ci, config in ipairs(CONFIGS) do
    if totals[ci] and ci ~= BASE then
        local st = clusteredFor(ci, JUDGED, #SALTS, SEQ and #LOOKS or 1)
        local v = BS.verdict(st)
        if SEQ and SEQ_RESULT[ci] then v = SEQ_RESULT[ci].verdict .. " @" .. SEQ_RESULT[ci].salts end
        print(row(config[1], LABEL, st, v, verdict(paired(ci, JUDGED))))
        local pad = string.rep(" ", 13)
        if st.se then
            local Snow = st.pairs / st.C
            print(string.format("%s   variance of the mean: characters %.3f + salts %.3f (SE %.2f); x2 salts: SE %.2f, x2 characters: SE %.2f",
                pad, st.partChar, st.partSalt, math.sqrt(st.partChar + st.partSalt), BS.project(st, st.C, 2 * Snow), BS.project(st, 2 * st.C, Snow)))
            if st.sdA then
                print(string.format("%s   salt noise within a character: base %.2f%%, this %.2f%%, difference %.2f%%, correlation %s",
                    pad, st.sdB, st.sdA, st.sdD, st.rho and string.format("%+.2f", st.rho) or "-"))
            end
            if st.s2c > 0 or st.s2s > 0 then
                local nd = BS.need(st, POWER_DELTA, 0.8, ALPHA)
                local salts = nd.salts and string.format("%d salts (%d pairs)", nd.salts, nd.salts * st.C)
                    or string.format("not reachable (the character part alone gives SE %.2f)", math.sqrt(st.partChar))
                print(string.format("%s   to detect %.2f points at 80%% power: SE <= %.2f; with %d characters: %s; with %d salts: %s characters; salts unlimited: %s characters",
                    pad, POWER_DELTA, nd.se, st.C, salts, math.floor(Snow + 0.5),
                    nd.chars and tostring(nd.chars) or ">10000", nd.charsUnlimited and tostring(nd.charsUnlimited) or ">10000"))
            end
        elseif st.C < 2 then
            print(pad .. "   (one character: no standard error)")
        end
        if ITIN then
            local s2 = clusteredFor(ci, "xp120", #SALTS, SEQ and #LOOKS or 1)
            print(row("", "top zone 120 min", s2, "-", "-"))
        end
    end
end
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

if ARMS then
    print("")
    print("ARMS: per removal and regret strength, over the ranked zones' searches of every character and salt (rounds; how they ended; work per round; quests taken out per round)")
    for ci, config in ipairs(CONFIGS) do
        local sum, any = {}, false
        for i in ipairs(CHARACTERS) do
            local runs = results[ci][i]
            if runs then
                for si = 1, #SALTS do
                    local a = ci > 1 and runs[si].arms
                    if a then
                        for name, e in pairs(a) do addArms(sum, name, e); any = true end
                    end
                end
            end
        end
        if any then
            local names = {}
            for name in pairs(sum) do names[#names + 1] = name end
            table.sort(names)
            print(string.format("%-13s %-26s %7s %6s %7s %6s %9s %8s %10s %8s", config[1], "arm", "rounds", "best%", "better%", "kept%", "rejected%", "success%", "work/round", "out/rnd"))
            local function line(name)
                local e = sum[name]
                if e.n == 0 then return end
                print(string.format("%-13s %-26s %7d %5.1f%% %6.1f%% %5.1f%% %8.1f%% %7.1f%% %10.0f %8.2f", "", name, e.n,
                    100 * e.best / e.n, 100 * e.better / e.n, 100 * e.kept / e.n, 100 * e.rejected / e.n,
                    100 * (e.best + e.better) / e.n, e.work / e.n, e.picked / e.n))
            end
            local priors, regrets = {}, {}
            for _, name in ipairs(names) do
                line(name)
                local i = name:match("^regret #(%d+)$")
                local e = sum[name]
                if e.n > 0 then
                    local p = (e.best + e.better) / e.n
                    local text = string.format("{ s = %.2f, f = %.2f, w = %.0f, wn = 4 }", 4 * p, 4 * (1 - p), 4 * e.work / e.n)
                    if i then regrets[#regrets + 1] = { tonumber(i), text }
                    else priors[#priors + 1] = string.format("[%q] = %s", name, text) end
                end
            end
            table.sort(regrets, function(a, b) return a[1] < b[1] end)
            local rg = {}
            for _, x in ipairs(regrets) do rg[#rg + 1] = string.format("[%d] = %s", x[1], x[2]) end
            print(string.format("%-13s Search.BANDIT_PRIORS = { destroy = { %s }, regret = { %s } }", "", table.concat(priors, ", "), table.concat(rg, ", ")))
        end
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

if RACE_DRY then
    -- Mirrors Zones.RaceSearch's rule: zones in base's ranked order; returns the skipped set, the work it
    -- saved and the zones skipped although they ended in the top K.
    local function raceSim(zones, q, K)
        local lb, pending = {}, {}
        for _, z in ipairs(zones) do
            lb[z] = z.plain or z.score
            if z.plain then pending[#pending + 1] = z end
        end
        table.sort(pending, function(a, b)
            if a.keep ~= b.keep then return a.keep end
            if a.plain ~= b.plain then return a.plain > b.plain end
            return a.map < b.map
        end)
        local skipped, saved = {}, 0
        for _, z in ipairs(pending) do
            local others = {}
            for _, o in ipairs(zones) do if o ~= z and o.steps > 0 then others[#others + 1] = lb[o] end end
            table.sort(others, function(a, b) return a > b end)
            local kth = others[K] or 0
            if not z.keep and z.plain > 0 and z.plain * (1 + q) < kth then
                skipped[z], saved, lb[z] = true, saved + z.spent, z.plain
            else
                lb[z] = z.score
            end
        end
        local wrong, rank = {}, 0
        for _, z in ipairs(zones) do
            if z.steps > 0 then rank = rank + 1 end
            if skipped[z] and z.steps > 0 and rank <= K then wrong[#wrong + 1] = z end
        end
        return skipped, saved, wrong
    end
    -- the runs of base: { label, salt, race }
    local runsOfBase = {}
    for i, char in ipairs(CHARACTERS) do
        local runs = results[BASE][i]
        if runs then
            for si = 1, #SALTS do
                if runs[si] and runs[si].race then
                    runsOfBase[#runsOfBase + 1] = { label = char[1] .. " " .. char[8], salt = SALTS[si], race = runs[si].race }
                end
            end
        end
    end
    local nRuns = #runsOfBase
    local K = tonumber(os.getenv("RACE_KEEP")) or (nRuns > 0 and runsOfBase[1].race.K) or 5
    local rankWork = 0
    for _, run_ in ipairs(runsOfBase) do rankWork = rankWork + run_.race.rankWork end
    print("")
    print(string.format("RACING, DRY RUN (Zones.RACE, from base's runs, nothing planned again): a zone is not searched when its unsearched score x (1 + q) is below the %d-th best score known of the others; 'oracle' skips every searched zone outside base's top %d", K, K))
    -- the gain of the search over the unsearched plan, and the best worth still to come after r rounds
    local gains, worthGains, RS = {}, {}, { 0, 10, 20, 30, 60, 90 }
    for _, r in ipairs(RS) do worthGains[r] = {} end
    for _, run_ in ipairs(runsOfBase) do
        for _, z in ipairs(run_.race.zones) do
            if z.plain and z.plain > 0 then
                gains[#gains + 1] = { (z.score / z.plain - 1) * 100, run_.label, run_.salt, z.map }
            end
            local c = z.curve
            if c and #c >= 1 then
                for _, r in ipairs(RS) do
                    if r <= #c and c[r] and c[r] > 0 then worthGains[r][#worthGains[r] + 1] = (c[#c] / c[r] - 1) * 100 end
                end
            end
        end
    end
    table.sort(gains, function(a, b) return a[1] < b[1] end)
    if #gains > 0 then
        local values = {}
        for j, g in ipairs(gains) do values[j] = g[1] end
        local top = gains[#gains]
        print(string.format("gain of the search over the unsearched plan (final / unsearched - 1), %d searched zones: p50 %+.1f%%  p90 %+.1f%%  p95 %+.1f%%  p99 %+.1f%%  max %+.1f%% (%s, salt %s, map %d)",
            #gains, BS.quantile(values, 0.5), BS.quantile(values, 0.9), BS.quantile(values, 0.95), BS.quantile(values, 0.99), top[1], top[2], tostring(top[3]), top[4]))
    else
        print("no searched zones (RACE_DRY needs plan.plainScore: a search of at least one round)")
    end
    print("the search's best worth still to come after r rounds (final best worth / best after r rounds - 1):")
    for _, r in ipairs(RS) do
        local list = worthGains[r]
        if #list > 0 then
            table.sort(list)
            print(string.format("  r = %-3d %5d zones   p50 %+.1f%%  p90 %+.1f%%  p99 %+.1f%%  max %+.1f%%", r, #list,
                BS.quantile(list, 0.5), BS.quantile(list, 0.9), BS.quantile(list, 0.99), list[#list]))
        end
    end
    print(string.format("%-8s %13s %11s %14s %11s  %s", "q", "skipped", "per ranking", "saved k/rank", "of ranking", "wrongly skipped (in base's top K)"))
    local function example(run_, z) return string.format("%s s%s map %d", run_.label, tostring(run_.salt), z.map) end
    for _, q in ipairs(numbers("RACE_Q", "0.2 0.3 0.5 0.75 1")) do
        local skipped, searched, saved, nWrong, examples = 0, 0, 0, 0, {}
        for _, run_ in ipairs(runsOfBase) do
            local set, got, wrong = raceSim(run_.race.zones, q, K)
            for _, z in ipairs(run_.race.zones) do
                if z.plain then searched = searched + 1 end
                if set[z] then skipped = skipped + 1 end
            end
            saved, nWrong = saved + got, nWrong + #wrong
            for _, z in ipairs(wrong) do if #examples < 3 then examples[#examples + 1] = example(run_, z) end end
        end
        print(string.format("%-8s %6d/%-6d %11.2f %14.0f %10.1f%%  %d%s", tostring(q), skipped, searched, nRuns > 0 and skipped / nRuns or 0,
            nRuns > 0 and saved / nRuns / 1000 or 0, rankWork > 0 and 100 * saved / rankWork or 0, nWrong,
            #examples > 0 and (": " .. table.concat(examples, "; ")) or ""))
    end
    do -- the oracle: every searched zone outside base's top K
        local skipped, searched, saved = 0, 0, 0
        for _, run_ in ipairs(runsOfBase) do
            local rank = 0
            for _, z in ipairs(run_.race.zones) do
                if z.steps > 0 then rank = rank + 1 end
                if z.plain then
                    searched = searched + 1
                    if not z.keep and rank > K then skipped, saved = skipped + 1, saved + z.spent end
                end
            end
        end
        print(string.format("%-8s %6d/%-6d %11.2f %14.0f %10.1f%%  %d", "oracle", skipped, searched, nRuns > 0 and skipped / nRuns or 0,
            nRuns > 0 and saved / nRuns / 1000 or 0, rankWork > 0 and 100 * saved / rankWork or 0, 0))
    end
end

local function perChar(ci, field)
    local out = {}
    for i in ipairs(CHARACTERS) do
        local runs = results[ci][i]
        if runs then
            local s = 0
            for si = 1, #SALTS do s = s + (runs[si][field] or 0) end
            out[i] = s / #SALTS
        end
    end
    return out
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

local RAW = os.getenv("RAW")
if RAW and RAW ~= "" then
    local f = assert(io.open(RAW, "w"))
    f:write("config\tchar\tlabel\tsalt\titinXP\txp120\txp60\twork\tms\n")
    for ci, config in ipairs(CONFIGS) do
        for i, char in ipairs(CHARACTERS) do
            local runs = results[ci][i]
            if runs then
                for si = 1, #SALTS do
                    local r = runs[si]
                    f:write(string.format("%s\t%d\t%s\t%s\t%.3f\t%.3f\t%.3f\t%.0f\t%.1f\n", config[1], i, char[1] .. " " .. char[8],
                        tostring(SALTS[si]), r.itinXP or 0, r.xp120 or 0, r.xp60 or 0, r.work or 0, r.ms or 0))
                end
            end
        end
    end
    f:close()
    print("per-run figures written to " .. RAW)
end
