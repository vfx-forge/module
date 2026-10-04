local knob = require("@mod/knob")
local curves = require("@mod/curves")
local registry = require("@mod/registry")

local v1 = require("@root/sdk/v1/facade")

-- each released facade by the sdk_version that asks for it
local VERSIONS = { v1 }

local FIELDS = {
  "sdk_version",
  "id",
  "display",
  "classifier",
  "components",
  "layout",
  "constant",
  "params",
  "duration",
  "emit",
  "unload",
  "template",
}

-- the built-ins an effect may be grouped with, in the order a reason names them
local CATEGORIES = { "emitters", "meshes", "paths", "shockwaves", "camera", "motion" }

-- the classes nothing narrower than the whole class can be told apart from
local BROAD = { Instance = true, PVInstance = true }

-- a knob's fields and a default modifier's options that may hold a rule
local RULES = { "rule", "hiddenRule", "readonlyRule" }
local OPTIONS = { "duration", "curve", "delay" }

-- the value types the plugin's panel has an editor for, a curve being a
-- string; a property row may also hold an enum item
local EDITABLE = {
  "number",
  "boolean",
  "string",
  "NumberRange",
  "Vector2",
  "Vector3",
  "UDim",
  "UDim2",
  "Color3",
  "NumberSequence",
  "ColorSequence",
}

local load = {}

load.SUPPORTED = #VERSIONS
load.VERSIONS = table.freeze(table.clone(VERSIONS))
load.CATEGORIES = table.freeze(table.clone(CATEGORIES))

