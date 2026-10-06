--!native
--!optimize 2
local path = require("@mod/common/path")
local curves = require("@mod/curves")
local logger = require("@mod/logger")

local timing_common = require("@mod/common/timing")

-- the content keyed shapes held at once, the least recently used going first
local LIMIT = 256

-- the even steps of time a shape's table holds a cubic for
local GRID = 64

-- how many points inside a step its cubic is checked at, and how far off the
-- curve it may be there before that step is solved outright instead
local CHECKS = 4
local FIT = 1e-6

local ROUNDS = 24
local TOLERANCE = 1e-9

export type Shape = {
  -- the chain, y up, one array per axis
  xs: { number },
  ys: { number },
  segments: number,

  -- four coefficients a step of time, built by the first `at`, or at load
  -- for a preset
  steps: { number }?,

  key: string?,
  used: number,
}

local Curve = {}
Curve.__index = Curve

export type Curve = typeof(setmetatable({} :: { duration: number, shape: Shape?, fn: ((t: number) -> number)? }, Curve))

local curve = {}

-- the four presets, built whole at load and frozen through, since every
-- effect shares them and an author's sdk.curve hands one out
local Presets: { [string]: Shape } = {}

-- every other shape by its content, in one budget of LIMIT
local Paths: { [string]: Shape } = {}
local Chains: { [string]: Shape } = {}

-- what a buffer or a chain table already resolved to, in front of the content
-- keys. weak keyed, so caching one never keeps it alive
local Buffers: { [buffer]: Shape } = setmetatable({}, { __mode = "k" }) :: any
local Tables: { [{ vector }]: Shape } = setmetatable({}, { __mode = "k" }) :: any

-- a preset's name by its serialized bytes, so a row holding a preset's value
-- shares the preset's shape
local Named: { [string]: string } = {}

for name, serialized in curves.PRESETS do
  Named[serialized] = name
end

local held = 0
local clock = 0

-- the linear preset's value is its time, so it is answered without a solve
local function linear(t: number): number
  return math.clamp(t, 0, 1)
end

local function cubic(a: number, b: number, c: number, d: number, s: number): number
  local r = 1 - s

  return r * r * r * a + 3 * r * r * s * b + 3 * r * s * s * c + s * s * s * d
end

local function slope(a: number, b: number, c: number, d: number, s: number): number
  local r = 1 - s

  return 3 * r * r * (b - a) + 6 * r * s * (c - b) + 3 * s * s * (d - c)
end

local function evict()
  local oldest: Shape? = nil

  for _, shape in Paths do
    if oldest == nil or shape.used < oldest.used then
      oldest = shape
    end
  end

  for _, shape in Chains do
    if oldest == nil or shape.used < oldest.used then
      oldest = shape
    end
  end

  if oldest == nil then
    return
  end

  local key = oldest.key :: string

  if Paths[key] == oldest then
    Paths[key] = nil
  else
    Chains[key] = nil
  end

  held -= 1
end

local function keep(store: { [string]: Shape }, key: string, shape: Shape)
  if held >= LIMIT then
    evict()
  end

  shape.key = key
  store[key] = shape
  held += 1
end

local function touch(shape: Shape): Shape
  clock += 1
  shape.used = clock

  return shape
end

