-- Engine.lua: keeps the plan current. Reads the character's state through ns.Game, runs the
-- planner as a background job, and publishes one `view` table that the UI and the waypoint
-- follow. Nothing here blocks a frame: planning yields every few milliseconds.

local _, ns = ...
local Data, Game, Async, Zones, Geo, Guide, Tracker = ns.Data, ns.Game, ns.Async, ns.Zones, ns.Geo, ns.Guide, ns.Tracker

local Engine = {}
ns.Engine = Engine

Engine.DEBOUNCE = 0.5        -- seconds: events arrive in bursts
Engine.MIN_GAP = 2           -- seconds between plans: a kill quest updates the log on every kill
Engine.RERANK_EVERY = 45     -- seconds between background re-rankings of the other zones
Engine.PROGRESS = true       -- say what the planner is doing while it runs (view.progress)
Engine.PROGRESS_EVERY = 0.15 -- seconds between two progress notices to the window, at least
-- A full re-plan's bar: ranking the zones up to SHARE_RANK, checking the shown route up to
-- SHARE_CHECK, then the next two hours (its own job) to the end. Shares of measured time.
Engine.SHARE_RANK, Engine.SHARE_CHECK = 0.75, 0.8
Engine.MOVE_EVERY = 1        -- seconds between two looks at where the player is (travel speed, see ns.Tracker.OnMove)
Engine.NEAR_YARDS = 40       -- an accept or turn-in further down the route this close comes to its front

local memory = ns.Memory.New()   -- plans kept between rankings (reused) and as warm starts (ns.Memory); never saved

--- Forget the kept plans: the next plans start from scratch and nothing is reused.
function Engine.ResetMemory() ns.Memory.Reset(memory) end

--- What the UI shows. status: "starting" | "planning" | "ready" | "paused" | "error".
Engine.view = { status = "starting", message = "Loading", ranked = {}, moveOn = { suggest = false } }

local listeners = {}
local db, chardb
local completed            -- { [questId] = true }, kept between plans
local pending, pendingFull -- a replan is scheduled; it must re-rank all zones
local leveledTo -- the level PLAYER_LEVEL_UP announced, until the game reports it itself
local lastRank, lastRun = -1e9, -1e9
local lastAltRate -- surplus goal: the last ranking's best score (XP per second), the next plans' R
local lastSignature
local bagSignature, bagNoticed = nil, {} -- quests the bags can start, as last seen; items already pointed out
local started = false
local publish                    -- defined below; used by the buff reminders
local xpBonus, xpBuffs = 0, {}   -- last XP buffs read out of combat
local plannedRested = 0          -- rested pool the shown plan was made with
local travel                     -- the ns.Travel object of the shown plan: the way to the current step (ns.Guide)
local front                      -- keys of stops the player stands at, for the next plan to bring forward
local frontAsked = {}            -- [key] = the quest log and level it was last asked for with (asked once each)

Engine.REMIND_SLEEPING_BAG = 600 -- seconds before the sleeping-bag buff ends
Engine.REMIND_OTHER = 180        -- seconds before any other XP buff (food) ends
local reminded = {}              -- [spellId] = the expiry time we already reminded for

