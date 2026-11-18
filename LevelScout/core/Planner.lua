-- core/Planner.lua: plans one zone. Pure Lua: reads ns.Data, ns.Model, ns.Travel only.
--
-- A plan is an ordered list of stops: accept a quest (P), work at a camp (W), turn in (T).
-- Order rules: P before the quest's W stops, W before T, and a follow-up quest's P after its
-- prerequisite's T. Quests that share a camp share one W stop.
--
-- Method:
--   1. Collect the zone's quests this character can do now, plus follow-ups they unlock.
--   2. Add quests one at a time, always the one with the best XP per added second, each stop
--      at its cheapest place in the route.
--   3. Improve: move single stops to better places while the rules allow.
--   4. Search: take a few quests out and put them back in a better way, many times over,
--      keeping what makes the route worth more (see "Search" below).
--   5. Drop quests that pay far less per second than the route as a whole.
--   6. Solve short stretches of the route exactly (see "Exact windows" below).
--   7. Score: the best XP per hour reachable by following the route and leaving at the best
--      moment, counting the trip to the zone.

local _, ns = ...

local Planner = {}
ns.Planner = Planner

local Cost, Model, Geo, Learn = ns.Cost, ns.Model, ns.Geo, ns.Learn
local max, min, floor, huge, abs = math.max, math.min, math.floor, math.huge, math.abs
local insert, remove, sort = table.insert, table.remove, table.sort

Planner.MIN_HORIZON = 3600     -- seconds: a zone is judged on at least this much play (60 minutes),
                               -- so a one-off trip does not decide the ranking
Planner.TAIL_RATIO = 0.6       -- the route's end counts as a slow tail below this share of the peak rate
Planner.PRUNE_RATIO = 0.5      -- drop a quest paying less than this share of the route's rate
Planner.SWITCH_OVERHEAD = 120  -- seconds lost when changing zone (bags, orientation)
Planner.IMPROVE_PASSES = 3
Planner.IMPROVE_GATES = true   -- `improve` without a guard takes back a move that leaves a quest before the level it
                               -- needs (a stop paying XP moved past it); false = as before
Planner.SCORE_GIVE = 0.05      -- a shorter route may cost up to this share of the peak XP per hour
Planner.SEGMENT_MOVES = 3      -- longest run of consecutive stops moved together when improving
Planner.SAME_PLACE_YARDS = 40  -- stops this close are one place: accept everything there at once
Planner.CHAIN_ROUNDS = 4
Planner.ON_THE_WAY_YARDS = 80  -- a quest starting this close to a stop in another zone (in the same camp) is considered too
Planner.PREREQ_DEPTH = 8       -- how far back a dungeon quest's prerequisite chain is followed
Planner.LEVELS_AHEAD = 3        -- level-ups the route is followed through (kills pay less after each;
                                -- quests that need the next level can be planned after it)
Planner.SEARCH_ITERATIONS = 120 -- take-out-and-put-back rounds on a fresh plan (0 = none)
Planner.WARM_START = true      -- start a zone's search from an earlier plan of it when one is given (opts.warm)
Planner.WARM_ROUNDS = 60       -- rounds at most in a search that started warm
Planner.SEARCH_TEMPERATURE = 0.015 -- early rounds may make the route this much worse, to get out of a dead end
Planner.TAIL_WEIGHT = 0.15     -- the search values the whole route's rate this much next to the peak rate
Planner.REGRET_CAP = 600       -- seconds: the most one stop counts as losing when its best place is taken
Planner.VALUE_CACHE = true     -- remember each stop's value and the route's level-up profile (a pure speed-up: same plans)
Planner.NEAR_SCOPE = "search"  -- where NEAR_K applies: "search" = only the repairs inside the search's rounds, "all" = everywhere
Planner.NEAR_K = nil           -- try only the places next to a stop's K nearest route stops (nil or 0 = every place)
Planner.EXACT_WINDOW = 8       -- stops in a row put in their best possible order at a time (0 = none)
Planner.GOAL = "rate"          -- what a route is worth: "rate" = its best XP-so-far / time-so-far (time floored at MIN_HORIZON,
                               -- plus a small tail term); "surplus" = its XP over what the next-best option would have made
                               -- in the same time (max over leaving points of XP(k) - R * time(k); see ctx.altRate)
