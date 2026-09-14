local harness = require("@tests/harness")
local knob = require("@mod/knob")
local emitters = require("@root/emitters")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect

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
  local shared = { unc = {}, ref = {} }
  local claimant = registry.of(root)

  local function dispatch(obj: Instance, effect: registry.Module?)
    lifetime.run(lifetime.effect(em, 0, nil), function(scope)
      emitters.dispatch(obj, scope, shared, 1, effect)
    end)
  end

  dispatch(root, claimant)

  for _, hit in registry.scan(root, claimant) do
    dispatch(hit.instance, hit.effect)
  end

  lifetime.seal(em)

  return em
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
end)
