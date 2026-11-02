const attr = require("@mod/attributes")
const knob = require("@mod/knob")
const tween = require("@mod/tween")
const reader = require("@mod/reader")
const utility = require("@mod/utility")
const lifetime = require("@mod/lifetime")
const look_common = require("@mod/common/look")
const bezier_common = require("@mod/common/bezier")
const flight_common = require("@mod/common/flight")
const numeric_common = require("@mod/common/numeric")
const particle_motion = require("@mod/particle_motion")

const pool = require("@srv/pool")
const mover = require("@srv/mover")
const frame_store = require("@srv/frame_store")
const enabled_effects = require("@srv/enabled_effects")

const WHITE = Color3.new(1, 1, 1)
const UP = Vector3.new(0, 1, 0)
const SIDE = Vector3.new(1, 0, 0)

-- below this a piece is taken to stand still, so it keeps the way it faces
const STILL_SPEED = 1e-6

-- the template's folders of frame sets, which a piece is never handed
const SETS = { Frames = "FrameSet", Textures = "TextureSet" }

const function always()
  return true
end

const function linear()
  return utility.linear_bezier
end

const function noFrames(_, attrs: any)
  return attrs.FrameSet == ""
end

const function noTextures(_, attrs: any)
  return attrs.TextureSet == ""
end

const function noFrameLoop(_, attrs: any)
  return attrs.FrameSet == "" or not attrs.FlipbookLoop
end

const function noTextureLoop(_, attrs: any)
  return attrs.TextureSet == "" or not attrs.TextureLoop
end

const function textureSynced(_, attrs: any)
  return attrs.TextureSyncDuration == true
end

const function noSpecialMesh(ctx: reader.Ctx)
  return ctx.ref:FindFirstChildOfClass("SpecialMesh") == nil
end

-- whether a folder of the template is one of its frame sets
const function setFolder(child: Instance)
  const key = SETS[child.Name]

  return key ~= nil and child:IsA("Folder") and child:GetAttribute(key) ~= nil
end

-- whether any frame of the template's frame set wears a look; a shape-only
-- set's frames wear none, so the glow has nothing to reach
const function framesDressed(template: Instance, key: string): boolean
  for _, folder in template:GetChildren() do
    if folder.Name ~= "Frames" or not setFolder(folder) or folder:GetAttribute("FrameSet") ~= key then
      continue
    end

    for _, part in folder:GetChildren() do
      if part:FindFirstChildOfClass("SurfaceAppearance") or part:FindFirstChildOfClass("Decal") then
        return true
      end
    end
  end

  return false
end

-- the surface glow reaches only a surface appearance, one the template wears
-- or one a texture or dressed frame set brings
const function unlit(ctx: reader.Ctx, attrs: any)
  if ctx.ref:FindFirstChildOfClass("SurfaceAppearance") ~= nil or attrs.TextureSet ~= "" then
    return false
  end

  return attrs.FrameSet == "" or not framesDressed(ctx.ref, attrs.FrameSet)
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

const function scaled(size: Vector3, factor: Vector3)
  return Vector3.new(size.X * factor.X, size.Y * factor.Y, size.Z * factor.Z)
end

-- upper case, the spelling an authored Vector3 answers to under every host
const function toVector(v: Vector3): vector
  return vector.create(v.X, v.Y, v.Z)
end

const function toVector3(v: vector)
  return Vector3.new(v.x, v.y, v.z)
end

-- whether every axis of a pose is finite, so no degenerate row reaches the
-- mover
const function finite(cf: CFrame)
  return numeric_common.usable(cf.Position)
    and numeric_common.usable(cf.XVector)
    and numeric_common.usable(cf.YVector)
    and numeric_common.usable(cf.ZVector)
end

-- a turn facing along `velocity`, or `fallback` while the piece stands still
const function along(velocity: vector, fallback: CFrame)
  const speed = vector.magnitude(velocity)

  if speed < STILL_SPEED or speed ~= speed then
    return fallback
  end

  -- straight up or down has no up of its own to turn about
  const up = if math.abs(velocity.y / speed) > 0.999 then SIDE else UP

  return CFrame.lookAt(Vector3.zero, toVector3(velocity), up)
end

