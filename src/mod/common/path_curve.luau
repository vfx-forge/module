--!native
--!optimize 2
-- handles are offsets from their anchor: left the incoming one, right the
-- outgoing one
export type Anchor = { position: vector, left: vector?, right: vector? }

export type Curve = { Anchor }

export type Ends = "Free" | "Center" | "Target"

export type Bend = "AsDrawn" | "Outward" | "Swirl" | "Random"

-- the first anchor and the line to the last, in the drawn frame
export type Drawn = { start: vector, chord: vector, length: number }

const VERSION = 1
const MAX = 64

-- the largest magnitude an f32 holds; anything past it is stored as inf
const F32_MAX = 3.4028234663852886e38

-- the version and count bytes, an anchor's mask and position, and a handle
const HEAD = 2
const ANCHOR = 13
const HANDLE = 12

-- the mask bit of each handle is its place here
const SIDES = { "left", "right" }

-- a chord shorter than this has no direction to stretch along
const SHORT_CHORD = 0.01

-- a spawn this near its end point stands on it
const ARRIVED = 1e-4

-- a vector whose part square to forward is under this share of its length
-- runs along forward
const PARALLEL = 1e-3

const TINY = 1e-6

-- the drawn frame: forward is -Z, up is +Y
const UP = vector.create(0, 1, 0)
const SIDE = vector.create(1, 0, 0)
const FORWARD = vector.create(0, 0, -1)

-- the metatable a curve this module made carries, so `is` tells one from any
-- other table
const Curve = table.freeze({})

const function finite(v: any)
  return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

-- a number an f32 holds, short of its rounding
const function storable(v: any)
  return finite(v) and math.abs(v) <= F32_MAX
end

const function mark(anchors: { Anchor }): Curve
  for _, anchor in anchors do
    table.freeze(anchor)
  end

  return table.freeze(setmetatable(anchors, Curve)) :: any
end

-- a vector's axes in either of the engine's spellings of one
const function axes(v: any): (number, number, number)
  if typeof(v) == "Vector3" then
    return v.X, v.Y, v.Z
  end

  return v.x, v.y, v.z
end

-- why a position or handle would encode to a string no decode reads back, or
-- nil when it stores
const function unstorable(v: any): string?
  const t = typeof(v)

  if t ~= "vector" and t ~= "Vector3" then
    return "is a vector"
  end

  const x, y, z = axes(v)

  return if storable(x) and storable(y) and storable(z) then nil else "has an axis no f32 holds"
end

const function writeVector(buf: buffer, at: number, v: any)
  const x, y, z = axes(v)

  buffer.writef32(buf, at, x)
  buffer.writef32(buf, at + 4, y)
  buffer.writef32(buf, at + 8, z)
end

-- the vector at `at`, or nil when an axis is not finite
const function readVector(buf: buffer, at: number): vector?
  const x, y, z = buffer.readf32(buf, at), buffer.readf32(buf, at + 4), buffer.readf32(buf, at + 8)

  if not (finite(x) and finite(y) and finite(z)) then
    return nil
  end

  return vector.create(x, y, z)
end

-- an [x, y, z] of numbers an f32 holds as a vector, or nil
const function vectorIn(v: any): vector?
  if type(v) ~= "table" or #v ~= 3 then
    return nil
  end

  for i = 1, 3 do
    if not storable(v[i]) then
      return nil
    end
  end

  return vector.create(v[1], v[2], v[3])
end

const function toVector(v: Vector3)
  return vector.create(v.X, v.Y, v.Z)
end

const function toVector3(v: vector)
  return Vector3.new(v.x, v.y, v.z)
end

-- the unit part of `v` square to `forward`, or nil when `v` runs along it
const function perpendicular(v: vector, forward: vector): vector?
  const length = vector.magnitude(v)
  const across = v - forward * vector.dot(v, forward)
  const size = vector.magnitude(across)

  if not (length >= TINY and size >= PARALLEL * length) then
    return nil
  end

  return across / size
end

-- +Y square to a direction, else -Z, else +X
const function upright(direction: vector)
  return perpendicular(UP, direction)
    or perpendicular(FORWARD, direction)
    or vector.normalize(SIDE - direction * direction.x)
end

const common = {}

common.VERSION = VERSION
common.MAX = MAX

-- a 10 stud arc forward, bulging up
common.DEFAULT = mark({
  { position = vector.zero, right = vector.create(0, 4, -3) },
  { position = vector.create(0, 0, -10), left = vector.create(0, 4, 3) },
})

function common.is(v: any)
  return type(v) == "table" and getmetatable(v) == Curve
end

