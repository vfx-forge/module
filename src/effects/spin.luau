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
  -- fast it gets there and never how far. a model saved before Turn was a row
  -- stores a rate instead, which the rule turns into the same turn until the
  -- plugin writes one (spin.upgrade)
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

-- the turn as a vector, none for a stored value that is not one: the row's
-- rule takes no type, so the reader checks nothing it reads under it
const function turnOf(attrs: any): vector
  const turn = attrs.SpinTurn

  return if knob.kindOf(turn) == "Vector3" then turn else vector.zero
end

-- what saving the model the current way writes and removes: the turn its rate
-- makes over its duration, where it stores a rate and no turn. nil for a model
-- stored the current way. an instance whose turn and rate are both stored keeps
-- both, the turn playing, since the rate is then what an older plugin wrote
-- after the conversion and nothing says which of the two to trust
function spin.upgrade(ref: Instance): ({ [string]: any }?, { string }?)
  if ref:GetAttribute("SpinTurn") ~= nil or ref:GetAttribute("SpinRotation") == nil then
    return nil, nil
  end

  const attrs = reader.resolve(spin, { ref = ref, obj = ref, effect = spin })
  const turn = turnOf(attrs)

  return { SpinTurn = Vector3.new(turn.X, turn.Y, turn.Z) }, { "SpinRotation" }
end

-- a model nothing moves: no turn, a scale resting at one, no following. a
-- speed alone turns nothing
function spin.static(attrs: any)
  return turnOf(attrs) == vector.zero and not attrs.Scale.animated and attrs.Scale.value == 1 and not attrs.SyncPosition
end

function spin.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: Model
  local scope = ctx.scope

  if lifetime.lock(scope, ref) or spin.static(attrs) then
    return
  end

  local turn = turnOf(attrs) * utility.DEG_TO_RAD

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
