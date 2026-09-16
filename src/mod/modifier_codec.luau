local value = require("./value")

local codec = {}

local VERSION = 2

-- fields the schema names explicitly; anything else on a modifier goes to
-- `extra`, so a field written by a newer plugin survives a round trip here
local KNOWN = {
  kind = true,
  chain = true,
  duration = true,
  offset = true,
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
  offset: value.Value?,
  start: value.Value?,
  finish: value.Value?,
  curve: buffer?,
  weight: buffer?,
  envelope: buffer?,
  [string]: any,
}

-- the outer payload a buffer decodes to; kept as a private alias rather than
-- an exported type, since the codec's only new public surface this version is
-- the `lanes` field and `offset` on a Modifier
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
-- built beside it, read only: it carries a flat queue and no offset field, so
-- it is a different byte layout rather than a subset of this one
local function schema(): (any, any, any)
  if _schema == nil then
    local Z = _z or require("@z") :: any
    _z = Z

    -- start, finish, offset and extra ride Z.table's self-describing mode
    -- because their type genuinely varies: an endpoint holds a tagged
    -- value.Value whose payload is whatever the row's property type is
    -- (number, Color3, UDim2, NumberRange, ...), and extra carries any field
    -- this version of the plugin does not know about, which is what keeps
    -- modifier_queue.merge's union-of-keys behaviour honest across versions
    local modifier = Z.schema({
      kind = Z.str8,
      chain = Z.bool,
      duration = Z.some(Z.f64),
      offset = Z.some(Z.table),
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

-- an offset stores as a Value, the way an endpoint does, so a drawn one needs
-- no schema entry of its own. one written by hand as a plain number stores as
-- the literal it is
local function offsetOf(offset: any): value.Value?
  if type(offset) == "table" then
    return offset
  end

  if typeof(offset) == "number" then
    return value.lit(offset)
  end

  return nil
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
    offset = m.offset,
    start = m.start,
    finish = m.finish,
    curve = m.curve,
    weight = m.weight,
    envelope = m.envelope,
  }

  if type(m.extra) == "table" then
    for k, v in m.extra do
      out[k] = v
    end
  end

  return out :: any
end

-- a wait no clock can count: the old reader took one as zero and the scheduler
-- reset a sum that came out infinite, so one moves nothing here either rather
-- than poisoning the offset of every entry behind it
local function unusable(x: any): boolean
  if x == nil or x.t ~= "lit" then
    return false
  end

  local v = x.v

  return v ~= v or v == math.huge or v == -math.huge
end

-- an old delay shifted everything after it, not just the one entry
-- immediately following, so its wait rides every later entry until a further
-- delay changes what is riding. a literal wait combines with a literal
-- pending by summing; where either side is drawn, the literal shifts the
-- drawn endpoints and two drawn waits sum their endpoints into one draw,
-- keeping the pending side's weight
local function combined(pending: any, wait: any): any
  local p = drawn(pending)
  local w = drawn(wait)

  if type(p) ~= "table" then
    p = if p == nil then nil else { t = "lit", v = p }
  end

  if type(w) ~= "table" then
    w = if w == nil then nil else { t = "lit", v = w }
  end

  if unusable(p) then
    p = nil
  end

  if unusable(w) then
    w = nil
  end

  if p == nil then
    return w
  end

  if w == nil then
    return p
  end

  if p.t == "lit" and w.t == "lit" then
    return { t = "lit", v = p.v + w.v }
  end

  if p.t == "lit" then
    return { t = "draw", a = w.a + p.v, b = w.b + p.v, weight = w.weight }
  end

  if w.t == "lit" then
    return { t = "draw", a = p.a + w.v, b = p.b + w.v, weight = p.weight }
  end

  return { t = "draw", a = p.a + w.a, b = p.b + w.b, weight = p.weight }
end

-- every entry the pending wait rides gets its own copy, so a later entry
-- changing its offset in place never reaches back into an earlier one
local function freshOffset(pending: any): value.Value?
  if pending == nil then
    return nil
  end

  if pending.t == "lit" then
    return { t = "lit", v = pending.v }
  end

  return { t = "draw", a = pending.a, b = pending.b, weight = pending.weight }
end

-- a delay is not an entry of its own: it moved what came after it, which is
-- what the offset on those entries says now. one with nothing after it moved
-- nothing
local function folded(queue: { any }): { Modifier }
  local out = {}
  local pending: any = nil

  for _, m in queue do
    if m.kind == "delay" then
      pending = combined(pending, if m.wait ~= nil then m.wait else m.duration)
      continue
    end

    m.start = drawn(m.start)
    m.finish = drawn(m.finish)

    if pending ~= nil then
      m.offset = freshOffset(pending)
    end

    table.insert(out, m)
  end

  return out
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
        offset = offsetOf(m.offset),
        start = m.start,
        finish = m.finish,
        curve = m.curve,
        weight = m.weight,
        envelope = m.envelope,
        extra = extra,
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

    return { v = VERSION, lanes = { start = folded(queue) } }
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
