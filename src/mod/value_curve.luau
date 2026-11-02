--!native
--!optimize 2
local value_curve = {}

const VERSION = 1

-- version, channels and linked as bytes, then the key count as a u32
const HEADER = 7
const MAX_CHANNELS = 3

-- each channel has its own value and its own handles
export type Key = {
  time: number,
  value: { number },
  envelope: number,
  left: { vector },
  right: { vector },
}

export type Curve = {
  channels: number,
  linked: boolean,
  keys: { Key },
}

-- time, the channels, the envelope, then each channel's two handles as an x
-- and a y each
const function keySize(channels: number)
  return 4 + channels * 4 + 4 + channels * 16
end

function value_curve.flat(value: number, channels: number): Curve
  return {
    channels = channels,
    linked = true,
    keys = {
      {
        time = 0,
        value = table.create(channels, value),
        envelope = 0,
        left = table.create(channels, vector.zero),
        right = table.create(channels, vector.zero),
      },
    },
  }
end

function value_curve.encode(curve: Curve): string
  const channels = curve.channels
  const size = keySize(channels)
  const buf = buffer.create(HEADER + #curve.keys * size)

  buffer.writeu8(buf, 0, VERSION)
  buffer.writeu8(buf, 1, channels)
  buffer.writeu8(buf, 2, if curve.linked then 1 else 0)
  buffer.writeu32(buf, 3, #curve.keys)

  for i, k in curve.keys do
    local at = HEADER + (i - 1) * size

    buffer.writef32(buf, at, k.time)

    for c = 1, channels do
      buffer.writef32(buf, at + c * 4, k.value[c])
    end

    at += 4 + channels * 4

    buffer.writef32(buf, at, k.envelope)

    for c = 1, channels do
      const handle = at + 4 + (c - 1) * 16

      buffer.writef32(buf, handle, k.left[c].x)
      buffer.writef32(buf, handle + 4, k.left[c].y)
      buffer.writef32(buf, handle + 8, k.right[c].x)
      buffer.writef32(buf, handle + 12, k.right[c].y)
    end
  end

  return buffer.tostring(buf)
end

const function finite(v: number)
  return v == v and v > -math.huge and v < math.huge
end

function value_curve.decode(data: string?): Curve?
  if type(data) ~= "string" or #data < HEADER then
    return nil
  end

  const buf = buffer.fromstring(data)

  if buffer.readu8(buf, 0) ~= VERSION then
    return nil
  end

  const channels = buffer.readu8(buf, 1)
  const flag = buffer.readu8(buf, 2)
  const count = buffer.readu32(buf, 3)

  -- the length must be exactly the keys the header names, which also keeps a
  -- huge count from sizing a table
  if (channels ~= 1 and channels ~= MAX_CHANNELS) or flag > 1 or count == 0 then
    return nil
  end

  const size = keySize(channels)

  if #data ~= HEADER + count * size then
    return nil
  end

  const keys = table.create(count)

  for i = 1, count do
    local at = HEADER + (i - 1) * size
    const time = buffer.readf32(buf, at)
    const values = table.create(channels)

    if not finite(time) then
      return nil
    end

    for c = 1, channels do
      const v = buffer.readf32(buf, at + c * 4)

      if not finite(v) then
        return nil
      end

      values[c] = v
    end

    at += 4 + channels * 4

    const envelope = buffer.readf32(buf, at)
    const left = table.create(channels)
    const right = table.create(channels)

    if not finite(envelope) then
      return nil
    end

    for c = 1, channels do
      const handle = at + 4 + (c - 1) * 16
      const lx = buffer.readf32(buf, handle)
      const ly = buffer.readf32(buf, handle + 4)
      const rx = buffer.readf32(buf, handle + 8)
      const ry = buffer.readf32(buf, handle + 12)

      if not (finite(lx) and finite(ly) and finite(rx) and finite(ry)) then
        return nil
      end

      left[c] = vector.create(lx, ly, 0)
      right[c] = vector.create(rx, ry, 0)
    end

    keys[i] = {
      time = time,
      value = values,
      envelope = envelope,
      left = left,
      right = right,
    }
  end

  -- table.sort is not stable, and keys at one time must keep their order
  const order = table.create(count)

  for i = 1, count do
    order[i] = i
  end

  table.sort(order, function(a: number, b: number)
    const ta, tb = keys[a].time, keys[b].time

    if ta ~= tb then
      return ta < tb
    end

    return a < b
  end)

  const sorted = table.create(count)

  for i, from in order do
    sorted[i] = keys[from]
  end

  return { channels = channels, linked = flag == 1, keys = sorted }
end

function value_curve.draw(curve: Curve, rng: Random): { number }
  const draws = table.create(#curve.keys)

  for i = 1, #curve.keys do
    draws[i] = rng:NextNumber(-1, 1)
  end

  return draws
end

const function cubic(p0: number, p1: number, p2: number, p3: number, s: number)
  const r = 1 - s

  return r * r * r * p0 + 3 * r * r * s * p1 + 3 * r * s * s * p2 + s * s * s * p3
end

const function slope(p0: number, p1: number, p2: number, p3: number, s: number)
  const r = 1 - s

  return 3 * (r * r * (p1 - p0) + 2 * r * s * (p2 - p1) + s * s * (p3 - p2))
end

-- the curve parameter whose time is t. time control points sit inside the
-- segment, so time rises with s and the root is unique
const function solve(t0: number, x1: number, x2: number, t1: number, t: number)
  local s = (t - t0) / (t1 - t0)

  for _ = 1, 6 do
    const err = cubic(t0, x1, x2, t1, s) - t
    const d = slope(t0, x1, x2, t1, s)

    if math.abs(err) < 1e-7 then
      return s
    end

    if d < 1e-6 then
      break
    end

    s = math.clamp(s - err / d, 0, 1)
  end

  local lo, hi = 0, 1

  for _ = 1, 40 do
    s = (lo + hi) * 0.5

    if cubic(t0, x1, x2, t1, s) < t then
      lo = s
    else
      hi = s
    end
  end

  return s
end

-- the returned table is the sampler's own and is rewritten by the next call,
-- so a frame loop allocates nothing; copy it to keep a reading. the second
-- return says whether every t reads the same, so a caller can write it once
function value_curve.sampler(curve: Curve, draws: { number }?): ((t: number) -> { number }, boolean)
  const keys = curve.keys
  const channels = curve.channels
  const count = #keys
  const times = table.create(count)
  const values = table.create(count * channels)
  const out = table.create(channels, 0)

  -- per segment and channel: the two time control points, clamped inside the
  -- segment so time never folds back, and the handle offsets in value
  const tx1 = table.create(count * channels)
  const tx2 = table.create(count * channels)
  const ty1 = table.create(count * channels)
  const ty2 = table.create(count * channels)

  for i, k in keys do
    const widen = k.envelope * (if draws then draws[i] or 0 else 0)

    times[i] = k.time

    for c = 1, channels do
      values[(i - 1) * channels + c] = k.value[c] + widen
    end
  end

  -- per segment: whether every channel's time handles match, as a linked
  -- curve's always do, so one time solve serves them all
  const shared = table.create(count, true)

  local flat = true

  for i = 1, count - 1 do
    const a, b = keys[i], keys[i + 1]
    const width = b.time - a.time

    for c = 1, channels do
      const at = (i - 1) * channels + c
      const leave, enter = a.right[c], b.left[c]
      const rx = math.clamp(leave.x, 0, width)
      const lx = math.clamp(enter.x, -width, 0)

      tx1[at] = a.time + rx
      tx2[at] = b.time + lx

      -- a handle cut short keeps its direction
      ty1[at] = if leave.x ~= 0 then leave.y * rx / leave.x else leave.y
      ty2[at] = if enter.x ~= 0 then enter.y * lx / enter.x else enter.y

      if tx1[at] ~= tx1[at - c + 1] or tx2[at] ~= tx2[at - c + 1] then
        shared[i] = false
      end

      if ty1[at] ~= 0 or ty2[at] ~= 0 or values[at] ~= values[at + channels] then
        flat = false
      end
    end
  end

  const last = count * channels - channels

  return function(t: number)
    -- nan reads as the start
    t = if t == t then math.clamp(t, 0, 1) else 0

    if t < times[1] then
      for c = 1, channels do
        out[c] = values[c]
      end

      return out
    end

    if t >= times[count] then
      for c = 1, channels do
        out[c] = values[last + c]
      end

      return out
    end

    -- the last key at or before t; keys at one time make a segment of no
    -- width that this never picks
    local i = 1

    while times[i + 1] <= t do
      i += 1
    end

    const t0, t1 = times[i], times[i + 1]
    const from = (i - 1) * channels
    const to = i * channels
    const one = if shared[i] then solve(t0, tx1[from + 1], tx2[from + 1], t1, t) else nil

    for c = 1, channels do
      const at = from + c
      const s = one or solve(t0, tx1[at], tx2[at], t1, t)
      const v0, v1 = values[at], values[to + c]

      out[c] = cubic(v0, v0 + ty1[at], v1 + ty2[at], v1, s)
    end

    return out
  end,
    flat
end

-- builds a whole sampler per call, so not for a frame loop; use sampler there
function value_curve.at(curve: Curve, t: number, draws: { number }?): { number }
  return table.clone(value_curve.sampler(curve, draws)(t))
end

return value_curve
