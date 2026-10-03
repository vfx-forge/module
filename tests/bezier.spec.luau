local process = require("@lune/process")
local harness = require("@tests/harness")

local Bezier = require("@obj/Bezier")
local Before = require("@tests/fixtures/Bezier_213759c")

local test, expect = harness.test, harness.expect

local SAMPLES = 10000

-- a fixed sequence of numbers in 0 to 1, so every run measures the same chains
local seed = 1

local function fraction(): number
  seed = (seed * 1103515245 + 12345) % 2147483648

  return seed / 2147483648
end

local function anywhere(scale: number): vector
  return vector.create((fraction() - 0.5) * scale, (fraction() - 0.5) * scale, (fraction() - 0.5) * scale)
end

-- a chain of `segments` segments, handles anywhere within `scale` studs
local function chain(segments: number, scale: number): { vector }
  local points = {}

  for _ = 1, segments * 3 + 1 do
    table.insert(points, anywhere(scale))
  end

  return points
end

-- the chains every accuracy test runs over: random ones of 1 to 10 segments,
-- handles collapsed onto their anchors, handles crossed into a near cusp, a
-- loop, and a straight pair
local function cases(): { { vector } }
  local list = {}

  for segments = 1, 10 do
    table.insert(list, chain(segments, 50))
  end

  local a, b = vector.create(0, 0, 0), vector.create(30, 5, -2)

  table.insert(list, { a, a, b, b })
  table.insert(list, { a, vector.create(40, 0, 0), vector.create(-10, 0, 0), vector.create(30, 0.001, 0) })
  table.insert(list, { a, vector.create(20, 20, 0), vector.create(-20, 20, 0), vector.create(0.5, 0, 0) })
  table.insert(list, { a, b })

  return list
end

local function cubic(p0: vector, p1: vector, p2: vector, p3: vector, s: number): vector
  local r = 1 - s

  return p0 * (r * r * r) + p1 * (3 * r * r * s) + p2 * (3 * r * s * s) + p3 * (s * s * s)
end

