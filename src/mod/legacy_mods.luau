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

-- the keys an old row's shapes are stored under, derived from the row's name
-- once and kept. every read of that row would otherwise build the same handful
-- of strings again
local Keys: { [string]: { [string]: string } } = {}

-- the tags src/mod/utility.luau puts on a RayValue to say which side of an
-- instance it drives. kept as literals rather than a require, so the
-- quarantine has no dependency that could pull a legacy name anywhere else
local ATTRIBUTE_TWEENER_TAG = "AttributeTweener"
local PROPERTY_RANDOMIZER_TAG = "PropertyRandomizer"
local ATTRIBUTE_RANDOMIZER_TAG = "AttributeRandomizer"
local PROPERTY_ANIMATOR_TAG = "PropertyAnimator"

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

-- a Transparency quad ran 0.5 seconds by default only on a shockwave's
-- pieces, every one a BasePart. a mesh's decal and the old lightning ran
-- theirs over the effect's own length, and a 0.5 lent to them by the name
-- alone cut a mesh decal's fade short from 2026-09-13 on
local PART_SPANS = { Transparency = true }

function legacy_mods.spanOf(ref: Instance, name: string): number?
  if PART_SPANS[name] and not ref:IsA("BasePart") then
    return nil
  end

  return legacy_mods.SPANS[name]
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

-- both legacy child shapes honor a ResetOnFinish attribute and default it to
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
local function legacySource(child: Instance): string?
  -- a Property Animator is named for its property as a tween child is, but it
  -- is an effect of its own
  if child:HasTag(PROPERTY_ANIMATOR_TAG) then
    return nil
  end

  if child:HasTag(ATTRIBUTE_TWEENER_TAG) or child:HasTag(ATTRIBUTE_RANDOMIZER_TAG) then
    return "attribute"
  end

  return "property"
end

-- the same question asked from outside, for a caller deciding whether a child
-- belongs to a row the walk below already folds it into
legacy_mods.childSource = legacySource

local function isRandomizer(child: Instance): boolean
  return child:HasTag(PROPERTY_RANDOMIZER_TAG) or child:HasTag(ATTRIBUTE_RANDOMIZER_TAG)
end

-- a drawn-range endpoint is a draw rather than a lit so the sampler draws it
-- once per emitted instance the way the effect used to itself
local function endpointOf(v: any, drawn: boolean): value.Value?
  if drawn and typeof(v) == "NumberRange" then
    return value.draw(v.Min, v.Max)
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

-- a tween the old format left to start from its target's own value: read off
-- a child naming no _START_VALUE, or stored from one. only the readers of the
-- old format set `reset`
function legacy_mods.fromTarget(m: any): boolean
  return m.kind == "tween" and m.reset ~= nil and m.start == nil and m.partial == nil
end

-- such a tween an earlier plugin stored with no chain, which plays nothing
-- until halfway and then jumps. a lone one marked seedable is left to the
-- read, which chains it only where the row's start is not the effect's
local function startless(m: any): boolean
  return legacy_mods.fromTarget(m) and m.chain ~= true and m.seedable ~= true
end

-- a stored lane map with each such tween chained, or the map itself when none
-- is in it
function legacy_mods.repaired(lanes: { [string]: { any } }): { [string]: { any } }
  local out = nil

  for lane, queue in lanes do
    for i, m in queue do
      if not startless(m) then
        continue
      end

      if out == nil then
        out = table.clone(lanes)
      end

      if out[lane] == queue then
        out[lane] = table.clone(queue)
      end

      local fixed = table.clone(m)
      fixed.chain = true
      out[lane][i] = fixed
    end
  end

  return out or lanes
end

-- the queue with each tween left to start from its target chained from
-- `rest`, save where `rest` is not of its end's type: v2 played nothing
-- there, and a lerp between the two would throw. the queue itself when no
-- entry changes
function legacy_mods.fromRest(queue: { any }, rest: any): { any }
  local out = nil

  for i, m in queue do
    if not legacy_mods.fromTarget(m) then
      continue
    end

    local finish = m.finish
    local chains = rest ~= nil and finish ~= nil and value.isLit(finish) and typeof(finish.v) == typeof(rest)

    if (m.chain == true) == chains then
      continue
    end

    if out == nil then
      out = table.clone(queue)
    end

    local fixed = table.clone(m)
    fixed.chain = chains
    out[i] = fixed
  end

  return out or queue
end

