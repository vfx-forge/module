const knob = require("@mod/knob")
const retime = require("@mod/retime")
const reader = require("@mod/reader")
const harness = require("@tests/harness")
const registry = require("@mod/registry")

const test, expect = harness.test, harness.expect
const Instance = harness.datatypes.Instance

const BUILT_IN = {
  "beam",
  "mesh",
  "spin",
  "sound",
  "trail",
  "bezier",
  "animator",
  "particle",
  "lightning",
  "controller",
  "forge_mesh",
  "camera_shake",
  "shockwave_line",
  "shockwave_ring",
  "shockwave_debris",
  "forge_lightning",
}

const function noop() end

-- a module built per case, so every case owns its rows
const function module(attributes: { [string]: any })
  return {
    id = "ranged_stub",
    display = { name = "Stub" },
    classifier = "Part",
    attributes = attributes,
    properties = {},
    emit = noop,
  }
end

-- an emit's read, which a scope stands for
const function ctxFor(obj: Instance)
  return { ref = obj, obj = obj, scope = {} }
end

-- every emit's reading of the row, `n` emits over
const function reads(m: any, obj: Instance, name: string, n: number): { number }
  const out = {}

  for i = 1, n do
    out[i] = reader.resolve(m, ctxFor(obj))[name]
  end

  return out
end

