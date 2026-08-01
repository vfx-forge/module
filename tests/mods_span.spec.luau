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
  end)
end)
