-- tests/game_env.lua: the mocked game client the test_game*.lua files share, and the start of a
-- session on the real data. Each test file calls require("game_env")(H, M) for its own copy.
return function(H, M)
    local E = {}

    E.SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
    local SECRET = E.SECRET
    E.requested = nil -- the last quest asked for with C_QuestLog.RequestLoadQuestByID

    -- over.questiedb: false = QuestieDB not installed, a table = that LibQuestieDB; default the
    -- real QuestieDB (tests/mocks.lua M.questieDB) for an Alliance warrior.
    function E.installGame(over)
        over = over or {}
        local lib = over.questiedb
        if lib == nil then lib = M.questieDB("Alliance", "WARRIOR") end
        M.install({ questiedb = lib or nil })
        M.set("issecretvalue", function(v) return v == SECRET end)
        M.set("IsInInstance", function() return over.inInstance or false end)
        M.set("InCombatLockdown", function() return false end)
        M.set("UnitLevel", function() return 12 end)
        M.set("UnitXP", function() return 3000 end)
        M.set("UnitXPMax", function() return 7400 end)
        M.set("GetXPExhaustion", function() return over.rested end)
        M.set("GetMaxPlayerLevel", function() return 60 end)
        M.set("UnitFactionGroup", function() return "Alliance" end)
        M.set("UnitRace", function() return "Human", "Human", 1 end)
        M.set("UnitClass", function() return "Warrior", "WARRIOR", 1 end)
        M.set("GetBuildInfo", function() return "1.60.1", "70888", "Nov 1 2026", 16001 end)
        M.set("HaveQuestData", function(id) return id ~= 424242 end)
        M.set("C_Map", {
            GetBestMapForUnit = function() return over.mapId == nil and 1429 or over.mapId end,
            GetPlayerMapPosition = function()
                if over.positionError then error("no position") end
                return { x = over.x or 0.42, y = 0.65 }
            end,
        })
        local log = {
            { title = "Elwynn Forest", isHeader = true },
            { title = "Kobold Camp Cleanup", questID = 7, level = 2 },
            { title = "Hidden", questID = 999, isHidden = true },
            { title = "Wolves Across the Border", questID = 33, level = 4 },
        }
        M.set("C_QuestLog", {
            GetNumQuestLogEntries = function() return #log, 2 end,
            GetInfo = function(i) return log[i] end,
            IsComplete = function(id) return id == 33 end,
            IsFailed = function() return false end,
            GetQuestObjectives = function(id)
                if id == 7 then
                    return { { text = "Kobold Vermin slain: 3/10", type = "monster", finished = false,
                        numFulfilled = 3, numRequired = 10 } }
                end
                return { { text = "Tough Wolf Meat: 8/8", type = "item", finished = true, numFulfilled = 8, numRequired = 8 } }
            end,
            GetAllCompletedQuestIDs = function() return { 783, 5261 } end,
            GetMaxNumQuestsCanAccept = function() return 40 end,
            GetQuestTagInfo = function(id) if id == 166 then return { tagID = 81, tagName = "Dungeon" } end end,
            RequestLoadQuestByID = function(id) E.requested = id end,
        })
        if over.rewardXP then
            M.set("GetQuestLogRewardXP", function(id) return id == 7 and 170 or 340 end)
        end
        return H.loadAddon()
    end

    function E.slash(msg) SlashCmdList.LEVELSCOUT(msg) end
    function E.output() return table.concat(M.printed, "\n") end

    -- These tests are about the engine and the window, not about how good the route is.
    -- Nine tenths of their time was the route search (every zone, several times a test), so
    -- it is off here unless a test asks for it (opts.search): the zones' own search and the
    -- itinerary's search of its later zones. The search has its own tests ("Planner search")
    -- and tests/bench.lua. A test that logs in without E.start calls this before M.login.
    function E.noSearch(ns)
        ns.Planner.SEARCH_ITERATIONS = 0
        ns.Zones.ITINERARY_ROUNDS = 0
    end

    -- Log in with fresh saved variables and let the first plan finish.
    -- opts: noTomTom, search (the route search on, as in the game), rounds (with search: rounds
    -- per zone), goal (Planner.GOAL).
    function E.start(over, opts)
        local ns = E.installGame(over)
        if opts and opts.noTomTom then M.set("TomTom", nil) end
        M.set("LevelScoutDB", nil)
        M.set("LevelScoutCharDB", nil)
        if not (opts and opts.search) then E.noSearch(ns) end
        if opts and opts.rounds then ns.Planner.SEARCH_ITERATIONS = opts.rounds end
        if opts and opts.goal then ns.Planner.GOAL = opts.goal end
        M.login()
        H.ok(M.settle(), "planning finishes")
        return ns
    end

    function E.rowTexts(ns)
        local out = {}
        for _, r in ipairs(ns.UI.rows) do
            if r:IsShown() and r.model then out[#out + 1] = r.model.title or r.model.section end
        end
        return out
    end

    -- The way to the current step: a step in Westfall, the player in Goldshire, flight points
    -- known in Stormwind (2) and at Sentinel Hill (4).
    function E.wayfinding()
        local ns = E.start()
        local names = { [1429] = "Elwynn Forest", [1436] = "Westfall", [1453] = "Stormwind City" }
        C_Map.GetMapInfo = function(id) return { name = names[id], parentMapID = 0 } end
        local map, x, y = 1429, 0.42, 0.65
        C_Map.GetBestMapForUnit = function() return map end
        C_Map.GetPlayerMapPosition = function() return { x = x, y = y } end
        local shown = {}
        TomTom.AddWaypoint = function(_, m, wx, wy, opts)
            shown[#shown + 1] = { map = m, x = wx, y = wy, title = opts.title }
            return {}
        end
        local travel = ns.Travel.New(ns.Data.World(), { speed = 7, side = "a", knownNodes = { [2] = true, [4] = true } })
        local function current()
            for _, r in ipairs(ns.UI.rows) do
                if r:IsShown() and r.model and r.model.current and r.model.step then return r end
            end
        end
        local function stand(m, px, py) map, x, y = m, px, py end
        return ns, travel, shown, current, stand
    end

    return E
end
