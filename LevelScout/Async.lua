-- Async.lua: runs long jobs as coroutines, a few milliseconds per frame.
-- A job is fn(checkpoint); it calls checkpoint() often, and checkpoint yields once the
-- frame's budget is spent. Results are delivered to onDone(ok, resultOrError).

local _, ns = ...

local Async = {}
ns.Async = Async

Async.BUDGET_MS = 4

local jobs = {}
local sliceStart = 0
local frame

local function now()
    return debugprofilestop()
end

local function checkpoint()
    if now() - sliceStart > Async.BUDGET_MS then
        coroutine.yield()
    end
end

--- The last finished run of each job: [name] = { cpu = ms of work, slices = frames it ran in,
--- wall = ms from start to end } (for /ls status).
Async.last = {}

local function step()
    sliceStart = now()
    local i = 1
    while i <= #jobs and now() - sliceStart <= Async.BUDGET_MS do
        local job = jobs[i]
        local t0 = now()
        local ok, result = coroutine.resume(job.co, checkpoint)
        job.cpu, job.slices = job.cpu + (now() - t0), job.slices + 1
        if coroutine.status(job.co) == "dead" then
            table.remove(jobs, i)
            Async.last[job.name] = { cpu = job.cpu, slices = job.slices, wall = now() - job.started }
            if job.onDone then job.onDone(ok, result) end
        else
            i = i + 1
        end
    end
    if #jobs == 0 and frame then frame:SetScript("OnUpdate", nil) end
end

--- Start a job. Jobs with the same name replace a still-running one.
function Async.Run(name, fn, onDone)
    for i = #jobs, 1, -1 do
        if jobs[i].name == name then table.remove(jobs, i) end
    end
    jobs[#jobs + 1] = { name = name, co = coroutine.create(fn), onDone = onDone, cpu = 0, slices = 0, started = now() }
    frame = frame or CreateFrame("Frame")
    frame:SetScript("OnUpdate", step)
end

--- Stop a running job (its onDone is not called).
function Async.Stop(name)
    for i = #jobs, 1, -1 do
        if jobs[i].name == name then table.remove(jobs, i) end
    end
end

function Async.IsRunning(name)
    for _, job in ipairs(jobs) do
        if job.name == name then return true end
    end
    return false
end
