local attr = require("@mod/attributes")
local value = require("@mod/value")
local curves = require("@mod/curves")
local logger = require("@mod/logger")
local numeric_common = require("@mod/common/numeric")

-- a stored value, read from the map a caller already holds when it hands one
-- in, and from the instance otherwise. a value no clock or lerp can use reads
-- as absent either way, as the soft read with no default always did
local function stored(ref: Instance, key: string, map: { [string]: any }?): any
  if map == nil then
    return attr.get(ref, key, nil, true)
  end

  local v = map[key]

  return if v ~= nil and numeric_common.usable(v) then v else nil
end

local legacy_mods = {}

-- the tags src/mod/utility.luau puts on a RayValue to say which side of an
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

-- old spellings a key was read under before it got its current name, newest
-- first. read only: an alias never writes the current name back, so an old
-- asset stays exactly as it was authored. the mesh effect's oldest names are
-- not here because which key they belong to depends on the model's structure,
-- and the effect resolves that itself
legacy_mods.ALIASES = {
  OffsetIn_Start = { "Offset_Start", "PartOffset" },
  OffsetIn_End = { "BaseOffset", "PartOffset" },
  OffsetOut_End = { "Offset_End", "PartOffset" },
  OffsetIn_Duration = { "Offset_Start_Duration" },
  OffsetOut_Duration = { "Offset_End_Duration" },
  OffsetIn_Curve = { "Offset_Start_Curve" },
  OffsetOut_Curve = { "Offset_End_Curve" },

  SizeScaleIn_Start = { "SizeScaleStart" },
  SizeScaleOut_End = { "SizeScaleEnd" },
  SizeScaleIn_Curve = { "Size_Start_Curve", "Size_Curve" },
  SizeScaleOut_Curve = { "Size_End_Curve", "Size_Curve" },
  SizeScaleIn_Duration = { "Size_Start_Duration", "Size_Duration" },
  SizeScaleOut_Duration = { "Size_End_Duration", "Size_Duration" },

  Width0_Start = { "StartWidth0" },
  Width1_Start = { "StartWidth1" },
  Transparency_Scale_End = { "EndTransparencyScale" },
}

function legacy_mods.alias(ref: Instance, name: string, default: any, map: { [string]: any }?): any
  local v = stored(ref, name, map)

  if v ~= nil then
    return v
  end

  local olds = legacy_mods.ALIASES[name]

  if olds then
    for _, old in olds do
      v = stored(ref, old, map)

      if v ~= nil then
        return v
      end
    end
  end

  return default
end

-- the curve keys that meant linear when absent. every other _Curve key meant
-- the out cubic default, which is what every effect read one as
legacy_mods.CURVES = {
  Easing_Curve = "linear",
  Weight_Curve = "linear",
  Path_Curve = "linear",
  Color_Curve = "linear",
  Fill_Color_Curve = "linear",
  Flipbook_Change_Curve = "linear",
}

function legacy_mods.defaultCurve(key: string): string
  if legacy_mods.CURVES[key] == "linear" then
    return curves.linear()
  end

  return curves.default()
end

