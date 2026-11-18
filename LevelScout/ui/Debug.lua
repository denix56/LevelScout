-- ui/Debug.lua: the search view (debug). Shows how the planner's search arrived at the route:
-- the route drawn on the zone's map, one frame per search round, with a slider to step
-- through them, and a curve of what the route was worth round by round. The map numbers the
-- route's stops in the order they are visited (steps at one place share a marker), and a list of
-- the route's steps sits to the right of the map and follows the slider; hovering a step lights
-- up its marker and hovering a marker its steps. The window resizes from its corner and keeps its
-- size and place (LevelScoutDB.debugWindow).
-- Open with /ls debug or from the options menu. While it is open, the engine records the
-- search of the shown zone on every full re-plan (ns.Engine.SetTrace).

local _, ns = ...
local Engine, Format, Zones, Game = ns.Engine, ns.Format, ns.Zones, ns.Game

local Debug = {}
ns.Debug = Debug

local MAP_W, MAP_H = 480, 320  -- the map at the default size: 3 by 2, like the game's zone maps
local CHART_H = 46
local PAD, INSET = 10, 6
local GAP, LIST_W = 10, 250    -- the steps list, right of the map
local ROW_H, NUM_W, PILL_W = 26, 20, 52
local CHROME_W = 2 * (PAD + INSET) + GAP + LIST_W                 -- what the window has besides the map: sides and list
local CHROME_H = 30 + 34 + 8 + CHART_H + 34 + 18 + 2 * INSET      -- title, captions, slider and legend, margins
local DEFAULT_W, DEFAULT_H = MAP_W + CHROME_W, MAP_H + CHROME_H
local MIN_W, MIN_H = 300 + CHROME_W, 200 + CHROME_H
local MAX_W, MAX_H = 1900, 1300
local SAME_PLACE = 0.6         -- map percent: closer stops are one marker
local LABEL_RUNS, TIP_MAX, SCROLL_STEP = 3, 8, 2
local PLAY_SECONDS = 0.12      -- per frame while playing

local GOLD, BLUE = { 1.00, 0.82, 0.00 }, { 0.35, 0.65, 1.00 }
local KIND_COLOR = { S = { 1, 1, 1 }, P = { 1.00, 0.82, 0.00 }, W = { 1.00, 0.35, 0.30 }, T = { 0.35, 1.00, 0.35 } }
local KIND_WORD = { start = "Route as first built", final = "Final route (slow quests dropped, tidied)",
    best = "new best", better = "better: kept", kept = "slightly worse: kept for now", rejected = "worse: undone" }
local KIND_HEX = { best = "|cff59ff59", better = "|cff59ff59", kept = "|cffffcc40", rejected = "|cffff5040" }
local STEP_KIND = { accept = "P", turnin = "T", work = "W" }   -- for KIND_COLOR
-- a stop recorded without a description (an older recording): just enough for Format.StepTitle
local FALLBACK = { P = { kind = "accept", action = "accept" }, T = { kind = "turnin", action = "turnin" }, W = { kind = "work", action = "do" } }

local root
local settings -- LevelScoutDB.debugWindow: { w, h, pos = { point, relPoint, x, y } }
local state = { index = 1, frames = {}, zone = nil, playing = false, scroll = 0, geo = {}, steps = {}, groups = {}, groupOf = {}, offMap = {} }
Debug.state = state -- read by tests
local geo = state.geo -- the window's sizes, worked out by layout(); never read back from the frames
local pool = { lines = {}, dots = {}, rings = {}, chart = {}, tiles = {}, nodes = {}, rows = {} }
Debug.MIN_W, Debug.MIN_H, Debug.DEFAULT_W, Debug.DEFAULT_H = MIN_W, MIN_H, DEFAULT_W, DEFAULT_H -- for tests

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
    if type(lw) ~= "number" or lw <= 0 or type(tw) ~= "number" or tw <= 0 or type(th) ~= "number" or th <= 0 then return false end
    local lh = type(layer.layerHeight) == "number" and layer.layerHeight > 0 and layer.layerHeight or nil
    local scale, cols = geo.drawW / lw, math.ceil(lw / tw)
    for i, file in ipairs(files) do
        local t = pool.tiles[i]
        if not t then
            t = root.canvas:CreateTexture(nil, "BACKGROUND")
            pool.tiles[i] = t
        end
        t:SetTexture(file)
        t:SetVertexColor(0.55, 0.55, 0.55) -- dimmed, so the route stands out
        -- the last column and row of tiles reach past the map: cut them at its edge, so nothing
        -- of them shows in the margin around the map
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        local vw, vh = math.min(tw, lw - col * tw), lh and math.min(th, lh - row * th) or th
        if vw > 0 and vh > 0 then
            t:SetTexCoord(0, vw / tw, 0, vh / th)
            t:SetSize(vw * scale, vh * scale)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", geo.ox + col * tw * scale, -(geo.oy + row * th * scale))
            t:Show()
        else
            t:Hide()
        end
    end
    return true
