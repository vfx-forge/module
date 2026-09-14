local knob = require("@mod/knob")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")

local function always()
  return true
end

local particle = {}

particle.id = "particle"
particle.display = { name = "Particle", icon = "particle", order = 20 }
particle.classifier = "ParticleEmitter"

particle.attributes = {
  -- a count only the plugin defaults: anywhere else a particle emits once an
  -- author has written one
  EmitCount = knob(function()
      return if utility.PLUGIN_CONTEXT then 1 else nil
    end)
    :label("Count")
    :hint("The amount of effects to emit."),
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
  EmitDuration = knob(0):min(0):unit("seconds"):label("Duration"):hint("Duration of the emit cycle in seconds."),
  -- the span an old time scale quad ran over, read by the old format's reader
  -- under this name and kept as a row so retime reaches it
  TimeScaleDuration = knob(0.1):min(0):aliases("TimeScale_Duration"):unit("seconds"):hidden(always),
}

-- the emitter's own property: a stored attribute of the same name shadows it
-- and an old quad on it folds into its queue
particle.properties = {
  TimeScale = knob():mod():label("TimeScale"):hint("Time scale written to the emitter for the length of the effect."),
}

particle.layout = {
  { title = "Emit", entries = { "EmitCount", "EmitDelay", "EmitDuration" } },
  { title = "Motion", entries = { "TimeScale" } },
  {
    title = "Behavior",
    entries = {
      { action = "toggle_paths", label = "Show Paths" },
      { action = "toggle_textures", label = "Load Textures" },
    },
  },
}

-- the emitter's own clock: the longest a particle it emits can live, after
-- the window it emits over
function particle.duration(ctx: reader.Ctx, attrs: any)
  return attrs.EmitDuration + (ctx.ref :: ParticleEmitter).Lifetime.Max
end

-- the clone an emitter outside the workspace plays on, under a copy of its
-- ancestry that every particle of the same emit shares and the last one frees
local function prepare(ctx: reader.Ctx): ParticleEmitter?
  local ref = ctx.ref :: ParticleEmitter
  local scope = ctx.scope
  local shared = ctx.shared :: reader.Shared

  if ref:IsDescendantOf(workspace) then
    return ref
  end

  local parent, ancestor = utility.cloneParticleAncestry(ref, shared.ref)

  if not parent then
    return nil
  end

  local clone = ref:Clone()
  clone.Archivable = false
  clone.Parent = parent

  if not shared.unc[ancestor] then
    ancestor.Parent = workspace.Terrain
    shared.unc[ancestor] = 1
  else
    shared.unc[ancestor] += 1
  end

  lifetime.hold(scope, function()
    shared.unc[ancestor] -= 1

    if shared.unc[ancestor] <= 0 then
      ancestor:Destroy()
    end
  end)

  return clone
end

function particle.emit(ctx: reader.Ctx, attrs: any, props: any)
  local ref = ctx.ref :: ParticleEmitter
  local scope = ctx.scope

  local count = attrs.EmitCount
  local duration = attrs.EmitDuration

  if count == nil or (count <= 0 and duration <= 0) then
    return
  end

  local obj = prepare(ctx)

  if obj == nil then
    return
  end

  ctx.obj = obj

  if ref.Enabled then
    ref.Enabled = false
  end

  local useDuration = duration > 0

  task.wait(attrs.EmitDelay)

  if useDuration then
    obj.Enabled = true
  end

  local timeScale = props.TimeScale
  local speedTween

  obj.TimeScale = timeScale.at(0)

  if timeScale.animated then
    speedTween = tween.fromParams(utility.linear_bezier, timeScale.duration, function(_, deltaTime, elapsed)
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
