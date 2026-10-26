-- the harness installs NumberRange, Vector2 and Color3 as globals, so it is required before rows
const harness = require("@tests/harness")
const rows = require("@mod/lightning/rows")
const describe, test, expect = harness.describe, harness.test, harness.expect

const Color3 = harness.datatypes.Color3
const Vector2 = harness.datatypes.Vector2
const NumberRange = harness.datatypes.NumberRange

const KNOB_METHODS = {
  "min",
  "max",
  "aliases",
  "options",
  "label",
  "hint",
  "curve",
  "unit",
  "hidden",
  "readonly",
  "slider",
  "seed",
  "mod",
  "instance",
}

const EXPECTED = {
  EmitDelay = { label = "Delay", default = 0, unit = "seconds" },
  EmitDuration = { label = "Duration", default = 0, unit = "seconds" },
  Count = { label = "Count", default = 1, mod = true },
  Enabled = { label = "Enabled", default = false },
  Continuous = { label = "Continuous", default = false },
  Rate = { label = "Rate", default = 5, unit = "perSecond" },
  Target = { label = "Target", default = "End" },
  EndPoint = { label = "End point" },
  Length = { label = "Length", default = 20, unit = "studs", mod = true },
  Spread = { label = "Spread", default = Vector2.zero, mod = true },
  Reach = { label = "Reach", default = 30, unit = "studs", mod = true },
  StartOffset = { label = "Start", unit = "studs", mod = true },
  EndOffset = { label = "End", unit = "studs", mod = true },
  Jagged = { label = "Jagged", default = 0.1, mod = true },
  Detail = { label = "Detail", default = 16, mod = true },
  Motion = { label = "Mode", default = "Jitter" },
  Jitter = { label = "Jitter", default = 15, unit = "perSecond", mod = true },
  FlowSpeed = { label = "Speed", default = 1, unit = "perSecond", mod = true },
  Forks = { label = "Amount", default = 3, mod = true },
  ForkLength = { label = "Length", default = 0.3, mod = true },
  Latch = { label = "Latch", default = 0, unit = "studs", mod = true },
  Style = { label = "Style", default = "Tube" },
  Width = { label = "Width", default = 0.7, unit = "studs", mod = true },
  Taper = { label = "Taper", default = 0, mod = true },
  Gradient = { label = "Color", mod = true },
  Heat = { label = "Heat", default = 0.8, mod = true },
  GradientRestart = { label = "Restart on forks", default = true },
  Glow = { label = "Strength", default = 1, mod = true },
  Light = { label = "Brightness", default = 0, mod = true },
  LightColor = { label = "Color", default = Color3.new(1, 1, 1), mod = true },
  Appear = { label = "Mode", default = "Strike" },
  AppearTime = { label = "Time", default = NumberRange.new(0.06, 0.1), unit = "seconds" },
  AppearCurve = { label = "Curve", default = "linear" },
  Hold = { label = "Time", default = NumberRange.new(0.2, 0.3), unit = "seconds" },
  Restrikes = { label = "Restrikes", default = 1, mod = true },
  Disappear = { label = "Mode", default = "Thin" },
  DisappearTime = { label = "Time", default = 0.25, unit = "seconds", mod = true },
  DisappearCurve = { label = "Curve", default = "easeIn" },
  ImpactFacing = { label = "Facing", default = "Surface" },
}

type recorder = { default: any, calls: { [string]: { any } } }

-- every knob method records what it was handed and answers the knob, as the real chain does
const function recorder(default: any): recorder
  const knob = { default = default, calls = {} }

  for _, name in KNOB_METHODS do
    knob[name] = function(self: any, ...: any)
      self.calls[name] = { ... }

      return self
    end
  end

  return knob :: any
end

const function stubSdk(): any
  const function spec(value: any)
    return recorder(value)
  end

  return {
    knob = recorder,
    mod = { from = spec, to = spec },
  }
end

const function params(): { [string]: recorder }
  return rows.params(stubSdk()).attributes :: any
end

const function hides(knob: recorder, attrs: { [string]: any }): boolean
  const call = knob.calls.hidden

  if not call then
    return false
  end

  return call[1](nil, attrs, {}) == true
end

const function group(title: string): any
  for _, entry in rows.layout do
    if entry.title == title then
      return entry
    end
  end

  return nil
end

