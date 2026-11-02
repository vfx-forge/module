--!native
--!optimize 2
local shape = require("@mod/shape")

export type Gravity = { kind: "Gravity", target: vector, mass: number, softening: number }

-- `height` is where the piece's own ring sits along the axis, from the height
-- it spawned at climbing at `rise` studs per second; a path left without one
-- takes it from where it starts. `spin` is in turns per second
export type Orbit = {
  kind: "Orbit",
  center: vector,
  axis: vector,
  radius: number,
  spin: number,
  rise: number,
  capture: number,
  height: number?,
}

export type Force = Gravity | Orbit

-- a piece's rows over its life for a caller holding no track: each list
-- samples one row evenly from age 0 to `span`, keyed by what it drives,
-- `acceleration`, `drag` or a field of the force, and `since` is the age the
-- path starts at
export type Rows = { span: number, since: number, lists: { [string]: { any } } }

export type Config = {
  shape: string,
  surface: boolean,
  partial: number,
  normal: Enum.NormalId,
  face: string,
  spread: vector,
}

const FLIP = CFrame.fromOrientation(0, math.pi, 0)

-- the longest stretch of a frame stepped whole once a piece is sub-stepped, a
-- frame a little over it still taken as one, and the most steps a hitch is
-- cut into
const MAX_STEP = 1 / 60
const STEP_SLACK = 0.05
const MAX_STEPS = 8

const WORLD_UP = vector.create(0, 1, 0)
const WORLD_X = vector.create(1, 0, 0)
const WORLD_Z = vector.create(0, 0, 1)

const TAU = 2 * math.pi

-- the turn a thinned path keeps a point at, at the least, and the points it
-- keeps for time alone: one every eighth of the path, then the two ends
const MIN_BEND = math.rad(3)
const EIGHTHS = 8

-- one channel's drift from `rest`, where it stood at age 0, so a piece spawns
-- where its path starts and never jumps on its first frame
const function drift(seed: number, t: number, scale: number, amount: number, rest: number)
  return math.clamp((math.noise(seed, t, 0.5) - rest) * scale, -amount, amount)
end

-- the unit part of `direction` across `outward`, nil when it runs along it
const function across(direction: vector, outward: vector): vector?
  const side = direction - outward * vector.dot(direction, outward)
  const length = vector.magnitude(side)

  if length <= 1e-4 * vector.magnitude(direction) then
    return nil
  end

  return side / length
end

-- the unit pair spanning the plane across a unit `axis`
const function basisOf(axis: vector): (vector, vector)
  const first = (across(WORLD_X, axis) or across(WORLD_Z, axis)) :: vector

  return first, vector.cross(axis, first)
end

-- where a piece stands about a center and unit axis: its height along the
-- axis, its distance off it and its angle in the plane across it. a piece on
-- the axis takes the angle of its velocity, else the plane's first direction
const function aroundOf(
  position: vector,
  velocity: vector,
  center: vector,
  axis: vector
): (number, number, number, vector, vector)
  const first, second = basisOf(axis)
  const offset = position - center
  const height = vector.dot(offset, axis)
  const radial = offset - axis * height

  local x, y = vector.dot(radial, first), vector.dot(radial, second)

  if x * x + y * y <= 1e-12 then
    x, y = vector.dot(velocity, first), vector.dot(velocity, second)
  end

  return height, vector.magnitude(radial), math.atan2(y, x), first, second
end

-- the value `t` of the way through a list sampled evenly, between the two
-- samples either side of it
const function sampledOf(list: { any }, t: number): any
  const count = #list

  if count == 1 then
    return list[1]
  end

  const at = math.clamp(t, 0, 1) * (count - 1)
  const i = math.floor(at)
  const a = list[i + 1]
  const b = list[math.min(i + 2, count)]

  return a + (b - a) * (at - i)
end

-- the angle between two steps, 0 when either has no length
const function turnOf(a: vector, b: vector)
  const lengths = vector.magnitude(a) * vector.magnitude(b)

  if lengths <= 0 then
    return 0
  end

  return math.acos(math.clamp(vector.dot(a, b) / lengths, -1, 1))
end

const particle_motion = {}

