-- core/Zones.lua: the character's planning context, which zones to consider, how they rank,
-- and when to move on. Pure Lua: reads ns.Data and the other core modules only.

local _, ns = ...

local Zones = {}
ns.Zones = Zones

local Geo, Cost, Travel, Planner = ns.Geo, ns.Cost, ns.Travel, ns.Planner

Zones.SHORTLIST = 6
Zones.DUNGEON_SHORTLIST = 3
Zones.DUNGEON_FROM = 0.25   -- a dungeon is offered from this far into its suggested level range
Zones.MOVE_ON_ENTER = 1.20  -- suggest another zone when it beats this one by 20%...
Zones.MOVE_ON_EXIT = 1.05   -- ...and keep suggesting until the lead falls under 5%
Zones.KEEP_ORDER = 1.05     -- a new order replaces the shown one only when 5% better

-- Plan memory (see ns.Memory)
Zones.REUSE = false         -- hand out another zone's plan again at the next ranking while it still stands
Zones.REUSE_MAX_AGE = 300   -- seconds: a plan is never reused for longer than this
Zones.ITINERARY_WARM = true  -- the itinerary plans its later zones again starting from their ranked plans
Zones.WARM_SHOWN = false   -- a quick re-plan of the shown zone starts from its last plan (measured worse: off)
Zones.REFRESH_EVERY = 4     -- a zone's search starts from its last plan this many times in a row, then from scratch

