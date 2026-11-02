local mod = require("@mod/mod")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local curves = require("@mod/curves")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local legacy_mods = require("@mod/legacy_mods")

local registry = {}

-- moves whenever the set of modules changes, so a cache keyed on what claims
-- an instance knows to drop it
registry.version = 0

export type Module = reader.Module

-- an effect of nil is the old format's tween child, which drives what it
-- targets with no module behind it
export type Hit = { instance: Instance, effect: Module? }

type Owned = { [string]: { [string]: boolean } }

-- the engine properties a custom effect mirrors: true for every one, or the
-- set it names
export type Reflected = true | { [string]: boolean }

local modules: { Module } = {}
local byId: { [string]: Module } = {}

-- the order instances are classified in: every custom effect ahead of the
-- built-ins, since a custom effect's tag is its own and an instance carrying it
-- is that effect's even where a built-in's classifier matches too, as screen's
-- does any part a passive loop gave Enabled
local order: { Module } = {}
local custom: { [Module]: boolean } = {}

-- the custom modules the runtime ships itself, which a host lists beside the
-- built-ins rather than under the place's own effects
local bundled: { [Module]: boolean } = {}

-- per module, computed once at register: the rows the effect drives itself. a
-- property row's old queues lived on the attribute side too, so the applier
-- must leave both alone
local owned: { [Module]: Owned } = {}

-- per custom module, computed once at register: the properties whose panel
-- queues the applier still plays for it, its own property rows and whatever
-- display.reflect names, nil when it mirrors none
local reflected: { [Module]: Reflected } = {}

-- a compound of a class, a name and tags and nothing else, which an instance
-- answers on its own; nil for one carrying a filter or a nested selector
type Plain = { class: string?, name: string?, tags: { string } }

-- one alternative of a classifier: its compounds left to right, each parsed
-- when plain, and whether every combinator between them is the child one
type Chain = { compounds: { string }, plain: { Plain? }, direct: boolean }

-- what a module's classifier says about where to run it from. sole is the class
-- of a classifier that is nothing but a class name, which an instance answers
-- on its own
type Shape = {
  depth: number,
  subjects: { string }?,
  sole: string?,
  chains: { Chain },
  -- every chain past a bare class leads with compounds this module can match
  -- by hand, so a scan never has to ask the engine from above its root
  byHand: boolean,
  -- every chain is made of such compounds through its subject too, so an
  -- instance is classified by walking its ancestry rather than by a query
  whole: boolean,
}

local shape: { [Module]: Shape } = {}

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
  table.clear(reflected)
  table.clear(shape)

  registry.version += 1
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

