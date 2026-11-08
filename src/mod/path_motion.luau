--!native
--!optimize 2
const value_curve = require("@mod/value_curve")
const path_curve = require("@mod/common/path_curve")

-- a velocity under this is no direction to leave a path along
const STILL = 1e-6

-- what every piece of one emit walking a path shares, read once as it emits:
-- the curve and its drawn frame, how its ends are fit, the emitter's center
-- and emission axis, the Progress curve each piece draws its own band of, and
-- the EndPoint, which `finish` holds as it last stood on frame `read`
export type Path = {
  bezier: any,
  drawn: path_curve.Drawn,
  ends: path_curve.Ends,
  bend: path_curve.Bend,
  reverse: boolean,
  radius: NumberRange,
  after: string,
  axis: vector,
  center: vector,
  flight: NumberRange,
  progress: value_curve.Curve,
  target: Instance?,
  finish: vector?,
  read: number,
}

-- the part of a piece's launch its path reads
export type Launch = {
  spawn: CFrame,
  pathTime: number,
  roll: number,
  offset: vector,
  pace: { number }?,
}

const path_motion = {}

-- the point `age` into a path's time under a placement, Progress pacing it
-- evenly along the curve, at its end from `pathTime` on
function path_motion.walker(opts: {
  bezier: any,
  drawn: path_curve.Drawn,
  progress: (t: number) -> { number },
  pathTime: number,
  reverse: boolean,
}): (age: number, frame: CFrame, scale: number) -> vector
  const bezier, drawn, progress = opts.bezier, opts.drawn, opts.progress
  const pathTime, reverse = opts.pathTime, opts.reverse

  return function(age: number, frame: CFrame, scale: number)
    const t = if pathTime > 0 then math.clamp(age / pathTime, 0, 1) else 1
    const u = math.clamp(progress(t)[1], 0, 1)

    return path_curve.at(bezier, drawn, frame, scale, if reverse then 1 - u else u)
  end
end

-- one piece's draws after its spawn, in this order: the roll, where its path
-- ends off the end point, how long it flies on, then one per Progress key for
-- its band. nothing is drawn off a piece with no path
function path_motion.draw(path: Path?, rng: Random, spawn: CFrame): (number, vector, number, { number }?)
  if path == nil then
    return 0, vector.zero, 0, nil
  end

  const at = vector.create(spawn.Position.X, spawn.Position.Y, spawn.Position.Z)
  const finish = if path.ends == "Center" then path.center else path.finish or at
  const roll = rng:NextNumber() * 2 * math.pi
  const offset = path_curve.ending(rng, finish, at, path.radius)
  const flight = rng:NextNumber(path.flight.Min, path.flight.Max)
  const pace = value_curve.draw(path.progress, rng)

  return roll, offset, if path.after == "Continue" then math.max(flight, 0) else 0, pace
end

-- a piece's walk along its path, `age` into its path time, and the way the
-- placed path runs from its start to its end. the end is placed again only
-- when it moved: a target read by `standing`, a world point mapped by
-- `unplaced` into the frame the piece flies in. nil for no path
function path_motion.follow(
  path: Path?,
  launch: Launch,
  standing: () -> vector?,
  unplaced: (at: vector) -> vector
): (((age: number) -> vector)?, (() -> vector)?)
  if path == nil then
    return nil, nil
  end

  const drawn, ends, offset = path.drawn, path.ends, launch.offset
  const walk = path_motion.walker({
    bezier = path.bezier,
    drawn = drawn,
    progress = (value_curve.sampler(path.progress, launch.pace)),
    pathTime = launch.pathTime,
    reverse = path.reverse,
  })

  local frame, scale = CFrame.identity, 0
  local placedAt: vector? = nil
  local placed = false

  const function finish(): vector?
    if ends == "Center" then
      return path.center + offset
    end

    if ends ~= "Target" then
      return nil
    end

    const at = standing()

    return if at ~= nil then unplaced(at + offset) else nil
  end

  const function point(age: number)
    const at = finish()

    if not placed or at ~= placedAt then
      placed, placedAt = true, at
      frame, scale = path_curve.place(drawn, ends, launch.spawn, at, path.center, path.axis, path.bend, launch.roll)
    end

    return walk(age, frame, scale)
  end

  const function heading()
    const chord = if drawn.length > STILL then drawn.chord / drawn.length else vector.create(0, 0, -1)
    const way = frame:VectorToWorldSpace(Vector3.new(chord.x, chord.y, chord.z))
    const along = vector.create(way.X, way.Y, way.Z)

    return if path.reverse then -along else along
  end

  return point, heading
end

-- the unit way `velocity` runs, or `fallback`'s when it stands still
function path_motion.unit(velocity: vector, fallback: () -> vector)
  const speed = vector.magnitude(velocity)

  return if speed > STILL then velocity / speed else fallback()
end

return path_motion
