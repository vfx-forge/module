local knob = require("@mod/knob")
local lazy = require("@mod/lazy")
local reader = require("@mod/reader")
local legacy_mods = require("@mod/legacy_mods")

local camera_shake = {}

const play = lazy.unit("camera_shake", function()
  return require("@root/play/camera_shake")
end, function(module: any)
  module.init()
end)

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

function camera_shake.init()
  return play().init()
end

-- nothing to stop before its first load
function camera_shake.deinit()
  if lazy.loaded("camera_shake") then
    play().deinit()
  end
end

function camera_shake.hook()
  return play().hook()
end

function camera_shake.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

return camera_shake
