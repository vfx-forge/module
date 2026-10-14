local curve = require("@mod/curve")
local tween = require("@mod/tween")
local curves = require("@mod/curves")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

local custom = require("@root/sdk/custom")

local ROUNDS = 5
local EMITS = 300

local function fresh()
  custom.clear()
  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
end

-- the same fade written against the internals, as a built-in would write it
local builtin = {
  id = "builtin_fade",
  display = { name = "Built-in fade" },
  classifier = "BasePart.BuiltinFade",
  attributes = {},
  properties = {},
  emit = function(ctx: any)
    local w = lifetime.write(ctx.scope, ctx.ref, "property", "Transparency")

    tween.wait(ctx.scope, curve.new(0.5, curves.PRESETS.easeOut), function(alpha: number)
      lifetime.set(w, alpha)
    end)
  end,
}

local fade = {
  sdk_version = 1,
  id = "custom_fade",
  display = { name = "Custom fade" },
  classifier = "BasePart.CustomFade",
  emit = function(sdk: any, ctx: any)
    local w = sdk.getWriter(ctx, ctx.ref, "Transparency")

    sdk.tween(ctx, sdk.curve(0.5, "easeOut"), function(alpha: number)
      w:set(alpha)
    end)
  end,
}

local function tagged(tag: string): Instance
  local part = harness.make("Part", harness.make("Folder"))

  part:AddTag(tag)

  return part
end

-- the fade's transparency a frame in, so a variant that never ran cannot pass
local function midway(part: Instance)
  effects.emit(0, part)
  scheduler.frame(0.2)

  local seen = (part :: any).Transparency

  scheduler.frame(0.2)
  scheduler.frame(0.2)

  return seen
end

-- one emit played to its end: three frames of a half second fade
local function timed(part: Instance)
  local started = os.clock()

  for _ = 1, EMITS do
    effects.emit(0, part)
    scheduler.frame(0.2)
    scheduler.frame(0.2)
    scheduler.frame(0.2)
  end

  return os.clock() - started
end

harness.suite(function()
  harness.describe("the cost of a custom effect", function()
    test("a custom effect costs no more per emit than a built-in of the same shape", function()
      fresh()

      local old, new = math.huge, math.huge
      local builtinPart, customPart = tagged("BuiltinFade"), tagged("CustomFade")

      -- each measured with only itself registered, so neither pays for
      -- classifying past the other
      for _ = 1, ROUNDS do
        custom.clear()
        registry.clear()
        registry.register(builtin)
        expect(midway(builtinPart) > 0).toBe(true)
        old = math.min(old, timed(builtinPart))

        registry.clear()
        expect((custom.add("fade", fade, "fade"))).toBe(true)
        expect(midway(customPart) > 0).toBe(true)
        new = math.min(new, timed(customPart))
      end

      custom.clear()

      print(
        `emit cost over {EMITS} emits: built-in {string.format("%.2f", old * 1000)} ms, custom {string.format(
          "%.2f",
          new * 1000
        )} ms`
      )

      expect(new <= old * 1.1).toBe(true)
    end)
  end)
end)
