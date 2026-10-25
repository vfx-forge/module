const harness = require("@tests/harness")
const gradient = require("@mod/lightning/gradient")
const geometry = require("@mod/lightning/geometry")
const describe, test, expect = harness.describe, harness.test, harness.expect

const Color3 = harness.datatypes.Color3

const KEYS = {
  { t = 0, r = 1, g = 0, b = 0 },
  { t = 0.5, r = 0, g = 1, b = 0 },
  { t = 1, r = 0, g = 0, b = 1 },
}

const UP = vector.create(0, 1, 0)
const WHITE = Color3.new(1, 1, 1)
const BLUE = Color3.new(0.25, 0.5, 1)
const BLUE_KEY = { t = 0, r = 0.25, g = 0.5, b = 1 }

-- a bolt of arcs 0 to 10, and a fork leaving it at arc 4 that runs on to arc 9
const function forked(): { geometry.Joint }
  const joints = {}
  const chains = { { 0, 2, 4, 6, 8, 10 }, { 4, 5.5, 7, 9 } }

  for c, arcs in chains do
    for _, arc in arcs do
      table.insert(joints, { p = vector.zero, t = UP, w = 1, fade = 1, arc = arc, chain = c })
    end
  end

  return joints
end

-- what geometry.along writes for each vertex of a tube with this many sides
const function placesOf(joints: { geometry.Joint }, sides: number, restart: boolean)
  const out = {}

  geometry.along(joints, sides, 10, out, restart)

  return out
end

const function same(a: Color3, b: Color3): boolean
  return math.abs(a.R - b.R) < 1e-6 and math.abs(a.G - b.G) < 1e-6 and math.abs(a.B - b.B) < 1e-6
end

