local mod = require("@mod/mod")
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

  -- a host calls the template and the unload from its own thread, so an
  -- engine function there would run with the host's rights
  for _, field in { "template", "unload" } do
    if type(author[field]) == "function" and debug.info(author[field], "s") == "[C]" then
      table.insert(found, `{field} must be a function of your own, not an engine function`)
    end
  end
end

-- a table of the author's, read raw into one the author never holds
local function copied(t: { [any]: any }): { [any]: any }
  local out = {}

  for k, v in next, t do
    out[k] = v
  end

  return out
end

-- a reason added once, however many tables gave it
local function once(found: { string }, reason: string)
  if not table.find(found, reason) then
    table.insert(found, reason)
  end
end

local function refuse(found: { string }, label: string)
  once(found, `{label} must be a plain table, with no metatable`)
end

-- how many tables deep a layout may nest: a group inside a group inside a
-- group, the deepest a built-in's needs being six
local LAYOUT_DEPTH = 8

-- a layout as plain tables the author never holds, nil once one carried a
-- metatable, sat deeper than LAYOUT_DEPTH or was met a second time. a table
-- met twice is refused rather than copied again, which a cycle would never
-- end and a table shared down each level would make cost twice per level
local function layoutOf(value: any, found: { string }, seen: { [any]: boolean }, depth: number): any
  if type(value) ~= "table" then
    return value
  end

  if seen[value] then
    once(found, "layout must not hold one table twice")
    return nil
  end

  seen[value] = true

  if getmetatable(value) ~= nil then
    once(found, "layout must be plain tables, with no metatable")
    return nil
  end

  if depth > LAYOUT_DEPTH then
    once(found, `layout must nest no deeper than {LAYOUT_DEPTH} tables`)
    return nil
  end

  local out = {}

  for k, v in next, value do
    out[k] = layoutOf(v, found, seen, depth + 1)
  end

  return out
end

-- the effect table, its display and its layout as tables the runtime owns,
-- read raw before params runs, so nothing the author's code does after can
-- change what was checked. a table carrying a metatable could answer one read
-- differently from the next, or iterate to more than was checked, so one is
-- refused by name
local function snapshot(author: any, found: { string }): any
  local out = copied(author)
  local display = out.display

  if type(display) == "table" and getmetatable(display) ~= nil then
    refuse(found, "display")
  elseif type(display) == "table" then
    display = copied(display)
    out.display = display

    if type(display.reflect) == "table" and getmetatable(display.reflect) ~= nil then
      refuse(found, "display.reflect")
    elseif type(display.reflect) == "table" then
      display.reflect = copied(display.reflect)
    end
  end

  out.layout = layoutOf(out.layout, found, {}, 1)

  return out
end

-- the fields of a knob, and what a reason calls each, that may hold a table
-- the reader or the registry walks or indexes once the effect is registered
local KEPT = {
  { "names", "aliases" },
  { "choices", "options" },
  { "classes", "classes" },
  { "modDefault", "default modifiers" },
}

-- a list of names, every entry a string the reader can look a value up by
local function named(list: any)
  if type(list) ~= "table" then
    return false
  end

  for _, entry in next, list do
    if type(entry) ~= "string" then
      return false
    end
  end

  return true
end

-- a knob's text fields, and what a reason calls each
local TEXTS = { { "title", "label" }, { "details", "hint" }, { "units", "unit" } }

-- what each option of a default modifier may hold, by the type of its value
local NUMBERS = { number = true, ["function"] = true }
local CURVES = { string = true, buffer = true, ["function"] = true }

-- every field the registry or a reason reads off a knob or its modifiers,
-- checked by type, so no reason ever turns an author's table to text. the
-- fields only sdk.knob sets must agree as it set them: a kind that names
-- its default's type, or neither when it has none
local function fieldsOf(row: any, name: string, found: { string })
  for _, field in TEXTS do
    local value = rawget(row, field[1])

    if value ~= nil and type(value) ~= "string" then
      once(found, `the {field[2]} of {name} must be a string`)
    end
  end

  local preset = rawget(row, "preset")

  if preset ~= nil and type(preset) ~= "string" then
    once(found, `the curve of {name} must be a preset's name`)
  end

  local default = rawget(row, "default")
  local kind = rawget(row, "kind")
  local has = rawget(row, "hasDefault")
  local agrees = if has == true
    then kind == knob.kindOf(default)
    else has == false and default == nil and (kind == nil or kind == "Instance")

  if
    not agrees
    or type(rawget(row, "order")) ~= "number"
    or type(rawget(row, "isMod")) ~= "boolean"
    or type(rawget(row, "isSlider")) ~= "boolean"
    or type(rawget(row, "isSeed")) ~= "boolean"
  then
    once(found, `{name} must keep the fields sdk.knob made it`)
  end
