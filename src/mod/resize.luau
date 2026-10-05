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
-- effect looks as it did. the flag says whether the resting value scales with
-- them: a spin model's scale is its absolute size, where a beam's length scale
-- multiplies the attachment distance that scaleShape already scales
resize.RATIOS = {
  model_spin = { Scale = true },
  beam = { LengthScale = false },
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
  utility.rescaleQueue(obj, source, key, function(lanes)
    mods.scaleValues(lanes, f)
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

    retime.walk(obj, module, factor, factorOf, nil, function(source, name, key, f)
      -- a row RATIOS names takes its factor from there, never from a unit as
      -- well, so nothing it holds is ever scaled twice
      if ratios[name] ~= nil then
        return
      end

      utility.scaleAttribute(obj, f, key)
      scaleQueue(obj, source, key, f)

      if source == "property" then
        scaleQueue(obj, "attribute", key, f)

        if key == name then
          scaleProperty(obj, name, f)
        end
      end
    end)

    for name, bare in ratios do
      local row = module.attributes[name]

      if row == nil then
        continue
      end

      for _, key in { name, table.unpack(row.names) } do
        if bare then
          utility.scaleAttribute(obj, factor, key)
        end

        utility.scaleAttribute(obj, factor, key .. "_Start")
        utility.scaleAttribute(obj, factor, key .. "_End")
        scaleQueue(obj, "attribute", key, factor)
      end
    end

    scaleShape(obj, module, factor)
  end

  -- a custom effect's instance is its own: only its rows say what scales
  local engine = module == nil or not registry.isCustom(module)

  for class, units in resize.PROPERTY_UNITS do
    if not engine or not obj:IsA(class) then
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
