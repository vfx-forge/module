const knob = require("@mod/knob")
const curves = require("@mod/curves")
const reader = require("@mod/reader")
const harness = require("@tests/harness")
const registry = require("@mod/registry")
const state_list = require("@mod/common/state_list")
const value_curve = require("@mod/value_curve")
const test, expect = harness.test, harness.expect
const Color3 = harness.datatypes.Color3
const Vector2 = harness.datatypes.Vector2
const Instance = harness.datatypes.Instance
const ColorSequence = harness.datatypes.ColorSequence

const EPSILON = 1e-6

-- whether two values match, numbers and their components within EPSILON
const function close(a: any, b: any): boolean
  const kind = typeof(a)

  if kind ~= typeof(b) then
    return false
  end

  if kind == "number" then
    return math.abs(a - b) < EPSILON
  end

  if kind == "vector" then
    return close(a.x, b.x) and close(a.y, b.y) and close(a.z, b.z)
  end

  if kind == "Color3" then
    return close(a.R, b.R) and close(a.G, b.G) and close(a.B, b.B)
  end

  if kind == "Vector2" then
    return close(a.X, b.X) and close(a.Y, b.Y)
  end

  if kind ~= "table" then
    return a == b
  end

  for k, v in a do
    if not close(v, b[k]) then
      return false
    end
  end

  for k in b do
    if a[k] == nil then
      return false
    end
  end

  return true
end

-- a serialized path of one cubic from (0, 0) to (1, 1), y down
const function shaped(x1: number, y1: number, x2: number, y2: number): string
  const buf = buffer.create(48)

  buffer.writef32(buf, 4, 1)
  buffer.writef32(buf, 8, x1)
  buffer.writef32(buf, 12, 1 - y1)
  buffer.writef32(buf, 16, x2)
  buffer.writef32(buf, 20, 1 - y2)
  buffer.writef32(buf, 24, 1)

  return buffer.tostring(buf)
end

const function state(time: number, extra: { [string]: any }?): any
  const s = {
    time = time,
    easing = curves.linear(),
    position = vector.create(0, 0, 0),
    rotation = vector.create(0, 0, 0),
    spin = vector.create(0, 0, 0),
    size = vector.create(1, 1, 1),
    color = Color3.new(1, 1, 1),
    transparency = 0,
    reflectance = 0,
    material = "Plastic",
    materialVariant = "",
    decals = {},
  }

  for k, v in extra or {} do
    s[k] = v
  end

  return s
end

const function sample(): any
  return {
    state(0, {
      position = vector.create(1.5, -2.25, 3),
      rotation = vector.create(0.1, 0.2, -0.3),
      color = Color3.new(0.25, 0.5, 0.75),
      material = "Neon",
      materialVariant = "Rough",
      vertexColor = vector.create(1, 0.5, 0.25),
      surface = { color = Color3.new(1, 0, 0), emissiveStrength = 2, alphaMode = "Overlay" },
      decals = {
        Base = { color = Color3.new(0, 1, 0), transparency = 0.25, uvOffset = Vector2.new(0.5, 0), zIndex = 2 },
        Glow = { glowStrength = 3, emissiveTint = Color3.new(0.1, 0.2, 0.3), easing = curves.PRESETS.easeOut },
      },
    }),
    state(0.375, {
      easing = curves.PRESETS.easeIn,
      spin = vector.create(0, 2, 0),
      size = vector.create(2, 0.5, 1.25),
      transparency = 0.5,
      reflectance = 0.125,
      vertexColor = vector.create(0.5, 0.5, 0.5),
      surface = { emissiveTint = Color3.new(0, 0, 1), easing = shaped(0.2, 0.9, 0.4, 1.1) },
      decals = {
        Base = { uvScale = Vector2.new(2, 2), rotation = 45, emissiveStrength = 0.75 },
      },
    }),
    state(1, {
      easing = shaped(0.1, 0.3, 0.6, 0.8),
      transparency = 1,
      vertexColor = vector.create(0, 0, 0),
      surface = {},
      decals = {
        Base = { transparency = 1 },
        Glow = { transparency = 1, zIndex = -1 },
      },
    }),
  }
end

