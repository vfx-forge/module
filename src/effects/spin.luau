local mod = require("@mod/mod")
local knob = require("@mod/knob")
local lazy = require("@mod/lazy")

-- Model:ScaleTo is invalid at zero or below, and the runtime can reach that
-- where the authoring UI cannot: a chained modifier or a randomizer with a bad
-- range evaluates to whatever it evaluates to
local MIN_SCALE = 0.001

local function always()
  return true
end

local spin = {}

const play = lazy.unit("model_spin", function()
  return require("@root/play/spin").bind(spin)
end)

spin.id = "model_spin"
spin.display = { name = "Model", icon = "model_spin", order = 10 }

-- every model that is not a mesh effect, which is a model with a Start and an
-- End part directly under it
spin.classifier = "Model:not(Model:has(> BasePart#Start):has(> BasePart#End))"

spin.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
  ResetDelay = knob(0)
    :min(0)
    :unit("seconds")
    :label("ResetDelay")
    :hint("Extra seconds to hold the finished pose before resetting."),
  ResetOnFinish = knob(true):label("ResetOnFinish"):hint("Whether to reset the effect state after it finishes."),
  SpinRotation = knob(vector.zero)
    :unit("perSecond")
    :label("Rotation")
    :hint("Per-axis spin speed in degrees per second."),
  SpinDuration = knob(0.5)
    :min(0)
    :unit("seconds")
    :label("Duration")
    :hint("Seconds the rotation sweep takes to complete."),
  SyncPosition = knob(false):label("SyncPosition"):hint("Whether the effect follows the emitter's position."),
  Scale = knob(1):min(MIN_SCALE):mod():label("Scale"):hint("Model scale factor over the spin."),
  -- an unauthored model rests on a ramp from nought to one, and that ramp is
  -- load bearing: a speed that is zero for good returns nil from the rotation
  -- timer's counter and stops it on frame one
  SpinSpeed = knob(1)
    :mod(mod.from(0):duration(function(_, attrs)
      return attrs.SpinSpeedDuration
    end))
    :label("Speed")
    :hint("Multiplier on the spin's clock over its duration."),
  SpinSpeedDuration = knob(0.1):min(0):aliases("SpinSpeed_Duration"):unit("seconds"):hidden(always),
}

spin.properties = {}

spin.layout = {
  { title = "Emit", entries = { "EmitDelay", "ResetDelay", "ResetOnFinish" } },
  { title = "Spin", entries = { "SpinRotation", "SpinDuration", "SpinSpeed", "SyncPosition", "Scale" } },
}

function spin.duration(_, attrs: any)
  return attrs.SpinDuration
end

-- a model nothing moves: no rotation, a scale resting at one, no following.
-- a speed alone turns nothing
function spin.static(attrs: any)
  return attrs.SpinRotation == vector.zero
    and not attrs.Scale.animated
    and attrs.Scale.value == 1
    and not attrs.SyncPosition
end

function spin.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

return spin
