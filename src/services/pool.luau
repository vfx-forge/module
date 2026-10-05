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

-- a template's motion never reaches a piece, which starts from the rest its
-- release left it at: debris reads a piece's velocity as its launch's start
local MOTION = { Velocity = true, RotVelocity = true, AssemblyLinearVelocity = true, AssemblyAngularVelocity = true }

-- what a MeshPart's mesh is built from, which only a copy of its own carries
local MESH = { "MeshId", "MeshContent", "RenderFidelity", "CollisionFidelity" }

-- the engine normalizes an authored rotation on write, so one slightly off
-- never reads back equal; a CFrame this close to its twin's is the same
local NEAR = 1e-4

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

-- what a free copy is hidden by, and so what a take puts back from its twin; a
-- free part must not collide, be queried, be touched or be selected either
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
local hiddenBy: { [string]: { [string]: any } | false } = {}

local stacks: { [string]: Store } = {}
local templates: { [Instance]: Template } = {}

local taken: { [Instance]: Taken } = {}
local storeOf: { [Instance]: Store } = {}
local setOf: { [Instance]: Set } = {}
local memberOf: { [Instance]: Set } = {}
local indexOf: { [Instance]: number } = {}
local known: { [Instance]: any } = {}
local loose: { [Instance]: true } = setmetatable({}, { __mode = "k" }) :: any

