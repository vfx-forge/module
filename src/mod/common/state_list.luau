const color = require("@mod/color/color")
const curve = require("@mod/curve")
const curves = require("@mod/curves")
const value_curve = require("@mod/value_curve")

export type Surface = {
  color: Color3?,
  emissiveStrength: number?,
  emissiveTint: Color3?,
  alphaMode: string?,
  easing: string?,
}

export type DecalState = {
  color: Color3?,
  transparency: number?,
  uvOffset: Vector2?,
  uvScale: Vector2?,
  rotation: number?,
  zIndex: number?,
  glowStrength: number?,
  emissiveStrength: number?,
  emissiveTint: Color3?,
  easing: string?,
}

-- the other end of a row's draw: `start` nil reads the state's own value, and
-- `weight` is a curve shaping the draw, nil drawing evenly
export type Randomizer = { start: any?, finish: any, weight: string? }

export type Random = {
  state: { [string]: Randomizer }?,
  surface: { [string]: Randomizer }?,
  decals: { [string]: { [string]: Randomizer } }?,
}

-- a pose and a look relative to the template; easing is the shape of the
-- segment arriving here, spin the whole turns per template axis added on the
-- way in. a decal a state does not name, or a field it leaves nil, reads as
-- the template decal's own. the offsets add to the pose in its own frame, and
-- `random` gives each piece its own value of the fields it names
export type State = {
  time: number,
  easing: string,
  position: vector,
  rotation: vector,
  positionOffset: vector,
  rotationOffset: vector,
  spin: vector,
  size: vector,
  color: Color3,
  transparency: number,
  reflectance: number,
  material: string,
  materialVariant: string,
  vertexColor: vector?,
  surface: Surface?,
  decals: { [string]: DecalState },
  random: Random?,
}

export type List = { State }

-- what a mesh's rows read over its life. `ends` says a modifier moves that
-- source, so its two ends are states of their own; `times` are the key
-- times of a card's own rows
export type SeedRows = {
  size: value_curve.Curve,
  transparency: value_curve.Curve,
  color: ColorSequence,
  color0: Color3,
  material: string,
  materialVariant: string,
  reflectance: number,
  surface: { at: (t: number) -> Surface, ends: boolean?, times: { number }? }?,
  decals: { [string]: { at: (t: number) -> DecalState, ends: boolean, times: { number }? } },
  ends: boolean,
}

type Field = { name: string, kind: string, rest: any, optional: boolean?, sparse: boolean? }

const VERSION = 2

-- 32 states with 8 decals and a surface, every field of every card set,
-- encode to 21154 bytes as version 1, 655 a state and the strings once; with
-- the offsets set and a randomizer of both ends and a weight on every field
-- that takes one, to 73666, 2296 a state
const MAX = 32

-- key times closer than this read as one state
const EPSILON = 1e-4

-- how near a segment's handles must sit to a preset's to read as it
const MATCH = 1e-3

-- the largest magnitude an f32 holds; anything past it is stored as inf
const F32_MAX = 3.4028234663852886e38

const LINEAR = curves.linear()

-- a state's own fields in the order they are stored. one is written only when
-- it differs from its rest; one with no rest is always written, unless it is
-- optional and nil. a sparse one is left out of the plain form at its rest
const STATE: { Field } = {
  { name = "time", kind = "time" },
  { name = "easing", kind = "easing", rest = LINEAR },
  { name = "position", kind = "vector", rest = vector.zero },
  { name = "rotation", kind = "vector", rest = vector.zero },
  { name = "spin", kind = "vector", rest = vector.zero },
  { name = "size", kind = "vector", rest = vector.one },
  { name = "color", kind = "Color3" },
  { name = "transparency", kind = "number", rest = 0 },
  { name = "reflectance", kind = "number", rest = 0 },
  { name = "material", kind = "string" },
  { name = "materialVariant", kind = "string", rest = "" },
  { name = "vertexColor", kind = "vector", optional = true },
  { name = "positionOffset", kind = "vector", rest = vector.zero, sparse = true },
  { name = "rotationOffset", kind = "vector", rest = vector.zero, sparse = true },
}

-- the state fields version 1 stored, before the offsets
const STATE_V1 = table.move(STATE, 1, 12, 1, {})

const SURFACE: { Field } = {
  { name = "color", kind = "Color3", optional = true },
  { name = "emissiveStrength", kind = "number", optional = true },
  { name = "emissiveTint", kind = "Color3", optional = true },
  { name = "alphaMode", kind = "string", optional = true },
  { name = "easing", kind = "easing", optional = true },
}

const DECAL: { Field } = {
  { name = "color", kind = "Color3", optional = true },
  { name = "transparency", kind = "number", optional = true },
  { name = "uvOffset", kind = "Vector2", optional = true },
  { name = "uvScale", kind = "Vector2", optional = true },
  { name = "rotation", kind = "number", optional = true },
  { name = "zIndex", kind = "integer", optional = true },
  { name = "glowStrength", kind = "number", optional = true },
  { name = "emissiveStrength", kind = "number", optional = true },
  { name = "emissiveTint", kind = "Color3", optional = true },
  { name = "easing", kind = "easing", optional = true },
}

-- the fields each card takes a randomizer on, in the order they are stored
const RANDOMIZABLE = table.freeze({
  state = table.freeze({
    "positionOffset",
    "rotationOffset",
    "spin",
    "size",
    "color",
    "transparency",
    "reflectance",
    "vertexColor",
  }),
  surface = table.freeze({ "color", "emissiveStrength", "emissiveTint" }),
  decal = table.freeze({
    "color",
    "transparency",
    "uvOffset",
    "uvScale",
    "rotation",
    "glowStrength",
    "emissiveStrength",
    "emissiveTint",
  }),
})

-- the cards as a randomizer stores them, from 0
const CARDS = { "state", "surface", "decal" }

-- per card, each randomizable field by name and its place in RANDOMIZABLE
const RANDOM_FIELDS: { [string]: { [string]: Field } } = {}
const RANDOM_SLOTS: { [string]: { [string]: number } } = {}

for card, fields in { state = STATE, surface = SURFACE, decal = DECAL } do
  const byName = {}
  const slots = {}

  for _, field in fields do
    byName[field.name] = field
  end

  for slot, name in RANDOMIZABLE[card] do
    slots[name] = slot
  end

  RANDOM_FIELDS[card] = byName
  RANDOM_SLOTS[card] = slots
end

-- what a version stores of a state: its fields, then the mask bits past them
-- saying a surface and a randomizer block follow
type Layout = { fields: { Field }, surface: number, random: number, extra: number }

