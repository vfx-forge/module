local fs = require("@lune/fs")
local clock = require("@mod/clock")
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local curves = require("@mod/curves")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

-- the tween as it stood before the core, dev 213759c, for the cost gate
local before = require("@tests/fixtures/tween_213759c")

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

    test("a held fromParams tween that throws ends its effect, and its emit settles", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.seal(emit)

      lifetime.run(fx, function(scope: lifetime.effect)
        local body = coroutine.running()

        -- the body waits on the tween's finish, as a bezier piece does
        lifetime.hold(
          scope,
          tween.fromParams(
            LINE,
            1,
            function(): number
              error("boom")
            end,
            nil,
            function()
              task.spawn(body)
            end
          )
        )

        coroutine.yield()
        table.insert(log, "resumed")
      end)

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
        scheduler.frame(0.1)
      end)

      expect(log).toEqual({})
      expect(#warnings).toBe(1)
      expect(fx.state).toBe(lifetime.RELEASED)
      expect(emit.done).toBe(true)
    end)

    test("an unheld fromParams tween that throws leaves the effect running", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function()
        tween.fromParams(LINE, 1, function(): number
          error("boom")
        end)

        coroutine.yield()
      end)

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
        scheduler.frame(0.1)
      end)

      local running = fx.state == lifetime.RUNNING

      lifetime.release(fx)

      expect(#warnings).toBe(1)
      expect(running).toBe(true)
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
        duration = 0.5,
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

      expect(writes).toEqual({ 0, 0.25, 0.5 })
    end)

    test("a drive of a track that never moves writes once", function()
      local writes = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local track = {
        animated = false,
        duration = 0.5,
        at = function()
          return 7
        end,
      } :: any

      tween.drive(fx, track, function(v: number)
        table.insert(writes, v)
      end)

      scheduler.frame(0.25)
      lifetime.release(fx)

      expect(writes).toEqual({ 7 })
    end)
  end)

  harness.describe("tween.play", function()
    local function effect()
      local emit = lifetime.emit(nil)

      return lifetime.effect(emit, 0, nil), emit
    end

    test("a tween sees its first value at once, then one a frame, the last at its end", function()
      local seen = {}
      local done = 0
      local fx = effect()

      local handle = tween.play(
        fx,
        curve.new(0.5, "linear"),
        function(alpha: number, _, elapsed: number)
          table.insert(seen, { alpha, elapsed })
        end,
        nil,
        function()
          done += 1
        end
      )

      expect(seen).toEqual({ { 0, 0 } })

      for _ = 1, 3 do
        scheduler.frame(0.25)
      end

      lifetime.release(fx)

      expect(#seen).toBe(3)
      expect(math.abs(seen[2][1] - 0.5) < 1e-6).toBe(true)
      expect(seen[2][2]).toBe(0.25)
      expect(math.abs(seen[3][1] - 1) < 1e-6).toBe(true)
      expect(seen[3][2]).toBe(0.5)
      expect(handle.Connected).toBe(false)
      expect(done).toBe(1)
    end)

    test("a tween of no duration sees its end at once and is done", function()
      local seen = {}
      local done = 0
      local fx = effect()

      local handle = tween.play(
        fx,
        curve.new(0, "linear"),
        function(alpha: number)
          table.insert(seen, alpha)
        end,
        nil,
        function()
          done += 1
        end
      )

      scheduler.frame(0.25)
      lifetime.release(fx)

      expect(#seen).toBe(1)
      expect(math.abs(seen[1] - 1) < 1e-6).toBe(true)
      expect(handle.Connected).toBe(false)
      expect(done).toBe(1)
    end)

    test("a tween that answers false ends there and is done", function()
      local calls = 0
      local done = 0
      local fx = effect()

      tween.play(
        fx,
        curve.new(1, "linear"),
        function()
          calls += 1
          return calls < 2
        end,
        nil,
        function()
          done += 1
        end
      )

      for _ = 1, 4 do
        scheduler.frame(0.1)
      end

      lifetime.release(fx)

      expect(calls).toBe(2)
      expect(done).toBe(1)
    end)

    test("a tween whose clock halts for good ends where it stands and is done", function()
      local calls = 0
      local done = 0
      local fx = effect()

      tween.play(
        fx,
        curve.new(1, "linear"),
        function()
          calls += 1
        end,
        nil,
        function()
          done += 1
        end
      )

      scheduler.frame(0.1)
      fx.clock.halted = true
      scheduler.frame(0.1)
      scheduler.frame(0.1)

      lifetime.release(fx)

      expect(calls).toBe(3)
      expect(done).toBe(1)
    end)

    test("a clear stops a tween and it is never done", function()
      local calls = 0
      local done = 0
      local fx, emit = effect()

      local handle = tween.play(
        fx,
        curve.new(1, "linear"),
        function()
          calls += 1
        end,
        nil,
        function()
          done += 1
        end
      )

      scheduler.frame(0.1)
      lifetime.clear(emit)
      scheduler.frame(0.1)

      expect(calls).toBe(2)
      expect(handle.Connected).toBe(false)
      expect(done).toBe(0)
    end)

    test("a tween on an effect already released never plays", function()
      local calls = 0
      local fx = effect()

      lifetime.release(fx)

      local handle = tween.play(fx, curve.new(1, "linear"), function()
        calls += 1
      end)

      scheduler.frame(0.1)

      expect(calls).toBe(0)
      expect(handle.Connected).toBe(false)
    end)

    test("a tween counts its effect's clock", function()
      local elapsed = {}
      local fx = effect()

      clock.setSpeed(fx.clock, 0.5)
      clock.refresh(fx.clock)

      tween.play(fx, curve.new(1, "linear"), function(_, _, at: number)
        table.insert(elapsed, at)
      end)

      scheduler.frame(0.2)
      scheduler.frame(0.2)

      lifetime.release(fx)

      expect(elapsed).toEqual({ 0, 0.1, 0.2 })
    end)

    test("a tween computes early and one given a depth follows after the screens", function()
      local log = {}
      local fx = effect()

      tween.play(fx, curve.new(1, "linear"), function(_, deltaTime: number)
        if deltaTime > 0 then
          table.insert(log, "tween")
        end
      end)

      tween.play(fx, curve.new(1, "linear"), function(_, deltaTime: number)
        if deltaTime > 0 then
          table.insert(log, "follower")
        end
      end, 0)

      local screen = scheduler.add("screen", function()
        table.insert(log, "screen")
      end, 5)

      scheduler.frame(0.1)

      screen:Disconnect()
      lifetime.release(fx)

      expect(log).toEqual({ "tween", "screen", "follower" })
    end)

    test("a tween that throws ends its effect, and its emit settles", function()
      local fx, emit = effect()
      local calls = 0

      lifetime.seal(emit)

      lifetime.run(fx, function(scope: lifetime.effect)
        tween.play(scope, curve.new(1, "linear"), function(_, deltaTime: number)
          calls += 1

          if deltaTime > 0 then
            error("boom")
          end
        end)

        coroutine.yield()
      end)

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
        scheduler.frame(0.1)
      end)

      expect(calls).toBe(2)
      expect(#warnings).toBe(1)
      expect(fx.state).toBe(lifetime.RELEASED)
      expect(emit.done).toBe(true)
    end)
  end)

  harness.describe("tween.wait", function()
    test("a tween waited on parks its caller until it ends", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        tween.wait(scope, curve.new(0.5, "linear"))
        table.insert(log, "resumed")
      end)

      scheduler.frame(0.25)

      expect(log).toEqual({})

      scheduler.frame(0.25)

      expect(log).toEqual({ "resumed" })
      expect(fx.state).toBe(lifetime.RELEASED)
    end)

    test("a halt ends a waited tween and its caller goes on", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        tween.wait(scope, curve.new(10, "linear"))
        table.insert(log, "resumed")
      end)

      scheduler.frame(0.25)
      fx.clock.halted = true
      scheduler.frame(0.25)

      expect(log).toEqual({ "resumed" })
    end)

    test("a clear closes the caller of a waited tween", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        tween.wait(scope, curve.new(10, "linear"))
        table.insert(log, "resumed")
      end)

      scheduler.frame(0.25)
      lifetime.clear(emit)
      scheduler.frame(0.25)

      expect(log).toEqual({})
      expect(fx.state).toBe(lifetime.RELEASED)
    end)
  end)

  harness.describe("the tween core's callers", function()
    -- the effects moved onto the core so far
    local MOVED = { "particle", "sound", "spin", "beam", "mesh" }

    test("no moved effect steps through fromParams, timer or after", function()
      for _, name in MOVED do
        local source = fs.readFile(`src/effects/{name}.luau`)

        for _, word in { "tween.fromParams", "tween.timer", "tween.after" } do
          expect(`{name} {word}: {string.find(source, word, 1, true) ~= nil}`).toBe(`{name} {word}: false`)
        end
      end
    end)
  end)

  harness.describe("the tween's cost", function()
    local COUNT = 200
    local FRAMES = 60
    local ROUNDS = 5

    -- COUNT tweens of one eased row stepped FRAMES frames, in seconds
    local function timed(start: (fx: lifetime.effect, sink: (alpha: number) -> ()) -> ()): number
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local total = 0

      local function sink(alpha: number)
        total += alpha
      end

      for _ = 1, COUNT do
        start(fx, sink)
      end

      local started = os.clock()

      for _ = 1, FRAMES do
        scheduler.frame(1 / 60)
      end

      local spent = os.clock() - started

      lifetime.clear(emit)

      return spent
    end

    -- the old stepper as Studio ran it: its 64 step table, read off the
    -- fixture, where lune itself fell back to the slower Newton solve
    test("a playing tween costs no more a frame than fromParams did", function()
      local eased = curves.default()
      local fastestNew, fastestOld = math.huge, math.huge

      for _ = 1, ROUNDS do
        fastestOld = math.min(
          fastestOld,
          timed(function(fx: lifetime.effect, sink: (alpha: number) -> ())
            lifetime.hold(
              fx,
              before.fromParams(eased, 100, function(alpha: number, deltaTime: number)
                sink(alpha)
                return deltaTime
              end)
            )
          end)
        )

        fastestNew = math.min(
          fastestNew,
          timed(function(fx: lifetime.effect, sink: (alpha: number) -> ())
            tween.play(fx, curve.new(100, eased), function(alpha: number)
              sink(alpha)
            end)
          end)
        )
      end

      print(
        `  tween a frame: play {string.format("%.1f", fastestNew / COUNT / FRAMES * 1e9)} ns, fromParams {string.format(
          "%.1f",
          fastestOld / COUNT / FRAMES * 1e9
        )} ns`
      )

      expect(fastestNew <= fastestOld).toBe(true)
    end)
  end)
end)
