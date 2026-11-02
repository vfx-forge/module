--!native
--!optimize 2
const attr = require("@mod/attributes")
const clock = require("@mod/clock")
const color = require("@mod/color/color")
const knob = require("@mod/knob")
const curve = require("@mod/curve")
const tween = require("@mod/tween")
const reader = require("@mod/reader")
const utility = require("@mod/utility")
const lifetime = require("@mod/lifetime")
const value_curve = require("@mod/value_curve")
const look_common = require("@mod/common/look")
const material_rows = require("@mod/common/material_rows")
const orient_common = require("@mod/common/orient")
const bezier_common = require("@mod/common/bezier")
const collision_common = require("@mod/common/collision")
const numeric_common = require("@mod/common/numeric")
const particle_motion = require("@mod/particle_motion")

const pool = require("@srv/pool")
const containers = require("@srv/containers")
const mover = require("@srv/mover")
const frame_store = require("@srv/frame_store")
const enabled_effects = require("@srv/enabled_effects")

-- the template's folders of frame sets, which a piece is never handed
const SETS = { Frames = "FrameSet", Textures = "TextureSet" }

const FLIPBOOK_MODES = { "OneShot", "Loop", "PingPong" }

-- how far a piece's look must move from what was last written before a write
-- is worth it: transparency in absolute terms, size relative to itself on any
-- axis, color in 8 bit steps on any channel
const CLEAR_STEP = 0.02
const SIZE_STEP = 0.015
const SIZE_FLOOR = 1e-4
const COLOR_STEP = 2 / 255

const function always()
  return true
end

const function linear()
  return utility.linear_bezier
end

const function disabled(_, attrs: any)
  return not attrs.Enabled
end

const function boxed(_, attrs: any)
  return attrs.Shape == "Box"
end

const function noFrames(_, attrs: any)
  return attrs.FrameSet == ""
end

const function noTextures(_, attrs: any)
  return attrs.TextureSet == ""
end

const function frameOneShot(_, attrs: any)
  return attrs.FlipbookMode == "OneShot"
end

const function textureOneShot(_, attrs: any)
  return attrs.TextureMode == "OneShot"
end

const function textureSynced(_, attrs: any)
  return attrs.TextureSyncDuration == true
end

const function untargeted(_, attrs: any)
  return attrs.GravityTarget == nil
end

-- a mod row reaches a rule as its track
const function dragless(_, attrs: any)
  return attrs.Drag.value <= 0
end

-- whether a Turbulence track wanders at all, its base or a modifier lifting it
const function turbulent(track: any)
  if track.animated then
    return true
  end

  const v = track.at(0)

  return type(v) == "number" and v > 0
end

const function calm(_, attrs: any)
  return not turbulent(attrs.Turbulence)
end

-- a piece locked to its parent never meets the world
const function carried(_, attrs: any)
  return attrs.LockedToPart == true
end

const function noBounce(_, attrs: any)
  return attrs.CollisionMode ~= "Bounce"
end

const function noCollision(_, attrs: any)
  return attrs.CollisionMode == "Off"
end

const function untagged(_, attrs: any)
  return attrs.CollisionMode == "Off" or attrs.CollisionFilter == "None"
end

-- whether a folder of the template is one of its frame sets
const function setFolder(child: Instance)
  const key = SETS[child.Name]

  return key ~= nil and child:IsA("Folder") and child:GetAttribute(key) ~= nil
end

-- the piece's own decals, each its own twin, so nothing blends between two
const function decalsOf(piece: BasePart): look_common.Decals
  const decals = { list = {}, flipbooks = {}, twins = {} }

  for _, child in piece:GetChildren() do
    if not child:IsA("Decal") then
      continue
    end

    const decal = child :: Decal

    table.insert(decals.list, decal)
    decals.twins[decal] = decal

    const data = if attr.get(decal, "FlipbookEnabled", nil, true)
      then attr.get(decal, "FlipbookTextures", nil, true)
      else nil

    if data then
      decals.flipbooks[decal] = utility.deserializeFlipbook(data)
    end
  end

  return decals
end

-- where pieces spawn from: a part's box, an attachment's point, else the
-- template's own pose as a point
const function originOf(template: BasePart): (CFrame, Vector3)
  const parent = template.Parent

  if parent ~= nil and parent:IsA("BasePart") then
    const cframe, size = utility.getTransformedOriginExtents(parent)

    return cframe, size
  end

  if parent ~= nil and parent:IsA("Attachment") then
    return (utility.getTransformedOriginExtents(parent)), Vector3.zero
  end

  return template.CFrame, Vector3.zero
end

-- a row's vector under every host, which lune spells apart from Vector3
const function isVector(v: any)
  const kind = typeof(v)

  return kind == "Vector3" or kind == "vector"
end

-- upper case, the spelling a row's vector and an authored Vector3 both answer
-- to under every host
const function toVector(v: Vector3): vector
  return vector.create(v.X, v.Y, v.Z)
end

-- a drawn number, or `fallback` where a modifier drew none a clock can use
const function numberOr(v: any, fallback: number)
  return if type(v) == "number" and v == v then v else fallback
