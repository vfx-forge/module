local RunService = game:GetService("RunService")

local knob = require("@mod/knob")
local clock = require("@mod/clock")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local legacy_mods = require("@mod/legacy_mods")

local Shake = require("@pkg/Shake")

-- a falloff of zero with the camera on its origin divides zero by zero
local MIN_FALLOFF = 1e-3

-- the camera before the last frame's shakes and the camera as it read back
-- after them, kept on the camera itself so every copy of this module, in any
-- context, finds what the others wrote
local BASE_ATTRIBUTE = "ForgeShakeBase"
local WRITTEN_ATTRIBUTE = "ForgeShakeWritten"

type Active = {
  shake: typeof(Shake.new()),
  ref: RayValue,
  falloff: number?,
  thread: thread,
  timeline: clock.Clock,
  done: boolean,
}

local camera_shake = {}

camera_shake.id = "camera_shake"
camera_shake.display = { name = "Camera Shake", icon = "camera_shake", order = 30 }
camera_shake.classifier = "RayValue.CameraShake"

const function sustained(_, attrs: any)
  return attrs.EmitDuration > 0
end

const function noFalloff(_, attrs: any)
  return attrs.FalloffEnabled ~= true
end

-- v2 had no switch: every shake fell off over Falloff studs, 30 where it
-- stored none, and a negative Falloff never weakened it. only v2 wrote Falloff
-- or a Speed quad on a shake, so one storing either and no switch of its own
-- is one v2 made. a v2 shake storing neither is the same instance a new one
-- is, and rests off as a new one does
const function madeInV2(map: { [string]: any }): boolean
  if map.FalloffEnabled ~= nil then
    return false
  end

  const falloff = map.Falloff

  -- read as the reader reads it, a number stored as text included
  const distance = if type(falloff) == "string" then tonumber(falloff) else falloff

  if type(distance) == "number" and distance < 0 then
    return false
  end

  return falloff ~= nil or legacy_mods.quadded(map, "Speed")
end

camera_shake.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
  EmitDuration = knob(0):min(0):unit("seconds"):label("Duration"):hint(
    "Seconds the shake runs before it fades out. At 0 it runs its own fade in, sustain and fade out."
  ),
  Speed = knob(1):mod():label("Speed"):hint("Multiplier on the shake's clock."),
  Amplitude = knob(2.5):label("Amplitude"):hint("How hard the camera shakes."),
  Frequency = knob(0.2):label("Frequency"):hint("How fast the shake moves. Higher is jerkier."),
  PositionInfluence = knob(vector.one):label("Position"):hint("How far the shake moves the camera along each axis."),
  RotationInfluence = knob(vector.one * 0.2)
    :label("Rotation")
    :hint("How far the shake turns the camera about each axis."),
  FadeInTime = knob(0.3)
    :min(0)
    :unit("seconds")
    :label("Fade in")
    :hint("Seconds the shake takes to reach full strength."),
  SustainTime = knob(1)
    :min(0)
    :unit("seconds")
    :hidden(sustained)
    :label("Sustain")
    :hint("Seconds the shake holds at full strength."),
  FadeOutTime = knob(2):min(0):unit("seconds"):label("Fade out"):hint("Seconds the shake takes to die away."),
  FalloffEnabled = knob
    .legacy(knob(false), function(ctx: reader.Ctx)
      return madeInV2(reader.source(ctx.ref))
    end)
    :label("Enabled")
    :hint("Whether the shake weakens as the camera gets farther from it. Off, every camera shakes at full strength."),
  FalloffDistance = knob(30)
    :min(0)
    :aliases("Falloff")
    :unit("studs")
    :hidden(noFalloff)
    :label("Distance")
    :hint("Studs from the shake at which it dies away completely, weakening evenly on the way."),
}

camera_shake.properties = {}

camera_shake.layout = {
  { title = "Emit", entries = { "EmitDelay", "EmitDuration", "Speed" } },
  {
    title = "Shake",
    entries = {
      "Amplitude",
      "Frequency",
      { title = "Influence", entries = { "PositionInfluence", "RotationInfluence" } },
    },
  },
  { title = "Envelope", entries = { "FadeInTime", "SustainTime", "FadeOutTime" } },
  { title = "Falloff", entries = { "FalloffEnabled", "FalloffDistance" } },
}

-- what the plugin writes when it converts a shake v2 made, so the shake keeps
-- falling off once the old shapes that mark it are gone
function camera_shake.legacyValues(map: { [string]: any }): { [string]: any }?
  return if madeInV2(map) then { FalloffEnabled = true } else nil
end

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

-- the hooks game code reads the shake through, which keep the camera unwritten
local hooks: { lifetime.WriteHook } = {}

-- in the editor, the shake the last frame applied, taken back off before the
-- next one is applied
local totalShakeCF = CFrame.identity

