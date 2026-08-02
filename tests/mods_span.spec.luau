local mods = require("@mod/mods")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect

-- only the pure half is reachable under lune; requiring mods here must not
-- touch game, which is why mods resolves EncodingService lazily through
-- modifier_frame rather than at module scope
harness.suite(function()
  harness.describe("mods.attrName", function()
    test("picks a prefix per source", function()
      expect(mods.attrName("property", "Transparency")).toBe("ForgePropMods_Transparency")
      expect(mods.attrName("attribute", "Scale")).toBe("ForgeAttrMods_Scale")
    end)
  end)

  harness.describe("mods.span", function()
    test("takes the longest explicit duration", function()
      expect(mods.span({ { duration = 0.5 }, { duration = 2 }, { duration = 1 } }, 9)).toBe(2)
    end)

    test("falls back when every modifier is linked", function()
      expect(mods.span({ { chain = false }, { chain = true } }, 9)).toBe(9)
    end)

    test("falls back on an empty queue", function()
      expect(mods.span({}, 9)).toBe(9)
    end)

    -- a delay pushes what follows it out, so the span is the far end of the
    -- queue rather than its longest single duration
    test("counts the wait a delay imposes", function()
      local queue = {
        { kind = "tween", duration = 1 },
        { kind = "delay", wait = { t = "lit", v = 2 } },
        { kind = "tween", duration = 0.5 },
      }

      expect(mods.span(queue, 9)).toBe(3.5)
    end)

    -- the span has to be the one THIS instance will run, so a drawn wait is
    -- spanned at the value drawn for it rather than at its midpoint
    test("spans a drawn wait at the value the rolls drew", function()
      local queue = {
        { kind = "delay", wait = { t = "rand", min = 0, max = 4 } },
        { kind = "tween", duration = 1 },
      }

      local rolls = { draws = {}, picks = { [1] = { wait = 0.25 } }, envelope = 0 }

      expect(mods.span(queue, 9)).toBe(3)
      expect(mods.span(queue, 9, rolls)).toBe(2)
    end)

    test("a delay alone still spans its own wait", function()
      expect(mods.span({ { kind = "delay", wait = { t = "lit", v = 2 } } }, 9)).toBe(2)
    end)
  end)
end)
