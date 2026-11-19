-- core/Cost.lua: the numbers behind the planner. Pure Lua: no game API.
-- XP scaling, mob XP, kill time by level difference, kills needed for drops, pace lookup.

local _, ns = ...

local Cost = {}
ns.Cost = Cost

local floor, ceil, sqrt, max, min = math.floor, math.ceil, math.sqrt, math.max, math.min

Cost.RED_QUEST = 5            -- a quest this many levels above the player shows red in the log: later
Cost.SOLO_CUTOFF = 4          -- mobs this many levels above the player wait for later
Cost.GROUP_CUTOFF = 6         -- the same for elite mobs, which are fought in a group
Cost.ELITE_GROUP = 3          -- members assumed for an elite quest when the real group is smaller
Cost.ELITE_KILL_FACTOR = 2.5  -- an elite takes this many times a normal mob's fight (an assumption)
-- A dungeon run, with no measurements to go by: a fixed part plus time and kills per boss.
Cost.DUNGEON_BASE_SECONDS, Cost.DUNGEON_BOSS_SECONDS = 900, 360
Cost.DUNGEON_MIN_SECONDS, Cost.DUNGEON_MAX_SECONDS = 1800, 7200
Cost.DUNGEON_BASE_KILLS, Cost.DUNGEON_BOSS_KILLS = 20, 12
Cost.DUNGEON_GROUP = 5

--- Seconds and kills assumed for one full run of a dungeon with this many bosses.
function Cost.DungeonRun(bosses)
    bosses = bosses or 5
    local seconds = Cost.DUNGEON_BASE_SECONDS + Cost.DUNGEON_BOSS_SECONDS * bosses
    seconds = max(Cost.DUNGEON_MIN_SECONDS, min(Cost.DUNGEON_MAX_SECONDS, seconds))
    return seconds, Cost.DUNGEON_BASE_KILLS + Cost.DUNGEON_BOSS_KILLS * bosses
end
Cost.INTERACT_SECONDS = 8     -- accepting or turning in a quest
Cost.RESPAWN_SECONDS = 300    -- a mob is back about this long after it dies
Cost.SINGLE_SPAWN_WAIT = 60   -- a named, single-spawn target is often dead when you arrive

-- An escort: an NPC walked somewhere, or kept alive through a scripted fight (Data flag
-- "escort"). An assumption, not a measurement. The way from its giver to where it ends is
-- travel like any other. This is what the escort adds: the NPC walks slower than you run,
-- there are ambushes, and the NPC may be out with another player when you arrive.
Cost.ESCORT_SECONDS = 300
-- Escorts whose NPC must be caught on its way: the wait on top, on average, by quest id.
-- The Gizelton Caravan sets out about once an hour, and the two quests are about half an
-- hour apart (warcraft.wiki.gg). Arriving at a random time: half an hour.
Cost.ESCORT_WAIT = { [5821] = 1800, [5943] = 1800 }

--- Seconds an escort quest's escort takes, and the wait for its NPC among them.
function Cost.EscortSeconds(questId)
    local wait = Cost.ESCORT_WAIT[questId] or 0
    return Cost.ESCORT_SECONDS + wait, wait
end

Cost.DEFAULT_COUNT = { kill = 8, item = 6, object = 4, event = 1, other = 1 }
Cost.DEFAULT_PACE = { c = 30, i = 25, o = 25, e = 120, x = 60, r = 7 }

-- XP to go from a level to the next (the classic table). Forever may differ: the planner
-- scales it by what the game says the current level needs (see Cost.LevelUps).
local XP_TO_LEVEL = { 400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900, 14400, 16000, 17700,
    19400, 21300, 23200, 25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400, 50800, 54500, 58600, 62800,
    67100, 71600, 76100, 80800, 85700, 90700, 95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200,
    147500, 153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800 }

--- XP still to earn before each of the next `count` level-ups, counted from now:
--- { to the next level, to the one after, ... }. `xp` and `xpMax` are the game's figures for
--- the current level (optional). Stops at `maxLevel`.
function Cost.LevelUps(level, xp, xpMax, count, maxLevel)
    local out = {}
    local own = XP_TO_LEVEL[level]
    if not own or (maxLevel and level >= maxLevel) then return out end
    local scale = (type(xpMax) == "number" and xpMax > 0) and xpMax / own or 1
    local total = max(1, own * scale - ((type(xp) == "number" and xp > 0) and xp or 0))
    for d = 1, count or 3 do
        out[d] = total
        local nextLevel = level + d
        local need = XP_TO_LEVEL[nextLevel]
        if not need or (maxLevel and nextLevel >= maxLevel) then break end
        total = total + need * scale
    end
    return out
end

