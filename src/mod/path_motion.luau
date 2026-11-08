--!native
--!optimize 2
const value_curve = require("@mod/value_curve")
const path_curve = require("@mod/common/path_curve")

-- a tangent under this is no direction to leave a path along
const STILL = 1e-6

-- the path time Progress is read back over, a frame at 60 per second, to
-- tell which way a walk last ran
const FRAME = 1 / 60

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
-- evenly along the curve, at its end from `pathTime` on, and the share of the
-- path Progress put it at
function path_motion.walker(opts: {
  bezier: any,
  drawn: path_curve.Drawn,
  progress: (t: number) -> { number },
  pathTime: number,
  reverse: boolean,
}): (age: number, frame: CFrame, scale: number) -> (vector, number)
  const bezier, drawn, progress = opts.bezier, opts.drawn, opts.progress
  const pathTime, reverse = opts.pathTime, opts.reverse

  return function(age: number, frame: CFrame, scale: number)
    const t = if pathTime > 0 then math.clamp(age / pathTime, 0, 1) else 1
    const u = math.clamp(progress(t)[1], 0, 1)

    return path_curve.at(bezier, drawn, frame, scale, if reverse then 1 - u else u), u
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

-- a way in a placed path's drawn frame, in the frame the piece moves in
const function turned(frame: CFrame, way: vector): vector
  const along = frame:VectorToWorldSpace(Vector3.new(way.x, way.y, way.z))

  return vector.create(along.X, along.Y, along.Z)
end

-- a piece's walk along its path, `age` into its path time, the velocity it
-- walked at between its last two points (`pace`) and the way the placed path
-- runs where it ends (`leaving`). the end is placed again only when it moved: a target
-- read by `standing`, a world point mapped by `unplaced` into the frame the
-- piece flies in. nil for no path
function path_motion.follow(
  path: Path?,
  launch: Launch,
  standing: () -> vector?,
  unplaced: (at: vector) -> vector
): (((age: number) -> vector)?, (() -> vector)?, ((span: number) -> vector?)?)
  if path == nil then
    return nil, nil, nil
  end

  const drawn, ends, offset = path.drawn, path.ends, launch.offset
  const progress = value_curve.sampler(path.progress, launch.pace)
  const walk = path_motion.walker({
    bezier = path.bezier,
    drawn = drawn,
    progress = progress,
    pathTime = launch.pathTime,
    reverse = path.reverse,
  })

  local frame, scale = CFrame.identity, 0
  local placedAt: vector? = nil
  local placed = false

  -- the share of the path the walk's last two points stood at
  local before, now = 0, 0

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

    const at, u = walk(age, frame, scale)

    before, now = now, u

    return at
  end

  const function heading()
    return path_motion.leaving(path.bezier, drawn, frame, path.reverse, progress, launch.pathTime)
  end

  -- the curve's tangent where the walk's last point stands, at the rate
  -- Progress moved it from the point before over `span` of path time, under
  -- the placement the walk last made. never the step between the two points,
  -- which easing to a stop moves too little a frame to give a direction. zero
  -- where Progress held still, so a facing keeps the turn it last had; nil
  -- over no path time
  const function pace(span: number): vector?
    if span <= 0 then
      return nil
    end

    -- how far the walk ran the way the curve was drawn
    const run = if path.reverse then before - now else now - before

    if run == 0 then
      return vector.zero
    end

    const bezier = path.bezier
    const tangent = bezier:tangentUniform(if path.reverse then 1 - now else now, run > 0)

    return turned(frame, tangent) * (run * bezier:length() * scale / span)
  end

  return point, heading, pace
end

-- the unit way a piece leaves a placed path where its walk, paced by
-- `progress` over `pathTime`, ends: the curve's tangent there, taken by
-- distance as the walk is, run backward under Reverse and when Progress last
-- ran back. never the walk's last step: one easing to a stop moves too little
-- over its last frame for f32 points to give a direction. an end whose handle
-- stands on its anchor leaves along the curve's limit there, and only a curve
-- that gives no tangent at all leaves along the chord
function path_motion.leaving(
  bezier: any,
  drawn: path_curve.Drawn,
  frame: CFrame,
  reverse: boolean,
  progress: (t: number) -> { number },
  pathTime: number
)
  const reached = math.clamp(progress(1)[1], 0, 1)
  const before = if pathTime > 0 then math.clamp(progress(1 - math.min(FRAME / pathTime, 1))[1], 0, 1) else reached

  -- whether the walk last ran the way the curve was drawn
  const forward = reverse == (reached < before)
  const tangent = bezier:tangentUniform(if reverse then 1 - reached else reached, forward)
  const way = if vector.magnitude(tangent) > STILL
    then tangent
    elseif drawn.length > STILL then drawn.chord / drawn.length
    else vector.create(0, 0, -1)
  const along = turned(frame, way)

  return if forward then along else -along
end

return path_motion
