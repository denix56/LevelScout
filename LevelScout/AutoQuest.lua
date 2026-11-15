-- AutoQuest.lua: when the player talks to an NPC, accept the quests the shown plan picks up
-- there and hand in the ones it turns in there. Only quests of the plan (ns.Engine.view.plan);
-- every other quest is left to the player. Holding Shift while talking does nothing automatic.
-- A reward to choose is never picked: the reward window stays open for the player.

local _, ns = ...
local Game = ns.Game

local AutoQuest = {}
ns.AutoQuest = AutoQuest

AutoQuest.RETRY = 3 -- seconds before the same quest is opened again (a full log, an accept the game refused)

local db -- LevelScoutDB.autoQuest = { accept = bool, turnin = bool }
local opened = {} -- [questId or title] = the time we last opened it from an NPC window

function AutoQuest.Accepts() return db == nil or db.accept ~= false end
function AutoQuest.TurnsIn() return db == nil or db.turnin ~= false end
function AutoQuest.SetAccept(on) if db then db.accept = on and true or false end end
function AutoQuest.SetTurnIn(on) if db then db.turnin = on and true or false end end

--- The quests the shown plan accepts and turns in, by id and by lower-case title:
--- { accept = { [id|title] = true }, turnin = { [id|title] = true } }.
function AutoQuest.Planned(plan)
    local out = { accept = {}, turnin = {} }
    for _, step in ipairs(plan and plan.steps or {}) do
        local set = (step.kind == "accept" and out.accept) or (step.kind == "turnin" and out.turnin) or nil
        if set then
            for _, q in ipairs(step.quests or {}) do
                if q.id then set[q.id] = true end
                if type(q.name) == "string" then set[q.name:lower()] = true end
            end
        end
    end
    return out
end

local function planned()
    local view = ns.Engine and ns.Engine.view
    return AutoQuest.Planned(view and view.plan)
end

-- Is a quest (an id, and a title as the NPC window shows it) in this set? By id when the
-- client gives one, by title only when it does not.
local function inSet(set, id, title)
    if id then return set[id] == true end
    return type(title) == "string" and set[title:lower()] == true
end

local function active()
    return not Game.ShiftDown()
end

-- Open a quest from an NPC window, at most once every RETRY seconds.
local function open(kind, which, entry)
    local key = entry.id or entry.title or "?"
    local now = Game.Now()
    if opened[key] and now - opened[key] < AutoQuest.RETRY then return false end
    opened[key] = now
    return Game.SelectNpcQuest(kind, which, entry) and true or false
end

--- An NPC window listing quests is open (kind: "gossip" | "greeting"). Opens one quest to
--- hand in (first) or to accept, if the plan has one here. Returns what it opened:
--- "turnin" | "accept" | nil.
function AutoQuest.OnList(kind)
    if not active() then return nil end
    local want = planned()
    local quests = Game.NpcQuests(kind)
    if AutoQuest.TurnsIn() then
        for _, q in ipairs(quests.active) do
            if q.complete and inSet(want.turnin, q.id, q.title) and open(kind, "active", q) then return "turnin" end
        end
    end
    if AutoQuest.Accepts() then
        for _, q in ipairs(quests.available) do
            if inSet(want.accept, q.id, q.title) and open(kind, "available", q) then return "accept" end
        end
    end
    return nil
end

--- The quest frame shows a quest's text (page: "detail" | "progress" | "complete"). Accepts,
--- goes on, or hands in when the plan wants it. Returns true when it acted.
function AutoQuest.OnQuestPage(page)
    if not active() then return false end
    local id, title = Game.ShownQuest()
    local want = planned()
    if page == "detail" then
        return AutoQuest.Accepts() and inSet(want.accept, id, title) and Game.AcceptShownQuest() and true or false
    elseif page == "progress" then
        return AutoQuest.TurnsIn() and inSet(want.turnin, id, title) and Game.ContinueShownQuest() and true or false
    elseif page == "complete" then
        if not (AutoQuest.TurnsIn() and inSet(want.turnin, id, title)) then return false end
        if Game.TakeQuestReward() then return true end
        ns.Print("Pick a reward for |cffffd100%s|r.", tostring(title or id))
    end
    return false
end

local handlers = {
    GOSSIP_SHOW = function() AutoQuest.OnList("gossip") end,
    QUEST_GREETING = function() AutoQuest.OnList("greeting") end,
    QUEST_DETAIL = function() AutoQuest.OnQuestPage("detail") end,
    QUEST_PROGRESS = function() AutoQuest.OnQuestPage("progress") end,
    QUEST_COMPLETE = function() AutoQuest.OnQuestPage("complete") end,
}

--- Called once at login, after ns.Engine.Start (which sets up the saved variables).
function AutoQuest.Start()
    local saved = ns.Engine and ns.Engine.db
    if type(saved) == "table" then
        saved.autoQuest = type(saved.autoQuest) == "table" and saved.autoQuest or {}
        db = saved.autoQuest
    end
    local names = {}
    for name in pairs(handlers) do names[#names + 1] = name end
    Game.Listen(names, function(event, ...) handlers[event](...) end)
end
