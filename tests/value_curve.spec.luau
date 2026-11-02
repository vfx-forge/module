const knob = require("@mod/knob")
const lerp = require("@mod/lerp")
const reader = require("@mod/reader")
const value_curve = require("@mod/value_curve")
const harness = require("@tests/harness")
const test, expect = harness.test, harness.expect
const Instance = harness.datatypes.Instance

const EPSILON = 1e-6
const LOOSE = 1e-4

const function near(a: number, b: number): boolean
  return math.abs(a - b) < EPSILON
end

-- handles per channel, flat when left out
const function key(time: number, value: { number }, envelope: number?, left: { vector }?, right: { vector }?)
  return {
    time = time,
    value = value,
    envelope = envelope or 0,
    left = left or table.create(#value, vector.create(0, 0, 0)),
    right = right or table.create(#value, vector.create(0, 0, 0)),
  }
end

const function sample()
  return {
    channels = 3,
    linked = false,
    keys = {
      key(
        0,
        { 1, 2, 3 },
        0.25,
        { vector.create(0, 0, 0), vector.create(0, 0, 0), vector.create(0, 0, 0) },
        { vector.create(0.125, 0.5, 0), vector.create(0.25, -1, 0), vector.create(0, 2, 0) }
      ),
      key(
        0.5,
        { 4, 0.5, -1 },
        0,
        { vector.create(-0.125, 0.25, 0), vector.create(-0.25, 0, 0), vector.create(-0.5, 1, 0) },
        { vector.create(0.25, -0.75, 0), vector.create(0.125, 0.125, 0), vector.create(0, 0, 0) }
      ),
      key(
        1,
        { 0, 8, 2 },
        1.5,
        { vector.create(-0.25, 0, 0), vector.create(-0.125, 4, 0), vector.create(0, 0, 0) },
        { vector.create(0, 0, 0), vector.create(0, 0, 0), vector.create(0, 0, 0) }
      ),
    },
  }
end

const function module(attributes: { [string]: any })
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
      const c = sample()
      const back = value_curve.decode(value_curve.encode(c))

      expect(back).ok()
      expect(back).toEqual(c)

      c.linked = true
      c.channels = 1
      c.keys = { key(0.25, { 3 }, 0.5, { vector.create(-0.5, 1, 0) }, { vector.create(0.5, -1, 0) }) }

      expect(value_curve.decode(value_curve.encode(c))).toEqual(c)
    end)

    test("flat curves read their value everywhere", function()
      const c = value_curve.flat(2, 1)

      for _, t in { 0, 0.37, 1 } do
        expect(value_curve.at(c, t)).toEqual({ 2 })
      end

      expect(value_curve.at(value_curve.flat(1, 3), 0.5)).toEqual({ 1, 1, 1 })
      expect(value_curve.decode(value_curve.encode(c))).toEqual(c)
    end)

    test("a linear two-key curve interpolates", function()
      const c = { channels = 1, linked = true, keys = { key(0, { 0 }), key(1, { 10 }) } }

      expect(near(value_curve.at(c, 0.25)[1], 2.5)).ok()
      expect(near(value_curve.at(c, 0.8)[1], 8)).ok()
    end)

    test("bezier handles bend the curve", function()
      const c = {
        channels = 1,
        linked = true,
        keys = {
          key(0, { 0 }, 0, nil, { vector.create(0.5, 0, 0) }),
          key(1, { 10 }, 0, { vector.create(-0.5, 0, 0) }, nil),
        },
      }

      expect(value_curve.at(c, 0.25)[1] < 2.5 - 0.1).ok()
      expect(near(value_curve.at(c, 0.5)[1], 5)).ok()
      expect(near(value_curve.at(c, 1)[1], 10)).ok()
    end)

    test("handles that would fold time back still read monotone", function()
      const c = {
        channels = 1,
        linked = true,
        keys = {
          key(0, { 0 }, 0, nil, { vector.create(5, 0, 0) }),
          key(1, { 10 }, 0, { vector.create(-5, 0, 0) }, nil),
        },
      }

      local last = -1

      for i = 0, 100 do
        const v = value_curve.at(c, i / 100)[1]

        expect(v >= last - EPSILON and v == v).ok()
        last = v
      end
    end)

    test("a handle cut to its segment keeps its direction", function()
      const function curve(right: vector, left: vector)
        return {
          channels = 1,
          linked = true,
          keys = { key(0, { 0 }, 0, nil, { right }), key(1, { 10 }, 0, { left }, nil) },
        }
      end

      const cut = curve(vector.create(2, 1, 0), vector.create(-2, 0, 0))
      const authored = curve(vector.create(1, 0.5, 0), vector.create(-1, 0, 0))

      for _, t in { 0.1, 0.25, 0.5, 0.75, 0.9 } do
        expect(near(value_curve.at(cut, t)[1], value_curve.at(authored, t)[1])).ok()
      end
    end)

    test("each channel bends by its own handles", function()
      const flat = vector.create(0, 0, 0)
      const c = {
        channels = 3,
        linked = false,
        keys = {
          key(0, { 0, 0, 0 }, 0, nil, { flat, vector.create(0.5, 0, 0), flat }),
          key(1, { 10, 10, 10 }, 0, { flat, vector.create(-0.5, 0, 0), flat }, nil),
        },
      }

      const v = value_curve.at(c, 0.25)

      expect(near(v[1], 2.5)).ok()
      expect(near(v[3], 2.5)).ok()
      expect(v[2] < 2.5 - 0.1).ok()
    end)

    test("a handle is cut to its segment on its own channel", function()
      const flat = vector.create(0, 0, 0)
      const function curve(right: vector)
        return {
          channels = 2,
          linked = false,
          keys = {
            key(0, { 0, 0 }, 0, nil, { right, flat }),
            key(1, { 10, 10 }, 0, { flat, vector.create(-0.25, 2, 0) }, nil),
          },
        }
      end

      const cut = curve(vector.create(2, 1, 0))
      const authored = curve(vector.create(1, 0.5, 0))

      for _, t in { 0.1, 0.25, 0.5, 0.75, 0.9 } do
        const a, b = value_curve.at(cut, t), value_curve.at(authored, t)

        expect(near(a[1], b[1])).ok()
        expect(near(a[2], b[2])).ok()
      end
    end)

    test("a vertical handle keeps its value offset", function()
      const c = {
        channels = 1,
        linked = true,
        keys = {
          key(0, { 0 }, 0, nil, { vector.create(0, 4, 0) }),
          key(1, { 0 }, 0, { vector.create(0, 0, 0) }, nil),
        },
      }

      expect(value_curve.at(c, 0.5)[1] > 0.1).ok()
    end)

    test("envelopes widen per draw", function()
      const c = { channels = 1, linked = true, keys = { key(0, { 1 }, 0.5) } }

      expect(value_curve.at(c, 0.5, { 1 })).toEqual({ 1.5 })
      expect(value_curve.at(c, 0.5, { -1 })).toEqual({ 0.5 })
      expect(value_curve.at(c, 0.5)).toEqual({ 1 })
    end)

    test("a draw is one number per key within -1..1", function()
      const rng = {
        NextNumber = function(_, lo: number, hi: number)
          return hi
        end,
      }

      expect(value_curve.draw(sample(), rng :: any)).toEqual({ 1, 1, 1 })
    end)

    test("a sampler says whether its curve reads the same at every t", function()
      const function flat(c: any, draws: { number }?)
        return select(2, value_curve.sampler(c, draws))
      end

      const bent = {
        channels = 1,
        linked = true,
        keys = { key(0, { 1 }, 0, nil, { vector.create(0.25, 2, 0) }), key(1, { 1 }) },
      }
      const widened = { channels = 1, linked = true, keys = { key(0, { 1 }, 0.5), key(1, { 1 }) } }

      expect(flat(value_curve.flat(1, 3))).toBe(true)
      expect(flat({ channels = 1, linked = true, keys = { key(0, { 2 }), key(1, { 2 }) } })).toBe(true)
      expect(flat({ channels = 1, linked = true, keys = { key(0, { 2 }), key(1, { 3 }) } })).toBe(false)
      expect(flat(bent)).toBe(false)
      expect(flat(widened, { 0, 0 })).toBe(true)
      expect(flat(widened, { 1, 0 })).toBe(false)
    end)

    test("t outside 0..1 clamps", function()
      const c = { channels = 1, linked = true, keys = { key(0, { 2 }), key(1, { 6 }) } }

      expect(value_curve.at(c, -3)).toEqual({ 2 })
      expect(value_curve.at(c, 7)).toEqual({ 6 })
      expect(value_curve.at(c, 0 / 0)[1] == 2).ok()
    end)

    test("one key, equal times and keys inside 0..1 hold their end values", function()
      const one = { channels = 1, linked = true, keys = { key(0.5, { 7 }) } }

      expect(value_curve.at(one, 0)).toEqual({ 7 })
      expect(value_curve.at(one, 1)).toEqual({ 7 })

      const equal = { channels = 1, linked = true, keys = { key(0.5, { 1 }), key(0.5, { 9 }) } }

      expect(value_curve.at(equal, 0.25)).toEqual({ 1 })
      expect(value_curve.at(equal, 0.5)).toEqual({ 9 })
      expect(value_curve.at(equal, 0.75)).toEqual({ 9 })
    end)

    test("a sampler matches at and reuses its result", function()
      const c = sample()
      const draws = { 0.5, -0.5, 1 }
      const read = value_curve.sampler(c, draws)

      for i = 0, 20 do
        const t = i / 20
        const want = value_curve.at(c, t, draws)
        const got = read(t)

        for ch = 1, 3 do
          expect(near(want[ch], got[ch])).ok()
        end
      end

      expect(read(0.1)).toBe(read(0.9))
    end)

    test("decode sorts keys by time", function()
      const c = { channels = 1, linked = true, keys = { key(1, { 6 }), key(0, { 2 }) } }
      const back = value_curve.decode(value_curve.encode(c))

      expect(back.keys[1].time).toBe(0)
      expect(back.keys[2].time).toBe(1)
    end)

    test("bad data reads as nil", function()
      const good = value_curve.encode(sample())

      expect(value_curve.decode(nil)).toBe(nil)
      expect(value_curve.decode("")).toBe(nil)
      expect(value_curve.decode("garbage")).toBe(nil)
      expect(value_curve.decode(`{string.char(2)}{good:sub(2)}`)).toBe(nil)
      expect(value_curve.decode(`{good}x`)).toBe(nil)
      expect(value_curve.decode(`{good:sub(1, 1)}{string.char(2)}{good:sub(3)}`)).toBe(nil)

      for n = 0, #good - 1 do
        expect(value_curve.decode(good:sub(1, n))).toBe(nil)
      end

      const empty = value_curve.encode({ channels = 1, linked = true, keys = {} })

      expect(value_curve.decode(empty)).toBe(nil)

      const nan = buffer.fromstring(good)
      buffer.writef32(nan, 7, 0 / 0)

      expect(value_curve.decode(buffer.tostring(nan))).toBe(nil)

      -- a 3 channel key's handles read as a 1 channel curve's
      const fewer = buffer.fromstring(good)
      buffer.writeu8(fewer, 1, 1)

      expect(value_curve.decode(buffer.tostring(fewer))).toBe(nil)

      const huge = buffer.fromstring(good)
      buffer.writeu32(huge, 3, 0xFFFFFFFF)

      expect(value_curve.decode(buffer.tostring(huge))).toBe(nil)
    end)
  end)

  harness.describe("lerp.ValueCurve", function()
    -- every channel of `got` within LOOSE of `want` at each t of a sweep
    const function alike(got: any, want: any)
      const read, truth = value_curve.sampler(got), value_curve.sampler(want)

      for i = 0, 200 do
        const t = i / 200
        const a, b = table.clone(read(t)), truth(t)

        for c = 1, want.channels do
          assert(math.abs(a[c] - b[c]) < LOOSE, `channel {c} at {t} reads {a[c]}, wants {b[c]}`)
        end
      end
    end

    -- three channels on key times sample() has none of, the first and last
    -- inside 0..1
    const function other()
      return {
        channels = 3,
        linked = false,
        keys = {
          key(
            0.1,
            { -2, 1, 0 },
            0.5,
            nil,
            { vector.create(0.1, 1, 0), vector.create(0.05, 0, 0), vector.create(0.2, -1, 0) }
          ),
          key(
            0.3,
            { 1, 1, 4 },
            0,
            { vector.create(-0.05, 0, 0), vector.create(-0.1, 2, 0), vector.create(-0.05, 0.5, 0) },
            { vector.create(0.2, 0, 0), vector.create(0.1, -1, 0), vector.create(0.3, 0, 0) }
          ),
          key(
            0.8,
            { 3, 6, -2 },
            0,
            { vector.create(-0.25, 1, 0), vector.create(-0.1, 0, 0), vector.create(-0.2, -1, 0) },
            nil
          ),
        },
      }
    end

    test("a blend at 0 reads as a and at 1 as b over a sweep", function()
      const a, b = sample(), other()

      alike(lerp.ValueCurve(a, b, 0), a)
      alike(lerp.ValueCurve(a, b, 1), b)

      -- a step off either end goes through the shared key times
      alike(lerp.ValueCurve(a, b, 1e-9), a)
      alike(lerp.ValueCurve(a, b, 1 - 1e-9), b)
      alike(lerp.ValueCurve(b, a, 1e-9), b)
    end)

    test("splitting a curve at a new time leaves its samples unchanged", function()
      const c = sample()

      for _, time in { 0.2, 0.37, 0.5, 0.9 } do
        const split = value_curve.split(c, time)

        alike(split, c)
        expect(#split.keys).toBe(if time == 0.5 then 3 else 4)
      end

      -- before the first key and past the last, where the curve holds its ends
      const inside = other()

      alike(value_curve.split(value_curve.split(inside, 0), 1), inside)
      alike(value_curve.split(value_curve.split(inside, 0.2), 0.25), inside)
    end)

    test("a blend at 0.5 of two flat curves is the flat mean", function()
      const blend = lerp.ValueCurve(value_curve.flat(1, 3), value_curve.flat(3, 3), 0.5)

      for _, t in { 0, 0.4, 1 } do
        expect(value_curve.at(blend, t)).toEqual({ 2, 2, 2 })
      end

      expect(lerp.any(value_curve.flat(0, 1), value_curve.flat(1, 1), 0.25)).toEqual(value_curve.flat(0.25, 1))
    end)

    test("curves on different key times blend between them where both rise", function()
      const a = {
        channels = 1,
        linked = true,
        keys = {
          key(0, { 0 }, 0, nil, { vector.create(0.1, 0.5, 0) }),
          key(0.4, { 2 }, 0, { vector.create(-0.1, -0.5, 0) }, { vector.create(0.2, 1, 0) }),
          key(1, { 5 }, 0, { vector.create(-0.2, -0.5, 0) }, nil),
        },
      }
      const b = {
        channels = 1,
        linked = true,
        keys = {
          key(0, { 1 }, 0, nil, { vector.create(0.3, 2, 0) }),
          key(0.7, { 6 }, 0, { vector.create(-0.2, -1, 0) }, { vector.create(0.1, 0.5, 0) }),
          key(1, { 8 }),
        },
      }

      for _, weight in { 0.25, 0.5, 0.75 } do
        const blend = lerp.ValueCurve(a, b, weight)

        for i = 0, 100 do
          const t = i / 100
          const v, low, high = value_curve.at(blend, t)[1], value_curve.at(a, t)[1], value_curve.at(b, t)[1]

          expect(v >= math.min(low, high) - LOOSE and v <= math.max(low, high) + LOOSE).ok()
        end
      end
    end)

    test("the blend is linked only when both are, and channel counts must agree", function()
      const one, three = value_curve.flat(1, 1), value_curve.flat(1, 3)
      const loose = value_curve.flat(2, 1)

      loose.linked = false

      expect(lerp.ValueCurve(one, loose, 0.5).linked).toBe(false)
      expect(lerp.ValueCurve(one, value_curve.flat(2, 1), 0.5).linked).toBe(true)
      expect(function()
        lerp.ValueCurve(one, three, 0.5)
      end).toThrow()
    end)
  end)

  harness.describe("a ValueCurve row", function()
    -- lune refuses a non utf-8 attribute string, so the stored map is stubbed
    const function resolve(row: any, stored: any)
      const obj = Instance.new("Part")

      reader.source = function()
        return { Size = stored }
      end

      const ok, attrs = pcall(reader.resolve, module({ Size = row }), { ref = obj, obj = obj })

      reader.source = reader.defaultSource

      assert(ok, attrs)

      return attrs.Size
    end

    test("reads its stored string", function()
      const c = sample()

      expect(resolve(knob(value_curve.flat(1, 3)):valueCurve(3), value_curve.encode(c))).toEqual(c)
    end)

    test("a bad attribute falls back to its default", function()
      const default = value_curve.flat(1, 3)

      for _, bad in { "garbage", 4, true, value_curve.encode(value_curve.flat(1, 1)) } do
        expect(resolve(knob(default):valueCurve(3), bad)).toBe(default)
      end
    end)

    test("an unset row reads its default", function()
      const default = value_curve.flat(1, 3)

      expect(resolve(knob(default):valueCurve(3), nil)).toBe(default)
    end)
  end)
end)
