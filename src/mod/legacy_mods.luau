local value = require("@mod/value")
local logger = require("@mod/logger")

local legacy_mods = {}

-- the tags src/utility.luau puts on a RayValue to say which side of an
-- instance it drives. kept as literals rather than a require, so the
-- quarantine has no dependency that could pull a legacy name anywhere else
local ATTRIBUTE_TWEENER_TAG = "AttributeTweener"
local PROPERTY_RANDOMIZER_TAG = "PropertyRandomizer"
local ATTRIBUTE_RANDOMIZER_TAG = "AttributeRandomizer"

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

-- the released-era quad. a nil _Duration is left nil rather than defaulted,
-- because nil is what "runs over the effect's own duration" is spelled as
function legacy_mods.readQuad(ref: Instance, name: string): { any }?
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

  local durationV = durationOf(ref:GetAttribute(`{name}_Duration`))
  local curveV = curveOf(ref:GetAttribute(`{name}_Curve`))

  return {
    {
      kind = "tween",
      chain = false,
      duration = durationV,
      start = value.lit(startV),
      finish = value.lit(finishV),
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

    if isRandom then
      table.insert(out, {
        kind = "randomizer",
        chain = false,
        start = litOrNil(child:GetAttribute("_START_VALUE")),
        finish = litOrNil(child:GetAttribute("_END_VALUE")),
        weight = curveOf(child:GetAttribute("Weight_Curve")),
      })
    else
      table.insert(out, {
        kind = "tween",
        chain = false,
        duration = durationOf(child:GetAttribute("Duration")),
        start = litOrNil(child:GetAttribute("_START_VALUE")),
        finish = litOrNil(child:GetAttribute("_END_VALUE")),
        curve = curveOf(child:GetAttribute("Easing_Curve")),
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
    return legacy_mods.readQuad(ref, name) or legacy_mods.readChildren(ref, source, name)
  end)

  if not ok then
    logger.warn(`failed to read legacy modifiers for {name} with error: {result}`)
    return nil
  end

  return result
end

return legacy_mods
