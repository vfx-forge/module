local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local timing_common = require("@mod/common/timing")

-- Model:ScaleTo is invalid at zero or below, and the runtime can reach that
-- where the authoring UI cannot: a chained modifier or a randomizer with a bad
-- range evaluates to whatever it evaluates to. the floor matches the bound the
-- plugin's own schema already declares on Scale_Start and Scale_End
local MIN_SCALE = 0.001

local spin = {}

-- both knobs spin drives itself, so emitters.applyMods leaves them alone
spin.OWNS = {
  attribute = {
    Scale = true,
    SpinSpeed = true,
  },
}

function spin.emit(ref: Model, scope: types.scope)
  if utility.isSpinModelStatic(ref) then
    return
  end

  local rotation = attr.get(ref, "SpinRotation", vector.zero) * utility.DEG_TO_RAD

  local emitDelay = attr.get(ref, "EmitDelay", 0)
  local resetDelay = attr.get(ref, "ResetDelay", 0)
  local resetOnFinish = attr.get(ref, "ResetOnFinish", true)

  local sync = attr.get(ref, "SyncPosition", false)
  local duration = attr.get(ref, "SpinDuration", 0.5)

  local speedDuration = attr.get(ref, "SpinSpeed_Duration", 0.1, true)

  task.wait(emitDelay)

  -- an unauthored model rests on a ramp from nought to one, and that ramp is
  -- load bearing: a speed that is zero for good returns nil from the rotation
  -- timer's counter and stops it on frame one
  local speed = mods.track(ref, "attribute", "SpinSpeed", mods.ramp(0, 1), speedDuration)
  local speedTween
  local currentSpeed = speed.at(0)

  if speed.animated then
    speedTween = tween.fromParams(utility.linear_bezier, speed.span, function(_, deltaTime, elapsed)
      currentSpeed = speed.at(elapsed)
      return deltaTime
    end)

    lifetime.hold(scope, speedTween)
  end

  local originalPivot = ref:GetPivot()
  local originalScale = ref:GetScale()

  local scale = mods.track(ref, "attribute", "Scale", 1, duration)

  if scale.animated then
    -- fromParams, not timer: timer yields until it finishes, and the rotation
    -- timer below is the last statement in this function
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, scale.span, function(_, deltaTime, elapsed)
        local v = scale.at(elapsed)

        -- a queue that stops resolving partway would throw here every frame, and
        -- a stepper that throws is never cleaned up
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
  end, speedTween, scope, utility.RENDER_PRIORITY + scope.depth)
end

return spin
