const harness = require("@tests/harness")
const value_curve = require("@mod/value_curve")

const orient_common = require("@mod/common/orient")
const states_common = require("@mod/common/states")

const test, expect = harness.test, harness.expect
const CFrame = harness.datatypes.CFrame
const Color3 = harness.datatypes.Color3
const Vector3 = harness.datatypes.Vector3
const ColorSequence = harness.datatypes.ColorSequence
const ColorSequenceKeypoint = harness.datatypes.ColorSequenceKeypoint

const EPSILON = 1e-4

const RED = Color3.new(1, 0, 0)
const BLUE = Color3.new(0, 0, 1)
const GREEN = Color3.new(0, 1, 0)

-- a key of literal values and handles, its handles none unless given
const function key(time: number, value: { number }, left: { vector }?, right: { vector }?, envelope: number?)
  const flat = table.create(#value, vector.zero)

  return {
    time = time,
    value = value,
    envelope = envelope or 0,
    left = left or table.clone(flat),
    right = right or table.clone(flat),
  }
end

const function curveOf(keys: { any }): value_curve.Curve
  return { channels = #keys[1].value, linked = true, keys = keys }
end

const function sequence(points: { { any } }): ColorSequence
  const keypoints = {}

  for _, p in points do
    table.insert(keypoints, ColorSequenceKeypoint.new(p[1], p[2]))
  end

  return ColorSequence.new(keypoints)
end

-- the rows a fresh template holds
const function template(): states_common.Curves
  return {
    offset = value_curve.flat(0, 3),
    turn = value_curve.flat(0, 3),
    size = value_curve.flat(1, 3),
    transparency = value_curve.flat(0, 1),
    color = sequence({ { 0, RED }, { 1, RED } }),
  }
end

-- offset rising from 0 to 10 on y over the whole life
const function rising(): value_curve.Curve
  return curveOf({ key(0, { 0, 0, 0 }), key(1, { 0, 10, 0 }) })
end

const function near(a: number, b: number)
  return math.abs(a - b) < EPSILON
end

const function nearVector(a: vector, b: vector)
  return vector.magnitude(a - b) < EPSILON
end

const function stateAt(states: { states_common.State }, time: number): states_common.State?
  for _, s in states do
    if near(s.time, time) then
      return s
    end
  end

  return nil
end

const function keysAt(curve: value_curve.Curve, time: number): { any }
  const out = {}

  for _, k in curve.keys do
    if near(k.time, time) then
      table.insert(out, k)
    end
  end

  return out
end

const function sameColor(a: Color3, b: Color3)
  return near(a.R, b.R) and near(a.G, b.G) and near(a.B, b.B)
end

const function easingAt(source: states_common.Curves, time: number)
  return (stateAt(states_common.read(source), time) :: states_common.State).easing
end

const function copyKeys(curve: value_curve.Curve): { any }
  const out = {}

  for _, k in curve.keys do
    table.insert(out, {
      time = k.time,
      value = table.clone(k.value),
      envelope = k.envelope,
      left = table.clone(k.left),
      right = table.clone(k.right),
    })
  end

  return out
end

-- a deep copy of the value rows' keys, to compare against after an apply
const function snapshot(source: states_common.Curves)
  return {
    offset = copyKeys(source.offset),
    turn = copyKeys(source.turn),
    size = copyKeys(source.size),
    transparency = copyKeys(source.transparency),
  }
end

harness.suite(function()
  harness.describe("states_common.read", function()
    test("a fresh template reads two states", function()
      const states = states_common.read(template())

      expect(#states).toBe(2)
      expect(states[1].time).toBe(0)
      expect(states[2].time).toBe(1)
      expect(states[1].easing).toBe(nil)
      expect(states[2].easing).toBe("Linear")
      expect(nearVector(states[2].size, vector.create(1, 1, 1))).toBe(true)
      expect(sameColor(states[2].color, RED)).toBe(true)
    end)

    test("states are the union of key times", function()
      const source = template()

      source.offset = rising()
      source.transparency = curveOf({ key(0.3, { 0.5 }) })

      const states = states_common.read(source)
      const mid = stateAt(states, 0.3) :: states_common.State

      expect(#states).toBe(3)
      expect(mid ~= nil).toBe(true)
      expect(mid.transparency).toBe(0.5)
      expect(nearVector(mid.offset, vector.create(0, 3, 0))).toBe(true)
    end)

    test("easing reads each preset back", function()
      for _, name in states_common.EASINGS do
        const source = template()

        source.offset = rising()

        const eased = states_common.apply(source, { { from = 1, easing = name } })

        expect(easingAt(eased, 1)).toBe(name)
      end
    end)

    test("a flat row does not vote", function()
      const source = template()

      source.offset = rising()
      source.size = curveOf({ key(0, { 1, 1, 1 }), key(1, { 1, 1, 1 }) })

      const eased = states_common.apply(source, { { from = 1, easing = "EaseIn" } })

      expect(easingAt(eased, 1)).toBe("EaseIn")
    end)

    test("disagreeing rows read Mixed", function()
      const source = template()

      source.offset = rising()
      source.transparency = curveOf({ key(0, { 0 }), key(1, { 1 }) })

      const eased = states_common.apply(source, { { from = 1, easing = "EaseIn" } })

      expect(easingAt(eased, 1)).toBe("EaseIn")

      eased.transparency = states_common.apply(source, { { from = 1, easing = "EaseOut" } }).transparency

      expect(easingAt(eased, 1)).toBe("Mixed")
    end)

    test("unknown handles read Custom", function()
      const source = template()

      source.offset = curveOf({
        key(0, { 0, 0, 0 }, nil, { vector.zero, vector.create(0.1, 7, 0), vector.zero }),
        key(1, { 0, 10, 0 }),
      })

      expect(easingAt(source, 1)).toBe("Custom")
    end)
  end)

  harness.describe("states_common.apply", function()
    test("an unchanged state writes nothing", function()
      const source = template()
      const custom = { vector.zero, vector.create(-0.2, 3, 0), vector.zero }

      source.turn = curveOf({ key(0, { 0, 0, 0 }), key(0.5, { 0, 720, 0 }, custom), key(1, { 0, 0, 0 }) })
      source.offset = curveOf({ key(0, { 0.3, 0, 0 }), key(0.5, { 1.7, 2.1, 0 }, nil, nil, 0.25) })

      const before = snapshot(source)
      const after = states_common.apply(source, { { from = 0.5 } })

      expect(after.turn.keys).toEqual(before.turn)
      expect(after.offset.keys).toEqual(before.offset)
      expect(after.size.keys).toEqual(before.size)
      expect(after.transparency.keys).toEqual(before.transparency)
      expect(after.turn ~= source.turn).toBe(true)
      expect(#after.color.Keypoints).toBe(2)
    end)

    test("a moved state moves its keys", function()
      const source = template()

      source.offset = curveOf({ key(0, { 0, 0, 0 }), key(0.5, { 0, 4, 0 }), key(1, { 0, 10, 0 }) })
      source.transparency = curveOf({ key(0, { 0 }), key(0.5, { 0.6 }) })

      const before = snapshot(source)
      const after = states_common.apply(source, { { from = 0.5, time = 0.7 } })

      expect(#keysAt(after.offset, 0.5)).toBe(0)
      expect(#keysAt(after.transparency, 0.5)).toBe(0)
      expect(keysAt(after.offset, 0.7)[1].value).toEqual({ 0, 4, 0 })
      expect(keysAt(after.transparency, 0.7)[1].value).toEqual({ 0.6 })
      expect(#keysAt(after.size, 0.7)).toBe(0)
      expect(source.offset.keys).toEqual(before.offset)
    end)

    test("a removed state takes its keys, and the color keeps its ends", function()
      const source = template()

      source.offset = curveOf({ key(0, { 0, 1, 0 }), key(0.5, { 0, 4, 0 }) })
      source.color = sequence({ { 0, RED }, { 0.5, GREEN }, { 1, BLUE } })

      const after = states_common.apply(source, { { from = 0, removed = true } })
      const keypoints = after.color.Keypoints

      expect(#keysAt(after.offset, 0)).toBe(0)
      expect(#after.offset.keys).toBe(1)
      expect(#keypoints).toBe(3)
      expect(keypoints[1].Time).toBe(0)
      expect(sameColor(keypoints[1].Value, GREEN)).toBe(true)
      expect(keypoints[3].Time).toBe(1)
      expect(sameColor(keypoints[3].Value, BLUE)).toBe(true)
    end)

    test("a row whose keys all go keeps one", function()
      const source = template()

      source.turn = curveOf({ key(0.25, { 0, 30, 0 }), key(0.5, { 0, 90, 0 }) })

      const after = states_common.apply(source, {
        { from = 0.25, removed = true },
        { from = 0.5, removed = true },
      })

      -- what the first state left read before
      expect(#after.turn.keys).toBe(1)
      expect(after.turn.keys[1].time).toBe(0)
      expect(after.turn.keys[1].value).toEqual({ 0, 30, 0 })
    end)

    test("a new state inserts only what differs", function()
      const source = template()

      source.offset = rising()
      source.size = curveOf({ key(0, { 1, 1, 1 }), key(1, { 3, 3, 3 }) })

      const after = states_common.apply(source, {
        {
          time = 0.5,
          offset = vector.create(0, 8, 0),
          turn = vector.zero,
          size = vector.create(2, 2, 2),
          transparency = 0,
          color = RED,
        },
      })

      expect(#keysAt(after.size, 0.5)).toBe(0)
      expect(#keysAt(after.turn, 0.5)).toBe(0)
      expect(#keysAt(after.transparency, 0.5)).toBe(0)
      expect(#after.color.Keypoints).toBe(2)
      expect(keysAt(after.offset, 0.5)[1].value).toEqual({ 0, 8, 0 })

      const mid = stateAt(states_common.read(after), 0.5) :: states_common.State

      expect(nearVector(mid.size, vector.create(2, 2, 2))).toBe(true)
    end)

    test("two states at one time collapse to the later", function()
      const source = template()
      const first = {
        time = 0.4,
        offset = vector.create(1, 1, 1),
        turn = vector.create(10, 0, 0),
        size = vector.create(2, 2, 2),
        transparency = 0.2,
        color = GREEN,
      }

      const second = {
        time = 0.40005,
        offset = vector.create(5, 5, 5),
        turn = vector.create(45, 0, 0),
        size = vector.create(4, 4, 4),
        transparency = 0.7,
        color = BLUE,
      }

      const after = states_common.apply(source, { first, second })
      const states = states_common.read(after)

      expect(#states).toBe(3)

      for _, row in { "offset", "turn", "size", "transparency" } do
        expect(#keysAt((after :: any)[row], 0.4)).toBe(1)
      end

      expect(nearVector(states[2].offset, second.offset)).toBe(true)
      expect(nearVector(states[2].turn, second.turn)).toBe(true)
      expect(nearVector(states[2].size, second.size)).toBe(true)
      expect(near(states[2].transparency, 0.7)).toBe(true)
      expect(sameColor(states[2].color, BLUE)).toBe(true)
    end)

    test("a keyed envelope survives an edit", function()
      const source = template()

      source.size = curveOf({ key(0, { 1, 1, 1 }), key(0.5, { 2, 2, 2 }, nil, nil, 0.4) })

      const after = states_common.apply(source, { { from = 0.5, size = vector.create(3, 3, 3) } })
      const edited = keysAt(after.size, 0.5)[1]

      expect(edited.value).toEqual({ 3, 3, 3 })
      expect(edited.envelope).toBe(0.4)
    end)

    test("an eased segment keeps its easing when its state moves or changes", function()
      const source = template()

      source.offset = curveOf({ key(0, { 0, 0, 0 }), key(0.5, { 0, 10, 0 }), key(1, { 0, 0, 0 }) })

      const eased = states_common.apply(source, { { from = 0.5, easing = "EaseInOut" } })
      const moved = states_common.apply(eased, { { from = 0.5, time = 0.3 } })
      const changed = states_common.apply(eased, { { from = 0.5, offset = vector.create(0, -4, 0) } })

      expect(easingAt(moved, 0.3)).toBe("EaseInOut")
      expect(easingAt(changed, 0.5)).toBe("EaseInOut")
    end)

    test("Mixed and Custom rewrite nothing", function()
      const source = template()

      source.offset = rising()

      const before = snapshot(source)

      for _, name in { states_common.MIXED, states_common.CUSTOM } do
        expect(states_common.apply(source, { { from = 1, easing = name } }).offset.keys).toEqual(before.offset)
      end
    end)

    test("a missing color end takes the nearest state's color as read", function()
      const source = template()

      source.offset = curveOf({ key(0.2, { 0, 2, 0 }) })
      source.color = sequence({ { 0, RED }, { 0.5, GREEN }, { 1, BLUE } })

      const read = (stateAt(states_common.read(source), 0.2) :: states_common.State).color
      const after = states_common.apply(source, { { from = 0, removed = true } })
      const keypoints = after.color.Keypoints

      expect(keypoints[1].Time).toBe(0)
      expect(sameColor(keypoints[1].Value, read)).toBe(true)
      expect(sameColor(keypoints[2].Value, GREEN)).toBe(true)
    end)

    test("a state set equal to its neighbor holds still", function()
      const source = template()

      source.offset = rising()

      const eased = states_common.apply(source, { { from = 1, easing = "EaseIn" } })
      const level = states_common.apply(eased, { { from = 1, offset = vector.zero } })

      source.offset = curveOf({ key(0, { 0, 0, 0 }), key(0.5, { 0, 10, 0 }), key(1, { 0, 0, 0 }) })

      const peaked = states_common.apply(source, {
        { from = 0.5, easing = "EaseIn" },
        { from = 1, easing = "EaseOut" },
      })

      const flattened = states_common.apply(peaked, { { from = 0.5, removed = true } })

      for step = 0, 20 do
        expect(near(value_curve.at(level.offset, step / 20)[2], 0)).toBe(true)
        expect(near(value_curve.at(flattened.offset, step / 20)[2], 0)).toBe(true)
      end
    end)

    test("a collapse keeps the loser's keys on rows the winner lacks", function()
      const source = template()

      source.size = curveOf({ key(0, { 1, 1, 1 }), key(1, { 3, 3, 3 }) })
      source.transparency = curveOf({ key(0, { 0 }), key(0.5, { 0.6 }) })
      source.color = sequence({ { 0, RED }, { 1, BLUE } })

      const after = states_common.apply(source, { { from = 0.5, time = 1 } })
      const last = states_common.read(after)[2]

      expect(#states_common.read(after)).toBe(2)
      expect(keysAt(after.size, 1)[1].value).toEqual({ 3, 3, 3 })
      expect(keysAt(after.transparency, 1)[1].value).toEqual({ 0.6 })
      expect(sameColor(last.color, BLUE)).toBe(true)
    end)

    test("a time within EPSILON of where a state stands writes nothing", function()
      const source = template()
      const custom = { vector.zero, vector.create(-0.2, 3, 0), vector.zero }

      source.offset = curveOf({ key(0, { 0, 0, 0 }), key(0.5, { 0, 4, 0 }, custom), key(1, { 0, 10, 0 }) })

      const before = snapshot(source)
      const after = states_common.apply(source, { { from = 0.5, time = 0.5 + 1e-6 } })

      expect(after.offset.keys).toEqual(before.offset)
    end)

    test("an easing set on a held segment survives a drag", function()
      const source = template()

      source.offset = curveOf({ key(0, { 0, 0, 0 }), key(1, { 0, 0, 0 }) })

      const eased = states_common.apply(source, { { from = 1, easing = "EaseIn" } })
      const dragged = states_common.apply(eased, { { from = 1, offset = vector.create(0, 5, 0) } })

      expect(easingAt(dragged, 1)).toBe("EaseIn")
    end)

    test("more than twenty states keeps the first nineteen and the last", function()
      const source = template()
      const edits = {}

      for i = 1, 24 do
        table.insert(edits, { time = i / 25, transparency = i / 25 })
      end

      local after

      const warnings = harness.captureWarnings(function()
        after = states_common.apply(source, edits)
      end)

      const states = states_common.read(after)

      expect(#warnings > 0).toBe(true)
      expect(#states).toBe(states_common.MAX)
      expect(states[#states].time).toBe(1)
      expect(near(states[#states - 1].time, 18 / 25)).toBe(true)
    end)

    test("the easing points are the curve presets'", function()
      const presets = {
        EaseIn = { vector.create(0.55, 0.055, 0), vector.create(0.675, 0.19, 0) },
        EaseOut = { vector.create(0.215, 0.61, 0), vector.create(0.355, 1, 0) },
        EaseInOut = { vector.create(0.645, 0.045, 0), vector.create(0.355, 1, 0) },
      }

      for name, points in presets do
        const source = template()

        source.offset = curveOf({ key(0.25, { 0, 1, 0 }), key(0.75, { 0, 3, 0 }) })

        const eased = states_common.apply(source, { { from = 0.75, easing = name } })
        const from, into = eased.offset.keys[1], eased.offset.keys[2]
        const c1 = vector.create(from.right[2].x / 0.5, from.right[2].y / 2, 0)
        const c2 = vector.create(1 + into.left[2].x / 0.5, 1 + into.left[2].y / 2, 0)

        expect(nearVector(c1, points[1])).toBe(true)
        expect(nearVector(c2, points[2])).toBe(true)
        expect(nearVector(from.right[1], vector.create(points[1].x * 0.5, 0, 0))).toBe(true)
      end
    end)
  end)

  harness.describe("states_common.pose", function()
    const BASE = CFrame.new(3, -2, 5) * CFrame.fromOrientation(0.3, -1.2, 0.4)

    test("pose and unpose round trip, turns unwrapped toward near", function()
      const offset = vector.create(1, 2, -3)
      const posed = states_common.pose(BASE, offset, vector.create(0, 350, 0))
      const back, turn = states_common.unpose(BASE, posed, vector.create(0, -10, 0))

      expect(nearVector(back, offset)).toBe(true)
      expect(near(turn.x, 0) and near(turn.z, 0)).toBe(true)
      expect(near(turn.y, -10)).toBe(true)
    end)

    test("unpose answers the turn nearest near past the pitch's reach", function()
      const turn = vector.create(120, 30, 0)
      const posed = states_common.pose(BASE, vector.zero, turn)
      const _, back = states_common.unpose(BASE, posed, vector.create(115, 380, 5))

      expect(near(back.x, 120) and near(back.y, 390) and near(back.z, 0)).toBe(true)
    end)
  end)

  harness.describe("orient_common.unsquash", function()
    test("unsquash undoes squash", function()
      const size = Vector3.new(2, 3, 4)

      for _, s in { 0.5, -0.5 } do
        const back = orient_common.unsquash(orient_common.squash(size, s), s)

        expect((back - size).Magnitude < EPSILON).toBe(true)
      end
    end)
  end)
end)
