export type Joint = {
  p: vector,
  t: vector,
  w: number,
  fade: number,
  arc: number,
  chain: number,
}
type fork = { root: number }
type shape = { forks: { fork } }

const UP = vector.create(0, 1, 0)
const SIDE = vector.create(1, 0, 0)
const NEAR_VERTICAL = math.cos(math.rad(25))
const FORK_SHARE = 0.55
const TINY = 1e-6
const CAP = 0.5
-- the glow shell's radius as a share of the joint's width, against the core's 0.5, and its peak vertex alpha at
-- Strength 1
const GLOW_SCALE = 1.1
const GLOW_ALPHA = 0.8

const geometry = {}

geometry.CORE = { sides = 5, scale = 0.5 }
geometry.GLOW = { sides = 6, scale = GLOW_SCALE, alpha = GLOW_ALPHA }

const function smooth(x: number): number
  const c = math.clamp(x, 0, 1)

  return c * c * (3 - 2 * c)
end

-- two perpendiculars to a direction from a fixed reference, the same rule as the path's offsets
const function frame(direction: vector): (vector, vector)
  const reference = if math.abs(vector.dot(direction, UP)) > NEAR_VERTICAL then SIDE else UP
  const first = vector.normalize(vector.cross(direction, reference))

  return first, vector.cross(direction, first)
end

function geometry.envelope(chain: number, f: number): number
  return smooth(f / if chain == 1 then 0.08 else 0.35) * smooth((1 - f) / 0.2)
end

const function tangent(chain: { vector }, j: number): vector
  const count = #chain
  const span = chain[math.min(j + 1, count)] - chain[math.max(j - 1, 1)]

  if vector.magnitude(span) < TINY then
    return UP
  end

  return vector.normalize(span)
end

function geometry.joints(shape: shape, fitted: { { vector } }, width: number, taper: number, out: { Joint }?): { Joint }
  const joints = out or {}
  local at = 0

  for c, chain in fitted do
    const count = #chain
    const fork = if c > 1 then shape.forks[c - 1] else nil
    const start = if fork then FORK_SHARE * joints[fork.root].w else width
    local arc = if fork then joints[fork.root].arc else 0

    for j = 1, count do
      const f = if count > 1 then (j - 1) / (count - 1) else 0
      const w = start * (1 + (taper - 1) * f)

      if j > 1 then
        arc += vector.magnitude(chain[j] - chain[j - 1])
      end

      at += 1

      if not joints[at] then
        joints[at] = {
          p = vector.zero,
          t = UP,
          w = 0,
          fade = 0,
          arc = 0,
          chain = c,
        }
      end

      const joint = joints[at]

      joint.p = chain[j]
      joint.t = tangent(chain, j)
      joint.w = w
      joint.fade = geometry.envelope(c, f)
      joint.arc = arc
      joint.chain = c
    end
  end

  for i = at + 1, #joints do
    joints[i] = nil
  end

  return joints
end

-- the point at a given arc along joints first..last, clamped to the chain's ends
const function pointAt(joints: { Joint }, first: number, last: number, arc: number): vector
  for k = first, last do
    if joints[k].arc >= arc then
      if k == first then
        return joints[k].p
      end

      const before = joints[k - 1]
      const span = joints[k].arc - before.arc

      if span <= 0 then
        return joints[k].p
      end

      return before.p + (joints[k].p - before.p) * ((arc - before.arc) / span)
    end
  end

  return joints[last].p
end

function geometry.reveal(joints: { Joint }, head: number, tail: number, into: { Joint })
  const count = #joints
  local first = 1

  while first <= count do
    local last = first

    while last < count and joints[last + 1].chain == joints[first].chain do
      last += 1
    end

    const headPoint = pointAt(joints, first, last, head)
    const tailPoint = pointAt(joints, first, last, tail)

    for i = first, last do
      const joint = joints[i]

      if not into[i] then
        into[i] = {
          p = vector.zero,
          t = UP,
          w = 0,
          fade = 0,
          arc = 0,
          chain = 0,
        }
      end

      const copy = into[i]

      copy.t = joint.t
      copy.fade = joint.fade
      copy.arc = joint.arc
      copy.chain = joint.chain

      if joint.arc > head then
        copy.p = headPoint
        copy.w = 0
      elseif joint.arc < tail then
        copy.p = tailPoint
        copy.w = 0
      else
        copy.p = joint.p
        copy.w = joint.w
      end
    end

    first = last + 1
  end

  for i = count + 1, #into do
    into[i] = nil
  end
end

-- a joint with width beside another in its chain, so it sits on a drawn segment: reveal parks a hidden joint at the
-- head or a fork's root with no width, and a lone joint with width draws nothing
const function onSegment(joints: { Joint }, i: number)
  const joint = joints[i]

  if joint.w <= 0 then
    return false
  end

  const before = joints[i - 1]
  const after = joints[i + 1]

  return (before ~= nil and before.chain == joint.chain and before.w > 0)
    or (after ~= nil and after.chain == joint.chain and after.w > 0)
