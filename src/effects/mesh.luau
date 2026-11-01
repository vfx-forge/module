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
local decal_fade = require("@mod/decal_fade")
local frame_show = require("@mod/frame_show")
local texture_show = require("@mod/texture_show")
local flipbook_loop = require("@mod/flipbook_loop")
local frames_common = require("@mod/common/frames")
local flipbook_common = require("@mod/common/flipbook")

local emitters = require("@root/emitters")

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

-- a decal's own glow rows, which the decal's card writes on the decal
const function glowStrength(decal: Decal, duration: number)
  const rest = attr.get(decal, "GlowStrength", 1, true, function(v)
    return if type(v) == "number" then math.max(v, 0) else 1
  end)

  return mods.track(decal, "attribute", "GlowStrength", rest, duration)
end

-- a track played on its own span, written once when it never moves
const function play(scope: lifetime.effect, track: mods.Track, write: (v: any) -> ())
  write(track.at(0))

  if track.animated then
    tween.play(scope, curve.new(track.span, "linear"), function(_, _, elapsed: number)
      write(track.at(elapsed))
    end)
  end
end

-- the decal's color, blended toward its twin and run through its own Color3
-- modifiers, times the strength when it glows by its color. never clamped, so
-- a strength past 1 brightens it past white. the mesh claims Color3 on its
-- decal in every glow mode, so this is its one writer
const function decalColor(scope: lifetime.effect, decal: Decal, twin: Color3, duration: number, glows: boolean)
  const rest = decal.Color3
  const blends = rest ~= twin
  const eased = curve.new(duration, attr.get(decal, "Color_Curve", utility.default_bezier, true))
  const tinted = mods.track(decal, "property", "Color3", rest, duration)
  const strength = if glows then glowStrength(decal, duration) else nil

  const function at(elapsed: number)
    const alpha = if duration > 0 then eased:at(math.min(elapsed / duration, 1)) else 1
    const base = if blends then color.blend(rest, twin, alpha, true) else rest
    const c = tinted.at(elapsed, base)

    if strength == nil then
      return c
    end

    const s = math.max(strength.at(elapsed), 0)

    return Color3.new(c.R * s, c.G * s, c.B * s)
  end

  -- written even when nothing moves, since a lane holding one color is not
  -- animated and still sets it
  decal.Color3 = at(0)

  if not blends and not tinted.animated and not (strength ~= nil and strength.animated) then
    return
  end

  local span = if blends then duration else 0

  for _, track in { tinted, strength } do
    if track.animated then
      span = math.max(span, track.span)
    end
  end

  tween.play(scope, curve.new(span, "linear"), function(_, _, elapsed: number)
    decal.Color3 = at(elapsed)
  end)
end