-- how many single letter edits apart two names are
local function distance(a: string, b: string)
  local previous = table.create(#b + 1)

  for j = 0, #b do
    previous[j + 1] = j
  end

  for i = 1, #a do
    local current = { i }

    for j = 1, #b do
      local cost = if string.byte(a, i) == string.byte(b, j) then 0 else 1

      current[j + 1] = math.min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost)
    end

    previous = current
  end

  return previous[#b + 1]
end

local function unknown(key: any)
  if type(key) ~= "string" then
    return `a field named by a {typeof(key)}`
  end

  for _, field in FIELDS do
    if distance(key, field) <= 2 then
      return `unknown field {key}, did you mean {field}`
    end
  end

  return `unknown field {key}`
end

local function versionOf(author: any, label: string): (number?, string?)
  local v = author.sdk_version

  if v == nil then
    return nil, "it declares no sdk_version"
  end

  if type(v) ~= "number" or v ~= v // 1 or v < 1 then
    return nil, `sdk_version must be a whole number from 1, got {tostring(v)}`
  end

  if v > load.SUPPORTED then
    return nil,
      `{label} needs sdk {v}, this VFX Forge supports up to {load.SUPPORTED}, update the plugin or the emit module`
  end

  return v, nil
end

-- "all", or a list of one or more names
local function reflectable(reflect: any)
  if reflect == "all" then
    return true
  end

  if type(reflect) ~= "table" or #reflect == 0 then
    return false
  end

  local count = 0

  for _, name in reflect do
    count += 1

    if type(name) ~= "string" or name == "" then
      return false
    end
  end

  return count == #reflect
end

local function checkFields(author: any, found: { string })
  local known = {}

  for _, field in FIELDS do
    known[field] = true
  end

  for key in author do
    if not known[key] then
      table.insert(found, unknown(key))
    end
  end

  if type(author.id) ~= "string" or not string.match(author.id, "^%a[%w_]*$") then
    table.insert(found, "id must be a name of letters, digits and underscores")
  end

  local display = author.display

  if type(display) ~= "table" or type(display.name) ~= "string" or display.name == "" then
    table.insert(found, "display needs a name")
  elseif display.icon ~= nil and type(display.icon) ~= "string" then
    table.insert(found, "display.icon must be a string")
  end

  if type(display) == "table" and display.category ~= nil and not table.find(CATEGORIES, display.category) then
    table.insert(found, `display.category must be one of {table.concat(CATEGORIES, ", ")}`)
  end

  if type(display) == "table" and display.reflect ~= nil and not reflectable(display.reflect) then
    table.insert(found, 'display.reflect must be "all" or a list of property names')
  end

  if type(display) == "table" then
    for key in display do
      if key ~= "name" and key ~= "icon" and key ~= "category" and key ~= "reflect" then
        table.insert(found, `unknown display field {tostring(key)}`)
      end
    end
  end

  if type(author.classifier) ~= "string" then
    table.insert(found, "classifier must be a selector string")
  end

  if author.components ~= nil and type(author.components) ~= "string" then
    table.insert(found, "components must be a selector string")
  end

  if author.layout ~= nil and type(author.layout) ~= "table" then
    table.insert(found, "layout must be a list of entries")
  end

  if author.constant ~= nil and type(author.constant) ~= "boolean" then
    table.insert(found, "constant must be a boolean")
  end

  if type(author.emit) ~= "function" then
    table.insert(found, "emit must be a function")
  end

  for _, field in { "params", "duration", "unload", "template" } do
    if author[field] ~= nil and type(author[field]) ~= "function" then
      table.insert(found, `{field} must be a function`)
    end
  end

  -- a host calls the template from its own thread, so an engine function
  -- there would run with the host's rights
  if type(author.template) == "function" and debug.info(author.template, "s") == "[C]" then
    table.insert(found, "template must be a function of your own, not an engine function")
  end
end

-- the attributes and properties params answered, each empty when it could
-- not be used and every reason added to `found`
local function paramsOf(author: any, sdk: any, found: { string }): ({ [string]: any }, { [string]: any })
  if author.params == nil then
    return {}, {}
  end

  local ok, params = pcall(author.params, sdk)

  if not ok then
    table.insert(found, `params failed: {tostring(params)}`)
    return {}, {}
  end

  if type(params) ~= "table" then
    table.insert(found, `params must answer a table, got {typeof(params)}`)
    return {}, {}
  end

  for key in params do
    if key ~= "attributes" and key ~= "properties" then
      table.insert(found, `params answers {tostring(key)}, which is neither attributes nor properties`)
    end
  end

  local attributes = params.attributes or {}
  local properties = params.properties or {}

  for name, list in { attributes = attributes, properties = properties } do
    if type(list) ~= "table" then
      table.insert(found, `params.{name} must be a table of knobs`)
    end
  end

  return if type(attributes) == "table" then attributes else {}, if type(properties) == "table" then properties else {}
end

-- every row whose default is of a type the panel cannot edit, named. a rule
-- row's type is what it resolves to, which nothing knows at load
local function checkKinds(rows: { [string]: any }, source: string, found: { string })
  local names = {}

  for name, row in rows do
    if type(name) == "string" and knob.is(row) and row.kind ~= nil then
      table.insert(names, name)
    end
  end

  table.sort(names)

  for _, name in names do
    local kind = rows[name].kind

    if table.find(EDITABLE, kind) or (source == "properties" and kind == "EnumItem") then
      continue
    end

    local allowed = table.concat(EDITABLE, ", ")
    local extra = if source == "properties" then ", EnumItem" else ""

    table.insert(
      found,
      `{source}.{name} is of type {kind}, which the panel cannot edit; a param holds one of {allowed}{extra}, or a curve`
    )
  end
end

-- a curve param whose default is a preset's name, or none, starts as that
-- preset's curve, which is what the curve editor shows and the reader hands on
local function curveDefaults(rows: { [string]: any })
  for _, row in rows do
    if type(row) ~= "table" or row.preset == nil or row.isMod then
      continue
    end

    local named = if row.hasDefault then row.default else row.preset

    if type(named) == "string" and curves.PRESETS[named] ~= nil then
      row.default = curves.PRESETS[named]
      row.hasDefault = true
      row.kind = "string"
    end
  end
end

-- every rule of the author's handed the view of its ctx rather than the ctx.
-- a row the registry already froze was handed it by the load that froze it
local function viewed(rows: { [string]: any }, facade: any)
  for _, row in rows do
    if type(row) ~= "table" or table.isfrozen(row) then
      continue
    end

    for _, field in RULES do
      if type(row[field]) == "function" then
        row[field] = facade.rule(row[field])
      end
    end

    if type(row.modDefault) ~= "table" then
      continue
    end

    for _, spec in row.modDefault do
      if type(spec) ~= "table" or type(spec.opts) ~= "table" then
        continue
      end

      if type(spec.endpoint) == "function" then
        spec.endpoint = facade.rule(spec.endpoint)
      end

      for _, option in OPTIONS do
        if type(spec.opts[option]) == "function" then
          spec.opts[option] = facade.rule(spec.opts[option])
        end
      end
    end
  end
end

-- a layout group's hidden rule handed the view of its ctx, in the copy only
local function viewedLayout(entries: any, facade: any)
  if type(entries) ~= "table" then
    return
  end

  for _, entry in entries do
    if type(entry) ~= "table" then
      continue
    end

    if type(entry.hidden) == "function" then
      entry.hidden = facade.rule(entry.hidden)
    end

    viewedLayout(entry.entries, facade)
  end
end

local function copy(value: any): any
  if type(value) ~= "table" then
    return value
  end

  local out = {}

  for k, v in value do
    out[k] = copy(v)
  end

  return out
end

local function tagsOf(compound: string): { string }
  local out = {}

  for tag in string.gmatch(compound, "%.([%w_]+)") do
    table.insert(out, tag)
  end

  return out
end

-- why the classifier could match an instance another effect plays, or nil
function load.overlap(classifier: string, except: any?): string?
  local others = {}

  for _, module in registry.list() do
    if module ~= except then
      table.insert(others, module)
    end
  end

  for _, alternative in registry.alternatives(classifier) do
    local subject = alternative[#alternative] or ""
    local class = string.match(subject, "^([%a_][%w_]*)")
    local tags = tagsOf(subject)

    if class == nil or #tags == 0 then
      return `classifier {classifier} must name a class and a tag of its own, as in Attachment.MyEffect`
    end

    if BROAD[class] then
      return `classifier {classifier}: {class} is too broad a class for a custom effect, name a concrete class such as BasePart`
    end

    for _, module in others do
      for _, theirs in registry.alternatives(module.classifier) do
        for _, tag in tagsOf(theirs[#theirs] or "") do
          if table.find(tags, tag) then
            return `classifier {classifier} shares the tag {tag} with {module.id}`
          end
        end
      end
    end
  end

  return nil
end

-- the effect module the runtime registers for what a tagged module returned,
-- or nil and every reason it was refused. `path` names the module in a reason,
-- `except` is the version it replaces, whose id and classifier are free, and
-- `alias` the name its source runs under when that is not `path`, which its
-- reported failures name as `path` instead
function load.assemble(author: any, path: string, except: any?, alias: string?): (any?, { string })
  if type(author) ~= "table" then
    return nil, { `{path} answers a {typeof(author)}, not an effect table` }
  end

  local label = if type(author.id) == "string" then author.id else path
  local version, refusal = versionOf(author, label)

  if version == nil then
    return nil, { refusal :: string }
  end

  local facade = VERSIONS[version]
  local found = {}

  checkFields(author, found)

  local attributes, properties = paramsOf(author, facade.sdk, found)

  checkKinds(attributes, "attributes", found)
  checkKinds(properties, "properties", found)

  if #found > 0 then
    return nil, found
  end

  curveDefaults(attributes)
  curveDefaults(properties)
  viewed(attributes, facade)
  viewed(properties, facade)

  local sdk = facade.sdk
  local run = facade.run
  local emit = author.emit
  local duration = author.duration
  local template = author.template

  local layout = copy(author.layout)
  local reflect = author.display.reflect

  if type(reflect) == "table" then
    reflect = table.freeze(table.clone(reflect))
  end

  viewedLayout(layout, facade)

  local module = {
    id = author.id,
    display = {
      name = author.display.name,
      icon = author.display.icon,
      category = author.display.category,
      reflect = reflect,
    },
    classifier = author.classifier,
    components = author.components,
    layout = layout,
    constant = author.constant,
    attributes = attributes,
    properties = properties,
    duration = if duration ~= nil
      then function(_, attrs: any, props: any)
        return duration(sdk, attrs, props)
      end
      else nil,
    emit = function(ctx: any, attrs: any, props: any)
      run(emit, ctx, attrs, props)
    end,
    template = if template ~= nil then facade.template(template, alias, path) else nil,
  }

  -- the id is the caller's to weigh, since only it knows who holds one
  local prefix = `effect module {author.id}: `

  for _, problem in registry.problems(module :: any, registry.get(author.id)) do
    table.insert(found, if string.sub(problem, 1, #prefix) == prefix then string.sub(problem, #prefix + 1) else problem)
  end

  local overlap = load.overlap(author.classifier, except)

  if overlap ~= nil then
    table.insert(found, overlap)
  end

  if #found > 0 then
    return nil, found
  end

  if alias ~= nil then
    facade.alias(module, alias, path)
  end

  return module, found
end

return load
