-- tools/import/import.lua
--
-- Builds LevelScout/data/*.lua, the baked ForeverDB layer, from one source:
--   ForeverDB  (GPL-3.0 + attribution, includes CMaNGOS classic-db GPL-3.0)
--              Forever quest titles and levels, CMaNGOS objective counts and prerequisites,
--              Forever-observed quest/objective locations, measured drop rates and XP, NPC
--              levels, pace (seconds per kill/item/object), travel, zones, dungeons
--
-- QuestieDB is not read here. The addon requires the QuestieDB addon and reads quests, NPCs,
-- objects, items and its support tables from it at runtime (LevelScout/adapters/Merge.lua),
-- with QuestieDB's corrections for the logged-in character.
--
-- Usage (from the repo root):
--   .tools/bin/lua5.1 tools/import/import.lua --foreverdb <dir> [--out LevelScout/data]
--
-- The run fails loudly when ForeverDB does not have the shape this script expects.

local here = (arg and arg[0] or ""):match("^(.*)/[^/]+$") or "."
local function module(name) return assert(loadfile(here .. "/" .. name .. ".lua"))(here) end
local ForeverDBLoader = module("foreverdb")
local Writer = module("writer")
local Layer = module("layer")

local args = { out = "LevelScout/data", foreverdb = "local/sources/ForeverDB" }
do
    local i = 1
    while arg[i] do
        local key = arg[i]:match("^%-%-(.+)$")
        if not key or not arg[i + 1] or (key ~= "foreverdb" and key ~= "out") then
            error("usage: import.lua --foreverdb DIR [--out DIR]", 0)
        end
        args[key] = arg[i + 1]
        i = i + 2
    end
end

local t0 = os.clock()
local function log(fmt, ...) io.stderr:write(string.format("[%5.1fs] " .. fmt .. "\n", os.clock() - t0, ...)) end

log("loading ForeverDB from %s", args.foreverdb)
local F, finfo = ForeverDBLoader.Load(args.foreverdb)
if #finfo.failed > 0 then error("ForeverDB data files failed to load:\n  " .. table.concat(finfo.failed, "\n  "), 0) end

-- The client build ForeverDB's data was made for (first line of every ForeverDB data file).
local build
do
    local f = assert(io.open(args.foreverdb .. "/Data/QuestXP.lua", "rb"))
    build = (f:read("*l") or ""):match("build (%d+%.%d+%.%d+%.%d+)")
    f:close()
    if not build then error("ForeverDB: cannot read the client build from Data/QuestXP.lua", 0) end
end

log("building the ForeverDB layer")
local model, report = Layer.Build(F)
model.meta = {
    build = build,
    generated = os.date("!%Y-%m-%d"),
    -- ForeverDBData is ForeverDB's daily data version (Data/Meta.lua), which changes more often than
    -- the addon version; tools/update.sh compares it with the site's manifest.
    sources = { ForeverDB = finfo.version, ForeverDBData = type(F.meta) == "table" and F.meta.version or nil },
    -- The QuestieDB contract the runtime merge is written against (adapters/Merge.lua).
    requires = { QuestieDBContract = 4 },
    counts = report.counts,
}

log("writing %s", args.out)
local files = Writer.Write(args.out, model)
for _, f in ipairs(files) do log("  %s  %d KB", f.name, math.floor(f.bytes / 1024 + 0.5)) end

local reportPath = here .. "/last_report.txt"
local rf = assert(io.open(reportPath, "w"))
rf:write(Layer.FormatReport(report, model.meta))
rf:close()
io.stdout:write(Layer.FormatReport(report, model.meta))
log("done; report in %s", reportPath)
