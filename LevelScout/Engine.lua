-- Engine.lua: keeps the plan current. Reads the character's state through ns.Game, runs the
-- planner as a background job, and publishes one `view` table that the UI and the waypoint
-- follow. Nothing here blocks a frame: planning yields every few milliseconds.

local _, ns = ...
local Data, Game, Async, Zones, Geo, Guide, Tracker = ns.Data, ns.Game, ns.Async, ns.Zones, ns.Geo, ns.Guide, ns.Tracker
local Classes, Snapshot, Play = ns.Classes, ns.Snapshot, ns.Play

local Engine = {}
ns.Engine = Engine

Engine.DEBOUNCE = 0.5        -- seconds: events arrive in bursts
Engine.MIN_GAP = 2           -- seconds between plans: a kill quest updates the log on every kill
Engine.RERANK_EVERY = 45     -- seconds between background re-rankings of the other zones
Engine.KEEP_GOAL = true      -- a clearly better route for the shown zone is taken with the step in hand still first
Engine.FOLLOW_PATH = true    -- the shown zone moves on by itself where the itinerary leaves it (see the plan job)
Engine.PROGRESS = true       -- say what the planner is doing while it runs (view.progress)
Engine.PROGRESS_EVERY = 0.15 -- seconds between two progress notices to the window, at least
-- A full re-plan's bar: ranking the zones up to SHARE_RANK, checking the shown route up to
-- SHARE_CHECK, then the next hours (its own job) to the end. Shares of measured time.
Engine.SHARE_RANK, Engine.SHARE_CHECK = 0.75, 0.8
Engine.MOVE_EVERY = 1        -- seconds between two looks at where the player is (travel speed, see ns.Tracker.OnMove)
Engine.NEAR_YARDS = 40       -- an accept or turn-in further down the route this close comes to its front
Engine.SNAPSHOTS = 5         -- snapshots kept with the character, the oldest dropped first (see Engine.Snapshot)
Engine.AUTO_SNAPSHOT = true  -- a snapshot is taken by itself when the player overrules the plan (a zone by hand, a skipped quest)
Engine.AUTO_SNAPSHOTS = 3    -- of those, this many are kept (next to the ones asked for)
Engine.AUTO_SNAPSHOT_EVERY = 900 -- seconds between two of them at least
Engine.BACK_WITHIN = 900     -- seconds of play: a zone chosen by hand this soon after the path left it is "back" (see ns.Play)

local memory = ns.Memory.New()   -- plans kept between rankings (reused) and as warm starts (ns.Memory); never saved

--- Forget the kept plans: the next plans start from scratch and nothing is reused.
function Engine.ResetMemory() ns.Memory.Reset(memory) end

--- What the UI shows. status: "starting" | "planning" | "ready" | "paused" | "error".
--- chains: class quest chains on offer (see offersOf); chain: the one being followed, or nil.
Engine.view = { status = "starting", message = "Loading", ranked = {}, moveOn = { suggest = false }, chains = {} }

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
local rankAfter                  -- a plan made at once (Engine.ReplanNow): the zones are ranked right after it
local quickNow                   -- the next plan is the shown route only, however old the ranking (Engine.ReplanNow)
local freshWay                   -- the next plan's way to the current step is taken at once (Guide.Follow)
local frontAsked = {}            -- [key] = the quest log and level it was last asked for with (asked once each)
local snap, saveSnapshot         -- the snapshot being taken (Engine.Snapshot), and what saves it (defined below)
local playEvent, autoSnapshot    -- the play log (ns.Play): an event; a snapshot for one (defined below)
local lastMoved                  -- { from = zone, a = active clock }: when the path last moved on by itself

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

-- `fresh`: the way to the current step is worked out again and taken at once, even for the
-- same step (new flight points: see Engine.ReplanNow).
publish = function(fresh)
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
        Guide.Follow({ loc = stop.loc }, "New flight point: " .. stop.name, travel, keep, fresh)
    elseif view.status == "ready" or view.status == "planning" then
        -- the waypoint: the step, or the flight master or harbour the way to it starts at
        Guide.Follow(step, step and ns.StepTitle and ns.StepTitle(step) or nil, travel, keep, fresh)
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
        routeEscort = chardb.routeEscort == true,
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
    local was = view.moveOn
    view.moveOn = Zones.MoveOn(plan, ranked, view.moveOn, itinerary)
    if view.moveOn.map then
        view.moveOn.name = Zones.Name(view.moveOn.map) or Game.MapName(view.moveOn.map) or ("Map " .. view.moveOn.map)
    end
    -- the play log: the banner came up, or names another zone
    local now = view.moveOn
    if now.suggest and now.map and not (was and was.suggest and was.map == now.map) then
        playEvent("banner", { to = now.map, gain = now.gain })
    end
end