end

-- a drawn curve, or `fallback` where a modifier drew none of its width
const function curveOr(v: any, fallback: value_curve.Curve): value_curve.Curve
  return if value_curve.is(v) and v.channels == fallback.channels then v else fallback
end

-- a drawn gradient, or `fallback` where a modifier drew none
const function gradientOr(v: any, fallback: ColorSequence): ColorSequence
  return if typeof(v) == "ColorSequence" then v else fallback
end

-- whether a row's track carries a modifier, so each piece reads its own
const function modified(track: reader.Track)
  return track.has("start") or track.has("end")
end

-- whether every keypoint of a gradient holds one color
const function flatColor(sequence: ColorSequence)
  const keypoints = sequence.Keypoints
  const first = keypoints[1].Value

  for _, keypoint in keypoints do
    if keypoint.Value ~= first then
      return false
    end
  end

  return true
end

-- whether every axis of a pose is finite, so no degenerate row reaches the
-- mover
const function finite(cf: CFrame)
  return numeric_common.usable(cf.Position)
    and numeric_common.usable(cf.XVector)
    and numeric_common.usable(cf.YVector)
    and numeric_common.usable(cf.ZVector)
end

-- what one piece draws as it spawns: its launch frame, whose look vector is
-- the way it sets off, its speed and life, its initial turn in degrees, the
-- velocity it inherits, and the curves and gradient it plays over its life
type Launch = {
  spawn: CFrame,
  speed: number,
  duration: number,
  turn: vector,
  inherited: vector,
  size: value_curve.Curve,
  squash: value_curve.Curve,
  clear: value_curve.Curve,
  tint: ColorSequence,
  keypoints: { ColorSequenceKeypoint },
}

-- how pieces meet the world, built once per emit: the rays' filter, and the
-- response each piece copies to give its own bounce and friction
type Collision = {
  params: RaycastParams,
  config: collision_common.Config,
}

-- what every piece of one emit shares, read once as it emits
type Flight = {
  origin: CFrame,
  rotation: CFrame,
  rng: Random,
  collision: Collision?,

  -- where the gravity target stood on frame `read`, shared by every piece of
  -- the emit; nil when it had no place or was gone
  standing: vector?,
  read: number,

  -- the Color row's keypoints, read once for the emit's pieces that take it
  -- as it rests
  keypoints: { ColorSequenceKeypoint },
}

-- where a gravity target stands, or nil for a class that has no place
const function standingOf(target: Instance): vector?
  if target:IsA("BasePart") then
    return toVector(target.Position)
  end

  if target:IsA("Attachment") then
    return toVector(target.WorldPosition)
  end

  if target:IsA("Model") then
    return toVector(target:GetPivot().Position)
  end

  return nil
end

-- a gravity target's up axis, the plane an orbit launch along the radius
-- turns in
const function upOf(target: Instance): vector
  if target:IsA("BasePart") then
    return toVector(target.CFrame.UpVector)
  end

  if target:IsA("Attachment") then
    return toVector(target.WorldCFrame.UpVector)
  end

  if target:IsA("Model") then
    return toVector(target:GetPivot().UpVector)
  end

  return vector.create(0, 1, 0)
end

const forge_mesh = {}

-- the gravity target's place this frame, read from the engine by the first
-- piece to ask and kept for the rest of the emit's pieces
const function standingNow(flight: Flight, target: Instance): vector?
  if flight.read ~= clock.frame then
    flight.read = clock.frame
    flight.standing = if forge_mesh.engine.alive(target) then standingOf(target) else nil
  end

  return flight.standing
end

-- the engine calls, held here so a spec can stand in for them under lune
forge_mesh.engine = {
  alive = function(inst: Instance): boolean
    return inst:IsDescendantOf(game)
  end,
}

forge_mesh.id = "forge_mesh"
forge_mesh.display = { name = "Mesh", icon = "forge_mesh", order = 95 }
forge_mesh.classifier = `BasePart.{utility.FORGE_MESH_TAG}`

-- the template's mesh, frame folders and decals are its own; the effects
-- nested in it run per piece
forge_mesh.components = "Instance"

