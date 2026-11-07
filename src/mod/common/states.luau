const color = require("@mod/color/color")
const curves = require("@mod/curves")
const logger = require("@mod/logger")
const value_curve = require("@mod/value_curve")

type Key = value_curve.Key
type Curve = value_curve.Curve

export type Curves = {
  offset: Curve,
  turn: Curve,
  size: Curve,
  transparency: Curve,
  color: ColorSequence,
}

export type State = {
  time: number,
  offset: vector,
  turn: vector,
  size: vector,
  transparency: number,
  color: Color3,
  easing: string?,
}

export type Edit = {
  from: number?,
  time: number?,
  offset: vector?,
  turn: vector?,
  size: vector?,
  transparency: number?,
  color: Color3?,
  easing: string?,
  removed: boolean?,
}

-- the keys every row holds at one time, as indices into the row's keys
type Cluster = { time: number, keys: { [string]: { number } } }

-- a state as `apply` carries it: where it ends up, the cluster its keys come
-- from, the fields an edit set and the last edit that touched it
type Entry = {
  time: number,
  source: Cluster?,
  fields: { [string]: any },
  easing: string?,
  order: number,
  removed: boolean?,
}

-- a key of the curve `apply` builds; `from` is the input key it copies and
-- `prev` and `next` were that key's neighbors, all nil for a key it inserts
type Record = { key: Key, from: Key?, prev: Key?, next: Key?, seq: number }

-- a color keypoint `apply` builds, spelled as a keypoint so color reads it
type Point = { Time: number, Value: Color3, seq: number }

const MAX = 20
const MIXED = "Mixed"
const CUSTOM = "Custom"
const EPSILON = 1e-4

-- how near a segment's handles must sit to a preset's, once taken over the
-- segment's width and change, to read as it
const MATCH = 1e-3

const ROWS = { "offset", "turn", "size", "transparency" }
const FIELDS = { "offset", "turn", "size", "transparency", "color" }
const EASINGS = { "Linear", "EaseIn", "EaseOut", "EaseInOut" }
const PRESETS = { Linear = "linear", EaseIn = "easeIn", EaseOut = "easeOut", EaseInOut = "easeInOut" }

-- each easing's two inner control points, x in time and y in value, both
-- taken over a segment running from 0 to 1
const POINTS: { [string]: { vector } } = {}

for _, name in EASINGS do
  const points = curves.points(PRESETS[name])

  POINTS[name] = { points[2], points[3] }
end

const common = {}

common.EASINGS = EASINGS
common.MIXED = MIXED
common.CUSTOM = CUSTOM
common.MAX = MAX
common.EPSILON = EPSILON

-- a state's field as a row's channels
const function channelsOf(field: any, channels: number): { number }
  if channels == 1 then
    return { field :: number }
  end

  const v = field :: vector

  return { v.x, v.y, v.z }
end

-- a row's channels as a state's field
const function fieldOf(values: { number }, channels: number): any
  if channels == 1 then
    return values[1]
  end

  return vector.create(values[1], values[2], values[3])
end

const function differs(values: { number }, want: { number })
  for c, v in want do
    if math.abs(values[c] - v) >= EPSILON then
      return true
    end
  end

  return false
end

const function colorDiffers(a: Color3, b: Color3)
  return math.abs(a.R - b.R) >= EPSILON or math.abs(a.G - b.G) >= EPSILON or math.abs(a.B - b.B) >= EPSILON
end

const function timesOf(source: Curves, row: string): { number }
  const out = {}

  if row == "color" then
    for _, keypoint in source.color.Keypoints do
      table.insert(out, keypoint.Time)
    end
  else
    for _, k in ((source :: any)[row] :: Curve).keys do
      table.insert(out, k.time)
    end
  end

  return out
end

