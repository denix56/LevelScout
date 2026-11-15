-- ui/Debug.lua: the search view (debug). Shows how the planner's search arrived at the route:
-- the route drawn on the zone's map, one frame per search round, with a slider to step
-- through them, and a curve of what the route was worth round by round.
-- Open with /ls debug or from the options menu. While it is open, the engine records the
-- search of the shown zone on every full re-plan (ns.Engine.SetTrace).

local _, ns = ...
local Engine, Format, Zones, Game = ns.Engine, ns.Format, ns.Zones, ns.Game

local Debug = {}
ns.Debug = Debug

local W, H = 480, 320          -- the map: 3 by 2, like the game's zone maps
local CHART_H = 46
local PAD, INSET = 10, 6
local PLAY_SECONDS = 0.12      -- per frame while playing

local GOLD, BLUE = { 1.00, 0.82, 0.00 }, { 0.35, 0.65, 1.00 }
local KIND_COLOR = { S = { 1, 1, 1 }, P = { 1.00, 0.82, 0.00 }, W = { 1.00, 0.35, 0.30 }, T = { 0.35, 1.00, 0.35 } }
local KIND_WORD = { start = "Route as first built", final = "Final route (slow quests dropped, tidied)",
    best = "new best", better = "better: kept", kept = "slightly worse: kept for now", rejected = "worse: undone" }
local KIND_HEX = { best = "|cff59ff59", better = "|cff59ff59", kept = "|cffffcc40", rejected = "|cffff5040" }

local root
local state = { index = 1, frames = {}, zone = nil, playing = false }
Debug.state = state -- read by tests
local pool = { lines = {}, dots = {}, rings = {}, chart = {}, tiles = {} }

local function text(parent, font, justify)
    local f = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    f:SetJustifyH(justify or "LEFT")
    f:SetWordWrap(false)
    return f
end

