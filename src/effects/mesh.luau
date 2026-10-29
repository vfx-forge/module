--!nolint LocalShadow
local mod = require("@mod/mod")
local attr = require("@mod/attributes")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local curve = require("@mod/curve")
local color = require("@mod/color/color")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local frame_show = require("@mod/frame_show")
local texture_show = require("@mod/texture_show")
local frames_common = require("@mod/common/frames")
local flipbook_common = require("@mod/common/flipbook")

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

-- whether the oldest transparency pair, one StartTransparency and one
-- EndTransparency for the whole model, meant the mesh or its decal: the decal
-- when there is one and the model is not an old flipbook
local function stoneOnMesh(ctx: reader.Ctx, attrs: any)
  local start = ctx.ref:FindFirstChild("Start")

  return attrs.Flipbook or start == nil or start:FindFirstChildOfClass("Decal") == nil
end

local function partDefault(ctx: reader.Ctx)
  local start = ctx.ref:FindFirstChild("Start")

  return if start ~= nil and start:FindFirstChildOfClass("Decal") ~= nil then 1 else 0
end

local mesh = {}

mesh.id = "mesh"
mesh.display = { name = "Mesh", icon = "mesh", order = 100 }
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
  DecalStartTransparency = knob(function(ctx, attrs)
      return if stoneOnMesh(ctx, attrs) then 0 else attrs.StartTransparency or 0
    end)
    :aliases("Decal_StartTransparency")
    :hidden(always),
  DecalEndTransparency = knob(function(ctx, attrs)
      return if stoneOnMesh(ctx, attrs) then 1 else attrs.EndTransparency
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
  SyncDuration = knob(false):hidden(noFrames):label("SyncDuration"):hint("Play the frames over the effect's duration."),
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
    :label("TextureFps")
    :hint("Texture frames worn per second, looping for the piece's life."),
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
      "FrameTransparency",
      "TextureFps",
    },
  },
  { title = "Glow", entries = { "SurfaceColor", "EmissiveStrength", "EmissiveTint" } },
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

  local destroyDelay = attrs.DestroyDelay

  local legacy_isFlipbook = attrs.Flipbook
  local legacy_flipbookFadeOffset = attrs.FlipbookFadeOffset

  local legacy_decalST = attrs.DecalStartTransparency
  -- no authored end holds the decal where it starts rather than fading it
  local legacy_decalET = if attrs.DecalEndTransparency ~= nil then attrs.DecalEndTransparency else legacy_decalST

  local sync = attrs.SyncPosition

  local partTp = attrs.PartTransparency(nil, duration)
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
  const surface = obj:FindFirstChildOfClass("SurfaceAppearance")

  -- read before a frame's decal joins the piece, where it would pass for one
  -- of the piece's own
  local decals, flipbooks, fromToMap = utility.getMeshDecals(ref, obj)

  const frameCount = if set then #set.frames else 0
  const textureCount = if textureSet then #textureSet.frames else 0
  const textures = if textureSet and textureCount > 0 then texture_show.new(textureSet, obj) else nil

  -- a texture set shown takes the surface, so the frames bring only their shapes
  const shown = if set and frameCount > 0
    then frame_show.new(set, obj, start, if textures then { materials = false } else nil)
    else nil

  local offset = Vector3.zero
  local frameIndex = 1
  local currentSize = sizeStart
  local longestFlipbookDuration = 0

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

    -- the frame's center off the union's, along the piece's own axes
    if shown then
      cf *= CFrame.new(offset)
    end

    return cf
  end

  -- while frames play on a piece with no special mesh, the frame's fit is the
  -- piece's size, so a size lands through the frame shown
  const function fitSize(size: Vector3)
    currentSize = size

    if shown == nil or objMesh ~= nil then
      obj.Size = size
    end

    if shown then
      offset = shown.show(frameIndex, size)
    end
  end

  if shown then
    -- a defer runs ahead of the clones, so the frame's material is given back
    -- before a piece cloned whole is destroyed with it
    lifetime.defer(scope, shown.release)

    const changeDuration = if attrs.SyncDuration then duration else attrs.FlipbookChangeDuration

    longestFlipbookDuration = changeDuration

    tween.play(scope, curve.new(changeDuration, attrs.FlipbookChangeCurve), function(alpha: number)
      frameIndex = frames_common.index(frameCount, alpha)
      offset = shown.show(frameIndex, currentSize)
    end)

    const fade = attrs.FrameTransparency(nil, duration)

    -- a fade at rest leaves every decal frame at its own transparency
    if fade.animated or fade.at(0) ~= 0 then
      tween.drive(scope, fade, function(v: number)
        shown.fade(v)
      end)
    end
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

  tween.drive(scope, partTp, function(v: number)
    obj.Transparency = v
  end)

  const strength = attrs.EmissiveStrength(nil, duration)
  const tint = attrs.EmissiveTint(nil, duration)
  const surfaceColor = attrs.SurfaceColor(nil, duration)

  -- a glow at rest writes nothing, so every material keeps its own
  if
    strength.animated
    or tint.animated
    or surfaceColor.animated
    or strength.at(0) ~= 1
    or tint.at(0) ~= WHITE
    or surfaceColor.at(0) ~= WHITE
  then
    const framed = set ~= nil and set.materials and textures == nil
    const authored = start:FindFirstChildOfClass("SurfaceAppearance") :: any
    const baseStrength = if authored then authored.EmissiveStrength else 1
    const baseTint = if authored then authored.EmissiveTint else WHITE
    const baseColor = if authored then authored.Color else WHITE

    local glowStrength, glowTint, glowColor = strength.at(0), tint.at(0), surfaceColor.at(0)

    const function shine()
      if textures then
        textures.glow(glowStrength, glowTint, glowColor)
      elseif shown and framed then
        shown.glow(glowStrength, glowTint, glowColor)
      elseif surface and authored then
        surface.EmissiveStrength = baseStrength * glowStrength
        surface.EmissiveTint = Color3.new(baseTint.R * glowTint.R, baseTint.G * glowTint.G, baseTint.B * glowTint.B)
        surface.Color = Color3.new(baseColor.R * glowColor.R, baseColor.G * glowColor.G, baseColor.B * glowColor.B)
      end
    end

    tween.drive(scope, strength, function(v: number)
      glowStrength = v
      shine()
    end)

    tween.drive(scope, tint, function(v: Color3)
      glowTint = v
      shine()
    end)

    tween.drive(scope, surfaceColor, function(v: Color3)
      glowColor = v
      shine()
    end)
  end

  if sizeStart ~= sizeEnd then
    local lastSizeAlpha = -1

    tween.play(scope, curve.new(duration, attrs.PartSizeCurve), function(alpha: number)
      -- reduce size writes
      if math.abs(alpha - lastSizeAlpha) < 0.005 then
        return
      end

      lastSizeAlpha = alpha
      fitSize(sizeStart:Lerp(sizeEnd, alpha))
    end)
  else
    fitSize(sizeStart)
  end

  local startMesh = start:FindFirstChildOfClass("SpecialMesh")
  local goalMesh = goal:FindFirstChildOfClass("SpecialMesh")

  if objMesh then
    if startMesh and goalMesh then
      local scaleStart, scaleEnd = startMesh.Scale, goalMesh.Scale

      if scaleStart ~= scaleEnd then
        tween.play(scope, curve.new(duration, attrs.MeshScaleCurve), function(alpha: number)
          objMesh.Scale = utility.lerp(scaleStart, scaleEnd, alpha)

          if shown then
            offset = shown.show(frameIndex, currentSize)
          end
        end)
      end
    else
      objMesh.Parent = nil

      lifetime.hold(scope, function()
        objMesh.Parent = obj
      end)
    end
  end

  if legacy_isFlipbook then
    table.sort(decals, function(a, b)
      local x = a.Name:match("%d+") or 0
      local y = b.Name:match("%d+") or 0

      return tonumber(x) < tonumber(y)
    end)

    local displayDecal = Instance.new("Decal")
    displayDecal.Parent = obj

    lifetime.hold(scope, displayDecal)

    if legacy_flipbookFadeOffset > 0 then
      if legacy_decalST ~= legacy_decalET then
        tween.play(scope, curve.new(duration + legacy_flipbookFadeOffset, "easeOut"), function(alpha: number)
          displayDecal.Transparency = utility.lerp(legacy_decalST, legacy_decalET, alpha)
        end)
      end
    end

    tween.play(scope, curve.new(duration, "easeOut"), function(alpha: number)
      local index = math.max(math.round(#decals * alpha), 1)
      local target = decals[index]

      displayDecal.Texture = target.Texture

      displayDecal.Color3 = target.Color3
      displayDecal.ZIndex = target.ZIndex

      if legacy_flipbookFadeOffset == 0 then
        displayDecal.Transparency = utility.lerp(legacy_decalST, legacy_decalET, alpha)
        displayDecal.ZIndex = target.ZIndex
      end
    end)
  else
    for _, decal in decals do
      local from = decal
      local to = fromToMap[from]

      -- this knob is authored on the DECAL rather than on ref: ownership is
      -- keyed to the instance dispatch routes to, and the decal is dispatched
      -- on its own through emitNested. the decal's own resting value, which
      -- the plugin's Transparency row writes, leads the model's old pair
      local decalST = attr.get(from, "Transparency", legacy_decalST, true, function(v)
        return if type(v) == "number" then v else legacy_decalST
      end)

      -- a decal storing nothing holds where it rests; only an end the model
      -- authored makes it fade by default
      local decalET = if attrs.DecalEndTransparency ~= nil then legacy_decalET else decalST
      local decalTp = mods.track(from, "attribute", "Transparency", mods.ramp(decalST, decalET), duration)

      decal.Transparency = decalTp.at(0)

      if decalTp.animated then
        tween.play(scope, curve.new(decalTp.span, "linear"), function(_, _, elapsed: number)
          decal.Transparency = decalTp.at(elapsed)
        end)
      end

      if from.Color3 ~= to.Color3 then
        local colorCurve = curve.new(duration, attr.get(from, "Color_Curve", utility.default_bezier, true))

        tween.play(scope, colorCurve, function(alpha: number)
          decal.Color3 = color.blend(from.Color3, to.Color3, alpha, true)
        end)
      end

      local flipbook = flipbooks[from]

      if flipbook then
        local config = {
          ref = from,
          frames = flipbook,
          effectDuration = duration,
          syncDuration = attr.get(from, "SyncDuration", false, true) == true,

          curve = attr.get(from, "Flipbook_Change_Curve", utility.linear_bezier, true),
          duration = attr.get(from, "Flipbook_Change_Duration", duration, true),

          setTexture = function(texture)
            decal.Texture = texture
          end,
        }

        local changeDuration = flipbook_common.getChangeDuration(config)

        if changeDuration > longestFlipbookDuration then
          longestFlipbookDuration = changeDuration
        end

        tween.play(scope, curve.new(changeDuration, config.curve), flipbook_common.createUpdateCallback(config))
      end
    end
  end

  const life = math.max(duration, longestFlipbookDuration) + legacy_flipbookFadeOffset + destroyDelay

  if textures then
    lifetime.defer(scope, textures.release)

    const fps = attrs.TextureFps
    local textureIndex = 0

    -- the textures loop on their own clock for as long as the piece is up
    tween.play(scope, curve.new(life, "linear"), function(_, _, elapsed: number)
      const index = math.floor(elapsed * fps) % textureCount + 1

      if index ~= textureIndex then
        textureIndex = index
        textures.show(index)
      end
    end)
  end

  tween.wait(scope, curve.new(life, "linear"))

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
    frame_store.warm(set)
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