end

local function optionsOf(opts: any, name: string, found: { string })
  if type(opts) ~= "table" or getmetatable(opts) ~= nil then
    return
  end

  for _, option in { "duration", "delay" } do
    if opts[option] ~= nil and not NUMBERS[type(opts[option])] then
      once(found, `the {option} of a default modifier of {name} must be a number or a rule`)
    end
  end

  if opts.curve ~= nil and not CURVES[type(opts.curve)] then
    once(found, `the curve of a default modifier of {name} must be a preset's name, a curve param's value or a rule`)
  end

  if opts.lane ~= nil and type(opts.lane) ~= "string" then
    once(found, `the lane of a default modifier of {name} must be a string`)
  end
end

-- a slider drags a number between two numbers, its own range or the row's
-- bounds, which the panel cannot draw without
local function sliderOf(row: any, name: string, found: { string })
  local kind = rawget(row, "kind")

  if kind ~= nil and kind ~= "number" then
    once(found, `the slider of {name} needs a number param`)
    return
  end

  local low = rawget(row, "dragLower")
  local high = rawget(row, "dragUpper")

  if (low ~= nil and type(low) ~= "number") or (high ~= nil and type(high) ~= "number") then
    once(found, `the slider range of {name} must be numbers`)
    return
  end

  low = if low ~= nil then low else rawget(row, "lower")
  high = if high ~= nil then high else rawget(row, "upper")

  if type(low) ~= "number" or type(high) ~= "number" then
    once(found, `the slider of {name} needs a range: give it one, or a min and a max`)
  elseif low >= high then
    once(found, `the slider of {name} must run from a lower number to a higher one`)
  end
end

-- a seed is a number the panel draws with a reroll, so it is one row shape
-- and not a slider's or a curve's as well, and never animated: the one thing
-- anyone does with a seed is try another
local function seedOf(row: any, name: string, found: { string })
  local kind = rawget(row, "kind")

  if kind ~= nil and kind ~= "number" then
    once(found, `the seed of {name} needs a number param`)
    return
  end

  if rawget(row, "isSlider") == true then
    once(found, `the seed of {name} cannot also be a slider`)
  elseif rawget(row, "preset") ~= nil then
    once(found, `the seed of {name} cannot also be a curve`)
  elseif rawget(row, "isMod") == true then
    once(found, `the seed of {name} cannot also be animated`)
  end
end

-- an instance row is picked, never typed or animated, so it has no range, no
-- choices and no motion, and its classes are names IsA can be asked
local function instanceOf(row: any, name: string, found: { string })
  if rawget(row, "hasDefault") == true or rawget(row, "default") ~= nil or rawget(row, "rule") ~= nil then
    once(found, "an Instance row has no default")
  end

  local classes = rawget(row, "classes")

  if classes ~= nil then
    local ok = type(classes) == "table" and getmetatable(classes) == nil and #classes > 0
    local count = 0

    if ok then
      for key, class in next, classes do
        count += 1

        if type(key) ~= "number" or type(class) ~= "string" or class == "" then
          ok = false
          break
        end
      end
    end

    if not ok or count ~= #classes then
      once(found, `the classes of {name} must be a list of class names`)
    end
  end

  local given = {
    { rawget(row, "lower") ~= nil, "min" },
    { rawget(row, "upper") ~= nil, "max" },
    { rawget(row, "choices") ~= nil, "options" },
    { rawget(row, "preset") ~= nil, "curve" },
    { rawget(row, "isSlider") == true, "slider" },
    { rawget(row, "isMod") == true, "modifiers" },
    { rawget(row, "isSeed") == true, "seed" },
    { rawget(row, "units") ~= nil, "unit" },
  }

  for _, entry in given do
    if entry[1] then
      once(found, `an Instance row has no {entry[2]}`)
    end
  end
end

