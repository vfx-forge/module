local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")

local mover = require("@srv/mover")
local containers = require("@srv/containers")

local FLOOR = 64
local BUCKET = 15
local EVERY = 1
local FOLDER = "Pool"

-- a clone carries every serialized property but these, which a copy keeps
-- its own of
local SKIP = { Name = true, Parent = true, Archivable = true }

-- a part's look the engine saves under a name no script may write, by the
-- name a script writes it under
local SAVED_AS = {
  size = "Size",
  shape = "Shape",
  style = "Style",
  Color3uint8 = "Color",
  MaterialVariantSerialized = "MaterialVariant",
}

-- where an effect places a part itself, so a take never moves it there first;
-- an attachment's CFrame is its offset from its parent, which a take copies
local PLACED = { CFrame = true }

-- a source's motion never reaches a piece, which starts from the rest its
-- release left it at: debris reads a piece's velocity as its launch's start
local MOTION = { Velocity = true, RotVelocity = true, AssemblyLinearVelocity = true, AssemblyAngularVelocity = true }

-- every bit of these classes' state is a serialized property, or is reset by
-- settle; a single of any other class is cloned fresh every take
local RESTORABLE = {
  "Beam",
  "Light",
  "Model",
  "Sound",
  "Trail",
  "Folder",
  "BasePart",
  "GuiObject",
  "Highlight",
  "SurfaceGui",
  "Attachment",
  "ValueBase",
  "BillboardGui",
  "FaceInstance",
  "UIComponent",
  "Configuration",
  "DataModelMesh",
  "ParticleEmitter",
  "SurfaceAppearance",
  "Weld",
  "WeldConstraint",
}

-- what a free copy is hidden by, and so what a take puts back from its source;
-- a free part must not collide, be queried, be touched or be selected either
local HIDES = {
  part = { LocalTransparencyModifier = 1, CanCollide = false, CanQuery = false, CanTouch = false, Locked = true },
  face = { Transparency = 1 },
  gui = { Visible = false },
  sound = { Playing = false, PlayOnRemove = false },
  enabled = { Enabled = false },
}

local ENABLED = { "Beam", "Light", "Trail", "Highlight", "SurfaceGui", "BillboardGui", "ParticleEmitter" }

type Store = {
  free: { Instance },
  used: number,
  peak: number,
  previous: number,
  turned: number,
  floor: number,
  key: string?,
}

type Taken = { holder: any, store: Store, released: boolean }

local pool = {}

local folder: Instance? = nil
local counts = { reuses = 0, fresh = 0, made = 0 }

local lists: { [string]: { string } | false } = {}
local links: { [string]: { string } } = {}
local restorable: { [string]: boolean } = {}
local hiddenBy: { [string]: { [string]: any } | false } = {}

local stacks: { [string]: Store } = {}

local taken: { [Instance]: Taken } = {}
local storeOf: { [Instance]: Store } = {}
local known: { [Instance]: any } = {}
local loose: { [Instance]: true } = setmetatable({}, { __mode = "k" }) :: any
local sources: { [Instance]: Instance } = setmetatable({}, { __mode = "k" }) :: any

