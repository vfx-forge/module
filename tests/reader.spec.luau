local mod = require("@mod/mod")
local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local knob = require("@mod/knob")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
local reader = require("@mod/reader")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Vector3 = harness.datatypes.Vector3
local Instance = harness.datatypes.Instance
local NumberRange = harness.datatypes.NumberRange

frame.configure(harness.fakeEncoding, harness.fakeCompression)

local EPSILON = 1e-9

local function near(a: number, b: number): boolean
  return math.abs(a - b) < EPSILON
end

local function tween(startV: any, finishV: any, duration: number?)
  return { kind = "tween", chain = false, duration = duration, start = value.lit(startV), finish = value.lit(finishV) }
end

local function framed(obj: Instance, source: string, name: string, queue: { any })
  obj:SetAttribute(mods.attrName(source, name), frame.frame(codec.encode({ v = 1, queue = queue })))
end

local function noop() end

-- a module built per case, so every case owns its rows
local function module(attributes: { [string]: any }, properties: { [string]: any }?, duration: any?)
  return {
    id = "stub",
    display = { name = "Stub" },
    classifier = "Part",
    attributes = attributes,
    properties = properties or {},
    duration = duration,
    emit = noop,
  }
end

local function ctxFor(obj: Instance)
  return { ref = obj, obj = obj, scale = 1 }
end

