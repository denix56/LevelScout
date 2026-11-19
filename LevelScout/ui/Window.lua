-- ui/Window.lua: the LevelScout window. One movable panel with four tabs:
--   Route   the current step and what follows
--   Zones   where leveling is best right now
--   Quests  what the route leaves out, and why; a search box finds any quest to accept by
--           name and makes it (with its chain) the plan
--   Class   class quest chains to pick (the title glows while one is new); only while there
--           is something on it
-- It draws from ns.Engine.view only. It uses the game's own look: the tooltip border and
-- background, the quest "!" and "?" icons, the quest-log highlight, gold titles. Every piece
-- of game art is optional: without it the window falls back to plain colours.

local _, ns = ...
local Engine, Format, Guide, Game = ns.Engine, ns.Format, ns.Guide, ns.Game

local UI = {}
ns.UI = UI

local DEFAULT_W, MIN_W, MAX_W = 330, 260, 640
local WIDTH = DEFAULT_W -- the content width; follows settings.width once the window is built
local PAD = 10
local HEADER_H, SUMMARY_H, BANNER_H, TABS_H, FOOTER_H = 30, 40, 30, 24, 20
local SEARCH_H = 28 -- the Quests tab's search box
UI.SEARCH_DELAY = 0.15 -- seconds after the last key before the search runs
local PROGRESS_H = 3 -- the bar shown while a plan is being made
local ROW_H, ROW_CURRENT_H, SECTION_H = 36, 46, 22
local LINE_H = 13 -- each extra line of detail on a row
local UNDO_SECONDS = 120 -- how long the Undo row stays after skipping a quest
local SIZES = { { "Compact", 4 }, { "Normal", 7 }, { "Tall", 12 } }
local MIN_LIST_H, MAX_LIST_H = 46 + 36, 900 -- dragging the corner: from two rows up
local SCALES = { 0.9, 1.0, 1.15, 1.3 }

local INSET = 6 -- room for the border
local C = {
    bg = { 0, 0, 0, 0.88 }, line = { 1, 1, 1, 0.10 }, border = { 0.6, 0.6, 0.6, 1 },
    accent = { 1.00, 0.82, 0.00 },                       -- the game's gold
    text = { 1, 1, 1 }, dim = { 0.78, 0.78, 0.78 }, faint = { 0.5, 0.5, 0.5 },
    good = { 0.35, 1.00, 0.35 }, warn = { 1.00, 0.50, 0.25 }, bad = { 1.00, 0.13, 0.13 },
    -- a step in another zone: a pale mint, away from the quest-difficulty greens and oranges
    place = { 0.60, 0.95, 0.80 },
    hover = { 1, 1, 1, 0.06 }, current = { 1.00, 0.82, 0.00, 0.10 },
}
local BACKDROP = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } }
-- What a row is about, as the game shows it: "!" to accept, "?" to turn in, the cursors for the rest.
local ICON = {
    accept = "Interface\\GossipFrame\\AvailableQuestIcon", turnin = "Interface\\GossipFrame\\ActiveQuestIcon",
    kill = "Interface\\CURSOR\\Attack", collect = "Interface\\CURSOR\\Pickup", use = "Interface\\CURSOR\\Interact",
    buy = "Interface\\CURSOR\\Buy", ["do"] = "Interface\\CURSOR\\Interact", run = "Interface\\CURSOR\\Attack",
    flight = "Interface\\TaxiFrame\\UI-Taxi-Icon-Green",
    tip = "Interface\\GossipFrame\\DailyQuestIcon", shown = "Interface\\Buttons\\UI-CheckBox-Check",
}
local HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"
local DUNGEON_ICON = "|TInterface\\Minimap\\Dungeon:16:16:0:0|t " -- drawn inside the text, before a dungeon's name
local BAR = "Interface\\TargetingFrame\\UI-StatusBar"

local root, rows, state = nil, {}, { tab = "route", scroll = 0, models = {} }
UI.rows, UI.state = rows, state -- read by tests
local settings -- LevelScoutDB.window

---------------------------------------------------------------------------------------------
-- Small building blocks
---------------------------------------------------------------------------------------------

local function tex(parent, layer, color)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    return t
end

-- A texture from the game's own art, tinted.
local function art(parent, layer, file, color, blend)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetTexture(file)
    if blend then t:SetBlendMode(blend) end
    if color then t:SetVertexColor(color[1], color[2], color[3], color[4] or 1) end
    return t
end

-- The tooltip-style frame the game uses for its own panels.
local function framed(kind, name, parent)
    local template = rawget(_G, "BackdropTemplateMixin") and "BackdropTemplate" or nil
    local f = CreateFrame(kind, name, parent, template)
    if f.SetBackdrop then
        f:SetBackdrop(BACKDROP)
        f:SetBackdropColor(C.bg[1], C.bg[2], C.bg[3], C.bg[4])
        f:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1)
    else
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], C.bg[4])
        bg:SetAllPoints()
    end
    return f
end

local function text(parent, font, color, justify)
    local f = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    f:SetTextColor(color[1], color[2], color[3], color[4] or 1)
    f:SetJustifyH(justify or "LEFT")
    f:SetWordWrap(false)
    return f
end

local function hex(c) return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255) end

local function tooltip(owner, build)
    owner:SetScript("OnEnter", function(self)
        if self.hover then self.hover:Show() end
        local lines = build and build(self)
        if not lines or #lines == 0 or not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        for i = 1, #lines do
            local l = lines[i]
            local c = l.color or (i == 1 and C.text or C.dim)
            if not l[1] then
                -- an optional line that does not apply
            elseif l.right then
                GameTooltip:AddDoubleLine(l[1], l.right, c[1], c[2], c[3], C.text[1], C.text[2], C.text[3])
            else
                GameTooltip:AddLine(l[1], c[1], c[2], c[3], true)
            end
        end
        GameTooltip:Show()
    end)
    owner:SetScript("OnLeave", function(self)
        if self.hover then self.hover:Hide() end
        if GameTooltip then GameTooltip:Hide() end
    end)
end

local function button(parent, w, h, onClick, tip)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.hover = art(b, "BACKGROUND", HIGHLIGHT, { 1, 1, 1, 0.6 }, "ADD")
    b.hover:SetAllPoints()
    b.hover:Hide()
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(self, mouse) onClick(self, mouse) end)
    tooltip(b, tip and function() return { { tip } } end or nil)
    return b
end

---------------------------------------------------------------------------------------------
-- Row models: each tab turns the view into a list of rows; one renderer draws any of them.
-- row = { h, section, pill (what kind of row), icon or rank, title, detail, right, rightSub, dim, current,
--         bar (0..1), onClick(mouse), tip() -> lines }
---------------------------------------------------------------------------------------------

-- The way to the current step in words (Format.TripText). While LevelScout knows none of the
-- player's flight paths (none seen on a flight master's map yet), a step in another zone is
-- reached on foot only for that reason: the line says so.
local function onFootUnknown(way)
    return way ~= nil and way.zone ~= nil and #(way.rides or {}) == 0 and not Engine.view.flightsKnown
end
local function wayText()
    local way = Guide.Trip()
    local text = Format.TripText(way)
    if text and onFootUnknown(way) then
        text = text .. "  |cff5f646e·|r  " .. hex(C.warn) .. "on foot: flight paths not known yet|r"
    end
    return text
end

