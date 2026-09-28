local RunService = game:GetService("RunService")

local knob = require("@mod/knob")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")

local Shake = require("@pkg/Shake")

-- a falloff of zero with the camera on its origin divides zero by zero
local MIN_FALLOFF = 1e-3

type Active = {
  shake: typeof(Shake.new()),
  ref: RayValue,
  falloff: number,
  thread: thread,
  done: boolean,
}

local function always()
  return true
end

local camera_shake = {}

camera_shake.id = "camera_shake"
camera_shake.display = { name = "Camera Shake", icon = "camera_shake", order = 30 }
camera_shake.classifier = "RayValue.CameraShake"

camera_shake.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
  EmitDuration = knob(0):min(0):unit("seconds"):label("Duration"):hint("Duration of the emit cycle in seconds."),
  Falloff = knob(30)
    :min(0)
    :unit("studs")
    :label("Falloff")
    :hint("How quickly the shake intensity decreases over distance."),
  Amplitude = knob(2.5):label("Amplitude"):hint("Intensity of the screen shake."),
  Frequency = knob(0.2):label("Frequency"):hint("Speed of the screen shake oscillation."),
  FadeInTime = knob(0.3):min(0):unit("seconds"):label("FadeIn"):hint("Duration to fade into the shake effect."),
  FadeOutTime = knob(2):min(0):unit("seconds"):label("FadeOut"):hint("Duration to fade out of the shake effect."),
  SustainTime = knob(1):min(0):unit("seconds"):label("Sustain"):hint("Duration to hold the shake at full intensity."),
  PositionInfluence = knob(vector.one):label("Position"):hint("Per-axis multiplier for positional shake."),
  RotationInfluence = knob(vector.one * 0.2):label("Rotation"):hint("Per-axis multiplier for rotational shake."),
  Speed = knob(1):mod():label("Speed"):hint("Multiplier on the shake's clock."),
  SpeedDuration = knob(0.1):min(0):aliases("Speed_Duration"):unit("seconds"):hidden(always),
}

camera_shake.properties = {}

camera_shake.layout = {
  { title = "Emit", entries = { "EmitDelay", "EmitDuration", "Speed" } },
  {
    title = "Effect",
    entries = {
      "Falloff",
      "Amplitude",
      "Frequency",
      { title = "Time", entries = { "FadeInTime", "FadeOutTime", "SustainTime" } },
      { title = "Influence", entries = { "PositionInfluence", "RotationInfluence" } },
    },
  },
}

-- how long the shake runs: its own envelope, or the emit window and the fade
-- out after it
function camera_shake.duration(_, attrs: any)
  if attrs.EmitDuration > 0 then
    return attrs.EmitDuration + attrs.FadeOutTime
  end

  return attrs.FadeInTime + attrs.SustainTime + attrs.FadeOutTime
end

local activeShakes: { Active } = {}
local steps: { scheduler.Handle } = {}

-- in the editor, the shake the last frame applied, taken back off before the
-- next one is applied
local totalShakeCF = CFrame.identity

-- in a running game, the camera before the last shake and the camera as it
-- read back after it. a camera that no longer reads back that way was written
-- by somebody else since, and keeps what they wrote
local base: CFrame? = nil
local written: CFrame? = nil

local function undo()
  local was = base

  if was == nil then
    return
  end

  local camera = workspace.CurrentCamera

  if camera.CFrame == written then
    camera.CFrame = was
  end

  base = nil
  written = nil
end