-- a value curve keyed as given, each key `{ time, value }` with flat handles
const function curveOf(channels: number, keys: { { number } }): value_curve.Curve
  const out = {}

  for i, k in keys do
    out[i] = {
      time = k[1],
      value = table.create(channels, k[2]),
      envelope = 0,
      left = table.create(channels, vector.create(0, 0, 0)),
      right = table.create(channels, vector.create(0, 0, 0)),
    }
  end

  return { channels = channels, linked = true, keys = out }
end

const function rows(extra: { [string]: any }?): any
  const r = {
    size = value_curve.flat(1, 3),
    transparency = value_curve.flat(0, 1),
    color = ColorSequence.new(Color3.new(0.2, 0.4, 0.6)),
    color0 = Color3.new(0.2, 0.4, 0.6),
    material = "SmoothPlastic",
    materialVariant = "",
    reflectance = 0,
    decals = {},
    ends = false,
  }

  for k, v in extra or {} do
    r[k] = v
  end

  return r
end

const function module(attributes: { [string]: any })
  return {
    id = "stub",
    display = { name = "Stub" },
    classifier = "Part",
    attributes = attributes,
    properties = {},
    emit = function() end,
  }
end

harness.suite(function()
  harness.describe("state_list codec", function()
    test("a list round-trips", function()
      const list = sample()
      const back = state_list.decode(state_list.encode(list))

      expect(back).ok()
      expect(close(back, list)).toBe(true)
      expect(state_list.is(back)).toBe(true)
      expect(state_list.is(list)).toBe(false)
    end)

    test("equal lists encode to equal strings", function()
      expect(state_list.encode(sample())).toBe(state_list.encode(sample()))
      expect(state_list.encode(state_list.decode(state_list.encode(sample())) :: any)).toBe(state_list.encode(sample()))
    end)

    test("anything malformed or of another version decodes to nil", function()
      const raw = state_list.encode(sample())
      const bumped = buffer.fromstring(raw)

      buffer.writeu8(bumped, 0, 2)

      expect(state_list.decode("")).toBe(nil)
      expect(state_list.decode("garbage, not a list")).toBe(nil)
      expect(state_list.decode(buffer.tostring(bumped))).toBe(nil)
      expect(state_list.decode(string.sub(raw, 1, -2))).toBe(nil)
      expect(state_list.decode(`{raw}x`)).toBe(nil)
      expect(state_list.decode(4 :: any)).toBe(nil)
    end)

    test("a decal with an empty name decodes to nil", function()
      const list = sample()

      list[1].decals = { ["\255"] = {} }

      const raw = state_list.encode(list)
      const nameless, swaps = string.gsub(raw, "\1\0\255", "\0\0")

      expect(swaps).toBe(1)
      expect(state_list.decode(raw)).ok()
      expect(state_list.decode(nameless)).toBe(nil)
    end)

    test("a value the format cannot hold raises instead of encoding a lost list", function()
      const function raises(field: string, v: any)
        const list = sample()

        list[2][field] = v

        const ok, problem = pcall(state_list.encode, list)

        expect(ok).toBe(false)
        expect(string.find(tostring(problem), field, 1, true) ~= nil).toBe(true)
      end

      raises("transparency", 0 / 0)
      raises("time", 1.5)
      raises("time", -1e-9)
      raises("reflectance", 1e40)
      raises("material", string.rep("x", 65536))

      const list = sample()

      list[1].decals.Base.rotation = math.huge

      expect(pcall(state_list.encode, list)).toBe(false)
    end)

    test("a list past the cap keeps its first states by time", function()
      const list = {}

      for i = 33, 1, -1 do
        table.insert(list, state(i / 33))
      end

      const back = state_list.decode(state_list.encode(list)) :: state_list.List

      expect(#back).toBe(state_list.MAX)

      for i, s in back do
        expect(close(s.time, i / 33)).toBe(true)
      end
    end)

    test("32 states with 8 decals and a surface fit the length the module notes", function()
      const list = {}

      for i = 1, state_list.MAX do
        const decals = {}

        for d = 1, 8 do
          decals[`Decal{d}`] = {
            color = Color3.new(0.5, 0.5, 0.5),
            transparency = 0.5,
            uvOffset = Vector2.new(0.5, 0.5),
            uvScale = Vector2.new(2, 2),
            rotation = 10,
            zIndex = 3,
            glowStrength = 2,
            emissiveStrength = 1,
            emissiveTint = Color3.new(1, 0.5, 0),
            easing = curves.PRESETS.easeIn,
          }
        end

        table.insert(
          list,
          state((i - 1) / 31, {
            easing = curves.PRESETS.easeOut,
            position = vector.create(1, 2, 3),
            rotation = vector.create(0.1, 0.2, 0.3),
            spin = vector.create(0, 1, 0),
            size = vector.create(2, 2, 2),
            transparency = 0.5,
            reflectance = 0.5,
            materialVariant = "Rough",
            vertexColor = vector.create(1, 1, 1),
            surface = {
              color = Color3.new(1, 1, 1),
              emissiveStrength = 1,
              emissiveTint = Color3.new(1, 1, 1),
              alphaMode = "Overlay",
              easing = curves.PRESETS.easeIn,
            },
            decals = decals,
          })
        )
      end

      expect(#state_list.encode(list)).toBe(21154)
    end)
  end)

  harness.describe("state_list plain form", function()
    test("a list round-trips through its plain form", function()
      const list = state_list.decode(state_list.encode(sample())) :: state_list.List

      expect(state_list.fromPlain(state_list.toPlain(list))).toEqual(list)
    end)

    test("a bad field is named", function()
      const list, problem = state_list.fromPlain({ { time = "x" } })

      expect(list).toBe(nil)
      expect(string.find(problem :: string, "time", 1, true) ~= nil).toBe(true)

      const plain = state_list.toPlain(sample())

      plain[2].decals.Base.uvScale = { 1 }

      const _, wrong = state_list.fromPlain(plain)

      expect(string.find(wrong :: string, "uvScale", 1, true) ~= nil).toBe(true)
      expect(string.find(wrong :: string, "Base", 1, true) ~= nil).toBe(true)
    end)

    test("a value no f32 holds is refused by name", function()
      const plain = state_list.toPlain(sample())

      plain[1].surface.emissiveStrength = 1e40

      const list, problem = state_list.fromPlain(plain)

      expect(list).toBe(nil)
      expect(string.find(problem :: string, "emissiveStrength", 1, true) ~= nil).toBe(true)

      const moved = state_list.toPlain(sample())

      moved[1].position = { 0, 1e40, 0 }

      const _, wrong = state_list.fromPlain(moved)

      expect(string.find(wrong :: string, "position", 1, true) ~= nil).toBe(true)
    end)

    test("a hole in the list is refused by index", function()
      const plain = state_list.toPlain(sample())
      const holed = { plain[1], nil, plain[2] }
      const list, problem = state_list.fromPlain(holed)

      expect(list).toBe(nil)
      expect(string.find(problem :: string, "state 2", 1, true) ~= nil).toBe(true)
    end)

    test("a list past the cap is refused", function()
      const plain = {}

      for i = 1, state_list.MAX + 1 do
        plain[i] = { time = 0, color = { 1, 1, 1 }, material = "Plastic" }
      end

      const list, problem = state_list.fromPlain(plain)

      expect(list).toBe(nil)
      expect(problem).ok()
    end)
  end)

  harness.describe("state_list.seed", function()
    test("a fade over the life seeds a state at each end", function()
      const list = state_list.seed(rows({ transparency = curveOf(1, { { 0, 0 }, { 1, 1 } }) }))

      expect(#list).toBe(2)
      expect(list[1].time).toBe(0)
      expect(list[2].time).toBe(1)
      expect(list[1].transparency).toBe(0)
      expect(list[2].transparency).toBe(1)

      for _, s in list do
        expect(s.size).toBe(vector.create(1, 1, 1))
        expect(close(s.color, Color3.new(0.2, 0.4, 0.6))).toBe(true)
      end
    end)

    test("a modifier on a decal seeds its two ends", function()
      const list = state_list.seed(rows({
        ends = true,
        decals = {
          Glow = {
            ends = true,
            at = function(t: number)
              return { transparency = t }
            end,
          },
        },
      }))

      expect(#list).toBe(2)
      expect(list[1].time).toBe(0)
      expect(list[2].time).toBe(1)
      expect(list[1].decals.Glow.transparency).toBe(0)
      expect(list[2].decals.Glow.transparency).toBe(1)
    end)

    test("a state sits at each key a row holds", function()
      const list = state_list.seed(rows({ size = curveOf(3, { { 0, 1 }, { 0.4, 2 }, { 1, 0.5 } }) }))

      expect(#list).toBe(3)
      expect(list[2].time).toBe(0.4)
      expect(list[2].size).toBe(vector.create(2, 2, 2))
    end)

    test("nothing moving seeds two equal states", function()
      const list = state_list.seed(rows())

      expect(#list).toBe(2)
      expect(list[1].time).toBe(0)
      expect(list[2].time).toBe(1)

      const a, b = table.clone(list[1]), table.clone(list[2])

      a.time, b.time = nil :: any, nil :: any

      expect(a).toEqual(b)
    end)

    test("an eased segment seeds its easing", function()
      const fade = curveOf(1, { { 0, 0 }, { 1, 1 } })
      const points = curves.points("easeIn")

      fade.keys[1].right = { points[2] }
      fade.keys[2].left = { points[3] - vector.create(1, 1, 0) }

      const list = state_list.seed(rows({ transparency = fade }))

      expect(list[2].easing).toBe(curves.PRESETS.easeIn)
      expect(list[1].easing).toBe(curves.linear())
    end)
  end)

  harness.describe("state_list.scaled", function()
    test("doubles positions and sizes", function()
      const list = sample()
      const twice = state_list.scaled(list, 2)

      for i, s in twice do
        expect(s.position).toBe(list[i].position * 2)
        expect(s.size).toBe(list[i].size * 2)
      end
    end)
  end)

  harness.describe("a StateList row", function()
    -- lune refuses a non utf-8 attribute string, so the stored map is stubbed
    const function resolve(row: any, stored: any)
      const obj = Instance.new("Part")

      reader.source = function()
        return { States = stored }
      end

      const ok, attrs = pcall(reader.resolve, module({ States = row }), { ref = obj, obj = obj })

      reader.source = reader.defaultSource

      assert(ok, attrs)

      return attrs.States
    end

    test("is the kind its default names", function()
      expect(knob.kindOf(state_list.EMPTY)).toBe("StateList")
      expect(knob(state_list.EMPTY):stateList().kind).toBe("StateList")
      expect(function()
        knob({}):stateList()
      end).toThrow()
    end)

    test("reads its stored string as one frozen list", function()
      const raw = state_list.encode(sample())
      const read = resolve(knob(state_list.EMPTY):stateList(), raw)

      expect(close(read, sample())).toBe(true)
      expect(table.isfrozen(read)).toBe(true)
      expect(table.isfrozen(read[1].decals.Base)).toBe(true)
      expect(resolve(knob(state_list.EMPTY):stateList(), raw)).toBe(read)
    end)

    test("a bad or unset attribute reads its default", function()
      for _, bad in { "garbage", 4, true } do
        expect(resolve(knob(state_list.EMPTY):stateList(), bad)).toBe(state_list.EMPTY)
      end

      expect(resolve(knob(state_list.EMPTY):stateList(), nil)).toBe(state_list.EMPTY)
    end)

    test("refuses a modifier", function()
      const problems = registry.problems(module({ States = knob(state_list.EMPTY):stateList():mod() }) :: any)

      expect(#problems).toBe(1)
    end)
  end)
  harness.describe("state_list.sampler", function()
    const CFrame = harness.datatypes.CFrame
    const function same(a: CFrame, b: CFrame): boolean
      return close(a.LookVector.X, b.LookVector.X)
        and close(a.LookVector.Y, b.LookVector.Y)
        and close(a.LookVector.Z, b.LookVector.Z)
        and close(a.RightVector.X, b.RightVector.X)
        and close(a.RightVector.Y, b.RightVector.Y)
        and close(a.RightVector.Z, b.RightVector.Z)
    end

    const fade = { state(0), state(1, { transparency = 1 }) }

    test("blends between two states and holds past both ends", function()
      const read = state_list.sampler(fade :: any)
      const out: any = {}

      expect(close(read(0.25, out).transparency, 0.25)).toBe(true)
      expect(read(-1, out).transparency).toBe(0)
      expect(read(2, out).transparency).toBe(1)
    end)

    test("shapes the way in with the arriving state's easing", function()
      const read =
        state_list.sampler({ state(0), state(1, { transparency = 1, easing = curves.PRESETS.easeIn }) } :: any)

      expect(read(0.5, {} :: any).transparency < 0.5).toBe(true)
    end)

    test("switches a material at the arriving state's time", function()
      const read = state_list.sampler({ state(0), state(0.5, { material = "Neon" }) } :: any)
      const out: any = {}

      expect(read(0.49, out).material).toBe("Plastic")
      expect(read(0.5, out).material).toBe("Neon")
    end)

    test("adds the arriving state's spin and lands on its rotation", function()
      const rotation = vector.create(0.2, 0.4, -0.1)
      const base = CFrame.fromOrientation(0.2, 0.4, -0.1)
      const read = state_list.sampler(
        { state(0, { rotation = rotation }), state(1, { rotation = rotation, spin = vector.create(0, 1, 0) }) } :: any
      )
      const out: any = {}
      const half = base * CFrame.fromOrientation(0, math.pi, 0)

      expect(same(read(0.5, out).cframe, half)).toBe(true)
      expect(same(read(1, out).cframe, base)).toBe(true)
    end)

    test("turns the short way", function()
      const read = state_list.sampler({ state(0), state(1, { rotation = vector.create(0, math.rad(270), 0) }) } :: any)
      const want = CFrame.fromOrientation(0, math.rad(-45), 0)
      const got = read(0.5, {} :: any).cframe

      expect(same(got, want)).toBe(true)
    end)

    test("eases a decal by its own card, else the state's", function()
      const glow = { transparency = 0 }
      const arrive = { transparency = 1 }
      const read = state_list.sampler({
        state(0, { decals = { Glow = glow, Plain = glow } }),
        state(1, {
          transparency = 1,
          decals = { Glow = { transparency = 1, easing = curves.PRESETS.easeOut }, Plain = arrive },
        }),
      } :: any)
      const out = read(0.5, {} :: any)

      expect(close(out.transparency, 0.5)).toBe(true)
      expect(out.decals.Glow.transparency > 0.5).toBe(true)
      expect(close(out.decals.Plain.transparency, 0.5)).toBe(true)
    end)

    test("blends a field set on one side from the rest, else holds it", function()
      const list = {
        state(0, { surface = { emissiveStrength = 0 }, decals = { Mark = { glowStrength = 4 } } }),
        state(1, { surface = {}, decals = { Mark = { glowStrength = 4 } } }),
      }
      const rest = { surface = { emissiveStrength = 2 }, decals = {} }
      const withRest = state_list.sampler(list :: any, rest :: any)(0.5, {} :: any)
      const without = state_list.sampler(list :: any)(0.5, {} :: any)

      expect(close(withRest.surface.emissiveStrength, 1)).toBe(true)
      expect(without.surface.emissiveStrength).toBe(0)
      expect(withRest.decals.Mark.uvScale).toBe(nil)
      expect(without.surface.color).toBe(nil)
    end)

    test("blends a decal field set on one side from the rest, and switches from the rest at b", function()
      const list = {
        state(0, { decals = { Mark = {} } }),
        state(0.5, { decals = { Mark = { transparency = 0.5, zIndex = 5 } } }),
      }
      const rest = { decals = { Mark = { transparency = 0.1, zIndex = 1 } } }
      const read = state_list.sampler(list :: any, rest :: any)
      const out: any = {}

      expect(close(read(0.25, out).decals.Mark.transparency, 0.3)).toBe(true)
      expect(read(0.25, out).decals.Mark.zIndex).toBe(1)
      expect(read(0.49, out).decals.Mark.zIndex).toBe(1)
      expect(read(0.5, out).decals.Mark.zIndex).toBe(5)
    end)

    test("allocates no table per call", function()
      const read = state_list.sampler({
        state(0, { decals = { Mark = { transparency = 0 } } }),
        state(1, { decals = { Mark = { transparency = 1 } } }),
      } :: any)
      const out: any = {}
      const decals = read(0, out).decals
      const mark = decals.Mark
      const surface = out.surface

      for i = 1, 1000 do
        expect(read(i / 1000, out)).toBe(out)
      end

      expect(out.decals).toBe(decals)
      expect(out.decals.Mark).toBe(mark)
      expect(out.surface).toBe(surface)
      expect(close(out.decals.Mark.transparency, 1)).toBe(true)
    end)
  end)
end)
