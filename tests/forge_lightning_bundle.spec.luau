local harness = require("@tests/harness")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect

local load = require("@root/sdk/load")
local lightning = require("@vfx/lightning")
local forge_lightning = require("@vfx/forge_lightning")

harness.suite(function()
  harness.describe("the bundled lightning", function()
    test("assembles with no problems and registers as a bundled custom effect", function()
      registry.clear()

      local module, found = load.assemble(forge_lightning, "forge_lightning")

      expect(table.concat(found, "\n")).toBe("")
      expect(module ~= nil).toBe(true)

      registry.register(module, true, true)

      local held = registry.get("forge_lightning") :: any

      expect(held.display.name).toBe("Lightning")
      expect(registry.isCustom(held)).toBe(true)
      expect(registry.isBundled(held)).toBe(true)

      registry.clear()
    end)

    test("leaves a custom effect the place holds unbundled", function()
      registry.clear()

      local module = load.assemble(forge_lightning, "forge_lightning")

      registry.register(module, true)

      expect(registry.isBundled(registry.get("forge_lightning") :: any)).toBe(false)

      registry.clear()
    end)

    test("names the old lightning as legacy", function()
      expect(lightning.display.name).toBe("Legacy Lightning")
    end)
  end)
end)
