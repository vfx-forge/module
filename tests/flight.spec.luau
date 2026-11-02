-- the harness installs the engine globals the scheduler reads, so it comes first
const harness = require("@tests/harness")

const lifetime = require("@mod/lifetime")
const scheduler = require("@mod/scheduler")
const flight_common = require("@mod/common/flight")

const mover = require("@srv/mover")

const test, expect = harness.test, harness.expect
const CFrame = harness.datatypes.CFrame
const Vector3 = harness.datatypes.Vector3

const EPSILON = 1e-4

const function near(a: Vector3, b: Vector3)
  return (a - b).Magnitude < EPSILON
end

-- a part flown from `start` on a fresh effect, the frames stepped and the
-- mover flushed after each; answers the part's pose and how often `done` had
-- run after each frame
const function fly(start: CFrame, velocity: Vector3, duration: number, opts: any, frames: { number })
  const part = harness.make("Part") :: BasePart
  const emit = lifetime.emit(nil)
  const fx = lifetime.effect(emit, 0, nil)
  local calls = 0
  const seen = {}

  part.CFrame = start

  -- the effect stays up until the flight lands, as a bolt's does
  lifetime.run(fx, function(scope: lifetime.effect)
    const flying = lifetime.join(scope)
    const landed = lifetime.add(flying)

    flight_common.projectile(scope, part, velocity :: any, duration, opts, function()
      calls += 1
      landed()
    end)

    lifetime.awaitJoin(flying)
  end)

  for _, deltaTime in frames do
    scheduler.frame(deltaTime)
    mover.flush()
    table.insert(seen, { calls = calls, cframe = part.CFrame })
  end

  lifetime.clear(emit)
  mover.clear()

  return seen
end

harness.suite(function()
  harness.describe("a projectile's flight", function()
    test("flies on at its velocity keeping the part's turn, done once when its time is up", function()
      const turn = CFrame.fromOrientation(0, 1, 0)
      const seen = fly(CFrame.new(1, 2, 3) * turn, Vector3.new(2, 0, 0), 1, {}, { 0.5, 0.5, 0.5 })

      expect(near(seen[1].cframe.Position, Vector3.new(2, 2, 3))).toBe(true)
      expect(near(seen[1].cframe.LookVector, turn.LookVector)).toBe(true)
      expect(near(seen[2].cframe.Position, Vector3.new(3, 2, 3))).toBe(true)
      expect({ seen[1].calls, seen[2].calls, seen[3].calls }).toEqual({ 0, 1, 1 })
    end)

    test("a hit ends it on that frame, done once, and the part stays where it hit", function()
      local hits = 0
      const original = workspace.GetPartsInPart

      -- the second step of the flight is the first to touch anything
      -- selene: allow(incorrect_standard_library_use)
      workspace.GetPartsInPart = function()
        hits += 1

        return if hits >= 2 then { true } else {}
      end

      const ok, seen = pcall(fly, CFrame.new(0, 0, 0), Vector3.new(1, 0, 0), 4, { params = {} }, { 0.5, 0.5, 0.5 })

      -- selene: allow(incorrect_standard_library_use)
      workspace.GetPartsInPart = original

      expect(ok).toBe(true)
      expect({ seen[1].calls, seen[2].calls, seen[3].calls }).toEqual({ 1, 1, 1 })
      expect(near(seen[3].cframe.Position, Vector3.new(0.5, 0, 0))).toBe(true)
    end)

    test("a followed flight is carried by the live origin and takes its turn", function()
      const turn = CFrame.fromOrientation(0, 1, 0)
      const moved = CFrame.new(0, 10, 0) * turn
      local reads = 0

      -- the origin stands off to the side as the flight sets off, then moves
      const function follow()
        reads += 1

        return if reads == 1 then CFrame.new(5, 0, 0) else moved
      end

      const start = CFrame.new(1, 0, 0) * CFrame.fromOrientation(0.5, 0, 0)
      const seen = fly(start, Vector3.new(0, 0, 2), 4, { follow = follow }, { 0.5 })

      expect(near(seen[1].cframe.Position, moved:PointToWorldSpace(Vector3.new(-4, 0, 1)))).toBe(true)
      expect(near(seen[1].cframe.LookVector, turn.LookVector)).toBe(true)
    end)

    test("a followed flight that keeps its turn turns with the origin from where it set off", function()
      const turn = CFrame.fromOrientation(0, 1, 0)
      const moved = CFrame.new(0, 10, 0) * turn
      local reads = 0

      const function follow()
        reads += 1

        return if reads == 1 then CFrame.new(5, 0, 0) else moved
      end

      const tilt = CFrame.fromOrientation(0.5, 0, 0)
      const start = CFrame.new(1, 0, 0) * tilt
      const seen = fly(start, Vector3.new(0, 0, 2), 4, { follow = follow, keepTurn = true }, { 0.5 })

      expect(near(seen[1].cframe.Position, moved:PointToWorldSpace(Vector3.new(-4, 0, 1)))).toBe(true)
      expect(near(seen[1].cframe.LookVector, (turn * tilt).LookVector)).toBe(true)
      expect(near(seen[1].cframe.UpVector, (turn * tilt).UpVector)).toBe(true)
    end)
  end)
end)
