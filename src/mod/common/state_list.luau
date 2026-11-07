const color = require("@mod/color/color")
const curves = require("@mod/curves")
const logger = require("@mod/logger")
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

-- a pose and a look relative to the template; easing is the shape of the
-- segment arriving here, spin the whole turns per template axis added on the
-- way in. a decal a state does not name, or a field it leaves nil, reads as
-- the template decal's own
export type State = {
  time: number,
  easing: string,
  position: vector,
  rotation: vector,
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

type Field = { name: string, kind: string, rest: any, optional: boolean? }

const VERSION = 1

-- 32 states with 8 decals and a surface, every field of every card set,
-- encode to 21154 bytes, 655 a state and the strings once
const MAX = 32

-- key times closer than this read as one state
const EPSILON = 1e-4

-- how near a segment's handles must sit to a preset's to read as it
const MATCH = 1e-3

const LINEAR = curves.linear()

-- a state's own fields in the order they are stored. one is written only when
-- it differs from its rest; one with no rest is always written, unless it is
-- optional and nil
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
}

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

-- the bit past a state's fields that says a surface follows
const SURFACE_BIT = bit32.lshift(1, #STATE)

const WIDTH = { time = 4, number = 4, integer = 4, vector = 12, Color3 = 12, Vector2 = 8, string = 2, easing = 2 }

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
common.EMPTY = table.freeze(setmetatable({}, List)) :: List

const function finite(v: any)
  return type(v) == "number" and v == v and v > -math.huge and v < math.huge
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

const function writeValue(w: Writer, kind: string, v: any)
  const buf, at = w.buf, w.at

  if kind == "time" or kind == "number" then
    buffer.writef32(buf, at, v)
  elseif kind == "integer" then
    buffer.writei32(buf, at, v)
  elseif kind == "vector" then
    buffer.writef32(buf, at, v.x)
    buffer.writef32(buf, at + 4, v.y)
    buffer.writef32(buf, at + 8, v.z)
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
-- into the mask
const function writeRecord(w: Writer, fields: { Field }, record: any, maskSize: number, extra: number)
  const maskAt = w.at
  local mask = extra

  w.at += maskSize

  for i, field in fields do
    const v = record[field.name]

    -- a list missing one would encode to a string no decode reads back
    if v == nil and field.rest == nil and not field.optional then
      logger.error(`a state has no {field.name}`)
    end

    if v == nil or (field.rest ~= nil and v == field.rest) then
      continue
    end

    mask = bit32.bor(mask, bit32.lshift(1, i - 1))
    writeValue(w, field.kind, v)
  end

  if maskSize == 1 then
    buffer.writeu8(w.buf, maskAt, mask)
  else
    buffer.writeu16(w.buf, maskAt, mask)
  end
end

const function sortedNames(decals: { [string]: any })
  const names = {}

  for name in decals do
    table.insert(names, name)
  end

  table.sort(names)

  return names
end

-- version, the strings every state indexes into, the state count, then each
-- state's fields, its surface and its decals by name. names are sorted, so
-- equal lists encode to equal strings
function common.encode(list: List): string
  local bound = 0

  for _, state in list do
    const decals = state.decals or {}
    local count = 0

    for _ in decals do
      count += 1
    end

    bound += STATE_WIDEST + SURFACE_WIDEST + 2 + count * (2 + DECAL_WIDEST)
  end

  const w: Writer = { buf = buffer.create(bound), at = 0, strings = {}, index = {} }

  for _, state in list do
    const decals = state.decals or {}
    const names = sortedNames(decals)

    writeRecord(w, STATE, state, 2, if state.surface ~= nil then SURFACE_BIT else 0)

    if state.surface ~= nil then
      writeRecord(w, SURFACE, state.surface, 1, 0)
    end

    buffer.writeu16(w.buf, w.at, #names)
    w.at += 2

    for _, name in names do
      buffer.writeu16(w.buf, w.at, stringIndex(w, name))
      w.at += 2
      writeRecord(w, DECAL, decals[name], 2, 0)
    end
  end

  local head = 3

  for _, s in w.strings do
    head += 2 + #s
  end

  const out = buffer.create(head + 2 + w.at)

  buffer.writeu8(out, 0, VERSION)
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

const function readState(r: Reader): State?
  const state, mask = readRecord(r, STATE, 2, 1)

  if state == nil then
    return nil
  end

  if bit32.band(mask, SURFACE_BIT) ~= 0 then
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

    if name == nil or decals[name] ~= nil then
      return nil
    end

    const decal = readRecord(r, DECAL, 2, 0)

    if decal == nil then
      return nil
    end

    decals[name] = decal
  end

  state.decals = decals

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
-- for anything that is not exactly one list of this version
function common.decode(raw: string): List?
  if type(raw) ~= "string" or #raw < 5 then
    return nil
  end

  const buf = buffer.fromstring(raw)
  const size = #raw

  if buffer.readu8(buf, 0) ~= VERSION then
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
    const state = readState(r)

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
    return { v.x, v.y, v.z }
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

    if v ~= nil then
      out[field.name] = valueOut(field.kind, v)
    end
  end

  return out
end

-- the list as numbers, strings, arrays and objects: vectors and colors as
-- arrays, an easing as a preset's name or the f32 numbers of its path, y
-- down as stored, decals as an object by name
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
    if not finite(v[i]) then
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
    if not finite(v) or v < 0 or v > 1 then
      return nil, "is a number from 0 to 1"
    end

    return v, nil
  end

  if kind == "number" then
    return if finite(v) then v else nil, "is a number"
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

const STATE_EXTRA = { surface = true, decals = true }

-- a list from its plain form, sorted by time, or nil and the field that is
-- wrong. a field with a rest may be left out and reads as it
function common.fromPlain(v: any): (List?, string?)
  if type(v) ~= "table" then
    return nil, "states are a list"
  end

  if #v > MAX then
    return nil, `a mesh holds at most {MAX} states`
  end

  for key in v do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #v then
      return nil, "states are a list"
    end
  end

  const states = table.create(#v)

  for i, plain in v do
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

-- the list with every position times `factor`, as resizing the template
-- does; sizes are factors on the template's own and stay. a surface and the
-- decals are shared with `list`
function common.scaled(list: List, factor: number): List
  const out = table.create(#list)

  for i, state in list do
    const copy = table.clone(state)

    copy.position = state.position * factor
    out[i] = copy
  end

  return mark(out)
end

return common
