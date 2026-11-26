-- tests/progress.lua: live progress for the test runs.
--
-- The harness reports what it does as events: a file loads, its tests start, a suite starts, a
-- test runs and passes or fails, the file is done. A reporter turns them into output:
--   on a terminal: one status line, redrawn in place, with failures and finished files above it;
--   elsewhere (a CI log, a file): plain lines, a line per suite and file, and a status line
--     every TEST_HEARTBEAT seconds (default 30) while tests run. TEST_TTY=1 or 0 forces either.
--
-- Used two ways:
--   require("progress") in the harness, when one process runs the tests (SERIAL=1, or
--     .tools/bin/lua5.1 tests/run.lua): the harness calls the reporter directly.
--   `lua5.1 tests/progress.lua <files>` in run_tests.sh, which runs a process per file: each
--     process writes its events as lines to TEST_EVENTS (its fd 3, a pipe shared by all of
--     them), this script reads them on stdin, reports, and at the end prints the failures from
--     the per-file logs in $OUT, the time per file and the total. Exits 1 if a test failed or a
--     file did not finish.
--
-- An event line is tab-separated: kind, file, then the kind's fields:
--   load <file>                       the file is being loaded (its tests are being set up)
--   loaded <file>                     loaded; waits for its turn (one process runs several files)
--   count <file> <tests>              how many tests the filter picked in the file
--   start <file> <tests>              its tests start (with the count again)
--   suite <file> <name>               a suite starts
--   run <file> <test>                 a test starts
--   ok <file> <test>  /  fail <file> <test>
--   done <file> <passed> <failed> <cpu seconds, loading included>
--   exit <file> <exit code>           the process ended (written by run_tests.sh)
-- Lines are kept short (EVENT_MAX bytes), so each is one write and lines from processes running
-- side by side do not mix.

local P = {}

P.EVENT_MAX = 400

--- One event field: no tabs or line breaks, and short.
function P.field(v)
    local s = tostring(v == nil and "" or v):gsub("[%c]", " ")
    if #s > 150 then s = s:sub(1, 147) .. "..." end
    return s
end

--- "12s", "3m05s" (whole seconds).
local function clock(s)
    s = math.floor(s + 0.5)
    if s < 60 then return s .. "s" end
    return string.format("%dm%02ds", math.floor(s / 60), s % 60)
end
P.clock = clock

--- "0.4s", "12.3s", "3m05s".
local function seconds(s)
    if s < 59.95 then return string.format("%.1fs", s) end
    return clock(s)
end

--- Is stdout a terminal? TEST_TTY=1/0 decides; TERM=dumb is not one.
function P.isTTY()
    local forced = os.getenv("TEST_TTY")
    if forced and forced ~= "" then return forced ~= "0" end
    if os.getenv("TERM") == "dumb" then return false end
    return os.execute("[ -t 1 ]") == 0
end

local function columns()
    local n = tonumber(os.getenv("COLUMNS") or "")
    if n and n > 0 then return n end
    local pipe = io.popen("stty size < /dev/tty 2> /dev/null")
    if pipe then
        local line = pipe:read("*l")
        pipe:close()
        n = line and tonumber(line:match("^%d+%s+(%d+)"))
        if n and n > 0 then return n end
    end
    return 80
end

local R = {}
R.__index = R

--- A reporter. opts: out (default io.stdout), tty (default P.isTTY()), files (the files that
--- will run, for "3/17 files"; without it, the files seen so far), heartbeat (seconds),
--- details (true: the caller prints each failure in full, so no short FAIL line here).
function P.new(opts)
    opts = opts or {}
    local tty = opts.tty
    if tty == nil then tty = P.isTTY() end
    local r = setmetatable({
        out = opts.out or io.stdout, tty = tty, cols = tty and columns() or 0,
        expected = opts.files, files = {}, order = {},
        passed = 0, failed = 0, done = 0, finished = 0,
        t0 = os.time(), lastBeat = os.time(),
        heartbeat = opts.heartbeat or tonumber(os.getenv("TEST_HEARTBEAT") or "") or 30,
        shown = false, details = opts.details,
    }, R)
    for _, f in ipairs(opts.files or {}) do r:entry(f) end
    return r
