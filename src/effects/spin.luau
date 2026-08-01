local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local utility = require("@mod/utility")

-- Model:ScaleTo is invalid at zero or below, and the runtime can reach that
-- where the authoring UI cannot: a chained modifier or a randomizer with a bad
-- range evaluates to whatever it evaluates to. the floor matches the bound the
-- plugin's own schema already declares on Scale_Start and Scale_End
local MIN_SCALE = 0.001

local spin = {}

-- both knobs spin drives through a sampler of its own, so emitters.applyMods
-- leaves them alone. task 5 converts the effect to actually use them
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

  local speedDuration = attr.get(ref, "SpinSpeed_Duration", 0.1)

  task.wait(emitDelay)

  -- read the sampler before any attr.get on SpinSpeed_Start/_End: attr.get's
  -- non-soft read below self-writes its default back onto ref, and it must
  -- not do that before legacy_mods.readQuad gets to see whether either
  -- attribute was genuinely absent
  local speed = mods.sampler(ref, "attribute", "SpinSpeed", speedDuration)
  local speedTween
  local currentSpeed

  if speed then
    currentSpeed = speed(0)

    speedTween = tween.fromParams(utility.linear_bezier, speedDuration, function(_, deltaTime, elapsed)
      currentSpeed = speed(elapsed)
      return deltaTime
    end)

    table.insert(scope, speedTween)
  else
    -- nothing authored at all. the pre-conversion default was a 0 to 1 ramp
    -- on default_bezier, and it was load-bearing: an unauthored model that
    -- lost it returns nil from the rotation timer's counter and stops on
    -- frame one
    local speedStart = attr.get(ref, "SpinSpeed_Start", 0)
    local speedEnd = attr.get(ref, "SpinSpeed_End", 1)

    currentSpeed = speedStart

    if speedStart ~= speedEnd then
      speedTween = tween.fromParams(
        attr.get(ref, "SpinSpeed_Curve", utility.default_bezier),
        speedDuration,
        function(alpha, deltaTime)
          currentSpeed = utility.lerp(speedStart, speedEnd, alpha)
          return deltaTime
        end
      )

      table.insert(scope, speedTween)
    end
  end

  local originalPivot = ref:GetPivot()
  local originalScale = ref:GetScale()

  local scale = mods.sampler(ref, "attribute", "Scale", duration)

  if scale then
    -- fromParams, not timer: timer yields until it finishes, and the rotation
    -- timer below is the last statement in this function. the curve is linear
    -- and its alpha ignored, because the sampler owns the shaping and is fed
    -- elapsed directly, exactly as the SpinSpeed branch above does
    table.insert(
      scope,
      tween.fromParams(utility.linear_bezier, duration, function(_, deltaTime, elapsed)
        ref:ScaleTo(math.max(scale(elapsed), MIN_SCALE))
        return deltaTime
      end)
    )
  else
    ref:ScaleTo(math.max(attr.get(ref, "Scale_Start", 1), MIN_SCALE))
  end

  local parent = ref:FindFirstAncestorOfClass("Attachment") or ref:FindFirstAncestorWhichIsA("BasePart")

  if resetOnFinish then
    table.insert(scope, function()
      ref:PivotTo(parent and utility.getTransformedOriginExtents(parent) or originalPivot)
      ref:ScaleTo(originalScale)
    end)
  end

  rotation *= duration

  tween.timer(duration + resetDelay, function(deltaTime, elapsed)
    local alpha = math.clamp(elapsed / duration, 0, 1)

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
