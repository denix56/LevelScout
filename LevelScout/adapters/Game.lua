-- adapters/Game.lua
--
-- Thin wrapper over the game API (client 1.60.1, modern C_* namespaces). Only non-combat
-- signals: quest log, completed quests, level/XP, position outside instances.
-- Every call checks the function exists, runs under pcall, and treats secret values as unknown.

local _, ns = ...

local Game = {}
ns.Game = Game

local function pack(...) return { n = select("#", ...), ... } end

local function isSecret(v)
    local fn = rawget(_G, "issecretvalue")
    return type(fn) == "function" and fn(v) and true or false
end

--- Call fn safely; returns its results, or nil on error / missing function / secret first value.
local function safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = pack(pcall(fn, ...))
    if not r[1] or isSecret(r[2]) then return nil end
    return unpack(r, 2, r.n)
end
Game.safe = safe

local function api(ns_, name)
    local t = rawget(_G, ns_)
    return type(t) == "table" and t[name] or nil
end

function Game.InInstance()
    return safe(rawget(_G, "IsInInstance")) and true or false
end

function Game.InCombat()
    return safe(rawget(_G, "InCombatLockdown")) and true or false
end

--- { level, xp, xpMax, rested, maxLevel, faction, race, class }
function Game.GetPlayer()
    local _, _, raceId = safe(rawget(_G, "UnitRace"), "player")
    local _, _, classId = safe(rawget(_G, "UnitClass"), "player")
    return {
        level = safe(rawget(_G, "UnitLevel"), "player"),
        xp = safe(rawget(_G, "UnitXP"), "player"),
        xpMax = safe(rawget(_G, "UnitXPMax"), "player"),
        rested = safe(rawget(_G, "GetXPExhaustion")) or 0,
        maxLevel = safe(rawget(_G, "GetMaxPlayerLevel")),
        faction = safe(rawget(_G, "UnitFactionGroup"), "player"),
        race = raceId,
        class = classId,
    }
end

--- The player context ns.Data and the eligibility checks use (faction, class, race, client build).
--- { faction = "Alliance"|"Horde", class = "WARRIOR"|..., raceId, clientBuild = "1.60.1.70888" }
function Game.GetPlayerContext()
    local _, classFile = safe(rawget(_G, "UnitClass"), "player")
    local _, _, raceId = safe(rawget(_G, "UnitRace"), "player")
    local version, build = safe(rawget(_G, "GetBuildInfo"))
    return {
        faction = safe(rawget(_G, "UnitFactionGroup"), "player"),
        class = classFile,
        raceId = raceId,
        clientBuild = version and build and (version .. "." .. build) or nil,
    }
end

-- C_QuestLog.GetQuestTagInfo tagIDs (QuestieDB questTagIds): 1 elite, 41 PvP, 62/88/89 raid,
-- 81/85 dungeon, 98 scenario.
local TAGS = { [1] = "elite", [41] = "pvp", [62] = "raid", [81] = "dungeon", [85] = "dungeon",
    [88] = "raid", [89] = "raid", [98] = "scenario" }

--- The game's own tag for a quest: tag ("dungeon"|"raid"|"elite"|"pvp"|"scenario"|nil), known.
--- `known` is false when the client has not loaded that quest's data yet (ask again later;
--- C_QuestLog.RequestLoadQuestByID starts the load).
function Game.GetQuestTag(questId)
    local have = rawget(_G, "HaveQuestData")
    if type(have) == "function" and not safe(have, questId) then
        safe(api("C_QuestLog", "RequestLoadQuestByID"), questId)
        return nil, false
    end
    local info = safe(api("C_QuestLog", "GetQuestTagInfo"), questId)
    if type(info) ~= "table" then return nil, true end
    return TAGS[info.tagID], true
end

