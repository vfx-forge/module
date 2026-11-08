const Bezier = require("@obj/Bezier")
const harness = require("@tests/harness")
const knob = require("@mod/knob")
const attr = require("@mod/attributes")
const reader = require("@mod/reader")
const resize = require("@mod/resize")
const registry = require("@mod/registry")
const value_curve = require("@mod/value_curve")
const path_curve = require("@mod/common/path_curve")
const test, expect = harness.test, harness.expect
const CFrame = harness.datatypes.CFrame
const Vector3 = harness.datatypes.Vector3
const NumberRange = harness.datatypes.NumberRange

const EPSILON = 1e-4

const UP = vector.create(0, 1, 0)
const ORIGIN = vector.zero

const function near(a: any, b: any, eps: number?)
  const within = eps or EPSILON

  if type(a) == "number" then
    return math.abs(a - b) <= within
  end

  return math.abs(a.x - b.x) <= within and math.abs(a.y - b.y) <= within and math.abs(a.z - b.z) <= within
end

const function toVector(v: Vector3)
  return vector.create(v.X, v.Y, v.Z)
end

const function anchorsNear(a: { any }, b: { any })
  if #a ~= #b then
    return false
  end

  for i, anchor in a do
    const other = b[i]

    if not near(anchor.position, other.position) then
      return false
    end

    for _, side in { "left", "right" } do
      if (anchor[side] == nil) ~= (other[side] == nil) then
        return false
      end

      if anchor[side] ~= nil and not near(anchor[side], other[side]) then
        return false
      end
    end
  end

  return true
end

-- the arc-length midpoint of the default curve, placed for one spawn
const function placed(ends: any, spawn: CFrame, finish: vector?, bend: any, roll: number?)
  const curve = path_curve.DEFAULT
  const drawn = path_curve.drawn(curve)
  const bezier = Bezier.new(path_curve.points(curve))
  const frame, scale = path_curve.place(drawn, ends, spawn, finish, ORIGIN, UP, bend, roll or 0)

  return function(u: number)
    return path_curve.at(bezier, drawn, frame, scale, u)
  end, scale
end

const function many(count: number)
  const anchors = table.create(count)

  for i = 1, count do
    const anchor: any = { position = vector.create(i * 1.25, -i * 0.5, i % 7 - 3.3) }

    if i % 2 == 0 then
      anchor.left = vector.create(0.1 * i, 2.5, -1)
    end

    if i % 3 == 0 then
      anchor.right = vector.create(-0.3, 0.7 * i, 4.4)
    end

    anchors[i] = anchor
  end

  return anchors
end

const MIDDLE_LEFT = {
  { position = vector.create(0, 0, 0) },
  { position = vector.create(1.1, 2.2, -3.3), left = vector.create(0.5, 0.25, 0.1) },
  { position = vector.create(4, 5, 6) },
}

