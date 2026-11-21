local clock = require("@mod/clock")
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local timing_common = require("@mod/common/timing")

-- the Scale row's floor: Model:ScaleTo is invalid at zero or below
local MIN_SCALE = 0.001

local spin: any = nil
local turnOf: (ref: Instance, attrs: any) -> vector = nil :: any

local play = {}

function play.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: Model
  local scope = ctx.scope

  if lifetime.lock(scope, ref) or spin.static(attrs, ref) then
    return
  end

  local turn = turnOf(ref, attrs) * utility.DEG_TO_RAD

  local resetDelay = attrs.ResetDelay
  local resetOnFinish = attrs.ResetOnFinish

  local sync = attrs.SyncPosition
  local duration = attrs.SpinDuration

  lifetime.wait(scope, attrs.EmitDelay)

  -- the spin's Speed is the rotation's clock alone, as it was in v2: the scale
  -- and every other lane run SpinDuration on the effect's own clock, which a
  -- handle's speed, a controller and the global speed reach as they reach
  -- the rotation
  const turning = clock.new(scope.clock)

  lifetime.hold(scope, function()
    clock.drop(turning)
  end)

  lifetime.speed(scope, attrs.SpinSpeed, turning)

  local originalPivot = ref:GetPivot()
  local originalScale = ref:GetScale()

  -- the spin ends once both the scale and the rotation have, since a fast
  -- rotation would otherwise release the scale partway
  const ended = lifetime.join(scope)
  const scaled = lifetime.add(ended)

  -- a queue that stops resolving partway would throw every frame, and a
  -- stepper that throws ends the spin
  const scaling = tween.drive(scope, attrs.Scale, function(v: any)
    if typeof(v) == "number" then
      ref:ScaleTo(math.max(v, MIN_SCALE))
    end
  end, nil, scaled)

  -- a scale that never moves calls nothing back
  if scaling == nil then
    scaled()
  end

  local parent = ref:FindFirstAncestorOfClass("Attachment") or ref:FindFirstAncestorWhichIsA("BasePart")

  if resetOnFinish then
    lifetime.hold(scope, function()
      ref:PivotTo(parent and utility.getTransformedOriginExtents(parent) or originalPivot)
      ref:ScaleTo(originalScale)
    end)
  end

  -- where the turn stands, which a synced model keeps following its parent
  -- with once the rotation is done and the scale still runs
  local turned = CFrame.identity
  local done = false
  const rotated = lifetime.add(ended)

  local function base(): CFrame
    return if parent and sync then utility.getTransformedOriginExtents(parent) else originalPivot
  end

  tween.play(
    scope,
    curve.new(duration + resetDelay, "linear"),
    function(_, _, elapsed: number)
      local alpha = timing_common.progress(elapsed, duration)

      local r = turn * alpha
      turned = CFrame.fromOrientation(r.X, r.Y, r.Z)

      ref:PivotTo(base() * turned)
    end,
    scope.depth,
    function()
      done = true
      rotated()
    end,
    turning
  )

  if parent and sync then
    lifetime.step(scope, function()
      if done then
        ref:PivotTo(base() * turned)
      end
    end, "follow")
  end

  lifetime.awaitJoin(ended)
end

function play.bind(module: any, readers: { turnOf: (ref: Instance, attrs: any) -> vector })
  spin = module
  turnOf = readers.turnOf

  return play
end

return play
