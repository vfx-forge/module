local value = require("@mod/value")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Color3 = harness.datatypes.Color3

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
      expect(value.isRand(v)).toBe(false)
      expect(value.resolve(v)).toBe(nil)
    end)
    test("only a var is a var", function()
      expect(value.isVar(value.lit(1))).toBe(false)
      expect(value.isVar(value.rand(1, 2))).toBe(false)
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
    -- a rand draw twice, two rows naming one var read one value
    test("two vars naming one entry resolve to the same value", function()
      local env = { Lifetime = 1.75 }
      local a = { t = "var", ref = "Lifetime" } :: any
      local b = { t = "var", ref = "Lifetime" } :: any
      expect(value.resolve(a, nil, env)).toBe(value.resolve(b, nil, env))
    end)
    test("a lit and a rand ignore an environment", function()
      expect(value.resolve(value.lit(7), nil, { v = 9 })).toBe(7)
      expect(value.resolve(value.rand(10, 20), 0, { min = 99 })).toBe(10)
    end)
    test("rand resolves at the draw it is handed", function()
      local v = value.rand(10, 20)
      expect(v.t).toBe("rand")
      expect(value.isRand(v)).toBe(true)
      expect(value.isLit(v)).toBe(false)
      expect(value.resolve(v, 0)).toBe(10)
      expect(value.resolve(v, 1)).toBe(20)
      expect(value.resolve(v, 0.25)).toBe(12.5)
    end)
    -- an editor row has no draw to show, and nor does a pure evaluate, so both
    -- get the midpoint rather than nothing at all
    test("rand resolves at its midpoint with no draw", function()
      expect(value.resolve(value.rand(10, 20))).toBe(15)
      expect(value.resolve(value.rand(4, 4))).toBe(4)
    end)
    test("a lit ignores a draw", function()
      expect(value.resolve(value.lit(7), 0.9)).toBe(7)
    end)
  end)
end)