harness.suite(function()
  describe("gradient", function()
    test("exact at the keys", function()
      for _, key in KEYS do
        const r, g, b = gradient.sample(KEYS, key.t)

        expect(r).toBe(key.r)
        expect(g).toBe(key.g)
        expect(b).toBe(key.b)
      end
    end)

    test("halfway between two keys is their mean", function()
      const r, g, b = gradient.sample(KEYS, 0.25)

      expect(r).toBe(0.5)
      expect(g).toBe(0.5)
      expect(b).toBe(0)
    end)

    test("clamped past the ends", function()
      const lowR = gradient.sample(KEYS, -3)
      const _, _, highB = gradient.sample(KEYS, 7)

      expect(lowR).toBe(1)
      expect(highB).toBe(1)
    end)

    test("a lone key answers itself and an empty list answers white", function()
      const r, g, b = gradient.sample({ { t = 0.4, r = 0.2, g = 0.3, b = 0.4 } }, 0.9)

      expect(r).toBe(0.2)
      expect(g).toBe(0.3)
      expect(b).toBe(0.4)

      const wr, wg, wb = gradient.sample({}, 0.5)

      expect(wr + wg + wb).toBe(3)
    end)
  end)

  describe("glow color", function()
    test("the glow takes the gradient's colors as they are", function()
      const joints = forked()
      const along = placesOf(joints, geometry.GLOW.sides, false)
      local ok = true
      const colors = gradient.colors(KEYS, along, {})

      for k, u in along do
        const r, g, b = gradient.sample(KEYS, u)

        ok = ok and same(colors[k], Color3.new(r, g, b))
      end

      expect(ok).toBe(true)
      expect(#colors).toBe(#along)
      expect(same(colors[1], Color3.new(1, 0, 0))).toBe(true)
    end)

    test("one color is a flat gradient, and a stale tail is cleared", function()
      const along = placesOf(forked(), geometry.GLOW.sides, true)
      const colors = table.create(#along + 5, WHITE)

      gradient.colors({ BLUE_KEY }, along, colors)

      local ok = #colors == #along

      for _, color in colors do
        ok = ok and same(color, BLUE)
      end

      expect(ok).toBe(true)
      expect(same(gradient.color({}, 0.4), WHITE)).toBe(true)
    end)

    test("a glow vertex sits at the same place along the bolt as the core's at its joint", function()
      const joints = forked()
      const core = placesOf(joints, geometry.CORE.sides, true)
      const glow = placesOf(joints, geometry.GLOW.sides, true)
      local ok = true
      local coreAt = 0
      local glowAt = 0
      local chain = 1

      for _, joint in joints do
        if joint.chain ~= chain then
          -- each chain's two cap vertices sit after its rings
          ok = ok and core[coreAt + 1] == glow[glowAt + 1] and core[coreAt + 2] == glow[glowAt + 2]
          coreAt += 2
          glowAt += 2
          chain = joint.chain
        end

        for s = 1, geometry.GLOW.sides do
          ok = ok and glow[glowAt + s] == core[coreAt + 1]
        end

        coreAt += geometry.CORE.sides
        glowAt += geometry.GLOW.sides
      end

      ok = ok and core[coreAt + 1] == glow[glowAt + 1] and core[coreAt + 2] == glow[glowAt + 2]

      expect(ok).toBe(true)
      expect(#glow).toBe(glowAt + 2)
    end)

    test("a fork's glow follows GradientRestart", function()
      const joints = forked()
      const sides = geometry.GLOW.sides
      const forkStart = 6 * sides + 2 + 1
      const restarted = gradient.colors(KEYS, placesOf(joints, sides, true), {})
      const carried = gradient.colors(KEYS, placesOf(joints, sides, false), {})

      -- restarting, the fork's root ring is the gradient's start; carried on, it is the bolt's color at arc 4
      expect(same(restarted[forkStart], Color3.new(1, 0, 0))).toBe(true)
      expect(same(carried[forkStart], Color3.new(0.2, 0.8, 0))).toBe(true)

      -- the main bolt reads the same either way
      for k = 1, forkStart - 1 do
        expect(same(restarted[k], carried[k])).toBe(true)
      end
    end)
  end)

  describe("core color", function()
    test("Heat 0 makes the core the bolt's color, 1 white, and 0.5 halfway between", function()
      local ok = true

      for _, u in { 0, 0.25, 0.5, 0.8, 1 } do
        const color = gradient.color(KEYS, u)

        ok = ok
          and same(gradient.core(KEYS, u, 0, 0), color)
          and same(gradient.core(KEYS, u, 1, 0), WHITE)
          and same(gradient.core(KEYS, u, 0.5, 0), color:Lerp(WHITE, 0.5))
      end

      expect(ok).toBe(true)
      expect(same(gradient.core(KEYS, 0, 0.5, 0), Color3.new(1, 0.5, 0.5))).toBe(true)
      expect(same(gradient.core({ BLUE_KEY }, 0.3, 0, 0), BLUE)).toBe(true)
    end)

    test("Heat driven past its range is held to it", function()
      expect(same(gradient.core(KEYS, 0.5, 3, 0), WHITE)).toBe(true)
      expect(same(gradient.core(KEYS, 0.5, -1, 0), Color3.new(0, 1, 0))).toBe(true)
    end)

    test("where the glow fades at the ends the core goes back to the glow's color by the glow's strength", function()
      const keys = { { t = 0, r = 0.2, g = 0.4, b = 1 } }
      const glowColor = Color3.new(0.2, 0.4, 1)
      local ok = true

      for _, heat in { 0, 0.5, 1 } do
        for _, strength in { 1, 0.5, 0 } do
          for _, f in { 0, 0.5, 1 } do
            const fade = geometry.envelope(1, f)
            const got = gradient.core(keys, 0.3, heat, gradient.lean(strength, fade, 0))
            -- at either end the glow has faded to nothing, in the middle it is whole
            const share = if f == 0.5 then 0 else strength
            const want = glowColor:Lerp(WHITE, heat * (1 - share))

            ok = ok and same(got, want)
          end
        end
      end

      expect(ok).toBe(true)
      expect(geometry.envelope(1, 0.5)).toBe(1)

      -- a whole glow at a bare end hands the core its color outright, whatever the Heat
      expect(same(gradient.core(keys, 0.3, 1, gradient.lean(1, 0, 0)), glowColor)).toBe(true)
    end)

    test("a fork's core restarts the color with its glow", function()
      const joints = forked()
      const sides = geometry.CORE.sides
      const forkStart = 6 * sides + 2 + 1
      const restarted = placesOf(joints, sides, true)
      const carried = placesOf(joints, sides, false)

      expect(same(gradient.core(KEYS, restarted[forkStart], 0.5, 0), Color3.new(1, 0.5, 0.5))).toBe(true)
      expect(same(gradient.core(KEYS, carried[forkStart], 0, 0), Color3.new(0.2, 0.8, 0))).toBe(true)
      expect(same(gradient.core(KEYS, carried[forkStart], 1, 0), WHITE)).toBe(true)
    end)

    test("the handover composes with a Fade's tint without applying either twice", function()
      expect(math.abs(gradient.lean(0, 1, 0.3) - 0.3) < 1e-9).toBe(true)
      expect(gradient.lean(1, 0, 0.3)).toBe(1)
      expect(gradient.lean(0.4, 1, 0)).toBe(0)
      expect(math.abs(gradient.lean(0.5, 0.5, 0.3) - (1 - 0.75 * 0.85)) < 1e-9).toBe(true)
    end)
  end)
end)
