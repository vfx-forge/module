local value = require("@mod/value")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Color3 = harness.datatypes.Color3
local Vector3 = harness.datatypes.Vector3

harness.suite(function()
  harness.describe("value", function()
    test("lit wraps a concrete value", function()
      local v = value.lit(Color3.new(1, 0, 0))
      expect(v.t).toBe("lit")
      expect(value.isLit(v)).toBe(true)
      expect(value.resolve(v)).toBe(Color3.new(1, 0, 0))
    end)
    test("var resolves to nil with no environment but is a valid Value", function()
      local v = value.var("MyVar")
      expect(v.t).toBe("var")
      expect(value.isVar(v)).toBe(true)
      expect(value.isLit(v)).toBe(false)
      expect(value.isDraw(v)).toBe(false)
      expect(value.resolve(v)).toBe(nil)
    end)
    test("only a var is a var", function()
      expect(value.isVar(value.lit(1))).toBe(false)
      expect(value.isVar(value.draw(1, 2))).toBe(false)
    end)
    -- a var names a value belonging to the whole emitted instance, so it
    -- resolves against what the caller drew ONCE for that instance
    test("var resolves against an environment", function()
      local v = { t = "var", ref = "Lifetime" } :: any
      expect(value.resolve(v, nil, { Lifetime = 2.5 })).toBe(2.5)
      expect(value.resolve(v, nil, { Lifetime = false })).toBe(false)
    end)
    test("var resolves to nil for a name the environment does not carry", function()
      local v = { t = "var", ref = "Lifetime" } :: any
      expect(value.resolve(v, nil, { Something = 2.5 })).toBe(nil)
      expect(value.resolve(v, nil, {})).toBe(nil)
    end)
    -- that is the whole difference between the two tags: two rows each holding
    -- a draw draw twice, two rows naming one var read one value
    test("two vars naming one entry resolve to the same value", function()
      local env = { Lifetime = 1.75 }
      local a = { t = "var", ref = "Lifetime" } :: any
      local b = { t = "var", ref = "Lifetime" } :: any
      expect(value.resolve(a, nil, env)).toBe(value.resolve(b, nil, env))
    end)
    test("a lit and a draw ignore an environment", function()
      expect(value.resolve(value.lit(7), nil, { v = 9 })).toBe(7)
      expect(value.resolve(value.draw(10, 20), 0, { min = 99 })).toBe(10)
    end)
    test("draw resolves at the alpha it is handed", function()
      local v = value.draw(10, 20)
      expect(v.t).toBe("draw")
      expect(value.isDraw(v)).toBe(true)
      expect(value.isLit(v)).toBe(false)
      expect(value.resolve(v, 0)).toBe(10)
      expect(value.resolve(v, 1)).toBe(20)
      expect(value.resolve(v, 0.25)).toBe(12.5)
    end)
    -- an editor row has no draw to show, and nor does a pure evaluate, so both
    -- get the midpoint rather than nothing at all
    test("draw resolves at its midpoint with no alpha", function()
      expect(value.resolve(value.draw(10, 20))).toBe(15)
      expect(value.resolve(value.draw(4, 4))).toBe(4)
    end)
    test("a lit ignores an alpha", function()
      expect(value.resolve(value.lit(7), 0.9)).toBe(7)
    end)
    -- a draw carries the row's own type rather than a pair of numbers, which
    -- is what lets an endpoint be drawn on any row a randomizer entry serves
    test("a draw resolves through the typed lerp", function()
      expect(value.resolve(value.draw(Vector3.new(0, 0, 0), Vector3.new(2, 4, 6)), 0.5)).toEqual(Vector3.new(1, 2, 3))
      expect(value.resolve(value.draw(Color3.new(0, 0, 0), Color3.new(1, 1, 1)), 0) :: any).toEqual(Color3.new(0, 0, 0))
    end)
    -- the weight curve rides the endpoint for the sampler to shape the pick
    -- with; resolve itself takes the alpha it is handed and nothing else
    test("a weight rides the draw and resolve does not apply it", function()
      local weighted = value.draw(0, 10, "curve")
      expect(weighted.weight ~= nil).toBe(true)
      expect(value.resolve(weighted, 0.25)).toBe(2.5)
    end)
  end)
end)
