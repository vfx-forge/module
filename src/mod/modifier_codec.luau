local value = require("./value")
local logger = require("@mod/logger")

local codec = {}

local VERSION = 2

-- Z writes a Color3 as three bytes and a ColorSequence stop as four, which
-- snaps a stop's time to 1/255 and merges stops closer than that. a colour in
-- an endpoint or an extra field rides a one key table holding a buffer instead,
-- every number in it an f32, the width the engine holds it at
local STOP = 16
local COLOUR = 12

-- the newest layout this codec reads, for a writer deciding whether a stored
-- payload is newer than itself
codec.VERSION = VERSION

-- fields the schema names explicitly; anything else on a modifier goes to
-- `extra`, so a field written by a newer plugin survives a round trip here
local KNOWN = {
  kind = true,
  chain = true,
  duration = true,
  wait = true,
  start = true,
  finish = true,
  curve = true,
  weight = true,
  envelope = true,
}

export type Modifier = {
  kind: string,
  chain: boolean,
  duration: number?,
  wait: value.Value?,
  start: value.Value?,
  finish: value.Value?,
  curve: buffer?,
  weight: buffer?,
  envelope: buffer?,
  [string]: any,
}

-- the outer payload a buffer decodes to; kept as a private alias rather than
-- an exported type, since the codec's only new public surface this version is
-- the `lanes` field
type Payload = { v: number, lanes: { [string]: { Modifier } } }

local _z: any = nil
local _schema: any = nil
local _legacy: any = nil

-- injected rather than resolved eagerly so a future runtime decoder can supply
-- a different Z; real Studio callers and lune specs both just require("@z")
-- directly, since the roblox datatype globals Z.table needs are already in
-- scope by the time this runs
function codec.configure(z: any)
  _z = z
  _schema = nil
  _legacy = nil
end

-- the fixed part of a modifier is a schema, so it writes no field names at all,
-- which is where most of the payload used to go. the layout before lanes is
-- built beside it, read only: it carries a flat queue and no wait field, so
-- it is a different byte layout rather than a subset of this one
local function schema(): (any, any, any)
  if _schema == nil then
    local Z = _z or require("@z") :: any
    _z = Z

    -- start, finish, wait and extra ride Z.table's self-describing mode
    -- because their type genuinely varies: an endpoint holds a tagged
    -- value.Value whose payload is whatever the row's property type is
    -- (number, Color3, UDim2, NumberRange, ...), a colour wrapped by packed
    -- below, and extra carries any field
    -- this version of the plugin does not know about, which is what keeps
    -- modifier_queue.merge's union-of-keys behaviour honest across versions
    local modifier = Z.schema({
      kind = Z.str8,
      chain = Z.bool,
      duration = Z.some(Z.f64),
      wait = Z.some(Z.table),
      start = Z.some(Z.table),
      finish = Z.some(Z.table),
      -- buffer16 tops curve out at 65535 bytes rather than an accidental
      -- limit; a curve is 24 bytes per control point, so that is thousands of
      -- points
      curve = Z.some(Z.buffer16),
      weight = Z.some(Z.buffer16),
      envelope = Z.some(Z.buffer16),
      extra = Z.some(Z.table),
    })

    local older = Z.schema({
      kind = Z.str8,
      chain = Z.bool,
      duration = Z.some(Z.f64),
      start = Z.some(Z.table),
      finish = Z.some(Z.table),
      curve = Z.some(Z.buffer16),
      weight = Z.some(Z.buffer16),
      envelope = Z.some(Z.buffer16),
      extra = Z.some(Z.table),
    })

    -- a row carries a handful of lanes and a lane a handful of entries, so an
    -- 8-bit count is plenty for both
    _schema = Z.schema({
      v = Z.u8,
      lanes = Z.schema8({ [Z.str8] = Z.schema8({ modifier }) }),
    })

    _legacy = Z.schema({
      v = Z.u8,
      queue = Z.schema8({ older }),
    })
  end

  return _z, _schema, _legacy
end

-- a wait stores as a Value, the way an endpoint does, so a drawn one needs no
-- schema entry of its own. one written by hand as a plain number stores as the
-- literal it is
local function waitOf(wait: any): value.Value?
  if type(wait) == "table" then
    return wait
  end

  if typeof(wait) == "number" then
    return value.lit(wait)
  end

  return nil
end