local function build(xs: { number }, ys: { number }): Shape
  return { xs = xs, ys = ys, segments = (#xs - 1) // 3, steps = nil, key = nil, used = 0 }
end

-- a serialized path, y down, as a shape, y up. a value too short to hold a
-- segment reads as 1 at every time, which is what the old solve made of one,
-- so a row or a mesh profile holding such a value keeps playing as it did
local function decode(serialized: string): Shape
  local points = path.deserializePath(serialized)

  if #points < 4 or (#points - 1) % 3 ~= 0 then
    return build({ 0, 1 / 3, 2 / 3, 1 }, { 1, 1, 1, 1 })
  end

  local xs = table.create(#points)
  local ys = table.create(#points)

  for i, point in points do
    xs[i] = point.x
    ys[i] = 1 - point.y
  end

  return build(xs, ys)
end

-- why a chain cannot be a curve, or nil when it can: 2 or 3n + 1 points, time
-- from 0 to 1, every anchor at or after the one before it and every handle
-- between its own segment's anchors, so time only moves forward
local function refusal(chain: { vector }): string?
  local count = #chain

  if count ~= 2 and (count < 4 or (count - 1) % 3 ~= 0) then
    return `a curve takes 2 or 3n + 1 points, got {count}`
  end

  if chain[1].x ~= 0 or chain[count].x ~= 1 then
    return `a curve's time runs from 0 to 1, got {chain[1].x} to {chain[count].x}`
  end

  for i = 1, count - 3, 3 do
    local from = chain[i].x
    local to = chain[i + 3].x

    if to < from then
      return `a curve's time moves backward at point {i + 3}`
    end

    for j = i + 1, i + 2 do
      local x = chain[j].x

      if x < from or x > to then
        return `a curve's handle at point {j} reaches outside its segment's time`
      end
    end
  end

  return nil
end

-- a straight chain gets its handles at the thirds, so its value is its time
local function fromChain(chain: { vector }): Shape
  if #chain == 2 then
    local a, b = chain[1], chain[2]

    return build(
      { a.x, a.x + (b.x - a.x) / 3, a.x + (b.x - a.x) * 2 / 3, b.x },
      { a.y, a.y + (b.y - a.y) / 3, a.y + (b.y - a.y) * 2 / 3, b.y }
    )
  end

  local xs = table.create(#chain)
  local ys = table.create(#chain)

  for i, point in chain do
    xs[i] = point.x
    ys[i] = point.y
  end

  return build(xs, ys)
end

-- a chain's content, for one built anew with the same numbers
local function keyOf(chain: { vector }): string
  local parts = table.create(#chain * 2)

  for i, point in chain do
    parts[i * 2 - 1] = string.format("%.9g", point.x)
    parts[i * 2] = string.format("%.9g", point.y)
  end

  return table.concat(parts, ",")
end

local function fromPath(serialized: string): Shape
  local name = Named[serialized]

  if name ~= nil then
    return Presets[name]
  end

  local found = Paths[serialized]

  if found ~= nil then
    return touch(found)
  end

  local shape = decode(serialized)

  keep(Paths, serialized, shape)

  return touch(shape)
end

-- the shape data a curve shares with every other curve of the same content
local function shapeOf(shape: any): Shape
  local kind = typeof(shape)

  if kind == "string" then
    if curves.PRESETS[shape] ~= nil then
      return Presets[shape]
    end

    return fromPath(shape)
  end

  if kind == "buffer" then
    local found = Buffers[shape]

    if found ~= nil and found.key == nil then
      return found
    end

    if found ~= nil and Paths[found.key :: string] == found then
      return touch(found)
    end

    local made = fromPath(buffer.tostring(shape))
    Buffers[shape] = made

    return made
  end

  if kind == "table" then
    local found = Tables[shape]

    if found ~= nil and Chains[found.key :: string] == found then
      return touch(found)
    end

    local reason = refusal(shape)

    if reason ~= nil then
      logger.error(reason)
    end

    local key = keyOf(shape)
    local made = Chains[key]

    if made == nil then
      made = fromChain(shape)
      keep(Chains, key, made :: Shape)
    end

    Tables[shape] = made :: Shape

    return touch(made :: Shape)
  end

  logger.error(`a curve's shape is a preset, a serialized path, a chain or a function, got {kind}`)
end

-- the segment whose anchors hold t, the first that does, else the last
local function segmentOf(xs: { number }, last: number, t: number): number
  for k = 0, last do
    if t >= xs[k * 3 + 1] and t < xs[k * 3 + 4] then
      return k
    end
  end

  return last
end

-- the value at time t solved outright: the segment's parameter by newton from
-- a straight guess inside it, the way the editor's curves were always solved,
-- run until it settles. the slope of the value over time is the second answer
local function exact(shape: Shape, t: number): (number, number)
  local xs, ys = shape.xs, shape.ys
  local i = segmentOf(xs, shape.segments - 1, t) * 3 + 1
  local x0, x1, x2, x3 = xs[i], xs[i + 1], xs[i + 2], xs[i + 3]
  local s = if t >= x0 and t < x3 then (t - x0) / (x3 - x0) else 1

  for _ = 1, ROUNDS do
    local dx = slope(x0, x1, x2, x3, s)

    if dx == 0 then
      break
    end

    local ds = (cubic(x0, x1, x2, x3, s) - t) / dx

    s -= ds

    if s < 0 then
      s = 0
    elseif s > 1 then
      s = 1
    end

    if ds < TOLERANCE and ds > -TOLERANCE then
      break
    end
  end

  local y0, y1, y2, y3 = ys[i], ys[i + 1], ys[i + 2], ys[i + 3]
  local dx = slope(x0, x1, x2, x3, s)

  return cubic(y0, y1, y2, y3, s), if dx ~= 0 then slope(y0, y1, y2, y3, s) / dx else math.huge
end

-- each step of time as a cubic in its own fraction, from the values and slopes
-- at its two ends, or nan where that cubic strays from the curve: a segment
-- ending inside the step, or a turn too sharp to follow
local function tabled(shape: Shape): { number }
  local h = 1 / GRID
  local last = shape.segments - 1
  local values = table.create(GRID + 1)
  local slopes = table.create(GRID + 1)
  local cells = table.create(GRID + 1)

  for g = 0, GRID do
    values[g + 1], slopes[g + 1] = exact(shape, g * h)
    cells[g + 1] = segmentOf(shape.xs, last, g * h)
  end

  local steps = table.create(GRID * 4)

  for g = 0, GRID - 1 do
    local y0, y1 = values[g + 1], values[g + 2]
    local m0, m1 = slopes[g + 1] * h, slopes[g + 2] * h
    local c = 3 * (y1 - y0) - 2 * m0 - m1
    local d = 2 * (y0 - y1) + m0 + m1
    local fits = cells[g + 1] == cells[g + 2] and m0 == m0 and c == c and d == d

    for probe = 1, CHECKS do
      if not fits then
        break
      end

      local u = probe / (CHECKS + 1)

      fits = math.abs(y0 + u * (m0 + u * (c + u * d)) - exact(shape, (g + u) * h)) <= FIT
    end

    steps[g * 4 + 1] = if fits then y0 else 0 / 0
    steps[g * 4 + 2] = m0
    steps[g * 4 + 3] = c
    steps[g * 4 + 4] = d
  end

  shape.steps = steps

  return steps
end

-- a shape with its table built, frozen through, so whoever holds it can change
-- nothing another curve reads
local function sealed(shape: Shape): Shape
  table.freeze(shape.xs)
  table.freeze(shape.ys)
  table.freeze(shape.steps or tabled(shape))

  return table.freeze(shape)
end

for name, serialized in curves.PRESETS do
  Presets[name] = sealed(decode(serialized))
end

-- the value at time t: its step's cubic where that follows the curve, else the
-- curve solved outright
local function solve(shape: Shape, t: number): number
  if t ~= t then
    return t
  end

  if t < 0 then
    t = 0
  elseif t > 1 then
    t = 1
  end

  local steps = shape.steps or tabled(shape)
  local g = t * GRID
  local cell = g // 1

  if cell >= GRID then
    cell = GRID - 1
  end

  local base = cell * 4
  local a = steps[base + 1]

  if a == a then
    local u = g - cell

    return a + u * (steps[base + 2] + u * (steps[base + 3] + u * steps[base + 4]))
  end

  return (exact(shape, t))
end

-- a curve over `duration` seconds. `shape` is a preset's name, a curve row's
-- serialized path as a string or a buffer, a chain of 2D vectors (x is time and
-- y the value, y up, z ignored) or a function of time
function curve.new(duration: number, shape: string | buffer | { vector } | (t: number) -> number): Curve
  local d = timing_common.duration(duration)

  if typeof(shape) == "function" then
    return setmetatable({ duration = d, shape = nil, fn = shape }, Curve)
  end

  if shape == "linear" or shape == curves.PRESETS.linear then
    return setmetatable({ duration = d, shape = nil, fn = linear }, Curve)
  end

  return setmetatable({ duration = d, shape = shapeOf(shape), fn = nil }, Curve)
end

-- a curve no holder can change: a preset's shape as every curve shares it, and
-- any other a frozen copy of the shape it shares, which the cache behind it
-- still writes to. for an author's curve, never for an effect's own
function curve.frozen(duration: number, shape: string | buffer | { vector } | (t: number) -> number): Curve
  local made = curve.new(duration, shape)
  local shared = made.shape

  if shared ~= nil and not table.isfrozen(shared) then
    made.shape = sealed({
      xs = table.clone(shared.xs),
      ys = table.clone(shared.ys),
      segments = shared.segments,
      steps = table.clone(shared.steps or tabled(shared)),
      key = nil,
      used = 0,
    })
  end

  return table.freeze(made)
end

-- a shape's value at t with no curve made, for a caller sampling a row's
-- curve once per value
function curve.sample(shape: string | buffer | { vector }, t: number): number
  return solve(shapeOf(shape), t)
end

-- the same read as curve.sample with the shape looked up once, for a caller
-- sampling one shape every frame
function curve.sampler(shape: string | buffer | { vector }): (t: number) -> number
  local resolved = shapeOf(shape)

  return function(t: number): number
    return solve(resolved, t)
  end
end

-- the value at t, 0 to 1 over the curve
function Curve.at(self: Curve, t: number): number
  if t ~= t then
    return t
  end

  local fn = self.fn

  if fn ~= nil then
    return fn(t)
  end

  return solve(self.shape :: Shape, t)
end

-- shared by every effect's curves, and an author's sdk.curve hands it out
table.freeze(Curve)

return curve
