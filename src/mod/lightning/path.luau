export type Fork = {
  root: number,
  angle: number,
  turn: number,
  share: number,
  target: vector?,
}
export type Shape = {
  detail: number,
  forkDetail: number,
  forks: { Fork },
  offsets: { { vector } },
  waves: { { number } },
}
export type Fitted = { { vector } }

const FIRST_ROOT = 3
const FIRST_KINK = 0.75
const DECAY = 0.9
const TINY = 1e-9
const UP = vector.create(0, 1, 0)
const SIDE = vector.create(1, 0, 0)
const NEAR_VERTICAL = math.cos(math.rad(25))
const REFIT_DISTANCE = 0.01
const CARRY_MIN = 1e-3

-- weights sum to 1 and frequencies are cycles per bolt length, which keeps a joint at speed 2 under a twentieth of jagged per millisecond
const OCTAVES = {
  { weight = 0.55, low = 0.8, high = 1.4 },
  { weight = 0.3, low = 1.8, high = 2.8 },
  { weight = 0.15, low = 3.5, high = 4.5 },
}
const WAVE_STRIDE = 4

const path = {}

path.FORK_MIN = math.rad(25)
path.FORK_MAX = math.rad(60)

const function between(next: () -> number, min: number, max: number): number
  return min + (max - min) * next()
end

const function within(offset: vector, bound: number): vector
  const size = vector.magnitude(offset)

  if size <= bound then
    return offset
  end

  return offset * (bound / size)
end

const function subdivide(values: { vector }, low: number, high: number, amplitude: number, next: () -> number)
  if high - low < 2 then
    return
  end

  const mid = (low + high) // 2
  const average = (values[low] + values[high]) * 0.5

  values[mid] = average + vector.create(between(next, -1, 1), between(next, -1, 1), 0) * amplitude

  subdivide(values, low, mid, amplitude * DECAY, next)
  subdivide(values, mid, high, amplitude * DECAY, next)
end

-- the finer levels keep most of the one above, so the sum can pass jagged and is clamped to it
const function zigzag(joints: { vector }, segments: number, next: () -> number, jagged: number)
  joints[1] = vector.zero
  joints[segments + 1] = vector.zero

  subdivide(joints, 1, segments + 1, jagged * FIRST_KINK, next)

  for i = 2, segments do
    joints[i] = within(joints[i] * math.sin(math.pi * (i - 1) / segments), jagged)
  end
end

const function fill(shape: Shape, next: () -> number, jagged: number)
  for c = 1, #shape.forks + 1 do
    const segments = if c == 1 then shape.detail else shape.forkDetail
    const joints = shape.offsets[c] or table.create(segments + 1, vector.zero)

    zigzag(joints, segments, next, jagged)

    shape.offsets[c] = joints
  end
end

