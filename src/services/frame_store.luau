local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")

local logger = require("@mod/logger")
local pool = require("@srv/pool")
local containers = require("@srv/containers")
local frames_common = require("@mod/common/frames")

export type Frame = {
  source: BasePart,
  mesh: BasePart?,
  meshId: string?,
  material: Instance?,
  bounds: frames_common.Bounds?,
  strength: number?,
  tint: Color3?,
  color: Color3?,
  transparency: number?,
}

export type Set = {
  key: string,
  frames: { Frame },
  union: frames_common.Bounds?,
  meshes: boolean,
  materials: boolean,
  entry: frames_common.Entry,
}

-- what tells a folder of frames from a folder of textures, and whether its frames are shapes to park
type Kind = { folder: string, key: string, count: string, shaped: boolean }

local DEFAULT_BUDGET = 128
local PARK = CFrame.new(0, -20000, 0)

local MAPS =
  { "ColorMapContent", "EmissiveMaskContent", "NormalMapContent", "RoughnessMapContent", "MetalnessMapContent" }

const FRAMES: Kind = { folder = "Frames", key = "FrameSet", count = "FrameCount", shaped = true }
const TEXTURES: Kind = { folder = "Textures", key = "TextureSet", count = "TextureCount", shaped = false }

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
  clone = function(instance: Instance): Instance?
    return instance:Clone()
  end,
  -- loads what the parts hold off the frame, calling `each` as each asset settles and `done` once all have
  preload = function(parts: { Instance }, each: (id: string) -> (), done: () -> ())
    task.spawn(function()
      pcall(function()
        ContentProvider:PreloadAsync(parts, each)
      end)

      done()
    end)
  end,
}

local sets: { [string]: Set } = {}
local byEntry: { [frames_common.Entry]: Set } = {}
local built: { [Set]: boolean } = {}
local homes: { [Frame]: BasePart } = {}
local out: { [Frame]: boolean } = {}
const refused: { [string]: { any } } = {}
const shapeless: { [Set]: boolean } = {}
const starts: { [Set]: BasePart } = {}
const requested: { [Set]: boolean } = {}

-- a mesh's first ApplyMesh onto a part in the world blocks until the engine holds the mesh, so a frame is
-- applied only once its mesh has settled from a preload. a fetch status of Success is not that: a mesh
-- only drawn has it and still blocks
const settled: { [string]: boolean } = {}
const asked: { [string]: boolean } = {}

local budget = DEFAULT_BUDGET
local park: BasePart? = nil

-- the folders a client detached, kept through a restart of the store, which would find none under their models
const kept: { [string]: Instance } = {}

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

-- frame k is the part named k, so a gap below the highest number is a folder still streaming in, as is one
-- naming a count it does not yet hold, or an apply is not done with it
const function whole(folder: Instance, kind: Kind): boolean
  const count = folder:GetAttribute(kind.count)
  const named = {}
  local parts, highest = 0, 0

  for _, child in frames_common.order(folder:GetChildren()) do
    const number = tonumber(child.Name) :: number

    if child:IsA("BasePart") and not named[number] then
      named[number] = true
      parts += 1
      highest = math.max(highest, number)
    end
  end

  if parts ~= highest then
    return false
  end

  return type(count) ~= "number" or count ~= math.floor(count) or parts >= count
end

local function register(folder: Instance, key: string, kind: Kind): Set
  const frames = {}
  local meshes, materials = false, false
  const named = {}
  local first: string? = nil

  for _, child in frames_common.order(folder:GetChildren()) do
    const number = tonumber(child.Name) :: number

    if child:IsA("BasePart") and not named[number] then
      named[number] = true

      if kind.shaped then
        const id = meshIdOf(child)
        const meshId = if child:IsA("MeshPart") and id ~= "" then id else nil

        table.insert(frames, { source = child, meshId = meshId, bounds = bounds(child, "FrameSize", "FrameCenter") })

        if #frames == 1 then
          first = id
        elseif id ~= nil and id ~= first then
          meshes = true
        end
      else
        table.insert(frames, { source = child })
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
    union = if kind.shaped then bounds(folder, "UnionSize", "UnionCenter") else nil,
    meshes = meshes,
    materials = materials,
    entry = entry,
  }

  sets[key] = set
  byEntry[entry] = set
  shapeless[set] = not kind.shaped

  const start = folder.Parent and folder.Parent:FindFirstChild("Start")

  if kind.shaped and start and start:IsA("MeshPart") then
    starts[set] = start
  end

  return set
