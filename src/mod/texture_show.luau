local material_dress = require("@mod/material_dress")

local frame_store = require("@srv/frame_store")

export type Show = {
  show: (index: number) -> (),
  glow: (strength: number, tint: Color3, color: Color3) -> (),
  release: () -> (),
}

local texture_show = {}

function texture_show.new(set: frame_store.Set, piece: BasePart): Show
  const own = {}

  local shown: number? = nil
  local worn: Instance? = nil
  local strength: number? = nil
  local tint = Color3.new(1, 1, 1)
  local color = Color3.new(1, 1, 1)

  for _, child in piece:GetChildren() do
    if child:IsA("SurfaceAppearance") then
      table.insert(own, child)
    end
  end

  const function wearOwn(on: boolean)
    for _, appearance in own do
      appearance.Parent = if on then piece else nil
    end
  end

  const function giveBack()
    if worn ~= nil and shown ~= nil then
      frame_store.giveBack(set, shown, worn)
    end

    worn = nil
  end

  const function show(index: number)
    const frame = set.frames[index]

    if frame == nil or index == shown then
      return
    end

    giveBack()
    shown = index

    const material = frame_store.lend(set, index)

    if material == nil then
      wearOwn(true)

      return
    end

    wearOwn(false)
    material.Parent = piece
    worn = material
    material_dress.apply(material, frame, strength, tint, color)
  end

  const function glow(by: number, shade: Color3, surface: Color3)
    strength = by
    tint = shade
    color = surface

    if worn ~= nil and shown ~= nil then
      material_dress.apply(worn, set.frames[shown], strength, tint, color)
    end
  end

  const function release()
    if shown == nil then
      return
    end

    giveBack()
    shown = nil
    wearOwn(true)
  end

  return { show = show, glow = glow, release = release }
end

return texture_show
