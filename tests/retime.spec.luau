local knob = require("@mod/knob")
local mods = require("@mod/mods")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
local debris = require("@vfx/shockwave_debris")
local resize = require("@mod/resize")
local retime = require("@mod/retime")
local harness = require("@tests/harness")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect
local Vector3 = harness.datatypes.Vector3
local Instance = harness.datatypes.Instance
local NumberRange = harness.datatypes.NumberRange
local NumberSequence = harness.datatypes.NumberSequence
local NumberSequenceKeypoint = harness.datatypes.NumberSequenceKeypoint

frame.configure(harness.fakeEncoding, harness.fakeCompression)

local function noop() end

local function always()
  return true
end

local function stub()
  registry.clear()
  registry.configure({ query = harness.query })
  registry.register({
    id = "stub",
    display = { name = "Stub" },
    classifier = "Part",
    attributes = {
      Delay = knob(0):unit("seconds"),
      Rate = knob(1):unit("perSecond"),
      Pull = knob(1):unit("perSecondSquared"),
      Reach = knob(1):unit("studs"):mod(),
      Dash = knob(1):unit("studsPerSecond"),
      Plain = knob(1),
      Speed = knob(1):mod(),
      SpeedDuration = knob(0.1):aliases("Speed_Duration"):unit("seconds"):hidden(always),
      Far = knob(Vector3.new(1, 1, 1)):aliases("Old_Far"):unit("studs"),
      Mass = knob(8):unit("studsCubedPerSecondSquared"),
      Still = knob(0):unit("seconds"),
      Ruled = knob(function()
        return 3
      end):unit("seconds"),
    },
    properties = {
      Width = knob():unit("studs"):mod(),
    },
    emit = noop,
  })
end

-- an emitter a custom effect classifies, its one property row the emitter's own
-- Lifetime
local function customEmitter(): Instance
  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  registry.register({
    id = "my_emitter",
    display = { name = "My Emitter" },
    classifier = "ParticleEmitter.MyEmitter",
    attributes = {},
    properties = { Lifetime = knob():unit("seconds") },
    emit = noop,
  }, true)

  local obj = harness.make("ParticleEmitter", harness.make("Folder"))

  obj:AddTag("MyEmitter")

  return obj
end

-- the sound's own shape for a knob whose queue can sit under the property
-- spelling, the legacy span of that queue claimed by no row
local function soundLike()
  registry.clear()
  registry.configure({ query = harness.query })
  registry.register({
    id = "sound_like",
    display = { name = "Sound" },
    classifier = "Sound",
    attributes = {},
    properties = {
      Volume = knob():mod(),
    },
    emit = noop,
  })
end

-- a module of a built-in's id and rows, for the behavior resize keys by id.
-- the built-ins are frozen by the time this file runs, and a frozen module
-- cannot be registered a second time
local function effectStub(id: string, classifier: string, attributes: { [string]: any })
  registry.clear()
  registry.configure({ query = harness.query })
  registry.register({
    id = id,
    display = { name = id },
    classifier = classifier,
    attributes = attributes,
    properties = {},
    emit = noop,
  })
end

local function framed(obj: Instance, source: string, name: string, queue: { any })
  obj:SetAttribute(mods.attrName(source, name), frame.frame(codec.encode({ v = 1, queue = queue })))
end

local function queueOf(obj: Instance, source: string, name: string)
  local lanes = mods.framed(obj, source, name)

  return if lanes then lanes.start else nil
end

