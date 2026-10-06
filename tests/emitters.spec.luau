local harness = require("@tests/harness")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
local curves = require("@mod/curves")
local emitters = require("@root/emitters")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect

frame.configure(harness.fakeEncoding, harness.fakeCompression)

-- a value written to a property comes back single precision, so a comparison
-- here is looser than one against a number the reader never wrote anywhere
local EPSILON = 1e-6

local function noop() end

local function near(a: number, b: number): boolean
  return math.abs(a - b) < EPSILON
end

local function module(id: string, classifier: string, extra: { [string]: any }?)
  local m = {
    id = id,
    display = { name = id, order = 10 },
    classifier = classifier,
    attributes = {},
    properties = {},
    emit = noop,
  }

  for k, v in extra or {} do
    m[k] = v
  end

  return m
end

-- an emit of a root, the way the effects service makes one: the root goes
-- through the dispatcher with its own module, then every hit the scan returns
-- with the module it was classified as, which for a legacy tween child is none
local function emit(root: Instance)
  local em = lifetime.emit(nil)
  local shared = { unc = {}, ref = {}, held = {} }
  local claimant = registry.of(root)

  local function dispatch(obj: Instance, effect: registry.Module?)
    lifetime.run(lifetime.effect(em, 0, nil), function(scope)
      emitters.dispatch(obj, scope, shared, effect)
    end)
  end

  dispatch(root, claimant)

  for _, hit in registry.scan(root, claimant) do
    dispatch(hit.instance, hit.effect)
  end

  lifetime.seal(em)

  return em
end

local function framed(obj: Instance, source: string, name: string, queue: { any })
  obj:SetAttribute(mods.attrName(source, name), frame.frame(codec.encode({ v = 1, queue = queue })))
end

local function tweener(parent: Instance, name: string, startV: any, endV: any, duration: number): Instance
  local child = harness.make("RayValue", parent)
  child.Name = name
  child:SetAttribute("_START_VALUE", startV)
  child:SetAttribute("_END_VALUE", endV)
  child:SetAttribute("Duration", duration)

  return child
end

