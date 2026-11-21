local fs = require("@lune/fs")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local pool = require("@srv/pool")
local mover = require("@srv/mover")
local attr = require("@mod/attributes")
local clock = require("@mod/clock")
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local value = require("@mod/value")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local curves = require("@mod/curves")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local utility = require("@mod/utility")
local emitters = require("@root/emitters")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local fake_pool = require("@tests/fake_pool")
local containers = require("@srv/containers")
local bezier_common = require("@mod/common/bezier")
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

    -- three folders of a module that notes the frame each one started in,
    -- emitted on a budget so small that one job spends it
    local function budgeted(options: { [string]: any }?)
      local built = fresh()
      local frame = 0
      local started = {}

      registry.register(module("notes", "Folder", function(ctx: any)
        table.insert(started, `{ctx.ref.Name}@{frame}`)
      end))

      local folders = {}

      for _, name in { "a", "b", "c" } do
        local folder = harness.make("Folder")
        folder.Name = name
        table.insert(folders, folder)
      end

      local budget = effects.budget
      effects.budget = 1e-9

      local env = if options ~= nil
        then effects.emit(0, folders[1], folders[2], folders[3], options)
        else effects.emit(0, folders[1], folders[2], folders[3])

      effects.budget = budget

      local function step()
        frame += 1
        scheduler.frame(1 / 60)
      end

      return env, started, step, built
    end

    test("an emit past its budget starts the rest one frame at a time, and ends after the last", function()
      local env, started, step, built = budgeted()

      expect(started).toEqual({ "a@0" })
      expect(env.Finished:getStatus()).toBe("Started")

      step()
      expect(started).toEqual({ "a@0", "b@1" })

      step()
      expect(started).toEqual({ "a@0", "b@1", "c@2" })
      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("a budget of 0 in the options starts every effect in the call", function()
      local env, started, _, built = budgeted({ budget = 0 })

      expect(started).toEqual({ "a@0", "b@0", "c@0" })
      expect(env.Finished:getStatus()).toBe("Resolved")

      built.restore()
    end)

    test("a clear starts none of the effects still waiting for their frame", function()
      local env, started, step, built = budgeted()

      env:Clear()

      expect(env.Finished:getStatus()).toBe("Resolved")

      step()
      step()
      expect(started).toEqual({ "a@0" })

      built.restore()
    end)

    test("a paused emit starts nothing until it resumes", function()
      local env, started, step, built = budgeted()

      env:Pause()
      step()
      step()
      expect(started).toEqual({ "a@0" })

      env:Resume()
      step()
      expect(started).toEqual({ "a@0", "b@3" })

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
  -- runs through, on a stand-in rather than bezier or lightning themselves,
  -- whose emission frame and hitbox need Studio
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

    test("an unwritten Rate ticks at the row's own default, the one the plugin shows", function()
      fresh()

      local ticks = { count = 0 }
      local stand = module("paced", "Model", function()
        ticks.count += 1
      end)

      stand.constant = true
      stand.attributes.Rate = knob(20)
      registry.register(stand)

      local token = enabled_effects.token()
      local tick = enabled_effects.ticker(harness.make("Model"), stand :: any, token, effects)

      -- the first at once, the next a tenth of a second on: due at 20 a second, not yet at 5
      tick(0)
      tick(0.1)
      expect(ticks.count).toBe(2)

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
    -- is dropped; a plain emit runs as it is. `prepare` runs once the module
    -- is registered, for a state only the runtime's own calls reach
    local function untagged(
      effect: any,
      build: () -> Instance,
      prepare: ((inst: Instance) -> ())?
    ): (Instance, { boolean })
      local built = fresh()
      local inst = build()
      local seen = {}
      local dispatch = emitters.dispatch

      if effect.init then
        effect.init({})
      end

      registry.register(effect)
      inst:SetAttribute("EmitDuration", 1)

      if prepare then
        prepare(inst)
      end

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

    -- a mesh model with its Start and End, switched on as the panel leaves
    -- it: Enabled and the tag together
    local function meshModel()
      local model = harness.make("Model", harness.make("Folder"))
      local start = harness.make("Part", model)
      local goal = harness.make("Part", model)

      start.Name = "Start"
      goal.Name = "End"
      model:SetAttribute("Enabled", true)
      model:AddTag(utility.ENABLED_VFX_TAG)

      return model
    end

    -- switched off in edit mode, a model loses its tag, so the state is
    -- reached through the switch: a tagged and disabled model is one edit
    -- mode never holds
    test("a mesh switched off in edit mode still runs its EmitDuration window", function()
      local model, seen = untagged(mesh, meshModel, function(inst: Instance)
        enabled_effects.switch(inst, false)
      end)

      expect(model:HasTag(utility.ENABLED_VFX_TAG)).toBe(false)
      expect(seen).toEqual({ true, true, true })
    end)

    test("a switched on mesh's plain emit switches it off and runs its window", function()
      local model, seen = untagged(mesh, meshModel)

      expect(model:GetAttribute("Enabled")).toBe(false)
      expect(seen).toEqual({ true, true, true })
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

    -- the beam's property rows as an emit reads them, for a beam whose
    -- properties are `props` and whose attributes are `attributes`
    local function beamRows(props: { [string]: any }, attributes: { [string]: any })
      local beam, built = beamOf(attributes)

      for name, v in props do
        beam[name] = v
      end

      local module = require("@vfx/beam")
      local _, rows = reader.resolve(module :: any, { ref = beam, obj = beam, effect = module } :: any)

      return rows, built
    end

    -- v2.1 through v2.4.0 played these quads only when they moved, so a still
    -- one left the beam's own property, which every v2 asset was authored
    -- against
    test("a still old quad on a curve size or texture row keeps the beam's property", function()
      local rows, built = beamRows({ CurveSize0 = 15, CurveSize1 = 4, TextureSpeed = 2, TextureLength = 3 }, {
        CurveSize0_Start = -22.5,
        CurveSize0_End = -22.5,
        CurveSize1_Start = 7,
        CurveSize1_End = 7,
        Speed_Texture_Start = 9,
        Speed_Texture_End = 9,
        Length_Texture_Start = 5,
        Length_Texture_End = 5,
      })

      for name, rest in { CurveSize0 = 15, CurveSize1 = 4, TextureSpeed = 2, TextureLength = 3 } do
        expect(rows[name].animated).toBe(false)
        expect(rows[name].at(0.5)).toBe(rest)
      end

      built.restore()
    end)

    -- v2 ran a beam's clock at 1 unless its Speed quad moved
    test("a still old Speed quad leaves a beam's clock at 1", function()
      local beam, built = beamOf({ Speed_Start = 2, Speed_End = 2 })
      local module = require("@vfx/beam")
      local attrs = reader.resolve(module :: any, { ref = beam, obj = beam, effect = module } :: any)

      expect(attrs.Speed.animated).toBe(false)
      expect(attrs.Speed.at(0)).toBe(1)

      built.restore()

      local moving, again = beamOf({ Speed_Start = 2, Speed_End = 1 })
      local ramp = reader.resolve(module :: any, { ref = moving, obj = moving, effect = module } :: any)

      expect(ramp.Speed.animated).toBe(true)
      expect(ramp.Speed.at(0)).toBe(2)

      again.restore()
    end)

    test("a moving old quad on a curve size or texture row still tweens", function()
      local rows, built = beamRows({ CurveSize0 = 15, TextureSpeed = 2, TextureLength = 3 }, {
        CurveSize0_Start = -22.5,
        CurveSize0_End = 0,
        Speed_Texture_Start = 1,
        Speed_Texture_End = 9,
        Length_Texture_Start = 5,
        Length_Texture_End = 1,
      })

      expect(rows.CurveSize0.animated).toBe(true)
      expect(rows.CurveSize0.at(0)).toBe(-22.5)
      expect(rows.TextureSpeed.at(0)).toBe(1)
      expect(rows.TextureLength.at(0)).toBe(5)

      built.restore()
    end)

    -- a lane the plugin converted out of a still quad before the quad read as
    -- none, its lone tween marked seedable
    local function laned(name: string, from: number, to: number, seedable: boolean)
      local entry = {
        kind = "tween",
        chain = false,
        start = value.lit(from),
        finish = value.lit(to),
        seedable = if seedable then true else nil,
      }

      return {
        [mods.attrName("property", name)] = frame.frame(codec.encode({ lanes = { start = { entry } } })),
      }
    end

    test("a converted still lane on a curve size reads as none and keeps the beam's property", function()
      local rows, built = beamRows({ CurveSize0 = 15 }, laned("CurveSize0", -22.5, -22.5, true))

      expect(rows.CurveSize0.animated).toBe(false)
      expect(rows.CurveSize0.at(0.5)).toBe(15)

      built.restore()
    end)

    test("a still lane the plugin did not convert keeps applying", function()
      local rows, built = beamRows({ CurveSize0 = 15 }, laned("CurveSize0", -22.5, -22.5, false))

      expect(rows.CurveSize0.at(0.5)).toBe(-22.5)

      built.restore()
    end)

    test("a converted moving lane on a curve size keeps tweening", function()
      local rows, built = beamRows({ CurveSize0 = 15 }, laned("CurveSize0", -22.5, 0, true))

      expect(rows.CurveSize0.animated).toBe(true)
      expect(rows.CurveSize0.at(0)).toBe(-22.5)

      built.restore()
    end)

    -- v2.4.0 applied a still Length_Scale only where the texture length
    -- started away from 1, its Length_Texture_Start or else the beam's own,
    -- since it compared the texture length where it meant the length scale
    test("an old still LengthScale applies only where the texture length starts away from 1", function()
      const NumberRange = harness.datatypes.NumberRange
      const two = NumberRange.new(2, 2)

      for _, case in
        {
          { texture = 1, extra = {}, want = 1 },
          { texture = 3, extra = {}, want = 2 },
          { texture = 1, extra = { Length_Texture_Start = 3, Length_Texture_End = 3 }, want = 2 },
          { texture = 1, extra = { Length_Texture_Start = 3, Length_Texture_End = 5 }, want = 2 },
          { texture = 3, extra = { Length_Texture_Start = 1, Length_Texture_End = 5 }, want = 1 },
        }
      do
        const attributes = { Length_Scale_Start = two, Length_Scale_End = two }

        for k, v in case.extra do
          attributes[k] = v
        end

        local beam, built = beamOf(attributes)
        beam.TextureLength = case.texture

        const module = require("@vfx/beam")
        const attrs = reader.resolve(module :: any, { ref = beam, obj = beam, effect = module } :: any)

        expect(attrs.LengthScale.at(0)).toBe(case.want)
        expect(attrs.LengthScale.at(0.5)).toBe(case.want)

        built.restore()
      end
    end)

    -- a lane an earlier plugin converted the same quad into, its ends draws of
    -- one value, under the old spelling the convert kept
    test("a converted still LengthScale lane under the old spelling is gated alike", function()
      for texture, want in { [1] = 1, [3] = 2 } do
        const entry = {
          kind = "tween",
          chain = false,
          start = value.draw(2, 2),
          finish = value.draw(2, 2),
          seedable = true,
        }

        local beam, built = beamOf({
          [mods.attrName("attribute", "Length_Scale")] = frame.frame(codec.encode({ lanes = { start = { entry } } })),
        })

        beam.TextureLength = texture

        const module = require("@vfx/beam")
        const attrs = reader.resolve(module :: any, { ref = beam, obj = beam, effect = module } :: any)

        expect(attrs.LengthScale.at(0)).toBe(want)

        built.restore()
      end
    end)

    -- the card writes LengthScale under its own name, a value or a lane, and
    -- neither is old: both apply at any texture length, as before
    test("a LengthScale written under its own name applies at a texture length of 1", function()
      const entry = { kind = "tween", chain = false, start = value.lit(2), finish = value.lit(2) }

      for _, attributes in
        {
          { LengthScale = 2 },
          {
            [mods.attrName("attribute", "LengthScale")] = frame.frame(codec.encode({ lanes = { start = { entry } } })),
          },
        }
      do
        local beam, built = beamOf(attributes)
        beam.TextureLength = 1

        const module = require("@vfx/beam")
        const attrs = reader.resolve(module :: any, { ref = beam, obj = beam, effect = module } :: any)

        expect(attrs.LengthScale.at(0)).toBe(2)

        built.restore()
      end
    end)

    test("a still old width quad is still applied, as v2 applied it", function()
      local rows, built = beamRows({ Width0 = 1 }, { Width0_Start = 3, Width0_End = 3 })

      expect(rows.Width0.at(0.5)).toBe(3)

      built.restore()
    end)

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

    test("an emitted beam's copy starts its texture at the TextureOffset row", function()
      local built = fresh()

      registry.register(require("@vfx/beam"))

      local fake = fake_pool.start({ Beam = { "Enabled" } })
      local part = harness.make("Part")
      local beam = harness.make("Beam", part) :: any

      beam.Attachment0 = harness.make("Attachment", part)
      beam.Attachment1 = harness.make("Attachment", part)
      beam:SetAttribute("TextureOffset", 0.25)

      table.clear(harness.textureOffsets)

      local env = effects.emit(0, beam)

      scheduler.frame(0.25)

      local calls = harness.textureOffsets

      expect(#calls).toBe(1)
      expect(calls[1].offset).toBe(0.25)
      expect(calls[1].id ~= beam:GetDebugId()).toBe(true)

      env:Clear()
      fake_pool.stop(fake)
      built.restore()
    end)

    -- a tween from 0 to 1 over the effect on the TextureOffset row
    local function offsetTween(): { [string]: any }
      local entry = { kind = "tween", chain = false, start = value.lit(0), finish = value.lit(1) }

      return {
        [mods.attrName("attribute", "TextureOffset")] = frame.frame(codec.encode({ lanes = { start = { entry } } })),
      }
    end

    -- a beam's copy emitted from a pool, with the TextureOffset calls made
    -- from the emit on
    local function offsetsOf(module: any, attributes: { [string]: any }, frames: number): { number }
      local built = fresh()

      registry.register(module)

      local fake = fake_pool.start({ Beam = { "Enabled" } })
      local part = harness.make("Part")
      local beam = harness.make("Beam", part) :: any

      beam.Attachment0 = harness.make("Attachment", part)
      beam.Attachment1 = harness.make("Attachment", part)

      for name, v in attributes do
        beam:SetAttribute(name, v)
      end

      table.clear(harness.textureOffsets)

      local env = effects.emit(0, beam)

      for _ = 1, frames do
        scheduler.frame(0.25)
      end

      local out = {}

      for _, call in harness.textureOffsets do
        table.insert(out, call.offset)
      end

      expect(beam:GetAttribute("TextureOffset")).toBe(attributes.TextureOffset)

      env:Clear()
      fake_pool.stop(fake)
      built.restore()

      return out
    end

    test("a modifier on TextureOffset moves the copy's scroll every frame of the effect", function()
      local attributes = offsetTween()

      attributes.TextureOffset = 0

      local calls = offsetsOf(require("@vfx/beam"), attributes, 3)

      expect(#calls > 1).toBe(true)
      expect(calls[1]).toBe(0)

      for i = 2, #calls do
        expect(calls[i] > calls[i - 1]).toBe(true)
      end
    end)

    -- an older module (3.0.1) read TextureOffset as a plain row and wrote it
    -- once: a queue the plugin writes on it now must leave that write alone.
    -- the stand in is today's beam with that row, its emit handed the plain
    -- value as the still track today's emit takes
    test("a queue on a TextureOffset row that takes no modifiers changes nothing it writes", function()
      local beam = require("@vfx/beam")
      local plain = table.clone(beam)

      plain.attributes = table.clone(beam.attributes)
      plain.attributes.TextureOffset = knob(0):label("TextureOffset")
      plain.emit = function(ctx: any, attrs: any, props: any)
        local offset = attrs.TextureOffset

        expect(offset).toBe(0.25)

        local still = {
          animated = false,
          duration = 0,
          at = function()
            return offset
          end,
        }

        return beam.emit(ctx, setmetatable({ TextureOffset = still }, { __index = attrs }), props)
      end

      local attributes = offsetTween()

      attributes.TextureOffset = 0.25

      local warnings = harness.captureWarnings(function()
        local calls = offsetsOf(plain, attributes, 3)

        expect(calls).toEqual({ 0.25 })
      end)

      expect(warnings).toEqual({})
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

    test("a beam's copy keeps the effects nested under it, and emits them", function()
      local built = fresh()
      local seen = {}

      registry.register(require("@vfx/beam"))
      registry.register(module("counts", "Folder", counting(seen)))

      local fake = fake_pool.start({ Beam = { "Enabled" }, Folder = {} })
      local part = harness.make("Part")
      local beam = harness.make("Beam", part) :: any
      local child = harness.make("Folder", beam)

      child.Name = "child"
      beam.Attachment0 = harness.make("Attachment", part)
      beam.Attachment1 = harness.make("Attachment", part)

      local env = effects.emit(0, beam)

      scheduler.frame(0.25)

      expect(seen.child).toBe(0.25)

      env:Clear()
      fake_pool.stop(fake)
      built.restore()
    end)

    -- the Transparency row's modifiers wrote over the scaled keypoints, so a
    -- beam saved with a TransparencyScale lost it on the row's first write
    test("a still TransparencyScale scales what the Transparency row writes", function()
      local built = fresh()
      local NumberSequence = harness.datatypes.NumberSequence
      registry.register(require("@vfx/beam"))

      local fake = fake_pool.start({ Beam = { "Enabled", "Transparency" } })
      local fromExisting = fake.engine.fromExisting
      local copies = {}

      fake.engine.fromExisting = function(source: Instance)
        local copy = fromExisting(source)

        table.insert(copies, copy)

        return copy
      end

      local part = harness.make("Part")
      local beam = harness.make("Beam", part) :: any
      local entry = {
        kind = "tween",
        chain = false,
        start = value.lit(NumberSequence.new(0.4)),
        finish = value.lit(NumberSequence.new(0.8)),
      }

      beam.Attachment0 = harness.make("Attachment", part)
      beam.Attachment1 = harness.make("Attachment", part)
      beam:SetAttribute("TransparencyScale", 0.5)
      beam:SetAttribute(
        mods.attrName("property", "Transparency"),
        frame.frame(codec.encode({ lanes = { start = { entry } } }))
      )

      local env = effects.emit(0, beam)

      scheduler.frame(0)

      local copy = copies[1] :: any
      local first = copy.Transparency.Keypoints[1].Value

      expect(math.abs(first - 0.2) < 1e-3).toBe(true)

      env:Clear()
      fake_pool.stop(fake)
      built.restore()
    end)

    test("a reused throwaway attachment starts where the authored one is", function()
      local built = fresh()
      local CFrame = harness.datatypes.CFrame
      registry.register(require("@vfx/beam"))

      local fake = fake_pool.start({ Beam = { "Enabled" }, Attachment = { "Visible", "CFrame" } })

      -- a beam scaled by 2 between attachments at `z0` and `z1`, answering
      -- where its throwaway attachments are after one frame
      local function scaled(z0: number, z1: number): { CFrame }
        local part = harness.make("Part")
        local a0 = harness.make("Attachment", part)
        local a1 = harness.make("Attachment", part)
        local beam = harness.make("Beam", part) :: any

        a0.CFrame = CFrame.new(0, 0, z0)
        a1.CFrame = CFrame.new(0, 0, z1)
        beam.Attachment0 = a0
        beam.Attachment1 = a1
        beam:SetAttribute("LengthScale", 2)

        local env = effects.emit(0, beam)

        scheduler.frame(0)

        local found = {}

        for _, inst in part:GetChildren() do
          if inst.Name == "_ForgeTempAttachment" then
            table.insert(found, (inst :: Attachment).CFrame)
          end
        end

        env:Clear()

        return found
      end

      scaled(100, 140)

      local made = fake.made
      local found = scaled(0, 10)

      expect(fake.made).toBe(made)
      expect(found[1]).toEqual(CFrame.new(0, 0, -5))
      expect(found[2]).toEqual(CFrame.new(0, 0, 15))

      fake_pool.stop(fake)
      built.restore()
    end)
  end)

  harness.describe("a line's emission", function()
    -- a line whose rays all land, so the pieces it makes are the ones the
    -- pool hands out; given `watch`, the rays land at `hit`, the mover never
    -- lands a write and `watch` sees the pool's folder before the clear
    local function pieces(
      frames: number,
      deltaTime: number,
      authored: { [string]: any },
      hit: Vector3?,
      watch: ((folder: Instance) -> ())?
    ): number
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
          Instance = {
            Color = harness.datatypes.Color3.new(1, 1, 1),
            Transparency = 0,
            IsA = function()
              return false
            end,
          },
          Material = Enum.Material.Plastic,
          Position = hit or Vector3.zero,
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

      -- the container the Exclude filter leaves out, which lune cannot make
      const root = containers.root
      const stand = harness.make("Part")
      containers.root = function()
        return stand :: any
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

      local after = scheduler.after

      if watch ~= nil then
        scheduler.after = nil
      end

      local env = effects.emit(0, ref)

      for _ = 1, frames do
        scheduler.frame(deltaTime)
      end

      if watch ~= nil then
        watch(fake.folder)
      end

      scheduler.after = after
      env:Clear()
      fake_pool.stop(fake)
      workspace.Raycast = raycast
      utility.getTransformedOriginExtents = extents
      containers.root = root
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

    test("a taken piece stands where its ray landed before the mover lands anything", function()
      local Vector3 = harness.datatypes.Vector3
      local positions = {}

      pieces(30, 1 / 60, { Duration = 0.3, FixedAmount = 1 }, Vector3.new(0, 0, 7), function(folder: Instance)
        for _, piece in folder:GetChildren() do
          table.insert(positions, (piece :: BasePart).CFrame.Position)
        end
      end)

      expect(positions).toEqual({ Vector3.new(0, 0, 7) })
    end)
  end)

  harness.describe("a mesh's pieces", function()
    type Seen = {
      count: number,
      id: string,
      cframe: CFrame,
      tagged: boolean,
      attributes: number,
      transparency: number?,
    }

    -- a mesh whose start is a MeshPart, emitted twice on the pool, its origin
    -- at a new height each time, and the piece each emit holds a frame in;
    -- `decal` gives the start and end a decal of differing colors, `rest` the
    -- start's decal a Transparency attribute, `stored` more attributes on that
    -- decal, `life` the model's EffectDuration, `onModel` attributes on the
    -- model itself, and with `flush` off the mover never lands a write
    local function emitTwice(
      decal: boolean,
      flush: boolean,
      rest: number?,
      stored: { [string]: any }?,
      life: number?,
      onModel: { [string]: any }?
    )
      local built = fresh()
      local CFrame = harness.datatypes.CFrame
      local Color3 = harness.datatypes.Color3

      registry.register(require("@vfx/mesh"))
      local fake = fake_pool.start({ MeshPart = LISTS.Part, Decal = { "Color3", "Transparency" } })

      local height = 0
      local extents = utility.getTransformedOriginExtents
      utility.getTransformedOriginExtents = function()
        return CFrame.new(0, height, 0)
      end

      local after = scheduler.after

      if not flush then
        scheduler.after = nil
      end

      -- lune hands out a new wrapper on every FindFirstChild, so the start
      -- each emit finds is taken as the one Studio would hand back
      local take = pool.take

      pool.take = function(holder: any, source: Instance, alone: boolean?)
        return take(holder, fake.stable(source), alone)
      end

      local model = harness.make("Model", harness.make("Folder"))
      local start = harness.make("MeshPart", model)
      local goal = harness.make("MeshPart", model)

      start.Name = "Start"
      goal.Name = "End"

      -- lune holds no default for a MeshPart's mesh
      start.MeshId = "rbxassetid://1"
      goal.MeshId = "rbxassetid://1"

      if decal then
        local from = harness.make("Decal", start) :: Decal
        local to = harness.make("Decal", goal) :: Decal

        from.Name, to.Name = "Face", "Face"
        from.Color3, to.Color3 = Color3.new(1, 0, 0), Color3.new(0, 0, 1)

        if rest ~= nil then
          from:SetAttribute("Transparency", rest)
        end

        for name, v in stored or {} do
          from:SetAttribute(name, v)
        end
      end

      if life ~= nil then
        model:SetAttribute("EffectDuration", harness.datatypes.NumberRange.new(life, life))
      end

      for name, v in onModel or {} do
        model:SetAttribute(name, v)
      end

      local seen: { Seen } = {}

      for _, y in { 5, 9 } do
        height = y

        local env = effects.emit(0, model)

        scheduler.frame(0.1)

        local pieces = fake.folder:GetChildren()
        local face = pieces[1]:FindFirstChildOfClass("Decal")
        local attributes = 0

        for _ in if face ~= nil then face:GetAttributes() else {} do
          attributes += 1
        end

        table.insert(seen, {
          count = #pieces,
          id = pieces[1]:GetDebugId(),
          cframe = pieces[1].CFrame,
          tagged = pieces[1]:HasTag(utility.CLEANUP_TAG),
          attributes = attributes,
          transparency = if face ~= nil then face.Transparency else nil,
        })

        env:Clear()
      end

      local stats = pool.stats()

      fake_pool.stop(fake)
      pool.take = take
      scheduler.after = after
      utility.getTransformedOriginExtents = extents
      built.restore()

      return seen, fake.made, stats
    end

    test("a MeshPart piece is the pool's, moved by the mover, and comes back for the next emit", function()
      local seen, made = emitTwice(false, true)

      expect(made).toBe(1)
      expect(seen[1].count).toBe(1)
      expect(seen[2].id).toBe(seen[1].id)
      expect(seen[1].cframe.Position).toEqual(harness.datatypes.Vector3.new(0, 5, 0))
      expect(seen[1].tagged).toBe(false)
    end)

    test("a taken piece stands at its first pose before the mover lands anything", function()
      local seen = emitTwice(false, false)

      expect(seen[1].cframe.Position).toEqual(harness.datatypes.Vector3.new(0, 5, 0))
      expect(seen[2].id).toBe(seen[1].id)
      expect(seen[2].cframe.Position).toEqual(harness.datatypes.Vector3.new(0, 9, 0))
    end)

    test("a start carrying a decal is cloned whole for every emit", function()
      local seen, made, stats = emitTwice(true, true)

      expect(made).toBe(0)
      expect(stats.fresh).toBe(2)
      expect(seen[2].id ~= seen[1].id).toBe(true)
    end)

    -- v2.4.0 faded a decal storing nothing from 0 to clear over the piece's
    -- life, which many EasyMesh imports rely on. each emit is read at
    -- mid-life, where the fade's eased curve stands at `eased`
    local function easedAtMid(): number
      return emitTwice(true, true, nil, nil, 0.2)[1].transparency :: number
    end

    test("a decal storing no fade fades from its rest toward clear", function()
      local eased = easedAtMid()
      local half = emitTwice(true, true, 0.4, nil, 0.2)
      local clear = emitTwice(true, true, 1, nil, 0.2)

      expect(eased > 0 and eased < 1).toBe(true)
      -- a Decal holds its transparency as a float
      expect(math.abs((half[1].transparency :: number) - (0.4 + 0.6 * eased)) < 1e-3).toBe(true)
      expect(clear[1].transparency).toBe(1)
    end)

    -- the missing half of an old pair reads from the default fade, whose end
    -- is clear
    test("a decal storing only an old Transparency_Start fades from it toward clear", function()
      local eased = easedAtMid()
      local mid = emitTwice(true, true, nil, { Transparency_Start = 0.5 }, 0.2)[1].transparency :: number

      expect(mid > 0.5 and mid < 1).toBe(true)
      expect(math.abs(mid - (0.5 + 0.5 * eased)) < 1e-3).toBe(true)
    end)

    test("a decal storing only an old Transparency_End fades from 0 to it", function()
      local eased = easedAtMid()
      local mid = emitTwice(true, true, nil, { Transparency_End = 0.5 }, 0.2)[1].transparency :: number

      expect(math.abs(mid - 0.5 * eased) < 1e-3).toBe(true)
    end)

    -- an older emit renamed the model's StartTransparency to
    -- Decal_StartTransparency and stored no end, which every release then read
    -- as a fade to clear
    test("a model storing only its decal's old start fades the decal to clear", function()
      for _, name in { "Decal_StartTransparency", "DecalStartTransparency", "StartTransparency" } do
        local seen = emitTwice(true, true, nil, nil, 0.2, { [name] = 0 })
        local mid = seen[1].transparency :: number

        expect(mid > 0 and mid < 1).toBe(true)
      end
    end)

    test("a model storing its decal's start and an end of 0 holds the decal", function()
      local seen = emitTwice(true, true, nil, nil, 0.2, { Decal_StartTransparency = 0, EndTransparency = 0 })
      local named = emitTwice(true, true, nil, nil, 0.2, { DecalStartTransparency = 0, DecalEndTransparency = 0 })

      expect(seen[1].transparency).toBe(0)
      expect(named[1].transparency).toBe(0)
    end)

    test("a decal's own Transparency or stored lane leads the model's old start", function()
      local start = { Decal_StartTransparency = 0 }
      local quad = { Transparency_Start = 0, Transparency_End = 0.5 }

      local clear = emitTwice(true, true, 1, nil, 0.2, start)
      local half = emitTwice(true, true, 0.4, nil, 0.2, start)
      local laned = emitTwice(true, true, nil, quad, 0.2, start)
      local alone = emitTwice(true, true, nil, quad, 0.2)

      local fromHalf = half[1].transparency :: number

      expect(clear[1].transparency).toBe(1)
      -- a Decal holds its transparency as a float, so the fade is told from a
      -- hold by a margin
      expect(fromHalf > 0.5 and fromHalf < 1).toBe(true)
      expect(math.abs((laned[1].transparency :: number) - (alone[1].transparency :: number)) < 1e-6).toBe(true)
    end)

    test("a decal's own modifier lane leads the model's old start", function()
      local held = {
        kind = "tween",
        chain = false,
        start = value.lit(0.3),
        finish = value.lit(0.3),
      }

      local lane =
        { [mods.attrName("attribute", "Transparency")] = frame.frame(codec.encode({ lanes = { start = { held } } })) }
      local seen = emitTwice(true, true, nil, lane, 0.2, { Decal_StartTransparency = 0 })

      expect(math.abs((seen[1].transparency :: number) - 0.3) < 1e-6).toBe(true)
    end)

    -- the shockwaves' old 0.5 second fade, lent by the row's name alone, cut
    -- this decal's fade short, where v2.4.0 ran it over the piece's life
    test("a decal's old fade naming no duration runs over the piece's life", function()
      local quad = { Transparency_Start = 0, Transparency_End = 1 }
      local named = table.clone(quad)

      named.Transparency_Duration = 2

      local plain = emitTwice(true, true, nil, quad, 2)
      local timed = emitTwice(true, true, nil, named, 2)
      local short = table.clone(quad)

      short.Transparency_Duration = 0.5

      local cut = emitTwice(true, true, nil, short, 2)

      expect(math.abs((plain[1].transparency :: number) - (timed[1].transparency :: number)) < 1e-6).toBe(true)
      expect((plain[1].transparency :: number) < (cut[1].transparency :: number)).toBe(true)
    end)

    test("a piece plays from the start and end the emit found, though the model lost one in its delay", function()
      local built = fresh()

      registry.register(require("@vfx/mesh"))
      local fake = fake_pool.start({ MeshPart = LISTS.Part })

      local model = harness.make("Model", harness.make("Folder"))
      local start = harness.make("MeshPart", model)
      local goal = harness.make("MeshPart", model)

      start.Name = "Start"
      goal.Name = "End"
      start.MeshId = "rbxassetid://1"
      goal.MeshId = "rbxassetid://1"
      model:SetAttribute("EmitDelay", 0.1)

      local seen = {}
      local warn = logger.warn

      logger.warn = function(...)
        table.insert(seen, table.concat({ ... }, " "))
      end

      local env = effects.emit(0, model)

      scheduler.frame(0.05)
      goal.Parent = nil
      scheduler.frame(0.1)

      local pieces = #fake.folder:GetChildren()

      env:Clear()
      logger.warn = warn
      fake_pool.stop(fake)
      built.restore()

      expect(seen).toEqual({})
      expect(pieces).toBe(1)
    end)
  end)

  harness.describe("a bezier's and a bolt's parts", function()
    type Options = {
      bits: boolean?,
      flush: boolean?,
      frames: { number },
      look: (fake: fake_pool.Fake, cleared: boolean) -> (),
    }

    -- a bolt of `effect` under a part, with its points and its template, emitted
    -- twice on the pool along a path laid along z from a height the spec raises
    -- between the emits; `authored` is written on the bolt, `bits` gives the
    -- template a child, and with `flush` off the mover lands nothing. `look`
    -- sees the pool after each emit's frames, and again once it is cleared
    local function emitTwice(effect: any, tag: string, authored: { [string]: any }, options: Options)
      local built = fresh()
      local CFrame = harness.datatypes.CFrame
      local Vector3 = harness.datatypes.Vector3

      registry.register(effect)
      local fake = fake_pool.start({ Part = LISTS.Part, Folder = {} })

      local height = 0
      local take = pool.take
      local instance = Instance
      local after = scheduler.after
      local terrain = workspace.Terrain
      local points = utility.getBezierPoints
      local extents = utility.getTransformedOriginExtents
      local getter = bezier_common.createPosGetter
      local hitbox = bezier_common.createHitboxParams
      local emission = bezier_common.calculateEmissionCFrame

      utility.getTransformedOriginExtents = function()
        return CFrame.new(0, height, 0), Vector3.zero
      end

      utility.getBezierPoints = function()
        return { vector.zero, vector.create(0, 0, 10) }
      end

      bezier_common.createPosGetter = function()
        return function(alpha: number)
          return Vector3.new(0, height, alpha * 10)
        end
      end

      -- lune has no CFrame.fromAxisAngle, and the path above ignores the frame
      bezier_common.calculateEmissionCFrame = function()
        return CFrame.identity
      end

      bezier_common.createHitboxParams = function()
        return {}
      end

      -- lune hands out a new wrapper on every FindFirstChildOfClass, so the
      -- template each emit finds is taken as the one Studio would hand back
      pool.take = function(holder: any, source: Instance, alone: boolean?)
        return take(holder, fake.stable(source), alone)
      end

      if not options.flush then
        scheduler.after = nil
      end

      -- a highlighted bolt builds its container with Instance.new
      -- selene: allow(unscoped_variables, incorrect_standard_library_use)
      Instance = harness.datatypes.Instance
      workspace.Terrain = harness.make("Folder")

      local ok, err = pcall(function()
        local bolt = harness.make("Attachment", harness.make("Part"))
        local root = harness.make("Attachment", bolt)
        local template = harness.make("Part", bolt)

        bolt:AddTag(tag)
        root.Name = "Points"

        for key, v in authored do
          bolt:SetAttribute(key, v)
        end

        if options.bits then
          harness.make("Folder", template).Name = "Bits"
        end

        for _, y in { 5, 9 } do
          height = y

          local env = effects.emit(0, bolt)

          for _, deltaTime in options.frames do
            scheduler.frame(deltaTime)
          end

          options.look(fake, false)
          env:Clear()
          options.look(fake, true)
        end
      end)

      local stats = pool.stats()

      fake_pool.stop(fake)
      pool.take = take
      Instance = instance
      scheduler.after = after
      workspace.Terrain = terrain
      utility.getBezierPoints = points
      utility.getTransformedOriginExtents = extents
      bezier_common.createPosGetter = getter
      bezier_common.createHitboxParams = hitbox
      bezier_common.calculateEmissionCFrame = emission
      built.restore()

      if not ok then
        error(err, 0)
      end

      return fake, stats
    end

    local function position(inst: Instance): Vector3
      return (inst :: BasePart).CFrame.Position
    end

    test("a bezier piece is the pool's, placed at once, then moved by the mover", function()
      local Vector3 = harness.datatypes.Vector3
      local seen = {}

      local fake = emitTwice(bezier, utility.BEZIER_TAG, {}, {
        flush = true,
        frames = { 0.25 },
        look = function(fake: fake_pool.Fake, cleared: boolean)
          if cleared then
            return
          end

          local pieces = fake.folder:GetChildren()

          table.insert(seen, { count = #pieces, id = pieces[1]:GetDebugId(), at = position(pieces[1]) })
        end,
      })

      expect(fake.made).toBe(1)
      expect(seen[1].count).toBe(1)
      expect(seen[2].id).toBe(seen[1].id)
      expect(seen[1].at).toEqual(Vector3.new(0, 5, 2.5))
      expect(seen[2].at).toEqual(Vector3.new(0, 9, 2.5))
    end)

    test("a bezier piece stands at its first pose before the mover lands anything", function()
      local Vector3 = harness.datatypes.Vector3
      local seen = {}

      emitTwice(bezier, utility.BEZIER_TAG, {}, {
        frames = { 0.25 },
        look = function(fake: fake_pool.Fake, cleared: boolean)
          if not cleared then
            table.insert(seen, position(fake.folder:GetChildren()[1]))
          end
        end,
      })

      expect(seen).toEqual({ Vector3.new(0, 5, 0), Vector3.new(0, 9, 0) })
    end)

    test("a bezier projectile starts from the pose its path left pending", function()
      local Vector3 = harness.datatypes.Vector3
      local seen = {}

      -- a projectile outliving the path, standing still where it set off
      local authored =
        { ProjectileEnabled = true, ProjectileSpeed = 0, ProjectileLifetime = harness.datatypes.NumberRange.new(2, 2) }

      emitTwice(bezier, utility.BEZIER_TAG, authored, {
        frames = { 0.5, 0.5, 0.25 },
        look = function(fake: fake_pool.Fake, cleared: boolean)
          if not cleared then
            mover.flush()
            table.insert(seen, position(fake.folder:GetChildren()[1]))
          end
        end,
      })

      expect(seen).toEqual({ Vector3.new(0, 5, 10), Vector3.new(0, 9, 10) })
    end)

    test("a bezier template with children is cloned whole for every emit", function()
      local names = {}

      local fake, stats = emitTwice(bezier, utility.BEZIER_TAG, {}, {
        bits = true,
        frames = { 0.25 },
        look = function(fake: fake_pool.Fake, cleared: boolean)
          if cleared then
            return
          end

          local bits = fake.folder:GetChildren()[1]:FindFirstChild("Bits")

          table.insert(names, if bits ~= nil then bits.Name else "none")
        end,
      })

      expect(fake.made).toBe(0)
      expect(stats.fresh).toBe(2)
      expect(names).toEqual({ "Bits", "Bits" })
    end)

    test("a bolt's segments with no nested effect are bare parts that come back for the next emit", function()
      local seen = {}

      local fake = emitTwice(lightning, utility.LIGHTNING_TAG, { Segments = 2, OffsetScale = 0 }, {
        bits = true,
        flush = true,
        frames = { 0.25 },
        look = function(fake: fake_pool.Fake, cleared: boolean)
          if cleared then
            return
          end

          for _, piece in fake.folder:GetChildren() do
            table.insert(seen, #piece:GetChildren())
          end
        end,
      })

      expect(fake.made).toBe(2)
      expect(seen).toEqual({ 0, 0, 0, 0 })
    end)

    test("a segment stands at its first pose before the mover lands anything", function()
      local Vector3 = harness.datatypes.Vector3
      local seen = {}

      emitTwice(lightning, utility.LIGHTNING_TAG, { Segments = 2, OffsetScale = 0 }, {
        frames = { 0.25 },
        look = function(fake: fake_pool.Fake, cleared: boolean)
          if cleared then
            return
          end

          for _, piece in fake.folder:GetChildren() do
            local part = piece :: BasePart

            if part.Transparency < 1 then
              table.insert(seen, part.CFrame.Position)
            end
          end
        end,
      })

      expect(seen).toEqual({ Vector3.new(0, 5, 1.25), Vector3.new(0, 9, 1.25) })
    end)

    test("a highlighted bolt's segments go back to the pool before its container goes", function()
      local held = {}
      local free = {}

      local fake = emitTwice(lightning, utility.LIGHTNING_TAG, { Segments = 2, FillTransparency = 0 }, {
        flush = true,
        frames = { 0.25 },
        look = function(fake: fake_pool.Fake, cleared: boolean)
          table.insert(held, #containers.of("lightning"):GetChildren())

          if cleared then
            table.insert(free, #fake.folder:GetChildren())
          end
        end,
      })

      expect(held).toEqual({ 1, 0, 1, 0 })
      expect(free).toEqual({ 2, 2 })
      expect(fake.made).toBe(2)
    end)

    -- the nested segment's copy is a whole clone, whose children the head
    -- carries from segment to segment and the emit's end destroys with it
    test("a head bolt's children ride its segments and go with the emit", function()
      local held = {}
      local homes = {}

      local fake, stats = emitTwice(lightning, utility.LIGHTNING_TAG, { Segments = 3, NestedEffectMode = "Head" }, {
        bits = true,
        flush = true,
        frames = { 0.5 },
        look = function(fake: fake_pool.Fake, cleared: boolean)
          for _, piece in fake.folder:GetChildren() do
            if piece:FindFirstChild("Bits") ~= nil then
              table.insert(if cleared then homes else held, piece:GetDebugId())
            end
          end
        end,
      })

      expect(fake.made).toBe(2)
      expect(stats.fresh).toBe(2)
      expect(#held).toBe(2)
      expect(#homes).toBe(0)
    end)
  end)
end)
