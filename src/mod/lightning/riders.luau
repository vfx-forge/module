const kinds = require("@mod/lightning/kinds")
const geometry = require("@mod/lightning/geometry")
const timeline = require("@mod/lightning/timeline")

type source = { width0: number, width1: number, transparency: NumberSequence, lifted: NumberSequence }
type segment = { beam: Beam, from: number, source: source, width0: number, width1: number, on: boolean }
type point = { attachment: Attachment, joint: number, emitters: { ParticleEmitter }, on: boolean }
type light = { light: Light, brightness: number, now: number, on: boolean }

export type Riders = {
  opacity: number,
  visible: boolean,
  joints: { Attachment },
  sources: { source },
  beams: { segment },
  points: { point },
  holder: Attachment?,
  lights: { light },
  head: { Attachment },
  trails: { Trail },
  places: { [Attachment]: Vector3 },
}

-- how many places a Bolt ParticleEmitter is cloned to per bolt, its Rate split over them
const POINTS = 5
const UP = vector.create(0, 1, 0)
const SIDE = vector.create(1, 0, 0)
const NEAR_VERTICAL = math.cos(math.rad(25))

const riders = {}

const function strip(piece: Instance)
  for _, tag in piece:GetTags() do
    piece:RemoveTag(tag)
  end
end

-- the lightning drives a clone as a plain instance, so no tag of a loop or a custom effect goes with it
const function copy(child: Instance): any
  const made = child:Clone()

  strip(made)

  for _, piece in made:GetDescendants() do
    strip(piece)
  end

  made.Archivable = false

  return made
end

const function attach(sdk: any, ctx: any, name: string): Attachment
  const attachment = sdk.hold(ctx, Instance.new("Attachment"))

  attachment.Name = name
  attachment.Archivable = false
  attachment.Parent = sdk.container(ctx)

  return attachment
end

