--!native
--!optimize 2
local logger = require("@mod/logger")

-- 5 point gauss legendre on 0 to 1: where the speed is taken, and how much
-- each sample counts
local NODES = { 0.046910077030668, 0.230765344947158, 0.5, 0.769234655052842, 0.953089922969332 }
local WEIGHTS = { 0.118463442528095, 0.239314335249683, 0.284444444444444, 0.239314335249683, 0.118463442528095 }

-- the stretches of a segment its length is taken over, each by one
-- quadrature, so a sharp turn is still measured within 0.1%
local PARTS = 16

-- newton rounds for the point a given way along a stretch
local ROUNDS = 4

local Bezier = {}
Bezier.__index = Bezier

export type Bezier = typeof(setmetatable(
  {} :: {
    -- how many points were handed in, and the chain as stepped: a straight
    -- one gets its handles at the thirds
    given: number,
    points: { vector },
    segments: number,

    -- each stretch's length in studs, each segment's, the running total
    -- before each segment and which segments moved since they were measured
    parts: { number },
    lengths: { number },
    before: { number },
    moved: { boolean },
    stale: boolean,
    total: number,

    -- the last share `seek` found and where it found it, so a point and the
    -- tangent there cost one search
    sought: number,
    soughtK: number,
    soughtS: number,
  },
  Bezier
))

local function point(p0: vector, p1: vector, p2: vector, p3: vector, s: number): vector
  local r = 1 - s

  return p0 * (r * r * r) + p1 * (3 * r * r * s) + p2 * (3 * r * s * s) + p3 * (s * s * s)
end

local function velocity(p0: vector, p1: vector, p2: vector, p3: vector, s: number): vector
  local r = 1 - s

  return (p1 - p0) * (3 * r * r) + (p2 - p1) * (6 * r * s) + (p3 - p2) * (3 * s * s)
end

-- a segment's length between its parameters a and b
local function arc(p0: vector, p1: vector, p2: vector, p3: vector, a: number, b: number): number
  local range = b - a
  local sum = 0

  for n = 1, 5 do
    sum += WEIGHTS[n] * vector.magnitude(velocity(p0, p1, p2, p3, a + NODES[n] * range))
  end

  return sum * range
end

local function check(points: { vector })
  local count = #points

  if count ~= 2 and (count < 4 or (count - 1) % 3 ~= 0) then
    logger.error(`a bezier takes 2 or 3n + 1 points, got {count}`)
  end
end

-- the chain into the curve's own array, a straight one as one segment with
-- its handles at the thirds
local function copy(points: { vector }, into: { vector })
  if #points == 2 then
    local a, b = points[1], points[2]

    into[1] = a
    into[2] = a + (b - a) / 3
    into[3] = a + (b - a) * (2 / 3)
    into[4] = b

    return
  end

  for i, p in points do
    into[i] = p
  end
end

-- every array the curve reads, made for this many points and kept while the
-- count stays
local function size(self: Bezier, points: { vector })
  local count = #points
  local segments = if count == 2 then 1 else (count - 1) // 3

  self.given = count
  self.points = table.create(segments * 3 + 1)
  self.segments = segments
  self.parts = table.create(segments * PARTS, 0)
  self.lengths = table.create(segments, 0)
  self.before = table.create(segments, 0)
  self.moved = table.create(segments, true)
  self.stale = true
  self.total = 0
  self.sought = -1
  self.soughtK = 1
  self.soughtS = 0

  copy(points, self.points)
end

-- a curve through a chain: an anchor, its outgoing handle, the next anchor's
-- incoming handle, the next anchor and so on, 3n + 1 points with handles as
-- positions; or 2 points, a straight segment
function Bezier.new(points: { vector }): Bezier
  check(points)

  local self = setmetatable({} :: any, Bezier)

  size(self, points)

  return self
end

-- new points for the curve, in the same format. a segment whose four points
-- all stayed keeps its length, and nothing is measured until a read asks
function Bezier.set(self: Bezier, points: { vector })
  if #points ~= self.given then
    check(points)
    size(self, points)

    return
  end

  local kept = self.points
  local moved = self.moved

  if self.given == 2 then
    if kept[1] ~= points[1] or kept[4] ~= points[2] then
      copy(points, kept)
      moved[1] = true
      self.stale = true
    end

    return
  end

  for k = 1, self.segments do
    local i = k * 3 - 2

    if
      kept[i] ~= points[i]
      or kept[i + 1] ~= points[i + 1]
      or kept[i + 2] ~= points[i + 2]
      or kept[i + 3] ~= points[i + 3]
    then
      moved[k] = true
      self.stale = true
    end
  end

  copy(points, kept)
end

-- the segment at t, 0 to 1 over the whole chain with every segment an equal
-- share, and the parameter inside it
local function locate(self: Bezier, t: number): (number, number)
  local segments = self.segments

  if t <= 0 then
    return 1, 0
  end

  if t >= 1 then
    return segments, 1
  end

  local scaled = t * segments
  local k = scaled // 1

  return k + 1, scaled - k
end

-- the point at t, 0 to 1 over the whole chain with every segment an equal share
function Bezier.at(self: Bezier, t: number): vector
  local k, s = locate(self, t)
  local i = k * 3 - 2
  local points = self.points

  return point(points[i], points[i + 1], points[i + 2], points[i + 3], s)
