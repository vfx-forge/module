local fs = require("@lune/fs")
local luau = require("@lune/luau")
local reader = require("@mod/reader")
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
-- vendored Shake multiplies by. a falloff of nil leaves it off
local function rows(falloff: number?)
  return {
    EmitDelay = 0,
    EmitDuration = 0,
    FalloffEnabled = falloff ~= nil,
    FalloffDistance = falloff or 30,
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

local function shakeWith(module: any, parent: Instance?, falloff: number?): lifetime.effect
  local ref = Instance.new("RayValue")
  ref.Parent = parent

  local fx = lifetime.effect(lifetime.emit(nil), 0, nil)

  lifetime.run(fx, function(effect: lifetime.effect)
    module.emit({ ref = ref, scope = effect } :: any, rows(falloff))
  end)

  return fx
end

local function shake(parent: Instance?, falloff: number?): lifetime.effect
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
        local left = next((camera :: any):GetAttributes())

        lifetime.release(theirs)
        otherShake.deinit()
        otherScheduler.stop()
        finish(ours)

        expect(shaken > 0).toBe(true)
        expect(unshaken).toBe(0)
        expect(settled).toBe(true)
        expect(left).toBe(nil)
      end)
    end

    test("two copies leave a camera another script wrote between frames where it was written", function()
      start(running)
      otherShake.init()

      local ours = shake(nil, 30)
      local theirs = shakeWith(otherShake, nil, 30)
      local kept = 0

      for i = 1, 10 do
        scheduler.compute(0.1)
        otherScheduler.compute(0.1)

        if camera.CFrame == CFrame.new(i - 1, 0, 0) then
          kept += 1
        end

        scheduler.late(0.1)
        otherScheduler.late(0.1)

        camera.CFrame = CFrame.new(i, 0, 0)
      end

      scheduler.compute(0.1)
      otherScheduler.compute(0.1)

      local last = camera.CFrame
      local left = next((camera :: any):GetAttributes())

      lifetime.release(theirs)
      otherShake.deinit()
      otherScheduler.stop()
      finish(ours)

      expect(kept).toBe(9)
      expect(last == CFrame.new(10, 0, 0)).toBe(true)
      expect(left).toBe(nil)
    end)

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

    test("a camera past the falloff distance stays still", function()
      start(notRunning)

      local part = Instance.new("Part")
      part.CFrame = BASE + Vector3.new(500, 0, 0)

      local fx = shake(part, 30)
      frames(3)

      expect(near(camera.CFrame, BASE)).toBe(true)

      finish(fx)
    end)

    -- v2 fell off over Falloff studs with no switch. a shake storing what
    -- only v2 wrote, Falloff or a Speed quad, and no switch falls off so; any
    -- other reads the switch as a new shake does, off unless stored on
    test("a shake carrying what only v2 wrote falls off as v2 did, any other as stored", function()
      for _, case in
        {
          { attrs = {}, on = false, distance = 30 },
          { attrs = { Falloff = 30 }, on = true, distance = 30 },
          { attrs = { Falloff = 50 }, on = true, distance = 50 },
          { attrs = { Speed_Start = 0.5, Speed_End = 1 }, on = true, distance = 30 },
          { attrs = { Speed_Duration = 0.4 }, on = true, distance = 30 },
          { attrs = { Falloff = -5 }, on = false, distance = 0 },
          { attrs = { Falloff = 30, FalloffEnabled = false }, on = false, distance = 30 },
          { attrs = { FalloffDistance = 20 }, on = false, distance = 20 },
          { attrs = { FalloffEnabled = true, FalloffDistance = 20 }, on = true, distance = 20 },
        }
      do
        local ref = Instance.new("RayValue")

        for k, v in case.attrs do
          ref:SetAttribute(k, v)
        end

        local attrs = reader.resolve(camera_shake :: any, { ref = ref, obj = ref, effect = camera_shake } :: any)
        local writes = camera_shake.legacyValues(ref:GetAttributes())

        expect(attrs.FalloffEnabled).toBe(case.on)
        expect(attrs.FalloffDistance).toBe(case.distance)
        expect(writes ~= nil).toBe(case.on and case.attrs.FalloffEnabled == nil)
      end
    end)

    test("with falloff off a camera far from the shake shakes all the same", function()
      start(notRunning)

      local part = Instance.new("Part")
      part.CFrame = BASE + Vector3.new(500, 0, 0)

      local fx = shake(part, nil)
      frames(3)

      expect(near(camera.CFrame, BASE)).toBe(false)

      finish(fx)
    end)

    for _, duration in { 0, 5 } do
      test(
        `a Speed resting at 0 ends the shake outright and the camera goes back, with an emit duration of {duration}`,
        function()
          start(notRunning)

          local ref = Instance.new("RayValue")
          local fx = lifetime.effect(lifetime.emit(nil), 0, nil)
          local row = rows(30)

          row.EmitDuration = duration
          row.Speed = {
            animated = false,
            at = function()
              return 0
            end,
          }

          lifetime.run(fx, function(effect: lifetime.effect)
            camera_shake.emit({ ref = ref, scope = effect } :: any, row)
          end)

          frames(3)

          expect(fx.state == lifetime.RUNNING).toBe(false)
          expect(near(camera.CFrame, BASE)).toBe(true)

          finish(fx)
        end
      )
    end

    test("a hook takes the shake as an Offset and the camera is left alone", function()
      start(running)

      local hook = camera_shake.hook()
      local fx = shake(nil, 30)

      frames(3)

      expect(near(camera.CFrame, BASE)).toBe(true)
      expect(hook.Active).toBe(true)
      expect(hook.Value).toBe(nil)
      expect(hook.Priority).toBe(nil)
      expect(near(hook.Offset, CFrame.identity)).toBe(false)

      hook:Disconnect()
      frames(1)

      expect(near(camera.CFrame, BASE)).toBe(false)

      finish(fx)
    end)

    test("a hooked shake is ready by the end of the compute phase", function()
      start(running)

      local hook = camera_shake.hook()
      local fx = shake(nil, 30)

      frames(2)

      local before = hook.Offset

      scheduler.compute(0.1)

      expect(near(hook.Offset, before)).toBe(false)

      scheduler.late(0.1)
      hook:Disconnect()
      finish(fx)
    end)

    test("a hook made in the editor takes the shake already applied back off", function()
      start(notRunning)

      local fx = shake(nil, 30)

      frames(2)

      expect(near(camera.CFrame, BASE)).toBe(false)

      local hook = camera_shake.hook()

      frames(1)

      expect(near(camera.CFrame, BASE)).toBe(true)

      hook:Disconnect()
      finish(fx)
    end)

    test("a hook with no shake running is inactive at the identity, and deinit disconnects it", function()
      start(running)

      local hook = camera_shake.hook()

      frames(1)

      expect(hook.Active).toBe(false)
      expect(hook.Offset).toEqual(CFrame.identity)

      camera_shake.deinit()

      expect(hook.Connected).toBe(false)

      RunService.IsRunning = notRunning
    end)
  end)
end)
