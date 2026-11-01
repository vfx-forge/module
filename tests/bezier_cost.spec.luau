local process = require("@lune/process")
local harness = require("@tests/harness")

local Bezier = require("@obj/Bezier")

local test, expect = harness.test, harness.expect

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

-- run on its own as `lune run tests/bezier_cost.spec gate`: the best of 200 rounds
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
  harness.describe("Bezier's cost", function()
    -- an earlier spec reads its globals through getfenv, which turns off the
    -- fast library calls for the whole process, so the gate is timed in a
    -- lune of its own
    test("a set of ten moved segments and 100 atUniform reads are timed", function()
      local result = process.exec("lune", { "run", "tests/bezier_cost.spec", "gate" })

      expect(result.ok).toBe(true)

      local best = tonumber(result.stdout) :: number

      print(`  bezier rebuild: set of 10 moved segments and 100 atUniform in {string.format("%.4f", best * 1000)} ms`)
    end)

    test("set and every read allocate nothing once the curve exists", function()
      local a, b = pair()
      local path = Bezier.new(a)

      local function round(n: number)
        path:set(if n % 2 == 0 then a else b)
        path:at(0.3)
        path:tangent(0.6)
        path:length()
        path:atUniform(0.7)
      end

      -- the first reads build what the curve keeps, about 1.5 KB, which is
      -- the curve existing and not a round's own cost
      round(1)
      round(2)

      local before = collectgarbage("count")

      for n = 1, 1000 do
        round(n)
      end

      -- a round that made one small table would grow it by tens of KB
      expect(collectgarbage("count") - before < 1).toBe(true)
    end)
  end)
end)