end

-- Canvas position of a recorded point { map, mx, my, kind }, or nil when it is on another map.
local function place(point)
    if not point or point[1] ~= state.map or not point[2] then return nil end
    return geo.ox + point[2] / 100 * geo.drawW, geo.oy + point[3] / 100 * geo.drawH
end

--- Steps that share a place: groups[g] = { mx, my, kind, steps = { k, ... } } and groupOf[k] = g,
--- for the steps (point k + 1; the start is no step) on `map`. Same place: within SAME_PLACE map
--- percent of the group's first stop, grouped in route order.
function Debug.Group(points, map)
    local groups, groupOf = {}, {}
    for k = 2, #points do
        local p = points[k]
        if p[1] == map and p[2] and p[3] then
            local g
            for gi, grp in ipairs(groups) do
                if math.abs(grp.mx - p[2]) <= SAME_PLACE and math.abs(grp.my - p[3]) <= SAME_PLACE then g = gi break end
            end
            if not g then g = #groups + 1; groups[g] = { mx = p[2], my = p[3], kind = p[4], steps = {} } end
            local s = groups[g].steps
            s[#s + 1] = k - 1
            groupOf[k - 1] = g
        end
    end
    return groups, groupOf
end

--- A marker's label: "4", "3,4", "3-5", "1,2,4", "1,3,5 +2" (steps: increasing; at most
--- LABEL_RUNS runs, then how many steps are left out).
function Debug.Label(steps)
    local runs, i = {}, 1
    while i <= #steps do
        local j = i
        while steps[j + 1] == steps[j] + 1 do j = j + 1 end
        runs[#runs + 1] = { steps[i], steps[j] }
        i = j + 1
    end
    local parts = {}
    for r = 1, math.min(#runs, LABEL_RUNS) do
        local a, b = runs[r][1], runs[r][2]
        parts[r] = a == b and tostring(a) or (b == a + 1 and (a .. "," .. b) or (a .. "-" .. b))
    end
    local out = table.concat(parts, ",")
    if #runs > LABEL_RUNS then
        local rest = 0
        for r = LABEL_RUNS + 1, #runs do rest = rest + runs[r][2] - runs[r][1] + 1 end
        out = out .. " +" .. rest
    end
    return out
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

local function num(v) return type(v) == "number" and v == v and v or nil end

-- A window size inside the limits, whole pixels (anything that is not a number: the default).
local function fit(w, h)
    w, h = num(w) or DEFAULT_W, num(h) or DEFAULT_H
    return math.floor(math.max(MIN_W, math.min(MAX_W, w)) + 0.5), math.floor(math.max(MIN_H, math.min(MAX_H, h)) + 0.5)
end

-- Work out every size from the window's (the children are anchored to each other in build) and
-- set them. The map is the largest 3 by 2 rectangle that fits what is left of the list and
-- above the curve, centred there. Sizes are kept in `geo`: the client's getters are not read.
local function layout(w, h)
    w, h = fit(w, h)
    geo.w, geo.h = w, h
    geo.areaW, geo.areaH = w - CHROME_W, h - CHROME_H
    geo.drawW = math.min(geo.areaW, geo.areaH * 1.5)
    geo.drawH = geo.drawW / 1.5
    geo.ox, geo.oy = (geo.areaW - geo.drawW) / 2, (geo.areaH - geo.drawH) / 2
    geo.listH = geo.areaH + 8 + CHART_H + 8 + 20 -- down to the slider's bottom
    geo.rows = math.max(1, math.floor(geo.listH / ROW_H))
    local contentW = w - 2 * (PAD + INSET)
    root:SetSize(w, h)
    root.top:SetWidth(contentW); root.bottom:SetWidth(contentW); root.legend:SetWidth(contentW - 20) -- (the grip's corner)
    root.canvas:SetSize(geo.areaW, geo.areaH)
    root.canvas.board:ClearAllPoints()
    root.canvas.board:SetPoint("TOPLEFT", root.canvas, "TOPLEFT", geo.ox, -geo.oy)
    root.canvas.board:SetSize(geo.drawW, geo.drawH)
    root.chart:SetSize(geo.areaW, CHART_H)
    root.slider:SetSize(geo.areaW - 62, 20)
    root.list:SetSize(LIST_W, geo.listH)
    return w, h
end

local function savePosition()
    local point, _, relPoint, x, y = root:GetPoint(1)
    settings.pos = { point or "CENTER", relPoint or "CENTER", x or 0, y or 0 }
end

local function applyPosition()
    local p = settings.pos
    root:ClearAllPoints()
    if p then root:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else root:SetPoint("CENTER", UIParent, "CENTER", -120, 40) end
end

--- Light up marker `g` and the rows of its steps (nil: nothing).
function Debug.Hover(g)
    state.hover = g
    if not root then return end
    local base = root.canvas:GetFrameLevel() or 0
    for gi, n in ipairs(pool.nodes) do
        local on = g ~= nil and gi == g
        if on then n.ring:Show() else n.ring:Hide() end
        n.label:SetTextColor(on and GOLD[1] or 1, on and GOLD[2] or 1, on and GOLD[3] or 1)
        n:SetFrameLevel(base + (on and 5 or 2))
    end
    for _, r in ipairs(pool.rows) do
        local on = r.step ~= nil and (r == state.hoverRow or (g ~= nil and state.groupOf[r.step] == g))
        if on then r.hl:Show() else r.hl:Hide() end
    end
end

-- the marker of whatever is under the mouse now (a row's, or the marker itself)
local function hoverNow()
    local r, n = state.hoverRow, state.hoverNode
    if r and r:IsShown() and r.step then return state.groupOf[r.step] end
    if n and n:IsShown() then return n.group end
end

local function nodeTip(n)
    if not GameTooltip then return end
    local grp = state.groups[n.group]
    if not grp then return end
    GameTooltip:SetOwner(n, "ANCHOR_RIGHT")
    for i, k in ipairs(grp.steps) do
        if i > TIP_MAX then break end
        GameTooltip:AddLine(string.format("%d. %s", k, Format.StepTitle(state.steps[k])), 1, 1, 1)
    end
    if #grp.steps > TIP_MAX then GameTooltip:AddLine(string.format("+%d more", #grp.steps - TIP_MAX), 0.6, 0.6, 0.6) end
    GameTooltip:Show()
end

local function rowTip(r)
    local step = r.step and state.steps[r.step]
    if not GameTooltip or not step then return end
    GameTooltip:SetOwner(r, "ANCHOR_LEFT")
    GameTooltip:AddLine(Format.StepTitle(step), 1, 1, 1)
    for _, q in ipairs(step.quests or {}) do GameTooltip:AddLine(Format.QuestName(q.name, q.level), 0.78, 0.78, 0.78) end
    if step.kind ~= "work" and step.target then GameTooltip:AddLine(step.target, 0.78, 0.78, 0.78) end
    GameTooltip:Show()
end

local fillList

-- Marker `i` of the map (made when first needed).
local function nodeButton(i)
    local n = pool.nodes[i]
    if n then return n end
    n = CreateFrame("Button", nil, root.canvas)
    n:SetSize(16, 16)
    n.ring = solid(n, "ARTWORK", GOLD[1], GOLD[2], GOLD[3], 1)
    n.ring:SetSize(13, 13)
    n.ring:SetPoint("CENTER")
    n.ring:Hide()
    n.dot = solid(n, "OVERLAY", 1, 1, 1)
    n.dot:SetPoint("CENTER")
    n.label = text(n, "GameFontHighlightSmall")
    n.label:SetPoint("BOTTOMLEFT", n, "CENTER", 4, 2)
    local file, size = n.label:GetFont()
    if type(file) == "string" then n.label:SetFont(file, size or 10, "OUTLINE") end
    n:SetScript("OnEnter", function(self)
        state.hoverNode = self
        Debug.Hover(self.group)
        nodeTip(self)
    end)
    n:SetScript("OnLeave", function()
        state.hoverNode = nil
        Debug.Hover(nil)
        if GameTooltip then GameTooltip:Hide() end
    end)
    n:SetScript("OnClick", function(self)
        local grp = state.groups[self.group]
        if grp then state.scroll = grp.steps[1] - 1; fillList() end
    end)
    pool.nodes[i] = n
    return n
end

-- Row `i` of the steps list (made when first needed).
local function listRow(i)
    local r = pool.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, root.list)
    r:SetSize(LIST_W - 6, ROW_H)
    r:SetPoint("TOPLEFT", root.list, "TOPLEFT", 0, -(i - 1) * ROW_H)
    r.hl = solid(r, "BACKGROUND", GOLD[1], GOLD[2], GOLD[3], 0.18)
    r.hl:SetAllPoints()
    r.hl:Hide()
    r.num = text(r, "GameFontHighlightSmall", "RIGHT")
    r.num:SetPoint("TOPLEFT", 0, -2)
    r.num:SetWidth(NUM_W)
    r.num:SetTextColor(0.6, 0.6, 0.6)
    r.pill = text(r, "GameFontNormalSmall")
    r.pill:SetPoint("TOPLEFT", NUM_W + 4, -2)
    r.pill:SetWidth(PILL_W)
    r.title = text(r)
    r.title:SetPoint("TOPLEFT", NUM_W + 8 + PILL_W, -2)
    r.title:SetWidth(LIST_W - 6 - (NUM_W + 8 + PILL_W))
    r.sub = text(r)
    r.sub:SetPoint("TOPLEFT", NUM_W + 4, -14)
    r.sub:SetWidth(LIST_W - 6 - NUM_W - 4)
    r.sub:SetTextColor(0.6, 0.6, 0.6)
    r:SetScript("OnEnter", function(self)
        state.hoverRow = self
        Debug.Hover(state.groupOf[self.step])
        rowTip(self)
    end)
    r:SetScript("OnLeave", function()
        state.hoverRow = nil
        Debug.Hover(nil)
        if GameTooltip then GameTooltip:Hide() end
    end)
    pool.rows[i] = r
    return r
end

-- The steps list: the rows from state.scroll on, and the scroll bar's thumb.
fillList = function()
    local steps, n = state.steps, geo.rows
    local maxScroll = math.max(0, #steps - n)
    state.scroll = math.max(0, math.min(state.scroll or 0, maxScroll))
    local shown = 0
    for i = 1, n do
        local r, k = listRow(i), state.scroll + i
        local step = steps[k]
        if step then
            shown = shown + 1
            r.step = k
            r.num:SetText(tostring(k))
            r.pill:SetText(Format.LABEL[step.action] or "DO")
            local c = KIND_COLOR[STEP_KIND[step.kind] or "W"]
            r.pill:SetTextColor(c[1], c[2], c[3])
            r.title:SetText((Format.StepTitle(step):gsub("^Accept: ", ""):gsub("^Turn in: ", "")))
            local sub = step.kind == "work" and Format.QuestNames(step, true) or (step.target or "")
            if state.offMap[k] then sub = "|cff808080(other map)|r " .. sub end
            r.sub:SetText(sub)
            r:Show()
        else
            r.step = nil
            r:Hide()
        end
    end
    for i = n + 1, #pool.rows do pool.rows[i].step = nil; pool.rows[i]:Hide() end
    if #steps > n then
        local th = math.max(8, geo.listH * n / #steps)
        root.thumb:SetHeight(th)
        root.thumb:ClearAllPoints()
        root.thumb:SetPoint("TOPRIGHT", root.list, "TOPRIGHT", 0, -(geo.listH - th) * state.scroll / maxScroll)
        root.thumb:Show()
    else
        root.thumb:Hide()
    end
    state.drawn = state.drawn or {}
    state.drawn.rows = shown
    Debug.Hover(hoverNow())
    -- the tooltip of what is under the mouse: the row or marker may show other steps now
    local row, node = state.hoverRow, state.hoverNode
    if row and row:IsShown() and row.step then rowTip(row)
    elseif node and node:IsShown() then nodeTip(node)
    elseif (row or node) and GameTooltip then GameTooltip:Hide() end
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
        hideFrom(pool.nodes, 1)
        root.marker:Hide()
        state.steps, state.groups, state.groupOf, state.offMap = {}, {}, {}, {}
        fillList()
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

    -- the steps: stop k of the route is step k - 1 (the start is no step); stops on another map
    -- have no marker, and the list says so
    local steps, offMap = {}, {}
    for k = 2, #f.points do
        local p = f.points[k]
        steps[k - 1] = p[5] or FALLBACK[p[4]] or FALLBACK.W
        offMap[k - 1] = (p[1] ~= nil and p[2] ~= nil and p[1] ~= state.map) or nil
    end
    state.steps, state.offMap = steps, offMap
    state.groups, state.groupOf = Debug.Group(f.points, state.map)

    -- the route: a line through the stops, gold at the start to blue at the end
    local canvas = root.canvas
    local used, total = 0, #f.points
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
        end
        px, py = x, y -- a stop on another map breaks the line
    end
    hideFrom(pool.lines, used + 1)

    -- the start: a larger white square, unnumbered
    local dots = 0
    local sx, sy = place(f.points[1])
    if sx then
        dots = 1
        local d = pool.dots[1]
        if not d then
            d = solid(canvas, "OVERLAY", 1, 1, 1)
            pool.dots[1] = d
        end
        d:SetColorTexture(1, 1, 1, 1)
        d:SetSize(9, 9)
        d:ClearAllPoints()
        d:SetPoint("CENTER", canvas, "TOPLEFT", sx, -sy)
        d:Show()
    end
    hideFrom(pool.dots, dots + 1)

    -- one marker for each place on the route, numbered with the steps done there
    for g, grp in ipairs(state.groups) do
        local node = nodeButton(g)
        local x, y = place({ state.map, grp.mx, grp.my })
        node.group = g
        local c = KIND_COLOR[grp.kind] or KIND_COLOR.W
        local size = #grp.steps > 1 and 7 or 5
        node.dot:SetColorTexture(c[1], c[2], c[3], 1)
        node.dot:SetSize(size, size)
        node.label:SetText(Debug.Label(grp.steps))
        node:ClearAllPoints()
        node:SetPoint("CENTER", canvas, "TOPLEFT", x, -y)
        node:Show()
    end
    hideFrom(pool.nodes, #state.groups + 1)
    state.drawn = { lines = used, dots = dots + #state.groups, nodes = #state.groups }

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
    local function cx(k) return n > 1 and (k - 1) / (n - 1) * geo.areaW or 0 end
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
    fillList() -- (and the hover again, for what is under the mouse now)
end

--- Set the window's size (clamped; saved). The map, its markers and the list follow.
function Debug.Resize(w, h)
    if not root then return end
    settings.w, settings.h = layout(w, h)
    root.mapShown = state.map and drawMap(state.map) or false
    Debug.Show(state.index)
end

--- Take the latest recorded search from the engine.
function Debug.Refresh()
    if not root or not root:IsShown() then return end
    local trace = Engine.view.trace
    local frames = trace and trace.frames or {}
    if frames ~= state.frames then
        state.frames, state.zone, state.playing = frames, trace and trace.zone or nil, false
        state.index = #frames -- the final route first; drag back to see how it came about
        state.scroll = 0
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
    local db = Engine.db or {} -- LevelScoutDB (Engine.Start has made it; the view opens after login)
    db.debugWindow = type(db.debugWindow) == "table" and db.debugWindow or {}
    settings = db.debugWindow
    if not num(settings.w) then settings.w = nil end
    if not num(settings.h) then settings.h = nil end
    local p = settings.pos
    if type(p) ~= "table" or type(p[1]) ~= "string" or type(p[2]) ~= "string" or not num(p[3]) or not num(p[4]) then settings.pos = nil end

    local template = rawget(_G, "BackdropTemplateMixin") and "BackdropTemplate" or nil
    root = CreateFrame("Frame", "LevelScoutDebugFrame", UIParent, template)
    if root.SetBackdrop then
        root:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        root:SetBackdropColor(0, 0, 0, 0.92)
        root:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
    root:SetFrameStrata("HIGH")
    root:SetClampedToScreen(true)
    root:EnableMouse(true)
    root:SetMovable(true)
    root:RegisterForDrag("LeftButton")
    root:SetScript("OnDragStart", function(self) self:StartMoving() end)
    root:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePosition() end)

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
    root.bottom = text(root)
    root.bottom:SetPoint("TOPLEFT", left, y - 15)
    root.bottom:SetTextColor(0.78, 0.78, 0.78)
    y = y - 34

    -- (the sizes of what follows are set by layout(); the pieces hang on each other)
    local canvas = CreateFrame("Frame", nil, root)
    canvas:SetPoint("TOPLEFT", left, y)
    if canvas.SetClipsChildren then canvas:SetClipsChildren(true) end
    canvas.bg = solid(canvas, "BACKGROUND", 0.07, 0.08, 0.10, 1)
    canvas.bg:SetAllPoints()
    if canvas.bg.SetDrawLayer then canvas.bg:SetDrawLayer("BACKGROUND", -8) end
    -- the zone map's own 3 by 2 rectangle inside the area; the map art lies over it
    canvas.board = solid(canvas, "BACKGROUND", 0.10, 0.11, 0.13, 1)
    if canvas.board.SetDrawLayer then canvas.board:SetDrawLayer("BACKGROUND", -7) end
    root.canvas = canvas

    local chart = CreateFrame("Frame", nil, root)
    chart:SetPoint("TOPLEFT", canvas, "BOTTOMLEFT", 0, -8)
    chart.bg = solid(chart, "BACKGROUND", 1, 1, 1, 0.05)
    chart.bg:SetAllPoints()
    root.chart = chart
    root.marker = solid(chart, "OVERLAY", 1, 1, 1, 0.8)
    root.marker:SetSize(1, CHART_H)

    local play = CreateFrame("Button", nil, root)
    play:SetSize(52, 20)
    play:SetPoint("TOPLEFT", chart, "BOTTOMLEFT", 0, -8)
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

    root.legend = text(root)
    root.legend:SetPoint("TOPLEFT", play, "BOTTOMLEFT", 0, -6)
    root.legend:SetTextColor(0.5, 0.5, 0.5)
    root.legend:SetText("Line: |cffffd100start|r to |cff59a6ffend|r   Numbers: step order   "
        .. "|cffffd100accept|r |cffff5a4dwork|r |cff59ff59turn in|r   |cffff3326red|r: taken out   Wheel: step, list: scroll")

    -- the steps of the shown route, right of the map; rows are made as needed and scrolled in Lua
    local list = CreateFrame("Frame", nil, root)
    list:SetPoint("TOPLEFT", canvas, "TOPRIGHT", GAP, 0)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        state.scroll = (state.scroll or 0) + (delta > 0 and -SCROLL_STEP or SCROLL_STEP)
        fillList()
    end)
    root.list = list
    root.thumb = solid(list, "OVERLAY", 1, 1, 1, 0.18)
    root.thumb:SetWidth(2)
    root.thumb:Hide()
    root.nodes, root.rows = pool.nodes, pool.rows -- read by tests

    -- resize grip in the bottom-right corner, as the main window's: the size is worked out from
    -- the cursor in Lua (no client resizing), so it is the same everywhere and is clamped here
    local grip = CreateFrame("Button", nil, root)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel((root:GetFrameLevel() or 0) + 10)
    grip.tex = grip:CreateTexture(nil, "OVERLAY")
    grip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip.tex:SetAllPoints()
    grip.tex:SetAlpha(0.6)
    local function cursor()
        local x, y = GetCursorPosition()
        local scale = root:GetEffectiveScale()
        if not scale or scale <= 0 then scale = 1 end
        return (x or 0) / scale, (y or 0) / scale
    end
    grip:SetScript("OnEnter", function(self) self.tex:SetAlpha(1) end)
    grip:SetScript("OnLeave", function(self) if not self.drag then self.tex:SetAlpha(0.6) end end)
    grip:SetScript("OnMouseDown", function(self)
        -- hold the top-left corner still while the opposite corner moves
        local left, top = root:GetLeft(), root:GetTop()
        if left and top and (left ~= 0 or top ~= 0) then
            root:ClearAllPoints()
            root:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        end
        local x, y = cursor()
        self.drag = { x = x, y = y, w = geo.w, h = geo.h }
    end)
    grip:SetScript("OnMouseUp", function(self)
        self.drag = nil
        self.tex:SetAlpha(0.6)
        savePosition()
    end)
    grip:SetScript("OnUpdate", function(self)
        local d = self.drag
        if not d then return end
        local x, y = cursor()
        local w, h = fit(d.w + (x - d.x), d.h - (y - d.y))
        if w ~= geo.w or h ~= geo.h then Debug.Resize(w, h) end
    end)
    root.grip = grip

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
    layout(settings.w, settings.h) -- (the saved size is not written back until the user resizes)
    applyPosition()
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
