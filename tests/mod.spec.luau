local mod = require("@mod/mod")
local value = require("@mod/value")
local curves = require("@mod/curves")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect

local ctx = {}

harness.suite(function()
  harness.describe("mod builders", function()
    test("from and to record the side and the endpoint", function()
      expect(mod.from(0).side).toBe("from")
      expect(mod.from(0).endpoint).toBe(0)
      expect(mod.to(1).side).toBe("to")
      expect(mod.is(mod.to(1))).toBe(true)
      expect(mod.is({})).toBe(false)
    end)

    test("the chain returns the same spec", function()
      local spec = mod.to(1)
      local same = spec:duration(0.5):curve("linear"):start(0.2)

      expect(same).toBe(spec)
      expect(spec.opts.duration).toBe(0.5)
      expect(spec.opts.curve).toBe("linear")
      expect(spec.opts.start).toBe(0.2)
    end)
  end)

  harness.describe("mod.queue", function()
    test("to runs from the row's state to the endpoint on the row's preset", function()
      local queue = mod.queue(mod.to(1), ctx, {}, {}, 0, "linear")

      expect(#queue).toBe(1)
      expect(queue[1].kind).toBe("tween")
      expect(value.resolve(queue[1].start)).toBe(0)
      expect(value.resolve(queue[1].finish)).toBe(1)
      expect(queue[1].duration).toBe(nil)
      expect(queue[1].curve).toBe(curves.linear())
    end)

    test("from runs from the endpoint to the row's state", function()
      local queue = mod.queue(mod.from(0), ctx, {}, {}, 1, nil)

      expect(value.resolve(queue[1].start)).toBe(0)
      expect(value.resolve(queue[1].finish)).toBe(1)
      expect(queue[1].curve).toBe(curves.default())
    end)

    test("an endpoint equal to the state is no modifier at all", function()
      expect(mod.queue(mod.to(1), ctx, {}, {}, 1, nil)).toBe(nil)
    end)

    test("duration, curve and start are honoured, and a start leads with a delay", function()
      local queue = mod.queue(mod.to(1):duration(0.5):curve("linear"):start(0.2), ctx, {}, {}, 0, nil)

      expect(#queue).toBe(2)
      expect(queue[1].kind).toBe("delay")
      expect(value.resolve(queue[1].wait)).toBe(0.2)
      expect(queue[2].duration).toBe(0.5)
      expect(queue[2].curve).toBe(curves.linear())
    end)

    test("an endpoint and a duration given as rules are called with ctx, attrs and props", function()
      local seen = {}

      local spec = mod
        .to(function(c, a, p)
          seen.ctx, seen.attrs, seen.props = c, a, p
          return 2
        end)
        :duration(function()
          return 3
        end)

      local attrs, props = {}, {}
      local queue = mod.queue(spec, ctx, attrs, props, 0, nil)

      expect(seen.ctx).toBe(ctx)
      expect(seen.attrs).toBe(attrs)
      expect(seen.props).toBe(props)
      expect(value.resolve(queue[1].finish)).toBe(2)
      expect(queue[1].duration).toBe(3)
    end)
  end)

  harness.describe("curves.preset", function()
    test("nil and easeOut are the default curve, linear is linear", function()
      expect(curves.preset(nil)).toBe(curves.default())
      expect(curves.preset("easeOut")).toBe(curves.default())
      expect(curves.preset("linear")).toBe(curves.linear())
      expect(curves.PRESETS.linear ~= nil).toBe(true)
    end)

    test("an unknown preset errors", function()
      expect(function()
        curves.preset("bounce")
      end).toThrow()
    end)
  end)
end)