harness.suite(function()
  harness.describe("the legacy tween child", function()
    test("one under a plain part under an emitted folder drives its target", function()
      registry.clear()
      registry.configure({ query = harness.query })
      harness.reset()

      local root = harness.make("Folder")
      local part = harness.make("Part", root)

      tweener(part, "Transparency", 0, 1, 1)

      emit(root)

      expect(part.Transparency).toBe(0)

      harness.render(0.5)
      harness.render(0.5)

      expect(near(part.Transparency, 0.5)).toBe(true)
    end)

    test("one under an instance whose module declares no row for it drives it", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("trail", "Trail"))
      harness.reset()

      local root = harness.make("Folder")
      local trail = harness.make("Trail", root)

      tweener(trail, "Lifetime", 1, 5, 1)

      emit(root)

      harness.render(0.5)

      expect(near(trail.Lifetime, 1)).toBe(true)

      harness.render(0.5)

      expect(near(trail.Lifetime, 3)).toBe(true)
    end)

    test("one naming a mod row of its parent's module leaves the template alone", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("sound", "Sound", { properties = { Volume = knob():mod() } }))
      harness.reset()

      local root = harness.make("Folder")
      local sound = harness.make("Sound", root)

      tweener(sound, "Volume", 1, 0.1, 1)

      local before = sound.Volume

      emit(root)

      harness.render(0.5)
      harness.render(0.5)

      -- the row on the read carries the child's queue, so the clone an effect
      -- makes fades; the template it was authored on is never driven
      local _, props = registry.read(sound)

      expect(sound.Volume).toBe(before)
      expect(props.Volume.animated).toBe(true)
      expect(near(props.Volume.at(0), 1)).toBe(true)
    end)

    -- a child's EmitDelay is a wall clock wait its speed ramp never touches, so
    -- the ramp starts once that wait is up. the delay is read from the child's
    -- own queue alone: a merged row of children never reaches the driver
    test("a speed ramp starts after its own child's delay", function()
      registry.clear()
      registry.configure({ query = harness.query })
      harness.reset()

      local root = harness.make("Folder")
      local part = harness.make("Part", root)

      local child = tweener(part, "Transparency", 0, 1, 1)
      child:SetAttribute("EmitDelay", 0.5)
      child:SetAttribute("Speed_Start", 2)
      child:SetAttribute("Speed_End", 2)

      emit(root)

      -- half a second of plain frames waits the delay out, and the ramp's
      -- first doubled frame samples where the tween begins
      for _ = 1, 3 do
        harness.render(0.25)
      end

      expect(near(part.Transparency, 0)).toBe(true)

      harness.render(0.25)

      expect(near(part.Transparency, 0.5)).toBe(true)
    end)

    -- in a queue that plays in turn, an entry carrying a speed ramp starts where
    -- the entry before it ends, and its ramp waits that long at plain frame time
    test("a speed ramp on a later entry waits out the entries before it", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("piece", "Part"))
      harness.reset()

      local part = harness.make("Part")
      local queue = {
        { kind = "tween", chain = false, duration = 1, start = value.lit(0), finish = value.lit(0.5) },
        {
          kind = "tween",
          chain = false,
          duration = 1,
          start = value.lit(0.5),
          finish = value.lit(1),
          speed = { start = 2, finish = 2, duration = 1, curve = curves.linear() },
        },
      }

      expect(codec.decode(codec.encode({ lanes = { start = queue } })).lanes.start[2].speed.start).toBe(2)

      framed(part, "property", "Transparency", queue)

      local em = lifetime.emit(nil)

      lifetime.run(lifetime.effect(em, 0, nil), function(scope)
        emitters.dispatch(part, scope, { unc = {}, ref = {}, held = {} }, registry.get("piece"))
      end)

      lifetime.seal(em)

      -- the first second passes at plain frames: the first entry is half done
      for _ = 1, 3 do
        harness.render(0.25)
      end

      expect(near(part.Transparency, 0.25)).toBe(true)

      -- then the ramp doubles the clock over the second entry
      for _ = 1, 3 do
        harness.render(0.25)
      end

      expect(near(part.Transparency, 0.75)).toBe(true)
    end)

    test("a randomizer is drawn once, by the prologue of the dispatch that finds it", function()
      registry.clear()
      registry.configure({ query = harness.query })
      harness.reset()

      local root = harness.make("Folder")
      local part = harness.make("Part", root)

      local child = tweener(part, "Transparency", 0.2, 0.2, 1)
      child:AddTag("PropertyRandomizer")

      emit(root)

      expect(near(part.Transparency, 0.2)).toBe(true)

      part.Transparency = 0

      -- the drive arm of the same dispatch refuses a randomizer, so the draw
      -- above is the only write it makes
      local em = lifetime.emit(nil)

      lifetime.run(lifetime.effect(em, 0, nil), function(scope)
        emitters.legacy_child(child :: any, scope)
      end)

      harness.render(0.5)

      expect(part.Transparency).toBe(0)
    end)
  end)

  harness.describe("a driven target", function()
    -- a part with a panel queue of its own, dispatched as an emit of its own
    local function driven(): Instance
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("piece", "Part"))
      harness.reset()

      local part = harness.make("Part")

      part.Transparency = 0.25

      framed(part, "property", "Transparency", {
        { kind = "tween", chain = false, duration = 1, start = value.lit(0), finish = value.lit(1) },
      })

      return part
    end

    local function dispatchOn(obj: Instance): lifetime.emit
      local em = lifetime.emit(nil)

      lifetime.run(lifetime.effect(em, 0, nil), function(scope)
        emitters.dispatch(obj, scope, { unc = {}, ref = {}, held = {} }, registry.get("piece"))
      end)

      lifetime.seal(em)

      return em
    end

    local function seconds(total: number)
      for _ = 1, math.round(total / 0.25) do
        harness.render(0.25)
      end
    end

    test("a panel queue on a property puts the authored value back once its emit ends", function()
      local part = driven()
      local em = dispatchOn(part)

      seconds(0.75)

      expect(near(part.Transparency, 0.5)).toBe(true)

      seconds(1.5)

      expect(em.done).toBe(true)
      expect(near(part.Transparency, 0.25)).toBe(true)
    end)

    test("two overlapping emits of one panel queue hand the property over and the last puts it back", function()
      local part = driven()
      local first = dispatchOn(part)

      seconds(0.5)

      local second = dispatchOn(part)

      seconds(1)

      -- the first has ended, and the second carries on from where it is
      expect(first.done).toBe(true)
      expect(second.done).toBe(false)
      expect(part.Transparency > 0.3 and part.Transparency < 0.95).toBe(true)

      seconds(1.5)

      expect(second.done).toBe(true)
      expect(near(part.Transparency, 0.25)).toBe(true)
    end)

    test("a legacy child with ResetOnFinish false keeps its last value", function()
      registry.clear()
      registry.configure({ query = harness.query })
      harness.reset()

      local root = harness.make("Folder")
      local part = harness.make("Part", root)

      part.Transparency = 0.25

      local child = tweener(part, "Transparency", 0, 1, 1)

      child:SetAttribute("ResetOnFinish", false)

      emit(root)
      seconds(2)

      expect(near(part.Transparency, 1)).toBe(true)
    end)

    test("a legacy child that resets goes back to its authored start value", function()
      registry.clear()
      registry.configure({ query = harness.query })
      harness.reset()

      local root = harness.make("Folder")
      local part = harness.make("Part", root)

      part.Transparency = 0.25

      tweener(part, "Transparency", 0.4, 1, 1)

      emit(root)
      seconds(2)

      expect(near(part.Transparency, 0.4)).toBe(true)
    end)
  end)

  harness.describe("the dispatcher", function()
    test("a constant emit reads and emits the module alone, where a plain one draws and drives too", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("piece", "Part"))
      harness.reset()

      -- a piece carrying both halves of the prologue: a randomizer child to
      -- draw and a queue of its own for the applier to start
      local function fixture(): Instance
        local part = harness.make("Part")
        local child = tweener(part, "Transparency", 0.7, 0.7, 1)
        child:AddTag("PropertyRandomizer")

        framed(part, "property", "Transparency", {
          { kind = "tween", chain = false, duration = 1, start = value.lit(0), finish = value.lit(1) },
        })

        return part
      end

      local function dispatch(obj: Instance, constant: boolean?)
        local em = lifetime.emit(nil)

        lifetime.run(lifetime.effect(em, 0, nil), function(scope)
          emitters.dispatch(obj, scope, { unc = {}, ref = {}, held = {} }, registry.get("piece"), constant)
        end)

        lifetime.seal(em)
      end

      local ticked = fixture()
      dispatch(ticked, true)

      expect(ticked.Transparency).toBe(0)

      for _ = 1, 3 do
        harness.render(0.25)
      end

      expect(ticked.Transparency).toBe(0)

      local emitted = fixture()
      dispatch(emitted, nil)

      expect(near(emitted.Transparency, 0.7)).toBe(true)

      for _ = 1, 3 do
        harness.render(0.25)
      end

      expect(near(emitted.Transparency, 0.5)).toBe(true)
    end)

    -- a trail the custom effect mine classifies, mirroring `reflect`, with a
    -- panel queue on two of its properties and on an attribute, half way
    -- through all three once the answer is read
    local function reflecting(reflect: any, extra: { [string]: any }?): Instance
      local mine = module("mine", "Trail.Mine", extra)

      mine.display = { name = "mine", order = 10, reflect = reflect }

      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(mine, true)
      harness.reset()

      local root = harness.make("Folder")
      local trail = harness.make("Trail", root)

      trail:AddTag("Mine")
      trail.Lifetime = 2
      trail.MaxLength = 4
      trail:SetAttribute("Spread", 4)

      local queue = {
        { kind = "tween", chain = false, duration = 1, start = value.lit(0), finish = value.lit(1) },
      }

      framed(trail, "property", "Lifetime", queue)
      framed(trail, "property", "MaxLength", queue)
      framed(trail, "attribute", "Spread", queue)

      emit(root)

      for _ = 1, 3 do
        harness.render(0.25)
      end

      return trail
    end

    test("a custom effect reflecting all plays a panel queue on any property it does not own", function()
      local trail = reflecting("all")

      expect(near(trail.Lifetime, 0.5)).toBe(true)
      expect(near(trail.MaxLength, 0.5)).toBe(true)
    end)

    test("a custom effect reflecting a list plays a listed property's queue and not another's", function()
      local trail = reflecting({ "Lifetime" })

      expect(near(trail.Lifetime, 0.5)).toBe(true)
      expect(trail.MaxLength).toBe(4)
    end)

    test("a custom effect never plays an attribute's queue, whatever it reflects", function()
      for _, reflect in { "all", { "Spread" } } :: { any } do
        local trail = reflecting(reflect)

        expect(trail:GetAttribute("Spread")).toBe(4)
      end
    end)

    test("a custom effect reflecting nothing plays no panel queue", function()
      local trail = reflecting(nil)

      expect(trail.Lifetime).toBe(2)
      expect(trail.MaxLength).toBe(4)
    end)

    test("a custom effect's own property rows are mirrored without reflect, and their panel queues play", function()
      local trail = reflecting(nil, { properties = { Lifetime = knob() } })

      expect(near(trail.Lifetime, 0.5)).toBe(true)
      expect(trail.MaxLength).toBe(4)
    end)

    test("a property a reflecting custom effect owns as a row is left to the row", function()
      local trail = reflecting("all", { properties = { MaxLength = knob():mod() } })

      expect(near(trail.Lifetime, 0.5)).toBe(true)
      expect(trail.MaxLength).toBe(4)
    end)

    test("a custom effect's instance runs none of the old format's leftovers on it", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("trail", "Trail"))
      registry.register(module("mine", "Trail.Mine"), true)
      harness.reset()

      local root = harness.make("Folder")
      local trail = harness.make("Trail", root)

      trail:AddTag("Mine")
      trail.Lifetime = 2
      trail.MaxLength = 4

      tweener(trail, "Lifetime", 1, 5, 1)

      local random = tweener(trail, "LightEmission", 0.7, 0.7, 1)

      random:AddTag("PropertyRandomizer")
      trail.LightEmission = 0.25

      framed(trail, "property", "MaxLength", {
        { kind = "tween", chain = false, duration = 1, start = value.lit(0), finish = value.lit(1) },
      })

      emit(root)

      for _ = 1, 4 do
        harness.render(0.25)
      end

      expect(trail.Lifetime).toBe(2)
      expect(trail.MaxLength).toBe(4)
      expect(trail.LightEmission).toBe(0.25)
    end)
  end)
end)
