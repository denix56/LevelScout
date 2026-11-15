-- tools/import/foreverdb.lua: loads ForeverDB's data files (Data/*.lua, as listed in its TOC)
-- inside the sandbox and returns its addon table. ForeverDB's code files are not run.
local here = ...
local Sandbox = assert(loadfile(here .. "/sandbox.lua"))(here)
local Client = assert(loadfile(here .. "/client.lua"))(here)

local M = {}

function M.Load(addonDir, faction)
    local toc = addonDir .. "/ForeverDB.toc"
    local state = { faction = faction or "Alliance", class = "WARRIOR", metadata = {} }
    state.metadata.ForeverDB = Sandbox.TocMetadata(toc)
    local env = Client.NewEnv(state)
    local ns, loaded, failed = {}, {}, {}
    for _, file in ipairs(Sandbox.TocFiles(toc)) do
        if file:match("^Data/") then
            local ok, err = pcall(Sandbox.RunFile, env, addonDir .. "/" .. file, "ForeverDB", ns)
            if ok then loaded[#loaded + 1] = file else failed[#failed + 1] = file .. ": " .. tostring(err) end
        end
    end
    return ns, { loaded = loaded, failed = failed, version = state.metadata.ForeverDB.Version }
end

return M
