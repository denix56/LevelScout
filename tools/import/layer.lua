-- tools/import/layer.lua
--
-- Builds LevelScout's baked ForeverDB layer from ForeverDB's data tables alone. QuestieDB is
-- not read here: the addon reads it at runtime (LevelScout/adapters/Merge.lua) and merges the
-- two per record. The tables keep ForeverDB's own names and record layouts (the legend at the
-- top of each ForeverDB data file), so the runtime merge reads them exactly as ForeverDB
-- wrote them. Only what the merge reads is kept. Layout: docs/data-format.md.

local here = ...
local Merge = assert(loadfile(here .. "/../../LevelScout/adapters/Merge.lua"))("LevelScout", {})

local M = {}

local function split(s, sep)
    local out, start = {}, 1
    while true do
        local a = s:find(sep, start, true)
        if not a then out[#out + 1] = s:sub(start); return out end
        out[#out + 1] = s:sub(start, a - 1)
        start = a + #sep
    end
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--- F = ForeverDB's addon table (its Data/*.lua files run). Returns the model the writer
--- writes ({ fdb, world }) and a report { counts }.
function M.Build(F)
    local report = { counts = {} }
    local counts = report.counts

    -- Required ForeverDB tables: fail loudly if the format changed.
    for _, name in ipairs({ "qcQuests", "qfQuests", "qcNpc", "qcObj", "qcItem", "qcGone", "qcExcl", "qfPoi",
        "qfSeen", "qfNpcSpots", "qfNpcNames", "qfItems", "qfArea", "qobj", "qxp", "qdrop", "pace", "npcLv",
        "travelData", "zoneData", "qgQuests", "qcByMap", "qfByMap", "dungeons" }) do
        if type(F[name]) ~= "table" then error("ForeverDB: table ns." .. name .. " is missing (format changed?)", 0) end
    end
    if type(F.qxp.q) ~= "table" or type(F.qxp.curve) ~= "table" then error("ForeverDB: ns.qxp.q/curve missing", 0) end
    if type(F.routeMaps) ~= "table" or not next(F.routeMaps) then error("ForeverDB: ns.routeMaps is missing (format changed?)", 0) end

    -- Classic quests players were never offered are left out by the merge before their
    -- record is read: only the id list is needed for them.
    local qcQuests = {}
    for id, rec in pairs(F.qcQuests) do
        if not F.qcGone[id] then qcQuests[id] = rec end
    end

    -- Group size: field 16 of ForeverDB's quest guide records (nothing else of the guide is used).
    local groupSize = {}
    for id, rec in pairs(F.qgQuests) do
        local n = tonumber(split(rec, "|")[16])
        if n then groupSize[id] = n end
    end

    -- Where ForeverDB saw a quest start: the merge's fallback zone for quests QuestieDB files
    -- under no zone. A quest seen on several maps keeps the first map read (as before the
    -- merge moved into the addon).
    local startMap = {}
    for _, byMap in ipairs({ F.qcByMap, F.qfByMap }) do
        for map, ids in pairs(byMap) do
            for qid in tostring(ids):gmatch("%d+") do
                qid = tonumber(qid)
                startMap[qid] = startMap[qid] or map
            end
        end
    end

    -- An NPC's own spot in ForeverDB's NPC table ({ name, title, uiMap, x, y, ... }): the last
    -- fallback for NPCs no other source places.
    local npcSpot = {}
    for id, v in pairs(type(F.npcs) == "table" and F.npcs or {}) do
        if type(v) == "table" and type(v[3]) == "number" and v[3] > 0 then
            npcSpot[id] = Merge.Spot(v[3], v[4], v[5])
        end
    end

    -- Dungeons: 5-player, with a known entrance and levels. The runtime merge adds the quests
    -- QuestieDB files under each dungeon's area.
    local dungeons = {}
    for id, d in pairs(F.dungeons) do
        if d.kind == "dungeon" and d.size == 5 and type(d.ent) == "string" and d.ent ~= "" then
            local lo, hi, min = tostring(d.lv or ""):match("^(%d+):(%d+):(%d+)$")
            local bosses = 0
            for _ in tostring(d.boss or ""):gmatch("[^|]+") do bosses = bosses + 1 end
            if tonumber(lo) and tonumber(lo) > 0 then
                dungeons[id] = { n = d.n, lo = tonumber(lo), hi = tonumber(hi), min = tonumber(min), ent = d.ent,
                    bosses = bosses, q = d.q or "" }
            end
        end
    end

    local links = {}
    for _, l in ipairs(type(F.routeLinks) == "table" and F.routeLinks or {}) do
        if type(l.a) == "table" and type(l.b) == "table" and l.a.c and l.b.c then
            links[#links + 1] = { name = l.name, side = l.side or "", both = l.both and true or false,
                a = { l.a.c, l.a.x, l.a.y }, b = { l.b.c, l.b.x, l.b.y }, wait = l.wait or 120, ride = l.ride or 90 }
        end
    end

    local fdb = {
        -- quests
        qcQuests = qcQuests, qfQuests = F.qfQuests, qcGone = F.qcGone, qcExcl = F.qcExcl,
        questXP = F.qxp.q, qobj = F.qobj, groupSize = groupSize, startMap = startMap,
        -- Forever-observed quest locations
        qfPoi = F.qfPoi, qfSeen = F.qfSeen, qfArea = F.qfArea,
        -- NPCs, objects, items
        qcNpc = F.qcNpc, qfNpcNames = F.qfNpcNames, qfNpcSpots = F.qfNpcSpots, npcLv = F.npcLv, npcSpot = npcSpot,
        qcObj = F.qcObj,
        qfItems = F.qfItems, qdrop = F.qdrop, qcItem = F.qcItem,
        dungeons = dungeons,
    }
    -- Flight masters: the client's TaxiNodes lists a few no flight path goes to or from (Powderfuse
    -- Port, Tidegear Coast: no flight master stands there in the game). Those are left out, so they
    -- are never suggested to unlock nor taken for the point just learned. The rest is ForeverDB's.
    local travel, flown, dropped = {}, {}, 0
    for k, v in pairs(F.travelData) do travel[k] = v end
    for a, b in (F.travelData.flights or ""):gmatch("(%d+)>(%d+)>") do
        flown[tonumber(a)], flown[tonumber(b)] = true, true
    end
    travel.nodes = {}
    for id, n in pairs(F.travelData.nodes or {}) do
        if flown[id] then travel.nodes[id] = n else dropped = dropped + 1 end
    end
    counts["flight masters"] = count(travel.nodes)
    counts["flight masters with no flight path (left out)"] = dropped

    local world = {
        pace = F.pace,
        xpCurve = F.qxp.curve,
        xpDungeonMultiplier = F.qxp.dmul,
        zones = F.zoneData,
        travel = travel,
        -- Map geometry ([uiMap] = { c = continent, t, l = world X/Y of the top-left corner, h, w = yards })
        -- and boats/zeppelins/trams between distant points, for distances and travel times.
        maps = F.routeMaps,
        links = links,
    }

    counts["classic quests (CMaNGOS, client-filtered)"] = count(qcQuests)
    counts["classic quests never offered in Forever"] = count(F.qcGone)
    counts["Forever quests"] = count(F.qfQuests)
    counts["quests with captured XP"] = count(F.qxp.q)
    counts["quests with captured objective counts"] = count(F.qobj)
    counts["quests with observed spots"] = count(F.qfSeen)
    counts["quests with a group size"] = count(groupSize)
    counts["NPCs (classic)"] = count(F.qcNpc)
    counts["NPCs (Forever names)"] = count(F.qfNpcNames)
    counts["NPCs with observed levels"] = count(F.npcLv)
    counts["objects (classic)"] = count(F.qcObj)
    counts["items (Forever names)"] = count(F.qfItems)
    counts["items with measured drop rates"] = count(F.qdrop)
    counts["items with classic drop rates"] = count(F.qcItem)
    counts["dungeons"] = count(dungeons)
    counts["zones"] = count(F.zoneData)
    return { fdb = fdb, world = world }, report
end

function M.FormatReport(report, meta)
    local lines = { "LevelScout data import report (the baked ForeverDB layer)", "",
        string.format("client build %s, generated %s", meta.build, meta.generated),
        string.format("source: ForeverDB %s (data %s)", tostring(meta.sources.ForeverDB),
            tostring(meta.sources.ForeverDBData)),
        "QuestieDB is read by the addon at runtime and is not part of this report.", "", "counts:" }
    local keys = {}
    for k in pairs(report.counts) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do lines[#lines + 1] = string.format("  %-45s %d", k, report.counts[k]) end
    return table.concat(lines, "\n") .. "\n"
end

return M