local function apply()
  local running = RunService:IsRunning()

  if #activeShakes == 0 and (running or totalShakeCF == CFrame.identity) then
    return
  end

  local camera = workspace.CurrentCamera

  if not running then
    camera.CFrame *= totalShakeCF:Inverse()

    -- forgotten as soon as it is off, so a frame that throws past here is
    -- not taken off the camera a second time by the next
    totalShakeCF = CFrame.identity

    -- I <3 THE STUDIO CAMERA SYSTEM !!!! YAYAY AIHU;S H;GDFAH GSDFL
    local cf = camera.CFrame
    local rx, ry = cf:ToOrientation()

    -- NO HAX ALLOWED!!!!!!!
    camera.CFrame = CFrame.new(cf.Position) * CFrame.fromOrientation(rx, ry, 0)
  end

  local totalPos = Vector3.zero
  local totalRot = CFrame.identity

  local stillActive = {}
  local finished: { thread }? = nil

  for _, active in activeShakes do
    local pos, rot, isDone = active.shake:Update()
    local origin = active.ref:FindFirstAncestorOfClass("Attachment") or active.ref:FindFirstAncestorWhichIsA("BasePart")

    if origin then
      local originCFrame = utility.getTransformedOriginExtents(origin)
      local originPosition = originCFrame and originCFrame.Position or origin.Position

      local alpha = 1 - math.clamp((camera.CFrame.Position - originPosition).Magnitude / active.falloff, 0, 1)

      pos *= alpha
      rot *= alpha
    end

    if isDone then
      active.done = true
      finished = finished or {}
      table.insert(finished :: { thread }, active.thread)

      continue
    end

    totalPos += pos
    totalRot *= CFrame.Angles(rot.X, rot.Y, rot.Z)

    table.insert(stillActive, active)
  end

  activeShakes = stillActive

  local total = CFrame.new(totalPos) * totalRot

  if running then
    local before = camera.CFrame

    camera.CFrame = before * total

    base = before
    written = camera.CFrame
  else
    totalShakeCF = total
    camera.CFrame *= total
  end

  if finished == nil then
    return
  end

  -- woken once the list is settled, since a body that ends here takes its
  -- shake out of it
  for _, thread in finished do
    task.spawn(thread)
  end
end

local function disconnectSteps()
  for _, step in steps do
    step:Disconnect()
  end

  table.clear(steps)
end

function camera_shake.init()
  if #steps > 0 then
    return
  end

  if RunService:IsRunning() then
    table.insert(steps, scheduler.add("undo", undo, 0, nil, true))
  end

  table.insert(steps, scheduler.add("shake", apply, 0, nil, true))
end

-- the steps that would take the last shake off go with it, so it is taken
-- off here
function camera_shake.deinit()
  undo()

  if totalShakeCF ~= CFrame.identity then
    local camera = workspace.CurrentCamera

    camera.CFrame *= totalShakeCF:Inverse()
    totalShakeCF = CFrame.identity
  end

  -- a shake left here would be applied again, from where its clock stopped,
  -- by the next init
  table.clear(activeShakes)
  disconnectSteps()
end

function camera_shake.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: RayValue
  local scope = ctx.scope

  local emitDuration = attrs.EmitDuration
  local sustained = emitDuration > 0

  local shake = Shake.new()
  shake.Sustain = sustained
  shake.Amplitude = attrs.Amplitude
  shake.Frequency = attrs.Frequency
  shake.FadeInTime = attrs.FadeInTime
  shake.FadeOutTime = attrs.FadeOutTime
  shake.SustainTime = attrs.SustainTime
  shake.PositionInfluence = attrs.PositionInfluence
  shake.RotationInfluence = attrs.RotationInfluence

  local elapsed = 0

  shake.TimeFunction = function()
    return elapsed
  end

  local speed = attrs.Speed
  local currentSpeed = speed.at(0)

  if speed.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, speed.duration, function(_, deltaTime, sampledAt)
        currentSpeed = speed.at(sampledAt)
        return deltaTime
      end)
    )
  end

  lifetime.step(scope, function(deltaTime: number)
    elapsed += deltaTime * currentSpeed
  end)

  lifetime.wait(scope, attrs.EmitDelay)

  local active: Active = {
    shake = shake,
    ref = ref,
    falloff = math.max(attrs.Falloff, MIN_FALLOFF),
    thread = coroutine.running(),
    done = false,
  }

  table.insert(activeShakes, active)

  -- a shake cleared before it is done stops with its effect
  lifetime.hold(scope, function()
    local index = table.find(activeShakes, active)

    if index then
      table.remove(activeShakes, index)
    end
  end)

  shake:Start()

  if sustained then
    lifetime.wait(scope, emitDuration)
    shake:StopSustain()
  end

  if not active.done then
    coroutine.yield()
  end
end

return camera_shake
