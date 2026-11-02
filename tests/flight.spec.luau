local mover = require("@srv/mover")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local flight_common = require("@mod/common/flight")

local test, expect = harness.test, harness.expect
local CFrame = harness.datatypes.CFrame
local Vector3 = harness.datatypes.Vector3

local EPSILON = 1e-4

local function near(a: Vector3, b: Vector3)
  return (a - b).Magnitude < EPSILON
end

-- a part flown from `start` on a fresh effect, the frames stepped and the
-- mover flushed after each; answers the part's pose and how often `done` had
-- run after each frame
local function fly(start: CFrame, velocity: Vector3, duration: number, opts: any, frames: { number })
  local part = harness.make("Part") :: BasePart
  local emit = lifetime.emit(nil)
  local fx = lifetime.effect(emit, 0, nil)
  local calls = 0
  local seen = {}

  part.CFrame = start

  -- the effect stays up until the flight lands, as a bolt's does
  lifetime.run(fx, function(scope: lifetime.effect)
    local flying = lifetime.join(scope)
    local landed = lifetime.add(flying)

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
      local turn = CFrame.fromOrientation(0, 1, 0)
      local seen = fly(CFrame.new(1, 2, 3) * turn, Vector3.new(2, 0, 0), 1, {}, { 0.5, 0.5, 0.5 })

      expect(near(seen[1].cframe.Position, Vector3.new(2, 2, 3))).toBe(true)
      expect(near(seen[1].cframe.LookVector, turn.LookVector)).toBe(true)
      expect(near(seen[2].cframe.Position, Vector3.new(3, 2, 3))).toBe(true)
      expect({ seen[1].calls, seen[2].calls, seen[3].calls }).toEqual({ 0, 1, 1 })
    end)

    test("a hit ends it on that frame, done once, and the part stays where it hit", function()
      local hits = 0
      local original = workspace.GetPartsInPart

      -- the second step of the flight is the first to touch anything
      -- selene: allow(incorrect_standard_library_use)
      workspace.GetPartsInPart = function()
        hits += 1

        return if hits >= 2 then { true } else {}
      end

      local ok, seen = pcall(fly, CFrame.new(0, 0, 0), Vector3.new(1, 0, 0), 4, { params = {} }, { 0.5, 0.5, 0.5 })

      -- selene: allow(incorrect_standard_library_use)
      workspace.GetPartsInPart = original

      expect(ok).toBe(true)
      expect({ seen[1].calls, seen[2].calls, seen[3].calls }).toEqual({ 1, 1, 1 })
      expect(near(seen[3].cframe.Position, Vector3.new(0.5, 0, 0))).toBe(true)
    end)

    test("a followed flight is carried by the live origin and takes its turn", function()
      local turn = CFrame.fromOrientation(0, 1, 0)
      local moved = CFrame.new(0, 10, 0) * turn
      local reads = 0

      -- the origin stands off to the side as the flight sets off, then moves
      local function follow()
        reads += 1

        return if reads == 1 then CFrame.new(5, 0, 0) else moved
      end

      local start = CFrame.new(1, 0, 0) * CFrame.fromOrientation(0.5, 0, 0)
      local seen = fly(start, Vector3.new(0, 0, 2), 4, { follow = follow }, { 0.5 })

      expect(near(seen[1].cframe.Position, moved:PointToWorldSpace(Vector3.new(-4, 0, 1)))).toBe(true)
      expect(near(seen[1].cframe.LookVector, turn.LookVector)).toBe(true)
    end)
  end)
end)
