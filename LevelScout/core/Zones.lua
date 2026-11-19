-- core/Zones.lua: the character's planning context, which zones to consider, how they rank,
-- and when to move on. Pure Lua: reads ns.Data and the other core modules only.

local _, ns = ...

local Zones = {}
ns.Zones = Zones

local Geo, Cost, Travel, Planner = ns.Geo, ns.Cost, ns.Travel, ns.Planner

Zones.SHORTLIST = 9          -- zones planned at a time (those with most quests that give XP now first); dungeons come on top
Zones.EARLY = 1             -- a zone is offered this many levels before its suggested range starts (dungeons: see DUNGEON_FROM)
Zones.EARLY_EXTRA = 1       -- such early zones never push a zone in its range off the shortlist: they take its free places, and this many more
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

--- The hearthstone as the planner takes it (ctx.stone), from state.hearth, or nil:
--- { kind = "hearth", name, loc, ready (rounded up to HEARTH_READY_STEP), cd, cast (cast + loading screen) }.
function Zones.Stone(h)
    if type(h) ~= "table" or not (h.map and h.x and h.y) then return nil end
    local ready, step = math.max(0, tonumber(h.ready) or 0), Planner.HEARTH_READY_STEP
    if step and step > 0 then ready = math.ceil(ready / step) * step end
    return { kind = "hearth", name = h.name, loc = Geo.Loc(h.map, h.x * 100, h.y * 100), ready = ready,
        cd = tonumber(h.cd) or Planner.HEARTH_COOLDOWN, cast = (tonumber(h.cast) or Planner.HEARTH_CAST) + Planner.HEARTH_LOAD }
end

--- The hearthstone's uses in `plan` up to step `upto` (nil: all): how many, the seconds they save.
function Zones.HearthUses(plan, upto)
    local n, saved = 0, 0
    for i, s in ipairs(plan and plan.steps or {}) do
        if upto and i > upto then break end
        if s.hearth then n, saved = n + 1, saved + (s.hearth.saved or 0) end
    end
    return n, saved
end

local bindCache = {}
local function bindKey(name)
    return (tostring(name):lower():gsub("^the%s+", ""):gsub("%s+city$", ""):gsub("[^%w]", ""))
end