-- what one piece draws as it spawns: its launch frame, whose look vector is
-- the way it sets off, its speed and life, its initial turn in degrees and
-- its projectile's lifetime
type Launch = {
  spawn: CFrame,
  speed: number,
  duration: number,
  turn: vector,
  flight: number,
}

-- what every piece of one emit flies by, read once as it emits
type Flight = {
  origin: CFrame,
  rotation: CFrame,
  acceleration: vector,
  inherited: vector,
  hitbox: OverlapParams?,
}

const function flightOf(template: BasePart, attrs: any, origin: CFrame): Flight
  const parent = template.Parent
  const authored = attrs.Acceleration
  const inheritance = attrs.VelocityInheritance

  -- a piece locked to its parent accelerates in the parent's frame
  const acceleration = if attrs.SyncPosition
    then origin:VectorToWorldSpace(Vector3.new(authored.X, authored.Y, authored.Z))
    else authored

  -- an attachment or no parent at all has no velocity to hand on
  const inherited = if inheritance ~= 0
      and parent ~= nil
      and parent:IsA("BasePart")
    then toVector(parent.AssemblyLinearVelocity) * inheritance
    else vector.zero

  -- an attachment's part is left out of the hits as a part parent is
  const root = if parent ~= nil and parent:IsA("Attachment") then parent else nil
  const hitbox = if attrs.HitboxEnabled and parent ~= nil
    then bezier_common.createHitboxParams(bezier_common.hitboxOf(attrs), parent, root)
    else nil

  return {
    origin = origin,
    rotation = template.CFrame.Rotation,
    acceleration = toVector(acceleration),
    inherited = inherited,
    hitbox = hitbox,
  }
end

const forge_mesh = {}

forge_mesh.id = "forge_mesh"
forge_mesh.display = { name = "Mesh", icon = "forge_mesh", order = 95 }
forge_mesh.classifier = `BasePart.{utility.FORGE_MESH_TAG}`

-- the template's mesh, frame folders and decals are its own; the effects
-- nested in it run per piece
forge_mesh.components = "Instance"

const attributes = bezier_common.rows({
  Motion = knob("Particle"):options({ "Particle" }):label("Motion"):hint("How each piece moves after it spawns."),
  Velocity = knob(NumberRange.new(5, 5))
    :unit("studsPerSecond")
    :label("Velocity")
    :hint("Speed range each piece launches at along its emission direction."),
  Acceleration = knob(vector.zero)
    :unit("studsPerSecondSquared")
    :label("Acceleration")
    :hint("Constant acceleration on each piece, in the parent's frame while LockedToPart."),
  Drag = knob(0):min(0):label("Drag"):hint("Rate each piece loses speed, halving it every 1/Drag seconds."),
  VelocityInheritance = knob(0)
    :label("VelocityInheritance")
    :hint("Share of the parent part's velocity each piece launches with."),
  TimeScale = knob(1)
    :min(0)
    :max(1)
    :label("TimeScale")
    :hint("Speed of each piece's motion and spin, 0 freezing them where they spawn."),
  WindAffectsDrag = knob(false)
    :label("WindAffectsDrag")
    :hint("Whether drag eases each piece toward the global wind rather than to rest."),
  FaceVelocity = knob(false):label("FaceVelocity"):hint("Whether each piece turns to face its direction of travel."),
  MinInitRot = knob(vector.zero)
    :label("Min")
    :hint("Lower per-axis bound for each piece's initial rotation, in degrees."),
  MaxInitRot = knob(vector.zero)
    :label("Max")
    :hint("Upper per-axis bound for each piece's initial rotation, in degrees."),
  RotSpeed = knob(0)
    :unit("perSecond")
    :mod()
    :label("Speed")
    :hint("Rotation speed drawn for each piece, in degrees per second."),
  Scale = knob(vector.one):mod():label("Scale"):hint("Multiplier on the template's size over the piece's duration."),
  MeshScale = knob(vector.one)
    :mod()
    :hidden(noSpecialMesh)
    :label("MeshScale")
    :hint("Multiplier on the template's special mesh scale over the piece's duration."),
  PartTransparency = knob(0):mod():label("Transparency"):hint("Part transparency over the piece's duration."),
  -- the key of the Frames folder the template plays, which the plugin writes
  FrameSet = knob(""):hidden(always),
  FlipbookChangeDuration = knob(function(ctx)
      return ctx.duration
    end)
    :unit("seconds")
    :hidden(noFrames)
    :label("Duration")
    :hint("Seconds the frames play over."),
  FlipbookChangeCurve = knob(linear):hidden(noFrames):label("Curve"):hint("Easing of the frames' playback."),
  SyncDuration = knob(false)
    :hidden(noFrames)
    :label("SyncDuration")
    :hint("Play the frames' cycles over the piece's duration."),
  FlipbookLoop = knob(false):hidden(noFrames):label("Loop"):hint("Repeat the frames' cycle."),
  FlipbookLoopCount = knob(0):hidden(noFrameLoop):label("LoopCount"):hint(
    "Cycles of the frames to play, 0 repeating for the piece's duration, below 0 until Loop is switched off."
  ),
  FrameTransparency = knob(0)
    :min(0)
    :max(1)
    :mod()
    :hidden(noFrames)
    :label("Transparency")
    :hint("Transparency of the frames' decals over the piece's duration."),
  -- the key of the Textures folder the piece wears, which the plugin writes
  TextureSet = knob(""):hidden(always),
  TextureFps = knob(24)
    :min(1)
    :unit("perSecond")
    :hidden(noTextures)
    :readonly(textureSynced)
    :label("Fps")
    :hint("Material frames worn per second, set by the piece's duration while synced."),
  TextureSyncDuration = knob(false)
    :hidden(noTextures)
    :label("SyncDuration")
    :hint("Play the material frames' cycles over the piece's duration."),
  TextureLoop = knob(true):hidden(noTextures):label("Loop"):hint("Repeat the material frames' cycle."),
  TextureLoopCount = knob(0):hidden(noTextureLoop):label("LoopCount"):hint(
    "Cycles of the material frames to play, 0 repeating for the piece's duration, below 0 until Loop is switched off."
  ),
  EmissiveStrength = knob(1):min(0):mod():label("Strength"):hint("Multiplier on the glow of the mesh's material."),
  SurfaceColor = knob(WHITE)
    :mod()
    :label("Color")
    :hint("Color the mesh's material is multiplied by, its glow included."),
  EmissiveTint = knob(WHITE):mod():label("Tint"):hint("Color the glow of the mesh's material is multiplied by."),
})

