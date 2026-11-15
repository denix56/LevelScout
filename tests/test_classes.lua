-- tests/test_classes.lua: class quest chains. The core (core/Classes.lua and the planner's chain
-- mode) on a small made-up world; the engine and the window on the real data (an Alliance
-- warrior at level 12 in Elwynn Forest, as in test_game.lua).
local H, M = ...
local test, eq, ok, contains = H.test, H.eq, H.ok, H.contains

---------------------------------------------------------------------------------------------
-- A made-up world: two zones side by side (1000 x 1000 yards each: 1 map unit = 10 yards)
---------------------------------------------------------------------------------------------

local function S(map, x, y)
    local n = map * 1e6 + math.floor(x * 10 + 0.5) * 1e3 + math.floor(y * 10 + 0.5)
    local digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    repeat local d = n % 36; out = digits:sub(d + 1, d + 1) .. out; n = (n - d) / 36 until n == 0
    return out
end

local WARRIOR, MAGE = 1, 128
local EVERY_CLASS = 1 + 2 + 4 + 8 + 16 + 64 + 128 + 256 + 1024

-- The packed quest record (see adapters/Data.lua buildQuest): field 7 is the classes mask.
local function quest(t)
    return table.concat({ t.name or "Q", t.level or 10, t.min or 10, 0, "", 0, t.classes or 0, t.zone or 1, 0, t.flags or "",
        t.xp or "", t.xp and "f" or "", t.starts or "", t.ends or "", t.objectives or "", t.preAll or "", t.preAny or "",
        t.exclusive or "", "", "", "", "", "", "", "", "", "", "", "", 0 }, "|")
end

