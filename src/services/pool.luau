local utility = require("@mod/utility")
local registry = require("@mod/registry")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")

local mover = require("@srv/mover")

local FLOOR = 64
local BUCKET = 15
local EVERY = 1
local FOLDER = "DO_NOT_REMOVE_ForgeSharedPartCache"

-- a clone carries every serialized property but these, which a copy keeps
-- its own of
local SKIP = { Name = true, Parent = true, Archivable = true }

-- where an effect places a piece itself, so a take never moves it there first
local PLACED = { CFrame = true }

-- every bit of these classes' state is a serialized property, or is reset by
-- settle; anything else under a template makes it clone fresh every emit
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

type Store = {
  free: { Instance },
  used: number,
  peak: number,
  previous: number,
  turned: number,
  floor: number,
}

type Template = Store & {
  template: Instance,
  keep: boolean?,
  generation: number,
  watch: { any }?,
}

type Set = {
  root: Instance,
  key: Template,
  generation: number,
  members: { Instance },
  twins: { Instance },
  parents: { Instance },
  map: { [Instance]: Instance },
  hides: { { index: number, name: string, value: any } },
  conns: { any },
  dirty: boolean,
}

type Taken = { holder: any, store: Store, set: Set?, released: boolean }

local pool = {}

local folder: Instance? = nil
local seen = 0
local counts = { builds = 0, reuses = 0, fresh = 0, made = 0 }

local lists: { [string]: { string } | false } = {}
local restorable: { [string]: boolean } = {}

local stacks: { [string]: Store } = {}
local templates: { [Instance]: Template } = {}

local taken: { [Instance]: Taken } = {}
local storeOf: { [Instance]: Store } = {}
local setOf: { [Instance]: Set } = {}
local memberOf: { [Instance]: Set } = {}
local indexOf: { [Instance]: number } = {}
local known: { [Instance]: any } = {}

