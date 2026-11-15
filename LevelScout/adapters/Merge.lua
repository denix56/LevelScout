-- adapters/Merge.lua
--
-- Builds LevelScout's compact records at runtime from two sources:
--   QuestieDB  the installed addon, read only through its public API (the `LibQuestieDB`
--              global, contract 4). QuestieDB applies its own corrections for the logged-in
--              character's faction and class when it loads, so every read here is already
--              right for this character.
--   ForeverDB  the baked layer in LevelScout/data (ns.data.fdb, ForeverDB.net data only):
--              Forever titles and levels, CMaNGOS objective counts, players' captures, XP,
--              drop rates and Forever-observed spots.
-- Records are the packed strings described in docs/data-format.md; adapters/Data.lua parses
-- and caches them. Field priorities are the same as the build-time merge had (same doc).
-- Pure Lua apart from the LibQuestieDB table it is given: runs in the standalone tests.

local _, ns = ...

local Merge = {}
ns.Merge = Merge

--- The LibQuestieDB contract this code is written against (QuestieDB/src/api.lua).
Merge.CONTRACT = 4
--- Where players get QuestieDB (CurseForge project page).
Merge.QUESTIEDB_URL = "https://www.curseforge.com/wow/addons/questiedb"

local floor, concat, insert, sort = math.floor, table.concat, table.insert, table.sort
local format, tostring, tonumber, type, pairs, ipairs = string.format, tostring, tonumber, type, pairs, ipairs

---------------------------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------------------------

local function list(t) return type(t) == "table" and t or {} end

