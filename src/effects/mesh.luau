--!nolint LocalShadow
local mod = require("@mod/mod")
local knob = require("@mod/knob")
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local decal_fade = require("@mod/decal_fade")
local look_common = require("@mod/common/look")

local pool = require("@srv/pool")
local mover = require("@srv/mover")
local frame_store = require("@srv/frame_store")
local enabled_effects = require("@srv/enabled_effects")

local rng = Random.new()

const WHITE = Color3.new(1, 1, 1)

local function always()
  return true
end

local function eased()
  return utility.default_bezier
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

local function stoneOnMesh(ctx: reader.Ctx, attrs: any)
  return decal_fade.onMesh(ctx.ref:FindFirstChild("Start"), attrs.Flipbook)
end

-- the decal's fade as the model stores it, the decal's own start taken as
-- `decalStart` once its row has resolved
const function decalFade(ctx: reader.Ctx, attrs: any, decalStart: number?)
  return decal_fade.resolve(ctx.ref:FindFirstChild("Start"), {
    flipbook = attrs.Flipbook,
    start = attrs.StartTransparency,
    finish = attrs.EndTransparency,
    decalStart = decalStart,
    decalEnd = nil,
  })
end

local function partDefault(ctx: reader.Ctx)
  local start = ctx.ref:FindFirstChild("Start")

  return if start ~= nil and start:FindFirstChildOfClass("Decal") ~= nil then 1 else 0
end

-- whether any frame of the model's frame set wears a look; a shape-only set's
-- frames wear none, so the glow has nothing to reach
const function framesDressed(model: Instance, key: string): boolean
  for _, folder in model:GetChildren() do
    if not folder:IsA("Folder") or folder.Name ~= "Frames" or folder:GetAttribute("FrameSet") ~= key then
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

-- the surface glow reaches only a surface appearance, one the start wears or
-- one a texture or dressed frame set brings
const function bare(ctx: reader.Ctx, attrs: any)
  const start = ctx.ref:FindFirstChild("Start")
  const surfaced = start ~= nil and start:FindFirstChildOfClass("SurfaceAppearance") ~= nil

  if surfaced or attrs.TextureSet ~= "" then
    return false
  end

  return attrs.FrameSet == "" or not framesDressed(ctx.ref, attrs.FrameSet)
end

local mesh = {}

mesh.id = "mesh"
mesh.display = { name = "Mesh (legacy)", icon = "mesh", order = 100 }
mesh.classifier = "Model:has(> BasePart#Start):has(> BasePart#End)"
mesh.components = "Instance"
mesh.constant = true