--- uiMapID, x, y (0-1) of the player; nil inside instances or when unavailable.
--- With `accept(mapId)`, climbs from the player's map (a cave, a town) to the first parent map
--- the function accepts, and gives the position on that map.
function Game.GetPosition(accept)
    if Game.InInstance() then return nil end
    local mapId = safe(api("C_Map", "GetBestMapForUnit"), "player")
    if not mapId then return nil end
    if accept then
        for _ = 1, 5 do
            if accept(mapId) then break end
            local info = safe(api("C_Map", "GetMapInfo"), mapId)
            local parent = type(info) == "table" and info.parentMapID or nil
            if not parent or parent == 0 then return nil end
            mapId = parent
        end
        if not accept(mapId) then return nil end
    end
    local pos = safe(api("C_Map", "GetPlayerMapPosition"), mapId, "player")
    if type(pos) ~= "table" and type(pos) ~= "userdata" then return nil end
    local x, y = pos.x, pos.y
    if (x == nil or y == nil) and pos.GetXY then x, y = safe(pos.GetXY, pos) end
    if type(x) ~= "number" or type(y) ~= "number" or isSecret(x) or isSecret(y) then return nil end
    if x == 0 and y == 0 then return nil end
    return mapId, x, y
end

--- The zone the game puts a point of a map in (`map`, x and y 0-1), by its real borders:
--- C_Map.GetMapInfoAtPosition, then up through parent maps (a sub-zone, a building) to the
--- first one `accept(mapId)` takes. nil where the client cannot say.
function Game.ZoneAt(map, x, y, accept)
    if not (map and x and y) then return nil end
    local info = safe(api("C_Map", "GetMapInfoAtPosition"), map, x, y)
    local mapId = type(info) == "table" and info.mapID or nil
    for _ = 1, 6 do
        if not mapId or mapId == 0 or mapId == map then return nil end
        if not accept or accept(mapId) then return mapId end
        local up = safe(api("C_Map", "GetMapInfo"), mapId)
        mapId = type(up) == "table" and up.parentMapID or nil
    end
    return nil
end

--- How the player is moving, for learning the travel speed (ns.Tracker.OnMove):
--- { blocked = true when this is not travel on the ground under the player's own power (on a
---   flight path, in combat, dead or a ghost, swimming, flying, falling, in a vehicle),
---   mounted = true|false, or nil when the client does not say }.
--- A check the client does not have counts as "no". (A flight is then still told apart by its speed.)
function Game.GetMovement()
    local function yes(name, ...)
        return safe(rawget(_G, name), ...) and true or false
    end
    local blocked = yes("UnitOnTaxi", "player") or Game.InCombat() or yes("UnitAffectingCombat", "player")
        or yes("UnitIsDeadOrGhost", "player") or yes("IsSwimming") or yes("IsFlying") or yes("IsFalling")
        or yes("UnitInVehicle", "player")
    local mounted
    if type(rawget(_G, "IsMounted")) == "function" then mounted = yes("IsMounted") end
    return { blocked = blocked, mounted = mounted }
end

--- True while the player is on a flight path (false when the client does not say).
function Game.OnTaxi()
    return safe(rawget(_G, "UnitOnTaxi"), "player") and true or false
end

--- Set of completed quest IDs: { [questId] = true }
function Game.GetCompletedQuests()
    local ids = safe(api("C_QuestLog", "GetAllCompletedQuestIDs"))
    local out = {}
    if type(ids) == "table" then
        for _, id in ipairs(ids) do out[id] = true end
    end
    return out
end

--- Has this character turned the quest in? true / false, or nil when the client does not say.
function Game.IsQuestCompleted(questId)
    local fn = api("C_QuestLog", "IsQuestFlaggedCompleted")
    if type(fn) ~= "function" then return nil end
    local done = safe(fn, questId)
    if done == nil then return nil end
    return done and true or false
end

--- Maximum number of quests the log accepts (nil when the client does not say).
function Game.GetQuestLogCapacity()
    return safe(api("C_QuestLog", "GetMaxNumQuestsCanAccept"))
end

