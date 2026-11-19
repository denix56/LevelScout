-- Tracker.lua: collects the samples ns.Learn learns from. It is told about two things by the
-- Engine (it listens to nothing itself and never touches the game API):
--
--   Tracker.OnLog   the quest log after a change. An objective whose count went up is a "tick".
--                   The time since that objective's previous tick, in the same area, is one pace
--                   sample: seconds per kill, per collected item or per object.
--   Tracker.OnKill  a mob died (PARTY_KILL). While an item is still wanted by a quest in the log,
--                   every kill of a mob that drops it is one try, and a tick of the item right
--                   after such a kill is one drop.
--   Tracker.OnPlan  a new plan is shown. When the step that was first is finished, the time it
--                   really took is written to the step log next to the time the plan gave it.
--                   The step-time model (ns.Learn.AddStep) learns from each line; the log
--                   itself shows how far off the plans are, by kind of step.
--   Tracker.OnMove  where the player is, about once a second. A stretch of steady travel on the
--                   ground gives one sample of the travel speed (yards per second), which
--                   replaces the typical run speed in the planner (ns.Learn.AddSpeed). It also
--                   keeps the active clock, and sees when the step being timed is reached.
--
-- Every duration measured here is active time (Tracker.Active): seconds in which the player
-- moved, fought, flew or rode, and pauses of up to IDLE_GRACE seconds (talking, looting,
-- reading a quest). Standing still for longer (away, tabbed out) is not counted. A step's time
-- is split at the moment its place is first reached: the travel there, and the work at it.
--
-- Pace and drops count solo play only: in a group, kills are quicker and drops are shared out.
-- Nothing is learned for elites. If the client does not report kills (or hides which mob died), no drop
-- rates are learned and the database rates stay in use.

local _, ns = ...
local Data, Cost, Learn, Geo, Model = ns.Data, ns.Cost, ns.Learn, ns.Geo, ns.Model

local Tracker = {}
ns.Tracker = Tracker

Tracker.PROGRESS_GAP = 240  -- seconds: a longer wait between two ticks is not one stretch of work
Tracker.AREA_YARDS = 250    -- both ticks must be this close together
Tracker.KILL_WINDOW = 120   -- seconds: an item counts as dropped by a kill at most this long ago
Tracker.KEEP_KILLS = 20     -- recent kills remembered
Tracker.KEEP_STEPS = 300    -- finished steps kept in the step log (the oldest go first)
Tracker.STEP_MAX = 7200     -- seconds: a step that took longer was not played in one go
Tracker.MOVE_STRETCH = 10   -- seconds of steady travel that make one speed sample
Tracker.MOVE_GAP = 3        -- seconds: two positions further apart in time are not one stretch (loading, a stall)
Tracker.MOVE_MIN = 4        -- yards per second: slower is not travelling (standing, walking pace, stuck on something)
Tracker.MOVE_MAX = 20       -- yards per second: faster is not on the ground (the fastest mount makes 14; a flight 30)
Tracker.IDLE_GRACE = 15     -- seconds standing still that still count (talking, looting, reading); longer is idle
Tracker.STILL_YARDS = 1     -- moved less than this between two looks: standing still
Tracker.ARRIVE_WORK = 60    -- yards: a work step's place (a camp) is reached this close to it
Tracker.ARRIVE_TALK = 25    -- yards: an accept's or a turn-in's NPC is reached this close
Tracker.SPLIT_MIN = 5       -- seconds: both parts of a step must be planned at least this long to be learned apart
Tracker.JUMP_YARDS = 250    -- a hop this long and ...
Tracker.JUMP_SPEED = 60     -- ... this fast (yards per second) is a teleport, not travel (Planner.HEARTH: marks the step)
Tracker.JUMP_WINDOW = 60    -- seconds: the two places are at most this far apart in time

local paceStore, dropStore, stepStore, modelStore
local current        -- the step being timed: { key, a0 (active clock at its start), loc, arrived (active
                     -- seconds until its place was reached), kind, action, p, pt, elite, quest, parts, n, d }
