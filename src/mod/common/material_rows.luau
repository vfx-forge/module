const knob = require("@mod/knob")
const reader = require("@mod/reader")

const WHITE = Color3.new(1, 1, 1)

const common = {}

-- the glow of a mesh's material, declared beside the look rather than on any
-- effect, so the material card is their one editor
common.rows = {
  EmissiveStrength = knob(1):min(0):mod():label("Strength"):hint("Multiplier on the glow of the mesh's material."),
  SurfaceColor = knob(WHITE)
    :mod()
    :label("Color")
    :hint("Color the mesh's material is multiplied by, its glow included."),
  EmissiveTint = knob(WHITE):mod():label("Tint"):hint("Color the glow of the mesh's material is multiplied by."),
}

-- whether any frame of the template's frame set wears a look; a shape-only
-- set's frames wear none, so the glow has nothing to reach
const function framesDressed(template: Instance, key: string)
  for _, folder in template:GetChildren() do
    if folder.Name ~= "Frames" or not folder:IsA("Folder") or folder:GetAttribute("FrameSet") ~= key then
      continue
    end

    for _, part in folder:GetChildren() do
      if part:FindFirstChildOfClass("SurfaceAppearance") or part:FindFirstChildOfClass("Decal") then
        return true
      end
    end
  end

  return false
end

const function unlit(ctx: reader.Ctx)
  return not common.lit(ctx.ref)
end

common.layout = {
  { title = "Glow", entries = { "SurfaceColor", "EmissiveStrength", "EmissiveTint" }, hidden = unlit },
}

-- the rows read as a module of their own, over the clock the effect decided
const module = {
  id = "material",
  display = { name = "Material" },
  classifier = "",
  attributes = common.rows,
  properties = {},
  duration = function(ctx: reader.Ctx)
    return ctx.duration
  end,
  emit = function() end,
}

-- the surface glow reaches only a surface appearance, one the template wears
-- or one a texture or dressed frame set brings
function common.lit(template: Instance)
  const frames = template:GetAttribute("FrameSet")
  const textures = template:GetAttribute("TextureSet")

  if template:FindFirstChildOfClass("SurfaceAppearance") ~= nil then
    return true
  end

  if type(textures) == "string" and textures ~= "" then
    return true
  end

  return type(frames) == "string" and frames ~= "" and framesDressed(template, frames)
end

-- the rows as the template holds them, modifiers and all, the way an
-- effect's own rows resolve
function common.resolve(ctx: reader.Ctx, ref: Instance): any
  const attrs = reader.resolve(module :: any, {
    ref = ref,
    obj = ref,
    scope = ctx.scope,
    duration = ctx.duration,
    shared = ctx.shared,
  })

  return attrs
end

return common