end

local function locate(model: Instance, key: string, kind: Kind): Instance?
  for _, child in model:GetChildren() do
    if child:IsA("Folder") and child.Name == kind.folder and child:GetAttribute(kind.key) == key then
      return child
    end
  end

  return nil
end

-- a copy of a frame part that draws nothing and sits out of view, holding only what its kind of mesh needs
local function parked(source: BasePart, keep: boolean): BasePart?
  const copy = frame_store.engine.clone(source) :: BasePart?

  if copy == nil then
    return nil
  end

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

-- what a refused build read, so a set is built again only once something it was refused for has changed
const function signature(set: Set): { any }
  const read = {}

  for _, frame in set.frames do
    const material = materialOf(frame.source)

    table.insert(read, frame.source.Archivable)
    table.insert(read, material)
    table.insert(read, if material then material.Archivable else false)
  end

  return read
end

const function same(a: { any }, b: { any }): boolean
  if #a ~= #b then
    return false
  end

  for index, value in a do
    if b[index] ~= value then
      return false
    end
  end

  return true
end

const function abandon(set: Set, made: { Instance })
  for _, instance in made do
    instance:Destroy()
  end

  for _, frame in set.frames do
    frame.mesh = nil
    frame.material = nil
    homes[frame] = nil
  end

  refused[set.key] = signature(set)
  logger.warn(`frame set {set.key} was not parked: a frame or its material is not Archivable, so it cannot be copied`)
end

-- every copy a set parks, or none of them: the engine clones nothing for an instance that is not Archivable
local function build(set: Set, holder: Instance): boolean
  const shaped = not shapeless[set]
  const made: { Instance } = {}
  local textures = 0

  const function keep(instance: Instance?): any
    if instance ~= nil then
      table.insert(made, instance)
    end

    return instance
  end

  for _, frame in set.frames do
    const material = materialOf(frame.source) :: any
    const mesh = if shaped then keep(parked(frame.source, true)) else nil
    const home = if material then keep(parked(frame.source, false)) else nil
    const copy = if material then keep(frame_store.engine.clone(material)) else nil

    if (shaped and mesh == nil) or (material and (home == nil or copy == nil)) then
      abandon(set, made)

      return false
    end

    if mesh then
      frame.mesh = mesh
      mesh.Parent = holder
    end

    if material then
      frame.strength = material.EmissiveStrength
      frame.tint = material.EmissiveTint
      frame.color = if material:IsA("Decal") then material.Color3 else material.Color
      frame.transparency = if material:IsA("Decal") then material.Transparency else nil
      textures += frame_store.engine.maps(material)

      copy.Parent = home
      home.Parent = holder
      frame.material = copy
      homes[frame] = home
    end
  end

  set.entry.textures = textures
  built[set] = true
  refused[set.key] = nil

  return true
end

-- a set's copies destroyed, to be built again: a material still lent is destroyed when it is given back
const function drop(set: Set)
  for _, frame in set.frames do
    if frame.mesh then
      frame.mesh:Destroy()
    end

    if homes[frame] then
      homes[frame]:Destroy()
    end

    frame.mesh = nil
    frame.material = nil
    homes[frame] = nil
    out[frame] = nil
  end

  built[set] = nil
  set.entry.parked = false
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

const function evict(keep: frames_common.Entry?)
  const entries = {}

  for _, set in sets do
    table.insert(entries, set.entry)
  end

  for _, gone in frames_common.evict(entries, budget, keep) do
    let(byEntry[gone])
  end
end

-- the meshes a set may apply, loaded off the frame before playback reaches them
const function request(set: Set)
  requested[set] = true

  const parts: { Instance } = {}
  const ids: { string } = {}

  const function ask(part: Instance, id: string?)
    if id == nil or id == "" or asked[id] then
      return
    end

    asked[id] = true
    table.insert(parts, part)
    table.insert(ids, id)
  end

  if starts[set] then
    ask(starts[set], meshIdOf(starts[set]))
  end

  for _, frame in set.frames do
    ask(frame.source, frame.meshId)
  end

  if #parts == 0 then
    return
  end

  frame_store.engine.preload(parts, function(id: string)
    if asked[id] then
      settled[id] = true
    end
  end, function()
    for _, id in ids do
      settled[id] = true
    end
  end)
