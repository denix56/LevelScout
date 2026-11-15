-- tests/harness.lua: a tiny test framework plus an addon loader for standalone Lua 5.1.
-- Files are loaded in TOC order with (addonName, ns), exactly as the client does.

local H = {}

H.root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."

local tests, current = {}, nil

function H.test(name, fn)
    tests[#tests + 1] = { name = (current and (current .. ": ") or "") .. name, fn = fn }
end

function H.suite(name, body)
    current = name
    body()
    current = nil
end

local function fmt(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

local function deepEq(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
H.deepEq = deepEq

local function serialize(v, depth)
    depth = depth or 0
    if type(v) ~= "table" or depth > 3 then return fmt(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. serialize(v[k], depth + 1) end
    return "{" .. table.concat(parts, ", ") .. "}"
end
H.serialize = serialize

function H.eq(actual, expected, msg)
    if not deepEq(actual, expected) then
        error(string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "",
            serialize(expected), serialize(actual)), 2)
    end
end

function H.ok(value, msg)
    if not value then error(msg or "expected a true value", 2) end
end

function H.near(actual, expected, tol, msg)
    if type(actual) ~= "number" or math.abs(actual - expected) > (tol or 1e-9) then
        error(string.format("%sexpected %s +- %s, got %s", msg and (msg .. ": ") or "",
            tostring(expected), tostring(tol), tostring(actual)), 2)
    end
end

function H.contains(str, pattern, msg)
    if type(str) ~= "string" or not str:find(pattern, 1, true) then
        error(string.format("%sexpected %s to contain %q", msg and (msg .. ": ") or "", fmt(str), pattern), 2)
    end
end

--- Files listed in LevelScout.toc, in order, with forward slashes.
function H.tocFiles()
    local files = {}
    for line in io.lines(H.root .. "/LevelScout/LevelScout.toc") do
        if not line:match("^%s*#") and line:match("%S") then
            files[#files + 1] = (line:gsub("\\", "/"):gsub("%s+$", ""))
        end
    end
    return files
end

--- TOC files without the generated data (fixture tests set ns.data themselves).
function H.runtimeFiles()
    local out = {}
    for _, f in ipairs(H.tocFiles()) do
        if not f:match("^data/") then out[#out + 1] = f end
    end
    return out
end

--- Load the addon (all TOC files, or `only`) into `ns` (default: a fresh namespace).
function H.loadAddon(only, ns)
    ns = ns or {}
    for _, file in ipairs(only or H.tocFiles()) do
        local chunk, err = loadfile(H.root .. "/LevelScout/" .. file)
        if not chunk then error("load " .. file .. ": " .. tostring(err)) end
        chunk("LevelScout", ns)
    end
    return ns
end

--- Run the tests; with `filter`, only those whose name contains it (./run_tests.sh "live progress").
function H.run(filter)
    local passed, failed = 0, 0
    local times = os.getenv("TIMES") and {} or nil -- TIMES=1 ./run_tests.sh: the slowest tests at the end
    for _, t in ipairs(tests) do
        local ok, err = true, nil
        local chosen = not filter or t.name:lower():find(filter:lower(), 1, true)
        if chosen then
            local t0 = os.clock()
            ok, err = xpcall(t.fn, debug.traceback)
            if times then times[#times + 1] = { os.clock() - t0, t.name } end
        end
        if not chosen then
            -- left out
        elseif ok then
            passed = passed + 1
        else
            failed = failed + 1
            io.write("FAIL ", t.name, "\n  ", tostring(err):gsub("\n", "\n  "), "\n")
        end
    end
    if times then
        table.sort(times, function(a, b) return a[1] > b[1] end)
        local total = 0
        for _, x in ipairs(times) do total = total + x[1] end
        for i = 1, math.min(25, #times) do io.write(string.format("%7.2fs  %s\n", times[i][1], times[i][2])) end
        io.write(string.format("%7.2fs  total CPU in tests\n", total))
    end
    io.write(string.format("%d passed, %d failed\n", passed, failed))
    return failed == 0
end

return H
