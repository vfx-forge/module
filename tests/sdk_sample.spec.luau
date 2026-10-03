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
local sample = require("@docs/sdk/v1/sample")

local Color3 = harness.datatypes.Color3
local Vector3 = harness.datatypes.Vector3

local ROUNDS = 5
local EMITS = 300

local function fresh()
  custom.clear()
  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
end

local function pulse(): Part
  local part = harness.make("Part", harness.make("Folder")) :: Part

  part:AddTag("Pulse")
  part.Transparency = 0
  part.Size = Vector3.new(2, 2, 2)
  part.Color = Color3.new(0, 0, 0)

  return part
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
  harness.describe("the sample effect", function()
    test("loads, and fades, grows and tints its part on effect time, then puts it back", function()
      fresh()

      expect((custom.add("sample", sample, "docs.sdk.v1.sample"))).toBe(true)

      local part = pulse()
      local env = effects.emit(0, part)

      expect(part.Transparency).toBe(0)

      scheduler.frame(0.25)

      expect(part.Transparency > 0.5 and part.Transparency < 1).toBe(true)
      expect(part.Size.X > 2 and part.Size.X < 4).toBe(true)
      expect(part.Color.R > 0).toBe(true)

      scheduler.frame(0.25)

      expect(env.Finished:getStatus()).toBe("Resolved")
      expect(part.Transparency).toBe(0)
      expect(part.Size).toBe(Vector3.new(2, 2, 2))
      expect(part.Color).toBe(Color3.new(0, 0, 0))
    end)

    test("its Speed runs the pulse's clock", function()
      fresh()
      custom.add("sample", sample, "docs.sdk.v1.sample")

      local part = pulse()

      part:SetAttribute("Speed", 2)

      local env = effects.emit(0, part)

      scheduler.frame(0.25)

      expect(env.Finished:getStatus()).toBe("Resolved")
    end)
  end)

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
        old = math.min(old, timed(builtinPart))

        registry.clear()
        custom.add("fade", fade, "fade")
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
