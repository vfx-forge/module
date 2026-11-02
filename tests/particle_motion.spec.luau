local particle_motion = require("@mod/particle_motion")
local roblox = require("@lune/roblox") :: any
local harness = require("@tests/harness")

local test, expect = harness.test, harness.expect
local CFrame = harness.datatypes.CFrame
local Vector3 = harness.datatypes.Vector3
local NormalId = roblox.Enum.NormalId

local EPSILON = 1e-4

local ORIGIN = CFrame.new(3, -2, 7) * CFrame.fromOrientation(0.4, 1.1, -0.3)

local function config(overrides: any?): particle_motion.Config
  local base = {
    shape = "Box",
    surface = false,
    partial = 1,
    normal = NormalId.Top,
    face = "Outward",
    spread = vector.zero,
  }

  for key, value in overrides or {} do
    base[key] = value
  end

  return base :: any
end

local function close(a: vector, b: vector, epsilon: number): boolean
  return vector.magnitude(a - b) < epsilon
end

local function near(a: Vector3, b: Vector3, epsilon: number): boolean
  return (a - b).Magnitude < epsilon
end

local function stepped(
  position: vector,
  velocity: vector,
  acceleration: vector,
  drag: number,
  wind: vector,
  dts: { number }
)
  for _, dt in dts do
    position, velocity = particle_motion.step(position, velocity, acceleration, drag, wind, dt)
  end

  return position, velocity
end

