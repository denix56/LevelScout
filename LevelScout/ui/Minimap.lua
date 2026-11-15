-- ui/Minimap.lua: the round button on the edge of the minimap.
-- Left-click shows or hides the window; drag moves the button around the minimap.
-- Built by hand (no library): the game's own minimap-button border and highlight, a map icon.

local _, ns = ...

local Button = {}
ns.MinimapButton = Button

local ICON = "Interface\\Icons\\INV_Misc_Map_01"
local DEFAULT_ANGLE = 215 -- degrees; lower left of the minimap

local button, settings

local function place()
    local minimap = rawget(_G, "Minimap")
    if not button or not minimap then return end
    local angle = math.rad(settings.minimapAngle or DEFAULT_ANGLE)
    local radius = (minimap:GetWidth() or 140) / 2 + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

-- While dragging: follow the cursor around the minimap's edge.
local function follow()
    local minimap = rawget(_G, "Minimap")
    local mx, my = minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = minimap:GetEffectiveScale()
    if not mx or not my or not cx or not cy or not scale or scale == 0 then return end
    settings.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360
    place()
end

--- Show or hide the button (saved).
function Button.SetShown(show)
    if not settings then return end
    settings.minimapHidden = not show
    if button then
        if show then button:Show() else button:Hide() end
    end
end

function Button.IsShown() return settings ~= nil and not settings.minimapHidden end

--- Called once at login with the saved window settings.
function Button.Start(saved)
    settings = saved
    local minimap = rawget(_G, "Minimap")
    if button or not minimap then return end
    button = CreateFrame("Button", "LevelScoutMinimapButton", minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    button:SetScript("OnClick", function() ns.UI.Toggle() end)
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", follow) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("LevelScout", 1, 0.82, 0)
        local view = ns.Engine.view
        if view.plan and view.plan.steps[1] then
            GameTooltip:AddLine(ns.Format.StepTitle(view.plan.steps[1]), 1, 1, 1, true)
        elseif view.message then
            GameTooltip:AddLine(view.message, 0.78, 0.78, 0.78, true)
        end
        GameTooltip:AddLine("Click: show or hide the window", 0.5, 0.5, 0.5)
        GameTooltip:AddLine("Drag: move this button", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    place()
    if settings.minimapHidden then button:Hide() end
end
