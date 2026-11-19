-- core/Play.lua: the play log. What the plan promised against what play brought, and where the
-- player did something else than the plan said. Pure Lua: no game API; the Engine tells it.
--
-- The planner is judged on its own forecasts otherwise (tests/bench.lua). This log is the other
-- side: the same forecasts next to the XP that really came in, and the moments the player
-- overruled the plan, which say what the plan gets wrong for this player.
--
--   Forecasts   Every FORECAST_EVERY seconds of play (and when the shown zone changes), the XP
--               the path promises inside each of Play.WINDOWS is written down, with the XP
--               earned so far. When that much play has passed, the XP earned since is written
--               next to it, and how often the player overruled the plan in between.
--   Events      zone     the shown zone was changed by hand ({ from, to, banner = true when the
--                        banner had suggested it, back = true when the path had just left it })
--               skip     a quest was left out by hand ({ q }); unskip: brought back
--               order    a quest was turned in that was more than ORDER_FRONT steps down the
--                        route ({ q, i })
--               extra    a quest was turned in that the route did not have ({ q })
--               banner   the move-on banner came up, or named another zone ({ to, gain })
--               moved    the path moved on to its next zone by itself ({ from, to })
--               hearth   the hearthstone was used ({ planned = true when the shown route had it on its first
--                        leg, to = where it is bound }); not "overruled": the plan may have it (Planner.HEARTH)
--               zone, skip, order and extra are "overruled": they count against the forecasts
--               open at that moment. Each event may carry snap = the id of the snapshot taken
--               for it (ns.Snapshot).
--
-- All times are on the Tracker's active clock (ns.Tracker.Active): standing still for long is
-- not play. That clock starts anew with every game session, so a forecast is only settled in
-- the session it was made in (`s`).
--
-- The store (kept with the character):
--   { v = Play.VERSION, session = number of sessions so far,
--     forecasts = { { s, a = active clock, lv, z = shown zone, x = XP earned in the session so far,
--                     p = { XP promised inside each window }, c = { seconds of each window the
--                     path covers (less than the window: the path ran out) },
--                     g = { XP got }, d = { times overruled }, n = events so far } },
--     events = { { s, a, k = kind, ... } } }

local _, ns = ...

local Play = {}
ns.Play = Play

Play.VERSION = 1
Play.WINDOWS = { 900, 1800, 3600 } -- seconds of play a forecast is made for
Play.FORECAST_EVERY = 600          -- seconds of play between two forecasts for the same zone
Play.KEEP_FORECASTS = 200          -- forecasts kept (the oldest go first)
Play.KEEP_EVENTS = 300             -- events kept
Play.ORDER_FRONT = 5               -- a turn-in further down the route than this was done out of order
Play.COVERED = 0.9                 -- a forecast counts for a window when its path covers this share of it
Play.OVERRULED = { zone = true, skip = true, order = true, extra = true }

local store          -- the character's log
local total = 0      -- XP earned in this session
local last           -- { level, xp, xpMax } at the last look
local open = {}      -- this session's forecasts with a window still to settle

