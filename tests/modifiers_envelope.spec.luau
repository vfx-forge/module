-- A TWEEN'S ENVELOPE PLAYS WHERE IT IS DRAWN. The editor stores one width per
-- curve point and draws the band between them linearly in time, by each
-- point's own time, the way the engine reads a NumberSequence keypoint's
-- envelope. The runtime once spread the widths evenly across the run instead,
-- so a curve whose points were not evenly spaced played a band that was not
-- the one drawn (0.24 off at t = 0.1 for points at 0, 0.1 and 1)
local modifiers = require("@mod/modifiers")
local path = require("@mod/common/path")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local UDim2 = harness.datatypes.UDim2

-- a corner point at time x, value v (path.serializePath reads only these)
local function cp(x: number, v: number)
  return { Position = UDim2.fromScale(x, 1 - v), LeftTangent = UDim2.new(), RightTangent = UDim2.new() }
end

local function widths(list: { number }): buffer
  local buf = buffer.create(#list * 4)

  for i, w in list do
    buffer.writef32(buf, (i - 1) * 4, w)
  end

  return buf
end

-- the tween's value at t over a run of 1, its instance rolled to the top of
-- the band (ctx.envelope 1), from 0 to 1 so the value is the alpha
local function played(curve: buffer, envelope: buffer, t: number): number
  local queue = {
    {
      kind = "tween",
      chain = false,
      duration = 1,
      start = { t = "lit", v = 0 },
      finish = { t = "lit", v = 1 },
      curve = curve,
      envelope = envelope,
    },
  }

  return modifiers.evaluate(queue, t, { duration = 1, envelope = 1 }) :: number
end

-- the runtime's old read, evenly across the run, for what must not change
local function evenly(buf: buffer, progress: number): number
  local n = math.floor(buffer.len(buf) / 4)
  local pos = math.clamp(progress, 0, 1) * (n - 1)
  local i = math.floor(pos)

  if i >= n - 1 then
    return buffer.readf32(buf, (n - 1) * 4)
  end

  local a = buffer.readf32(buf, i * 4)
  local b = buffer.readf32(buf, (i + 1) * 4)

  return a + (b - a) * (pos - i)
end

local function near(a: number, b: number): boolean
  return math.abs(a - b) < 1e-5
end

harness.suite(function()
  harness.describe("a tween's envelope", function()
    test("plays by each point's time, as the band is drawn", function()
      local curve = path.serializePath({ cp(0, 0.2), cp(0.1, 0.3), cp(1, 0.2) })
      local envelope = widths({ 0, 0.3, 0 })

      -- at the point, between it and the start, and halfway to the end
      for _, case in { { 0.1, 0.3 }, { 0.05, 0.15 }, { 0.55, 0.15 } } do
        local t, width = case[1], case[2]
        local alpha = modifiers.alphaFromCurve(curve, t)

        expect(near(played(curve, envelope, t), math.clamp(alpha + width, 0, 1))).ok()
      end
    end)

    test("evenly spaced points play exactly as before", function()
      local curve = path.serializePath({ cp(0, 0.1), cp(0.5, 0.4), cp(1, 0.2) })
      local envelope = widths({ 0.1, 0.4, 0.2 })

      for i = 0, 60 do
        local t = i / 60
        local alpha = modifiers.alphaFromCurve(curve, t)

        expect(played(curve, envelope, t)).toBe(math.clamp(alpha + evenly(envelope, t), 0, 1))
      end
    end)

    test("one width everywhere plays exactly as before", function()
      local curve = path.serializePath({ cp(0, 0.1), cp(0.1, 0.4), cp(0.8, 0.3), cp(1, 0.2) })
      local envelope = widths({ 0.2, 0.2, 0.2, 0.2 })

      for i = 0, 60 do
        local t = i / 60
        local alpha = modifiers.alphaFromCurve(curve, t)

        expect(played(curve, envelope, t)).toBe(math.clamp(alpha + evenly(envelope, t), 0, 1))
      end
    end)
  end)
end)
