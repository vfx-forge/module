local clock = require("@mod/clock")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

-- a step of the effect that adds up the time it is handed
local function counting(fx: lifetime.effect)
  local seen = { total = 0 }

  lifetime.step(fx, function(deltaTime: number)
    seen.total += deltaTime
  end)

  return seen
end

-- a frame for whatever an earlier case released to end, and one that begins
-- with every clock back at 1
local function settle()
  for _ = 1, 2 do
    scheduler.frame(0)
  end
end

harness.suite(function()
  harness.describe("the clock tree", function()
    test("a clock's factor is its parent's times its speed, from the frame after a change", function()
      local parent = clock.new(clock.global)
      local child = clock.new(parent)

      clock.setSpeed(parent, 0.5)
      clock.setSpeed(child, 3)

      expect(clock.factorOf(child)).toBe(1)

      scheduler.frame(0)

      expect(clock.factorOf(parent)).toBe(0.5)
      expect(clock.factorOf(child)).toBe(1.5)

      clock.drop(child)
      clock.drop(parent)
      scheduler.frame(0)
    end)

    test("a paused clock stands every clock below it still and resumes at its speed", function()
      local parent = clock.new(clock.global)
      local child = clock.new(parent)

      clock.setSpeed(parent, 2)
      clock.setPaused(parent, true)
      scheduler.frame(0)

      expect(clock.factorOf(parent)).toBe(0)
      expect(clock.factorOf(child)).toBe(0)

      clock.setPaused(parent, false)
      scheduler.frame(0)

      expect(clock.factorOf(child)).toBe(2)

      clock.drop(child)
      clock.drop(parent)
      scheduler.frame(0)
    end)

    test("scales multiply into the factor and one taken away leaves the rest", function()
      local c = clock.new(clock.global)

      clock.scale(c, "a", 0.5)
      clock.scale(c, "b", 0.25)
      scheduler.frame(0)

      expect(clock.factorOf(c)).toBe(0.125)

      clock.unscale(c, "a")
      scheduler.frame(0)

      expect(clock.factorOf(c)).toBe(0.25)

      clock.unscale(c, "b")
      scheduler.frame(0)

      expect(clock.factorOf(c)).toBe(1)
      expect(c.scales).toBe(nil)

      clock.drop(c)
      scheduler.frame(0)
    end)

    test("a dropped clock reads as 1 to what still hangs from it and counts for nothing", function()
      local parent = clock.new(clock.global)
      local child = clock.new(parent)

      clock.setSpeed(parent, 0.5)
      clock.setSpeed(child, 2)
      scheduler.frame(0)

      expect(clock.uniform).toBe(false)

      clock.drop(parent)
      scheduler.frame(0)

      expect(clock.factorOf(child)).toBe(2)

      clock.drop(child)
      scheduler.frame(0)

      expect(clock.uniform).toBe(true)
    end)

    test("a refresh reaches the clock's own later steps on the frame it is made", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local seen = {}

      -- off 1 before the frame, so the frame's passes scale
      clock.setSpeed(emit.clock, 0.5)
      scheduler.frame(0)

      lifetime.step(fx, function()
        clock.setSpeed(fx.clock, 0.5)
        clock.refresh(fx.clock)
      end)

      lifetime.step(fx, function(deltaTime: number)
        table.insert(seen, deltaTime)
      end)

      scheduler.frame(1)

      expect(seen).toEqual({ 0.25 })

      lifetime.clear(emit)
      scheduler.frame(0)
    end)

    test("a refresh made on a frame that began at 1 still reaches the owner's later steps", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local seen = {}

      settle()

      expect(clock.uniform).toBe(true)

      lifetime.step(fx, function()
        clock.setSpeed(fx.clock, 0.5)
        clock.refresh(fx.clock)
      end)

      lifetime.step(fx, function(deltaTime: number)
        table.insert(seen, deltaTime)
      end)

      scheduler.frame(1)

      expect(seen).toEqual({ 0.5 })

      lifetime.clear(emit)
      scheduler.frame(0)
    end)

    test("while every clock runs at 1 a step is handed the frame as it is", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local seen = counting(fx)

      settle()

      expect(clock.uniform).toBe(true)

      scheduler.frame(1 / 60)

      expect(seen.total).toBe(1 / 60)

      lifetime.clear(emit)
      scheduler.frame(0)
    end)

    test("a watcher hears each change once, with the factor it last heard", function()
      local c = clock.new(clock.global)
      local heard = {}

      local stop = clock.watch(c, function(factor: number, previous: number)
        table.insert(heard, `{previous}>{factor}`)
      end)

      clock.setSpeed(c, 2)
      scheduler.frame(0)
      scheduler.frame(0)
      clock.setPaused(c, true)
      scheduler.frame(0)

      stop()
      clock.setPaused(c, false)
      scheduler.frame(0)

      expect(heard).toEqual({ "1>2", "2>0" })

      clock.drop(c)
      scheduler.frame(0)
    end)

    test("watching a dropped clock registers nothing", function()
      local c = clock.new(clock.global)
      local heard = 0

      clock.drop(c)

      local stop = clock.watch(c, function()
        heard += 1
      end)

      expect(c.watchers).toBe(nil)

      stop()
      scheduler.frame(0)

      expect(heard).toBe(0)
    end)

    test("a watcher that stops other clocks watching does not make the frame skip one", function()
      local a = clock.new(clock.global)
      local b = clock.new(clock.global)
      local c = clock.new(clock.global)
      local heard = {}

      local stopA = clock.watch(a, function()
        table.insert(heard, "a")
      end)

      local stopB
      stopB = clock.watch(b, function()
        table.insert(heard, "b")
        stopA()
        stopB()
      end)

      clock.watch(c, function()
        table.insert(heard, "c")
      end)

      clock.setSpeed(a, 2)
      clock.setSpeed(b, 2)
      clock.setSpeed(c, 2)
      scheduler.frame(0)

      expect(heard).toEqual({ "a", "b", "c" })

      clock.drop(a)
      clock.drop(b)
      clock.drop(c)
      scheduler.frame(0)
    end)

    test("a watcher that throws warns once and the frame carries on", function()
      local c = clock.new(clock.global)
      local other = clock.new(clock.global)
      local heard = 0

      clock.watch(c, function()
        error("boom")
      end)

      clock.watch(other, function()
        heard += 1
      end)

      clock.setSpeed(c, 2)
      clock.setSpeed(other, 2)

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0)
      end)

      expect(#warnings).toBe(1)
      expect(heard).toBe(1)

      clock.drop(c)
      clock.drop(other)
      scheduler.frame(0)
    end)
  end)

  harness.describe("effects on their clocks", function()
    test("an effect's steps are handed the frame scaled by its emit's clock", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local seen = counting(fx)

      clock.setSpeed(emit.clock, 0.5)
      scheduler.frame(1)

      expect(seen.total).toBe(0.5)

      lifetime.clear(emit)
      scheduler.frame(0)
    end)

    test("a step with no owner keeps real time while effects around it slow", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local seen = counting(fx)
      local real = 0

      local handle = scheduler.add("compute", function(deltaTime: number)
        real += deltaTime
      end)

      clock.setSpeed(emit.clock, 0.25)
      scheduler.frame(1)

      expect(seen.total).toBe(0.25)
      expect(real).toBe(1)

      handle:Disconnect()
      lifetime.clear(emit)
      scheduler.frame(0)
    end)

    test("a wait at half speed takes twice the frames", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      clock.setSpeed(emit.clock, 0.5)
      scheduler.frame(0)

      lifetime.run(fx, function(scope: lifetime.effect)
        lifetime.wait(scope, 1)
        table.insert(log, "waited")
      end)

      scheduler.frame(1)
      expect(log).toEqual({})

      scheduler.frame(1)
      expect(log).toEqual({ "waited" })

      lifetime.clear(emit)
    end)

    test("a paused emit's wait stands still, and resumed runs only what was left", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        lifetime.wait(scope, 1)
        table.insert(log, "waited")
      end)

      scheduler.frame(0.5)

      clock.setPaused(emit.clock, true)
      scheduler.frame(0)

      for _ = 1, 10 do
        scheduler.frame(1)
      end

      expect(log).toEqual({})

      clock.setPaused(emit.clock, false)
      scheduler.frame(0.25)
      expect(log).toEqual({})

      scheduler.frame(0.25)
      expect(log).toEqual({ "waited" })

      lifetime.clear(emit)
    end)

    test("a pause made inside a step reaches the effect from the next frame", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local seen = {}

      lifetime.step(fx, function(deltaTime: number)
        table.insert(seen, deltaTime)
        clock.setPaused(emit.clock, true)
      end)

      scheduler.frame(1)
      scheduler.frame(1)

      expect(seen).toEqual({ 1, 0 })

      lifetime.clear(emit)
      scheduler.frame(0)
    end)

    test("a child emit's clock hangs from the clock it is handed", function()
      local root = lifetime.emit(nil)
      local starter = lifetime.effect(root, 0, nil)
      local child = lifetime.emit(root, starter.clock)
      local fx = lifetime.effect(child, 1, nil)
      local seen = counting(fx)

      clock.setSpeed(starter.clock, 0.5)
      clock.setSpeed(root.clock, 0.5)
      scheduler.frame(0)
      scheduler.frame(1)

      expect(seen.total).toBe(0.25)

      lifetime.clear(root)
      scheduler.frame(0)
    end)

    test("a released effect's clock and its sealed emit's count for nothing", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      clock.setSpeed(emit.clock, 0.5)
      clock.setSpeed(fx.clock, 3)
      scheduler.frame(0)

      expect(clock.uniform).toBe(false)

      lifetime.run(fx, function() end)
      lifetime.seal(emit)
      scheduler.frame(0)

      expect(emit.done).toBe(true)
      expect(clock.uniform).toBe(true)
    end)
  end)
end)
