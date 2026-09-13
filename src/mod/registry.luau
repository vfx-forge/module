local mod = require("@mod/mod")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local curves = require("@mod/curves")
local logger = require("@mod/logger")
local reader = require("@mod/reader")

local registry = {}

export type Module = reader.Module

export type Hit = { instance: Instance, effect: Module }

type Owned = { [string]: { [string]: boolean } }

local modules: { Module } = {}
local byId: { [string]: Module } = {}

-- per module, computed once at register: the rows the effect drives itself,
-- and what its classifier says about where to run it from
local owned: { [Module]: Owned } = {}
local shape: { [Module]: { depth: number, subjects: { string }? } } = {}

-- the selector engine is the engine's; a test host hands one in
local function engineQuery(root: Instance, selector: string): { Instance }
  return root:QueryDescendants(selector)
end

local query = engineQuery

function registry.configure(opts: { query: ((root: Instance, selector: string) -> { Instance })? })
  query = opts.query or engineQuery
end

function registry.clear()
  table.clear(modules)
  table.clear(byId)
  table.clear(owned)
  table.clear(shape)
end

-- a classifier with its parenthesised parts blanked, so a relative selector
-- inside :has() or :not() never counts as a combinator of the whole
local function flatten(classifier: string): string
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

local function compounds(alternative: string): { string }
  local out = {}

  for token in string.gmatch(string.gsub(alternative, ">", " "), "%S+") do
    table.insert(out, token)
  end

  return out
end

function registry.depth(classifier: string): number
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

local function fail(id: string, message: string)
  logger.error(`effect module {id}: {message}`)
end

local function checkRow(id: string, source: string, name: string, row: any, taken: { [string]: string })
  if not knob.is(row) then
    fail(id, `{source} row {name} is not a knob`)
  end

  if taken[name] then
    fail(id, `{name} is already the name or alias of {taken[name]}`)
  end

  taken[name] = name

  for _, alias in row.names do
    if taken[alias] then
      fail(id, `alias {alias} of {name} is already the name or alias of {taken[alias]}`)
    end

    taken[alias] = name
  end

  if row.hasDefault then
    if (row.lower ~= nil or row.upper ~= nil) and not knob.ordered(row.default) then
      fail(id, `{name} has a bound but its default cannot be ordered`)
    end

    local kind = mods.kindOf(row.default)

    if row.lower ~= nil and typeof(row.lower) ~= "number" and mods.kindOf(row.lower) ~= kind then
      fail(id, `the min of {name} is neither a number nor a {kind}`)
    end

    if row.upper ~= nil and typeof(row.upper) ~= "number" and mods.kindOf(row.upper) ~= kind then
      fail(id, `the max of {name} is neither a number nor a {kind}`)
    end

    if knob.clamp(row.default, row.lower, row.upper) ~= row.default then
      fail(id, `the default of {name} lies outside its own bounds`)
    end

    if row.choices ~= nil and (typeof(row.default) ~= "string" or not table.find(row.choices, row.default)) then
      fail(id, `{name} has options its default is not one of`)
    end
  end

  if row.units ~= nil and not knob.UNITS[row.units] then
    fail(id, `{name} has an unknown unit {row.units}`)
  end

  if row.preset ~= nil and curves.PRESETS[row.preset] == nil then
    fail(id, `{name} has an unknown curve preset {row.preset}`)
  end

  if row.modDefault ~= nil and not mod.is(row.modDefault) then
    fail(id, `the default modifier of {name} is not a mod spec`)
  end

  for _, field in { "hiddenRule", "readonlyRule", "rule" } do
    if row[field] ~= nil and type(row[field]) ~= "function" then
      fail(id, `{field} of {name} is not a function`)
    end
  end
end

local function checkLayout(id: string, entries: { any }, rows: { [string]: boolean })
  for _, entry in entries do
    if type(entry) == "string" then
      if not rows[entry] then
        fail(id, `layout names no row {entry}`)
      end
    elseif type(entry) == "table" and entry.action ~= nil then
      if type(entry.action) ~= "string" or type(entry.label) ~= "string" then
        fail(id, "an action row needs a string action and label")
      end
    elseif type(entry) == "table" and type(entry.entries) == "table" then
      if entry.hidden ~= nil and type(entry.hidden) ~= "function" then
        fail(id, `hidden on group {tostring(entry.title)} is not a function`)
      end

      checkLayout(id, entry.entries, rows)
    else
      fail(id, "a layout entry is a row name, an action row or a group")
    end
  end
