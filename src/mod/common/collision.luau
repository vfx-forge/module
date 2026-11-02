const MIN_STEP = 1e-4
const MIN_NORMAL = 1e-6
const MIN_BOUNCE_SPEED = 0.5
const SURFACE_OFFSET = 0.01

const common = {}

export type Mode = "Off" | "Kill" | "Stop" | "Bounce"

export type Config = {
  mode: Mode,
  bounce: number,
  friction: number,
  filterType: Enum.RaycastFilterType,
  filterTag: string,
  group: string,
  respectCanCollide: boolean,
}

-- the engine calls, held here so a spec can stand in for them under lune
common.engine = {
  params = function(): RaycastParams
    return RaycastParams.new()
  end,
  tagged = function(tag: string): { Instance }
    return game:GetService("CollectionService"):GetTagged(tag)
  end,
  raycast = function(params: RaycastParams, from: vector, to: vector): RaycastResult?
    const origin, direction = from, to - from

    return workspace:Raycast(
      Vector3.new(origin.x, origin.y, origin.z),
      Vector3.new(direction.x, direction.y, direction.z),
      params
    )
  end,
}

-- Terrain is never filtered out, so the ground stays hittable
function common.params(config: Config, exclude: { Instance }): RaycastParams
  const params = common.engine.params()
  const tagged = if config.filterTag ~= "" then common.engine.tagged(config.filterTag) else {}

  params.FilterType = Enum.RaycastFilterType[config.filterType :: any]
  params.CollisionGroup = config.group
  params.RespectCanCollide = config.respectCanCollide

  if config.filterType == "Include" then
    params:AddToFilter(tagged)
  else
    params:AddToFilter(exclude)
    params:AddToFilter(tagged)
  end

  return params
end

function common.cast(params: RaycastParams, from: vector, to: vector): RaycastResult?
  if vector.magnitude(to - from) < MIN_STEP then
    return nil
  end

  return common.engine.raycast(params, from, to)
end

function common.respond(
  config: Config,
  velocity: vector,
  hit: { position: vector, normal: vector }
): (string, vector, vector)
  if config.mode == "Kill" then
    return "kill", hit.position, velocity
  end

  const length = vector.magnitude(hit.normal)

  if config.mode ~= "Bounce" or length < MIN_NORMAL then
    return "stop", hit.position, vector.zero
  end

  const normal = hit.normal / length
  const along = vector.dot(velocity, normal)
  const tangent = velocity - normal * along
  const speed = math.max(-along, 0) * config.bounce

  if speed < MIN_BOUNCE_SPEED then
    return "stop", hit.position, vector.zero
  end

  return "bounce", hit.position + normal * SURFACE_OFFSET, normal * speed + tangent * (1 - config.friction)
end

return common
