const UP = vector.create(0, 1, 0)
const SIDE = vector.create(1, 0, 0)
const FORWARD = vector.create(0, 0, 1)
const TINY = 1e-6
const PARALLEL = 1e-3

const impacts = {}

impacts.GROUND_RAYS = 7
impacts.GROUND_CONE = math.rad(35)
impacts.LATCH_RAYS = 5
impacts.LATCH_CONE = math.rad(40)
impacts.LIFT = 0.1

-- a unit vector along v, or the fallback when v is too short to have a direction
const function unit(v: vector, fallback: vector): vector
  const length = vector.magnitude(v)

  if length < TINY then
    return fallback
  end

  return v / length
end

-- the unit part of a direction across a unit axis, or nil when it lies within a milliradian of the axis
-- (vector is float32, so a nearer residual is rounding noise); the part is projected twice to stay square
const function crossing(v: vector, axis: vector): vector?
  const length = vector.magnitude(v)

  if length < TINY then
    return nil
  end

  const unitV = v / length
  const flat = unitV - axis * vector.dot(unitV, axis)

  if vector.magnitude(flat) < PARALLEL then
    return nil
  end

  const once = vector.normalize(flat)

  return vector.normalize(once - axis * vector.dot(once, axis))
end

-- v across axis, else the first fallback that lies across it, else any perpendicular
const function across(v: vector, axis: vector, ...: vector): vector
  const found = crossing(v, axis)

  if found then
    return found
  end

  for _, candidate in { ... } do
    const other = crossing(candidate, axis)

    if other then
      return other
    end
  end

  return vector.normalize(vector.cross(axis, if math.abs(axis.x) < 0.9 then SIDE else UP))
end

-- two perpendiculars to a unit direction
const function sides(direction: vector): (vector, vector)
  const first = vector.normalize(vector.cross(direction, if math.abs(direction.x) < 0.9 then SIDE else UP))

  return first, vector.cross(direction, first)
end

-- a unit direction tilted from down by polar radians, turned round it by turn
const function tilt(down: vector, first: vector, second: vector, polar: number, turn: number): vector
  return down * math.cos(polar) + (first * math.cos(turn) + second * math.sin(turn)) * math.sin(polar)
end

-- a ray cast from exactly on a face misses it (measured 2026-10-24: from a floor's top face it struck the
-- Baseplate below), and a stock Shockwave casts its rays from its own plane, so a host sits a little off the surface
function impacts.lifted(point: vector, normal: vector): vector
  return point + unit(normal, UP) * impacts.LIFT
end

function impacts.axes(normal: vector, travel: vector, facing: string): (vector, vector, vector)
  const n = unit(normal, UP)
  local up = n
  local look = vector.zero

  if facing == "Bolt" then
    look = unit(travel, FORWARD)
    up = across(n, look, UP, SIDE)
  elseif facing == "Upright" then
    up = UP
    look = across(travel, UP, SIDE)
  else
    look = across(travel, n, SIDE, FORWARD)
  end

  -- fromMatrix(point, right, up) puts right x up on the Z column, and LookVector is minus Z
  return vector.cross(look, up), up, look
end

function impacts.cone(down: vector, rays: number, angle: number): { vector }
  const result = { down }
  const first, second = sides(down)
  const count = rays - 1

  for i = 1, count do
    result[i + 1] = tilt(down, first, second, angle, (i - 1) / count * math.pi * 2)
  end

  return result
end

-- the bolt's own direction, straight down, and the rest spread round the direction at the angle
function impacts.fan(direction: vector, down: vector, rays: number, angle: number): { vector }
  const result = { direction }

  if rays < 2 then
    return result
  end

  result[2] = down

  const first, second = sides(direction)
  const count = rays - 2

  for i = 1, count do
    result[i + 2] = tilt(direction, first, second, angle, (i - 1) / count * math.pi * 2)
  end

  return result
end

function impacts.nearest(hits: { { point: vector, distance: number }? }): number?
  local best: number? = nil
  local bestDistance = math.huge

  for i, hit in hits do
    if hit.distance < bestDistance then
      best = i
      bestDistance = hit.distance
    end
  end

  return best
end

function impacts.miss(down: vector, reach: number, next: () -> number): vector
  const first, second = sides(down)

  return tilt(down, first, second, next() * impacts.GROUND_CONE, next() * math.pi * 2) * (reach / 2)
end

function impacts.due(arcs: { number }, fired: { boolean }, head: number): { number }
  const answer = {}

  for i, arc in arcs do
    if not fired[i] and head >= arc then
      fired[i] = true
      table.insert(answer, i)
    end
  end

  return answer
end

return impacts
