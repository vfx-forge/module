const particle_motion = require("@mod/particle_motion")

const WORLD_UP = vector.create(0, 1, 0)

const common = {}

-- the rows each force drives over a piece's life, by the field of its
-- particle_motion force they write
common.DRIVEN = table.freeze({
  Gravity = table.freeze({ GravityMass = "mass" }),
  Orbit = table.freeze({ OrbitRadius = "radius", OrbitSpin = "spin", OrbitRise = "rise" }),
})

-- a row's vector under every host, which lune spells apart from Vector3
function common.isVector(v: any)
  const kind = typeof(v)

  return kind == "Vector3" or kind == "vector"
end

-- a drawn number, or `fallback` where a modifier drew none a clock can use
function common.numberOr(v: any, fallback: number)
  return if type(v) == "number" and v == v then v else fallback
end

const isVector = common.isVector
const numberOr = common.numberOr

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

-- the force of one emit as it emits, from the rows that hold for a piece's
-- whole life; each piece flies a copy. its place and axis are written as it
-- flies, and its driven rows, DRIVEN's, start at 0 until they are. nil for
-- None
function common.force(attrs: any): particle_motion.Force?
  const kind = attrs.Force

  if kind == "Gravity" then
    return { kind = "Gravity", target = vector.zero, mass = 0, softening = attrs.GravitySoftening }
  end

  if kind == "Orbit" then
    return {
      kind = "Orbit",
      center = vector.zero,
      axis = WORLD_UP,
      radius = 0,
      spin = 0,
      rise = 0,
      capture = attrs.OrbitCapture,
      height = nil,
    }
  end

  return nil
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