const function wavesOf(chains: number, next: () -> number): { { number } }
  const waves = table.create(chains)

  for c = 1, chains do
    const wave = table.create(#OCTAVES * WAVE_STRIDE)

    for _, octave in OCTAVES do
      table.insert(wave, between(next, octave.low, octave.high))
      table.insert(wave, octave.weight * between(next, 0.75, 1))
      table.insert(wave, between(next, 0, 2 * math.pi))
      table.insert(wave, between(next, 0, 2 * math.pi))
    end

    waves[c] = wave
  end

  return waves
end

function path.make(
  next: () -> number,
  spec: { detail: number, forks: number, forkLength: number, jagged: number }
): Shape
  const detail = spec.detail
  const forks = {}
  const lastRoot = detail - 1
  const count = if lastRoot >= FIRST_ROOT then spec.forks else 0

  for i = 1, count do
    forks[i] = {
      root = math.min(lastRoot, FIRST_ROOT + math.floor(next() * (lastRoot - FIRST_ROOT + 1))),
      angle = between(next, path.FORK_MIN, path.FORK_MAX),
      turn = between(next, 0, 2 * math.pi),
      share = spec.forkLength * between(next, 0.6, 1),
    }
  end

  const shape: Shape = {
    detail = detail,
    forkDetail = math.max(2, detail // 2),
    forks = forks,
    offsets = {},
    waves = wavesOf(count + 1, next),
  }

  fill(shape, next, spec.jagged)

  return shape
end

function path.jitter(shape: Shape, next: () -> number, jagged: number)
  fill(shape, next, jagged)
end

function path.flow(shape: Shape, t: number, speed: number, jagged: number)
  const shift = speed * t

  for c, joints in shape.offsets do
    const wave = shape.waves[c]
    const segments = #joints - 1

    joints[1] = vector.zero
    joints[segments + 1] = vector.zero

    for i = 2, segments do
      const along = (i - 1) / segments
      const at = 2 * math.pi * (along - shift)
      local x = 0
      local y = 0

      for k = 1, #wave, WAVE_STRIDE do
        const phase = at * wave[k]
        const amplitude = wave[k + 1]

        x += amplitude * math.sin(phase + wave[k + 2])
        y += amplitude * math.sin(phase + wave[k + 3])
      end

      joints[i] = within(vector.create(x, y, 0) * (jagged * math.sin(math.pi * along)), jagged)
    end
  end
end

-- two perpendiculars to the main bolt's chord, from a fixed reference so its offsets do not flip between frames
const function frame(direction: vector): (vector, vector)
  const reference = if math.abs(vector.dot(direction, UP)) > NEAR_VERTICAL then SIDE else UP
  const first = vector.normalize(vector.cross(direction, reference))

  return first, vector.cross(direction, first)
end

-- an axis carried onto the plane across a direction, so a fork's frame turns with the main bolt's: crossing a fixed
-- reference flipped a fork whenever it swung through the cone, and a reference picked for the whole bolt was
-- ill-conditioned once the bolt tilted, both jumping a flowing fork's joints by studs in a millisecond (2026-10-24)
const function carry(axis: vector, spare: vector, direction: vector): vector
  local flat = axis - direction * vector.dot(axis, direction)

  -- only a latched fork can run along the axis itself
  if vector.magnitude(flat) < CARRY_MIN then
    flat = spare - direction * vector.dot(spare, direction)
  end

  return vector.normalize(flat)
end

const function unit(v: vector): vector
  if vector.magnitude(v) < TINY then
    return UP
  end

  return vector.normalize(v)
end

const function lay(chain: { vector }, offsets: { vector }, from: vector, to: vector, first: vector, second: vector)
  const joints = #offsets
  const span = to - from
  const length = vector.magnitude(span)

  for i = 1, joints do
    chain[i] = from + span * ((i - 1) / (joints - 1)) + (first * offsets[i].x + second * offsets[i].y) * length
  end

  chain[1] = from
  chain[joints] = to

  for i = joints + 1, #chain do
    chain[i] = nil
  end
end

const function layForks(shape: Shape, fitted: Fitted, length: number, first: vector, second: vector)
  const main = fitted[1]

  for i, fork in shape.forks do
    const chain = fitted[i + 1] or {}
    const root = main[fork.root]
    const tangent = unit(main[fork.root + 1] - main[fork.root - 1])
    const across = carry(first, second, tangent)
    const sideways = vector.cross(tangent, across)
    const around = across * math.cos(fork.turn) + sideways * math.sin(fork.turn)
    const direction = tangent * math.cos(fork.angle) + around * math.sin(fork.angle)
    const finishAt = fork.target or root + direction * (length * fork.share)
    const along = unit(finishAt - root)
    const forkFirst = carry(across, sideways, along)

    fitted[i + 1] = chain

    lay(chain, shape.offsets[i + 1], root, finishAt, forkFirst, vector.cross(along, forkFirst))
  end

  for i = #shape.forks + 2, #fitted do
    fitted[i] = nil
  end
end

function path.fit(shape: Shape, origin: vector, finish: vector, out: Fitted?): Fitted
  const fitted: Fitted = out or {}
  const main = fitted[1] or {}
  const first, second = frame(unit(finish - origin))

  fitted[1] = main

  lay(main, shape.offsets[1], origin, finish, first, second)
  layForks(shape, fitted, vector.magnitude(finish - origin), first, second)

  return fitted
end

-- the forks laid again from the main chain as it now stands, so a main bolt moved after its fit carries their roots
function path.forks(shape: Shape, origin: vector, finish: vector, fitted: Fitted)
  const first, second = frame(unit(finish - origin))

  layForks(shape, fitted, vector.magnitude(finish - origin), first, second)
end

function path.spread(up: vector, right: vector, look: vector, spread: vector, next: () -> number): vector
  const about = math.rad(spread.x) * between(next, -1, 1)
  const around = math.rad(spread.y) * between(next, -1, 1)
  const tilted = up * math.cos(about)
    + vector.cross(right, up) * math.sin(about)
    + right * (vector.dot(right, up) * (1 - math.cos(about)))

  return tilted * math.cos(around)
    + vector.cross(look, tilted) * math.sin(around)
    + look * (vector.dot(look, tilted) * (1 - math.cos(around)))
end

function path.refits(last: vector, now: vector): boolean
  return vector.magnitude(now - last) > REFIT_DISTANCE
end

return path