-- a spawn frame whose look vector is the launch direction. draws shape point,
-- spread x, spread y, then the InAndOut coin, so a caller replaying a
-- ParticleEmitter must draw speed and lifetime before calling
function particle_motion.spawn(origin: CFrame, size: Vector3, config: Config, rng: Random, seed: number?): CFrame
  local cf: CFrame

  if size == Vector3.zero then
    cf = shape.box(origin, Vector3.zero, { normal = config.normal })
  else
    const make = shape[string.lower(config.shape)]

    cf = make(origin, size, {
      surface = config.surface,
      partial = config.partial,
      normal = config.normal,
      seed = seed,
    })
  end

  const spread = config.spread

  cf *= CFrame.fromOrientation(
    math.rad(rng:NextNumber(-spread.x, spread.x)),
    math.rad(rng:NextNumber(-spread.y, spread.y)),
    0
  )

  const face = config.face

  if face == "Inward" or (face == "InAndOut" and rng:NextInteger(0, 1) == 1) then
    cf *= FLIP
  end

  return cf
end

-- one step of a particle: the position from the old velocity, then the
-- velocity eased toward the wind by drag
function particle_motion.step(
  position: vector,
  velocity: vector,
  acceleration: vector,
  drag: number,
  wind: vector,
  dt: number
): (vector, vector)
  const nextPosition = position + velocity * dt + acceleration * (0.5 * dt * dt)
  const nextVelocity = wind + (velocity + acceleration * dt - wind) * 2 ^ (-drag * dt)

  return nextPosition, nextVelocity
end

-- how many even steps a frame of `dt` is cut into
function particle_motion.substeps(dt: number)
  return math.clamp(math.ceil(dt / MAX_STEP - STEP_SLACK), 1, MAX_STEPS)
end

-- Plummer-softened inverse-square gravity with G = 1, zero at the target with
-- no softening, where the pull has no direction
function particle_motion.gravity(position: vector, target: vector, mass: number, softening: number): vector
  const offset = target - position
  const squared = vector.dot(offset, offset) + softening * softening
  const scale = mass / (squared * math.sqrt(squared))

  if scale ~= scale or scale == math.huge or scale == -math.huge then
    return vector.zero
  end

  return offset * scale
end

-- the velocity of a circular orbit about the target through `position`:
-- across the radius in its plane with `look`, on look's side, else in the
-- plane with `up`, then with the world's up
function particle_motion.orbit(
  position: vector,
  target: vector,
  look: vector,
  up: vector,
  mass: number,
  softening: number
): vector
  const radial = position - target
  const squared = vector.dot(radial, radial)

  if squared == 0 then
    return vector.zero
  end

  const outward = radial / math.sqrt(squared)
  const side = across(look, outward) or across(up, outward) or across(WORLD_UP, outward) or across(WORLD_X, outward)
  const speed = math.sqrt(math.max(mass, 0) * squared / (squared + softening * softening) ^ 1.5)

  return (side :: vector) * speed
end

-- one velocity Verlet step under the target's gravity and `acceleration`:
-- the position from the pull where the piece stands, the velocity from the
-- mean of that pull and the one where it lands, then drag toward the wind
function particle_motion.verlet(
  position: vector,
  velocity: vector,
  acceleration: vector,
  target: vector,
  mass: number,
  softening: number,
  drag: number,
  wind: vector,
  dt: number
): (vector, vector)
  const before = acceleration + particle_motion.gravity(position, target, mass, softening)
  const nextPosition = position + velocity * dt + before * (0.5 * dt * dt)
  const after = acceleration + particle_motion.gravity(nextPosition, target, mass, softening)
  const nextVelocity = wind + (velocity + (before + after) * (0.5 * dt) - wind) * 2 ^ (-drag * dt)

  return nextPosition, nextVelocity
end

-- one step of an orbiting piece, worked out from where it stands: its angle
-- carried on at the spin, its ring climbing at the rise, and its gaps from the
-- ring's radius and height eased away at the capture's rate, so a piece on the
-- ring climbs at the rise exactly. the velocity is what the move took
function particle_motion.ring(position: vector, velocity: vector, orbit: Orbit, dt: number): (vector, vector)
  const axis = orbit.axis
  const center = orbit.center
  const along, distance, angle, first, second = aroundOf(position, velocity, center, axis)
  const settle = math.exp(-math.max(orbit.capture, 0) * dt)
  const climb = orbit.rise * dt
  const rest = (orbit.height or along) + climb
  const height = rest + (along + climb - rest) * settle
  const radius = math.max(orbit.radius, 0)
  const reach = math.max(radius + (distance - radius) * settle, 0)
  const turned = angle + orbit.spin * TAU * dt

  orbit.height = rest

  const nextPosition = center + axis * height + (first * math.cos(turned) + second * math.sin(turned)) * reach

  return nextPosition, if dt > 0 then (nextPosition - position) / dt else velocity
end

