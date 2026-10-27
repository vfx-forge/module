local RunService = game:GetService("RunService")

local containers = require("@srv/containers")
local frames_common = require("@mod/common/frames")

export type Frame = {
  source: BasePart,
  mesh: BasePart?,
  material: Instance?,
  size: Vector3?,
  center: Vector3?,
  strength: number?,
  tint: Color3?,
}

export type Set = {
  key: string,
  frames: { Frame },
  union: frames_common.Bounds?,
  meshes: boolean,
  materials: boolean,
  entry: frames_common.Entry,
}

local DEFAULT_BUDGET = 128
local PARK = CFrame.new(0, -20000, 0)

local MAPS =
  { "ColorMapContent", "EmissiveMaskContent", "NormalMapContent", "RoughnessMapContent", "MetalnessMapContent" }

local frame_store = {}

-- what a spec stands in
frame_store.engine = {
  now = os.clock,
  detaches = function()
    return RunService:IsRunning() and RunService:IsClient()
  end,
  maps = function(material: Instance): number
    local count = 0

    for _, name in MAPS do
      const ok, uri = pcall(function()
        return (material :: any)[name].Uri
      end)

      if ok and uri ~= nil and uri ~= "" then
        count += 1
      end
    end

    return count
  end,
}

local sets: { [string]: Set } = {}
local byEntry: { [frames_common.Entry]: Set } = {}
local built: { [Set]: boolean } = {}
local homes: { [Frame]: BasePart } = {}
local out: { [Frame]: boolean } = {}
local budget = DEFAULT_BUDGET
local park: BasePart? = nil

local function materialOf(source: Instance): Instance?
  return source:FindFirstChildOfClass("SurfaceAppearance") or source:FindFirstChildOfClass("Decal")
end

local function meshIdOf(part: BasePart): string?
  if part:IsA("MeshPart") then
    const ok, uri = pcall(function()
      return part.MeshContent.Uri
    end)

    return if ok then uri else nil
  end

  const special = part:FindFirstChildOfClass("SpecialMesh")

  return if special then special.MeshId else nil
end

local function bounds(from: Instance, size: string, center: string): frames_common.Bounds?
  const s, c = from:GetAttribute(size), from:GetAttribute(center)

  if typeof(s) ~= "Vector3" or typeof(c) ~= "Vector3" then
    return nil
  end

  return { size = s, center = c }
end

local function register(folder: Instance, key: string): Set
  const frames = {}
  local meshes, materials = false, false
  local first: string? = nil

  for _, child in frames_common.order(folder:GetChildren()) do
    if child:IsA("BasePart") then
      const size, center = child:GetAttribute("FrameSize"), child:GetAttribute("FrameCenter")
      const id = meshIdOf(child)

      table.insert(frames, {
        source = child,
        size = if typeof(size) == "Vector3" then size else nil,
        center = if typeof(center) == "Vector3" then center else nil,
      })

      if #frames == 1 then
        first = id
      elseif id ~= nil and id ~= first then
        meshes = true
      end

      if materialOf(child) then
        materials = true
      end
    end
  end

  const entry = { textures = 0, used = 0, lent = 0, parked = false }
  const set = {
    key = key,
    frames = frames,
    union = bounds(folder, "UnionSize", "UnionCenter"),
    meshes = meshes,
    materials = materials,
    entry = entry,
  }

  sets[key] = set
  byEntry[entry] = set

  return set
end

local function locate(model: Instance, key: string): Instance?
  for _, child in model:GetChildren() do
    if child:IsA("Folder") and child.Name == "Frames" and child:GetAttribute("FrameSet") == key then
      return child
    end
  end

  return nil
end

