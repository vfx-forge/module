local RunService = game:GetService("RunService")

local reader = require("@mod/reader")

local Particle = require("@vfx/particle")

local particle_2d = {}

particle_2d.id = "particle_2d"
particle_2d.display = { name = "Particle 2D", icon = "particle_2d", order = 21 }
particle_2d.classifier = "ParticleEmitter2D"

particle_2d.attributes, particle_2d.properties = Particle.rows()

-- the texture is a Content, which the plugin edits as a row of its own
particle_2d.layout = {
  { title = "Emit", entries = { "EmitCount", "EmitDelay", "EmitDuration" } },
  { title = "Motion", entries = { "TimeScale" } },
  { title = "Appearance", entries = { { property = "Color" }, { action = "texture_content", label = "Texture" } } },
  { title = "Behavior", entries = { { action = "toggle_textures", label = "Load Textures" } } },
}

particle_2d.duration = Particle.duration

-- a 2D emitter draws only under a GuiObject and only in the editor or on a
-- client, so it plays where it is or not at all
local function place(ctx: reader.Ctx): Instance?
  local ref = ctx.ref
  local parent = ref.Parent

  if RunService:IsRunning() and not RunService:IsClient() then
    return nil
  end

  if parent == nil or not parent:IsA("GuiObject") then
    return nil
  end

  return ref
end

function particle_2d.emit(ctx: reader.Ctx, attrs: any, props: any)
  Particle.play(ctx, attrs, props, place)
end

return particle_2d
