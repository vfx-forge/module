--!native
--!optimize 2
const MIN_STEP = 1e-4
const MIN_NORMAL = 1e-6
const MIN_BOUNCE_SPEED = 0.5
const SURFACE_OFFSET = 0.01

const common = {}

-- bounces a piece makes before the next hit pins it
common.MAX_BOUNCES = 16

export type Mode = "Off" | "Kill" | "Stop" | "Bounce"
export type FilterType = "Exclude" | "Include"
export type Hit = { position: vector, normal: vector }

export type Config = {
  mode: Mode,
  bounce: number,
  friction: number,
  filterType: FilterType,
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
    return workspace:Raycast(
      Vector3.new(from.x, from.y, from.z),
      Vector3.new(to.x - from.x, to.y - from.y, to.z - from.z),
      params
    )
  end,
}

-- a filter row's choice as the filter type and tag a cast reads: None leaves
-- out only what the caller excludes. an Include naming no tag would hit
-- nothing at all, so it reads as None
function common.filter(choice: string, tag: string): (FilterType, string)
  if choice == "Include Tag" and tag ~= "" then
    return "Include", tag
  end

  if choice == "Include Tag" then
    return "Exclude", ""
  end

  return "Exclude", if choice == "Exclude Tag" then tag else ""
end

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

-- a path of states mirrored across every surface it bounced off: an
-- unbounced point s is drawn at `anchor + map(s - from)`, the map held as the
-- images of the three axes, and `last` is the unbounced point the path last
-- reached
export type Mirror = {
  anchor: vector,
  from: vector,
  x: vector,
  y: vector,
  z: vector,
  last: vector,
  bounces: number,
}

function common.mirror(start: vector): Mirror
  return {
    anchor = start,
    from = start,
    x = vector.create(1, 0, 0),
    y = vector.create(0, 1, 0),
    z = vector.create(0, 0, 1),
    last = start,
    bounces = 0,
  }
end

-- where the mirror draws the unbounced point `s`, `s` itself before a bounce
function common.mirrored(mirror: Mirror, s: vector): vector
  if mirror.bounces == 0 then
    return s
  end

  const d = s - mirror.from

  return mirror.anchor + mirror.x * d.x + mirror.y * d.y + mirror.z * d.z
end

-- `v` folded across a surface of unit `normal`: the share `bounce` of its part
-- into the surface turned back out, the share `friction` of its part along
-- the surface lost
function common.fold(v: vector, normal: vector, bounce: number, friction: number): vector
  const along = vector.dot(v, normal)

  return (v - normal * along) * (1 - friction) - normal * (along * bounce)
end

-- one step of a mirrored path to the unbounced point `to`, `span` seconds
-- long: what became of it ("move", "stop" or "kill") and where it is drawn.
-- `cast` finds what the drawn step hits, `respond` answers the response at a
-- hit the share it gives of the way through the step, and `bounced` hears of
-- each bounce, with the way the path came in and the way it leaves. a Bounce
-- folds the rest of the path across the surface from the hit, and stops it
-- instead when it meets the surface too slowly or past MAX_BOUNCES
function common.step(
  mirror: Mirror,
  respond: (share: number) -> Config,
  to: vector,
  span: number,
  cast: (from: vector, to: vector) -> Hit?,
  bounced: ((at: vector, incoming: vector, rebound: vector, normal: vector) -> ())?
): (string, vector)
  local from = mirror.last
  local done = 0

  while true do
    const a = common.mirrored(mirror, from)
    const b = common.mirrored(mirror, to)
    const hit = cast(a, b)

    if hit == nil then
      mirror.last = to
      return "move", b
    end

    const incoming = b - a
    const reach = vector.magnitude(incoming)
    const share = if reach > 0 then math.clamp(vector.magnitude(hit.position - a) / reach, 0, 1) else 0
    const config = respond(done + (1 - done) * share)

    if config.mode == "Kill" then
      return "kill", hit.position
    end

    const length = vector.magnitude(hit.normal)

    if config.mode ~= "Bounce" or length < MIN_NORMAL or mirror.bounces >= common.MAX_BOUNCES then
      return "stop", hit.position
    end

    const normal = hit.normal / length
    const into = -vector.dot(incoming, normal)

    if into <= 0 or into < MIN_BOUNCE_SPEED * span * (1 - done) then
      return "stop", hit.position
    end

    const bounce, friction = config.bounce, config.friction

    mirror.x = common.fold(mirror.x, normal, bounce, friction)
    mirror.y = common.fold(mirror.y, normal, bounce, friction)
    mirror.z = common.fold(mirror.z, normal, bounce, friction)
    mirror.anchor = hit.position + normal * SURFACE_OFFSET
    mirror.bounces += 1

    from += (to - from) * share
    mirror.from = from
    done += (1 - done) * share

    if bounced ~= nil then
      bounced(hit.position, incoming, common.fold(incoming, normal, bounce, friction), normal)
    end
  end
end

return common
