local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local knob = require("@mod/knob")
local harness = require("@tests/harness")
local registry = require("@mod/registry")
local legacy_mods = require("@mod/legacy_mods")
local test, expect = harness.test, harness.expect

local function noop() end

local function module(id: string)
  return {
    id = id,
    display = { name = id, icon = id, order = 1 },
    classifier = "Attachment",
    attributes = {
      Width = knob(1):mod(),
      Count = knob(4),
    },
    properties = {},
    emit = noop,
  }
end

local function template()
  harness.reset()

  local obj = harness.make("Attachment")
  obj:SetAttribute("Width_Start", 1)
  obj:SetAttribute("Width_End", 3)
  obj:SetAttribute("Count", 7)
  attr.cache(obj)

  return obj
end

-- how many old-shape lookups and builds a read made
local function counting(fn: () -> ()): (number, number)
  local realRead, realBuild = legacy_mods.read, mods.build
  local reads, builds = 0, 0

  legacy_mods.read = function(...)
    reads += 1
    return realRead(...)
  end

  mods.build = function(...)
    builds += 1
    return realBuild(...)
  end

  local ok, err = pcall(fn)

  legacy_mods.read, mods.build = realRead, realBuild

  if not ok then
    error(err, 0)
  end

  return reads, builds
end

-- a clone of a cached template reads through the same cache table, so what
-- the module resolved from that table serves every clone
harness.suite(function()
  harness.describe("a read through an attribute cache", function()
    test("a clone's read looks nothing up and builds nothing the first read did", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("baked_a"))

      local obj = template()
      local first, second = obj:Clone(), obj:Clone()

      registry.read(first)

      local attrs
      local reads, builds = counting(function()
        attrs = registry.read(second)
      end)

      expect(reads).toBe(0)
      expect(builds).toBe(0)
      expect(attrs.Count).toBe(7)
      expect(attrs.Width.at(0)).toBe(1)
      expect(attrs.Width.at(attrs.Width.duration)).toBe(3)
    end)

    -- a cached name wins over a live one of the same name, as every read of
    -- a cached instance has it, so the live attribute a clone can add is one
    -- the cache does not hold
    test("a clone given a live attribute the cache lacks reads it", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("baked_b"))
      harness.reset()

      local obj = harness.make("Attachment")
      obj:SetAttribute("Width_Start", 1)
      obj:SetAttribute("Width_End", 3)
      attr.cache(obj)

      registry.read(obj:Clone())

      local own = obj:Clone()
      own:SetAttribute("Count", 9)

      expect(registry.read(own).Count).toBe(9)
      expect(registry.read(obj:Clone()).Count).toBe(4)
    end)

    test("a write into the cache is seen by the next read", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("baked_c"))

      local obj = template()
      registry.read(obj:Clone())

      attr.set(obj, "Count", 5)
      attr.set(obj, "Width_End", 6)

      local attrs = registry.read(obj:Clone())

      expect(attrs.Count).toBe(5)
      expect(attrs.Width.at(attrs.Width.duration)).toBe(6)
    end)

    test("an instance with no cache is looked up every read", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(module("baked_d"))
      harness.reset()

      local obj = harness.make("Attachment")
      obj:SetAttribute("Width_Start", 1)
      obj:SetAttribute("Width_End", 3)

      registry.read(obj)

      local reads = counting(function()
        registry.read(obj)
      end)

      expect(reads > 0).toBe(true)
    end)
  end)

  -- lune stores no instance in an attribute, so the test of what stays on a
  -- cached instance is replaced: a text starting with a marker stands in for a
  -- handle the engine would remap on a clone
  harness.describe("caching an instance holding a handle", function()
    local function withStays(fn: () -> ())
      local real = attr.stays

      attr.stays = function(v: any)
        return type(v) == "string" and string.sub(v, 1, 7) == "handle:"
      end

      local ok, err = pcall(fn)

      attr.stays = real

      if not ok then
        error(err, 0)
      end
    end

    test("the handle stays on the instance and the rest is cached", function()
      withStays(function()
        harness.reset()

        local obj = harness.make("Attachment")
        obj:SetAttribute("Count", 7)
        obj:SetAttribute("Target", "handle:a")
        attr.cache(obj)

        expect(obj:GetAttribute("Count")).toBe(nil)
        expect(obj:GetAttribute("Target")).toBe("handle:a")
      end)
    end)

    test("a clone still reads through the cache for every other row", function()
      withStays(function()
        harness.reset()

        local obj = harness.make("Attachment")
        obj:SetAttribute("Count", 7)
        obj:SetAttribute("Target", "handle:a")
        attr.cache(obj)

        local cache = attr.cached(obj:Clone())

        expect(cache ~= nil).toBe(true)
        expect((cache :: any).Count).toBe(7)
        expect((cache :: any).Target).toBe(nil)
      end)
    end)
  end)
end)
