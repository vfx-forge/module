-- run through the VFX Forge MCP's studio_execute_luau with each paste line replaced by that module's text, and
-- comment lines, blank lines and indentation stripped so the paste stays small:
-- gawk 'match($0, /^ *--@paste ([a-z_]+)$/, m) { f = "src/mod/lightning/" m[1] ".luau"; while ((getline l < f) > 0) { sub(/^export type/, "type", l); print l }; next } { print }' tests/forge_lightning_studio/riders_check.luau | grep -v -E '^\s*(--.*)?$' | sed -E 's/^\s+//'
-- the sandbox can neither require a ModuleScript it made nor parent into the place, so each module is pasted as a
-- function body, script and require are shadowed below, and riders takes a stand-in workspace whose Terrain is an
-- anchored Part of the check's own at the world's origin, so an attachment under it reads world positions
-- a module whose file does not exist yet is left empty, so its require fails by name
-- nothing is placed: everything made is held and destroyed before the call answers; any FAIL raises with the whole
-- output

const modules = {}

const script = {
  Parent = setmetatable({}, {
    __index = function(_, name: string)
      return name
    end,
  }),
}

const function require(name: string): any
  const found = modules[name]

  if found == nil then
    error(`no module {name}`, 2)
  end

  return found
end

modules.kinds = (function()
  --@paste kinds
end)()

modules.geometry = (function()
  --@paste geometry
end)()

modules.timeline = (function()
  --@paste timeline
end)()

-- riders reads workspace.Terrain when it builds, so it loads with a stand-in
const function loadRiders(workspace: any)
  --@paste riders
end

const TOLERANCE = 1e-3
const WIDTH = 0.6
const TAPER = 0.5
const FORK_ROOT = 4
const MAIN = 9
const FORK = 4
const POINTS = 5
const RATE = 40
const BRIGHTNESS = 2
const TAG = "ConstantVFX"
const TO_WORLD = CFrame.new(10, -4, 6) * CFrame.Angles(0, math.rad(30), 0)

const held = {}
const lines = {}
local failed = false

const sdk = {
  hold = function(_, thing)
    table.insert(held, thing)

    return thing
  end,
}

const function check(what: string, ok: boolean, detail: string?)
  if ok then
    table.insert(lines, `ok {what}`)
  else
    failed = true
    table.insert(lines, `FAIL {what}{if detail then `: {detail}` else ""}`)
  end
end

const function near(a: Vector3, b: Vector3): boolean
  return (a - b).Magnitude < TOLERANCE
end

const function close(a: number, b: number): boolean
  return math.abs(a - b) < 1e-4
end

const function sequenceNear(a: NumberSequence, b: NumberSequence): boolean
  if #a.Keypoints ~= #b.Keypoints then
    return false
  end

  for k, point in a.Keypoints do
    const other = b.Keypoints[k]

    if not close(point.Time, other.Time) or not close(point.Value, other.Value) then
      return false
    end

    if not close(point.Envelope, other.Envelope) then
      return false
    end
  end

  return true
end

