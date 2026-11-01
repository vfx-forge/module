local frames_common = require("@mod/common/frames")
local material_dress = require("@mod/material_dress")

local frame_store = require("@srv/frame_store")

export type Show = {
  show: (index: number, size: Vector3) -> Vector3,
  glow: (strength: number, tint: Color3, color: Color3) -> (),
  fade: (transparency: number) -> (),
  release: () -> (),
}

export type Options = {
  materials: boolean?,
}

local frame_show = {}

-- what a spec stands in
frame_show.engine = {
  apply = function(piece: MeshPart, source: BasePart)
    piece:ApplyMesh(source)
  end,
}

-- with `materials` false the frames' meshes play and the piece keeps whatever surface it wears
function frame_show.new(set: frame_store.Set, piece: BasePart, start: BasePart, opts: Options?): Show
  const materials = set.materials and not (opts and opts.materials == false)
  const special = piece:FindFirstChildOfClass("SpecialMesh")
  const startSpecial = start:FindFirstChildOfClass("SpecialMesh")
  const startId = if startSpecial then startSpecial.MeshId else nil
  const own = {}
  const home = if special then special.Offset else Vector3.zero

  -- a frame applied before its mesh is loaded blocks the frame it lands on, so until it is the last one
  -- shown holds, or the start before any has
  const gated = set.meshes and special == nil and piece:IsA("MeshPart")

  local shown: number? = nil
  local switched = false
  local worn: Instance? = nil
  local offset = Vector3.zero
  local strength: number? = nil
  local tint = Color3.new(1, 1, 1)
  local color = Color3.new(1, 1, 1)
  local faded: number? = nil
  local sized: Vector3? = nil

  for _, child in piece:GetChildren() do
    if materials and child:IsA("SurfaceAppearance") then
      table.insert(own, child)
    end
  end

  const function dress(index: number)
    const frame = set.frames[index]

    if frame == nil or worn == nil then
      return
    end

    material_dress.apply(worn, frame, strength, tint, color, faded)
  end

  const function swap(index: number)
    if worn ~= nil and shown ~= nil then
      frame_store.giveBack(set, shown, worn)
      worn = nil
    end

    const material = frame_store.lend(set, index)

    if material == nil then
      for _, appearance in own do
        appearance.Parent = piece
      end

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
    local frame = set.frames[index]

    if frame == nil then
      return offset
    end

    if index ~= shown and gated and not frame_store.ready(set, index) then
      frame = if shown then set.frames[shown] else nil
    elseif index ~= shown then
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

      if materials then
        swap(index)
      end

      shown = index
    end

    const bounds = if frame then frame.bounds else nil
    const fitted, shift = frames_common.fit(bounds, set.union, size)

    if special then
      if bounds and set.union then
        special.Offset = home + (bounds.center - set.union.center) * special.Scale
      end

      offset = Vector3.zero
    else
      if fitted ~= sized then
        piece.Size = fitted
        sized = fitted
      end

      offset = shift
    end

    return offset
  end

  const function glow(by: number, shade: Color3, surface: Color3)
    strength = by
    tint = shade
    color = surface

    if shown ~= nil then
      dress(shown)
    end
  end

  -- a decal frame's own transparency, faded further by the effect's
  const function fade(transparency: number)
    faded = transparency

    if shown ~= nil then
      dress(shown)
    end
  end

  const function release()
    if shown == nil then
      return
    end

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
        if startId then
          special.MeshId = startId
        end
      elseif piece:IsA("MeshPart") then
        frame_show.engine.apply(piece, start)
      end

      switched = false
    end
  end

  return { show = show, glow = glow, fade = fade, release = release }
end

return frame_show