end

function frame_store.init(scope: { any })
  const holder = containers.of("frames")

  park = holder
  budget = DEFAULT_BUDGET

  table.clear(sets)
  table.clear(byEntry)
  table.clear(built)
  table.clear(homes)
  table.clear(out)
  table.clear(refused)
  table.clear(shapeless)
  table.clear(starts)
  table.clear(requested)
  table.clear(settled)
  table.clear(asked)

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
    table.clear(shapeless)
    table.clear(starts)
    table.clear(requested)
    park = nil
  end)
end

-- a folder of `kind` under the model registered by its key, and on a client detached from the model and
-- from the template it was copied from, so later copies carry none
const function found(model: Instance, key: string, kind: Kind): Set?
  local set = sets[key]
  const folder = locate(model, key, kind) or if set == nil then kept[key] else nil

  if folder == nil then
    return set
  end

  const detaches = frame_store.engine.detaches()

  if (set == nil or detaches) and not whole(folder, kind) then
    return set
  end

  if set == nil then
    set = register(folder, key, kind)
  end

  if detaches then
    kept[key] = folder
    folder.Parent = nil

    const template = pool.templateOf(model)
    const original = if template then locate(template, key, kind) else nil

    if original ~= nil then
      original.Parent = nil
    end
  end

  return set
end

function frame_store.find(model: Instance, key: string): Set?
  return found(model, key, FRAMES)
end

-- a set whose frames carry only a material, worn on a clock of its own beside any frame set
function frame_store.findTextures(model: Instance, key: string): Set?
  return found(model, key, TEXTURES)
end

function frame_store.warm(set: Set)
  const entry = set.entry
  const holder = containers.of("frames")

  if set.meshes and not requested[set] then
    request(set)
  end

  -- the copies under a holder that was destroyed went with it
  if holder ~= park then
    for other in built do
      drop(other)
    end

    park = holder
  end

  local changed = false

  if not entry.parked then
    if built[set] then
      for _, frame in set.frames do
        if frame.mesh then
          frame.mesh.Parent = holder
        end

        if homes[frame] then
          homes[frame].Parent = holder
        end
      end
    elseif refused[set.key] and same(refused[set.key], signature(set)) then
      return
    elseif not build(set, holder) then
      return
    end

    entry.parked = true
    changed = true
  end

  entry.used = frame_store.engine.now()

  if changed then
    evict(entry)
  end
end

-- whether frame `index` applies without blocking on its mesh: one never asked for is applied as it is
function frame_store.ready(set: Set, index: number): boolean
  const frame = set.frames[index]
  const id = if frame then frame.meshId else nil

  return id == nil or not asked[id] or settled[id] == true
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

  if frame.color ~= nil then
    if copy:IsA("Decal") then
      copy.Color3 = frame.color
    else
      copy.Color = frame.color
    end
  end

  if frame.transparency ~= nil then
    copy.Transparency = frame.transparency
  end

  return copy
end

function frame_store.giveBack(set: Set, index: number, material: Instance)
  const frame = set.frames[index]

  if frame == nil then
    material:Destroy()

    return
  end

  if set.entry.lent == 0 then
    error("a frame was given back with none lent", 2)
  end

  set.entry.lent -= 1

  if material ~= frame.material then
    material:Destroy()

    return
  end

  const held = material :: any

  held.EmissiveStrength = frame.strength
  held.EmissiveTint = frame.tint

  if frame.color ~= nil then
    if held:IsA("Decal") then
      held.Color3 = frame.color
    else
      held.Color = frame.color
    end
  end

  if frame.transparency ~= nil then
    held.Transparency = frame.transparency
  end

  held.Parent = homes[frame]
  out[frame] = nil
end

function frame_store.setBudget(textures: number)
  budget = textures
  evict(nil)
end

function frame_store.getBudget(): number
  return budget
end

return frame_store
