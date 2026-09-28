local harness = require("@tests/harness")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

local function logging(log: { string }, name: string)
  return function()
    table.insert(log, name)
  end
end

local function disconnectAll(handles: { scheduler.Handle })
  for _, handle in handles do
    handle:Disconnect()
  end
end

harness.suite(function()
  harness.describe("a frame of the scheduler", function()
    test("runs the early phases, then the late ones, each late slot by depth", function()
      local log = {}
      local handles = {
        scheduler.add("follow", logging(log, "follow 2"), 2),
        scheduler.add("screen", logging(log, "screen 1"), 1),
        scheduler.add("follow", logging(log, "follow 0"), 0),
        scheduler.add("compute", logging(log, "compute")),
        scheduler.add("shake", logging(log, "shake")),
        scheduler.add("wait", logging(log, "wait")),
        scheduler.add("screen", logging(log, "screen 0"), 0),
        scheduler.add("undo", logging(log, "undo")),
      }

      scheduler.frame(0.1)
      disconnectAll(handles)

      expect(log).toEqual({ "undo", "wait", "compute", "shake", "screen 0", "screen 1", "follow 0", "follow 2" })
    end)

    test("hands every step the frame's delta", function()
      local seen = {}
      local handle = scheduler.add("compute", function(deltaTime: number)
        table.insert(seen, deltaTime)
      end)

      scheduler.frame(0.25)
      scheduler.frame(0.5)
      handle:Disconnect()

      expect(seen).toEqual({ 0.25, 0.5 })
    end)

    test("keeps the order steps were added in after one of them leaves", function()
      local log = {}
      local a = scheduler.add("compute", logging(log, "a"))
      local b = scheduler.add("compute", logging(log, "b"))
      local c = scheduler.add("compute", logging(log, "c"))
      local d = scheduler.add("compute", logging(log, "d"))

      b:Disconnect()
      scheduler.frame(0.1)
      scheduler.frame(0.1)
      disconnectAll({ a, c, d })

      expect(log).toEqual({ "a", "c", "d", "a", "c", "d" })
    end)

    test("a step disconnected by an earlier one in the same pass does not run", function()
      local log = {}
      local later: scheduler.Handle
      local first = scheduler.add("compute", function()
        table.insert(log, "first")
        later:Disconnect()
      end)

      later = scheduler.add("compute", logging(log, "later"))

      scheduler.frame(0.1)
      scheduler.frame(0.1)
      first:Disconnect()

      expect(log).toEqual({ "first", "first" })
    end)

    -- a timer that ends and wakes a body starting new tweens is the shape
    -- this pins: the new ones step from the next frame, and a follower the
    -- body starts early in the frame follows in that same frame
    test("a step added during a pass waits for its bucket's next pass", function()
      local log = {}
      local added = {}
      local spawner: scheduler.Handle

      spawner = scheduler.add("compute", function()
        spawner:Disconnect()

        table.insert(added, scheduler.add("compute", logging(log, "computed")))
        table.insert(added, scheduler.add("follow", logging(log, "followed"), 0))
      end)

      scheduler.frame(0.1)
      table.insert(log, "|")
      scheduler.frame(0.1)
      disconnectAll(added)

      expect(log).toEqual({ "followed", "|", "computed", "followed" })
    end)

    test("a step that throws is dropped and reported once, and its bucket carries on", function()
      local log = {}
      local told = {}
      local owner = {}
      local previous = scheduler.failed

      scheduler.failed = function(o: any)
        table.insert(told, o)
      end

      local before = scheduler.add("compute", logging(log, "before"))
      local thrower = scheduler.add("compute", function()
        table.insert(log, "thrower")
        error("boom")
      end, 0, owner)
      local after = scheduler.add("compute", logging(log, "after"))

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
        scheduler.frame(0.1)
      end)

      scheduler.failed = previous
      disconnectAll({ before, after })

      expect(log).toEqual({ "before", "thrower", "after", "before", "after" })
      expect(#warnings).toBe(1)
      expect(thrower.Connected).toBe(false)
      expect(#told).toBe(1)
      expect(told[1]).toBe(owner)
      expect(string.find(warnings[1], "function sweep", 1, true) ~= nil).toBe(true)
    end)

    test("a throwing step with no owner tells no one", function()
      local told = 0
      local previous = scheduler.failed

      scheduler.failed = function()
        told += 1
      end

      local thrower = scheduler.add("compute", function()
        error("boom")
      end)

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
      end)

      scheduler.failed = previous

      expect(#warnings).toBe(1)
      expect(told).toBe(0)
      expect(thrower.Connected).toBe(false)
    end)

    test("an owner whose release throws is logged once, and the pass carries on", function()
      local log = {}
      local previous = scheduler.failed

      scheduler.failed = function()
        error("release")
      end

      local thrower = scheduler.add("compute", function()
        error("boom")
      end, 0, {})
      local after = scheduler.add("compute", logging(log, "after"))

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
        scheduler.frame(0.1)
      end)

      scheduler.failed = previous
      after:Disconnect()

      expect(log).toEqual({ "after", "after" })
      expect(#warnings).toBe(2)
      expect(string.find(warnings[2], "release", 1, true) ~= nil).toBe(true)
      expect(thrower.Connected).toBe(false)
    end)

    test("a frame started inside a pass is skipped with a warning, and the pass carries on", function()
      local log = {}
      local reentered = 0
      local reentrant = scheduler.add("compute", function()
        reentered += 1
        scheduler.compute(0.1)
      end)
      local after = scheduler.add("compute", logging(log, "after"))

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
      end)

      disconnectAll({ reentrant, after })

      expect(reentered).toBe(1)
      expect(log).toEqual({ "after" })
      expect(#warnings).toBe(1)
    end)

    test("a shallower depth added during a deeper one's pass runs from the next frame, in depth order", function()
      local log = {}
      local added: scheduler.Handle? = nil
      local deep = scheduler.add("follow", function()
        table.insert(log, "deep")

        if added == nil then
          added = scheduler.add("follow", logging(log, "shallow"), 1)
        end
      end, 3)

      scheduler.frame(0.1)
      table.insert(log, "|")
      scheduler.frame(0.1)
      deep:Disconnect()

      if added then
        added:Disconnect()
      end

      expect(log).toEqual({ "deep", "|", "shallow", "deep" })
    end)
  end)

  harness.describe("the scheduler's bindings", function()
    test("a running game binds the early half at First and the late half after Last, under one suffix", function()
      local binds = {}
      local unbinds = {}
      local running = {
        IsRunning = function()
          return true
        end,
        BindToRenderStep = function(_, name: string, priority: number, fn: (deltaTime: number) -> ())
          table.insert(binds, { name = name, priority = priority, fn = fn })
        end,
        UnbindFromRenderStep = function(_, name: string)
          table.insert(unbinds, name)
        end,
      }

      scheduler.stop()
      scheduler.start(running)

      local log = {}
      local computed = scheduler.add("compute", logging(log, "computed"))
      local followed = scheduler.add("follow", logging(log, "followed"), 0)

      binds[1].fn(0.1)
      table.insert(log, "|")
      binds[2].fn(0.1)

      scheduler.stop()
      scheduler.start()
      disconnectAll({ computed, followed })

      local computeSuffix = string.match(binds[1].name, "^forge_compute_(%x+)$")
      local lateSuffix = string.match(binds[2].name, "^forge_late_(%x+)$")

      expect(#binds).toBe(2)
      expect(binds[1].priority).toBe(Enum.RenderPriority.First.Value)
      expect(binds[2].priority).toBe(Enum.RenderPriority.Last.Value + 1)
      expect(computeSuffix ~= nil and computeSuffix == lateSuffix).toBe(true)
      expect(log).toEqual({ "computed", "|", "followed" })
      expect(unbinds).toEqual({ binds[1].name, binds[2].name })
    end)

    test("the editor runs both halves in one connection, and a stopped scheduler binds nothing", function()
      local connections = {}
      local editor = {
        IsRunning = function()
          return false
        end,
        RenderStepped = {
          Connect = function(_, fn: (deltaTime: number) -> ())
            table.insert(connections, fn)

            return {
              Disconnect = function() end,
            }
          end,
        },
      }

      scheduler.stop()
      scheduler.start(editor)

      local log = {}
      local handles = {
        scheduler.add("follow", logging(log, "followed"), 0),
        scheduler.add("compute", logging(log, "computed")),
      }

      connections[1](0.1)
      scheduler.stop()
      table.insert(handles, scheduler.add("compute", logging(log, "late add")))
      scheduler.start()
      disconnectAll(handles)

      expect(#connections).toBe(1)
      expect(log).toEqual({ "computed", "followed" })
    end)
  end)

  harness.describe("the scheduler's cost", function()
    test("a frame of many steps costs little more than calling each one", function()
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

      expect(overhead < 0.15e-6).toBe(true)
    end)
  end)
end)
