-- adapters/Data.lua
--
-- The only reader of LevelScout's quest, NPC, object and item data. Records are compact strings
-- (layouts: docs/data-format.md), parsed on first use and cached. They come from one of two
-- record sources:
--   merge    the shipped one: adapters/Merge.lua builds each record when it is first needed
--            from the installed QuestieDB addon (LibQuestieDB, required) and the baked
--            ForeverDB layer (LevelScout/data, ns.data.fdb); the packed string is kept.
--   records  ready-made records in ns.data.quests/npcs/objects/items/questText/questSpots, as
--            the unit tests' fixtures provide them.
-- Pure Lua: no WoW API calls here (the player context is passed in, LibQuestieDB is a table),
-- so the whole module runs in the standalone test harness.

local _, ns = ...

local Data = {}
ns.Data = Data

local floor, tonumber, concat = math.floor, tonumber, table.concat

Data.EXPECTED_FIELDS = { quest = 30, npc = 7, object = 2, item = 4 }

local KIND = { c = "kill", o = "object", i = "item", e = "event", r = "reputation", x = "other" }
local COUNT_SOURCE = { C = "CMaNGOS", F = "ForeverDB", Q = "QuestieDB" }
local XP_SOURCE = { f = "ForeverDB", q = "QuestieDB" }
local RATE_SOURCE = { f = "ForeverDB", c = "QuestieDB correction", m = "CMaNGOS", w = "Wowhead", k = "CMaNGOS" }
local FLAG = { d = "dungeon", r = "raid", g = "group", p = "repeatable", y = "daily", w = "weekly",
    n = "new", u = "unseen", v = "event" }

---------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------

