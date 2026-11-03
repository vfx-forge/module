local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local logger = require("@mod/logger")
local utility = require("@mod/utility")
local registry = require("@mod/registry")
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

-- engine properties no effect reads, which time still scales
retime.PROPERTY_UNITS = {
  ParticleEmitter = {
    Speed = "studsPerSecond",
    RotSpeed = "perSecond",
    Lifetime = "seconds",
    Acceleration = "studsPerSecondSquared",
    Drag = "perSecond",
    Rate = "perSecond",
  },
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

  if typeof(v) == "number" or typeof(v) == "Vector3" then
    obj[name] = v * f
  elseif typeof(v) == "NumberRange" then
    obj[name] = NumberRange.new(v.Min * f, v.Max * f)
  elseif typeof(v) == "NumberSequence" then
    obj[name] = utility.scaleNumberSequence(v, f)
  end
end

const function scaleValues(obj: Instance, source: string, key: string, f: number)
  utility.rescaleQueue(obj, source, key, function(lanes)
    mods.scaleValues(lanes, f)
  end)
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
-- for the edit to scale
function retime.walk(
  obj: Instance,
  module: registry.Module,
  factor: number,
  unitFactor: (unit: string, factor: number) -> number?,
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
      local f = if row.units ~= nil then unitFactor(row.units, factor) else nil
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
      scaleValues(obj, source, key, f)

      if source == "property" then
        scaleValues(obj, "attribute", key, f)

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
      end
    end
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