-- every table a row keeps copied into it, so the author's own lists reach
-- nothing. a row the registry froze on an earlier load already holds copies
local function rowOf(row: any, name: string, found: { string })
  local fresh = not table.isfrozen(row)

  fieldsOf(row, name, found)

  for _, field in KEPT do
    local key, label = field[1], field[2]
    local value = rawget(row, key)

    if type(value) ~= "table" then
      continue
    end

    if getmetatable(value) ~= nil then
      refuse(found, `the {label} of {name}`)
    elseif fresh then
      row[key] = copied(value)
    end
  end

  -- a bound is a number or a value of the row's own type, never a table,
  -- which the clamp would index on every read
  for _, field in { { "lower", "min" }, { "upper", "max" } } do
    if typeof(rawget(row, field[1])) == "table" then
      once(found, `the {field[2]} of {name} must be a number or a value of its type, not a table`)
    end
  end

  -- a recolor maps colors, so only a row holding one is declared to follow it or not
  local kind = rawget(row, "kind")

  if rawget(row, "recolors") ~= nil and kind ~= "Color3" and kind ~= "ColorSequence" then
    once(found, `the recolor of {name} needs a Color3 or ColorSequence param`)
  end

  if kind == "Instance" then
    instanceOf(row, name, found)
  else
    if rawget(row, "isSlider") == true then
      sliderOf(row, name, found)
    end

    if rawget(row, "isSeed") == true then
      seedOf(row, name, found)
    end
  end

  -- the registry walks each of these unasked, and would throw on one that is
  -- no table rather than name it. an entry is looked up by and joined into
  -- text, so one that is no string is refused too
  local choices = rawget(row, "choices")
  local specs = rawget(row, "modDefault")

  if not named(rawget(row, "names")) then
    once(found, `the aliases of {name} must be a list of names`)
  end

  if choices ~= nil and not named(choices) then
    once(found, `the options of {name} must be a list of names`)
  end

  if specs ~= nil and type(specs) ~= "table" then
    once(found, `the default modifiers of {name} must be a list of sdk.mod specs`)
  end

  if type(specs) ~= "table" or getmetatable(specs) ~= nil then
    return
  end

  for _, spec in next, specs do
    if not mod.is(spec) then
      continue
    end

    local endpoint = rawget(spec, "endpoint")
    local opts = rawget(spec, "opts")

    optionsOf(opts, name, found)

    if typeof(endpoint) == "table" then
      once(found, `the endpoint of a default modifier of {name} must be a value or a rule, not a table`)
    end

    -- options with a metatable, or frozen with a rule load would have to
    -- wrap, are checkFrozen's to name
    if
      type(opts) == "table"
      and getmetatable(opts) == nil
      and not table.isfrozen(opts)
      and not table.isfrozen(spec)
    then
      spec.opts = copied(opts)
    end
  end
end

-- the rows params answered as a map the runtime owns, by name
local function rowsOf(given: any, label: string, found: { string }): { [string]: any }
  if given == nil then
    return {}
  end

  if type(given) ~= "table" then
    table.insert(found, `{label} must be a table of knobs`)
    return {}
  end

  if getmetatable(given) ~= nil then
    refuse(found, label)
    return {}
  end

  local rows = {}
  local names = {}

  -- a name that is no string is never turned to text, which could run a
  -- metamethod of the author's in the middle of the load
  for name, row in next, given do
    if type(name) ~= "string" then
      once(found, `{label} names a row by a {typeof(name)}, not a string`)
      continue
    end

    rows[name] = row
    table.insert(names, name)
  end

  table.sort(names)

  for _, name in names do
    if knob.is(rows[name]) then
      rowOf(rows[name], name, found)
    end
  end

  return rows
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

  if getmetatable(params) ~= nil then
    table.insert(found, "params must answer a plain table, with no metatable")
    return {}, {}
  end

  for key in next, params do
    if key ~= "attributes" and key ~= "properties" then
      table.insert(
        found,
        `params answers {if type(key) == "string" then key else typeof(key)}, which is neither attributes nor properties`
      )
    end
  end

  return rowsOf(params.attributes, "params.attributes", found), rowsOf(params.properties, "params.properties", found)
end

-- every row whose default is of a type the panel cannot edit, named. a rule
-- row's type is what it resolves to, which nothing knows at load
local function checkKinds(rows: { [string]: any }, source: string, found: { string })
  local names = {}

  for name, row in rows do
    if type(name) == "string" and knob.is(row) and type(row.kind) == "string" then
      table.insert(names, name)
    end
  end

  table.sort(names)

  for _, name in names do
    local kind = rows[name].kind

    -- the reader takes an instance only from an attribute, read live
    if kind == "Instance" and source == "properties" then
      table.insert(
        found,
        `properties.{name} is an Instance row; an instance is held by an attribute row, declared under params.attributes`
      )
      continue
    end

    if kind == "Instance" or table.find(EDITABLE, kind) or (source == "properties" and kind == "EnumItem") then
      continue
    end

    local allowed = table.concat(EDITABLE, ", ")
    local extra = if source == "properties" then ", EnumItem" else ""

    table.insert(
      found,
      `{source}.{name} is of type {kind}, which the panel cannot edit; a param holds one of {allowed}{extra}, or a curve; an Instance row is declared with :instance()`
    )
  end
end

-- the preset a curve param whose default is a preset's name, or none, starts
-- as, which is what the curve editor shows and the reader hands on
local function presetOf(row: any): string?
  if row.preset == nil or row.isMod then
    return nil
  end

  local named = if row.hasDefault then row.default else row.preset

  return if type(named) == "string" and curves.PRESETS[named] ~= nil then named else nil
end

