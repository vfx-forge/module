local attr = require("@mod/attributes")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local logger = require("@mod/logger")
local utility = require("@mod/utility")
local registry = require("@mod/registry")
local value_curve = require("@mod/value_curve")
local numeric_common = require("@mod/common/numeric")

local retime = {}

-- how a unit scales when time runs `factor` times faster: a span shrinks, a
-- rate grows, an acceleration grows by the square, a length is untouched. a
-- gravity mass is a length cubed per second squared, so its orbits keep their
-- shape and play faster
function retime.factorOf(unit: string, factor: number): number?
  if unit == "seconds" then
    return 1 / factor
  end

  if unit == "perSecond" or unit == "studsPerSecond" then
    return factor
  end

  if unit == "perSecondSquared" or unit == "studsPerSecondSquared" or unit == "studsCubedPerSecondSquared" then
    return factor * factor
  end

  return nil
end

-- an emitter's time rows, the 2D one's too, whose lengths are offset pixels
const EMITTER = {
  Speed = "studsPerSecond",
  RotSpeed = "perSecond",
  Lifetime = "seconds",
  Acceleration = "studsPerSecondSquared",
  Drag = "perSecond",
  Rate = "perSecond",
}

-- engine properties no effect reads, which time still scales
retime.PROPERTY_UNITS = {
  ParticleEmitter = EMITTER,
  ParticleEmitter2D = EMITTER,
  Trail = { Lifetime = "seconds" },
}

-- a property the instance does not have throws on the read, which is the
-- answer "nothing to scale"
local function scaleProperty(obj: any, name: string, f: number)
  local ok, v = pcall(function()
    return obj[name]
  end)

  if not ok then
    return
  end

  if typeof(v) == "number" or typeof(v) == "Vector3" or typeof(v) == "Vector2" then
    obj[name] = v * f
  elseif typeof(v) == "NumberRange" then
    obj[name] = NumberRange.new(v.Min * f, v.Max * f)
  elseif typeof(v) == "NumberSequence" then
    obj[name] = utility.scaleNumberSequence(v, f)
  end
end

-- the fields a NumberSequence tween end keeps the curve it was drawn as in
-- (the plugin's sequence_ends)
const DRAWN_ENDS = { "start_curve", "finish_curve" }

-- a lane endpoint scaled as scaleProperty scales the value it stands for
const function scaleEndpoint(v: any, f: number): any
  const kind = typeof(v)

  if kind == "number" or kind == "Vector3" or kind == "Vector2" or kind == "vector" then
    return v * f
  end

  if kind == "NumberRange" then
    return NumberRange.new(v.Min * f, v.Max * f)
  end

  if kind == "NumberSequence" then
    return utility.scaleNumberSequence(v, f)
  end

  return v
end

-- a row's lanes, every endpoint scaled as the row's value is. a NumberSequence
-- tween end carries the curve it was drawn as beside it, which the plugin edits
-- the end as only while the end is still its bake, so that curve scales too
function retime.scaleLanes(obj: Instance, source: string, key: string, f: number)
  utility.rescaleQueue(obj, source, key, function(lanes)
    mods.scaleValues(lanes, f, scaleEndpoint)

    for _, queue in lanes do
      for _, m in queue do
        for _, field in DRAWN_ENDS do
          const drawn = if type(m[field]) == "string" then value_curve.decode(m[field]) else nil

          if drawn ~= nil then
            m[field] = value_curve.encode(value_curve.multiply(drawn, f))
          end
        end
      end
    end
  end)
end

-- the unit an engine property is measured in on `target`: its effect's
-- property row's, else what `units` (a tool's PROPERTY_UNITS) names for its
-- class. a custom effect's instance is its own, so only its rows say
const function unitOf(target: Instance, name: string, units: { [string]: { [string]: string } }): string?
  const module = registry.of(target)
  const row = if module ~= nil then module.properties[name] else nil

  if row ~= nil then
    return row.units
  end

  if module ~= nil and registry.isCustom(module) then
    return nil
  end

  for class, names in units do
    if target:IsA(class) and names[name] ~= nil then
      return names[name]
    end
  end

  return nil
end

-- the instance an animator drives: its Target, else its parent past Folders,
-- the way the animator finds it
const function animatedOf(animator: Instance): Instance?
  const handle = animator:GetAttribute("Target")

  if typeof(handle) == "InstanceHandle" then
    const named = (handle :: any):Get()

    if named ~= nil and named:IsDescendantOf(game) then
      return named
    end
  end

  return utility.getTarget(animator)
end

-- a Property Animator holds its property's lanes on itself rather than on the
-- instance the property belongs to, so they scale with the animator, by the
-- unit the property has there. `factorOf` is the tool's, `units` its table of
-- engine properties
function retime.scaleAnimator(
  animator: Instance,
  factor: number,
  units: { [string]: { [string]: string } },
  factorOf: (unit: string, factor: number) -> number?
)
  const name = animator:GetAttribute("Property")
  const target = animatedOf(animator)

  if type(name) ~= "string" or name == "" or target == nil then
    return
  end

  const unit = unitOf(target, name, units)
  const f = if unit ~= nil then factorOf(unit, factor) else nil

  if f ~= nil then
    retime.scaleLanes(animator, "property", name, f)
  end
end

local QUAD = { "_Start", "_End", "_Min", "_Max" }
local RANGE = { "Min", "Max" }

-- every name a module's rows answer to, so a legacy key one row claims is
-- never scaled twice by another row's rule
local function claimedOf(module: registry.Module): { [string]: boolean }
  local out = {}

  for _, rows in { module.properties, module.attributes, table.unpack(module.companions or {}) } do
    for name, row in rows do
      out[name] = true

      for _, alias in row.names do
        out[alias] = true
      end
    end
  end

  return out
