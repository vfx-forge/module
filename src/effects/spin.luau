local mod = require("@mod/mod")
local knob = require("@mod/knob")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local timing_common = require("@mod/common/timing")

-- Model:ScaleTo is invalid at zero or below, and the runtime can reach that
-- where the authoring UI cannot: a chained modifier or a randomizer with a bad
-- range evaluates to whatever it evaluates to
local MIN_SCALE = 0.001

local function always()
  return true
end

local spin = {}

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
  ScaleDuration = knob():aliases("Scale_Duration"):unit("seconds"):hidden(always),
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
  { title = "Spin", entries = { "SpinRotation", "SpinDuration", "SpinSpeed", "SyncPosition" } },
  { title = "Scale", entries = { "Scale" } },
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

function spin.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: Model
  local scope = ctx.scope

  if lifetime.lock(scope, ref) or spin.static(attrs) then
    return
  end

  local rotation = attrs.SpinRotation * utility.DEG_TO_RAD

  local resetDelay = attrs.ResetDelay
  local resetOnFinish = attrs.ResetOnFinish

  local sync = attrs.SyncPosition
  local duration = attrs.SpinDuration

  task.wait(attrs.EmitDelay)

  local speed = attrs.SpinSpeed
  local speedTween
  local currentSpeed = speed.at(0)

  if speed.animated then
    speedTween = tween.fromParams(utility.linear_bezier, speed.duration, function(_, deltaTime, elapsed)
      currentSpeed = speed.at(elapsed)
      return deltaTime
    end)

    lifetime.hold(scope, speedTween)
  end

  local originalPivot = ref:GetPivot()
  local originalScale = ref:GetScale()

  local scale = attrs.Scale

  if scale.animated then
    -- fromParams, not timer: timer yields until it finishes, and the rotation
    -- timer below is the last statement in this function
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, scale.duration, function(_, deltaTime, elapsed)
        local v = scale.at(elapsed)

        -- a queue that stops resolving partway would throw here every frame,
        -- and a stepper that throws is never cleaned up
        if typeof(v) == "number" then
          ref:ScaleTo(math.max(v, MIN_SCALE))
        end

        return deltaTime
      end)
    )
  else
    ref:ScaleTo(math.max(scale.at(0), MIN_SCALE))
  end

  local parent = ref:FindFirstAncestorOfClass("Attachment") or ref:FindFirstAncestorWhichIsA("BasePart")

  if resetOnFinish then
    lifetime.hold(scope, function()
      ref:PivotTo(parent and utility.getTransformedOriginExtents(parent) or originalPivot)
      ref:ScaleTo(originalScale)
    end)
  end

  rotation *= duration

  tween.timer(duration + resetDelay, function(deltaTime, elapsed)
    local alpha = timing_common.progress(elapsed, duration)

    local r = rotation * alpha
    local cf = (if parent and sync then utility.getTransformedOriginExtents(parent) else originalPivot)
      * CFrame.fromOrientation(r.x, r.y, r.z)

    ref:PivotTo(cf)

    return if currentSpeed > 0 or (speedTween ~= nil and elapsed > 0 and speedTween.Connected)
      then deltaTime * currentSpeed
      else nil
  end, speedTween, scope, scope.depth)
end

return spin
