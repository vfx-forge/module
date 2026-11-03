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
end)
