local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local retime = require("@mod/retime")
local utility = require("@mod/utility")
local registry = require("@mod/registry")
local path_curve = require("@mod/common/path_curve")
local state_list = require("@mod/common/state_list")
local value_curve = require("@mod/value_curve")

local resize = {}

-- a length scales, and so does anything measured in lengths per time; a
-- gravity mass by the cube, so its orbits keep their period at the new size
local function factorOf(unit: string, factor: number): number?
  if unit == "studs" or unit == "studsPerSecond" or unit == "studsPerSecondSquared" then
    return factor
  end

  if unit == "studsCubedPerSecondSquared" then
    return factor * factor * factor
  end

  return nil
end

-- engine properties no effect reads, which size still scales. a 2D emitter's
-- are offset pixels, scaled as studs are; its emission offset and spread are
-- fractions of its parent, which a resize leaves as a 3D emitter's part is
resize.PROPERTY_UNITS = {
  ParticleEmitter = { Size = "studs", Speed = "studsPerSecond", Acceleration = "studsPerSecondSquared" },
  ParticleEmitter2D = { Size = "studs", Speed = "studsPerSecond", Acceleration = "studsPerSecondSquared" },
  Sound = { RollOffMaxDistance = "studs" },
}

-- ratios resize scales as if they were lengths. the flag says whether the
-- resting value scales with them: a model's scale is its absolute size. a
-- mesh's Size is a curve of factors on its template, scaled in place of the
-- template as a ParticleEmitter's Size is, and its States a list whose
-- positions are studs, which no unit reaches inside a list. its Path is a
-- curve of studs, scaled the same way. a beam's LengthScale is not here: it
-- multiplies the attachment distance scaleShape already scales, so scaling
-- it too grew the beam's length by the factor squared
resize.RATIOS = {
  model_spin = { Scale = true },
  forge_mesh = { Size = true, States = true, Path = true },
}

