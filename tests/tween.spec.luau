local tween = require("@mod/tween")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

-- getEase interpolates through the engine's vector Lerp, which this host does
-- not have, so the curve cache is seeded with a straight line under a key no
-- effect uses
local LINE = "spec:line"

tween.bezier_cache[LINE] = {
  getEase = function(_, t: number)
    return { y = 1 - t }
  end,
} :: any

local function counting(_: any, deltaTime: number)
  return deltaTime
end

local function ticking(deltaTime: number)
  return deltaTime
end

harness.suite(function()
  harness.describe("tween on the scheduler", function()
    test("a tween computes early and a follower steps after the screens", function()
      local log = {}
      local tweened = tween.fromParams(LINE, 1, function(_, deltaTime: number)
        table.insert(log, "tween")
        return deltaTime
      end)
      local followed = tween.fromParams(LINE, 1, function(_, deltaTime: number)
        table.insert(log, "follower")
        return deltaTime
      end, nil, nil, nil, 0)
      local screen = scheduler.add("screen", function()
        table.insert(log, "screen")
      end, 5)

      scheduler.frame(0.1)

      tweened:Disconnect()
      followed:Disconnect()
      screen:Disconnect()

      expect(log).toEqual({ "tween", "screen", "follower" })
    end)

    test("a tween ends on its own and one awaiting another runs until that one ends", function()
      local ended = false
      local speed = tween.fromParams(LINE, 1, counting)
      local held = tween.fromParams(LINE, 0.25, counting, speed, function()
        ended = true
      end)

      for _ = 1, 3 do
        scheduler.frame(0.25)
      end

      expect(speed.Connected).toBe(true)
      expect(held.Connected).toBe(true)
      expect(ended).toBe(false)

      scheduler.frame(0.25)

      expect(speed.Connected).toBe(false)
      expect(held.Connected).toBe(false)
      expect(ended).toBe(true)
    end)

    test("a timer resumes its caller the frame after its time is counted", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        tween.timer(0.5, ticking, nil, scope)
        table.insert(log, "done")
      end)

      scheduler.frame(0.25)
      scheduler.frame(0.25)

      expect(log).toEqual({})

      scheduler.frame(0.25)

      expect(log).toEqual({ "done" })
      expect(fx.state).toBe(lifetime.RELEASED)
    end)

    test("a timer given a depth follows", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        tween.timer(1, function(deltaTime: number)
          table.insert(log, "timer")
          return deltaTime
        end, nil, scope, 0)
      end)

      local computed = scheduler.add("compute", function()
        table.insert(log, "computed")
      end)

      scheduler.frame(0.1)
      computed:Disconnect()
      lifetime.clear(emit)

      expect(log).toEqual({ "computed", "timer" })
    end)

    test("a timer whose counter throws kills the effect holding it", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        tween.timer(1, function(): number
          error("boom")
        end, nil, scope)

        table.insert(log, "resumed")
      end)

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
        scheduler.frame(0.1)
      end)

      expect(log).toEqual({})
      expect(#warnings).toBe(1)
      expect(fx.state).toBe(lifetime.RELEASED)
    end)

    test("a fromParams tween that throws ends alone, once, and its neighbours step on", function()
      local runs = 0
      local stepped = 0

      local function stepping(_: any, deltaTime: number)
        stepped += 1
        return deltaTime
      end

      local before = tween.fromParams(LINE, 1, stepping)
      local thrower = tween.fromParams(LINE, 1, function(): number
        runs += 1
        error("boom")
      end)
      local after = tween.fromParams(LINE, 1, stepping)

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
        scheduler.frame(0.1)
        scheduler.frame(0.1)
      end)

      before:Disconnect()
      after:Disconnect()

      expect(runs).toBe(1)
      expect(stepped).toBe(6)
      expect(thrower.Connected).toBe(false)
      expect(#warnings).toBe(1)
    end)

    test("an after whose effect is released first never finishes", function()
      local finished = false
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      tween.after(0.25, ticking, function()
        finished = true
      end, fx)

      lifetime.release(fx)

      scheduler.frame(0.25)
      scheduler.frame(0.25)

      expect(finished).toBe(false)
    end)

    test("a follower's finish that starts a timer on its own thread resumes it and frames go on", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.hold(
        fx,
        tween.fromParams(LINE, 0.25, counting, nil, function()
          task.spawn(function()
            tween.timer(0.5, ticking, nil, fx, 0)
            table.insert(log, "resumed")
          end)
        end, true, 0)
      )

      local frames = 0
      local counted = scheduler.add("compute", function()
        frames += 1
      end)

      local warnings = harness.captureWarnings(function()
        for _ = 1, 5 do
          scheduler.frame(0.25)
        end
      end)

      counted:Disconnect()
      lifetime.clear(emit)

      expect(log).toEqual({ "resumed" })
      expect(frames).toBe(5)
      expect(#warnings).toBe(0)
    end)

    test("a timer or a wait started on the pass's own thread fails loudly and frames go on", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      tween.fromParams(LINE, 0.25, counting, nil, function()
        tween.timer(0.5, ticking, nil, fx)
        table.insert(log, "timer")
      end, true)

      scheduler.add("compute", function()
        lifetime.wait(fx, 0.5)
        table.insert(log, "wait")
      end)

      local frames = 0
      local counted = scheduler.add("compute", function()
        frames += 1
      end)

      local warnings = harness.captureWarnings(function()
        for _ = 1, 3 do
          scheduler.frame(0.25)
        end
      end)

      counted:Disconnect()
      lifetime.clear(emit)

      local told = 0

      for _, warning in warnings do
        if string.find(warning, "start it in task.spawn", 1, true) then
          told += 1
        end
      end

      expect(log).toEqual({})
      expect(frames).toBe(3)
      expect(told).toBe(2)
    end)

    test("held tweens awaiting a speed tween stop on a clear and never finish", function()
      local stepped = 0
      local finished = false
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      local function stepping(_: any, deltaTime: number)
        stepped += 1
        return deltaTime
      end

      local function finish()
        finished = true
      end

      local speed = lifetime.hold(fx, tween.fromParams(LINE, 1, counting))
      local dissipation = lifetime.hold(fx, tween.fromParams(LINE, 0.25, stepping, speed, finish, true, 0))
      local lingering = lifetime.hold(fx, tween.fromParams(LINE, 0.25, stepping, speed, finish, true, 0))

      scheduler.frame(0.1)
      lifetime.clear(emit)
      scheduler.frame(0.1)
      scheduler.frame(0.1)

      expect(stepped).toBe(2)
      expect(finished).toBe(false)
      expect(speed.Connected).toBe(false)
      expect(dissipation.Connected).toBe(false)
      expect(lingering.Connected).toBe(false)
    end)

    test("a drive writes its first value at once and lands on its last", function()
      local writes = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local track = {
        animated = true,
        span = 0.5,
        at = function(t: number)
          return t
        end,
      } :: any

      tween.drive(fx, track, function(v: number)
        table.insert(writes, v)
      end)

      for _ = 1, 4 do
        scheduler.frame(0.25)
      end

      lifetime.release(fx)

      expect(writes).toEqual({ 0, 0, 0.25, 0.5, 0.5 })
    end)
  end)
end)