harness.suite(function()
  harness.describe("plain rows", function()
    test("a stored value beats an alias, an alias beats a rule, a rule beats the default", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("Old", 4)

      local m = module({
        A = knob(1):aliases("Old"),
        B = knob(function()
          return 9
        end),
        C = knob(2),
      })

      obj:SetAttribute("C", 7)

      local attrs = reader.resolve(m, ctxFor(obj))

      expect(attrs.A).toBe(4)
      expect(attrs.B).toBe(9)
      expect(attrs.C).toBe(7)
    end)

    test("a rule is called with ctx, attrs and props and may read other rows", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("A", 3)

      local seen = {}

      local m = module({
        A = knob(0),
        B = knob(function(ctx, attrs, props)
          seen.ctx, seen.props = ctx, props
          return attrs.A * 2
        end),
      })

      local ctx = ctxFor(obj)
      local attrs, props = reader.resolve(m, ctx)

      expect(seen.ctx).toBe(ctx)
      expect(seen.props).toBe(props)
      expect(attrs.B).toBe(6)
    end)

    test("a number stored for a range row reads as a degenerate range", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("D", 2)

      local attrs = reader.resolve(module({ D = knob(NumberRange.new(1, 1)) }), ctxFor(obj))

      expect(attrs.D.Min).toBe(2)
      expect(attrs.D.Max).toBe(2)
    end)

    test("bounds clamp what was stored", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("A", 50)

      local attrs = reader.resolve(module({ A = knob(1):min(0):max(10) }), ctxFor(obj))

      expect(attrs.A).toBe(10)
    end)

    test("a stored value of another kind falls back and warns once", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("A", "no")

      local m = module({ A = knob(1) })

      local warnings = harness.captureWarnings(function()
        expect(reader.resolve(m, ctxFor(obj)).A).toBe(1)
        expect(reader.resolve(m, ctxFor(obj)).A).toBe(1)
      end)

      expect(#warnings).toBe(1)
    end)

    test("an unusable stored number rests at the fallback without a warning", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("A", 0 / 0)
      obj:SetAttribute("B", math.huge)

      local m = module({
        A = knob(1),
        B = knob(function()
          return 3
        end),
      })

      local attrs
      local warnings = harness.captureWarnings(function()
        attrs = reader.resolve(m, ctxFor(obj))
      end)

      expect(attrs.A).toBe(1)
      expect(attrs.B).toBe(3)
      expect(#warnings).toBe(0)
    end)

    test("a readonly row ignores what was stored", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("A", 5)

      local m = module({
        A = knob(function()
          return 2
        end):readonly(function()
          return true
        end),
      })

      expect(reader.resolve(m, ctxFor(obj)).A).toBe(2)
    end)

    test("a value outside the options falls back", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("Mode", "z")

      expect(reader.resolve(module({ Mode = knob("x"):options({ "x", "y" }) }), ctxFor(obj)).Mode).toBe("x")
    end)

    test("hidden is never evaluated by the runtime", function()
      local obj = Instance.new("Part")

      local m = module({
        A = knob(1):hidden(function()
          error("hidden ran")
        end),
      })

      expect(reader.resolve(m, ctxFor(obj)).A).toBe(1)
    end)

    test("a property row takes the instance's property, and its default only when there is none", function()
      local obj = Instance.new("Part")
      obj.Transparency = 0.25

      local _, props = reader.resolve(module({}, { Transparency = knob(), Nothing = knob(4) }), ctxFor(obj))

      expect(props.Transparency).toBe(0.25)
      expect(props.Nothing).toBe(4)
    end)

    test("an attribute of a property row's name shadows the property", function()
      local obj = Instance.new("Part")
      obj.Transparency = 0.25
      obj:SetAttribute("Transparency", 0.75)

      local _, props = reader.resolve(module({}, { Transparency = knob() }), ctxFor(obj))

      expect(props.Transparency).toBe(0.75)
    end)

    test("the result is frozen and carries no metatable", function()
      local attrs, props = reader.resolve(module({ A = knob(1) }), ctxFor(Instance.new("Part")))

      expect(table.isfrozen(attrs)).toBe(true)
      expect(table.isfrozen(props)).toBe(true)
      expect(getmetatable(attrs)).toBe(nil)
      expect(getmetatable(props)).toBe(nil)
      expect(attrs.Missing).toBe(nil)
    end)

    test("a rule reaches the side it asks for, whichever table it came through", function()
      local obj = Instance.new("Part")
      obj.Transparency = 0.25

      local m = module({
        A = knob(function(_, _, props)
          return props.Transparency * 4
        end),
      }, {
        Transparency = knob(),
        Nothing = knob(function(_, attrs)
          return attrs.A + 1
        end),
      })

      local attrs, props = reader.resolve(m, ctxFor(obj))

      expect(attrs.A).toBe(1)
      expect(props.Transparency).toBe(0.25)
      expect(props.Nothing).toBe(2)
    end)

    test("an attribute row and a property row of one name are not each other", function()
      local obj = Instance.new("Part")
      obj.Transparency = 0.5

      local m = module({
        Transparency = knob(function(_, _, props)
          return props.Transparency + 1
        end),
      }, {
        Transparency = knob(),
      })

      local attrs, props = reader.resolve(m, ctxFor(obj))

      expect(props.Transparency).toBe(0.5)
      expect(attrs.Transparency).toBe(1.5)
    end)

    test("a row defined in terms of itself errors", function()
      local m = module({
        A = knob(function(_, attrs)
          return attrs.A
        end),
      })

      expect(function()
        reader.resolve(m, ctxFor(Instance.new("Part")))
      end).toThrow()
    end)

    test("the source seam replaces what is walked", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("A", 1)

      reader.source = function()
        return { A = 7 }
      end

      -- a module seam restored inside the body leaks into every case after it
      -- when the body throws, so the throw is carried past the restore
      local ok, err = pcall(function()
        expect(reader.resolve(module({ A = knob(0) }), ctxFor(obj)).A).toBe(7)
      end)

      reader.source = reader.defaultSource

      if not ok then
        error(err, 0)
      end
    end)
  end)

  harness.describe("duration", function()
    test("ctx.duration is the module's rule, or one", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("Length", 3)

      local ctx = ctxFor(obj)
      reader.resolve(
        module({ Length = knob(1) }, nil, function(_, attrs)
          return attrs.Length
        end),
        ctx
      )

      expect(ctx.duration).toBe(3)

      local plain = ctxFor(obj)
      reader.resolve(module({}), plain)

      expect(plain.duration).toBe(1)
    end)

    test("a duration rule that asks a mod row for a piece reaches itself and errors", function()
      local m = module({ Life = knob(1):mod() }, nil, function(_, attrs)
        return attrs.Life(2).duration
      end)

      expect(function()
        reader.resolve(m, ctxFor(Instance.new("Part")))
      end).toThrow()
    end)

    test("the duration rule may read a mod row's own value", function()
      local ctx = ctxFor(Instance.new("Part"))
      local attrs = reader.resolve(
        module({ Life = knob(NumberRange.new(2, 3)):mod() }, nil, function(_, a)
          return a.Life.value.Max
        end),
        ctx
      )

      expect(ctx.duration).toBe(3)
      expect(attrs.Life.duration).toBe(3)
    end)
  end)

  harness.describe("mod rows", function()
    test("nothing authored rests at the value", function()
      local attrs = reader.resolve(module({ A = knob(2):mod() }), ctxFor(Instance.new("Part")))

      expect(attrs.A.animated).toBe(false)
      expect(attrs.A.at(0)).toBe(2)
      expect(attrs.A.value).toBe(2)
    end)

    test("a framed queue animates over its own duration", function()
      local obj = Instance.new("Part")
      framed(obj, "attribute", "A", { tween(0, 10, 4) })

      local attrs = reader.resolve(module({ A = knob(2):mod() }), ctxFor(obj))

      expect(attrs.A.animated).toBe(true)
      expect(attrs.A.duration).toBe(4)
      expect(near(attrs.A.at(2), 5)).toBe(true)
      expect(attrs.A.value).toBe(2)
    end)

    test("a queue naming no duration runs over the effect's", function()
      local obj = Instance.new("Part")
      framed(obj, "attribute", "A", { tween(0, 10) })

      local attrs = reader.resolve(
        module({ A = knob(2):mod() }, nil, function()
          return 8
        end),
        ctxFor(obj)
      )

      expect(attrs.A.duration).toBe(8)
    end)

    test("a queue under an alias is found", function()
      local obj = Instance.new("Part")
      framed(obj, "attribute", "Old_Name", { tween(0, 10, 4) })

      local attrs = reader.resolve(module({ NewName = knob(2):aliases("Old_Name"):mod() }), ctxFor(obj))

      expect(attrs.NewName.animated).toBe(true)
    end)

    test("a queue found under an alias chains from the value stored under that alias", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("Length_Scale", 2)
      framed(obj, "attribute", "Length_Scale", { { kind = "tween", chain = true, finish = value.lit(5) } })

      local attrs = reader.resolve(module({ LengthScale = knob(1):aliases("Length_Scale"):mod() }), ctxFor(obj))
      local track = attrs.LengthScale

      expect(track.animated).toBe(true)
      expect(near(track.at(0), 2)).toBe(true)
      expect(near(track.at(track.duration), 5)).toBe(true)
    end)

    test("a range stored on a scalar mod row draws inside it and warns about nothing", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("Speed", NumberRange.new(2, 3))

      local m = module({ Speed = knob(1):mod() })

      local warnings = harness.captureWarnings(function()
        local drawn = reader.resolve(m, ctxFor(obj)).Speed.at(0)

        expect(typeof(drawn)).toBe("number")
        expect(drawn >= 2 and drawn <= 3).toBe(true)
      end)

      expect(#warnings).toBe(0)
    end)

    test("an old quad folds in, and a half quad is completed from the row's state", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("A_Start", 1)
      obj:SetAttribute("A_End", 3)
      obj:SetAttribute("B_End", 3)

      local attrs = reader.resolve(module({ A = knob(0):mod(), B = knob(9):mod() }), ctxFor(obj))

      expect(near(attrs.A.at(0), 1)).toBe(true)
      expect(near(attrs.A.at(attrs.A.duration), 3)).toBe(true)
      expect(near(attrs.B.at(0), 9)).toBe(true)
      expect(near(attrs.B.at(attrs.B.duration), 3)).toBe(true)
    end)

    test("a property row's queue found under an alias still chains from the property", function()
      local obj = Instance.new("Part")
      obj.Transparency = 0.5
      framed(obj, "property", "Transparency_Old", { { kind = "tween", chain = true, finish = value.lit(1) } })

      local _, props =
        reader.resolve(module({}, { Transparency = knob():aliases("Transparency_Old"):mod() }), ctxFor(obj))
      local track = props.Transparency

      expect(track.animated).toBe(true)
      expect(near(track.at(0), 0.5)).toBe(true)
      expect(near(track.at(track.duration), 1)).toBe(true)
    end)

    test("a property row finds a queue framed on the attribute side", function()
      local obj = Instance.new("Part")
      obj.Transparency = 0.5
      framed(obj, "attribute", "Transparency", { tween(0, 1, 2) })

      local _, props = reader.resolve(module({}, { Transparency = knob():mod() }), ctxFor(obj))

      expect(props.Transparency.animated).toBe(true)
      expect(props.Transparency.duration).toBe(2)
    end)

    test("a property row folds an old attribute quad on its name", function()
      local obj = Instance.new("Part")
      obj.Transparency = 0.5
      obj:SetAttribute("Transparency_End", 1)

      local _, props = reader.resolve(module({}, { Transparency = knob():mod() }), ctxFor(obj))

      expect(near(props.Transparency.at(0), 0.5)).toBe(true)
      expect(near(props.Transparency.at(props.Transparency.duration), 1)).toBe(true)
    end)

    test("a property row folds an attribute-tagged legacy child", function()
      local obj = Instance.new("Part")
      obj.Transparency = 0.5

      local child = Instance.new("RayValue")
      child.Name = "Transparency"
      child:AddTag("AttributeTweener")
      child:SetAttribute("_START_VALUE", 0)
      child:SetAttribute("_END_VALUE", 1)
      child:SetAttribute("Duration", 2)
      child.Parent = obj

      local _, props = reader.resolve(module({}, { Transparency = knob():mod() }), ctxFor(obj))

      expect(props.Transparency.animated).toBe(true)
      expect(props.Transparency.duration).toBe(2)
    end)

    test("a default modifier runs when no queue exists, and an empty queue silences it", function()
      local obj = Instance.new("Part")
      local m = module({ A = knob(0):mod(mod.to(1)) }, nil, function()
        return 2
      end)

      local attrs = reader.resolve(m, ctxFor(obj))

      expect(attrs.A.animated).toBe(true)
      expect(attrs.A.duration).toBe(2)
      expect(near(attrs.A.at(0), 0)).toBe(true)
      expect(near(attrs.A.at(2), 1)).toBe(true)

      framed(obj, "attribute", "A", {})

      local silenced = reader.resolve(m, ctxFor(obj))

      expect(silenced.A.animated).toBe(false)
      expect(silenced.A.at(0)).toBe(0)
    end)

    test("an inert framed queue silences the default modifier", function()
      local obj = Instance.new("Part")
      framed(obj, "attribute", "A", {})

      local attrs = reader.resolve(module({ A = knob(0):mod(mod.to(1)) }), ctxFor(obj))

      expect(attrs.A.animated).toBe(false)
      expect(attrs.A.at(0)).toBe(0)
    end)

    test("a default modifier whose endpoint equals the state rests", function()
      local attrs = reader.resolve(module({ A = knob(1):mod(mod.to(1)) }), ctxFor(Instance.new("Part")))

      expect(attrs.A.animated).toBe(false)
    end)

    test("a default modifier's own duration and start are honoured", function()
      local attrs =
        reader.resolve(module({ A = knob(0):mod(mod.from(5):duration(1):start(1)) }), ctxFor(Instance.new("Part")))

      expect(attrs.A.duration).toBe(2)
      expect(near(attrs.A.at(0), 5)).toBe(true)
      expect(near(attrs.A.at(1), 5)).toBe(true)
      expect(near(attrs.A.at(2), 0)).toBe(true)
    end)

    test("a duration row stored as zero snaps the phase the module's clock would ramp", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("ADuration", 0)

      local m = module(
        {
          A = knob(0):mod(mod.to(1):duration(function(_, attrs)
            return attrs.ADuration
          end)),
          ADuration = knob(0.5),
        },
        nil,
        function()
          return 2
        end
      )

      local attrs = reader.resolve(m, ctxFor(obj))
      local ramped = reader.resolve(m, ctxFor(Instance.new("Part")))

      expect(near(attrs.A.at(0), 1)).toBe(true)
      expect(near(attrs.A.at(attrs.A.duration), 1)).toBe(true)
      expect(near(ramped.A.at(0), 0)).toBe(true)
    end)

    test("a range row draws a number per resolution and keeps the range as its value", function()
      local attrs = reader.resolve(module({ Life = knob(NumberRange.new(2, 3)):mod() }), ctxFor(Instance.new("Part")))

      local first = attrs.Life.at(0)
      local again = attrs.Life().at(0)

      expect(typeof(first)).toBe("number")
      expect(first >= 2 and first <= 3).toBe(true)
      expect(typeof(again)).toBe("number")
      expect(attrs.Life.value.Min).toBe(2)
    end)

    test("a tombstone on a range row still draws", function()
      local obj = Instance.new("Part")
      framed(obj, "attribute", "Life", {})

      local attrs = reader.resolve(module({ Life = knob(NumberRange.new(2, 3)):mod() }), ctxFor(obj))
      local drawn = attrs.Life.at(0)

      expect(typeof(drawn)).toBe("number")
      expect(drawn >= 2 and drawn <= 3).toBe(true)
    end)

    test("calling a track for a piece re-resolves it from the value given", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("A_Start", 0)
      obj:SetAttribute("A_End", 1)

      local attrs = reader.resolve(module({ A = knob(0):mod(mod.to(1)) }), ctxFor(obj))
      local piece = attrs.A(0.5)

      expect(near(piece.at(0), 0.5)).toBe(true)
      expect(near(piece.at(piece.duration), 1)).toBe(true)
      expect(piece.value).toBe(0.5)

      local plain = reader.resolve(module({ B = knob(0):mod(mod.to(1)) }), ctxFor(Instance.new("Part")))
      local fromHalf = plain.B(0.5)

      expect(near(fromHalf.at(0), 0.5)).toBe(true)
      expect(near(fromHalf.at(fromHalf.duration), 1)).toBe(true)
    end)

    test("a framed queue is taken at its word when a piece calls it", function()
      local obj = Instance.new("Part")
      framed(obj, "attribute", "A", { tween(0.2, 1, 1) })

      local attrs = reader.resolve(module({ A = knob(0):mod() }), ctxFor(obj))

      expect(near(attrs.A(0.5).at(0), 0.2)).toBe(true)
    end)

    test("a rule reading a mod row gets its track", function()
      local m = module({
        A = knob(2):mod(),
        B = knob(function(_, attrs)
          return attrs.A.at(0) + 1
        end),
      })

      expect(reader.resolve(m, ctxFor(Instance.new("Part"))).B).toBe(3)
    end)

    test("apply hands the track and the scope to the driver", function()
      local seen = {}

      reader.bind = function(scope, track, write)
        seen.scope, seen.track, seen.write = scope, track, write
      end

      local ctx = ctxFor(Instance.new("Part"))
      ctx.scope = {}

      local ok, err = pcall(function()
        local attrs = reader.resolve(module({ A = knob(2):mod() }), ctx)
        local function write() end

        attrs.A:apply(write)

        expect(seen.scope).toBe(ctx.scope)
        expect(seen.track.at(0)).toBe(2)
        expect(seen.write).toBe(write)
      end)

      reader.bind = nil

      if not ok then
        error(err, 0)
      end
    end)

    test("apply before a driver is bound errors", function()
      local ctx = ctxFor(Instance.new("Part"))
      ctx.scope = {}

      local attrs = reader.resolve(module({ A = knob(2):mod() }), ctx)

      expect(function()
        attrs.A:apply(noop)
      end).toThrow()
    end)

    test("a vector row accepts the engine's other vector spelling", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("V", Vector3.new(1, 2, 3))

      local attrs = reader.resolve(module({ V = knob(vector.create(0, 0, 0)):mod() }), ctxFor(obj))

      expect(attrs.V.animated).toBe(false)
      expect(attrs.V.at(0).X).toBe(1)
    end)

    test("a row called with a span builds this piece's track over it", function()
      local obj = Instance.new("Part")

      local m = module(
        {
          Width = knob(0.2):mod(mod.from(2)),
        },
        nil,
        function()
          return 4
        end
      )

      local attrs = reader.resolve(m, ctxFor(obj))

      expect(attrs.Width.duration).toBe(4)
      expect(attrs.Width(nil, 1).duration).toBe(1)
      expect(near(attrs.Width(nil, 1).at(0), 2)).toBe(true)
      expect(near(attrs.Width(nil, 1).at(1), 0.2)).toBe(true)
      expect(attrs.Width(0.5, 2).duration).toBe(2)
      expect(near(attrs.Width(0.5, 2).at(0), 2)).toBe(true)
    end)

    test("a read finds its queues in the map it already holds", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("Old_Start", 0)
      obj:SetAttribute("Old_End", 1)

      local m = module({}, { Transparency = knob(1):mod():aliases("Old") })

      local calls = 0
      local original = attr.get

      local ok, err = pcall(function()
        attr.get = function(...)
          calls += 1
          return original(...)
        end

        local _, props = reader.resolve(m, ctxFor(obj))

        expect(calls).toBe(0)
        expect(props.Transparency.animated).toBe(true)
      end)

      attr.get = original

      if not ok then
        error(err, 0)
      end
    end)

    test("a row's queue is looked for once per read, however many spellings it has", function()
      local obj = Instance.new("Part")

      local child = Instance.new("RayValue")
      child.Name = "Old"
      child:SetAttribute("_START_VALUE", 0)
      child:SetAttribute("_END_VALUE", 1)
      child:SetAttribute("Duration", 2)
      child.Parent = obj

      local m = module({}, { Transparency = knob(1):mod():aliases("Old") })

      local probes = 0
      local original = attr.get

      local ok, err = pcall(function()
        attr.get = function(inst, key, ...)
          if inst == child and key == "_START_VALUE" then
            probes += 1
          end

          return original(inst, key, ...)
        end

        local _, props = reader.resolve(m, ctxFor(obj))

        -- the row is looked for on its own side and the attribute side old
        -- content authored on, under its name and under its alias; the child
        -- behind it is read once for all four
        expect(probes).toBe(1)
        expect(props.Transparency.animated).toBe(true)

        props.Transparency(nil, 2)
        props.Transparency(0.5)

        expect(probes).toBe(1)
      end)

      attr.get = original

      if not ok then
        error(err, 0)
      end
    end)

    test("a piece's call reads nothing the read did not", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("Old_Start", 0)
      obj:SetAttribute("Old_End", 1)

      local m = module({}, { Transparency = knob(1):mod():aliases("Old") })

      local calls = 0
      local original = attr.get

      local ok, err = pcall(function()
        attr.get = function(...)
          calls += 1
          return original(...)
        end

        local _, props = reader.resolve(m, ctxFor(obj))
        local afterRead = calls

        local track
        for _ = 1, 3 do
          track = props.Transparency(nil, 2)
        end

        expect(calls).toBe(afterRead)
        expect(track.duration).toBe(2)
        expect(near(track.at(0), 0)).toBe(true)
        expect(near(track.at(2), 1)).toBe(true)
      end)

      attr.get = original

      if not ok then
        error(err, 0)
      end
    end)
  end)
end)