harness.suite(function()
  harness.describe("ranged rows", function()
    test("with nothing beside it the row reads its own value, as before", function()
      const obj = Instance.new("Part")
      obj:SetAttribute("Delay", 0.2)

      const m = module({ Delay = knob(0):min(0):ranged() })

      for _, v in reads(m, obj, "Delay", 8) do
        expect(v).toBe(0.2)
      end

      expect(reader.resolve(m, ctxFor(Instance.new("Part"))).Delay).toBe(0)
    end)

    test("a longest beside it draws once per emit between the two", function()
      const obj = Instance.new("Part")
      obj:SetAttribute("Delay", 0.2)
      obj:SetAttribute(knob.maxOf("Delay"), 0.6)

      const m = module({ Delay = knob(0):min(0):ranged() })
      const seen: { [number]: boolean } = {}
      local kinds = 0

      for _, v in reads(m, obj, "Delay", 32) do
        expect(v >= 0.2 and v <= 0.6).toBe(true)

        if not seen[v] then
          seen[v] = true
          kinds += 1
        end
      end

      expect(kinds > 1).toBe(true)
    end)

    test("one emit reads one draw, whichever row asks for it", function()
      const obj = Instance.new("Part")
      obj:SetAttribute("Delay", 0.2)
      obj:SetAttribute(knob.maxOf("Delay"), 0.6)

      -- a rule row reading the delay, as a span rule adds it to the effect's
      const m = module({
        Delay = knob(0):ranged(),
        Echo = knob(function(_, attrs: any)
          return attrs.Delay
        end),
      })

      const seen: { [number]: boolean } = {}
      local kinds = 0

      for _ = 1, 16 do
        const attrs = reader.resolve(m, ctxFor(obj))
        const echo = attrs.Echo

        expect(attrs.Delay).toBe(echo)

        if not seen[echo] then
          seen[echo] = true
          kinds += 1
        end
      end

      expect(kinds > 1).toBe(true)
    end)

    test("a read through the registry draws when handed the emit's scope, as a pooled sound's pick is", function()
      registry.clear()
      registry.configure({ query = harness.query })

      const m = module({ Delay = knob(0):ranged() })

      registry.register(m)

      const obj = Instance.new("Part")
      obj:SetAttribute("Delay", 0.2)
      obj:SetAttribute(knob.maxOf("Delay"), 0.6)

      const seen: { [number]: boolean } = {}
      local kinds = 0

      for _ = 1, 16 do
        const v = (registry.read(obj, m, {}))
        const d = v.Delay

        expect(d >= 0.2 and d <= 0.6).toBe(true)

        if not seen[d] then
          seen[d] = true
          kinds += 1
        end
      end

      expect(kinds > 1).toBe(true)
      expect((registry.read(obj, m)).Delay).toBe(0.2)
    end)

    test("a longest at or below the value, or on a row not ranged, changes nothing", function()
      const obj = Instance.new("Part")
      obj:SetAttribute("Delay", 0.5)
      obj:SetAttribute(knob.maxOf("Delay"), 0.5)
      obj:SetAttribute("Plain", 0.2)
      obj:SetAttribute(knob.maxOf("Plain"), 0.9)

      const m = module({ Delay = knob(0):ranged(), Plain = knob(0) })

      for i = 1, 8 do
        const attrs = reader.resolve(m, ctxFor(obj))

        expect(attrs.Delay).toBe(0.5)
        expect(attrs.Plain).toBe(0.2)
      end
    end)

    test("a read with no emit behind it reads the shortest", function()
      const obj = Instance.new("Part")
      obj:SetAttribute("Delay", 0.2)
      obj:SetAttribute(knob.maxOf("Delay"), 0.6)

      const m = module({ Delay = knob(0):ranged() })

      for i = 1, 8 do
        expect(reader.resolve(m, { ref = obj, obj = obj }).Delay).toBe(0.2)
      end
    end)

    test("a draw stays inside the row's own bounds", function()
      const obj = Instance.new("Part")
      obj:SetAttribute("Delay", 0.5)
      obj:SetAttribute(knob.maxOf("Delay"), 10)

      for _, v in reads(module({ Delay = knob(0):max(1):ranged() }), obj, "Delay", 16) do
        expect(v >= 0.5 and v <= 1).toBe(true)
      end
    end)

    test("a rule row draws up to its longest too", function()
      const obj = Instance.new("Part")
      obj:SetAttribute("Length", 1)
      obj:SetAttribute(knob.maxOf("Length"), 2)

      const m = module({
        Length = knob(function()
          return 3
        end):ranged(),
      })

      for _, v in reads(m, obj, "Length", 8) do
        expect(v >= 1 and v <= 2).toBe(true)
      end
    end)

    test("the emit delay, the destroy delay and the flipbook's duration are ranged on every built-in", function()
      local count = 0

      for _, id in BUILT_IN do
        const m = require(`@vfx/{id}`) :: any

        for name, row in m.attributes or {} do
          if name == "EmitDelay" or name == "DestroyDelay" or name == "FlipbookChangeDuration" then
            count += 1
            expect(`{id}.{name} {row.isRanged}`).toBe(`{id}.{name} true`)
          end
        end
      end

      expect(count).toBe(24)
    end)

    test("the lightning's delay is ranged, and its length counts the delay it drew", function()
      const lightning = require("@vfx/forge_lightning") :: any
      const obj = Instance.new("Attachment")

      obj:SetAttribute("EmitDelay", 0.2)
      obj:SetAttribute(knob.maxOf("EmitDelay"), 0.6)

      expect(lightning.attributes.EmitDelay.isRanged).toBe(true)

      const bare = Instance.new("Attachment")
      const plain = reader.resolve(lightning, { ref = bare, obj = bare, effect = lightning })
      const seen: { [number]: boolean } = {}
      local kinds = 0

      for _ = 1, 16 do
        const ctx = { ref = obj, obj = obj, effect = lightning, scope = {} }
        const attrs = reader.resolve(lightning, ctx)
        const delay = attrs.EmitDelay

        expect(delay >= 0.2 and delay <= 0.6).toBe(true)
        expect(math.abs(lightning.duration(ctx, attrs, {}) - lightning.duration(ctx, plain, {}) - delay) < 1e-9).toBe(
          true
        )

        if not seen[delay] then
          seen[delay] = true
          kinds += 1
        end
      end

      expect(kinds > 1).toBe(true)
    end)

    test("a retime scales the longest with the row", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module({ Delay = knob(0):unit("seconds"):ranged() }))

      const obj = Instance.new("Part")
      obj:SetAttribute("Delay", 0.2)
      obj:SetAttribute(knob.maxOf("Delay"), 0.6)

      retime.apply(obj, 2, 0.5)

      expect(math.abs(obj:GetAttribute("Delay") - 0.1) < 1e-9).toBe(true)
      expect(math.abs(obj:GetAttribute(knob.maxOf("Delay")) - 0.3) < 1e-9).toBe(true)
    end)
  end)
end)
