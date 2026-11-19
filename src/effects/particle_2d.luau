local RunService = game:GetService("RunService")

local reader = require("@mod/reader")

local Particle = require("@vfx/particle")

local particle_2d = {}

particle_2d.id = "particle_2d"
particle_2d.display = { name = "Particle 2D", icon = "particle_2d", order = 21 }
particle_2d.classifier = "ParticleEmitter2D"

-- handed to the dispatcher as a copy is, so its rows' modifiers are driven
-- only once it plays: on a server they would write every frame for nothing
-- and replicate over a client's own emit
particle_2d.copies = true

particle_2d.attributes, particle_2d.properties = Particle.rows()

-- the texture is a Content, which the plugin edits as a row of its own
particle_2d.layout = {
  { title = "Emit", entries = { "EmitCount", "EmitDelay", "EmitDuration" } },
  { title = "Motion", entries = { "TimeScale" } },
  { title = "Appearance", entries = { { property = "Color" }, { action = "texture_content", label = "Texture" } } },
  {
    title = "Behavior",
    entries = {
      { action = "toggle_paths", label = "Show Paths" },
      { action = "toggle_textures", label = "Load Textures" },
    },
  },
}

particle_2d.duration = Particle.duration

-- a 2D emitter draws only under a GuiObject and only in the editor or on a
-- client, and plays where it is
local function draws(ref: Instance): boolean
  if RunService:IsRunning() and not RunService:IsClient() then
    return false
  end

  local parent = ref.Parent

  return parent ~= nil and parent:IsA("GuiObject")
end

local function place(ctx: reader.Ctx): Instance?
  return ctx.ref
end

function particle_2d.emit(ctx: reader.Ctx, attrs: any, props: any)
  if not draws(ctx.ref) then
    return
  end

  Particle.play(ctx, attrs, props, place)
end

return particle_2d
