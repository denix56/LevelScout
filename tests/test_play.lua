-- tests/test_play.lua: the play log (core/Play.lua): the XP a session earns, what the path
-- promises inside a window, forecasts settled on the active clock, the events that overrule the
-- plan; and the Engine's side of it on the real data (needs the real QuestieDB, like the other
-- game tests: see mocks.lua).
local H, M = ...
local test, eq, ok, contains = H.test, H.eq, H.ok, H.contains

local E = require("game_env")(H, M)
local slash, output, start = E.slash, E.output, E.start

-- The module alone, in a namespace of its own.
local function play()
    return H.loadAddon({ "core/Play.lua" }, {}).Play
end

-- A route of three steps in zone 1: an accept, a camp (600 XP over 200 s, done at 400 s), a
-- turn-in (1000 XP at 500 s).
local function route()
    return { zone = 1, order = { "P:1", "W:m1", "T:1" }, seconds = 500, steps = {
        { t = 100, seconds = 20, kind = "accept", xp = 0, cumXP = 0 },
        { t = 400, seconds = 200, kind = "work", xp = 600, cumXP = 600 },
        { t = 500, seconds = 10, kind = "turnin", xp = 1000, cumXP = 1600 } } }
end

H.suite("Play log", function()
    test("the XP a session earns, over a level-up reported either way round", function()
        local P = play()
        P.Start({})
        eq(P.XP(12, 3000, 7400), 0, "the first look is where counting starts")
        eq(P.XP(12, 3500, 7400), 500)
        eq(P.XP(13, 100, 8000), 500 + 3900 + 100, "a new level: the rest of the old one and the new XP")
        eq(P.Total(), 4500)
        eq(P.XP(nil, 5, 5), 4500, "no figures: nothing counted")
        -- the game reports the new XP before the new level
        P.Start({})
        P.XP(12, 7000, 7400)
        eq(P.XP(12, 50, 8000), 450, "XP that went down is a level-up")
        eq(P.XP(13, 60, 8000), 460, "the level following is not counted again")
        eq(P.XP(12, 70, 8000), 470, "nor a stale level after that")
        eq(P.XP(13, 80, 8000), 480)
    end)

    test("what the path promises inside a window", function()
        local P = play()
        local plan = route()
        eq({ P.Within(plan, nil, 450) }, { 600, 450 }, "the camp is done, the turn-in is not")
        eq({ P.Within(plan, nil, 300) }, { 300, 300 }, "half of the camp")
        eq({ P.Within(plan, nil, 1000) }, { 1600, 500 }, "the route ran out at 500 s")
        eq({ P.Within(plan, nil, 50) }, { 0, 50 }, "nothing reached yet")
        eq({ P.Within({ zone = 1, steps = {} }, nil, 900) }, { 0, 0 })
        -- with an itinerary: zone 1 is left after the camp, zone 2 is 100 s away and pays 500 XP 10 s in
        local onward = { zone = 2, steps = { { t = 50, seconds = 10, kind = "turnin", xp = 500, cumXP = 500 } } }
        local it = { segments = { { map = 1, leaveKey = "W:m1" }, { map = 2, travel = 100, plan = onward } } }
        eq({ P.Within(plan, it, 600) }, { 1100, 510 }, "the camp, the trip, the next zone's turn-in")
        eq({ P.Within(plan, it, 505) }, { 600, 505 }, "the next zone's turn-in comes at 510 s")
        eq({ P.Within(plan, it, 450) }, { 600, 450 }, "still on the way")
        -- an itinerary made for another zone is not this route's path
        eq({ P.Within(plan, { segments = { { map = 9 } } }, 1000) }, { 1600, 500 })
        -- the leave step is not in the route any more: the zone is followed to its end
        it.segments[1].leaveKey = "T:99"
        eq({ P.Within(plan, it, 700) }, { 2100, 610 })
    end)

    test("forecasts are written down, spaced out, and settled when their time has passed", function()
        local P = play()
        local store = P.Start({})
        eq(store.session, 1)
        P.XP(12, 1000, 9000)
        local plan = route()
        plan.steps[#plan.steps + 1] = { t = 4000, seconds = 10, kind = "turnin", xp = 400, cumXP = 2000 }
        local f = P.Forecast(0, { level = 12, zone = 1, plan = plan })
        eq({ f.s, f.a, f.lv, f.z, f.x }, { 1, 0, 12, 1, 0 })
        eq(f.p, { 1600, 1600, 1600 })
        eq(f.c, { 900, 1800, 3600 }, "the route goes on past every window")
        eq(P.Forecast(100, { level = 12, zone = 1, plan = plan }), nil, "not again so soon for the same zone")
        ok(P.Forecast(100, { level = 12, zone = 2, plan = { zone = 2, steps = plan.steps } }), "another zone: at once")
        ok(P.Forecast(100 + P.FORECAST_EVERY, { level = 12, zone = 2, plan = { zone = 2, steps = plan.steps } }))
        eq(P.Forecast(5000, { level = 12, zone = 3, plan = { zone = 3, steps = {} } }), nil, "no route: no forecast")
        eq(#store.forecasts, 3)
        -- play: 700 XP and one skipped quest before the first window ends
        P.XP(12, 1700, 9000)
        P.Event(200, "skip", { q = 5 })
        P.Event(210, "banner", { to = 7, gain = 0.3 })
        P.Tick(899)
        eq(f.g[1], nil)
        P.Tick(900)
        eq({ f.g[1], f.d[1] }, { 700, 1 }, "the XP earned since, and how often the plan was overruled (a banner is not)")
        eq(f.g[2], nil)
        P.XP(12, 2000, 9000)
        P.Tick(3600)
        eq(f.g, { 700, 1000, 1000 })
        eq(f.d, { 1, 1, 1 })
        -- a new session: yesterday's open forecasts stay as they are
        local later = store.forecasts[3]
        eq(later.g[3], nil)
        P.Start(store)
        eq(store.session, 2)
        P.XP(12, 2000, 9000)
        P.XP(12, 5000, 9000)
        P.Tick(100000)
        eq(later.g[3], nil, "the active clock started anew: not settled")
        -- a damaged log is emptied
        eq(#P.Start({ v = 0, forecasts = "x" }).forecasts, 0)
    end)

    test("events are kept, capped, and summed up", function()
        local P = play()
        local store = P.Start({})
        P.KEEP_EVENTS = 4
        local e = P.Event(10, "zone", { from = 1, to = 2, banner = true, note = { "not plain" } })
        eq({ e.s, e.a, e.k, e.from, e.to, e.banner, e.note }, { 1, 10, "zone", 1, 2, true, nil })
        P.Event(20, "zone", { from = 2, to = 1, back = true })
        P.Event(30, "order", { q = 3, i = 9 })
        P.Event(40, "extra", { q = 4 })
        P.Event(50, "moved", { from = 1, to = 2 }).snap = 7
        eq(#store.events, 4, "the oldest went")
        eq(store.events[1].a, 20)
        local sum = P.Summary()
        eq({ sum.events, sum.kinds.zone, sum.kinds.order, sum.kinds.extra, sum.kinds.moved, sum.zoneBanner, sum.zoneBack, sum.snapshots },
            { 4, 1, 1, 1, 1, 0, 1, 1 })
        local text = table.concat(P.Describe(), "\n")
        contains(text, "Play log: 0 forecasts, 4 events.")
        contains(text, "Nothing to compare yet")
        contains(text, "changed zone by hand once (1 back to a zone the path had left)")
        contains(text, "turned in 1 out of order")
        contains(text, "the path moved on once")
        P.Reset()
        eq(#store.events, 0)
    end)

    test("the summary compares what was promised with what came, apart when the plan was kept to", function()
        local P = play()
        local store = P.Start({})
        store.forecasts = {
            { s = 1, a = 0, z = 1, x = 0, p = { 1000, 2000, 4000 }, c = { 900, 1800, 3600 }, g = { 800, 1500 }, d = { 0, 1 }, n = 1 },
            { s = 1, a = 600, z = 1, x = 0, p = { 1000, 2000, 4000 }, c = { 900, 1800, 3600 }, g = { 600 }, d = { 2 }, n = 2 },
            { s = 1, a = 900, z = 1, x = 0, p = { 500, 500, 500 }, c = { 300, 300, 300 }, g = { 100 }, d = { 0 }, n = 0 },
        }
        local sum = P.Summary()
        local w = sum.windows[1]
        eq({ w.n, w.promised, w.got, w.short }, { 2, 2000, 1400, 1 }, "the one whose path ran out is left out")
        eq({ w.followed.n, w.followed.promised, w.followed.got }, { 1, 1000, 800 })
        eq({ sum.windows[2].n, sum.windows[2].followed.n }, { 1, 0 })
        eq(sum.windows[3].n, 0)
        local text = table.concat(P.Describe(), "\n")
        contains(text, "next 15 min: 1000 XP promised, 700 got (70%) over 2 forecasts; 80% when you kept to the plan (1)")
        contains(text, "next 30 min: 2000 XP promised, 1500 got (75%) over 1 forecast; never without a change of plan")
    end)
end)

H.suite("Play log in the Engine (real data)", function()
    test("a forecast is written with the itinerary, XP is counted, and /ls play says so", function()
        local ns = start()
        local view, log = ns.Engine.view, LevelScoutCharDB.play
        eq(log.session, 1)
        eq(#log.forecasts, 1, "one forecast after the first plan")
        local f = log.forecasts[1]
        eq({ f.z, f.lv, f.x }, { view.zone, 12, 0 })
        ok(f.p[3] > 0 and f.p[3] >= f.p[1], "more is promised in an hour than in a quarter")
        eq(f.p[3], math.floor(ns.Play.Within(view.plan, view.itinerary, 3600) + 0.5))
        M.set("UnitXP", function() return 3500 end)
        M.fire("PLAYER_XP_UPDATE", "player")
        eq(ns.Play.Total(), 500)
        M.fire("PLAYER_XP_UPDATE", "target")
        eq(ns.Play.Total(), 500, "someone else's XP is not ours")
        ns.Play.Tick(f.a + 900)
        eq(f.g[1], 500)
        M.printed = {}
        slash("play")
        contains(output(), "Play log: 1 forecast, ")
        slash("play reset")
        eq(#log.forecasts, 0)
    end)

    test("a zone chosen by hand is an event with a quiet snapshot, not more than one at a time", function()
        local ns = start(nil, { autoSnapshot = true })
        local view, db = ns.Engine.view, LevelScoutCharDB
        local first, other = view.zone, nil
        for _, z in ipairs(view.ranked) do
            if z.map > 0 and z.map ~= first and #z.plan.steps > 0 then other = z.map end
        end
        ok(other, "another zone to choose")
        eq(#db.snapshots, 0)
        M.printed = {}
        ns.Engine.SetZone(other)
        ok(M.settle())
        eq(view.zone, other)
        local e
        for _, ev in ipairs(db.play.events) do if ev.k == "zone" then e = ev end end
        ok(e, "the change is in the log")
        eq({ e.from, e.to, e.banner, e.back }, { first, other, nil, nil })
        eq(#db.snapshots, 1, "and a snapshot was taken for it")
        local s = db.snapshots[1]
        eq({ s.auto, s.id, e.snap }, { true, 1, 1 })
        contains(s.note, "by hand")
        eq(s.before.zone, first, "what was on screen before the change")
        ok(not output():find("Snapshot 1 saved", 1, true), "without a word in chat")
        -- back again at once: an event, but no second snapshot so soon
        ns.Engine.SetZone(first)
        ok(M.settle())
        eq(#db.snapshots, 1)
        local zones = 0
        for _, ev in ipairs(db.play.events) do if ev.k == "zone" then zones = zones + 1 end end
        eq(zones, 2)
        ns.Engine.SetZone(first)
        ok(M.settle())
        local again = 0
        for _, ev in ipairs(db.play.events) do if ev.k == "zone" then again = again + 1 end end
        eq(again, 2, "the zone already shown is no change")
        -- the ones asked for and the ones taken by themselves do not push each other out
        ns.Engine.SNAPSHOTS = 1
        slash("snapshot mine")
        ok(M.settle())
        slash("snapshot mine too")
        ok(M.settle())
        eq(#db.snapshots, 2)
        eq({ db.snapshots[1].auto, db.snapshots[2].auto, db.snapshots[2].note }, { true, nil, "mine too" })
    end)

    test("following the banner is not overruling the plan: no snapshot", function()
        local ns = start(nil, { autoSnapshot = true })
        local view, db = ns.Engine.view, LevelScoutCharDB
        local other
        for _, z in ipairs(view.ranked) do
            if z.map > 0 and z.map ~= view.zone and #z.plan.steps > 0 then other = z.map end
        end
        view.moveOn = { suggest = true, map = other }
        ns.Engine.SetZone(other)
        ok(M.settle())
        local e
        for _, ev in ipairs(db.play.events) do if ev.k == "zone" then e = ev end end
        eq({ e.to, e.banner }, { other, true })
        eq(#db.snapshots, 0)
    end)

    test("a skipped quest and a turn-in out of the route's order are events", function()
        local ns = start()
        local view, events = ns.Engine.view, LevelScoutCharDB.play.events
        local function last(kind)
            local found
            for _, ev in ipairs(events) do if ev.k == kind then found = ev end end
            return found
        end
        local function count(kind)
            local n = 0
            for _, ev in ipairs(events) do if ev.k == kind then n = n + 1 end end
            return n
        end
        -- a turn-in far down the route, and one the route does not have
        local far, at
        for i, key in ipairs(view.plan.order) do
            local id = key:match("^T:(%d+)$")
            if id and i > ns.Play.ORDER_FRONT then far, at = tonumber(id), i break end
        end
        ok(far, "a turn-in further down the route")
        M.fire("QUEST_TURNED_IN", far)
        eq({ last("order").q, last("order").i }, { far, at })
        M.fire("QUEST_TURNED_IN", 999999)
        eq(last("extra").q, 999999)
        ok(M.settle())
        -- skipping, once; bringing back
        ns.Engine.Ignore(424242, true)
        ns.Engine.Ignore(424242, true)
        eq(count("skip"), 1)
        eq(last("skip").q, 424242)
        ns.Engine.Ignore(424242, false)
        eq(count("unskip"), 1)
        ok(M.settle())
        eq(#LevelScoutCharDB.snapshots, 0, "the tests' game takes no snapshots by itself")
    end)
end)
