local mod = require("@mod/mod")
local attr = require("@mod/attributes")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local path = require("@mod/common/path")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
local curves = require("@mod/curves")
local reader = require("@mod/reader")
local harness = require("@tests/harness")
local registry = require("@mod/registry")

local Bezier = require("@tests/fixtures/Bezier_213759c")

local test, expect = harness.test, harness.expect
local Vector3 = harness.datatypes.Vector3
local NumberRange = harness.datatypes.NumberRange

frame.configure(harness.fakeEncoding, harness.fakeCompression)

-- the old Bezier's Newton solve stops short of exact, so every comparison here
-- allows the slack between it and the runtime's own sampling
local EPSILON = 1e-4

-- the two piece modules whose exits are the same pair of lanes
local PIECES = { "shockwave_ring", "shockwave_line" }

local function near(a: number, b: number): boolean
  return math.abs(a - b) < EPSILON
end

-- only a Vector3 answers to an upper case axis under this host, so every value
-- compared here is authored as one
local function nearVector(a: any, b: any): boolean
  return near(a.X, b.X) and near(a.Y, b.Y) and near(a.Z, b.Z)
end

-- the Newton solve this host always took, where Studio read a 64 step table
-- built from it
local function easeOf(bez: any, alpha: number): number
  return bez:_getEaseRaw(alpha).y
end

-- the size factor the hand shrink wrote, as a fraction of the piece's drawn
-- size: from where the entry stood when the dwell ended to ShrinkScale, eased
-- through the shrink's own curve. written out here before the tween is deleted
local function oldShrink(attrs: any, from: Vector3, e: number): Vector3
  local bez = Bezier.new(path.deserializePath(attrs.ShrinkCurve), 0)
  local alpha = if attrs.ShrinkDuration > 0 then math.clamp(e / attrs.ShrinkDuration, 0, 1) else 1

  return from:Lerp(attrs.ShrinkScale, 1 - easeOf(bez, alpha))
end

-- the offset the hand exit wrote: from where the entry stood to OffsetOut
local function oldExitOffset(attrs: any, from: Vector3, e: number): Vector3
  local bez = Bezier.new(path.deserializePath(attrs.OffsetOutCurve), 0)
  local alpha = if attrs.OffsetOutDuration > 0 then math.clamp(e / attrs.OffsetOutDuration, 0, 1) else 1

  return from:Lerp(attrs.OffsetOut, 1 - easeOf(bez, alpha))
end

local loaded = false

local function load()
  if loaded then
    return
  end

  registry.clear()
  registry.configure({ query = harness.query })

  for _, name in { "shockwave_ring", "shockwave_line", "shockwave_debris" } do
    registry.register(require(`@vfx/{name}`))
  end

  loaded = true
end

-- a piece of the given module with the attributes the case authors, read the
-- way an emit reads one
local function pieceOf(id: string, authored: { [string]: any }): (any, any)
  load()
  harness.reset()

  local ref = harness.make("Part")
  local binary = {}

  -- this host's attributes hold only valid utf-8, so a serialized curve is
  -- written through the cache the way every other spec writes one
  for key, v in authored do
    if type(v) == "string" then
      binary[key] = v
      v = ""
    end

    ref:SetAttribute(key, v)
  end

  if next(binary) ~= nil then
    attr.cache(ref)

    for key, v in binary do
      attr.set(ref, key, v)
    end
  end

  local module = registry.get(id) :: any

  return registry.read(ref, module), module
end

-- the Transparency row each piece module declared before its fade moved onto
-- the despawn lane: a default on the start lane the module drove from a
-- piece's despawn, on a clock of its own
local function oldFadeModule(finish: number)
  local function noop() end

  return {
    id = "old_fade",
    display = { name = "Old fade" },
    classifier = "Part",
    attributes = {
      Transparency = knob(0):aliases("Transparency_Start"):mod(mod.to(finish):duration(function(_, attrs)
        return attrs.TransparencyDuration
      end)),
      TransparencyDuration = knob(0.5):min(0):aliases("Transparency_Duration"),
    },
    properties = {},
    emit = noop,
  }
end

local FADE_ENDS = { shockwave_ring = 0, shockwave_line = 0, shockwave_debris = 1 }
local FADE_TIMES = { 0, 0.05, 0.1, 0.2, 0.25, 0.4, 0.5, 0.75, 1, 2 }

