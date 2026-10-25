const rng = require("@mod/lightning/rng")
const path = require("@mod/lightning/path")
const geometry = require("@mod/lightning/geometry")
const harness = require("@tests/harness")
const describe, test, expect = harness.describe, harness.test, harness.expect

const ORIGIN = vector.create(1, 2, 3)
const FINISH = vector.create(9, -4, 20)

const function build(seed: number, detail: number, forks: number)
  const next = rng.generator(seed * 7919 + 100003)
  const shape = path.make(next, { detail = detail, forks = forks, forkLength = 0.5, jagged = 0.15 })
  const fitted = path.fit(shape, ORIGIN, FINISH)

  return shape, fitted, next
end

const function counts(fitted: { { vector } }): ({ number }, number, number)
  const perChain = {}
  local total = 0
  local segments = 0

  for c, chain in fitted do
    perChain[c] = #chain
    total += #chain
    segments += #chain - 1
  end

  return perChain, total, segments
end

const function near(a: vector, b: vector): boolean
  return vector.magnitude(a - b) < 1e-5
end

const function finite(p: vector): boolean
  return p.x == p.x
    and p.y == p.y
    and p.z == p.z
    and math.abs(p.x) < 1e9
    and math.abs(p.y) < 1e9
    and math.abs(p.z) < 1e9
end

