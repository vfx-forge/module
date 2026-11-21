local mod = require("@mod/mod")
local clock = require("@mod/clock")
local knob = require("@mod/knob")
local curve = require("@mod/curve")
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
  -- how far the model turns in all, so a new duration or a retime changes how
  -- fast it gets there and never how far. a model storing a rate plays that
  -- instead (onRate), the same turn as before, until the plugin folds it in
  -- (spin.upgrade)
  SpinTurn = knob(function(_, attrs)
      return attrs.SpinRotation * attrs.SpinDuration
    end)
    :label("Turn")
    :hint("Degrees the model turns in all over its duration, per axis."),
  -- degrees a second for SpinDuration, as every model before Turn stored it
  SpinRotation = knob(vector.zero):unit("perSecond"):hidden(always),
  SpinDuration = knob(0.5)
    :min(0)
    :unit("seconds")
    :label("Duration")
    :hint("Seconds the model takes to make its turn at a Speed of 1."),
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
    :hint("Multiplier on how fast the model makes its turn. It ramps in from 0 by default."),
  SpinSpeedDuration = knob(0.1):min(0):aliases("SpinSpeed_Duration"):unit("seconds"):hidden(always),
}

spin.properties = {}

spin.layout = {
  { title = "Emit", entries = { "EmitDelay", "ResetDelay", "ResetOnFinish" } },
  { title = "Spin", entries = { "SpinTurn", "SpinDuration", "SpinSpeed", "SyncPosition", "Scale" } },
}

function spin.duration(_, attrs: any)
  return attrs.SpinDuration
end

-- a model stores a rate, degrees a second for SpinDuration, when it was saved
-- before Turn was a row, or when something older wrote one since: an older
-- plugin's Rotation row, an old script, a v2 randomizer child. a stored rate
-- is the newest intent there is, so it plays whatever turn is stored beside it
const function onRate(ref: Instance): boolean
  return ref:GetAttribute("SpinRotation") ~= nil
end

-- the turn as a vector, none for a stored value that is not one: the row's
-- rule takes no type, so the reader checks nothing it reads under it
const function turnOf(ref: Instance, attrs: any): vector
  const turn = if onRate(ref) then attrs.SpinRotation * attrs.SpinDuration else attrs.SpinTurn

  return if knob.kindOf(turn) == "Vector3" then turn else vector.zero
end

-- what saving the model the current way writes and removes: the turn its
-- stored rate makes over its duration, written over any turn stored beside it,
-- and the rate gone. nil for a model storing no rate
function spin.upgrade(ref: Instance): ({ [string]: any }?, { string }?)
  if not onRate(ref) then
    return nil, nil
  end

  const attrs = reader.resolve(spin, { ref = ref, obj = ref, effect = spin })
  const turn = turnOf(ref, attrs)

  return { SpinTurn = Vector3.new(turn.X, turn.Y, turn.Z) }, { "SpinRotation" }
end

-- a model nothing moves: no turn, a scale resting at one, no following. a
-- speed alone turns nothing
function spin.static(attrs: any, ref: Instance)
  return turnOf(ref, attrs) == vector.zero
    and not attrs.Scale.animated
    and attrs.Scale.value == 1
    and not attrs.SyncPosition
end

function spin.emit(ctx: reader.Ctx, attrs: any)
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

  tween.play(scope, curve.new(duration + resetDelay, "linear"), function(_, _, elapsed: number)
    local alpha = timing_common.progress(elapsed, duration)

    local r = turn * alpha
    local cf = (if parent and sync then utility.getTransformedOriginExtents(parent) else originalPivot)
      * CFrame.fromOrientation(r.X, r.Y, r.Z)

    ref:PivotTo(cf)
  end, scope.depth, lifetime.add(ended), turning)

  lifetime.awaitJoin(ended)
end

return spin
