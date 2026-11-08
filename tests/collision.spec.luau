const harness = require("@tests/harness")

const collision_common = require("@mod/common/collision")

const test, expect = harness.test, harness.expect

const EPSILON = 1e-4

const function config(over: any)
  const base = {
    mode = "Bounce",
    bounce = 0.5,
    friction = 0.2,
    filterType = "Exclude",
    filterTag = "",
    group = "Default",
    respectCanCollide = true,
  }

  for key, value in over do
    base[key] = value
  end

  return base :: any
end

const function near(a: vector, b: vector)
  return vector.magnitude(a - b) < EPSILON
end

const UP = vector.create(0, 1, 0)

const function hitAt(normal: vector)
  return { position = vector.create(1, 2, 3), normal = normal }
end

-- stands in for RaycastParams, which lune does not have
const function fakeParams()
  return {
    AddToFilter = function(self: any, items: { any })
      for _, item in items do
        table.insert(self.added, item)
      end
    end,
    added = {},
  }
end

harness.suite(function()
  test("bounce reflects and damps", function()
    const outcome, position, velocity = collision_common.respond(config({}), vector.create(3, -10, 0), hitAt(UP))

    expect(outcome).toBe("bounce")
    expect(near(velocity, vector.create(2.4, 5, 0))).toBe(true)
    expect(near(position, vector.create(1, 2.01, 3))).toBe(true)
  end)

  test("a slow bounce stops", function()
    const outcome = collision_common.respond(config({ bounce = 0.04 }), vector.create(3, -10, 0), hitAt(UP))

    expect(outcome).toBe("stop")
  end)

  test("bounce 0 stops", function()
    const outcome, _, velocity = collision_common.respond(config({ bounce = 0 }), vector.create(3, -10, 0), hitAt(UP))

    expect(outcome).toBe("stop")
    expect(near(velocity, vector.zero)).toBe(true)
  end)

  test("kill and stop keep the hit position", function()
    const move = vector.create(0, -4, 0)

    for mode, expected in { Kill = "kill", Stop = "stop" } do
      const outcome, position = collision_common.respond(config({ mode = mode }), move, hitAt(UP))

      expect(outcome).toBe(expected)
      expect(near(position, vector.create(1, 2, 3))).toBe(true)
    end
  end)

  test("a zero normal does not produce NaN", function()
    const outcome, position, velocity =
      collision_common.respond(config({}), vector.create(3, -10, 0), hitAt(vector.zero))

    expect(outcome).toBe("stop")
    expect(position == position).toBe(true)
    expect(velocity == velocity).toBe(true)
  end)

  test("a short step casts nothing", function()
    const engine = collision_common.engine
    const original = engine.raycast
    local calls = 0

    engine.raycast = function()
      calls += 1

      return nil
    end

    const params = fakeParams() :: any
    const origin = vector.create(0, 5, 0)

    expect(collision_common.cast(params, origin, origin + vector.create(0, 0.00001, 0))).toBe(nil)
    expect(calls).toBe(0)

    collision_common.cast(params, origin, origin + vector.create(0, -1, 0))
    engine.raycast = original

    expect(calls).toBe(1)
  end)

  test("params never exclude Terrain", function()
    const engine = collision_common.engine
    const original = engine.params
    const terrain = { Name = "Terrain" }
    const made = fakeParams()

    engine.params = function()
      return made
    end

    const root, template = { Name = "root" }, { Name = "template" }

    collision_common.params(config({}), { root, template } :: any)
    engine.params = original

    for _, item in made.added do
      expect(item ~= terrain).toBe(true)
    end
  end)

  test("a filter choice reads as its type and tag, an Include naming no tag as None", function()
    expect({ collision_common.filter("None", "Spark") }).toEqual({ "Exclude", "" })
    expect({ collision_common.filter("Exclude Tag", "Spark") }).toEqual({ "Exclude", "Spark" })
    expect({ collision_common.filter("Include Tag", "Spark") }).toEqual({ "Include", "Spark" })
    expect({ collision_common.filter("Include Tag", "") }).toEqual({ "Exclude", "" })
  end)

  test("Exclude holds what the caller passed", function()
    const engine = collision_common.engine
    const original = engine.params
    const made = fakeParams()

    engine.params = function()
      return made
    end

    const root, template, parent = { Name = "root" }, { Name = "template" }, { Name = "parent" }

    collision_common.params(config({}), { root, template, parent } :: any)
    engine.params = original

    expect(#made.added).toBe(3)
    expect(made.added[1]).toBe(root)
    expect(made.added[2]).toBe(template)
    expect(made.added[3]).toBe(parent)
    expect((made :: any).FilterType).toBe(Enum.RaycastFilterType.Exclude)
  end)

  test("a fold turns the share Bounce of the part into a surface back and loses the share Friction along it", function()
    const v = vector.create(4, 6, 0)

    expect(near(collision_common.fold(v, UP, 1, 0), vector.create(4, -6, 0))).toBe(true)
    expect(near(collision_common.fold(v, UP, 0.5, 0), vector.create(4, -3, 0))).toBe(true)
    expect(near(collision_common.fold(v, UP, 1, 1), vector.create(0, -6, 0))).toBe(true)
    expect(near(collision_common.fold(v, UP, 0, 0.25), vector.create(3, 0, 0))).toBe(true)
  end)

  -- a ceiling at y 5 facing down, hit by any ray that crosses it going up
  const function ceiling(from: vector, to: vector): collision_common.Hit?
    if not (from.y < 5 and to.y >= 5) then
      return nil
    end

    return { position = from + (to - from) * ((5 - from.y) / (to.y - from.y)), normal = -UP }
  end

  const function responding(over: any)
    const own = config(over)

    return function()
      return own
    end
  end

  test("a mirror draws a path as it is until it bounces", function()
    const mirror = collision_common.mirror(vector.zero)
    const outcome, at = collision_common.step(mirror, responding({}), vector.create(1, 4, 2), 1, ceiling)

    expect(outcome).toBe("move")
    expect(at).toEqual(vector.create(1, 4, 2))
    expect(collision_common.mirrored(mirror, vector.create(7, 8, 9))).toEqual(vector.create(7, 8, 9))
  end)

  test("a step across a surface folds the rest of the path from the hit", function()
    const mirror = collision_common.mirror(vector.create(0, 4, 0))
    const told = {}
    const outcome, at = collision_common.step(
      mirror,
      responding({ bounce = 1, friction = 0 }),
      vector.create(2, 6, 0),
      1,
      ceiling,
      function(hit: vector, incoming: vector, rebound: vector)
        table.insert(told, { hit, incoming, rebound })
      end
    )

    expect(outcome).toBe("move")
    expect(near(at, vector.create(2, 3.99, 0))).toBe(true)
    expect(#told).toBe(1)
    expect(near(told[1][1], vector.create(1, 5, 0))).toBe(true)
    expect(near(told[1][2], vector.create(2, 2, 0))).toBe(true)
    expect(near(told[1][3], vector.create(2, -2, 0))).toBe(true)

    -- the rest of the path stays mirrored from the hit
    const _, later = collision_common.step(mirror, responding({}), vector.create(3, 10, 0), 1, ceiling)

    expect(near(later, vector.create(3, -0.01, 0))).toBe(true)
  end)

  test("the response is read at the share of the step the hit lands at", function()
    const mirror = collision_common.mirror(vector.create(0, 1, 0))
    local asked = -1

    collision_common.step(mirror, function(share: number)
      asked = share
      return config({})
    end, vector.create(0, 9, 0), 1, ceiling)

    expect(math.abs(asked - 0.5) < EPSILON).toBe(true)
  end)

  test("a step that meets a surface too slowly stops at the hit", function()
    const mirror = collision_common.mirror(vector.create(0, 4.9, 0))
    const outcome, at = collision_common.step(mirror, responding({}), vector.create(0, 5.1, 0), 1, ceiling)

    expect(outcome).toBe("stop")
    expect(near(at, vector.create(0, 5, 0))).toBe(true)
  end)

  test("a Bounce of 0 slides along the surface rather than stopping", function()
    const mirror = collision_common.mirror(vector.create(0, 4, 0))
    const outcome, at =
      collision_common.step(mirror, responding({ bounce = 0, friction = 0 }), vector.create(2, 6, 0), 1, ceiling)

    expect(outcome).toBe("move")
    expect(near(at, vector.create(2, 4.99, 0))).toBe(true)
  end)

  test("Kill and Stop end a step at the hit", function()
    for mode, want in { Kill = "kill", Stop = "stop" } do
      const mirror = collision_common.mirror(vector.create(0, 4, 0))
      const outcome, at = collision_common.step(mirror, responding({ mode = mode }), vector.create(0, 6, 0), 1, ceiling)

      expect(outcome).toBe(want)
      expect(near(at, vector.create(0, 5, 0))).toBe(true)
    end
  end)

  test("a step bounces again off a second surface, up to MAX_BOUNCES, and stops past it", function()
    -- a floor at y 0 under the ceiling
    const function walls(from: vector, to: vector): collision_common.Hit?
      if from.y > 0 and to.y <= 0 then
        return { position = from + (to - from) * (from.y / (from.y - to.y)), normal = UP }
      end

      return ceiling(from, to)
    end

    const mirror = collision_common.mirror(vector.create(0, 1, 0))
    local bounces = 0

    const function counted()
      bounces += 1
    end

    const outcome, at = collision_common.step(
      mirror,
      responding({ bounce = 1, friction = 0 }),
      vector.create(0, 12, 0),
      1,
      walls,
      counted
    )

    expect(outcome).toBe("move")
    expect(bounces).toBe(2)
    expect(near(at, vector.create(0, 2.02, 0))).toBe(true)

    const far, landed = collision_common.step(
      mirror,
      responding({ bounce = 1, friction = 0 }),
      vector.create(0, 1000, 0),
      1000,
      walls,
      counted
    )

    expect(far).toBe("stop")
    expect(bounces).toBe(collision_common.MAX_BOUNCES)
    expect(math.abs(landed.y) < EPSILON or math.abs(landed.y - 5) < EPSILON).toBe(true)
  end)
end)