local seen = {}      -- ["questId:objective"] = { have, t = time of the last tick, loc = where }
local wantedBy = {}  -- [npcId] = { itemId, ... }: items of open objectives that this mob drops
local kills = {}     -- recent kills, oldest first: { npc = id or false (unknown mob), t = time }
local move           -- the stretch of travel being measured: { t, loc, mounted, yards, seconds } or nil
local idle = 0       -- seconds of standing still past IDLE_GRACE so far (not active)
local look           -- the last look: { t, loc } (for the active clock)
local placed         -- the last place seen: { t, loc } (to tell a jump of position: Planner.HEARTH)
local stillFor = 0   -- seconds standing still up to the last look

--- Start collecting into the saved tables (pace: per character; drops: per account).
function Tracker.Start(pace, drops, steps, model)
    paceStore, dropStore, stepStore, modelStore = pace, drops, steps, model
    seen, wantedBy, kills, current, move = {}, {}, {}, nil, nil
    idle, look, stillFor, placed = 0, nil, 0, nil
end

--- The active clock at `now` (seconds, like Game.Now): the time so far less the time spent
--- standing still beyond IDLE_GRACE. Without looks at the player (Tracker.OnMove) it runs with
--- the real clock.
function Tracker.Active(now) return (now or 0) - idle end

-- Moved, fought, flew? One look about once a second keeps the active clock.
local function keepClock(info)
    local now = info.now
    local prev = look
    look = { t = now, loc = info.loc }
    if not prev then return end
    local dt = now - prev.t
    if dt <= 0 then return end
    local hop = (info.loc and prev.loc) and Geo.Dist(prev.loc, info.loc) or nil
    -- (no position here or before: unknown, counted; blocked: on a flight or a boat, in combat, dead)
    local moving = info.blocked or not hop or hop >= Tracker.STILL_YARDS
    if moving then
        stillFor = 0
    else
        local before = stillFor
        stillFor = stillFor + dt
        if stillFor > Tracker.IDLE_GRACE then idle = idle + (stillFor - math.max(before, Tracker.IDLE_GRACE)) end
    end
end

local function sameStretch(prev, now, loc)
    -- (`now` and prev.t are on the active clock: time standing idle in between does not count)
    if not prev.t or now - prev.t > Tracker.PROGRESS_GAP or now <= prev.t then return false end
    if prev.loc and loc then
        local d = Geo.Dist(prev.loc, loc)
        if not d or d > Tracker.AREA_YARDS then return false end
    end
    return true
end

-- One pace sample from an objective that took `seconds` per count.
local function paceSample(o, seconds, info)
    local base = Cost.Pace(Data.World(), info.level)
    if o.kind == "kill" then
        local npc = Data.GetNpc(o.ids[1] or 0)
        if not npc or Model.IsElite(npc) then return end
        -- "kill credit" from an NPC on our side is not a fight
        local own = info.faction == "Alliance" and "A" or (info.faction == "Horde" and "H" or nil)
        if own and npc.friendly:find(own, 1, true) then return end
        -- the typical time for a mob of this level, so that the sample compares like with like
        local level = Model.MobLevel(npc)
        local diff = level and math.floor(level - info.level + 0.5) or 0
        Learn.AddPace(paceStore, "c", seconds / Cost.KillSeconds(base.c, diff))
    elseif o.kind == "item" then
        Learn.AddPace(paceStore, "i", seconds / base.i)
    elseif o.kind == "object" then
        Learn.AddPace(paceStore, "o", seconds / base.o)
    end
end

-- The mob an item just dropped from: the latest kill of one of its sources. A kill of an
-- unknown mob in between hides the answer, so nothing is counted then.
local function dropSource(itemId, now)
    local item = Data.GetItem(itemId)
    if not item then return nil end
    for i = #kills, 1, -1 do
        local kill = kills[i]
        if now - kill.t > Tracker.KILL_WINDOW or not kill.npc then return nil end
        for _, d in ipairs(item.drops) do
            if d.id == kill.npc then return kill.npc end
        end
    end
