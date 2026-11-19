-- ui/Format.lua: the words and numbers shown for a plan. Pure Lua: no game API.

local _, ns = ...

local Format = {}
ns.Format = Format

local floor = math.floor

--- 950 -> "950", 21400 -> "21.4k", 183000 -> "183k"
function Format.Number(n)
    n = n or 0
    if n < 1000 then return tostring(floor(n + 0.5)) end
    if n < 100000 then return (string.format("%.1fk", n / 1000):gsub("%.0k$", "k")) end
    return string.format("%.0fk", n / 1000)
end

--- 45 -> "under 1 min", 240 -> "4 min", 5400 -> "1 h 30 min"
function Format.Duration(seconds)
    seconds = seconds or 0
    if seconds < 60 then return "under 1 min" end
    local minutes = floor(seconds / 60 + 0.5)
    if minutes < 60 then return minutes .. " min" end
    local h, m = floor(minutes / 60), minutes % 60
    return m == 0 and (h .. " h") or (h .. " h " .. m .. " min")
end

function Format.Distance(yards)
    if not yards then return nil end
    if yards < 30 then return "here" end
    if yards < 1000 then return floor(yards / 10 + 0.5) * 10 .. " yd" end
    return string.format("%.1fk yd", yards / 1000)
end

local VERB = { kill = "Kill", collect = "Collect", use = "Use", buy = "Buy", ["do"] = "Do", run = "Run" }
Format.LABEL = { accept = "ACCEPT", turnin = "TURN IN", kill = "KILL", collect = "COLLECT", use = "USE", buy = "BUY", ["do"] = "DO",
    run = "DUNGEON", flight = "FLIGHT" }

-- "Kobold Candles", "Kobold Candles, Gold Dust Exchange", "Kobold Candles +2 more"
--- "[12] Name": a quest's name with its level in front, as the quest log shows it (no level
--- known, or a level that scales: the name alone).
function Format.QuestName(name, level)
    if level and level > 0 then return string.format("[%d] %s", level, name or "?") end
    return name or "?"
end

