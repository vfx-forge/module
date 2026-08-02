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
-- bezier RotSpeed, mesh Part_RotSpeed, beam Length_Scale.
--
-- exported rather than local because the plugin's own reader of this same
-- format, src/ui/attributes/legacy_quad.luau, has to agree with it exactly. it
-- writes what it reads back to the instance, so a lit NumberRange stored there
-- becomes a lit NumberRange the runtime lerps into a NumberRange and hands an
-- effect that wants a scalar
legacy_mods.DRAWN_RANGES = {
  attribute = {
    RotSpeed = true,
    Length_Scale = true,
    Part_RotSpeed = true,
  },
}

function legacy_mods.isDrawnRange(source: string, name: string): boolean
  local group = legacy_mods.DRAWN_RANGES[source]

  return group ~= nil and group[name] == true
end

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

  -- a half-authored quad cannot be represented faithfully here, because the
  -- missing half's default belongs to the EFFECT and differs per knob: 0 or 1
  -- for a decal transparency, 1 for a speed, NumberRange(0, 0) for a rotation
  -- speed, the clone's live Volume for a sound. copying the other half is the
  -- best a generic reader can do and is what a caller with no effect behind it
  -- gets, so the entry records that it happened and mods.driver hands the knob
  -- back to its effect rather than pinning it to a constant
  local partial = startV == nil or finishV == nil

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

  local drawn = legacy_mods.isDrawnRange(source, name)

  return {
    {
      kind = "tween",
      chain = false,
      duration = durationV,
      start = endpointOf(startV, drawn),
      finish = endpointOf(finishV, drawn),
      curve = curveV,
      partial = partial or nil,
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

-- a value drawn ONCE per emitted instance, which is what a randomizer modifier
-- already is. Legacy content spells it two ways: one NumberRange attribute
-- (`Lifetime`, `Amount`, `Airtime`) or a pair of attributes (`MinSize` and
-- `MaxSize`). Both mean the same thing, so both read as one entry.
--
-- The pair is looked for as `<name>_Min` and `<name>_Max` first, which is the
-- spelling to author going forward, and only then as `Min<name>` and
-- `Max<name>`, which is what the shockwaves have always written. Reading both
-- means content already in the wild becomes an editable row without anyone
-- having to rename an attribute on it.
--
-- Attribute source only. These are effect knobs, and a bare `<name>` lookup
-- against a property source would collide with real property names: a Part
-- carries MinSize-ish attributes and a `Size` property that mean nothing to
-- each other.
function legacy_mods.readRange(ref: Instance, source: string, name: string): { any }?
  if source ~= "attribute" then
    return nil
  end

  local range = ref:GetAttribute(name)

  if typeof(range) == "NumberRange" then
    return { { kind = "randomizer", chain = false, start = value.lit(range.Min), finish = value.lit(range.Max) } }
  end

  local min = ref:GetAttribute(`{name}_Min`)
  local max = ref:GetAttribute(`{name}_Max`)

  -- the prefixed spelling is tried unless the underscore pair reads WHOLE. half
  -- of a pair says nothing on its own, and gating this on "neither half is
  -- there" would let one stray Size_Max suppress a complete MinSize and MaxSize,
  -- which is the spelling every shockwave in the wild actually carries
  if min == nil or max == nil then
    min = ref:GetAttribute(`Min{name}`)
    max = ref:GetAttribute(`Max{name}`)
  end

  -- half a pair cannot say what the other half was, and that default belongs to
  -- the effect. the same reason readQuad refuses to speak for a half quad
  if min == nil or max == nil then
    return nil
  end

  return { { kind = "randomizer", chain = false, start = value.lit(min), finish = value.lit(max), perComponent = true } }
end

function legacy_mods.read(ref: Instance, source: string, name: string): { any }?
  local ok, result = pcall(function()
    -- range last: it is the broadest of the three shapes, matching on a single
    -- attribute named exactly for the row, so it must not shadow a quad or a
    -- RayValue child that says something more specific
    return legacy_mods.readQuad(ref, source, name)
      or legacy_mods.readChildren(ref, source, name)
      or legacy_mods.readRange(ref, source, name)
  end)

  if not ok then
    logger.warn(`failed to read legacy modifiers for {name} with error: {result}`)
    return nil
  end

  return result
end

return legacy_mods
