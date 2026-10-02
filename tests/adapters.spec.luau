local clock = require("@mod/clock")
local harness = require("@tests/harness")
local adapters = require("@mod/adapters")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

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
end)
