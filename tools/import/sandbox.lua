-- tools/import/sandbox.lua
--
-- Runs third-party addon files (QuestieDB code, ForeverDB data) in standalone Lua 5.1 with no
-- access to io, os, require, loadfile or dofile. Each file gets (addonName, addonTable) as `...`,
-- exactly like the client. A stand-in for the few client APIs those files touch is installed
-- into the environment (see client.lua).

local Sandbox = {}

local SAFE = {
    "assert", "error", "ipairs", "next", "pairs", "pcall", "xpcall", "select", "tonumber",
    "tostring", "type", "unpack", "rawget", "rawset", "rawequal", "setmetatable", "getmetatable",
    "loadstring", "setfenv", "getfenv", "collectgarbage", "gcinfo",
}

local function copyLib(lib)
    local out = {}
    for k, v in pairs(lib) do out[k] = v end
    return out
end

--- A fresh global environment. `extra` entries are added on top (client stand-ins).
function Sandbox.NewEnv(extra)
    local env = {}
    for _, name in ipairs(SAFE) do env[name] = _G[name] end
    env.string, env.table, env.math, env.coroutine = copyLib(string), copyLib(table), copyLib(math), copyLib(coroutine)
    env.print = function() end
    env._G = env
    -- Chunks compiled inside the sandbox (QuestieDB uses loadstring for support tables) must
    -- also run in the sandbox, never in our real globals.
    env.loadstring = function(src, name)
        local chunk, err = loadstring(src, name)
        if chunk then setfenv(chunk, env) end
        return chunk, err
    end
    env.setfenv = function(f, t)
        if type(f) == "function" then return setfenv(f, t) end
        error("sandbox: setfenv on stack levels is not allowed")
    end
    env.getfenv = function(f)
        if type(f) == "function" then return getfenv(f) end
        return env
    end
    for k, v in pairs(extra or {}) do env[k] = v end
    return env
end

function Sandbox.ReadFile(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return data
end

--- Load and run one file in `env`, passing `...` through. Returns the chunk's results.
function Sandbox.RunFile(env, path, ...)
    local src, err = Sandbox.ReadFile(path)
    if not src then error("cannot read " .. path .. ": " .. tostring(err), 0) end
    src = src:gsub("^\239\187\191", "") -- UTF-8 BOM
    local chunk, cerr = loadstring(src, "@" .. path)
    if not chunk then error(cerr, 0) end
    setfenv(chunk, env)
    return chunk(...)
end

--- Lua files listed in a TOC, in order, as paths relative to the addon folder (forward slashes).
--- Lines with a `[AllowLoadTextLocale xx]` style condition are kept only for enUS.
function Sandbox.TocFiles(tocPath)
    local src = assert(Sandbox.ReadFile(tocPath), "cannot read " .. tocPath)
    local files = {}
    for line in src:gmatch("[^\r\n]+") do
        if not line:match("^%s*#") and line:match("%S") then
            local file, cond = line:match("^%s*(.-)%s*%[(.-)%]%s*$")
            file = file or line:match("^%s*(.-)%s*$")
            local keep = not cond or cond:match("enUS")
            if keep and file:match("%.lua$") then
                files[#files + 1] = (file:gsub("\\", "/"))
            end
        end
    end
    return files
end

--- `## Key: value` metadata of a TOC (the store QuestieDB's baked mode reads from).
function Sandbox.TocMetadata(tocPath)
    local src = assert(Sandbox.ReadFile(tocPath), "cannot read " .. tocPath)
    local meta = {}
    for key, value in src:gmatch("##%s*([^:\r\n]+):[ \t]*([^\r\n]*)") do
        meta[key] = value
    end
    return meta
end

return Sandbox