mesh.attributes = {
  EmitCount = knob(1):min(0):label("Count"):hint("The amount of effects to emit."),
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
  EmitDuration = knob(0):min(0):unit("seconds"):label("Duration"):hint("Duration of the emit cycle in seconds."),
  DestroyDelay = knob(0)
    :min(0)
    :unit("seconds")
    :label("DestroyDelay")
    :hint("Extra seconds to keep the part alive after the effect finishes."),
  EffectDuration = knob(NumberRange.new(1, 1))
    :min(0)
    :aliases("Duration")
    :unit("seconds")
    :label("Duration")
    :hint("Duration range of the effect in seconds."),
  SpreadAngle = knob(vector.zero):label("SpreadAngle"):hint("Random rotation spread applied to emitted effects."),
  SyncPosition = knob(false):label("SyncPosition"):hint("Whether the effect follows the emitter's position."),
  Enabled = knob(false):label("Enabled"):hint("Whether the effect continuously emits."),
  -- the tick reads the rate off the instance itself, so the row is here for
  -- the plugin and for retime rather than for any emit
  Rate = knob(5):min(0):unit("perSecond"):label("Rate"):hint("Effects emitted per second when Enabled is true."),
  RotAroundOrigin = knob(false)
    :label("AroundOrigin")
    :hint("Rotate around the emitter origin instead of the part's own center."),
  MinInitRot = knob(vector.zero):label("Min"):hint("Lower per-axis bound for each part's initial rotation."),
  MaxInitRot = knob(vector.zero):label("Max"):hint("Upper per-axis bound for each part's initial rotation."),
  PartRotSpeed = knob(0)
    :aliases("Part_RotSpeed")
    :unit("perSecond")
    :mod()
    :label("Speed")
    :hint("Rotation speed drawn for each piece, in degrees per second."),
  PartCFrameCurve = knob(eased)
    :aliases("Part_CFrame_Curve")
    :label("CFrame")
    :hint("Easing of the part's travel from Start to End."),
  PartSizeCurve = knob(eased)
    :aliases("Part_Size_Curve")
    :label("Size")
    :hint("Easing of the part's size from Start to End."),
  MeshScaleCurve = knob(eased)
    :aliases("Mesh_Scale_Curve")
    :label("Scale")
    :hint("Easing of the mesh scale from Start to End."),
  Speed = knob(1):mod():label("Speed"):hint("Multiplier on the effect's clock."),
  -- the oldest assets' inputs, read and never renamed. which surface the
  -- stone-age pair means depends on what the model holds, so the per-surface
  -- rows fall back through it
  Flipbook = knob(false):hidden(always),
  FlipbookFadeOffset = knob(0):min(0):unit("seconds"):hidden(always),
  StartTransparency = knob():hidden(always),
  EndTransparency = knob():hidden(always),
  -- nil where the model stores no start for its decal. the end is 1 where it
  -- stores none, so a decal fades to clear by default as it did in v2.4.0
  DecalStartTransparency = knob(function(ctx, attrs)
      return (decalFade(ctx, attrs, nil))
    end)
    :aliases("Decal_StartTransparency")
    :hidden(always),
  DecalEndTransparency = knob(function(ctx, attrs)
      const _, finish = decalFade(ctx, attrs, attrs.DecalStartTransparency)

      return finish
    end)
    :aliases("Decal_EndTransparency")
    :hidden(always),
  MeshStartTransparency = knob(function(ctx, attrs)
      local base = partDefault(ctx)
      return if stoneOnMesh(ctx, attrs) then attrs.StartTransparency or base else base
    end)
    :aliases("Mesh_StartTransparency")
    :hidden(always),
  MeshEndTransparency = knob(function(ctx, attrs)
      local base = partDefault(ctx)
      return if stoneOnMesh(ctx, attrs) then attrs.EndTransparency or base else base
    end)
    :aliases("Mesh_EndTransparency")
    :hidden(always),
  -- the part's transparency rests at the mesh end value and ramps from the
  -- mesh start value over the piece's duration, as the old default did
  PartTransparency = knob(function(_, attrs)
      return attrs.MeshEndTransparency
    end)
    :aliases("Part_Transparency")
    :mod(mod.from(function(_, attrs)
      return attrs.MeshStartTransparency
    end))
    :label("Transparency")
    :hint("Part transparency over the piece's duration."),
  -- the key of the Frames folder the model plays, which the plugin writes
  FrameSet = knob(""):hidden(always),
  FlipbookChangeDuration = knob(function(ctx)
      return ctx.duration
    end)
    :aliases("Flipbook_Change_Duration")
    :unit("seconds")
    :hidden(noFrames)
    :label("Duration")
    :hint("Seconds the frames play over."),
  FlipbookChangeCurve = knob(linear)
    :aliases("Flipbook_Change_Curve")
    :hidden(noFrames)
    :label("Curve")
    :hint("Easing of the frames' playback."),
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
}

mesh.properties = {}

mesh.layout = {
  { title = "Emit", entries = { "EmitCount", "EmitDelay", "EmitDuration", "DestroyDelay" } },
  { title = "Effect", entries = { "EffectDuration", "SpreadAngle", "SyncPosition", "Enabled", "Rate", "Speed" } },
  {
    title = "Random Rotation",
    entries = { "RotAroundOrigin", "MinInitRot", "MaxInitRot", { title = "Speed", entries = { "PartRotSpeed" } } },
  },
  {
    title = "Part",
    entries = {
      "PartTransparency",
      "PartCFrameCurve",
      "PartSizeCurve",
      "MeshScaleCurve",
    },
  },
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
  { title = "Glow", entries = { "SurfaceColor", "EmissiveStrength", "EmissiveTint" }, hidden = bare },
  {
    title = "Behavior",
    entries = {
      { action = "toggle_textures", label = "Load Textures" },
    },
  },
}

