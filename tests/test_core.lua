-- tests/test_core.lua: the planner core (core/*.lua) on a small made-up world.
local H, M = ...
local test, eq, ok, near = H.test, H.eq, H.ok, H.near

-- Two zones side by side on continent 0 (1000 x 1000 yards each: 1 map unit = 10 yards),
-- and one on continent 1.
local function S(map, x, y)
    local n = map * 1e6 + math.floor(x * 10 + 0.5) * 1e3 + math.floor(y * 10 + 0.5)
    local digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    repeat local d = n % 36; out = digits:sub(d + 1, d + 1) .. out; n = (n - d) / 36 until n == 0
    return out
end

local function quest(t)
    return table.concat({ t.name or "Q", t.level or 8, t.min or 5, 0, t.side or "", 0, 0, t.zone or 1, 0, t.flags or "",
        t.xp or "", t.xp and "f" or "", t.starts or "", t.ends or "", t.objectives or "", t.preAll or "", t.preAny or "",
        t.exclusive or "", "", "", "", "", "", "", "", "", "", "", "", 0 }, "|")
end

local function camp(map, x, y, n)
    local out = {}
    for i = 0, (n or 6) - 1 do out[#out + 1] = S(map, x + (i % 3) * 0.5, y + math.floor(i / 3) * 0.5) end
    return table.concat(out, " ")
end

local function fixture()
    local curve = {}
    for i = 1, 60 do curve[i] = i * 100 end
    return {
        meta = { build = "1.60.1.70888", generated = "2026-11-13", sources = { QuestieDB = "x", ForeverDB = "y" } },
        quests = {
            [1] = quest({ name = "Boars", xp = 800, starts = "n100", ends = "n100", objectives = "c200:10:C" }),
            [2] = quest({ name = "Boar Hides", xp = 600, starts = "n101", ends = "n101", objectives = "i300:4:C" }),
            [3] = quest({ name = "After Boars", xp = 500, starts = "n100", ends = "n101", preAll = "1" }),
            [4] = quest({ name = "Statues", xp = 700, starts = "n100", ends = "n100", objectives = "o400:3:C" }),
            [5] = quest({ name = "Deep Dungeon", xp = 5000, flags = "d", starts = "n100", ends = "n100", objectives = "c201:1:C" }),
            [6] = quest({ name = "Big Ogre", xp = 900, starts = "n100", ends = "n100", objectives = "c202:1:C" }),
            [7] = quest({ name = "High Wolves", xp = 900, starts = "n100", ends = "n100", objectives = "c203:5:C" }),
            [8] = quest({ name = "Far Giver", xp = 900, starts = "n102", ends = "n100", objectives = "c200:5:C" }),
            [9] = quest({ name = "Too Soon", xp = 900, min = 12, level = 13, starts = "n100", ends = "n100" }),
            [10] = quest({ name = "Slow Crawl", xp = 60, starts = "n100", ends = "n100", objectives = "i301:10:C" }),
            [11] = quest({ name = "No Place", xp = 500, starts = "n100", ends = "n100", objectives = "c204:5:C" }),
            [12] = quest({ name = "Daily", xp = 500, flags = "py", starts = "n100", ends = "n100" }),
            [13] = quest({ name = "Other Game Mission", flags = "u", starts = "n100", ends = "n100", objectives = "c200:3:C" }),
            [14] = quest({ name = "Unseen But Traced", flags = "u", xp = 300, starts = "n100", ends = "n100" }),
            [15] = quest({ name = "Keep Secrets", xp = 1500, flags = "d", starts = "n101", ends = "n201", preAll = "16", objectives = "c201:1:C" }),
            [16] = quest({ name = "Lead Up", xp = 300, starts = "n100", ends = "n101" }),
            [20] = quest({ name = "Other Zone", zone = 2, xp = 700, starts = "n110", ends = "n110", objectives = "c210:6:C" }),
            [21] = quest({ name = "Other Zone 2", zone = 2, xp = 900, starts = "n110", ends = "n110", objectives = "c210:8:C" }),
        },
        questText = {}, questSpots = {},
        npcs = {
            [100] = "Marshal|10|10|0|2|A|" .. S(1, 50, 50),
            [101] = "Tanner|10|10|0|2|A|" .. S(1, 52, 50),
            [102] = "Far Giver|10|10|0|2|A|" .. S(2, 50, 50),
            [110] = "Captain|10|10|0|2|A|" .. S(2, 20, 50),
            [200] = "Boar|7|8|0|0||" .. camp(1, 60, 50) .. " " .. S(1, 5, 5),
            [201] = "Dungeon Boss|12|12|1|0||",
            [202] = "Ogre|9|9|1|0||" .. camp(1, 70, 70),
            [203] = "High Wolf|13|13|0|0||" .. camp(1, 30, 30),
            [204] = "Ghost|8|8|0|0||",
            [205] = "Snail|8|8|0|0||" .. camp(1, 90, 90, 2),
            [210] = "Bandit|8|8|0|0||" .. camp(2, 25, 50),
        },
        objects = { [400] = "Statue|" .. camp(1, 40, 60, 3) },
        items = { [300] = "Boar Hide|200:50:f||", [301] = "Snail Slime|205:2:f||" },
        variants = { Quest = {}, Npc = {}, Object = {}, Item = {} },
        world = {
            pace = { [1] = { c = 30, i = 20, o = 15, r = 7 } },
            xpCurve = curve,
            maps = { [1] = { c = 0, t = 0, l = 0, h = 1000, w = 1000 }, [2] = { c = 0, t = 0, l = -1000, h = 1000, w = 1000 },
                [3] = { c = 1, t = 0, l = 0, h = 1000, w = 1000 } },
            links = { { a = { 0, -500, -1900 }, b = { 1, -500, -100 }, side = "", both = true, wait = 100, ride = 50, name = "Boat" } },
            zones = { [1] = "0|A|s|5-10||0|5,0|||Hub~a~50~50~10~5~10|", [2] = "0|C|s|6-12||0|5,5|||Fort~b~20~50~10~6~12|",
                [3] = "1|H|s|6-12||0|0,5|||Camp~h~50~50~10~6~12|" },
            travel = { speeds = { fly = 30 }, nodes = { [1] = { 0, -500, -100, 1, 10, 50, "a", 0, "West" }, [2] = { 0, -500, -1900, 2, 90, 50, "a", 0, "East" } },
                flights = "1>2>1800>10 2>1>1800>10", measured = "1>2>40>3" },
            enum = {},
            dungeons = { [900] = { name = "Test Keep", lo = 7, hi = 12, min = 6, ent = S(1, 80, 20), bosses = 3, quests = "5,15", confirmed = "5" } },
        },
    }
end

local function load(overrides)
    M.install()
    local data = fixture()
    if overrides then overrides(data) end
    local ns = { data = data }
    H.loadAddon(H.runtimeFiles(), ns)
    ns.Data.Init({ faction = "Alliance", class = "WARRIOR", clientBuild = "1.60.1.70888" })
    ns.Data.BuildIndex()
    ns.Zones.Reset()
    return ns
end

local function state(extra)
    local s = { level = 8, faction = "Alliance", class = "WARRIOR", map = 1, x = 0.5, y = 0.5, log = {}, completed = {}, capacity = 20 }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end

local function keys(plan) return table.concat(plan.order, " ") end
local function indexOf(plan, key)
    for i, k in ipairs(plan.order) do if k == key then return i end end
end
local function listed(list)
    local out = {}
    for _, e in ipairs(list) do out[#out + 1] = e.id end
    return out
end

H.suite("Core numbers", function()
    test("map points become world yards; distance is nil across continents", function()
        local ns = load()
        ns.Geo.Init(ns.data.world)
        local a, b = ns.Geo.Loc(1, 50, 50), ns.Geo.Loc(1, 53, 54)
        near(ns.Geo.Dist(a, b), 50, 1e-6)
        near(ns.Geo.Dist(ns.Geo.Loc(1, 100, 50), ns.Geo.Loc(2, 0, 50)), 0, 1e-6, "the two zones touch")
        eq(ns.Geo.Dist(a, ns.Geo.Loc(3, 50, 50)), nil)
    end)

    test("clustering picks the dense camp, or a nearer one when told where we are", function()
        local ns = load()
        ns.Geo.Init(ns.data.world)
        local spots = {}
        for i = 1, 6 do spots[#spots + 1] = { map = 1, x = 60 + i * 0.2, y = 50 } end
        spots[#spots + 1] = { map = 1, x = 5, y = 5 }
        local loc, inCamp, total = ns.Geo.Cluster(spots)
        near(loc.mx, 60.7, 0.01)
        eq({ inCamp, total }, { 6, 7 })
        local far = {}
        for i = 1, 3 do far[#far + 1] = { map = 1, x = 10 + i * 0.2, y = 10 } end
        for i = 1, 4 do far[#far + 1] = { map = 1, x = 90 + i * 0.2, y = 90 } end
        near(ns.Geo.Cluster(far, ns.Geo.Loc(1, 12, 12)).mx, 10.4, 0.01, "3 mobs next to us beat 4 across the zone")
    end)

    test("quest XP share, mob XP and kill time by level difference", function()
        local C = load().Cost
        eq({ C.QuestXPFactor(10, 15), C.QuestXPFactor(10, 16), C.QuestXPFactor(10, 19), C.QuestXPFactor(10, 30) }, { 1, 0.8, 0.2, 0.1 })
        eq(C.MobXP(10, 10), 95)
        eq(C.MobXP(10, 12), 105, "two levels above: +10%")
        eq(C.MobXP(10, 4), 0, "grey")
        eq(C.MobXP(10, 10, true), 190, "rested doubles it")
        eq({ C.GroupXPFactor(1), C.GroupXPFactor(2) }, { 1, 0.5 })
        near(C.GroupXPFactor(5), 0.28, 1e-9)
        eq({ C.MobXP(10, 10, false, 2), C.MobXP(10, 10, false, 3), C.MobXP(10, 10, true, 5) }, { 48, 37, 53 },
            "a group shares the kill: half each for two; a bonus from three members")
        eq({ C.KillSeconds(30, -3), C.KillSeconds(30, 0), C.KillSeconds(30, 2) }, { 22.5, 30, 43.5 })
    end)

    test("kills planned for drops: the 70th percentile, not the mean", function()
        local C = load().Cost
        eq(C.KillsForItems(10, 1), 10)
        eq(C.KillsForItems(8, 0.5), 19, "mean 16, plus about half a standard deviation")
        ok(C.KillsForItems(5, 0.001) <= 5 / 0.01 * 1.3, "rates are floored at 1%")
    end)

    test("pace falls back to the nearest level band, then to defaults", function()
        local ns = load()
        local p = ns.Cost.Pace(ns.data.world, 40)
        eq({ p.c, p.i, p.o, p.r }, { 30, 20, 15, 7 })
        eq(p.e, 120, "no band has event time: default")
    end)

    test("travel: walking, a known flight path when faster, a boat across continents", function()
        local ns = load()
        ns.Geo.Init(ns.data.world)
        local a, b = ns.Geo.Loc(1, 10, 50), ns.Geo.Loc(2, 90, 50)
        local walkOnly = ns.Travel.New(ns.data.world, { speed = 7 })
        near(walkOnly:Seconds(a, b), 1800 * 1.25 / 7, 0.01)
        local flyer = ns.Travel.New(ns.data.world, { speed = 7, knownNodes = { [1] = true, [2] = true } })
        local secs, mode = flyer:Seconds(a, b)
        eq(mode, "fly")
        near(secs, 20 + 40, 0.01, "measured flight time plus the flight-master overhead")
        local t, how = walkOnly:Seconds(b, ns.Geo.Loc(3, 10, 50))
        eq(how, "boat")
        near(t, 150, 0.01, "both ends are at the docks")
        local alliance = ns.Travel.New({ links = { { a = { 0, 0, 0 }, b = { 1, 0, 0 }, side = "H" } } }, { side = "a" })
        eq({ alliance:Seconds(ns.Geo.WorldLoc(0, 0, 0), ns.Geo.WorldLoc(1, 0, 0)) }, { ns.Travel.NO_ROUTE, "unknown" })
    end)

    test("travel: a flight can start at a flight master of our side that is not known yet, never end at one", function()
        local ns = load()
        ns.Geo.Init(ns.data.world)
        local a, b = ns.Geo.Loc(1, 10, 50), ns.Geo.Loc(2, 90, 50) -- at West, at East
        local walk = 1800 * 1.25 / 7
        -- knowing only East: walk to West, unlock it, fly on
        local t = ns.Travel.New(ns.data.world, { speed = 7, side = "a", knownNodes = { [2] = true } })
        local secs, mode = t:Seconds(a, b)
        eq(mode, "fly")
        near(secs, 20 + 40, 0.01)
        local route = t:Route(a, b)
        near(route.seconds, secs, 0.01, "the same choice")
        local fly = route.legs[2]
        eq({ fly.kind, fly.from.name, fly.from.unlock, fly.to.name, fly.to.unlock }, { "fly", "West", true, "East", nil })
        eq(route.legs[1].to.unlock, true, "the walk goes to the new flight master")
        if ns.Format then
            eq(ns.Format.TripTitle({ first = fly }), "New flight master: West, fly to East")
            eq(ns.Format.TripText({ rides = { fly }, seconds = 60 }):match("^[^|]+"), "unlock West and fly to East  ")
        end
        -- the other way: no flight to a point that is not known
        local back, how = t:Seconds(b, a)
        eq(how, "walk")
        near(back, walk, 0.01)
        -- known points are told as before
        local both = ns.Travel.New(ns.data.world, { speed = 7, side = "a", knownNodes = { [1] = true, [2] = true } })
        eq(both:Route(a, b).legs[2].from.unlock, nil)
        -- not the other side's flight masters, not without a side, not with no point known, not switched off
        local function mode_(opts) return select(2, ns.Travel.New(ns.data.world, opts):Seconds(a, b)) end
        eq(mode_({ speed = 7, side = "h", knownNodes = { [2] = true } }), "walk")
        eq(mode_({ speed = 7, knownNodes = { [2] = true } }), "walk")
        eq(mode_({ speed = 7, side = "a", knownNodes = {} }), "walk")
        ns.Travel.UNLOCK = false
        eq(mode_({ speed = 7, side = "a", knownNodes = { [2] = true } }), "walk")
        ns.Travel.UNLOCK = true
    end)

    test("travel: a long walk takes the walk table's way round when that is longer than the straight line", function()
        -- two hubs 1,800 yards apart in a straight line, 6,000 yards apart on foot
        local A64 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
        local function d2(n) return A64:sub(math.floor(n / 64) + 1, math.floor(n / 64) + 1) .. A64:sub(n % 64 + 1, n % 64 + 1) end
        local function pair(a, b, yards) return d2(a) .. d2(b) .. d2(yards / 2) .. "00" end
        local ns = load(function(data)
            data.world.travel.hubs = "f1~0~-500~-100~a;f2~0~-500~-1900~a;q9:1~1~0~0~a"
            data.world.travel.walk = pair(0, 1, 6000)
        end)
        ns.Geo.Init(ns.data.world)
        local a, b = ns.Geo.Loc(1, 10, 50), ns.Geo.Loc(2, 90, 50)
        local walker = ns.Travel.New(ns.data.world, { speed = 7 })
        near(walker:WalkYards(a, b), 6000, 0.01, "both ends are at the hubs")
        near(walker:Seconds(a, b), 6000 / 7, 0.01)
        near(walker:WalkYards(b, a), 6000, 0.01, "either way")
        -- 200 yards short of each hub: the walk can be that much shorter at each end
        local c, d = ns.Geo.Loc(1, 30, 50), ns.Geo.Loc(2, 70, 50)
        near(walker:WalkYards(c, d), 6000 - 400 * 1.25, 0.01)
        -- a short walk is not looked up, and a walk the table makes no longer stays the straight line
        near(walker:WalkYards(a, ns.Geo.Loc(1, 60, 50)), 500 * 1.25, 0.01)
        near(walker:WalkYards(a, ns.Geo.Loc(1, 10, 100)), 500 * 1.25, 0.01)
        near(walker:WalkYards(ns.Geo.Loc(1, 100, 100), ns.Geo.Loc(1, 100, 0)), 1000 * 1.25, 0.01, "far from both hubs: nothing to add")
        eq(walker:WalkYards(a, ns.Geo.Loc(3, 10, 50)), nil, "another continent")
        -- the route's legs still add up, and the flight is worth more now
        local flyer = ns.Travel.New(ns.data.world, { speed = 7, knownNodes = { [1] = true, [2] = true } })
        local route = flyer:Route(c, d)
        eq(route.mode, "fly")
        local sum = 0
        for _, leg in ipairs(route.legs) do sum = sum + leg.seconds end
        near(sum, route.seconds, 0.01)
        -- switched off: the straight line again
        ns.Travel.HUB_WALK = false
        near(ns.Travel.New(ns.data.world, { speed = 7 }):WalkYards(a, b), 1800 * 1.25, 0.01)
        ns.Travel.HUB_WALK = true
        -- data without a walk table, or with a broken one: the straight line
        local bare = ns.Travel.New({ maps = ns.data.world.maps, travel = { hubs = "x;y", walk = "!!!!!!!!" } }, { speed = 7 })
        near(bare:WalkYards(a, b), 1800 * 1.25, 0.01)
    end)

    test("travel: the route behind the seconds, leg by leg, with the same choice and the same total", function()
        local ns = load()
        ns.Geo.Init(ns.data.world)
        local L = ns.Geo.Loc
        local walkOnly = ns.Travel.New(ns.data.world, { speed = 7 })
        local flyer = ns.Travel.New(ns.data.world, { speed = 7, knownNodes = { [1] = true, [2] = true } })
        local function kinds(route)
            local out = {}
            for _, leg in ipairs(route.legs) do out[#out + 1] = leg.kind end
            return table.concat(out, " ")
        end
        -- every pair of these points, with and without flight paths: legs add up to Seconds
        local points = { L(1, 10, 50), L(1, 20, 50), L(1, 50, 50), L(1, 90, 90), L(2, 80, 50), L(2, 90, 50), L(2, 20, 20),
            L(3, 10, 50), L(3, 50, 50) }
        for _, t in ipairs({ walkOnly, flyer }) do
            for _, a in ipairs(points) do
                for _, b in ipairs(points) do
                    local seconds, mode = t:Seconds(a, b)
                    local route = t:Route(a, b)
                    local sum = 0
                    for _, leg in ipairs(route.legs) do sum = sum + leg.seconds end
                    near(route.seconds, seconds, 1e-9)
                    near(sum, seconds, 1e-6)
                    eq(route.mode, mode)
                    eq(route.legs[1].from.loc, a)
                    eq(route.legs[#route.legs].to.loc, b)
                    for i = 2, #route.legs do ok(route.legs[i].from == route.legs[i - 1].to, "each leg starts where the one before ends") end
                end
            end
        end
        eq(kinds(walkOnly:Route(L(1, 20, 50), L(2, 80, 50))), "walk")
        -- a flight: walk to the flight master, fly, walk on
        local route = flyer:Route(L(1, 20, 50), L(2, 80, 50))
        eq(kinds(route), "walk fly walk")
        local walk, fly, last = route.legs[1], route.legs[2], route.legs[3]
        near(walk.seconds, 100 * 1.25 / 7, 1e-6)
        eq({ walk.to.name, walk.to.node, walk.to.loc.map, walk.to.loc.mx, walk.to.loc.my }, { "West", 1, 1, 10, 50 })
        eq({ fly.from.name, fly.to.name, fly.to.node }, { "West", "East", 2 })
        near(fly.seconds, 20 + 40, 1e-6, "the overhead at the flight master and the measured flight")
        eq({ last.from.name, last.to.name }, { "East" })
        -- standing at the flight master: the walk is there, and takes no time
        eq(flyer:Route(L(1, 10, 50), L(2, 90, 50)).legs[1].seconds, 0)
        -- a short hop is walked even with flight paths
        eq(kinds(flyer:Route(L(1, 20, 50), L(1, 50, 50))), "walk")
        -- a boat: its two ends, with a flight on the way to the harbour when that is faster
        local boat = walkOnly:Route(L(2, 90, 50), L(3, 10, 50))
        eq(kinds(boat), "walk boat walk")
        eq({ boat.legs[2].name, boat.legs[2].seconds }, { "Boat", 150 })
        eq(kinds(flyer:Route(L(1, 20, 50), L(3, 50, 50))), "walk fly walk boat walk")
        eq(kinds(flyer:Route(L(3, 50, 50), L(1, 20, 50))), "walk boat walk fly walk")
        -- "Zeppelin between Here and There": the kind and the ends are read from the name
        local named = ns.Travel.New({ links = { { a = { 0, 0, 0 }, b = { 1, 0, 0 }, name = "Zeppelin between Here and There", wait = 10, ride = 20 } } }, {})
        local ride = named:Route(ns.Geo.WorldLoc(1, 0, 0), ns.Geo.WorldLoc(0, 0, 0)).legs[2]
        eq({ ride.kind, ride.transport, ride.from.name, ride.to.name, ride.seconds }, { "boat", "Zeppelin", "There", "Here", 30 })
        -- no known way: the fixed cost and no legs
        local alliance = ns.Travel.New({ links = { { a = { 0, 0, 0 }, b = { 1, 0, 0 }, side = "H" } } }, { side = "a" })
        local none = alliance:Route(ns.Geo.WorldLoc(0, 0, 0), ns.Geo.WorldLoc(1, 0, 0))
        eq({ none.seconds, none.mode, #none.legs }, { ns.Travel.NO_ROUTE, "unknown", 0 })
        -- a harbour has world coordinates only: its map point, for the waypoint
        local dock = ns.Geo.OnMap(ns.Geo.WorldLoc(0, -500, -1900))
        eq({ dock.map, dock.mx, dock.my }, { 2, 90, 50 })
        eq(ns.Geo.OnMap(ns.Geo.WorldLoc(7, 0, 0)), nil)
        local same = L(1, 10, 50)
        ok(ns.Geo.OnMap(same) == same)
    end)

    test("the way to the current step in words: zone, flight or boat, legs", function()
        local F = load().Format
        local SEP = "  |cff5f646e\194\183|r  "
        local west, east = { name = "Lakeshire", zone = "Redridge Mountains" }, { name = "Darkshire", zone = "Duskwood" }
        local fly = { kind = "fly", from = west, to = east, seconds = 130 }
        local trip = { seconds = 250, zone = "Duskwood", rides = { fly }, first = fly,
            legs = { { kind = "walk", from = {}, to = west, seconds = 70 }, fly, { kind = "walk", from = east, to = {}, seconds = 50 } } }
        eq(F.TripText(trip), "In Duskwood" .. SEP .. "fly Lakeshire to Darkshire" .. SEP .. "4 min")
        eq(F.TripTitle(trip), "Flight master: Lakeshire, fly to Darkshire")
        eq(F.TripLegs(trip), { { text = "Walk to the flight master in Lakeshire (Redridge Mountains)", seconds = 70 },
            { text = "Fly Lakeshire to Darkshire", seconds = 130 }, { text = "Walk to the step", seconds = 50 } })
        -- another zone on foot: only the zone. The zone we are in, on foot: nothing at all.
        eq(F.TripText({ seconds = 300, zone = "Duskwood", rides = {}, legs = { { kind = "walk", from = {}, to = {}, seconds = 300 } } }), "In Duskwood")
        eq(F.TripText({ seconds = 40, rides = {}, legs = { { kind = "walk", from = {}, to = {}, seconds = 40 } } }), nil)
        eq({ F.TripText(nil), F.TripTitle(nil), F.TripLegs(nil), F.TripTitle({ rides = {} }), F.TripLegs({ rides = {}, legs = {} }) }, {})
        -- a flight inside the zone we are in: no zone; standing at the flight master: no walk to it
        local here = { seconds = 150, rides = { fly }, first = fly, legs = { { kind = "walk", from = {}, to = west, seconds = 0 }, fly,
            { kind = "walk", from = east, to = {}, seconds = 20 } } }
        eq(F.TripText(here), "fly Lakeshire to Darkshire" .. SEP .. "3 min")
        eq(#F.TripLegs(here), 2)
        -- a boat, then a flight
        local a, b = { name = "Menethil Harbor", zone = "Wetlands" }, { name = "Theramore Isle" }
        local boat = { kind = "boat", transport = "Boat", name = "Boat between Menethil Harbor and Theramore Isle", from = a, to = b, seconds = 238 }
        local far = { seconds = 600, zone = "Dustwallow Marsh", rides = { boat, fly }, first = boat,
            legs = { { kind = "walk", from = {}, to = a, seconds = 100 }, boat, { kind = "walk", from = b, to = west, seconds = 60 }, fly,
                { kind = "walk", from = east, to = {}, seconds = 72 } } }
        eq(F.TripText(far), "In Dustwallow Marsh" .. SEP .. "boat Menethil Harbor to Theramore Isle" .. SEP
            .. "then fly Lakeshire to Darkshire" .. SEP .. "10 min")
        eq(F.TripTitle(far), "Boat: Menethil Harbor, ride to Theramore Isle")
        eq(F.TripLegs(far)[1].text, "Walk to the boat in Menethil Harbor (Wetlands)")
        eq(F.TripLegs(far)[2].text, "Boat Menethil Harbor to Theramore Isle")
        eq(F.TripLegs(far)[3].text, "Walk to the flight master in Lakeshire (Redridge Mountains)")
        -- a transport whose name does not give its ends
        local lift = { kind = "boat", name = "Freewind Post lift", from = {}, to = {}, seconds = 30 }
        local up = { seconds = 90, rides = { lift }, first = lift, legs = { { kind = "walk", from = {}, to = {}, seconds = 30 }, lift,
            { kind = "walk", from = {}, to = {}, seconds = 30 } } }
        eq(F.TripText(up), "take the Freewind Post lift" .. SEP .. "2 min")
        eq(F.TripTitle(up), "Freewind Post lift")
        eq({ F.TripLegs(up)[1].text, F.TripLegs(up)[2].text }, { "Walk to the Freewind Post lift", "Freewind Post lift" })
    end)
end)

H.suite("Planner", function()
    test("order rules: accept, then work, then turn in; follow-ups after their prerequisite", function()
        local ns = load()
        local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state()))
        ok(indexOf(plan, "P:1") < indexOf(plan, "W:m200"))
        ok(indexOf(plan, "W:m200") < indexOf(plan, "T:1"))
        ok(indexOf(plan, "T:1") < indexOf(plan, "P:3"), "After Boars is accepted after Boars is turned in")
        ok(indexOf(plan, "P:3") < indexOf(plan, "T:3"))
        ok(indexOf(plan, "P:4") < indexOf(plan, "W:o400") and indexOf(plan, "W:o400") < indexOf(plan, "T:4"))
    end)

    test("everything a place offers is accepted on the first visit", function()
        local ns = load()
        local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state()))
        -- the Marshal (50,50) offers Boars, Statues and Unseen But Traced right away; After Boars
        -- (same NPC) only after Boars is turned in
        local first, last = math.huge, 0
        for _, key in ipairs({ "P:1", "P:4", "P:14" }) do
            local i = indexOf(plan, key)
            first, last = math.min(first, i), math.max(last, i)
        end
        for i = first, last do ok(plan.order[i]:find("^P:"), "one unbroken run of accepts") end
        for i = 1, first - 1 do ok(not plan.order[i]:find("^[WT]:"), "nothing is worked or turned in before them") end
        ok(indexOf(plan, "P:3") > indexOf(plan, "T:1"), "the follow-up still waits for its prerequisite")
        -- every accept at a place we have already stood at would have been taken then
        local seen = {}
        for i, s in ipairs(plan.steps) do
            local spot = string.format("%d:%.0f:%.0f", s.loc.map, s.loc.mx, s.loc.my)
            if s.kind == "accept" and seen[spot] and plan.order[i] ~= "P:3" then
                ok(plan.steps[i - 1].kind ~= "work", "no return to " .. spot .. " just to accept " .. plan.order[i])
            end
            seen[spot] = true
        end
    end)

    test("a quest that starts where another quest sends us, in the next zone, is considered too", function()
        local function world(withErrand)
            return load(function(data)
                -- Found There belongs to zone 2 and starts at a note lying in the bandit camp
                data.quests[24] = quest({ name = "Found There", zone = 2, xp = 900, starts = "o401", ends = "n100" })
                data.objects[401] = "Bandit Orders|" .. S(2, 26, 50)
                -- Far Note also starts in zone 2, but nowhere near anything we do there
                data.quests[25] = quest({ name = "Far Note", zone = 2, xp = 900, starts = "o402", ends = "n100" })
                data.objects[402] = "Old Note|" .. S(2, 90, 90)
                if withErrand then
                    -- a zone 1 quest that sends us to the bandit camp in zone 2
                    data.quests[23] = quest({ name = "Cross Border", xp = 900, starts = "n100", ends = "n100", objectives = "c210:6:C" })
                end
            end)
        end
        local ns = world(true)
        local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state()))
        ok(indexOf(plan, "W:m210"), "we go to the bandit camp")
        ok(indexOf(plan, "P:24"), "the quest lying in that camp is picked up")
        ok(indexOf(plan, "P:24") < indexOf(plan, "T:24"))
        eq(indexOf(plan, "P:25"), nil, "a quest elsewhere in that zone is not")
        local skipped = ns.Zones.PlanZone(1, ns.Zones.Context(state({ ignored = { [24] = true } })))
        eq(indexOf(skipped, "P:24"), nil, "unless we skipped it")
        local without = world(false)
        eq(indexOf(without.Zones.PlanZone(1, without.Zones.Context(state())), "P:24"), nil, "nothing sends us there: not our zone's quest")
    end)

    test("a quest's objectives are done in the same camp when their targets share one", function()
        local ns = load(function(data)
            for id in pairs(data.quests) do data.quests[id] = nil end
            -- Footpads: 7 in the north camp, 4 in the south camp. Thieves: 6 in each.
            -- The south camp is the one nearer the quest giver.
            data.npcs[220] = "Footpad|8|8|0|0||" .. camp(1, 70, 10, 7) .. " " .. camp(1, 48, 40, 4)
            data.npcs[221] = "Thief|8|8|0|0||" .. camp(1, 70.5, 10.5, 6) .. " " .. camp(1, 48.5, 40.5, 6)
            data.quests[40] = quest({ name = "Assassins", xp = 900, starts = "n100", ends = "n100", objectives = "c220:12:C;c221:8:C" })
        end)
        local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state()))
        local footpads, thieves = plan.steps[indexOf(plan, "W:m220")], plan.steps[indexOf(plan, "W:m221")]
        near(footpads.loc.my, 10.3, 0.5, "footpads at the bigger camp")
        near(thieves.loc.my, 10.8, 0.5, "thieves in that same camp, not the equal one nearer the giver")
        ok(ns.Geo.Dist(footpads.loc, thieves.loc) < 60)
        eq(math.abs(indexOf(plan, "W:m220") - indexOf(plan, "W:m221")), 1, "done back to back")
    end)

    test("quests sharing a camp share one stop; kills count once for both", function()
        -- (without Far Giver, whose kills are at the same camp when its trip pays)
        local ns = load(function(data) data.quests[8] = nil end)
        local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state()))
        local stop
        for _, s in ipairs(plan.steps) do if s.kind == "work" and s.target == "Boar" or s.from == "Boar" then stop = s end end
        ok(stop, "one boar stop")
        eq(#stop.quests, 2)
        -- 10 kills for Boars; 4 hides at 50% plan for 10 kills: the camp costs 10 kills, not 20
        eq(stop.kills, 10)
        -- six boars in the camp: the last four kills wait for respawns (300 s / 6 = 50 s each)
        near(stop.seconds, 6 * 30 + 4 * 50, 0.01)
        ok(indexOf(plan, "P:1") < indexOf(plan, "W:m200") and indexOf(plan, "P:2") < indexOf(plan, "W:m200"), "both accepted first")
        local n = 0
        for _, k in ipairs(plan.order) do if k:find("^W:m200") then n = n + 1 end end
        eq(n, 1)
    end)

    test("what is left out and why", function()
        local ns = load()
        local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state({ routeElite = false })))
        local order = keys(plan)
        ok(not order:find("P:5", 1, true), "dungeon quests are never planned")
        for _, list in pairs(plan.lists) do
            for _, e in ipairs(list) do ok(e.id ~= 5, "dungeon quests are in no list") end
        end
        eq(listed(plan.lists.group), { 6 }, "elite target")
        local function withLog(done)
            return ns.Zones.PlanZone(1, ns.Zones.Context(state({ routeElite = false,
                log = { { id = 5, isComplete = done, objectives = { { have = done and 1 or 0, need = 1, finished = done } } } } })))
        end
        eq(indexOf(withLog(false), "T:5"), nil, "a dungeon quest in the log with work left stays out")
        ok(indexOf(withLog(true), "T:5"), "a finished dungeon quest: its turn-in is planned")
        eq(listed(plan.lists.later), { 7, 9 }, "mobs 5 levels up; level requirement")
        eq(plan.lists.later[1].needLevel, 10, "High Wolves at level 10 (mob 13, cutoff 4)")
        eq(plan.lists.later[2].needLevel, 12)
        eq(plan.lists.elsewhere, nil, "no separate list for quests whose giver is in another zone")
        local slow = {}
        for _, id in ipairs(listed(plan.lists.skipped)) do slow[id] = true end
        ok(slow[10], "about 560 kills in a two-mob camp for 60 XP")
        for id in pairs(slow) do ok(id == 10 or id == 8, "only the slow camp, and the far giver when its trip does not pay: " .. id) end
        eq(listed(plan.lists.unlocated), { 11 })
        ok(not order:find("P:12", 1, true), "repeatables are not planned")
        eq(listed(plan.lists.unconfirmed), { 13 }, "no player data shows it exists in Forever")
        ok(not order:find("P:13", 1, true))
        ok(order:find("P:14", 1, true), "unseen by ForeverDB but Questie players were paid for it: planned")
        local log = { { id = 13, isComplete = false, objectives = { { have = 0, need = 3, finished = false } } } }
        local withLog = ns.Zones.PlanZone(1, ns.Zones.Context(state({ log = log })))
        ok(indexOf(withLog, "T:13"), "once it is in the log it is real: planned")
    end)

    test("a quest in the log: no accept step, remaining count and reward from the game", function()
        local ns = load()
        local log = { { id = 1, isComplete = false, rewardXP = 1234, objectives = { { have = 7, need = 10, finished = false } } } }
        local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state({ log = log })))
        eq(indexOf(plan, "P:1"), nil)
        local work, turnin
        for _, s in ipairs(plan.steps) do
            for _, q in ipairs(s.quests) do
                if q.id == 1 and s.kind == "work" then work = s end
                if q.id == 1 and s.kind == "turnin" then turnin = s end
            end
        end
        local part
        for _, p in ipairs(work.parts) do if p.quest == 1 then part = p end end
        eq({ part.need, part.have, part.total }, { 3, 7, 10 })
        eq(turnin.xp, 1234)
    end)

    test("a red quest waits for later, even in the log; once complete it is turned in", function()
        local ns = load(function(data)
            data.quests[30] = quest({ name = "Preserving Knowledge", level = 14, min = 6, xp = 9000, starts = "n100", ends = "n100",
                objectives = "c206:5:C" })
            data.npcs[206] = "Librarian|9|9|0|0||" .. camp(1, 15, 85)
        end)
        local function plan(extra) return ns.Zones.PlanZone(1, ns.Zones.Context(state(extra))) end
        -- level 8, quest level 14: six levels above, red
        local fresh = plan()
        eq(indexOf(fresh, "P:30"), nil)
        local entry
        for _, e in ipairs(fresh.lists.later) do if e.id == 30 then entry = e end end
        ok(entry, "listed under Later")
        eq(entry.needLevel, 10, "yellow-orange again at level 10")
        local inLog = plan({ log = { { id = 30, level = 14, isComplete = false, objectives = { { have = 0, need = 5, finished = false } } } } })
        eq(indexOf(inLog, "T:30"), nil, "in the log but red: not worked on")
        local done = plan({ log = { { id = 30, level = 14, isComplete = true, objectives = {} } } })
        ok(indexOf(done, "T:30"), "complete: turn it in")
        ok(indexOf(plan({ level = 10 }), "P:30"), "four levels above is orange: planned")
    end)

    test("a red quest comes along when its work is in a camp another quest visits anyway", function()
        local function world(objectives, extra)
            return load(function(data)
                data.quests[31] = quest({ name = "Red But Same Mobs", level = 14, min = 6, xp = 4000, starts = "n100", ends = "n100",
                    objectives = objectives })
                if extra then extra(data) end
            end)
        end
        -- level 8; quest level 14 is red. Its boars are the ones the orange-or-lower Boars quest kills
        local ns = world("c200:6:C")
        local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state()))
        ok(indexOf(plan, "P:31") and indexOf(plan, "T:31"), "same mobs: taken along")
        local later = {}
        for _, e in ipairs(plan.lists.later) do later[e.id] = true end
        ok(not later[31])
        local stop = plan.steps[indexOf(plan, "W:m200")]
        local ids = {}
        for _, q in ipairs(stop.quests) do ids[q.id] = true end
        ok(ids[1] and ids[31], "one boar stop for both")
        -- different mobs, but standing in the same camp
        local same = world("c207:4:C", function(data) data.npcs[207] = "Boar Matriarch|9|9|0|0||" .. S(1, 60.2, 50.4) end)
        ok(indexOf(same.Zones.PlanZone(1, same.Zones.Context(state())), "P:31"), "same spot: taken along")
        -- half of it is with our mobs, the other half elsewhere: it still comes along
        local half = world("c200:6:C;c208:4:C", function(data) data.npcs[208] = "Hermit Boar|9|9|0|0||" .. camp(1, 10, 90) end)
        ok(indexOf(half.Zones.PlanZone(1, half.Zones.Context(state())), "P:31"))
        -- most of it is elsewhere: it waits
        local far = world("c200:6:C;c208:4:C;c209:4:C", function(data)
            data.npcs[208] = "Hermit Boar|9|9|0|0||" .. camp(1, 10, 90)
            data.npcs[209] = "Lost Boar|9|9|0|0||" .. camp(1, 90, 10)
        end)
        eq(indexOf(far.Zones.PlanZone(1, far.Zones.Context(state())), "P:31"), nil)
        -- an item that drops from several kinds of mob is taken from the kind we already kill
        local drops = world("i310:3:C", function(data)
            data.npcs[211] = "Tusker|8|8|0|0||" .. camp(1, 20, 20, 12)      -- a bigger camp, but nobody sends us there
            data.items[310] = "Old Tome|211:50:f 200:50:f||"
        end)
        local tomes = drops.Zones.PlanZone(1, drops.Zones.Context(state()))
        ok(indexOf(tomes, "P:31"), "its tomes drop from our boars: taken along")
        eq(indexOf(tomes, "W:m211"), nil, "not from the other mob that also drops them")
        -- its own mobs are too strong: it waits whatever else is there
        local strong = world("c200:6:C;c203:2:C")
        eq(indexOf(strong.Zones.PlanZone(1, strong.Zones.Context(state())), "P:31"), nil)
    end)

    test("a finished quest in the log is only turned in; a finished objective is not worked", function()
        local ns = load()
        local log = { { id = 1, isComplete = true, objectives = { { have = 10, need = 10, finished = true } } } }
        local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state({ log = log, ignored = { [2] = true, [8] = true } })))
        ok(indexOf(plan, "T:1"))
        eq(indexOf(plan, "W:m200"), nil, "no boar stop: Boars is done and Boar Hides is ignored")
        eq(listed(plan.lists.ignored), { 2, 8 })
    end)

    test("completed prerequisites open follow-ups directly; completed quests are gone", function()
        local ns = load()
        local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state({ completed = { [1] = true } })))
        eq(indexOf(plan, "P:1"), nil)
        ok(indexOf(plan, "P:3"))
    end)

    test("the same input gives the same plan, and a seed keeps the shown order", function()
        -- (without Far Giver: its trip to another zone is a close call that a changed log can tip)
        local ns = load(function(data) data.quests[8] = nil end)
        local a = ns.Zones.PlanZone(1, ns.Zones.Context(state()))
        local b = ns.Zones.PlanZone(1, ns.Zones.Context(state()))
        eq(keys(a), keys(b))
        -- after accepting Boars somewhere else in the order, the kept plan is the old one minus P:1
        local log = { { id = 1, isComplete = false, objectives = { { have = 0, need = 10, finished = false } } } }
        local kept = ns.Zones.PlanZone(1, ns.Zones.Context(state({ log = log })), a.order)
        local expected = {}
        for _, k in ipairs(a.order) do if k ~= "P:1" then expected[#expected + 1] = k end end
        eq(keys(kept), table.concat(expected, " "))
    end)

    test("times add up: each step's clock is travel plus work after the one before", function()
        local ns = load()
        local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state()))
        local t, xp = 0, 0
        for _, s in ipairs(plan.steps) do
            t, xp = t + s.travel + s.seconds, xp + s.xp
            near(s.t, t, 1e-6)
            eq(s.cumXP, xp)
        end
        near(plan.seconds, t, 1e-6)
        ok(plan.rate > 0 and plan.score > 0 and plan.score <= plan.rate + 1e-6)
        ok(plan.peak >= 1 and plan.peak <= #plan.steps)
    end)

    test("in a group, XP from kills is shared and quest XP is not", function()
        local ns = load()
        local function boars(groupSize)
            local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state({ groupSize = groupSize })))
            local kill, quest
            for i, s in ipairs(plan.steps) do
                if plan.order[i] == "W:m200" then kill = s.xp end
                if plan.order[i] == "T:1" then quest = s.xp end
            end
            return kill, quest, plan.xp
        end
        near(ns.Cost.GroupKillFactor(1), 1, 1e-9)
        near(ns.Cost.GroupKillFactor(2), 0.65, 1e-9)
        near(ns.Cost.GroupKillFactor(5), 0.44, 1e-9)
        local soloKill, soloQuest, soloTotal = boars(nil)
        local duoKill, duoQuest, duoTotal = boars(2)
        ok(soloKill > 0)
        near(duoKill, soloKill / 2, 10, "ten boars, half the XP each")
        eq(duoQuest, soloQuest)
        ok(duoTotal < soloTotal)
    end)

    test("in a group, kills are faster and quest drops are split between the members", function()
        local ns = load(function(data)
            -- only the two boar quests, in a camp big enough that respawns do not matter
            for id in pairs(data.quests) do if id ~= 1 and id ~= 2 then data.quests[id] = nil end end
            data.npcs[200] = "Boar|7|8|0|0||" .. camp(1, 60, 50, 60)
        end)
        local function boarStop(groupSize, ignored)
            local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state({ groupSize = groupSize, ignored = ignored })))
            for i, s in ipairs(plan.steps) do if plan.order[i] == "W:m200" then return s end end
        end
        -- Boars alone: 10 kills count for everyone, so only the pace changes
        local solo, duo = boarStop(nil, { [2] = true }), boarStop(2, { [2] = true })
        eq({ solo.kills, duo.kills }, { 10, 10 }, "kill credit is shared")
        near(duo.seconds, solo.seconds * 0.65, 0.01)
        -- Boar Hides alone: 4 hides at 50% is 10 kills solo; two members need 8 hides
        local soloHides, duoHides = boarStop(nil, { [1] = true }), boarStop(2, { [1] = true })
        eq(soloHides.kills, 10)
        eq(duoHides.kills, ns.Cost.KillsForItems(8, 0.5))
        ok(duoHides.kills > soloHides.kills)
    end)

    test("elite quests are routed as group steps, with no time charged for finding the group", function()
        local ns = load()
        local function ogre(extra)
            local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state(extra)))
            for i, s in ipairs(plan.steps) do if plan.order[i] == "W:m202" then return s, plan end end
            return nil, plan
        end
        local solo, plan = ogre()
        ok(solo, "Big Ogre is in the route")
        eq(#plan.lists.group, 0)
        ok(solo.group)
        -- one level-9 elite for a level-8 player in an assumed group of three:
        -- 30 s x 1.2 (one level up) x 2.5 (elite) x (0.3 + 0.7 / 3)
        near(solo.seconds, 30 * 1.2 * 2.5 * (0.3 + 0.7 / 3), 0.01)
        eq(solo.xp, ns.Cost.MobXP(8, 9, false, 3, true))
        local grouped = ogre({ groupSize = 5 })
        near(grouped.seconds, 30 * 1.2 * 2.5 * (0.3 + 0.7 / 5), 0.01)
        local off, offPlan = ogre({ routeElite = false })
        eq(off, nil)
        eq(listed(offPlan.lists.group), { 6 })
    end)

    test("a skipped quest stays out, but once it is complete in the log its turn-in is planned", function()
        local ns = load()
        local function plan(log)
            return ns.Zones.PlanZone(1, ns.Zones.Context(state({ ignored = { [1] = true }, log = log })))
        end
        local fresh = plan({})
        eq(indexOf(fresh, "P:1"), nil)
        eq(listed(fresh.lists.ignored), { 1 })
        local started = plan({ { id = 1, isComplete = false, objectives = { { have = 4, need = 10, finished = false } } } })
        eq(indexOf(started, "T:1"), nil, "in the log but not done: still skipped")
        eq(indexOf(started, "W:m200") ~= nil, indexOf(started, "P:2") ~= nil, "boars are only killed for the other quest")
        local done = plan({ { id = 1, isComplete = true, objectives = { { have = 10, need = 10, finished = true } } } })
        ok(indexOf(done, "T:1"), "done anyway: turn it in")
        eq(listed(done.lists.ignored), {})
    end)

    test("drops are split between the members who are on the quest", function()
        local ns = load(function(data)
            for id in pairs(data.quests) do if id ~= 2 then data.quests[id] = nil end end
            data.npcs[200] = "Boar|7|8|0|0||" .. camp(1, 60, 50, 60)
        end)
        local log = { { id = 2, isComplete = false, objectives = { { have = 0, need = 4, finished = false } } } }
        local function kills(on)
            local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state({ groupSize = 3, log = log, partyOn = on })))
            for i, s in ipairs(plan.steps) do if plan.order[i] == "W:m200" then return s.kills end end
        end
        eq(kills(nil), ns.Cost.KillsForItems(12, 0.5), "unknown: all three are assumed to need hides")
        eq(kills(function() return 1 end), ns.Cost.KillsForItems(8, 0.5), "one other member is on it")
        eq(kills(function() return 0 end), ns.Cost.KillsForItems(4, 0.5), "nobody else is on it: all drops are ours")
    end)

    test("log space: a plan that needs more slots than are free says so", function()
        local ns = load()
        ok(not ns.Zones.PlanZone(1, ns.Zones.Context(state())).logFull)
        ok(ns.Zones.PlanZone(1, ns.Zones.Context(state({ capacity = 1 }))).logFull)
    end)
end)

H.suite("XP bonuses", function()
    test("XP buffs raise quest and kill XP alike, but not the game's own reward figure", function()
        local ns = load()
        local function xp(extra)
            local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state(extra)))
            local out = {}
            for i, s in ipairs(plan.steps) do out[plan.order[i]] = s.xp end
            return out
        end
        local base, buffed = xp(), xp({ xpBonus = 0.10 })
        eq(base["T:1"], 800)
        eq(buffed["T:1"], 880, "quest XP +10%")
        near(buffed["W:m200"], base["W:m200"] * 1.1, 6, "kill XP +10%")
        local log = { { id = 1, isComplete = true, rewardXP = 1234, objectives = {} } }
        eq(xp({ xpBonus = 0.10, log = log })["T:1"], 1234, "the game's figure already includes buffs")
    end)

    test("rested XP doubles kills in route order until the pool is used up", function()
        local ns = load()
        local function kills(pool)
            local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state({ restedPool = pool })))
            local out, total, rested = {}, 0, 0
            for i, s in ipairs(plan.steps) do
                if s.kind == "work" then total, rested = total + s.xp, rested + (s.restedXP or 0) end
                out[plan.order[i]] = s
            end
            return out, total, rested, plan
        end
        local none, baseTotal, r0, basePlan = kills(0)
        eq(r0, 0)
        -- a pool of 600 is 300 of bonus: it is all spent, on the first kills of the route
        local some, total, rested, plan = kills(600)
        eq(rested, 300)
        eq(total, baseTotal + 300)
        local firstKill
        for i, s in ipairs(plan.steps) do if s.kind == "work" and s.xp > 0 then firstKill = s; break end end
        ok(firstKill.restedXP and firstKill.restedXP > 0, "the first kills get the bonus")
        eq(some["T:1"].xp, none["T:1"].xp, "quest rewards do not use rested XP")
        -- a huge pool doubles every kill, and never more
        local _, all = kills(10000000)
        eq(all, baseTotal * 2)
        ok(plan.rate >= basePlan.rate)
    end)
end)

H.suite("Dungeons", function()
    test("a dungeon is planned like a zone: lead-up quests, every dungeon quest accepted, one run, turn-ins", function()
        local ns = load()
        eq(ns.Zones.Name(-900), "Test Keep")
        local plan = ns.Zones.PlanZone(-900, ns.Zones.Context(state()))
        eq({ plan.zone, plan.dungeon }, { -900, "Test Keep" })
        -- Keep Secrets needs Lead Up, which is not a dungeon quest: it is done first
        ok(indexOf(plan, "P:16") < indexOf(plan, "T:16"))
        ok(indexOf(plan, "T:16") < indexOf(plan, "P:15"), "the dungeon quest is accepted after its prerequisite")
        ok(indexOf(plan, "P:15") < indexOf(plan, "W:D900") and indexOf(plan, "P:5") < indexOf(plan, "W:D900"), "both accepted before the run")
        ok(indexOf(plan, "W:D900") < indexOf(plan, "T:15") and indexOf(plan, "W:D900") < indexOf(plan, "T:5"))
        local runs = 0
        for _, k in ipairs(plan.order) do if k:find("^W:D900") then runs = runs + 1 end end
        eq(runs, 1, "one run for all its quests")
        for _, k in ipairs(plan.order) do ok(not k:find("^[PT]:1$"), "zone quests are not part of a dungeon plan") end
        local run = plan.steps[indexOf(plan, "W:D900")]
        eq({ run.action, run.group, #run.quests }, { "run", true, 2 })
        local seconds, kills = ns.Cost.DungeonRun(3)
        eq({ seconds, kills }, { 900 + 3 * 360, 20 + 3 * 12 })
        near(run.seconds, seconds, 0.01)
        eq(run.xp, kills * ns.Cost.MobXP(8, 9, false, 5, true), "elite kills at the dungeon's middle level, shared by five")
        eq(ns.Format.StepTitle(run), "Run Test Keep")
        ok(ns.Format.StepDetail(run):find("2 quests inside", 1, true))
        -- the turn-in NPC is inside (no world location): turned in at the door
        local turnin = plan.steps[indexOf(plan, "T:15")]
        near(turnin.loc.mx, 80, 0.01)
        ok(turnin.target:find("in Test Keep", 1, true))
        ok(plan.xp >= 5000 + 1500 + 300 + run.xp)
    end)

    test("a finished dungeon quest that is not on the dungeon's list is turned in with the dungeon's plan", function()
        local ns = load(function(data)
            data.quests[40] = quest({ name = "Follow-up From Inside", xp = 900, flags = "d", starts = "n100", ends = "n101" })
        end)
        local function plan(done)
            return ns.Zones.PlanZone(-900, ns.Zones.Context(state({ log = { { id = 40, isComplete = done, objectives = {} } } })))
        end
        eq(indexOf(plan(false), "T:40"), nil, "not finished: not this dungeon's quest, left out")
        ok(indexOf(plan(true), "T:40"), "finished: turned in")
    end)

    test("a dungeon waits for the level its quests ask for", function()
        local function from(min, extra)
            local ns = load(function(data)
                data.quests[15] = quest({ name = "Keep Secrets", xp = 1500, min = min, flags = "d", starts = "n101", ends = "n201",
                    preAll = "16", objectives = "c201:1:C" })
            end)
            local ctx = ns.Zones.Context(state(extra))
            local listed = false
            for _, z in ipairs(ns.Zones.DungeonShortlist(ctx)) do listed = listed or z.map == -900 end
            return ns.Zones.DungeonFrom(ns.Zones.Dungeon(-900), ctx), listed
        end
        eq({ from(10, { level = 9 }) }, { 10, false }, "a quest asks for level 10: no run at 9")
        eq({ from(10, { level = 10 }) }, { 10, true })
        eq({ from(10, { level = 9, completed = { [15] = true } }) }, { 8, true }, "that quest is done: nothing to wait for")
        eq({ from(13, { level = 9 }) }, { 8, true }, "asks for more than the dungeon's top level: not waited for")
        local _, inLog = from(10, { level = 9, log = { { id = 5, isComplete = false, objectives = {} } } })
        ok(inLog, "a dungeon quest in the log: offered whatever the level")
    end)

    test("a quest whose giver is in another zone is planned like any other: the trip is weighed", function()
        local function where(ns, quest_, extra)
            local p = ns.Zones.PlanZone(1, ns.Zones.Context(state(extra)))
            for _, k in ipairs(p.order) do if k == "P:" .. quest_ then return "route" end end
            for name, list in pairs(p.lists) do
                for _, e in ipairs(list) do if e.id == quest_ then return name end end
            end
            return "nowhere"
        end
        -- worth the trip (Far Giver: 900 XP, giver on map 2): its accept step is in the route
        local ns = load()
        eq(where(ns, 8), "route")
        -- worth almost nothing: left out as slow, from afar and at the giver alike, never lost
        ns = load(function(data)
            data.quests[41] = quest({ name = "Errand", xp = 1, starts = "n102", ends = "n100" })
        end)
        eq(where(ns, 41), "skipped", "from afar")
        eq(where(ns, 41, { map = 2, x = 0.50, y = 0.50 }), "skipped", "standing at the giver")
        eq(where(ns, 41, { ignored = { [41] = true } }), "ignored", "skipped by the player")
    end)

    test("the zone a spot is in: its own map when that is a zone, else the zone under it", function()
        local ns = load(function(data)
            -- a continent map over zones 1 and 2 (spots can be recorded on it)
            data.world.maps[99] = { c = 0, t = 0, l = 0, h = 1000, w = 2000 }
        end)
        ns.Geo.Init(ns.data.world)
        eq(ns.Zones.ZoneAt(ns.Geo.Loc(1, 10, 50)), 1)
        eq(ns.Zones.ZoneAt(ns.Geo.Loc(99, 25, 50)), 1, "the west half of the continent map is zone 1")
        eq(ns.Zones.ZoneAt(ns.Geo.Loc(99, 75, 50)), 2)
        eq(ns.Zones.ZoneAt(ns.Geo.WorldLoc(0, 99999, 99999)), nil, "outside every zone")
        -- zone maps are rectangles and can overlap: a zone named in `prefer` wins over the smallest
        local ns2 = load(function(data)
            data.world.maps[99] = { c = 0, t = 0, l = 0, h = 1000, w = 2000 }
            data.world.maps[2] = { c = 0, t = 0, l = -500, h = 500, w = 500 } -- small, inside zone 1's rectangle
        end)
        ns2.Geo.Init(ns2.data.world)
        local spot = ns2.Geo.Loc(99, 35, 25) -- inside both
        eq(ns2.Zones.ZoneAt(spot), 2, "the smallest")
        eq(ns2.Zones.ZoneAt(spot, { 1 }), 1, "the zone being planned")
        eq(ns2.Zones.ZoneAt(spot, { 3, 1 }), 1, "the first preferred zone that contains it")
        eq(ns.Zones.ZoneAt(nil), nil)
    end)

    test("flight points to unlock: an unknown one close to the route is a stop where the detour is smallest", function()
        local ns = load()
        local function stops(extra, skip)
            local ctx = ns.Zones.Context(state(extra))
            return ns.Zones.FlightStops(ns.Zones.PlanZone(1, ctx), ctx, skip)
        end
        -- standing at the West flight master (map 1, 10,50), knowing only East: West comes first
        local at = { x = 0.10, y = 0.50, knownNodes = { [2] = true } }
        local list = stops(at)
        eq(#list, 1)
        eq({ list[1].id, list[1].name, list[1].at, list[1].loc.map }, { 1, "West", 1, 1 })
        near(list[1].detour, ns.Travel.FLIGHT_OVERHEAD, 0.01, "no walk at all: only the talk")
        eq(#stops(at, { [1] = true }), 0, "the player left it out")
        eq(#stops({ x = 0.10, y = 0.50, knownNodes = { [1] = true, [2] = true } }), 0, "known already")
        eq(#stops({ x = 0.10, y = 0.50 }), 0, "no flight point known at all: the flight map has not been read")
        eq(#stops({ x = 0.10, y = 0.50, knownNodes = {} }), 0)
        -- East is on another map. The route goes there for Far Giver (quest 8, accepted on map 2),
        -- so East is on the way...
        local east = stops({ knownNodes = { [1] = true } })
        eq({ #east, east[1].id }, { 1, 2 })
        -- ...and without that quest it is far from this zone's route: not worth the detour
        local home = { knownNodes = { [1] = true }, ignored = { [8] = true } }
        eq(#stops(home), 0)
        -- ...unless any detour is fine: then it is placed where it costs least
        local saved = ns.Zones.FLIGHT_DETOUR
        ns.Zones.FLIGHT_DETOUR = math.huge
        local far = stops(home)
        ns.Zones.FLIGHT_DETOUR = saved
        eq({ #far, far[1].id }, { 1, 2 })
        ok(far[1].at >= 1 and far[1].detour > 180)
    end)

    test("dungeons are shortlisted by level and ranked with the zones", function()
        local ns = load()
        local function has(extra)
            for _, z in ipairs(ns.Zones.Rank(ns.Zones.Context(state(extra)))) do
                if z.map == -900 then return z end
            end
        end
        local z = has()
        ok(z and z.dungeon and #z.plan.steps > 0)
        eq(has({ level = 4 }), nil, "below the dungeon's minimum level")
        eq(has({ level = 7 }), nil, "suggested 7-12: offered from a quarter of the way in, level 8")
        local picked = false
        for _, z in ipairs(ns.Zones.Rank(ns.Zones.Context(state({ level = 7 })), -900)) do picked = picked or z.map == -900 end
        ok(picked, "chosen by hand: still planned")
        eq(has({ completed = { [5] = true, [15] = true } }), nil, "nothing left to do there")
        local log = { { id = 5, isComplete = true, objectives = {} } }
        local done = ns.Zones.PlanZone(-900, ns.Zones.Context(state({ log = log, completed = { [15] = true } })))
        eq(indexOf(done, "W:D900"), nil, "its only quest is complete: no run, just the turn-in")
        ok(indexOf(done, "T:5"))
        -- and the zone itself still never plans dungeon quests
        local zone = ns.Zones.PlanZone(1, ns.Zones.Context(state()))
        eq(indexOf(zone, "P:5"), nil)
        eq(indexOf(zone, "W:D900"), nil)
    end)
end)

H.suite("Zones", function()
    test("shortlist: right side and level, current zone always", function()
        local ns = load()
        local ctx = ns.Zones.Context(state())
        local maps = {}
        for _, z in ipairs(ns.Zones.Shortlist(ctx)) do maps[#maps + 1] = z.map end
        eq(maps, { 1, 2 }, "zone 3 is Horde-only")
        local low = ns.Zones.Context(state({ level = 3, map = 2 }))
        local forced = ns.Zones.Shortlist(low)
        eq(forced[1] and forced[1].map, nil, "nothing to do at level 3: no zone listed")
    end)

    test("shortlist: a zone is offered from one level before its suggested range, not sooner", function()
        local ns = load()
        local function listed2(extra, always)
            for _, z in ipairs(ns.Zones.Shortlist(ns.Zones.Context(state(extra)), always)) do
                if z.map == 2 then return true end
            end
            return false
        end
        eq(listed2({ level = 6 }), true, "zone 2 is 6-12: offered at 6")
        eq(listed2({ level = 5 }), true, "one level below its range (Zones.EARLY): offered")
        eq(listed2({ level = 4 }), false, "two levels below: not offered")
        ns.Zones.EARLY = 0
        eq(listed2({ level = 5 }), false, "Zones.EARLY = 0: only from the bottom of its range")
        eq(listed2({ level = 5 }, 2), true, "chosen by hand: still planned")
        eq(listed2({ level = 5, map = 2 }), true, "standing in it: still planned")
    end)

    test("ranking counts the trip: the zone we stand in wins over an equal one far away", function()
        local ns = load()
        local function zone2(from)
            for _, z in ipairs(ns.Zones.Rank(ns.Zones.Context(state(from)))) do
                if z.map == 2 then return z.plan end
            end
        end
        local there, away = zone2({ map = 2, x = 0.2, y = 0.5 }), zone2({ map = 1, x = 0.1, y = 0.5 })
        ok(away.steps[1].travel > 100, "the first leg is the walk to the zone")
        eq({ there.overhead, away.overhead }, { 0, ns.Planner.SWITCH_OVERHEAD })
        ok(away.seconds > there.seconds + 200, "the trip and the switch are on the clock")
        ok(away.score <= there.score, "the same zone is never worth more from far away")
        local ranked = ns.Zones.Rank(ns.Zones.Context(state()))
        ok(ranked[1].plan.score >= ranked[2].plan.score, "best first")
    end)

    test("move-on: suggested above 20%, kept until the lead is under 5%", function()
        local Z = load().Zones
        local function plan(score, zone) return { score = score, zone = zone, steps = { {} } } end
        local ranked = { { map = 2, plan = plan(1150, 2) }, { map = 1, plan = plan(1000, 1) } }
        local active = plan(1000, 1)
        local first = Z.MoveOn(active, ranked, nil)
        eq(first.suggest, false, "15% is not enough to start suggesting")
        ranked[1].plan.score = 1300
        local on = Z.MoveOn(active, ranked, first)
        eq({ on.suggest, on.map }, { true, 2 })
        near(on.gain, 0.3, 1e-9)
        ranked[1].plan.score = 1100
        eq(Z.MoveOn(active, ranked, on).suggest, true, "10% keeps an existing suggestion")
        ranked[1].plan.score = 1040
        eq(Z.MoveOn(active, ranked, on).suggest, false)
        eq(Z.MoveOn(plan(0, 1), ranked, nil).suggest, true, "nothing left here")
        -- little left here: both choices are valued over the same hour, so the answer is calm
        local function short(xp, seconds) return { xp = xp, seconds = seconds, rate = xp / seconds * 3600, score = xp, zone = 1, steps = { {} } } end
        ranked[1].plan.score = 1300
        local good = Z.MoveOn(short(350, 900), ranked, nil)     -- 15 minutes at 1,400/h, then move
        eq(good.suggest, false, "finish what is left before moving")
        near(good.gain, 1300 / (350 + 1300 * 0.75) - 1, 1e-9)
        local poor = Z.MoveOn(short(150, 900), ranked, nil)     -- 15 minutes at 600/h: leaving gains about 15%
        eq(poor.suggest, false, "a short poor remainder alone does not trigger it")
        ok(poor.gain > 0.1 and poor.gain < 0.2)
        -- one more kill changes the remainder a little, and the answer a little
        local a, b = Z.MoveOn(short(150, 900), ranked, nil).gain, Z.MoveOn(short(150, 870), ranked, nil).gain
        ok(math.abs(a - b) < 0.02, "no jumps from small progress")
        -- a long stretch of poor quests does trigger it
        eq(Z.MoveOn({ xp = 3000, seconds = 7200, rate = 1000, score = 1000, zone = 1, steps = { {} } }, ranked, nil).suggest, true)
    end)

    test("move-on with an itinerary: its first zone, valued against starting here", function()
        local Z = load().Zones
        local function plan(score, zone) return { score = score, zone = zone, steps = { {} } } end
        local ranked = { { map = 2, plan = plan(3000, 2) }, { map = 3, plan = plan(2000, 3) }, { map = 1, plan = plan(1000, 1) } }
        local active = plan(1000, 1)
        local function itinerary(xp, here, first, shown)
            return { horizon = 7200, xp = xp, here = here, shown = shown or 1, segments = { { map = first or 3 }, { map = 2 } } }
        end
        -- the old rule would name zone 2 (three times the score); the itinerary starts in zone 3
        local first = Z.MoveOn(active, ranked, nil, itinerary(1150, 1000))
        eq({ first.suggest, first.map }, { false, 3 }, "15% is not enough to start suggesting")
        local on = Z.MoveOn(active, ranked, first, itinerary(1300, 1000))
        eq({ on.suggest, on.map, on.horizon }, { true, 3, 7200 })
        near(on.gain, 0.3, 1e-9)
        eq(Z.MoveOn(active, ranked, on, itinerary(1100, 1000)).suggest, true, "10% keeps an existing suggestion")
        eq(Z.MoveOn(active, ranked, on, itinerary(1040, 1000)).suggest, false)
        local other = Z.MoveOn(active, ranked, on, itinerary(1100, 1000, 2))
        eq({ other.suggest, other.map }, { false, 2 }, "another first zone has to earn its 20% again")
        -- the itinerary starts in the shown zone: stay, whatever the other zones score
        eq(Z.MoveOn(active, ranked, nil, itinerary(1300, 1300, 1)), { suggest = false })
        -- nothing can be started here
        local done = Z.MoveOn(active, ranked, nil, itinerary(1300, nil))
        eq({ done.suggest, done.map, done.gain }, { true, 3, nil })
        -- an itinerary made while another zone was shown, or nothing left here: the one-hour rule
        local old = Z.MoveOn(active, ranked, nil, itinerary(1300, 1000, 3, 2))
        eq({ old.suggest, old.map, old.horizon }, { true, 2, nil })
        near(old.gain, 2, 1e-9)
        local empty = Z.MoveOn({ score = 0, zone = 1, steps = {} }, ranked, nil, itinerary(1300, 1300, 1))
        eq({ empty.suggest, empty.map }, { true, 2 }, "nothing left here")
    end)

    test("walking around inside our zone does not change how other zones are judged", function()
        local ns = load()
        local function other(x, y, map)
            for _, z in ipairs(ns.Zones.Rank(ns.Zones.Context(state({ map = map or 1, x = x, y = y })), 1)) do
                if z.map == 2 then return z.plan end
            end
        end
        local west, east = other(0.05, 0.5), other(0.98, 0.5)
        near(east.seconds, west.seconds, 1e-6, "next to the border or far from it: the same trip, from the hub")
        eq(east.score, west.score)
        -- from the hub at (50, 50) to the first giver of zone 2 at (20, 50) of the next map: 700 yards
        near(west.steps[1].travel, 700 * 1.25 / 7, 0.01)
        -- our own zone is always planned from where we really stand
        local function own(x)
            for _, z in ipairs(ns.Zones.Rank(ns.Zones.Context(state({ x = x, y = 0.5 })), 1)) do
                if z.map == 1 then return z.plan end
            end
        end
        ok(own(0.05).steps[1].travel > own(0.5).steps[1].travel + 60)
        -- once we have left our zone, the real position counts again
        local outside = other(0.2, 0.5, 2)
        ok(outside.steps[1].travel < 5, "standing at zone 2's giver")
    end)

    test("what leaving now gains or loses against staying", function()
        local Z = load().Zones
        local here = { xp = 6000, seconds = 7200, rate = 3000, score = 3000, zone = 1, steps = { {} } }
        near(Z.Gain(here, { score = 3300 }), 0.10, 1e-9)
        near(Z.Gain(here, { score = 2400 }), -0.20, 1e-9)
        eq(Z.Gain({ xp = 0, seconds = 0, steps = {} }, { score = 1000 }), nil, "nothing left here")
    end)

    test("a new order replaces the shown one only when clearly better", function()
        local Z = load().Zones
        eq(Z.PreferFresh({ score = 1000, steps = { {} } }, { score = 1040 }), false)
        eq(Z.PreferFresh({ score = 1000, steps = { {} } }, { score = 1100 }), true)
        eq(Z.PreferFresh({ score = 1000, steps = {} }, { score = 10 }), true)
    end)
end)

-- Quests that end beyond the first zone (zone 1's quests with a turn-in or work in zone 2).
-- (A first guess at the XP: the tests check what they rely on, and say what is wrong.)
local function borderWorld(data)
    local q = data.quests
    q[22] = quest({ name = "Letter to the Fort", xp = 120, starts = "n100", ends = "n110" })           -- deliver to zone 2
    q[23] = quest({ name = "Bandit Report", xp = 300, starts = "n101", ends = "n110", objectives = "c210:4:C" }) -- work in zone 2
    q[24] = quest({ name = "Boar Report", xp = 300, starts = "n100", ends = "n110", objectives = "c200:4:C" })   -- work here
    q[25] = quest({ name = "After the Letter", zone = 2, xp = 300, starts = "n110", ends = "n110", preAll = "22" })
    q[26] = quest({ name = "Back Home", xp = 300, starts = "n100", ends = "n100", objectives = "c210:3:C" })    -- work there, turn-in back here
    q[27] = quest({ name = "Second Letter", xp = 300, starts = "n100", ends = "n100", preAll = "22" })         -- follows 22 here
    q[28] = quest({ name = "Far Letter", xp = 300, starts = "n100", ends = "n120" })                          -- turn-in on the other continent
    data.npcs[120] = "Far Clerk|10|10|0|2|A|" .. S(3, 50, 50)
    -- zone 2 long enough to follow zone 1 in an itinerary (Zones.MIN_STAY)
    q[20] = quest({ name = "Other Zone", zone = 2, xp = 700, starts = "n110", ends = "n110", objectives = "c210:20:C" })
    q[21] = quest({ name = "Other Zone 2", zone = 2, xp = 900, starts = "n110", ends = "n110", objectives = "c210:30:C" })
end

H.suite("Quests across a border", function()
    local TAKEN = { [22] = true, [23] = true, [24] = true }
    -- is this order key one of the quests 22-24 (an accept, a turn-in, or a camp of its own)?
    local function ofTaken(key)
        local id = key:match("^[PT]:(%d+)$") or key:match("#(%d+)$")
        return id ~= nil and TAKEN[tonumber(id)] == true
    end
    local function others(plan)
        local out = {}
        for _, k in ipairs(plan.order) do if not ofTaken(k) then out[#out + 1] = k end end
        return out
    end
    local function turnins(plan, skipTaken)
        local sum = 0
        for _, st in ipairs(plan.steps) do
            if st.kind == "turnin" and not (skipTaken and TAKEN[st.quests[1].id]) then sum = sum + st.xp end
        end
        return sum
    end
    local function setOf(list)
        local out = {}
        for _, id in ipairs(list or {}) do out[id] = true end
        return out
    end
    -- zone 1's own plan, and the set 22-24 laid over it (before = its last stop of another quest)
    local function laid(ns, ids)
        local ctx = ns.Zones.Context(state())
        local plain = ns.Zones.PlanZone(1, ctx)
        local before
        for _, k in ipairs(plain.order) do if not ofTaken(k) then before = k end end
        local to = {}
        for _, id in ipairs(ids or { 22, 23, 24 }) do to[id] = 2 end
        local border = { zone = 1, ids = ids or { 22, 23, 24 }, to = to, before = before }
        return plain, ns.Zones.PlanZone(1, ctx, plain.order, plain.from, { border = border }), border, ctx
    end

    test("a quest taken along: only its stops here are planned, nothing else moves", function()
        local ns = load(borderWorld)
        ns.Zones.SEAM = false -- (this suite is about the quests taken along alone)
        local plain, got, border = laid(ns)
        eq(others(got), others(plain), "everything else stays as it was")
        local before = indexOf(got, border.before)
        ok(before, "the stop it is left after is still there")
        for _, id in ipairs({ 22, 23, 24 }) do
            local at = indexOf(got, "P:" .. id)
            ok(at and at > 1 and at < before, "the accept of " .. id .. " is after the first stop and before leaving")
            eq(indexOf(got, "T:" .. id), nil, "its turn-in is no step here")
        end
        for _, st in ipairs(got.steps) do
            if st.kind == "accept" and TAKEN[st.quests[1].id] then eq(st.borderTo, 2, "the accept says where it is finished") end
        end
        local work24
        for i, st in ipairs(got.steps) do
            for _, part in ipairs(st.parts or {}) do if part.quest == 24 then work24 = i end end
        end
        ok(work24 and work24 < before, "the boars of quest 24 are killed here, before leaving")
        eq(got.border[23].left, 1, "its bandits are left to do")
        eq(got.border[22].left, 0)
        eq(got.borderIds, { 22, 23, 24 })
        local sum, want = turnins(got), turnins(plain, true)
        ok(math.abs(sum - want) <= 0.05 * want + 1, "no turn-in XP of theirs here: " .. sum .. " against " .. want)
        eq(keys(select(2, laid(ns))), keys(got), "planned twice: the same route")
    end)

    test("follow-ups of a quest taken along wait", function()
        local ns = load(borderWorld)
        ns.Zones.SEAM = false -- (this suite is about the quests taken along alone)
        local _, got = laid(ns, { 22 })
        eq(indexOf(got, "P:27"), nil, "Second Letter needs a quest that is turned in elsewhere")
        local found
        for _, e in ipairs(got.lists.later) do if e.id == 27 then found = e end end
        ok(found, "it is listed")
        eq(found.reason, "follows a quest finished in the next zone")
    end)

    test("what is left of a quest taken along goes into the log, and the next zone turns it in", function()
        local ns = load(borderWorld)
        ns.Zones.SEAM = false -- (this suite is about the quests taken along alone)
        local _, got, border, ctx = laid(ns)
        local leave = indexOf(got, border.before)
        local after, carried = ns.Zones.Project(state(), ctx, got, leave)
        local byId = {}
        for _, e in ipairs(after.log) do byId[e.id] = e end
        ok(byId[22] and byId[22].isComplete, "a delivery is finished: only the turn-in is left")
        ok(byId[23] and not byId[23].isComplete, "its work in the next zone is not done")
        ok(byId[24] and byId[24].isComplete, "the boars are done here")
        ok(carried[22] and carried[23] and carried[24], "all three are brought along")
        local there = ns.Zones.PlanZone(2, ns.Zones.Context(after))
        local t22, t23, p25 = indexOf(there, "T:22"), indexOf(there, "T:23"), indexOf(there, "P:25")
        ok(t22 and t23, "the next zone turns them in")
        local work23
        for _, st in ipairs(there.steps) do
            for _, part in ipairs(st.parts or {}) do if part.quest == 23 then work23 = true end end
        end
        ok(work23, "and does the work of quest 23")
        ok(p25 and p25 > t22, "the follow-up of 22 is accepted after its turn-in")
    end)

    test("which quests can be taken along", function()
        local ns = load(borderWorld)
        ns.Zones.SEAM = false -- (this suite is about the quests taken along alone)
        local ctx = ns.Zones.Context(state())
        local plain = ns.Zones.PlanZone(1, ctx)
        local leave = #plain.steps
        local list = ns.Zones.BorderQuests(1, ctx, plain, leave, { 2 })
        local found = {}
        for _, q in ipairs(list) do found[q.id] = q.to end
        eq(found[22], 2, "a delivery to the next zone")
        ok(#list >= 2, "and the others that end there")
        eq(found[8], nil, "given in the next zone")
        eq(found[26], nil, "its turn-in is back here")
        local sorted = true
        for i = 2, #list do if list[i - 1].id >= list[i].id then sorted = false end end
        ok(sorted, "by id")
        -- the quest of the step the zone is left after stays
        for i, st in ipairs(plain.steps) do
            local id = st.kind == "turnin" and found[st.quests[1].id] and st.quests[1].id
            if id then
                for _, q in ipairs(ns.Zones.BorderQuests(1, ctx, plain, i, { 2 })) do ok(q.id ~= id, "not the quest of the leave step") end
                break
            end
        end
        local skipped = ns.Zones.Context(state({ ignored = { [22] = true } }))
        local without = {}
        for _, q in ipairs(ns.Zones.BorderQuests(1, skipped, plain, leave, { 2 })) do without[q.id] = true end
        eq(without[22], nil, "one the player skipped")
        eq(#ns.Zones.BorderQuests(1, ctx, setmetatable({ logFull = true }, { __index = plain }), leave, { 2 }), 0, "a full quest log")
        ns.Zones.BORDER_MAX = 1
        eq(#ns.Zones.BorderQuests(1, ctx, plain, leave, { 2 }), 1, "at most Zones.BORDER_MAX")
    end)

    -- the first zone's route on screen, the zones ranked, and the next hours with and without
    local function hours(ns, extra)
        local st = state()
        local ctx = ns.Zones.Context(st)
        local ranked = ns.Zones.Rank(ctx)
        local shown = ns.Zones.PlanZone(1, ctx)
        local opts = { shown = 1, plan = shown }
        for k, v in pairs(extra or {}) do opts[k] = v end
        return ns.Zones.Itinerary(st, ns.Zones.Context(st), ranked, opts), shown, st, ranked
    end

    test("the itinerary takes them along only when it earns more, never less than without", function()
        local ns = load(borderWorld)
        ns.Zones.SEAM = false -- (this suite is about the quests taken along alone)
        ns.Zones.BORDER = false
        local plainIt, shown = hours(ns)
        ok(plainIt and #plainIt.segments >= 2 and plainIt.segments[1].map == 1 and plainIt.segments[2].map == 2,
            "the fixture's itinerary goes from zone 1 to zone 2")
        eq(plainIt.border, nil)
        ns.Zones.BORDER = true
        local it = hours(ns)
        ok(it.xp >= plainIt.xp, "never less")
        ok(it.border and setOf(it.border.ids)[22], "the delivery is taken along")
        ok(it.xp > plainIt.xp * (1 + ns.Zones.BORDER_GAIN), "and earns more than it has to")
        local first = it.segments[1]
        eq(first.leaveKey, plainIt.segments[1].leaveKey, "the moment to leave stands")
        ok(indexOf(first.plan, "P:22") < indexOf(first.plan, first.leaveKey), "accepted before leaving")
        ok(indexOf(it.segments[2].plan, "T:22"), "turned in in the next zone")
        eq(first.plan.base, shown, "the route without them is the base")
        eq(it.here, it.xp)
        ns.Zones.BORDER_GAIN = 1
        local strict = hours(ns)
        eq(strict.border, nil, "not worth a hundred percent more")
        eq(strict.xp, plainIt.xp)
    end)

    test("a quest the next zone does not use is left out again", function()
        local ns = load(borderWorld)
        ns.Zones.SEAM = false -- (this suite is about the quests taken along alone)
        ns.Zones.BORDER_MAX = 8
        local it = hours(ns)
        ok(it and it.border, "something is taken along")
        eq(setOf(it.border.ids)[28], nil, "the letter to the other continent is not used by the next zone")
        eq(indexOf(it.segments[1].plan, "P:28"), nil)
    end)

    test("the set on screen is kept: the itinerary returns the route on screen", function()
        local ns = load(borderWorld)
        ns.Zones.SEAM = false -- (this suite is about the quests taken along alone)
        local it, shown, st, ranked = hours(ns)
        ok(it and it.border)
        local again = ns.Zones.Itinerary(st, ns.Zones.Context(st), ranked,
            { shown = 1, plan = shown, border = it.border, borderPlan = it.segments[1].plan })
        eq(again.segments[1].plan, it.segments[1].plan, "the very route on screen")
        eq(again.border.ids, it.border.ids)
        ns.Zones.BORDER_GAIN = 1
        local kept = ns.Zones.Itinerary(st, ns.Zones.Context(st), ranked,
            { shown = 1, plan = shown, border = it.border, borderPlan = it.segments[1].plan })
        ok(kept.border, "a set on screen stays while it earns no less")
    end)

    test("Zones.WithBorder lays the set over a route and leaves other zones alone", function()
        local ns = load(borderWorld)
        ns.Zones.SEAM = false -- (this suite is about the quests taken along alone)
        local it, shown = hours(ns)
        ok(it and it.border)
        local ctx = ns.Zones.Context(state())
        local with = ns.Zones.WithBorder(1, ctx, shown, it.border)
        ok(indexOf(with, "P:22"), "the accept is in it")
        eq(with.base, shown)
        eq(ns.Zones.WithBorder(2, ctx, shown, it.border), shown, "a set for another zone")
        eq(ns.Zones.WithBorder(1, ctx, shown, nil), shown, "no set")
        ns.Zones.BORDER = false
        eq(ns.Zones.WithBorder(1, ctx, shown, it.border), shown, "the flag off")
        ns.Zones.BORDER = true
        -- accepted meanwhile, with nothing left to do here: taken out of the route, not planned again
        local log = { { id = 22, isComplete = true, objectives = {} } }
        local ctx2 = ns.Zones.Context(state({ log = log }))
        local base = ns.Zones.PlanZone(1, ctx2)
        local gone = ns.Zones.WithBorder(1, ctx2, base, { zone = 1, ids = { 22 }, to = { [22] = 2 } })
        eq(indexOf(gone, "P:22"), nil)
        eq(indexOf(gone, "T:22"), nil)
        local listedGone
        for _, e in ipairs((gone.lists or base.lists).skipped) do
            if e.id == 22 and e.reason == "finished in the next zone" then listedGone = true end
        end
        ok(gone == base or listedGone, "listed as finished in the next zone")
    end)

    test("with nothing to take along, the flag changes nothing", function()
        local function run(flag)
            local ns = load()
            ns.Zones.SEAM = false -- (this suite is about the quests taken along alone)
            ns.Zones.BORDER = flag
            local it = hours(ns)
            local out = { xp = it.xp, border = it.border }
            for i, seg in ipairs(it.segments) do
                out[i] = { seg.map, seg.leave, seg.leaveKey, seg.xp, seg.seconds, table.concat(seg.plan.order, " ") }
            end
            return out
        end
        local on, off = run(true), run(false)
        eq(H.serialize(on), H.serialize(off))
        eq(on.border, nil)
    end)

    test("the accept says where the quest is finished", function()
        local ns = load()
        ns.Zones.SEAM = false -- (this suite is about the quests taken along alone)
        local step = { kind = "accept", target = "Marshal", borderTo = 2, travel = 0, seconds = 8 }
        ns.Format.MapName = nil -- (the window sets it to the map names it knows)
        H.contains(ns.Format.StepDetail(step), "finished in the next zone")
        ns.Format.MapName = function() return "Fort Zone" end
        H.contains(ns.Format.StepDetail(step), "finished in Fort Zone")
    end)

    test("the border search yields to the game", function()
        local ns = load(borderWorld)
        ns.Zones.SEAM = false -- (this suite is about the quests taken along alone)
        local st = state()
        local calls, yields = 0, 0
        st.checkpoint = function()
            calls = calls + 1
            if calls % 7 == 0 then yields = yields + 1; coroutine.yield() end
        end
        local co = coroutine.create(function()
            local ctx = ns.Zones.Context(st)
            local ranked = ns.Zones.Rank(ctx)
            local shown = ns.Zones.PlanZone(1, ctx)
            return ns.Zones.Itinerary(st, ns.Zones.Context(st), ranked, { shown = 1, plan = shown })
        end)
        local result
        for _ = 1, 1000000 do
            local good, value = coroutine.resume(co)
            if not good then error(value) end
            if coroutine.status(co) == "dead" then result = value; break end
        end
        ok(result, "it finishes")
        ok(yields > 0, "and yields on the way")
    end)
end)

-- Two zones whose routes meet at the border: a camp near zone 1's east edge (x 100 of map 1 is x 0 of
-- map 2) and one near zone 2's west edge, and zone 2 long enough to follow zone 1 (Zones.MIN_STAY).
-- (A first guess at the XP: the tests check what they rely on, and say what is wrong.)
local function seamWorld(data)
    local q = data.quests
    data.npcs[130] = "Border Scout|10|10|0|2|A|" .. S(1, 92, 50)
    data.npcs[131] = "Fort Lookout|10|10|0|2|A|" .. S(2, 6, 50)
    data.npcs[220] = "Border Wolf|8|8|0|0||" .. camp(1, 95, 45)
    data.npcs[221] = "Ridge Boar|8|8|0|0||" .. camp(2, 8, 55)
    q[40] = quest({ name = "Border Watch", xp = 450, starts = "n130", ends = "n130", objectives = "c220:6:C" })
    q[41] = quest({ name = "Lookout Duty", zone = 2, xp = 450, starts = "n131", ends = "n131", objectives = "c221:6:C" })
    q[20] = quest({ name = "Other Zone", zone = 2, xp = 700, starts = "n110", ends = "n110", objectives = "c210:20:C" })
    q[21] = quest({ name = "Other Zone 2", zone = 2, xp = 900, starts = "n110", ends = "n110", objectives = "c210:30:C" })
end

H.suite("The way across a border, planned together", function()
    -- the first zone's route on screen, the zones ranked, and the next hours (as the border suite's `hours`)
    local function hours(ns, extra)
        local st = state()
        local ctx = ns.Zones.Context(st)
        local ranked = ns.Zones.Rank(ctx)
        local shown = ns.Zones.PlanZone(1, ctx)
        local opts = { shown = 1, plan = shown }
        for k, v in pairs(extra or {}) do opts[k] = v end
        return ns.Zones.Itinerary(st, ns.Zones.Context(st), ranked, opts), shown, st, ranked
    end
    -- what an itinerary decided, to compare two runs
    local function summary(it)
        local out = { xp = it.xp }
        for i, seg in ipairs(it.segments) do
            out[i] = { seg.map, seg.leave, seg.leaveKey, seg.xp, seg.seconds, table.concat(seg.plan.order, " ") }
        end
        return out
    end
    -- the world loaded with the flags the tests are about: the quests taken along are left out of it
    local function world(build, flags)
        local ns = load(build)
        ns.Zones.BORDER = false
        for k, v in pairs(flags or {}) do ns.Zones[k] = v end
        return ns
    end
    local function copyOf(list)
        local out = {}
        for i, k in ipairs(list) do out[i] = k end
        return out
    end

    test("exact seeded plans keep the seed: nothing is added, nothing dropped", function()
        local ns = load()
        local ctx = ns.Zones.Context(state())
        local plain = ns.Zones.PlanZone(1, ctx)
        local again = ns.Zones.PlanZone(1, ctx, plain.order, nil, { exact = true })
        eq(keys(again), keys(plain), "the seed is the route")
        ok(indexOf(plain, "T:4"), "precondition: Statues is in zone 1's own route")
        local without = {}
        for _, k in ipairs(plain.order) do
            if k ~= "P:4" and k ~= "T:4" and not k:find("^W:o400") then without[#without + 1] = k end
        end
        local gap = ns.Zones.PlanZone(1, ctx, without, nil, { exact = true })
        eq(indexOf(gap, "P:4"), nil, "what the seed does not have is not added")
        eq(indexOf(gap, "T:4"), nil)
        local found
        for _, id in ipairs(listed(gap.lists.skipped)) do if id == 4 then found = true end end
        ok(found, "and is listed as left out")
        local slow = copyOf(plain.order)
        slow[#slow + 1], slow[#slow + 2] = "P:10", "T:10"
        local exact = ns.Zones.PlanZone(1, ctx, slow, nil, { exact = true })
        ok(indexOf(exact, "T:10"), "a slow quest in the seed stays")
        local loose = ns.Zones.PlanZone(1, ctx, slow)
        eq(indexOf(loose, "T:10"), nil, "precondition: without exact it is dropped as slow")
    end)

    test("the stretch rebuilt as one route gives back what it was given", function()
        -- (Far Giver is planned by both zones: left out, so that every quest is on one side)
        local ns = load(function(data) data.quests[8] = nil end)
        local Z = ns.Zones
        local ctx = Z.Context(state())
        local a, b = Z.PlanZone(1, ctx), Z.PlanZone(2, ctx)
        local side = {}
        local function sidesOf(plan, mark)
            for _, st in ipairs(plan.steps) do
                for _, q in ipairs(st.quests or {}) do
                    side[q.id] = (side[q.id] and side[q.id] ~= mark) and "X" or mark
                end
            end
        end
        sidesOf(a, "A")
        sidesOf(b, "B")
        local shared = 0
        for _, s in pairs(side) do if s == "X" then shared = shared + 1 end end
        eq(shared, 0, "precondition: no quest is in both routes")
        local function spec(extra)
            local s = { also = { 2 }, keysA = a.order, keysB = b.order, side = side, ghost = {}, after = {}, free = {},
                horizon = 9000, switch = 120, rounds = 0, work = 1e9, seed = 12345 }
            for k, v in pairs(extra or {}) do s[k] = v end
            return s
        end
        local function plan(extra) return Z.PlanSeam(1, Z.Context(state()), spec(extra), a.overhead) end
        local res = plan()
        ok(res, "the stretch can be rebuilt")
        eq(res.keysA, a.order, "the first side as it was given")
        eq(res.keysB, b.order, "the next zone's side as it was given")
        eq(res.value, res.start, "nothing searched: nothing changed")
        -- searched: every stop on its side, nothing twice, accepts before turn-ins, never worse
        local found = plan({ rounds = 30 })
        local seen = {}
        local function check(list, mark)
            for _, key in ipairs(list) do
                ok(not seen[key], "no key twice: " .. key)
                seen[key] = true
                local id = key:match("^[PT]:(%d+)$")
                if id then eq(side[tonumber(id)], mark, key .. " is on its own side") end
            end
        end
        check(found.keysA, "A")
        check(found.keysB, "B")
        local order = {}
        for _, k in ipairs(found.keysA) do order[#order + 1] = k end
        for _, k in ipairs(found.keysB) do order[#order + 1] = k end
        local index = {}
        for i, k in ipairs(order) do index[k] = i end
        for i, k in ipairs(order) do
            local id = k:match("^P:(%d+)$")
            if id and index["T:" .. id] then ok(index["T:" .. id] > i, "quest " .. id .. ": accepted before it is turned in") end
        end
        ok(found.value >= found.start - 1e-9, "never worse than it started")
        local twice = plan({ rounds = 30 })
        eq(twice.keysA, found.keysA, "planned twice: the same")
        eq(twice.keysB, found.keysB)
        -- a quest done on both sides stays where it is (Statues: nothing follows it)
        ok(indexOf(a, "T:4"), "precondition: Statues is in zone 1's route")
        local keysA, keysB = {}, { "T:4" }
        for _, k in ipairs(a.order) do if k ~= "T:4" then keysA[#keysA + 1] = k end end
        for _, k in ipairs(b.order) do keysB[#keysB + 1] = k end
        local side2 = {}
        for id, s in pairs(side) do side2[id] = s end
        side2[4] = "X"
        local fixed = plan({ keysA = keysA, keysB = keysB, side = side2, rounds = 30 })
        local function has(list, key) for _, k in ipairs(list) do if k == key then return true end end return false end
        ok(has(fixed.keysA, "P:4"), "its accept stays on the first side")
        ok(has(fixed.keysB, "T:4"), "its turn-in on the next zone's")
        local all = {}
        for _, k in ipairs(fixed.keysA) do all[#all + 1] = k end
        for _, k in ipairs(fixed.keysB) do all[#all + 1] = k end
        local pos = {}
        for i, k in ipairs(all) do
            if k == "P:4" or k == "T:4" or k:find("^W:o400") then pos[#pos + 1] = i end
        end
        local sorted = #pos >= 3
        for i = 2, #pos do if pos[i - 1] >= pos[i] then sorted = false end end
        ok(sorted, "its keys keep their order")
        -- a quest that goes on after the stretch: its stops are kept where they are, as stops of no quest
        local keysB3 = {}
        for _, k in ipairs(keysB) do
            if k ~= "T:21" and not k:find("#21$") then keysB3[#keysB3 + 1] = k end
        end
        local side3, ghost = {}, { [21] = true }
        for id, s in pairs(side2) do side3[id] = s end
        side3[21] = nil
        local kept = plan({ keysA = keysA, keysB = keysB3, side = side3, ghost = ghost, rounds = 30 })
        ok(has(kept.keysB, "P:21"), "its accept is in the stretch")
        local function relative(list)
            local out = {}
            for _, k in ipairs(list) do
                if k == "P:4" or k == "T:4" or k == "P:21" or k:find("^W:o400") then out[#out + 1] = k end
            end
            return out
        end
        local given = {}
        for _, k in ipairs(keysA) do given[#given + 1] = k end
        for _, k in ipairs(keysB3) do given[#given + 1] = k end
        local now = {}
        for _, k in ipairs(kept.keysA) do now[#now + 1] = k end
        for _, k in ipairs(kept.keysB) do now[#now + 1] = k end
        eq(relative(now), relative(given), "the stops that stay come in the order they were given")
    end)

    test("Zones.WithSeam lays a way across over a route; another route does not take it", function()
        local ns = load()
        local Z = ns.Zones
        local ctx = Z.Context(state())
        local base = Z.PlanZone(1, ctx)
        local o = base.order
        local i
        for k = #o - 1, 2, -1 do
            if o[k]:find("^P:") and o[k + 1]:find("^P:") then i = k; break end
        end
        ok(i, "precondition: two accepts in a row after the first stop")
        local recipe = { zone = 1, to = 2, window = { o[i], o[i + 1] }, keys = { o[i + 1], o[i] }, leave = o[i],
            windowB = {}, head = {} }
        local laid = Z.WithSeam(1, ctx, base, recipe)
        ok(laid ~= base, "laid over the route")
        eq(#laid.order, #base.order)
        eq(laid.order[i], o[i + 1], "the two accepts swapped")
        eq(laid.order[i + 1], o[i])
        for k = 1, #o do
            if k ~= i and k ~= i + 1 then eq(laid.order[k], o[k], "every other key where it was") end
        end
        ok(laid.seamBase == base, "the route under it")
        ok(laid.seamRecipe == recipe)
        ok(Z.Plain(laid) == base, "the route without it")
        ok(Z.SeamLayer(laid) == laid)
        eq(Z.SeamLayer(base), nil)
        -- another route: the stretch is not in it in that order
        local swapped = copyOf(o)
        swapped[i], swapped[i + 1] = o[i + 1], o[i]
        eq(Z.SeamOrder(swapped, recipe), nil, "the keys the other way round: not this route")
        local other = Z.PlanZone(1, ctx, swapped)
        ok(indexOf(other, o[i + 1]) < indexOf(other, o[i]), "precondition: the seeded route keeps its order")
        ok(Z.WithSeam(1, ctx, other, recipe) == other, "another route takes nothing")
        -- a route that has moved on (its first accept is done): still laid over
        if o[1]:find("^P:") then
            local id = tonumber(o[1]:match("^P:(%d+)"))
            local ctx2 = Z.Context(state({ log = { { id = id, isComplete = false, objectives = {} } } }))
            local moved = Z.PlanZone(1, ctx2, o)
            eq(indexOf(moved, o[1]), nil, "precondition: its first accept is gone")
            local got = Z.WithSeam(1, ctx2, moved, recipe)
            ok(got ~= moved, "still laid over")
            ok(indexOf(got, o[i + 1]) < indexOf(got, o[i]), "the two keys swapped")
        end
        local gone = { zone = 1, to = 2, window = recipe.window, keys = recipe.keys, leave = "P:99999", windowB = {}, head = {} }
        ok(Z.WithSeam(1, ctx, base, gone) == base, "a step it leaves after that is not in the route")
        ok(Z.WithSeam(2, ctx, base, recipe) == base, "a way across for another zone")
        ok(Z.WithSeam(1, ctx, base, nil) == base, "none")
        Z.SEAM = false
        ok(Z.WithSeam(1, ctx, base, recipe) == base, "the flag off")
    end)

    test("the itinerary plans the way across together only when it earns more, never less", function()
        local ns = world(seamWorld, { SEAM = false })
        local plainIt, shown = hours(ns)
        ok(plainIt and #plainIt.segments >= 2 and plainIt.segments[1].map == 1 and plainIt.segments[2].map == 2,
            "the fixture's itinerary goes from zone 1 to zone 2")
        eq(plainIt.seam, nil)
        eq(plainIt.seamInfo, nil, "the flag off: nothing looked at")
        ns.Zones.SEAM = true
        local it = hours(ns)
        ok(it.xp >= plainIt.xp, "never less")
        local info = it.seamInfo
        ok(info and info.ran, "the gate is on and the search ran (gated: " .. tostring(info and info.gated) .. ")")
        ok(it.seam, "a way across is taken (tune quests 40/41 of the fixture)")
        ok(it.xp > plainIt.xp * (1 + ns.Zones.SEAM_GAIN), "and earns more than it has to")
        local first = it.segments[1]
        eq(first.leaveKey, it.seam.leave, "the first zone is left after the step the way across ends with")
        ok(first.plan.seamBase == shown, "the route without it is the base")
        ok(ns.Zones.Plain(first.plan) == shown)
        eq(it.here, it.xp)
        -- the accept of the border quest: before the step the zone is left after (and later than in the plain route, if it was there)
        local at, leave, was = indexOf(first.plan, "P:40"), indexOf(first.plan, first.leaveKey), indexOf(shown, "P:40")
        if was then
            ok(at and at > was, "Border Watch was in the zone's own route and is done later, nearer the border")
        else
            ok(at and at < leave, "Border Watch was left out and is done before leaving")
        end
        ns.Zones.SEAM_GAIN = 1
        local strict = hours(ns)
        eq(strict.seam, nil, "not worth a hundred percent more")
        eq(strict.xp, plainIt.xp)
    end)

    test("the way across on screen is kept", function()
        local ns = world(seamWorld)
        local it, shown, st, ranked = hours(ns)
        ok(it and it.seam, "precondition: a way across is taken")
        -- (the Engine lays the recipe it keeps over the route, so that plan's recipe is the one passed back)
        local on = it.segments[1].plan
        local again = ns.Zones.Itinerary(st, ns.Zones.Context(st), ranked,
            { shown = 1, plan = shown, seam = on.seamRecipe, seamPlan = on })
        ok(again.segments[1].plan == on, "the very route on screen")
        eq(again.seamInfo.won, "kept")
        ns.Zones.SEAM_GAIN = 1
        local kept = ns.Zones.Itinerary(st, ns.Zones.Context(st), ranked,
            { shown = 1, plan = shown, seam = on.seamRecipe, seamPlan = on })
        ok(kept.seam, "one on screen stays while it earns no less")
    end)

    test("nothing runs where it cannot matter", function()
        local function run(build, flags)
            local ns = world(build, flags)
            local calls = 0
            local planSeam = ns.Zones.PlanSeam
            ns.Zones.PlanSeam = function(...) calls = calls + 1; return planSeam(...) end
            return hours(ns), calls
        end
        local off = run(seamWorld, { SEAM = false })
        local far, calls = run(seamWorld, { SEAM_TRIP = -1 })
        ok(far.seamInfo, "precondition: the itinerary goes on to a second zone")
        eq(far.seamInfo.gated, "far", "a trip longer than allowed")
        eq(calls, 0, "nothing is planned together")
        eq(far.seam, nil)
        eq(H.serialize(summary(far)), H.serialize(summary(off)), "the same itinerary as with the flag off")
        -- the base fixture: whatever the gate says, a way across that is not taken changes nothing
        local plain = run(nil, { SEAM = false })
        local on = run(nil, { SEAM = true })
        if on.seam == nil then
            eq(H.serialize(summary(on)), H.serialize(summary(plain)), "none taken: the same itinerary")
        else
            print("note: the base fixture takes a way across: nothing to compare")
        end
    end)

    test("the stretch: its size, and nothing found without rounds", function()
        local ns = world(seamWorld, { SEAM = false })
        local plainIt = hours(ns)
        ns.Zones.SEAM, ns.Zones.SEAM_ROUNDS = true, 0
        local it = hours(ns)
        local info = it.seamInfo
        ok(info and info.ran, "precondition: the gate is on (gated: " .. tostring(info and info.gated) .. ")")
        eq(info.keysA[#info.keysA], plainIt.segments[1].leaveKey, "the stretch ends with the step the zone is left after")
        eq(info.keysB[1], plainIt.segments[2].plan.order[1], "and begins with the next zone's first step")
        local Z = ns.Zones
        ok(info.windowA >= 1 and info.windowA <= Z.SEAM_MAX_STOPS, "the first zone's side is not larger than allowed")
        ok(info.windowB >= 1 and info.windowB <= Z.SEAM_MAX_STOPS, "nor the next zone's")
        eq(info.proxyBest, info.proxyStart, "nothing searched: nothing found")
        eq(it.seam, nil)
        eq(it.xp, plainIt.xp)
    end)

    test("the way across and quests taken along together", function()
        local ns = load(function(data) borderWorld(data); seamWorld(data) end)
        ns.Zones.SEAM, ns.Zones.BORDER = false, false
        local off, shown = hours(ns)
        ns.Zones.SEAM, ns.Zones.BORDER = true, true
        local it = hours(ns)
        ok(it.xp >= off.xp, "never less than with both off")
        if it.seam and it.border then
            eq(it.border.before, it.seam.leave, "the quests are taken along before the step the way across ends with")
            local plan = it.segments[1].plan
            ok(plan.base and plan.base.seamBase == shown, "the way across is under the quests taken along")
            ok(ns.Zones.Plain(plan) == shown, "and the route without both is the base")
        else
            print("note: the fixture does not make both (seam " .. tostring(it.seam ~= nil) .. ", border "
                .. tostring(it.border ~= nil) .. "): only the figure was compared")
        end
    end)

    test("the way across yields to the game", function()
        local ns = world(seamWorld)
        local st = state()
        local calls, yields = 0, 0
        st.checkpoint = function()
            calls = calls + 1
            if calls % 7 == 0 then yields = yields + 1; coroutine.yield() end
        end
        local co = coroutine.create(function()
            local ctx = ns.Zones.Context(st)
            local ranked = ns.Zones.Rank(ctx)
            local shown = ns.Zones.PlanZone(1, ctx)
            return ns.Zones.Itinerary(st, ns.Zones.Context(st), ranked, { shown = 1, plan = shown })
        end)
        local result
        for _ = 1, 1000000 do
            local good, value = coroutine.resume(co)
            if not good then error(value) end
            if coroutine.status(co) == "dead" then result = value; break end
        end
        ok(result, "it finishes")
        ok(yields > 0, "and yields on the way")
    end)
end)

H.suite("Learning", function()
    test("pace: starts at players' typical, moves towards our own, fades old samples", function()
        local L = load().Learn
        local store = {}
        near(L.PaceFactor(store, "c"), 1, 1e-9, "no samples: the typical pace")
        ok(L.AddPace(store, "c", 0.5))
        near(L.PaceFactor(store, "c"), 0.5 ^ (1 / 4), 1e-9, "one sample against a prior worth three")
        for _ = 1, 40 do L.AddPace(store, "c", 0.5) end
        eq(store.c.n, 20, "the count stops at the memory length")
        near(L.PaceFactor(store, "c"), 0.5 ^ (20 / 23), 1e-9)
        for _ = 1, 200 do L.AddPace(store, "c", 2) end
        near(L.PaceFactor(store, "c"), 2 ^ (20 / 23), 1e-3, "a lasting change of pace replaces the old one")
        -- one wild sample counts as four times slower at most
        local a, b = {}, {}
        L.AddPace(a, "i", 1000)
        L.AddPace(b, "i", 4)
        eq(a.i.m, b.i.m)
        eq({ L.AddPace(store, "x", 2), L.AddPace(store, "c", 0), L.AddPace(store, "c", 0 / 0), L.AddPace(store, "c", "2") },
            { false, false, false, false }, "other keys and bad numbers are refused")
        local pace = L.Pace({ c = 30, i = 20, o = 15, x = 60, r = 7 }, { o = { n = 20, m = math.log(2) } })
        near(pace.o, 15 * 2 ^ (20 / 23), 1e-9)
        eq({ pace.c, pace.x, pace.r }, { 30, 60, 7 }, "the rest is untouched")
    end)

    test("drop rates: the database rate, moved by our own kills and drops", function()
        local L = load().Learn
        local store = {}
        eq({ L.DropRate(0.5, store, 300, 200) }, { 0.5, false })
        L.AddDrops(store, 300, 200, 20, 2)
        local rate, learned = L.DropRate(0.5, store, 300, 200)
        near(rate, 0.3, 1e-9, "(0.5 x 20 + 2) / (20 + 20)")
        eq(learned, true)
        eq({ L.DropRate(0.5, store, 300, 999) }, { 0.5, false }, "counts are per mob")
        -- no database rate: nothing until five kills, then a weak starting guess plus our counts
        L.AddDrops(store, 301, 205, 4, 2)
        eq({ L.DropRate(nil, store, 301, 205) }, { nil, false })
        L.AddDrops(store, 301, 205, 2, 1)
        near(L.DropRate(nil, store, 301, 205), (0.35 * 4 + 3) / 10, 1e-9)
        -- more drops than kills (two in one corpse) cannot push the rate over 100%
        L.AddDrops(store, 302, 1, 2, 5)
        ok(L.DropRate(0.9, store, 302, 1) <= 1)
    end)

    test("tracker: time between two ticks of an objective is a pace sample (solo, same area, same stretch)", function()
        local ns = load()
        local pace, drops = {}, {}
        ns.Tracker.Start(pace, drops)
        local have, now, where, solo = 0, 0, ns.Geo.Loc(1, 60, 50), true
        local function tick(seconds, extra)
            have, now = have + (extra or 1), now + seconds
            ns.Tracker.OnLog({ { id = 1, objectives = { { have = have, need = 10 } } } },
                { now = now, level = 8, solo = solo, faction = "Alliance", loc = where })
        end
        tick(0, 0)
        tick(100)
        eq(pace.c, nil, "the first tick has nothing to be timed from")
        tick(15)
        eq(pace.c.n, 1)
        near(pace.c.m, math.log(15 / 30), 1e-9, "15 seconds a boar against players' 30")
        tick(40, 2)
        near(pace.c.m, (math.log(0.5) + math.log(20 / 30)) / 2, 1e-9, "two kills in 40 seconds: 20 each")
        tick(1000)
        eq(pace.c.n, 2, "a long break is not a kill time")
        where = ns.Geo.Loc(1, 5, 5)
        tick(15)
        eq(pace.c.n, 2, "nor is a trip across the zone")
        solo = false
        tick(15)
        eq(pace.c.n, 2, "nor a kill made in a group")
        -- the planner uses it
        local ctx = ns.Zones.Context(state({ pace = pace }))
        near(ctx.pace.c, 30 * ns.Learn.PaceFactor(pace, "c"), 1e-9)
        ok(ctx.pace.c < 30)
        eq(ctx.pace.i, 20, "nothing learned about items yet")
    end)

    test("tracker: items and objects have their own pace; elites teach nothing", function()
        local ns = load()
        local pace = {}
        ns.Tracker.Start(pace, {})
        local now = 0
        local function log(hides, statues, ogres)
            now = now + 10
            ns.Tracker.OnLog({ { id = 2, objectives = { { have = hides, need = 4 } } },
                { id = 4, objectives = { { have = statues, need = 3 } } },
                { id = 6, objectives = { { have = ogres, need = 1 } } } }, { now = now, level = 8, solo = true })
        end
        log(0, 0, 0); log(1, 0, 0); log(1, 1, 0); log(2, 1, 0); log(2, 2, 1)
        near(pace.i.m, math.log(20 / 20), 1e-9, "20 seconds between two hides")
        near(pace.o.m, math.log(20 / 15), 1e-9, "20 seconds between two statues")
        eq(pace.c, nil)
    end)

    test("tracker: kills of a mob while its item is wanted are tries, a tick after a kill is a drop", function()
        local ns = load(function(data)
            data.npcs[200] = "Boar|7|8|0|0||" .. camp(1, 60, 50, 60)
        end)
        local pace, drops = {}, {}
        ns.Tracker.Start(pace, drops)
        local now, hides = 0, 0
        local function log(finished)
            ns.Tracker.OnLog({ { id = 2, objectives = { { have = hides, need = 4, finished = finished } } } },
                { now = now, level = 8, solo = true })
        end
        local function kill(npc, solo)
            now = now + 20
            ns.Tracker.OnKill(npc, { now = now, solo = solo ~= false })
        end
        kill(200)
        eq({ ns.Learn.DropCounts(drops, 300, 200) }, { 0, 0 }, "not wanted yet: not a try")
        log()
        kill(200); kill(200); kill(210)
        hides = 1; log()
        eq({ ns.Learn.DropCounts(drops, 300, 200) }, { 2, 1 }, "the bandit in between does not drop hides")
        kill(200); kill(nil)
        hides = 2; log()
        eq({ ns.Learn.DropCounts(drops, 300, 200) }, { 3, 1 }, "a kill the client hid: the hide is not counted")
        kill(200, false)
        hides = 3; log()
        eq({ ns.Learn.DropCounts(drops, 300, 200) }, { 3, 1 }, "in a group nothing is counted")
        kill(200)
        now = now + 500
        hides = 4; log(true)
        eq({ ns.Learn.DropCounts(drops, 300, 200) }, { 4, 1 }, "a hide long after the kill came from somewhere else")
        kill(200)
        eq({ ns.Learn.DropCounts(drops, 300, 200) }, { 4, 1 }, "objective finished: kills are no longer tries")

        -- the planner: 4 hides at 50% is 10 kills; having seen 2 in 20, it plans for 30%
        local function boarKills(store)
            local plan = ns.Zones.PlanZone(1, ns.Zones.Context(state({ ignored = { [1] = true }, drops = store })))
            for i, s in ipairs(plan.steps) do if plan.order[i] == "W:m200" then return s.kills end end
        end
        eq(boarKills(nil), 10)
        eq(boarKills({ ["300:200"] = { k = 20, d = 2 } }), ns.Cost.KillsForItems(4, 0.3))
        ok(boarKills({ ["300:200"] = { k = 20, d = 20 } }) < 10, "and for fewer kills when it drops more often")

        -- /ls learn's text, and forgetting
        local text = table.concat(ns.Tracker.Describe(), "\n")
        H.contains(text, "Boar Hide from Boar: 1 in 4 kills; database 50%, planned with 46%")
        H.contains(text, "time per kill: players' typical (no samples yet)")
        ns.Tracker.Reset()
        eq(drops, {})
    end)

    test("step log: a finished first step is written down with its planned and real time", function()
        local ns = load()
        local steps = {}
        ns.Tracker.Start({}, {}, steps)
        local T = ns.Tracker
        local function plan(key, step) return { order = { key, "T:9" }, steps = { step, {} } } end
        local accept = plan("P:1", { kind = "accept", action = "accept", travel = 52, seconds = 8, quests = { { id = 1 } } })
        local work = plan("W:m200", { kind = "work", action = "kill", travel = 100.4, seconds = 300, group = true,
            kills = 12, mobLevel = 9.5, parts = { { quest = 1, index = 1 }, { quest = 8, index = 1 } } })
        local turnin = plan("T:1", { kind = "turnin", action = "turnin", travel = 90, seconds = 8, quests = { { id = 1 } } })
        local function log(boars, far) return {
            { id = 1, objectives = { { have = boars, need = 10, finished = boars >= 10 } } },
            { id = 8, isComplete = far, objectives = { { have = 0, need = 5, finished = false } } } } end

        T.OnPlan(accept, { now = 100, level = 8, log = {} })
        T.OnPlan(accept, { now = 130, level = 8, log = {} })
        eq(#steps, 0, "still the same step")
        T.OnPlan(work, { now = 175, level = 8, group = 2, log = log(0) })
        eq(steps[1], { k = "accept", w = "accept", p = 60, pt = 52, a = 75, lv = 8, g = 2 })
        T.OnPlan(work, { now = 300, level = 8, log = log(6) })
        T.OnPlan(turnin, { now = 400, level = 8, log = log(10) })
        eq(#steps, 1, "one of the two quests it was for is not done: the route changed, the step did not finish")
        T.OnPlan(work, { now = 500, level = 8, log = log(6) })
        T.OnPlan(turnin, { now = 800, level = 9, log = log(10, true) })
        eq(steps[2], { k = "work", w = "kill", p = 400, pt = 100, a = 300, lv = 9, g = 1, e = true, n = 12, d = 2 })
        T.OnPlan(nil, { now = 900, level = 9, log = log(10, true), completed = { [1] = true } })
        eq(steps[3].k, "turnin")
        eq(steps[3].a, 100)
        -- a step left for hours, and a turn-in that did not happen
        T.OnPlan(accept, { now = 1000, log = {} })
        T.OnPlan(nil, { now = 1000 + T.STEP_MAX + 1, log = { { id = 1, objectives = {} } } })
        T.OnPlan(turnin, { now = 20000, log = {} })
        T.OnPlan(nil, { now = 20050, log = {}, completed = {} })
        eq(#steps, 3)

        local stats = T.StepStats()
        eq(stats.all.n, 3)
        near(stats.all.ratio, 100 / 98, 1e-9, "the median of 75/60, 300/400 and 100/98")
        eq(stats.byKind[1].name, "kill")
        near(stats.byKind[1].ratio, 0.75, 1e-9)
        eq({ stats.byKind[2].name, stats.byKind[2].n }, { "talk", 2 })
        local text = table.concat(T.Describe(), "\n")
        H.contains(text, "plan accuracy: 3 steps took 102% of the planned time (median)")
        H.contains(text, "kill steps: 75% (1)")
        -- only the newest are kept
        T.KEEP_STEPS = 2
        T.OnPlan(accept, { now = 30000, log = {} })
        T.OnPlan(nil, { now = 30010, log = { { id = 1, objectives = {} } } })
        eq(#steps, 2)
        eq(steps[2].a, 10)
        T.KEEP_STEPS = 300
        T.Reset()
        eq(steps, {})
    end)

    test("active time: standing idle is left out; a step's travel and its work are timed and learned apart", function()
        local ns = load()
        local T, Geo, Learn = ns.Tracker, ns.Geo, ns.Learn
        Geo.Init(ns.data.world)
        local steps, model = {}, {}
        T.Start({}, {}, steps, model)
        local function look(t, x, extra)
            local info = { now = t, level = 8, loc = Geo.Loc(1, x, 50) }
            for k, v in pairs(extra or {}) do info[k] = v end
            T.OnMove(info)
        end
        -- a kill step at the boars (60, 50): 100 s of travel planned, then 300 s of work
        local work = { order = { "W:m200" }, steps = { { kind = "work", action = "kill", travel = 100, seconds = 300,
            loc = Geo.Loc(1, 60, 50), kills = 10, parts = { { quest = 1, index = 1 } } } } }
        look(0, 40)
        T.OnPlan(work, { now = 0, level = 8, log = {} })
        for t = 1, 14 do look(t, 40 + t) end           -- 10 yards a second: 60 yards from the camp at 14 s
        for t = 15, 114 do look(t, 54) end             -- then standing for 100 s: the first 15 count
        for t = 115, 164 do look(t, 54, { blocked = true }) end -- fighting (in combat): counts
        eq(T.Active(164), 164 - 85, "85 seconds idle left out")
        T.OnPlan(nil, { now = 164, level = 8, log = { { id = 1, isComplete = true, objectives = { { finished = true } } } } })
        eq({ steps[1].a, steps[1].at, steps[1].aw }, { 79, 14, 65 })
        eq(model.n, 2, "learned as two parts: the way there, and the work")
        ok(Learn.TravelFactor(model) < 1, "travel took less than planned")
        ok(Learn.WorkFactor(model, "kill") < 1, "so did the killing")
        local stats = T.StepStats()
        near(stats.travel.ratio, 0.14, 1e-9)
        near(stats.stop.ratio, 65 / 300, 1e-9)
        H.contains(table.concat(T.Describe(), "\n"), "getting there: 14% of the planned travel (1)")
        -- a step whose place was never seen reached: learned as a whole, as before
        steps, model = {}, {}
        T.Start({}, {}, steps, model)
        T.OnPlan(work, { now = 0, level = 8, log = {} })
        T.OnPlan(nil, { now = 200, level = 8, log = { { id = 1, isComplete = true, objectives = { { finished = true } } } } })
        eq({ steps[1].a, steps[1].at, steps[1].aw, model.n }, { 200, nil, nil, 1 })
    end)

    test("kill pace is counted in active time: a break at the camp does not slow it down", function()
        local ns = load()
        local T, Geo, Learn = ns.Tracker, ns.Geo, ns.Learn
        Geo.Init(ns.data.world)
        local here = Geo.Loc(1, 60, 50)
        local function log(have) return { { id = 1, objectives = { { have = have, need = 10 } } } } end
        local function info(t) return { now = t, level = 8, solo = true, faction = "Alliance", loc = here } end
        local away, straight = {}, {}
        T.Start(away, {}, {}, {})
        T.OnLog(log(0), info(0))
        T.OnLog(log(1), info(1)) -- (the first kill starts the stretch)
        for t = 1, 131 do T.OnMove({ now = t, level = 8, loc = here }) end -- 130 s at the camp, 115 of them idle
        T.OnLog(log(2), info(131))
        T.Start(straight, {}, {}, {})
        T.OnLog(log(0), info(0))
        T.OnLog(log(1), info(1))
        T.OnLog(log(2), info(16))
        eq(away.c and away.c.n, 1, "a sample was taken")
        eq(Learn.PaceFactor(away, "c"), Learn.PaceFactor(straight, "c"), "15 active seconds for the kill either way")
    end)

    test("drop rates: one correction per data source, from all its items but the one in hand", function()
        local L = load().Learn
        local store = { ["300:200"] = { k = 40, d = 8 }, ["301:205"] = { k = 10, d = 1 }, ["bad"] = { k = 5, d = 5 } }
        local function lookup(itemId)
            if itemId == 300 then return 0.5, "ForeverDB" end
            if itemId == 301 then return 0.2, "Wowhead" end
        end
        local bias = L.SourceBias(store, lookup)
        eq(bias, { ForeverDB = { x = 20, d = 8 }, Wowhead = { x = 2, d = 1 } })
        near(L.SourceFactor(bias, "ForeverDB"), 18 / 30, 1e-9, "8 drops where 20 were promised, against a prior worth 10")
        eq(L.SourceFactor(bias, "CMaNGOS"), 1, "a source we have no kills for")
        -- another ForeverDB item, never farmed: its rate is corrected
        local rate, learned = L.DropRate(0.5, store, 999, 1, "ForeverDB", bias)
        near(rate, 0.3, 1e-9)
        eq(learned, true)
        -- the item the evidence came from: its own counts are not used twice
        near(L.DropRate(0.5, store, 300, 200, "ForeverDB", bias), (0.5 * 20 + 8) / 60, 1e-9)
        eq({ L.DropRate(0.4, store, 999, 1, "CMaNGOS", bias) }, { 0.4, false })
        eq({ L.DropRate(nil, store, 999, 1, nil, bias) }, { nil, false }, "no rate, nothing to correct")
        -- at most a factor of two either way, and never over 100%
        local low = L.SourceBias({ ["300:200"] = { k = 1000, d = 0 } }, lookup)
        eq(L.SourceFactor(low, "ForeverDB"), 0.5)
        local high = L.SourceBias({ ["301:205"] = { k = 1000, d = 1000 } }, lookup)
        eq(L.SourceFactor(high, "Wowhead"), 2)
        eq(L.DropRate(0.8, {}, 999, 1, "Wowhead", high), 1)
    end)

    test("step-time model: learns what kinds of step run long, starts at no correction, shrugs off one wild step", function()
        local L = load().Learn
        local talk = L.StepFeatures({ k = "accept", w = "accept", p = 60, pt = 0 })
        local kill = L.StepFeatures({ k = "work", w = "kill", p = 300, pt = 0, g = 1, n = 1, d = 0 })
        local elite = L.StepFeatures({ k = "work", w = "kill", p = 300, pt = 0, g = 1, n = 1, d = 0, e = true })
        eq(talk, { 1, 0, 0, 0, 0, 0, 0, 0, 0 })
        eq(L.StepFeatures({ k = "work", w = "collect", p = 200, pt = 50, g = 2, n = 10, d = 9, e = true }),
            { 0.75, 0, 0.75, 0, 0.25, 0.75, 0.75 * math.log(2), 0.75, 0.75 }, "a quarter travel, three quarters at the stop")
        eq(L.StepFeatures({ k = "accept", w = "accept", p = 100, pt = 100, e = true, g = 3 }), { 0, 0, 0, 0, 1, 0, 0, 0, 0 },
            "all travel; elite and group size describe work only")
        local m = {}
        eq(L.StepFactor(m, elite), 1, "nothing learned: the plan is left alone")
        -- every step takes 10% longer than planned; elite ones another 50% on top
        for _ = 1, 150 do
            L.AddStep(m, talk, 60, 60 * 1.1)
            L.AddStep(m, kill, 300, 300 * 1.1)
            L.AddStep(m, elite, 300, 300 * 1.1 * 1.5)
        end
        eq(m.n, 450)
        near(L.StepFactor(m, talk), 1.1, 0.03)
        near(L.StepFactor(m, kill), 1.1, 0.03)
        near(L.StepFactor(m, elite), 1.65, 0.05)
        local before = L.StepFactor(m, kill)
        L.AddStep(m, kill, 300, 300000)
        ok(L.StepFactor(m, kill) < before * 1.05, "one step left for days hardly moves it")
        -- long stretches without elites do not make the model unsure of everything
        for _ = 1, 3000 do L.AddStep(m, kill, 300, 330) end
        for i = 1, 9 do
            ok(m.R[(i - 1) * 9 + i] >= 1 / L.STEP_DOUBT - 1e-9, "what is known about a weight never fades below the floor")
        end
        near(L.StepFactor(m, elite), 1.65, 0.1, "and what was learned about elites is still there")
        -- a lasting change (new gear) replaces what was learned before
        for _ = 1, 400 do L.AddStep(m, kill, 300, 300 * 0.8) end
        near(L.StepFactor(m, kill), 0.8, 0.03)
        -- the correction is at most a factor of two
        local wild = {}
        for _ = 1, 200 do L.AddStep(wild, kill, 100, 400) end
        eq(L.StepFactor(wild, kill), 2)
        eq({ L.AddStep(m, kill, 0, 10), L.AddStep(m, kill, 10, 0), L.AddStep(m, { 1 }, 10, 10), L.AddStep(nil, kill, 10, 10) },
            { false, false, false, false })
        -- saved by a version with other features: it starts again
        local old = { w = { 1, 2 }, P = { 1 }, n = 7 }
        L.AddStep(old, talk, 60, 60)
        eq({ #old.w, #old.R, old.P, old.n, old.v }, { 9, 81, nil, 1, L.STEP_VERSION })
        local stale = { w = { 1, 1, 1, 1, 1, 1, 1, 1, 1 }, R = m.R, n = 50, v = 1 }
        eq(L.StepFactor(stale, kill), 1, "and is not used until it has")
        -- the three factors the planner uses
        local parts = { w = { math.log(1.2), math.log(1.5), 0, 0, math.log(0.8), math.log(1.25), 0, 0, 0 }, R = m.R, n = 9, v = L.STEP_VERSION }
        near(L.TravelFactor(parts), 0.8, 1e-9)
        near(L.TalkFactor(parts), 1.2, 1e-9)
        near(L.WorkFactor(parts, { w = "kill", g = 1, n = 1 }), 1.2 * 1.5, 1e-9)
        near(L.WorkFactor(parts, { w = "kill", e = true, g = 1, n = 1 }), 2, 1e-9, "1.2 x 1.5 x 1.25, held at 2")
        near(L.WorkFactor(parts, { w = "use" }), 1.2, 1e-9)
    end)

    test("step-time model: the search plans with the corrected times; the tracker fits it against the uncorrected ones", function()
        local ns = load()
        local function model(w)
            local m = { w = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }, R = {}, n = 1, v = ns.Learn.STEP_VERSION }
            for i, v in pairs(w) do m.w[i] = math.log(v) end
            for i = 1, 81 do m.R[i] = 0 end
            return m
        end
        local function plan(m, extra)
            local s = state(extra)
            s.stepModel = m
            return ns.Zones.PlanZone(1, ns.Zones.Context(s))
        end
        local base = plan(nil)
        -- everything half as slow again: the same route, 1.5 times as long
        local slow = plan(model({ [1] = 1.5, [5] = 1.5 }))
        eq(keys(slow), keys(base), "the same route")
        near(slow.seconds, base.seconds * 1.5, 1e-6)
        ok(slow.rate < base.rate)
        local a, b = base.steps[1], slow.steps[1]
        eq({ a.rawSeconds, a.factor }, {}, "no model: nothing added to the step")
        near(b.factor, 1.5, 1e-9)
        near(b.seconds, a.seconds * 1.5, 1e-9)
        near(b.rawTravel + b.rawSeconds, a.travel + a.seconds, 1e-9)
        -- only travel is slower: work and talking keep their times
        local far = plan(model({ [5] = 2 }))
        for i, step in ipairs(far.steps) do
            if keys(far) == keys(base) then
                near(step.travel, base.steps[i].travel * 2, 1e-6)
                near(step.seconds, base.steps[i].seconds, 1e-6)
            end
        end
        -- kills twice as slow: the boar camp (shared by a kill quest and a collect quest) and the
        -- ogre double, whichever quest was put on the camp first; nothing else changes
        local kills = plan(model({ [2] = 2 }))
        local function work(p, key)
            for i, step in ipairs(p.steps) do if p.order[i] == key then return step end end
        end
        near(work(kills, "W:m200").seconds, work(base, "W:m200").seconds * 2, 1e-6)
        eq(work(kills, "W:m200").workAs, "kill")
        eq(work(base, "W:m200").workAs, "kill", "also recorded before anything is learned")
        near(work(kills, "W:m202").seconds, work(base, "W:m202").seconds * 2, 1e-6)
        near(work(kills, "W:o400").seconds, work(base, "W:o400").seconds, 1e-6)
        near(work(kills, "W:m200").rawSeconds, work(base, "W:m200").seconds, 1e-6)
        -- the search itself works with the corrected times: what it finds is worth at least as
        -- much, by those times, as the order it would have chosen without them
        for _, w in ipairs({ { [2] = 2 }, { [3] = 2 }, { [4] = 2 }, { [5] = 2 }, { [5] = 0.5 }, { [1] = 2, [9] = 2 } }) do
            local m = model(w)
            local found = plan(m)
            local s = state()
            s.stepModel = m
            local kept = ns.Zones.PlanZone(1, ns.Zones.Context(s), base.order)
            -- the uncorrected order, as it stands by the corrected times: Far Giver (quest 8, a trip
            -- to another map) is weighed like any other quest and may be left out as slow
            local function home(p) return (keys(p):gsub(" [PT]:8%f[%D]", "")) end
            eq(home(kept), home(base))
            ok(found.score >= kept.score * (1 - ns.Planner.SCORE_GIVE) - 1e-6, "not worse than the uncorrected order")
        end
        -- a model that has seen nothing is not used at all
        local unused = model({ [2] = 2 })
        unused.n = 0
        near(plan(unused).seconds, base.seconds, 1e-9)
        -- the tracker logs the uncorrected time and teaches the model
        local steps, fresh = {}, {}
        ns.Tracker.Start({}, {}, steps, fresh)
        local id = tonumber(slow.order[1]:match("^P:(%d+)$"))
        ok(id, "the route starts with an accept")
        ns.Tracker.OnPlan(slow, { now = 0, level = 8, log = {} })
        ns.Tracker.OnPlan(nil, { now = 90, level = 8, log = { { id = id, objectives = {} } } })
        eq(steps[1].p, math.floor(a.travel + a.seconds + 0.5))
        eq(fresh.n, 1)
        ok(ns.Learn.StepFactor(fresh, ns.Learn.StepFeatures(steps[1])) ~= 1)
        H.contains(table.concat(ns.Tracker.Describe(), "\n"), "step-time model (1 steps): any stop x")
        ns.Tracker.Reset()
        eq(fresh, {})
    end)

    test("travel speed: starts at the typical run speed, moves slowly towards our own, within limits", function()
        local L = load().Learn
        local store = {}
        eq(L.SpeedFactor(store), 1, "nothing learned")
        -- one sample of a fast mount hardly moves it: the typical speed counts as twelve samples
        L.AddSpeed(store, 2)
        near(L.SpeedFactor(store), 2 ^ (1 / 13), 1e-9)
        ok(L.SpeedFactor(store) < 1.06)
        for _ = 1, 500 do L.AddSpeed(store, 1.6) end
        near(L.SpeedFactor(store), 1.6 ^ (60 / 72), 1e-3, "sixty samples remembered, against a prior worth twelve")
        eq(store.r.n, 60)
        -- one wild sample counts as 2.5 times faster or slower at most
        local a, b, c = {}, {}, {}
        L.AddSpeed(a, 1000); L.AddSpeed(b, 2.5); L.AddSpeed(c, 0.001)
        eq(a.r.m, b.r.m)
        near(c.r.m, -b.r.m, 1e-12)
        eq({ L.AddSpeed(store, 0), L.AddSpeed(store, -1), L.AddSpeed(store, 0 / 0), L.AddSpeed(store, "2"), L.AddSpeed(nil, 2) },
            { false, false, false, false, false }, "bad numbers are refused")
        -- a damaged saved value cannot push the speed past the limits
        near(L.SpeedFactor({ r = { n = 1e9, m = 50 } }), 2.5 ^ (60 / 72), 1e-9)
        eq(L.SpeedFactor({ r = { n = 5, m = 0 / 0 } }), 1)
        near(L.PaceFactor({ c = { n = 20, m = 50 } }, "c"), 4 ^ (20 / 23), 1e-9, "the same for the other paces")
        -- the planner's pace: only the speed changes, and it is not one of the per-task paces
        local pace = L.Pace({ c = 30, i = 20, o = 15, x = 60, r = 7 }, { r = { n = 60, m = math.log(1.6) } })
        near(pace.r, 7 * 1.6 ^ (60 / 72), 1e-9)
        eq({ pace.c, pace.i, pace.o, pace.x }, { 30, 20, 15, 60 })
        eq(L.AddPace(store, "r", 2), false, "the speed has its own limits: it is not fed through AddPace")
    end)

    test("tracker: ten seconds of steady travel are one speed sample; flights, fights, jumps and mounting up are not", function()
        local ns = load()
        ns.Geo.Init(ns.data.world)
        local pace = {}
        ns.Tracker.Start(pace, {}, {}, {})
        local T = ns.Tracker
        local t, x = 0, 10
        -- one second on, `yards` further east or back west (1 map unit = 10 yards)
        local dir = 1
        local function hop(yards, extra)
            if x > 80 then dir = -1 elseif x < 20 then dir = 1 end
            t, x = t + 1, x + dir * yards / 10
            local info = { now = t, level = 8, loc = ns.Geo.Loc(1, x, 50), mounted = false }
            for k, v in pairs(extra or {}) do info[k] = v end
            return T.OnMove(info)
        end
        local function run(seconds, yards, extra)
            local got
            for _ = 1, seconds do got = hop(yards, extra) or got end
            return got
        end
        eq(run(10, 8), nil, "the first position only starts the stretch: nine hops so far")
        near(hop(8), 8, 1e-6, "ten hops of 8 yards in ten seconds")
        eq(pace.r.n, 1)
        near(pace.r.m, math.log(8 / 7), 1e-6, "against the typical 7 yards per second")
        -- standing still in the middle: the stretch starts again
        pace.r = nil
        run(6, 8); hop(0); eq(run(9, 8), nil)
        eq(pace.r, nil)
        near(hop(8), 8, 1e-6)
        -- a flight: reported by the client, or not reported and simply too fast
        pace.r = nil
        eq(run(30, 8, { blocked = true }), nil, "on a flight path, in combat, dead, swimming")
        eq(run(30, 30), nil, "30 yards per second is no mount")
        eq(pace.r, nil)
        -- a jump in position (hearthstone), another continent, no position, a long gap in time
        -- (each case: 8 seconds of travel, the break, 9 more hops; a pause in between)
        x = 20
        hop(0); run(8, 8); x = x + 30; eq(run(9, 8), nil)
        hop(0); run(8, 8)
        t = t + 1
        T.OnMove({ now = t, level = 8, loc = ns.Geo.Loc(3, 50, 50), mounted = false })
        eq(run(10, 8), nil)
        hop(0); run(8, 8); t = t + 1; T.OnMove({ now = t, level = 8 }); eq(run(10, 8), nil)
        hop(0); run(8, 8); t = t + 60; eq(run(10, 8), nil)
        eq(pace.r, nil)
        -- mounting up in the middle: the two speeds are not mixed into one sample; the speed on a
        -- mount is learned apart from the speed on foot, against the typical speed on a mount
        hop(0); run(8, 8)
        eq(run(10, 11, { mounted = true }), nil)
        near(hop(11, { mounted = true }), 11, 1e-6)
        eq(pace.r, nil, "nothing learned on foot")
        local ride = ((ns.Data.World().travel or {}).speeds or {}).ride or ns.Learn.RIDE_TYPICAL
        eq(pace.rm.n, 1)
        near(pace.rm.m, math.log(11 / ride), 1e-6)
        -- what was learned reaches the planner: walking takes less time
        for _ = 1, 700 do hop(11) end
        local s = state()
        local slow = ns.Zones.Context(s).travel
        s.pace = pace
        local fast = ns.Zones.Context(s).travel
        local a, b = ns.Geo.Loc(1, 10, 50), ns.Geo.Loc(1, 90, 50)
        near(fast:Seconds(a, b), slow:Seconds(a, b) / ns.Learn.SpeedFactor(pace), 1e-6)
        ok(ns.Learn.SpeedFactor(pace) > 1.4 and ns.Learn.SpeedFactor(pace) < 11 / 7)
        s.speed = 7
        near(ns.Zones.Context(s).travel:Seconds(a, b), slow:Seconds(a, b), 1e-6, "a speed given outright wins")
        local text = table.concat(T.Describe(8), "\n")
        H.contains(text, "travel speed: 1")
        H.contains(text, "yards per second (60 samples)")
        H.contains(text, "speed on a mount: not seen riding yet")
        -- seen riding (three samples on a mount): a long walk is ridden
        s.speed = nil
        for _ = 1, 30 do hop(11, { mounted = true }) end
        eq(pace.rm.n, 3)
        ok(ns.Zones.Context(s).travel:Seconds(a, b) < fast:Seconds(a, b), "ridden")
        H.contains(table.concat(T.Describe(8), "\n"), "yards per second (3 samples); long walks are ridden")
        T.Reset()
        eq(pace, {})
        H.contains(table.concat(T.Describe(), "\n"), "travel speed: the typical run speed (no samples yet)")
    end)

    test("an itinerary's later zones are planned with everything learned, and trips between zones use the travel factor", function()
        local ns = load()
        local s = state()
        s.pace = { c = { n = 20, m = math.log(2) }, r = { n = 60, m = math.log(1.5) } }
        s.drops = { ["300:200"] = { k = 40, d = 8 } }
        s.stepModel = { v = ns.Learn.STEP_VERSION, n = 5, w = { 0, 0, 0, 0, math.log(1.5), 0, 0, 0, 0 } }
        local ctx = ns.Zones.Context(s)
        local plan = ns.Zones.PlanZone(1, ctx)
        ok(#plan.steps > 2)
        local after = ns.Zones.Project(s, ctx, plan, 2)
        ok(after.pace == s.pace and after.drops == s.drops and after.stepModel == s.stepModel,
            "the projected character has learned the same")
        local ctx2 = ns.Zones.Context(after)
        near(ctx2.pace.c, ctx.pace.c, 1e-9)
        near(ctx2.pace.r, 7 * ns.Learn.SpeedFactor(s.pace), 1e-9)
        eq(ctx2.dropBias, ctx.dropBias)
        ok(ctx2.stepModel == s.stepModel)
        -- the level-aware kill time (Model.KillAt) starts from the learned pace, as the task itself does
        local m = ns.Model.Build(1, ctx)
        local kill
        for _, t in ipairs(m and m.tasks or {}) do if t.paceC then kill = t end end
        ok(kill, "quest 1 has a kill task")
        near(kill.paceC, ctx.pace.c, 1e-9)
        near(kill.paceC, 30 * ns.Learn.PaceFactor(s.pace, "c"), 1e-9)
        near((ns.Model.KillAt(kill, kill.lv)), kill.cycle, 1e-9)
    end)
end)
