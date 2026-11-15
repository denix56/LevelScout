-- core/Classes.lua: class quest chains. Which ones this character can work on now, and the
-- plan for one of them: the chain and its lead-up, nothing else (see Planner.Plan, ctx.chain). Pure Lua: reads ns.Data and the other core modules only.

local _, ns = ...

local Classes = {}
ns.Classes = Classes

-- Why a quest can never be done by this character: another race or side, a sibling taken,
-- the chain already done further on.
local function never(reason)
    if not reason then return false end
    return reason == "race" or reason == "faction" or reason == "class" or reason == "unknown quest"
        or reason:find("^exclusive") ~= nil or reason:find("^later quest") ~= nil or reason:find("^breadcrumb") ~= nil
end

local function repeats(q)
    return q.flags.repeatable or q.flags.daily or q.flags.weekly or q.flags.event
end

-- The chain's name: its last quest within reach now (none of the others there leads on from
-- it), the highest level of those, then the highest id. `ids` sorted.
local function nameOf(ids, quests)
    local leads = {}
    for _, id in ipairs(ids) do
        local q = quests[id]
        for _, pre in ipairs(q.preAll) do leads[pre] = true end
        for _, pre in ipairs(q.preAny) do leads[pre] = true end
        if q.nextInChain and quests[q.nextInChain] then leads[id] = true end
    end
    local best
    for _, id in ipairs(ids) do
        local q = quests[id]
        if not leads[id] and (not best or q.minLevel > best.minLevel or (q.minLevel == best.minLevel and id > best.id)) then best = q end
    end
    best = best or quests[ids[#ids]]
    return best and best.name or nil
end

-- One chain's state for this character from its quests (`members`, sorted ids; `quests` =
-- { [id] = quest record }): see Classes.Chains. false when nothing of it is left to do.
local function analyse(root, members, quests, ctx)
    local Data, Model = ns.Data, ns.Model
    local avail = ctx.avail
    local completed = avail.completed or {}
    local left, set, open, reach, nextLevel, inLog, level = {}, {}, {}, {}, nil, false, nil
    local function waits(lv)
        if lv > ctx.level and (not nextLevel or lv < nextLevel) then nextLevel = lv end
    end
    for _, id in ipairs(members) do
        local q = quests[id]
        if not completed[id] then
            local entry = ctx.log[id]
            local ok, why = true, nil
            if not entry then ok, why = Data.IsAvailable(id, avail) end
            if entry or not never(why) then
                left[#left + 1], set[id] = id, true
                if q.minLevel <= ctx.level then reach[#reach + 1] = id end
                local isOpen = entry ~= nil or (ok and not Model.Unconfirmed(q) and q.minLevel <= ctx.level)
                if isOpen then
                    open[#open + 1] = id
                    if entry then inLog = true end
                    if not level or q.minLevel < level then level = q.minLevel end
                else
                    waits(q.minLevel)
                end
            end
        end
    end
    if #left == 0 then return false end
    return { id = root, quests = left, set = set, open = open, sig = table.concat(open, ","),
        level = level, nextLevel = nextLevel, inLog = inLog,
        name = nameOf(#reach > 0 and reach or left, quests) or ("Quest " .. root) }
end

Classes.CHAIN_MAX = 40 -- quests at most in a chain found from one quest (Classes.ChainOf)

--- The chain a quest belongs to, for this character: the quests linked to it (prerequisites,
--- follow-ups, next in chain, breadcrumbs, either-or siblings), followed out from it up to
--- CHAIN_MAX quests, through quests this character can take or has done. In the shape of
--- Classes.Chains' chains, under `anchor` as its id. nil when nothing of it is left to do.
function Classes.ChainOf(anchor, ctx)
    local Data = ns.Data
    local avail = ctx.avail
    local quests, members, queue, seen, head = {}, {}, { anchor }, { [anchor] = true }, 1
    while queue[head] and #members < Classes.CHAIN_MAX do
        local id = queue[head]
        head = head + 1
        local q = Data.GetQuest(id)
        local takes = q and not repeats(q)
        if takes and id ~= anchor and not (avail.completed or {})[id] and not ctx.log[id] then
            local _, why = Data.IsAvailable(id, avail)
            if never(why) then takes = false end -- another race's or class's: not followed further
        end
        if takes then
            quests[id], members[#members + 1] = q, id
            local links = Data.GetFollowUps(id)
            for _, list in ipairs({ q.preAll, q.preAny, q.exclusive }) do
                for _, l in ipairs(list) do links[#links + 1] = l end
            end
            links[#links + 1] = q.nextInChain
            links[#links + 1] = q.breadcrumbFor
            for _, l in ipairs(links) do
                if l and l > 0 and not seen[l] then seen[l] = true; queue[#queue + 1] = l end
            end
        end
        if ctx.checkpoint then ctx.checkpoint() end
    end
    table.sort(members)
    return analyse(anchor, members, quests, ctx) or nil
end

--- The class quest chains this character has not finished: quests only some classes can take
--- (this one among them), grouped by what leads to what (prerequisites, next in chain,
--- breadcrumbs, either-or siblings). ctx from ns.Zones.Context.
--- Returns { chain, ... }, lowest level first, each
---   { id = its lowest quest id (stable while the chain lasts), name,
---     quests = { ids still to do, ascending }, set = { [id] = true } of those,
---     open = { ids that can be taken now, or are in the log }, sig = `open` as one string (it
---     changes when the chain moves on), level = the lowest level of `open`,
---     nextLevel = the lowest level a quest still to do waits for, above the character's (nil:
---     none), inLog = one of them is in the quest log }
--- Quests seen by no Forever player are never open unless they are in the log.
function Classes.Chains(ctx)
    local Data, Model = ns.Data, ns.Model
    local avail = ctx.avail
    local completed = avail.completed or {}
    local quests = {}
    for i, id in ipairs(Data.ClassQuests(avail.class)) do
        local q = Data.GetQuest(id)
        if q and not repeats(q) then quests[id] = q end
        if ctx.checkpoint and i % 8 == 0 then ctx.checkpoint() end
    end
    -- groups: the lowest id of a group is its root
    local parent = {}
    for id in pairs(quests) do parent[id] = id end
    local function find(x)
        while parent[x] ~= x do
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end
    local function join(a, b)
        if not (a and b and quests[a] and quests[b]) then return end
        local ra, rb = find(a), find(b)
        if ra < rb then parent[rb] = ra elseif rb < ra then parent[ra] = rb end
    end
    for id, q in pairs(quests) do
        for _, pre in ipairs(q.preAll) do join(id, pre) end
        for _, pre in ipairs(q.preAny) do join(id, pre) end
        for _, ex in ipairs(q.exclusive) do join(id, ex) end
        join(id, q.nextInChain)
        join(id, q.breadcrumbFor)
    end
    local groups = {}
    for id in pairs(quests) do
        local root = find(id)
        groups[root] = groups[root] or {}
        groups[root][#groups[root] + 1] = id
    end
    local out = {}
    for root, members in pairs(groups) do
        table.sort(members)
        out[#out + 1] = analyse(root, members, quests, ctx)
        if ctx.checkpoint then ctx.checkpoint() end
    end
    local kept = {}
    for _, c in ipairs(out) do if c then kept[#kept + 1] = c end end
    table.sort(kept, function(a, b)
        local la, lb = a.level or math.huge, b.level or math.huge
        if la ~= lb then return la < lb end
        return a.id < b.id
    end)
    return kept
end

--- Plan one chain from where the character stands (ctx.start, ctx.startMap). `seed` and
--- `front` as for Planner.Plan (keep a previous order; bring stops we stand at forward).
--- The plan is a Planner plan with chain = the chain's id, chainQuests = how many of the
--- chain's quests it turns in, and chainName = the last of them (a chain with a variant per
--- race is named after the variant planned), else the chain's own name; chainLevel = that
--- quest's level (nil when unknown). nil without a position.
function Classes.Plan(chain, ctx, seed, front)
    if not ctx.start then return nil end
    local near = ctx.near
    ctx.chain, ctx.near = chain, ctx.start
    local plan = ns.Planner.Plan(ctx.startMap, ctx, { overhead = 0, seed = seed, front = front })
    ctx.chain, ctx.near = nil, near
    local n, last = 0, nil
    for _, step in ipairs(plan.steps) do
        if step.kind == "turnin" and chain.set[step.quests[1].id] then n, last = n + 1, step.quests[1] end
    end
    plan.chain, plan.chainQuests = chain.id, n
    plan.chainName = last and last.name or chain.name
    plan.chainLevel = last and last.level and last.level > 0 and last.level or nil
    return plan
end

--- What to warn about before a chain is picked, from its plan:
--- { eliteStep = the first step that is a group quest (routed), eliteName,
---   groupName = a quest of the chain left out because group quests are not routed,
---   laterLevel = the level the rest of the chain waits for (nil: nothing waits) }
function Classes.Facts(chain, plan)
    local f = {}
    for i, step in ipairs(plan and plan.steps or {}) do
        if step.group and not f.eliteStep then f.eliteStep, f.eliteName = i, step.quests[1] and step.quests[1].name end
    end
    local lists = plan and plan.lists or {}
    for _, e in ipairs(lists.group or {}) do
        if chain.set[e.id] and not f.groupName then f.groupName = e.name end
    end
    local later = chain.nextLevel
    for _, e in ipairs(lists.later or {}) do
        local lv = e.needLevel or e.minLevel
        if chain.set[e.id] and lv and lv > 0 and (not later or lv < later) then later = lv end
    end
    f.laterLevel = later
    return f
end

--- Does this plan (a zone's route) already do one of the chain's quests?
function Classes.InPlan(chain, plan)
    for _, step in ipairs(plan and plan.steps or {}) do
        for _, q in ipairs(step.quests or {}) do
            if chain.set[q.id] then return true end
        end
    end
    return false
end