-- The step's quests by name; `levels`: each with its level in front (accept and turn-in steps).
local function questNames(step, levels)
    local quests = step.quests or {}
    local function one(q) return levels and Format.QuestName(q.name, q.level) or q.name end
    if #quests > 2 then return one(quests[1]) .. " +" .. (#quests - 1) .. " more" end
    local names = {}
    for _, q in ipairs(quests) do names[#names + 1] = one(q) end
    return table.concat(names, ", ")
end
--- The step's quests by name ("A", "A, B", "A +2 more"); `levels`: each with its level in front.
Format.QuestNames = questNames

-- The different things one stop collects or kills: { "Dirty Knucklebones 2/9", "Recovered Tome 0/5" }.
local function partLines(step)
    local out, seen = {}, {}
    for _, p in ipairs(step.parts or {}) do
        local text = p.label or "?"
        if p.total then text = text .. string.format(" %d/%d", p.have or 0, p.total)
        elseif p.need and p.need > 1 then text = text .. " x" .. p.need end
        if not seen[text] then seen[text] = true; out[#out + 1] = text end
    end
    return out
end

--- True when one stop serves several different things (two quests' items from the same mobs).
function Format.IsShared(step)
    return step.kind == "work" and #partLines(step) > 1
end

--- The headline of a step: what to do. Also the waypoint's title.
function Format.StepTitle(step)
    if step.kind == "accept" and step.fromBag then return "Start: " .. questNames(step, true) end
    if step.kind == "accept" then return "Accept: " .. questNames(step, true) end
    if step.kind == "turnin" then return "Turn in: " .. questNames(step, true) end
    local verb = VERB[step.action] or "Do"
    if step.action == "do" then return questNames(step) end
    if step.action == "run" then return "Run " .. (step.target or "the dungeon") end
    local target = step.target or "?"
    local parts = step.parts or {}
    -- several things from the same mobs: the stop is about the mob
    if Format.IsShared(step) and step.kills and step.from then return "Kill " .. step.from end
    if Format.IsShared(step) then return verb .. " " .. target .. " +" .. (#partLines(step) - 1) .. " more" end
    if #parts == 1 and parts[1].need and parts[1].need > 1 and step.action ~= "buy" then
        return string.format("%s %s x%d", verb, target, parts[1].need)
    end
    return verb .. " " .. target
end
ns.StepTitle = Format.StepTitle
Format.MapName = nil -- set by the window: map id -> name (Format itself knows no names)

--- The second line: who or where, progress, and what it takes. `current`: the row of the step being followed,
--- whose way line (TripText) tells how to get there.
function Format.StepDetail(step, current)
    local bits, lines = {}, nil
    -- the route goes to this step by hearthstone (Planner.HEARTH); the current row's way line says it already
    if step.hearth and not current then bits[#bits + 1] = "|cff8fd0ffhearth to " .. (step.hearth.name or "your inn") .. "|r" end
    if step.kind ~= "work" then
        if step.target then bits[#bits + 1] = step.target end
        if step.guessed then bits[#bits + 1] = "turn-in place is a guess" end
        if step.needLevel and step.kind == "accept" then bits[#bits + 1] = "needs level " .. step.needLevel end
        if step.keep then bits[#bits + 1] = "for the run; the rest is done elsewhere" end
        if step.borderTo then bits[#bits + 1] = "finished in " .. (Format.MapName and Format.MapName(step.borderTo) or "the next zone") end
        if step.ready then bits[#bits + 1] = "|cff59ff59ready to turn in|r" end
    else
        local parts = step.parts or {}
        if Format.IsShared(step) then
            lines = partLines(step) -- one line each, so none is cut off
        else
            if step.from and step.from ~= step.target then bits[#bits + 1] = "from " .. step.from end
            if parts[1] and parts[1].total and (parts[1].have or 0) > 0 then
                bits[#bits + 1] = string.format("%d/%d done", parts[1].have, parts[1].total)
            end
        end
        if step.kills and (step.action == "collect" or lines) then bits[#bits + 1] = "about " .. step.kills .. " kills" end
        if parts[1] and parts[1].guessed then bits[#bits + 1] = "count is a guess" end
    end
    if step.action == "run" then
        local n = #(step.quests or {})
        if step.live and #step.live > 0 then
            -- inside the dungeon: each quest's progress from the quest log, a line each
            lines = {}
            for i, text in ipairs(step.live) do lines[i] = text end
        else
            bits[#bits + 1] = string.format("%d quest%s inside", n, n == 1 and "" or "s")
        end
    end
    if step.group then bits[#bits + 1] = "|cffffcc40group|r" end
    bits[#bits + 1] = Format.Duration((step.travel or 0) + (step.seconds or 0))
    local last = table.concat(bits, "  |cff5f646e·|r  ")
    if lines then
        lines[#lines + 1] = last
        return table.concat(lines, "\n"), #lines
    end
    return last, 1
end

local SEP = "  |cff5f646e·|r  "

-- "fly Lakeshire to Darkshire", "boat Menethil Harbor to Theramore Isle", "take the Freewind Post lift"
-- (a flight master not known yet: "unlock Lakeshire and fly to Darkshire")
local function rideText(leg)
    if leg.kind == "hearth" then return "hearth to " .. (leg.to.name or "your inn") end
    if leg.kind == "fly" and leg.from.unlock then
        return string.format("unlock %s and fly to %s", leg.from.name or "?", leg.to.name or "?")
    end
    if leg.kind == "fly" then return string.format("fly %s to %s", leg.from.name or "?", leg.to.name or "?") end
    if leg.from.name and leg.to.name then
        return string.format("%s %s to %s", (leg.transport or "boat"):lower(), leg.from.name, leg.to.name)
    end
    return "take the " .. (leg.name or "boat")
end

--- The way to the current step in a line (trip: from ns.Guide.Trip), or nil when there is
--- nothing to say: the step is in the zone we are in and no flight or boat is involved.
---   "In Duskwood"                                              another zone, on foot
---   "In Duskwood  ·  fly Lakeshire to Darkshire  ·  4 min"     the time is the whole way from here
---   "fly Sentinel Hill to Moonbrook  ·  3 min"                 a flight inside the zone
function Format.TripText(trip)
    if not trip then return nil end
    local bits, rides = {}, trip.rides or {}
    if trip.zone then bits[#bits + 1] = "In " .. trip.zone end
    for i, leg in ipairs(rides) do bits[#bits + 1] = (i > 1 and "then " or "") .. rideText(leg) end
    if #bits > 0 and #rides > 0 and trip.seconds then bits[#bits + 1] = Format.Duration(trip.seconds) end
    -- the route has the hearthstone here but it is not ready (Planner.HEARTH)
    if trip.stoneWait then bits[#bits + 1] = "hearthstone ready in " .. Format.Duration(trip.stoneWait) end
    if #bits == 0 then return nil end
    return table.concat(bits, SEP)
end

--- The waypoint's title while it points at where the way starts:
---   "Flight master: Lakeshire, fly to Darkshire", "Boat: Menethil Harbor, ride to Theramore Isle", "Hearth to Lakeshire"
function Format.TripTitle(trip)
    local leg = trip and trip.first
    if not leg then return nil end
    if leg.kind == "hearth" then return "Hearth to " .. (leg.to.name or "your inn") end
    if leg.kind == "fly" then
        return string.format(leg.from.unlock and "New flight master: %s, fly to %s" or "Flight master: %s, fly to %s",
            leg.from.name or "?", leg.to.name or "?")
    end
    if leg.from.name and leg.to.name then
        return string.format("%s: %s, ride to %s", leg.transport or "Boat", leg.from.name, leg.to.name)
    end
    return leg.name or "Boat"
end

--- The legs of the way with their times, for the tooltip: { { text, seconds }, ... }, or nil
--- when the way is a plain walk.
---   "Walk to the flight master in Lakeshire (Redridge Mountains)", "Fly Lakeshire to Darkshire",
---   "Walk to the boat in Menethil Harbor", "Boat Menethil Harbor to Theramore Isle", "Walk to the step"
function Format.TripLegs(trip)
    if not trip or #(trip.rides or {}) == 0 then return nil end
    local out = {}
    for i, leg in ipairs(trip.legs) do
        local text
        if leg.kind == "walk" then
            local nextLeg = trip.legs[i + 1]
            if leg.seconds >= 1 then
                if nextLeg and nextLeg.kind == "fly" then
                    text = (leg.to.unlock and "Walk to the new flight master in " or "Walk to the flight master in ") .. (leg.to.name or "?")
                elseif nextLeg then
                    text = leg.to.name and string.format("Walk to the %s in %s", (nextLeg.transport or "boat"):lower(), leg.to.name)
                        or ("Walk to the " .. (nextLeg.name or "boat"))
                else
                    text = "Walk to the step"
                end
                if nextLeg and leg.to.zone and leg.to.zone ~= leg.to.name then text = text .. " (" .. leg.to.zone .. ")" end
            end
        else
            text = rideText(leg):gsub("^%l", string.upper):gsub("^Take the ", "")
        end
        if text then out[#out + 1] = { text = text, seconds = leg.seconds } end
    end
    return out
end

--- One line for a whole plan: "12 steps  ·  48 min".
function Format.PlanSummary(plan)
    local n = #plan.steps
    if n == 0 then return "Nothing to do here right now" end
    return string.format("%d step%s  |cff5f646e·|r  %s  |cff5f646e·|r  %s XP", n, n == 1 and "" or "s",
        Format.Duration(plan.seconds), Format.Number(plan.xp))
end

--- "+5% (Well-Rested 5%)" for the engine's view.
function Format.Bonus(view)
    local parts = {}
    for _, b in ipairs(view.xpBuffs or {}) do parts[#parts + 1] = string.format("%s %d%%", b.name, b.bonus * 100 + 0.5) end
    return string.format("+%d%%", (view.xpBonus or 0) * 100 + 0.5) .. (#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "")
end
