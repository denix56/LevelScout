-- tools/import/client.lua
--
-- A stand-in for the WoW client APIs that QuestieDB and ForeverDB touch while loading:
-- addon metadata (QuestieDB's baked data store), C_EncodingUtil (Base64, zlib, CBOR),
-- faction/class/locale queries, and inert frames/timers. Only what loading needs.

local here = ...
local Sandbox = assert(loadfile(here .. "/sandbox.lua"))(here)

local Client = {}

---------------------------------------------------------------------------------------------
-- Base64
---------------------------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64index = {}
for i = 1, #B64 do b64index[B64:byte(i)] = i - 1 end

function Client.DecodeBase64(s)
    local out, n = {}, 0
    local acc, bits = 0, 0
    for i = 1, #s do
        local v = b64index[s:byte(i)]
        if v then
            acc = acc * 64 + v
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local byte = math.floor(acc / 2 ^ bits)
                acc = acc - byte * 2 ^ bits
                n = n + 1
                out[n] = string.char(byte)
            end
        end
    end
    return table.concat(out)
end

---------------------------------------------------------------------------------------------
-- CBOR (RFC 8949 subset produced by C_EncodingUtil.SerializeCBOR)
---------------------------------------------------------------------------------------------

local byte, sub, ldexp, floor = string.byte, string.sub, math.ldexp, math.floor

local function uint(b, i, n)
    local v = 0
    for k = 0, n - 1 do v = v * 256 + byte(b, i + k) end
    return v
end

local function half(h)
    local sign = h >= 0x8000 and -1 or 1
    local e = floor(h / 1024) % 32
    local m = h % 1024
    if e == 0 then return sign * ldexp(m, -24) end
    if e == 31 then return m == 0 and sign * math.huge or 0 / 0 end
    return sign * ldexp(m + 1024, e - 25)
end

local function single(b, i)
    local v = uint(b, i, 4)
    local sign = v >= 0x80000000 and -1 or 1
    local e = floor(v / 0x800000) % 256
    local m = v % 0x800000
    if e == 0 then return sign * ldexp(m, -149) end
    if e == 255 then return m == 0 and sign * math.huge or 0 / 0 end
    return sign * ldexp(m + 0x800000, e - 150)
end

local function double(b, i)
    local hi, lo = uint(b, i, 4), uint(b, i + 4, 4)
    local sign = hi >= 0x80000000 and -1 or 1
    local e = floor(hi / 0x100000) % 2048
    local m = (hi % 0x100000) * 2 ^ 32 + lo
    if e == 0 then return sign * ldexp(m, -1074) end
    if e == 2047 then return m == 0 and sign * math.huge or 0 / 0 end
    return sign * ldexp(m + 2 ^ 52, e - 1075)
end

local decode

local function argument(b, i, ai)
    if ai < 24 then return ai, i end
    if ai == 24 then return byte(b, i), i + 1 end
    if ai == 25 then return uint(b, i, 2), i + 2 end
    if ai == 26 then return uint(b, i, 4), i + 4 end
    if ai == 27 then return uint(b, i, 8), i + 8 end
    error("cbor: unsupported additional info " .. ai)
end

decode = function(b, i)
    local ib = byte(b, i)
    local mt, ai = floor(ib / 32), ib % 32
    i = i + 1
    if mt == 7 then
        if ai == 20 then return false, i end
        if ai == 21 then return true, i end
        if ai == 22 or ai == 23 then return nil, i end
        if ai == 25 then return half(uint(b, i, 2)), i + 2 end
        if ai == 26 then return single(b, i), i + 4 end
        if ai == 27 then return double(b, i), i + 8 end
        error("cbor: unsupported simple value " .. ai)
    end
    local v
    v, i = argument(b, i, ai)
    if mt == 0 then return v, i end
    if mt == 1 then return -1 - v, i end
    if mt == 2 or mt == 3 then return sub(b, i, i + v - 1), i + v end
    if mt == 4 then
        local t = {}
        for k = 1, v do t[k], i = decode(b, i) end
        return t, i
    end
    if mt == 5 then
        local t = {}
        for _ = 1, v do
            local key, value
            key, i = decode(b, i)
            value, i = decode(b, i)
            if key ~= nil then t[key] = value end
        end
        return t, i
    end
    if mt == 6 then return decode(b, i) end
    error("cbor: unsupported major type " .. mt)
end

function Client.DeserializeCBOR(b)
    return (decode(b, 1))
end

---------------------------------------------------------------------------------------------
-- Environment
---------------------------------------------------------------------------------------------

local LibDeflate = dofile(here .. "/vendor/LibDeflate.lua")

--- Build the client stand-in. `state.faction` ("Alliance"/"Horde") and `state.class`
--- ("WARRIOR", ...) can be changed between correction passes; `metadata[addon]` holds parsed
--- TOC metadata for every addon whose metadata is read.
function Client.NewEnv(state)
    state.metadata = state.metadata or {}
    local function getMeta(addon, key)
        local m = state.metadata[addon]
        return m and m[key] or nil
    end
    local inert = setmetatable({}, { __index = function() return function() end end })
    local function frame()
        return setmetatable({}, { __index = function() return function() end end })
    end
    local env = Sandbox.NewEnv({
        C_AddOns = { GetAddOnMetadata = getMeta, IsAddOnLoaded = function() return false end },
        GetAddOnMetadata = getMeta,
        C_EncodingUtil = {
            DecodeBase64 = Client.DecodeBase64,
            DecompressString = function(s, method)
                local out = (method == 1) and LibDeflate:DecompressZlib(s) or LibDeflate:DecompressDeflate(s)
                if not out then error("decompress failed") end
                return out
            end,
            DeserializeCBOR = Client.DeserializeCBOR,
        },
        UnitFactionGroup = function() return state.faction, state.faction end,
        UnitClassBase = function() return state.class end,
        UnitClass = function() return state.class, state.class end,
        UnitRace = function() return "Human", "Human", 1 end,
        UnitLevel = function() return 1 end,
        UnitName = function() return "Importer" end,
        GetLocale = function() return "enUS" end,
        GetRealmName = function() return "Import" end,
        GetBuildInfo = function() return "1.60.1", "70888", "Nov 1 2026", 16001 end,
        GetTime = function() return 0 end,
        GetTimePreciseSec = function() return 0 end,
        debugprofilestop = function() return 0 end,
        debugstack = function() return "" end,
        IsInInstance = function() return false end,
        InCombatLockdown = function() return false end,
        issecretvalue = function() return false end,
        CreateFrame = frame,
        UIParent = frame(),
        C_Timer = { After = function() end, NewTicker = function() return inert end, NewTimer = function() return inert end },
        WOW_PROJECT_ID = 1, WOW_PROJECT_MAINLINE = 1, WOW_PROJECT_CLASSIC = 2,
        strsplit = function(sep, s, limit)
            local out, start = {}, 1
            while true do
                if limit and #out == limit - 1 then out[#out + 1] = s:sub(start); break end
                local a, b2 = s:find(sep, start, true)
                if not a then out[#out + 1] = s:sub(start); break end
                out[#out + 1] = s:sub(start, a - 1)
                start = b2 + 1
            end
            return unpack(out)
        end,
        strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
        format = string.format,
        tinsert = table.insert,
        tremove = table.remove,
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
        floor = math.floor,
        max = math.max,
        min = math.min,
        Enum = setmetatable({}, { __index = function() return {} end }),
    })
    return env
end

return Client
