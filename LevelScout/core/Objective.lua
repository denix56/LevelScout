-- core/Objective.lua: what the search maximises. Pure Lua.
-- An evaluator judges a route; the search loop (ns.Search) asks it for a number after every
-- round. Two kinds of number (Objective.MODE):
--   "worth"      today's R:worth: the best XP per second over a prefix, plus a little for the
--                rest of the route.
--   "dinkelbach" for a rate R held fixed for a while, the XP the route makes over what that
--                rate would have made in the same time (a sum of per-stop terms and one running
--                maximum, instead of a ratio). R is raised to the best rate found, every EPOCH
--                rounds, so the target keeps up with the search. It is reported as R + F / H
--                (H = Planner.MIN_HORIZON), a number in XP per second like worth, so the
--                loop's relative margins mean the same in both modes.
--   "surplus"    (Planner.GOAL = "surplus", chosen automatically then) the route's value over a
--                rate R held fixed for the whole search (the route's r.goalR, from ctx.altRate):
--                max over leaving points of XP - R * time (R:surplus), reported as R + V / H like
--                dinkelbach. The best route is kept by this same number, and so is the final choice.
-- The number is only what a round is judged by while searching: the loop keeps its best route
-- by today's worth (the evaluator's second result), and the final choices are today's.
-- Polish (Objective.POLISH) moves short runs of stops after a repair, judged by the same number,
-- and re-works only the stretch of the route that moved (ev:commit, ev:evalFrom).
local _, ns = ...
local Objective = {}
ns.Objective = Objective

local max, min, abs, huge = math.max, math.min, math.abs, math.huge

Objective.MODE = "worth"     -- or "dinkelbach"
Objective.EPOCH = 20         -- rounds between raising R (dinkelbach)
Objective.POLISH = false     -- polish after a repair
Objective.POLISH_RADIUS = 2  -- stops either side of a placed stop that are tried too
Objective.POLISH_REACH = 6   -- how far from its place a run may be moved
Objective.POLISH_SEG = 2     -- longest run moved together
Objective.POLISH_MAX_TRIES = 40 -- moves looked at per round
Objective.SHORTCUT = true    -- evalFrom: stop at the point where the rest of the route is the reference's
Objective.CHECK = false      -- tests: verify what evalFrom assumes about the route

local BROKEN = -1            -- what a route with a stop before its level is worth to the search (dinkelbach)

local Ev = {}
Ev.__index = Ev

local function planner() return ns.Planner end

--- An evaluator for route `r` with `overhead` seconds before the first stop.
function Objective.New(r, overhead)
    local mode = Objective.MODE
    if r.goalR then mode = "surplus" elseif mode == "surplus" then mode = "worth" end -- the route's goal decides
    local ev = setmetatable({ r = r, overhead = overhead, mode = mode }, Ev)
    if mode == "surplus" then ev.R = r.goalR end
    if ev.mode == "dinkelbach" then
        local c = r:prefix(overhead)
        local n = c.n
        ev.R = c.OK[n] and c.BR[n] or 0
    end
    return ev
end

-- F_R of a route given by the XP and time at each paying stop, its end, and the rate R.
local function surplus(R, xs, ts, Xn, Tn)
    local P = planner()
    local H = P.MIN_HORIZON
    local g = -R * H
    for k = 1, #xs do
        local v = xs[k] - R * max(ts[k], H)
        if v > g then g = v end
    end
    return g + P.TAIL_WEIGHT * (Xn - P.PRUNE_RATIO * R * Tn)
end

