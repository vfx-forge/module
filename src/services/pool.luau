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

-- what a free copy is hidden by, and so what a take puts back from its twin; a
-- free part must not collide, be queried, be touched or be selected either
local HIDES = {
  part = { LocalTransparencyModifier = 1, CanCollide = false, CanQuery = false, CanTouch = false, Locked = true },
  face = { Transparency = 1 },
  gui = { Visible = false },
  sound = { Playing = false },
  enabled = { Enabled = false },
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

  -- every walk of a copy or its template, so a test host can answer the
  -- wrappers it holds
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

local function hideOf(inst: Instance): { [string]: any }?
  if inst:IsA("BasePart") then
    return HIDES.part
  end

  if inst:IsA("FaceInstance") then
    return HIDES.face
  end

  if inst:IsA("GuiObject") then
    return HIDES.gui
  end

  if inst:IsA("Sound") then
    return HIDES.sound
  end

  for _, class in { "Beam", "Light", "Trail", "Highlight", "SurfaceGui", "BillboardGui", "ParticleEmitter" } do
    if inst:IsA(class) then
      return HIDES.enabled
    end
  end

  return nil
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

-- a set that cannot be filed, destroyed without what other holders still use
local function discard(root: Instance)
  local set = setOf[root]

  if set ~= nil then
    sendHome(set, root, false)
  end

  destroy(root)
end

-- the copy walked against its template in step, children in order; false
-- when the two part ways
local function pair(set: Set, copy: Instance, twin: Instance): boolean
  local copies = pool.engine.children(copy)
  local twins = pool.engine.children(twin)

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

local function claimed(inst: Instance): boolean
  local module = registry.of(inst)

  return module ~= nil and registry.isCustom(module)
end

-- a twin's value, a reference into the template turned into its copy
local function authored(set: Set, twin: Instance, name: string): any
  local value = (twin :: any)[name]

  if typeof(value) == "Instance" then
    return set.map[value] or value
  end

  return value
end

local function restore(set: Set)
  for i, member in set.members do
    local twin = set.twins[i]

    for _, name in listOf(twin.ClassName) :: { string } do
      local value = authored(set, twin, name)

      if (member :: any)[name] ~= value then
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

  table.insert(s.free, inst)
  storeOf[inst] = s

  trim(s)
end

putBack = function(set: Set): boolean
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
local function stale(t: Template)
  local free = t.free

  t.generation += 1
  t.keep = nil
  t.free = {}

  for _, root in free do
    destroy(root)
  end

  for _, conn in t.watch or {} do
    conn:Disconnect()
  end

  t.watch = nil
end

local function refresh()
  seen = registry.version

  for _, t in templates do
    stale(t)
  end
end

local function watchOf(t: Template)
  t.watch = pool.engine.watch(t.template, function()
    stale(t)
  end)
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

local function build(root: Instance, key: Instance, t: Template): Set?
  for _, child in key:GetChildren() do
    local copy = utility.clone(child)

    if copy == nil then
      return nil
    end

    copy.Parent = root
  end

  local set: Set = {
    root = root,
    key = t,
    generation = t.generation,
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

  setOf[root] = set
  counts.builds += 1

  return set
end

local function kept(holder: any, key: Instance): Instance
  -- a clone of a class the pool cannot restore carries its children already
  if not canRestore(key) then
    return fresh(holder, key)
  end

  local t = templates[key]

  if t == nil then
    t = store(0) :: any
    t.template = key
    t.generation = 0
    templates[key] = t
  end

  if t.keep == false then
    local inst = single(holder, key)

    for _, child in key:GetChildren() do
      local copy = utility.clone(child)

      if copy ~= nil then
        copy.Parent = inst
      end
    end

    return inst
  end

  local root = table.remove(t.free)

  -- a member destroyed or written while free spoils its set before any take
  while root ~= nil and setOf[root].dirty do
    discard(root)
    root = table.remove(t.free)
  end

  if root ~= nil then
    local set = setOf[root]

    storeOf[root] = nil
    counts.reuses += 1

    dress(root, key)
    unhide(set)

    return begin(holder, root, t, set)
  end

  local s = stacks[key.ClassName]

  if s == nil then
    s = store(FLOOR)
    stacks[key.ClassName] = s
  end

  root = table.remove(s.free)

  if root ~= nil then
    storeOf[root] = nil
  else
    root = pool.engine.fromExisting(key)
    counts.made += 1
    strip(root)
    track(root)
  end

  dress(root, key)

  local set = build(root, key, t)

  -- the clones stay under the root and are cleared on release, as for any
  -- template that cannot be kept
  if set == nil then
    t.keep = false
    return begin(holder, root, s, nil)
  end

  t.keep = true

  if t.watch == nil then
    watchOf(t)
  end

  return begin(holder, root, t, set)
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

-- every free set's members against their twins, one line per difference
function pool.audit(): { string }
  local found = {}

  for _, t in templates do
    for _, root in t.free do
      local set = setOf[root]
      local hidden = {}

      for _, entry in set.hides do
        hidden[`{entry.index} {entry.name}`] = true
      end

      for i, member in set.members do
        local twin = set.twins[i]

        for _, name in listOf(twin.ClassName) :: { string } do
          if hidden[`{i} {name}`] or (member :: any)[name] == authored(set, twin, name) then
            continue
          end

          table.insert(found, `{t.template:GetFullName()} {member.Name}.{name}`)
        end
      end
    end
  end

  return found
end

function pool.stats()
  return table.clone(counts)
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

    for _, map in { stacks, templates, taken, storeOf, setOf, memberOf, indexOf, known, lists, restorable } :: { any } do
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
