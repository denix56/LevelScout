-- Init.lua: addon namespace. Every file receives (addonName, ns) from the client;
-- the test harness passes the same pair, so modules never depend on globals for wiring.
local ADDON, ns = ...

ns.name = ADDON or "LevelScout"

-- The TOC's "## Version" holds the packager's project-version keyword, which BigWigs
-- release.sh replaces with the git tag. Run from the repository (unpackaged) or outside the
-- game, the keyword (it contains "@") is still there or there is no metadata to read: the
-- version is then "dev".
local function addonVersion()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or rawget(_G, "GetAddOnMetadata")
    local ok, v = pcall(function() return get and get(ns.name, "Version") end)
    if not ok or type(v) ~= "string" or v == "" or v:find("@", 1, true) then return "dev" end
    return v
end
ns.version = addonVersion()

-- Exposed for /dump debugging only. Code inside the addon uses `ns`.
_G.LevelScout = ns

local PREFIX = "|cffffd100LevelScout|r: "

function ns.Print(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print(PREFIX .. msg)
end
