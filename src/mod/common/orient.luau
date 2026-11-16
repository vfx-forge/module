--!native
--!optimize 2
const common = {}

export type Mode = "None" | "FacingCamera" | "FacingCameraWorldUp" | "VelocityParallel" | "VelocityPerpendicular"
export type Side = "None" | "Top" | "Front" | "Back"

const STILL_SPEED = 1e-6
const NEAR_VERTICAL = 0.999

-- the sine below which a side and a normal run as one line, which a float32
-- cross product cannot find a plane for
const PARALLEL = 1e-4

const UP = vector.create(0, 1, 0)
const SIDE = vector.create(1, 0, 0)
const BACK = vector.create(0, 0, 1)

common.MODES = {
  "None",
  "FacingCamera",
  "FacingCameraWorldUp",
  "VelocityParallel",
  "VelocityPerpendicular",
} :: { Mode }

common.SIDES = { "None", "Top", "Front", "Back" } :: { Side }

-- upper case, the spelling an authored Vector3 answers to under every host
const function toVector(v: Vector3): vector
  return vector.create(v.X, v.Y, v.Z)
end

const function toVector3(v: vector)
  return Vector3.new(v.x, v.y, v.z)
end

-- built from its axes, so a host's lookAt handedness never shows
const function frame(right: vector, up: vector, back: vector)
  return CFrame.fromMatrix(Vector3.zero, toVector3(right), toVector3(up), toVector3(back))
end

-- the turn looking along `look`, its up as near `hint` as it can be; nil
-- where the two run parallel
const function looking(look: vector, hint: vector)
  const right = vector.cross(look, hint)

  if vector.magnitude(right) < STILL_SPEED then
    return nil
  end

  const side = vector.normalize(right)

  return frame(side, vector.cross(side, look), -look)
end

-- a unit direction, or nil while it is too short to have one
const function direction(v: vector)
  const length = vector.magnitude(v)

  if length < STILL_SPEED or length ~= length then
    return nil
  end

  return v / length
end

-- `held` is the turn the velocity last gave, kept while a piece stands still
function common.rotation(
  mode: Mode,
  base: CFrame,
  position: vector,
  velocity: vector,
  camera: CFrame?,
  held: CFrame?
): CFrame
  const keep = base.Rotation

  if mode == "None" then
    return keep
  end

  if mode == "VelocityPerpendicular" or mode == "VelocityParallel" then
    const heading = direction(velocity)

    if not heading then
      return held or keep
    end

    if mode == "VelocityPerpendicular" then
      -- straight up or down has no up of its own to turn about
      return looking(heading, if math.abs(heading.y) > NEAR_VERTICAL then SIDE else UP) or keep
    end

    const hint = if math.abs(heading.z) > NEAR_VERTICAL then SIDE else BACK
    const side = vector.normalize(vector.cross(heading, hint))

    return frame(side, heading, vector.cross(side, heading))
  end

  if not camera then
    return keep
  end

  const toward = toVector(camera.Position) - position

  if mode == "FacingCamera" then
    const look = direction(toward)

    return look and looking(look, toVector(camera.UpVector)) or keep
  end

  const level = direction(vector.create(toward.x, 0, toward.z))

  return level and looking(level, UP) or keep
end

-- the turn that sets `side` of a piece turned `turn` facing out of a surface
-- of unit `normal`: its up along the normal, its front along it or its front
-- into it, the axes VelocityParallel and VelocityPerpendicular turn. the
-- shortest arc does it, about an axis square to the normal, so the piece
-- never twists about the normal
function common.landing(turn: CFrame, side: Side, normal: vector): CFrame
  const keep = turn.Rotation

  if side == "None" then
    return keep
  end

  const axis = if side == "Top"
    then toVector(keep.UpVector)
    elseif side == "Front" then toVector(keep.LookVector)
    else -toVector(keep.LookVector)
  const cos = math.clamp(vector.dot(axis, normal), -1, 1)
  const across = vector.cross(axis, normal)
  const planar = vector.magnitude(across) > PARALLEL

  if not planar and cos > 0 then
    return keep
  end

  -- facing straight away the arc has no plane, so the half turn is about an
  -- axis of the piece's own square to the side
  const pivot = if planar
    then vector.normalize(across)
    elseif side == "Top" then toVector(keep.RightVector)
    else toVector(keep.UpVector)

  return CFrame.fromAxisAngle(toVector3(pivot), math.acos(cos)) * keep
end

-- the turn `elapsed` seconds into a landing from `from` to `to` that takes
-- `duration`, eased by `ease`; one of no duration snaps
function common.settling(from: CFrame, to: CFrame, elapsed: number, duration: number, ease: (t: number) -> number)
  if duration <= 0 or elapsed >= duration then
    return to
  end

  return from:Lerp(to, ease(math.max(elapsed, 0) / duration))
end

-- as a ParticleEmitter squashes, measured: height by 1 + s, or by 1 / (1 - s)
-- below 0, and the other two by its inverse, so each side keeps its area
function common.squash(size: Vector3, s: number): Vector3
  const up = if s >= 0 then 1 + s else 1 / (1 - s)
  const across = 1 / up

  return Vector3.new(size.X * across, size.Y * up, size.Z * across)
end

-- the size `squash` makes this one from at the same `s`
function common.unsquash(size: Vector3, s: number): Vector3
  const up = if s >= 0 then 1 + s else 1 / (1 - s)

  return Vector3.new(size.X * up, size.Y / up, size.Z * up)
end

-- a pose drawn nearer than this share of its distance to the camera would
-- reach the camera itself, so a ZOffset past it stops there
const NEAREST = 0.05

-- `cf` drawn `by` studs along the line to a camera standing at `eye`, below 0
-- away from it, as a ParticleEmitter's ZOffset draws a particle, and the
-- scale that keeps it the same on screen: every point of the piece moves
-- toward the eye by one share, so its outline never changes and only the
-- distance Roblox sorts transparent parts by does (measured 2026-11-16: the
-- engine sorts by where a part draws, a pivot or a mesh's Offset changes
-- nothing). Its turn is kept. One at the camera has no line to move along
function common.toward(cf: CFrame, eye: Vector3, by: number): (CFrame, number)
  const line = eye - cf.Position
  const length = line.Magnitude

  if length < STILL_SPEED or length ~= length then
    return cf, 1
  end

  const k = math.max((length - by) / length, NEAREST)

  return cf + line * (1 - k), k
end

return common
