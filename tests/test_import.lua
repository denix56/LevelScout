-- tests/test_import.lua: the ForeverDB-only data import (tools/import/layer.lua), the record
-- helpers it shares with the runtime merge (LevelScout/adapters/Merge.lua), and the sandbox the
-- tools run third-party addon files in.
local H, M = ...
local test, eq, ok, near, contains = H.test, H.eq, H.ok, H.near, H.contains

local dir = H.root .. "/tools/import"
local Merge = assert(loadfile(H.root .. "/LevelScout/adapters/Merge.lua"))("LevelScout", {})
local Layer = assert(loadfile(dir .. "/layer.lua"))(dir)
local Sandbox = assert(loadfile(dir .. "/sandbox.lua"))(dir)
local Client = assert(loadfile(dir .. "/client.lua"))(dir)

H.suite("Import helpers", function()
    test("map spots round-trip and match ForeverDB's packing", function()
        eq({ Merge.DecodeSpot(Merge.Spot(1429, 49.3, 36.7)) }, { 1429, 49.3, 36.7 })
        eq(Merge.Spot(1429, 49.3, 36.7), "nn3053", "ForeverDB's token for Kobold Vermin")
        eq({ Merge.DecodeSpot(Merge.Spot(2991, 100, 0)) }, { 2991, 99.9, 0 }, "x=100 clamps, never spills into the map")
    end)

    test("band works above 32 bits", function()
        eq(Merge.band(4294967373, 1), 1)
        eq(Merge.band(4294967373, 2 ^ 32), 2 ^ 32)
        eq(Merge.band(8589934770, 2 ^ 32), 0)
    end)

    test("classic objective strings (CMaNGOS via ForeverDB)", function()
        eq(Merge.ParseClassicObjectives("c6:10"), { { k = "c", id = 6, count = 10, credit = {} } })
        eq(Merge.ParseClassicObjectives("c504:15;c95:15;i782:8"), {
            { k = "c", id = 504, count = 15, credit = {} },
            { k = "c", id = 95, count = 15, credit = {} },
            { k = "i", id = 782, count = 8, credit = {} } })
        eq(Merge.ParseClassicObjectives("c123:5:44,55;a178"), {
            { k = "c", id = 123, count = 5, credit = { 44, 55 } },
            { k = "e", id = 178, credit = {}, area = 178 } })
        eq(Merge.ParseClassicObjectives(""), {})
    end)

    test("captured objective strings (ForeverDB players)", function()
        eq(Merge.ParseCapturedObjectives("c:8,i:5,o:3"), { { k = "c", count = 8 }, { k = "i", count = 5 }, { k = "o", count = 3 } })
        eq(Merge.ParseCapturedObjectives(""), {})
    end)

    test("Base64 and CBOR decoding", function()
        eq(Client.DecodeBase64("S29ib2xk"), "Kobold")
        -- {1: "Kobold", "p": 5} as CBOR: a2 01 66 4b6f626f6c64 61 70 05
        local cbor = string.char(0xa2, 0x01, 0x66) .. "Kobold" .. string.char(0x61, 0x70, 0x05)
        eq(Client.DeserializeCBOR(cbor), { [1] = "Kobold", p = 5 })
        -- [1.5 (double), -3, null, true]
        local arr = string.char(0x84, 0xfb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0, 0x22, 0xf6, 0xf5)
        local t = Client.DeserializeCBOR(arr)
        eq({ t[1], t[2], t[3], t[4] }, { 1.5, -3, nil, true })
    end)

    test("XP estimates: median and quartiles by level and kind, borrowing from nearby levels", function()
        local function q(level, xp, flags, objectives)
            local f = {}
            for i = 1, 30 do f[i] = "" end
            f[2], f[3], f[10], f[11], f[15] = level, 1, flags or "", xp or "", objectives or ""
            return table.concat(f, "|")
        end
        local quests = {}
        for i, xp in ipairs({ 100, 200, 300, 400, 500, 600, 700 }) do quests[i] = q(10, xp, "", "c6:10:C") end
        quests[20] = q(10, "", "", "c6:10:C")           -- unknown XP: not a sample
        for i, xp in ipairs({ 50, 60, 70 }) do quests[30 + i] = q(10, xp) end        -- talk-to, level 10
        for i, xp in ipairs({ 80, 90 }) do quests[40 + i] = q(12, xp) end            -- talk-to, level 12
        quests[50] = q(20, 5000, "d", "c639:1:C")
        local e = Merge.XpEstimates(quests)
        eq(e.o[10], { 400, 300, 600 })
        eq(e.o[11], { 400, 300, 600 }, "level 11 borrows level 10")
        eq(e.o[16], nil, "nothing within 5 levels")
        eq(e.t[10], { 70, 60, 80 }, "3 samples are too few; widened to level 12")
        eq(e.d[20], nil, "one dungeon sample is not enough")
        eq(Merge.XpKind("dn", "c1:1:C"), "d")
        eq(Merge.XpKind("", ""), "t")
        eq(Merge.XpLevel(0, 7), 7)
        eq(Merge.XpLevel(63, 60), 60)
    end)

    test("the layer is ForeverDB only: what the merge reads, trimmed, and the world tables", function()
        local F = {
            qcQuests = { [7] = "Kobold Camp Cleanup|2|1|a|0|0||||n197|n197|c6:10||", [9] = "Gone|5|1||0|0||||||||" },
            qfQuests = { [90001] = "Riverglades Survey|24|20|Survey.|n300001|n300001|17|1|||" },
            qcNpc = { [6] = "Kobold Vermin|nn3053" }, qcObj = {}, qcItem = {}, qcGone = { [9] = true }, qcExcl = {},
            qfPoi = {}, qfSeen = {}, qfNpcSpots = {}, qfNpcNames = {}, qfItems = {}, qfArea = {}, qobj = {},
            qxp = { q = { [7] = 170 }, curve = { 100 }, dmul = 2 }, qdrop = {}, pace = { [0] = { c = 30 } },
            npcLv = {}, travelData = { nodes = {} }, zoneData = { [1429] = "0|a" },
            qgQuests = { [7] = "1|||||||||||||||3" },
            qcByMap = { [1429] = "7" }, qfByMap = { [2501] = "90001 7" },
            npcs = { [197] = { "Marshal McBride", "", 1429, 48.9, 41.6 }, [198] = { "Nowhere", "", 0, 0, 0 } },
            dungeons = {
                [36] = { kind = "dungeon", size = 5, n = "The Deadmines", lv = "17:26:10", ent = "nhbx7k", boss = "1:a|2:b", q = "166 185" },
                [409] = { kind = "raid", size = 40, n = "Molten Core", lv = "60:60:0", ent = "x" },
                [37] = { kind = "dungeon", size = 5, n = "No door", lv = "20:30:15", ent = "" },
            },
            routeMaps = { [1429] = { c = 0, t = 0, l = 0, h = 1, w = 1 } }, routeLinks = {},
        }
        local model, report = Layer.Build(F)
        local fdb = model.fdb
        eq(fdb.qcQuests[9], nil, "a quest players were never offered keeps only its id in qcGone")
        ok(fdb.qcQuests[7] and fdb.qcGone[9])
        eq(fdb.questXP[7], 170)
        eq(fdb.groupSize, { [7] = 3 }, "group size: field 16 of the quest guide")
        eq(fdb.startMap[7], 1429, "classic map first")
        eq(fdb.startMap[90001], 2501)
        eq(fdb.npcSpot, { [197] = Merge.Spot(1429, 48.9, 41.6) }, "an NPC's own spot, only on a real map")
        eq(fdb.dungeons, { [36] = { n = "The Deadmines", lo = 17, hi = 26, min = 10, ent = "nhbx7k", bosses = 2, q = "166 185" } },
            "5-player dungeons with an entrance")
        eq(model.world.xpCurve, { 100 })
        eq(model.world.xpDungeonMultiplier, 2)
        eq(model.world.enum, nil, "QuestieDB's enums come from QuestieDB at runtime")
        eq(model.world.dungeons, nil, "dungeon quests are matched at runtime")
        eq(report.counts["classic quests never offered in Forever"], 1)
        local okBuild, err = pcall(Layer.Build, { qcQuests = {} })
        ok(not okBuild and tostring(err):find("ForeverDB: table ns.qfQuests is missing", 1, true), tostring(err))
    end)

    test("the import reads no QuestieDB", function()
        for _, file in ipairs({ "import.lua", "layer.lua", "writer.lua" }) do
            local f = assert(io.open(dir .. "/" .. file, "rb"))
            local src = f:read("*a")
            f:close()
            ok(not src:find("questiedb.lua", 1, true) and not src:find("LibQuestieDB", 1, true), file)
        end
    end)

    test("the sandbox has no io, os or module loading", function()
        local env = Sandbox.NewEnv()
        for _, name in ipairs({ "io", "os", "require", "dofile", "loadfile", "package", "debug" }) do
            eq(env[name], nil, name)
        end
        local chunk = env.loadstring("return io")
        eq(chunk(), nil, "loadstring runs inside the sandbox")
        local okSet = pcall(env.setfenv, 1, {})
        ok(not okSet, "setfenv on stack levels is refused")
    end)

    test("TOC parsing: file list and metadata", function()
        local path = H.root .. "/LevelScout/LevelScout.toc"
        local files = Sandbox.TocFiles(path)
        eq(files[1], "Init.lua")
        ok(#files > 5)
        eq(Sandbox.TocMetadata(path).Interface, "16001")
    end)
end)