forge_mesh.attributes = {
  EmitCount = knob(1):min(0):label("Count"):hint("Pieces emitted at once."),
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
  EmitDuration = knob(0)
    :min(0)
    :unit("seconds")
    :label("Duration")
    :hint("Seconds the effect emits at its Rate, 0 emitting Count pieces once."),
  DestroyDelay = knob(0)
    :min(0)
    :unit("seconds")
    :label("DestroyDelay")
    :hint("Extra seconds each piece keeps its look and nested effects after its motion ends."),

  Color = knob(function(ctx: reader.Ctx)
      return ColorSequence.new((ctx.ref :: BasePart).Color)
    end)
    :mod()
    :label("Color")
    :hint("Color of each piece over its life."),
  Orientation = knob("None")
    :options(orient_common.MODES)
    :label("Orientation")
    :hint("How each piece turns as it flies: its own pose, toward the camera or along its velocity."),
  Size = knob(value_curve.flat(1, 3))
    :valueCurve(3)
    :mod()
    :label("Size")
    :hint("Factor on the template's size, or its special mesh's scale, over each piece's life."),
  Squash = knob(value_curve.flat(0, 1))
    :valueCurve(1)
    :mod()
    :label("Squash")
    :hint("Stretch along each piece's up axis over its life, the other axes taking the opposite."),
  Transparency = knob(value_curve.flat(0, 1))
    :valueCurve(1)
    :mod()
    :label("Transparency")
    :hint("Transparency of each piece over its life."),

  EmissionDirection = knob("Top")
    :options({ "Back", "Bottom", "Front", "Left", "Right", "Top" })
    :label("EmissionDirection")
    :hint("Face of the emitter pieces launch from."),
  Enabled = knob(false):label("Enabled"):hint("Whether the effect emits continuously at its Rate."),
  Lifetime = knob(NumberRange.new(1, 1))
    :min(0)
    :unit("seconds")
    :mod()
    :label("Lifetime")
    :hint("Seconds each piece flies, drawn per piece."),
  Rate = knob(5):min(0):unit("perSecond"):hidden(disabled):label("Rate"):hint("Emits per second while Enabled."),
  Rotation = knob(vector.zero)
    :mod()
    :label("Rotation")
    :hint("Initial rotation of each piece per axis, in degrees, drawn per piece."),
  RotSpeed = knob(vector.zero)
    :unit("perSecond")
    :mod()
    :label("RotSpeed")
    :hint("Spin of each piece per axis, in degrees per second, drawn per piece."),
  Speed = knob(NumberRange.new(5, 5))
    :unit("studsPerSecond")
    :mod()
    :label("Speed")
    :hint("Speed each piece launches at along its emission direction, drawn per piece."),
  SpreadAngle = knob(vector.zero)
    :mod()
    :label("SpreadAngle")
    :hint("Random spread of each piece's launch direction, in degrees about X and Y."),

  Shape = knob("Box")
    :options({ "Box", "Cylinder", "Disc", "Sphere" })
    :label("Shape")
    :hint("Volume shape the pieces spawn in."),
  ShapeFace = knob("Outward")
    :options({ "InAndOut", "Inward", "Outward" })
    :label("Face")
    :hint("Whether pieces launch out of the shape, into it or both."),
  ShapePartial = knob(1):min(0):max(1):hidden(boxed):label("Partial"):hint("Fraction of the shape pieces spawn in."),
  ShapeStyle = knob("Volume")
    :options({ "Surface", "Volume" })
    :label("Style")
    :hint("Whether pieces spawn on the shape's surface or in its volume."),

  FlipbookMode = knob("OneShot")
    :options(FLIPBOOK_MODES)
    :label("Mode")
    :hint("Whether the frames play once, loop, or play back and forth."),
  FlipbookStartRandom = knob(false):label("StartRandom"):hint("Start each piece at a random frame."),
  FlipbookReverse = knob(false):label("Reverse"):hint("Play the frames backward."),
  FlipbookChangeCurve = knob(linear):label("Curve"):hint("Easing of the frames' playback."),
  FlipbookChangeDuration = knob(function(ctx)
      return ctx.duration
    end)
    :unit("seconds")
    :label("Duration")
    :hint("Seconds one pass of the frames takes, a PingPong pass running there and back."),
  SyncDuration = knob(true):label("SyncDuration"):hint("Play the frames' cycles over the piece's life."),
  FlipbookLoopCount = knob(0):hidden(frameOneShot):label("LoopCount"):hint(
    "Cycles of the frames to play, 0 repeating for the piece's life, below 0 until Mode leaves Loop or PingPong."
  ),
  FrameTransparency = knob(0)
    :min(0)
    :max(1)
    :mod()
    :label("Transparency")
    :hint("Transparency of the frames' decals over the piece's life."),

  TextureMode = knob("Loop")
    :options(FLIPBOOK_MODES)
    :label("Mode")
    :hint("Whether the material frames play once, loop, or play back and forth."),
  TextureStartRandom = knob(false):label("StartRandom"):hint("Start each piece at a random material frame."),
  TextureReverse = knob(false):label("Reverse"):hint("Play the material frames backward."),
  TextureFps = knob(24)
    :min(1)
    :unit("perSecond")
    :readonly(textureSynced)
    :label("Fps")
    :hint("Material frames worn per second, set by the piece's life while synced."),
  TextureSyncDuration = knob(false)
    :label("SyncDuration")
    :hint("Play the material frames' cycles over the piece's life."),
  TextureLoopCount = knob(0):hidden(textureOneShot):label("LoopCount"):hint(
    "Cycles of the material frames to play, 0 repeating for the piece's life, below 0 until Mode leaves Loop or PingPong."
  ),

  Motion = knob("Particle"):options({ "Particle" }):label("Motion"):hint("How each piece moves after it spawns."),
  Acceleration = knob(vector.zero)
    :unit("studsPerSecondSquared")
    :mod()
    :label("Acceleration")
    :hint("Constant acceleration on each piece, in the parent's frame while LockedToPart."),
  GravityTarget = knob()
    :instance({ "Attachment", "BasePart", "Model" })
    :label("GravityTarget")
    :hint("Attachment, part or model whose gravity pulls each piece."),
  GravityMass = knob(1000):min(0):mod():hidden(untargeted):label("GravityMass"):hint(
    "How hard the target pulls. At distance d the pull is Mass / d squared, in studs per second squared."
  ),
  GravitySoftening = knob(1)
    :min(0)
    :unit("studs")
    :hidden(untargeted)
    :label("GravitySoftening")
    :hint("Smooths the pull close to the target, so a piece passing through it is not flung away."),
  OrbitLaunch = knob(false)
    :hidden(untargeted)
    :label("OrbitLaunch")
    :hint("Launch each piece sideways at the speed of a circular orbit around the target."),

  Turbulence = knob(0)
    :min(0)
    :unit("studs")
    :mod()
    :label("Turbulence")
    :hint("How far each piece wanders off its path, drawn per piece."),
  TurbulenceFrequency = knob(1)
    :min(0)
    :unit("perSecond")
    :hidden(calm)
    :label("TurbulenceFrequency")
    :hint("How fast each piece's wander changes."),

  Drag = knob(0):min(0):mod():label("Drag"):hint("Rate each piece loses speed, halving it every 1/Drag seconds."),
  LockedToPart = knob(false):label("LockedToPart"):hint("Whether pieces move with the parent after they spawn."),
  TimeScale = knob(1):min(0):mod():label("TimeScale"):hint("Multiplier on the effect's clock, 0 freezing it."),
  VelocityInheritance = knob(0)
    :mod()
    :label("VelocityInheritance")
    :hint("Share of the parent part's velocity each piece launches with."),
  WindAffectsDrag = knob(false)
    :hidden(dragless)
    :label("WindAffectsDrag")
    :hint("Whether drag eases each piece toward the global wind rather than to rest."),

  CollisionMode = knob("Off")
    :options({ "Off", "Kill", "Stop", "Bounce" })
    :label("CollisionMode")
    :hint("What a piece does when its path hits something."),
  Bounce = knob(0.5)
    :min(0)
    :max(1)
    :mod()
    :hidden(noBounce)
    :label("Bounce")
    :hint("Share of the speed into the surface a bounce keeps."),
  Friction = knob(0.2)
    :min(0)
    :max(1)
    :mod()
    :hidden(noBounce)
    :label("Friction")
    :hint("Share of the speed along the surface a bounce loses."),
  CollisionFilter = knob("None")
    :options({ "None", "Exclude Tag", "Include Tag" })
    :hidden(noCollision)
    :label("CollisionFilter")
    :hint("Whether tagged parts are left out of the hits or are the only ones hit."),
  CollisionFilterTag = knob(""):hidden(untagged):label("FilterTag"):hint("CollectionService tag the filter reads."),
  CollisionGroup = knob("Default")
    :hidden(noCollision)
    :label("CollisionGroup")
    :hint("Collision group the hits are cast in."),
  CollisionRespectCanCollide = knob(true)
    :hidden(noCollision)
    :label("RespectCanCollide")
    :hint("Whether parts with CanCollide off are passed through."),

  -- the keys of the Frames and Textures folders the template plays, which the
  -- plugin writes
  FrameSet = knob(""):hidden(always),
  TextureSet = knob(""):hidden(always),
}

