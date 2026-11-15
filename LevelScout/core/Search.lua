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
                              -- or a comma list of short names (chain,camp,detour,place)
Search.WEIGHT_CARRY = 0.5     -- saved operator weights count this much, 1 - this towards 1
Search.OUTSIDERS = "once"     -- "once": in a repair, quests that were already out are tried on the first pass only

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

function Search.ExportWeights(dw, rw)
    local out = { destroy = {}, regret = {} }
    for i, op in ipairs(Search.DESTROY) do out.destroy[op.name] = dw[i] end
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
--- Leaves the route at the best one found. Returns { rounds, work, worth, weights }.
function Search.Run(sc)
    local r = sc.r
    local S = { r = r, sc = sc, seed = sc.seed + 7 * Search.SEED_SALT }
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
        sc.takeOut(m, sc.frame and record or nil)
    end

    local dw, rw = Search.InitWeights(sc.weights)
    local ops = activeOps()
    local ev = ns.Objective.New(r, sc.overhead)
    local obj, worth, memo = ev:eval()
    local cur = { snap = r:snapshot(), obj = obj, memo = memo }
    local best = { snap = cur.snap, obj = obj, worth = worth, memo = memo }
    local w0, done, sinceBest, stopped = r.work, 0, 0, false
    local stall = sc.warm and Search.STALL_ROUNDS_WARM or Search.STALL_ROUNDS
    local minRounds = sc.warm and Search.MIN_ROUNDS_WARM or Search.MIN_ROUNDS
    for round = 1, sc.rounds do
        if sc.work and r.work - w0 >= sc.work then break end
        if sc.progress then sc.progress("search", round, sc.rounds) end
        local list = {}
        for _, m in ipairs(sc.candidates) do
            if r.routed[m] then list[#list + 1] = m end
        end
        if #list < 2 then break end
        done = round
        local k = min(8, 1 + S:rand(max(2, floor(#list * 0.3))))
        local di, ri = pick(S, dw, ops), pick(S, rw)
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
        end
        sc.fill(Search.REGRET[ri], ns.Planner.PRUNE_RATIO * x / max(t, 1), fresh)
        local touched = r.touched
        r.touched = nil
        ns.Objective.Polish(r, ev, touched, S)
        obj, worth, memo = ev:eval()
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
        dw[di], rw[ri] = 0.8 * dw[di] + 0.2 * reward, 0.8 * rw[ri] + 0.2 * reward
        if sc.checkpoint then sc.checkpoint() end
        if stall and sinceBest >= stall and round >= minRounds and round >= Search.STALL_FROM * sc.rounds then
            stopped = true
            break
        end
    end
    sc.restore(best.snap)
    return { rounds = done, work = r.work - w0, worth = best.worth, weights = Search.ExportWeights(dw, rw), stopped = stopped }
end

return Search
