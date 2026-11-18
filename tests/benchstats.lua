-- tests/benchstats.lua: the statistics of tests/bench.lua (pure Lua 5.1, no addon).
-- Paired % differences to base, clustered by character: Student t quantiles, the clustered
-- standard error, the variance split, the noise-aware character guard, the verdict, power.
local S = {}
local sqrt, floor, ceil, log, huge, min, max = math.sqrt, math.floor, math.ceil, math.log, math.huge, math.min, math.max

--- P(|T| <= t) for Student's t with integer df (Abramowitz & Stegun 26.7.3 and 26.7.4).
function S.central(t, df)
    if t <= 0 then return 0 end
    df = min(floor(df), 1000)
    local th = math.atan(t / sqrt(df))
    local s, c = math.sin(th), math.cos(th)
    local c2 = c * c
    if df % 2 == 0 then
        local term, sum = 1, 1
        for k = 2, df - 2, 2 do term = term * c2 * (k - 1) / k; sum = sum + term end
        return s * sum
    end
    if df == 1 then return 2 * th / math.pi end
    local term, sum = 1, 1
    for k = 3, df - 2, 2 do term = term * c2 * (k - 1) / k; sum = sum + term end
    return 2 / math.pi * (th + s * c * sum)
end

--- The p quantile of Student's t (0.5 < p < 1), df >= 1 (above 1000 taken as 1000), by bisection.
function S.tq(p, df)
    assert(p > 0.5 and p < 1 and df >= 1, "tq: p in (0.5, 1), df >= 1")
    df = min(floor(df), 1000)
    local target, lo, hi = 2 * p - 1, 0, 1
    while S.central(hi, df) < target do hi = hi * 2 end
    for _ = 1, 100 do
        local mid = (lo + hi) / 2
        if S.central(mid, df) < target then lo = mid else hi = mid end
    end
    return (lo + hi) / 2
end

