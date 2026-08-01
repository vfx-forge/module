local value = require("@mod/value")
local logger = require("@mod/logger")

local legacy_mods = {}

-- the tags src/utility.luau puts on a RayValue to say which side of an
-- instance it drives. kept as literals rather than a require, so the
-- quarantine has no dependency that could pull a legacy name anywhere else
local PROPERTY_TWEENER_TAG = "PropertyTweener"
local ATTRIBUTE_TWEENER_TAG = "AttributeTweener"
local PROPERTY_RANDOMIZER_TAG = "PropertyRandomizer"
local ATTRIBUTE_RANDOMIZER_TAG = "AttributeRandomizer"

local function tagsFor(source: string): (string, string)
  if source == "property" then
    return PROPERTY_TWEENER_TAG, PROPERTY_RANDOMIZER_TAG
  end

  return ATTRIBUTE_TWEENER_TAG, ATTRIBUTE_RANDOMIZER_TAG
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

  local duration = ref:GetAttribute(`{name}_Duration`)
  local curve = ref:GetAttribute(`{name}_Curve`)

  return {
    {
      kind = "tween",
      chain = false,
      duration = if typeof(duration) == "number" then duration else nil,
      start = value.lit(startV),
      finish = value.lit(finishV),
      curve = if typeof(curve) == "string" or typeof(curve) == "buffer" then curve else nil,
    },
  }
end

-- the RayValue children the tweener and randomizer effects still play. only
-- children matching this source are read, so a property and an attribute of
-- the same name never see each other's authoring
function legacy_mods.readChildren(ref: Instance, source: string, name: string): { any }?
  local tweenTag, randomTag = tagsFor(source)

  local out = {}

  for _, child in ref:GetChildren() do
    if child.Name ~= name or not child:IsA("RayValue") then
      continue
    end

    local isTween = child:HasTag(tweenTag)
    local isRandom = child:HasTag(randomTag)

    if not isTween and not isRandom then
      continue
    end

    local startV = child:GetAttribute("Start")
    local finishV = child:GetAttribute("End")
    local duration = child:GetAttribute("Duration")
    local curve = child:GetAttribute("Curve")

    table.insert(out, {
      kind = if isRandom then "randomizer" else "tween",
      chain = false,
      duration = if typeof(duration) == "number" then duration else nil,
      start = value.lit(startV),
      finish = value.lit(finishV),
      curve = if isTween and typeof(curve) == "string" then curve else nil,
      weight = if isRandom and typeof(curve) == "string" then curve else nil,
    })
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
