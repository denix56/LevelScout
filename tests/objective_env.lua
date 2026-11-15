-- tests/objective_env.lua: the real data, the two states and the helpers test_objective.lua and
-- test_objective_2.lua share. Each file calls require("objective_env")(H, M) for its own copy.
return function(H, M)
    local O = {}

    local loaded
    local function data()
        if not loaded then
            M.install()
            local ns = {}
            local files = {}
            for _, f in ipairs(H.tocFiles()) do if f:match("^data/") then files[#files + 1] = f end end
            H.loadAddon(files, ns)
            H.loadAddon(H.runtimeFiles(), ns)
            loaded = ns
        end
        return loaded
    end

    -- A state: level 22 paladin in Redridge ("redridge"), or a level 7 warrior in Goldshire, where
    -- quests need the next levels, with a rested pool or XP just short of a level on request.
    local function state(kind, extra)
        local ns = data()
        local faction, class = "Alliance", kind == "redridge" and "PALADIN" or "WARRIOR"
        ns.Data.Init({ faction = faction, class = class, clientBuild = ns.data.meta.build }, M.questieDB(faction, class))
        ns.Data.BuildIndex()
        local upTo = kind == "redridge" and 18 or 3
        local completed = {}
        for _, id in ipairs(ns.Data.QuestIds()) do
            local q = ns.Data.GetQuest(id)
            if q and q.level > 0 and q.level <= upTo then completed[id] = true end
        end
        local s
        if kind == "redridge" then
            s = { level = 22, faction = faction, class = class, raceId = 1, map = 1433, x = 0.30, y = 0.44, log = {},
                completed = completed, capacity = 40 }
        else
            s = { level = 7, faction = faction, class = class, raceId = 1, map = 1429, x = 0.438, y = 0.659, log = {},
                completed = completed, capacity = 40 }
        end
        for k, v in pairs(extra or {}) do s[k] = v end
        return s
    end

    local MAPS = { redridge = { 1433, 1431, 1437 }, goldshire = { 1429 } }

    -- Settings for the length of a block, put back after.
    local function with(settings, fn)
        local ns = data()
        local saved = {}
        for _, s in ipairs(settings) do
            saved[#saved + 1] = { s[1], s[2], ns[s[1]][s[2]] }
            ns[s[1]][s[2]] = s[3]
        end
        local okay, err = pcall(fn)
        for i = #saved, 1, -1 do ns[saved[i][1]][saved[i][2]] = saved[i][3] end
        if not okay then error(err, 0) end
    end

    -- Plan a zone and keep the search's route (left at the best one found) and its settings.
    local function captured(st, map)
        local ns = data()
        local got
        local run = ns.Search.Run
        ns.Search.Run = function(sc) local res = run(sc); got = sc; return res end
        local okay, plan = pcall(ns.Zones.PlanZone, map, ns.Zones.Context(st))
        ns.Search.Run = run
        if not okay then error(plan, 0) end
        return got, plan
    end

    local function order(plan) return table.concat(plan.order, " ") end

    local seed = 20240607
    local function rnd(n) seed = (seed * 16807) % 2147483647; return seed % n + 1 end

    -- A random move of a run inside the route (order rules kept); returns i, len, p or nil.
    local function randomMove(r)
        for _ = 1, 20 do
            local len = rnd(2)
            local i = 1 + rnd(#r.route - 1)
            if i >= 2 and i + len - 1 <= #r.route then
                local lo, hi = r:runBounds(i, len)
                if lo <= hi then
                    local p = lo - 1 + rnd(hi - lo + 1)
                    if p ~= i - 1 then return i, len, p end
                end
            end
        end
    end

    -- every quest: accept, then its work, then turn in; never twice (plans with polish and dinkelbach on)
    local function wellFormed(plan)
        local at, count = {}, {}
        for i, key in ipairs(plan.order) do
            count[key] = (count[key] or 0) + 1
            at[key] = i
        end
        for key, n in pairs(count) do
            if n > 1 then return false, key .. " twice" end
            local id = key:match("^T:(%d+)$")
            if id and at["P:" .. id] and at["P:" .. id] > at[key] then return false, "turned in before accepted: " .. id end
        end
        return true
    end

    O.data, O.state, O.MAPS, O.with, O.captured, O.order = data, state, MAPS, with, captured, order
    O.rnd, O.randomMove, O.wellFormed = rnd, randomMove, wellFormed
    return O
end