-- how long an old quad ran when it named no duration of its own: the default
-- every effect read for the row's _Duration key. a row not listed lends the
-- effect's duration, which is what a new queue entry naming none does
legacy_mods.SPANS = {
  Speed = 0.1,
  SpinSpeed = 0.1,
  TimeScale = 0.1,
  OffsetIn = 0.5,
  OffsetOut = 0.5,
  Transparency = 0.5,
  SizeScaleIn = 0.5,
  SizeScaleOut = 0.5,
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
-- range, while the new format carries a single number, the same collapse the
-- plugin's own reader of this format makes
local function durationOf(v: any): number?
  if typeof(v) == "NumberRange" then
    return v.Min
  end

  if typeof(v) == "number" then
    return v
  end

  return nil
end

-- both legacy child shapes honour a ResetOnFinish attribute and default it to
-- true. the modifier codec passes a field it does not know through its `extra`
-- table, so `reset` round trips with no schema change
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

-- which side of an instance a legacy RayValue child drives: untagged means a
-- real property, because the runtime always fell back to a property tween for
-- old content
local function legacySource(child: Instance): string
  if child:HasTag(ATTRIBUTE_TWEENER_TAG) or child:HasTag(ATTRIBUTE_RANDOMIZER_TAG) then
    return "attribute"
  end

  return "property"
end

local function isRandomizer(child: Instance): boolean
  return child:HasTag(PROPERTY_RANDOMIZER_TAG) or child:HasTag(ATTRIBUTE_RANDOMIZER_TAG)
end

-- a drawn-range endpoint is a rand rather than a lit so the sampler draws it
-- once per emitted instance the way the effect used to itself
local function endpointOf(v: any, drawn: boolean): value.Value?
  if drawn and typeof(v) == "NumberRange" then
    return value.rand(v.Min, v.Max)
  end

  return litOrNil(v)
end

function legacy_mods.endpoint(source: string, name: string, v: any): value.Value?
  return endpointOf(v, legacy_mods.isDrawnRange(source, name))
end

-- a copy of a half quad with the missing half supplied by the caller, which is
-- the effect that knows what that half rests at
function legacy_mods.complete(queue: { any }, fillStart: value.Value?, fillFinish: value.Value?): { any }
  local m = table.clone(queue[1])

  if m.partial == "start" then
    m.start = fillStart
  elseif m.partial == "finish" then
    m.finish = fillFinish
  elseif m.partial == "both" then
    m.start = fillStart
    m.finish = fillFinish
  end

  m.partial = nil

  return { m }
end

-- the speed ramp a legacy tween child carried beside its tween: a multiplier on
-- the clock the tween counts, which the applier honours. carried only when it
-- does something, so an ordinary child stays a plain tween entry
local function speedOf(child: Instance): { start: number, finish: number, duration: number, curve: string | buffer }?
  local startV = attr.get(child, "Speed_Start", nil, true)
  local finishV = attr.get(child, "Speed_End", nil, true)

  if typeof(startV) ~= "number" then
    startV = 1
  end

  if typeof(finishV) ~= "number" then
    finishV = 1
  end

  if startV == 1 and finishV == 1 then
    return nil
  end

  local duration = attr.get(child, "Speed_Duration", nil, true)

  if typeof(duration) ~= "number" then
    duration = 0.1
  end

  return {
    start = startV,
    finish = finishV,
    duration = duration,
    curve = curveOf(attr.get(child, "Speed_Curve", nil, true)) or curves.default(),
  }
end

-- one RayValue child as queue entries: a randomizer is one entry; a tween is
-- one entry, led by a delay when it authored one
local function entriesOf(child: Instance): { any }
  local reset = resetOf(attr.get(child, "ResetOnFinish", nil, true))

  if isRandomizer(child) then
    return {
      {
        kind = "randomizer",
        chain = false,
        start = litOrNil(attr.get(child, "_START_VALUE", nil, true)),
        finish = litOrNil(attr.get(child, "_END_VALUE", nil, true)),
        weight = curveOf(attr.get(child, "Weight_Curve", nil, true)) or curves.linear(),
        reset = reset,
      },
    }
  end

  local out = {}

  local emitDelay = attr.get(child, "EmitDelay", nil, true)

  if typeof(emitDelay) == "number" and emitDelay > 0 then
    table.insert(out, { kind = "delay", chain = false, wait = value.lit(emitDelay) })
  end

  table.insert(out, {
    kind = "tween",
    chain = false,
    duration = durationOf(attr.get(child, "Duration", nil, true)),
    start = litOrNil(attr.get(child, "_START_VALUE", nil, true)),
    finish = litOrNil(attr.get(child, "_END_VALUE", nil, true)),
    curve = curveOf(attr.get(child, "Easing_Curve", nil, true)) or curves.linear(),
    speed = speedOf(child),
    reset = reset,
  })

  return out
end

export type Child = {
  source: string,
  name: string,
  queue: { any },
  random: boolean,
}

-- a legacy RayValue read on its own, for the applier to drive whatever the
-- RayValue targets. the target is the caller's to find
function legacy_mods.readChild(child: Instance): Child?
  if not child:IsA("RayValue") then
    return nil
  end

  return {
    source = legacySource(child),
    name = child.Name,
    queue = entriesOf(child),
    random = isRandomizer(child),
  }
end

function legacy_mods.readQuad(ref: Instance, source: string, name: string, map: { [string]: any }?): { any }?
  local startV = legacy_mods.alias(ref, `{name}_Start`, nil, map)
  local finishV = legacy_mods.alias(ref, `{name}_End`, nil, map)

  if startV == nil and finishV == nil then
    return nil
  end

  -- a half-authored quad cannot be completed here, because the missing half's
  -- default belongs to the effect and differs per knob. the entry names the
  -- missing half and mods.track fills it from the default it was handed
  local partial: string? = nil

  if startV == nil then
    partial = "start"
    startV = finishV
  end

  if finishV == nil then
    partial = "finish"
    finishV = startV
  end

  local durationV = durationOf(legacy_mods.alias(ref, `{name}_Duration`, nil, map)) or legacy_mods.SPANS[name]
  local curveV = curveOf(legacy_mods.alias(ref, `{name}_Curve`, nil, map)) or legacy_mods.defaultCurve(`{name}_Curve`)

  local drawn = legacy_mods.isDrawnRange(source, name)

  return {
    {
      kind = "tween",
      chain = false,
      duration = durationV,
      start = endpointOf(startV, drawn),
      finish = endpointOf(finishV, drawn),
      curve = curveV,
      partial = partial,
    },
  }
end

-- the RayValue children the applier in the emitter plays. only children
-- matching this source are read, so a property and an attribute of the same
-- name never see each other's authoring, and an untagged child counts as a
-- property, matching legacySource exactly
function legacy_mods.readChildren(ref: Instance, source: string, name: string): { any }?
  local out = {}

  for _, child in ref:GetChildren() do
    if child.Name ~= name or not child:IsA("RayValue") or legacySource(child) ~= source then
      continue
    end

    for _, entry in entriesOf(child) do
      table.insert(out, entry)
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
function legacy_mods.readRange(ref: Instance, source: string, name: string, map: { [string]: any }?): { any }?
  if source ~= "attribute" then
    return nil
  end

  local range = stored(ref, name, map)

  if typeof(range) == "NumberRange" then
    return { { kind = "randomizer", chain = false, start = value.lit(range.Min), finish = value.lit(range.Max) } }
  end

  local min = stored(ref, `{name}_Min`, map)
  local max = stored(ref, `{name}_Max`, map)

  -- the prefixed spelling is tried unless the underscore pair reads WHOLE. half
  -- of a pair says nothing on its own, and gating this on "neither half is
  -- there" would let one stray Size_Max suppress a complete MinSize and MaxSize,
  -- which is the spelling every shockwave in the wild actually carries
  if min == nil or max == nil then
    min = stored(ref, `Min{name}`, map)
    max = stored(ref, `Max{name}`, map)
  end

  -- half a pair cannot say what the other half was, and that default belongs to
  -- the effect. the same reason readQuad refuses to speak for a half quad
  if min == nil or max == nil then
    return nil
  end

  return { { kind = "randomizer", chain = false, start = value.lit(min), finish = value.lit(max), perComponent = true } }
end

-- a curve authored with neither end of its quad. it eases whatever ramp the
-- effect would have run by default, so both halves are left for mods.track to
-- fill; it says nothing about a constant knob, which mods.track decides
function legacy_mods.readCurve(ref: Instance, _source: string, name: string, map: { [string]: any }?): { any }?
  local curveV = curveOf(legacy_mods.alias(ref, `{name}_Curve`, nil, map))

  if curveV == nil then
    return nil
  end

  return {
    {
      kind = "tween",
      chain = false,
      duration = durationOf(legacy_mods.alias(ref, `{name}_Duration`, nil, map)) or legacy_mods.SPANS[name],
      curve = curveV,
      partial = "both",
    },
  }
end

function legacy_mods.read(ref: Instance, source: string, name: string, map: { [string]: any }?): { any }?
  local ok, result = pcall(function()
    -- range last: it is the broadest of the three shapes, matching on a single
    -- attribute named exactly for the row, so it must not shadow a quad or a
    -- RayValue child that says something more specific. the curve-only shape
    -- trails even range, because a curve with no value behind it is the least
    -- specific thing an author can have left
    return legacy_mods.readQuad(ref, source, name, map)
      or legacy_mods.readChildren(ref, source, name)
      or legacy_mods.readRange(ref, source, name, map)
      or legacy_mods.readCurve(ref, source, name, map)
  end)

  if not ok then
    logger.warn(`failed to read legacy modifiers for {name} with error: {result}`)
    return nil
  end

  return result
end

return legacy_mods