-- the version, the anchor count, then each anchor's mask (bit 0 left, bit 1
-- right), its position and the handles it has, all little endian f32. a curve
-- the format cannot hold raises, since its string would decode to nil
function common.encode(curve: Curve): string
  if type(curve) ~= "table" then
    error("a path is a list of anchors", 2)
  end

  const count = #curve

  if count < 2 or count > MAX then
    error(`a path holds 2 to {MAX} anchors, not {count}`, 2)
  end

  local size = HEAD

  for i = 1, count do
    const anchor = curve[i] :: any

    if type(anchor) ~= "table" then
      error(`anchor {i} is no table`, 2)
    end

    const problem = unstorable(anchor.position)

    if problem ~= nil then
      error(`anchor {i}: position {problem}`, 2)
    end

    size += ANCHOR

    for _, side in SIDES do
      const handle = anchor[side]

      if handle == nil then
        continue
      end

      const wrong = unstorable(handle)

      if wrong ~= nil then
        error(`anchor {i}: {side} {wrong}`, 2)
      end

      size += HANDLE
    end
  end

  const buf = buffer.create(size)
  local at = HEAD

  buffer.writeu8(buf, 0, VERSION)
  buffer.writeu8(buf, 1, count)

  for i = 1, count do
    const anchor = curve[i] :: any
    const maskAt = at
    local mask = 0

    writeVector(buf, at + 1, anchor.position)
    at += ANCHOR

    for bit, side in SIDES do
      const handle = anchor[side]

      if handle ~= nil then
        mask = bit32.bor(mask, bit32.lshift(1, bit - 1))
        writeVector(buf, at, handle)
        at += HANDLE
      end
    end

    buffer.writeu8(buf, maskAt, mask)
  end

  return buffer.tostring(buf)
end