-- the rows that aim at an end target, which this effect does not have yet
for _, name in { "MirrorPaths", "MirrorRotation", "MatchEndDirection" } do
  attributes[name]:hidden(always)
end

attributes.SyncPosition:label("LockedToPart"):hint("Whether pieces move with the parent after they spawn.")

forge_mesh.attributes = attributes

forge_mesh.properties = {}

forge_mesh.layout = {
  { title = "Emit", entries = { "EmitCount", "EmitDelay", "EmitDuration", "DestroyDelay" } },
  { title = "Effect", entries = { "Duration", "SpreadAngle", "Enabled", "Rate", "SyncPosition", "Speed" } },
  { title = "Shape", entries = { "EmissionDirection", "Shape", "ShapePartial", "ShapeStyle", "ShapeFace" } },
  {
    title = "Motion",
    entries = {
      "Motion",
      "Velocity",
      "Acceleration",
      "Drag",
      "VelocityInheritance",
      "TimeScale",
      "WindAffectsDrag",
      "FaceVelocity",
    },
  },
  {
    title = "Rotation",
    entries = { { title = "Speed", entries = { "RotSpeed" } }, "MinInitRot", "MaxInitRot" },
  },
  { title = "Part", entries = { "PartTransparency", "Scale", "MeshScale" } },
  {
    title = "Frames",
    entries = {
      { curve = "FlipbookChangeCurve", duration = "FlipbookChangeDuration" },
      "SyncDuration",
      "FlipbookLoop",
      "FlipbookLoopCount",
      "FrameTransparency",
    },
  },
  {
    title = "Material Frames",
    entries = { "TextureFps", "TextureSyncDuration", "TextureLoop", "TextureLoopCount" },
  },
  { title = "Glow", entries = { "SurfaceColor", "EmissiveStrength", "EmissiveTint" }, hidden = unlit },
  { title = "Projectile Motion", entries = { "ProjectileEnabled", "ProjectileLifetime", "ProjectileSpeed" } },
  {
    title = "Hitbox",
    entries = {
      "HitboxEnabled",
      "HitboxCollisionGroup",
      { title = "Filter", entries = { "HitboxFilterTag", "HitboxFilterType", "HitboxIgnoreCanCollide" } },
    },
  },
}

