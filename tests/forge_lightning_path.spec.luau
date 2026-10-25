const rng = require("@mod/lightning/rng")
const path = require("@mod/lightning/path")
const harness = require("@tests/harness")
const describe, test, expect = harness.describe, harness.test, harness.expect

const ORIGIN = vector.create(1, 2, 3)
const FINISH = vector.create(9, -4, 20)

const function spec(detail: number, forks: number)
  return { detail = detail, forks = forks, forkLength = 0.5, jagged = 0.15 }
end

const function finite(p: vector): boolean
  return p.x == p.x
    and p.y == p.y
    and p.z == p.z
    and math.abs(p.x) < 1e9
    and math.abs(p.y) < 1e9
    and math.abs(p.z) < 1e9
end

const function sameVectors(a: { { vector } }, b: { { vector } }): boolean
  if #a ~= #b then
    return false
  end

  for c, chain in a do
    if #chain ~= #b[c] then
      return false
    end

    for j, p in chain do
      if p ~= b[c][j] then
        return false
      end
    end
  end

  return true
end

harness.suite(function()
  describe("path", function()
    test("the main chain runs exactly from origin to end", function()
      local exact = true

      for seed = 1, 50 do
        const shape = path.make(rng.generator(seed * 7919 + 100003), spec(12, 3))
        const fitted = path.fit(shape, ORIGIN, FINISH)

        if fitted[1][1] ~= ORIGIN or fitted[1][#fitted[1]] ~= FINISH then
          exact = false
        end
      end

      expect(exact).toBe(true)
    end)

    test("displacement is zero at the ends and bounded by Jagged", function()
      const length = vector.magnitude(FINISH - ORIGIN)
      const axis = (FINISH - ORIGIN) / length
      local bounded = true
      local ends = true

      for seed = 1, 50 do
        const shape = path.make(rng.generator(seed * 7919 + 100003), spec(16, 2))
        const fitted = path.fit(shape, ORIGIN, FINISH)

        for c, chain in shape.offsets do
          if chain[1] ~= vector.zero or chain[#chain] ~= vector.zero then
            ends = false
          end

          if c == 1 then
            for _, p in fitted[1] do
              const rel = p - ORIGIN
              const side = rel - axis * vector.dot(rel, axis)

              if vector.magnitude(side) > 0.15 * length * 1.0001 then
                bounded = false
              end
            end
          end
        end
      end

      expect(ends).toBe(true)
      expect(bounded).toBe(true)
    end)

    test("Detail sets the segments", function()
      const shape = path.make(rng.generator(123457), spec(10, 3))
      const fitted = path.fit(shape, ORIGIN, FINISH)

      expect(#fitted[1]).toBe(11)
      expect(shape.forkDetail).toBe(5)
      expect(#fitted).toBe(4)

      for c = 2, #fitted do
        expect(#fitted[c]).toBe(6)
      end

      expect(path.make(rng.generator(5), spec(2, 1)).forkDetail).toBe(2)
    end)

    test("forks leave from the middle", function()
      local inside = true

      for seed = 1, 30 do
        const shape = path.make(rng.generator(seed * 104729 + 7), spec(10, 6))

        for _, fork in shape.forks do
          if fork.root < 3 or fork.root > 9 then
            inside = false
          end

          if fork.angle < path.FORK_MIN or fork.angle > path.FORK_MAX then
            inside = false
          end
        end
      end

      expect(inside).toBe(true)
    end)

    test("one seed makes one shape", function()
      const a = path.make(rng.generator(987654), spec(12, 4))
      const b = path.make(rng.generator(987654), spec(12, 4))
      local same = #a.forks == #b.forks

      for i, fork in a.forks do
        const other = b.forks[i]

        if
          fork.root ~= other.root
          or fork.angle ~= other.angle
          or fork.turn ~= other.turn
          or fork.share ~= other.share
        then
          same = false
        end
      end

      expect(same).toBe(true)
      expect(sameVectors(a.offsets, b.offsets)).toBe(true)
    end)

    test("jitter keeps the structure", function()
      const shape = path.make(rng.generator(424243), spec(12, 4))
      const before = {}

      for i, fork in shape.forks do
        before[i] = table.clone(fork)
      end

      const offsets = shape.offsets
      const first = table.clone(offsets[1])
      path.jitter(shape, rng.generator(777773), 0.15)

      local kept = true

      for i, fork in shape.forks do
        const old = before[i]

        if fork.root ~= old.root or fork.angle ~= old.angle or fork.turn ~= old.turn or fork.share ~= old.share then
          kept = false
        end
      end

      expect(kept).toBe(true)
      expect(shape.offsets).toBe(offsets)
      expect(sameVectors({ first }, { offsets[1] })).toBe(false)
    end)

    test("a fork ends at its target when it has one", function()
      const shape = path.make(rng.generator(31337), spec(12, 2))
      const target = vector.create(-5, 30, 8)
      shape.forks[1].target = target
      const fitted = path.fit(shape, ORIGIN, FINISH)

      expect(fitted[2][#fitted[2]]).toBe(target)
    end)

    test(
      "a flowed shape aimed at new ends carries its pattern over, moved with them and scaled by the new length",
      function()
        const shape = path.make(rng.generator(777), spec(12, 0))

        path.flow(shape, 0.37, 1.5, 0.15)

        const shift = vector.create(4, -3, 11)
        const first = path.fit(shape, ORIGIN, FINISH)[1]
        const moved = path.fit(shape, ORIGIN + shift, FINISH + shift)[1]
        const longer = path.fit(shape, ORIGIN, ORIGIN + (FINISH - ORIGIN) * 2)[1]
        local ok = true

        for j, p in first do
          ok = ok and vector.magnitude(moved[j] - (p + shift)) < 1e-4
          ok = ok and vector.magnitude((longer[j] - ORIGIN) - (p - ORIGIN) * 2) < 1e-4
        end

        expect(ok).toBe(true)
      end
    )

    test("forks laid again start from the main chain as it now stands, and match fit when it has not moved", function()
      const shape = path.make(rng.generator(4242), spec(12, 3))
      const fitted = path.fit(shape, ORIGIN, FINISH)
      const before = {}

      for c, chain in fitted do
        before[c] = table.clone(chain)
      end

      path.forks(shape, ORIGIN, FINISH, fitted)

      expect(sameVectors(fitted, before)).toBe(true)

      const root = shape.forks[1].root

      fitted[1][root] += vector.create(0, 2, 0)
      path.forks(shape, ORIGIN, FINISH, fitted)

      expect(fitted[2][1]).toBe(fitted[1][root])
      expect(#fitted).toBe(4)
    end)

    test("the default bolt kinks sharply", function()
      local largest = 0

      for seed = 1, 200 do
        const shape =
          path.make(rng.generator(seed * 7919 + 100003), { detail = 12, forks = 3, forkLength = 0.5, jagged = 0.1 })
        local most = 0

        for _, offset in shape.offsets[1] do
          most = math.max(most, vector.magnitude(offset))
        end

        largest += most
      end

      expect(largest / 200 > 0.05).toBe(true)
    end)

    -- a mean turn of 31 degrees a joint read as a smooth wandering tube in Studio, 40 as kinks (2026-10-24)
    test("the default bolt turns sharply at its joints", function()
      local sum = 0
      local turns = 0

      for seed = 1, 200 do
        const shape =
          path.make(rng.generator(seed * 7919 + 100003), { detail = 16, forks = 3, forkLength = 0.3, jagged = 0.1 })
        const main = path.fit(shape, vector.create(0, 20, 0), vector.zero)[1]

        for i = 2, #main - 1 do
          const into = vector.normalize(main[i] - main[i - 1])
          const out = vector.normalize(main[i + 1] - main[i])

          sum += math.deg(math.acos(math.clamp(vector.dot(into, out), -1, 1)))
          turns += 1
        end
      end

      expect(sum / turns > 36).toBe(true)
    end)

    -- the worst step of any fork joint over a millisecond of Flow, a 20 stud bolt tilted from straight down
    const function forkStep(tilt: number, jagged: number): number
      const origin = vector.create(0, 20, 0)
      const finish = origin + vector.create(math.sin(math.rad(tilt)), -math.cos(math.rad(tilt)), 0) * 20
      local worst = 0

      for seed = 1, 15 do
        const shape =
          path.make(rng.generator(seed * 104729 + 7), { detail = 16, forks = 3, forkLength = 0.3, jagged = jagged })
        local last: path.Fitted? = nil

        for step = 0, 800 do
          path.flow(shape, step * 0.001, 1, jagged)

          const fitted = path.fit(shape, origin, finish)

          if last then
            for c = 2, #fitted do
              for j, p in fitted[c] do
                worst = math.max(worst, vector.magnitude(p - last[c][j]))
              end
            end
          end

          last = {}

          for c, chain in fitted do
            (last :: path.Fitted)[c] = table.clone(chain)
          end
        end
      end

      return worst
    end

    test("flow moves every fork joint smoothly at any tilt", function()
      const rough = {}

      for _, jagged in { 0.1, 0.3 } do
        for _, tilt in { 0, 30, 45, 60 } do
          const worst = forkStep(tilt, jagged)

          if worst >= 2 * jagged then
            table.insert(rough, `tilt {tilt} jagged {jagged}: {worst}`)
          end
        end
      end

      expect(table.concat(rough, ", ")).toBe("")
    end)

    test("forks carry no dive", function()
      const shape = path.make(rng.generator(55555), spec(12, 20))
      local any = false

      for _, fork in shape.forks do
        if (fork :: any).dives ~= nil then
          any = true
        end
      end

      expect(#shape.forks).toBe(20)
      expect(any).toBe(false)
    end)

    test("flow keeps the ends exact", function()
      local exact = true

      for seed = 1, 30 do
        const shape = path.make(rng.generator(seed * 15485863 + 11), spec(12, 4))

        for step = 0, 40 do
          path.flow(shape, step * 0.37 - 3, 1.5, 0.15)

          for _, chain in shape.offsets do
            if chain[1] ~= vector.zero or chain[#chain] ~= vector.zero then
              exact = false
            end
          end
        end
      end

      expect(exact).toBe(true)
    end)

    test("flow stays within Jagged", function()
      local bounded = true

      for seed = 1, 50 do
        const shape = path.make(rng.generator(seed * 32452843 + 5), spec(16, 4))

        for step = 0, 200 do
          path.flow(shape, step * 0.05, 1, 0.15)

          for _, chain in shape.offsets do
            for _, offset in chain do
              if vector.magnitude(offset) > 0.15 * 1.0001 then
                bounded = false
              end
            end
          end
        end
      end

      expect(bounded).toBe(true)
    end)

    test("flow moves continuously", function()
      const dt = 1e-3
      local smooth = true

      for _, speed in { 1, -2 } do
        for seed = 1, 30 do
          const shape = path.make(rng.generator(seed * 49979687 + 3), spec(16, 4))

          for step = 0, 50 do
            const t = step * 0.193
            path.flow(shape, t, speed, 0.15)

            const before = {}

            for c, chain in shape.offsets do
              before[c] = table.clone(chain)
            end

            path.flow(shape, t + dt, speed, 0.15)

            for c, chain in shape.offsets do
              for j, offset in chain do
                if vector.magnitude(offset - before[c][j]) >= 0.15 * 0.05 then
                  smooth = false
                end
              end
            end
          end
        end
      end

      expect(smooth).toBe(true)
    end)

    test("flow moves with speed and holds at speed 0", function()
      const shape = path.make(rng.generator(271828), spec(12, 3))

      path.flow(shape, 0, 1, 0.15)
      const still = { table.clone(shape.offsets[1]) }
      path.flow(shape, 0.25, 1, 0.15)

      expect(sameVectors(still, { shape.offsets[1] })).toBe(false)

      path.flow(shape, 0, 0, 0.15)
      const first = {}

      for c, chain in shape.offsets do
        first[c] = table.clone(chain)
      end

      path.flow(shape, 0.25, 0, 0.15)

      expect(sameVectors(first, shape.offsets)).toBe(true)
    end)

    test("one seed flows one way", function()
      const a = path.make(rng.generator(314159), spec(12, 4))
      const b = path.make(rng.generator(314159), spec(12, 4))
      const offsets = a.offsets

      path.flow(a, 2.75, -1.25, 0.12)
      path.flow(b, 2.75, -1.25, 0.12)

      expect(a.offsets).toBe(offsets)
      expect(sameVectors(a.offsets, b.offsets)).toBe(true)
    end)

    test("a zero length path is finite", function()
      const shape = path.make(rng.generator(8675309), spec(10, 4))
      const fitted = path.fit(shape, ORIGIN, ORIGIN)
      local ok = true

      for _, chain in fitted do
        for _, p in chain do
          if not finite(p) or p ~= ORIGIN then
            ok = false
          end
        end
      end

      expect(ok).toBe(true)
    end)

    test("spread 0 is up", function()
      const up = vector.create(0, 1, 0)
      const right = vector.create(1, 0, 0)
      const look = vector.create(0, 0, -1)
      const g = rng.generator(24680135)

      expect(path.spread(up, right, look, vector.zero, g)).toBe(up)

      local within = true
      local aboutRight = true

      for _ = 1, 200 do
        const d = path.spread(up, right, look, vector.create(30, 0, 0), g)

        if math.acos(math.clamp(vector.dot(d, up), -1, 1)) > math.rad(30) + 1e-6 then
          within = false
        end

        if math.abs(vector.dot(d, right)) > 1e-6 then
          aboutRight = false
        end
      end

      expect(within).toBe(true)
      expect(aboutRight).toBe(true)
    end)

    test("Detail 2 with forks is safe", function()
      local ok = true

      for detail = 2, 3 do
        const shape = path.make(rng.generator(246813), spec(detail, 5))
        const fitted = path.fit(shape, ORIGIN, FINISH)

        if fitted[1][1] ~= ORIGIN or fitted[1][#fitted[1]] ~= FINISH then
          ok = false
        end

        for _, chain in fitted do
          for _, p in chain do
            if not finite(p) then
              ok = false
            end
          end
        end
      end

      expect(ok).toBe(true)
    end)

    test("a vertical chain is finite and exact", function()
      local ok = true

      for _, finish in { vector.create(0, 20, 0), vector.create(0, -20, 0) } do
        const shape = path.make(rng.generator(135791), spec(16, 3))
        const fitted = path.fit(shape, vector.zero, finish)

        if fitted[1][1] ~= vector.zero or fitted[1][#fitted[1]] ~= finish then
          ok = false
        end

        for _, chain in fitted do
          for _, p in chain do
            if not finite(p) then
              ok = false
            end
          end
        end

        for _, p in fitted[1] do
          if vector.magnitude(vector.create(p.x, 0, p.z)) > 0.15 * 20 * 1.0001 then
            ok = false
          end
        end
      end

      expect(ok).toBe(true)
    end)

    test("fit reuses out", function()
      const big = path.make(rng.generator(112233), spec(12, 4))
      const small = path.make(rng.generator(112233), spec(12, 2))
      const out = path.fit(big, ORIGIN, FINISH)
      const chains = table.clone(out)
      const again = path.fit(big, ORIGIN, FINISH, out)
      local same = rawequal(again, out)

      for c, chain in chains do
        if not rawequal(again[c], chain) then
          same = false
        end
      end

      const fewer = path.fit(small, ORIGIN, FINISH, out)

      expect(same).toBe(true)
      expect(rawequal(fewer, out)).toBe(true)
      expect(#out).toBe(3)
    end)

    test("refits", function()
      expect(path.refits(ORIGIN, ORIGIN + vector.create(0.005, 0, 0))).toBe(false)
      expect(path.refits(ORIGIN, ORIGIN + vector.create(0, 0.02, 0))).toBe(true)
    end)
  end)
end)