harness.suite(function()
  harness.describe("particle_motion.step", function()
    test("step with no drag follows the closed form", function()
      const dts = table.create(30, 1 / 30)
      const position, velocity =
        stepped(vector.zero, vector.create(0, 10, 0), vector.create(0, -20, 0), 0, vector.zero, dts)

      expect(close(position, vector.zero, 1e-6)).toBe(true)
      expect(close(velocity, vector.create(0, -10, 0), 1e-6)).toBe(true)
    end)

    test("drag halves the speed every 1/drag seconds", function()
      const dts = { 0.05, 0.1, 0.02, 0.13, 0.08, 0.07, 0.05 }
      const _, velocity = stepped(vector.zero, vector.create(8, 0, 0), vector.zero, 2, vector.zero, dts)

      expect(math.abs(vector.magnitude(velocity) - 4) < 1e-6).toBe(true)
    end)

    test("drag pulls the velocity toward the wind", function()
      const wind = vector.create(10, 0, 0)
      const _, velocity = stepped(vector.zero, vector.zero, vector.zero, 2, wind, table.create(5, 0.1))

      expect(close(velocity, vector.create(5, 0, 0), 1e-6)).toBe(true)
    end)

    test("zero wind is the old formula", function()
      const velocity = vector.create(3, 4, -5)
      const acceleration = vector.create(1, -9, 2)
      const dt = 0.07
      const _, got = particle_motion.step(vector.zero, velocity, acceleration, 1.5, vector.zero, dt)
      const want = (velocity + acceleration * dt) * 2 ^ (-1.5 * dt)

      expect(got).toBe(want)
    end)
  end)

  harness.describe("particle_motion.spawn", function()
    test("a point origin launches along the emission normal", function()
      const cf = particle_motion.spawn(ORIGIN, Vector3.zero, config(), Random.new(1))

      expect(near(cf.LookVector, ORIGIN.UpVector, EPSILON)).toBe(true)
      expect(near(cf.Position, ORIGIN.Position, EPSILON)).toBe(true)
    end)

    test("spread stays inside its cone", function()
      const rng = Random.new(7)
      const spread = config({ spread = vector.create(30, 0, 0) })

      local widest = 0

      for _ = 1, 500 do
        const cf = particle_motion.spawn(ORIGIN, Vector3.zero, spread, rng)
        const angle = math.deg(math.acos(math.clamp(cf.LookVector:Dot(ORIGIN.UpVector), -1, 1)))

        expect(angle <= 30 + EPSILON).toBe(true)

        widest = math.max(widest, angle)
      end

      expect(widest > 20).toBe(true)
    end)

    test("Inward faces back", function()
      const cf = particle_motion.spawn(ORIGIN, Vector3.zero, config({ face = "Inward" }), Random.new(1))

      expect(near(cf.LookVector, -ORIGIN.UpVector, EPSILON)).toBe(true)
    end)
  end)

  harness.describe("particle_motion.path", function()
    test("a path ends where stepping ends", function()
      const start = CFrame.new(1, 2, 3) * CFrame.fromOrientation(0.3, 0.2, 0.1)
      const acceleration = vector.create(0, -9, 1)
      const wind = vector.create(2, 0, -1)
      const points = particle_motion.path(start, 12, 1.3, acceleration, 0.4, wind, 32)

      local position = vector.create(1, 2, 3)
      local look = start.LookVector
      local velocity = vector.create(look.X, look.Y, look.Z) * 12

      for _ = 1, 41 do
        position, velocity = particle_motion.step(position, velocity, acceleration, 0.4, wind, 1 / 32)
      end

      position, velocity = particle_motion.step(position, velocity, acceleration, 0.4, wind, (1.3 * 32 - 41) / 32)

      expect(#points).toBe(42)
      expect(close(points[#points], position, 1e-4)).toBe(true)
    end)
  end)

  harness.describe("particle_motion.pull", function()
    test("a pull points at the target", function()
      const position = vector.create(1, 2, 3)
      const target = vector.create(4, 6, 3)
      const pulled = particle_motion.pull(position, target, 5)

      expect(close(pulled, vector.create(3, 4, 0), 1e-4)).toBe(true)
    end)

    test("a pull at the target is zero", function()
      const position = vector.create(1, 2, 3)
      const pulled = particle_motion.pull(position, position, 5)

      expect(close(pulled, vector.zero, 1e-6)).toBe(true)
    end)

    test("a negative pull pushes away", function()
      const pulled = particle_motion.pull(vector.zero, vector.create(10, 0, 0), -2)

      expect(close(pulled, vector.create(-2, 0, 0), 1e-4)).toBe(true)
    end)

    test("a path with a pull bends toward the target", function()
      const start = CFrame.new(0, 0, 0)
      const target = vector.create(0, 20, 0)
      const free = particle_motion.path(start, 10, 1, vector.zero, 0, vector.zero, 30)
      const bent =
        particle_motion.path(start, 10, 1, vector.zero, 0, vector.zero, 30, { target = target, strength = 30 })

      expect(vector.magnitude(bent[#bent] - target) < vector.magnitude(free[#free] - target)).toBe(true)
    end)

    test("a path without a pull is today's path", function()
      const start = CFrame.new(1, 2, 3) * CFrame.fromOrientation(0.3, 0.2, 0.1)
      const acceleration = vector.create(0, -9, 1)
      const wind = vector.create(2, 0, -1)
      const points = particle_motion.path(start, 12, 1.3, acceleration, 0.4, wind, 32, nil)

      local position = vector.create(1, 2, 3)
      local look = start.LookVector
      local velocity = vector.create(look.X, look.Y, look.Z) * 12

      for index = 1, 41 do
        position, velocity = particle_motion.step(position, velocity, acceleration, 0.4, wind, 1 / 32)

        expect(points[index]).toBe(position)
      end
    end)
  end)

  harness.describe("particle_motion.wander", function()
    test("wander stays inside its amount", function()
      for index = 0, 999 do
        const offset = particle_motion.wander(3.7, index * 0.05, 2, 1.5)

        expect(math.abs(offset.x) <= 1.5).toBe(true)
        expect(math.abs(offset.y) <= 1.5).toBe(true)
        expect(math.abs(offset.z) <= 1.5).toBe(true)
      end
    end)

    test("wander is smooth", function()
      const amount = 2

      for index = 0, 999 do
        const a = particle_motion.wander(1.2, index / 60, 1, amount)
        const b = particle_motion.wander(1.2, (index + 1) / 60, 1, amount)

        expect(vector.magnitude(a - b) < amount * 0.2).toBe(true)
      end
    end)

    test("wander starts at zero, so a piece leaves its spawn without a jump", function()
      for seed = 0, 99 do
        expect(particle_motion.wander(seed * 9.7 + 0.3, 0, 3, 2)).toBe(vector.zero)
        expect(vector.magnitude(particle_motion.wander(seed * 9.7 + 0.3, 1 / 60, 3, 2)) < 0.5).toBe(true)
      end
    end)

    test("a wander given its rest equals one that works it out, and the noise it was", function()
      for seed = 0, 40 do
        const base = seed * 23.17 + 0.4
        const rest = particle_motion.rest(base)

        for index = 0, 30 do
          const age = index * 0.07
          const given = particle_motion.wander(base, age, 1.7, 2.5, rest)
          const t = age * 1.7
          const expected = vector.create(
            math.clamp((math.noise(base, t, 0.5) - math.noise(base, 0, 0.5)) * 5, -2.5, 2.5),
            math.clamp((math.noise(base + 17.1, t, 0.5) - math.noise(base + 17.1, 0, 0.5)) * 5, -2.5, 2.5),
            math.clamp((math.noise(base + 34.2, t, 0.5) - math.noise(base + 34.2, 0, 0.5)) * 5, -2.5, 2.5)
          )

          expect(given).toBe(expected)
          expect(particle_motion.wander(base, age, 1.7, 2.5)).toBe(expected)
        end
      end
    end)

    test("wander is zero at amount 0", function()
      expect(particle_motion.wander(5, 1.3, 2, 0)).toBe(vector.zero)
    end)
  end)
end)
