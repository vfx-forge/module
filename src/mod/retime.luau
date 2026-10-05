local mods = require("@mod/mods")
local logger = require("@mod/logger")
local utility = require("@mod/utility")
local registry = require("@mod/registry")
local numeric_common = require("@mod/common/numeric")

local pool = require("@srv/pool")

local retime = {}

-- how a unit scales when time runs `factor` times faster: a span shrinks, a
-- rate grows, an acceleration grows by the square, a length is untouched
function retime.factorOf(unit: string, factor: number): number?
  if unit == "seconds" then
    return 1 / factor
  end

  if unit == "perSecond" or unit == "studsPerSecond" then
    return factor
  end

  if unit == "perSecondSquared" or unit == "studsPerSecondSquared" then
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

local QUAD = { "_Start", "_End", "_Min", "_Max" }
local RANGE = { "Min", "Max" }

-- every name a module's rows answer to, so a legacy key one row claims is
-- never scaled twice by another row's rule
local function claimedOf(module: registry.Module): { [string]: boolean }
  local out = {}

  for _, rows in { module.attributes, module.properties } do
    for name, row in rows do
      out[name] = true

      for _, alias in row.names do
        out[alias] = true
      end
    end
  end

  return out
end

-- the walk every unit-driven edit makes: the row's own keys by the unit's
-- factor, the old quad endpoints and drawn ranges of a mod row likewise, and
-- the old span keys of a mod row by the inverse when `spans` is given. `visit`
-- is called with the key and the factor for every key the walk decides on
function retime.walk(
  obj: Instance,
  module: registry.Module,
  factor: number,
  unitFactor: (unit: string, factor: number) -> number?,
  spans: number?,
  visit: (source: string, name: string, key: string, f: number) -> ()
)
  local claimed = claimedOf(module)

  for source, rows in { attribute = module.attributes, property = module.properties } do
    for name, row in rows do
      local f = if row.units ~= nil then unitFactor(row.units, factor) else nil
      local keys = { name }

      for _, alias in row.names do
        table.insert(keys, alias)
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
    retime.walk(obj, module, factor, retime.factorOf, invFactor, function(source, name, key, f)
      utility.scaleAttribute(obj, f, key)

      if source == "property" and key == name then
        scaleProperty(obj, name, f)
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

    pool.touch(instance)
  end
end

return retime
