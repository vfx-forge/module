local fs = require("@lune/fs")
local luau = require("@lune/luau")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local camera_shake = require("@vfx/camera_shake")

local Shake = require("@pkg/Shake")
local test, expect = harness.test, harness.expect
local CFrame = harness.datatypes.CFrame
local Vector3 = harness.datatypes.Vector3
local Instance = harness.datatypes.Instance

local RunService = game:GetService("RunService")
local camera = workspace.CurrentCamera

local BASE = CFrame.new(0, 5, 10)

local function notRunning()
  return false
end

local function running()
  return true
end

local function unit()
  return 1
end

-- the rows as the reader answers them, the influences as the Vector3 the
-- vendored Shake multiplies by
local function rows(falloff: number)
  return {
    EmitDelay = 0,
    EmitDuration = 0,
    Falloff = falloff,
    Amplitude = 2.5,
    Frequency = 0.2,
    FadeInTime = 0.3,
    FadeOutTime = 2,
    SustainTime = 1,
    PositionInfluence = Vector3.one,
    RotationInfluence = Vector3.one * 0.2,
    Speed = { animated = false, at = unit },
  }
end

-- a copy of a module loaded afresh, as a game's copy beside the plugin's,
-- with the requires named in `own` answered by the copy's own modules
local function load(path: string, own: { [string]: any }): any
  local env = setmetatable({
    require = function(name: string)
      return own[name] or require(name)
    end,
  }, { __index = getfenv(1) })

  return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

local otherScheduler = load("src/mod/scheduler.luau", {})
local otherShake = load("src/effects/camera_shake.luau", { ["@mod/scheduler"] = otherScheduler })

local function shakeWith(module: any, parent: Instance?, falloff: number): lifetime.effect
  local ref = Instance.new("RayValue")
  ref.Parent = parent

  local fx = lifetime.effect(lifetime.emit(nil), 0, nil)

  lifetime.run(fx, function(effect: lifetime.effect)
    module.emit({ ref = ref, scope = effect } :: any, rows(falloff))
  end)

  return fx
end

local function shake(parent: Instance?, falloff: number): lifetime.effect
  return shakeWith(camera_shake, parent, falloff)
end

local function frames(count: number)
  for _ = 1, count do
    scheduler.frame(0.1)
  end
end

local function near(a: CFrame, b: CFrame): boolean
  return (a.Position - b.Position).Magnitude < 1e-4
    and (a.LookVector - b.LookVector).Magnitude < 1e-4
    and (a.UpVector - b.UpVector).Magnitude < 1e-4
end

-- a session starts from a still camera with no steps of its own
local function start(isRunning: () -> boolean)
  RunService.IsRunning = isRunning
  camera.CFrame = BASE
  camera_shake.init()
end

local function finish(fx: lifetime.effect)
  lifetime.release(fx)
  camera_shake.deinit()
  RunService.IsRunning = notRunning
end

