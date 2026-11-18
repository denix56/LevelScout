-- tests/test_game_4.lua: the engine and the window on the real data, part 4 of 4 (see test_game.lua):
-- the move-on banner, planning progress, instances, map pins, flight points, learning, the way to a step.
local H, M = ...
local test, eq, ok, contains, near = H.test, H.eq, H.ok, H.contains, H.near

local E = require("game_env")(H, M)
local SECRET, installGame, slash, output, start = E.SECRET, E.installGame, E.slash, E.output, E.start

H.suite("Engine and window (real data)", function()
    test("the move-on banner follows the itinerary and says over which time", function()
        local ns = start()
        local view = ns.Engine.view
        -- the engine hands the itinerary to the move-on rule: they never name different zones
        local it = view.itinerary
        ok(it and it.shown == view.zone, "the itinerary is made for the shown zone")
        eq(it.segments[1].map, view.zone, "and starts in it")
        if it.alt then
            eq(view.moveOn.map, it.alt.map, "the banner is about the better start")
        elseif it.segments[1].map == view.zone then
            eq(view.moveOn.suggest, false, "the itinerary starts here: no banner")
        else
            eq(view.moveOn.map, it.segments[1].map)
        end
        local banner = LevelScoutFrame.banner
        view.moveOn = { suggest = true, map = -1, name = "Elsewhere", gain = 0.25, horizon = 7200 }
        ns.UI.Refresh()
        ok(banner:IsShown())
        eq(banner.label.text, "Elsewhere: 25% more XP over the next 2 hours")
        view.moveOn = { suggest = true, map = -1, name = "Elsewhere", gain = 0.25 }
        ns.UI.Refresh()
        eq(banner.label.text, "Elsewhere: 25% more XP over the next hour", "without an itinerary: the one-hour rule")
        view.moveOn = { suggest = true, map = -1, name = "Elsewhere", horizon = 7200 }
        ns.UI.Refresh()
        eq(banner.label.text, "Done here. Next: Elsewhere")
        view.moveOn = { suggest = false }
        ns.UI.Refresh()
        ok(not banner:IsShown())
    end)

    test("the zones and the route are shown before the next two hours are worked out", function()
        local ns = start()
        local view = ns.Engine.view
        local before = view.ranked
        local realClock = debugprofilestop
        M.set("debugprofilestop", function() M.clock = M.clock + 1; return M.clock end)
        ns.Engine.Replan(true)
        local early
        for _ = 1, 200000 do
            if #M.timers > 0 then
                local fns = M.timers
                M.timers = {}
                for _, fn in ipairs(fns) do fn() end
            end
            local f = M.asyncFrame()
            if not f and #M.timers == 0 then break end
            if f then f.scripts.OnUpdate(f, 0.02) end
            if not early and view.ranked ~= before and ns.Async.IsRunning("itinerary") then
                early = { busy = view.busy, status = view.status, fraction = view.progress and view.progress.fraction,
                    text = view.progress and view.progress.text }
            end
        end
        ok(early, "a new ranking was shown while the itinerary was still being worked out")
        eq(early.status, "ready")
        ok(early.busy, "still busy: the bar stays")
        ok(early.fraction and early.fraction >= ns.Engine.SHARE_RANK, "the bar is past the ranking")
        ok(not view.busy and view.itinerary, "then the itinerary arrives and planning ends")
        -- a new plan job stops the itinerary, which is worked out again after it from the new result
        ns.Engine.Replan(true)
        for _ = 1, 200000 do
            if #M.timers > 0 then
                local fns = M.timers
                M.timers = {}
                for _, fn in ipairs(fns) do fn() end
            end
            local f = M.asyncFrame()
            if f then f.scripts.OnUpdate(f, 0.02) end
            if ns.Async.IsRunning("itinerary") then break end
        end
        ok(ns.Async.IsRunning("itinerary"), "the itinerary job runs")
        -- the rest at the usual speed: the slow clock above makes the jobs take very many frames
        M.set("debugprofilestop", realClock)
        ns.Engine.Replan()
        ok(M.settle(), "planning settles")
        ok(not ns.Async.IsRunning("itinerary") and not view.busy and view.itinerary, "worked out again, for the newest plan: running "
            .. tostring(ns.Async.IsRunning("itinerary")) .. " busy " .. tostring(view.busy) .. " itinerary " .. tostring(view.itinerary)
            .. " printed " .. tostring(M.printed[#M.printed]))
    end)

    test("planning shows its progress: a bar and what the planner is doing", function()
        local ns = start()
        local view, frame = ns.Engine.view, LevelScoutFrame
        ok(not view.progress and not frame.progress:IsShown(), "nothing while idle")
        local function result()
            local parts = { table.concat(view.plan.order, " ") }
            for _, z in ipairs(view.ranked) do parts[#parts + 1] = z.map .. "=" .. z.plan.score .. ":" .. table.concat(z.plan.order, " ") end
            local it = view.itinerary
            parts[#parts + 1] = it and (it.xp .. "/" .. #it.segments .. "/" .. tostring(it.here)) or "no itinerary"
            return table.concat(parts, "\n")
        end
        -- time passes while the planner works, so the job spreads over many frames
        M.set("debugprofilestop", function() M.clock = M.clock + 1; return M.clock end)
        local notices = {}
        ns.Engine.OnProgress(function(v)
            notices[#notices + 1] = { at = GetTime(), fraction = v.progress.fraction }
            eq(frame.status.text, v.progress.text .. "...", "the footer says what the planner is doing")
            eq(frame.progress.fraction, v.progress.fraction, "the bar follows")
        end)
        local function replan(watch)
            ns.Engine.Replan(true)
            local frames, last, texts = 0, 0, {}
            for _ = 1, 200000 do
                if #M.timers > 0 then
                    local fns = M.timers
                    M.timers = {}
                    for _, fn in ipairs(fns) do fn() end
                end
                local f = M.asyncFrame()
                if not f and #M.timers == 0 then break end
                if f then
                    f.scripts.OnUpdate(f, 0.02)
                    if view.busy then frames = frames + 1; watch(view.progress, last, texts) end
                    last = view.progress and view.progress.fraction or last
                end
            end
            return frames, last, texts
        end
        local bad
        local frames, last, texts = replan(function(p, before, seen)
            if not (p and p.fraction >= before and p.fraction >= 0 and p.fraction <= 1 and type(p.text) == "string" and p.text ~= "") then
                bad = bad or ("progress " .. tostring(p and p.fraction) .. " after " .. before)
            end
            if p then seen[p.text] = true end
            if not frame.progress:IsShown() then bad = bad or "the bar is hidden while planning" end
        end)
        ok(not bad, tostring(bad))
        ok(frames > 20, "the job ran over many frames: " .. frames)
        ok(last > 0.7, "the bar got most of the way: " .. last)
        local phases = 0
        for text in pairs(texts) do
            if text:find("^Ranking zones: Map %-?%d+ %(%d+ of %d+%)$") or text:find("^Searching for a better route: round %d+ of %d+$")
                or text == "Putting stops in their best order" or text == "Checking the shown route" or text == "Planning the next hours" then
                phases = phases + 1
            else
                ok(text == "Planning" or text == "Ranking zones", "an unexpected text: " .. text)
            end
        end
        ok(phases >= 3, "several phases are named: " .. phases)
        -- the window is told a few times per second at most, not on every step
        ok(#notices >= 2 and #notices < frames, #notices .. " notices in " .. frames .. " frames")
        for i = 2, #notices do
            ok(notices[i].at - notices[i - 1].at >= ns.Engine.PROGRESS_EVERY - 1e-9, "notices are spaced out")
            ok(notices[i].fraction >= notices[i - 1].fraction, "never backwards")
        end
        -- settled: cleared and hidden
        ok(not view.busy and view.progress == nil, "cleared when planning has settled")
        ok(not frame.progress:IsShown(), "the bar is hidden")
        ok(not frame.status.text:find("...", 1, true), "the footer is back to normal: " .. frame.status.text)
        -- the callback only listens: the same plans without it
        local with = result()
        ns.Engine.PROGRESS = false
        local count = #notices
        replan(function(p) if p then bad = "progress although switched off" end end)
        ok(not bad, tostring(bad))
        eq(#notices, count, "no notices")
        eq(result(), with, "the same ranking, route and itinerary")
        ns.Engine.PROGRESS = true
        -- collapsed: the bar sits at the window's bottom edge, without text
        view.busy, view.progress = true, { fraction = 0.5, text = "Ranking zones" }
        ns.UI.Refresh()
        local _, _, open = frame.progress:GetPoint(1)
        LevelScoutDB.window.collapsed = true
        ns.UI.Refresh()
        local _, _, shut = frame.progress:GetPoint(1)
        ok(frame.progress:IsShown() and shut < open, "collapsed: at the bottom edge")
        eq(frame.progress.fraction, 0.5)
        view.busy, view.progress = false, nil
        ns.UI.Refresh()
        ok(not frame.progress:IsShown())
        -- a failed job clears it too
        LevelScoutDB.window.collapsed = false
        local rank = ns.Zones.Rank
        ns.Zones.Rank = function() error("boom") end
        ns.Engine.Replan(true)
        ok(M.settle())
        ns.Zones.Rank = rank
        eq(view.status, "error")
        ok(view.progress == nil and not frame.progress:IsShown(), "cleared after an error")
    end)

    test("collapse, hide and /ls, options menu", function()
        local ns = start()
        LevelScoutDB.window.collapsed = true
        ns.UI.Refresh()
        local shown = 0
        for _, r in ipairs(ns.UI.rows) do if r:IsShown() then shown = shown + 1 end end
        eq(shown, 1, "collapsed: only the current step")
        ok(not LevelScoutFrame.tabs:IsShown())
        slash("")
        ok(not LevelScoutFrame:IsShown())
        eq(LevelScoutDB.window.hidden, true)
        slash("")
        ok(LevelScoutFrame:IsShown())
        slash("plan")
        contains(output(), "XP/h")
        slash("status")
        contains(output(), "planner: ready")
    end)

    test("inside an instance the planner pauses and the waypoint is removed", function()
        local ns = start({ inInstance = true })
        eq(ns.Engine.view.status, "paused")
        contains(ns.Engine.view.message, "instance")
        eq(ns.Guide.mode, "none")
        contains(LevelScoutFrame.empty.text, "instance", "no route planned yet: nothing but the message")
    end)

    test("entering an instance keeps the route on screen, with the quest log's progress", function()
        local over = {}
        local ns = start(over)
        local view = ns.Engine.view
        local plan = view.plan
        ok(plan and #plan.steps > 0)
        -- a step working the kobolds (quest 7, 3/10 in the log)
        local part
        for _, s in ipairs(plan.steps) do
            for _, p in ipairs(s.parts or {}) do if p.quest == 7 then part = p end end
        end
        -- in we go
        over.inInstance = true
        M.set("IsInInstance", function() return true end)
        ns.Engine.Replan()
        ok(M.settle())
        eq(view.status, "paused")
        ok(view.plan == plan, "the route is kept")
        eq(ns.Guide.mode, "none", "no waypoint inside")
        ok(ns.UI.state.models[1] and (ns.UI.state.models[1].step or ns.UI.state.models[1].section), "the rows are drawn")
        contains(LevelScoutFrame.summaryText.text, "the route goes on outside")
        ok(not LevelScoutFrame.empty:IsShown(), "not the empty message")
        if part then eq({ part.have, part.total }, { 3, 10 }, "progress from the log") end
        -- the dungeon step lists its quests' progress, a line each
        local Format = ns.Format
        local run = { kind = "work", action = "run", target = "Gnomeregan", quests = { { id = 7, name = "Kobold Camp Cleanup" }, { id = 33, name = "Wolves Across the Border" }, { id = 5, name = "Elsewhere" } },
            parts = {}, travel = 0, seconds = 1800 }
        plan.steps[#plan.steps + 1] = run
        ns.Engine.Replan()
        ok(M.settle())
        local detail, lines = Format.StepDetail(run)
        eq(lines, 4)
        contains(detail, "Kobold Camp Cleanup: 3/10")
        contains(detail, "Wolves Across the Border: |cff59ff59done|r")
        contains(detail, "Elsewhere: not in the log")
        -- out again: planned as usual
        M.set("IsInInstance", function() return false end)
        over.inInstance = false
        ns.Engine.Replan(true)
        ok(M.settle())
        eq(view.status, "ready")
        ok(view.plan ~= plan, "a new plan outside")
    end)

    test("without TomTom the game's map pin is used, and only our pin is cleared", function()
        local pin, cleared
        local function withMapPin()
            C_Map.CanSetUserWaypointOnMap = function() return true end
            C_Map.SetUserWaypoint = function(p) pin = p end
            C_Map.GetUserWaypoint = function() return pin end
            C_Map.ClearUserWaypoint = function() cleared = true; pin = nil end
            M.set("UiMapPoint", { CreateFromCoordinates = function(map, x, y) return { uiMapID = map, position = { x = x, y = y } } end })
        end
        local ns = installGame()
        E.noSearch(ns)
        M.set("TomTom", nil)
        M.set("LevelScoutDB", nil)
        M.set("LevelScoutCharDB", nil)
        withMapPin()
        M.login()
        ok(M.settle())
        eq(ns.Guide.mode, "map")
        ok(pin and pin.uiMapID == 1429)
        pin = { uiMapID = 1429, position = { x = 0.99, y = 0.99 } } -- the player moved the pin
        ns.Guide.Clear()
        ok(not cleared, "a pin the player placed is left alone")
    end)

    test("discovering a flight point records the one we stand at; elsewhere the window asks for the flight map", function()
        local output = function() return table.concat(M.printed, "\n") end
        -- Goldshire has no flight master: nothing is close, so a reminder is shown
        local ns = start()
        M.set("ERR_NEWTAXIPATH", "New flight path discovered!")
        ok(not ns.Engine.view.flightsKnown)
        M.fire("UI_INFO_MESSAGE", 1, "New flight path discovered!")
        eq(LevelScoutCharDB.knownNodes, {})
        contains(ns.Engine.view.flightNote, "Open the flight map")
        LevelScoutFrame.tabButtons[2].scripts.OnClick(LevelScoutFrame.tabButtons[2], "LeftButton")
        eq(ns.UI.rows[1].model.title, "New flight point")
        M.fire("UI_INFO_MESSAGE", 1, "Some other message")
        -- standing at the Sentinel Hill flight master (Westfall 56.6, 52.7): recorded at once
        local ns2 = start({ mapId = 1436, x = 0.566 })
        M.set("ERR_NEWTAXIPATH", "New flight path discovered!")
        C_Map.GetPlayerMapPosition = function() return { x = 0.566, y = 0.527 } end
        M.fire("UI_INFO_MESSAGE", 1, "New flight path discovered!")
        eq(LevelScoutCharDB.knownNodes, { [4] = true })
        contains(output(), "Learned flight point: Sentinel Hill")
        ok(M.settle())
        ok(ns2.Engine.view.flightsKnown)
        eq(ns2.Engine.view.flightNote, nil)
    end)

    test("the flight map teaches known flight paths", function()
        local ns = start()
        C_TaxiMap = { GetAllTaxiNodes = function() return { { nodeID = 2, state = 0 }, { nodeID = 4, state = 1 }, { nodeID = 5, state = 2 } } end }
        M.fire("TAXIMAP_OPENED")
        eq(LevelScoutCharDB.knownNodes, { [2] = true, [4] = true })
        ok(M.settle())
        C_TaxiMap = nil
        eq(ns.Engine.view.status, "ready")
    end)

    test("learning: kill events and quest progress are recorded, saved and shown by /ls learn", function()
        local ns = start()
        eq(ns.Game.NpcFromGUID("Creature-0-4444-0-12-6-0000ABCDEF"), 6)
        eq({ ns.Game.NpcFromGUID("Player-4444-00ABCDEF"), ns.Game.NpcFromGUID(SECRET), ns.Game.NpcFromGUID(nil) }, {})
        eq(LevelScoutCharDB.pace, {})
        eq(LevelScoutDB.drops, {})
        local done = 3
        C_QuestLog.GetQuestObjectives = function(id)
            if id == 7 then
                return { { text = "Kobold Vermin slain", type = "monster", finished = false, numFulfilled = done, numRequired = 10 } }
            end
            return { { text = "Tough Wolf Meat: 8/8", type = "item", finished = true, numFulfilled = 8, numRequired = 8 } }
        end
        M.fire("QUEST_LOG_UPDATE")
        for _ = 1, 3 do
            M.clock = M.clock + 12000
            M.fire("PARTY_KILL", SECRET, "Creature-0-4444-0-12-6-0000ABCDEF")
            M.fire("PARTY_KILL", SECRET, SECRET)
            done = done + 1
            M.fire("QUEST_LOG_UPDATE")
        end
        eq(LevelScoutCharDB.pace.c.n, 2, "three kills: two times between them")
        ok(M.settle())
        eq(ns.Engine.view.status, "ready", "the plan is made with the learned pace")
        M.printed = {}
        SlashCmdList.LEVELSCOUT("learn")
        contains(output(), "time per kill:")
        contains(output(), "(2 samples)")
        contains(output(), "plan accuracy: no finished steps timed yet")
        -- the step log: accepting the quest of the first step writes a line
        eq(LevelScoutCharDB.steps, {})
        local id = tonumber(ns.Engine.view.plan.order[1]:match("^P:(%d+)$"))
        ok(id, "the route starts by accepting a quest")
        local count, info = C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo
        C_QuestLog.GetNumQuestLogEntries = function() return count() + 1 end
        C_QuestLog.GetInfo = function(i) return info(i) or { title = "Accepted", questID = id, level = 5 } end
        M.clock = M.clock + 30000
        M.fire("QUEST_ACCEPTED", id)
        ok(M.settle())
        eq(#LevelScoutCharDB.steps, 1)
        local line = LevelScoutCharDB.steps[1]
        eq({ line.k, line.lv, line.g }, { "accept", 12, 1 })
        ok(line.a >= 66 and line.a < 70 and line.p > 0, "66 seconds since it became the first step (36 of kobolds, 30 more), next to the planned time")
        M.printed = {}
        SlashCmdList.LEVELSCOUT("learn")
        contains(output(), "plan accuracy: 1 steps took")
        SlashCmdList.LEVELSCOUT("learn reset")
        eq(LevelScoutCharDB.pace, {})
        eq(LevelScoutCharDB.steps, {})
    end)

    test("learning: the travel speed is measured from the player's position, on the ground and out of combat only", function()
        local ns = start()
        local x = 0.42
        C_Map.GetPlayerMapPosition = function() return { x = x, y = 0.65 } end
        local here = ns.Geo.Loc(1429, 42, 65)
        local step = 9 / ns.Geo.Dist(here, ns.Geo.Loc(1429, 43, 65)) / 100 -- 9 yards, in map units
        local function travel(seconds)
            local got
            for _ = 1, seconds do
                M.clock = M.clock + 1000
                x = x + step
                got = ns.Engine.TrackMove() or got
            end
            return got
        end
        eq(ns.Game.GetMovement(), { blocked = false }, "a client without these checks: nothing blocks, mounted unknown")
        near(travel(11), 9, 0.01, "eleven positions a second apart, 9 yards each")
        eq(LevelScoutCharDB.pace.r.n, 1)
        -- on a flight path, in combat, dead, swimming: nothing is learned
        for _, name in ipairs({ "UnitOnTaxi", "UnitAffectingCombat", "UnitIsDeadOrGhost", "IsSwimming", "IsFlying", "IsFalling", "UnitInVehicle" }) do
            M.set(name, function() return true end)
            eq(ns.Game.GetMovement().blocked, true, name)
            eq(travel(25), nil, name)
            M.set(name, function() return false end)
        end
        M.set("InCombatLockdown", function() return true end)
        eq(travel(25), nil, "in combat")
        M.set("InCombatLockdown", function() return false end)
        eq(LevelScoutCharDB.pace.r.n, 1)
        -- mounting up starts a new stretch
        M.set("IsMounted", function() return false end)
        travel(6)
        M.set("IsMounted", function() return true end)
        eq(ns.Game.GetMovement().mounted, true)
        eq(travel(10), nil)
        near(travel(1), 9, 0.01)
        eq({ LevelScoutCharDB.pace.r.n, LevelScoutCharDB.pace.rm.n }, { 1, 1 },
            "on a mount the speed is learned apart from the speed on foot")
        -- the frame's timer asks once a second
        local frame
        for _, f in ipairs(M.frames) do
            if f.events and f.events.QUEST_LOG_UPDATE and f.scripts.OnUpdate then frame = f end
        end
        ok(frame, "the engine's listener")
        local calls, track = 0, ns.Engine.TrackMove
        ns.Engine.TrackMove = function() calls = calls + 1 end
        for _ = 1, 25 do frame.scripts.OnUpdate(frame, 0.1) end
        eq(calls, 2)
        ns.Engine.TrackMove = track
        M.printed = {}
        SlashCmdList.LEVELSCOUT("learn")
        contains(output(), "travel speed: 10")
        contains(output(), "yards per second (1 samples)")
        contains(output(), "speed on a mount: not seen riding yet")
        SlashCmdList.LEVELSCOUT("learn reset")
        eq(LevelScoutCharDB.pace, {})
        contains(output(), "forgot the learned pace, travel speed, drop rates, step log and step-time model")
    end)

    test("flight points off an open flight map: planned with at once, and the way flies at once", function()
        local ns, travel = E.wayfinding()
        local view = ns.Engine.view
        local step = { kind = "turnin", action = "turnin", loc = ns.Geo.Loc(1436, 56, 52), quests = { { id = 1, name = "Test" } }, travel = 0, seconds = 8 }
        -- the Guide: a new way for the same step settles first, unless the plan is fresh
        local walking = ns.Travel.New(ns.Data.World(), { speed = 7, side = "a", knownNodes = {} })
        ns.Guide.Follow(step, "Turn in: Test", walking)
        eq(ns.Guide.Trip().first, nil, "no flight point known: walked")
        ns.Guide.Follow(step, "Turn in: Test", travel)
        eq(ns.Guide.Trip().first, nil, "another plan for the same step: its way settles first")
        ns.Guide.Follow(step, "Turn in: Test", travel, false, true)
        eq(ns.Guide.Trip().first and ns.Guide.Trip().first.kind, "fly", "a fresh plan's way is taken at once")
        -- the engine: the map's list fills a moment after it opens; read again, planned with at once
        local calls = 0
        C_TaxiMap = { GetAllTaxiNodes = function()
            calls = calls + 1
            if calls == 1 then return {} end
            return { { nodeID = 2, state = 0 }, { nodeID = 4, state = 1 }, { nodeID = 5, state = 2 } }
        end }
        -- the zones were ranked a minute ago: the plan made at once is still the shown route only,
        -- on screen before the zones are ranked again
        M.clock = M.clock + 60000
        local knownWhenRanked
        local rank = ns.Zones.Rank
        ns.Zones.Rank = function(...)
            if knownWhenRanked == nil then knownWhenRanked = view.flightsKnown == true end
            return rank(...)
        end
        M.fire("TAXIMAP_OPENED")
        eq(LevelScoutCharDB.knownNodes, {}, "nothing listed yet")
        ok(not ns.Async.IsRunning("plan"))
        table.remove(M.timers, 1)() -- the next look, a moment later (the map is still open)
        eq(LevelScoutCharDB.knownNodes, { [2] = true, [4] = true })
        ok(ns.Async.IsRunning("plan"), "planned at once: no wait")
        ok(M.settle())
        ok(view.flightsKnown)
        eq(knownWhenRanked, true, "the route with the flight points was shown before the zones were ranked")
        ns.Zones.Rank = rank
        eq(view.status, "ready")
        -- closed: no more looks
        M.fire("TAXIMAP_CLOSED")
        local before = calls
        ok(M.settle())
        eq(calls, before, "nothing is read after the map has closed")
        C_TaxiMap = nil
    end)

    test("a current step that needs a flight: the waypoint goes to the flight master, the row and the tooltip say where to fly", function()
        local ns, travel, shown, current, stand = E.wayfinding()
        local step = { kind = "turnin", action = "turnin", loc = ns.Geo.Loc(1436, 56, 52), quests = { { id = 1, name = "Test" } }, travel = 0, seconds = 8 }
        ns.Guide.Follow(step, "Turn in: Test", travel)
        local trip = ns.Guide.Trip()
        eq(trip.zone, "Westfall")
        eq({ trip.first.kind, trip.first.from.name, trip.first.to.name, trip.first.from.zone }, { "fly", "Stormwind", "Sentinel Hill", "Stormwind City" })
        near(trip.seconds, (travel:Seconds(ns.Geo.Loc(1429, 42, 65), step.loc)), 1e-6, "the same time the planner counts")
        -- the waypoint: the flight master in Stormwind, with both ends in its title
        local node = ns.Data.World().travel.nodes[2]
        local at = shown[#shown]
        eq({ at.map, at.title }, { node[4], "Flight master: Stormwind, fly to Sentinel Hill" })
        near(at.x, node[5] / 100, 1e-9)
        near(at.y, node[6] / 100, 1e-9)
        -- the window: a line of its own on the current row
        ns.UI.Refresh()
        local row = current()
        local line = row.model.detail:match("^[^\n]*")
        contains(line, "In Westfall")
        contains(line, "fly Stormwind to Sentinel Hill")
        contains(line, ns.Format.Duration(trip.seconds))
        eq(row.model.trip, ns.Format.TripText(trip))
        contains(row.detail.text, "fly Stormwind to Sentinel Hill")
        local base = select(2, ns.Format.StepDetail(row.model.step))
        ok(row.model.lines > base, "the row is taller by the line")
        local tip = {}
        for _, l in ipairs(row.model.tip()) do tip[#tip + 1] = l[1] .. (l.right and (" = " .. l.right) or "") end
        tip = table.concat(tip, "\n")
        contains(tip, "From where you are = " .. ns.Format.Duration(trip.seconds))
        contains(tip, "Walk to the flight master in Stormwind (Stormwind City) = ")
        contains(tip, "Fly Stormwind to Sentinel Hill = ")
        contains(tip, "Walk to the step = ")
        -- walking towards the flight master changes the time, not the waypoint
        local n = #shown
        stand(1429, 0.38, 0.56)
        ns.Guide.Tick(); ns.Guide.Tick(); ns.Guide.Tick()
        eq(#shown, n, "the same target: the waypoint is not set again")
        ok(ns.Guide.Trip().seconds < trip.seconds)
        -- the flight begins: the flight master is behind us, the waypoint goes to the step itself
        M.set("UnitOnTaxi", function() return true end)
        ns.Guide.Tick()
        eq(#shown, n + 1, "moved as soon as we are in the air")
        at = shown[#shown]
        eq({ at.map, at.title }, { 1436, "Turn in: Test" })
        near(at.x, 0.56, 1e-9)
        -- in the air nothing is worked out, and the waypoint stays on the step
        stand(1436, 0.50, 0.40)
        for _ = 1, 5 do ns.Guide.Tick() end
        eq(#shown, n + 1)
        eq(ns.Guide.Trip().first.kind, "fly")
        -- a new plan for the same step, published in mid-air, does not send us back to a flight master
        ns.Guide.Follow(step, "Turn in: Test", travel)
        eq(shown[#shown].title, "Turn in: Test")
        M.set("UnitOnTaxi", function() return false end)
        -- landed at Sentinel Hill: the way from here is taken at once, and it is a walk
        stand(1436, 0.566, 0.527)
        ns.Guide.Tick()
        eq(shown[#shown].title, "Turn in: Test")
        eq(ns.Guide.Trip().first, nil, "no flight left")
        n = #shown - 1
        eq(ns.Format.TripText(ns.Guide.Trip()), nil, "in the step's zone, on foot: nothing to say")
        ns.UI.Tick()
        row = current()
        eq(row.model.trip, nil)
        eq(row.model.lines, base, "the line is gone and the row is its usual height")
        ok(not row.model.detail:find("In Westfall", 1, true))
        ns.Guide.Tick(); ns.Guide.Tick()
        eq(#shown, n + 1)
        -- a click in the window points the arrow by hand: it stays on that step until the next
        -- plan, and the way to it is worked out too. From Sentinel Hill a giver in Elwynn is a
        -- flight away: the waypoint goes to the flight master first
        ns.Guide.Show({ loc = ns.Geo.Loc(1429, 30, 30) }, "Accept: Elsewhere")
        at = shown[#shown]
        local hill = ns.Data.World().travel.nodes[4]
        eq({ at.map, at.title }, { hill[4], "Flight master: Sentinel Hill, fly to Stormwind" })
        near(at.x, hill[5] / 100, 1e-9)
        -- in the air it is the step itself, and it stays so after landing in Stormwind
        M.set("UnitOnTaxi", function() return true end)
        ns.Guide.Tick()
        eq(shown[#shown].title, "Accept: Elsewhere")
        M.set("UnitOnTaxi", function() return false end)
        stand(1453, 0.716, 0.723)
        ns.Guide.Tick()
        eq(shown[#shown].title, "Accept: Elsewhere")
        -- walking on in Elwynn: still the step, and the plan's own step is not pointed at
        stand(1429, 0.42, 0.65)
        ns.Guide.Tick(); ns.Guide.Tick(); ns.Guide.Tick()
        eq(shown[#shown].title, "Accept: Elsewhere")
        eq(ns.Guide.Trip().first.kind, "fly", "the way to the plan's step is still followed for the window")
        -- a step close by, pointed at by hand: no flight, the step at once
        ns.Guide.Show({ loc = ns.Geo.Loc(1429, 45, 65) }, "Accept: Next Door")
        eq(shown[#shown].title, "Accept: Next Door")
        -- a new plan while it is still there (the Engine says so): the arrow stays on it
        ns.Guide.Follow(step, "Turn in: Test", travel, true)
        eq(shown[#shown].title, "Accept: Next Door")
        eq(ns.Guide.Pointed().title, "Accept: Next Door")
        -- a new plan without it: back to the route
        ns.Guide.Follow(step, "Turn in: Test", travel)
        eq(ns.Guide.Pointed(), nil)
        eq(shown[#shown].title, "Flight master: Stormwind, fly to Sentinel Hill")
        -- flight points the character does not know are not suggested
        ns.Guide.Follow(step, "Turn in: Test", ns.Travel.New(ns.Data.World(), { speed = 7, side = "a", knownNodes = { [2] = true } }))
        ns.Guide.Tick(); ns.Guide.Tick()
        eq(shown[#shown].title, "Turn in: Test")
        eq(ns.Format.TripText(ns.Guide.Trip()), "In Westfall")
        ns.Guide.Follow(nil)
        eq({ ns.Guide.Trip(), ns.Guide.mode }, { nil, "none" })
    end)

    test("a current step in the zone we are in, on foot: no extra text; later steps name their zone where it changes", function()
        local ns, travel, shown, current = E.wayfinding()
        local view = ns.Engine.view
        local step = view.plan.steps[1]
        eq(step.loc.map, 1429)
        ns.Guide.Follow(step, ns.Format.StepTitle(step), travel)
        local trip = ns.Guide.Trip()
        eq({ trip.zone, #trip.rides, trip.target }, { nil, 0 })
        eq(ns.Format.TripText(trip), nil)
        eq(#shown, 0, "the waypoint was on the step already and is not set again")
        ns.UI.Refresh()
        local row = current()
        local detail, lines = ns.Format.StepDetail(row.model.step)
        eq({ row.model.detail, row.model.lines, row.model.trip }, { detail, lines })
        ok(not row.detail.text:find("In ", 1, true))
        for _, l in ipairs(row.model.tip()) do ok(l[1] ~= "From where you are") end
        -- the engine's own plan follows the same rule (its travel object knows no flight points here)
        ns.Engine.Replan(true)
        ok(M.settle())
        eq(ns.Format.TripText(ns.Guide.Trip()), nil)
        eq(current().model.trip, nil)
        -- later steps: a zone is named on the first step in it, and again on the way back
        local plan = view.plan
        ok(#plan.steps >= 4)
        local away
        for i = 2, #plan.steps - 1 do
            local a, b = plan.steps[i].loc, plan.steps[i + 1].loc
            if a.map == 1429 and b.map == 1429 and (math.abs(a.mx - b.mx) > 1 or math.abs(a.my - b.my) > 1) and not away then away = i end
        end
        ok(away, "a step with another stop after it")
        plan.steps[away].loc = ns.Geo.Loc(1436, 50, 50)
        ns.UI.Refresh()
        local hints = 0
        for _, r in ipairs(ns.UI.rows) do
            local m = r:IsShown() and r.model
            if m and m.step and not m.current then
                local there = m.detail:find("In Westfall", 1, true)
                local back = m.detail:find("In Elwynn Forest", 1, true)
                if m.step.first == away then ok(there, "the step in Westfall says so") else ok(not there) end
                if there or back then hints = hints + 1 end
            end
        end
        eq(hints, 2, "into Westfall and back: the steps in between say nothing")
    end)

    test("no flight path known: a step in another zone says it is walked for that, once in chat", function()
        local ns = start()
        local view = ns.Engine.view
        ok(not view.flightsKnown, "a fresh character: no flight path seen yet")
        local function current()
            for _, r in ipairs(ns.UI.rows) do
                if r:IsShown() and r.model and r.model.guided then return r end
            end
        end
        -- in Elwynn, the route's first step is in Elwynn: nothing to say
        ok(not current().model.detail:find("flight paths not known", 1, true))
        eq(#M.printed > 0 and table.concat(M.printed, "\n"):find("flight paths yet", 1, true), nil)
        -- in Westfall, the route (Elwynn, the zone chosen) starts in another zone
        C_Map.GetBestMapForUnit = function() return 1436 end
        C_Map.GetPlayerMapPosition = function() return { x = 0.5, y = 0.5 } end
        M.fire("ZONE_CHANGED_NEW_AREA")
        ok(M.settle())
        eq(view.zone, 1429)
        contains(current().model.detail, "on foot: flight paths not known yet")
        local tip = current().model.tip()
        local said = false
        for _, l in ipairs(tip) do if l[1] and l[1]:find("does not know your flight paths", 1, true) then said = true end end
        ok(said, "the tooltip says what to do")
        local function told()
            local n = 0
            for _, line in ipairs(M.printed) do if line:find("does not know your flight paths yet", 1, true) then n = n + 1 end end
            return n
        end
        eq(told(), 1, "said in chat")
        ns.Engine.Replan(true)
        ok(M.settle())
        eq(told(), 1, "once")
        -- a flight path seen: no more of it
        ns.Engine.chardb.knownNodes[2] = true
        ns.Engine.Replan(true)
        ok(M.settle())
        for _, r in ipairs(ns.UI.rows) do
            ok(not (r:IsShown() and r.model and (r.model.detail or ""):find("flight paths not known", 1, true)), "no row says it")
        end
    end)
    test("quests taken along: a malformed saved set is dropped, a set is laid over the route and forgotten with the zone", function()
        local ns = E.installGame()
        M.set("LevelScoutDB", nil)
        M.set("LevelScoutCharDB", { border = { zone = "x", ids = { 1 }, to = {} } })
        E.noSearch(ns)
        ns.Engine.AUTO_SNAPSHOT = false
        M.login()
        ok(M.settle(), "planning finishes")
        eq(LevelScoutCharDB.border, nil, "a malformed set is dropped at login")
        ns = E.start()
        ns.Zones.SEAM = false -- (this test is about the quests taken along alone)
        local view = ns.Engine.view
        local id
        for _, e in ipairs(view.plan.lists.skipped) do
            if e.loc and e.loc.map == view.zone then id = e.id; break end
        end
        ok(id, "the shown route leaves a quest of its zone out")
        local function has(plan, key)
            for _, k in ipairs(plan.order) do if k == key then return true end end
            return false
        end
        ns.Zones.BORDER = false
        ns.Engine.chardb.border = { zone = view.zone, ids = { id }, to = { [id] = 1453 } }
        ns.Engine.Replan()
        ok(M.settle())
        eq(view.plan.base, nil, "the flag off: nothing is laid over the route")
        ns.Zones.BORDER = true
        ns.Engine.chardb.border = { zone = view.zone, ids = { id }, to = { [id] = 1453 } }
        ns.Engine.Replan()
        ok(M.settle())
        ok(has(view.plan, "P:" .. id), "the accept is in the shown route")
        ok(view.plan.base, "made over the route without it")
        ok(not has({ order = ns.Engine.chardb.route.order }, "P:" .. id), "the route saved with the character is the one without it (the set is laid over it again)")
        local other
        for _, z in ipairs(view.ranked) do
            if z.map > 0 and z.map ~= view.zone then other = z.map; break end
        end
        ok(other, "another zone is ranked")
        ns.Engine.SetZone(other)
        ok(M.settle())
        eq(ns.Engine.chardb.border, nil, "choosing a zone forgets the set")
    end)
    test("the way across: a malformed saved one is dropped, one is laid over the route and forgotten with the zone", function()
        local ns = E.installGame()
        M.set("LevelScoutDB", nil)
        M.set("LevelScoutCharDB", { seam = { zone = "x" } })
        E.noSearch(ns)
        ns.Engine.AUTO_SNAPSHOT = false
        M.login()
        ok(M.settle(), "planning finishes")
        eq(LevelScoutCharDB.seam, nil, "a malformed way across is dropped at login")
        ns = E.start()
        local view = ns.Engine.view
        local o = ns.Zones.Plain(view.plan).order
        -- the last two accepts in a row, swapped (so that the stops we stand at are not among them)
        local i
        for k = #o - 1, 1, -1 do
            if o[k]:find("^P:") and o[k + 1]:find("^P:") then i = k; break end
        end
        ok(i, "the shown route has two accepts in a row")
        local recipe = { zone = view.zone, to = 0, window = { o[i], o[i + 1] }, keys = { o[i + 1], o[i] }, leave = o[i],
            windowB = {}, head = {} }
        -- (the next hours are not worked out here: they would judge this made-up way across and drop it)
        ns.Zones.Itinerary = function() error("not worked out in this test") end
        ns.Zones.SEAM = false
        ns.Engine.chardb.seam = recipe
        ns.Engine.Replan()
        ok(M.settle())
        eq(view.plan.seamBase, nil, "the flag off: nothing is laid over the route")
        ns.Zones.SEAM = true
        ns.Engine.chardb.seam = recipe
        ns.Engine.Replan()
        ok(M.settle())
        ok(view.plan.seamBase, "made over the route without it")
        -- (by their places relative to each other: a re-plan may have moved the rest of the route)
        local function at(order, key)
            for n, k in ipairs(order) do if k == key then return n end end
        end
        local a, b = at(view.plan.order, o[i]), at(view.plan.order, o[i + 1])
        ok(a and b and b < a, "the two accepts swapped")
        local saved = ns.Engine.chardb.route.order
        local sa, sb = at(saved, o[i]), at(saved, o[i + 1])
        ok(sa and sb and sa < sb, "the route saved with the character is the one without it (the way across is laid over it again)")
        local other
        for _, z in ipairs(view.ranked) do
            if z.map > 0 and z.map ~= view.zone then other = z.map; break end
        end
        ok(other, "another zone is ranked")
        ns.Engine.SetZone(other)
        ok(M.settle())
        eq(ns.Engine.chardb.seam, nil, "choosing a zone forgets the way across")
    end)
end)
