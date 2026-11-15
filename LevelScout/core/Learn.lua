-- core/Learn.lua: what the planner learns from play, one sample at a time. Pure Lua: no game API.
--
-- Small online estimators. Each starts from the database figure and moves towards what this
-- player really sees as samples come in; none keeps the samples themselves.
--
--   Pace        how this character's seconds per kill, per collected item and per object compare
--               with players' typical pace (Cost.Pace). Kept as the running mean of
--               log(own / typical), so one number carries over from one level band to the next,
--               and the last PACE_MEMORY samples count most (gear and talents change the pace).
--   Speed       yards per second while travelling, against the typical run speed (Cost.Pace's
--               r): the same kind of running mean, with a heavier prior and tighter limits.
--   Drop rates  kills and drops counted per item and mob: a Beta-Binomial estimate whose prior
--               is the database rate, worth DROP_PRIOR_KILLS kills.
--               Before that, each data source gets one shared correction ("its rates run 20%
--               high"): the drops seen against the drops its rates promised, over all its items.
--   Step times  a linear model of log(seconds taken / seconds planned) for a finished route
--               step, on what kind of step it was (Learn.StepFeatures), fitted by recursive
--               least squares with forgetting. It corrects what pace alone cannot: elites,
--               groups, level difference, travel.

local _, ns = ...

local Learn = {}
ns.Learn = Learn

local log, exp, min, max, abs = math.log, math.exp, math.min, math.max, math.abs

Learn.PACE_KEYS = { c = true, i = true, o = true } -- the Cost.Pace values that are learned
Learn.PACE_PRIOR = 3        -- the typical pace counts as this many samples of our own
Learn.PACE_MEMORY = 20      -- samples after which older ones fade (each new one then weighs 1/20)
Learn.PACE_MAX_RATIO = 4    -- a sample counts as at most this many times faster or slower than typical
Learn.DROP_PRIOR_KILLS = 20 -- the database drop rate counts as this many kills of our own
Learn.DROP_UNKNOWN_RATE = 0.35  -- where the estimate starts when the database has no rate...
Learn.DROP_UNKNOWN_KILLS = 4    -- ...worth this many kills...
Learn.DROP_UNKNOWN_MIN = 5      -- ...and used only after this many kills of our own

--- One pace sample: `ratio` = own seconds / typical seconds for `key` ("c", "i" or "o").
--- `store` is { [key] = { n = samples counted (capped), m = mean of log(ratio) } }.
--- Returns true when the sample was taken.
function Learn.AddPace(store, key, ratio)
    if type(store) ~= "table" or not Learn.PACE_KEYS[key] then return false end
    if type(ratio) ~= "number" or ratio ~= ratio or ratio <= 0 or ratio == math.huge then return false end
    local x = log(max(1 / Learn.PACE_MAX_RATIO, min(Learn.PACE_MAX_RATIO, ratio)))
    local rec = store[key]
    if type(rec) ~= "table" or type(rec.n) ~= "number" or type(rec.m) ~= "number" then
        rec = { n = 0, m = 0 }
        store[key] = rec
    end
    rec.n = min(rec.n + 1, Learn.PACE_MEMORY)
    rec.m = rec.m + (x - rec.m) / rec.n
    return true
end

--- What to multiply the typical pace for `key` by: 1 with no samples, the character's own
--- ratio once it has many.
function Learn.PaceFactor(store, key)
    local rec = type(store) == "table" and store[key] or nil
    if type(rec) ~= "table" or type(rec.n) ~= "number" or type(rec.m) ~= "number" or rec.n <= 0 then return 1 end
    -- (the mean is within the sample limits by construction; a damaged saved value is held to them too)
    local limit = log(Learn.PACE_MAX_RATIO)
    local m = rec.m == rec.m and max(-limit, min(limit, rec.m)) or 0
    return exp(m * rec.n / (rec.n + Learn.PACE_PRIOR))
end

Learn.SPEED_KEY = "r"       -- where the travel speed is kept in the pace store (Cost.Pace's key for it)
Learn.RIDE_KEY = "rm"       -- the same for the speed on a mount (kept apart: a walk is costed on foot or mounted)
Learn.RIDE_TYPICAL = 11.2   -- yards per second on a mount when the data does not say (60% faster than running)
Learn.RIDE_MIN = 3          -- samples on a mount before the character counts as riding
Learn.SPEED_PRIOR = 12      -- the typical speed counts as this many samples of our own (two minutes of travel)
Learn.SPEED_MEMORY = 60     -- samples after which older ones fade (ten minutes of travel)
Learn.SPEED_MAX_RATIO = 2.5 -- a sample counts as at most this many times faster or slower than typical

--- One travel-speed sample: `ratio` = own yards per second / typical yards per second, over a
--- stretch of steady travel (see ns.Tracker.OnMove). Kept in the pace store under "r" in the
--- same form as the other paces: { n = samples counted (capped), m = mean of log(ratio) }.
--- Returns true when the sample was taken.
function Learn.AddSpeed(store, ratio, key)
    key = key or Learn.SPEED_KEY
    if type(store) ~= "table" then return false end
    if type(ratio) ~= "number" or ratio ~= ratio or ratio <= 0 or ratio == math.huge then return false end
    local x = log(max(1 / Learn.SPEED_MAX_RATIO, min(Learn.SPEED_MAX_RATIO, ratio)))
    local rec = store[key]
    if type(rec) ~= "table" or type(rec.n) ~= "number" or type(rec.m) ~= "number" then
        rec = { n = 0, m = 0 }
        store[key] = rec
    end
    rec.n = min(rec.n + 1, Learn.SPEED_MEMORY)
    rec.m = rec.m + (x - rec.m) / rec.n
    return true
end

--- What to multiply the typical travel speed by: 1 with no samples, the character's own ratio
--- once it has many; within 1/SPEED_MAX_RATIO to SPEED_MAX_RATIO whatever the store holds.
function Learn.SpeedFactor(store, key)
    local rec = type(store) == "table" and store[key or Learn.SPEED_KEY] or nil
    if type(rec) ~= "table" or type(rec.n) ~= "number" or type(rec.m) ~= "number" or rec.n <= 0 or rec.m ~= rec.m then return 1 end
    local limit = log(Learn.SPEED_MAX_RATIO)
    local n = min(rec.n, Learn.SPEED_MEMORY)
    return exp(max(-limit, min(limit, rec.m)) * n / (n + Learn.SPEED_PRIOR))
end

--- Yards per second on a mount: `typical` (nil: RIDE_TYPICAL) adjusted to what this character
--- has ridden, or nil while it has not been seen riding (fewer than RIDE_MIN samples).
function Learn.RideSpeed(store, typical)
    local rec = type(store) == "table" and store[Learn.RIDE_KEY] or nil
    if type(rec) ~= "table" or type(rec.n) ~= "number" or rec.n < Learn.RIDE_MIN then return nil end
    return (typical or Learn.RIDE_TYPICAL) * Learn.SpeedFactor(store, Learn.RIDE_KEY)
end

--- The typical pace (from Cost.Pace) adjusted to this character. Returns a new table.
function Learn.Pace(base, store)
    local out = {}
    for key, value in pairs(base) do
        if Learn.PACE_KEYS[key] then
            out[key] = value * Learn.PaceFactor(store, key)
        elseif key == Learn.SPEED_KEY then
            out[key] = value * Learn.SpeedFactor(store)
        else
            out[key] = value
        end
    end
    return out
end

local function dropKey(itemId, npcId) return itemId .. ":" .. npcId end

--- Count `kills` of a mob made while the item was wanted, and `drops` of the item from it.
--- `store` is { ["itemId:npcId"] = { k = kills, d = drops } }.
function Learn.AddDrops(store, itemId, npcId, kills, drops)
    if type(store) ~= "table" or not itemId or not npcId then return false end
    local key = dropKey(itemId, npcId)
    local rec = store[key]
    if type(rec) ~= "table" then
        rec = { k = 0, d = 0 }
        store[key] = rec
    end
    rec.k = (tonumber(rec.k) or 0) + (kills or 0)
    rec.d = (tonumber(rec.d) or 0) + (drops or 0)
    return true
end

--- Our own counts for an item from a mob: kills, drops (0, 0 when there are none).
function Learn.DropCounts(store, itemId, npcId)
    local rec = type(store) == "table" and store[dropKey(itemId, npcId)] or nil
    if type(rec) ~= "table" then return 0, 0 end
    return tonumber(rec.k) or 0, tonumber(rec.d) or 0
end

Learn.DROP_BIAS_PRIOR = 10  -- a source's rates count as right for this many expected drops
Learn.DROP_BIAS_MAX = 2     -- a source is corrected by at most this factor, up or down

--- Per data source, over every item and mob we have counts for: the drops its rates promised
--- for our kills (x) and the drops we saw (d). `lookup(itemId, npcId)` returns the database rate
--- and its source's name. Returns { [source] = { x, d } }.
function Learn.SourceBias(store, lookup)
    local out, keys = {}, {}
    for key in pairs(type(store) == "table" and store or {}) do keys[#keys + 1] = tostring(key) end
    table.sort(keys) -- sums of fractions depend on the order: the same counts always give the same answer
    for _, key in ipairs(keys) do
        local rec = store[key]
        local itemId, npcId = key:match("^(%d+):(%d+)$")
        local kills = type(rec) == "table" and tonumber(rec.k) or 0
        if itemId and kills > 0 then
            local rate, source = lookup(tonumber(itemId), tonumber(npcId))
            if rate and source then
                local t = out[source]
                if not t then
                    t = { x = 0, d = 0 }
                    out[source] = t
                end
                t.x = t.x + kills * rate
                t.d = t.d + min(tonumber(rec.d) or 0, kills)
            end
        end
    end
    return out
end

--- What to multiply a source's rates by: (drops seen + 10) / (drops promised + 10), within
--- 1/2 to 2. `lessX` and `lessD` leave one item's own counts out, so that they are not used
--- twice (once here, once as that item's own estimate).
function Learn.SourceFactor(bias, source, lessX, lessD)
    local t = type(bias) == "table" and source and bias[source] or nil
    if not t then return 1 end
    local x, d = max(0, t.x - (lessX or 0)), max(0, t.d - (lessD or 0))
    local weight = Learn.DROP_BIAS_PRIOR
    return max(1 / Learn.DROP_BIAS_MAX, min(Learn.DROP_BIAS_MAX, (d + weight) / (x + weight)))
end

--- The drop chance to plan with: the database rate `prior` (0..1 or nil), corrected for its
--- source (`source`, `bias` from Learn.SourceBias; optional), then moved towards our own counts.
--- Returns the rate (nil when nothing is known) and true when what we saw changed it.
function Learn.DropRate(prior, store, itemId, npcId, source, bias)
    local kills, drops = Learn.DropCounts(store, itemId, npcId)
    drops = min(drops, kills) -- two items from one kill still count as one drop
    local changed = false
    if prior and bias then
        local factor = Learn.SourceFactor(bias, source, kills * prior, drops)
        if abs(factor - 1) > 1e-9 then
            prior, changed = max(0.01, min(1, prior * factor)), true
        end
    end
    if kills <= 0 then return prior, changed end
    if prior then
        local weight = Learn.DROP_PRIOR_KILLS
        return (prior * weight + drops) / (weight + kills), true
    end
    if kills < Learn.DROP_UNKNOWN_MIN then return nil, false end
    local weight = Learn.DROP_UNKNOWN_KILLS
    return (Learn.DROP_UNKNOWN_RATE * weight + drops) / (weight + kills), true
end

-- Step times: recursive least squares.

Learn.STEP_FEATURES = { "at the stop", "kill", "collect", "use", "travel", "elite", "group size", "mob level", "many kills" }
Learn.STEP_VERSION = 2      -- a model saved with other features starts again
Learn.STEP_PRIOR = 0.05     -- how far a weight may be from 0 before any step is seen (its variance)
Learn.STEP_DOUBT = 0.2      -- the most a weight is ever doubted again, however long its feature goes unseen
Learn.STEP_FORGET = 0.99    -- older steps count this much less with each new one (about 100 remembered)
Learn.STEP_CLIP = log(3)    -- one step moves the model as if it were at most 3 times off
Learn.STEP_MAX_RATIO = 4    -- a step counts as taking at most 4 times (or a quarter of) the planned time
Learn.STEP_MAX_FACTOR = 2   -- the planned time is corrected by at most this factor, up or down
local NF = #Learn.STEP_FEATURES

--- What the model is told about a step. `s` has the step log's fields: k (kind), w (action),
--- p (planned seconds), pt (the travel part), g (group size), e (elite), d (mob level minus own
--- level), n (planned kills).
--- A step is travel, then what is done at the stop. Feature 5 is travel's share of the planned
--- time; every other feature describes the stop and is weighted by the stop's share. So the
--- model is one factor for travel and one factor for each kind of stop, which is how the
--- planner uses it (Learn.TravelFactor, Learn.TalkFactor, Learn.WorkFactor).
function Learn.StepFeatures(s)
    local work = s.k == "work"
    local p = tonumber(s.p) or 0
    local travel = p > 0 and max(0, min(1, (tonumber(s.pt) or 0) / p)) or 0
    local stop = 1 - travel
    return {
        stop,
        (work and s.w == "kill") and stop or 0,
        (work and s.w == "collect") and stop or 0,
        (work and s.w == "use") and stop or 0,
        travel,
        (work and s.e) and stop or 0,
        work and stop * log(max(1, tonumber(s.g) or 1)) or 0,
        work and stop * max(-4, min(4, tonumber(s.d) or 0)) / 4 or 0,
        work and stop * log(max(1, tonumber(s.n) or 1)) / log(10) or 0,
    }
end

local function stepModel(store)
    if type(store) ~= "table" then return nil end
    local ok = store.v == Learn.STEP_VERSION and type(store.w) == "table" and #store.w == NF
        and type(store.R) == "table" and #store.R == NF * NF
    if not ok then -- new, or saved by a version with other features: start again
        store.w, store.R, store.P, store.n, store.v = {}, {}, nil, 0, Learn.STEP_VERSION
        for i = 1, NF do store.w[i] = 0 end
        for i = 1, NF * NF do store.R[i] = ((i - 1) % (NF + 1) == 0) and 1 / Learn.STEP_PRIOR or 0 end
    end
    return store
end

-- Solve R k = x for k (R is symmetric and positive definite; Gaussian elimination on a copy).
local function solve(R, x)
    local a, k = {}, {}
    for i = 1, NF * NF do a[i] = R[i] end
    for i = 1, NF do k[i] = x[i] end
    for col = 1, NF do
        local pivot = col
        for row = col + 1, NF do
            if abs(a[(row - 1) * NF + col]) > abs(a[(pivot - 1) * NF + col]) then pivot = row end
        end
        if abs(a[(pivot - 1) * NF + col]) < 1e-12 then return nil end
        if pivot ~= col then
            for j = 1, NF do
                a[(col - 1) * NF + j], a[(pivot - 1) * NF + j] = a[(pivot - 1) * NF + j], a[(col - 1) * NF + j]
            end
            k[col], k[pivot] = k[pivot], k[col]
        end
        for row = col + 1, NF do
            local f = a[(row - 1) * NF + col] / a[(col - 1) * NF + col]
            if f ~= 0 then
                for j = col, NF do a[(row - 1) * NF + j] = a[(row - 1) * NF + j] - f * a[(col - 1) * NF + j] end
                k[row] = k[row] - f * k[col]
            end
        end
    end
    for row = NF, 1, -1 do
        local sum = k[row]
        for j = row + 1, NF do sum = sum - a[(row - 1) * NF + j] * k[j] end
        k[row] = sum / a[(row - 1) * NF + row]
    end
    return k
end

--- One finished step: it took `taken` seconds where `planned` were planned (before any
--- correction by this model). `store` is { w = weights, R = what is known about them (the
--- information matrix, row by row), n = steps seen }.
function Learn.AddStep(store, features, planned, taken)
    local m = stepModel(store)
    if not m or type(features) ~= "table" or #features ~= NF then return false end
    if type(planned) ~= "number" or type(taken) ~= "number" or not (planned > 0 and taken > 0) then return false end
    local w, R, x = m.w, m.R, features
    local limit = log(Learn.STEP_MAX_RATIO)
    local y = max(-limit, min(limit, log(taken / planned)))
    local predicted = 0
    for i = 1, NF do predicted = predicted + w[i] * x[i] end
    local err = max(-Learn.STEP_CLIP, min(Learn.STEP_CLIP, y - predicted))
    -- What is known fades a little with every step, but only down to a floor (STEP_DOUBT): a
    -- feature that is not seen for a long time (no elites for ten levels) does not swing wildly
    -- when it returns. Then this step is added:  R = forget R + (1 - forget) floor + x x'
    local keep, floor_ = Learn.STEP_FORGET, (1 - Learn.STEP_FORGET) / Learn.STEP_DOUBT
    for i = 1, NF do
        for j = 1, NF do
            local k = (i - 1) * NF + j
            R[k] = keep * R[k] + x[i] * x[j] + (i == j and floor_ or 0)
        end
    end
    -- the weights move by gain x error, where gain = inverse(R) x
    local gain = solve(R, x)
    if not gain then return false end
    for i = 1, NF do w[i] = w[i] + gain[i] * err end
    m.n = (tonumber(m.n) or 0) + 1
    return true
end

--- What to multiply a step's planned seconds by: 1 before anything is learned, and within
--- 1/2 to 2 always.
function Learn.StepFactor(store, features)
    if type(store) ~= "table" or store.v ~= Learn.STEP_VERSION or type(store.w) ~= "table" or #store.w ~= NF
        or #features ~= NF then return 1 end
    local sum = 0
    for i = 1, NF do sum = sum + (tonumber(store.w[i]) or 0) * features[i] end
    local limit = log(Learn.STEP_MAX_FACTOR)
    return exp(max(-limit, min(limit, sum)))
end

--- The factor for travel time alone.
function Learn.TravelFactor(store)
    return Learn.StepFactor(store, Learn.StepFeatures({ p = 1, pt = 1 }))
end

--- The factor for the time at a stop where a quest is accepted or turned in.
function Learn.TalkFactor(store)
    return Learn.StepFactor(store, Learn.StepFeatures({ k = "accept", p = 1, pt = 0 }))
end

--- The factor for the time working at a stop: s = { w = action, e = elite, g = group size,
--- d = mob level minus own level, n = kills }.
function Learn.WorkFactor(store, s)
    return Learn.StepFactor(store, Learn.StepFeatures({ k = "work", w = s.w, p = 1, pt = 0, e = s.e, g = s.g, d = s.d, n = s.n }))
end
