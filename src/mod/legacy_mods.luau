local value = require("@mod/value")
local curves = require("@mod/curves")
local logger = require("@mod/logger")

local legacy_mods = {}

-- the tags src/utility.luau puts on a RayValue to say which side of an
-- instance it drives. kept as literals rather than a require, so the
-- quarantine has no dependency that could pull a legacy name anywhere else
local ATTRIBUTE_TWEENER_TAG = "AttributeTweener"
local PROPERTY_RANDOMIZER_TAG = "PropertyRandomizer"
local ATTRIBUTE_RANDOMIZER_TAG = "AttributeRandomizer"

-- the only quads whose _Start and _End hold a NumberRange the effect draws ONE
-- scalar from per emitted instance, rather than two values to tween between.
-- listed by name because a NumberRange is a legitimate target type too, and an
-- attribute quad is the only place any of these is ever authored:
-- bezier RotSpeed, mesh Part_RotSpeed, beam Length_Scale
local DRAWN_RANGES = {
  attribute = {
    RotSpeed = true,
    Length_Scale = true,
    Part_RotSpeed = true,
  },
}

-- omitted rather than wrapped when absent, so evaluate sees no endpoint at
-- all instead of a lit nil it would try to lerp
local function litOrNil(v: any): value.Value?
  if v == nil then
    return nil
  end

  return value.lit(v)
end

-- a NumberRange duration collapses to its Min. real authored data stores a
-- range (src/effects/tweener.luau reads it via attr.getRange), while the new
-- format carries a single number, the same collapse legacy_quad.luau makes
-- for the plugin's own "show" side
local function durationOf(v: any): number?
  if typeof(v) == "NumberRange" then
    return v.Min
  end

  if typeof(v) == "number" then
    return v
  end

  return nil
end

-- both effects that play a legacy child honour a ResetOnFinish attribute on it
-- and default it to true (src/effects/tweener.luau, src/effects/randomizer.luau).
-- the modifier codec passes a field it does not know through its `extra` table,
-- so `reset` round trips with no schema change
local function resetOf(v: any): boolean
  if typeof(v) == "boolean" then
    return v
  end

  return true
end

local function curveOf(v: any): (string | buffer)?
  if typeof(v) == "string" or typeof(v) == "buffer" then
    return v
  end

  return nil
end

-- which side of an instance a legacy RayValue child drives, mirrored from
-- modifier_store.luau's legacySource, the shipping reader for this same
-- data: untagged means a real property, because emitters.dispatch falls back
-- to property_tweener for old content and src/utility.luau's scan buckets an
-- untagged child into tween_properties
local function legacySource(child: Instance): string
  if child:HasTag(ATTRIBUTE_TWEENER_TAG) or child:HasTag(ATTRIBUTE_RANDOMIZER_TAG) then
    return "attribute"
  end

  return "property"
end

-- a drawn-range endpoint, which is a rand rather than a lit so the sampler
-- draws it once per emitted instance the way the effect used to itself
local function endpointOf(v: any, drawn: boolean): value.Value?
  if drawn and typeof(v) == "NumberRange" then
    return value.rand(v.Min, v.Max)
  end

  return litOrNil(v)
end

-- the released-era quad. a nil _Duration is left nil rather than defaulted,
-- because nil is what "runs over the effect's own duration" is spelled as
function legacy_mods.readQuad(ref: Instance, source: string, name: string): { any }?
  local startV = ref:GetAttribute(`{name}_Start`)
  local finishV = ref:GetAttribute(`{name}_End`)

  if startV == nil and finishV == nil then
    return nil
  end

  if startV == nil then
    startV = finishV
  end

  if finishV == nil then
    finishV = startV
  end

  -- a quad with no _Curve meant OUT CUBIC and not linear, because every effect
  -- read one as attr.get(ref, "X_Curve", utility.default_bezier). leaving it nil
  -- would have evaluate fall back to plain progress. every _Start / _End quad in
  -- the package pairs with a _Curve of that default; the legacy curves that
  -- default to linear (Easing_Curve, Weight_Curve, Path_Curve) are never quad
  -- halves, and readChildren reads those
  local durationV = durationOf(ref:GetAttribute(`{name}_Duration`))
  local curveV = curveOf(ref:GetAttribute(`{name}_Curve`)) or curves.default()

  local group = DRAWN_RANGES[source]
  local drawn = group ~= nil and group[name] == true

  return {
    {
      kind = "tween",
      chain = false,
      duration = durationV,
      start = endpointOf(startV, drawn),
      finish = endpointOf(finishV, drawn),
      curve = curveV,
    },
  }
end

-- the RayValue children the tweener and randomizer effects still play. only
-- children matching this source are read, so a property and an attribute of
-- the same name never see each other's authoring, and an untagged child
-- counts as a property, matching legacySource exactly
function legacy_mods.readChildren(ref: Instance, source: string, name: string): { any }?
  local out = {}

  for _, child in ref:GetChildren() do
    if child.Name ~= name or not child:IsA("RayValue") or legacySource(child) ~= source then
      continue
    end

    local isRandom = child:HasTag(PROPERTY_RANDOMIZER_TAG) or child:HasTag(ATTRIBUTE_RANDOMIZER_TAG)
    local reset = resetOf(child:GetAttribute("ResetOnFinish"))

    if isRandom then
      table.insert(out, {
        kind = "randomizer",
        chain = false,
        start = litOrNil(child:GetAttribute("_START_VALUE")),
        finish = litOrNil(child:GetAttribute("_END_VALUE")),
        weight = curveOf(child:GetAttribute("Weight_Curve")),
        reset = reset,
      })
    else
      table.insert(out, {
        kind = "tween",
        chain = false,
        duration = durationOf(child:GetAttribute("Duration")),
        start = litOrNil(child:GetAttribute("_START_VALUE")),
        finish = litOrNil(child:GetAttribute("_END_VALUE")),
        curve = curveOf(child:GetAttribute("Easing_Curve")),
        reset = reset,
      })
    end
  end

  if #out == 0 then
    return nil
  end

  return out
end

function legacy_mods.read(ref: Instance, source: string, name: string): { any }?
  local ok, result = pcall(function()
    return legacy_mods.readQuad(ref, source, name) or legacy_mods.readChildren(ref, source, name)
  end)

  if not ok then
    logger.warn(`failed to read legacy modifiers for {name} with error: {result}`)
    return nil
  end

  return result
end

return legacy_mods
