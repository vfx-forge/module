local mods = require("@mod/mods")
local value = require("@mod/value")
local frame = require("@mod/modifier_frame")
local modifiers = require("@mod/modifiers")
local rows = require("@mod/lightning/rows")
local knob = require("@mod/knob")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance

frame.configure(harness.fakeEncoding, harness.fakeCompression)

const function randomizer(a: number, b: number)
  return { kind = "randomizer", chain = false, start = value.lit(a), finish = value.lit(b) }
end

-- the share of alphas spread evenly over 0 to 1 that land on each value
const function spread(draw: (alpha: number) -> number): { [number]: number }
  const out = {}
  const n = 3000

  for i = 0, n - 1 do
    const v = draw((i + 0.5) / n)
    out[v] = (out[v] or 0) + 1 / n
  end

  return out
end

-- a generator lent to the roll, so a build draws where a spec says
const function lent(alpha: number): any
  return {
    NextNumber = function()
      return alpha
    end,
  }
end

harness.suite(function()
  harness.describe("a randomizer on a whole number row", function()
    test("draws every whole number between its ends alike, the far end included", function()
      const shares = spread(function(alpha)
        return modifiers.drawn(1, 3, alpha, true)
      end)

      for _, v in { 1, 2, 3 } do
        expect(math.abs(shares[v] - 1 / 3) < 1e-3).toBe(true)
      end

      expect(modifiers.drawn(1, 3, 1, true)).toBe(3)
      expect(modifiers.drawn(3, 1, 0, true)).toBe(3)
      expect(modifiers.drawn(3, 1, 1, true)).toBe(1)
    end)

    test("draws the whole numbers inside fractional ends", function()
      const shares = spread(function(alpha)
        return modifiers.drawn(0.5, 2.5, alpha, true)
      end)

      expect(shares[0]).toBe(nil)
      expect(math.abs(shares[1] - 0.5) < 1e-3).toBe(true)
      expect(math.abs(shares[2] - 0.5) < 1e-3).toBe(true)
    end)

    test("leaves every other row and value as a plain draw", function()
      expect(modifiers.drawn(1, 3, 0.5, false)).toBe(2)
      expect(modifiers.drawn(1, 3, 0.25, nil)).toBe(1.5)
      expect(modifiers.drawn(1.2, 1.8, 0.5, true)).toBe(1.5)
    end)

    test("reaches a built row only when the knob is whole", function()
      const lanes = { start = { randomizer(1, 3) } }

      mods.random = lent(0.95)

      const whole = mods.build(Instance.new("Attachment"), "attribute", "Restrikes", 1, 1, nil, lanes, true, {
        whole = true,
      })
      const plain = mods.build(Instance.new("Attachment"), "attribute", "Restrikes", 1, 1, nil, lanes, true, nil)

      mods.random = nil

      expect(whole.at(0)).toBe(3)
      expect(math.abs(plain.at(0) - 2.9) < 1e-9).toBe(true)
    end)

    test("a lone tween on a whole number row keeps the build's fast path", function()
      const tween = { kind = "tween", chain = false, duration = 1, start = value.lit(1), finish = value.lit(3) }
      const lanes = { start = { tween } }

      -- the reader hands a whole row that says nothing else this one table
      expect(mods.WHOLE.whole).toBe(true)

      const track, share =
        mods.build(Instance.new("Attachment"), "attribute", "Count", 1, 1, nil, lanes, true, mods.WHOLE)

      -- the fast path hands every piece its one track
      expect((share :: any)(mods.piece())).toBe(track)
      expect(track.at(0.5)).toBe(2)
    end)

    test("lightning's counted rows are whole and its measured ones are not", function()
      const attrs = rows.params({ knob = knob }).attributes

      for _, name in { "Count", "Detail", "Forks", "Restrikes" } do
        expect(attrs[name].isWhole).toBe(true)
      end

      for _, name in { "Width", "Jitter", "Light", "DisappearTime" } do
        expect(attrs[name].isWhole).toBe(false)
      end
    end)
  end)
end)
