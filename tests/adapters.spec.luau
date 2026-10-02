local clock = require("@mod/clock")
local harness = require("@tests/harness")
local adapters = require("@mod/adapters")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

local Vector3 = harness.datatypes.Vector3
local NumberRange = harness.datatypes.NumberRange

-- an effect on an emit of its own, and the frames that let a change reach it
local function effect(): (lifetime.emit, lifetime.effect)
  local emit = lifetime.emit(nil)

  return emit, lifetime.effect(emit, 0, nil)
end

local function at(emit: lifetime.emit, speed: number)
  clock.setSpeed(emit.clock, speed)
  scheduler.frame(0)
end

local function done(emit: lifetime.emit)
  lifetime.clear(emit)

  for _ = 1, 4 do
    scheduler.frame(0)
  end
end

-- a particle emitter's time rows and TimeScale, as a plain table
local function emitter()
  return {
    TimeScale = 1,
    Speed = NumberRange.new(4, 8),
    RotSpeed = NumberRange.new(10, 20),
    Lifetime = NumberRange.new(1, 2),
    Acceleration = Vector3.new(0, -4, 0),
    Drag = 2,
    Rate = 10,
  }
end

local function near(a: number, b: number)
  return math.abs(a - b) < 1e-9
end

harness.suite(function()
  harness.describe("the beam adapter", function()
    test("scrolls the texture at its speed times the clock, and stops it while paused", function()
      local emit, fx = effect()
      local beam = { TextureSpeed = 3 }

      local set = adapters.beam(fx, beam, 3, false)

      expect(beam.TextureSpeed).toBe(3)

      at(emit, 2)
      expect(beam.TextureSpeed).toBe(6)

      set(1)
      expect(beam.TextureSpeed).toBe(2)

      clock.setPaused(emit.clock, true)
      scheduler.frame(0)
      expect(beam.TextureSpeed).toBe(0)

      clock.setPaused(emit.clock, false)
      scheduler.frame(0)
      expect(beam.TextureSpeed).toBe(2)

      done(emit)
    end)

    test("writes nothing at once at speed 1 for a texture speed nothing animates", function()
      local emit, fx = effect()
      local beam = { TextureSpeed = 5 }

      adapters.beam(fx, beam, 3, false)

      expect(beam.TextureSpeed).toBe(5)

      done(emit)
    end)
  end)

  harness.describe("the particle adapter", function()
    test("below 1 the TimeScale carries the clock, exact for live particles", function()
      local emit, fx = effect()
      local obj = emitter()

      adapters.particle(fx, obj, 0.8)

      expect(obj.TimeScale).toBe(0.8)

      at(emit, 0.5)

      expect(obj.TimeScale).toBe(0.4)
      expect(obj.Lifetime).toEqual(NumberRange.new(1, 2))

      done(emit)
    end)

    test("above 1 the TimeScale rests at 1 and the time rows take the rest", function()
      local emit, fx = effect()
      local obj = emitter()

      adapters.particle(fx, obj, 1)
      at(emit, 2)

      expect(obj.TimeScale).toBe(1)
      expect(obj.Lifetime).toEqual(NumberRange.new(0.5, 1))
      expect(obj.Speed).toEqual(NumberRange.new(8, 16))
      expect(obj.RotSpeed).toEqual(NumberRange.new(20, 40))
      expect(obj.Acceleration).toEqual(Vector3.new(0, -16, 0))
      expect(obj.Drag).toBe(4)
      expect(obj.Rate).toBe(20)

      -- from the rows as authored, never from what the last speed left
      at(emit, 4)

      expect(obj.Rate).toBe(40)

      at(emit, 1)

      expect(obj.Rate).toBe(10)
      expect(obj.Lifetime).toEqual(NumberRange.new(1, 2))

      done(emit)
    end)

    test("only the part of the speed above 1 is retimed, after the authored TimeScale", function()
      local emit, fx = effect()
      local obj = emitter()

      adapters.particle(fx, obj, 0.5)
      at(emit, 3)

      expect(obj.TimeScale).toBe(1)
      expect(obj.Rate).toBe(15)

      done(emit)
    end)

    test("a pause stands the particles still", function()
      local emit, fx = effect()
      local obj = emitter()

      adapters.particle(fx, obj, 1)
      clock.setPaused(emit.clock, true)
      scheduler.frame(0)

      expect(obj.TimeScale).toBe(0)

      done(emit)
    end)

    test("the rows and the TimeScale go back when the effect ends", function()
      local emit, fx = effect()
      local obj = emitter()

      adapters.particle(fx, obj, 0.7)
      at(emit, 2)
      done(emit)

      expect(obj.TimeScale).toBe(0.7)
      expect(obj.Rate).toBe(10)
      expect(obj.Lifetime).toEqual(NumberRange.new(1, 2))
    end)

    test("two emits of one emitter put back the rows it held before either", function()
      local first, a = effect()
      local second, b = effect()
      local obj = emitter()

      adapters.particle(a, obj, 1)
      at(first, 2)

      adapters.particle(b, obj, 1)
      at(second, 3)

      done(first)

      expect(obj.Rate).toBe(30)

      done(second)

      expect(obj.Rate).toBe(10)
      expect(obj.Lifetime).toEqual(NumberRange.new(1, 2))
    end)
  end)

  harness.describe("the particle adapter with a neighbour", function()
    test("one of two emits ending leaves the other's TimeScale, and the last puts the authored back", function()
      local first, a = effect()
      local second, b = effect()
      local obj = emitter()

      adapters.particle(a, obj, 1)
      adapters.particle(b, obj, 1)

      clock.setSpeed(second.clock, 0.5)
      scheduler.frame(0)

      done(first)

      expect(obj.TimeScale).toBe(0.5)

      done(second)

      expect(obj.TimeScale).toBe(1)
    end)

    test("a NaN TimeScale is ignored", function()
      local emit, fx = effect()
      local obj = emitter()

      local set = adapters.particle(fx, obj, 0.5)

      set(0 / 0)

      expect(obj.TimeScale).toBe(0.5)
      expect(obj.Rate).toBe(10)

      done(emit)
    end)
  end)

  harness.describe("the sound adapter", function()
    local function sound()
      local log = {}
      local clone

      clone = {
        PlaybackSpeed = 1,
        IsPaused = false,
        log = log,
        Pause = function()
          clone.IsPaused = true
          table.insert(log, "pause")
        end,
        Resume = function()
          clone.IsPaused = false
          table.insert(log, "resume")
        end,
      }

      return clone
    end

    test("plays at its speed times the clock, so the pitch follows", function()
      local emit, fx = effect()
      local clone = sound()

      local set = adapters.sound(fx, clone, 1.5)

      expect(clone.PlaybackSpeed).toBe(1.5)

      at(emit, 2)
      expect(clone.PlaybackSpeed).toBe(3)

      set(0.5)
      expect(clone.PlaybackSpeed).toBe(1)

      done(emit)
    end)

    test("pauses while the clock stands still and resumes once", function()
      local emit, fx = effect()
      local clone = sound()

      adapters.sound(fx, clone, 1)

      clock.setPaused(emit.clock, true)
      scheduler.frame(0)
      scheduler.frame(0)

      clock.setPaused(emit.clock, false)
      scheduler.frame(0)

      expect(clone.log).toEqual({ "pause", "resume" })
      expect(clone.PlaybackSpeed).toBe(1)

      done(emit)
    end)
  end)

  harness.describe("the sound adapter once released", function()
    test("a released sound is left alone by the clock", function()
      local emit, fx = effect()
      local log = {}
      local clone = {
        PlaybackSpeed = 1,
        IsPaused = false,
        Pause = function()
          table.insert(log, "pause")
        end,
        Resume = function()
          table.insert(log, "resume")
        end,
      }

      local _, release = adapters.sound(fx, clone, 1)

      release()
      at(emit, 2)

      expect(clone.PlaybackSpeed).toBe(1)

      done(emit)
    end)

    test("a sound that ended by itself during a pause is not resumed", function()
      local emit, fx = effect()
      local log = {}
      local clone = {
        PlaybackSpeed = 1,
        IsPaused = false,
        Pause = function() end,
        Resume = function()
          table.insert(log, "resume")
        end,
      }

      adapters.sound(fx, clone, 1)

      clock.setPaused(emit.clock, true)
      scheduler.frame(0)
      clock.setPaused(emit.clock, false)
      scheduler.frame(0)

      expect(#log).toBe(0)

      done(emit)
    end)
  end)

  harness.describe("the debris adapter", function()
    local made: { any } = {}

    local function part()
      return {
        Anchored = false,
        AssemblyMass = 2,
        AssemblyLinearVelocity = Vector3.new(0, 10, 4),
        AssemblyAngularVelocity = Vector3.new(1, 0, 0),
      }
    end

    local function withForces(body: () -> ())
      local create = adapters.create
      local gravity = workspace.Gravity

      table.clear(made)

      adapters.create = function(class: string)
        local inst = { ClassName = class }
        table.insert(made, inst)

        return inst
      end

      workspace.Gravity = 100

      local ok, err = pcall(body)

      adapters.create = create
      workspace.Gravity = gravity

      assert(ok, err)
    end

    test("at speed 1 a part flies as launched and gets no force", function()
      withForces(function()
        local emit, fx = effect()
        local flying = part()

        adapters.debris(fx)(flying)

        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(0, 10, 4))
        expect(#made).toBe(0)

        done(emit)
      end)
    end)

    test("a slowed part is launched slower and falls under gravity times the speed squared", function()
      withForces(function()
        local emit, fx = effect()
        local flying = part()

        at(emit, 0.5)
        adapters.debris(fx)(flying)

        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(0, 5, 2))
        expect(flying.AssemblyAngularVelocity).toEqual(Vector3.new(0.5, 0, 0))

        local force = made[2]

        expect(force.ClassName).toBe("VectorForce")
        expect(force.Attachment0).toBe(made[1])
        expect(force.Parent).toBe(flying)
        expect(near(force.Force.Y, 2 * 100 * 0.75)).toBe(true)

        done(emit)
      end)
    end)

    test("a speed change rescales what is in flight and its force", function()
      withForces(function()
        local emit, fx = effect()
        local flying = part()

        adapters.debris(fx)(flying)
        at(emit, 2)

        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(0, 20, 8))
        expect(near(made[2].Force.Y, 2 * 100 * (1 - 4))).toBe(true)

        done(emit)
      end)
    end)

    test("a pause anchors every part and the resume gives its velocity back at the new speed", function()
      withForces(function()
        local emit, fx = effect()
        local flying = part()

        adapters.debris(fx)(flying)

        clock.setPaused(emit.clock, true)
        scheduler.frame(0)

        expect(flying.Anchored).toBe(true)

        clock.setPaused(emit.clock, false)
        at(emit, 0.5)

        expect(flying.Anchored).toBe(false)
        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(0, 5, 2))
        expect(flying.AssemblyAngularVelocity).toEqual(Vector3.new(0.5, 0, 0))

        done(emit)
      end)
    end)

    test("a part whose mass changes keeps its effective gravity once it is told", function()
      withForces(function()
        local emit, fx = effect()
        local flying = part()

        at(emit, 0.5)

        local launch, resized = adapters.debris(fx)

        launch(flying)

        flying.AssemblyMass = 1
        resized(flying)

        expect(near(made[2].Force.Y, 1 * 100 * 0.75)).toBe(true)

        done(emit)
      end)
    end)

    test("a part launched while paused waits anchored and leaves at the speed it resumes at", function()
      withForces(function()
        local emit, fx = effect()
        local flying = part()
        local launch = adapters.debris(fx)

        clock.setPaused(emit.clock, true)
        scheduler.frame(0)

        launch(flying)

        expect(flying.Anchored).toBe(true)

        clock.setPaused(emit.clock, false)
        at(emit, 2)

        expect(flying.Anchored).toBe(false)
        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(0, 20, 8))

        done(emit)
      end)
    end)
  end)
end)