-- the speed ramp a legacy tween child carried beside its tween: a multiplier on
-- the clock the tween counts, which the applier honors. carried only when it
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
-- one entry, led by a delay when it authored one. every child of a name ran
-- from the emit on its own clock, so each entry is `parallel`, its delay too:
-- a child starts at its own delay alone, never after the children before it
local function entriesOf(child: Instance): { any }
  local reset = resetOf(attr.get(child, "ResetOnFinish", nil, true))

  if isRandomizer(child) then
    return {
      {
        kind = "randomizer",
        chain = false,
        parallel = true,
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
    table.insert(out, { kind = "delay", chain = false, parallel = true, wait = value.lit(emitDelay) })
  end

  local start = litOrNil(attr.get(child, "_START_VALUE", nil, true))

  -- a tween naming no _START_VALUE ran from whatever its target held as it
  -- began, which an entry says by chaining
  table.insert(out, {
    kind = "tween",
    chain = start == nil,
    parallel = true,
    duration = durationOf(attr.get(child, "Duration", nil, true)),
    start = start,
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
  if not child:IsA("RayValue") or child:HasTag(PROPERTY_ANIMATOR_TAG) then
    return nil
  end

  return {
    source = legacySource(child) :: string,
    name = child.Name,
    queue = entriesOf(child),
    random = isRandomizer(child),
  }
end

local function keysOf(name: string)
  local derived = Keys[name]

  if derived == nil then
    derived = {
      min = `{name}_Min`,
      max = `{name}_Max`,
      start = `{name}_Start`,
      finish = `{name}_End`,
      curve = `{name}_Curve`,
      lowest = `Min{name}`,
      highest = `Max{name}`,
      duration = `{name}_Duration`,
    }

    Keys[name] = derived
  end

  return derived
end

-- an old shape read once per distinct set of stored values: every clone of a
-- template stores the same ones, and a queue is read and never written past
-- here, so one frozen table answers them all and a build keyed on it is a
-- build keyed on the content. the values are spelled out by type and text,
-- which tells any two apart that a tween could tell apart
local QUEUES: { [string]: { any } } = {}
local QUEUES_CAP = 4096
local queueCount = 0

local function text(v: any): string
  if v == nil then
    return ""
  end

  if typeof(v) == "buffer" then
    return `buffer:{buffer.tostring(v)}`
  end

  return `{typeof(v)}:{tostring(v)}`
end

local function remember(key: string, queue: { any }): { any }
  for _, m in queue do
    for _, v in m do
      if type(v) == "table" then
        table.freeze(v)
      end
    end

    table.freeze(m)
  end

  table.freeze(queue)

  if queueCount >= QUEUES_CAP then
    table.clear(QUEUES)
    queueCount = 0
  end

  QUEUES[key] = queue
  queueCount += 1

  return queue
end

-- the rows whose quad v2 played only when it moved, by class: a beam's curve
-- sizes and texture rows kept the beam's own property when the start equaled
-- the end, and its clock ran at 1. a still width or transparency scale
-- applied, so neither is here
legacy_mods.MOVING_ONLY = {
  Beam = {
    Speed = true,
    CurveSize0 = true,
    CurveSize1 = true,
    Speed_Texture = true,
    Length_Texture = true,
  },
}

-- every name some class lists above, so a read of any other row asks nothing
-- of the instance
const STILL_NAMES: { [string]: boolean } = {}

for _, rows in legacy_mods.MOVING_ONLY do
  for name in rows do
    STILL_NAMES[name] = true
  end
end

-- a beam's still length scale moved its attachments only where the texture
-- length started away from 1: v2.4.0 (effects/beam.luau) asked
-- Length_Texture_Start, or the beam's TextureLength, where it meant to ask
-- the length scale. a v2 bug, kept for what v2 shaped: only the old spelling
-- is gated, so a LengthScale written under its own name always applies
const GATED = "Length_Scale"

STILL_NAMES[GATED] = true

-- whether the beam's texture length started at 1 as v2.4.0 read it, so its
-- still length scale did nothing
const function gateShut(ref: Instance, map: { [string]: any }?): boolean
  local start = stored(ref, "Length_Texture_Start", map)

  if start == nil then
    start = (ref :: any).TextureLength
  end

  return start == 1
end

-- the one value a drawn endpoint lands on every emit, nil where it draws a
-- spread: v2.4.0 drew each end of the quad on its own, so a spread moved
const function fixedOf(v: any): any
  if typeof(v) == "NumberRange" then
    return if v.Min == v.Max then v.Min else nil
  end

  return v
end

-- the value both ends of a gated still quad hold, nil for any other quad
const function gatedAt(ref: Instance, name: string, startV: any, finishV: any): any
  if name ~= GATED or ref.ClassName ~= "Beam" or startV == nil or finishV == nil then
    return nil
  end

  const at = fixedOf(startV)

  return if at ~= nil and at == fixedOf(finishV) then at else nil
end

local function heldStill(ref: Instance, name: string, startV: any, finishV: any, map: { [string]: any }?): boolean
  if name == GATED then
    return gatedAt(ref, name, startV, finishV) ~= nil and gateShut(ref, map)
  end

  const rows = legacy_mods.MOVING_ONLY[ref.ClassName]

  return rows ~= nil and rows[name] == true and startV ~= nil and startV == finishV
end

-- whether the quad stored under `name` is one v2 never applied, which reads as
-- no quad at all
function legacy_mods.isHeldStill(ref: Instance, name: string, map: { [string]: any }?): boolean
  const keys = keysOf(name)

  return heldStill(
    ref,
    name,
    legacy_mods.alias(ref, keys.start, nil, map),
    legacy_mods.alias(ref, keys.finish, nil, map),
    map
  )
end

-- the value a gated still quad under `name` plays at where its gate is open,
-- nil for any other quad and where the gate is shut. the convert writes it as
-- the row's own value, which applies wherever the texture length goes after
function legacy_mods.gatedValue(ref: Instance, name: string, map: { [string]: any }?): any
  const keys = keysOf(name)
  const at =
    gatedAt(ref, name, legacy_mods.alias(ref, keys.start, nil, map), legacy_mods.alias(ref, keys.finish, nil, map))

  return if at ~= nil and not gateShut(ref, map) then at else nil
end

-- whether the map stores any key of the old quad under `name`, which only the
-- old format ever wrote
function legacy_mods.quadded(map: { [string]: any }, name: string): boolean
  const keys = keysOf(name)

  return map[keys.start] ~= nil or map[keys.finish] ~= nil or map[keys.duration] ~= nil or map[keys.curve] ~= nil
end

-- the one value a lone seedable tween on the start lane holds at both ends,
-- the shape the plugin converted a still quad into, nil for any other map. a
-- drawn end counts where it draws one value, as a converted length scale's do
const function stillLaneAt(lanes: { [string]: { any } }, drawn: boolean): any
  for lane in lanes do
    if lane ~= "start" then
      return nil
    end
  end

  const queue = lanes.start

  if queue == nil or #queue ~= 1 then
    return nil
  end

  const m = queue[1]

  if m.kind ~= "tween" or m.seedable ~= true or m.chain == true or m.partial ~= nil then
    return nil
  end

  const function endOf(v: value.Value?): any
    if v == nil then
      return nil
    end

    if value.isLit(v) then
      return v.v
    end

    if drawn and value.isDraw(v) and v.a == v.b then
      return v.a
    end

    return nil
  end

  const at = endOf(m.start)

  return if at ~= nil and at == endOf(m.finish) then at else nil
end

-- whether a framed map is one the plugin converted out of such a still quad
-- before the quad read as none: a lone seedable tween on the start lane, its
-- ends one literal. it reads as no map, so the row keeps the instance's own
-- value as v2 did. only the convert marks a lane seedable, never one the
-- modifier window adds. a length scale an earlier plugin converted is gated
-- on the texture length as its quad is, though the texture quad that
-- convert took off is no longer there to ask
function legacy_mods.isHeldStillLane(ref: Instance, name: string, lanes: { [string]: { any } }): boolean
  if not STILL_NAMES[name] then
    return false
  end

  if name == GATED then
    return ref.ClassName == "Beam" and stillLaneAt(lanes, true) ~= nil and gateShut(ref, nil)
  end

  const rows = legacy_mods.MOVING_ONLY[ref.ClassName]

  if rows == nil or not rows[name] then
    return false
  end

  return stillLaneAt(lanes, false) ~= nil
end

function legacy_mods.readQuad(ref: Instance, source: string, name: string, map: { [string]: any }?): { any }?
  local keys = keysOf(name)
  local startV = legacy_mods.alias(ref, keys.start, nil, map)
  local finishV = legacy_mods.alias(ref, keys.finish, nil, map)

  if startV == nil and finishV == nil then
    return nil
  end

  if heldStill(ref, name, startV, finishV, map) then
    return nil
  end

  local durationRaw = legacy_mods.alias(ref, keys.duration, nil, map)
  local curveRaw = legacy_mods.alias(ref, keys.curve, nil, map)
  local span = legacy_mods.spanOf(ref, name)
  local key = `quad|{source}|{name}|{text(startV)}|{text(finishV)}|{text(durationRaw)}|{text(curveRaw)}|{text(span)}`
  local known = QUEUES[key]

  if known ~= nil then
    return known
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

  local durationV = durationOf(durationRaw) or span
  local curveV = curveOf(curveRaw) or legacy_mods.defaultCurve(keys.curve)

  local drawn = legacy_mods.isDrawnRange(source, name)

  return remember(key, {
    {
      kind = "tween",
      chain = false,
      duration = durationV,
      start = endpointOf(startV, drawn),
      finish = endpointOf(finishV, drawn),
      curve = curveV,
      partial = partial,
    },
  })
end

-- the RayValue children the applier in the emitter plays. only children
-- matching this source are read, so a property and an attribute of the same
-- name never see each other's authoring, and an untagged child counts as a
-- property, matching legacySource exactly
function legacy_mods.readChildren(ref: Instance, source: string, name: string, children: { Instance }?): { any }?
  local out = {}

  for _, child in children or ref:GetChildren() do
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
    local key = `range|{name}|{text(range)}`

    return QUEUES[key]
      or remember(key, {
        { kind = "randomizer", chain = false, start = value.lit(range.Min), finish = value.lit(range.Max) },
      })
  end

  local keys = keysOf(name)
  local min = stored(ref, keys.min, map)
  local max = stored(ref, keys.max, map)

  -- the prefixed spelling is tried unless the underscore pair reads WHOLE. half
  -- of a pair says nothing on its own, and gating this on "neither half is
  -- there" would let one stray Size_Max suppress a complete MinSize and MaxSize,
  -- which is the spelling every shockwave in the wild actually carries
  if min == nil or max == nil then
    min = stored(ref, keys.lowest, map)
    max = stored(ref, keys.highest, map)
  end

  -- half a pair cannot say what the other half was, and that default belongs to
  -- the effect. the same reason readQuad refuses to speak for a half quad
  if min == nil or max == nil then
    return nil
  end

  local key = `pair|{name}|{text(min)}|{text(max)}`

  return QUEUES[key]
    or remember(key, {
      { kind = "randomizer", chain = false, start = value.lit(min), finish = value.lit(max), perComponent = true },
    })
end

-- a curve authored with neither end of its quad. it eases whatever ramp the
-- effect would have run by default, so both halves are left for mods.track to
-- fill; it says nothing about a constant knob, which mods.track decides
function legacy_mods.readCurve(ref: Instance, _source: string, name: string, map: { [string]: any }?): { any }?
  local keys = keysOf(name)
  local curveV = curveOf(legacy_mods.alias(ref, keys.curve, nil, map))

  if curveV == nil then
    return nil
  end

  local durationRaw = legacy_mods.alias(ref, keys.duration, nil, map)
  local span = legacy_mods.spanOf(ref, name)
  local key = `curve|{name}|{text(curveV)}|{text(durationRaw)}|{text(span)}`

  return QUEUES[key]
    or remember(key, {
      {
        kind = "tween",
        chain = false,
        duration = durationOf(durationRaw) or span,
        curve = curveV,
        partial = "both",
      },
    })
end

-- range last: it is the broadest of the three shapes, matching on a single
-- attribute named exactly for the row, so it must not shadow a quad or a
-- RayValue child that says something more specific. the curve-only shape
-- trails even range, because a curve with no value behind it is the least
-- specific thing an author can have left. written here rather than inside the
-- pcall below, so a read builds no closure to call
local function readShapes(
  ref: Instance,
  source: string,
  name: string,
  map: { [string]: any }?,
  children: { Instance }?
): { any }?
  return legacy_mods.readQuad(ref, source, name, map)
    or legacy_mods.readChildren(ref, source, name, children)
    or legacy_mods.readRange(ref, source, name, map)
    or legacy_mods.readCurve(ref, source, name, map)
end

-- children is the one list of the instance's children a caller reading several
-- rows off the same instance already holds. left out, every row takes its own
function legacy_mods.read(
  ref: Instance,
  source: string,
  name: string,
  map: { [string]: any }?,
  children: { Instance }?
): { any }?
  local ok, result = pcall(readShapes, ref, source, name, map, children)

  if not ok then
    logger.warn(`failed to read legacy modifiers for {name} with error: {result}`)
    return nil
  end

  return result
end

return legacy_mods
