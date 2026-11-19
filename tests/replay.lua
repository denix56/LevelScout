-- tests/replay.lua: plan a snapshot from the game again, outside the game, and list what differs
-- from what the game showed. A snapshot is what `/ls snapshot [note]` saves with the character
-- (core/Snapshot.lua). Usage (from the repo root):
--   .tools/bin/lua5.1 tests/replay.lua <WTF/Account/<ACC>/<Realm>/<Char>/SavedVariables/LevelScout.lua> [id]
--       [--list] [--settings=code] [--zone=MAP] [--cold] [--account=PATH] [--drops=account]
--   id          the number chat printed (default: the newest)
--   --list      list the saved snapshots and stop
--   --settings=code   plan with this code's constants, not the ones saved in the snapshot
--   --zone=MAP  print the replayed route of that ranked zone, step by step
--   --cold      plan without the warm starts the game's ranking had (to see whether one made a difference)
--   --account=PATH    the account's LevelScout.lua (default: found three folders up); its drop counts
--                     are told about, and used instead of the snapshot's with --drops=account
-- QUESTIEDB=<QuestieDB addon folder> says where QuestieDB is read from, as for the tests.
-- Exit code: 0 nothing differs, 1 something does, 2 it could not run.
-- Also a module (the snapshot test requires it): `return R`, and main runs only as a script.

local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."
package.path = root .. "/tests/?.lua;" .. package.path
local H = require("harness")
local M = require("mocks")

local R = {}

local floor, abs, max, min, huge = math.floor, math.abs, math.max, math.min, math.huge

---------------------------------------------------------------------------------------------
-- Reading and writing saved variables
---------------------------------------------------------------------------------------------

--- The value `name` that a saved-variables text assigns. The text is run in an empty
--- environment: it can assign and build tables, nothing else. nil and the error when it cannot.
function R.LoadText(text, name, chunkname)
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end -- a UTF-8 byte order mark
    local chunk, err = loadstring(text, chunkname or ("=" .. name))
    if not chunk then return nil, err end
    local env = {}
    setfenv(chunk, env)
    local ok, ran = pcall(chunk)
    if not ok then return nil, ran end
    return env[name]
end

--- The value `name` of the saved-variables file at `path`; nil and the reason when it cannot be read.
function R.ReadSaved(path, name)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local text = f:read("*a")
    f:close()
    return R.LoadText(text, name, "@" .. path)
end

