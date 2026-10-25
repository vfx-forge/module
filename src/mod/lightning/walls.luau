export type cast = (from: vector, to: vector) -> (vector?, vector?)
export type Clock = { period: number, next: number }

-- a hit this close to a segment's end is the surface the segment was laid to, a latch's or a ground strike's
const END_SLACK = 0.05
const HALVINGS = 3
const TINY = 1e-6
-- how often a bolt that never reshapes is aimed again, a Flow bolt or any bolt at Jitter 0
const IDLE_PERIOD = 0.1

const walls = {}

walls.END_SLACK = END_SLACK
walls.HALVINGS = HALVINGS
walls.IDLE_PERIOD = IDLE_PERIOD

-- the clock a bolt's walls are cast on: a pass is all the casting a bolt does, so outside one a fit casts nothing and
-- reuses the last pass's cuts and bends. a restrike or a reshape forces one; any other fit takes one at most once
-- every 1 / Jitter seconds, or IDLE_PERIOD at Jitter 0
function walls.clock(jitter: number): Clock
  const period = if jitter > 0 then 1 / jitter else IDLE_PERIOD

  return { period = period, next = period }
end

function walls.due(clock: Clock, elapsed: number, forced: boolean?): boolean
  if not forced and elapsed < clock.next then
    return false
  end

  clock.next = elapsed + clock.period

  return true
end

-- where a segment's cast meets something short of its end
function walls.blocked(cast: cast, from: vector, to: vector): (vector?, vector?)
  const point, normal = cast(from, to)

  if not point or vector.magnitude(point - from) >= vector.magnitude(to - from) - END_SLACK then
    return nil, nil
  end

  return point, normal
end

-- the chain laid again with as many joints, evenly by length along its first `through` joints and on to point, so a
-- trimmed fork keeps its taper, its fade and its ring count and never leaves the path it was clear along
function walls.resample(chain: { vector }, through: number, point: vector)
  const count = #chain
  const line = table.create(through + 1)
  const lengths = table.create(through)
  local total = 0

  table.move(chain, 1, through, 1, line)
  line[through + 1] = point

  for k = 1, through do
    lengths[k] = vector.magnitude(line[k + 1] - line[k])
    total += lengths[k]
  end

  local leg = 1
  local walked = 0

  for j = 1, count do
    const want = if count > 1 then total * (j - 1) / (count - 1) else 0

    while leg < through and walked + lengths[leg] < want do
      walked += lengths[leg]
      leg += 1
    end

    const span = lengths[leg]
    const f = if span > TINY then math.clamp((want - walked) / span, 0, 1) else 0

    chain[j] = line[leg] + (line[leg + 1] - line[leg]) * f
  end

  chain[1] = line[1]
  chain[count] = point
end

const function lengthOf(chain: { vector }): number
  local total = 0

  for j = 1, #chain - 1 do
    total += vector.magnitude(chain[j + 1] - chain[j])
  end

  return total
end

-- each segment cast root to tip; the chain ends where the first one meets something, answered with that surface and
-- the share of the chain's length kept, which a fit between passes cuts the chain to again
function walls.trim(chain: { vector }, cast: cast): (vector?, vector?, number?)
  local walked = 0

  for j = 1, #chain - 1 do
    const point, normal = walls.blocked(cast, chain[j], chain[j + 1])

    if point then
      const total = lengthOf(chain)
      const kept = walked + vector.magnitude(point - chain[j])
      const share = if total > TINY then kept / total else 1

      walls.resample(chain, j, point)

      return point, normal, share
    end

    walked += vector.magnitude(chain[j + 1] - chain[j])
  end

  return nil, nil, nil
end

-- the chain cut to the share of its length a pass kept, laid again as trim lays it
function walls.cut(chain: { vector }, share: number)
  if share >= 1 or #chain < 2 then
    return
  end

  const want = lengthOf(chain) * math.max(share, 0)
  local walked = 0

  for j = 1, #chain - 1 do
    const span = vector.magnitude(chain[j + 1] - chain[j])

    if walked + span >= want or j == #chain - 1 then
      const f = if span > TINY then math.clamp((want - walked) / span, 0, 1) else 0

      walls.resample(chain, j, chain[j] + (chain[j + 1] - chain[j]) * f)

      return
    end

    walked += span
  end
end

-- each segment cast in turn, and a joint whose segment meets something pulled halfway to its place on the straight
-- chord, up to HALVINGS times and then onto it; the chain's ends stay, so the far joint of a segment is the one
-- pulled, and the last segment's near one. a chord that itself meets something has its end behind a wall, where the
-- bolt is meant to cross it, and is left as it is. each joint's share of its offset kept goes in bends, which a fit
-- between passes bends the chain by again. answers whether a joint moved
function walls.pull(chain: { vector }, cast: cast, bends: { number }): boolean
  const count = #chain

  table.clear(bends)

  if count < 3 or walls.blocked(cast, chain[1], chain[count]) then
    return false
  end

  const from = chain[1]
  const span = chain[count] - from
  local moved = false

  for i = 1, count - 1 do
    if not walls.blocked(cast, chain[i], chain[i + 1]) then
      continue
    end

    const k = if i + 1 < count then i + 1 else i
    const straight = from + span * ((k - 1) / (count - 1))
    local clear = false

    moved = true

    for _ = 1, HALVINGS do
      chain[k] = straight + (chain[k] - straight) * 0.5
      bends[k] = (bends[k] or 1) * 0.5

      -- a near joint pulled back moves the segment before it too; a far one's next segment is the loop's next
      clear = not walls.blocked(cast, chain[k - 1], chain[k])
        and (k ~= i or not walls.blocked(cast, chain[k], chain[k + 1]))

      if clear then
        break
      end
    end

    if not clear then
      chain[k] = straight
      bends[k] = 0
    end
  end

  return moved
end

-- each joint's offset from the straight chord scaled by the share a pass kept of it; answers whether one moved
function walls.bend(chain: { vector }, bends: { number }): boolean
  const count = #chain
  const from = chain[1]
  const span = chain[count] - from
  local moved = false

  for k, share in bends do
    if k <= 1 or k >= count then
      continue
    end

    const straight = from + span * ((k - 1) / (count - 1))

    chain[k] = straight + (chain[k] - straight) * share
    moved = true
  end

  return moved
end

return walls