harness.suite(function()
  harness.describe("path_curve codec", function()
    test("encode then decode keeps every anchor within f32", function()
      for _, curve in { path_curve.DEFAULT, MIDDLE_LEFT, many(64) } do
        const back = path_curve.decode(path_curve.encode(curve :: any))

        expect(back ~= nil).toBe(true)
        expect(path_curve.is(back)).toBe(true)
        expect(table.isfrozen(back :: any)).toBe(true)
        expect(anchorsNear(back :: any, curve)).toBe(true)
      end
    end)

    test("encode raises on 1 anchor, 65 anchors, a NaN, and a 1e39 coordinate", function()
      const nan = { { position = vector.create(0 / 0, 0, 0) }, { position = vector.create(0, 0, -1) } }
      const huge = { { position = vector.zero }, { position = vector.create(0, 1e39, 0) } }

      for _, curve in { { { position = vector.zero } }, many(65), nan, huge } do
        expect(function()
          path_curve.encode(curve :: any)
        end).toThrow()
      end
    end)

    test(
      "decode answers nil on a wrong version byte, a short buffer, a trailing byte, mask bit 2 set, a count of 1",
      function()
        const raw = path_curve.encode(path_curve.DEFAULT)

        const function patched(at: number, byte: number)
          const buf = buffer.fromstring(raw)

          buffer.writeu8(buf, at, byte)

          return buffer.tostring(buf)
        end

        const single = buffer.create(15)

        buffer.writeu8(single, 0, path_curve.VERSION)
        buffer.writeu8(single, 1, 1)

        const nan = buffer.fromstring(raw)

        buffer.writef32(nan, 3, 0 / 0)

        expect(path_curve.decode(raw) ~= nil).toBe(true)
        expect(path_curve.decode(patched(0, path_curve.VERSION + 1))).toBe(nil)
        expect(path_curve.decode(string.sub(raw, 1, #raw - 1))).toBe(nil)
        expect(path_curve.decode(`{raw}\0`)).toBe(nil)
        expect(path_curve.decode(patched(2, bit32.bor(buffer.readu8(buffer.fromstring(raw), 2), 4)))).toBe(nil)
        expect(path_curve.decode(buffer.tostring(single))).toBe(nil)
        expect(path_curve.decode(buffer.tostring(nan))).toBe(nil)
      end
    )

    test("points orders anchor, right, next left, next with missing handles as the anchor", function()
      const a1, a2, a3 = vector.create(0, 0, 0), vector.create(5, 0, 0), vector.create(10, 0, 0)
      const points = path_curve.points({
        { position = a1, right = vector.create(1, 0, 0) },
        { position = a2, left = vector.create(-1, 1, 0) },
        { position = a3 },
      } :: any)

      expect(#points).toBe(7)
      expect(points[1] == a1).toBe(true)
      expect(points[2] == vector.create(1, 0, 0)).toBe(true)
      expect(points[3] == vector.create(4, 1, 0)).toBe(true)
      expect(points[4] == a2).toBe(true)
      expect(points[5] == a2).toBe(true)
      expect(points[6] == a3).toBe(true)
      expect(points[7] == a3).toBe(true)
    end)

    test("fromPlain refuses a position no f32 holds", function()
      const curve, problem = path_curve.fromPlain({ { position = { 0, 1e39, 0 } }, { position = { 0, 0, -10 } } })

      expect(curve).toBe(nil)
      expect(problem ~= nil).toBe(true)
    end)

    test("fromPlain refuses a missing position and a 1 anchor list; toPlain then fromPlain is identity", function()
      const missing, problem = path_curve.fromPlain({ { position = { 0, 0, 0 } }, { left = { 1, 2, 3 } } })

      expect(missing).toBe(nil)
      expect(type(problem)).toBe("string")

      const single, wrong = path_curve.fromPlain({ { position = { 0, 0, 0 } } })

      expect(single).toBe(nil)
      expect(type(wrong)).toBe("string")

      for _, curve in { path_curve.DEFAULT, path_curve.decode(path_curve.encode(MIDDLE_LEFT :: any)) } do
        const back = path_curve.fromPlain(path_curve.toPlain(curve :: any))

        expect(path_curve.is(back)).toBe(true)
        expect(path_curve.encode(back :: any)).toBe(path_curve.encode(curve :: any))
      end
    end)

    test("scaled multiplies positions and handles", function()
      const doubled = path_curve.scaled(path_curve.DEFAULT, 2)

      expect(path_curve.is(doubled)).toBe(true)
      expect(doubled[1].position == vector.zero).toBe(true)
      expect(doubled[1].right == vector.create(0, 8, -6)).toBe(true)
      expect(doubled[1].left).toBe(nil)
      expect(doubled[2].position == vector.create(0, 0, -20)).toBe(true)
      expect(doubled[2].left == vector.create(0, 8, 6)).toBe(true)
      expect(doubled[2].right).toBe(nil)
    end)
  end)

  harness.describe("path_curve placement", function()
    test("Free AsDrawn places the drawn start at the spawn and keeps the spawn rotation", function()
      const spawn = CFrame.new(1, 2, 3) * CFrame.fromOrientation(0, 1, 0)
      const curve = path_curve.DEFAULT
      const drawn = path_curve.drawn(curve)
      const frame, scale = path_curve.place(drawn, "Free", spawn, nil, ORIGIN, UP, "AsDrawn", 0)
      const bezier = Bezier.new(path_curve.points(curve))

      expect(scale).toBe(1)
      expect(near(toVector(frame.LookVector), toVector(spawn.LookVector))).toBe(true)
      expect(near(toVector(frame.UpVector), toVector(spawn.UpVector))).toBe(true)
      expect(near(path_curve.at(bezier, drawn, frame, scale, 0), toVector(spawn.Position))).toBe(true)
      expect(near(path_curve.at(bezier, drawn, frame, scale, 1), toVector(spawn * Vector3.new(0, 0, -10)))).toBe(true)
    end)

    test("Center stretches the chord onto spawn to center", function()
      const spawn = CFrame.new(0, 0, 20) * CFrame.fromOrientation(0.3, 1.2, -0.4)
      const at, scale = placed("Center", spawn, ORIGIN, "AsDrawn")

      expect(near(scale, 2)).toBe(true)
      expect(near(at(0), vector.create(0, 0, 20))).toBe(true)
      expect(near(at(1), ORIGIN)).toBe(true)
    end)

    test("Outward under Center bulges along the axis", function()
      for _, x in { 20, -20 } do
        const spawn = CFrame.new(x, 0, 0) * CFrame.fromOrientation(0.5, -0.7, 0.2)
        const at = placed("Center", spawn, ORIGIN, "Outward")

        expect(at(0.5).y > 1).toBe(true)
      end
    end)

    test("Outward under Target mirrors two sides", function()
      const target = vector.create(0, 0, -20)
      const signs = {}

      for i, x in { 5, -5 } do
        const at = placed("Target", CFrame.new(x, 0, 0), target, "Outward")
        const offset = at(0.5) - (vector.create(x, 0, 0) + target) / 2

        signs[i] = math.sign(offset.x)
        expect(math.abs(offset.x) > 0.5).toBe(true)
      end

      expect(signs[1]).toBe(1)
      expect(signs[2]).toBe(-1)
    end)

    test("Swirl turns every bulge the same way round", function()
      local way = 0

      for k = 0, 3 do
        const angle = k * math.pi / 2
        const radial = vector.create(math.cos(angle), 0, math.sin(angle))
        const start = radial * 10
        const at = placed("Center", CFrame.new(start.x, start.y, start.z), ORIGIN, "Swirl")
        const offset = at(0.5) - start / 2
        const turn = vector.dot(vector.cross(offset, radial), UP)

        expect(math.abs(turn) > 1).toBe(true)

        if way == 0 then
          way = math.sign(turn)
        end

        expect(math.sign(turn)).toBe(way)
      end
    end)

    test("Random turns the bulge by roll", function()
      const spawn = CFrame.new(0, 0, 20)
      const still = placed("Center", spawn, ORIGIN, "Random", 0)
      const turned = placed("Center", spawn, ORIGIN, "Random", math.pi)
      const middle = vector.create(0, 0, 10)
      const a, b = still(0.5) - middle, turned(0.5) - middle

      expect(vector.magnitude(a) > 1).toBe(true)
      expect(near(a, -b)).toBe(true)
    end)

    test("a coincident chord under Center places as Free", function()
      const curve = path_curve.fromPlain({
        { position = { 0, 0, 0 }, right = { 0, 4, -3 } },
        { position = { 0, 0, 0 }, left = { 3, 4, 0 } },
      }) :: any
      const drawn = path_curve.drawn(curve)
      const bezier = Bezier.new(path_curve.points(curve))
      const spawn = CFrame.new(4, 5, 6) * CFrame.fromOrientation(0.2, 0.4, 0.6)

      for _, bend in { "AsDrawn", "Outward", "Swirl", "Random" } do
        const frame, scale = path_curve.place(drawn, "Center", spawn, ORIGIN, ORIGIN, UP, bend :: any, 1)

        expect(scale).toBe(1)

        for i = 0, 10 do
          const p = path_curve.at(bezier, drawn, frame, scale, i / 10)

          for _, n in { p.x, p.y, p.z } do
            expect(n == n and math.abs(n) < math.huge).toBe(true)
          end
        end
      end
    end)

    test("a spawn on its end point gives scale 0", function()
      for _, bend in { "AsDrawn", "Outward", "Swirl", "Random" } do
        const at, scale = placed("Center", CFrame.new(0, 0, 0), ORIGIN, bend, 0.5)

        expect(scale).toBe(0)

        for i = 0, 10 do
          expect(near(at(i / 10), ORIGIN)).toBe(true)
        end
      end
    end)

    test("ending stays in the radius on the spawn's side", function()
      const rng = Random.new(11)
      const finish = vector.create(1, -2, 3)
      const spawn = vector.create(6, -1, 5)

      for _ = 1, 200 do
        const offset = path_curve.ending(rng, finish, spawn, NumberRange.new(3, 3))

        expect(near(vector.magnitude(offset), 3)).toBe(true)
        expect(vector.dot(offset, spawn - finish) >= 0).toBe(true)
      end

      expect(path_curve.ending(rng, finish, spawn, NumberRange.new(0, 0)) == vector.zero).toBe(true)
    end)

    test("trace reversed starts at the end", function()
      const at = placed("Free", CFrame.new(1, 2, 3), nil, "AsDrawn")
      const curve = path_curve.DEFAULT
      const drawn = path_curve.drawn(curve)
      const bezier = Bezier.new(path_curve.points(curve))
      const frame, scale = path_curve.place(drawn, "Free", CFrame.new(1, 2, 3), nil, ORIGIN, UP, "AsDrawn", 0)
      const out = {}
      const points = path_curve.trace(bezier, drawn, frame, scale, true, 5, out)

      expect(points).toBe(out)
      expect(#points).toBe(5)
      expect(near(points[1], at(1))).toBe(true)
      expect(near(points[3], at(0.5))).toBe(true)
      expect(near(points[5], at(0))).toBe(true)

      const forward = path_curve.trace(bezier, drawn, frame, scale, false, 3)

      expect(#forward).toBe(3)
      expect(near(forward[1], at(0))).toBe(true)
      expect(near(forward[3], at(1))).toBe(true)
    end)

    test("a NaN axis still places a finite frame", function()
      const nan = vector.create(0 / 0, 0 / 0, 0 / 0)
      const spawn = CFrame.new(5, 0, 0)

      for _, bend in { "Outward", "Swirl" } do
        const frame, scale =
          path_curve.place(path_curve.drawn(path_curve.DEFAULT), "Center", spawn, ORIGIN, ORIGIN, nan, bend, 0)

        for _, v in { frame.Position, frame.RightVector, frame.UpVector, frame.LookVector } do
          expect(v.X == v.X and v.Y == v.Y and v.Z == v.Z).toBe(true)
        end

        expect(scale == scale).toBe(true)
      end
    end)

    test("ending draws the direction first, then the distance", function()
      const finish = vector.create(0, 0, 0)
      const spawn = vector.create(0, 0, 10)
      const rng, twin = Random.new(7), Random.new(7)
      const offset = path_curve.ending(rng, finish, spawn, NumberRange.new(2, 6))

      const z = 1 - 2 * twin:NextNumber()
      const angle = 2 * math.pi * twin:NextNumber()
      const ring = math.sqrt(1 - z * z)
      local direction = vector.create(ring * math.cos(angle), ring * math.sin(angle), z)
      const distance = 2 + 4 * twin:NextNumber()

      if vector.dot(direction, spawn - finish) < 0 then
        direction = -direction
      end

      expect(near(offset, direction * distance)).toBe(true)
    end)
  end)

  -- a row's source stubbed, as lune refuses a non utf-8 attribute string
  const function readWith(stored: any, body: (path: any) -> (), on: Instance?)
    const module = {
      id = "stub",
      display = { name = "Stub" },
      classifier = "Part",
      attributes = { Route = knob(path_curve.DEFAULT):path() },
      properties = {},
    }
    const part = on or harness.make("Part")

    reader.source = function(inst: Instance)
      const map = table.clone(reader.defaultSource(inst))

      if inst == part then
        map.Route = stored
      end

      return map
    end

    const ok, err = pcall(function()
      body((reader.resolve(module :: any, { ref = part, obj = part } :: any)).Route)
    end)

    reader.source = reader.defaultSource

    if not ok then
      error(err, 0)
    end
  end

  harness.describe("path rows", function()
    test("a Path row reads its encoded string", function()
      const stored = path_curve.encode(MIDDLE_LEFT :: any)

      readWith(stored, function(read)
        expect(path_curve.is(read)).toBe(true)
        expect(anchorsNear(read, MIDDLE_LEFT)).toBe(true)
      end)
    end)

    test("an undecodable Path string reads the default and warns once", function()
      const part = harness.make("Part")
      const warnings = harness.captureWarnings(function()
        readWith("junk", function(first)
          expect(first).toBe(path_curve.DEFAULT)
        end, part)

        readWith("junk", function(second)
          expect(second).toBe(path_curve.DEFAULT)
        end, part)
      end)

      expect(#warnings).toBe(1)
    end)

    test("a :mod() Path row is refused by the registry", function()
      registry.clear()

      expect(function()
        registry.register({
          id = "pathed",
          display = { name = "Pathed", icon = "pathed", order = 10 },
          classifier = "Beam",
          attributes = { Route = knob(path_curve.DEFAULT):path():mod() },
          properties = {},
          emit = function() end,
        })
      end).toThrow()
    end)

    -- resize a mesh whose Path attribute reads stored, answering what it wrote
    const function resized(stored: string?)
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register({
        id = "forge_mesh",
        display = { name = "Mesh" },
        classifier = "Part",
        attributes = { Path = knob(path_curve.DEFAULT):path() },
        properties = {},
        emit = function() end,
      })

      const part = harness.make("Part")
      const written = {}
      const get, set = attr.get, attr.set

      attr.get = function(obj: any, name: string, default: any)
        if obj == part and name == "Path" then
          return stored
        end

        return get(obj, name, default)
      end

      attr.set = function(obj: any, name: string, v: any)
        if obj == part and name == "Path" then
          written[name] = v
          return
        end

        return set(obj, name, v)
      end

      const ok, err = pcall(resize.apply, part, 2)

      attr.get, attr.set = get, set

      if not ok then
        error(err, 0)
      end

      return written
    end

    test("resize scales a mesh's path", function()
      const back = path_curve.decode(resized(path_curve.encode(MIDDLE_LEFT :: any)).Path)

      expect(back ~= nil).toBe(true)
      expect(near((back :: any)[2].position, vector.create(2.2, 4.4, -6.6))).toBe(true)
      expect(near((back :: any)[2].left, vector.create(1, 0.5, 0.2))).toBe(true)
    end)

    test("resize writes the scaled default for an unset path", function()
      const back = path_curve.decode(resized(nil).Path)

      expect(back ~= nil).toBe(true)
      expect(near((back :: any)[2].position, vector.create(0, 0, -20))).toBe(true)
      expect(near((back :: any)[1].right, vector.create(0, 8, -6))).toBe(true)
    end)

    test("resize leaves an unreadable path string as it was", function()
      expect(resized("junk").Path).toBe(nil)
    end)

    test("ramp samples linearly", function()
      const sample = value_curve.sampler(value_curve.ramp(0, 1))

      expect(near(sample(0.25)[1], 0.25, 1e-6)).toBe(true)
      expect(near(sample(1)[1], 1, 1e-6)).toBe(true)
    end)
  end)
end)