end

--- The quest log changed. `log` is ns.Game.GetQuestLog();
--- info = { now, level, solo, faction, loc (ns.Geo location or nil) }.
function Tracker.OnLog(log, info)
    if not paceStore or not info or not info.now then return end
    local now = Tracker.Active(info.now) -- seconds per count are counted in active time
    local nextSeen, wanted, dropped = {}, {}, {}
    for _, entry in ipairs(log or {}) do
        local q = Data.GetQuest(entry.id)
        for i, live in ipairs(entry.objectives or {}) do
            local o = q and q.objectives[i]
            local have = live.have
            if o and type(have) == "number" then
                local key = entry.id .. ":" .. i
                local prev = seen[key]
                local rec = { have = have, t = prev and prev.t or nil, loc = prev and prev.loc or nil }
                if prev and have > prev.have then
                    if info.solo and info.level and sameStretch(prev, now, info.loc) then
                        paceSample(o, (now - prev.t) / (have - prev.have), info)
                    end
                    rec.t, rec.loc = now, info.loc
                    if o.kind == "item" and o.ids[1] then dropped[o.ids[1]] = true end
                elseif prev and have < prev.have then
                    rec.t = nil -- items were lost or handed in: not a stretch of work
                end
                nextSeen[key] = rec
                if o.kind == "item" and o.ids[1] and not live.finished then wanted[o.ids[1]] = true end
            end
        end
    end
    seen = nextSeen
    if info.solo then
        for itemId in pairs(dropped) do -- once per item, however many quests want it
            local npc = dropSource(itemId, info.now)
            if npc then Learn.AddDrops(dropStore, itemId, npc, 0, 1) end
        end
    end
    wantedBy = {}
    for itemId in pairs(wanted) do
        local item = Data.GetItem(itemId)
        for _, d in ipairs(item and item.drops or {}) do
            wantedBy[d.id] = wantedBy[d.id] or {}
            table.insert(wantedBy[d.id], itemId)
        end
    end
end

