local attr = require("@mod/attributes")
local clock = require("@mod/clock")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local utility = require("@mod/utility")
local emitters = require("@root/emitters")
local registry = require("@mod/registry")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local enabled_effects = require("@srv/enabled_effects")
local test, expect = harness.test, harness.expect

local mesh = require("@vfx/mesh")

local custom = require("@root/sdk/custom")

-- the api registers every built-in when it first loads, so the registry is
-- emptied first and left empty for whichever spec runs next
local function api()
  registry.clear()

  local loaded = require("@root")

  registry.clear()

  return loaded :: any
end

harness.suite(function()
  harness.describe("the frame budget", function()
    test("setFrameBudget takes a finite count and refuses the rest", function()
      const vfx = api()
      const ok, err = pcall(function()
        expect(vfx.getFrameBudget()).toBe(128)

        vfx.setFrameBudget(-1)
        vfx.setFrameBudget(0 / 0)
        vfx.setFrameBudget(math.huge)

        expect(vfx.getFrameBudget()).toBe(128)

        vfx.setFrameBudget(40)

        expect(vfx.getFrameBudget()).toBe(40)
      end)

      -- put back whatever the case did, so a failure leaks no budget into the next spec
      vfx.setFrameBudget(128)

      if not ok then
        error(err, 0)
      end
    end)
  end)

  harness.describe("the global speed functions", function()
    test("read and write the global clock, a pause leaving the speed as it was", function()
      local vfx = api()

      expect(vfx.getSpeed()).toBe(1)
      expect(vfx.isPaused()).toBe(false)
      expect(vfx.getEffectiveSpeed()).toBe(1)

      vfx.setSpeed(0.5)

      expect(vfx.getSpeed()).toBe(0.5)
      expect(vfx.getEffectiveSpeed()).toBe(0.5)
      expect(clock.global.speed).toBe(0.5)

      vfx.pause()

      expect(vfx.isPaused()).toBe(true)
      expect(vfx.getSpeed()).toBe(0.5)
      expect(vfx.getEffectiveSpeed()).toBe(0.5)
      expect(clock.global.paused).toBe(true)

      vfx.resume()
      vfx.setSpeed(1)

      expect(vfx.isPaused()).toBe(false)
      expect(vfx.getEffectiveSpeed()).toBe(1)
    end)

    test("getEffectiveSpeed counts every Global controller", function()
      local vfx = api()

      clock.scale(clock.global, "a", 0.5)
      clock.scale(clock.global, "b", 0.5)

      expect(vfx.getEffectiveSpeed()).toBe(0.25)
      expect(vfx.getSpeed()).toBe(1)

      clock.unscale(clock.global, "a")
      clock.unscale(clock.global, "b")
    end)

    test("refuses a speed that is not a finite number of 0 or more, naming setSpeed", function()
      local vfx = api()

      vfx.setSpeed(0.5)

      for _, bad in { -1, 0 / 0, math.huge, "fast" :: any } do
        local ok, err = pcall(vfx.setSpeed, bad)

        expect(ok).toBe(false)
        expect(string.find(tostring(err), "setSpeed", 1, true) ~= nil).toBe(true)
      end

      expect(vfx.getSpeed()).toBe(0.5)

      vfx.setSpeed(1)
    end)

    test("a second pause or resume changes nothing and fires nothing", function()
      local vfx = api()
      local heard = {}

      local connection = vfx.PausedChanged:Connect(function(paused: boolean)
        table.insert(heard, paused)
      end)

      vfx.pause()
      vfx.pause()

      expect(vfx.isPaused()).toBe(true)

      vfx.resume()
      vfx.resume()

      connection:Disconnect()

      expect(vfx.isPaused()).toBe(false)
      expect(heard).toEqual({ true, false })
    end)

    test("the signals are the clock's, and the api table is a plain one", function()
      local vfx = api()

      expect(vfx.SpeedChanged).toBe(clock.speedChanged)
      expect(vfx.PausedChanged).toBe(clock.pausedChanged)
      expect(getmetatable(vfx)).toBe(nil)
    end)
  end)

  harness.describe("the registered effects", function()
    test("are read through a frozen view of list and get alone", function()
      local vfx = api()

      registry.register(mesh)

      expect(table.isfrozen(vfx.effects)).toBe(true)
      expect(vfx.effects.get("mesh")).toBe(mesh)
      expect(vfx.effects.list()).toEqual({ mesh })
      expect(vfx.effects.clear).toBe(nil)
      expect(vfx.effects.register).toBe(nil)

      registry.clear()
    end)

    test("knob and mod are no longer on the api", function()
      local vfx = api()

      expect(vfx.knob).toBe(nil)
      expect(vfx.mod).toBe(nil)
    end)
  end)

  harness.describe("the hook functions", function()
    test("hookProperty and hookAttribute hand back a connected hook", function()
      local vfx = api()
      local part = harness.make("Part")

      part:SetAttribute("Glow", 2)

      local transparency = vfx.hookProperty(part, "Transparency")
      local glow = vfx.hookAttribute(part, "Glow")

      expect(transparency.Connected).toBe(true)
      expect(transparency.Active).toBe(false)
      expect(transparency.Offset).toBe(0)
      expect(glow.Connected).toBe(true)
      expect(glow.Offset).toBe(0)

      transparency:Disconnect()
      glow:Disconnect()

      expect(transparency.Connected).toBe(false)
    end)
  end)

  harness.describe("emit", function()
    test("a leading number is ignored with one warning, and the instances still emit", function()
      local vfx = api()
      local part = harness.make("Part")
      local emit, setup = effects.emit, vfx.setup
      local calls = {}

      effects.emit = function(...: any)
        table.insert(calls, { ... })
        return {} :: any
      end

      vfx.setup = true

      local warnings = harness.captureWarnings(function()
        vfx.emit(2, part)
        vfx.emit(2, part)
        vfx.emit(part)
      end)

      effects.emit, vfx.setup = emit, setup

      expect(#warnings).toBe(1)
      expect(string.find(warnings[1], "scale argument was removed", 1, true) ~= nil).toBe(true)
      expect(#calls).toBe(3)

      for _, call in calls do
        expect(#call).toBe(2)
        expect(call[1]).toBe(0)
        expect(call[2]).toBe(part)
      end
    end)
  end)

  harness.describe("enable and disable", function()
    -- runs `body` against the api in a running game, with mesh registered and
    -- the passive loops started, and puts every stand-in back whether `body`
    -- passes or not. `stand.where.placed` is where an instance sits,
    -- `stand.moved` and `stand.destroyed` keep each reparent and destroy
    -- signal for the spec to fire, `stand.deinit` and `stand.init` are the
    -- api's teardown and start of the loops, `stand.tagged` is what the tag
    -- scan finds, and every tick is counted in `stand.seen` by the emit it
    -- belongs to, while a plain emit runs as it is
    local function passive(body: (stand: any) -> ())
      local vfx = api()
      local scope = {}

      local runService = game:GetService("RunService")
      local tags = game:GetService("CollectionService")
      local isRunning, getTagged = runService.IsRunning, tags.GetTagged
      local placed, moves, dispatch = enabled_effects.placed, enabled_effects.moved, emitters.dispatch

      local stand = {
        vfx = vfx,
        seen = { passive = 0, window = 0 },
        ticked = nil :: any,
        where = { placed = true },
        moved = {} :: { [Instance]: () -> () },
        destroyed = {} :: { [Instance]: () -> () },
        tagged = {} :: { Instance },
        deinit = function()
          utility.cleanupScope(scope)
        end,
        init = function()
          enabled_effects.init(scope, effects)
        end,
      }

      tags.GetTagged = function()
        return stand.tagged
      end

      registry.configure({ query = harness.query })
      harness.reset()
      registry.register(mesh)
      effects.init({ setup = true } :: any)
      enabled_effects.init(scope, effects)
      scheduler.start()

      runService.IsRunning = function()
        return true
      end

      enabled_effects.placed = function()
        return stand.where.placed
      end

      enabled_effects.moved = function(obj: Instance, callback: () -> (), destroyed: () -> ())
        stand.moved[obj] = callback
        stand.destroyed[obj] = destroyed

        return {
          function()
            stand.moved[obj] = nil
            stand.destroyed[obj] = nil
          end,
        } :: any
      end

      emitters.dispatch = function(obj: any, fx: any, shared: any, effect: any, constant: boolean?)
        if not constant then
          dispatch(obj, fx, shared, effect, constant)
          return
        end

        local kind = if fx.emit.constant then "passive" else "window"

        stand.seen[kind] += 1
        stand.ticked = effect
      end

      local ok, err = pcall(body, stand)

      custom.clear()
      utility.cleanupScope(scope)
      registry.clear()

      runService.IsRunning, tags.GetTagged = isRunning, getTagged
      enabled_effects.placed, enabled_effects.moved, emitters.dispatch = placed, moves, dispatch

      if not ok then
        error(err, 0)
      end
    end

    -- an untagged, cached mesh model that is not enabled, under `parent` or a
    -- folder of its own
    local function model(parent: Instance?): Instance
      local m = harness.make("Model", parent or harness.make("Folder"))
      local start = harness.make("Part", m)
      local goal = harness.make("Part", m)

      start.Name = "Start"
      goal.Name = "End"

      m:SetAttribute("Enabled", false)
      m:SetAttribute("EmitDuration", 1)
      attr.cache(m)

      return m
    end

    test("enable on an untagged mesh ticks with no tag added in a running game, and disable leaves no loop", function()
      passive(function(stand: any)
        local m = model()

        stand.vfx.enable(m)

        harness.render(0.21)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(2)
        expect(attr.get(m, "Enabled", false)).toBe(true)
        expect(m:HasTag(utility.ENABLED_VFX_TAG)).toBe(false)

        stand.vfx.disable(m)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(2)
        expect(attr.get(m, "Enabled", true)).toBe(false)
        expect(stand.moved[m]).toBe(nil)
      end)
    end)

    test("enable in edit mode adds the tag, and disable stops the loop and removes it", function()
      passive(function(stand: any)
        local m = model()
        local runService = game:GetService("RunService")
        local running = runService.IsRunning

        runService.IsRunning = function()
          return false
        end

        stand.vfx.enable(m)

        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)
        expect(m:HasTag(utility.ENABLED_VFX_TAG)).toBe(true)

        stand.vfx.disable(m)
        runService.IsRunning = running
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)
        expect(m:HasTag(utility.ENABLED_VFX_TAG)).toBe(false)
        expect(stand.moved[m]).toBe(nil)
      end)
    end)

    test("disable of a tagged mesh in a running game stops the loop and keeps the tag", function()
      passive(function(stand: any)
        local m = model()

        m:AddTag(utility.ENABLED_VFX_TAG)
        attr.set(m, "Enabled", true)
        enabled_effects.add(m)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)

        stand.vfx.disable(m)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)
        expect(m:HasTag(utility.ENABLED_VFX_TAG)).toBe(true)
        expect(stand.moved[m] ~= nil).toBe(true)

        -- the record kept, so game code switching Enabled back on resumes it
        attr.set(m, "Enabled", true)
        attr.trigger(m, "Enabled", true)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(2)
      end)
    end)

    test("disable stops the passive loop and leaves an open window ticking", function()
      passive(function(stand: any)
        local m = model()
        local env = effects.emit(0, m)

        stand.vfx.enable(m)
        harness.render(0.21)

        -- the window ticked as it opened and again with the frame
        expect(stand.seen).toEqual({ passive = 1, window = 2 })

        stand.vfx.disable(m)
        harness.render(0.21)

        expect(stand.seen).toEqual({ passive = 1, window = 3 })

        env:Clear()
      end)
    end)

    test("enable on a cached instance survives a reparent", function()
      passive(function(stand: any)
        local m = model()

        stand.vfx.enable(m)
        harness.render(0.21)

        stand.where.placed = false
        stand.moved[m]()
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)

        stand.where.placed = true
        stand.moved[m]()
        harness.render(0.21)

        expect(stand.seen.passive).toBe(2)
      end)
    end)

    test("deinit tears down a loop enable started without the tag", function()
      passive(function(stand: any)
        local m = model()

        stand.vfx.enable(m)
        harness.render(0.21)
        stand.deinit()
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)
        expect(stand.moved[m]).toBe(nil)
      end)
    end)

    test("clear ends a loop's ticks still playing, its own and a stopped loop's", function()
      passive(function(stand: any)
        local released = 0

        emitters.dispatch = function(_obj: any, fx: any)
          lifetime.hold(fx, function()
            released += 1
          end)

          lifetime.wait(fx, 60)
        end

        local m = model()

        stand.vfx.enable(m)
        harness.render(0.21)
        stand.vfx.disable(m)
        stand.vfx.enable(m)
        harness.render(0.21)

        expect(released).toBe(0)

        enabled_effects.clear()

        expect(released).toBe(2)
      end)
    end)

    test("enable on the folder that holds a mesh starts the mesh's loop", function()
      passive(function(stand: any)
        local folder = harness.make("Folder")

        model(folder)
        stand.vfx.enable(folder)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)
      end)
    end)

    test("enable twice, on an instance the tag listener already holds, keeps one loop", function()
      passive(function(stand: any)
        local m = model()

        m:AddTag(utility.ENABLED_VFX_TAG)
        enabled_effects.add(m)

        stand.vfx.enable(m)
        stand.vfx.enable(m)

        harness.render(0.21)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(2)
      end)
    end)

    test("any other instance stores Enabled, a cached one in its cache", function()
      local vfx = api()

      registry.register(require("@vfx/particle"))

      local folder = harness.make("Folder")
      local emitter = harness.make("ParticleEmitter", folder) :: ParticleEmitter

      folder:SetAttribute("Enabled", false)
      attr.cache(folder)
      emitter.Enabled = false

      vfx.enable(folder)

      expect(attr.get(folder, "Enabled", false)).toBe(true)
      expect(folder:GetAttribute("Enabled")).toBe(nil)
      expect(emitter.Enabled).toBe(true)

      vfx.disable(folder)

      expect(attr.get(folder, "Enabled", true)).toBe(false)
      expect(emitter.Enabled).toBe(false)

      registry.clear()
    end)

    test("an emitter a custom effect classifies keeps its own Enabled and stores the row", function()
      local vfx = api()

      registry.configure({ query = harness.query })
      harness.reset()
      registry.register(require("@vfx/particle"))
      registry.register({
        id = "my_emitter",
        display = { name = "My Emitter" },
        classifier = "ParticleEmitter.MyEmitter",
        emit = function() end,
      }, true)

      local folder = harness.make("Folder")
      local mine = harness.make("ParticleEmitter", folder) :: ParticleEmitter
      local plain = harness.make("ParticleEmitter", folder) :: ParticleEmitter

      mine:AddTag("MyEmitter")
      mine.Enabled = false
      plain.Enabled = false

      vfx.enable(folder)

      expect(mine.Enabled).toBe(false)
      expect(attr.get(mine, "Enabled", false)).toBe(true)
      expect(plain.Enabled).toBe(true)

      registry.clear()
    end)

    test("an emit of a cached enabled mesh stops its passive loop", function()
      passive(function(stand: any)
        local m = model()

        attr.set(m, "Enabled", true)
        m:AddTag(utility.ENABLED_VFX_TAG)
        enabled_effects.add(m)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)

        local env = effects.emit(0, m)

        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)
        expect(attr.get(m, "Enabled", true)).toBe(false)

        env:Clear()
      end)
    end)

    test("an emit of a cached enabled untagged mesh stops its passive loop and removes its record", function()
      passive(function(stand: any)
        local m = model()

        stand.vfx.enable(m)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)

        local env = effects.emit(0, m)

        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)
        expect(attr.get(m, "Enabled", true)).toBe(false)
        expect(stand.moved[m]).toBe(nil)

        env:Clear()
      end)
    end)

    test("enable while out of place ticks once the instance is placed", function()
      passive(function(stand: any)
        local m = model()

        stand.where.placed = false
        stand.vfx.enable(m)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(0)

        stand.where.placed = true
        stand.moved[m]()
        harness.render(0.21)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(2)
      end)
    end)

    test("a destroyed untagged mesh leaves no loop and no reparent signal behind", function()
      passive(function(stand: any)
        local m = model()

        stand.vfx.enable(m)
        harness.render(0.21)
        stand.destroyed[m]()
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)
        expect(stand.moved[m]).toBe(nil)
        expect(stand.destroyed[m]).toBe(nil)
      end)
    end)

    test("enable on every frame keeps the cached mesh's Rate", function()
      passive(function(stand: any)
        local m = model()

        for _ = 1, 60 do
          stand.vfx.enable(m)
          harness.render(1 / 60)
        end

        expect(stand.seen.passive).toBe(5)
      end)
    end)

    test("enable before init stores Enabled and the tag, and init's tag scan starts the loop", function()
      passive(function(stand: any)
        local m = model()
        local runService = game:GetService("RunService")
        local running = runService.IsRunning

        stand.deinit()

        runService.IsRunning = function()
          return false
        end

        stand.vfx.enable(m)
        runService.IsRunning = running

        harness.render(0.21)

        expect(stand.seen.passive).toBe(0)
        expect(attr.get(m, "Enabled", false)).toBe(true)
        expect(m:HasTag(utility.ENABLED_VFX_TAG)).toBe(true)

        stand.tagged = { m }
        stand.init()
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)
      end)
    end)

    -- a constant custom effect as an author writes it, and a tagged, cached
    -- instance of it the passive loops already hold
    local function looping(name: string): any
      return {
        sdk_version = 1,
        id = "my_loop",
        display = { name = name },
        classifier = "Part.MyLoop",
        constant = true,
        emit = function() end,
      }
    end

    local function looped(stand: any): Instance
      local part = harness.make("Part", harness.make("Folder"))

      part:AddTag("MyLoop")
      part:AddTag(utility.ENABLED_VFX_TAG)
      part:SetAttribute("Enabled", true)
      attr.cache(part)
      table.insert(stand.tagged, part)
      enabled_effects.add(part)

      return part
    end

    test("a constant custom effect registered after its instance exists starts looping", function()
      passive(function(stand: any)
        looped(stand)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(0)
        expect((custom.add("a", looping("Loop"), "ReplicatedStorage.A"))).toBe(true)

        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)
        expect(stand.ticked).toBe(registry.get("my_loop"))
      end)
    end)

    test("a reload swaps a running loop to the new version", function()
      passive(function(stand: any)
        custom.add("a", looping("Loop"), "ReplicatedStorage.A")
        looped(stand)
        harness.render(0.21)

        local first = registry.get("my_loop")

        expect(stand.ticked).toBe(first)
        expect((custom.add("a", looping("Loop 2"), "ReplicatedStorage.A"))).toBe(true)

        harness.render(0.21)

        expect(stand.seen.passive).toBe(2)
        expect(stand.ticked).toBe(registry.get("my_loop"))
        expect(stand.ticked ~= first).toBe(true)
      end)
    end)

    test("a constant custom effect keeps looping after a reload on a part screen also matches", function()
      passive(function(stand: any)
        registry.register(require("@vfx/screen"))

        local author = looping("Loop")

        author.classifier = "BasePart.MyLoop"
        custom.add("a", author, "ReplicatedStorage.A")

        local part = looped(stand)

        -- the attribute on the part itself, which the cache moved aside, as
        -- attr.get's write of a default leaves it in Studio's edit mode and
        -- where screen's classifier reads it
        part:SetAttribute("Enabled", true)

        expect(table.find(harness.query(part.Parent :: Instance, "BasePart[$Enabled=true]"), part) ~= nil).toBe(true)
        expect(registry.of(part)).toBe(registry.get("my_loop"))

        harness.render(0.21)

        local first = registry.get("my_loop")

        expect(stand.ticked).toBe(first)

        local again = looping("Loop 2")

        again.classifier = "BasePart.MyLoop"

        expect((custom.add("a", again, "ReplicatedStorage.A"))).toBe(true)

        harness.render(0.21)

        expect(stand.seen.passive).toBe(2)
        expect(stand.ticked).toBe(registry.get("my_loop"))
        expect(stand.ticked ~= first).toBe(true)
      end)
    end)

    test("removing a constant custom effect stops its loop", function()
      passive(function(stand: any)
        custom.add("a", looping("Loop"), "ReplicatedStorage.A")
        looped(stand)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)

        custom.remove("a")
        harness.render(0.21)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)
      end)
    end)

    test("init after deinit keeps one loop on a tagged mesh", function()
      passive(function(stand: any)
        local m = model()

        m:AddTag(utility.ENABLED_VFX_TAG)
        stand.tagged = { m }
        stand.vfx.enable(m)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(1)

        stand.deinit()
        stand.init()
        stand.init()

        harness.render(0.21)
        harness.render(0.21)

        expect(stand.seen.passive).toBe(3)
      end)
    end)
  end)
end)