-- a copy of a frame part that draws nothing and sits out of view, holding only what its kind of mesh needs
local function parked(source: BasePart, keep: boolean): BasePart
  const copy = source:Clone()

  for _, child in copy:GetChildren() do
    if not (keep and child:IsA("SpecialMesh")) then
      child:Destroy()
    end
  end

  copy.Name = source.Name
  copy.Archivable = false
  copy.Locked = true
  copy.Anchored = true
  copy.CanCollide = false
  copy.CanQuery = false
  copy.CanTouch = false
  copy.CastShadow = false
  copy.Transparency = 1
  copy.Size = Vector3.zero
  copy.CFrame = PARK

  return copy
end

local function build(set: Set, holder: Instance)
  local textures = 0

  for _, frame in set.frames do
    const material = materialOf(frame.source) :: any

    frame.mesh = parked(frame.source, true)
    frame.mesh.Parent = holder

    if material then
      frame.strength = material.EmissiveStrength
      frame.tint = material.EmissiveTint
      textures += frame_store.engine.maps(material)

      const home = parked(frame.source, false)
      const copy = material:Clone()

      copy.Parent = home
      home.Parent = holder
      frame.material = copy
      homes[frame] = home
    end
  end

  set.entry.textures = textures
  built[set] = true
end

local function let(set: Set)
  for _, frame in set.frames do
    if frame.mesh then
      frame.mesh.Parent = nil
    end

    if homes[frame] then
      homes[frame].Parent = nil
    end
  end

  set.entry.parked = false
end

function frame_store.init(scope: { any })
  const holder = containers.of("frames")

  park = holder

  table.clear(sets)
  table.clear(byEntry)
  table.clear(built)
  table.clear(homes)
  table.clear(out)

  table.insert(scope, function()
    for _, set in sets do
      for _, frame in set.frames do
        if frame.mesh then
          frame.mesh:Destroy()
        end

        if homes[frame] then
          homes[frame]:Destroy()
        end
      end
    end

    table.clear(sets)
    table.clear(byEntry)
    table.clear(built)
    table.clear(homes)
    table.clear(out)
    park = nil
  end)
end

function frame_store.find(model: Instance, key: string): Set?
  const folder = locate(model, key)
  local set = sets[key]

  if set == nil and folder ~= nil then
    set = register(folder, key)
  end

  if folder ~= nil and frame_store.engine.detaches() then
    folder.Parent = nil
  end

  return set
end

function frame_store.warm(set: Set)
  const entry = set.entry

  if not entry.parked then
    const holder = park or containers.of("frames")

    if built[set] then
      for _, frame in set.frames do
        if frame.mesh then
          frame.mesh.Parent = holder
        end

        if homes[frame] then
          homes[frame].Parent = holder
        end
      end
    else
      build(set, holder)
    end

    entry.parked = true
  end

  entry.used = frame_store.engine.now()

  const entries = {}

  for _, other in sets do
    table.insert(entries, other.entry)
  end

  for _, gone in frames_common.evict(entries, budget, entry) do
    let(byEntry[gone])
  end
end

function frame_store.lend(set: Set, index: number): Instance?
  const frame = set.frames[index]
  const material = if frame then frame.material else nil

  if material == nil then
    return nil
  end

  set.entry.lent += 1

  if not out[frame] then
    out[frame] = true

    return material
  end

  const copy = material:Clone() :: any

  copy.EmissiveStrength = frame.strength
  copy.EmissiveTint = frame.tint

  return copy
end

function frame_store.giveBack(set: Set, index: number, material: Instance)
  const frame = set.frames[index]

  if frame == nil then
    material:Destroy()

    return
  end

  set.entry.lent = math.max(set.entry.lent - 1, 0)

  if material ~= frame.material then
    material:Destroy()

    return
  end

  const held = material :: any

  held.EmissiveStrength = frame.strength
  held.EmissiveTint = frame.tint
  held.Parent = homes[frame]
  out[frame] = nil
end

function frame_store.setBudget(textures: number)
  budget = textures
end

function frame_store.getBudget(): number
  return budget
end

return frame_store
