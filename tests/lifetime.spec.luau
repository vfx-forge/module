local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
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

    test("holding a table or a thread after release disposes both at once", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local worker = coroutine.create(function()
        coroutine.yield()
      end)

      task.spawn(worker)
      lifetime.release(fx)

      lifetime.hold(fx, {
        function()
          table.insert(log, "nested")
        end,
      })

      lifetime.hold(fx, worker)

      expect(log).toEqual({ "nested" })
      expect(coroutine.status(worker)).toBe("dead")
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

      local warnings = harness.captureWarnings(function()
        lifetime.run(fx, function(self: lifetime.effect)
          lifetime.hold(self, coroutine.running())
        end)
      end)

      -- closing the running coroutine throws, and the release only survives it
      -- through the restartable pcall, so a quiet release is the whole point
      expect(warnings).toEqual({})
      expect(fx.state).toBe(lifetime.RELEASED)
      expect(coroutine.status(fx.thread :: thread)).toBe("dead")
    end)
  end)

  harness.describe("lifetime.releasePlain", function()
    test("empties a plain scope from the back, each entry out before it runs", function()
      local log = {}
      local folder = Instance.new("Folder")
      local part = Instance.new("Part")
      part.Parent = folder

      local scope = {
        function()
          table.insert(log, "first")
        end,

        part,

        function()
          table.insert(log, `second:{#folder:GetChildren()}`)
        end,
      }

      lifetime.releasePlain(scope)

      expect(log).toEqual({ "second:1", "first" })
      expect(#folder:GetChildren()).toBe(0)
      expect(#scope).toBe(0)
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

    -- the root keeps the sealed flag the caller left it with, which is what
    -- keeps a never-sealed token usable after a cancel
    test("an unsealed root is still open for the next effect after a clear", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.hold(fx, function()
        table.insert(log, "first")
      end)

      lifetime.clear(emit)

      expect(log).toEqual({ "first" })
      expect(emit.sealed).toBe(false)
      expect(emit.done).toBe(false)

      local revived = lifetime.effect(emit, 0, nil)

      lifetime.run(revived, parked(log, "second"))

      task.spawn(function()
        lifetime.await(emit)
        table.insert(log, "woke")
      end)

      expect(log).toEqual({ "first", "second:start" })

      task.spawn(revived.thread :: thread)

      expect(log).toEqual({ "first", "second:start", "second:after", "woke" })
      expect(emit.pending).toBe(0)
      expect(emit.done).toBe(false)
    end)
  end)

  harness.describe("lifetime.step, lifetime.wait and lifetime.kill", function()
    test("a step runs every frame until its effect is released", function()
      local ran = 0
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      local handle = lifetime.step(fx, function()
        ran += 1
      end)

      scheduler.frame(0.1)
      scheduler.frame(0.1)
      lifetime.release(fx)
      scheduler.frame(0.1)

      expect(ran).toBe(2)
      expect(handle.Connected).toBe(false)
    end)

    test("a follower steps at its effect's depth, after shallower ones", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local deep = lifetime.effect(emit, 3, nil)
      local shallow = lifetime.effect(emit, 1, nil)

      lifetime.step(deep, function()
        table.insert(log, "deep")
      end, "follow")

      lifetime.step(shallow, function()
        table.insert(log, "shallow")
      end, "follow")

      scheduler.frame(0.1)
      lifetime.release(deep)
      lifetime.release(shallow)

      expect(log).toEqual({ "shallow", "deep" })
    end)

    test("a step on a released effect never runs", function()
      local ran = false
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.release(fx)

      local handle = lifetime.step(fx, function()
        ran = true
      end)

      scheduler.frame(0.1)

      expect(ran).toBe(false)
      expect(handle.Connected).toBe(false)
    end)

    test("holding a handle disconnects it on release", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local handle = scheduler.add("compute", function() end)

      lifetime.hold(fx, handle)
      lifetime.release(fx)

      expect(handle.Connected).toBe(false)
    end)

    test("a wait resumes its thread once the frames add up to it and says how long it took", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        table.insert(log, lifetime.wait(scope, 1))
      end)

      for _ = 1, 3 do
        scheduler.frame(0.25)
      end

      expect(#log).toBe(0)

      scheduler.frame(0.25)

      expect(log).toEqual({ 1 })
      expect(fx.state).toBe(lifetime.RELEASED)
    end)

    test("a wait resumes before the steps of its frame", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        lifetime.step(scope, function()
          table.insert(log, "step")
        end)

        lifetime.wait(scope, 0.1)
        table.insert(log, "resumed")
        coroutine.yield()
      end)

      scheduler.frame(0.1)
      lifetime.clear(emit)

      expect(log).toEqual({ "resumed", "step" })
    end)

    test("a wait of no usable length does not yield", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        table.insert(log, lifetime.wait(scope, 0))
        table.insert(log, lifetime.wait(scope, -1))
        table.insert(log, lifetime.wait(scope, 0 / 0))
      end)

      expect(log).toEqual({ 0, 0, 0 })
      expect(fx.state).toBe(lifetime.RELEASED)
    end)

    -- a second thread of the same effect, the way a piece's promise waits
    test("no wait of an effect cleared under it resumes, on any of its threads", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local worker: thread? = nil

      lifetime.run(fx, function(scope: lifetime.effect)
        local piece = coroutine.create(function()
          lifetime.wait(scope, 0.5)
          table.insert(log, "piece")
        end)

        worker = piece
        task.spawn(piece)

        lifetime.wait(scope, 0.5)
        table.insert(log, "body")
      end)

      lifetime.clear(emit)
      scheduler.frame(1)
      scheduler.frame(1)

      expect(log).toEqual({})
      expect(coroutine.status(worker :: thread)).toBe("suspended")
    end)

    test("a step that throws kills its effect: cancelled, its body closed and its emit settled", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        lifetime.defer(scope, function(cancelled: boolean)
          table.insert(log, `cancelled:{cancelled}`)
        end)

        lifetime.step(scope, function()
          error("boom")
        end)

        coroutine.yield()
        table.insert(log, "resumed")
      end)

      lifetime.seal(emit)

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
        scheduler.frame(0.1)
      end)

      expect(log).toEqual({ "cancelled:true" })
      expect(#warnings).toBe(1)
      expect(fx.state).toBe(lifetime.RELEASED)
      expect(emit.done).toBe(true)
      expect(coroutine.status(fx.thread :: thread)).toBe("dead")
    end)

    test("an await inside a step is refused rather than left to yield the pass", function()
      local emit = lifetime.emit(nil)
      local after = false

      local handle = scheduler.add("compute", function()
        lifetime.await(emit)
        after = true
      end)

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
      end)

      handle:Disconnect()

      expect(after).toBe(false)
      expect(string.find(warnings[1], "lifetime.await yields", 1, true) ~= nil).toBe(true)
    end)

    test("a clear from inside a step completes and the rest of the frame runs", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.step(fx, function()
        table.insert(log, "clearing")
        lifetime.clear(emit)
      end)

      local after = scheduler.add("compute", function()
        table.insert(log, "after")
      end)

      scheduler.frame(0.1)
      scheduler.frame(0.1)
      after:Disconnect()

      expect(log).toEqual({ "clearing", "after", "after" })
      expect(fx.state).toBe(lifetime.RELEASED)
    end)
  end)

  harness.describe("lifetime.join", function()
    test("the waiter wakes once the last thing counted in is out, and not before", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local first, second

      lifetime.run(fx, function(scope: lifetime.effect)
        local outstanding = lifetime.join(scope)
        first = lifetime.add(outstanding)
        second = lifetime.add(outstanding)

        lifetime.awaitJoin(outstanding)
        table.insert(log, "joined")
      end)

      first()
      expect(log).toEqual({})

      second()
      expect(log).toEqual({ "joined" })
      expect(fx.state).toBe(lifetime.RELEASED)
    end)

    test("counting a thing out twice counts it once", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local first, second

      lifetime.run(fx, function(scope: lifetime.effect)
        local outstanding = lifetime.join(scope)
        first = lifetime.add(outstanding)
        second = lifetime.add(outstanding)

        lifetime.awaitJoin(outstanding)
        table.insert(log, "joined")
      end)

      first()
      first()
      expect(log).toEqual({})

      second()
      expect(log).toEqual({ "joined" })
    end)

    test("a thing counted in while the body waits is waited for too", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local outstanding, first

      lifetime.run(fx, function(scope: lifetime.effect)
        outstanding = lifetime.join(scope)
        first = lifetime.add(outstanding)

        lifetime.awaitJoin(outstanding)
        table.insert(log, "joined")
      end)

      local late = lifetime.add(outstanding)

      first()
      expect(log).toEqual({})

      late()
      expect(log).toEqual({ "joined" })
    end)

    test("a join with nothing counted in does not yield", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        lifetime.awaitJoin(lifetime.join(scope))
        table.insert(log, "joined")
      end)

      expect(log).toEqual({ "joined" })
      expect(fx.state).toBe(lifetime.RELEASED)
    end)

    test("an included child emit counts until it is done, and a done one counts nothing", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local child = lifetime.emit(emit)
      local cfx = lifetime.effect(child, 1, nil)
      lifetime.seal(child)

      local finished = lifetime.emit(emit)
      lifetime.seal(finished)

      lifetime.run(fx, function(scope: lifetime.effect)
        local children = lifetime.join(scope)
        lifetime.include(children, child)
        lifetime.include(children, finished)

        expect(children.count).toBe(1)

        lifetime.awaitJoin(children)
        table.insert(log, "joined")
      end)

      expect(log).toEqual({})

      lifetime.release(cfx)
      expect(log).toEqual({ "joined" })
      expect(child.joins).toBe(nil)
    end)

    test("a child emit cleared under the join counts out as well", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local child = lifetime.emit(emit)
      lifetime.effect(child, 1, nil)
      lifetime.seal(child)

      lifetime.run(fx, function(scope: lifetime.effect)
        local children = lifetime.join(scope)
        lifetime.include(children, child)

        lifetime.awaitJoin(children)
        table.insert(log, "joined")
      end)

      lifetime.clear(child)
      expect(log).toEqual({ "joined" })
    end)

    test("the waiter is resumed off the pass when a step counts the last thing out", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      lifetime.run(fx, function(scope: lifetime.effect)
        local outstanding = lifetime.join(scope)
        local done = lifetime.add(outstanding)

        lifetime.step(scope, function()
          done()
        end)

        lifetime.awaitJoin(outstanding)
        table.insert(log, `in pass:{scheduler.inPass()}`)
      end)

      scheduler.frame(0.1)

      expect(log).toEqual({ "in pass:false" })
      expect(fx.state).toBe(lifetime.RELEASED)
    end)

    test("a spawned piece that throws is logged once and counted out, and its sibling keeps running", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      local warnings = harness.captureWarnings(function()
        lifetime.run(fx, function(scope: lifetime.effect)
          local outstanding = lifetime.join(scope)

          lifetime.spawn(outstanding, function()
            error("boom")
          end)

          lifetime.spawn(outstanding, function(name: string)
            lifetime.wait(scope, 0.5)
            table.insert(log, name)
          end, "sibling")

          lifetime.awaitJoin(outstanding)
          table.insert(log, "joined")
        end)

        scheduler.frame(0.5)
      end)

      expect(#warnings).toBe(1)
      expect(string.find(warnings[1], "a piece failed", 1, true) ~= nil).toBe(true)
      expect(log).toEqual({ "sibling", "joined" })
      expect(fx.state).toBe(lifetime.RELEASED)
    end)

    test("a clear closes a spawned piece parked in a wait, which never resumes", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      lifetime.seal(emit)

      local worker: thread? = nil

      lifetime.run(fx, function(scope: lifetime.effect)
        local outstanding = lifetime.join(scope)

        lifetime.spawn(outstanding, function()
          worker = coroutine.running()
          lifetime.wait(scope, 0.5)
          table.insert(log, "piece")
        end)

        lifetime.awaitJoin(outstanding)
        table.insert(log, "joined")
      end)

      lifetime.clear(emit)
      scheduler.frame(1)

      expect(log).toEqual({})
      expect(coroutine.status(worker :: thread)).toBe("dead")
      expect(emit.done).toBe(true)
    end)

    test("a piece that clears its own emit stops there and the clear completes", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      lifetime.seal(emit)

      local piece: thread? = nil

      lifetime.run(fx, function(scope: lifetime.effect)
        local outstanding = lifetime.join(scope)

        lifetime.hold(scope, function()
          table.insert(log, "released")
        end)

        lifetime.spawn(outstanding, function()
          piece = coroutine.running()
          lifetime.clear(emit)
          table.insert(log, "piece after")
        end)

        table.insert(log, "body after")
        lifetime.awaitJoin(outstanding)
        table.insert(log, "joined")
      end)

      expect(log).toEqual({ "released" })
      expect(fx.state).toBe(lifetime.RELEASED)
      expect(emit.done).toBe(true)
      expect(coroutine.status(fx.thread :: thread)).toBe("dead")
      expect(coroutine.status(piece :: thread)).toBe("dead")
    end)

    test("a piece's own piece that clears the emit stops every thread it was started from", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      lifetime.seal(emit)

      local outer: thread? = nil
      local inner: thread? = nil

      lifetime.run(fx, function(scope: lifetime.effect)
        local outstanding = lifetime.join(scope)

        lifetime.spawn(outstanding, function()
          outer = coroutine.running()

          lifetime.spawn(outstanding, function()
            inner = coroutine.running()
            lifetime.clear(emit)
            table.insert(log, "inner after")
          end)

          table.insert(log, "outer after")
        end)

        table.insert(log, "body after")
        lifetime.awaitJoin(outstanding)
      end)

      expect(log).toEqual({})
      expect(emit.done).toBe(true)
      expect(coroutine.status(fx.thread :: thread)).toBe("dead")
      expect(coroutine.status(outer :: thread)).toBe("dead")
      expect(coroutine.status(inner :: thread)).toBe("dead")
    end)

    test("a spawn on an effect that is no longer running starts nothing and counts nothing", function()
      local log = {}
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local outstanding = lifetime.join(fx)

      lifetime.release(fx)

      lifetime.spawn(outstanding, function()
        table.insert(log, "ran")
      end)

      expect(log).toEqual({})
      expect(outstanding.count).toBe(0)
    end)

    test("an await on a join inside a step is refused rather than left to yield the pass", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local outstanding = lifetime.join(fx)
      local after = false

      lifetime.add(outstanding)

      local handle = scheduler.add("compute", function()
        lifetime.awaitJoin(outstanding)
        after = true
      end)

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.1)
      end)

      handle:Disconnect()

      expect(after).toBe(false)
      expect(string.find(warnings[1], "lifetime.awaitJoin yields", 1, true) ~= nil).toBe(true)
    end)
  end)
end)