harness.suite(function()
  describe("geometry", function()
    test("counts", function()
      local ok = true

      for seed = 1, 20 do
        const shape, fitted = build(seed, 12, 3)
        const joints = geometry.joints(shape, fitted, 0.7, 0.3)
        const perChain, total, segments = counts(fitted)
        const out = {}
        const core = geometry.CORE
        const glow = geometry.GLOW

        ok = ok
          and #joints == total
          and geometry.tube(joints, core.sides, core.scale, out) == total * 5 + 2 * #perChain
          and geometry.tube(joints, glow.sides, glow.scale, out) == total * 6 + 2 * #perChain
          and #geometry.faces(perChain, core.sides, true) == (segments + #perChain) * core.sides * 2
          and #geometry.faces(perChain, glow.sides, true) == (segments + #perChain) * glow.sides * 2
      end

      expect(ok).toBe(true)
    end)

    test("the glow shell sits clearly outside the core and stays a sleeve", function()
      const glow = geometry.GLOW

      expect(glow.scale / geometry.CORE.scale >= 1.4).toBe(true)
      expect(glow.alpha >= 0.45 and glow.alpha < 1).toBe(true)
    end)

    test("faces stay in range and wind outward", function()
      const fitted = { { vector.create(0, 0, 0), vector.create(0, 1, 0), vector.create(0, 2, 0) } }
      const joints = geometry.joints({ forks = {} }, fitted, 1, 1)
      const verts = {}
      const count = geometry.tube(joints, 5, 0.5, verts)
      const faces = geometry.faces({ 3 }, 5, true)

      expect(count).toBe(17)
      expect(#faces).toBe(2 * 5 * 2 + 2 * 5)

      local inRange = true
      local outward = true

      for _, f in faces do
        for _, index in f do
          if index < 1 or index > count then
            inRange = false
          end
        end

        const a, b, c = verts[f[1]], verts[f[2]], verts[f[3]]
        const normal = vector.cross(b - a, c - a)
        const center = (a + b + c) / 3
        const radial = vector.create(center.x, 0, center.z)

        if f[1] > 15 or f[2] > 15 or f[3] > 15 then
          -- a cap face: its normal points away along the axis, and outward from it
          const axial = if f[3] == 16 then -1 else 1

          if normal.y * axial <= 0 or vector.dot(normal, radial) <= 0 then
            outward = false
          end
        elseif vector.dot(normal, radial) <= 0 then
          outward = false
        end
      end

      expect(inRange).toBe(true)
      expect(outward).toBe(true)
    end)

    test("topology is fixed", function()
      const shape, fitted, next = build(5, 12, 3)
      const perChain = counts(fitted)
      const before = geometry.faces(perChain, 5, true)

      path.jitter(shape, next, 0.3)

      const after = geometry.faces(counts(path.fit(shape, ORIGIN, FINISH)), 5, true)
      local same = #before == #after

      for i, f in before do
        if f[1] ~= after[i][1] or f[2] ~= after[i][2] or f[3] ~= after[i][3] then
          same = false
        end
      end

      expect(same).toBe(true)
    end)

    test("caps sit behind the first joint and past the last", function()
      const fitted = { { vector.create(0, 0, 0), vector.create(0, 1, 0), vector.create(0, 2, 0) } }
      const joints = geometry.joints({ forks = {} }, fitted, 1, 1)
      const verts = {}

      geometry.tube(joints, 5, 0.5, verts)

      expect(near(verts[16], vector.create(0, -0.25, 0))).toBe(true)
      expect(near(verts[17], vector.create(0, 2.25, 0))).toBe(true)

      const flat = geometry.joints({ forks = {} }, fitted, 0, 1)

      geometry.tube(flat, 5, 0.5, verts)

      expect(near(verts[16], vector.create(0, 0, 0))).toBe(true)
      expect(near(verts[17], vector.create(0, 2, 0))).toBe(true)
    end)

    test("two chains lay out rings then caps each", function()
      const joints = {
        { p = vector.create(0, 0, 0), t = vector.create(0, 1, 0), w = 1, fade = 1, arc = 0, chain = 1 },
        { p = vector.create(0, 1, 0), t = vector.create(0, 1, 0), w = 1, fade = 1, arc = 1, chain = 1 },
        { p = vector.create(0, 1, 0), t = vector.create(1, 0, 0), w = 1, fade = 1, arc = 1, chain = 2 },
        { p = vector.create(1, 1, 0), t = vector.create(1, 0, 0), w = 1, fade = 1, arc = 2, chain = 2 },
      }
      const verts = {}
      const count = geometry.tube(joints, 4, 1, verts)

      expect(count).toBe((2 * 4 + 2) * 2)
      expect(near(verts[9], vector.create(0, -0.5, 0))).toBe(true)
      expect(near(verts[10], vector.create(0, 1.5, 0))).toBe(true)
      expect(near(verts[19], vector.create(-0.5, 1, 0))).toBe(true)
      expect(near(verts[20], vector.create(1.5, 1, 0))).toBe(true)

      const faces = geometry.faces({ 2, 2 }, 4, true)
      local top = 0

      for _, f in faces do
        for _, index in f do
          top = math.max(top, index)
        end
      end

      expect(top).toBe(20)
    end)

    test(
      "a restarting fork starts the gradient at 0 on the same scale, and one carried on starts at its root's",
      function()
        local ok = true

        for seed = 1, 10 do
          const shape, fitted = build(seed, 12, 3)
          const joints = geometry.joints(shape, fitted, 0.7, 0.3)
          const perChain = counts(fitted)
          const verts = {}
          const carried = {}
          const restarted = {}
          local longest = 0

          for _, joint in joints do
            longest = math.max(longest, joint.arc)
          end

          geometry.tube(joints, 5, 0.5, verts)
          geometry.along(joints, 5, longest, carried)
          geometry.along(joints, 5, longest, restarted, true)

          -- the main bolt reads the same either way
          for k = 1, perChain[1] * 5 + 2 do
            ok = ok and carried[k] == restarted[k]
          end

          if not shape.forks[1] then
            continue
          end

          const forkStart = perChain[1] * 5 + 2 + 1
          const rootValue = carried[(shape.forks[1].root - 1) * 5 + 1]

          ok = ok and restarted[forkStart] == 0
          ok = ok and math.abs(carried[forkStart] - rootValue) < 1e-9

          -- every ring of the fork is shifted down by its root's value, on the bolt's own scale
          for k = forkStart, forkStart + perChain[2] * 5 - 1 do
            ok = ok and math.abs(carried[k] - rootValue - restarted[k]) < 1e-9
          end
        end

        expect(ok).toBe(true)
      end
    )

    test("u is the arc over the longest, less the chain's start when restarting, held to 0 to 1", function()
      expect(geometry.u(6, 4, 10, false)).toBe(0.6)
      expect(geometry.u(6, 4, 10, true)).toBe(0.2)
      expect(geometry.u(14, 0, 10, false)).toBe(1)
      expect(geometry.u(3, 4, 10, true)).toBe(0)
      expect(geometry.u(5, 0, 0, false)).toBe(0)
    end)

    test("along rises from the origin to the farthest tip", function()
      local ok = true

      for seed = 1, 10 do
        const shape, fitted = build(seed, 12, 3)
        const joints = geometry.joints(shape, fitted, 0.7, 0.3)
        const perChain, total = counts(fitted)
        const verts = {}
        const values = {}
        local longest = 0

        for _, joint in joints do
          longest = math.max(longest, joint.arc)
        end

        const count = geometry.tube(joints, 5, 0.5, verts)

        ok = ok and geometry.along(joints, 5, longest, values) == count and #values == count
        ok = ok and values[1] == 0 and total > 0

        local top = 0

        for _, v in values do
          ok = ok and v >= 0 and v <= 1
          top = math.max(top, v)
        end

        ok = ok and math.abs(top - 1) < 1e-9

        -- a fork starts at its root's value
        const main = perChain[1]
        const forkStart = main * 5 + 2 + 1

        if shape.forks[1] then
          ok = ok and math.abs(values[forkStart] - values[(shape.forks[1].root - 1) * 5 + 1]) < 1e-9
        end
      end

      expect(ok).toBe(true)
    end)

    test("taper and forks", function()
      local ok = true

      for seed = 1, 20 do
        const shape, fitted = build(seed, 12, 3)
        const joints = geometry.joints(shape, fitted, 0.7, 0.3)
        const main = #fitted[1]

        ok = ok and joints[1].w == 0.7 and math.abs(joints[main].w - 0.21) < 1e-9

        local at = main

        for c = 2, #fitted do
          const root = shape.forks[c - 1].root

          ok = ok and math.abs(joints[at + 1].w - 0.55 * joints[root].w) < 1e-9
          ok = ok and joints[at + 1].arc == joints[root].arc
          at += #fitted[c]
        end
      end

      expect(ok).toBe(true)
    end)

    test("the envelope", function()
      expect(geometry.envelope(2, 0)).toBe(0)
      expect(geometry.envelope(2, 0.35)).toBe(1)
      expect(geometry.envelope(1, 1)).toBe(0)
      expect(geometry.envelope(1, 0.5)).toBe(1)
    end)

    test("reveal", function()
      const shape, fitted = build(3, 12, 2)
      const joints = geometry.joints(shape, fitted, 0.7, 0.3)
      const into = {}
      const head = joints[#fitted[1]].arc / 2

      geometry.reveal(joints, head, -math.huge, into)

      local beyond = nil
      local ok = true

      for i = 1, #fitted[1] do
        if joints[i].arc > head then
          beyond = beyond or into[i].p
          ok = ok and into[i].p == beyond and into[i].w == 0
        else
          ok = ok and into[i].p == joints[i].p and into[i].w == joints[i].w
        end
      end

      expect(beyond ~= nil).toBe(true)
      expect(ok).toBe(true)

      geometry.reveal(joints, math.huge, -math.huge, into)

      for i, joint in joints do
        ok = ok and into[i].p == joint.p and into[i].w == joint.w
      end

      expect(ok).toBe(true)

      const flat = geometry.joints({ forks = {} }, { { ORIGIN, ORIGIN, ORIGIN } }, 1, 1)

      geometry.reveal(flat, 0, 0, into)

      for _, joint in into do
        ok = ok and finite(joint.p) and joint.w == joint.w
      end

      expect(ok).toBe(true)
    end)

    test("zero widths are finite", function()
      const shape, fitted = build(2, 12, 3)
      const joints = geometry.joints(shape, fitted, 0, 0.3)
      const out = {}
      local ok = true

      geometry.tube(joints, 6, 0.6, out)

      for _, p in out do
        ok = ok and finite(p)
      end

      expect(ok).toBe(true)
    end)

    test("alphas", function()
      const joints = geometry.joints({ forks = {} }, { { ORIGIN, FINISH, ORIGIN } }, 1, 1)

      joints[1].fade = 0.25
      joints[2].fade = 1
      joints[3].fade = 0.5

      const profile = { 0, 0.7, 1, 0.7, 0 }
      const out = {}
      const count = geometry.alphas(joints, profile, 0.8, out)
      local ok = count == #joints * #profile + 2 and #out == count

      for i, joint in joints do
        for k, value in profile do
          ok = ok and out[(i - 1) * #profile + k] == value * 0.8 * joint.fade
        end
      end

      expect(ok).toBe(true)
    end)

    test("alphas follow the tube's layout with cap values", function()
      const joints = {
        { p = vector.create(0, 0, 0), t = vector.create(0, 1, 0), w = 1, fade = 0.2, arc = 0, chain = 1 },
        { p = vector.create(0, 1, 0), t = vector.create(0, 1, 0), w = 1, fade = 0.9, arc = 1, chain = 1 },
        { p = vector.create(0, 1, 0), t = vector.create(1, 0, 0), w = 1, fade = 0.4, arc = 1, chain = 2 },
        { p = vector.create(1, 1, 0), t = vector.create(1, 0, 0), w = 1, fade = 0.6, arc = 2, chain = 2 },
      }
      const profile = { 0.5, 1, 0.5 }
      const verts = {}
      const out = {}
      const count = geometry.tube(joints, 3, 1, verts)

      expect(geometry.alphas(joints, profile, 2, out)).toBe(count)
      expect(#out).toBe(count)
      expect(out[7]).toBe(0.5 * 2 * 0.2)
      expect(out[8]).toBe(0.5 * 2 * 0.9)
      expect(out[15]).toBe(0.5 * 2 * 0.4)
      expect(out[16]).toBe(0.5 * 2 * 0.6)
    end)

    test("reveal hides behind the tail", function()
      const shape, fitted = build(3, 12, 2)
      const joints = geometry.joints(shape, fitted, 0.7, 0.3)
      const into = {}
      const tail = joints[#fitted[1]].arc / 2

      geometry.reveal(joints, math.huge, tail, into)

      local behind = nil
      local ok = true

      for i = 1, #fitted[1] do
        if joints[i].arc < tail then
          behind = behind or into[i].p
          ok = ok and into[i].p == behind and into[i].w == 0
        else
          ok = ok and into[i].p == joints[i].p and into[i].w == joints[i].w
        end
      end

      expect(behind ~= nil).toBe(true)
      expect(ok).toBe(true)
    end)

    test("a fork past the head is hidden", function()
      const shape, fitted = build(3, 12, 3)
      const joints = geometry.joints(shape, fitted, 0.7, 0.3)
      const into = {}
      const main = #fitted[1]

      geometry.reveal(joints, joints[shape.forks[1].root].arc - 0.01, -math.huge, into)

      local ok = true

      for i = main + 1, main + #fitted[2] do
        ok = ok and into[i].w == 0 and finite(into[i].p)
      end

      expect(ok).toBe(true)
    end)

    test("zero arcs reach the guard", function()
      const joints = geometry.joints({ forks = {} }, { { ORIGIN, ORIGIN, ORIGIN } }, 1, 1)
      const into = {}

      geometry.reveal(joints, -1, -math.huge, into)

      local ok = true

      for _, joint in into do
        ok = ok and finite(joint.p) and joint.w == 0
      end

      expect(ok).toBe(true)
    end)

    test("faces offset each chain", function()
      const faces = geometry.faces({ 3, 4, 2 }, 5, true)
      const ranges = { { 1, 17 }, { 18, 39 }, { 40, 51 } }
      local ok = #faces == (2 + 3 + 1 + 3) * 5 * 2

      for _, f in faces do
        local home = nil

        for r, range in ranges do
          if f[1] >= range[1] and f[1] <= range[2] then
            home = r
          end
        end

        for _, index in f do
          ok = ok and home ~= nil and index >= ranges[home][1] and index <= ranges[home][2]
        end
      end

      expect(ok).toBe(true)
    end)

    test("rings do not twist", function()
      const joints = {}
      const turns = { 20, 22, 24, 26, 28, 26, 24, 22, 20 }

      for i, degrees in turns do
        const angle = math.rad(degrees)
        const t = vector.create(math.sin(angle), math.cos(angle), 0)

        joints[i] = { p = vector.create(i, 0, 0), t = t, w = 1, fade = 1, arc = i, chain = 1 }
      end

      const out = {}

      geometry.tube(joints, 4, 1, out)

      local ok = true

      for i = 2, #joints do
        const before = out[(i - 2) * 4 + 1] - joints[i - 1].p
        const now = out[(i - 1) * 4 + 1] - joints[i].p
        const turned = math.acos(math.clamp(vector.dot(joints[i - 1].t, joints[i].t), -1, 1))
        const between = math.acos(math.clamp(vector.dot(before, now), -1, 1))

        ok = ok and between <= turned + 1e-3
      end

      expect(ok).toBe(true)
    end)

    test("pick lands only on a drawn joint", function()
      const shape, fitted = build(5, 12, 3)
      const joints = geometry.joints(shape, fitted, 0.7, 0.3)
      const into = {}
      const next = rng.generator(31)

      geometry.reveal(joints, joints[#fitted[1]].arc / 3, -math.huge, into)

      local ok = true
      const seen = {}

      for _ = 1, 500 do
        const index = geometry.pick(into, next)

        const joint = index and into[index]
        const before = index and into[index - 1]
        const after = index and into[index + 1]
        const beside = (before and before.chain == joint.chain and before.w > 0)
          or (after and after.chain == joint.chain and after.w > 0)

        ok = ok and joint ~= nil and joint.w > 0 and beside == true
        seen[index or 0] = true
      end

      local distinct = 0

      for _ in seen do
        distinct += 1
      end

      expect(ok).toBe(true)
      expect(distinct > 1).toBe(true)

      geometry.reveal(joints, -math.huge, -math.huge, into)

      expect(geometry.pick(into, next)).toBe(nil)

      geometry.reveal(joints, 0, -math.huge, into)

      expect(into[1].w > 0).toBe(true)
      expect(geometry.pick(into, next)).toBe(nil)
    end)
  end)
end)