-- The next hours across zones (and the search view's recording), after the zones and the
-- route are on screen. Worked out after each ranking and kept in between. A new plan job
-- stops it; it is then worked out again after that job, from its result.
startItinerary = function(result)
    local view = Engine.view
    itineraryOwed = true
    view.busy = true
    view.progress = Engine.PROGRESS and (view.progress or { fraction = Engine.SHARE_CHECK, text = "Planning the next hours" }) or nil
    local state, zone, plan, ranked = result.state, result.zone, result.base or result.plan, view.ranked
    local shownPlan, border = result.plan, Zones.BORDER and chardb.border or nil
    local seam, seamPlan = Zones.SEAM and chardb.seam or nil, Zones.SEAM and Zones.SeamLayer(result.plan) or nil
    Async.Run("itinerary", function(checkpoint)
        state.checkpoint = checkpoint
        state.progress = view.progress and note or nil
        local ctx = Zones.Context(state)
        phase(Engine.SHARE_CHECK, 1, "Planning the next hours", true)
        local was = view.itinerary
        if snap and snap.state == state then snap.itineraryWas = Snapshot.Maps(was); snap.borderWas = Snapshot.Copy(border); snap.seamWas = Snapshot.Copy(seam) end
        local itinerary = Zones.Itinerary(state, ctx, ranked, { shown = zone, plan = plan, was = was,
            border = border, borderPlan = (shownPlan ~= plan and shownPlan.base) and shownPlan or nil,
            seam = seam, seamPlan = seamPlan })
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
        -- the route on screen follows the itinerary: with the quests it takes along, or without them again
        local show
        local first = itinerary and itinerary.segments[1]
        if (Zones.BORDER or Zones.SEAM) and first and first.map == zone and first.plan ~= shownPlan then
            show = { plan = first.plan, flightStops = Zones.FlightStops(first.plan, ctx, chardb.skippedNodes) }
        end
        return { itinerary = itinerary, trace = trace, show = show }
    end, function(ok, out)
        itineraryOwed = false
        view.busy = Async.IsRunning("plan")
        if not view.busy then view.progress, scope, zoneSpan = nil, nil, nil end
        local mine = snap and snap.ranked and snap.state == state -- the run a snapshot waits for
        if ok then
            view.itinerary = out.itinerary
            if (Zones.BORDER or Zones.SEAM) and not view.chain then
                local function copy(list) local out = {}; for i, k in ipairs(list or {}) do out[i] = k end; return out end
                if Zones.BORDER then
                    local b = out.itinerary and out.itinerary.border
                    -- (a plain copy for SavedVariables: the ids list is the plan's own borderIds)
                    local ids, to = {}, {}
                    for i, id in ipairs(b and b.ids or {}) do ids[i], to[id] = id, b.to and b.to[id] end
                    chardb.border = b and { zone = b.zone, ids = ids, to = to, before = b.before } or nil
                end
                if Zones.SEAM then
                    local sm = out.itinerary and out.itinerary.seam
                    chardb.seam = sm and { zone = sm.zone, to = sm.to, window = copy(sm.window), keys = copy(sm.keys),
                        leave = sm.leave, windowB = copy(sm.windowB), head = copy(sm.head), leaveB = sm.leaveB } or nil
                end
                if out.show and view.zone == zone and view.plan == shownPlan then
                    view.plan, view.flightStops = out.show.plan, out.show.flightStops
                    chardb.route = { zone = zone, order = Zones.Plain(view.plan).order } -- (the overlays are laid over it again)
                    Tracker.OnPlan(view.plan, { now = Game.Now(), level = state.level, group = state.groupSize,
                        log = state.log, completed = completed })
                end
            end
            view.trace = Engine.trace and out.trace or nil
            local was = view.moveOn
            moveOn(view.plan, view.ranked, out.itinerary)
            if mine then saveSnapshot(was) end
            -- the play log: what the path promises from here (at most every Play.FORECAST_EVERY of play)
            if view.plan and view.zone and not view.chain then
                Play.Forecast(Tracker.Active(Game.Now()), { level = view.level, zone = view.zone, plan = view.plan, itinerary = out.itinerary })
            end
        else
            ns.Print("|cffff5555Planning the next hours failed: %s|r", tostring(out))
            if mine then
                if not snap.auto then ns.Print("Snapshot not taken: planning the next hours failed.") end
                snap = nil
            end
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

---------------------------------------------------------------------------------------------
-- Class quest chains (ns.Classes)
---------------------------------------------------------------------------------------------
-- A chain that becomes available is offered: one line in chat, and a row on the window's Class
-- tab, whose title glows until the tab is opened. Picked (chardb.chain), it is the plan shown
-- until it has no steps left; then the zones take over again. Per chain,
-- chardb.classChains[id] = { told = its open quests when chat said so, seen = its open quests
-- when the Class tab was open, never = true: not suggested (listed apart on the tab) }. A chain
-- whose open quests change (its next part opens, a quest of it is dropped) is news again.

Engine.CHAIN_REPLAN_AGE = 300 -- seconds: an offered chain is planned again this often at most, unless it moved on
local chainPlans = {}          -- [chain id] = { sig, level, at, plan }: the offered chains' plans

local function chainRecord(id)
    local rec = chardb.classChains[id]
    if type(rec) ~= "table" then rec = {}; chardb.classChains[id] = rec end
    return rec
end

local function mapName(map)
    return map and (Zones.Name(map) or Game.MapName(map) or ("Map " .. tostring(map))) or nil
end

---------------------------------------------------------------------------------------------
-- Snapshots (ns.Snapshot): what a plan was made from and what was shown for it
---------------------------------------------------------------------------------------------
-- `/ls snapshot` records a light view of what is on screen (snap.before), then plans once more
-- in full. That run's state is copied to plain data as it is gathered (snap.input; only while a
-- snapshot is pending), and when its plan job and its itinerary job have both finished, what
-- came out is recorded and saved. The input and the result of one record belong to one run, so
-- a replay (tests/replay.lua) can plan the input again and compare. Every hook checks that it is
-- still the state of that run (snap.state): a job that was stopped never reports, and the next
-- run takes the input again.

-- The input of the run the snapshot waits for, as gathered (`state` is nil: it could not be).
local function takeInput(state, why)
    if not state then
        if not snap.auto then ns.Print("Snapshot not taken: %s.", tostring(why)) end
        snap = nil
        return
    end
    snap.state, snap.ranked, snap.itineraryWas, snap.zone = state, nil, nil, nil
    local ok, input = pcall(Snapshot.Capture, state)
    if not ok then
        if not snap.auto then ns.Print("|cffff5555Snapshot not taken: %s|r", tostring(input)) end
        snap = nil
        return
    end
    snap.input = input
    if ns.Planner.GOAL == "surplus" then snap.input.altRate = lastAltRate end -- (set in the job, see run)
end

-- The record of the finished run: `moveOnWas` is the banner before this run's itinerary changed it.
local function record(s, moveOnWas)
    local view = Engine.view
    local pctx = Game.GetPlayerContext()
    local names = {}
    local function name(map) if map then names[map] = mapName(map) end end
    local shown = Snapshot.View(view)
    name(s.input.map)
    name(shown.zone)
    for _, z in ipairs(shown.ranked) do name(z.map) end
    for _, seg in ipairs(shown.itinerary and shown.itinerary.segments or {}) do name(seg.map) end
    if shown.itinerary and shown.itinerary.alt then name(shown.itinerary.alt.map) end
    local clock = rawget(_G, "date")
    return {
        format = Snapshot.FORMAT, note = s.note, auto = s.auto and true or nil,
        date = type(clock) == "function" and clock("%Y-%m-%d %H:%M:%S") or nil,
        asked = s.asked, saved = Game.Now(), rankedAt = lastRank,
        version = { addon = ns.version, client = pctx.clientBuild, data = Data.status.build,
            generated = Data.status.generated, sources = Snapshot.Copy(Data.status.sources) },
        settings = Snapshot.Settings(), zone = s.zone, input = s.input, warm = Snapshot.Warm(view.ranked),
        itineraryWas = s.itineraryWas, borderWas = s.borderWas, seamWas = s.seamWas,
        moveOnWas = moveOnWas and { suggest = moveOnWas.suggest and true or false, map = moveOnWas.map } or nil,
        shown = shown, before = s.before, names = names,
    }
end

saveSnapshot = function(moveOnWas)
    local s = snap
    snap = nil
    if not s then return end
    local ok, rec = pcall(record, s, moveOnWas)
    if not ok then
        if not s.auto then ns.Print("|cffff5555Snapshot not taken: %s|r", tostring(rec)) end
        return
    end
    local id = (tonumber(chardb.snapshotCount) or 0) + 1
    chardb.snapshotCount, rec.id = id, id
    local list = chardb.snapshots
    list[#list + 1] = rec
    -- the ones asked for and the ones taken by themselves are kept apart: neither pushes the other out
    local function cap(auto, keep)
        local n = 0
        for i = #list, 1, -1 do
            if (list[i].auto == true) == auto then
                n = n + 1
                if n > keep then table.remove(list, i) end
            end
        end
    end
    cap(false, Engine.SNAPSHOTS)
    cap(true, Engine.AUTO_SNAPSHOTS)
    if s.event then s.event.snap = id end -- (the play log's event it was taken for)
    if not s.auto then
        ns.Print("Snapshot %d saved%s. It is written to disk at logout or /reload.", id, s.note and (" (" .. s.note .. ")") or "")
    end
end

-- The play log (ns.Play). An event, on the active clock:
playEvent = function(kind, data)
    return Play.Event(Tracker.Active(Game.Now()), kind, data)
end
-- and a snapshot for an event where the player overruled the plan: what was on screen and what
-- it was made from, to be planned again later (tests/replay.lua). Quiet, and not more often
-- than every AUTO_SNAPSHOT_EVERY seconds.
local lastAuto
autoSnapshot = function(note, event)
    if not Engine.AUTO_SNAPSHOT or snap then return end
    local now = Game.Now()
    if lastAuto and now - lastAuto < Engine.AUTO_SNAPSHOT_EVERY then return end
    if Engine.Snapshot(note, true, event) then lastAuto = now end
end

-- The zones a plan's steps are in, in route order, each once (names).
local function planZones(plan)
    local out, seen = {}, {}
    for _, step in ipairs(plan.steps) do
        local zone = step.loc and (Zones.ZoneAt(step.loc) or step.loc.map)
        if zone and not seen[zone] then seen[zone] = true; out[#out + 1] = mapName(zone) end
    end
    return out
end

-- The chains to offer: something in them can be done now, and the zone's route (`levelPlan`)
-- does not do it already. Each is planned (Classes.Plan) when it is new, has moved on, the
-- level changed, or its plan is older than CHAIN_REPLAN_AGE; one that cannot be planned is not
-- offered. `best`: the best zone's XP per hour, for what the chain costs against leveling.
-- { { id, name, level (of the quest it is named after), sig, quests, inLog, count (quests of the chain the plan turns in), seconds, xp,
--     score, start (whom the first step is with), startZone, trip (seconds to it), zones (names),
--     facts (Classes.Facts), lost (seconds of leveling the chain costs; < 0: it pays better) } }
local function offersOf(chains, ctx, skip, levelPlan, best)
    local out, plans = {}, {}
    for _, c in ipairs(chains) do
        if c.id ~= skip and #c.open > 0 and not (levelPlan and Classes.InPlan(c, levelPlan)) then
            local kept = chainPlans[c.id]
            local plan = kept and kept.sig == c.sig and kept.level == ctx.level
                and (ctx.now or 0) - kept.at < Engine.CHAIN_REPLAN_AGE and kept.plan or nil
            plans[c.id] = kept
            if not plan then
                plan = Classes.Plan(c, ctx)
                plans[c.id] = { sig = c.sig, level = ctx.level, at = ctx.now or 0, plan = plan }
            end
            if plan and #plan.steps > 0 then
                local first = plan.steps[1]
                out[#out + 1] = { id = c.id, name = plan.chainName, level = plan.chainLevel, sig = c.sig, quests = c.quests, inLog = c.inLog,
                    count = plan.chainQuests, seconds = plan.seconds, xp = plan.xp, score = plan.score,
                    start = first.target, startZone = mapName(first.loc and (Zones.ZoneAt(first.loc) or first.loc.map)),
                    trip = first.travel, zones = planZones(plan), facts = Classes.Facts(c, plan),
                    lost = (best and best > 0) and (plan.seconds - plan.xp / best * 3600) or nil }
            end
        end
    end
    chainPlans = plans
    return out
end

-- new: not seen on the Class tab with these open quests; never: turned off by the player.
local function markOffers()
    for _, o in ipairs(Engine.view.chains or {}) do
        local rec = chardb.classChains[o.id]
        o.never = type(rec) == "table" and rec.never or nil
        o.new = (not o.never and not (type(rec) == "table" and rec.seen == o.sig)) or nil
    end
end

-- One line in chat for each chain on offer that is news.
local function announce()
    for _, o in ipairs(Engine.view.chains or {}) do
        if o.new then
            local rec = chainRecord(o.id)
            if rec.told ~= o.sig then
                rec.told = o.sig
                ns.Print("Class quest |cffffd100%s|r is now available. Pick it on the Class tab of the LevelScout window (/ls).",
                    ns.Format and ns.Format.QuestName(o.name, o.level) or o.name)
            end
        end
    end
end

-- What the window shows of the chain followed (view.chain), from its plan. `after`: the zone
-- leveling goes on in.
local function chainView(chain, plan, after)
    local facts = Classes.Facts(chain, plan)
    return { id = chain.id, kind = chardb.chainKind or "class", name = plan.chainName, level = plan.chainLevel, sig = chain.sig, set = chain.set,
        quests = chain.quests, left = plan.chainQuests, laterLevel = facts.laterLevel,
        after = after, afterName = mapName(after) }
end

-- The chain followed has nothing left to plan: say why, and where leveling goes on.
-- The title of the plan shown while a chain is followed: "Class quest: [30] Name" for a class
-- quest chain, "Quest: [28] Name" for a quest (and its chain) picked by name.
local function chainTitle(plan)
    local label = chardb.chainKind == "quest" and "Quest: " or "Class quest: "
    return label .. ns.Format.QuestName(plan.chainName, plan.chainLevel)
end

local function chainEnded(e, zoneName)
    local name = e.name or "The class quest"
    local back = zoneName and ("Back to leveling in " .. zoneName .. ".") or "Back to the leveling plan."
    if e.why == "done" then
        ns.Print("%s done: |cffffd100%s|r. %s", e.kind == "quest" and "Quest" or "Class quest", name, back)
    elseif e.why == "later" then
        ns.Print("|cffffd100%s|r: the rest of the chain opens at level %d. %s", name, e.level, back)
    elseif e.why == "group" then
        ns.Print("|cffffd100%s|r: the next part, %s, is a group quest. %s", name, e.groupName, back)
    elseif e.why == "escort" then
        ns.Print("|cffffd100%s|r: the next part, %s, is an escort quest. %s", name, e.escortName, back)
    else
        ns.Print("|cffffd100%s|r: nothing more of it can be planned for now. %s", name, back)
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
    if snap then takeInput(state, why) end
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
    -- (a plan made at once for the player looking at it is the shown route only: the zones follow)
    if (not quickNow and now - lastRank > Engine.RERANK_EVERY) or #view.ranked == 0 then full = true end
    if quickNow then full = false end
    quickNow = false
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
        if not view.plan and not chardb.chain and saved and saved.zone == chardb.zone then
            local early = Zones.PlanZone(saved.zone, ctx, saved.order)
            if Zones.SEAM then early = Zones.WithSeam(saved.zone, ctx, early, chardb.seam) end -- (as shown before the relog)
            if Zones.BORDER then early = Zones.WithBorder(saved.zone, ctx, early, chardb.border) end -- (as shown before the relog)
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
        -- Class quest chains. The one picked (chardb.chain) is the plan shown while it has steps
        -- (planned like a dungeon, without the search: see Classes.Plan). It is planned before
        -- the zones are ranked: on the first plan of a session (login, /reload) it is shown at
        -- once, in the order saved with the character, and the zones are ranked behind it.
        -- When it has nothing left, the zones take over again in this same job.
        local active, chainPlan, ended
        if chardb.chain then
            if chardb.chainKind == "quest" then
                active = Classes.ChainOf(chardb.chain, ctx) -- a quest picked by name, and its chain
            else
                for _, c in ipairs(Classes.Chains(ctx)) do if c.id == chardb.chain then active = c end end
            end
            local tried
            if active and #active.open > 0 then
                tried = Classes.Plan(active, ctx)
                chainPlan = tried
                -- the shown order (or the one saved with the character) is kept unless a new
                -- one is clearly better, as for a zone
                local was = view.plan
                local order = (was and was.chain == active.id and #was.steps > 0) and was.order or nil
                local savedChain = chardb.chainRoute
                if not was and savedChain and savedChain.chain == active.id then order = savedChain.order end
                if tried and order then
                    local kept = Classes.Plan(active, ctx, order, was and frontKeys or nil)
                    if kept and #kept.steps > 0 and (kept.fronted or not Zones.PreferFresh(kept, tried)) then chainPlan = kept end
                end
                if chainPlan and #chainPlan.steps == 0 then chainPlan = nil end
            end
            if not chainPlan then
                local facts = active and Classes.Facts(active, tried) or {}
                ended = { id = chardb.chain, kind = chardb.chainKind, name = chardb.chainName or (active and active.name),
                    why = (not active and "done") or (facts.groupName and "group") or (facts.escortName and "escort") or (facts.laterLevel and "later") or "stuck",
                    level = facts.laterLevel, groupName = facts.groupName, escortName = facts.escortName }
            elseif not view.plan then
                view.plan, view.zone, view.chain = chainPlan, nil, chainView(active, chainPlan, chardb.zone)
                view.zoneName = chainTitle(chainPlan)
                view.moveOn, view.itinerary = { suggest = false }, nil
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
            if snap and snap.state == state then snap.zone = chardb.zone end -- (what Zones.Rank is asked to include)
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
        local chains = Classes.Chains(ctx)
        local best = 0
        for _, z in ipairs(ranked) do if z.plan.score > best then best = z.plan.score end end
        if chainPlan then
            -- where leveling goes on afterwards: the chosen zone while it has steps, else the best-ranked
            local after = (chardb.zone and open(chardb.zone)) and chardb.zone or (ranked[1] and ranked[1].map) or nil
            return { ranked = ranked, plan = chainPlan, zone = nil, state = state, full = full, travel = ctx.travel,
                flightStops = Zones.FlightStops(chainPlan, ctx, chardb.skippedNodes),
                chain = active, chainAfter = after, offers = offersOf(chains, ctx, active.id, nil, best) }
        end
        -- (a class quest plan shown until now is no zone's route: nothing of it is kept)
        -- (with quests taken along to the next zone, the route without them: its order rebuilt
        -- without Zones.WithBorder would plan them whole, their far turn-in included; and without the
        -- way across planned together)
        local shown = (view.plan and not view.plan.chain) and Zones.Plain(view.plan) or nil
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
        -- The path moves on. The itinerary made for the shown zone leaves it after a step (its
        -- first zone's leave point) for the next zone. Once that step is done, the next zone is
        -- the one shown, in the order the itinerary planned for it, and what is left here stays
        -- for later: the route is one path across zones, and the step after the last one here
        -- is the first one there. (Not into a dungeon: that takes a group, so it is the
        -- player's choice. Leaving for a zone the itinerary did not plan from here stays the
        -- banner's business, see Zones.MoveOn.)
        local movedOn
        local path = view.itinerary
        if Engine.FOLLOW_PATH and zone and shown and shown.zone == zone and #shown.steps > 0
            and path and path.shown == zone and path.segments[2] and path.segments[1].map == zone
            and path.segments[1].leaveKey and path.segments[2].map > 0 then
            local key = path.segments[1].leaveKey
            local function has(order)
                for _, k in ipairs(order or {}) do if k == key then return true end end
                return false
            end
            -- (the shown route in its own order, as it stands now: the leave step is gone from it when it is done)
            -- (with the way across planned together, the step is one of that route: it is laid over the
            -- route as it stands now, as below)
            local before, rebuilt = shown.order, Zones.PlanZone(zone, ctx, shown.order)
            local now = rebuilt.order
            local layer = Zones.SEAM and chardb.seam and chardb.seam.zone == zone and Zones.SeamLayer(view.plan) or nil
            if layer then
                before, now = layer.order, Zones.WithSeam(zone, ctx, rebuilt, chardb.seam).order
            end
            if has(before) and not has(now) then
                if not full then
                    full = true
                    phase(0.1, Engine.SHARE_RANK, "Ranking zones")
                    rank()
                end
                local onto = path.segments[2].map
                if open(onto) then
                    movedOn = { from = zone, to = onto, order = path.segments[2].plan and path.segments[2].plan.order or nil }
                    zone, fresh = onto, nil
                end
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
            -- (so was the zone the path moved on to)
            local handed = full and ((finished ~= nil and finished == state.map) or movedOn ~= nil)
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
        -- (the zone the path moved on to: the order the itinerary planned for it, as it was shown under "Then:")
        if movedOn and movedOn.order then keep = movedOn.order end
        if keep then
            -- stops we stand at, further down: the shown route with them brought forward wins
            local kept = Zones.PlanZone(zone, ctx, keep, nil, frontKeys and { front = frontKeys } or nil)
            if kept.fronted or not Zones.PreferFresh(kept, fresh) then
                plan = kept
            elseif Engine.KEEP_GOAL and shown and shown.zone == zone and not movedOn and kept.order[1] then
                -- The step in hand stays the step in hand: the better route is taken in its own
                -- order with that step put first. Where that cannot be done (it waits for
                -- something, or the new route does not have it) or it is no longer better than
                -- the shown route, the shown route stays until the step is done.
                -- (with the way across planned together on screen, the step in hand is that route's first)
                local goal = kept.order[1]
                if Zones.SEAM and chardb.seam and chardb.seam.zone == zone then
                    goal = Zones.WithSeam(zone, ctx, kept, chardb.seam).order[1] or goal
                end
                if fresh.order[1] ~= goal then
                    local pinned = Zones.PlanZone(zone, ctx, fresh.order, nil, { first = goal })
                    if #pinned.steps > 0 and pinned.order[1] == goal and pinned.score > kept.score then
                        plan = pinned
                    else
                        plan = kept
                    end
                end
            end
        end
        -- The way across the border planned together (chardb.seam) and the quests the itinerary takes
        -- along (chardb.border) go over the chosen route, in that order (Zones.WithSeam, Zones.WithBorder).
        -- The keep rule above compared the routes without them; `base` is the route without them.
        local base = plan
        if Zones.SEAM and chardb.seam and chardb.seam.zone == zone then
            plan = Zones.WithSeam(zone, ctx, plan, chardb.seam, frontKeys)
        end
        if Zones.BORDER and chardb.border and chardb.border.zone == zone then
            plan = Zones.WithBorder(zone, ctx, plan, chardb.border, frontKeys)
        end
        return { ranked = ranked, plan = plan, base = base, fresh = fresh, zone = zone, state = state, full = full, travel = ctx.travel,
            flightStops = Zones.FlightStops(plan, ctx, chardb.skippedNodes),
            offers = offersOf(chains, ctx, nil, plan, best), ended = ended, movedOn = movedOn }
    end, function(ok, result)
        -- The zones and the route are shown now; the itinerary follows in a job of its own.
        -- (a class quest plan has no itinerary: it is followed to its end)
        local more = ok and not result.chain and (result.full or itineraryOwed)
        view.busy = more and true or false
        if not more then view.progress, scope, zoneSpan = nil, nil, nil end
        if not ok then
            setStatus("error", "Planning failed: " .. tostring(result))
            if snap then
                if not snap.auto then ns.Print("Snapshot not taken: planning failed.") end
                snap = nil
            end
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
        local chain = result.chain
        if not chain then
            chardb.zone = result.zone
            -- the shown route's order, for the first plan of the next session (see `keep` above)
            -- (without the quests taken along: chardb.border lays them over it again after a relog)
            chardb.route = #result.plan.steps > 0 and { zone = result.zone, order = (result.base or result.plan).order } or nil
            -- quests taken along from a zone no longer shown (moved on, or another zone): nothing to take along
            if chardb.border and chardb.border.zone ~= result.zone then chardb.border = nil end
            if chardb.seam and chardb.seam.zone ~= result.zone then chardb.seam = nil end
        else
            chardb.border = nil -- (a class quest chain is followed: there is no itinerary)
            chardb.seam = nil
        end
        view.ranked, view.plan, view.zone = result.ranked, result.plan, result.zone
        view.zoneName = chain and chainTitle(result.plan) or mapName(result.zone)
        if chain then
            chardb.chainName = result.plan.chainName
            -- the chain's order, for the first plan of the next session (see the chain above)
            chardb.chainRoute = { chain = chain.id, order = result.plan.order }
            view.chain = chainView(chain, result.plan, result.chainAfter)
        else
            view.chain = nil
        end
        view.chains = result.offers or {}
        view.level, view.here = result.state.level, result.state.map
        view.logCount, view.capacity = #result.state.log, result.state.capacity
        view.groupSize = result.state.groupSize
        view.xpBonus, view.xpBuffs, view.restedPool = result.state.xpBonus, xpBuffs, result.state.restedPool
        plannedRested = result.state.restedPool
        if chain then
            view.moveOn, view.itinerary = { suggest = false }, nil -- the chain is followed, wherever leveling is better
        else
            -- The path moved on to its next zone: until the new itinerary is in, the one before
            -- stands without the zone that was left (so its order of zones is the one kept).
            if result.movedOn then
                local was, segs, xp = view.itinerary, {}, 0
                for i = 2, #(was and was.segments or {}) do
                    segs[#segs + 1] = was.segments[i]
                    xp = xp + (was.segments[i].xp or 0)
                end
                view.itinerary = (segs[1] and segs[1].map == result.zone)
                    and { horizon = was.horizon, xp = xp, rate = xp / was.horizon * 3600, shown = result.zone, here = xp, segments = segs } or nil
                ns.Print("On to %s. What is left in %s stays for later.", mapName(result.movedOn.to), mapName(result.movedOn.from))
                playEvent("moved", { from = result.movedOn.from, to = result.movedOn.to })
                lastMoved = { from = result.movedOn.from, a = Tracker.Active(Game.Now()) }
            end
            -- until the new itinerary is in, the move-on rule uses the one worked out before
            moveOn(result.plan, result.ranked, view.itinerary)
        end
        view.updated = Game.Now()
        travel = result.travel
        view.flightStops = result.flightStops -- unknown flight points close to the route (Zones.FlightStops)
        -- the step log: how long the step that was first really took (see ns.Tracker)
        Tracker.OnPlan(result.plan, { now = view.updated, level = result.state.level, group = result.state.groupSize,
            log = result.state.log, completed = completed })
        view.flightsKnown = next(chardb.knownNodes) ~= nil
        -- No flight path known and the route starts in another zone: trips are walked only for
        -- that. Said once per character (the current step's row says it too).
        if not view.flightsKnown and not chardb.flightHintTold then
            local first = result.plan.steps[1]
            local zone = first and first.loc and (Zones.ZoneAt(first.loc) or first.loc.map)
            if zone and zone ~= result.state.map then
                chardb.flightHintTold = true
                ns.Print("LevelScout does not know your flight paths yet, so trips are planned on foot. Open any flight master's map once (talk to the flight master) and routes will use them.")
            end
        end
        if result.ended then
            chardb.chain, chardb.chainRoute, chardb.chainKind = nil, nil, nil
            chainEnded(result.ended, view.zoneName)
        end
        markOffers()
        announce()
        setStatus("ready", nil)
        local fresh = freshWay
        freshWay = false
        publish(fresh)
        if snap and snap.state == result.state then
            if result.full then
                snap.ranked = true -- the record is saved when the itinerary is in (see startItinerary)
                if not more then saveSnapshot(nil) end -- a class quest chain is shown: no itinerary follows
            else
                pendingFull = true -- the snapshot waits for a full plan: the code below asks for one
            end
        end
        if more then startItinerary(result) end
        -- a plan made at once for the shown route: the zones are ranked next
        if rankAfter then
            rankAfter = false
            if not result.full then pendingFull = true end
        end
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
        if not pending then return end -- (Engine.ReplanNow ran it already)
        if Async.IsRunning("plan") then
            pending = false
            Game.After(Engine.DEBOUNCE, function() Engine.Replan() end)
            return
        end
        run()
    end)
end

-- Stop following the class quest chain: it is offered again on the Class tab, as seen (news
-- again when its next part opens).
local function leaveChain()
    local c = Engine.view.chain
    if c and c.id == chardb.chain and c.sig and c.kind ~= "quest" then
        local rec = chainRecord(c.id)
        rec.seen, rec.told = c.sig, c.sig
    end
    chardb.chain, chardb.chainRoute, chardb.chainKind, Engine.view.chain = nil, nil, nil, nil
end

--- Show a zone (nil: let LevelScout choose). A class quest chain being followed is left.
function Engine.SetZone(map)
    -- the play log: the player chose the zone (and, unless the banner had suggested it, a
    -- snapshot of what was shown instead, taken before anything changes)
    if map ~= chardb.zone then
        local mo = Engine.view.moveOn
        local banner = (mo and mo.suggest and mo.map == map) or nil
        local back = (lastMoved and lastMoved.from == map
            and Tracker.Active(Game.Now()) - lastMoved.a <= Engine.BACK_WITHIN) or nil
        local e = playEvent("zone", { from = chardb.zone, to = map, banner = banner, back = back })
        if not banner then autoSnapshot(string.format("auto: zone %s -> %s by hand", tostring(chardb.zone), tostring(map)), e) end
    end
    if chardb.chain then leaveChain() end
    chardb.zone = map
    chardb.route = nil
    chardb.border = nil
    chardb.seam = nil
    Engine.view.plan = nil
    Engine.Replan(true)
end

--- Follow a class quest chain on offer (view.chains): it becomes the plan shown until it is
--- done. Its quests are no longer skipped.
function Engine.SetChain(id)
    if not chardb then return end
    local offer
    for _, o in ipairs(Engine.view.chains or {}) do if o.id == id then offer = o end end
    if not offer then return end
    local rec = chainRecord(id)
    rec.never, rec.seen, rec.told = nil, offer.sig, offer.sig
    for _, q in ipairs(offer.quests or {}) do chardb.ignored[q] = nil end
    chardb.chain, chardb.chainName, chardb.chainKind, chardb.chainRoute = id, offer.name, "class", nil
    Engine.view.plan = nil
    Engine.Replan()
end

-- What Data.FindQuests and Classes.ChainOf need to know about the character, from the game.
local function findContext()
    local player, pctx = Game.GetPlayer(), Game.GetPlayerContext()
    local log, inLog = {}, {}
    for _, q in ipairs(Game.GetQuestLog()) do log[q.id], inLog[q.id] = q, true end
    local avail = { faction = pctx.faction, raceId = pctx.raceId, class = pctx.class, completed = completed or {}, inLog = inLog }
    return { level = player.level or 1, avail = avail, log = log }
end

Engine.FIND_MAX = 12 -- quests listed for a search

--- Quests the character can accept now whose name matches `text` (typos and case aside),
--- best first: { { id, name, level, minLevel, giver, zone (map id), chain = quests in its chain
--- still to do (1: on its own) }, ... }.
function Engine.FindQuests(text)
    if not (chardb and Data.IsIndexBuilt()) then return {} end
    local fctx = findContext()
    local found = Data.FindQuests(text, { level = fctx.level, faction = fctx.avail.faction, raceId = fctx.avail.raceId,
        class = fctx.avail.class, completed = fctx.avail.completed, inLog = fctx.avail.inLog }, Engine.FIND_MAX)
    local out = {}
    for _, id in ipairs(found) do
        local q = Data.GetQuest(id)
        local chain = Classes.ChainOf(id, fctx)
        local giver = q.starters[1]
        local who = giver and (giver.kind == "npc" and Data.GetNpc(giver.id) or (giver.kind == "object" and Data.GetObject(giver.id))) or nil
        out[#out + 1] = { id = id, name = q.name, level = q.level, minLevel = q.minLevel, giver = who and who.name,
            zone = q.zone ~= 0 and q.zone or nil, chain = chain and #chain.quests or 1,
            chainNames = chain and (function()
                local names = {}
                for _, cid in ipairs(chain.quests) do
                    local cq = Data.GetQuest(cid)
                    names[#names + 1] = cq and ns.Format.QuestName(cq.name, cq.level) or tostring(cid)
                end
                return names
            end)() or nil }
    end
    return out
end

--- Make a quest the plan, with the chain it belongs to (Classes.ChainOf): it is followed like a
--- class quest chain (only its quests) until it is done. The quest is no longer skipped.
function Engine.PickQuest(id)
    if not chardb then return end
    local q = Data.GetQuest(id)
    if not q then return end
    chardb.ignored[id] = nil
    chardb.chain, chardb.chainName, chardb.chainKind, chardb.chainRoute = id, q.name, "quest", nil
    Engine.view.plan, Engine.view.chain = nil, nil
    Engine.Replan()
end

--- Back to the leveling plan from a class quest chain.
function Engine.EndChain()
    if not (chardb and chardb.chain) then return end
    leaveChain()
    Engine.view.plan = nil
    Engine.Replan()
end

--- The Class tab is open: every chain on it has been seen (news again when it moves on).
--- Returns true when one was new. Does not publish: the window calls it while it draws.
function Engine.ChainsSeen()
    if not chardb then return false end
    local any = false
    for _, o in ipairs(Engine.view.chains or {}) do
        if o.new then
            local rec = chainRecord(o.id)
            rec.seen, rec.told, any = o.sig, o.sig, true
        end
    end
    if any then markOffers() end
    return any
end

--- Do not offer this chain again (true), or offer it again (false).
function Engine.ChainNever(id, never)
    if not chardb then return end
    local rec = chainRecord(id)
    rec.never = never and true or nil
    if not never then
        for _, o in ipairs(Engine.view.chains or {}) do
            if o.id == id then rec.seen, rec.told = o.sig, o.sig end -- back among the chains on offer, not as news
        end
    end
    markOffers()
    publish()
end

--- Plan again at once, without the usual wait: the shown route first (its way to the current
--- step taken at once), the zones right after it. For a change the player is looking at
--- now: flight points read off an open flight map.
function Engine.ReplanNow()
    if not started then return end
    Async.Stop("plan")
    pending, rankAfter, freshWay, quickNow = false, true, true, true
    if #Engine.view.ranked == 0 then quickNow = false end -- (nothing ranked yet: the first plan ranks)
    run()
end

--- Plan from scratch: the shown route (and the one saved with the character) and the kept
--- plans are forgotten, so nothing holds the new plan to the old order.
function Engine.ReplanFresh()
    chardb.route = nil
    chardb.border = nil
    chardb.seam = nil
    Engine.view.plan = nil
    Engine.ResetMemory()
    Engine.Replan(true)
end

--- Save a snapshot: what the plan is made from and what is shown for it, with the character
--- (chardb.snapshots, the last Engine.SNAPSHOTS), for tests/replay.lua. What is on screen now is
--- noted first (snap.before); then the zones are ranked and the route and the next hours worked
--- out once more, and the record is saved when that has finished (see takeInput). Returns true,
--- or false and the reason; the outcome is told in chat.
function Engine.Snapshot(note, auto, event)
    if not (started and chardb) then return false, "LevelScout has not started yet" end
    if not Data.usable then return false, Data.status.message or "the data is not usable" end
    if snap then return false, "a snapshot is being taken already" end
    local viewed, before = pcall(Snapshot.View, Engine.view, true)
    snap = { note = note, asked = Game.Now(), before = viewed and before or nil, auto = auto and true or nil, event = event }
    Engine.Replan(true)
    return true
end

--- Leave a quest out of all plans, or bring it back.
function Engine.Ignore(questId, ignore)
    if (chardb.ignored[questId] == true) ~= (ignore and true or false) then -- the play log
        local e = playEvent(ignore and "skip" or "unskip", { q = questId })
        if ignore then autoSnapshot("auto: quest " .. tostring(questId) .. " skipped", e) end
    end
    chardb.ignored[questId] = ignore and true or nil
    Engine.Replan(true)
end

--- Route elite (group) quests, or only list them.
function Engine.SetRouteElite(on)
    chardb.routeElite = on and true or false
    Engine.Replan(true)
end

--- Route escort quests, or only list them (the default). Saved with the character.
function Engine.SetRouteEscort(on)
    chardb.routeEscort = on and true or false
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
function Engine.RoutesEscort() return chardb ~= nil and chardb.routeEscort == true end

--- Leave a flight point out of the route (the player does not want the detour), or put it back.
function Engine.SkipFlightPoint(nodeId, skip)
    chardb.skippedNodes[nodeId] = skip and true or nil
    Engine.Replan()
end

function Engine.IsIgnored(questId) return chardb and chardb.ignored[questId] == true end

local handlers = {}
function handlers.QUEST_ACCEPTED() Engine.Replan() end
-- A quest of the chain being followed left the log: turned in, or dropped. Dropped (the game
-- says it is not done, a moment later), the chain is left and offered again.
function handlers.QUEST_REMOVED(questId)
    local c = Engine.view.chain
    if c and type(questId) == "number" and c.set and c.set[questId] then
        Game.After(2, function()
            if chardb.chain ~= c.id or (completed and completed[questId]) then return end
            if Game.IsQuestCompleted(questId) ~= false then return end -- done, or the client cannot tell
            local q = Data.GetQuest(questId)
            ns.Print("You dropped |cffffd100%s|r: back to the leveling plan.", q and q.name or ("quest " .. questId))
            chardb.chain, chardb.chainRoute, chardb.chainKind, Engine.view.chain = nil, nil, nil, nil
            Engine.view.plan = nil
            Engine.Replan()
        end)
    end
    Engine.Replan()
end
function handlers.QUEST_TURNED_IN(questId)
    -- the play log: a turn-in the route did not have, or had much further down
    local shown = Engine.view.plan
    if type(questId) == "number" and shown and shown.order and not shown.chain then
        local at
        for i, key in ipairs(shown.order) do
            if key == "T:" .. questId then at = i break end
        end
        if not at then
            playEvent("extra", { q = questId })
        elseif at > Play.ORDER_FRONT then
            playEvent("order", { q = questId, i = at })
        end
    end
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
    local sample = Tracker.OnMove(info)
    Play.Tick(Tracker.Active(info.now)) -- the play log: forecasts whose time has passed
    return sample
end
-- XP came in: the play log counts what the session earns.
function handlers.PLAYER_XP_UPDATE(unit)
    if unit ~= nil and unit ~= "player" then return end
    local p = Game.GetPlayer()
    Play.XP(p.level, p.xp, p.xpMax)
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
Engine.TAXI_LOOKS = 200   -- looks at the flight map's points while it is open, at most (a point just
                          -- discovered can be listed a moment late): every TAXI_EVERY seconds until it closes
Engine.TAXI_EVERY = 0.3   -- seconds between them

-- Record the flight points the open flight map shows. Returns true when one is new, false
-- when none is, nil when the game shows none (yet).
local function readTaxi()
    local nodes = Game.GetTaxiNodes()
    if not nodes then return nil end
    local changed = false
    for id in pairs(nodes) do
        if not chardb.knownNodes[id] then chardb.knownNodes[id], changed = true, true end
    end
    Engine.view.flightNote = nil
    return changed
end

-- The flight map opened: its points are read at once and a few times more while it is open,
-- and anything new is planned with at once, so the route (and the flight to take, marked on
-- the map: ns.FlightMap) changes while the map is still open.
local taxiOpen = false
function handlers.TAXIMAP_OPENED()
    taxiOpen = true
    local looks = 0
    local function look()
        if not taxiOpen then return end
        looks = looks + 1
        if readTaxi() then Engine.ReplanNow() end
        if looks < Engine.TAXI_LOOKS then Game.After(Engine.TAXI_EVERY, look) end
    end
    look()
end
function handlers.TAXIMAP_CLOSED()
    taxiOpen = false
    if readTaxi() then Engine.ReplanNow() end -- (a list that came only at the last moment)
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
            Engine.ReplanNow()
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
    chardb.snapshots = type(chardb.snapshots) == "table" and chardb.snapshots or {} -- see Engine.Snapshot
    chardb.snapshotCount = tonumber(chardb.snapshotCount) or #chardb.snapshots
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
    -- quests the itinerary takes along to the next zone (Zones.BORDER): { zone, ids, to = { [id] = map }, before }
    local b = chardb.border
    local bValid = type(b) == "table" and type(b.zone) == "number" and type(b.ids) == "table" and type(b.to) == "table"
        and (b.before == nil or type(b.before) == "string")
    for _, id in ipairs(bValid and b.ids or {}) do
        if type(id) ~= "number" then bValid = false break end
    end
    chardb.border = bValid and b or nil
    -- the way across the border planned together (Zones.SEAM): { zone, to, window, keys, leave, windowB, head, leaveB }
    local sm = chardb.seam
    local function keyList(t)
        if type(t) ~= "table" then return false end
        for _, k in ipairs(t) do if type(k) ~= "string" then return false end end
        return true
    end
    local smValid = type(sm) == "table" and type(sm.zone) == "number" and type(sm.to) == "number"
        and type(sm.leave) == "string" and keyList(sm.window) and #sm.window > 0 and keyList(sm.keys)
        and (sm.windowB == nil or keyList(sm.windowB)) and (sm.head == nil or keyList(sm.head))
        and (sm.leaveB == nil or type(sm.leaveB) == "string")
    chardb.seam = smValid and sm or nil
    chardb.skippedNodes = type(chardb.skippedNodes) == "table" and chardb.skippedNodes or {}
    -- the class quest chain being followed (its lowest quest id), and what was said about each
    chardb.chain = type(chardb.chain) == "number" and chardb.chain or nil
    chardb.chainName = type(chardb.chainName) == "string" and chardb.chainName or nil
    chardb.chainKind = (chardb.chainKind == "quest" or chardb.chainKind == "class") and chardb.chainKind or nil
    chardb.classChains = type(chardb.classChains) == "table" and chardb.classChains or {}
    -- the followed chain's order at logout: { chain, order = { "P:123", ... } }
    local cr = chardb.chainRoute
    local crValid = type(cr) == "table" and type(cr.chain) == "number" and type(cr.order) == "table"
    for _, key in ipairs(crValid and cr.order or {}) do
        if type(key) ~= "string" then crValid = false break end
    end
    chardb.chainRoute = crValid and cr or nil
    chardb.seenBuffs = type(chardb.seenBuffs) == "table" and chardb.seenBuffs or {}
    chardb.mutedBuffs = type(chardb.mutedBuffs) == "table" and chardb.mutedBuffs or {}
    chardb.pace = type(chardb.pace) == "table" and chardb.pace or {}  -- this character's pace
    db.drops = type(db.drops) == "table" and db.drops or {}           -- drop counts: the same for every character
    chardb.steps = type(chardb.steps) == "table" and chardb.steps or {} -- planned against real time per step
    chardb.stepModel = type(chardb.stepModel) == "table" and chardb.stepModel or {} -- fitted on the step log
    Tracker.Start(chardb.pace, db.drops, chardb.steps, chardb.stepModel)
    -- the play log: forecasts against what play brought, and where the player overruled the plan
    chardb.play = Play.Start(chardb.play)
    do
        local p = Game.GetPlayer()
        Play.XP(p.level, p.xp, p.xpMax)
    end
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
