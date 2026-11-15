-- tests/test_data.lua: the runtime data reader (adapters/Data.lua) on hand-made records, and the
-- runtime merge (adapters/Merge.lua) on a small fake QuestieDB and ForeverDB layer.
local H, M = ...
local test, eq, ok, near, contains = H.test, H.eq, H.ok, H.near, H.contains

local Merge = assert(loadfile(H.root .. "/LevelScout/adapters/Merge.lua"))("LevelScout", {})
local S = Merge.Spot

-- Quest record builder: same field order as adapters/Merge.lua (docs/data-format.md).
local QFIELDS = { "name", "level", "min", "max", "side", "races", "classes", "zone", "sort", "flags", "xp",
    "xpSrc", "starts", "ends", "objectives", "preAll", "preAny", "exclusive", "breadcrumbFor", "nextInChain",
    "parent", "repMin", "repMax", "skill", "sourceItem", "groupSize", "seen", "prevSeen", "lowest", "area" }
local function quest(t)
    local out = {}
    for i, k in ipairs(QFIELDS) do
        local v = t[k]
        if v == nil then v = (k == "level" or k == "min" or k == "max" or k == "races" or k == "classes"
            or k == "zone" or k == "sort" or k == "area") and 0 or "" end
        out[i] = tostring(v)
    end
    return table.concat(out, "|")
end

local ALLIANCE_CLASSIC = 1 + 4 + 8 + 64 -- Human, Dwarf, Night Elf, Gnome
local HORDE_CLASSIC = 2 + 16 + 32 + 128