Planner.ALT_SHARE = 1.0        -- surplus goal: R = ctx.altRate * ALT_SHARE (the share of the best zone's rate the player can get elsewhere)

---------------------------------------------------------------------------------------------
-- Route state
---------------------------------------------------------------------------------------------

local R = {}
R.__index = R

local function newRoute(ctx)
    local self = setmetatable({}, R)
    self.ctx = ctx
    self.travel = ctx.travel
    self.start = { kind = "S", loc = ctx.start, n = 0 }
    self.route = { self.start }
    self.pos = { [self.start] = 1 }
    self.taskNodes = {}   -- key -> W node in use
    self.nodeCache = {}   -- key -> W node ever made (reused across trials)
    self.memo = {}        -- travel seconds between nodes
    self.count = 0
    self.allNodes = { self.start } -- every stop made so far (the start too), for the neighbour lists
    self.nbr = {}         -- node.n -> { list = stops by distance, size = #allNodes when built }
    self.work = 0         -- deterministic CPU proxy: inner-loop steps taken so far (see Search budgets)
    self.version = 0      -- bumped whenever the route's order or any stop's reqs change (R:touch);
                          -- equal versions mean the same route, and a version is never reused for another
    self.vseq = 0         -- the last version handed out
    self.routed = {}      -- quest model -> true
    self.restedBonus = ctx.restedBonus or 0 -- bonus XP the rested pool still pays on kills
    self.level = ctx.level
    self.ups = ctx.levelUps or {}           -- route XP at which each next level is reached
    self.gated = false                      -- is any quest in play that needs a later level?
    -- What finished steps have taught about planned times (ns.Learn's step-time model): one
    -- factor for travel, one for accepting and turning in, one per kind of work (in `fix`).
    -- Every time the search looks at comes from tt, value, service or taskTotals, so the
    -- corrected times decide the order of stops and which quests are worth doing.
    self.travelFactor, self.talk = 1, 1
    local model = ctx.stepModel
    if type(model) == "table" and (tonumber(model.n) or 0) > 0 then
        self.travelFactor, self.talk = Learn.TravelFactor(model), Learn.TalkFactor(model)
        self.fix = { model = model, group = ctx.group or 1, level = ctx.level, memo = {} }
    end
    return self
end

-- The route class and constructor, for ns.Objective, ns.Search and tests.
Planner.Route = R
Planner.NewRoute = newRoute

function R:node(kind, loc, key)
    self.count = self.count + 1
    local node = { kind = kind, loc = loc, key = key, n = self.count }
    local all = self.allNodes
    all[#all + 1] = node
    return node
end

-- Every other stop made so far by straight-line distance from `node` (other continents last,
-- ties by creation number); rebuilt when more stops have been made since.
function R:neighbours(node)
    local all = self.allNodes
    local e = self.nbr[node.n]
    if e and e.size == #all then return e.list end
    local dist, list = {}, {}
    local loc = node.loc
    for i = 1, #all do
        local x = all[i]
        if x ~= node then
            list[#list + 1] = x
            dist[x] = Geo.Dist(loc, x.loc) or huge
        end
    end
    sort(list, function(a, b)
        local da, db = dist[a], dist[b]
        if da ~= db then return da < db end
        return a.n < b.n
    end)
    self.work = self.work + #all
    self.nbr[node.n] = { list = list, size = #all }
    return list
end

-- The insertion places (after which route index, increasing) worth trying within lo..hi for
-- a stop, or a run whose first and last stops are `a` and `b`: the range's edges, the place
-- right after the start, and both sides of each of the K nearest stops that are in the route.
-- Returns nil when every place is to be tried (NEAR_K off, or a short route).
local candSeen, cand = {}, {}
function R:nearCandidates(a, b, lo, hi)
    local K = Planner.NEAR_SCOPE == "all" and Planner.NEAR_K or self.nearK
    local route, pos = self.route, self.pos
    if not K or K <= 0 or hi < lo or #route <= 2 * K + 2 then return nil end
    local n = 0
    local function add(p)
        if p >= lo and p <= hi and not candSeen[p] then
            candSeen[p] = true
            n = n + 1
            cand[n] = p
        end
    end
    add(lo); add(hi); add(1)
    local steps = 0
    for pass = 1, (b and b ~= a) and 2 or 1 do
        local list = self:neighbours(pass == 1 and a or b)
        local hits = 0
        for i = 1, #list do
            steps = steps + 1
            local q = pos[list[i]]
            if q then
                add(q - 1); add(q)
                hits = hits + 1
                if hits >= K then break end
            end
        end
    end
    for i = 1, n do candSeen[cand[i]] = nil end
    -- increasing order (insertion sort: short lists)
    for i = 2, n do
        local v, j = cand[i], i - 1
        while j >= 1 and cand[j] > v do cand[j + 1] = cand[j]; j = j - 1 end
        cand[j + 1] = v
    end
    self.work = self.work + steps
    local out = {}
    for i = 1, n do out[i] = cand[i] end
    return out
end

function R:tt(a, b)
    local k = a.n * 65536 + b.n
    local v = self.memo[k]
    if v == nil then
        v = self.travel:Seconds(a.loc, b.loc) * self.travelFactor
        self.memo[k] = v
    end
    return v
end

-- Version: bumped whenever the route's order or any stop's reqs change.
function R:touch()
    local v = self.vseq + 1
    self.vseq, self.version = v, v
end

-- A stop's reqs are changed only through these three (each touches the version).
function R:addReq(node, req)
    node.reqs[#node.reqs + 1] = req
    node.vc = nil
    self:touch()
end

-- Remove the last req of `quest` from the stop (`all`: every req of it).
function R:dropReq(node, quest, all)
    local reqs = node.reqs
    for k = #reqs, 1, -1 do
        if reqs[k].quest == quest then
            remove(reqs, k)
            if not all then break end
        end
    end
    node.vc = nil
    self:touch()
end

function R:setReqs(node, list)
    node.reqs = list
    node.vc = nil
    self:touch()
end

-- Empty the route (the start stop only) and forget every quest's stops.
function R:clear(candidates)
    for node in pairs(self.pos) do self.pos[node] = nil end
    self.route, self.taskNodes, self.routed = { self.start }, {}, {}
    self:reindex(1)
    for _, m in ipairs(candidates) do m.P, m.T, m.W, m.dependents = nil, nil, nil, nil end
end

function R:reindex(from)
    self:touch()
    local route, pos = self.route, self.pos
    self.work = self.work + (#route - (from or 1) + 1)
    for i = from or 1, #route do pos[route[i]] = i end
end

local ACTION = { kill = "kill", item = "collect", object = "use", buy = "buy", event = "do", other = "do", reputation = "do",
    dungeon = "run" }

-- The learned correction for the work at a stop (ns.Learn's step-time model), remembered per
-- kind of stop: `fix` = { model, group, level, memo } from newRoute.
local ACTION_CODE = { kill = 1, collect = 2, use = 3 }
-- A stop shared by several quests is corrected as its most telling kind of work, whichever
-- quest was added to it first: killing, else collecting, else using.
local KIND_RANK = { kill = 3, item = 2, object = 1 }
local function leading(first, t)
    if not first or (KIND_RANK[t.kind] or 0) > (KIND_RANK[first.kind] or 0) then return t end
    return first
end
local function workFactor(fix, action, elite, mobLevel, lv, kills)
    local d = mobLevel and max(-4, min(4, floor(mobLevel - (lv or fix.level) + 0.5))) or 0
    local n = min(kills or 0, 4095)
    local key = ((n * 16 + d + 4) * 2 + (elite and 1 or 0)) * 4 + (ACTION_CODE[action] or 0)
    local f = fix.memo[key]
    if not f then
        f = Learn.WorkFactor(fix.model, { w = action, e = elite, g = fix.group, d = d, n = n })
        fix.memo[key] = f
    end
    return f
end

-- Work seconds and kill XP of a W node, for all quests sharing it. Kills of one mob count
-- for every quest at once, so a shared camp costs the largest requirement, not the sum.
-- With `lv`, as fought at that player level (the route may have levelled us up by then).
-- With `fix` (the route's, see workFactor), the seconds are corrected by what was learned.
-- The fourth result is the kind of work the stop counts as for that.
local function taskTotals(node, skip, lv, fix)
    local reqs = node.reqs
    local first, elite
    if node.mob then
        local kills, cycle, wait, xp = 0, 0, 0, 0
        for i = 1, #reqs do
            if reqs[i].quest ~= skip then
                local t = reqs[i].task
                local c, x = t.cycle, t.xpPerKill or 0
                if lv and t.lv and lv ~= t.lv then c, x = Model.KillAt(t, lv) end
                kills, cycle, wait, xp = max(kills, t.kills), max(cycle, c), max(wait, t.wait or 0), max(xp, x)
                first, elite = leading(first, t), elite or t.elite
            end
        end
        local seconds = kills * cycle + wait
        if fix and first then
            seconds = seconds * workFactor(fix, ACTION[first.kind], elite, first.mobLevel, lv, kills)
        end
        return seconds, kills * xp, kills, first and ACTION[first.kind]
    end
    local seconds = 0
    for i = 1, #reqs do
        if reqs[i].quest ~= skip then
            local t = reqs[i].task
            seconds = seconds + (t.seconds or 0)
            first, elite = leading(first, t), elite or t.elite
        end
    end
    if fix and first then seconds = seconds * workFactor(fix, ACTION[first.kind], elite, nil, lv, nil) end
    return seconds, 0, 0, first and ACTION[first.kind]
end
Planner.TaskTotals = taskTotals

-- Does this stop need a group (an elite target)?
local function needsGroup(node)
    if node.kind ~= "W" then return false end
    for i = 1, #node.reqs do
        if node.reqs[i].task.elite then return true end
    end
    return false
end

-- The level a stop needs, as level-ups from now (0 = none).
local function gateOf(node)
    if node.kind == "W" then
        local g = 0
        for i = 1, #node.reqs do
            local q = node.reqs[i].quest.gate
            if q and q > g then g = q end
        end
        return g
    end
    -- a red quest is accepted while red; only its work and turn-in wait for its level
    if node.kind == "P" and node.quest and node.quest.acceptEarly then return 0 end
    return node.quest and node.quest.gate or 0
end
Planner.GateOf = gateOf

-- Seconds at a stop and the XP it pays, `d` level-ups into the route.
function R:value(node, skip, d)
    local lv = d > 0 and (self.level + d) or nil
    if not Planner.VALUE_CACHE then
        if node.kind == "W" then return taskTotals(node, skip, lv, self.fix) end
        if node.kind == "T" then
            -- (the turn-in of a quest taken along to the next zone is no stop here: no time)
            local s = node.quest.border and 0 or Cost.INTERACT_SECONDS * self.talk
            return s, lv and Model.QuestXPAt(node.quest, lv) or (node.quest.xp or 0), 0
        end
        if node.kind == "E" then return 0, 0, 0 end -- (the end of a seam route: a place, no stop)
        return Cost.INTERACT_SECONDS * self.talk, 0, 0
    end
    local isW = node.kind == "W"
    if skip and isW then
        -- as if a quest were not there: only a stop that has it differs from the remembered value
        local reqs, has = node.reqs, false
        for i = 1, #reqs do if reqs[i].quest == skip then has = true; break end end
        if has then return taskTotals(node, skip, lv, self.fix) end
    end
    -- (P and T stops never look at `skip`.) Remembered per stop and level; the stop forgets
    -- it when its reqs change (addReq, dropReq, setReqs) and it belongs to one route.
    local c = node.vc
    if not c or c.r ~= self then c = { r = self }; node.vc = c end
    local i = d * 4
    local s = c[i + 1]
    if s then return s, c[i + 2], c[i + 3], c[i + 4] or nil end
    local x, k, a
    if isW then
        s, x, k, a = taskTotals(node, nil, lv, self.fix)
    elseif node.kind == "T" then
        s = node.quest.border and 0 or Cost.INTERACT_SECONDS * self.talk
        x, k = lv and Model.QuestXPAt(node.quest, lv) or (node.quest.xp or 0), 0
    elseif node.kind == "E" then
        s, x, k = 0, 0, 0
    else
        s, x, k = Cost.INTERACT_SECONDS * self.talk, 0, 0
    end
    c[i + 1], c[i + 2], c[i + 3], c[i + 4] = s, x, k, a or false
    return s, x, k, a
end

-- Level-ups reached after each stop: after[i] for route index i.
function R:profile()
    local cache = Planner.VALUE_CACHE
    if cache then -- the route has not changed since one of the two remembered profiles
        local v = self.version
        if self.profV == v then return self.profA end
        if self.anchorV == v then return self.anchorA end
    end
    local route, ups, after = self.route, self.ups, { 0 }
    self.work = self.work + #route
    local xp, d, nextUp, pool = 0, 0, self.ups[1], self.restedBonus
    for i = 2, #route do
        local node = route[i]
        local _, x = self:value(node, nil, d)
        if node.kind == "W" then
            local bonus = min(x, pool)
            pool, x = pool - bonus, x + bonus
        end
        xp = xp + x
        while nextUp and xp >= nextUp do d = d + 1; nextUp = ups[d + 1] end
        after[i] = d
    end
    if cache then
        -- the profile of the route a trial started from is kept apart: the trial's own changes
        -- would push it out, and the next trial starts from that same route again
        if self.version == self.tryV then self.anchorV, self.anchorA = self.version, after
        else self.profV, self.profA = self.version, after end
    end
    return after
end

-- The route index after which we are `gate` level-ups on (nil: the route never gets there).
function R:gateIndex(gate)
    local after = self:profile()
    if Planner.VALUE_CACHE then
        -- level-ups only ever grow along the route: the first index at or past `gate`, by halving
        local lo, hi = 1, #after
        if after[hi] < gate then return nil end
        while lo < hi do
            local mid = floor((lo + hi) / 2)
            if after[mid] >= gate then hi = mid else lo = mid + 1 end
        end
        return lo
    end
    for i = 1, #after do
        if after[i] >= gate then return i end
    end
    return nil
end

-- The route's running totals, stop by stop, for the objective (ns.Objective) and for working out
-- a changed stretch of the route without going over all of it again. Arrays by route index i
-- (1 = the start), valid for this version of the route and `overhead`:
--   T[i]  seconds from the start of the plan (overhead included) after stop i
--   X[i]  XP after stop i (rested bonus included)    P[i]  rested bonus left
--   D[i]  level-ups reached after stop i               OK[i] no stop up to i is before its level
--   BR[i] the best XP per second over a prefix up to i (the score, so far)
-- also firstBad (index of the first stop before its level, or nil) and xpBad (XP before it).
-- The sums are made exactly as R:score makes them.
function R:prefix(overhead)
    local c = self.pc
    if c and c.version == self.version and c.overhead == overhead then return c end
    local route, ups, H = self.route, self.ups, Planner.MIN_HORIZON
    local T, X, P, D, OK, BR = {}, {}, {}, {}, {}, {}
    local t, xp, pool, d, nextUp, ok, br = overhead or 0, 0, self.restedBonus, 0, ups[1], true, 0
    T[1], X[1], P[1], D[1], OK[1], BR[1] = t, 0, pool, 0, true, 0
    local gated, firstBad, xpBad = self.gated, nil, nil
    for i = 2, #route do
        local node = route[i]
        if ok and gated and gateOf(node) > d then ok, firstBad, xpBad = false, i, xp end
        local s, gain = self:value(node, nil, d)
        if node.kind == "W" then
            local bonus = min(gain, pool)
            pool, gain = pool - bonus, gain + bonus
        end
        t = t + self:tt(route[i - 1], node) + s
        xp = xp + gain
        while nextUp and xp >= nextUp do d = d + 1; nextUp = ups[d + 1] end
        if ok and gain > 0 then
            local rate = xp / max(t, H)
            if rate > br then br = rate end
        end
        T[i], X[i], P[i], D[i], OK[i], BR[i] = t, xp, pool, d, ok, br
    end
    self.work = self.work + #route
    c = { version = self.version, overhead = overhead, T = T, X = X, P = P, D = D, OK = OK, BR = BR,
        firstBad = firstBad, xpBad = xpBad, n = #route }
    self.pc = c
    return c
end

-- A quest that sits in the route before the level it needs, or nil.
function R:brokenGate()
    if not self.gated then return nil end
    local route, after = self.route, self:profile()
    for i = 2, #route do
        local node = route[i]
        if gateOf(node) > after[i - 1] then
            if node.kind ~= "W" then return node.quest end
            for _, req in ipairs(node.reqs) do
                if (req.quest.gate or 0) > after[i - 1] then return req.quest end
            end
        end
    end
    return nil
end

function R:service(node)
    if node.kind == "W" then
        if Planner.VALUE_CACHE then return (self:value(node, nil, 0)) end
        return (taskTotals(node, nil, nil, self.fix))
    end
    if node.kind == "S" or node.kind == "E" then return 0 end
    if node.kind == "T" and node.quest.border then return 0 end
    return Cost.INTERACT_SECONDS * self.talk
end

-- The order rules' range for a node: it may go after route index lo..hi. With `i, len`, as
-- if the run route[i .. i + len - 1] were not in the route (indices as they would then be).
-- (No closures in here: it runs tens of thousands of times per plan, and each one was garbage.)
local function orderAt(pos, n, i, len)
    local p = n and pos[n]
    if p and i then
        if p >= i + len then p = p - len elseif p >= i then p = nil end
    end
    return p
end
local function orderRange(self, node, i, len)
    local pos, lo, hi = self.pos, 1, #self.route
    local p
    if i then hi = hi - len end
    if node.kind == "P" then
        local m = node.quest
        local deps, W = m.deps, m.W
        if deps then
            for k = 1, #deps do
                p = orderAt(pos, deps[k].T, i, len); if p and p > lo then lo = p end
            end
        end
        if W then
            for k = 1, #W do
                p = orderAt(pos, W[k], i, len); if p and p - 1 < hi then hi = p - 1 end
            end
        end
        p = orderAt(pos, m.T, i, len); if p and p - 1 < hi then hi = p - 1 end
    elseif node.kind == "W" then
        local reqs = node.reqs
        for k = 1, #reqs do
            local q = reqs[k].quest
            p = orderAt(pos, q.P, i, len); if p and p > lo then lo = p end
            p = orderAt(pos, q.T, i, len); if p and p - 1 < hi then hi = p - 1 end
        end
        -- The dungeon run comes after everything that leads up to it is turned in, so every
        -- dungeon quest can still be accepted before the one run.
        if node.dungeon then
            for m in pairs(self.routed) do
                if not m.dungeon then
                    p = orderAt(pos, m.T, i, len); if p and p > lo then lo = p end
                end
            end
        end
    else
        local m = node.quest
        if not m.dungeon then
            p = orderAt(pos, self.runNode, i, len); if p and p - 1 < hi then hi = p - 1 end
        end
        p = orderAt(pos, m.P, i, len); if p and p > lo then lo = p end
        local W, dependents = m.W, m.dependents
        if W then
            for k = 1, #W do
                p = orderAt(pos, W[k], i, len); if p and p > lo then lo = p end
            end
        end
        if dependents then
            for k = 1, #dependents do
                p = orderAt(pos, dependents[k].P, i, len); if p and p - 1 < hi then hi = p - 1 end
            end
        end
    end
    return lo, hi
end

-- The side of the crossing a stop of a seam route is on (Planner.Plan's opts.seam): its own, set
-- when the route was rebuilt, else that of its quest (a camp: of its first quest; all quests at a
-- camp are on one side, the far side's camps having keys of their own).
local function seamSide(node)
    local s = node.side
    if s then return s end
    local q = node.quest or (node.reqs and node.reqs[1] and node.reqs[1].quest)
    s = q and q.seamSide
    node.side = s
    return s
end

-- Allowed insertion range for a node: it may go after route index lo..hi. With `noGate`, the
-- order rules alone (the level a quest needs is then left to whoever judges the route).
function R:bounds(node, noGate)
    local lo, hi = orderRange(self, node)
    -- a quest that needs a later level: only after the route has got us there
    if self.gated and not noGate then
        local g = gateOf(node)
        if g > 0 then
            local at = self:gateIndex(g)
            if not at then lo = hi + 1 elseif at > lo then lo = at end
        end
    end
    -- Quests taken along to the next zone (Planner.Plan's opts.border) are added after the first
    -- stop, so where we stand now does not move them about, and before the stop the zone is left
    -- after (`cap`); their turn-in of no time may also go right after that stop. When that stop is
    -- the first one, they may go before it.
    local b = self.borderFill
    if b then
        local cap = b.cap and self.pos[b.cap]
        if cap then
            local top = node.kind == "T" and cap or cap - 1
            if top < hi then hi = top end
        end
        local from = min(2, (cap or #self.route + 1) - 1)
        if lo < from then lo = from end
    end
    -- The way across a zone border planned together (Planner.Plan's opts.seam): a stop stays on its
    -- side of the crossing (`cross`: the route index of the last stop before it), and every stop goes
    -- before the place the rest of the path starts at (`endNode`).
    local c = self.cross
    if c then
        if seamSide(node) == "A" then
            if c < hi then hi = c end
        elseif c > lo then
            lo = c
        end
        local e = self.endNode
        if e then
            local pe = self.pos[e] - 1
            if pe < hi then hi = pe end
        end
    end
    return lo, hi
end

-- Where the run route[i .. i + len - 1] may go as a whole (after which index of the route
-- without it): every stop's own order range, intersected. Gates are not looked at.
function R:runBounds(i, len)
    local lo, hi = 1, #self.route - len
    for k = i, i + len - 1 do
        local l, h = orderRange(self, self.route[k], i, len)
        if l > lo then lo = l end
        if h < hi then hi = h end
    end
    return lo, hi
end

-- Move the run route[i .. i + len - 1] to just after index p of the route without it (the
-- convention of `improve`), rewriting `pos` only where stops moved. Returns the version it had.
function R:shift(i, len, p)
    local route, pos = self.route, self.pos
    local v = self.version
    if p == i - 1 then return v end
    local seg = {}
    for k = 1, len do seg[k] = route[i + k - 1] end
    local lo, hi
    if p >= i then -- later: what stood between slides back over the run's old place
        for j = i, p do route[j] = route[j + len] end
        lo, hi = i, p + len
    else
        for j = i + len - 1, p + 1 + len, -1 do route[j] = route[j - len] end
        lo, hi = p + 1, i + len - 1
    end
    for k = 1, len do route[p + k] = seg[k] end
    for j = lo, hi do pos[route[j]] = j end
    self.work = self.work + (hi - lo + 1)
    self:touch()
    return v
end

-- Undo `shift(i, len, p)`; `version` (what shift returned) puts the version back, the route
-- being exactly as it was then.
function R:unshift(i, len, p, version)
    if p == i - 1 then return end
    self:shift(p + 1, len, i - 1)
    if version then self.version = version end
end

-- Cheapest place for a node within lo..hi: returns index to insert after, added travel seconds.
function R:best(node, lo, hi)
    local route = self.route
    local bestP, bestD, second = nil, huge, huge
    local cands = self:nearCandidates(node, nil, lo, hi)
    self.work = self.work + (cands and #cands or (hi - lo + 1))
    if cands then
        for ci = 1, #cands do
            local p = cands[ci]
            local a, b = route[p], route[p + 1]
            local d = self:tt(a, node)
            if b then d = d + self:tt(node, b) - self:tt(a, b) end
            if d < bestD then bestP, bestD, second = p, d, bestD elseif d < second then second = d end
        end
        return bestP, bestD, min(second - bestD, Planner.REGRET_CAP)
    end
    if Planner.VALUE_CACHE then
        -- the same sums with the travel memo read in place (a function call per lookup was a fifth of all CPU)
        local memo, tt, n = self.memo, self.tt, node.n * 1
        for p = lo, hi do
            local a, b = route[p], route[p + 1]
            local an = a.n * 65536
            local d = memo[an + n]
            if d == nil then d = tt(self, a, node) end
            if b then
                local bn = b.n
                local x = memo[n * 65536 + bn]
                if x == nil then x = tt(self, node, b) end
                local y = memo[an + bn]
                if y == nil then y = tt(self, a, b) end
                d = d + x - y
            end
            if d < bestD then bestP, bestD, second = p, d, bestD elseif d < second then second = d end
        end
        return bestP, bestD, min(second - bestD, Planner.REGRET_CAP)
    end
    for p = lo, hi do
        local a, b = route[p], route[p + 1]
        local d = self:tt(a, node)
        if b then d = d + self:tt(node, b) - self:tt(a, b) end
        if d < bestD then bestP, bestD, second = p, d, bestD elseif d < second then second = d end
    end
    -- regret: what this stop loses when its best place is gone (capped; a stop with one
    -- possible place loses the most)
    return bestP, bestD, min(second - bestD, Planner.REGRET_CAP)
end

function R:place(node, p)
    insert(self.route, p + 1, node)
    self:reindex(p + 1)
    local c = self.cross -- (a seam route: one more stop before the crossing)
    if c and seamSide(node) == "A" then self.cross = c + 1 end
    local t = self.touched -- repair log: the stops placed since a search round began
    if t then t[#t + 1] = node end
end

function R:unplace(node)
    local p = self.pos[node]
    remove(self.route, p)
    self.pos[node] = nil
    self:reindex(p)
    local c = self.cross
    if c and p <= c then self.cross = c - 1 end
end

-- Add a quest to the route. Returns added seconds and gained XP, or nil when the order rules
-- leave no place. `undo` (a list) receives what is needed to take the quest out again.
function R:add(m, private, undo)
    local added, gain, regret = 0, m.xp or 0, 0
    m.W = {}
    -- Where each task goes: a stop already in the route (a table) or the key of one to make.
    -- (Two lists of the route's own, used again by every trial: this runs thousands of times a plan.)
    local joinAt, tasks = self.joinAt, m.tasks
    if not joinAt then joinAt = {}; self.joinAt = joinAt end
    local nJoins = #tasks
    for k = 1, nJoins do
        local task = tasks[k]
        local key = private and (task.key .. "#" .. m.id) or task.key
        local node = self.taskNodes[key]
        joinAt[k] = (node and self.pos[node]) and node or key
    end
    -- Stops are created once per quest and reused by every trial, so travel times between
    -- stops are computed once.
    if m.pickup then
        m.nodeP = m.nodeP or self:node("P", m.pickup)
        m.P = m.nodeP
        m.P.quest = m
        local lo, hi = self:bounds(m.P)
        for k = 1, nJoins do
            local at = joinAt[k]
            if type(at) == "table" and self.pos[at] - 1 < hi then hi = self.pos[at] - 1 end
        end
        if lo > hi then m.P = nil; return nil end
        local p, d, g = self:best(m.P, lo, hi)
        self:place(m.P, p)
        undo[#undo + 1] = { "node", m.P }
        added, regret = added + d + Cost.INTERACT_SECONDS * self.talk, regret + g
    end
    for k = 1, nJoins do
        local task, at = tasks[k], joinAt[k]
        local node = type(at) == "table" and at or self.taskNodes[at]
        -- (a task's requirement record is never changed: one per task, made once)
        local req = task.req
        if not req or req.quest ~= m then req = { quest = m, task = task }; task.req = req end
        if node and self.pos[node] and m.gate then
            -- the camp is already in the route: too early for a quest that needs a later level?
            local gateAt = self:gateIndex(m.gate)
            if not gateAt or self.pos[node] <= gateAt then return nil end
        end
        if node and self.pos[node] then
            local s0, x0 = self:value(node, nil, 0)
            self:addReq(node, req)
            local s1, x1 = self:value(node, nil, 0)
            added, gain = added + s1 - s0, gain + x1 - x0
            undo[#undo + 1] = { "req", node }
            -- a T of this quest must come after this node: checked when T is placed
        else
            node = self.nodeCache[at] or self:node("W", task.loc, at)
            self.nodeCache[at] = node
            node.mob = task.kills ~= nil
            self:setReqs(node, { req })
            self.taskNodes[at] = node
            if task.kind == "dungeon" then node.dungeon, self.runNode = true, node end
            local lo, hi = self:bounds(node)
            if lo > hi then return nil end
            local p, d, g = self:best(node, lo, hi)
            self:place(node, p)
            undo[#undo + 1] = { "node", node, at }
            local s, x = self:value(node, nil, 0)
            added, gain, regret = added + d + s, gain + x, regret + g
        end
        m.W[#m.W + 1] = node
    end
    m.nodeT = m.nodeT or self:node("T", m.turnin)
    m.T = m.nodeT
    m.T.quest = m
    local lo, hi = self:bounds(m.T)
    if lo > hi then m.T = nil; return nil end
    local p, d, g = self:best(m.T, lo, hi)
    self:place(m.T, p)
    undo[#undo + 1] = { "node", m.T }
    return added + d + (m.border and 0 or Cost.INTERACT_SECONDS * self.talk), gain, regret + g
end

function R:rollback(m, undo)
    for i = #undo, 1, -1 do
        local u = undo[i]
        if u[1] == "node" then
            if self.pos[u[2]] then self:unplace(u[2]) end
            if u[3] then self.taskNodes[u[3]] = nil end
        else
            self:dropReq(u[2], m)
        end
    end
    m.P, m.T, m.W = nil, nil, nil
end

-- Try a quest: shared camps first, private stops when sharing breaks the order rules.
function R:try(m, commit)
    -- A trial that is taken back leaves the route exactly as it was: it gets its version (and
    -- the level-up profile worked out for it) back, so the next trial need not work it out again.
    local v0 = self.version
    self.tryV = v0
    for attempt = 1, m.dungeon and 1 or 2 do -- a dungeon is run once: its quests never get a stop of their own
        local undo = {}
        local added, gain, regret = self:add(m, attempt == 2, undo)
        if added then
            if commit then
                self.routed[m] = true
                for _, d in ipairs(m.deps or {}) do
                    d.dependents = d.dependents or {}
                    d.dependents[#d.dependents + 1] = m
                end
            else
                self:rollback(m, undo)
                if Planner.VALUE_CACHE then self.version = v0 end
            end
            return added, gain, regret
        end
        self:rollback(m, undo)
        if Planner.VALUE_CACHE then self.version = v0 end
    end
    return nil
end

function R:removeQuest(m)
    if m.P then self:unplace(m.P) end
    if m.T then self:unplace(m.T) end
    for _, w in ipairs(m.W or {}) do
        self:dropReq(w, m, true)
        if #w.reqs == 0 and self.pos[w] then
            self:unplace(w)
            self.taskNodes[w.key] = nil
        end
    end
    m.P, m.T, m.W = nil, nil, nil
    self.routed[m] = nil
    for _, d in ipairs(m.deps or {}) do
        for k = #(d.dependents or {}), 1, -1 do
            if d.dependents[k] == m then remove(d.dependents, k) end
        end
    end
end

-- Seconds and XP of the whole route; with `skip`, as if that quest were not in it.
function R:totals(skip)
    local route, t, xp = self.route, 0, 0
    self.work = self.work + #route
    local prev, pool = route[1], self.restedBonus
    local ups, d, nextUp = self.ups, 0, self.ups[1]
    for i = 2, #route do
        local node = route[i]
        local gone = skip and (node.quest == skip
            or (node.kind == "W" and #node.reqs == 1 and node.reqs[1].quest == skip))
        if not gone then
            local s, x = self:value(node, skip, d)
            if node.kind == "W" then
                local bonus = min(x, pool) -- rested: kills pay double until the pool is used up
                pool, x = pool - bonus, x + bonus
            end
            t, xp = t + self:tt(prev, node) + s, xp + x
            while nextUp and xp >= nextUp do d = d + 1; nextUp = ups[d + 1] end
            prev = node
        end
    end
    return t, xp
end

-- Move stops to cheaper places, keeping the order rules: single stops, then runs of two and
-- three consecutive stops moved together (or-opt). Moving a run is what lets the route choose
-- between "turn in on the way past" and "do several quests, then turn them all in": a pair
-- like work-then-turn-in can only move as one.
--- With `guard` = { overhead, floor = lowest score allowed }, a move that shortens the route
--- but pushes what the route is worth per hour under the floor (XP paid out too much later)
--- is taken back, one move at a time. Without one (and with IMPROVE_GATES), a move that leaves a
--- quest before the level it needs is taken back: `bounds` checks only the moved stops' own levels,
--- and a stop paying XP moved past a quest for a later level pushes the level-up past it. (A route
--- that already has such a quest is left to whoever judges it.)
function R:improve(passes, checkpoint, maxLen, guard)
    local route = self.route
    local gates = Planner.IMPROVE_GATES and not guard and self.gated and not self:brokenGate()
    for _ = 1, passes do
        local improved = false
        for len = 1, maxLen or 1 do
            local i = 2
            while i + len - 1 <= #route do
                local first, last = route[i], route[i + len - 1]
                local a, b = route[i - 1], route[i + len]
                local saved = self:tt(a, first) + (b and (self:tt(last, b) - self:tt(a, b)) or 0)
                local seg = {}
                for k = 1, len do seg[k] = route[i + k - 1] end
                for k = len, 1, -1 do self:unplace(seg[k]) end
                -- where the whole run may go: every stop's own range must allow it
                local lo, hi = 1, #route
                for k = 1, len do
                    local l, h = self:bounds(seg[k])
                    if l > lo then lo = l end
                    if h < hi then hi = h end
                end
                local bestP, bestD = nil, huge
                local cands = Planner.NEAR_IMPROVE ~= false and self:nearCandidates(first, last, lo, hi) or nil
                self.work = self.work + (cands and #cands or (hi - lo + 1))
                for ci = 1, cands and #cands or (hi - lo + 1) do
                    local p = cands and cands[ci] or (lo + ci - 1)
                    local x, y = route[p], route[p + 1]
                    local d = self:tt(x, first)
                    if y then d = d + self:tt(last, y) - self:tt(x, y) end
                    if d < bestD then bestP, bestD = p, d end
                end
                local target = (bestP and bestP ~= i - 1 and bestD < saved - 1) and bestP or (i - 1)
                for k = 1, len do self:place(seg[k], target + k - 1) end
                if guard and target ~= i - 1 then
                    local worth = self:guardScore(guard.overhead)
                    if worth < guard.floor then
                        for k = len, 1, -1 do self:unplace(seg[k]) end
                        target = i - 1
                        for k = 1, len do self:place(seg[k], target + k - 1) end
                    end
                elseif gates and target ~= i - 1 and self:brokenGate() then
                    for k = len, 1, -1 do self:unplace(seg[k]) end
                    target = i - 1
                    for k = 1, len do self:place(seg[k], target + k - 1) end
                end
                if target ~= i - 1 then improved = true else i = i + 1 end
                if checkpoint then checkpoint() end
            end
        end
        if not improved then break end
    end
end

-- What the route is worth: the best XP per second over a prefix, judged on at least
-- MIN_HORIZON (the same rule `describe` reports). Used to compare two orders of one route.
function R:score(overhead)
    local route, t, xp, best = self.route, overhead or 0, 0, 0
    self.work = self.work + #route
    local pool = self.restedBonus
    local ups, d, nextUp, gated = self.ups, 0, self.ups[1], self.gated
    for i = 2, #route do
        local node = route[i]
        -- a quest placed before the level it needs: this order is worth nothing
        if gated and gateOf(node) > d then return 0, t, xp end
        local s, gain = self:value(node, nil, d)
        if node.kind == "W" then
            local bonus = min(gain, pool)
            pool, gain = pool - bonus, gain + bonus
        end
        t = t + self:tt(route[i - 1], node) + s
        xp = xp + gain
        while nextUp and xp >= nextUp do d = d + 1; nextUp = ups[d + 1] end
        if gain > 0 then
            local rate = xp / max(t, Planner.MIN_HORIZON)
            if rate > best then best = rate end
        end
    end
    return best, t, xp
end

-- What the search maximises: mostly the peak rate. The rest of the route counts a little, so
-- the stretch after the best moment to leave is not left in a mess: all the route's XP, less
-- its time valued at the rate below which a quest is dropped anyway (PRUNE_RATIO of the peak).
-- So a quest worth keeping adds to it, and a shorter way through the same stops does too.
function R:worth(overhead)
    local best, t, xp = self:score(overhead)
    return best + Planner.TAIL_WEIGHT * (xp - Planner.PRUNE_RATIO * best * t) / Planner.MIN_HORIZON
end

-- The surplus goal (Planner.GOAL = "surplus"): with R = self.goalR (XP per second the player can
-- get elsewhere), leaving after stop k is worth V(k) = XP(k) - R * T(k) (T includes the overhead).
-- Leaving before the first stop is V = -R * overhead. Returns the best V (XP), the route index
-- of the stop to leave after (nil when staying put is best), and the route's end time and XP.
-- A stop before its level: returns nil (the route is worth nothing as it stands).
function R:surplus(overhead, rate)
    rate = rate or self.goalR
    local c = self:prefix(overhead)
    local n = c.n
    if not c.OK[n] then return nil end
    local T, X = c.T, c.X
    local best, at = -rate * T[1], nil
    for i = 2, n do
        if X[i] > X[i - 1] then
            local v = X[i] - rate * T[i]
            if v > best then best, at = v, i end
        end
    end
    return best, at, T[n], X[n]
end

-- What the tidy-up's guards hold on to (see `improve` and `finish`): today's score, or under the
-- surplus goal the value V in XP (a route's V is a small difference of large numbers, so it is
-- guarded as XP: a move may cost SCORE_GIVE of it, not of R + V / H). Broken: -huge.
function R:guardScore(overhead)
    if not self.goalR then return (self:score(overhead)) end
    return self:surplus(overhead) or -huge
end

-- The number the search, the warm-start check, the exact windows and the tidy-up's guard compare
-- routes by: today's worth, or under the surplus goal R + V / MIN_HORIZON (XP per second like
-- worth, so the loop's relative margins mean the same). A route with a stop before its level is -1.
function R:goalWorth(overhead)
    local rate = self.goalR
    if not rate then return self:worth(overhead) end
    local v = self:surplus(overhead)
    if not v then return -1 end
    return rate + v / Planner.MIN_HORIZON
end

-- The way across a zone border planned together (Planner.Plan's opts.seam): what the route is worth
-- as the itinerary judges it, the XP inside the horizon (self.seam.horizon, seconds from the
-- itinerary's start; `overhead` is when the route starts). Stops after the crossing (`cross`) are
-- later by the zone switch (self.seam.switch). A work stop cut by the horizon counts for the share
-- done. When the route ends inside the horizon, what follows it adds self.seam.tail(when, where).
-- A route with a stop before its level is worth -1.
function R:seamValue(overhead)
    local sm = self.seam
    local c = self:prefix(overhead)
    local n = c.n
    if not c.OK[n] then return -1 end
    local T, X, D, H = c.T, c.X, c.D, sm.horizon
    local cross, sw, route = self.cross or n, sm.switch or 0, self.route
    for i = 2, n do
        local t = T[i] + (i > cross and sw or 0)
        if t > H then
            local node, xp = route[i], X[i - 1]
            if node.kind == "W" then
                local s = self:value(node, nil, D[i - 1])
                if s > 0 then
                    local done = (H - (t - s)) / s
                    if done > 0 then xp = xp + (X[i] - X[i - 1]) * min(1, done) end
                end
            end
            return xp
        end
    end
    local tEnd = T[n] + (n > cross and sw or 0)
    return X[n] + (sm.tail and sm.tail(tEnd, route[n].loc) or 0)
end

-- The whole route as it stands, to come back to later.
function R:snapshot()
    local s = { route = {}, reqs = {}, quests = {} }
    for i, node in ipairs(self.route) do
        s.route[i] = node
        if node.kind == "W" then
            local copy = {}
            for k, req in ipairs(node.reqs) do copy[k] = req end
            s.reqs[node] = copy
        end
    end
    for m in pairs(self.routed) do
        local w = {}
        for k, node in ipairs(m.W or {}) do w[k] = node end
        s.quests[m] = { m.P, m.T, w, m.deps } -- (deps: which of "one of" its prerequisites it follows, see ready)
    end
    return s
end

function R:restore(s, candidates)
    for node in pairs(self.pos) do self.pos[node] = nil end
    self.route, self.taskNodes = {}, {}
    for i, node in ipairs(s.route) do
        self.route[i] = node
        if node.kind == "W" then
            local copy = {}
            for k, req in ipairs(s.reqs[node]) do copy[k] = req end
            self:setReqs(node, copy)
            self.taskNodes[node.key] = node
        end
    end
    self:reindex(1)
    self.routed = {}
    for _, m in ipairs(candidates) do m.P, m.T, m.W, m.dependents = nil, nil, nil, nil end
    for _, m in ipairs(candidates) do
        local q = s.quests[m]
        if q then
            local w = {}
            for k, node in ipairs(q[3]) do w[k] = node end
            m.P, m.T, m.W = q[1], q[2], w
            m.deps = q[4] or m.deps
            self.routed[m] = true
            for _, d in ipairs(m.deps or {}) do
                d.dependents = d.dependents or {}
                d.dependents[#d.dependents + 1] = m
            end
        end
    end
    if self.cross then -- (a seam route: the crossing is after the last stop of the first side)
        local c = 1
        for i = 2, #self.route do if seamSide(self.route[i]) == "A" then c = i end end
        self.cross = c
    end
end

-- Must stop a come before stop b?
local function mustPrecede(a, b)
    if a.kind == "P" then
        if b.kind == "T" then return b.quest == a.quest end
        if b.kind == "W" then
            for i = 1, #b.reqs do if b.reqs[i].quest == a.quest then return true end end
        end
    elseif a.kind == "W" then
        if b.kind == "T" then
            for i = 1, #a.reqs do if a.reqs[i].quest == b.quest then return true end end
        end
    elseif a.kind == "T" and b.kind == "P" then
        for _, d in ipairs(b.quest.deps or {}) do if d == a.quest then return true end end
    end
    return false
end

--- Does the route keep every order rule? (A safeguard, and for tests.)
function R:valid()
    local pos = self.pos
    for m in pairs(self.routed) do
        local p, t = m.P and pos[m.P] or 0, m.T and pos[m.T]
        if not t or (m.P and not pos[m.P]) or p > t then return false end
        for _, w in ipairs(m.W or {}) do
            local at = pos[w]
            if not at or at < p or at > t then return false end
        end
        for _, d in ipairs(m.deps or {}) do
            if self.routed[d] and m.P and pos[d.T] > p then return false end
        end
    end
    return true
end

---------------------------------------------------------------------------------------------
-- Exact windows
---------------------------------------------------------------------------------------------
-- A stretch of K stops in a row is small enough to find its best possible order: for every
-- set of stops already visited and every last stop, keep the quickest way to have done just
-- that (2^K x K states). Two orders come out of it: the quickest through the whole stretch,
-- and the one that reaches the best XP per hour soonest and then finishes as fast as it can.
-- Whichever makes the route worth most replaces the stretch. The window then slides on.

-- Quickest paths over the window's stops. `from` = { mask, last, seconds } starts midway.
-- Returns dist and parent, both indexed by mask * k + last (stops are 0..k-1).
-- `dist` and `parent` may be handed in to be used again (they are emptied first).
local function windowPaths(k, cost, startCost, preds, from, dist, parent)
    dist, parent = dist or {}, parent or {}
    for key in pairs(dist) do dist[key] = nil end
    for key in pairs(parent) do parent[key] = nil end
    local bit = {}
    for j = 0, k - 1 do bit[j] = 2 ^ j end
    local full = 2 ^ k - 1
    if from then
        dist[from[1] * k + from[2]] = from[3]
    else
        for j = 0, k - 1 do
            if #preds[j] == 0 then dist[bit[j] * k + j] = startCost[j] end
        end
    end
    local inMask = {}
    for mask = from and from[1] or 1, full do
        local rest = mask
        for j = k - 1, 0, -1 do
            if rest >= bit[j] then inMask[j] = true; rest = rest - bit[j] else inMask[j] = false end
        end
        local base = mask * k
        for last = 0, k - 1 do
            local d = inMask[last] and dist[base + last]
            if d then
                local row = cost[last]
                for nxt = 0, k - 1 do
                    if not inMask[nxt] then
                        local ok = true
                        local pr = preds[nxt]
                        for i = 1, #pr do if not inMask[pr[i]] then ok = false; break end end
                        if ok then
                            local idx = (mask + bit[nxt]) * k + nxt
                            local nd = d + row[nxt]
                            local old = dist[idx]
                            if not old or nd < old then dist[idx], parent[idx] = nd, last end
                        end
                    end
                end
            end
        end
    end
    return dist, parent, bit, full
end

-- The order that ends in state (mask, last), back to where the paths started.
local function windowOrder(k, parent, bit, mask, last, stopMask)
    local order = {}
    while mask ~= stopMask do
        insert(order, 1, last)
        local prev = parent[mask * k + last]
        mask = mask - bit[last]
        last = prev
        if last == nil then break end
    end
    return order
end

function R:exactWindows(size, overhead, checkpoint)
    local route = self.route
    local step = max(1, floor(size / 2))
    local i = 2
    while i + 2 <= #route do
        local k = min(size, #route - i + 1)
        local nodes = {}
        for j = 0, k - 1 do nodes[j] = route[i + j] end
        local before, after = route[i - 1], route[i + k]
        -- cost of going to a stop includes the work there; the last leg out is added at the end
        local cost, startCost, endCost, preds, gain = {}, {}, {}, {}, {}
        for a = 0, k - 1 do
            local service = self:service(nodes[a])
            startCost[a] = self:tt(before, nodes[a]) + service
            endCost[a] = after and self:tt(nodes[a], after) or 0
            cost[a], preds[a] = {}, {}
            local node = nodes[a]
            gain[a] = node.kind == "T" and (node.quest.xp or 0) or (node.kind == "W" and select(2, taskTotals(node)) or 0)
        end
        for a = 0, k - 1 do
            for b = 0, k - 1 do
                if a ~= b then
                    cost[a][b] = self:tt(nodes[a], nodes[b]) + self:service(nodes[b])
                    if mustPrecede(nodes[a], nodes[b]) then preds[b][#preds[b] + 1] = a end
                end
            end
        end
        self.work = self.work + 2 ^ k * k
        -- (the path tables are this route's own, used again by every window: a few kB each time otherwise)
        local ws = self.windowScratch
        if not ws then ws = { {}, {}, {}, {} }; self.windowScratch = ws end
        local dist, parent, bit, full = windowPaths(k, cost, startCost, preds, nil, ws[1], ws[2])
        if checkpoint then checkpoint() end
        local orders = {}
        -- 1. the quickest way through
        local bestLast, bestD = nil, huge
        for last = 0, k - 1 do
            local d = dist[full * k + last]
            if d and d + endCost[last] < bestD then bestLast, bestD = last, d + endCost[last] end
        end
        if bestLast then orders[#orders + 1] = windowOrder(k, parent, bit, full, bestLast, 0) end
        -- 2. the best rate soonest, then the quickest finish
        local t0, x0 = overhead or 0, 0
        do
            local pool = self.restedBonus
            for p = 2, i - 1 do
                local node = route[p]
                t0 = t0 + self:tt(route[p - 1], node) + self:service(node)
                if node.kind == "W" then
                    local _, x = taskTotals(node)
                    local bonus = min(x, pool)
                    pool, x0 = pool - bonus, x0 + x + bonus
                elseif node.kind == "T" then x0 = x0 + (node.quest.xp or 0) end
            end
        end
        local peakMask, peakLast, peakRate = nil, nil, 0
        local inMask = {}
        for mask = 1, full - 1 do
            local rest, xp = mask, x0
            for j = k - 1, 0, -1 do
                if rest >= bit[j] then inMask[j] = true; rest = rest - bit[j]; xp = xp + gain[j] else inMask[j] = false end
            end
            for last = 0, k - 1 do
                local d = inMask[last] and gain[last] > 0 and dist[mask * k + last]
                if d then
                    local rate = xp / max(t0 + d, Planner.MIN_HORIZON)
                    if rate > peakRate * (1 + 1e-9) then peakMask, peakLast, peakRate = mask, last, rate end
                end
            end
        end
        if peakMask then
            local head = windowOrder(k, parent, bit, peakMask, peakLast, 0)
            self.work = self.work + 2 ^ k * k
            local dist2, parent2 = windowPaths(k, cost, startCost, preds, { peakMask, peakLast, dist[peakMask * k + peakLast] }, ws[3], ws[4])
            local last2, d2 = nil, huge
            for last = 0, k - 1 do
                local d = dist2[full * k + last]
                if d and d + endCost[last] < d2 then last2, d2 = last, d + endCost[last] end
            end
            if last2 then
                local tail = windowOrder(k, parent2, bit, full, last2, peakMask)
                for _, j in ipairs(tail) do head[#head + 1] = j end
                if #head == k then orders[#orders + 1] = head end
            end
            if checkpoint then checkpoint() end
        end
        -- keep whichever order makes the route worth most (the present one unless clearly beaten)
        local bestWorth, bestOrder = self:goalWorth(overhead) * (1 + 1e-6), nil
        for _, order in ipairs(orders) do
            if #order == k then
                for j = 0, k - 1 do route[i + j] = nodes[order[j + 1]] end
                self:reindex(i)
                local worth = self:valid() and self:goalWorth(overhead) or -1
                if worth > bestWorth then bestWorth, bestOrder = worth, order end
            end
        end
        for j = 0, k - 1 do route[i + j] = nodes[bestOrder and bestOrder[j + 1] or j] end
        self:reindex(i)
        i = i + step
    end
end

-- Accept everything a place offers on the first visit. A quest's accept stop moves to the
-- earliest stop at (nearly) the same spot, as far forward as its prerequisites allow. The
-- route never gets longer by this: the new place is where we already stand, and the old stop
-- is simply passed by.
function R:batchPickups()
    local route = self.route
    local near = Planner.SAME_PLACE_YARDS
    for i = 2, #route do
        local node = route[i]
        if node.kind == "P" and gateOf(node) == 0 then -- (a quest for a later level stays where its level is)
            local lo = 1
            for _, d in ipairs(node.quest.deps or {}) do
                local p = d.T and self.pos[d.T]
                if p and p > lo then lo = p end
            end
            for p = lo, i - 2 do
                local d = Geo.Dist(route[p].loc, node.loc)
                if d and d <= near then
                    -- go to the end of that visit, so stops at one NPC stay together
                    while p + 1 < i do
                        local dn = Geo.Dist(route[p + 1].loc, node.loc)
                        if dn and dn <= near then p = p + 1 else break end
                    end
                    if p < i - 1 then
                        self:unplace(node)
                        self:place(node, p)
                    end
                    break
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------
-- Collecting quests
---------------------------------------------------------------------------------------------

local function listEntry(m, reason)
    return { id = m.id, name = m.name, level = m.level, minLevel = m.minLevel, needLevel = m.needLevel,
        reason = reason or m.detail, loc = m.pickup, at = m.pickupName, xp = m.xp }
end

-- The stop of the route with this order key ("P:12", "T:12", "W:m200"), or nil.
local function nodeOfKey(r, key)
    if not key then return nil end
    for i = 2, #r.route do
        local n = r.route[i]
        local k = n.kind == "W" and ("W:" .. n.key) or (n.kind .. ":" .. n.quest.id)
        if k == key then return n end
    end
    return nil
end

-- Quests taken along to the next zone (Planner.Plan's opts.border): accepted here, their work on
-- this map done here, the rest (their work elsewhere and the turn-in) left to the zone they are
-- finished in. Here such a quest pays nothing (its XP is kept as `borderXP`, for the check that
-- drops slow quests); its turn-in is a stop of no time at its last place here, and no step (see
-- describe). One with nothing to do here (in the log, its work and turn-in elsewhere) is taken
-- out; so is every quest that follows one of them (its prerequisite is turned in elsewhere).
-- Returns the candidates left and the ids of those taken out with nothing to do here, sorted.
local function takeAlong(candidates, zoneMap, border, lists, checkpoint)
    local want = {}
    for _, id in ipairs(border.ids or {}) do want[id] = true end
    local keep, nothingHere, goneIds = {}, {}, {}
    for _, m in ipairs(candidates) do
        if checkpoint then checkpoint() end
        if want[m.id] and m.status == "ok" and not m.gate and not m.dungeon and not m.keep then
            local here, left = {}, 0
            for _, t in ipairs(m.tasks) do
                if t.loc and t.loc.map == zoneMap then here[#here + 1] = t else left = left + 1 end
            end
            if not m.pickup and #here == 0 then
                nothingHere[m] = true
                goneIds[#goneIds + 1] = m.id
                lists.skipped[#lists.skipped + 1] = listEntry(m, "finished in the next zone")
            else
                m.border, m.borderTo, m.borderLeft, m.borderXP = true, border.to and border.to[m.id], left, m.xp or 0
                m.xp, m.xpLow, m.xpHigh = 0, nil, nil
                m.tasks = here
                local last = here[#here]
                m.turnin, m.turninName, m.turninGuessed = (last and last.loc) or m.pickup, nil, nil
                keep[#keep + 1] = m
            end
        else
            keep[#keep + 1] = m
        end
    end
    -- what follows a quest taken along waits for its turn-in elsewhere (and so on down the chain)
    local changed = true
    while changed do
        changed = false
        for i = #keep, 1, -1 do
            local m, waits = keep[i], false
            for _, list in ipairs({ m.deps or {}, m.baseDeps or {}, m.anyDeps or {} }) do
                for _, d in ipairs(list) do
                    if d.border or nothingHere[d] then waits = true end
                end
            end
            if waits then
                table.remove(keep, i)
                nothingHere[m], changed = true, true
                local e = listEntry(m, "follows a quest finished in the next zone")
                if m.borderXP then e.xp = m.borderXP end
                lists.later[#lists.later + 1] = e
            end
        end
    end
    table.sort(goneIds)
    return keep, goneIds
end

-- Models of every quest relevant to the zone, sorted into routable ones and the lists.
local function collect(zoneMap, ctx, lists, also)
    local Data = ns.Data
    -- The way across a zone border planned together (Planner.Plan's opts.seam): the other zone's
    -- quests are candidates too (`also`, maps).
    local inZones = { [zoneMap] = true }
    for _, map in ipairs(also or {}) do inZones[map] = true end
    local models, order, undecided = {}, {}, {}
    ctx.campKeys = {} -- camps (mob kinds, objects) the plan's quests use so far
    -- What the plan reads about quests (for ns.Memory): `ids` = every quest asked about (is it
    -- available? build its model), `used` = those of them in the log, `logSeen` = the whole log.
    -- Log quests looked at and found to belong elsewhere are in `logSeen` only.
    local inputs = { ids = {}, used = {}, logSeen = {} }
    for id in pairs(ctx.log) do inputs.logSeen[id] = true end
    -- A quest that only needs a level the route will reach: it is built as it will be at that
    -- level and planned after the level-up (`gate` = level-ups from now).
    local function gatedModel(m)
        local ups = ctx.levelUps or {}
        if ctx.dungeon or not m.needLevel or #ups == 0 then return nil end
        local need = m.needLevel
        for _ = 1, 2 do
            local d = need - ctx.level
            if d < 1 or d > #ups then return nil end
            local g = Model.Build(m.id, setmetatable({ level = need }, { __index = ctx }))
            if not g then return nil end
            if g.status == "ok" then
                if not ctx.chain and g.pickup and not inZones[g.pickup.map] and g.pickup.map ~= ctx.startMap then return nil end
                g.gate, g.needLevel, g.deps, g.anyDeps, g.baseDeps = d, need, m.deps, m.anyDeps, m.baseDeps
                -- red today but can be accepted: picked up now, worked from the level it is orange
                g.acceptEarly = (m.red and not ((m.minLevel or 0) > ctx.level)) or nil
                return g
            end
            if g.status ~= "later" or not g.needLevel or g.needLevel <= need then return nil end
            need = g.needLevel
        end
        return nil
    end
    local function later(m)
        local g = gatedModel(m)
        if not g then
            lists.later[#lists.later + 1] = listEntry(m)
            return
        end
        models[m.id] = g
        order[#order + 1] = g
        for _, t in ipairs(g.tasks) do
            if t.key then ctx.campKeys[t.key] = true end
        end
    end
    local function consider(id, m)
        if not m then return end
        models[id] = m
        inputs.ids[id] = true
        if ctx.log[id] then inputs.used[id] = true end
        local entry = ctx.log[id]
        -- A skipped quest stays out of the route, unless it got done anyway: then only the
        -- turn-in is left, and that is worth planning.
        if ctx.ignored and ctx.ignored[id] and not (entry and entry.isComplete and m.status == "ok") then
            lists.ignored[#lists.ignored + 1] = listEntry(m, "you skipped it")
        elseif m.status == "ok" then
            -- (a giver in another zone or city is planned like any other: the trip to it is part
            -- of the route, and the usual value checks decide whether it is worth it)
            order[#order + 1] = m
            for _, t in ipairs(m.tasks) do
                if t.key then ctx.campKeys[t.key] = true end -- later quests prefer these mobs
            end
        elseif m.status == "later" then later(m) -- (a red quest too: planned from the level it is orange)
        elseif m.status == "group" then lists.group[#lists.group + 1] = listEntry(m)
        elseif m.status == "unconfirmed" then lists.unconfirmed[#lists.unconfirmed + 1] = listEntry(m)
        elseif m.status == "unlocated" or m.status == "item" then lists.unlocated[#lists.unlocated + 1] = listEntry(m)
        end
    end
    -- What to look at: the zone's quests, or for a dungeon its own quests and everything that
    -- has to be done first to get them (their prerequisite chains, wherever those are). A class
    -- quest plan (ctx.chain) is built the same way from the chain's quests: those and their
    -- lead-up are the plan's must-dos (`must`), whatever they pay.
    local entries = Data.QuestsInZone(zoneMap) or {}
    if also and #also > 0 and not (ctx.dungeon or ctx.chain) then
        local merged, have = {}, {}
        for _, e in ipairs(entries) do merged[#merged + 1] = e; have[e.id] = true end
        for _, map in ipairs(also) do
            for _, e in ipairs(Data.QuestsInZone(map) or {}) do
                if not have[e.id] then merged[#merged + 1] = e; have[e.id] = true end
            end
        end
        entries = merged
    end
    if ctx.dungeon or ctx.chain then
        entries = {}
        local added = {}
        local function add(id, depth)
            if added[id] or depth > Planner.PREREQ_DEPTH then return end
            added[id] = true
            entries[#entries + 1] = { id = id }
            local q = Data.GetQuest(id)
            if not q or (ctx.avail.completed or {})[id] then return end
            for _, list in ipairs({ q.preAll, q.preAny }) do
                for _, pre in ipairs(list) do
                    if not (ctx.avail.completed or {})[pre] then add(pre, depth + 1) end
                end
            end
        end
        for _, id in ipairs(ctx.dungeon and ctx.dungeon.quests or ctx.chain.quests) do add(id, 0) end
        table.sort(entries, function(a, b) return a.id < b.id end)
    end
    local seen = {}
    for _, e in ipairs(entries) do
        if ctx.checkpoint then ctx.checkpoint() end
        local id = e.id
        seen[id] = true
        inputs.ids[id] = true
        if ctx.log[id] then
            consider(id, Model.Build(id, ctx))
        else
            local ok, reason = Data.IsAvailable(id, ctx.avail)
            if ok then
                consider(id, Model.Build(id, ctx))
            elseif reason and reason:find("^prerequisite") then
                undecided[#undecided + 1] = id
            end
        end
        if ctx.checkpoint then ctx.checkpoint() end
    end
    -- Quests in the log from elsewhere that are worked or turned in on this map. In an
    -- itinerary (ctx.carried: quests brought along from the zone before), a finished one is
    -- considered wherever its turn-in is: a city on the way is worth the stop, anything else
    -- is dropped by the usual value check.
    -- A dungeon plan takes only finished dungeon quests that are not on the dungeon's own list
    -- (a follow-up started inside, like Return of the Ring): their turn-in is planned when it
    -- is on the map of the dungeon's door, on the map we stand on, or the quest belongs there.
    -- (A class quest plan takes the log's quests that pass where the chain goes: see below.)
    for id, entry in pairs(ctx.chain and {} or ctx.log) do
        if not seen[id] and ctx.dungeon then
            local m = Model.Build(id, ctx)
            local door = ctx.dungeon.loc.map
            if m and m.leftover and m.turnin
                and (m.turnin.map == door or m.turnin.map == ctx.startMap or m.zone == door) then
                consider(id, m)
            end
        elseif not seen[id] then
            local m = Model.Build(id, ctx)
            local here = m and m.turnin and inZones[m.turnin.map]
            for _, t in ipairs(m and m.tasks or {}) do
                if t.loc and inZones[t.loc.map] then here = true end
            end
            if not here and m and ctx.carried and ctx.carried[id] and entry.isComplete and m.turnin then here = true end
            if here then consider(id, m) end
        end
    end
    -- Quests an item in the bags starts, when their work or turn-in is on this map.
    local bagIds = {}
    for id in pairs(ctx.bagQuests or {}) do bagIds[#bagIds + 1] = id end
    table.sort(bagIds)
    for _, id in ipairs(bagIds) do
        if not seen[id] and not ctx.log[id] and not ctx.dungeon and not ctx.chain and Data.IsAvailable(id, ctx.avail) then
            seen[id] = true
            local m = Model.Build(id, ctx)
            local here = m and inZones[m.zone] or (m and m.turnin and inZones[m.turnin.map])
            for _, t in ipairs(m and m.tasks or {}) do
                if t.loc and inZones[t.loc.map] then here = true end
            end
            if here then consider(id, m) end
        end
    end
    -- On the way: when the zone's quests send us into another zone, quests that start right
    -- where we will be standing there are worth a look too (a letter found in the camp we
    -- clear, a prisoner next to it). They are added as candidates; the usual value check
    -- decides whether they stay.
    if not ctx.dungeon and not ctx.chain then
        local stops, maps = {}, {}
        for _, m in ipairs(order) do
            for _, t in ipairs(m.tasks) do
                if t.loc and t.loc.map and not inZones[t.loc.map] then stops[#stops + 1] = t.loc; maps[t.loc.map] = true end
            end
        end
        for map in pairs(maps) do
            for _, e in ipairs(Data.QuestsInZone(map) or {}) do
                local id = e.id
                if e.giverInZone and not seen[id] and not models[id] then inputs.ids[id] = true end -- (skipped below when in the log or ignored)
                if e.giverInZone and not seen[id] and not models[id] and not ctx.log[id] and not (ctx.ignored and ctx.ignored[id]) then
                    seen[id] = true
                    if Data.IsAvailable(id, ctx.avail) then
                        local m = Model.Build(id, ctx)
                        local near = false
                        if m and m.status == "ok" and m.pickup then
                            for _, stop in ipairs(stops) do
                                local d = Geo.Dist(stop, m.pickup)
                                if d and d <= Planner.ON_THE_WAY_YARDS then near = true; break end
                            end
                        end
                        if near then
                            m.onTheWay = true
                            models[id] = m
                            order[#order + 1] = m
                        end
                    end
                end
                if ctx.checkpoint then ctx.checkpoint() end
            end
        end
    end

    -- Follow-ups: quests whose only obstacle is a prerequisite that is in the plan.
    local assumed = setmetatable({}, { __index = ctx.avail.completed or {} })
    local avail2 = {}
    for k, v in pairs(ctx.avail) do avail2[k] = v end
    avail2.completed = assumed
    for _ = 1, (ctx.dungeon or ctx.chain) and Planner.PREREQ_DEPTH or Planner.CHAIN_ROUNDS do
        if #undecided == 0 then break end
        for _, m in ipairs(order) do assumed[m.id] = true end
        local still, progress = {}, false
        for _, id in ipairs(undecided) do
            if ctx.checkpoint then ctx.checkpoint() end
            if Data.IsAvailable(id, avail2) then
                local m = Model.Build(id, ctx)
                if m then
                    -- Every quest of "all of" must come first; of "one of", any one of them in
                    -- the plan is enough: `anyDeps`, bound to one when the quest is placed (see ready).
                    m.deps = {}
                    local any = {}
                    for n, list in ipairs({ m.quest.preAll, m.quest.preAny }) do
                        for _, pre in ipairs(list) do
                            local dep = models[pre]
                            if dep and dep.status == "ok" and not rawget(ctx.avail.completed or {}, pre) then
                                if n == 1 then m.deps[#m.deps + 1] = dep else any[#any + 1] = dep end
                            end
                        end
                    end
                    if #any == 1 then
                        m.deps[#m.deps + 1] = any[1]
                    elseif #any > 1 then
                        m.anyDeps, m.baseDeps = any, m.deps
                        local copy = {}
                        for i, d in ipairs(m.deps) do copy[i] = d end
                        m.deps = copy
                    end
                    consider(id, m)
                    progress = true
                end
            else
                still[#still + 1] = id
            end
        end
        undecided = still
        if not progress then break end
    end
    -- A class quest plan takes the chain and its lead-up only, nothing else on the way: every
    -- quest collected is a must-do (`must`).
    if ctx.chain then
        for _, m in ipairs(order) do m.must = true end
    end
    ctx.campKeys = nil
    return order, models, inputs
end

---------------------------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------------------------

-- Can the quest go in the route: is every quest it follows there? A quest that needs one of
-- several (`anyDeps`) follows the first of them in the route; its `deps` are set to that one
-- (with the "all of" ones), and stay so while it is in the route.
local function ready(r, m)
    for _, d in ipairs(m.baseDeps or m.deps or {}) do
        if not r.routed[d] then return false end
    end
    local any = m.anyDeps
    if any and not r.routed[m] then
        local pick
        for _, d in ipairs(any) do
            if r.routed[d] then pick = d; break end
        end
        if not pick then return false end
        local base = m.baseDeps
        if #m.deps ~= #base + 1 or m.deps[#m.deps] ~= pick then
            local deps = {}
            for i, d in ipairs(base) do deps[i] = d end
            deps[#deps + 1] = pick
            m.deps = deps
        end
    end
    return true
end

local function exclusiveWith(m, routedIds)
    for _, ex in ipairs(m.quest.exclusive) do
        if routedIds[ex] then return true end
    end
    return false
end


local function describe(r, plan)
    local route = r.route
    local steps, order = {}, {}
    local t, xp = plan.overhead, 0
    local pool = r.restedBonus
    local ups, d, nextUp = r.ups, 0, r.ups[1]
    for i = 2, #route do
        local node = route[i]
        local travel = r:tt(route[i - 1], node)
        local step = { loc = node.loc, travel = travel }
        local lv = d > 0 and (r.level + d) or nil
        if node.kind == "W" then
            local seconds, killXP, kills, workAs = taskTotals(node, nil, lv, r.fix)
            step.workAs = workAs -- the kind of work the step-time model takes it for (see ns.Tracker)
            local first = node.reqs[1].task
            local rested = min(killXP, pool)
            pool = pool - rested
            step.kind, step.action, step.seconds, step.xp = "work", ACTION[first.kind] or "do", seconds, killXP + rested
            step.restedXP = rested > 0 and rested or nil
            step.group = needsGroup(node) or nil
            step.target, step.from, step.kills = first.label, first.from, kills > 0 and kills or nil
            step.mobLevel = first.mobLevel    -- for the step log only
            step.quests, step.parts = {}, {}
            local listed = {}
            for _, req in ipairs(node.reqs) do
                if not listed[req.quest.id] then
                    listed[req.quest.id] = true
                    step.quests[#step.quests + 1] = { id = req.quest.id, name = req.quest.name, level = req.quest.level }
                end
                step.parts[#step.parts + 1] = { quest = req.quest.id, index = req.task.index, label = req.task.label,
                    need = req.task.need, have = req.task.have, total = req.task.total, action = ACTION[req.task.kind] or "do",
                    guessed = req.task.countGuessed, rate = req.task.rate }
            end
            order[#order + 1] = "W:" .. node.key
        else
            local m = node.quest
            step.kind = node.kind == "P" and "accept" or "turnin"
            step.action, step.seconds = step.kind, (node.kind == "T" and m.border) and 0 or Cost.INTERACT_SECONDS * r.talk
            step.xp = node.kind == "T" and (lv and Model.QuestXPAt(m, lv) or (m.xp or 0)) or 0
            step.needLevel = m.gate and not (node.kind == "P" and m.acceptEarly) and (r.level + m.gate) or nil
            step.workLevel = m.gate and node.kind == "P" and m.acceptEarly and (r.level + m.gate) or nil
            step.target = node.kind == "P" and m.pickupName or m.turninName
            step.keep = m.keep or nil -- kept in the log after a dungeon run (its turn-in goes below)
            step.borderTo = node.kind == "P" and m.border and m.borderTo or nil -- accepted here, finished in that zone (a map)
            step.border = (node.kind == "T" and m.border) or nil -- (its turn-in elsewhere: no step, see below)
            step.fromBag = node.kind == "P" and m.fromBag or nil -- started from an item in the bags: no place to go
            step.guessed = node.kind == "T" and m.turninGuessed or nil
            step.quests = { { id = m.id, name = m.name, level = m.level } }
            step.group = m.elite or nil
            step.xpSource, step.xpLow, step.xpHigh = m.xpSource, m.xpLow, m.xpHigh
            order[#order + 1] = (node.kind == "P" and "P:" or "T:") .. m.id
        end
        -- The times above are corrected by what finished steps have taught (see newRoute). The
        -- times as first planned stay on the step: the step-time model is fitted against those.
        if r.fix then
            local rawTravel = travel / r.travelFactor
            local rawSeconds = node.kind == "W" and (taskTotals(node, nil, lv)) or Cost.INTERACT_SECONDS
            if rawTravel + rawSeconds > 0 then
                step.rawTravel, step.rawSeconds = rawTravel, rawSeconds
                step.factor = (travel + step.seconds) / (rawTravel + rawSeconds)
            end
        end
        t, xp = t + travel + step.seconds, xp + step.xp
        step.t, step.cumXP = t, xp
        while nextUp and xp >= nextUp do d = d + 1; nextUp = ups[d + 1] end
        if d > 0 and (r.level + d) ~= (lv or r.level) then step.levelUp = r.level + d end -- this step levels us up
        steps[#steps + 1] = step
    end
    -- The turn-in of a quest kept in the log after a dungeon run (Model: `keep`) and the turn-in
    -- of a quest taken along to the next zone (Planner.Plan's opts.border) are no steps: their
    -- time goes to the step after them, so every step's `t` stays as it was.
    for i = #steps, 1, -1 do
        local s = steps[i]
        if s.kind == "turnin" and (s.keep or s.border) then
            local after = steps[i + 1]
            if after then after.travel = after.travel + s.travel + s.seconds end
            remove(steps, i)
            remove(order, i)
        end
    end
    plan.steps, plan.order = steps, order
    plan.seconds, plan.xp = t, xp
    -- Best moment to leave: the prefix with the highest XP per second, judged on at least
    -- MIN_HORIZON of play (time left over in a short zone earns nothing).
    local horizon = min(Planner.MIN_HORIZON, max(t, 1))
    local peak, peakRate = #steps, 0
    for i, step in ipairs(steps) do
        if step.xp > 0 then
            local rate = step.cumXP / max(step.t, horizon)
            if rate > peakRate then peak, peakRate = i, rate end
        end
    end
    plan.peak = peak
    plan.rate = peakRate * 3600                                   -- XP per hour, leaving at the best moment
    plan.score = (#steps > 0) and steps[peak].cumXP / max(steps[peak].t, Planner.MIN_HORIZON) * 3600 or 0
    plan.fullRate = t > 0 and xp / t * 3600 or 0
    -- The slow tail: the last stretch of the route whose own rate is well under the peak.
    local tailStart, sufXP, sufT = #steps + 1, 0, 0
    for i = #steps, 2, -1 do
        sufXP, sufT = sufXP + steps[i].xp, sufT + steps[i].travel + steps[i].seconds
        if sufXP / max(sufT, 1) < peakRate * Planner.TAIL_RATIO then tailStart = i else break end
    end
    -- The surplus goal: the plan's value is the best of leaving after stop k, XP(k) - R * time(k)
    -- (in XP), or staying put (-R * overhead). The leaving point is the argmax (when staying put
    -- is best, `stay` is set and `peak` is still the best stop to leave after, for the window);
    -- the steps after it are the tail. `score` and `rate` stay what the window shows: XP per hour
    -- up to the leaving point. `todayScore` is what "rate" would call the score (one-hour floor).
    if r.goalR then
        local R_ = r.goalR
        local stay = -R_ * plan.overhead
        local bestV, at = -huge, nil
        for i, step in ipairs(steps) do
            local v = step.cumXP - R_ * step.t
            if v > bestV then bestV, at = v, i end
        end
        plan.todayScore = plan.score
        plan.stay = (#steps == 0 or stay >= bestV) or nil
        plan.value = (#steps > 0 and bestV > stay) and bestV or stay
        plan.R = R_
        plan.bestValue = #steps > 0 and bestV or stay -- the best leaving point after a step, even when below staying put (tie-break for ranking)
        if at then
            plan.peak = at
            plan.rate = steps[at].cumXP / max(steps[at].t, 1) * 3600
            plan.score = plan.rate
            tailStart = at + 1
        else
            plan.rate, plan.score = 0, 0
        end
        if plan.stay then tailStart = 1 end
    end
    plan.tailStart = tailStart
    for i, step in ipairs(steps) do step.tail = i >= tailStart end
    return plan
end

--- Plan a zone.
--- ctx = { level, restedBonus, xpBonus, pace, stepModel (ns.Learn's step-time model; optional), start (location), startMap, travel (ns.Travel object),
---         log = { [questId] = entry }, logCount, capacity, avail (context for Data.IsAvailable),
---         ignored = { [questId] = true }, tagOf, checkpoint, near,
---         progress = optional function(stage, done, total): told "search" round of rounds and
---                    "order" (the tidy-up); it only listens,
---         chain = optional { quests = { ids } }: plan a class quest chain instead of the zone (see
---                 ns.Classes): its quests and their lead-up, nothing else }
--- opts = { seed = order of a previous plan (kept as is; new quests are added to it),
---          overhead = seconds before the first step (zone switch),
---          front = with a seed: keys of accept and turn-in stops ("P:id", "T:id") to bring to
---                  the front of the route, in this order, as far as the order rules and levels
---                  allow (the player stands at them now),
---          first = with a seed: the key of the stop to put first (the step in hand), when the
---                  order rules and levels allow,
---          border = with a seed: quests taken along to the next zone (Zones.Itinerary, Zones.WithBorder):
---                   { zone, ids = { questId, ... }, to = { [questId] = map where it is turned in },
---                   before = key of the stop the zone is left after (optional) }. Only their stops on
---                   this map are added (after the first stop, before `before`); nothing else is added
---                   and only they may be dropped as slow. Their turn-in is no step here,
---          exact = with a seed: the seed is the route as it is: nothing else is added and nothing
---                  is dropped as slow (what is done or gone is left out, as always; what stayed out is
---                  listed as after a search). Zones.WithSeam and the next zone of a way across,
---          seam = the way across a zone border planned together (Zones.PlanSeam; no seed): see
---                 seamSearch below. The result is then { zone, seam = (seamSearch's result or nil),
---                 work } instead of a plan }
--- Returns { zone, steps, order, rate, score, peak, seconds, xp, lists, quests, fronted = the
--- keys of `front` that were brought forward (nil: none), plainScore = the score of the route
--- tidied without the search (only when a search was possible; at most the score of a searched
--- plan under the rate goal), searchSpent = work units of the warm start, the search and the
--- tidy-up of its route (nil without a search),
--- border = { [id] = { to, left = objectives left after this zone, gone = true when nothing of it
--- is done here } }, borderIds = those ids, sorted (only with opts.border) }.
function Planner.Plan(zoneMap, ctx, opts)
    opts = opts or {}
    local checkpoint = ctx.checkpoint
    local lists = { later = {}, group = {}, skipped = {}, unlocated = {}, ignored = {}, unconfirmed = {} }
    ctx.near = ctx.near or ctx.start
    local candidates, _, inputs = collect(zoneMap, ctx, lists, opts.seam and opts.seam.also)
    -- Quests taken along to the next zone (opts.border, with a seed: Zones.Itinerary and
    -- Zones.WithBorder): only their part on this map is planned here, and nothing else is added.
    local border = opts.seed and opts.border or nil
    local borderGone
    local exact = opts.seed and opts.exact or nil
    if border then candidates, borderGone = takeAlong(candidates, zoneMap, border, lists, checkpoint) end
    -- Always in the same order: a table keyed by quest models is walked in memory order, which
    -- differs from one run to the next, and the first quest tried at a camp decides where
    -- that camp's stop is.
    table.sort(candidates, function(a, b) return a.id < b.id end)
    local r = newRoute(ctx)
    for _, m in ipairs(candidates) do
        if m.gate then r.gated = true end
    end
    local remaining, routedIds = {}, {}
    for _, m in ipairs(candidates) do remaining[m] = true end

    -- Debug view: with ctx.trace set to this zone, every round of the search is recorded as a
    -- frame (the route's stops as map points, what was taken out, what the route is worth).
    -- Each point also carries a step-shaped description of its stop, for the debug view's list.
    -- (A dungeon plan is not searched: its frames are the route as built and the final one.)
    local trace = (ctx.trace ~= nil and (ctx.trace == zoneMap or ctx.dungeon ~= nil) and not opts.seed) and {} or nil
    -- what the debug view lists for a stop: a step-shaped table for Format.StepTitle, made once
    -- per stop and shared by every frame that has it (a camp's again when its reqs change)
    local described = trace and {} or nil -- node -> { step = ..., n = #reqs, [k] = req }
    local function traceStep(node)
        local c = described[node]
        if node.kind == "P" or node.kind == "T" then
            if not c then
                local m, accept = node.quest, node.kind == "P"
                c = { step = { kind = accept and "accept" or "turnin", action = accept and "accept" or "turnin",
                    target = accept and m.pickupName or m.turninName, fromBag = accept and m.fromBag or nil,
                    quests = { { id = m.id, name = m.name, level = m.level } } } }
                described[node] = c
            end
            return c.step
        end
        local reqs = node.reqs or {}
        if c and c.n == #reqs then
            local same = true
            for k = 1, #reqs do if c[k] ~= reqs[k] then same = false break end end
            if same then return c.step end
        end
        local first = reqs[1] and reqs[1].task or {}
        local step = { kind = "work", action = ACTION[first.kind] or "do", target = first.label, from = first.from,
            kills = type(first.kills) == "number" and first.kills > 0 and first.kills or nil, quests = {}, parts = {} }
        local listed = {}
        for _, req in ipairs(reqs) do
            local q = req.quest
            if not listed[q.id] then
                listed[q.id] = true
                step.quests[#step.quests + 1] = { id = q.id, name = q.name, level = q.level }
            end
            step.parts[#step.parts + 1] = { quest = q.id, index = req.task.index, label = req.task.label, need = req.task.need }
        end
        c = { step = step, n = #reqs }
        for k = 1, #reqs do c[k] = reqs[k] end
        described[node] = c
        return step
    end
    local function frame(kind, info)
        if not trace then return end
        local points, quests = {}, 0
        for i, node in ipairs(r.route) do
            local l = node.loc or {}
            points[i] = { l.map, l.mx, l.my, node.kind, node.kind ~= "S" and traceStep(node) or nil }
        end
        for _ in pairs(r.routed) do quests = quests + 1 end
        local f = info or {}
        f.kind, f.points, f.quests = kind, points, quests
        f.worth = r:worth(opts.overhead) * 3600
        f.score = r:score(opts.overhead) * 3600
        trace[#trace + 1] = f
    end

    local function commit(m)
        r:try(m, true)
        remaining[m] = nil
        routedIds[m.id] = true
    end

    -- Add what is left, one quest at a time: always the one with the best XP per added second.
    -- With `regretWeight`, a quest that would lose much by waiting (its good place may be
    -- taken) goes earlier. With `floorRatio`, quests paying less than that stay out. For a
    -- dungeon (`leadUp`), the quests leading up to it are placed first, then the dungeon's own
    -- quests around the one run. With `only` (a set of quests), only those are added.
    local function fill(regretWeight, floorRatio, leadUp, fresh, only)
        local parked, retried, scans = {}, false, 0
        while true do
            local best, bestKey
            scans = scans + 1
            for _, m in ipairs(candidates) do
                -- (`fresh` = quests a search round just took out: the others that are out are tried on the first pass only)
                if remaining[m] and not parked[m] and not (fresh and not fresh[m] and scans > 1)
                    and not (only and not only[m])
                    and not exclusiveWith(m, routedIds) and ready(r, m) and not (leadUp and m.dungeon) then
                    local added, gain, regret = r:try(m, false)
                    if added then
                        local ratio = gain / max(added, 1)
                        -- (a quest already finished in the log always goes back in: only the
                        -- usual check at the end may drop its turn-in)
                        local entry = ctx.log[m.id]
                        if floorRatio and ratio < floorRatio and not (entry and entry.isComplete) then
                            parked[m] = true
                        else
                            local key = ratio
                            if regretWeight > 0 then key = ratio + regretWeight * (ratio - gain / max(added + regret, 1)) end
                            if not best or key > bestKey then best, bestKey = m, key end -- ties: the lower id
                        end
                    end
                end
                if checkpoint then checkpoint() end
            end
            if best then
                commit(best)
            elseif leadUp then
                leadUp = false
            elseif next(parked) and not retried then
                parked, retried = {}, true -- a quest too slow before may share a camp by now
            else
                break
            end
        end
    end

    -- A class quest plan: the chain and its lead-up, every quest of it that can be placed, best
    -- XP per added second first, however little it pays.
    local function fillChain()
        while true do
            local best, bestKey
            for _, m in ipairs(candidates) do
                if remaining[m] and m.must and not exclusiveWith(m, routedIds) and ready(r, m) then
                    local added, gain = r:try(m, false)
                    if added then
                        local key = gain / max(added, 1)
                        if not best or key > bestKey then best, bestKey = m, key end
                    end
                end
                if checkpoint then checkpoint() end
            end
            if not best then break end
            commit(best)
        end
    end

    -- remaining / routedIds follow r.routed (after every restore)
    local function sync()
        for _, m in ipairs(candidates) do
            remaining[m] = not r.routed[m] or nil
            routedIds[m.id] = r.routed[m] or nil
        end
    end

    -- Take a quest out of the route, and what follows from it. `onOut(m)` (optional) sees each
    -- quest before it goes (the debug trace records its stops).
    local function takeOut(m, onOut)
        if not r.routed[m] then return end
        if onOut then onOut(m) end
        local after = {}
        for _, d in ipairs(m.dependents or {}) do after[#after + 1] = d end
        for _, d in ipairs(after) do takeOut(d, onOut) end -- follow-ups cannot stay without it
        r:removeQuest(m)
        remaining[m], routedIds[m.id] = true, nil
    end

    -- Keep a previous order: rebuild the route stop by stop from its keys, leaving out what
    -- is done or gone. Quests new since then are added by the greedy step below.
    local function rebuild(order)
        local byId = {}
        for _, m in ipairs(candidates) do byId[m.id] = m end
        local open = {} -- quests whose P is placed (or that need none) and whose T is not
        for _, m in ipairs(candidates) do
            if not m.pickup and not m.border then m.W = {}; open[m] = true end
        end
        local function append(node)
            r.route[#r.route + 1] = node
            r.pos[node] = #r.route
        end
        local function work(m, task, key)
            local node = r.taskNodes[key]
            if not node then
                node = r:node("W", task.loc, key)
                node.mob = task.kills ~= nil
                r:setReqs(node, {})
                r.taskNodes[key] = node
                append(node)
            end
            r:addReq(node, { quest = m, task = task })
            m.W[#m.W + 1] = node
            task.placed = true
        end
        for _, key in ipairs(order) do
            local kind, rest = key:match("^(%a):(.+)$")
            if kind == "P" then
                local m = byId[tonumber(rest)]
                if m and m.pickup and remaining[m] and not m.P and ready(r, m) and not m.border then
                    m.P = r:node("P", m.pickup)
                    m.P.quest, m.W = m, {}
                    append(m.P)
                    open[m] = true
                end
            elseif kind == "W" then
                for _, m in ipairs(candidates) do
                    if open[m] then
                        for _, task in ipairs(m.tasks) do
                            if not task.placed and (task.key == rest or (task.key .. "#" .. m.id) == rest) then work(m, task, rest) end
                        end
                    end
                end
            elseif kind == "T" then
                local m = byId[tonumber(rest)]
                if m and open[m] then
                    for _, task in ipairs(m.tasks) do
                        if not task.placed then work(m, task, task.key .. "#" .. m.id) end
                    end
                    m.T = r:node("T", m.turnin)
                    m.T.quest = m
                    append(m.T)
                    open[m] = nil
                    r.routed[m], remaining[m], routedIds[m.id] = true, nil, true
                    for _, d in ipairs(m.deps or {}) do
                        d.dependents = d.dependents or {}
                        d.dependents[#d.dependents + 1] = m
                    end
                end
            end
        end
        -- A quest started in the old order but not finished there: take it out again and let
        -- the greedy step place it.
        for m in pairs(open) do
            if m.P or #(m.W or {}) > 0 then
                r:removeQuest(m)
                for _, task in ipairs(m.tasks) do task.placed = nil end
            else
                m.W = nil
            end
        end
    end

    -- The way across a zone border planned together (opts.seam, from Zones.Itinerary through
    -- Zones.PlanSeam). The route is the stretch around the crossing only: it starts where the first
    -- zone's route is before the stretch (ctx is the character as they will be there), holds the
    -- stretch's stops of both zones (sp.keysA, then sp.keysB; camps on the far side named "...@B") and
    -- ends at the place the rest of the path starts at (sp.endLoc: `endNode`, no time). A stop stays on
    -- its side of the crossing (`cross`, see R:bounds). Only quests done inside the stretch on one side
    -- (sp.side "A"/"B") and those that may come in (sp.free) move; a quest done on both sides ("X"),
    -- one that goes on after the stretch (sp.ghost: its stops here are kept, but belong to no planned
    -- quest), and every quest those or the next zone's rest (sp.after) follow stay as they are. Judged
    -- by R:seamValue. Returns { keysA, keysB (each side's keys as found, far-side names undone),
    -- out (ids of moving quests left out), added (ids of quests that came in), start, value
    -- (R:seamValue before and after), legStart, legBest (seconds of the leg across the crossing),
    -- rounds, moving } or nil when the stretch cannot be rebuilt.
    local function seamSearch()
        local sp = opts.seam
        local side, ghost, free = sp.side or {}, sp.ghost or {}, sp.free or {}
        local byId = {}
        for _, m in ipairs(candidates) do
            byId[m.id] = m
            local s = (side[m.id] == "A" or side[m.id] == "B") and side[m.id] or free[m.id]
            if s and not ghost[m.id] then
                m.seamSide = s
                if s == "B" then -- (a camp on the far side is another stop than one of that name here)
                    for _, t in ipairs(m.tasks) do
                        if t.key and not t.key:find("@B", 1, true) then t.key = t.key .. "@B" end
                    end
                end
            end
        end
        local route, pos = r.route, r.pos
        local part, open = "A", {}
        for _, m in ipairs(candidates) do
            if (side[m.id] or ghost[m.id]) and not m.pickup then m.W = {}; open[m] = true end
        end
        local function append(node)
            route[#route + 1] = node
            pos[node] = #route
            node.side = part
        end
        local function onSide(key) -- a task's key as it is named on this part's side
            if part == "B" and not key:find("@B", 1, true) then return key .. "@B" end
            return key
        end
        local function attach(m, task, key)
            local node = r.taskNodes[key]
            if not node or not pos[node] then
                node = r:node("W", task.loc, key)
                node.mob = task.kills ~= nil
                r:setReqs(node, {})
                r.taskNodes[key], r.nodeCache[key] = node, node
                append(node)
            end
            local req = task.req
            if not req or req.quest ~= m then req = { quest = m, task = task }; task.req = req end
            r:addReq(node, req)
            if not ghost[m.id] then m.W[#m.W + 1] = node end
            task.placed = true
        end
        local function step(key)
            local kind, rest = key:match("^(%a):(.+)$")
            if kind == "P" then
                local m = byId[tonumber(rest)]
                if m and (side[m.id] or ghost[m.id]) and m.pickup and not open[m] and not r.routed[m] and ready(r, m) then
                    local node = m.nodeP or r:node("P", m.pickup)
                    m.nodeP, node.quest = node, m
                    if not ghost[m.id] then m.P = node end
                    m.W = m.W or {}
                    append(node)
                    open[m] = true
                end
            elseif kind == "W" then
                local base, priv = rest:match("^([^#]*)(.*)$")
                local jk = onSide(base) .. priv
                for _, m in ipairs(candidates) do
                    if open[m] then
                        for _, task in ipairs(m.tasks) do
                            if not task.placed and task.key then
                                local tk = onSide(task.key)
                                if tk == jk or (tk .. "#" .. m.id) == jk then
                                    task.key = tk
                                    attach(m, task, jk)
                                end
                            end
                        end
                    end
                end
            elseif kind == "T" then
                local m = byId[tonumber(rest)]
                if m and open[m] and not ghost[m.id] then
                    for _, task in ipairs(m.tasks) do
                        if not task.placed and task.key then
                            local tk = onSide(task.key)
                            task.key = tk
                            attach(m, task, tk .. "#" .. m.id)
                        end
                    end
                    local node = m.nodeT or r:node("T", m.turnin)
                    m.nodeT, node.quest, m.T = node, m, node
                    append(node)
                    open[m] = nil
                    r.routed[m], remaining[m], routedIds[m.id] = true, nil, true
                    for _, d in ipairs(m.deps or {}) do
                        d.dependents = d.dependents or {}
                        d.dependents[#d.dependents + 1] = m
                    end
                end
            end
        end
        for _, key in ipairs(sp.keysA or {}) do step(key); if checkpoint then checkpoint() end end
        part = "B"
        for _, key in ipairs(sp.keysB or {}) do step(key); if checkpoint then checkpoint() end end
        -- a quest started in the stretch and not finished there (and not one that goes on after it): out again
        for _, m in ipairs(candidates) do
            if open[m] and not ghost[m.id] then
                if m.P or #(m.W or {}) > 0 then r:removeQuest(m) else m.W = nil end
                open[m] = nil
            end
        end
        if sp.endLoc then
            local e = r:node("E", sp.endLoc)
            route[#route + 1] = e
            pos[e] = #route
            e.side = "B"
            r.endNode = e
        end
        r:reindex(1)
        for _, m in ipairs(candidates) do
            for _, task in ipairs(m.tasks) do task.placed = nil end
        end
        local c = 1
        for i = 2, #r.route do if r.route[i].side == "A" then c = i end end
        r.cross = c
        if not r:valid() then return nil end
        -- what stays as it is: a quest done on both sides, and every quest that one of those, one going
        -- on after the stretch or one of the next zone's rest follows (taking it out takes those along)
        local fixed = {}
        for _, m in ipairs(candidates) do
            if side[m.id] == "X" and r.routed[m] then fixed[m] = true end
        end
        for _, m in ipairs(candidates) do
            if ghost[m.id] or (sp.after and sp.after[m.id]) then
                for _, list in ipairs({ m.deps or {}, m.baseDeps or {}, m.anyDeps or {} }) do
                    for _, d in ipairs(list) do if r.routed[d] then fixed[d] = true end end
                end
            end
        end
        local changed = true
        while changed do
            changed = false
            for _, m in ipairs(candidates) do
                if fixed[m] then
                    for _, d in ipairs(m.deps or {}) do
                        if r.routed[d] and not fixed[d] then fixed[d], changed = true, true end
                    end
                end
            end
            if checkpoint then checkpoint() end
        end
        -- what moves: quests done on one side (in the route or not) and those that may come in
        local only, list = {}, {}
        for _, m in ipairs(candidates) do
            if m.seamSide and not fixed[m] then only[m] = true; list[#list + 1] = m end
        end
        -- a quest before the level it needs: out again (one that stays: the stretch cannot be planned)
        while true do
            local m = r:brokenGate()
            if not m then break end
            if not only[m] then return nil end
            takeOut(m)
        end
        r.seam = { horizon = sp.horizon, switch = sp.switch or 0, tail = sp.tail, scale = 1 }
        local start = r:seamValue(opts.overhead)
        local _, x0 = r:totals()
        r.seam.scale = max(x0, 1) -- (the search's margins: a share of what the stretch earns)
        local cr = r.cross
        local legStart = cr < #r.route and r:tt(r.route[cr], r.route[cr + 1]) or 0
        local found
        if (sp.rounds or 0) > 0 then
            -- the quests that may come in, where they pay as a search round would take them back:
            -- kept when the stretch is worth more for it
            local snap = r:snapshot()
            local t, x = r:totals()
            fill(0, Planner.PRUNE_RATIO * x / max(t, 1), nil, nil, only)
            if not (r:seamValue(opts.overhead) > start) then r:restore(snap, candidates); sync() end
            found = ns.Search.Run({
                r = r, candidates = list, overhead = opts.overhead, rounds = sp.rounds, work = sp.work,
                seed = sp.seed or 1, warm = true, checkpoint = checkpoint,
                fill = function(regretWeight, floorRatio, fresh) fill(regretWeight, floorRatio, nil, fresh, only) end,
                takeOut = function(m, onOut) if only[m] then takeOut(m, onOut) end end,
                restore = function(s) r:restore(s, candidates); sync() end,
            })
        end
        local keysA, keysB = {}, {}
        for i = 2, #r.route do
            local n = r.route[i]
            if n.kind ~= "E" then
                local key = n.kind == "W" and ("W:" .. (n.key:gsub("@B", "", 1))) or (n.kind .. ":" .. n.quest.id)
                if i <= r.cross then keysA[#keysA + 1] = key else keysB[#keysB + 1] = key end
            end
        end
        local outIds, added = {}, {}
        for _, m in ipairs(list) do
            if not r.routed[m] then
                if side[m.id] then outIds[#outIds + 1] = m.id end
            elseif free[m.id] then
                added[#added + 1] = m.id
            end
        end
        cr = r.cross
        return { keysA = keysA, keysB = keysB, out = outIds, added = added, start = start,
            value = r:seamValue(opts.overhead), rounds = found and found.rounds or 0, moving = #list,
            legStart = legStart, legBest = cr < #r.route and r:tt(r.route[cr], r.route[cr + 1]) or 0 }
    end

    if opts.seam then
        return { zone = zoneMap, seam = seamSearch(), work = r.work }
    end

    if opts.seed then rebuild(opts.seed) end

    if exact then
        -- (the seed is the route: nothing else is added)
    elseif ctx.chain then
        fillChain()
    elseif border then
        -- only the quests taken along, after the first stop and before the stop the zone is left
        -- after (see R:bounds)
        local taken = {}
        for _, m in ipairs(candidates) do if m.border then taken[m] = true end end
        r.borderFill = { cap = nodeOfKey(r, border.before) }
        fill(0, nil, false, nil, taken)
        r.borderFill = nil
    else
        fill(0, nil, ctx.dungeon ~= nil)
    end

    -- Stops the player stands at now, further down the kept route: brought to its front, each
    -- after the one before, when nothing they wait for (an accept, the work, a prerequisite's
    -- turn-in, a level) comes before them.
    local fronted
    if opts.seed and opts.front then
        local at = 1
        for _, key in ipairs(opts.front) do
            local kind, id = key:match("^([PT]):(%d+)$")
            id = tonumber(id)
            local node
            for i = at + 1, #r.route do
                local n = r.route[i]
                if n.kind == kind and n.quest.id == id then node = n; break end
            end
            if node then
                local lo = r:bounds(node)
                if lo <= at then
                    r:unplace(node)
                    r:place(node, at)
                    at = at + 1
                    fronted = fronted or {}
                    fronted[#fronted + 1] = key
                end
            end
        end
    end
    -- The step in hand (opts.first, a key of an order: "P:id", "T:id" or "W:key"): made the
    -- first stop of the seeded route when nothing it waits for comes before it.
    if opts.seed and opts.first then
        for i = 3, #r.route do
            local n = r.route[i]
            local key = n.kind == "W" and ("W:" .. n.key) or (n.kind .. ":" .. n.quest.id)
            if key == opts.first then
                if r:bounds(n) <= 1 then
                    r:unplace(n)
                    r:place(n, 1)
                end
                break
            end
        end
    end
    -- The surplus goal: R, the XP per second the player can get elsewhere. Given by the caller
    -- (ctx.altRate: see Zones.Rank), else the greedy route's own score stands in for it.
    if (ctx.goal or Planner.GOAL) == "surplus" then
        r.goalR = (ctx.altRate or r:score(opts.overhead)) * Planner.ALT_SHARE
    end
    local searched, unsearched, found, searchOrder = false, nil, nil, nil
    local searchStartWork
    if not opts.seed then
        r:improve(Planner.IMPROVE_PASSES, checkpoint, 1)
        -- A dungeon plan is one run with its lead-up: there is little to search.
        local rounds = ctx.searchRounds or Planner.SEARCH_ITERATIONS
        local searching = rounds > 0 and not ctx.dungeon and not ctx.chain
        -- the route as it would be without the search (see the end): always the cold greedy one
        if searching then unsearched = r:snapshot() end
        searchStartWork = r.work
        -- Warm start: begin the search from the order an earlier plan of this zone ended on
        -- (opts.warm), when that is at least as good as the greedy route.
        local warmUsed = false
        if searching and opts.warm and Planner.WARM_START then
            local cold = unsearched
            local coldWorth = r:goalWorth(opts.overhead)
            r:clear(candidates); sync()
            rebuild(opts.warm)
            -- a quest before the level it needs: out again, the greedy step places it after the level-up
            while true do
                local m = r:brokenGate()
                if not m then break end
                takeOut(m)
            end
            -- quests new since that plan, and only those that pay as a search round would take
            -- them back (the ones the search left out then are left out now)
            local t, x = r:totals()
            fill(0, Planner.PRUNE_RATIO * x / max(t, 1), false)
            r:improve(Planner.IMPROVE_PASSES, checkpoint, 1)
            if r:valid() and r:goalWorth(opts.overhead) >= coldWorth then
                warmUsed = true
            else
                r:restore(cold, candidates); sync()
            end
            for _, m in ipairs(candidates) do
                for _, task in ipairs(m.tasks) do task.placed = nil end
            end
        end
        frame("start", warmUsed and { warm = true } or nil)
        if searching then
            found = ns.Search.Run({
                r = r, candidates = candidates, overhead = opts.overhead,
                rounds = warmUsed and math.min(rounds, Planner.WARM_ROUNDS) or rounds,
                work = ctx.searchWork,                        -- work: optional budget in work units
                seed = (zoneMap % 100000) * 7919 + (ctx.level or 1) * 104729 + #candidates * 31 + 1,
                weights = opts.weights,                       -- optional, from an earlier search
                warm = warmUsed,                              -- true when started from an earlier plan
                checkpoint = checkpoint, progress = ctx.progress,
                fill = function(regretWeight, floorRatio, fresh)
                    -- nearby places only for the repair inside a round. No pcall here: the
                    -- repair calls the checkpoint, which yields the coroutine, and the game's
                    -- Lua cannot yield through a pcall. (An error ends the whole plan anyway.)
                    if Planner.NEAR_SCOPE ~= "all" then r.nearK = Planner.NEAR_K end
                    fill(regretWeight, floorRatio, nil, fresh)
                    r.nearK = nil
                end,
                takeOut = takeOut,
                restore = function(snap) r:restore(snap, candidates); sync() end,
                frame = trace and frame or nil,
            })
            searched = true
            found.warm = warmUsed
            -- The route the search ended on, as step keys: what the next plan of this zone
            -- starts from. (The plan's own order is tidied after this: made shorter, slow
            -- quests dropped, so it is worth a little less than the route the search found.)
            searchOrder = {}
            for i = 2, #r.route do
                local node = r.route[i]
                searchOrder[#searchOrder + 1] = node.kind == "W" and ("W:" .. node.key)
                    or ((node.kind == "P" and "P:" or "T:") .. node.quest.id)
            end
        end
    end

    -- Tidy the route as it stands and describe it as a plan: list what stayed out, drop slow
    -- quests, batch accepts, shorten, solve short stretches exactly. Works on its own copy of
    -- the lists, so it can be run on more than one route.
    local collected = lists
    local function finish(searched)
        local lists = {}
        for name, list in pairs(collected) do
            local copy = {}
            for i, e in ipairs(list) do copy[i] = e end
            lists[name] = copy
        end
        for _, m in ipairs(candidates) do
            if remaining[m] and not exclusiveWith(m, routedIds) then
                -- after a search, a quest that fits but stayed out is one that did not pay
                local added, gain
                -- (a route kept with quests taken along adds nothing else: what stayed out is weighed
                -- as after a search; an exact seed, too)
                if (searched or border or exact) and ready(r, m) and not m.border then added, gain = r:try(m, false) end
                if m.border then
                    local e = listEntry(m, "not before leaving for the next zone")
                    e.xp = m.borderXP
                    lists.skipped[#lists.skipped + 1] = e
                elseif m.gate then
                    lists.later[#lists.later + 1] = listEntry(m) -- the route does not reach its level (or not in time)
                elseif added then
                    lists.skipped[#lists.skipped + 1] = listEntry(m,
                        string.format("slow: about %d XP per hour here", floor(gain / max(added, 1) * 3600)))
                else
                    lists.unlocated[#lists.unlocated + 1] = listEntry(m, "could not be placed in the route")
                end
            end
        end


        -- Drop quests that pay far less per second than the rest of the route does without them. A quest that others
        -- in the route depend on stays. Quests already in the log are dropped the same way: the
        -- plan simply does not spend time on them.
        local nRouted = 0
        for _ in pairs(r.routed) do nRouted = nRouted + 1 end
        -- (an exact seed keeps every quest it has)
        while nRouted > 1 and not exact do
            local t0, x0 = r:totals()
            if t0 <= 0 then break end
            local worst, worstRatio
            for _, m in ipairs(candidates) do
                -- (with quests taken along only they may go: the rest of the route is kept as it is)
                if r.routed[m] and not m.must and #(m.dependents or {}) == 0 and (not border or m.border) then
                    local t1, x1 = r:totals(m)
                    local ratio = (x0 - x1) / max(t0 - t1, 1)
                    -- (a quest taken along pays where it is finished: that XP against its time here)
                    if m.borderXP then ratio = (x0 - x1 + m.borderXP) / max(t0 - t1, 1) end
                    local rest = x1 / max(t1, 1) -- what the route earns per second without this quest
                    if ratio < rest * Planner.PRUNE_RATIO and (not worst or ratio < worstRatio
                        or (ratio == worstRatio and m.id < worst.id)) then
                        worst, worstRatio = m, ratio
                    end
                end
                if checkpoint then checkpoint() end
            end
            if not worst then break end
            local e = listEntry(worst, string.format("slow: about %d XP per hour here", floor(worstRatio * 3600)))
            if worst.borderXP then e.xp = worst.borderXP end -- (the XP it pays where it is finished)
            lists.skipped[#lists.skipped + 1] = e
            r:removeQuest(worst)
            nRouted = nRouted - 1
        end

        if not opts.seed then
            if ctx.progress then ctx.progress("order") end
                r:batchPickups()
            -- Shorter is not always better: batching turn-ins saves walking but pays out later.
            -- Try shorter orders (runs of stops moved together). A move is kept unless it costs
            -- more than a few percent of the peak XP per hour: doing the work at a camp while we
            -- are there beats coming back for it, even if a turn-in then pays out a little later.
            local before, order = r:guardScore(opts.overhead), {}
            for i, node in ipairs(r.route) do order[i] = node end
            local floor_ = r.goalR and (before - Planner.SCORE_GIVE * abs(before)) or before * (1 - Planner.SCORE_GIVE)
            r:improve(Planner.IMPROVE_PASSES, checkpoint, Planner.SEGMENT_MOVES, { overhead = opts.overhead, floor = floor_ })
                if Planner.EXACT_WINDOW >= 3 and not ctx.dungeon then
                r:exactWindows(Planner.EXACT_WINDOW, opts.overhead, checkpoint)
            end
            r:batchPickups()
            if r:guardScore(opts.overhead) < floor_ - 1e-9 then -- cannot happen move by move; kept as a safeguard
                for node in pairs(r.pos) do r.pos[node] = nil end
                r.route = order
                r:reindex(1)
            end
        end

        -- Dropping and moving stops can push a level-up back: a quest left before the level it
        -- needs comes out again (with what follows from it) and waits.
        while true do
            local m = r:brokenGate()
            if not m then break end
            local function out(q)
                local after = {}
                for _, d in ipairs(q.dependents or {}) do after[#after + 1] = d end
                for _, d in ipairs(after) do out(d) end
                if r.routed[q] then
                    r:removeQuest(q)
                    nRouted = nRouted - 1
                    lists.later[#lists.later + 1] = listEntry(q, q.gate and nil or "follows a quest that waits for a level")
                end
            end
            out(m)
        end

        local plan = { zone = zoneMap, lists = lists, overhead = opts.overhead or 0, quests = nRouted }
        describe(r, plan)
        frame("final", { unsearched = unsearched ~= nil and not searched or nil })
        -- Log space: quests held at once along the route.
        local held, peakHeld = ctx.logCount or 0, ctx.logCount or 0
        for _, step in ipairs(plan.steps) do
            if step.kind == "accept" then held = held + 1 elseif step.kind == "turnin" then held = held - 1 end
            if held > peakHeld then peakHeld = held end
        end
        plan.logFull = ctx.capacity and peakHeld > ctx.capacity or false
        for _, list in pairs(lists) do table.sort(list, function(a, b) return a.id < b.id end) end
        return plan
    end

    local plan = finish(searched)
    if border then
        -- what is taken along (for Zones' `project`): what is left of each after this zone
        plan.border, plan.borderIds = {}, {}
        for _, m in ipairs(candidates) do
            if m.border and r.routed[m] then
                plan.border[m.id] = { to = m.borderTo, left = m.borderLeft }
                plan.borderIds[#plan.borderIds + 1] = m.id
            end
        end
        for _, id in ipairs(borderGone) do
            plan.border[id] = { to = border.to and border.to[id], left = 0, gone = true }
            plan.borderIds[#plan.borderIds + 1] = id
        end
        table.sort(plan.borderIds)
    end
    local spent = searched and (r.work - searchStartWork) or nil
    if fronted then -- (what the tidy-up kept of it)
        local kept, inPlan = {}, {}
        for _, key in ipairs(plan.order) do inPlan[key] = true end
        for _, key in ipairs(fronted) do if inPlan[key] then kept[#kept + 1] = key end end
        plan.fronted = #kept > 0 and kept or nil
    end
    -- The search maximises the route's worth before the tidy-up, and the tidy-up can undo part
    -- of that. So the route as it was before the search is tidied the same way, and the plan
    -- that scores higher is the answer: a searched plan is never worse than a plain one.
    if unsearched then
        r:restore(unsearched, candidates)
        sync()
        local plain = finish(false)
        if (r.goalR and plain.value > plan.value) or (not r.goalR and plain.score > plan.score) then
            plan = plain
            if trace then remove(trace, #trace - 1) end -- the searched route's last frame goes
        elseif trace then
            trace[#trace] = nil
        end
        plan.plainScore = plain.score -- the unsearched route's score: a lower bound of a searched plan's (rate goal)
    end
    plan.searchSpent = spent -- work units of the warm start, the search and its tidy-up
    plan.trace = trace
    plan.search = found -- { rounds, work, weights, worth } or nil
    plan.work = r.work  -- all work units of this plan (build, search, finish of both routes)
    plan.inputs = inputs -- what the plan read about quests (ns.Memory)
    plan.searchOrder = searchOrder -- the route the search ended on, as keys (nil without a search): a warm start's seed
    return plan
end
