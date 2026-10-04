local mod = require("@mod/mod")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local curves = require("@mod/curves")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local legacy_mods = require("@mod/legacy_mods")

local registry = {}

export type Module = reader.Module

-- an effect of nil is the old format's tween child, which drives what it
-- targets with no module behind it
export type Hit = { instance: Instance, effect: Module? }

type Owned = { [string]: { [string]: boolean } }

local modules: { Module } = {}
local byId: { [string]: Module } = {}

-- the order instances are classified in: every custom effect ahead of the
-- built-ins, since a custom effect's tag is its own and an instance carrying it
-- is that effect's even where a built-in's classifier matches too, as screen's
-- does any part a passive loop gave Enabled
local order: { Module } = {}
local custom: { [Module]: boolean } = {}

-- per module, computed once at register: the rows the effect drives itself. a
-- property row's old queues lived on the attribute side too, so the applier
-- must leave both alone
local owned: { [Module]: Owned } = {}

-- what a module's classifier says about where to run it from. sole is the class
-- of a classifier that is nothing but a class name, which an instance answers
-- on its own
local shape: { [Module]: { depth: number, subjects: { string }?, sole: string? } } = {}

-- the selector engine is the engine's; a test host hands one in
local function engineQuery(root: Instance, selector: string)
  return root:QueryDescendants(selector)
end

local query = engineQuery

function registry.configure(opts: { query: ((root: Instance, selector: string) -> { Instance })? })
  query = opts.query or engineQuery
end

function registry.clear()
  table.clear(modules)
  table.clear(order)
  table.clear(byId)
  table.clear(custom)
  table.clear(owned)
  table.clear(shape)
end

-- a classifier with its parenthesized parts blanked, so a relative selector
-- inside :has() or :not() never counts as a combinator of the whole
local function flatten(classifier: string)
  local out = {}
  local depth = 0

  for i = 1, #classifier do
    local c = string.sub(classifier, i, i)

    if c == "(" then
      depth += 1
    elseif c == ")" then
      depth = math.max(depth - 1, 0)
    elseif depth == 0 then
      table.insert(out, c)
    end
  end

  return table.concat(out)
end

local function compounds(alternative: string)
  local out = {}

  for token in string.gmatch(string.gsub(alternative, ">", " "), "%S+") do
    table.insert(out, token)
  end

  return out
end

-- each alternative of a classifier as its compounds, parenthesized parts
-- blanked, the subject last
function registry.alternatives(classifier: string): { { string } }
  local out = {}

  for alternative in string.gmatch(flatten(classifier), "[^,]+") do
    table.insert(out, compounds(alternative))
  end

  return out
end

