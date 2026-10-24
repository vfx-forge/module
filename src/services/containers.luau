local containers = {}

containers.ROOT = "VFXForge"

local root: BasePart? = nil
local byKey: { [string]: BasePart } = {}

-- an invisible part at the origin, since attachments, parts, models and sounds all work under one as they do under
-- Terrain, and a Folder holds no attachment
local function make(name: string, parent: Instance): BasePart
  local part = Instance.new("Part")

  part.Name = name
  part.Archivable = false
  part.Locked = true
  part.Anchored = true
  part.CanCollide = false
  part.CanQuery = false
  part.CanTouch = false
  part.CastShadow = false
  part.Transparency = 1
  part.Size = Vector3.zero
  part.CFrame = CFrame.identity
  part.Parent = parent

  return part
end

-- the one part under Terrain everything the runtime makes goes under, made again when it was destroyed or moved
function containers.root(): BasePart
  local terrain = workspace.Terrain

  if root == nil or root.Parent ~= terrain then
    root = make(containers.ROOT, terrain)
    table.clear(byKey)
  end

  return root :: BasePart
end

-- the part under the root one effect, or one of the runtime's own services, keeps its pieces in, named by key
function containers.of(key: string): BasePart
  local parent = containers.root()
  local held = byKey[key]

  if held == nil or held.Parent ~= parent then
    held = make(key, parent)
    byKey[key] = held
  end

  return held :: BasePart
end

-- the root and everything still under it gone, last in a teardown, so nothing a teardown missed stays in the place
function containers.clear()
  local was = root

  root = nil
  table.clear(byKey)

  if was ~= nil then
    was:Destroy()
  end
end

return containers
