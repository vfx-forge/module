local tween = require("@mod/tween")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

local Promise = require("@pkg/Promise")

local RAW_NEW = Promise._new

local function noop() end

-- a stand-in module, classified by class name, whose emit is the spec's own. one
-- that takes its whole subtree emits what is under it itself, the way a screen does
local function module(id: string, classifier: string, emit: (ctx: any) -> (), whole: boolean?)
  return {
    id = id,
    display = { name = id, order = 10 },
    classifier = classifier,
    components = if whole then "Instance" else nil,
    attributes = {},
    properties = {},
    emit = emit,
  }
end

-- the effects service with nothing registered but what a spec registers, and
-- a counter on every promise evaera builds from here on
local function fresh()
  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)

  local built = { count = 0, restore = noop }

  Promise._new = function(...)
    built.count += 1
    return RAW_NEW(...)
  end

  built.restore = function()
    Promise._new = RAW_NEW
  end

  return built
end

local function waiting(seconds: number)
  return function(ctx: any)
    lifetime.wait(ctx.scope, seconds)
  end
end

harness.suite(function()
  harness.describe("an emit's Finished", function()
    test("an emit nobody asks about builds no promise, and a read builds one", function()
      local built = fresh()
      registry.register(module("waits", "Folder", waiting(0.5)))

      local env = effects.emit(0, harness.make("Folder"))

      expect(built.count).toBe(0)

      local finished = env.Finished

      expect(built.count).toBe(1)
      expect(env.Finished).toBe(finished)

      built.restore()
      scheduler.frame(0.5)
    end)

    test("resolves when the emit ends on its own", function()
      local built = fresh()
      registry.register(module("waits", "Folder", waiting(0.5)))

      local env = effects.emit(0, harness.make("Folder"))
      local finished = env.Finished

      expect(finished:getStatus()).toBe("Started")

      scheduler.frame(0.5)

      expect(finished:getStatus()).toBe("Resolved")
      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("is already resolved when first read after the emit ended", function()
      local built = fresh()
      registry.register(module("returns", "Folder", noop))

      local env = effects.emit(0, harness.make("Folder"))

      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("resolves on a clear, read before the clear or after it", function()
      local built = fresh()
      registry.register(module("waits", "Folder", waiting(10)))

      local before = effects.emit(0, harness.make("Folder"))
      local held = before.Finished
      before:Clear()

      local after = effects.emit(0, harness.make("Folder"))
      after:Clear()

      expect(held:getStatus()).toBe("Resolved")
      expect(after.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("resolves when the service is torn down under a live emit", function()
      local built = fresh()
      registry.register(module("waits", "Folder", waiting(10)))

      local env = effects.emit(0, harness.make("Folder"))
      local finished = env.Finished

      effects.deinit()

      expect(finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("a Promise.all over Finished settles on a clear and runs its finally", function()
      local built = fresh()
      registry.register(module("waits", "Folder", waiting(10)))

      local log = {}
      local env = effects.emit(0, harness.make("Folder"))

      Promise.all({ env.Finished }):finally(function()
        table.insert(log, "finally")
      end)

      env:Clear()

      expect(log).toEqual({ "finally" })

      built.restore()
    end)

    test("is an evaera promise a roblox-ts await accepts", function()
      local built = fresh()
      registry.register(module("waits", "Folder", waiting(0.5)))

      local env = effects.emit(0, harness.make("Folder"))
      local status

      task.spawn(function()
        expect(Promise.is(env.Finished)).toBe(true)
        status = env.Finished:awaitStatus()
      end)

      scheduler.frame(0.5)

      expect(status).toBe(Promise.Status.Resolved)

      built.restore()
    end)
  end)

  harness.describe("a nested emit and the join it is given", function()
    test("the join holds its effect until the nested emit is done", function()
      local built = fresh()
      local log = {}

      registry.register(module("inner", "Configuration", waiting(0.5)))
      registry.register(module("outer", "Folder", function(ctx: any)
        local scope = ctx.scope
        local children = lifetime.join(scope)

        scope.effects.emitNested(ctx.ref, scope.depth + 1, scope, children)

        lifetime.awaitJoin(children)
        table.insert(log, "joined")
      end, true))

      local root = harness.make("Folder")
      harness.make("Configuration", root)

      local env = effects.emit(0, root)

      expect(log).toEqual({})

      scheduler.frame(0.5)

      expect(log).toEqual({ "joined" })
      expect(env.Finished:getStatus()).toBe("Resolved")
      expect(built.count).toBe(1)

      built.restore()
    end)
  end)

  -- pattern specs: the join and wait shape a shockwave module runs through,
  -- not shockwave_ring itself, which lune cannot emit without raycasts
  harness.describe("the shape a shockwave waits in", function()
    test("a dwell that outlasts the run files its exit after the body began waiting, and is waited for", function()
      local built = fresh()
      local log = {}

      registry.register(module("shape", "Folder", function(ctx: any)
        local scope = ctx.scope
        local outstanding = lifetime.join(scope)
        local landed = lifetime.add(outstanding)

        tween.after(0.75, function(deltaTime: number)
          return deltaTime
        end, function()
          task.spawn(function()
            -- the exit, a stepper that counts itself out when it lands
            tween.after(0.5, function(deltaTime: number)
              return deltaTime
            end, lifetime.add(outstanding), scope)

            landed()
          end)
        end, scope)

        tween.timer(0.5, function(deltaTime: number)
          return deltaTime
        end, nil, scope)

        table.insert(log, "waiting")
        lifetime.awaitJoin(outstanding)
        table.insert(log, "joined")
      end))

      effects.emit(0, harness.make("Folder"))

      for _ = 1, 4 do
        scheduler.frame(0.25)
      end

      expect(log).toEqual({ "waiting" })

      for _ = 1, 3 do
        scheduler.frame(0.25)
      end

      expect(log).toEqual({ "waiting", "joined" })

      built.restore()
    end)

    test("an on-impact emit started while the body waits is waited for", function()
      local built = fresh()
      local log = {}

      registry.register(module("inner", "Configuration", waiting(0.5)))
      registry.register(module("shape", "Folder", function(ctx: any)
        local scope = ctx.scope
        local outstanding = lifetime.join(scope)
        local landed = lifetime.add(outstanding)
        local impact = ctx.ref:FindFirstChildOfClass("Model")

        tween.after(0.25, function(deltaTime: number)
          return deltaTime
        end, function()
          scope.effects.emitFromFolder(impact, ctx.ref, scope.depth + 1, scope, outstanding)
          landed()
        end, scope)

        lifetime.awaitJoin(outstanding)
        table.insert(log, "joined")
      end, true))

      local root = harness.make("Folder")
      local impact = harness.make("Model", root)
      harness.make("Configuration", impact)

      effects.emit(0, root)

      scheduler.frame(0.25)
      scheduler.frame(0.25)

      expect(log).toEqual({})

      scheduler.frame(0.5)

      expect(log).toEqual({ "joined" })

      built.restore()
    end)
  end)

  -- pattern specs: the join and try shape a bezier piece or a lightning bolt
  -- runs through, not bezier or lightning themselves, which need a Points
  -- attachment and a cached part and only run in Studio
  harness.describe("the shape a bezier or a bolt waits in", function()
    test("a piece whose setup throws is logged once and counted out, and its sibling still holds the body", function()
      local built = fresh()
      local log = {}

      registry.register(module("shape", "Folder", function(ctx: any)
        local scope = ctx.scope
        local outstanding = lifetime.join(scope)

        for i = 1, 2 do
          local landed = lifetime.add(outstanding)

          local ok = utility.try(`failed to emit a piece with error: %s`, function()
            if i == 1 then
              error("boom")
            end

            tween.after(0.5, function(deltaTime: number)
              return deltaTime
            end, landed, scope)
          end)

          if not ok then
            landed()
          end
        end

        lifetime.awaitJoin(outstanding)
        table.insert(log, "joined")
      end))

      local warnings = harness.captureWarnings(function()
        effects.emit(0, harness.make("Folder"))
      end)

      expect(#warnings).toBe(1)
      expect(log).toEqual({})

      scheduler.frame(0.5)
      scheduler.frame(0.5)

      expect(log).toEqual({ "joined" })

      built.restore()
    end)
  end)
end)
