-- tests/mocks.lua: stand-ins for the WoW client (and TomTom) used by the addon's runtime files.

local M = {}

-- name -> the global's value before we replaced it (a sentinel stands for nil)
local NONE = {}
local originals = {}

local function set(name, value)
    if originals[name] == nil then
        local before = rawget(_G, name)
        originals[name] = before == nil and NONE or before
    end
    _G[name] = value
end
M.set = set

function M.reset()
    for name, before in pairs(originals) do
        if before == NONE then _G[name] = nil else _G[name] = before end
    end
    originals = {}
end

function M.makeTomTom()
    local T = {}
    function T:IsCrazyArrowEmpty() return true end
    function T:AddWaypoint() return {} end
    function T:RemoveWaypoint() end
    function T:IsValidWaypoint() return true end
    function T:DefaultCallbacks() return {} end
    return T
end

--- Install client basics. opts.tomtom = table|false, opts.versions = {Name = "x"}, opts.loaded = {Name = bool},
--- opts.questiedb = a LibQuestieDB (M.questieDB() or M.fakeQuestieDB()), installed as the global
--- with QuestieDB shown as loaded; without it there is no QuestieDB.
function M.install(opts)
    opts = opts or {}
    M.reset()
    local versions = { TomTom = "v4.4.1-release" }
    for k, v in pairs(opts.versions or {}) do versions[k] = v end
    local loaded = { TomTom = opts.tomtom ~= false }
    for k, v in pairs(opts.loaded or {}) do loaded[k] = v end
    if opts.questiedb then
        set("LibQuestieDB", opts.questiedb)
        loaded.QuestieDB = true
        versions.QuestieDB = versions.QuestieDB or opts.questiedb.version or "1.1.1"
    end
    set("C_AddOns", {
        GetAddOnMetadata = function(name, field)
            if field == "Version" and loaded[name] then return versions[name] end
        end,
        IsAddOnLoaded = function(name) return loaded[name] == true end,
    })
    if opts.tomtom ~= false then set("TomTom", opts.tomtom or M.makeTomTom()) end
    M.printed = {}
    set("print", function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        M.printed[#M.printed + 1] = table.concat(parts, " ")
    end)
    M.frames = {}
    set("CreateFrame", function(kind, name)
        local f = M.widget(kind or "Frame")
        f.name = name
        -- the frame ns.Async drives its jobs with (see M.asyncFrame)
        local caller = debug.getinfo(2, "S")
        f.isAsync = caller and caller.source:find("Async%.lua$") ~= nil or nil
        M.frames[#M.frames + 1] = f
        if name then set(name, f) end
        return f
    end)
    set("UIParent", M.widget("Frame"))
    M.tooltip = M.widget("GameTooltip")
    M.tooltip.lines = {}
    function M.tooltip:SetOwner() self.lines = {} end
    function M.tooltip:AddLine(text) self.lines[#self.lines + 1] = text end
    function M.tooltip:AddDoubleLine(left, right) self.lines[#self.lines + 1] = left .. " | " .. right end
    set("GameTooltip", M.tooltip)
    M.clock = 0
    set("debugprofilestop", function() return M.clock end)
    set("GetTime", function() return M.clock / 1000 end)
    M.timers = {}
    set("C_Timer", { After = function(_, fn) M.timers[#M.timers + 1] = fn end })
    set("SlashCmdList", {})
end

--- A stand-in for any frame, texture or font string: remembers scripts, events, text, points
--- and visibility; every other method exists and does nothing (getters return 0).
function M.widget(kind)
    local w = { kind = kind, scripts = {}, events = {}, shown = true, children = {}, points = {} }
    function w:SetScript(name, fn) self.scripts[name] = fn end
    function w:HookScript(name, fn)
        local before = self.scripts[name]
        self.scripts[name] = function(...) if before then before(...) end; fn(...) end
    end
    function w:GetScript(name) return self.scripts[name] end
    function w:RegisterEvent(e) self.events[e] = true end
    function w:SetText(t) self.text = t end
    function w:GetText() return self.text end
    function w:Show() self.shown = true end
    function w:Hide() self.shown = false end
    function w:IsShown() return self.shown end
    function w:SetHeight(h) self.height = h end
    function w:GetHeight() return self.height or 0 end
    function w:SetSize(wd, h) self.width, self.height = wd, h end
    function w:ClearAllPoints() self.points = {} end
    function w:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function w:GetPoint(i) local p = self.points[i or 1]; if p then return p[1], p[2], p[3], p[4], p[5] end end
    local function child(kind2)
        return function(self)
            local c = M.widget(kind2)
            c.parent = self
            self.children[#self.children + 1] = c
            return c
        end
    end
    w.CreateTexture, w.CreateFontString = child("Texture"), child("FontString")
    return setmetatable(w, { __index = function(_, key)
        if type(key) == "string" and key:match("^Get") then return function() return 0 end end
        if type(key) == "string" and key:match("^%u") then return function() end end
        return nil
    end })
end

--- The frame that drives background jobs (ns.Async), or nil when none is running.
--- (Told apart by who made it: other unnamed frames with an OnUpdate script, such as the flight
--- map's watcher while the map is open, are not background jobs.)
function M.asyncFrame()
    for i = #M.frames, 1, -1 do
        local f = M.frames[i]
        if f.isAsync and f.scripts.OnUpdate then return f end
    end
end

--- Run timers set with C_Timer.After and background jobs until nothing is left.
function M.settle(max)
    for _ = 1, max or 5000 do
        if #M.timers > 0 then
            local fns = M.timers
            M.timers = {}
            for _, fn in ipairs(fns) do fn() end
        end
        local f = M.asyncFrame()
        if f then
            M.clock = M.clock + 1
            f.scripts.OnUpdate(f, 0.02)
        elseif #M.timers == 0 then
            return true
        end
    end
    return false
end

--- Fire an event on every frame that registered it.
function M.fire(event, ...)
    for _, f in ipairs(M.frames) do
        if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end

--- Fire PLAYER_LOGIN on every frame that registered it.
function M.login()
    for _, f in ipairs(M.frames) do
        if f.events.PLAYER_LOGIN then f.scripts.OnEvent(f, "PLAYER_LOGIN") end
    end
end

---------------------------------------------------------------------------------------------
-- QuestieDB
---------------------------------------------------------------------------------------------

local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."
M.QUESTIEDB = os.getenv("QUESTIEDB") or "/Applications/World of Warcraft/_forever_/Interface/AddOns/QuestieDB"
local real

--- The real QuestieDB addon (folder: env QUESTIEDB, default the game's AddOns folder), run in
--- the import tools' sandbox (tools/import/questiedb.lua) and read through its LibQuestieDB,
--- exactly as the game runs it. QuestieDB applies its corrections for `faction`/`class`; it is
--- loaded once per process and switching re-applies the corrections for the new pair.
--- Returns LibQuestieDB (with .version set to QuestieDB's TOC version).
function M.questieDB(faction, class)
    faction, class = faction or "Alliance", class or "WARRIOR"
    if not real then
        local toc = io.open(M.QUESTIEDB .. "/QuestieDB_Forever.toc", "rb")
        if not toc then
            error("the real-data tests need the QuestieDB addon: not found at " .. M.QUESTIEDB
                .. " (set QUESTIEDB=<QuestieDB addon folder>)", 0)
        end
        toc:close()
        local tools = root .. "/tools/import"
        local Loader = assert(loadfile(tools .. "/questiedb.lua"))(tools)
        local L, _, state = Loader.Load(M.QUESTIEDB, faction, class)
        L.version = state.metadata.QuestieDB.Version
        real = { L = L, state = state }
    end
    local st = real.state
    if st.faction ~= faction or st.class ~= class then
        st.faction, st.class = faction, class
        real.L.Corrections.ApplyRegisteredCorrections(real.L.Corrections.OWNER)
    end
    return real.L
end

local function sourceOf(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. k .. "]=" .. tostring(t[k]) end
    return "return {" .. table.concat(parts, ",") .. "}"
end

local function nestedSourceOf(t)
    local parts = {}
    for item, byNpc in pairs(t or {}) do parts[#parts + 1] = "[" .. item .. "]=" .. sourceOf(byNpc):sub(8) end
    return "return {" .. table.concat(parts, ",") .. "}"
end

--- A small stand-in for LibQuestieDB (contract 4) with only what LevelScout reads.
--- spec = {
---   quests/npcs/objects/items = { [id] = { field = value, ... } }  (QuestieDB field names)
---   zones = { [areaId] = uiMapID }, parents = { [subZone] = zone }, dungeons = ZoneDB dungeons,
---   xp = { [questId] = { level, xp } }, wowhead/cmangos = { [itemId] = { [npcId] = percent } },
---   dropCorrections = { [itemId] = { [npcId] = percent } }, objectiveFirst = {...},
---   contract = 4 (contractVersion), minContract = 1, version = "1.1.1" }
function M.fakeQuestieDB(spec)
    spec = spec or {}
    local L = { addonName = "QuestieDB", version = spec.version or "1.1.1",
        contractVersion = spec.contract or 4, minSupportedContract = spec.minContract or 1 }
    function L.RequireContract(required)
        if required >= L.minSupportedContract and required <= L.contractVersion then return true end
        return false, string.format("QuestieDB contract mismatch: this consumer needs version %d, the installed "
            .. "QuestieDB provides %d (supporting consumers back to %d). Update whichever is older.",
            required, L.contractVersion, L.minSupportedContract)
    end
    L.reads = 0 -- field reads, for the caching tests
    local function entity(rows)
        rows = rows or {}
        local e = {}
        function e.Exists(id) return rows[id] ~= nil end
        function e.Get(id, key)
            local r = rows[id]
            if not r then return nil end
            L.reads = L.reads + 1
            return r[key]
        end
        function e.GetAll(id, keys)
            local r = rows[id]
            if not r then return nil end
            local out = { n = #keys }
            for i, k in ipairs(keys) do L.reads = L.reads + 1; out[i] = r[k] end
            return out
        end
        function e.GetAllIds()
            local ids = {}
            for id in pairs(rows) do ids[#ids + 1] = id end
            table.sort(ids)
            return ids
        end
        return e
    end
    L.Quest, L.Npc, L.Object, L.Item = entity(spec.quests), entity(spec.npcs), entity(spec.objects), entity(spec.items)
    local support = {
        ZoneDB = { private = { areaIdToUiMapId = sourceOf(spec.zones), areaIdToUiMapIdOverride = "return {}",
            subZoneToParentZone = sourceOf(spec.parents), subZoneToParentZoneOverride = "return {}",
            dungeons = spec.dungeons or {} } },
        QuestXP = { db = spec.xp or {} },
        QuestieClassicItemDrops = { wowheadData = nestedSourceOf(spec.wowhead), cmangosData = nestedSourceOf(spec.cmangos) },
        QuestieItemDropCorrections = { Era = spec.dropCorrections or {} },
    }
    L.Support = { Get = function(name) return support[name] end }
    L.ObjectiveFirst = spec.objectiveFirst or {}
    L.Enum = {
        factionRaceMasks = { Alliance = 1 + 4 + 8 + 64 + 2 ^ 32, Horde = 2 + 16 + 32 + 128 + 2 ^ 33 },
        raceMaskById = { [1] = 1, [2] = 2, [3] = 4, [4] = 8, [5] = 16, [6] = 32, [7] = 64, [8] = 128 },
        classKeys = { WARRIOR = 1, PALADIN = 2, HUNTER = 4, ROGUE = 8, PRIEST = 16, SHAMAN = 64, MAGE = 128,
            WARLOCK = 256, DRUID = 1024 },
        npcFlags = { VENDOR = 128, FLIGHT_MASTER = 8192, INNKEEPER = 65536 },
        sortKeys = { SEASONAL = -22, CAMPING = -666 },
        dropCorrectionKeys = { WOWHEAD = -1, PSERVER = -2 },
    }
    return L
end

return M
