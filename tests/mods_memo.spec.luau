local mods = require("@mod/mods")
local value = require("@mod/value")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local harness = require("@tests/harness")
local legacy_mods = require("@mod/legacy_mods")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance

frame.configure(harness.fakeEncoding, harness.fakeCompression)

local function tween(startV: any, finishV: any, duration: number?)
  return { kind = "tween", chain = false, duration = duration, start = value.lit(startV), finish = value.lit(finishV) }
end

local function framed(queue: { any })
  return frame.frame(codec.encode({ v = 1, queue = queue }))
end

local function authored(raw: string)
  local obj = Instance.new("Attachment")
  obj:SetAttribute(mods.attrName("attribute", "Width"), raw)

  return obj
end

local function quad(startV: any, finishV: any)
  local obj = Instance.new("Attachment")
  obj:SetAttribute("Width_Start", startV)
  obj:SetAttribute("Width_End", finishV)

  return obj
end

-- every clone of a template stores the same strings and values, so what they
-- decode to is read once and shared, frozen so nothing downstream can write
-- into what another instance reads
harness.suite(function()
  harness.describe("a memoized queue", function()
    test("two instances carrying one framed string decode to one frozen table", function()
      local raw = framed({ tween(1, 2, 1) })
      local a = mods.framed(authored(raw), "attribute", "Width")
      local b = mods.framed(authored(raw), "attribute", "Width")

      expect(rawequal(a, b)).toBe(true)
      expect(table.isfrozen(a :: any)).toBe(true)
      expect(table.isfrozen((a :: any).start)).toBe(true)
      expect(table.isfrozen((a :: any).start[1])).toBe(true)
    end)

    test("a different framed string decodes to a table of its own", function()
      local a = mods.framed(authored(framed({ tween(1, 2, 1) })), "attribute", "Width")
      local b = mods.framed(authored(framed({ tween(1, 3, 1) })), "attribute", "Width")

      expect(rawequal(a, b)).toBe(false)
      expect(value.resolve((b :: any).start[1].finish)).toBe(3)
    end)

    test("two instances storing one old quad read as one frozen queue", function()
      local a = legacy_mods.read(quad(1, 2), "attribute", "Width")
      local b = legacy_mods.read(quad(1, 2), "attribute", "Width")
      local c = legacy_mods.read(quad(1, 3), "attribute", "Width")

      expect(rawequal(a, b)).toBe(true)
      expect(rawequal(a, c)).toBe(false)
      expect(table.isfrozen(a :: any)).toBe(true)
      expect(table.isfrozen((a :: any)[1])).toBe(true)
    end)

    test("a quad whose halves differ only in type reads as two queues", function()
      local a = legacy_mods.read(quad(1, 2), "attribute", "Width")
      local b = legacy_mods.read(quad("1", "2"), "attribute", "Width")

      expect(rawequal(a, b)).toBe(false)
    end)

    test("a track builds from a memoized queue as it does from a fresh one", function()
      local obj = quad(1, 3)
      local first = mods.track(obj, "attribute", "Width", 0, 2)
      local again = mods.track(quad(1, 3), "attribute", "Width", 0, 2)

      expect(first.at(0)).toBe(1)
      expect(again.at(0)).toBe(1)
      expect(first.animated).toBe(true)
      expect(again.at(2)).toBe(3)
    end)
  end)
end)