-- a copy of the value with every colour in it wrapped, however deep
local function packed(v: any): any
  local kind = typeof(v)

  if kind == "Color3" then
    local buf = buffer.create(COLOUR)

    buffer.writef32(buf, 0, v.R)
    buffer.writef32(buf, 4, v.G)
    buffer.writef32(buf, 8, v.B)

    return { Color3 = buf }
  end

  if kind == "ColorSequence" then
    local points = v.Keypoints
    local buf = buffer.create(#points * STOP)

    for i, point in points do
      local at = (i - 1) * STOP
      local colour = point.Value

      buffer.writef32(buf, at, point.Time)
      buffer.writef32(buf, at + 4, colour.R)
      buffer.writef32(buf, at + 8, colour.G)
      buffer.writef32(buf, at + 12, colour.B)
    end

    return { ColorSequence = buf }
  end

  if kind ~= "table" then
    return v
  end

  local out = {}

  for k, x in v do
    out[k] = packed(x)
  end

  return out
end

-- no endpoint holds a plain table of its own, and no other table is a single
-- key naming a colour type over a buffer, so that shape is only ever a wrap
local function unpacked(v: any): any
  if type(v) ~= "table" then
    return v
  end

  local kind, buf = next(v)

  if typeof(buf) == "buffer" and next(v, kind) == nil then
    local size = buffer.len(buf)

    if kind == "Color3" then
      if size ~= COLOUR then
        logger.error(`malformed modifier queue payload: a colour of {size} bytes`)
      end

      return Color3.new(buffer.readf32(buf, 0), buffer.readf32(buf, 4), buffer.readf32(buf, 8))
    end

    if kind == "ColorSequence" then
      if size < STOP * 2 or size % STOP ~= 0 then
        logger.error(`malformed modifier queue payload: a colour sequence of {size} bytes`)
      end

      local points = {}

      for at = 0, size - STOP, STOP do
        local colour =
          Color3.new(buffer.readf32(buf, at + 4), buffer.readf32(buf, at + 8), buffer.readf32(buf, at + 12))

        table.insert(points, ColorSequenceKeypoint.new(buffer.readf32(buf, at), colour))
      end

      return ColorSequence.new(points)
    end
  end

  for k, x in v do
    v[k] = unpacked(x)
  end

  return v
end

-- the numeric range an older endpoint drew between is a draw of the same two
-- numbers, which is the one shape that tag ever carried
local function drawn(x: any): any
  if type(x) == "table" and x.t == "rand" then
    return value.draw(x.min, x.max)
  end

  return x
end

local function entryOf(m: any): Modifier
  local out: { [string]: any } = {
    kind = m.kind,
    chain = m.chain,
    duration = m.duration,
    wait = m.wait,
    start = m.start,
    finish = m.finish,
    curve = m.curve,
    weight = m.weight,
    envelope = m.envelope,
  }

  if type(m.extra) == "table" then
    for k, v in unpacked(m.extra) do
      out[k] = v
    end
  end

  out.wait = unpacked(drawn(out.wait))
  out.start = unpacked(drawn(out.start))
  out.finish = unpacked(drawn(out.finish))

  return out :: any
end

function codec.empty(): Payload
  return { v = VERSION, lanes = {} }
end

function codec.encode(payload: any): buffer
  if type(payload) ~= "table" then
    error("cannot encode a malformed modifier queue", 2)
  end

  local lanes = payload.lanes

  -- a caller holding one queue means the lane every queue was before lanes
  if lanes == nil and type(payload.queue) == "table" then
    lanes = { start = payload.queue }
  end

  if type(lanes) ~= "table" then
    error("cannot encode a malformed modifier queue", 2)
  end

  local Z, s = schema()
  local out = {}

  for lane, queue in lanes do
    if type(lane) ~= "string" then
      error(`modifier codec cannot encode a lane named with a {type(lane)}`, 2)
    end

    if type(queue) ~= "table" then
      error(`cannot encode the {lane} lane, which is not a queue`, 2)
    end

    local entries = {}

    for i, m in queue do
      if type(m) ~= "table" then
        error("cannot encode a modifier that is not a table", 2)
      end

      local extra: { [string]: any }? = nil

      for k, v in m do
        if not KNOWN[k] then
          if type(k) ~= "string" then
            error(`modifier codec cannot encode a modifier with a {type(k)} key`, 2)
          end

          extra = extra or {}
          (extra :: any)[k] = v
        end
      end

      entries[i] = {
        kind = m.kind or "",
        chain = m.chain == true,
        duration = m.duration,
        wait = packed(waitOf(m.wait)),
        start = packed(m.start),
        finish = packed(m.finish),
        curve = m.curve,
        weight = m.weight,
        envelope = m.envelope,
        extra = packed(extra),
      }
    end

    out[lane] = entries
  end

  -- Z.ser REPORTS failure as a second return rather than raising, so an
  -- unencodable value would otherwise sail through as a nil buffer
  local buf, err = Z.ser(s, { v = VERSION, lanes = out })

  if err ~= nil or typeof(buf) ~= "buffer" then
    error(`cannot encode modifier queue: {err or "no buffer produced"}`, 2)
  end

  return buf :: buffer
end

function codec.decode(buf: buffer): Payload
  if typeof(buf) ~= "buffer" or buffer.len(buf) == 0 then
    error("malformed modifier queue payload", 2)
  end

  local Z, s, older = schema()

  -- a schema writes its fields in sorted key order, which puts the one byte
  -- version last in both layouts, so the payload says which schema reads it
  -- before anything is read. the decoded version is checked against this below,
  -- so a layout that stopped ending in its version fails loudly rather than
  -- reading one field as another
  local version = buffer.readu8(buf, buffer.len(buf) - 1)

  if version > VERSION then
    error(`unsupported modifier queue version {version} (reader supports <= {VERSION})`, 2)
  end

  -- Z's safe mode swallows the read error and hands back nil, so absence of a
  -- table IS one failure signal. it is not sufficient on its own: a payload
  -- truncated at a field boundary still decodes, just short. Z.migrate shows the
  -- intended check, which is that the reader consumed exactly the whole buffer,
  -- and that also rejects trailing garbage
  local data, pos = Z.des(if version < VERSION then older else s, buf, 0, true)

  if type(data) ~= "table" or data.v ~= version then
    error("malformed modifier queue payload", 2)
  end

  if pos ~= buffer.len(buf) then
    error(`malformed modifier queue payload: read {pos} of {buffer.len(buf)} bytes`, 2)
  end

  if version < VERSION then
    if type(data.queue) ~= "table" then
      error("malformed modifier queue payload", 2)
    end

    local queue = {}

    for i, m in data.queue do
      queue[i] = entryOf(m)
    end

    return { v = VERSION, lanes = { start = queue } }
  end

  if type(data.lanes) ~= "table" then
    error("malformed modifier queue payload", 2)
  end

  local lanes = {}

  for lane, queue in data.lanes do
    local entries = {}

    for i, m in queue do
      entries[i] = entryOf(m)
    end

    lanes[lane] = entries
  end

  return { v = VERSION, lanes = lanes }
end

return codec
