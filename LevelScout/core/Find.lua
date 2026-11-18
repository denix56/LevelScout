-- core/Find.lua: matching what the player types against quest names, forgiving about case,
-- punctuation, spaces and a few typos. Pure Lua. Used by Data.FindQuests (the Quests tab's
-- search box).

local _, ns = ...

local Find = {}
ns.Find = Find

-- Lower case, letters and digits only, single spaces.
local function norm(s)
    s = tostring(s or ""):lower():gsub("'", ""):gsub("[^%w]+", " ")
    return (s:gsub("^ +", ""):gsub(" +$", ""))
end
Find.Normalize = norm

local normCache = {} -- [name] = { words, squashed }: every quest name is prepared once
local function prepared(name)
    local p = normCache[name]
    if not p then
        local n = norm(name)
        local words = {}
        for w in n:gmatch("%S+") do words[#words + 1] = w end
        p = { words = words, squashed = (n:gsub(" ", "")) }
        normCache[name] = p
    end
    return p
end

--- Edit distance between a and b (a letter put in, left out, changed, or two swapped), or
--- limit + 1 as soon as it is sure to be more than `limit`.
function Find.Distance(a, b, limit)
    local la, lb = #a, #b
    if math.abs(la - lb) > limit then return limit + 1 end
    local prev2, prev, cur = nil, {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur = { [0] = i }
        local low = i
        local ca = a:byte(i)
        for j = 1, lb do
            local cb = b:byte(j)
            local cost = ca == cb and 0 or 1
            local v = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if prev2 and i > 1 and j > 1 and ca == b:byte(j - 1) and a:byte(i - 1) == cb then
                v = math.min(v, prev2[j - 2] + 1)
            end
            cur[j] = v
            if v < low then low = v end
        end
        if low > limit then return limit + 1 end
        prev2, prev = prev, cur
    end
    return prev[lb]
end

-- Typos allowed in a word of this length.
local function allowed(len)
    if len <= 3 then return 0 end
    if len <= 6 then return 1 end
    return 2
end

--- What the player typed, ready for Find.Score; nil when it is too short to look for.
function Find.Query(text)
    local n = norm(text)
    local squashed = n:gsub(" ", "")
    if #squashed < 2 then return nil end
    local words = {}
    for w in n:gmatch("%S+") do words[#words + 1] = w end
    return { words = words, squashed = squashed }
end

--- How well a quest name matches the query: 0 not at all, higher is better (1000: the name
--- itself). In order: the name; the query inside it (spaces and case aside); the whole name
--- with a few typos; every word of the query at the start of a word of the name, or within a
--- few typos of one (or of its start).
function Find.Score(query, name)
    local p = prepared(name)
    local qs, ns_ = query.squashed, p.squashed
    if ns_ == qs then return 1000 end
    local at = ns_:find(qs, 1, true)
    if at then return 900 - math.min(at - 1, 40) * 2 - math.min(#ns_ - #qs, 50) end
    if #qs >= 5 then
        local d = Find.Distance(qs, ns_, allowed(#qs))
        if d <= allowed(#qs) then return 800 - 60 * d end
    end
    local total = 0
    for _, qw in ipairs(query.words) do
        local limit, best = allowed(#qw), nil
        for _, nw in ipairs(p.words) do
            local d
            if nw:sub(1, #qw) == qw then
                d = 0
            else
                d = Find.Distance(qw, nw, limit)
                -- a word typed in part, with a typo: against the start of the name's word, one
                -- letter longer or shorter too (a letter left out or doubled)
                for extra = -1, 1 do
                    local len = #qw + extra
                    if d > limit and len >= 2 and #nw > len then d = math.min(d, Find.Distance(qw, nw:sub(1, len), limit)) end
                end
            end
            if d <= limit and (not best or d < best) then best = d end
            if best == 0 then break end
        end
        if not best then return 0 end -- every word of the query must be found
        total = total + 100 - 30 * best
    end
    return math.floor(total / #query.words * 7 / 10) -- (up to 700: under a match of the whole)
end
