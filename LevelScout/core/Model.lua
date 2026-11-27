-- core/Model.lua: turns one quest into what the planner routes: where it is picked up and
-- turned in, where each remaining objective is done, how long that takes and what it pays.
-- Pure Lua: reads ns.Data only.

local _, ns = ...

local Model = {}
ns.Model = Model

local Geo, Cost, Learn = ns.Geo, ns.Cost, ns.Learn
local ceil, max = math.ceil, math.max

local MAX_DROP_SOURCES = 12

local function entitySpots(kind, id)
    local Data = ns.Data
    local e = (kind == "npc" and Data.GetNpc(id)) or (kind == "object" and Data.GetObject(id)) or nil
    return e and e.spots or {}, e
end

-- Where a quest giver or turn-in stands: Forever-observed spots first, then the NPC's or
-- object's own. Prefers a spot on the quest's zone map, close to `near`.
local function giverLoc(observed, givers, zoneMap, near)
    local name
    local pool = observed
    if #pool == 0 then
        pool = {}
        for _, g in ipairs(givers) do
            local spots, e = entitySpots(g.kind, g.id)
            if e and #spots > 0 then
                name = name or e.name
                for _, s in ipairs(spots) do pool[#pool + 1] = s end
            end
        end
    else
        for _, g in ipairs(givers) do
            local _, e = entitySpots(g.kind, g.id)
            if e then name = e.name; break end
        end
    end
    if #pool == 0 then return nil, name end
    local best, bestScore
    for _, s in ipairs(pool) do
        local loc = Geo.Loc(s.map, s.x, s.y)
        local score = (s.map == zoneMap) and 0 or 5000
        local d = near and Geo.Dist(near, loc)
        score = score + (d or (near and 20000 or 0))
        if not best or score < bestScore then best, bestScore = loc, score end
    end
    return best, name
end

local function mobLevel(npc)
    if not npc or (npc.minLevel or 0) <= 0 then return nil end
    return (npc.minLevel + max(npc.maxLevel or 0, npc.minLevel)) / 2
end

local function isElite(npc) return npc ~= nil and npc.rank >= 1 and npc.rank <= 3 end
Model.MobLevel, Model.IsElite = mobLevel, isElite

-- An event or other objective that only a player capture lists (QuestieDB and CMaNGOS list
-- none for the quest) and that nobody saw done. On Forever it is nearly always the talk or the
-- delivery at the turn-in ("Deliver X to Y", "Speak with Y"), now and then an escort that ends
-- there: it is taken as part of the turn-in, and the quest is planned as a talk.
local function partOfTurnin(q, o)
    return #o.ids == 0 and o.countSource == "ForeverDB" and (o.kind == "event" or o.kind == "other")
        and #(q.spots[o.index] or {}) == 0
end

-- Nothing to do but walk and talk: no objectives, or only ones that are part of the turn-in.
local function talkOnly(q)
    for _, o in ipairs(q.objectives) do
        if not partOfTurnin(q, o) then return false end
    end
    return true
end

Model.CONFIRM_DEPTH = 8 -- how many follow-ups on a quest is confirmed by the one after it

local function unseen(q) return q.flags.unseen == true and q.xp == nil end

-- Does a follow-up that cannot be had without this quest show that it exists: a quest that
-- needs it (all of its prerequisites, or this one alone), seen in Forever itself or shown by
-- its own follow-up in turn? Kept per quest record once the index is built.
local shownCache = setmetatable({}, { __mode = "k" })
local function shownByFollowUp(q, depth)
    local got = shownCache[q]
    if got ~= nil then return got end
    local Data = ns.Data
    if not Data.IsIndexBuilt() then return false end
    shownCache[q] = false -- (a loop in the data ends here)
    local found = false
    if depth < Model.CONFIRM_DEPTH then
        for _, id in ipairs(Data.GetFollowUps(q.id)) do
            local f = Data.GetQuest(id)
            local needs = false
            if f then
                for _, pre in ipairs(f.preAll) do if pre == q.id then needs = true end end
                if #f.preAny == 1 and f.preAny[1] == q.id then needs = true end
            end
            if needs and (not unseen(f) or shownByFollowUp(f, depth + 1)) then found = true; break end
        end
    end
    shownCache[q] = found
    return found
end

--- True when nothing shows the quest exists in Forever: no ForeverDB player has seen it,
--- Questie's player traces have no reward for it, and no quest that needs it is confirmed
--- (a follow-up seen in Forever shows that the quest before it exists too, up to
--- CONFIRM_DEPTH links back). QuestieDB carries such quests over from other versions of the
--- game (for example Season of Discovery's Duskwood missions).
function Model.Unconfirmed(q)
    return unseen(q) and not shownByFollowUp(q, 0)
end

--- The level the quest can be taken at. Most Forever-only quests have none in the data (0):
--- then it is taken to be 4 below the quest's own level, so a red quest (Cost.RED_QUEST or
--- more above us) cannot be taken yet, as the game's grey "!" says; or the lowest level a
--- player was seen completing it at, when that is lower.
function Model.MinLevel(q)
    if (q.minLevel or 0) > 0 or (q.level or 0) <= 0 then return q.minLevel or 0 end
    local guess = max(1, q.level - Cost.RED_QUEST + 1)
    local low = q.lowestLevelSeen
    if low and low > 0 and low < guess then guess = low end
    return guess
end

--- Build the model of one quest for this character.
--- ctx = { level, xpBonus (0.05 = +5% from buffs), pace, drops, dropBias (own drop counts and what they say about each data source, see ns.Learn; optional), near (location), log = { [questId] = log entry },
---         tagOf = function(questId) -> "dungeon"|"raid"|"elite"|nil (optional) }
--- The model has `taken` when the quest is in the log and has not failed.
--- Returns nil for an unknown quest. `status` is "ok", or why the quest is not routed:
---   "dungeon"   dungeon or raid quest (planned only under its dungeon, or once it is complete:
---               then only its turn-in is left)
---   "group"     elite quest, when ctx.routeElite is off and the quest is not taken (otherwise it
---               is routed, `elite` set)
---   "escort"    escort quest, when ctx.routeEscort is off and it is not taken, or failed in the log
---               whatever the option (otherwise it is routed; its escort stop has escort = true)
---   "later"     needs a higher level (`needLevel`; a red quest only when not taken)
---   "excluded"  repeatable, daily, weekly or seasonal
---   "unconfirmed" no player data shows the quest exists in Forever (see Model.Unconfirmed)
---   "item"      starts from an item
---   "unlocated" a giver, turn-in or objective has no known location (`detail`)
function Model.Build(questId, ctx)
    local Data = ns.Data
    local q = Data.GetQuest(questId)
    if not q then return nil end
    local entry = ctx.log and ctx.log[questId] or nil
    -- Taken: in the log and not failed (a failed quest has to be abandoned and taken again).
    local taken = entry ~= nil and not entry.isFailed
    local m = { id = questId, name = q.name, level = q.level, minLevel = q.minLevel, zone = q.zone,
        inLog = entry ~= nil, taken = taken or nil, tasks = {}, status = "ok", quest = q, lv = ctx.level }

    local tag = ctx.tagOf and ctx.tagOf(questId) or nil
    if tag == nil then tag = Data.GetQuestTag(questId) end
    -- A dungeon's own quests are planned only when that dungeon is what is being planned.
    local D = ctx.dungeon
    local inDungeon = D ~= nil and D.questSet[questId] == true
    if inDungeon then
        m.dungeon, m.elite, tag = true, true, nil
    elseif tag == "dungeon" or tag == "raid" then
        -- Finished already (in the log, complete): only the turn-in is left, and that is a walk
        -- like any other. It is planned wherever the turn-in is (`leftover`).
        if entry and entry.isComplete then
            m.leftover, tag = true, nil
        elseif tag == "dungeon" and talkOnly(q) then
            -- Nothing in it is done inside: a talk on the way (the paladins' Test of
            -- Righteousness starts with one in Ironforge, filed as a dungeon quest). Planned
            -- like any other.
            tag = nil
        else
            m.status = "dungeon"
            return m
        end
    end
    local asElite = false
    if tag == "elite" then
        if ctx.routeElite then
            m.elite = true
        elseif taken then
            m.elite, asElite = true, true
        else
            m.status = "group"
        end
    end
    -- An escort is listed, not routed, unless ctx.routeEscort is on. Complete in the log, only
    -- its turn-in is left: planned like any other. (Decided below, once its stops are known.)
    m.escort = (q.flags.escort and not inDungeon and not (entry and entry.isComplete)) or nil
    -- How many group members the quest's drops are split between: for a quest in the log the
    -- game says who else is on it; otherwise everyone in the group is assumed to take it.
    ctx.share = nil
    if entry and ctx.partyOn then
        local others = ctx.partyOn(questId)
        if others then ctx.share, m.share = 1 + others, 1 + others end
    end
    -- A taken elite quest is built as with the option on (killTask and Model.Task read
    -- ctx.routeElite). Made after the share above is set: the rest reads it through the proxy.
    if asElite then ctx = setmetatable({ routeElite = true }, { __index = ctx }) end
    -- A red quest (5 or more levels above us) waits, unless it is taken: one in the log is
    -- planned, and its mobs' level is in the kill times. A taken quest whose own targets are
    -- too strong still waits (task.tooHigh below). Once it is complete, only the turn-in is
    -- left and that is planned.
    local shownLevel = (entry and type(entry.level) == "number" and entry.level > 0) and entry.level or q.level
    if shownLevel - ctx.level >= Cost.RED_QUEST and not taken and not (entry and entry.isComplete) then
        m.status, m.needLevel, m.detail = "later", shownLevel - Cost.RED_QUEST + 1, "red quest"
        -- the planner may still take it along when its work is in a camp we visit anyway (not an
        -- escort while escorts are listed only)
        m.red = (not (m.escort and not ctx.routeEscort)) or nil
    end
    if not entry then
        if q.flags.repeatable or q.flags.daily or q.flags.weekly or q.flags.event then m.status = "excluded"; return m end
        if Model.Unconfirmed(q) and not (inDungeon and D.confirmed[questId]) then m.status = "unconfirmed"; return m end
        local minLevel = Model.MinLevel(q)
        if minLevel > ctx.level then
            m.status, m.needLevel = "later", max(m.needLevel or 0, minLevel)
            m.blocked = true -- cannot be accepted yet
        end
    end

    -- Reward: the game's own figure for a quest in the log, else data XP scaled for our level.
    local base, source, low, high = Data.GetQuestXP(questId)
    local questLevel = q.level > 0 and q.level or q.minLevel
    local factor = Cost.QuestXPFactor(questLevel, ctx.level)
    m.questLevel = questLevel
    if entry and type(entry.rewardXP) == "number" and entry.rewardXP > 0 then
        m.xp, m.xpSource = entry.rewardXP, "game"
    else
        -- XP buffs (sleeping bag, food) raise it; the game's own figure above already has them.
        local bonus = 1 + (ctx.xpBonus or 0)
        m.xp, m.xpSource = math.floor((base or 0) * factor * bonus), source
        if low then m.xpLow, m.xpHigh = math.floor(low * factor * bonus), math.floor(high * factor * bonus) end
    end

    -- Pickup and turn-in.
    if not entry then
        local itemStart, onlyItems = false, #q.starters > 0
        for _, g in ipairs(q.starters) do
            if g.kind == "item" then itemStart = true else onlyItems = false end
        end
        -- A quest that only an item starts has no giver to walk to. The data's start spots are
        -- where players happened to start it (where the item dropped): not a place to accept it
        -- without the item. It is planned only while the item is in the bags.
        if not onlyItems then
            m.pickup, m.pickupName = giverLoc(q.spots.start, q.starters, q.zone, ctx.near)
        end
        -- An item in the bags that starts the quest: it is started where we stand, any time.
        local bagItem = itemStart and ctx.bagQuests and ctx.bagQuests[questId]
        if bagItem and not m.pickup and (ctx.start or ctx.near) then
            local item = Data.GetItem(bagItem)
            m.pickup, m.fromBag = ctx.start or ctx.near, bagItem
            m.pickupName = (item and item.name or "an item") .. " in your bags"
        end
        if not m.pickup and inDungeon and not itemStart then
            m.pickup, m.pickupName, m.inside = D.loc, (m.pickupName or "inside") .. " (in " .. D.name .. ")", true
        end
        if not m.pickup then
            m.status = itemStart and "item" or "unlocated"
            m.detail = itemStart and "starts from an item" or "no known quest giver"
            return m
        end
    end
    m.turnin, m.turninName = giverLoc(q.spots.finish, q.finishers, q.zone, m.pickup or ctx.near)
    if not m.turnin and inDungeon then
        m.turnin, m.turninName = D.loc, (m.turninName or "inside") .. " (in " .. D.name .. ")"
    end
    if not m.turnin and entry and not m.pickup then
        -- (in the log: no pickup is planned, but the turn-in is guessed at the giver, as before it was taken)
        local onlyItems = #q.starters > 0
        for _, g in ipairs(q.starters) do if g.kind ~= "item" then onlyItems = false end end
        if not onlyItems then
            local giver, giverName = giverLoc(q.spots.start, q.starters, q.zone, ctx.near)
            if giver then m.turnin, m.turninName, m.turninGuessed = giver, giverName, true end
        end
    end
    if not m.turnin then
        if m.pickup then
            m.turnin, m.turninName, m.turninGuessed = m.pickup, m.pickupName, true
        else
            m.status, m.detail = "unlocated", "no known turn-in"
            return m
        end
    end
    if entry and entry.isComplete then return m end
    if inDungeon then
        -- A class quest done only partly inside (D.partial: the objectives done there): it is
        -- accepted before the run and kept in the log after it, the rest being done elsewhere.
        -- Its turn-in is not planned here (`keep`: placed at the door, not shown as a step) and
        -- its reward is not counted. Once its part inside is done it has nothing to do here.
        local inside = D.partial and D.partial[questId]
        if inside then
            local left = false
            for _, i in ipairs(inside) do
                local live = entry and entry.objectives and entry.objectives[i]
                if not (live and live.finished) then left = true end
            end
            if not left then m.status = "dungeon"; return m end
            -- (`must`: it pays nothing here, but taking it in is why it is in this plan: the
            -- planner never drops it as slow)
            m.keep, m.must, m.xp, m.xpLow, m.xpHigh = true, true, 0, nil, nil
            m.turnin, m.turninName, m.turninGuessed = D.loc, D.name, nil
        end
        -- Everything the quest asks for happens during one run. All of the dungeon's quests
        -- share that run: it is one stop, done once.
        m.tasks[1] = { kind = "dungeon", key = "D" .. D.id, loc = D.loc, label = D.name, elite = true,
            kills = 1, cycle = D.seconds, xpPerKill = D.xp, wait = 0, index = 1, need = 1 }
        return m
    end

    local pace = ctx.pace
    local near = m.pickup or ctx.near
    for i, o in ipairs(q.objectives) do
        local live = entry and entry.objectives and entry.objectives[i] or nil
        if not (live and live.finished) then
            local need, guessed
            if live and type(live.need) == "number" and live.need > 0 then
                need = live.need - (live.have or 0)
            elseif o.count then
                need = o.count
            else
                need, guessed = Cost.DEFAULT_COUNT[o.kind] or 1, true
            end
            if need > 0 then
                local task = Model.Task(q, o, need, ctx, pace, near)
                task.index, task.need, task.countGuessed = i, need, guessed
                task.have = live and live.have or nil
                task.total = live and live.need or o.count
                if task.tooHigh then
                    m.blocked = true -- its targets really are too strong
                    if m.status == "ok" then m.status = "later" end
                    m.needLevel = max(m.needLevel or 0, task.tooHigh)
                elseif not task.loc and not task.skip then
                    if m.status == "ok" or m.status == "later" then
                        m.status, m.detail = "unlocated", "objective " .. i .. " has no known location"
                    end
                end
                if not task.skip then m.tasks[#m.tasks + 1] = task end
                -- The quest's next objective is looked for near this one: when its targets
                -- live in several camps, the camp we are already in is the one to use.
                if task.loc then near = task.loc end
            end
        end
    end
    -- An escort takes its script's time at one stop: its event, else its first stop. Kills asked
    -- for there are fought during it, so the stop takes the escort's time at least, not that
    -- time plus the kills.
    if m.escort then
        local hasEvent, at = false, nil
        for _, o in ipairs(q.objectives) do if o.kind == "event" then hasEvent = true end end
        for _, t in ipairs(m.tasks) do if not hasEvent or t.kind == "event" then at = t; break end end
        if at then
            local seconds, wait = Cost.EscortSeconds(questId)
            if taken then seconds, wait = seconds - wait, 0 end -- (the NPC was caught when it was taken)
            at.escort = true
            if at.kills and at.cycle then
                at.wait = max(at.wait or 0, seconds - at.kills * at.cycle)
            else
                at.seconds = seconds
            end
            local failed = entry ~= nil and not taken -- (in the log, failed: the NPC died)
            if m.status == "ok" and (failed or not (ctx.routeEscort or taken)) then
                m.status = "escort"
                if failed then
                    m.detail = "failed: abandon it and take it again"
                elseif wait > 0 then
                    m.detail = "the NPC must be caught on its way: about " .. math.floor(wait / 60 + 0.5) .. " minutes' wait"
                end
            end
        else
            m.escort = nil -- its escort is done: the rest is planned as any quest
        end
    end
    return m
end

-- One kill option: kill `kills` of npc. Returns a task or nil (no spawn data).
local function killTask(npc, spots, kills, ctx, pace, near)
    local loc, inCamp, total = Geo.Cluster(spots, near)
    if not loc then return nil end
    local level = mobLevel(npc)
    local diff = level and (level - ctx.level) or 0
    -- An elite is fought in a group: the one we are in, or an assumed one of three.
    local elite = isElite(npc) and ctx.routeElite or false
    local members = elite and max(ctx.group or 1, Cost.ELITE_GROUP) or (ctx.group or 1)
    local solo = Cost.KillSeconds(pace.c, math.floor(diff + 0.5)) * (elite and Cost.ELITE_KILL_FACTOR or 1)
    local cycle = solo * Cost.GroupKillFactor(members)
    -- More kills than the camp holds: the rest come only as fast as the camp respawns.
    if kills > inCamp then
        local slow = max(cycle, Cost.RESPAWN_SECONDS / inCamp)
        cycle = (inCamp * cycle + (kills - inCamp) * slow) / kills
    end
    local t = { loc = loc, kills = kills, cycle = cycle, elite = elite or nil, members = members,
        lv = ctx.level, inCamp = inCamp, paceC = pace.c, bonus = ctx.xpBonus or 0,
        xpPerKill = math.floor(Cost.MobXP(ctx.level, level and math.floor(level + 0.5), false, members, elite)
            * (1 + (ctx.xpBonus or 0)) + 0.5),
        mobLevel = level, wait = (total == 1) and Cost.SINGLE_SPAWN_WAIT or 0, soloCycle = solo }
    local cutoff = elite and Cost.GROUP_CUTOFF or Cost.SOLO_CUTOFF
    if level and diff >= cutoff then t.tooHigh = math.ceil(level - cutoff + 1) end
    return t
end

--- A kill task's seconds per kill and XP per kill at another player level (the route levels
--- us up as it goes: the same mob then dies faster and pays less).
function Model.KillAt(t, level)
    if not t.lv or level == t.lv or not t.mobLevel then return t.cycle, t.xpPerKill or 0 end
    local at = t.at and t.at[level]
    if not at then
        local diff = math.floor(t.mobLevel - level + 0.5)
        local cycle = Cost.KillSeconds(t.paceC, diff) * (t.elite and Cost.ELITE_KILL_FACTOR or 1) * Cost.GroupKillFactor(t.members)
        if t.kills > t.inCamp then
            local slow = max(cycle, Cost.RESPAWN_SECONDS / t.inCamp)
            cycle = (t.inCamp * cycle + (t.kills - t.inCamp) * slow) / t.kills
        end
        local xp = math.floor(Cost.MobXP(level, math.floor(t.mobLevel + 0.5), false, t.members, t.elite) * (1 + t.bonus) + 0.5)
        at = { cycle, xp }
        t.at = t.at or {}
        t.at[level] = at
    end
    return at[1], at[2]
end

--- A quest's reward at another player level (it shrinks once the quest is far below us).
function Model.QuestXPAt(m, level)
    if not m.lv or level == m.lv or not m.questLevel then return m.xp or 0 end
    local was = Cost.QuestXPFactor(m.questLevel, m.lv)
    local now = Cost.QuestXPFactor(m.questLevel, level)
    if now == was then return m.xp or 0 end
    return math.floor((m.xp or 0) * now / was)
end

--- The task for one objective: { kind, key, loc, label, seconds or (kills, cycle, xpPerKill) }.
--- `key` identifies the camp: tasks of different quests with the same key are done together.
function Model.Task(q, o, need, ctx, pace, near)
    local Data = ns.Data
    local observed = q.spots[o.index] or {}
    local kind = o.kind
    if partOfTurnin(q, o) then return { kind = kind, label = q.name, skip = true } end
    if kind == "kill" then
        local spots, first = {}, nil
        for _, id in ipairs(o.ids) do
            local npc = Data.GetNpc(id)
            if npc then
                first = first or npc
                if #observed == 0 then for _, s in ipairs(npc.spots) do spots[#spots + 1] = s end end
            end
        end
        if #observed > 0 then spots = observed end
        -- "Kill credit" from an NPC that is friendly to us is not a fight (a trainer, a
        -- fishing spot marker): something is done at that NPC instead.
        local own = ctx.side == "a" and "A" or (ctx.side == "h" and "H" or nil)
        if first and own and first.friendly:find(own, 1, true) then
            return { kind = "other", key = "p" .. q.id .. ":" .. o.index, loc = Geo.Cluster(spots, near),
                label = q.text or first.name, seconds = need * pace.x }
        end
        local t = first and killTask(first, spots, need, ctx, pace, near) or nil
        if not t then return { kind = "kill", label = first and first.name or "?" } end
        t.kind, t.key, t.label, t.npc = "kill", "m" .. (o.ids[1] or 0), first.name, first.id
        return t
    elseif kind == "object" then
        local obj = Data.GetObject(o.ids[1] or 0)
        local spots = #observed > 0 and observed or (obj and obj.spots or {})
        local loc = Geo.Cluster(spots, near)
        return { kind = "object", key = "o" .. (o.ids[1] or 0), loc = loc, label = obj and obj.name or "?",
            seconds = need * pace.o }
    elseif kind == "item" then
        local item = Data.GetItem(o.ids[1] or 0)
        local label = item and item.name or "?"
        if q.sourceItem and q.sourceItem == o.ids[1] then return { kind = "item", label = label, skip = true } end
        local best, bestScore, tooHigh
        local function offer(t, seconds)
            local score = seconds * ((t.loc.map == q.zone) and 1 or 1.5)
            -- An item that drops from several kinds of mob is taken from the kind another
            -- planned quest already has us killing: one camp, one set of kills for both.
            if ctx.campKeys and t.key and ctx.campKeys[t.key] then score = score * 0.5 end
            if not best or score < bestScore then best, bestScore = t, score end
        end
        local drops = {}
        for _, s in ipairs(Data.ObjectiveSources(o)) do
            if s.kind == "npc" then
                -- the database rate, moved towards what this player has seen drop (ctx.drops)
                local rate, learned = Learn.DropRate(s.rate, ctx.drops, o.ids[1] or 0, s.id, s.source, ctx.dropBias)
                drops[#drops + 1] = { kind = s.kind, id = s.id, rate = rate, source = s.source, learned = learned or nil }
            elseif s.kind == "object" then
                local obj = Data.GetObject(s.id)
                local loc = obj and Geo.Cluster(obj.spots, near)
                if loc then
                    local seconds = need * pace.o / math.max(0.05, math.min(1, s.rate or 1))
                    offer({ kind = "item", key = "o" .. s.id, loc = loc, label = label, from = obj.name, seconds = seconds }, seconds)
                end
            elseif s.kind == "vendor" then
                local npc = Data.GetNpc(s.id)
                local loc = npc and Geo.Cluster(npc.spots, near)
                if loc then
                    offer({ kind = "buy", key = "v" .. s.id, loc = loc, label = label, from = npc.name,
                        seconds = Cost.INTERACT_SECONDS }, 60)
                end
            end
        end
        table.sort(drops, function(a, b) return (a.rate or 0) > (b.rate or 0) end)
        for i = 1, math.min(#drops, MAX_DROP_SOURCES) do
            local s = drops[i]
            local npc = Data.GetNpc(s.id)
            if npc and #npc.spots > 0 and (ctx.routeElite or not isElite(npc)) then
                -- In a group, quest drops go to the members in turn (the round-robin rule in
                -- findings.md section 5): the group needs our count once per member on the quest.
                local group = ctx.group or 1
                if isElite(npc) then group = max(group, Cost.ELITE_GROUP) end
                local share = math.min(ctx.share or group, group)
                local kills = s.rate and Cost.KillsForItems(need * share, s.rate) or nil
                if not kills then -- unknown rate: players' typical seconds per collected item
                    kills = ceil(need * share * pace.i * 1.3 / Cost.KillSeconds(pace.c, 0))
                end
                local t = killTask(npc, npc.spots, kills, ctx, pace, near)
                if t then
                    if t.tooHigh then
                        tooHigh = math.min(tooHigh or 99, t.tooHigh)
                    else
                        t.kind, t.key, t.label, t.from, t.npc, t.rate = "item", "m" .. s.id, label, npc.name, npc.id, s.rate
                        t.rateLearned = s.learned
                        offer(t, t.kills * t.cycle + t.wait)
                    end
                end
            end
        end
        if best then return best end
        if #observed > 0 then
            return { kind = "item", key = "p" .. q.id .. ":" .. o.index, loc = Geo.Cluster(observed, near), label = label,
                seconds = need * pace.i }
        end
        return { kind = "item", label = label, tooHigh = tooHigh }
    end
    -- events, reputation and anything else: only routable where Forever players saw it done
    local loc = Geo.Cluster(observed, near)
    return { kind = kind, key = "p" .. q.id .. ":" .. o.index, loc = loc, label = ns.Data.GetQuest(q.id).text or q.name,
        seconds = (kind == "event") and pace.e or pace.x }
end
