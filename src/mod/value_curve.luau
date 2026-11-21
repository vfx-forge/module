--!optimize 2
local value_curve = {}

const VERSION = 1

-- version, channels and linked as bytes, then the key count as a u32
const HEADER = 7
const MAX_CHANNELS = 3

-- how a key a split or a blend made widens, per channel: its value and each
-- of its handles by the sum of each weight times the draw of the key it
-- names, flat as index then weight, so it follows the keys it came from
-- rather than drawing alone
export type Mix = { value: { { number } }, left: { { number } }, right: { { number } } }

-- each channel has its own value and its own handles. a key with no `mix`
-- widens its value by its envelope times its own draw
export type Key = {
  time: number,
  value: { number },
  envelope: number,
  left: { vector },
  right: { vector },
  mix: Mix?,
}

-- `exact` is a curve a split or a blend made, whose time handles may reach
-- past their own segment and still rise, as the halves of one cubic do; the
-- sampler draws them as they are. a stored curve is never exact
export type Curve = {
  channels: number,
  linked: boolean,
  keys: { Key },
  exact: boolean?,
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

-- one channel running straight from `from` at 0 to `to` at 1
function value_curve.ramp(from: number, to: number): Curve
  const function key(time: number, v: number)
    return {
      time = time,
      value = { v },
      envelope = 0,
      left = { vector.zero },
      right = { vector.zero },
    }
  end

  return {
    channels = 1,
    linked = true,
    keys = { key(0, from), key(1, to) },
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

@native
local function cubic(p0: number, p1: number, p2: number, p3: number, s: number)
  const r = 1 - s

  return r * r * r * p0 + 3 * r * r * s * p1 + 3 * r * s * s * p2 + s * s * s * p3
end

@native
local function slope(p0: number, p1: number, p2: number, p3: number, s: number)
  const r = 1 - s

  return 3 * (r * r * (p1 - p0) + 2 * r * s * (p2 - p1) + s * s * (p3 - p2))
end

-- the curve parameter whose time is t. time control points sit inside the
-- segment, so time rises with s and the root is unique
@native
local function solve(t0: number, x1: number, x2: number, t1: number, t: number)
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
@native
function value_curve.sampler(curve: Curve, draws: { number }?): ((t: number) -> { number }, boolean)
  const keys = curve.keys
  const channels = curve.channels
  const exact = curve.exact == true
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

  -- the weighted draws a mix's pairs sum to
  @native
  local function drawn(pairs: { number }): number
    local sum = 0

    for at = 1, #pairs, 2 do
      sum += pairs[at + 1] * ((draws :: { number })[pairs[at]] or 0)
    end

    return sum
  end

  for i, k in keys do
    const mix = k.mix
    const widen = if draws ~= nil and mix == nil then k.envelope * (draws[i] or 0) else 0

    times[i] = k.time

    for c = 1, channels do
      values[(i - 1) * channels + c] = k.value[c] + (if draws ~= nil and mix ~= nil then drawn(mix.value[c]) else widen)
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
      const rx = if exact then leave.x else math.clamp(leave.x, 0, width)
      const lx = if exact then enter.x else math.clamp(enter.x, -width, 0)

      tx1[at] = a.time + rx
      tx2[at] = b.time + lx

      -- a handle cut short keeps its direction
      ty1[at] = if leave.x ~= 0 then leave.y * rx / leave.x else leave.y
      ty2[at] = if enter.x ~= 0 then enter.y * lx / enter.x else enter.y

      if draws ~= nil and a.mix ~= nil then
        ty1[at] += drawn(a.mix.right[c])
      end

      if draws ~= nil and b.mix ~= nil then
        ty2[at] += drawn(b.mix.left[c])
      end

      if tx1[at] ~= tx1[at - c + 1] or tx2[at] ~= tx2[at - c + 1] then
        shared[i] = false
      end

      if ty1[at] ~= 0 or ty2[at] ~= 0 or values[at] ~= values[at + channels] then
        flat = false
      end
    end
  end

  const last = count * channels - channels

  return @native function(t: number)
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
@native
function value_curve.at(curve: Curve, t: number, draws: { number }?): { number }
  return table.clone(value_curve.sampler(curve, draws)(t))
end

-- whether a value is a decoded curve, which a row's value is the one table of
function value_curve.is(v: any)
  return type(v) == "table" and type(v.channels) == "number" and type(v.keys) == "table"
end

-- a mix's index and weight pairs, each weight times `factor`
const function scalePairs(parts: { { number } }, factor: number)
  const out = table.create(#parts)

  for c, pairs in parts do
    const scaled = table.clone(pairs)

    for at = 2, #scaled, 2 do
      scaled[at] *= factor
    end

    out[c] = scaled
  end

  return out
end

-- the curve with every key's value, envelope and handle value offsets times
-- `factor`, its times kept, so every sample and every draw scales with it
function value_curve.multiply(curve: Curve, factor: number): Curve
  const channels = curve.channels
  const keys = table.create(#curve.keys)

  for i, k in curve.keys do
    const mix = k.mix
    const values = table.create(channels)
    const left = table.create(channels)
    const right = table.create(channels)

    for c = 1, channels do
      const l, r = k.left[c], k.right[c]

      values[c] = k.value[c] * factor
      left[c] = vector.create(l.x, l.y * factor, 0)
      right[c] = vector.create(r.x, r.y * factor, 0)
    end

    keys[i] = {
      time = k.time,
      value = values,
      envelope = k.envelope * factor,
      left = left,
      right = right,
      mix = if mix ~= nil
        then {
          value = scalePairs(mix.value, factor),
          left = scalePairs(mix.left, factor),
          right = scalePairs(mix.right, factor),
        }
        else nil,
    }
  end

  return { channels = channels, linked = curve.linked, keys = keys, exact = curve.exact }
end

-- a handle cut to a segment the way the sampler cuts it, so a copy stores the
-- curve the sampler draws
const function cut(handle: vector, low: number, high: number)
  const x = math.clamp(handle.x, low, high)

  if x == handle.x then
    return handle
  end

  return vector.create(x, if handle.x ~= 0 then handle.y * x / handle.x else handle.y, 0)
end

-- what a key's widening is made of, per channel: its value's and each of its
-- handles', each the draws of keys the curve owns times a weight, keyed by
-- the key that owns the draw. every part is linear in the draws, so a split
-- cuts it by de Casteljau as it cuts the cubic, and the halves widen exactly
-- as the whole did
type Terms = { [Key]: number }
type Widen = { value: { Terms }, left: { Terms }, right: { Terms } }
type Widths = { [Key]: Widen }

-- `a` times `wa` plus `b` times `wb`
const function combine(a: Terms, wa: number, b: Terms?, wb: number): Terms
  const out = {}

  for owner, w in a do
    out[owner] = w * wa
  end

  if b ~= nil then
    for owner, w in b do
      out[owner] = (out[owner] or 0) + w * wb
    end
  end

  return out
end

-- none of a key's own, for a part that does not widen
const function emptyOf(channels: number): { Terms }
  const out = table.create(channels)

  for c = 1, channels do
    out[c] = {}
  end

  return out
end

-- a key at `time` holding `from`'s value with no handles, widening as it does
const function still(from: Key, time: number, channels: number, widths: Widths): Key
  const made = {
    time = time,
    value = table.clone(from.value),
    envelope = from.envelope,
    left = table.create(channels, vector.zero),
    right = table.create(channels, vector.zero),
  }

  const value = table.create(channels)

  for c = 1, channels do
    value[c] = combine(widths[from].value[c], 1, nil, 0)
  end

  widths[made] = { value = value, left = emptyOf(channels), right = emptyOf(channels) }

  return made
end

-- the key at `time` inside the segment from `from` to `into`, each channel's
-- cubic cut there by de Casteljau at the parameter whose time is `time`. the
-- handles either side are rewritten to the halves, so the two segments draw
-- exactly the one they replace, and so is each channel's widening. the stored
-- envelope is spread as the cubic spreads the end values
const function splitAt(from: Key, into: Key, time: number, channels: number, widths: Widths): Key
  const t0, t1 = from.time, into.time
  const values = table.create(channels)
  const left = table.create(channels)
  const right = table.create(channels)
  const fw, iw = widths[from], widths[into]
  const widen = { value = table.create(channels), left = table.create(channels), right = table.create(channels) }

  local weight = 0

  for c = 1, channels do
    const leave, enter = from.right[c], into.left[c]
    const v0, v1 = from.value[c], into.value[c]
    const x1, y1 = t0 + leave.x, v0 + leave.y
    const x2, y2 = t1 + enter.x, v1 + enter.y
    const s = solve(t0, x1, x2, t1, time)
    const r = 1 - s

    const ax, ay = t0 + (x1 - t0) * s, v0 + (y1 - v0) * s
    const bx, by = x1 + (x2 - x1) * s, y1 + (y2 - y1) * s
    const cx, cy = x2 + (t1 - x2) * s, y2 + (v1 - y2) * s
    const dx, dy = ax + (bx - ax) * s, ay + (by - ay) * s
    const ex, ey = bx + (cx - bx) * s, by + (cy - by) * s
    const px, py = dx + (ex - dx) * s, dy + (ey - dy) * s

    from.right[c] = vector.create(ax - t0, ay - v0, 0)
    into.left[c] = vector.create(cx - t1, cy - v1, 0)

    values[c] = py
    left[c] = vector.create(dx - px, dy - py, 0)
    right[c] = vector.create(ex - px, ey - py, 0)

    -- the same cut on the widening's control points
    const p0 = fw.value[c]
    const p1 = combine(p0, 1, fw.right[c], 1)
    const p3 = iw.value[c]
    const p2 = combine(p3, 1, iw.left[c], 1)
    const a = combine(p0, r, p1, s)
    const b = combine(p1, r, p2, s)
    const e = combine(p2, r, p3, s)
    const d = combine(a, r, b, s)
    const f = combine(b, r, e, s)
    const p = combine(d, r, f, s)

    fw.right[c] = combine(a, 1, p0, -1)
    iw.left[c] = combine(e, 1, p3, -1)
    widen.value[c] = p
    widen.left[c] = combine(d, 1, p, -1)
    widen.right[c] = combine(f, 1, p, -1)

    if c == 1 then
      weight = s * s * (3 - 2 * s)
    end
  end

  const made = {
    time = time,
    value = values,
    envelope = from.envelope + (into.envelope - from.envelope) * weight,
    left = left,
    right = right,
  }

  widths[made] = widen

  return made
end

-- a mix's flat index and weight pairs as terms keyed by the keys of `keys`
const function termsOf(pairs: { number }, keys: { Key }): Terms
  const out = {}

  for at = 1, #pairs, 2 do
    out[keys[pairs[at]]] = pairs[at + 1]
  end

  return out
end

-- the curve's keys, copied with their handles cut to their segments as the
-- sampler cuts them, and a key added at each of `extra`, sorted times the curve
-- has no key at, each key's widening in `widths`. a time before the first key
-- or past the last holds that end's value, as the sampler reads it there
const function withTimes(curve: Curve, extra: { number }, widths: Widths): { Key }
  const channels = curve.channels
  const exact = curve.exact == true
  const source = curve.keys
  const count = #source
  const keys = table.create(count)
  const out = table.create(count + #extra)

  for i, k in source do
    const before = source[i - 1]
    const after = source[i + 1]

    keys[i] = {
      time = k.time,
      value = table.clone(k.value),
      envelope = k.envelope,
      left = table.clone(k.left),
      right = table.clone(k.right),
    }

    if exact then
      continue
    end

    for c = 1, channels do
      if before ~= nil then
        keys[i].left[c] = cut(k.left[c], before.time - k.time, 0)
      end

      if after ~= nil then
        keys[i].right[c] = cut(k.right[c], 0, after.time - k.time)
      end
    end
  end

  for i, k in source do
    const own = keys[i]
    const mix = k.mix

    if mix ~= nil then
      const widen = { value = table.create(channels), left = table.create(channels), right = table.create(channels) }

      for c = 1, channels do
        widen.value[c] = termsOf(mix.value[c], keys)
        widen.left[c] = termsOf(mix.left[c], keys)
        widen.right[c] = termsOf(mix.right[c], keys)
      end

      widths[own] = widen
    else
      const value = table.create(channels)

      for c = 1, channels do
        value[c] = { [own] = k.envelope }
      end

      widths[own] = { value = value, left = emptyOf(channels), right = emptyOf(channels) }
    end
  end

  local cursor = 1

  -- a held end that becomes a segment must not bend it with a handle the
  -- sampler never read
  while cursor <= #extra and extra[cursor] < keys[1].time do
    table.insert(out, still(keys[1], extra[cursor], channels, widths))
    cursor += 1
  end

  if cursor > 1 then
    keys[1].left = table.create(channels, vector.zero)
    widths[keys[1]].left = emptyOf(channels)
  end

  for i = 1, count do
    local from = keys[i]
    const into = keys[i + 1]

    if into ~= nil then
      while cursor <= #extra and extra[cursor] < into.time do
        if extra[cursor] > from.time then
          const mid = splitAt(from, into, extra[cursor], channels, widths)

          table.insert(out, from)
          from = mid
        end

        cursor += 1
      end
    end

    table.insert(out, from)
  end

  const last = keys[count]

  local trailed = false

  while cursor <= #extra do
    if extra[cursor] > last.time then
      table.insert(out, still(last, extra[cursor], channels, widths))
      trailed = true
    end

    cursor += 1
  end

  if trailed then
    last.right = table.create(channels, vector.zero)
    widths[last].right = emptyOf(channels)
  end

  return out
end

-- index and weight pairs flat, in index order so equal terms flatten alike,
-- a pair of no weight left out
const function flatten(terms: { [number]: number }): { number }
  const order = {}

  for at, w in terms do
    if w ~= 0 then
      table.insert(order, at)
    end
  end

  table.sort(order)

  const out = table.create(#order * 2)

  for _, at in order do
    table.insert(out, at)
    table.insert(out, terms[at])
  end

  return out
end

-- terms keyed by key as terms keyed by the key's place in the list
const function indexed(terms: Terms, index: { [Key]: number }): { [number]: number }
  const out = {}

  for owner, w in terms do
    const at = index[owner]

    out[at] = (out[at] or 0) + w
  end

  return out
end

-- whether a key widens as a stored key does: its value by its own envelope
-- on every channel, its handles not at all
const function plain(mix: Mix, i: number, envelope: number)
  for c, pairs in mix.value do
    const own = if #pairs == 2 and pairs[1] == i then pairs[2] else if #pairs == 0 then 0 else nil

    if own ~= envelope or #mix.left[c] > 0 or #mix.right[c] > 0 then
      return false
    end
  end

  return true
end

-- each key of `keys` given the mix its widening takes, nil for one that
-- widens as a stored key does
const function settle(keys: { Key }, widths: Widths, channels: number): { Key }
  const index: { [Key]: number } = {}

  for i, k in keys do
    index[k] = i
  end

  for i, k in keys do
    const widen = widths[k]
    const mix = { value = table.create(channels), left = table.create(channels), right = table.create(channels) }

    for c = 1, channels do
      mix.value[c] = flatten(indexed(widen.value[c], index))
      mix.left[c] = flatten(indexed(widen.left[c], index))
      mix.right[c] = flatten(indexed(widen.right[c], index))
    end

    k.mix = if plain(mix, i, k.envelope) then nil else mix
  end

  return keys
end

-- the mix of key `i` blended from `a` toward `b` by `t`, each part's pairs
-- weighted by its side's share; nil when both widen as stored keys do, which
-- the blended envelope already is
function value_curve.mixOf(a: Key, b: Key, i: number, t: number, channels: number): Mix?
  if a.mix == nil and b.mix == nil then
    return nil
  end

  const out = { value = table.create(channels), left = table.create(channels), right = table.create(channels) }

  for _, part in { "value", "left", "right" } do
    for c = 1, channels do
      const terms: { [number]: number } = {}

      for _, side in { { a, 1 - t }, { b, t } } do
        const k, share = side[1] :: Key, side[2] :: number
        const pairs = if k.mix ~= nil then (k.mix :: any)[part][c] elseif part == "value" then { i, k.envelope } else {}

        for at = 1, #pairs, 2 do
          terms[pairs[at]] = (terms[pairs[at]] or 0) + pairs[at + 1] * share
        end
      end

      (out :: any)[part][c] = flatten(terms)
    end
  end

  return out
end

-- a copy of the curve with a key at `time`, drawing the same curve
function value_curve.split(curve: Curve, time: number): Curve
  const widths = {}
  const extra = { time }

  for _, k in curve.keys do
    if k.time == time then
      table.clear(extra)
      break
    end
  end

  return {
    channels = curve.channels,
    linked = curve.linked,
    keys = settle(withTimes(curve, extra, widths), widths, curve.channels),
    exact = true,
  }
end

-- the times of `other`'s keys that `own` has no key at, both sorted
const function missing(own: { Key }, other: { Key }): { number }
  const out = {}

  local i = 1

  for _, k in other do
    const time = k.time

    while own[i] ~= nil and own[i].time < time do
      i += 1
    end

    if (own[i] == nil or own[i].time ~= time) and out[#out] ~= time then
      table.insert(out, time)
    end
  end

  return out
end

-- the keys of one time, `count` of them from `at`, made `want` by copying the
-- last into keys of no width between, which the sampler never reads inside
const function pad(
  keys: { Key },
  at: number,
  count: number,
  want: number,
  channels: number,
  out: { Key },
  widths: Widths
)
  for i = at, at + count - 2 do
    table.insert(out, keys[i])
  end

  const last = keys[at + count - 1]

  for copy = 1, want - count do
    const made = still(last, last.time, channels, widths)

    if copy == 1 then
      made.left = last.left
      widths[made].left = widths[last].left
    end

    table.insert(out, made)
  end

  if want > count then
    last.left = table.create(channels, vector.zero)
    widths[last].left = emptyOf(channels)
  end

  table.insert(out, last)
end

-- how many keys from `at` share its time
const function run(keys: { Key }, at: number)
  local count = 1

  while keys[at + count] ~= nil and keys[at + count].time == keys[at].time do
    count += 1
  end

  return count
end

-- both curves' keys on one set of times, the union of theirs, each drawing
-- the curve it was. key i of one sits at the time of key i of the other, and
-- a key either adds widens as the keys it came from do, on the draws of the
-- keys at the same index. the keys draw their curve only through an exact
-- sampler, as their handles may reach past their segments
function value_curve.align(a: Curve, b: Curve): ({ Key }, { Key })
  const channels = a.channels
  const widths = {}
  const ka = withTimes(a, missing(a.keys, b.keys), widths)
  const kb = withTimes(b, missing(b.keys, a.keys), widths)
  const outA = table.create(#ka)
  const outB = table.create(#kb)

  local i, j = 1, 1

  while ka[i] ~= nil and kb[j] ~= nil do
    const na, nb = run(ka, i), run(kb, j)
    const want = math.max(na, nb)

    pad(ka, i, na, want, channels, outA, widths)
    pad(kb, j, nb, want, channels, outB, widths)

    i += na
    j += nb
  end

  return settle(outA, widths, channels), settle(outB, widths, channels)
end

return value_curve
