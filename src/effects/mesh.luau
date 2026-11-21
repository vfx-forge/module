--!nolint LocalShadow
local mod = require("@mod/mod")
local knob = require("@mod/knob")
local lazy = require("@mod/lazy")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local decal_fade = require("@mod/decal_fade")

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

const play = lazy.unit("mesh", function()
  return require("@root/play/mesh").bind(mesh)
end)

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
  MinInitRot = knob(vector.zero)
    :label("Min")
    :hint("Lower per-axis bound for each part's initial rotation, in degrees."),
  MaxInitRot = knob(vector.zero)
    :label("Max")
    :hint("Upper per-axis bound for each part's initial rotation, in degrees."),
  PartRotSpeed = knob(0):aliases("Part_RotSpeed"):unit("perSecond"):mod():label("Speed"):hint(
    "Rotation speed drawn for each piece, in radians per second, on the axes its initial rotation turns."
  ),
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

function mesh.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

function mesh.selected(ctx: any)
  return play().selected(ctx)
end

return mesh
