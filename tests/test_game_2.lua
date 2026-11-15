-- tests/test_game_2.lua: the engine and the window on the real data, part 2 of 4 (see test_game.lua):
-- skipping and restoring, quests from items, XP buffs and rest, settings, the minimap, rows and resizing.
local H, M = ...
local test, eq, ok, contains, near = H.test, H.eq, H.ok, H.contains, H.near

local E = require("game_env")(H, M)
local SECRET, installGame, slash, output, start = E.SECRET, E.installGame, E.slash, E.output, E.start

H.suite("Engine and window (real data)", function()
    test("skipping by accident: an Undo row on top puts the quests back", function()
        local ns = start()
        local row = ns.UI.rows[1]
        local quests = row.model.step.quests
        row.scripts.OnClick(row, "RightButton")
        ok(ns.Engine.IsIgnored(quests[1].id))
        ok(M.settle())
        ns.UI.Refresh()
        local undo = ns.UI.rows[1]
        eq(undo.model.pill, "UNDO")
        contains(undo.model.title, quests[1].name)
        ok(ns.UI.rows[2].model.current or ns.UI.rows[3].model.current, "the route follows below it")
        M.clock = M.clock + 5000
        undo.scripts.OnClick(undo, "LeftButton")
        ok(not ns.Engine.IsIgnored(quests[1].id), "back in the plan")
        ok(M.settle())
        ok(ns.UI.rows[1].model.pill ~= "UNDO", "the Undo row is gone")
        -- left alone, the row goes away after two minutes; the quest stays under Quests
        ns.UI.rows[1].scripts.OnClick(ns.UI.rows[1], "RightButton")
        ok(M.settle())
        M.clock = M.clock + 121000
        ns.UI.Refresh()
        ok(ns.UI.rows[1].model.pill ~= "UNDO")
    end)

    test("an item in the bags that starts a quest: said once, then planned with a Start step", function()
        local bag = {}
        local ns = start()
        M.set("C_Container", {
            GetContainerNumSlots = function(b) return b == 0 and 16 or 0 end,
            GetContainerItemID = function(b, slot) return b == 0 and bag[slot] or nil end,
            GetContainerItemQuestInfo = function(b, slot)
                if b == 0 and bag[slot] == 1307 then return { isQuestItem = true, questID = 123, isActive = false } end
                return { isQuestItem = false }
            end,
        })
        local function listed(id)
            for name, list in pairs(ns.Engine.view.plan.lists) do
                for _, e in ipairs(list) do if e.id == id then return name, e.reason end end
            end
        end
        local function inRoute(id)
            for i, key in ipairs(ns.Engine.view.plan.order) do if key == "P:" .. id then return i end end
        end
        ok(not inRoute(123), "without the item: The Collector is not planned")
        -- the item drops
        bag[3] = 1307
        M.fire("BAG_UPDATE_DELAYED")
        ok(M.settle())
        contains(table.concat(M.printed, "\n"), "Gold Pickup Schedule in your bags starts a quest: |cffffd100The Collector|r")
        local at = inRoute(123)
        ok(at or listed(123) == "skipped", "planned, or left out by the usual value check: " .. tostring((listed(123))))
        if at then
            local step = ns.Engine.view.plan.steps[at]
            eq(step.fromBag, 1307)
            eq(ns.Format.StepTitle(step), "Start: The Collector")
            contains(ns.Format.StepDetail(step), "Gold Pickup Schedule in your bags")
            if at == 1 then
                local followed = ns.Engine.view.plan.steps[2]
                ok(ns.UI.rows[2].model.guided and not ns.UI.rows[1].model.guided, "the next step carries the way and the distance")
                ok(followed and not followed.fromBag)
            end
        end
        -- said once: more bag changes do not repeat it
        local n = #M.printed
        M.fire("BAG_UPDATE_DELAYED")
        bag[4] = 2589
        M.fire("BAG_UPDATE_DELAYED")
        ok(M.settle())
        local again = 0
        for i = n + 1, #M.printed do if M.printed[i]:find("Gold Pickup Schedule", 1, true) then again = again + 1 end end
        eq(again, 0, "not said twice")
        -- the quest data names the quest when the game does not
        eq(ns.Data.QuestsStartedByItem(1307), { 123 })
    end)

    test("the Skip button on the current step; a turned-in quest is no longer 'skipped'", function()
        local ns = start()
        local row = ns.UI.rows[1]
        ok(row.model.current and row.skip:IsShown(), "the current step has a Skip button")
        ok(not ns.UI.rows[2].skip:IsShown(), "other rows do not")
        local id = row.model.step.quests[1].id
        row.skip.scripts.OnClick(row.skip, "LeftButton")
        ok(ns.Engine.IsIgnored(id))
        ok(M.settle())
        M.clock = M.clock + 5000
        M.fire("QUEST_TURNED_IN", id, 100, 0)
        ok(not ns.Engine.IsIgnored(id), "done: taken off the skipped list")
        ok(M.settle())
        -- every drawn row has an icon or a rank, never a text label
        for _, r in ipairs(ns.UI.rows) do
            if r:IsShown() and r.model and not r.model.section then ok(r.model.icon or r.model.rank, "row has an icon") end
        end
    end)

    test("XP buffs are read from the game, applied to the plan, and announced before they end", function()
        local output = function() return table.concat(M.printed, "\n") end
        local ns = start()
        eq(ns.Engine.view.xpBonus, 0)
        local questXP
        for _, s in ipairs(ns.Engine.view.plan.steps) do
            if s.kind == "turnin" and s.xpSource ~= "game" and s.xp > 0 then questXP = questXP or { s.quests[1].id, s.xp } end
        end
        local auras = {
            { name = "Mana Regen", spellId = 1, applications = 0, expirationTime = 0 },
            { name = "Well-Rested", spellId = 429959, applications = 5, expirationTime = M.clock / 1000 + 3600 },
            { name = "Hearty Stew", spellId = 777001, applications = 0, expirationTime = M.clock / 1000 + 1800 },
        }
        M.set("C_UnitAuras", { GetAuraDataByIndex = function(_, i) return auras[i] end })
        M.set("C_Spell", { GetSpellDescription = function(id)
            return id == 777001 and "Well fed. Experience gained is increased by 3%." or "Restores mana."
        end })
        local messages = {}
        M.set("UIErrorsFrame", { AddMessage = function(_, text) messages[#messages + 1] = text end })
        local total, list = ns.Game.GetXPBuffs()
        near(total, 0.08, 1e-9, "5 stacks of the sleeping bag, 3% from food")
        eq(#list, 2)
        eq(ns.Game.XPBonusFromText("Increases experience gained by 10% for 1 hour."), 0.10)
        eq(ns.Game.XPBonusFromText("Grants 15% bonus experience from kills."), 0.15)
        eq(ns.Game.XPBonusFromText("Increases Stamina by 10."), nil)
        M.clock = M.clock + 5000
        M.fire("UNIT_AURA", "player")
        ok(M.settle())
        near(ns.Engine.view.xpBonus, 0.08, 1e-9)
        for _, s in ipairs(ns.Engine.view.plan.steps) do
            if s.kind == "turnin" and s.quests[1].id == questXP[1] then eq(s.xp, math.floor(questXP[2] * 1.08 + 1e-6), "quest XP carries the bonus") end
        end
        contains(LevelScoutFrame.logText.text, "+8% XP")
        -- in combat the buffs cannot be read: the last answer is kept
        M.set("InCombatLockdown", function() return true end)
        eq(ns.Game.GetXPBuffs(), nil)
        near(ns.Engine.XPBonus(), 0.08, 1e-9)
        -- reminders: nothing early; food at 3 minutes, the sleeping bag at 10; once each
        eq(#ns.Engine.CheckBuffs(), 0)
        M.clock = M.clock + (1800 - 170) * 1000
        local shown = ns.Engine.CheckBuffs()
        eq(#shown, 1)
        contains(shown[1], "Hearty Stew (+3% XP) ends in 3 min")
        contains(output(), "Hearty Stew (+3% XP) ends in")
        eq(#messages, 1, "also shown on screen")
        contains(LevelScoutFrame.status.text, "Hearty Stew")
        eq(#ns.Engine.CheckBuffs(), 0, "not repeated")
        M.clock = M.clock + (1800 - 420) * 1000
        local bag = ns.Engine.CheckBuffs()
        eq(#bag, 1)
        contains(bag[1], "Well-Rested (+5% XP) ends in 10 min")
        M.set("InCombatLockdown", function() return false end)
    end)

    test("an XP buff that was used before and is now missing is pointed out", function()
        local output = function() return table.concat(M.printed, "\n") end
        local ns = start()
        local auras = { { name = "Hearty Stew", spellId = 777001, applications = 0, expirationTime = M.clock / 1000 + 600 } }
        M.set("C_UnitAuras", { GetAuraDataByIndex = function(_, i) return auras[i] end })
        M.set("C_Spell", { GetSpellDescription = function() return "Experience gained is increased by 3%." end })
        local messages = {}
        M.set("UIErrorsFrame", { AddMessage = function(_, text) messages[#messages + 1] = text end })
        M.clock = M.clock + 5000
        M.fire("UNIT_AURA", "player")
        ok(M.settle())
        eq(ns.Engine.view.missingBuffs, {})
        eq(LevelScoutCharDB.seenBuffs[777001].name, "Hearty Stew")
        SlashCmdList.LEVELSCOUT("buffs")
        contains(output(), "[777001] Hearty Stew")
        contains(output(), "+3% XP")
        -- the buff runs out
        auras = {}
        M.clock = M.clock + 5000
        M.fire("UNIT_AURA", "player")
        ok(M.settle())
        contains(output(), "Hearty Stew has ended (+3% XP lost).")
        eq(#messages, 1)
        eq(ns.Engine.view.xpBonus, 0)
        contains(LevelScoutFrame.status.text, "No Hearty Stew (+3% XP)")
        M.fire("UNIT_AURA", "player")
        eq(#messages, 1, "said once")
        -- eaten again: the note goes
        auras = { { name = "Hearty Stew", spellId = 777001, applications = 0, expirationTime = M.clock / 1000 + 1800 } }
        M.clock = M.clock + 5000
        M.fire("UNIT_AURA", "player")
        ok(M.settle())
        ok(not LevelScoutFrame.status.text:find("No Hearty", 1, true))
        -- reminders can be switched off for one buff: nothing before it ends, when it ends, or while it is missing
        eq(ns.Engine.BuffReminders(), { { spellId = 777001, name = "Hearty Stew", bonus = 0.03, remind = true } })
        ns.Engine.SetBuffReminder(777001, false)
        eq(LevelScoutCharDB.mutedBuffs, { [777001] = true })
        M.clock = M.clock + (1800 - 100) * 1000
        eq(#ns.Engine.CheckBuffs(), 0, "no warning before it ends")
        local before = #messages
        auras = {}
        M.clock = M.clock + 5000
        M.fire("UNIT_AURA", "player")
        ok(M.settle())
        eq(#messages, before, "no 'has ended' message")
        ok(not LevelScoutFrame.status.text:find("Hearty", 1, true), "no missing note")
        eq(ns.Engine.view.xpBonus, 0, "the plan still follows the buff")
        -- and back on
        ns.Engine.SetBuffReminder(777001, true)
        contains(LevelScoutFrame.status.text, "No Hearty Stew (+3% XP)")
        eq(ns.Engine.BuffReminders()[1].remind, true)
    end)

    test("resting in a tavern re-plans; ordinary drain from kills does not", function()
        local ns = start()
        local rested = 0
        M.set("GetXPExhaustion", function() return rested end)
        M.clock = M.clock + 5000
        M.fire("UPDATE_EXHAUSTION")
        eq(#M.timers, 0, "no change")
        rested = 3000
        M.fire("UPDATE_EXHAUSTION")
        eq(#M.timers, 1, "the pool appeared")
        ok(M.settle())
        eq(ns.Engine.view.restedPool, 3000)
        contains(LevelScoutFrame.logText.text, "Rested")
        rested = 2900
        M.clock = M.clock + 5000
        M.fire("UPDATE_EXHAUSTION")
        eq(#M.timers, 0, "a kill's worth of drain is already in the plan")
        rested = 0
        M.fire("UPDATE_EXHAUSTION")
        eq(#M.timers, 1, "ran dry")
        ok(M.settle())
    end)

    test("/ls and /levelscout are the commands", function()
        installGame()
        eq({ SLASH_LEVELSCOUT1, SLASH_LEVELSCOUT2, SLASH_LEVELSCOUT3 }, { "/ls", "/levelscout", nil })
    end)

    test("the minimap button shows and hides the window, can be dragged and switched off", function()
        local ns = installGame()
        E.noSearch(ns)
        M.set("LevelScoutDB", nil)
        M.set("LevelScoutCharDB", nil)
        local minimap = M.widget("Frame")
        function minimap:GetWidth() return 140 end
        function minimap:GetCenter() return 500, 400 end
        function minimap:GetEffectiveScale() return 1 end
        M.set("Minimap", minimap)
        M.login()
        ok(M.settle())
        local b = LevelScoutMinimapButton
        ok(b and b:IsShown(), "the button is there")
        local _, anchor, _, x, y = b:GetPoint(1)
        eq(anchor, minimap)
        near(math.sqrt(x * x + y * y), 75, 0.01, "on the minimap's edge")
        ok(LevelScoutFrame:IsShown())
        b.scripts.OnClick(b, "LeftButton")
        ok(not LevelScoutFrame:IsShown(), "click hides the window")
        b.scripts.OnClick(b, "LeftButton")
        ok(LevelScoutFrame:IsShown(), "and shows it again")
        b.scripts.OnEnter(b)
        ok(#M.tooltip.lines >= 3)
        -- drag to straight right of the minimap
        M.set("GetCursorPosition", function() return 700, 400 end)
        b.scripts.OnDragStart(b)
        b.scripts.OnUpdate(b)
        b.scripts.OnDragStop(b)
        eq(b.scripts.OnUpdate, nil)
        near(LevelScoutDB.window.minimapAngle, 0, 0.01)
        local _, _, _, x2, y2 = b:GetPoint(1)
        near(x2, 75, 0.01); near(y2, 0, 0.01)
        ns.MinimapButton.SetShown(false)
        ok(not b:IsShown())
        eq(LevelScoutDB.window.minimapHidden, true)
    end)

    test("a stop shared by two quests' items names the mob and lists every item on its own line", function()
        local ns = start()
        local F = ns.Format
        local shared = { kind = "work", action = "collect", target = "Dirty Knucklebones", from = "Crushridge Ogre", kills = 41,
            travel = 60, seconds = 2040, xp = 6300, loc = { map = 1429, mx = 40, my = 60 },
            quests = { { id = 500, name = "Crushridge Bounty" }, { id = 540, name = "Preserving Knowledge" } },
            parts = { { quest = 500, label = "Dirty Knucklebones", have = 2, total = 9, need = 7 },
                { quest = 540, label = "Recovered Tome", have = 0, total = 5, need = 5 } } }
        eq(F.StepTitle(shared), "Kill Crushridge Ogre")
        local detail, lines = F.StepDetail(shared)
        eq(lines, 3)
        local l1, l2, l3 = detail:match("^(.-)\n(.-)\n(.-)$")
        eq({ l1, l2 }, { "Dirty Knucklebones 2/9", "Recovered Tome 0/5" })
        contains(l3, "about 41 kills")
        contains(l3, "35 min")
        -- one item only: as before, one line
        local single = { kind = "work", action = "collect", target = "Recovered Tome", from = "Crushridge Ogre", kills = 41,
            travel = 0, seconds = 600, quests = { { id = 540, name = "Preserving Knowledge" } },
            parts = { { quest = 540, label = "Recovered Tome", have = 0, total = 5, need = 5 } } }
        eq(F.StepTitle(single), "Collect Recovered Tome x5")
        eq(select(2, F.StepDetail(single)), 1)
        -- in the window the shared row is taller, and nothing else moves
        shared.loc = ns.Geo.Loc(1429, 40, 60) -- a real place, so the row can show how far it is
        ns.Engine.view.plan.steps = { shared, single }
        ns.UI.state.tab, ns.UI.state.scroll = "route", 0
        ns.UI.Refresh()
        local models = {}
        for _, m in ipairs(ns.UI.state.models) do if m.step then models[#models + 1] = m end end
        eq(models[1].title, "Kill Crushridge Ogre")
        eq(models[1].lines, 3)
        eq(models[1].h - models[2].h, 10 + 2 * 13, "current-row height plus two extra lines")
        contains(ns.UI.rows[1].detail.text, "Recovered Tome 0/5")
        -- the live distance sits on the last line, so the item lines stay aligned
        local first, second, third = ns.UI.rows[1].detail.text:match("^(.-)\n(.-)\n(.-)$")
        eq({ first, second }, { "Dirty Knucklebones 2/9", "Recovered Tome 0/5" })
        ok(third:find(" yd", 1, true) or third:find("here", 1, true), "distance on the last line: " .. third)
        contains(third, "about 41 kills")
        -- a one-line row keeps the distance in front
        ok(not ns.UI.rows[2].detail.text:find("\n", 1, true))
    end)

    test("turning a quest in re-plans; bursts of events plan once", function()
        local ns = start()
        local before = ns.Engine.view.updated
        M.clock = M.clock + 5000
        for _ = 1, 5 do M.fire("QUEST_TURNED_IN", 33, 100, 0) end
        eq(#M.timers, 1, "one replan scheduled for the burst")
        ok(M.settle())
        ok(ns.Engine.view.updated > before)
        eq(ns.Engine.view.status, "ready")
    end)

    test("resizing: the corner grip changes width and list height, and both are saved", function()
        local ns = start()
        local function shown()
            local n = 0
            for _, r in ipairs(ns.UI.rows) do if r:IsShown() then n = n + 1 end end
            return n
        end
        local before = shown()
        ns.UI.Resize(420, 600)
        eq(LevelScoutDB.window.width, 420)
        eq(LevelScoutDB.window.listH, 600)
        ok(shown() >= before, "a taller list shows at least as many rows")
        eq(ns.UI.rows[1].width, 420, "rows follow the width")
        ns.UI.Resize(10, 10)
        ok(LevelScoutDB.window.width >= 260 and LevelScoutDB.window.listH >= 80, "clamped to a usable minimum")
        ok(shown() >= 1 and shown() <= before)
        ns.UI.Resize(5000, 5000)
        ok(LevelScoutDB.window.width <= 640 and LevelScoutDB.window.listH <= 900, "and to a maximum")
        -- dragging the grip: 50 right and 40 down from where the button went down
        local grip = LevelScoutFrame.grip
        ns.UI.Resize(330, 300)
        local cx, cy = 500, 500
        GetCursorPosition = function() return cx, cy end
        LevelScoutFrame.GetEffectiveScale = function() return 1 end
        grip.scripts.OnMouseDown(grip)
        cx, cy = 550, 460
        grip.scripts.OnUpdate(grip, 0.02)
        eq(LevelScoutDB.window.width, 380)
        eq(LevelScoutDB.window.listH, 340)
        grip.scripts.OnMouseUp(grip)
        cx, cy = 900, 100
        grip.scripts.OnUpdate(grip, 0.02)
        eq(LevelScoutDB.window.width, 380, "nothing moves after the button is released")
        LevelScoutDB.window.collapsed = true
        ns.UI.Refresh()
        ok(not grip:IsShown(), "no grip on the collapsed window")
    end)
end)
