-- core/Memory.lua: plan memory. Pure Lua; owned by the Engine, handed to the planner through
-- the state (state.memory -> ctx.memory). Two uses:
--   1. Reuse: a zone's plan is kept and handed out again at the next ranking when nothing it
--      depends on has moved enough to matter (Memory.Reusable / Memory.Store).
--   2. Warm start: the last plan made for a zone (its order and the search's operator weights)
--      seeds the next search of that zone (Memory.Seed / Memory.Remember).
-- Nothing here is saved between sessions. Without a memory (tests, bench) the planner behaves
-- as it always did.
--
-- What a reused plan may be off by (the user's decision): XP and rested pool moved by less
-- than XP_TOLERANCE of a level, learned figures by less than LEARN_TOLERANCE, never older than
-- Zones.REUSE_MAX_AGE. Anything discrete (level, flight paths, group size, ignored quests, XP
-- bonus, the quests the plan read) must be equal. The continuous inputs are compared with the
-- values the plan was made with, so the drift cannot build up over several reuses.
local _, ns = ...
local Memory = {}
ns.Memory = Memory

local floor, abs, max = math.floor, math.abs, math.max

Memory.XP_TOLERANCE = 0.10    -- of the level's XP: the XP still needed and the rested pool
Memory.LEARN_TOLERANCE = 0.02 -- relative, for learned paces, factors and drop biases
Memory.WEIGHT_TOLERANCE = 0.02 -- absolute, for the step-time model's weights
Memory.PRUNE_AGE = 1800       -- seconds: a stored plan nobody asked for in this long is dropped
Memory.POSITION_CELL = 2      -- start positions are told apart by cells of this many map percent

function Memory.New() return { zones = {}, version = 1 } end

function Memory.Reset(mem)
    if not mem then return end
    mem.zones = {}
    mem.version = (mem.version or 0) + 1
end

local function sortedKeys(t, filter)
    local keys = {}
    for k, v in pairs(t or {}) do
        if not filter or filter(k, v) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        return a < b
    end)
    return keys
end

-- Every plain setting of the modules that decide how a plan is made: a changed constant (in
-- tests, in the bench) never meets a plan made with another.
local SETTING_MODULES = { "Planner", "Search", "Objective", "Zones", "Cost", "Model", "Travel", "Learn" }
local function settingsKey()
    local parts = {}
    for _, name in ipairs(SETTING_MODULES) do
        local mod = ns[name]
        if type(mod) == "table" then
            for _, k in ipairs(sortedKeys(mod, function(k, v)
                local t = type(v)
                return type(k) == "string" and (t == "number" or t == "boolean" or t == "string")
            end)) do
                parts[#parts + 1] = name .. "." .. k .. "=" .. tostring(mod[k])
            end
        end
    end
    return table.concat(parts, ";")
end

-- The continuous inputs: { unit, xp (XP still needed for the next level-up), rested (bonus XP
-- left; nil when unlimited), vec = { { name, value, abs } ... } sorted by name }.
local function continuous(ctx)
    local ups = ctx.levelUps or {}
    local width = ups[2] and (ups[2] - ups[1]) or ups[1] or 1
    local c = { unit = max(1, Memory.XP_TOLERANCE * width), xp = ups[1], vec = {} }
    if ctx.restedBonus and ctx.restedBonus ~= math.huge then c.rested = ctx.restedBonus end
    local vec = c.vec
    for _, k in ipairs(sortedKeys(ctx.pace, function(_, v) return type(v) == "number" end)) do
        vec[#vec + 1] = { "pace." .. tostring(k), ctx.pace[k] }
    end
    local model = ctx.stepModel
    if type(model) == "table" and (tonumber(model.n) or 0) > 0 then
        vec[#vec + 1] = { "travel", ns.Learn.TravelFactor(model) }
        vec[#vec + 1] = { "talk", ns.Learn.TalkFactor(model) }
        for _, k in ipairs(sortedKeys(model.w, function(_, v) return type(v) == "number" end)) do
            vec[#vec + 1] = { "w." .. tostring(k), model.w[k], true }
        end
    end
    for _, k in ipairs(sortedKeys(ctx.dropBias, function(_, v) return type(v) == "table" end)) do
        local t = ctx.dropBias[k]
        vec[#vec + 1] = { "bias." .. tostring(k), ((t.d or 0) + 1) / ((t.x or 0) + 1) }
    end
    return c
end
Memory.Continuous = continuous

--- Are two sets of continuous inputs close enough for a plan made with `a` to stand for `b`?
function Memory.Close(a, b)
    if (a.xp == nil) ~= (b.xp == nil) then return false end
    if a.xp and abs(a.xp - b.xp) >= a.unit then return false end
    if (a.rested == nil) ~= (b.rested == nil) then return false end
    if a.rested and abs(a.rested - b.rested) >= a.unit then return false end
    if #a.vec ~= #b.vec then return false end
    for i, x in ipairs(a.vec) do
        local y = b.vec[i]
        if x[1] ~= y[1] then return false end
        if x[3] then
            if abs(x[2] - y[2]) > Memory.WEIGHT_TOLERANCE then return false end
        elseif abs(x[2] - y[2]) > Memory.LEARN_TOLERANCE * max(abs(x[2]), abs(y[2])) + 1e-12 then
            return false
        end
    end
    return true
end

local function idList(set)
    local ids = {}
    for k, v in pairs(set or {}) do
        if v then ids[#ids + 1] = k end
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

--- The discrete inputs shared by every zone's plan, as one string (continuous ones are compared
--- by Memory.Close, only their presence and names are in here).
function Memory.GlobalKey(ctx)
    local c = continuous(ctx)
    local names = {}
    for i, e in ipairs(c.vec) do names[i] = e[1] end
    local avail = ctx.avail or {}
    local rested = ctx.restedBonus == math.huge and "inf" or ((ctx.restedBonus or 0) > 0 and "r" or "0")
    local key = table.concat({
        "L" .. tostring(ctx.level), tostring(ctx.side), tostring(avail.class), tostring(avail.raceId), tostring(avail.faction),
        c.xp and "x" or "cap", rested,
        string.format("%.3f", ctx.xpBonus or 0), "g" .. tostring(ctx.group), tostring(ctx.routeElite), "esc" .. tostring(ctx.routeEscort), "tram" .. tostring(ctx.tram),
        "cap" .. tostring(ctx.capacity), "sp" .. tostring(ctx.speed),
        "sr" .. tostring(ctx.searchRounds) .. "/" .. tostring(ctx.searchWork),
        "f" .. idList(ctx.knownNodes),
        "b" .. idList(ctx.bagQuests), -- quests an item in the bags starts
        table.concat(names, ","),
        settingsKey(),
    }, "|")
    -- The hearthstone (Planner.HEARTH): where it is bound (in cells of 2% of the map), when it is ready
    -- (in 5 minutes) and its cooldown. The settings key already covers Planner.HEARTH*.
    local st = ctx.stone
    if st then
        local loc = st.loc or {}
        key = key .. "|h" .. tostring(loc.map) .. ":" .. floor((loc.mx or 0) / 2) .. ":" .. floor((loc.my or 0) / 2)
            .. ":" .. (st.ready > 0 and floor(st.ready / 300) or "r") .. ":" .. tostring(st.cd)
    end
    return key
end

local function cell(loc)
    if not loc then return "-" end
    local n = Memory.POSITION_CELL
    return tostring(loc.map) .. ":" .. floor((loc.mx or 0) / n) .. ":" .. floor((loc.my or 0) / n)
end

--- The key of one zone's plan: the global key, the zone, where it is left from (`from`, else the
--- context's start, in cells of 2% of the map), and the map we stand in.
function Memory.ZoneKey(ctx, map, from)
    return Memory.GlobalKey(ctx) .. "||" .. tostring(map) .. "|" .. cell(from or ctx.start) .. "|" .. tostring(ctx.startMap)
end

--- Quests whose state the plan depends on: `ids` (a set, or a list) and what
--- Data.IsAvailable reads about them. Sorted, without duplicates.
function Memory.Watch(ids)
    local seen, out = {}, {}
    local function add(id)
        if id and id ~= 0 and not seen[id] then seen[id] = true; out[#out + 1] = id end
    end
    local list = {}
    if ids[1] ~= nil then
        for _, id in ipairs(ids) do list[#list + 1] = id end
    else
        for id, v in pairs(ids) do if v then list[#list + 1] = id end end
    end
    table.sort(list)
    for _, id in ipairs(list) do
        add(id)
        local q = ns.Data.GetQuest(id)
        if q then
            for _, pre in ipairs(q.preAll or {}) do add(pre) end
            for _, pre in ipairs(q.preAny or {}) do add(pre) end
            for _, ex in ipairs(q.exclusive or {}) do add(ex) end
            add(q.nextInChain); add(q.breadcrumbFor); add(q.parent)
        end
    end
    table.sort(out)
    return out
end

local function entrySig(e, id, ctx)
    local parts = { tostring(e.level), tostring(e.rewardXP), e.isComplete and "C" or "", e.isFailed and "F" or "" }
    for _, o in ipairs(e.objectives or {}) do
        parts[#parts + 1] = tostring(o.have) .. "/" .. tostring(o.need) .. (o.finished and "!" or "")
    end
    if ctx.partyOn then parts[#parts + 1] = "p" .. tostring(ctx.partyOn(id)) end
    if ctx.tagOf then parts[#parts + 1] = "t" .. tostring(ctx.tagOf(id)) end
    return table.concat(parts, ",")
end

--- The state of the quests a plan read, as a string: for each id of `watch` that is completed,
--- in the log or ignored, the id with what it is, and for `used` ids (log quests the plan worked
--- with) also their progress. (Ignored quests are here and not in the global key: ignoring a
--- quest of one zone leaves the plans of the others alone.)
function Memory.QuestSig(ctx, watch, used)
    local completed = (ctx.avail and ctx.avail.completed) or {}
    local log = ctx.log or {}
    local ignored = ctx.ignored or {}
    local out = {}
    for i, id in ipairs(watch) do
        local c, e, ign = completed[id], log[id], ignored[id]
        if c or e or ign then
            local s = id .. (c and "c" or "") .. (ign and "i" or "")
            if e then s = s .. "l" .. (used and used[id] and ("[" .. entrySig(e, id, ctx) .. "]") or "") end
            out[#out + 1] = s
        end
        if ctx.checkpoint and i % 64 == 0 then ctx.checkpoint() end
    end
    return table.concat(out, ";")
end

-- Peak number of quests held at once along the plan, relative to the log count at planning time.
local function heldAbove(plan)
    local held, peak = 0, 0
    for _, step in ipairs(plan.steps or {}) do
        if step.kind == "accept" then held = held + 1 elseif step.kind == "turnin" then held = held - 1 end
        if held > peak then peak = held end
    end
    return peak
end

-- Is the log quest `id` (new since the plan was made) one this zone's plan would have worked on?
-- The same test as the planner's own: its turn-in or one of its tasks is on the zone's map.
local function relevantNewLogQuest(ctx, map, id)
    local Zones = ns.Zones
    local near = ctx.near
    ctx.near = Zones and Zones.EntryPoint(map, ctx.side) or ctx.start
    local m = ns.Model.Build(id, ctx)
    ctx.near = near
    if not m then return false end
    if m.turnin and m.turnin.map == map then return true end
    for _, t in ipairs(m.tasks or {}) do
        if t.loc and t.loc.map == map then return true end
    end
    return false
end

--- The stored plan of `map` when it still stands for the state in `ctx`, else nil and why not
--- ("none", "age", "key", "close", "log room", "quests", "new log quest").
function Memory.Reusable(mem, ctx, map, from)
    local entry = mem and mem.zones[map]
    local reuse = entry and entry.reuse
    if not reuse then return nil, "none" end
    if (ctx.now or 0) - reuse.at > (ns.Zones.REUSE_MAX_AGE or 300) then return nil, "age" end
    if reuse.key ~= Memory.ZoneKey(ctx, map, from) then return nil, "key" end
    if not Memory.Close(reuse.cont, continuous(ctx)) then return nil, "close" end
    -- the log has room for what the plan holds, or not, as before
    local capacity = ctx.capacity
    if capacity and (((ctx.logCount or 0) + reuse.held > capacity) ~= reuse.plan.logFull) then return nil, "log room" end
    if reuse.sig ~= Memory.QuestSig(ctx, reuse.watch, reuse.used) then return nil, "quests" end
    -- a quest in the log that the plan never looked at: does it belong to this zone?
    if not reuse.dungeon then
        local seen = reuse.logSeen
        for _, id in ipairs(sortedKeys(ctx.log)) do
            if not seen[id] then
                if relevantNewLogQuest(ctx, map, id) then return nil, "new log quest" end
                seen[id] = true
            end
        end
    end
    reuse.touched = ctx.now or 0
    return reuse.plan
end

--- Keep `plan` (just made for `map` from `from` under `ctx`) for Reusable. Entries nobody has
--- asked for in PRUNE_AGE seconds are dropped.
function Memory.Store(mem, ctx, map, from, plan)
    if not mem or not plan.inputs then return end
    local now = ctx.now or 0
    for _, e in pairs(mem.zones) do
        if e.reuse and now - (e.reuse.touched or e.reuse.at) > Memory.PRUNE_AGE then e.reuse = nil end
    end
    local inputs = plan.inputs
    local watch = Memory.Watch(inputs.ids)
    local entry = mem.zones[map]
    if not entry then entry = {}; mem.zones[map] = entry end
    entry.reuse = {
        key = Memory.ZoneKey(ctx, map, from), at = now, touched = now, plan = plan,
        cont = continuous(ctx), watch = watch, used = inputs.used, logSeen = inputs.logSeen or {},
        sig = Memory.QuestSig(ctx, watch, inputs.used), held = heldAbove(plan),
        dungeon = ns.Zones.Dungeon(map) ~= nil,
    }
end

--- The previous plan's order and operator weights for `map`, or nil when there is none or the
--- zone is due for a plan from scratch (every REFRESH_EVERY + 1st).
function Memory.Seed(mem, map)
    local entry = mem and mem.zones[map]
    local warm = entry and entry.warm
    if not warm or #warm.order == 0 then return nil end
    if warm.count >= (ns.Zones.REFRESH_EVERY or 4) then return nil end
    return warm.order, warm.weights
end

--- Keep the order (the route the search ended on, else the plan's order) and weights of a plan just made for `map`; `warmUsed` is whether it was
--- started from a seed (the count of warm plans in a row decides when to plan from scratch).
function Memory.Remember(mem, map, plan, warmUsed)
    local order = plan.searchOrder or plan.order
    if not mem or not order or #order == 0 then return end
    local entry = mem.zones[map]
    if not entry then entry = {}; mem.zones[map] = entry end
    local count = entry.warm and entry.warm.count or 0
    entry.warm = { order = order, weights = plan.search and plan.search.weights or nil,
        count = warmUsed and (count + 1) or 0 }
end

return Memory