local function curveDefaults(rows: { [string]: any })
  for _, row in rows do
    if type(row) ~= "table" then
      continue
    end

    local named = presetOf(row)

    if named ~= nil then
      row.default = curves.PRESETS[named]
      row.hasDefault = true
      row.kind = "string"
    end
  end
end

-- a function the facade has not yet handed the view of its ctx
local function bare(value: any, facade: any)
  return type(value) == "function" and facade.rule(value) ~= value
end

local function holdsBare(t: any, facade: any)
  for _, value in next, t do
    if bare(value, facade) then
      return true
    end
  end

  return false
end

-- every frozen table load would have to change, named. a row the registry froze
-- on an earlier load, as a module keeps at module level, holds only rules that
-- load wrapped and passes; any other frozen one would reach the reader with the
-- runtime's ctx, so it is refused before any of it can run
local function checkFrozen(rows: { [string]: any }, facade: any, found: { string })
  local names = {}

  for name, row in rows do
    if type(row) == "table" then
      table.insert(names, name)
    end
  end

  table.sort(names, function(a: any, b: any)
    return tostring(a) < tostring(b)
  end)

  for _, name in names do
    local row = rows[name]

    if table.isfrozen(row) and (presetOf(row) ~= nil or holdsBare(row, facade)) then
      table.insert(found, `a knob must come fresh from sdk.knob; {name} is frozen`)
    end

    if type(row.modDefault) ~= "table" then
      continue
    end

    -- one that is no spec at all is the registry's to name
    for _, spec in row.modDefault do
      if not mod.is(spec) then
        continue
      end

      local opts = spec.opts

      if type(opts) ~= "table" or getmetatable(opts) ~= nil then
        table.insert(found, `a default modifier of {name} must keep the options sdk.mod made it`)
      elseif
        (table.isfrozen(spec) and bare(spec.endpoint, facade))
        or (table.isfrozen(opts) and holdsBare(opts, facade))
      then
        table.insert(found, `a default modifier must come fresh from sdk.mod; one of {name}'s is frozen`)
      end
    end
  end
end

-- every rule of the author's handed the view of its ctx rather than the ctx.
-- checkFrozen left no frozen table here with a rule still to wrap
local function viewed(rows: { [string]: any }, facade: any)
  for _, row in rows do
    if type(row) ~= "table" then
      continue
    end

    if not table.isfrozen(row) then
      for _, field in RULES do
        if type(row[field]) == "function" then
          row[field] = facade.rule(row[field])
        end
      end
    end

    if type(row.modDefault) ~= "table" then
      continue
    end

    for _, spec in row.modDefault do
      if not mod.is(spec) then
        continue
      end

      if not table.isfrozen(spec) and type(spec.endpoint) == "function" then
        spec.endpoint = facade.rule(spec.endpoint)
      end

      if table.isfrozen(spec.opts) then
        continue
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
-- or nil and every reason it was refused, and the unload it held when load
-- read it, which the caller calls in place of reading the author's table
-- again, refused or not. `path` names the module in a reason, `except` is the
-- version it replaces, whose id and classifier are free, and `alias` the name
-- its source runs under when that is not `path`, which its reported failures
-- name as `path` instead
function load.assemble(author: any, path: string, except: any?, alias: string?): (any?, { string }, (() -> ())?)
  if type(author) ~= "table" then
    return nil, { `{path} answers a {typeof(author)}, not an effect table` }
  end

  if getmetatable(author) ~= nil then
    return nil, { `{path} answers a table with a metatable, not a plain effect table` }
  end

  local found = {}

  author = snapshot(author, found)

  local unload = author.unload

  if type(unload) ~= "function" or debug.info(unload, "s") == "[C]" then
    unload = nil
  end

  if #found > 0 then
    return nil, found, unload
  end

  local label = if type(author.id) == "string" then author.id else path
  local version, refusal = versionOf(author, label)

  if version == nil then
    return nil, { refusal :: string }, unload
  end

  local facade = VERSIONS[version]

  checkFields(author, found)

  local attributes, properties = paramsOf(author, facade.sdk, found)

  checkKinds(attributes, "attributes", found)
  checkKinds(properties, "properties", found)
  checkFrozen(attributes, facade, found)
  checkFrozen(properties, facade, found)

  if #found > 0 then
    return nil, found, unload
  end

  curveDefaults(attributes)
  curveDefaults(properties)
  viewed(attributes, facade)
  viewed(properties, facade)

  local run = facade.run
  local emit = author.emit
  local duration = author.duration
  local template = author.template

  local layout = author.layout
  local reflect = author.display.reflect

  if type(reflect) == "table" then
    reflect = table.freeze(reflect)
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
    duration = if duration ~= nil then facade.duration(duration) else nil,
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
    return nil, found, unload
  end

  if alias ~= nil then
    facade.alias(module, alias, path)
  end

  return module, found, unload
end

return load
