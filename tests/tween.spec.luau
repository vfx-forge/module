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