const function emissiveGlow(scope: lifetime.effect, decal: Decal, duration: number)
  const rest = attr.get(decal, "GlowTint", WHITE, true, function(v)
    return if typeof(v) == "Color3" then v else WHITE
  end)

  play(scope, glowStrength(decal, duration), function(v: number)
    decal.EmissiveStrength = math.max(v, 0)
  end)

  play(scope, mods.track(decal, "attribute", "GlowTint", rest, duration), function(v: Color3)
    decal.EmissiveTint = v
  end)
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
  -- nil where the model stores no start for its decal, which the decal's end
  -- reads to tell an old fade from a decal storing nothing
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

  local destroyDelay = attrs.DestroyDelay

  local legacy_isFlipbook = attrs.Flipbook
  local legacy_flipbookFadeOffset = attrs.FlipbookFadeOffset

  local legacy_decalST = attrs.DecalStartTransparency or 0
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

  -- a loop counting 0 plays for the piece's whole life, known only once every
  -- flipbook has its length, so it shows its first frame now and starts then
  const bounded: { (life: number) -> () } = {}

  -- every loop counting below 0 still playing, which the piece outlives
  const looping = lifetime.join(scope)

  -- a loop counting below 0 plays until `toggle` on `obj` is switched off, then
  -- to the end of its cycle. the one read of an instance after its rows
  -- resolve, since that switch while the loop plays is the only way it ends
  const function endless(
    obj: Instance,
    toggle: string,
    default: boolean,
    cycle: number,
    write: (elapsed: number, cycles: number) -> ()
  )
    -- a cycle of no length stands at its end from the start
    if not (cycle > 0) then
      write(0, 0)
      return
    end

    const stop = flipbook_loop.endless(scope, cycle, write, lifetime.add(looping))

    lifetime.hold(
      scope,
      attr.observe(obj, toggle, function(v: any)
        if (if v == nil then default else v) ~= true then
          stop()
        end
      end)
    )
  end

  const function loop(
    obj: Instance,
    shape: any,
    count: number,
    cycle: number,
    cycles: number,
    length: number,
    write: (alpha: number) -> ()
  )
    if cycles > 0 then
      flipbook_loop.play(scope, shape, cycle, cycles, length, write)
      return
    end

    const eased = curve.new(1, shape)

    if count < 0 then
      endless(obj, "FlipbookLoop", false, cycle, function(elapsed: number, played: number)
        write(eased:at(flipbook_common.phase(elapsed, cycle, played)))
      end)

      return
    end

    write(eased:at(0))

    table.insert(bounded, function(life: number)
      flipbook_loop.play(scope, shape, cycle, 0, life, write)
    end)
  end

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

    const function write(alpha: number)
      frameIndex = frames_common.index(frameCount, alpha)
      offset = shown.show(frameIndex, currentSize)
    end

    if attrs.FlipbookLoop then
      const cycle, cycles, length = flipbook_common.cycles(
        attrs.FlipbookChangeDuration,
        duration,
        attrs.SyncDuration,
        true,
        attrs.FlipbookLoopCount
      )

      longestFlipbookDuration = length
      loop(ref, attrs.FlipbookChangeCurve, attrs.FlipbookLoopCount, cycle, cycles, length, write)
    else
      const changeDuration = if attrs.SyncDuration then duration else attrs.FlipbookChangeDuration

      longestFlipbookDuration = changeDuration

      tween.play(scope, curve.new(changeDuration, attrs.FlipbookChangeCurve), write)
    end

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
    -- the list can name a decal twice, and a glow reads the color it multiplies
    -- off the decal it writes, so each decal glows once
    const glowing: { [Instance]: boolean } = {}

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

      -- a decal storing nothing holds where it rests unless its model stores
      -- a fade for it, an end or an old start alone
      local decalET = if attrs.DecalEndTransparency ~= nil then legacy_decalET else decalST
      local decalTp = mods.track(from, "attribute", "Transparency", mods.ramp(decalST, decalET), duration)

      decal.Transparency = decalTp.at(0)

      if decalTp.animated then
        tween.play(scope, curve.new(decalTp.span, "linear"), function(_, _, elapsed: number)
          decal.Transparency = decalTp.at(elapsed)
        end)
      end

      const glowMode = attr.get(from, "GlowMode", "None", true)
      const first = not glowing[decal]

      glowing[decal] = true

      -- an animator on the decal's Color3 is the explicit ask, so the mesh
      -- leaves the color to it
      const animated = emitters.animated(decal)

      if first and not (animated ~= nil and animated.Color3) then
        decalColor(scope, decal, to.Color3, duration, glowMode == "Color")
      end

      if glowMode == "Emissive" and first then
        emissiveGlow(scope, decal, duration)
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

        const write = flipbook_common.createUpdateCallback(config)

        if attr.get(from, "FlipbookLoop", false, true) == true then
          const count = attr.get(from, "FlipbookLoopCount", 0, true, function(v)
            return if type(v) == "number" and v == v then v else 0
          end)

          const cycle, cycles, length =
            flipbook_common.cycles(config.duration, duration, config.syncDuration, true, count)

          longestFlipbookDuration = math.max(longestFlipbookDuration, length)
          -- switched on the model's own decal, the one this piece's decal copies
          loop(start:FindFirstChild(from.Name) or from, config.curve, count, cycle, cycles, length, write)
        else
          local changeDuration = flipbook_common.getChangeDuration(config)

          if changeDuration > longestFlipbookDuration then
            longestFlipbookDuration = changeDuration
          end

          tween.play(scope, curve.new(changeDuration, config.curve), write)
        end
      end
    end
  end

  const fps = attrs.TextureFps
  const textureSync = attrs.TextureSyncDuration
  const textureCycle, textureCycles, textureLength =
    flipbook_common.cycles(textureCount / fps, duration, textureSync, attrs.TextureLoop, attrs.TextureLoopCount)

  if textures then
    longestFlipbookDuration = math.max(longestFlipbookDuration, textureLength)
  end

  const life = math.max(duration, longestFlipbookDuration) + legacy_flipbookFadeOffset

  for _, begin in bounded do
    begin(life + destroyDelay)
  end

  if textures then
    lifetime.defer(scope, textures.release)

    const rate = if textureSync then textureCount / textureCycle else fps
    local textureIndex = 0

    const function wear(elapsed: number, cycles: number)
      const index = flipbook_common.frame(elapsed, rate, textureCount, cycles)

      if index ~= textureIndex then
        textureIndex = index
        textures.show(index)
      end
    end

    if textureCycles == 0 and attrs.TextureLoopCount < 0 then
      endless(ref, "TextureLoop", true, textureCycle, wear)
    else
      -- a loop counting 0 wears the textures for as long as the piece is up
      const worn = if textureCycles == 0 then life + destroyDelay else textureLength

      tween.play(scope, curve.new(worn, "linear"), function(_, _, elapsed: number)
        wear(elapsed, textureCycles)
      end)
    end
  end

  -- the destroy delay runs once the last loop counting below 0 has stopped
  if looping.count > 0 then
    tween.wait(scope, curve.new(life, "linear"))
    lifetime.awaitJoin(looping)
    tween.wait(scope, curve.new(destroyDelay, "linear"))
  else
    tween.wait(scope, curve.new(life + destroyDelay, "linear"))
  end

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
