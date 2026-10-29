local value = require("@mod/value")
local frame = require("@mod/modifier_frame")
local codec = require("@mod/modifier_codec")
local color = require("@mod/color/color")
local mods = require("@mod/mods")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local utility = require("@mod/utility")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local fake_pool = require("@tests/fake_pool")
local test, expect = harness.test, harness.expect

local mesh = require("@vfx/mesh")

const Color3 = harness.datatypes.Color3
const Vector3 = harness.datatypes.Vector3
const NumberRange = harness.datatypes.NumberRange

frame.configure(harness.fakeEncoding, harness.fakeCompression)

-- the mesh registered on the effects service and a fake pool, put back once
-- `body` ends
const function staged(body: (fake: fake_pool.Fake) -> ())
  const protect = utility.protectParent
  const constructor = Instance

  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
  registry.register(mesh)

  utility.protectParent = function() end

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = harness.datatypes.Instance

  const fake = fake_pool.start({})
  const ok, err = pcall(body, fake)

  fake_pool.stop(fake)
  registry.clear()
  utility.protectParent = protect

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = constructor

  if not ok then
    error(err, 0)
  end
end

-- a mesh model on the special mesh route, its Start and End each wearing a
-- decal named Face, the start's carrying `attributes`, living two seconds
const function model(attributes: { [string]: any }): (any, any)
  const m = harness.make("Model", harness.make("Folder")) :: any
  const start = harness.make("Part", m) :: any
  const goal = harness.make("Part", m) :: any

  start.Name, goal.Name = "Start", "End"
  start.Size, goal.Size = Vector3.new(4, 4, 4), Vector3.new(4, 4, 4)
  harness.make("SpecialMesh", start).MeshId = "rbxassetid://0"
  harness.make("SpecialMesh", goal).MeshId = "rbxassetid://0"

  const decal = harness.make("Decal", start) :: any
  const twin = harness.make("Decal", goal) :: any

  decal.Name, twin.Name = "Face", "Face"
  m:SetAttribute("EffectDuration", NumberRange.new(2, 2))

  for name, v in attributes do
    decal:SetAttribute(name, v)
  end

  return m, decal
end

const function tweened(obj: Instance, source: string, name: string, from: any, to: any)
  const queue = {
    { kind = "tween", chain = false, duration = 1, start = value.lit(from), finish = value.lit(to) },
  }

  obj:SetAttribute(mods.attrName(source, name), frame.frame(codec.encode({ v = 1, queue = queue })))
end

-- the decal the emit's one piece wears
const function worn(fake: fake_pool.Fake): any
  const pieces = fake.folder:GetChildren()

  expect(#pieces).toBe(1)

  return pieces[1]:FindFirstChildOfClass("Decal")
end

const function near(a: number, b: number)
  expect(math.abs(a - b) < 1e-5).toBe(true)
end

const function nearColor(a: Color3, b: Color3)
  near(a.R, b.R)
  near(a.G, b.G)
  near(a.B, b.B)
end

const function times(c: Color3, s: number): Color3
  return Color3.new(c.R * s, c.G * s, c.B * s)
end

const function glowGroup(): any
  for _, entry in mesh.layout do
    if type(entry) == "table" and entry.title == "Glow" then
      return entry
    end
  end

  return nil
end

harness.suite(function()
  harness.describe("a mesh's decal glow", function()
    test("Color mode multiplies the decal's color by its strength", function()
      staged(function(fake)
        const m = model({ GlowMode = "Color", GlowStrength = 3 })
        const env = effects.emit(0, m)

        nearColor(worn(fake).Color3, times(Color3.new(1, 1, 1), 3))

        env:Clear()
      end)
    end)

    test("Color mode composes a Color3 modifier with a strength tween", function()
      staged(function(fake)
        const from, to = Color3.new(1, 0, 0), Color3.new(0, 0, 1)
        const m, decal = model({ GlowMode = "Color", GlowStrength = 2 })

        tweened(decal, "property", "Color3", from, to)
        tweened(decal, "attribute", "GlowStrength", 2, 4)

        const env = effects.emit(0, m)
        const face = worn(fake)

        nearColor(face.Color3, times(from, 2))

        scheduler.frame(0.25)
        scheduler.frame(0.25)

        const mid = color.blend(from, to, 0.5)

        nearColor(face.Color3, times(mid, 3))

        scheduler.frame(0.5)
        scheduler.frame(0.25)

        nearColor(face.Color3, times(to, 4))

        env:Clear()
      end)
    end)

    test("Emissive mode writes EmissiveStrength and EmissiveTint from their tracks", function()
      staged(function(fake)
        const tint = Color3.new(1, 0.5, 0)
        const m, decal = model({ GlowMode = "Emissive", GlowStrength = 2, GlowTint = tint })

        tweened(decal, "attribute", "GlowStrength", 2, 4)

        const env = effects.emit(0, m)
        const face = worn(fake)

        near(face.EmissiveStrength, 2)
        nearColor(face.EmissiveTint, tint)
        nearColor(face.Color3, Color3.new(1, 1, 1))

        scheduler.frame(0.25)
        scheduler.frame(0.25)

        near(face.EmissiveStrength, 3)

        env:Clear()
      end)
    end)

    test("None leaves the decal's color and emissive alone", function()
      staged(function(fake)
        const cyan = Color3.new(0, 1, 1)
        const m, decal = model({ GlowStrength = 3, GlowTint = Color3.new(1, 0, 0) })

        decal.Color3 = cyan
        m.End.Face.Color3 = cyan

        const env = effects.emit(0, m)
        const face = worn(fake)

        scheduler.frame(0.5)

        nearColor(face.Color3, cyan)
        near(face.EmissiveStrength, 1)
        nearColor(face.EmissiveTint, Color3.new(1, 1, 1))

        env:Clear()
      end)
    end)

    test("the mesh card's Glow group hides on a decal-dressed mesh and shows on a SurfaceAppearance", function()
      const group = glowGroup()
      const plain = { TextureSet = "", FrameSet = "" }

      expect(group ~= nil).toBe(true)
      expect(type(group.hidden)).toBe("function")

      const dressed = model({})

      expect(group.hidden({ ref = dressed }, plain)).toBe(true)
      expect(group.hidden({ ref = dressed }, { TextureSet = "a", FrameSet = "" })).toBe(false)
      expect(group.hidden({ ref = dressed }, { TextureSet = "", FrameSet = "b" })).toBe(false)

      const surfaced = model({})

      harness.make("SurfaceAppearance", surfaced:FindFirstChild("Start"))

      expect(group.hidden({ ref = surfaced }, plain)).toBe(false)
    end)
  end)
end)
