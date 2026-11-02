const attr = require("@mod/attributes")
const knob = require("@mod/knob")
const tween = require("@mod/tween")
const reader = require("@mod/reader")
const utility = require("@mod/utility")
const lifetime = require("@mod/lifetime")
const look_common = require("@mod/common/look")
const bezier_common = require("@mod/common/bezier")
const particle_motion = require("@mod/particle_motion")

const pool = require("@srv/pool")
const mover = require("@srv/mover")
const frame_store = require("@srv/frame_store")
const enabled_effects = require("@srv/enabled_effects")

const WHITE = Color3.new(1, 1, 1)

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

const forge_mesh = {}

forge_mesh.id = "forge_mesh"
forge_mesh.display = { name = "Mesh", icon = "forge_mesh", order = 95 }
forge_mesh.classifier = `BasePart.{utility.FORGE_MESH_TAG}`

-- the template's mesh, frame folders and decals are its own; the effects
-- nested in it run per piece
forge_mesh.components = "Instance"

const attributes = bezier_common.rows({
  Motion = knob("Particle"):options({ "Particle" }):label("Motion"):hint("How each piece moves after it spawns."),
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

forge_mesh.attributes = attributes

forge_mesh.properties = {}

forge_mesh.layout = {
  { title = "Emit", entries = { "EmitCount", "EmitDelay", "EmitDuration", "DestroyDelay" } },
  { title = "Effect", entries = { "Duration", "SpreadAngle", "Enabled", "Rate", "SyncPosition", "Speed" } },
  { title = "Shape", entries = { "EmissionDirection", "Shape", "ShapePartial", "ShapeStyle", "ShapeFace" } },
  { title = "Motion", entries = { "Motion" } },
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

-- one piece: a bare copy of the template standing at `spawn` for its life,
-- wearing the look, its nested effects run on it
const function piece(
  ctx: reader.Ctx,
  attrs: any,
  template: BasePart,
  spawn: CFrame,
  duration: number,
  sets: look_common.Sets
)
  const scope = ctx.scope
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

  const function pose()
    return spawn * look.offset()
  end

  -- the first pose is written at once, so a reused piece never shows a frame
  -- where its last holder let it go
  obj.CFrame = pose()

  -- a frame's offset moves the piece as the frames play
  if sets.frames then
    lifetime.step(scope, function()
      mover.move(scope, obj, pose())
    end, "follow")
  end

  const children = lifetime.join(scope)
  const emitOnFinish = scope.effects.prepareEmitOnFinish(obj, scope)

  scope.effects.emitNested(obj, scope.depth + 1, scope, children)

  look.play()
  look.wait()

  lifetime.awaitJoin(children)

  scope.effects.emitOnFinish(emitOnFinish, obj, scope.depth + 1, scope, children)
  lifetime.awaitJoin(children)
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

  -- each piece runs on a thread the effect holds, so a clear closes it
  const outstanding = lifetime.join(scope)

  for _ = 1, attrs.EmitCount do
    const spawn = particle_motion.spawn(origin, size, config, rng)
    const duration = rng:NextNumber(range.Min, range.Max)

    lifetime.spawn(outstanding, piece, ctx, attrs, template, spawn, duration, sets)
  end

  lifetime.awaitJoin(outstanding)
end

return forge_mesh
