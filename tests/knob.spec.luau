local fs = require("@lune/fs")
local mod = require("@mod/mod")
local knob = require("@mod/knob")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Vector3 = harness.datatypes.Vector3
local NumberRange = harness.datatypes.NumberRange

harness.suite(function()
  harness.describe("knob", function()
    test("a plain default is the resting value", function()
      local row = knob(3)

      expect(knob.is(row)).toBe(true)
      expect(row.default).toBe(3)
      expect(row.hasDefault).toBe(true)
      expect(row.rule).toBe(nil)
      expect(row.isMod).toBe(false)
    end)

    test("a function default is a rule", function()
      local fn = function()
        return 1
      end

      local row = knob(fn)

      expect(row.rule).toBe(fn)
      expect(row.hasDefault).toBe(false)
    end)

    test("no default is a property row that takes the instance's value", function()
      local row = knob()

      expect(row.hasDefault).toBe(false)
      expect(row.default).toBe(nil)
    end)

    test("a row keeps the kind of its default, with a vector spelled one way", function()
      expect(knob(3).kind).toBe("number")
      expect(knob(NumberRange.new(0, 1)).kind).toBe("NumberRange")
      expect(knob(Vector3.new(1, 1, 1)).kind).toBe("Vector3")
      expect(knob(vector.create(1, 1, 1)).kind).toBe("Vector3")
      expect(knob().kind).toBe(nil)
      expect(knob(function()
        return 1
      end).kind).toBe(nil)
    end)

    test("every chain method returns the same knob", function()
      local row = knob(1)
      local same = row:min(0):max(2):aliases("A", "B"):label("One"):hint("h"):curve("linear"):unit("seconds"):mod()

      expect(same).toBe(row)
      expect(row.lower).toBe(0)
      expect(row.upper).toBe(2)
      expect(row.names[1]).toBe("A")
      expect(row.names[2]).toBe("B")
      expect(row.title).toBe("One")
      expect(row.details).toBe("h")
      expect(row.preset).toBe("linear")
      expect(row.units).toBe("seconds")
      expect(row.isMod).toBe(true)
      expect(row.modDefault).toBe(nil)
    end)

    test("declaration order survives the table it is listed in", function()
      local first = knob(1)
      local second = knob(2)

      expect(second.order > first.order).toBe(true)
    end)

    test("hidden and readonly take rules", function()
      local fn = function()
        return true
      end

      local row = knob("x"):hidden(fn):readonly(fn):options({ "x", "y" })

      expect(row.hiddenRule).toBe(fn)
      expect(row.readonlyRule).toBe(fn)
      expect(row.choices[2]).toBe("y")
    end)

    test("mod takes any number of specs, and none is still a mod row", function()
      local bare = knob(1):mod()
      local one = knob(1):mod(mod.to(2))
      local two = knob(1):mod(mod.to(2), mod.from(0):lane("dissipate"))

      expect(bare.isMod).toBe(true)
      expect(bare.modDefault).toBe(nil)
      expect(#one.modDefault).toBe(1)
      expect(#two.modDefault).toBe(2)
      expect(two.modDefault[2].opts.lane).toBe("dissipate")
    end)
  end)

  harness.describe("knob.clamp", function()
    test("a number clamps between number bounds", function()
      expect(knob.clamp(5, 0, 2)).toBe(2)
      expect(knob.clamp(-1, 0, nil)).toBe(0)
      expect(knob.clamp(1, nil, nil)).toBe(1)
    end)

    test("a number bound applies to both ends of a range", function()
      local r = knob.clamp(NumberRange.new(-1, 9), 0, 5)

      expect(r.Min).toBe(0)
      expect(r.Max).toBe(5)
    end)

    test("a range bound applies fieldwise", function()
      local r = knob.clamp(NumberRange.new(-1, 9), NumberRange.new(0, 1), NumberRange.new(4, 5))

      expect(r.Min).toBe(0)
      expect(r.Max).toBe(5)
    end)

    test("a vector clamps per component against a number", function()
      local v = knob.clamp(Vector3.new(-1, 0.5, 9), 0, 1)

      expect(v.X).toBe(0)
      expect(v.Y).toBe(0.5)
      expect(v.Z).toBe(1)
    end)

    test("a vector clamps fieldwise against a vector", function()
      local v = knob.clamp(Vector3.new(-1, 5, 9), Vector3.new(0, 0, 0), Vector3.new(1, 2, 3))

      expect(v.X).toBe(0)
      expect(v.Y).toBe(2)
      expect(v.Z).toBe(3)
    end)

    test("an unordered value is returned as it is", function()
      expect(knob.clamp("abc", 0, 1)).toBe("abc")
      expect(knob.ordered("abc")).toBe(false)
      expect(knob.ordered(true)).toBe(false)
      expect(knob.ordered(1)).toBe(true)
      expect(knob.ordered(NumberRange.new(0, 1))).toBe(true)
      expect(knob.ordered(Vector3.new(0, 0, 0))).toBe(true)
    end)

    test("the sdk's unit types name exactly the units a knob takes", function()
      local expected = {}

      for unit in knob.UNITS do
        table.insert(expected, unit)
      end

      table.sort(expected)

      local source = fs.readFile("src/sdk/v1/types.luau")
      local union = string.match(source, "export type Unit = ([^\n]+)") :: string
      local named = {}

      for unit in string.gmatch(union, '"(%w+)"') do
        table.insert(named, unit)
      end

      table.sort(named)

      local typed = string.match(fs.readFile("index.d.ts"), "export type Unit =([^;]+);") :: string
      local declared = {}

      for unit in string.gmatch(typed, '"(%w+)"') do
        table.insert(declared, unit)
      end

      table.sort(declared)

      expect(named).toEqual(expected)
      expect(declared).toEqual(expected)
    end)
  end)
end)
