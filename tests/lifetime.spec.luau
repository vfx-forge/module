local lifetime = require("@mod/lifetime")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance

-- a body that parks itself until the test resumes it, so a spec never yields
local function parked(log: { string }, name: string)
  return function(fx)
    table.insert(log, `{name}:start`)
    coroutine.yield()
    table.insert(log, `{name}:after`)
  end
end

harness.suite(function()
  harness.describe("lifetime.hold and release", function()
    test("files a value by kind and releases clones before cleanups, each in reverse", function()
      local log = {}
      local folder = Instance.new("Folder")
      local a = Instance.new("Part")
      local b = Instance.new("Part")
      a.Parent = folder
      b.Parent = folder

      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.hold(fx, function()
        table.insert(log, "first")
      end)
      lifetime.hold(fx, a)
      lifetime.hold(fx, function()
        table.insert(log, `second:{#folder:GetChildren()}`)
      end)
      lifetime.hold(fx, b)

      lifetime.release(fx)

      expect(#folder:GetChildren()).toBe(0)
      expect(log).toEqual({ "second:0", "first" })
      expect(fx.state).toBe(lifetime.RELEASED)
    end)

    test("returns the held value so a call can wrap an expression", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local marker = function() end

      expect(lifetime.hold(fx, marker)).toBe(marker)
    end)

    test("a throwing cleanup does not stop the ones before it", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.hold(fx, function()
        table.insert(log, "ran")
      end)
      lifetime.hold(fx, function()
        error("boom")
      end)
      lifetime.hold(fx, function()
        table.insert(log, "also ran")
      end)

      lifetime.release(fx)

      expect(log).toEqual({ "also ran", "ran" })
    end)

    test("releasing twice is harmless", function()
      local count = 0
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.hold(fx, function()
        count += 1
      end)

      lifetime.release(fx)
      lifetime.release(fx)

      expect(count).toBe(1)
    end)

    test("holding after release disposes at once", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local part = Instance.new("Part")
      local folder = Instance.new("Folder")
      part.Parent = folder

      lifetime.release(fx)
      lifetime.hold(fx, part)

      expect(#folder:GetChildren()).toBe(0)
    end)

    test("a plain table is released like an old scope", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.hold(fx, {
        function()
          table.insert(log, "nested")
        end,
      })

      lifetime.release(fx)

      expect(log).toEqual({ "nested" })
    end)
  end)

  harness.describe("lifetime.defer", function()
    test("hears whether the release was a cancel", function()
      local seen = {}
      local emit = lifetime.emit(nil)
      local natural = lifetime.effect(emit, 0, nil)
      local cancelled = lifetime.effect(emit, 0, nil)

      lifetime.defer(natural, function(flag)
        table.insert(seen, `natural:{flag}`)
      end)
      lifetime.defer(cancelled, function(flag)
        table.insert(seen, `cancelled:{flag}`)
      end)

      lifetime.release(natural)
      lifetime.release(cancelled, true)

      expect(seen).toEqual({ "natural:false", "cancelled:true" })
    end)
  end)

  harness.describe("lifetime.lock", function()
    test("a lock is held until the effect releases", function()
      local ref = Instance.new("Part")
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local other = lifetime.effect(emit, 0, nil)

      expect(lifetime.lock(fx, ref)).toBe(false)
      expect(lifetime.lock(other, ref)).toBe(true)
      expect(lifetime.isLocked(ref)).toBe(true)

      lifetime.release(fx, true)

      expect(lifetime.isLocked(ref)).toBe(false)
      expect(lifetime.lock(other, ref)).toBe(false)

      lifetime.release(other)
    end)
  end)

  harness.describe("lifetime.run", function()
    test("runs the body inline until it yields and releases when it returns", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.hold(fx, function()
        table.insert(log, "released")
      end)

      lifetime.run(fx, parked(log, "body"))

      expect(log).toEqual({ "body:start" })
      expect(fx.state).toBe(lifetime.RUNNING)

      task.spawn(fx.thread :: thread)

      expect(log).toEqual({ "body:start", "body:after", "released" })
      expect(fx.state).toBe(lifetime.RELEASED)
    end)

    test("a body that throws still releases", function()
      local released = false
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.hold(fx, function()
        released = true
      end)

      lifetime.run(fx, function()
        error("boom")
      end)

      expect(released).toBe(true)
      expect(fx.state).toBe(lifetime.RELEASED)
    end)
  end)
end)
