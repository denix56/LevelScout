-- core/Snapshot.lua: a snapshot of what a plan was made from and what the addon showed for it,
-- and the way back from that record to a planner state. Pure Lua: no game API, no os or io.
-- `/ls snapshot` (ns.Engine.Snapshot) fills it in game; tests/replay.lua plans it again outside.
--
-- A snapshot is plain data that the game can save with the character (LevelScoutCharDB.snapshots):
-- numbers (finite only), strings, booleans and tables of those. It holds no reference to any live
-- table, no function and no cycle. Format 1:
--
--   format, id, note, date, asked/saved (Game.Now), rankedAt (when the ranking was made)
--   version   { addon, client, data, generated, sources = { ForeverDB.., QuestieDB.. } }
--   settings  { [Module] = { [KEY] = value } }  the constants that shape a plan (Snapshot.Settings)
--   zone      the zone the ranking was asked to include (Zones.Rank's `always`)
--   input     the planning state (Snapshot.Capture; Snapshot.State turns it back into a state):
--             level, restedPool, xpBonus, xp, xpMax, maxLevel, raceId, faction, class, map, x, y,
--             capacity, groupSize, routeElite, routeEscort, tram, now, altRate (plain values),
--             log (the quest log, as the game gave it), bagQuests, pace, stepModel (plain copies),
--             completed, knownNodes, ignored ("12,3,1,40": sorted ids as differences),
--             drops ("item:npc:kills:drops;..."), tags and party ({ [questId] = answer } for the
--             quests in the log: the state asks for these through functions)
--   warm      { [map] = { order = "P:1,W:m2,...", weights } } the warm start each ranked zone got
--   itineraryWas, moveOnWas  what the itinerary and the banner were made after (the order of
--             zones shown before, and { suggest, map } of the banner before)
--   borderWas the set of quests taken along to the next zone that was on screen before the run
--             ({ zone, ids, to, before }, see Zones.Itinerary)
--   seamWas   the way across planned together that was on screen before the run (see Zones.Itinerary)
--   shown     what the addon showed for that run (Snapshot.View): ranked, plan (and how it was
--             made), itinerary, moveOn, chain
--   before    a light view of what was on screen when the command was typed
--   names     { [map] = name }, for reading the record
--
-- Only chat output is meant for people; the record is read by tests/replay.lua.

local _, ns = ...

local Snapshot = {}
ns.Snapshot = Snapshot

local floor, huge = math.floor, math.huge

Snapshot.FORMAT = 1
Snapshot.STEPS = 10        -- steps of the shown route kept in a view
Snapshot.LIGHT_STEPS = 5   -- ... in a light view
Snapshot.MAX_DEPTH = 8     -- tables nested deeper than this are left out of a copy
-- The modules whose constants shape a plan (ns.Memory's settingsKey lists the first eight), and
-- Engine's, which decide which route is shown.
Snapshot.MODULES = { "Planner", "Search", "Objective", "Zones", "Cost", "Model", "Travel", "Learn", "Memory", "Classes", "Engine" }

-- A number the game can save and read back: NaN and the infinities cannot be.
local function finite(n) return type(n) == "number" and n == n and n ~= huge and n ~= -huge end
local function num(n) if finite(n) then return n end end
local function str(s) if type(s) == "string" then return s end end

local function scalar(v)
    local t = type(v)
    return t == "string" or t == "boolean" or (t == "number" and finite(v))
end

---------------------------------------------------------------------------------------------
-- Plain copies
---------------------------------------------------------------------------------------------

local function copy(v, depth, open)
    local t = type(v)
    if t == "number" then return finite(v) and v or nil end
    if t == "string" or t == "boolean" then return v end
    if t ~= "table" or depth > Snapshot.MAX_DEPTH or open[v] then return nil end
    open[v] = true
    local out = {}
    for k, x in pairs(v) do
        local tk = type(k)
        if tk == "string" or (tk == "number" and finite(k)) then out[k] = copy(x, depth + 1, open) end
    end
    open[v] = nil
    return out
end

--- A deep plain copy: finite numbers, strings, booleans and tables of those. Keys that are not
--- strings or numbers, and functions, userdata and threads, are left out; so is a table met
--- again while it is being copied (a cycle) and anything nested deeper than Snapshot.MAX_DEPTH.
function Snapshot.Copy(v) return copy(v, 1, {}) end

---------------------------------------------------------------------------------------------
-- Encodings
---------------------------------------------------------------------------------------------

--- A set of ids as text: the ids sorted, each as the difference to the one before ("12,3,1,40").
--- Only whole numbers with a true value count.
function Snapshot.EncodeIds(set)
    local ids = {}
    for k, v in pairs(set or {}) do
        if v and finite(k) and k == floor(k) then ids[#ids + 1] = k end
    end
    table.sort(ids)
    local parts, prev = {}, 0
    for i, id in ipairs(ids) do
        parts[i] = string.format("%d", id - prev)
        prev = id
    end
    return table.concat(parts, ",")
end

function Snapshot.DecodeIds(text)
    local set, at = {}, 0
    for d in tostring(text or ""):gmatch("(%-?%d+)") do
        at = at + tonumber(d)
        set[at] = true
    end
    return set
end

--- A list of order keys ("P:12", "W:m3") as one string; nil for nil. The keys hold no commas.
function Snapshot.JoinList(list)
    if type(list) ~= "table" then return nil end
    local parts = {}
    for i, k in ipairs(list) do parts[i] = tostring(k) end
    return table.concat(parts, ",")
end

function Snapshot.SplitList(text)
    local out = {}
    if type(text) ~= "string" then return out end
    for k in text:gmatch("([^,]+)") do out[#out + 1] = k end
    return out
end

local function whole(n) -- an integer with %d, anything else exactly
    if n == floor(n) and n > -2 ^ 53 and n < 2 ^ 53 then return string.format("%d", n) end
    return string.format("%.17g", n)
end

--- The drop counts ({ ["item:npc"] = { k = kills, d = drops } }) as "item:npc:k:d;...", by key.
--- Only keys of the form item:npc count.
function Snapshot.EncodeDrops(store)
    local keys = {}
    for key, rec in pairs(type(store) == "table" and store or {}) do
        if type(key) == "string" and key:match("^%d+:%d+$") and type(rec) == "table" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local parts = {}
    for i, key in ipairs(keys) do
        local rec = store[key]
        parts[i] = key .. ":" .. whole(num(tonumber(rec.k)) or 0) .. ":" .. whole(num(tonumber(rec.d)) or 0)
    end
    return table.concat(parts, ";")
end

function Snapshot.DecodeDrops(text)
    local store = {}
    for item, npc, k, d in tostring(text or ""):gmatch("(%d+):(%d+):([^:;]+):([^:;]+)") do
        store[item .. ":" .. npc] = { k = tonumber(k) or 0, d = tonumber(d) or 0 }
    end
    return store
end

---------------------------------------------------------------------------------------------
-- The planning state
---------------------------------------------------------------------------------------------

local NUMBERS = { "level", "restedPool", "xpBonus", "xp", "xpMax", "maxLevel", "raceId", "map", "x", "y",
    "capacity", "groupSize", "now", "altRate", "speed", "ride" }
local STRINGS = { "faction", "class", "tram" }

--- The planning input of a state (as the Engine gathers it, see Zones.Context) as plain data.
--- The functions of a state are asked here, for the quests in its log: `tagOf` gives `tags`,
--- `partyOn` gives `party`. Nothing that is not set when planning starts (checkpoint, progress)
--- and nothing that holds plans (memory) is taken.
function Snapshot.Capture(state)
    local input = {}
    for _, k in ipairs(NUMBERS) do input[k] = num(state[k]) end
    for _, k in ipairs(STRINGS) do input[k] = str(state[k]) end
    if type(state.routeElite) == "boolean" then input.routeElite = state.routeElite end
    if type(state.routeEscort) == "boolean" then input.routeEscort = state.routeEscort end
    if state.rested == true then input.rested = true end
    input.log = Snapshot.Copy(state.log or {})
    if state.completed then input.completed = Snapshot.EncodeIds(state.completed) end
    if state.knownNodes then input.knownNodes = Snapshot.EncodeIds(state.knownNodes) end
    if state.ignored then input.ignored = Snapshot.EncodeIds(state.ignored) end
    if state.drops then input.drops = Snapshot.EncodeDrops(state.drops) end
    input.bagQuests = Snapshot.Copy(state.bagQuests)
    input.pace = Snapshot.Copy(state.pace)
    input.stepModel = Snapshot.Copy(state.stepModel)
    local tags, party = {}, {}
    for _, q in ipairs(input.log) do
        if type(state.tagOf) == "function" then
            local tag = state.tagOf(q.id)
            if tag ~= nil then tags[q.id] = Snapshot.Copy(tag) end
        end
        if type(state.partyOn) == "function" then
            local n = state.partyOn(q.id)
            if n ~= nil then party[q.id] = num(n) end
        end
    end
    input.tags, input.party = tags, party
    return input
end

--- A planner state from an input: a fresh table every call, ready for Zones.Context and
--- Zones.Itinerary. `tagOf` answers only for the quests in the log, as the game's does;
--- `partyOn` is always a function, nil when solo. There is no memory, checkpoint or progress.
function Snapshot.State(input)
    local state = {}
    for _, k in ipairs(NUMBERS) do state[k] = input[k] end
    for _, k in ipairs(STRINGS) do state[k] = input[k] end
    state.routeElite, state.rested = input.routeElite, input.rested
    state.routeEscort = input.routeEscort -- (old snapshots have none: off)
    state.log = Snapshot.Copy(input.log) or {}
    if input.completed then state.completed = Snapshot.DecodeIds(input.completed) end
    if input.knownNodes then state.knownNodes = Snapshot.DecodeIds(input.knownNodes) end
    if input.ignored then state.ignored = Snapshot.DecodeIds(input.ignored) end
    if input.drops then state.drops = Snapshot.DecodeDrops(input.drops) end
    state.bagQuests = Snapshot.Copy(input.bagQuests)
    state.pace = Snapshot.Copy(input.pace)
    state.stepModel = Snapshot.Copy(input.stepModel)
    local inLog = {}
    for _, q in ipairs(state.log) do inLog[q.id] = true end
    local tags, party = Snapshot.Copy(input.tags) or {}, Snapshot.Copy(input.party) or {}
    state.tagOf = function(id) if inLog[id] then return tags[id] end end
    state.partyOn = function(id) return party[id] end
    return state
end

--- A plan memory that hands out the warm starts the zones had in the game (see Memory.Seed):
--- every zone in `snap.warm` starts from its recorded order and weights, any other from scratch.
function Snapshot.Memory(snap)
    local mem = ns.Memory.New()
    for map, w in pairs(snap.warm or {}) do
        mem.zones[tonumber(map)] = { warm = { order = Snapshot.SplitList(w.order),
            weights = Snapshot.Copy(w.weights), count = 0 } }
    end
    return mem
end

---------------------------------------------------------------------------------------------
-- What was shown
---------------------------------------------------------------------------------------------

--- The constants that shape a plan: { [Module] = { [KEY] = value } }. Only upper-case names,
--- with a number, boolean or string, or a flat table of those, as value.
function Snapshot.Settings()
    local out = {}
    for _, name in ipairs(Snapshot.MODULES) do
        local mod = ns[name]
        local got = {}
        for k, v in pairs(type(mod) == "table" and mod or {}) do
            if type(k) == "string" and k:match("^[A-Z][A-Z0-9_]*$") then
                if scalar(v) then
                    got[k] = v
                elseif type(v) == "table" then
                    local flat = true
                    for k2, v2 in pairs(v) do
                        if not (scalar(v2) and (type(k2) == "string" or finite(k2))) then flat = false break end
                    end
                    if flat then got[k] = Snapshot.Copy(v) end
                end
            end
        end
        if next(got) then out[name] = got end
    end
    return out
end

--- The warm start each ranked zone was planned from: { [map] = { order, weights } }. A zone
--- handed out again from an earlier ranking (z.reused) was not planned here.
function Snapshot.Warm(ranked)
    local out = {}
    for _, z in ipairs(ranked or {}) do
        local p = z.plan
        if p and p.warmSeed and not z.reused then
            out[z.map] = { order = Snapshot.JoinList(p.warmSeed), weights = Snapshot.Copy(p.warmWeights) }
        end
    end
    return out
end

--- How a plan was made, from what Zones.PlanZone stamped on it (see there), as the recipe the
--- replay follows to make it again:
---   { kind = "chain" }                          a class quest chain
---   { kind = "seeded", seed, front, first }     a shown order kept, brought forward or pinned
---   { kind = "ranked" }                         the very plan of a ranked zone
---   { kind = "fresh", warm, weights }           planned for the zone on its own
--- With `border`, `borderFront` besides: quests taken along to the next zone, laid over the route
--- made by the rest of the recipe (Zones.WithBorder). With `seam`, `seamFront`: the way across planned
--- together, laid over the route made by the rest of the recipe (Zones.WithSeam), under the quests
--- taken along.
function Snapshot.Made(plan, ranked)
    if not plan then return nil end
    if plan.base and plan.seedBorder then
        -- quests taken along: the route without them, made as it was, then them over it
        local made = Snapshot.Made(plan.base, ranked) or {}
        made.border = Snapshot.Copy(plan.seedBorder)
        made.borderFront = Snapshot.JoinList(plan.seedFront)
        return made
    end
    if plan.seamBase and plan.seamRecipe then
        -- the way across planned together: the route without it, made as it was, then it over it
        local made = Snapshot.Made(plan.seamBase, ranked) or {}
        made.seam = Snapshot.Copy(plan.seamRecipe)
        made.seamFront = Snapshot.JoinList(plan.seedFront)
        return made
    end
    if plan.chain then return { kind = "chain" } end
    if plan.seedOrder then
        return { kind = "seeded", seed = Snapshot.JoinList(plan.seedOrder), front = Snapshot.JoinList(plan.seedFront),
            first = str(plan.seedFirst) }
    end
    for _, z in ipairs(ranked or {}) do
        if z.plan == plan then return { kind = "ranked" } end
    end
    return { kind = "fresh", warm = Snapshot.JoinList(plan.warmSeed), weights = Snapshot.Copy(plan.warmWeights) }
end

--- The zones of an itinerary, in order (what Zones.Itinerary reads of the one before), or nil.
function Snapshot.Maps(itinerary)
    if not (itinerary and itinerary.segments) then return nil end
    local out = {}
    for i, seg in ipairs(itinerary.segments) do out[i] = seg.map end
    return out
end

local function stepOf(plan, i)
    local s = plan.steps[i]
    local loc = s.loc or {}
    return { key = plan.order and str(plan.order[i]), kind = str(s.kind), xp = num(s.xp), t = num(s.t),
        travel = num(s.travel), seconds = num(s.seconds), map = num(loc.map), mx = num(loc.mx), my = num(loc.my),
        target = type(s.target) == "string" and s.target or nil }
end

local function planOf(plan, light)
    local out = { zone = num(plan.zone), score = num(plan.score), rate = num(plan.rate), value = num(plan.value),
        xp = num(plan.xp), seconds = num(plan.seconds), quests = num(plan.quests), peak = num(plan.peak),
        count = #plan.steps, steps = {} }
    if not light then out.order = Snapshot.JoinList(plan.order) end
    for i = 1, math.min(#plan.steps, light and Snapshot.LIGHT_STEPS or Snapshot.STEPS) do out.steps[i] = stepOf(plan, i) end
    return out
end

local function itineraryOf(it, light)
    local out = { horizon = num(it.horizon), xp = num(it.xp), rate = num(it.rate), stay = num(it.stay), here = num(it.here),
        shown = num(it.shown), segments = {} }
    if it.alt then out.alt = { map = num(it.alt.map), xp = num(it.alt.xp), next = num(it.alt.next) } end
    for i, seg in ipairs(it.segments or {}) do
        out.segments[i] = { map = num(seg.map), travel = num(seg.travel), seconds = num(seg.seconds), xp = num(seg.xp),
            leave = num(seg.leave), leaveKey = str(seg.leaveKey), carried = num(seg.carried), carriedXP = num(seg.carriedXP) }
    end
    if it.starts and not light then
        out.starts = {}
        for map, s in pairs(it.starts) do out.starts[map] = { xp = num(s.xp), rate = num(s.rate), next = num(s.next) } end
    end
    return out
end

--- A plain summary of a view (Engine.view, or a table with the same fields: ranked, plan, zone,
--- itinerary, moveOn, chain). `light`: shorter (no routes as order strings, fewer steps, no
--- recipe, no `starts`), for what was on screen before a snapshot.
function Snapshot.View(view, light)
    local out = { status = str(view.status), zone = num(view.zone), zoneName = str(view.zoneName),
        level = num(view.level), here = num(view.here), ranked = {} }
    for i, z in ipairs(view.ranked or {}) do
        local p = z.plan
        out.ranked[i] = { map = num(z.map), score = num(p.score), rate = num(p.rate), value = num(p.value), xp = num(p.xp),
            seconds = num(p.seconds), quests = num(p.quests), steps = #p.steps, peak = num(p.peak),
            forced = z.forced or nil, dungeon = z.dungeon or nil, reused = z.reused or nil,
            warm = p.search and p.search.warm or nil, order = (not light) and Snapshot.JoinList(p.order) or nil }
    end
    if view.plan then
        out.plan = planOf(view.plan, light)
        if not light then out.made = Snapshot.Made(view.plan, view.ranked) end
    end
    if view.itinerary then out.itinerary = itineraryOf(view.itinerary, light) end
    local m = view.moveOn
    if m then out.moveOn = { suggest = m.suggest and true or false, map = num(m.map), gain = num(m.gain), horizon = num(m.horizon) } end
    local c = view.chain
    if c then out.chain = { id = num(c.id), kind = str(c.kind), name = str(c.name) } end
    return out
end
