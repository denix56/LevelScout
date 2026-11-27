-- core/Travel.lua: seconds to get from one location to another. Pure Lua: no game API.
-- Walking is straight-line distance times a detour factor; a long walk is also checked against
-- the walk table between hubs (the real way round mountains and water), and takes the longer
-- of the two. Known flight paths and boats/zeppelins are used when they are faster; a flight
-- can also start at a flight master not known yet (Travel.UNLOCK), never end at one.
--   travel:Seconds(a, b)  the time and the mode; called very often by the planner.
--   travel:Route(a, b)    the same choice with its legs (walk, fly, boat; boats and other links
--                         can follow one another, see `chain`), for telling the
--                         player where to go; called for the current step only.
--   travel:Route(a, b, stone)  with the hearthstone as one more way (see T:Route).

local _, ns = ...

local Travel = {}
ns.Travel = Travel

local Geo = ns.Geo
local huge = math.huge
local floor = math.floor

Travel.DETOUR = 1.25          -- real paths are longer than straight lines
Travel.FLIGHT_OVERHEAD = 20   -- talking to the flight master, take-off and landing
Travel.MIN_WALK_FOR_FLIGHT = 240
Travel.UNLOCK = true          -- a flight can start at a flight master of our side that is not known yet:
                              -- walk there, talk (that unlocks the point), fly on to a known point
Travel.CHAIN = true            -- boats, ferries and lifts can follow one another, and are used inside a
                              -- continent too (off: one crossing between continents, none inside one)
Travel.MIN_FOR_LINK = 240     -- seconds: a shorter trip inside a continent never takes a boat or a lift
Travel.LAND_MASSES = true     -- no walking between two land masses that a boat, a ferry or a portal joins
                              -- (off: every walk on a continent is possible, over water too)
Travel.LAND_PATH = true       -- a walk that would cross water goes round it on the land-mass grid, or swims
Travel.SWIM = 1.5             -- a yard swum counts as this many walked (swimming is two thirds as fast)
Travel.LAND_PATH_MAX = 4000   -- yards in a straight line: longer walks are left to the walk table
Travel.LAND_PATH_MARGIN = 6   -- cells beyond the two ends that the way round may use
Travel.LAND_PATH_CACHE = 20000 -- ways remembered per continent (pairs of cells); then it starts afresh
Travel.MOUNT_UP = 3           -- seconds to get on a mount: a walk is ridden when that still makes it shorter
Travel.TRAM_NAME = "Deeprun Tram"              -- the link's name starts with this
Travel.TRAM_CITIES = { "Stormwind", "Ironforge" } -- its ends, by the names of their flight points
Travel.NO_ROUTE = 1800        -- no known way between the points: a long, fixed cost
Travel.HUB_WALK_MIN = 1000    -- yards in a straight line: shorter walks are not checked against the walk table
                              -- (walks to a flight master always are: see NearestNodes)
Travel.HUB_SECOND_MAX = 1000  -- yards: a point's second-nearest hub counts only when it is this close
Travel.HUB_WALK = true        -- use the walk table at all (off: every walk is the straight line times DETOUR)

---------------------------------------------------------------------------------------------
-- The walk table: world.travel.hubs (flight masters, quest hubs, transport ends) and
-- world.travel.walk (yards on foot between pairs of nearby hubs, along the terrain).
-- Read once per data table; walks between far hubs are the shortest chain of pairs.
---------------------------------------------------------------------------------------------

local A64 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
local D64 = {}
for i = 1, 64 do D64[A64:byte(i)] = i - 1 end

local terrainCache = setmetatable({}, { __mode = "k" }) -- travel data table -> terrain, or false