pool.engine = {
  folder = function(scope: { any })
    local made = Instance.new("Folder")
    made.Name = FOLDER
    made.Archivable = false
    local home = containers.root()

    made.Parent = home

    utility.protectParent(scope, made, home)

    return made
  end,

  fromExisting = function(source: Instance)
    return Instance.fromExisting(source)
  end,

  -- a MeshPart's mesh and what the engine builds of it; a part serves only its
  -- own, since a first ApplyMesh of a mesh stalls for hundreds of milliseconds
  mesh = function(part: Instance): string?
    local mesh = part :: MeshPart

    -- an EditableMesh or other object content has no id a key could name
    if mesh.MeshId == "" and mesh.MeshContent.SourceType ~= Enum.ContentSourceType.None then
      return nil
    end

    return `{mesh.MeshId}|{mesh.RenderFidelity.Name}|{mesh.CollisionFidelity.Name}`
  end,

  -- every property a clone carries and any script may write; nil for a class
  -- the engine cannot describe
  properties = function(class: string): { string }?
    local ok, found = pcall(function()
      return game:GetService("ReflectionService"):GetPropertiesOfClass(class)
    end)

    if not ok then
      return nil
    end

    local list = {}

    for _, property in found do
      local name = property.Name
      local permits = property.Permits

      if not property.Serialized or SKIP[name] or permits == nil then
        continue
      end

      if SAVED_AS[name] ~= nil and permits.Write == nil then
        table.insert(list, SAVED_AS[name])
        continue
      end

      if permits.Read == nil or permits.Write == nil then
        continue
      end

      -- no capability, or Basic, which every script outside a sandbox holds
      local write = tostring(permits.Write)

      if write ~= "" and write ~= "Basic" then
        continue
      end

      table.insert(list, name)
    end

    return list
  end,

  -- every property of a class that names an instance; a free copy lets go of
  -- what the listed ones name
  references = function(class: string): { string }
    local ok, found = pcall(function()
      return game:GetService("ReflectionService"):GetPropertiesOfClass(class)
    end)

    local list = {}

    if not ok then
      return list
    end

    for _, property in found do
      local kind = property.Type

      if kind ~= nil and kind.ScriptType == "Instance" then
        table.insert(list, property.Name)
      end
    end

    return list
  end,

  -- every walk of a released copy, so a test host can answer the wrappers it
  -- holds
  children = function(inst: Instance)
    return inst:GetChildren()
  end,

  destroying = function(inst: Instance, fn: () -> ())
    return inst.Destroying:Connect(fn)
  end,

  -- what a property does not hold: live particles and trail segments, and a
  -- playing sound
  settle = function(inst: Instance)
    if inst:IsA("ParticleEmitter") or inst:IsA("Trail") then
      (inst :: any):Clear()
    elseif inst:IsA("Sound") then
      (inst :: Sound):Stop()
    end
  end,
}

local function listOf(class: string): { string }?
  local list = lists[class]

  if list == nil then
    list = pool.engine.properties(class) or false
    lists[class] = list
  end

  return if list == false then nil else list
end

-- the listed properties of a class that name an instance
local function linksOf(class: string): { string }
  local found = links[class]

  if found == nil then
    local list = listOf(class) or {}

    found = {}

    for _, name in pool.engine.references(class) do
      if table.find(list, name) then
        table.insert(found, name)
      end
    end

    links[class] = found
  end

  return found
end

local function canRestore(inst: Instance)
  local class = inst.ClassName
  local verdict = restorable[class]

  if verdict ~= nil then
    return verdict
  end

  verdict = false

  for _, name in RESTORABLE do
    if inst:IsA(name) then
      verdict = listOf(class) ~= nil
      break
    end
  end

  restorable[class] = verdict

  return verdict
end

local function hideOf(inst: Instance): { [string]: any }?
  local class = inst.ClassName
  local found = hiddenBy[class]

  if found == nil then
    found = false

    if inst:IsA("BasePart") then
      found = HIDES.part
    elseif inst:IsA("FaceInstance") then
      found = HIDES.face
    elseif inst:IsA("GuiObject") then
      found = HIDES.gui
    elseif inst:IsA("Sound") then
      found = HIDES.sound
    else
      for _, name in ENABLED do
        if inst:IsA(name) then
          found = HIDES.enabled
          break
        end
      end
    end

    hiddenBy[class] = found
  end

  return if found == false then nil else found
end

local function store(floor: number): Store
  return { free = {}, used = 0, peak = 0, previous = 0, turned = os.clock(), floor = floor }
end

-- one stack a class, but one a mesh for a MeshPart, kept only while its recent
-- peak asks; nil for a mesh no key can name, which is copied fresh
local function stackOf(source: Instance): Store?
  local key = source.ClassName
  local mesh = key == "MeshPart"

  if mesh then
    local named = pool.engine.mesh(source)

    if named == nil then
      return nil
    end

    key = `{key}|{named}`
  end

  local stack = stacks[key]

  if stack == nil then
    stack = store(if mesh then 0 else FLOOR)
    stack.key = if mesh then key else nil
    stacks[key] = stack
  end

  return stack
end

local function strip(inst: Instance)
  for _, tag in inst:GetTags() do
    inst:RemoveTag(tag)
  end

  for name in inst:GetAttributes() do
    inst:SetAttribute(name, nil)
  end
end