local function fixture()
    local curve = {}
    for i = 1, 60 do curve[i] = i * 100 end
    return {
        meta = { build = "1.60.1.70888", generated = "2026-11-12", sources = { QuestieDB = "1.0.15", ForeverDB = "0.58.2" } },
        quests = {
            [7] = quest({ name = "Kobold Camp Cleanup", level = 2, min = 1, side = "a", races = ALLIANCE_CLASSIC,
                zone = 1429, xp = 170, xpSrc = "f", starts = "n197", ends = "n197", objectives = "c6:10:C",
                seen = 16, area = 9 }),
            [15] = quest({ name = "Investigate Echo Ridge", level = 3, min = 1, zone = 1429, starts = "n197",
                ends = "n197", objectives = "c257:10:C", preAny = "7", xp = 250, xpSrc = "q" }),
            [33] = quest({ name = "Wolves Across the Border", level = 4, min = 2, zone = 1429, starts = "n196",
                ends = "n196", objectives = "i750:8:C" }),
            [166] = quest({ name = "The Defias Brotherhood", level = 22, min = 14, flags = "d", zone = 1436,
                starts = "n234", ends = "n234", objectives = "c639:1:C", preAny = "155" }),
            [176] = quest({ name = "Wanted: Hogger", level = 11, min = 6, zone = 1429, starts = "o68", ends = "n240",
                objectives = "c448:1:C" }),
            [177] = quest({ name = "Elite Hides", level = 12, min = 8, zone = 1429, starts = "n197", ends = "n197",
                objectives = "i751:5:C" }),
            [184] = quest({ name = "Furlbrow's Deed", level = 13, min = 9, zone = 1436, starts = "i1972", ends = "n237" }),
            [185] = quest({ name = "Deadmines Errand", level = 20, min = 15, flags = "d", zone = 1436, starts = "n234" }),
            [500] = quest({ name = "Mage Only", level = 10, min = 10, side = "h", races = HORDE_CLASSIC, classes = 128 }),
            [600] = quest({ name = "Skill", skill = "171:50" }),
            [601] = quest({ name = "Rep cap", repMax = "529:3000" }),
            [602] = quest({ name = "Parent", parent = 7 }),
            [603] = quest({ name = "Exclusive", exclusive = "15" }),
            [604] = quest({ name = "Chain", nextInChain = 15 }),
            [605] = quest({ name = "Breadcrumb", breadcrumbFor = 15 }),
            [606] = quest({ name = "Skyborne only", races = 2 ^ 32 }),
            [607] = quest({ name = "Repeatable", flags = "p" }),
            [608] = quest({ name = "Needs both", preAll = "7,15" }),
            [687] = quest({ name = "Theldurin the Lost", starts = "n2786" }),
            [700] = quest({ name = "Alliance edition" }),
            [8315] = quest({ name = "The Calling", nextInChain = 8316 }),
            [90001] = quest({ name = "Riverglades Survey", level = 24, min = 20, zone = 2501, flags = "pyn",
                xp = 2100, xpSrc = "f", starts = "n300001", ends = "n300001",
                objectives = "c300011,300012:5:F;c300010:3:C;i900001:4:F;e:1:Q;r529:3000:Q", repMin = "529:-42000" }),
        },
        questText = { [7] = "Kill 10 Kobold Vermin, then return to Marshal McBride." },
        questSpots = { [90001] = { s = S(2501, 30, 30), e = S(2501, 30.5, 30), [4] = S(2501, 40, 50) .. " " .. S(2501, 41, 51) } },
        npcs = {
            [6] = "Kobold Vermin|1|2|0|0||" .. S(1429, 49.3, 36.7) .. " " .. S(1429, 51.4, 37.1),
            [197] = "Marshal McBride|10|10|0|2|A|" .. S(1429, 48.9, 41.6),
            [196] = "Eagan Peltskinner|5|5|0|0|A|" .. S(1429, 48, 40),
            [234] = "Gryan Stoutmantle|30|30|0|0|A|" .. S(1436, 56, 47),
            [448] = "Hogger|11|11|1|0||" .. S(1429, 26, 92),
            [452] = "Riverpaw Bandit|12|12|1|0||" .. S(1429, 25, 90),
            [453] = "Riverpaw Mystic|12|12|1|0||",
            [299] = "Young Wolf|1|1|0|0|AH|" .. S(1429, 45, 50),
            [69] = "Timber Wolf|2|2|0|0|AH|" .. S(1429, 44, 52),
            [2786] = "Gerrig Bonegrip|40|40|0|0|A|",
            [2787] = "Zaruk|40|40|0|0|H|",
            [300001] = "Surveyor Lin|25|25|0|4|AH|" .. S(2501, 30, 30),
            [300010] = "Marsh Lurker|22|23|0|0||" .. S(2501, 35, 40),
        },
        objects = { [68] = "Wanted Poster|" .. S(1429, 42, 65) },
        items = {
            [750] = "Tough Wolf Meat|69:70:f 299::||",
            [751] = "Elite Hide|452:30:w 453:25:m||",
            [900001] = "Lurker Scale|300010:55:w|501:20:k|300001",
            [1972] = "Westfall Deed|||",
        },
        world = {
            xpCurve = curve, xpDungeonMultiplier = 2,
            pace = { [2] = { c = 32.5, i = 12.1, o = 24.8, r = 7 } },
            enum = {
                raceMaskById = { [1] = 1, [2] = 2, [3] = 4, [4] = 8, [5] = 16, [6] = 32, [7] = 64, [8] = 128,
                    [95] = 2 ^ 32, [96] = 2 ^ 33 },
                classKeys = { WARRIOR = 1, PALADIN = 2, HUNTER = 4, ROGUE = 8, PRIEST = 16, SHAMAN = 64, MAGE = 128,
                    WARLOCK = 256, DRUID = 1024 },
            },
        },
    }
end

local function load(player, data)
    M.install()
    local ns = { data = data == nil and fixture() or data or nil }
    H.loadAddon(H.runtimeFiles(), ns)
    ns.Data.Init(player or { faction = "Alliance", class = "WARRIOR", clientBuild = "1.60.1.70888" })
    return ns.Data, ns
end

