local clock = require("@mod/clock")
local harness = require("@tests/harness")
local adapters = require("@mod/adapters")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local particle = require("@vfx/particle")
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

    test("the rows and the emitter's own TimeScale go back when the effect ends", function()
      local emit, fx = effect()
      local obj = emitter()

      adapters.particle(fx, obj, 0.7)
      at(emit, 2)
      done(emit)

      expect(obj.TimeScale).toBe(1)
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
    test("an emit at 1 joining while another holds the rows retimed leaves them to follow its own speed", function()
      local first, a = effect()
      local second, b = effect()
      local obj = emitter()

      adapters.particle(a, obj, 1)
      at(first, 2)

      adapters.particle(b, obj, 1)

      expect(obj.Rate).toBe(10)

      done(second)

      expect(obj.Rate).toBe(20)

      done(first)

      expect(obj.Rate).toBe(10)
      expect(obj.Lifetime).toEqual(NumberRange.new(1, 2))
    end)

    test("a lone emit at 1 writes no row", function()
      local emit, fx = effect()
      local obj = emitter()

      adapters.particle(fx, obj, 1)

      expect(lifetime.writing(obj, "property", "Rate")).toBe(0)

      done(emit)
    end)

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

    test("a NaN or infinite authored TimeScale falls back to the emitter's own", function()
      for _, bad in { 0 / 0, math.huge } do
        local emit, fx = effect()
        local obj = emitter()

        obj.TimeScale = 0.5
        adapters.particle(fx, obj, bad)

        expect(obj.TimeScale).toBe(0.5)
        expect(obj.Rate).toBe(10)

        done(emit)
      end
    end)

    test("a NaN or infinite TimeScale is ignored", function()
      for _, bad in { 0 / 0, math.huge } do
        local emit, fx = effect()
        local obj = emitter()

        local set = adapters.particle(fx, obj, 0.5)

        set(bad)

        expect(obj.TimeScale).toBe(0.5)
        expect(obj.Rate).toBe(10)

        done(emit)
      end
    end)
  end)

  harness.describe("the particle module over one emitter in place", function()
    -- an emitter in the workspace, which an emit plays on rather than a clone
    local function inPlace()
      local obj = emitter() :: any

      obj.TimeScale = 0.8
      obj.Enabled = false

      obj.IsDescendantOf = function()
        return true
      end

      obj.Emit = function() end
      obj.cleared = 0

      obj.Clear = function()
        obj.cleared += 1
      end

      return obj
    end

    -- an emit at a speed, its rows answered from the emitter as the reader
    -- answers them, once, when the emit is read
    local function play(obj: any, speed: number, window: number?): lifetime.emit
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local read = obj.TimeScale

      at(emit, speed)

      local timeScale = {
        animated = false,
        value = read,
        at = function()
          return read
        end,
      }

      lifetime.run(fx, function(scope: lifetime.effect)
        local ctx = { ref = obj, scope = scope, shared = { unc = {}, ref = obj.refMap or {} } }

        particle.emit(
          ctx :: any,
          { EmitCount = 1, EmitDelay = 0, EmitDuration = window or 0 },
          { TimeScale = timeScale }
        )
      end)

      lifetime.seal(emit)

      return emit
    end

    local function run(seconds: number)
      for _ = 1, math.round(seconds / 0.05) do
        scheduler.frame(0.05)
      end
    end

    test("a second emit over the first's writes reads what was authored, and the last puts it back", function()
      local obj = inPlace()

      local first = play(obj, 2)

      expect(obj.TimeScale).toBe(1)

      run(0.2)

      local second = play(obj, 0.5)

      expect(particle.duration({ ref = obj } :: any, { EmitDuration = 0 })).toBe(2)

      -- the first runs out 2 / (0.8 * 2) after it starts, the second
      -- 2 / (0.8 * 0.5) after it does
      run(1.8)

      expect(first.done).toBe(true)
      expect(near(obj.TimeScale, 0.4)).toBe(true)

      run(3)

      expect(second.done).toBe(false)
      expect(near(obj.TimeScale, 0.4)).toBe(true)

      run(0.4)

      expect(second.done).toBe(true)
      expect(obj.TimeScale).toBe(0.8)
      expect(obj.Lifetime).toEqual(NumberRange.new(1, 2))
      expect(obj.Speed).toEqual(NumberRange.new(4, 8))
      expect(obj.Rate).toBe(10)
    end)

    test("two overlapping windows keep the emitter on until the last closes", function()
      local obj = inPlace()
      local first = play(obj, 1, 1)

      expect(obj.Enabled).toBe(true)

      run(0.5)

      local second = play(obj, 1, 1)

      expect(obj.Enabled).toBe(true)

      run(0.6)

      expect(obj.Enabled).toBe(true)

      run(0.5)

      expect(obj.Enabled).toBe(false)

      lifetime.clear(first)
      lifetime.clear(second)
    end)

    test("a clear wipes the emitter only when no other emit plays on it", function()
      local obj = inPlace()
      local first = play(obj, 1)
      local second = play(obj, 1)

      lifetime.clear(first)

      expect(obj.cleared).toBe(0)

      lifetime.clear(second)

      expect(obj.cleared).toBe(1)
    end)

    test("a burst and a window on one emitter leave it off once the window closes", function()
      local obj = inPlace()
      local burst = play(obj, 1)

      expect(obj.Enabled).toBe(false)

      local window = play(obj, 1, 1)

      expect(obj.Enabled).toBe(true)

      run(1.1)

      expect(obj.Enabled).toBe(false)

      lifetime.clear(burst)
      lifetime.clear(window)

      expect(obj.Enabled).toBe(false)
    end)

    test("a clear in the middle of a window puts Enabled back", function()
      local obj = inPlace()
      local window = play(obj, 1, 1)

      run(0.3)

      expect(obj.Enabled).toBe(true)

      lifetime.clear(window)

      expect(obj.Enabled).toBe(false)
    end)

    test("a clone of an enabled emitter ends off once its window closes", function()
      local parent = {}
      local clone = inPlace()
      local template = inPlace()

      clone.Enabled = true
      clone.Archivable = true
      template.Enabled = true
      template.Parent = parent
      template.refMap = { [parent] = { Destroy = function() end } }

      template.IsDescendantOf = function()
        return false
      end

      template.FindFirstAncestorWhichIsA = function()
        return {}
      end

      template.Clone = function()
        return clone
      end

      local window = play(template, 1, 1)

      expect(clone.Enabled).toBe(true)

      run(1.1)

      expect(clone.Enabled).toBe(false)

      lifetime.clear(window)
    end)
  end)

  harness.describe("the sound adapter", function()
    local function sound()
      local log = {}
      local clone

      clone = {
        PlaybackSpeed = 1,
        IsPlaying = true,
        IsPaused = false,
        log = log,
        Pause = function()
          clone.IsPlaying = false
          clone.IsPaused = true
          table.insert(log, "pause")
        end,
        Resume = function()
          clone.IsPlaying = true
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
        IsPlaying = true,
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
        IsPlaying = false,
        IsPaused = true,
        Pause = function()
          table.insert(log, "pause")
        end,
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

    -- what the effect hands a launch: the impulses for a flight at speed 1
    local IMPULSE = Vector3.new(0, 20, 8)
    local SPIN = Vector3.new(2, 0, 0)

    -- a part as the engine keeps one: an impulse lands at the next physics
    -- step rather than when it is applied, and an anchored part takes none
    local function part()
      local p = {
        Anchored = false,
        AssemblyMass = 2,
        AssemblyLinearVelocity = Vector3.zero,
        AssemblyAngularVelocity = Vector3.zero,
        pending = Vector3.zero,
        pendingSpin = Vector3.zero,
      }

      function p.ApplyImpulse(self: any, impulse: Vector3)
        self.pending += impulse
      end

      function p.ApplyAngularImpulse(self: any, impulse: Vector3)
        self.pendingSpin += impulse
      end

      return p
    end

    -- the physics step, with an inertia of the part's mass about every axis
    local function step(p: any)
      if not p.Anchored then
        p.AssemblyLinearVelocity += p.pending / p.AssemblyMass
        p.AssemblyAngularVelocity += p.pendingSpin / p.AssemblyMass
      end

      p.pending = Vector3.zero
      p.pendingSpin = Vector3.zero
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

        adapters.debris(fx)(flying, IMPULSE, SPIN)
        step(flying)

        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(0, 10, 4))
        expect(flying.AssemblyAngularVelocity).toEqual(Vector3.new(1, 0, 0))
        expect(#made).toBe(0)

        done(emit)
      end)
    end)

    test("a slowed part is launched slower and falls under gravity times the speed squared", function()
      withForces(function()
        local emit, fx = effect()
        local flying = part()

        flying.AssemblyLinearVelocity = Vector3.new(2, 0, 0)

        at(emit, 0.5)
        adapters.debris(fx)(flying, IMPULSE, SPIN)
        step(flying)

        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(1, 5, 2))
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

        adapters.debris(fx)(flying, IMPULSE, SPIN)
        step(flying)
        at(emit, 2)

        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(0, 20, 8))
        expect(flying.AssemblyAngularVelocity).toEqual(Vector3.new(2, 0, 0))
        expect(near(made[2].Force.Y, 2 * 100 * (1 - 4))).toBe(true)

        done(emit)
      end)
    end)

    test("a pause anchors every part and the resume gives its velocity back at the new speed", function()
      withForces(function()
        local emit, fx = effect()
        local flying = part()

        adapters.debris(fx)(flying, IMPULSE, SPIN)
        step(flying)

        clock.setPaused(emit.clock, true)
        scheduler.frame(0)
        step(flying)

        expect(flying.Anchored).toBe(true)

        clock.setPaused(emit.clock, false)
        at(emit, 0.5)
        step(flying)

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

        launch(flying, IMPULSE, SPIN)
        step(flying)

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

        launch(flying, IMPULSE, SPIN)
        step(flying)

        expect(flying.Anchored).toBe(true)
        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.zero)

        clock.setPaused(emit.clock, false)
        at(emit, 2)
        step(flying)

        expect(flying.Anchored).toBe(false)
        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(0, 20, 8))
        expect(flying.AssemblyAngularVelocity).toEqual(Vector3.new(2, 0, 0))

        done(emit)
      end)
    end)

    test("a part paused in its launch frame keeps its impulse and leaves at the speed it resumes at", function()
      withForces(function()
        local emit, fx = effect()
        local flying = part()

        adapters.debris(fx)(flying, IMPULSE, SPIN)

        clock.setPaused(emit.clock, true)
        scheduler.frame(0)
        step(flying)

        expect(flying.Anchored).toBe(true)

        clock.setPaused(emit.clock, false)
        at(emit, 0.5)
        step(flying)

        expect(flying.Anchored).toBe(false)
        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(0, 5, 2))
        expect(flying.AssemblyAngularVelocity).toEqual(Vector3.new(0.5, 0, 0))

        done(emit)
      end)
    end)

    test("a part whose speed changes in its launch frame leaves at the new speed", function()
      withForces(function()
        local emit, fx = effect()
        local flying = part()

        adapters.debris(fx)(flying, IMPULSE, SPIN)
        at(emit, 0.5)
        step(flying)

        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(0, 5, 2))
        expect(flying.AssemblyAngularVelocity).toEqual(Vector3.new(0.5, 0, 0))

        done(emit)
      end)
    end)

    test("a part resumed and paused again before a step still keeps its impulse", function()
      withForces(function()
        local emit, fx = effect()
        local flying = part()
        local launch = adapters.debris(fx)

        clock.setPaused(emit.clock, true)
        scheduler.frame(0)

        launch(flying, IMPULSE, SPIN)

        clock.setPaused(emit.clock, false)
        scheduler.frame(0)
        clock.setPaused(emit.clock, true)
        scheduler.frame(0)
        step(flying)

        clock.setPaused(emit.clock, false)
        scheduler.frame(0)
        step(flying)

        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(0, 10, 4))

        done(emit)
      end)
    end)

    -- a piece that flew, landed and came to rest at zero again, frames after
    -- its launch
    local function landed(launch: (any, Vector3, Vector3) -> (), impulse: Vector3, spin: Vector3)
      local flying = part()

      launch(flying, impulse, spin)
      step(flying)

      for _ = 1, 3 do
        scheduler.frame(0)
        step(flying)
      end

      flying.AssemblyLinearVelocity = Vector3.zero
      flying.AssemblyAngularVelocity = Vector3.zero

      return flying
    end

    test("a piece come to rest frames after its launch is not launched again by a pause", function()
      withForces(function()
        local emit, fx = effect()
        local launch = adapters.debris(fx)
        local resting = landed(launch, IMPULSE, SPIN)
        local spinning = landed(launch, Vector3.zero, SPIN)

        clock.setPaused(emit.clock, true)
        scheduler.frame(0)
        step(resting)
        step(spinning)

        clock.setPaused(emit.clock, false)
        scheduler.frame(0)
        step(resting)
        step(spinning)

        expect(resting.AssemblyLinearVelocity).toEqual(Vector3.zero)
        expect(resting.AssemblyAngularVelocity).toEqual(Vector3.zero)
        expect(spinning.AssemblyAngularVelocity).toEqual(Vector3.zero)

        done(emit)
      end)
    end)

    test("a piece come to rest frames after its launch is not kicked by a speed change", function()
      withForces(function()
        local emit, fx = effect()
        local launch = adapters.debris(fx)
        local resting = landed(launch, IMPULSE, SPIN)
        local spinning = landed(launch, Vector3.zero, SPIN)

        at(emit, 0.5)
        step(resting)
        step(spinning)

        at(emit, 2)
        step(resting)
        step(spinning)

        expect(resting.AssemblyLinearVelocity).toEqual(Vector3.zero)
        expect(resting.AssemblyAngularVelocity).toEqual(Vector3.zero)
        expect(spinning.AssemblyAngularVelocity).toEqual(Vector3.zero)

        done(emit)
      end)
    end)

    test("a part launched while slowed and then paused leaves at the speed it resumes at", function()
      withForces(function()
        local emit, fx = effect()
        local flying = part()
        local launch = adapters.debris(fx)

        at(emit, 0.5)
        clock.setPaused(emit.clock, true)
        scheduler.frame(0)

        launch(flying, IMPULSE, SPIN)
        step(flying)

        clock.setPaused(emit.clock, false)
        at(emit, 0.25)
        step(flying)

        expect(flying.AssemblyLinearVelocity).toEqual(Vector3.new(0, 2.5, 1))
        expect(flying.AssemblyAngularVelocity).toEqual(Vector3.new(0.25, 0, 0))

        done(emit)
      end)
    end)
  end)
end)
