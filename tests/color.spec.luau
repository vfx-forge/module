local lerp = require("@mod/lerp")
local color = require("@mod/color/color")
local harness = require("@tests/harness")

local test, expect = harness.test, harness.expect
local Color3 = harness.datatypes.Color3
local Vector3 = harness.datatypes.Vector3
local ColorSequence = harness.datatypes.ColorSequence
local NumberSequence = harness.datatypes.NumberSequence
local ColorSequenceKeypoint = harness.datatypes.ColorSequenceKeypoint
local NumberSequenceKeypoint = harness.datatypes.NumberSequenceKeypoint

local EPSILON = 1e-5

local RED = Color3.new(1, 0, 0)
local BLUE = Color3.new(0, 0, 1)

local function same(a: Color3, b: Color3): boolean
  return math.abs(a.R - b.R) < EPSILON and math.abs(a.G - b.G) < EPSILON and math.abs(a.B - b.B) < EPSILON
end

harness.suite(function()
  harness.describe("color", function()
    test("a color goes to Oklab and back unchanged", function()
      for _, c in { RED, BLUE, Color3.new(0.2, 0.7, 0.4), Color3.new(1, 1, 1) } do
        expect(same(color.fromOklab(color.toOklab(c)), c)).toBe(true)
      end
    end)

    test("a blend starts and ends on its colors and blends in Oklab between", function()
      local middle = color.fromOklab(color.toOklab(RED):Lerp(color.toOklab(BLUE), 0.5))

      expect(same(color.blend(RED, BLUE, 0), RED)).toBe(true)
      expect(same(color.blend(RED, BLUE, 1), BLUE)).toBe(true)
      expect(same(color.blend(RED, BLUE, 0.5), middle)).toBe(true)
      expect(same(color.blend(RED, BLUE, 0.5), RED:Lerp(BLUE, 0.5))).toBe(false)
    end)

    test("an Oklab color past the range is clamped unless asked not to be", function()
      local bright = Vector3.new(1.2, 0, 0)

      expect(color.fromOklab(bright).R).toBe(1)
      expect(color.fromOklab(bright, true).R > 1).toBe(true)
      expect(color.blend(RED, Color3.new(2, 0, 0), 1, true).R > 1).toBe(true)
    end)

    test("an Oklab color is in gamut only where a clamp would leave it", function()
      local blue = color.toOklab(BLUE)
      local white = color.toOklab(Color3.new(1, 1, 1))

      expect(color.inGamut(color.toOklab(Color3.new(0.2, 0.7, 0.4)))).toBe(true)
      expect(color.inGamut(blue:Lerp(white, 0.5))).toBe(false)
      expect(color.inGamut(Vector3.new(1.2, 0, 0))).toBe(false)
    end)

    test("a sequence's color is its ends outside them, its keypoints on them and a blend between", function()
      local sequence = ColorSequence.new({
        ColorSequenceKeypoint.new(0, RED),
        ColorSequenceKeypoint.new(0.5, BLUE),
        ColorSequenceKeypoint.new(1, BLUE),
      })

      expect(same(color.sequenceAt(sequence, -1), RED)).toBe(true)
      expect(same(color.sequenceAt(sequence, 0.5), BLUE)).toBe(true)
      expect(same(color.sequenceAt(sequence, 2), BLUE)).toBe(true)
      expect(same(color.sequenceAt(sequence, 0.25), color.blend(RED, BLUE, 0.5))).toBe(true)
    end)
  end)

  harness.describe("lerp's colors", function()
    test("a Color3 blends as color.blend does", function()
      expect(same(lerp.any(RED, BLUE, 0.3), color.blend(RED, BLUE, 0.3))).toBe(true)
    end)

    test("a ColorSequence blends each of the far sequence's keypoints in Oklab", function()
      local a = ColorSequence.new(RED)
      local b = ColorSequence.new({
        ColorSequenceKeypoint.new(0, BLUE),
        ColorSequenceKeypoint.new(0.4, Color3.new(0, 1, 0)),
        ColorSequenceKeypoint.new(1, BLUE),
      })
      local blended = lerp.any(a, b, 0.5)

      expect(#blended.Keypoints).toBe(3)

      for i, keypoint in blended.Keypoints do
        local far = b.Keypoints[i]

        expect(keypoint.Time).toBe(far.Time)
        expect(same(keypoint.Value, color.blend(RED, far.Value, 0.5))).toBe(true)
      end
    end)

    test("a ColorSequence reads the near sequence as color.sequenceAt does", function()
      local white = Color3.new(1, 1, 1)
      local a = ColorSequence.new({
        ColorSequenceKeypoint.new(0, RED),
        ColorSequenceKeypoint.new(0.3, BLUE),
        ColorSequenceKeypoint.new(0.6, white),
        ColorSequenceKeypoint.new(1, Color3.new(0.2, 0.7, 0.4)),
      })
      local b = ColorSequence.new({
        ColorSequenceKeypoint.new(0, BLUE),
        ColorSequenceKeypoint.new(0.15, white),
        ColorSequenceKeypoint.new(0.3, RED),
        ColorSequenceKeypoint.new(0.45, Color3.new(0, 1, 0)),
        ColorSequenceKeypoint.new(0.5, BLUE),
        ColorSequenceKeypoint.new(1, white),
      })

      for _, t in { 0, 0.35, 1 } do
        local blended = lerp.any(a, b, t)

        for i, keypoint in blended.Keypoints do
          local far = b.Keypoints[i]

          expect(keypoint.Time).toBe(far.Time)
          expect(same(keypoint.Value, color.blend(color.sequenceAt(a, far.Time), far.Value, t))).toBe(true)
        end
      end
    end)

    test("a NumberSequence blend past the engine's 20 keypoints keeps 20 and warns once", function()
      local function sequence(count: number, offset: number): NumberSequence
        local keypoints = {}

        for i = 0, count - 1 do
          table.insert(keypoints, NumberSequenceKeypoint.new(math.min(i / (count - 1) + offset, 1), i))
        end

        keypoints[1] = NumberSequenceKeypoint.new(0, 0)

        return NumberSequence.new(keypoints)
      end

      local blends = {}

      local warnings = harness.captureWarnings(function()
        blends[1] = lerp.any(sequence(15, 0), sequence(15, 0.01), 0.5)
        blends[2] = lerp.any(sequence(15, 0), sequence(15, 0.02), 0.5)
      end)

      local told = 0

      for _, warning in warnings do
        if string.find(warning, "past the engine's 20", 1, true) then
          told += 1
        end
      end

      expect(#blends[1].Keypoints).toBe(20)
      expect(#blends[2].Keypoints).toBe(20)
      expect(told).toBe(1)
    end)
  end)
end)
