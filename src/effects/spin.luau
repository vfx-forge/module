local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local utility = require("@mod/utility")

local spin = {}

-- both knobs spin drives through a sampler of its own, so emitters.applyMods
-- leaves them alone. task 5 converts the effect to actually use them
spin.OWNS = {
  Scale = true,
  SpinSpeed = true,
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

  local currentSpeed = attr.get(ref, "SpinSpeed_Start", 0)

  task.wait(emitDelay)

  local speed = mods.sampler(ref, "attribute", "SpinSpeed", speedDuration)
  local speedTween

  if speed then
    speedTween = tween.fromParams(utility.linear_bezier, speedDuration, function(_, deltaTime, elapsed)
      currentSpeed = speed(elapsed)
      return deltaTime
    end)

    table.insert(scope, speedTween)
  end

  local originalPivot = ref:GetPivot()
  local originalScale = ref:GetScale()

  local scale = mods.sampler(ref, "attribute", "Scale", duration)

  if scale then
    table.insert(
      scope,
      tween.timer(duration, function(deltaTime, elapsed)
        ref:ScaleTo(scale(elapsed))
        return deltaTime
      end)
    )
  else
    ref:ScaleTo(attr.get(ref, "Scale_Start", 1))
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
