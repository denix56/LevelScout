-- core/Search.lua: the search over a zone's route (adaptive large-neighbourhood search). Pure Lua.
-- Each round takes a few quests out of the route and puts them back, or leaves them out when they
-- no longer pay. A round is kept when the route is worth more; early on also when it is worth
-- slightly less, so the search can leave a dead end (the allowance shrinks to nothing). Ways to
-- choose what to take out, and how eagerly to put back quests with few good places, are picked by
-- how well each has worked so far. Random numbers are seeded by the input: the same situation
-- always gives the same plan.
local _, ns = ...
local Search = {}
ns.Search = Search

local max, min, floor, huge = math.max, math.min, math.floor, math.huge

Search.SEED_SALT = 0       -- bench only: a different random sequence (0 = as before)
Search.STREAM = "sequential" -- "sequential": one random sequence for the whole search (the shipped plans);
                             -- "rounds": round t draws from a sequence of its own, started from the seed and t
                             -- only (common random numbers, bench CRN=1; docs/planner.md "How a change is judged")
Search.CURVE = false         -- bench only: the result keeps the best worth after every round (curve[0..rounds])
Search.REGRET = { 0, 1, 2.5 }

-- Defaults set from the bench (docs/planner.md, "Search loop"): "outsiders once" on; record-to-record
-- acceptance, early stop, restarts and the extra removals off (rrt cost 1-2% of the itinerary's XP).
-- The bench changes them with SET=.
Search.ACCEPT = "anneal"      -- "anneal": allowance shrinking to nothing; "rrt": within RRT_MARGIN of the best
Search.RRT_MARGIN = 0.005     -- record-to-record: a round is kept when within this share of the best
Search.RESTART_AFTER = nil    -- go back to the best route after this many rounds without a new best
Search.STALL_ROUNDS = nil     -- stop after this many rounds without a new best (nil = never)
Search.STALL_ROUNDS_WARM = 25 -- the same for a search started from an earlier plan
Search.MIN_ROUNDS = 20        -- no early stop before this round
Search.MIN_ROUNDS_WARM = 10
Search.STALL_FROM = 0         -- no early stop before this share of the rounds (0.75 with annealing)
Search.EXTRA_OPS = false      -- more ways to take quests out: true = chain, camp, detours; "all" adds one place;
                              -- or a comma list of short names (chain,camp,detour,place,credit; in the bench's
                              -- SET= join them with +)
Search.WEIGHT_CARRY = 0.5     -- saved operator weights count this much, 1 - this towards 1
Search.OUTSIDERS = "once"     -- "once": in a repair, quests that were already out are tried on the first pass only;
                              -- "contested": the same, except those in at least CONTESTED_SHARE of the routes kept so far
Search.CONTESTED_SHARE = 0.25 -- OUTSIDERS = "contested": (times in + 1) / (routes kept + 2) at least this
Search.BANDIT = false         -- choosing removal and regret strength: false = adaptive weights (today); "beta" = Beta
                              -- posteriors, success per work; "uniform" = all alike (a control)
Search.BANDIT_PRIOR = 2       -- "beta": prior worth this many rounds at the success rate of all rounds so far
Search.BANDIT_DISCOUNT = 0.98 -- "beta": evidence fades by this every round
Search.BANDIT_COST = 1        -- "beta": value = success / (work / mean work) ^ this (1 = per work unit, 0 = per round)
Search.BANDIT_PRIORS = nil    -- "beta": optional fitted counts in the format of weights.bandit (tests/bench.lua ARMS=1)
Search.QUEST_PRIOR = 0.5      -- the "credit" removal: prior worth this many successes at the rate of all quests
Search.QUEST_DISCOUNT = 0.99  -- the "credit" removal: per-quest evidence fades by this every round
Search.ARM_STATS = false      -- bench/debug: per removal and strength, rounds, outcomes, work (result.arms)

local function stopsOf(m)
    local nodes = {}
    if m.P then nodes[#nodes + 1] = m.P end
    for _, w in ipairs(m.W or {}) do nodes[#nodes + 1] = w end
    if m.T then nodes[#nodes + 1] = m.T end
    return nodes
end

-- S = the running search: S.r, S.sc, S:rand(n), S:takeOut(m)
Search.DESTROY = {
    { name = "any quests", fn = function(S, list, k)
        for _ = 1, k do S:takeOut(list[S:rand(#list)]) end
    end },
    { name = "quests close together", fn = function(S, list, k) -- they compete for the same places
        local r = S.r
        local from = stopsOf(list[S:rand(#list)])
        local near = {}
        for _, m in ipairs(list) do
            local d = huge
            for _, a in ipairs(stopsOf(m)) do
                for _, b in ipairs(from) do
                    local t = a == b and 0 or r:tt(a, b)
                    if t < d then d = t end
                end
            end
            near[#near + 1] = { m, d }
        end
        table.sort(near, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1].id < b[1].id end)
        for i = 1, min(k, #near) do S:takeOut(near[i][1]) end
    end },
    { name = "the lowest paying", fn = function(S, list, k) -- the quests that pay least for their time
        local r = S.r
        local t0, x0 = r:totals()
        local poor = {}
        for _, m in ipairs(list) do
            local t1, x1 = r:totals(m)
            poor[#poor + 1] = { m, (x0 - x1) / max(t0 - t1, 1) }
            if S.sc.checkpoint then S.sc.checkpoint() end
        end
        table.sort(poor, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1].id < b[1].id end)
        for _ = 1, k do
            local i = floor(S:rand() ^ 3 * #poor) + 1 -- mostly from the poor end
            S:takeOut(poor[i][1])
        end
    end },
    { name = "one stretch of the route", fn = function(S, _, k) -- everything on one stretch of the route
        local route = S.r.route
        local first = 1 + S:rand(max(1, #route - 1))
        local hit = {}
        for p = first, min(#route, first + 2 * k - 1) do
            local node = route[p]
            if node.kind == "W" then
                for _, req in ipairs(node.reqs) do hit[#hit + 1] = req.quest end
            elseif node.quest then
                hit[#hit + 1] = node.quest
            end
        end
        for _, m in ipairs(hit) do S:takeOut(m) end
    end },
    -- (the operators below are used only with Search.EXTRA_OPS)
    { name = "a whole quest chain", short = "chain", fn = function(S, list, k)
        local r = S.r
        local m = list[S:rand(#list)]
        local seen, order, head = { [m] = true }, { m }, 1
        local cap = max(k, 3) * 2
        while head <= #order and #order < cap do
            local q = order[head]
            head = head + 1
            for _, lists in ipairs({ q.deps or {}, q.dependents or {} }) do
                for _, d in ipairs(lists) do
                    if r.routed[d] and not seen[d] and #order < cap then
                        seen[d] = true
                        order[#order + 1] = d
                    end
                end
            end
        end
        if #order == 1 then -- no chain: its closest neighbours go with it
            local from, near = stopsOf(m), {}
            for _, o in ipairs(list) do
                if o ~= m then
                    local d = huge
                    for _, a in ipairs(stopsOf(o)) do
                        for _, b in ipairs(from) do
                            local t = a == b and 0 or r:tt(a, b)
                            if t < d then d = t end
                        end
                    end
                    near[#near + 1] = { o, d }
                end
            end
            table.sort(near, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1].id < b[1].id end)
            for i = 1, min(k - 1, #near) do order[#order + 1] = near[i][1] end
        end
        for _, q in ipairs(order) do S:takeOut(q) end
    end },
    { name = "everything at one camp", short = "camp", fn = function(S, list, _)
        local route = S.r.route
        local ws = {}
        for _, node in ipairs(route) do
            if node.kind == "W" and node.key then ws[#ws + 1] = node end
        end
        if #ws == 0 then S:takeOut(list[S:rand(#list)]); return end
        local w = ws[S:rand(#ws)]
        local base = w.key:match("^[^#]+")
        local hit = {}
        local atW = {}
        for _, req in ipairs(w.reqs or {}) do atW[req.quest] = true end
        for _, m in ipairs(list) do -- (list is in id order)
            local here = atW[m]
            if not here then
                for _, task in ipairs(m.tasks or {}) do
                    if task.key == base or task.key == base .. "#" .. m.id then here = true; break end
                end
            end
            if here and #hit < 8 then hit[#hit + 1] = m end
        end
        for _, m in ipairs(hit) do S:takeOut(m) end
    end },
    { name = "the longest detours", short = "detour", fn = function(S, list, k)
        local r = S.r
        local route, pos = r.route, r.pos
        local function detour(node)
            local p = pos[node]
            if not p or p < 2 then return 0 end
            local prev, nxt = route[p - 1], route[p + 1]
            if not nxt then return r:tt(prev, node) end
            return r:tt(prev, node) + r:tt(node, nxt) - r:tt(prev, nxt)
        end
        local rank = {}
        for _, m in ipairs(list) do
            local sum = 0
            for _, node in ipairs(stopsOf(m)) do
                local d = detour(node)
                if node.kind == "W" and node.reqs and #node.reqs > 1 then d = d / #node.reqs end
                sum = sum + d
            end
            rank[#rank + 1] = { m, sum }
            if S.sc.checkpoint then S.sc.checkpoint() end
        end
        table.sort(rank, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1].id < b[1].id end)
        for _ = 1, k do
            local i = floor(S:rand() ^ 3 * #rank) + 1 -- mostly from the long end
            S:takeOut(rank[i][1])
        end
    end },
    { name = "everything at one place", short = "place", fn = function(S, list, _)
        local route = S.r.route
        local Geo = ns.Geo
        local ps = {}
        for _, node in ipairs(route) do
            if node.kind == "P" or node.kind == "T" then ps[#ps + 1] = node end
        end
        if #ps == 0 then S:takeOut(list[S:rand(#list)]); return end
        local at = ps[S:rand(#ps)]
        local reach = 2 * ns.Planner.SAME_PLACE_YARDS
        local near = {}
        for _, m in ipairs(list) do
            local d = huge
            for _, node in ipairs({ m.P or false, m.T or false }) do
                if node then
                    local x = node == at and 0 or Geo.Dist(node.loc, at.loc)
                    if x and x < d then d = x end
                end
            end
            if d <= reach then near[#near + 1] = { m, d } end
        end
        table.sort(near, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1].id < b[1].id end)
        for i = 1, min(8, #near) do S:takeOut(near[i][1]) end
    end },
    { name = "the quests worth moving", short = "credit", exportWhenUsed = true, fn = function(S, list, k)
        -- quests drawn by how often taking them out has paid (Search.NewQuestModel); without that
        -- evidence (a test's stub), like "any quests"
        local Q = S.quests
        if not Q then
            for _ = 1, k do S:takeOut(list[S:rand(#list)]) end
            return
        end
        local routed, w, n = S.r.routed, Q.buf, #list
        local total, left = 0, 0
        for i = 1, n do
            local x = Search.QuestMean(Q, list[i])
            w[i], total, left = x, total + x, left + 1
        end
        for _ = 1, k do
            local u = S:rand() -- one draw for each quest asked for, also when none is left
            if left > 0 then
                local x, chosen = u * total, nil
                for i = 1, n do
                    if w[i] > 0 then
                        chosen = i
                        x = x - w[i]
                        if x <= 0 then break end
                    end
                end
                S:takeOut(list[chosen])
                -- the chosen quest, and follow-ups that went with it, are drawn no more
                for i = 1, n do
                    if w[i] > 0 and not routed[list[i]] then
                        total, left, w[i] = total - w[i], left - 1, 0
                    end
                end
            end
        end
    end },
}
Search.BASE_OPS = 4

--- The operator with this name (or short name), for tests.
function Search.Operator(name)
    for _, op in ipairs(Search.DESTROY) do
        if op.name == name or op.short == name then return op end
    end
end

-- Indices into DESTROY of the operators in use: the first four, plus those EXTRA_OPS asks for.
local function activeOps()
    local out = {}
    for i = 1, Search.BASE_OPS do out[i] = i end
    local x = Search.EXTRA_OPS
    if x then
        local want = {}
        if x == true then want = { chain = true, camp = true, detour = true }
        elseif x == "all" then want = { chain = true, camp = true, detour = true, place = true }
        else for w in tostring(x):gmatch("%a+") do want[w] = true end end
        for i = Search.BASE_OPS + 1, #Search.DESTROY do
            if want[Search.DESTROY[i].short] then out[#out + 1] = i end
        end
    end
    return out
end

-- Weights in and out are keyed by name, so operators can be added without breaking saved ones.
-- saved = { destroy = { [name] = w }, regret = { [i] = w } } or nil.
-- Returns dw (array in DESTROY order) and rw (array in REGRET order).
function Search.InitWeights(saved)
    local c = Search.WEIGHT_CARRY or 1
    local function blend(v) -- carried over, pulled towards 1 (an old search's luck is not today's)
        if not v then return 1 end
        return max(0.05, c * v + (1 - c))
    end
    local dw, rw = {}, {}
    for i, op in ipairs(Search.DESTROY) do
        dw[i] = blend(saved and saved.destroy and saved.destroy[op.name])
    end
    for i = 1, #Search.REGRET do
        rw[i] = blend(saved and saved.regret and saved.regret[i])
    end
    return dw, rw
end

function Search.ExportWeights(dw, rw, ops)
    local out = { destroy = {}, regret = {} }
    for i, op in ipairs(Search.DESTROY) do
        local used = true
        if op.exportWhenUsed then -- (left out unless in use: plans without it export what they did before)
            used = false
            for _, j in ipairs(ops or {}) do if j == i then used = true end end
        end
        if used then out.destroy[op.name] = dw[i] end
    end
    for i = 1, #Search.REGRET do out.regret[i] = rw[i] end
    return out
end

-- Pick among the entries `which` (indices; nil = all) by weight.
local function pick(S, weights, which)
    local n = which and #which or #weights
    local total = 0
    for j = 1, n do total = total + weights[which and which[j] or j] end
    local x = S:rand() * total
    for j = 1, n do
        local i = which and which[j] or j
        x = x - weights[i]
        if x <= 0 then return i end
    end
    return which and which[n] or n
end

-- The "credit" removal's evidence about single quests: per quest model m, s[m] and f[m] =
-- credited successes and failures as of round last[m]; S, F = their sums over all quests as of
-- Q.round. Walked only in list or candidate order.
local HYPER_S, HYPER_N = 1, 20 -- before any evidence: taking a quest out pays one time in twenty

local function age(Q, m)
    local last, now = Q.last[m], Q.round
    if last ~= now then
        local d = (Search.QUEST_DISCOUNT or 1) ^ (now - last)
        Q.s[m], Q.f[m], Q.last[m] = Q.s[m] * d, Q.f[m] * d, now
    end
end

--- Saved evidence ("id:s:f;..." in thousandths) for these candidates, times WEIGHT_CARRY.
function Search.NewQuestModel(candidates, saved)
    local c = Search.WEIGHT_CARRY or 1
    local got = Search.DecodeQuests(saved and saved.quests)
    local Q = { s = {}, f = {}, last = {}, S = 0, F = 0, round = 0, buf = {} }
    for _, m in ipairs(candidates) do
        local e = got[m.id]
        local s, f = e and c * e[1] or 0, e and c * e[2] or 0
        Q.s[m], Q.f[m], Q.last[m] = s, f, 0
        Q.S, Q.F = Q.S + s, Q.F + f
    end
    return Q
end

function Search.QuestRound(Q, round)
    local d = (Search.QUEST_DISCOUNT or 1) ^ (round - Q.round)
    Q.round, Q.S, Q.F = round, Q.S * d, Q.F * d
end

--- Posterior mean chance that taking m out lets a round improve the current route.
function Search.QuestMean(Q, m)
    age(Q, m)
    local theta = (Q.S + HYPER_S) / (Q.S + Q.F + HYPER_N)
    local a0 = max(Search.QUEST_PRIOR or 0.5, 0.01)
    return (Q.s[m] + a0) / (Q.s[m] + Q.f[m] + a0 / theta)
end

--- After a round: picked[1..n] = the quests its removal chose; y = 1 when it improved the current route.
--- Noisy-or: a round that did not pay is a failure for each; one that paid is shared by how likely
--- each was to have made it, theta_q / (1 - prod(1 - theta_j)), the rest of its round a failure.
function Search.QuestUpdate(Q, picked, n, y)
    if n == 0 then return end
    local buf = Q.buf
    if y == 1 then
        local miss = 1
        for j = 1, n do
            local x = Search.QuestMean(Q, picked[j])
            buf[j] = x
            miss = miss * (1 - x)
        end
        local hit = 1 - miss
        for j = 1, n do
            local m = picked[j]
            local share = hit > 0 and min(1, buf[j] / hit) or 1 / n
            Q.s[m], Q.f[m] = Q.s[m] + share, Q.f[m] + (1 - share)
            Q.S, Q.F = Q.S + share, Q.F + (1 - share)
        end
    else
        for j = 1, n do
            local m = picked[j]
            age(Q, m)
            Q.f[m] = Q.f[m] + 1
            Q.F = Q.F + 1
        end
    end
end

--- "id:s:f;..." (thousandths, id order; locale-proof, short in a snapshot), nil when nothing to keep.
function Search.EncodeQuests(Q, candidates)
    local parts = {}
    for _, m in ipairs(candidates) do
        age(Q, m)
        local s, f = Q.s[m], Q.f[m]
        if type(m.id) == "number" and m.id >= 0 and m.id == floor(m.id) and s + f >= 0.05 then
            parts[#parts + 1] = string.format("%d:%d:%d", m.id, floor(s * 1000 + 0.5), floor(f * 1000 + 0.5))
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ";")
end

function Search.DecodeQuests(text)
    local out = {}
    if type(text) ~= "string" then return out end
    for id, s, f in text:gmatch("(%d+):(%d+):(%d+)") do
        out[tonumber(id)] = { tonumber(s) / 1000, tonumber(f) / 1000 }
    end
    return out
end

--- OUTSIDERS = "contested": should a quest that was in `timesIn` of the `kept` routes kept so far be
--- tried on every pass of the repair? ((timesIn + 1) / (kept + 2) at least CONTESTED_SHARE)
function Search.IsContested(timesIn, kept)
    return timesIn + 1 >= (Search.CONTESTED_SHARE or 0.25) * (kept + 2)
end

-- BANDIT = "beta": a Beta posterior for each removal and each regret strength.
local function count(v) -- a count read from saved weights: finite and >= 0, else 0
    v = tonumber(v)
    if not v or v ~= v or v < 0 or v == huge then return 0 end
    return v
end

-- Per arm i (operator: index into DESTROY; strength: index into REGRET): discounted counts of
-- rounds that improved the current route (s), did not (f), their work (w), rounds with work (wn).
-- p, v, t2: scratch (no allocation per round).
-- An old weight is the average reward (best 3, better 1, kept 0.3, rejected 0.05) over about 5 rounds
-- (0.8 per round): a round that improved earned about 1.3, one that did not about 0.1.
local OLD_SUCCESS, OLD_FAIL, OLD_ROUNDS = 1.3, 0.1, 5

local function newArms(n)
    local a = { s = {}, f = {}, w = {}, wn = {}, p = {}, v = {}, t2 = {} }
    for i = 1, n do a.s[i], a.f[i], a.w[i], a.wn[i], a.p[i], a.v[i], a.t2[i] = 0, 0, 0, 0, 0, 0, 0 end
    return a
end
local function addCounts(a, i, e, c)
    if type(e) ~= "table" then return end
    a.s[i], a.f[i] = a.s[i] + c * count(e.s), a.f[i] + c * count(e.f)
    a.w[i], a.wn[i] = a.w[i] + c * count(e.w), a.wn[i] + c * count(e.wn)
end
local function addOld(a, i, w, c)
    w = tonumber(w)
    if not w or w ~= w or w == huge or w == -huge then return end
    local p = min(0.99, max(0.01, (w - OLD_FAIL) / (OLD_SUCCESS - OLD_FAIL)))
    local n = OLD_ROUNDS * c
    a.s[i], a.f[i] = a.s[i] + n * p, a.f[i] + n * (1 - p)
end

--- Starting counts: BANDIT_PRIORS (as is), plus saved.bandit times WEIGHT_CARRY, or else the
--- old weights (saved.destroy / saved.regret) as evidence: OLD_ROUNDS x WEIGHT_CARRY rounds.
function Search.InitBandit(saved, ops)
    local c = Search.WEIGHT_CARRY or 1
    local B = { op = newArms(#Search.DESTROY), rg = newArms(#Search.REGRET) }
    local function part(t, key) return type(t) == "table" and type(t[key]) == "table" and t[key] or nil end
    local P = type(Search.BANDIT_PRIORS) == "table" and Search.BANDIT_PRIORS or nil
    local own = part(saved, "bandit")
    local pd, pr, od, orr = part(P, "destroy"), part(P, "regret"), part(own, "destroy"), part(own, "regret")
    local oldD, oldR = (not own) and part(saved, "destroy") or nil, (not own) and part(saved, "regret") or nil
    for _, i in ipairs(ops) do
        local name = Search.DESTROY[i].name
        if pd then addCounts(B.op, i, pd[name], 1) end
        if od then addCounts(B.op, i, od[name], c) end
        if oldD then addOld(B.op, i, oldD[name], c) end
    end
    for i = 1, #Search.REGRET do
        if pr then addCounts(B.rg, i, pr[i], 1) end
        if orr then addCounts(B.rg, i, orr[i], c) end
        if oldR then addOld(B.rg, i, oldR[i], c) end
    end
    return B
end

local function logistic(z) return 1 / (1 + math.exp(-1.702 * z)) end -- about the normal CDF

--- Choice weights into arms.p for the arms `which` (nil = all): each arm's chance of beating the
--- leader (the arm with the best posterior mean per relative work), the leader counting 0.5.
function Search.BanditProbs(arms, which)
    local n = which and #which or #arms.s
    local S, F, W, WN = 0, 0, 0, 0
    for j = 1, n do
        local i = which and which[j] or j
        S, F, W, WN = S + arms.s[i], F + arms.f[i], W + arms.w[i], WN + arms.wn[i]
    end
    local pbar = (S + 1) / (S + F + 2)
    local n0 = max(Search.BANDIT_PRIOR or 2, 0.01)
    local cbar = WN > 0 and max(W / WN, 1) or 1
    local lambda = Search.BANDIT_COST or 0
    local lead, leadV
    for j = 1, n do
        local i = which and which[j] or j
        local a, b = arms.s[i] + n0 * pbar, arms.f[i] + n0 * (1 - pbar)
        local mean = a / (a + b)
        local var = a * b / ((a + b) * (a + b) * (a + b + 1))
        local scale = 1
        if lambda ~= 0 then
            local cost = (arms.w[i] + n0 * cbar) / (arms.wn[i] + n0)
            scale = (max(cost, 1) / cbar) ^ lambda
        end
        arms.v[i], arms.t2[i] = mean / scale, var / (scale * scale)
        if not lead or arms.v[i] > leadV then lead, leadV = i, arms.v[i] end -- ties: the first
    end
    for j = 1, n do
        local i = which and which[j] or j
        if i == lead then
            arms.p[i] = 0.5
        else
            local sd = math.sqrt(arms.t2[i] + arms.t2[lead])
            arms.p[i] = sd > 0 and logistic((arms.v[i] - leadV) / sd) or (arms.v[i] == leadV and 0.5 or 0)
        end
    end
    return arms.p
end

local function observe(arms, which, chosen, y, work, g)
    local n = which and #which or #arms.s
    for j = 1, n do
        local i = which and which[j] or j
        arms.s[i], arms.f[i], arms.w[i], arms.wn[i] = g * arms.s[i], g * arms.f[i], g * arms.w[i], g * arms.wn[i]
    end
    arms.s[chosen], arms.f[chosen] = arms.s[chosen] + y, arms.f[chosen] + (1 - y)
    arms.w[chosen], arms.wn[chosen] = arms.w[chosen] + work, arms.wn[chosen] + 1
end

function Search.BanditUpdate(B, ops, di, ri, y, work)
    local g = Search.BANDIT_DISCOUNT or 1
    observe(B.op, ops, di, y, work, g)
    observe(B.rg, nil, ri, y, work, g)
end

function Search.ExportBandit(B, ops)
    local out = { destroy = {}, regret = {} }
    local function arm(a, i) return { s = a.s[i], f = a.f[i], w = a.w[i], wn = a.wn[i] } end
    for _, i in ipairs(ops) do out.destroy[Search.DESTROY[i].name] = arm(B.op, i) end
    for i = 1, #Search.REGRET do out.regret[i] = arm(B.rg, i) end
    return out
end

-- ARM_STATS: per removal and strength, the rounds and how they ended, their work, quests taken out.
local function newArmStats(ops)
    local function entry() return { n = 0, best = 0, better = 0, kept = 0, rejected = 0, work = 0, picked = 0 } end
    local A = { op = {}, rg = {}, out = { destroy = {}, regret = {} } }
    for _, i in ipairs(ops) do local e = entry(); A.op[i], A.out.destroy[Search.DESTROY[i].name] = e, e end
    for i = 1, #Search.REGRET do local e = entry(); A.rg[i], A.out.regret[i] = e, e end
    return A
end
local function addArm(e, kind, work, picked)
    e.n, e[kind] = e.n + 1, e[kind] + 1
    e.work, e.picked = e.work + work, e.picked + picked
end

--- Should a round's route be kept as the current one? (obj: this round's, curObj: the current's,
--- bestObj: the best's; ev gives the magnitude margins are taken of.)
--- policy "anneal": within T * (1 - round/rounds) of the current (the allowance shrinks to nothing);
--- policy "rrt": within RRT_MARGIN of the best (record-to-record travel; needs no schedule).
function Search.Accept(policy, obj, curObj, bestObj, round, rounds, ev)
    if policy == "rrt" then
        return obj >= bestObj - Search.RRT_MARGIN * ev:scale(bestObj)
    end
    local T = ns.Planner.SEARCH_TEMPERATURE * (1 - round / rounds)
    return obj >= curObj - T * ev:scale(curObj)
end

--- Run the search on sc.r (already filled): sc = { r, candidates, overhead, rounds, work, seed,
--- weights, warm, checkpoint, progress, fill, takeOut, restore, frame } (see Planner.Plan).
--- Leaves the route at the best one found. Returns { rounds, work, worth, weights, stopped, curve, arms }
--- (curve only with CURVE, arms only with ARM_STATS).
function Search.Run(sc)
    local r = sc.r
    local S = { r = r, sc = sc, seed = sc.seed + 7 * Search.SEED_SALT }
    -- "rounds": round t starts its draws at R_t = R_(t-1) * 48271 mod (2^31 - 1), R_0 = the seed
    -- (exact in doubles: R * 48271 < 2^47; rounds 1-200000 never share a draw among their first 256)
    local roundSeed
    if Search.STREAM == "rounds" then
        roundSeed = S.seed % 2147483647
        if roundSeed == 0 then roundSeed = 1 end
    end
    function S:rand(n)
        self.seed = (self.seed * 16807) % 2147483647
        if n then return self.seed % n + 1 end
        return self.seed / 2147483647
    end
    local removed
    local function record(q) -- debug trace: names and map points of what goes out
        removed.names[#removed.names + 1] = q.name
        for _, l in ipairs({ q.pickup or false, q.turnin or false }) do
            if l then removed.points[#removed.points + 1] = { l.map, l.mx, l.my } end
        end
        for _, w in ipairs(q.W or {}) do
            if w.loc then removed.points[#removed.points + 1] = { w.loc.map, w.loc.mx, w.loc.my } end
        end
    end
    function S:takeOut(m)
        if self.track and r.routed[m] then -- the quests the removal chose, not the follow-ups that go with them
            self.npicked = self.npicked + 1
            self.picked[self.npicked] = m
        end
        sc.takeOut(m, sc.frame and record or nil)
    end

    local dw, rw = Search.InitWeights(sc.weights)
    local ops = activeOps()
    -- learning from rounds; with the defaults B, onesD, onesR, Q, arms and acc are all nil
    local B = Search.BANDIT == "beta" and Search.InitBandit(sc.weights, ops) or nil
    local onesD, onesR
    if Search.BANDIT == "uniform" then
        onesD, onesR = {}, {}
        for i = 1, #Search.DESTROY do onesD[i] = 1 end
        for i = 1, #Search.REGRET do onesR[i] = 1 end
    end
    local Q
    for _, i in ipairs(ops) do
        if Search.DESTROY[i].short == "credit" then Q = Search.NewQuestModel(sc.candidates, sc.weights) end
    end
    S.quests = Q
    local arms = Search.ARM_STATS and newArmStats(ops) or nil
    if Q or arms then S.track, S.picked, S.npicked = true, {}, 0 end
    local acc -- (OUTSIDERS = "contested") routes kept so far, and in how many each quest was
    if Search.OUTSIDERS == "contested" then
        acc = { n = 1, inn = {} }
        for _, m in ipairs(sc.candidates) do acc.inn[m] = r.routed[m] and 1 or 0 end
    end
    local ev = ns.Objective.New(r, sc.overhead)
    local obj, worth, memo = ev:eval()
    local cur = { snap = r:snapshot(), obj = obj, memo = memo }
    local best = { snap = cur.snap, obj = obj, worth = worth, memo = memo }
    local curve = Search.CURVE and { [0] = best.worth } or nil
    local w0, done, sinceBest, stopped = r.work, 0, 0, false
    local stall = sc.warm and Search.STALL_ROUNDS_WARM or Search.STALL_ROUNDS
    local minRounds = sc.warm and Search.MIN_ROUNDS_WARM or Search.MIN_ROUNDS
    for round = 1, sc.rounds do
        if roundSeed then
            roundSeed = (roundSeed * 48271) % 2147483647
            S.seed = roundSeed
        end
        if sc.work and r.work - w0 >= sc.work then break end
        if sc.progress then sc.progress("search", round, sc.rounds) end
        local list = {}
        for _, m in ipairs(sc.candidates) do
            if r.routed[m] then list[#list + 1] = m end
        end
        if #list < 2 then break end
        done = round
        if S.track then S.npicked = 0 end
        if Q then Search.QuestRound(Q, round) end
        local k = min(8, 1 + S:rand(max(2, floor(#list * 0.3))))
        local di, ri
        if B then -- one draw per choice, as below
            di = pick(S, Search.BanditProbs(B.op, ops), ops)
            ri = pick(S, Search.BanditProbs(B.rg))
        elseif onesD then
            di = pick(S, onesD, ops)
            ri = pick(S, onesR)
        else
            di, ri = pick(S, dw, ops), pick(S, rw)
        end
        local work0 = r.work
        -- what a quest must pay to go back in: the same share of the route's rate under
        -- which a quest is dropped anyway (the rate before anything was taken out)
        local t, x = r:totals()
        removed = { names = {}, points = {} }
        r.touched = {}
        Search.DESTROY[di].fn(S, list, k)
        local fresh
        if Search.OUTSIDERS then -- the quests this round took out (everything else out was out before)
            fresh = {}
            for _, m in ipairs(list) do
                if not r.routed[m] then fresh[m] = true end
            end
            if acc then -- "contested": out before, but in enough of the routes kept
                for _, m in ipairs(sc.candidates) do
                    if not r.routed[m] and not fresh[m] and Search.IsContested(acc.inn[m], acc.n) then fresh[m] = true end
                end
            end
        end
        sc.fill(Search.REGRET[ri], ns.Planner.PRUNE_RATIO * x / max(t, 1), fresh)
        local touched = r.touched
        r.touched = nil
        ns.Objective.Polish(r, ev, touched, S)
        obj, worth, memo = ev:eval()
        local roundWork = r.work - work0
        -- judge
        local kind
        if worth > best.worth * (1 + 1e-9) then kind = "best"
        elseif obj > cur.obj + 1e-9 * ev:scale(cur.obj) then kind = "better"
        elseif Search.Accept(Search.ACCEPT, obj, cur.obj, best.obj, round, sc.rounds, ev) then kind = "kept"
        else kind = "rejected" end
        if kind == "best" then sinceBest = 0 else sinceBest = sinceBest + 1 end
        local restart = Search.RESTART_AFTER and sinceBest > 0 and sinceBest % Search.RESTART_AFTER == 0
        if sc.frame then
            sc.frame(kind, { round = round, rounds = sc.rounds, took = Search.DESTROY[di].name,
                regret = Search.REGRET[ri], out = removed.points, names = removed.names,
                best = max(best.worth, worth) * 3600, restart = restart or nil })
        end
        local reward = 0.05
        if kind == "rejected" then
            if not restart then sc.restore(cur.snap) end
        else
            cur = { snap = r:snapshot(), obj = obj, memo = memo }
            if kind == "best" then
                best = { snap = cur.snap, obj = obj, worth = worth, memo = memo }
                reward = 3
            elseif kind == "better" then reward = 1
            else reward = 0.3 end
            if acc then -- a route kept: count its quests
                acc.n = acc.n + 1
                for _, m in ipairs(sc.candidates) do
                    if r.routed[m] then acc.inn[m] = acc.inn[m] + 1 end
                end
            end
        end
        local epoch
        if restart then -- back to the best route (the next round starts from it)
            sc.restore(best.snap)
            cur = { snap = best.snap, obj = best.obj, memo = best.memo }
            epoch = ev:newEpoch(round, best.memo)
        else
            epoch = ev:newEpoch(round, best.memo)
        end
        if epoch then
            cur.obj, best.obj = ev:objOf(cur.memo), ev:objOf(best.memo)
        end
        dw[di], rw[ri] = 0.8 * dw[di] + 0.2 * reward, 0.8 * rw[ri] + 0.2 * reward -- (always: the saved weights)
        local y = (kind == "best" or kind == "better") and 1 or 0
        if B then Search.BanditUpdate(B, ops, di, ri, y, roundWork) end
        if Q then Search.QuestUpdate(Q, S.picked, S.npicked, y) end
        if arms then
            addArm(arms.op[di], kind, roundWork, S.npicked)
            addArm(arms.rg[ri], kind, roundWork, S.npicked)
        end
        if curve then curve[round] = best.worth end
        if sc.checkpoint then sc.checkpoint() end
        if stall and sinceBest >= stall and round >= minRounds and round >= Search.STALL_FROM * sc.rounds then
            stopped = true
            break
        end
    end
    sc.restore(best.snap)
    local weights = Search.ExportWeights(dw, rw, ops)
    if B then weights.bandit = Search.ExportBandit(B, ops) end
    if Q then weights.quests = Search.EncodeQuests(Q, sc.candidates) end
    return { rounds = done, work = r.work - w0, worth = best.worth, weights = weights, stopped = stopped,
        curve = curve, arms = arms and arms.out or nil }
end

return Search
