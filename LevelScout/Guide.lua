-- Guide.lua: one waypoint for the current step. TomTom's arrow when TomTom is there, else the
-- game's own map pin. Only waypoints created here are ever removed.
--
-- The way to the current step is worked out from where the player stands (ns.Travel:Route):
-- when it starts at a flight master or a harbour, the waypoint points there first, and at the
-- step itself as soon as the flight has begun (the flight master is behind us then), and the
-- way is worked out afresh on landing.
--   Guide.Follow(step, title, travel)  the Engine: this is the current step (nil: none)
--   Guide.Tick()                       about once a second: the player has moved
--   Guide.Trip()                       the way as it stands, for the window (see `evaluate`)
--   Guide.Pointed()                    the step pointed at by hand, for the window to highlight
--   Guide.Show(step, title)            point at this step and stay there (a click in the window);
--                                      the way to it is worked out the same way, so the waypoint
--                                      goes to the flight master or harbour first when it starts there

local _, ns = ...
local Game, TomTom, Geo = ns.Game, ns.TomTom, ns.Geo

local Guide = {}
ns.Guide = Guide

Guide.mode = "none" -- "tomtom" | "map" | "none"
Guide.SETTLE = 2    -- a different way must come out this many times in a row before the waypoint moves
local shownKey
local followed      -- { step, title, travel }: the plan's current step, as the Engine gave it
local trip          -- the way to it as last worked out (see `evaluate`)
local manual        -- { step, title, trip, pending }: the player pointed the arrow somewhere by hand; it
                    -- stays there until the next plan (trip and pending as for the followed step)
local lastTravel    -- the ns.Travel object of the last plan (the way to a step pointed at by hand)
local pending       -- { key, count, trip }: a different way that has not settled yet
local riding        -- on a flight path right now
local lastSeen      -- { loc, t }: where the player was at the last look (to notice a flight)
Guide.FLIGHT_SPEED = 20 -- yards per second no mount reaches: moving faster than this is a flight

local function clear()
    TomTom.Clear()
    Game.ClearMapWaypoint()
    Guide.mode, shownKey = "none", nil
end

-- Point at a step (nil clears). Does nothing when that step is already shown.
local function show(step, title)
    local loc = step and step.loc
    if not loc or not loc.map or not loc.mx then
        if shownKey then clear() end
        return Guide.mode
    end
    local key = string.format("%d:%.1f:%.1f:%s", loc.map, loc.mx, loc.my, tostring(title))
    if key == shownKey then return Guide.mode end
    clear()
    if TomTom.Set(loc.map, loc.mx / 100, loc.my / 100, title) then
        Guide.mode = "tomtom"
    elseif Game.SetMapWaypoint(loc.map, loc.mx / 100, loc.my / 100) then
        Guide.mode = "map"
    end
    shownKey = key
    return Guide.mode
end

local function mapName(map)
    return map and ((ns.Zones and ns.Zones.Name(map)) or Game.MapName(map) or ("Map " .. tostring(map))) or nil
end

