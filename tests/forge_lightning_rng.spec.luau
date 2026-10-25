const rng = require("@mod/lightning/rng")
const harness = require("@tests/harness")
const describe, test, expect = harness.describe, harness.test, harness.expect

harness.suite(function()
  describe("rng", function()
    test("one seed makes one sequence", function()
      const a = rng.generator(42)
      const b = rng.generator(42)
      local agree = true
      local inside = true

      for _ = 1, 1000 do
        const x = a()

        if x ~= b() then
          agree = false
        end

        if x <= 0 or x >= 1 then
          inside = false
        end
      end

      expect(agree).toBe(true)
      expect(inside).toBe(true)
    end)

    test("two seeds differ", function()
      expect(rng.generator(1)() ~= rng.generator(2)()).toBe(true)
    end)
  end)
end)