local function keyOrder(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta == "number" end
    return a < b
end

local function number(v)
    if v == floor(v) and abs(v) < 2 ^ 53 then return string.format("%d", v) end
    return string.format("%.17g", v)
end

--- The text a saved-variables file would hold for `name = value`, as the game writes it (an
--- imitation: keys sorted, numbers before strings). Errors, naming the path, where the game
--- could not save the value: a function, userdata or thread, a number that is not finite, a key
--- that is not a string or a number, a table that contains itself.
function R.Write(name, value)
    local buf, open = {}, {}
    local function put(v, path, indent)
        local t = type(v)
        if t == "number" then
            if v ~= v or v == huge or v == -huge then error(path .. ": a number that is not finite", 0) end
            buf[#buf + 1] = number(v)
        elseif t == "string" then
            buf[#buf + 1] = string.format("%q", v)
        elseif t == "boolean" then
            buf[#buf + 1] = tostring(v)
        elseif t == "table" then
            if open[v] then error(path .. ": a table that contains itself", 0) end
            open[v] = true
            local keys = {}
            for k in pairs(v) do
                local tk = type(k)
                if tk ~= "string" and tk ~= "number" then error(path .. ": a key that is a " .. tk, 0) end
                if tk == "number" and (k ~= k or k == huge or k == -huge) then error(path .. ": a key that is not finite", 0) end
                keys[#keys + 1] = k
            end
            table.sort(keys, keyOrder)
            buf[#buf + 1] = "{\n"
            for _, k in ipairs(keys) do
                local label = type(k) == "number" and ("[" .. number(k) .. "]") or ("[" .. string.format("%q", k) .. "]")
                buf[#buf + 1] = indent .. "\t" .. label .. " = "
                put(v[k], path .. (type(k) == "number" and ("[" .. number(k) .. "]") or ("." .. k)), indent .. "\t")
                buf[#buf + 1] = ",\n"
            end
            buf[#buf + 1] = indent .. "}"
            open[v] = nil
        else
            error(path .. ": a " .. t, 0)
        end
    end
    buf[1] = name .. " = "
    put(value, name, "")
    buf[#buf + 1] = "\n"
    return table.concat(buf)
end

---------------------------------------------------------------------------------------------
-- Loading the planner and planning the snapshot again
---------------------------------------------------------------------------------------------

--- The addon files the planner needs, in TOC order: no game adapter, no UI, no Engine.
--- (Core modules take each other at load time only; so nothing here makes frames or touches
--- SlashCmdList.)
function R.PlannerFiles()
    local out = {}
    for _, f in ipairs(H.tocFiles()) do
        if f == "Init.lua" or f:match("^data/") or f == "adapters/Merge.lua" or f == "adapters/Data.lua" or f:match("^core/") then
            out[#out + 1] = f
        end
    end
    return out
end

--- A namespace with the planner and the data of the snapshot's character loaded.
--- opts = { questiedb = a LibQuestieDB (default: the real QuestieDB for the snapshot's faction
---          and class, see mocks.lua), keepMocks = do not install the mocks: a test has them }.
function R.Setup(snap, opts)
    opts = opts or {}
    local input = snap.input
    local lib = opts.questiedb or M.questieDB(input.faction, input.class)
    if not opts.keepMocks then M.install({ questiedb = lib }) end
    local global = rawget(_G, "LevelScout") -- (Init.lua sets it: the namespace of a game running here keeps it)
    local ns = H.loadAddon(R.PlannerFiles())
    _G.LevelScout = global
    ns.Data.Init({ faction = input.faction, class = input.class, clientBuild = snap.version and snap.version.client }, lib)
    if not ns.Data.usable then error("the data is not usable here: " .. tostring(ns.Data.status.message), 0) end
    ns.Data.BuildIndex()
    return ns
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys, keyOrder)
    return keys
end

local function plain(v) local t = type(v) return t == "number" or t == "string" or t == "boolean" end

--- Put the game's constants into the loaded modules. Engine's are not applied (Engine is not
--- loaded and not replayed: which route is shown is taken from the snapshot) and neither are
--- tables; a key the snapshot lacks stays as the code has it. Returns the list of the values
--- that were set (those that differed): { { key, game, here } }, and of the ones that were not,
--- with the reason: { { key, why } }.
function R.ApplySettings(ns, settings)
    local applied, skipped = {}, {}
    for _, mod in ipairs(sortedKeys(settings)) do
        for _, k in ipairs(sortedKeys(settings[mod])) do
            local v, key = settings[mod][k], mod .. "." .. k
            local target = ns[mod]
            if mod == "Engine" then
                -- recorded only
            elseif type(target) ~= "table" then
                skipped[#skipped + 1] = { key = key, why = "no such module here" }
            elseif not plain(v) then
                if not H.deepEq(v, target[k]) then skipped[#skipped + 1] = { key = key, why = "a table" } end
            elseif target[k] ~= v then
                applied[#applied + 1] = { key = key, game = v, here = target[k] }
                target[k] = v
            end
        end
    end
    return applied, skipped
end

--- Where this code's constants differ from the snapshot's: { { key, game, here } } (a constant
--- the code has and the snapshot lacks has game = nil). Engine's are left out: Engine is not loaded.
function R.SettingsDiff(ns, settings)
    local diffs = {}
    local here = ns.Snapshot.Settings()
    for _, mod in ipairs(sortedKeys(settings)) do
        if mod ~= "Engine" and type(ns[mod]) == "table" then
            local mine = here[mod] or {}
            local keys = {}
            for k in pairs(settings[mod]) do keys[k] = true end
            for k in pairs(mine) do keys[k] = true end
            for _, k in ipairs(sortedKeys(keys)) do
                if not H.deepEq(settings[mod][k], mine[k]) then
                    diffs[#diffs + 1] = { key = mod .. "." .. k, game = settings[mod][k], here = mine[k] }
                end
            end
        end
    end
    return diffs
end

--- The plan the game showed, made again from its recipe (core/Snapshot.lua, Snapshot.Made):
--- the ranked zone's own plan, the order shown before kept (with the stops at hand brought
--- forward or the step in hand pinned), or the zone planned for itself with the warm start it
--- had. The warm start is given outright, never through the memory: the memory's count after the
--- replayed ranking can differ from the game's. nil and why when it cannot be made.
function R.Remake(ns, ctx, ranked, made, zone)
    local Z, S = ns.Zones, ns.Snapshot
    if not zone then return nil, "no zone was shown" end
    if not made or made.kind == "chain" then return nil, "a class quest chain was shown" end
    -- the route without the way across planned together and the quests taken along to the next zone
    -- (made.seam and made.border: laid over it below)
    local base
    if made.kind == "ranked" then
        for _, z in ipairs(ranked) do
            if z.map == zone and not base then base = z.plan end
        end
        if not base then return nil, "the shown zone is not ranked in the replay" end
    elseif made.kind == "seeded" then
        base = Z.PlanZone(zone, ctx, S.SplitList(made.seed), nil,
            { front = made.front and S.SplitList(made.front) or nil, first = made.first })
    elseif made.kind == "fresh" then
        base = Z.PlanZone(zone, ctx, nil, nil, { warm = made.warm and S.SplitList(made.warm) or false, weights = made.weights })
    else
        return nil, "unknown way of making the route: " .. tostring(made.kind)
    end
    local plain = base
    if made.seam then
        base = Z.WithSeam(zone, ctx, base, made.seam, made.seamFront and S.SplitList(made.seamFront) or nil)
    end
    if made.border then
        return Z.WithBorder(zone, ctx, base, made.border, made.borderFront and S.SplitList(made.borderFront) or nil), nil, plain
    end
    return base, nil, plain
end

--- Plan the snapshot again as the Engine's full run does (see Engine.lua, run and
--- startItinerary): rank the zones, make the shown route, work out the next hours and the banner.
--- opts = { cold = no warm starts, drops = the drop counts to plan with (default: the snapshot's) }.
--- Returns { view (as Snapshot.View makes it), ranked, plan, itinerary, moveOn, why (the route could
--- not be made), time = { rank, route, itinerary, total } } in seconds.
function R.Replay(ns, snap, opts)
    opts = opts or {}
    local Z, S = ns.Zones, ns.Snapshot
    local t0 = os.clock()
    local state = S.State(snap.input)
    if opts.drops then state.drops = opts.drops end
    state.memory = (not opts.cold) and S.Memory(snap) or nil
    local ctx = Z.Context(state)
    local ranked = Z.Rank(ctx, snap.zone)
    state.altRate = ctx.altRate -- as the Engine's rank() does, for the itinerary
    local t1 = os.clock()
    local shown = snap.shown or {}
    local zone, made = shown.zone, shown.made
    local plan, why, base = R.Remake(ns, ctx, ranked, made, zone)
    local t2 = os.clock()
    local itinerary
    if plan and not shown.chain then
        local ictx = Z.Context(state) -- a new context, as the itinerary's job makes
        local was
        if snap.itineraryWas then
            was = { segments = {} }
            for i, map in ipairs(snap.itineraryWas) do
                was.segments[i] = { map = map, leaveKey = snap.itineraryWasKeys and snap.itineraryWasKeys[i] or nil }
            end
        end
        itinerary = Z.Itinerary(state, ictx, ranked, { shown = zone, plan = base or plan, was = was,
            border = snap.borderWas, borderPlan = (base and plan ~= base and plan.base) and plan or nil,
            seam = snap.seamWas, seamPlan = Z.SeamLayer(plan) })
    end
    local t3 = os.clock()
    -- the commitment to the zone as the game had it before this run's itinerary, then as that updated it
    local commit = zone and Z.Commit(S.Copy(snap.commitWas), itinerary, zone) or nil
    local moveOn = Z.MoveOn(plan, ranked, snap.moveOnWas, itinerary, commit)
    local result = { ranked = ranked, plan = plan, itinerary = itinerary, moveOn = moveOn, commit = commit, why = why,
        time = { rank = t1 - t0, route = t2 - t1, itinerary = t3 - t2, total = t3 - t0 } }
    result.view = S.View({ ranked = ranked, plan = plan, zone = zone, itinerary = itinerary, moveOn = moveOn, status = "ready" })
    return result
end

---------------------------------------------------------------------------------------------
-- Comparing
---------------------------------------------------------------------------------------------

-- Two numbers are the same when they are within abs + rel * the larger of them. The search is
-- seeded from its input, so with the same code, data and settings the figures agree to the
-- last bit: this only allows for how the numbers were saved and the C library's rounding.
R.TOL = {
    score = { 0.01, 1e-6 }, rate = { 0.01, 1e-6 }, value = { 0.01, 1e-6 },
    xp = { 1, 0 }, seconds = { 1, 0 }, t = { 1, 0 }, travel = { 1, 0 }, gain = { 1e-4, 0 },
}

local function close(a, b, tol)
    if type(a) ~= "number" or type(b) ~= "number" then return a == b end
    return abs(a - b) <= tol[1] + tol[2] * max(abs(a), abs(b))
end

local function show(v)
    if type(v) == "number" then
        if v == floor(v) then return string.format("%d", v) end
        return string.format("%.6g", v)
    end
    return tostring(v)
end

local function stepText(s)
    return string.format("%s %s +%s xp at %s s (walk %s, do %s)", tostring(s.key), tostring(s.kind), show(s.xp), show(s.t),
        show(s.travel), show(s.seconds))
end

--- What differs between two views (Snapshot.View's tables: `want` the game's, `got` the
--- replay's): a list of { section, what, game, replay }, the number of values compared, and
--- notes { reused = zones the game handed out again from an earlier ranking (not compared),
--- chain = a class quest chain was shown (route, itinerary and banner not compared) }.
--- opts = { light = only what a light view holds (for the view before a snapshot), names = { [map] = name } }.
function R.Compare(want, got, opts)
    opts = opts or {}
    local light, names = opts.light, opts.names or {}
    local diffs, count, notes = {}, 0, {}
    local function add(section, what, a, b) diffs[#diffs + 1] = { section = section, what = what, game = a, replay = b } end
    local function eq(section, what, a, b, tolName)
        count = count + 1
        if tolName then
            if close(a, b, R.TOL[tolName]) then return true end
        elseif a == b then
            return true
        end
        add(section, what, a, b)
        return false
    end
    local function nameOf(map) return names[map] or ("map " .. tostring(map)) end

    -- zones
    local wr, gr = want.ranked or {}, got.ranked or {}
    local wm, gm, byMap, inWant = {}, {}, {}, {}
    for i, z in ipairs(wr) do wm[i], inWant[z.map] = z.map, true end
    for i, z in ipairs(gr) do gm[i], byMap[z.map] = z.map, z end
    count = count + 1
    if table.concat(wm, ",") ~= table.concat(gm, ",") then
        add("zones", "order of zones", table.concat(wm, ","), table.concat(gm, ","))
    end
    for _, z in ipairs(gr) do
        if not inWant[z.map] then add("zones", nameOf(z.map) .. " is ranked in the replay only", "absent", "present") end
    end
    for _, z in ipairs(wr) do
        local g = byMap[z.map]
        local who = nameOf(z.map)
        if not g then
            add("zones", who .. " is ranked in the game only", "present", "absent")
        elseif z.reused then
            notes.reused = true
        else
            eq("zones", who .. " score", z.score, g.score, "score")
            eq("zones", who .. " rate", z.rate, g.rate, "rate")
            eq("zones", who .. " value", z.value, g.value, "value")
            eq("zones", who .. " xp", z.xp, g.xp, "xp")
            eq("zones", who .. " seconds", z.seconds, g.seconds, "seconds")
            eq("zones", who .. " quests", z.quests, g.quests)
            eq("zones", who .. " steps", z.steps, g.steps)
            if not light then
                local a, b = z.order or "", g.order or ""
                count = count + 1
                if a ~= b then
                    local i = 1
                    local la, lb = a:gmatch("[^,]+"), b:gmatch("[^,]+")
                    while true do
                        local x, y = la(), lb()
                        if x ~= y then
                            add("zones", who .. " route, first stop that differs (" .. i .. ")", x, y)
                            break
                        end
                        if not x then break end
                        i = i + 1
                    end
                end
            end
        end
    end

    -- the route shown
    if want.chain or got.chain then
        notes.chain = true
    else
        local wp, gp = want.plan, got.plan
        count = count + 1
        if (wp ~= nil) ~= (gp ~= nil) then
            add("route", "a route is shown", wp ~= nil and "yes" or "no", gp ~= nil and "yes" or "no")
        elseif wp then
            eq("route", "zone", want.zone, got.zone)
            if not light then eq("route", "how it was made", want.made and want.made.kind, got.made and got.made.kind) end
            eq("route", "score", wp.score, gp.score, "score")
            eq("route", "rate", wp.rate, gp.rate, "rate")
            eq("route", "xp", wp.xp, gp.xp, "xp")
            eq("route", "seconds", wp.seconds, gp.seconds, "seconds")
            eq("route", "steps", wp.count, gp.count)
            for i = 1, min(#wp.steps, #gp.steps) do
                local s, g = wp.steps[i], gp.steps[i]
                local same = true
                for _, f in ipairs({ "key", "kind", "map" }) do
                    count = count + 1
                    if s[f] ~= g[f] then same = false end
                end
                for _, f in ipairs({ "xp", "t", "travel", "seconds" }) do
                    count = count + 1
                    if not close(s[f], g[f], R.TOL[f]) then same = false end
                end
                if not same then
                    add("route", "step " .. i, stepText(s), stepText(g))
                    break -- (the steps after it follow from it)
                end
            end
        end
    end

    -- the next hours
    if not notes.chain then
        local wi, gi = want.itinerary, got.itinerary
        count = count + 1
        if (wi ~= nil) ~= (gi ~= nil) then
            add("itinerary", "an itinerary is made", wi ~= nil and "yes" or "no", gi ~= nil and "yes" or "no")
        elseif wi then
            eq("itinerary", "xp", wi.xp, gi.xp, "xp")
            eq("itinerary", "rate", wi.rate, gi.rate, "rate")
            eq("itinerary", "stay", wi.stay, gi.stay, "xp")
            eq("itinerary", "here", wi.here, gi.here, "xp")
            eq("itinerary", "shown", wi.shown, gi.shown)
            eq("itinerary", "better start (alt)", wi.alt and wi.alt.map, gi.alt and gi.alt.map)
            eq("itinerary", "zones", #wi.segments, #gi.segments)
            for i = 1, min(#wi.segments, #gi.segments) do
                local s, g = wi.segments[i], gi.segments[i]
                local who = "zone " .. i .. " (" .. nameOf(s.map) .. ")"
                eq("itinerary", who .. " map", s.map, g.map)
                eq("itinerary", who .. " leave after", s.leaveKey, g.leaveKey)
                eq("itinerary", who .. " xp", s.xp, g.xp, "xp")
                eq("itinerary", who .. " trip", s.travel, g.travel, "travel")
                eq("itinerary", who .. " time there", s.seconds, g.seconds, "seconds")
                eq("itinerary", who .. " carried quests", s.carried, g.carried)
            end
            if not light and (wi.starts ~= nil) ~= (gi.starts ~= nil) then
                add("itinerary", "starts are listed", wi.starts ~= nil and "yes" or "no", gi.starts ~= nil and "yes" or "no")
            elseif not light and wi.starts then
                for _, map in ipairs(sortedKeys(wi.starts)) do
                    local s, g = wi.starts[map], gi.starts[map] or {}
                    local who = "start in " .. nameOf(map)
                    eq("itinerary", who .. " xp", s.xp, g.xp, "xp")
                    eq("itinerary", who .. " rate", s.rate, g.rate, "rate")
                    eq("itinerary", who .. " next", s.next, g.next)
                    eq("itinerary", who .. " path", s.path or false, g.path or false)
                    eq("itinerary", who .. " rough", s.rough or false, g.rough or false)
                end
            end
        end

        -- the banner
        local wb, gb = want.moveOn or {}, got.moveOn or {}
        eq("banner", "suggested", wb.suggest or false, gb.suggest or false)
        eq("banner", "zone", wb.map, gb.map)
        eq("banner", "gain", wb.gain, gb.gain, "gain")
        eq("banner", "rate", wb.rate or false, gb.rate or false)
        eq("banner", "reached", wb.reached or false, gb.reached or false)
        eq("banner", "horizon", wb.horizon, gb.horizon)
    end
    return diffs, count, notes
end

---------------------------------------------------------------------------------------------
-- Reporting
---------------------------------------------------------------------------------------------

local function hm(s) -- minutes:seconds
    if type(s) ~= "number" then return "-" end
    return string.format("%d:%02d", floor(s / 60), floor(s % 60))
end

local function hours(s) -- hours:minutes
    if type(s) ~= "number" then return "-" end
    return string.format("%d:%02d", floor(s / 3600), floor(s % 3600 / 60))
end

local function xph(v) return type(v) == "number" and string.format("%.0f", v) or "-" end

local function mapName(snap, map)
    if map == nil then return "-" end
    return (snap.names and snap.names[map]) or ("map " .. tostring(map))
end

local function countKeys(set)
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end

local function versionLine(v)
    local sources = {}
    for _, k in ipairs(sortedKeys(v.sources)) do
        local text = tostring(v.sources[k])
        sources[#sources + 1] = text:sub(1, #k) == k and text or (k .. " " .. text) -- (QuestieDB's says its own name)
    end
    return string.format("LevelScout %s, client %s, data %s (%s)%s", tostring(v.addon), tostring(v.client), tostring(v.data),
        tostring(v.generated), #sources > 0 and (", " .. table.concat(sources, ", ")) or "")
end

local function dataKey(v)
    local sources = {}
    for _, k in ipairs(sortedKeys(v.sources)) do sources[#sources + 1] = k .. "=" .. tostring(v.sources[k]) end
    return tostring(v.data) .. "|" .. tostring(v.generated) .. "|" .. table.concat(sources, ";")
end

local function listing(items, fmt, limit)
    local parts = {}
    for i, item in ipairs(items) do
        if i > limit then parts[#parts + 1] = string.format("... %d more", #items - limit) break end
        parts[#parts + 1] = fmt(item)
    end
    return table.concat(parts, ", ")
end

local function itineraryText(snap, it)
    if not it then return "none" end
    local parts = {}
    for _, seg in ipairs(it.segments) do parts[#parts + 1] = string.format("%s %s", mapName(snap, seg.map), hm(seg.seconds)) end
    return string.format("%s, %s XP (%s XP/h)", table.concat(parts, " -> "), show(it.xp), xph(it.rate))
end

local function bannerText(snap, m)
    if not (m and m.suggest) then return "none" end
    return string.format("%s%s%s", mapName(snap, m.map), m.gain and string.format(" (%+.1f%%)", m.gain * 100) or "",
        m.reached and " (done here as planned)" or "")
end

local function madeText(made)
    if not made then return "unknown" end
    if made.kind == "ranked" then return "the ranked route" end
    if made.kind == "seeded" then
        return "kept order (rebuilt from the order shown before"
            .. (made.front and ", stops at hand brought forward" or "") .. (made.first and ", the step in hand first" or "") .. ")"
    end
    if made.kind == "fresh" then return "planned for itself" .. (made.warm and " from a warm start" or "") end
    return made.kind
end

--- The printout, as a list of lines.
--- info = { applied, skipped (R.ApplySettings), settingsDiff (R.SettingsDiff), settingsFrom = "game" | "code",
---          diffs, count, notes (R.Compare of the shown view), before (R.Compare of the view before and the
---          shown one), cold, account = { path, records, kills, snapshotKills, used }, version = this code's }
function R.Report(ns, snap, result, info)
    local lines = {}
    local function say(fmt, ...) lines[#lines + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt end
    local input, shown = snap.input, snap.shown or {}
    local Z = ns.Zones
    say("LevelScout replay of snapshot %s (%s)%s", tostring(snap.id), tostring(snap.date or "no date"),
        snap.note and (": \"" .. snap.note .. "\"") or "")

    -- the character
    local completed = ns.Snapshot.DecodeIds(input.completed)
    local nodes = ns.Snapshot.DecodeIds(input.knownNodes)
    local ignored = ns.Snapshot.DecodeIds(input.ignored)
    local pace = {}
    for _, k in ipairs(sortedKeys(input.pace)) do
        local rec = input.pace[k]
        if type(rec) == "table" and rec.n then pace[#pace + 1] = k .. show(rec.n) end
    end
    say("Character  level %s (%s/%s XP, rested %s, +%s%% XP), %s %s race %s", tostring(input.level), show(input.xp or 0),
        show(input.xpMax or 0), show(input.restedPool or 0), show((input.xpBonus or 0) * 100), tostring(input.faction),
        tostring(input.class), tostring(input.raceId))
    say("           at %s (%s) %.1f, %.1f; %d/%s quests in the log, %d done, %d flight points,",
        mapName(snap, input.map), tostring(input.map), (input.x or 0) * 100, (input.y or 0) * 100, #input.log,
        tostring(input.capacity), countKeys(completed), countKeys(nodes))
    say("           %d skipped, %s, elite %s, escort %s, tram %s; pace %s samples, step model %s, drops %d",
        countKeys(ignored), (input.groupSize or 1) > 1 and ("group of " .. input.groupSize) or "solo",
        input.routeElite == false and "listed only" or "routed",
        input.routeEscort and "routed" or "listed only", tostring(input.tram or "auto"), #pace > 0 and table.concat(pace, " ") or "none",
        show(input.stepModel and input.stepModel.n or 0), countKeys(ns.Snapshot.DecodeDrops(input.drops)))

    -- versions
    local mine = info.version
    local sameData = dataKey(snap.version or { sources = {} }) == dataKey(mine)
    say("Versions   game: %s", versionLine(snap.version or { sources = {} }))
    say("           here: %s   -> %s", versionLine(mine), sameData and "same data" or "DIFFERENT data")

    -- settings
    if info.settingsFrom == "code" then
        say("Settings   this code's values used; %d differ from the game's%s", #info.settingsDiff,
            #info.settingsDiff > 0 and (": " .. listing(info.settingsDiff, function(d)
                return string.format("%s %s (game %s)", d.key, show(d.here), show(d.game))
            end, 6)) or "")
    else
        say("Settings   game's values used; %d differ from this code%s", #info.settingsDiff,
            #info.settingsDiff > 0 and (": " .. listing(info.settingsDiff, function(d)
                return string.format("%s %s (code %s)", d.key, show(d.game), show(d.here))
            end, 6)) or "")
    end
    say("           Engine settings recorded only (which route is shown is taken from the snapshot)")
    if #(info.skipped or {}) > 0 then
        say("           not applied: %s", listing(info.skipped, function(s) return s.key .. " (" .. s.why .. ")" end, 6))
    end

    -- memory
    local warmZones = countKeys(snap.warm or {})
    say("Memory     %d of %d zones started warm in game; %s", warmZones, #(shown.ranked or {}),
        info.cold and "planned cold (--cold)" or "replayed with the same starts")
    if info.account then
        local a = info.account
        say("Drops      %s", a.used and string.format("the account's now (%s): %d records", a.path, a.records)
            or string.format("the snapshot's; account drops now: %d records, %d kills more than in the snapshot", a.records, a.kills - a.snapshotKills))
    end

    -- zones
    local got = {}
    for _, z in ipairs(result.view.ranked) do got[z.map] = z end
    local shownStarts = shown.itinerary and shown.itinerary.starts or {}
    local replayStarts = result.view.itinerary and result.view.itinerary.starts or {}
    say("Zones (ranking order)            game XP/h  replay XP/h  route           start XP/h game/replay")
    local firstWrong
    for _, d in ipairs(info.diffs) do if d.section == "zones" then firstWrong = firstWrong or d end end
    for i, z in ipairs(shown.ranked or {}) do
        local g = got[z.map]
        local route = "not ranked"
        if g then
            if z.reused then
                route = "reused"
            elseif z.order == g.order then
                route = "same"
            else
                local a, b = ns.Snapshot.SplitList(z.order), ns.Snapshot.SplitList(g.order)
                local at = 1
                while a[at] == b[at] and a[at] do at = at + 1 end
                route = "from stop " .. at
            end
        end
        local s, rs = shownStarts[z.map], replayStarts[z.map]
        say("%3d. %-28s %9s  %11s  %-14s  %s / %s", i, string.format("%s (%s)", mapName(snap, z.map), z.map), xph(z.score),
            g and xph(g.score) or "-", route, s and xph(s.rate) or "-", rs and xph(rs.rate) or "-")
    end
    local same = true
    for _, d in ipairs(info.diffs) do if d.what == "order of zones" then same = false end end
    say("  zone order: %s", same and "same" or "DIFFERENT")

    -- the shown route
    if shown.chain then
        say("Shown route  a class quest chain (%s): its route, the itinerary and the banner are not replayed", tostring(shown.chain.name))
    elseif not shown.plan then
        say("Shown route  none")
    else
        local p, rp = shown.plan, result.view.plan
        say("Shown route  %s, %s; game %s XP/h, replay %s XP/h", mapName(snap, shown.zone), madeText(shown.made), xph(p.score),
            rp and xph(rp.score) or ("- (" .. tostring(result.why) .. ")"))
        local wrong
        for i, s in ipairs(p.steps) do
            local r = rp and rp.steps[i]
            local verdict = "same"
            if not r then
                verdict = "REPLAY HAS NO SUCH STEP"
            elseif s.key ~= r.key or not close(s.xp, r.xp, R.TOL.xp) or not close(s.t, r.t, R.TOL.t) then
                verdict = "DIFFERENT: " .. stepText(r)
                wrong = wrong or i
            end
            say("  %2d  %-9s %-8s %-30s %+6s  %5s   %s", i, tostring(s.key), tostring(s.kind), tostring(s.target or ""):sub(1, 30),
                show(s.xp or 0), hm(s.t), verdict)
        end
        say("  first %d steps: %s", #p.steps, wrong and ("differ from step " .. wrong) or "same")
        if shown.made and shown.made.kind == "seeded" and rp then
            local ranked
            for _, z in ipairs(result.ranked) do if z.map == shown.zone then ranked = z.plan end end
            local kept = result.plan
            if ranked and kept and ranked ~= kept then
                say("  (the ranked route for this zone: %s XP/h; %s)", xph(ranked.score),
                    Z.PreferFresh(kept, ranked) and "clearly better, so the shown order would change"
                    or string.format("not %d%% better: the shown order stays", floor((Z.KEEP_ORDER - 1) * 100 + 0.5)))
            end
        end
    end

    -- the next hours and the banner
    if not shown.chain then
        local wi, gi = shown.itinerary, result.view.itinerary
        local horizon = wi and wi.horizon or (gi and gi.horizon)
        local sameIt = true
        for _, d in ipairs(info.diffs) do if d.section == "itinerary" then sameIt = false end end
        say("Itinerary%s  game: %s; replay: %s", horizon and (" (" .. hours(horizon) .. ")") or "", itineraryText(snap, wi),
            sameIt and "same" or itineraryText(snap, gi))
        local sameBanner = true
        for _, d in ipairs(info.diffs) do if d.section == "banner" then sameBanner = false end end
        say("Banner      game: %s; replay: %s", bannerText(snap, shown.moveOn), sameBanner and bannerText(snap, shown.moveOn) or bannerText(snap, result.view.moveOn))
        local c = result.commit
        if c then
            say("Commitment  %s%s, played %d s%s%s", mapName(snap, c.zone), c.hand and " picked by hand" or "", floor(c.played or 0),
                c.zones and (", path " .. #c.zones .. " zone" .. (#c.zones == 1 and "" or "s") .. (c.reached and ", leave step done" or "")) or "",
                c.stay and string.format(", asked again after %s", hm(math.min(Z.COMMIT_STAY, c.stay))) or "")
        end
    end

    -- what was on screen when the command was typed
    local b = snap.before
    if b then
        local keys = {}
        for i, s in ipairs(b.plan and b.plan.steps or {}) do if i <= 4 then keys[#keys + 1] = tostring(s.key) end end
        say("When typed (before the re-plan): %s, %s; itinerary %s; banner %s", mapName(snap, b.zone),
            #keys > 0 and table.concat(keys, " ") or "no route", itineraryText(snap, b.itinerary), bannerText(snap, b.moveOn))
        if #info.before == 0 then
            say("  the re-plan for the snapshot changed nothing shown")
        else
            say("  changed by the re-plan: %s", listing(info.before, function(d)
                return string.format("%s: %s (%s -> %s)", d.section, d.what, show(d.game), show(d.replay))
            end, 4))
        end
    end

    -- caveats
    local caveats = {}
    if not sameData then caveats[#caveats + 1] = "the data or QuestieDB differ from the game's: a route can differ for that alone" end
    if snap.version and snap.version.addon ~= mine.addon then
        caveats[#caveats + 1] = string.format("this is LevelScout %s, the game ran %s: check out that tag for an exact replay", tostring(mine.addon), tostring(snap.version.addon))
    end
    if info.settingsFrom == "code" and #info.settingsDiff > 0 then caveats[#caveats + 1] = "settings are this code's, not the game's" end
    if #(info.skipped or {}) > 0 then caveats[#caveats + 1] = "some settings could not be applied" end
    if info.notes.reused then caveats[#caveats + 1] = "zones handed out again from an earlier ranking in the game were not compared" end
    if info.notes.chain then caveats[#caveats + 1] = "a class quest chain was shown: only the zones were compared" end
    if info.cold then caveats[#caveats + 1] = "planned without the warm starts: differences may come from that" end
    if info.account and info.account.used then caveats[#caveats + 1] = "planned with the account's drop counts of now" end
    if #caveats > 0 then say("Caveats    %s", table.concat(caveats, "; ")) end

    local t = result.time
    say("Replayed in %.1f s (ranking %.1f, route %.1f, itinerary %.1f)", t.total, t.rank, t.route, t.itinerary)
    for _, d in ipairs(info.diffs) do
        say("DIFFERENCE %s: %s: game %s, replay %s", d.section, d.what, show(d.game), show(d.replay))
    end
    if #info.diffs == 0 then
        say("RESULT: same (%d values compared)", info.count)
    else
        say("RESULT: %d differences (first: %s, %s)", #info.diffs, info.diffs[1].section, info.diffs[1].what)
    end
    return lines
end

--- The saved snapshots, one line each.
function R.List(list)
    local lines = {}
    for _, s in ipairs(list) do
        local zone = s.shown and s.shown.zone
        lines[#lines + 1] = string.format("%3s  %-19s  level %-3s  %s%s", tostring(s.id), tostring(s.date or "no date"),
            tostring(s.input and s.input.level or "?"),
            zone and string.format("%s (%s)", (s.names and s.names[zone]) or "map", zone) or (s.shown and s.shown.chain and "a class quest chain" or "no zone"),
            s.note and (": " .. s.note) or "")
    end
    return lines
end

--- The route of one ranked zone of the replay, step by step (as tests/sim.lua prints it).
function R.PrintZone(result, map)
    local lines = {}
    for _, z in ipairs(result.ranked) do
        if z.map == map then
            lines[#lines + 1] = string.format("replayed route for map %d (trip to the first step: %s):", z.map,
                hm(z.plan.steps[1] and z.plan.steps[1].travel or 0))
            for i, s in ipairs(z.plan.steps) do
                local names = {}
                for _, q in ipairs(s.quests or {}) do names[#names + 1] = q.name end
                if s.group then names[#names + 1] = "<GROUP>" end
                if s.needLevel then names[#names + 1] = "<needs level " .. s.needLevel .. ">" end
                if s.levelUp then names[#names + 1] = "<LEVEL " .. s.levelUp .. ">" end
                lines[#lines + 1] = string.format("%2d%s %-7s %-34s %5.1f,%5.1f  walk %4s  do %5s  +%-5d  at %s  [%s]", i, s.tail and "~" or " ",
                    tostring(s.action), tostring(s.target):sub(1, 34) .. (s.kills and (" x" .. s.kills) or ""), s.loc.mx or 0, s.loc.my or 0,
                    hm(s.travel), hm(s.seconds), s.xp, hm(s.t), table.concat(names, "; "):sub(1, 60))
            end
            return lines
        end
    end
    lines[1] = "map " .. tostring(map) .. " is not among the replayed zones"
    return lines
end

---------------------------------------------------------------------------------------------
-- The command line
---------------------------------------------------------------------------------------------

local USAGE = [[
usage: .tools/bin/lua5.1 tests/replay.lua <LevelScout.lua of the character> [id] [options]
  <LevelScout.lua of the character>   WTF/Account/<ACCOUNT>/<Realm>/<Character>/SavedVariables/LevelScout.lua
  id                the snapshot's number as chat said it (default: the newest)
  --list            list the saved snapshots and stop
  --settings=code   plan with this code's constants, not the game's
  --zone=MAP        print the replayed route of that ranked zone
  --cold            plan without the game's warm starts
  --account=PATH    the account's LevelScout.lua (default: found three folders up)
  --drops=account   plan with the account's drop counts of now, not the snapshot's
QUESTIEDB=<folder> says where the QuestieDB addon is. Exit code 0: nothing differs, 1: something does, 2: it could not run.
take a snapshot in game with /ls snapshot [note], then /reload so the game writes it to disk.]]

local function write(lines) for _, l in ipairs(lines) do io.write(l, "\n") end end
local function fail(msg) io.stderr:write("replay: ", msg, "\n") return 2 end

-- The account's saved variables: given, or three folders up from the character's file
-- (.../Account/<ACC>/<Realm>/<Char>/SavedVariables/x.lua -> .../Account/<ACC>/SavedVariables/LevelScout.lua).
local function accountOf(path, given)
    if not given then
        local base = path:match("^(.*)/[^/]+/[^/]+/SavedVariables/[^/]+$")
        given = base and (base .. "/SavedVariables/LevelScout.lua")
    end
    if not given then return nil end
    path = given
    local db = R.ReadSaved(path, "LevelScoutDB")
    if type(db) ~= "table" or type(db.drops) ~= "table" then return nil end
    local records, kills = 0, 0
    for key, rec in pairs(db.drops) do
        if type(key) == "string" and key:match("^%d+:%d+$") and type(rec) == "table" then
            records, kills = records + 1, kills + (tonumber(rec.k) or 0)
        end
    end
    return { path = path, records = records, kills = kills, store = db.drops }
end

local function main(argv)
    local path, id, opts = nil, nil, {}
    for _, a in ipairs(argv) do
        if a == "--list" then opts.list = true
        elseif a == "--cold" then opts.cold = true
        elseif a == "--help" or a == "-h" then io.write(USAGE, "\n") return 0
        elseif a:match("^%-%-settings=") then opts.settings = a:match("=(.*)$")
        elseif a:match("^%-%-zone=") then
            opts.zone = tonumber(a:match("=(.*)$"))
            if not opts.zone then return fail("--zone takes a uiMapID, such as --zone=1429") end
        elseif a:match("^%-%-account=") then opts.account = a:match("=(.*)$")
        elseif a:match("^%-%-drops=") then opts.drops = a:match("=(.*)$")
        elseif a:match("^%-%-") then io.stderr:write("replay: unknown option ", a, "\n") io.write(USAGE, "\n") return 2
        elseif not path then path = a
        elseif not id and tonumber(a) then id = tonumber(a)
        else io.stderr:write("replay: unexpected argument ", a, "\n") io.write(USAGE, "\n") return 2 end
    end
    if not path then io.write(USAGE, "\n") return 2 end
    if opts.settings and opts.settings ~= "code" then return fail("--settings takes only the value code") end
    if opts.drops and opts.drops ~= "account" then return fail("--drops takes only the value account") end

    local db, err = R.ReadSaved(path, "LevelScoutCharDB")
    if db == nil then return fail(err and ("cannot read " .. tostring(err)) or (path .. " holds no LevelScoutCharDB")) end
    if type(db) ~= "table" then return fail(path .. ": LevelScoutCharDB is not a table") end
    local list = type(db.snapshots) == "table" and db.snapshots or {}
    if #list == 0 then
        return fail(path .. " holds no snapshot. Take one in game with /ls snapshot [note], then /reload so the game writes it to disk.")
    end
    if opts.list then write(R.List(list)) return 0 end
    local snap
    if id then
        for _, s in ipairs(list) do if s.id == id then snap = s end end
        if not snap then
            local ids = {}
            for _, s in ipairs(list) do ids[#ids + 1] = tostring(s.id) end
            return fail("no snapshot " .. id .. " in " .. path .. "; there are: " .. table.concat(ids, ", "))
        end
    else
        snap = list[#list]
    end
    if type(snap.input) ~= "table" or type(snap.shown) ~= "table" then return fail("snapshot " .. tostring(snap.id) .. " is incomplete") end

    local ok, ns = pcall(R.Setup, snap)
    if not ok then return fail(tostring(ns)) end
    if snap.format ~= ns.Snapshot.FORMAT then
        return fail(string.format("snapshot %s is format %s, this code reads format %s", tostring(snap.id), tostring(snap.format), tostring(ns.Snapshot.FORMAT)))
    end
    local info = { settingsFrom = opts.settings == "code" and "code" or "game", cold = opts.cold, skipped = {} }
    info.settingsDiff = R.SettingsDiff(ns, snap.settings or {})
    if info.settingsFrom == "game" then info.applied, info.skipped = R.ApplySettings(ns, snap.settings or {}) end

    local replayOpts = { cold = opts.cold }
    local account = accountOf(path, opts.account)
    if opts.drops == "account" and not account then return fail("--drops=account: no account file found (give --account=PATH)") end
    if account then
        local snapshotKills = 0
        for _, rec in pairs(ns.Snapshot.DecodeDrops(snap.input.drops)) do snapshotKills = snapshotKills + (rec.k or 0) end
        account.snapshotKills = snapshotKills
        account.used = opts.drops == "account"
        if account.used then replayOpts.drops = account.store end
        info.account = account
    end

    local done, result = pcall(R.Replay, ns, snap, replayOpts)
    if not done then return fail("planning the snapshot failed: " .. tostring(result)) end
    local cmp = { names = snap.names }
    info.diffs, info.count, info.notes = R.Compare(snap.shown, result.view, cmp)
    info.before = snap.before and R.Compare(snap.before, snap.shown, { light = true, names = snap.names }) or {}
    local sources = {}
    for k, v in pairs(ns.Data.status.sources or {}) do sources[k] = v end
    info.version = { addon = ns.version, client = snap.version and snap.version.client, data = ns.Data.status.build,
        generated = ns.Data.status.generated, sources = sources }
    write(R.Report(ns, snap, result, info))
    if opts.zone then write(R.PrintZone(result, opts.zone)) end
    return #info.diffs == 0 and 0 or 1
end

if arg and arg[0] and arg[0]:match("replay%.lua$") then os.exit(main(arg)) end

return R
