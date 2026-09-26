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
    -- modifiers run one after another, so the far end of the queue is its
    -- durations added up rather than the longest of them
    test("reaches the far end of an undelayed queue", function()
      expect(mods.span({ { duration = 0.5 }, { duration = 2 }, { duration = 1 } }, 9)).toBe(3.5)
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

    -- a delay pushes what follows it out past the end of what came before
    test("counts the wait a delay imposes", function()
      local queue = {
        { kind = "tween", duration = 1 },
        { kind = "delay", wait = { t = "lit", v = 2 } },
        { kind = "tween", duration = 0.5 },
      }

      expect(mods.span(queue, 9)).toBe(3.5)
    end)

    -- a delay with nothing after it moves nothing, so it must not add a wait
    -- the effect then pumps through with no value changing
    test("a delay last in the queue leaves the span alone", function()
      local delayed = { { kind = "tween", duration = 1 }, { kind = "delay", wait = { t = "lit", v = 5 } } }

      expect(mods.span(delayed, 9)).toBe(mods.span({ { kind = "tween", duration = 1 } }, 9))
    end)

    -- a delayed modifier that names no duration runs out what is left of the
    -- effect, so the queue ends with the effect
    test("ends a delayed modifier with no duration at the effect's end", function()
      local queue = { { kind = "delay", wait = { t = "lit", v = 2 } }, { kind = "tween" } }

      expect(mods.span(queue, 5)).toBe(5)
    end)

    -- named durations that add up past the effect carry the queue past it
    test("runs past the effect when the named durations do", function()
      local queue = { { kind = "tween", duration = 2 }, { kind = "tween", duration = 3 }, { kind = "tween" } }

      expect(mods.span(queue, 4)).toBe(5)
    end)

    -- the span has to be the one THIS instance will run, so a drawn wait is
    -- spanned at the value drawn for it rather than at its midpoint
    test("spans a drawn wait at the value the rolls drew", function()
      local queue = {
        { kind = "delay", wait = { t = "rand", min = 0, max = 4 } },
        { kind = "tween", duration = 1 },
      }

      local rolls = { draws = {}, picks = { [1] = { wait = 0.25 } }, envelope = 0 }

      expect(mods.span(queue, 9)).toBe(3)
      expect(mods.span(queue, 9, rolls)).toBe(2)
    end)

    -- a var wait decides the far end exactly as a drawn one does, so the
    -- environment has to reach mods.span and not only the sampler
    test("spans a var wait at what the environment carries", function()
      local queue = { { kind = "delay", wait = { t = "var", ref = "Lifetime" } }, { kind = "tween", duration = 1 } }

      local rolls = { draws = {}, picks = {}, env = { Lifetime = 2 }, envelope = 0 }

      expect(mods.span(queue, 9, rolls)).toBe(3)
      expect(mods.span(queue, 9)).toBe(1)
    end)

    test("a delay alone spans nothing of its own", function()
      expect(mods.span({ { kind = "delay", wait = { t = "lit", v = 2 } } }, 9)).toBe(9)
    end)

    -- waitOf makes every wait finite one at a time, but a sum of finite waits
    -- need not be, and an effect turns a span straight into a tween's duration
    test("a delay sum that would overflow stays finite", function()
      local wait = { t = "lit", v = 1e308 }

      local queue = {
        { kind = "delay", wait = wait },
        { kind = "delay", wait = wait },
        { kind = "tween", duration = 1 },
      }

      local span = mods.span(queue, 9)

      -- `< math.huge` alone cannot tell the guard from mods.span's OWN fallback:
      -- without the guard the sum reaches inf, the frontier with it, and the
      -- fallback returns 9, which satisfies it just as well as 1e308 does
      expect(span < math.huge).toBe(true)
      expect(span > 9).toBe(true)
    end)

    -- the sampler lends a linked modifier this, NOT the span: the span can run
    -- past the effect, and a linked modifier runs out the effect alone
    test("hands back the effect a linked modifier runs out, beside the reach", function()
      local queue = { { kind = "tween" }, { kind = "tween", duration = 1 } }
      local span, linked = mods.span(queue, 5)

      expect(span).toBe(6)
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
      local queue = { { kind = "delay", wait = { t = "lit", v = 2 } }, { kind = "tween" } }
      local span, linked = mods.span(queue, 0 / 0)

      expect(span).toBe(2)
      expect(linked).toBe(0)
    end)

    test("a nan duration in the queue falls back rather than spanning nan", function()
      expect(mods.span({ { kind = "tween", duration = 0 / 0 } }, 3)).toBe(3)
    end)
  end)

  -- a queue that waits and does nothing else drives nothing, but on a property
  -- source its base is the property's live value rather than nil, so nothing
  -- downstream notices unless the shape is named here
  harness.describe("mods.inert", function()
    test("a queue that only waits is inert", function()
      expect(mods.inert({ { kind = "delay", wait = { t = "lit", v = 1 } } })).toBe(true)
      expect(mods.inert({ { kind = "sequence" }, { kind = "delay", wait = { t = "lit", v = 1 } } })).toBe(true)
    end)

    test("anything that produces a value is not", function()
      expect(mods.inert({ { kind = "delay" }, { kind = "tween", duration = 1 } })).toBe(false)
      expect(mods.inert({ { kind = "delay" }, { kind = "randomizer" } })).toBe(false)
      expect(mods.inert({ { kind = "delay" }, { kind = "future_kind" } })).toBe(false)
    end)

    -- a base entry alone is a value the target already carries, which is a
    -- shape mods.track has its own reason to stand down on. inert is about
    -- the waits, so it must not widen its reach to that one
    test("a queue with no delay in it is never inert", function()
      expect(mods.inert({ { kind = "sequence" } })).toBe(false)
      expect(mods.inert({})).toBe(false)
    end)
  end)
end)
