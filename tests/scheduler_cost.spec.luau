local clock = require("@mod/clock")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

-- the scheduler as it stood before clocks, dev 6c84de0, verbatim: the cost
-- gate below runs the same frame through both in one process
local before = require("@tests/fixtures/scheduler_6c84de0")

local function disconnectAll(handles: { scheduler.Handle })
  for _, handle in handles do
    handle:Disconnect()
  end
end

harness.suite(function()
  harness.describe("the scheduler's cost", function()
    test("a frame of many steps is timed against calling each one", function()
      local STEPS = 1500
      local FRAMES = 200
      local ROUNDS = 5

      local total = 0
      local list = table.create(STEPS)

      for i = 1, STEPS do
        list[i] = function(deltaTime: number)
          total += deltaTime
        end
      end

      local function best(fn: () -> ())
        local fastest = math.huge

        for _ = 1, ROUNDS do
          local started = os.clock()
          fn()
          fastest = math.min(fastest, os.clock() - started)
        end

        return fastest
      end

      local bare = best(function()
        for _ = 1, FRAMES do
          for _, step in list do
            step(1 / 60)
          end
        end
      end)

      local handles = table.create(STEPS)

      for i, step in list do
        handles[i] = scheduler.add("compute", step)
      end

      local scheduled = best(function()
        for _ = 1, FRAMES do
          scheduler.compute(1 / 60)
        end
      end)

      disconnectAll(handles)
      scheduler.compute(1 / 60)

      local overhead = (scheduled - bare) / (STEPS * FRAMES)

      print(
        `scheduler: {string.format("%.1f", scheduled / FRAMES * 1e6)} us per frame of {STEPS} steps, {string.format(
          "%.1f",
          overhead * 1e9
        )} ns over a bare call each`
      )
    end)

    test("a frame of many effects is timed against before clocks", function()
      local STEPS = 1500
      local EFFECTS = 150
      local FRAMES = 100
      local ROUNDS = 9

      local total = 0
      local root = lifetime.emit(nil)
      local owners = table.create(EFFECTS)
      local handles = table.create(STEPS * 2)

      for i = 1, EFFECTS do
        owners[i] = lifetime.effect(root, 0, nil)
      end

      local function run(deltaTime: number)
        total += deltaTime
      end

      for i = 1, STEPS do
        table.insert(handles, scheduler.add("compute", run, 0, owners[i % EFFECTS + 1]))
        table.insert(handles, before.add("compute", run, 0, owners[i % EFFECTS + 1]))
      end

      local function timed(compute: (deltaTime: number) -> ())
        local started = os.clock()

        for _ = 1, FRAMES do
          compute(1 / 60)
        end

        return (os.clock() - started) / FRAMES
      end

      -- alternate rounds, each side's fastest, so the collector and a busy
      -- runner weigh on both alike
      local function against(): (number, number)
        local new, old = math.huge, math.huge

        for _ = 1, ROUNDS do
          new = math.min(new, timed(scheduler.compute))
          old = math.min(old, timed(before.compute))
        end

        return new, old
      end

      scheduler.frame(0)

      -- every case before this one leaves its clocks at 1, or this measures
      -- the scaled sweep twice
      expect(clock.uniform).toBe(true)

      local uniform, old = against()

      clock.setSpeed(root.clock, 0.5)
      scheduler.frame(0)

      local scaled = against()

      disconnectAll(handles)
      before.compute(0)
      before.stop()
      lifetime.clear(root)
      scheduler.frame(0)

      print(
        `clocks: {string.format("%.1f", uniform * 1e6)} us per frame at speed 1, {string.format("%.1f", scaled * 1e6)} us at 0.5, {string.format(
          "%.1f",
          old * 1e6
        )} us before clocks ({STEPS} steps, {EFFECTS} effects)`
      )
    end)
  end)
end)