forge_mesh.properties = {}

forge_mesh.layout = {
  { title = "Emit", entries = { "EmitCount", "EmitDelay", "EmitDuration", "DestroyDelay" } },
  { title = "Appearance", entries = { "Color", "Orientation", "Size", "Squash", "Transparency" } },
  {
    title = "Emission",
    entries = {
      "EmissionDirection",
      "Enabled",
      "Lifetime",
      "Rate",
      "Rotation",
      "RotSpeed",
      "Speed",
      "SpreadAngle",
    },
  },
  { title = "EmitterShape", entries = { "Shape", "ShapeFace", "ShapePartial", "ShapeStyle" } },
  {
    title = "Flipbook",
    entries = {
      {
        title = "Mesh Frames",
        entries = {
          "FlipbookMode",
          "FlipbookStartRandom",
          "FlipbookReverse",
          { curve = "FlipbookChangeCurve", duration = "FlipbookChangeDuration" },
          "SyncDuration",
          "FlipbookLoopCount",
          "FrameTransparency",
        },
        hidden = noFrames,
      },
      {
        title = "Material Frames",
        entries = {
          "TextureMode",
          "TextureStartRandom",
          "TextureReverse",
          "TextureFps",
          "TextureSyncDuration",
          "TextureLoopCount",
        },
        hidden = noTextures,
      },
    },
  },
  {
    title = "Motion",
    entries = {
      "Motion",
      "Acceleration",
      "GravityTarget",
      "GravityMass",
      "GravitySoftening",
      "OrbitLaunch",
      "Turbulence",
      "TurbulenceFrequency",
    },
  },
  {
    title = "Particles",
    entries = { "Drag", "LockedToPart", "TimeScale", "VelocityInheritance", "WindAffectsDrag" },
  },
  {
    title = "Collision",
    entries = {
      "CollisionMode",
      "Bounce",
      "Friction",
      "CollisionFilter",
      "CollisionFilterTag",
      "CollisionGroup",
      "CollisionRespectCanCollide",
    },
    hidden = carried,
  },
  {
    title = "Behavior",
    entries = {
      { action = "toggle_paths", label = "Show Paths" },
      { action = "toggle_textures", label = "Load Textures" },
    },
  },
}