local function split(s, sep)
    local out, start = {}, 1
    sep = sep or "|"
    while true do
        local a = s:find(sep, start, true)
        if not a then out[#out + 1] = s:sub(start); return out end
        out[#out + 1] = s:sub(start, a - 1)
        start = a + #sep
    end
end

local function ids(s)
    local out = {}
    for n in (s or ""):gmatch("%d+") do out[#out + 1] = tonumber(n) end
    return out
end

local function num(s) return tonumber(s) end

--- Decode one packed map spot: uiMapID, x, y (0-100).
function Data.DecodeSpot(token)
    local n = tonumber(token, 36)
    if not n then return nil end
    local map = floor(n / 1e6)
    local r = n % 1e6
    return map, floor(r / 1e3) / 10, (r % 1e3) / 10
end

local function spots(s)
    local out = {}
    for token in (s or ""):gmatch("%S+") do
        local map, x, y = Data.DecodeSpot(token)
        if map then out[#out + 1] = { map = map, x = x, y = y } end
    end
    return out
end

local function hasBit(value, bit)
    if not value or not bit or bit <= 0 then return false end
    return floor(value / bit) % 2 == 1
end

-- a & b for integers up to 2^53 (race masks use bits 32 and 33).
local function band(a, b)
    local result, bit = 0, 1
    a, b = a or 0, b or 0
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then result = result + bit end
        a, b, bit = floor(a / 2), floor(b / 2), bit * 2
    end
    return result
end
Data.band = band

---------------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------------

local D        -- ns.data
local world    -- ns.data.world (in merge mode with QuestieDB's enums and the computed tables)
local mode     -- "merge" or "records" (see the top of this file)
local packed   -- merge mode: [tableName][id] = packed record, or false when there is none
local questText, questSpots -- merge mode: what Merge.Quest returned beside each quest record
local cache

-- World tables computed from every quest's record, so they exist only once the index has read
-- them all (Data.BuildIndex). Read before that, they build the index on the spot.
local COMPUTED = { dungeons = true, xpEstimate = true }
local worldMeta = { __index = function(t, key)
    if COMPUTED[key] and mode == "merge" and Data.usable then
        Data.BuildIndex()
        return rawget(t, key)
    end
end }

-- The merge's records depend only on QuestieDB (and the corrections it applied for one faction
-- and class) and the ForeverDB layer. They are kept by those, so a second Init for the same
-- character (in the game: never; in the tests: often) does not build them again.
-- [lib][fdb][faction:class] = { packed, questText, questSpots }
local recordSets = setmetatable({}, { __mode = "k" })

local function useRecords(lib, fdb, player)
    local byFdb = recordSets[lib]
    if not byFdb then byFdb = setmetatable({}, { __mode = "k" }); recordSets[lib] = byFdb end
    local byPlayer = byFdb[fdb]
    if not byPlayer then byPlayer = {}; byFdb[fdb] = byPlayer end
    local key = tostring(player.faction) .. ":" .. tostring(player.class)
    local set = byPlayer[key]
    if not set then
        set = { packed = { quests = {}, npcs = {}, objects = {}, items = {} }, questText = {}, questSpots = {} }
        byPlayer[key] = set
    end
    packed, questText, questSpots = set.packed, set.questText, set.questSpots
end

local function reset()
    cache = { quest = {}, npc = {}, object = {}, item = {} }
    packed = { quests = {}, npcs = {}, objects = {}, items = {} }
    questText, questSpots = {}, {}
    Data._index = nil
end

local function fail(st, state, message)
    st.state, st.message = state, message
    Data.usable = false
    return false
end

--- Check the data and QuestieDB and connect the record source.
--- `player` = { faction = "Alliance"|"Horde", class = "WARRIOR"|..., clientBuild = "1.60.1.70888" }
--- (QuestieDB has already applied its corrections for the logged-in character; the player
--- context is kept for the client build note and for callers.)
--- `lib` = LibQuestieDB (default: the global; nil when QuestieDB is not loaded).
--- Returns true when the data is usable; Data.status explains problems either way:
--- state "ok", "missing"/"broken" (LevelScout's own files), or "questiedb-missing",
--- "questiedb-version", "questiedb-broken" (the required QuestieDB addon).
function Data.Init(player, lib)
    player = player or {}
    if lib == nil then lib = rawget(_G, "LibQuestieDB") end
    reset()
    D = ns.data
    mode, world = nil, nil
    local st = { state = "ok", notes = {} }
    Data.status = st
    if type(D) ~= "table" or type(D.meta) ~= "table" or (type(D.quests) ~= "table" and type(D.fdb) ~= "table") then
        return fail(st, "missing", "LevelScout's data files are missing; reinstall the addon")
    end
    local need = type(D.quests) == "table" and { "questText", "questSpots", "npcs", "objects", "items", "world" }
        or { "world" }
    for _, name in ipairs(need) do
        if type(D[name]) ~= "table" then
            return fail(st, "broken", "data table '" .. name .. "' is missing; reinstall the addon")
        end
    end
    st.build = D.meta.build
    st.generated = D.meta.generated
    st.sources = {}
    for k, v in pairs(D.meta.sources or {}) do st.sources[k] = v end
    world = D.world
    if type(D.quests) == "table" then
        mode = "records"
    else
        local Merge = ns.Merge
        local ok, state, message, have = Merge.Check(lib)
        if not ok then return fail(st, "questiedb-" .. state, message) end
        local opened, err = Merge.Open(lib, D.fdb)
        if not opened then return fail(st, "broken", err) end
        mode = "merge"
        useRecords(lib, D.fdb, player)
        st.sources.QuestieDB = have
        for name in pairs(COMPUTED) do rawset(world, name, nil) end
        world.enum = Merge.Enum()
        setmetatable(world, worldMeta)
    end
    st.mode = mode
    if player.clientBuild and D.meta.build and player.clientBuild ~= D.meta.build then
        st.notes[#st.notes + 1] = string.format(
            "data was made for client %s, this client is %s; some quests may be missing or changed",
            D.meta.build, player.clientBuild)
    end
    Data.player = player
    Data.usable = true
    return true
end

-- The packed record of a quest/NPC/object/item. In merge mode it is built the first time and
-- kept (a quest's text and spots with it).
local BUILD = { npcs = "Npc", objects = "Object", items = "Item" }
local function raw(tableName, id)
    if mode == "records" then return D[tableName][id] end
    local t = packed[tableName]
    local rec = t[id]
    if rec == nil then
        if tableName == "quests" then
            local text, spots
            rec, text, spots = ns.Merge.Quest(id)
            questText[id], questSpots[id] = text, spots
        else
            rec = ns.Merge[BUILD[tableName]](id)
        end
        rec = rec or false
        t[id] = rec
    end
    return rec or nil
end

local function spotsOf(id)
    if mode == "records" then return D.questSpots[id] end
    raw("quests", id)
    return questSpots[id]
end

local function textOf(id)
    if mode == "records" then return D.questText[id] end
    raw("quests", id)
    return questText[id]
end

--- Every quest id, ascending (a fresh list).
function Data.QuestIds()
    local out = {}
    if mode == "merge" then
        for i, id in ipairs(ns.Merge.QuestIds()) do out[i] = id end
    elseif mode == "records" then
        for id in pairs(D.quests) do out[#out + 1] = id end
        table.sort(out)
    end
    return out
end

--- The packed record behind a getter, for debugging and the tests: tableName is "quests",
--- "npcs", "objects", "items", "questText" or "questSpots".
function Data.Raw(tableName, id)
    if not Data.usable then return nil end
    if tableName == "questText" then return textOf(id) end
    if tableName == "questSpots" then return spotsOf(id) end
    return raw(tableName, id)
end

-- (The builders are plain functions of the id, made once: a closure per lookup was garbage on
-- every call, and the planner looks records up thousands of times a plan.)
local function cached(kind, id, build)
    if not Data.usable or type(id) ~= "number" then return nil end
    local hit = cache[kind][id]
    if hit ~= nil then return hit or nil end
    local value = build(id)
    cache[kind][id] = value or false
    return value
end

---------------------------------------------------------------------------------------------
-- Entities
---------------------------------------------------------------------------------------------

--- { id, name, minLevel, maxLevel, rank (0 normal, 1 elite, 2 rare elite, 3 boss, 4 rare),
---   npcFlags, friendly ("A", "H", "AH" or ""), spots = { {map, x, y}, ... } }
local function buildNpc(id)
    local rec = raw("npcs", id)
    if not rec then return nil end
    local f = split(rec)
    return { id = id, name = f[1], minLevel = num(f[2]) or 0, maxLevel = num(f[3]) or 0, rank = num(f[4]) or 0,
        npcFlags = num(f[5]) or 0, friendly = f[6] or "", spots = spots(f[7]) }
end
function Data.GetNpc(id) return cached("npc", id, buildNpc) end

local function buildObject(id)
    local rec = raw("objects", id)
    if not rec then return nil end
    local f = split(rec)
    return { id = id, name = f[1], spots = spots(f[2]) }
end
function Data.GetObject(id) return cached("object", id, buildObject) end

local function sources(s)
    local out = {}
    for entry in (s or ""):gmatch("%S+") do
        local id, rate, src = entry:match("^(%d+):([%d%.]*):(%a*)$")
        if id then
            out[#out + 1] = { id = tonumber(id), rate = tonumber(rate) and tonumber(rate) / 100 or nil,
                source = RATE_SOURCE[src] }
        end
    end
    return out
end

--- { id, name, drops = { {id = npcId, rate = 0..1|nil, source}, ... }, objects = {...}, vendors = {...} }
local function buildItem(id)
    local rec = raw("items", id)
    if not rec then return nil end
    local f = split(rec)
    return { id = id, name = f[1], drops = sources(f[2]), objects = sources(f[3]), vendors = ids(f[4]) }
end
function Data.GetItem(id) return cached("item", id, buildItem) end

--- Database drop chance (0..1) of an item from an NPC, and its source; nil when unknown.
function Data.GetDropRate(itemId, npcId)
    local item = Data.GetItem(itemId)
    for _, d in ipairs(item and item.drops or {}) do
        if d.id == npcId then return d.rate, d.source end
    end
    return nil
end

---------------------------------------------------------------------------------------------
-- Quests
---------------------------------------------------------------------------------------------

local function givers(s)
    local out = {}
    for kind, id in (s or ""):gmatch("([noi])(%d+)") do
        out[#out + 1] = { kind = (kind == "n" and "npc") or (kind == "o" and "object") or "item", id = tonumber(id) }
    end
    return out
end

local function pair(s)
    local a, b = (s or ""):match("^(%-?%d+):(%-?%d*)$")
    if not a then return nil end
    return { id = tonumber(a), value = tonumber(b) }
end

local function objectives(s)
    local out = {}
    if s == "" then return out end
    for i, entry in ipairs(split(s, ";")) do
        local k, list, n, src = entry:match("^(%a)([%d,]*):(%d*):(%a*)$")
        if k then
            out[#out + 1] = { index = i, kind = KIND[k] or "other", ids = ids(list), count = tonumber(n),
                countSource = COUNT_SOURCE[src] }
        end
    end
    return out
end

--- Normalised quest. Spots are decoded {map, x, y}; `spots.start`, `spots.finish` and
--- `spots[objectiveIndex]` are Forever-observed locations (client POI points, players).
local function buildQuest(id)
    local rec = raw("quests", id)
    if not rec then return nil end
    local f = split(rec)
    local flags = {}
    for c in (f[10] or ""):gmatch("%a") do if FLAG[c] then flags[FLAG[c]] = true end end
    local s = spotsOf(id) or {}
    local qspots = { start = spots(s.s), finish = spots(s.e) }
    for k, v in pairs(s) do if type(k) == "number" then qspots[k] = spots(v) end end
    return {
        id = id,
        name = f[1],
        level = num(f[2]) or 0,
        minLevel = num(f[3]) or 0,
        maxLevel = num(f[4]) or 0,
        side = f[5] or "",
        races = num(f[6]) or 0,
        classes = num(f[7]) or 0,
        zone = num(f[8]) or 0,
        sort = num(f[9]) or 0,
        flags = flags,
        xp = num(f[11]),
        xpSource = XP_SOURCE[f[12]],
        starters = givers(f[13]),
        finishers = givers(f[14]),
        objectives = objectives(f[15] or ""),
        preAll = ids(f[16]),
        preAny = ids(f[17]),
        exclusive = ids(f[18]),
        breadcrumbFor = num(f[19]),
        nextInChain = num(f[20]),
        parent = num(f[21]),
        repMin = pair(f[22]),
        repMax = pair(f[23]),
        skill = pair(f[24]),
        sourceItem = num(f[25]),
        groupSize = num(f[26]),
        seenBy = num(f[27]),
        prevSeen = num(f[28]),
        lowestLevelSeen = num(f[29]),
        area = num(f[30]) or 0,
        text = textOf(id),
        spots = qspots,
    }
end
function Data.GetQuest(id) return cached("quest", id, buildQuest) end

--- Where an objective is done: { {kind = "npc"|"object"|"vendor", id, rate?, source?}, ... }.
--- Forever-observed spots for the objective are in quest.spots[objective.index].
function Data.ObjectiveSources(objective)
    local out = {}
    if objective.kind == "kill" then
        for _, id in ipairs(objective.ids) do out[#out + 1] = { kind = "npc", id = id } end
    elseif objective.kind == "object" then
        for _, id in ipairs(objective.ids) do out[#out + 1] = { kind = "object", id = id } end
    elseif objective.kind == "item" then
        for _, itemId in ipairs(objective.ids) do
            local item = Data.GetItem(itemId)
            if item then
                for _, d in ipairs(item.drops) do out[#out + 1] = { kind = "npc", id = d.id, rate = d.rate, source = d.source } end
                for _, o in ipairs(item.objects) do out[#out + 1] = { kind = "object", id = o.id, rate = o.rate, source = o.source } end
                for _, v in ipairs(item.vendors) do out[#out + 1] = { kind = "vendor", id = v } end
            end
        end
    end
    return out
end

--- Base quest XP (before level scaling) and its source: xp, source, low, high.
--- Without a record the source is "estimate":
---   1. the median XP of recorded quests of the same level and kind (dungeon, with objectives,
---      without objectives), with `low` and `high` as the quartiles: half of such quests fall
---      between them;
---   2. failing that, ForeverDB's curve for the level (dungeon quests scaled by its dungeon
---      multiplier), with no range.
function Data.GetQuestXP(questId)
    local q = Data.GetQuest(questId)
    if not q then return nil end
    if q.xp then return q.xp, q.xpSource end
    local level = q.level > 0 and q.level or q.minLevel
    local kind = (q.flags.dungeon or q.flags.raid) and "d" or (#q.objectives > 0 and "o" or "t")
    local est = world.xpEstimate and world.xpEstimate[kind]
    est = est and est[math.max(1, math.min(60, level))]
    if est then return est[1], "estimate", est[2], est[3] end
    local base = world.xpCurve and world.xpCurve[math.max(1, math.min(60, level))]
    if not base then return nil end
    if (q.flags.dungeon or q.flags.raid) and world.xpDungeonMultiplier then base = base * world.xpDungeonMultiplier end
    return floor(base), "estimate"
end

---------------------------------------------------------------------------------------------
-- Tags and availability
---------------------------------------------------------------------------------------------

local function eliteNpc(npcId)
    local npc = Data.GetNpc(npcId)
    return npc ~= nil and npc.rank >= 1 and npc.rank <= 3
end

--- "dungeon" | "raid" | "elite" | nil, and how it was decided: "data" (database flags) or
--- "heuristic" (an objective mob is elite). The game's own tag (C_QuestLog.GetQuestTagInfo)
--- is read by ns.Game and wins over this when available.
function Data.GetQuestTag(questId)
    local q = Data.GetQuest(questId)
    if not q then return nil, "none" end
    if q.flags.raid then return "raid", "data" end
    if q.flags.dungeon then return "dungeon", "data" end
    if q.flags.group then return "elite", "data" end
    for _, o in ipairs(q.objectives) do
        if o.kind == "kill" then
            for _, id in ipairs(o.ids) do
                if eliteNpc(id) then return "elite", "heuristic" end
            end
        elseif o.kind == "item" then
            local item = Data.GetItem(o.ids[1])
            local drops = item and item.drops or {}
            local allElite = #drops > 0 and #item.objects == 0 and #item.vendors == 0
            for _, d in ipairs(drops) do
                if not eliteNpc(d.id) then allElite = false; break end
            end
            if allElite then return "elite", "heuristic" end
        end
    end
    return nil, "none"
end

--- Can this character take the quest (ignoring level, which the planner handles)?
--- ctx = { faction, raceId, class, completed = {[id]=true}, inLog = {[id]=true},
---         skills = {[skillId]=value}?, reputations = {[factionId]=value}? }
--- Returns ok, reason. Unknown skills/reputations do not block (reason notes it).
function Data.IsAvailable(questId, ctx)
    local q = Data.GetQuest(questId)
    if not q then return false, "unknown quest" end
    ctx = ctx or {}
    local completed, inLog = ctx.completed or {}, ctx.inLog or {}
    if completed[questId] and not q.flags.repeatable then return false, "completed" end
    if inLog[questId] then return false, "in quest log" end
    local enum = world.enum or {}
    if q.races ~= 0 and ctx.raceId and enum.raceMaskById then
        local mask = enum.raceMaskById[ctx.raceId]
        if mask and band(q.races, mask) == 0 then return false, "race" end
    elseif q.side ~= "" and ctx.faction then
        if (q.side == "a") ~= (ctx.faction == "Alliance") then return false, "faction" end
    end
    if q.classes ~= 0 and ctx.class and enum.classKeys then
        local bit = enum.classKeys[ctx.class]
        if bit and not hasBit(q.classes, bit) then return false, "class" end
    end
    for _, pre in ipairs(q.preAll) do
        if not completed[pre] then return false, "prerequisite " .. pre end
    end
    if #q.preAny > 0 then
        local any = false
        for _, pre in ipairs(q.preAny) do if completed[pre] then any = true; break end end
        if not any then return false, "prerequisite (one of " .. concat(q.preAny, ",") .. ")" end
    end
    for _, ex in ipairs(q.exclusive) do
        if completed[ex] or inLog[ex] then return false, "exclusive with " .. ex end
    end
    if q.nextInChain and (completed[q.nextInChain] or inLog[q.nextInChain]) then return false, "later quest done" end
    if q.breadcrumbFor and (completed[q.breadcrumbFor] or inLog[q.breadcrumbFor]) then
        return false, "breadcrumb target already taken"
    end
    if q.parent and q.parent ~= 0 and not inLog[q.parent] then return false, "needs quest " .. q.parent .. " active" end
    local unknown
    if q.skill and q.skill.id then
        local have = ctx.skills and ctx.skills[q.skill.id]
        if have == nil then unknown = "skill unknown"
        elseif have < (q.skill.value or 0) then return false, "skill" end
    end
    if q.repMin and q.repMin.id then
        local have = ctx.reputations and ctx.reputations[q.repMin.id]
        if have == nil then unknown = "reputation unknown"
        elseif have < (q.repMin.value or 0) then return false, "reputation" end
    end
    if q.repMax and q.repMax.id and ctx.reputations and ctx.reputations[q.repMax.id]
        and ctx.reputations[q.repMax.id] >= (q.repMax.value or 0) then
        return false, "reputation too high"
    end
    return true, unknown
end

---------------------------------------------------------------------------------------------
-- Indexes
---------------------------------------------------------------------------------------------

local VIA_ZONE, VIA_GIVER = 1, 2

-- The four fields of a quest record the index reads (8 zone, 13 starters, 16 and 17 prerequisites),
-- picked out of the packed string without decoding the quest.
local INDEX_FIELDS = "^" .. ("[^|]*|"):rep(7) .. "([^|]*)|" .. ("[^|]*|"):rep(4) .. "([^|]*)|"
    .. ("[^|]*|"):rep(2) .. "([^|]*)|([^|]*)"

-- The maps an NPC or object stands on (its spots are the record's last field), in the order of
-- its spots, each once. Read from the packed string: the entity is not decoded or cached.
local function entityMaps(kind, id)
    local rec
    if kind == "n" then rec = raw("npcs", id) elseif kind == "o" then rec = raw("objects", id) end
    local out, seen = {}, {}
    for token in ((rec or ""):match("([^|]*)$") or ""):gmatch("%S+") do
        local n = tonumber(token, 36)
        local map = n and floor(n / 1e6)
        if map and not seen[map] then seen[map] = true; out[#out + 1] = map end
    end
    return out
end

--- One pass over every quest: quests by uiMap (quest zone, and maps where a starter stands)
--- and the reverse prerequisite index. `checkpoint()` lets a coroutine runner yield.
--- The quests are not decoded: decoding all of them (Data.GetQuest keeps what it decodes) cost
--- some 25 MB that a session never needed, since the planner only ever looks at the quests of
--- the zones around the character's level. Records mode reads the four fields from the packed
--- record. Merge mode reads only what the index needs of each quest (Merge.QuestIndex) and
--- builds no quest record, and computes the world tables made from every quest on the way:
--- world.xpEstimate and world.dungeons.
function Data.BuildIndex(checkpoint)
    if not Data.usable then return nil end
    local byMap, followUps, byItem, n = {}, {}, {}, 0
    local giverMaps = {} -- [kind .. id] = entityMaps, for this pass only
    local merge = mode == "merge" and ns.Merge or nil
    local stats = merge and merge.NewStats()
    local exists = {}
    local function put(map, questId, via)
        if not map or map <= 0 then return end
        local t = byMap[map]
        if not t then t = {}; byMap[map] = t end
        local cur = t[questId] or 0
        if not hasBit(cur, via) then t[questId] = cur + via end
    end
    local function follows(list, questId)
        for pre in list:gmatch("%d+") do
            pre = tonumber(pre)
            local t = followUps[pre]
            if not t then t = {}; followUps[pre] = t end
            t[#t + 1] = questId
        end
    end
    local all = Data.QuestIds()
    for i = 1, #all do
        local questId = all[i]
        n = n + 1
        local zone, starters, preAll, preAny, startSpots
        local rec = merge and packed.quests[questId] -- already built: read it like a fixture
        if merge and rec == nil then
            zone, starters, preAll, preAny, startSpots = merge.QuestIndex(questId, stats)
        else
            rec = raw("quests", questId)
            if rec then
                zone, starters, preAll, preAny = rec:match(INDEX_FIELDS)
                if not zone then -- a short record: read it the long way
                    local f = split(rec)
                    zone, starters, preAll, preAny = f[8] or "", f[13] or "", f[16] or "", f[17] or ""
                end
                local s = spotsOf(questId)
                startSpots = s and s.s
                if merge then merge.CountRecord(stats, questId, rec) end
            end
        end
        if zone then
            exists[questId] = true
            put(tonumber(zone) or 0, questId, VIA_ZONE)
            local hasStart = false
            for token in (startSpots or ""):gmatch("%S+") do
                local v = tonumber(token, 36)
                if v then hasStart = true; put(floor(v / 1e6), questId, VIA_GIVER) end
            end
            for kind, id in starters:gmatch("([noi])(%d+)") do
                id = tonumber(id)
                if kind == "i" then
                    local t = byItem[id]
                    if not t then t = {}; byItem[id] = t end
                    t[#t + 1] = questId
                elseif not hasStart then
                    local key = kind .. id
                    local maps = giverMaps[key]
                    if not maps then maps = entityMaps(kind, id); giverMaps[key] = maps end
                    for j = 1, #maps do put(maps[j], questId, VIA_GIVER) end
                end
            end
            follows(preAll, questId)
            follows(preAny, questId)
        end
        if checkpoint and n % 50 == 0 then checkpoint() end
    end
    for _, t in pairs(followUps) do table.sort(t) end
    for _, t in pairs(byItem) do table.sort(t) end
    if merge then
        if checkpoint then checkpoint() end
        rawset(world, "xpEstimate", merge.XpEstimatesFrom(stats))
        if checkpoint then checkpoint() end
        rawset(world, "dungeons", merge.DungeonsFrom(stats, exists))
        if checkpoint then checkpoint() end
        merge.LoadDropTables() -- (once, here, rather than in the middle of the first plan)
        merge.ReleaseQuestCache()
    end
    Data._index = { byMap = byMap, followUps = followUps, byItem = byItem, questCount = n }
    return Data._index
end

function Data.IsIndexBuilt() return Data._index ~= nil end

--- Quests tied to a uiMap: { {id, inZone = bool, giverInZone = bool}, ... } sorted by id.
function Data.QuestsInZone(uiMapId)
    local index = Data._index
    if not index then return nil end
    local out = {}
    for questId, via in pairs(index.byMap[uiMapId] or {}) do
        out[#out + 1] = { id = questId, inZone = hasBit(via, VIA_ZONE), giverInZone = hasBit(via, VIA_GIVER) }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Quests that start from this item (needs BuildIndex), sorted.
function Data.QuestsStartedByItem(itemId)
    local index = Data._index
    local t = index and index.byItem and index.byItem[itemId] or {}
    local out = {}
    for i, v in ipairs(t) do out[i] = v end
    return out
end

--- Quests unlocked by this one (needs BuildIndex).
function Data.GetFollowUps(questId)
    local index = Data._index
    local t = index and index.followUps[questId] or {}
    local out = {}
    for i, v in ipairs(t) do out[i] = v end
    return out
end

--- The world tables: ForeverDB's pace (seconds per kill/item/object by level band), xpCurve,
--- xpDungeonMultiplier, zones (levels, hubs), travel (flight nodes/paths, walk matrix), maps and
--- links; QuestieDB's enums; xpEstimate and dungeons (computed from every quest).
function Data.World() return Data.usable and world or nil end

Data.status = { state = "missing", notes = {} }
Data.usable = false
reset()
