-- ui/FlightMap.lua: marks the flight point to fly to on the flight master's map.
-- When the way to the current step (or to the step pointed at by hand) starts with a flight,
-- the destination's pin gets a pulsing ring and a line in its tooltip. The player still picks
-- the flight; nothing is clicked for them.
--
-- Works on the modern flight map (FlightMapFrame, a map canvas whose pins carry taxiNodeData)
-- and on the classic one (TaxiFrame with TaxiButton1..n), whichever the client opens.
-- The modern map's pins come from a pool and are reused for other flight points, so the ring
-- is put on the right pin again every FlightMap.EVERY seconds while the map is open.
-- /ls taxi prints what it sees (FlightMap.Describe).

local _, ns = ...
local Game, Guide = ns.Game, ns.Guide

local FlightMap = {}
ns.FlightMap = FlightMap

FlightMap.EVERY = 0.3 -- seconds between looks while the flight map is open
FlightMap.PIN_TEMPLATE = "FlightMap_FlightPointPinTemplate"
FlightMap.TOOLTIP = "LevelScout: fly here"
local RING = "Interface\\Buttons\\UI-ActionButton-Border"
local COLOR = { 0.35, 1, 0.45 }

local watcher           -- shown (so its OnUpdate runs) while a flight map is open
local ring              -- the highlight, a child of the pin it is on
local marked            -- the pin the ring is on
local hooked = setmetatable({}, { __mode = "k" }) -- pins whose tooltip we add a line to
local told              -- the destination we said is missing from this map (once per opening)

--- The flight point the way starts with: { node, name }, or nil when it does not start with a flight.
function FlightMap.Destination()
    local pointed = Guide.Pointed()
    local way = pointed and pointed.trip or Guide.Trip()
    local first = way and way.first
    if not first or first.kind ~= "fly" or not first.to or not first.to.node then return nil end
    return { node = first.to.node, name = first.to.name }
end

local function buildRing()
    ring = CreateFrame("Frame")
    local tex = ring:CreateTexture(nil, "OVERLAY")
    tex:SetTexture(RING)
    tex:SetBlendMode("ADD")
    tex:SetVertexColor(COLOR[1], COLOR[2], COLOR[3])
    tex:SetAllPoints(ring)
    local pulse = ring:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.35)
    fade:SetDuration(0.6)
    ring.pulse = pulse
end

local function unmark()
    marked = nil
    if ring then
        ring.pulse:Stop()
        ring:Hide()
    end
end

local function mark(pin)
    if marked == pin and ring and ring:IsShown() then return end
    if not ring then buildRing() end
    marked = pin
    ring:SetParent(pin)
    ring:ClearAllPoints()
    ring:SetPoint("CENTER", pin, "CENTER", 0, 0)
    -- the border texture's ring fills about half of its square
    local size = math.max(pin:GetWidth() or 0, pin:GetHeight() or 0, 12) * 3.4
    ring:SetSize(size, size)
    ring:SetFrameLevel((pin:GetFrameLevel() or 1) + 1)
    ring:Show()
    ring.pulse:Play()
    -- the pin's own tooltip is drawn first; our line goes under it
    if not hooked[pin] then
        hooked[pin] = true
        pin:HookScript("OnEnter", function(self)
            local tip = rawget(_G, "GameTooltip")
            if self ~= marked or not ring or not ring:IsShown() or not tip or not tip:IsShown() then return end
            tip:AddLine(FlightMap.TOOLTIP, COLOR[1], COLOR[2], COLOR[3])
            tip:Show()
        end)
    end
end

-- The modern flight map (FlightMapFrame, a map canvas): the pin whose taxiNodeData is this
-- flight point, whatever template it was made from. Returns the pin and whether it can be flown to.
local function modernPin(map, node)
    local pins
    if type(map.EnumerateAllPins) == "function" then
        pins = map:EnumerateAllPins()
    elseif type(map.EnumeratePinsByTemplate) == "function" then
        pins = map:EnumeratePinsByTemplate(FlightMap.PIN_TEMPLATE)
    end
    if not pins then return nil end
    local seen = false
    for pin in pins do
        local data = pin.taxiNodeData
        if type(data) == "table" then
            seen = true
            -- Enum.FlightPathState: 0 current, 1 reachable, 2 unreachable
            if data.nodeID == node then return pin, data.state ~= 2, true end
        end
    end
    return nil, false, seen
end