-- a camera that no longer reads back the last write was written by somebody
-- else since, and keeps what they wrote
local function undo()
  local camera = workspace.CurrentCamera
  local written = camera:GetAttribute(WRITTEN_ATTRIBUTE)

  if written == nil then
    return
  end

  local base = camera:GetAttribute(BASE_ATTRIBUTE)

  if base ~= nil and camera.CFrame == written then
    camera.CFrame = base
  end

  camera:SetAttribute(BASE_ATTRIBUTE, nil)
  camera:SetAttribute(WRITTEN_ATTRIBUTE, nil)
end

-- every running shake one frame on: the shakes summed as one CFrame, and the
-- threads of those that ended, taken out of the list
local function advance(camera: any): (CFrame, { thread }?)
  local totalPos = Vector3.zero
  local totalRot = CFrame.identity

  local stillActive = {}
  local finished: { thread }? = nil

  for _, active in activeShakes do
    local pos, rot, isDone = active.shake:Update()

    -- a Speed resting at 0 for good ends the shake outright, with no fade
    if active.timeline.halted then
      isDone = true
    end

    local falloff = active.falloff
    local origin = if falloff
      then active.ref:FindFirstAncestorOfClass("Attachment") or active.ref:FindFirstAncestorWhichIsA("BasePart")
      else nil

    if falloff and origin then
      local originCFrame = utility.getTransformedOriginExtents(origin)
      local originPosition = originCFrame and originCFrame.Position or origin.Position

      local alpha = 1 - math.clamp((camera.CFrame.Position - originPosition).Magnitude / falloff, 0, 1)

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

  return CFrame.new(totalPos) * totalRot, finished
end

-- woken once the list is settled, since a body that ends here takes its shake
-- out of it
local function wake(finished: { thread }?)
  if finished == nil then
    return
  end

  for _, thread in finished do
    task.spawn(thread)
  end
end

local function apply()
  if #hooks > 0 then
    return
  end

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

  local total, finished = advance(camera)

  if running then
    local current = camera.CFrame
    local base = camera:GetAttribute(BASE_ATTRIBUTE)

    -- a camera still reading back another copy's shake this frame goes back
    -- to where that copy found it
    local before = if base ~= nil and current == camera:GetAttribute(WRITTEN_ATTRIBUTE) then base else current

    camera.CFrame = current * total

    camera:SetAttribute(BASE_ATTRIBUTE, before)
    camera:SetAttribute(WRITTEN_ATTRIBUTE, camera.CFrame)
  else
    totalShakeCF = total
    camera.CFrame *= total
  end

  wake(finished)
end

-- with a hook connected the shake goes to game code in the compute phase,
-- after every effect's own step, and the camera is never written. a shake
-- the editor already applied comes back off first
local function offer()
  if #hooks == 0 then
    return
  end

  local camera = workspace.CurrentCamera

  if totalShakeCF ~= CFrame.identity then
    camera.CFrame *= totalShakeCF:Inverse()
    totalShakeCF = CFrame.identity
  end

  local total = CFrame.identity
  local finished: { thread }? = nil

  if #activeShakes > 0 then
    total, finished = advance(camera)
  end

  local active = #activeShakes > 0

  for _, hook in hooks do
    hook.Active = active
    hook.Offset = if active then total else CFrame.identity
  end

  wake(finished)
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

  table.insert(steps, scheduler.add("undo", undo, 0, nil, true))
  table.insert(steps, scheduler.add("compute", offer, math.huge, nil, true))
  table.insert(steps, scheduler.add("shake", apply, 0, nil, true))
end

local function quiet(hook: lifetime.WriteHook)
  hook.Connected = false
  hook.Active = false
  hook.Offset = CFrame.identity
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

  for _, hook in hooks do
    quiet(hook)
  end

  table.clear(hooks)

  -- a shake left here would be applied again, from where its clock stopped,
  -- by the next init
  table.clear(activeShakes)
  disconnectSteps()
end

local function unhook(hook: lifetime.WriteHook)
  if not hook.Connected then
    return
  end

  quiet(hook)

  local index = table.find(hooks, hook)

  if index then
    table.remove(hooks, index)
  end
end

-- the shake as an Offset game code applies itself, while the camera is left
-- alone; it has no Value and no Priority
function camera_shake.hook(): lifetime.WriteHook
  local hook: lifetime.WriteHook = {
    Connected = true,
    Active = #activeShakes > 0,
    Value = nil,
    Offset = CFrame.identity,
    Priority = nil,
    Disconnect = unhook,
  }

  table.insert(hooks, hook)

  return hook
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

  lifetime.wait(scope, attrs.EmitDelay)

  lifetime.speed(scope, attrs.Speed)

  -- the shake's own time is the effect's clock, so a pause holds the camera
  -- where the shake has it
  lifetime.step(scope, function(deltaTime: number)
    elapsed += deltaTime
  end)

  local active: Active = {
    shake = shake,
    ref = ref,
    falloff = if attrs.FalloffEnabled then math.max(attrs.FalloffDistance, MIN_FALLOFF) else nil,
    thread = coroutine.running(),
    timeline = scope.clock,
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