function mesh.duration(_, attrs: any)
  return attrs.EffectDuration.Max
end

-- one piece: the assembled part driven over a duration of its own, the tail of
-- the old effect body. `start` and `goal` are the ones the emit checked: the
-- piece runs after the emit's delay, by which time the model may no longer
-- hold them
local function piece(
  ctx: reader.Ctx,
  attrs: any,
  start: BasePart,
  goal: BasePart,
  obj: BasePart,
  duration: number,
  set: frame_store.Set?,
  textureSet: frame_store.Set?
)
  local ref = ctx.ref :: Model
  local scope = ctx.scope

  local sync = attrs.SyncPosition

  local rotSpeed = attrs.PartRotSpeed(nil, duration)

  local rotSpeedStart = rotSpeed.at(0)

  local spreadAngle = attrs.SpreadAngle

  local rotAroundOrigin = attrs.RotAroundOrigin

  local minInitRot = attrs.MinInitRot
  local maxInitRot = attrs.MaxInitRot

  -- upper case, the spelling a row's vector and an authored Vector3 both answer to under every host
  local initRot = vector.create(
    rng:NextNumber(minInitRot.X, maxInitRot.X),
    rng:NextNumber(minInitRot.Y, maxInitRot.Y),
    rng:NextNumber(minInitRot.Z, maxInitRot.Z)
  ) * utility.DEG_TO_RAD

  local parent = ref:FindFirstAncestorOfClass("Attachment") or start

  local origin = utility.getTransformedOriginExtents(parent)
  local goalCFrameOffset = start.CFrame:ToObjectSpace(goal.CFrame)

  local currentRotSpeed = rotSpeedStart

  local currentRot = CFrame.fromOrientation(initRot.x, initRot.y, initRot.z)
  local currentCFrame = CFrame.identity

  local spread = CFrame.fromOrientation(
    math.rad(rng:NextNumber(-spreadAngle.x, spreadAngle.x)),
    math.rad(rng:NextNumber(-spreadAngle.y, spreadAngle.y)),
    0
  )

  local sizeStart, sizeEnd = start.Size, goal.Size

  local objMesh = obj:FindFirstChildOfClass("SpecialMesh")

  -- read before a frame's decal joins the piece, where it would pass for one
  -- of the piece's own
  const decals, flipbooks, twins = utility.getMeshDecals(ref, obj)

  const look = look_common.start(scope, obj, start, attrs, duration, { frames = set, textures = textureSet }, {
    owner = ref,
    decals = { list = decals, flipbooks = flipbooks, twins = twins },
  })

  local function pose(deltaTime: number)
    local o = sync and utility.getTransformedOriginExtents(parent) or origin
    local add = vector.sign(initRot) * currentRotSpeed * deltaTime

    currentRot *= CFrame.fromOrientation(add.x, add.y, add.z)

    local cf

    if rotAroundOrigin then
      cf = o * spread * currentRot * currentCFrame
    else
      cf = o * spread * currentCFrame * currentRot
    end

    cf *= currentRot

    return cf * look.offset()
  end

  -- the first pose is written at once, so a reused piece never shows a frame
  -- where its last holder let it go
  obj.CFrame = pose(0)

  lifetime.step(scope, function(deltaTime: number)
    mover.move(scope, obj, pose(deltaTime))
  end, "follow")

  local children = lifetime.join(scope)

  local emitOnFinish = scope.effects.prepareEmitOnFinish(obj, scope)

  scope.effects.emitNested(obj, scope.depth + 1, scope, children)

  if goalCFrameOffset ~= CFrame.identity then
    tween.play(scope, curve.new(duration, attrs.PartCFrameCurve), function(alpha: number)
      currentCFrame = CFrame.identity:Lerp(goalCFrameOffset, alpha)
    end)
  end

  tween.drive(scope, rotSpeed, function(v: number)
    currentRotSpeed = v
  end)

  if sizeStart ~= sizeEnd then
    local lastSizeAlpha = -1

    tween.play(scope, curve.new(duration, attrs.PartSizeCurve), function(alpha: number)
      -- reduce size writes
      if math.abs(alpha - lastSizeAlpha) < 0.005 then
        return
      end

      lastSizeAlpha = alpha
      look.size(sizeStart:Lerp(sizeEnd, alpha))
    end)
  else
    look.size(sizeStart)
  end

  local startMesh = start:FindFirstChildOfClass("SpecialMesh")
  local goalMesh = goal:FindFirstChildOfClass("SpecialMesh")

  if objMesh then
    if startMesh and goalMesh then
      local scaleStart, scaleEnd = startMesh.Scale, goalMesh.Scale

      if scaleStart ~= scaleEnd then
        tween.play(scope, curve.new(duration, attrs.MeshScaleCurve), function(alpha: number)
          objMesh.Scale = utility.lerp(scaleStart, scaleEnd, alpha)
          look.refit()
        end)
      end
    else
      objMesh.Parent = nil

      lifetime.hold(scope, function()
        objMesh.Parent = obj
      end)
    end
  end

  look.play()
  look.wait()

  lifetime.awaitJoin(children)

  scope.effects.emitOnFinish(emitOnFinish, obj, scope.depth + 1, scope, children)
  lifetime.awaitJoin(children)
