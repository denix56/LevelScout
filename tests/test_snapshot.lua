-- tests/test_snapshot.lua: /ls snapshot and tests/replay.lua on the real data: what a snapshot
-- holds, that it is plain data the game can save, and that planning it again outside the game
-- gives what the game showed. Needs the real QuestieDB, like the other game tests (see mocks.lua).
local H, M = ...
local test, eq, ok, contains = H.test, H.eq, H.ok, H.contains

local E = require("game_env")(H, M)
local R = require("replay")
local slash, output, start = E.slash, E.output, E.start

-- /ls snapshot [note], let the planning finish, and the snapshot saved last.
local function take(note)
    slash("snapshot" .. (note and (" " .. note) or ""))
    ok(M.settle(), "planning finishes")
    local list = LevelScoutCharDB.snapshots
    return list[#list]
end

-- What the game would hand back after a logout: the saved variables written and read again.
local function throughFile(db)
    return R.LoadText(R.Write("LevelScoutCharDB", db), "LevelScoutCharDB")
end

-- The snapshot planned again in a namespace of its own (the mocks of the running test stay).
local function replay(snap, opts)
    local ns = R.Setup(snap, { questiedb = M.questieDB(snap.input.faction, snap.input.class), keepMocks = true })
    R.ApplySettings(ns, snap.settings)
    return R.Replay(ns, snap, opts), ns
end

local function noSharedTable(v, seen, path)
    if type(v) ~= "table" then return end
    if seen[v] then error("a table is held twice: " .. path, 0) end
    seen[v] = true
    for k, x in pairs(v) do noSharedTable(x, seen, path .. "." .. tostring(k)) end
end

H.suite("Snapshots and replay (real data)", function()
    test("no snapshot is taken unless asked for", function()
        local ns = start()
        ns.Engine.Replan(true)
        ok(M.settle())
        eq(LevelScoutCharDB.snapshots, {})
        eq(LevelScoutCharDB.snapshotCount, 0)
    end)

    test("a snapshot holds the planning input and what was shown", function()
        local ns = start()
        M.printed = {}
        local s = take("why this zone?")
        local view = ns.Engine.view
        eq(s.note, "why this zone?")
        eq(s.id, 1)
        eq(s.format, ns.Snapshot.FORMAT)
        eq(s.input.level, 12)
        eq(s.input.faction, "Alliance")
        eq(s.input.class, "WARRIOR")
        eq(s.input.raceId, 1)
        eq(s.input.map, 1429)
        H.near(s.input.x, 0.42, 0.01)
        eq(s.input.log[1].id, 7)
        eq(s.input.log[2].id, 33)
        eq(ns.Snapshot.DecodeIds(s.input.completed), { [783] = true, [5261] = true })
        eq(s.input.capacity, 40)
        eq(s.settings.Zones.HORIZON, ns.Zones.HORIZON)
        eq(s.shown.zone, view.zone)
        eq(#s.shown.ranked, #view.ranked)
        ok(s.shown.itinerary, "the next hours are in it")
        ok(s.before, "and what was on screen when it was asked for")
        contains(output(), "Snapshot 1 saved")
    end)

    test("a snapshot is plain data that survives a logout", function()
        local ns = start()
        local s = take()
        noSharedTable(s, {}, "snapshot")
        local db = LevelScoutCharDB
        local back = throughFile(db) -- (the writer errors on a function, a cycle or a number the game cannot save)
        ok(H.deepEq(back, db), "read back it is what was written")
        -- a log with thousands of quests done: ids are written as differences
        C_QuestLog.GetAllCompletedQuestIDs = function()
            local ids = {}
            for id = 3, 9000, 3 do ids[#ids + 1] = id end
            return ids
        end
        M.fire("PLAYER_ENTERING_WORLD")
        ok(M.settle())
        local big = take()
        ok(#big.input.completed < 4 * 3000, "under 4 bytes for each id")
        ok(#R.Write("LevelScoutCharDB", LevelScoutCharDB) < 60000, "a snapshot is about 50 KB at most")
        eq(ns.Snapshot.DecodeIds(big.input.completed)[9000], true)
    end)

    test("the writer refuses what the game cannot save", function()
        local ok1, err1 = pcall(R.Write, "X", { a = { b = print } })
        ok(not ok1)
        contains(err1, "X.a.b")
        local cycle = {}
        cycle.me = cycle
        local ok2, err2 = pcall(R.Write, "X", cycle)
        ok(not ok2)
        contains(err2, "contains itself")
        ok(not pcall(R.Write, "X", { n = 0 / 0 }))
        ok(not pcall(R.Write, "X", { n = math.huge }))
        ok(not pcall(R.Write, "X", { [true] = 1 }))
        ok(H.deepEq(R.LoadText(R.Write("X", { 1, 2.5, "a\nb", { x = false }, [10] = -3, k = 1e300 }), "X"),
            { 1, 2.5, "a\nb", { x = false }, [10] = -3, k = 1e300 }))
    end)

    test("the input turns back into a state without losing anything", function()
        local ns = start()
        local s = take()
        local state = ns.Snapshot.State(s.input)
        ok(H.deepEq(ns.Snapshot.Capture(state), s.input), "state and back")
        eq(state.tagOf(424242), nil, "a quest that is not in the log has no tag")
        eq(state.partyOn(7), nil, "solo")
        ok(state.completed ~= ns.Snapshot.State(s.input).completed, "a fresh state each time")
    end)

    test("a replay gives what the game showed", function()
        start()
        take()
        local s = throughFile(LevelScoutCharDB).snapshots[1] -- as read after a logout
        local result = replay(s)
        eq(R.Compare(s.shown, result.view, { names = s.names }), {})
        eq(result.view.made.kind, s.shown.made.kind)
    end)

    test("warm starts replay the same", function()
        local ns = start(nil, { search = true, rounds = 8 })
        ns.Zones.ITINERARY_ROUNDS = 0 -- (the settings are recorded: the replay does the same)
        take()
        local second = take()
        ok(next(second.warm), "the zones started from their last plans")
        local s = throughFile({ snapshots = { second } }).snapshots[1]
        local result = replay(s)
        eq(R.Compare(s.shown, result.view, { names = s.names }), {})
    end)

    test("snapshots are numbered and the oldest are dropped", function()
        local ns = start()
        ns.Engine.SNAPSHOTS = 2
        take()
        take()
        M.printed = {}
        take()
        local ids = {}
        for _, s in ipairs(LevelScoutCharDB.snapshots) do ids[#ids + 1] = s.id end
        eq(ids, { 2, 3 })
        eq(LevelScoutCharDB.snapshotCount, 3)
        contains(output(), "Snapshot 3 saved")
    end)

    test("a snapshot is refused while another is being taken and inside an instance", function()
        start()
        M.printed = {}
        slash("snapshot first")
        slash("snapshot second")
        contains(output(), "No snapshot: a snapshot is being taken already.")
        ok(M.settle())
        eq(#LevelScoutCharDB.snapshots, 1)
        eq(LevelScoutCharDB.snapshots[1].note, "first")

        start({ inInstance = true })
        M.printed = {}
        slash("snapshot")
        ok(M.settle())
        contains(output(), "Snapshot not taken: Paused inside an instance.")
        eq(#LevelScoutCharDB.snapshots, 0)
    end)

    test("the encodings round trip", function()
        local keep = rawget(_G, "LevelScout") -- (Init.lua sets it)
        local ns = H.loadAddon({ "Init.lua", "core/Memory.lua", "core/Snapshot.lua" }, {})
        _G.LevelScout = keep
        local S = ns.Snapshot
        local ids = { [55] = true, [12] = true, [16] = true, [15] = true, [99] = false }
        eq(S.EncodeIds(ids), "12,3,1,39")
        eq(S.DecodeIds(S.EncodeIds(ids)), { [12] = true, [15] = true, [16] = true, [55] = true })
        eq(S.EncodeIds({}), "")
        eq(S.DecodeIds(""), {})
        eq(S.SplitList(S.JoinList({ "P:1", "W:m2", "T:1", "W:p12:3" })), { "P:1", "W:m2", "T:1", "W:p12:3" })
        eq(S.JoinList(nil), nil)
        eq(S.SplitList(""), {})
        local drops = { ["738:299"] = { k = 25, d = 6 }, ["1:2"] = { k = 10.5, d = 0 } }
        eq(S.DecodeDrops(S.EncodeDrops(drops)), drops)
        eq(S.EncodeDrops({ bad = { k = 1, d = 1 } }), "")
        local cyc = { a = 1, s = "x", f = print, n = 0 / 0 }
        cyc.self = cyc
        eq(S.Copy(cyc), { a = 1, s = "x" }, "a copy keeps plain finite values only")
    end)

    test("a saved-variables file is read in an empty environment", function()
        local db = R.LoadText("LevelScoutCharDB = { a = 1, b = (os ~= nil) }", "LevelScoutCharDB")
        eq(db, { a = 1, b = false })
        local value, err = R.LoadText("print(1)", "X")
        eq(value, nil)
        ok(err, "it says why")
    end)
end)