function registry.depth(classifier: string)
  local deepest = 0

  for alternative in string.gmatch(flatten(classifier), "[^,]+") do
    deepest = math.max(deepest, #compounds(alternative) - 1)
  end

  return deepest
end

-- the class each alternative's subject starts with, or nil when one starts
-- with a name, a tag or a filter instead and any instance could be it
function registry.subjects(classifier: string): { string }?
  local out = {}

  for alternative in string.gmatch(flatten(classifier), "[^,]+") do
    local list = compounds(alternative)
    local subject = list[#list] or ""
    local class = string.match(subject, "^([%a_][%w_]*)")

    if class == nil then
      return nil
    end

    table.insert(out, class)
  end

  return out
end

-- a classifier that is one bare class token and nothing else: no tag, name,
-- attribute or combinator, so IsA alone decides it
local function soleClass(classifier: string, subjects: { string }?): string?
  if subjects == nil or #subjects ~= 1 then
    return nil
  end

  if subjects[1] ~= string.match(classifier, "^%s*(.-)%s*$") then
    return nil
  end

  return subjects[1]
end

-- every reason a module cannot be registered is gathered rather than raised at
-- the first, so an author fixing one sees them all at once
type Found = { string }

local function fail(found: Found, id: string, message: string)
  table.insert(found, `effect module {id}: {message}`)
end

local function checkRow(
  found: Found,
  id: string,
  source: string,
  name: string,
  row: any,
  taken: { [string]: string },
  events: { string }?
)
  if not knob.is(row) then
    fail(found, id, `{source} row {name} is not a knob`)
    return
  end

  if taken[name] then
    fail(found, id, `{name} is already the name or alias of {taken[name]}`)
  end

  taken[name] = name

  for _, alias in row.names do
    if taken[alias] then
      fail(found, id, `alias {alias} of {name} is already the name or alias of {taken[alias]}`)
    end

    taken[alias] = name
  end

  if row.hasDefault then
    if (row.lower ~= nil or row.upper ~= nil) and not knob.ordered(row.default) then
      fail(found, id, `{name} has a bound but its default cannot be ordered`)
    end

    local kind = mods.kindOf(row.default)

    if row.lower ~= nil and typeof(row.lower) ~= "number" and mods.kindOf(row.lower) ~= kind then
      fail(found, id, `the min of {name} is neither a number nor a {kind}`)
    end

    if row.upper ~= nil and typeof(row.upper) ~= "number" and mods.kindOf(row.upper) ~= kind then
      fail(found, id, `the max of {name} is neither a number nor a {kind}`)
    end

    if knob.clamp(row.default, row.lower, row.upper) ~= row.default then
      fail(found, id, `the default of {name} lies outside its own bounds`)
    end

    if row.choices ~= nil and (typeof(row.default) ~= "string" or not table.find(row.choices, row.default)) then
      fail(found, id, `{name} has options its default is not one of`)
    end
  end

  if row.units ~= nil and not knob.UNITS[row.units] then
    fail(found, id, `{name} has an unknown unit {row.units}`)
  end

  if row.preset ~= nil and curves.PRESETS[row.preset] == nil then
    fail(found, id, `{name} has an unknown curve preset {row.preset}`)
  end

  if row.modDefault ~= nil then
    for _, spec in row.modDefault do
      if not mod.is(spec) then
        fail(found, id, `a default modifier of {name} is not a mod spec`)
        continue
      end

      local lane = spec.opts.lane

      -- nothing can ever fire a lane the module does not declare, so a modifier
      -- behind one would sit on the row for the whole emit and never run
      if lane ~= nil and lane ~= "start" and lane ~= "end" then
        if events == nil or table.find(events, lane) == nil then
          fail(found, id, `a default modifier of {name} waits on {lane}, which this module never declares`)
        end
      end
    end
  end

  for _, field in { "hiddenRule", "readonlyRule", "rule" } do
    if row[field] ~= nil and type(row[field]) ~= "function" then
      fail(found, id, `{field} of {name} is not a function`)
    end
  end
end

local function checkLayout(found: Found, id: string, entries: { any }, rows: { [string]: boolean })
  for _, entry in entries do
    if type(entry) == "string" then
      if not rows[entry] then
        fail(found, id, `layout names no row {entry}`)
      end
    elseif type(entry) == "table" and entry.action ~= nil then
      if type(entry.action) ~= "string" or type(entry.label) ~= "string" then
        fail(found, id, "an action row needs a string action and label")
      end
    elseif type(entry) == "table" and entry.curve ~= nil then
      -- a compound entry draws a set of rows as one; the runtime reads nothing
      -- from it, so only the rows it points at are checked
      for _, key in { "curve", "duration" } do
        local named = entry[key]

        if named ~= nil and (type(named) ~= "string" or not rows[named]) then
          fail(found, id, `a compound row names no row {tostring(named)}`)
        end
      end
    elseif type(entry) == "table" and type(entry.entries) == "table" then
      if entry.hidden ~= nil and type(entry.hidden) ~= "function" then
        fail(found, id, `hidden on group {tostring(entry.title)} is not a function`)
      end

      checkLayout(found, id, entry.entries, rows)
    else
      fail(found, id, "a layout entry is a row name, an action row or a group")
    end
  end
end

-- freezing a frozen table errors, and a table here is frozen either because
-- this registry froze it on an earlier registration or because its author did.
-- every check still runs over it; only the freeze is skipped
local function freeze(t: any)
  if table.isfrozen(t) then
    return
  end

  table.freeze(t)
end

local function freezeLayout(entries: { any })
  for _, entry in entries do
    if type(entry) == "table" then
      if type(entry.entries) == "table" then
        freezeLayout(entry.entries)
      end

      freeze(entry)
    end
  end

  freeze(entries)
end

local function freezeRows(rows: { [string]: any })
  for _, row in rows do
    freeze(row.names)

    if row.choices then
      freeze(row.choices)
    end

    if row.modDefault then
      for _, spec in row.modDefault do
        freeze(spec.opts)
        freeze(spec)
      end

      freeze(row.modDefault)
    end

    freeze(row)
  end

  freeze(rows)
end

local function mark(out: { [string]: boolean }, name: string, row: any)
  out[name] = true

  for _, alias in row.names do
    out[alias] = true
  end
end

local function ownedOf(module: Module): Owned
  local out = { attribute = {}, property = {} }

  for name, row in module.attributes do
    if row.isMod then
      mark(out.attribute, name, row)
    end
  end

  for name, row in module.properties do
    if row.isMod then
      mark(out.property, name, row)
      mark(out.attribute, name, row)
    end
  end

  return out
end

local function checkEvents(found: Found, id: string, events: any)
  if type(events) ~= "table" then
    fail(found, id, "events must be a list of lane names")
    return
  end

  local named = {}

  for _, event in events do
    if type(event) ~= "string" or event == "" then
      fail(found, id, "an event needs a name")
      continue
    end

    if event == "start" or event == "end" then
      fail(found, id, `{event} is a built in lane rather than an event`)
    end

    if named[event] then
      fail(found, id, `event {event} is declared twice`)
    end

    named[event] = true
  end
end

local function checkRows(found: Found, id: string, module: Module, rows: { [string]: boolean })
  local taken = {}
  local events = if type(module.events) == "table" then module.events else nil

  for _, source in { "attributes", "properties" } do
    local list = (module :: any)[source]

    if list == nil then
      continue
    end

    if type(list) ~= "table" then
      fail(found, id, `{source} must be a table of knobs`)
      continue
    end

    for name, row in list do
      checkRow(found, id, string.sub(source, 1, -2), name, row, taken, events)
      rows[name] = true
    end
  end
end

-- every reason the module cannot be registered, none when it can. `except` is
-- a module the caller is about to take out, whose id is free to claim
function registry.problems(module: Module, except: Module?): { string }
  local found: Found = {}
  local id = module.id

  if type(id) ~= "string" or id == "" then
    table.insert(found, "an effect module needs a string id")
    id = "?"
  elseif byId[id] ~= nil and byId[id] ~= except then
    fail(found, id, "already registered")
  end

  if type(module.display) ~= "table" or type(module.display.name) ~= "string" then
    fail(found, id, "display needs a name")
  end

  if type(module.classifier) ~= "string" then
    fail(found, id, "classifier must be a selector string")
  end

  if module.components ~= nil and type(module.components) ~= "string" then
    fail(found, id, "components must be a selector string")
  end

  if type(module.emit) ~= "function" then
    fail(found, id, "emit must be a function")
  end

  if module.duration ~= nil and type(module.duration) ~= "function" then
    fail(found, id, "duration must be a rule")
  end

  if module.selected ~= nil and type(module.selected) ~= "function" then
    fail(found, id, "selected must be a function")
  end

  if module.constant ~= nil and type(module.constant) ~= "boolean" then
    fail(found, id, "constant must be a boolean")
  end

  if module.events ~= nil then
    checkEvents(found, id, module.events)
  end

  local rows = {}

  checkRows(found, id, module, rows)

  if module.layout ~= nil then
    if type(module.layout) == "table" then
      checkLayout(found, id, module.layout, rows)
    else
      fail(found, id, "layout must be a list of entries")
    end
  end

  return found
end

-- the classification order rebuilt from the display order, each custom effect
-- first and every built-in after it in the order it already had
local function reorder()
  table.clear(order)

  for _, module in modules do
    if custom[module] then
      table.insert(order, module)
    end
  end

  for _, module in modules do
    if not custom[module] then
      table.insert(order, module)
    end
  end
end

-- `isCustom` marks a custom effect's module, which is classified ahead of
-- every built-in
function registry.register(module: Module, isCustom: boolean?)
  local found = registry.problems(module)

  if #found > 0 then
    logger.error(table.concat(found, "\n"))
  end

  local id = module.id

  if module.attributes == nil then
    module.attributes = {}
  end

  if module.properties == nil then
    module.properties = {}
  end

  if module.layout ~= nil then
    freezeLayout(module.layout)
  end

  local subjects = registry.subjects(module.classifier)

  owned[module] = table.freeze(ownedOf(module))

  shape[module] = {
    depth = registry.depth(module.classifier),
    subjects = subjects,
    sole = soleClass(module.classifier, subjects),
  }

  freezeRows(module.attributes)
  freezeRows(module.properties)
  freeze(module.display)

  if module.events ~= nil then
    freeze(module.events)
  end

  freeze(module)

  byId[id] = module
  table.insert(modules, module)

  table.sort(modules, function(a, b)
    local ao = a.display.order or math.huge
    local bo = b.display.order or math.huge

    if ao ~= bo then
      return ao < bo
    end

    return a.id < b.id
  end)

  if isCustom then
    custom[module] = true
  end

  reorder()
end

-- the module taken out of every lookup, so its id and classifier are free
-- again. an emit already running it keeps running
function registry.unregister(module: Module)
  local index = table.find(modules, module)

  if index == nil then
    return
  end

  table.remove(modules, index)

  byId[module.id] = nil
  owned[module] = nil
  shape[module] = nil
  custom[module] = nil

  reorder()
end

-- whether the module was registered as a custom effect's, and still is
function registry.isCustom(module: Module): boolean
  return custom[module] == true
end

function registry.get(id: string): Module?
  return byId[id]
end

function registry.list()
  return table.clone(modules)
end

function registry.owned(module: Module): Owned
  return owned[module]
end

local function ancestorAt(inst: Instance, levels: number): Instance?
  local current: Instance? = inst

  for _ = 1, levels do
    if current == nil then
      return nil
    end

    current = current.Parent
  end

  return current
end

-- where a module's classifier runs from for a scan of root. the engine never
-- matches a classifier's leftmost compound against the instance queried, so a
-- root that is the compound's own instance has to be asked from above it; a
-- tree shallower than the classifier is asked from the highest ancestor it has
local function scanRoot(root: Instance, depth: number): Instance
  local above = ancestorAt(root, depth)

  if above ~= nil then
    return above
  end

  local current = root

  while current.Parent ~= nil do
    current = current.Parent
  end

  return current
end

-- one instance classified: a classifier that is only a class is answered by the
-- instance itself, at no walk and no query, and any other is run from the
-- ancestor high enough for every combinator in it to match below the root. the
-- first hit wins, a custom effect's ahead of a built-in's; built-ins are
-- disjoint by contract, so among them first is only ever one
function registry.of(inst: Instance): Module?
  for _, module in order do
    local sole = shape[module].sole

    if sole ~= nil then
      if inst:IsA(sole) then
        return module
      end

      continue
    end

    local subjects = shape[module].subjects
    local candidate = subjects == nil

    if subjects then
      for _, class in subjects do
        if inst:IsA(class) then
          candidate = true
        end
      end
    end

    if not candidate then
      continue
    end

    local root = ancestorAt(inst, shape[module].depth + 1)

    if root == nil then
      continue
    end

    if table.find(query(root, module.classifier), inst) then
      return module
    end
  end

  return nil
end

-- the module a legacy child's parent was classified as, which is the only one
-- that could already be reading the child: the parent is either a hit of this
-- scan or the root, whose own module the claimant is. walked rather than kept
-- in a map, because the parent an instance hands back is equal to the hit
-- rather than the same table
local function classifierOf(hits: { Hit }, parent: Instance): Module?
  for _, hit in hits do
    if hit.effect ~= nil and hit.instance == parent then
      return hit.effect
    end
  end

  return nil
end

-- whether a legacy child under a classified instance names a mod row that
-- instance's module already reads, which the reader folds into the row on the
-- clone. dispatching it as well would drive the template at the same time
local function readsChild(module: Module?, child: Instance): boolean
  if module == nil then
    return false
  end

  return owned[module][legacy_mods.childSource(child)][child.Name] == true
end

-- every descendant of root that some module classifies, plus every legacy
-- tween child no module reads, less the ones another hit or the root's own
-- module claims as components. a module whose components selector is the whole
-- subtree is answered by ancestry rather than by a query, since every instance
-- below it is claimed
function registry.scan(root: Instance, claimant: Module?): { Hit }
  if claimant ~= nil and claimant.components == "Instance" then
    return {}
  end

  local hits: { Hit } = {}
  local taken: { [Instance]: boolean } = {}

  -- the first module to reach an instance takes it, in the order `of` asks
  for _, module in order do
    for _, inst in query(scanRoot(root, shape[module].depth), module.classifier) do
      -- a query run from above the root reaches the root's siblings too, and
      -- none of them is this scan's
      if taken[inst] or not inst:IsDescendantOf(root) then
        continue
      end

      taken[inst] = true
      table.insert(hits, { instance = inst, effect = module })
    end
  end

  -- the old format's tween children, which drove their targets long before any
  -- effect had a module and still do: every RayValue no module classified, at
  -- one query for the scan. what the child carries is dispatch's business, so
  -- nothing here reads it
  for _, inst in query(root, "RayValue") do
    if taken[inst] then
      continue
    end

    local parent = inst.Parent
    local module = if parent == root then claimant else classifierOf(hits, parent :: Instance)

    if readsChild(module, inst) then
      continue
    end

    taken[inst] = true
    table.insert(hits, { instance = inst, effect = nil })
  end

  local component: { [Instance]: boolean } = {}

  if claimant ~= nil and claimant.components ~= nil then
    for _, inst in query(root, claimant.components) do
      component[inst] = true
    end
  end

  for _, hit in hits do
    local selector = if hit.effect ~= nil then hit.effect.components else nil

    if selector == nil then
      continue
    end

    if selector == "Instance" then
      for _, other in hits do
        if other ~= hit and other.instance:IsDescendantOf(hit.instance) then
          component[other.instance] = true
        end
      end

      continue
    end

    for _, inst in query(hit.instance, selector) do
      component[inst] = true
    end
  end

  local kept: { Hit } = {}

  for _, hit in hits do
    if not component[hit.instance] then
      table.insert(kept, hit)
    end
  end

  return kept
end

function registry.source(fn: ((inst: Instance) -> { [string]: any })?)
  reader.source = fn or reader.defaultSource
end

-- an instance's resolved attrs and props, through its module. a caller that
-- already has the module in hand passes it and skips classifying the
-- instance a second time; left nil, the module is found the usual way
function registry.read(inst: Instance, module: Module?): (any, any)
  module = if module ~= nil then module else registry.of(inst)

  if module == nil then
    return nil, nil
  end

  return reader.resolve(module, { ref = inst, obj = inst, effect = module })
end

return registry
