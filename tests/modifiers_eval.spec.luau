-- modifiers and path are pure, with no game or script access, so they are
-- required directly
local modifiers = require("@mod/modifiers")
local path = require("@mod/common/path")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local UDim2 = harness.datatypes.UDim2
local Vector3 = harness.datatypes.Vector3

-- `Path2DControlPoint` isn't constructible under lune (`@lune/roblox` doesn't
-- expose it), but `path.serializePath` only ever reads `.Position` /
-- `.LeftTangent` / `.RightTangent` (each UDim2-shaped, which lune *does*
-- have), so a plain duck-typed table round-trips identically to a real
-- Path2DControlPoint. These are the exact control points `mod/utility.luau`
-- uses for `utility.linear_bezier` (endpoints only, zero tangents).
local function cp(x: number, y: number)
  return { Position = UDim2.fromScale(x, y), LeftTangent = UDim2.new(), RightTangent = UDim2.new() }
end
local linear = path.serializePath({ cp(0, 1), cp(1, 0) })

-- Empirically verified (scratch script, not committed): sampling this curve
-- via `path.alphaAt` gives alpha == progress to within ~1e-7 (float32
-- round-trip error) at t = 0, 0.1, 0.25, 0.5, 0.75, 0.9, 1 -- i.e. the `1 - y`
-- orientation established in mod/tween.luau *does* give identity for the
-- endpoints-only "linear" control points, so the brief's test expectations
-- (progress 0.5 -> value 5 on a 0..10 tween) hold. Assertions below use a
-- small epsilon since `Bezier:getEase` is LUT/Newton-based, not exact.
local EPSILON = 1e-4
local function near(a: number, b: number): boolean
  return math.abs(a - b) < EPSILON
end

-- Random-under-lune: confirmed absent entirely. `require("@lune/roblox")`
-- does not expose `Random` (`roblox.Random == nil`), and the bare `Random`
-- global is also absent under plain `lune run` (`Random.new(...)` errors
-- "attempt to index nil with 'new'"). `modifiers.evaluate` never constructs
-- one itself though: a randomizer's draw arrives from `ctx.draws`, made by
-- the caller once per emitted instance, so the randomizer branch is tested
-- here with plain injected numbers and no real `Random` is needed.

