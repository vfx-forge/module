local knob = require("@mod/knob")
local mods = require("@mod/mods")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
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
    },
    properties = {
      Width = knob():unit("studs"):mod(),
    },
    emit = noop,
  })
end

-- the sound's own shape for a knob whose queue can sit under the property
-- spelling, beside the legacy span of that queue as a row of its own
local function soundLike()
  registry.clear()
  registry.configure({ query = harness.query })
  registry.register({
    id = "sound_like",
    display = { name = "Sound" },
    classifier = "Sound",
    attributes = {
      VolumeDuration = knob():aliases("Volume_Duration"):unit("seconds"):hidden(always),
    },
    properties = {
      Volume = knob():mod(),
    },
    emit = noop,
  })
end

local function framed(obj: Instance, source: string, name: string, queue: { any })
  obj:SetAttribute(mods.attrName(source, name), frame.frame(codec.encode({ v = 1, queue = queue })))
end

local function queueOf(obj: Instance, source: string, name: string)
  return mods.framed(obj, source, name)
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

    test("engine properties scale by class", function()
      local obj = Instance.new("ParticleEmitter")
      obj.Lifetime = NumberRange.new(2, 4)
      obj.Rate = 10

      retime.apply(obj, 2, 0.5)

      expect(obj.Lifetime.Min).toBe(1)
      expect(obj.Lifetime.Max).toBe(2)
      expect(obj.Rate).toBe(20)
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
  end)
end)
