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
        -- every stop carries a description of what is done there, made once and shared by the frames
        local KIND = { P = "accept", T = "turnin", W = "work" }
        local seen, distinct, total = {}, 0, 0
        for _, f in ipairs(trace.frames) do
            for k = 2, #f.points do
                local s = f.points[k][5]
                ok(s, "every stop has a description")
                eq(s.kind, KIND[f.points[k][4]])
                ok(#ns.Format.StepTitle(s) > 0)
                total = total + 1
                if not seen[s] then seen[s] = true; distinct = distinct + 1 end
            end
        end
        ok(distinct < total / 2, "a stop's description is shared between frames, not copied")
        -- the list of steps and the numbered markers of the final route
        local function title(s) return (ns.Format.StepTitle(s):gsub("^Accept: ", ""):gsub("^Turn in: ", "")) end
        local final, rows, nodes = trace.frames[#trace.frames], LevelScoutDebugFrame.rows, LevelScoutDebugFrame.nodes
        eq(#st.steps, #final.points - 1)
        eq(st.drawn.rows, math.min(#st.steps, st.geo.rows))
        eq(rows[1].num.text, "1")
        eq(rows[1].title.text, title(final.points[2][5]))
        ok(#st.groups > 0, "the route has stops on the map")
        for g, grp in ipairs(st.groups) do
            eq(nodes[g].label.text, ns.Debug.Label(grp.steps))
            near(nodes[g].points[1][4], st.geo.ox + grp.mx / 100 * st.geo.drawW, 1e-6)
        end
        -- hovering a row lights up its marker, hovering a marker lights up its rows
        local r1
        for _, r in ipairs(rows) do
            if r:IsShown() and st.groupOf[r.step] then r1 = r break end
        end
        ok(r1, "a listed step is on the map")
        local g = st.groupOf[r1.step]
        r1.scripts.OnEnter(r1)
        eq(st.hover, g)
        ok(nodes[g].ring:IsShown(), "its marker lights up")
        for gi, n in ipairs(nodes) do
            if gi ~= g then ok(not n.ring:IsShown()) end
        end
        for _, r in ipairs(rows) do
            if r:IsShown() then eq(r.hl:IsShown(), st.groupOf[r.step] == g or r == r1) end
        end
        r1.scripts.OnLeave(r1)
        eq(st.hover, nil)
        ok(not nodes[g].ring:IsShown())
        nodes[g].scripts.OnEnter(nodes[g])
        ok(r1.hl:IsShown(), "hovering the marker lights up its rows")
        contains(table.concat(M.tooltip.lines, "\n"), ns.Format.StepTitle(st.steps[r1.step]))
        nodes[g].scripts.OnLeave(nodes[g])
        ok(not r1.hl:IsShown())
        -- the slider
        local slider = LevelScoutDebugFrame.slider
        slider.scripts.OnValueChanged(slider, 2)
        eq(st.index, 2)
        ok(#trace.frames[2].points >= 2)
        eq(rows[1].title.text, title(trace.frames[2].points[2][5]), "the list follows the slider")
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

    test("search view: steps at one place share a numbered marker", function()
        local D = start().Debug
        local pts = { { 1429, 40, 40, "S" }, { 1429, 50, 50, "P" }, { 1429, 70, 20, "W" }, { 1429, 50.3, 49.8, "T" },
            { 1436, 50, 50, "P" }, { nil, nil, nil, "P" }, { 1429, 50, 50, "T" } }
        local groups, of = D.Group(pts, 1429)
        eq(#groups, 2)
        eq(groups[1].steps, { 1, 3, 6 })
        eq(groups[2].steps, { 2 })
        eq(of[4], nil)
        eq(of[5], nil)
        eq(of[1], 1)
        eq(of[2], 2)
        eq(D.Label({ 4 }), "4")
        eq(D.Label({ 3, 4 }), "3,4")
        eq(D.Label({ 3, 4, 5 }), "3-5")
        eq(D.Label({ 1, 2, 4 }), "1,2,4")
        eq(D.Label({ 1, 3, 5, 7, 9 }), "1,3,5 +2")
        eq(D.Label({ 1, 2, 3, 7, 9, 10, 11, 12 }), "1-3,7,9-12")
    end)

    test("search view: resizable from the corner; size and place are kept", function()
        local ns = start()
        local D = ns.Debug
        -- a saved size and place are used when the view is first built
        LevelScoutDB.debugWindow = { w = 900, h = 640, pos = { "TOPLEFT", "BOTTOMLEFT", 100, 700 } }
        slash("debug")
        ok(M.settle(), "re-planned with the search recorded")
        local f, st = LevelScoutDebugFrame, D.state
        eq(f.width, 900)
        eq(f.height, 640)
        local pt = f.points[1]
        eq(pt[1], "TOPLEFT")
        ok(pt[2] == UIParent)
        eq(pt[3], "BOTTOMLEFT")
        eq(pt[4], 100)
        eq(pt[5], 700)
        -- the map takes what is left of the list, in the zone map's 3 by 2
        eq(f.canvas.width, 900 - 292)
        near(st.geo.drawW / st.geo.drawH, 1.5, 1e-9)
        ok(st.geo.drawW <= st.geo.areaW and st.geo.drawH <= st.geo.areaH, "the map fits its area")
        ok(st.geo.ox >= 0 and st.geo.oy >= 0)
        -- clamped to the limits, and saved
        D.Resize(10, 10)
        eq(LevelScoutDB.debugWindow.w, D.MIN_W)
        eq(LevelScoutDB.debugWindow.h, D.MIN_H)
        eq(f.width, D.MIN_W)
        D.Resize(5000, 5000)
        ok(LevelScoutDB.debugWindow.w <= 1900 and LevelScoutDB.debugWindow.h <= 1300, "and to a maximum")
        -- the markers follow the map
        D.Resize(1200, 800)
        ok(#st.groups > 0)
        near(f.nodes[1].points[1][4], st.geo.ox + st.groups[1].mx / 100 * st.geo.drawW, 1e-6)
        -- dragging the grip: 60 right and 40 down from where the button went down
        local grip = f.grip
        D.Resize(800, 560)
        local cx, cy = 500, 500
        M.set("GetCursorPosition", function() return cx, cy end)
        f.GetEffectiveScale = function() return 1 end
        grip.scripts.OnMouseDown(grip)
        cx, cy = 560, 460
        grip.scripts.OnUpdate(grip, 0.02)
        eq(LevelScoutDB.debugWindow.w, 860)
        eq(LevelScoutDB.debugWindow.h, 600)
        eq(f.width, 860)
        grip.scripts.OnMouseUp(grip)
        ok(LevelScoutDB.debugWindow.pos, "the place is saved when the grip is let go")
        eq(LevelScoutDB.debugWindow.pos[3], 100)
        cx, cy = 900, 100
        grip.scripts.OnUpdate(grip, 0.02)
        eq(LevelScoutDB.debugWindow.w, 860, "nothing moves after the button is released")
        -- the list scrolls with the wheel, and a marker click scrolls it to the marker's first step
        D.Resize(D.MIN_W, D.MIN_H)
        ok(#st.steps >= 1)
        if #st.steps >= st.geo.rows + 2 then
            f.list.scripts.OnMouseWheel(f.list, -1)
            eq(st.scroll, 2)
            eq(f.rows[1].step, 3)
            f.list.scripts.OnMouseWheel(f.list, 1)
            eq(st.scroll, 0)
        end
        local g = #st.groups
        local want = math.min(st.groups[g].steps[1] - 1, math.max(0, #st.steps - st.geo.rows))
        f.nodes[g].scripts.OnClick(f.nodes[g])
        eq(st.scroll, want)
        eq(f.rows[1].step, want + 1)
        slash("debug")
        ok(not D.IsShown())

        -- bad saved values: the default for what is not a number, the minimum for what is too small, the middle of the screen
        local ns2 = start()
        LevelScoutDB.debugWindow = { w = 5, h = "x", pos = { "TOPLEFT" } }
        slash("debug")
        ok(M.settle())
        local f2 = LevelScoutDebugFrame
        eq(f2.width, ns2.Debug.MIN_W)
        eq(f2.height, ns2.Debug.DEFAULT_H)
        eq(f2.points[1][1], "CENTER")
        slash("debug")
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
        -- (after the last step's own "Level N from here" when it levels us up)
        local after = lastStep + 1
        if models[after].section and models[after].section:find("^Level %d+ from here") then after = after + 1 end
        eq(headings, { after }, "one heading, after the last step")
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
        local above = at - 1 -- (the last step's "Level N from here" when it levels us up)
        if models[above].section and models[above].section:find("^Level %d+ from here") then above = above - 1 end
        ok(models[above].step and not models[above].dim or above == 1 or models[above].step.tail, "the route above is as it was")
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

    test("a zone that runs out stays shown, and the banner names the next zone of its itinerary", function()
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
        eq(view.zone, first, "the zone stays shown")
        eq(ns.Engine.chardb.zone, first, "and stays the chosen one")
        eq(#view.plan.steps, 0, "with nothing left in it")
        ok(view.itinerary and view.itinerary.shown == first, "the itinerary is made for it")
        ok(view.itinerary.segments[1].map ~= first, "and starts elsewhere")
        eq(view.status, "ready")
        local m = view.moveOn
        eq({ m.suggest, m.map, m.gain }, { true, view.itinerary.segments[1].map, nil }, "the banner names where the itinerary goes")
        -- the route tab says so, then shows the next zone's first steps
        ns.UI.state.tab, ns.UI.state.scroll = "route", 0
        ns.UI.Refresh()
        local rows = ns.UI.state.models
        eq(rows[1].section, "Nothing left here")
        local then_ = false
        for _, row in ipairs(rows) do if row.section and row.section:find("^Then: ") then then_ = true end end
        ok(then_, "followed by the next zone's heading")
        -- without an itinerary for the finished zone: no banner is made up from the one-hour scores
        -- except that the zone is used up: the best ranked one with something to do
        ns.Zones.PlanZone = realPlan
        ns.Engine.SetZone(first)
        ok(M.settle())
        eq(view.zone, first)
        view.itinerary = nil
        ns.Zones.PlanZone = spent
        ns.Engine.Replan()
        ok(M.settle())
        local best
        for _, z in ipairs(view.ranked) do if #z.plan.steps > 0 and z.map ~= first then best = best or z.map end end
        eq(view.zone, first, "still the zone chosen")
        ok(view.moveOn.suggest and view.moveOn.gain == nil, "the banner says this zone is done")
        -- (the itinerary made for it afterwards goes where the best start is; before it, the best ranked zone)
        ok(view.moveOn.map == best or (view.itinerary and view.moveOn.map == view.itinerary.segments[1].map))
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

    test("the leave step done: the zone stays and the banner says the path is done, as planned", function()
        local ns = start()
        local view = ns.Engine.view
        local first = view.zone
        local realPlan = ns.Zones.PlanZone
        local target
        for i, z in ipairs(view.ranked) do
            if i > 1 and z.map > 0 and z.map ~= first and z.map ~= view.here and #z.plan.steps > 0 then target = z.map end
        end
        ok(target, "another zone to go to")
        local key, step -- the first step with quests: the one the path leaves the zone after
        for i, st in ipairs(view.plan.steps) do
            if st.quests and #st.quests > 0 then key, step = view.plan.order[i], st; break end
        end
        ok(key, "a step to leave the zone after")
        local function commit()
            return { zone = first, hand = true, played = 0, zones = { first, target }, leaveKey = key, stay = 900 }
        end
        local function without(k) -- the step is gone from every plan of the zone: done
            return function(map, ...)
                local p = realPlan(map, ...)
                if map == first then
                    for i, o in ipairs(p.order) do
                        if o == k then table.remove(p.order, i); table.remove(p.steps, i); break end
                    end
                end
                return p
            end
        end
        local chardb = ns.Engine.chardb
        -- the leave step still ahead: nothing is reached
        chardb.commit = commit()
        ns.Engine.Replan()
        ok(M.settle())
        eq(view.zone, first)
        ok(not chardb.commit.reached, "the leave step is still ahead")
        -- the leave step is done
        ns.Zones.PlanZone = without(key)
        chardb.commit = commit()
        M.printed = {}
        ns.Engine.Replan()
        ok(M.settle())
        ns.Zones.PlanZone = realPlan
        eq(view.zone, first, "the zone stays shown")
        eq(chardb.zone, first)
        ok(#view.plan.steps > 0 and view.plan.zone == first, "with its route")
        ok(chardb.commit.reached, "the path is done here")
        contains(output(), "as planned", "chat says so")
        contains(output(), "right-click it to stay")
        local m = view.moveOn
        ok(m.suggest, "the banner is up")
        -- (a clearly better start of the new itinerary may be named instead)
        if m.reached then eq(m.map, target) else ok(m.rate and m.gain >= ns.Zones.MOVE_ON_ENTER - 1) end
        eq(view.status, "ready")
        -- skipped by hand, not done: the step's quests are all in the ignored list
        chardb.commit = commit()
        for _, q in ipairs(step.quests) do ns.Engine.Ignore(q.id, true) end
        ok(M.settle())
        ok(not chardb.commit.reached, "skipping the leave step is not doing it")
        for _, q in ipairs(step.quests) do ns.Engine.Ignore(q.id, false) end
        ok(M.settle())
        -- stay: the commitment starts over, the banner goes
        chardb.commit = commit()
        chardb.commit.reached = true
        view.moveOn = { suggest = true, map = target, reached = true, name = "Next" }
        ns.Engine.StayHere()
        ok(not chardb.commit.reached, "the commitment started over")
        eq({ chardb.commit.zone, chardb.commit.hand, chardb.commit.played }, { first, true, 0 })
        eq(view.moveOn, { suggest = false })
        local stays = 0
        for _, ev in ipairs(ns.Engine.chardb.play.events) do if ev.k == "stay" then stays = stays + 1 end end
        eq(stays, 1, "an event in the play log")
        -- a zone picked by hand is kept: the commitment is made, and is for that zone
        ns.Engine.SetZone(target)
        ok(M.settle())
        eq({ chardb.commit.zone, chardb.commit.hand }, { target, true })
        eq(chardb.zone, target)
    end)
end)
