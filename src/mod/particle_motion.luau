--!native
--!optimize 2
local shape = require("@mod/shape")

export type Gravity = { kind: "Gravity", target: vector, mass: number, softening: number }

-- a value along a funnel's height, bottom to top: one number where it is
-- flat, else samples taken evenly over the height
export type Shape = number | { number }

-- a funnel about the axis, `height` tall, its curves read at the share of
-- the height a piece stands at and held past either end. `spin` is in turns
-- per second at `widest`, the radius curve's widest, and `tighten` the power
-- narrower parts and inner pieces turn faster by; `rise` is in studs per
-- second, `pull` per second and `sway` in studs. `wall` is the piece's own
-- place across a wall `thickness` studs thick, -0.5 to 0.5. the trunk sways
-- on `time`, the effect's clock where the piece stands, from two noise
-- channels `seeds` picks; `swayed` is where the trunk stood as the piece was
-- last placed, and a piece past the top flags `released` when `release` is set
export type Vortex = {
  kind: "Vortex",
  center: vector,
  axis: vector,
  height: number,
  radius: Shape,
  widest: number,
  wall: number,
  thickness: number,
  spin: number,
  tighten: number,
  rise: number,
  pull: number,
  sway: number,
  swaySpeed: number,
  spinOver: Shape,
  riseOver: Shape,
  swayOver: Shape,
  inflow: number,
  release: boolean,
  seeds: vector,
  time: number,
  swayed: vector?,
  released: boolean,
}

-- `height` is where the piece's own ring sits along the axis, the height it
-- spawned at; a path left without one takes it from where it starts
export type Orbit = {
  kind: "Orbit",
  center: vector,
  axis: vector,
  radius: number,
  spin: number,
  capture: number,
  height: number?,
}

export type Force = Gravity | Vortex | Orbit

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

-- how close to the trunk a piece counts its distance from, as a share of the
-- widest radius, and the most a tightened spin is sped up by, so a piece on
-- the axis never turns infinitely fast
const CORE = 0.05
const MAX_BOOST = 8

-- how far behind the foot the top's sway runs, in noise units: one bend over
-- the height, traveling upward
const LAG = 1

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

const function shapeAt(curve: Shape, u: number): number
  if type(curve) == "number" then
    return curve
  end

  return sampledOf(curve, u)
end

-- the share of a funnel's height `h` stands at, held at its ends past them
const function shareOf(height: number, h: number)
  return if height > 0 then math.clamp(h / height, 0, 1) elseif h > 0 then 1 else 0
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

-- what an orbit hands the funnel's step: a flat radius, no rise, no tighten
-- and no sway, rewritten every step
const RING: Vortex = {
  kind = "Vortex",
  center = vector.zero,
  axis = WORLD_UP,
  height = 1,
  radius = 0,
  widest = 0,
  wall = 0,
  thickness = 0,
  spin = 0,
  tighten = 0,
  rise = 0,
  pull = 0,
  sway = 0,
  swaySpeed = 0,
  spinOver = 1,
  riseOver = 1,
  swayOver = 0,
  inflow = 0,
  release = false,
  seeds = vector.zero,
  time = 0,
  swayed = vector.zero,
  released = false,
}

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

-- the funnel's radius for the piece at share `u` of its height, its own
-- place across the wall added
function particle_motion.width(vortex: Vortex, u: number)
  return math.max(shapeAt(vortex.radius, u) + vortex.wall * vortex.thickness, 0)
end

-- radians per second a piece `distance` from the trunk at share `u` of the
-- height turns at: the spin at the widest part, sped up by the widest over
-- the distance to the power of tighten, capped
function particle_motion.turning(vortex: Vortex, distance: number, u: number)
  const tighten = vortex.tighten
  const widest = vortex.widest

  local boost = 1

  if tighten ~= 0 and widest > 0 then
    boost = math.min((widest / math.max(distance, CORE * widest)) ^ tighten, MAX_BOOST)
  end

  return vortex.spin * TAU * shapeAt(vortex.spinOver, u) * boost
