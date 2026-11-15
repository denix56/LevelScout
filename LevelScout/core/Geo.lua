-- core/Geo.lua: map coordinates to world yards, distances, and spawn clustering.
-- Pure Lua: no game API. Geometry comes from ns.data.world.maps (the client's map table).

local _, ns = ...

local Geo = {}
ns.Geo = Geo

local sqrt, floor = math.sqrt, math.floor

local maps = {}

-- A map without geometry is treated as its own small continent, so points on it are still
-- comparable with each other but never with points elsewhere.
local UNKNOWN_W, UNKNOWN_H = 4000, 2667

function Geo.Init(world)
    maps = (world and world.maps) or {}
end

function Geo.HasMap(map) return maps[map] ~= nil end

--- A location: { c = continent, x, y = world yards, map = uiMapID, mx, my = 0-100 on that map }.
function Geo.Loc(map, mx, my)
    local m = maps[map]
    if m then
        return { c = m.c, x = m.t - my / 100 * m.h, y = m.l - mx / 100 * m.w, map = map, mx = mx, my = my }
    end
    return { c = -map, x = -my / 100 * UNKNOWN_H, y = -mx / 100 * UNKNOWN_W, map = map, mx = mx, my = my }
end

--- A location from world coordinates only (no map point; used for flight nodes and transports).
function Geo.WorldLoc(c, x, y) return { c = c, x = x, y = y } end

--- The same location with a map point, for one that has only world coordinates (a harbour):
--- on the smallest map of its continent that contains it. Returns nil when no map does.
function Geo.OnMap(loc)
    if loc.map and loc.mx then return loc end
    local best, bestArea
    for id, m in pairs(maps) do
        if m.c == loc.c and m.w and m.h and m.w > 0 and m.h > 0 then
            local mx, my = (m.l - loc.y) / m.w * 100, (m.t - loc.x) / m.h * 100
            local area = m.w * m.h
            if mx >= 0 and mx <= 100 and my >= 0 and my <= 100
                and (not best or area < bestArea or (area == bestArea and id < best.map)) then
                best, bestArea = { c = loc.c, x = loc.x, y = loc.y, map = id, mx = mx, my = my }, area
            end
        end
    end
    return best
end

--- Straight-line yards, or nil when the two points are on different continents.
function Geo.Dist(a, b)
    if a.c ~= b.c then return nil end
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

Geo.CELL = 150 -- yards; a camp is a cell plus its eight neighbours

local scratchCells, scratchOrder = {}, {} -- Geo.Cluster's working tables, empty between calls

--- The best place to work on a set of spawn points: dense, and close to `near` when given.
--- spots = { {map, x, y}, ... } (0-100). Returns loc, pointsInCamp, pointsInTotal; nil if empty.
function Geo.Cluster(spots, near)
    local n = #spots
    if n == 0 then return nil end
    if n == 1 then
        local s = spots[1]
        return Geo.Loc(s.map, s.x, s.y), 1, 1
    end
    local CELL = Geo.CELL
    -- The cells are scratch tables kept between calls (a planning run clusters hundreds of
    -- spawn lists; a fresh table per cell was megabytes of garbage each time).
    local cells, order, used = scratchCells, scratchOrder, 0
    for i = 1, n do
        local s = spots[i]
        local m = maps[s.map]
        local c, x, y
        if m then c, x, y = m.c, m.t - s.y / 100 * m.h, m.l - s.x / 100 * m.w
        else c, x, y = -s.map, -s.y / 100 * UNKNOWN_H, -s.x / 100 * UNKNOWN_W end
        local key = c * 1e8 + (floor(x / CELL) + 5000) * 1e4 + (floor(y / CELL) + 5000)
        local cell = cells[key]
        if not cell then
            used = used + 1
            cell = order[used]
            if not cell then cell = {}; order[used] = cell end
            cell.key, cell.n, cell.sx, cell.sy, cell.c, cell.map, cell.smx, cell.smy, cell.nm = key, 0, 0, 0, c, s.map, 0, 0, 0
            cells[key] = cell
        end
        cell.n, cell.sx, cell.sy = cell.n + 1, cell.sx + x, cell.sy + y
        if s.map == cell.map then cell.smx, cell.smy, cell.nm = cell.smx + s.x, cell.smy + s.y, cell.nm + 1 end
    end
    local best, bestScore, bestCount
    for i = 1, used do
        local cell = order[i]
        local count = 0
        for dx = -1, 1 do
            for dy = -1, 1 do
                local nb = cells[cell.key + dx * 1e4 + dy]
                if nb then count = count + nb.n end
            end
        end
        local score = count
        if near then
            if near.c ~= cell.c then
                score = score * 0.02
            else
                local dx, dy = cell.sx / cell.n - near.x, cell.sy / cell.n - near.y
                score = score / (1 + sqrt(dx * dx + dy * dy) / 1000)
            end
        end
        if not best or score > bestScore then best, bestScore, bestCount = cell, score, count end
    end
    local loc = { c = best.c, x = best.sx / best.n, y = best.sy / best.n, map = best.map,
        mx = best.smx / best.nm, my = best.smy / best.nm }
    for i = 1, used do cells[order[i].key] = nil end
    return loc, bestCount, n
end
