local knob = require("@mod/knob")
local lazy = require("@mod/lazy")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local adapters = require("@mod/adapters")

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

const play = lazy.unit("particle", function()
  return require("@root/play/particle")
end)

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

function particle.play(ctx: any, attrs: any, props: any, place: any)
  return play().play(ctx, attrs, props, place)
end

function particle.emit(ctx: any, attrs: any, props: any)
  return play().emit(ctx, attrs, props)
end

return particle