function forge_mesh.duration(_, attrs: any)
  return attrs.Lifetime.value.Max
end

forge_mesh.constant = true

-- every piece alive across all emitters and emits, and the most that may be;
-- a spec lowers max, nothing else writes either
forge_mesh.pieces = { live = 0, max = 500 }

-- one piece: a bare copy of the template flown from its launch for its life,
-- wearing the look, its nested effects run on it
const function piece(
  ctx: reader.Ctx,
  attrs: any,
  looks: any,
  template: BasePart,
  launch: Launch,
  flight: Flight,
  sets: look_common.Sets
)
  const scope = ctx.scope
  const duration = launch.duration
  const census = forge_mesh.pieces

  -- a full house drops the piece before it takes anything
  if census.live >= census.max then
    return
  end

  census.live += 1

  -- given back once, by whichever comes first: the piece's own end or the
  -- effect letting go (a clear, a cancel, a thrown step)
  local counted = true

  const function uncount()
    if counted then
      counted = false
      census.live -= 1
    end
  end

  lifetime.hold(scope, uncount)

  const obj = pool.take(scope, template, false, true) :: BasePart

  -- a frame set is lent from the store, never worn as a copy of its folder
  for _, child in obj:GetChildren() do
    if setFolder(child) then
      child:Destroy()
    end
  end

  const objMesh = obj:FindFirstChildOfClass("SpecialMesh")
  const templateMesh = template:FindFirstChildOfClass("SpecialMesh")

  -- read before a frame's decal joins the piece, where it would pass for one
  -- of the piece's own
  const decals = decalsOf(obj)

  const look = look_common.start(scope, obj, template, looks, duration, sets, {
    owner = template,
    decals = decals,
    modes = true,
    rng = flight.rng,
    ownDefault = true,
  })

  -- one draw per curve for the piece's whole life, read through samplers built
  -- once, so a frame allocates nothing for them; a flat one is written once
  const sizeAt, sizeFlat = value_curve.sampler(launch.size, value_curve.draw(launch.size, flight.rng))
  const squashAt, squashFlat = value_curve.sampler(launch.squash, value_curve.draw(launch.squash, flight.rng))
  const clearAt, clearFlat = value_curve.sampler(launch.clear, value_curve.draw(launch.clear, flight.rng))

  const keypoints = launch.keypoints
  const tinted = not flatColor(launch.tint)
  const shaped = not (sizeFlat and squashFlat)
  const mode = attrs.Orientation :: orient_common.Mode
  const watching = mode == "FacingCamera" or mode == "FacingCameraWorldUp"

  -- a template's special mesh carries the size when the piece has one too
  const meshed = objMesh ~= nil and templateMesh ~= nil
  const rest = if meshed then (templateMesh :: SpecialMesh).Scale else template.Size

  -- the last size, transparency and color written; a value is written only
  -- once it is far enough from these, and always on the first frame, at an
  -- end of the curve and as the piece ends
  local writtenSize = rest
  local writtenClear = 0
  local writtenColor = obj.Color

  -- the share of a step each channel's first write after the spawn waits
  -- for, drawn per piece, so the pieces of one emit playing one curve cross
  -- their steps on different frames; every later write waits a whole step
  const stagger = if shaped or tinted or not clearFlat then flight.rng:NextNumber() else 1

  local sizeShare = stagger
  local clearShare = stagger
  local colorShare = stagger

  -- the piece's size, color and transparency at `t` of its life, each checked
  -- every frame only while it changes over the life
  const function appear(t: number, first: boolean, over: boolean)
    const exact = first or over or t <= 0 or t >= 1

    if first or shaped then
      const size = sizeAt(t)
      const x, y, z = size[1], size[2], size[3]
      const stretched = orient_common.squash(Vector3.new(rest.X * x, rest.Y * y, rest.Z * z), squashAt(t)[1])
      const sx, sy, sz = stretched.X, stretched.Y, stretched.Z

      const step = SIZE_STEP * sizeShare
      const moved = math.abs(sx - writtenSize.X) > step * math.max(math.abs(writtenSize.X), SIZE_FLOOR)
        or math.abs(sy - writtenSize.Y) > step * math.max(math.abs(writtenSize.Y), SIZE_FLOOR)
        or math.abs(sz - writtenSize.Z) > step * math.max(math.abs(writtenSize.Z), SIZE_FLOOR)

      if first or moved or (exact and stretched ~= writtenSize) then
        writtenSize = stretched
        sizeShare = if first then sizeShare else 1

        if meshed then
          (objMesh :: SpecialMesh).Scale = stretched
          look.refit()
        else
          look.size(stretched)
        end
      end
    end

    if first or not clearFlat then
      const clear = clearAt(t)[1]

      if first or math.abs(clear - writtenClear) > CLEAR_STEP * clearShare or (exact and clear ~= writtenClear) then
        writtenClear = clear
        clearShare = if first then clearShare else 1
        obj.Transparency = clear
      end
    end

    if first or tinted then
      const tone = color.keypointsAt(keypoints, t)

      const step = COLOR_STEP * colorShare
      const moved = math.abs(tone.R - writtenColor.R) > step
        or math.abs(tone.G - writtenColor.G) > step
        or math.abs(tone.B - writtenColor.B) > step

      if first or moved or (exact and tone ~= writtenColor) then
        writtenColor = tone
        colorShare = if first then colorShare else 1
        obj.Color = tone
      end
    end
  end

  appear(0, true, false)

  const locked = attrs.LockedToPart
  const windy = attrs.WindAffectsDrag
  const origin = flight.origin
  const facing = flight.rotation
  const turn = launch.turn
  const at = launch.spawn.Position

  local position = toVector(at)
  local velocity = toVector(launch.spawn.LookVector) * launch.speed + launch.inherited
  local acceleration = vector.zero
  local drag = 0
  local mass = 0
  local amount = 0
  local wander = vector.zero
  local spin = vector.zero

  -- a piece the world stopped keeps its look but no longer moves
  local pinned = false

  const target = attrs.GravityTarget :: Instance?
  const softening = attrs.GravitySoftening :: number
  const collision = if flight.collision ~= nil and not locked then flight.collision else nil
  const response = if collision ~= nil then table.clone(collision.config) else nil

  -- the initial turn, each step's spin added onto it
  local rotation =
    CFrame.fromOrientation(turn.x * utility.DEG_TO_RAD, turn.y * utility.DEG_TO_RAD, turn.z * utility.DEG_TO_RAD)

  -- a piece locked to its parent accelerates in the parent's frame
  tween.drive(scope, attrs.Acceleration(nil, duration), function(v: any)
    if isVector(v) then
      acceleration = toVector(if locked then origin:VectorToWorldSpace(Vector3.new(v.X, v.Y, v.Z)) else v)
    end
  end)

  tween.drive(scope, attrs.Drag(nil, duration), function(v: number)
    drag = v
  end)

  if target ~= nil then
    tween.drive(scope, attrs.GravityMass(nil, duration), function(v: any)
      mass = numberOr(v, 0)
    end)
  end

  const wobbles = turbulent(attrs.Turbulence)
  const seed = if wobbles then flight.rng:NextNumber(0, 1000) else 0
  const frequency = attrs.TurbulenceFrequency
  const calm = if wobbles then particle_motion.rest(seed) else vector.zero

  if wobbles then
    tween.drive(scope, attrs.Turbulence(nil, duration), function(v: any)
      amount = numberOr(v, 0)
    end)
  end

  if response ~= nil then
    tween.drive(scope, attrs.Bounce(nil, duration), function(v: any)
      response.bounce = numberOr(v, 0)
    end)

    tween.drive(scope, attrs.Friction(nil, duration), function(v: any)
      response.friction = numberOr(v, 0)
    end)
  end

  tween.drive(scope, attrs.RotSpeed(nil, duration), function(v: any)
    if isVector(v) then
      spin = toVector(v) * utility.DEG_TO_RAD
    end
  end)

  -- the parent the piece spawned under, whose last pose is held once the
  -- template leaves it, so a destroyed parent never snaps a locked piece
  const anchor = template.Parent
  local held = origin

  const function live()
    if template.Parent == anchor then
      held = (originOf(template))
    end

    return held
  end

  -- a piece locked to its parent rides the parent from where it spawned
  const function placed(cf: CFrame)
    return if locked then live() * origin:ToObjectSpace(cf) else cf
  end

  -- a world point in the frame a locked piece flies in, carried back by the
  -- parent's move since the spawn
  const function unplaced(at: vector): vector
    if not locked then
      return at
    end

    return toVector(origin:PointToWorldSpace(live():PointToObjectSpace(Vector3.new(at.x, at.y, at.z))))
  end

  -- an orbit launch trades the launch's speed for the circular orbit's about
  -- where the target stands, in the frame the piece flies in
  if target ~= nil and attrs.OrbitLaunch and mass ~= 0 then
    const standing = standingNow(flight, target)

    if standing ~= nil then
      const up = upOf(target)
      const axis = if locked
        then toVector(origin:VectorToWorldSpace(live():VectorToObjectSpace(Vector3.new(up.x, up.y, up.z))))
        else up
      const look = toVector(launch.spawn.LookVector)

      velocity = particle_motion.orbit(position, unplaced(standing), look, axis, mass, softening) + launch.inherited
    end
  end

  -- the turn the velocity last gave, held once the piece stops
  local heading: CFrame? = nil

  const function pose()
    const camera = if watching then workspace.CurrentCamera else nil
    const turned =
      orient_common.rotation(mode, facing, position, velocity, if camera then camera.CFrame else nil, heading)

    heading = turned

    const drawn = position + wander
    const cf = CFrame.new(drawn.x, drawn.y, drawn.z) * turned * rotation

    return placed(cf) * look.offset()
  end

  -- the first pose is written at once, so a reused piece never shows a frame
  -- where its last holder let it go
  const first = pose()

  if finite(first) then
    obj.CFrame = first
  end

  const children = lifetime.join(scope)
  const emitOnFinish = scope.effects.prepareEmitOnFinish(obj, scope)

  scope.effects.emitNested(obj, scope.depth + 1, scope, children)

  look.play()

  const ended = lifetime.join(scope)
  const finish = lifetime.add(ended)

  local age = 0
  local moving = true

  const function place()
    const cf = pose()

    if finite(cf) then
      mover.move(scope, obj, cf)
    end
  end

  const function advance(deltaTime: number)
    -- a piece at rest moves only with its parent or its frames
    if not moving then
      if locked or sets.frames then
        place()
      end

      return
    end

    -- a clock halted for good never reaches the end of the motion
    if scope.clock.halted then
      moving = false
      finish()
      return
    end

    -- the last step lands on the end of the piece's life exactly
    const dt = math.min(deltaTime, duration - age)

    age += dt

    if dt > 0 and not pinned then
      const wind = if windy then toVector(workspace.GlobalWind) else vector.zero

      -- the gravity target is read once a frame, a gone one adding none
      const standing = if target ~= nil and mass ~= 0 then standingNow(flight, target) else nil

      const pulled = if standing ~= nil then unplaced(standing) else nil

      const steps = if collision ~= nil or drag > 0 or pulled ~= nil then particle_motion.substeps(dt) else 1
      const h = dt / steps

      for step = 1, steps do
        local nextPosition, nextVelocity

        -- a piece under gravity steps with velocity Verlet, so an orbit
        -- neither spirals out nor in
        if pulled ~= nil then
          nextPosition, nextVelocity =
            particle_motion.verlet(position, velocity, acceleration, pulled, mass, softening, drag, wind, h)
        else
          nextPosition, nextVelocity = particle_motion.step(position, velocity, acceleration, drag, wind, h)
        end

        if not (numeric_common.usable(nextPosition) and numeric_common.usable(nextVelocity)) then
          break
        end

        -- the ray runs along what is drawn: the flown position plus the wander
        const nextWander = if amount > 0
          then particle_motion.wander(seed, age - dt + h * step, frequency, amount, calm)
          else vector.zero

        const hit = if collision ~= nil
          then collision_common.cast(collision.params, position + wander, nextPosition + nextWander)
          else nil

        wander = nextWander

        if hit == nil then
          position, velocity = nextPosition, nextVelocity
          continue
        end

        const outcome, landed, rebound = collision_common.respond(
          response :: collision_common.Config,
          nextVelocity,
          { position = toVector(hit.Position), normal = toVector(hit.Normal) }
        )

        position, velocity = landed - wander, rebound

        if outcome == "kill" then
          moving = false
          break
        end

        if outcome == "stop" then
          pinned = true
          break
        end
      end

      const add = spin * dt

      if not pinned and moving and numeric_common.usable(add) then
        rotation *= CFrame.fromOrientation(add.x, add.y, add.z)
      end
    end

    const over = not moving or age >= duration

    appear(if duration > 0 then age / duration else 1, false, over)
    place()

    if over then
      moving = false
      finish()
    end
  end

  const stepping = lifetime.step(scope, advance, "follow")
  lifetime.awaitJoin(ended)

  scope.effects.emitOnFinish(emitOnFinish, obj, scope.depth + 1, scope, children)

  -- the look may run past the motion, as frames played longer than the piece
  -- do
  const tail = look.life - duration

  if tail > 0 then
    tween.wait(scope, curve.new(tail, "linear"))
  end

  look.linger()
  lifetime.awaitJoin(children)

  -- a piece that ends ahead of its emit leaves the world at once, out of
  -- reach of the writes still running on the effect, its last move with it;
  -- the pool takes it back when the effect lets go
  stepping:Disconnect()
  mover.cancel(obj)
  obj.Parent = nil
  uncount()
