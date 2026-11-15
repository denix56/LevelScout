-- adapters/TomTom.lua
--
-- The only code that touches TomTom (optional): detection, version check, and the one
-- waypoint LevelScout shows. Shape checked against TomTom v4.4.1-release
-- (core/waypoints.lua: AddWaypoint/RemoveWaypoint/IsValidWaypoint/DefaultCallbacks).

local _, ns = ...

local TomTomAdapter = {}
ns.TomTom = TomTomAdapter

TomTomAdapter.TESTED = "v4.4.1-release"

local function addonMeta(name, field)
    local fn = (C_AddOns and C_AddOns.GetAddOnMetadata) or rawget(_G, "GetAddOnMetadata")
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, name, field)
    return ok and value or nil
end

local function addonLoaded(name)
    local fn = (C_AddOns and C_AddOns.IsAddOnLoaded) or rawget(_G, "IsAddOnLoaded")
    if type(fn) ~= "function" then return false end
    local ok, value = pcall(fn, name)
    return ok and value and true or false
end

local handle

--- Returns a status { state = "ok"|"untested"|"missing"|"incompatible", version, message }.
function TomTomAdapter.Check()
    handle = nil
    local st = { name = "TomTom", version = addonMeta("TomTom", "Version"), notes = {} }
    TomTomAdapter.status = st
    local T = rawget(_G, "TomTom")
    local loaded = addonLoaded("TomTom")
    if type(T) ~= "table" then
        st.state = loaded and "incompatible" or "missing"
        st.message = loaded and "TomTom is loaded but its global table is missing"
            or "not installed (optional); the game's own map waypoint is used instead"
        return st
    end
    -- Other addons create a stand-in `TomTom` table with only AddWaypoint (TomTom README).
    if type(T.IsCrazyArrowEmpty) ~= "function" then
        st.state = loaded and "incompatible" or "missing"
        st.message = "found a TomTom stand-in from another addon, not TomTom itself"
        return st
    end
    for _, fn in ipairs({ "AddWaypoint", "RemoveWaypoint", "IsValidWaypoint", "DefaultCallbacks" }) do
        if type(T[fn]) ~= "function" then
            st.state, st.message = "incompatible", "TomTom:" .. fn .. " is missing"
            return st
        end
    end
    st.state = (st.version == TomTomAdapter.TESTED) and "ok" or "untested"
    if st.state == "untested" then
        st.notes[1] = string.format("version %s is untested (tested: %s)", tostring(st.version), TomTomAdapter.TESTED)
    end
    handle = T
    return st
end

-- The waypoint we created. TomTom's uid is a table we own; only this one is ever removed.
local current

--- Remove our waypoint (never anyone else's).
function TomTomAdapter.Clear()
    local uid = current
    current = nil
    if not uid or not handle then return end
    local ok, valid = pcall(handle.IsValidWaypoint, handle, uid)
    if ok and valid then pcall(handle.RemoveWaypoint, handle, uid) end
end

--- Show one waypoint with the arrow. x, y are 0-1. Returns true when TomTom took it.
function TomTomAdapter.Set(mapId, x, y, title)
    if not handle then return false end
    TomTomAdapter.Clear()
    -- TomTom changes the options table, so it is built fresh. cleardistance 0 keeps the
    -- waypoint while we work at the spot; it goes when the step is done.
    local opts = { title = title, from = "LevelScout", persistent = false, minimap = true, world = true,
        crazy = true, silent = true, cleardistance = 0, arrivaldistance = 15 }
    local ok, uid = pcall(handle.AddWaypoint, handle, mapId, x, y, opts)
    if ok and type(uid) == "table" then
        current = uid
        return true
    end
    return false
end

function TomTomAdapter.Available() return handle ~= nil end
function TomTomAdapter.Get() return handle end

TomTomAdapter.status = { name = "TomTom", state = "missing", notes = {} }