harness.suite(function()
  harness.describe("retime", function()
    test("rows scale by their unit, legacy keys by the row's, durations by the inverse", function()
      stub()

      local obj = Instance.new("Part")
      obj:SetAttribute("Delay", 2)
      obj:SetAttribute("Rate", 3)
      obj:SetAttribute("Pull", 1)
      obj:SetAttribute("Reach", 4)
      obj:SetAttribute("Dash", 5)
      obj:SetAttribute("Plain", 7)
      obj:SetAttribute("Speed_Start", 1)
      obj:SetAttribute("Speed_End", 2)
      obj:SetAttribute("Speed_Duration", 0.5)
      obj:SetAttribute("Reach_Duration", 1)
      obj:SetAttribute("Old_Far", Vector3.new(1, 1, 1))

      retime.apply(obj, 2, 0.5)

      expect(obj:GetAttribute("Delay")).toBe(1)
      expect(obj:GetAttribute("Rate")).toBe(6)
      expect(obj:GetAttribute("Pull")).toBe(4)
      expect(obj:GetAttribute("Reach")).toBe(4)
      expect(obj:GetAttribute("Dash")).toBe(10)
      expect(obj:GetAttribute("Plain")).toBe(7)
      expect(obj:GetAttribute("Speed_Start")).toBe(1)
      expect(obj:GetAttribute("Speed_Duration")).toBe(0.25)
      expect(obj:GetAttribute("Reach_Duration")).toBe(0.5)
      expect(obj:GetAttribute("Old_Far") == Vector3.new(1, 1, 1)).toBe(true)
    end)

    test("every queue's time scales", function()
      stub()

      local obj = Instance.new("Part")
      framed(obj, "attribute", "Plain", {
        { kind = "tween", chain = false, duration = 2, start = value.lit(0), finish = value.lit(1) },
      })

      retime.apply(obj, 2, 0.5)

      expect(queueOf(obj, "attribute", "Plain")[1].duration).toBe(1)
    end)

    test("a queue under a property spelling scales, and its legacy span once", function()
      soundLike()

      local obj = Instance.new("Sound")
      obj:SetAttribute("Volume_Duration", 1)
      framed(obj, "property", "Volume", {
        { kind = "tween", chain = false, duration = 2, start = value.lit(0), finish = value.lit(1) },
      })

      retime.apply(obj, 2, 0.5)

      expect(queueOf(obj, "property", "Volume")[1].duration).toBe(1)
      expect(obj:GetAttribute("Volume_Duration")).toBe(0.5)
    end)

    test("a bare RayValue keeps the legacy child's spans", function()
      stub()

      local obj = Instance.new("RayValue")
      obj:SetAttribute("Duration", 2)
      obj:SetAttribute("Speed_Duration", 2)
      obj:SetAttribute("EmitDelay", 2)

      retime.apply(obj, 2, 0.5)

      expect(obj:GetAttribute("Duration")).toBe(1)
      expect(obj:GetAttribute("Speed_Duration")).toBe(1)
      expect(obj:GetAttribute("EmitDelay")).toBe(1)
    end)

    test("engine properties scale by class", function()
      local obj = Instance.new("ParticleEmitter")
      obj.Lifetime = NumberRange.new(2, 4)
      obj.Rate = 10

      retime.apply(obj, 2, 0.5)

      expect(obj.Lifetime.Min).toBe(1)
      expect(obj.Lifetime.Max).toBe(2)
      expect(obj.Rate).toBe(20)
    end)

    test("a custom effect's emitter scales by its rows alone, a shared property once", function()
      local obj = customEmitter() :: any

      obj.Lifetime = NumberRange.new(2, 4)
      obj.Rate = 10

      retime.apply(obj, 2, 0.5)

      expect(obj.Lifetime.Min).toBe(1)
      expect(obj.Lifetime.Max).toBe(2)
      expect(obj.Rate).toBe(10)
    end)

    test("batch refuses a factor that is not positive and finite", function()
      local obj = Instance.new("Part")
      obj:SetAttribute("Delay", 2)

      harness.captureWarnings(function()
        retime.batch(0, obj)
        retime.batch(0 / 0, obj)
      end)

      expect(obj:GetAttribute("Delay")).toBe(2)
    end)

    test("a row stored nowhere scales from its default, one at zero or worked out is left unstored", function()
      stub()

      local obj = Instance.new("Part")

      retime.apply(obj, 2, 0.5)

      expect(obj:GetAttribute("Rate")).toBe(2)
      expect(obj:GetAttribute("Pull")).toBe(4)
      expect(obj:GetAttribute("Reach")).toBe(nil)
      expect(obj:GetAttribute("Still")).toBe(nil)
      expect(obj:GetAttribute("Ruled")).toBe(nil)
      expect(obj:GetAttribute("Plain")).toBe(nil)
      expect(obj:GetAttribute("Width")).toBe(nil)

      expect(obj:GetAttribute("SpeedDuration")).toBe(0.05)

      -- a length is not time's, so it stays unstored
      expect(obj:GetAttribute("Far")).toBe(nil)

      resize.apply(obj, 2)

      expect(obj:GetAttribute("Far") == Vector3.new(2, 2, 2)).toBe(true)
      expect(obj:GetAttribute("Mass")).toBe(256)
    end)

    test("a row stored under an old spelling or quad is not written again", function()
      stub()

      local obj = Instance.new("Part")
      obj:SetAttribute("Old_Far", Vector3.new(1, 1, 1))
      obj:SetAttribute("Speed_Duration", 1)
      obj:SetAttribute("Reach_Start", 1)

      resize.apply(obj, 2)

      expect(obj:GetAttribute("Far")).toBe(nil)
      expect(obj:GetAttribute("Old_Far") == Vector3.new(2, 2, 2)).toBe(true)
      expect(obj:GetAttribute("Reach")).toBe(nil)
      expect(obj:GetAttribute("Reach_Start")).toBe(2)
    end)

    test("a gravity mass scales by the square of a retime and the cube of a resize", function()
      stub()

      local obj = Instance.new("Part")
      obj:SetAttribute("Mass", 8)

      retime.apply(obj, 2, 0.5)

      expect(obj:GetAttribute("Mass")).toBe(32)

      resize.apply(obj, 2)

      expect(obj:GetAttribute("Mass")).toBe(256)

      local fresh = Instance.new("Part")

      resize.apply(fresh, 0.5)

      expect(fresh:GetAttribute("Mass")).toBe(1)
    end)

    test("a lane's values scale by its row's unit while its timing scales by the inverse", function()
      stub()

      local obj = Instance.new("Part")
      obj:SetAttribute("Rate", 1)
      obj:SetAttribute("Delay", 1)
      framed(obj, "attribute", "Rate", {
        { kind = "tween", chain = false, duration = 2, start = value.lit(0), finish = value.lit(30) },
      })
      framed(obj, "attribute", "Delay", {
        { kind = "tween", chain = false, duration = 2, start = value.lit(1), finish = value.lit(4) },
      })
      framed(obj, "attribute", "Plain", {
        { kind = "tween", chain = false, duration = 2, start = value.lit(1), finish = value.lit(4) },
      })

      retime.apply(obj, 2, 0.5)

      local rate = queueOf(obj, "attribute", "Rate")[1]
      local delay = queueOf(obj, "attribute", "Delay")[1]
      local plain = queueOf(obj, "attribute", "Plain")[1]

      expect(rate.duration).toBe(1)
      expect(rate.finish.v).toBe(60)
      expect(delay.duration).toBe(1)
      expect(delay.start.v).toBe(0.5)
      expect(delay.finish.v).toBe(2)
      expect(plain.duration).toBe(1)
      expect(plain.finish.v).toBe(4)
    end)

    test("every lane of a row scales, not only the one that starts at the emit", function()
      stub()

      local obj = Instance.new("Part")

      obj:SetAttribute(
        mods.attrName("attribute", "Plain"),
        frame.frame(codec.encode({
          v = 2,
          lanes = {
            start = { { kind = "tween", chain = false, duration = 2 } },
            ["end"] = { { kind = "tween", chain = false, duration = 4 } },
          },
        }))
      )

      retime.apply(obj, 2, 0.5)

      local lanes = mods.framed(obj, "attribute", "Plain") :: any

      expect(lanes.start[1].duration).toBe(1)
      expect(lanes["end"][1].duration).toBe(2)
    end)
  end)

  harness.describe("resize", function()
    test("studs rows scale with their aliases, legacy keys, queues and properties", function()
      stub()

      local obj = Instance.new("Part")
      obj:SetAttribute("Reach", 4)
      obj:SetAttribute("Reach_Start", 1)
      obj:SetAttribute("MinReach", 1)
      obj:SetAttribute("Dash", 5)
      obj:SetAttribute("Delay", 2)
      obj:SetAttribute("Old_Far", Vector3.new(1, 1, 1))
      framed(obj, "attribute", "Reach", {
        { kind = "tween", chain = false, duration = 1, start = value.lit(1), finish = value.lit(2) },
      })
      framed(obj, "property", "Width", {
        { kind = "tween", chain = false, duration = 1, start = value.lit(1), finish = value.lit(2) },
      })

      resize.apply(obj, 2)

      expect(obj:GetAttribute("Reach")).toBe(8)
      expect(obj:GetAttribute("Reach_Start")).toBe(2)
      expect(obj:GetAttribute("MinReach")).toBe(2)
      expect(obj:GetAttribute("Dash")).toBe(10)
      expect(obj:GetAttribute("Delay")).toBe(2)
      expect(obj:GetAttribute("Old_Far") == Vector3.new(2, 2, 2)).toBe(true)
      expect(queueOf(obj, "attribute", "Reach")[1].finish.v).toBe(4)
      expect(queueOf(obj, "property", "Width")[1].finish.v).toBe(4)
    end)

    test("engine properties scale by class", function()
      local obj = Instance.new("ParticleEmitter")
      obj.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 2) })

      resize.apply(obj, 2)

      expect(obj.Size.Keypoints[1].Value).toBe(2)
      expect(obj.Size.Keypoints[2].Value).toBe(4)
    end)

    test("a custom effect's emitter keeps the engine sizes no row of its names", function()
      local obj = customEmitter() :: any

      obj.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 2) })

      resize.apply(obj, 2)

      expect(obj.Size.Keypoints[1].Value).toBe(1)
      expect(obj.Size.Keypoints[2].Value).toBe(2)
    end)

    -- the length scale multiplies the attachment distance, which resize
    -- scales already, so scaling the length scale too grew the beam's length
    -- by the factor squared where its widths grew by the factor
    test("a beam's length scales its attachments, never its length scale", function()
      local beam = require("@vfx/beam")

      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(beam)

      local obj = Instance.new("Beam") :: any
      local a0 = Instance.new("Attachment")
      local a1 = Instance.new("Attachment")

      a0.Position = Vector3.new(-1, 0, 0)
      a1.Position = Vector3.new(1, 0, 0)

      obj.Attachment0 = a0
      obj.Attachment1 = a1
      obj.Width0 = 1

      obj:SetAttribute("LengthScale", 1.5)
      obj:SetAttribute("Length_Scale_Start", NumberRange.new(2, 2))
      obj:SetAttribute("Length_Scale_End", NumberRange.new(3, 3))
      framed(
        obj,
        "attribute",
        "LengthScale",
        { { kind = "tween", chain = false, start = value.lit(2), finish = value.lit(4) } }
      )

      resize.apply(obj, 2)

      expect(a0.Position == Vector3.new(-2, 0, 0)).toBe(true)
      expect(a1.Position == Vector3.new(2, 0, 0)).toBe(true)
      expect(obj.Width0).toBe(2)
      expect(obj:GetAttribute("LengthScale")).toBe(1.5)
      expect(obj:GetAttribute("Length_Scale_Start") == NumberRange.new(2, 2)).toBe(true)
      expect(obj:GetAttribute("Length_Scale_End") == NumberRange.new(3, 3)).toBe(true)

      local queue = queueOf(obj, "attribute", "LengthScale") :: any

      expect(queue[1].start.v).toBe(2)
      expect(queue[1].finish.v).toBe(4)
    end)

    test("a spin model's resting scale is its size", function()
      effectStub("model_spin", "Model", { Scale = knob(1):mod() })

      local obj = Instance.new("Model")
      obj:SetAttribute("Scale", 1)

      resize.apply(obj, 2)

      expect(obj:GetAttribute("Scale")).toBe(2)
    end)

    test("a ring piece's entry offset spellings scale, and each of them once", function()
      effectStub("shockwave_ring", "Part", {
        OffsetIn = knob(Vector3.new()):unit("studs"):mod(),
        OffsetOut = knob(Vector3.new()):aliases("OffsetOut_End", "Offset_End", "PartOffset"):unit("studs"):mod(),
      })

      local obj = Instance.new("Part")
      obj:SetAttribute("OffsetIn_Start", Vector3.new(1, 1, 1))
      obj:SetAttribute("PartOffset", Vector3.new(1, 1, 1))

      resize.apply(obj, 2)

      -- the entry quad's own keys come from the row's name, and PartOffset
      -- from the exit row alone: a key two rows named would be scaled once by
      -- each of them
      expect(obj:GetAttribute("OffsetIn_Start") == Vector3.new(2, 2, 2)).toBe(true)
      expect(obj:GetAttribute("PartOffset") == Vector3.new(2, 2, 2)).toBe(true)
    end)

    test("a debris piece's throw distance scales where its spin does not", function()
      expect(debris.attributes.LinearMagnitude.units).toBe("studs")
      expect(debris.attributes.AngularMagnitude.units).toBe(nil)

      effectStub("shockwave_debris", "Part", {
        LinearMagnitude = knob(NumberRange.new(15, 25)):unit("studs"),
        AngularMagnitude = knob(NumberRange.new(5, 15)),
      })

      local obj = Instance.new("Part")
      obj.Size = Vector3.new(1, 1, 1)
      obj:SetAttribute("LinearMagnitude", NumberRange.new(15, 25))
      obj:SetAttribute("AngularMagnitude", NumberRange.new(5, 15))

      resize.apply(obj, 2)

      expect(obj:GetAttribute("LinearMagnitude") == NumberRange.new(30, 50)).toBe(true)
      expect(obj:GetAttribute("AngularMagnitude") == NumberRange.new(5, 15)).toBe(true)
      expect(obj.Size == Vector3.new(2, 2, 2)).toBe(true)
    end)
  end)
end)
