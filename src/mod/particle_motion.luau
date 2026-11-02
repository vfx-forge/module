--!native
--!optimize 2
local shape = require("@mod/shape")

export type Config = {
  shape: string,
  surface: boolean,
  partial: number,
  normal: Enum.NormalId,
  face: string,
  spread: vector,
}

const FLIP = CFrame.fromOrientation(0, math.pi, 0)

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

-- a pull along the line to the target, zero inside 1e-4 so no NaN
function particle_motion.pull(position: vector, target: vector, strength: number): vector
  const offset = target - position
  const distance = vector.magnitude(offset)

  if distance < 1e-4 then
    return vector.zero
  end

  return offset / distance * strength
end

-- a smooth offset of up to amount per axis, three noise channels apart by seed
function particle_motion.wander(seed: number, age: number, frequency: number, amount: number): vector
  const t = age * frequency
  const scale = amount * 2

  return vector.create(
    math.clamp(math.noise(seed, t, 0.5) * scale, -amount, amount),
    math.clamp(math.noise(seed + 17.1, t, 0.5) * scale, -amount, amount),
    math.clamp(math.noise(seed + 34.2, t, 0.5) * scale, -amount, amount)
  )
end

-- positions at whole steps of 1/rate, then the remainder step
function particle_motion.path(
  start: CFrame,
  speed: number,
  lifetime: number,
  acceleration: vector,
  drag: number,
  wind: vector,
  rate: number,
  pull: { target: vector, strength: number }?
): { vector }
  const origin = start.Position
  const look = start.LookVector

  local position = vector.create(origin.X, origin.Y, origin.Z)
  local velocity = vector.create(look.X, look.Y, look.Z) * speed

  const points = {}

  const function accelerate(at: vector): vector
    if pull == nil then
      return acceleration
    end

    return acceleration + particle_motion.pull(at, pull.target, pull.strength)
  end

  const samples = lifetime * rate
  const remainder = if samples <= 1 then samples else samples % 1

  for _ = 1, math.floor(samples) do
    position, velocity = particle_motion.step(position, velocity, accelerate(position), drag, wind, 1 / rate)

    table.insert(points, position)
  end

  if remainder ~= 0 then
    position, velocity = particle_motion.step(position, velocity, accelerate(position), drag, wind, remainder / rate)

    table.insert(points, position)
  end

  return points
end

return particle_motion