pool.engine = {
  folder = function(scope: { any }): Instance
    local made = Instance.new("Folder")
    made.Name = FOLDER
    made.Archivable = false
    made.Parent = workspace.Terrain

    utility.protectParent(scope, made)

    return made
  end,

  fromExisting = function(source: Instance): Instance
    return Instance.fromExisting(source)
  end,

  applyMesh = function(part: Instance, source: Instance)
    (part :: MeshPart):ApplyMesh(source :: MeshPart)
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
      local permits = property.Permits

      if not property.Serialized or SKIP[property.Name] or permits == nil then
        continue
      end

      if permits.Read == nil or permits.Write == nil then
        continue
      end

      -- an empty set of capabilities is a write any script may make
      if tostring(permits.Write) ~= "" then
        continue
      end

      table.insert(list, property.Name)
    end

    return list
  end,

  watch = function(template: Instance, changed: () -> ()): { any }
    local conns = {
      template.DescendantAdded:Connect(changed),
      template.DescendantRemoving:Connect(changed),
      template.AncestryChanged:Connect(changed),
    }

    for _, desc in template:GetDescendants() do
      table.insert(conns, desc.Changed:Connect(changed))
      table.insert(conns, desc.AttributeChanged:Connect(changed))
    end

    return conns
  end,

  listen = function(inst: Instance, changed: () -> ()): any
    return inst.AttributeChanged:Connect(changed)
  end,

  -- the walk a release clears, so a test host can answer the wrappers it holds
  children = function(inst: Instance): { Instance }
    return inst:GetChildren()
  end,

  destroying = function(inst: Instance, fn: () -> ()): any
    return inst.Destroying:Connect(fn)
  end,

  -- what a property does not hold: live particles and trail segments, a
  -- playing sound, a model's scale and pivot
  settle = function(inst: Instance, twin: Instance?)
    if inst:IsA("ParticleEmitter") or inst:IsA("Trail") then
      (inst :: any):Clear()
    elseif inst:IsA("Sound") then
      (inst :: Sound):Stop()
    elseif inst:IsA("Model") and twin ~= nil then
      local model = inst :: Model
      local authored = twin :: Model

      model:ScaleTo(authored:GetScale())
      model.WorldPivot = authored.WorldPivot
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

local function canRestore(inst: Instance): boolean
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

-- what a free copy is hidden by, and so what a take puts back from its twin
local function hideOf(inst: Instance): (string?, any)
  if inst:IsA("BasePart") then
    return "LocalTransparencyModifier", 1
  end

  if inst:IsA("FaceInstance") then
    return "Transparency", 1
  end

  if inst:IsA("GuiObject") then
    return "Visible", false
  end

  for _, class in { "Beam", "Light", "Trail", "Highlight", "SurfaceGui", "BillboardGui", "ParticleEmitter" } do
    if inst:IsA(class) then
      return "Enabled", false
    end
  end

  return nil, nil
end

local function store(floor: number): Store
  return { free = {}, used = 0, peak = 0, previous = 0, turned = os.clock(), floor = floor }
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
  local set = setOf[inst]

  if set ~= nil then
    for _, member in set.members do
      memberOf[member] = nil
      indexOf[member] = nil
    end

    for _, conn in set.conns do
      conn:Disconnect()
    end

    setOf[inst] = nil
  end

  local s = storeOf[inst]

  if s ~= nil then
    local index = table.find(s.free, inst)

    if index ~= nil then
      table.remove(s.free, index)
    end

    storeOf[inst] = nil
  end

  local conn = known[inst]

  if conn ~= nil then
    conn:Disconnect()
    known[inst] = nil
  end

  taken[inst] = nil
  indexOf[inst] = nil
  memberOf[inst] = nil
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

local function dress(inst: Instance, source: Instance)
  if inst:IsA("MeshPart") and (inst :: MeshPart).MeshId ~= (source :: MeshPart).MeshId then
    pool.engine.applyMesh(inst, source)
  end

  for _, name in listOf(source.ClassName) :: { string } do
    local value = (source :: any)[name]

    if PLACED[name] or (inst :: any)[name] == value then
      continue
    end

    (inst :: any)[name] = value
  end

  inst.Name = source.Name

  if inst:IsA("BasePart") then
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

local function fresh(holder: any, source: Instance): Instance
  local copy = utility.clone(source)

  counts.fresh += 1

  if folder ~= nil then
    copy.Parent = folder
  end

  if copy:IsA("BasePart") then
    (copy :: BasePart).Anchored = true
  end

  holdIn(holder, copy)

  return copy
end

-- a member goes back where its set put it, anything else the pool owns to the
-- folder, so clearing a released instance's children never destroys either
local function rescue(inst: Instance): boolean
  local set = memberOf[inst]

  if set ~= nil then
    inst.Parent = set.parents[indexOf[inst]]
    return true
  end

  if taken[inst] ~= nil or storeOf[inst] ~= nil then
    inst.Parent = folder
    return true
  end

  return false
end

local function trim(s: Store)
  local cap = math.max(s.floor, s.peak, s.previous)

  while #s.free > cap do
    destroy(table.remove(s.free) :: Instance)
  end

  local t = s :: Template

  if t.template == nil or s.used > 0 or #s.free > 0 then
    return
  end

  for _, conn in t.watch or {} do
    conn:Disconnect()
  end

  t.watch = nil
  templates[t.template] = nil
end

local finish: (inst: Instance, record: Taken) -> ()
local putBack: (set: Set) -> boolean

local function begin(holder: any, inst: Instance, s: Store, set: Set?): Instance
  s.used += 1

  if s.used > s.peak then
    s.peak = s.used
  end

  local record: Taken = { holder = holder, store = s, set = set, released = false }

  taken[inst] = record

  if inst:IsA("BasePart") then
    mover.assign(inst :: BasePart, holder)
  end

  holdIn(holder, function()
    finish(inst, record)
  end)

  return inst
end

local function single(holder: any, source: Instance): Instance
  if not canRestore(source) then
    return fresh(holder, source)
  end

  local class = source.ClassName
  local s = stacks[class]

  if s == nil then
    s = store(FLOOR)
    stacks[class] = s
  end

  local inst = table.remove(s.free)

  if inst == nil then
    inst = pool.engine.fromExisting(source)
    counts.made += 1
    strip(inst)
    track(inst)
  else
    storeOf[inst] = nil
    counts.reuses += 1
  end

  dress(inst, source)

  return begin(holder, inst, s, nil)
end

finish = function(inst: Instance, record: Taken)
  if record.released then
    return
  end

  record.released = true
  taken[inst] = nil

  local s = record.store
  s.used -= 1

  if inst:IsA("BasePart") then
    mover.drop(inst :: BasePart)
  end

  if known[inst] == nil or folder == nil then
    return
  end

  local set = record.set

  if set ~= nil then
    if not putBack(set) then
      destroy(inst)
      return
    end
  else
    for _, child in pool.engine.children(inst) do
      if not rescue(child) then
        child:Destroy()
      end
    end

    pool.engine.settle(inst, nil)
    strip(inst)

    local name, value = hideOf(inst)

    if name ~= nil and not inst:IsA("BasePart") then
      (inst :: any)[name] = value
    end
  end

  if inst:IsA("BasePart") then
    inert(inst :: BasePart)
  end

  if inst.Parent ~= folder then
    inst.Parent = folder
  end

  table.insert(s.free, inst)
  storeOf[inst] = s

  trim(s)
end

putBack = function(_: Set): boolean
  return false
end

local function refresh()
  seen = registry.version
end

-- a member of a kept copy answers its authored twin, so nested pieces share
-- the template's stores rather than one per copy
local function twinOf(source: Instance): Instance
  local set = memberOf[source]

  if set ~= nil then
    return set.twins[indexOf[source]]
  end

  return source
end

local function kept(holder: any, key: Instance): Instance
  -- a clone of a class the pool cannot restore carries its children already
  if not canRestore(key) then
    return fresh(holder, key)
  end

  local inst = single(holder, key)

  for _, child in key:GetChildren() do
    local copy = utility.clone(child)

    if copy ~= nil then
      copy.Parent = inst
    end
  end

  return inst
end

function pool.take(holder: any, source: Instance, alone: boolean?): Instance
  if folder == nil then
    return fresh(holder, source)
  end

  if registry.version ~= seen then
    refresh()
  end

  local key = twinOf(source)

  if alone or #key:GetChildren() == 0 then
    return single(holder, key)
  end

  return kept(holder, key)
end

-- the once a second tick: each store keeps the larger of its floor and the
-- peak in use over the last two buckets
function pool.sweep(now: number)
  for _, map in { stacks, templates } :: { { [any]: Store } } do
    for _, s in map do
      if now - s.turned >= BUCKET then
        s.previous = s.peak
        s.peak = s.used
        s.turned = now
      end

      trim(s)
    end
  end
end

function pool.kept(inst: Instance): boolean
  return memberOf[inst] ~= nil
end

function pool.stats()
  return table.clone(counts)
end

function pool.init(scope: { any })
  folder = pool.engine.folder(scope)
  seen = registry.version

  local last = os.clock()

  local tick = scheduler.add("compute", function()
    local now = os.clock()

    if now - last < EVERY then
      return
    end

    last = now
    pool.sweep(now)
  end, 0, nil, true)

  table.insert(scope, function()
    tick:Disconnect()

    for _, template in templates do
      for _, conn in template.watch or {} do
        conn:Disconnect()
      end
    end

    for _, set in setOf do
      for _, conn in set.conns do
        conn:Disconnect()
      end
    end

    local made = folder

    folder = nil

    for _, map in { stacks, templates, taken, storeOf, setOf, memberOf, indexOf, known, lists, restorable } :: { any } do
      table.clear(map)
    end

    counts.builds, counts.reuses, counts.fresh, counts.made = 0, 0, 0, 0

    mover.clear()

    if made ~= nil then
      made:Destroy()
    end
  end)
end

return pool