harness.suite(function()
  harness.describe("camera_shake", function()
    test("deinit takes the last shake off the editor camera", function()
      start(notRunning)

      local fx = shake(nil, 30)
      frames(3)

      expect(near(camera.CFrame, BASE)).toBe(false)

      finish(fx)

      expect(near(camera.CFrame, BASE)).toBe(true)
    end)

    test("deinit puts a running game's camera back to where the shake found it", function()
      start(running)

      local fx = shake(nil, 30)
      frames(3)

      expect(near(camera.CFrame, BASE)).toBe(false)

      finish(fx)

      expect(camera.CFrame == BASE).toBe(true)
    end)

    test("a copy started in the editor undoes its shakes once the game runs", function()
      start(notRunning)
      RunService.IsRunning = running

      local fx = shake(nil, 30)
      frames(3)

      expect(near(camera.CFrame, BASE)).toBe(false)

      scheduler.compute(0.1)

      expect(camera.CFrame == BASE).toBe(true)

      finish(fx)
    end)

    test("a running game keeps a camera somebody else wrote after the shake", function()
      start(running)

      local fx = shake(nil, 30)
      frames(3)

      local other = CFrame.new(7, 8, 9)
      camera.CFrame = other

      finish(fx)

      expect(camera.CFrame == other).toBe(true)
    end)

    test("a shake step that throws keeps shaking once the camera is sound again", function()
      start(notRunning)

      local fx = shake(nil, 30)

      -- a camera with no CFrame to multiply makes the shake step throw
      local warnings = harness.captureWarnings(function()
        camera.CFrame = nil :: any
        frames(2)
      end)

      expect(#warnings).toBe(1)

      camera.CFrame = BASE
      frames(1)

      expect(near(camera.CFrame, BASE)).toBe(false)

      finish(fx)
    end)

    test("an editor frame whose shake throws leaves the camera on its base once the shake ends", function()
      start(notRunning)

      local fx = shake(nil, 30)
      frames(3)

      -- the vendored module hands out no class, so it is patched through an
      -- instance's metatable
      local class = getmetatable(Shake.new() :: any)
      local update = class.Update

      class.Update = function()
        error("boom")
      end

      local warnings = harness.captureWarnings(function()
        frames(1)
      end)

      class.Update = update

      expect(#warnings).toBe(1)
      expect(near(camera.CFrame, BASE)).toBe(true)

      -- past the whole envelope, fade in, sustain and fade out
      frames(40)

      expect(near(camera.CFrame, BASE)).toBe(true)

      finish(fx)
    end)

    test("a deinit then an init does not apply the shake the deinit left", function()
      start(notRunning)

      local fx = shake(nil, 30)
      frames(3)

      camera_shake.deinit()
      camera_shake.init()
      frames(3)

      expect(near(camera.CFrame, BASE)).toBe(true)

      finish(fx)
    end)

    -- each copy undoes on its own scheduler at First and shakes at Last + 1,
    -- in either order for either half
    for _, orders in { { false, false }, { false, true }, { true, false }, { true, true } } do
      local undoFlipped, shakeFlipped = orders[1], orders[2]
      local undoing = if undoFlipped then "theirs" else "ours"
      local shaking = if shakeFlipped then "theirs" else "ours"

      test(`two copies leave one camera on its base, {undoing} undoing first and {shaking} shaking first`, function()
        start(running)
        otherShake.init()

        local ours = shake(nil, 30)
        local theirs = shakeWith(otherShake, nil, 30)

        local first = if undoFlipped then otherScheduler else scheduler
        local second = if undoFlipped then scheduler else otherScheduler
        local shaken = 0
        local unshaken = 0

        -- past the whole envelope, fade in, sustain and fade out
        for _ = 1, 40 do
          first.compute(0.1)
          second.compute(0.1)

          if camera.CFrame ~= BASE then
            unshaken += 1
          end

          if shakeFlipped then
            otherScheduler.late(0.1)
            scheduler.late(0.1)
          else
            scheduler.late(0.1)
            otherScheduler.late(0.1)
          end

          if not near(camera.CFrame, BASE) then
            shaken += 1
          end
        end

        first.compute(0.1)
        second.compute(0.1)

        local settled = camera.CFrame == BASE

        lifetime.release(theirs)
        otherShake.deinit()
        otherScheduler.stop()
        finish(ours)

        expect(shaken > 0).toBe(true)
        expect(unshaken).toBe(0)
        expect(settled).toBe(true)
      end)
    end

    test("a falloff of zero with the camera on its origin shakes rather than NaN", function()
      start(notRunning)

      local part = Instance.new("Part")
      part.CFrame = BASE

      local fx = shake(part, 0)
      frames(1)

      local position = camera.CFrame.Position

      expect(position.X == position.X and position.Y == position.Y and position.Z == position.Z).toBe(true)
      expect(near(camera.CFrame, BASE)).toBe(false)

      finish(fx)
    end)
  end)
end)
