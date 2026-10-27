local frames_common = require("@mod/common/frames")
local frame_store = require("@srv/frame_store")

export type Show = {
  show: (index: number, size: Vector3) -> Vector3,
  glow: (strength: number, tint: Color3) -> (),
  release: () -> (),
}

local frame_show = {}

-- what a spec stands in
frame_show.engine = {
  apply = function(piece: MeshPart, source: BasePart)
    piece:ApplyMesh(source)
  end,
}

local function boundsOf(frame: frame_store.Frame): frames_common.Bounds?
  if frame.size == nil or frame.center == nil then
    return nil
  end

  return { size = frame.size, center = frame.center }
end

function frame_show.new(set: frame_store.Set, piece: BasePart, start: BasePart): Show
  const special = piece:FindFirstChildOfClass("SpecialMesh")
  const startSpecial = start:FindFirstChildOfClass("SpecialMesh")
  const own = {}
  const home = if special then special.Offset else Vector3.zero

  local shown: number? = nil
  local switched = false
  local worn: Instance? = nil
  local offset = Vector3.zero
  local strength: number? = nil
  local tint = Color3.new(1, 1, 1)

  for _, child in piece:GetChildren() do
    if child:IsA("SurfaceAppearance") then
      table.insert(own, child)
    end
  end

  const function dress(index: number)
    const frame = set.frames[index]

    if frame == nil or strength == nil or worn == nil then
      return
    end

    const material = worn :: any
    const base = frame.tint or Color3.new(1, 1, 1)

    material.EmissiveStrength = (frame.strength or 1) * strength
    material.EmissiveTint = Color3.new(base.R * tint.R, base.G * tint.G, base.B * tint.B)
  end

  const function swap(index: number)
    if worn ~= nil and shown ~= nil then
      frame_store.giveBack(set, shown, worn)
      worn = nil
    end

    const material = frame_store.lend(set, index)

    if material == nil then
      return
    end

    for _, appearance in own do
      appearance.Parent = nil
    end

    material.Parent = piece
    worn = material
    dress(index)
  end

  const function show(index: number, size: Vector3): Vector3
    const frame = set.frames[index]

    if frame == nil then
      return offset
    end

    if index ~= shown then
      if set.meshes then
        if special then
          const source = frame.source:FindFirstChildOfClass("SpecialMesh")

          if source then
            special.MeshId = source.MeshId
            switched = true
          end
        elseif frame.mesh and piece:IsA("MeshPart") then
          frame_show.engine.apply(piece, frame.mesh)
          switched = true
        end
      end

      if set.materials then
        swap(index)
      end

      shown = index
    end

    const bounds = boundsOf(frame)
    const fitted, shift = frames_common.fit(bounds, set.union, size)

    if special then
      if bounds and set.union then
        special.Offset = (bounds.center - set.union.center) * special.Scale
      end

      offset = Vector3.zero
    else
      piece.Size = fitted
      offset = shift
    end

    return offset
  end

  const function glow(by: number, color: Color3)
    strength = by
    tint = color

    if shown ~= nil then
      dress(shown)
    end
  end

  const function release()
    if worn ~= nil and shown ~= nil then
      frame_store.giveBack(set, shown, worn)
    end

    worn = nil
    shown = nil

    for _, appearance in own do
      appearance.Parent = piece
    end

    if special then
      special.Offset = home
    end

    if switched then
      if special then
        if startSpecial then
          special.MeshId = startSpecial.MeshId
        end
      elseif piece:IsA("MeshPart") then
        frame_show.engine.apply(piece, start)
      end

      switched = false
    end
  end

  return { show = show, glow = glow, release = release }
end

return frame_show
