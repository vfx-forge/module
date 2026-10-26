const path = require("@mod/lightning/path")
const walls = require("@mod/lightning/walls")
const world = require("@mod/lightning/world")
const impacts = require("@mod/lightning/impacts")
const geometry = require("@mod/lightning/geometry")

export type Hit = { chain: number, point: Vector3, normal: Vector3 }
export type Impact = { chain: number, onEnd: boolean, point: Vector3, normal: Vector3, travel: Vector3 }
export type Bolt = {
  next: () -> number,
  shape: path.Shape,
  fitted: path.Fitted,
  joints: { geometry.Joint },
  targets: { [number]: Vector3 },
  trims: { [number]: Hit },
  cuts: { [number]: number },
  bends: { number },
  cast: walls.cast?,
  aim: Vector3,
  miss: Vector3?,
  fitEnd: Vector3,
  -- the bolt's end in the ref's own space with no StartOffset, so a moving start leaves the end where it is
  endAt: Vector3?,
  atFit: CFrame,
  -- the StartOffset the frame passed as now is moved by, and the one atFit was. what the bolt keeps between frames
  -- (its end, latched fork tips, impacts) is kept in the ref's own space and placed through it
  shift: Vector3,
  fitShift: Vector3,
  width: number,
  longest: number,
  middle: number,
  length: number,
}

const TINY = 1e-6

const strike = {}

-- a destroyed attachment reads its world frame as its own offset (measured 2026-10-23), so one with no parent
-- is no place to draw to
function strike.live(attachment: Attachment?): Attachment?
  return if attachment and attachment.Parent ~= nil then attachment else nil
end

function strike.ends(fitted: path.Fitted)
  const ends = {}
  local at = 0

  for c, chain in fitted do
    at += #chain
    ends[c] = at
  end

  return ends
end

export type walled = "pass" | "skip"

-- a pass casts the main bolt's joints out of what they cross and ends each fork at the first thing it meets, against
-- the surfaces the last aim cast for, keeping what it did as bends and cuts; any other fit casts nothing and lays the
-- same bends and cuts on the shape as it now stands
const function clear(b: Bolt, origin: Vector3, finish: Vector3, pass: boolean)
  const cast = b.cast
  const fitted = b.fitted

  if pass and cast then
    table.clear(b.trims)
    table.clear(b.cuts)

    if walls.pull(fitted[1], cast, b.bends) then
      path.forks(b.shape, origin, finish, fitted)
    end

    for i in b.shape.forks do
      const point, normal, share = walls.trim(fitted[i + 1], cast)

      if point and normal and share then
        b.trims[i] = { chain = i + 1, point = point, normal = normal }
        b.cuts[i] = share
      end
    end

    return
  end

  if walls.bend(fitted[1], b.bends) then
    path.forks(b.shape, origin, finish, fitted)
  end

  for i, share in b.cuts do
    const chain = fitted[i + 1]

    if chain then
      walls.cut(chain, share)
    end
  end
end

-- every vertex is written in the world as it stood at this fit, with the parts at identity. walled "pass" casts for
-- the walls, "skip" leaves them out, for a fit the caller fits again before it draws, and none reuses the last pass
function strike.fit(b: Bolt, now: CFrame, finish: Vector3, width: number, taper: number, walled: walled?)
  const origin = now.Position
  const ending = now:PointToWorldSpace(finish)

  for i, fork in b.shape.forks do
    const target = b.targets[i]

    fork.target = if target then now:PointToWorldSpace(target - b.shift) else nil
  end

  path.fit(b.shape, origin, ending, b.fitted)

  if walled ~= "skip" then
    clear(b, origin, ending, walled == "pass")
  end

  geometry.joints(b.shape, b.fitted, width, taper, b.joints)

  local longest = 0
  local length = 0

  for _, joint in b.joints do
    longest = math.max(longest, joint.arc)

    if joint.chain == 1 then
      length = joint.arc
    end
  end

  local middle = 1

  for i, joint in b.joints do
    if joint.chain == 1 and math.abs(joint.arc - length / 2) < math.abs(b.joints[middle].arc - length / 2) then
      middle = i
    end
  end

  b.atFit = now
  b.fitShift = b.shift
  b.fitEnd = finish
  b.width = width
  b.longest = longest
  b.middle = middle
  b.length = length
end

