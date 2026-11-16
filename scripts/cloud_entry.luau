-- the body of every engine shard. scripts/roblox_cloud_test.py writes one
-- entry per spec under tests/roblox that hands the spec's cases here, and
-- darklua bundles that entry's require graph into the one script string the
-- create-task api accepts, which is why the specs reach the engine without a
-- place upload
local run = require("@tests/roblox/run")

return function(cases: { run.Case })
  local passed, failed, report, failures = run(cases)

  print(report)

  -- a failed case is in the task's return values, not an error: the api
  -- carries them back as the task's output, so the runner counts and names
  -- every failure from there rather than from the logs, which it may cut
  return { passed = passed, failed = failed, failures = failures }
end