local function plainOf(compound: string): Plain?
  local rest = compound
  local class = string.match(rest, "^[%a_][%w_]*")
  local out: Plain = { class = class, name = nil, tags = {} }

  if class ~= nil then
    rest = string.sub(rest, #class + 1)
  end

  while #rest > 0 do
    local mark, word = string.match(rest, "^([.#])([%w_]+)")

    if mark == nil then
      return nil
    end

    if mark == "#" then
      if out.name ~= nil then
        return nil
      end

      out.name = word
    else
      table.insert(out.tags, word)
    end

    rest = string.sub(rest, #word + 2)
  end

  return out
end

-- the alternatives of a classifier, split at the commas and child combinators
-- that sit outside any parenthesis or bracket, each compound kept as the
-- engine spells it so a part of a chain can be asked of the engine again
local function chainsOf(classifier: string): { Chain }
  local out: { Chain } = {}
  local parts: { string } = {}
  local direct = true
  local current = {}
  local depth = 0

  local function closeCompound()
    local text = string.match(table.concat(current), "^%s*(.-)%s*$")

    if text ~= "" then
      table.insert(parts, text)
    end

    table.clear(current)
  end

  local function closeChain()
    closeCompound()

    if #parts > 0 then
      local plain = table.create(#parts)

      for i, compound in parts do
        plain[i] = plainOf(compound)
      end

      table.insert(out, { compounds = parts, plain = plain, direct = direct })
    end

    parts = {}
    direct = true
  end

  local i = 1

  while i <= #classifier do
    local c = string.sub(classifier, i, i)

    if c == "(" or c == "[" then
      depth += 1
    elseif c == ")" or c == "]" then
      depth = math.max(depth - 1, 0)
    end

    if depth == 0 and c == "," then
      closeChain()
    elseif depth == 0 and c == ">" then
      closeCompound()

      local after = string.match(classifier, "^%s*>", i + 1)

      if after ~= nil then
        direct = false
        i += #after
      end
    else
      table.insert(current, c)
    end

    i += 1
  end

  closeChain()

  return out
end

local function matchPlain(inst: Instance, plain: Plain): boolean
  if plain.class ~= nil and not inst:IsA(plain.class) then
    return false
  end

  if plain.name ~= nil and inst.Name ~= plain.name then
    return false
  end

  for _, tag in plain.tags do
    if not inst:HasTag(tag) then
      return false
    end
  end

  return true
end

-- whether the chain's compounds from `first` to `last` match `inst` and its
-- ancestors in turn, the compound at `last` against the instance itself
local function matchUp(inst: Instance?, chain: Chain, first: number, last: number): boolean
  local current = inst

  for i = last, first, -1 do
    local plain = chain.plain[i]

    if current == nil or plain == nil or not matchPlain(current, plain) then
      return false
    end

    current = current.Parent
  end

  return true
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

  for _, rows in { module.attributes, table.unpack(module.companions or {}) } do
    for name, row in rows do
      if row.isMod then
        mark(out.attribute, name, row)
      end
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

local function reflectedOf(module: Module): Reflected?
  local reflect = (module.display :: any).reflect

  if reflect == "all" then
    return true
  end

  local out = {}

  for name in module.properties or {} do
    out[name] = true
  end

  for _, name in if type(reflect) == "table" then reflect else {} do
    out[name] = true
  end

  return if next(out) ~= nil then table.freeze(out) else nil
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
-- every built-in, and `isBundled` one the runtime ships itself
function registry.register(module: Module, isCustom: boolean?, isBundled: boolean?)
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

  local chains = chainsOf(module.classifier)
  local byHand = true
  local whole = true

  for _, chain in chains do
    local last = #chain.compounds

    if not chain.direct then
      byHand = false
      whole = false
    end

    -- indexed, since a compound that is not plain leaves a hole the generic
    -- walk would step over
    for i = 1, last do
      if chain.plain[i] == nil then
        whole = false

        if i < last then
          byHand = false
        end
      end
    end
  end

  shape[module] = {
    depth = registry.depth(module.classifier),
    subjects = subjects,
    sole = soleClass(module.classifier, subjects),
    chains = chains,
    byHand = byHand,
    whole = whole,
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
    bundled[module] = isBundled == true
    reflected[module] = reflectedOf(module)
  end

  reorder()

  registry.version += 1
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
  bundled[module] = nil
  reflected[module] = nil

  reorder()

  registry.version += 1
end

-- whether the module was registered as a custom effect's, and still is
function registry.isCustom(module: Module): boolean
  return custom[module] == true
end

-- whether the module is a custom effect the runtime ships itself
function registry.isBundled(module: Module): boolean
  return bundled[module] == true
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

-- the engine properties a custom effect mirrors, nil for a built-in or a
-- custom effect that mirrors none
function registry.reflected(module: Module): Reflected?
  return reflected[module]
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

-- the place itself, or one of its services: never an effect, and never a root
-- to query from, since a query from the place walks every service in it
local function placeLevel(inst: Instance): boolean
  local parent = inst.Parent

  return inst:IsA("DataModel") or (parent ~= nil and parent:IsA("DataModel"))
end

-- an ancestor up to `levels` above inst, stopping at a service or at the top
local function climb(inst: Instance, levels: number): Instance
  local current = inst

  for _ = 1, levels do
    local parent = current.Parent

    if parent == nil or parent:IsA("DataModel") then
      break
    end

    current = parent
  end

  return current
end

-- where a module's classifier runs from for a scan of root. the engine never
-- matches a classifier's leftmost compound against the instance queried, so a
-- root that is the compound's own instance has to be asked from above it; a
-- tree shallower than the classifier is asked from the highest ancestor it has
-- below the place
local function scanRoot(root: Instance, depth: number): Instance
  return climb(root, depth)
end

-- a subject compound asked of the instance itself: true or false when it names
-- nothing but a class, tags and a name, nil when it filters on more than that
local function bare(inst: Instance, compound: string): boolean?
  local class, rest = string.match(compound, "^([%a_][%w_]*)(.*)$")

  if class == nil then
    return nil
  end

  local matched = inst:IsA(class)

  while rest ~= "" do
    local kind, word, after = string.match(rest, "^([%.#])([%w_]+)(.*)$")

    if kind == nil then
      return nil
    end

    if kind == "." then
      matched = matched and inst:HasTag(word)
    else
      matched = matched and inst.Name == word
    end

    rest = after
  end

  return matched
end

-- the value a filter spells, as the engine reads one: a boolean, a number or
-- a string, quoted or bare
local function literal(text: string): any
  if text == "true" then
    return true
  end

  if text == "false" then
    return false
  end

  local number = tonumber(text)

  if number ~= nil then
    return number
  end

  return string.match(text, '^"(.*)"$') or string.match(text, "^'(.*)'$") or text
end

-- whether an instance could be a compound's subject, from what the compound
-- asks of the instance itself: its class, tags, name and attributes, read up
-- to the first filter that asks more (a property, :has, :not). false only on
-- a filter the instance fails for sure; an attribute the engine might read
-- another way than this does passes
local function couldBe(inst: Instance, compound: string): boolean
  local class, rest = string.match(compound, "^([%a_][%w_]*)(.*)$")

  if class ~= nil and not inst:IsA(class) then
    return false
  end

  rest = rest or compound

  while rest ~= "" do
    local kind, word, after = string.match(rest, "^([%.#])([%w_]+)(.*)$")

    if kind == "." then
      if not inst:HasTag(word) then
        return false
      end

      rest = after
      continue
    end

    if kind == "#" then
      if inst.Name ~= word then
        return false
      end

      rest = after
      continue
    end

    local name, value, afterValue = string.match(rest, "^%[%s*%$([%w_]+)%s*=%s*(.-)%s*%](.*)$")

    if name ~= nil then
      local held = inst:GetAttribute(name)

      local spelled = string.match(value, '^"(.*)"$') or string.match(value, "^'(.*)'$") or value

      if held == nil or (held ~= literal(value) and tostring(held) ~= spelled) then
        return false
      end

      rest = afterValue
      continue
    end

    local set, afterSet = string.match(rest, "^%[%s*%$([%w_]+)%s*%](.*)$")

    if set == nil then
      return true
    end

    if inst:GetAttribute(set) == nil then
      return false
    end

    rest = afterSet
  end

  return true
end

-- a custom classifier asked of an instance with no ancestor to query it from:
-- "claims" when a lone subject compound matches it outright, "holds" when the
-- instance carries a subject's class and every tag but the classifier cannot be
-- decided here, so no built-in may take it either
local function unrooted(inst: Instance, classifier: string): string?
  local held = false

  for _, alternative in registry.alternatives(classifier) do
    local subject = alternative[#alternative] or ""
    local matched = if #alternative == 1 then bare(inst, subject) else nil

    if matched == true then
      return "claims"
    end

    if matched == false then
      continue
    end

    local class = string.match(subject, "^([%a_][%w_]*)")
    local carried = class ~= nil and inst:IsA(class)

    for tag in string.gmatch(subject, "%.([%w_]+)") do
      carried = carried and inst:HasTag(tag)
    end

    held = held or carried
  end

  return if held then "holds" else nil
end

-- one instance classified: a classifier that is only a class is answered by the
-- instance itself, at no walk and no query, and any other is run from the
-- ancestor high enough for every combinator in it to match below the root. the
-- first hit wins, a custom effect's ahead of a built-in's; built-ins are
-- disjoint by contract, so among them first is only ever one. an instance a
-- custom classifier holds but cannot decide is nobody's
function registry.of(inst: Instance): Module?
  if placeLevel(inst) then
    return nil
  end

  local held = false

  for _, module in order do
    if held and not custom[module] then
      return nil
    end

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

    local shaped = shape[module]

    -- a chain of plain compounds is walked up the instance's ancestry, at no
    -- query. one the instance has too few ancestors to walk is left to the
    -- query path below, which knows what an unrooted instance is to a custom
    -- effect
    if shaped.whole then
      local decided = true

      for _, chain in shaped.chains do
        local last = #chain.compounds

        if ancestorAt(inst, last - 1) == nil then
          decided = false
        elseif matchUp(inst, chain, 1, last) then
          return module
        end
      end

      if decided then
        continue
      end
    end

    -- asked from the service rather than the place above it, the furthest a
    -- query climbs
    local root = ancestorAt(inst, shaped.depth + 1)

    if root ~= nil and root:IsA("DataModel") then
      root = climb(inst, shaped.depth + 1)
    end

    if root == nil then
      local answer = if custom[module] then unrooted(inst, module.classifier) else nil

      if answer == "claims" then
        return module
      end

      held = held or answer == "holds"

      continue
    end

    -- the subject's own filters are asked of the instance before the query:
    -- one it fails matches below no root, and the query that would say so
    -- walks everything the root holds, a rig's animation saves or the whole
    -- place from above a rig
    local possible = false

    for _, chain in shaped.chains do
      if couldBe(inst, chain.compounds[#chain.compounds]) then
        possible = true
        break
      end
    end

    if possible and table.find(query(root, module.classifier), inst) then
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

  local source = legacy_mods.childSource(child)

  if source == nil then
    return false
  end

  return owned[module][source][child.Name] == true
end

-- whether anything under root is of `class`, asked of the engine the first
-- time a scan needs it and kept in that scan's own answers alone
local function occurs(root: Instance, answers: { [string]: boolean }, class: string): boolean
  local known = answers[class]

  if known ~= nil then
    return known
  end

  local found = root:FindFirstChildWhichIsA(class, true) ~= nil

  answers[class] = found

  return found
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

  local function take(inst: Instance, module: Module)
    if taken[inst] then
      return
    end

    taken[inst] = true
    table.insert(hits, { instance = inst, effect = module })
  end

  -- a module classifies only instances of its subjects' classes, so one whose
  -- classes nothing under the root is can match nothing there and is not asked
  local answers: { [string]: boolean } = {}

  -- the first module to reach an instance takes it, in the order `of` asks
  for _, module in order do
    local subjects = shape[module].subjects

    if subjects ~= nil then
      local present = false

      for _, class in subjects do
        if occurs(root, answers, class) then
          present = true
          break
        end
      end

      if not present then
        continue
      end
    end

    local held = shape[module]

    -- a chain the engine cannot be shown from the root is asked from above it,
    -- where the query reaches the root's siblings too, and none of them is
    -- this scan's
    if not held.byHand then
      for _, inst in query(scanRoot(root, held.depth), module.classifier) do
        if inst:IsDescendantOf(root) then
          take(inst, module)
        end
      end

      continue
    end

    for _, inst in query(root, module.classifier) do
      take(inst, module)
    end

    -- a chain whose upper compounds are the root and its ancestors: the engine
    -- never matches a chain's leftmost compound against the instance it is
    -- asked from, so those compounds are matched here and the engine is shown
    -- what is left of the chain, from the root. a subject it answers is a hit
    -- only where the chain's compound at the root really is the root
    for _, chain in held.chains do
      local last = #chain.compounds

      for at = 1, last - 1 do
        if not matchUp(root, chain, 1, at) then
          continue
        end

        local below = table.concat(chain.compounds, " > ", at + 1, last)

        for _, inst in query(root, below) do
          if ancestorAt(inst, last - at) == root then
            take(inst, module)
          end
        end
      end
    end
  end

  -- the old format's tween children, which drove their targets long before any
  -- effect had a module and still do: every RayValue no module classified, at
  -- one query for the scan. what the child carries is dispatch's business, so
  -- nothing here reads it
  local children: { Instance } = {}

  if occurs(root, answers, "RayValue") then
    children = query(root, "RayValue")
  end

  for _, inst in children do
    if taken[inst] then
      continue
    end

    local parent = inst.Parent
    local module = if parent == root then claimant else classifierOf(hits, parent :: Instance)

    -- under a custom effect's instance, a legacy child its rows do not read
    -- is the old format's leftover, which nothing plays
    if readsChild(module, inst) or (module ~= nil and custom[module]) then
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

  -- a hit that claims its whole subtree claims every hit below it, told by
  -- walking each hit's ancestry up to the root rather than by asking every hit
  -- about every other. the claimants are bucketed by name and compared by
  -- equality, because an ancestor an instance hands back is equal to a hit
  -- rather than the same table under the test host
  local whole: { [string]: { Instance } } = {}
  local claims = false

  for _, hit in hits do
    if hit.effect ~= nil and hit.effect.components == "Instance" then
      local name = hit.instance.Name
      local bucket = whole[name]

      if bucket == nil then
        bucket = {}
        whole[name] = bucket
      end

      table.insert(bucket, hit.instance)
      claims = true
    end
  end

  if claims then
    for _, hit in hits do
      local current = hit.instance.Parent

      while current ~= nil and current ~= root do
        local bucket = whole[current.Name]

        if bucket ~= nil and table.find(bucket, current) ~= nil then
          component[hit.instance] = true
          break
        end

        current = current.Parent
      end
    end
  end

  for _, hit in hits do
    local selector = if hit.effect ~= nil then hit.effect.components else nil

    if selector == nil or selector == "Instance" then
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
