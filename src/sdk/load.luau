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
}

-- the classes nothing narrower than the whole class can be told apart from
local BROAD = { Instance = true, PVInstance = true }

local load = {}

load.SUPPORTED = #VERSIONS

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

  if type(display) == "table" then
    for key in display do
      if key ~= "name" and key ~= "icon" then
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

  for _, field in { "params", "duration", "unload" } do
    if author[field] ~= nil and type(author[field]) ~= "function" then
      table.insert(found, `{field} must be a function`)
    end
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

-- a compound naming nothing but a class claims every instance of it
local function whole(alternative: { string }): string?
  local subject = alternative[#alternative] or ""

  if #alternative ~= 1 or string.find(subject, "[%.#%[]") then
    return nil
  end

  return string.match(subject, "^([%a_][%w_]*)")
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

        local claimed = whole(theirs)

        if claimed ~= nil and claimed == class then
          return `classifier {classifier} overlaps {module.id}, which plays every {claimed}`
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

  if #found > 0 then
    return nil, found
  end

  curveDefaults(attributes)
  curveDefaults(properties)

  local sdk = facade.sdk
  local run = facade.run
  local emit = author.emit
  local duration = author.duration

  local module = {
    id = author.id,
    display = { name = author.display.name, icon = author.display.icon },
    classifier = author.classifier,
    components = author.components,
    layout = copy(author.layout),
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
