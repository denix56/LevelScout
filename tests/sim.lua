-- tests/sim.lua: plan for an imagined character on the real data and print the result.
-- Usage (from the repo root):
--   .tools/bin/lua5.1 tests/sim.lua <level> <Alliance|Horde> <CLASS> <raceId> <uiMap> <x> <y> [zone to print]
-- Example: a level 7 human warrior at Goldshire:
--   .tools/bin/lua5.1 tests/sim.lua 7 Alliance WARRIOR 1 1429 43.8 65.9
local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."
package.path = root .. "/tests/?.lua;" .. package.path
local print = function(...) io.write(table.concat({ ... }, " "), "\n") end
local H = require("harness")
local M = require("mocks")
M.install()
local ns = H.loadAddon()
local level, faction, class, race = tonumber(arg[1]) or 7, arg[2] or "Alliance", arg[3] or "WARRIOR", tonumber(arg[4]) or 1
local map, x, y = tonumber(arg[5]) or 1429, tonumber(arg[6]) or 43.8, tonumber(arg[7]) or 65.9
ns.Data.Init({ faction = faction, class = class, clientBuild = ns.data.meta.build }, M.questieDB(faction, class))
ns.Data.BuildIndex()
if os.getenv("SEGMENT") then ns.Planner.SEGMENT_MOVES = tonumber(os.getenv("SEGMENT")) end -- 0 = single stops only
if os.getenv("LEVELS") then ns.Planner.LEVELS_AHEAD = tonumber(os.getenv("LEVELS")) end -- 0 = value the route at today's level
if os.getenv("HORIZON") then ns.Planner.MIN_HORIZON = tonumber(os.getenv("HORIZON")) end -- seconds, to compare windows

-- An imagined history: every quest more than 3 levels below the character is done.
local completed = {}
if not os.getenv("FRESH") then
    for _, id in ipairs(ns.Data.QuestIds()) do
        local q = ns.Data.GetQuest(id)
        if q and q.level > 0 and q.level <= level - 4 then completed[id] = true end
    end
end
local state = { level = level, faction = faction, class = class, raceId = race, map = map, x = x / 100, y = y / 100,
    log = {}, completed = completed, capacity = 40 }
-- The longest stretch the planner runs without offering to yield: in game that is the most
-- one frame can be held up (on top of the 4 ms budget).
local last, longest, yields = os.clock(), 0, 0
state.checkpoint = function()
    local now = os.clock()
    if now - last > longest then longest = now - last end
    last, yields = now, yields + 1
end
if os.getenv("FLIGHTS") then -- pretend every flight point of our side is known
    state.knownNodes = {}
    for id, n in pairs(ns.data.world.travel.nodes) do
        if n[7] == "n" or n[7] == (faction == "Alliance" and "a" or "h") then state.knownNodes[id] = true end
    end
end
local t0 = os.clock()
last = t0
local ctx = ns.Zones.Context(state)
local ranked = ns.Zones.Rank(ctx)
local elapsed = os.clock() - t0
local function hm(s) return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60)) end
print(string.format("level %d %s %s at map %d (%.1f, %.1f): %d zones planned in %.0f ms; longest stretch without a yield point %.1f ms (%d yield points)",
    level, faction, class, map, x, y, #ranked, elapsed * 1000, longest * 1000, yields))
for i, z in ipairs(ranked) do
    local p = z.plan
    print(string.format("%d. map %d (levels %s-%s)  %5.0f XP/h  %d quests, %d steps, %s, %d XP; leave after step %d; skipped %d, later %d, group %d, no location %d",
        i, z.map, tostring(z.lo), tostring(z.hi), p.score, p.quests, #p.steps, hm(p.seconds), p.xp, p.peak,
        #p.lists.skipped, #p.lists.later, #p.lists.group, #p.lists.unlocated))
end
do -- the next hours across zones
    local t1 = os.clock()
    local it = ns.Zones.Itinerary(state, ctx, ranked)
    if it then
        local parts = {}
        for _, seg in ipairs(it.segments) do
            parts[#parts + 1] = string.format("map %d: %s there after a %s trip, %d XP%s%s", seg.map, hm(seg.seconds), hm(seg.travel), seg.xp,
                seg.leaveKey and (" (leave after " .. seg.leaveKey .. ")") or "",
                (seg.carried or 0) > 0 and string.format(" (%d carried turn-ins, %d XP)", seg.carried, seg.carriedXP) or "")
        end
        print(string.format("\nitinerary, %d min: %s\n  %d XP = %.0f XP/h; best single zone %d XP (%+.1f%%); found in %.0f ms",
            it.horizon / 60, table.concat(parts, "  ->  "), it.xp, it.rate, it.stay or 0, it.stay and (it.xp / it.stay - 1) * 100 or 0,
            (os.clock() - t1) * 1000))
    end
end
local want = tonumber(arg[8]) or (ranked[1] and ranked[1].map)
for _, z in ipairs(ranked) do
    if z.map == want then
        print("\nplan for map " .. z.map .. " (trip to the first step: " .. hm(z.plan.steps[1] and z.plan.steps[1].travel or 0) .. "):")
        for i, s in ipairs(z.plan.steps) do
            local names = {}
            for _, q in ipairs(s.quests) do names[#names + 1] = q.name end
            if s.group then names[#names + 1] = s.findGroup and "<GROUP: find one first>" or "<GROUP>" end
            if s.needLevel then names[#names + 1] = "<needs level " .. s.needLevel .. ">" end
            if s.levelUp then names[#names + 1] = "<LEVEL " .. s.levelUp .. ">" end
            print(string.format("%2d%s %-7s %-34s %5.1f,%5.1f  walk %4s  do %5s  +%-5d  at %s  [%s]", i, s.tail and "~" or " ", s.action,
                tostring(s.target):sub(1, 34) .. (s.kills and (" x" .. s.kills) or ""), s.loc.mx or 0, s.loc.my or 0, hm(s.travel), hm(s.seconds), s.xp, hm(s.t),
                table.concat(names, "; "):sub(1, 60)))
        end
        for name, list in pairs(z.plan.lists) do
            for _, e in ipairs(list) do print(string.format("  %-9s [%d] %s (level %d)%s", name, e.id, e.name, e.level, e.reason and (": " .. e.reason) or (e.needLevel and (": level " .. e.needLevel) or ""))) end
        end
    end
end