local function stepTip(step, index)
    return function()
        local lines = { { Format.StepTitle(step) } }
        for _, q in ipairs(step.quests or {}) do
            lines[#lines + 1] = { q.name, right = q.level and q.level > 0 and ("level " .. q.level) or nil }
        end
        for _, p in ipairs(step.parts or {}) do
            local what = p.label or "?"
            if p.total then what = what .. string.format("  %d/%d", p.have or 0, p.total) end
            if p.rate then what = what .. string.format("  (drops %d%%)", p.rate * 100 + 0.5) end
            if p.guessed then what = what .. "  (count is a guess)" end
            lines[#lines + 1] = { what }
        end
        lines[#lines + 1] = { "Travel", right = Format.Duration(step.travel) }
        if step.hearth then -- (Planner.HEARTH)
            lines[#lines + 1] = { "  by hearthstone to " .. (step.hearth.name or "your inn"), right = "saves " .. Format.Duration(step.hearth.saved), color = C.dim }
        end
        -- the current step: the way from where we stand, leg by leg, when it is more than a walk
        local trip = index == 1 and Guide.Trip() or nil
        if onFootUnknown(trip) then
            lines[#lines + 1] = { "Planned on foot: LevelScout does not know your flight paths yet. Open any flight master's map once (talk to the flight master) and the route will use them.", color = C.warn }
        end
        local legs = Format.TripLegs(trip)
        if legs then
            lines[#lines + 1] = { "From where you are", right = Format.Duration(trip.seconds) }
            for _, leg in ipairs(legs) do
                lines[#lines + 1] = { "  " .. leg.text, right = Format.Duration(leg.seconds), color = C.dim }
            end
        end
        if step.kind == "work" then lines[#lines + 1] = { "Work", right = Format.Duration(step.seconds) } end
        if (step.xp or 0) > 0 then
            local xp = Format.Number(step.xp) .. " XP"
            if step.kind == "turnin" and step.xpSource == "estimate" then
                xp = xp .. (step.xpLow and string.format(" (estimate, usually %s-%s)", Format.Number(step.xpLow), Format.Number(step.xpHigh)) or " (estimate)")
            end
            lines[#lines + 1] = { step.kind == "work" and "XP from kills" or "Quest XP", right = xp }
        end
        if step.group then lines[#lines + 1] = { "Group quest (elite).", color = C.warn } end
        if step.restedXP then lines[#lines + 1] = { "of which rested bonus", right = Format.Number(step.restedXP) .. " XP" } end
        if step.tail then lines[#lines + 1] = { "Low value: the route slows down from here.", color = C.warn } end
        local skip = #(step.quests or {}) > 1 and "Right-click: skip these quests" or "Right-click: skip this quest"
        lines[#lines + 1] = { index == 1 and skip or ("Click: point the arrow here.  " .. skip), color = C.faint }
        return lines
    end
end

local function skipQuest(step)
    local quests = step.quests or {}
    if #quests == 0 then return end
    local names = {}
    for _, q in ipairs(quests) do
        Engine.Ignore(q.id, true)
        names[#names + 1] = q.name
    end
    -- a slip of the mouse should be easy to take back: an Undo row stays on top for a while
    state.skipped = { quests = quests, names = table.concat(names, ", "), at = Game.Now() }
    ns.Print("Skipped %s. Click Undo in the window, or bring it back under Quests.", #quests == 1 and quests[1].name or (#quests .. " quests"))
end

-- Several quests accepted (or turned in) in a row at the same NPC are one row: one stop, one
-- thing to do. Returns the steps to show, each with `first` (its index in the plan).
local function grouped(steps)
    local out = {}
    for i, step in ipairs(steps) do
        local last = out[#out]
        local a, b = last and last.loc, step.loc
        if last and step.kind ~= "work" and last.kind == step.kind and last.target == step.target and a and b
            and a.map == b.map and math.abs(a.mx - b.mx) < 0.6 and math.abs(a.my - b.my) < 0.6 then
            last.seconds = last.seconds + step.travel + step.seconds
            last.xp = last.xp + step.xp
            last.levelUp = step.levelUp or last.levelUp
            last.needLevel = step.needLevel or last.needLevel
            last.borderTo = last.borderTo or step.borderTo
            for _, q in ipairs(step.quests) do last.quests[#last.quests + 1] = q end
        else
            local copy = {}
            for k, v in pairs(step) do copy[k] = v end
            copy.quests = {}
            for _, q in ipairs(step.quests or {}) do copy.quests[#copy.quests + 1] = q end
            copy.first = i
            out[#out + 1] = copy
        end
    end
    return out
end

local tripLines -- (defined below: how many lines a way's text takes on a row)

-- Is this the step the arrow was pointed at by hand (a click on its row)? That row is then
-- the highlighted one, not the route's first step: the highlight is where the arrow goes.
local function pointedAt(title, loc)
    local p = Guide.Pointed()
    local at = p and p.step and p.step.loc
    -- (the same title on the same map: a giver's spot can move a little from one plan to the next)
    return p ~= nil and at ~= nil and loc ~= nil and p.title == title and at.map == loc.map
end

local function zoneName(map)
    return (ns.Zones and ns.Zones.Name(map)) or Game.MapName(map) or ("Map " .. tostring(map))
end
Format.MapName = zoneName

-- A step outside the zone being planned (a giver in a city or the next zone, a turn-in far
-- away) names its zone in a pale mint (C.place), so it is seen before setting off. `zone` is
-- that zone's name, or nil for a step in the planned zone. On the current row the way there
-- already starts with "In <zone>": that part is coloured.
local function outsideTag(zone) return hex(C.place) .. "In " .. zone .. "|r  |cff5f646e·|r  " end
local function colourTrip(trip, zone)
    local lead = zone and ("In " .. zone)
    if lead and trip:sub(1, #lead) == lead then return hex(C.place) .. lead .. "|r" .. trip:sub(#lead + 1) end
    return trip
end

-- `text` in front of a row's detail: on its last line, where the time is (a stop shared by
-- several items lists them one per line above that).
local function prefixed(detail, text)
    local items, last = detail:match("^(.*\n)([^\n]*)$")
    return items and (items .. text .. last) or (text .. detail)
end

-- How many lines the way to the current step takes on its row. The row is drawn with a fixed
-- number of lines, so a long line ("In Feralas  ·  fly Nijel's Point to Feathermoon
-- Stronghold  ·  12 min") gets the room it wraps into. The width of a character is an
-- estimate for the small font, on the generous side: a line too many is a little air, a line
-- too few would cut the step's own detail off.
local TRIP_CHAR_W = 5.6
tripLines = function(text)
    local plain = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local width = WIDTH - 2 * PAD - 24 - 58 -- the current row's detail: beside the icon and the Skip button
    return math.max(1, math.ceil(#plain * TRIP_CHAR_W / math.max(width, 60)))
end

-- The height of a heading row: one line, or as many as a long heading ("Then: Swamp of
-- Sorrows  (hearth to Stormwind City, 11 min away, about 45 min there)") wraps into at the
-- window's width, so it never runs past the window's edge.
local function sectionH(text)
    local plain = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local lines = math.max(1, math.ceil(#plain * TRIP_CHAR_W / math.max(WIDTH - 2 * PAD, 60)))
    return SECTION_H + (lines - 1) * LINE_H
end

---------------------------------------------------------------------------------------------
-- Class quest chains (Engine.view.chains: on offer; Engine.view.chain: the one followed)
---------------------------------------------------------------------------------------------

-- Is a chain on offer news (not seen on the Class tab yet)?
local function anyNew(view)
    for _, o in ipairs(view.chains or {}) do
        if o.new then return true end
    end
    return false
end

local function plural(n, word) return string.format("%d %s%s", n, word, n == 1 and "" or "s") end

-- "3 quests left · 30 min · 2,400 XP" for the chain followed.
local function chainSummary(chain, plan)
    if not plan or #plan.steps == 0 then return "" end
    return string.format("%s left  |cff5f646e·|r  %s  |cff5f646e·|r  %s XP", plural(chain.left or 0, "quest"),
        Format.Duration(plan.seconds), Format.Number(plan.xp))
end

-- The tooltip of a chain on offer: where it starts, what it takes and pays, what it costs
-- against leveling, what to watch out for; then the clicks (`clicks`, a list of lines).
local function chainTip(o, clicks)
    return function()
        local f = o.facts or {}
        local lines = { { "Class quest: " .. Format.QuestName(o.name, o.level) } }
        if o.start then lines[#lines + 1] = { "Starts at", right = o.start .. (o.startZone and (", " .. o.startZone) or "") } end
        if (o.trip or 0) >= 60 then lines[#lines + 1] = { "Getting there", right = Format.Duration(o.trip) } end
        lines[#lines + 1] = { "Steps", right = string.format("%s, about %s", plural(o.count or 0, "quest"), Format.Duration(o.seconds)) }
        if o.zones and #o.zones > 0 then lines[#lines + 1] = { "Zones", right = table.concat(o.zones, ", ") } end
        lines[#lines + 1] = { "Pays", right = Format.Number(o.xp) .. " XP" }
        if o.lost then
            lines[#lines + 1] = { "Against leveling", right = o.lost >= 60 and ("about " .. Format.Duration(o.lost) .. " lost") or "pays as well" }
        end
        if o.inLog then lines[#lines + 1] = { "Part of it is in your quest log already." } end
        if f.eliteStep then
            lines[#lines + 1] = { string.format("Step %d is a group quest (elite): %s.", f.eliteStep, f.eliteName or "?"), color = C.warn }
        end
        if f.groupName then lines[#lines + 1] = { f.groupName .. " needs a group: the plan stops before it.", color = C.warn } end
        if f.escortName then lines[#lines + 1] = { f.escortName .. " is an escort quest: the plan stops before it.", color = C.warn } end
        if f.laterLevel then lines[#lines + 1] = { string.format("The rest of the chain needs level %d.", f.laterLevel), color = C.warn } end
        for _, l in ipairs(clicks or {}) do lines[#lines + 1] = { l, color = C.faint } end
        return lines
    end
end

-- The zones the itinerary goes to after the shown one: for each a heading and the first steps
-- of its route there (as planned from where the zone before is left), dimmed: what comes next
-- is on screen before the zone in hand runs out. `from` is where the shown zone is left.
UI.AHEAD_STEPS = 20 -- rows per zone
local function onwardRows(it, out, from)
    for n = 2, #it.segments do
        local seg = it.segments[n]
        local steps = seg.plan and seg.plan.steps or {}
        local stone = steps[1] and steps[1].hearth -- (Planner.HEARTH: the way there is the stone)
        local heading = string.format("Then: %s  %s(%s%sabout %s there)|r", seg.name or "the next zone", hex(C.faint),
            stone and ("hearth to " .. (stone.name or "your inn") .. ", ") or "",
            (seg.travel or 0) > 60 and (Format.Duration(seg.travel) .. " away, ") or "", Format.Duration(seg.seconds))
        out[#out + 1] = { section = heading, h = sectionH(heading) }
        local upto = math.min(seg.leave or #steps, #steps)
        local shown = 0
        for _, step in ipairs(grouped(steps)) do
            if step.first > upto or shown >= UI.AHEAD_STEPS then break end
            shown = shown + 1
            local detail, lines = Format.StepDetail(step)
            if from and step.loc and from.map and step.loc.map and from.map ~= step.loc.map then
                detail = prefixed(detail, "In " .. zoneName(step.loc.map) .. "  |cff5f646e·|r  ")
            end
            from = step.loc or from
            out[#out + 1] = {
                h = ROW_H + (lines - 1) * LINE_H, lines = lines, dim = true, ahead = step,
                pill = Format.LABEL[step.action] or "DO", icon = ICON[step.action] or ICON["do"],
                title = Format.StepTitle(step):gsub("^Accept: ", ""):gsub("^Turn in: ", ""),
                detail = detail,
                right = (step.xp or 0) > 0 and ("+" .. Format.Number(step.xp)) or nil,
                tip = stepTip(step, shown + 1),
                onClick = function(mouse)
                    if mouse == "RightButton" then skipQuest(step)
                    elseif not step.fromBag then Guide.Show(step, Format.StepTitle(step)) end
                end,
            }
        end
        local last = steps[upto]
        from = last and last.loc or from
    end
end

local function routeRows(view)
    local out = {}
    local plan = view.plan
    if not plan then return out end
    local undo = state.skipped
    if undo and Game.Now() - undo.at > UNDO_SECONDS then state.skipped, undo = nil, nil end
    if undo then
        out[#out + 1] = { h = ROW_H, pill = "UNDO", icon = ICON.tip, title = "Skipped: " .. undo.names,
            detail = hex(C.accent) .. "Click to undo|r",
            tip = function() return { { "Skipped by you" }, { undo.names }, { "Click: put it back in the route", color = C.faint } } end,
            onClick = function()
                for _, q in ipairs(undo.quests) do Engine.Ignore(q.id, false) end
                state.skipped = nil
            end }
    end
    if #plan.steps == 0 then return out end
    -- Where the itinerary leaves this zone for the next one.
    -- (`onward`: it goes on from this zone. A leave step that is not in the route any more:
    -- the next zone follows the route's end.)
    local it, leaveAt = view.itinerary, nil
    local onward = it and it.segments[1] and it.segments[1].map == view.zone and it.segments[2] ~= nil
    if onward and it.segments[1].leaveKey then
        for i, key in ipairs(plan.order or {}) do
            if key == it.segments[1].leaveKey then leaveAt = i end
        end
    end
    local tailShown, left, guided = false, false, nil
    local groups = grouped(plan.steps)
    -- Flight points to unlock on the way (view.flightStops): a row each, where the route passes
    -- closest. One before the first step is where the waypoint goes (see the Engine's publish):
    -- it is the highlighted row then, and no step is "the current one".
    local stops, nextStop = view.flightStops or {}, 1
    local flightFirst = stops[1] ~= nil and stops[1].at == 1
    if flightFirst then guided = -1 end
    local function flightRows(upTo)
        while stops[nextStop] and stops[nextStop].at <= upTo do
            local stop = stops[nextStop]
            local title = "New flight point: " .. stop.name
            local followed = flightFirst and nextStop == 1
            local cur = (followed and Guide.Pointed() == nil) or pointedAt(title, stop.loc)
            local detail, lines = "Talk to the flight master  |cff5f646e·|r  " .. Format.Duration(stop.detour) .. " out of the way", 1
            local way = followed and Format.TripText(Guide.Trip()) or nil
            if way then detail, lines = way .. "\n" .. detail, lines + tripLines(way) end
            out[#out + 1] = {
                h = (cur and ROW_CURRENT_H or ROW_H) + (lines - 1) * LINE_H, lines = lines,
                current = cur or nil, pill = Format.LABEL.flight, icon = ICON.flight,
                title = "Flight point: " .. stop.name, detail = detail,
                tip = function()
                    return { { "Flight point: " .. stop.name }, { "You do not have this flight point yet, and the route passes close to it." },
                        { "Detour", right = Format.Duration(stop.detour) },
                        { "Click: point the arrow at it", color = C.faint }, { "Right-click: leave it out", color = C.faint } }
                end,
                onClick = function(mouse)
                    if mouse == "RightButton" then Engine.SkipFlightPoint(stop.id, true)
                    else Guide.Show({ loc = stop.loc }, title) end
                end,
            }
            nextStop = nextStop + 1
        end
    end
    for i, step in ipairs(groups) do
        flightRows(step.first)
        if step.tail and not tailShown and i > 1 then
            tailShown = true
            out[#out + 1] = { section = "Low value from here", h = SECTION_H, warn = true }
        end
        local detail, lines = Format.StepDetail(step, not guided and not step.fromBag) -- (the current row's way line has the hearthstone)
        local base, trip = detail, nil
        local here = step.loc
        -- (the zone the step is in, not the map its spots were recorded on: a camp can come
        -- from spots on the continent map)
        local prefer = view.zone and { view.zone, view.here } or { view.here }
        local hereZone = here and (ns.Zones.ZoneAt(here, prefer) or here.map)
        local outside = (view.zone or 0) > 0 and hereZone and hereZone ~= view.zone and zoneName(hereZone) or nil
        -- the step the waypoint follows: the first one, unless that is a quest started from an
        -- item in the bags (nothing to walk to), then the one after it
        if not guided and not step.fromBag then guided = i end
        if guided == i then
            -- the current step: the way from where we stand, on a line of its own (its zone
            -- when that is not the one we are in, the flight or boat to take; see UI.Tick)
            trip = wayText()
            if trip then
                detail, lines = colourTrip(trip, outside) .. "\n" .. detail, lines + tripLines(trip)
                if outside and trip:sub(1, 3) ~= "In " then base = prefixed(base, outsideTag(outside)); detail = colourTrip(trip, outside) .. "\n" .. base end
            elseif outside then
                detail = prefixed(detail, outsideTag(outside)) -- (standing in that zone: no way to tell, the zone still is)
                base = detail
            end
        else
            -- later steps: a step outside the planned zone always names it, highlighted; inside
            -- it, the zone is named where it is not the zone of the step before (coming back)
            local before = groups[i - 1] and groups[i - 1].loc
            local beforeZone = before and (ns.Zones.ZoneAt(before, prefer) or before.map)
            if outside then
                detail = prefixed(detail, outsideTag(outside))
            elseif beforeZone and hereZone and beforeZone ~= hereZone then
                detail = prefixed(detail, "In " .. zoneName(hereZone) .. "  |cff5f646e·|r  ")
            end
        end
        -- highlighted: the first step, unless the arrow was pointed elsewhere by hand (then the
        -- row it was pointed at)
        local highlighted = (i == 1 and Guide.Pointed() == nil and not flightFirst) or (not step.fromBag and pointedAt(Format.StepTitle(step), step.loc))
        out[#out + 1] = {
            h = ((i == 1 or highlighted) and ROW_CURRENT_H or ROW_H) + (lines - 1) * LINE_H, lines = lines,
            base = base, trip = trip, outside = outside,
            current = highlighted, dim = (step.tail or left) and i > 1, step = step,
            pill = Format.LABEL[step.action] or "DO", icon = ICON[step.action] or ICON["do"],
            title = Format.StepTitle(step):gsub("^Accept: ", ""):gsub("^Turn in: ", ""),
            detail = detail,
            right = (step.xp or 0) > 0 and ("+" .. Format.Number(step.xp)) or nil,
            tip = stepTip(step, guided == i and 1 or i + 1), guided = guided == i or nil,
            onClick = function(mouse)
                if mouse == "RightButton" then skipQuest(step)
                elseif not step.fromBag then Guide.Show(step, Format.StepTitle(step)) end -- nothing to walk to
            end,
        }
        -- the route levels us up here: what follows is planned at the new level
        if step.levelUp then
            out[#out + 1] = { section = string.format("Level %d from here", step.levelUp), h = SECTION_H }
        end
        -- the itinerary moves on after this step: the next zones' first steps, then what is
        -- left for later here
        if leaveAt and not left and leaveAt >= step.first and (not groups[i + 1] or groups[i + 1].first > leaveAt) then
            left, tailShown = true, true
            onwardRows(it, out, step.loc)
            if groups[i + 1] then out[#out + 1] = { section = "Left for later here", h = SECTION_H } end
        end
    end
    flightRows(math.huge)
    if onward and not left then onwardRows(it, out, groups[#groups] and groups[#groups].loc) end
    -- a class quest plan: what is left of the chain for later, and where leveling goes on
    local chain = view.chain
    if chain then
        if chain.laterLevel then
            out[#out + 1] = { section = string.format("Rest of the chain at level %d", chain.laterLevel), h = SECTION_H, warn = true }
        end
        local heading = string.format("%sThen: back to leveling%s|r", hex(C.faint),
            chain.afterName and (" in " .. chain.afterName) or "")
        out[#out + 1] = { section = heading, h = sectionH(heading) }
    end
    return out
end

local function zoneRows(view)
    local out = {}
    -- The zone we are working in stays on top: where we stand changes every other zone's
    -- trip from minute to minute, and the list should not reshuffle around the zone in hand.
    -- The others follow, best first, each with what leaving now would gain or lose.
    local ranked = {}
    for _, z in ipairs(view.ranked or {}) do if z.map == view.zone then ranked[#ranked + 1] = z end end
    for _, z in ipairs(view.ranked or {}) do if z.map ~= view.zone then ranked[#ranked + 1] = z end end
    -- Flight paths: say so while none are known, or when a new one still has to be read.
    local note = view.flightNote or (not view.flightsKnown and #ranked > 0
        and "Talk to any flight master once so trips can use flight paths.") or nil
    if note then
        out[#out + 1] = { h = ROW_H, pill = "TIP", icon = ICON.tip,
            title = view.flightNote and "New flight point" or "Flight paths unknown", detail = note,
            tip = function()
                return { { "Flight paths" }, { "The game only tells addons which flight points you know while a flight master's map is open. "
                    .. "Until then every trip is planned on foot, which makes far zones look worse than they are." },
                    { "A newly discovered flight point is recorded on the spot when you are standing at its flight master." } }
            end }
    end
    -- The next hours across zones, when that is more than "stay where you are".
    local it = view.itinerary
    if it and (#it.segments > 1 or it.segments[1].map ~= view.zone) then
        local parts = {}
        for i, seg in ipairs(it.segments) do
            parts[i] = string.format("%s %s%s|r", seg.name or ("Map " .. seg.map), hex(C.faint), Format.Duration(seg.seconds))
        end
        local hours = it.horizon / 3600
        local span = hours == math.floor(hours) and string.format("%d hours", hours) or Format.Duration(it.horizon)
        out[#out + 1] = { section = "Next " .. span, h = SECTION_H }
        out[#out + 1] = {
            h = ROW_H, pill = "PLAN", icon = ICON.tip, itinerary = true,
            title = table.concat(parts, "  >  "),
            detail = Format.Number(it.xp) .. " XP",
            right = Format.Number(it.pathRate or it.rate), rightSub = "XP/h",
            tip = function()
                local lines = { { "The next " .. span }, { "The order of zones that earns most in that time: each zone's route is followed up to a turn-in, then you travel on." } }
                for i, seg in ipairs(it.segments) do
                    lines[#lines + 1] = { string.format("%d. %s", i, seg.name or ("Map " .. seg.map)),
                        right = string.format("%s trip, %s there, %s XP", Format.Duration(seg.travel), Format.Duration(seg.seconds), Format.Number(seg.xp)) }
                    if (seg.carried or 0) > 0 then
                        lines[#lines + 1] = { string.format("    %d quest%s brought along and turned in there", seg.carried, seg.carried == 1 and "" or "s"),
                            right = Format.Number(seg.carriedXP or 0) .. " XP", color = C.faint }
                    end
                end
                if it.border then
                    local n = #it.border.ids
                    lines[#lines + 1] = { string.format("%d quest%s accepted in %s and finished later", n, n == 1 and "" or "s",
                        it.segments[1].name or "the first zone"), right = "+" .. Format.Number(it.border.gain or 0) .. " XP", color = C.faint }
                end
                if it.seam then
                    lines[#lines + 1] = { string.format("The way from %s into %s planned together", it.segments[1].name or "the first zone",
                        it.segments[2] and it.segments[2].name or "the next zone"), right = "+" .. Format.Number(it.seam.gain or 0) .. " XP", color = C.faint }
                end
                if it.stay then lines[#lines + 1] = { "Best single zone", right = Format.Number(it.stay) .. " XP" } end
                -- (the list gives the shown zone's rate alone when going on earns less per hour)
                local own = it.starts and it.starts[view.zone]
                if own and not own.path then
                    lines[#lines + 1] = { (view.zoneName or "The zone shown") .. " alone, while it lasts",
                        right = Format.Number(own.rate) .. " XP/h" }
                end
                if it.here and it.segments[1].map ~= view.zone then
                    lines[#lines + 1] = { "Starting with " .. (view.zoneName or "the zone shown"), right = Format.Number(it.here) .. " XP" }
                end
                lines[#lines + 1] = { "Each later zone is planned as you will find it: from where you leave the zone before, at the level you will have, with the quests still in your log.", color = C.faint }
                if it.alt then
                    lines[#lines + 1] = { "Starting with " .. (it.alt.name or Game.MapName(it.alt.map) or "another zone") .. " instead",
                        right = string.format("%+d%% XP/h", (it.alt.gain or 0) * 100 + 0.5) }
                    lines[#lines + 1] = { "Click: plan " .. (it.alt.name or "that zone"), color = C.faint }
                end
                if it.segments[1].map ~= view.zone then lines[#lines + 1] = { "Click: plan " .. (it.segments[1].name or "the first zone"), color = C.faint } end
                return lines
            end,
            onClick = function()
                local go = it.alt and it.alt.map or it.segments[1].map
                if go ~= view.zone then Engine.SetZone(go); state.tab = "route"; state.scroll = 0 end
            end,
        }
    end
    -- What a zone is worth: with an itinerary made for the shown zone, the next hours when that
    -- zone is done first and the best way on is taken after it (itinerary.starts); the zones
    -- are then listed by that. Without one (or while it is for another zone, or does not know a
    -- listed zone yet): the zone's own XP per hour, trip included, in the ranking's order.
    local starts
    local order = (it and not view.chain) and ns.Zones.StartOrder(it, view.ranked, view.zone) or nil
    if order then
        -- the zone shown stays first, then the Zones.StartOrder (the banner's order), then the
        -- zones with nothing to do
        starts = it.starts
        local list, listed = {}, {}
        for _, z in ipairs(ranked) do if z.map == view.zone then list[#list + 1] = z; listed[z] = true end end
        for _, z in ipairs(order) do if not listed[z] then list[#list + 1] = z; listed[z] = true end end
        for _, z in ipairs(ranked) do if not listed[z] then list[#list + 1] = z end end
        ranked = list
    end
    local function worth(z)
        if not starts then return z.plan.score end
        return starts[z.map] and starts[z.map].rate or 0
    end
    local span = it and (it.horizon % 3600 == 0 and string.format("%d hours", it.horizon / 3600) or Format.Duration(it.horizon)) or nil
    local best = 0
    for _, z in ipairs(ranked) do if worth(z) > best then best = worth(z) end end
    local place = 0
    for _, z in ipairs(ranked) do
        local p = z.plan
        local name = ns.Zones.Name(z.map) or Game.MapName(z.map) or ("Map " .. z.map)
        local shown = z.map == view.zone
        if not shown then place = place + 1 end
        local i = place
        local value = worth(z)
        local onward = starts and starts[z.map] and starts[z.map].next or nil
        local onwardName = onward and (ns.Zones.Name(onward) or Game.MapName(onward) or ("Map " .. onward)) or nil
        -- (while a class quest chain is followed there is no zone to compare with)
        local gain
        if starts then
            local stay = starts[view.zone] and starts[view.zone].rate or 0
            if not shown and stay > 0 and starts[z.map] then gain = starts[z.map].rate / stay - 1 end
        elseif not shown and view.plan and not view.chain then
            gain = ns.Zones.Gain(view.plan, p)
        end
        local trip = (z.map ~= view.here and p.steps[1]) and p.steps[1].travel or nil
        local detail = (z.dungeon and (hex(C.warn) .. "Dungeon|r  |cff5f646e·|r  ") or "")
            .. string.format("%d quest%s", p.quests, p.quests == 1 and "" or "s")
        if #p.steps > 0 then detail = detail .. "  |cff5f646e·|r  " .. Format.Duration(p.seconds) end
        if trip and trip > 60 then detail = detail .. "  |cff5f646e·|r  " .. Format.Duration(trip) .. " away" end
        if onwardName then detail = detail .. "  |cff5f646e·|r  then " .. onwardName end
        if gain then
            local pct = math.floor(math.abs(gain) * 100 + 0.5)
            if pct >= 1 then
                detail = string.format("%s%s%d%%|r  |cff5f646e·|r  ", hex(gain > 0 and C.good or C.faint), gain > 0 and "+" or "-", pct) .. detail
            end
        end
        out[#out + 1] = {
            h = ROW_H, current = shown, pill = shown and "SHOWN" or tostring(i), icon = shown and ICON.shown or nil,
            rank = not shown and tostring(i) or nil,
            -- a dungeon carries the game's dungeon-entrance icon in front of its name
            title = (z.dungeon and DUNGEON_ICON or "") .. name .. (z.lo and string.format("  %s%d-%d|r", hex(C.faint), z.lo, z.hi) or ""),
            dungeon = z.dungeon and true or nil,
            detail = detail, right = Format.Number(value), rightSub = "XP/h",
            bar = best > 0 and value / best or 0,
            tip = function()
                local pct = gain and string.format("%+d%%", gain * 100 + (gain >= 0 and 0.5 or -0.5)) or nil
                local lines = { { name } }
                if starts then
                    if onwardName then
                        lines[#lines + 1] = { "XP per hour over the next " .. span .. ", starting here", right = Format.Number(value) }
                        lines[#lines + 1] = { "Then, from where this zone is left", right = onwardName }
                    else
                        lines[#lines + 1] = { "XP per hour in this zone alone, while it lasts (an hour at least)", right = Format.Number(value) }
                    end
                    if gain then lines[#lines + 1] = { "Against starting with " .. (view.zoneName or "the zone shown"), right = pct } end
                    lines[#lines + 1] = { "This zone alone, first hour, trip included", right = Format.Number(p.score) .. " XP/h" }
                else
                    lines[#lines + 1] = { "XP per hour, trip included", right = Format.Number(p.score) }
                    if gain then lines[#lines + 1] = { "Leaving now, over the next hour", right = pct } end
                end
                if gain then lines[#lines + 1] = { "Counted as leaving from your zone's main hub while you are in it.", color = C.faint } end
                lines[#lines + 1] = { "Whole route", right = Format.Duration(p.seconds) .. ", " .. Format.Number(p.xp) .. " XP" }
                local l = p.lists
                if #l.later > 0 then lines[#lines + 1] = { "Quests for a higher level", right = tostring(#l.later) } end
                if #l.group > 0 then lines[#lines + 1] = { "Group quests", right = tostring(#l.group) } end
                if l.escort and #l.escort > 0 then lines[#lines + 1] = { "Escort quests", right = tostring(#l.escort) } end
                lines[#lines + 1] = { shown and "This zone is shown." or "Click: plan this zone", color = C.faint }
                return lines
            end,
            onClick = function() if not shown then Engine.SetZone(z.map); state.tab = "route"; state.scroll = 0 end end,
        }
    end
    return out
end

local LISTS = {
    { "later", "Later", "Needs a higher level." },
    { "group", "Needs a group", "Elite quest. Turn on \"Group quests: in the route\" in the options to plan it." },
    { "escort", "Escort quests", "Walk an NPC somewhere or keep it alive: several minutes, and it fails if the NPC dies. Turn on \"Escort quests: in the route\" in the options to plan it." },
    { "skipped", "Left out as slow", "Pays much less per minute than the rest of the route." },
    { "unlocated", "No known location", "No database knows where this is done." },
    { "unconfirmed", "Not confirmed in Forever", "No player data shows this quest exists in Forever. It is planned once it is in your log." },
    { "ignored", "Skipped by you", "Click to bring it back." },
}

-- The quest picked by name being followed (Engine.PickQuest), on top of the Quests tab.
local function followingRow(c, view)
    return {
        h = ROW_H, current = true, pill = "SHOWN", icon = ICON.shown, title = Format.QuestName(c.name, c.level),
        detail = chainSummary(c, view.plan),
        tip = function()
            return { { "Quest: " .. Format.QuestName(c.name, c.level) },
                { "This is the plan shown: the quest and its chain. When it is done, LevelScout goes back to leveling." },
                { "Right-click: back to the leveling plan", color = C.faint } }
        end,
        onClick = function(mouse) if mouse == "RightButton" then Engine.EndChain() end end,
    }
end

local pickFound -- (defined with the search box: makes a found quest the plan)

-- Is something typed in the search box (two letters at least)? The Quests tab then lists what
-- it found instead of what the route leaves out.
local function searching()
    return #((state.query or ""):gsub("[^%w]", "")) >= 2
end

-- What the search box found (state.results, for state.query).
local function foundRows()
    local out = {}
    local results = state.resultsFor == state.query and state.results or nil
    if not results then
        out[#out + 1] = { h = ROW_H, title = "Searching...", dim = true }
        return out
    end
    if #results == 0 then
        out[#out + 1] = { h = ROW_H, pill = "TIP", icon = ICON.tip, title = "No quest you can accept matches",
            detail = "Typos and case do not matter. Quests for a higher level, or whose earlier quests are not done, are not listed.", dim = true }
        return out
    end
    out[#out + 1] = { section = string.format("Quests you can accept  %s%d|r", hex(C.faint), #results), h = SECTION_H }
    for i, r in ipairs(results) do
        local where = r.zone and zoneName(r.zone) or nil
        local detail = (r.giver or "?") .. (where and ("  |cff5f646e·|r  " .. where) or "")
        if (r.chain or 1) > 1 then detail = detail .. "  |cff5f646e·|r  " .. hex(C.accent) .. "chain of " .. r.chain .. "|r" end
        out[#out + 1] = {
            h = ROW_H, pill = "FIND", icon = ICON.accept, title = Format.QuestName(r.name, r.level), detail = detail,
            right = (r.minLevel or 0) > 0 and ("L" .. r.minLevel) or nil,
            tip = function()
                local lines = { { Format.QuestName(r.name, r.level) } }
                if r.giver then lines[#lines + 1] = { "Given by " .. r.giver .. (where and (" in " .. where) or "") } end
                if (r.chain or 1) > 1 then
                    lines[#lines + 1] = { string.format("Part of a chain: %d quests still to do, all planned", r.chain) }
                    for k, n in ipairs(r.chainNames or {}) do
                        if k > 10 then lines[#lines + 1] = { "  ...", color = C.dim }; break end
                        lines[#lines + 1] = { "  " .. n, color = C.dim }
                    end
                end
                lines[#lines + 1] = { (i == 1 and "Click (or Enter): " or "Click: ") .. "make it the plan", color = C.faint }
                return lines
            end,
            onClick = function() pickFound(r) end,
        }
    end
    return out
end

local function questRows(view)
    local out = {}
    local c = view.chain
    if c and c.kind == "quest" then out[#out + 1] = followingRow(c, view) end
    if searching() then
        for _, row in ipairs(foundRows()) do out[#out + 1] = row end
        return out
    end
    local lists = view.plan and view.plan.lists
    if not lists then return out end
    for _, def in ipairs(LISTS) do
        local key, title, hint = def[1], def[2], def[3]
        local list = lists[key] or {}
        if #list > 0 then
            out[#out + 1] = { section = string.format("%s  %s%d|r", title, hex(C.faint), #list), h = SECTION_H }
            for _, e in ipairs(list) do
                local detail = hint
                if key == "later" and e.needLevel then detail = "At level " .. e.needLevel
                elseif e.reason and key ~= "ignored" then detail = e.reason:gsub("^%l", string.upper) end
                out[#out + 1] = {
                    h = ROW_H, title = e.name, detail = detail, dim = true,
                    right = (e.level or 0) > 0 and ("L" .. e.level) or nil,
                    tip = function()
                        local lines = { { e.name }, { hint } }
                        if e.xp and e.xp > 0 then lines[#lines + 1] = { "Quest XP", right = Format.Number(e.xp) } end
                        if key == "ignored" then lines[#lines + 1] = { "Click: plan this quest again", color = C.faint }
                        elseif e.loc then lines[#lines + 1] = { "Click: point the arrow at the giver.  Right-click: skip", color = C.faint }
                        else lines[#lines + 1] = { "Right-click: skip this quest", color = C.faint } end
                        return lines
                    end,
                    onClick = function(mouse)
                        if key == "ignored" then Engine.Ignore(e.id, false)
                        elseif mouse == "RightButton" then Engine.Ignore(e.id, true)
                        elseif e.loc then Guide.Show({ loc = e.loc }, "Accept: " .. e.name) end
                    end,
                }
            end
        end
    end
    return out
end

-- The Class tab: the chain followed, the chains to pick (lowest level first), and those
-- turned off.
local function classRows(view)
    local out = {}
    local c = view.chain
    if c and c.kind ~= "quest" then
        out[#out + 1] = { section = "Following", h = SECTION_H }
        out[#out + 1] = {
            h = ROW_H, current = true, pill = "SHOWN", icon = ICON.shown, title = Format.QuestName(c.name, c.level),
            detail = chainSummary(c, view.plan),
            tip = function()
                return { { "Class quest: " .. Format.QuestName(c.name, c.level) },
                    { "This is the plan shown. When the chain is done, LevelScout goes back to leveling." },
                    { "Right-click: back to the leveling plan", color = C.faint } }
            end,
            onClick = function(mouse) if mouse == "RightButton" then Engine.EndChain() end end,
        }
    end
    local offers, never = {}, {}
    for _, o in ipairs(view.chains or {}) do
        if o.never then never[#never + 1] = o else offers[#offers + 1] = o end
    end
    if #offers > 0 then
        out[#out + 1] = { section = string.format("Available  %s%d|r", hex(C.faint), #offers), h = SECTION_H }
        for _, o in ipairs(offers) do
            local f = o.facts or {}
            local fresh = o.new or (state.fresh and state.fresh[o.id])
            local lead = (fresh and (hex(C.good) .. "New|r  |cff5f646e·|r  ") or "")
                .. ((f.eliteStep or f.groupName) and (hex(C.warn) .. "Group|r  |cff5f646e·|r  ") or "")
            out[#out + 1] = {
                h = ROW_H, pill = "CLASS", icon = ICON.accept, title = Format.QuestName(o.name, o.level),
                detail = lead .. plural(o.count or 0, "quest") .. "  |cff5f646e·|r  " .. Format.Duration(o.seconds)
                    .. (o.startZone and ("  |cff5f646e·|r  " .. o.startZone) or ""),
                right = Format.Number(o.xp), rightSub = "XP",
                tip = chainTip(o, { "Click: plan it", "Right-click: don't suggest it again" }),
                onClick = function(mouse)
                    if mouse == "RightButton" then Engine.ChainNever(o.id, true)
                    else Engine.SetChain(o.id); state.tab = "route"; state.scroll = 0 end
                end,
            }
        end
    end
    if #never > 0 then
        out[#out + 1] = { section = string.format("Not suggested  %s%d|r", hex(C.faint), #never), h = SECTION_H }
        for _, o in ipairs(never) do
            out[#out + 1] = {
                h = ROW_H, title = Format.QuestName(o.name, o.level), detail = "Click to suggest it again.", dim = true,
                tip = function()
                    return { { "Class quest: " .. Format.QuestName(o.name, o.level) }, { "You asked not to have this chain suggested." },
                        { "Click: suggest it again", color = C.faint } }
                end,
                onClick = function() Engine.ChainNever(o.id, false) end,
            }
        end
    end
    return out
end

---------------------------------------------------------------------------------------------
-- Row widgets
---------------------------------------------------------------------------------------------

local ICON_SIZE, TEXT_LEFT = 16, PAD + 16 + 8

local function newRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetSize(WIDTH, ROW_H)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.fill = art(r, "BACKGROUND", HIGHLIGHT, { C.accent[1], C.accent[2], C.accent[3], 0.35 }, "ADD")
    r.fill:SetAllPoints()
    r.hover = art(r, "BORDER", HIGHLIGHT, { 1, 1, 1, 0.5 }, "ADD")
    r.hover:SetAllPoints()
    r.hover:Hide()
    r.rule = tex(r, "ARTWORK", C.line)
    r.rule:SetPoint("BOTTOMLEFT", PAD, 0)
    r.rule:SetPoint("BOTTOMRIGHT", -PAD, 0)
    r.rule:SetHeight(1)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ICON_SIZE, ICON_SIZE)
    r.rank = text(r, "GameFontNormal", C.accent, "CENTER")
    r.rank:SetWidth(ICON_SIZE)
    r.title = text(r, "GameFontHighlight", C.text)
    r.detail = text(r, "GameFontHighlightSmall", C.dim)
    r.right = text(r, "GameFontHighlight", C.text, "RIGHT")
    r.rightSub = text(r, "GameFontHighlightSmall", C.faint, "RIGHT")
    r.bar = art(r, "ARTWORK", BAR, C.accent)
    r.bar:SetHeight(3)
    r.section = text(r, "GameFontNormalSmall", C.accent)
    r.section:SetPoint("BOTTOMLEFT", PAD, 5)
    r.section:SetWordWrap(true) -- a long heading wraps (its row is made tall enough: sectionH)
    -- "Skip" on the current step: the same as right-clicking any step
    r.skip = CreateFrame("Button", nil, r)
    r.skip:SetSize(34, 16)
    r.skip:SetPoint("BOTTOMRIGHT", -PAD + 4, 4)
    r.skip.label = text(r.skip, "GameFontHighlightSmall", C.faint, "CENTER")
    r.skip.label:SetAllPoints()
    r.skip.label:SetText("Skip")
    r.skip:SetScript("OnEnter", function(self) self.label:SetTextColor(C.accent[1], C.accent[2], C.accent[3]) end)
    r.skip:SetScript("OnLeave", function(self) self.label:SetTextColor(C.faint[1], C.faint[2], C.faint[3]) end)
    r.skip:SetScript("OnClick", function()
        if r.model and r.model.step then
            skipQuest(r.model.step)
            UI.Refresh()
        end
    end)
    r:SetScript("OnClick", function(self, mouse)
        if self.model and self.model.onClick then
            self.model.onClick(mouse)
            UI.Refresh()
        end
    end)
    tooltip(r, function(self) return self.model and self.model.tip and self.model.tip() end)
    return r
end

local function drawRow(r, m)
    r.model = m
    r:SetSize(WIDTH, m.h)
    local isSection = m.section ~= nil
    for _, part in ipairs({ r.icon, r.rank, r.title, r.detail, r.right, r.rightSub, r.bar, r.fill, r.rule, r.skip }) do part:Hide() end
    r.section:Hide()
    r:EnableMouse(not isSection)
    if isSection then
        local c = m.warn and C.warn or C.accent
        r.section:SetWidth(WIDTH - 2 * PAD)
        r.section:SetText(m.section)
        r.section:SetTextColor(c[1], c[2], c[3])
        r.section:Show()
        return
    end
    r.rule:Show()
    if m.current then r.fill:Show() end
    local alpha = m.dim and 0.55 or 1
    local left = PAD
    local top = m.current and -8 or -6
    if m.icon then
        r.icon:SetTexture(m.icon)
        r.icon:SetAlpha(alpha)
        r.icon:ClearAllPoints()
        r.icon:SetPoint("TOPLEFT", PAD, top + 1)
        r.icon:Show()
        left = TEXT_LEFT
    elseif m.rank then
        r.rank:SetText(m.rank)
        r.rank:ClearAllPoints()
        r.rank:SetPoint("TOPLEFT", PAD, top)
        r.rank:Show()
        left = TEXT_LEFT
    end
    local rightW = m.right and 58 or 0
    local title = (m.current and m.step) and C.accent or C.text -- the current step reads like a quest title
    r.title:ClearAllPoints()
    r.title:SetPoint("TOPLEFT", left, top)
    r.title:SetWidth(WIDTH - left - PAD - rightW)
    r.title:SetText(m.title or "")
    r.title:SetTextColor(title[1], title[2], title[3], alpha)
    r.title:Show()
    local skip = m.current and m.step ~= nil
    r.detail:ClearAllPoints()
    r.detail:SetPoint("TOPLEFT", left, m.current and -25 or -21)
    r.detail:SetWidth(WIDTH - left - PAD - ((m.rightSub or skip) and rightW or 0))
    -- a stop shared by several items lists them one per line
    local lines = m.lines or 1
    r.detail:SetWordWrap(lines > 1)
    r.detail:SetJustifyV("TOP")
    r.detail:SetHeight(lines * LINE_H)
    if r.detail.SetMaxLines then r.detail:SetMaxLines(lines) end
    r.detail:SetText(m.detail or "")
    r.detail:SetTextColor(C.dim[1], C.dim[2], C.dim[3], alpha)
    r.detail:Show()
    if skip then r.skip:Show() end
    if m.right then
        r.right:ClearAllPoints()
        r.right:SetPoint("TOPRIGHT", -PAD, top)
        r.right:SetWidth(rightW)
        r.right:SetText(m.right)
        local rc = m.rightSub and C.accent or C.good
        r.right:SetTextColor(rc[1], rc[2], rc[3], alpha)
        r.right:Show()
    end
    if m.rightSub then
        r.rightSub:ClearAllPoints()
        r.rightSub:SetPoint("TOPRIGHT", -PAD, -21)
        r.rightSub:SetText(m.rightSub)
        r.rightSub:Show()
    end
    if m.bar then
        r.bar:ClearAllPoints()
        r.bar:SetPoint("BOTTOMLEFT", PAD, 2)
        r.bar:SetWidth(math.max(2, (WIDTH - 2 * PAD) * math.min(1, m.bar)))
        r.bar:Show()
    end
end

---------------------------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------------------------

local function visibleRows() return SIZES[settings.size or 2][2] end
local function listHeight() return settings.listH or (visibleRows() * ROW_H + (ROW_CURRENT_H - ROW_H)) end

-- Everything whose width was set when the window was built follows the window's width.
-- The tabs side by side, as wide as the window. The Class tab only while it has something: a
-- class quest chain followed, on offer, or turned off.
local function hasClass(view)
    return (view.chain ~= nil and view.chain.kind ~= "quest") or #(view.chains or {}) > 0
end
local function placeTabs()
    local shown = {}
    for _, b in ipairs(root.tabButtons) do
        if b.key ~= "class" or state.classShown then shown[#shown + 1] = b else b:Hide() end
    end
    for i, b in ipairs(shown) do
        b:SetSize(WIDTH / #shown, TABS_H)
        b:ClearAllPoints()
        b:SetPoint("LEFT", (i - 1) * WIDTH / #shown, 0)
        b:Show()
    end
end

local function applyWidth()
    WIDTH = math.max(MIN_W, math.min(MAX_W, settings.width or DEFAULT_W))
    root:SetWidth(WIDTH + 2 * INSET)
    root.title:SetWidth(WIDTH - 148)
    root.summaryText:SetWidth(WIDTH - 120)
    root.banner:SetSize(WIDTH, BANNER_H)
    root.banner.label:SetWidth(WIDTH - 90)
    placeTabs()
    root.empty:SetWidth(WIDTH - 4 * PAD)
    root.emptySub:SetWidth(WIDTH - 4 * PAD)
end

--- Set the window's size: the content width and the height of the list, both clamped.
function UI.Resize(width, listH)
    if not root then return end
    settings.width = math.floor(math.max(MIN_W, math.min(MAX_W, width or WIDTH)) + 0.5)
    if listH then settings.listH = math.floor(math.max(MIN_LIST_H, math.min(MAX_LIST_H, listH)) + 0.5) end
    UI.Refresh()
end

local function savePosition()
    local point, _, relPoint, x, y = root:GetPoint(1)
    settings.pos = { point or "CENTER", relPoint or "CENTER", x or 0, y or 0 }
end

local function applyPosition()
    local p = settings.pos or { "RIGHT", "RIGHT", -260, 60 }
    root:ClearAllPoints()
    root:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    root:SetScale(settings.scale or 1)
    root:SetMovable(not settings.locked)
end

local MENU
local function menuItems()
    local size, scale = settings.size or 2, settings.scale or 1
    local items = {
        { "Re-plan now", function() Engine.Replan(true) end },
        { Engine.view.chain and "Back to the leveling plan" or nil, function() Engine.EndChain() end },
        { (Engine.chardb and Engine.chardb.zone) and "Let LevelScout pick the zone" or nil, function() Engine.SetZone(nil) end },
        { (settings.locked and "Unlock" or "Lock") .. " position", function() settings.locked = not settings.locked; applyPosition() end },
        { "Group quests: " .. (Engine.RoutesElite() and "in the route" or "listed only"), function() Engine.SetRouteElite(not Engine.RoutesElite()) end },
        { "Escort quests: " .. (Engine.RoutesEscort() and "in the route" or "listed only"), function() Engine.SetRouteEscort(not Engine.RoutesEscort()) end },
        -- talking to an NPC accepts and hands in the plan's quests there (Shift held: not this time)
        { "Accept planned quests: " .. (ns.AutoQuest.Accepts() and "auto" or "by hand"), function() ns.AutoQuest.SetAccept(not ns.AutoQuest.Accepts()) end },
        { "Turn in planned quests: " .. (ns.AutoQuest.TurnsIn() and "auto" or "by hand"), function() ns.AutoQuest.SetTurnIn(not ns.AutoQuest.TurnsIn()) end },
        -- the Deeprun Tram: auto (what that comes to), on, off
        (function()
            local mode, used = Engine.Tram()
            if used == nil and mode == "auto" and Engine.view.plan then return { nil } end -- (this side has no tram)
            local label = mode == "auto" and (used == nil and "auto" or ("auto (" .. (used and "on" or "off") .. ")")) or mode
            local nextMode = { auto = "on", on = "off", off = "auto" }
            return { "Deeprun Tram: " .. label, function() Engine.SetTram(nextMode[mode]) end }
        end)(),
        -- a size dragged by the corner is "Custom"; picking here goes back to the presets
        { "Size: " .. ((settings.listH or settings.width) and "Custom" or SIZES[size][1]), function()
            if settings.listH or settings.width then settings.listH, settings.width = nil, nil
            else settings.size = size % #SIZES + 1 end
            state.scroll = 0
        end },
        { string.format("Scale: %d%%", scale * 100 + 0.5), function()
            local nextScale = SCALES[1]
            for i, s in ipairs(SCALES) do if math.abs(s - scale) < 0.01 then nextScale = SCALES[i % #SCALES + 1] end end
            settings.scale = nextScale
            applyPosition()
        end },
        { "Reset position", function() settings.pos = nil; applyPosition() end },
        { ns.Debug and "Search view (debug)" or nil, function() ns.Debug.Toggle(true) end },
        { ns.MinimapButton and ("Minimap button: " .. (ns.MinimapButton.IsShown() and "shown" or "hidden")) or nil,
            function() ns.MinimapButton.SetShown(not ns.MinimapButton.IsShown()) end },
    }
    -- one switch per XP buff this character has had
    for _, b in ipairs(Engine.BuffReminders()) do
        items[#items + 1] = { string.format("Remind: %s  %s%s|r", b.name, b.remind and hex(C.good) or hex(C.faint), b.remind and "on" or "off"),
            function() Engine.SetBuffReminder(b.spellId, not b.remind) end }
    end
    return items
end

local function toggleMenu(anchor)
    if MENU and MENU:IsShown() then MENU:Hide(); return end
    if not MENU then
        MENU = framed("Frame", nil, root)
        MENU:SetFrameStrata("DIALOG")
        MENU:EnableMouse(true)
        MENU.items = {}
    end
    local n = 0
    for _, item in ipairs(menuItems()) do
        if item[1] then
            n = n + 1
            local b = MENU.items[n]
            if not b then
                b = button(MENU, 190, 22, function(self) self.run(); MENU:Hide(); UI.Refresh() end)
                b.label = text(b, "GameFontHighlightSmall", C.text)
                b.label:SetPoint("LEFT", 10, 0)
                b:SetPoint("TOPLEFT", INSET, -(n - 1) * 22 - INSET)
                MENU.items[n] = b
            end
            b.label:SetText(item[1])
            b.run = item[2]
            b:Show()
        end
    end
    for i = n + 1, #MENU.items do MENU.items[i]:Hide() end
    MENU:SetSize(190 + 2 * INSET, n * 22 + 2 * INSET)
    MENU:ClearAllPoints()
    MENU:SetPoint("TOPRIGHT", anchor or root, "BOTTOMRIGHT", 0, -2)
    MENU:Show()
end

local function build()
    root = framed("Frame", "LevelScoutFrame", UIParent)
    root:SetFrameStrata("MEDIUM")
    root:SetClampedToScreen(true)
    root:EnableMouse(true)
    root:SetWidth(WIDTH + 2 * INSET)

    -- header: drag handle, zone name, menu / collapse / close
    local header = CreateFrame("Frame", nil, root)
    header:SetPoint("TOPLEFT", INSET, -INSET); header:SetPoint("TOPRIGHT", -INSET, -INSET); header:SetHeight(HEADER_H)
    header.rule = tex(header, "ARTWORK", C.line)
    header.rule:SetPoint("BOTTOMLEFT", PAD, 0); header.rule:SetPoint("BOTTOMRIGHT", -PAD, 0); header.rule:SetHeight(1)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() if not settings.locked then root:StartMoving() end end)
    header:SetScript("OnDragStop", function() root:StopMovingOrSizing(); savePosition() end)
    root.title = text(header, "GameFontNormal", C.accent)
    root.title:SetPoint("LEFT", PAD, -1)
    root.title:SetWidth(WIDTH - 148)
    -- the game's own close button when the client has it
    local hasClose, close = pcall(CreateFrame, "Button", nil, header, "UIPanelCloseButton")
    if hasClose and close then
        close:SetSize(26, 26)
        close:SetPoint("RIGHT", 4, 0)
        close:SetScript("OnClick", function() UI.Toggle(false) end)
    else
        close = button(header, 22, 22, function() UI.Toggle(false) end, "Hide (type /ls to show)")
        close:SetPoint("RIGHT", -4, -1)
        close.x = text(close, "GameFontHighlight", C.dim, "CENTER")
        close.x:SetPoint("CENTER", 0, 0)
        close.x:SetText("x")
    end
    local fold = button(header, 22, 22, function() settings.collapsed = not settings.collapsed end, "Collapse to the current step")
    fold:SetPoint("RIGHT", close, "LEFT", 0, 0)
    fold.bar = tex(fold, "ARTWORK", C.accent)
    fold.bar:SetSize(10, 2)
    fold.bar:SetPoint("CENTER", 0, -3)
    local menu = button(header, 22, 22, function(self) toggleMenu(self) end, "Options")
    menu:SetPoint("RIGHT", fold, "LEFT", -2, 0)
    for i = -1, 1 do
        local bar = tex(menu, "ARTWORK", C.accent)
        bar:SetSize(10, 2)
        bar:SetPoint("CENTER", 0, i * 4)
    end
    -- the search view (debug): three rising bars, like its curve
    if ns.Debug then
        local search = button(header, 22, 22, function() ns.Debug.Toggle() end, "Search view: how the route was found (debug)")
        search:SetPoint("RIGHT", menu, "LEFT", -2, 0)
        for i = 0, 2 do
            local bar = tex(search, "ARTWORK", C.accent)
            bar:SetSize(2, 4 + i * 3)
            bar:SetPoint("BOTTOM", search, "CENTER", (i - 1) * 4, -5)
        end
        root.searchButton = search
    end
    -- re-plan: from scratch on a left click (the shown route is not kept), the usual way on a right click
    local replan = button(header, 22, 22, function(_, mouse)
        if mouse == "RightButton" then Engine.Replan(true) else Engine.ReplanFresh() end
    end)
    replan:SetPoint("RIGHT", root.searchButton or menu, "LEFT", -2, 0)
    replan.icon = art(replan, "ARTWORK", "Interface\\Buttons\\UI-RefreshButton", C.accent)
    replan.icon:SetSize(14, 14)
    replan.icon:SetPoint("CENTER", 0, -1)
    tooltip(replan, function()
        return { { "Re-plan from scratch" }, { "Forgets the shown route and searches again." },
            { "Right-click: re-plan and keep the shown route unless a new one is clearly better." } }
    end)
    for _, b in ipairs({ close, fold, menu }) do
        b:HookScript("OnClick", function() UI.Refresh() end)
    end

    -- summary: plan size on the left, XP per hour on the right
    local summary = CreateFrame("Frame", nil, root)
    summary:SetPoint("TOPLEFT", header, "BOTTOMLEFT"); summary:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT")
    summary:SetHeight(SUMMARY_H)
    root.summary = summary
    root.summaryText = text(summary, "GameFontHighlightSmall", C.dim)
    root.summaryText:SetPoint("LEFT", PAD, 0)
    root.summaryText:SetWidth(WIDTH - 120)
    root.rate = text(summary, "GameFontNormalLarge", C.accent, "RIGHT")
    root.rate:SetPoint("TOPRIGHT", -PAD, -6)
    root.rateSub = text(summary, "GameFontHighlightSmall", C.faint, "RIGHT")
    root.rateSub:SetPoint("TOPRIGHT", -PAD, -24)
    root.rateSub:SetText("XP per hour")
    tooltip(summary, function()
        local plan = Engine.view.plan
        if not plan or #plan.steps == 0 then return nil end
        local short = plan.seconds < ns.Planner.MIN_HORIZON -- the route ends before the hour it is judged on
        local hearth = Engine.view.hearth -- (Planner.HEARTH)
        local uses, saved, wait = 0, 0, 0
        if hearth then
            uses, saved = ns.Zones.HearthUses(plan)
            wait = (hearth.ready or 0) - (Game.Now() - (hearth.at or Game.Now())) -- (seconds from the plan, less those gone since)
        end
        return { { "XP per hour" }, { "Following this route and leaving at the best moment. Travel, kills and quest rewards are counted." },
            { short and "The route is shorter than an hour: the time left over earns nothing here." or false },
            { short and "Pace while it lasts" or "Whole route", right = Format.Number(short and plan.rate or plan.fullRate) .. " XP/h" },
            { (Engine.view.xpBonus or 0) > 0 and "XP buffs" or false, right = Format.Bonus(Engine.view) },
            { (Engine.view.restedPool or 0) > 0 and "Rested" or false,
                right = Format.Number((Engine.view.restedPool or 0) / 2) .. " bonus XP on kills" },
            { hearth and ("Hearthstone: bound at " .. tostring(hearth.name)) or false,
                right = wait > 0 and ("ready in " .. Format.Duration(wait)) or "ready" },
            { uses > 0 and "Hearthstone in this route" or false,
                right = string.format("%d %s, saves %s", uses, uses == 1 and "use" or "uses", Format.Duration(saved)) },
            { (Engine.view.groupSize or 1) > 1 and string.format("In a group of %d: kills are planned faster, their XP is shared, and quest drops are split between the members. Quest XP is unchanged.", Engine.view.groupSize) or false },
            { plan.logFull and "The quest log is too full for this route: turn something in or abandon a quest." or false, color = C.warn } }
    end)

    -- move-on banner
    local banner = button(root, WIDTH, BANNER_H, function()
        local m = Engine.view.moveOn
        if m and m.map then Engine.SetZone(m.map); state.tab = "route"; state.scroll = 0 end
    end)
    banner.bg = art(banner, "BACKGROUND", HIGHLIGHT, { C.accent[1], C.accent[2], C.accent[3], 0.5 }, "ADD")
    banner.bg:SetAllPoints()
    banner.label = text(banner, "GameFontNormalSmall", C.accent)
    banner.label:SetPoint("LEFT", PAD, 0)
    banner.label:SetWidth(WIDTH - 90)
    banner.go = text(banner, "GameFontHighlightSmall", C.text, "RIGHT")
    banner.go:SetPoint("RIGHT", -PAD, 0)
    banner.go:SetText("Switch >")
    root.banner = banner

    -- tabs
    local tabs = CreateFrame("Frame", nil, root)
    tabs:SetHeight(TABS_H)
    root.tabs, root.tabButtons = tabs, {}
    local defs = { { "route", "Route" }, { "zones", "Zones" }, { "quests", "Quests" }, { "class", "Class" } }
    for i, def in ipairs(defs) do
        local b = button(tabs, WIDTH / #defs, TABS_H, function() state.tab = def[1]; state.scroll = 0; UI.Refresh() end)
        b.hover:SetVertexColor(1, 1, 1, 0.3)
        -- a glow behind the title while the tab has news (the Class tab: a new class quest),
        -- slowly pulsing; gone once the tab is opened
        b.glow = art(b, "BACKGROUND", HIGHLIGHT, { C.accent[1], C.accent[2], C.accent[3], 0.6 }, "ADD")
        b.glow:SetAllPoints()
        b.glow:Hide()
        local pulse = 0
        b:SetScript("OnUpdate", function(self, elapsed)
            if not self.glowing then return end
            pulse = pulse + (elapsed or 0)
            self.glow:SetAlpha(0.45 + 0.35 * math.sin(pulse * 3))
        end)
        b:SetPoint("LEFT", (i - 1) * WIDTH / #defs, 0)
        b.label = text(b, "GameFontNormalSmall", C.dim, "CENTER")
        b.label:SetPoint("CENTER", 0, 0)
        b.line = tex(b, "ARTWORK", C.accent)
        b.line:SetPoint("BOTTOMLEFT", 12, 0); b.line:SetPoint("BOTTOMRIGHT", -12, 0); b.line:SetHeight(2)
        b.key, b.name = def[1], def[2]
        root.tabButtons[i] = b
    end
    tabs.rule = tex(tabs, "ARTWORK", C.line)
    tabs.rule:SetPoint("BOTTOMLEFT"); tabs.rule:SetPoint("BOTTOMRIGHT"); tabs.rule:SetHeight(1)

    -- the Quests tab's search box: any quest to accept, by name (Engine.FindQuests); the one
    -- picked becomes the plan with its chain (Engine.PickQuest)
    local search = CreateFrame("Frame", nil, root)
    search:SetHeight(SEARCH_H)
    local made, box = pcall(CreateFrame, "EditBox", nil, search, "InputBoxTemplate")
    if not made or not box then box = CreateFrame("EditBox", nil, search) end
    box:SetAutoFocus(false)
    box:SetMaxLetters(60)
    box:SetHeight(20)
    box:SetPoint("LEFT", PAD + 6, 0)
    box:SetPoint("RIGHT", -PAD, 0)
    if box.SetFontObject and not made then box:SetFontObject("GameFontHighlightSmall") end
    box.hint = text(search, "GameFontHighlightSmall", C.faint)
    box.hint:SetPoint("LEFT", box, "LEFT", 2, 0)
    box.hint:SetText("Find a quest to plan, by name")
    local function runSearch()
        local query = state.query or ""
        state.results = searching() and Engine.FindQuests(query) or nil
        state.resultsFor = query
        state.scroll = 0
        UI.Refresh()
    end
    box:SetScript("OnTextChanged", function(self)
        local query = self:GetText() or ""
        if query == state.query then return end
        state.query = query
        box.hint[query == "" and "Show" or "Hide"](box.hint)
        local asked = query
        Game.After(UI.SEARCH_DELAY, function() if state.query == asked then runSearch() end end)
        UI.Refresh()
    end)
    pickFound = function(r)
        Engine.PickQuest(r.id)
        state.query, state.results, state.resultsFor = "", nil, nil
        box:SetText("")
        box.hint:Show()
        box:ClearFocus()
        state.tab, state.scroll = "route", 0
        UI.Refresh()
    end
    box:SetScript("OnEnterPressed", function(self)
        local first = searching() and state.resultsFor == state.query and state.results and state.results[1]
        if first then pickFound(first) else self:ClearFocus() end
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    search.box = box
    root.search = search

    -- list
    local list = CreateFrame("Frame", nil, root)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        state.scroll = math.max(0, state.scroll - delta)
        UI.Refresh()
    end)
    root.list = list
    root.empty = text(list, "GameFontHighlight", C.dim, "CENTER")
    root.empty:SetPoint("CENTER", 0, 6)
    root.empty:SetWidth(WIDTH - 4 * PAD)
    root.empty:SetWordWrap(true)
    root.emptySub = text(list, "GameFontHighlightSmall", C.faint, "CENTER")
    root.emptySub:SetPoint("TOP", root.empty, "BOTTOM", 0, -6)
    root.emptySub:SetWidth(WIDTH - 4 * PAD)
    root.emptySub:SetWordWrap(true)
    root.thumb = tex(list, "OVERLAY", { 1, 1, 1, 0.18 })
    root.thumb:SetWidth(2)

    -- footer
    local footer = CreateFrame("Frame", nil, root)
    footer:SetPoint("BOTTOMLEFT", INSET, INSET); footer:SetPoint("BOTTOMRIGHT", -INSET, INSET); footer:SetHeight(FOOTER_H)
    footer.rule = tex(footer, "ARTWORK", C.line)
    footer.rule:SetPoint("TOPLEFT"); footer.rule:SetPoint("TOPRIGHT"); footer.rule:SetHeight(1)
    root.status = text(footer, "GameFontHighlightSmall", C.faint)
    root.status:SetPoint("LEFT", PAD, 0)
    root.logText = text(footer, "GameFontHighlightSmall", C.faint, "RIGHT")
    root.logText:SetPoint("RIGHT", -PAD - 12, 0) -- leaves the corner to the resize grip
    -- the status on the left ends where the figures on the right begin (it is cut short, not drawn over them)
    root.status:SetPoint("RIGHT", root.logText, "LEFT", -8, 0)
    root.footer = footer

    -- progress while planning: a thin bar along the footer's top edge (the window's bottom
    -- edge when collapsed). It lies over the layout and never moves anything.
    local progress = CreateFrame("Frame", nil, root)
    progress:SetHeight(PROGRESS_H)
    progress:SetFrameLevel((footer:GetFrameLevel() or 0) + 2)
    progress.fill = art(progress, "OVERLAY", BAR, C.accent)
    progress.fill:SetPoint("TOPLEFT"); progress.fill:SetPoint("BOTTOMLEFT")
    progress:Hide()
    root.progress = progress

    -- resize grip in the bottom-right corner: drag to change the width and the list's height
    local grip = CreateFrame("Button", nil, root)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel((root:GetFrameLevel() or 0) + 10)
    grip.tex = art(grip, "OVERLAY", "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip.tex:SetAllPoints()
    grip.tex:SetAlpha(0.6)
    local function cursor()
        local x, y = GetCursorPosition()
        local s = root:GetEffectiveScale()
        if not s or s <= 0 then s = 1 end
        return (x or 0) / s, (y or 0) / s
    end
    grip:SetScript("OnEnter", function(self) self.tex:SetAlpha(1) end)
    grip:SetScript("OnLeave", function(self) if not self.drag then self.tex:SetAlpha(0.6) end end)
    grip:SetScript("OnMouseDown", function(self)
        -- hold the top-left corner still while the opposite corner moves
        local left, top = root:GetLeft(), root:GetTop()
        if left and top and (left ~= 0 or top ~= 0) then
            root:ClearAllPoints()
            root:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        end
        local x, y = cursor()
        self.drag = { x = x, y = y, w = WIDTH, h = listHeight() }
    end)
    grip:SetScript("OnMouseUp", function(self)
        self.drag = nil
        self.tex:SetAlpha(0.6)
        savePosition()
    end)
    grip:SetScript("OnUpdate", function(self)
        local d = self.drag
        if not d then return end
        local x, y = cursor()
        local w, h = d.w + (x - d.x), d.h - (y - d.y)
        if math.abs(w - WIDTH) >= 1 or math.abs(h - listHeight()) >= 1 then UI.Resize(w, h) end
    end)
    root.grip = grip

    -- the distance to the current step is refreshed about once a second
    local since = 0
    root:SetScript("OnUpdate", function(_, elapsed)
        since = since + (elapsed or 0)
        if since < 1 then return end
        since = 0
        UI.Tick()
    end)
end

local EMPTY = {
    route = { "Nothing to do here right now", "Open Zones to see where leveling is better." },
    zones = { "No zone fits this level yet", "Zones appear here once quests are available." },
    quests = { "Nothing is left out", "Every available quest here is in the route. Type above to find any quest to plan." },
    class = { "No class quest to pick right now", "Class quests appear here when they become available. The tab's title glows when one does." },
}

-- The progress bar and its text, from view.progress. Cheap: called a few times per second
-- while a plan is being made (Engine.OnProgress), and by every redraw.
local function showProgress(view)
    local bar = root.progress
    local p = view.busy and view.progress or nil
    if not p then
        bar:Hide()
        return
    end
    local collapsed = settings.collapsed
    local y = INSET + (collapsed and 0 or (FOOTER_H - PROGRESS_H))
    bar:ClearAllPoints()
    bar:SetPoint("BOTTOMLEFT", INSET, y); bar:SetPoint("BOTTOMRIGHT", -INSET, y)
    bar.fraction = math.max(0, math.min(1, p.fraction or 0))
    bar.fill:SetWidth(math.max(1, WIDTH * bar.fraction))
    bar:Show()
    -- the text takes the place of "Planning..." in the footer (a buff reminder stays)
    if not collapsed and not view.buffNote and p.text then root.status:SetText(p.text .. "...") end
end

--- Called by the engine while planning: only the bar and its text change.
function UI.Progress()
    if not root or not root:IsShown() then return end
    showProgress(Engine.view)
end

local function layout(view)
    local collapsed = settings.collapsed
    applyWidth()
    root.grip[collapsed and "Hide" or "Show"](root.grip)
    local y = -(INSET + HEADER_H + SUMMARY_H)
    local showBanner = view.moveOn and view.moveOn.suggest and view.status == "ready" and not collapsed
    root.banner:ClearAllPoints()
    if showBanner then
        root.banner:SetPoint("TOPLEFT", INSET, y)
        y = y - BANNER_H
        root.banner:Show()
    else
        root.banner:Hide()
    end
    root.tabs:ClearAllPoints()
    if collapsed then
        root.tabs:Hide()
    else
        root.tabs:SetPoint("TOPLEFT", INSET, y); root.tabs:SetPoint("TOPRIGHT", -INSET, y)
        root.tabs:Show()
        y = y - TABS_H
    end
    root.search:ClearAllPoints()
    if not collapsed and state.tab == "quests" then
        root.search:SetPoint("TOPLEFT", INSET, y); root.search:SetPoint("TOPRIGHT", -INSET, y)
        root.search:Show()
        y = y - SEARCH_H
    else
        root.search:Hide()
    end
    local h = collapsed and ROW_CURRENT_H or listHeight()
    root.list:ClearAllPoints()
    root.list:SetPoint("TOPLEFT", INSET, y); root.list:SetPoint("TOPRIGHT", -INSET, y)
    root.list:SetHeight(h)
    root.footer[collapsed and "Hide" or "Show"](root.footer)
    root:SetHeight(-y + h + (collapsed and 0 or FOOTER_H) + INSET)
    return h
end

--- Redraw from the engine's view.
function UI.Refresh()
    if not root or not root:IsShown() then return end
    local view = Engine.view
    local plan = view.plan
    -- paused (inside an instance): the last route stays, brought up to date from the quest log
    local paused = view.status == "paused" and plan ~= nil
    local ready = view.status == "ready" or ((view.status == "planning" or paused) and plan ~= nil)

    root.title:SetText(ready and view.zoneName or "LevelScout")
    if ready and plan and #plan.steps > 0 then
        root.summaryText:SetText(paused and (hex(C.warn) .. (view.message or "Paused") .. "|r  |cff5f646e·|r  the route goes on outside")
            or (view.chain and chainSummary(view.chain, plan)) or Format.PlanSummary(plan))
        -- the score, not plan.rate: a route shorter than an hour is still judged on an hour of play,
        -- so four turn-ins in two minutes do not read as hundreds of thousands per hour
        root.rate:SetText(Format.Number(plan.score))
        root.rate:Show(); root.rateSub:Show()
    else
        root.summaryText:SetText(ready and plan and Format.PlanSummary(plan) or (view.message or ""))
        root.rate:Hide(); root.rateSub:Hide()
    end
    -- the Class tab goes while it has nothing (and the window leaves it if it was open)
    state.classShown = hasClass(view)
    if not state.classShown and state.tab == "class" then state.tab, state.scroll = "route", 0 end
    local m = view.moveOn or {}
    if m.suggest then
        -- with an itinerary the gain is in XP per hour, the Zones tab's figures (m.rate); else over the next hour
        local who = m.name or "Another zone"
        root.banner.label:SetText(m.gain and (m.rate and string.format("%s: %d%% more XP per hour", who, m.gain * 100 + 0.5)
            or string.format("%s: %d%% more XP over the next hour", who, m.gain * 100 + 0.5))
            or string.format("Done here. Next: %s", m.name or "another zone"))
    end
    local h = layout(view)

    -- The Class tab open (and drawn): what is on it has been seen, and the glow goes. What was
    -- new keeps its "New" mark while the tab stays open (state.fresh).
    if state.tab == "class" and ready and not settings.collapsed then
        state.fresh = state.fresh or {}
        for _, o in ipairs(view.chains or {}) do if o.new then state.fresh[o.id] = true end end
        Engine.ChainsSeen()
    elseif state.tab ~= "class" then
        state.fresh = nil
    end
    local news = anyNew(view)
    for _, b in ipairs(root.tabButtons) do
        local on = b.key == state.tab
        local label = b.name
        if b.key == "quests" and plan then
            local n = 0
            for _, l in pairs(plan.lists) do n = n + #l end
            if n > 0 then label = label .. "  " .. hex(C.faint) .. n .. "|r" end
        end
        local glowing = b.key == "class" and news and not on
        if glowing then label = label .. "  " .. hex(C.good) .. "New|r" end
        b.label:SetText(label)
        local c = (on or glowing) and C.accent or C.dim
        b.label:SetTextColor(c[1], c[2], c[3])
        b.line[on and "Show" or "Hide"](b.line)
        b.glowing = glowing or nil
        b.glow[glowing and "Show" or "Hide"](b.glow)
    end

    local models = {}
    if ready then
        if settings.collapsed then
            local all = routeRows(view)
            for _, m in ipairs(all) do
                if m.current then models = { m }; break end
            end
            if #models == 0 then -- (pointed at a row that is not listed right now: the route's own step)
                for _, m in ipairs(all) do
                    if m.guided then models = { m }; break end
                end
            end
        elseif state.tab == "route" then models = routeRows(view)
        elseif state.tab == "zones" then models = zoneRows(view)
        elseif state.tab == "class" then models = classRows(view)
        else models = questRows(view) end
    end
    state.models = models
    local maxScroll = 0
    do -- how far can we scroll: until the last row is at the bottom
        local total = 0
        for i = #models, 1, -1 do
            total = total + models[i].h
            if total > h then maxScroll = i; break end
        end
    end
    state.scroll = math.min(state.scroll, maxScroll)
    local y, used = 0, 0
    for i = state.scroll + 1, #models do
        local m = models[i]
        if y + m.h > h + 0.5 then break end
        used = used + 1
        local r = rows[used]
        if not r then r = newRow(root.list); rows[used] = r end
        drawRow(r, m)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 0, -y)
        r:Show()
        y = y + m.h
    end
    for i = used + 1, #rows do rows[i]:Hide(); rows[i].model = nil end

    if #models == 0 then
        local e = EMPTY[state.tab]
        if not ready then
            root.empty:SetText(view.message or "Loading")
            root.emptySub:SetText(view.status == "error" and "Type /ls status for details." or "")
        else
            root.empty:SetText(e[1]); root.emptySub:SetText(e[2])
        end
        root.empty:Show(); root.emptySub:Show()
    else
        root.empty:Hide(); root.emptySub:Hide()
    end
    if maxScroll > 0 and #models > 0 then
        local share = used / #models
        root.thumb:ClearAllPoints()
        root.thumb:SetPoint("TOPRIGHT", -2, -(h * (1 - share)) * (state.scroll / maxScroll))
        root.thumb:SetHeight(math.max(12, h * share))
        root.thumb:Show()
    else
        root.thumb:Hide()
    end

    local where = Guide.mode == "tomtom" and "TomTom arrow" or (Guide.mode == "map" and "Map pin" or "No waypoint")
    local missing = view.missingBuffs and view.missingBuffs[1]
    if view.buffNote then
        root.status:SetText(hex(C.warn) .. view.buffNote:gsub("%. Renew it.*$", "") .. "|r")
    elseif missing and view.status == "ready" and not view.busy then
        -- an XP buff this character has used before is not on
        root.status:SetText(string.format("%sNo %s (+%d%% XP)|r", hex(C.warn), missing.name, missing.bonus * 100 + 0.5))
    else
        root.status:SetText(view.busy and "Planning..." or (view.status == "ready" and where or (view.status or "")))
    end
    showProgress(view)
    local group = (view.groupSize or 1) > 1 and string.format("%sGroup of %d|r  |cff5f646e·|r  ", hex(C.accent), view.groupSize) or ""
    if (view.xpBonus or 0) > 0 then group = string.format("%s+%d%% XP|r  |cff5f646e·|r  ", hex(C.good), view.xpBonus * 100 + 0.5) .. group end
    if (view.restedPool or 0) > 0 then group = hex(C.accent) .. "Rested|r  |cff5f646e·|r  " .. group end
    root.logText:SetText(view.logCount and (group .. string.format("Log %d/%s", view.logCount, tostring(view.capacity or "?"))) or group)
    UI.Tick()
end

--- Live distance on the current step.
function UI.Tick()
    if not root or not root:IsShown() then return end
    if state.tab ~= "route" and not settings.collapsed then return end
    local r, m
    for _, row in ipairs(rows) do
        if row:IsShown() and row.model and row.model.guided and row.model.step then r, m = row, row.model; break end
    end
    -- A row pointed at by hand shows the way to it: drawn again when that changes (landed).
    for _, row in ipairs(rows) do
        local pm = row:IsShown() and row.model or nil
        if pm and pm.pointedWay then
            local p = Guide.Pointed()
            if (p and Format.TripText(p.trip) or "") ~= pm.pointedWay then return UI.Refresh() end
        end
    end
    if not r then return end
    -- The way to the step (ns.Guide.Trip), as it stands now. Its line coming or going changes
    -- the row's height, so the list is drawn again; a change of words only is put in place.
    if m.base then
        local trip = wayText()
        if (trip ~= nil) ~= (m.trip ~= nil) or (trip and tripLines(trip) ~= tripLines(m.trip)) then return UI.Refresh() end
        if trip ~= m.trip then m.trip, m.detail = trip, colourTrip(trip, m.outside) .. "\n" .. m.base end
    end
    local d = not m.step.fromBag and Format.Distance(Guide.Distance(m.step)) or nil
    if not d then
        r.detail:SetText(m.detail)
        return
    end
    -- A row with several lines keeps them aligned: the distance goes on the last line, with
    -- the kills and the time.
    r.detail:SetText(prefixed(m.detail, hex(C.accent) .. d .. "|r  |cff5f646e·|r  "))
end

--- Show or hide (nil toggles).
function UI.Toggle(show)
    if not root then return end
    if show == nil then show = not root:IsShown() end
    settings.hidden = not show
    if show then root:Show(); UI.Refresh() else root:Hide(); if MENU then MENU:Hide() end end
end

function UI.IsShown() return root ~= nil and root:IsShown() end

--- Called once at login, after Engine.Start.
function UI.Start()
    if root then return end
    Engine.db.window = type(Engine.db.window) == "table" and Engine.db.window or {}
    settings = Engine.db.window
    build()
    applyPosition()
    Engine.OnChange(function() UI.Refresh() end)
    Engine.OnProgress(function() UI.Progress() end)
    if settings.hidden then root:Hide() else root:Show(); UI.Refresh() end
    if ns.MinimapButton then ns.MinimapButton.Start(settings) end
    if ns.FlightMap then ns.FlightMap.Start() end
end

-- Addon compartment (the minimap addon list) click.
function LevelScout_OnAddonCompartmentClick() UI.Toggle() end