end

-- the unit direction of travel at parameter s of segment k, or zero where
-- the curve stands still
local function heading(points: { vector }, k: number, s: number): vector
  local i = k * 3 - 2
  local v = velocity(points[i], points[i + 1], points[i + 2], points[i + 3], s)
  local speed = vector.magnitude(v)

  if speed == 0 then
    return vector.zero
  end

  return v / speed
end

-- the unit direction of travel at t, or zero where the curve stands still
function Bezier.tangent(self: Bezier, t: number): vector
  local k, s = locate(self, t)

  return heading(self.points, k, s)
end

-- every moved segment measured again, stretch by stretch, and the running
-- totals redone
local function measure(self: Bezier)
  local points = self.points
  local parts = self.parts
  local lengths = self.lengths
  local before = self.before
  local moved = self.moved
  local total = 0

  for k = 1, self.segments do
    if moved[k] then
      local i = k * 3 - 2
      local p0, p1, p2, p3 = points[i], points[i + 1], points[i + 2], points[i + 3]
      local sum = 0

      for j = 1, PARTS do
        local part = arc(p0, p1, p2, p3, (j - 1) / PARTS, j / PARTS)

        parts[(k - 1) * PARTS + j] = part
        sum += part
      end

      lengths[k] = sum
      moved[k] = false
    end

    before[k] = total
    total += lengths[k]
  end

  self.total = total
  self.stale = false
  self.sought = -1
end

-- the length in studs
function Bezier.length(self: Bezier): number
  if self.stale then
    measure(self)
  end

  return self.total
end

-- the segment u of the way along a measured chain of some length by
-- distance, inside 0 to 1, and the parameter inside it
local function seek(self: Bezier, u: number): (number, number)
  if u == self.sought then
    return self.soughtK, self.soughtS
  end

  local want = u * self.total
  local before = self.before
  local low, high = 1, self.segments

  while low < high do
    local middle = (low + high + 1) // 2

    if before[middle] <= want then
      low = middle
    else
      high = middle - 1
    end
  end

  local k = low
  local parts = self.parts
  local base = (k - 1) * PARTS
  local j = 1

  want -= before[k]

  while j < PARTS and parts[base + j] < want do
    want -= parts[base + j]
    j += 1
  end

  local part = parts[base + j]
  local from = (j - 1) / PARTS
  local to = j / PARTS
  local i = k * 3 - 2
  local points = self.points
  local p0, p1, p2, p3 = points[i], points[i + 1], points[i + 2], points[i + 3]
  local s = from + (if part > 0 then math.min(want / part, 1) else 0) / PARTS

  -- newton inside the stretch, from where it would be at an even speed
  for _ = 1, ROUNDS do
    local speed = vector.magnitude(velocity(p0, p1, p2, p3, s))

    if speed == 0 then
      break
    end

    s -= (arc(p0, p1, p2, p3, from, s) - want) / speed

    if s < from then
      s = from
    elseif s > to then
      s = to
    end
  end

  self.sought, self.soughtK, self.soughtS = u, k, s

  return k, s
end

-- the point u of the way along the curve by distance, 0 to 1
function Bezier.atUniform(self: Bezier, u: number): vector
  if self.stale then
    measure(self)
  end

  local points = self.points

  if self.total <= 0 or u <= 0 then
    return points[1]
  end

  if u >= 1 then
    return points[self.segments * 3 + 1]
  end

  local k, s = seek(self, u)
  local i = k * 3 - 2

  return point(points[i], points[i + 1], points[i + 2], points[i + 3], s)
end

-- the unit way segment k leaves its end (s = 1, from the anchor before) or
-- its start (s = 0) where its derivative vanishes, as a handle standing on
-- its anchor makes it: the limit of its direction, toward the nearest point
-- that differs, a segment of no length stepping on to its neighbor. zero for
-- a chain of no length
local function limit(self: Bezier, k: number, s: number): vector
  local points = self.points
  local ending = s >= 1

  while k >= 1 and k <= self.segments do
    local i = k * 3 - 2

    for j = 1, 3 do
      local way = if ending then points[i + 3] - points[i + 3 - j] else points[i + j] - points[i]
      local length = vector.magnitude(way)

      if length > 0 then
        return way / length
      end
    end

    k += if ending then -1 else 1
  end

  return vector.zero
end

-- the unit direction of travel u of the way along the curve by distance, 0
-- to 1, where it leaves a handle standing on its anchor too, or zero for a
-- curve of no length. a point on an anchor between segments is read on the
-- segment before it when `arriving`, as a walk forward reaches it, else on
-- the one after
function Bezier.tangentUniform(self: Bezier, u: number, arriving: boolean?): vector
  if self.stale then
    measure(self)
  end

  if self.total <= 0 then
    return vector.zero
  end

  local k, s = 1, 0

  if u >= 1 then
    k, s = self.segments, 1
  elseif u > 0 then
    k, s = seek(self, u)
  end

  if arriving and s <= 0 and k > 1 then
    k, s = k - 1, 1
  end

  local way = heading(self.points, k, s)

  if way ~= vector.zero then
    return way
  end

  return limit(self, k, s)
end

return Bezier
