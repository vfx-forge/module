local harness = require("@tests/harness")
local effects = require("@srv/effects")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

local custom = require("@root/sdk/custom")
local sample = require("@docs/sdk/v1/sample")

local Color3 = harness.datatypes.Color3
local Vector3 = harness.datatypes.Vector3

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
  part.Reflectance = 0

  return part
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
      expect(part.Reflectance > 0).toBe(true)

      scheduler.frame(0.25)

      expect(env.Finished:getStatus()).toBe("Resolved")
      expect(part.Transparency).toBe(0)
      expect(part.Size).toBe(Vector3.new(2, 2, 2))
      expect(part.Color).toBe(Color3.new(0, 0, 0))
      expect(part.Reflectance).toBe(0)
    end)

    test("waits its delay before it touches the part", function()
      fresh()
      custom.add("sample", sample, "docs.sdk.v1.sample")

      local part = pulse()

      part:SetAttribute("EmitDelay", 0.5)

      local env = effects.emit(0, part)

      scheduler.frame(0.25)

      expect(part.Transparency).toBe(0)
      expect(part.Size).toBe(Vector3.new(2, 2, 2))

      -- the frame the delay runs out in plays the fade's first step
      scheduler.frame(0.25)

      expect(part.Transparency > 0 and part.Transparency < 1).toBe(true)

      scheduler.frame(0.5)

      expect(env.Finished:getStatus()).toBe("Resolved")
    end)

    test("plays alone on its part, so a second emit while it plays ends at once", function()
      fresh()
      custom.add("sample", sample, "docs.sdk.v1.sample")

      local part = pulse()
      local first = effects.emit(0, part)

      scheduler.frame(0.25)

      local grown = part.Size
      local second = effects.emit(0, part)

      scheduler.frame(0)

      expect(second.Finished:getStatus()).toBe("Resolved")
      expect(part.Size).toBe(grown)

      scheduler.frame(0.25)

      expect(first.Finished:getStatus()).toBe("Resolved")
      expect(part.Size).toBe(Vector3.new(2, 2, 2))
    end)
  end)
end)
