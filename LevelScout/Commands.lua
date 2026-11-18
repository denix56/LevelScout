-- Commands.lua: startup and the /ls command (also /levelscout). /ls alone shows or hides the
-- window; the rest are debug commands.

local _, ns = ...
local Data, Game, TomTom, Async = ns.Data, ns.Game, ns.TomTom, ns.Async

local RED, YELLOW, GREY = "|cffff5555", "|cffffcc00", "|cffaaaaaa"

ns.CREDITS = {
    "Data from ForeverDB.net (https://foreverdb.net)",
    "Quest data read at runtime from the QuestieDB addon (https://github.com/Questie/QuestieDB), GPL-3.0",
    "Classic data from CMaNGOS classic-db (https://github.com/cmangos/classic-db), GPL-3.0",
    "LevelScout is free software under the GNU GPL v3.0; see LICENSE, NOTICE.txt and CREDITS.md",
}

local function printStatus()
    local st = Data.status
    if Data.usable then
        ns.Print("data: client build %s, ForeverDB %s (data %s, baked %s); %s", tostring(st.build),
            tostring(st.sources and st.sources.ForeverDB), tostring(st.sources and st.sources.ForeverDBData),
            tostring(st.generated), tostring(st.sources and st.sources.QuestieDB or "no QuestieDB (test records)"))
    else
        ns.Print("%sdata %s: %s|r", RED, tostring(st.state), tostring(st.message))
    end
    for _, note in ipairs(st.notes or {}) do ns.Print("%s%s|r", YELLOW, note) end
    local tt = TomTom.status
    ns.Print("TomTom: %s (version %s)%s", tt.state, tostring(tt.version), tt.message and (" " .. GREY .. tt.message .. "|r") or "")
    for _, note in ipairs(tt.notes or {}) do ns.Print("%s%s|r", YELLOW, note) end
    local job = Async.last and Async.last.index
    if Data.IsIndexBuilt() and job then
        ns.Print("index built: %d quests, %.0f ms of work over %d frames (%.1f s)", Data._index.questCount, job.cpu,
            job.slices, job.wall / 1000)
    else
        ns.Print("index built: %s", tostring(Data.IsIndexBuilt()))
    end
end

local function availabilityContext()
    local ctx = Game.GetPlayerContext()
    ctx.completed = Game.GetCompletedQuests()
    ctx.inLog = {}
    for _, q in ipairs(Game.GetQuestLog()) do ctx.inLog[q.id] = true end
    return ctx
end

local function buildIndex(onDone)
    if Data.IsIndexBuilt() then
        if onDone then onDone() end
        return
    end
    local started = debugprofilestop()
    Async.Run("index", function(checkpoint) return Data.BuildIndex(checkpoint) end, function(ok, index)
        if ok and index then
            ns.Print("indexed %d quests in %.0f ms (spread over frames)", index.questCount, debugprofilestop() - started)
            if onDone then onDone() end
        else
            ns.Print("%sindex build failed: %s|r", RED, tostring(index))
        end
    end)
end

local function describeSource(s)
    local text = s.kind .. ":" .. tostring(s.id)
    local e = (s.kind == "npc" or s.kind == "vendor") and Data.GetNpc(s.id) or (s.kind == "object" and Data.GetObject(s.id))
    if e and e.name then text = text .. " " .. e.name end
    if s.rate then text = text .. string.format(" %.0f%% (%s)", s.rate * 100, tostring(s.source)) end
    return text
end

