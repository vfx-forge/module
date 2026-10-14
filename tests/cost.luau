local process = require("@lune/process")
local harness = require("@tests/harness")

-- the timing and allocation gates, run by hand when a change is about speed:
-- `lune run tests/cost`. They measure the process they run in (an earlier
-- spec's getfenv turns the fast library calls off, the collector sits mid
-- cycle), so they are not in tests/run, whose result judges every pull
-- request, and never in CI. Each gate prints what it measured
require("@tests/bezier_cost.spec")
require("@tests/sampling_cost.spec")
require("@tests/scheduler_cost.spec")
require("@tests/tween_cost.spec")
require("@tests/read_cost.spec")
require("@tests/sdk_sample_cost.spec")
-- last: its promise churn leaves the collector mid cycle for whatever follows
require("@tests/join_cost.spec")

process.exit(harness.run())
