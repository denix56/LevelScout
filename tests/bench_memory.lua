-- tests/bench_memory.lua: where the addon's memory goes (kB of Lua heap, after a full collection).
-- Usage (from the repo root):  .tools/bin/lua5.1 tests/bench_memory.lua
-- Options (environment): CHAR=3 (number in the list below), RANKS=3 (re-rankings to run).
local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."
package.path = root .. "/tests/?.lua;" .. package.path
local H = require("harness")
local M = require("mocks")
M.install()

local CHARACTERS = {
    { 7, "Alliance", "WARRIOR", 1, 1429, 43.8, 65.9, "Elwynn, Goldshire" },
    { 22, "Alliance", "PALADIN", 1, 1433, 30.0, 44.0, "Redridge, Lakeshire" },
    { 35, "Alliance", "HUNTER", 3, 1424, 50.0, 58.0, "Hillsbrad, Southshore" },
    { 42, "Alliance", "WARRIOR", 1, 1446, 51.0, 28.0, "Tanaris, Gadgetzan" },
    { 25, "Horde", "WARLOCK", 5, 1424, 62.0, 20.0, "Hillsbrad, Tarren Mill" },
}
local char = CHARACTERS[tonumber(os.getenv("CHAR")) or 3]
local RANKS = tonumber(os.getenv("RANKS")) or 3

local function live()
    collectgarbage("collect"); collectgarbage("collect")
    return collectgarbage("count")
end
local last = live()
local function report(label, extra)
    local now = live()
    io.write(string.format("%-46s %9.0f kB  (%+9.0f)%s\n", label, now, now - last, extra and ("  " .. extra) or ""))
    last = now
end
-- Garbage made by fn: the heap's growth with the collector stopped.
local function churn(fn)
    live()
    collectgarbage("stop")
    local before = collectgarbage("count")
    local a, b = fn()
    local made = collectgarbage("count") - before
    collectgarbage("restart")
    return made, a, b
end

report("empty harness")
local level, faction, class, race, map, x, y = unpack(char)
-- The real QuestieDB, in the import tools' sandbox. In the game its data is TOC metadata held by
-- the client, outside the Lua heap; here the whole TOC is a Lua string, so this line is much
-- bigger than QuestieDB's in-game memory. The lines after it are what LevelScout adds.
local L = M.questieDB(faction, class)
report("QuestieDB loaded (sandbox; not like the game)")
local ns = {}
for _, file in ipairs(H.tocFiles()) do
    if file:match("^data/") then
        H.loadAddon({ file }, ns)
        report("  " .. file)
    end
end
local rest = {}
for _, file in ipairs(H.tocFiles()) do
    if not file:match("^data/") and file ~= "Init.lua" then rest[#rest + 1] = file end
end
H.loadAddon({ "Init.lua" }, ns)
H.loadAddon(rest, ns)
report("code")

local t0 = os.clock()
ns.Data.Init({ faction = faction, class = class, clientBuild = ns.data.meta.build }, L)
report("Data.Init", string.format("%.0f ms", (os.clock() - t0) * 1000))
local made
t0 = os.clock()
made = churn(function() ns.Data.BuildIndex() end)
report("Data.BuildIndex", string.format("allocated %.0f kB, %.0f ms (sandbox CPU)", made, (os.clock() - t0) * 1000))

local completed = {}
for _, id in ipairs(ns.Data.QuestIds()) do -- (QuestieDB's level: building every record would fill the cache)
    local qlevel = L.Quest.Exists(id) and L.Quest.Get(id, "questLevel") or 0
    if qlevel > 0 and qlevel <= level - 4 then completed[id] = true end
end
L.InvalidateCache("Quest") -- (what those reads left in QuestieDB is the bench's, not the addon's)
local state = { level = level, faction = faction, class = class, raceId = race, map = map, x = x / 100, y = y / 100,
    log = {}, completed = completed, capacity = 40, knownNodes = {}, now = 0, memory = ns.Memory.New() }
for id, n in pairs(ns.data.world.travel.nodes) do
    if n[7] == "n" or n[7] == (faction == "Alliance" and "a" or "h") then state.knownNodes[id] = true end
end
if ns.Geo.Init then ns.Geo.Init(ns.Data.World()) end
report("state (" .. char[8] .. ", level " .. level .. ")")

local ranked, itinerary
for i = 1, RANKS do
    state.now = (i - 1) * 400 -- past Zones.REUSE_MAX_AGE: every zone is planned again
    local ctx
    local m = churn(function()
        ctx = ns.Zones.Context(state)
        ranked = ns.Zones.Rank(ctx)
    end)
    report("Zones.Rank #" .. i, string.format("allocated %.0f kB, %d zones", m, #ranked))
    m = churn(function()
        itinerary = ns.Zones.Itinerary(state, ctx, ranked, { shown = ranked[1].map, plan = ranked[1].plan, was = itinerary })
    end)
    ctx = nil
    report("Zones.Itinerary #" .. i, string.format("allocated %.0f kB", m))
end

-- What holds it: the size of each long-lived root, by dropping it.
local function drop(label, fn) fn(); report("  without " .. label) end
io.write("\nBy owner (each line: the heap after dropping it)\n")
drop("the itinerary", function() itinerary = nil end)
drop("the ranked plans", function() ranked = nil end)
drop("the plan memory", function() state.memory = nil; state = nil end)
drop("QuestieDB's read caches", function() L.InvalidateCache() end)
drop("the data caches, records and index", function()
    ns.Data.Init({ faction = faction, class = class }, M.fakeQuestieDB()) -- (another QuestieDB: nothing kept)
end)