-- the chain walked in SAMPLES even steps of its parameter: each step's point
-- and the length up to it
local function walk(points: { vector }): ({ vector }, { number })
  if #points == 2 then
    points =
      { points[1], points[1] + (points[2] - points[1]) / 3, points[1] + (points[2] - points[1]) * (2 / 3), points[2] }
  end

  local segments = (#points - 1) // 3
  local at, lengths = {}, {}
  local total = 0

  for n = 0, SAMPLES do
    local t = n / SAMPLES * segments
    local k = math.min(t // 1, segments - 1)
    local i = k * 3 + 1
    local p = cubic(points[i], points[i + 1], points[i + 2], points[i + 3], t - k)

    if n > 0 then
      total += vector.magnitude(p - at[n])
    end

    at[n + 1] = p
    lengths[n + 1] = total
  end

  return at, lengths
end

-- the brute force point u of the way along by distance
local function along(at: { vector }, lengths: { number }, u: number): vector
  local want = u * lengths[#lengths]

  for n = 2, #lengths do
    if lengths[n] >= want then
      local stretch = lengths[n] - lengths[n - 1]
      local f = if stretch > 0 then (want - lengths[n - 1]) / stretch else 0

      return at[n - 1] + (at[n] - at[n - 1]) * f
    end
  end

  return at[#at]
end

local function refusal(points: { vector }): string
  local ok, err = pcall(Bezier.new, points)

  expect(ok).toBe(false)

  return tostring(err)
end

-- two chains of ten segments that differ at every point, so each set moves
-- every segment
local function pair(): ({ vector }, { vector })
  local a = chain(10, 60)
  local b = {}

  for i, p in a do
    b[i] = p + vector.create(0.5, 0.25, -0.5)
  end

  return a, b
end

-- run on its own as `lune run tests/bezier.spec gate`: the best of 200 rounds
-- of a set and 100 atUniform reads, in seconds
if process.args[1] == "gate" then
  local a, b = pair()
  local path = Bezier.new(a)
  local best = math.huge

  for round = 1, 200 do
    local started = os.clock()

    path:set(if round % 2 == 0 then a else b)

    for n = 0, 99 do
      path:atUniform(n / 99)
    end

    best = math.min(best, os.clock() - started)
  end

  print(best)
  process.exit(0)
end

harness.suite(function()
  harness.describe("Bezier", function()
    test("at is the old getPosition", function()
      for _, points in cases() do
        if #points == 2 then
          continue
        end

        local path = Bezier.new(points)
        local before = Before.new(points, 0)

        for n = 0, 100 do
          local t = n / 100
          local gap = vector.magnitude(path:at(t) - before:getPosition(t))

          if gap > 1e-3 then
            error(`{#points} points at {t}: {gap} studs from the old position`, 0)
          end
        end
      end
    end)

    test("length is within 0.1% of a 10000 step walk", function()
      for _, points in cases() do
        local _, lengths = walk(points)
        local walked = lengths[#lengths]
        local measured = Bezier.new(points):length()

        if math.abs(measured - walked) > walked * 1e-3 then
          error(`{#points} points: {measured} against {walked}`, 0)
        end
      end
    end)

    test("atUniform is within 0.1% of the length from a 10000 step walk", function()
      for _, points in cases() do
        local at, lengths = walk(points)
        local path = Bezier.new(points)
        local total = lengths[#lengths]

        for n = 0, 200 do
          local u = n / 200
          local gap = vector.magnitude(path:atUniform(u) - along(at, lengths, u))

          if gap > total * 1e-3 then
            error(`{#points} points at {u}: {gap} studs off on a {total} stud curve`, 0)
          end
        end
      end
    end)

    test("two points are a straight segment", function()
      local a, b = vector.create(1, 2, 3), vector.create(7, 2, 3)
      local path = Bezier.new({ a, b })

      expect(vector.magnitude(path:at(0.5) - vector.create(4, 2, 3)) < 1e-5).toBe(true)
      expect(math.abs(path:length() - 6) < 1e-5).toBe(true)
      expect(vector.magnitude(path:tangent(0.3) - vector.create(1, 0, 0)) < 1e-5).toBe(true)
    end)

    test("tangent is the unit direction of travel, and zero where the curve stands still", function()
      local path = Bezier.new(chain(3, 40))

      for n = 1, 9 do
        local t = n / 10
        local ahead = vector.normalize(path:at(t + 1e-4) - path:at(t - 1e-4))

        expect(math.abs(vector.magnitude(path:tangent(t)) - 1) < 1e-5).toBe(true)
        expect(vector.dot(path:tangent(t), ahead) > 0.999).toBe(true)
      end

      local stopped = vector.create(5, 5, 5)

      expect(Bezier.new({ stopped, stopped, stopped, stopped }):tangent(0.5)).toBe(vector.zero)
    end)

    test("a chain of any other count is refused with the count", function()
      expect(string.find(refusal({}), "2 or 3n + 1 points, got 0", 1, true) ~= nil).toBe(true)
      expect(string.find(refusal({ vector.zero, vector.one, vector.zero }), "got 3", 1, true) ~= nil).toBe(true)
    end)

    test("set reads as a new curve of the same points", function()
      local points = chain(4, 30)
      local path = Bezier.new(chain(4, 30))

      path:length()
      path:set(points)

      local fresh = Bezier.new(points)

      expect(math.abs(path:length() - fresh:length()) < 1e-9).toBe(true)

      for n = 0, 20 do
        expect(path:atUniform(n / 20)).toBe(fresh:atUniform(n / 20))
      end
    end)

    test("set measures only the segments that moved, and nothing until asked", function()
      local points = chain(4, 30)
      local path = Bezier.new(points)
      local lengths = table.clone((path:length() :: any) and path.lengths)

      local moved = table.clone(points)
      moved[13] += vector.create(0, 5, 0)

      path:set(table.clone(points))

      expect(path.stale).toBe(false)

      path:set(moved)

      expect(path.stale).toBe(true)
      expect(path.moved).toEqual({ false, false, false, true })

      path:length()

      expect(path.lengths[1]).toBe(lengths[1])
      expect(path.lengths[3]).toBe(lengths[3])
      expect(path.lengths[4] ~= lengths[4]).toBe(true)
    end)

    test("set with another count of points takes the new chain whole", function()
      local path = Bezier.new(chain(2, 30))
      local points = chain(5, 30)

      path:set(points)

      expect(path.segments).toBe(5)
      expect(math.abs(path:length() - Bezier.new(points):length()) < 1e-9).toBe(true)
    end)
  end)

  harness.describe("Bezier's cost", function()
    -- an earlier spec reads its globals through getfenv, which turns off the
    -- fast library calls for the whole process, so the gate is timed in a
    -- lune of its own
    test("a set of ten moved segments and 100 atUniform reads take under 0.1 ms", function()
      local result = process.exec("lune", { "run", "tests/bezier.spec", "gate" })

      expect(result.ok).toBe(true)

      local best = tonumber(result.stdout) :: number

      print(`  bezier rebuild: set of 10 moved segments and 100 atUniform in {string.format("%.4f", best * 1000)} ms`)

      expect(best < 1e-4).toBe(true)
    end)

    test("set and every read allocate nothing once the curve exists", function()
      local a, b = pair()
      local path = Bezier.new(a)

      path:length()

      local before = gcinfo()

      for round = 1, 1000 do
        path:set(if round % 2 == 0 then a else b)
        path:at(0.3)
        path:tangent(0.6)
        path:length()
        path:atUniform(0.7)
      end

      -- a round that made one small table would grow it by tens of KB
      expect(gcinfo() - before < 1).toBe(true)
    end)
  end)
end)