-- evenly over the joints inside each chain, so a point never sits on a tip that tapers to nothing or doubles a
-- fork's root; a bolt with no inside joint spreads over all of them
const function spread(perChain: { number }): { number }
  const inside = {}
  local total = 0

  for _, count in perChain do
    for j = 2, count - 1 do
      table.insert(inside, total + j)
    end

    total += count
  end

  if #inside == 0 then
    for i = 1, total do
      table.insert(inside, i)
    end
  end

  const count = math.min(POINTS, #inside)
  const picked = {}

  for k = 1, count do
    picked[k] = inside[math.ceil((k - 0.5) * #inside / count)]
  end

  return picked
end

-- a direction across the head, by the same reference rule as the bolt's rings
const function across(t: vector): vector
  const reference = if math.abs(vector.dot(t, UP)) > NEAR_VERTICAL then SIDE else UP

  return vector.normalize(vector.cross(t, reference))
end

-- the artist's transparency seen through the bolt's fade: every value lifted toward 1 by 1 - opacity
const function lift(sequence: NumberSequence, opacity: number): NumberSequence
  const points = {}

  for i, key in sequence.Keypoints do
    points[i] = NumberSequenceKeypoint.new(key.Time, 1 - (1 - key.Value) * opacity, key.Envelope * opacity)
  end

  return NumberSequence.new(points)
end

const function move(r: Riders, attachment: Attachment, at: Vector3)
  if r.places[attachment] ~= at then
    r.places[attachment] = at
    attachment.WorldPosition = at
  end
end

function riders.build(sdk: any, ctx: any, sorted: kinds.Sorted, perChain: { number }): Riders?
  if sorted.found == 0 then
    return nil
  end

  const r: Riders = {
    opacity = 1,
    visible = false,
    joints = {},
    sources = {},
    beams = {},
    points = {},
    holder = nil,
    lights = {},
    head = {},
    trails = {},
    places = {},
  }

  if #sorted.beam > 0 then
    local total = 0

    for _, count in perChain do
      total += count
    end

    for i = 1, total do
      r.joints[i] = attach(sdk, ctx, "BoltJoint")
    end
  end

  for _, template in sorted.beam do
    const source = {
      width0 = template.Width0,
      width1 = template.Width1,
      transparency = template.Transparency,
      lifted = template.Transparency,
    }
    local base = 0

    table.insert(r.sources, source)

    for _, count in perChain do
      for j = 1, count - 1 do
        const from = base + j
        const beam = copy(template)

        beam.Attachment0 = r.joints[from]
        beam.Attachment1 = r.joints[from + 1]
        beam.Enabled = false
        beam.Parent = r.joints[from]
        table.insert(r.beams, { beam = beam, from = from, source = source, width0 = -1, width1 = -1, on = false })
      end

      base += count
    end
  end

  if #sorted.emitter > 0 then
    const picked = spread(perChain)

    for _, joint in picked do
      const attachment = attach(sdk, ctx, "BoltPoint")
      const emitters = {}

      for _, template in sorted.emitter do
        const emitter = copy(template)

        emitter.Rate = template.Rate / #picked
        emitter.Enabled = false
        emitter.Parent = attachment
        table.insert(emitters, emitter)
      end

      table.insert(r.points, { attachment = attachment, joint = joint, emitters = emitters, on = false })
    end
  end

  if #sorted.light > 0 then
    const holder = attach(sdk, ctx, "BoltLight")

    r.holder = holder

    for _, template in sorted.light do
      const made = copy(template)

      made.Enabled = false
      made.Parent = holder
      table.insert(r.lights, { light = made, brightness = template.Brightness, now = made.Brightness, on = false })
    end
  end

  if #sorted.trail > 0 then
    r.head = { attach(sdk, ctx, "BoltHead"), attach(sdk, ctx, "BoltHead") }

    for _, template in sorted.trail do
      const trail = copy(template)

      trail.Attachment0 = r.head[1]
      trail.Attachment1 = r.head[2]
      trail.Enabled = false
      trail.Parent = r.head[1]
      table.insert(r.trails, trail)
    end
  end

  return r
end

-- width is the Width row now, which the joints' widths are measured in
function riders.draw(
  r: Riders,
  joints: { geometry.Joint },
  state: timeline.State,
  toWorld: CFrame,
  middle: number,
  head: number,
  width: number
)
  const visible = state.visible

  -- a hidden bolt's parked joints are not where it will show again, so nothing follows them
  if visible then
    for i, attachment in r.joints do
      move(r, attachment, toWorld:PointToWorldSpace(joints[i].p))
    end

    for _, point in r.points do
      move(r, point.attachment, toWorld:PointToWorldSpace(joints[point.joint].p))
    end

    if r.holder then
      move(r, r.holder, toWorld:PointToWorldSpace(joints[middle].p))
    end

    if #r.head > 0 then
      const joint = joints[head]
      const at = toWorld:PointToWorldSpace(joint.p)

      move(r, r.head[1], at)
      move(r, r.head[2], at + toWorld:VectorToWorldSpace(across(joint.t)) * width)
    end
  end

  const relift = state.opacity ~= r.opacity

  if relift then
    r.opacity = state.opacity

    for _, source in r.sources do
      source.lifted = lift(source.transparency, state.opacity)
    end
  end

  const scale = if width > 0 then state.width / width else 0

  for _, segment in r.beams do
    const a = joints[segment.from]
    const b = joints[segment.from + 1]
    const on = visible and (a.w > 0 or b.w > 0)
    const beam = segment.beam

    if on then
      const width0 = segment.source.width0 * a.w * scale
      const width1 = segment.source.width1 * b.w * scale

      if width0 ~= segment.width0 then
        segment.width0 = width0
        beam.Width0 = width0
      end

      if width1 ~= segment.width1 then
        segment.width1 = width1
        beam.Width1 = width1
      end
    end

    if relift then
      beam.Transparency = segment.source.lifted
    end

    if on ~= segment.on then
      segment.on = on
      beam.Enabled = on
    end
  end

  for _, point in r.points do
    const on = visible and joints[point.joint].w > 0

    if on ~= point.on then
      point.on = on

      for _, emitter in point.emitters do
        emitter.Enabled = on
      end
    end
  end

  for _, light in r.lights do
    const brightness = light.brightness * state.flash

    if brightness ~= light.now then
      light.now = brightness
      light.light.Brightness = brightness
    end

    if visible ~= light.on then
      light.on = visible
      light.light.Enabled = visible
    end
  end

  if visible ~= r.visible then
    r.visible = visible

    for _, trail in r.trails do
      trail.Enabled = visible
    end
  end
end

function riders.free(r: Riders): number
  for _, attachment in r.joints do
    attachment:Destroy()
  end

  for _, attachment in r.head do
    attachment:Destroy()
  end

  if r.holder then
    r.holder:Destroy()
  end

  local longest = 0

  for _, point in r.points do
    point.on = false

    for _, emitter in point.emitters do
      emitter.Enabled = false
      longest = math.max(longest, emitter.Lifetime.Max)
    end
  end

  r.holder = nil
  table.clear(r.joints)
  table.clear(r.sources)
  table.clear(r.beams)
  table.clear(r.lights)
  table.clear(r.head)
  table.clear(r.trails)

  return longest
end

function riders.last(r: Riders)
  for _, point in r.points do
    point.attachment:Destroy()
  end

  table.clear(r.points)
  table.clear(r.places)
end

return riders
