local mods = require("@mod/mods")
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

  harness.describe("the lightning fade as a modifier on its row", function()
    test("an unauthored bolt costs no lane at all", function()
      bolt()
      harness.reset()

      local ref = harness.make("Attachment")
      ref:AddTag("LightningBolt")
      harness.make("Part", ref)

      local module = registry.get("lightning")
      local attrs = registry.read(ref, module)
      local track = attrs.Transparency(nil, 1, mods.piece(module.events))

      expect(track.animated).toBe(false)
      expect(track.at(0)).toBe(0)
      expect(track.has("start")).toBe(false)
      expect(track.has("dissipate")).toBe(false)
    end)

    test("the fade in samples what the hand loop sampled", function()
      local _, attrs = bolt()
      local module = registry.get("lightning")
      local track = attrs.Transparency(nil, 1, mods.piece(module.events))

      expect(track.has("start")).toBe(true)

      for _, at in { 0.1, 0.2, 0.3 } do
        expect(near(track.at(at), oldFadeIn(attrs, 0, at))).toBe(true)
      end

      expect(near(track.at(0), FADE_IN_START)).toBe(true)
      expect(near(track.at(FADE_IN_DURATION), 0)).toBe(true)
    end)

    -- the module fires the lane on the same clock it hands the track, so the
    -- dissipation's own progress is the elapsed past the fire
    test("the dissipation fade samples what the hand loop sampled", function()
      local _, attrs = bolt()
      local module = registry.get("lightning")
      local piece = mods.piece(module.events)
      local track = attrs.Transparency(nil, 1, piece)

      expect(track.has("dissipate")).toBe(true)

      local fired = 0.5

      piece:fire("dissipate", fired)

      for _, at in { 0.075, 0.15, 0.225 } do
        expect(near(track.at(fired + at), oldFadeOut(attrs, 0, at))).toBe(true)
      end

      expect(near(track.at(fired + FADE_OUT_DURATION), FADE_OUT_END)).toBe(true)
      expect(near(track.at(9), FADE_OUT_END)).toBe(true)
    end)

    -- a segment that froze the row at its birth composes only the lanes fired
    -- after it, over the value it is holding
    test("a segment holding its birth value fades out from there", function()
      local _, attrs = bolt()
      local module = registry.get("lightning")
      local piece = mods.piece(module.events)
      local track = attrs.Transparency(nil, 1, piece)

      local birthElapsed = 0.2
      local born = track.at(birthElapsed)

      expect(near(born, oldFadeIn(attrs, 0, birthElapsed))).toBe(true)

      piece:fire("dissipate", 0.5)

      expect(near(track.at(0.4, born, birthElapsed), born)).toBe(true)

      for _, at in { 0.075, 0.15, 0.225 } do
        expect(near(track.at(0.5 + at, born, birthElapsed), oldFadeOut(attrs, born, at))).toBe(true)
      end

      expect(near(track.at(0.5 + FADE_OUT_DURATION, born, birthElapsed), FADE_OUT_END)).toBe(true)
    end)

    -- a segment born at the emit is born into the fade rather than past it, so
    -- the lane that starts there still runs over the value it is holding. this
    -- is the call form the module uses with IndependentSegments on
    test("a segment born at the emit still fades in", function()
      local _, attrs = bolt()
      local module = registry.get("lightning")
      local piece = mods.piece(module.events)
      local track = attrs.Transparency(nil, 1, piece)

      local birth = track.at(0)

      expect(near(birth, FADE_IN_START)).toBe(true)

      for _, at in { 0.1, 0.2, 0.3 } do
        expect(near(track.at(at, birth, 0), oldFadeIn(attrs, 0, at))).toBe(true)
      end

      expect(near(track.at(FADE_IN_DURATION, birth, 0), 0)).toBe(true)
      expect(near(track.at(9, birth, 0), 0)).toBe(true)
    end)

    -- a bolt that authors only the exit fade puts nothing on the row's own
    -- lane, and the row still rests where its own value says it does
    test("a fade out with no fade in rests at the row's value until it fires", function()
      bolt()
      harness.reset()

      local ref = harness.make("Attachment")
      ref:AddTag("LightningBolt")
      harness.make("Part", ref)
      ref:SetAttribute("FadeOutEnd", FADE_OUT_END)
      ref:SetAttribute("FadeOutDuration", FADE_OUT_DURATION)

      local module = registry.get("lightning")
      local attrs = registry.read(ref, module)
      local piece = mods.piece(module.events)
      local track = attrs.Transparency(nil, 1, piece)

      expect(attrs.FadeInDuration).toBe(0)
      expect(track.has("start")).toBe(false)
      expect(track.has("dissipate")).toBe(true)
      expect(near(track.at(0), 0)).toBe(true)
      expect(near(track.at(0.65), 0)).toBe(true)

      local fired = 0.5

      piece:fire("dissipate", fired)

      for _, at in { 0.075, 0.15, 0.225 } do
        expect(near(track.at(fired + at), oldFadeOut(attrs, 0, at))).toBe(true)
      end

      expect(near(track.at(fired + FADE_OUT_DURATION), FADE_OUT_END)).toBe(true)
    end)

    -- an old quad on the row carried one trigger and could never have named the
    -- dissipation, so the ramp it authors takes the entry fade and leaves the
    -- exit one the bolt authored beside it standing
    test("a legacy quad on the row leaves the dissipation fade standing", function()
      bolt()
      harness.reset()

      local ref = harness.make("Attachment")
      ref:AddTag("LightningBolt")
      harness.make("Part", ref)

      ref:SetAttribute("FadeInStart", FADE_IN_START)
      ref:SetAttribute("FadeInDuration", FADE_IN_DURATION)
      ref:SetAttribute("Fade_Out_End", FADE_OUT_END)
      ref:SetAttribute("Fade_Out_Duration", FADE_OUT_DURATION)
      ref:SetAttribute("Transparency_End", 0.5)

      local module = registry.get("lightning")
      local attrs = registry.read(ref, module)
      local piece = mods.piece(module.events)
      local track = attrs.Transparency(nil, 1, piece)

      expect(track.has("start")).toBe(true)
      expect(track.has("dissipate")).toBe(true)

      local fired = 0.6
      local held = track.at(fired)

      piece:fire("dissipate", fired)

      for _, at in { 0.075, 0.15, 0.225 } do
        expect(near(track.at(fired + at), oldFadeOut(attrs, held, at))).toBe(true)
      end

      expect(near(track.at(fired + FADE_OUT_DURATION), FADE_OUT_END)).toBe(true)
    end)

    -- a fade nobody authored is not a lane, which is what keeps an unauthored
    -- bolt free of a sampler it would only ever sample at rest
    test("a fade of no length is no lane", function()
      bolt()
      harness.reset()

      local ref = harness.make("Attachment")
      ref:AddTag("LightningBolt")
      harness.make("Part", ref)
      ref:SetAttribute("FadeOutEnd", 1)

      local module = registry.get("lightning")
      local attrs = registry.read(ref, module)
      local track = attrs.Transparency(nil, 1, mods.piece(module.events))

      expect(attrs.FadeOutDuration).toBe(0)
      expect(track.has("dissipate")).toBe(false)
    end)
  end)
end)