end

-- the trunk's offset across the axis at share `u` of the height at `time`:
-- one centerline every piece of the effect rides, the bend at the top
-- running behind the foot's so it travels up
function particle_motion.trunk(vortex: Vortex, u: number, time: number): vector
  const sway = vortex.sway * shapeAt(vortex.swayOver, u)

  if sway == 0 then
    return vector.zero
  end

  const phase = time * vortex.swaySpeed - u * LAG
  const seeds = vortex.seeds
  const first, second = basisOf(vortex.axis)

  -- math.noise rarely leaves -0.5 to 0.5
  return (first * math.noise(phase, seeds.x) + second * math.noise(phase, seeds.y)) * (2 * sway)
end

-- one step of a piece about a swaying trunk, worked out from where it stands
-- against where the trunk stood as it was last placed: its angle carried on
-- at its turning, its height moved by the rise, or eased toward `rest` when
-- one is given, and its gap from the wall eased away at the pull's rate, so a
-- piece drawn on keeps to the wall as it climbs and as the trunk sways. the
-- velocity is what the move took
const function swirl(position: vector, velocity: vector, vortex: Vortex, rest: number?, dt: number): (vector, vector)
  const axis = vortex.axis
  const center = vortex.center
  const height = vortex.height
  const along = vector.dot(position - center, axis)
  const u = shareOf(height, along)
  const swayed = vortex.swayed or particle_motion.trunk(vortex, u, vortex.time)
  const _, distance, angle, first, second = aroundOf(position, velocity, center + swayed, axis)
  const turned = angle + particle_motion.turning(vortex, distance, u) * dt
  const settle = math.exp(-math.max(vortex.pull, 0) * dt)
  const wall = particle_motion.width(vortex, u)

  local climbed: number

  if rest ~= nil then
    climbed = rest + (along - rest) * settle
  else
    -- a piece outside the wall is held back by the square of how far in it is
    const inflow = vortex.inflow
    const reach = if inflow ~= 0 and distance > wall then (wall / distance) ^ 2 else 1

    climbed = along + vortex.rise * shapeAt(vortex.riseOver, u) * (1 + (reach - 1) * inflow) * dt
  end

  const next = shareOf(height, climbed)
  const radius = math.max(particle_motion.width(vortex, next) + (distance - wall) * settle, 0)
  const time = vortex.time + dt
  const trunk = particle_motion.trunk(vortex, next, time)

  vortex.time = time
  vortex.swayed = trunk

  if vortex.release and climbed > height then
    vortex.released = true
  end

  const nextPosition = center + axis * climbed + trunk + (first * math.cos(turned) + second * math.sin(turned)) * radius

  return nextPosition, if dt > 0 then (nextPosition - position) / dt else velocity
end

-- one step of a piece on a funnel, which carries the piece's own state on
function particle_motion.funnel(position: vector, velocity: vector, vortex: Vortex, dt: number): (vector, vector)
  return swirl(position, velocity, vortex, nil, dt)
end

-- one step of an orbiting piece: the funnel's step on a ring of the orbit's
-- radius, its height eased toward the ring's at the capture's rate
function particle_motion.ring(position: vector, velocity: vector, orbit: Orbit, dt: number): (vector, vector)
  RING.center = orbit.center
  RING.axis = orbit.axis
  RING.radius = math.max(orbit.radius, 0)
  RING.spin = orbit.spin
  RING.pull = orbit.capture

  return swirl(position, velocity, RING, orbit.height or vector.dot(position - orbit.center, orbit.axis), dt)
end

-- one step under a force, or none: gravity by velocity Verlet, a vortex by
-- its funnel alone until it is released past the top, then as a particle with
-- the velocity it left with, an orbit by its ring alone
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

  if force.kind == "Vortex" then
    if force.released then
      return particle_motion.step(position, velocity, acceleration, drag, wind, dt)
    end

    return particle_motion.funnel(position, velocity, force, dt)
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
