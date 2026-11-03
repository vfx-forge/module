local particle_motion = require("@mod/particle_motion")
local numeric_common = require("@mod/common/numeric")
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

  harness.describe("particle_motion.gravity", function()
    test("gravity is the softened inverse square over a sweep", function()
      const rng = Random.new(11)

      for _ = 1, 400 do
        const position = vector.create(rng:NextNumber(-20, 20), rng:NextNumber(-20, 20), rng:NextNumber(-20, 20))
        const target = vector.create(rng:NextNumber(-20, 20), rng:NextNumber(-20, 20), rng:NextNumber(-20, 20))
        const mass = rng:NextNumber(0, 5000)
        const softening = rng:NextNumber(0, 4)
        const offset = target - position
        const want = offset * mass / (vector.dot(offset, offset) + softening * softening) ^ 1.5
        const got = particle_motion.gravity(position, target, mass, softening)

        expect(vector.magnitude(got - want) <= 1e-5 * math.max(vector.magnitude(want), 1)).toBe(true)
      end
    end)

    test("gravity at the target with no softening is zero, never NaN", function()
      const at = vector.create(1, 2, 3)

      expect(particle_motion.gravity(at, at, 1000, 0)).toBe(vector.zero)
      expect(particle_motion.gravity(at, at, 0, 0)).toBe(vector.zero)
      expect(particle_motion.gravity(at, at, 1000, 1)).toBe(vector.zero)
    end)

    test("gravity of mass 0 is zero", function()
      expect(particle_motion.gravity(vector.zero, vector.create(4, 0, 0), 0, 1)).toBe(vector.zero)
    end)

    test("an orbit launch is the circular speed, across the radius, on the launch's side", function()
      const target = vector.create(2, 0, 0)
      const position = vector.create(2, 0, 10)
      const look = vector.normalize(vector.create(1, 0, 1))

      for _, softening in { 0, 1, 3 } do
        const velocity = particle_motion.orbit(position, target, look, vector.create(0, 1, 0), 1000, softening)
        const pulled = particle_motion.gravity(position, target, 1000, softening)
        const radius = position - target

        expect(math.abs(vector.dot(velocity, radius)) < 1e-4).toBe(true)
        expect(vector.dot(velocity, look) > 0).toBe(true)
        expect(math.abs(vector.dot(velocity, velocity) / 10 - vector.magnitude(pulled)) < 1e-4).toBe(true)
      end
    end)

    test("a launch along the radius turns in the target's up plane, then the world's", function()
      const target = vector.zero
      const position = vector.create(10, 0, 0)
      const outward = vector.create(1, 0, 0)
      const tilted = particle_motion.orbit(position, target, outward, vector.create(0, 0, 1), 1000, 0)

      expect(close(vector.normalize(tilted), vector.create(0, 0, 1), 1e-6)).toBe(true)

      const upright = particle_motion.orbit(position, target, -outward, outward, 1000, 0)

      expect(close(vector.normalize(upright), vector.create(0, 1, 0), 1e-6)).toBe(true)
      expect(math.abs(vector.magnitude(upright) - 10) < 1e-5).toBe(true)
    end)

    test("an orbit launch at the target is still", function()
      const at = vector.create(1, 2, 3)

      expect(particle_motion.orbit(at, at, vector.create(0, 1, 0), vector.create(0, 1, 0), 1000, 0)).toBe(vector.zero)
    end)

    test("a verlet orbit at radius 10 keeps within 2% of it over five orbits", function()
      const target = vector.create(3, -1, 2)

      local position = target + vector.create(10, 0, 0)
      local velocity = particle_motion.orbit(position, target, vector.create(0, 1, 0), vector.create(0, 1, 0), 1000, 0)
      local lowest, highest = math.huge, 0

      -- one orbit at speed 10 around radius 10 takes 2 pi seconds
      for _ = 1, math.ceil(5 * 2 * math.pi * 60) do
        position, velocity =
          particle_motion.verlet(position, velocity, vector.zero, target, 1000, 0, 0, vector.zero, 1 / 60)

        const radius = vector.magnitude(position - target)

        lowest, highest = math.min(lowest, radius), math.max(highest, radius)
      end

      expect(lowest > 9.8 and highest < 10.2).toBe(true)
    end)

    test("a radial fall passes through the target and comes back out the other side", function()
      const target = vector.zero

      local position = vector.create(0, 10, 0)
      local velocity = vector.zero
      local through, back = false, false

      for _ = 1, 600 do
        position, velocity =
          particle_motion.verlet(position, velocity, vector.zero, target, 1000, 1, 0, vector.zero, 1 / 60)

        expect(numeric_common.usable(position) and numeric_common.usable(velocity)).toBe(true)

        through = through or position.y < -8
        back = back or (through and position.y > 8)
      end

      expect(through).toBe(true)
      expect(back).toBe(true)
    end)

    test("a retime by k plays the same gravity path k times faster at k squared the mass", function()
      const function flown(mass: number, speed: number, seconds: number, steps: number): vector
        const target = vector.zero

        local position = vector.create(10, 0, 0)
        local velocity = vector.create(-0.3, 0, 1) * speed

        for _ = 1, steps do
          position, velocity =
            particle_motion.verlet(position, velocity, vector.zero, target, mass, 1, 0, vector.zero, seconds / steps)
        end

        return position
      end

      -- rows at their units' factors: a mass by k squared, a speed by k
      const original = flown(1000, 8, 4, 4000)
      const retimed = flown(1000 * 4, 8 * 2, 2, 4000)

      expect(close(original, retimed, 1e-3)).toBe(true)
    end)

    test("a resize by s plays the same gravity path s times larger at s cubed the mass", function()
      const function flown(scale: number, mass: number): vector
        const target = vector.zero

        local position = vector.create(10, 0, 0) * scale
        local velocity = vector.create(-0.3, 0, 1) * 8 * scale

        for _ = 1, 4000 do
          position, velocity =
            particle_motion.verlet(position, velocity, vector.zero, target, mass, scale, 0, vector.zero, 4 / 4000)
        end

        return position
      end

      -- a length, its softening and a speed by s, the mass by s cubed
      const original = flown(1, 1000)
      const resized = flown(2, 1000 * 8)

      expect(close(original * 2, resized, 1e-3)).toBe(true)
    end)

    test("verlet of mass 0 is the plain step", function()
      const position, velocity = vector.create(1, 2, 3), vector.create(4, -5, 6)
      const acceleration, wind = vector.create(0, -9, 1), vector.create(2, 0, -1)
      const p1, v1 = particle_motion.verlet(position, velocity, acceleration, vector.zero, 0, 1, 0.7, wind, 0.03)
      const p2, v2 = particle_motion.step(position, velocity, acceleration, 0.7, wind, 0.03)

      expect(p1).toBe(p2)
      expect(v1).toBe(v2)
    end)

    test("a path under gravity is the verlet stepped at most 1/60 s at a time", function()
      const start = CFrame.new(10, 0, 0) * CFrame.fromOrientation(0.3, 0.2, 0.1)
      const acceleration = vector.create(0, -2, 0)
      const wind = vector.create(1, 0, 0)
      const gravity = { kind = "Gravity", target = vector.zero, mass = 1000, softening = 1 }
      const points = particle_motion.path(start, 6, 1.3, acceleration, 0.4, wind, 32, gravity)

      local position = vector.create(10, 0, 0)
      local look = start.LookVector
      local velocity = vector.create(look.X, look.Y, look.Z) * 6

      const function run(dt: number)
        const steps = particle_motion.substeps(dt)

        for _ = 1, steps do
          position, velocity =
            particle_motion.verlet(position, velocity, acceleration, vector.zero, 1000, 1, 0.4, wind, dt / steps)
        end
      end

      for index = 1, 41 do
        run(1 / 32)

        expect(close(points[index], position, 1e-6)).toBe(true)
      end

      run((1.3 * 32 - 41) / 32)

      expect(#points).toBe(42)
      expect(close(points[42], position, 1e-6)).toBe(true)
    end)

    test("a path with gravity bends toward the target", function()
      const start = CFrame.new(0, 0, 0)
      const target = vector.create(0, 20, 0)
      const free = particle_motion.path(start, 10, 1, vector.zero, 0, vector.zero, 30)
      const bent = particle_motion.path(
        start,
        10,
        1,
        vector.zero,
        0,
        vector.zero,
        30,
        { kind = "Gravity", target = target, mass = 3000, softening = 1 }
      )

      expect(vector.magnitude(bent[#bent] - target) < vector.magnitude(free[#free] - target)).toBe(true)
    end)

    test("a path without gravity is today's path", function()
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

    test("substeps cut a frame into at most 1/60 s pieces, with slack and a cap of 8", function()
      expect(particle_motion.substeps(1 / 60)).toBe(1)
      expect(particle_motion.substeps(1.04 / 60)).toBe(1)
      expect(particle_motion.substeps(1 / 30)).toBe(2)
      expect(particle_motion.substeps(1)).toBe(8)
      expect(particle_motion.substeps(0)).toBe(1)
    end)
  end)

  harness.describe("particle_motion.ring", function()
    const AXIS = vector.create(0, 1, 0)

    const function orbitOf(overrides: any?): particle_motion.Orbit
      const base = {
        kind = "Orbit",
        center = vector.zero,
        axis = AXIS,
        radius = 10,
        spin = 0.25,
        rise = 0,
        capture = 2,
        height = 0,
      }

      for key, value in overrides or {} do
        base[key] = value
      end

      return base :: any
    end

    const function flown(orbit: particle_motion.Orbit, from: vector, seconds: number)
      local position, velocity = from, vector.zero
      const angles = {}

      for _ = 1, math.round(seconds * 60) do
        position, velocity = particle_motion.advance(position, velocity, vector.zero, 0, vector.zero, orbit, 1 / 60)
        table.insert(angles, math.atan2(position.z, position.x))
      end

      return position, velocity, angles
    end

    test("a piece from radius 3 eases out to OrbitRadius at the capture's rate", function()
      const orbit = orbitOf()
      const position = flown(orbit, vector.create(3, 0, 0), 3 / 2)
      const radius = vector.magnitude(position)

      expect(math.abs(radius - (10 - 7 * math.exp(-3))) < 1e-3).toBe(true)

      const settled = flown(orbit, vector.create(3, 0, 0), math.log(70) / 2 + 0.05)

      expect(math.abs(vector.magnitude(settled) - 10) <= 0.1).toBe(true)
    end)

    test("the angle advances at OrbitSpin's turns per second", function()
      const orbit = orbitOf({ spin = 0.25 })
      const _, _, angles = flown(orbit, vector.create(3, 0, 0), 1)

      local turned = 0

      for i = 2, #angles do
        local step = angles[i] - angles[i - 1]

        if step > math.pi then
          step -= 2 * math.pi
        elseif step < -math.pi then
          step += 2 * math.pi
        end

        turned += step
      end

      -- about the up axis a positive turn runs from +x toward -z
      expect(math.abs(math.deg(-turned) - 90 * (59 / 60)) < 1e-2).toBe(true)
    end)

    test("a piece keeps to the height it spawned at and settles back to it", function()
      const orbit = orbitOf({ height = 4 })
      const position = flown(orbit, vector.create(3, 1, 0), 5)

      expect(math.abs(position.y - 4) < 1e-3).toBe(true)
    end)

    test("OrbitRise climbs the ring at its speed, a negative one sinking, the radius kept", function()
      for _, rise in { 5, -3 } do
        const orbit = orbitOf({ rise = rise })
        const position = flown(orbit, vector.create(10, 0, 0), 2)

        expect(math.abs(position.y - rise * 2) < 1e-3).toBe(true)
        expect(math.abs(vector.magnitude(vector.create(position.x, 0, position.z)) - 10) < 1e-3).toBe(true)
        expect(math.abs((orbit.height :: number) - rise * 2) < 1e-3).toBe(true)
      end
    end)

    test("a piece off a rising ring settles onto it and then climbs with it", function()
      const orbit = orbitOf({ rise = 4, height = 0 })
      const position, velocity = flown(orbit, vector.create(10, -6, 0), 4)

      expect(math.abs(position.y - 16) < 0.01).toBe(true)
      expect(math.abs(velocity.y - 4) < 0.01).toBe(true)
    end)

    test("the velocity is what the move took", function()
      const orbit = orbitOf()
      const from = vector.create(10, 0, 0)
      const to, velocity = particle_motion.advance(from, vector.zero, vector.zero, 0, vector.zero, orbit, 1 / 60)

      expect(close(velocity, (to - from) * 60, 1e-4)).toBe(true)
      expect(math.abs(vector.magnitude(velocity) - math.rad(90) * 10) < 0.01).toBe(true)
    end)

    test("acceleration, drag and wind leave the ring alone", function()
      const orbit = orbitOf()
      const from = vector.create(6, 0, 0)
      const a = particle_motion.advance(from, vector.zero, vector.create(0, -50, 0), 3, vector.one, orbit, 1 / 60)
      const b = particle_motion.advance(from, vector.zero, vector.zero, 0, vector.zero, orbit, 1 / 60)

      expect(a).toBe(b)
    end)

    test("a piece on the axis sets off the way it was launched, never NaN", function()
      const orbit = orbitOf()
      const position =
        particle_motion.advance(vector.zero, vector.create(0, 0, 5), vector.zero, 0, vector.zero, orbit, 1 / 60)

      expect(numeric_common.usable(position)).toBe(true)
      expect(position.z > 0).toBe(true)
    end)
  end)

  harness.describe("particle_motion.path under a force", function()
    test("a path under a rising orbit is advance stepped at most 1/60 s at a time", function()
      const start = CFrame.new(6, 0, 0)
      const orbit = {
        kind = "Orbit",
        center = vector.zero,
        axis = vector.create(0, 1, 0),
        radius = 4,
        spin = 1,
        rise = 5,
        capture = 3,
        height = 0,
      } :: particle_motion.Orbit
      const points = particle_motion.path(start, 0, 1, vector.zero, 0, vector.zero, 32, orbit)

      -- the path flies a copy, so the caller's force keeps its own height
      const own = table.clone(orbit)

      local position, velocity = vector.create(6, 0, 0), vector.zero

      for index = 1, 32 do
        for _ = 1, particle_motion.substeps(1 / 32) do
          position, velocity = particle_motion.advance(
            position,
            velocity,
            vector.zero,
            0,
            vector.zero,
            own,
            1 / 32 / particle_motion.substeps(1 / 32)
          )
        end

        expect(close(points[index], position, 1e-4)).toBe(true)
      end

      expect(orbit.height).toBe(0)
    end)

    test("an orbit path takes its height from where it starts", function()
      const orbit = {
        kind = "Orbit",
        center = vector.zero,
        axis = vector.create(0, 1, 0),
        radius = 10,
        spin = 0.25,
        rise = 0,
        capture = 2,
      } :: particle_motion.Orbit
      const points = particle_motion.path(CFrame.new(3, 2, 0), 0, 4, vector.zero, 0, vector.zero, 32, orbit)

      expect(math.abs(points[#points].y - 2) < 1e-3).toBe(true)
      expect(orbit.height).toBe(nil)
    end)

    test("rows sampled over the life drive the force as it flies", function()
      const start = CFrame.new(0, 0, 0)
      const gravity = { kind = "Gravity", target = vector.create(0, 20, 0), mass = 0, softening = 1 }
      const flat = particle_motion.path(start, 0, 1, vector.zero, 0, vector.zero, 30, gravity)
      const ramped = particle_motion.path(start, 0, 1, vector.zero, 0, vector.zero, 30, gravity, {
        span = 1,
        since = 0,
        lists = { mass = { 0, 3000 } },
      })

      expect(flat[#flat]).toBe(vector.zero)
      expect(ramped[#ramped].y > 1).toBe(true)
      expect(gravity.mass).toBe(0)
    end)

    test("rows drive the acceleration and drag too", function()
      const start = CFrame.new(0, 0, 0)
      const points = particle_motion.path(start, 0, 1, vector.zero, 0, vector.zero, 32, nil, {
        span = 1,
        since = 0,
        lists = { acceleration = { vector.create(0, -10, 0) } },
      })
      const plain = particle_motion.path(start, 0, 1, vector.create(0, -10, 0), 0, vector.zero, 32)

      expect(points[#points]).toBe(plain[#plain])
    end)
  end)

  harness.describe("particle_motion.sampled", function()
    test("a list sampled evenly reads between its two nearest samples", function()
      expect(particle_motion.sampled({ 4 }, 0.7)).toBe(4)
      expect(particle_motion.sampled({ 0, 10 }, 0.25)).toBe(2.5)
      expect(particle_motion.sampled({ 0, 10, 30 }, 0.75)).toBe(20)
      expect(particle_motion.sampled({ 0, 10 }, 2)).toBe(10)
      expect(particle_motion.sampled({ 0, 10 }, -1)).toBe(0)
    end)
  end)

  harness.describe("particle_motion.thin", function()
    const function circle(count: number, turns: number)
      const points = {}

      for i = 0, count do
        const a = i / count * turns * 2 * math.pi

        table.insert(points, vector.create(math.cos(a) * 10, 0, math.sin(a) * 10))
      end

      return points
    end

    test("a path that turns a lot keeps at most 64 points, its ends among them", function()
      const points = circle(4000, 30)
      const kept = particle_motion.thin(points, 64)

      expect(#kept <= 64).toBe(true)
      expect(#kept >= 32).toBe(true)
      expect(kept[1]).toBe(points[1])
      expect(kept[#kept]).toBe(points[#points])
    end)

    test("a path that turns little keeps a point every 3 degrees or so", function()
      const kept = particle_motion.thin(circle(720, 0.25), 64)

      -- a quarter turn is 30 bends of 3 degrees, and the eighths fall among them
      expect(#kept >= 28 and #kept <= 40).toBe(true)
    end)

    test("a straight path keeps its ends and a point every eighth", function()
      const points = {}

      for i = 0, 100 do
        table.insert(points, vector.create(i, 0, 0))
      end

      const kept = particle_motion.thin(points, 64)

      expect(#kept).toBe(9)
      expect(kept[#kept]).toBe(points[#points])
    end)

    test("a sharp bend is kept", function()
      const points = {}

      for i = 0, 50 do
        table.insert(points, vector.create(i, 0, 0))
      end

      for i = 1, 50 do
        table.insert(points, vector.create(50, i, 0))
      end

      const corner = points[51]

      expect(table.find(particle_motion.thin(points, 64), corner) ~= nil).toBe(true)
    end)

    test("a jagged path keeps its biggest bends within the cap", function()
      const points = {}
      const rng = Random.new(3)

      for i = 0, 2000 do
        table.insert(points, vector.create(i * 0.1, rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)))
      end

      expect(#particle_motion.thin(points, 64) <= 64).toBe(true)
    end)

    test("a path of two points or fewer is itself", function()
      const two = { vector.zero, vector.one }

      expect(particle_motion.thin(two, 64)).toBe(two)
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
