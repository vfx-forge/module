local mods = require("@mod/mods")
local retime = require("@mod/retime")
local utility = require("@mod/utility")
local registry = require("@mod/registry")

local resize = {}

-- a length scales, and so does anything measured in lengths per time
local function factorOf(unit: string, factor: number): number?
  if unit == "studs" or unit == "studsPerSecond" or unit == "studsPerSecondSquared" then
    return factor
  end

  return nil
end

-- engine properties no effect reads, which size still scales
resize.PROPERTY_UNITS = {
  ParticleEmitter = { Size = "studs", Speed = "studsPerSecond", Acceleration = "studsPerSecondSquared" },
  Sound = { RollOffMaxDistance = "studs" },
}

-- ratios the old resize scaled as if they were lengths, kept so a resized
-- effect looks as it did: a spin model's scale is its absolute size, and a
-- beam's length scale was scaled beside its attachments
resize.RATIOS = {
  model_spin = { Scale = true },
  beam = { LengthScale = true },
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

local function scaleQueue(obj: Instance, source: string, key: string, f: number)
  utility.rescaleQueue(obj, source, key, function(queue)
    mods.scaleValues(queue, f)
  end)
end

-- the geometry a few effects keep outside their rows
local function scaleShape(obj: any, module: registry.Module, factor: number)
  local id = module.id

  if id == "beam" or id == "trail" then
    utility.scaleAttachmentDistance(obj.Attachment0, obj.Attachment1, factor)
  elseif id == "mesh" then
    local start = obj:FindFirstChild("Start")
    local goal = obj:FindFirstChild("End")

    if start and goal then
      start.Size *= factor
      goal.Size *= factor

      local startMesh = start:FindFirstChildOfClass("SpecialMesh")
      local goalMesh = goal:FindFirstChildOfClass("SpecialMesh")

      if startMesh and goalMesh then
        startMesh.Scale *= factor
        goalMesh.Scale *= factor
      end
    end
  elseif id == "shockwave_debris" then
    obj.Size *= factor
  end
end

function resize.apply(obj: Instance, factor: number)
  local module = registry.of(obj)

  if module ~= nil then
    local ratios = resize.RATIOS[module.id] or {}

    retime.walk(
      obj,
      module,
      factor,
      function(unit, f)
        return factorOf(unit, f)
      end,
      nil,
      function(source, name, key, f)
        utility.scaleAttribute(obj, f, key)
        scaleQueue(obj, source, key, f)

        if source == "property" then
          scaleQueue(obj, "attribute", key, f)

          if key == name then
            scaleProperty(obj, name, f)
          end
        end
      end
    )

    for name in ratios do
      local row = module.attributes[name]

      if row == nil then
        continue
      end

      for _, key in { name, table.unpack(row.names) } do
        utility.scaleAttribute(obj, factor, key)
        utility.scaleAttribute(obj, factor, key .. "_Start")
        utility.scaleAttribute(obj, factor, key .. "_End")
        scaleQueue(obj, "attribute", key, factor)
      end
    end

    scaleShape(obj, module, factor)
  end

  for class, units in resize.PROPERTY_UNITS do
    if not obj:IsA(class) then
      continue
    end

    for name, unit in units do
      local f = factorOf(unit, factor)

      if f ~= nil then
        scaleProperty(obj, name, f)
      end
    end
  end
end

function resize.batch(factor: number, ...: Instance)
  for _, instance in { ... } do
    resize.apply(instance, factor)

    for _, desc in instance:GetDescendants() do
      resize.apply(desc, factor)
    end
  end
end

return resize
