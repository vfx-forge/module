local harness = require("@tests/harness")
local screen_common = require("@mod/common/screen")
local test, expect = harness.test, harness.expect
local Vector2 = harness.datatypes.Vector2
local Vector3 = harness.datatypes.Vector3

harness.suite(function()
  harness.describe("screen_common.size", function()
    test("a Vector3 scale scales all three axes", function()
      expect(screen_common.size(10, 5, 1, Vector3.new(2, 3, 4))).toEqual(Vector3.new(20, 15, 4))
    end)

    test("a Vector2 scale leaves the depth alone, which is what the plugin schema writes now", function()
      expect(screen_common.size(10, 5, 0.5, Vector2.new(2, 3))).toEqual(Vector3.new(20, 15, 0.5))
    end)

    test("a native vector scale scales all three axes, matching PartScale's own default", function()
      expect(screen_common.size(10, 5, 1, vector.create(2, 3, 4))).toEqual(Vector3.new(20, 15, 4))
    end)

    test("a number scales width and height", function()
      expect(screen_common.size(10, 5, 0.5, 2)).toEqual(Vector3.new(20, 10, 0.5))
    end)

    test("anything else is no scale at all", function()
      expect(screen_common.size(10, 5, 0.5, "oops")).toEqual(Vector3.new(10, 5, 0.5))
    end)
  end)
end)
