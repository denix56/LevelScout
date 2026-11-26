-- tests/test_game.lua: game API wrapper, coroutine runner, slash commands (smoke), and the first
-- part of the engine and window on the real data (the rest: test_game_2.lua to test_game_4.lua,
-- split so that the parts run side by side; the mocked game is tests/game_env.lua).
local H, M = ...
local test, eq, ok, contains, near = H.test, H.eq, H.ok, H.contains, H.near

local E = require("game_env")(H, M)
local SECRET, installGame, slash, output, start = E.SECRET, E.installGame, E.slash, E.output, E.start

H.suite("Game", function()
    test("player state", function()
        local ns = installGame()
        local p = ns.Game.GetPlayer()
        eq({ p.level, p.xp, p.xpMax, p.rested, p.maxLevel, p.race, p.class },
            { 12, 3000, 7400, 0, 60, 1, 1 })
    end)

    test("position outside instances; nil inside, on error or when secret", function()
        local ns = installGame()
        eq({ ns.Game.GetPosition() }, { 1429, 0.42, 0.65 })
        ns = installGame({ inInstance = true })
        eq(ns.Game.GetPosition(), nil)
        ns = installGame({ positionError = true })
        eq(ns.Game.GetPosition(), nil)
        ns = installGame({ x = SECRET })
        eq(ns.Game.GetPosition(), nil)
        ns = installGame({ mapId = false })
        eq(ns.Game.GetPosition(), nil)
    end)

    test("quest log skips headers and hidden entries, maps objectives", function()
        local ns = installGame()
        local log = ns.Game.GetQuestLog()
        eq(#log, 2)
        eq(log[1].id, 7)
        eq(log[1].objectives, { { text = "Kobold Vermin slain: 3/10", type = "monster", finished = false,
            have = 3, need = 10 } })
        eq(log[1].rewardXP, nil, "GetQuestLogRewardXP absent")
        ok(log[2].isComplete)
        eq(log[2].logIndex, 4)
    end)

    test("quest log reward XP when the client provides it", function()
        local ns = installGame({ rewardXP = true })
        local log = ns.Game.GetQuestLog()
        eq({ log[1].rewardXP, log[2].rewardXP }, { 170, 340 })
    end)

    test("completed quests and log capacity", function()
        local ns = installGame()
        eq(ns.Game.GetCompletedQuests(), { [783] = true, [5261] = true })
        eq(ns.Game.GetQuestLogCapacity(), 40)
    end)

    test("player context", function()
        local ns = installGame()
        eq(ns.Game.GetPlayerContext(), { faction = "Alliance", class = "WARRIOR", raceId = 1, clientBuild = "1.60.1.70888" })
    end)

    test("game quest tags; unloaded quests are requested", function()
        local ns = installGame()
        eq({ ns.Game.GetQuestTag(166) }, { "dungeon", true })
        eq({ ns.Game.GetQuestTag(7) }, { nil, true })
        E.requested = nil
        eq({ ns.Game.GetQuestTag(424242) }, { nil, false })
        eq(E.requested, 424242)
    end)

    test("missing namespaces degrade to empty results", function()
        local ns = installGame()
        M.set("C_QuestLog", nil)
        M.set("C_Map", nil)
        eq(ns.Game.GetQuestLog(), {})
        eq(ns.Game.GetCompletedQuests(), {})
        eq(ns.Game.GetQuestLogCapacity(), nil)
        eq(ns.Game.GetPosition(), nil)
    end)
end)

H.suite("Async", function()
    test("job runs across frames within the budget and reports its result", function()
        M.install()
        local ns = H.loadAddon()
        local frames = 0
        local result
        ns.Async.Run("job", function(checkpoint)
            local sum = 0
            for i = 1, 10 do
                M.clock = M.clock + 1 -- each unit of work costs 1 ms
                sum = sum + i
                checkpoint()
            end
            return sum
        end, function(okRun, value) result = { okRun, value } end)
        local frame = M.frames[#M.frames]
        while frame.scripts.OnUpdate do
            frames = frames + 1
            frame.scripts.OnUpdate()
            ok(frames < 50, "runaway")
        end
        eq(result, { true, 55 })
        ok(frames >= 2, "work was split over frames (" .. frames .. ")")
    end)

    test("a job error is delivered, not raised", function()
        M.install()
        local ns = H.loadAddon()
        local result
        ns.Async.Run("bad", function() error("kaput") end, function(okRun, err) result = { okRun, err } end)
        M.frames[#M.frames].scripts.OnUpdate()
        eq(result[1], false)
        contains(result[2], "kaput")
    end)

    test("same name replaces the running job", function()
        M.install()
        local ns = H.loadAddon()
        local done = {}
        ns.Async.Run("x", function(cp) M.clock = M.clock + 10; cp(); return 1 end, function(_, v) done[#done + 1] = v end)
        ns.Async.Run("x", function() return 2 end, function(_, v) done[#done + 1] = v end)
        M.frames[#M.frames].scripts.OnUpdate()
        eq(done, { 2 })
        ok(not ns.Async.IsRunning("x"))
    end)
end)

H.suite("Commands", function()

    test("login, /ls status, /ls quest, /ls about, /ls log, /ls pos (real data)", function()
        installGame()
        M.login()
        ok(LevelScout.Data.usable, "data usable")
        slash("status")
        contains(output(), "data: client build " .. LevelScout.data.meta.build)
        contains(output(), "TomTom: ok")
        slash("quest 7")
        contains(output(), "Kobold Camp Cleanup")
        contains(output(), "obj 1 kill x10 (CMaNGOS)")
        contains(output(), "available false - in quest log")
        slash("quest 1")
        contains(output(), "quest 1: not in LevelScout's data")
        slash("about")
        contains(output(), "Data from ForeverDB.net (https://foreverdb.net)")
        slash("log")
        contains(output(), "quest log: 2 / 40")
        slash("pos")
        contains(output(), "uiMapID 1429")
    end)

    test("/ls zone builds the index asynchronously, then reports", function()
        E.noSearch(installGame())
        M.login()
        ok(not LevelScout.Data.IsIndexBuilt(), "login does not block on the index")
        ok(M.settle(), "background work finishes")
        ok(LevelScout.Data.IsIndexBuilt())
        slash("zone")
        contains(output(), "map 1429: ")
    end)

    test("QuestieDB missing: one clear chat message, the window says why, no errors", function()
        installGame({ questiedb = false })
        M.set("LevelScoutDB", nil)
        M.set("LevelScoutCharDB", nil)
        M.login()
        ok(M.settle(), "nothing left running")
        local _, n = output():gsub("QuestieDB is missing", "")
        eq(n, 1, "said once")
        contains(output(), "install or enable QuestieDB")
        ok(not LevelScout.Data.usable)
        eq(LevelScout.Engine.view.status, "error")
        contains(LevelScout.Engine.view.message, "QuestieDB is missing")
        slash("")
        slash("quest 7")
        contains(output(), "data not usable")
        slash("status")
        contains(output(), "data questiedb-missing")
        slash("about")
        contains(output(), "Quest data read at runtime from the QuestieDB addon")
    end)

    test("QuestieDB with the wrong contract: the message names both versions, no errors", function()
        installGame({ questiedb = M.fakeQuestieDB({ contract = 3, version = "1.0.9" }) })
        M.set("LevelScoutDB", nil)
        M.set("LevelScoutCharDB", nil)
        M.login()
        ok(M.settle(), "nothing left running")
        contains(output(), "QuestieDB 1.0.9 (contract 3) does not work with this LevelScout")
        contains(output(), "needs QuestieDB contract 4")
        eq(LevelScout.Engine.view.status, "error")
        slash("replan")
        slash("quest 7")
        contains(output(), "data not usable")
    end)

    test("missing data: login prints a clear message, commands refuse", function()
        M.install()
        H.loadAddon(H.runtimeFiles())
        M.login()
        contains(output(), "LevelScout's data files are missing")
        slash("quest 7")
        contains(output(), "data not usable")
        slash("about")
        contains(output(), "Data from ForeverDB.net")
    end)
end)

H.suite("Engine and window (real data)", function()
    test("login plans in the background and shows the route with a waypoint", function()
        local ns = start(nil, { search = true }) -- the whole thing once, as in the game
        local view = ns.Engine.view
        eq(view.status, "ready")
        eq(view.zone, 1429, "the zone we stand in")
        ok(#view.plan.steps > 5, "a real route")
        ok(#view.ranked >= 2, "other zones ranked")
        eq(ns.Guide.mode, "tomtom")
        local step = view.plan.steps[1]
        ok(step.loc and step.loc.map == 1429)
        -- the window
        ok(LevelScoutFrame:IsShown())
        eq(LevelScoutFrame.title.text, "Map 1429", "no map names in the test client")
        contains(LevelScoutFrame.summaryText.text, "steps")
        ok(tonumber((LevelScoutFrame.rate.text:gsub("k", ""))), "XP per hour is shown")
        eq(LevelScoutFrame.rate.text, ns.Format.Number(view.plan.score),
            "the header shows the rate judged on at least an hour, not a short route's pace")
        local texts = E.rowTexts(ns)
        ok(#texts >= 5, "rows are drawn")
        ok(ns.UI.rows[1].model.current, "the first row is the current step")
        eq(LevelScoutFrame.logText.text, "Log 2/40")
        eq(LevelScoutFrame.status.text, "TomTom arrow")
    end)

    test("the surplus goal: the first ranking works R out, the next one starts from the last ranking's best score", function()
        local ns = start(nil, { goal = "surplus" })
        local view = ns.Engine.view
        eq(view.status, "ready")
        local first = view.ranked[1].plan
        ok(first.R and first.R > 0, "plans carry R")
        local best = 0
        for _, z in ipairs(view.ranked) do best = math.max(best, ns.Zones.AltScore(z.plan)) end
        ns.Engine.Replan(true)
        ok(M.settle(), "planning finishes")
        for _, z in ipairs(view.ranked) do
            near(z.plan.R, best / 3600, 1e-9, "the next ranking is planned against the last one's best score")
        end
        eq(view.ranked[1].plan.value >= view.ranked[#view.ranked].plan.value, true, "ranked by value")
    end)

    test("quests accepted in a row at one NPC are a single row", function()
        local ns = start()
        local steps = ns.Engine.view.plan.steps
        -- consecutive accepts (or turn-ins) at the same NPC and spot
        local merged = 0
        for i = 2, #steps do
            local a, b = steps[i - 1], steps[i]
            if a.kind ~= "work" and a.kind == b.kind and a.target == b.target and a.loc.map == b.loc.map
                and math.abs(a.loc.mx - b.loc.mx) < 0.6 and math.abs(a.loc.my - b.loc.my) < 0.6 then merged = merged + 1 end
        end
        ns.UI.state.tab, ns.UI.state.scroll = "route", 0
        ns.UI.Refresh()
        local stepRows, grouped = 0, 0
        for _, m in ipairs(ns.UI.state.models) do
            if m.step then
                stepRows = stepRows + 1
                if #m.step.quests > 1 and m.step.kind ~= "work" then grouped = grouped + 1 end
            end
        end
        eq(stepRows, #steps - merged, "each such run is one row")
        ok(merged == 0 or grouped > 0, "a grouped row carries several quests")
        eq(ns.Format.StepTitle({ kind = "accept", quests = { { name = "A" }, { name = "B" }, { name = "C" } } }), "Accept: A +2 more")
        -- the grouping itself, on a made-up plan
        local loc = { map = 1429, mx = 40, my = 60 }
        local function step(kind, name, target) return { kind = kind, action = kind, target = target, loc = loc, travel = 0, seconds = 8, xp = 10, quests = { { id = 1, name = name } } } end
        ns.Engine.view.plan.steps = { step("accept", "A", "Bob"), step("accept", "B", "Bob"), step("accept", "C", "Ann"), step("turnin", "A", "Bob") }
        ns.UI.Refresh()
        local titles = {}
        for _, m in ipairs(ns.UI.state.models) do if m.step then titles[#titles + 1] = m.title .. "|" .. tostring(m.right) end end
        eq(titles, { "A, B|+20", "C|+10", "A|+10" })
    end)

    test("route steps outside the planned zone name it, highlighted; there is no separate pick-up list", function()
        local ns = start()
        local view = ns.Engine.view
        eq(view.plan.lists.elsewhere, nil, "quests whose giver is elsewhere are planned or left out like any other")
        -- Show a ranked zone whose route has a step on another map. The ranked route is planned
        -- lighter than the shown one, which can keep every step inside the zone, so the zones
        -- are tried in turn until the window has a later step outside (the data picks the case).
        local function outsideRows(zone)
            local n = 0
            for _, m in ipairs(ns.UI.state.models) do
                if m.step and m.step.loc and not m.guided then
                    local at = ns.Zones.ZoneAt(m.step.loc, { zone, ns.Engine.view.here }) or m.step.loc.map
                    if at ~= zone then n = n + 1 end
                end
            end
            return n
        end
        local candidates = {}
        for _, z in ipairs(view.ranked) do
            if z.map > 0 then
                for _, st in ipairs(z.plan.steps) do
                    local at = st.loc and (ns.Zones.ZoneAt(st.loc, { z.map, view.here }) or st.loc.map)
                    if at and at ~= z.map then candidates[#candidates + 1] = z.map; break end
                end
            end
        end
        ok(#candidates > 0, "a ranked zone's route steps outside it")
        local zone
        for _, z in ipairs(candidates) do
            ns.Engine.SetZone(z)
            ok(M.settle())
            ns.UI.state.tab, ns.UI.state.scroll = "route", 0
            ns.UI.Refresh()
            if outsideRows(z) > 0 then zone = z; break end
        end
        ok(zone, "a shown route has a later step outside its zone (in one of " .. #candidates .. " zones)")
        local warn, plain = 0, 0
        for _, m in ipairs(ns.UI.state.models) do
            ok(m.section ~= "Get before you go" and m.pill ~= "PICK UP", "no pick-up rows")
            if m.step and m.step.loc then
                -- (by zone: a camp's spots can be on the continent map, and that is no other zone)
                local at = ns.Zones.ZoneAt(m.step.loc, { zone, ns.Engine.view.here }) or m.step.loc.map
                local tagged = (m.detail or ""):find("In Map " .. at, 1, true) ~= nil
                if at ~= zone and not m.guided then
                    ok(tagged, "a later step outside the zone names it: " .. tostring(m.title))
                    ok(m.detail:find("|cff", 1, true) and m.detail:find("|cff", 1, true) < m.detail:find("In Map", 1, true),
                        "in its own colour")
                    warn = warn + 1
                elseif at == zone then
                    ok(not (m.detail or ""):find("|cff99f2cc", 1, true), "a step in the zone is not highlighted")
                    plain = plain + 1
                end
            end
        end
        ok(warn > 0 and plain > 0)
        LevelScoutDB.window.collapsed = true
        ns.UI.Refresh()
        ok(ns.UI.state.models[1].current, "collapsed still shows the current step")
    end)

    test("quests in the log are planned from their live progress", function()
        local ns = start()
        local order = table.concat(ns.Engine.view.plan.order, " ")
        ok(not order:find("P:7 ", 1, true) and not order:find("P:33 ", 1, true), "no accept step for quests in the log")
        local left = false
        for _, e in ipairs(ns.Engine.view.plan.lists.skipped) do if e.id == 33 then left = true end end
        ok(order:find("T:33", 1, true) or left, "Wolves Across the Border is complete: turn it in (or leave it out as slow)")
        ok(not order:find("W:[^ ]*#33", 1) , "and nothing is left to do for it")
        local kobolds
        for _, s in ipairs(ns.Engine.view.plan.steps) do
            for _, p in ipairs(s.parts or {}) do if p.quest == 7 then kobolds = p end end
        end
        local skipped = false
        for _, e in ipairs(ns.Engine.view.plan.lists.skipped) do if e.id == 7 then skipped = true end end
        ok(skipped or (kobolds and kobolds.need == 7 and kobolds.have == 3), "7 of 10 kobolds left (or the quest is left out as slow)")
    end)

    test("tabs, tooltips, clicking a zone, skipping and restoring a quest", function()
        local ns = start()
        local UI, view = ns.UI, ns.Engine.view
        -- tooltip of the current step
        local row = UI.rows[1]
        row.scripts.OnEnter(row)
        ok(#M.tooltip.lines >= 3, "step tooltip")
        row.scripts.OnLeave(row)
        -- skip the current step's quest
        local id, name = row.model.step.quests[1].id, row.model.step.quests[1].name
        row.scripts.OnClick(row, "RightButton")
        contains(output(), "Skipped " .. name)
        ok(M.settle())
        ok(ns.Engine.IsIgnored(id))
        for _, s in ipairs(ns.Engine.view.plan.steps) do
            for _, q in ipairs(s.quests) do ok(q.id ~= id, "the skipped quest is out of the route") end
        end
        -- Quests tab lists it; clicking brings it back
        LevelScoutFrame.tabButtons[3].scripts.OnClick(LevelScoutFrame.tabButtons[3], "LeftButton")
        eq(UI.state.tab, "quests")
        local found
        for i = 1, 40 do
            for _, r in ipairs(UI.rows) do
                if r:IsShown() and r.model and r.model.title == name then found = r end
            end
            if found then break end
            LevelScoutFrame.list.scripts.OnMouseWheel(LevelScoutFrame.list, -1)
        end
        ok(found, "the skipped quest is listed under Quests")
        found.scripts.OnClick(found, "LeftButton")
        ok(M.settle())
        ok(not ns.Engine.IsIgnored(id))
        -- Zones tab: click another zone
        LevelScoutFrame.tabButtons[2].scripts.OnClick(LevelScoutFrame.tabButtons[2], "LeftButton")
        local other
        for _, r in ipairs(UI.rows) do
            if r:IsShown() and r.model and r.model.rightSub and not r.model.current and not r.model.itinerary then other = other or r end
        end
        eq(UI.rows[1].model.title, "Flight paths unknown", "a tip until a flight map has been seen")
        local firstZone
        for _, m in ipairs(UI.state.models) do
            if m.rightSub and not m.itinerary then firstZone = m; break end
        end
        ok(firstZone and firstZone.current, "the zone in hand is always the first zone listed")
        for _, m in ipairs(UI.state.models) do
            if m.rightSub and not m.itinerary then
                eq(m.title:find("|TInterface\\Minimap\\Dungeon", 1, true) ~= nil, m.dungeon == true, "a dungeon, and only a dungeon, carries the dungeon icon")
            end
        end
        -- the next hours across zones, when that is more than staying here
        local it = ns.Engine.view.itinerary
        ok(it and #it.segments >= 1 and it.xp > 0 and it.horizon == ns.Zones.HORIZON, "an itinerary is worked out with the ranking")
        for _, m in ipairs(UI.state.models) do
            if m.itinerary then
                ok(#it.segments > 1 or it.segments[1].map ~= ns.Engine.view.zone, "shown only when it says more than 'stay'")
                contains(m.title, it.segments[1].name)
                ok(#m.tip() >= 3, "itinerary tooltip")
            end
        end
        other.model.tip()
        ok(other, "another zone is listed")
        other.scripts.OnEnter(other)
        ok(#M.tooltip.lines >= 3, "zone tooltip")
        other.scripts.OnClick(other, "LeftButton")
        ok(M.settle())
        ok(ns.Engine.view.zone ~= 1429, "the clicked zone is shown")
        eq(UI.state.tab, "route")
        eq(LevelScoutCharDB.zone, ns.Engine.view.zone, "the choice is saved")
    end)

    test("a level-up plans everything again, at the new level", function()
        local ns = start()
        eq(ns.Engine.view.level, 12)
        local ranked = ns.Engine.view.ranked
        -- The game still reports the old level when the event arrives: the event's level counts.
        M.fire("PLAYER_LEVEL_UP", 13)
        ok(M.settle())
        eq(ns.Engine.view.level, 13)
        ok(ns.Engine.view.ranked ~= ranked, "the zones are ranked again, not only the shown one")
        M.set("UnitLevel", function() return 13 end)
        M.clock = M.clock + 5000
        ns.Engine.Replan(true)
        ok(M.settle())
        eq(ns.Engine.view.level, 13)
    end)

    test("joining or leaving a group re-plans with shared kill XP", function()
        local ns = start()
        local function killXP()
            local xp = 0
            for _, s in ipairs(ns.Engine.view.plan.steps) do if s.kind == "work" then xp = xp + s.xp end end
            return xp
        end
        eq(ns.Engine.view.groupSize, 1)
        local solo = killXP()
        ok(solo > 0)
        local size = 3
        M.set("GetNumGroupMembers", function() return size end)
        M.clock = M.clock + 5000
        M.fire("GROUP_ROSTER_UPDATE")
        ok(M.settle())
        eq(ns.Engine.view.groupSize, 3)
        contains(LevelScoutFrame.logText.text, "Group of 3")
        M.fire("GROUP_ROSTER_UPDATE")
        eq(#M.timers, 0, "same size: nothing to re-plan")
        size = 0
        M.clock = M.clock + 5000
        M.fire("GROUP_ROSTER_UPDATE")
        ok(M.settle())
        eq(ns.Engine.view.groupSize, 1)
        -- (a re-plan need not be the first plan step for step, so the totals are close, not equal;
        -- shared between three they would be well under half)
        H.near(killXP(), solo, solo * 0.10, "back to solo numbers")
        ok(not LevelScoutFrame.logText.text:find("Group", 1, true))
    end)

    test("party members' quests are read from the game; the options toggle group quests", function()
        local ns = start()
        eq(ns.Game.PartyOnQuest(7), nil, "no party")
        M.set("UnitExists", function(unit) return unit == "party1" or unit == "party2" end)
        C_QuestLog.IsUnitOnQuest = function(unit, id) return unit == "party1" and id == 7 end
        eq(ns.Game.PartyOnQuest(7), 1)
        eq(ns.Game.PartyOnQuest(33), 0)
        C_QuestLog.IsUnitOnQuest = nil
        M.set("IsUnitOnQuestByQuestID", function(id, unit) return unit == "party2" and id == 33 end)
        eq(ns.Game.PartyOnQuest(33), 1, "the older call takes the quest first")
        M.set("IsUnitOnQuestByQuestID", nil)
        eq(ns.Game.PartyOnQuest(33), nil, "the client cannot say")
        M.fire("UNIT_QUEST_LOG_CHANGED", "player")
        eq(#M.timers, 0)
        M.clock = M.clock + 5000
        M.fire("UNIT_QUEST_LOG_CHANGED", "party1")
        eq(#M.timers, 1, "a member's log changed: re-plan")
        ok(M.settle())
        ok(ns.Engine.RoutesElite(), "group quests are routed by default")
        ok(not ns.Engine.RoutesEscort(), "escort quests are listed by default")
        M.clock = M.clock + 5000
        ns.Engine.SetRouteElite(false)
        ok(M.settle())
        eq(LevelScoutCharDB.routeElite, false)
        for _, s in ipairs(ns.Engine.view.plan.steps) do ok(not s.group, "no group steps when listed only") end
        M.clock = M.clock + 5000
        ns.Engine.SetRouteEscort(true)
        ok(M.settle())
        eq(LevelScoutCharDB.routeEscort, true)
    end)
end)