end

function R:entry(name)
    local e = self.files[name]
    if not e then
        e = { name = name, state = "waiting", done = 0, failed = 0 }
        self.files[name] = e
        self.order[#self.order + 1] = name
    end
    return e
end

function R:elapsed() return os.time() - self.t0 end

--- "230/416 tests, 1 failed, 12/17 files, 1m10s". The test total is "350+" while some files
--- have not started (their counts are not known yet).
function R:summary()
    local total, known = 0, true
    for _, name in ipairs(self.order) do
        local e = self.files[name]
        if e.n then total = total + e.n elseif not e.broken then known = false end
    end
    return string.format("%d/%d%s tests, %d failed, %d/%d files, %s", self.done, total,
        known and "" or "+", self.failed, self.finished, #self.order, clock(self:elapsed()))
end

--- The files loading or running now: "test_game_3 40/96, test_core loading".
function R:running(detail)
    local parts = {}
    for _, name in ipairs(self.order) do
        local e = self.files[name]
        if e.state == "loading" then
            parts[#parts + 1] = name .. " loading"
        elseif e.state == "running" then
            local s = string.format("%s %d/%d", name, e.done, e.n or 0)
            if detail and e.test then s = s .. " " .. e.test end
            parts[#parts + 1] = s
        end
    end
    return table.concat(parts, detail and " | " or ", ")
end

function R:clearStatus()
    if self.shown then
        self.out:write("\r\27[K")
        self.shown = false
    end
end

function R:redraw()
    if not self.tty then return end
    local line = "[" .. self:summary() .. "]"
    local running = self:running(true)
    if running ~= "" then line = line .. " " .. running end
    if #line > self.cols - 1 then line = line:sub(1, math.max(self.cols - 4, 1)) .. "..." end
    self.out:write("\r\27[K", line)
    self.out:flush()
    self.shown = true
end

--- Text that stays (one or more whole lines): above the status line on a terminal.
function R:write(text)
    self:clearStatus()
    self.out:write(text)
    self:redraw()
    self.out:flush()
end

function R:line(text) self:write(text .. "\n") end

--- Off a terminal: the status line, now and then.
function R:beat()
    if self.tty or self.heartbeat <= 0 then return end
    local now = os.time()
    if now - self.lastBeat < self.heartbeat then return end
    self.lastBeat = now
    local running = self:running(false)
    self:line(string.format("...    %s%s", self:summary(), running ~= "" and ("; running " .. running) or ""))
end

local function label(name) return string.format("%-16s", name) end

function R:load(name)
    self:entry(name).state = "loading"
    self:redraw()
end

function R:loaded(name)
    local e = self:entry(name)
    if e.state == "loading" then e.state = "waiting" end
    self:redraw()
end

function R:count(name, n)
    self:entry(name).n = tonumber(n) or 0
end

function R:start(name, n)
    local e = self:entry(name)
    e.n, e.state = tonumber(n) or 0, "running"
    if not self.tty and e.n > 0 then self:line(string.format("start  %s %d tests", label(name), e.n)) end
    self:redraw()
end

function R:suite(name, suite)
    local e = self:entry(name)
    if not self.tty then
        self:line(string.format("       %s [%d/%d] %s", label(name), e.done, e.n or 0, suite))
        self.lastBeat = os.time()
    end
end

function R:run(name, test)
    self:entry(name).test = test
    self:redraw()
    self:beat()
end

function R:result(name, ok, test)
    local e = self:entry(name)
    e.done, e.test = e.done + 1, nil
    self.done = self.done + 1
    if not ok then
        e.failed = e.failed + 1
        self.failed = self.failed + 1
        if not self.details then self:line(string.format("FAIL   %s: %s", name, test)) end
    end
    self:redraw()
    self:beat()
end

function R:ok(name, test) self:result(name, true, test) end
function R:fail(name, test) self:result(name, false, test) end

function R:finish(name, passed, failed, cpu)
    local e = self:entry(name)
    if e.state == "done" then return end
    e.state, e.test, e.cpu = "done", nil, tonumber(cpu) or 0
    e.passed, e.failed = tonumber(passed) or 0, tonumber(failed) or e.failed
    if not e.n then e.n = e.passed + e.failed end
    self.passed = self.passed + e.passed
    self.finished = self.finished + 1
    local what = e.n == 0 and "no tests match" or string.format("%d passed, %d failed", e.passed, e.failed)
    self:line(string.format("%s %s %-22s %6s   (%s)", e.failed > 0 and "FAILED" or "done  ",
        label(name), what, seconds(e.cpu), self:summary()))
end

function R:exit(name, code)
    local e = self:entry(name)
    e.exit = tonumber(code)
    if e.state ~= "done" then
        e.state, e.broken = "broken", true
        self.finished = self.finished + 1
        self:line(string.format("BROKEN %s exited (code %s) before it finished; its log is at the end", label(name), tostring(code)))
    end
end

--- Feed one event line (see the top of this file).
function R:event(line)
    local f = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = field end
    local kind, name = f[1], f[2]
    if not name or name == "" then return false end
    if kind == "load" then self:load(name)
    elseif kind == "loaded" then self:loaded(name)
    elseif kind == "count" then self:count(name, f[3])
    elseif kind == "start" then self:start(name, f[3])
    elseif kind == "suite" then self:suite(name, f[3] or "")
    elseif kind == "run" then self:run(name, f[3] or "")
    elseif kind == "ok" then self:ok(name, f[3] or "")
    elseif kind == "fail" then self:fail(name, f[3] or "")
    elseif kind == "done" then self:finish(name, f[3], f[4], f[5])
    elseif kind == "exit" then self:exit(name, f[3])
    else return false end
    return true
end

--- Done: clears the status line; with more than one file, lists the time per file.
function R:close()
    self:clearStatus()
    local timed = {}
    for _, name in ipairs(self.order) do
        local e = self.files[name]
        if e.cpu then timed[#timed + 1] = e end
    end
    if #timed > 1 then
        table.sort(timed, function(a, b) return a.cpu > b.cpu end)
        self.out:write("CPU time per file, longest first:\n")
        for _, e in ipairs(timed) do
            self.out:write(string.format("  %7s  %-16s %d tests\n", seconds(e.cpu), e.name, e.n or 0))
        end
    end
    self.out:flush()
end

P.Reporter = R

--- run_tests.sh's side: events on stdin, the per-file logs in $OUT.
local function main(files)
    local r = P.new({ files = files })
    local jobs = tonumber(os.getenv("TEST_JOBS") or "")
    r:line(string.format("Running %d test file%s%s", #files, #files == 1 and "" or "s",
        (jobs and #files > 1) and string.format(", %d at a time", math.min(jobs, #files)) or ""))
    for line in io.stdin:lines() do
        if not r:event(line) then r:line(line) end
    end
    r:close()

    local dir = os.getenv("OUT") or "."
    local function lines(name)
        local out, fh = {}, io.open(dir .. "/" .. name .. ".log", "r")
        if fh then
            for l in fh:lines() do out[#out + 1] = l end
            fh:close()
        end
        return out
    end
    local broken, failed = false, 0
    for _, name in ipairs(r.order) do
        local e = r.files[name]
        failed = failed + e.failed
        if e.state ~= "done" then
            broken = true
            local log = lines(name)
            io.write("== ", name, " did not finish:\n")
            for i = math.max(1, #log - 19), #log do io.write(log[i], "\n") end
        elseif e.failed > 0 or os.getenv("TIMES") then
            -- Failures in full, and the TIMES=1 table; the per-file tally is in the total below.
            local log = lines(name)
            if log[#log] and log[#log]:match("^%d+ passed, %d+ failed$") then log[#log] = nil end
            io.write("== ", name, "\n")
            for _, l in ipairs(log) do io.write(l, "\n") end
        end
    end
    io.write(string.format("%d passed, %d failed in %s\n", r.passed, failed, clock(r:elapsed())))
    io.stdout:flush()
    os.exit((not broken and failed == 0) and 0 or 1)
end

if ... ~= "progress" then main({ ... }) end

return P
