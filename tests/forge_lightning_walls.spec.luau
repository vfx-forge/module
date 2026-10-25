const walls = require("@mod/lightning/walls")
const harness = require("@tests/harness")
const describe, test, expect = harness.describe, harness.test, harness.expect

type box = { low: vector, high: vector }

const TOLERANCE = 1e-4

const function near(a: vector, b: vector): boolean
  return vector.magnitude(a - b) < TOLERANCE
end

const function inside(p: vector, b: box): boolean
  return p.x > b.low.x and p.x < b.high.x and p.y > b.low.y and p.y < b.high.y and p.z > b.low.z and p.z < b.high.z
end

-- a ray against boxes as the engine casts it: the nearest face it enters, and nothing from inside a box, since a
-- raycast never reports the far face of a part it starts in
const function caster(boxes: { box }): (walls.cast, () -> number)
  local count = 0

  const function cast(from: vector, to: vector): (vector?, vector?)
    count += 1

    const direction = to - from
    local best = math.huge
    local bestNormal: vector? = nil

    for _, b in boxes do
      if inside(from, b) then
        continue
      end

      local enter = 0
      local leave = 1
      local normal = vector.zero
      local missed = false

      for _, axis in { "x", "y", "z" } do
        const d = (direction :: any)[axis]
        const o = (from :: any)[axis]
        const low = (b.low :: any)[axis]
        const high = (b.high :: any)[axis]

        if math.abs(d) < 1e-9 then
          if o < low or o > high then
            missed = true
          end

          continue
        end

        local t1 = (low - o) / d
        local t2 = (high - o) / d
        local face = -1

        if t1 > t2 then
          t1, t2 = t2, t1
          face = 1
        end

        if t1 > enter then
          enter = t1
          normal = vector.create(
            if axis == "x" then face else 0,
            if axis == "y" then face else 0,
            if axis == "z" then face else 0
          )
        end

        leave = math.min(leave, t2)
      end

      if not missed and enter <= leave and enter < best then
        best = enter
        bestNormal = normal
      end
    end

    if not bestNormal then
      return nil, nil
    end

    return from + direction * best, bestNormal
  end

  return cast, function()
    return count
  end
end

const function clearAll(chain: { vector }, cast: walls.cast): boolean
  for j = 1, #chain - 1 do
    if walls.blocked(cast, chain[j], chain[j + 1]) then
      return false
    end
  end

  return true
end

const function straight(from: vector, to: vector, count: number): { vector }
  const chain = {}

  for j = 1, count do
    chain[j] = from + (to - from) * ((j - 1) / (count - 1))
  end

  return chain
end