--- obj (larger is better; units depend on the mode), worth (today's R:worth, XP/s), memo
--- (opaque: lets objOf value this route again later without restoring it)
function Ev:eval()
    if self.mode == "surplus" then
        local o = self.r:goalWorth(self.overhead)
        return o, o, o
    end
    if self.mode ~= "dinkelbach" then
        local w = self.r:worth(self.overhead)
        return w, w, w
    end
    local P = planner()
    local H, tau, rho = P.MIN_HORIZON, P.TAIL_WEIGHT, P.PRUNE_RATIO
    local c = self.r:prefix(self.overhead)
    local n = c.n
    local X, T = c.X, c.T
    if not c.OK[n] then
        -- a stop before its level: today's worth is what the XP before it gives
        local worth = 0 + tau * (c.xpBad - rho * 0 * T[c.firstBad - 1]) / H
        return BROKEN, worth, { ok = false }
    end
    local score = c.BR[n]
    local worth = score + tau * (X[n] - rho * score * T[n]) / H
    local xs, ts, k = {}, {}, 0
    for i = 2, n do
        if X[i] > X[i - 1] then k = k + 1; xs[k], ts[k] = X[i], T[i] end
    end
    local memo = { ok = true, xs = xs, ts = ts, Xn = X[n], Tn = T[n], score = score }
    return self.R + surplus(self.R, xs, ts, X[n], T[n]) / H, worth, memo
end

--- obj of a route remembered by its memo, under the current parameters
function Ev:objOf(memo)
    if self.mode ~= "dinkelbach" then return memo end
    if not memo.ok then return BROKEN end
    return self.R + surplus(self.R, memo.xs, memo.ts, memo.Xn, memo.Tn) / planner().MIN_HORIZON
end

--- the magnitude used for relative margins around `ref`
function Ev:scale(ref)
    if self.mode == "surplus" then return max(abs(ref), self.R) end
    if self.mode ~= "dinkelbach" then return ref end
    return max(abs(ref), self.R)
end

--- the search loop calls this every round; true when the objective's parameters changed
function Ev:newEpoch(round, bestMemo)
    if self.mode ~= "dinkelbach" or round % Objective.EPOCH ~= 0 then return false end
    local score = bestMemo and bestMemo.score
    if score and score > self.R then
        self.R, self.ref = score, nil
        return true
    end
    return false
end

---------------------------------------------------------------------------------------------
-- Working out a changed stretch of the route
---------------------------------------------------------------------------------------------

--- Take the route as it is as the reference for `evalFrom`.
function Ev:commit()
    local r, R = self.r, self.R
    local c = r:prefix(self.overhead)
    local route, n = r.route, c.n
    local node = {}
    for i = 1, n do node[i] = route[i] end
    local ref = { c = c, node = node, T = c.T, X = c.X, P = c.P, D = c.D, OK = c.OK, BR = c.BR, n = n,
        OKn = c.OK[n], xpBad = c.xpBad, R = R }
    if self.mode == "dinkelbach" then
        local H = planner().MIN_HORIZON
        local G, SG, X, T, OK = { [1] = -R * H }, { [n + 1] = -huge }, c.X, c.T, c.OK
        for i = 2, n do
            local g = G[i - 1]
            if OK[i] and X[i] > X[i - 1] then
                local v = X[i] - R * max(T[i], H)
                if v > g then g = v end
            end
            G[i] = g
        end
        for i = n, 2, -1 do
            local g = SG[i + 1]
            if OK[i] and X[i] > X[i - 1] then
                local v = X[i] - R * T[i]
                if v > g then g = v end
            end
            SG[i] = g
        end
        ref.G, ref.SG = G, SG
    end
    self.ref = ref
end

--- The objective of the route as it stands now, given that it equals the reference at indices
--- 1 .. p - 1. `same` (optional): the first index from which the route is the reference's stop
--- for stop (any move of a run inside the route). Returns what `eval` would, as obj.
function Ev:evalFrom(p, same)
    local r, ref, R = self.r, self.ref, self.R
    local P = planner()
    local H, tau, rho = P.MIN_HORIZON, P.TAIL_WEIGHT, P.PRUNE_RATIO
    local route, n = r.route, #r.route
    local dink = self.mode == "dinkelbach"
    if Objective.CHECK then
        assert(ref and ref.n == n and ref.R == R, "evalFrom: no reference for this route")
        for i = 1, p - 1 do assert(route[i] == ref.node[i], "evalFrom: the route differs before " .. p) end
        if same then
            for i = same, n do assert(route[i] == ref.node[i], "evalFrom: the route differs after " .. same) end
        end
    end
    local i0 = p - 1
    local t, xp, pool, d, ok = ref.T[i0], ref.X[i0], ref.P[i0], ref.D[i0], ref.OK[i0]
    local ups = r.ups
    local nextUp = ups[d + 1]
    local gated = r.gated
    local g, br = dink and ref.G[i0] or nil, ref.BR[i0]
    local xpBad = (not ok) and ref.xpBad or nil
    local shortcut = dink and same and Objective.SHORTCUT
    local ops = ref.node
    for i = p, n do
        local node = route[i]
        if shortcut and i > same and i < n and node == ops[i] and route[i - 1] == ops[i - 1] then
            -- from here on the route is the reference's, one stop behind or ahead in time only?
            if ok == ref.OK[i - 1] and d == ref.D[i - 1] and abs(xp - ref.X[i - 1]) <= 1e-6
                and abs(pool - ref.P[i - 1]) <= 1e-6 then
                local dt = t - ref.T[i - 1]
                if ref.T[i] + dt >= H then -- every later stop is past the first hour
                    r.work = r.work + (i - p)
                    if not ref.OKn or not ok then return BROKEN end
                    local best = max(g, ref.SG[i] - R * dt)
                    return R + (best + tau * (ref.X[n] - rho * R * (ref.T[n] + dt))) / H
                end
            end
        end
        if ok and gated and P.GateOf(node) > d then ok, xpBad = false, xp end
        local s, gain = r:value(node, nil, d)
        if node.kind == "W" then
            local b = min(gain, pool)
            pool, gain = pool - b, gain + b
        end
        t = t + r:tt(route[i - 1], node) + s
        xp = xp + gain
        while nextUp and xp >= nextUp do d = d + 1; nextUp = ups[d + 1] end
        if ok and gain > 0 then
            local denom = max(t, H)
            if dink then
                local v = xp - R * denom
                if v > g then g = v end
            else
                local rate = xp / denom
                if rate > br then br = rate end
            end
        end
    end
    r.work = r.work + (n - p + 1)
    if dink then
        if not ok then return BROKEN end
        return R + (g + tau * (xp - rho * R * t)) / H
    end
    if not ok then return tau * xpBad / H end
    return br + tau * (xp - rho * br * t) / H
end

---------------------------------------------------------------------------------------------
-- Polish
---------------------------------------------------------------------------------------------

--- After a repair (called by the search loop before the round is judged): try moving short runs of
--- the stops the repair placed, and their neighbours, a little earlier or later, and keep a move
--- when the objective rises. `touched` = the stops placed during the repair (some may be gone).
--- Draws no random numbers; calls the checkpoint.
function Objective.Polish(r, ev, touched, S)
    if ev.mode == "surplus" then return end -- (polish is not built for the surplus goal)
    if not Objective.POLISH or not touched or #touched == 0 then return end
    local route, pos = r.route, r.pos
    local radius, reach, seg = Objective.POLISH_RADIUS, Objective.POLISH_REACH, Objective.POLISH_SEG
    local at = {}
    for _, node in ipairs(touched) do
        local i = pos[node]
        if i and i > 1 then
            for j = max(2, i - radius), min(#route, i + radius) do at[j] = true end
        end
    end
    local tries = {}
    for j = 2, #route do
        if at[j] then tries[#tries + 1] = route[j] end -- by position: the same order every time
    end
    ev:commit()
    if not ev.ref.OKn then return end -- a stop before its level: the round will be thrown out anyway
    local base = ev:evalFrom(2)
    local budget = Objective.POLISH_MAX_TRIES
    local checkpoint = S and S.sc and S.sc.checkpoint
    for _, node in ipairs(tries) do
        for len = 1, seg do
            local i = pos[node]
            if not i or i + len - 1 > #route then break end
            local lo, hi = r:runBounds(i, len)
            lo, hi = max(lo, i - 1 - reach, 1), min(hi, i - 1 + reach)
            local bestP, bestObj = nil, base + 1e-9 * ev:scale(base)
            for p = lo, hi do
                if p ~= i - 1 and budget > 0 then
                    budget = budget - 1
                    local v = r:shift(i, len, p)
                    local o = ev:evalFrom(min(i, p + 1), max(i + len, p + len + 1))
                    if o > bestObj then bestP, bestObj = p, o end
                    r:unshift(i, len, p, v)
                end
            end
            if bestP then
                r:shift(i, len, bestP)
                ev:commit()
                base = bestObj
            end
            if checkpoint then checkpoint() end
        end
        if budget <= 0 then break end
    end
end

return Objective
