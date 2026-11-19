local resize = require("@mod/resize")
local retime = require("@mod/retime")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
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
local function play(obj: any, attrs: any, copied: { Instance }): lifetime.emit
  local emit = lifetime.emit(nil)
  local fx = lifetime.effect(emit, 0, nil)

  lifetime.run(fx, function(scope: lifetime.effect)
    local ctx = {
      ref = obj,
      obj = obj,
      scope = scope,
      shared = { unc = {}, ref = {}, held = {} },
      copied = function(copy: Instance)
        table.insert(copied, copy)
      end,
    }
    local rows = table.clone(attrs)

    rows.EmitCount = rows.EmitCount or 1
    rows.EmitDelay = rows.EmitDelay or 0
    rows.EmitDuration = rows.EmitDuration or 0

    particle_2d.emit(ctx :: any, rows, { TimeScale = still(obj.TimeScale) })
  end)

  lifetime.seal(emit)

  return emit
end

harness.suite(function()
  harness.describe("the 2D particle emitter", function()
    -- the burst, the window and the TimeScale are the 3D emitter's own code,
    -- covered by its specs; what is the 2D one's is where it plays
    test("under a GuiObject in the editor it emits and hands its rows to the dispatcher", function()
      local obj = emitter(frame("GuiObject"))
      local copied = {}
      local emit = play(obj, { EmitCount = 12 }, copied)

      expect(obj.emitted).toEqual({ 12 })
      expect(copied).toEqual({ obj })

      lifetime.clear(emit)
    end)

    test("under no GuiObject it emits nothing and drives none of its rows", function()
      local obj = emitter(frame("Folder"))
      local copied = {}
      local emit = play(obj, { EmitCount = 4, EmitDuration = 1 }, copied)

      expect(obj.emitted).toEqual({})
      expect(obj.Enabled).toBe(false)
      expect(copied).toEqual({})
      expect(emit.done).toBe(true)
    end)

    test("on a server it emits nothing and drives none of its rows, a count of 0 included", function()
      local runService = game:GetService("RunService") :: any
      local wasRunning, wasClient = runService.IsRunning, runService.IsClient

      runService.IsRunning = function()
        return true
      end

      runService.IsClient = function()
        return false
      end

      local obj = emitter(frame("GuiObject"))
      local copied = {}
      local ok, err = pcall(function()
        play(obj, { EmitCount = 4 }, copied)
        play(obj, { EmitCount = 0 }, copied)
      end)

      runService.IsRunning, runService.IsClient = wasRunning, wasClient

      if not ok then
        error(err, 0)
      end

      expect(obj.emitted).toEqual({})
      expect(copied).toEqual({})
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