--- Quests currently in the log:
--- { {id, title, level, logIndex, isComplete, isFailed, rewardXP?,
---    objectives = { {text, type, finished, have, need}, ... }}, ... }
function Game.GetQuestLog()
    local out = {}
    local count = safe(api("C_QuestLog", "GetNumQuestLogEntries")) or 0
    local getInfo = api("C_QuestLog", "GetInfo")
    for i = 1, count do
        local info = safe(getInfo, i)
        if type(info) == "table" and not info.isHeader and not info.isHidden and info.questID then
            local id = info.questID
            local q = {
                id = id,
                title = info.title,
                level = info.level,
                logIndex = i,
                isComplete = safe(api("C_QuestLog", "IsComplete"), id) and true or false,
                isFailed = safe(api("C_QuestLog", "IsFailed"), id) and true or false,
                -- Unverified on Forever (docs/findings.md section 6): nil when absent.
                rewardXP = safe(rawget(_G, "GetQuestLogRewardXP"), id),
                objectives = {},
            }
            local objectives = safe(api("C_QuestLog", "GetQuestObjectives"), id)
            for _, o in ipairs(type(objectives) == "table" and objectives or {}) do
                q.objectives[#q.objectives + 1] = { text = o.text, type = o.type,
                    finished = o.finished and true or false, have = o.numFulfilled, need = o.numRequired }
            end
            out[#out + 1] = q
        end
    end
    return out
end

--- The client's name for a map, or nil.
--- Items in the backpack and the four bags: { { itemId, questId (the quest this item starts,
--- as the game says; nil when it does not or cannot say) }, ... }, in bag and slot order.
function Game.GetBagItems()
    local out = {}
    local C = rawget(_G, "C_Container")
    local numSlots = (C and C.GetContainerNumSlots) or rawget(_G, "GetContainerNumSlots")
    local itemId = (C and C.GetContainerItemID) or rawget(_G, "GetContainerItemID")
    local questInfo = (C and C.GetContainerItemQuestInfo) or rawget(_G, "GetContainerItemQuestInfo")
    if not numSlots or not itemId then return out end
    for bag = 0, 4 do
        local ok, n = pcall(numSlots, bag)
        for slot = 1, (ok and type(n) == "number") and n or 0 do
            local okId, id = pcall(itemId, bag, slot)
            if okId and type(id) == "number" then
                local quest
                if questInfo then
                    local okQ, a, b, c = pcall(questInfo, bag, slot)
                    if okQ and type(a) == "table" then a, b, c = a.isQuestItem, a.questID, a.isActive end
                    if okQ and type(b) == "number" and b > 0 and not c then quest = b end
                end
                out[#out + 1] = { id, quest }
            end
        end
    end
    return out
end

function Game.MapName(mapId)
    local info = safe(api("C_Map", "GetMapInfo"), mapId)
    return type(info) == "table" and info.name or nil
end

--- Seconds since the client started (0 when unavailable).
function Game.Now()
    return safe(rawget(_G, "GetTime")) or 0
end

--- Run fn after `seconds`. Without C_Timer it runs at once.
function Game.After(seconds, fn)
    local after = api("C_Timer", "After")
    if type(after) == "function" and pcall(after, seconds, fn) then return true end
    fn()
    return false
end

--- Call handler(event, ...) for the given events. Returns the frame.
function Game.Listen(events, handler)
    local frame = CreateFrame("Frame")
    for _, e in ipairs(events) do pcall(frame.RegisterEvent, frame, e) end
    frame:SetScript("OnEvent", function(_, event, ...) handler(event, ...) end)
    return frame
end

--- Flight nodes this character can use, read while the flight map is open:
--- { [taxiNodeId] = true }, or nil when the client does not say.
function Game.GetTaxiNodes()
    local mapId = safe(api("C_Map", "GetBestMapForUnit"), "player")
    local nodes = mapId and safe(api("C_TaxiMap", "GetAllTaxiNodes"), mapId)
    if type(nodes) ~= "table" then return nil end
    local out, any = {}, false
    for _, n in ipairs(nodes) do
        -- Enum.FlightPathState: 0 current, 1 reachable, 2 unreachable (not discovered)
        if type(n) == "table" and n.nodeID and n.state ~= 2 then out[n.nodeID], any = true, true end
    end
    return any and out or nil
end

-- The game's own map waypoint, used when TomTom is absent. Only a waypoint we set is cleared.
local ownWaypoint

--- Set the map pin and track it. x, y are 0-1. Returns true when it was set.
function Game.SetMapWaypoint(mapId, x, y)
    local can = api("C_Map", "CanSetUserWaypointOnMap")
    if type(can) == "function" and not safe(can, mapId) then return false end
    local point = rawget(_G, "UiMapPoint")
    local set = api("C_Map", "SetUserWaypoint")
    if type(point) ~= "table" or type(point.CreateFromCoordinates) ~= "function" or type(set) ~= "function" then return false end
    local ok, p = pcall(point.CreateFromCoordinates, mapId, x, y)
    if not ok or not p or not pcall(set, p) then return false end
    ownWaypoint = { map = mapId, x = x, y = y }
    safe(api("C_SuperTrack", "SetSuperTrackedUserWaypoint"), true)
    return true
end

--- Remove the map pin if it is still the one we set (the player may have moved it).
function Game.ClearMapWaypoint()
    local own = ownWaypoint
    ownWaypoint = nil
    if not own then return end
    local cur = safe(api("C_Map", "GetUserWaypoint"))
    local pos = type(cur) == "table" and cur.position or nil
    if pos and cur.uiMapID == own.map and type(pos.x) == "number" and math.abs(pos.x - own.x) < 0.002
        and math.abs(pos.y - own.y) < 0.002 then
        safe(api("C_Map", "ClearUserWaypoint"))
    end
end

--- The NPC id inside a creature's GUID ("Creature-0-server-instance-zone-npcId-spawn"), or nil:
--- not a creature, or the client keeps the GUID secret (it can, in combat).
function Game.NpcFromGUID(guid)
    if isSecret(guid) or type(guid) ~= "string" then return nil end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
    return tonumber(id)
end

--- Members of the player's party or raid including the player; 1 when solo.
function Game.GetGroupSize()
    local n = safe(rawget(_G, "GetNumGroupMembers"))
    if type(n) ~= "number" or n < 1 then return 1 end
    return n
end

--- How many other party members are on a quest, or nil when there is no party or the client
--- cannot say. Only meaningful for quests in the player's own log.
function Game.PartyOnQuest(questId)
    local modern = api("C_QuestLog", "IsUnitOnQuest")
    local classic = rawget(_G, "IsUnitOnQuestByQuestID")
    if type(modern) ~= "function" and type(classic) ~= "function" then return nil end
    local exists = rawget(_G, "UnitExists")
    local members, on = 0, 0
    for i = 1, 4 do
        local unit = "party" .. i
        if safe(exists, unit) then
            members = members + 1
            local yes
            if type(modern) == "function" then yes = safe(modern, unit, questId) else yes = safe(classic, questId, unit) end
            if yes then on = on + 1 end
        end
    end
    if members == 0 then return nil end
    return on
end

-- Buffs known to raise XP gained: [spellId] = bonus (per stack when `stack` is set).
-- 429959 is Forever's sleeping-bag buff (from Questie's Forever support); the rest are the
-- classic event buffs.
local XP_BUFFS = {
    [429959] = { 0.01, stack = true }, -- Well-Rested (sleeping bag): 1% per stack
    [46668] = { 0.10 },                -- Darkmoon Faire
    [95987] = { 0.10 }, [24705] = { 0.10 }, -- Hallow's End
    [377749] = { 0.50 },               -- Joyous Journeys
}

-- "+5% experience" in a buff's description, for XP buffs not in the table (food, for one).
local function bonusFromText(text)
    if type(text) ~= "string" then return nil end
    local lower = text:lower()
    if not lower:find("experience", 1, true) then return nil end
    local pct = lower:match("experience[^%d%.]*by%s*(%d+)%%") or lower:match("(%d+)%%[^%.]*experience")
        or lower:match("experience[^%d%.]*(%d+)%%")
    pct = tonumber(pct)
    if pct and pct > 0 and pct <= 300 then return pct / 100 end
    return nil
end
Game.XPBonusFromText = bonusFromText

Game.SLEEPING_BAG_BUFF = 429959

--- A line in the middle of the screen, where the game shows its own notices.
function Game.Notice(text)
    local frame = rawget(_G, "UIErrorsFrame")
    if type(frame) == "table" and type(frame.AddMessage) == "function" then
        pcall(frame.AddMessage, frame, text, 1, 0.82, 0)
        return true
    end
    return false
end

--- The player's XP bonus from buffs: total (0.05 = +5%) and { {name, bonus, spellId, expires}, ... }.
--- Returns nil in combat and in instances, where the client hides buffs from addons: keep the
--- last answer then.
function Game.GetXPBuffs()
    if Game.InCombat() or Game.InInstance() then return nil end
    local byIndex = api("C_UnitAuras", "GetAuraDataByIndex")
    local legacy = rawget(_G, "UnitAura") or rawget(_G, "UnitBuff")
    if type(byIndex) ~= "function" and type(legacy) ~= "function" then return nil end
    local describe = api("C_Spell", "GetSpellDescription") or rawget(_G, "GetSpellDescription")
    local total, list = 0, {}
    for i = 1, 40 do
        local name, stacks, spellId, expires
        if type(byIndex) == "function" then
            local aura = safe(byIndex, "player", i, "HELPFUL")
            if type(aura) ~= "table" then break end
            name, stacks, spellId, expires = aura.name, aura.applications, aura.spellId, aura.expirationTime
        else
            local n, _, count, _, _, expiration, _, _, _, id = safe(legacy, "player", i, "HELPFUL")
            if not n then break end
            name, stacks, spellId, expires = n, count, id, expiration
        end
        if type(spellId) == "number" and not isSecret(spellId) then
            local known = XP_BUFFS[spellId]
            local bonus
            if known then
                bonus = known[1] * (known.stack and math.max(1, tonumber(stacks) or 1) or 1)
            else
                bonus = bonusFromText(safe(describe, spellId))
            end
            if bonus then
                total = total + bonus
                -- expires: client time (Game.Now) when it ends; nil for a buff without a timer
                list[#list + 1] = { name = type(name) == "string" and name or ("spell " .. spellId), bonus = bonus,
                    spellId = spellId, expires = (type(expires) == "number" and expires > 0) and expires or nil }
            end
        end
    end
    return total, list
end

--- Every helpful buff as the addon sees it, for "/ls buffs":
--- { {name, spellId, description, bonus}, ... }, or nil in combat and in instances.
function Game.ListBuffs()
    if Game.InCombat() or Game.InInstance() then return nil end
    local byIndex = api("C_UnitAuras", "GetAuraDataByIndex")
    local legacy = rawget(_G, "UnitAura") or rawget(_G, "UnitBuff")
    local describe = api("C_Spell", "GetSpellDescription") or rawget(_G, "GetSpellDescription")
    local out = {}
    for i = 1, 40 do
        local name, spellId
        if type(byIndex) == "function" then
            local aura = safe(byIndex, "player", i, "HELPFUL")
            if type(aura) ~= "table" then break end
            name, spellId = aura.name, aura.spellId
        elseif type(legacy) == "function" then
            local n, _, _, _, _, _, _, _, _, id = safe(legacy, "player", i, "HELPFUL")
            if not n then break end
            name, spellId = n, id
        else
            break
        end
        local text = type(spellId) == "number" and not isSecret(spellId) and safe(describe, spellId) or nil
        local known = type(spellId) == "number" and XP_BUFFS[spellId]
        out[#out + 1] = { name = type(name) == "string" and name or "?", spellId = spellId,
            description = type(text) == "string" and text or nil,
            bonus = known and known[1] or bonusFromText(text) }
    end
    return out
end

---------------------------------------------------------------------------------------------
-- Talking to quest givers (ns.AutoQuest). An NPC lists its quests either in a gossip window
-- (C_GossipInfo) or in a quest greeting (the older QuestFrame list); one quest opens straight
-- in the quest frame (detail, progress, reward).
---------------------------------------------------------------------------------------------

--- The quests an open NPC window offers: { available = { {id?, title, index}, ... },
--- active = { {id?, title, index, complete}, ... } }. `kind` is "gossip" or "greeting".
--- id is nil where the client gives only the title (match by title then).
function Game.NpcQuests(kind)
    local out = { available = {}, active = {} }
    if kind == "gossip" then
        local avail = safe(api("C_GossipInfo", "GetAvailableQuests"))
        for i, q in ipairs(type(avail) == "table" and avail or {}) do
            if type(q) == "table" then
                out.available[#out.available + 1] = { id = q.questID, title = q.title, index = i }
            end
        end
        local active = safe(api("C_GossipInfo", "GetActiveQuests"))
        for i, q in ipairs(type(active) == "table" and active or {}) do
            if type(q) == "table" then
                out.active[#out.active + 1] = { id = q.questID, title = q.title, index = i, complete = q.isComplete and true or false }
            end
        end
    elseif kind == "greeting" then
        for i = 1, safe(rawget(_G, "GetNumAvailableQuests")) or 0 do
            local id = select(5, safe(rawget(_G, "GetAvailableQuestInfo"), i))
            out.available[#out.available + 1] = { id = type(id) == "number" and id > 0 and id or nil,
                title = safe(rawget(_G, "GetAvailableTitle"), i), index = i }
        end
        for i = 1, safe(rawget(_G, "GetNumActiveQuests")) or 0 do
            local title, complete = safe(rawget(_G, "GetActiveTitle"), i)
            local id = safe(rawget(_G, "GetActiveQuestID"), i)
            out.active[#out.active + 1] = { id = type(id) == "number" and id > 0 and id or nil, title = title,
                index = i, complete = complete and true or false }
        end
    end
    return out
end

--- Open one quest of an NPC window (an entry of Game.NpcQuests). which: "available" | "active".
function Game.SelectNpcQuest(kind, which, entry)
    if kind == "gossip" then
        local fn = api("C_GossipInfo", which == "available" and "SelectAvailableQuest" or "SelectActiveQuest")
        if entry.id and type(fn) == "function" then return pcall(fn, entry.id) end
    elseif kind == "greeting" then
        local fn = rawget(_G, which == "available" and "SelectAvailableQuest" or "SelectActiveQuest")
        if type(fn) == "function" then return pcall(fn, entry.index) end
    end
    return false
end

--- The quest open in the quest frame: id (nil when the client does not say), title.
function Game.ShownQuest()
    local id = safe(rawget(_G, "GetQuestID"))
    return type(id) == "number" and id > 0 and id or nil, safe(rawget(_G, "GetTitleText"))
end

--- Accept the quest shown in the quest frame. A quest the game already accepted on its own
--- (an auto-accept quest) is only acknowledged.
function Game.AcceptShownQuest()
    if safe(rawget(_G, "QuestGetAutoAccept")) then
        return pcall(rawget(_G, "AcknowledgeAutoAcceptQuest") or function() end)
    end
    local accept = rawget(_G, "AcceptQuest")
    return type(accept) == "function" and pcall(accept) or false
end

--- On the quest frame's progress page: go on to the reward page when the quest can be handed in.
function Game.ContinueShownQuest()
    if not safe(rawget(_G, "IsQuestCompletable")) then return false end
    local complete = rawget(_G, "CompleteQuest")
    return type(complete) == "function" and pcall(complete) or false
end

--- On the reward page: hand the quest in when there is no reward to choose (none, or one).
--- Returns false when the player has to pick a reward.
function Game.TakeQuestReward()
    local choices = safe(rawget(_G, "GetNumQuestChoices")) or 0
    if choices > 1 then return false end
    local take = rawget(_G, "GetQuestReward")
    return type(take) == "function" and pcall(take, choices == 1 and 1 or nil) or false
end

--- True while Shift is held (it pauses the automatic accept and turn-in).
function Game.ShiftDown()
    return safe(rawget(_G, "IsShiftKeyDown")) and true or false
end