-- the curve a string holds, or nil for anything that is not exactly one curve
-- of this version
function common.decode(raw: string): Curve?
  if type(raw) ~= "string" or #raw < HEAD then
    return nil
  end

  const buf = buffer.fromstring(raw)
  const size = #raw
  const count = buffer.readu8(buf, 1)

  if buffer.readu8(buf, 0) ~= VERSION or count < 2 or count > MAX then
    return nil
  end

  const anchors = table.create(count)
  local at = HEAD

  for i = 1, count do
    if at + ANCHOR > size then
      return nil
    end

    const mask = buffer.readu8(buf, at)

    if bit32.rshift(mask, #SIDES) ~= 0 then
      return nil
    end

    const position = readVector(buf, at + 1)

    if position == nil then
      return nil
    end

    const anchor: any = { position = position }

    at += ANCHOR

    for bit, side in SIDES do
      if bit32.extract(mask, bit - 1) == 0 then
        continue
      end

      if at + HANDLE > size then
        return nil
      end

      const handle = readVector(buf, at)

      if handle == nil then
        return nil
      end

      anchor[side] = handle
      at += HANDLE
    end

    anchors[i] = anchor
  end

  if at ~= size then
    return nil
  end

  return mark(anchors)
end

-- each anchor as an object of [x, y, z] arrays, a missing handle left out
function common.toPlain(curve: Curve): { any }
  const out = table.create(#curve)

  for i, anchor in curve do
    const plain: any = { position = { axes(anchor.position) } }

    for _, side in SIDES do
      const handle = (anchor :: any)[side]

      if handle ~= nil then
        plain[side] = { axes(handle) }
      end
    end

    out[i] = plain
  end

  return out
end

-- a curve from its plain form, or nil and what is wrong with it
function common.fromPlain(v: any): (Curve?, string?)
  if type(v) ~= "table" then
    return nil, "a path is a list of anchors"
  end

  local last = 0

  for key in v do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      return nil, "a path is a list of anchors"
    end

    last = math.max(last, key)
  end

  if last < 2 or last > MAX then
    return nil, `a path holds 2 to {MAX} anchors, not {last}`
  end

  const anchors = table.create(last)

  for i = 1, last do
    const plain = v[i]
    const where = `anchor {i}`

    if type(plain) ~= "table" then
      return nil, `{where} is an object`
    end

    for key in plain do
      if key ~= "position" and key ~= "left" and key ~= "right" then
        return nil, `{where} has no field {tostring(key)}`
      end
    end

    if plain.position == nil then
      return nil, `{where}: position is missing`
    end

    const anchor: any = {}

    for _, name in { "position", "left", "right" } do
      const given = plain[name]

      if given == nil then
        continue
      end

      const read = vectorIn(given)

      if read == nil then
        return nil, `{where}: {name} is [x, y, z]`
      end

      anchor[name] = read
    end

    anchors[i] = anchor
  end

  return mark(anchors), nil
end

function common.scaled(curve: Curve, factor: number): Curve
  const out = table.create(#curve)

  for i, anchor in curve do
    out[i] = {
      position = anchor.position * factor,
      left = if anchor.left ~= nil then anchor.left * factor else nil,
      right = if anchor.right ~= nil then anchor.right * factor else nil,
    }
  end

  return mark(out)
end

-- the chain Bezier.new takes: an anchor, its right handle, the next anchor's
-- left handle, the next anchor, a missing handle standing on its anchor
function common.points(curve: Curve): { vector }
  const count = #curve
  const out = table.create(3 * count - 2)
  local previous = curve[1]

  out[1] = previous.position

  for i = 2, count do
    const anchor = curve[i]
    const from, to = previous.position, anchor.position

    table.insert(out, if previous.right ~= nil then from + previous.right else from)
    table.insert(out, if anchor.left ~= nil then to + anchor.left else to)
    table.insert(out, to)
    previous = anchor
  end

  return out
end

function common.drawn(curve: Curve): Drawn
  const start = curve[1].position
  const chord = curve[#curve].position - start

  return { start = start, chord = chord, length = vector.magnitude(chord) }
end

-- where a path ends past its end point: up to the radius off it, on the half
-- facing the spawn. two draws for the direction, then one for the distance
function common.ending(rng: Random, finish: vector, spawn: vector, radius: NumberRange)
  const z = 1 - 2 * rng:NextNumber()
  const angle = 2 * math.pi * rng:NextNumber()
  const distance = radius.Min + (radius.Max - radius.Min) * rng:NextNumber()
  const ring = math.sqrt(math.max(1 - z * z, 0))
  const direction = vector.create(ring * math.cos(angle), ring * math.sin(angle), z)

  if vector.dot(direction, spawn - finish) < 0 then
    return -direction * distance
  end

  return direction * distance
end

-- the frame and scale a drawn point p lands by, at
-- `frame.Position + frame.Rotation * ((p - drawn.start) * scale)`. the chord
-- and the drawn up turn onto the path's forward and its wanted up
function common.place(
  drawn: Drawn,
  ends: Ends,
  spawn: CFrame,
  finish: vector?,
  center: vector,
  axis: vector,
  bend: Bend,
  roll: number
): (CFrame, number)
  const position = toVector(spawn.Position)
  const chord = if drawn.length > TINY then drawn.chord / drawn.length else FORWARD
  const reference = upright(chord)
  const fitted = ends ~= "Free" and finish ~= nil and drawn.length >= SHORT_CHORD
  const mode = if fitted then ends else "Free"
  local forward = toVector(spawn:VectorToWorldSpace(toVector3(chord)))
  local scale = 1

  if fitted then
    const toward = (finish :: vector) - position
    const distance = vector.magnitude(toward)

    if distance < ARRIVED then
      scale = 0
    else
      forward = toward / distance
      scale = distance / drawn.length
    end
  end

  const kept = if mode == "Free"
    then toVector(spawn:VectorToWorldSpace(toVector3(reference)))
    else perpendicular(toVector(spawn.UpVector), forward)
      or perpendicular(toVector(spawn.RightVector), forward)
      or upright(forward)
  local up = kept

  if bend == "Outward" then
    const away = if mode == "Center" then nil else perpendicular(position - center, forward)

    up = away or perpendicular(axis, forward) or kept
  elseif bend == "Swirl" then
    const side = perpendicular(axis, forward)

    up = if side ~= nil then vector.cross(side, forward) else kept
  elseif bend == "Random" then
    up = kept * math.cos(roll) + vector.cross(forward, kept) * math.sin(roll)
  end

  -- the rotation taking (chord, reference, their cross) onto (forward, up,
  -- their cross), column by column
  const drawnSide = vector.cross(chord, reference)
  const wantedSide = vector.cross(forward, up)
  const x = forward * chord.x + up * reference.x + wantedSide * drawnSide.x
  const y = forward * chord.y + up * reference.y + wantedSide * drawnSide.y
  const z = forward * chord.z + up * reference.z + wantedSide * drawnSide.z

  return CFrame.fromMatrix(spawn.Position, toVector3(x), toVector3(y), toVector3(z)), scale
end

-- the point u of the way along the placed path by distance, 0 to 1
function common.at(bezier: any, drawn: Drawn, frame: CFrame, scale: number, u: number)
  const offset = (bezier:atUniform(u) - drawn.start) * scale

  return toVector(frame:PointToWorldSpace(toVector3(offset)))
end

-- `count` points at even steps along the placed path, from its end when
-- reversed, written into `out` when given
function common.trace(
  bezier: any,
  drawn: Drawn,
  frame: CFrame,
  scale: number,
  reverse: boolean,
  count: number,
  out: { vector }?
): { vector }
  const points = out or table.create(count)
  const steps = math.max(count - 1, 1)

  for i = 1, count do
    const u = (i - 1) / steps

    points[i] = common.at(bezier, drawn, frame, scale, if reverse then 1 - u else u)
  end

  for i = #points, count + 1, -1 do
    points[i] = nil
  end

  return points
end

return common