harness.suite(function()
  describe("lightning rows", function()
    test("every row exists with its default and label", function()
      const attributes = params()
      local count = 0

      for name, want in EXPECTED do
        const knob = attributes[name]

        expect(knob ~= nil).toBe(true)
        expect(want.default == nil or knob.default == want.default).toBe(true)
        expect(knob.calls.label[1]).toBe(want.label)
      end

      for _ in attributes do
        count += 1
      end

      for _ in EXPECTED do
        count -= 1
      end

      expect(count).toBe(0)
    end)

    test("every row carries a hint and a label", function()
      for _, knob in params() do
        expect(type(knob.calls.hint[1])).toBe("string")
        expect(type(knob.calls.label[1])).toBe("string")
      end
    end)

    test("seconds, studs and rate rows carry their unit", function()
      const attributes = params()

      for name, want in EXPECTED do
        const unit = attributes[name].calls.unit

        expect(if unit then unit[1] else nil).toBe(want.unit)
      end
    end)

    -- a choice of mode, a curve, a flag or an instance takes none; everything else moves on screen
    test("every row but modes, curves, flags, the end point and the emit's own timing takes modifiers", function()
      const attributes = params()

      for name, want in EXPECTED do
        expect(attributes[name].calls.mod ~= nil).toBe(want.mod == true)
      end
    end)

    test("every layout entry names a row once and no group nests another", function()
      const attributes = params()
      const seen = {}

      for _, group in rows.layout do
        expect(type(group.title)).toBe("string")

        for _, entry in group.entries do
          expect(type(entry)).toBe("string")
          expect(attributes[entry] ~= nil).toBe(true)
          expect(seen[entry]).toBe(nil)

          seen[entry] = true
        end
      end

      for name in attributes do
        expect(seen[name]).toBe(true)
      end
    end)

    test("Length and Spread show only for Direction, Reach only for Ground", function()
      const attributes = params()

      for _, target in { "Direction", "End", "Ground" } do
        const attrs = { Target = target }

        expect(hides(attributes.Length, attrs)).toBe(target ~= "Direction")
        expect(hides(attributes.Spread, attrs)).toBe(target ~= "Direction")
        expect(hides(attributes.Reach, attrs)).toBe(target ~= "Ground")
      end
    end)

    test("fork rows hide at zero forks", function()
      const attributes = params()

      expect(hides(attributes.ForkLength, { Forks = 0 })).toBe(true)
      expect(hides(attributes.Latch, { Forks = 0 })).toBe(true)
      expect(hides(attributes.GradientRestart, { Forks = 0 })).toBe(true)
      expect(hides(attributes.GradientRestart, { Forks = 2 })).toBe(false)
      expect(hides(attributes.ForkLength, { Forks = 3 })).toBe(false)
      expect(hides(attributes.Latch, { Forks = 1 })).toBe(false)
      -- a modifier may move Forks off 0, so its fork rows stay
      expect(hides(attributes.ForkLength, { Forks = { value = 0, animated = false } })).toBe(true)
      expect(hides(attributes.ForkLength, { Forks = { value = 0, animated = true } })).toBe(false)
      expect(hides(attributes.Latch, { Forks = { value = 2, animated = false } })).toBe(false)
    end)

    test("End point is an attachment row shown only for End", function()
      const attributes = params()

      expect(attributes.EndPoint.calls.instance[1][1]).toBe("Attachment")
      expect(hides(attributes.EndPoint, { Target = "End" })).toBe(false)
      expect(hides(attributes.EndPoint, { Target = "Ground" })).toBe(true)
    end)

    test("the layout groups the rows as the spec lists them, in order", function()
      const found = {}

      for i, entry in rows.layout do
        found[i] = `{entry.title}: {table.concat(entry.entries, ",")}`
      end

      expect(found).toEqual({
        "Emit: EmitDelay,EmitDuration,Count,Enabled,Continuous,Rate",
        "Path: Target,EndPoint,Length,Spread,Reach,Jagged,Detail",
        "Offset: StartOffset,EndOffset",
        "Motion: Motion,Jitter,FlowSpeed",
        "Forks: Forks,ForkLength,Latch",
        "Look: Style,Width,Taper",
        "Color: Gradient,Heat,GradientRestart",
        "Glow: Glow",
        "Light: Light,LightColor",
        "Appear: Appear,AppearTime,AppearCurve",
        "Hold: Hold,Restrikes",
        "Disappear: Disappear,DisappearTime,DisappearCurve",
        "Impact: ImpactFacing",
      })
    end)

    test("none of the removed rows is left", function()
      const attributes = params()

      for _, name in { "Color", "Rim", "RimColor", "GlowWidth", "GlowColor", "Render", "ForkReach" } do
        expect(attributes[name]).toBe(nil)

        for _, group in rows.layout do
          expect(table.find(group.entries, name)).toBe(nil)
        end
      end
    end)

    test("no hint speaks of a glow ribbon and Disappear speaks of no glow", function()
      for _, knob in params() do
        expect(string.find(string.lower(knob.calls.hint[1]), "ribbon", 1, true)).toBe(nil)
      end

      for _, name in { "Disappear", "DisappearTime" } do
        expect(string.find(string.lower(params()[name].calls.hint[1]), "glow", 1, true)).toBe(nil)
      end
    end)

    test("Jitter and Flow each hide the other's row, read plain or animated", function()
      const attributes = params()

      for _, motion in { "Jitter", "Flow" } do
        for _, attrs in { { Motion = motion }, { Motion = { value = motion, animated = true } } } do
          expect(hides(attributes.Jitter, attrs)).toBe(motion == "Flow")
          expect(hides(attributes.FlowSpeed, attrs)).toBe(motion == "Jitter")
        end
      end
    end)

    test("the Glow group hides in Tube only, and only it and Hold hide", function()
      const attributes = params()
      const glow = group("Glow")
      const hold = group("Hold")

      expect(type(glow.hidden)).toBe("function")
      expect(hides(attributes.Glow, { Style = "Tube" })).toBe(false)

      for _, entry in rows.layout do
        expect(entry.hidden == nil or entry == glow or entry == hold).toBe(true)
      end

      for _, style in { "Tube", "Glow", "Segments" } do
        for _, attrs in { { Style = style }, { Style = { value = style, animated = false } } } do
          expect(glow.hidden(nil, attrs, {}) == true).toBe(style == "Tube")
        end
      end
    end)

    test("no hint names a row by a label it no longer has", function()
      for _, knob in params() do
        const hint = knob.calls.hint[1]

        -- whole words, since "End attachment" is the End child's own name
        expect(string.find(hint, "End at%f[^%w]")).toBe(nil)
        expect(string.find(string.lower(hint), "rim", 1, true)).toBe(nil)
        expect(string.find(hint, "Core", 1, true)).toBe(nil)
        expect(string.find(hint, "gradient", 1, true)).toBe(nil)
        expect(string.find(hint, "Gradient", 1, true)).toBe(nil)
      end
    end)

    test("Color, Heat and Strength each say what they do to the bolt", function()
      const attributes = params()
      const color = attributes.Gradient.calls.hint[1]
      const heat = attributes.Heat.calls.hint[1]
      const glow = attributes.Glow.calls.hint[1]

      expect(string.find(color, "One color", 1, true) ~= nil).toBe(true)
      expect(string.find(heat, "0 makes the core the bolt's color", 1, true) ~= nil).toBe(true)
      expect(string.find(heat, "1 a white center", 1, true) ~= nil).toBe(true)
      expect(string.find(glow, "0 leaves the bare core", 1, true) ~= nil).toBe(true)
      expect(attributes.Heat.calls.min[1]).toBe(0)
      expect(attributes.Heat.calls.max[1]).toBe(1)
      expect(attributes.Glow.calls.min[1]).toBe(0)
      expect(attributes.Glow.calls.max[1]).toBe(1)
    end)

    test("Color starts as a ColorSequence of one white", function()
      const default = params().Gradient.default
      const points = default.Keypoints
      const white = Color3.new(1, 1, 1)

      expect(typeof(default)).toBe("ColorSequence")
      expect(points[1].Value == white and points[#points].Value == white).toBe(true)
    end)

    test("the light takes a color of its own, so Brightness speaks of neither the rim nor the core", function()
      const hint = string.lower(params().Light.calls.hint[1])

      expect(string.find(hint, "rim", 1, true)).toBe(nil)
      expect(string.find(hint, "core", 1, true)).toBe(nil)
      expect(group("Light").entries).toEqual({ "Light", "LightColor" })
    end)

    test("a bolt draws a glow outside Tube while Glow is above 0 or animated", function()
      expect(rows.glowing("Glow", { value = 1, animated = false })).toBe(true)
      expect(rows.glowing("Segments", { value = 0.5, animated = false })).toBe(true)
      expect(rows.glowing("Segments", { value = 0, animated = true })).toBe(true)
      expect(rows.glowing("Glow", { value = 0, animated = false })).toBe(false)
      expect(rows.glowing("Tube", { value = 1, animated = false })).toBe(false)
      expect(rows.glowing("Tube", { value = 0, animated = true })).toBe(false)
    end)

    test("Rate hides while neither the loop nor a Duration runs", function()
      const attributes = params()

      expect(hides(attributes.Rate, { Enabled = false, EmitDuration = 0 })).toBe(true)
      expect(hides(attributes.Rate, { Enabled = true, EmitDuration = 0 })).toBe(false)
      expect(hides(attributes.Rate, { Enabled = false, EmitDuration = 2 })).toBe(false)
    end)

    test("a continuous bolt hides Rate and Hold only while the loop or a Duration runs", function()
      const attributes = params()
      const hold = group("Hold")

      for _, attrs in { { Enabled = true, EmitDuration = 0 }, { Enabled = false, EmitDuration = 2 } } do
        attrs.Continuous = true

        expect(hides(attributes.Rate, attrs)).toBe(true)
        expect(hold.hidden(nil, attrs, {}) == true).toBe(true)

        attrs.Continuous = false

        expect(hides(attributes.Rate, attrs)).toBe(false)
        expect(hold.hidden(nil, attrs, {}) == true).toBe(false)
      end

      expect(hides(attributes.Continuous, { Enabled = false, EmitDuration = 0 })).toBe(true)
      expect(hides(attributes.Continuous, { Enabled = true, EmitDuration = 0 })).toBe(false)
      expect(hides(attributes.Continuous, { Enabled = false, EmitDuration = 2 })).toBe(false)

      -- a plain emit's bolt holds for its Hold row, continuous or not
      expect(hold.hidden(nil, { Continuous = true, Enabled = false, EmitDuration = 0 }, {}) == true).toBe(false)
    end)

    test("Duration floors at 0 and says 0 emits once", function()
      const duration = params().EmitDuration

      expect(duration.calls.min[1]).toBe(0)
      expect(string.find(duration.calls.hint[1], "0 emits it once", 1, true) ~= nil).toBe(true)
    end)

    test("the appear time and curve hide for Instant", function()
      const attributes = params()

      for _, mode in { "Instant", "Grow", "Strike" } do
        const attrs = { Appear = mode }

        expect(hides(attributes.AppearTime, attrs)).toBe(mode == "Instant")
        expect(hides(attributes.AppearCurve, attrs)).toBe(mode == "Instant")
      end
    end)

    test("choice rows offer their modes and curves start at their preset", function()
      const attributes = params()

      expect(attributes.Target.calls.options[1]).toEqual({ "Direction", "End", "Ground" })
      expect(attributes.Style.calls.options[1]).toEqual({ "Tube", "Glow", "Segments" })
      expect(attributes.Motion.calls.options[1]).toEqual({ "Jitter", "Flow" })
      expect(attributes.Appear.calls.options[1]).toEqual({ "Instant", "Grow", "Strike" })
      expect(attributes.Disappear.calls.options[1]).toEqual({ "Thin", "Fade", "Retract", "Recoil" })
      expect(attributes.ImpactFacing.calls.options[1]).toEqual({ "Surface", "Bolt", "Upright" })
      expect(attributes.AppearCurve.calls.curve[1]).toBe("linear")
      expect(attributes.DisappearCurve.calls.curve[1]).toBe("easeIn")
    end)

    test("bounded rows keep their floors and ceilings", function()
      const attributes = params()

      expect(attributes.Count.calls.min[1]).toBe(1)
      expect(attributes.Reach.calls.min[1]).toBe(1)
      expect(attributes.Detail.calls.min[1]).toBe(2)
      expect(attributes.Detail.calls.max[1]).toBe(32)
      expect(attributes.Forks.calls.max[1]).toBe(8)
      expect(attributes.Jagged.calls.max[1]).toBe(0.5)
      expect(attributes.ForkLength.calls.min[1]).toBe(0.05)
      expect(attributes.Latch.calls.min[1]).toBe(0)

      for _, name in { "Jagged", "ForkLength", "Taper", "Heat", "Glow" } do
        expect(attributes[name].calls.slider ~= nil).toBe(true)
      end
    end)
  end)
end)
