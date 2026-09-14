local RunService = game:GetService("RunService")

local knob = require("@mod/knob")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")

local Shake = require("@pkg/Shake")

local activeShakes = {}
local totalShakeCF = CFrame.identity

local function updateCamera()
  if #activeShakes == 0 then
    return
  end

  local camera = workspace.CurrentCamera

  if not RunService:IsRunning() then
    camera.CFrame *= totalShakeCF:Inverse()

    -- I <3 THE STUDIO CAMERA SYSTEM !!!! YAYAY AIHU;S H;GDFAH GSDFL
    local cf = camera.CFrame
    local rx, ry = cf:ToOrientation()

    -- NO HAX ALLOWED!!!!!!!
    camera.CFrame = CFrame.new(cf.Position) * CFrame.fromOrientation(rx, ry, 0)
  end

  local totalPos = vector.zero
  local totalRot = CFrame.identity

  local stillActive = {}

  for _, v in activeShakes do
    if v.done then
      continue
    end

    totalPos += v.pos
    totalRot *= CFrame.Angles(v.rot.x, v.rot.y, v.rot.z)

    table.insert(stillActive, v)
  end

  activeShakes = stillActive

  local total = CFrame.new(totalPos) * totalRot

  if not RunService:IsRunning() then
    totalShakeCF = total
  end

  camera.CFrame *= total
end

local function always()
  return true
end

local camera_shake = {}

camera_shake.id = "camera_shake"
camera_shake.display = { name = "Camera Shake", icon = "camera_shake", order = 15 }
camera_shake.classifier = "RayValue.CameraShake"

camera_shake.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"),
  EmitDuration = knob(0):min(0):unit("seconds"),
  Falloff = knob(30):min(0):unit("studs"),
  Amplitude = knob(2.5),
  Frequency = knob(0.2),
  FadeInTime = knob(0.3):min(0):unit("seconds"),
  FadeOutTime = knob(2):min(0):unit("seconds"),
  SustainTime = knob(1):min(0):unit("seconds"),
  PositionInfluence = knob(vector.one),
  RotationInfluence = knob(vector.one * 0.2),
  Speed = knob(1):mod(),
  SpeedDuration = knob(0.1):min(0):aliases("Speed_Duration"):unit("seconds"):hidden(always),
}

camera_shake.properties = {}

camera_shake.layout = {
  { title = "Emit", entries = { "EmitDelay", "EmitDuration", "Speed" } },
  { title = "Effect", entries = { "Falloff", "Amplitude", "Frequency" } },
  { title = "Time", entries = { "FadeInTime", "FadeOutTime", "SustainTime" } },
  { title = "Influence", entries = { "PositionInfluence", "RotationInfluence" } },
}

-- how long the shake runs: its own envelope, or the emit window and the fade
-- out after it
function camera_shake.duration(_, attrs: any)
  if attrs.EmitDuration > 0 then
    return attrs.EmitDuration + attrs.FadeOutTime
  end

  return attrs.FadeInTime + attrs.SustainTime + attrs.FadeOutTime
end

local conn
local lastCameraCf

function camera_shake.init()
  if conn then
    return
  end

  if RunService:IsRunning() then
    conn = RunService.Heartbeat:Connect(function()
      if not lastCameraCf then
        return
      end

      workspace.CurrentCamera.CFrame = lastCameraCf
    end)
  end

  RunService:BindToRenderStep("forge_updateCameraShake", Enum.RenderPriority.Last.Value + 1, updateCamera)
end

function camera_shake.deinit()
  if conn then
    conn:Disconnect()
    conn = nil
  end

  RunService:UnbindFromRenderStep("forge_updateCameraShake")
end

function camera_shake.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: RayValue
  local scope = ctx.scope

  local emitDelay = attrs.EmitDelay
  local emitDuration = attrs.EmitDuration

  local falloff = attrs.Falloff

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

  local currentSpeed = 1

  local elapsed = 0

  shake.TimeFunction = function()
    return elapsed
  end

  local speed = attrs.Speed

  currentSpeed = speed.at(0)

  if speed.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, speed.duration, function(_, deltaTime, sampledAt)
        currentSpeed = speed.at(sampledAt)
        return deltaTime
      end)
    )
  end

  lifetime.hold(
    scope,
    RunService.RenderStepped:Connect(function(deltaTime)
      elapsed += deltaTime * currentSpeed
    end)
  )

  local obj = {
    done = false,
    pos = vector.zero,
    rot = vector.zero,
  }

  task.wait(emitDelay)

  table.insert(activeShakes, obj)

  local thread = coroutine.running()

  shake:BindToRenderStep(Shake.NextRenderName(), utility.RENDER_PRIORITY + scope.depth, function(pos, rot, isDone)
    local camera = workspace.CurrentCamera

    lastCameraCf = camera.CFrame

    local origin = ref:FindFirstAncestorOfClass("Attachment") or ref:FindFirstAncestorWhichIsA("BasePart")

    if origin then
      local originCFrame = utility.getTransformedOriginExtents(origin)
      local originPosition = originCFrame and originCFrame.Position or origin.Position

      local alpha = 1 - math.clamp((camera.CFrame.Position - originPosition).Magnitude / falloff, 0, 1)

      pos *= alpha
      rot *= alpha
    end

    obj.pos = pos
    obj.rot = rot
    obj.done = isDone

    if isDone then
      lastCameraCf = nil
      task.spawn(thread)
    end
  end)

  shake:Start()

  if sustained then
    task.wait(emitDuration)
    shake:StopSustain()
  end

  if not obj.done then
    coroutine.yield()
  end
end

return camera_shake
