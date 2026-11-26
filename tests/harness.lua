-- tests/harness.lua: a tiny test framework plus an addon loader for standalone Lua 5.1.
-- Files are loaded in TOC order with (addonName, ns), exactly as the client does.

local H = {}

H.root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."

local tests, current = {}, nil
local files, currentFile, loadStart, loadTime = {}, nil, nil, {}

function H.test(name, fn)
    tests[#tests + 1] = { name = (current and (current .. ": ") or "") .. name, fn = fn,
        suite = current, file = currentFile or "tests" }
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

-- Progress (tests/progress.lua): with TEST_EVENTS (run_tests.sh sets it to a pipe), each step
-- is written there as an event line, and stdout keeps only the failures, the TIMES table and the
-- tally; otherwise a reporter in this process shows the progress on stdout.
local sink, reporter

local function emit(kind, ...)
    local P = require("progress")
    if sink == nil then
        sink = false
        local path = os.getenv("TEST_EVENTS")
        local fh = path and path ~= "" and io.open(path, "a")
        if fh then sink = fh else reporter = P.new({ details = true }) end
    end
    local parts = { kind }
    for i = 1, select("#", ...) do parts[#parts + 1] = P.field((select(i, ...))) end
    local line = table.concat(parts, "\t")
    if sink then
        if #line > P.EVENT_MAX then line = line:sub(1, P.EVENT_MAX) end
        sink:write(line, "\n")
        sink:flush()
    elseif reporter then
        reporter:event(line)
    end
end

--- Output that stays: through the reporter when it draws a status line on this stdout.
local function out(text)
    if reporter then reporter:write(text) else io.write(text) end
end

local function endLoad()
    if currentFile and loadStart then
        loadTime[currentFile] = (loadTime[currentFile] or 0) + os.clock() - loadStart
        loadStart = nil
        emit("loaded", currentFile)
    end
end

--- run.lua calls this before loading each test file: the tests it adds belong to that file.
function H.beginFile(name)
    endLoad()
    currentFile, loadStart = name, os.clock()
    files[#files + 1] = name
    emit("load", name)
end

--- Run the tests; with `filter`, only those whose name contains it (./run_tests.sh "live progress").
function H.run(filter)
    endLoad()
    local passed, failed = 0, 0
    local times = os.getenv("TIMES") and {} or nil -- TIMES=1 ./run_tests.sh: the slowest tests at the end

    -- The chosen tests by file, in the order the files were loaded.
    local byFile, order = {}, {}
    for _, f in ipairs(files) do
        if not byFile[f] then byFile[f] = {}; order[#order + 1] = f end
    end
    for _, t in ipairs(tests) do
        if not byFile[t.file] then byFile[t.file] = {}; order[#order + 1] = t.file end
        if not filter or t.name:lower():find(filter:lower(), 1, true) then
            local list = byFile[t.file]
            list[#list + 1] = t
        end
    end

    for _, file in ipairs(order) do emit("count", file, #byFile[file]) end
    for _, file in ipairs(order) do
        local list, p, x, suite = byFile[file], 0, 0, nil
        local c0 = os.clock()
        emit("start", file, #list)
        for _, t in ipairs(list) do
            if t.suite and t.suite ~= suite then
                suite = t.suite
                emit("suite", file, suite)
            end
            emit("run", file, t.name)
            local t0 = os.clock()
            local ok, err = xpcall(t.fn, debug.traceback)
            if times then times[#times + 1] = { os.clock() - t0, t.name } end
            if ok then
                p = p + 1
                emit("ok", file, t.name)
            else
                x = x + 1
                emit("fail", file, t.name)
                out("FAIL " .. t.name .. "\n  " .. tostring(err):gsub("\n", "\n  ") .. "\n")
            end
        end
        passed, failed = passed + p, failed + x
        emit("done", file, p, x, string.format("%.2f", (loadTime[file] or 0) + os.clock() - c0))
    end

    if reporter then reporter:close(); reporter = nil end
    if times then
        table.sort(times, function(a, b) return a[1] > b[1] end)
        local total = 0
        for _, x in ipairs(times) do total = total + x[1] end
        for i = 1, math.min(25, #times) do out(string.format("%7.2fs  %s\n", times[i][1], times[i][2])) end
        out(string.format("%7.2fs  total CPU in tests\n", total))
    end
    io.write(string.format("%d passed, %d failed\n", passed, failed))
    return failed == 0
end

return H