local function number(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

--- Use `s` as the log (a damaged or older one is emptied) and begin a new session.
function Play.Start(s)
    if type(s) ~= "table" then s = {} end
    if s.v ~= Play.VERSION or type(s.forecasts) ~= "table" or type(s.events) ~= "table" then
        s.v, s.forecasts, s.events, s.session = Play.VERSION, {}, {}, 0
    end
    s.session = (number(s.session) and s.session or 0) + 1
    store, total, last, open = s, 0, nil, {}
    return s
end

--- Forget everything (the session's count stays).
function Play.Reset()
    if not store then return end
    store.forecasts, store.events = {}, {}
    open = {}
end

--- The character's XP as the game reports it. Returns the XP earned in this session so far.
--- A level-up shows as a higher level, or (the game can report the new XP before the new
--- level) as XP that went down: either way the rest of the old level and the new XP count.
function Play.XP(level, xp, xpMax)
    if not (number(level) and number(xp)) then return total end
    if last then
        if level < last.level then level = last.level end -- (still the old level after a level-up that was counted)
        local gained = 0
        if level > last.level or xp < last.xp then
            gained = math.max(0, (last.xpMax or last.xp) - last.xp) + xp
            if level <= last.level then level = last.level + 1 end -- (the level follows: do not count it twice)
        else
            gained = xp - last.xp
        end
        total = total + gained
    end
    last = { level = level, xp = xp, xpMax = number(xpMax) and xpMax or (last and last.xpMax) or nil }
    return total
end

--- XP earned in this session so far.
function Play.Total() return total end

--- What the path promises inside the next `w` seconds: the shown plan up to where the
--- itinerary leaves it, then the itinerary's later zones (their trips on the clock). Without an
--- itinerary for the plan's zone, the plan alone. A camp being worked when the time runs out
--- counts for the share done. Returns the XP and the seconds covered (less than `w`: the path
--- ran out before).
function Play.Within(plan, itinerary, w)
    if not plan or not plan.steps or #plan.steps == 0 then return 0, 0 end
    local segs = itinerary and itinerary.segments
    if not (segs and segs[1] and segs[1].map == plan.zone) then segs = { { map = plan.zone } } end
    local xp, clock = 0, 0
    for n, seg in ipairs(segs) do
        local p = n == 1 and plan or seg.plan
        if not p or not p.steps or #p.steps == 0 then break end
        local steps = p.steps
        local first = steps[1]
        local start = n == 1 and ((first.t or 0) - (first.seconds or 0)) or (clock + (seg.travel or 0))
        if start > w then return xp, w end
        -- where this zone is left: the first zone by its key (the plan may have moved on since
        -- the itinerary was made), later ones by their step
        local upto = #steps
        if segs[n + 1] then
            if n == 1 then
                for i, key in ipairs(p.order or {}) do
                    if key == seg.leaveKey then upto = i break end
                end
            elseif seg.leave then
                upto = math.min(seg.leave, #steps)
            end
        end
        local got = 0
        for i = 1, upto do
            local s = steps[i]
            local t = start + ((s.t or 0) - (first.t or 0) + (first.seconds or 0))
            if t > w then
                if s.kind == "work" and (s.seconds or 0) > 0 then
                    local done = (w - (t - s.seconds)) / s.seconds
                    if done > 0 then got = got + (s.xp or 0) * math.min(1, done) end
                end
                return xp + got, w
            end
            got, clock = s.cumXP or got, t
        end
        xp = xp + got
    end
    return xp, math.min(clock, w)
end

local function trim(list, keep)
    while #list > keep do table.remove(list, 1) end
end

--- Write down what the path promises now. `active` is the active clock, info = { level, zone,
--- plan, itinerary }. Nothing is written within FORECAST_EVERY of the last forecast for the same
--- zone, or without a route. Returns the forecast, or nil.
function Play.Forecast(active, info)
    if not store or not number(active) or type(info) ~= "table" then return nil end
    local plan = info.plan
    if not plan or not plan.steps or #plan.steps == 0 or not info.zone then return nil end
    local list = store.forecasts
    local prev = list[#list]
    if prev and prev.s == store.session and prev.z == info.zone and active - prev.a < Play.FORECAST_EVERY then return nil end
    local f = { s = store.session, a = active, lv = info.level, z = info.zone, x = total, p = {}, c = {}, g = {}, d = {}, n = 0 }
    for j, w in ipairs(Play.WINDOWS) do
        local xp, covered = Play.Within(plan, info.itinerary, w)
        f.p[j], f.c[j] = math.floor(xp + 0.5), math.floor(covered + 0.5)
    end
    list[#list + 1] = f
    trim(list, Play.KEEP_FORECASTS)
    open[#open + 1] = f
    return f
end

--- The active clock moved on: forecasts whose window has passed get the XP earned since.
function Play.Tick(active)
    if not store or not number(active) or #open == 0 then return end
    for i = #open, 1, -1 do
        local f, left = open[i], false
        for j, w in ipairs(Play.WINDOWS) do
            if f.g[j] == nil then
                if active >= f.a + w then
                    f.g[j], f.d[j] = total - f.x, f.n
                else
                    left = true
                end
            end
        end
        if not left then table.remove(open, i) end
    end
end

--- Something happened (see the kinds above). `data` is copied into the event. Returns the event.
function Play.Event(active, kind, data)
    if not store or type(kind) ~= "string" then return nil end
    local e = { s = store.session, a = number(active) and active or 0, k = kind }
    for key, value in pairs(data or {}) do
        if e[key] == nil and (number(value) or type(value) == "string" or type(value) == "boolean") then e[key] = value end
    end
    store.events[#store.events + 1] = e
    trim(store.events, Play.KEEP_EVENTS)
    if Play.OVERRULED[kind] then
        for _, f in ipairs(open) do f.n = f.n + 1 end
    end
    return e
end

--- The log in figures:
---   { forecasts, events, windows = { { seconds, n, promised, got (sums over the settled forecasts
---     whose path covered the window), followed = { n, promised, got } (those without an
---     overruling in the window), short = forecasts whose path ran out before the window's end } },
---     kinds = { [kind] = count }, zoneBanner (zone changes the banner had suggested), zoneBack
---     (zone changes back to a zone the path had just left), snapshots (events with a snapshot),
---     hearthPlanned (hearth events where the route had the stone; only when there is one) }
function Play.Summary(s)
    s = s or store
    local out = { forecasts = 0, events = 0, windows = {}, kinds = {}, zoneBanner = 0, zoneBack = 0, snapshots = 0 }
    if type(s) ~= "table" then return out end
    for j, w in ipairs(Play.WINDOWS) do
        out.windows[j] = { seconds = w, n = 0, promised = 0, got = 0, short = 0, followed = { n = 0, promised = 0, got = 0 } }
    end
    for _, f in ipairs(s.forecasts or {}) do
        out.forecasts = out.forecasts + 1
        for j, w in ipairs(Play.WINDOWS) do
            local row = out.windows[j]
            local got, promised = f.g and f.g[j], f.p and f.p[j]
            if number(got) and number(promised) then
                if (f.c and f.c[j] or 0) < w * Play.COVERED then
                    row.short = row.short + 1
                else
                    row.n, row.promised, row.got = row.n + 1, row.promised + promised, row.got + got
                    if (f.d and f.d[j] or 0) == 0 then
                        local fo = row.followed
                        fo.n, fo.promised, fo.got = fo.n + 1, fo.promised + promised, fo.got + got
                    end
                end
            end
        end
    end
    for _, e in ipairs(s.events or {}) do
        out.events = out.events + 1
        out.kinds[e.k] = (out.kinds[e.k] or 0) + 1
        if e.k == "zone" and e.banner then out.zoneBanner = out.zoneBanner + 1 end
        if e.k == "zone" and e.back then out.zoneBack = out.zoneBack + 1 end
        if e.k == "hearth" and e.planned then out.hearthPlanned = (out.hearthPlanned or 0) + 1 end
        if e.snap then out.snapshots = out.snapshots + 1 end
    end
    return out
end

local function minutes(seconds) return string.format("%d min", math.floor(seconds / 60 + 0.5)) end
local function share(got, promised) return promised > 0 and string.format("%d%%", got / promised * 100 + 0.5) or "-" end
local function times(n) return n == 1 and "once" or (n .. " times") end

--- The log as lines of text (for /ls play).
function Play.Describe(s)
    local sum = Play.Summary(s)
    local lines = { string.format("Play log: %d forecast%s, %d event%s.", sum.forecasts, sum.forecasts == 1 and "" or "s",
        sum.events, sum.events == 1 and "" or "s") }
    local any = false
    for _, row in ipairs(sum.windows) do
        if row.n > 0 then
            any = true
            local line = string.format("  next %s: %d XP promised, %d got (%s) over %d forecast%s", minutes(row.seconds),
                row.promised / row.n + 0.5, row.got / row.n + 0.5, share(row.got, row.promised), row.n, row.n == 1 and "" or "s")
            local fo = row.followed
            if fo.n > 0 and fo.n < row.n then
                line = line .. string.format("; %s when you kept to the plan (%d)", share(fo.got, fo.promised), fo.n)
            elseif fo.n == 0 then
                line = line .. "; never without a change of plan"
            end
            lines[#lines + 1] = line
        end
        if row.short > 0 then
            lines[#lines + 1] = string.format("  (%d more for %s where the path ran out before the end: not counted)", row.short, minutes(row.seconds))
        end
    end
    if not any then
        lines[#lines + 1] = string.format("  Nothing to compare yet: a forecast is checked after %s of play.", minutes(Play.WINDOWS[1]))
    end
    local k = sum.kinds
    local parts = {}
    if (k.zone or 0) > 0 then
        local extra = {}
        if sum.zoneBanner > 0 then extra[#extra + 1] = sum.zoneBanner .. " after the banner" end
        if sum.zoneBack > 0 then extra[#extra + 1] = sum.zoneBack .. " back to a zone the path had left" end
        parts[#parts + 1] = "changed zone by hand " .. times(k.zone) .. (#extra > 0 and (" (" .. table.concat(extra, ", ") .. ")") or "")
    end
    if (k.skip or 0) > 0 then parts[#parts + 1] = string.format("skipped %d quest%s", k.skip, k.skip == 1 and "" or "s") end
    if (k.order or 0) > 0 then parts[#parts + 1] = string.format("turned in %d out of order", k.order) end
    if (k.extra or 0) > 0 then parts[#parts + 1] = string.format("turned in %d the route did not have", k.extra) end
    if (k.hearth or 0) > 0 then
        parts[#parts + 1] = string.format("used the hearthstone %s (%d where the route had it)", times(k.hearth), sum.hearthPlanned or 0)
    end
    if #parts > 0 then lines[#lines + 1] = "  You " .. table.concat(parts, ", ") .. "." end
    local auto = {}
    if (k.moved or 0) > 0 then auto[#auto + 1] = "the path moved on " .. times(k.moved) end
    if (k.banner or 0) > 0 then auto[#auto + 1] = "the banner came up " .. times(k.banner) end
    if #auto > 0 then lines[#lines + 1] = "  By itself: " .. table.concat(auto, ", ") .. "." end
    if sum.snapshots > 0 then
        lines[#lines + 1] = string.format("  %d of these have a snapshot (tests/replay.lua).", sum.snapshots)
    end
    return lines
end