--- A mob died by our hand. `npcId` is nil when the client would not say which mob it was;
--- info = { now, solo }.
function Tracker.OnKill(npcId, info)
    if not dropStore or not info or not info.now then return end
    if not info.solo then
        kills = {} -- in a group the drops are shared out: nothing to learn from
        return
    end
    kills[#kills + 1] = { npc = npcId or false, t = info.now }
    if #kills > Tracker.KEEP_KILLS then table.remove(kills, 1) end
    for _, itemId in ipairs(npcId and wantedBy[npcId] or {}) do
        Learn.AddDrops(dropStore, itemId, npcId, 1, 0)
    end
end

--- Where the player is now. info = { now, loc (ns.Geo location, or nil when unknown),
--- level, mounted (true|false|nil when the client does not say),
--- blocked = true while this is not travel on the ground under our own power: on a flight or
--- a transport, in combat, dead, swimming, flying, in a vehicle }.
--- Call it about once a second. Each pair of positions is one hop; MOVE_STRETCH seconds of hops
--- in a row that all look like travel (between MOVE_MIN and MOVE_MAX yards per second, without
--- mounting or dismounting) are one speed sample: the path walked over the time it took.
--- Anything else ends the stretch and nothing is learned from it: standing, fighting, a jump in
--- position (teleport, hearthstone, another continent), a flight even where the client does
--- not report it (it is faster than MOVE_MAX).
--- Returns the sample in yards per second when one was taken.
function Tracker.OnMove(info)
    if not paceStore or not info or not info.now then return nil end
    keepClock(info)
    -- a jump of position (the hearthstone, any teleport) marks the step being timed (Planner.HEARTH)
    if ns.Planner and ns.Planner.HEARTH and info.loc then
        local was = placed
        placed = { t = info.now, loc = info.loc }
        if current and was then
            local dt, hop = info.now - was.t, Geo.Dist(was.loc, info.loc)
            if dt > 0 and dt <= Tracker.JUMP_WINDOW and hop and hop > Tracker.JUMP_YARDS and hop / dt > Tracker.JUMP_SPEED then
                current.jumped = true
            end
        end
    end
    -- the step being timed: its place reached for the first time ends its travel part
    if current and not current.arrived and current.loc and info.loc then
        local d = Geo.Dist(current.loc, info.loc)
        local reach = current.kind == "work" and Tracker.ARRIVE_WORK or Tracker.ARRIVE_TALK
        if d and d <= reach then current.arrived = Tracker.Active(info.now) - current.a0 end
    end
    local prev = move
    local loc = (not info.blocked) and info.loc or nil
    if not loc then
        move = nil
        return nil
    end
    local mounted = info.mounted and true or false
    local here = { t = info.now, loc = loc, mounted = mounted, yards = 0, seconds = 0 }
    move = here
    if not prev or prev.mounted ~= mounted then return nil end
    local dt = info.now - prev.t
    if dt <= 0 or dt > Tracker.MOVE_GAP then return nil end
    local hop = Geo.Dist(prev.loc, loc)
    if not hop or hop < Tracker.MOVE_MIN * dt or hop > Tracker.MOVE_MAX * dt then return nil end
    here.yards, here.seconds = prev.yards + hop, prev.seconds + dt
    if here.seconds < Tracker.MOVE_STRETCH then return nil end
    local speed = here.yards / here.seconds
    here.yards, here.seconds = 0, 0
    -- on foot and on a mount are learned apart (the planner costs a walk as one or the other)
    local typical, key
    if mounted then
        local speeds = ((Data.World() or {}).travel or {}).speeds
        typical, key = speeds and speeds.ride or Learn.RIDE_TYPICAL, Learn.RIDE_KEY
    else
        typical, key = Cost.Pace(Data.World(), info.level)[Learn.SPEED_KEY], Learn.SPEED_KEY
    end
    if not typical or typical <= 0 or not Learn.AddSpeed(paceStore, speed / typical, key) then return nil end
    return speed
end

--- The step being timed is given up: nothing is logged for it (planning has stopped: inside
--- an instance, position unknown).
function Tracker.Interrupt()
    current = nil
end

--- The player teleported (the hearthstone's cast went through): the step being timed is marked, so that its
--- time is not taken for travel on foot. Only with Planner.HEARTH.
function Tracker.Teleported()
    if ns.Planner and ns.Planner.HEARTH and current then current.jumped = true end
end

-- Is the timed step done? An accept: the quest is in the log. A turn-in: the quest is completed.
-- Work: every objective it was for is finished. Anything else (the route changed, the quest was
-- skipped or dropped) is not a finished step and is not logged.
local function stepFinished(step, info)
    local log = {}
    for _, entry in ipairs(info.log or {}) do log[entry.id] = entry end
    local completed = info.completed or {}
    if step.kind == "accept" then return log[step.quest] ~= nil or completed[step.quest] == true end
    if step.kind == "turnin" then return completed[step.quest] == true end
    for _, part in ipairs(step.parts) do
        local entry = log[part.quest]
        if not entry then
            if not completed[part.quest] then return false end
        elseif not entry.isComplete then
            local o = entry.objectives and entry.objectives[part.index]
            if not (o and o.finished) then return false end
        end
    end
    return #step.parts > 0
end

--- A plan is shown (nil: none). When its first step is no longer the one being timed and that
--- one is finished, a line goes into the step log:
---   { k = kind ("work"|"accept"|"turnin"), w = action ("kill"|"collect"|"use"|...),
---     p = planned seconds (travel + the step), pt = the travel part, a = seconds it took
---     (active time), at, aw = of those, the travel until its place was first reached and the
---     rest (nil when it was not seen reached), lv = level, g = group size, e = true for a group
---     (elite) step, n = planned kills, d = mob level minus own level when the step started
---     (both may be nil), h = 1 when a teleport was in the step (Planner.HEARTH: the hearthstone, or a jump of
---     position; its travel is not learned) }
--- info = { now, level, group, log = ns.Game.GetQuestLog(), completed = { [questId] = true } }.
function Tracker.OnPlan(plan, info)
    if not stepStore or not info or not info.now then return end
    local key = plan and plan.order and plan.order[1] or nil
    if current and current.key ~= key then
        local took = Tracker.Active(info.now) - current.a0
        if took > 0 and took <= Tracker.STEP_MAX and stepFinished(current, info) then
            local line = { k = current.kind, w = current.action, p = current.p, pt = current.pt,
                a = math.floor(took + 0.5), lv = info.level, g = info.group or 1, e = current.elite,
                n = current.n, d = current.d }
            -- the travel there and the work at it, when its place was reached on the way
            if current.arrived then
                line.at = math.floor(math.min(current.arrived, took) + 0.5)
                line.aw = line.a - line.at
            end
            -- h = 1: a teleport (a hearthstone, a jump of position) was in the step, or the plan had the stone for it
            if current.jumped or current.hearth then line.h = 1 end
            stepStore[#stepStore + 1] = line
            Tracker.Learn(line) -- the step-time model learns from it
            while #stepStore > Tracker.KEEP_STEPS do table.remove(stepStore, 1) end
        end
        current = nil
    end
    local step = key and plan.steps and plan.steps[1]
    if step and not current then
        local parts = {}
        for _, part in ipairs(step.parts or {}) do parts[#parts + 1] = { quest = part.quest, index = part.index } end
        -- the times as planned, before the step-time model's correction: it is fitted against those
        local travel, seconds = step.rawTravel or step.travel or 0, step.rawSeconds or step.seconds or 0
        -- a stop shared by several quests is learned as the kind of work the planner corrected it as
        current = { key = key, a0 = Tracker.Active(info.now), loc = step.loc, kind = step.kind, action = step.workAs or step.action,
            p = math.floor(travel + seconds + 0.5), pt = math.floor(travel + 0.5),
            elite = step.group and true or nil, quest = step.quests and step.quests[1] and step.quests[1].id, parts = parts,
            n = step.kills, d = step.mobLevel and info.level and math.floor(step.mobLevel - info.level + 0.5) or nil,
            hearth = step.hearth and true or nil }
    end
end

--- The step-time model learns from one line of the step log. With its travel and its work
--- timed apart (`at`, `aw`) and both planned at least SPLIT_MIN seconds, each part is one
--- observation of its own: the travel against the planned travel (only the travel factor is
--- in play), the work against the planned work (only the stop's factors). Otherwise the
--- step as a whole.
function Tracker.Learn(line)
    local p, pt = tonumber(line.p) or 0, tonumber(line.pt) or 0
    local at, aw = tonumber(line.at), tonumber(line.aw)
    -- a line with h (a teleport in it): its travel says nothing about walking, only its work is learned
    if line.h then
        if at and aw and pt >= Tracker.SPLIT_MIN and p - pt >= Tracker.SPLIT_MIN and aw > 0 then
            local stop = { k = line.k, w = line.w, p = p - pt, pt = 0, g = line.g, e = line.e, n = line.n, d = line.d }
            return Learn.AddStep(modelStore, Learn.StepFeatures(stop), stop.p, aw)
        end
        return nil
    end
    if at and aw and pt >= Tracker.SPLIT_MIN and p - pt >= Tracker.SPLIT_MIN then
        local travel = { k = line.k, w = line.w, p = pt, pt = pt, g = line.g, e = line.e, n = line.n, d = line.d }
        local stop = { k = line.k, w = line.w, p = p - pt, pt = 0, g = line.g, e = line.e, n = line.n, d = line.d }
        local a = at > 0 and Learn.AddStep(modelStore, Learn.StepFeatures(travel), travel.p, at)
        local b = aw > 0 and Learn.AddStep(modelStore, Learn.StepFeatures(stop), stop.p, aw)
        return a or b
    end
    return Learn.AddStep(modelStore, Learn.StepFeatures(line), line.p, line.a)
end

local function median(list)
    table.sort(list)
    local n = #list
    if n == 0 then return nil end
    return n % 2 == 1 and list[(n + 1) / 2] or (list[n / 2] + list[n / 2 + 1]) / 2
end

--- The step log in numbers: { all = { n, ratio }, byKind = { { name, n, ratio }, ... },
--- travel = { n, ratio }, stop = { n, ratio } }, where ratio is the median of (seconds taken /
--- seconds planned). Kinds: the work actions, and "talk" for accepting and turning in. travel
--- and stop: the two parts of the steps timed apart (the way there, what was done at it).
function Tracker.StepStats()
    local all, groups, names, travel, stop = {}, {}, {}, {}, {}
    for _, s in ipairs(stepStore or {}) do
        if type(s) == "table" and (tonumber(s.p) or 0) > 0 and tonumber(s.a) then
            local pt = tonumber(s.pt) or 0
            if tonumber(s.at) and pt >= Tracker.SPLIT_MIN and not s.h then travel[#travel + 1] = s.at / pt end
            if tonumber(s.aw) and s.p - pt >= Tracker.SPLIT_MIN then stop[#stop + 1] = s.aw / (s.p - pt) end
            local ratio = s.a / s.p
            local name = s.k == "work" and tostring(s.w or "do") or "talk"
            all[#all + 1] = ratio
            if not groups[name] then groups[name] = {}; names[#names + 1] = name end
            table.insert(groups[name], ratio)
        end
    end
    table.sort(names)
    local out = { all = { n = #all, ratio = median(all) }, byKind = {},
        travel = { n = #travel, ratio = median(travel) }, stop = { n = #stop, ratio = median(stop) } }
    for _, name in ipairs(names) do
        out.byKind[#out.byKind + 1] = { name = name, n = #groups[name], ratio = median(groups[name]) }
    end
    return out
end

--- Forget everything learned (this character's pace and step log, the account's drop counts).
function Tracker.Reset()
    for k in pairs(paceStore or {}) do paceStore[k] = nil end
    for k in pairs(dropStore or {}) do dropStore[k] = nil end
    for k in pairs(stepStore or {}) do stepStore[k] = nil end
    for k in pairs(modelStore or {}) do modelStore[k] = nil end
    seen, kills, current, move = {}, {}, nil, nil
end


--- What has been learned, as lines of text for /ls learn. `level` (optional) is the
--- character's level: the travel speed is then given in yards per second as well.
function Tracker.Describe(level)
    local lines = {}
    local names = { c = "kill", i = "collected item", o = "object" }
    for _, key in ipairs({ "c", "i", "o" }) do
        local rec = paceStore and paceStore[key]
        if type(rec) == "table" and (rec.n or 0) > 0 then
            lines[#lines + 1] = string.format("time per %s: %.0f%% of players' typical (%d samples)", names[key],
                Learn.PaceFactor(paceStore, key) * 100, rec.n)
        else
            lines[#lines + 1] = string.format("time per %s: players' typical (no samples yet)", names[key])
        end
    end
    local speed = paceStore and paceStore[Learn.SPEED_KEY]
    if type(speed) == "table" and (tonumber(speed.n) or 0) > 0 then
        local factor = Learn.SpeedFactor(paceStore)
        local typical = level and Cost.Pace(Data.World(), level)[Learn.SPEED_KEY]
        lines[#lines + 1] = string.format("travel speed: %.0f%% of the typical run speed%s (%d samples)", factor * 100,
            typical and string.format(", %.1f yards per second", typical * factor) or "", speed.n)
    else
        lines[#lines + 1] = "travel speed: the typical run speed (no samples yet)"
    end
    local ride = Learn.RideSpeed(paceStore, (((Data.World() or {}).travel or {}).speeds or {}).ride)
    if ride then
        lines[#lines + 1] = string.format("speed on a mount: %.1f yards per second (%d samples); long walks are ridden", ride,
            paceStore[Learn.RIDE_KEY].n)
    else
        lines[#lines + 1] = "speed on a mount: not seen riding yet (every walk is on foot)"
    end
    local drops = {}
    local bias = Learn.SourceBias(dropStore, Data.GetDropRate)
    for key, rec in pairs(dropStore or {}) do
        local itemId, npcId = tostring(key):match("^(%d+):(%d+)$")
        itemId, npcId = tonumber(itemId), tonumber(npcId)
        if itemId and type(rec) == "table" and (tonumber(rec.k) or 0) > 0 then
            local item, npc = Data.GetItem(itemId), Data.GetNpc(npcId)
            local prior, source = Data.GetDropRate(itemId, npcId)
            -- as the planner works it out: the source's correction, then our own counts
            local rate = Learn.DropRate(prior, dropStore, itemId, npcId, source, bias)
            drops[#drops + 1] = string.format("%s from %s: %d in %d kills; database %s, planned with %s",
                item and item.name or ("item " .. itemId), npc and npc.name or ("npc " .. npcId), rec.d or 0, rec.k,
                prior and string.format("%.0f%%", prior * 100) or "unknown",
                rate and string.format("%.0f%%", rate * 100) or "players' typical time")
        end
    end
    table.sort(drops)
    if #drops == 0 then lines[#lines + 1] = "drop rates: no kills counted yet" end
    for _, line in ipairs(drops) do lines[#lines + 1] = line end
    local sources = {}
    for source in pairs(bias) do sources[#sources + 1] = source end
    table.sort(sources)
    for _, source in ipairs(sources) do
        lines[#lines + 1] = string.format("%s drop rates: %d drops where %.1f were expected; its rates are planned at %.0f%%",
            source, bias[source].d, bias[source].x, Learn.SourceFactor(bias, source) * 100)
    end
    local stats = Tracker.StepStats()
    if stats.all.n == 0 then
        lines[#lines + 1] = "plan accuracy: no finished steps timed yet"
    else
        lines[#lines + 1] = string.format("plan accuracy: %d steps took %.0f%% of the planned time (median)",
            stats.all.n, stats.all.ratio * 100)
        for _, g in ipairs(stats.byKind) do
            lines[#lines + 1] = string.format("  %s steps: %.0f%% (%d)", g.name, g.ratio * 100, g.n)
        end
        if stats.travel.n > 0 then
            lines[#lines + 1] = string.format("  getting there: %.0f%% of the planned travel (%d)", stats.travel.ratio * 100, stats.travel.n)
        end
        if stats.stop.n > 0 then
            lines[#lines + 1] = string.format("  at the stop: %.0f%% of the planned time there (%d)", stats.stop.ratio * 100, stats.stop.n)
        end
        lines[#lines + 1] = string.format("  (active time only: standing still for more than %d seconds is not counted)", Tracker.IDLE_GRACE)
    end
    -- the step-time model: what each feature does to the planned time, at a telling value
    local m = modelStore
    if type(m) == "table" and m.v == Learn.STEP_VERSION and (tonumber(m.n) or 0) > 0 and type(m.w) == "table"
        and #m.w == #Learn.STEP_FEATURES then
        local at = { 1, 1, 1, 1, 1, 1, math.log(2), 1, 1 }
        local label = { "any stop", "kill", "collect", "use", "all travel", "elite", "group of 2", "mob 4 levels above", "10 kills" }
        local parts = {}
        for i, name in ipairs(label) do parts[#parts + 1] = string.format("%s x%.2f", name, math.exp(m.w[i] * at[i])) end
        lines[#lines + 1] = string.format("step-time model (%d steps): %s", m.n, table.concat(parts, ", "))
    end
    return lines
end