local function printQuest(id)
    local q = Data.GetQuest(id)
    if not q then
        ns.Print("quest %s: not in LevelScout's data", tostring(id))
        return
    end
    local tag, tagSource = Data.GetQuestTag(id)
    local gameTag, known = Game.GetQuestTag(id)
    local ok, reason = Data.IsAvailable(id, availabilityContext())
    ns.Print("[%d] %s  level %d (min %d)  map %d  tag %s (%s; game: %s)  available %s%s", id, q.name, q.level,
        q.minLevel, q.zone, tostring(tag), tagSource, known and tostring(gameTag) or "not loaded", tostring(ok),
        reason and (" - " .. reason) or "")
    local xp, xpSource, xpLow, xpHigh = Data.GetQuestXP(id)
    ns.Print("  XP %s (%s%s)", tostring(xp), tostring(xpSource),
        xpLow and string.format(", usually %d-%d", xpLow, xpHigh) or "")
    for _, g in ipairs(q.starters) do
        local e = g.kind == "npc" and Data.GetNpc(g.id) or g.kind == "object" and Data.GetObject(g.id) or nil
        ns.Print("  starts at %s %d %s", g.kind, g.id, e and e.name or "")
    end
    if q.text then ns.Print("  %s%s|r", GREY, q.text) end
    for _, o in ipairs(q.objectives) do
        local parts = {}
        for i, s in ipairs(Data.ObjectiveSources(o)) do
            if i > 3 then parts[#parts + 1] = "..."; break end
            parts[#parts + 1] = describeSource(s)
        end
        ns.Print("  obj %d %s x%s (%s) -> %s%s", o.index, o.kind, tostring(o.count), tostring(o.countSource),
            table.concat(parts, ", "), q.spots[o.index] and string.format(" [%d seen spots]", #q.spots[o.index]) or "")
    end
    local follow = Data.GetFollowUps(id)
    if #follow > 0 then ns.Print("  unlocks %s", table.concat(follow, ", ")) end
end

local function printZone(uiMapId)
    local list = Data.QuestsInZone(uiMapId) or {}
    local ctx = availabilityContext()
    local available = 0
    for _, entry in ipairs(list) do
        if Data.IsAvailable(entry.id, ctx) then available = available + 1 end
    end
    ns.Print("map %s: %d quests tied to it, %d available to this character now (any level)",
        tostring(uiMapId), #list, available)
end

local function printLog()
    local log = Game.GetQuestLog()
    ns.Print("quest log: %d / %s", #log, tostring(Game.GetQuestLogCapacity()))
    for _, q in ipairs(log) do
        local parts = {}
        for _, o in ipairs(q.objectives) do
            parts[#parts + 1] = string.format("%s %s/%s", tostring(o.type), tostring(o.have), tostring(o.need))
        end
        ns.Print("  [%d] %s  rewardXP %s  %s", q.id, tostring(q.title), tostring(q.rewardXP), table.concat(parts, "; "))
    end
end

SLASH_LEVELSCOUT1 = "/ls"
SLASH_LEVELSCOUT2 = "/levelscout"
SlashCmdList.LEVELSCOUT = function(msg)
    local cmd, arg = string.match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")
    if cmd == "" or cmd == "show" or cmd == "hide" then
        if ns.UI and ns.UI.IsShown then
            ns.UI.Toggle(cmd == "show" and true or (cmd == "hide" and false or nil))
        else
            printStatus()
        end
    elseif cmd == "status" then
        printStatus()
        local v = ns.Engine and ns.Engine.view
        if v then
            ns.Print("planner: %s%s; waypoint: %s", tostring(v.status), v.message and (" (" .. v.message .. ")") or "", ns.Guide.mode)
        end
    elseif cmd == "buffs" then
        local buffs = Game.ListBuffs()
        if not buffs then ns.Print("buffs cannot be read in combat or in an instance"); return end
        ns.Print("%d buffs; XP bonus counted: +%d%%", #buffs, ns.Engine.XPBonus() * 100 + 0.5)
        for _, b in ipairs(buffs) do
            ns.Print("  [%s] %s%s  %s%s|r", tostring(b.spellId), b.name, b.bonus and string.format("  |cff55ff55+%d%% XP|r", b.bonus * 100 + 0.5) or "",
                GREY, b.description and b.description:sub(1, 90) or "(no description)")
        end
    elseif cmd == "debug" or cmd == "search" then
        if ns.Debug then ns.Debug.Toggle() end
    elseif cmd == "learn" or cmd == "learned" then
        if arg == "reset" then
            ns.Tracker.Reset()
            ns.Engine.ResetMemory()
            ns.Engine.Replan(true)
            ns.Print("forgot the learned pace, travel speed, drop rates, step log and step-time model")
        else
            ns.Print("learned from your play (pace and drops: solo only; /ls learn reset to forget):")
            for _, line in ipairs(ns.Tracker.Describe(ns.Game.GetPlayer().level)) do ns.Print("  %s", line) end
        end
    elseif cmd == "replan" then
        if string.lower(arg or "") == "fresh" then
            ns.Engine.ReplanFresh()
            ns.Print("re-planning from scratch (the shown route is not kept)")
        else
            ns.Engine.Replan(true)
            ns.Print("re-planning")
        end
    elseif cmd == "plan" then
        local v = ns.Engine.view
        if not v.plan then ns.Print("no plan yet (%s)", tostring(v.status)); return end
        ns.Print("%s: %s, %s XP/h", tostring(v.zoneName), ns.Format.PlanSummary(v.plan), ns.Format.Number(v.plan.score))
        for i, step in ipairs(v.plan.steps) do
            if i > 12 then ns.Print("  ... %d more", #v.plan.steps - 12); break end
            ns.Print("  %d. %s%s", i, ns.Format.StepTitle(step), step.loc and step.loc.mx and string.format(" (%.1f, %.1f)", step.loc.mx, step.loc.my) or "")
        end
    elseif cmd == "about" or cmd == "credits" then
        ns.Print("LevelScout %s", ns.version)
        for _, line in ipairs(ns.CREDITS) do ns.Print("  %s", line) end
    elseif not Data.usable then
        ns.Print("data not usable; see /ls status")
    elseif cmd == "quest" then
        printQuest(tonumber(arg))
    elseif cmd == "zone" then
        local uiMapId = tonumber(arg) or Game.GetPosition()
        if not uiMapId then
            ns.Print("could not determine the current map (inside an instance?)")
            return
        end
        buildIndex(function() printZone(uiMapId) end)
    elseif cmd == "log" then
        printLog()
    elseif cmd == "play" then
        if arg == "reset" then
            ns.Play.Reset()
            ns.Print("Play log emptied.")
        else
            for _, line in ipairs(ns.Play.Describe()) do ns.Print(line) end
        end
    elseif cmd == "snapshot" then
        local ok, why = ns.Engine.Snapshot(arg ~= "" and arg:sub(1, 200) or nil)
        if ok then
            ns.Print("Taking a snapshot: planning once more to record what the plan is made from (a few seconds; best while standing still). Chat says when it is saved.")
        else
            ns.Print("No snapshot: %s.", why)
        end
    elseif cmd == "taxi" then
        for _, line in ipairs(ns.FlightMap and ns.FlightMap.Describe() or { "flight map highlight is not loaded" }) do ns.Print(line) end
    elseif cmd == "pos" then
        local uiMapId, x, y = Game.GetPosition()
        ns.Print("uiMapID %s  x %s  y %s", tostring(uiMapId), tostring(x), tostring(y))
    else
        ns.Print("commands: (none) show or hide the window, status, plan, replan [fresh], snapshot [note], play [reset], learn [reset], buffs, debug (search view), quest <id>, zone [uiMapID], log, pos, taxi (flight map highlight), about")
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
    Data.Init(Game.GetPlayerContext())
    TomTom.Check()
    if not Data.usable then
        ns.Print("%s%s|r", RED, tostring(Data.status.message))
    end
    for _, note in ipairs(Data.status.notes or {}) do ns.Print("%s%s|r", YELLOW, note) end
    ns.Engine.Start()
    ns.AutoQuest.Start()
    ns.UI.Start()
end)