function forge_mesh.duration(_, attrs: any)
  return attrs.Duration.Max
end

forge_mesh.constant = true

-- one piece: a bare copy of the template flown from its launch for its life,
-- wearing the look, its nested effects run on it
const function piece(
  ctx: reader.Ctx,
  attrs: any,
  template: BasePart,
  launch: Launch,
  flight: Flight,
  sets: look_common.Sets
)
  const scope = ctx.scope
  const duration = launch.duration
  const obj = pool.take(scope, template, false, true) :: BasePart

  -- a frame set is lent from the store, never worn as a copy of its folder
  for _, child in obj:GetChildren() do
    if setFolder(child) then
      child:Destroy()
    end
  end

  const objMesh = obj:FindFirstChildOfClass("SpecialMesh")
  const templateMesh = template:FindFirstChildOfClass("SpecialMesh")
  const size = template.Size

  -- read before a frame's decal joins the piece, where it would pass for one
  -- of the piece's own
  const decals = decalsOf(obj)

  const look = look_common.start(scope, obj, template, attrs, duration, sets, {
    owner = template,
    decals = decals,
  })

  tween.drive(scope, attrs.Scale(nil, duration), function(factor: any)
    if isVector(factor) then
      look.size(scaled(size, factor))
    end
  end)

  if objMesh and templateMesh then
    const meshScale = templateMesh.Scale

    tween.drive(scope, attrs.MeshScale(nil, duration), function(factor: any)
      if isVector(factor) then
        objMesh.Scale = scaled(meshScale, factor)
        look.refit()
      end
    end)
  end

  const locked = attrs.SyncPosition
  const faced = attrs.FaceVelocity
  const windy = attrs.WindAffectsDrag
  const drag = attrs.Drag
  const timeScale = attrs.TimeScale
  const origin = flight.origin
  const acceleration = flight.acceleration
  const turn = launch.turn
  const spin = vector.sign(turn) * utility.DEG_TO_RAD
  const at = launch.spawn.Position

  local position = toVector(at)
  local velocity = toVector(launch.spawn.LookVector) * launch.speed + flight.inherited
  local facing = if faced then along(velocity, flight.rotation) else flight.rotation

  -- the initial turn, each step's spin added onto it
  local rotation =
    CFrame.fromOrientation(turn.x * utility.DEG_TO_RAD, turn.y * utility.DEG_TO_RAD, turn.z * utility.DEG_TO_RAD)

  -- set once a projectile lands, where it left the piece
  local parked: CFrame? = nil

  const rotSpeed = attrs.RotSpeed(nil, duration)
  local currentRotSpeed = rotSpeed.at(0)

  tween.drive(scope, rotSpeed, function(v: number)
    currentRotSpeed = v
  end)

  const function live()
    return (originOf(template))
  end

  -- a piece locked to its parent rides the parent from where it spawned
  const function placed(cf: CFrame)
    return if locked then live() * origin:ToObjectSpace(cf) else cf
  end

  const function pose()
    const cf = parked or CFrame.new(position.x, position.y, position.z) * facing * rotation

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

  const life = look.life
  const ended = lifetime.join(scope)
  const finish = lifetime.add(ended)

  local age = 0
  local hit = false
  local moving = true
  local flying = false

  const function place()
    const cf = pose()

    if finite(cf) then
      mover.move(scope, obj, cf)
    end
  end

  const function advance(deltaTime: number)
    if flying then
      return
    end

    -- a piece at rest moves only with its parent or its frames
    if not moving then
      if locked or sets.frames then
        place()
      end

      return
    end

    -- the last step lands on the end of the life exactly
    const span = math.min(deltaTime, life - age)
    const dt = span * timeScale

    age += span

    if dt > 0 then
      const wind = if windy then toVector(workspace.GlobalWind) else vector.zero
      const nextPosition, nextVelocity = particle_motion.step(position, velocity, acceleration, drag, wind, dt)

      if numeric_common.usable(nextPosition) and numeric_common.usable(nextVelocity) then
        position, velocity = nextPosition, nextVelocity
      end

      if faced then
        facing = along(velocity, facing)
      end

      const add = spin * currentRotSpeed * dt

      if numeric_common.usable(add) then
        rotation *= CFrame.fromOrientation(add.x, add.y, add.z)
      end
    end

    place()

    if flight.hitbox ~= nil and flight_common.hit(flight.hitbox, obj) then
      hit = true
      moving = false
      finish()
      return
    end

    if age >= life then
      moving = false
      finish()
    end
  end

  const stepping = lifetime.step(scope, advance, "follow")
  lifetime.awaitJoin(ended)

  if attrs.ProjectileEnabled and not hit then
    -- the last velocity, carried into the world the piece is placed in
    const world = placed(CFrame.identity):VectorToWorldSpace(toVector3(velocity))
    const direction = if world.Magnitude > 0 then world.Unit else Vector3.zero
    const landing = lifetime.join(scope)

    flying = true

    flight_common.projectile(scope, obj, (direction * attrs.ProjectileSpeed) :: any, launch.flight, {
      params = flight.hitbox,
      follow = if locked then live else nil,
      keepTurn = true,
    }, lifetime.add(landing))

    lifetime.awaitJoin(landing)

    -- held where it landed, in the frame the piece spawned in
    const landed = mover.cframe(obj) * look.offset():Inverse()

    parked = if locked then origin * live():ToObjectSpace(landed) else landed
    flying = false
  end

  scope.effects.emitOnFinish(emitOnFinish, obj, scope.depth + 1, scope, children)

  look.linger()
  lifetime.awaitJoin(children)

  -- a piece that ends ahead of its emit leaves the world at once, out of
  -- reach of the writes still running on the effect; the pool takes it back
  -- when the effect lets go
  stepping:Disconnect()
  obj.Parent = nil