end

function mesh.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: Model
  local scope = ctx.scope

  local start = ref:FindFirstChild("Start")
  local goal = ref:FindFirstChild("End")

  if not start or not goal or not start:IsA("BasePart") or not goal:IsA("BasePart") then
    return
  end

  -- a plain emit of an enabled model switches it off; the tick's own emits
  -- leave it as it is
  if attrs.Enabled and not ctx.constant then
    enabled_effects.switch(ref, false)
  end

  lifetime.wait(scope, attrs.EmitDelay)

  -- every EmitDuration runs as a window, tagged or not. v2 asked for
  -- ConstantVFX here, but its tag was a switch of its own; the tag now follows
  -- Enabled and leaves every model switched off in edit mode, so v2's check
  -- would emit each of them once
  if attrs.EmitDuration > 0 and not ctx.constant then
    enabled_effects.window(ctx, mesh, attrs.EmitDuration, attrs.Speed)
    return
  end

  local range = attrs.EffectDuration

  -- every piece runs on the effect's clock, so one Speed track paces them all
  utility.speedFrom(scope, ctx.constant, attrs.Speed)

  const set = if attrs.FrameSet ~= "" then frame_store.find(ref, attrs.FrameSet) else nil
  const textureSet = if attrs.TextureSet ~= "" then frame_store.findTextures(ref, attrs.TextureSet) else nil

  if set then
    frame_store.warm(set, ref:FindFirstChild("Start"), textureSet)
  end

  if textureSet then
    frame_store.warm(textureSet)
  end

  -- each piece runs on a thread the effect holds, so a clear closes it
  local outstanding = lifetime.join(scope)

  for _ = 1, attrs.EmitCount do
    local duration = rng:NextNumber(range.Min, range.Max)

    lifetime.spawn(outstanding, function()
      piece(
        ctx,
        attrs,
        start :: BasePart,
        goal :: BasePart,
        pool.take(scope, start) :: BasePart,
        duration,
        set,
        textureSet
      )
    end)
  end

  lifetime.awaitJoin(outstanding)
end

-- a mesh under an attachment pivots on that attachment, so a scale or a spin
-- authored in the panel turns about the point the emit turns about
function mesh.selected(ctx: reader.Ctx)
  local model = ctx.ref :: Model
  local parent = model.Parent

  if parent == nil or not parent:IsA("Attachment") then
    return
  end

  local primary = model.PrimaryPart

  if primary == nil then
    model.WorldPivot = parent.WorldCFrame
  else
    primary.PivotOffset = primary.CFrame:ToObjectSpace(parent.WorldCFrame)
  end
end

return mesh
