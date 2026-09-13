local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")

local particle = {}

-- TimeScale is driven through a sampler of its own, so emitters.applyMods
-- leaves it alone. unlike sound's Speed this is not a clock multiplier: it
-- writes the real ParticleEmitter property and the engine does the scaling
particle.OWNS = {
  attribute = {
    TimeScale = true,
  },
}

function particle.emit(ref: ParticleEmitter, obj: ParticleEmitter, scope: types.scope)
  if ref.Enabled then
    ref.Enabled = false
  end

  local delay = attr.get(ref, "EmitDelay", 0)
  local count = attr.get(ref, "EmitCount", 1)
  local duration = attr.get(ref, "EmitDuration", 0)

  local useDuration = duration > 0

  task.wait(delay)

  if useDuration then
    obj.Enabled = true
  end

  local timeScale =
    mods.track(ref, "attribute", "TimeScale", obj.TimeScale, attr.get(ref, "TimeScale_Duration", 0.1, true))

  local speedTween

  obj.TimeScale = timeScale.at(0)

  if timeScale.animated then
    speedTween = tween.fromParams(utility.linear_bezier, timeScale.span, function(_, deltaTime, elapsed)
      obj.TimeScale = timeScale.at(elapsed)
      return deltaTime
    end)

    lifetime.hold(scope, speedTween)
  end

  utility.onCancel(scope, function()
    if useDuration then
      obj.Enabled = false
    end

    obj:Clear()
  end)

  obj:Emit(count)

  if useDuration then
    task.wait(duration)
    obj.Enabled = false
  end

  tween.timer(ref.Lifetime.Max, function(deltaTime, elapsed)
    return if obj.TimeScale > 0 or (elapsed > 0 and speedTween and speedTween.Connected)
      then deltaTime * obj.TimeScale
      else nil
  end, speedTween, scope)
end

return particle
