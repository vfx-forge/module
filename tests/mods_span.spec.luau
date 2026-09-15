local mods = require("@mod/mods")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect

-- only the pure half is reachable under lune; requiring mods here must not
-- touch game, which is why mods resolves EncodingService lazily through
-- modifier_frame rather than at module scope
harness.suite(function()
  harness.describe("mods.attrName", function()
    test("picks a prefix per source", function()
      expect(mods.attrName("property", "Transparency")).toBe("ForgePropMods_Transparency")
      expect(mods.attrName("attribute", "Scale")).toBe("ForgeAttrMods_Scale")
    end)
  end)

  harness.describe("mods.span", function()
    -- with nothing delaying anything the far end of the queue and its longest
    -- single duration are the same number, which is what this was before
    test("reaches the far end of an undelayed queue", function()
      expect(mods.span({ { duration = 0.5 }, { duration = 2 }, { duration = 1 } }, 9)).toBe(2)
    end)

    -- a base entry is pinned at index 1 and holds a value rather than running,
    -- but a duration on one counted toward the run before delays existed
    test("counts a base entry's duration", function()
      expect(mods.span({ { kind = "sequence", duration = 4 }, { kind = "tween", duration = 1 } }, 9)).toBe(4)
    end)

    test("falls back when every modifier is linked", function()
      expect(mods.span({ { chain = false }, { chain = true } }, 9)).toBe(9)
    end)

    test("falls back on an empty queue", function()
      expect(mods.span({}, 9)).toBe(9)
    end)

    -- an offset pushes its entry out, so the span is the far end of the queue
    -- rather than its longest single duration
    test("counts the offset an entry carries", function()
      local queue = {
        { kind = "tween", duration = 1 },
        { kind = "tween", duration = 0.5, offset = { t = "lit", v = 2 } },
      }

      expect(mods.span(queue, 9)).toBe(2.5)
    end)

    -- the far end has to be far enough for an offset modifier that names no
    -- duration to get a full turn, or the track pumps for a span the queue
    -- cannot finish inside and the knob freezes at its start value
    test("lends an offset modifier with no duration a full fallback", function()
      local queue = { { kind = "tween", offset = { t = "lit", v = 2 } } }

      expect(mods.span(queue, 5)).toBe(7)
    end)

    -- the span has to be the one THIS instance will run, so a drawn offset is
    -- spanned at the value drawn for it rather than at its midpoint
    test("spans a drawn offset at the value the rolls drew", function()
      local queue = { { kind = "tween", duration = 1, offset = { t = "draw", a = 0, b = 4 } } }

      local rolls = { draws = {}, picks = { [1] = { offset = 0.25 } }, envelope = 0 }

      expect(mods.span(queue, 9)).toBe(3)
      expect(mods.span(queue, 9, rolls)).toBe(2)
    end)

    -- a var offset decides the far end exactly as a drawn one does, so the
    -- environment has to reach mods.span and not only the sampler
    test("spans a var offset at what the environment carries", function()
      local queue = { { kind = "tween", duration = 1, offset = { t = "var", ref = "Lifetime" } } }

      local rolls = { draws = {}, picks = {}, env = { Lifetime = 2 }, envelope = 0 }

      expect(mods.span(queue, 9, rolls)).toBe(3)
      expect(mods.span(queue, 9)).toBe(1)
    end)

    -- offsetOf makes every offset finite, and an effect turns a span straight
    -- into a tween's duration
    test("an offset that would overflow stays finite", function()
      local queue = { { kind = "tween", duration = 1, offset = { t = "lit", v = 1e308 } } }

      local span = mods.span(queue, 9)

      expect(span < math.huge).toBe(true)
      expect(span > 9).toBe(true)
    end)

    -- the sampler seeds a linked modifier's run from this, NOT from the span:
    -- the span carries the offset, and seeding a linked run from it leaves an
    -- offset modifier short of its finish for the whole emit
    test("hands back the run a linked modifier gets, beside the reach", function()
      local queue = { { kind = "tween", offset = { t = "lit", v = 2 } } }
      local span, linked = mods.span(queue, 5)

      expect(span).toBe(7)
      expect(linked).toBe(5)
    end)

    -- an infinite duration must not become the run every OTHER linked modifier
    -- takes, or they all read a progress of zero and sit on their start value
    test("an endless duration does not become the linked run", function()
      local queue = { { kind = "tween", duration = math.huge }, { kind = "tween" } }
      local _, linked = mods.span(queue, 4)

      expect(linked).toBe(4)
    end)

    test("an endless span falls back rather than holding the emit open", function()
      expect(mods.span({ { kind = "tween", duration = math.huge } }, 9)).toBe(9)
    end)
  end)

  -- a nan EffectDuration reaches mods.span as the fallback, and the fallback is
  -- what a modifier naming no duration of its own runs for, so one unusable
  -- attribute used to poison the span and the linked run together
  harness.describe("mods.span with unusable input", function()
    test("a nan fallback reaches neither the span nor the linked run", function()
      local queue = { { kind = "tween", offset = { t = "lit", v = 2 } } }
      local span, linked = mods.span(queue, 0 / 0)

      expect(span).toBe(2)
      expect(linked).toBe(0)
    end)

    test("a nan duration in the queue falls back rather than spanning nan", function()
      expect(mods.span({ { kind = "tween", duration = 0 / 0 } }, 3)).toBe(3)
    end)
  end)

  -- a queue that moves nothing drives nothing, but on a property source its
  -- base is the property's live value rather than nil, so nothing downstream
  -- notices unless the shape is named here
  harness.describe("mods.inert", function()
    test("a queue of base entries alone is inert", function()
      expect(mods.inert({ { kind = "sequence" } })).toBe(true)
      expect(mods.inert({ { kind = "sequence" }, { kind = "gradient" } })).toBe(true)
    end)

    test("anything that produces a value is not", function()
      expect(mods.inert({ { kind = "sequence" }, { kind = "tween", duration = 1 } })).toBe(false)
      expect(mods.inert({ { kind = "randomizer" } })).toBe(false)
      expect(mods.inert({ { kind = "future_kind" } })).toBe(false)
    end)

    -- an empty queue is a tombstone its caller tells apart on its own, so inert
    -- must not widen its reach to that one
    test("an empty queue is never inert", function()
      expect(mods.inert({})).toBe(false)
    end)
  end)
end)