local function split(s, sep)
    local out, start = {}, 1
    if s == nil then return out end
    while true do
        local a = s:find(sep, start, true)
        if not a then out[#out + 1] = s:sub(start); return out end
        out[#out + 1] = s:sub(start, a - 1)
        start = a + #sep
    end
end

local function numbers(s)
    local out = {}
    for n in tostring(s or ""):gmatch("%d+") do out[#out + 1] = tonumber(n) end
    return out
end

local function words(s)
    local out = {}
    for w in tostring(s or ""):gmatch("%S+") do out[#out + 1] = w end
    return out
end

local function nz(v) if v == nil or v == 0 or v == "" then return nil end return v end

--- a & b for non-negative integers up to 2^53 (race masks use bits above 32).
local function band(a, b)
    local result, bit = 0, 1
    a, b = a or 0, b or 0
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then result = result + bit end
        a, b, bit = floor(a / 2), floor(b / 2), bit * 2
    end
    return result
end
Merge.band = band

local function hasFlag(v, flag) return v ~= nil and v % (2 * flag) >= flag end

local function joinIds(ids)
    local out = {}
    for _, id in ipairs(ids or {}) do out[#out + 1] = tostring(id) end
    return concat(out, ",")
end

local function uniqueSorted(ids)
    local seen, out = {}, {}
    for _, id in ipairs(ids) do
        if id and not seen[id] then seen[id] = true; out[#out + 1] = id end
    end
    sort(out)
    return out
end

local function clean(s)
    if s == nil then return "" end
    return (tostring(s):gsub("|", "/"):gsub("[\r\n]+", " "))
end

local function record(s) return s and split(s, "|") or nil end

---------------------------------------------------------------------------------------------
-- Map spots: base-36 of uiMap * 1e6 + x10 * 1e3 + y10 (the same packing ForeverDB uses)
---------------------------------------------------------------------------------------------

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

local function base36(n)
    if n == 0 then return "0" end
    local out = {}
    while n > 0 do
        local d = n % 36
        insert(out, 1, DIGITS:sub(d + 1, d + 1))
        n = floor(n / 36)
    end
    return concat(out)
end

function Merge.Spot(map, x, y)
    local xi = math.min(999, math.max(0, floor(x * 10 + 0.5)))
    local yi = math.min(999, math.max(0, floor(y * 10 + 0.5)))
    return base36(map * 1e6 + xi * 1e3 + yi)
end
local Spot = Merge.Spot

function Merge.DecodeSpot(token)
    local n = tonumber(token, 36)
    if not n then return nil end
    local map = floor(n / 1e6)
    local r = n % 1e6
    return map, floor(r / 1e3) / 10, (r % 1e3) / 10
end

local function addSpots(set, order, tokens)
    for _, t in ipairs(tokens) do
        if not set[t] then set[t] = true; order[#order + 1] = t end
    end
end

---------------------------------------------------------------------------------------------
-- Source parsing (ForeverDB record layouts: the legend in each ForeverDB data file)
---------------------------------------------------------------------------------------------

-- QuestieDB's support tables are Lua source strings ("return {...}"). Run with no globals.
local function loadDataString(s)
    if type(s) ~= "string" then return {} end
    local chunk = loadstring(s)
    if not chunk then return {} end
    setfenv(chunk, {})
    local ok, t = pcall(chunk)
    return ok and type(t) == "table" and t or {}
end

local QC = { title = 1, level = 2, min = 3, side = 4, classes = 5, races = 6, needsAll = 7, needsOne = 8,
    excl = 9, starts = 10, ends = 11, objectives = 12, skill = 13, flags = 14 }
local QF = { title = 1, level = 2, min = 3, text = 4, starts = 5, ends = 6, seen = 7, new = 8, prev = 9,
    lowest = 10, side = 11 }
Merge.QC, Merge.QF = QC, QF

-- "c6:10;i782:8;o176245:1;a178;c123:5:44,55" -> { {k, id, count, credit = {...}}, ... }
function Merge.ParseClassicObjectives(s)
    local out = {}
    for part in tostring(s or ""):gmatch("[^;]+") do
        local k, id, rest = part:match("^([cioa])(%d+):?(.*)$")
        if k then
            local count, credit = rest:match("^(%d*):?(.*)$")
            out[#out + 1] = { k = (k == "a") and "e" or k, id = tonumber(id), count = tonumber(count),
                credit = numbers(credit), area = (k == "a") and tonumber(id) or nil }
        end
    end
    return out
end

-- "c:8,i:5,o:3" -> { {k = "c", count = 8}, ... }; "" -> {}
function Merge.ParseCapturedObjectives(s)
    local out = {}
    for k, n in tostring(s or ""):gmatch("(%a):(%d+)") do out[#out + 1] = { k = k, count = tonumber(n) } end
    return out
end

local CAPTURE_KIND = { c = "c", i = "i", o = "o", e = "e", s = "x", r = "x", x = "x" }

--- Typical XP of quests like this one, for quests whose XP no source has recorded.
--- Groups the quests with known XP by level and kind and takes the median and quartiles:
---   d = dungeon or raid quest, o = has objectives, t = no objectives (talk-to, delivery)
--- A level with fewer than MIN_SAMPLES quests borrows from neighbouring levels (up to 5 away).
--- `quests` = { [id] = packed quest record }. Returns { [kind] = { [level] = { median, q1, q3 } } }.
local XP_MIN_SAMPLES, XP_WINDOWS = 5, { 0, 1, 2, 3, 5 }
function Merge.XpKind(flags, objectives)
    if flags:find("d", 1, true) or flags:find("r", 1, true) then return "d" end
    return objectives ~= "" and "o" or "t"
end
function Merge.XpLevel(level, minLevel)
    local l = (level and level > 0) and level or (minLevel or 0)
    return math.max(1, math.min(60, l))
end
--- Quest statistics gathered over every quest (by Data.BuildIndex), for the XP estimates and
--- the dungeon quest lists: { xp = { [kind] = { [level] = { xp, ... } } }, dungeonArea = { [id] = area } }.
function Merge.NewStats() return { xp = { d = {}, o = {}, t = {} }, dungeonArea = {} } end

local function addXpSample(stats, xp, level, kind)
    if xp and xp > 0 then
        local t = stats.xp[kind]
        local l = t[level]
        if not l then l = {}; t[level] = l end
        l[#l + 1] = xp
    end
end

--- Add one quest's packed record to the statistics.
function Merge.CountRecord(stats, id, rec)
    local f = split(rec, "|")
    addXpSample(stats, tonumber(f[11]), Merge.XpLevel(tonumber(f[2]), tonumber(f[3])), Merge.XpKind(f[10], f[15]))
    local area = tonumber(f[30]) or 0
    if area > 0 and f[10]:find("d", 1, true) then stats.dungeonArea[id] = area end
end

function Merge.XpEstimates(quests)
    local stats = Merge.NewStats()
    for id, rec in pairs(quests) do Merge.CountRecord(stats, id, rec) end
    return Merge.XpEstimatesFrom(stats)
end

function Merge.XpEstimatesFrom(stats)
    local byKind = stats.xp
    local out = {}
    for kind, byLevel in pairs(byKind) do
        out[kind] = {}
        for level = 1, 60 do
            for _, w in ipairs(XP_WINDOWS) do
                local v = {}
                for l = level - w, level + w do
                    for _, xp in ipairs(byLevel[l] or {}) do v[#v + 1] = xp end
                end
                if #v >= XP_MIN_SAMPLES then
                    sort(v)
                    local function q(p) return v[math.max(1, math.min(#v, floor(p * (#v - 1) + 1.5)))] end
                    out[kind][level] = { q(0.5), q(0.25), q(0.75) }
                    break
                end
            end
        end
    end
    return out
end

---------------------------------------------------------------------------------------------
-- The QuestieDB dependency
---------------------------------------------------------------------------------------------

local ENTITY_FUNCTIONS = { "Get", "GetAll", "GetAllIds", "Exists" }

--- Is this a QuestieDB we can read? Returns ok, state ("ok"|"missing"|"version"|"broken"), message.
--- `L` is the `LibQuestieDB` global (nil when QuestieDB is not installed or not enabled).
function Merge.Check(L)
    if type(L) ~= "table" then
        return false, "missing", "QuestieDB is missing. LevelScout reads its quest data from the QuestieDB addon: "
            .. "install or enable QuestieDB (" .. Merge.QUESTIEDB_URL .. "), then /reload."
    end
    local version = L.addonName and rawget(_G, "C_AddOns") and C_AddOns.GetAddOnMetadata
        and select(2, pcall(C_AddOns.GetAddOnMetadata, L.addonName, "Version")) or nil
    local have = format("QuestieDB %s (contract %s)", tostring(type(version) == "string" and version or "?"),
        tostring(L.contractVersion))
    if type(L.RequireContract) ~= "function" then
        return false, "version", format("%s is too old for LevelScout, which needs QuestieDB contract %d or newer. "
            .. "Update QuestieDB (%s), then /reload.", have, Merge.CONTRACT, Merge.QUESTIEDB_URL)
    end
    local called, ok, msg = pcall(L.RequireContract, Merge.CONTRACT)
    if not called or not ok then
        return false, "version", format("%s does not work with this LevelScout, which needs QuestieDB contract %d. %s",
            have, Merge.CONTRACT, called and type(msg) == "string" and msg or "Update whichever is older, then /reload.")
    end
    for _, name in ipairs({ "Quest", "Npc", "Object", "Item" }) do
        local e = L[name]
        for _, fn in ipairs(ENTITY_FUNCTIONS) do
            if type(e) ~= "table" or type(e[fn]) ~= "function" then
                return false, "broken", format("%s is missing LibQuestieDB.%s.%s; reinstall QuestieDB, then /reload.",
                    have, name, fn)
            end
        end
    end
    if type(L.Support) ~= "table" or type(L.Support.Get) ~= "function" or type(L.Enum) ~= "table" then
        return false, "broken", have .. " is missing LibQuestieDB.Support or .Enum; reinstall QuestieDB, then /reload."
    end
    return true, "ok", nil, have
end

---------------------------------------------------------------------------------------------
-- The merge
---------------------------------------------------------------------------------------------

local L, F, E -- LibQuestieDB, ns.data.fdb, LibQuestieDB.Enum
local a2u, parent, dungeonZones, xpdb, dropCorr, DK, raceA, raceH, eventSorts
local drops -- QuestieDB's drop-rate tables, parsed on first use: { wowhead = ..., cmangos = ... }
local universe, questIds, excluded, startMap

local function uiMapOf(areaId)
    if not areaId or areaId <= 0 then return nil end
    return a2u[areaId] or (parent[areaId] and a2u[parent[areaId]]) or nil
end
Merge.UiMapOf = function(areaId) return a2u and uiMapOf(areaId) or nil end

local function spawnsToTokens(spawns)
    local out = {}
    for areaId, points in pairs(list(spawns)) do
        local map = uiMapOf(areaId)
        if map then
            for _, p in ipairs(list(points)) do
                if type(p[1]) == "number" and type(p[2]) == "number" and p[1] >= 0 then
                    out[#out + 1] = Spot(map, p[1], p[2])
                end
            end
        end
    end
    return out
end

local QK = { "name", "startedBy", "finishedBy", "requiredLevel", "questLevel", "requiredRaces",
    "requiredClasses", "objectivesText", "triggerEnd", "objectives", "sourceItemId", "preQuestGroup",
    "preQuestSingle", "exclusiveTo", "zoneOrSort", "requiredSkill", "requiredMinRep", "requiredMaxRep",
    "nextQuestInChain", "questFlags", "specialFlags", "parentQuest", "breadcrumbForQuestId", "requiredMaxLevel" }
local function qdbQuest(id)
    local packed = L.Quest.GetAll(id, QK)
    if not packed then return nil end
    local r = {}
    for i, k in ipairs(QK) do r[k] = packed[i] end
    return r
end

local function exclusionReason(id)
    if F.qcGone[id] then return "ForeverDB: classic quest players have never been offered in Forever" end
    if id < 10000 and universe[id] == "q" and not F.qcQuests[id] and not F.qfQuests[id] then
        return "not in the Forever client (absent from ForeverDB's client-filtered classic table)"
    end
end

--- Connect to QuestieDB and the ForeverDB layer. Returns true, or false and an error message.
--- `lib` = LibQuestieDB (already checked with Merge.Check), `fdb` = ns.data.fdb.
function Merge.Open(lib, fdb)
    Merge.ready = false
    L, F = lib, fdb
    for _, name in ipairs({ "qcQuests", "qfQuests", "qcNpc", "qcObj", "qcItem", "qcGone", "qcExcl", "qfPoi",
        "qfSeen", "qfNpcSpots", "qfNpcNames", "qfItems", "qfArea", "qobj", "questXP", "qdrop", "npcLv", "npcSpot",
        "groupSize", "startMap", "dungeons" }) do
        if type(F) ~= "table" or type(F[name]) ~= "table" then
            return false, "LevelScout's ForeverDB data table '" .. name .. "' is missing; reinstall LevelScout"
        end
    end
    E = L.Enum
    local zoneDB = L.Support.Get("ZoneDB")
    local Z = type(zoneDB) == "table" and zoneDB.private
    if type(Z) ~= "table" or type(E.factionRaceMasks) ~= "table" or type(E.sortKeys) ~= "table" then
        return false, "QuestieDB's zone tables or enums are missing; reinstall QuestieDB"
    end
    a2u = loadDataString(Z.areaIdToUiMapId)
    for k, v in pairs(loadDataString(Z.areaIdToUiMapIdOverride)) do a2u[k] = v end
    parent = loadDataString(Z.subZoneToParentZone)
    for k, v in pairs(loadDataString(Z.subZoneToParentZoneOverride)) do parent[k] = v end
    dungeonZones = {}
    Merge.dungeonEntries = type(Z.dungeons) == "table" and Z.dungeons or {}
    for areaId, entry in pairs(Merge.dungeonEntries) do
        dungeonZones[areaId] = true
        for _, alt in ipairs(list(entry[2])) do dungeonZones[alt] = true end
    end
    local xp = L.Support.Get("QuestXP")
    xpdb = type(xp) == "table" and type(xp.db) == "table" and xp.db or {}
    local corr = L.Support.Get("QuestieItemDropCorrections")
    dropCorr = type(corr) == "table" and type(corr.Era) == "table" and corr.Era or {}
    DK = E.dropCorrectionKeys or {}
    drops = nil
    raceA, raceH = E.factionRaceMasks.Alliance, E.factionRaceMasks.Horde
    eventSorts = {}
    for name, v in pairs(E.sortKeys) do
        if name:match("FESTIV") or name:match("SEASONAL") or name:match("DARKMOON") or name:match("HALLOW")
            or name:match("LUNAR") or name:match("MIDSUMMER") or name:match("WINTER_VEIL") or name:match("CHILDREN")
            or name:match("LOVE_IS") or name:match("NOBLEGARDEN") or name:match("BREWFEST") or name:match("HARVEST")
            or name:match("PILGRIM") or name:match("INVASION") or name:match("AHN_QIRAJ_WAR") then
            eventSorts[v] = true
        end
    end
    -- The quests: QuestieDB's, ForeverDB's classic (client-filtered) and Forever tables.
    universe, excluded, questIds = {}, {}, {}
    for _, id in ipairs(L.Quest.GetAllIds()) do universe[id] = "q" end
    for id in pairs(F.qcQuests) do universe[id] = universe[id] or "f" end
    for id in pairs(F.qfQuests) do universe[id] = universe[id] or "f" end
    for id in pairs(universe) do
        local reason = exclusionReason(id)
        if reason then excluded[id] = reason else questIds[#questIds + 1] = id end
    end
    sort(questIds)
    startMap = F.startMap
    Merge.ready = true
    return true
end

--- QuestieDB keeps every field it has decoded. The index reads a few fields of every quest
--- once, and LevelScout keeps its own records, so QuestieDB's copy of those reads (some 4 MB) is
--- given back afterwards through its public InvalidateCache. Not when Questie itself is loaded:
--- it reads the same quests all session and would only decode them again.
function Merge.ReleaseQuestCache()
    if rawget(_G, "Questie") or rawget(_G, "QuestieLoader") then return false end
    if type(L) ~= "table" or type(L.InvalidateCache) ~= "function" then return false end
    return (pcall(L.InvalidateCache, "Quest"))
end

--- Every quest id LevelScout plans with, ascending (shared list: do not change it).
function Merge.QuestIds() return questIds end
--- Why a quest is left out ({ [id] = reason }), for the debug output and the tests.
function Merge.Excluded() return excluded end

--- QuestieDB's enums the availability check needs (QuestieDB's own tables: read-only).
function Merge.Enum()
    return { raceMaskById = E.raceMaskById, classKeys = E.classKeys, factionRaceMasks = E.factionRaceMasks,
        npcFlags = E.npcFlags }
end

-------------------------------------------------------------------------------- quests

local function giversString(qdbGivers, fdbSpec)
    local parts = {}
    local g = list(qdbGivers)
    for _, n in ipairs(list(g[1])) do parts[#parts + 1] = "n" .. n end
    for _, o in ipairs(list(g[2])) do parts[#parts + 1] = "o" .. o end
    for _, i in ipairs(list(g[3])) do parts[#parts + 1] = "i" .. i end
    if #parts == 0 and fdbSpec then
        for _, w in ipairs(words(fdbSpec)) do
            if w:match("^[noi]%d+$") then parts[#parts + 1] = w end
        end
    end
    return concat(parts, " ")
end

local function qdbObjectives(id, o, trigger)
    local out = {}
    local first = L.ObjectiveFirst or {}
    local function add(e, set)
        if type(set) == "table" and set[id] then insert(out, 1, e) else out[#out + 1] = e end
    end
    o = list(o)
    for _, e in ipairs(list(o[1])) do add({ k = "c", ids = { e[1] } }) end
    for _, e in ipairs(list(o[2])) do add({ k = "o", ids = { e[1] } }, first.objectObjectiveFirst) end
    for _, e in ipairs(list(o[3])) do add({ k = "i", ids = { e[1] } }, first.itemObjectiveFirst) end
    if type(o[4]) == "table" then add({ k = "r", ids = { o[4][1] }, count = o[4][2], src = "Q" }) end
    for _, e in ipairs(list(o[5])) do
        local ids = {}
        for _, n in ipairs(list(e[1])) do ids[#ids + 1] = n end
        if #ids == 0 and e[2] then ids[1] = e[2] end
        add({ k = "c", ids = ids, root = e[2] }, first.killCreditObjectiveFirst)
    end
    for _, e in ipairs(list(o[6])) do add({ k = "x", ids = { e[1] }, item = e[3] }, first.spellObjectiveFirst) end
    if type(trigger) == "table" then
        add({ k = "e", ids = {}, count = 1, src = "Q", spawns = trigger[2] }, first.eventObjectiveFirst)
    end
    return out
end

local function matchClassicCounts(objs, classic)
    local used = {}
    for _, ob in ipairs(objs) do
        if not ob.count then
            for ci, c in ipairs(classic) do
                if not used[ci] and c.k == ob.k then
                    local hit = false
                    if ob.k == "e" then hit = true
                    else
                        for _, id in ipairs(ob.ids) do
                            if id == c.id then hit = true end
                            for _, cr in ipairs(c.credit) do if cr == id then hit = true end end
                        end
                        if ob.root and ob.root == c.id then hit = true end
                    end
                    if hit then
                        used[ci] = true
                        ob.count, ob.src = c.count or 1, "C"
                        if c.area then ob.area = c.area end
                        break
                    end
                end
            end
        end
    end
end

local function matchCapturedCounts(objs, captured)
    local used = {}
    for _, ob in ipairs(objs) do
        if not ob.count then
            local want = CAPTURE_KIND[ob.k] or ob.k
            for ci, c in ipairs(captured) do
                if not used[ci] and (CAPTURE_KIND[c.k] or c.k) == want then
                    used[ci] = true
                    ob.count, ob.src = c.count, "F"
                    break
                end
            end
        end
    end
end

local function objectivesString(objs)
    local parts = {}
    for _, ob in ipairs(objs) do
        parts[#parts + 1] = ob.k .. joinIds(ob.ids) .. ":" .. (ob.count and tostring(ob.count) or "")
            .. ":" .. (ob.src or "")
    end
    return concat(parts, ";")
end

local function sideOf(races, fallback)
    if races and races > 0 then
        local a, h = band(races, raceA) > 0, band(races, raceH) > 0
        if a and not h then return "a" end
        if h and not a then return "h" end
        return ""
    end
    if fallback == "a" or fallback == "h" then return fallback end
    return ""
end

local function mergeTokenField(...)
    local set, order = {}, {}
    for i = 1, select("#", ...) do
        local s = select(i, ...)
        if type(s) == "string" then addSpots(set, order, words(s)) end
    end
    return order
end

local function pair(p) return type(p) == "table" and p[1] and (p[1] .. ":" .. tostring(p[2] or "")) or "" end

-- The fields the index also needs, computed the same way for a full record (Merge.Quest) and
-- for the index's short read (Merge.QuestIndex).
local function levelsOf(q, qc, qf)
    local level = tonumber(qf and nz(qf[QF.level])) or (q and nz(q.questLevel)) or tonumber(qc and qc[QC.level]) or 0
    local min = tonumber(qf and nz(qf[QF.min])) or (q and nz(q.requiredLevel)) or tonumber(qc and qc[QC.min]) or 0
    return level, min
end

local function zoneOf(id, zos)
    return (zos > 0 and uiMapOf(zos)) or (zos == 0 and startMap[id]) or 0
end

local function isDungeon(zos, cflags)
    return (zos > 0 and dungeonZones[zos]) or cflags:find("d", 1, true) ~= nil
end

-- XP: ForeverDB's player captures first, then QuestieDB's trace table.
local function xpOf(id)
    local fx = F.questXP[id]
    local qx = xpdb[id]
    if type(fx) == "number" and fx > 0 then return fx, "f" end
    if type(qx) == "table" and (qx[1] or 0) > 0 and (qx[2] or 0) > 0 then return qx[2], "q" end
    return "", ""
end

local function startersOf(q, qc, qf)
    return giversString(q and q.startedBy, (qc and nz(qc[QC.starts])) or (qf and qf[QF.starts]))
end

-- QuestieDB's prerequisites when it knows the quest (it splits CMaNGOS' fields into
-- all-of/one-of itself); CMaNGOS' fields only for quests it lacks.
local function prerequisitesOf(q, qc)
    if q then
        return joinIds(uniqueSorted(list(q.preQuestGroup))), joinIds(uniqueSorted(list(q.preQuestSingle)))
    end
    return joinIds(uniqueSorted(numbers(qc and qc[QC.needsAll]))), joinIds(uniqueSorted(numbers(qc and qc[QC.needsOne])))
end

-- Where the quest starts, as Forever players saw it (client POI points and observations).
local function startSpotsOf(id)
    local P, S = F.qfPoi[id], F.qfSeen[id]
    local s = mergeTokenField(P and P.s, S and S.s)
    return #s > 0 and concat(s, " ") or nil
end

--- The packed quest record, its objective text and its Forever-observed spots
--- ({ s, e, [objectiveIndex] } or nil). nil for a quest LevelScout leaves out.
function Merge.Quest(id)
    if not universe[id] or excluded[id] then return nil end
    local q = universe[id] == "q" and qdbQuest(id) or nil
    local qc, qf = record(F.qcQuests[id]), record(F.qfQuests[id])
    local r = {}
    r.name = clean((qf and nz(qf[QF.title])) or (q and q.name) or (qc and qc[QC.title]) or ("Quest " .. id))
    r.level, r.min = levelsOf(q, qc, qf)
    r.max = q and q.requiredMaxLevel or 0
    r.races = (q and q.requiredRaces) or tonumber(qc and qc[QC.races]) or 0
    r.classes = (q and q.requiredClasses) or tonumber(qc and qc[QC.classes]) or 0
    r.side = sideOf(r.races, (qf and qf[QF.side] ~= "" and qf[QF.side]) or (qc and qc[QC.side]))
    local zos = q and q.zoneOrSort or 0
    r.zone = zoneOf(id, zos)
    r.sort = zos < 0 and zos or 0
    r.area = zos > 0 and zos or 0
    -- flags
    local f = {}
    local cflags = qc and qc[QC.flags] or ""
    if isDungeon(zos, cflags) then f[#f + 1] = "d" end
    if cflags:find("r", 1, true) then f[#f + 1] = "r" end
    if cflags:find("g", 1, true) then f[#f + 1] = "g" end
    if (q and hasFlag(q.specialFlags, 1)) or cflags:find("p", 1, true) then f[#f + 1] = "p" end
    if q and hasFlag(q.questFlags, 4096) then f[#f + 1] = "y" end
    if q and hasFlag(q.questFlags, 32768) then f[#f + 1] = "w" end
    if qf and qf[QF.new] == "1" then f[#f + 1] = "n" end
    if not qc and not qf then f[#f + 1] = "u" end
    if eventSorts[zos] then f[#f + 1] = "v" end
    r.flags = concat(f)
    r.xp, r.xpSrc = xpOf(id)
    -- givers
    r.starts = startersOf(q, qc, qf)
    r.ends = giversString(q and q.finishedBy, (qc and nz(qc[QC.ends])) or (qf and qf[QF.ends]))
    -- objectives: QuestieDB structure and order, counts from CMaNGOS (via ForeverDB) or captures
    local objs = q and qdbObjectives(id, q.objectives, q.triggerEnd) or {}
    local classic = Merge.ParseClassicObjectives(qc and qc[QC.objectives])
    if #objs == 0 and #classic > 0 then
        for _, c in ipairs(classic) do
            local ids = { c.id }
            for _, cr in ipairs(c.credit) do ids[#ids + 1] = cr end
            objs[#objs + 1] = { k = c.k, ids = c.k == "e" and {} or ids, count = c.count or 1, src = "C", area = c.area }
        end
    else
        matchClassicCounts(objs, classic)
    end
    local captured = Merge.ParseCapturedObjectives(F.qobj[id])
    if #objs == 0 and #captured > 0 then
        for _, c in ipairs(captured) do objs[#objs + 1] = { k = c.k, ids = {}, count = c.count, src = "F" } end
    else
        matchCapturedCounts(objs, captured)
    end
    r.objectives = objectivesString(objs)
    -- chains and requirements
    r.preAll, r.preAny = prerequisitesOf(q, qc)
    local excl = {}
    for _, e in ipairs(list(q and q.exclusiveTo)) do excl[#excl + 1] = e end
    local group = tonumber(qc and qc[QC.excl])
    if group and group ~= 0 and F.qcExcl[group] then
        for _, e in ipairs(numbers(F.qcExcl[group])) do if e ~= id then excl[#excl + 1] = e end end
    end
    r.exclusive = joinIds(uniqueSorted(excl))
    r.breadcrumbFor = q and q.breadcrumbForQuestId or ""
    r.nextInChain = q and q.nextQuestInChain or ""
    r.parent = q and q.parentQuest or ""
    r.repMin, r.repMax = pair(q and q.requiredMinRep), pair(q and q.requiredMaxRep)
    r.skill = (q and pair(q.requiredSkill) ~= "" and pair(q.requiredSkill)) or (qc and qc[QC.skill] or "")
    r.sourceItem = q and q.sourceItemId or ""
    r.groupSize = F.groupSize[id] or ""
    r.seen = qf and tonumber(qf[QF.seen]) or ""
    r.prevSeen = qf and tonumber(qf[QF.prev]) or ""
    r.lowest = qf and tonumber(qf[QF.lowest]) or ""
    -- free text, kept out of the record
    local text = q and list(q.objectivesText)[1] or (qf and nz(qf[QF.text])) or nil
    text = text and clean(text) or nil
    -- Forever-observed locations: client POI points and players' observations
    local P, S = F.qfPoi[id] or {}, F.qfSeen[id] or {}
    local spots = {}
    spots.s = startSpotsOf(id)
    local e = mergeTokenField(P.e, S.e)
    if #e > 0 then spots.e = concat(e, " ") end
    for i, ob in ipairs(objs) do
        local t = mergeTokenField(P.o and P.o[i], S.o and S.o[i])
        if #t == 0 and ob.spawns then t = spawnsToTokens(ob.spawns) end
        if #t == 0 and ob.area and F.qfArea[ob.area] then t = words(F.qfArea[ob.area]) end
        if #t > 0 then spots[i] = concat(uniqueSorted(t), " ") end
    end
    local rec = concat({ r.name, r.level, r.min, r.max, r.side, format("%.0f", r.races), r.classes, r.zone,
        r.sort, r.flags, r.xp, r.xpSrc, r.starts, r.ends, r.objectives, r.preAll, r.preAny, r.exclusive,
        r.breadcrumbFor, r.nextInChain, r.parent, r.repMin, r.repMax, r.skill, r.sourceItem, r.groupSize,
        r.seen, r.prevSeen, r.lowest, r.area }, "|")
    return rec, text, next(spots) and spots or nil
end

-- The QuestieDB fields the index reads (a scalar row and five of the quest's table fields).
local IK_QUEST = { "zoneOrSort", "startedBy", "preQuestGroup", "preQuestSingle", "questLevel", "requiredLevel",
    "objectives", "triggerEnd", "requiredClasses" }

--- What the index needs of a quest, without building its record: zone (uiMap), starters,
--- preAll, preAny (as in the record), its start spots (as questSpots.s) and its classes mask. Adds the quest to
--- `stats` (Merge.NewStats) the way Merge.CountRecord adds its full record.
function Merge.QuestIndex(id, stats)
    if not universe[id] or excluded[id] then return nil end
    local q
    if universe[id] == "q" then
        local packed = L.Quest.GetAll(id, IK_QUEST)
        if packed then
            q = {}
            for i, k in ipairs(IK_QUEST) do q[k] = packed[i] end
        end
    end
    local qc, qf = record(F.qcQuests[id]), record(F.qfQuests[id])
    local zos = q and q.zoneOrSort or 0
    local preAll, preAny = prerequisitesOf(q, qc)
    if stats then
        local cflags = qc and qc[QC.flags] or ""
        local dungeon = isDungeon(zos, cflags)
        local kind
        if dungeon or cflags:find("r", 1, true) then kind = "d"
        else
            local any = q and #qdbObjectives(id, q.objectives, q.triggerEnd) > 0
                or #Merge.ParseClassicObjectives(qc and qc[QC.objectives]) > 0
                or #Merge.ParseCapturedObjectives(F.qobj[id]) > 0
            kind = any and "o" or "t"
        end
        local xp = xpOf(id)
        addXpSample(stats, tonumber(xp), Merge.XpLevel(levelsOf(q, qc, qf)), kind)
        if zos > 0 and dungeon then stats.dungeonArea[id] = zos end
    end
    local classes = (q and q.requiredClasses) or tonumber(qc and qc[QC.classes]) or 0
    return zoneOf(id, zos), startersOf(q, qc, qf), preAll, preAny, startSpotsOf(id), classes
end

-------------------------------------------------------------------------------- entities

local NK = { "name", "minLevel", "maxLevel", "rank", "spawns", "zoneID", "friendlyToFaction", "npcFlags" }

--- `name|minLevel|maxLevel|rank|npcFlags|friendly|spots`, or nil when neither source knows the NPC.
function Merge.Npc(id)
    local p = L.Npc.Exists(id) and L.Npc.GetAll(id, NK) or nil
    local qc = F.qcNpc[id] and split(F.qcNpc[id], "|") or nil
    local name = F.qfNpcNames[id] or (p and p[1]) or (qc and qc[1])
    if not name then return nil end
    local minL, maxL = p and p[2] or 0, p and p[3] or 0
    local lv = F.npcLv[id]
    if type(lv) == "number" and lv > 0 then minL, maxL = floor(lv / 100), lv % 100 end
    local set, order = {}, {}
    addSpots(set, order, spawnsToTokens(p and p[5]))
    addSpots(set, order, words(F.qfNpcSpots[id]))
    if #order == 0 and qc then addSpots(set, order, words(qc[2])) end
    if #order == 0 and F.npcSpot[id] then addSpots(set, order, { F.npcSpot[id] }) end
    return concat({ clean(name), minL or 0, maxL or 0, p and p[4] or 0, p and p[8] or 0, p and p[7] or "",
        concat(order, " ") }, "|")
end

--- The dungeon (its id in the dungeon table, world.dungeons) an NPC or object (kind "npc" or
--- "object") stands in, from the areas of its QuestieDB spawns: nil when it has a spawn outside
--- every dungeon, or none known. Needs Merge.DungeonsFrom (the index) to have run.
function Merge.InstanceOf(kind, id)
    local areaDungeon = Merge.areaDungeon
    if not areaDungeon then return nil end
    local entity = kind == "npc" and L.Npc or (kind == "object" and L.Object or nil)
    if not (entity and entity.Exists(id)) then return nil end
    local spawns = list(entity.Get(id, "spawns"))
    local found
    for areaId in pairs(spawns) do
        local d = areaDungeon[areaId]
        if not d then return nil end -- (also stands outside: not a dungeon's own)
        found = found or d
    end
    if not found and kind == "npc" then found = areaDungeon[entity.Get(id, "zoneID") or 0] end
    return found
end

--- `name|spots`, or nil.
function Merge.Object(id)
    local exists = L.Object.Exists(id)
    local name = exists and L.Object.Get(id, "name") or nil
    local qc = F.qcObj[id] and split(F.qcObj[id], "|") or nil
    name = name or (qc and qc[1])
    if not name then return nil end
    local set, order = {}, {}
    addSpots(set, order, spawnsToTokens(exists and L.Object.Get(id, "spawns")))
    if qc then addSpots(set, order, words(qc[2])) end
    return clean(name) .. "|" .. concat(order, " ")
end

--- QuestieDB's drop-rate tables (Lua source in its support data), parsed once.
function Merge.LoadDropTables()
    if drops then return drops end
    local support = L.Support.Get("QuestieClassicItemDrops")
    support = type(support) == "table" and support or {}
    drops = { wowhead = loadDataString(support.wowheadData), cmangos = loadDataString(support.cmangosData) }
    return drops
end

local function dropRate(itemId, npcId)
    local fd = F.qdrop[itemId]
    if fd and type(fd[npcId]) == "number" then return fd[npcId], "f" end
    local d = drops or Merge.LoadDropTables()
    local wowhead, cmangos = d.wowhead, d.cmangos
    local c = dropCorr[itemId] and dropCorr[itemId][npcId]
    if type(c) == "number" then
        if c >= 0 then return c, "c" end
        if c == DK.WOWHEAD and wowhead[itemId] and wowhead[itemId][npcId] then return wowhead[itemId][npcId], "w" end
        if c == DK.PSERVER and cmangos[itemId] and cmangos[itemId][npcId] then return cmangos[itemId][npcId], "m" end
    end
    if cmangos[itemId] and cmangos[itemId][npcId] then return math.abs(cmangos[itemId][npcId]), "m" end
    if wowhead[itemId] and wowhead[itemId][npcId] then return wowhead[itemId][npcId], "w" end
    return nil
end

-- Rates are drop chances in percent. Wowhead reports items per kill, which can exceed 100.
local function fmtRate(v)
    v = math.max(0, math.min(100, v))
    return (format("%.2f", v):gsub("%.?0+$", ""))
end

local IK = { "name", "npcDrops", "objectDrops", "vendors" }

--- `name|drops|objects|vendors`, or nil.
function Merge.Item(id)
    local p = L.Item.Exists(id) and L.Item.GetAll(id, IK) or nil
    local name = F.qfItems[id] or (p and p[1])
    if not name then return nil end
    local npcSet, npcs = {}, {}
    local function addNpc(n) if n and not npcSet[n] then npcSet[n] = true; npcs[#npcs + 1] = n end end
    for _, n in ipairs(list(p and p[2])) do addNpc(n) end
    for n in pairs(F.qdrop[id] or {}) do addNpc(n) end
    local qcRates = {}
    for _, w in ipairs(words(F.qcItem[id])) do
        local k, sid, pct = w:match("^([no])(%d+):([%d%.]+)$")
        if k then qcRates[k .. sid] = tonumber(pct); if k == "n" then addNpc(tonumber(sid)) end end
    end
    sort(npcs)
    local dropParts = {}
    for _, n in ipairs(npcs) do
        local rate, src = dropRate(id, n)
        if not rate and qcRates["n" .. n] then rate, src = qcRates["n" .. n], "k" end
        dropParts[#dropParts + 1] = n .. ":" .. (rate and fmtRate(rate) or "") .. ":" .. (src or "")
    end
    local objSet, objs = {}, {}
    for _, o in ipairs(list(p and p[3])) do if not objSet[o] then objSet[o] = true; objs[#objs + 1] = o end end
    for key in pairs(qcRates) do
        local o = key:match("^o(%d+)$")
        if o and not objSet[tonumber(o)] then objSet[tonumber(o)] = true; objs[#objs + 1] = tonumber(o) end
    end
    sort(objs)
    local objParts = {}
    for _, o in ipairs(objs) do
        local rate = qcRates["o" .. o]
        objParts[#objParts + 1] = o .. ":" .. (rate and fmtRate(rate) or "") .. ":" .. (rate and "k" or "")
    end
    return concat({ clean(name), concat(dropParts, " "), concat(objParts, " "), joinIds(uniqueSorted(list(p and p[4]))) }, "|")
end

-------------------------------------------------------------------------------- dungeons

--- world.dungeons: ForeverDB's 5-player dungeons with a known entrance and their quests: the
--- quests ForeverDB players confirmed in Forever, plus the quests QuestieDB files under the
--- dungeon's area. The two sources name dungeons differently, so they are matched by where
--- the entrance is. `quests` = { [id] = packed record } of every quest (see Merge.QuestIds).
function Merge.Dungeons(quests)
    local stats, exists = Merge.NewStats(), {}
    for id, rec in pairs(quests) do Merge.CountRecord(stats, id, rec); exists[id] = true end
    return Merge.DungeonsFrom(stats, exists)
end

--- The same from Merge.NewStats statistics; `exists` = { [questId] = true } of every quest.
function Merge.DungeonsFrom(stats, exists)
    local function norm(n) return (tostring(n):lower():gsub("^the ", ""):gsub("[^%a]", "")) end
    local areasOf, anyArea = {}, {}
    for id, d in pairs(F.dungeons) do
        local map, ex, ey = Merge.DecodeSpot(words(d.ent)[1] or "")
        local matches = {}
        for areaId, entry in pairs(Merge.dungeonEntries) do
            for _, at in ipairs(list(entry[4])) do
                if map and uiMapOf(at[1]) == map and math.abs(at[2] - ex) < 4 and math.abs(at[3] - ey) < 4 then
                    matches[#matches + 1] = { areaId, entry }
                    break
                end
            end
        end
        if #matches > 1 then -- several dungeons behind one door: the name decides
            local byName = {}
            for _, mt in ipairs(matches) do
                local a, b = norm(mt[2][1]), norm(d.n)
                if a == b or a:find(b, 1, true) or b:find(a, 1, true) then byName[#byName + 1] = mt end
            end
            matches = byName
        end
        local areas = {}
        if #matches == 1 then
            areas[matches[1][1]] = true
            for _, alt in ipairs(list(matches[1][2][2])) do areas[alt] = true end
        end
        areasOf[id] = areas
        for a in pairs(areas) do anyArea[a] = true end
    end
    -- Which dungeon an area is (for Merge.InstanceOf). A dungeon whose door was not matched
    -- above (the Deadmines, the Stockade, ...) is matched to QuestieDB's dungeon of the same
    -- name here; its quest list below stays as it was (ForeverDB's confirmed quests).
    Merge.areaDungeon = {}
    for id, areas in pairs(areasOf) do
        for a in pairs(areas) do Merge.areaDungeon[a] = id end
        if not next(areas) then
            local want = norm(F.dungeons[id].n)
            for areaId, entry in pairs(Merge.dungeonEntries) do
                if want ~= "" and norm(entry[1]) == want then
                    Merge.areaDungeon[areaId] = id
                    for _, alt in ipairs(list(entry[2])) do Merge.areaDungeon[alt] = id end
                end
            end
        end
    end
    -- The dungeon quests filed under one of those areas.
    local inArea = {} -- [areaId] = { questId, ... }
    for qid, area in pairs(stats.dungeonArea) do
        if anyArea[area] then
            local t = inArea[area]
            if not t then t = {}; inArea[area] = t end
            t[#t + 1] = qid
        end
    end
    local out = {}
    for id, d in pairs(F.dungeons) do
        local set, ids = {}, {}
        local confirmed = numbers(d.q)
        for _, qid in ipairs(confirmed) do
            if exists[qid] and not set[qid] then set[qid] = true; ids[#ids + 1] = qid end
        end
        for area in pairs(areasOf[id]) do
            for _, qid in ipairs(inArea[area] or {}) do
                if not set[qid] then set[qid] = true; ids[#ids + 1] = qid end
            end
        end
        sort(ids)
        if #ids > 0 then
            out[id] = { name = d.n, lo = d.lo, hi = d.hi, min = d.min, ent = d.ent, bosses = d.bosses,
                quests = joinIds(ids), confirmed = joinIds(confirmed) }
        end
    end
    return out
end

return Merge
