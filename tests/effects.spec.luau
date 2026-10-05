local fs = require("@lune/fs")
local mods = require("@mod/mods")
local attr = require("@mod/attributes")
local clock = require("@mod/clock")
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local curves = require("@mod/curves")
local logger = require("@mod/logger")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local utility = require("@mod/utility")
local emitters = require("@root/emitters")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local fake_pool = require("@tests/fake_pool")
local enabled_effects = require("@srv/enabled_effects")
local test, expect = harness.test, harness.expect
local row = harness.row

local mesh = require("@vfx/mesh")
local bezier = require("@vfx/bezier")
local Promise = require("@pkg/Promise")
local lightning = require("@vfx/lightning")
local controller = require("@vfx/controller")

local RAW_NEW = Promise._new

frame.configure(harness.fakeEncoding, harness.fakeCompression)

local function noop() end

local LISTS = {
  Part = { "Color", "Size", "Transparency" },
}

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

    test(
      "GetTime counts the emit's effect time: scaled by its speed, still while paused and once it is done",
      function()
        local built = fresh()
        registry.register(module("waits", "Folder", waiting(10)))

        local env = effects.emit(0, harness.make("Folder"))

        expect(env:GetTime()).toBe(0)

        scheduler.frame(0.5)

        expect(env:GetTime()).toBe(0.5)

        env:SetSpeed(2)
        scheduler.frame(0)
        scheduler.frame(0.25)

        expect(env:GetTime()).toBe(1)

        env:Pause()
        scheduler.frame(0)
        scheduler.frame(3)

        expect(env:GetTime()).toBe(1)

        env:Resume()
        scheduler.frame(0)
        scheduler.frame(0.25)

        expect(env:GetTime()).toBe(1.5)

        env:Clear()
        scheduler.frame(0)
        scheduler.frame(1)

        expect(env:GetTime()).toBe(1.5)

        built.restore()
      end
    )

    test("GetTime first asked after some frames counts them at the emit's speed then", function()
      local built = fresh()
      registry.register(module("waits", "Folder", waiting(10)))

      local env = effects.emit(0, harness.make("Folder"))

      scheduler.frame(0.5)
      scheduler.frame(0.25)

      expect(env:GetTime()).toBe(0.75)

      scheduler.frame(0.25)

      expect(env:GetTime()).toBe(1)

      env:Clear()
      built.restore()
    end)

    test(
      "GetTime first asked once the emit has finished answers the real seconds since it, then stands still",
      function()
        local built = fresh()
        local log = {}
        registry.register(module("waits", "Folder", function(ctx: any)
          lifetime.wait(ctx.scope, 1)
          table.insert(log, "waited")
        end))

        local env = effects.emit(0, harness.make("Folder"))

        scheduler.frame(0.5)
        scheduler.frame(0.75)
        scheduler.frame(0)

        expect(log).toEqual({ "waited" })

        scheduler.frame(0.5)

        expect(env:GetTime()).toBe(1.75)

        scheduler.frame(0)
        scheduler.frame(1)

        expect(env:GetTime()).toBe(1.75)

        built.restore()
      end
    )

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
      local token = enabled_effects.token()

      expect(token.constant).toBe(true)
      expect(token.priority).toBe(0)
      expect(token.clock.parent).toBe(clock.global)
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

    test("of two holding one key, the newest's value stands, and the older's once it ends first", function()
      local KEY = {}
      local region = {
        here = clock.new(clock.global),
        below = clock.new(clock.global),
        above = clock.global,
        nested = false,
      }

      local function hold(timeScale: number, length: number): lifetime.emit
        local emit = lifetime.emit(nil)
        local stub = {
          regionOf = function()
            return region, KEY
          end,
        }

        lifetime.run(lifetime.effect(emit, 0, stub), function(scope: lifetime.effect)
          controller.emit({ scope = scope } :: any, {
            Scope = "Parent",
            EmitDelay = 0,
            EmitDuration = length,
            TimeScale = {
              apply = function(_, write: (v: number) -> ())
                write(timeScale)
              end,
            },
          })
        end)

        lifetime.seal(emit)

        return emit
      end

      local older = hold(0.5, 2)
      local newer = hold(0.25, 1)

      scheduler.frame(0)

      expect(clock.factorOf(region.here)).toBe(0.25)

      scheduler.frame(1)
      scheduler.frame(0)

      expect(newer.done).toBe(true)
      expect(clock.factorOf(region.here)).toBe(0.5)

      scheduler.frame(1)
      scheduler.frame(0)

      expect(older.done).toBe(true)
      expect(clock.factorOf(region.here)).toBe(1)
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

        tween.play(scope, curve.new(0.75, "linear"), function() end, nil, function()
          task.spawn(function()
            -- the exit, a tween that counts itself out when it lands
            tween.play(scope, curve.new(0.5, "linear"), function() end, nil, lifetime.add(outstanding))

            landed()
          end)
        end)

        tween.wait(scope, curve.new(0.5, "linear"))

        table.insert(log, "waiting")
        lifetime.awaitJoin(outstanding)
        table.insert(log, "joined")
      end))

      effects.emit(0, harness.make("Folder"))

      -- the run ends on the second frame, the dwell on the third and the
      -- exit it files then on the fifth
      for _ = 1, 4 do
        scheduler.frame(0.25)
      end

      expect(log).toEqual({ "waiting" })

      scheduler.frame(0.25)

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

        tween.play(scope, curve.new(0.25, "linear"), function() end, nil, function()
          scope.effects.emitFromFolder(impact, ctx.ref, scope.depth + 1, scope, outstanding)
          landed()
        end)

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

            tween.play(scope, curve.new(0.5, "linear"), function() end, nil, landed)
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

      expect(log).toEqual({ "joined" })

      built.restore()
    end)
  end)

  harness.describe("a passive loop's ticks", function()
    -- a stand-in enabled module whose every tick is counted, and its ticker on
    -- a passive loop's token
    local function ticking()
      fresh()

      local ticks = { count = 0 }
      local stand = module("ticks", "Model", function()
        ticks.count += 1
      end)

      stand.constant = true
      registry.register(stand)

      local token = enabled_effects.token()

      return ticks, token, enabled_effects.ticker(harness.make("Model"), stand :: any, token, effects)
    end

    test("a plain enabled instance's ticks hang from the global clock and stop while it is paused", function()
      local ticks, token, tick = ticking()

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

    test("the per-instance window state is gone", function()
      local functions = {
        "forceEmit",
        "isForceEmitting",
        "forcedClock",
        "stopEmitDuration",
        "awaitEmitDuration",
        "setEnabledCancelToken",
        "getEnabledCancelToken",
      }

      local words = {
        "SpeedOverride",
        "SpeedTweening",
        "forceEmit",
        "isForceEmitting",
        "forcedClock",
        "stopEmitDuration",
        "awaitEmitDuration",
        "EnabledCancelToken",
      }

      for _, name in functions do
        expect((utility :: any)[name]).toBe(nil)
      end

      for _, name in { "getState", "setState", "clearState" } do
        expect((attr :: any)[name]).toBe(nil)
      end

      local function scan(dir: string)
        for _, name in fs.readDir(dir) do
          local path = `{dir}/{name}`

          if fs.isDir(path) then
            scan(path)
            continue
          end

          local source = fs.readFile(path)

          for _, word in words do
            expect(`{path}: {string.find(source, word, 1, true) ~= nil}`).toBe(`{path}: false`)
          end
        end
      end

      scan("src")
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

  harness.describe("an EmitDuration window", function()
    -- a stand-in for the three modules that open windows: a plain emit opens a
    -- window of `duration` seconds at `speed`, 1 when it is nil, and each tick
    -- of it is handed to `onTick`. the instance ticks at the default 5 a
    -- second: once as the window opens, then once a frame of 0.21
    local function windowed(duration: number, onTick: (ctx: any) -> (), speed: any?)
      local built = fresh()
      local stand = module("windows", "Model", noop)

      stand.emit = function(ctx: any)
        if ctx.constant then
          onTick(ctx)
          return
        end

        enabled_effects.window(ctx, stand, duration, speed or row(1))
      end

      stand.constant = true
      registry.register(stand)

      return harness.make("Model"), built
    end

    -- each tick as the number of its window, counted in the order the windows
    -- first ticked
    local function labelled(log: { number })
      local windows = {}

      return function(ctx: any)
        local window = ctx.scope.emit
        local index = table.find(windows, window)

        if index == nil then
          table.insert(windows, window)
          index = #windows
        end

        table.insert(log, index)
      end
    end

    test("two overlapping windows of one instance each tick to their own end", function()
      local log = {}
      local ref, built = windowed(1, labelled(log))

      local first = effects.emit(0, ref)

      scheduler.frame(0.21)
      scheduler.frame(0.21)

      local second = effects.emit(0, ref)

      for _ = 1, 5 do
        scheduler.frame(0.21)
      end

      expect(log).toEqual({ 1, 1, 1, 2, 1, 2, 1, 2, 2, 2 })
      expect(first.Finished:getStatus()).toBe("Resolved")
      expect(second.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("clearing one window's emit leaves the other ticking", function()
      local log = {}
      local ref, built = windowed(10, labelled(log))

      local first = effects.emit(0, ref)
      local second = effects.emit(0, ref)

      scheduler.frame(0.21)
      first:Clear()
      scheduler.frame(0.21)
      scheduler.frame(0.21)

      expect(log).toEqual({ 1, 2, 1, 2, 2, 2 })
      expect(first.Finished:getStatus()).toBe("Resolved")
      expect(second.Finished:getStatus()).toBe("Started")

      second:Clear()
      built.restore()
    end)

    test("the handle stays pending until the window's last tick has ended", function()
      local ref, built = windowed(0.3, function(ctx: any)
        lifetime.wait(ctx.scope, 1)
      end)

      local env = effects.emit(0, ref)

      scheduler.frame(0.21)
      scheduler.frame(0.21)

      -- the window closed at 0.42, its ticks from 0 and 0.21 still playing
      expect(env.Finished:getStatus()).toBe("Started")

      for _ = 1, 3 do
        scheduler.frame(0.21)
      end

      expect(env.Finished:getStatus()).toBe("Started")

      scheduler.frame(0.21)

      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("a window shorter than a frame still spawns its first tick", function()
      local ticks = 0
      local ref, built = windowed(0.05, function()
        ticks += 1
      end)

      local env = effects.emit(0, ref)

      scheduler.frame(0.21)

      expect(ticks).toBe(1)
      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("a window at half speed ticks at half the rate and its ticks run at half speed", function()
      local ticks = {}
      local ref, built = windowed(2, function(ctx: any)
        table.insert(ticks, ctx.scope)
        lifetime.wait(ctx.scope, 10)
      end)

      local env = effects.emit(0, ref)

      env:SetSpeed(0.5)

      for _ = 1, 10 do
        scheduler.frame(0.21)
      end

      -- the tick at the open, then one every other frame where full speed
      -- would have ticked every frame
      expect(#ticks).toBe(6)

      for _, tick in ticks do
        expect(clock.factorOf(tick.clock)).toBe(0.5)
      end

      env:Clear()
      built.restore()
    end)

    test("a paused window spawns nothing, and ticks again once resumed", function()
      local log = {}
      local ref, built = windowed(1, labelled(log))

      local env = effects.emit(0, ref)

      scheduler.frame(0.21)
      env:Pause()

      for _ = 1, 3 do
        scheduler.frame(0.21)
      end

      expect(log).toEqual({ 1, 1 })

      env:Resume()

      for _ = 1, 4 do
        scheduler.frame(0.21)
      end

      expect(log).toEqual({ 1, 1, 1, 1, 1 })
      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("SetPriority on a window's handle hands a target its ticks write over at once", function()
      local target = { Transparency = 0 }
      local ref, built = windowed(10, function(ctx: any)
        lifetime.set(lifetime.write(ctx.scope, target, "property", "Transparency"), 0.25)
        lifetime.wait(ctx.scope, 10)
      end)

      registry.register(module("writes", "Folder", function(ctx: any)
        lifetime.set(lifetime.write(ctx.scope, target, "property", "Transparency"), 0.75)
        lifetime.wait(ctx.scope, 10)
      end))

      local window = effects.emit(0, ref)
      local plain = effects.emit(0, harness.make("Folder"))

      expect(target.Transparency).toBe(0.75)

      window:SetPriority(1)

      expect(target.Transparency).toBe(0.25)

      window:SetPriority(0)

      expect(target.Transparency).toBe(0.75)

      window:Clear()
      plain:Clear()

      expect(target.Transparency).toBe(0)

      built.restore()
    end)

    test("a window whose effect is killed takes its ticks with it", function()
      local built = fresh()
      local ticks = {}
      local frames = 0
      local stand = module("windows", "Model", noop)

      stand.emit = function(ctx: any)
        if ctx.constant then
          table.insert(ticks, ctx.scope)
          lifetime.wait(ctx.scope, 10)
          return
        end

        lifetime.step(ctx.scope, function()
          frames += 1

          if frames == 2 then
            error("boom")
          end
        end)

        enabled_effects.window(ctx, stand, 10, row(1))
      end

      stand.constant = true
      registry.register(stand)

      local env = effects.emit(0, harness.make("Model"))

      local warnings = harness.captureWarnings(function()
        scheduler.frame(0.21)
        scheduler.frame(0.21)
      end)

      expect(#ticks).toBe(2)
      expect(ticks[1].state).toBe(lifetime.RELEASED)
      expect(ticks[2].state).toBe(lifetime.RELEASED)
      expect(env.Finished:getStatus()).toBe("Resolved")
      expect(#warnings > 0).toBe(true)

      built.restore()
    end)

    test("a static Speed scales the window's clock: its tick rate and its ticks", function()
      local factors = {}
      local ref, built = windowed(1, function(ctx: any)
        table.insert(factors, clock.factorOf(ctx.scope.clock))
      end, row(2))

      local env = effects.emit(0, ref)

      -- 0.11 of a frame is 0.22 of the window, past the 0.2 between ticks
      for _ = 1, 4 do
        scheduler.frame(0.11)
      end

      expect(factors).toEqual({ 2, 2, 2, 2, 2 })

      env:Clear()
      built.restore()
    end)

    test("an animated Speed moves the tick rate and the ticks in flight", function()
      local ticks = {}
      local ref, built = windowed(10, function(ctx: any)
        table.insert(ticks, ctx.scope)
        lifetime.wait(ctx.scope, 10)
      end, row(1, 0.5, 1))

      local env = effects.emit(0, ref)

      -- the window's clock at 0.875, 0.75, 0.625 then 0.5 and resting there:
      -- a tick at the open, then one each time 0.2 of the window's clock has
      -- run, where full speed would have ticked every frame
      for _ = 1, 7 do
        scheduler.frame(0.25)
      end

      expect(#ticks).toBe(5)
      expect(clock.factorOf(ticks[1].clock)).toBe(0.5)

      env:Clear()
      built.restore()
    end)

    test("a Speed that comes to rest at 0 ends the ticks still playing, then the window", function()
      local ticks = 0
      local ended = 0
      local ref, built = windowed(1, function(ctx: any)
        local scope = ctx.scope

        ticks += 1

        tween.wait(scope, curve.new(10, "linear"))

        ended += 1
      end, row(1, 0, 0.5))

      local env = effects.emit(0, ref)

      scheduler.frame(0.25)
      scheduler.frame(0.25)

      expect(ticks).toBe(1)
      expect(ended).toBe(1)
      expect(env.Finished:getStatus()).toBe("Started")

      scheduler.frame(0.25)
      scheduler.frame(0.25)

      expect(ticks).toBe(1)
      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    -- ticks that each run a timer until their clock halts
    local function halting(scopes: { any })
      return function(ctx: any)
        local scope = ctx.scope

        table.insert(scopes, scope)

        tween.wait(scope, curve.new(10, "linear"))
      end
    end

    test("a Speed ramp as long as the window ends its ticks and the handle", function()
      local scopes = {}
      local ref, built = windowed(0.5, halting(scopes), row(1, 0, 0.5))
      local env = effects.emit(0, ref)

      for _ = 1, 6 do
        scheduler.frame(0.25)
      end

      expect(#scopes > 0).toBe(true)
      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("a Speed ramp that outlasts the window keeps slowing its ticks to a halt", function()
      local scopes = {}
      local ref, built = windowed(0.25, halting(scopes), row(1, 0, 1))
      local env = effects.emit(0, ref)

      for _ = 1, 3 do
        scheduler.frame(0.25)
      end

      -- spawning stopped at 0.25, and the ramp is at 0.25 of its way down
      local factor = clock.factorOf(scopes[1].clock)

      expect(factor > 0 and factor < 1).toBe(true)
      expect(env.Finished:getStatus()).toBe("Started")

      scheduler.frame(0.25)

      expect(clock.factorOf(scopes[1].clock) < factor).toBe(true)

      for _ = 1, 3 do
        scheduler.frame(0.25)
      end

      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("a tick still in its delay when the Speed halts does not hang the handle", function()
      local after = 0
      local ref, built = windowed(1, function(ctx: any)
        lifetime.wait(ctx.scope, 2)
        after += 1
      end, row(1, 0, 0.5))

      local env = effects.emit(0, ref)

      for _ = 1, 8 do
        scheduler.frame(0.25)
      end

      expect(after).toBe(0)
      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("a window at a static Speed of 0 spawns nothing and still ends", function()
      local ticks = 0
      local ref, built = windowed(0.5, function()
        ticks += 1
      end, row(0))

      local env = effects.emit(0, ref)

      for _ = 1, 3 do
        scheduler.frame(0.21)
      end

      expect(ticks).toBe(0)
      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("only a window's tick leaves its own Speed row alone", function()
      local token = lifetime.emit(nil)
      local window = lifetime.emit(nil)
      local plain = lifetime.emit(nil)

      token.constant = true

      local passiveTick = lifetime.effect(token, 0, nil)
      local windowTick = lifetime.effect(window, 0, nil)
      local plainEffect = lifetime.effect(plain, 0, nil)

      utility.speedFrom(passiveTick, true, row(2))
      utility.speedFrom(windowTick, true, row(2))
      utility.speedFrom(plainEffect, false, row(2))

      expect(passiveTick.clock.speed).toBe(2)
      expect(windowTick.clock.speed).toBe(1)
      expect(plainEffect.clock.speed).toBe(2)

      lifetime.clear(token)
      lifetime.clear(window)
      lifetime.clear(plain)
    end)

    -- an untagged instance built after the registry is fresh, and the ticks its
    -- window dispatches as it opens and over two frames, each true when it is
    -- a tick of that instance's own module. a tick is counted rather than run,
    -- since a piece of these modules needs Studio, and a tick of anything else
    -- is dropped; a plain emit runs as it is
    local function untagged(effect: any, build: () -> Instance): (Instance, { boolean })
      local built = fresh()
      local inst = build()
      local seen = {}
      local dispatch = emitters.dispatch

      if effect.init then
        effect.init({})
      end

      registry.register(effect)
      inst:SetAttribute("EmitDuration", 1)

      emitters.dispatch = function(obj: any, fx: any, shared: any, ticked: any, constant: boolean?)
        if not constant then
          dispatch(obj, fx, shared, ticked, constant)
          return
        end

        if obj == inst then
          table.insert(seen, ticked == effect)
        end
      end

      local env = effects.emit(0, inst)

      scheduler.frame(0.21)
      scheduler.frame(0.21)

      emitters.dispatch = dispatch
      env:Clear()

      if effect.deinit then
        effect.deinit()
      end

      built.restore()

      return inst, seen
    end

    test("an untagged mesh window ticks", function()
      local model, seen = untagged(mesh, function()
        local model = harness.make("Model", harness.make("Folder"))
        local start = harness.make("Part", model)
        local goal = harness.make("Part", model)

        start.Name = "Start"
        goal.Name = "End"

        return model
      end)

      expect(seen).toEqual({ true, true, true })
      expect(model:HasTag(utility.ENABLED_VFX_TAG)).toBe(false)
    end)

    -- a bolt as its emit needs it to reach the window: under a part, with its
    -- points and its template
    local function bolt(tag: string)
      return function()
        local att = harness.make("Attachment", harness.make("Part"))
        local points = harness.make("Attachment", att)

        att:AddTag(tag)
        points.Name = "Points"
        harness.make("Part", att)

        return att
      end
    end

    test("an untagged lightning window ticks", function()
      local att, seen = untagged(lightning, bolt(utility.LIGHTNING_TAG))

      expect(seen).toEqual({ true, true, true })
      expect(att:HasTag(utility.ENABLED_VFX_TAG)).toBe(false)
    end)

    test("an untagged bezier window ticks", function()
      local att, seen = untagged(bezier, bolt(utility.BEZIER_TAG))

      expect(seen).toEqual({ true, true, true })
      expect(att:HasTag(utility.ENABLED_VFX_TAG)).toBe(false)
    end)
  end)

  harness.describe("a clone of what an author made", function()
    -- the engine's Clone, which answers nil for an instance whose Archivable
    -- is false; lune's clones one anyway. every write is counted
    local function authored(archivable: boolean, throws: boolean?)
      local state = { Archivable = archivable }
      local inst = { writes = 0 }

      function inst.Clone()
        if throws then
          error("clone refused")
        end

        return if state.Archivable then { Archivable = true } else nil
      end

      return setmetatable(inst, {
        __index = state,
        __newindex = function(_, key: string, value: any)
          inst.writes += 1
          state[key] = value
        end,
      }) :: any
    end

    test("one that is not archivable is cloned and left as it was", function()
      local inst = authored(false)
      local copy = utility.clone(inst)

      expect(copy ~= nil).toBe(true)
      expect(inst.Archivable).toBe(false)
    end)

    test("one that is not archivable is left as it was when its clone throws", function()
      local inst = authored(false, true)

      local ok, err = pcall(utility.clone, inst)

      expect(ok).toBe(false)
      expect(string.find(tostring(err), "clone refused", 1, true) ~= nil).toBe(true)
      expect(inst.Archivable).toBe(false)
    end)

    test("one that is archivable is cloned with nothing written to it", function()
      local inst = authored(true)
      local copy = utility.clone(inst)

      expect(copy ~= nil).toBe(true)
      expect(inst.Archivable).toBe(true)
      expect(inst.writes).toBe(0)
    end)

    -- cannot fail against the original bug under lune: the mock's Clone does not
    -- answer nil for an instance that is not archivable
    test("a beam that is not archivable plays out and is left as it was", function()
      local built = fresh()
      registry.register(require("@vfx/beam"))

      local part = harness.make("Part")
      local beam = harness.make("Beam", part) :: any

      beam.Archivable = false
      beam.Attachment0 = harness.make("Attachment", part)
      beam.Attachment1 = harness.make("Attachment", part)
      beam:SetAttribute("EffectDuration", harness.datatypes.NumberRange.new(0.5, 0.5))
      beam:SetAttribute("LengthScale", 2)

      local env = effects.emit(0, beam)

      scheduler.frame(0.25)
      scheduler.frame(0.25)
      scheduler.frame(0.25)

      expect(env.Finished:getStatus()).toBe("Resolved")
      expect(beam.Archivable).toBe(false)

      built.restore()
    end)
  end)

  harness.describe("a beam", function()
    -- a beam between two attachments of one part, its rows authored as given
    local function beamOf(attributes: { [string]: any })
      local built = fresh()
      registry.register(require("@vfx/beam"))

      local part = harness.make("Part")
      local beam = harness.make("Beam", part) :: any

      beam.Attachment0 = harness.make("Attachment", part)
      beam.Attachment1 = harness.make("Attachment", part)

      for name, v in attributes do
        beam:SetAttribute(name, v)
      end

      return beam, built
    end

    test("a beam plays out its duration on its clock, then its handle resolves", function()
      local beam, built = beamOf({ EffectDuration = harness.datatypes.NumberRange.new(0.5, 0.5), Speed = 0.5 })
      local env = effects.emit(0, beam)

      scheduler.frame(0.25)
      scheduler.frame(0.25)
      scheduler.frame(0.25)

      expect(env.Finished:getStatus()).toBe("Started")

      scheduler.frame(0.25)
      scheduler.frame(0.25)

      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("a beam whose Speed rests at 0 ends rather than holding", function()
      local beam, built = beamOf({ Speed = 0 })
      local env = effects.emit(0, beam)

      scheduler.frame(0.25)

      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

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

    test("a LengthScale of 1 leaves an attachment the game moved where it is", function()
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

      local env = effects.emit(0, beam)

      scheduler.frame(0)

      a1.CFrame = CFrame.new(0, 0, 20)

      env:Clear()

      expect(a1.CFrame).toEqual(CFrame.new(0, 0, 20))

      built.restore()
    end)
  end)

  harness.describe("a line's emission", function()
    -- a line whose rays all land, so the pieces it makes are the ones the
    -- pool hands out
    local function pieces(frames: number, deltaTime: number, authored: { [string]: any }): number
      local built = fresh()
      local line = require("@vfx/shockwave_line")
      local raycast = workspace.Raycast
      local params = RaycastParams
      local Vector3 = harness.datatypes.Vector3

      -- selene: allow(unscoped_variables, incorrect_standard_library_use)
      RaycastParams = {
        new = function()
          return { AddToFilter = noop }
        end,
      }
      workspace.Raycast = function()
        return {
          Instance = { Color = harness.datatypes.Color3.new(1, 1, 1), Transparency = 0 },
          Material = Enum.Material.Plastic,
          Position = Vector3.zero,
          Normal = Vector3.yAxis,
        }
      end
      workspace.Terrain = workspace.Terrain or {}

      registry.register(require("@vfx/shockwave"))
      registry.register(table.clone(line))
      local fake = fake_pool.start(LISTS)

      local extents = utility.getTransformedOriginExtents
      utility.getTransformedOriginExtents = function()
        return harness.datatypes.CFrame.identity
      end

      local origin = harness.make("Attachment", harness.make("Folder"))
      origin:AddTag("Shockwave")
      origin:SetAttribute("RayDirection", Vector3.new(0, -50, 0))

      local lines = harness.make("Folder", origin)
      lines.Name = "Lines"

      local ref = harness.make("Part", lines)
      ref:SetAttribute("Direction", Vector3.new(0, 0, -1))

      for key, v in authored do
        ref:SetAttribute(key, v)
      end

      -- lune keeps a native vector apart from a Vector3, so the piece rows'
      -- vector defaults and the size's grow from zero are authored over
      ref:SetAttribute("OffsetIn", Vector3.zero)
      ref:SetAttribute("SizeScaleIn", Vector3.one)
      ref:SetAttribute(mods.attrName("attribute", "SizeScaleIn"), frame.frame(codec.encode({ lanes = { start = {} } })))

      local env = effects.emit(0, ref)

      for _ = 1, frames do
        scheduler.frame(deltaTime)
      end

      env:Clear()
      fake_pool.stop(fake)
      workspace.Raycast = raycast
      utility.getTransformedOriginExtents = extents
      RaycastParams = params
      built.restore()

      return fake.made
    end

    test("emits every piece of a fixed amount even where the summed deltas fall short", function()
      -- 0.3 s at sixtieths summed a float short of the third tick
      expect(pieces(30, 1 / 60, { Duration = 0.3, FixedAmount = 3 })).toBe(3)
      expect(pieces(100, 1 / 120, { Duration = 0.5, FixedAmount = 7 })).toBe(7)
      expect(pieces(60, 1 / 30, { Duration = 1, FixedAmount = 4 })).toBe(4)
    end)

    test("a rate line counts the frame that ends its sweep toward a piece", function()
      -- the sweep ends a frame after the summed deltas reach it, and that
      -- frame's time is what lands the last piece
      expect(pieces(80, 1 / 240, { Duration = 0.25, Rate = 20 })).toBe(5)
      expect(pieces(100, 1 / 240, { Duration = 0.3, Rate = 10 })).toBe(3)
      expect(pieces(100, 1 / 240, { Duration = 0.3, Rate = 20 })).toBe(6)
      expect(pieces(60, 1 / 60, { Duration = 0.5, Rate = 10 })).toBe(5)
    end)
  end)
end)
