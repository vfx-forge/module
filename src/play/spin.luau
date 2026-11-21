local curve = require("@mod/curve")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local timing_common = require("@mod/common/timing")

-- the Scale row's floor: Model:ScaleTo is invalid at zero or below
local MIN_SCALE = 0.001

local spin: any = nil

local play = {}

function play.emit(ctx: reader.Ctx, attrs: any)
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

  lifetime.wait(scope, attrs.EmitDelay)

  -- the spin's speed is its clock, so the scale runs on it too
  lifetime.speed(scope, attrs.SpinSpeed)

  local originalPivot = ref:GetPivot()
  local originalScale = ref:GetScale()

  -- a queue that stops resolving partway would throw every frame, and a
  -- stepper that throws ends the spin
  tween.drive(scope, attrs.Scale, function(v: any)
    if typeof(v) == "number" then
      ref:ScaleTo(math.max(v, MIN_SCALE))
    end
  end)

  local parent = ref:FindFirstAncestorOfClass("Attachment") or ref:FindFirstAncestorWhichIsA("BasePart")

  if resetOnFinish then
    lifetime.hold(scope, function()
      ref:PivotTo(parent and utility.getTransformedOriginExtents(parent) or originalPivot)
      ref:ScaleTo(originalScale)
    end)
  end

  rotation *= duration

  tween.wait(scope, curve.new(duration + resetDelay, "linear"), function(_, _, elapsed: number)
    local alpha = timing_common.progress(elapsed, duration)

    local r = rotation * alpha
    local cf = (if parent and sync then utility.getTransformedOriginExtents(parent) else originalPivot)
      * CFrame.fromOrientation(r.x, r.y, r.z)

    ref:PivotTo(cf)
  end, scope.depth)
end

function play.bind(module: any)
  spin = module

  return play
end

return play
