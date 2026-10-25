const impacts = require("@mod/lightning/impacts")

const TINY = 1e-6
const PIECE_SKIPS = 8
const WORLD_DOWN = Vector3.new(0, -1, 0)

const world = {}

function world.params(ref: Attachment): RaycastParams
  const params = RaycastParams.new()

  params.FilterType = Enum.RaycastFilterType.Exclude
  params.IgnoreWater = true
  params.RespectCanCollide = true

  if ref.Parent and ref.Parent:IsA("BasePart") then
    params.FilterDescendantsInstances = { ref.Parent }
  end

  return params
end

-- pieces other effects keep under Terrain collide (a Shockwave's debris does) but are not surfaces, so a ray that
-- meets one leaves it out of this strike's rays and goes on
const function cast(origin: Vector3, direction: Vector3, params: RaycastParams): RaycastResult?
  const terrain = workspace.Terrain

  for _ = 0, PIECE_SKIPS do
    const result = workspace:Raycast(origin, direction, params)

    if not result or result.Instance == terrain or not result.Instance:IsDescendantOf(terrain) then
      return result
    end

    params:AddToFilter(result.Instance)
  end

  return nil
end

-- the nearest hit of rays from one origin, each reach long
const function closest(
  origin: Vector3,
  directions: { vector },
  reach: number,
  params: RaycastParams
): (Vector3?, Vector3?)
  const hits = {}
  const found = {}

  for _, direction in directions do
    const result = cast(origin, Vector3.new(direction.x, direction.y, direction.z) * reach, params)

    if result then
      table.insert(hits, {
        point = vector.create(result.Position.X, result.Position.Y, result.Position.Z),
        distance = result.Distance,
      })
      table.insert(found, result)
    end
  end

  const best = impacts.nearest(hits)

  if not best then
    return nil, nil
  end

  return found[best].Position, found[best].Normal
end

function world.ground(origin: Vector3, down: Vector3, reach: number, params: RaycastParams): (Vector3?, Vector3?)
  const directions = impacts.cone(vector.create(down.X, down.Y, down.Z), impacts.GROUND_RAYS, impacts.GROUND_CONE)

  return closest(origin, directions, reach, params)
end

function world.latch(tip: Vector3, directions: { Vector3 }, reach: number, params: RaycastParams): (Vector3?, Vector3?)
  return closest(tip, directions, reach, params)
end

function world.cross(a: Vector3, b: Vector3, params: RaycastParams): (Vector3?, Vector3?)
  const result = cast(a, b - a, params)

  if not result then
    return nil, nil
  end

  return result.Position, result.Normal
end

-- a fork strikes what its chord crosses, else bends onto the nearest surface its fan of rays finds within latch of
-- its tip; the bent chord is checked again, so a latch never lays a fork through a wall
function world.fork(root: Vector3, tip: Vector3, latch: number, params: RaycastParams): (Vector3?, Vector3?)
  const crossed, crossedNormal = world.cross(root, tip, params)

  if crossed then
    return crossed, crossedNormal
  end

  const chord = tip - root

  if latch <= 0 or chord.Magnitude <= TINY then
    return nil, nil
  end

  const fan = impacts.fan(chord.Unit, WORLD_DOWN, impacts.LATCH_RAYS, impacts.LATCH_CONE)
  const at, facing = world.latch(tip, fan, latch, params)

  if not at then
    return nil, nil
  end

  const through, throughNormal = world.cross(root, at, params)

  if through then
    return through, throughNormal
  end

  return at, facing
end

-- a segment's cast, for the walls a fit pulls the bolt out of
function world.caster(params: RaycastParams): (from: vector, to: vector) -> (vector?, vector?)
  return function(from: vector, to: vector)
    return world.cross(from, to, params)
  end
end

function world.beyond(finish: Vector3, travel: Vector3, params: RaycastParams): (Vector3?, Vector3?)
  return world.cross(finish - travel * 0.5, finish + travel, params)
end

return world