-- every key time across the rows, times closer than EPSILON to the first of
-- a run taken as that one, sorted
const function gather(source: Curves): { Cluster }
  const marks = {}

  for rank, row in FIELDS do
    for index, time in timesOf(source, row) do
      table.insert(marks, { time = time, rank = rank, index = index, row = row })
    end
  end

  table.sort(marks, function(a, b)
    if a.time ~= b.time then
      return a.time < b.time
    end

    if a.rank ~= b.rank then
      return a.rank < b.rank
    end

    return a.index < b.index
  end)

  const clusters: { Cluster } = {}

  local open: Cluster? = nil

  for _, mark in marks do
    if open == nil or mark.time - open.time >= EPSILON then
      open = { time = mark.time, keys = { offset = {}, turn = {}, size = {}, transparency = {}, color = {} } }
      table.insert(clusters, open :: Cluster)
    end

    table.insert((open :: Cluster).keys[mark.row], mark.index)
  end

  return clusters
end

-- a row's value at a cluster: its last key there, else its curve's reading
const function valueAt(curve: Curve, at: { number }, time: number): { number }
  if #at > 0 then
    return table.clone(curve.keys[at[#at]].value)
  end

  return value_curve.at(curve, time)
end

const function colorAt(keypoints: { ColorSequenceKeypoint }, at: { number }, time: number): Color3
  if #at > 0 then
    return keypoints[at[#at]].Value
  end

  return color.keypointsAt(keypoints, time)
end

-- the easing one channel of a segment traces; nil on a channel holding its
-- value, which has no shape to read
const function shapeOf(from: Key, into: Key, c: number): string?
  const width = into.time - from.time
  const change = into.value[c] - from.value[c]

  if width <= 0 or math.abs(change) < EPSILON then
    return nil
  end

  const leave, enter = from.right[c], into.left[c]
  const c1 = vector.create(leave.x / width, leave.y / change, 0)
  const c2 = vector.create(1 + enter.x / width, 1 + enter.y / change, 0)

  for _, name in EASINGS do
    const points = POINTS[name]

    if vector.magnitude(c1 - points[1]) < MATCH and vector.magnitude(c2 - points[2]) < MATCH then
      return name
    end
  end

  return CUSTOM
end

-- the easing of the segment arriving at `after`, voted by every channel of
-- every row with keys at both ends; the color blends linearly and never votes
const function easingOf(source: Curves, before: Cluster, after: Cluster): string
  local answer = nil

  for _, row in ROWS do
    const curve = (source :: any)[row] :: Curve
    const a, b = before.keys[row], after.keys[row]

    if #a == 0 or #b == 0 then
      continue
    end

    const from, into = curve.keys[a[#a]], curve.keys[b[1]]

    for c = 1, curve.channels do
      const vote = shapeOf(from, into, c)

      if vote == CUSTOM then
        return CUSTOM
      end

      if vote ~= nil then
        answer = if answer == nil or answer == vote then vote else MIXED
      end
    end
  end

  return answer or "Linear"
end

function common.read(source: Curves): { State }
  const clusters = gather(source)
  const keypoints = source.color.Keypoints
  const states = table.create(#clusters)

  for i, cluster in clusters do
    const time = cluster.time
    const state: any = {
      time = time,
      color = colorAt(keypoints, cluster.keys.color, time),
      easing = if i > 1 then easingOf(source, clusters[i - 1], cluster) else nil,
    }

    for _, row in ROWS do
      const curve = (source :: any)[row] :: Curve

      state[row] = fieldOf(valueAt(curve, cluster.keys[row], time), curve.channels)
    end

    states[i] = state :: State
  end

  return states
end

-- an edited time, inside a life, and on an end when within EPSILON of it
const function settle(time: number)
  const t = math.clamp(time, 0, 1)

  if t < EPSILON then
    return 0
  end

  if t > 1 - EPSILON then
    return 1
  end

  return t
end

-- the states the edits leave, sorted by time; of those landing within
-- EPSILON of one time, the one an edit touched last
const function entriesOf(clusters: { Cluster }, edits: { Edit }): { Entry }
  const entries: { Entry } = {}

  for _, cluster in clusters do
    table.insert(entries, { time = cluster.time, source = cluster, fields = {}, order = 0 })
  end

  for order, edit in edits do
    local entry: Entry? = nil

    if edit.from ~= nil then
      for _, e in entries do
        if e.source ~= nil and math.abs(e.source.time - edit.from) < EPSILON then
          entry = e
          break
        end
      end

      if entry == nil then
        logger.warn(`no state at {edit.from} to edit`)
        continue
      end
    elseif edit.time ~= nil then
      entry = { time = settle(edit.time), fields = {}, order = order }
      table.insert(entries, entry :: Entry)
    else
      logger.warn("a new state needs a time")
      continue
    end

    const e = entry :: Entry

    if edit.removed then
      e.removed = true
      continue
    end

    if edit.time ~= nil then
      e.time = settle(edit.time)
    end

    for _, field in FIELDS do
      const v = (edit :: any)[field]

      if v ~= nil then
        e.fields[field] = v
      end
    end

    if edit.easing ~= nil then
      e.easing = edit.easing
    end

    e.order = order
  end

  const live = {}

  for _, e in entries do
    if not e.removed then
      table.insert(live, e)
    end
  end

  table.sort(live, function(a: Entry, b: Entry)
    if a.time ~= b.time then
      return a.time < b.time
    end

    return a.order < b.order
  end)

  const kept: { Entry } = {}

  local start = -math.huge

  for _, e in live do
    if e.time - start >= EPSILON then
      start = e.time
      table.insert(kept, e)
    elseif e.order > kept[#kept].order then
      kept[#kept] = e
    end
  end

  return kept
end

const function copyKey(k: Key): Key
  return {
    time = k.time,
    value = table.clone(k.value),
    envelope = k.envelope,
    left = table.clone(k.left),
    right = table.clone(k.right),
  }
end

const function blankKey(time: number, value: { number }): Key
  const channels = #value

  return {
    time = time,
    value = value,
    envelope = 0,
    left = table.create(channels, vector.zero),
    right = table.create(channels, vector.zero),
  }
end

-- `from`'s handle on one side, `old` its neighbor there in the input, fit to
-- `new`, the neighbor `key` has there now: its time scaled by the new width
-- over the old and its value by the new change over the old, so the segment
-- keeps its shape. one that gains a neighbor it had none on starts flat, as a
-- held end that becomes a segment does in value_curve
const function fit(handle: vector, from: Key, old: Key?, key: Key, new: Key?, c: number)
  if new == nil then
    return handle
  end

  if old == nil then
    return vector.zero
  end

  const oldWidth = math.abs(old.time - from.time)
  const newWidth = math.abs(new.time - key.time)
  const oldChange = old.value[c] - from.value[c]
  const newChange = new.value[c] - key.value[c]

  local x, y = handle.x, handle.y

  if newWidth ~= oldWidth and oldWidth > 0 then
    x *= newWidth / oldWidth
  end

  if newChange ~= oldChange and math.abs(oldChange) >= EPSILON and math.abs(newChange) >= EPSILON then
    y *= newChange / oldChange
  end

  return vector.create(x, y, 0)
end

-- the curve the records draw, sorted by time, each copied key's handles fit
-- to the neighbors it has now
const function finish(curve: Curve, records: { Record }): Curve
  table.sort(records, function(a: Record, b: Record)
    if a.key.time ~= b.key.time then
      return a.key.time < b.key.time
    end

    return a.seq < b.seq
  end)

  const keys = table.create(#records)

  for i, r in records do
    const k, from = r.key, r.from

    keys[i] = k

    if from == nil then
      continue
    end

    const before = if records[i - 1] ~= nil then records[i - 1].key else nil
    const after = if records[i + 1] ~= nil then records[i + 1].key else nil

    for c = 1, curve.channels do
      k.left[c] = fit(from.left[c], from, r.prev, k, before, c)
      k.right[c] = fit(from.right[c], from, r.next, k, after, c)
    end
  end

  return { channels = curve.channels, linked = curve.linked, keys = keys, exact = curve.exact }
end

-- one row as the kept states leave it. a field with no key of its own at its
-- state inserts one only where the curve does not already read it, checked
-- again after every insert, since a key moves the readings around it
const function buildRow(curve: Curve, row: string, kept: { Entry }): Curve
  const channels = curve.channels
  const records: { Record } = {}
  const pending = {}

  local seq = 0

  for _, e in kept do
    const source = e.source
    const at = if source ~= nil then source.keys[row] else {}
    const moved = source ~= nil and e.time ~= source.time

    for _, i in at do
      const from = curve.keys[i]
      const k = copyKey(from)

      if moved then
        k.time = e.time
      end

      seq += 1
      table.insert(records, { key = k, from = from, prev = curve.keys[i - 1], next = curve.keys[i + 1], seq = seq })
    end

    const field = e.fields[row]

    if field == nil then
      continue
    end

    const want = channelsOf(field, channels)

    if #at == 0 then
      table.insert(pending, { time = e.time, value = want })
      continue
    end

    -- a channel within EPSILON keeps its value exactly
    const value = records[#records].key.value

    for c = 1, channels do
      if math.abs(want[c] - value[c]) >= EPSILON then
        value[c] = want[c]
      end
    end
  end

  while #pending > 0 do
    const drawn = if #records > 0 then finish(curve, records) else nil

    local picked = nil

    for i, p in pending do
      if drawn == nil or differs(value_curve.at(drawn, p.time), p.value) then
        picked = i
        break
      end
    end

    if picked == nil then
      break
    end

    const p = table.remove(pending, picked)

    seq += 1
    table.insert(records, { key = blankKey(p.time, p.value), seq = seq })
  end

  -- a curve needs a key, so a row left with none holds what it read at the
  -- first state left
  if #records == 0 then
    const first = kept[1]
    const time = if first ~= nil then first.time else 0
    const source = if first ~= nil then first.source else nil

    table.insert(records, {
      key = blankKey(time, value_curve.at(curve, if source ~= nil then source.time else time)),
      seq = 1,
    })
  end

  return finish(curve, records)
end

const function sortPoints(points: { Point })
  table.sort(points, function(a: Point, b: Point)
    if a.Time ~= b.Time then
      return a.Time < b.Time
    end

    return a.seq < b.seq
  end)
end

-- the color as the kept states leave it, its ends at 0 and 1 kept by taking
-- the nearest keypoint's color, which is what the state nearest them reads
const function buildColor(sequence: ColorSequence, kept: { Entry }): ColorSequence
  const keypoints = sequence.Keypoints
  const points: { Point } = {}
  const pending = {}

  local seq = 0

  for _, e in kept do
    const source = e.source
    const at = if source ~= nil then source.keys.color else {}
    const moved = source ~= nil and e.time ~= source.time

    for _, i in at do
      const keypoint = keypoints[i]

      seq += 1
      table.insert(points, { Time = if moved then e.time else keypoint.Time, Value = keypoint.Value, seq = seq })
    end

    const field = e.fields.color

    if field == nil then
      continue
    end

    if #at == 0 then
      table.insert(pending, { time = e.time, value = field })
    elseif colorDiffers(points[#points].Value, field) then
      points[#points].Value = field
    end
  end

  while #pending > 0 do
    sortPoints(points)

    local picked = nil

    for i, p in pending do
      if #points == 0 or colorDiffers(color.keypointsAt(points :: any, p.time), p.value) then
        picked = i
        break
      end
    end

    if picked == nil then
      break
    end

    const p = table.remove(pending, picked)

    seq += 1
    table.insert(points, { Time = p.time, Value = p.value, seq = seq })
  end

  sortPoints(points)

  if #points == 0 then
    table.insert(points, { Time = 0, Value = keypoints[1].Value, seq = 0 })
    table.insert(points, { Time = 1, Value = keypoints[#keypoints].Value, seq = 0 })
  end

  if points[1].Time ~= 0 then
    table.insert(points, 1, { Time = 0, Value = points[1].Value, seq = 0 })
  end

  if points[#points].Time ~= 1 then
    table.insert(points, { Time = 1, Value = points[#points].Value, seq = 0 })
  end

  const out = table.create(#points)

  for i, p in points do
    out[i] = ColorSequenceKeypoint.new(p.Time, p.Value)
  end

  return ColorSequence.new(out)
end

const function build(source: Curves, kept: { Entry }): Curves
  const out: any = { color = buildColor(source.color, kept) }

  for _, row in ROWS do
    out[row] = buildRow((source :: any)[row], row, kept)
  end

  return out :: Curves
end

-- the cluster holding `time`, as gather made them
const function clusterOf(clusters: { Cluster }, time: number): number?
  for i, cluster in clusters do
    if time >= cluster.time and time - cluster.time < EPSILON then
      return i
    end
  end

  return nil
end

-- each eased state's incoming handles on every row with keys at both ends, a
-- preset's control points taken over the segment's width and each channel's
-- change, so the curve stays linked
const function ease(result: Curves, clusters: { Cluster }, kept: { Entry })
  for _, e in kept do
    const points = if e.easing ~= nil then POINTS[e.easing] else nil
    const index = if points ~= nil then clusterOf(clusters, e.time) else nil

    if points == nil or index == nil or index == 1 then
      continue
    end

    const before, after = clusters[index - 1], clusters[index]

    for _, row in ROWS do
      const curve = (result :: any)[row] :: Curve
      const a, b = before.keys[row], after.keys[row]

      if #a == 0 or #b == 0 then
        continue
      end

      const from, into = curve.keys[a[#a]], curve.keys[b[1]]
      const width = into.time - from.time

      for c = 1, curve.channels do
        const change = into.value[c] - from.value[c]

        from.right[c] = vector.create(points[1].x * width, points[1].y * change, 0)
        into.left[c] = vector.create((points[2].x - 1) * width, (points[2].y - 1) * change, 0)
      end
    end
  end
end

function common.apply(source: Curves, edits: { Edit }): Curves
  local kept = entriesOf(gather(source), edits)
  local result = build(source, kept)
  local clusters = gather(result)

  if #clusters > MAX then
    logger.warn(`a mesh holds at most {MAX} states, so the {#clusters - MAX} latest before its end were left out`)
  end

  -- the last state always stands at the color's end, so the latest before it
  -- go, as many as it takes
  while #clusters > MAX do
    const left = {}

    for _, e in kept do
      const index = clusterOf(clusters, e.time)

      if index == nil or index < MAX or index == #clusters then
        table.insert(left, e)
      end
    end

    if #left == #kept then
      break
    end

    kept = left
    result = build(source, kept)
    clusters = gather(result)
  end

  ease(result, clusters, kept)

  return result
end

function common.pose(base: CFrame, offset: vector, turn: vector): CFrame
  return base
    * CFrame.new(offset.x, offset.y, offset.z)
    * CFrame.fromOrientation(math.rad(turn.x), math.rad(turn.y), math.rad(turn.z))
end

-- `degrees` moved by whole turns to the value nearest `near`
const function unwrap(degrees: number, near: number)
  return degrees + 360 * math.round((near - degrees) / 360)
end

function common.unpose(base: CFrame, cf: CFrame, near: vector): (vector, vector)
  const relative = base:ToObjectSpace(cf)
  const position = relative.Position
  const rx, ry, rz = relative:ToOrientation()
  const x, y, z = math.deg(rx), math.deg(ry), math.deg(rz)

  -- every turn has a second triple, its pitch past the quarter turn
  -- ToOrientation keeps it within
  const one = vector.create(unwrap(x, near.x), unwrap(y, near.y), unwrap(z, near.z))
  const other = vector.create(unwrap(180 - x, near.x), unwrap(y + 180, near.y), unwrap(z + 180, near.z))
  const turn = if vector.magnitude(other - near) < vector.magnitude(one - near) then other else one

  return vector.create(position.X, position.Y, position.Z), turn
end

return common
