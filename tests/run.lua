-- Offline test runner: lua5.2 tests/run.lua [filter]
package.path = "tests/?.lua;" .. package.path

io.stdout:setvbuf("no")
local out = io.write
local filter = arg and arg[1] or nil
local suites = { "test_miner", "test_monitor", "test_resume", "test_follower", "test_update" }

local passed, failed = 0, 0
for _, suiteName in ipairs(suites) do
  local suite = require(suiteName)
  for _, case in ipairs(suite) do
    local name = suiteName .. " :: " .. case.name
    if not filter or name:find(filter, 1, true) then
      local ok, err = xpcall(case.fn, debug.traceback)
      if ok then
        passed = passed + 1
        out("PASS  ", name, "\n")
      else
        failed = failed + 1
        out("FAIL  ", name, "\n      ", tostring(err):gsub("\n", "\n      "), "\n")
      end
    end
  end
end

out(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