--- Where a hearthstone bound at `name` (the client's bind location, "Lakeshire", "Stormwind City") is, from the
--- hubs of the side ("a" | "h"; a hub of both sides counts too): { map, x, y (0-1) }, or nil. Three passes over the
--- hubs, maps in id order: the name as it is (any case); then with "The" and "City" left off and only letters and
--- digits kept; then a hub whose key (5 letters at least) starts the name's ("Theramore Isle" for "Theramore").
function Zones.BindSpot(name, side)
    if type(name) ~= "string" or name == "" then return nil end
    local key = name .. "|" .. tostring(side)
    local hit = bindCache[key]
    if hit == nil then
        hit = false
        local world = ns.Data.World()
        local maps = {}
        for map in pairs(world and world.zones or {}) do
            if type(map) == "number" then maps[#maps + 1] = map end
        end
        table.sort(maps)
        local wanted, wantedKey = name:lower(), bindKey(name)
        for pass = 1, 3 do
            for _, map in ipairs(maps) do
                local info = Zones.Info(map, side)
                for _, hub in ipairs(info and info.hubs or {}) do
                    if hub.side == "b" or hub.side == side or not side then
                        local hubKey = bindKey(hub.name)
                        if (pass == 1 and hub.name:lower() == wanted) or (pass == 2 and hubKey == wantedKey)
                            or (pass == 3 and #hubKey >= 5 and wantedKey:sub(1, #hubKey) == hubKey) then
                            hit = { map = map, x = hub.x / 100, y = hub.y / 100 }
                            break
                        end
                    end
                end
                if hit then break end
            end
            if hit then break end
        end
        bindCache[key] = hit
    end
    if hit then return { map = hit.map, x = hit.x, y = hit.y } end
    return nil
end

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
---           now (seconds, the memory's clock; optional),
---           hearth = { name, map, x, y (0-1), ready (s, 0 now), cd, cast } (the hearthstone: where it is bound,
---           the seconds until it can be used, its cooldown and cast; optional, used only with Planner.HEARTH) }
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
        stone = Planner.HEARTH and Zones.Stone(state.hearth) or nil, -- the hearthstone (Planner.HEARTH)
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

local classInside = {} -- [class] = Zones.ClassInside's answer

function Zones.Reset() zoneCache, dungeonCache, classInside, bindCache = {}, nil, {}, {} end

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
--- A zone is offered from Zones.EARLY levels before its suggested range starts, not sooner.
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
        if info and info.lo and (forced or (sideOk and ctx.level >= info.lo - Zones.EARLY and ctx.level <= info.hi + 2)) then
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
            if n > 0 then
                out[#out + 1] = { map = map, quests = n, forced = forced, lo = info.lo, hi = info.hi,
                    early = (not forced and ctx.level < info.lo) or nil }
            end
            seen[map] = true
            if ctx.checkpoint then ctx.checkpoint() end
        end
    end
    -- (zones offered early come last: they do not take a place from a zone in its range)
    table.sort(out, function(a, b)
        if a.forced ~= b.forced then return a.forced end
        if (a.early or false) ~= (b.early or false) then return not a.early end
        if a.quests ~= b.quests then return a.quests > b.quests end
        return a.map < b.map
    end)
    local forcedCount, inRange = 0, 0
    for _, z in ipairs(out) do
        if z.forced then forcedCount = forcedCount + 1 end
        if not z.early then inRange = inRange + 1 end
    end
    local keep = math.max(Zones.SHORTLIST, forcedCount)
    -- the zones in their range fill the list first; early ones get what is left, and EARLY_EXTRA more
    local total = math.min(inRange, keep) + math.min(#out - inRange, math.max(0, keep - inRange) + Zones.EARLY_EXTRA)
    for i = #out, 1, -1 do
        local z = out[i]
        if (not z.early and i > keep) or (z.early and i > total) then table.remove(out, i) end
    end
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

--- Class quests of this class that take it into a dungeon: an objective that can only be done
--- inside (every NPC or object for it stands in that dungeon and nowhere else, Data.InstanceOf),
--- whatever dungeon the quest is filed under. { [dungeon zone (-id)] = { [questId] = { full =
--- true when all of it is done there, objectives = { indexes done there } } } }, kept per class.
function Zones.ClassInside(class, checkpoint)
    local Data = ns.Data
    if not class or not Data.IsIndexBuilt() then return {} end
    local got = classInside[class]
    if got then return got end
    got = {}
    for _, id in ipairs(Data.ClassQuests(class)) do
        local q = Data.GetQuest(id)
        if q and #q.objectives > 0 then
            local where, outside = {}, false
            for i, o in ipairs(q.objectives) do
                local inside
                for _, s in ipairs(Data.ObjectiveSources(o)) do
                    local d = (s.kind == "npc" or s.kind == "object") and Data.InstanceOf(s.kind, s.id) or nil
                    if not d or (inside and inside ~= d) then inside = false; break end
                    inside = d
                end
                if inside then
                    where[inside] = where[inside] or {}
                    where[inside][#where[inside] + 1] = i
                else
                    outside = true
                end
            end
            for d, objectives in pairs(where) do
                got[-d] = got[-d] or {}
                got[-d][id] = { full = not outside and #objectives == #q.objectives, objectives = objectives }
            end
        end
        if checkpoint then checkpoint() end
    end
    classInside[class] = got
    return got
end

-- The dungeon's quests for this character: its own, and the class quests done partly or wholly
-- inside (Zones.ClassInside). Returns the list, the set, and { [id] = objective indexes done
-- inside } of those done only partly there.
local function questsFor(d, ctx)
    local extra = ctx and ctx.avail and Zones.ClassInside(ctx.avail.class, ctx.checkpoint)[d.zone]
    if not extra then return d.quests, d.questSet, {} end
    local quests, set, partial = {}, {}, {}
    for _, id in ipairs(d.quests) do quests[#quests + 1] = id; set[id] = true end
    for id, how in pairs(extra) do
        if not set[id] then quests[#quests + 1] = id; set[id] = true end
        if not how.full then partial[id] = how.objectives end
    end
    table.sort(quests)
    return quests, set, partial
end

-- The dungeon as the planner needs it for this character: where the door is, how long a run
-- is assumed to take and what its kills pay (elites, shared by five).
local function dungeonFor(d, ctx)
    local seconds, kills = Cost.DungeonRun(d.bosses)
    local mobLevel = math.floor((d.lo + d.hi) / 2)
    local quests, questSet, partial = questsFor(d, ctx)
    return { id = d.id, name = d.name, loc = Geo.Loc(d.map, d.x, d.y), quests = quests, questSet = questSet,
        partial = partial, confirmed = d.confirmed, seconds = seconds,
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
    for _, id in ipairs((questsFor(d, ctx))) do
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
        for _, id in ipairs((questsFor(d, ctx))) do
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
---          front = with a seed: stops to bring to the route's front (see Planner.Plan),
---          first = with a seed: the stop to put first (see Planner.Plan),
---          border = with a seed: quests taken along to the next zone (see Planner.Plan),
---          exact = with a seed: the seed is the route as it is (see Planner.Plan) }.
--- With ctx.memory and without opts.warm, the zone's last plan in the memory is the warm start.
--- The plan keeps what it was made from, for ns.Snapshot: warmSeed and warmWeights (the warm start
--- it was given) and seedOrder, seedFront, seedFirst and seedBorder (the seed and `front`, `first` and
--- `border`), and `from` (Zones.BORDER or Zones.SEAM only: where it was planned from, so that
--- Zones.WithBorder and Zones.WithSeam can plan it again from there).
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
    local plan = Zones.PlanOne(map, ctx, seed, warm or nil, weights, opts.front, opts.first, opts.border, opts.exact)
    if Zones.BORDER or Zones.SEAM then plan.from = ctx.start end -- (where it was planned from: Zones.WithBorder and Zones.WithSeam plan it again from there)
    if opts.border then plan.seedBorder = opts.border end -- (ns.Snapshot)
    plan.seedOrder, plan.seedFront, plan.seedFirst = seed, opts.front, opts.first -- how it was made (ns.Snapshot)
    if warm then plan.warmSeed, plan.warmWeights = warm, weights end -- (the debug view plans the same again)
    if mem and not seed and not opts.readOnly and not Zones.Dungeon(map) then
        ns.Memory.Remember(mem, map, plan, plan.search and plan.search.warm or false)
    end
    return plan
end

-- (PlanZone without the memory: from the position in ctx.start)
function Zones.PlanOne(map, ctx, seed, warm, weights, front, first, border, exact)
    local dungeon = Zones.Dungeon(map)
    if dungeon then
        -- Travel to the door, the givers and the prerequisite quests is all on the clock, so
        -- there is no separate switch cost.
        local start = ctx.start
        ctx.dungeon = dungeonFor(dungeon, ctx)
        ctx.start = start or ctx.dungeon.loc
        ctx.near = ctx.dungeon.loc
        local plan = Planner.Plan(dungeon.map, ctx, { overhead = 0, seed = seed, front = front, first = first })
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
    local plan = Planner.Plan(map, ctx, { overhead = overhead, seed = seed, warm = warm, weights = weights, front = front, first = first, border = border, exact = exact })
    ctx.start, ctx.near = start, nil
    return plan
end

-- Does the quest end on another map than `map`: a spot of its turn-in (players' first, else its
-- NPCs' or objects') elsewhere? A cheap look before its model is built.
local function endsOutside(id, map)
    local Data = ns.Data
    local q = Data.GetQuest(id)
    if not q then return false end
    local spots = q.spots and q.spots.finish or {}
    if #spots == 0 then
        for _, g in ipairs(q.finishers or {}) do
            local e = (g.kind == "npc" and Data.GetNpc(g.id)) or (g.kind == "object" and Data.GetObject(g.id)) or nil
            for _, s in ipairs(e and e.spots or {}) do if s.map ~= map then return true end end
        end
        return false
    end
    for _, s in ipairs(spots) do if s.map ~= map then return true end end
    return false
end

--- The quests of zone `map` that an itinerary going on to `later` (maps, in order) can take along:
--- accepted here (or in the log already), their work on this map done here, the rest left to the
--- later zones, whose plans weigh them as quests brought along (see `project`): the turn-in
--- anywhere outside this zone, and any other work only on the map of a later zone. Looked at: the
--- quests `plan` (the zone's plan, left after step `leave`) leaves out as slow, and the ones it
--- turns in outside the zone, unless it accepts them before leaving and turns them in after (they
--- are brought along already). Not: a quest of the step the zone is left after, one skipped by the
--- player, one that cannot be done yet, any when the plan already fills the quest log.
--- Returns { { id, to = the zone of its turn-in }, ... } by id, at most Zones.BORDER_MAX (most XP first).
function Zones.BorderQuests(map, ctx, plan, leave, later)
    local out = {}
    if plan.logFull or not plan.steps[leave] then return out end
    local isLater, prefer = {}, { map }
    for _, m in ipairs(later) do isLater[m] = true; prefer[#prefer + 1] = m end
    local function zoneOf(loc) -- (a spot on this zone's own map is in it; one on a continent map is resolved)
        if not loc then return nil end
        if loc.map == map then return map end
        return Zones.ZoneAt(loc, prefer) or loc.map
    end
    local firstAt, T = {}, {}
    for i, step in ipairs(plan.steps) do
        for _, q in ipairs(step.quests or {}) do
            if not firstAt[q.id] then firstAt[q.id] = i end
            if step.kind == "turnin" then T[q.id] = i end
        end
    end
    local atLeave = {}
    for _, q in ipairs(plan.steps[leave].quests or {}) do atLeave[q.id] = true end
    local ids, seen = {}, {}
    local function add(id) if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
    for _, e in ipairs(plan.lists and plan.lists.skipped or {}) do
        if ctx.log[e.id] or (e.loc and e.loc.map == map) then add(e.id) end -- (given here, or in the log)
    end
    for id, i in pairs(T) do
        if zoneOf(plan.steps[i].loc) ~= map then add(id) end
    end
    table.sort(ids) -- (T was walked with pairs)
    local near = ctx.near
    ctx.near = entryPoint(map, ctx.side) -- (as Zones.PlanOne plans the zone: the same models)
    local found = {}
    for _, id in ipairs(ids) do
        if ctx.checkpoint then ctx.checkpoint() end
        local inLog = ctx.log[id] ~= nil
        local carriedAlready = T[id] and firstAt[id] <= leave and T[id] > leave
        if not atLeave[id] and not (ctx.ignored and ctx.ignored[id]) and not carriedAlready
            and (T[id] or endsOutside(id, map)) then
            local m = ns.Model.Build(id, ctx)
            if m and m.status == "ok" and m.turnin and (m.xp or 0) > 0
                and (inLog or (m.pickup and m.pickup.map == map)) then
                local to = zoneOf(m.turnin)
                local ok = to ~= map
                for _, t in ipairs(m.tasks) do
                    if t.loc.map ~= map and not isLater[t.loc.map] then ok = false end
                end
                -- (in the log with nothing to do here: only worth it when the plan goes out of the zone for it)
                if ok and inLog and not T[id] then
                    local here = false
                    for _, t in ipairs(m.tasks) do if t.loc.map == map then here = true end end
                    ok = here or m.tasks[1] == nil
                end
                if ok then found[#found + 1] = { id = id, to = to, xp = m.xp } end
            end
        end
    end
    ctx.near = near
    table.sort(found, function(a, b) if a.xp ~= b.xp then return a.xp > b.xp end return a.id < b.id end)
    for i = #found, Zones.BORDER_MAX + 1, -1 do found[i] = nil end
    table.sort(found, function(a, b) return a.id < b.id end)
    for _, q in ipairs(found) do out[#out + 1] = { id = q.id, to = q.to } end
    return out
end

--- The route on screen with the quests the itinerary takes along (`border` = an itinerary's
--- `border`, kept by the Engine as chardb.border): `plan` planned again in its own order with
--- only their stops here added (Planner.Plan's opts.border). Of `front` (stops we stand at, as for
--- Zones.PlanZone) only their accepts are brought forward: nothing else of `plan` moves.
--- `plan` itself when the set is not for this zone or nothing of it is left; otherwise the new
--- plan, whose `base` is `plan`.
function Zones.WithBorder(map, ctx, plan, border, front)
    if not (Zones.BORDER and border and border.zone == map and plan and #plan.steps > 0 and not plan.chain) then return plan end
    local taken, mine = {}, nil
    for _, id in ipairs(border.ids or {}) do taken["P:" .. id] = true end
    for _, key in ipairs(front or {}) do
        if taken[key] then mine = mine or {}; mine[#mine + 1] = key end
    end
    local got = Zones.PlanZone(map, ctx, plan.order, plan.from, { border = border, front = mine })
    if #(got.borderIds or {}) == 0 or #got.steps == 0 then return plan end
    got.base = plan
    return got
end

--- The way from zone `map` into the next, planned together (Zones.Itinerary's seam step): `cx` is
--- the character at the start of the stretch (as `project` leaves them), `overhead` the seconds from
--- the itinerary's start to that moment, `spec` what Planner.Plan's opts.seam takes:
---   { also = { the next zone's map }, keysA, keysB = the stretch's keys on each side, in order,
---     side = { [id] = "A" | "B" | "X" } for quests done inside the stretch (on one side; "X": on
---     both, they stay), ghost = { [id] = true } quests of the stretch that go on after it,
---     after = { [id] = true } quests with steps in the next zone's route after the stretch,
---     free = { [id] = "A" | "B" } quests that may come in, and on which side,
---     endLoc = the place the rest of the path starts at (nil: nothing follows in that zone),
---     tail = function(when, where) -> XP inside the horizon of what follows the stretch (or nil),
---     horizon, switch = seconds of the zone switch, rounds, work, seed }.
--- Returns the planner's seam result (see Planner.Plan) or nil, and the work units it took.
function Zones.PlanSeam(map, cx, spec, overhead)
    local near, start = cx.near, cx.start
    cx.near = entryPoint(map, cx.side) -- (as Zones.PlanOne plans the zone: the same models)
    if not cx.start then cx.start = entryPoint(map, cx.side) end
    cx.trace = nil
    local got = Planner.Plan(map, cx, { seam = spec, overhead = overhead })
    cx.near, cx.start = near, start
    return got.seam, got.work or 0
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
    -- (a leg that goes by hearthstone starts at the inn: Planner.HEARTH)
    local from = {}
    for i, step in ipairs(plan.steps) do from[i] = step.hearth and step.hearth.loc or points[i] end
    for id, n in pairs(nodes) do
        if not known[id] and not (skip and skip[id]) and (n[7] == "n" or n[7] == ctx.side) and n[4] and n[5] and n[6] then
            local loc = { c = n[1], x = n[2], y = n[3], map = n[4], mx = n[5], my = n[6] }
            local best, detours = nil, {}
            for i = 1, #points do
                local prev, nxt = from[i] or points[i], points[i + 1]
                local there = travel:Walk(prev, loc)
                if there and there <= Zones.FLIGHT_DETOUR then
                    local d = there
                    if nxt then
                        -- (on from the flight master: on foot, or by the flight that starts there)
                        local on, direct = travel:Walk(loc, nxt), (travel:Seconds(prev, nxt))
                        local ride = travel:Seconds(loc, nxt)
                        if on and ride < on then on = ride end
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

--- The ranked zones with something to do, in the Zones tab's order when an itinerary was made for
--- `shown`: by itinerary.starts rate, best first, ties in the ranking's order. nil when the
--- itinerary is for another zone or has no figure for one of them (the tab then lists the
--- one-hour scores).
function Zones.StartOrder(itinerary, ranked, shown)
    local starts = itinerary and itinerary.starts
    if not starts or shown == nil or itinerary.shown ~= shown then return nil end
    local list, at = {}, {}
    for i, z in ipairs(ranked or {}) do
        if z.plan and #z.plan.steps > 0 then
            if not starts[z.map] then return nil end
            list[#list + 1] = z; at[z] = i
        end
    end
    table.sort(list, function(a, b)
        local ra, rb = starts[a.map].rate, starts[b.map].rate
        if ra ~= rb then return ra > rb end
        return at[a] < at[b]
    end)
    return list
end

--- Move-on rule with hysteresis. `active` is the shown zone's plan, `ranked` from Zones.Rank,
--- `was` the previous answer, `itinerary` from Zones.Itinerary (optional).
--- Returns { suggest, map, gain, rate }: gain 0.25 = 25% more XP by leaving now. `rate` is true
--- when the gain is in XP per hour over the itinerary's horizon (the Zones tab's figures), else
--- it is over the next hour (nil gain: nothing left here).
---
--- With an itinerary made for the shown zone, see the first lines of the function. Without:
--- Both choices are valued over the same hour, so the answer does not swing when little is
--- left here:
---   leave now:  an hour of the other zone, trip included;
---   stay:       what is left here, then the other zone for the rest of the hour.
--- A short remainder therefore never triggers the suggestion by itself; a long stretch of
--- poor quests does.
function Zones.MoveOn(active, ranked, was, itinerary)
    -- With an itinerary made for the shown zone, the banner says what the Zones tab says: the zone
    -- it lists first (Zones.StartOrder), when that is not the shown one. The gain is that zone's
    -- start rate against the shown zone's.
    -- (Nothing left here, or an itinerary made while another zone was shown: the rule below.)
    if itinerary and itinerary.segments and itinerary.segments[1] and active and #active.steps > 0
        and itinerary.shown ~= nil and itinerary.shown == active.zone then
        local order = Zones.StartOrder(itinerary, ranked, active.zone)
        local mine = order and order[1] and itinerary.starts[active.zone]
        if mine and mine.rate > 0 then
            local top = order[1]
            if top.map == active.zone then return { suggest = false } end
            local lead = itinerary.starts[top.map].rate / mine.rate
            local threshold = (was and was.suggest and was.map == top.map) and Zones.MOVE_ON_EXIT or Zones.MOVE_ON_ENTER
            return { suggest = lead > threshold, map = top.map, gain = lead - 1, rate = true }
        end
        -- (carried over after the path moved on, without figures: it starts here, no banner)
        if not itinerary.starts and itinerary.segments[1].map == active.zone then return { suggest = false } end
        -- (figures missing for a zone of a newer ranking: the one-hour rule, as the tab then lists)
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
-- leave is tried. The best few (Zones.REFINE_TOP, each with another next zone) have their second
-- and third zone planned again as they will really be found: from where the zone before is left,
-- at the level reached by then, with its quests done and the quests still in the log carried
-- along. The one that earns most then wins, unless the order on screen is within
-- Zones.KEEP_ITINERARY of it.

Zones.HORIZON = 9000           -- seconds an itinerary covers (two and a half hours)
Zones.ITINERARY_ZONES = 5      -- best-ranked zones that may appear in it
Zones.ITINERARY_STOPS = 3      -- zones in a row at most
Zones.LEAVE_EVERY = 900        -- a zone may be left at the first turn-in after each quarter of an hour
Zones.MIN_STAY = 600           -- a zone is not visited for less than this (the zone on screen may be: we are in it already)
-- Search rounds when a later zone is planned again (nil: as many as a full plan). Measured on
-- six characters: 40, 60 or 80 rounds cut the time to a quarter or a third but gave two of them
-- a worse itinerary (5% and 11% less XP), so the full search is kept.
Zones.ITINERARY_ROUNDS = 40 -- with ITINERARY_WARM: the later zones start from their ranked plans
Zones.KEEP_ITINERARY = 1.05    -- the order of zones on screen (and the step its first zone is left after) stays unless another earns 5% more, all planned again
Zones.REFINE_TOP = 3           -- itineraries planned again before one is chosen: the best by today's plans, each with another next zone
Zones.PIN_SHOWN = true        -- the itinerary starts in the shown zone while that has something left; the zone the Zones tab lists first, if another, is its `alt`
Zones.SHORT_IN_HAND = true     -- the zone on screen may be left after less than MIN_STAY: we are in it already
Zones.BORDER = true            -- the itinerary takes along quests that end beyond its first zone: accepted there, finished in a zone it goes on to
Zones.BORDER_MAX = 4           -- such quests at most (most XP first)
Zones.BORDER_ROUNDS = 20       -- search rounds for the later zones planned again with them in the log (warm from their plain plans)
Zones.BORDER_GAIN = 0.005      -- a new set is taken when the itinerary earns this much more; the set on screen stays while it earns no less
Zones.SEAM = false             -- (off: no clear gain on the bench, see docs/planner.md) the way from the itinerary's first zone into the next is planned together: the end of one, the trip and the start of the other as one route
Zones.SEAM_SPAN = 1200         -- seconds: the stretch planned together on each side of the crossing (the steps that end within this of it)
Zones.SEAM_MIN_STOPS = 3       -- steps on each side at least (as far as the route has them)...
Zones.SEAM_MAX_STOPS = 12      -- ...and at most
Zones.SEAM_FREE = 6            -- quests left out by either zone that may come in, at most (the nearest first)
Zones.SEAM_REACH = 500         -- yards: such a quest is this close to a step of the stretch, at most
Zones.SEAM_TRIP = 600          -- seconds: planned together only when the trip between the zones takes at most this (the switch not counted)
Zones.SEAM_NEAR = 300          -- yards: stops of the two sides this close to each other touch both zones
Zones.SEAM_ROUNDS = 40         -- search rounds over the stretch (it starts as the itinerary has it)
Zones.SEAM_WORK = 250000       -- work units at most for that search
Zones.SEAM_GAIN = 0.005        -- a new way across is taken when the itinerary earns this much more; the one on screen stays while it earns no less

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

-- (for the quests taken along, Zones.Itinerary)
local function keyIndex(order, key)
    for i, k in ipairs(order or {}) do if k == key then return i end end
    return nil
end
local function sameIds(a, b) -- two sorted lists of ids (or any two lists)
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
local function within(a, b) -- every id of the list a is in the list b
    local set = {}
    for _, id in ipairs(b or {}) do set[id] = true end
    for _, id in ipairs(a) do if not set[id] then return false end end
    return true
end

--- The route without the way across planned together and without the quests taken along: what the
--- keep rule compares and what is saved with the character (the plan itself when it has neither).
function Zones.Plain(plan)
    if not plan then return nil end
    local p = plan.base or plan
    return p.seamBase or p
end

--- Of `plan` and the routes it is laid over, the one with the way across laid over it (Zones.WithSeam), or nil.
function Zones.SeamLayer(plan)
    if not plan then return nil end
    if plan.seamBase then return plan end
    if plan.base and plan.base.seamBase then return plan.base end
    return nil
end

--- A route's order with the way across planned together (`seam`, see Zones.Itinerary): the stretch
--- before the crossing as the seam has it (seam.keys), where the stretch began (the first key left of
--- seam.window: the stretch as the itinerary had it); what the seam left out of the stretch, and the
--- rest of the route, after it. nil when the stretch is not in the route as it was (none of its keys
--- left, or not in that order: another route).
function Zones.SeamOrder(order, seam)
    local at = {}
    for i, k in ipairs(seam.window or {}) do at[k] = i end
    local first, last = nil, 0
    for i, k in ipairs(order) do
        local p = at[k]
        if p then
            if p < last then return nil end
            last, first = p, first or i
        end
    end
    if not first then return nil end
    local mine, out = {}, {}
    for _, k in ipairs(seam.keys or {}) do mine[k] = true end
    for i = 1, first - 1 do if not mine[order[i]] then out[#out + 1] = order[i] end end
    for _, k in ipairs(seam.keys or {}) do out[#out + 1] = k end
    for i = first, #order do if not mine[order[i]] then out[#out + 1] = order[i] end end
    return out
end

--- The route on screen with the way across planned together (`seam` = an itinerary's `seam`, kept
--- by the Engine as chardb.seam): `plan`'s order made over by Zones.SeamOrder and rebuilt exactly
--- (nothing added, nothing dropped: Planner.Plan's opts.exact), from where `plan` was planned. `front`
--- as for Zones.PlanZone. `plan` itself when the seam is not for this zone, its stretch is not in the
--- route as it was, or the step it leaves after is done; otherwise the new plan, whose `seamBase` is
--- `plan` and `seamRecipe` is `seam`.
function Zones.WithSeam(map, ctx, plan, seam, front)
    if not (Zones.SEAM and seam and seam.zone == map and plan and #plan.steps > 0 and not plan.chain) then return plan end
    local order = Zones.SeamOrder(plan.order, seam)
    if not order then return plan end
    local got = Zones.PlanZone(map, ctx, order, plan.from, { exact = true, front = front })
    if #got.steps == 0 or not keyIndex(got.order, seam.leave) then return plan end
    got.seamBase, got.seamRecipe = plan, seam
    return got
end

-- Quests under way when the horizon cuts a plan (Zones.END_CREDIT). A turn-in that falls
-- after the horizon pays nothing inside it, so a plain cut marks down whatever is started
-- late: the last half hour of an itinerary would rather do small things that pay at once than
-- start a quest worth more. Each quest whose turn-in is still ahead therefore counts for the
-- share of its time already spent: its turn-in XP times (seconds put into its steps so far /
-- seconds its steps take up to and with the turn-in). A step's seconds (the way to it and
-- the work there) are shared equally among its quests.
-- credit(plan)[i] = that XP when the plan is cut after step i (0 when nothing is under way).
Zones.END_CREDIT = true
local credits = setmetatable({}, { __mode = "k" })
local function credit(plan)
    local c = credits[plan]
    if c then return c end
    local steps = plan.steps
    local turn, pays, total = {}, {}, {}
    for i, s in ipairs(steps) do
        if s.kind == "turnin" then
            local n = #(s.quests or {})
            for _, q in ipairs(s.quests or {}) do
                if not turn[q.id] then turn[q.id], pays[q.id] = i, (s.xp or 0) / n end
            end
        end
    end
    local function share(s)
        local n = #(s.quests or {})
        return n > 0 and ((s.travel or 0) + (s.seconds or 0)) / n or 0
    end
    for i, s in ipairs(steps) do
        local each = share(s)
        for _, q in ipairs(s.quests or {}) do
            if turn[q.id] and i <= turn[q.id] then total[q.id] = (total[q.id] or 0) + each end
        end
    end
    c = { [0] = 0 }
    local sum, put = 0, {}
    for i, s in ipairs(steps) do
        local each = share(s)
        for _, q in ipairs(s.quests or {}) do
            local t = turn[q.id]
            if t and i < t and total[q.id] > 0 then
                local part = pays[q.id] * each / total[q.id]
                put[q.id] = (put[q.id] or 0) + part
                sum = sum + part
            elseif t == i and put[q.id] then
                sum = sum - put[q.id]
                put[q.id] = nil
            end
        end
        c[i] = sum > 0 and sum or 0
    end
    credits[plan] = c
    return c
end

-- Following a plan from `start` (the moment its first stop is reached) until the horizon:
-- XP earned, when it ends, and the last step finished. A camp being worked when time runs
-- out counts for the share done, and so do the quests under way (see `credit`).
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
            if Zones.END_CREDIT then xp = xp + credit(plan)[last] end
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
-- Quests the plan takes along to the next zone (plan.border) go on as brought along, with their
-- work elsewhere still to do.
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
    -- Quests taken along to the next zone (plan.border, Zones.BORDER): their objectives elsewhere
    -- are still to do, so a quest with work left there is not finished.
    local along = plan.border
    for _, id in ipairs(along and plan.borderIds or {}) do
        local h = held[id]
        if h then h.left = h.left + (along[id].left or 0) end
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
            if (h and h.touched) or (along and along[entry.id]) then out[entry.id] = true end
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
    -- The hearthstone (Planner.HEARTH): its cooldown runs on from its last use up to the leave step.
    local ph = plan.hearth
    if ph and type(state.hearth) == "table" then
        local readyAt = ph.ready
        for _, u in ipairs(ph.uses) do if u.step <= leave then readyAt = u.t + ph.cd end end
        local h = {}
        for k, v in pairs(state.hearth) do h[k] = v end
        h.ready, h.cd = math.max(0, readyAt - at.t), ph.cd
        next_.hearth = h
    end
    next_.trace = nil
    next_.carried = out
    return next_, out
end
Zones.Project = project -- (for the tests)

--- Of itineraries found on today's plans (`cands`, best first), the one to follow: the first
--- Zones.REFINE_TOP of them planned again (`refine`: as each will really be found), the best of
--- those if it earns more than `alone` (the first zone alone, or the best single zone), else
--- `alone`; then the order on screen (`kept`, optional, planned again too) unless that one earns
--- Zones.KEEP_ITINERARY times more.
function Zones.Choose(cands, alone, kept, refine)
    local best = alone
    for i = 1, math.min(Zones.REFINE_TOP, #cands) do
        local got = refine(cands[i])
        if got and #got.segments >= 2 and (not best or got.xp > best.xp) then best = got end
    end
    kept = kept and refine(kept)
    if kept and (not best or best.xp <= kept.xp * Zones.KEEP_ITINERARY) then best = kept end
    return best
end

--- A later zone planned again from `from` (where the zone before is left) whose first leg is the hearthstone:
--- the trip there is that leg, with the zone switch. nil otherwise (then the trip is worked out as before).
function Zones.HearthLead(from, plan)
    local ph, first = plan.hearth, plan.steps[1]
    if not (ph and ph.from and first and first.hearth and from) then return nil end
    local d = Geo.Dist(ph.from, from)
    if not d or d > 1 then return nil end
    return Planner.SWITCH_OVERHEAD + (first.t - first.seconds - (plan.overhead or 0))
end

--- The best way through the next hours. `state` and `ctx` as for Zones.Context / Zones.Rank,
--- `ranked` from Zones.Rank.
--- opts = { shown = map of the zone on screen, plan = its plan (used instead of the ranked one),
---          was = the previous itinerary (its order of zones, and the step its first zone was left
---                after, are kept unless clearly beaten; zones at its front that have nothing left by
---                now are passed over; only `segments[i].map` and `.leaveKey` are read),
---          border = the set of quests taken along that is on screen (chardb.border; optional),
---          borderPlan = the shown zone's route with them (Zones.WithBorder; `plan` is then the
---                       route without them),
---          seam = the way across planned together that is on screen (chardb.seam; optional),
---          seamPlan = the shown zone's route with it (Zones.WithSeam; `plan` is then the route
---                     without it) }
--- The zone on screen is the one in hand: as an itinerary's first zone it may be left however
--- little is left in it (Zones.MIN_STAY is for zones that take a trip to reach).
--- Returns nil when nothing can be planned, else
---   { horizon, xp, rate (XP per hour over the horizon), stay = XP of the best single zone,
---     pathRate = XP per hour of the path over the time used (the figure of `starts`),
---     shown = opts.shown, here = XP of the path when it starts in the shown zone
---             (nil when nothing is left there, or no zone is shown),
---     alt = { map, name, xp, rate, gain, next } when the Zones tab lists another zone first (by
---           start rate, see Zones.StartOrder): `gain` is that zone's rate against the shown zone's,
---           minus one. The itinerary itself then starts in the shown zone all the same
---           (Zones.PIN_SHOWN),
---     starts = { [map] = { xp = XP inside the horizon when that zone is done first and the best
---                way on is taken from where it is left, rate = that in XP per hour (over the time
---                used, see below), next = the zone gone to after it (or nil),
---                path = true for the shown zone when the entry is the path itself (else it is
---                the zone alone) } }
---                for every ranked zone with something to do,
---     border = { zone, ids, to = { [id] = map }, before = the leave step's key, gain = XP more
---              than without them } when quests are taken along across the border (Zones.BORDER):
---              the first zone's plan is then the one with them (Zones.WithBorder makes the same),
---     seam = { zone, to, window, keys, leave, windowB, head, leaveB, gain = XP more than without it }
---            when the way from the first zone into the next is planned together (Zones.SEAM): the
---            first zone's plan is then the one with it (Zones.WithSeam makes the same),
---     seamInfo = how the way across was looked at (for the bench and tests; nil with one zone or the
---            flag off): { gated = "dungeon" | "empty" | "far" | "short" | "apart" | nil, ran,
---            windowA, windowB, keysA, keysB, movableA, movableB, fixed, free, work, proxyStart,
---            proxyBest, changedA, changedB, deferredA, deferredB, added, legBefore, legAfter,
---            stitchedXP, kept, keptXP, newXP, won = "kept" | "new" | nil, gain, leaveBefore, leaveAfter },
---     segments ={ { map, name, travel (seconds to get there), seconds (spent there), xp,
---                    leave = step index left after (nil: until the horizon), leaveKey,
---                    carried, carriedXP = quests brought along from the zones before and turned
---                    in here, and their XP (part of xp),
---                    plan = the plan the zone is followed by (later zones: as made here) } } }.
--- `leave` and `leaveKey` of the first zone refer to segments[1].plan (the plan as given, or the one
--- with the way across or the quests taken along); those of later zones to the plan made for them
--- here (from where the zone before is left).
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
    -- progress: the first search, then one part for each zone planned again
    local parts = 0
    local PARTS = 3 + (Zones.REFINE_TOP + 2) * (Zones.ITINERARY_STOPS - 1)
    local function part()
        if ctx.progress then ctx.progress("itinerary", math.min(parts, PARTS - 1), PARTS) end
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
    -- (a step a zone is left after that its own rules would not make a leave point stands: the way
    -- across, the quests taken along, the step the order on screen left its first zone after)
    local function pinLeave(plan, at)
        local points = leavesOf(plan)
        for _, p in ipairs(points) do if p == at then return end end
        points[#points + 1] = at
        table.sort(points)
    end

    -- Try every order (or only `order`, a list of maps; or only those starting in `first`),
    -- every leave point (or only `fixed[n]` for the n-th zone: then at least two zones), with `swap[map]` in place of
    -- that zone's plan when it is not the first zone, and `leadPlans[map]` in place of that zone's
    -- plan when it is the first zone.
    -- With `top` ({ by = {}, list = {} }) the best itinerary for each pair of first two zones is
    -- collected in `top.list`, in first-seen order.
    local function search(order, fixed, swap, depthMax, first, leadPlans, top)
        local best
        local segs, used = {}, {}
        local function go(depth, time, xp, loc)
            for _, z in ipairs(zones) do
                if not used[z.map] and (not order or order[depth] == z.map) and (depth > 1 or not first or first == z.map) then
                    local plan = (depth == 1 and leadPlans and leadPlans[z.map]) or (swap and depth > 1 and swap[z.map]) or z.plan
                    local first = plan.steps[1]
                    local lead = depth == 1 and (first.t - first.seconds) or Zones.HearthLead(loc, plan) or trip(loc, plan)
                    local start = time + lead
                    if start + Zones.MIN_STAY <= H or depth == 1 then
                        local gain, finish, last = untilHorizon(plan, start, H)
                        segs[depth] = { map = z.map, plan = plan, travel = lead, seconds = finish - start, xp = gain, last = last }
                        -- (with the first zone's leave step fixed, the answer goes on to a next
                        -- zone: staying put instead is not what was asked)
                        if (not best or xp + gain > best.xp) and not (fixed and fixed[1] and depth < 2) then
                            best = { xp = xp + gain, segments = {} }
                            for i = 1, depth do best.segments[i] = segs[i] end
                        end
                        if top and depth >= 2 then
                            local row = top.by[segs[1].map]
                            if not row then row = {}; top.by[segs[1].map] = row end
                            local c = row[segs[2].map]
                            if not c or xp + gain > c.xp then
                                local new = { xp = xp + gain, segments = {} }
                                for i = 1, depth do new.segments[i] = segs[i] end
                                if c then
                                    new.at = c.at
                                    top.list[c.at] = new
                                else
                                    top.list[#top.list + 1] = new
                                    new.at = #top.list
                                end
                                row[segs[2].map] = new
                            end
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
    if not single then return nil end
    -- the order of zones on screen (zones at its front with nothing left by now are finished: the
    -- rest stands) and the step its first zone was left after
    local keptOrder, keptLeave
    if opts.was and opts.was.segments then
        local open, order = {}, {}
        for _, z in ipairs(zones) do open[z.map] = true end
        for _, seg in ipairs(opts.was.segments) do
            if #order > 0 or open[seg.map] then
                order[#order + 1] = seg.map
                if #order == 1 then keptLeave = seg.leaveKey end
            end
        end
        if #order > 0 then keptOrder = order end
    end
    -- The zones after the first as they will really be found: each is planned again from where
    -- the one before is left, at the level reached by then, with that zone's turned-in quests
    -- done and the quests still held in the log (see `project`). The moment to leave each zone
    -- is chosen with the zones before it settled. A zone with nothing to do by then is dropped,
    -- with everything after it.
    -- (`how`, optional, for the quests taken along: { lead = { [map] = plan of the first zone },
    -- warmFrom = { [map] = plan each later zone starts its search from }, rounds = search rounds })
    local function refine(cand, how)
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
            cx2.searchRounds = (how and how.rounds) or Zones.ITINERARY_ROUNDS
            -- start from the order this zone was ranked with: today's state, not the projected one,
            -- but most of the route is the same (what is done or gone by then is left out)
            local ranked_ = (how and how.warmFrom and how.warmFrom[order[depth]]) or rankedPlan[order[depth]]
            local again = Zones.PlanZone(order[depth], cx2, nil, nil, { readOnly = true,
                warm = Zones.ITINERARY_WARM and ranked_ and (ranked_.searchOrder or ranked_.order) or false,
                weights = ranked_ and ranked_.search and ranked_.search.weights or nil })
            if #again.steps == 0 then
                for i = #order, depth, -1 do order[i] = nil end
                got = search(order, fixed, swap, nil, nil, how and how.lead)
                break
            end
            again.carried = carried
            swap[order[depth]] = again
            got = search(order, fixed, swap, nil, nil, how and how.lead)
            local seg = got and got.segments[depth]
            if not seg or not seg.leave then break end -- nothing follows: every zone in it is planned again
            fixed[depth] = seg.leave
            st, cx, plan, leave = after, cx2, again, seg.leave
        end
        return got
    end
    -- (planned again once: the same order left after the same step gives the same itinerary)
    local refinedOf = {}
    local function refined(cand)
        if not cand or #cand.segments < 2 or not cand.segments[1].leave then return cand end
        local maps = {}
        for i, seg in ipairs(cand.segments) do maps[i] = seg.map end
        local key = table.concat(maps, ">") .. "@" .. cand.segments[1].leave
        local got = refinedOf[key]
        if got == nil then got = refine(cand) or false; refinedOf[key] = got end
        return got or nil
    end
    local planOf = {}
    for _, z in ipairs(zones) do planOf[z.map] = z.plan end
    -- the itinerary to follow from `first` (nil: from any zone); it must beat staying in one zone
    local function pick(first)
        local top = { by = {}, list = {} }
        search(nil, nil, nil, nil, first, nil, top)
        local cands = top.list
        table.sort(cands, function(a, b) if a.xp ~= b.xp then return a.xp > b.xp end return a.at < b.at end)
        local alone = single
        if first then alone = search(nil, nil, nil, 1, first) end
        local kept
        if keptOrder and (not first or keptOrder[1] == first) then
            local raw
            local at = #keptOrder > 1 and keptLeave and keyIndex(planOf[keptOrder[1]].order, keptLeave)
            if at then pinLeave(planOf[keptOrder[1]], at); raw = search(keptOrder, { at }) end
            if not (raw and #raw.segments == #keptOrder) then raw = search(keptOrder) end
            if raw and #raw.segments == #keptOrder then kept = raw end
        end
        return Zones.Choose(cands, alone, kept, refined)
    end
    -- The path: from the shown zone while that has something left, else (or with PIN_SHOWN off, when
    -- another start earns more) from the best zone.
    local here
    local mine = opts.shown and pick(opts.shown) or nil
    local best = mine
    if not (mine and Zones.PIN_SHOWN) then
        local any = pick(nil)
        if any and not (mine and mine.xp >= any.xp) then best = any end
    end
    if not best then return nil end
    if mine then here = mine.xp end

    -- The way across the border planned together (Zones.SEAM). The stretch around the crossing (the
    -- winner's first zone's last steps before it is left, the trip, the next zone's first steps, and
    -- quests either zone left out near them) becomes one route, which starts as the itinerary has it
    -- and is searched for a while (Zones.PlanSeam); the rest of both routes stays. What it finds is
    -- judged as any itinerary: the first zone's route rebuilt with its stretch as found
    -- (Zones.WithSeam), the next zone planned from where that is left in the order found, the zone
    -- after it as it was. It replaces the winner only when it earns more inside the horizon (the way
    -- across on screen: no less). The choice of zones and their order stand.
    local seam, seamInfo
    local function sameRecipe(a, b)
        return a.zone == b.zone and a.to == b.to and a.leave == b.leave and a.leaveB == b.leaveB
            and sameIds(a.keys, b.keys) and sameIds(a.window, b.window)
            and sameIds(a.head or {}, b.head or {}) and sameIds(a.windowB or {}, b.windowB or {})
    end
    local function seamStep(cand)
        local seg1, seg2, seg3 = cand.segments[1], cand.segments[2], cand.segments[3]
        if not (seg1.leave and seg2) then return nil end
        local info = { stitchedXP = cand.xp }
        local A, B = seg1.map, seg2.map
        if Zones.Dungeon(A) or Zones.Dungeon(B) then info.gated = "dungeon"; return nil, nil, info end
        local planA, planB = seg1.plan, seg2.plan
        if planA.chain or #planB.steps == 0 then info.gated = "empty"; return nil, nil, info end
        local L = seg1.leave
        local LB = seg3 and seg2.leave or #planB.steps
        -- a way across judged as an itinerary: the first zone's route with it, the next zone planned
        -- from where that is left in the order found (exactly), the zone after it as it was
        local function judge(laid, recipe)
            local at = keyIndex(laid.order, recipe.leave)
            if not at then return nil end
            pinLeave(laid, at)
            local after, carried = project(state, ctx, laid, at, nil)
            after.checkpoint, after.memory = state.checkpoint, nil
            after.altRate = after.altRate or ctx.altRate
            local cx2 = Zones.Context(after)
            local orderB, used, late = {}, {}, {}
            local function put(k) if not used[k] then used[k] = true; orderB[#orderB + 1] = k end end
            for _, k in ipairs(recipe.windowB or {}) do late[k] = true end
            for _, k in ipairs(recipe.head or {}) do put(k); late[k] = nil end
            for _, k in ipairs(planB.order) do if not late[k] then put(k) end end
            for _, k in ipairs(recipe.windowB or {}) do put(k) end -- (left out of the stretch: after everything)
            local laidB = Zones.PlanZone(B, cx2, orderB, nil, { readOnly = true, exact = true })
            if #laidB.steps == 0 then return nil end
            laidB.carried = carried
            local atB = recipe.leaveB and keyIndex(laidB.order, recipe.leaveB)
            if atB then pinLeave(laidB, atB) end
            local order, swap = { A, B }, { [B] = laidB }
            if seg3 then order[3], swap[seg3.map] = seg3.map, seg3.plan end
            local got = search(order, { at }, swap, nil, nil, { [A] = laid })
            if not got or #got.segments < 2 then return nil end
            return got
        end
        -- the way across on screen, judged again as it stands (also when nothing else runs below)
        local was, keptGot = opts.seam, nil
        if was and was.zone == A and was.to == B then
            local laid = opts.seamPlan
            if not (laid and laid.seamBase == planA and laid.seamRecipe == was) then laid = Zones.WithSeam(A, ctx, planA, was) end
            if laid ~= planA then keptGot = judge(laid, was) end
            info.kept, info.keptXP = true, keptGot and keptGot.xp or nil
        end
        -- (the one on screen stays while it earns no less than the winner; a new one has to earn
        -- Zones.SEAM_GAIN more than both)
        local function decide(newGot, newRecipe)
            info.newXP = newGot and newGot.xp or nil
            local pick, recipe
            if keptGot and keptGot.xp >= cand.xp then pick, recipe = keptGot, was end
            if newGot and newGot.xp > cand.xp * (1 + Zones.SEAM_GAIN)
                and (not pick or newGot.xp > pick.xp * (1 + Zones.SEAM_GAIN)) then
                pick, recipe = newGot, newRecipe
            end
            if not pick then return nil, nil, info end
            info.won, info.gain = (recipe == was) and "kept" or "new", pick.xp - cand.xp
            info.leaveBefore, info.leaveAfter = seg1.seconds, pick.segments[1].seconds
            local out = { zone = recipe.zone, to = recipe.to, window = recipe.window, keys = recipe.keys,
                leave = recipe.leave, windowB = recipe.windowB, head = recipe.head, leaveB = recipe.leaveB,
                gain = math.floor(pick.xp - cand.xp) }
            return pick, out, info
        end
        -- only where it can matter: a short trip apart ...
        if seg2.travel - Planner.SWITCH_OVERHEAD > Zones.SEAM_TRIP then info.gated = "far"; return decide() end
        -- the stretch on each side: the steps that end within SEAM_SPAN of the crossing, at least
        -- SEAM_MIN_STOPS, at most SEAM_MAX_STOPS (never the step in hand: the shown zone's first)
        local tL, k = planA.steps[L].t, 0
        for i = L, 1, -1 do
            if k >= Zones.SEAM_MAX_STOPS then break end
            if k >= Zones.SEAM_MIN_STOPS and tL - planA.steps[i].t >= Zones.SEAM_SPAN then break end
            k = k + 1
        end
        local a0 = L - k + 1
        if opts.shown == A and a0 < 2 then a0 = 2 end
        if a0 > L then info.gated = "short"; return decide() end
        local b1 = 0
        for j = 1, LB do
            if b1 >= Zones.SEAM_MAX_STOPS then break end
            if b1 >= Zones.SEAM_MIN_STOPS and since(planB, j) > Zones.SEAM_SPAN then break end
            b1 = b1 + 1
        end
        local keysA, keysB = {}, {}
        for i = a0, L do keysA[#keysA + 1] = planA.order[i] end
        for j = 1, b1 do keysB[#keysB + 1] = planB.order[j] end
        info.windowA, info.windowB, info.keysA, info.keysB = #keysA, #keysB, keysA, keysB
        -- where each quest of the path has steps: before the stretch, in it (on either side), in the next
        -- zone's route after it, or after a zone is left
        local where, ids = {}, {}
        local function mark(id, field)
            local w = where[id]
            if not w then w = {}; where[id] = w; ids[#ids + 1] = id end
            w[field] = true
            return w
        end
        for i, st in ipairs(planA.steps) do
            local field = (i < a0 and "pre") or (i <= L and "wA") or "later"
            for _, q in ipairs(st.quests or {}) do
                local w = mark(q.id, field)
                if field == "wA" and st.kind == "turnin" then w.T = true end
            end
            if checkpoint then checkpoint() end
        end
        for j, st in ipairs(planB.steps) do
            local field = (j <= b1 and "wB") or (j <= LB and "suf") or "later"
            for _, q in ipairs(st.quests or {}) do
                local w = mark(q.id, field)
                if field == "wB" and st.kind == "turnin" then w.T = true end
            end
            if checkpoint then checkpoint() end
        end
        table.sort(ids)
        local side, ghost, after = {}, {}, {}
        local nA, nB, nFixed = 0, 0, 0
        for _, id in ipairs(ids) do
            local w = where[id]
            if w.suf then after[id] = true end
            if w.wA or w.wB then
                if w.T and not w.suf and not w.later then
                    side[id] = (w.wA and w.wB) and "X" or (w.wA and "A" or "B")
                    if side[id] == "A" then nA = nA + 1 elseif side[id] == "B" then nB = nB + 1 else nFixed = nFixed + 1 end
                else
                    ghost[id], nFixed = true, nFixed + 1
                end
            end
        end
        info.movableA, info.movableB, info.fixed = nA, nB, nFixed
        -- quests either zone left out that may come in: near the stretch, the nearest first
        local locs = {}
        for i = a0, L do locs[#locs + 1] = planA.steps[i].loc end
        for j = 1, b1 do locs[#locs + 1] = planB.steps[j].loc end
        local cands, seen = {}, {}
        local function consider(id, s, loc)
            local w = where[id]
            if seen[id] or (w and (w.pre or w.wA or w.wB or w.suf)) or (ctx.ignored and ctx.ignored[id]) or not loc then return end
            seen[id] = true
            local d = math.huge
            for _, l in ipairs(locs) do
                local x = Geo.Dist(loc, l)
                if x and x < d then d = x end
            end
            if d <= Zones.SEAM_REACH then cands[#cands + 1] = { id = id, side = s, d = d, loc = loc } end
        end
        for i = L + 1, #planA.steps do
            for _, q in ipairs(planA.steps[i].quests or {}) do consider(q.id, "A", planA.steps[i].loc) end
            if checkpoint then checkpoint() end
        end
        for _, e in ipairs(planA.lists and planA.lists.skipped or {}) do consider(e.id, "A", e.loc) end
        for j = LB + 1, #planB.steps do
            for _, q in ipairs(planB.steps[j].quests or {}) do consider(q.id, "B", planB.steps[j].loc) end
            if checkpoint then checkpoint() end
        end
        for _, e in ipairs(planB.lists and planB.lists.skipped or {}) do consider(e.id, "B", e.loc) end
        table.sort(cands, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
        for i = #cands, Zones.SEAM_FREE + 1, -1 do cands[i] = nil end
        local free = {}
        for _, q in ipairs(cands) do free[q.id] = q.side end
        info.free = #cands
        -- ... and something touching both zones: a step of the stretch in the other zone, a quest that
        -- may come in on one side located in the other, stops of the two sides within SEAM_NEAR yards,
        -- or a quest the first zone leaves out whose turn-in is outside it (a border candidate)
        local function zoneOf(loc)
            if not loc then return nil end
            if loc.map == A or loc.map == B then return loc.map end
            return Zones.ZoneAt(loc, { A, B })
        end
        local touch = false
        local nearA, nearB = {}, {}
        for i = a0, L do
            local loc = planA.steps[i].loc
            if zoneOf(loc) == B then touch = true end
            nearA[#nearA + 1] = loc
        end
        for j = 1, b1 do
            local loc = planB.steps[j].loc
            if zoneOf(loc) == A then touch = true end
            nearB[#nearB + 1] = loc
        end
        for _, q in ipairs(cands) do
            local z = zoneOf(q.loc)
            if (q.side == "A" and z == B) or (q.side == "B" and z == A) then touch = true end
            if q.side == "A" then nearA[#nearA + 1] = q.loc else nearB[#nearB + 1] = q.loc end
        end
        for _, a in ipairs(touch and {} or nearA) do
            for _, b in ipairs(nearB) do
                local d = Geo.Dist(a, b)
                if d and d <= Zones.SEAM_NEAR then touch = true; break end
            end
            if touch then break end
            if checkpoint then checkpoint() end
        end
        if not touch then
            for _, e in ipairs(planA.lists and planA.lists.skipped or {}) do
                if e.loc and e.loc.map == A and endsOutside(e.id, A) then touch = true; break end
            end
        end
        if not touch then info.gated = "apart"; return decide() end
        -- the stretch's start: the first zone followed up to the step before it (as `project` leaves it)
        local cx, t0
        if a0 > 1 then
            local st = project(state, ctx, planA, a0 - 1, nil)
            st.checkpoint, st.memory = state.checkpoint, nil
            st.altRate = st.altRate or ctx.altRate
            cx, t0 = Zones.Context(st), planA.steps[a0 - 1].t
        else
            local st = {}
            for key, v in pairs(state) do st[key] = v end
            st.memory, st.trace = nil, nil
            cx, t0 = Zones.Context(st), planA.overhead or 0
            cx.start = planA.from or cx.start
        end
        -- what follows the stretch: the next zone's rest of the route as it is, from the moment its
        -- first stop is reached, and the zone after it (as the itinerary's search would follow them)
        local tailB, planC = b1 < LB, seg3 and seg3.plan
        local xpWin = b1 > 0 and planB.steps[b1].cumXP or 0
        local function tail(t, loc)
            local best = 0
            if tailB then
                local s0, first = planB.steps[b1 + 1], planB.steps[1]
                local start = t + s0.seconds - s0.t + first.t - first.seconds
                best = untilHorizon(planB, start, H) - xpWin
                if planC then
                    local startC = start + since(planB, LB) + trip(planB.steps[LB].loc, planC)
                    if startC + Zones.MIN_STAY <= H then
                        local v = planB.steps[LB].cumXP - xpWin + untilHorizon(planC, startC, H)
                        if v > best then best = v end
                    end
                end
            elseif planC then
                local startC = t + trip(loc, planC)
                if startC + Zones.MIN_STAY <= H then best = untilHorizon(planC, startC, H) end
            end
            return best
        end
        local spec = { also = { B }, keysA = keysA, keysB = keysB, side = side, ghost = ghost, after = after, free = free,
            endLoc = tailB and planB.steps[b1 + 1].loc or nil, tail = (tailB or planC) and tail or nil,
            horizon = H, switch = Planner.SWITCH_OVERHEAD, rounds = Zones.SEAM_ROUNDS, work = Zones.SEAM_WORK,
            seed = (A % 100000) * 7919 + (B % 100000) * 6007 + (state.level or 1) * 104729 + #keysA * 131 + #keysB * 31 + 7 }
        part()
        local res, work = Zones.PlanSeam(A, cx, spec, t0)
        info.ran, info.work = true, work
        if not res then return decide() end
        info.proxyStart, info.proxyBest = res.start, res.value
        info.legBefore, info.legAfter = res.legStart, res.legBest
        info.changedA, info.changedB = not sameIds(res.keysA, keysA), not sameIds(res.keysB, keysB)
        local dA, dB = 0, 0
        for _, id in ipairs(res.out) do if side[id] == "A" then dA = dA + 1 else dB = dB + 1 end end
        info.deferredA, info.deferredB, info.added = dA, dB, #res.added
        -- (a figure under half the bar is not worth judging)
        if not (res.value > res.start + 0.5 * Zones.SEAM_GAIN * cand.xp) then return decide() end
        local leave = res.keysA[#res.keysA] or planA.order[a0 - 1]
        if not leave then return decide() end
        local recipe = { zone = A, to = B, window = keysA, keys = res.keysA, leave = leave, windowB = keysB, head = res.keysB,
            leaveB = seg3 and (tailB and planB.order[LB] or res.keysB[#res.keysB]) or nil }
        if was and sameRecipe(recipe, was) then return decide() end
        local laid = Zones.WithSeam(A, ctx, planA, recipe)
        if laid == planA then return decide() end
        return decide(judge(laid, recipe), recipe)
    end
    if Zones.SEAM then
        local got, s, info = seamStep(best)
        seamInfo = info
        if got then
            best, seam = got, s
            if opts.shown and best.segments[1].map == opts.shown then here = best.xp end
        end
    end

    -- Quests taken along across the border (Zones.BORDER). The winner's first zone is planned once
    -- more in its own order with the quests it can take along to the zones after it (accepted
    -- there, finished later: Zones.BorderQuests); the later zones are planned again from where it is
    -- left, where they find those quests in the log (see `project`); quests they do not use are
    -- left out again; and that itinerary replaces the winner when it earns more (a set already on
    -- screen: no less). The choice of zones, their order and the first moment to leave stand.
    local border
    local function takeAlong(cand)
        local seg1 = cand.segments[1]
        if not (seg1.leave and cand.segments[2]) or Zones.Dungeon(seg1.map) then return nil end
        local A, plainA = seg1.map, seg1.plan
        local leaveKey = plainA.order[seg1.leave]
        local later, warmFrom = {}, {}
        for i, seg in ipairs(cand.segments) do
            if i > 1 then
                warmFrom[seg.map] = seg.plan
                if not Zones.Dungeon(seg.map) then later[#later + 1] = seg.map end
            end
        end
        if #later == 0 then return nil end
        local list = Zones.BorderQuests(A, ctx, plainA, seg1.leave, later)
        if #list == 0 then return nil end
        local was = opts.border
        local function withThem(ids, to)
            -- (the route on screen is that already)
            if was and opts.borderPlan and opts.borderPlan.base == plainA and was.zone == A
                and was.before == leaveKey and sameIds(was.ids, ids) then return opts.borderPlan end
            local p = Zones.PlanZone(A, ctx, plainA.order, plainA.from, { readOnly = true,
                border = { zone = A, ids = ids, to = to, before = leaveKey } })
            p.base = plainA
            return p
        end
        local ids, to = {}, {}
        for i, q in ipairs(list) do ids[i], to[q.id] = q.id, q.to end
        local plan = withThem(ids, to)
        local at = keyIndex(plan.order, leaveKey)
        if not at or #(plan.borderIds or {}) == 0 then return nil end
        pinLeave(plan, at)
        local trial = { segments = { { map = A, plan = plan, leave = at } } }
        for i = 2, #cand.segments do trial.segments[i] = { map = cand.segments[i].map } end
        local got = refine(trial, { lead = { [A] = plan }, warmFrom = warmFrom, rounds = Zones.BORDER_ROUNDS })
        if not got or #got.segments < 2 then return nil end
        -- the quests a later zone does something with; the others are left out again
        local used = {}
        for i = 2, #got.segments do
            for _, step in ipairs(got.segments[i].plan.steps) do
                for _, q in ipairs(step.quests or {}) do used[q.id] = true end
            end
        end
        local keepIds, keepTo = {}, {}
        for _, id in ipairs(plan.borderIds) do
            if used[id] then keepIds[#keepIds + 1] = id; keepTo[id] = to[id] end
        end
        if #keepIds == 0 then return nil end
        if #keepIds < #plan.borderIds then
            local plan2 = withThem(keepIds, keepTo)
            local at2 = keyIndex(plan2.order, leaveKey)
            if not at2 or #(plan2.borderIds or {}) == 0 then return nil end
            pinLeave(plan2, at2)
            -- (the later zones stay as planned, so their moments to leave stand too)
            local order, swap, fixed2 = {}, {}, { at2 }
            for i, seg in ipairs(got.segments) do
                order[i] = seg.map
                if i > 1 then
                    swap[seg.map] = seg.plan
                    fixed2[i] = seg.leave
                end
            end
            got = search(order, fixed2, swap, nil, nil, { [A] = plan2 })
            if not got or #got.segments < 2 then return nil end
            plan, ids, to = plan2, keepIds, keepTo
        end
        -- (a set on screen stays while it earns no less; a new one has to earn Zones.BORDER_GAIN more)
        local kept = was and was.zone == A and within(ids, was.ids)
        if got.xp < cand.xp or (not kept and got.xp <= cand.xp * (1 + Zones.BORDER_GAIN)) then return nil end
        return got, { zone = A, ids = plan.borderIds, to = to, before = leaveKey, gain = math.floor(got.xp - cand.xp) }
    end
    if Zones.BORDER then
        local got, b = takeAlong(best)
        if got then
            best, border = got, b
            if opts.shown and best.segments[1].map == opts.shown then here = best.xp end
        end
    end

    -- Every ranked zone as the place to start: its route, then the best way on from where it is
    -- left, until the horizon. What a zone is worth then no longer hangs on one hour that the
    -- trip eats into: a short zone is not marked down for running out (the time left is spent in
    -- the next one), and a far zone pays its trip once, over the whole horizon. The plans are
    -- the ranked ones (nothing is planned again, also for the zone the itinerary starts in), so
    -- the figures compare with each other.
    -- The rate is over the time used, at least Planner.MIN_HORIZON: when the routes run out
    -- before the horizon and no other zone fits into what is left (a trip and Zones.MIN_STAY),
    -- that rest is not counted as earning nothing. Staying in the zone alone is tried too, and
    -- the better rate of the two is the zone's.
    -- The shown zone's entry is the path itself (its later zones planned again, the order on screen
    -- kept) when going on earns more per hour than the zone alone; else the zone alone. That way the
    -- list's shown row is the "Next" row's figure, with the same zone after it.
    local starts = {}
    local function rate(got)
        local used = 0
        for _, seg in ipairs(got.segments) do used = used + seg.travel + seg.seconds end
        return got.xp / math.max(math.min(used, H), Planner.MIN_HORIZON) * 3600
    end
    do
        local listed = {}
        for _, z in ipairs(zones) do listed[z.map] = true end
        for _, z in ipairs(ranked or {}) do
            if z.plan and #z.plan.steps > 0 then
                local extra = not listed[z.map]
                if extra then zones[#zones + 1] = { map = z.map, plan = z.plan } end -- (only ever the first zone: `first`)
                local got = search(nil, nil, nil, nil, z.map)
                local alone = search(nil, nil, nil, 1, z.map)
                if extra then zones[#zones] = nil end
                if alone and (not got or rate(alone) > rate(got)) then got = alone end
                if got then
                    starts[z.map] = { xp = math.floor(got.xp), rate = rate(got), next = got.segments[2] and got.segments[2].map or nil }
                end
            end
        end
    end
    if opts.shown and best.segments[1].map == opts.shown then
        local alone = search(nil, nil, nil, 1, opts.shown)
        local own = (alone and rate(alone) > rate(best)) and alone or best
        starts[opts.shown] = { xp = math.floor(own.xp), rate = rate(own),
            next = own.segments[2] and own.segments[2].map or nil, path = (own == best) or nil }
    end

    local out = { horizon = H, xp = math.floor(best.xp), rate = best.xp / H * 3600, stay = single and math.floor(single.xp) or nil,
        pathRate = rate(best), shown = opts.shown, here = here and math.floor(here) or nil, starts = starts,
        segments = {}, border = border, seam = seam, seamInfo = seamInfo }
    -- the zone the Zones tab lists first, when that is not the shown one
    if opts.shown and starts[opts.shown] then
        local order = Zones.StartOrder({ shown = opts.shown, starts = starts }, ranked, opts.shown)
        local top = order and order[1]
        if top and top.map ~= opts.shown and starts[opts.shown].rate > 0 and starts[top.map].rate > starts[opts.shown].rate then
            local st = starts[top.map]
            out.alt = { map = top.map, name = Zones.Name(top.map), xp = st.xp, rate = st.rate,
                gain = st.rate / starts[opts.shown].rate - 1, next = st.next }
        end
    end
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