-- The classic flight map (TaxiFrame): its buttons TaxiButton1..n are the map's slots. The slot
-- of a flight point comes from the game's node list; where that has no slots, from its name
-- ("Darkshire, Duskwood" starts with "Darkshire").
local function classicPin(node, name)
    local count = Game.safe(rawget(_G, "NumTaxiNodes")) or 0
    if count == 0 then return nil, false, false end
    local slot
    local mapId = Game.safe(rawget(_G, "C_Map") and C_Map.GetBestMapForUnit, "player")
    local nodes = mapId and Game.safe(rawget(_G, "C_TaxiMap") and C_TaxiMap.GetAllTaxiNodes, mapId)
    for _, n in ipairs(type(nodes) == "table" and nodes or {}) do
        if type(n) == "table" and n.nodeID == node and n.slotIndex then slot = n.slotIndex end
    end
    if not slot and name then
        for i = 1, count do
            local label = Game.safe(rawget(_G, "TaxiNodeName"), i)
            if type(label) == "string" and label:sub(1, #name) == name then slot = i break end
        end
    end
    local button = slot and rawget(_G, "TaxiButton" .. slot)
    if not button or not button:IsShown() then return nil, false, true end
    local kind = Game.safe(rawget(_G, "TaxiNodeGetType"), slot)
    return button, kind == nil or kind == "REACHABLE", true
end

local function shown(name)
    local frame = rawget(_G, name)
    return frame and frame:IsShown() and frame or nil
end

-- The destination's pin on whichever flight map is open: pin, can be flown to, pins are drawn.
local function findPin(dest)
    local map = shown("FlightMapFrame")
    if map then
        local pin, reachable, drawn = modernPin(map, dest.node)
        if pin or drawn then return pin, reachable, drawn end
    end
    if shown("TaxiFrame") then return classicPin(dest.node, dest.name) end
    return nil, false, false
end

--- Put the ring on the destination's pin (or take it away). Called while a flight map is open.
function FlightMap.Refresh()
    local dest = FlightMap.Destination()
    if not dest then return unmark() end
    local ok, pin, reachable, drawn = pcall(findPin, dest)
    if ok and pin and reachable then return mark(pin) end
    unmark()
    -- the pins are drawn a moment after the map opens: only say so once they are there
    if ok and drawn and told ~= dest.node then
        told = dest.node
        ns.Print("%s is not a flight you can take from here.", tostring(dest.name or "The flight point of your route"))
    end
end

--- What the highlight sees right now, for /ls taxi (with a flight master's map open).
function FlightMap.Describe()
    local out = {}
    local dest = FlightMap.Destination()
    out[#out + 1] = dest and string.format("fly to: %s (node %s)", tostring(dest.name), tostring(dest.node))
        or "the way to the current step does not start with a flight"
    for _, name in ipairs({ "FlightMapFrame", "TaxiFrame" }) do
        local frame = rawget(_G, name)
        out[#out + 1] = name .. ": " .. (not frame and "not there" or frame:IsShown() and "open" or "closed")
    end
    local map, pins, withNode = shown("FlightMapFrame"), 0, 0
    if map and type(map.EnumerateAllPins) == "function" then
        pcall(function()
            for pin in map:EnumerateAllPins() do
                pins = pins + 1
                if type(pin.taxiNodeData) == "table" then withNode = withNode + 1 end
            end
        end)
        out[#out + 1] = string.format("FlightMapFrame pins: %d, with a flight point: %d", pins, withNode)
    end
    out[#out + 1] = "classic slots: " .. tostring(Game.safe(rawget(_G, "NumTaxiNodes")) or "none")
    if dest then
        local ok, pin, reachable, drawn = pcall(findPin, dest)
        out[#out + 1] = not ok and ("error: " .. tostring(pin))
            or string.format("pin found: %s, can fly: %s, pins drawn: %s", tostring(pin ~= nil), tostring(reachable), tostring(drawn))
    end
    out[#out + 1] = "watching: " .. tostring(watcher ~= nil and watcher:IsShown())
    return out
end

-- Runs between the flight map opening and closing.
local function watch()
    if not watcher then
        watcher = CreateFrame("Frame")
        watcher:Hide()
        watcher:SetScript("OnUpdate", function(self, elapsed)
            self.since = (self.since or 0) + elapsed
            if self.since < FlightMap.EVERY then return end
            self.since = 0
            FlightMap.Refresh()
        end)
    end
    watcher.since = FlightMap.EVERY -- look on the next frame: the map is shown by then
    watcher:Show()
end

--- Called once at login.
function FlightMap.Start()
    Game.Listen({ "TAXIMAP_OPENED", "TAXIMAP_CLOSED" }, function(event)
        told = nil
        if event == "TAXIMAP_CLOSED" then
            if watcher then watcher:Hide() end
            return unmark()
        end
        watch()
    end)
end
