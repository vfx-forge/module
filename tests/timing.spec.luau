local timing = require("@mod/common/timing")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect

local NAN = 0 / 0

harness.suite(function()
  harness.describe("timing.duration", function()
    test("keeps a positive finite duration", function()
      expect(timing.duration(2.5)).toBe(2.5)
    end)

    test("collapses nan, infinity and negatives to zero", function()
      expect(timing.duration(NAN)).toBe(0)
      expect(timing.duration(math.huge)).toBe(0)
      expect(timing.duration(-1)).toBe(0)
    end)
  end)

  harness.describe("timing.progress", function()
    test("is the clamped fraction of a positive duration", function()
      expect(timing.progress(1, 4)).toBe(0.25)
      expect(timing.progress(8, 4)).toBe(1)
      expect(timing.progress(-1, 4)).toBe(0)
    end)

    test("is one for a zero duration instead of nan", function()
      expect(timing.progress(0, 0)).toBe(1)
      expect(timing.progress(0.5, 0)).toBe(1)
    end)
  end)

  harness.describe("timing.done", function()
    test("a positive duration is done once elapsed reaches it", function()
      expect(timing.done(3.9, 4)).toBe(false)
      expect(timing.done(4, 4)).toBe(true)
    end)

    test("a zero duration is done once any time has passed", function()
      expect(timing.done(0, 0)).toBe(false)
      expect(timing.done(0.001, 0)).toBe(true)
    end)
  end)
end)
