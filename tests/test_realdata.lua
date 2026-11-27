-- tests/test_realdata.lua: what players get: the real QuestieDB addon (loaded through the import
-- tools' sandbox from env QUESTIEDB, default the game's AddOns folder) merged at runtime with the
-- baked ForeverDB layer in LevelScout/data. Every record must parse, references must resolve,
-- spot checks must match known facts, the records must equal what the build-time importer made
-- before QuestieDB became a runtime dependency, and every data file must carry the credit lines
-- the licences require.
local H, M = ...
local test, eq, ok, contains = H.test, H.eq, H.ok, H.contains

local function load()
    M.install()
    local ns = {}
    local files = {}
    for _, f in ipairs(H.tocFiles()) do if f:match("^data/") then files[#files + 1] = f end end
    H.loadAddon(files, ns)
    H.loadAddon(H.runtimeFiles(), ns)
    return ns
end

local loaded
local function data()
    loaded = loaded or load()
    return loaded
end

local function init(faction, class)
    local ns = data()
    faction, class = faction or "Alliance", class or "WARRIOR"
    ns.Data.Init({ faction = faction, class = class, clientBuild = ns.data.meta.build }, M.questieDB(faction, class))
    assert(ns.Data.usable, tostring(ns.Data.status.message))
    return ns.Data, ns.data
end

local function fieldCount(s)
    local n = 1
    for _ in s:gmatch("|") do n = n + 1 end
    return n
end

-- Every NPC, object and item the quests point at (givers, objective targets, drop sources).
local function referenced(Data)
    local npcs, objects, items = {}, {}, {}
    local put = { npc = npcs, object = objects, item = items, kill = npcs }
    for _, id in ipairs(Data.QuestIds()) do
        local q = Data.GetQuest(id)
        for _, g in ipairs(q.starters) do put[g.kind][g.id] = true end
        for _, g in ipairs(q.finishers) do put[g.kind][g.id] = true end
        for _, o in ipairs(q.objectives) do
            if put[o.kind] then for _, oid in ipairs(o.ids) do put[o.kind][oid] = true end end
        end
    end
    for id in pairs(items) do
        local item = Data.GetItem(id)
        for _, d in ipairs(item and item.drops or {}) do npcs[d.id] = true end
        for _, d in ipairs(item and item.objects or {}) do objects[d.id] = true end
        for _, v in ipairs(item and item.vendors or {}) do npcs[v] = true end
    end
    return npcs, objects, items
end

H.suite("Generated data", function()
    test("meta: client build, the ForeverDB source and the QuestieDB contract it needs", function()
        local Data, D = init()
        ok(D.meta.build:match("^%d+%.%d+%.%d+%.%d+$"), "build " .. tostring(D.meta.build))
        ok(D.meta.sources.ForeverDB and D.meta.sources.ForeverDBData)
        eq(D.meta.sources.QuestieDB, nil, "QuestieDB is not baked in")
        eq(D.meta.requires.QuestieDBContract, data().Merge.CONTRACT)
        contains(Data.status.sources.QuestieDB, "contract 4")
        ok(#Data.QuestIds() > 4000, "quest count")
    end)

    test("the baked layer is ForeverDB only: no merged records, no variants, no QuestieDB tables", function()
        local _, D = init()
        for _, name in ipairs({ "quests", "npcs", "objects", "items", "questText", "questSpots", "variants" }) do
            eq(D[name], nil, "ns.data." .. name)
        end
        ok(type(D.fdb.qcQuests) == "table" and type(D.fdb.qfQuests) == "table")
        ok(D.world.enum.classKeys == M.questieDB("Alliance", "WARRIOR").Enum.classKeys, "enums are QuestieDB's own tables")
        local f = assert(io.open(H.root .. "/LevelScout/LevelScout.toc", "rb"))
        local toc = f:read("*a")
        f:close()
        contains(toc, "## Dependencies: QuestieDB")
        ok(not toc:find("Variants.lua", 1, true) and not toc:find("QuestText.lua", 1, true), "no merged files in the TOC")
    end)

    test("no Wowhead objective counts: no such count source, meta entry or file warning", function()
        local Data, D = init()
        for _, id in ipairs(Data.QuestIds()) do
            ok(not Data.Raw("quests", id):find(":W", 1, true), "quest " .. id .. " has a Wowhead count")
        end
        eq(D.meta.localOnly, nil, "meta.localOnly")
        eq(D.meta.sources.Wowhead, nil, "meta.sources.Wowhead")
        local f = assert(io.open(H.root .. "/LevelScout/data/Quests.lua", "rb"))
        local head = f:read(1200)
        f:close()
        ok(not head:find("DO NOT DISTRIBUTE", 1, true), "file header warning")
    end)

    test("walk table: Stormwind to Gnomeregan is a flight to Ironforge, not a walk over the mountains", function()
        local _, D = init()
        local ns = data()
        ns.Geo.Init(D.world)
        ok(type(D.world.travel.hubs) == "string" and type(D.world.travel.walk) == "string", "the import carries the walk table")
        local known = {}
        for _, id in ipairs({ 2, 4, 5, 6, 7, 8, 12, 14, 16, 19 }) do known[id] = true end
        local travel = ns.Travel.New(D.world, { speed = 7, side = "a", knownNodes = known })
        local stormwind, ironforge = ns.Geo.Loc(1453, 60, 70), ns.Geo.Loc(1455, 35, 60)
        local door = ns.Geo.Loc(1426, 17.7, 39.2)
        local straight = ns.Geo.Dist(stormwind, door) * ns.Travel.DETOUR
        ok(travel:WalkYards(stormwind, door) > 2 * straight, "on foot it is far more than the straight line")
        local route = travel:Route(stormwind, door)
        eq(route.mode, "fly")
        eq({ route.legs[2].from.name, route.legs[2].to.name }, { "Stormwind", "Ironforge" })
        -- inside one area nothing changes: Ironforge to the door is the straight line still
        H.near(travel:WalkYards(ironforge, door), ns.Geo.Dist(ironforge, door) * ns.Travel.DETOUR, 0.01)
        eq(travel:Route(ironforge, door).mode, "walk")
    end)

    test("dungeons: entrance on a known map, levels, and quests that exist", function()
        local Data = init()
        local world = Data.World()
        local n = 0
        for _, d in pairs(world.dungeons) do
            n = n + 1
            local map, x, y = Data.DecodeSpot(d.ent:match("%S+"))
            ok(map and world.maps[map], d.name .. ": entrance map")
            ok(x >= 0 and x <= 100 and y >= 0 and y <= 100)
            ok(d.lo > 0 and d.hi >= d.lo and d.bosses > 0, d.name .. ": levels and bosses")
            for q in d.quests:gmatch("%d+") do ok(Data.GetQuest(tonumber(q)), d.name .. ": quest " .. q) end
        end
        ok(n >= 15, "dungeon count " .. n)
        eq(world.dungeons[36].name, "Deadmines")
        ok(("," .. world.dungeons[36].quests .. ","):find(",166,", 1, true), "The Defias Brotherhood (final part) is a Deadmines quest")
    end)

    test("XP estimates cover every level for quests with and without objectives", function()
        local Data = init()
        local e = Data.World().xpEstimate
        for level = 1, 60 do
            for _, kind in ipairs({ "o", "t" }) do
                local v = e[kind][level]
                ok(v and v[2] <= v[1] and v[1] <= v[3], kind .. " level " .. level)
            end
        end
        local n = 0
        for _, id in ipairs(Data.QuestIds()) do
            local q = Data.GetQuest(id)
            if q and not q.xp then
                local xp, src = Data.GetQuestXP(id)
                ok(xp and xp > 0 and src == "estimate", "quest " .. id)
                n = n + 1
            end
        end
        ok(n > 100, "some quests rely on the estimate")
    end)

    test("every file carries the ForeverDB credit line and licence notices", function()
        for _, f in ipairs(H.tocFiles()) do
            if f:match("^data/") then
                local fh = assert(io.open(H.root .. "/LevelScout/" .. f, "rb"))
                local head = fh:read("*l") .. "\n" .. fh:read("*l") .. "\n" .. fh:read("*l")
                fh:close()
                ok(head:find("^%-%- Data: ForeverDB%.net %(https://foreverdb%.net%)"), f .. ": ForeverDB credit line")
                contains(head, "CMaNGOS", f)
                contains(head, "GPL-3.0", f)
                contains(head, "QuestieDB is read", f)
            end
        end
    end)

    test("every record has the expected number of fields", function()
        local Data = init()
        local expect = Data.EXPECTED_FIELDS
        local npcs, objects, items = referenced(Data)
        local function check(tableName, ids, n)
            for id in pairs(ids) do
                local rec = Data.Raw(tableName, id)
                if rec and fieldCount(rec) ~= n then error(string.format("%s[%d] has %d fields", tableName, id, fieldCount(rec))) end
            end
        end
        local quests = {}
        for _, id in ipairs(Data.QuestIds()) do quests[id] = true end
        check("quests", quests, expect.quest)
        check("npcs", npcs, expect.npc)
        check("objects", objects, expect.object)
        check("items", items, expect.item)
    end)

    test("every quest, NPC, object and item parses; spots decode to valid map positions", function()
        local Data = init()
        local function checkSpots(list, what)
            for _, s in ipairs(list) do
                if not (s.map > 0 and s.x >= 0 and s.x <= 100 and s.y >= 0 and s.y <= 100) then
                    error(what .. " bad spot " .. H.serialize(s))
                end
            end
        end
        for _, id in ipairs(Data.QuestIds()) do
            local q = Data.GetQuest(id)
            ok(q and q.name ~= "", "quest " .. id)
            for _, o in ipairs(q.objectives) do ok(o.kind, "objective kind in quest " .. id) end
            for k, list in pairs(q.spots) do checkSpots(list, "quest " .. id .. " spots " .. tostring(k)) end
        end
        local npcs, objects, items = referenced(Data)
        for id in pairs(npcs) do local npc = Data.GetNpc(id); if npc then checkSpots(npc.spots, "npc " .. id) end end
        for id in pairs(objects) do local o = Data.GetObject(id); if o then checkSpots(o.spots, "object " .. id) end end
        for id in pairs(items) do
            for _, d in ipairs((Data.GetItem(id) or { drops = {} }).drops) do
                ok(d.rate == nil or (d.rate >= 0 and d.rate <= 1), "item " .. id .. " rate")
            end
        end
    end)

    test("references from quests resolve (at most 1% dangling)", function()
        local Data = init()
        local refs, missing = 0, {}
        local get = { npc = Data.GetNpc, kill = Data.GetNpc, object = Data.GetObject, item = Data.GetItem }
        for _, id in ipairs(Data.QuestIds()) do
            local q = Data.GetQuest(id)
            for _, g in ipairs(q.starters) do
                refs = refs + 1
                if not get[g.kind](g.id) then missing[#missing + 1] = g.kind .. g.id end
            end
            for _, o in ipairs(q.objectives) do
                for _, oid in ipairs(o.ids) do
                    refs = refs + 1
                    if get[o.kind] and not get[o.kind](oid) then missing[#missing + 1] = o.kind .. oid end
                end
            end
        end
        ok(#missing <= refs / 100, string.format("%d of %d references dangle, e.g. %s", #missing, refs,
            table.concat({ missing[1] or "", missing[2] or "", missing[3] or "" }, " ")))
    end)

    test("known facts: Northshire", function()
        local Data = init()
        local q = Data.GetQuest(7)
        eq(q.name, "Kobold Camp Cleanup")
        eq(q.zone, 1429)
        eq(q.objectives[1].kind, "kill")
        eq(q.objectives[1].ids, { 6 })
        eq(q.objectives[1].count, 10)
        eq(q.objectives[1].countSource, "CMaNGOS")
        eq(q.starters, { { kind = "npc", id = 197 } })
        local vermin = Data.GetNpc(6)
        ok(#vermin.spots > 5)
        for _, s in ipairs(vermin.spots) do eq(s.map, 1429) end
        local wolves = Data.GetQuest(33)
        eq({ wolves.objectives[1].kind, wolves.objectives[1].ids[1], wolves.objectives[1].count }, { "item", 750, 8 })
        local rate = Data.GetDropRate(750, 299)
        ok(rate and rate > 0 and rate <= 1, "Young Wolf drops Tough Wolf Meat")
    end)

    test("known facts: faction and class corrections", function()
        local Data = init("Alliance", "WARRIOR")
        eq(Data.GetQuest(687).starters[1].id, 2786)
        Data = init("Horde", "WARRIOR")
        eq(Data.GetQuest(687).starters[1].id, 2787)
        eq(init("Alliance", "MAGE").GetQuest(8315).nextInChain, 8381)
        eq(init("Alliance", "DRUID").GetQuest(8315).nextInChain, 8382)
        eq(init("Horde", "WARRIOR").GetQuest(84395).text,
            "Collect 'Undead Potatoes' and bring it to Oran Snakewrithe in Undercity.", "QuestieDB's Horde text")
        eq(init("Alliance", "WARRIOR").GetQuest(84395).text,
            "Collect 'Undead Potatoes' and bring it to Jennea Cannon in Stormwind.", "and the Alliance one")
    end)

    test("known facts: eligibility for a human and an orc", function()
        local Data = init("Alliance", "WARRIOR")
        eq({ Data.IsAvailable(7, { faction = "Alliance", raceId = 1, class = "WARRIOR", completed = {}, inLog = {} }) }, { false, "prerequisite (one of 783)" })
        eq(Data.IsAvailable(7, { faction = "Alliance", raceId = 1, class = "WARRIOR", completed = { [783] = true }, inLog = {} }), true)
        Data = init("Horde", "WARRIOR")
        eq({ Data.IsAvailable(7, { faction = "Horde", raceId = 2, class = "WARRIOR", completed = { [783] = true }, inLog = {} }) }, { false, "race" })
    end)

    test("known facts: escort quests", function()
        local Data = init()
        for _, id in ipairs({ 219, 309, 5821, 5943, 1560, 6641 }) do
            ok(Data.GetQuest(id).flags.escort, "quest " .. id .. " is an escort")
        end
        for _, id in ipairs({ 754, 1640, 4492, 1144 }) do
            eq(Data.GetQuest(id).flags.escort, nil, "quest " .. id .. " is not")
        end
    end)

    test("world tables: pace, XP curve, travel, zones, enums", function()
        local Data = init()
        local w = Data.World()
        ok(type(w.pace) == "table" and next(w.pace) ~= nil, "pace")
        eq(#w.xpCurve, 60)
        ok(type(w.travel.nodes) == "table", "travel nodes")
        ok(type(w.zones) == "table" and next(w.zones) ~= nil, "zones")
        eq(w.enum.classKeys.MAGE, 128)
        eq(w.enum.raceMaskById[95], 2 ^ 32)
    end)

    test("index over all quests builds and finds Northshire quests", function()
        local Data = init()
        local index = Data.BuildIndex()
        ok(index.questCount > 4000)
        local found = false
        for _, e in ipairs(Data.QuestsInZone(1429)) do if e.id == 7 then found = true end end
        ok(found, "quest 7 on map 1429")
    end)

    test("the index from QuestieDB's short reads equals the index from the full records", function()
        local ns = load() -- a fresh copy: no records built yet
        local Data = ns.Data
        Data.Init({ faction = "Alliance", class = "WARRIOR" }, M.questieDB("Alliance", "WARRIOR"))
        local function snapshot()
            local index = Data.BuildIndex()
            local maps, follow = {}, {}
            for map in pairs(index.byMap) do maps[map] = Data.QuestsInZone(map) end
            for id in pairs(index.followUps) do follow[id] = Data.GetFollowUps(id) end
            local w = Data.World()
            return { maps = maps, follow = follow, byItem = index.byItem, xp = w.xpEstimate, dungeons = w.dungeons }
        end
        local lean = snapshot()
        for _, id in ipairs(Data.QuestIds()) do Data.GetQuest(id) end
        local full = snapshot()
        for _, k in ipairs({ "maps", "follow", "byItem", "xp", "dungeons" }) do ok(H.deepEq(lean[k], full[k]), k) end
    end)
end)

-- The records the build-time importer wrote before QuestieDB became a runtime dependency
-- (tests/fixtures/old_records.lua: a sample for one character). Built at runtime from the same
-- QuestieDB and ForeverDB versions they must be the same, field for field.
H.suite("Runtime records against the old importer", function()
    local old = dofile(H.root .. "/tests/fixtures/old_records.lua")
    local function sameSources(Data, D)
        local qdb = Data.status.sources.QuestieDB or ""
        return qdb:find("QuestieDB " .. old.sources.QuestieDB .. " ", 1, true) ~= nil
            and D.meta.sources.ForeverDBData == old.sources.ForeverDBData
    end
    local function compare(what, getter)
        local Data, D = init(old.faction, old.class)
        if not sameSources(Data, D) then
            io.write(string.format("  (skipped %s: the fixture is for QuestieDB %s and ForeverDB data %s; installed %s, baked %s)\n",
                what, old.sources.QuestieDB, old.sources.ForeverDBData, tostring(Data.status.sources.QuestieDB),
                tostring(D.meta.sources.ForeverDBData)))
            return
        end
        local n, bad = 0, {}
        for id, rec in pairs(old[what]) do
            n = n + 1
            local now = getter(Data, id)
            if now ~= (rec or nil) and not H.deepEq(now, rec or nil) then
                bad[#bad + 1] = string.format("%s %d:\n    old %s\n    new %s", what, id, H.serialize(rec), H.serialize(now))
            end
        end
        ok(n > 50, what .. ": sample size " .. n)
        ok(#bad == 0, #bad .. " of " .. n .. " differ:\n  " .. table.concat(bad, "\n  ", 1, math.min(#bad, 5)))
    end
    test("quests", function() compare("quests", function(Data, id) return Data.Raw("quests", id) end) end)
    test("NPCs", function() compare("npcs", function(Data, id) return Data.Raw("npcs", id) end) end)
    test("items", function() compare("items", function(Data, id) return Data.Raw("items", id) end) end)
    test("objects", function() compare("objects", function(Data, id) return Data.Raw("objects", id) end) end)
    test("quest spots", function() compare("questSpots", function(Data, id) return Data.Raw("questSpots", id) end) end)
    test("XP estimates and dungeons", function()
        local Data, D = init(old.faction, old.class)
        if not sameSources(Data, D) then return end
        eq(Data.World().xpEstimate, old.xpEstimate)
        eq(Data.World().dungeons, old.dungeons)
    end)
end)

-- The planner's search on the real data: a level 22 human in Redridge, a few zones to plan.
H.suite("Planner search (real data)", function()
    local function plans(settings)
        local Data, raw = init("Alliance", "PALADIN")
        local ns = data()
        Data.BuildIndex()
        local saved = {}
        for k, v in pairs(settings or {}) do saved[k], ns.Planner[k] = ns.Planner[k], v end
        local completed = {}
        for _, id in ipairs(ns.Data.QuestIds()) do
            local q = Data.GetQuest(id)
            if q and q.level > 0 and q.level <= 18 then completed[id] = true end
        end
        local ctx = ns.Zones.Context({ level = 22, faction = "Alliance", class = "PALADIN", raceId = 1, map = 1433, x = 0.30, y = 0.44,
            log = {}, completed = completed, capacity = 40 })
        local out = {}
        for _, map in ipairs({ 1433, 1431, 1437 }) do out[map] = ns.Zones.PlanZone(map, ctx) end
        for k, v in pairs(saved) do ns.Planner[k] = v end
        return out
    end
    -- every quest: accept, then its work, then turn in; never twice
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
        for _, step in ipairs(plan.steps) do
            if step.kind == "work" then
                for _, q in ipairs(step.quests) do
                    local p, t = at["P:" .. q.id], at["T:" .. q.id]
                    local here
                    for i, s in ipairs(plan.steps) do if s == step then here = i end end
                    if not t or t < here or (p and p > here) then return false, "work out of order for " .. q.id end
                end
            end
        end
        return true
    end

    local plain, searched
    test("the same situation always gives the same plan", function()
        searched = plans()
        local again = plans()
        for map, plan in pairs(searched) do
            eq(table.concat(plan.order, " "), table.concat(again[map].order, " "), "map " .. map)
        end
    end)

    test("searched routes keep every order rule", function()
        for map, plan in pairs(searched) do
            ok(#plan.steps > 0, "map " .. map .. " has a route")
            local fine, why = wellFormed(plan)
            ok(fine, "map " .. map .. ": " .. tostring(why))
        end
    end)

    test("the search and the exact windows make routes worth more, never clearly less", function()
        plain = plans({ SEARCH_ITERATIONS = 0, EXACT_WINDOW = 0 })
        local better, total, base = 0, 0, 0
        for map, plan in pairs(searched) do
            ok(plan.score >= plain[map].score, string.format("map %d: %.0f against %.0f before", map, plan.score, plain[map].score))
            if plan.score > plain[map].score * 1.01 then better = better + 1 end
            total, base = total + plan.score, base + plain[map].score
        end
        ok(better >= 1, "at least one zone is clearly better")
        ok(total > base * 1.03, string.format("better overall: %.0f against %.0f", total, base))
    end)

    test("exact windows alone: a stretch in its best order is never worse", function()
        local windows = plans({ SEARCH_ITERATIONS = 0 })
        -- the searched plan is checked against the unsearched route tidied the same way
        for map, plan in pairs(searched) do
            ok(plan.score >= windows[map].score, string.format("map %d: searched %.0f, not searched %.0f", map, plan.score, windows[map].score))
        end
        -- The quests a plan routes, as one string.
        local function questSet(plan)
            local ids = {}
            for _, key in ipairs(plan.order) do
                local id = key:match("^[PT]:(%d+)$")
                if id and not ids[id] then ids[id] = true; ids[#ids + 1] = tonumber(id) end
            end
            table.sort(ids)
            return table.concat(ids, " ")
        end
        local compared = 0
        for map, plan in pairs(windows) do
            -- With the same quests, a stretch in its best order is never worse. The tidy-up after
            -- the windows can still differ: in the plain route it may push a level-up back, and the
            -- quest that waits for it goes out (with what follows from it), while the reordered
            -- route keeps them. Then the windows plan does more: it routes more quests for more XP.
            if questSet(plan) == questSet(plain[map]) then
                ok(plan.score >= plain[map].score * 0.999, string.format("map %d: %.0f against %.0f", map, plan.score, plain[map].score))
                compared = compared + 1
            else
                ok(plan.quests > plain[map].quests and plan.xp >= plain[map].xp, string.format(
                    "map %d: other quests (%d against %d) and %d XP against %d", map, plan.quests, plain[map].quests, plan.xp, plain[map].xp))
            end
            ok(wellFormed(plan))
        end
        ok(compared >= 1, "at least one zone keeps the same quests")
    end)
end)

-- Level-ups along the route: a level 7 human at Goldshire.
H.suite("Planner levels (real data)", function()
    local function plan(extra, settings)
        local Data, raw = init("Alliance", "WARRIOR")
        local ns = data()
        Data.BuildIndex()
        local saved = {}
        for k, v in pairs(settings or {}) do saved[k], ns.Planner[k] = ns.Planner[k], v end
        local completed = {}
        for _, id in ipairs(ns.Data.QuestIds()) do
            local q = Data.GetQuest(id)
            if q and q.level > 0 and q.level <= 3 then completed[id] = true end
        end
        local state = { level = 7, faction = "Alliance", class = "WARRIOR", raceId = 1, map = 1429, x = 0.438, y = 0.659,
            log = {}, completed = completed, capacity = 40 }
        for k, v in pairs(extra or {}) do state[k] = v end
        local p = ns.Zones.PlanZone(1429, ns.Zones.Context(state))
        for k, v in pairs(saved) do ns.Planner[k] = v end
        return p, ns
    end

    test("XP to the next levels: the classic table, scaled by the game's figure", function()
        local Cost = data().Cost
        eq(Cost.LevelUps(10, 0, nil, 3), { 7600, 16400, 26500 })
        eq(Cost.LevelUps(10, 3800, 15200, 2), { 11400, 29000 }, "this level needs twice the table: so do the next")
        eq(Cost.LevelUps(59, 0, nil, 3, 60), { 209800 }, "nothing after the last level")
        eq(Cost.LevelUps(60, 0, nil, 3, 60), {})
        eq(Cost.LevelUps(10, 0, nil, 0), {}, "switched off")
    end)

    test("a kill pays less and goes faster a level later; a quest far below pays less", function()
        local Model = data().Model
        local task = { lv = 10, mobLevel = 10, kills = 8, inCamp = 10, paceC = 30, bonus = 0, members = 1, cycle = 30, xpPerKill = 95 }
        local cycle, xp = Model.KillAt(task, 10)
        eq({ cycle, xp }, { 30, 95 }, "at the level it was built for: as built")
        cycle, xp = Model.KillAt(task, 11)
        ok(xp < 95 and xp > 60, "less XP per kill: " .. xp)
        ok(cycle <= 30)
        cycle = Model.KillAt(task, 13)
        ok(cycle < 30, "three levels above the mob: quicker kills")
        local quest = { lv = 10, questLevel = 5, xp = 1000 }
        eq(Model.QuestXPAt(quest, 10), 1000)
        eq(Model.QuestXPAt(quest, 11), 800, "six levels below: 80%")
    end)

    local leveled
    test("the route marks where it levels us up, and plans next-level quests after that", function()
        -- (at level 6: at 7, Elwynn's one quest for levels 8 to 10, Report to Gryan Stoutmantle,
        -- waits for its level since the Forever quest that brought level 9 early got its level 20)
        leveled = plan({ level = 6 })
        local up, firstUp, gated = {}, nil, 0
        for i, step in ipairs(leveled.steps) do
            if step.levelUp then up[#up + 1] = step.levelUp; firstUp = firstUp or i end
            if step.needLevel then
                gated = gated + 1
                ok(firstUp and i > firstUp, "a quest for level " .. step.needLevel .. " comes after a level-up")
                local reached = 6
                for j = 1, i - 1 do reached = leveled.steps[j].levelUp or reached end
                ok(reached >= step.needLevel, "and after the right one")
            end
        end
        ok(#up >= 1 and up[1] == 7, "level 7 is reached along the route")
        for i = 2, #up do ok(up[i] == up[i - 1] + 1, "one level at a time") end
        ok(gated >= 1, "at least one quest that needs a later level is planned")
    end)

    test("almost at the next level: the first XP levels us up", function()
        local p = plan({ xp = 4490, xpMax = 4500 })
        local first
        for _, step in ipairs(p.steps) do
            if step.xp > 0 then first = step; break end
        end
        eq(first.levelUp, 8)
    end)

    test("switched off: everything is valued at today's level", function()
        local p = plan(nil, { LEVELS_AHEAD = 0 })
        for _, step in ipairs(p.steps) do
            ok(not step.levelUp and not step.needLevel)
        end
        ok(#p.steps > 0)
    end)

    test("at the level cap nothing levels up", function()
        local p = plan({ maxLevel = 7 })
        for _, step in ipairs(p.steps) do ok(not step.levelUp and not step.needLevel) end
    end)
end)

-- The next hours across zones: a level 22 human paladin at Lakeshire, every flight path known.
H.suite("Itinerary (real data)", function()
    local function setup()
        local Data, raw = init("Alliance", "PALADIN")
        local ns = data()
        Data.BuildIndex()
        local completed, known = {}, {}
        for _, id in ipairs(ns.Data.QuestIds()) do
            local q = Data.GetQuest(id)
            if q and q.level > 0 and q.level <= 18 then completed[id] = true end
        end
        for id, n in pairs(raw.world.travel.nodes) do
            if n[7] == "n" or n[7] == "a" then known[id] = true end
        end
        local state = { level = 22, faction = "Alliance", class = "PALADIN", raceId = 1, map = 1433, x = 0.30, y = 0.44,
            log = {}, completed = completed, capacity = 40, knownNodes = known }
        local ctx = ns.Zones.Context(state)
        -- (these tests are about how an itinerary is put together, and need one of two zones: the rule
        -- for moving on, Zones.HANDOFF, keeps this level 22 paladin in one zone, so it is off here; its
        -- own test below turns it on)
        ns.Zones.HANDOFF = false
        return ns, state, ctx, ns.Zones.Rank(ctx)
    end

    local ns, state, ctx, ranked, it
    -- The banner is the Zones tab's first zone, with the tab's figures; the shown zone's entry is the path's.
    local function bannerIs(with, active, shownMap)
        local Z = ns.Zones
        local order = Z.StartOrder(with, ranked, shownMap)
        ok(order and order[1], "the zones in the tab's order")
        local top, starts = order[1], with.starts
        local m = Z.MoveOn(active, ranked, nil, with)
        if top.map == shownMap then
            eq(m.suggest, false, "the shown zone is first: no banner")
            ok(with.alt == nil, "and no better start")
        else
            local lead = starts[top.map].rate / starts[shownMap].rate
            eq(m.map, top.map, "the banner names the zone the tab lists first")
            H.near(m.gain, lead - 1, 1e-9)
            eq(m.suggest, lead > Z.MOVE_ON_ENTER)
            eq(m.rate, true)
            if lead > 1 then
                eq(with.alt.map, top.map)
                H.near(with.alt.gain, m.gain, 1e-9)
            end
        end
        local own = starts[shownMap]
        ok(own.path, "the shown zone's entry is the path itself, never the zone alone")
        eq(own.next, with.segments[2] and with.segments[2].map or nil, "the shown row's next zone is the path's")
        H.near(own.rate, with.pathRate, 1e-6)
        for _, st in pairs(starts) do H.near(st.rate, st.xp / with.horizon * 3600, 1, "the same for every start") end
    end
    test("two zones inside the horizon beat the best single zone, and the times add up", function()
        ns, state, ctx, ranked = setup()
        it = ns.Zones.Itinerary(state, ctx, ranked)
        ok(it, "an itinerary")
        eq(it.horizon, ns.Zones.HORIZON)
        ok(#it.segments >= 2, "more than one zone")
        ok(it.xp > it.stay, string.format("%d XP against %d in one zone", it.xp, it.stay))
        local clock, xp, seen = 0, 0, {}
        for i, seg in ipairs(it.segments) do
            ok(not seen[seg.map], "no zone twice")
            seen[seg.map] = true
            ok(seg.travel >= 0 and seg.seconds >= ns.Zones.MIN_STAY, "a real stay in zone " .. seg.map)
            clock, xp = clock + seg.travel + seg.seconds, xp + seg.xp
            if i < #it.segments then
                ok(seg.leaveKey and seg.leaveKey:find("^[TW]:"), "left after a step that pays: " .. tostring(seg.leaveKey))
            else
                ok(not seg.leave, "the last zone runs to the horizon")
            end
        end
        ok(clock <= it.horizon + 1, "inside the horizon: " .. clock)
        ok(math.abs(xp - it.xp) <= #it.segments, "the zones' XP adds up to the total")
        H.near(it.rate, it.xp / (it.horizon / 3600), 1, "XP per hour over the horizon")
    end)

    test("moving on (Zones.HANDOFF): every zone after the first is higher than the zone before it", function()
        local Z = ns.Zones
        Z.HANDOFF = true
        local on = Z.Itinerary(state, ctx, ranked)
        local long
        Z.HORIZON = 4 * 3600 -- (more room for a move)
        long = Z.Itinerary(state, ctx, ranked)
        Z.HANDOFF, Z.HORIZON = false, it.horizon
        for _, got in ipairs({ on, long }) do
            ok(got, "an itinerary")
            local before
            for _, seg in ipairs(got.segments) do
                if not Z.Dungeon(seg.map) then
                    if before then
                        local a, b = Z.Info(before, ctx.side), Z.Info(seg.map, ctx.side)
                        ok(Z.Higher(a.lo, a.hi, b.lo, b.hi), string.format("%d (%d-%d) after %d (%d-%d)", seg.map, b.lo, b.hi, before, a.lo, a.hi))
                    end
                    before = seg.map
                end
            end
        end
    end)

    test("the trip from one zone to the next is corrected by the learned travel factor", function()
        -- the same zone plans, and a step-time model that says all travel takes `factor` times as long.
        -- The two-hour plan can fill the horizon to the second, so a big factor may leave no room for
        -- the second zone on some data builds: take the largest factor that keeps it.
        -- (without the credit for quests under way at the horizon: with it, a slower trip can
        -- tip a close call between two second zones, and this test is about the trip alone)
        ns.Zones.END_CREDIT = false
        local horizon = ns.Zones.HORIZON
        local it = ns.Zones.Itinerary(state, ctx, ranked)
        -- (when staying in one zone is best inside the horizon on this data build, a longer one
        -- gives a trip to correct)
        if not (it and #it.segments >= 2) then
            ns.Zones.HORIZON = 4 * 3600
            it = ns.Zones.Itinerary(state, ctx, ranked)
        end
        local slow, factor
        for _, f in ipairs({ 1.5, 1.2, 1.05 }) do
            ctx.stepModel = { v = ns.Learn.STEP_VERSION, n = 5, w = { 0, 0, 0, 0, math.log(f), 0, 0, 0, 0 } }
            slow, factor = ns.Zones.Itinerary(state, ctx, ranked), f
            ctx.stepModel = nil
            if slow and #slow.segments >= 2 then break end
        end
        ns.Zones.END_CREDIT, ns.Zones.HORIZON = true, horizon
        ok(it and #it.segments >= 2, "an itinerary with a trip")
        ok(slow and #slow.segments >= 2)
        eq({ slow.segments[1].map, slow.segments[2].map, slow.segments[1].leaveKey },
            { it.segments[1].map, it.segments[2].map, it.segments[1].leaveKey }, "the same way through the zones")
        local over = ns.Planner.SWITCH_OVERHEAD
        H.near(slow.segments[2].travel - over, (it.segments[2].travel - over) * factor, 1e-6)
    end)

    test("the first zone is left at a step of its ranked plan", function()
        local first = it.segments[1]
        local plan
        for _, z in ipairs(ranked) do if z.map == first.map then plan = z.plan end end
        eq(plan.order[first.leave], first.leaveKey)
        ok(plan.steps[first.leave].cumXP == first.xp or math.abs(plan.steps[first.leave].cumXP - first.xp) < 1)
    end)

    test("a short horizon leaves no time for a second zone", function()
        local was = ns.Zones.HORIZON
        ns.Zones.HORIZON = 1500
        local short = ns.Zones.Itinerary(state, ctx, ranked)
        ns.Zones.HORIZON = was
        eq(#short.segments, 1)
        eq(short.xp, short.stay)
    end)

    test("the shown order of zones is kept unless another is clearly better", function()
        local again = ns.Zones.Itinerary(state, ctx, ranked, { was = it })
        eq(#again.segments, #it.segments)
        for i, seg in ipairs(it.segments) do eq(again.segments[i].map, seg.map) end
        -- an order that was shown before but is far worse does not stick
        local last = ranked[#ranked]
        local poor = ns.Zones.Itinerary(state, ctx, ranked, { was = { segments = { { map = last.map } } } })
        ok(poor.xp >= it.xp * 0.99, "a poor old order is dropped")
    end)

    test("the plan on screen is used for its zone", function()
        local shown = ranked[1]
        local mine = ns.Zones.PlanZone(shown.map, ctx)
        local with = ns.Zones.Itinerary(state, ctx, ranked, { shown = shown.map, plan = mine })
        ok(with and with.xp > 0)
        eq(with.shown, shown.map)
        ok(with.here and with.here > 0, "what starting in the shown zone is worth")
    end)

    test("every zone of an itinerary carries the plan it is followed by", function()
        for i, seg in ipairs(it.segments) do
            ok(seg.plan and #seg.plan.steps > 0, "a plan for zone " .. seg.map)
            if seg.leave then eq(seg.plan.order[seg.leave], seg.leaveKey) end
            if i == 1 then
                local plan
                for _, z in ipairs(ranked) do if z.map == seg.map then plan = z.plan end end
                ok(seg.plan == plan, "the first zone: the plan it was ranked with")
            else
                local before = it.segments[i - 1]
                local from = before.plan.steps[before.leave].loc
                ok(seg.plan.carried, "later zones: planned again from where the zone before is left")
                H.near(seg.travel, ns.Planner.SWITCH_OVERHEAD + ctx.travel:Seconds(from, seg.plan.steps[1].loc), 1e-6)
            end
        end
    end)

    test("the zone in hand is finished and left for the next however little is left in it", function()
        -- the shown zone with only the end of its route left: under MIN_STAY of it
        local shown = ranked[1]
        local full = shown.plan
        local from = #full.steps
        while from > 1 and full.steps[#full.steps].t - full.steps[from - 1].t + full.steps[from - 1].seconds < ns.Zones.MIN_STAY * 0.8 do
            from = from - 1
        end
        local base = full.steps[from]
        local t0, xp0 = base.t - base.seconds - base.travel, from > 1 and full.steps[from - 1].cumXP or 0
        local rest = {}
        for k, v in pairs(full) do rest[k] = v end
        rest.steps, rest.order = {}, {}
        for i = from, #full.steps do
            local step = {}
            for k, v in pairs(full.steps[i]) do step[k] = v end
            step.t, step.cumXP = step.t - t0, step.cumXP - xp0
            rest.steps[#rest.steps + 1], rest.order[#rest.order + 1] = step, full.order[i]
        end
        rest.peak = #rest.steps
        local left = rest.steps[#rest.steps].t
        ok(#rest.steps >= 2 and left < ns.Zones.MIN_STAY and rest.steps[#rest.steps].cumXP > 0,
            string.format("%d steps and %d s left", #rest.steps, left))
        local with = ns.Zones.Itinerary(state, ctx, ranked, { shown = shown.map, plan = rest })
        eq(with.segments[1].map, shown.map, "what is left here is done first")
        ok(#with.segments >= 2, "then the next zone")
        ok(with.segments[1].seconds < ns.Zones.MIN_STAY and with.segments[1].leaveKey, "a short stay, left at a step")
        ok(with.segments[2].seconds >= ns.Zones.MIN_STAY, "a zone that takes a trip is still a real stay")
        ok(with.segments[2].plan and #with.segments[2].plan.steps > 0, "with its route")
        eq(with.here, with.xp)
        bannerIs(with, rest, shown.map)
        eq(ns.Zones.NextZone(with, shown.map), with.segments[2].map)
        -- only for the zone on screen: the same short plan under another zone's name must stay MIN_STAY
        local other = ns.Zones.Itinerary(state, ctx, ranked, { plan = rest })
        for i, seg in ipairs(other.segments) do
            ok(seg.seconds >= ns.Zones.MIN_STAY or i == #other.segments, "no short stays without a zone in hand")
        end
    end)

    test("a finished zone at the front of the shown order is passed over: the rest of the order stands", function()
        local order = { { map = 999999 } }
        for _, seg in ipairs(it.segments) do order[#order + 1] = { map = seg.map } end
        local again = ns.Zones.Itinerary(state, ctx, ranked, { was = { segments = order } })
        eq(#again.segments, #it.segments)
        for i, seg in ipairs(it.segments) do eq(again.segments[i].map, seg.map) end
        -- the order after it is kept as an order is: the worst zone first is not what comes out by itself
        local last = ranked[#ranked]
        local stuck = ns.Zones.Itinerary(state, ctx, ranked, { was = { segments = { { map = 999999 }, { map = last.map } } } })
        ok(stuck.xp >= it.xp * 0.99, "a poor rest of the order is dropped as before")
    end)

    test("the next zone after a finished one is the itinerary's, when it was made for that zone", function()
        local next = ns.Zones.NextZone
        local made = { shown = 1, segments = { { map = 1 }, { map = 2 }, { map = 3 } } }
        eq(next(made, 1), 2)
        eq(next({ shown = 1, segments = { { map = 1 } } }, 1), nil, "it ends here")
        eq(next({ shown = 1, segments = { { map = 5 }, { map = 6 } } }, 1), 5, "it wanted us elsewhere already")
        eq(next(made, 2), nil, "made for another zone")
        eq(next(nil, 1), nil)
        eq(next(made, nil), nil)
    end)

    test("leaving a zone: quests still held go along in the log, with what is done so far", function()
        local plan = ranked[1].plan
        -- a turn-in after which a quest is held whose work is all done, and one with work left
        local function held(p)
            local accepted, left, turned, worked = {}, {}, {}, {}
            for i, step in ipairs(plan.steps) do
                for _, q in ipairs(step.quests) do
                    if step.kind == "accept" and i <= p then accepted[q.id] = true end
                    if step.kind == "turnin" and i <= p then turned[q.id] = true end
                    if step.kind == "work" and i > p then left[q.id] = true end
                    if step.kind == "work" and i <= p then worked[q.id] = true end
                end
            end
            local complete, partial = {}, {}
            for id in pairs(accepted) do
                if not turned[id] then
                    if not left[id] then complete[#complete + 1] = id else partial[#partial + 1] = id end
                end
            end
            table.sort(complete); table.sort(partial)
            return complete, partial, turned, worked
        end
        local leave, complete, partial, turned, worked
        for i, step in ipairs(plan.steps) do
            if step.kind == "turnin" then
                local c, part, t, w = held(i)
                if #c > 0 and #part > 0 then leave, complete, partial, turned, worked = i, c, part, t, w; break end
            end
        end
        ok(leave, "a moment with a finished quest and an unfinished one in hand")
        local after, carried = ns.Zones.Project(state, ctx, plan, leave)
        local log = {}
        for _, entry in ipairs(after.log) do log[entry.id] = entry end
        eq(#after.log, #complete + #partial, "exactly the quests in hand")
        for _, id in ipairs(complete) do
            ok(log[id] and log[id].isComplete, "finished, to be turned in: " .. id)
            ok(carried[id] and after.carried[id])
            ok(not after.completed[id])
        end
        for _, id in ipairs(partial) do
            ok(log[id] and not log[id].isComplete, "work left: " .. id)
            local ticked = 0
            for _, o in ipairs(log[id].objectives) do if o.finished then ticked = ticked + 1 end end
            ok((ticked > 0) == (worked[id] == true), "objectives done so far are ticked off: " .. id)
        end
        for id in pairs(turned) do ok(after.completed[id] and not log[id], "turned in: " .. id) end
        ok(after.level >= state.level and after.map == plan.steps[leave].loc.map)
        -- the same zone planned from there: the finished quests are only turned in
        local again = ns.Zones.PlanZone(ranked[1].map, ns.Zones.Context(after))
        local at = {}
        for i, key in ipairs(again.order) do at[key] = i end
        local turnedIn = 0
        for _, id in ipairs(complete) do
            ok(not at["P:" .. id], "not accepted twice: " .. id)
            if at["T:" .. id] then turnedIn = turnedIn + 1 end
        end
        ok(turnedIn >= 1, "a quest brought along is turned in")
        for _, id in ipairs(partial) do ok(not at["P:" .. id], "not accepted twice: " .. id) end
    end)

    test("a quest brought along is turned in outside the zone only in an itinerary", function()
        -- finished in the log, turn-in in another zone: a zone's own plan leaves it alone
        local plan = ranked[1].plan
        local id = plan.steps[plan.peak].quests[1].id
        local other
        for _, z in ipairs(ranked) do
            if z.map > 0 and z.map ~= ranked[1].map and z.map ~= plan.steps[plan.peak].loc.map then other = z.map; break end
        end
        local entry = { id = id, title = "carried", level = 20, isComplete = true, objectives = {} }
        local function turnsIn(carried)
            local st = {}
            for k, v in pairs(state) do st[k] = v end
            st.log, st.carried = { entry }, carried
            local p = ns.Zones.PlanZone(other, ns.Zones.Context(st))
            for _, key in ipairs(p.order) do if key == "T:" .. id then return true end end
            for _, e in ipairs(p.lists.skipped) do if e.id == id then return "considered" end end
            return false
        end
        eq(turnsIn(nil), false, "not this zone's business")
        ok(turnsIn({ [id] = true }), "brought along: turned in on the way, or weighed and left out as slow")
    end)

    test("three zones: the second and third are planned from where the one before is left", function()
        -- (how many zones fit is the plans' business: seven hours hold three, with the search's
        -- fix for quests before their level and without it; five hours held three only without)
        local was, HOURS = ns.Zones.HORIZON, 7
        ns.Zones.HORIZON = HOURS * 3600
        local long = ns.Zones.Itinerary(state, ctx, ranked)
        local again = ns.Zones.Itinerary(state, ctx, ranked)
        ns.Zones.HORIZON = was
        eq(#long.segments, 3, HOURS .. " hours are enough for three zones")
        ok(long.xp > long.stay)
        local clock, xp, seen = 0, 0, {}
        for i, seg in ipairs(long.segments) do
            ok(not seen[seg.map], "no zone twice")
            seen[seg.map] = true
            clock, xp = clock + seg.travel + seg.seconds, xp + seg.xp
            ok(seg.seconds >= ns.Zones.MIN_STAY)
            eq(seg.leave ~= nil, i < 3, "every zone but the last is left at a step")
            ok(seg.carried >= 0 and seg.carriedXP <= seg.xp, "XP of quests brought along is part of the zone's XP")
            eq(again.segments[i].map, seg.map, "the same answer twice")
            eq(again.segments[i].leaveKey, seg.leaveKey)
        end
        eq(long.segments[1].carried, 0, "nothing is brought along to the first zone")
        ok(clock <= HOURS * 3600 + 1, "inside the horizon: " .. clock)
        ok(math.abs(xp - long.xp) <= 3, "the zones' XP adds up to the total")
        eq(again.xp, long.xp)
    end)

    test("the order on screen stays within 5% when starting in the shown zone", function()
        local Z = ns.Zones
        local S, P = it.segments[1].map, nil
        for _, z in ipairs(ranked) do if z.map == S then P = z.plan end end
        local border, seam, keep = Z.BORDER, Z.SEAM, Z.KEEP_ITINERARY
        Z.BORDER, Z.SEAM = false, false
        local function run(was) return Z.Itinerary(state, ctx, ranked, { shown = S, plan = P, was = was }) end
        local fresh = run()
        local B, forced
        for _, z in ipairs(ranked) do
            if not B and z.map ~= S and z.map ~= fresh.segments[2].map and #z.plan.steps > 0 then
                Z.KEEP_ITINERARY = 1e9
                local got = run({ segments = { { map = S }, { map = z.map } } })
                Z.KEEP_ITINERARY = keep
                if got.segments[2] and got.segments[2].map == z.map then B, forced = z.map, got end
            end
        end
        local was = { segments = { { map = S }, { map = B } } }
        local again = B and run(was)
        local same = run(fresh)
        Z.BORDER, Z.SEAM, Z.KEEP_ITINERARY = border, seam, keep
        ok(B, "another second zone that can be forced")
        -- (the outputs are floored: a figure that close to the bar decides nothing)
        if math.abs(fresh.xp / forced.xp - keep) >= 1e-3 then
            eq((again.segments[2] and again.segments[2].map == B) or false, fresh.xp <= forced.xp * keep, "kept unless the other earns 5% more")
        end
        eq({ same.segments[2].map, same.segments[1].leaveKey, same.xp },
            { fresh.segments[2].map, fresh.segments[1].leaveKey, fresh.xp }, "the order and step on screen stand")
    end)

    test("the step the first zone was left after is kept", function()
        local Z = ns.Zones
        local S, P = it.segments[1].map, nil
        for _, z in ipairs(ranked) do if z.map == S then P = z.plan end end
        local k
        for i = 2, #P.steps do
            if not k and P.steps[i].kind == "turnin" and P.steps[i].t < Z.HORIZON / 2 then k = P.order[i] end
        end
        ok(k, "a turn-in in the first half of the horizon")
        local keep, border, seam = Z.KEEP_ITINERARY, Z.BORDER, Z.SEAM
        -- (the way across, planned together, may move the step the zone is left after)
        Z.KEEP_ITINERARY, Z.BORDER, Z.SEAM = 1e9, false, false
        local fresh = Z.Itinerary(state, ctx, ranked, { shown = S, plan = P })
        local got = Z.Itinerary(state, ctx, ranked, { shown = S, plan = P,
            was = { segments = { { map = S, leaveKey = k }, { map = fresh.segments[2].map } } } })
        Z.KEEP_ITINERARY, Z.BORDER, Z.SEAM = keep, border, seam
        ok(#got.segments >= 2)
        eq(got.segments[1].leaveKey, k)
    end)

    test("move-on follows the itinerary: its first zone against starting in the shown zone", function()
        local first = it.segments[1].map
        local shown
        for _, z in ipairs(ranked) do
            if z.map ~= first and #z.plan.steps > 0 then shown = z end -- the worst-ranked other zone
        end
        local with = ns.Zones.Itinerary(state, ctx, ranked, { shown = shown.map })
        ok(with.here and with.here > 0, "something is left in the shown zone")
        eq(with.segments[1].map, shown.map, "the itinerary starts in the shown zone: the player chose it")
        eq(with.xp, with.here)
        bannerIs(with, shown.plan, shown.map)
        -- shown zone = the itinerary's first zone: nothing to suggest
        local stay = ns.Zones.Itinerary(state, ctx, ranked, { shown = first })
        eq(stay.segments[1].map, first)
        eq(stay.here, stay.xp)
        local plan
        for _, z in ipairs(ranked) do if z.map == first then plan = z.plan end end
        bannerIs(stay, plan, first)
    end)
end)

-- In the game the planner runs in a coroutine that yields at its checkpoints, and the game's Lua
-- cannot yield through pcall, a metamethod or a C function such as table.sort. Here the whole
-- planning runs that way, with every option that changes the code path switched on in turn.
H.suite("Planning yields (real data)", function()
    test("ranking, a warm plan, the itinerary and the debug recording all yield cleanly", function()
        local Data, raw = init("Alliance", "PALADIN")
        local ns = data()
        Data.BuildIndex()
        local completed = {}
        for _, id in ipairs(ns.Data.QuestIds()) do
            local q = Data.GetQuest(id)
            if q and q.level > 0 and q.level <= 18 then completed[id] = true end
        end
        local function run(settings)
            local saved = {}
            for path, v in pairs(settings) do
                local mod, key = path:match("^(%a+)%.(.+)$")
                saved[path] = ns[mod][key]
                ns[mod][key] = v
            end
            local yields, calls = 0, 0
            local co = coroutine.create(function()
                local state = { level = 22, faction = "Alliance", class = "PALADIN", raceId = 1, map = 1433, x = 0.30, y = 0.44,
                    log = {}, completed = completed, capacity = 40, memory = ns.Memory.New(), now = 0 }
                state.checkpoint = function()
                    calls = calls + 1
                    if calls % 7 == 0 then yields = yields + 1; coroutine.yield() end
                end
                local ctx = ns.Zones.Context(state)
                local ranked = ns.Zones.Rank(ctx)
                local again = ns.Zones.PlanZone(1433, ctx) -- warm, from the memory the ranking filled
                ns.Zones.Itinerary(state, ctx, ranked, { shown = 1433, plan = again })
                ctx.trace = 1433
                ns.Zones.PlanZone(1433, ctx, nil, nil, { readOnly = true })
                ctx.trace = nil
                return #ranked
            end)
            local ok, result
            repeat ok, result = coroutine.resume(co) until not ok or coroutine.status(co) == "dead"
            for path, v in pairs(saved) do
                local mod, key = path:match("^(%a+)%.(.+)$")
                ns[mod][key] = v
            end
            return ok, result, yields
        end
        for _, settings in ipairs({
            {},
            { ["Planner.NEAR_K"] = 6 },
            { ["Planner.NEAR_K"] = 6, ["Planner.NEAR_SCOPE"] = "all" },
            { ["Objective.MODE"] = "dinkelbach", ["Objective.POLISH"] = true },
            { ["Search.ACCEPT"] = "rrt", ["Search.RESTART_AFTER"] = 10, ["Search.STALL_ROUNDS"] = 30, ["Search.EXTRA_OPS"] = "all" },
            { ["Zones.REUSE"] = true },
            { ["Search.STREAM"] = "rounds" },
            { ["Planner.GOAL"] = "surplus" },
            { ["Planner.GOAL"] = "surplus", ["Planner.NEAR_K"] = 6, ["Search.ACCEPT"] = "rrt", ["Zones.REUSE"] = true },
        }) do
            local names = {}
            for k, v in pairs(settings) do names[#names + 1] = k .. "=" .. tostring(v) end
            table.sort(names)
            local fine, result, yields = run(settings)
            ok(fine, "planning ran to the end (" .. table.concat(names, ", ") .. "): " .. tostring(result))
            ok(yields > 100, "and yielded along the way: " .. tostring(yields))
        end
    end)
end)