local function forgetOne(inst: Instance)
  local stack = storeOf[inst]

  if stack ~= nil then
    local index = table.find(stack.free, inst)

    if index ~= nil then
      table.remove(stack.free, index)
    end

    storeOf[inst] = nil
  end

  local conn = known[inst]

  if conn ~= nil then
    conn:Disconnect()
    known[inst] = nil
  end

  if inst:IsA("BasePart") then
    mover.drop(inst :: BasePart)
  end

  taken[inst] = nil
end

local function destroy(inst: Instance)
  forgetOne(inst)
  inst:Destroy()
end

local function track(inst: Instance)
  known[inst] = pool.engine.destroying(inst, function()
    forgetOne(inst)
  end)

  inst.Archivable = false
  inst.Parent = folder
end

-- a new copy, at the rest a released one is left at
local function copyOf(source: Instance)
  local inst = pool.engine.fromExisting(source)

  counts.made += 1
  strip(inst)
  track(inst)

  if inst:IsA("BasePart") then
    local part = inst :: BasePart
    part.AssemblyLinearVelocity = Vector3.zero
    part.AssemblyAngularVelocity = Vector3.zero
  end

  return inst
end

local function dress(inst: Instance, source: Instance)
  local isPart = inst:IsA("BasePart")

  for _, name in listOf(source.ClassName) :: { string } do
    if (isPart and PLACED[name]) or MOTION[name] then
      continue
    end

    local value = (source :: any)[name]

    if (inst :: any)[name] ~= value then
      (inst :: any)[name] = value
    end
  end

  inst.Name = source.Name

  if isPart then
    local part = inst :: BasePart
    part.Anchored = true
    part.Locked = true
  end
end

local function inert(part: BasePart)
  part.Transparency = 1
  part.Anchored = true
  part.CanCollide = false
  part.CanQuery = false
  part.CanTouch = false
  part.CollisionGroup = "ForgeMouseIgnore"
  part.AssemblyLinearVelocity = Vector3.zero
  part.AssemblyAngularVelocity = Vector3.zero
end

local function holdIn(holder: any, value: any)
  if holder.emit ~= nil and holder.state ~= nil then
    lifetime.hold(holder, value)
  else
    table.insert(holder, value)
  end
end

-- a whole clone, held by the holder and destroyed when it lets go. a bare one
-- loses its root's tags and attributes before anything can see it parented
local function fresh(holder: any, source: Instance, bare: boolean?)
  local copy = utility.clone(source)

  counts.fresh += 1

  if bare then
    strip(copy)
  end

  if folder ~= nil then
    copy.Parent = folder
  end

  if copy:IsA("BasePart") then
    (copy :: BasePart).Anchored = true
  end

  loose[copy] = true
  sources[copy] = source

  if folder ~= nil then
    pool.engine.destroying(copy, function()
      sources[copy] = nil
    end)
  end

  holdIn(holder, copy)

  return copy
end

-- the instance at an instance's place in the source of the fresh copy holding it
function pool.templateOf(inst: Instance): Instance?
  const steps = {}
  local at: Instance? = inst

  while at ~= nil and sources[at] == nil do
    const parent = at.Parent

    if parent == nil then
      return nil
    end

    local index = 0

    for _, sibling in parent:GetChildren() do
      if sibling.Name == at.Name then
        index += 1
      end

      if sibling == at then
        break
      end
    end

    table.insert(steps, 1, { name = at.Name, index = index })
    at = parent
  end

  if at == nil then
    return nil
  end

  local found: Instance? = sources[at]

  for _, step in steps do
    if found == nil then
      return nil
    end

    local seen = 0
    local next: Instance? = nil

    for _, child in found:GetChildren() do
      if child.Name == step.name then
        seen += 1

        if seen == step.index then
          next = child
          break
        end
      end
    end

    found = next
  end

  return found
end

-- anything the pool owns goes back to the folder, so clearing a released
-- instance's children never destroys it
local function rescue(inst: Instance)
  if taken[inst] ~= nil or storeOf[inst] ~= nil or loose[inst] then
    inst.Parent = folder
    return true
  end

  return false
end

local function trim(stack: Store)
  local cap = math.max(stack.floor, stack.peak, stack.previous)

  while #stack.free > cap do
    destroy(table.remove(stack.free) :: Instance)
  end

  if stack.key ~= nil and stack.used == 0 and #stack.free == 0 then
    stacks[stack.key] = nil
  end
end