-- lengths resize leaves as they are, whatever their unit. a mesh's ZOffset
-- only moves where a piece is drawn along the line to the camera, to order it
-- among the effects around it, so a resized effect keeps the layering it had
resize.KEPT = {
  forge_mesh = { ZOffset = true },
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

-- a lane endpoint of a value curve row, stored encoded; anything else the
-- reader would refuse is left as it is
const function scaleCurve(v: any, f: number): any
  if value_curve.is(v) then
    return value_curve.multiply(v, f)
  end

  const decoded = if type(v) == "string" then value_curve.decode(v) else nil

  return if decoded ~= nil then value_curve.encode(value_curve.multiply(decoded, f)) else v
end

-- a value curve row's stored curve, or its default when none is stored, and
-- every curve its lanes hold
const function scaleCurveRow(obj: Instance, name: string, row: any, f: number)
  local stored = false

  for _, key in { name, table.unpack(row.names) } do
    const raw = attr.get(obj, key, nil)

    utility.rescaleQueue(obj, "attribute", key, function(lanes)
      mods.scaleValues(lanes, f, scaleCurve)
    end)

    if raw == nil then
      continue
    end

    stored = true

    const decoded = if type(raw) == "string" then value_curve.decode(raw) else nil

    if decoded ~= nil then
      attr.set(obj, key, value_curve.encode(value_curve.multiply(decoded, f)))
    end
  end

  if not stored and value_curve.is(row.default) then
    attr.set(obj, name, value_curve.encode(value_curve.multiply(row.default, f)))
  end
end

-- a state list row's stored list with every position and size scaled. the default
-- holds no state, so an unset row has nothing to scale
const function scaleListRow(obj: Instance, name: string, row: any, f: number)
  for _, key in { name, table.unpack(row.names) } do
    const raw = attr.get(obj, key, nil)
    const list = if type(raw) == "string" then state_list.decode(raw) else nil

    if list ~= nil then
      attr.set(obj, key, state_list.encode(state_list.scaled(list, f)))
    end
  end
end

-- a path row's stored curve with every position and handle scaled, or its
-- default when none is stored. an unreadable string counts as stored and is
-- left as it was
const function scalePathRow(obj: Instance, name: string, row: any, f: number)
  local stored = false

  for _, key in { name, table.unpack(row.names) } do
    const raw = attr.get(obj, key, nil)

    if raw == nil then
      continue
    end

    stored = true

    const curve = if type(raw) == "string" then path_curve.decode(raw) else nil

    if curve ~= nil then
      attr.set(obj, key, path_curve.encode(path_curve.scaled(curve, f)))
    end
  end

  if not stored and path_curve.is(row.default) then
    attr.set(obj, name, path_curve.encode(path_curve.scaled(row.default, f)))
  end
end

-- one resize over many instances. the attachment pairs its beams and trails
-- name are gathered as they are reached and moved once, at the end: scaled
-- per beam, a pair two beams share moved twice and a ring of two beams came
-- out an oval, ten beams on one pair ten times over
export type Pass = { pairs: { { Attachment } } }

function resize.pass(): Pass
  return { pairs = {} }
end

function resize.pair(pass: Pass, a0: Attachment?, a1: Attachment?)
  if a0 ~= nil and a1 ~= nil then
    table.insert(pass.pairs, { a0, a1 })
  end
end

-- every key the pairs name, once, with where it goes: the keys a chain of
-- pairs joins scale together about their own center, so a lone pair spreads
-- about its midpoint as it always has and a ring keeps its shape
function resize.moves<K>(pairs: { { K } }, where: (K) -> vector, factor: number): { [K]: vector }
  const root: { [K]: K } = {}

  const function find(key: K): K
    local at = key

    while root[at] ~= at do
      at = root[at]
    end

    root[key] = at

    return at
  end

  for _, pair in pairs do
    for _, key in pair do
      if root[key] == nil then
        root[key] = key
      end
    end

    root[find(pair[1])] = find(pair[2])
  end

  const sums: { [K]: vector } = {}
  const counts: { [K]: number } = {}

  for key in root do
    const group = find(key)

    sums[group] = (sums[group] or vector.zero) + where(key)
    counts[group] = (counts[group] or 0) + 1
  end

  const out: { [K]: vector } = {}

  for key in root do
    const group = find(key)
    const center = sums[group] / counts[group]

    out[key] = center + (where(key) - center) * factor
  end

  return out
end

-- in world space, so a pair whose ends sit under two parts spreads about the
-- point between them rather than each end about its own part
function resize.finish(pass: Pass, factor: number)
  const moves = resize.moves(pass.pairs, function(a: Attachment): vector
    return a.WorldPosition :: any
  end, factor)

  for a, to in moves do
    a.WorldPosition = to :: any
  end

  table.clear(pass.pairs)
end

-- the geometry a few effects keep outside their rows
local function scaleShape(obj: any, module: registry.Module, factor: number, pass: Pass?)
  local id = module.id

  if id == "beam" or id == "trail" then
    if pass ~= nil then
      resize.pair(pass, obj.Attachment0, obj.Attachment1)
    else
      utility.scaleAttachmentDistance(obj.Attachment0, obj.Attachment1, factor)
    end
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

-- `pass` gathers the attachments a beam or trail spreads, for resize.finish to
-- move once; without one they move at once, which is right for one instance
function resize.apply(obj: Instance, factor: number, pass: Pass?)
  local module = registry.of(obj)

  if module ~= nil then
    local ratios = resize.RATIOS[module.id] or {}
    local kept = resize.KEPT[module.id] or {}

    const function unitFactor(unit: string, f: number, name: string): number?
      return if kept[name] then nil else factorOf(unit, f)
    end

    retime.walk(obj, module, factor, unitFactor, nil, function(source, name, key, f)
      -- a row RATIOS names takes its factor from there, never from a unit as
      -- well, so nothing it holds is ever scaled twice
      if ratios[name] ~= nil then
        return
      end

      utility.scaleAttribute(obj, f, key)
      retime.scaleLanes(obj, source, key, f)

      if source == "property" then
        retime.scaleLanes(obj, "attribute", key, f)

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

      if row.kind == "ValueCurve" then
        scaleCurveRow(obj, name, row, factor)
        continue
      end

      if row.kind == "StateList" then
        scaleListRow(obj, name, row, factor)
        continue
      end

      if row.kind == "Path" then
        scalePathRow(obj, name, row, factor)
        continue
      end

      for _, key in { name, table.unpack(row.names) } do
        if bare then
          utility.scaleAttribute(obj, factor, key)
        end

        utility.scaleAttribute(obj, factor, key .. "_Start")
        utility.scaleAttribute(obj, factor, key .. "_End")
        retime.scaleLanes(obj, "attribute", key, factor)
      end
    end

    scaleShape(obj, module, factor, pass)

    if module.id == "animator" then
      retime.scaleAnimator(obj, factor, resize.PROPERTY_UNITS, factorOf)
    end
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
        retime.scaleLanes(obj, "property", name, f)
      end
    end
  end
end

function resize.batch(factor: number, ...: Instance)
  const pass = resize.pass()

  for _, instance in { ... } do
    resize.apply(instance, factor, pass)

    for _, desc in instance:GetDescendants() do
      resize.apply(desc, factor, pass)
    end
  end

  resize.finish(pass, factor)
end

return resize