const LAYOUTS: { [number]: Layout } = {
  [1] = { fields = STATE_V1, surface = bit32.lshift(1, #STATE_V1), random = 0, extra = 1 },
  [2] = { fields = STATE, surface = bit32.lshift(1, #STATE), random = bit32.lshift(1, #STATE + 1), extra = 2 },
}

const WIDTH = { time = 4, number = 4, integer = 4, vector = 12, Color3 = 12, Vector2 = 8, string = 2, easing = 2 }

-- the most bytes one randomizer takes: card, decal name, field, flags, two
-- ends and a weight
const RANDOMIZER_WIDEST = 1 + 2 + 1 + 1 + 12 + 12 + 2

-- a randomizer's flags: its start is stored, its weight is stored
const START_FLAG = 1
const WEIGHT_FLAG = 2

-- the most bytes a record of these fields takes, its mask included
const function widest(fields: { Field }, mask: number)
  local size = mask

  for _, field in fields do
    size += WIDTH[field.kind]
  end

  return size
end

const STATE_WIDEST = widest(STATE, 2)
const SURFACE_WIDEST = widest(SURFACE, 1)
const DECAL_WIDEST = widest(DECAL, 2)

-- the metatable a list this module made carries, so `is` tells one from any
-- other table
const List = table.freeze({})

const PRESET_NAMES: { [string]: string } = {}

for name, bytes in curves.PRESETS do
  PRESET_NAMES[bytes] = name
end

const common = {}

common.MAX = MAX
common.VERSION = VERSION
common.RANDOMIZABLE = RANDOMIZABLE
common.EMPTY = table.freeze(setmetatable({}, List)) :: List

const function finite(v: any)
  return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

-- a number an f32 holds, short of its rounding
const function storable(v: any)
  return finite(v) and math.abs(v) <= F32_MAX
end

-- a serialized curve path: an anchor every 24 bytes, two anchors at least
const function isPath(s: string)
  return #s >= 48 and #s % 24 == 0
end

const function mark(list: { State }): List
  return setmetatable(list, List) :: any
end

function common.is(v: any)
  return type(v) == "table" and getmetatable(v) == List
end

type Writer = { buf: buffer, at: number, strings: { string }, index: { [string]: number } }

const function stringIndex(w: Writer, s: string)
  const known = w.index[s]

  if known ~= nil then
    return known
  end

  table.insert(w.strings, s)
  w.index[s] = #w.strings - 1

  return #w.strings - 1
end

-- a vector's axes in either of the engine's spellings of one
const function axes(v: any): (number, number, number)
  if typeof(v) == "Vector3" then
    return v.X, v.Y, v.Z
  end

  return v.x, v.y, v.z
end

-- why a value of a field's kind would encode to a string no decode reads
-- back, or nil when it is one a list can hold
const function unstorable(kind: string, v: any): string?
  if kind == "time" then
    if not storable(v) or v < 0 or v > 1 then
      return "is a number from 0 to 1"
    end

    return nil
  end

  if kind == "number" then
    return if storable(v) then nil else "is a finite number within the f32 range"
  end

  if kind == "integer" then
    if not finite(v) or v % 1 ~= 0 or math.abs(v) > 2 ^ 31 - 1 then
      return "is a whole number"
    end

    return nil
  end

  if kind == "string" or kind == "easing" then
    if type(v) ~= "string" or #v > 65535 then
      return "is a string of at most 65535 bytes"
    end

    return if kind == "easing" and not isPath(v) then "is a curve path" else nil
  end

  const t = typeof(v)

  if kind == "vector" and (t == "vector" or t == "Vector3") then
    const x, y, z = axes(v)

    return if storable(x) and storable(y) and storable(z) then nil else "has an axis no f32 holds"
  end

  if kind == "Color3" and t == "Color3" then
    return if storable(v.R) and storable(v.G) and storable(v.B) then nil else "has a channel no f32 holds"
  end

  if kind == "Vector2" and t == "Vector2" then
    return if storable(v.X) and storable(v.Y) then nil else "has an axis no f32 holds"
  end

  return `is a {kind}`
end

const function writeValue(w: Writer, kind: string, v: any)
  const buf, at = w.buf, w.at

  if kind == "time" or kind == "number" then
    buffer.writef32(buf, at, v)
  elseif kind == "integer" then
    buffer.writei32(buf, at, v)
  elseif kind == "vector" then
    const x, y, z = axes(v)

    buffer.writef32(buf, at, x)
    buffer.writef32(buf, at + 4, y)
    buffer.writef32(buf, at + 8, z)
  elseif kind == "Color3" then
    buffer.writef32(buf, at, v.R)
    buffer.writef32(buf, at + 4, v.G)
    buffer.writef32(buf, at + 8, v.B)
  elseif kind == "Vector2" then
    buffer.writef32(buf, at, v.X)
    buffer.writef32(buf, at + 4, v.Y)
  else
    buffer.writeu16(buf, at, stringIndex(w, v))
  end

  w.at += WIDTH[kind]
end

-- a mask of the fields written, then each of them in order; `extra` is ored
-- into the mask. answers why the record cannot be stored, when it cannot
const function writeRecord(
  w: Writer,
  fields: { Field },
  record: any,
  maskSize: number,
  extra: number,
  where: string
): string?
  if type(record) ~= "table" then
    return `{where} is no table`
  end

  const maskAt = w.at
  local mask = extra

  w.at += maskSize

  for i, field in fields do
    const v = record[field.name]

    if v == nil and field.rest == nil and not field.optional then
      return `{where} has no {field.name}`
    end

    if v == nil or (field.rest ~= nil and v == field.rest) then
      continue
    end

    const problem = unstorable(field.kind, v)

    if problem ~= nil then
      return `{where}: {field.name} {problem}`
    end

    mask = bit32.bor(mask, bit32.lshift(1, i - 1))
    writeValue(w, field.kind, v)
  end

  if maskSize == 1 then
    buffer.writeu8(w.buf, maskAt, mask)
  else
    buffer.writeu16(w.buf, maskAt, mask)
  end

  return nil
end

const function sortedNames(decals: { [string]: any })
  const names = {}

  for name in decals do
    table.insert(names, name)
  end

  table.sort(names)

  return names
end

type Entry = { card: number, decal: string?, slot: number, kind: string, randomizer: Randomizer }

-- the card's own record a randomizer of it reads, nil when the state has none
const function holder(state: any, card: string, decal: string?): any
  if card == "state" then
    return state
  end

  if card == "surface" then
    return state.surface
  end

  return if type(state.decals) == "table" then state.decals[decal] else nil
end

-- the randomizers of one card in stored order, appended to `entries`, or why
-- one cannot be stored. a field the state leaves unset takes none
const function addCard(entries: { Entry }, state: any, card: number, decal: string?, given: any, where: string): string?
  const name = CARDS[card + 1]
  const fields = RANDOM_FIELDS[name]
  const own = holder(state, name, decal)

  if type(given) ~= "table" then
    return `{where} is no table`
  end

  for key in given do
    if RANDOM_SLOTS[name][key] == nil then
      return `{where}: {tostring(key)} takes no randomizer`
    end
  end

  for slot, key in RANDOMIZABLE[name] do
    const randomizer = given[key]
    const field = fields[key]

    if randomizer == nil then
      continue
    end

    if own == nil or (own[key] == nil and field.rest == nil) then
      return `{where}: {key} is randomized but the state leaves it unset`
    end

    if type(randomizer) ~= "table" then
      return `{where}: {key} is no table`
    end

    if randomizer.finish == nil then
      return `{where}: {key} has no finish`
    end

    const problem = (if randomizer.start ~= nil then unstorable(field.kind, randomizer.start) else nil)
      or unstorable(field.kind, randomizer.finish)
      or (if randomizer.weight ~= nil then unstorable("easing", randomizer.weight) else nil)

    if problem ~= nil then
      return `{where}: {key} randomizer {problem}`
    end

    table.insert(entries, { card = card, decal = decal, slot = slot, kind = field.kind, randomizer = randomizer })
  end

  return nil
end

-- a state's randomizers in the order they are stored: the state card, the
-- surface, then each decal by name, every card in RANDOMIZABLE's order
const function entriesOf(state: any, where: string): ({ Entry }?, string?)
  const random = state.random
  const entries = {}

  if random == nil then
    return entries, nil
  end

  if type(random) ~= "table" then
    return nil, `{where}: random is no table`
  end

  for key in random do
    if key ~= "state" and key ~= "surface" and key ~= "decals" then
      return nil, `{where}: random has no card {tostring(key)}`
    end
  end

  for card, key in { "state", "surface" } do
    if random[key] == nil then
      continue
    end

    const problem = addCard(entries, state, card - 1, nil, random[key], `{where} random {key}`)

    if problem ~= nil then
      return nil, problem
    end
  end

  const decals = random.decals

  if decals == nil then
    return entries, nil
  end

  if type(decals) ~= "table" then
    return nil, `{where}: random decals is no table`
  end

  for name in decals do
    if type(name) ~= "string" then
      return nil, `{where}: random decals is a table by decal name`
    end
  end

  for _, name in sortedNames(decals) do
    const problem = addCard(entries, state, 2, name, decals[name], `{where} random decal {name}`)

    if problem ~= nil then
      return nil, problem
    end
  end

  return entries, nil
end

const function writeEntries(w: Writer, entries: { Entry })
  buffer.writeu16(w.buf, w.at, #entries)
  w.at += 2

  for _, entry in entries do
    const randomizer = entry.randomizer
    local flags = 0

    if randomizer.start ~= nil then
      flags = bit32.bor(flags, START_FLAG)
    end

    if randomizer.weight ~= nil then
      flags = bit32.bor(flags, WEIGHT_FLAG)
    end

    buffer.writeu8(w.buf, w.at, entry.card)
    w.at += 1

    if entry.decal ~= nil then
      writeValue(w, "string", entry.decal)
    end

    buffer.writeu8(w.buf, w.at, entry.slot)
    buffer.writeu8(w.buf, w.at + 1, flags)
    w.at += 2

    if randomizer.start ~= nil then
      writeValue(w, entry.kind, randomizer.start)
    end

    writeValue(w, entry.kind, randomizer.finish)

    if randomizer.weight ~= nil then
      writeValue(w, "easing", randomizer.weight)
    end
  end
end

-- whether a value moves a pose off its rest, which version 1 cannot store
const function moved(v: any)
  return v ~= nil and v ~= vector.zero
end

-- version, the strings every state indexes into, the state count, then each
-- state's fields, its surface, its decals by name and its randomizers. names
-- are sorted, so equal lists encode to equal strings. a list with no offset
-- and no randomizer is written as version 1, byte for byte as before either
-- was stored. a value the format cannot hold raises, since the string would
-- decode to nil and lose every state
function common.encode(list: List): string
  if #list > 65535 then
    error(`a list holds at most 65535 states to encode, not {#list}`, 2)
  end

  local bound = 0
  local version = 1
  const plans = table.create(#list)

  for i, state in list do
    const decals = state.decals or {}
    const entries, problem = entriesOf(state, `state {i}`)
    local count = 0

    if entries == nil then
      error(problem, 2)
    end

    if #entries > 65535 then
      error(`state {i} has more than 65535 randomizers`, 2)
    end

    for _ in decals do
      count += 1
    end

    if #entries > 0 or moved(state.positionOffset) or moved(state.rotationOffset) then
      version = VERSION
    end

    plans[i] = entries
    bound += STATE_WIDEST + SURFACE_WIDEST + 2 + count * (2 + DECAL_WIDEST) + 2 + #entries * RANDOMIZER_WIDEST
  end

  const layout = LAYOUTS[version]
  const w: Writer = { buf = buffer.create(bound), at = 0, strings = {}, index = {} }

  for i, state in list do
    const where = `state {i}`
    const decals = state.decals or {}
    const names = sortedNames(decals)
    const entries = plans[i]
    const extra =
      bit32.bor(if state.surface ~= nil then layout.surface else 0, if #entries > 0 then layout.random else 0)
    local problem = writeRecord(w, layout.fields, state, 2, extra, where)

    if problem == nil and state.surface ~= nil then
      problem = writeRecord(w, SURFACE, state.surface, 1, 0, `{where} surface`)
    end

    if problem == nil and #names > 65535 then
      problem = `{where} has more than 65535 decals`
    end

    if problem ~= nil then
      error(problem, 2)
    end

    buffer.writeu16(w.buf, w.at, #names)
    w.at += 2

    for _, name in names do
      if type(name) ~= "string" or name == "" or #name > 65535 then
        error(`{where}: a decal name is a string of 1 to 65535 bytes`, 2)
      end

      buffer.writeu16(w.buf, w.at, stringIndex(w, name))
      w.at += 2

      const wrong = writeRecord(w, DECAL, decals[name], 2, 0, `{where} decal {name}`)

      if wrong ~= nil then
        error(wrong, 2)
      end
    end

    if #entries > 0 then
      writeEntries(w, entries)
    end
  end

  if #w.strings > 65535 then
    error(`a list holds at most 65535 distinct strings to encode, not {#w.strings}`, 2)
  end

  local head = 3

  for _, s in w.strings do
    head += 2 + #s
  end

  const out = buffer.create(head + 2 + w.at)

  buffer.writeu8(out, 0, version)
  buffer.writeu16(out, 1, #w.strings)

  local at = 3

  for _, s in w.strings do
    buffer.writeu16(out, at, #s)
    buffer.writestring(out, at + 2, s)
    at += 2 + #s
  end

  buffer.writeu16(out, at, #list)
  buffer.copy(out, at + 2, w.buf, 0, w.at)

  return buffer.tostring(out)
end

type Reader = { buf: buffer, at: number, size: number, strings: { string } }

-- the value at the reader, or nil when it is out of bounds or no value of
-- its kind
const function readValue(r: Reader, kind: string): any
  const width = WIDTH[kind]
  const buf, at = r.buf, r.at

  if at + width > r.size then
    return nil
  end

  r.at += width

  if kind == "time" or kind == "number" then
    const v = buffer.readf32(buf, at)

    if not finite(v) or (kind == "time" and (v < 0 or v > 1)) then
      return nil
    end

    return v
  end

  if kind == "integer" then
    return buffer.readi32(buf, at)
  end

  if kind == "string" or kind == "easing" then
    const s = r.strings[buffer.readu16(buf, at) + 1]

    if s == nil or (kind == "easing" and not isPath(s)) then
      return nil
    end

    return s
  end

  const x, y = buffer.readf32(buf, at), buffer.readf32(buf, at + 4)

  if kind == "Vector2" then
    return if finite(x) and finite(y) then Vector2.new(x, y) else nil
  end

  const z = buffer.readf32(buf, at + 8)

  if not (finite(x) and finite(y) and finite(z)) then
    return nil
  end

  return if kind == "vector" then vector.create(x, y, z) else Color3.new(x, y, z)
end

-- a record and its mask, or nil when it is malformed: a bit no field owns
-- past `extraBits`, a value that does not read, or a required field missing
const function readRecord(r: Reader, fields: { Field }, maskSize: number, extraBits: number): (any, number)
  if r.at + maskSize > r.size then
    return nil, 0
  end

  const mask = if maskSize == 1 then buffer.readu8(r.buf, r.at) else buffer.readu16(r.buf, r.at)

  r.at += maskSize

  if bit32.rshift(mask, #fields + extraBits) ~= 0 then
    return nil, 0
  end

  const record = {}

  for i, field in fields do
    if bit32.extract(mask, i - 1) == 0 then
      if field.rest == nil and not field.optional then
        return nil, 0
      end

      record[field.name] = field.rest
      continue
    end

    const v = readValue(r, field.kind)

    if v == nil then
      return nil, 0
    end

    record[field.name] = v
  end

  return record, mask
end

type Place = { card: number, decal: string?, slot: number }

-- whether a randomizer is stored after the one before it, which keeps one
-- order for equal lists and refuses the same randomizer twice
const function after(place: Place, last: Place?)
  if last == nil then
    return true
  end

  if place.card ~= last.card then
    return place.card > last.card
  end

  if place.decal ~= last.decal then
    return (place.decal :: string) > (last.decal :: string)
  end

  return place.slot > last.slot
end

-- the randomizers a state's block holds, or nil when one is malformed, out of
-- order, or names a field the state leaves unset
const function readRandom(r: Reader, state: any): Random?
  if r.at + 2 > r.size then
    return nil
  end

  const count = buffer.readu16(r.buf, r.at)
  const random: any = {}
  local last: Place? = nil

  r.at += 2

  if count == 0 then
    return nil
  end

  for _ = 1, count do
    if r.at + 1 > r.size then
      return nil
    end

    const card = buffer.readu8(r.buf, r.at)
    const name = CARDS[card + 1]

    r.at += 1

    if name == nil then
      return nil
    end

    const decal = if card == 2 then readValue(r, "string") else nil

    if (card == 2 and decal == nil) or r.at + 2 > r.size then
      return nil
    end

    const slot, flags = buffer.readu8(r.buf, r.at), buffer.readu8(r.buf, r.at + 1)
    const key = RANDOMIZABLE[name][slot]
    const place = { card = card, decal = decal, slot = slot }

    r.at += 2

    if key == nil or bit32.rshift(flags, 2) ~= 0 or not after(place, last) then
      return nil
    end

    const own = holder(state, name, decal)

    if own == nil or own[key] == nil then
      return nil
    end

    const kind = RANDOM_FIELDS[name][key].kind
    const started = bit32.band(flags, START_FLAG) ~= 0
    const weighted = bit32.band(flags, WEIGHT_FLAG) ~= 0
    const start = if started then readValue(r, kind) else nil

    if started and start == nil then
      return nil
    end

    const finish = readValue(r, kind)
    const weight = if weighted then readValue(r, "easing") else nil

    if finish == nil or (weighted and weight == nil) then
      return nil
    end

    local into = nil

    if card == 2 then
      random.decals = random.decals or {}
      random.decals[decal] = random.decals[decal] or {}
      into = random.decals[decal]
    else
      random[name] = random[name] or {}
      into = random[name]
    end

    into[key] = { start = start, finish = finish, weight = weight }
    last = place
  end

  return random
end

const function readState(r: Reader, layout: Layout): State?
  const state, mask = readRecord(r, layout.fields, 2, layout.extra)

  if state == nil then
    return nil
  end

  -- a field this version does not store reads as its rest
  for i = #layout.fields + 1, #STATE do
    state[STATE[i].name] = STATE[i].rest
  end

  if bit32.band(mask, layout.surface) ~= 0 then
    state.surface = readRecord(r, SURFACE, 1, 0)

    if state.surface == nil then
      return nil
    end
  end

  if r.at + 2 > r.size then
    return nil
  end

  const count = buffer.readu16(r.buf, r.at)
  const decals = {}

  r.at += 2

  for _ = 1, count do
    const name = readValue(r, "string")

    if name == nil or name == "" or decals[name] ~= nil then
      return nil
    end

    const decal = readRecord(r, DECAL, 2, 0)

    if decal == nil then
      return nil
    end

    decals[name] = decal
  end

  state.decals = decals

  if bit32.band(mask, layout.random) ~= 0 then
    state.random = readRandom(r, state)

    if state.random == nil then
      return nil
    end
  end

  return state
end

-- states at one time keep their stored order, which table.sort alone would
-- not promise
const function byTime(states: { State }): { State }
  const order = table.create(#states)

  for i = 1, #states do
    order[i] = i
  end

  table.sort(order, function(a: number, b: number)
    const ta, tb = states[a].time, states[b].time

    if ta ~= tb then
      return ta < tb
    end

    return a < b
  end)

  const sorted = table.create(#states)

  for i, from in order do
    sorted[i] = states[from]
  end

  return sorted
end

-- the list a string holds, sorted by time and cut to the first MAX, or nil
-- for anything that is not exactly one list of a version this module reads
function common.decode(raw: string): List?
  if type(raw) ~= "string" or #raw < 5 then
    return nil
  end

  const buf = buffer.fromstring(raw)
  const size = #raw
  const layout = LAYOUTS[buffer.readu8(buf, 0)]

  if layout == nil then
    return nil
  end

  const strings = {}
  local at = 3

  for i = 1, buffer.readu16(buf, 1) do
    if at + 2 > size then
      return nil
    end

    const length = buffer.readu16(buf, at)

    if at + 2 + length > size then
      return nil
    end

    strings[i] = buffer.readstring(buf, at + 2, length)
    at += 2 + length
  end

  if at + 2 > size then
    return nil
  end

  const count = buffer.readu16(buf, at)
  const r: Reader = { buf = buf, at = at + 2, size = size, strings = strings }
  const states = table.create(count)

  for i = 1, count do
    const state = readState(r, layout)

    if state == nil then
      return nil
    end

    states[i] = state
  end

  if r.at ~= size then
    return nil
  end

  const sorted = byTime(states)

  for i = MAX + 1, #sorted do
    sorted[i] = nil
  end

  return mark(sorted)
end

const function easingOut(s: string): any
  const name = PRESET_NAMES[s]

  if name ~= nil then
    return name
  end

  const buf = buffer.fromstring(s)
  const numbers = table.create(#s // 4)

  for i = 0, #s // 4 - 1 do
    numbers[i + 1] = buffer.readf32(buf, i * 4)
  end

  return numbers
end

const function valueOut(kind: string, v: any): any
  if kind == "vector" then
    return { axes(v) }
  end

  if kind == "Color3" then
    return { v.R, v.G, v.B }
  end

  if kind == "Vector2" then
    return { v.X, v.Y }
  end

  if kind == "easing" then
    return easingOut(v)
  end

  return v
end

const function recordOut(fields: { Field }, record: any)
  const out = {}

  for _, field in fields do
    const v = record[field.name]

    if v ~= nil and not (field.sparse and v == field.rest) then
      out[field.name] = valueOut(field.kind, v)
    end
  end

  return out
end

const function cardOut(card: string, given: { [string]: Randomizer })
  const out = {}

  for key, randomizer in given do
    const kind = RANDOM_FIELDS[card][key].kind

    out[key] = {
      start = if randomizer.start ~= nil then valueOut(kind, randomizer.start) else nil,
      finish = valueOut(kind, randomizer.finish),
      weight = if randomizer.weight ~= nil then valueOut("easing", randomizer.weight) else nil,
    }
  end

  return out
end

const function randomOut(random: Random)
  const out: any = {}

  if random.state ~= nil then
    out.state = cardOut("state", random.state)
  end

  if random.surface ~= nil then
    out.surface = cardOut("surface", random.surface)
  end

  if random.decals ~= nil then
    out.decals = {}

    for name, given in random.decals do
      out.decals[name] = cardOut("decal", given)
    end
  end

  return out
end

-- the list as numbers, strings, arrays and objects: vectors and colors as
-- arrays, an easing or a weight as a preset's name or the f32 numbers of its
-- path, y down as stored, decals as an object by name. the offsets and
-- `random` are left out when unset
function common.toPlain(list: List): { any }
  const out = table.create(#list)

  for i, state in list do
    const plain = recordOut(STATE, state)
    const decals = {}

    if state.surface ~= nil then
      plain.surface = recordOut(SURFACE, state.surface)
    end

    for name, decal in state.decals do
      decals[name] = recordOut(DECAL, decal)
    end

    if state.random ~= nil then
      plain.random = randomOut(state.random)
    end

    plain.decals = decals
    out[i] = plain
  end

  return out
end

const function numbers(v: any, count: number)
  if type(v) ~= "table" or #v ~= count then
    return false
  end

  for i = 1, count do
    if not storable(v[i]) then
      return false
    end
  end

  return true
end

const function easingIn(v: any): (string?, string?)
  if type(v) == "string" then
    const preset = curves.PRESETS[v]

    if preset ~= nil then
      return preset, nil
    end

    if isPath(v) then
      return v, nil
    end
  end

  if type(v) == "table" and #v >= 12 and #v % 6 == 0 and numbers(v, #v) then
    const buf = buffer.create(#v * 4)

    for i, n in v do
      buffer.writef32(buf, (i - 1) * 4, n)
    end

    return buffer.tostring(buf), nil
  end

  return nil, "is linear, easeIn, easeOut, easeInOut or the numbers of a curve path"
end

-- a plain value as a field's kind, or nil and what it should be
const function valueIn(kind: string, v: any): (any, string?)
  if kind == "time" then
    if not storable(v) or v < 0 or v > 1 then
      return nil, "is a number from 0 to 1"
    end

    return v, nil
  end

  if kind == "number" then
    return if storable(v) then v else nil, "is a finite number within the f32 range"
  end

  if kind == "integer" then
    if not finite(v) or v % 1 ~= 0 or math.abs(v) > 2 ^ 31 - 1 then
      return nil, "is a whole number"
    end

    return v, nil
  end

  if kind == "string" then
    return if type(v) == "string" and #v < 65536 then v else nil, "is a string"
  end

  if kind == "easing" then
    return easingIn(v)
  end

  if kind == "Vector2" then
    return if numbers(v, 2) then Vector2.new(v[1], v[2]) else nil, "is [x, y]"
  end

  if not numbers(v, 3) then
    return nil, if kind == "vector" then "is [x, y, z]" else "is [r, g, b]"
  end

  return if kind == "vector" then vector.create(v[1], v[2], v[3]) else Color3.new(v[1], v[2], v[3]), nil
end

const function recordIn(fields: { Field }, v: any, where: string, extra: { [string]: boolean }?): (any, string?)
  if type(v) ~= "table" then
    return nil, `{where} is an object`
  end

  for key in v do
    const known = extra ~= nil and extra[key]

    if known then
      continue
    end

    local found = false

    for _, field in fields do
      if field.name == key then
        found = true
        break
      end
    end

    if not found then
      return nil, `{where} has no field {tostring(key)}`
    end
  end

  const record = {}

  for _, field in fields do
    const given = v[field.name]

    if given == nil then
      if field.rest == nil and not field.optional then
        return nil, `{where}: {field.name} is missing`
      end

      record[field.name] = field.rest
      continue
    end

    const value, problem = valueIn(field.kind, given)

    if value == nil then
      return nil, `{where}: {field.name} {problem}`
    end

    record[field.name] = value
  end

  return record, nil
end

const RANDOMIZER_KEYS = { start = true, finish = true, weight = true }

const function randomizerIn(kind: string, v: any, where: string): (Randomizer?, string?)
  if type(v) ~= "table" then
    return nil, `{where} is an object`
  end

  for key in v do
    if not RANDOMIZER_KEYS[key] then
      return nil, `{where} has no field {tostring(key)}`
    end
  end

  if v.finish == nil then
    return nil, `{where}: finish is missing`
  end

  local start = nil

  if v.start ~= nil then
    const read, problem = valueIn(kind, v.start)

    if read == nil then
      return nil, `{where}: start {problem}`
    end

    start = read
  end

  const finish, problem = valueIn(kind, v.finish)

  if finish == nil then
    return nil, `{where}: finish {problem}`
  end

  local weight = nil

  if v.weight ~= nil then
    const read, wrong = easingIn(v.weight)

    if read == nil then
      return nil, `{where}: weight {wrong}`
    end

    weight = read
  end

  return { start = start, finish = finish, weight = weight }, nil
end

-- a card's randomizers from their plain form, nil when it holds none
const function cardIn(card: string, v: any, where: string): ({ [string]: Randomizer }?, string?)
  if type(v) ~= "table" then
    return nil, `{where} is an object by field`
  end

  const out = {}

  for key, given in v do
    const field = RANDOM_FIELDS[card][key]

    if RANDOM_SLOTS[card][key] == nil then
      return nil, `{where}: {tostring(key)} takes no randomizer`
    end

    const randomizer, problem = randomizerIn(field.kind, given, `{where} {key}`)

    if randomizer == nil then
      return nil, problem
    end

    out[key] = randomizer
  end

  return if next(out) ~= nil then out else nil, nil
end

-- a state's randomizers from their plain form, empty cards dropped, so one
-- naming none reads as nil
const function randomIn(v: any, where: string): (Random?, string?)
  if type(v) ~= "table" then
    return nil, `{where}: random is an object by card`
  end

  const random: any = {}

  for key, given in v do
    if key ~= "state" and key ~= "surface" and key ~= "decals" then
      return nil, `{where}: random has no card {tostring(key)}`
    end

    if key == "decals" then
      continue
    end

    const card, problem = cardIn(key, given, `{where} random {key}`)

    if problem ~= nil then
      return nil, problem
    end

    random[key] = card
  end

  if v.decals ~= nil and type(v.decals) ~= "table" then
    return nil, `{where}: random decals is an object by decal name`
  end

  for name, given in v.decals or {} do
    if type(name) ~= "string" then
      return nil, `{where}: random decals is an object by decal name`
    end

    const card, problem = cardIn("decal", given, `{where} random decal {name}`)

    if problem ~= nil then
      return nil, problem
    end

    random.decals = random.decals or {}
    random.decals[name] = card
  end

  return if next(random) ~= nil then random else nil, nil
end

const STATE_EXTRA = { surface = true, decals = true, random = true }

-- a list from its plain form, sorted by time, or nil and the field that is
-- wrong. a field with a rest may be left out and reads as it
function common.fromPlain(v: any): (List?, string?)
  if type(v) ~= "table" then
    return nil, "states are a list"
  end

  local last = 0

  for key in v do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      return nil, "states are a list"
    end

    last = math.max(last, key)
  end

  if last > MAX then
    return nil, `a mesh holds at most {MAX} states`
  end

  const states = table.create(last)

  for i = 1, last do
    const plain = v[i]

    if plain == nil then
      return nil, `state {i} is missing from the list`
    end

    const where = `state {i}`
    const state, problem = recordIn(STATE, plain, where, STATE_EXTRA)

    if state == nil then
      return nil, problem
    end

    if plain.surface ~= nil then
      const surface, wrong = recordIn(SURFACE, plain.surface, `{where} surface`)

      if surface == nil then
        return nil, wrong
      end

      state.surface = surface
    end

    if plain.decals ~= nil and type(plain.decals) ~= "table" then
      return nil, `{where}: decals is an object by decal name`
    end

    const decals = {}

    for name, decal in plain.decals or {} do
      if type(name) ~= "string" or name == "" or #name >= 65536 then
        return nil, `{where}: decals is an object by decal name`
      end

      const read, wrong = recordIn(DECAL, decal, `{where} decal {name}`)

      if read == nil then
        return nil, wrong
      end

      decals[name] = read
    end

    state.decals = decals

    if plain.random ~= nil then
      const random, wrong = randomIn(plain.random, where)

      if wrong ~= nil then
        return nil, wrong
      end

      state.random = random
    end

    const _, unset = entriesOf(state, where)

    if unset ~= nil then
      return nil, unset
    end

    states[i] = state
  end

  return mark(byTime(states)), nil
end

const function addTimes(marks: { number }, times: { number }?)
  for _, t in times or {} do
    table.insert(marks, math.clamp(t, 0, 1))
  end
end

const function addEnds(marks: { number }, ends: boolean?)
  if ends then
    table.insert(marks, 0)
    table.insert(marks, 1)
  end
end

const function keyTimes(curve: value_curve.Curve)
  const out = table.create(#curve.keys)

  for i, k in curve.keys do
    out[i] = k.time
  end

  return out
end

-- every time a source keys or a modifier ends, a run closer than EPSILON
-- taken as its first, sorted and cut to MAX
const function timesOf(rows: SeedRows): { number }
  const marks = {}

  addEnds(marks, rows.ends)
  addTimes(marks, keyTimes(rows.size))
  addTimes(marks, keyTimes(rows.transparency))

  if rows.color ~= nil then
    for _, keypoint in rows.color.Keypoints do
      table.insert(marks, keypoint.Time)
    end
  end

  if rows.surface ~= nil then
    addEnds(marks, rows.surface.ends)
    addTimes(marks, rows.surface.times)
  end

  for _, decal in rows.decals do
    addEnds(marks, decal.ends)
    addTimes(marks, decal.times)
  end

  table.sort(marks)

  const times = {}

  for _, t in marks do
    if #times == MAX then
      break
    end

    if #times == 0 or t - times[#times] >= EPSILON then
      table.insert(times, t)
    end
  end

  return times
end

-- the first key at `time`, or the last when `last` is set, since a step
-- keys one time twice
const function keyAt(curve: value_curve.Curve, time: number, last: boolean): number?
  local found = nil

  for i, k in curve.keys do
    if math.abs(k.time - time) < EPSILON then
      found = i

      if not last then
        break
      end
    end
  end

  return found
end

-- a serialized path of one cubic from (0, 0) to (1, 1), y down as stored
const function pathOf(c1: vector, c2: vector): string
  const buf = buffer.create(48)

  buffer.writef32(buf, 4, 1)
  buffer.writef32(buf, 8, c1.x)
  buffer.writef32(buf, 12, 1 - c1.y)
  buffer.writef32(buf, 16, c2.x)
  buffer.writef32(buf, 20, 1 - c2.y)
  buffer.writef32(buf, 24, 1)

  return buffer.tostring(buf)
end

-- each preset's two inner control points, y up
const PRESET_POINTS: { [string]: { vector } } = {}

for name, bytes in curves.PRESETS do
  const points = curves.points(name)

  PRESET_POINTS[bytes] = { points[2], points[3] }
end

-- the inner control points one channel of a segment traces, over a segment
-- from 0 to 1; nil on a channel that holds its value
const function traced(from: value_curve.Key, into: value_curve.Key, c: number): (vector?, vector?)
  const width = into.time - from.time
  const change = into.value[c] - from.value[c]

  if width <= 0 or math.abs(change) < EPSILON then
    return nil, nil
  end

  const leave, enter = from.right[c], into.left[c]
  const c1 = vector.create(math.clamp(leave.x / width, 0, 1), leave.y / change, 0)
  const c2 = vector.create(math.clamp(1 + enter.x / width, 0, 1), 1 + enter.y / change, 0)

  return c1, c2
end

-- the easing of the segment from `before` to `after`, the shape every moving
-- channel keyed at both ends traces when they agree, else linear. the color
-- blends linearly and never votes
const function easingOf(rows: SeedRows, before: number, after: number): string
  local c1: vector? = nil
  local c2: vector? = nil

  for _, curve in { rows.size, rows.transparency } do
    const a, b = keyAt(curve, before, true), keyAt(curve, after, false)

    if a == nil or b ~= a + 1 then
      continue
    end

    for c = 1, curve.channels do
      const p1, p2 = traced(curve.keys[a], curve.keys[b :: number], c)

      if p1 == nil then
        continue
      end

      if c1 == nil then
        c1, c2 = p1, p2
      elseif vector.magnitude(p1 - c1) >= MATCH or vector.magnitude((p2 :: vector) - (c2 :: vector)) >= MATCH then
        return LINEAR
      end
    end
  end

  if c1 == nil or c2 == nil then
    return LINEAR
  end

  if math.abs(c1.x - c1.y) < MATCH and math.abs(c2.x - c2.y) < MATCH then
    return LINEAR
  end

  for bytes, points in PRESET_POINTS do
    if vector.magnitude(c1 - points[1]) < MATCH and vector.magnitude(c2 - points[2]) < MATCH then
      return bytes
    end
  end

  return pathOf(c1, c2)
end

-- the states a mesh's rows describe: one at each time a row keys or a
-- modifier ends, each holding what the rows read there, posed on the
-- template
function common.seed(rows: SeedRows): List
  const times = timesOf(rows)
  const list = table.create(#times)

  for i, t in times do
    const size = value_curve.at(rows.size, t)
    const decals = {}

    for name, decal in rows.decals do
      decals[name] = table.clone(decal.at(t))
    end

    list[i] = {
      time = t,
      easing = if i > 1 then easingOf(rows, times[i - 1], t) else LINEAR,
      position = vector.zero,
      rotation = vector.zero,
      positionOffset = vector.zero,
      rotationOffset = vector.zero,
      spin = vector.zero,
      size = vector.create(size[1], size[2], size[3]),
      color = if rows.color ~= nil then color.keypointsAt(rows.color.Keypoints, t) else rows.color0,
      transparency = value_curve.at(rows.transparency, t)[1],
      reflectance = rows.reflectance,
      material = rows.material,
      materialVariant = rows.materialVariant,
      surface = if rows.surface ~= nil then table.clone(rows.surface.at(t)) else nil,
      decals = decals,
    }
  end

  return mark(list)
end

-- the randomizer with both ends times `factor`
const function scaledEnds(randomizer: Randomizer, factor: number): Randomizer
  return {
    start = if randomizer.start ~= nil then randomizer.start * factor else nil,
    finish = randomizer.finish * factor,
    weight = randomizer.weight,
  }
end

-- the list with every position, position offset and size times `factor`, and
-- the ends of their randomizers, as resizing the template does; a size is a
-- factor on the template's own, which no resize scales under states. a
-- surface, the decals and every other randomizer are shared with `list`
function common.scaled(list: List, factor: number): List
  const out = table.create(#list)

  for i, state in list do
    const copy = table.clone(state)
    const random = state.random

    copy.position = state.position * factor
    copy.positionOffset = state.positionOffset * factor
    copy.size = state.size * factor

    if random ~= nil and random.state ~= nil then
      const own = table.clone(random.state)

      for _, key in { "positionOffset", "size" } do
        if own[key] ~= nil then
          own[key] = scaledEnds(own[key], factor)
        end
      end

      copy.random = table.clone(random)
      copy.random.state = own
    end

    out[i] = copy
  end

  return mark(out)
end

export type Sample = {
  cframe: CFrame,
  size: vector,
  color: Color3,
  transparency: number,
  reflectance: number,
  material: string,
  materialVariant: string,
  vertexColor: vector?,
  surface: Surface?,
  decals: { [string]: DecalState },
}

export type Rest = { surface: Surface?, decals: { [string]: DecalState } }

type Fields = { { name: string, kind: string } }

-- a kind of "switch" holds the segment's first value until the state arrives
const SURFACE_PLAY: Fields = {
  { name = "color", kind = "Color3" },
  { name = "emissiveStrength", kind = "number" },
  { name = "emissiveTint", kind = "Color3" },
  { name = "alphaMode", kind = "switch" },
}

const DECAL_PLAY: Fields = {
  { name = "color", kind = "Color3" },
  { name = "transparency", kind = "number" },
  { name = "uvOffset", kind = "Vector2" },
  { name = "uvScale", kind = "Vector2" },
  { name = "rotation", kind = "number" },
  { name = "zIndex", kind = "switch" },
  { name = "glowStrength", kind = "number" },
  { name = "emissiveStrength", kind = "number" },
  { name = "emissiveTint", kind = "Color3" },
}

-- the value `u` of the way from a to b. a side that leaves the field unset
-- reads as `rest`, or as the other side without one; both unset stays nil
const function mix(kind: string, a: any, b: any, rest: any, u: number): any
  if a == nil and b == nil then
    return nil
  end

  if a == nil then
    a = rest
  end

  if b == nil then
    b = rest
  end

  if a == nil then
    return b
  end

  if b == nil or u == 0 or kind == "switch" or a == b then
    return a
  end

  if kind == "Color3" then
    return color.blend(a, b, u)
  end

  if kind == "Vector2" then
    return a:Lerp(b, u)
  end

  return a + (b - a) * u
end

const function play(fields: Fields, out: any, a: any, b: any, rest: any, u: number)
  for _, field in fields do
    const name = field.name

    out[name] = mix(
      field.kind,
      if a ~= nil then a[name] else nil,
      if b ~= nil then b[name] else nil,
      if rest ~= nil then rest[name] else nil,
      u
    )
  end
end

-- a pose with the rotation about each axis in radians, applied in
-- CFrame.fromOrientation's order, then `turn` the same way after it
function common.pose(base: CFrame, position: vector, rotation: vector, turn: vector?): CFrame
  const posed = base
    * CFrame.new(position.x, position.y, position.z)
    * CFrame.fromOrientation(rotation.x, rotation.y, rotation.z)

  if turn == nil then
    return posed
  end

  return posed * CFrame.fromOrientation(turn.x, turn.y, turn.z)
end

-- a function writing what the list reads at `t` into `out`, built once per
-- list: it makes no table after the first call into one `out`. userdata
-- remains: a moving segment makes up to 5 (the rotation Lerp, the spin CFrame
-- when spin is not zero, the product of the two, a Vector3 and the final
-- sum), a changing Color3 about 4 (its Oklab round trip) and a changing
-- Vector2 one; a hold or an idle segment makes none. before the
-- first state and after the last it holds that state; between two, the
-- arriving state's easing shapes the way in. a surface or decal field set on
-- one side blends from `rest`'s value, or holds the side that has it
function common.sampler(list: List, rest: Rest?): (t: number, out: Sample) -> Sample
  const count = #list
  const rotations = table.create(count)
  const poses = table.create(count)
  const idle = table.create(count)
  const ease = table.create(count)
  const surfaceEase = table.create(count)
  const decalEase = table.create(count)
  const names = {}
  local hasSurface = false

  for i, state in list do
    rotations[i] = CFrame.fromOrientation(state.rotation.x, state.rotation.y, state.rotation.z)
    poses[i] = CFrame.new(state.position.x, state.position.y, state.position.z) * rotations[i]
    ease[i] = curve.sampler(state.easing)

    -- a segment into this state that neither moves nor turns the piece
    idle[i] = i > 1
      and state.spin == vector.zero
      and state.position == list[i - 1].position
      and state.rotation == list[i - 1].rotation

    const surface = state.surface

    surfaceEase[i] = if surface ~= nil and surface.easing ~= nil then curve.sampler(surface.easing) else ease[i]

    const own = {}

    for name, decal in state.decals do
      names[name] = true

      if decal.easing ~= nil then
        own[name] = curve.sampler(decal.easing)
      end
    end

    decalEase[i] = own

    if surface ~= nil then
      hasSurface = true
    end
  end

  for i = 1, count do
    for name in names do
      if decalEase[i][name] == nil then
        decalEase[i][name] = ease[i]
      end
    end
  end

  const restSurface = if rest ~= nil then rest.surface else nil
  const restDecals = if rest ~= nil then rest.decals else nil

  return function(t: number, out: Sample): Sample
    if count == 0 then
      return out
    end

    local at = 0

    for i = 1, count do
      if list[i].time > t then
        break
      end

      at = i
    end

    -- a segment runs from a to b; a hold reads one state as both ends
    const hold = at == 0 or at == count
    const ia = math.max(at, 1)
    const ib = if hold then ia else at + 1
    const a, b = list[ia], list[ib]
    local u, us, f = 0, 0, 0

    if not hold then
      f = (t - a.time) / (b.time - a.time)
      u = ease[ib](f)
      us = surfaceEase[ib](f)
    end

    local pose = poses[ia]
    local size = a.size
    local tint = a.color
    local transparency = a.transparency
    local reflectance = a.reflectance
    local vertexColor = a.vertexColor

    if not hold then
      if not idle[ib] then
        const spin = b.spin
        local turn = rotations[ia]:Lerp(rotations[ib], u)

        if spin ~= vector.zero then
          turn *= CFrame.fromOrientation(2 * math.pi * spin.x * u, 2 * math.pi * spin.y * u, 2 * math.pi * spin.z * u)
        end

        const pos = mix("vector", a.position, b.position, nil, u)

        pose = turn + Vector3.new(pos.x, pos.y, pos.z)
      end

      size = mix("vector", size, b.size, nil, u)
      tint = mix("Color3", tint, b.color, nil, u)
      transparency = mix("number", transparency, b.transparency, nil, u)
      reflectance = mix("number", reflectance, b.reflectance, nil, u)
      vertexColor = mix("vector", vertexColor, b.vertexColor, nil, u)
    end

    out.cframe = pose
    out.size = size
    out.color = tint
    out.transparency = transparency
    out.reflectance = reflectance
    out.material = a.material
    out.materialVariant = a.materialVariant
    out.vertexColor = vertexColor

    if hasSurface then
      out.surface = out.surface or {}
      play(SURFACE_PLAY, out.surface, a.surface, b.surface, restSurface, us)
    else
      out.surface = nil
    end

    const decals = out.decals or {}

    out.decals = decals

    for name in names do
      const into = decals[name] or {}

      decals[name] = into
      play(
        DECAL_PLAY,
        into,
        a.decals[name],
        b.decals[name],
        if restDecals ~= nil then restDecals[name] else nil,
        if hold then 0 else decalEase[ib][name](f)
      )
    end

    return out
  end
end

return common