local finish: (inst: Instance, record: Taken) -> ()

local function begin(holder: any, inst: Instance, stack: Store)
  stack.used += 1

  if stack.used > stack.peak then
    stack.peak = stack.used
  end

  local record: Taken = { holder = holder, store = stack, released = false }

  taken[inst] = record

  if inst:IsA("BasePart") then
    mover.assign(inst :: BasePart, holder)
  end

  holdIn(holder, function()
    finish(inst, record)
  end)

  return inst
end

local function single(holder: any, source: Instance, bare: boolean?)
  if not canRestore(source) then
    return fresh(holder, source, bare)
  end

  local stack = stackOf(source)

  if stack == nil then
    return fresh(holder, source, bare)
  end

  local inst = table.remove(stack.free)

  if inst == nil then
    inst = copyOf(source)
  else
    storeOf[inst] = nil
    counts.reuses += 1
  end

  dress(inst, source)

  return begin(holder, inst, stack)
end

finish = function(inst: Instance, record: Taken)
  if record.released then
    return
  end

  record.released = true
  taken[inst] = nil

  local stack = record.store
  stack.used -= 1

  if inst:IsA("BasePart") then
    mover.drop(inst :: BasePart)
  end

  -- nothing takes it again once the pool has stopped
  if folder == nil then
    inst:Destroy()
    return
  end

  if known[inst] == nil then
    return
  end

  -- Destroying is deferred, so one destroyed by someone else this frame is
  -- still known, and only its locked parent tells
  if inst.Parent == nil and not pcall(function()
    inst.Parent = folder
  end) then
    forgetOne(inst)
    return
  end

  for _, child in pool.engine.children(inst) do
    if not rescue(child) then
      child:Destroy()
    end
  end

  pool.engine.settle(inst)
  strip(inst)

  -- a free copy names nothing of the use it was let go from, such as a beam
  -- still naming a destroyed piece's attachments; a take dresses them back
  for _, name in linksOf(inst.ClassName) do
    if (inst :: any)[name] ~= nil then
      (inst :: any)[name] = nil
    end
  end

  if inst:IsA("BasePart") then
    inert(inst :: BasePart)
  else
    for name, value in hideOf(inst) or {} do
      (inst :: any)[name] = value
    end
  end

  if inst.Parent ~= folder then
    inst.Parent = folder
  end

  table.insert(stack.free, inst)
  storeOf[inst] = stack

  trim(stack)
end

-- a source with children is cloned whole, so a reference from one child into
-- another names the copy's own; a childless one comes from its class's stack.
-- `bare` takes a copy with none of its source's tags or attributes on its
-- root, which a single from a stack never carries anyway
function pool.take(holder: any, source: Instance, alone: boolean?, bare: boolean?)
  if folder == nil then
    return fresh(holder, source, bare)
  end

  if alone or #source:GetChildren() == 0 then
    return single(holder, source, bare)
  end

  return fresh(holder, source, bare)
end

-- the once a second tick: each stack keeps the larger of its floor and the
-- peak in use over the last two buckets
function pool.sweep(now: number)
  for _, stack in stacks do
    if now - stack.turned >= BUCKET then
      stack.previous = stack.peak
      stack.peak = stack.used
      stack.turned = now
    end

    trim(stack)
  end
end

function pool.stats()
  return table.clone(counts)
end

-- whether init has run and nothing has stopped it since
function pool.started()
  return folder ~= nil
end

function pool.init(scope: { any })
  local tick: scheduler.Handle? = nil

  -- filed ahead of the folder's parent guard, which the scope then lets go
  -- first, so destroying the folder never queues the guard's write
  table.insert(scope, function()
    if tick ~= nil then
      tick:Disconnect()
    end

    local made = folder

    folder = nil

    for _, map in { stacks, taken, storeOf, known, loose, sources, lists, links, restorable, hiddenBy } :: { any } do
      table.clear(map)
    end

    counts.reuses, counts.fresh, counts.made = 0, 0, 0

    mover.clear()

    if made ~= nil then
      made:Destroy()
    end
  end)

  folder = pool.engine.folder(scope)

  local last = os.clock()

  tick = scheduler.add("compute", function()
    local now = os.clock()

    if now - last < EVERY then
      return
    end

    last = now
    pool.sweep(now)
  end, 0, nil, true)
end

return pool
