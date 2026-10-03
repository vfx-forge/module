local path = require("@mod/common/path")
local curve = require("@mod/curve")
local curves = require("@mod/curves")
local editor = require("@tests/fixtures/editor_curves")
local harness = require("@tests/harness")

local Before = require("@tests/fixtures/Bezier_213759c")

local test, expect = harness.test, harness.expect

local SAMPLES = 200

-- a fixture curve's serialized bytes, from its f32s
local function bytes(floats: string): string
  local values = string.split(floats, " ")
  local buf = buffer.create(#values * 4)

  for i, v in values do
    buffer.writef32(buf, (i - 1) * 4, tonumber(v) :: number)
  end

  return buffer.tostring(buf)
end

-- every preset and every editor curve, each as its name and its bytes
local function everyShape(): { { string } }
  local list = {}

  for name, serialized in curves.PRESETS do
    table.insert(list, { name, serialized })
  end

  for _, entry in editor do
    table.insert(list, { entry[1], bytes(entry[2]) })
  end

  return list
end

-- what every tween eased with before: the old Bezier's Newton solve, which this
-- host always took
local function before(serialized: string, t: number): number
  return 1 - Before.new(path.deserializePath(serialized), 0):_getEaseRaw(t).y
end

local function cubic(a: number, b: number, c: number, d: number, s: number): number
  local r = 1 - s

  return r * r * r * a + 3 * r * r * s * b + 3 * r * s * s * c + s * s * s * d
end

-- the curve's true value at t: the segment the old solve picked, its time
-- halved down to t, its value there
local function exactly(serialized: string, t: number): number
  local points = path.deserializePath(serialized)

  for i = 1, #points - 3, 3 do
    local x0, x1, x2, x3 = points[i].x, points[i + 1].x, points[i + 2].x, points[i + 3].x

    if t >= x0 and t < x3 then
      local low, high = 0, 1

      for _ = 1, 60 do
        local middle = (low + high) / 2

        if cubic(x0, x1, x2, x3, middle) < t then
          low = middle
        else
          high = middle
        end
      end

      local s = (low + high) / 2

      return 1 - cubic(points[i].y, points[i + 1].y, points[i + 2].y, points[i + 3].y, s)
    end
  end

  return 1 - points[#points].y
end

-- how many times `serialized` is decoded while fn runs
local function decodes(serialized: string, fn: () -> ()): number
  local original = path.deserializePath
  local count = 0

  path.deserializePath = function(data: string | buffer)
    if data == serialized then
      count += 1
    end

    return original(data)
  end

  local ok, err = pcall(fn)

  path.deserializePath = original

  if not ok then
    error(err, 0)
  end

  return count
end

-- a serialized two anchor curve of its own, its outgoing handle at (x, 0.5)
local function unique(x: number): string
  local buf = buffer.create(48)

  buffer.writef32(buf, 0, 0)
  buffer.writef32(buf, 4, 1)
  buffer.writef32(buf, 8, x)
  buffer.writef32(buf, 12, 0.5)
  buffer.writef32(buf, 16, 0.75)
  buffer.writef32(buf, 20, 0)
  buffer.writef32(buf, 24, 1)
  buffer.writef32(buf, 28, 0)

  return buffer.tostring(buf)
end

local function refusal(shape: any): string
  local ok, err = pcall(curve.new, 1, shape)

  expect(ok).toBe(false)

  return tostring(err)
end

harness.suite(function()
  harness.describe("curve presets", function()
    test("the out cubic and linear keep the bytes rows have always stored", function()
      local easeOut = buffer.tostring(path.serializePath({
        Path2DControlPoint.new(UDim2.fromScale(0, 1), UDim2.new(), UDim2.fromScale(0.215, -0.61)),
        Path2DControlPoint.new(UDim2.fromScale(1, 0), UDim2.fromScale(-0.645, 0), UDim2.new()),
      }))

      local linear = buffer.tostring(path.serializePath({
        Path2DControlPoint.new(UDim2.fromScale(0, 1)),
        Path2DControlPoint.new(UDim2.fromScale(1, 0)),
      }))

      expect(curves.PRESETS.easeOut).toBe(easeOut)
      expect(curves.PRESETS.linear).toBe(linear)
      expect(curves.default()).toBe(easeOut)
      expect(curves.linear()).toBe(linear)
    end)

    test("every preset runs from 0 to 1, and the eased three bend the way their names say", function()
      for name in curves.PRESETS do
        local shaped = curve.new(1, name)

        expect(math.abs(shaped:at(0)) < 1e-6).toBe(true)
        expect(math.abs(shaped:at(1) - 1) < 1e-6).toBe(true)
      end

      expect(math.abs(curve.new(1, "linear"):at(0.3) - 0.3) < 1e-6).toBe(true)
      expect(curve.new(1, "easeIn"):at(0.5) < 0.4).toBe(true)
      expect(curve.new(1, "easeOut"):at(0.5) > 0.6).toBe(true)
      expect(math.abs(curve.new(1, "easeInOut"):at(0.5) - 0.5) < 0.02).toBe(true)
    end)
  end)

  harness.describe("curve:at", function()
    -- the old solve stopped once a newton step moved less than 0.001, which
    -- leaves it up to 6e-4 off on the editor's circular curves; the new one
    -- may differ from it by 1e-4 beyond that
    test("every preset and editor curve agrees with the old solve", function()
      for _, entry in everyShape() do
        local shaped = curve.new(1, entry[2])

        for i = 0, SAMPLES - 1 do
          local t = i / (SAMPLES - 1)
          local old = before(entry[2], t)
          local slack = 1e-4 + math.abs(old - exactly(entry[2], t))

          if math.abs(shaped:at(t) - old) > slack then
            error(`{entry[1]} at {t}: {shaped:at(t)} against {old}`, 0)
          end
        end
      end
    end)

    test("every preset and editor curve is within 1e-5 of its exact value", function()
      for _, entry in everyShape() do
        local shaped = curve.new(1, entry[2])

        for i = 0, SAMPLES - 1 do
          local t = i / (SAMPLES - 1)

          if math.abs(shaped:at(t) - exactly(entry[2], t)) > 1e-5 then
            error(`{entry[1]} at {t}: {shaped:at(t)} against {exactly(entry[2], t)}`, 0)
          end
        end
      end
    end)

    test("a time outside 0 to 1 reads the nearer end", function()
      local shaped = curve.new(1, "easeOut")
      local straight = curve.new(1, "linear")

      expect(shaped:at(-1)).toBe(shaped:at(0))
      expect(shaped:at(2)).toBe(shaped:at(1))
      expect(straight:at(-1)).toBe(0)
      expect(straight:at(2)).toBe(1)
    end)

    test("a NaN time reads as NaN from every kind of curve, never throwing", function()
      local nan = 0 / 0
      local read = {
        curve.new(1, "easeOut"):at(nan),
        curve.new(1, "linear"):at(nan),
        curve.new(1, { vector.create(0, 0), vector.create(1, 1) }):at(nan),
        curve
          .new(1, function(t: number)
            assert(t == t, "a NaN time reached the function")
            return t
          end)
          :at(nan),
        curve.sample("easeOut", nan),
      }

      for _, v in read do
        expect(v ~= v).toBe(true)
      end
    end)

    test("linear, by name or by a row's bytes, is its own time", function()
      expect(curve.new(1, "linear"):at(0.37)).toBe(0.37)
      expect(curve.new(1, curves.linear()):at(0.37)).toBe(0.37)
    end)
  end)

  harness.describe("curve shapes", function()
    test("a chain is read y up, and agrees with the same curve serialized", function()
      local chain = { vector.create(0, 0), vector.create(0.215, 0.61), vector.create(0.355, 1), vector.create(1, 1) }
      local shaped = curve.new(1, chain)
      local preset = curve.new(1, "easeOut")

      for i = 0, 10 do
        expect(math.abs(shaped:at(i / 10) - preset:at(i / 10)) < 1e-6).toBe(true)
      end
    end)

    test("a chain of two points is a straight line", function()
      local shaped = curve.new(1, { vector.create(0, 0.2), vector.create(1, 0.6) })

      expect(math.abs(shaped:at(0.5) - 0.4) < 1e-6).toBe(true)
    end)

    test("a chain that cannot be a curve is refused with the reason", function()
      local three = refusal({ vector.create(0, 0), vector.create(0.5, 0.5), vector.create(1, 1) })
      local late = refusal({ vector.create(0.1, 0), vector.create(1, 1) })
      local back = refusal({
        vector.create(0, 0),
        vector.create(0.2, 0),
        vector.create(0.4, 1),
        vector.create(0.6, 1),
        vector.create(0.6, 1),
        vector.create(0.5, 1),
        vector.create(0.5, 0),
        vector.create(0.6, 0),
        vector.create(0.9, 1),
        vector.create(1, 1),
      })
      local handle = refusal({ vector.create(0, 0), vector.create(1.2, 0), vector.create(0.8, 1), vector.create(1, 1) })

      expect(string.find(three, "2 or 3n + 1 points, got 3", 1, true) ~= nil).toBe(true)
      expect(string.find(late, "runs from 0 to 1", 1, true) ~= nil).toBe(true)
      expect(string.find(back, "moves backward at point 7", 1, true) ~= nil).toBe(true)
      expect(string.find(handle, "handle at point 2", 1, true) ~= nil).toBe(true)
    end)

    test("a function is the curve itself", function()
      local shaped = curve.new(2, function(t: number)
        return t * t
      end)

      expect(shaped.duration).toBe(2)
      expect(shaped:at(0.5)).toBe(0.25)
    end)

    test("a duration that cannot be run is zero", function()
      expect(curve.new(0 / 0, "linear").duration).toBe(0)
      expect(curve.new(math.huge, "linear").duration).toBe(0)
      expect(curve.new(-1, "linear").duration).toBe(0)
    end)

    test("a value too short to hold a segment reads as 1 at every time, as it always did", function()
      for _, value in { "", "no", "bounce", string.rep("\0", 24) } do
        expect(curve.new(1, value):at(0)).toBe(1)
        expect(curve.new(1, value):at(0.4)).toBe(1)
        expect(curve.sample(value, 1)).toBe(1)
      end
    end)

    test("anything else is refused", function()
      expect(string.find(refusal(7), "got number", 1, true) ~= nil).toBe(true)
      expect(string.find(refusal(true), "got boolean", 1, true) ~= nil).toBe(true)
    end)
  end)

  harness.describe("the shape cache", function()
    test("a thousand curves of one row's value decode it once", function()
      local serialized = unique(0.11)

      local count = decodes(serialized, function()
        for _ = 1, 1000 do
          curve.new(1, serialized):at(0.5)
        end
      end)

      expect(count).toBe(1)
    end)

    test("a buffer shares the shape of its string, and is decoded once", function()
      local serialized = unique(0.12)
      local held = buffer.fromstring(serialized)

      local count = decodes(serialized, function()
        for _ = 1, 10 do
          expect(curve.new(1, held).shape).toBe(curve.new(1, serialized).shape)
        end
      end)

      expect(count).toBe(1)
    end)

    test("a chain is found by its table, and a copy of it by its numbers", function()
      local chain = { vector.create(0, 0), vector.create(0.3, 0.1), vector.create(0.7, 0.9), vector.create(1, 1) }
      local copy = table.clone(chain)

      expect(curve.new(1, chain).shape).toBe(curve.new(1, chain).shape)
      expect(curve.new(1, copy).shape).toBe(curve.new(1, chain).shape)
    end)

    test("a row holding a preset's bytes shares the preset's shape", function()
      expect(curve.new(1, curves.default()).shape).toBe(curve.new(1, "easeOut").shape)
    end)

    test("it holds 256 shapes and lets the least recently used go first", function()
      local made = {}

      for i = 1, 257 do
        made[i] = unique(0.2 + i / 1000)
      end

      for i = 1, 256 do
        curve.new(1, made[i])
      end

      -- the first is used again, so the second is now the oldest
      expect(decodes(made[1], function()
        curve.new(1, made[1])
      end)).toBe(0)

      curve.new(1, made[257])

      expect(decodes(made[1], function()
        curve.new(1, made[1])
      end)).toBe(0)

      expect(decodes(made[2], function()
        curve.new(1, made[2])
      end)).toBe(1)
    end)

    test("a hit costs well under two microseconds", function()
      local serialized = unique(0.13)
      local rounds = 10000

      curve.new(1, serialized)

      local started = os.clock()

      for _ = 1, rounds do
        curve.new(1, serialized)
      end

      expect((os.clock() - started) / rounds < 2e-6).toBe(true)
    end)
  end)
end)
