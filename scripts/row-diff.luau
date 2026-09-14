local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local harness = require("@tests/harness")
local registry = require("@mod/registry")

local MODULES = {
  "beam",
  "mesh",
  "spin",
  "sound",
  "trail",
  "bezier",
  "screen",
  "particle",
  "lightning",
  "shockwave",
  "camera_shake",
  "shockwave_ring",
  "shockwave_line",
  "shockwave_debris",
}

-- the plugin's effect keys against the modules' ids
local IDS = {
  model_spin = "model_spin",
  particle = "particle",
  camera_shake = "camera_shake",
  shockwave = "shockwave",
  shockwave_ring = "shockwave_ring",
  shockwave_line = "shockwave_line",
  shockwave_debris = "shockwave_debris",
  screen = "screen",
  sound = "sound",
  beam = "beam",
  mesh = "mesh",
  bezier = "bezier",
  lightning = "lightning",
}

-- lune hands the separator on with the rest of the arguments
local dir = if process.args[1] == "--" then process.args[2] else process.args[1]

if dir == nil then
  error("pass the plugin's schema directory")
end

registry.clear()
registry.configure({ query = harness.query })

for _, name in MODULES do
  registry.register(require(`@vfx/{name}`))
end

local env = setmetatable({
  vector = vector,
  math = math,
  NumberRange = harness.datatypes.NumberRange,
  ColorSequence = harness.datatypes.ColorSequence,
  Color3 = harness.datatypes.Color3,
  Vector2 = harness.datatypes.Vector2,
  Vector3 = harness.datatypes.Vector3,
}, { __index = _G })

local function loadSchema(file: string)
  local chunk = luau.load(fs.readFile(file), { environment = env })

  return chunk()
end

local function same(a: any, b: any)
  if typeof(a) ~= typeof(b) then
    return false
  end

  if typeof(a) == "table" then
    if #a ~= #b then
      return false
    end

    for i, v in a do
      if not same(v, b[i]) then
        return false
      end
    end

    return true
  end

  return a == b
end

local function show(v: any)
  if typeof(v) == "table" then
    local parts = {}

    for _, x in v do
      table.insert(parts, show(x))
    end

    return `\{{table.concat(parts, ", ")}}`
  end

  return tostring(v)
end

-- a module's rows by every name they answer to
local function rowsOf(module: any)
  local byName = {}

  for _, rows in { module.attributes, module.properties } do
    for name, row in rows do
      byName[name] = { name = name, row = row }

      for _, alias in row.names do
        byName[alias] = { name = name, row = row }
      end
    end
  end

  return byName
end

local function walk(entries: { any }, path: { string }, visit: (row: any, path: { string }) -> ())
  for _, entry in entries do
    if entry.name ~= nil then
      visit(entry, path)
    elseif entry.entries ~= nil then
      local inner = table.clone(path)
      table.insert(inner, entry.title)
      walk(entry.entries, inner, visit)
    end
  end
end

local total = 0

local function report(effect: string, line: string)
  total += 1
  print(`{effect}: {line}`)
end

-- every plugin schema against the module it names: a plugin row no module row
-- answers to (by name or alias), a default that differs, an option list that
-- differs, a label or short hint that differs, and a module row the plugin
-- never showed. run from the package root:
-- lune run scripts/row-diff -- /path/to/plugin/src/ui/attributes/schema
for key, id in IDS do
  local schema = loadSchema(`{dir}/{key}.luau`)
  local module = registry.get(id)

  if module == nil then
    report(key, `no module {id}`)
    continue
  end

  local byName = rowsOf(module)
  local shown = {}

  walk(schema.entries, {}, function(entry, path)
    local found = byName[entry.name]

    if found == nil then
      report(key, `plugin row {entry.name} answers to no module row`)
      return
    end

    shown[found.name] = true

    local row = found.row

    if found.name ~= entry.name then
      report(key, `plugin row {entry.name} is module row {found.name}`)
    end

    if entry.default ~= nil and row.hasDefault and not same(entry.default, row.default) then
      report(key, `{found.name} defaults to {show(row.default)} where the plugin showed {show(entry.default)}`)
    end

    if entry.options ~= nil and not same(entry.options, row.choices) then
      report(key, `{found.name} options {show(row.choices)} where the plugin showed {show(entry.options)}`)
    end

    if entry.display_name ~= row.title then
      report(key, `{found.name} label {show(row.title)} where the plugin showed {show(entry.display_name)}`)
    end

    if entry.details ~= nil and entry.details.short ~= row.details then
      report(key, `{found.name} hint {show(row.details)} where the plugin showed {show(entry.details.short)}`)
    end

    if entry.min ~= nil and typeof(entry.min) == "number" and row.lower ~= entry.min then
      report(key, `{found.name} min {show(row.lower)} where the plugin showed {show(entry.min)}`)
    end
  end)

  for _, rows in { module.attributes, module.properties } do
    for name, row in rows do
      if not shown[name] and row.hiddenRule == nil then
        report(key, `module row {name} the plugin never showed`)
      end
    end
  end
end

print(`{total} differences`)
