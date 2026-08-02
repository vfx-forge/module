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

    -- a delay pushes what follows it out, so the span is the far end of the
    -- queue rather than its longest single duration
    test("counts the wait a delay imposes", function()
      local queue = {
        { kind = "tween", duration = 1 },
        { kind = "delay", wait = { t = "lit", v = 2 } },
        { kind = "tween", duration = 0.5 },
      }

      expect(mods.span(queue, 9)).toBe(2.5)
    end)

    -- a delay with nothing after it moves nothing, so it must not add a wait
    -- the effect then pumps through with no value changing
    test("a delay last in the queue leaves the span alone", function()
      local delayed = { { kind = "tween", duration = 1 }, { kind = "delay", wait = { t = "lit", v = 5 } } }

      expect(mods.span(delayed, 9)).toBe(mods.span({ { kind = "tween", duration = 1 } }, 9))
    end)

    -- the far end has to be far enough for a delayed modifier that names no
    -- duration to get a full turn, or mods.driver pumps for a span the queue
    -- cannot finish inside and the knob freezes at its start value
    test("lends a delayed modifier with no duration a full fallback", function()
      local queue = { { kind = "delay", wait = { t = "lit", v = 2 } }, { kind = "tween" } }

      expect(mods.span(queue, 5)).toBe(7)
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

    test("a delay alone spans nothing of its own", function()
      expect(mods.span({ { kind = "delay", wait = { t = "lit", v = 2 } } }, 9)).toBe(9)
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
    -- shape mods.driver has its own reason to stand down on. inert is about
    -- the waits, so it must not widen its reach to that one
    test("a queue with no delay in it is never inert", function()
      expect(mods.inert({ { kind = "sequence" } })).toBe(false)
      expect(mods.inert({})).toBe(false)
    end)
  end)
end)
