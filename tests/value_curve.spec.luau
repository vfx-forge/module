local knob = require("@mod/knob")
local reader = require("@mod/reader")
local value_curve = require("@mod/value_curve")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance

local EPSILON = 1e-6

local function near(a: number, b: number): boolean
  return math.abs(a - b) < EPSILON
end

local function key(time: number, value: { number }, envelope: number?, left: vector?, right: vector?)
  return {
    time = time,
    value = value,
    envelope = envelope or 0,
    left = left or vector.create(0, 0),
    right = right or vector.create(0, 0),
  }
end

local function sample()
  return {
    channels = 3,
    linked = false,
    keys = {
      key(0, { 1, 2, 3 }, 0.25, vector.create(0, 0), vector.create(0.125, 0.5)),
      key(0.5, { 4, 0.5, -1 }, 0, vector.create(-0.125, 0.25), vector.create(0.25, -0.75)),
      key(1, { 0, 8, 2 }, 1.5, vector.create(-0.25, 0), vector.create(0, 0)),
    },
  }
end

local function module(attributes: { [string]: any })
  return {
    id = "stub",
    display = { name = "Stub" },
    classifier = "Part",
    attributes = attributes,
    properties = {},
    emit = function() end,
  }
end

harness.suite(function()
  harness.describe("value_curve", function()
    test("a curve round-trips", function()
      local c = sample()
      local back = value_curve.decode(value_curve.encode(c))

      expect(back).ok()
      expect(back).toEqual(c)

      c.linked = true
      c.channels = 1
      c.keys = { key(0.25, { 3 }, 0.5, vector.create(-0.5, 1), vector.create(0.5, -1)) }

      expect(value_curve.decode(value_curve.encode(c))).toEqual(c)
    end)

    test("flat curves read their value everywhere", function()
      local c = value_curve.flat(2, 1)

      for _, t in { 0, 0.37, 1 } do
        expect(value_curve.at(c, t)).toEqual({ 2 })
      end

      expect(value_curve.at(value_curve.flat(1, 3), 0.5)).toEqual({ 1, 1, 1 })
      expect(value_curve.decode(value_curve.encode(c))).toEqual(c)
    end)

    test("a linear two-key curve interpolates", function()
      local c = { channels = 1, linked = true, keys = { key(0, { 0 }), key(1, { 10 }) } }

      expect(near(value_curve.at(c, 0.25)[1], 2.5)).ok()
      expect(near(value_curve.at(c, 0.8)[1], 8)).ok()
    end)

    test("bezier handles bend the curve", function()
      local c = {
        channels = 1,
        linked = true,
        keys = {
          key(0, { 0 }, 0, nil, vector.create(0.5, 0)),
          key(1, { 10 }, 0, vector.create(-0.5, 0), nil),
        },
      }

      expect(value_curve.at(c, 0.25)[1] < 2.5 - 0.1).ok()
      expect(near(value_curve.at(c, 0.5)[1], 5)).ok()
      expect(near(value_curve.at(c, 1)[1], 10)).ok()
    end)

    test("handles that would fold time back still read monotone", function()
      local c = {
        channels = 1,
        linked = true,
        keys = {
          key(0, { 0 }, 0, nil, vector.create(5, 0)),
          key(1, { 10 }, 0, vector.create(-5, 0), nil),
        },
      }

      local last = -1

      for i = 0, 100 do
        local v = value_curve.at(c, i / 100)[1]

        expect(v >= last - EPSILON and v == v).ok()
        last = v
      end
    end)

    test("envelopes widen per draw", function()
      local c = { channels = 1, linked = true, keys = { key(0, { 1 }, 0.5) } }

      expect(value_curve.at(c, 0.5, { 1 })).toEqual({ 1.5 })
      expect(value_curve.at(c, 0.5, { -1 })).toEqual({ 0.5 })
      expect(value_curve.at(c, 0.5)).toEqual({ 1 })
    end)

    test("a draw is one number per key within -1..1", function()
      local rng = {
        NextNumber = function(_, lo: number, hi: number)
          return hi
        end,
      }

      expect(value_curve.draw(sample(), rng :: any)).toEqual({ 1, 1, 1 })
    end)

    test("t outside 0..1 clamps", function()
      local c = { channels = 1, linked = true, keys = { key(0, { 2 }), key(1, { 6 }) } }

      expect(value_curve.at(c, -3)).toEqual({ 2 })
      expect(value_curve.at(c, 7)).toEqual({ 6 })
      expect(value_curve.at(c, 0 / 0)[1] == 2).ok()
    end)

    test("one key, equal times and keys inside 0..1 hold their end values", function()
      local one = { channels = 1, linked = true, keys = { key(0.5, { 7 }) } }

      expect(value_curve.at(one, 0)).toEqual({ 7 })
      expect(value_curve.at(one, 1)).toEqual({ 7 })

      local equal = { channels = 1, linked = true, keys = { key(0.5, { 1 }), key(0.5, { 9 }) } }

      expect(value_curve.at(equal, 0.25)).toEqual({ 1 })
      expect(value_curve.at(equal, 0.5)).toEqual({ 9 })
      expect(value_curve.at(equal, 0.75)).toEqual({ 9 })
    end)

    test("a sampler matches at and reuses its result", function()
      local c = sample()
      local draws = { 0.5, -0.5, 1 }
      local read = value_curve.sampler(c, draws)

      for i = 0, 20 do
        local t = i / 20
        local want = value_curve.at(c, t, draws)
        local got = read(t)

        for ch = 1, 3 do
          expect(near(want[ch], got[ch])).ok()
        end
      end

      expect(read(0.1)).toBe(read(0.9))
    end)

    test("decode sorts keys by time", function()
      local c = { channels = 1, linked = true, keys = { key(1, { 6 }), key(0, { 2 }) } }
      local back = value_curve.decode(value_curve.encode(c))

      expect(back.keys[1].time).toBe(0)
      expect(back.keys[2].time).toBe(1)
    end)

    test("bad data reads as nil", function()
      local good = value_curve.encode(sample())

      expect(value_curve.decode(nil)).toBe(nil)
      expect(value_curve.decode("")).toBe(nil)
      expect(value_curve.decode("garbage")).toBe(nil)
      expect(value_curve.decode(`{string.char(2)}{good:sub(2)}`)).toBe(nil)
      expect(value_curve.decode(`{good}x`)).toBe(nil)
      expect(value_curve.decode(`{good:sub(1, 1)}{string.char(2)}{good:sub(3)}`)).toBe(nil)

      for n = 0, #good - 1 do
        expect(value_curve.decode(good:sub(1, n))).toBe(nil)
      end

      local empty = value_curve.encode({ channels = 1, linked = true, keys = {} })

      expect(value_curve.decode(empty)).toBe(nil)

      local nan = buffer.fromstring(good)
      buffer.writef32(nan, 7, 0 / 0)

      expect(value_curve.decode(buffer.tostring(nan))).toBe(nil)

      local huge = buffer.fromstring(good)
      buffer.writeu32(huge, 3, 0xFFFFFFFF)

      expect(value_curve.decode(buffer.tostring(huge))).toBe(nil)
    end)
  end)

  harness.describe("a ValueCurve row", function()
    -- lune refuses a non utf-8 attribute string, so the stored map is stubbed
    local function resolve(row: any, stored: any)
      local obj = Instance.new("Part")

      reader.source = function()
        return { Size = stored }
      end

      local ok, attrs = pcall(reader.resolve, module({ Size = row }), { ref = obj, obj = obj })

      reader.source = reader.defaultSource

      assert(ok, attrs)

      return attrs.Size
    end

    test("reads its stored string", function()
      local c = sample()

      expect(resolve(knob(value_curve.flat(1, 3)):valueCurve(3), value_curve.encode(c))).toEqual(c)
    end)

    test("a bad attribute falls back to its default", function()
      local default = value_curve.flat(1, 3)

      for _, bad in { "garbage", 4, true, value_curve.encode(value_curve.flat(1, 1)) } do
        expect(resolve(knob(default):valueCurve(3), bad)).toBe(default)
      end
    end)

    test("an unset row reads its default", function()
      local default = value_curve.flat(1, 3)

      expect(resolve(knob(default):valueCurve(3), nil)).toBe(default)
    end)
  end)
end)
