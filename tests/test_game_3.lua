-- tests/test_game_3.lua: the engine and the window on the real data, part 3 of 4 (see test_game.lua):
-- the search view, the plan memory, the itinerary on the route and a zone that runs out.
local H, M = ...
local test, eq, ok, contains, near = H.test, H.eq, H.ok, H.contains, H.near

local E = require("game_env")(H, M)
local SECRET, installGame, slash, output, start = E.SECRET, E.installGame, E.slash, E.output, E.start

H.suite("Engine and window (real data)", function()
    test("search view: the search is recorded while it is open, and the slider steps through it", function()
        -- (with the search on, as the view records it; 30 rounds a zone make plenty of frames)
        local ns = start(nil, { search = true, rounds = 30 })
        ok(not ns.Engine.view.trace, "nothing is recorded while the view is closed")
        -- the button in the window's header opens and closes it, like /ls debug
        local button = LevelScoutFrame.searchButton
        ok(button, "a search-view button in the header")
        button.scripts.OnClick(button, "LeftButton")
        ok(ns.Debug.IsShown())
        button.scripts.OnClick(button, "LeftButton")
        ok(not ns.Debug.IsShown())
        slash("debug")
        ok(ns.Debug.IsShown())
        ok(M.settle(), "re-planned with the search recorded")
        local trace = ns.Engine.view.trace
        ok(trace and #trace.frames > 10, "one frame per round, plus the first and the final route")
        eq(trace.zone, ns.Engine.view.zone)
        eq(trace.frames[1].kind, "start")
        eq(trace.frames[#trace.frames].kind, "final")
        local kinds = {}
        for _, f in ipairs(trace.frames) do
            kinds[f.kind] = true
            ok(#f.points >= 1 and f.points[1][4] == "S", "every frame starts where we stand")
            ok(f.worth and f.score)
            if f.round then ok(f.took and f.names and f.out, "a round says what it took out") end
        end
        ok(kinds.best or kinds.better, "some round improved the route")
        local st = ns.Debug.state
        eq(st.index, #trace.frames, "opens on the final route")
        contains(LevelScoutDebugFrame.top.text, "Final route")
        contains(LevelScoutDebugFrame.bottom.text, "XP/h")
        ok(st.drawn.dots > 3, "stops are drawn")
        -- the slider
        local slider = LevelScoutDebugFrame.slider
        slider.scripts.OnValueChanged(slider, 2)
        eq(st.index, 2)
        contains(LevelScoutDebugFrame.top.text, "Round 1 of")
        contains(LevelScoutDebugFrame.count.text, "2 / " .. #trace.frames)
        -- the wheel steps, and stops at the ends
        LevelScoutDebugFrame.scripts.OnMouseWheel(LevelScoutDebugFrame, 1)
        LevelScoutDebugFrame.scripts.OnMouseWheel(LevelScoutDebugFrame, 1)
        eq(st.index, 1)
        contains(LevelScoutDebugFrame.top.text, "first built")
        -- play runs to the end and stops
        LevelScoutDebugFrame.play.scripts.OnClick(LevelScoutDebugFrame.play)
        ok(st.playing)
        for _ = 1, #trace.frames + 5 do LevelScoutDebugFrame.scripts.OnUpdate(LevelScoutDebugFrame, 0.2) end
        eq(st.index, #trace.frames)
        ok(not st.playing)
        -- the shown route is the same as without recording: re-plan from the same shown plan
        -- once with the recording on and once with it off
        local view = ns.Engine.view
        local shown, itinerary = view.plan, view.itinerary
        -- Each re-plan also feeds the plan memory and the step log, so each one starts from the
        -- same shown plan, an empty memory and no step log.
        local onPlan = ns.Tracker.OnPlan
        ns.Tracker.OnPlan = function() end
        local function again()
            view.plan, view.itinerary = shown, itinerary
            ns.Engine.ResetMemory()
            ns.Engine.Replan(true)
            ok(M.settle())
            return table.concat(view.plan.order, " ")
        end
        local with = again()
        ok(view.trace, "recorded")
        slash("debug")
        ok(not ns.Debug.IsShown())
        ok(not view.trace, "closing stops the recording")
        eq(again(), with, "recording does not change the plan")
        ns.Tracker.OnPlan = onPlan
    end)

    test("plan memory: forgotten on /ls learn reset and on entering the world; the search view writes none", function()
        local ns = start()
        local resets, remembered = 0, 0
        local reset, remember = ns.Memory.Reset, ns.Memory.Remember
        ns.Memory.Reset = function(...) resets = resets + 1; return reset(...) end
        ns.Memory.Remember = function(...) remembered = remembered + 1; return remember(...) end
        slash("learn reset")
        eq(resets, 1, "/ls learn reset")
        ok(M.settle())
        M.fire("PLAYER_ENTERING_WORLD")
        eq(resets, 2, "entering the world")
        ok(M.settle())
        ns.Engine.ResetMemory()
        eq(resets, 3)
        -- a full re-plan writes what it planned; the recorded plan of the search view adds nothing
        ns.Engine.ResetMemory(); ok(M.settle())
        remembered = 0
        ns.Engine.Replan(true)
        ok(M.settle())
        local without = remembered
        ok(without >= 1, "plans are remembered")
        slash("debug")
        ok(M.settle(), "re-planned with the search recorded")
        remembered = 0
        ns.Engine.ResetMemory()
        ns.Engine.Replan(true)
        ok(M.settle())
        ok(ns.Engine.view.trace, "recorded")
        eq(remembered, without, "the recorded plan is not written to the memory")
        slash("debug")
    end)

    test("the route shows where the itinerary moves on to the next zone", function()
        local ns = start()
        local view = ns.Engine.view
        local k = math.min(4, #view.plan.order - 2)
        view.itinerary = { horizon = 7200, xp = 1000, rate = 500, stay = 900, segments = {
            { map = view.zone, name = "Here", travel = 0, seconds = 1800, xp = 400, leave = k, leaveKey = view.plan.order[k] },
            { map = -1, name = "Elsewhere", travel = 300, seconds = 2400, xp = 600 } } }
        ns.UI.Refresh()
        local at
        for i, m in ipairs(ns.UI.state.models) do
            if m.section and m.section:find("Then: Elsewhere", 1, true) then at = i end
        end
        ok(at, "a heading names the next zone")
        contains(ns.UI.state.models[at].section, "40 min")
        local before, after = 0, 0
        for i, m in ipairs(ns.UI.state.models) do
            if m.step then
                if i < at then before = before + 1; ok(not m.dim or m.step.tail, "steps before it are not dimmed") end
                if i > at then after = after + 1; ok(m.dim, "what follows here is dimmed") end
            end
            ok(not (i > at and m.section == "Low value from here"), "no second heading after it")
        end
        ok(before >= 1 and after >= 1)
        eq(ns.UI.state.models[at + 1].section, "Left for later here")
        -- a leave step that is gone from the route: the next zone follows the route's end
        view.itinerary.segments[1].leaveKey = "T:0"
        ns.UI.Refresh()
        local models = ns.UI.state.models
        local headings, lastStep = {}, 0
        for i, m in ipairs(models) do
            if m.section and m.section:find("^Then: Elsewhere") then headings[#headings + 1] = i end
            if m.step then lastStep = i end
        end
        eq(headings, { lastStep + 1 }, "one heading, after the last step")
        -- an itinerary that starts elsewhere shows no heading
        view.itinerary.segments[1].map = -2
        ns.UI.Refresh()
        for _, m in ipairs(ns.UI.state.models) do ok(not (m.section and m.section:find("^Then:"))) end
    end)

    test("the route goes on with the next zone's first steps, where the itinerary leaves or at its end", function()
        local ns = start()
        local view = ns.Engine.view
        local other
        for _, z in ipairs(view.ranked) do if z.map ~= view.zone and #z.plan.steps > ns.UI.AHEAD_STEPS + 2 then other = z end end
        ok(other, "another zone with a route")
        local function show(k, leave)
            view.itinerary = { horizon = 7200, xp = 1000, rate = 500, stay = 900, shown = view.zone, segments = {
                { map = view.zone, name = "Here", travel = 0, seconds = 1800, xp = 400, leave = k, leaveKey = view.plan.order[k] },
                { map = other.map, name = "Elsewhere", travel = 300, seconds = 2400, xp = 600, plan = other.plan, leave = leave } } }
            ns.UI.state.tab, ns.UI.state.scroll = "route", 0
            ns.UI.Refresh()
            local at, ahead, steps, later = nil, {}, 0, nil
            for i, m in ipairs(ns.UI.state.models) do
                if m.section and m.section:find("Then: Elsewhere", 1, true) then at = i end
                if m.section == "Left for later here" then later = i end
                if m.ahead then ahead[#ahead + 1] = i; ok(m.dim and not m.current and not m.step and not m.guided, "a dimmed row of its own kind") end
                if m.step then steps = steps + 1 end
            end
            return at, ahead, steps, later, ns.UI.state.models
        end
        -- the zone is followed to its end: the heading and the next zone's steps close the list
        local at, ahead, steps, later, models = show(#view.plan.order)
        ok(at and not later, "a heading after the last step")
        eq(#ahead, ns.UI.AHEAD_STEPS, "its first steps")
        eq(ahead[1], at + 1); eq(ahead[#ahead], at + #ahead, "in a row")
        for i = at, #models do ok(not models[i].step, "no step of the shown zone after them") end
        ok(models[at - 1].step and not models[at - 1].dim or at - 1 == 1 or models[at - 1].step.tail, "the route above is as it was")
        local first = other.plan.steps[1]
        eq(models[at + 1].ahead.loc, first.loc, "starting with its first stop")
        contains(models[at + 1].detail, "In Map " .. first.loc.map, "the first of them names its zone")
        ok(#models[at + 1].tip() >= 2, "with a tooltip")
        local shownSteps = steps
        -- left in the middle: heading, the next zone's steps, then what is left for later here
        local k = math.min(4, #view.plan.order - 2)
        at, ahead, steps, later, models = show(k, 2)
        ok(at and later and later > at, "what is left here comes after the next zone")
        ok(#ahead >= 1 and #ahead <= 2, "only up to where the next zone is left: " .. #ahead)
        eq(ahead[1], at + 1); eq(later, ahead[#ahead] + 1)
        eq(steps, shownSteps, "the shown zone's own rows are all still there")
        for i = later + 1, #models do ok(not models[i].step or models[i].dim, "dimmed") end
        -- the waypoint still follows the shown zone's first step
        ok(models[1].current or models[2].current)
    end)

    test("a zone that runs out hands over at once to the next zone of its itinerary", function()
        local ns = start()
        local view = ns.Engine.view
        local first = view.zone
        local ranks = 0
        local realRank, realPlan = ns.Zones.Rank, ns.Zones.PlanZone
        ns.Zones.Rank = function(...) ranks = ranks + 1; return realRank(...) end
        ns.Engine.Replan()
        ok(M.settle())
        eq(ranks, 0, "a quick re-plan does not rank the zones")
        eq(view.zone, first)
        -- a zone that is neither the best nor where we stand, named next by the itinerary
        local target
        for i, z in ipairs(view.ranked) do
            if i > 1 and z.map ~= first and z.map ~= view.here and #z.plan.steps > 0 then target = z.map end
        end
        ok(target, "a third zone to go to")
        view.itinerary = { horizon = 7200, xp = 1000, rate = 500, stay = 900, shown = first, segments = {
            { map = first, name = "Here", travel = 0, seconds = 300, xp = 400, leave = 1, leaveKey = view.plan.order[1] },
            { map = target, name = "Next", travel = 300, seconds = 2400, xp = 600 } } }
        -- the shown zone has nothing left
        local function spent(map, ...)
            local p = realPlan(map, ...)
            if map == first then p.steps, p.order, p.score, p.xp, p.seconds = {}, {}, 0, 0, 0 end
            return p
        end
        ns.Zones.PlanZone = spent
        ns.Engine.Replan()
        ok(M.settle())
        eq(ranks, 1, "the zones are ranked in the same job")
        eq(view.zone, target, "the itinerary's next zone is shown")
        eq(ns.Engine.chardb.zone, target, "and stays the shown zone")
        ok(#view.plan.steps > 0 and view.plan.zone == target, "with its route")
        ok(view.itinerary and view.itinerary.shown == target, "and an itinerary of its own")
        eq(view.status, "ready")
        -- without an itinerary for the finished zone: where we stand, else the best, as before
        ns.Zones.PlanZone = realPlan
        ns.Engine.SetZone(first)
        ok(M.settle())
        eq(view.zone, first)
        view.itinerary = nil
        ns.Zones.PlanZone = spent
        ns.Engine.Replan()
        ok(M.settle())
        local best
        for _, z in ipairs(view.ranked) do if #z.plan.steps > 0 then best = best or z.map end end
        eq(view.zone, best, "the best zone with something to do")
        ok(view.zone ~= first)
        -- nothing anywhere: no loop of rankings, the empty route stays
        ns.Zones.PlanZone = function(map, ...)
            local p = realPlan(map, ...)
            p.steps, p.order, p.score, p.xp, p.seconds = {}, {}, 0, 0, 0
            return p
        end
        ranks = 0
        ns.Engine.Replan()
        ok(M.settle())
        local after = ranks
        ok(after <= 1, "ranked once when the route ran out")
        ns.Engine.Replan()
        ok(M.settle())
        eq(ranks, after, "an empty route does not rank the zones on every re-plan")
        ns.Zones.Rank, ns.Zones.PlanZone = realRank, realPlan
    end)
end)
