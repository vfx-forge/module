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
      local refreshed = 0

      settle()

      expect(clock.uniform).toBe(true)

      lifetime.step(fx, function()
        refreshed += 1
        clock.setSpeed(fx.clock, 0.5)
        clock.refresh(fx.clock)
      end)

      lifetime.step(fx, function(deltaTime: number)
        table.insert(seen, deltaTime)
      end)

      scheduler.frame(1)

      expect(seen).toEqual({ 0.5 })
      expect(refreshed).toBe(1)

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

  harness.describe("the global clock's signals", function()
    test("each fires with its own value when that value moves, and only then", function()
      local heard = {}

      local speed = clock.speedChanged:Connect(function(value: number)
        table.insert(heard, `speed {value}`)
      end)

      local paused = clock.pausedChanged:Connect(function(value: boolean)
        table.insert(heard, `paused {value}`)
      end)

      clock.setGlobalSpeed(0.5)
      clock.setGlobalSpeed(0.5)
      clock.setGlobalPaused(true)
      clock.setGlobalPaused(true)
      clock.setGlobalSpeed(0.25)
      clock.setGlobalPaused(false)
      clock.setGlobalSpeed(1)

      speed:Disconnect()
      paused:Disconnect()

      expect(heard).toEqual({ "speed 0.5", "paused true", "speed 0.25", "paused false", "speed 1" })
    end)

    test("the speed signal fires on the frame a Global scale moves it", function()
      local heard = {}

      local connection = clock.speedChanged:Connect(function(speed: number)
        table.insert(heard, speed)
      end)

      clock.scale(clock.global, "controller", 0.5)
      expect(heard).toEqual({})

      scheduler.frame(0)
      scheduler.frame(0)
      expect(heard).toEqual({ 0.5 })

      clock.unscale(clock.global, "controller")
      scheduler.frame(0)
      expect(heard).toEqual({ 0.5, 1 })

      connection:Disconnect()
    end)

    test("a handler runs off the pass, and one that yields never holds the pass up", function()
      local inPass = nil
      local after = {}

      local connection = clock.speedChanged:Connect(function()
        inPass = scheduler.inPass()
        coroutine.yield()
      end)

      local setter = scheduler.add("compute", function()
        clock.setGlobalSpeed(0.5)
      end)

      local later = scheduler.add("compute", function()
        table.insert(after, "ran")
      end)

      scheduler.frame(0)

      expect(inPass).toBe(false)
      expect(after).toEqual({ "ran" })

      setter:Disconnect()
      later:Disconnect()
      connection:Disconnect()
      clock.setGlobalSpeed(1)
      settle()
    end)

    test("a global pause stops the wall clock too", function()
      clock.setGlobalPaused(true)
      scheduler.frame(0)

      expect(clock.factorOf(clock.global)).toBe(0)
      expect(clock.factorOf(clock.wall)).toBe(0)

      clock.setGlobalPaused(false)
      scheduler.frame(0)

      expect(clock.factorOf(clock.wall)).toBe(1)
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
  harness.describe("an authored Speed", function()
    -- a Speed row as the reader hands it over: a ramp from `from` to `to`
    -- over `duration`, or a constant when there is no duration
    local function row(from: number, to: number?, duration: number?)
      return {
        animated = duration ~= nil,
        duration = duration or 0,
        at = function(elapsed: number)
          if duration == nil or to == nil then
            return from
          end

          return from + (to - from) * math.clamp(elapsed / duration, 0, 1)
        end,
      }
    end

    test("a constant Speed scales the effect's steps from the call on", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local seen = counting(fx)

      lifetime.speed(fx, row(2))
      scheduler.frame(1)

      expect(seen.total).toBe(2)
      expect(fx.clock.halted).toBe(false)

      lifetime.clear(emit)
      settle()
    end)

    test("a Speed at or below 0 holds the effect and halts it, and never runs time backwards", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local seen = counting(fx)

      lifetime.speed(fx, row(-1))
      scheduler.frame(1)

      expect(fx.clock.speed).toBe(0)
      expect(seen.total).toBe(0)
      expect(fx.clock.halted).toBe(true)

      lifetime.clear(emit)
      settle()
    end)

    test("a ramp runs on the clock above the effect's, so it never scales itself", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      clock.setSpeed(emit.clock, 0.5)
      scheduler.frame(0)

      lifetime.speed(fx, row(1, 3, 1))

      -- half a second of the ramp per second of the frame
      scheduler.frame(1)
      expect(fx.clock.speed).toBe(2)

      scheduler.frame(1)
      expect(fx.clock.speed).toBe(3)

      lifetime.clear(emit)
      settle()
    end)

    test("a ramp is sampled ahead of the effect's later steps on the frame it moves", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      clock.setSpeed(emit.clock, 0.5)
      scheduler.frame(0)

      lifetime.speed(fx, row(1, 3, 2))

      local seen = counting(fx)

      scheduler.frame(1)

      -- the ramp stands at 1.5 after half a second of the emit's clock, and
      -- the step after it is handed the frame at 0.5 times that
      expect(seen.total).toBe(0.75)

      lifetime.clear(emit)
      settle()
    end)

    test("a ramp that ends at 0 halts once it is done, and 0 partway does not", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.speed(fx, {
        animated = true,
        duration = 2,
        at = function(elapsed: number)
          return if elapsed < 1 then 0 else (if elapsed < 2 then 1 else 0)
        end,
      })

      scheduler.frame(0.5)
      expect(fx.clock.halted).toBe(false)

      scheduler.frame(1)
      expect(fx.clock.halted).toBe(false)

      scheduler.frame(1)
      expect(fx.clock.halted).toBe(true)

      lifetime.clear(emit)
      settle()
    end)
    test("a NaN Speed is ignored like a non-number", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.speed(fx, row(0 / 0))
      expect(fx.clock.speed).toBe(1)

      lifetime.speed(fx, {
        animated = true,
        duration = 1,
        at = function(elapsed: number)
          return if elapsed == 0 then 2 else 0 / 0
        end,
      })
      expect(fx.clock.speed).toBe(2)

      scheduler.frame(0.5)
      expect(fx.clock.speed).toBe(2)

      lifetime.clear(emit)
      settle()
    end)
  end)
end)
