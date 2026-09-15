local path = require("@mod/common/path")
local curves = require("@mod/curves")
local harness = require("@tests/harness")
local registry = require("@mod/registry")

local Bezier = require("@obj/Bezier")

local test, expect = harness.test, harness.expect

-- the bolt's own Bezier is LUT and Newton based rather than exact, so every
-- comparison here allows the same slack the runtime's own sampling does
local EPSILON = 1e-4

local function near(a: number, b: number): boolean
  return math.abs(a - b) < EPSILON
end

local FADE_IN_START = 0.9
local FADE_IN_DURATION = 0.4
local FADE_OUT_END = 1
local FADE_OUT_DURATION = 0.3

local function lerp(a: number, b: number, t: number): number
  return a + (b - a) * t
end

-- getEase interpolates its LUT through the native vector type's :Lerp, which
-- this host does not implement; fall back to the LUT-free Newton solve the
-- same object uses to build that LUT, agreeing to numerical precision
local function easeOf(bez: any, alpha: number): number
  local ok, y = pcall(function()
    return bez:getEase(alpha).y
  end)

  if not ok then
    y = bez:_getEaseRaw(alpha).y
  end

  return y
end

-- the transparency the hand-written segment loop produced, written out here
-- before it is deleted. the bolt's own Bezier is what shapes it, so these
-- numbers owe nothing at all to the sampler that replaces the loop
local function oldFadeIn(attrs: any, base: number, elapsed: number): number
  local bez = Bezier.new(path.deserializePath(attrs.FadeInCurve), 0)
  local alpha = if attrs.FadeInDuration > 0 then math.clamp(elapsed / attrs.FadeInDuration, 0, 1) else 1

  return lerp(attrs.FadeInStart, base, 1 - easeOf(bez, alpha))
end

local function oldFadeOut(attrs: any, base: number, progress: number): number
  local bez = Bezier.new(path.deserializePath(attrs.FadeOutCurve), 0)
  local alpha = if attrs.FadeOutDuration > 0 then math.clamp(progress / attrs.FadeOutDuration, 0, 1) else 1

  return lerp(base, attrs.FadeOutEnd, 1 - easeOf(bez, alpha))
end

local loaded = false

-- a bolt with both fades authored, read through the registry the way an emit
-- reads one
local function bolt()
  if not loaded then
    registry.clear()
    registry.configure({ query = harness.query })
    registry.register(require("@vfx/lightning"))
    loaded = true
  end

  harness.reset()

  local ref = harness.make("Attachment")
  ref:AddTag("LightningBolt")
  harness.make("Part", ref)

  ref:SetAttribute("FadeInStart", FADE_IN_START)
  ref:SetAttribute("FadeInDuration", FADE_IN_DURATION)
  ref:SetAttribute("FadeOutEnd", FADE_OUT_END)
  ref:SetAttribute("FadeOutDuration", FADE_OUT_DURATION)

  local attrs = registry.read(ref, registry.get("lightning"))

  return ref, attrs
end

harness.suite(function()
  harness.describe("the lightning fade as the hand loop ran it", function()
    test("the fade inputs read off the bolt", function()
      local _, attrs = bolt()

      expect(attrs.FadeInStart).toBe(FADE_IN_START)
      expect(attrs.FadeInDuration).toBe(FADE_IN_DURATION)
      expect(attrs.FadeOutEnd).toBe(FADE_OUT_END)
      expect(attrs.FadeOutDuration).toBe(FADE_OUT_DURATION)
      expect(attrs.FadeInCurve).toBe(curves.default())
      expect(attrs.FadeOutCurve).toBe(curves.default())
    end)

    -- the fade in leaves the bolt at the transparency it fades from and lands
    -- exactly on the segment's own value, and it only ever moves one way
    test("the fade in runs from its start to the row's value", function()
      local _, attrs = bolt()

      expect(near(oldFadeIn(attrs, 0, 0), FADE_IN_START)).toBe(true)
      expect(near(oldFadeIn(attrs, 0, FADE_IN_DURATION), 0)).toBe(true)
      expect(near(oldFadeIn(attrs, 0, 9), 0)).toBe(true)

      local a = oldFadeIn(attrs, 0, 0.1)
      local b = oldFadeIn(attrs, 0, 0.2)
      local c = oldFadeIn(attrs, 0, 0.3)

      expect(a > b and b > c).toBe(true)
      expect(a < FADE_IN_START).toBe(true)
      expect(c > 0).toBe(true)
    end)

    test("the dissipation fade runs from the row's value to its end", function()
      local _, attrs = bolt()

      expect(near(oldFadeOut(attrs, 0, 0), 0)).toBe(true)
      expect(near(oldFadeOut(attrs, 0, FADE_OUT_DURATION), FADE_OUT_END)).toBe(true)

      local a = oldFadeOut(attrs, 0, 0.075)
      local b = oldFadeOut(attrs, 0, 0.15)
      local c = oldFadeOut(attrs, 0, 0.225)

      expect(a < b and b < c).toBe(true)
      expect(a > 0).toBe(true)
      expect(c < FADE_OUT_END).toBe(true)
    end)

    -- a segment with its own birth value fades out from that value rather than
    -- from the row's, which is what IndependentSegments meant in the loop
    test("a fade out from a held value starts there and still lands on its end", function()
      local _, attrs = bolt()

      local born = oldFadeIn(attrs, 0, 0.2)

      expect(near(oldFadeOut(attrs, born, 0), born)).toBe(true)
      expect(near(oldFadeOut(attrs, born, FADE_OUT_DURATION), FADE_OUT_END)).toBe(true)
    end)
  end)
end)