harness.suite(function()
  describe("lightning walls", function()
    test(
      "a hit within the slack of a segment's end is the surface it was laid to, and one short of it blocks",
      function()
        const cast = caster({ { low = vector.create(10, -5, -5), high = vector.create(12, 5, 5) } })

        expect(walls.blocked(cast, vector.zero, vector.create(10 + walls.END_SLACK / 2, 0, 0))).toBe(nil)

        const point, normal = walls.blocked(cast, vector.zero, vector.create(11, 0, 0))

        expect(near(point :: vector, vector.create(10, 0, 0))).toBe(true)
        expect(near(normal :: vector, vector.create(-1, 0, 0))).toBe(true)
      end
    )

    test(
      "a fork through a wall ends on it, keeping its joints, and every joint lies on the path it was clear along",
      function()
        const cast = caster({ { low = vector.create(5, -5, -5), high = vector.create(6, 5, 5) } })
        const chain = {
          vector.create(0, 0, 0),
          vector.create(2, 1, 0),
          vector.create(4, -1, 0),
          vector.create(7, 0, 0),
          vector.create(9, 1, 0),
        }
        const before = table.clone(chain)
        const point, normal = walls.trim(chain, cast)

        expect(#chain).toBe(5)
        expect(near(point :: vector, chain[5])).toBe(true)
        expect(math.abs((point :: vector).x - 5) < TOLERANCE).toBe(true)
        expect(near(normal :: vector, vector.create(-1, 0, 0))).toBe(true)
        expect(chain[1]).toBe(before[1])

        -- evenly spaced by length along the old joints 1 to 3 and on to the hit
        const legs = { before[1], before[2], before[3], point :: vector }
        local total = 0

        for k = 1, 3 do
          total += vector.magnitude(legs[k + 1] - legs[k])
        end

        for j = 2, 5 do
          local walked = 0
          local on = false

          for k = 1, 3 do
            const span = vector.magnitude(legs[k + 1] - legs[k])
            const f = vector.magnitude(chain[j] - legs[k]) / span

            if near(legs[k] + (legs[k + 1] - legs[k]) * f, chain[j]) and f <= 1 + TOLERANCE then
              on = math.abs(walked + f * span - total * (j - 1) / 4) < 1e-3
              break
            end

            walked += span
          end

          expect(`{j} {on}`).toBe(`{j} true`)
        end

        expect(clearAll(chain, cast)).toBe(true)
      end
    )

    test("a clear fork is left exactly as it was, one cast a segment", function()
      const cast, casts = caster({ { low = vector.create(50, -5, -5), high = vector.create(60, 5, 5) } })
      const chain = { vector.create(0, 0, 0), vector.create(2, 1, 0), vector.create(4, -1, 0), vector.create(6, 0, 0) }
      const before = table.clone(chain)

      expect(walls.trim(chain, cast)).toBe(nil)
      expect(chain).toEqual(before)
      expect(casts()).toBe(3)
    end)

    test("a fork that meets a wall on its first segment lies along that segment to it", function()
      const cast = caster({ { low = vector.create(1, -5, -5), high = vector.create(2, 5, 5) } })
      const chain = straight(vector.zero, vector.create(8, 0, 0), 5)

      walls.trim(chain, cast)

      for j = 1, 5 do
        expect(near(chain[j], vector.create((j - 1) / 4, 0, 0))).toBe(true)
      end
    end)

    test("a joint pushed into a wall is pulled back until no segment crosses it, and the ends stay", function()
      const cast = caster({ { low = vector.create(3, 2, -5), high = vector.create(7, 6, 5) } })
      const chain = straight(vector.zero, vector.create(10, 0, 0), 6)

      chain[3] = chain[3] + vector.create(0, 3, 0)
      chain[4] = chain[4] + vector.create(0, -1, 0)

      const first = chain[1]
      const last = chain[6]

      expect(clearAll(chain, cast)).toBe(false)
      expect(walls.pull(chain, cast, {})).toBe(true)
      expect(clearAll(chain, cast)).toBe(true)
      expect(chain[1]).toBe(first)
      expect(chain[6]).toBe(last)
      -- the joint that never crossed anything keeps its jag
      expect(near(chain[4], vector.create(6, -1, 0))).toBe(true)
      expect(chain[3].y > 0).toBe(true)
    end)

    test("the last segment pulls its near joint, so the target stays", function()
      const cast = caster({ { low = vector.create(7, 1, -5), high = vector.create(9, 4, 5) } })
      const chain = straight(vector.zero, vector.create(10, 0, 0), 4)

      chain[3] = vector.create(6.6, 3, 0)

      expect(walls.pull(chain, cast, {})).toBe(true)
      expect(chain[4]).toBe(vector.create(10, 0, 0))
      expect(clearAll(chain, cast)).toBe(true)
    end)

    test("a chord that crosses a wall has its end behind it, so the chain is left, for one cast", function()
      const cast, casts = caster({ { low = vector.create(4, -5, -5), high = vector.create(5, 5, 5) } })
      const chain = straight(vector.zero, vector.create(10, 0, 0), 5)

      chain[2] = chain[2] + vector.create(0, 1, 0)

      const before = table.clone(chain)

      expect(walls.pull(chain, cast, {})).toBe(false)
      expect(chain).toEqual(before)
      expect(casts()).toBe(1)
    end)

    test("a joint no halving clears lands on the chord, after a bounded number of casts", function()
      -- a wall over the chord's upper side only, so every halving of a high joint still crosses it
      const cast, casts = caster({ { low = vector.create(4, 0.01, -5), high = vector.create(6, 50, 5) } })
      const chain = straight(vector.zero, vector.create(10, 0, 0), 3)

      chain[2] = vector.create(5, 40, 0)

      expect(walls.pull(chain, cast, {})).toBe(true)
      expect(chain[2]).toBe(vector.create(5, 0, 0))
      expect(casts() <= 1 + 2 + walls.HALVINGS).toBe(true)
    end)

    test("a clear chain costs one cast a segment and one for the chord, and is left as it was", function()
      const cast, casts = caster({})
      const chain = straight(vector.zero, vector.create(10, 0, 0), 17)

      chain[5] = chain[5] + vector.create(0, 2, 0)

      const before = table.clone(chain)

      expect(walls.pull(chain, cast, {})).toBe(false)
      expect(chain).toEqual(before)
      expect(casts()).toBe(17)
    end)

    test("a fit between passes cuts a fork to the share the pass kept, landing where the pass's trim did", function()
      const cast = caster({ { low = vector.create(5, -5, -5), high = vector.create(6, 5, 5) } })
      const chain = {
        vector.create(0, 0, 0),
        vector.create(2, 1, 0),
        vector.create(4, -1, 0),
        vector.create(7, 0, 0),
        vector.create(9, 1, 0),
      }
      const again = table.clone(chain)
      const _, _, share = walls.trim(chain, cast)

      walls.cut(again, share :: number)

      for j = 1, 5 do
        expect(near(again[j], chain[j])).toBe(true)
      end

      const whole = table.clone(again)

      walls.cut(again, 1)

      expect(again).toEqual(whole)
    end)

    test("a fit between passes bends the main chain as the pass pulled it, casting nothing", function()
      const cast, casts = caster({ { low = vector.create(3, 2, -5), high = vector.create(7, 6, 5) } })
      const chain = straight(vector.zero, vector.create(10, 0, 0), 6)

      chain[3] += vector.create(0, 3, 0)
      chain[4] += vector.create(0, -1, 0)

      const again = table.clone(chain)
      const bends = {}

      walls.pull(chain, cast, bends)

      const spent = casts()

      expect(walls.bend(again, bends)).toBe(true)
      expect(casts()).toBe(spent)

      for j = 1, 6 do
        expect(near(again[j], chain[j])).toBe(true)
      end

      expect(walls.bend(again, {})).toBe(false)
    end)

    test("the wall clock is due once a period, at Jitter 0 every idle period, and a forced pass restarts it", function()
      const clock = walls.clock(10)

      expect(walls.due(clock, 0.05)).toBe(false)
      expect(walls.due(clock, 0.1)).toBe(true)
      expect(walls.due(clock, 0.15)).toBe(false)
      expect(walls.due(clock, 0.2)).toBe(true)

      const idle = walls.clock(0)

      expect(idle.period).toBe(walls.IDLE_PERIOD)
      expect(walls.due(idle, walls.IDLE_PERIOD / 2)).toBe(false)
      expect(walls.due(idle, walls.IDLE_PERIOD)).toBe(true)

      -- a restrike passes at once and the next unforced pass is a whole period after it
      const struck = walls.clock(10)

      expect(walls.due(struck, 0.03, true)).toBe(true)
      expect(walls.due(struck, 0.1)).toBe(false)
      expect(walls.due(struck, 0.13)).toBe(true)
    end)
  end)
end)
