--!native
--!optimize 2
local shape = require("@mod/shape")

export type Gravity = { target: vector, mass: number, softening: number }

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

-- positions at whole steps of 1/rate, then the remainder step; under gravity
-- each step is cut as a piece's frame is
function particle_motion.path(
  start: CFrame,
  speed: number,
  lifetime: number,
  acceleration: vector,
  drag: number,
  wind: vector,
  rate: number,
  gravity: Gravity?
): { vector }
  const origin = start.Position
  const look = start.LookVector

  local position = vector.create(origin.X, origin.Y, origin.Z)
  local velocity = vector.create(look.X, look.Y, look.Z) * speed

  const points = {}

  const function advance(dt: number)
    if gravity == nil then
      position, velocity = particle_motion.step(position, velocity, acceleration, drag, wind, dt)
      return
    end

    const steps = particle_motion.substeps(dt)
    const h = dt / steps

    for _ = 1, steps do
      position, velocity = particle_motion.verlet(
        position,
        velocity,
        acceleration,
        gravity.target,
        gravity.mass,
        gravity.softening,
        drag,
        wind,
        h
      )
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
