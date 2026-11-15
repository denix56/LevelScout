-- tools/import/questiedb.lua: loads the installed QuestieDB addon (its own code and baked data)
-- inside the sandbox, so every read goes through LibQuestieDB exactly as in the game.
local here = ...
local Sandbox = assert(loadfile(here .. "/sandbox.lua"))(here)
local Client = assert(loadfile(here .. "/client.lua"))(here)

local M = {}

--- Returns LibQuestieDB, the sandbox env and the client state (faction/class switchable).
function M.Load(addonDir, faction, class)
    local toc = addonDir .. "/QuestieDB_Forever.toc"
    local state = { faction = faction or "Alliance", class = class or "WARRIOR", metadata = {} }
    state.metadata.QuestieDB = Sandbox.TocMetadata(toc)
    local env = Client.NewEnv(state)
    local addonTable = {}
    for _, file in ipairs(Sandbox.TocFiles(toc)) do
        Sandbox.RunFile(env, addonDir .. "/" .. file, "QuestieDB", addonTable)
    end
    return env.LibQuestieDB or addonTable, env, state
end

return M
