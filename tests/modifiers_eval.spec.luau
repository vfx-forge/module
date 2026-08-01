-- modifiers and path are pure, with no game or script access, so they are
-- required directly
local modifiers = require("@mod/modifiers")
local path = require("@mod/common/path")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local UDim2 = harness.datatypes.UDim2

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

      expect(near(modifiers.evaluate(queue, 1, { duration = 1 }) :: number, 20)).ok()
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
  end)
end)