--- chars = { { label, n = salts, a = { [s] = config's figure }, b = { [s] = base's figure } }, ... }
--- (a pair counts when both are there and b > 0). opts = { alpha = 0.05, looks = 1 }.
function S.clustered(chars, opts)
    opts = opts or {}
    local alpha, looks = opts.alpha or 0.05, opts.looks or 1
    local st = { C = 0, pairs = 0, same = 0, perChar = {}, harmed1 = 0, harmed2 = 0 }
    local sumMeans, ss, dfw, invN = 0, 0, 0, 0
    local acc = { a = { ss = 0, df = 0 }, b = { ss = 0, df = 0 }, d = { ss = 0, df = 0 } }
    local function add(into, xs)
        if #xs < 2 then return end
        local m = 0
        for _, x in ipairs(xs) do m = m + x end
        m = m / #xs
        for _, x in ipairs(xs) do into.ss = into.ss + (x - m) ^ 2 end
        into.df = into.df + #xs - 1
    end
    for _, ch in ipairs(chars) do
        local ds, la, lb, ld = {}, {}, {}, {}
        for s = 1, ch.n or #ch.b do
            local a, b = ch.a[s], ch.b[s]
            if a and b and b > 0 then
                ds[#ds + 1] = (a / b - 1) * 100
                st.pairs = st.pairs + 1
                if a == b then st.same = st.same + 1 end
                if a > 0 then
                    la[#la + 1], lb[#lb + 1] = 100 * log(a), 100 * log(b)
                    ld[#ld + 1] = la[#la] - lb[#lb]
                end
            end
        end
        if #ds > 0 then
            local m = 0
            for _, d in ipairs(ds) do m = m + d end
            m = m / #ds
            for _, d in ipairs(ds) do ss = ss + (d - m) ^ 2 end
            dfw, invN = dfw + #ds - 1, invN + 1 / #ds
            st.C = st.C + 1
            st.perChar[st.C] = { label = ch.label, mean = m, n = #ds }
            sumMeans = sumMeans + m
        end
        add(acc.a, la); add(acc.b, lb); add(acc.d, ld)
    end
    local C = st.C
    if C == 0 then return st end
    st.mean = sumMeans / C
    st.worst = huge
    for _, pc in ipairs(st.perChar) do
        if pc.mean < st.worst then st.worst, st.worstLabel = pc.mean, pc.label end
    end
    st.dfw = dfw
    st.msw = dfw > 0 and ss / dfw or nil
    if C >= 2 then
        local vb = 0
        for _, pc in ipairs(st.perChar) do vb = vb + (pc.mean - st.mean) ^ 2 end
        vb = vb / (C - 1)
        st.se = sqrt(vb / C)
        st.df = C - 1
        st.tcrit = S.tq(1 - alpha / 2 / looks, st.df)
        st.bar = st.tcrit * st.se
        -- variance components (one-way random effects, moment estimates)
        local meanInv = invN / C
        st.s2s = st.msw or 0
        st.s2c = max(0, vb - st.s2s * meanInv)
        st.partSalt = st.s2s * meanInv / C
        st.partChar = st.s2c / C
    end
    -- a character is harmed by more than h% when its mean is below -h and below 0 beyond its noise
    if st.msw and st.msw > 0 then st.g = S.tq(1 - alpha / (looks * C), dfw) else st.guardPoint = true end
    for _, pc in ipairs(st.perChar) do
        local beyond = st.guardPoint or (pc.mean + st.g * sqrt(st.msw / pc.n) < 0)
        if pc.mean < -1 and beyond then st.harmed1 = st.harmed1 + 1 end
        if pc.mean < -2 and beyond then st.harmed2 = st.harmed2 + 1 end
    end
    -- salt-to-salt noise within a character (100 x log, pooled) and the correlation of base and config
    if acc.a.df > 0 and acc.b.df > 0 then
        local vA, vB, vD = acc.a.ss / acc.a.df, acc.b.ss / acc.b.df, acc.d.ss / acc.d.df
        st.sdA, st.sdB, st.sdD = sqrt(vA), sqrt(vB), sqrt(vD)
        if vA > 0 and vB > 0 then st.rho = (vA + vB - vD) / (2 * sqrt(vA * vB)) end
    end
    return st
end

function S.verdict(st)
    if st.C == 0 then return "no pairs" end
    if st.same == st.pairs then return "identical" end
    if not st.se then return "too few characters" end
    if st.mean < -st.bar or st.harmed2 > 0 then return "worse" end
    if st.mean > st.bar and st.harmed1 == 0 then return "better" end
    return "no clear difference"
end

--- The standard error with C2 characters and S2 salts each, from the variance components.
function S.project(st, C2, S2)
    return sqrt(st.s2c / C2 + st.s2s / (C2 * S2))
end

--- What it takes to detect `delta` points with probability `power` (two-sided alpha):
--- { se = the SE needed with today's characters, salts = salts needed with today's characters
---   (nil: not reachable), chars = characters needed with today's salts, charsUnlimited = with
---   salts unlimited (nil: more than 10000) }.
function S.need(st, delta, power, alpha)
    delta, power, alpha = delta or 0.5, power or 0.8, alpha or 0.05
    local function m(C2) return S.tq(1 - alpha / 2, C2 - 1) + S.tq(power, C2 - 1) end
    local C, Snow = st.C, st.pairs / st.C
    local out = { se = delta / m(C) }
    local room = C * out.se ^ 2 - st.s2c
    if room > 0 then out.salts = max(1, ceil(st.s2s / room)) end
    local function chars(s2s)
        for C2 = 2, 10000 do
            if sqrt((st.s2c + s2s) / C2) * m(C2) <= delta then return C2 end
        end
    end
    out.chars = chars(st.s2s / Snow)
    out.charsUnlimited = chars(0)
    return out
end

--- The p quantile of a sorted list (nearest rank).
function S.quantile(sorted, p)
    return sorted[max(1, ceil(p * #sorted))]
end

return S