local function camp(map, x, y, n)
    local out = {}
    for i = 0, (n or 6) - 1 do out[#out + 1] = S(map, x + (i % 3) * 0.5, y + math.floor(i / 3) * 0.5) end
    return table.concat(out, " ")
end

-- The warrior chain: Call to Arms (or its either-or sibling Other Path, far away) > Steel
-- Trial (slow: six boars for little XP) > Proof of Steel, and Grand Trial at level 14.
-- Errand starts and ends where the chain goes and costs two talks: on the way. Long Hunt starts
-- there too but takes twenty kills. Far Away is in the other zone.
local function fixture(more)
    local curve = {}
    for i = 1, 60 do curve[i] = i * 100 end
    local quests = {
        [30] = quest({ name = "Call to Arms", classes = WARRIOR, xp = 300, starts = "n100", ends = "n101", exclusive = "42" }),
        [31] = quest({ name = "Steel Trial", classes = WARRIOR, xp = 40, starts = "n101", ends = "n101", preAll = "30",
            objectives = "c200:6:C" }),
        [32] = quest({ name = "Proof of Steel", classes = WARRIOR, xp = 400, starts = "n101", ends = "n100", preAll = "31" }),
        [33] = quest({ name = "Grand Trial", classes = WARRIOR, min = 14, level = 14, xp = 900, starts = "n100", ends = "n100",
            preAll = "32" }),
        [42] = quest({ name = "Other Path", classes = WARRIOR, xp = 100, zone = 2, starts = "n110", ends = "n110", exclusive = "30" }),
        [40] = quest({ name = "Arcane Lesson", classes = MAGE, xp = 300, starts = "n100", ends = "n100" }),
        -- (pays less than Errand: Errand takes the time share first, and this one no longer fits)
        [41] = quest({ name = "For Everyone", classes = EVERY_CLASS, xp = 100, starts = "n100", ends = "n100" }),
        [60] = quest({ name = "Errand", xp = 200, starts = "n100", ends = "n101" }),
        [50] = quest({ name = "Long Hunt", xp = 900, starts = "n100", ends = "n100", objectives = "c200:20:C" }),
        [20] = quest({ name = "Far Away", zone = 2, xp = 700, starts = "n111", ends = "n111" }),
    }
    for id, rec in pairs(more or {}) do quests[id] = rec end
    return {
        meta = { build = "1.60.1.70888", generated = "2026-11-15", sources = { QuestieDB = "x", ForeverDB = "y" } },
        quests = quests,
        questText = {}, questSpots = {},
        npcs = {
            [100] = "Marshal|10|10|0|2|A|" .. S(1, 50, 50),
            [101] = "Tanner|10|10|0|2|A|" .. S(1, 52, 50),
            [110] = "Captain|10|10|0|2|A|" .. S(2, 20, 50),
            [111] = "Hermit|10|10|0|2|A|" .. S(2, 80, 80),
            [112] = "Scout|10|10|0|2|A|" .. S(2, 22, 50),
            [200] = "Boar|9|10|0|0||" .. camp(1, 60, 50),
        },
        objects = {}, items = {},
        variants = { Quest = {}, Npc = {}, Object = {}, Item = {} },
        world = {
            pace = { [1] = { c = 30, i = 20, o = 15, r = 7 } },
            xpCurve = curve,
            maps = { [1] = { c = 0, t = 0, l = 0, h = 1000, w = 1000 }, [2] = { c = 0, t = 0, l = -1000, h = 1000, w = 1000 } },
            links = {},
            zones = { [1] = "0|A|s|5-14||0|5,0|||Hub~a~50~50~10~5~10|", [2] = "0|C|s|6-14||0|5,5|||Fort~b~20~50~10~6~12|" },
            travel = { speeds = { fly = 30 }, nodes = {}, flights = "", measured = "" },
            enum = { classKeys = { WARRIOR = 1, PALADIN = 2, HUNTER = 4, ROGUE = 8, PRIEST = 16, SHAMAN = 64, MAGE = 128,
                WARLOCK = 256, DRUID = 1024 } },
            dungeons = {},
        },
    }
end

local function load(more)
    M.install()
    local ns = { data = fixture(more) }
    H.loadAddon(H.runtimeFiles(), ns)
    ns.Data.Init({ faction = "Alliance", class = "WARRIOR", clientBuild = "1.60.1.70888" })
    ns.Data.BuildIndex()
    ns.Zones.Reset()
    return ns
end

local function context(ns, extra)
    local s = { level = 10, faction = "Alliance", class = "WARRIOR", map = 1, x = 0.5, y = 0.5, log = {}, completed = {}, capacity = 20 }
    for k, v in pairs(extra or {}) do s[k] = v end
    return ns.Zones.Context(s)
end

local function indexOf(plan, key)
    for i, k in ipairs(plan.order) do if k == key then return i end end
end

local function listedAnywhere(plan, id)
    for _, list in pairs(plan.lists) do
        for _, e in ipairs(list) do if e.id == id then return true end end
    end
    return false
end

H.suite("Class quests (core)", function()
    test("the index lists the class's own quests, not another class's or every class's", function()
        local ns = load()
        eq(ns.Data.ClassQuests("WARRIOR"), { 30, 31, 32, 33, 42 })
        eq(ns.Data.ClassQuests("MAGE"), { 40 })
        eq(ns.Data.ClassQuests("DRUID"), {})
    end)

    test("a chain is its quests linked by what leads to what; open, sig and the next level", function()
        local ns = load()
        local chains = ns.Classes.Chains(context(ns))
        eq(#chains, 1, "one warrior chain (the mage quest is not ours)")
        local c = chains[1]
        eq(c.id, 30, "under its lowest quest id")
        eq(c.quests, { 30, 31, 32, 33, 42 }, "either-or siblings belong to the chain")
        eq(c.open, { 30, 42 })
        eq(c.sig, "30,42")
        eq({ c.level, c.nextLevel, c.inLog }, { 10, 14, false })
    end)

    test("the chain moves on: a sibling taken is never open again, the next quest opens", function()
        local ns = load()
        local c = ns.Classes.Chains(context(ns, { completed = { [30] = true } }))[1]
        eq(c.quests, { 31, 32, 33 }, "Other Path is out: Call to Arms was taken")
        eq(c.sig, "31")
        local log = { { id = 31, title = "Steel Trial", level = 10, isComplete = false, objectives = {} } }
        c = ns.Classes.Chains(context(ns, { completed = { [30] = true }, log = log }))[1]
        eq({ c.sig, c.inLog }, { "31", true }, "a quest in the log is open")
    end)

    test("below the chain's level nothing is open, and it says when it opens", function()
        local ns = load()
        local c = ns.Classes.Chains(context(ns, { level = 9 }))[1]
        eq(#c.open, 0)
        eq(c.nextLevel, 10)
        eq(#ns.Classes.Chains(context(ns, { completed = { [30] = true, [31] = true, [32] = true, [33] = true } })), 0,
            "all done: no chain")
    end)

    test("a chain's plan does every quest of it in order, a slow one too, and is named after its last", function()
        local ns = load()
        local ctx = context(ns)
        local chain = ns.Classes.Chains(ctx)[1]
        local plan = ns.Classes.Plan(chain, ctx)
        local t30, t31, t32 = indexOf(plan, "T:30"), indexOf(plan, "T:31"), indexOf(plan, "T:32")
        ok(t30 and t31 and t32, "the three quests are turned in: " .. table.concat(plan.order, " "))
        ok(t30 < indexOf(plan, "P:31") and t31 < indexOf(plan, "P:32"), "each after the one before")
        eq(indexOf(plan, "P:42"), nil, "one of the either-or siblings only: the near one")
        ok(not listedAnywhere(plan, 31), "the slow quest is never left out as slow")
        eq({ plan.chain, plan.chainQuests, plan.chainName }, { 30, 3, "Proof of Steel" })
        eq(ns.Classes.Facts(chain, plan).laterLevel, 14, "Grand Trial waits for level 14")
    end)

    test("quests on the way come along within the time share; long and far ones stay out, unlisted", function()
        local ns = load()
        local ctx = context(ns)
        local chain = ns.Classes.Chains(ctx)[1]
        local plan = ns.Classes.Plan(chain, ctx)
        ok(indexOf(plan, "P:60") and indexOf(plan, "T:60"), "Errand: two talks where the chain goes: "
            .. table.concat(plan.order, " ") .. string.format(" (%.0f s)", plan.seconds))
        for _, step in ipairs(plan.steps) do
            local id = step.quests[1] and step.quests[1].id
            if id == 60 then eq(step.extra, true, "an Errand step is marked as on the way") end
            if id == 31 then eq(step.extra, nil, "a chain step is not") end
        end
        eq(indexOf(plan, "P:50"), nil, "Long Hunt adds far more than a tenth of the chain's time")
        eq(indexOf(plan, "P:20"), nil, "Far Away is not on the way")
        ok(not listedAnywhere(plan, 50) and not listedAnywhere(plan, 20) and not listedAnywhere(plan, 60),
            "quests that are not of the chain are not listed")
        local extra = 0
        for _, step in ipairs(plan.steps) do
            if step.extra then extra = extra + step.travel + step.seconds end
        end
        ok(extra <= ns.Planner.CHAIN_EXTRA_SHARE * plan.seconds + 1e-6, "the extras take at most their share")
    end)

    test("a zone's route that does a quest of the chain already does the chain", function()
        local ns = load()
        local chain = ns.Classes.Chains(context(ns))[1]
        ok(ns.Classes.InPlan(chain, { steps = { { quests = { { id = 31 } } } } }))
        ok(not ns.Classes.InPlan(chain, { steps = { { quests = { { id = 60 } } } } }))
        ok(not ns.Classes.InPlan(chain, nil))
    end)

    test("a quest no Forever player has seen is confirmed by a follow-up that needs it", function()
        -- (flags "u": no ForeverDB player has seen it; no XP: no reward in Questie's traces)
        local ns = load({
            [80] = quest({ name = "Hidden Step", flags = "u", starts = "n100", ends = "n100" }),
            [81] = quest({ name = "Seen After", xp = 300, starts = "n100", ends = "n100", preAll = "80" }),
            [82] = quest({ name = "Lone Unseen", flags = "u", starts = "n100", ends = "n100" }),
            [83] = quest({ name = "Also Unseen", flags = "u", starts = "n100", ends = "n100", preAll = "82" }),
            [84] = quest({ name = "Maybe", flags = "u", starts = "n100", ends = "n100" }),
            [85] = quest({ name = "Either", xp = 300, starts = "n100", ends = "n100", preAny = "84,60" }),
            [86] = quest({ name = "Far Back", flags = "u", starts = "n100", ends = "n100" }),
            [87] = quest({ name = "Middle", flags = "u", starts = "n100", ends = "n100", preAny = "86" }),
            [88] = quest({ name = "Seen At Last", xp = 300, starts = "n100", ends = "n100", preAll = "87" }),
        })
        local function unconfirmed(id) return ns.Model.Unconfirmed(ns.Data.GetQuest(id)) end
        eq(unconfirmed(80), false, "Seen After cannot be had without it")
        eq({ unconfirmed(82), unconfirmed(83) }, { true, true }, "nothing after them is seen")
        eq(unconfirmed(84), true, "Either needs only one of Maybe and Errand")
        eq({ unconfirmed(86), unconfirmed(87) }, { false, false }, "through a follow-up confirmed in turn")
    end)

    test("one of several prerequisites: the follow-up follows whichever of them is planned", function()
        -- Path A and Path B are either-or; Reunion needs one of them (before, it waited for both)
        local ns = load({
            [70] = quest({ name = "Path A", zone = 2, xp = 300, starts = "n110", ends = "n110", exclusive = "71" }),
            [71] = quest({ name = "Path B", zone = 2, xp = 200, starts = "n112", ends = "n112", exclusive = "70" }),
            [72] = quest({ name = "Reunion", zone = 2, xp = 500, starts = "n110", ends = "n112", preAny = "70,71" }),
        })
        local ctx = context(ns, { map = 2, x = 0.21, y = 0.5 })
        local plan = ns.Zones.PlanOne(2, ctx)
        local a, b = indexOf(plan, "T:70"), indexOf(plan, "T:71")
        ok((a ~= nil) ~= (b ~= nil), "one path: " .. table.concat(plan.order, " "))
        local p72 = indexOf(plan, "P:72")
        ok(p72 and p72 > (a or b), "Reunion is planned after the path taken")
        ok(not listedAnywhere(plan, 72), "and not listed as impossible")
    end)
end)

---------------------------------------------------------------------------------------------
-- The engine and the window on the real data
---------------------------------------------------------------------------------------------

local E = require("game_env")(H, M)

-- Log in as in E.start, with these quests done as well. With A Warrior's Training (1638) done,
-- the level 10 warrior chain is not in Elwynn's route any more: it is offered.
local function startWith(done)
    local ns = E.installGame()
    local ids = { 783, 5261 }
    for _, id in ipairs(done or {}) do ids[#ids + 1] = id end
    C_QuestLog.GetAllCompletedQuestIDs = function() return ids end
    M.set("LevelScoutDB", nil)
    M.set("LevelScoutCharDB", nil)
    E.noSearch(ns)
    M.login()
    ok(M.settle(), "planning finishes")
    return ns
end

local function said(pattern)
    local n = 0
    for _, line in ipairs(M.printed) do if line:find(pattern, 1, true) then n = n + 1 end end
    return n
end

local function click(widget, mouse) widget.scripts.OnClick(widget, mouse or "LeftButton") end

local function rowWith(ns, text)
    for _, r in ipairs(ns.UI.rows) do
        local m = r:IsShown() and r.model
        if m and ((m.title and m.title:find(text, 1, true)) or (m.section and m.section:find(text, 1, true))) then return r end
    end
end

local function offered(ns, id)
    for _, o in ipairs(ns.Engine.view.chains) do if o.id == id then return o end end
end

local CLASS_TAB = 4

H.suite("Class quests (real data)", function()
    test("accept and turn-in titles carry the quest's level, as the quest log shows it", function()
        local ns = E.start()
        local F = ns.Format
        eq(F.QuestName("Wolves", 4), "[4] Wolves")
        eq(F.QuestName("Wolves", 0), "Wolves", "no level known")
        eq(F.StepTitle({ kind = "accept", quests = { { name = "A", level = 5 }, { name = "B", level = 6 } } }), "Accept: [5] A, [6] B")
        eq(F.StepTitle({ kind = "turnin", quests = { { name = "A", level = 5 } } }), "Turn in: [5] A")
        local seen = false
        for i, step in ipairs(ns.Engine.view.plan.steps) do
            local q = step.quests[1]
            if (step.kind == "accept" or step.kind == "turnin") and q and (q.level or 0) > 0 then
                contains(F.StepTitle(step), "[" .. q.level .. "] " .. q.name)
                seen = true
            end
        end
        ok(seen, "the route has quests with a level")
        local row = ns.UI.rows[1].model
        if row.step and (row.step.kind == "accept" or row.step.kind == "turnin") and (row.step.quests[1].level or 0) > 0 then
            contains(row.title, "[" .. row.step.quests[1].level .. "]", "on the route's rows too")
        end
    end)

    test("a chain the leveling route already does is not offered", function()
        local ns = E.start()
        local view = ns.Engine.view
        local inRoute = false
        for _, step in ipairs(view.plan.steps) do
            for _, q in ipairs(step.quests or {}) do if q.id == 1638 then inRoute = true end end
        end
        ok(inRoute, "A Warrior's Training is in Elwynn's route")
        eq(offered(ns, 1638), nil)
        ok(not LevelScoutFrame.tabButtons[CLASS_TAB].glowing, "nothing new on the Class tab")
    end)

    test("an available chain: one line in chat, the Class tab glows until it is opened", function()
        local ns = startWith({ 1638 })
        local o = offered(ns, 1638)
        ok(o and o.new, "the warrior chain is on offer, and news")
        ok(o.count > 0 and o.seconds > 0 and o.xp > 0 and #o.zones > 0)
        local tab = LevelScoutFrame.tabButtons[CLASS_TAB]
        eq(tab.name, "Class")
        ok(tab.glowing and tab.glow:IsShown(), "the tab glows")
        contains(tab.label.text, "New")
        local banner = LevelScoutFrame.banner
        ok(not (banner:IsShown() and (banner.label.text or ""):find("lass quest")), "no banner for it (a move-on one may be up)")
        eq(said("is now available"), 1)
        contains(table.concat(M.printed, "\n"), "Class tab")
        ns.Engine.Replan(true)
        ok(M.settle())
        eq(said("is now available"), 1, "said once, not on every plan")
        ok(tab.glowing, "still glowing: the tab was not opened")
        click(tab)
        eq(ns.UI.state.tab, "class")
        ok(not tab.glowing and not tab.glow:IsShown(), "opened: the glow is gone")
        eq(ns.Engine.chardb.classChains[1638].seen, o.sig)
        local row = rowWith(ns, ns.Format.QuestName(o.name, o.level))
        ok(row, "the chain is listed, with its level")
        contains(row.model.detail, "New", "marked new while the tab stays open")
        row.scripts.OnEnter(row)
        local tip = table.concat(M.tooltip.lines, "\n")
        contains(tip, "Starts at")
        contains(tip, "Click: plan it")
        click(LevelScoutFrame.tabButtons[1])
        ok(not tab.glowing, "seen: it does not glow again")
        click(tab)
        ok(not rowWith(ns, o.name).model.detail:find("New", 1, true), "and is not new any more")
    end)

    test("right-click turns a chain off; listed apart, a click brings it back", function()
        local ns = startWith({ 1638 })
        local o = offered(ns, 1638)
        click(LevelScoutFrame.tabButtons[CLASS_TAB])
        click(rowWith(ns, o.name), "RightButton")
        ok(offered(ns, 1638).never, "not suggested")
        ok(rowWith(ns, "Not suggested"), "a section of its own")
        local row = rowWith(ns, o.name)
        ok(row and row.model.dim)
        click(row)
        ok(not offered(ns, 1638).never, "suggested again")
        ok(rowWith(ns, "Available"))
        ok(not LevelScoutFrame.tabButtons[CLASS_TAB].glowing, "not as news")
    end)

    test("picked, the chain is the plan until it is done; then leveling goes on", function()
        local ns = startWith({ 1638 })
        local view = ns.Engine.view
        local name = offered(ns, 1638).name
        click(LevelScoutFrame.tabButtons[CLASS_TAB])
        click(rowWith(ns, name))
        ok(M.settle())
        eq(ns.UI.state.tab, "route", "picking one shows its route")
        eq(view.plan.chain, 1638, "the chain's plan is shown")
        eq(view.chain.id, 1638)
        eq(LevelScoutFrame.title.text, "Class quest: " .. ns.Format.QuestName(view.chain.name, view.chain.level))
        contains(LevelScoutFrame.summaryText.text, "left")
        eq(view.moveOn.suggest, false, "no move-on banner")
        eq(view.itinerary, nil, "no itinerary")
        eq(offered(ns, 1638), nil, "not offered while followed")
        local last = ns.UI.state.models[#ns.UI.state.models]
        contains(last.section or "", "Then: back to leveling", "the route ends with where leveling goes on")
        click(LevelScoutFrame.tabButtons[CLASS_TAB])
        ok(rowWith(ns, "Following"), "the Class tab shows the chain followed")
        ns.Engine.Replan(true)
        ok(M.settle())
        eq(view.plan.chain, 1638, "a full re-plan keeps the chain")
        -- every quest of the chain turned in
        for _, id in ipairs(view.chain.quests) do M.fire("QUEST_TURNED_IN", id) end
        ok(M.settle())
        eq(view.chain, nil)
        eq(view.plan.chain, nil, "a zone's route again")
        ok(view.zone ~= nil)
        eq(said("Class quest done: |cffffd100" .. name), 1, "chat says the chain is done")
        eq(LevelScoutFrame.title.text, view.zoneName)
    end)

    test("Back to the leveling plan, or a zone picked, leaves the chain", function()
        local ns = startWith({ 1638 })
        local view = ns.Engine.view
        ns.Engine.SetChain(1638)
        ok(M.settle())
        eq(view.plan.chain, 1638)
        ns.Engine.EndChain()
        ok(M.settle())
        eq(view.chain, nil)
        eq(view.plan.chain, nil)
        local o = offered(ns, 1638)
        ok(o and not o.new, "on offer again, not as news")
        ns.Engine.SetChain(1638)
        ok(M.settle())
        local map = view.ranked[1].map
        ns.Engine.SetZone(map)
        ok(M.settle())
        eq(view.chain, nil, "picking a zone leaves the chain")
        eq(view.zone, map)
    end)

    test("a paladin chain through a quest no Forever player has seen is planned to its end", function()
        -- A Strange Artifact (78088) > ... > A Second Opinion (78090, not seen in Forever) >
        -- Earning Your Salt (78091, seen) > It Must Be Destroyed (78092); quests of level 30,
        -- offered from level 26 (they are red before)
        local ns = E.installGame({ questiedb = M.questieDB("Alliance", "PALADIN") })
        M.set("UnitClass", function() return "Paladin", "PALADIN", 2 end)
        M.set("UnitLevel", function() return 26 end)
        M.set("UnitXP", function() return 0 end)
        M.set("UnitXPMax", function() return 20000 end)
        M.set("LevelScoutDB", nil)
        M.set("LevelScoutCharDB", nil)
        E.noSearch(ns)
        M.login()
        ok(M.settle())
        eq(ns.Model.Unconfirmed(ns.Data.GetQuest(78090)), false, "shown to exist by Earning Your Salt")
        local o = offered(ns, 78088)
        ok(o, "the chain is on offer")
        eq(o.count, 5, "all five quests")
        eq(o.name, "It Must Be Destroyed")
        M.questieDB("Alliance", "WARRIOR") -- (the other tests play a warrior)
    end)

    test("a quest of the chain dropped ends the chain; one turned in does not", function()
        local ns = startWith({ 1638 })
        local view = ns.Engine.view
        ns.Engine.SetChain(1638)
        ok(M.settle())
        local id = view.chain.quests[1]
        M.fire("QUEST_REMOVED", id)
        ok(M.settle())
        eq(view.chain and view.chain.id, 1638, "the client cannot tell: kept")
        C_QuestLog.IsQuestFlaggedCompleted = function() return true end
        M.fire("QUEST_REMOVED", id)
        ok(M.settle())
        eq(view.chain and view.chain.id, 1638, "turned in: kept")
        C_QuestLog.IsQuestFlaggedCompleted = function() return false end
        M.fire("QUEST_REMOVED", id)
        ok(M.settle())
        eq(view.chain, nil, "dropped: back to leveling")
        eq(said("You dropped"), 1)
    end)
end)
