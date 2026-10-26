local harness = require("@tests/harness")
local effects = require("@srv/effects")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect

local load = require("@root/sdk/load")
local facade = require("@root/sdk/v1/facade")
local forge_lightning = require("@vfx/forge_lightning")

local CLEAN = 100000
local CHANGED = 2000

-- a call per bolt per frame, against the lightning's own forty rows: the clean
-- call a continuous bolt makes every frame, and the read after a change
local function measured(): (number, number)
  local lightning = load.assemble(forge_lightning, "forge_lightning")
  local touch: (() -> ())? = nil
  local clean, changed = math.huge, math.huge
  local real = facade.seams.watch

  facade.seams.watch = function(_: Instance, _: any, touched: () -> ())
    touch = touched

    return {}
  end

  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)

  registry.register({
    id = "refresh_cost",
    display = { name = "refresh_cost" },
    classifier = "Folder",
    attributes = lightning.attributes,
    properties = lightning.properties,
    emit = function(ctx: any, attrs: any, props: any)
      facade.run(function(sdk: any, view: any)
        sdk.refresh(view)

        for _ = 1, 3 do
          local started = os.clock()

          for _ = 1, CLEAN do
            sdk.refresh(view)
          end

          clean = math.min(clean, (os.clock() - started) / CLEAN)
          started = os.clock()

          for _ = 1, CHANGED do
            (touch :: () -> ())()
            sdk.refresh(view)
          end

          changed = math.min(changed, (os.clock() - started) / CHANGED)
        end
      end, ctx, attrs, props)
    end,
  })

  effects.emit(0, harness.make("Folder"))
  facade.seams.watch = real
  registry.clear()

  return clean, changed
end

harness.suite(function()
  harness.describe("the cost of sdk.refresh", function()
    test("a call with nothing changed is a lookup, and a read after a change stays well under a frame", function()
      local clean, changed = measured()

      print(
        `sdk.refresh over the lightning's rows: {string.format("%.3f", clean * 1e6)} us clean, {string.format(
          "%.1f",
          changed * 1e6
        )} us after a change`
      )

      expect(clean < 1e-6).toBe(true)
      expect(changed < 2e-4).toBe(true)
    end)
  end)
end)