end

function forge_mesh.emit(ctx: reader.Ctx, attrs: any)
  const template = ctx.ref :: BasePart
  const scope = ctx.scope

  -- a plain emit of an enabled template switches it off; the tick's own emits
  -- leave it as it is
  if attrs.Enabled and not ctx.constant then
    enabled_effects.switch(template, false)
  end

  lifetime.wait(scope, attrs.EmitDelay)

  if attrs.EmitDuration > 0 and not ctx.constant then
    enabled_effects.window(ctx, forge_mesh, attrs.EmitDuration, attrs.Speed)
    return
  end

  if attrs.EmitCount <= 0 or bezier_common.SHAPES[attrs.Shape] == nil then
    return
  end

  -- every piece runs on the effect's clock, so one Speed track paces them all
  utility.speedFrom(scope, ctx.constant, attrs.Speed)

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

  const origin, size = originOf(template)
  const spread = attrs.SpreadAngle

  -- upper case, the spelling a row's vector and an authored Vector3 both
  -- answer to under every host
  const config: particle_motion.Config = {
    shape = attrs.Shape,
    surface = attrs.ShapeStyle == "Surface",
    partial = attrs.ShapePartial,
    normal = Enum.NormalId[attrs.EmissionDirection],
    face = attrs.ShapeFace,
    spread = vector.create(spread.X, spread.Y, 0),
  }

  const rng = Random.new()
  const range = attrs.Duration
  const speeds = attrs.Velocity
  const minTurn = attrs.MinInitRot
  const maxTurn = attrs.MaxInitRot
  const flights = attrs.ProjectileLifetime
  const flight = flightOf(template, attrs, origin)

  -- each piece runs on a thread the effect holds, so a clear closes it
  const outstanding = lifetime.join(scope)

  for _ = 1, attrs.EmitCount do
    -- speed and life ahead of the launch frame, the order a ParticleEmitter
    -- draws them in
    const speed = rng:NextNumber(speeds.Min, speeds.Max)
    const duration = rng:NextNumber(range.Min, range.Max)
    const spawn = particle_motion.spawn(origin, size, config, rng)

    const launch: Launch = {
      spawn = spawn,
      speed = speed,
      duration = duration,
      turn = vector.create(
        rng:NextNumber(minTurn.X, maxTurn.X),
        rng:NextNumber(minTurn.Y, maxTurn.Y),
        rng:NextNumber(minTurn.Z, maxTurn.Z)
      ),
      flight = if attrs.ProjectileEnabled then rng:NextNumber(flights.Min, flights.Max) else 0,
    }

    lifetime.spawn(outstanding, piece, ctx, attrs, template, launch, flight, sets)
  end

  lifetime.awaitJoin(outstanding)
end

return forge_mesh
