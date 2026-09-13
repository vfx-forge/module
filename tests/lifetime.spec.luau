local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance

-- a body that parks itself until the test resumes it, so a spec never yields
local function parked(log: { string }, name: string)
  return function(_: lifetime.effect)
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

    -- lune has no RBXScriptConnection, so only the thread half of the threads
    -- list is reachable here
    test("a suspended thread is closed when the effect releases", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local worker = coroutine.create(function()
        coroutine.yield()
      end)

      task.spawn(worker)
      lifetime.hold(fx, worker)

      expect(coroutine.status(worker)).toBe("suspended")

      lifetime.release(fx)

      expect(coroutine.status(worker)).toBe("dead")
    end)

    test("an effect holding its own thread releases without closing itself", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(self: lifetime.effect)
        lifetime.hold(self, coroutine.running())
      end)

      expect(fx.state).toBe(lifetime.RELEASED)
      expect(coroutine.status(fx.thread :: thread)).toBe("dead")
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

    test("a released effect is told the lock is taken and takes none", function()
      local ref = Instance.new("Part")
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.release(fx)

      expect(lifetime.lock(fx, ref)).toBe(true)
      expect(lifetime.isLocked(ref)).toBe(false)
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

    test("a released effect never starts a body", function()
      local ran = false
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.release(fx)

      lifetime.run(fx, function()
        ran = true
      end)

      expect(ran).toBe(false)
      expect(fx.thread).toBe(nil)
    end)
  end)

  harness.describe("emit tree", function()
    test("an emit is done once sealed with nothing pending", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.seal(emit)
      expect(emit.done).toBe(false)

      lifetime.release(fx)
      expect(emit.done).toBe(true)
      expect(emit.pending).toBe(0)
    end)

    test("a child emit keeps its parent pending until the child is done", function()
      local parent = lifetime.emit(nil)
      local pfx = lifetime.effect(parent, 0, nil)
      lifetime.seal(parent)

      local child = lifetime.emit(parent)
      local cfx = lifetime.effect(child, 1, nil)
      lifetime.seal(child)

      lifetime.release(pfx)
      expect(parent.done).toBe(false)

      lifetime.release(cfx)
      expect(child.done).toBe(true)
      expect(parent.done).toBe(true)
      expect(#parent.children).toBe(0)
    end)

    test("await returns at once when nothing is pending and wakes when the last effect ends", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      lifetime.seal(emit)

      local waiter = coroutine.create(function()
        lifetime.await(emit)
        table.insert(log, "woke")
      end)
      task.spawn(waiter)

      expect(log).toEqual({})

      lifetime.release(fx)
      expect(log).toEqual({ "woke" })

      local empty = lifetime.emit(nil)
      lifetime.seal(empty)
      lifetime.await(empty)
      table.insert(log, "immediate")
      expect(log).toEqual({ "woke", "immediate" })
    end)
  end)

  harness.describe("lifetime.stop", function()
    test("closes a parked thread down the tree and releases nothing until the clear", function()
      local log = {}
      local parent = lifetime.emit(nil)
      local child = lifetime.emit(parent)
      local cfx = lifetime.effect(child, 1, nil)
      lifetime.seal(parent)
      lifetime.seal(child)

      lifetime.run(cfx, function(scope)
        lifetime.hold(scope, function()
          table.insert(log, "released")
        end)
        coroutine.yield()
      end)

      lifetime.stop(parent)

      expect(coroutine.status(cfx.thread :: thread)).toBe("dead")
      expect(cfx.state).toBe(lifetime.STOPPED)
      expect(log).toEqual({})
      expect(parent.done).toBe(false)

      lifetime.clear(parent)

      expect(log).toEqual({ "released" })
      expect(cfx.state).toBe(lifetime.RELEASED)
      expect(parent.done).toBe(true)
    end)
  end)

  harness.describe("lifetime.clear", function()
    test("closes a parked effect, releases what it acquired, and never runs the code after its yield", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      lifetime.seal(emit)

      lifetime.run(fx, function(scope)
        lifetime.hold(scope, function()
          table.insert(log, "released")
        end)
        coroutine.yield()
        table.insert(log, "after")
      end)

      lifetime.clear(emit)

      expect(log).toEqual({ "released" })
      expect(coroutine.status(fx.thread :: thread)).toBe("dead")
      expect(fx.cancelled).toBe(true)
      expect(emit.done).toBe(true)

      lifetime.clear(emit)
      expect(log).toEqual({ "released" })
    end)

    test("releases children before parents", function()
      local log = {}
      local parent = lifetime.emit(nil)
      local pfx = lifetime.effect(parent, 0, nil)
      lifetime.seal(parent)
      local child = lifetime.emit(parent)
      local cfx = lifetime.effect(child, 1, nil)
      lifetime.seal(child)

      lifetime.hold(pfx, function()
        table.insert(log, "parent")
      end)
      lifetime.hold(cfx, function()
        table.insert(log, "child")
      end)

      lifetime.clear(parent)

      expect(log).toEqual({ "child", "parent" })
      expect(parent.done).toBe(true)
    end)

    test("wakes a waiter once, after the whole subtree is released", function()
      local log = {}
      local parent = lifetime.emit(nil)
      local pfx = lifetime.effect(parent, 0, nil)
      lifetime.seal(parent)
      local child = lifetime.emit(parent)
      local cfx = lifetime.effect(child, 1, nil)
      lifetime.seal(child)

      lifetime.hold(pfx, function()
        table.insert(log, "parent released")
      end)
      lifetime.hold(cfx, function()
        table.insert(log, "child released")
      end)

      task.spawn(function()
        lifetime.await(child)
        table.insert(log, "woke")
      end)

      lifetime.clear(parent)

      expect(log).toEqual({ "child released", "parent released", "woke" })
    end)

    test("clear finishes a child that was never sealed", function()
      local log = {}
      local parent = lifetime.emit(nil)
      local child = lifetime.emit(parent)
      lifetime.seal(parent)

      local cfx = lifetime.effect(child, 1, nil)

      lifetime.run(cfx, function(scope)
        lifetime.hold(scope, function()
          table.insert(log, "released")
        end)
        coroutine.yield()
      end)

      task.spawn(function()
        lifetime.await(parent)
        table.insert(log, "woke")
      end)

      lifetime.clear(parent)

      expect(log).toEqual({ "released", "woke" })
      expect(parent.pending).toBe(0)
      expect(parent.done).toBe(true)
      expect(#parent.children).toBe(0)
    end)

    test("an effect that clears its own emit stops running", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      lifetime.seal(emit)

      lifetime.run(fx, function(scope)
        lifetime.hold(scope, function()
          table.insert(log, "released")
        end)
        lifetime.clear(emit)
        table.insert(log, "after")
      end)

      expect(log).toEqual({ "released" })
      expect(fx.state).toBe(lifetime.RELEASED)
      expect(coroutine.status(fx.thread :: thread)).toBe("suspended")
    end)

    test("marks the whole subtree cleared, where an emit that ends on its own is not", function()
      local parent = lifetime.emit(nil)
      local child = lifetime.emit(parent)
      local cfx = lifetime.effect(child, 1, nil)
      lifetime.seal(parent)
      lifetime.seal(child)

      local natural = lifetime.emit(nil)
      local nfx = lifetime.effect(natural, 0, nil)
      lifetime.seal(natural)
      lifetime.release(nfx)

      expect(parent.cleared).toBe(false)

      lifetime.clear(parent)

      expect(parent.cleared).toBe(true)
      expect(child.cleared).toBe(true)
      expect(cfx.state).toBe(lifetime.RELEASED)
      expect(natural.done).toBe(true)
      expect(natural.cleared).toBe(false)
    end)
  end)
end)