H.suite("Data init", function()
    test("valid data is usable with no notes", function()
        local Data = load()
        ok(Data.usable)
        eq(Data.status.state, "ok")
        eq(Data.status.build, "1.60.1.70888")
        eq(Data.status.notes, {})
    end)

    test("missing data: clear message, getters return nil", function()
        local Data = load(nil, false)
        ok(not Data.usable)
        eq(Data.status.state, "missing")
        contains(Data.status.message, "reinstall")
        eq(Data.GetQuest(7), nil)
        eq(Data.GetNpc(6), nil)
        eq(Data.BuildIndex(), nil)
        eq(Data.QuestsInZone(1429), nil)
    end)

    test("a missing data table is reported as broken", function()
        local data = fixture()
        data.items = nil
        local Data = load(nil, data)
        ok(not Data.usable)
        eq(Data.status.state, "broken")
        contains(Data.status.message, "'items'")
    end)

    test("newer client build gives a note but stays usable", function()
        local Data = load({ faction = "Alliance", class = "WARRIOR", clientBuild = "1.60.2.71000" })
        ok(Data.usable)
        contains(Data.status.notes[1], "1.60.2.71000")
    end)
end)

H.suite("Data records", function()
    test("quest fields, objectives with count sources, givers, spots", function()
        local Data = load()
        local q = Data.GetQuest(90001)
        eq({ q.name, q.level, q.minLevel, q.zone, q.xp, q.xpSource }, { "Riverglades Survey", 24, 20, 2501, 2100, "ForeverDB" })
        eq(q.flags, { repeatable = true, daily = true, new = true })
        eq(q.starters, { { kind = "npc", id = 300001 } })
        eq(#q.objectives, 5)
        eq(q.objectives[1], { index = 1, kind = "kill", ids = { 300011, 300012 }, count = 5, countSource = "ForeverDB" })
        eq(q.objectives[2], { index = 2, kind = "kill", ids = { 300010 }, count = 3, countSource = "CMaNGOS" })
        eq(q.objectives[3].kind, "item")
        eq(q.objectives[4], { index = 4, kind = "event", ids = {}, count = 1, countSource = "QuestieDB" })
        eq(q.objectives[5], { index = 5, kind = "reputation", ids = { 529 }, count = 3000, countSource = "QuestieDB" })
        eq(q.repMin, { id = 529, value = -42000 })
        eq(q.spots.start, { { map = 2501, x = 30, y = 30 } })
        eq(q.spots[4], { { map = 2501, x = 40, y = 50 }, { map = 2501, x = 41, y = 51 } })
        eq(q.spots[1], nil)
    end)

    test("quest text, unknown count, item starter, empty objectives", function()
        local Data = load()
        eq(Data.GetQuest(7).text, "Kill 10 Kobold Vermin, then return to Marshal McBride.")
        eq(Data.GetQuest(184).starters, { { kind = "item", id = 1972 } })
        eq(Data.GetQuest(184).objectives, {})
        eq(Data.GetQuest(424242), nil)
    end)

    test("NPC, object and item records", function()
        local Data = load()
        local hogger = Data.GetNpc(448)
        eq({ hogger.name, hogger.rank, hogger.minLevel }, { "Hogger", 1, 11 })
        eq(hogger.spots, { { map = 1429, x = 26, y = 92 } })
        eq(Data.GetNpc(197).friendly, "A")
        eq(Data.GetNpc(2786).spots, {})
        eq(Data.GetObject(68).spots, { { map = 1429, x = 42, y = 65 } })
        local scale = Data.GetItem(900001)
        eq(scale.drops, { { id = 300010, rate = 0.55, source = "Wowhead" } })
        eq(scale.objects, { { id = 501, rate = 0.2, source = "CMaNGOS" } })
        eq(scale.vendors, { 300001 })
    end)

    test("drop rates carry their source; unknown rates are nil", function()
        local Data = load()
        local rate, source = Data.GetDropRate(750, 69)
        near(rate, 0.70)
        eq(source, "ForeverDB")
        eq({ Data.GetDropRate(750, 299) }, {})
        eq({ Data.GetDropRate(750, 6) }, {})
    end)

    test("objective sources: kills, drops with rates, objects, vendors", function()
        local Data = load()
        local q = Data.GetQuest(90001)
        eq(Data.ObjectiveSources(q.objectives[1]), { { kind = "npc", id = 300011 }, { kind = "npc", id = 300012 } })
        eq(Data.ObjectiveSources(q.objectives[3]), {
            { kind = "npc", id = 300010, rate = 0.55, source = "Wowhead" },
            { kind = "object", id = 501, rate = 0.2, source = "CMaNGOS" },
            { kind = "vendor", id = 300001 },
        })
        eq(Data.ObjectiveSources(q.objectives[4]), {})
    end)

    test("records are parsed once and cached", function()
        local Data = load()
        ok(Data.GetQuest(7) == Data.GetQuest(7))
        ok(Data.GetNpc(6) == Data.GetNpc(6))
    end)
end)

-- The shipped record source: the ForeverDB layer (ns.data.fdb) and a fake QuestieDB that has
-- already applied its corrections for `faction`.
local ALLIANCE_ALL = 1 + 4 + 8 + 64 + 2 ^ 32

local function layer()
    return {
        meta = { build = "1.60.1.70888", generated = "2026-11-15", sources = { ForeverDB = "0.60.4", ForeverDBData = "x" } },
        fdb = {
            qcQuests = {
                [7] = "Kobold Camp Cleanup (CMaNGOS)|2|1|a|0|0||||n197|n197|c6:10||",
                [33] = "Wolves Across the Border|4|2|a|0|0||||n196|n196|i750:8||",
                [687] = "Theldurin the Lost|40|30||0|0||||n2786|n2786|||",
            },
            qfQuests = { [90001] = "Riverglades Survey|24|20|Survey the marsh.|n300001|n300001|17|1|||" },
            qcGone = {}, qcExcl = {}, questXP = { [7] = 170 }, qobj = { [90001] = "c:5" }, groupSize = {},
            startMap = { [90001] = 2501 }, qfPoi = {}, qfSeen = { [90001] = { s = S(2501, 30, 30) } }, qfArea = {},
            qcNpc = { [196] = "Eagan Peltskinner|" .. S(1429, 48, 40) }, qfNpcNames = { [300001] = "Surveyor Lin" },
            qfNpcSpots = { [300001] = S(2501, 30, 30) }, npcLv = { [197] = 1010 }, npcSpot = {},
            qcObj = {}, qfItems = {}, qdrop = { [750] = { [69] = 70 } }, qcItem = {},
            dungeons = {},
        },
        world = { xpCurve = (function() local c = {}; for i = 1, 60 do c[i] = i * 10 end; return c end)(),
            xpDungeonMultiplier = 2, pace = {}, maps = {}, zones = {} },
    }
end

local function fakeQuestieDB(faction, over)
    local spec = {
        zones = { [12] = 1429, [40] = 1436 },
        quests = {
            [7] = { name = "Kobold Camp Cleanup", questLevel = 2, requiredLevel = 1, requiredRaces = ALLIANCE_ALL,
                zoneOrSort = 12, startedBy = { { 197 } }, finishedBy = { { 197 } }, objectives = { { { 6 } } },
                objectivesText = { "Kill 10 Kobold Vermin, then return to Marshal McBride." } },
            [33] = { name = "Wolves Across the Border", questLevel = 4, requiredLevel = 2, zoneOrSort = 12,
                startedBy = { { 196 } }, finishedBy = { { 196 } }, objectives = { nil, nil, { { 750 } } },
                preQuestSingle = { 7 } },
            [687] = { name = "Theldurin the Lost", questLevel = 40, zoneOrSort = 40,
                startedBy = { { faction == "Horde" and 2787 or 2786 } }, finishedBy = { { 2786 } } },
            [555] = { name = "Not in Forever", questLevel = 10, zoneOrSort = 12 },
            [60001] = { name = "Unseen in Forever", questLevel = 30, zoneOrSort = 40 },
        },
        npcs = {
            [197] = { name = "Marshal McBride", minLevel = 5, maxLevel = 5, rank = 0, npcFlags = 2,
                friendlyToFaction = "A", spawns = { [12] = { { 48.9, 41.6 } } } },
            [6] = { name = "Kobold Vermin", minLevel = 1, maxLevel = 2, rank = 0, spawns = { [12] = { { 49.3, 36.7 } } } },
            [69] = { name = "Timber Wolf", minLevel = 2, maxLevel = 2, spawns = { [12] = { { 44, 52 } } } },
            [299] = { name = "Young Wolf", minLevel = 1, maxLevel = 1, spawns = { [12] = { { 45, 50 } } } },
        },
        items = { [750] = { name = "Tough Wolf Meat", npcDrops = { 69, 299 } } },
        xp = { [33] = { 4, 340 } },
        wowhead = { [750] = { [299] = 33.3 } },
    }
    for k, v in pairs(over or {}) do spec[k] = v end
    return M.fakeQuestieDB(spec)
end

local function loadMerge(lib, player, data)
    M.install({ questiedb = lib or nil })
    local ns = { data = data or layer() }
    H.loadAddon(H.runtimeFiles(), ns)
    ns.Data.Init(player or { faction = "Alliance", class = "WARRIOR", clientBuild = "1.60.1.70888" })
    return ns.Data, ns
end

H.suite("Data: the QuestieDB dependency", function()
    test("QuestieDB missing: a clear message, nothing usable, no errors", function()
        local Data = loadMerge(nil)
        ok(not Data.usable)
        eq(Data.status.state, "questiedb-missing")
        contains(Data.status.message, "QuestieDB is missing")
        contains(Data.status.message, "install or enable QuestieDB")
        contains(Data.status.message, "/reload")
        eq(Data.GetQuest(7), nil)
        eq(Data.GetNpc(197), nil)
        eq(Data.BuildIndex(), nil)
        eq(Data.QuestsInZone(1429), nil)
        eq(Data.World(), nil)
        eq(Data.QuestIds(), {})
    end)

    test("QuestieDB with the wrong contract: says which is needed and which is installed", function()
        local Data = loadMerge(fakeQuestieDB("Alliance", { contract = 3, version = "1.0.9" }))
        ok(not Data.usable)
        eq(Data.status.state, "questiedb-version")
        contains(Data.status.message, "needs QuestieDB contract 4")
        contains(Data.status.message, "QuestieDB 1.0.9 (contract 3)")
        contains(Data.status.message, "Update whichever is older")
        eq(Data.GetQuest(7), nil)
        Data = loadMerge(fakeQuestieDB("Alliance", { contract = 9, minContract = 5 }))
        eq(Data.status.state, "questiedb-version", "a newer QuestieDB that dropped contract 4")
        local old = fakeQuestieDB("Alliance")
        old.RequireContract = nil
        Data = loadMerge(old)
        eq(Data.status.state, "questiedb-version")
        contains(Data.status.message, "too old")
    end)

    test("a QuestieDB without the entity API is reported as broken", function()
        local lib = fakeQuestieDB("Alliance")
        lib.Item = nil
        local Data = loadMerge(lib)
        eq(Data.status.state, "questiedb-broken")
        contains(Data.status.message, "LibQuestieDB.Item")
    end)

    test("a working QuestieDB: usable, and the status names it", function()
        local Data = loadMerge(fakeQuestieDB("Alliance"))
        ok(Data.usable)
        eq(Data.status.mode, "merge")
        eq(Data.status.sources.QuestieDB, "QuestieDB 1.1.1 (contract 4)")
        eq(Data.status.sources.ForeverDB, "0.60.4")
    end)
end)

H.suite("Data: records built at runtime", function()
    test("quests: ForeverDB first for name and levels, QuestieDB for structure, CMaNGOS counts", function()
        local Data = loadMerge(fakeQuestieDB("Alliance"))
        local q = Data.GetQuest(7)
        eq({ q.name, q.level, q.minLevel, q.zone, q.side, q.area }, { "Kobold Camp Cleanup", 2, 1, 1429, "a", 12 },
            "QuestieDB's name over CMaNGOS'; zone from QuestieDB's area")
        eq({ q.xp, q.xpSource }, { 170, "ForeverDB" })
        eq(q.starters, { { kind = "npc", id = 197 } })
        eq(q.objectives, { { index = 1, kind = "kill", ids = { 6 }, count = 10, countSource = "CMaNGOS" } })
        eq(q.text, "Kill 10 Kobold Vermin, then return to Marshal McBride.")
        local wolves = Data.GetQuest(33)
        eq({ wolves.xp, wolves.xpSource }, { 340, "QuestieDB" })
        eq(wolves.preAny, { 7 })
        eq(wolves.objectives[1].count, 8)
        eq(Data.Raw("quests", 7), "Kobold Camp Cleanup|2|1|0|a|" .. string.format("%.0f", ALLIANCE_ALL)
            .. "|0|1429|0||170|f|n197|n197|c6:10:C|" .. ("|"):rep(14) .. "12")
    end)

    test("quests only one source knows; quests left out", function()
        local Data = loadMerge(fakeQuestieDB("Alliance"))
        local survey = Data.GetQuest(90001)
        eq({ survey.name, survey.level, survey.zone }, { "Riverglades Survey", 24, 2501 }, "Forever-only, zone where players saw it start")
        eq(survey.flags, { new = true })
        eq(survey.objectives, { { index = 1, kind = "kill", ids = {}, count = 5, countSource = "ForeverDB" } })
        eq(survey.spots.start, { { map = 2501, x = 30, y = 30 } })
        eq(Data.GetQuest(60001).flags, { unseen = true }, "QuestieDB only, in the Forever id range")
        eq(Data.GetQuest(555), nil, "a classic id ForeverDB's client-filtered table lacks is not in Forever")
        eq(Data.QuestIds(), { 7, 33, 687, 60001, 90001 })
    end)

    test("NPCs and items: QuestieDB spawns and drops, ForeverDB levels and rates", function()
        local Data = loadMerge(fakeQuestieDB("Alliance"))
        local mcbride = Data.GetNpc(197)
        eq({ mcbride.name, mcbride.minLevel, mcbride.maxLevel, mcbride.friendly, mcbride.npcFlags },
            { "Marshal McBride", 10, 10, "A", 2 }, "ForeverDB's observed level over QuestieDB's")
        eq(mcbride.spots, { { map = 1429, x = 48.9, y = 41.6 } })
        eq(Data.GetNpc(196).spots, { { map = 1429, x = 48, y = 40 } }, "CMaNGOS spots when QuestieDB has none")
        eq(Data.GetNpc(300001).name, "Surveyor Lin")
        eq(Data.GetNpc(424242), nil)
        local meat = Data.GetItem(750)
        eq({ meat.drops[1].id, meat.drops[1].source, meat.drops[2].id, meat.drops[2].source }, { 69, "ForeverDB", 299, "Wowhead" })
        near(meat.drops[1].rate, 0.7, 1e-9)
        local rate, source = Data.GetDropRate(750, 299)
        near(rate, 0.333, 1e-9)
        eq(source, "Wowhead")
    end)

    test("faction and class corrections are QuestieDB's, for the logged-in character", function()
        local Data = loadMerge(fakeQuestieDB("Alliance"))
        eq(Data.GetQuest(687).starters, { { kind = "npc", id = 2786 } })
        Data = loadMerge(fakeQuestieDB("Horde"), { faction = "Horde", class = "WARRIOR" })
        eq(Data.GetQuest(687).starters, { { kind = "npc", id = 2787 } })
    end)

    test("records are built once: repeated reads do not touch QuestieDB again", function()
        local lib = fakeQuestieDB("Alliance")
        local Data, ns = loadMerge(lib)
        Data.GetQuest(7)
        Data.GetNpc(197)
        Data.GetItem(750)
        local reads = lib.reads
        ok(reads > 0)
        ok(Data.GetQuest(7) == Data.GetQuest(7))
        Data.GetNpc(197)
        Data.GetItem(750)
        Data.GetDropRate(750, 69)
        eq(lib.reads, reads, "cached")
        ns.Data.Init({ faction = "Alliance", class = "WARRIOR" })
        Data.GetQuest(7)
        Data.GetNpc(197)
        eq(lib.reads, reads, "a second Init with the same QuestieDB keeps the built records")
        ns.Data.Init({ faction = "Horde", class = "WARRIOR" })
        Data.GetQuest(7)
        ok(lib.reads > reads, "another character: built again")
    end)

    test("the index reads only what it needs and matches the records", function()
        local Data = loadMerge(fakeQuestieDB("Alliance"))
        Data.BuildIndex()
        local lean = { Data.QuestsInZone(1429), Data.QuestsInZone(2501), Data.QuestsInZone(1436), Data.GetFollowUps(7) }
        eq(Data.GetFollowUps(7), { 33 })
        eq(Data.QuestsInZone(2501), { { id = 90001, inZone = true, giverInZone = true } })
        for _, id in ipairs(Data.QuestIds()) do Data.GetQuest(id) end
        Data.BuildIndex()
        eq({ Data.QuestsInZone(1429), Data.QuestsInZone(2501), Data.QuestsInZone(1436), Data.GetFollowUps(7) }, lean,
            "the same index from the full records")
    end)

    test("world tables made from every quest: computed by the index, or on first use", function()
        local Data = loadMerge(fakeQuestieDB("Alliance"))
        ok(not Data.IsIndexBuilt())
        local world = Data.World()
        eq(world.enum.classKeys.MAGE, 128, "QuestieDB's enums")
        ok(type(world.xpEstimate) == "table", "reading it builds the index")
        ok(Data.IsIndexBuilt())
        eq(world.dungeons, {})
        eq({ Data.GetQuestXP(687) }, { 400, "estimate" }, "too few samples for an estimate: the curve")
    end)
end)

H.suite("Data XP and tags", function()
    test("recorded XP, curve estimate, dungeon multiplier", function()
        local Data = load()
        eq({ Data.GetQuestXP(7) }, { 170, "ForeverDB" })
        eq({ Data.GetQuestXP(15) }, { 250, "QuestieDB" })
        eq({ Data.GetQuestXP(184) }, { 1300, "estimate" })
        eq({ Data.GetQuestXP(185) }, { 4000, "estimate" })
    end)

    test("XP estimate: level-and-kind median with its usual range, before the curve", function()
        local Data, ns = load()
        ns.data.world.xpEstimate = { t = { [13] = { 450, 300, 700 } }, o = { [4] = { 360, 250, 420 } }, d = {} }
        eq({ Data.GetQuestXP(184) }, { 450, "estimate", 300, 700 }, "no objectives: talk-to kind")
        eq({ Data.GetQuestXP(33) }, { 360, "estimate", 250, 420 }, "with objectives")
        eq({ Data.GetQuestXP(185) }, { 4000, "estimate" }, "no dungeon estimate: falls back to the curve")
        eq({ Data.GetQuestXP(7) }, { 170, "ForeverDB" }, "recorded XP always wins")
        ns.data.world.xpEstimate = nil
    end)

    test("tags: data flags first, then elite mobs, else none", function()
        local Data = load()
        eq({ Data.GetQuestTag(166) }, { "dungeon", "data" })
        eq({ Data.GetQuestTag(176) }, { "elite", "heuristic" })
        eq({ Data.GetQuestTag(177) }, { "elite", "heuristic" }, "item dropped only by elites")
        eq({ Data.GetQuestTag(33) }, { nil, "none" }, "wolves are not elite")
        eq({ Data.GetQuestTag(7) }, { nil, "none" })
    end)
end)

H.suite("Data availability", function()
    local human = { faction = "Alliance", raceId = 1, class = "WARRIOR" }
    local function ctx(extra)
        local c = { faction = human.faction, raceId = human.raceId, class = human.class, completed = {}, inLog = {} }
        for k, v in pairs(extra or {}) do c[k] = v end
        return c
    end

    test("race mask, faction side, class mask", function()
        local Data = load()
        eq({ Data.IsAvailable(7, ctx()) }, { true, nil })
        eq({ Data.IsAvailable(7, ctx({ raceId = 2, faction = "Horde" })) }, { false, "race" })
        eq({ Data.IsAvailable(500, ctx({ raceId = 2, faction = "Horde" })) }, { false, "class" })
        eq({ Data.IsAvailable(500, ctx({ raceId = 2, faction = "Horde", class = "MAGE" })) }, { true, nil })
        eq({ Data.IsAvailable(606, ctx()) }, { false, "race" })
        eq({ Data.IsAvailable(606, ctx({ raceId = 95 })) }, { true, nil }, "Skyborne bit above 32")
    end)

    test("completed, in log, repeatable", function()
        local Data = load()
        eq({ Data.IsAvailable(7, ctx({ completed = { [7] = true } })) }, { false, "completed" })
        eq({ Data.IsAvailable(7, ctx({ inLog = { [7] = true } })) }, { false, "in quest log" })
        eq({ Data.IsAvailable(607, ctx({ completed = { [607] = true } })) }, { true, nil })
    end)

    test("prerequisites: one-of and all-of", function()
        local Data = load()
        eq(Data.IsAvailable(15, ctx()), false)
        eq({ Data.IsAvailable(15, ctx({ completed = { [7] = true } })) }, { true, nil })
        eq(Data.IsAvailable(608, ctx({ completed = { [7] = true } })), false)
        eq(Data.IsAvailable(608, ctx({ completed = { [7] = true, [15] = true } })), true)
    end)

    test("exclusive, later chain step, breadcrumb, parent", function()
        local Data = load()
        local done15 = ctx({ completed = { [15] = true } })
        eq({ Data.IsAvailable(603, done15) }, { false, "exclusive with 15" })
        eq({ Data.IsAvailable(604, done15) }, { false, "later quest done" })
        eq({ Data.IsAvailable(605, ctx({ inLog = { [15] = true } })) }, { false, "breadcrumb target already taken" })
        eq(Data.IsAvailable(602, ctx()), false)
        eq(Data.IsAvailable(602, ctx({ inLog = { [7] = true } })), true)
    end)

    test("skills and reputation: unknown does not block, known does", function()
        local Data = load()
        eq({ Data.IsAvailable(600, ctx()) }, { true, "skill unknown" })
        eq({ Data.IsAvailable(600, ctx({ skills = { [171] = 10 } })) }, { false, "skill" })
        eq({ Data.IsAvailable(600, ctx({ skills = { [171] = 75 } })) }, { true, nil })
        eq({ Data.IsAvailable(601, ctx({ reputations = { [529] = 3000 } })) }, { false, "reputation too high" })
        eq({ Data.IsAvailable(424242, ctx()) }, { false, "unknown quest" })
    end)
end)

H.suite("Data index", function()
    test("quests by map: quest zone and where the starter stands", function()
        local Data = load()
        eq(Data.QuestsInZone(1429), nil, "nil before BuildIndex")
        local checkpoints = 0
        local index = Data.BuildIndex(function() checkpoints = checkpoints + 1 end)
        ok(index.questCount >= 20)
        local list = Data.QuestsInZone(1429)
        local byId = {}
        for _, e in ipairs(list) do byId[e.id] = e end
        eq(byId[7], { id = 7, inZone = true, giverInZone = true })
        eq(byId[176], { id = 176, inZone = true, giverInZone = true }, "object starter located")
        eq(Data.QuestsInZone(2501), { { id = 90001, inZone = true, giverInZone = true } })
        eq(Data.QuestsInZone(1436)[1].id, 166)
        eq(Data.QuestsInZone(9999), {})
    end)

    test("follow-ups from the reverse prerequisite index", function()
        local Data = load()
        Data.BuildIndex()
        eq(Data.GetFollowUps(7), { 15, 608 })
        eq(Data.GetFollowUps(155), { 166 })
        eq(Data.GetFollowUps(1), {})
    end)
end)