-- one step under a force, or none: gravity by velocity Verlet, an orbit by
-- its ring alone
function particle_motion.advance(
  position: vector,
  velocity: vector,
  acceleration: vector,
  drag: number,
  wind: vector,
  force: Force?,
  dt: number
): (vector, vector)
  if force == nil then
    return particle_motion.step(position, velocity, acceleration, drag, wind, dt)
  end

  if force.kind == "Gravity" then
    return particle_motion.verlet(
      position,
      velocity,
      acceleration,
      force.target,
      force.mass,
      force.softening,
      drag,
      wind,
      dt
    )
  end

  return particle_motion.ring(position, velocity, force, dt)
end

-- the value `t` of the way through a list sampled evenly, between the two
-- samples either side of it
function particle_motion.sampled(list: { any }, t: number): any
  return sampledOf(list, t)
end

-- the points of a dense path worth drawing, at most `most`: both ends, a
-- point once the path has turned some bend since the last one kept, and one
-- every eighth of the path. the bend is 3 degrees, or the path's whole
-- turning shared out over what the cap leaves, so a path that turns a lot
-- keeps its sharpest bends and never more points
function particle_motion.thin(points: { vector }, most: number): { vector }
  const count = #points

  if count <= 2 then
    return points
  end

  const turns = table.create(count, 0)

  local total = 0

  for i = 2, count - 1 do
    const turn = turnOf(points[i] - points[i - 1], points[i + 1] - points[i])

    turns[i] = turn
    total += turn
  end

  const bend = math.max(MIN_BEND, total / math.max(most - EIGHTHS - 2, 1))
  const every = (count - 1) / EIGHTHS
  const kept = { points[1] }

  local turned = 0
  local last = 1

  for i = 2, count - 1 do
    turned += turns[i]

    if turned > bend or i - last >= every then
      table.insert(kept, points[i])
      turned = 0
      last = i
    end
  end

  table.insert(kept, points[count])

  return kept
end

-- where a seed's three wander channels stand at age 0, constant for a piece's
-- whole life, so a caller wandering every frame works them out once
function particle_motion.rest(seed: number): vector
  return vector.create(math.noise(seed, 0, 0.5), math.noise(seed + 17.1, 0, 0.5), math.noise(seed + 34.2, 0, 0.5))
end

-- a smooth offset of up to amount per axis, three noise channels apart by
-- seed; `rest` is particle_motion.rest(seed), worked out here when not given
function particle_motion.wander(seed: number, age: number, frequency: number, amount: number, rest: vector?): vector
  const t = age * frequency
  const scale = amount * 2
  const origin = rest or particle_motion.rest(seed)

  return vector.create(
    drift(seed, t, scale, amount, origin.x),
    drift(seed + 17.1, t, scale, amount, origin.y),
    drift(seed + 34.2, t, scale, amount, origin.z)
  )
end

-- positions at whole steps of 1/rate, then the remainder step; under a
-- force each step is cut as a piece's frame is. `rows` drive the
-- acceleration, drag and force fields over the life, each read at the start
-- of a step
function particle_motion.path(
  start: CFrame,
  speed: number,
  lifetime: number,
  acceleration: vector,
  drag: number,
  wind: vector,
  rate: number,
  force: Force?,
  rows: Rows?
): { vector }
  const origin = start.Position
  const look = start.LookVector

  local position = vector.create(origin.X, origin.Y, origin.Z)
  local velocity = vector.create(look.X, look.Y, look.Z) * speed
  local age = if rows ~= nil then rows.since else 0

  -- the path's own copy, which the rows write and an orbit's height is kept on
  const own: any = if force ~= nil then table.clone(force) else nil

  if own ~= nil and own.kind == "Orbit" and own.height == nil then
    own.height = vector.dot(position - own.center, own.axis)
  end

  const points = {}

  const function read()
    const span = (rows :: Rows).span
    const t = if span > 0 then age / span else 0

    for key, list in (rows :: Rows).lists do
      const v = particle_motion.sampled(list, t)

      if key == "acceleration" then
        acceleration = v
      elseif key == "drag" then
        drag = v
      elseif own ~= nil then
        own[key] = v
      end
    end
  end

  const function advance(dt: number)
    if rows ~= nil then
      read()
    end

    age += dt

    if own == nil then
      position, velocity = particle_motion.step(position, velocity, acceleration, drag, wind, dt)
      return
    end

    const steps = particle_motion.substeps(dt)
    const h = dt / steps

    for _ = 1, steps do
      position, velocity = particle_motion.advance(position, velocity, acceleration, drag, wind, own, h)
    end
  end

  const samples = lifetime * rate
  const remainder = if samples <= 1 then samples else samples % 1

  for _ = 1, math.floor(samples) do
    advance(1 / rate)

    table.insert(points, position)
  end

  if remainder ~= 0 then
    advance(remainder / rate)

    table.insert(points, position)
  end

  return points
end

return particle_motion
