const harness = require("@tests/harness")
const resize = require("@mod/resize")

const test, expect = harness.test, harness.expect

const function near(a: vector, b: vector): boolean
  return vector.magnitude(a - b) < 1e-9
end

const function count(t: { [any]: any }): number
  local n = 0

  for _ in t do
    n += 1
  end

  return n
end

harness.suite(function()
  harness.describe("resize.moves", function()
    const at = {
      a = vector.create(0, 0, 0),
      b = vector.create(10, 0, 0),
      c = vector.create(10, 10, 0),
      d = vector.create(0, 10, 0),
    }

    const function where(key: string): vector
      return at[key]
    end

    test("a lone pair spreads about its midpoint", function()
      const moves = resize.moves({ { "a", "b" } }, where, 2)

      expect(near(moves.a, vector.create(-5, 0, 0))).toBe(true)
      expect(near(moves.b, vector.create(15, 0, 0))).toBe(true)
    end)

    test("ten beams on one pair move it once, not ten times", function()
      const pairs = {}

      for _ = 1, 10 do
        table.insert(pairs, { "a", "b" })
      end

      table.insert(pairs, { "b", "a" })

      const moves = resize.moves(pairs, where, 2)

      expect(count(moves)).toBe(2)
      expect(near(moves.a, vector.create(-5, 0, 0))).toBe(true)
      expect(near(moves.b, vector.create(15, 0, 0))).toBe(true)
    end)

    test("a ring of pairs keeps its shape about its own center", function()
      const moves = resize.moves({ { "a", "b" }, { "b", "c" }, { "c", "d" }, { "d", "a" } }, where, 2)
      const center = vector.create(5, 5, 0)

      expect(count(moves)).toBe(4)

      for key, from in at do
        expect(near(moves[key], center + (from - center) * 2)).toBe(true)
      end
    end)

    test("pairs that share nothing each keep their own center", function()
      const moves = resize.moves({ { "a", "b" }, { "c", "d" } }, where, 0.5)

      expect(near(moves.a, vector.create(2.5, 0, 0))).toBe(true)
      expect(near(moves.b, vector.create(7.5, 0, 0))).toBe(true)
      expect(near(moves.c, vector.create(7.5, 10, 0))).toBe(true)
      expect(near(moves.d, vector.create(2.5, 10, 0))).toBe(true)
    end)
  end)
end)