--- The planning context from plain facts about the character.
--- state = { level, restedPool (rested XP left, as the game reports it; or rested = true for
---           "always rested"), xpBonus (0.05 = +5% XP from buffs),
---           xp, xpMax (the game's figures for the current level; optional), maxLevel (optional),
---           faction ("Alliance"|"Horde"), raceId, class, map, x, y (0-1),
---           log = { quest log entries from ns.Game.GetQuestLog }, completed = { [id] = true },
---           altRate (XP per second the player can get elsewhere; the surplus goal's R. Optional: the
---           engine passes the last ranking's best score, else Zones.Rank works it out),
---           capacity, knownNodes = { [flightNodeId] = true }, ignored = { [id] = true },
---           groupSize (members including you; 1 or nil = solo),
---           routeElite (false: elite quests are listed, not routed),
---           partyOn = function(questId) -> how many other members are on the quest, or nil,
---           pace, drops, stepModel (what ns.Learn has saved for this character and account; optional),
---           speed (yards per second; optional: overrides the typical run speed as adjusted by
---           the travel speed learned in `pace`), tagOf (optional), checkpoint (optional),
---           memory (ns.Memory.New(), optional: plans are reused and searches start warm),
---           now (seconds, the memory's clock; optional) }
function Zones.Context(state)
    local world = ns.Data.World() or {}
    Geo.Init(world)
    -- players' typical pace for the level, adjusted to how this character plays
    local pace = ns.Learn.Pace(Cost.Pace(world, state.level), state.pace)
    -- on a mount, once the character has been seen riding (a speed given outright is the only speed)
    if not state.speed then pace.rm = ns.Learn.RideSpeed(state.pace, world.travel and world.travel.speeds and world.travel.speeds.ride) end
    local side = state.faction == "Alliance" and "a" or (state.faction == "Horde" and "h" or nil)
    local log, inLog, count = {}, {}, 0
    for _, entry in ipairs(state.log or {}) do
        log[entry.id], inLog[entry.id] = entry, true
        count = count + 1
    end
    local start = state.map and state.x and Geo.Loc(state.map, state.x * 100, state.y * 100) or nil
    return {
        level = state.level, pace = pace, side = side, drops = state.drops,
        -- one correction per data source of drop rates, from all our kills and drops
        dropBias = state.drops and ns.Learn.SourceBias(state.drops, ns.Data.GetDropRate) or nil,
        stepModel = state.stepModel,
        -- Rested: the pool is the XP still to be earned at double rate, so half of it is bonus.
        -- It is spent on kills in route order (quest rewards do not use it).
        restedBonus = state.rested == true and math.huge or (state.restedPool or 0) / 2,
        xpBonus = state.xpBonus or 0,
        -- XP still needed for each of the next level-ups: the route is valued level by level
        levelUps = Cost.LevelUps(state.level, state.xp, state.xpMax, ns.Planner.LEVELS_AHEAD, state.maxLevel),
        group = math.max(1, state.groupSize or 1),
        routeElite = state.routeElite ~= false, partyOn = state.partyOn,
        start = start, startMap = state.map,
        travel = Travel.New(world, { speed = state.speed or pace.r, ride = state.ride or pace.rm, side = side,
            knownNodes = state.knownNodes, tram = state.tram }),
        tram = state.tram, -- "on" | "off" | "auto" (nil): the Deeprun Tram (see Travel.New)
        log = log, logCount = count, capacity = state.capacity,
        bagQuests = state.bagQuests, -- { [questId] = itemId }: quests an item in the bags starts
        avail = { faction = state.faction, raceId = state.raceId, class = state.class,
            completed = state.completed or {}, inLog = inLog },
        ignored = state.ignored or {}, tagOf = state.tagOf, checkpoint = state.checkpoint,
        altRate = state.altRate, -- surplus goal: XP per second available elsewhere (see Zones.Rank)
        carried = state.carried, -- set by an itinerary: quests brought along from the zone before
        memory = state.memory, now = state.now, knownNodes = state.knownNodes, speed = state.speed,
        -- Optional: progress(stage, done, total, what) is told what the planner is doing
        -- ("zone" i of n with the map, "search" round of rounds, "order", "itinerary" part of
        -- parts). It only listens: plans are the same with and without it.
        progress = state.progress,
        trace = state.trace, -- a zone whose search is recorded for the debug view
    }
end

-- "continent|side|src|lo-hi|loA-hiA,loH-hiH|new quests|quests A,H|flight nodes|dungeons|hubs|subzones"
local function parseZone(rec, side)
    local f = {}
    for part in (rec .. "|"):gmatch("([^|]*)|") do f[#f + 1] = part end
    local lo, hi = (f[4] or ""):match("^(%d+)%-(%d+)$")
    local a, h = (f[5] or ""):match("^([^,]*),(.*)$")
    local own = side == "a" and a or (side == "h" and h or nil)
    local lo2, hi2 = (own or ""):match("^(%d+)%-(%d+)$")
    local hubs = {}
    for name, hubSide, x, y in (f[10] or ""):gmatch("([^~;]+)~(%a)~([%d%.]+)~([%d%.]+)") do
        hubs[#hubs + 1] = { name = name, side = hubSide, x = tonumber(x), y = tonumber(y) }
    end
    return { continent = tonumber(f[1]), side = f[2], src = f[3], lo = tonumber(lo2 or lo), hi = tonumber(hi2 or hi), hubs = hubs }
end

local zoneCache = {}
--- { continent, side ("A"|"H"|"C"|"B"), lo, hi, hubs = { {name, side, x, y}, ... } } or nil.
function Zones.Info(map, side)
    local key = map .. (side or "")
    if zoneCache[key] == nil then
        local world = ns.Data.World()
        local rec = world and world.zones and world.zones[map]
        zoneCache[key] = rec and parseZone(rec, side) or false
    end
    return zoneCache[key] or nil
end

function Zones.Reset() zoneCache, dungeonCache = {}, nil end

-- Where to start a zone when the character's own position is unknown or far away: its
-- busiest hub for this side.
local function entryPoint(map, side)
    local info = Zones.Info(map, side)
    for _, hub in ipairs(info and info.hubs or {}) do
        if hub.side == "b" or hub.side == side or not side then return Geo.Loc(map, hub.x, hub.y) end
    end
    return Geo.Loc(map, 50, 50)
end
Zones.EntryPoint = entryPoint

--- Zones worth planning: the right side and level, ordered by how many quests give XP now.
--- A zone whose suggested range starts above the character's level is not offered.
--- Always includes ctx.startMap and `always` (the active zone) when they have quests.
function Zones.Shortlist(ctx, always)
    local Data = ns.Data
    local world = Data.World() or {}
    local out, seen = {}, {}
    for map in pairs(world.zones or {}) do
        local info = Zones.Info(map, ctx.side)
        local sideOk = info and (info.side == "C" or info.side == "B"
            or (info.side == "A" and ctx.side == "a") or (info.side == "H" and ctx.side == "h"))
        local forced = map == ctx.startMap or map == always
        if info and info.lo and (forced or (sideOk and ctx.level >= info.lo and ctx.level <= info.hi + 2)) then
            local n = 0
            for i, e in ipairs(Data.QuestsInZone(map) or {}) do
                if ctx.checkpoint and i % 8 == 0 then ctx.checkpoint() end
                local q = Data.GetQuest(e.id)
                if q and not q.flags.dungeon and not q.flags.raid then
                    if ctx.log[e.id] then
                        n = n + 1
                    elseif q.minLevel <= ctx.level and (q.level <= 0 or q.level >= ctx.level - 6)
                        and not ns.Model.Unconfirmed(q) and Data.IsAvailable(e.id, ctx.avail) then
                        n = n + 1
                    end
                end
            end
            if n > 0 then out[#out + 1] = { map = map, quests = n, forced = forced, lo = info.lo, hi = info.hi } end
            seen[map] = true
            if ctx.checkpoint then ctx.checkpoint() end
        end
    end
    table.sort(out, function(a, b)
        if a.forced ~= b.forced then return a.forced end
        if a.quests ~= b.quests then return a.quests > b.quests end
        return a.map < b.map
    end)
    local forcedCount = 0
    for _, z in ipairs(out) do if z.forced then forcedCount = forcedCount + 1 end end
    for i = #out, math.max(Zones.SHORTLIST, forcedCount) + 1, -1 do out[i] = nil end
    return out
end

---------------------------------------------------------------------------------------------
-- Dungeons: planned like zones, under a negative id (-instanceId)
---------------------------------------------------------------------------------------------

local dungeonCache
local function dungeonTable()
    if dungeonCache then return dungeonCache end
    dungeonCache = {}
    local world = ns.Data.World() or {}
    for id, d in pairs(world.dungeons or {}) do
        local map, x, y = ns.Data.DecodeSpot((d.ent or ""):match("%S+") or "")
        if map then
            local quests, set, confirmed = {}, {}, {}
            for q in (d.quests or ""):gmatch("%d+") do quests[#quests + 1] = tonumber(q); set[tonumber(q)] = true end
            for q in (d.confirmed or ""):gmatch("%d+") do confirmed[tonumber(q)] = true end
            dungeonCache[-id] = { id = id, zone = -id, name = d.name, lo = d.lo, hi = d.hi, min = d.min, bosses = d.bosses,
                map = map, x = x, y = y, quests = quests, questSet = set, confirmed = confirmed }
        end
    end
    return dungeonCache
end

--- The dungeon planned under this zone id, or nil. { id, name, lo, hi, min, bosses, quests, ... }
function Zones.Dungeon(zone) return zone and zone < 0 and dungeonTable()[zone] or nil end

--- A name for a zone id when we have one ourselves (dungeons).
function Zones.Name(zone)
    local d = Zones.Dungeon(zone)
    return d and d.name or nil
end

-- The dungeon as the planner needs it for this character: where the door is, how long a run
-- is assumed to take and what its kills pay (elites, shared by five).
local function dungeonFor(d, ctx)
    local seconds, kills = Cost.DungeonRun(d.bosses)
    local mobLevel = math.floor((d.lo + d.hi) / 2)
    return { id = d.id, name = d.name, loc = Geo.Loc(d.map, d.x, d.y), quests = d.quests, questSet = d.questSet,
        confirmed = d.confirmed, seconds = seconds,
        xp = math.floor(kills * Cost.MobXP(ctx.level, mobLevel, false, Cost.DUNGEON_GROUP, true) * (1 + (ctx.xpBonus or 0)) + 0.5) }
end

--- The level a dungeon is offered from. The bottom of its suggested range is where a group can
--- just about enter, so it is a quarter of the way into the range (Zones.DUNGEON_FROM), never
--- under the entrance's minimum. A quest of the dungeon this character has still to do and that
--- asks for a higher level moves it up to that level (one run then takes every quest), unless
--- it asks for more than the top of the range.
function Zones.DungeonFrom(d, ctx)
    local from = d.lo + math.floor((d.hi - d.lo) * Zones.DUNGEON_FROM + 0.5)
    from = math.min(math.max(from, d.min or 0), math.max(d.hi, d.min or 0))
    local Data, avail = ns.Data, ctx and ctx.avail
    if not avail then return from end
    local completed = avail.completed or {}
    for _, id in ipairs(d.quests) do
        local q = Data.GetQuest(id)
        if q and q.minLevel > from and q.minLevel <= d.hi and not completed[id] and not ctx.log[id]
            and not (q.flags.repeatable or q.flags.daily or q.flags.weekly or q.flags.event)
            and not (ns.Model.Unconfirmed(q) and not d.confirmed[id]) then
            -- Open to this side, race and class; a quest that only waits for its lead-up counts.
            local open, why = Data.IsAvailable(id, avail)
            if open or (why and why:find("^prerequisite")) then from = q.minLevel end
        end
    end
    return from
end

--- Dungeons worth planning at this level: those with a quest in the log, or with quests still
--- to do. At most `max`, most quests first.
function Zones.DungeonShortlist(ctx, always, max)
    local Data = ns.Data
    local out = {}
    for zone, d in pairs(dungeonTable()) do
        local n, inLog = 0, 0
        for _, id in ipairs(d.quests) do
            local q = Data.GetQuest(id)
            if ctx.log[id] then
                n, inLog = n + 1, inLog + 1
            elseif q and not (ctx.avail.completed or {})[id] and q.minLevel <= ctx.level
                and (q.level <= 0 or q.level >= ctx.level - 6) then
                n = n + 1
            end
        end
        local fits = ctx.level <= d.hi + 2 and ctx.level >= Zones.DungeonFrom(d, ctx)
        local forced = zone == always
        if n > 0 and (fits or forced or inLog > 0) then
            out[#out + 1] = { map = zone, quests = n, forced = forced, lo = d.lo, hi = d.hi, dungeon = true, name = d.name }
        end
    end
    table.sort(out, function(a, b)
        if a.forced ~= b.forced then return a.forced end
        if a.quests ~= b.quests then return a.quests > b.quests end
        return a.map > b.map
    end)
    for i = #out, (max or Zones.DUNGEON_SHORTLIST) + 1, -1 do
        if not out[i].forced then table.remove(out, i) end
    end
    return out
end

--- Plan one zone from the character's position (or the zone's main hub when there is no
--- usable position). `seed` keeps a previous order.
--- opts = { warm = order of an earlier plan to start the search from (false: from scratch),
---          weights = that search's operator weights, readOnly = do not write the memory,
---          front = with a seed: stops to bring to the route's front (see Planner.Plan) }.
--- With ctx.memory and without opts.warm, the zone's last plan in the memory is the warm start.
function Zones.PlanZone(map, ctx, seed, from, opts)
    if from then
        -- plan as if leaving from `from` (see Zones.Rank), then put the real position back
        local start = ctx.start
        ctx.start = from
        local plan = Zones.PlanZone(map, ctx, seed, nil, opts)
        ctx.start = start
        return plan
    end
    opts = opts or {}
    local mem = ctx.memory
    local warm, weights = opts.warm, opts.weights
    if warm == nil and mem and not seed and Planner.WARM_START and not Zones.Dungeon(map) then
        warm, weights = ns.Memory.Seed(mem, map)
    end
    local plan = Zones.PlanOne(map, ctx, seed, warm or nil, weights, opts.front)
    if warm then plan.warmSeed, plan.warmWeights = warm, weights end -- (the debug view plans the same again)
    if mem and not seed and not opts.readOnly and not Zones.Dungeon(map) then
        ns.Memory.Remember(mem, map, plan, plan.search and plan.search.warm or false)
    end
    return plan
end

-- (PlanZone without the memory: from the position in ctx.start)
function Zones.PlanOne(map, ctx, seed, warm, weights, front)
    local dungeon = Zones.Dungeon(map)
    if dungeon then
        -- Travel to the door, the givers and the prerequisite quests is all on the clock, so
        -- there is no separate switch cost.
        local start = ctx.start
        ctx.dungeon = dungeonFor(dungeon, ctx)
        ctx.start = start or ctx.dungeon.loc
        ctx.near = ctx.dungeon.loc
        local plan = Planner.Plan(dungeon.map, ctx, { overhead = 0, seed = seed, front = front })
        ctx.dungeon, ctx.start, ctx.near = nil, start, nil
        plan.zone, plan.dungeon = map, dungeon.name
        return plan
    end
    local start, startMap = ctx.start, ctx.startMap
    local overhead = (map ~= startMap) and Planner.SWITCH_OVERHEAD or 0
    if not start then
        ctx.start = entryPoint(map, ctx.side)
    end
    ctx.near = Zones.EntryPoint(map, ctx.side)
    local plan = Planner.Plan(map, ctx, { overhead = overhead, seed = seed, warm = warm, weights = weights, front = front })
    ctx.start, ctx.near = start, nil
    return plan
end

local zoneAtCache = setmetatable({}, { __mode = "k" })

--- The zone a location is in, as a uiMap id: its own map when that is a zone or city of the
--- data. Spots recorded on a continent map (Eastern Kingdoms) belong to a zone under them; but
--- zone maps are rectangles and neighbours overlap (the north of Stranglethorn is inside
--- Westfall's rectangle), so the first of `prefer` (zone ids: the zone being planned, the one
--- we stand in) whose map contains the spot wins, and only then the smallest map that does.
--- In the game, Zones.ZoneResolver (set by the Engine: the game's own answer by the real zone
--- borders) is asked first; the rectangles are the fallback, and all there is in tests.
--- nil when none is known.
Zones.ZoneResolver = nil -- function(loc) -> zone uiMap id or nil
local resolvedCache = setmetatable({}, { __mode = "k" })
function Zones.ZoneAt(loc, prefer)
    if not loc then return nil end
    local world = ns.Data.World() or {}
    local zones = world.zones or {}
    if loc.map and zones[loc.map] then return loc.map end
    if Zones.ZoneResolver then
        local got = resolvedCache[loc]
        if got == nil then
            got = Zones.ZoneResolver(loc)
            if not (got and zones[got]) then got = false end
            resolvedCache[loc] = got
        end
        if got then return got end
    end
    -- the zones whose map contains the spot, smallest first (kept per location)
    local under = zoneAtCache[loc]
    if not under then
        under = {}
        if loc.c and loc.x and loc.y then
            for id, m in pairs(world.maps or {}) do
                if zones[id] and m.c == loc.c and m.w and m.h and m.w > 0 and m.h > 0 then
                    local mx, my = (m.l - loc.y) / m.w, (m.t - loc.x) / m.h
                    if mx >= 0 and mx <= 1 and my >= 0 and my <= 1 then under[#under + 1] = { id = id, area = m.w * m.h } end
                end
            end
            table.sort(under, function(a, b) if a.area ~= b.area then return a.area < b.area end return a.id < b.id end)
        end
        zoneAtCache[loc] = under
    end
    for _, want in ipairs(prefer or {}) do
        for _, z in ipairs(under) do if z.id == want then return want end end
    end
    return under[1] and under[1].id or nil
end

Zones.FLIGHT_DETOUR = 180 -- seconds: a flight point this little out of the way is worth unlocking
Zones.FLIGHT_SOON = 30    -- seconds: the first place in the route within this of the smallest detour is taken

--- Flight points of our side the character does not know yet that are close to the route:
--- { { id, name, loc, at, detour }, ... }, in route order. `at`: the stop comes before
--- plan.steps[at] (#steps + 1: after the last). `detour`: the extra seconds on foot, the
--- talk with the flight master included. A point is listed when the smallest detour anywhere
--- in the route is at most FLIGHT_DETOUR, at the first place that is within FLIGHT_SOON of
--- that (a route often passes a flight master several times: the sooner it is unlocked, the
--- sooner it can be used). `skip` = { [nodeId] = true }:
--- points the player does not want. Nothing is listed while no flight point is known at all
--- (the flight map has not been read yet: every point would look new).
function Zones.FlightStops(plan, ctx, skip)
    local out = {}
    local world = ns.Data.World() or {}
    local nodes = world.travel and world.travel.nodes
    local known, travel = ctx.knownNodes, ctx.travel
    if not nodes or not plan or not travel or not ctx.start or type(known) ~= "table" or not next(known) then return out end
    local points = { ctx.start }
    for i, step in ipairs(plan.steps) do points[i + 1] = step.loc or points[i] end
    for id, n in pairs(nodes) do
        if not known[id] and not (skip and skip[id]) and (n[7] == "n" or n[7] == ctx.side) and n[4] and n[5] and n[6] then
            local loc = { c = n[1], x = n[2], y = n[3], map = n[4], mx = n[5], my = n[6] }
            local best, detours = nil, {}
            for i = 1, #points do
                local prev, nxt = points[i], points[i + 1]
                local there = travel:Walk(prev, loc)
                if there and there <= Zones.FLIGHT_DETOUR then
                    local d = there
                    if nxt then
                        local on, direct = travel:Walk(loc, nxt), (travel:Seconds(prev, nxt))
                        d = on and (there + on - direct) or nil
                    end
                    detours[i] = d
                    if d and (not best or d < best) then best = d end
                end
            end
            if best and best + Travel.FLIGHT_OVERHEAD <= Zones.FLIGHT_DETOUR then
                for i = 1, #points do
                    local d = detours[i]
                    if d and d <= best + Zones.FLIGHT_SOON then
                        out[#out + 1] = { id = id, name = n[9] or "Flight master", loc = loc, at = i,
                            detour = math.max(0, d) + Travel.FLIGHT_OVERHEAD }
                        break
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        if a.detour ~= b.detour then return a.detour < b.detour end
        return a.id < b.id
    end)
    return out
end

--- Plan every shortlisted zone and rank them by score (XP per hour including the trip).
--- `always` is the zone being worked in (it is always planned, from the real position).
--- Returns { {map, plan, quests, lo, hi}, ... } best first.
function Zones.Rank(ctx, always)
    local ranked = {}
    local list = Zones.Shortlist(ctx, always)
    for _, z in ipairs(Zones.DungeonShortlist(ctx, always)) do list[#list + 1] = z end
    -- While we are inside the zone we are working in, every other zone is judged as if we left
    -- from that zone's main hub, not from the exact spot we stand on. Otherwise a neighbouring
    -- zone looks better each time a quest takes us towards the border, and worse again when we
    -- walk back.
    local home = always or ctx.startMap
    local hub
    if home and home == ctx.startMap and ctx.start and Zones.Info(home, ctx.side) then
        hub = entryPoint(home, ctx.side)
    end
    -- The surplus goal needs R, the rate to be had elsewhere: when nobody gave it, it is the best
    -- zone's score (today's, one-hour floor) from a first pass without the search.
    if Planner.GOAL == "surplus" and not ctx.altRate then
        ctx.altRate, ctx.bootstrapWork = Zones.Bootstrap(ctx, list, home, hub)
    end
    for i, z in ipairs(list) do
        if ctx.progress then ctx.progress("zone", i, #list, z.map) end
        local from = z.map ~= home and hub or nil
        local mem = ctx.memory
        local reused, why
        if mem and Zones.REUSE and z.map ~= home then reused, why = ns.Memory.Reusable(mem, ctx, z.map, from) end
        if reused then
            z.plan, z.reused = reused, true
        else
            z.why = why -- (why not: see Memory.Reusable)
            z.plan = Zones.PlanZone(z.map, ctx, nil, from)
            if mem and Zones.REUSE and z.map ~= home then ns.Memory.Store(mem, ctx, z.map, from, z.plan) end
        end
        if #z.plan.steps > 0 or z.forced then ranked[#ranked + 1] = z end
    end
    if Planner.GOAL == "surplus" then
        table.sort(ranked, function(a, b)
            if a.plan.value ~= b.plan.value then return a.plan.value > b.plan.value end
            -- (zones that are all worse than staying put tie on value: the better of them first)
            if a.plan.bestValue ~= b.plan.bestValue then return a.plan.bestValue > b.plan.bestValue end
            if a.plan.score ~= b.plan.score then return a.plan.score > b.plan.score end
            return a.map < b.map
        end)
    else
        table.sort(ranked, function(a, b)
            if a.plan.score ~= b.plan.score then return a.plan.score > b.plan.score end
            return a.map < b.map
        end)
    end
    return ranked
end

--- The alternative rate for the surplus goal (XP per second, before Planner.ALT_SHARE): every
--- zone in `list` planned once without the search under today's goal (the greedy route, tidied),
--- the best score (one-hour floor) of them. The memory is neither read nor written. The caller
--- (Zones.Rank) puts the result in ctx.altRate. Second result: the work units it took. Calls the checkpoint (never inside a pcall).
function Zones.Bootstrap(ctx, list, home, hub)
    local goal, rounds = ctx.goal, ctx.searchRounds
    ctx.goal, ctx.searchRounds = "rate", 0
    local best, work = 0, 0
    for _, z in ipairs(list) do
        local from = z.map ~= home and hub or nil
        local plan = Zones.PlanZone(z.map, ctx, nil, from, { readOnly = true, warm = false })
        if plan.score > best then best = plan.score end
        work = work + (plan.work or 0)
    end
    ctx.goal, ctx.searchRounds = goal, rounds
    return best / 3600, work
end

--- The rate a plan gets under today's goal (XP per hour, one-hour floor): the surplus goal's
--- plans keep it as `todayScore`, because their `score` is the rate up to the leaving point.
function Zones.AltScore(plan) return plan.todayScore or plan.score end

--- Should the shown order change? Only when the fresh plan is clearly better than continuing
--- the shown one, or the shown one has nothing left.
function Zones.PreferFresh(kept, fresh)
    if not kept or #kept.steps == 0 then return true end
    return fresh.score > kept.score * Zones.KEEP_ORDER
end

--- What leaving now for another zone is worth against staying, over the next hour:
--- 0.12 = 12% more XP, -0.08 = 8% less. nil when nothing is left here.
function Zones.Gain(active, other)
    local H = Planner.MIN_HORIZON
    local go = other.score / 3600 * H
    local stay = 0
    if active and #active.steps > 0 then
        local left = active.seconds or H
        if left >= H then
            stay = (active.rate or active.score or 0) / 3600 * H
        else
            stay = (active.xp or 0) + other.score / 3600 * (H - left)
        end
    end
    if stay <= 0 then return nil end
    return go / stay - 1
end

--- Move-on rule with hysteresis. `active` is the shown zone's plan, `ranked` from Zones.Rank,
--- `was` the previous answer, `itinerary` from Zones.Itinerary (optional).
--- Returns { suggest, map, gain, horizon }: gain 0.25 = 25% more XP by leaving now, over
--- `horizon` seconds (nil: the next hour).
---
--- With an itinerary made for the shown zone, see the first lines of the function. Without:
--- Both choices are valued over the same hour, so the answer does not swing when little is
--- left here:
---   leave now:  an hour of the other zone, trip included;
---   stay:       what is left here, then the other zone for the rest of the hour.
--- A short remainder therefore never triggers the suggestion by itself; a long stretch of
--- poor quests does.
function Zones.MoveOn(active, ranked, was, itinerary)
    -- With an itinerary for the shown zone, the banner says what the itinerary says: its first
    -- zone, when that is not the shown one. The gain is the itinerary's XP against the best
    -- itinerary that starts by staying here, over the itinerary's horizon.
    -- (Nothing left here, or an itinerary made while another zone was shown: the rule below.)
    if itinerary and itinerary.segments and itinerary.segments[1] and active and #active.steps > 0
        and itinerary.shown ~= nil and itinerary.shown == active.zone then
        local first = itinerary.segments[1].map
        if first == active.zone then return { suggest = false } end
        if not itinerary.here or itinerary.here <= 0 then
            return { suggest = true, map = first, gain = nil, horizon = itinerary.horizon }
        end
        local lead = itinerary.xp / itinerary.here
        local threshold = (was and was.suggest and was.map == first) and Zones.MOVE_ON_EXIT or Zones.MOVE_ON_ENTER
        return { suggest = lead > threshold, map = first, gain = lead - 1, horizon = itinerary.horizon }
    end
    local best
    for _, z in ipairs(ranked or {}) do
        if z.map ~= (active and active.zone) and #z.plan.steps > 0 then best = z; break end
    end
    if not best then return { suggest = false } end
    local gain = Zones.Gain(active, best.plan)
    if not gain then return { suggest = true, map = best.map, gain = nil } end
    local lead = gain + 1
    local threshold = (was and was.suggest and was.map == best.map) and Zones.MOVE_ON_EXIT or Zones.MOVE_ON_ENTER
    return { suggest = lead > threshold, map = best.map, gain = lead - 1 }
end

---------------------------------------------------------------------------------------------
-- Itinerary: the next hours across several zones
---------------------------------------------------------------------------------------------
-- Each zone's plan is a curve of XP against time. An itinerary strings up to three of them
-- together: follow the first zone's route up to some turn-in, travel, follow the next, and
-- so on until the horizon. Every order of the best few zones and every sensible moment to
-- leave is tried, and the one that earns most XP inside the horizon wins. The second zone
-- and third zone of the winner are then planned again as they will really be found: from
-- where the zone before is left, at the level reached by then, with its quests done and the
-- quests still in the log carried along.

Zones.HORIZON = 7200           -- seconds an itinerary covers
Zones.ITINERARY_ZONES = 5      -- best-ranked zones that may appear in it
Zones.ITINERARY_STOPS = 3      -- zones in a row at most
Zones.LEAVE_EVERY = 900        -- a zone may be left at the first turn-in after each quarter of an hour
Zones.MIN_STAY = 600           -- a zone is not visited for less than this (the zone on screen may be: we are in it already)
-- Search rounds when a later zone is planned again (nil: as many as a full plan). Measured on
-- six characters: 40, 60 or 80 rounds cut the time to a quarter or a third but gave two of them
-- a worse itinerary (5% and 11% less XP), so the full search is kept.
Zones.ITINERARY_ROUNDS = 40 -- with ITINERARY_WARM: the later zones start from their ranked plans
Zones.KEEP_ITINERARY = 1.05    -- a different order of zones replaces the shown one only when 5% better
Zones.SHORT_IN_HAND = true     -- the zone on screen may be left after less than MIN_STAY: we are in it already

-- Step indices after which a plan may be left: its best moment, the first turn-in after each
-- quarter of an hour, and its end.
local function leavePoints(plan)
    local steps, out, seen = plan.steps, {}, {}
    local function add(i)
        if i and i >= 1 and i <= #steps and not seen[i] then seen[i] = true; out[#out + 1] = i end
    end
    add(plan.peak)
    local mark = Zones.LEAVE_EVERY
    for i, s in ipairs(steps) do
        if s.kind == "turnin" and s.t >= mark then
            add(i)
            while mark <= s.t do mark = mark + Zones.LEAVE_EVERY end
        end
    end
    add(#steps)
    table.sort(out)
    return out
end

-- Seconds from arriving at a plan's first stop to finishing step i.
local function since(plan, i)
    local first = plan.steps[1]
    return plan.steps[i].t - first.t + first.seconds
end

-- Following a plan from `start` (the moment its first stop is reached) until the horizon:
-- XP earned, when it ends, and the last step finished. A camp being worked when time runs
-- out counts for the share done.
local function untilHorizon(plan, start, H)
    local steps, xp, last, finish = plan.steps, 0, 0, start
    for i = 1, #steps do
        local t = start + since(plan, i)
        if t > H then
            local s = steps[i]
            if s.kind == "work" and s.seconds > 0 then
                local done = (H - (t - s.seconds)) / s.seconds
                if done > 0 then xp = xp + s.xp * math.min(1, done) end
            end
            return xp, H, last
        end
        xp, last, finish = steps[i].cumXP, i, t
    end
    return xp, finish, last
end

-- The character as they will be after following `plan` up to step `leave`.
-- Quests turned in by then are done. Quests accepted (or already in the log) and not turned in
-- by then stay in the log, as the game would show them: complete when all their work in the
-- plan is behind us, else with the objectives done so far ticked off. The next zone's plan can
-- then turn them in or finish them where that happens on its map.
-- Returns the state and the ids of the quests carried on that this itinerary has put time into
-- (`carried` = those of the zones before, still in the log).
local function project(state, ctx, plan, leave, carried)
    local steps = plan.steps
    local at = steps[leave]
    local gained, rested, done = at.cumXP, 0, {}
    -- per quest: accepted by the leave step? which objectives are finished, which are left?
    local held, ids = {}, {}
    local function quest(id, info)
        local h = held[id]
        if not h then
            h = { id = id, name = info and info.name, level = info and info.level, finished = {}, left = 0, touched = false }
            held[id] = h
            ids[#ids + 1] = id
        end
        if info and not h.name then h.name, h.level = info.name, info.level end
        return h
    end
    for i, step in ipairs(steps) do
        local before = i <= leave
        if before then rested = rested + (step.restedXP or 0) end
        if step.kind == "turnin" then
            for _, q in ipairs(step.quests) do
                if before then done[q.id] = true else quest(q.id, q) end
            end
        elseif step.kind == "accept" then
            for _, q in ipairs(step.quests) do
                local h = quest(q.id, q)
                if before then h.accepted, h.touched = true, true end
            end
        else
            for _, q in ipairs(step.quests) do quest(q.id, q) end
            for _, part in ipairs(step.parts or {}) do
                local h = quest(part.quest)
                if before then
                    h.touched = true
                    if part.index then h.finished[part.index] = true end
                else
                    h.left = h.left + 1
                end
            end
        end
    end
    local ups, d = ctx.levelUps or {}, 0
    while ups[d + 1] and gained >= ups[d + 1] do d = d + 1 end
    local next_ = {}
    for k, v in pairs(state) do next_[k] = v end
    next_.level = state.level + d
    next_.xp = gained - (ups[d] or 0) + (d == 0 and (state.xp or 0) or 0)
    next_.xpMax = nil
    if d == 0 then next_.xpMax = state.xpMax elseif ups[d + 1] then next_.xpMax = ups[d + 1] - ups[d] end
    next_.restedPool = math.max(0, (state.restedPool or 0) - 2 * rested)
    next_.map, next_.x, next_.y = at.loc.map, (at.loc.mx or 50) / 100, (at.loc.my or 50) / 100
    next_.completed = {}
    for id in pairs(state.completed or {}) do next_.completed[id] = true end
    for id in pairs(done) do next_.completed[id] = true end
    -- The log: what was in it and is not turned in, then what the plan accepted and still holds.
    local out = {}
    for id in pairs(carried or {}) do
        if not done[id] then out[id] = true end
    end
    local function entryFor(h, old)
        local e = {}
        for k, v in pairs(old or {}) do e[k] = v end
        e.id, e.title, e.level = h.id, e.title or h.name, e.level or h.level
        e.isComplete = (old and old.isComplete) or h.left == 0
        e.isFailed = old and old.isFailed or false
        e.objectives = {}
        local n = #(old and old.objectives or {})
        for index in pairs(h.finished) do if index > n then n = index end end
        for i = 1, n do
            local o = old and old.objectives and old.objectives[i]
            if h.finished[i] then
                local need = o and o.need
                e.objectives[i] = { text = o and o.text, type = o and o.type, finished = true, have = need, need = need }
            else
                e.objectives[i] = o or { finished = false }
            end
        end
        return e
    end
    next_.log = {}
    local inLog = {}
    for _, entry in ipairs(state.log or {}) do
        if not done[entry.id] then
            local h = held[entry.id]
            inLog[entry.id] = true
            next_.log[#next_.log + 1] = (h and h.touched) and entryFor(h, entry) or entry
            if h and h.touched then out[entry.id] = true end
        end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local h = held[id]
        if h.accepted and not done[id] and not inLog[id] then
            next_.log[#next_.log + 1] = entryFor(h)
            out[id] = true
        end
    end
    next_.trace = nil
    next_.carried = out
    return next_, out
end
Zones.Project = project -- (for the tests)

--- The best way through the next hours. `state` and `ctx` as for Zones.Context / Zones.Rank,
--- `ranked` from Zones.Rank.
--- opts = { shown = map of the zone on screen, plan = its plan (used instead of the ranked one),
---          was = the previous itinerary (its order of zones is kept unless clearly beaten; zones
---                at its front that have nothing left by now are passed over) }
--- The zone on screen is the one in hand: as an itinerary's first zone it may be left however
--- little is left in it (Zones.MIN_STAY is for zones that take a trip to reach).
--- Returns nil when nothing can be planned, else
---   { horizon, xp, rate (XP per hour over the horizon), stay = XP of the best single zone,
---     shown = opts.shown, here = XP of the best itinerary that starts in the shown zone
---             (nil when nothing is left there, or no zone is shown),
---     segments = { { map, name, travel (seconds to get there), seconds (spent there), xp,
---                    leave = step index left after (nil: until the horizon), leaveKey,
---                    carried, carriedXP = quests brought along from the zones before and turned
---                    in here, and their XP (part of xp),
---                    plan = the plan the zone is followed by (later zones: as made here) } } }.
--- `leave` and `leaveKey` of the first zone refer to its plan as given; those of later zones
--- to the plan made for them here (from where the zone before is left).
function Zones.Itinerary(state, ctx, ranked, opts)
    opts = opts or {}
    local H = Zones.HORIZON
    local zones = {}
    for _, z in ipairs(ranked or {}) do
        local plan = (z.map == opts.shown and opts.plan) or z.plan
        if plan and #plan.steps > 0 and (#zones < Zones.ITINERARY_ZONES or z.map == opts.shown) then
            zones[#zones + 1] = { map = z.map, plan = plan }
        end
    end
    if #zones == 0 then return nil end
    local rankedPlan = {} -- the plans the zones above were ranked with: the warm starts of their later plans
    for _, z in ipairs(zones) do rankedPlan[z.map] = z.plan end
    local checkpoint = ctx.checkpoint
    -- progress: the first search, then one part for each zone planned again (four at most)
    local parts = 0
    local function part()
        if ctx.progress then ctx.progress("itinerary", parts, 5) end
        parts = parts + 1
    end
    part()
    local leaves, trips = {}, {}
    -- travel between zones is corrected like travel inside a zone's plan (ns.Learn's step-time model)
    local travelFactor = 1
    if type(ctx.stepModel) == "table" and (tonumber(ctx.stepModel.n) or 0) > 0 then
        travelFactor = ns.Learn.TravelFactor(ctx.stepModel)
    end
    local function leavesOf(plan)
        leaves[plan] = leaves[plan] or leavePoints(plan)
        return leaves[plan]
    end
    local function trip(from, plan) -- seconds from a stop to another plan's first stop, switch cost included
        local row = trips[from]
        if not row then row = {}; trips[from] = row end
        if not row[plan] then
            row[plan] = Planner.SWITCH_OVERHEAD + ctx.travel:Seconds(from, plan.steps[1].loc) * travelFactor
        end
        return row[plan]
    end

    -- Try every order (or only `order`, a list of maps; or only those starting in `first`),
    -- every leave point (or only `fixed[n]` for the n-th zone), with `swap[map]` in place of
    -- that zone's plan when it is not the first zone.
    local function search(order, fixed, swap, depthMax, first)
        local best
        local segs, used = {}, {}
        local function go(depth, time, xp, loc)
            for _, z in ipairs(zones) do
                if not used[z.map] and (not order or order[depth] == z.map) and (depth > 1 or not first or first == z.map) then
                    local plan = (swap and depth > 1 and swap[z.map]) or z.plan
                    local first = plan.steps[1]
                    local lead = depth == 1 and (first.t - first.seconds) or trip(loc, plan)
                    local start = time + lead
                    if start + Zones.MIN_STAY <= H or depth == 1 then
                        local gain, finish, last = untilHorizon(plan, start, H)
                        segs[depth] = { map = z.map, plan = plan, travel = lead, seconds = finish - start, xp = gain, last = last }
                        if not best or xp + gain > best.xp then
                            best = { xp = xp + gain, segments = {} }
                            for i = 1, depth do best.segments[i] = segs[i] end
                        end
                        if depth < (depthMax or Zones.ITINERARY_STOPS) and (not order or order[depth + 1]) then
                            used[z.map] = true
                            for _, p in ipairs(leavesOf(plan)) do
                                local t = start + since(plan, p)
                                local inHand = Zones.SHORT_IN_HAND and depth == 1 and opts.shown ~= nil and z.map == opts.shown
                                if t + Zones.MIN_STAY <= H and (inHand or since(plan, p) >= Zones.MIN_STAY)
                                    and not (fixed and fixed[depth] and p ~= fixed[depth]) then
                                    segs[depth] = { map = z.map, plan = plan, travel = lead, seconds = t - start,
                                        xp = plan.steps[p].cumXP, leave = p }
                                    go(depth + 1, t, xp + plan.steps[p].cumXP, plan.steps[p].loc)
                                end
                            end
                            used[z.map] = nil
                        end
                        segs[depth] = nil
                    end
                end
                if checkpoint then checkpoint() end
            end
        end
        go(1, 0, 0, nil)
        return best
    end

    local single = search(nil, nil, nil, 1)
    local best = search()
    if not best then return nil end
    -- keep the shown order of zones unless another is clearly better
    -- (zones at its front with nothing left by now are finished: the rest of the order stands)
    if opts.was and opts.was.segments then
        local open, order = {}, {}
        for _, z in ipairs(zones) do open[z.map] = true end
        for _, seg in ipairs(opts.was.segments) do
            if #order > 0 or open[seg.map] then order[#order + 1] = seg.map end
        end
        local kept = #order > 0 and search(order) or nil
        if kept and #kept.segments == #order and best.xp <= kept.xp * Zones.KEEP_ITINERARY then best = kept end
    end
    -- The zones after the first as they will really be found: each is planned again from where
    -- the one before is left, at the level reached by then, with that zone's turned-in quests
    -- done and the quests still held in the log (see `project`). The moment to leave each zone
    -- is chosen with the zones before it settled. A zone with nothing to do by then is dropped,
    -- with everything after it.
    local function refine(cand)
        if not cand or #cand.segments < 2 or not cand.segments[1].leave then return cand end
        local order = {}
        for i, seg in ipairs(cand.segments) do order[i] = seg.map end
        local fixed, swap = { cand.segments[1].leave }, {}
        local st, cx, plan, leave, carried = state, ctx, cand.segments[1].plan, cand.segments[1].leave, nil
        local got = cand
        for depth = 2, #order do
            local after
            part()
            after, carried = project(st, cx, plan, leave, carried)
            after.checkpoint = state.checkpoint
            after.memory = nil -- a projected state never reads or writes the memory
            after.altRate = after.altRate or ctx.altRate
            local cx2 = Zones.Context(after)
            cx2.searchRounds = Zones.ITINERARY_ROUNDS
            -- start from the order this zone was ranked with: today's state, not the projected one,
            -- but most of the route is the same (what is done or gone by then is left out)
            local ranked_ = rankedPlan[order[depth]]
            local again = Zones.PlanZone(order[depth], cx2, nil, nil, { readOnly = true,
                warm = Zones.ITINERARY_WARM and ranked_ and (ranked_.searchOrder or ranked_.order) or false,
                weights = ranked_ and ranked_.search and ranked_.search.weights or nil })
            if #again.steps == 0 then
                for i = #order, depth, -1 do order[i] = nil end
                got = search(order, fixed, swap)
                break
            end
            again.carried = carried
            swap[order[depth]] = again
            got = search(order, fixed, swap)
            local seg = got and got.segments[depth]
            if not seg or not seg.leave then break end -- nothing follows: every zone in it is planned again
            fixed[depth] = seg.leave
            st, cx, plan, leave = after, cx2, again, seg.leave
        end
        return got
    end
    -- an itinerary must beat simply staying in one zone
    local function settle(cand)
        local refined = refine(cand)
        if refined and #refined.segments >= 2 and single and refined.xp > single.xp then return refined end
        return single
    end
    if #best.segments >= 2 then best = settle(best) end
    if not best then return nil end
    -- Against staying: the best itinerary that starts in the shown zone, worked out the same
    -- way. (When that turns out better than the one found, it is the answer.)
    local here
    if opts.shown then
        if best.segments[1].map == opts.shown then
            here = best.xp
        else
            local stay = search(nil, nil, nil, 1, opts.shown)
            local onward = search(nil, nil, nil, nil, opts.shown)
            if onward and #onward.segments >= 2 then onward = refine(onward) end
            if stay and (not onward or onward.xp < stay.xp) then onward = stay end
            if onward then
                here = onward.xp
                if onward.xp >= best.xp then best = onward end
            end
        end
    end

    local out = { horizon = H, xp = math.floor(best.xp), rate = best.xp / H * 3600, stay = single and math.floor(single.xp) or nil,
        shown = opts.shown, here = here and math.floor(here) or nil, segments = {} }
    for i, seg in ipairs(best.segments) do
        -- quests brought along from the zones before and turned in here
        local carried, carriedXP = 0, 0
        if seg.plan.carried then
            for k = 1, seg.leave or seg.last or 0 do
                local step = seg.plan.steps[k]
                if step.kind == "turnin" and seg.plan.carried[step.quests[1].id] then
                    carried, carriedXP = carried + 1, carriedXP + step.xp
                end
            end
        end
        out.segments[i] = { map = seg.map, name = Zones.Name(seg.map), travel = seg.travel, seconds = seg.seconds, xp = math.floor(seg.xp),
            leave = seg.leave, leaveKey = seg.leave and seg.plan.order[seg.leave] or nil,
            carried = carried, carriedXP = carriedXP, plan = seg.plan }
    end
    return out
end

--- The zone to show when the zone on screen (`finished`) has nothing left: the one the
--- itinerary made for it goes to next. nil when the itinerary was made for another zone or
--- names nothing else: the caller then chooses as it does without an itinerary.
function Zones.NextZone(itinerary, finished)
    if not finished or not itinerary or not itinerary.segments or itinerary.shown ~= finished then return nil end
    local segs = itinerary.segments
    for i, seg in ipairs(segs) do
        if seg.map == finished then return segs[i + 1] and segs[i + 1].map or nil end
    end
    return segs[1] and segs[1].map or nil -- it starts elsewhere: that is where it wanted us already
end
