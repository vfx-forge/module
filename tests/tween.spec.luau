local fs = require("@lune/fs")
local clock = require("@mod/clock")
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

harness.suite(function()
  harness.describe("tween on the scheduler", function()
    test("a waited tween given a depth follows", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        tween.wait(scope, curve.new(1, "linear"), function(_, deltaTime: number)
          if deltaTime > 0 then
            table.insert(log, "tween")
          end
        end, 0)
      end)

      local computed = scheduler.add("compute", function()
        table.insert(log, "computed")
      end)

      scheduler.frame(0.1)
      computed:Disconnect()
      lifetime.clear(emit)

      expect(log).toEqual({ "computed", "tween" })
    end)

    test("a waited tween that throws kills the effect waiting on it", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        tween.wait(scope, curve.new(1, "linear"), function(_, deltaTime: number)
          if deltaTime > 0 then
            error("boom")
          end
        end)

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

    test("a tween that throws ends alone, once, and another effect's tweens step on", function()
      local runs = 0
      local stepped = 0
      local first = lifetime.effect(lifetime.emit(nil), 0, nil)
      local second = lifetime.effect(lifetime.emit(nil), 0, nil)

      local function stepping(_: number, deltaTime: number)
        if deltaTime > 0 then
          stepped += 1
        end
      end

      tween.play(second, curve.new(1, "linear"), stepping)

      local thrower = tween.play(first, curve.new(1, "linear"), function(_, deltaTime: number)
        if deltaTime > 0 then
          runs += 1
          error("boom")
        end
      end)

      tween.play(second, curve.new(1, "linear"), stepping)

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
        scheduler.frame(0.1)
        scheduler.frame(0.1)
      end)

      lifetime.release(second)

      expect(runs).toBe(1)
      expect(stepped).toBe(6)
      expect(thrower.Connected).toBe(false)
      expect(#warnings).toBe(1)
    end)

    test("a follower's done that waits on its own thread resumes it and frames go on", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      tween.play(fx, curve.new(0.25, "linear"), function() end, 0, function()
        task.spawn(function()
          tween.wait(fx, curve.new(0.5, "linear"), nil, 0)
          table.insert(log, "resumed")
        end)
      end)

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

    test("a tween waited or a wait started on the pass's own thread fails loudly and frames go on", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      tween.play(fx, curve.new(0.25, "linear"), function() end, nil, function()
        tween.wait(fx, curve.new(0.5, "linear"))
        table.insert(log, "tween")
      end)

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

  harness.describe("what the cleanup replaced", function()
    -- each name a helper the cleanup removed, added by the task that removed it
    local GONE = {
      "fromParams",
      "tween.timer",
      "tween.after",
      "bezier_cache",
      "drivePropertyTrack",
      "getEase",
      "drawFuncMap",
      "getPointWithin",
      "getColorAtTime",
      "getColorWithEasing",
    }

    -- every source file under `dir`, by its path
    local function sources(dir: string, into: { string })
      for _, name in fs.readDir(dir) do
        local at = `{dir}/{name}`

        if fs.isDir(at) then
          sources(at, into)
        elseif string.sub(name, -5) == ".luau" then
          table.insert(into, at)
        end
      end

      return into
    end

    test("nothing in the runtime names a helper the cleanup removed", function()
      for _, at in sources("src", {}) do
        local source = fs.readFile(at)

        for _, word in GONE do
          expect(`{at} {word}: {string.find(source, word, 1, true) ~= nil}`).toBe(`{at} {word}: false`)
        end
      end
    end)

    -- the two vendored color modules are their author's, the fixtures are old
    -- code kept as it was, and this file names the spellings it looks for
    local SKIPPED = {
      ["src/mod/color/Oklab.luau"] = true,
      ["src/mod/color/sRGB.luau"] = true,
      ["tests/tween.spec.luau"] = true,
    }
    local BRITISH = {
      "colour",
      "behaviour",
      "honour",
      "neighbour",
      "metre",
      "normalise",
      "serialise",
      "optimise",
      "recognise",
      "summarise",
      "initialise",
      "prioritise",
      "parenthesise",
    }

    test("the runtime, its tests and its guides spell the US way", function()
      local files = sources("tests", sources("src", {}))

      table.insert(files, "AGENTS.md")
      table.insert(files, ".agents/skills/forge-luau-style/SKILL.md")
      table.insert(files, ".agents/skills/forge-luau-style/reference.md")

      for _, at in files do
        if SKIPPED[at] or string.find(at, "tests/fixtures/", 1, true) then
          continue
        end

        local source = string.lower(fs.readFile(at))

        for _, word in BRITISH do
          expect(`{at} {word}: {string.find(source, word, 1, true) ~= nil}`).toBe(`{at} {word}: false`)
        end
      end
    end)
  end)
end)
