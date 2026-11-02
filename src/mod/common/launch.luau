const value_curve = require("@mod/value_curve")
const particle_motion = require("@mod/particle_motion")

const WORLD_UP = vector.create(0, 1, 0)

-- the samples a curve over a funnel's height is baked into past its first,
-- read between with a linear lookup
const BAKED = 16

-- the trunk's two noise channels when no emitter picks its own
const TRUNK_SEEDS = vector.create(7.31, 19.57, 0)

-- the sway a funnel's height takes while its shaping rows are off: none at
-- the foot, all at the top
const RAMP = table.freeze({ 0, 1 })

const common = {}

-- the rows each force drives over a piece's life, by the field of its
-- particle_motion force they write
common.DRIVEN = table.freeze({
  Gravity = table.freeze({ GravityMass = "mass" }),
  Vortex = table.freeze({
    VortexSpin = "spin",
    VortexRise = "rise",
    VortexPull = "pull",
    VortexSway = "sway",
    VortexTighten = "tighten",
    VortexThickness = "thickness",
  }),
  Orbit = table.freeze({ OrbitRadius = "radius", OrbitSpin = "spin" }),
})

-- a row's vector under every host, which lune spells apart from Vector3
const function isVector(v: any)
  const kind = typeof(v)

  return kind == "Vector3" or kind == "vector"
end

-- a drawn number, or `fallback` where a modifier drew none a clock can use
const function numberOr(v: any, fallback: number)
  return if type(v) == "number" and v == v then v else fallback
end

-- the largest value a baked curve reaches
const function widestOf(shape: particle_motion.Shape): number
  if type(shape) == "number" then
    return shape
  end

  local most = -math.huge

  for _, v in shape do
    most = math.max(most, v)
  end

  return most
end

-- whether any key of a curve scatters what each piece draws
const function enveloped(curve: value_curve.Curve)
  for _, key in curve.keys do
    if key.envelope ~= 0 then
      return true
    end
  end

  return false
end

-- whether a row's track carries a modifier, so each piece reads its own
function common.modified(track: any): boolean
  return track.has("start") or track.has("end")
end

-- what one piece reads off its rows as it spawns, `spawned` into the
-- effect's clock: its launch speed, its life, its spread about X and Y, its
-- initial turn in degrees and the share of the parent's velocity it takes.
-- each call is one piece's own, a randomizer drawing anew
function common.draw(attrs: any, spawned: number): (number, number, vector, vector, number)
  const speed = numberOr(attrs.Speed().at(spawned), attrs.Speed.value.Min)
  const duration = math.max(numberOr(attrs.Lifetime().at(spawned), attrs.Lifetime.value.Min), 0)
  const spread = attrs.SpreadAngle().at(spawned)
  const turn = attrs.Rotation().at(spawned)
  const inheritance = numberOr(attrs.VelocityInheritance().at(spawned), 0)

  return speed,
    duration,
    if isVector(spread) then vector.create(spread.X, spread.Y, 0) else vector.zero,
    if isVector(turn) then vector.create(turn.X, turn.Y, turn.Z) else vector.zero,
    inheritance
end

-- the target set for the chosen force, nil for None or none set, when a
-- force centers on the emitter
function common.target(attrs: any): Instance?
  if attrs.Force == "None" then
    return nil
  end

  return attrs.ForceTarget
end

-- a curve over a funnel's height as its step reads it: the one value a flat
-- curve holds, else BAKED + 1 samples from the bottom to the top, through
-- one sampler. `draws` are a piece's own envelope draws
function common.bake(curve: value_curve.Curve, draws: { number }?): particle_motion.Shape
  const at, flat = value_curve.sampler(curve, draws)

  if flat then
    return at(0)[1]
  end

  const samples = table.create(BAKED + 1)

  for k = 0, BAKED do
    samples[k + 1] = at(k / BAKED)[1]
  end

  return samples
end

-- the force of one emit as it emits, from the rows that hold for a piece's
-- whole life; each piece flies a copy. its place and axis are written as it
-- flies, and its driven rows, DRIVEN's, start at 0 until they are. a vortex's
-- shaping rows reach it only while VortexShaping is on. nil for None
function common.force(attrs: any): particle_motion.Force?
  const kind = attrs.Force

  if kind == "Gravity" then
    return { kind = "Gravity", target = vector.zero, mass = 0, softening = attrs.GravitySoftening }
  end

  if kind == "Vortex" then
    const shaping = attrs.VortexShaping == true
    const radius = common.bake(attrs.VortexRadius)

    return {
      kind = "Vortex",
      center = vector.zero,
      axis = WORLD_UP,
      height = attrs.VortexHeight,
      radius = radius,
      widest = widestOf(radius),
      wall = 0,
      thickness = 0,
      spin = 0,
      tighten = 0,
      rise = 0,
      pull = 0,
      sway = 0,
      swaySpeed = attrs.VortexSwaySpeed,
      spinOver = if shaping then common.bake(attrs.VortexSpinOverHeight) else 1,
      riseOver = if shaping then common.bake(attrs.VortexRiseOverHeight) else 1,
      swayOver = if shaping then common.bake(attrs.VortexSwayOverHeight) else RAMP,
      inflow = if shaping then attrs.VortexInflow else 0,
      release = shaping and attrs.VortexTop == "Release",
      seeds = TRUNK_SEEDS,
      time = 0,
      swayed = nil,
      released = false,
    }
  end

  if kind == "Orbit" then
    return {
      kind = "Orbit",
      center = vector.zero,
      axis = WORLD_UP,
      radius = 0,
      spin = 0,
      capture = attrs.OrbitCapture,
      height = nil,
    }
  end

  return nil
end

-- one piece's own place on a vortex as it spawns, drawn from `rng`: its
-- radius curve with the curve's envelope drawn for it, and where across the
-- wall it sits
function common.wall(attrs: any, vortex: particle_motion.Vortex, rng: Random)
  const curve = attrs.VortexRadius

  if enveloped(curve) then
    vortex.radius = common.bake(curve, value_curve.draw(curve, rng))
    vortex.widest = widestOf(vortex.radius)
  end

  vortex.wall = rng:NextNumber(-0.5, 0.5)
end

-- one piece's row over its life of `life` seconds, for a caller with no
-- clock to drive it on: `count` + 1 values at even ages from 0 to the life,
-- each through `read`, or the one value a row with nothing moving it rests at
function common.over(track: any, life: number, count: number, read: (v: any) -> any): { any }
  if not track.animated and not common.modified(track) then
    return { read(track.at(0)) }
  end

  const own = track(nil, life)

  if not own.animated then
    return { read(own.at(0)) }
  end

  const values = table.create(count + 1)

  for k = 0, count do
    values[k + 1] = read(own.at(life * k / count))
  end

  return values
end

return common
