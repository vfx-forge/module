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
      local same = spec:duration(0.5):curve("linear"):offset(0.2):lane("dissipate")

      expect(same).toBe(spec)
      expect(spec.opts.duration).toBe(0.5)
      expect(spec.opts.curve).toBe("linear")
      expect(spec.opts.offset).toBe(0.2)
      expect(spec.opts.lane).toBe("dissipate")
    end)
  end)

  harness.describe("mod.lanes", function()
    test("to runs from the row's state to the endpoint on the row's preset", function()
      local lanes = mod.lanes({ mod.to(1) }, ctx, {}, {}, 0, "linear")

      expect(#lanes.start).toBe(1)
      expect(lanes.start[1].kind).toBe("tween")
      expect(value.resolve(lanes.start[1].start)).toBe(0)
      expect(value.resolve(lanes.start[1].finish)).toBe(1)
      expect(lanes.start[1].duration).toBe(nil)
      expect(lanes.start[1].curve).toBe(curves.linear())
    end)

    test("from runs from the endpoint to the row's state", function()
      local lanes = mod.lanes({ mod.from(0) }, ctx, {}, {}, 1, nil)

      expect(value.resolve(lanes.start[1].start)).toBe(0)
      expect(value.resolve(lanes.start[1].finish)).toBe(1)
      expect(lanes.start[1].curve).toBe(curves.default())
    end)

    test("an endpoint equal to the state is no modifier at all", function()
      expect(mod.lanes({ mod.to(1) }, ctx, {}, {}, 1, nil)).toBe(nil)
    end)

    test("a lane name places the entry, and two specs of one lane queue up", function()
      local lanes = mod.lanes({
        mod.from(1),
        mod.to(1):lane("dissipate"),
        mod.to(2):lane("dissipate"),
      }, ctx, {}, {}, 0, nil)

      expect(#lanes.start).toBe(1)
      expect(#lanes.dissipate).toBe(2)
      expect(value.resolve(lanes.dissipate[2].finish)).toBe(2)
    end)

    -- a lane fired mid run has to pick the row up where it stands, so a `to`
    -- there chains instead of naming the row's resting value as its start
    test("a to on a module's own lane begins where the row stands", function()
      local lanes = mod.lanes({ mod.to(1):lane("dissipate"), mod.to(1) }, ctx, {}, {}, 0, nil)

      expect(lanes.dissipate[1].chain).toBe(true)
      expect(lanes.dissipate[1].start).toBe(nil)
      expect(lanes.start[1].chain).toBe(false)
      expect(value.resolve(lanes.start[1].start)).toBe(0)
    end)

    -- a chained entry begins where the lanes before it left the row, so an
    -- endpoint standing at the row's rest is the phase that carries it back
    test("a chained lane whose endpoint is the row's rest is kept", function()
      local lanes = mod.lanes({ mod.to(1), mod.to(0):lane("dissipate") }, ctx, {}, {}, 0, nil)

      expect(value.resolve(lanes.start[1].finish)).toBe(1)
      expect(#lanes.dissipate).toBe(1)
      expect(lanes.dissipate[1].chain).toBe(true)
      expect(lanes.dissipate[1].start).toBe(nil)
      expect(value.resolve(lanes.dissipate[1].finish)).toBe(0)
    end)

    test("an offset rides the entry rather than leading it", function()
      local lanes = mod.lanes({ mod.to(1):duration(0.5):curve("linear"):offset(0.2) }, ctx, {}, {}, 0, nil)

      expect(#lanes.start).toBe(1)
      expect(value.resolve(lanes.start[1].offset)).toBe(0.2)
      expect(lanes.start[1].duration).toBe(0.5)
      expect(lanes.start[1].curve).toBe(curves.linear())
    end)

    -- a snap TO somewhere is a step the author asked for; a snap FROM somewhere
    -- to where the row already is is the row's own value and costs no sampler
    test("a duration of zero snaps a to and drops a from", function()
      local snapped = mod.lanes({ mod.to(1):duration(0) }, ctx, {}, {}, 0, nil)
      local unnamed = mod.lanes({ mod.to(1) }, ctx, {}, {}, 0, nil)

      expect(snapped.start[1].duration).toBe(0)
      expect(unnamed.start[1].duration).toBe(nil)
      expect(mod.lanes({ mod.from(1):duration(0) }, ctx, {}, {}, 0, nil)).toBe(nil)
    end)

    test("an endpoint, a duration and a curve given as rules are called with ctx, attrs and props", function()
      local seen = {}

      local spec = mod
        .to(function(c, a, p)
          seen.ctx, seen.attrs, seen.props = c, a, p
          return 2
        end)
        :duration(function()
          return 3
        end)
        :curve(function()
          return "linear"
        end)

      local attrs, props = {}, {}
      local lanes = mod.lanes({ spec }, ctx, attrs, props, 0, nil)

      expect(seen.ctx).toBe(ctx)
      expect(seen.attrs).toBe(attrs)
      expect(seen.props).toBe(props)
      expect(value.resolve(lanes.start[1].finish)).toBe(2)
      expect(lanes.start[1].duration).toBe(3)
      expect(lanes.start[1].curve).toBe(curves.linear())
    end)
  end)

  harness.describe("curves.preset", function()
    test("nil and easeOut are the default curve, linear is linear", function()
      expect(curves.preset(nil)).toBe(curves.default())
      expect(curves.preset("easeOut")).toBe(curves.default())
      expect(curves.preset("linear")).toBe(curves.linear())
      expect(curves.PRESETS.linear ~= nil).toBe(true)
    end)

    -- a rule reading a curve row hands back the serialized path that row holds,
    -- which names no preset and is already the curve
    test("a serialized path is the curve it already is", function()
      local buf = buffer.fromstring(curves.default())

      expect(curves.preset(curves.default())).toBe(curves.default())
      expect(curves.preset(buf)).toBe(buf)
    end)

    test("a name that is neither a preset nor a path errors", function()
      expect(function()
        curves.preset("bounce")
      end).toThrow()

      expect(function()
        curves.preset(7 :: any)
      end).toThrow()
    end)
  end)
end)