-- a piece's fade as the module plays it now, fired at `fired`, against the
-- old reading of the same instance started from its own zero at the fire
local function sameFade(id: string, authored: { [string]: any }, rest: number)
  local fired = 1.5
  local attrs, module = pieceOf(id, authored)
  local ref = attrs.Transparency.state.ctx.ref
  local old = reader.resolve(oldFadeModule(FADE_ENDS[id]) :: any, { ref = ref, obj = ref })
  local before = old.Transparency(rest)
  local piece = mods.piece(module.events)
  local after = attrs.Transparency(rest, nil, piece)

  expect(after.has("start")).toBe(false)
  expect(near(after.at(0), rest)).toBe(true)

  piece:fire("despawn", fired)

  for _, e in FADE_TIMES do
    local was, now = before.at(e), after.at(fired + e)

    assert(near(was, now), `{id} {e} s after the despawn: {was} before, {now} now`)
  end

  -- a fade that moved ran its span from the despawn, and the lane reaches as
  -- far. one that never moved is held where it rests, which the samples say
  if before.animated then
    local length, reach = before.duration, after.reach("despawn")

    assert(near(length, reach), `{id}: the old fade ran {length} s, the despawn lane reaches {reach} s`)
  end
end

harness.suite(function()
  harness.describe("the shockwave exits as the hand tweens ran them", function()
    test("the shrink runs from where the entry stood to ShrinkScale", function()
      for _, id in PIECES do
        local attrs = pieceOf(id, { ShrinkScale = Vector3.new(0.2, 0.2, 0.2), ShrinkDuration = 0.4 })
        local from = Vector3.new(1, 1, 1)

        expect(nearVector(oldShrink(attrs, from, 0), from)).toBe(true)
        expect(nearVector(oldShrink(attrs, from, 0.4), Vector3.new(0.2, 0.2, 0.2))).toBe(true)

        local a = oldShrink(attrs, from, 0.1).X
        local b = oldShrink(attrs, from, 0.2).X
        local c = oldShrink(attrs, from, 0.3).X

        expect(a > b and b > c).toBe(true)
        expect(a < 1 and c > 0.2).toBe(true)
      end
    end)

    test("the exit offset runs from where the entry stood to OffsetOut", function()
      for _, id in PIECES do
        local attrs = pieceOf(id, { OffsetOut = Vector3.new(0, -2, 0), OffsetOutDuration = 0.3 })
        local from = Vector3.new(0, 1, 0)

        expect(nearVector(oldExitOffset(attrs, from, 0), from)).toBe(true)
        expect(nearVector(oldExitOffset(attrs, from, 0.3), Vector3.new(0, -2, 0))).toBe(true)

        local a = oldExitOffset(attrs, from, 0.075).Y
        local b = oldExitOffset(attrs, from, 0.15).Y
        local c = oldExitOffset(attrs, from, 0.225).Y

        expect(a > b and b > c).toBe(true)
      end
    end)
  end)

  harness.describe("the shockwave exits as the despawn lane", function()
    -- the entry phases are old quads still mid ramp when the dwell ends, so
    -- the exits start from where they stood, which is what the hand tweens
    -- read off the part
    test("a piece mid entry shrinks and leaves from where its entry stood", function()
      for _, id in PIECES do
        local attrs, module = pieceOf(id, {
          SizeScaleIn_Start = Vector3.new(0, 0, 0),
          SizeScaleIn_End = Vector3.new(1, 1, 1),
          SizeScaleIn_Duration = 1,
          OffsetIn_Start = Vector3.new(0, 1, 0),
          OffsetIn_End = Vector3.new(0, 3, 0),
          OffsetIn_Duration = 1,
          ShrinkScale = Vector3.new(0.2, 0.2, 0.2),
          ShrinkDuration = 0.4,
          OffsetOut = Vector3.new(0, -2, 0),
          OffsetOutDuration = 0.3,
        })

        local piece = mods.piece(module.events)
        local sizeIn = attrs.SizeScaleIn(nil, nil, piece)
        local offsetIn = attrs.OffsetIn(nil, nil, piece)

        expect(sizeIn.has("start")).toBe(true)
        expect(sizeIn.has("despawn")).toBe(true)
        expect(offsetIn.has("start")).toBe(true)
        expect(offsetIn.has("despawn")).toBe(true)
        expect(near(sizeIn.reach("despawn"), 0.4)).toBe(true)
        expect(near(offsetIn.reach("despawn"), 0.3)).toBe(true)

        local fired = 0.5
        local heldSize = sizeIn.at(fired)
        local heldOffset = offsetIn.at(fired)

        piece:fire("despawn", fired)

        for _, e in { 0.1, 0.2, 0.3 } do
          expect(nearVector(sizeIn.at(fired + e), oldShrink(attrs, heldSize, e))).toBe(true)
        end

        for _, e in { 0.075, 0.15, 0.225 } do
          expect(nearVector(offsetIn.at(fired + e), oldExitOffset(attrs, heldOffset, e))).toBe(true)
        end

        expect(nearVector(sizeIn.at(fired + 0.4), Vector3.new(0.2, 0.2, 0.2))).toBe(true)
        expect(nearVector(offsetIn.at(fired + 0.3), Vector3.new(0, -2, 0))).toBe(true)
      end
    end)

    -- behavior difference 1, pinned as the new reading: the hand exit lerped
    -- from an offset only its entry stepper ever updated, so a piece resting at
    -- a plain OffsetIn with OffsetOut at zero never left; the lane starts where
    -- the row stands
    test("a piece resting at a plain OffsetIn now eases from it to OffsetOut", function()
      for _, id in PIECES do
        local rest = Vector3.new(0, 2, 0)
        local attrs, module = pieceOf(id, {
          OffsetIn = rest,
          OffsetOut = Vector3.new(0, 0, 0),
          OffsetOutDuration = 0.3,
        })

        local piece = mods.piece(module.events)
        local offsetIn = attrs.OffsetIn(nil, nil, piece)

        expect(offsetIn.has("start")).toBe(false)
        expect(offsetIn.at(0) == rest).toBe(true)
        expect(offsetIn.at(2) == rest).toBe(true)

        piece:fire("despawn", 2)

        for _, e in { 0.075, 0.15, 0.225 } do
          expect(nearVector(offsetIn.at(2 + e), oldExitOffset(attrs, rest, e))).toBe(true)
        end

        expect(nearVector(offsetIn.at(2.3), Vector3.new(0, 0, 0))).toBe(true)
      end
    end)

    -- the exit stepper writes a CFrame only when the offset moved, so a piece
    -- whose offset lane runs from rest to rest writes none
    test("an unauthored piece's offset never moves", function()
      for _, id in PIECES do
        local attrs, module = pieceOf(id, {})
        local piece = mods.piece(module.events)
        local offsetIn = attrs.OffsetIn(nil, nil, piece)
        local rest = offsetIn.at(0)

        expect(offsetIn.has("start")).toBe(false)
        expect(offsetIn.has("despawn")).toBe(true)

        piece:fire("despawn", 2)

        for _, e in { 0, 0.1, 0.25, 0.5, 1 } do
          expect(offsetIn.at(2 + e) == rest).toBe(true)
        end
      end
    end)

    -- the exit stepper samples only a row whose despawn lane can move it, and
    -- a lane that cannot still answers its reach
    test("a despawn lane that leaves the row where it stands is still", function()
      for _, id in PIECES do
        local attrs, module = pieceOf(id, {})
        local piece = mods.piece(module.events)
        local offsetIn = attrs.OffsetIn(nil, nil, piece)
        local sizeIn = attrs.SizeScaleIn(nil, nil, piece)

        expect(offsetIn.still("despawn", 2)).toBe(true)
        expect(sizeIn.still("despawn", 2)).toBe(false)
        expect(offsetIn.still("dissipate", 2)).toBe(true)
        expect(near(offsetIn.reach("despawn"), attrs.OffsetOutDuration)).toBe(true)

        piece:fire("despawn", 2)

        expect(offsetIn.still("despawn", 2)).toBe(true)
        expect(sizeIn.still("despawn", 2)).toBe(false)
      end
    end)

    test("a despawn lane is still only over the value it ends at", function()
      for _, id in PIECES do
        local stands = Vector3.new(0, 2, 0)
        local attrs, module = pieceOf(id, { OffsetIn = stands, OffsetOut = stands })
        local kept = attrs.OffsetIn(nil, nil, mods.piece(module.events))

        expect(kept.still("despawn", 2)).toBe(true)

        local moved = pieceOf(id, { OffsetIn = stands })
        local leaving = moved.OffsetIn(nil, nil, mods.piece(module.events))

        expect(leaving.still("despawn", 2)).toBe(false)
      end
    end)

    -- the lane chains from wherever the lanes under it hold the row when it
    -- fires, so an entry still moving there moves the exit too
    test("a despawn lane fired over a moving entry is still only where the entry stands", function()
      for _, id in PIECES do
        load()
        harness.reset()

        local rise = {
          kind = "tween",
          chain = false,
          duration = 1,
          start = value.lit(Vector3.new(0, 0, 0)),
          finish = value.lit(Vector3.new(0, 2, 0)),
        }
        local ref = harness.make("Part")

        -- this host's Vector3 is not the native vector a default rests at
        ref:SetAttribute("OffsetOut", Vector3.new(0, 0, 0))
        ref:SetAttribute(
          mods.attrName("attribute", "OffsetIn"),
          frame.frame(codec.encode({ v = 2, lanes = { start = { rise } } }))
        )

        local module = registry.get(id) :: any
        local attrs = registry.read(ref, module) :: any
        local early = mods.piece(module.events)
        local late = mods.piece(module.events)
        local atStart = attrs.OffsetIn(nil, nil, early)
        local midway = attrs.OffsetIn(nil, nil, late)

        early:fire("despawn", 0)
        late:fire("despawn", 0.5)

        expect(atStart.still("despawn", 0)).toBe(true)
        expect(midway.still("despawn", 0.5)).toBe(false)
      end
    end)

    -- the row belongs to the lane that started last, so an end lane starting
    -- inside the exit moves the row whatever the despawn lane says
    test("a despawn lane is not still while a lane starting after it can take the row", function()
      for _, id in PIECES do
        load()
        harness.reset()

        local ends = { kind = "tween", chain = true, duration = 0.3, finish = value.lit(Vector3.new(0, 1, 0)) }
        local ref = harness.make("Part")

        ref:SetAttribute("Lifetime", NumberRange.new(1, 1))
        ref:SetAttribute(
          mods.attrName("attribute", "OffsetIn"),
          frame.frame(codec.encode({ v = 2, lanes = { ["end"] = { ends } } }))
        )

        local module = registry.get(id) :: any
        local attrs = registry.read(ref, module) :: any
        local piece = mods.piece(module.events)
        local offsetIn = attrs.OffsetIn(nil, nil, piece)

        piece:fire("despawn", 0.1)

        expect(offsetIn.still("despawn", 0.1)).toBe(false)
      end
    end)

    test("a despawn lane that passes through somewhere else is not still", function()
      for _, id in PIECES do
        load()
        harness.reset()

        local away = { kind = "tween", chain = true, duration = 0.2, finish = value.lit(Vector3.new(0, 1, 0)) }
        local back = { kind = "tween", chain = true, duration = 0.2, finish = value.lit(Vector3.new(0, 0, 0)) }
        local drawn = {
          kind = "tween",
          chain = true,
          duration = 0.2,
          finish = value.draw(Vector3.new(1, 1, 1), Vector3.new(1, 1, 1)),
        }
        local ref = harness.make("Part")

        ref:SetAttribute(
          mods.attrName("attribute", "OffsetIn"),
          frame.frame(codec.encode({ v = 2, lanes = { despawn = { away, back } } }))
        )

        ref:SetAttribute(
          mods.attrName("attribute", "SizeScaleIn"),
          frame.frame(codec.encode({ v = 2, lanes = { despawn = { drawn } } }))
        )

        local module = registry.get(id) :: any
        local attrs = registry.read(ref, module) :: any
        local piece = mods.piece(module.events)
        local offsetIn = attrs.OffsetIn(nil, nil, piece)
        local sizeIn = attrs.SizeScaleIn(nil, nil, piece)

        expect(offsetIn.still("despawn", 2)).toBe(false)
        expect(sizeIn.still("despawn", 2)).toBe(false)
      end
    end)

    test("the old shrink spellings still reach the despawn lane", function()
      for _, id in PIECES do
        local attrs, module = pieceOf(id, {
          SizeScaleIn = Vector3.new(1, 1, 1),
          SizeScaleEnd = Vector3.new(0.5, 0.5, 0.5),
          Size_Duration = 0.2,
          Size_Curve = curves.linear(),
        })

        local piece = mods.piece(module.events)
        local sizeIn = attrs.SizeScaleIn(nil, nil, piece)

        expect(attrs.ShrinkScale == Vector3.new(0.5, 0.5, 0.5)).toBe(true)
        expect(attrs.ShrinkDuration).toBe(0.2)
        expect(attrs.ShrinkCurve).toBe(curves.linear())

        -- Size_Curve is also a curve-only key on the entry's start lane, and
        -- a stored lane replaces only the default lane it names
        expect(sizeIn.has("start")).toBe(true)
        expect(sizeIn.has("despawn")).toBe(true)
        expect(near(sizeIn.reach("despawn"), 0.2)).toBe(true)

        piece:fire("despawn", 2)

        expect(nearVector(sizeIn.at(2.1), Vector3.new(0.75, 0.75, 0.75))).toBe(true)
        expect(nearVector(sizeIn.at(2.2), Vector3.new(0.5, 0.5, 0.5))).toBe(true)
      end
    end)

    test("an exit of no length reaches nothing and lands at once", function()
      for _, id in PIECES do
        local attrs, module = pieceOf(id, {
          SizeScaleIn = Vector3.new(1, 1, 1),
          ShrinkScale = Vector3.new(0.3, 0.3, 0.3),
          ShrinkDuration = 0,
          OffsetOutDuration = 0,
        })

        local piece = mods.piece(module.events)
        local sizeIn = attrs.SizeScaleIn(nil, nil, piece)
        local offsetIn = attrs.OffsetIn(nil, nil, piece)

        expect(sizeIn.reach("despawn")).toBe(0)
        expect(offsetIn.reach("despawn")).toBe(0)

        piece:fire("despawn", 2)

        expect(nearVector(sizeIn.at(2), Vector3.new(0.3, 0.3, 0.3))).toBe(true)
      end
    end)

    -- despawn-whole: nothing reads the ring's run into a despawn lane, so a
    -- lane authored longer than the run still runs to its end on the piece's
    -- clock; the emit awaiting the stepper is Appendix A R6
    test("an authored despawn lane longer than the run runs to its end", function()
      for _, id in PIECES do
        load()
        harness.reset()

        local ends = Vector3.new(0.1, 0.1, 0.1)
        local long = { kind = "tween", chain = true, duration = 10, finish = value.lit(ends) }
        local ref = harness.make("Part")

        ref:SetAttribute("SizeScaleIn", Vector3.new(1, 1, 1))
        ref:SetAttribute(
          mods.attrName("attribute", "SizeScaleIn"),
          frame.frame(codec.encode({ v = 2, lanes = { despawn = { long } } }))
        )

        local module = registry.get(id) :: any
        local ctx = { ref = ref, obj = ref, effect = module }
        local attrs = reader.resolve(module, ctx)
        local piece = mods.piece(module.events)
        local sizeIn = attrs.SizeScaleIn(nil, nil, piece)
        local fired = attrs.Lifetime.value.Max

        expect(sizeIn.reach("despawn")).toBe(10)
        expect(fired + sizeIn.reach("despawn") > ctx.duration).toBe(true)

        piece:fire("despawn", fired)

        expect(nearVector(sizeIn.at(fired + 5), Vector3.new(0.55, 0.55, 0.55))).toBe(true)
        expect(nearVector(sizeIn.at(fired + 10), ends)).toBe(true)
      end
    end)

    test("the run covers the longest exit a default despawn lane can take", function()
      for _, id in PIECES do
        load()
        harness.reset()

        local ref = harness.make("Part")
        ref:SetAttribute("ShrinkDuration", 0.7)
        ref:SetAttribute("OffsetOutDuration", 0.9)

        local module = registry.get(id) :: any
        local ctx = { ref = ref, obj = ref, effect = module }
        local attrs = reader.resolve(module, ctx)
        local piece = mods.piece(module.events)
        local exit = math.max(
          attrs.SizeScaleIn(nil, nil, piece).reach("despawn"),
          attrs.OffsetIn(nil, nil, piece).reach("despawn")
        )
        local sweep = if id == "shockwave_line" then attrs.Duration else 0

        expect(near(exit, 0.9)).toBe(true)
        expect(ctx.duration + EPSILON >= sweep + attrs.Lifetime.value.Max + exit).toBe(true)
      end
    end)

    test("the old exit offset spellings still reach the despawn lane", function()
      for _, id in PIECES do
        for _, spelling in { "PartOffset", "Offset_End", "OffsetOut_End" } do
          local attrs, module = pieceOf(id, {
            [spelling] = Vector3.new(0, 4, 0),
            Offset_End_Duration = 0.25,
          })

          local piece = mods.piece(module.events)
          local offsetIn = attrs.OffsetIn(nil, nil, piece)

          expect(near(offsetIn.reach("despawn"), 0.25)).toBe(true)

          piece:fire("despawn", 2)

          expect(nearVector(offsetIn.at(2.25), Vector3.new(0, 4, 0))).toBe(true)
        end
      end
    end)

    -- the pieces of one read are handed the lanes it built rather than
    -- building their own, and still fire on clocks of their own
    test("one piece despawning never moves another", function()
      for _, id in PIECES do
        local attrs, module = pieceOf(id, {
          SizeScaleIn = Vector3.new(1, 1, 1),
          ShrinkScale = Vector3.new(0.2, 0.2, 0.2),
          ShrinkDuration = 0.4,
        })

        local leaving = mods.piece(module.events)
        local staying = mods.piece(module.events)
        local gone = attrs.SizeScaleIn(nil, nil, leaving)
        local kept = attrs.SizeScaleIn(nil, nil, staying)

        leaving:fire("despawn", 1)

        expect(nearVector(gone.at(1.4), Vector3.new(0.2, 0.2, 0.2))).toBe(true)
        expect(kept.at(1.4) == Vector3.new(1, 1, 1)).toBe(true)
        expect(near(kept.reach("despawn"), 0.4)).toBe(true)
      end
    end)

    -- an event lane answers its reach before it fires, and builds its sampler
    -- only once a piece has fired it: a curve nothing else eases through is
    -- first decoded for sampling when that sampler first runs, and not a
    -- moment before
    test("a despawn lane never fired builds nothing it would sample through", function()
      for i, id in PIECES do
        local curve = buffer.tostring(path.serializePath({
          Path2DControlPoint.new(UDim2.fromScale(0, 1), UDim2.new(), UDim2.fromScale(0.1 * i, -0.37)),
          Path2DControlPoint.new(UDim2.fromScale(1, 0), UDim2.fromScale(-0.53, 0), UDim2.new()),
        }))

        local original = path.deserializePath
        local decoded = 0

        path.deserializePath = function(data: string | buffer)
          if data == curve then
            decoded += 1
          end

          return original(data)
        end

        local ok, err = pcall(function()
          local attrs, module = pieceOf(id, {
            SizeScaleIn = Vector3.new(1, 1, 1),
            ShrinkScale = Vector3.new(0.2, 0.2, 0.2),
            ShrinkDuration = 0.4,
            ShrinkCurve = curve,
          })

          local piece = mods.piece(module.events)
          local sizeIn = attrs.SizeScaleIn(nil, nil, piece)
          local read = decoded

          expect(sizeIn.has("despawn")).toBe(true)
          expect(near(sizeIn.reach("despawn"), 0.4)).toBe(true)
          expect(sizeIn.at(1) == Vector3.new(1, 1, 1)).toBe(true)
          expect(decoded).toBe(read)

          piece:fire("despawn", 1)

          expect(nearVector(sizeIn.at(1.4), Vector3.new(0.2, 0.2, 0.2))).toBe(true)
          expect(decoded).toBe(read + 1)
        end)

        path.deserializePath = original

        if not ok then
          error(err, 0)
        end
      end
    end)

    -- the emit steps an entry for a row holding an end lane as well as a start
    -- one, since such a row runs during the dwell with no start lane at all
    test("an authored end lane on the entry rows holds no start lane", function()
      for _, id in PIECES do
        load()
        harness.reset()

        local ends = { kind = "tween", chain = true, duration = 0.2, finish = value.lit(Vector3.new(0, 1, 0)) }
        local ref = harness.make("Part")

        ref:SetAttribute(
          mods.attrName("attribute", "OffsetIn"),
          frame.frame(codec.encode({ v = 2, lanes = { ["end"] = { ends } } }))
        )

        local module = registry.get(id) :: any
        local attrs = registry.read(ref, module) :: any
        local offsetIn = attrs.OffsetIn(nil, nil, mods.piece(module.events))

        expect(offsetIn.has("start")).toBe(false)
        expect(offsetIn.has("end")).toBe(true)
        expect(offsetIn.has("despawn")).toBe(true)
      end
    end)
  end)

  harness.describe("the shockwave fade as the despawn lane", function()
    local function tween(start: number?, finish: number, duration: number): any
      return {
        kind = "tween",
        chain = false,
        duration = duration,
        start = if start ~= nil then value.lit(start) else nil,
        finish = value.lit(finish),
      }
    end

    local function framed(lanes: { [string]: { any } }): string
      return frame.frame(codec.encode({ v = 2, lanes = lanes }))
    end

    test("an old fade quad plays from the despawn as it did", function()
      for id in FADE_ENDS do
        for _, rest in { 0, 0.3 } do
          sameFade(id, {
            Transparency_Start = 0,
            Transparency_End = 1,
            Transparency_Duration = 0.4,
            Transparency_Curve = curves.PRESETS.easeInOut,
          }, rest)
        end
      end
    end)

    test("an old fade quad that ends where it starts stays still from the despawn", function()
      for id in FADE_ENDS do
        sameFade(id, { Transparency_Start = 0, Transparency_End = 0, Transparency_Duration = 0.5 }, 0)
      end
    end)

    test("an old half quad is completed from the row as it was", function()
      for id in FADE_ENDS do
        for _, rest in { 0, 0.3 } do
          sameFade(id, { Transparency_End = 0.8 }, rest)
          sameFade(id, { Transparency_Start = 0.2, Transparency_Duration = 0.3 }, rest)
        end
      end
    end)

    test("an unauthored fade plays from the despawn as it did", function()
      for id in FADE_ENDS do
        for _, rest in { 0, 0.3, 1 } do
          sameFade(id, {}, rest)
          sameFade(id, { TransparencyDuration = 0.25 }, rest)
        end
      end
    end)

    test("a start lane stored for the fade plays from the despawn as it did", function()
      local delayed = {
        { kind = "delay", chain = false, wait = value.lit(0.1) },
        tween(0.2, 1, 0.3),
      }

      for id in FADE_ENDS do
        for _, rest in { 0, 0.3 } do
          sameFade(id, { [mods.attrName("attribute", "Transparency")] = framed({ start = delayed }) }, rest)
        end
      end
    end)

    test("a start lane stored beside a despawn lane is the one that plays", function()
      for id in FADE_ENDS do
        local attrs, module = pieceOf(id, {
          [mods.attrName("attribute", "Transparency")] = framed({
            start = { tween(0, 1, 0.4) },
            despawn = { tween(0, 0.5, 2) },
          }),
        })

        local piece = mods.piece(module.events)
        local fade = attrs.Transparency(0, nil, piece)

        piece:fire("despawn", 1)

        expect(near(fade.reach("despawn"), 0.4)).toBe(true)
        expect(near(fade.at(1.2), 0.5)).toBe(true)
        expect(near(fade.at(1.4), 1)).toBe(true)
      end
    end)

    test("a despawn lane stored for the fade plays from the despawn", function()
      for id in FADE_ENDS do
        local attrs, module = pieceOf(id, {
          [mods.attrName("attribute", "Transparency")] = framed({ despawn = { tween(0.1, 0.9, 0.4) } }),
        })

        local piece = mods.piece(module.events)
        local fade = attrs.Transparency(0, nil, piece)

        expect(fade.at(0.5)).toBe(0)

        piece:fire("despawn", 1)

        expect(near(fade.at(1), 0.1)).toBe(true)
        expect(near(fade.at(1.2), 0.5)).toBe(true)
        expect(near(fade.at(1.4), 0.9)).toBe(true)
      end
    end)
  end)

  harness.describe("the debris exit", function()
    -- the old emit waited out ShrinkDuration after the longest dwell; the
    -- despawn lane's reach is what it waits now
    local function oldExitWait(attrs: any): number
      return attrs.ShrinkDuration
    end

    test("a debris piece shrinks through SizeScale's despawn lane as the hand shrink did", function()
      local from = Vector3.new(1, 1, 1)
      local attrs, module = pieceOf("shockwave_debris", {
        SizeScale = from,
        ShrinkScale = Vector3.new(0.25, 0.25, 0.25),
        ShrinkDuration = 0.4,
      })

      local piece = mods.piece(module.events)
      local sizeScale = attrs.SizeScale(nil, nil, piece)

      expect(sizeScale.has("start")).toBe(false)
      expect(near(sizeScale.reach("despawn"), 0.4)).toBe(true)
      expect(sizeScale.at(1) == from).toBe(true)

      piece:fire("despawn", 2)

      for _, e in { 0.1, 0.2, 0.3 } do
        expect(nearVector(sizeScale.at(2 + e), oldShrink(attrs, from, e))).toBe(true)
      end

      expect(nearVector(sizeScale.at(2.4), Vector3.new(0.25, 0.25, 0.25))).toBe(true)
    end)

    test("a debris shrink is not still while an end lane can still take the size", function()
      load()
      harness.reset()

      local from = Vector3.new(1, 1, 1)
      local ends = { kind = "tween", chain = true, duration = 0.3, finish = value.lit(Vector3.new(0.5, 0.5, 0.5)) }
      local ref = harness.make("Part")

      ref:SetAttribute("Lifetime", NumberRange.new(2, 3))
      ref:SetAttribute("SizeScale", from)
      ref:SetAttribute("ShrinkScale", from)
      ref:SetAttribute(
        mods.attrName("attribute", "SizeScale"),
        frame.frame(codec.encode({ v = 2, lanes = { ["end"] = { ends } } }))
      )

      local module = registry.get("shockwave_debris") :: any
      local attrs = registry.read(ref, module) :: any
      local piece = mods.piece(module.events)
      local sizeScale = attrs.SizeScale(nil, nil, piece)

      piece:fire("despawn", 2, 0.5)

      expect(sizeScale.still("despawn", 2)).toBe(false)
    end)

    test("a debris shrink to where the piece stands is still", function()
      local from = Vector3.new(1, 1, 1)
      local kept, module = pieceOf("shockwave_debris", { SizeScale = from, ShrinkScale = from })
      local held = kept.SizeScale(nil, nil, mods.piece(module.events))

      expect(held.still("despawn", 2)).toBe(true)
      expect(near(held.reach("despawn"), kept.ShrinkDuration)).toBe(true)

      local shrunk = pieceOf("shockwave_debris", {})
      local shrinking = shrunk.SizeScale(nil, nil, mods.piece(module.events))

      expect(shrinking.still("despawn", 2)).toBe(false)
    end)

    test("the emit waits out as long an exit as the hand shrink did", function()
      for _, shrink in { 0.5, 1.2, 0 } do
        local attrs = pieceOf("shockwave_debris", { ShrinkDuration = shrink })

        expect(near(attrs.SizeScale.reach("despawn"), oldExitWait(attrs))).toBe(true)
      end
    end)

    -- the fire lends the lane the exit the emit waits out, so an entry naming
    -- no duration runs that exit rather than what is left of the dwell ceiling.
    -- the exit is computed here the way the emit computes it
    test("a no-duration entry on a debris despawn lane runs out the exit", function()
      local ends = Vector3.new(0.25, 0.25, 0.25)
      local open = { kind = "tween", chain = true, finish = value.lit(ends) }
      local attrs, module = pieceOf("shockwave_debris", {
        SizeScale = Vector3.new(1, 1, 1),
        Lifetime = NumberRange.new(2, 2),
        [mods.attrName("attribute", "SizeScale")] = frame.frame(
          codec.encode({ v = 2, lanes = { despawn = { open } } })
        ),
      })

      local fadeLength = if attrs.Transparency.animated then attrs.Transparency.reach("despawn") else 0
      local exit = math.max(fadeLength, attrs.SizeScale.reach("despawn"))
      local piece = mods.piece(module.events)
      local sizeScale = attrs.SizeScale(nil, nil, piece)

      expect(near(exit, 2)).toBe(true)

      -- the old reading: fired at the dwell ceiling, the entry had no time left
      piece:fire("despawn", 2)

      expect(nearVector(sizeScale.at(2.05), ends)).toBe(true)

      piece:fire("despawn", 2, exit)

      expect(nearVector(sizeScale.at(2 + exit / 2), Vector3.new(0.625, 0.625, 0.625))).toBe(true)
      expect(nearVector(sizeScale.at(2 + exit), ends)).toBe(true)
    end)

    -- the pre-module debris read Transparency_Duration as the span of its
    -- default fade, and the module hard-coded half a second instead
    test("a lone Transparency_Duration is the span of a debris piece's fade", function()
      local attrs = pieceOf("shockwave_debris", { Transparency_Duration = 2 })

      expect(attrs.TransparencyDuration).toBe(2)
      expect(attrs.Transparency(0).reach("despawn")).toBe(2)

      local plain = pieceOf("shockwave_debris", {})

      expect(plain.Transparency(0).reach("despawn")).toBe(0.5)
    end)
  end)
end)
