local resize = require("@mod/resize")
local retime = require("@mod/retime")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local particle_2d = require("@vfx/particle_2d")
local test, expect = harness.test, harness.expect

local Vector2 = harness.datatypes.Vector2
local NumberRange = harness.datatypes.NumberRange
local NumberSequence = harness.datatypes.NumberSequence

-- lune's roblox library has no ParticleEmitter2D, so the emitter is a plain
-- table answering what the runtime asks of one
local function emitter(parent: any?)
  local attributes = {}
  local obj = {
    ClassName = "ParticleEmitter2D",
    Parent = parent,
    Enabled = false,
    TimeScale = 1,
    Rate = 20,
    Drag = 2,
    Lifetime = NumberRange.new(1, 2),
    Speed = NumberRange.new(50, 100),
    RotSpeed = NumberRange.new(10, 20),
    Acceleration = Vector2.new(0, 40),
    Size = NumberSequence.new(32),
    EmissionOffset = Vector2.new(0.5, 0),
    EmissionSpread = Vector2.new(1, 1),
    emitted = {},
    cleared = 0,
  } :: any

  function obj:IsA(class: string)
    return class == "ParticleEmitter2D" or class == "Instance"
  end

  function obj:Emit(count: number)
    table.insert(obj.emitted, count)
  end

  function obj:Clear()
    obj.cleared += 1
  end

  function obj:GetAttribute(name: string)
    return attributes[name]
  end

  function obj:SetAttribute(name: string, value: any)
    attributes[name] = value
  end

  function obj:GetAttributes()
    return table.clone(attributes)
  end

  function obj:GetDescendants()
    return {}
  end

  return obj
end

local function frame(class: string)
  return {
    IsA = function(_, name: string)
      return name == class
    end,
  }
end

local function still(at: number)
  return {
    animated = false,
    value = at,
    at = function()
      return at
    end,
  }
end

-- an emit of the emitter's module, its rows as the reader answers them
local function play(obj: any, attrs: any, timeScale: any?): lifetime.emit
  local emit = lifetime.emit(nil)
  local fx = lifetime.effect(emit, 0, nil)

  lifetime.run(fx, function(scope: lifetime.effect)
    local ctx = { ref = obj, obj = obj, scope = scope, shared = { unc = {}, ref = {}, held = {} } }
    local rows = table.clone(attrs)

    rows.EmitCount = rows.EmitCount or 1
    rows.EmitDelay = rows.EmitDelay or 0
    rows.EmitDuration = rows.EmitDuration or 0

    particle_2d.emit(ctx :: any, rows, { TimeScale = timeScale or still(obj.TimeScale) })
  end)

  lifetime.seal(emit)

  return emit
end

local function run(seconds: number)
  for _ = 1, math.round(seconds / 0.05) do
    scheduler.frame(0.05)
  end
end

local function near(a: number, b: number)
  return math.abs(a - b) < 1e-6
end

harness.suite(function()
  harness.describe("the 2D particle emitter", function()
    test("bursts its count after the delay and ends once its longest particle has lived", function()
      local obj = emitter(frame("GuiObject"))
      local emit = play(obj, { EmitCount = 12, EmitDelay = 0.5 })

      run(0.45)

      expect(obj.emitted).toEqual({})

      run(0.1)

      expect(obj.emitted).toEqual({ 12 })
      expect(particle_2d.duration({ ref = obj } :: any, { EmitDuration = 0 })).toBe(2)

      run(1.9)

      expect(emit.done).toBe(false)

      run(0.1)

      expect(emit.done).toBe(true)
    end)

    test("a window holds it on for its duration and lets it go after", function()
      local obj = emitter(frame("GuiObject"))
      local emit = play(obj, { EmitCount = 0, EmitDuration = 1 })

      expect(obj.Enabled).toBe(true)

      run(0.9)

      expect(obj.Enabled).toBe(true)

      run(0.2)

      expect(obj.Enabled).toBe(false)
      expect(particle_2d.duration({ ref = obj } :: any, { EmitDuration = 1 })).toBe(3)

      lifetime.clear(emit)
    end)

    test("an emitter left on is switched off as it emits", function()
      local obj = emitter(frame("GuiObject"))

      obj.Enabled = true

      local emit = play(obj, { EmitCount = 4 })

      expect(obj.Enabled).toBe(false)
      expect(obj.emitted).toEqual({ 4 })

      lifetime.clear(emit)
    end)

    test("emits nothing where it cannot draw: under no GuiObject, or on a server", function()
      local loose = emitter(frame("Folder"))
      local first = play(loose, { EmitCount = 4, EmitDuration = 1 })

      expect(loose.emitted).toEqual({})
      expect(loose.Enabled).toBe(false)
      expect(first.done).toBe(true)

      local runService = game:GetService("RunService") :: any
      local wasRunning, wasClient = runService.IsRunning, runService.IsClient

      runService.IsRunning = function()
        return true
      end

      runService.IsClient = function()
        return false
      end

      local served = emitter(frame("GuiObject"))
      local second = play(served, { EmitCount = 4 })

      runService.IsRunning, runService.IsClient = wasRunning, wasClient

      expect(served.emitted).toEqual({})
      expect(second.done).toBe(true)
    end)

    test("a modifier on its TimeScale is written to the emitter, and the authored one put back", function()
      local obj = emitter(frame("GuiObject"))

      obj.TimeScale = 0.8

      local ramp = {
        animated = true,
        duration = 1,
        value = 1,
        at = function(t: number)
          return 1 - t * 0.5
        end,
      }

      local emit = play(obj, { EmitCount = 1 }, ramp)

      expect(obj.TimeScale).toBe(1)

      run(0.5)

      expect(near(obj.TimeScale, 0.75)).toBe(true)

      run(0.5)

      expect(near(obj.TimeScale, 0.5)).toBe(true)

      lifetime.clear(emit)

      expect(obj.TimeScale).toBe(0.8)
    end)
  end)

  harness.describe("a 2D emitter's rows under an edit", function()
    local function registered()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(particle_2d)
    end

    test("a resize scales its pixel rows and leaves the fractions of its parent", function()
      registered()

      local obj = emitter(frame("GuiObject"))

      resize.batch(2, obj)

      expect(obj.Size).toEqual(NumberSequence.new(64))
      expect(obj.Speed).toEqual(NumberRange.new(100, 200))
      expect(obj.Acceleration).toEqual(Vector2.new(0, 80))
      expect(obj.EmissionOffset).toEqual(Vector2.new(0.5, 0))
      expect(obj.EmissionSpread).toEqual(Vector2.new(1, 1))
      expect(obj.Lifetime).toEqual(NumberRange.new(1, 2))

      registry.clear()
    end)

    test("a retime scales its time rows, the acceleration by the square", function()
      registered()

      local obj = emitter(frame("GuiObject"))

      retime.batch(2, obj)

      expect(obj.Lifetime).toEqual(NumberRange.new(0.5, 1))
      expect(obj.Speed).toEqual(NumberRange.new(100, 200))
      expect(obj.Acceleration).toEqual(Vector2.new(0, 160))
      expect(obj.Rate).toBe(40)
      expect(obj.Drag).toBe(4)
      expect(obj.Size).toEqual(NumberSequence.new(32))

      registry.clear()
    end)
  end)
end)