-- { hubs = { { c, x, y }, ... }, edges = { [hub] = { [hub] = yards } }, from = { [hub] = { [hub] = yards } } }
-- or nil when the data has no walk table.
local function terrain(travel)
    if type(travel) ~= "table" then return nil end
    local hit = terrainCache[travel]
    if hit ~= nil then return hit or nil end
    local t = { hubs = {}, edges = {}, from = {} }
    for part in (type(travel.hubs) == "string" and travel.hubs or ""):gmatch("[^;]+") do
        local c, x, y = part:match("^.-~(%-?%d+)~(%-?%d+)~(%-?%d+)~%a$")
        -- (a part that does not parse still takes its number: the walk table counts every part)
        t.hubs[#t.hubs + 1] = c and { c = tonumber(c), x = tonumber(x), y = tonumber(y) } or false
    end
    local s, pairsRead = type(travel.walk) == "string" and travel.walk or "", 0
    for p = 1, #s - 7, 8 do
        local a1, a2, b1, b2 = D64[s:byte(p)], D64[s:byte(p + 1)], D64[s:byte(p + 2)], D64[s:byte(p + 3)]
        local y1, y2 = D64[s:byte(p + 4)], D64[s:byte(p + 5)]
        if a1 and a2 and b1 and b2 and y1 and y2 then
            local a, b, yards = a1 * 64 + a2 + 1, b1 * 64 + b2 + 1, (y1 * 64 + y2) * 2
            if t.hubs[a] and t.hubs[b] and a ~= b then
                t.edges[a] = t.edges[a] or {}
                t.edges[b] = t.edges[b] or {}
                t.edges[a][b], t.edges[b][a] = yards, yards
                pairsRead = pairsRead + 1
            end
        end
    end
    if pairsRead == 0 then t = false end
    terrainCache[travel] = t
    return t or nil
end

-- Yards on foot between two hubs along the walk table, or nil when no chain of pairs joins them.
local function hubWalk(t, i, j)
    if i == j then return 0 end
    local dist = t.from[i]
    if not dist then
        dist = { [i] = 0 }
        local done = {}
        while true do
            local cur, best = nil, huge
            for id, d in pairs(dist) do
                if not done[id] and d < best then cur, best = id, d end
            end
            if not cur then break end
            done[cur] = true
            for to, yards in pairs(t.edges[cur] or {}) do
                local nd = best + yards
                if not dist[to] or nd < dist[to] then dist[to] = nd end
            end
        end
        t.from[i] = dist
    end
    return dist[j]
end

---------------------------------------------------------------------------------------------
-- Land masses: world.travel.comps, per continent a grid of cells (x0, y0: its corner in world
-- yards; `cell` yards; cols over x, rows over y; s: a character per cell, column by column, the
-- id of the land mass there, 0 where none is known). An island and the mainland have different
-- ids. A spot on a cell without one (a dock over the water) takes the mass of the cell next to it.
---------------------------------------------------------------------------------------------

local function cellMass(g, col, row)
    if col < 0 or row < 0 or col >= g.cols or row >= g.rows then return 0 end
    local b = g.s:byte(col * g.rows + row + 1)
    return b and D64[b] or 0
end

-- The land mass at a location as one number over all continents (0: none known).
local function massAt(comps, loc)
    local g = comps and loc.c and comps[loc.c]
    if not (g and loc.x and loc.y) then return 0 end
    local fx, fy = (loc.x - g.x0) / g.cell, (loc.y - g.y0) / g.cell
    local col, row = floor(fx), floor(fy)
    local m = cellMass(g, col, row)
    if m == 0 then
        local best
        for dc = -1, 1 do
            for dr = -1, 1 do
                local near = cellMass(g, col + dc, row + dr)
                if near ~= 0 then
                    local dx, dy = col + dc + 0.5 - fx, row + dr + 0.5 - fy
                    local d = dx * dx + dy * dy
                    if not best or d < best then best, m = d, near end
                end
            end
        end
    end
    return m ~= 0 and (loc.c * 64 + m) or 0
end

---------------------------------------------------------------------------------------------
-- The way round water. The grid's cells are 400 yards: a step between two cells of the same
-- land mass costs its length, a step through a cell without one (water) or between two masses
-- SWIM times that. The cheapest way from a's cell to b's (A*, inside the box around the two
-- ends plus LAND_PATH_MARGIN cells) is how far the walk is at least, less one cell for where
-- in their cells the ends are. Only looked for when the straight line crosses water; remembered
-- per pair of cells (the grid never changes).
---------------------------------------------------------------------------------------------

local pathCache = setmetatable({}, { __mode = "k" }) -- grid -> { n, swim, [cell * 2048 + cell] = yards | false }
local heapK, heapV, cost, seenAt, searches = {}, {}, {}, {}, 0
local SQRT2 = math.sqrt(2)

local function landPath(g, ac, ar, bc, br)
    local rows, cols, cell, swim = g.rows, g.cols, g.cell, Travel.SWIM
    local dc, dr = bc - ac, br - ar
    -- does the straight line leave the land (or change land mass) at all?
    local steps = 2 * math.max(math.abs(dc), math.abs(dr))
    local wet, mass = false, nil
    for s = 1, steps - 1 do
        local c, r = floor(ac + 0.5 + dc * s / steps), floor(ar + 0.5 + dr * s / steps)
        if not ((c == ac and r == ar) or (c == bc and r == br)) then
            local m = cellMass(g, c, r)
            if m == 0 or (mass and m ~= mass) then wet = true break end
            mass = m
        end
    end
    if not wet then return false end
    local margin = Travel.LAND_PATH_MARGIN
    local c0, c1 = math.max(0, math.min(ac, bc) - margin), math.min(cols - 1, math.max(ac, bc) + margin)
    local r0, r1 = math.max(0, math.min(ar, br) - margin), math.min(rows - 1, math.max(ar, br) + margin)
    local from, goal = ac * rows + ar, bc * rows + br
    searches = searches + 1
    local run, n = searches, 1
    cost[from], seenAt[from] = 0, run
    heapK[1], heapV[1] = 0, from
    while n > 0 do
        -- take the cheapest (a binary heap of estimate, cell)
        local k, u = heapK[1], heapV[1]
        local lastK, lastV = heapK[n], heapV[n]
        n = n - 1
        local i = 1
        while true do
            local child = 2 * i
            if child > n then break end
            if child < n and heapK[child + 1] < heapK[child] then child = child + 1 end
            if heapK[child] >= lastK then break end
            heapK[i], heapV[i] = heapK[child], heapV[child]
            i = child
        end
        if n > 0 then heapK[i], heapV[i] = lastK, lastV end
        if u == goal then return cost[u] end
        local uc = floor(u / rows)
        local ur = u - uc * rows
        local base = cost[u]
        -- (an entry put in before a cheaper way to this cell was found is skipped)
        local hc, hr = math.abs(bc - uc), math.abs(br - ur)
        if k <= base + (math.max(hc, hr) + (SQRT2 - 1) * math.min(hc, hr)) * cell + 0.001 then
            local mu = (u == from or u == goal) and -1 or cellMass(g, uc, ur) -- (-1: an end's own cell is land)
            for oc = -1, 1 do
                for orow = -1, 1 do
                    local vc, vr = uc + oc, ur + orow
                    if (oc ~= 0 or orow ~= 0) and vc >= c0 and vc <= c1 and vr >= r0 and vr <= r1 then
                        local v = vc * rows + vr
                        local mv = (v == from or v == goal) and -1 or cellMass(g, vc, vr)
                        local f = ((mu == 0 and swim or 1) + (mv == 0 and swim or 1)) / 2
                        if mu > 0 and mv > 0 and mu ~= mv then f = swim end
                        local t = base + ((oc ~= 0 and orow ~= 0) and SQRT2 or 1) * cell * f
                        if seenAt[v] ~= run or t < cost[v] then
                            cost[v], seenAt[v] = t, run
                            -- estimate: what is left at the least, a straight diagonal-and-straight way over land
                            local ec, er = math.abs(bc - vc), math.abs(br - vr)
                            local est = t + (math.max(ec, er) + (SQRT2 - 1) * math.min(ec, er)) * cell
                            n = n + 1
                            local j = n
                            while j > 1 do
                                local parent = floor(j / 2)
                                if heapK[parent] <= est then break end
                                heapK[j], heapV[j] = heapK[parent], heapV[parent]
                                j = parent
                            end
                            heapK[j], heapV[j] = est, v
                        end
                    end
                end
            end
        end
    end
    return false
end

-- Yards the walk from a to b is at least, going round water or swimming it; nil when the
-- straight line stays on land (or the ends are in neighbouring cells, or off the grid).
local function landYards(comps, a, b)
    local g = comps[a.c]
    if not g or not (a.x and a.y and b.x and b.y) then return nil end
    local rows, cell = g.rows, g.cell
    local ac, ar = floor((a.x - g.x0) / cell), floor((a.y - g.y0) / cell)
    local bc, br = floor((b.x - g.x0) / cell), floor((b.y - g.y0) / cell)
    local dc, dr = bc - ac, br - ar
    if dc >= -1 and dc <= 1 and dr >= -1 and dr <= 1 then return nil end
    if ac < 0 or ar < 0 or bc < 0 or br < 0 or ac >= g.cols or bc >= g.cols or ar >= rows or br >= rows then return nil end
    local ia, ib = ac * rows + ar, bc * rows + br
    local key = ia < ib and ia * 2048 + ib or ib * 2048 + ia
    local cache = pathCache[g]
    if not cache or cache.swim ~= Travel.SWIM or cache.margin ~= Travel.LAND_PATH_MARGIN or cache.n >= Travel.LAND_PATH_CACHE then
        cache = { n = 0, swim = Travel.SWIM, margin = Travel.LAND_PATH_MARGIN }
        pathCache[g] = cache
    end
    local hit = cache[key]
    if hit == nil then
        -- (always from the lower cell to the higher, so both directions get the same answer)
        if ia < ib then hit = landPath(g, ac, ar, bc, br) else hit = landPath(g, bc, br, ac, ar) end
        hit = hit and (hit - cell) or false
        cache[key], cache.n = hit, cache.n + 1
    end
    return hit or nil
end

local T = {}
T.__index = T

--- The land mass a location is on (0: none known). Remembered per location table.
function T:Mass(loc)
    local m = self.massCache[loc]
    if m == nil then
        m = massAt(self.comps, loc)
        self.massCache[loc] = m
    end
    return m
end

--- Is there no way on foot between a and b? True when they are on two land masses that links
--- join (the mainland and an island with a boat to it, an island and the city its portal goes
--- to): the link is there because the walk is not. An island nothing goes to can be swum to.
function T:Apart(a, b)
    local groups = self.massGroup
    if not groups then return false end
    local ma = self:Mass(a)
    if ma == 0 then return false end
    local mb = self:Mass(b)
    if mb == 0 or ma == mb then return false end
    local ga = groups[ma]
    return ga ~= nil and ga == groups[mb]
end

--- world = ns.data.world; opts = { speed = yards per second on foot, side = "a"|"h",
--- ride = yards per second mounted (nil: the character does not ride),
--- knownNodes = { [flightNodeId] = true } or nil (nil: no flight paths known),
--- tram = "on" | "off" | "auto" (nil: auto): the Deeprun Tram; auto takes it only while the
---        flight between Stormwind and Ironforge is not known }.
--- travel.tramUsed says what came of it (nil: this side has no tram).
function Travel.New(world, opts)
    opts = opts or {}
    local self = setmetatable({}, T)
    self.speed = opts.speed or 7
    self.ride = opts.ride and opts.ride > self.speed and opts.ride or nil
    self.side = opts.side
    self.world = world
    self.links = {}
    for _, l in ipairs((world and world.links) or {}) do
        local s = (l.side or ""):lower()
        if s == "" or not self.side or s == self.side then
            -- "Boat between Menethil Harbor and Theramore Isle": the kind and the two ends, a first
            local kind, aName, bName = (l.name or ""):match("^(%S+) between (.+) and (.+)$")
            self.links[#self.links + 1] = { a = Geo.WorldLoc(l.a[1], l.a[2], l.a[3]),
                b = Geo.WorldLoc(l.b[1], l.b[2], l.b[3]), secs = (l.wait or 120) + (l.ride or 90), name = l.name,
                kind = kind, aName = aName, bName = bName }
        end
    end
    -- nodes: the flight points a flight can start at (known, or of our side and to be unlocked
    -- on the way); known: those it can pass and end at
    self.nodes, self.known, self.edges, self.fromCache = {}, {}, {}, {}
    self.nearCache = setmetatable({}, { __mode = "k" }) -- location -> its nearest flight nodes
    self.nodeNames, self.nodePoints = {}, {} -- for Route: the flight master's name and map point
    local travel = world and world.travel
    if travel and opts.knownNodes and next(opts.knownNodes) then
        local flySpeed = (travel.speeds and travel.speeds.fly) or 32
        for id, n in pairs(travel.nodes or {}) do
            local known = opts.knownNodes[id] and true or false
            -- (opts.noUnlock: points not to be unlocked, those in zones above the level)
            if known or (Travel.UNLOCK and self.side and (n[7] == "n" or n[7] == self.side)
                and not (opts.noUnlock and opts.noUnlock[id])) then
                self.known[id] = known or nil
                if not known then self.hasUnknown = true end
                self.nodes[id] = Geo.WorldLoc(n[1], n[2], n[3])
                self.nodeNames[id] = n[9]
                if n[4] and n[5] and n[6] then self.nodePoints[id] = { map = n[4], mx = n[5], my = n[6] } end
            end
        end
        for from, to, yards in (travel.flights or ""):gmatch("(%d+)>(%d+)>(%d+)>%d+") do
            from, to = tonumber(from), tonumber(to)
            -- (no flight to a point that is not known, nor through one)
            if self.nodes[from] and self.known[to] then
                self.edges[from] = self.edges[from] or {}
                self.edges[from][to] = tonumber(yards) / flySpeed
            end
        end
        for from, to, secs in (travel.measured or ""):gmatch("(%d+)>(%d+)>(%d+)>%d+") do
            from, to = tonumber(from), tonumber(to)
            if self.edges[from] and self.edges[from][to] then self.edges[from][to] = tonumber(secs) end
        end
    end
    self.hasFlights = next(self.edges) ~= nil
    -- land masses joined by links of this side: no walking between them (see T:Apart)
    self.comps = Travel.LAND_MASSES and travel and type(travel.comps) == "table" and travel.comps or nil
    self.massCache = setmetatable({}, { __mode = "k" }) -- location -> its land mass
    if self.comps then
        local group = {}
        local function root(m)
            while group[m] and group[m] ~= m do m = group[m] end
            return m
        end
        for _, l in ipairs(self.links) do
            local ma, mb = massAt(self.comps, l.a), massAt(self.comps, l.b)
            if l.a.c == l.b.c and ma ~= 0 and mb ~= 0 and ma ~= mb then
                local ra, rb = root(ma), root(mb)
                group[ra], group[rb] = ra, ra
                group[ma], group[mb] = group[ma] or ra, group[mb] or ra
            end
        end
        for m in pairs(group) do group[m] = root(m) end
        self.massGroup = next(group) and group or nil
    end
    -- the Deeprun Tram: on, off, or (auto) only while its two cities are not joined by a known flight
    for i, l in ipairs(self.links) do
        if (l.name or ""):find(Travel.TRAM_NAME, 1, true) == 1 then
            local use = opts.tram == "on"
            if opts.tram ~= "on" and opts.tram ~= "off" then
                local a, b
                for id, name in pairs(self.nodeNames) do
                    if name == Travel.TRAM_CITIES[1] then a = id elseif name == Travel.TRAM_CITIES[2] then b = id end
                end
                use = not (a and b and self:FlightsFrom(a)[b] and self:FlightsFrom(b)[a])
            end
            self.tramUsed = use
            if not use then table.remove(self.links, i) end
            break
        end
    end
    -- the fastest we ever get over the ground in a straight line (yards per second): on foot,
    -- or the fastest flight between two flight points. For ruling links out early (see `chain`).
    self.vmax = self.ride or self.speed
    local known = {}
    for id in pairs(self.known) do known[#known + 1] = id end
    table.sort(known)
    for from, tos in pairs(self.edges) do
        for to, secs in pairs(tos) do
            local d = Geo.Dist(self.nodes[from], self.nodes[to])
            if d and secs > 0 and d / secs > self.vmax then self.vmax = d / secs end
        end
    end
    -- what the times between the links depend on (see `hops`)
    self.chainKey = table.concat({ tostring(self.speed), tostring(self.ride), tostring(Travel.MOUNT_UP),
        tostring(Travel.LAND_PATH), tostring(Travel.SWIM), tostring(Travel.LAND_PATH_MAX), tostring(Travel.LAND_PATH_MARGIN), tostring(self.side), table.concat(known, ","), tostring(self.tramUsed),
        tostring(Travel.DETOUR), tostring(Travel.HUB_WALK), tostring(Travel.LAND_MASSES), tostring(Travel.FLIGHT_OVERHEAD),
        tostring(Travel.MIN_WALK_FOR_FLIGHT), tostring(Travel.HUB_WALK_MIN), tostring(Travel.HUB_SECOND_MAX),
        tostring(self.hasUnknown) }, "|")
    self.terrain = Travel.HUB_WALK and terrain(travel) or nil
    self.hubCache = setmetatable({}, { __mode = "k" }) -- location -> its two nearest hubs
    return self
end

-- The two hubs of the walk table closest to a location, as { hub, yards, hub, yards } (straight
-- lines). The second only when it is close too (HUB_SECOND_MAX): a far one says nothing about
-- this place. None when the continent has no hubs.
function T:NearHubs(loc)
    local hit = self.hubCache[loc]
    if hit then return hit end
    local t = self.terrain
    local a, da, b, db
    for i, hub in ipairs(t.hubs) do
        if hub and hub.c == loc.c and t.edges[i] then
            local dx, dy = hub.x - loc.x, hub.y - loc.y
            local d = dx * dx + dy * dy
            if not da or d < da then a, da, b, db = i, d, a, da
            elseif not db or d < db then b, db = i, d end
        end
    end
    local out = {}
    if a then out[1], out[2] = a, math.sqrt(da) end
    if b and math.sqrt(db) <= Travel.HUB_SECOND_MAX then out[3], out[4] = b, math.sqrt(db) end
    self.hubCache[loc] = out
    return out
end

--- Yards on foot from a to b, nil (another continent) or math.huge (no way on foot: two land
--- masses that a link joins, see T:Apart). The straight line times DETOUR; for
--- a long walk (or with `always`, any walk) also what the walk table says, when that is more. The table gives the walk
--- between the hubs near both ends; our ends are at most their distance to those hubs closer
--- to each other than that. Where an end has two hubs close by, the pair that says least is
--- believed, so a hub behind a ridge does not make a walk look long.
function T:WalkYards(a, b, always)
    local d = Geo.Dist(a, b)
    if not d then return nil end
    if self.massGroup and self:Apart(a, b) then return huge end -- no way on foot
    local yards = d * Travel.DETOUR
    -- round the water, or through it at swimming speed, when that is more
    if self.comps and Travel.LAND_PATH and d <= Travel.LAND_PATH_MAX then
        -- (the way round is as crooked as any other: it takes the detour factor too)
        local round = landYards(self.comps, a, b)
        if round and round * Travel.DETOUR > yards then yards = round * Travel.DETOUR end
    end
    local t = self.terrain
    if t and (always or d >= Travel.HUB_WALK_MIN) then
        local ha, hb = self:NearHubs(a), self:NearHubs(b)
        local low
        for i = 1, #ha, 2 do
            for j = 1, #hb, 2 do
                local between = hubWalk(t, ha[i], hb[j])
                if between then
                    local bound = between - (ha[i + 1] + hb[j + 1]) * Travel.DETOUR
                    if not low or bound < low then low = bound end
                end
            end
        end
        if low and low > yards then yards = low end
    end
    return yards
end

--- Seconds on the ground from a to b (nil, math.huge: as WalkYards). On foot, or mounted when
--- the character rides (self.ride) and the walk is long enough to be worth getting on the
--- mount (MOUNT_UP). (Where mounts cannot be used, in caves and buildings, is not known.)
function T:Walk(a, b, always)
    local yards = self:WalkYards(a, b, always)
    if not yards then return nil end
    local t = yards / self.speed
    local ride = self.ride
    if ride and t > Travel.MOUNT_UP then
        local mounted = Travel.MOUNT_UP + yards / ride
        if mounted < t then t = mounted end
    end
    return t
end

-- Shortest flight times from one node (known or not) to every known node (few dozen nodes: plain Dijkstra).
function T:FlightsFrom(from)
    local hit = self.fromCache[from]
    if hit then return hit end
    local dist, done = { [from] = 0 }, {}
    while true do
        local cur, best = nil, huge
        for id, d in pairs(dist) do
            if not done[id] and d < best then cur, best = id, d end
        end
        if not cur then break end
        done[cur] = true
        for to, secs in pairs(self.edges[cur] or {}) do
            local nd = best + secs
            if not dist[to] or nd < dist[to] then dist[to] = nd end
        end
    end
    self.fromCache[from] = dist
    return dist
end

-- The two known flight nodes closest to a location, and the two closest that are still to be
-- unlocked (a flight can start there): { id, walkSeconds } each, nil where there is none.
function T:NearestNodes(loc)
    -- (remembered per location table; the planner's VALUE_CACHE switch covers it, for the bench)
    local cache = self.nearCache
    if ns.Planner and ns.Planner.VALUE_CACHE == false then cache = nil end
    local hit = cache and cache[loc]
    if hit then return hit[1], hit[2], hit[3], hit[4] end
    local a, b, u1, u2
    local known = self.known
    for id, nloc in pairs(self.nodes) do
        -- (always against the walk table: a flight master close by in a straight line can be
        -- a long way on foot, as Menethil Harbor is from the north of Ironforge)
        local w = self:Walk(loc, nloc, true)
        if w and w < huge then
            if known[id] then
                if not a or w < a[2] then a, b = { id, w }, a
                elseif not b or w < b[2] then b = { id, w } end
            elseif not u1 or w < u1[2] then u1, u2 = { id, w }, u1
            elseif not u2 or w < u2[2] then u2 = { id, w } end
        end
    end
    if cache then cache[loc] = { a, b, u1, u2 } end
    return a, b, u1, u2
end

-- Same continent: walk, or walk-fly-walk when flight paths make it faster. The flight starts
-- at a known flight point or at one still to be unlocked, and ends at a known one.
-- Returns the seconds and the mode; for a flight also the two nodes as { id, walkSeconds }
-- (where to take off, where to land) and the seconds in the air.
function T:Land(a, b)
    local walk = self:Walk(a, b)
    if not walk then return nil end
    if not self.hasFlights or walk < Travel.MIN_WALK_FOR_FLIGHT then return walk, "walk" end
    local best, mode, from, to, air = walk, "walk", nil, nil, nil
    local a1, a2, a3, a4 = self:NearestNodes(a)
    local b1, b2 = self:NearestNodes(b)
    local overhead = Travel.FLIGHT_OVERHEAD
    -- (as `for na in {a1, a2, a3, a4}`, `for nb in {b1, b2}`, without the tables: this runs for every pair of stops)
    for i = 1, 4 do
        local na = (i == 1 and a1) or (i == 2 and a2) or (i == 3 and a3) or (i == 4 and a4) or nil
        if na and na[2] + overhead < best then
            local flights = self:FlightsFrom(na[1])
            local nb = b1
            while nb do
                local fly = flights[nb[1]]
                if fly and nb[1] ~= na[1] then
                    local t = na[2] + overhead + fly + nb[2]
                    if t < best then best, mode, from, to, air = t, "fly", na, nb, fly end
                end
                nb = nb == b1 and b2 or nil
            end
        end
    end
    return best, mode, from, to, air
end

---------------------------------------------------------------------------------------------
-- Links (boats, zeppelins, ferries, lifts, the tram) and chains of them.
-- A "hop" is a link taken one way: board at p, arrive at r, `secs` for the wait and the ride.
-- between[i][j] is the time from the arrival of hop i to the arrival of hop j (walking or
-- flying to the links in between and taking them; 0 for i == j), via[i][j] the next hop on
-- that way. Worked out once per world and set of flight points, speed and side.
---------------------------------------------------------------------------------------------

local chainCache = setmetatable({}, { __mode = "k" }) -- world -> { key, between, via }

local function hops(self)
    local h = self.hops
    if h then return h end
    local list = {}
    for _, l in ipairs(self.links) do
        local n = #list
        list[n + 1] = { p = l.a, r = l.b, secs = l.secs, link = l, back = false, rev = n + 2 }
        list[n + 2] = { p = l.b, r = l.a, secs = l.secs, link = l, back = true, rev = n + 1 }
    end
    h = { list = list, ins = {}, outs = {}, inLow = {}, outLow = {}, tin = {}, tout = {} }
    local cached = self.world and chainCache[self.world]
    if cached and cached.key == self.chainKey and #cached.between == #list then
        h.between, h.via = cached.between, cached.via
    else
        local n, between, via = #list, {}, {}
        for i = 1, n do
            local row, next_ = {}, {}
            for k = 1, n do
                row[k] = i == k and 0 or huge
                -- (never straight back on the link we came with)
                if k ~= i and k ~= list[i].rev and list[i].r.c == list[k].p.c then
                    local t = self:Land(list[i].r, list[k].p)
                    if t and t < huge then row[k], next_[k] = t + list[k].secs, k end
                end
            end
            between[i], via[i] = row, next_
        end
        for m = 1, n do
            local viaM = between[m]
            for i = 1, n do
                local row, im = between[i], between[i][m]
                if im < huge then
                    for j = 1, n do
                        local t = im + viaM[j]
                        if t < row[j] then row[j], via[i][j] = t, via[i][m] end
                    end
                end
            end
        end
        h.between, h.via = between, via
        if self.world then chainCache[self.world] = { key = self.chainKey, between = between, via = via } end
    end
    self.hops = h
    return h
end

-- The fastest way from a to b that takes at least one link and beats `best` seconds.
-- Returns the seconds and the first and the last hop (indexes into hops(self).list), or `best`
-- alone when no such way is faster. With `single`, only ways of one link.
-- A link is looked at closely only when it could win at all: the straight lines to it and
-- from it at the fastest speed there is (self.vmax) are a lower bound on those two ends.
local function chain(self, a, b, best, single)
    local h = hops(self)
    local list, between = h.list, h.between
    local ins, outs, inLow, outLow, tin, tout = h.ins, h.outs, h.inLow, h.outLow, h.tin, h.tout
    local nIn, nOut, vmax = 0, 0, self.vmax
    for i = 1, #list do
        local hop = list[i]
        tin[i], tout[i] = false, false
        if hop.p.c == a.c then
            local d = Geo.Dist(a, hop.p)
            local low = d and d / vmax + hop.secs
            if low and low < best then nIn = nIn + 1; ins[nIn], inLow[i] = i, low end
        end
        if hop.r.c == b.c then
            local d = Geo.Dist(hop.r, b)
            local low = d and d / vmax
            if low and low < best then nOut = nOut + 1; outs[nOut], outLow[i] = i, low end
        end
    end
    local first, last
    for x = 1, nIn do
        local i = ins[x]
        local row = between[i]
        for y = 1, nOut do
            local j = outs[y]
            local mid = row[j]
            if (not single or i == j) and inLow[i] + mid + outLow[j] < best then
                local ti = tin[i]
                if not ti then
                    ti = (self:Land(a, list[i].p) or huge) + list[i].secs
                    tin[i] = ti
                end
                if ti + mid + outLow[j] < best then
                    local tj = tout[j]
                    if not tj then
                        tj = self:Land(list[j].r, b) or huge
                        tout[j] = tj
                    end
                    if ti + mid + tj < best then best, first, last = ti + mid + tj, i, j end
                end
            end
        end
    end
    return best, first, last
end

-- The time and the mode of the way from a to b, and for a way over links its first and last hop.
local function way(self, a, b)
    local direct, mode
    if a.c == b.c then
        direct, mode = self:Land(a, b)
        if not direct then return nil end
        -- (math.huge: no way on foot and no flight; only links can do it)
        if direct < huge and (not Travel.CHAIN or direct < Travel.MIN_FOR_LINK) then return direct, mode end
    end
    local best, first, last = chain(self, a, b, direct or huge, not Travel.CHAIN)
    if first then return best, "boat", first, last end
    if direct and direct < huge then return direct, mode end
    return Travel.NO_ROUTE, "unknown" -- (another continent or land mass, and no link to it)
end

--- Seconds from a to b and how: "walk", "fly", "boat" (any link or chain of links) or "unknown".
function T:Seconds(a, b)
    local seconds, mode = way(self, a, b)
    return seconds, mode
end

-- A point of a route: { name (flight point, harbour; nil for where we are and where we are going), loc }.
local function nodePoint(self, id)
    local loc, p = self.nodes[id], self.nodePoints[id]
    -- (unlock: the flight master is not known yet; talking to them there unlocks the point)
    return { name = self.nodeNames[id], node = id, unlock = not self.known[id] or nil,
        loc = { c = loc.c, x = loc.x, y = loc.y, map = p and p.map, mx = p and p.mx, my = p and p.my } }
end

-- The legs of Land(a, b), added to `legs`. `from` and `to` are the points for a and b.
local function landLegs(self, legs, a, b, from, to)
    local seconds, mode, na, nb, air = self:Land(a, b)
    if not seconds then return nil end
    if mode == "walk" then
        legs[#legs + 1] = { kind = "walk", from = from, to = to, seconds = seconds }
        return seconds
    end
    local off, on = nodePoint(self, na[1]), nodePoint(self, nb[1])
    legs[#legs + 1] = { kind = "walk", from = from, to = off, seconds = na[2] }
    -- One leg however many flight points the path passes: the game's flight map takes a
    -- click on the far end and flies through the points in between.
    legs[#legs + 1] = { kind = "fly", from = off, to = on, seconds = Travel.FLIGHT_OVERHEAD + air }
    legs[#legs + 1] = { kind = "walk", from = on, to = to, seconds = nb[2] }
    return seconds
end

--- The way from a to b behind Seconds(a, b): the same choice and the same total.
--- Returns { seconds, mode, legs = { { kind = "walk"|"fly"|"boat", from, to, seconds,
---           name, transport (boat legs: the link's name and its kind, "Boat", "Zeppelin", ...) }, ... } }
--- where from and to are { name, loc, node (flight node id), unlock (true: a flight point still
--- to be unlocked; only where a flight starts) }: a flight point or a harbour, or
--- only { loc } for a and b themselves. A walk leg can be zero seconds long (standing at the
--- flight master). No known way (mode "unknown"): no legs, and Travel.NO_ROUTE seconds.
local function routeOf(self, a, b)
    local legs = {}
    local from, to = { loc = a }, { loc = b }
    local seconds, mode, first, last = way(self, a, b)
    if not first then
        if mode ~= "unknown" then landLegs(self, legs, a, b, from, to) end
        return { seconds = seconds, mode = mode, legs = legs }
    end
    local h = hops(self)
    local at, atPoint, k = a, from, first
    while k do
        local hop = h.list[k]
        local link = hop.link
        local on = { name = hop.back and link.bName or link.aName, loc = hop.p }
        local off = { name = hop.back and link.aName or link.bName, loc = hop.r }
        landLegs(self, legs, at, hop.p, atPoint, on)
        legs[#legs + 1] = { kind = "boat", from = on, to = off, seconds = link.secs, name = link.name, transport = link.kind }
        at, atPoint = hop.r, off
        k = k ~= last and h.via[k][last] or nil
    end
    landLegs(self, legs, at, b, atPoint, to)
    return { seconds = seconds, mode = "boat", legs = legs }
end

--- The same with the hearthstone as one more way: stone = { loc (where it is bound), name, cast (seconds: the cast
--- and the loading screen), min (seconds it must save; default 0) }, ready to be used now. When the way from the
--- bind point, with the cast, is quicker than the plain way by `min` seconds, the way is a "hearth" leg
--- ({ kind = "hearth", from = { loc = a }, to = { name, loc }, seconds = cast }) and the legs of the way on from there,
--- with mode "hearth". Without a stone, or when it does not pay, the plain way as before.
function T:Route(a, b, stone)
    local plain = routeOf(self, a, b)
    if type(stone) ~= "table" or not stone.loc then return plain end
    local on = routeOf(self, stone.loc, b)
    if on.mode == "unknown" or not on.seconds then return plain end
    local secs = (stone.cast or 0) + on.seconds
    if secs + (stone.min or 0) >= (plain.seconds or math.huge) then return plain end
    local inn = { name = stone.name, loc = stone.loc }
    local legs = { { kind = "hearth", from = { loc = a }, to = inn, seconds = stone.cast or 0 } }
    for i, leg in ipairs(on.legs) do
        if i == 1 then leg.from = inn end
        legs[#legs + 1] = leg
    end
    return { seconds = secs, mode = "hearth", legs = legs }
end