-- a zigzag main bolt up +Y and one fork off its fourth joint, laid out chain by chain as geometry.joints does
const function handBolt(): { any }
  const joints = {}
  local arc = 0

  for j = 1, MAIN do
    const p = vector.create(if j % 2 == 0 then 0.8 else 0, 2 * (j - 1), 0)
    const f = (j - 1) / (MAIN - 1)

    if j > 1 then
      arc += vector.magnitude(p - joints[j - 1].p)
    end

    table.insert(joints, { p = p, t = vector.zero, w = WIDTH * (1 + (TAPER - 1) * f), fade = 1, arc = arc, chain = 1 })
  end

  const root = joints[FORK_ROOT]
  local forkArc = root.arc

  for j = 1, FORK do
    const p = root.p + vector.create(1.5 * (j - 1), 1.2 * (j - 1), 0)
    const f = (j - 1) / (FORK - 1)

    if j > 1 then
      forkArc += vector.magnitude(p - joints[#joints].p)
    end

    table.insert(
      joints,
      { p = p, t = vector.zero, w = 0.55 * root.w * (1 + (TAPER - 1) * f), fade = 1, arc = forkArc, chain = 2 }
    )
  end

  for i, joint in joints do
    const before = joints[i - 1]
    const after = joints[i + 1]
    const a = if before and before.chain == joint.chain then before.p else joint.p
    const b = if after and after.chain == joint.chain then after.p else joint.p

    joint.t = vector.normalize(b - a)
  end

  return joints
end

const function run()
  const kinds = require("kinds")
  const geometry = require("geometry")
  const terrain = sdk.hold(nil, Instance.new("Part"))

  terrain.Name = "Terrain"
  terrain.Anchored = true
  terrain.CFrame = CFrame.identity

  const stage = { Terrain = terrain }
  const riders = loadRiders(stage)
  const joints = handBolt()
  const perChain = { MAIN, FORK }
  const segments = (MAIN - 1) + (FORK - 1)

  -- the folder the artist fills: a Beam, two ParticleEmitters, a Trail, a PointLight and a Shockwave
  const folder = sdk.hold(nil, Instance.new("Folder"))

  folder.Name = "Bolt"

  const beam = Instance.new("Beam")

  beam.Width0 = 0.8
  beam.Width1 = 0.4
  beam.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.2, 0.1),
    NumberSequenceKeypoint.new(1, 0.6),
  })
  beam.Parent = folder

  const sparks = Instance.new("ParticleEmitter")

  sparks.Rate = RATE
  sparks.Lifetime = NumberRange.new(1, 2)
  sparks:AddTag(TAG)
  sparks:SetAttribute("EmitCount", 12)
  sparks.Parent = folder

  const smoke = Instance.new("ParticleEmitter")

  smoke.Rate = RATE / 2
  smoke.Lifetime = NumberRange.new(0.5, 3)
  smoke.Parent = folder

  const trail = Instance.new("Trail")

  trail.Parent = folder

  const light = Instance.new("PointLight")

  light.Brightness = BRIGHTNESS
  light.Parent = folder

  const shockwave = Instance.new("Attachment")

  shockwave.Name = "Shockwave"
  shockwave:AddTag("Shockwave")
  Instance.new("ParticleEmitter").Parent = shockwave
  shockwave.Parent = folder

  const started = os.clock()
  const built, r = pcall(riders.build, sdk, {}, kinds.sort(folder:GetChildren()), perChain)

  table.insert(lines, `riders.build {string.format("%.2f", (os.clock() - started) * 1000)} ms`)
  check("riders.build answers riders", built and r ~= nil, if built then nil else tostring(r))

  if not built or not r then
    return
  end

  check(`one attachment per joint {#r.joints}`, #r.joints == #joints, `want {#joints}`)
  check(`one beam per segment {#r.beams}`, #r.beams == segments, `want {segments}`)
  check(`emitter points {#r.points}`, #r.points == POINTS, `want {POINTS}`)
  check(`lights {#r.lights}`, #r.lights == 1, "want 1")
  check(`trails {#r.trails}`, #r.trails == 1, "want 1")

  local beamsOk = 0

  for _, segment in r.beams do
    const made = segment.beam
    const a = made.Attachment0
    const b = made.Attachment1

    if
      made.Parent == r.joints[segment.from]
      and a == r.joints[segment.from]
      and b == r.joints[segment.from + 1]
      and not made.Archivable
    then
      beamsOk += 1
    end
  end

  check("each beam spans its segment's two joint attachments", beamsOk == segments, `{beamsOk} of {segments}`)

  local split = 0
  local tagged = 0
  local shockwaves = 0

  for _, point in r.points do
    const emitters = point.attachment:GetChildren()

    if #emitters == 2 then
      for _, emitter in emitters do
        const want = if emitter.Lifetime.Max == 2 then RATE / POINTS else RATE / 2 / POINTS

        if emitter:IsA("ParticleEmitter") and close(emitter.Rate, want) and not emitter.Enabled then
          split += 1
        end

        if #emitter:GetTags() > 0 then
          tagged += 1
        end
      end
    end
  end

  check("each point holds both emitters, off, their Rates split over the points", split == 2 * POINTS, `{split}`)
  check("the clones carry no tags", tagged == 0, `{tagged} tagged`)

  for _, piece in terrain:GetDescendants() do
    if piece:HasTag("Shockwave") or piece.Name == "Shockwave" then
      shockwaves += 1
    end
  end

  check("nothing is made for the Shockwave", shockwaves == 0, `{shockwaves}`)

  const made = #terrain:GetChildren()
  const want = #joints + POINTS + 1 + 2

  check(
    `Terrain holds the joints, the points, the light holder and the two head attachments {made}`,
    made == want,
    `want {want}`
  )

  check(
    "the light rides one holder",
    r.holder ~= nil and r.lights[1].light.Parent == r.holder and r.lights[1].light:IsA("PointLight")
  )
  check(
    "the trail spans the two head attachments",
    r.trails[1].Attachment0 == r.head[1] and r.trails[1].Attachment1 == r.head[2]
  )

  -- the head at 60% of the main bolt: its last joints and the fork's tip are parked at their heads
  local longest = 0

  for _, joint in joints do
    if joint.chain == 1 then
      longest = math.max(longest, joint.arc)
    end
  end

  const shown = {}

  geometry.reveal(joints, longest * 0.6, 0, shown)

  const state = { visible = true, width = 0.5, opacity = 0.5, flash = 0.8 }
  const middle = 5
  const drew = os.clock()

  riders.draw(r, shown, state, TO_WORLD, middle, MAIN, WIDTH)
  table.insert(lines, `riders.draw {string.format("%.3f", (os.clock() - drew) * 1000)} ms`)

  local placed = 0

  for i, attachment in r.joints do
    if near(attachment.WorldPosition, TO_WORLD:PointToWorldSpace(shown[i].p)) then
      placed += 1
    end
  end

  check("joint attachments sit at the shown joints through toWorld", placed == #joints, `{placed} of {#joints}`)

  local drawnBeam = nil
  local hiddenBeam = nil

  for _, segment in r.beams do
    const a = shown[segment.from]
    const b = shown[segment.from + 1]

    if a.w > 0 and b.w > 0 and not drawnBeam then
      drawnBeam = segment
    end

    if a.w == 0 and b.w == 0 and not hiddenBeam then
      hiddenBeam = segment
    end
  end

  check("the reveal leaves a drawn and a hidden segment", drawnBeam ~= nil and hiddenBeam ~= nil)

  -- a Beam keeps no envelope: it reads back 0 whatever was written (measured 2026-10-24)
  const lifted = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.6),
    NumberSequenceKeypoint.new(1, 0.8),
  })

  if drawnBeam then
    const made = drawnBeam.beam
    const a = shown[drawnBeam.from]
    const b = shown[drawnBeam.from + 1]
    const want0 = 0.8 * a.w / WIDTH * state.width
    const want1 = 0.4 * b.w / WIDTH * state.width

    check("a drawn segment's beam is on", made.Enabled)
    check(
      `its widths taper with its joints {string.format("%.3f %.3f", made.Width0, made.Width1)}`,
      close(made.Width0, want0) and close(made.Width1, want1),
      `want {string.format("%.3f %.3f", want0, want1)}`
    )
    check("its transparency is lifted by 1 - opacity", sequenceNear(made.Transparency, lifted), `{made.Transparency}`)
  end

  if hiddenBeam then
    check("a hidden segment's beam is off", not hiddenBeam.beam.Enabled)
  end

  local on = 0
  local offOk = 0

  for _, point in r.points do
    const joint = shown[point.joint]
    const lit = point.attachment:FindFirstChildOfClass("ParticleEmitter").Enabled

    if joint.w > 0 and lit then
      on += 1
    elseif joint.w == 0 and not lit then
      offOk += 1
    end

    if not near(point.attachment.WorldPosition, TO_WORLD:PointToWorldSpace(joint.p)) then
      on = -100
    end
  end

  check(
    `points at shown joints emit and the rest wait {on} on {offOk} off`,
    on > 0 and offOk > 0 and on + offOk == POINTS,
    `want {POINTS} in all`
  )

  const headAt = TO_WORLD:PointToWorldSpace(shown[MAIN].p)
  const gap = (r.head[2].WorldPosition - r.head[1].WorldPosition).Magnitude
  const tangent = TO_WORLD:VectorToWorldSpace(shown[MAIN].t)
  const along = math.abs((r.head[2].WorldPosition - r.head[1].WorldPosition).Unit:Dot(tangent))

  check("the trail's first attachment sits at the head", near(r.head[1].WorldPosition, headAt))
  check(`the trail's attachments sit Width apart across the head {gap}`, close(gap, WIDTH) and along < 1e-3)
  check("the trail is on while the bolt is visible", r.trails[1].Enabled)

  -- Width animated to twice its first value: the joints widen with it, and the beams keep the artist's width as a
  -- share of Width now while the trail's attachments spread to the new Width
  const wider = {}

  for i, joint in shown do
    wider[i] = table.clone(joint)
    wider[i].w = joint.w * 2
  end

  riders.draw(r, wider, state, TO_WORLD, middle, MAIN, WIDTH * 2)

  if drawnBeam then
    const a = shown[drawnBeam.from]
    const want0 = 0.8 * a.w / WIDTH * state.width

    check(
      `a beam keeps its width as Width grows {string.format("%.3f", drawnBeam.beam.Width0)}`,
      close(drawnBeam.beam.Width0, want0),
      `want {string.format("%.3f", want0)}`
    )
  end

  const widerGap = (r.head[2].WorldPosition - r.head[1].WorldPosition).Magnitude

  check(
    `the trail's attachments follow Width now {string.format("%.3f", widerGap)}`,
    close(widerGap, WIDTH * 2),
    `want {WIDTH * 2}`
  )

  riders.draw(r, shown, state, TO_WORLD, middle, MAIN, WIDTH)

  -- a bolt whose Width starts at 0 and grows still shows its beams once it has width, since nothing is measured
  -- against the Width it was built at
  const growing = riders.build(sdk, {}, kinds.sort({ beam }), perChain)

  if growing then
    riders.draw(growing, shown, state, TO_WORLD, middle, MAIN, WIDTH)

    local lit = 0

    for _, segment in growing.beams do
      if segment.beam.Enabled and segment.beam.Width0 > 0 then
        lit += 1
      end
    end

    check("a beam built at Width 0 shows once Width grows", lit > 0, `{lit} beams shown`)
    riders.free(growing)
    riders.last(growing)
  else
    check("a beam built at Width 0 shows once Width grows", false, "no riders")
  end

  const shine = r.lights[1].light

  check(
    "the holder sits at the middle joint",
    near(r.holder.WorldPosition, TO_WORLD:PointToWorldSpace(shown[middle].p))
  )
  check(
    `the light's brightness is the artist's times flash {shine.Brightness}`,
    close(shine.Brightness, BRIGHTNESS * state.flash) and shine.Enabled
  )

  -- an opacity change rebuilds the transparency; the artist's comes back at full opacity
  riders.draw(r, shown, { visible = true, width = 0.5, opacity = 1, flash = 0.8 }, TO_WORLD, middle, MAIN, WIDTH)

  if drawnBeam then
    check(
      "at full opacity the beam takes the artist's transparency",
      sequenceNear(drawnBeam.beam.Transparency, beam.Transparency),
      `{drawnBeam.beam.Transparency}`
    )
  end

  -- a blink hides everything that rides
  riders.draw(r, shown, { visible = false, width = 0.5, opacity = 1, flash = 0 }, TO_WORLD, middle, MAIN, WIDTH)

  local lit = 0

  for _, segment in r.beams do
    if segment.beam.Enabled then
      lit += 1
    end
  end

  for _, point in r.points do
    for _, emitter in point.attachment:GetChildren() do
      if emitter.Enabled then
        lit += 1
      end
    end
  end

  if r.trails[1].Enabled or shine.Enabled then
    lit += 1
  end

  check("a hidden bolt leaves every rider off", lit == 0, `{lit} on`)

  -- the cost of a steady frame, every value already written, for the measurement record
  const steady = { visible = true, width = 0.5, opacity = 0.5, flash = 0.8 }

  riders.draw(r, shown, steady, TO_WORLD, middle, MAIN, WIDTH)

  const timed = os.clock()

  for _ = 1, 100 do
    riders.draw(r, shown, steady, TO_WORLD, middle, MAIN, WIDTH)
  end

  table.insert(lines, `riders.draw steady {string.format("%.4f", (os.clock() - timed) * 10)} ms a frame`)

  const moved = os.clock()

  for k = 1, 100 do
    riders.draw(r, shown, steady, TO_WORLD * CFrame.new(0, k * 0.01, 0), middle, MAIN, WIDTH)
  end

  table.insert(lines, `riders.draw moving {string.format("%.4f", (os.clock() - moved) * 10)} ms a frame`)

  const jointAttachment = r.joints[1]
  const holder = r.holder
  const headAttachment = r.head[1]
  const trailMade = r.trails[1]
  const lifetime = riders.free(r)

  check(`free answers the longest Lifetime.Max {lifetime}`, lifetime == 3, "want 3")
  check(
    "free lets the beams, joints, lights and trail go at once",
    drawnBeam ~= nil
      and drawnBeam.beam.Parent == nil
      and jointAttachment.Parent == nil
      and holder.Parent == nil
      and shine.Parent == nil
      and headAttachment.Parent == nil
      and trailMade.Parent == nil
  )

  local waiting = 0

  for _, point in r.points do
    if point.attachment.Parent == terrain then
      for _, emitter in point.attachment:GetChildren() do
        if not emitter.Enabled then
          waiting += 1
        end
      end
    end
  end

  check("free keeps the points with their emitters off", waiting == 2 * POINTS, `{waiting}`)

  const point = r.points[1].attachment

  riders.last(r)
  check("last lets the points go", point.Parent == nil and #terrain:GetChildren() == 0, `{#terrain:GetChildren()} left`)

  -- a folder with nothing to drive answers nil and makes nothing
  const refused = sdk.hold(nil, Instance.new("Folder"))

  Instance.new("Highlight").Parent = refused
  shockwave:Clone().Parent = refused
  Instance.new("Sound").Parent = refused

  const none = riders.build(sdk, {}, kinds.sort(refused:GetChildren()), perChain)

  check("a folder with nothing drivable answers nil", none == nil)
  check("and makes nothing", #terrain:GetChildren() == 0)
end

const ran, problem = pcall(run)

if not ran then
  check("the check ran to its end", false, tostring(problem))
end

-- only what the check made is destroyed, by the references it held
for i = #held, 1, -1 do
  const thing = held[i]

  if typeof(thing) == "Instance" then
    thing:Destroy()
  end
end

const output = table.concat(lines, "\n")

if failed then
  error(`riders check failed\n{output}`, 0)
end

return output
