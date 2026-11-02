const common = {}

export type Mode = "None" | "FacingCamera" | "FacingCameraWorldUp" | "VelocityParallel" | "VelocityPerpendicular"

const STILL_SPEED = 1e-6
const NEAR_VERTICAL = 0.999

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

function common.rotation(mode: Mode, base: CFrame, position: vector, velocity: vector, camera: CFrame?): CFrame
  const keep = base.Rotation

  if mode == "None" then
    return keep
  end

  if mode == "VelocityPerpendicular" or mode == "VelocityParallel" then
    const heading = direction(velocity)

    if not heading then
      return keep
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

-- the volume stays: height by 2^s, the other two by 2^(-s/2)
function common.squash(size: Vector3, s: number): Vector3
  const across = 2 ^ (-s / 2)

  return Vector3.new(size.X * across, size.Y * 2 ^ s, size.Z * across)
end

return common