end

local function freezeRows(rows: { [string]: any })
  for _, row in rows do
    table.freeze(row.names)

    if row.choices then
      table.freeze(row.choices)
    end

    if row.modDefault then
      table.freeze(row.modDefault.opts)
      table.freeze(row.modDefault)
    end

    table.freeze(row)
  end

  table.freeze(rows)
end

local function ownedOf(module: Module): Owned
  local out = { attribute = {}, property = {} }

  for name, row in module.attributes do
    if row.isMod then
      out.attribute[name] = true
    end
  end

  for name, row in module.properties do
    if row.isMod then
      out.property[name] = true
    end
  end

  return out
end

function registry.register(module: Module)
  local id = module.id

  if type(id) ~= "string" or id == "" then
    logger.error("an effect module needs a string id")
  end

  if byId[id] then
    fail(id, "already registered")
  end

  if type(module.display) ~= "table" or type(module.display.name) ~= "string" then
    fail(id, "display needs a name")
  end

  if type(module.classifier) ~= "string" then
    fail(id, "classifier must be a selector string")
  end

  if module.components ~= nil and type(module.components) ~= "string" then
    fail(id, "components must be a selector string")
  end

  if type(module.emit) ~= "function" then
    fail(id, "emit must be a function")
  end

  if module.duration ~= nil and type(module.duration) ~= "function" then
    fail(id, "duration must be a rule")
  end

  if module.selected ~= nil and type(module.selected) ~= "function" then
    fail(id, "selected must be a function")
  end

  if module.attributes == nil then
    module.attributes = {}
  end

  if module.properties == nil then
    module.properties = {}
  end

  local taken = {}
  local rows = {}

  for name, row in module.attributes do
    checkRow(id, "attribute", name, row, taken)
    rows[name] = true
  end

  for name, row in module.properties do
    checkRow(id, "property", name, row, taken)
    rows[name] = true
  end

  if module.layout ~= nil then
    checkLayout(id, module.layout, rows)
  end

  owned[module] = table.freeze(ownedOf(module))
  shape[module] = { depth = registry.depth(module.classifier), subjects = registry.subjects(module.classifier) }

  freezeRows(module.attributes)
  freezeRows(module.properties)
  table.freeze(module.display)
  table.freeze(module)

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
end

function registry.get(id: string): Module?
  return byId[id]
end

function registry.list(): { Module }
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

-- one instance classified: each module whose subject class it is gets its
-- classifier run from the ancestor high enough for every combinator in it to
-- match below the root, and the first hit wins. modules are disjoint by
-- contract, so first is only ever one
function registry.of(inst: Instance): Module?
  for _, module in modules do
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

-- an instance handed back by two separate query calls is not guaranteed to be
-- the same table reference even where it names the same instance, so
-- membership here goes through table.find rather than a hash keyed by Instance
function registry.scan(root: Instance): { Hit }
  local hits: { Hit } = {}
  local seen: { Instance } = {}

  for _, module in modules do
    for _, inst in query(root, module.classifier) do
      if table.find(seen, inst) then
        continue
      end

      table.insert(seen, inst)
      table.insert(hits, { instance = inst, effect = module })
    end
  end

  local components: { Instance } = {}

  for _, hit in hits do
    if hit.effect.components == nil then
      continue
    end

    for _, inst in query(hit.instance, hit.effect.components) do
      table.insert(components, inst)
    end
  end

  local kept: { Hit } = {}

  for _, hit in hits do
    if not table.find(components, hit.instance) then
      table.insert(kept, hit)
    end
  end

  return kept
end

function registry.source(fn: ((inst: Instance) -> { [string]: any })?)
  reader.source = fn or reader.defaultSource
end

function registry.read(inst: Instance): (any, any)
  local module = registry.of(inst)

  if module == nil then
    return nil, nil
  end

  return reader.resolve(module, { ref = inst, obj = inst, scale = 1, effect = module })
end

return registry
