local numeric = require("@mod/common/numeric")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Vector2 = harness.datatypes.Vector2
local Vector3 = harness.datatypes.Vector3
local NumberRange = harness.datatypes.NumberRange

local NAN = 0 / 0

harness.suite(function()
  harness.describe("numeric.finite", function()
    test("accepts an ordinary number and zero", function()
      expect(numeric.finite(1.5)).toBe(true)
      expect(numeric.finite(0)).toBe(true)
      expect(numeric.finite(-3)).toBe(true)
    end)

    test("rejects nan and both infinities", function()
      expect(numeric.finite(NAN)).toBe(false)
      expect(numeric.finite(math.huge)).toBe(false)
      expect(numeric.finite(-math.huge)).toBe(false)
    end)
  end)

  harness.describe("numeric.usable", function()
    test("a value that is not numeric is always usable", function()
      expect(numeric.usable("text")).toBe(true)
      expect(numeric.usable(true)).toBe(true)
      expect(numeric.usable(nil)).toBe(true)
    end)

    test("checks every component of a vector", function()
      expect(numeric.usable(Vector3.new(1, 2, 3))).toBe(true)
      expect(numeric.usable(Vector3.new(1, NAN, 3))).toBe(false)
      expect(numeric.usable(Vector2.new(math.huge, 0))).toBe(false)
    end)

    test("checks both ends of a range", function()
      expect(numeric.usable(NumberRange.new(0, 1))).toBe(true)
      expect(numeric.usable(NumberRange.new(NAN, NAN))).toBe(false)
    end)
  end)
end)