local function solid(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(r, g, b, a or 1)
    return t
end

-- A line between two points of `parent` (x right, y down from its top-left), or nil when
-- this client cannot draw lines.
local function line(list, i, parent)
    local l = list[i]
    if l == nil then
        l = parent.CreateLine and parent:CreateLine(nil, "ARTWORK") or false
        list[i] = l
    end
    return l or nil
end

local function setLine(l, parent, x1, y1, x2, y2, c, alpha, thick)
    l:SetThickness(thick or 2)
    l:SetColorTexture(c[1], c[2], c[3], alpha or 1)
    l:SetStartPoint("TOPLEFT", parent, x1, -y1)
    l:SetEndPoint("TOPLEFT", parent, x2, -y2)
    l:Show()
end

local function hideFrom(list, from)
    for i = from, #list do
        if list[i] then list[i]:Hide() end
    end
end

-- The zone's own map art behind the route, where the client offers it.
local function drawMap(mapId)
    hideFrom(pool.tiles, 1)
    local api = rawget(_G, "C_Map")
    if type(mapId) ~= "number" or not api or not api.GetMapArtLayers or not api.GetMapArtLayerTextures then return false end
    local ok, layers = pcall(api.GetMapArtLayers, mapId)
    local ok2, files = pcall(api.GetMapArtLayerTextures, mapId, 1)
    local layer = ok and type(layers) == "table" and layers[1] or nil
    if not layer or not ok2 or type(files) ~= "table" or #files == 0 then return false end
    local lw, tw, th = layer.layerWidth, layer.tileWidth, layer.tileHeight
    if type(lw) ~= "number" or lw <= 0 or type(tw) ~= "number" or tw <= 0 or type(th) ~= "number" then return false end
    local scale, cols = W / lw, math.ceil(lw / tw)
    for i, file in ipairs(files) do
        local t = pool.tiles[i]
        if not t then
            t = root.canvas:CreateTexture(nil, "BACKGROUND")
            pool.tiles[i] = t
        end
        t:SetTexture(file)
        t:SetVertexColor(0.55, 0.55, 0.55) -- dimmed, so the route stands out
        t:SetSize(tw * scale, th * scale)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", ((i - 1) % cols) * tw * scale, -math.floor((i - 1) / cols) * th * scale)
        t:Show()
    end
    return true
end

-- Canvas position of a recorded point { map, mx, my, kind }, or nil when it is on another map.
local function place(point)
    if not point or point[1] ~= state.map or not point[2] then return nil end
    return point[2] / 100 * W, point[3] / 100 * H
end

local function caption(f, i, n)
    local top
    if f.round then
        local took = #(f.names or {})
        top = string.format("Round %d of %d  |cff808080·|r  took out %d quest%s (%s)  |cff808080·|r  %s%s|r", f.round, f.rounds or 0,
            took, took == 1 and "" or "s", f.took or "?", KIND_HEX[f.kind] or "", KIND_WORD[f.kind] or f.kind)
        if f.restart then top = top .. "|cff808080, then back to the best route|r" end
    else
        top = "|cffffd100" .. (KIND_WORD[f.kind] or f.kind) .. "|r"
        if #state.frames <= 2 then top = top .. "  |cff808080·|r  dungeon plans are not searched" end
    end
    local stops, off = 0, 0
    for _, p in ipairs(f.points) do
        stops = stops + 1
        if p[4] ~= "S" and not place(p) then off = off + 1 end
    end
    local bottom = string.format("%s XP/h at the best moment to leave  |cff808080·|r  %d quests, %d stops%s", Format.Number(f.score or 0),
        f.quests or 0, math.max(0, stops - 1), off > 0 and string.format(" (%d on other maps, not drawn)", off) or "")
    return top, bottom, string.format("%d / %d", i, n)
end

--- Draw frame `i` of the recorded search.
function Debug.Show(i)
    if not root then return end
    local frames = state.frames
    local n = #frames
    if n == 0 then
        root.top:SetText("No search recorded yet")
        root.bottom:SetText(Engine.view.busy and "Planning..." or "Nothing to show for this plan. Re-plan from the options menu.")
        root.count:SetText("")
        hideFrom(pool.lines, 1); hideFrom(pool.dots, 1); hideFrom(pool.rings, 1); hideFrom(pool.chart, 1)
        root.marker:Hide()
        return
    end
    i = math.max(1, math.min(n, math.floor((i or state.index) + 0.5)))
    state.index = i
    local f = frames[i]
    local top, bottom, count = caption(f, i, n)
    root.top:SetText(top)
    root.bottom:SetText(bottom)
    root.count:SetText(count)
    if root.slider.GetValue and root.slider:GetValue() ~= i then
        state.setting = true
        root.slider:SetValue(i)
        state.setting = false
    end

    -- the route: a line through the stops, gold at the start to blue at the end
    local canvas = root.canvas
    local used, dots, total = 0, 0, #f.points
    local px, py
    for k, p in ipairs(f.points) do
        local x, y = place(p)
        if x then
            if px then
                local l = line(pool.lines, used + 1, canvas)
                if l then
                    used = used + 1
                    local t = total > 1 and (k - 1) / (total - 1) or 0
                    setLine(l, canvas, px, py, x, y, { GOLD[1] + (BLUE[1] - GOLD[1]) * t, GOLD[2] + (BLUE[2] - GOLD[2]) * t,
                        GOLD[3] + (BLUE[3] - GOLD[3]) * t }, 0.9, 2)
                end
            end
            dots = dots + 1
            local d = pool.dots[dots]
            if not d then
                d = solid(canvas, "OVERLAY", 1, 1, 1)
                pool.dots[dots] = d
            end
            local c = KIND_COLOR[p[4]] or KIND_COLOR.W
            local size = p[4] == "S" and 9 or 5
            d:SetColorTexture(c[1], c[2], c[3], 1)
            d:SetSize(size, size)
            d:ClearAllPoints()
            d:SetPoint("CENTER", canvas, "TOPLEFT", x, -y)
            d:Show()
        end
        px, py = x, y -- a stop on another map breaks the line
    end
    hideFrom(pool.lines, used + 1)
    hideFrom(pool.dots, dots + 1)
    state.drawn = { lines = used, dots = dots }

    -- what this round took out: red marks under the stops
    local rings = 0
    for _, p in ipairs(f.out or {}) do
        local x, y = place(p)
        if x then
            rings = rings + 1
            local r = pool.rings[rings]
            if not r then
                r = solid(canvas, "ARTWORK", 1, 0.2, 0.15, 0.55)
                pool.rings[rings] = r
            end
            r:SetSize(13, 13)
            r:ClearAllPoints()
            r:SetPoint("CENTER", canvas, "TOPLEFT", x, -y)
            r:Show()
        end
    end
    hideFrom(pool.rings, rings + 1)

    -- the curve: what each round's route was worth (grey) and the best so far (gold)
    local lo, hi = math.huge, 0
    local best = {}
    for k, fr in ipairs(frames) do
        local w = fr.worth or 0
        best[k] = math.max(best[k - 1] or 0, fr.kind == "final" and 0 or w)
        if w > 0 and w < lo then lo = w end
        if w > hi then hi = w end
    end
    if lo == math.huge then lo = 0 end
    local span = math.max(hi - lo, 1)
    local function cx(k) return n > 1 and (k - 1) / (n - 1) * W or 0 end
    local function cy(w) return CHART_H - 3 - (math.max(w, lo) - lo) / span * (CHART_H - 6) end
    local c = 0
    for k = 2, n do
        local grey, gold = line(pool.chart, c + 1, root.chart), line(pool.chart, c + 2, root.chart)
        if grey and gold then
            c = c + 2
            setLine(grey, root.chart, cx(k - 1), cy(frames[k - 1].worth or 0), cx(k), cy(frames[k].worth or 0), { 0.6, 0.6, 0.6 }, 0.7, 1)
            setLine(gold, root.chart, cx(k - 1), cy(best[k - 1]), cx(k), cy(best[k]), GOLD, 1, 2)
        end
    end
    hideFrom(pool.chart, c + 1)
    root.marker:ClearAllPoints()
    root.marker:SetPoint("TOPLEFT", root.chart, "TOPLEFT", cx(i), 0)
    root.marker:Show()
end

--- Take the latest recorded search from the engine.
function Debug.Refresh()
    if not root or not root:IsShown() then return end
    local trace = Engine.view.trace
    local frames = trace and trace.frames or {}
    if frames ~= state.frames then
        state.frames, state.zone, state.playing = frames, trace and trace.zone or nil, false
        state.index = #frames -- the final route first; drag back to see how it came about
        root.title:SetText("Search view" .. (state.zone and (": " .. (Zones.Name(state.zone) or Game.MapName(state.zone) or state.zone)) or ""))
        root.slider:SetMinMaxValues(1, math.max(1, #frames))
        -- the map to draw on: the one most of the final route's stops are on (for a dungeon
        -- that is the zone of its entrance and quest givers, not the dungeon itself)
        local count, most = {}, 0
        state.map = nil
        for _, p in ipairs(frames[#frames] and frames[#frames].points or {}) do
            if p[1] and p[2] then
                count[p[1]] = (count[p[1]] or 0) + 1
                if count[p[1]] > most or (count[p[1]] == most and p[1] < state.map) then state.map, most = p[1], count[p[1]] end
            end
        end
        state.map = state.map or state.zone
        root.mapShown = state.map and drawMap(state.map) or false
    end
    root.play.label:SetText(state.playing and "Pause" or "Play")
    Debug.Show(state.index)
end

local function build()
    local template = rawget(_G, "BackdropTemplateMixin") and "BackdropTemplate" or nil
    root = CreateFrame("Frame", "LevelScoutDebugFrame", UIParent, template)
    if root.SetBackdrop then
        root:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        root:SetBackdropColor(0, 0, 0, 0.92)
        root:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
    root:SetFrameStrata("HIGH")
    root:SetSize(W + 2 * (PAD + INSET), 30 + 34 + H + 8 + CHART_H + 34 + 18 + 2 * INSET)
    root:SetPoint("CENTER", UIParent, "CENTER", -120, 40)
    root:SetClampedToScreen(true)
    root:EnableMouse(true)
    root:SetMovable(true)
    root:RegisterForDrag("LeftButton")
    root:SetScript("OnDragStart", function(self) self:StartMoving() end)
    root:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local left, y = PAD + INSET, -INSET
    root.title = text(root, "GameFontNormal")
    root.title:SetPoint("TOPLEFT", left, y - 8)
    root.title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    local close = CreateFrame("Button", nil, root)
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", -INSET - 2, y - 3)
    close.label = text(close, "GameFontHighlight", "CENTER")
    close.label:SetAllPoints()
    close.label:SetText("x")
    close:SetScript("OnClick", function() Debug.Toggle(false) end)
    root.count = text(root, "GameFontHighlightSmall", "RIGHT")
    root.count:SetPoint("RIGHT", close, "LEFT", -8, 0)
    y = y - 30

    root.top = text(root)
    root.top:SetPoint("TOPLEFT", left, y)
    root.top:SetWidth(W)
    root.bottom = text(root)
    root.bottom:SetPoint("TOPLEFT", left, y - 15)
    root.bottom:SetWidth(W)
    root.bottom:SetTextColor(0.78, 0.78, 0.78)
    y = y - 34

    local canvas = CreateFrame("Frame", nil, root)
    canvas:SetSize(W, H)
    canvas:SetPoint("TOPLEFT", left, y)
    if canvas.SetClipsChildren then canvas:SetClipsChildren(true) end
    canvas.bg = solid(canvas, "BACKGROUND", 0.07, 0.08, 0.10, 1)
    canvas.bg:SetAllPoints()
    if canvas.bg.SetDrawLayer then canvas.bg:SetDrawLayer("BACKGROUND", -8) end
    root.canvas = canvas
    y = y - H - 8

    local chart = CreateFrame("Frame", nil, root)
    chart:SetSize(W, CHART_H)
    chart:SetPoint("TOPLEFT", left, y)
    chart.bg = solid(chart, "BACKGROUND", 1, 1, 1, 0.05)
    chart.bg:SetAllPoints()
    root.chart = chart
    root.marker = solid(chart, "OVERLAY", 1, 1, 1, 0.8)
    root.marker:SetSize(1, CHART_H)
    y = y - CHART_H - 8

    local play = CreateFrame("Button", nil, root)
    play:SetSize(52, 20)
    play:SetPoint("TOPLEFT", left, y)
    play.bg = solid(play, "BACKGROUND", 1, 1, 1, 0.10)
    play.bg:SetAllPoints()
    play.label = text(play, "GameFontHighlightSmall", "CENTER")
    play.label:SetAllPoints()
    play.label:SetText("Play")
    play:SetScript("OnClick", function()
        state.playing = not state.playing
        if state.playing and state.index >= #state.frames then state.index = 1 end -- from the start
        Debug.Refresh()
    end)
    root.play = play

    local slider = CreateFrame("Slider", nil, root)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(W - 62, 20)
    slider:SetPoint("LEFT", play, "RIGHT", 10, 0)
    slider.track = solid(slider, "BACKGROUND", 1, 1, 1, 0.15)
    slider.track:SetPoint("LEFT", 0, 0); slider.track:SetPoint("RIGHT", 0, 0); slider.track:SetHeight(4)
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    slider:SetMinMaxValues(1, 1)
    slider:SetValueStep(1)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    slider:SetScript("OnValueChanged", function(_, value)
        if state.setting or type(value) ~= "number" then return end
        state.playing = false
        root.play.label:SetText("Play")
        Debug.Show(value)
    end)
    root.slider = slider
    y = y - 26

    root.legend = text(root)
    root.legend:SetPoint("TOPLEFT", left, y)
    root.legend:SetWidth(W)
    root.legend:SetTextColor(0.5, 0.5, 0.5)
    root.legend:SetText("Line: the route, |cffffd100start|r to |cff59a6ffend|r   |cffffd100accept|r  |cffff5a4dwork|r  |cff59ff59turn in|r   "
        .. "|cffff3326red|r: taken out this round   Wheel: step")

    root:EnableMouseWheel(true)
    root:SetScript("OnMouseWheel", function(_, delta)
        state.playing = false
        root.play.label:SetText("Play")
        Debug.Show(state.index + (delta > 0 and -1 or 1))
    end)
    local since = 0
    root:SetScript("OnUpdate", function(_, elapsed)
        if not state.playing then return end
        since = since + (elapsed or 0)
        if since < PLAY_SECONDS then return end
        since = 0
        if state.index >= #state.frames then
            state.playing = false
            root.play.label:SetText("Play")
        else
            Debug.Show(state.index + 1)
        end
    end)
    Engine.OnChange(function() Debug.Refresh() end)
    root:Hide()
end

--- Show or hide the search view (nil toggles). Recording runs only while it is open.
function Debug.Toggle(show)
    if not root then build() end
    if show == nil then show = not root:IsShown() end
    if show then
        root:Show()
        state.frames = {} -- take whatever the engine has now
        Engine.SetTrace(true)
        Debug.Refresh()
    else
        root:Hide()
        state.playing = false
        Engine.SetTrace(false)
    end
end

function Debug.IsShown() return root ~= nil and root:IsShown() end