-- The way from where the player stands to a step:
--   { seconds, legs (from ns.Travel:Route, each end with its zone's name where known),
--     zone = the step's zone name when it is not the zone we are in (else nil),
--     rides = the fly and boat legs in order, first = rides[1],
--     target = { loc, name } where the waypoint goes instead of the step: the flight master or
--              harbour of the first ride (nil: the step itself),
--     key = what tells one way from another: the rides' ends and the zone }
-- nil when the position is unknown (inside an instance).
local function evaluate(step, travel)
    if not step or not step.loc or not step.loc.map then return nil end
    local map, x, y = Game.GetPosition(Geo.HasMap)
    if not map then return nil end
    local here = Geo.Loc(map, x * 100, y * 100)
    local route = travel and travel:Route(here, step.loc) or nil
    local out = { seconds = route and route.seconds, legs = route and route.legs or {}, rides = {},
        zone = nil }
    -- the step's zone when it is not the one we are in (zones, not the maps the points were
    -- recorded on: a camp's spots can be on the continent map)
    local zoneOf = ns.Zones and ns.Zones.ZoneAt
    local hereZone = zoneOf and zoneOf(here) or map
    local stepZone = zoneOf and zoneOf(step.loc, { hereZone }) or step.loc.map
    if stepZone ~= hereZone then out.zone = mapName(stepZone) end
    local parts = { out.zone or "" }
    for _, leg in ipairs(out.legs) do
        for _, point in ipairs({ leg.from, leg.to }) do
            if point.name and not point.loc.map then point.loc = Geo.OnMap(point.loc) or point.loc end
            if point.name and point.loc.map and not point.zone then point.zone = mapName(point.loc.map) end
        end
        if leg.kind ~= "walk" then
            out.rides[#out.rides + 1] = leg
            parts[#parts + 1] = leg.kind .. ":" .. tostring(leg.from.name) .. ">" .. tostring(leg.to.name)
        end
    end
    out.first = out.rides[1]
    if out.first and out.first.from.loc.map and out.first.from.loc.mx then out.target = out.first.from end
    out.key = table.concat(parts, "|")
    return out
end

-- Is the player on a flight path? The game says so where it can; where it cannot, moving
-- faster than any mount between two looks is taken for one.
local function inFlight()
    local map, x, y = Game.GetPosition(Geo.HasMap)
    local now, fast = Game.Now(), false
    local here = map and Geo.Loc(map, x * 100, y * 100) or nil
    if here and lastSeen then
        local d, dt = Geo.Dist(lastSeen.loc, here), now - lastSeen.t
        fast = d ~= nil and dt > 0 and dt < 5 and d / dt > Guide.FLIGHT_SPEED
    end
    if here then lastSeen = { loc = here, t = now } end
    return Game.OnTaxi() or fast
end

-- The waypoint for a step and the way to it: where the way starts (a flight master, a
-- harbour) until the ride has begun, else the step itself.
local function pointAt(step, title, way)
    if way and way.target and not riding then
        return show({ loc = way.target.loc }, ns.Format and ns.Format.TripTitle(way) or title)
    end
    return show(step, title)
end

-- The way as it stands after another look (`now`), and what is still settling: the same way
-- is refreshed at once, a different one must come out Guide.SETTLE times in a row.
local function settle(way, waiting, now)
    if not now or not way or now.key == way.key then
        return now or way, nil -- (no position: the last way stays)
    elseif waiting and waiting.key == now.key and waiting.count + 1 >= Guide.SETTLE then
        return now, nil
    end
    return way, { key = now.key, count = (waiting and waiting.key == now.key) and waiting.count + 1 or 1 }
end

local function point()
    if manual then return pointAt(manual.step, manual.title, manual.trip) end
    if not followed then return show(nil) end
    return pointAt(followed.step, followed.title, trip)
end

--- Point at a step and keep the waypoint there until the Engine publishes its next plan
--- (nil clears). The way to it is worked out like the way to the current step (with the last
--- plan's travel object): when it starts with a flight or a boat, the waypoint goes to the
--- flight master or harbour first. Does nothing when that is already shown.
function Guide.Show(step, title)
    if not step then
        manual = nil
        return show(nil)
    end
    manual = { step = step, title = title, trip = evaluate(step, lastTravel) }
    return point()
end

--- The Engine's current step (nil: none), its waypoint title, and the ns.Travel object of the
--- plan (nil: the way is not worked out; the waypoint is the step). Points the waypoint.
function Guide.Follow(step, title, travel, keepPointed)
    if not step then
        followed, trip, pending, manual = nil, nil, nil, nil
        return show(nil)
    end
    local was, loc = followed and followed.step.loc, step.loc
    local same = was and loc and was.map == loc.map and was.mx == loc.mx and was.my == loc.my and followed.title == title
    followed = { step = step, title = title, travel = travel }
    lastTravel = travel or lastTravel
    -- A step pointed at by hand stays pointed at through a new plan as long as the Engine says
    -- it is still there (a flight, a zone change and quest events all plan again; the player is
    -- still on the way to it). Otherwise the arrow goes back to the route.
    if not keepPointed then manual = nil end
    if same and trip then
        Guide.Tick() -- the same step as before: a different way has to settle first
    else
        trip, pending = evaluate(step, travel), nil
    end
    return point()
end

--- The player has moved: work out the way again (to the current step, and to a step pointed
--- at by hand, which is where the waypoint then is). The waypoint and Guide.Trip() change only
--- when a different way (other flight points, another harbour, no flight any more) has come
--- out Guide.SETTLE times in a row; the times of the same way are refreshed at once.
--- Once a flight has begun the waypoint goes to the step itself: the flight master is behind
--- us. Nothing is worked out in the air; on landing the way from there is taken at once.
function Guide.Tick()
    if not followed then return Guide.mode end
    if inFlight() then
        riding, pending = true, nil
        if manual then manual.pending = nil end
        return point()
    end
    if riding then
        riding, pending = false, nil
        trip = evaluate(followed.step, followed.travel) or trip
        if manual then manual.trip, manual.pending = evaluate(manual.step, lastTravel) or manual.trip, nil end
        return point()
    end
    trip, pending = settle(trip, pending, evaluate(followed.step, followed.travel))
    if manual then manual.trip, manual.pending = settle(manual.trip, manual.pending, evaluate(manual.step, lastTravel)) end
    return point()
end

--- The way to the Engine's current step as it stands (see `evaluate`), or nil.
function Guide.Trip() return trip end

--- The step the player pointed the arrow at by hand (Guide.Show), while it lasts:
--- { step, title, trip (the way to it, as Guide.Trip) }, or nil.
function Guide.Pointed() return manual end

function Guide.Clear()
    followed, trip, pending, manual, riding = nil, nil, nil, nil, nil
    clear()
end

--- Straight-line yards from the player to a step, or nil (instance, other continent).
function Guide.Distance(step)
    if not step or not step.loc then return nil end
    local map, x, y = Game.GetPosition(Geo.HasMap)
    if not map then return nil end
    return Geo.Dist(Geo.Loc(map, x * 100, y * 100), step.loc)
end
