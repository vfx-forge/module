local frame_store = require("@srv/frame_store")

const WHITE = Color3.new(1, 1, 1)

local material_dress = {}

-- a frame's own glow and color multiplied by the rows, and a decal frame's own transparency faded further by
-- `fade`. a strength of nil leaves the glow as the frame authored it
function material_dress.apply(
  worn: Instance,
  frame: frame_store.Frame,
  strength: number?,
  tint: Color3,
  color: Color3,
  fade: number?
)
  const material = worn :: any

  if strength ~= nil then
    const base = frame.tint or WHITE
    const own = frame.color or WHITE
    const mixed = Color3.new(own.R * color.R, own.G * color.G, own.B * color.B)

    material.EmissiveStrength = (frame.strength or 1) * strength
    material.EmissiveTint = Color3.new(base.R * tint.R, base.G * tint.G, base.B * tint.B)

    if material:IsA("Decal") then
      material.Color3 = mixed
    else
      material.Color = mixed
    end
  end

  if fade ~= nil and material:IsA("Decal") then
    material.Transparency = 1 - (1 - (frame.transparency or 0)) * (1 - fade)
  end
end

return material_dress