--- Remind before an XP buff runs out: once per buff, in chat, on screen and in the window.
--- Works from the last buffs read, so it also fires in combat. Returns the reminders shown.
function Engine.CheckBuffs()
    local now, shown, note = Game.Now(), {}, nil
    for _, b in ipairs(xpBuffs) do
        if b.expires and not (chardb and chardb.mutedBuffs[b.spellId]) then
            local left = b.expires - now
            local lead = b.spellId == Game.SLEEPING_BAG_BUFF and Engine.REMIND_SLEEPING_BAG or Engine.REMIND_OTHER
            if left > 0 and left <= lead then
                local text = string.format("%s (+%d%% XP) ends in %s. Renew it to keep the bonus.", b.name,
                    b.bonus * 100 + 0.5, ns.Format.Duration(left))
                note = note or text
                if reminded[b.spellId] ~= b.expires then
                    reminded[b.spellId] = b.expires
                    ns.Print(text)
                    Game.Notice(text)
                    shown[#shown + 1] = text
                end
            end
        end
    end
    if note ~= Engine.view.buffNote then
        Engine.view.buffNote = note
        if #shown == 0 then publish() end
    end
    if #shown > 0 then publish() end
    return shown
end

--- The XP bonus from buffs, refreshed when the client lets us read buffs (not in combat).
function Engine.XPBonus()
    local total, list = Game.GetXPBuffs()
    if not total then return xpBonus end
    local had = {}
    for _, b in ipairs(xpBuffs) do had[b.spellId] = b end
    xpBonus, xpBuffs = total, list
    if chardb then
        -- Remember every XP buff this character has had, so its absence can be pointed out.
        local now = {}
        for _, b in ipairs(list) do
            now[b.spellId] = true
            chardb.seenBuffs[b.spellId] = { name = b.name, bonus = b.bonus }
        end
        local missing = {}
        for id, b in pairs(chardb.seenBuffs) do
            if not now[id] and not chardb.mutedBuffs[id] then
                missing[#missing + 1] = { spellId = id, name = b.name, bonus = b.bonus }
                if had[id] then -- it was on a moment ago: say so once
                    local text = string.format("%s has ended (+%d%% XP lost).", b.name, b.bonus * 100 + 0.5)
                    ns.Print(text)
                    Game.Notice(text)
                end
            end
        end
        table.sort(missing, function(a, b) return a.bonus > b.bonus end)
        Engine.view.missingBuffs = missing
    end
    return xpBonus
end

--- The XP buffs this character has had, for the options menu:
--- { {spellId, name, bonus, remind = bool}, ... } sorted by name.
function Engine.BuffReminders()
    local out = {}
    for id, b in pairs(chardb and chardb.seenBuffs or {}) do
        out[#out + 1] = { spellId = id, name = b.name, bonus = b.bonus, remind = not chardb.mutedBuffs[id] }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- Turn the reminders for one XP buff on or off: before it ends, when it ends, while it is missing.
--- The buff still counts in the plan either way.
function Engine.SetBuffReminder(spellId, on)
    if not chardb then return end
    chardb.mutedBuffs[spellId] = (not on) and true or nil
    Engine.XPBonus()      -- rebuild the missing list
    Engine.CheckBuffs()   -- and the expiry note
    publish()
end

function Engine.OnChange(fn) listeners[#listeners + 1] = fn end

---------------------------------------------------------------------------------------------
-- Progress while planning: view.progress = { fraction = 0..1, text }
---------------------------------------------------------------------------------------------
-- The planner tells us what it is doing through an optional callback (ctx.progress). That
-- is stored at once, but the window hears of it only every PROGRESS_EVERY seconds, through
-- its own listeners: a progress notice moves the bar and nothing else (no redraw, no waypoint).

local progressListeners = {}
local scope, zoneSpan           -- the phase's share of the bar, and the current zone's share of that
local itineraryOwed             -- the plan shown has no itinerary worked out for it yet (see startItinerary)
local startItinerary
local lastNotice = -1e9

--- fn(view) is called while a plan is being made, a few times per second at most.
function Engine.OnProgress(fn) progressListeners[#progressListeners + 1] = fn end

local function advance(fraction, text)
    local p = Engine.view.progress
    if not p then return end
    if fraction and fraction > p.fraction then p.fraction = math.min(1, fraction) end -- never backwards
    if text then p.text = text end
    local now = Game.Now()
    if now - lastNotice < Engine.PROGRESS_EVERY then return end
    lastNotice = now
    for _, fn in ipairs(progressListeners) do pcall(fn, Engine.view) end
end

-- A phase of the job takes the bar from `lo` to `hi`. With `fixed`, the text stays as it is
-- whatever the planner reports inside the phase.
local function phase(lo, hi, text, fixed)
    scope = { lo = lo, hi = hi, fixed = fixed }
    zoneSpan = scope
    advance(lo, text)
end

-- What the planner reports (see Zones.Context: progress).
local function note(stage, done, total, what)
    if not scope then return end
    local span = scope.hi - scope.lo
    if stage == "zone" then
        zoneSpan = { lo = scope.lo + span * (done - 1) / total, hi = scope.lo + span * done / total }
        local name = Zones.Name(what) or Game.MapName(what) or ("Map " .. tostring(what))
        advance(zoneSpan.lo, not scope.fixed and string.format("Ranking zones: %s (%d of %d)", name, done, total) or nil)
    elseif stage == "itinerary" then
        zoneSpan = { lo = scope.lo + span * done / total, hi = scope.lo + span * (done + 1) / total }
        advance(zoneSpan.lo)
    elseif stage == "search" then
        -- a zone's plan: a tenth to build the route, most of it searching, the rest tidying up
        advance(zoneSpan.lo + (zoneSpan.hi - zoneSpan.lo) * (0.1 + 0.7 * done / total),
            not scope.fixed and string.format("Searching for a better route: round %d of %d", done, total) or nil)
    elseif stage == "order" then
        advance(zoneSpan.lo + (zoneSpan.hi - zoneSpan.lo) * 0.85, not scope.fixed and "Putting stops in their best order" or nil)
    end
end

-- Is what the arrow was pointed at by hand (a click in the window, Guide.Pointed) still in the
-- new plan: the same step, the same flight point, the same quest's giver? Matched by
-- its title and its map (a giver's spot can move a little from one plan to the next).
local function pointedStillThere(view)
    local p = Guide.Pointed and Guide.Pointed() or nil
    local at = p and p.step and p.step.loc
    if not (p and at and view.plan) then return false end
    local function same(title, loc) return title == p.title and loc ~= nil and loc.map == at.map end
    for _, stop in ipairs(view.flightStops or {}) do
        if same("New flight point: " .. tostring(stop.name), stop.loc) then return true end
    end
    for _, s in ipairs(view.plan.steps or {}) do
        local loc = s.loc
        if loc and loc.map == at.map then
            if ns.StepTitle and same(ns.StepTitle(s), loc) then return true end
            -- (several steps at one spot are one row in the window, under a joint title)
            if loc.mx and at.mx and math.abs(loc.mx - at.mx) < 0.6 and math.abs(loc.my - at.my) < 0.6 then return true end
        end
    end
    return false
end

publish = function()
    local view = Engine.view
    local step = view.plan and view.plan.steps[1] or nil
    if step and step.fromBag then
        for _, s in ipairs(view.plan.steps) do
            if not s.fromBag then step = s; break end
        end
        if step.fromBag then step = nil end
    end
    -- a flight point to unlock before the first step: the waypoint goes there first
    local stop = view.plan and view.flightStops and view.flightStops[1]
    if stop and stop.at ~= 1 then stop = nil end
    local keep = pointedStillThere(view)
    if (view.status == "ready" or view.status == "planning") and stop then
        Guide.Follow({ loc = stop.loc }, "New flight point: " .. stop.name, travel, keep)
    elseif view.status == "ready" or view.status == "planning" then
        -- the waypoint: the step, or the flight master or harbour the way to it starts at
        Guide.Follow(step, step and ns.StepTitle and ns.StepTitle(step) or nil, travel, keep)
    else
        Guide.Follow(nil)
    end
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, view)
        if not ok then ns.Print("|cffff5555UI error: %s|r", tostring(err)) end
    end
end

local function setStatus(status, message)
    Engine.view.status, Engine.view.message = status, message
end

-- The quest log reduced to what changes a plan: ids, progress, completion.
local function signature(log)
    local parts = {}
    for _, q in ipairs(log) do
        local o = {}
        for _, ob in ipairs(q.objectives) do o[#o + 1] = tostring(ob.have) .. "/" .. tostring(ob.need) .. (ob.finished and "!" or "") end
        parts[#parts + 1] = q.id .. (q.isComplete and "C" or "") .. ":" .. table.concat(o, ",")
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

-- What was learned, as it is now: a plan takes several frames, and the tracker goes on
-- learning in between. Every part of one plan (each zone, the itinerary) uses the same figures.
local function frozen(t)
    local out = {}
    for k, v in pairs(t or {}) do
        if type(v) == "table" then
            local inner = {}
            for k2, v2 in pairs(v) do inner[k2] = v2 end
            out[k] = inner
        else
            out[k] = v
        end
    end
    return out
end

-- Quests an item in the bags would start, not yet in the log or done: { [questId] = itemId }.
-- The game names the quest where it can; otherwise the data does (an item may start several).
local function bagQuests(inLog)
    local out = {}
    for _, item in ipairs(Game.GetBagItems()) do
        local ids = item[2] and { item[2] } or Data.QuestsStartedByItem(item[1])
        for _, id in ipairs(ids) do
            if not inLog[id] and not (completed and completed[id]) and not out[id] then out[id] = item[1] end
        end
    end
    return out
end

local function bagKey(quests)
    local ids = {}
    for id, item in pairs(quests) do ids[#ids + 1] = id .. ":" .. item end
    table.sort(ids)
    return table.concat(ids, ",")
end

local function gather()
    local player = Game.GetPlayer()
    local pctx = Game.GetPlayerContext()
    if not player.level then return nil, "Waiting for character data" end
    -- Right after a level-up the game can still report the old level: the event's own figure wins.
    if leveledTo and leveledTo > player.level then player.level = leveledTo else leveledTo = nil end
    local map, x, y = Game.GetPosition(Geo.HasMap)
    if not map then return nil, Game.InInstance() and "Paused inside an instance" or "Position unknown here" end
    local log = Game.GetQuestLog()
    local inLog = {}
    for _, q in ipairs(log) do inLog[q.id] = true end
    local bags = bagQuests(inLog)
    if bagSignature == nil then -- what the bags held when we started is not news
        bagSignature = bagKey(bags)
        for _, item in pairs(bags) do bagNoticed[item] = true end
    end
    return {
        level = player.level, restedPool = player.rested or 0, xpBonus = Engine.XPBonus(),
        xp = player.xp, xpMax = player.xpMax, maxLevel = player.maxLevel,
        faction = pctx.faction, class = pctx.class, raceId = pctx.raceId,
        map = map, x = x, y = y, log = log, completed = completed,
        capacity = Game.GetQuestLogCapacity(),
        groupSize = Game.GetGroupSize(),
        routeElite = chardb.routeElite ~= false,
        tram = chardb.tram, -- "on" | "off" | nil (auto): the Deeprun Tram (see Travel.New)
        partyOn = function(id) return Game.PartyOnQuest(id) end,
        knownNodes = chardb.knownNodes, ignored = chardb.ignored,
        memory = memory, now = Game.Now(),
        bagQuests = bags,
        -- learned from play (ns.Learn, ns.Tracker)
        pace = frozen(chardb.pace), drops = frozen(db.drops),
        stepModel = { v = chardb.stepModel.v, n = chardb.stepModel.n, w = frozen(chardb.stepModel.w) },
        -- The game's own tag, but only for quests in the log: their data is loaded already.
        tagOf = function(id)
            if inLog[id] then
                local tag, known = Game.GetQuestTag(id)
                if known then return tag end
            end
        end,
    }
end

local function moveOn(plan, ranked, itinerary)
    local view = Engine.view
    view.moveOn = Zones.MoveOn(plan, ranked, view.moveOn, itinerary)
    if view.moveOn.map then
        view.moveOn.name = Zones.Name(view.moveOn.map) or Game.MapName(view.moveOn.map) or ("Map " .. view.moveOn.map)
    end
end

-- The next hours across zones (and the search view's recording), after the zones and the
-- route are on screen. Worked out after each ranking and kept in between. A new plan job
-- stops it; it is then worked out again after that job, from its result.
startItinerary = function(result)
    local view = Engine.view
    itineraryOwed = true
    view.busy = true
    view.progress = Engine.PROGRESS and (view.progress or { fraction = Engine.SHARE_CHECK, text = "Planning the next two hours" }) or nil
    local state, zone, plan, ranked = result.state, result.zone, result.plan, view.ranked
    Async.Run("itinerary", function(checkpoint)
        state.checkpoint = checkpoint
        state.progress = view.progress and note or nil
        local ctx = Zones.Context(state)
        phase(Engine.SHARE_CHECK, 1, "Planning the next two hours", true)
        local itinerary = Zones.Itinerary(state, ctx, ranked, { shown = zone, plan = plan, was = view.itinerary })
        for _, seg in ipairs(itinerary and itinerary.segments or {}) do
            seg.name = seg.name or Game.MapName(seg.map) or ("Map " .. tostring(seg.map))
        end
        -- Debug view: plan the shown zone once more from scratch, recording the search. It
        -- starts from the same earlier plan the shown one did (so the same route comes out) and
        -- leaves the memory as it is.
        local trace
        phase(1, 1, nil, true)
        if Engine.trace then
            ctx.trace = zone
            local fresh = result.fresh
            local traced = Zones.PlanZone(zone, ctx, nil, nil, { readOnly = true,
                warm = fresh and fresh.warmSeed or false, weights = fresh and fresh.warmWeights or nil })
            ctx.trace = nil
            if traced.trace then trace = { zone = zone, frames = traced.trace } end
        end
        return { itinerary = itinerary, trace = trace }
    end, function(ok, out)
        itineraryOwed = false
        view.busy = Async.IsRunning("plan")
        if not view.busy then view.progress, scope, zoneSpan = nil, nil, nil end
        if ok then
            view.itinerary = out.itinerary
            view.trace = Engine.trace and out.trace or nil
            moveOn(view.plan, view.ranked, out.itinerary)
        else
            ns.Print("|cffff5555Planning the next two hours failed: %s|r", tostring(out))
        end
        publish()
    end)
end

-- Inside an instance nothing is planned (no position), but the route stays on screen: its
-- steps are brought up to date from the quest log, so the dungeon's quests show their progress.
local function applyLive(plan)
    if not plan then return end
    local byId = {}
    for _, q in ipairs(Game.GetQuestLog()) do byId[q.id] = q end
    for _, step in ipairs(plan.steps) do
        for _, p in ipairs(step.parts or {}) do
            local entry = byId[p.quest]
            local o = entry and entry.objectives[p.index]
            if o and type(o.need) == "number" and o.need > 0 then p.have, p.total = o.have or 0, o.need end
        end
        if step.action == "run" or step.kind == "turnin" then
            local live = {}
            for _, q in ipairs(step.quests or {}) do
                local entry = byId[q.id]
                local text
                if not entry then
                    text = "not in the log"
                elseif entry.isComplete then
                    text = "|cff59ff59done|r"
                else
                    local bits = {}
                    for _, o in ipairs(entry.objectives) do
                        if type(o.need) == "number" and o.need > 0 then bits[#bits + 1] = string.format("%d/%d", o.have or 0, o.need)
                        elseif o.finished then bits[#bits + 1] = "done" end
                    end
                    text = #bits > 0 and table.concat(bits, ", ") or "in progress"
                end
                live[#live + 1] = q.name .. ": " .. text
                if step.kind == "turnin" then step.ready = entry and entry.isComplete or nil end
            end
            if step.action == "run" then step.live = live end
        end
    end
end

local function run()
    pending = false
    local full = pendingFull
    pendingFull = false
    if not Data.usable then
        setStatus("error", Data.status.message or "LevelScout's data is not usable")
        return publish()
    end
    if not Data.IsIndexBuilt() then
        pendingFull = true
        return -- the index job replans when it finishes
    end
    local state, why = gather()
    if not state then
        Tracker.Interrupt() -- no plan is followed: the step that was being timed is not timed any more
        setStatus("paused", why)
        applyLive(Engine.view.plan)
        return publish()
    end
    local frontKeys = front -- (see nearbyLater)
    front = nil
    lastSignature = signature(state.log)
    lastRun = Game.Now()
    local view = Engine.view
    local now = Game.Now()
    if now - lastRank > Engine.RERANK_EVERY or #view.ranked == 0 then full = true end
    if view.status ~= "ready" then setStatus("planning", "Planning") end
    view.busy = true
    view.progress = Engine.PROGRESS and { fraction = 0, text = "Planning" } or nil
    scope, zoneSpan = nil, nil
    publish()

    Async.Stop("itinerary") -- worked out again after this job, from its result
    Async.Run("plan", function(checkpoint)
        state.checkpoint = checkpoint
        if view.progress then state.progress = note end
        if ns.Planner.GOAL == "surplus" then state.altRate = lastAltRate end
        local ctx = Zones.Context(state)
        local ranked = view.ranked
        -- The first plan of a session (login, /reload): the route saved with the character is
        -- shown at once, as it was, and the zones are ranked behind it. The ranking then keeps
        -- it unless a new route is clearly better, like any shown route (see `keep` below).
        local saved = chardb.route
        if not view.plan and saved and saved.zone == chardb.zone then
            local early = Zones.PlanZone(saved.zone, ctx, saved.order)
            if #early.steps > 0 then
                view.plan, view.zone = early, saved.zone
                view.zoneName = Zones.Name(saved.zone) or Game.MapName(saved.zone) or ("Map " .. tostring(saved.zone))
                view.level, view.here = state.level, state.map
                view.logCount, view.capacity, view.groupSize = #state.log, state.capacity, state.groupSize
                view.updated = Game.Now()
                travel = ctx.travel
                setStatus("ready", nil)
                publish()
            end
        end
        -- The bar: ranking the zones is most of a full re-plan, then the check of the shown
        -- route, then the itinerary. A quick re-plan is the shown zone's plan and that check.
        phase(0, full and Engine.SHARE_RANK or 0.7, full and "Ranking zones" or "Planning the route")
        local function rank()
            ranked = Zones.Rank(ctx, chardb.zone)
            state.altRate = ctx.altRate -- (worked out by the ranking when there was none) for the itinerary
        end
        if full then rank() end
        local function planOf(map)
            for _, z in ipairs(ranked) do if z.map == map then return z.plan end end
        end
        local function open(map) -- a ranked zone with something to do
            local p = map and planOf(map)
            return p ~= nil and #p.steps > 0
        end
        local shown = view.plan
        local zone, fresh, finished = chardb.zone, nil, nil
        -- A quick re-plan that finds the shown zone's route used up: the zones are ranked at
        -- once, so the next zone follows without waiting for the next ranking.
        if zone and not full then
            fresh = Zones.PlanZone(zone, ctx, nil, nil, { warm = Zones.WARM_SHOWN and nil or false })
            if #fresh.steps == 0 and shown and shown.zone == zone and #shown.steps > 0 then
                full, fresh = true, nil
                phase(0.1, Engine.SHARE_RANK, "Ranking zones")
                rank()
            end
        end
        -- Which zone is shown: the chosen one while it has steps. When it has none left, the
        -- zone its itinerary goes to next; else where we stand, else the best.
        if zone and full and not open(zone) then zone, finished = nil, zone end
        if not zone then
            local onward = Zones.NextZone(view.itinerary, finished)
            if open(onward) then
                zone = onward
            else
                zone = open(state.map) and state.map or (ranked[1] and ranked[1].map) or state.map
            end
            fresh = nil
        end
        if not fresh then
            -- (a zone taken over from the finished zone we stand in was ranked as if left from
            -- that zone's main town, see Zones.Rank: its route is made from where we stand)
            local handed = full and finished ~= nil and finished == state.map
            fresh = (full and not handed and planOf(zone))
                or Zones.PlanZone(zone, ctx, nil, nil, { warm = (handed or Zones.WARM_SHOWN) and nil or false })
        end
        local plan = fresh
        phase(full and Engine.SHARE_RANK or 0.7, full and Engine.SHARE_CHECK or 1, "Checking the shown route", true)
        -- The order to keep: the shown route's; before the first plan of a session (login,
        -- /reload) the one saved with the character, so the route does not reshuffle over a relog.
        local keep = shown and shown.zone == zone and #shown.steps > 0 and shown.order or nil
        local saved = chardb.route
        if not shown and saved and saved.zone == zone then keep = saved.order end
        if keep then
            -- stops we stand at, further down: the shown route with them brought forward wins
            local kept = Zones.PlanZone(zone, ctx, keep, nil, frontKeys and { front = frontKeys } or nil)
            if kept.fronted or not Zones.PreferFresh(kept, fresh) then plan = kept end
        end
        return { ranked = ranked, plan = plan, fresh = fresh, zone = zone, state = state, full = full, travel = ctx.travel,
            flightStops = Zones.FlightStops(plan, ctx, chardb.skippedNodes) }
    end, function(ok, result)
        -- The zones and the route are shown now; the itinerary follows in a job of its own.
        local more = ok and (result.full or itineraryOwed)
        view.busy = more and true or false
        if not more then view.progress, scope, zoneSpan = nil, nil, nil end
        if not ok then
            setStatus("error", "Planning failed: " .. tostring(result))
            return publish()
        end
        if result.full then
            lastRank = Game.Now()
            if ns.Planner.GOAL == "surplus" then -- the next plans' alternative: the best score of this ranking
                local best
                for _, z in ipairs(result.ranked) do
                    local s = Zones.AltScore(z.plan)
                    if not best or s > best then best = s end
                end
                if best and best > 0 then lastAltRate = best / 3600 end
            end
        end
        chardb.zone = result.zone
        -- the shown route's order, for the first plan of the next session (see `keep` above)
        chardb.route = #result.plan.steps > 0 and { zone = result.zone, order = result.plan.order } or nil
        view.ranked, view.plan, view.zone = result.ranked, result.plan, result.zone
        view.zoneName = Zones.Name(result.zone) or Game.MapName(result.zone) or ("Map " .. tostring(result.zone))
        view.level, view.here = result.state.level, result.state.map
        view.logCount, view.capacity = #result.state.log, result.state.capacity
        view.groupSize = result.state.groupSize
        view.xpBonus, view.xpBuffs, view.restedPool = result.state.xpBonus, xpBuffs, result.state.restedPool
        plannedRested = result.state.restedPool
        -- until the new itinerary is in, the move-on rule uses the one worked out before
        moveOn(result.plan, result.ranked, view.itinerary)
        view.updated = Game.Now()
        travel = result.travel
        view.flightStops = result.flightStops -- unknown flight points close to the route (Zones.FlightStops)
        -- the step log: how long the step that was first really took (see ns.Tracker)
        Tracker.OnPlan(result.plan, { now = view.updated, level = result.state.level, group = result.state.groupSize,
            log = result.state.log, completed = completed })
        view.flightsKnown = next(chardb.knownNodes) ~= nil
        setStatus("ready", nil)
        publish()
        if more then startItinerary(result) end
        if pending then return end
        if pendingFull then Engine.Replan(true) end
    end)
end

--- Ask for a new plan. `full` also re-ranks the other zones. Bursts of calls run once.
function Engine.Replan(full)
    if not started then return end
    if full then pendingFull = true end
    if pending then return end
    pending = true
    local wait = math.max(Engine.DEBOUNCE, lastRun + Engine.MIN_GAP - Game.Now())
    Game.After(wait, function()
        if Async.IsRunning("plan") then
            pending = false
            Game.After(Engine.DEBOUNCE, function() Engine.Replan() end)
            return
        end
        run()
    end)
end

--- Show a zone (nil: let LevelScout choose).
function Engine.SetZone(map)
    chardb.zone = map
    chardb.route = nil
    Engine.view.plan = nil
    Engine.Replan(true)
end

--- Plan from scratch: the shown route (and the one saved with the character) and the kept
--- plans are forgotten, so nothing holds the new plan to the old order.
function Engine.ReplanFresh()
    chardb.route = nil
    Engine.view.plan = nil
    Engine.ResetMemory()
    Engine.Replan(true)
end

--- Leave a quest out of all plans, or bring it back.
function Engine.Ignore(questId, ignore)
    chardb.ignored[questId] = ignore and true or nil
    Engine.Replan(true)
end

--- Route elite (group) quests, or only list them.
function Engine.SetRouteElite(on)
    chardb.routeElite = on and true or false
    Engine.Replan(true)
end

--- The Deeprun Tram in routes: "on", "off" or "auto" (taken only while the flight between
--- Stormwind and Ironforge is not known). Saved with the character.
function Engine.SetTram(mode)
    chardb.tram = (mode == "on" or mode == "off") and mode or nil
    Engine.Replan(true)
end

--- The setting ("on" | "off" | "auto") and whether the last plan's routes could take the tram
--- (nil: no plan yet, or this side has no tram).
function Engine.Tram()
    return chardb and chardb.tram or "auto", travel and travel.tramUsed
end

--- Debug view: record the search of the shown zone on every full re-plan (this session only).
function Engine.SetTrace(on)
    Engine.trace = on and true or nil
    if on then Engine.Replan(true) else Engine.view.trace = nil end
end

function Engine.RoutesElite() return chardb == nil or chardb.routeElite ~= false end

--- Leave a flight point out of the route (the player does not want the detour), or put it back.
function Engine.SkipFlightPoint(nodeId, skip)
    chardb.skippedNodes[nodeId] = skip and true or nil
    Engine.Replan()
end

function Engine.IsIgnored(questId) return chardb and chardb.ignored[questId] == true end

local handlers = {}
function handlers.QUEST_ACCEPTED() Engine.Replan() end
function handlers.QUEST_REMOVED() Engine.Replan() end
function handlers.QUEST_TURNED_IN(questId)
    if type(questId) == "number" and completed then completed[questId] = true end
    if type(questId) == "number" and chardb then chardb.ignored[questId] = nil end -- done: no longer "skipped"
    Engine.Replan()
end
-- What the tracker needs to know about the moment a sample is taken.
local function trackInfo(withPlace)
    local info = { now = Game.Now(), solo = Game.GetGroupSize() == 1 }
    if withPlace then
        info.level, info.faction = Game.GetPlayer().level, Game.GetPlayerContext().faction
        local map, x, y = Game.GetPosition(Geo.HasMap)
        if map then info.loc = Geo.Loc(map, x * 100, y * 100) end
    end
    return info
end
-- The bags changed: a dropped item may start a quest. Said once per item, and planned anew.
function handlers.BAG_UPDATE_DELAYED()
    if not Data.IsIndexBuilt() then return end
    local inLog = {}
    for _, q in ipairs(Game.GetQuestLog()) do inLog[q.id] = true end
    local quests = bagQuests(inLog)
    local key = bagKey(quests)
    if key == bagSignature then return end
    bagSignature = key
    local ids = {}
    for id in pairs(quests) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local item = quests[id]
        if not bagNoticed[item] then
            local q, i = Data.GetQuest(id), Data.GetItem(item)
            ns.Print("%s in your bags starts a quest: |cffffd100%s|r. Right-click it to start it.",
                i and i.name or ("Item " .. item), q and q.name or ("Quest " .. id))
        end
        bagNoticed[item] = true
    end
    Engine.Replan(true)
end

function handlers.QUEST_LOG_UPDATE()
    local log = Game.GetQuestLog()
    Tracker.OnLog(log, trackInfo(true)) -- it compares with the log it saw last
    -- Fires for many reasons; replan only when progress really changed.
    if signature(log) ~= lastSignature then Engine.Replan() end
end
-- A kill by us or our party: one try at every quest item that mob drops (learned solo only).
function handlers.PARTY_KILL(_, targetGUID)
    Tracker.OnKill(Game.NpcFromGUID(targetGUID), trackInfo())
end
-- The player stands at an NPC whose accept or turn-in comes later in the route, after a stop
-- somewhere else: plan again with those stops brought to the front (when their quest allows it
-- now: see Planner.Plan, opts.front). Each is asked for once until the log or the level changes.
local function nearbyLater(loc, level)
    local view, plan = Engine.view, Engine.view.plan
    if view.status ~= "ready" or not (plan and plan.order) or pending or Async.IsRunning("plan") then return end
    local stamp = tostring(lastSignature) .. "@" .. tostring(level)
    local away, keys = false, nil -- away: a stop elsewhere comes first (the ones here are not next)
    for i, s in ipairs(plan.steps) do
        if not s.fromBag then
            local d = s.loc and Geo.Dist(loc, s.loc)
            if not (d and d <= Engine.NEAR_YARDS) then
                away = true
            elseif away and (s.kind == "accept" or s.kind == "turnin") and plan.order[i]
                and not (s.needLevel and level and s.needLevel > level) and frontAsked[plan.order[i]] ~= stamp then
                keys = keys or {}
                keys[#keys + 1] = plan.order[i]
            end
        end
    end
    if not keys then return end
    for _, key in ipairs(keys) do frontAsked[key] = stamp end
    front = keys
    Engine.Replan()
end

--- Tell the tracker where the player is (it learns the travel speed from steady stretches), and
--- bring stops the player stands at forward in the route. Called about once a second. Returns
--- the speed sample in yards per second when one was taken.
function Engine.TrackMove()
    local info = Game.GetMovement()
    info.now, info.level = Game.Now(), Game.GetPlayer().level
    if not info.blocked and info.level then
        local map, x, y = Game.GetPosition(Geo.HasMap)
        if map then info.loc = Geo.Loc(map, x * 100, y * 100) end
    end
    if info.loc then nearbyLater(info.loc, info.level) end
    return Tracker.OnMove(info)
end
-- A new level: everything is planned again (zones, dungeons, the route), at the new level.
function handlers.PLAYER_LEVEL_UP(level)
    leveledTo = tonumber(level)
    Engine.Replan(true)
end
-- A buff came or went: re-plan if the XP bonus changed (sleeping bag, food).
local function buffsChanged()
    local before = xpBonus
    if math.abs(Engine.XPBonus() - before) > 0.001 then Engine.Replan(true) end
end
function handlers.UNIT_AURA(unit) if unit == "player" then buffsChanged() end end
function handlers.PLAYER_REGEN_ENABLED() buffsChanged() end -- out of combat: buffs are readable again
-- Rested XP: kills drain it a little each time, which the plan already expects. Re-plan when it
-- changes by a lot at once: resting in a tavern, or the pool running dry.
function handlers.UPDATE_EXHAUSTION()
    local now = Game.GetPlayer().rested or 0
    local change = math.abs(now - plannedRested)
    if (now == 0) ~= (plannedRested == 0) or change > 0.1 * (Game.GetPlayer().xpMax or math.huge) then
        plannedRested = now
        Engine.Replan(true)
    end
end
function handlers.PLAYER_UPDATE_RESTING() handlers.UPDATE_EXHAUSTION() end
-- A party member accepted, finished or dropped a quest: drops may now be split differently.
function handlers.UNIT_QUEST_LOG_CHANGED(unit)
    if unit ~= "player" then Engine.Replan() end
end
-- Joining or leaving a group changes the XP from kills (it is shared), so every zone is
-- planned again. The roster event also fires for other changes; only the size matters.
function handlers.GROUP_ROSTER_UPDATE()
    if Game.GetGroupSize() ~= (Engine.view.groupSize or 1) then Engine.Replan(true) end
end
function handlers.ZONE_CHANGED_NEW_AREA() Engine.Replan(true) end
function handlers.PLAYER_ENTERING_WORLD()
    completed = Game.GetCompletedQuests()
    Engine.ResetMemory()
    Engine.Replan(true)
end
function handlers.TAXIMAP_OPENED()
    local nodes = Game.GetTaxiNodes()
    if not nodes then return end
    local changed = false
    for id in pairs(nodes) do
        if not chardb.knownNodes[id] then chardb.knownNodes[id], changed = true, true end
    end
    Engine.view.flightNote = nil
    if changed then Engine.Replan(true) end
end

-- The flight node of our side closest to the player: id, name, yards.
local function nearestFlightNode()
    local map, x, y = Game.GetPosition(Geo.HasMap)
    local travel = (Data.World() or {}).travel
    if not map or not travel then return nil end
    local here = Geo.Loc(map, x * 100, y * 100)
    local side = Game.GetPlayerContext().faction == "Alliance" and "a" or "h"
    local best, bestName, bestDist
    for id, n in pairs(travel.nodes or {}) do
        if n[7] == "n" or n[7] == side then
            local d = Geo.Dist(here, Geo.WorldLoc(n[1], n[2], n[3]))
            if d and (not bestDist or d < bestDist) then best, bestName, bestDist = id, n[9], d end
        end
    end
    return best, bestName, bestDist
end

Engine.FLIGHT_NODE_RANGE = 150 -- yards: "at the flight master" when a new path is discovered

-- "New flight path discovered": the game does not say which one, but we are standing at it.
-- The nearest flight point is recorded at once; if none is close, the window asks for the
-- flight map to be opened (that always gives the full list).
function handlers.UI_INFO_MESSAGE(_, message)
    local text = rawget(_G, "ERR_NEWTAXIPATH")
    if type(text) ~= "string" or message ~= text then return end
    local id, name, dist = nearestFlightNode()
    if id and dist <= Engine.FLIGHT_NODE_RANGE then
        if not chardb.knownNodes[id] then
            chardb.knownNodes[id] = true
            ns.Print("Learned flight point: %s", tostring(name))
            Engine.Replan(true)
        end
    else
        Engine.view.flightNote = "New flight point found. Open the flight map once so LevelScout can use it."
        ns.Print(Engine.view.flightNote)
        publish()
    end
end

--- Called once at login, after ns.Data.Init.
function Engine.Start()
    if started then return end
    started = true
    LevelScoutDB = type(LevelScoutDB) == "table" and LevelScoutDB or {}
    LevelScoutCharDB = type(LevelScoutCharDB) == "table" and LevelScoutCharDB or {}
    db, chardb = LevelScoutDB, LevelScoutCharDB
    chardb.ignored = type(chardb.ignored) == "table" and chardb.ignored or {}
    chardb.knownNodes = type(chardb.knownNodes) == "table" and chardb.knownNodes or {}
    -- which zone a spot recorded on a continent map is in: the game knows the real borders
    Zones.ZoneResolver = function(loc)
        if not (loc.map and loc.mx and loc.my) then return nil end
        local zones = (Data.World() or {}).zones or {}
        return Game.ZoneAt(loc.map, loc.mx / 100, loc.my / 100, function(id) return zones[id] ~= nil end)
    end
    -- the shown route's order as it was at logout: { zone, order = { "P:123", "W:...", "T:123" } }
    local route = chardb.route
    local valid = type(route) == "table" and type(route.zone) == "number" and type(route.order) == "table" and #route.order > 0
    for _, key in ipairs(valid and route.order or {}) do
        if type(key) ~= "string" then valid = false break end
    end
    chardb.route = valid and route or nil
    chardb.skippedNodes = type(chardb.skippedNodes) == "table" and chardb.skippedNodes or {}
    chardb.seenBuffs = type(chardb.seenBuffs) == "table" and chardb.seenBuffs or {}
    chardb.mutedBuffs = type(chardb.mutedBuffs) == "table" and chardb.mutedBuffs or {}
    chardb.pace = type(chardb.pace) == "table" and chardb.pace or {}  -- this character's pace
    db.drops = type(db.drops) == "table" and db.drops or {}           -- drop counts: the same for every character
    chardb.steps = type(chardb.steps) == "table" and chardb.steps or {} -- planned against real time per step
    chardb.stepModel = type(chardb.stepModel) == "table" and chardb.stepModel or {} -- fitted on the step log
    Tracker.Start(chardb.pace, db.drops, chardb.steps, chardb.stepModel)
    Engine.db, Engine.chardb = db, chardb
    completed = Game.GetCompletedQuests()
    if not Data.usable then
        setStatus("error", Data.status.message or "LevelScout's data is not usable")
        return publish()
    end
    Geo.Init(Data.World())
    local names = {}
    for name in pairs(handlers) do names[#names + 1] = name end
    local listener = Game.Listen(names, function(event, ...) handlers[event](...) end)
    -- buff timers are looked at every few seconds, the player's position about once a second
    local since, sinceMove = 0, 0
    listener:SetScript("OnUpdate", function(_, elapsed)
        since, sinceMove = since + (elapsed or 0), sinceMove + (elapsed or 0)
        if sinceMove >= Engine.MOVE_EVERY then
            sinceMove = 0
            Engine.TrackMove()
            Guide.Tick() -- the way to the current step, from where we are now
        end
        if since >= 5 then
            since = 0
            Engine.CheckBuffs()
        end
    end)
    setStatus("planning", "Reading quest data")
    publish()
    Async.Run("index", function(checkpoint) return Data.BuildIndex(checkpoint) end, function(ok, err)
        if not ok then
            setStatus("error", "Could not index the quest data: " .. tostring(err))
            return publish()
        end
        Engine.Replan(true)
    end)
end