--- XP earned from (fromLevel, fromXP) to (level, xp), by the classic table; nil when a level is
--- not in it. Negative when the second is the earlier.
function Cost.XPGained(fromLevel, fromXP, level, xp)
    if type(fromLevel) ~= "number" or type(level) ~= "number" then return nil end
    if level < fromLevel then
        local back = Cost.XPGained(level, xp, fromLevel, fromXP)
        return back and -back or nil
    end
    local total = (xp or 0) - (fromXP or 0)
    for l = fromLevel, level - 1 do
        local need = XP_TO_LEVEL[l]
        if not need then return nil end
        total = total + need
    end
    return total
end

--- Share of a quest's base XP awarded at this level (classic rule: full within 5 levels).
function Cost.QuestXPFactor(questLevel, playerLevel)
    local diff = playerLevel - questLevel
    if diff <= 5 then return 1 end
    if diff == 6 then return 0.8 end
    if diff == 7 then return 0.6 end
    if diff == 8 then return 0.4 end
    if diff == 9 then return 0.2 end
    return 0.1
end

local function grayLevel(pl)
    if pl <= 5 then return 0 end
    if pl <= 39 then return pl - floor(pl / 10) - 5 end
    if pl <= 59 then return pl - floor(pl / 5) - 1 end
    return pl - 9
end

local function zeroDifference(pl)
    if pl < 8 then return 5 elseif pl < 10 then return 6 elseif pl < 12 then return 7 elseif pl < 16 then return 8
    elseif pl < 20 then return 9 elseif pl < 30 then return 11 elseif pl < 40 then return 12
    elseif pl < 45 then return 13 elseif pl < 50 then return 14 elseif pl < 55 then return 15
    elseif pl < 60 then return 16 end
    return 17
end

-- Classic group rule: a kill's XP gets a bonus for 3 or more members and is then shared.
-- With members of the same level each gets total / members.
local GROUP_BONUS = { 1, 1, 1.166, 1.3, 1.4 }

--- Share of a kill's XP one member gets in a group of `members` (1 = solo). Assumes the
--- others are of similar level and close enough to share. A raid shares without a bonus.
function Cost.GroupXPFactor(members)
    members = floor(members or 1)
    if members <= 1 then return 1 end
    return (GROUP_BONUS[members] or 1) / members
end

Cost.GROUP_FIGHT_SHARE = 0.7 -- share of a solo kill cycle that is fighting and recovering

--- How much of the solo time per kill a group of `members` needs. An assumption, not a
--- measurement: the fighting and recovery part of the cycle (70%) is split between the
--- members, the walking and looting part (30%) is not. Two members: 0.65; five: 0.44.
function Cost.GroupKillFactor(members)
    members = floor(members or 1)
    if members <= 1 then return 1 end
    return (1 - Cost.GROUP_FIGHT_SHARE) + Cost.GROUP_FIGHT_SHARE / members
end

--- XP for one kill (classic formula), doubled while rested, shared in a group of `members`.
--- Elites give double.
function Cost.MobXP(playerLevel, mobLevel, rested, members, elite)
    if not mobLevel or mobLevel <= 0 then return 0 end
    local base = playerLevel * 5 + 45
    local xp
    if mobLevel >= playerLevel then
        xp = base * (1 + 0.05 * min(mobLevel - playerLevel, 4))
    elseif mobLevel <= grayLevel(playerLevel) then
        xp = 0
    else
        xp = base * (1 - (playerLevel - mobLevel) / zeroDifference(playerLevel))
    end
    if rested then xp = xp * 2 end
    if elite then xp = xp * 2 end
    return floor(xp * Cost.GroupXPFactor(members) + 0.5)
end

--- Seconds per kill in a camp (fight, recovery, walk to the next mob), by level difference.
function Cost.KillSeconds(base, diff)
    if diff <= -3 then return base * 0.75 end
    if diff <= 0 then return base end
    if diff == 1 then return base * 1.2 end
    if diff == 2 then return base * 1.45 end
    return base * 1.8
end

--- Kills to plan for when `items` must drop at chance `rate`: the 70th percentile of the
--- negative binomial (normal approximation), so a plan is not thrown off by ordinary bad luck.
function Cost.KillsForItems(items, rate)
    if items <= 0 then return 0 end
    rate = max(0.01, min(1, rate or 1))
    if rate >= 1 then return items end
    local mean = items / rate
    local sd = sqrt(items * (1 - rate)) / rate
    return ceil(mean + 0.524 * sd)
end

--- Players' typical pace at a level: seconds per kill (c), item (i), object (o), event (e),
--- other (x) and run speed (r). Each value comes from the nearest level band that has it.
function Cost.Pace(world, level)
    local table_ = (world and world.pace) or {}
    local band = floor((level or 1) / 5)
    local out = {}
    for key, default in pairs(Cost.DEFAULT_PACE) do
        local value
        for d = 0, 12 do
            local lower, upper = table_[band - d], table_[band + d]
            value = (lower and lower[key]) or (upper and upper[key])
            if value then break end
        end
        out[key] = value or default
    end
    return out
end