harness.suite(function()
  harness.describe("path.serializePath / deserializePath", function()
    test("round-trips control points (incl. tangents) fed as duck-typed tables", function()
      local points = path.deserializePath(path.serializePath({
        {
          Position = UDim2.fromScale(0, 1),
          LeftTangent = UDim2.new(),
          RightTangent = UDim2.fromScale(0.2, -0.3),
        },
        {
          Position = UDim2.fromScale(1, 0),
          LeftTangent = UDim2.fromScale(-0.4, 0.1),
          RightTangent = UDim2.new(),
        },
      }))

      -- point1 own -> right-tangent-adjusted -> left-tangent-adjusted -> point2 own
      local expected = {
        vector.create(0, 1),
        vector.create(0.2, 0.7),
        vector.create(0.6, 0.1),
        vector.create(1, 0),
      }

      expect(#points).toBe(#expected)

      local allClose = true
      for i, p in points do
        local e = expected[i]
        if not near(p.x, e.x) or not near(p.y, e.y) then
          allClose = false
        end
      end
      expect(allClose).ok()
    end)
  end)

  harness.describe("modifiers.evaluate", function()
    test("a tween with its own duration reaches its finish at that duration", function()
      local queue = {
        {
          kind = "tween",
          chain = false,
          duration = 2,
          start = { t = "lit", v = 0 },
          finish = { t = "lit", v = 10 },
          curve = linear,
        },
      }

      expect(near(modifiers.evaluate(queue, 1, { duration = 10 }) :: number, 5)).ok()
      expect(near(modifiers.evaluate(queue, 2, { duration = 10 }) :: number, 10)).ok()
      expect(near(modifiers.evaluate(queue, 4, { duration = 10 }) :: number, 10)).ok()
    end)

    test("a nil duration runs over the effect's own", function()
      local queue = {
        {
          kind = "tween",
          chain = false,
          start = { t = "lit", v = 0 },
          finish = { t = "lit", v = 10 },
          curve = linear,
        },
      }

      expect(near(modifiers.evaluate(queue, 2, { duration = 4 }) :: number, 5)).ok()
    end)

    test("chain feeds the previous output into the next start", function()
      local queue = {
        {
          kind = "tween",
          chain = false,
          duration = 1,
          start = { t = "lit", v = 0 },
          finish = { t = "lit", v = 10 },
          curve = linear,
        },
        {
          kind = "tween",
          chain = true,
          duration = 1,
          finish = { t = "lit", v = 20 },
          curve = linear,
        },
      }

      -- the second starts where the first ends, from the value it ended on
      expect(near(modifiers.evaluate(queue, 1, { duration = 2 }) :: number, 10)).ok()
      expect(near(modifiers.evaluate(queue, 1.5, { duration = 2 }) :: number, 15)).ok()
      expect(near(modifiers.evaluate(queue, 2, { duration = 2 }) :: number, 20)).ok()
    end)

    test("a base entry seeds the chain from ctx.base and contributes nothing itself", function()
      local queue = {
        {
          kind = "sequence",
          chain = false,
          start = { t = "lit", v = 0 },
          finish = { t = "lit", v = 99 },
          curve = linear,
        },
        {
          kind = "tween",
          chain = true,
          duration = 1,
          finish = { t = "lit", v = 8 },
          curve = linear,
        },
      }

      expect(near(modifiers.evaluate(queue, 0, { duration = 1, base = 4 }) :: number, 4)).ok()
      expect(near(modifiers.evaluate(queue, 1, { duration = 1, base = 4 }) :: number, 8)).ok()
    end)

    test("a base entry alone returns ctx.base untouched", function()
      local queue = { { kind = "gradient", chain = false } }

      expect(modifiers.evaluate(queue, 0.5, { duration = 1, base = "seeded" })).toBe("seeded")
    end)

    test("a randomizer reads its draw by queue index", function()
      local queue = {
        { kind = "randomizer", chain = false, start = { t = "lit", v = 0 }, finish = { t = "lit", v = 100 } },
      }

      expect(near(modifiers.evaluate(queue, 0, { duration = 1, draws = { [1] = 0.25 } }) :: number, 25)).ok()
    end)

    -- what a legacy MinSize / MaxSize pair has always meant: three independent
    -- draws, so a part comes out with its own proportions. one alpha across all
    -- three would only ever give scaled copies of one shape
    test("a randomizer between vectors draws once per component", function()
      local queue = {
        {
          kind = "randomizer",
          chain = false,
          start = { t = "lit", v = Vector3.new(0, 0, 0) },
          finish = { t = "lit", v = Vector3.new(10, 100, 1000) },
        },
      }

      local got = modifiers.evaluate(queue, 0, { duration = 1, draws = { [1] = { 0.25, 0.5, 0.75 } } })

      expect(near(got.X, 2.5)).ok()
      expect(near(got.Y, 50)).ok()
      expect(near(got.Z, 750)).ok()
    end)

    test("a component with no draw of its own takes the midpoint", function()
      local queue = {
        {
          kind = "randomizer",
          chain = false,
          start = { t = "lit", v = Vector3.new(0, 0, 0) },
          finish = { t = "lit", v = Vector3.new(10, 10, 10) },
        },
      }

      local got = modifiers.evaluate(queue, 0, { duration = 1, draws = { [1] = { 0.2 } } })

      expect(near(got.X, 2)).ok()
      expect(near(got.Y, 5)).ok()
      expect(near(got.Z, 5)).ok()
    end)

    -- a per component draw handed to a randomizer over plain numbers has no
    -- components to spend itself on, so it must not be read as one
    test("a component draw over non-vector endpoints falls back to the midpoint", function()
      local queue = {
        { kind = "randomizer", chain = false, start = { t = "lit", v = 0 }, finish = { t = "lit", v = 100 } },
      }

      expect(near(modifiers.evaluate(queue, 0, { duration = 1, draws = { [1] = { 0.25 } } }) :: number, 50)).ok()
    end)

    test("a randomizer with no draw supplied falls back to the midpoint", function()
      local queue = {
        { kind = "randomizer", chain = false, start = { t = "lit", v = 0 }, finish = { t = "lit", v = 100 } },
      }

      expect(near(modifiers.evaluate(queue, 0, { duration = 1 }) :: number, 50)).ok()
    end)

    test("an envelope deviates alpha in alpha units and clamps at both ends", function()
      local env = buffer.create(8)
      buffer.writef32(env, 0, 0.25)
      buffer.writef32(env, 4, 0.25)

      local queue = {
        {
          kind = "tween",
          chain = false,
          duration = 1,
          start = { t = "lit", v = 0 },
          finish = { t = "lit", v = 100 },
          curve = linear,
          envelope = env,
        },
      }

      expect(near(modifiers.evaluate(queue, 0.5, { duration = 1, envelope = 1 }) :: number, 75)).ok()
      expect(near(modifiers.evaluate(queue, 0.5, { duration = 1, envelope = -1 }) :: number, 25)).ok()
      expect(near(modifiers.evaluate(queue, 1, { duration = 1, envelope = 1 }) :: number, 100)).ok()
    end)

    test("discrete types snap via lerp.Other", function()
      local queue = {
        {
          kind = "tween",
          chain = false,
          duration = 1,
          start = { t = "lit", v = false },
          finish = { t = "lit", v = true },
          curve = linear,
        },
      }

      expect(modifiers.evaluate(queue, 0.2, { duration = 1 })).toBe(false)
      expect(modifiers.evaluate(queue, 0.8, { duration = 1 })).toBe(true)
    end)

    test("unknown modifier kind passes its value through unchanged", function()
      local queue = { { kind = "future_kind", chain = false, start = { t = "lit", v = 42 } } }

      expect(modifiers.evaluate(queue, 0.5, { duration = 1 })).toBe(42)
    end)

    test("empty queue returns ctx.base, which is nil when unset", function()
      expect(modifiers.evaluate({}, 0.5, { duration = 1 })).toBe(nil)
    end)

    -- a legacy RotSpeed / Part_RotSpeed / Length_Scale quad authors a
    -- NumberRange per endpoint and the effect used to draw a scalar from each
    -- one per emitted part. the draws arrive the same way a randomizer's does
    test("draw endpoints tween between the two values ctx.picks drew", function()
      local queue = {
        {
          kind = "tween",
          chain = false,
          duration = 1,
          start = { t = "draw", a = 0, b = 100 },
          finish = { t = "draw", a = 200, b = 300 },
          curve = linear,
        },
      }

      local ctx = { duration = 1, picks = { [1] = { start = 0.25, finish = 0.5 } } }

      expect(near(modifiers.evaluate(queue, 0, ctx) :: number, 25)).ok()
      expect(near(modifiers.evaluate(queue, 1, ctx) :: number, 250)).ok()
      expect(near(modifiers.evaluate(queue, 0.5, ctx) :: number, 137.5)).ok()
    end)

    test("a draw endpoint with no pick falls back to its midpoint", function()
      local queue = {
        {
          kind = "tween",
          chain = false,
          duration = 1,
          start = { t = "draw", a = 0, b = 100 },
          finish = { t = "lit", v = 0 },
          curve = linear,
        },
      }

      expect(near(modifiers.evaluate(queue, 0, { duration = 1 }) :: number, 50)).ok()
    end)

    -- picks are keyed by queue index the way draws are, so one modifier's draw
    -- can never leak into another's endpoint
    test("picks are per modifier index", function()
      local entry = function(min: number, max: number)
        return {
          kind = "tween",
          chain = false,
          duration = 1,
          start = { t = "draw", a = min, b = max },
          finish = { t = "draw", a = min, b = max },
          curve = linear,
        }
      end

      local queue = { entry(0, 10), entry(100, 200) }
      local ctx = { duration = 1, picks = { [2] = { start = 1, finish = 1 } } }

      -- entry 1 has no pick and takes its midpoint; entry 2 takes over once it
      -- starts, a second in, on the pick drawn for it
      expect(near(modifiers.evaluate(queue, 0, ctx) :: number, 5)).ok()
      expect(near(modifiers.evaluate(queue, 1, ctx) :: number, 200)).ok()
    end)

    -- the weight curve an authored randomizer endpoint carries shapes the pick
    -- before the two ends are read, which is the same shaping a randomizer
    -- entry's own draw gets
    test("a weighted draw endpoint shapes its pick through the curve", function()
      local queue = {
        {
          kind = "tween",
          chain = false,
          duration = 1,
          start = { t = "draw", a = 0, b = 100, weight = linear },
          finish = { t = "lit", v = 0 },
          curve = linear,
        },
      }

      local ctx = { duration = 1, picks = { [1] = { start = 0.25 } } }

      -- the linear control points sample as identity, so the shaped pick is the
      -- pick and the endpoint is a quarter of the way along
      expect(near(modifiers.evaluate(queue, 0, ctx) :: number, 25)).ok()
    end)
  end)

  -- a row's modifiers run one after another: each starts where the one before
  -- it ends, and after the last one the value holds on its finish
  harness.describe("modifiers.evaluate in sequence", function()
    local function lit(v: number)
      return { t = "lit", v = v }
    end

    local function tween(startV: number?, finishV: number, duration: number?, chain: boolean?)
      return {
        kind = "tween",
        chain = chain == true,
        duration = duration,
        start = if startV then lit(startV) else nil,
        finish = lit(finishV),
        curve = linear,
      }
    end

    -- the owner's example: a 4 second effect, 50 to 10 over 2 seconds, then
    -- 10 to 50 over 1, then a second holding 50
    test("plays the second tween after the first and holds its finish", function()
      local queue = { tween(50, 10, 2), tween(10, 50, 1) }
      local ctx = { duration = 4 }

      expect(near(modifiers.evaluate(queue, 0, ctx) :: number, 50)).ok()
      expect(near(modifiers.evaluate(queue, 1, ctx) :: number, 30)).ok()
      expect(near(modifiers.evaluate(queue, 2, ctx) :: number, 10)).ok()
      expect(near(modifiers.evaluate(queue, 2.5, ctx) :: number, 30)).ok()
      expect(near(modifiers.evaluate(queue, 3, ctx) :: number, 50)).ok()
      expect(near(modifiers.evaluate(queue, 3.5, ctx) :: number, 50)).ok()
      expect(near(modifiers.evaluate(queue, 4, ctx) :: number, 50)).ok()

      local _, reach = modifiers.schedule(queue, nil, 4)

      expect(reach).toBe(3)
    end)

    -- a modifier naming no duration runs out what is left of the effect after
    -- the ones before it
    test("a linked modifier runs out the time left after the ones before it", function()
      local queue = { tween(0, 10, 1), tween(10, 40) }
      local ctx = { duration = 4 }

      expect(near(modifiers.evaluate(queue, 0.5, ctx) :: number, 5)).ok()
      expect(near(modifiers.evaluate(queue, 2.5, ctx) :: number, 25)).ok()
      expect(near(modifiers.evaluate(queue, 4, ctx) :: number, 40)).ok()
    end)

    -- a randomizer naming no duration draws at its start and takes no time, so
    -- the tween after it runs right where the one before it ended: 2 to 3 s in
    -- a 4 s effect, here leaving from the draw it chains from
    test("a randomizer with no duration takes no time", function()
      local queue = {
        tween(0, 10, 2),
        { kind = "randomizer", chain = false, start = lit(100), finish = lit(200) },
        tween(nil, 0, 1, true),
      }

      local offsets, reach, _, lengths = modifiers.schedule(queue, nil, 4)

      expect((offsets :: any)[2]).toBe(2)
      expect((lengths :: any)[2]).toBe(0)
      expect((offsets :: any)[3]).toBe(2)
      expect(reach).toBe(3)

      local ctx = { duration = 4, draws = { [2] = 0.5 } }

      expect(near(modifiers.evaluate(queue, 1, ctx) :: number, 5)).ok()
      expect(near(modifiers.evaluate(queue, 2, ctx) :: number, 150)).ok()
      expect(near(modifiers.evaluate(queue, 2.5, ctx) :: number, 75)).ok()
      expect(near(modifiers.evaluate(queue, 3, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(queue, 4, ctx) :: number, 0)).ok()

      -- one that names a duration keeps it, and a lone one still spans the effect
      local timed = { kind = "randomizer", chain = false, duration = 1, start = lit(100), finish = lit(200) }
      local later = modifiers.schedule({ tween(0, 10, 2), timed, tween(0, 1, 1) }, nil, 4)

      expect((later :: any)[3]).toBe(3)
    end)

    -- a chain now reads as "carry on from where the last one left off", across
    -- every modifier in the run
    test("a chain continues from where the one before it ended", function()
      local queue = { tween(0, 10, 1), tween(nil, 20, 1, true), tween(nil, 5, 2, true) }
      local ctx = { duration = 9 }

      expect(near(modifiers.evaluate(queue, 0.5, ctx) :: number, 5)).ok()
      expect(near(modifiers.evaluate(queue, 1.5, ctx) :: number, 15)).ok()
      expect(near(modifiers.evaluate(queue, 2, ctx) :: number, 20)).ok()
      expect(near(modifiers.evaluate(queue, 3, ctx) :: number, 12.5)).ok()
      expect(near(modifiers.evaluate(queue, 4, ctx) :: number, 5)).ok()
      expect(near(modifiers.evaluate(queue, 8, ctx) :: number, 5)).ok()
    end)

    -- one that has not started yet has no say, even over a value the one
    -- before it is still moving through
    test("a modifier waiting its turn leaves the value to the one before it", function()
      local queue = { tween(0, 10, 2), tween(100, 200, 1) }
      local ctx = { duration = 9 }

      expect(near(modifiers.evaluate(queue, 1.99, ctx) :: number, 9.95)).ok()
      expect(near(modifiers.evaluate(queue, 2, ctx) :: number, 100)).ok()
    end)

    -- a legacy entry runs beside the ones before it, as it always did
    test("parallel entries keep running together", function()
      local first = tween(0, 10, 2)
      local second = tween(100, 200, 1)

      first.parallel = true
      second.parallel = true

      local ctx = { duration = 9 }

      expect(near(modifiers.evaluate({ first, second }, 0.5, ctx) :: number, 150)).ok()

      -- and one a delay holds back shows its start while it waits, over the
      -- entry before it
      local delayed = { first, { kind = "delay", chain = false, wait = lit(1) }, second }

      expect(near(modifiers.evaluate(delayed, 0.5, ctx) :: number, 100)).ok()
      expect(near(modifiers.evaluate(delayed, 1.5, ctx) :: number, 150)).ok()
    end)
  end)

  -- a delay is the one modifier that contributes no value of its own. it moves
  -- the modifiers after it along the clock, which is what an effect with an
  -- entry phase, a wait and an exit phase needs
  harness.describe("modifiers.evaluate with a delay", function()
    local function lit(v: number)
      return { t = "lit", v = v }
    end

    local function phase(startV: number?, finishV: number, chain: boolean)
      return {
        kind = "tween",
        chain = chain,
        duration = 1,
        start = if startV then { t = "lit", v = startV } else nil,
        finish = { t = "lit", v = finishV },
        curve = linear,
      }
    end

    test("holds what follows it at its start value until the wait is up", function()
      local queue = { { kind = "delay", chain = false, wait = { t = "lit", v = 1 } }, phase(0, 10, false) }

      expect(near(modifiers.evaluate(queue, 0.5, { duration = 9 }) :: number, 0)).ok()
      expect(near(modifiers.evaluate(queue, 1.5, { duration = 9 }) :: number, 5)).ok()
      expect(near(modifiers.evaluate(queue, 2, { duration = 9 }) :: number, 10)).ok()
    end)

    -- a delay waits after the modifier before it has ENDED, so its wait adds to
    -- that modifier's duration rather than counting from zero. the entry phase
    -- below runs for a second and the wait is a second, so the exit starts at 2
    test("waits after the modifier before it ends", function()
      local queue = {
        phase(0, 10, false),
        { kind = "delay", chain = false, wait = { t = "lit", v = 1 } },
        phase(nil, 20, true),
      }

      local ctx = { duration = 9 }

      expect(near(modifiers.evaluate(queue, 0.5, ctx) :: number, 5)).ok()
      expect(near(modifiers.evaluate(queue, 1.5, ctx) :: number, 10)).ok()
      expect(near(modifiers.evaluate(queue, 2, ctx) :: number, 10)).ok()
      expect(near(modifiers.evaluate(queue, 2.5, ctx) :: number, 15)).ok()
      expect(near(modifiers.evaluate(queue, 3, ctx) :: number, 20)).ok()
    end)

    -- a delay between two tweens that do not chain: the second waits out the
    -- gap on the value the first finished at, then leaves from its own start
    test("a delay between two tweens holds the first one's finish through the gap", function()
      local queue = {
        { kind = "tween", chain = false, duration = 1, start = lit(0), finish = lit(10), curve = linear },
        { kind = "delay", chain = false, wait = lit(2) },
        { kind = "tween", chain = false, duration = 1, start = lit(30), finish = lit(40), curve = linear },
      }

      local offsets, frontier = modifiers.schedule(queue, nil, 9)

      expect((offsets :: any)[3]).toBe(3)
      expect(frontier).toBe(4)

      local ctx = { duration = 9 }

      expect(near(modifiers.evaluate(queue, 1, ctx) :: number, 10)).ok()
      expect(near(modifiers.evaluate(queue, 2.9, ctx) :: number, 10)).ok()
      expect(near(modifiers.evaluate(queue, 3, ctx) :: number, 30)).ok()
      expect(near(modifiers.evaluate(queue, 3.5, ctx) :: number, 35)).ok()
      expect(near(modifiers.evaluate(queue, 5, ctx) :: number, 40)).ok()
    end)

    -- a delayed modifier that names no duration runs out what is left of the
    -- effect from where the wait put it, so it ends with the effect
    test("a delayed modifier with no duration runs out the rest of the effect", function()
      local queue = {
        { kind = "delay", chain = false, wait = { t = "lit", v = 2 } },
        { kind = "tween", chain = false, start = lit(0), finish = lit(10), curve = linear },
      }

      local ctx = { duration = 5 }

      expect(near(modifiers.evaluate(queue, 2, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(queue, 3.5, ctx) :: number, 5)).ok()
      expect(near(modifiers.evaluate(queue, 5, ctx) :: number, 10)).ok()
    end)

    -- a modifier after one naming no duration starts at the effect's end,
    -- because the one before it runs until then
    test("a modifier after a linked one starts at the effect's end", function()
      local head = { kind = "tween", chain = false, start = lit(0), finish = lit(10), curve = linear }
      local tail = { kind = "tween", chain = true, duration = 1, finish = lit(20), curve = linear }

      local offsets, reach, linked, lengths = modifiers.schedule({ head, tail }, nil, 4)

      expect((offsets :: any)[2]).toBe(4)
      expect((lengths :: any)[1]).toBe(4)
      expect(linked).toBe(1)
      expect(reach).toBe(5)

      local ctx = { duration = 4 }

      expect(near(modifiers.evaluate({ head, tail }, 2, ctx) :: number, 5)).ok()
      expect(near(modifiers.evaluate({ head, tail }, 4, ctx) :: number, 10)).ok()
      expect(near(modifiers.evaluate({ head, tail }, 4.5, ctx) :: number, 15)).ok()
    end)

    -- progressOf returns 1 outright for a duration of zero, which without the
    -- offset would step the value at elapsed 0 no matter where it was placed
    test("a zero duration steps where it was placed rather than at zero", function()
      local queue = {
        { kind = "delay", chain = false, wait = { t = "lit", v = 1 } },
        { kind = "tween", chain = false, duration = 0, start = lit(0), finish = lit(10), curve = linear },
      }

      local ctx = { duration = 9 }

      expect(modifiers.evaluate(queue, 0.5, ctx)).toBe(0)
      expect(modifiers.evaluate(queue, 1, ctx)).toBe(10)
    end)

    -- a randomizer's alpha is its draw, so nothing about it varies with time
    -- and a delay in front of it changes nothing. pinned because the delay
    -- still moves the queue's reach, so the shape is not simply a no-op
    test("a delay before a randomizer does not hold it back", function()
      local queue = {
        { kind = "delay", chain = false, wait = { t = "lit", v = 5 } },
        { kind = "randomizer", chain = false, start = lit(0), finish = lit(100) },
      }

      local ctx = { duration = 9, draws = { [2] = 0.25 } }

      expect(near(modifiers.evaluate(queue, 0, ctx) :: number, 25)).ok()
      expect(near(modifiers.evaluate(queue, 9, ctx) :: number, 25)).ok()
    end)

    test("a base entry still seeds a chain whose first real phase is delayed", function()
      local queue = {
        { kind = "sequence", chain = false },
        { kind = "delay", chain = false, wait = { t = "lit", v = 1 } },
        phase(nil, 10, true),
      }

      local ctx = { duration = 9, base = 4 }

      expect(near(modifiers.evaluate(queue, 0, ctx) :: number, 4)).ok()
      expect(near(modifiers.evaluate(queue, 1, ctx) :: number, 4)).ok()
      expect(near(modifiers.evaluate(queue, 2, ctx) :: number, 10)).ok()
    end)

    test("contributes no value of its own", function()
      local queue = { { kind = "delay", chain = false, wait = { t = "lit", v = 1 } } }

      expect(modifiers.evaluate(queue, 5, { duration = 1, base = "seeded" })).toBe("seeded")
    end)

    test("a drawn wait lands on the pick made for it", function()
      local queue = { { kind = "delay", chain = false, wait = { t = "draw", a = 0, b = 2 } }, phase(0, 10, false) }

      local ctx = { duration = 9, picks = { [1] = { wait = 0.25 } } }

      -- a draw of 0.25 across 0..2 is a wait of half a second
      expect(near(modifiers.evaluate(queue, 0.5, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(queue, 1, ctx) :: number, 5)).ok()
    end)

    -- the shape a converted shockwave wants: the wait is not the knob's own
    -- business, it is the instance's lifetime, and every knob on that instance
    -- names the same one
    test("a wait can name a value from the environment", function()
      local queue = { { kind = "delay", chain = false, wait = { t = "var", ref = "Lifetime" } }, phase(0, 10, false) }

      local ctx = { duration = 9, env = { Lifetime = 2 } }

      expect(near(modifiers.evaluate(queue, 1.5, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(queue, 2.5, ctx) :: number, 5)).ok()
      expect(near(modifiers.evaluate(queue, 3, ctx) :: number, 10)).ok()
    end)

    -- two knobs are two queues sampled independently, so a draw in each would
    -- draw twice and break them apart. one env is what holds them together
    test("two queues sharing one environment wait the same wait", function()
      local named = { { kind = "delay", chain = false, wait = { t = "var", ref = "Lifetime" } }, phase(0, 10, false) }
      local drawn = { { kind = "delay", chain = false, wait = { t = "draw", a = 0, b = 4 } }, phase(0, 10, false) }

      local env = { Lifetime = 2 }
      local a = { duration = 9, env = env }
      local b = { duration = 9, env = env }

      expect(modifiers.evaluate(named, 2.5, a)).toBe(modifiers.evaluate(named, 2.5, b))

      -- and the same two queues on separate draws do not, which is the whole
      -- reason the wait cannot just be a draw per knob
      local one = { duration = 9, picks = { [1] = { wait = 0.25 } } }
      local two = { duration = 9, picks = { [1] = { wait = 0.75 } } }

      expect(modifiers.evaluate(drawn, 2.5, one) ~= modifiers.evaluate(drawn, 2.5, two)).ok()
    end)

    -- an environment nobody supplied leaves a var at nil, which waitOf reads as
    -- no wait rather than as a reason to fail
    test("a var wait with no environment waits for nothing", function()
      local queue = { { kind = "delay", chain = false, wait = { t = "var", ref = "Lifetime" } }, phase(0, 10, false) }

      expect(near(modifiers.evaluate(queue, 0.5, { duration = 9 }) :: number, 5)).ok()
    end)

    test("an endpoint can name the environment too", function()
      local queue = {
        {
          kind = "tween",
          chain = false,
          duration = 1,
          start = { t = "var", ref = "Base" },
          finish = lit(10),
          curve = linear,
        },
      }

      expect(near(modifiers.evaluate(queue, 0, { duration = 1, env = { Base = 4 } }) :: number, 4)).ok()
      expect(near(modifiers.evaluate(queue, 0.5, { duration = 1, env = { Base = 4 } }) :: number, 7)).ok()
    end)

    test("a drawn wait with no pick takes its midpoint", function()
      local queue = { { kind = "delay", chain = false, wait = { t = "draw", a = 0, b = 2 } }, phase(0, 10, false) }

      expect(near(modifiers.evaluate(queue, 1.5, { duration = 9 }) :: number, 5)).ok()
    end)

    -- `duration` is what anyone writing a delay by hand reaches for, so it
    -- waits rather than silently doing nothing
    test("a wait spelled as a plain duration still waits", function()
      local queue = { { kind = "delay", chain = false, duration = 1 }, phase(0, 10, false) }

      expect(near(modifiers.evaluate(queue, 0.5, { duration = 9 }) :: number, 0)).ok()
      expect(near(modifiers.evaluate(queue, 1.5, { duration = 9 }) :: number, 5)).ok()
    end)

    test("delays add up", function()
      local queue = {
        { kind = "delay", chain = false, wait = { t = "lit", v = 1 } },
        { kind = "delay", chain = false, wait = { t = "lit", v = 2 } },
        phase(0, 10, false),
      }

      expect(near(modifiers.evaluate(queue, 3, { duration = 9 }) :: number, 0)).ok()
      expect(near(modifiers.evaluate(queue, 3.5, { duration = 9 }) :: number, 5)).ok()
    end)

    -- mods.sampler works the offsets out once per emitted instance and hands
    -- them over, so evaluate has no walk to do per frame. it has to USE them,
    -- which a queue whose supplied offsets disagree with its own delays pins
    test("a supplied schedule wins over walking the queue again", function()
      local queue = { { kind = "delay", chain = false, wait = { t = "lit", v = 1 } }, phase(0, 10, false) }

      local ctx = { duration = 9, offsets = { [2] = 4 } }

      expect(near(modifiers.evaluate(queue, 2, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(queue, 4.5, ctx) :: number, 5)).ok()
    end)
  end)

  -- an fps holds a modifier on each step until the next is due, so a phase moves
  -- in a countable number of jumps rather than every frame. what a stylized
  -- flipbook-looking knob wants, and what nothing else in the queue can express
  harness.describe("modifiers.evaluate at a named fps", function()
    local function phase(fps: number?)
      return {
        {
          kind = "tween",
          chain = false,
          duration = 1,
          start = { t = "lit", v = 0 },
          finish = { t = "lit", v = 100 },
          curve = linear,
          fps = fps,
        },
      }
    end

    test("holds each step until the next one is due", function()
      local queue = phase(4)
      local ctx = { duration = 1 }

      -- 4 steps per second over a second: 0, 0.25, 0.5, 0.75 and then the finish
      expect(near(modifiers.evaluate(queue, 0.1, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(queue, 0.24, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(queue, 0.25, ctx) :: number, 25)).ok()
      expect(near(modifiers.evaluate(queue, 0.49, ctx) :: number, 25)).ok()
      expect(near(modifiers.evaluate(queue, 0.5, ctx) :: number, 50)).ok()
    end)

    -- the same readings without an fps are the continuous ones, so the test
    -- above is measuring the stepping rather than the curve
    test("naming no fps moves every frame", function()
      local queue = phase(nil)
      local ctx = { duration = 1 }

      expect(near(modifiers.evaluate(queue, 0.1, ctx) :: number, 10)).ok()
      expect(near(modifiers.evaluate(queue, 0.24, ctx) :: number, 24)).ok()
      expect(near(modifiers.evaluate(queue, 0.49, ctx) :: number, 49)).ok()
    end)

    -- the whole reason the last step is exempt: 0.1s at 12fps steps once, at
    -- zero, and the next step is past the end. quantizing the finish too would
    -- leave the knob at 83% of its travel for the rest of the emit
    test("still reaches its finish when the run is not a whole number of steps", function()
      local queue = {
        {
          kind = "tween",
          chain = false,
          duration = 0.1,
          start = { t = "lit", v = 0 },
          finish = { t = "lit", v = 100 },
          curve = linear,
          fps = 12,
        },
      }

      local ctx = { duration = 0.1 }

      expect(near(modifiers.evaluate(queue, 0.05, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(queue, 0.1, ctx) :: number, 100)).ok()
      expect(near(modifiers.evaluate(queue, 0.2, ctx) :: number, 100)).ok()
    end)

    -- an fps nobody can step at is no fps at all. zero would divide the run into
    -- nothing, and a NaN or an infinity would carry straight into the floor
    test("an unusable fps is ignored rather than obeyed", function()
      local ctx = { duration = 1 }

      expect(near(modifiers.evaluate(phase(0), 0.1, ctx) :: number, 10)).ok()
      expect(near(modifiers.evaluate(phase(-4), 0.1, ctx) :: number, 10)).ok()
      expect(near(modifiers.evaluate(phase(0 / 0), 0.1, ctx) :: number, 10)).ok()
      expect(near(modifiers.evaluate(phase(math.huge), 0.1, ctx) :: number, 10)).ok()
    end)

    -- a delayed modifier steps from where the wait put it, not from zero, or
    -- every knob on an instance would step on a grid it does not share
    test("steps from where a delay placed it", function()
      local queue = {
        { kind = "delay", chain = false, wait = { t = "lit", v = 0.6 } },
        {
          kind = "tween",
          chain = false,
          duration = 1,
          start = { t = "lit", v = 0 },
          finish = { t = "lit", v = 100 },
          curve = linear,
          fps = 4,
        },
      }

      local ctx = { duration = 9 }

      -- the wait is deliberately not a whole number of steps: at 0.5 a grid
      -- measured from zero and a grid measured from the wait agree everywhere,
      -- and the test cannot tell which one ran
      expect(near(modifiers.evaluate(queue, 0.7, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(queue, 0.9, ctx) :: number, 25)).ok()
      expect(near(modifiers.evaluate(queue, 1, ctx) :: number, 25)).ok()
      expect(near(modifiers.evaluate(queue, 1.15, ctx) :: number, 50)).ok()
    end)
  end)

  -- a rate that ramps across the run, which is what "choppy at the start,
  -- smooth by the end" is. The flat grid above cannot express it: recomputing
  -- floor(elapsed * fps) as fps changes MOVES the grid, and a moved grid runs
  -- backwards
  harness.describe("modifiers.evaluate at a rate that ramps", function()
    local function ramp(from: number, to: number, shape: buffer?)
      return {
        {
          kind = "tween",
          chain = false,
          duration = 1,
          start = { t = "lit", v = 0 },
          finish = { t = "lit", v = 100 },
          curve = linear,
          fps = { from = from, to = to, curve = shape },
        },
      }
    end

    local function walk(queue: { any }, frames: number): { number }
      local out = {}

      for i = 0, frames do
        table.insert(out, modifiers.evaluate(queue, i / frames, { duration = 1 }) :: number)
      end

      return out
    end

    local function flatAt(fps: number)
      return {
        {
          kind = "tween",
          chain = false,
          duration = 1,
          start = { t = "lit", v = 0 },
          finish = { t = "lit", v = 100 },
          curve = linear,
          fps = fps,
        },
      }
    end

    local function distinct(values: { number }): number
      local n = 1

      for i = 2, #values do
        if not near(values[i], values[i - 1]) then
          n += 1
        end
      end

      return n
    end

    -- THE test. Ramping 20fps to 22fps, the flat grid reads 0.600 at elapsed
    -- 0.60 and 0.591 at 0.61, so the knob rewinds a hundredth of its travel;
    -- on a ramp that happens at every rate change, which is every frame
    test("never runs backwards", function()
      local backwards = {}

      for _, values in { walk(ramp(20, 22), 300), walk(ramp(10, 60), 300), walk(ramp(60, 10), 300) } do
        for i = 2, #values do
          if values[i] < values[i - 1] - 1e-9 then
            table.insert(backwards, `{values[i - 1]} then {values[i]}`)
          end
        end
      end

      expect(table.concat(backwards, ", ")).toBe("")
    end)

    -- and it is genuinely stepping rather than merely not-rewinding: a run of
    -- 300 frames lands on the number of steps the integral names, which for a
    -- linear 8-to-20 ramp over a second is the average of the ends
    test("holds for as many steps as the rate integrates to", function()
      expect(distinct(walk(ramp(8, 20), 300))).toBe(15)
    end)

    -- the effect this exists for. The first hold outlasts the last one, because
    -- the rate it was taken at is slower
    test("its steps get shorter as the rate climbs", function()
      local values = walk(ramp(4, 40), 600)
      local first, last, run = 0, 0, 1

      for i = 2, #values do
        if near(values[i], values[i - 1]) then
          run += 1
        else
          if first == 0 then
            first = run
          end

          last = run
          run = 1
        end
      end

      expect(first > last * 3).toBe(true)
    end)

    -- a table whose ends agree is a constant rate however it was authored, and
    -- has to read exactly like the plain number it means
    test("equal ends are the constant rate they name", function()
      local rampt = walk(ramp(12, 12), 200)
      local flat = walk(flatAt(12), 200)
      local apart = 0

      for i, v in rampt do
        if not near(v, flat[i]) then
          apart += 1
        end
      end

      expect(apart).toBe(0)

      -- and it reaches those readings by the cheap grid rather than by
      -- integrating a flat line, which is the only part of this a value can
      -- show: the two agree to the last decimal, so nothing but the phase table
      -- itself says which path ran
      table.clear(modifiers.phase_cache)
      walk(ramp(12, 12, linear), 20)

      expect(next(modifiers.phase_cache) == nil).toBe(true)
    end)

    -- `linear` is the IDENTITY alpha, so its integral is p squared over two --
    -- the very closed form the no-curve path uses instead of a table. They have
    -- to name the same number of steps.
    --
    -- Not the same VALUE at every frame, though: a sample landing within an
    -- epsilon of a boundary floors to either side of it, and the two paths reach
    -- that boundary by different arithmetic. One frame in a few hundred sits
    -- there, and on it they are a whole step apart. That is inherent to
    -- quantizing at all, not a disagreement about where the steps are
    test("a linear shape names the same steps as the closed form", function()
      local straight = walk(ramp(4, 40), 300)
      local shaped = walk(ramp(4, 40, linear), 300)
      local apart = 0

      for i, v in straight do
        if not near(v, shaped[i]) then
          apart += 1
        end
      end

      expect(distinct(shaped)).toBe(distinct(straight))
      expect(apart <= 3).toBe(true)
    end)

    -- A shape that climbs sharply INSIDE one of the table's cells, which is
    -- where the per-cell solve earns its place: the rate barely moves for most
    -- of the run and then leaps, so a cell holds a large slice of the whole
    -- integral and inverting it as a straight line puts the boundary well off.
    --
    -- Checked against ground truth rather than against the other code path.
    -- Consecutive held values are consecutive STEPS, so the integral of the rate
    -- between them is exactly one step -- and that integral is computed here on
    -- a grid 128 times finer than the one under test, from the same curve.
    test("a rate that leaps inside one cell still lands its steps", function()
      local steep = path.serializePath({
        { Position = UDim2.fromScale(0, 1), LeftTangent = UDim2.new(), RightTangent = UDim2.fromScale(0.49, 0) },
        { Position = UDim2.fromScale(1, 0), LeftTangent = UDim2.fromScale(-0.49, 0), RightTangent = UDim2.new() },
      })

      local FROM, TO, FINE = 4, 400, 4096

      -- reference: the integral of the rate from 0 to p, trapezoid on a fine
      -- grid. Nothing here touches the module's own table
      local reference = { 0 }
      local previous = modifiers.alphaFromCurve(steep, 0)

      for i = 1, FINE do
        local current = modifiers.alphaFromCurve(steep, i / FINE)

        reference[i + 1] = reference[i] + (FROM + (TO - FROM) * (previous + current) / 2) / FINE
        previous = current
      end

      local function phaseOf(p: number): number
        local pos = math.clamp(p, 0, 1) * FINE
        local i = math.min(math.floor(pos), FINE - 1)

        return reference[i + 1] + (reference[i + 2] - reference[i + 1]) * (pos - i)
      end

      -- the held values, as progress rather than as the 0..100 they drive
      local queue = ramp(FROM, TO, steep)
      local held = {}

      for i = 0, 20000 do
        local v = (modifiers.evaluate(queue, i / 20000, { duration = 1 }) :: number) / 100

        if #held == 0 or not near(v, held[#held]) then
          table.insert(held, v)
        end
      end

      -- every consecutive pair is one step apart, so one unit of phase apart.
      -- Inverting the cell linearly instead misplaces the boundaries that fall
      -- inside the leap, which is most of them
      local worst = 0

      for i = 2, #held - 1 do
        worst = math.max(worst, math.abs(phaseOf(held[i]) - phaseOf(held[i - 1]) - 1))
      end

      expect(#held > 10).toBe(true)
      expect(worst < 0.05).toBe(true)
    end)

    -- a shape that is NOT the identity does move the steps, which is the point
    -- of being able to draw one
    test("a shaped rate steps somewhere a straight ramp does not", function()
      local ease = path.serializePath({
        { Position = UDim2.fromScale(0, 1), LeftTangent = UDim2.new(), RightTangent = UDim2.fromScale(0.6, 0) },
        { Position = UDim2.fromScale(1, 0), LeftTangent = UDim2.fromScale(-0.6, 0), RightTangent = UDim2.new() },
      })

      local straight = walk(ramp(4, 40), 300)
      local shaped = walk(ramp(4, 40, ease), 300)
      local apart, worst = 0, 0

      for i, v in straight do
        local diff = math.abs(v - shaped[i])

        if not near(v, shaped[i]) then
          apart += 1
          worst = math.max(worst, diff)
        end
      end

      -- a MOVED step, not a boundary frame flooring to either side of itself:
      -- one epsilon-differing frame out of 301 would satisfy a bare apart > 0,
      -- and an ease this pronounced holds the knob a seventh of its travel away
      expect(apart > 100).toBe(true)
      expect(worst > 5).toBe(true)
    end)

    -- an end nobody can read is dropped rather than carried into the integral,
    -- and what is left is the start, which is a rate the run can be held to.
    -- A start that is no rate at all leaves nothing to step on, whatever the
    -- far end says
    test("an unusable end falls back to the rate it starts at", function()
      local ctx = { duration = 1 }

      -- 4fps holds at zero for the first quarter second
      expect(near(modifiers.evaluate(ramp(4, math.huge), 0.1, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(ramp(4, 0 / 0), 0.1, ctx) :: number, 0)).ok()

      -- a rate that ramps to a standstill is unusable too: 4fps still has the
      -- knob three quarters of the way over, where integrating a rate down to
      -- zero would strand it at under a third
      expect(near(modifiers.evaluate(ramp(4, 0), 0.9, ctx) :: number, 75)).ok()

      -- and these step nothing, because the start is what the fallback reads
      expect(near(modifiers.evaluate(ramp(0, 40), 0.1, ctx) :: number, 10)).ok()
      expect(near(modifiers.evaluate(ramp(math.huge, 40), 0.1, ctx) :: number, 10)).ok()
      expect(near(modifiers.evaluate(ramp(0 / 0, 40), 0.1, ctx) :: number, 10)).ok()
    end)

    -- 4 to 41 integrates to 22.5 steps over the second, so the run ends half a
    -- step past its last one. 4 to 40 lands on exactly 22 and cannot tell
    -- whether the last step is exempt or not
    test("still reaches its finish", function()
      expect(near(modifiers.evaluate(ramp(4, 41), 1, { duration = 1 }) :: number, 100)).ok()
    end)

    -- a curve is free to overshoot, and one shaping a tween is often MEANT to:
    -- anticipation dips below the start before it leaves. Read as a rate, an
    -- alpha of -0.13 across a 2-to-60 ramp is -5 steps per second, and a phase
    -- that falls is a floor that falls with it. Unclamped, this reads 84 at one
    -- frame and 31 at the next
    test("an overshooting shape never runs the knob backwards", function()
      local back = path.serializePath({
        { Position = UDim2.fromScale(0, 1), LeftTangent = UDim2.new(), RightTangent = UDim2.fromScale(0.3, 0.6) },
        { Position = UDim2.fromScale(1, 0), LeftTangent = UDim2.fromScale(-0.3, 0), RightTangent = UDim2.new() },
      })

      local backwards = {}

      -- a ramp that CLIMBS is the vulnerable one: a negative alpha subtracts
      -- from the near end. Falling, the same alpha overshoots the fast end and
      -- the rate stays positive, so 60-to-2 is included as the control
      for _, values in { walk(ramp(2, 60, back), 400), walk(ramp(4, 400, back), 400), walk(ramp(60, 2, back), 400) } do
        for i = 2, #values do
          if values[i] < values[i - 1] - 1e-9 then
            table.insert(backwards, `{values[i - 1]} then {values[i]}`)
          end
        end
      end

      expect(table.concat(backwards, ", ")).toBe("")

      -- and it is still stepping, rather than clamped into holding still
      expect(distinct(walk(ramp(2, 60, back), 400)) > 10).toBe(true)
    end)

    -- an endless run is nought percent through at every elapsed, and a rate has
    -- no clock to divide: floor(inf * 0) is NaN, which reads as having reached
    -- the finish, so the knob jumps to its end value and stays there
    test("an endless duration steps nothing rather than reading as arrived", function()
      local named = ramp(4, 40)
      named[1].duration = math.huge

      local lent = ramp(4, 40)
      lent[1].duration = nil

      local ctx = { duration = math.huge }

      expect(near(modifiers.evaluate(named, 0.5, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(named, 500, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(lent, 0.5, ctx) :: number, 0)).ok()
    end)

    -- a rate needs a run to spread itself over. A modifier naming no duration,
    -- in a queue lent none either, is a step function rather than a run, and
    -- there is no span for the phase to divide
    test("a rate over no duration at all steps nothing", function()
      local none = ramp(4, 40)
      none[1].duration = nil

      local ctx = { duration = 0 }

      expect(near(modifiers.evaluate(none, -1, ctx) :: number, 0)).ok()
      expect(near(modifiers.evaluate(none, 1, ctx) :: number, 100)).ok()
    end)

    -- and an elapsed that is not a number lands on no step at all. Naming a
    -- rate must not turn a clock nobody can read into an error: the phase table
    -- indexed at NaN is a nil, and the arithmetic on it throws
    test("an elapsed that is not a number reads no worse than a rate-less one", function()
      local ease = path.serializePath({
        { Position = UDim2.fromScale(0, 1), LeftTangent = UDim2.new(), RightTangent = UDim2.fromScale(0.6, 0) },
        { Position = UDim2.fromScale(1, 0), LeftTangent = UDim2.fromScale(-0.6, 0), RightTangent = UDim2.new() },
      })

      local shaped = ramp(4, 40, ease)
      shaped[1].curve = nil

      local rateless = ramp(4, 40)
      rateless[1].curve = nil
      rateless[1].fps = nil

      local ctx = { duration = 1 }
      local a = modifiers.evaluate(shaped, 0 / 0, ctx) :: number
      local b = modifiers.evaluate(rateless, 0 / 0, ctx) :: number

      expect(a ~= a and b ~= b).toBe(true)
    end)
  end)

  harness.describe("modifiers.schedule", function()
    test("reaches the far end of a delayed queue", function()
      local queue = {
        { kind = "tween", chain = false, duration = 1 },
        { kind = "delay", chain = false, wait = { t = "lit", v = 2 } },
        { kind = "tween", chain = false, duration = 0.5 },
      }

      local offsets, frontier = modifiers.schedule(queue)

      expect((offsets :: any)[1]).toBe(0)

      -- the second the entry phase runs for, then the wait
      expect((offsets :: any)[3]).toBe(3)
      expect(frontier).toBe(3.5)
    end)

    -- one after another: an offset is the durations ahead of it added up
    test("starts each modifier where the one before it ends", function()
      local queue = {
        { kind = "tween", chain = false, duration = 2 },
        { kind = "randomizer", chain = false, duration = 0.5 },
        { kind = "tween", chain = false, duration = 1 },
      }

      local offsets, frontier = modifiers.schedule(queue, nil, 9)

      expect((offsets :: any)[1]).toBe(0)
      expect((offsets :: any)[2]).toBe(2)
      expect((offsets :: any)[3]).toBe(2.5)
      expect(frontier).toBe(3.5)
    end)

    -- a modifier naming no duration takes what is left of the effect after the
    -- ones before it, and with no effect lent it takes the longest named one
    test("a linked modifier takes the effect's remaining time", function()
      local queue = {
        { kind = "tween", chain = false, duration = 1.5 },
        { kind = "tween", chain = false },
      }

      local lentOffsets, lentReach, _, lent = modifiers.schedule(queue, nil, 4)

      expect((lentOffsets :: any)[2]).toBe(1.5)
      expect((lent :: any)[2]).toBe(2.5)
      expect(lentReach).toBe(4)

      local _, bareReach, bareLinked, bare = modifiers.schedule(queue)

      expect(bareLinked).toBe(1.5)
      expect((bare :: any)[2]).toBe(1.5)
      expect(bareReach).toBe(3)
    end)

    -- the named durations can add up past the effect, and then a linked
    -- modifier after them has nothing left to run for
    test("a linked modifier past the effect's end runs for nothing", function()
      local queue = {
        { kind = "tween", chain = false, duration = 3 },
        { kind = "tween", chain = false },
      }

      local _, reach, _, lengths = modifiers.schedule(queue, nil, 2)

      expect((lengths :: any)[2]).toBe(0)
      expect(reach).toBe(3)
    end)

    -- a delay moves what follows it and never reaches backwards: the head
    -- runs out the effect whether or not a wait sits after it
    test("a delay does not re-time what runs before it", function()
      local head = { kind = "tween", chain = false }
      local tail = { kind = "tween", chain = false, duration = 1 }

      local plain, plainReach, _, plainLengths = modifiers.schedule({ head, tail }, nil, 9)
      local delayed, delayedReach, _, delayedLengths =
        modifiers.schedule({ head, { kind = "delay", chain = false, wait = { t = "lit", v = 3 } }, tail }, nil, 9)

      expect((plainLengths :: any)[1]).toBe(9)
      expect((delayedLengths :: any)[1]).toBe(9)
      expect((plain :: any)[2]).toBe(9)
      expect((delayed :: any)[3]).toBe(12)
      expect(plainReach).toBe(10)
      expect(delayedReach).toBe(13)
    end)

    -- a legacy entry keeps the reading every RayValue child had: it starts at
    -- the waits ahead of it and runs beside the entries before it
    test("a parallel entry starts at the waits ahead of it alone", function()
      local queue = {
        { kind = "tween", chain = false, parallel = true, duration = 1 },
        { kind = "delay", chain = false, wait = { t = "lit", v = 2 } },
        { kind = "tween", chain = false, parallel = true, duration = 0.5 },
        { kind = "tween", chain = false, parallel = true },
      }

      local offsets, frontier, linked, lengths = modifiers.schedule(queue, nil, 9)

      expect((offsets :: any)[3]).toBe(2)
      expect((offsets :: any)[4]).toBe(2)
      expect(linked).toBe(1)
      expect((lengths :: any)[4]).toBe(1)
      expect(frontier).toBe(3)
    end)

    -- a modifier with no duration of its own runs over the effect's, and at
    -- offset zero the effect's duration IS the reach, so it cannot extend it
    test("an undelayed modifier with no duration reaches the duration it was lent", function()
      local _, frontier, linked = modifiers.schedule({ { kind = "tween", chain = false } }, nil, 5)

      -- it runs for the lent duration starting at zero, so that is how far it
      -- reaches too. mods.span answers 5 either way, since a reach of nothing
      -- falls back to the very same number
      expect(frontier).toBe(5)
      expect(linked).toBe(5)
    end)

    -- once it starts late it can, because it still has to get a full turn
    -- before the run is over, and mods.track pumps for exactly this reach
    test("a delayed modifier with no duration reaches the end of the lent duration", function()
      local queue = {
        { kind = "delay", chain = false, wait = { t = "lit", v = 2 } },
        { kind = "tween", chain = false },
      }

      local _, frontier, _, lengths = modifiers.schedule(queue, nil, 5)

      expect((lengths :: any)[2]).toBe(3)
      expect(frontier).toBe(5)
    end)

    -- a caller that only wants the offsets lends nothing, and gets no say in
    -- the reach in exchange
    test("with nothing lent, a modifier that names no duration runs for nothing", function()
      local queue = {
        { kind = "delay", chain = false, wait = { t = "lit", v = 2 } },
        { kind = "tween", chain = false },
      }

      local offsets, frontier, linked = modifiers.schedule(queue)

      -- a caller after the offsets alone lends nothing, and then a modifier
      -- naming no duration has no run of its own: the reach is only where the
      -- delays put it
      expect((offsets :: any)[2]).toBe(2)
      expect(frontier).toBe(2)
      expect(linked).toBe(0)
    end)

    -- a queue with nothing on the clock carries no table at all, and one
    -- naming every duration carries no lengths
    test("a queue with nothing on the clock schedules nothing", function()
      local offsets, frontier = modifiers.schedule({ { kind = "sequence", chain = false } })

      expect(offsets).toBe(nil)
      expect(frontier).toBe(0)

      local _, named, _, lengths = modifiers.schedule({ { kind = "tween", chain = false, duration = 2 } })

      expect(lengths).toBe(nil)
      expect(named).toBe(2)
    end)

    -- a delay with nothing after it shifts nothing, so it must not pad the run
    -- with a wait no modifier is waiting for
    test("a delay last in the queue reaches nowhere", function()
      local queue = {
        { kind = "tween", chain = false, duration = 1 },
        { kind = "delay", chain = false, wait = { t = "lit", v = 5 } },
      }

      local _, frontier = modifiers.schedule(queue, nil, 9)

      expect(frontier).toBe(1)
    end)

    -- a base entry holds a value rather than running, so no delay moves it and
    -- it takes no offset. a duration on one still lengthened the run before
    -- delays existed, and has to keep doing so
    test("a base entry takes no offset, and its duration still reaches", function()
      local queue = {
        { kind = "sequence", chain = false, duration = 5 },
        { kind = "delay", chain = false, wait = { t = "lit", v = 1 } },
        { kind = "tween", chain = false, duration = 1 },
      }

      local offsets, frontier = modifiers.schedule(queue)

      expect((offsets :: any)[1]).toBe(nil)
      expect((offsets :: any)[3]).toBe(1)
      expect(frontier).toBe(5)
    end)
  end)

  harness.describe("modifiers.waitOf", function()
    test("prefers the wait value over a plain duration", function()
      expect(modifiers.waitOf({ kind = "delay", wait = { t = "lit", v = 2 }, duration = 9 })).toBe(2)
    end)

    test("falls back to a plain duration", function()
      expect(modifiers.waitOf({ kind = "delay", duration = 3 })).toBe(3)
    end)

    -- a var resolves to nothing in spec 1, and neither a missing wait nor a
    -- negative one may push the queue backwards
    test("waits for nothing it cannot read as a number, and never backwards", function()
      expect(modifiers.waitOf({ kind = "delay" })).toBe(0)
      expect(modifiers.waitOf({ kind = "delay", wait = { t = "var", ref = "nope" } })).toBe(0)
      expect(modifiers.waitOf({ kind = "delay", duration = -5 })).toBe(0)
    end)

    -- the wait reaches mods.span and then tween.timer, which never satisfies
    -- elapsed >= duration for either of these and so never finishes the emit.
    -- the comparison this arithmetic replaced used to reject them for free
    test("refuses a wait that is not finite", function()
      expect(modifiers.waitOf({ kind = "delay", wait = { t = "lit", v = 0 / 0 } })).toBe(0)
      expect(modifiers.waitOf({ kind = "delay", wait = { t = "lit", v = math.huge } })).toBe(0)
      expect(modifiers.waitOf({ kind = "delay", duration = math.huge })).toBe(0)
    end)
  end)
end)
