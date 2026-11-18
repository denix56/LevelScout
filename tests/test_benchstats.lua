-- tests/test_benchstats.lua: tests/benchstats.lua, the statistics of the bench (pure Lua, no addon).
local H, M = ...
local test, eq, ok, near = H.test, H.eq, H.ok, H.near
local _ = M
local BS = require("benchstats")

-- chars from per-character lists of base figures and the config's figures
local function chars(bs, as)
    local out = {}
    for i = 1, #bs do out[i] = { label = "c" .. i, n = #bs[i], a = as[i], b = bs[i] } end
    return out
end
-- base 1000 everywhere; the config's figure is 1000 * (1 + d / 100) for each % difference d
local function fromDiffs(ds)
    local bs, as = {}, {}
    for i, row in ipairs(ds) do
        bs[i], as[i] = {}, {}
        for s, d in ipairs(row) do bs[i][s], as[i][s] = 1000, 1000 * (1 + d / 100) end
    end
    return chars(bs, as)
end

H.suite("Bench statistics", function()
    test("t quantiles match the tables", function()
        near(BS.tq(0.975, 1), 12.7062, 1e-3)
        near(BS.tq(0.975, 2), 4.3027, 1e-3)
        near(BS.tq(0.975, 7), 2.3646, 1e-3)
        near(BS.tq(0.975, 30), 2.0423, 1e-3)
        near(BS.tq(0.8, 7), 0.8960, 1e-3)
        near(BS.tq(1 - 0.05 / 6, 7), 3.1276, 1e-3)
        near(BS.tq(0.99375, 32), 2.6468, 1e-3)
        near(BS.tq(0.975, 5000), 1.9623, 1e-3)
    end)

    test("central inverts tq", function()
        for _, df in ipairs({ 1, 2, 3, 7, 32 }) do
            for _, p in ipairs({ 0.8, 0.975, 0.995 }) do
                ok(math.abs(BS.central(BS.tq(p, df), df) - (2 * p - 1)) < 1e-9, "df " .. df .. " p " .. p)
            end
        end
    end)

    test("hand example", function()
        local st = BS.clustered(chars({ { 100, 100 }, { 100, 100 }, { 100, 100 } }, { { 101, 103 }, { 98, 100 }, { 100, 100 } }))
        eq(st.C, 3); eq(st.pairs, 6); eq(st.same, 3)
        near(st.mean, 1 / 3, 1e-9)
        near(st.se, 0.8819171, 1e-6)
        near(st.tcrit, 4.3026527, 1e-6)
        near(st.msw, 4 / 3, 1e-9)
        eq(st.dfw, 3)
        near(st.s2c, 5 / 3, 1e-9); near(st.s2s, 4 / 3, 1e-9)
        near(st.partChar, 5 / 9, 1e-9); near(st.partSalt, 2 / 9, 1e-9)
        near(BS.project(st, 3, 2), st.se, 1e-12)
        eq(st.harmed1, 0)
        eq(BS.verdict(st), "no clear difference")
        local nd = BS.need(st, 0.5)
        eq(nd.salts, nil, "not reachable: the character part alone is too big")
        eq(nd.chars, 76)
        eq(nd.charsUnlimited, 55)
    end)

    test("a steady gain is better", function()
        local st = BS.clustered(fromDiffs({ { 2.1, 1.9, 2.0 }, { 1.8, 2.2, 2.0 }, { 2.5, 1.5, 2.0 }, { 2.0, 2.0, 2.3 } }))
        near(st.mean, 2.025, 1e-9)
        eq(BS.verdict(st), "better")
    end)

    test("a character steadily 5% down is worse", function()
        local st = BS.clustered(fromDiffs({ { 1.0, 1.2, 0.8 }, { 1.1, 0.9, 1.0 }, { 0.9, 1.0, 1.1 }, { -5.0, -5.2, -4.8 } }))
        eq(st.harmed2, 1)
        eq(BS.verdict(st), "worse")
        near(st.g, 2.7515, 1e-3)
    end)

    test("a noisy character at -3% is not harmed", function()
        local st = BS.clustered(fromDiffs({ { 10, -16, -3 }, { 1, 0, 2 }, { 0, 1, -1 }, { 2, 1, 0 } }))
        near(st.worst, -3, 1e-9)
        eq(st.harmed1, 0)
        eq(BS.verdict(st), "no clear difference")
        near(st.msw, 43, 1e-9)
    end)

    test("one salt: the old point rule", function()
        local st = BS.clustered(chars({ { 100 }, { 100 } }, { { 97 }, { 104 } }))
        eq(st.guardPoint, true)
        eq(st.harmed2, 1)
        eq(BS.verdict(st), "worse")
    end)

    test("identical pairs", function()
        local st = BS.clustered(chars({ { 100, 200 }, { 300, 50 } }, { { 100, 200 }, { 300, 50 } }))
        eq(BS.verdict(st), "identical")
    end)

    test("only salts noisy: more salts help", function()
        local ds = {}
        for i = 1, 8 do ds[i] = { -1, 1, -1, 1 } end
        local st = BS.clustered(fromDiffs(ds))
        near(st.se, 0, 1e-9)
        local nd = BS.need(st, 0.5)
        eq(nd.salts, 8)
        eq(nd.chars, 13)
        eq(nd.charsUnlimited, 2)
        near(nd.se, 0.153343, 1e-5)
    end)

    test("correlation of base and config", function()
        local seed = 99
        local function u() seed = (seed * 16807) % 2147483647; return seed / 2147483647 end
        local bs, as = {}, {}
        for i = 1, 6 do
            bs[i], as[i] = {}, {}
            for s = 1, 4 do
                local b = 1000 * (1 + 0.1 * (u() - 0.5)) -- base varies by +-5% with the salt
                bs[i][s], as[i][s] = b, b * (1 + 0.01 * (u() - 0.5))
            end
        end
        local st = BS.clustered(chars(bs, as))
        ok(st.rho and st.rho > 0.99, "rho " .. tostring(st.rho))
    end)

    test("quantile (nearest rank)", function()
        local list = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
        eq(BS.quantile(list, 0.5), 5)
        eq(BS.quantile(list, 0.9), 9)
        eq(BS.quantile(list, 0.99), 10)
        eq(BS.quantile({ 7 }, 0.5), 7)
    end)
end)
