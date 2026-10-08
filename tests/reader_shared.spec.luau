local mods = require("@mod/mods")
local knob = require("@mod/knob")
local harness = require("@tests/harness")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance
local NumberRange = harness.datatypes.NumberRange

local function noop() end

local function module(id: string)
  return {
    id = id,
    display = { name = id, icon = id, order = 1 },
    classifier = "Attachment",
    attributes = {
      Width = knob(1):mod(),
      Speed = knob(2):mod(),
      Spread = knob(NumberRange.new(0, 1)):mod(),
    },
    properties = {},
    emit = noop,
  }
end

local function instance(startV: any, finishV: any, width: any?)
  local obj = Instance.new("Attachment")
  obj:SetAttribute("Width_Start", startV)
  obj:SetAttribute("Width_End", finishV)

  if width ~= nil then
    obj:SetAttribute("Width", width)
  end

  return obj
end

-- how many times the reader built a track, counted on the one call it makes
local function counting(fn: () -> ()): number
  local real = mods.build
  local builds = 0

  mods.build = function(...)
    builds += 1
    return real(...)
  end

  local ok, err = pcall(fn)

  mods.build = real

  if not ok then
    error(err, 0)
  end

  return builds
end

-- two clones of a template store the same content, so the second read is
-- handed the lanes the first built rather than building them again
harness.suite(function()
  harness.describe("a build shared across instances", function()
    test("a clone storing the same quad reads without a build of its own", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("shared_a"))

      local first = instance(1, 3)
      local second = instance(1, 3)

      local firstBuilds = counting(function()
        registry.read(first)
      end)

      local attrs
      local secondBuilds = counting(function()
        attrs = registry.read(second)
      end)

      -- Width is shared; Spread draws from its range every read and is not
      expect(firstBuilds > secondBuilds).toBe(true)
      expect(attrs.Width.at(0)).toBe(1)
      expect(attrs.Width.at(attrs.Width.duration)).toBe(3)
      expect(attrs.Width.animated).toBe(true)
    end)

    test("a clone resting elsewhere or storing another quad builds its own", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("shared_b"))

      registry.read(instance(1, 3))

      local other = counting(function()
        expect(registry.read(instance(1, 4)).Width.at(10)).toBe(4)
      end)
      local same = counting(function()
        expect(registry.read(instance(1, 3)).Width.at(10)).toBe(3)
      end)

      expect(other > same).toBe(true)
    end)

    test("a row that draws per instance is built for every instance", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("shared_c"))

      local a = Instance.new("Attachment")
      local b = Instance.new("Attachment")

      a:SetAttribute("Spread", NumberRange.new(2, 5))
      b:SetAttribute("Spread", NumberRange.new(2, 5))

      registry.read(a)

      local builds = counting(function()
        local drawn = registry.read(b).Spread.at(0)

        expect(drawn >= 2 and drawn <= 5).toBe(true)
      end)

      expect(builds >= 1).toBe(true)
    end)

    test("a piece calling a shared row gets lanes on its own clock", function()
      registry.clear()
      registry.configure({ query = harness.query })

      local m = module("shared_d")
      m.events = { "burst" }
      registry.register(m)

      registry.read(instance(1, 3))

      local attrs = registry.read(instance(1, 3))
      local piece = mods.piece({ "burst" })
      local own = attrs.Width(nil, nil, piece)

      expect(own.at(0)).toBe(1)
      expect(own.animated).toBe(true)
    end)
  end)
end)