end

function forge_mesh.emit(ctx: reader.Ctx, attrs: any)
  const template = ctx.ref :: BasePart
  const scope = ctx.scope

  -- a deferred signal has not yet told the pool of a write made just before a
  -- plain emit, so its pieces come from a copy taken now; a tick's keep the one
  -- its loop has
  if not ctx.constant then
    pool.refresh(template)
  end

  -- a plain emit of an enabled template switches it off; the tick's own emits
  -- leave it as it is
  if attrs.Enabled and not ctx.constant then
    enabled_effects.switch(template, false)
  end

  lifetime.wait(scope, attrs.EmitDelay)

  if attrs.EmitDuration > 0 and not ctx.constant then
    enabled_effects.window(ctx, forge_mesh, attrs.EmitDuration, attrs.TimeScale)
    return
  end

  if attrs.EmitCount <= 0 or bezier_common.SHAPES[attrs.Shape] == nil then
    return
  end

  -- every piece runs on the effect's clock, so one TimeScale track paces them
  -- all
  utility.speedFrom(scope, ctx.constant, attrs.TimeScale)

  const sets: look_common.Sets = {
    frames = if attrs.FrameSet ~= "" then frame_store.find(template, attrs.FrameSet) else nil,
    textures = if attrs.TextureSet ~= "" then frame_store.findTextures(template, attrs.TextureSet) else nil,
  }

  if sets.frames then
    frame_store.warm(sets.frames)
  end

  if sets.textures then
    frame_store.warm(sets.textures)
  end

  -- the look reads the material's glow rows beside the effect's own
  const looks = table.clone(attrs)

  for name, track in material_rows.resolve(ctx, template) do
    looks[name] = track
  end

  const origin, size = originOf(template)
  const parent = template.Parent

  -- an attachment or no parent at all has no velocity to hand on
  const moved = parent ~= nil and parent:IsA("BasePart")

  const config: particle_motion.Config = {
    shape = attrs.Shape,
    surface = attrs.ShapeStyle == "Surface",
    partial = attrs.ShapePartial,
    normal = Enum.NormalId[attrs.EmissionDirection],
    face = attrs.ShapeFace,
    spread = vector.zero,
  }

  const flight: Flight = {
    origin = origin,
    rotation = template.CFrame.Rotation,
    rng = Random.new(),
    collision = nil,
    standing = nil,
    read = -1,
    keypoints = (attrs.Color.value :: ColorSequence).Keypoints,
  }

  if attrs.CollisionMode ~= "Off" then
    const exclude = { containers.root(), template }

    -- the workspace and its terrain are the world the rays are for
    if parent ~= nil and parent ~= workspace and parent ~= workspace.Terrain then
      table.insert(exclude, parent)
    end

    const filterType, filterTag = collision_common.filter(attrs.CollisionFilter, attrs.CollisionFilterTag)

    const collision: collision_common.Config = {
      mode = attrs.CollisionMode,
      bounce = 0,
      friction = 0,
      filterType = filterType,
      filterTag = filterTag,
      group = attrs.CollisionGroup,
      respectCanCollide = attrs.CollisionRespectCanCollide,
    }

    flight.collision = { params = collision_common.params(collision, exclude), config = collision }
  end

  -- each piece runs on a thread the effect holds, so a clear closes it
  const outstanding = lifetime.join(scope)

  -- every piece of an emit spawns at one time on the effect's clock: 0, or for
  -- a tick of an EmitDuration window how far into the window it fired. so
  -- these tracks differ between the pieces of one emit only by what their
  -- modifiers draw, and between ticks by where the window had got to
  const spawned = scope.windowAt or 0

  -- an appearance row with no modifier hands every piece the value it rests
  -- at, read here once rather than per piece
  const sizeRest = attrs.Size.value :: value_curve.Curve
  const squashRest = attrs.Squash.value :: value_curve.Curve
  const clearRest = attrs.Transparency.value :: value_curve.Curve
  const tintRest = attrs.Color.value :: ColorSequence

  const sized = modified(attrs.Size)
  const squashed = modified(attrs.Squash)
  const cleared = modified(attrs.Transparency)
  const colored = modified(attrs.Color)

  for _ = 1, attrs.EmitCount do
    const speed = numberOr(attrs.Speed().at(spawned), attrs.Speed.value.Min)
    const duration = math.max(numberOr(attrs.Lifetime().at(spawned), attrs.Lifetime.value.Min), 0)
    const spread = attrs.SpreadAngle().at(spawned)
    const turn = attrs.Rotation().at(spawned)
    const inheritance = numberOr(attrs.VelocityInheritance().at(spawned), 0)
    const tint = if colored then gradientOr(attrs.Color().at(spawned), tintRest) else tintRest

    config.spread = if isVector(spread) then vector.create(spread.X, spread.Y, 0) else vector.zero

    const launch: Launch = {
      spawn = particle_motion.spawn(origin, size, config, flight.rng),
      speed = speed,
      duration = duration,
      turn = if isVector(turn) then toVector(turn) else vector.zero,
      inherited = if inheritance ~= 0 and moved
        then toVector((parent :: BasePart).AssemblyLinearVelocity) * inheritance
        else vector.zero,
      size = if sized then curveOr(attrs.Size().at(spawned), sizeRest) else sizeRest,
      squash = if squashed then curveOr(attrs.Squash().at(spawned), squashRest) else squashRest,
      clear = if cleared then curveOr(attrs.Transparency().at(spawned), clearRest) else clearRest,
      tint = tint,
      keypoints = if colored then tint.Keypoints else flight.keypoints,
    }

    lifetime.spawn(outstanding, piece, ctx, attrs, looks, template, launch, flight, sets)
  end

  lifetime.awaitJoin(outstanding)
end

return forge_mesh
