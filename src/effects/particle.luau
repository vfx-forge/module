local knob = require("@mod/knob")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local adapters = require("@mod/adapters")
local lifetime = require("@mod/lifetime")

local timing_common = require("@mod/common/timing")
local numeric_common = require("@mod/common/numeric")

local pool = require("@srv/pool")

-- the rows every emitter declares, the 2D one too, made anew for each module
-- that registers them, since registering freezes a row
local function rows()
  local attributes = {
    -- a count only the plugin defaults: anywhere else a particle emits once
    -- an author has written one
    EmitCount = knob(function()
        return if utility.PLUGIN_CONTEXT then 1 else nil
      end)
      :label("Count")
      :hint("The amount of effects to emit."),
    EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
    EmitDuration = knob(0):min(0):unit("seconds"):label("Duration"):hint("Duration of the emit cycle in seconds."),
  }

  -- the emitter's own property: a stored attribute of the same name shadows
  -- it and an old quad on it folds into its queue
  local properties = {
    TimeScale = knob():mod():label("TimeScale"):hint("Time scale written to the emitter for the length of the effect."),
  }

  return attributes, properties
end

local particle = {}

particle.id = "particle"
particle.display = { name = "Particle", icon = "particle", order = 20 }
particle.classifier = "ParticleEmitter"

-- only an emitter outside the workspace plays on a clone
function particle.copies(ref: Instance)
  return not ref:IsDescendantOf(workspace)
end

particle.attributes, particle.properties = rows()
particle.rows = rows

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

-- the longest a particle can live, as authored even while another emit of
-- the emitter in place has it retimed
local function longestOf(ref: ParticleEmitter): number
  local lifetimeRange = adapters.authoredOf(ref, "Lifetime") or ref.Lifetime

  return lifetimeRange.Max
end

-- the emitter's own clock: the longest a particle it emits can live, after
-- the window it emits over
function particle.duration(ctx: reader.Ctx, attrs: any)
  return attrs.EmitDuration + longestOf(ctx.ref :: ParticleEmitter)
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

  local links = {}

  local parent, ancestor = utility.cloneParticleAncestry(ref, shared.ref, function(obj: Instance)
    local link = pool.take(links, obj, true)

    -- a take never places a part, and a link sits where its source does
    if link:IsA("BasePart") then
      (link :: BasePart).CFrame = (obj :: BasePart).CFrame
    end

    return link
  end)

  if not parent then
    lifetime.releasePlain(links)
    return nil
  end

  local held = shared.held[ancestor]

  if held == nil then
    held = {}
    shared.held[ancestor] = held
  end

  for _, release in links do
    table.insert(held, release)
  end

  local clone = pool.take(scope, ref, true) :: ParticleEmitter
  clone.Parent = parent

  if not shared.unc[ancestor] then
    shared.unc[ancestor] = 1
  else
    shared.unc[ancestor] += 1
  end

  lifetime.hold(scope, function()
    shared.unc[ancestor] -= 1

    if shared.unc[ancestor] <= 0 then
      -- every link of the ancestor sits under it until it is released, and a
      -- released one may already be another holder's
      for source, link in shared.ref do
        if link == ancestor or link:IsDescendantOf(ancestor) then
          shared.ref[source] = nil
        end
      end

      lifetime.releasePlain(shared.held[ancestor])
      shared.held[ancestor] = nil
    end
  end)

  return clone
end

-- an emit of an emitter, 3D or 2D, on the instance `place` answers it plays
-- on, nil for none
function particle.play(ctx: reader.Ctx, attrs: any, props: any, place: (ctx: reader.Ctx) -> any?)
  local ref = ctx.ref :: any
  local scope = ctx.scope

  local count = attrs.EmitCount
  local duration = attrs.EmitDuration

  -- a count the reader could not make a number of, text that spells none,
  -- emits nothing rather than throwing on the compare
  if type(count) ~= "number" or (count <= 0 and duration <= 0) then
    -- what it emits nothing from still has its queues driven
    if ctx.copied then
      ctx.copied(ref, scope)
    end

    return
  end

  local obj = place(ctx)

  if obj == nil then
    return
  end

  ctx.obj = obj

  if ctx.copied then
    ctx.copied(obj, scope)
  end

  -- an emitter left enabled would emit on its own; one another emit's window
  -- holds is that window's to switch off
  if ref.Enabled and lifetime.writing(ref, "property", "Enabled") == 0 then
    ref.Enabled = false
  end

  local useDuration = duration > 0
  local longest = longestOf(ref)

  -- another emit of the emitter in place has written its own TimeScale over
  -- the authored one, which a row resting on the property was read from
  local written = ref.TimeScale
  local kept = adapters.authoredOf(ref, "TimeScale")

  -- a clone has the template's Enabled, so it is switched off before the
  -- window joins, or its restore would be on
  if obj ~= ref then
    obj.Enabled = false
  end

  -- the window holds the emitter on, and the last window to close lets it go
  local enabled = lifetime.write(scope, obj, "property", "Enabled")
  local emitted = false

  lifetime.wait(scope, attrs.EmitDelay)

  if useDuration then
    lifetime.set(enabled, true)
  end

  local timeScale = props.TimeScale
  local authored = timeScale.at(0)

  -- told apart by value only: an attribute equal to what the other emit
  -- wrote reads as the property, and an animated row is left as read
  if kept ~= nil and not timeScale.animated and authored == written then
    authored = kept
  end

  if not numeric_common.finite(authored) then
    local current = adapters.authoredOf(obj, "TimeScale") or obj.TimeScale

    authored = if numeric_common.finite(current) then current else 1
  end

  local setTimeScale = adapters.particle(scope, obj, authored)

  local scaling = if timeScale.animated
    then tween.drive(scope, timeScale, function(v: any)
      if typeof(v) == "number" and numeric_common.finite(v) then
        authored = v
        setTimeScale(v)
      end
    end)
    else nil

  -- what is in the air is wiped only by the last emit playing on the emitter,
  -- since every one that has started holds its TimeScale. one still in its
  -- EmitDelay holds none yet, and wipes nothing
  lifetime.defer(scope, function(cancelled: boolean)
    if cancelled and emitted and lifetime.writing(obj, "property", "TimeScale") <= 1 then
      obj:Clear()
    end
  end)

  obj:Emit(count)
  emitted = true

  if useDuration then
    lifetime.wait(scope, duration)
    lifetime.leave(enabled)
  end

  -- the clock carries the speed, so the particles' own time is that times
  -- the TimeScale they were authored at. they are not gone while a scale is
  -- still moving it, and a rate of 0 ends the wait unless one is
  local lasts = timing_common.duration(longest)
  local aged = lifetime.join(scope)
  local counted = lifetime.add(aged)
  local age = 0
  local ageing

  ageing = lifetime.step(scope, function(deltaTime: number)
    local rate = math.min(authored, 1)
    local moving = scaling ~= nil and scaling.Connected
    local stopped = rate <= 0 and not (age > 0 and moving)

    if (stopped or timing_common.done(age, lasts)) and not moving then
      ageing:Disconnect()
      counted()
      return
    end

    if not stopped then
      age += deltaTime * rate
    end
  end)

  lifetime.awaitJoin(aged)
end

function particle.emit(ctx: reader.Ctx, attrs: any, props: any)
  particle.play(ctx, attrs, props, prepare)
end

return particle
