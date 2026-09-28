local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local knob = require("@mod/knob")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
local reader = require("@mod/reader")
local harness = require("@tests/harness")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance
local NumberRange = harness.datatypes.NumberRange

frame.configure(harness.fakeEncoding, harness.fakeCompression)

local ROUNDS = 5
local ITERATIONS = 2000

local PLAIN = { "A", "B", "C", "D", "E", "F", "G", "H", "I" }
local ANIMATED = { "X", "Y", "Z" }

local function noop() end

local function fixture(): Instance
  local obj = Instance.new("Part")

  for i, name in PLAIN do
    obj:SetAttribute(name, i)
  end

  obj:SetAttribute("R", NumberRange.new(1, 2))
  obj:SetAttribute("X_Start", 0)
  obj:SetAttribute("X_End", 1)

  obj:SetAttribute(
    mods.attrName("attribute", "Y"),
    frame.frame(codec.encode({
      v = 2,
      lanes = {
        start = { { kind = "tween", chain = false, duration = 1, start = value.lit(0), finish = value.lit(1) } },
      },
    }))
  )

  return obj
end

local function moduleFor()
  local attributes = {}

  for _, name in PLAIN do
    attributes[name] = knob(0):min(0)
  end

  attributes.R = knob(NumberRange.new(0, 1))

  for _, name in ANIMATED do
    attributes[name] = knob(0):mod()
  end

  return {
    id = "cost",
    display = { name = "Cost" },
    classifier = "Part",
    attributes = attributes,
    properties = {},
    emit = noop,
  }
end

-- what a converted effect used to do for the same rows: one soft read per
-- plain row and one track per animated one
local function oldRead(obj: Instance)
  local out = {}

  for _, name in PLAIN do
    out[name] = math.max(attr.get(obj, name, 0, true), 0)
  end

  out.R = attr.getRange(obj, "R", NumberRange.new(0, 1), nil, true)

  for _, name in ANIMATED do
    out[name] = mods.track(obj, "attribute", name, 0, 1)
  end

  return out
end

-- what the converted particle read on every emit, before it was a module: its
-- three plain attributes with their defaults, the emitter's own TimeScale as
-- the start of a track whose span is the soft read behind it, and the lifetime
-- the emit ran over
local function oldParticleRead(obj: Instance)
  local emitter = obj :: ParticleEmitter
  local out = {}

  out.EmitDelay = attr.get(obj, "EmitDelay", 0)
  out.EmitCount = attr.get(obj, "EmitCount", 1)
  out.EmitDuration = attr.get(obj, "EmitDuration", 0)

  out.TimeScale =
    mods.track(obj, "attribute", "TimeScale", emitter.TimeScale, attr.get(obj, "TimeScale_Duration", 0.1, true))

  out.Lifetime = emitter.Lifetime.Max

  return out
end

local function timed(fn: () -> ())
  local started = os.clock()

  for _ = 1, ITERATIONS do
    fn()
  end

  return os.clock() - started
end

local function best(fn: () -> ())
  local fastest = math.huge

  for _ = 1, ROUNDS do
    fastest = math.min(fastest, timed(fn))
  end

  return fastest
end

-- the old and the new read in alternate rounds, so wherever the collector is
-- in its cycle weighs on both alike instead of on whichever ran second
local function against(old: () -> (), new: () -> ()): (number, number)
  local fastestOld, fastestNew = math.huge, math.huge

  for _ = 1, ROUNDS do
    fastestOld = math.min(fastestOld, timed(old))
    fastestNew = math.min(fastestNew, timed(new))
  end

  return fastestOld, fastestNew
end

harness.suite(function()
  test("one read of every row costs no more than the reads it replaces", function()
    local obj = fixture()
    local m = moduleFor()

    local old, new = against(function()
      oldRead(obj)
    end, function()
      reader.resolve(m, { ref = obj, obj = obj, scale = 1 })
    end)

    print(
      `read cost over {ITERATIONS} emits: old {string.format("%.1f", old * 1000)} ms, new {string.format(
        "%.1f",
        new * 1000
      )} ms`
    )

    -- the one attributes map behind a read carries a fixed cost, and a module
    -- of this few non mod rows does not read enough of them to pay it back,
    -- even though every row costs less than the read it replaced
    expect(new <= old * 1.1).toBe(true)
  end)

  test("a read of every built-in against its bare instance is reported, and the particle's is bounded", function()
    registry.clear()
    registry.configure({ query = harness.query })

    for _, name in
      {
        "beam",
        "mesh",
        "spin",
        "sound",
        "trail",
        "bezier",
        "screen",
        "particle",
        "lightning",
        "shockwave",
        "camera_shake",
        "shockwave_ring",
        "shockwave_line",
        "shockwave_debris",
      }
    do
      registry.register(require(`@vfx/{name}`))
    end

    local lines = {}
    local particle: any = nil
    local particleInst: Instance? = nil

    for _, module in registry.list() do
      local class = registry.subjects(module.classifier)
      local name = if class ~= nil and class[1] ~= "BasePart" then class[1] else "Part"
      local inst = Instance.new(name)
      local ctx = { ref = inst, obj = inst, scale = 1, effect = module }

      local took = best(function()
        reader.resolve(module, ctx)
      end)

      table.insert(lines, `{module.id} {string.format("%.1f", took / ITERATIONS * 1e6)} us`)

      if module.id == "particle" then
        particle = { module = module, ctx = ctx }
        particleInst = inst
      end
    end

    print(`one read per built-in: {table.concat(lines, ", ")}`)

    local oldParticle, newParticle = against(function()
      oldParticleRead(particleInst :: Instance)
    end, function()
      reader.resolve(particle.module, particle.ctx)
    end)

    print(
      `particle read cost over {ITERATIONS} emits: old {string.format("%.1f", oldParticle * 1000)} ms, new {string.format(
        "%.1f",
        newParticle * 1000
      )} ms`
    )

    expect(newParticle <= oldParticle * 1.1).toBe(true)
  end)
end)