end

function geometry.pick(joints: { Joint }, next: () -> number): number?
  local drawn = 0

  for i in joints do
    if onSegment(joints, i) then
      drawn += 1
    end
  end

  if drawn == 0 then
    return nil
  end

  local left = math.min(drawn, 1 + math.floor(next() * drawn))

  for i in joints do
    if onSegment(joints, i) then
      left -= 1

      if left == 0 then
        return i
      end
    end
  end

  return nil
end

-- the rounded ends of one chain: a point behind its first joint and one past its last
const function cap(first: Joint, last: Joint, radius: number, out: { vector }, at: number): number
  out[at + 1] = first.p - first.t * (first.w * radius * CAP)
  out[at + 2] = last.p + last.t * (last.w * radius * CAP)

  return at + 2
end

-- per chain, its rings in joint order, then its two cap points; faces and along write the same layout
function geometry.tube(joints: { Joint }, sides: number, radius: number, out: { vector }): number
  local at = 0
  local chain = 0
  local first = UP
  local head: Joint? = nil
  local tail: Joint? = nil

  for _, joint in joints do
    local second = UP

    if joint.chain ~= chain then
      if head and tail then
        at = cap(head, tail, radius, out, at)
      end

      head = joint
      chain = joint.chain
      first, second = frame(joint.t)
    else
      -- carried along the chain so adjacent rings never twist at the reference switch
      const carried = first - joint.t * vector.dot(first, joint.t)

      if vector.magnitude(carried) < TINY then
        first, second = frame(joint.t)
      else
        first = vector.normalize(carried)
        second = vector.cross(joint.t, first)
      end
    end

    tail = joint

    const reach = joint.w * radius

    for s = 1, sides do
      const angle = 2 * math.pi * (s - 1) / sides

      at += 1
      out[at] = joint.p + (first * math.cos(angle) + second * math.sin(angle)) * reach
    end
  end

  if head and tail then
    at = cap(head, tail, radius, out, at)
  end

  for i = at + 1, #out do
    out[i] = nil
  end

  return at
end

-- a fork's arc starts at its root's, so it carries the gradient on from where it leaves unless restart takes that off
function geometry.u(arc: number, start: number, longest: number, restart: boolean): number
  if longest <= 0 then
    return 0
  end

  return math.clamp((if restart then arc - start else arc) / longest, 0, 1)
end

function geometry.along(joints: { Joint }, across: number, longest: number, out: { number }, restart: boolean?): number
  local at = 0
  local chain = 0
  local head = 0
  local tail = 0
  local start = 0

  const function value(joint: Joint): number
    return geometry.u(joint.arc, start, longest, restart == true)
  end

  for _, joint in joints do
    if joint.chain ~= chain then
      if chain ~= 0 then
        out[at + 1] = head
        out[at + 2] = tail
        at += 2
      end

      chain = joint.chain
      start = joint.arc
      head = value(joint)
    end

    tail = value(joint)

    for _ = 1, across do
      at += 1
      out[at] = tail
    end
  end

  if chain ~= 0 then
    out[at + 1] = head
    out[at + 2] = tail
    at += 2
  end

  for i = at + 1, #out do
    out[i] = nil
  end

  return at
end

function geometry.faces(perChain: { number }, across: number, closed: boolean): { { number } }
  const faces = {}
  local base = 0

  for _, count in perChain do
    for j = 1, count - 1 do
      for s = 1, if closed then across else across - 1 do
        const a = base + (j - 1) * across + s
        const b = base + (j - 1) * across + (s % across) + 1
        const c = a + across
        const d = b + across

        faces[#faces + 1] = { a, b, c }
        faces[#faces + 1] = { b, d, c }
      end
    end

    -- the fans use the chain's two cap vertices, which sit after its rings
    if closed and count > 0 then
      const front = base + count * across + 1
      const back = front + 1
      const last = base + (count - 1) * across

      for s = 1, across do
        const nextSide = s % across + 1

        faces[#faces + 1] = { base + nextSide, base + s, front }
        faces[#faces + 1] = { last + s, last + nextSide, back }
      end
    end

    base += count * across + 2
  end

  return faces
end

function geometry.alphas(joints: { Joint }, profile: { number }, strength: number, out: { number }): number
  const across = #profile
  local at = 0
  local chain = 0
  local head = 0
  local tail = 0

  for _, joint in joints do
    if joint.chain ~= chain then
      if chain ~= 0 then
        out[at + 1] = head * strength * profile[1]
        out[at + 2] = tail * strength * profile[1]
        at += 2
      end

      chain = joint.chain
      head = joint.fade
    end

    tail = joint.fade

    for k = 1, across do
      at += 1
      out[at] = profile[k] * strength * joint.fade
    end
  end

  if chain ~= 0 then
    out[at + 1] = head * strength * profile[1]
    out[at + 2] = tail * strength * profile[1]
    at += 2
  end

  for i = at + 1, #out do
    out[i] = nil
  end

  return at
end

return geometry