end

-- whether any spelling of a row, an old quad endpoint or drawn range of one
-- included, is stored on the instance
const function stored(obj: Instance, keys: { string }): boolean
  for _, key in keys do
    if attr.get(obj, key, nil) ~= nil then
      return true
    end

    for _, suffix in QUAD do
      if attr.get(obj, key .. suffix, nil) ~= nil then
        return true
      end
    end

    for _, prefix in RANGE do
      if attr.get(obj, prefix .. key, nil) ~= nil then
        return true
      end
    end
  end

  return false
end

-- the default a row rests at when nothing is stored, as the attribute that
-- scales; nil for one that scales to itself or is worked out from other rows
const function scalable(default: any): any
  const kind = typeof(default)

  if kind == "number" then
    return if default ~= 0 then default else nil
  end

  if kind == "vector" or kind == "Vector3" then
    const v = Vector3.new(default.X, default.Y, default.Z)

    return if v ~= Vector3.zero then v else nil
  end

  if kind == "NumberRange" then
    return if default.Min ~= 0 or default.Max ~= 0 then default else nil
  end

  return nil
end

-- the walk every unit-driven edit makes: the row's own keys by the unit's
-- factor, the old quad endpoints and drawn ranges of a mod row likewise, and
-- the old span keys of a mod row by the inverse when `spans` is given. `visit`
-- is called with the key and the factor for every key the walk decides on. a
-- row resting at its default stores nothing, so the default is written first
-- for the edit to scale. `unitFactor` is handed the row's name too, and a row
-- it answers nil for is not touched by its unit at all
function retime.walk(
  obj: Instance,
  module: registry.Module,
  factor: number,
  unitFactor: (unit: string, factor: number, name: string) -> number?,
  spans: number?,
  visit: (source: string, name: string, key: string, f: number) -> ()
)
  local claimed = claimedOf(module)
  const sets = { { "attribute", module.attributes }, { "property", module.properties } }

  -- a companion's rows sit on the effect's instance as its own attributes do
  for _, rows in module.companions or {} do
    table.insert(sets, { "attribute", rows })
  end

  for _, set in sets do
    local source, rows = set[1], set[2]

    for name, row in rows do
      local f = if row.units ~= nil then unitFactor(row.units, factor, name) else nil
      local keys = { name }

      for _, alias in row.names do
        table.insert(keys, alias)
      end

      if f ~= nil and f ~= 1 and source == "attribute" and not stored(obj, keys) then
        const default = scalable(row.default)

        if default ~= nil then
          attr.set(obj, name, default)
        end
      end

      for _, key in keys do
        if f ~= nil then
          visit(source, name, key, f)
        end

        -- the longest a ranged row draws up to is the same quantity
        if f ~= nil and row.isRanged and source == "attribute" then
          utility.scaleAttribute(obj, f, knob.maxOf(key))
        end

        if not row.isMod then
          continue
        end

        if f ~= nil then
          for _, suffix in QUAD do
            if not claimed[key .. suffix] then
              utility.scaleAttribute(obj, f, key .. suffix)
            end
          end

          for _, prefix in RANGE do
            if not claimed[prefix .. key] then
              utility.scaleAttribute(obj, f, prefix .. key)
            end
          end
        end

        if spans ~= nil and not claimed[key .. "_Duration"] then
          utility.scaleAttribute(obj, spans, key .. "_Duration")
        end
      end
    end
  end
end

function retime.apply(obj: Instance, factor: number, invFactor: number)
  local module = registry.of(obj)

  if module ~= nil then
    -- a lane's values are the row's, so they scale by its unit as well as its
    -- timing does below
    retime.walk(obj, module, factor, retime.factorOf, invFactor, function(source, name, key, f)
      utility.scaleAttribute(obj, f, key)
      retime.scaleLanes(obj, source, key, f)

      if source == "property" then
        retime.scaleLanes(obj, "attribute", key, f)

        if key == name then
          scaleProperty(obj, name, f)
        end
      end
    end)
  end

  -- a custom effect's instance is its own: only its rows say what scales
  local engine = module == nil or not registry.isCustom(module)

  for class, units in retime.PROPERTY_UNITS do
    if not engine or not obj:IsA(class) then
      continue
    end

    for name, unit in units do
      local f = retime.factorOf(unit, factor)

      if f ~= nil then
        scaleProperty(obj, name, f)
        retime.scaleLanes(obj, "property", name, f)
      end
    end
  end

  if module ~= nil and module.id == "animator" then
    retime.scaleAnimator(obj, factor, retime.PROPERTY_UNITS, retime.factorOf)
  end

  -- a lane is time whatever it targets, so every one on the instance scales
  utility.rescaleQueues(obj, function(lanes)
    mods.scaleTime(lanes, invFactor)
  end)

  -- the legacy child the dispatcher still emits belongs to no module, so the
  -- spans it carries are named here
  if module == nil and obj:IsA("RayValue") then
    utility.scaleAttribute(obj, invFactor, "Duration")
    utility.scaleAttribute(obj, invFactor, "Speed_Duration")
    utility.scaleAttribute(obj, invFactor, "EmitDelay")
  end
end

function retime.batch(factor: number, ...: Instance)
  if not numeric_common.finite(factor) or factor <= 0 then
    logger.warn(`retime ignores a factor of {factor}`)
    return
  end

  local invFactor = 1 / factor

  for _, instance in { ... } do
    retime.apply(instance, factor, invFactor)

    for _, desc in instance:GetDescendants() do
      retime.apply(desc, factor, invFactor)
    end
  end
end

return retime
