local attr = require("@mod/attributes")
local clock = require("@mod/clock")
local tween = require("@mod/tween")
local curves = require("@mod/curves")
local logger = require("@mod/logger")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local enabled_effects = require("@srv/enabled_effects")
local test, expect = harness.test, harness.expect

local Promise = require("@pkg/Promise")
local controller = require("@vfx/controller")

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

-- an emit that adds up the time its effect is handed, under `seen[name]`
local function counting(seen: { [string]: number })
  return function(ctx: any)
    local name = ctx.ref.Name

    seen[name] = 0

    lifetime.step(ctx.scope, function(deltaTime: number)
      seen[name] += deltaTime
    end)

    lifetime.wait(ctx.scope, 100)
  end
end

-- one frame for a change to reach the clocks, then one frame of `seconds`
-- counted from zero
local function measure(seen: { [string]: number }, seconds: number)
  scheduler.frame(0)

  for name in seen do
    seen[name] = 0
  end

  scheduler.frame(seconds)
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

  harness.describe("an emit's handle", function()
    test("SetSpeed scales every effect of the emit from the next frame, and GetSpeed answers it", function()
      local built = fresh()
      local seen = {}
      registry.register(module("counts", "Folder", counting(seen)))

      local a = harness.make("Folder")
      local b = harness.make("Folder")
      a.Name, b.Name = "a", "b"

      local env = effects.emit(0, a, b)

      expect(env:GetSpeed()).toBe(1)

      env:SetSpeed(2)

      expect(env:GetSpeed()).toBe(2)

      measure(seen, 1)

      expect(seen).toEqual({ a = 2, b = 2 })

      env:Clear()
      built.restore()
    end)

    test("Pause stands the emit still and Resume picks it up where it stood", function()
      local built = fresh()
      local log = {}
      registry.register(module("waits", "Folder", function(ctx: any)
        lifetime.wait(ctx.scope, 1)
        table.insert(log, "waited")
      end))

      local env = effects.emit(0, harness.make("Folder"))

      scheduler.frame(0.5)

      env:Pause()

      expect(env:IsPaused()).toBe(true)

      scheduler.frame(0)
      scheduler.frame(10)

      expect(log).toEqual({})

      env:Resume()

      expect(env:IsPaused()).toBe(false)

      scheduler.frame(0)
      scheduler.frame(0.5)

      expect(log).toEqual({ "waited" })

      built.restore()
    end)

    test("refuses a speed that is not a finite number of 0 or more, naming SetSpeed", function()
      local built = fresh()
      registry.register(module("waits", "Folder", waiting(10)))

      local env = effects.emit(0, harness.make("Folder"))

      for _, bad in { -1, 0 / 0, math.huge, "fast" :: any } do
        local ok, err = pcall(function()
          env:SetSpeed(bad)
        end)

        expect(ok).toBe(false)
        expect(string.find(tostring(err), "SetSpeed", 1, true) ~= nil).toBe(true)
      end

      expect(env:GetSpeed()).toBe(1)

      env:Clear()
      built.restore()
    end)

    test("Clear still works called without self", function()
      local built = fresh()
      registry.register(module("waits", "Folder", waiting(10)))

      local env = effects.emit(0, harness.make("Folder"))
      local finished = env.Finished

      env.Clear()

      expect(finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("a nested emit runs on the clock of the effect that started it", function()
      local built = fresh()
      local seen = {}
      registry.register(module("counts", "Part", counting(seen)))
      registry.register(module("starts", "Model", function(ctx: any)
        local scope = ctx.scope
        local children = lifetime.join(scope)

        clock.setSpeed(scope.clock, 0.5)
        scope.effects.emitNested(ctx.ref, scope.depth + 1, scope, children)
        lifetime.awaitJoin(children)
      end, true))

      local model = harness.make("Model")
      harness.make("Part", model).Name = "nested"

      local env = effects.emit(0, model)

      env:SetSpeed(0.5)
      measure(seen, 1)

      expect(seen.nested).toBe(0.25)

      env:Clear()
      built.restore()
    end)
    test("an on-finish emit runs on the clock of the effect that started it", function()
      local built = fresh()
      local seen = {}
      registry.register(module("counts", "Part", counting(seen)))
      registry.register(module("starts", "Model", function(ctx: any)
        local scope = ctx.scope
        local children = lifetime.join(scope)
        local folder = scope.effects.prepareEmitOnFinish(ctx.ref, scope)

        clock.setSpeed(scope.clock, 0.5)
        scope.effects.emitOnFinish(folder, ctx.ref, scope.depth + 1, scope, children)
        lifetime.awaitJoin(children)
      end, true))

      local model = harness.make("Model")
      local folder = harness.make("Folder", model)

      folder.Name = "EmitOnFinish"
      harness.make("Part", folder).Name = "finish"

      local env = effects.emit(0, model)

      measure(seen, 1)

      expect(seen.finish).toBe(0.5)

      env:Clear()
      built.restore()
    end)
  end)

  harness.describe("an emit's priority", function()
    -- a property every emit of a "writes" folder writes its own Value
    -- attribute to, until the spec clears it
    local function writes(target: { [string]: any })
      return module("writes", "Folder", function(ctx: any)
        local w = lifetime.write(ctx.scope, target, "property", "Value")

        lifetime.set(w, ctx.ref:GetAttribute("Value"))
        lifetime.wait(ctx.scope, 100)
      end)
    end

    local function folder(v: number): Instance
      local made = harness.make("Folder")
      made:SetAttribute("Value", v)

      return made
    end

    -- every warning logged while `fn` runs
    local function warnings(fn: () -> ()): { string }
      local seen = {}
      local warn = logger.warn

      logger.warn = function(...)
        table.insert(seen, table.concat({ ... }, " "))
      end

      fn()

      logger.warn = warn

      return seen
    end

    test("an options table after the instances sets it, and 0 is the default", function()
      local built = fresh()
      registry.register(module("waits", "Folder", waiting(10)))

      local plain = effects.emit(0, harness.make("Folder"))
      local ranked = effects.emit(0, harness.make("Folder"), { priority = 5 })

      expect(plain:GetPriority()).toBe(0)
      expect(ranked:GetPriority()).toBe(5)

      plain:Clear()
      ranked:Clear()
      built.restore()
    end)

    test("a priority that is not a finite number warns and is 0, and an unknown key warns", function()
      local built = fresh()
      registry.register(module("waits", "Folder", waiting(10)))

      for _, bad in { 0 / 0, math.huge, "high" :: any } do
        local env
        local seen = warnings(function()
          env = effects.emit(0, harness.make("Folder"), { priority = bad })
        end)

        expect(#seen).toBe(1)
        expect(env:GetPriority()).toBe(0)

        env:Clear()
      end

      local env
      local seen = warnings(function()
        env = effects.emit(0, harness.make("Folder"), { prority = 5 })
      end)

      expect(#seen).toBe(1)
      expect(env:GetPriority()).toBe(0)

      env:Clear()
      built.restore()
    end)

    test("an emit of a higher priority owns a target over a newer emit", function()
      local built = fresh()
      local target = { Value = 0 }
      registry.register(writes(target))

      local high = effects.emit(0, folder(1), { priority = 1 })
      local low = effects.emit(0, folder(2))

      expect(target.Value).toBe(1)

      high:Clear()

      expect(target.Value).toBe(2)

      low:Clear()

      expect(target.Value).toBe(0)

      built.restore()
    end)

    test("SetPriority raises an older emit over a newer one at once, and back", function()
      local built = fresh()
      local target = { Value = 0 }
      registry.register(writes(target))

      local older = effects.emit(0, folder(1))
      local newer = effects.emit(0, folder(2))

      expect(target.Value).toBe(2)

      older:SetPriority(1)

      expect(older:GetPriority()).toBe(1)
      expect(target.Value).toBe(1)

      older:SetPriority(0)

      expect(target.Value).toBe(2)

      older:Clear()
      newer:Clear()
      built.restore()
    end)

    test("SetPriority on an ended emit does nothing", function()
      local built = fresh()
      registry.register(module("returns", "Folder", noop))

      local env = effects.emit(0, harness.make("Folder"))

      env:SetPriority(4)

      expect(env:GetPriority()).toBe(0)

      built.restore()
    end)

    test("SetPriority with a value that is not a finite number warns and keeps the priority", function()
      local built = fresh()
      registry.register(module("waits", "Folder", waiting(10)))

      local env = effects.emit(0, harness.make("Folder"), { priority = 2 })

      for _, bad in { 0 / 0, -math.huge, "high" :: any } do
        local seen = warnings(function()
          env:SetPriority(bad)
        end)

        expect(#seen).toBe(1)
        expect(env:GetPriority()).toBe(2)
      end

      env:Clear()
      built.restore()
    end)

    test("a ConstantVFX tick's emit is marked constant", function()
      local token = enabled_effects.token(harness.make("Part"))

      expect(token.constant).toBe(true)
      expect(token.priority).toBe(0)
    end)

    test("an EmitDuration's forced ticks are not marked constant", function()
      local obj = harness.make("Part")

      utility.forceEmit(obj, true)

      expect(enabled_effects.token(obj).constant).toBe(false)

      utility.forceEmit(obj, false)
    end)
  end)

  harness.describe("a controller", function()
    -- the stand-ins every case scales: two counting folders and a controller,
    -- siblings under one parent, emitted together
    local function siblings(scope: string, timeScale: number, seen: { [string]: number })
      fresh()
      registry.register(module("counts", "Folder", counting(seen)))
      registry.register(controller)

      local parent = harness.make("Model")
      local a = harness.make("Folder", parent)
      local b = harness.make("Folder", parent)
      local rule = harness.make("RayValue", parent)

      a.Name, b.Name = "a", "b"

      rule:AddTag("Controller")
      rule:SetAttribute("Scope", scope)
      rule:SetAttribute("TimeScale", timeScale)
      rule:SetAttribute("EmitDuration", 10)

      return a, b, rule
    end

    -- a counting model that starts the emit of what is under it, the way a
    -- mesh or a beam does, with a controller among its children
    local function nested(scope: string, timeScale: number, seen: { [string]: number })
      fresh()
      registry.register(module("counts", "Folder", counting(seen)))
      registry.register(controller)
      registry.register(module("starts", "Model", function(ctx: any)
        local scope = ctx.scope
        local name = ctx.ref.Name
        local children = lifetime.join(scope)

        seen[name] = 0

        lifetime.step(scope, function(deltaTime: number)
          seen[name] += deltaTime
        end)

        scope.effects.emitNested(ctx.ref, scope.depth + 1, scope, children)
        lifetime.awaitJoin(children)
      end, true))

      local host = harness.make("Model")
      local child = harness.make("Folder", host)
      local rule = harness.make("RayValue", host)

      host.Name, child.Name = "host", "child"

      rule:AddTag("Controller")
      rule:SetAttribute("Scope", scope)
      rule:SetAttribute("TimeScale", timeScale)
      rule:SetAttribute("EmitDuration", 10)

      return host
    end

    test("ParentAndDescendants and Descendants scale everything under the parent", function()
      for _, scope in { "ParentAndDescendants", "Descendants" } do
        local seen = {}
        local a, b, rule = siblings(scope, 0.5, seen)

        local env = effects.emit(0, a, b, rule)

        measure(seen, 1)

        expect(seen).toEqual({ a = 0.5, b = 0.5 })

        env:Clear()
      end
    end)

    test("Parent on an instance that hosts no effect scales nothing", function()
      local seen = {}
      local a, b, rule = siblings("Parent", 0.5, seen)

      local env = effects.emit(0, a, b, rule)

      measure(seen, 1)

      expect(seen).toEqual({ a = 1, b = 1 })

      env:Clear()
    end)

    test("Global scales every effect through the global clock", function()
      local seen = {}
      local a, b, rule = siblings("Global", 0.5, seen)

      local env = effects.emit(0, a, rule)
      local other = effects.emit(0, b)

      measure(seen, 1)

      expect(seen).toEqual({ a = 0.5, b = 0.5 })
      expect(clock.effective()).toBe(0.5)

      env:Clear()
      other:Clear()
    end)

    test("on the instance a nested emit starts from, each scope takes what it names", function()
      local cases = {
        Parent = { host = 0.25, child = 0.25 },
        ParentAndDescendants = { host = 0.25, child = 0.25 },
        Descendants = { host = 1, child = 0.25 },
      }

      for scope, expected in cases do
        local seen = {}
        local env = effects.emit(0, nested(scope, 0.25, seen))

        measure(seen, 1)

        expect(seen).toEqual(expected)

        env:Clear()
      end
    end)

    -- a host that clones one template per piece and starts each piece's
    -- nested emit, the way a mesh of many pieces or a ring's segments do
    local function copies(count: number, rules: { { scope: string, timeScale: number } }, seen: { [string]: number })
      fresh()
      registry.register(controller)

      local template = harness.make("Folder")

      for _, rule in rules do
        local inst = harness.make("RayValue", template)

        inst:AddTag("Controller")
        inst:SetAttribute("Scope", rule.scope)
        inst:SetAttribute("TimeScale", rule.timeScale)
        inst:SetAttribute("EmitDuration", 10)
      end

      registry.register(module("starts", "Model", function(ctx: any)
        local scope = ctx.scope
        local children = lifetime.join(scope)

        seen.host = 0

        lifetime.step(scope, function(deltaTime: number)
          seen.host += deltaTime
        end)

        for _ = 1, count do
          local copy = harness.clone(template)

          copy.Parent = ctx.ref
          scope.effects.emitNested(copy, scope.depth + 1, scope, children)
        end

        lifetime.awaitJoin(children)
      end, true))

      return harness.make("Model")
    end

    test("pieces cloned from one template scale their host once per controller", function()
      local seen = {}
      local env = effects.emit(0, copies(20, { { scope = "ParentAndDescendants", timeScale = 0.5 } }, seen))

      measure(seen, 1)

      expect(seen.host).toBe(0.5)

      env:Clear()
    end)

    test("two controllers in one template still multiply, however many pieces", function()
      local seen = {}
      local rules = {
        { scope = "ParentAndDescendants", timeScale = 0.5 },
        { scope = "ParentAndDescendants", timeScale = 0.5 },
      }

      local env = effects.emit(0, copies(20, rules, seen))

      measure(seen, 1)

      expect(seen.host).toBe(0.25)

      env:Clear()
    end)

    test("a Global controller cloned into every piece scales the global clock once", function()
      local seen = {}
      local env = effects.emit(0, copies(20, { { scope = "Global", timeScale = 0.5 } }, seen))

      scheduler.frame(0)

      expect(clock.effective()).toBe(0.5)

      env:Clear()
      scheduler.frame(0)

      expect(clock.effective()).toBe(1)
    end)

    test("an on-finish controller emitted into pieces holding different children scales its host once", function()
      local seen = {}

      fresh()
      registry.register(controller)

      local template = harness.make("Folder")
      template.Name = "EmitOnFinish"

      harness.make("Folder", template)

      local inst = harness.make("RayValue", template)

      inst:AddTag("Controller")
      inst:SetAttribute("Scope", "ParentAndDescendants")
      inst:SetAttribute("TimeScale", 0.5)
      inst:SetAttribute("EmitDuration", 10)

      registry.register(module("finishes", "Model", function(ctx: any)
        local scope = ctx.scope
        local children = lifetime.join(scope)

        seen.host = 0

        lifetime.step(scope, function(deltaTime: number)
          seen.host += deltaTime
        end)

        -- each piece already holds what the run gave it, a different count
        -- each, ahead of what the folder moves in
        for i = 1, 6 do
          local site = harness.make("Folder", ctx.ref)

          for _ = 1, i do
            harness.make("Folder", site)
          end

          scope.effects.emitFromFolder(harness.clone(template), site, scope.depth + 1, scope, children)
        end

        lifetime.awaitJoin(children)
      end, true))

      local env = effects.emit(0, harness.make("Model"))

      measure(seen, 1)

      expect(seen.host).toBe(0.5)

      env:Clear()
    end)

    test("several controllers on one scope multiply", function()
      local seen = {}
      local a, b, rule = siblings("Descendants", 0.5, seen)
      local second = harness.make("RayValue", a.Parent)

      second:AddTag("Controller")
      second:SetAttribute("Scope", "Descendants")
      second:SetAttribute("TimeScale", 0.5)
      second:SetAttribute("EmitDuration", 10)

      local env = effects.emit(0, a, b, rule, second)

      measure(seen, 1)

      expect(seen).toEqual({ a = 0.25, b = 0.25 })

      env:Clear()
    end)

    test("a local controller runs on the clocks above its scope, never on its own", function()
      local seen = {}
      local a, _, rule = siblings("ParentAndDescendants", 0.5, seen)

      rule:SetAttribute("EmitDuration", 1)

      local env = effects.emit(0, a, rule)

      measure(seen, 1)
      expect(seen.a).toBe(0.5)

      -- its second ran out at the real second, so the scope is back at 1
      measure(seen, 1)
      expect(seen.a).toBe(1)

      env:Clear()
    end)

    test("a Global controller runs on real time a global pause still stops", function()
      local seen = {}
      local a, _, rule = siblings("Global", 0.5, seen)

      rule:SetAttribute("EmitDuration", 1)

      local env = effects.emit(0, a, rule)

      clock.setGlobalPaused(true)
      measure(seen, 5)

      -- still scaled: the controller's real second has not run while paused
      expect(clock.effective()).toBe(0.5)

      clock.setGlobalPaused(false)
      measure(seen, 0.5)

      expect(clock.effective()).toBe(0.5)

      measure(seen, 0.5)
      scheduler.frame(0)

      expect(clock.effective()).toBe(1)

      env:Clear()
    end)

    test("two Global controllers multiply and never slow each other", function()
      local seen = {}
      local a, b, rule = siblings("Global", 0.5, seen)
      local second = harness.make("RayValue", a.Parent)

      second:AddTag("Controller")
      second:SetAttribute("Scope", "Global")
      second:SetAttribute("TimeScale", 0.5)
      second:SetAttribute("EmitDuration", 1)
      rule:SetAttribute("EmitDuration", 1)

      local env = effects.emit(0, b, rule, second)

      measure(seen, 0.5)

      expect(clock.effective()).toBe(0.25)

      measure(seen, 0.5)
      scheduler.frame(0)

      expect(clock.effective()).toBe(1)

      env:Clear()
    end)

    test("its factor goes on a clear, at deinit and once it ends", function()
      local seen = {}
      local a, _, rule = siblings("Global", 0.5, seen)

      local cleared = effects.emit(0, a, rule)

      scheduler.frame(0)
      expect(clock.effective()).toBe(0.5)

      cleared:Clear()
      scheduler.frame(0)
      expect(clock.effective()).toBe(1)

      effects.emit(0, a, rule)

      scheduler.frame(0)
      expect(clock.effective()).toBe(0.5)

      effects.deinit()
      scheduler.frame(0)
      expect(clock.effective()).toBe(1)
    end)

    test("a hit-stop curve on TimeScale reaches the scope frame by frame", function()
      local seen = {}
      local a, b, rule = siblings("Descendants", 1, seen)

      -- an old style quad, which the row folds into a linear ramp from 0 to 1
      -- over a second
      rule:SetAttribute("TimeScale_Start", 0)
      rule:SetAttribute("TimeScale_End", 1)
      rule:SetAttribute("TimeScale_Duration", 1)

      -- a curve is a binary string no instance here can hold, so it goes
      -- through the attribute cache every reader looks in first
      rule:SetAttribute("TimeScale_Curve", "")
      attr.cache(rule)
      attr.set(rule, "TimeScale_Curve", curves.linear())

      local env = effects.emit(0, a, b, rule)

      -- each half second in frames of a hundredth, so what the scope ran is
      -- the area under the ramp: about 0.125 then 0.375, where a constant
      -- would give the same twice
      local function half()
        for name in seen do
          seen[name] = 0
        end

        for _ = 1, 50 do
          scheduler.frame(0.01)
        end

        return seen.a
      end

      scheduler.frame(0)

      local early = half()
      local late = half()

      expect(math.abs(early - 0.125) < 0.02).toBe(true)
      expect(math.abs(late - 0.375) < 0.02).toBe(true)

      env:Clear()
    end)

    test("SpeedChanged fires as a Global controller moves the effective speed", function()
      local seen = {}
      local heard = {}
      local a, _, rule = siblings("Global", 0.5, seen)

      local connection = clock.speedChanged:Connect(function(speed: number)
        table.insert(heard, speed)
      end)

      local env = effects.emit(0, a, rule)

      scheduler.frame(0)
      env:Clear()
      scheduler.frame(0)

      connection:Disconnect()

      expect(heard).toEqual({ 0.5, 1 })
    end)

    test("SpeedChanged fires once with 1 as deinit tears a Global controller down", function()
      local seen = {}
      local heard = {}
      local a, _, rule = siblings("Global", 0.5, seen)

      effects.emit(0, a, rule)
      scheduler.frame(0)

      expect(clock.effective()).toBe(0.5)

      local connection = clock.speedChanged:Connect(function(speed: number)
        table.insert(heard, speed)
      end)

      -- no frame follows a deinit to announce what it cleared
      effects.deinit()

      connection:Disconnect()

      expect(heard).toEqual({ 1 })
    end)

    test("deinit puts the global speed back at 1 and resumes, so the next init starts at full speed", function()
      local seen = {}
      local heard = { speed = {}, paused = {} }

      fresh()
      registry.register(module("counts", "Folder", counting(seen)))

      clock.setGlobalSpeed(0.5)
      clock.setGlobalPaused(true)

      local speedConnection = clock.speedChanged:Connect(function(speed: number)
        table.insert(heard.speed, speed)
      end)

      local pausedConnection = clock.pausedChanged:Connect(function(paused: boolean)
        table.insert(heard.paused, paused)
      end)

      effects.deinit()

      speedConnection:Disconnect()
      pausedConnection:Disconnect()

      expect(heard).toEqual({ speed = { 1 }, paused = { false } })
      expect(clock.global.speed).toBe(1)
      expect(clock.global.paused).toBe(false)
      expect(clock.wall.paused).toBe(false)

      effects.init({ setup = true } :: any)

      local env = effects.emit(0, harness.make("Folder"))

      measure(seen, 1)

      expect(seen).toEqual({ Folder = 1 })

      env:Clear()
    end)

    test("deinit takes off a Global controller's scale from an emit it does not track", function()
      local seen = {}
      local heard = {}
      local _, _, rule = siblings("Global", 0.5, seen)

      -- a ConstantVFX tick's token: never sealed and never live, so deinit
      -- cannot clear the controller nested under it
      local token = lifetime.emit(nil)
      local tick = lifetime.effect(token, 0, effects)

      effects.emitNested(rule.Parent :: Instance, 1, tick)
      scheduler.frame(0)

      expect(clock.effective()).toBe(0.5)

      local connection = clock.speedChanged:Connect(function(speed: number)
        table.insert(heard, speed)
      end)

      effects.deinit()

      connection:Disconnect()

      expect(clock.effective()).toBe(1)
      expect(heard).toEqual({ 1 })

      lifetime.clear(token)
    end)

    test("a TimeScale that is not a number leaves the scope alone and one below 0 holds it", function()
      local cases = {
        { expected = 1, attributes = { TimeScale = 0 / 0 } },
        { expected = 1, attributes = { TimeScale = math.huge } },
        { expected = 0, attributes = { TimeScale = -1 } },
      }

      for _, case in cases do
        local seen = {}
        local a, b, rule = siblings("Descendants", 1, seen)

        for name, value in case.attributes do
          rule:SetAttribute(name, value)
        end

        local env = effects.emit(0, a, b, rule)

        measure(seen, 1)

        expect(seen).toEqual({ a = case.expected, b = case.expected })

        env:Clear()
      end
    end)

    test("a nan or an infinity the TimeScale row writes never reaches the clocks it scales", function()
      for _, bad in { 0 / 0, math.huge } do
        local seen = {}

        fresh()
        registry.register(module("counts", "Folder", counting(seen)))

        -- the controller's own emit, handed a row that writes the bad value,
        -- the way a modifier could where the reader does not see it
        registry.register(module(controller.id, "RayValue", function(ctx: any)
          controller.emit(ctx, {
            Scope = "Descendants",
            EmitDelay = 0,
            EmitDuration = 10,
            TimeScale = {
              apply = function(_, write: (value: number) -> ())
                write(bad)
              end,
            },
          })
        end))

        local parent = harness.make("Model")
        local a = harness.make("Folder", parent)
        local b = harness.make("Folder", parent)
        local rule = harness.make("RayValue", parent)

        a.Name, b.Name = "a", "b"

        local env = effects.emit(0, a, b, rule)

        measure(seen, 1)

        expect(seen).toEqual({ a = 1, b = 1 })

        env:Clear()
      end
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
    test("an effect halted at Speed 0 lets its nested emit run out on the clocks above it, and finishes", function()
      local built = fresh()
      local log = {}
      local seen = {}

      registry.register(module("inner", "Configuration", function(ctx: any)
        seen.inner = 0

        lifetime.step(ctx.scope, function(deltaTime: number)
          seen.inner += deltaTime
        end)

        lifetime.wait(ctx.scope, 0.5)
      end))

      registry.register(module("outer", "Folder", function(ctx: any)
        local scope = ctx.scope
        local children = lifetime.join(scope)

        seen.outer = 0

        lifetime.speed(scope, {
          animated = false,
          duration = 0,
          at = function()
            return 0
          end,
        })

        lifetime.step(scope, function(deltaTime: number)
          seen.outer += deltaTime
        end)

        scope.effects.emitNested(ctx.ref, scope.depth + 1, scope, children)

        lifetime.awaitJoin(children)
        table.insert(log, "joined")
      end, true))

      local root = harness.make("Folder")
      harness.make("Configuration", root)

      local env = effects.emit(0, root)

      env:SetSpeed(0.5)
      scheduler.frame(0)
      scheduler.frame(0.5)

      -- the halted effect stands still, and its child runs at the handle's half
      expect(seen).toEqual({ outer = 0, inner = 0.25 })
      expect(log).toEqual({})

      scheduler.frame(0.5)

      expect(log).toEqual({ "joined" })
      expect(env.Finished:getStatus()).toBe("Resolved")

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

  -- pattern specs: the tick shape an EmitDuration mesh waits in, not mesh
  -- itself, which needs a cached part and only runs in Studio
  harness.describe("an EmitDuration's ticks", function()
    test("waiting out the ticks waits for the last piece of every tick", function()
      local log = {}
      local token = lifetime.emit(nil)

      for i = 1, 2 do
        lifetime.run(lifetime.effect(token, 0, nil), function(scope: lifetime.effect)
          local outstanding = lifetime.join(scope)

          lifetime.spawn(outstanding, function()
            lifetime.wait(scope, 0.5 * i)
          end)

          lifetime.awaitJoin(outstanding)
        end)
      end

      lifetime.run(lifetime.effect(lifetime.emit(nil), 0, nil), function()
        utility.awaitEmitDuration(token)
        table.insert(log, "waited")
      end)

      scheduler.frame(0.5)
      expect(log).toEqual({})

      scheduler.frame(0.5)
      expect(log).toEqual({ "waited" })
    end)

    test("a tick with no ramp written runs at its own Speed row", function()
      local ref = harness.make("Model")
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      utility.speedFrom(fx, ref, {
        animated = false,
        duration = 0,
        at = function()
          return 2
        end,
      })

      expect(fx.clock.speed).toBe(2)

      lifetime.clear(emit)
    end)

    test("a tick follows the speed the EmitDuration's ramp writes, every frame", function()
      local ref = harness.make("Model")
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      attr.setState(ref, "SpeedTweening", true)
      attr.setState(ref, "SpeedOverride", 0.5)

      utility.speedFrom(fx, ref, {
        animated = false,
        duration = 0,
        at = function()
          return 2
        end,
      })

      expect(fx.clock.speed).toBe(0.5)

      attr.setState(ref, "SpeedOverride", 0)
      scheduler.frame(0)

      expect(fx.clock.speed).toBe(0)
      expect(fx.clock.halted).toBe(false)

      attr.setState(ref, "SpeedTweening", nil)
      scheduler.frame(0)

      expect(fx.clock.halted).toBe(true)

      attr.clearState(ref)
      lifetime.clear(emit)
      scheduler.frame(0)
    end)

    test("a tick keeps the last speed its ramp wrote once the state is cleared", function()
      local ref = harness.make("Model")
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      attr.setState(ref, "SpeedTweening", true)
      attr.setState(ref, "SpeedOverride", 0.2)

      utility.speedFrom(fx, ref, {
        animated = false,
        duration = 0,
        at = function()
          return 1
        end,
      })

      attr.clearState(ref)
      scheduler.frame(0)

      expect(fx.clock.speed).toBe(0.2)

      lifetime.clear(emit)
      scheduler.frame(0)
    end)

    test("a tick that halted stays halted once the state is cleared", function()
      local ref = harness.make("Model")
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      attr.setState(ref, "SpeedTweening", true)
      attr.setState(ref, "SpeedOverride", 0)

      utility.speedFrom(fx, ref, {
        animated = false,
        duration = 0,
        at = function()
          return 1
        end,
      })

      attr.setState(ref, "SpeedTweening", nil)
      scheduler.frame(0)

      expect(fx.clock.halted).toBe(true)

      attr.clearState(ref)
      scheduler.frame(0)

      expect(fx.clock.halted).toBe(true)

      lifetime.clear(emit)
      scheduler.frame(0)
    end)

    test("a tick ignores a NaN speed", function()
      local ref = harness.make("Model")
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)

      attr.setState(ref, "SpeedTweening", true)
      attr.setState(ref, "SpeedOverride", 0.5)

      utility.speedFrom(fx, ref, {
        animated = false,
        duration = 0,
        at = function()
          return 0 / 0
        end,
      })

      attr.setState(ref, "SpeedOverride", 0 / 0)
      scheduler.frame(0)

      expect(fx.clock.speed).toBe(0.5)

      attr.clearState(ref)
      lifetime.clear(emit)
      scheduler.frame(0)
    end)

    -- a stand-in enabled module whose every tick is counted, and its ticker
    -- on the token an instance it forced or did not force would get
    local function ticking(timeline: clock.Clock?)
      fresh()

      local ticks = { count = 0 }
      local stand = module("ticks", "Model", function()
        ticks.count += 1
      end)

      stand.constant = true
      registry.register(stand)

      local ref = harness.make("Model")

      utility.forceEmit(ref, timeline ~= nil, timeline)

      local token = enabled_effects.token(ref)

      return ticks, token, enabled_effects.ticker(ref, stand :: any, token, effects), ref
    end

    test("an EmitDuration's ticks run on the clock of the effect that forced them", function()
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, effects)
      local ticks, token, tick, ref = ticking(fx.clock)

      expect(token.clock.parent).toBe(fx.clock)

      -- the handle of the forcing emit paused: no tick, not even the first
      clock.setPaused(emit.clock, true)
      scheduler.frame(0)

      for _ = 1, 3 do
        tick(1)
      end

      expect(ticks.count).toBe(0)

      -- resumed at half speed: the first tick at once, the next after 0.2 s of
      -- the token's clock at the default 5 a second, so after 0.4 s of frames
      clock.setPaused(emit.clock, false)
      clock.setSpeed(emit.clock, 0.5)
      scheduler.frame(0)

      tick(0.1)
      expect(ticks.count).toBe(1)

      tick(0.3)
      expect(ticks.count).toBe(1)

      tick(0.11)
      expect(ticks.count).toBe(2)

      utility.forceEmit(ref, false)
      lifetime.clear(token)
      lifetime.clear(emit)
      scheduler.frame(0)
    end)

    test("a plain enabled instance's ticks hang from the global clock and stop while it is paused", function()
      local ticks, token, tick = ticking(nil)

      expect(token.clock.parent).toBe(clock.global)

      clock.setGlobalPaused(true)
      scheduler.frame(0)

      tick(1)
      expect(ticks.count).toBe(0)

      clock.setGlobalPaused(false)
      scheduler.frame(0)

      tick(0)
      expect(ticks.count).toBe(1)

      lifetime.clear(token)
      scheduler.frame(0)
    end)

    test("a clear of the ticks closes every piece they hold", function()
      local token = lifetime.emit(nil)
      local workers: { thread } = {}

      for _ = 1, 2 do
        lifetime.run(lifetime.effect(token, 0, nil), function(scope: lifetime.effect)
          local outstanding = lifetime.join(scope)

          lifetime.spawn(outstanding, function()
            table.insert(workers, coroutine.running())
            lifetime.wait(scope, 10)
          end)

          lifetime.awaitJoin(outstanding)
        end)
      end

      lifetime.clear(token)

      expect(#workers).toBe(2)
      expect(coroutine.status(workers[1])).toBe("dead")
      expect(coroutine.status(workers[2])).toBe("dead")
      expect(#token.effects).toBe(0)
    end)
  end)

  harness.describe("a beam", function()
    test("a LengthScale other than 1 never moves the authored attachments", function()
      local built = fresh()
      local CFrame = harness.datatypes.CFrame
      registry.register(require("@vfx/beam"))

      local part = harness.make("Part")
      local a0 = harness.make("Attachment", part)
      local a1 = harness.make("Attachment", part)

      a0.CFrame = CFrame.new(0, 0, 0)
      a1.CFrame = CFrame.new(0, 0, 10)

      local beam = harness.make("Beam", part) :: any

      beam.Attachment0 = a0
      beam.Attachment1 = a1
      beam:SetAttribute("LengthScale", 2)

      local env = effects.emit(0, beam)

      scheduler.frame(0)

      expect(a0.CFrame).toEqual(CFrame.new(0, 0, 0))
      expect(a1.CFrame).toEqual(CFrame.new(0, 0, 10))

      env:Clear()

      expect(a0.CFrame).toEqual(CFrame.new(0, 0, 0))
      expect(a1.CFrame).toEqual(CFrame.new(0, 0, 10))

      built.restore()
    end)
  end)
end)
