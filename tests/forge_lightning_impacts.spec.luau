const rng = require("@mod/lightning/rng")
const impacts = require("@mod/lightning/impacts")
const harness = require("@tests/harness")
const describe, test, expect = harness.describe, harness.test, harness.expect

const UP = vector.create(0, 1, 0)

const function near(a: vector, b: vector): boolean
  return vector.magnitude(a - b) < 1e-6
end

const function frameHolds(right: vector, up: vector, look: vector, slack: number?): boolean
  const eps = slack or 1e-6

  return vector.magnitude(vector.cross(right, up) + look) < eps
    and math.abs(vector.dot(right, up)) < eps
    and math.abs(vector.dot(up, look)) < eps
    and math.abs(vector.dot(right, look)) < eps
    and math.abs(vector.magnitude(right) - 1) < eps
    and math.abs(vector.magnitude(up) - 1) < eps
    and math.abs(vector.magnitude(look) - 1) < eps
end

const function finite(v: vector): boolean
  return v.x == v.x and v.y == v.y and v.z == v.z
end

harness.suite(function()
  describe("impacts", function()
    test("Surface on a floor", function()
      const right, up, look = impacts.axes(UP, vector.create(1, -1, 0), "Surface")

      expect(near(up, UP)).toBe(true)
      expect(near(look, vector.create(1, 0, 0))).toBe(true)
      expect(frameHolds(right, up, look)).toBe(true)
    end)

    test("Surface on a wall and a slope", function()
      const wall = vector.create(-1, 0, 0)
      const slope = vector.normalize(vector.create(1, 1, 0))
      const travel = vector.create(2, -1, 0.5)

      for _, normal in { wall, slope } do
        const right, up, look = impacts.axes(normal, travel, "Surface")

        expect(near(up, normal)).toBe(true)
        expect(math.abs(vector.dot(look, normal)) < 1e-6).toBe(true)
        expect(frameHolds(right, up, look)).toBe(true)
      end
    end)

    test("travel along the normal gives no NaN", function()
      for _, facing in { "Surface", "Bolt", "Upright" } do
        for _, normal in { UP, -UP, vector.create(1, 0, 0) } do
          const right, up, look = impacts.axes(normal, normal * 3, facing)

          expect(finite(right) and finite(up) and finite(look)).toBe(true)
          expect(frameHolds(right, up, look)).toBe(true)
        end
      end
    end)

    test("a long travel nearly along a slanted normal stays orthonormal", function()
      const normal = vector.normalize(vector.create(0.3, 0.9, 0.1))
      const side = vector.normalize(vector.cross(normal, UP))

      for _, length in { 1, 50, 500 } do
        for _, angle in { 0, 1e-4, 1e-2 } do
          const travel = (-normal * math.cos(angle) + side * math.sin(angle)) * length

          for _, facing in { "Surface", "Bolt", "Upright" } do
            const right, up, look = impacts.axes(normal, travel, facing)

            expect(finite(right) and finite(up) and finite(look)).toBe(true)
            expect(frameHolds(right, up, look, 1e-4)).toBe(true)
          end
        end
      end

      const right, up, look = impacts.axes(normal, -normal * 50 + vector.create(1e-5, 0, 0), "Surface")

      expect(frameHolds(right, up, look, 1e-4)).toBe(true)
    end)

    test("Bolt looks along the travel", function()
      const travel = vector.normalize(vector.create(1, -2, 1))
      const right, up, look = impacts.axes(UP, travel, "Bolt")

      expect(near(look, travel)).toBe(true)
      expect(math.abs(vector.dot(up, travel)) < 1e-6).toBe(true)
      expect(vector.dot(up, UP) > 0).toBe(true)
      expect(frameHolds(right, up, look)).toBe(true)
    end)

    test("Upright keeps world up and flattens the travel", function()
      const right, up, look = impacts.axes(vector.create(1, 0, 0), vector.create(0, -1, 2), "Upright")

      expect(near(up, UP)).toBe(true)
      expect(near(look, vector.create(0, 0, 1))).toBe(true)
      expect(frameHolds(right, up, look)).toBe(true)
    end)

    test("cone", function()
      const down = vector.normalize(vector.create(0.2, -1, 0.1))
      const rays = impacts.cone(down, impacts.GROUND_RAYS, impacts.GROUND_CONE)

      expect(#rays).toBe(7)
      expect(near(rays[1], down)).toBe(true)

      for i = 2, #rays do
        expect(math.abs(vector.magnitude(rays[i]) - 1) < 1e-6).toBe(true)
        expect(math.abs(math.acos(vector.dot(rays[i], down)) - math.rad(35)) < 1e-5).toBe(true)
      end
    end)

    test("fan", function()
      const direction = vector.normalize(vector.create(0.6, -0.5, 0.2))
      const down = vector.create(0, -1, 0)
      const rays = impacts.fan(direction, down, impacts.LATCH_RAYS, impacts.LATCH_CONE)
      local hasDown = false

      expect(#rays).toBe(5)
      expect(near(rays[1], direction)).toBe(true)

      for _, ray in rays do
        expect(math.abs(vector.magnitude(ray) - 1) < 1e-6).toBe(true)
        expect(math.acos(math.min(1, vector.dot(ray, direction))) <= impacts.LATCH_CONE + 1e-5 or near(ray, down)).toBe(
          true
        )

        hasDown = hasDown or near(ray, down)
      end

      expect(hasDown).toBe(true)
      expect(#impacts.fan(direction, down, 1, 0.5)).toBe(1)
    end)

    test("nearest", function()
      const far = { point = vector.zero, distance = 9 }
      const close = { point = vector.zero, distance = 4 }
      const middle = { point = vector.zero, distance = 6 }

      expect(impacts.nearest({ nil, far, close, middle })).toBe(3)
      expect(impacts.nearest({})).toBe(nil)
    end)

    test("miss", function()
      const next = rng.generator(424242424)
      const down = vector.create(0, -1, 0)

      for _ = 1, 20 do
        const p = impacts.miss(down, 30, next)

        expect(math.abs(vector.magnitude(p) - 15) < 1e-5).toBe(true)
        expect(vector.dot(vector.normalize(p), down) >= math.cos(impacts.GROUND_CONE) - 1e-6).toBe(true)
      end
    end)

    test("a host is lifted off the surface along its normal", function()
      const point = vector.create(3, 9.1, -2)
      const lifted = impacts.lifted(point, vector.create(0, 2, 0))
      const slanted = impacts.lifted(point, vector.create(-0.5, 0.866, 0))

      expect(lifted).toBe(point + vector.create(0, impacts.LIFT, 0))
      expect(math.abs(vector.magnitude(slanted - point) - impacts.LIFT) < 1e-5).toBe(true)
      expect(vector.dot(slanted - point, vector.create(-0.5, 0.866, 0)) > 0).toBe(true)
    end)

    test("due answers each index once as the head passes", function()
      const arcs = { 0.2, 0.5, 0.5, 0.9 }
      const fired = { false, false, false, false }

      expect(#impacts.due(arcs, fired, 0.1)).toBe(0)
      expect(impacts.due(arcs, fired, 0.2)[1]).toBe(1)
      expect(#impacts.due(arcs, fired, 0.3)).toBe(0)
      expect(#impacts.due(arcs, fired, 0.6)).toBe(2)
      expect(#impacts.due(arcs, fired, 0.6)).toBe(0)
      expect(impacts.due(arcs, fired, 1)[1]).toBe(4)
    end)
  end)
end)