pool.engine = {
  folder = function(scope: { any })
    local made = Instance.new("Folder")
    made.Name = FOLDER
    made.Archivable = false
    made.Parent = workspace.Terrain

    utility.protectParent(scope, made)

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

  watch = function(template: Instance, changed: () -> ())
    local conns = {
      template.DescendantAdded:Connect(changed),
      template.DescendantRemoving:Connect(changed),
      template.AncestryChanged:Connect(changed),
    }

    for _, desc in template:GetDescendants() do
      table.insert(conns, desc.Changed:Connect(changed))
      table.insert(conns, desc.AttributeChanged:Connect(changed))
    end

    -- a take dresses the root from its template, but never gives it another
    -- mesh, so a new mesh needs a new root
    if template.ClassName == "MeshPart" then
      for _, name in MESH do
        table.insert(conns, template:GetPropertyChangedSignal(name):Connect(changed))
      end
    end

    return conns
  end,

  listen = function(inst: Instance, changed: () -> ())
    return inst.AttributeChanged:Connect(changed)
  end,

  -- every walk of a copy or its template, so a test host can answer the
  -- wrappers it holds
  children = function(inst: Instance)
    return inst:GetChildren()
  end,

  destroying = function(inst: Instance, fn: () -> ())
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

local function fresh(holder: any, source: Instance)
  local copy = utility.clone(source)

  counts.fresh += 1

  if folder ~= nil then
    copy.Parent = folder
  end

  if copy:IsA("BasePart") then
    (copy :: BasePart).Anchored = true
  end

  loose[copy] = true
  holdIn(holder, copy)

  return copy
end

-- a member goes back where its set put it, anything else the pool owns to the
-- folder, so clearing a released instance's children never destroys either
local function rescue(inst: Instance)
  local set = memberOf[inst]

  if set ~= nil then
    inst.Parent = set.parents[indexOf[inst]]
    return true
  end

  if taken[inst] ~= nil or storeOf[inst] ~= nil or loose[inst] then
    inst.Parent = folder
    return true
  end

  return false
end

-- everything under a set's root the pool owns elsewhere is sent home and never
-- walked into; answers how many of the set's own members it passed, or nil at
-- an instance the pool does not own when strict
local function sendHome(set: Set, inst: Instance, strict: boolean): number?
  local count = 0

  for _, child in pool.engine.children(inst) do
    if memberOf[child] == set then
      count += 1
    elseif rescue(child) then
      continue
    elseif strict then
      return nil
    end

    local below = sendHome(set, child, strict)

    if below == nil then
      return nil
    end

    count += below
  end

  return count
end

-- a member an effect carried out of the root, as a beam does its on-finish
-- emits, or a folder it detached
local function carried(set: Set, root: Instance, member: Instance)
  if member:IsDescendantOf(root) then
    return
  end

  sendHome(set, member, false)
  member:Destroy()
end

-- a set that cannot be filed, destroyed without what other holders still use
local function discard(root: Instance)
  local set = setOf[root]

  if set ~= nil then
    sendHome(set, root, false)

    -- a member destroyed already, or one with a locked parent, may refuse it
    for _, member in set.members do
      pcall(carried, set, root, member)
    end
  end

  destroy(root)
end

-- the copy walked against its template in step, children in order; false
-- when the two part ways
local function pair(set: Set, copy: Instance, twin: Instance)
  local copies = pool.engine.children(copy)
  local twins = {}

  -- a clone leaves out a child that is not archivable
  for _, child in pool.engine.children(twin) do
    if child.Archivable then
      table.insert(twins, child)
    end
  end

  if #copies ~= #twins then
    return false
  end

  for i, child in copies do
    local other = twins[i]

    if child.ClassName ~= other.ClassName or child.Name ~= other.Name then
      return false
    end

    table.insert(set.members, child)
    table.insert(set.twins, other)
    table.insert(set.parents, copy)

    if not pair(set, child, other) then
      return false
    end
  end

  return true
end

local function claimed(inst: Instance)
  local module = registry.of(inst)

  return module ~= nil and registry.isCustom(module)
end

-- a twin's value, a reference into the template turned into its copy
local function authored(set: Set, twin: Instance, name: string)
  local value = (twin :: any)[name]

  if typeof(value) == "Instance" then
    return set.map[value] or value
  end

  return value
end

local function same(a: any, b: any)
  if a == b then
    return true
  end

  if typeof(a) ~= "CFrame" or typeof(b) ~= "CFrame" then
    return false
  end

  return (a.Position - b.Position).Magnitude <= NEAR
    and (a.XVector - b.XVector).Magnitude <= NEAR
    and (a.YVector - b.YVector).Magnitude <= NEAR
    and (a.ZVector - b.ZVector).Magnitude <= NEAR
end

local function restore(set: Set)
  for i, member in set.members do
    local twin = set.twins[i]

    for _, name in listOf(twin.ClassName) :: { string } do
      local value = authored(set, twin, name)

      local current = (member :: any)[name]

      if current ~= value and not same(current, value) then
        (member :: any)[name] = value
      end
    end
  end
end

local function hide(set: Set)
  for _, entry in set.hides do
    (set.members[entry.index] :: any)[entry.name] = entry.value
  end
end

local function unhide(set: Set)
  for _, entry in set.hides do
    (set.members[entry.index] :: any)[entry.name] = (set.twins[entry.index] :: any)[entry.name]
  end
end

local function trim(stack: Store)
  local cap = math.max(stack.floor, stack.peak, stack.previous)

  while #stack.free > cap do
    destroy(table.remove(stack.free) :: Instance)
  end

  if stack.key ~= nil and stack.used == 0 and #stack.free == 0 then
    stacks[stack.key] = nil
    return
  end

  local entry = stack :: Template

  if entry.template == nil or stack.used > 0 or #stack.free > 0 then
    return
  end

  for _, conn in entry.watch or {} do
    conn:Disconnect()
  end

  entry.watch = nil
  templates[entry.template] = nil
end

local finish: (inst: Instance, record: Taken) -> ()
local putBack: (set: Set) -> boolean

local function begin(holder: any, inst: Instance, stack: Store, set: Set?)
  stack.used += 1

  if stack.used > stack.peak then
    stack.peak = stack.used
  end

  local record: Taken = { holder = holder, store = stack, set = set, released = false }

  taken[inst] = record

  if inst:IsA("BasePart") then
    mover.assign(inst :: BasePart, holder)
  end

  holdIn(holder, function()
    finish(inst, record)
  end)

  return inst
end

-- stored under the key, a nested piece's authored twin, but dressed from the
-- source itself, so its references name the copy it was taken from
local function single(holder: any, key: Instance, source: Instance)
  if not canRestore(key) then
    return fresh(holder, source)
  end

  local stack = stackOf(key)

  if stack == nil then
    return fresh(holder, source)
  end

  local inst = table.remove(stack.free)

  if inst == nil then
    inst = copyOf(source)
  else
    storeOf[inst] = nil
    counts.reuses += 1
  end

  dress(inst, source)

  return begin(holder, inst, stack, nil)
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

  local set = record.set

  if set ~= nil then
    if not putBack(set) then
      discard(inst)
      return
    end
  else
    for _, child in pool.engine.children(inst) do
      if not rescue(child) then
        child:Destroy()
      end
    end
  end

  pool.engine.settle(inst, nil)
  strip(inst)

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

putBack = function(set: Set)
  if set.dirty or set.generation ~= set.key.generation then
    return false
  end

  for i, member in set.members do
    local parent = set.parents[i]

    if member.Parent ~= parent and not pcall(function()
      member.Parent = parent
    end) then
      return false
    end
  end

  if sendHome(set, set.root, true) ~= #set.members then
    return false
  end

  for i, member in set.members do
    pool.engine.settle(member, set.twins[i])
  end

  restore(set)
  hide(set)

  return true
end

-- a template that changed: its free sets go, and a set still in use is
-- destroyed on release, since its generation no longer matches
local function stale(entry: Template)
  local free = entry.free

  entry.generation += 1
  entry.keep = nil
  entry.free = {}

  for _, root in free do
    destroy(root)
  end

  for _, conn in entry.watch or {} do
    conn:Disconnect()
  end

  entry.watch = nil
end

local function refresh()
  seen = registry.version

  for _, entry in templates do
    stale(entry)
  end
end

local function watchOf(entry: Template)
  entry.watch = pool.engine.watch(entry.template, function()
    stale(entry)
  end)
end

-- a member of a kept copy answers its authored twin, so nested pieces share
-- the template's stores rather than one per copy
local function twinOf(source: Instance)
  local set = memberOf[source]

  if set ~= nil then
    return set.twins[indexOf[source]]
  end

  return source
end

local function build(root: Instance, key: Instance, entry: Template): Set?
  for _, child in key:GetChildren() do
    if child.Archivable then
      child:Clone().Parent = root
    end
  end

  local set: Set = {
    root = root,
    key = entry,
    generation = entry.generation,
    members = {},
    twins = {},
    parents = {},
    map = {},
    hides = {},
    conns = {},
    dirty = false,
  }

  if not pair(set, root, key) then
    return nil
  end

  for _, member in set.members do
    if not canRestore(member) or claimed(member) then
      return nil
    end
  end

  local function spoil()
    set.dirty = true
  end

  for i, member in set.members do
    set.map[set.twins[i]] = member
    memberOf[member] = set
    indexOf[member] = i

    for name, value in hideOf(member) or {} do
      table.insert(set.hides, { index = i, name = name, value = value })
    end

    -- an attribute written on a member, or a member destroyed, during the
    -- emit breaks its set
    table.insert(set.conns, pool.engine.listen(member, spoil))
    table.insert(set.conns, pool.engine.destroying(member, spoil))
  end

  -- each child is cloned alone, so a reference from one into another still
  -- names the template's
  restore(set)

  setOf[root] = set
  counts.builds += 1

  return set
end

local function kept(holder: any, key: Instance, source: Instance)
  -- a clone of a class the pool cannot restore carries its children already
  if not canRestore(key) then
    return fresh(holder, source)
  end

  local entry = templates[key]

  if entry == nil then
    entry = store(0) :: any
    entry.template = key
    entry.generation = 0
    templates[key] = entry
  end

  -- a whole clone, so references between its children name each other
  if entry.keep == false then
    return fresh(holder, source)
  end

  local root = table.remove(entry.free)

  -- a member destroyed or written while free spoils its set before any take
  while root ~= nil and setOf[root].dirty do
    discard(root)
    root = table.remove(entry.free)
  end

  if root ~= nil then
    local set = setOf[root]

    storeOf[root] = nil
    counts.reuses += 1

    dress(root, source)
    unhide(set)

    return begin(holder, root, entry, set)
  end

  local stack = stackOf(key)

  -- a mesh no key can name has no stack, and is copied whole as well
  if stack == nil then
    return fresh(holder, source)
  end

  root = table.remove(stack.free)

  if root ~= nil then
    storeOf[root] = nil
  else
    root = copyOf(key)
  end

  dress(root, source)

  local set = build(root, key, entry)

  -- its children were cloned one by one, so a reference between them still
  -- names the template's; a whole clone names its own
  if set == nil then
    entry.keep = false
    destroy(root)
    return fresh(holder, source)
  end

  entry.keep = true

  if entry.watch == nil then
    watchOf(entry)
  end

  return begin(holder, root, entry, set)
end

function pool.take(holder: any, source: Instance, alone: boolean?)
  if folder == nil then
    return fresh(holder, source)
  end

  if registry.version ~= seen then
    refresh()
  end

  local key = twinOf(source)

  if alone or #key:GetChildren() == 0 then
    return single(holder, key, source)
  end

  return kept(holder, key, source)
end

-- the once a second tick: each store keeps the larger of its floor and the
-- peak in use over the last two buckets
function pool.sweep(now: number)
  for _, map in { stacks, templates } :: { { [any]: Store } } do
    for _, stack in map do
      if now - stack.turned >= BUCKET then
        stack.previous = stack.peak
        stack.peak = stack.used
        stack.turned = now
      end

      trim(stack)
    end
  end
end

-- an edit made through the module's own api drops the sets of every template
-- it reaches at once, where a template's watch hears of it only a frame later
function pool.touch(inst: Instance)
  for _, entry in templates do
    local template = entry.template

    if template == inst or template:IsDescendantOf(inst) or inst:IsDescendantOf(template) then
      stale(entry)
    end
  end
end

function pool.kept(inst: Instance)
  return memberOf[inst] ~= nil
end

-- every free set's members against their twins, one line per difference
function pool.audit()
  local found = {}

  for _, entry in templates do
    for _, root in entry.free do
      local set = setOf[root]
      local hidden = {}

      for _, entry in set.hides do
        hidden[`{entry.index} {entry.name}`] = true
      end

      for i, member in set.members do
        local twin = set.twins[i]

        for _, name in listOf(twin.ClassName) :: { string } do
          if hidden[`{i} {name}`] or same((member :: any)[name], authored(set, twin, name)) then
            continue
          end

          table.insert(found, `{entry.template:GetFullName()} {member.Name}.{name}`)
        end
      end
    end
  end

  return found
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

    for _, map in
      { stacks, templates, taken, storeOf, setOf, memberOf, indexOf, known, loose, lists, restorable, hiddenBy } :: { any }
    do
      table.clear(map)
    end

    counts.builds, counts.reuses, counts.fresh, counts.made = 0, 0, 0, 0

    mover.clear()

    if made ~= nil then
      made:Destroy()
    end
  end)

  folder = pool.engine.folder(scope)
  seen = registry.version

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
