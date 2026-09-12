local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local utility = require("@mod/utility")

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

  -- read before the legacy attr.get below, because attr.get writes its default
  -- back and reading TimeScale_Start would create the quad readQuad then finds
  local timeScale, timeScaleSpan = mods.driver(ref, "attribute", "TimeScale", 0.1)

  local speedTween

  if timeScale then
    obj.TimeScale = timeScale(0)

    speedTween = tween.fromParams(utility.linear_bezier, timeScaleSpan, function(_, deltaTime, elapsed)
      obj.TimeScale = timeScale(elapsed)
      return deltaTime
    end)

    table.insert(scope, speedTween)
  else
    local timeScaleDuration = attr.get(ref, "TimeScale_Duration", 0.1)

    local timeScaleStart = attr.get(ref, "TimeScale_Start", obj.TimeScale, true)
    local timeScaleEnd = attr.get(ref, "TimeScale_End", obj.TimeScale, true)

    if timeScaleStart ~= timeScaleEnd then
      speedTween = tween.fromParams(
        attr.get(ref, "TimeScale_Curve", utility.default_bezier),
        timeScaleDuration,
        function(alpha, deltaTime)
          local speed = utility.lerp(timeScaleStart, timeScaleEnd, math.clamp(alpha, 0, 1))

          obj.TimeScale = speed

          return deltaTime
        end
      )

      table.insert(scope, speedTween)
    elseif timeScaleStart ~= obj.TimeScale then
      obj.TimeScale = timeScaleStart
    end
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
