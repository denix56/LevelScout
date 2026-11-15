-- tests/run.lua: entry point. Run from the repo root:  ./run_tests.sh
-- run_tests.sh starts one process per test file; TEST_FILES="test_core test_data" picks the files.
assert(_VERSION == "Lua 5.1", "tests must run under Lua 5.1 (WoW's Lua), got " .. tostring(_VERSION))

local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."
package.path = root .. "/tests/?.lua;" .. package.path

local H = require("harness")
local M = require("mocks")

-- Longest first: run_tests.sh starts them in this order, so the long ones do not end up last.
local FILES = { "test_game_3", "test_game", "test_game_2", "test_game_4", "test_realdata", "test_objective",
    "test_objective_2", "test_memory", "test_surplus", "test_core", "test_search", "test_data", "test_import" }
local pick = os.getenv("TEST_FILES")
if pick and pick ~= "" then
    FILES = {}
    for f in pick:gmatch("%S+") do FILES[#FILES + 1] = f end
end
if os.getenv("LIST_FILES") then io.write(table.concat(FILES, " "), "\n"); os.exit(0) end

for _, file in ipairs(FILES) do
    local chunk = assert(loadfile(root .. "/tests/" .. file .. ".lua"))
    chunk(H, M)
end

local passed = H.run(arg and arg[1])
M.reset()
os.exit(passed and 0 or 1)