-- the main bolt's end in the ref's space, with the surface it struck when that makes an impact. Direction keeps the
-- aim its strike drew in the ref's space and Ground the miss it drew, so a bolt aimed again follows the ref and what
-- is around it without jumping to a new random end; surfaces is false once no impact is wanted, which spares End
-- the ray past its end. now is the ref's frame moved by the bolt's shift, which moves the start alone: every end is
-- found from the ref itself. EndOffset moves the end along the ref's axes, and on Ground where the surface is looked
-- for
const function resolve(
  attrs: any,
  b: Bolt,
  now: CFrame,
  params: RaycastParams,
  finishAt: Attachment?,
  surfaces: boolean
): (Vector3, Vector3?, Vector3?)
  const origin = now.Position
  const offset = attrs.EndOffset - b.shift

  if attrs.Target == "Direction" then
    const along = b.aim * attrs.Length + offset
    const reach = now:VectorToWorldSpace(along)

    if along.Magnitude <= TINY then
      return along, nil, nil
    end

    -- a Direction bolt stops at the first surface its line crosses and strikes it
    const point, normal = world.cross(origin, origin + reach, params)

    if point then
      return now:PointToObjectSpace(point), point, normal
    end

    return along, nil, nil
  end

  if attrs.Target == "Ground" then
    const down = -now.UpVector
    const point, normal = world.ground(now:PointToWorldSpace(offset), down, attrs.Reach, params)

    if point then
      return now:PointToObjectSpace(point), point, normal
    end

    if not b.miss then
      b.miss = now:VectorToObjectSpace(impacts.miss(down, attrs.Reach, b.next))
    end

    return (b.miss :: Vector3) + offset, nil, nil
  end

  const ending = strike.live(finishAt)

  -- an End destroyed mid bolt leaves the bolt on the end it had
  if not ending then
    return if b.endAt then b.endAt - b.shift else b.fitEnd, nil, nil
  end

  const placed = now:PointToObjectSpace(ending.WorldPosition) + attrs.EndOffset
  const finish = now:PointToWorldSpace(placed)
  const travel = finish - origin

  if not surfaces or travel.Magnitude < TINY then
    return placed, nil, nil
  end

  const point, normal = world.beyond(finish, travel.Unit, params)

  return placed, point, normal
end

-- the shape aimed again from where the ref is now: its end resolved, every fork's latch cast for, and every surface
-- that makes an impact, cast again on every strike and reshape so the bolt follows the ref and the world around it.
-- its last fit is a pass of the walls
function strike.aim(
  attrs: any,
  b: Bolt,
  ref: Attachment,
  now: CFrame,
  finishAt: Attachment?,
  surfaces: boolean
): { Hit }
  const params = world.params(ref)
  const finish, point, normal = resolve(attrs, b, now, params, finishAt, surfaces)

  b.endAt = finish + b.shift
  const hits = {}
  const struck = {}

  b.cast = world.caster(params)

  if point and normal then
    table.insert(hits, { chain = 1, point = point, normal = normal })
  end

  table.clear(b.targets)
  strike.fit(b, now, finish, b.width, attrs.Taper, "skip")

  for i in b.shape.forks do
    const chain = b.fitted[i + 1]
    const at, facing = world.fork(chain[1], chain[#chain], attrs.Latch, params)

    if at and facing then
      b.targets[i] = now:PointToObjectSpace(at) + b.shift
      struck[i] = { chain = i + 1, point = at, normal = facing }
    end
  end

  strike.fit(b, now, finish, b.width, attrs.Taper, "pass")

  -- a fork stopped short by a wall strikes there when it latches or was already striking
  for i in b.shape.forks do
    const trim = b.trims[i]

    if trim and (attrs.Latch > 0 or struck[i]) then
      table.insert(hits, trim)
    elseif struck[i] then
      table.insert(hits, struck[i])
    end
  end

  return hits
end

-- a new shape and its aim; flowed is how many bolt lengths a Flow bolt's kinks have slid so far
function strike.make(
  attrs: any,
  b: Bolt,
  ref: Attachment,
  now: CFrame,
  finishAt: Attachment?,
  surfaces: boolean,
  flowed: number
): { Hit }
  b.shape = path.make(b.next, {
    detail = math.floor(attrs.Detail),
    forks = math.floor(attrs.Forks),
    forkLength = attrs.ForkLength,
    jagged = attrs.Jagged,
  })

  -- Flow's offsets are another pattern than make's zigzag, so a Flow bolt shows them from its first frame, slid as
  -- far as the frame loop has flowed them
  if attrs.Motion == "Flow" then
    path.flow(b.shape, flowed, 1, attrs.Jagged)
  end

  b.miss = nil

  if attrs.Target == "Direction" then
    const spread = attrs.Spread

    b.aim = now:VectorToObjectSpace(
      path.spread(now.UpVector, now.RightVector, now.LookVector, vector.create(spread.X, spread.Y, 0), b.next)
    )
  end

  return strike.aim(attrs, b, ref, now, finishAt, surfaces)
end

-- what each hit needs to fire, kept in the space of what carries it: End for the main tip in End mode, else the ref
-- with no StartOffset
function strike.impacts(b: Bolt, now: CFrame, hits: { Hit }, ends: { number }, finishAt: Attachment?): { Impact }
  const list = {}

  for i, h in hits do
    const joint = b.joints[ends[h.chain]]
    const onEnd = h.chain == 1 and finishAt ~= nil
    const space = if onEnd and finishAt then finishAt.WorldCFrame else now

    list[i] = {
      chain = h.chain,
      onEnd = onEnd,
      point = space:PointToObjectSpace(h.point) + (if onEnd then Vector3.zero else b.shift),
      normal = space:VectorToObjectSpace(h.normal),
      travel = space:VectorToObjectSpace(joint.t),
    }
  end

  return list
end

return strike
