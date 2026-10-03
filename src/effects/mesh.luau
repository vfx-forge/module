--!nolint LocalShadow
local mod = require("@mod/mod")
local attr = require("@mod/attributes")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local flipbook_common = require("@mod/common/flipbook")
local enabled_effects = require("@srv/enabled_effects")

local Oklab = require("@mod/color/Oklab")

local rng = Random.new()

local function always()
  return true
end

local function eased()
  return utility.default_bezier
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
  -- the span an old speed quad ran over, read by the old format's reader under
  -- this name and kept as a row so retime reaches it
  SpeedDuration = knob(0.1):min(0):aliases("Speed_Duration"):unit("seconds"):hidden(always),
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
      return if stoneOnMesh(ctx, attrs) then 1 else attrs.EndTransparency or 1
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
    title = "Behavior",
    entries = {
      { action = "toggle_constant", label = "Add Enabled Tag" },
      { action = "toggle_textures", label = "Load Textures" },
    },
  },
}

function mesh.duration(_, attrs: any)
  return attrs.EffectDuration.Max
end

local part_cache: any

function mesh.init(cache)
  part_cache = cache
end

function mesh.deinit()
  part_cache = nil
end

-- one piece: the assembled part driven over a duration of its own, the tail of
-- the old effect body
local function piece(ctx: reader.Ctx, attrs: any, obj: any, duration: number)
  local ref = ctx.ref :: Model
  local scope = ctx.scope
  local scale = ctx.scale

  local start = ref:FindFirstChild("Start") :: BasePart
  local goal = ref:FindFirstChild("End") :: BasePart

  local destroyDelay = attrs.DestroyDelay

  local legacy_isFlipbook = attrs.Flipbook
  local legacy_flipbookFadeOffset = attrs.FlipbookFadeOffset

  local legacy_decalST = attrs.DecalStartTransparency
  local legacy_decalET = attrs.DecalEndTransparency

  local sync = attrs.SyncPosition

  local partTp = attrs.PartTransparency(nil, duration)
  local rotSpeed = attrs.PartRotSpeed(nil, duration)

  local rotSpeedStart = rotSpeed.at(0)

  local spreadAngle = attrs.SpreadAngle

  local rotAroundOrigin = attrs.RotAroundOrigin

  local minInitRot = attrs.MinInitRot
  local maxInitRot = attrs.MaxInitRot

  local initRot = vector.create(
    rng:NextNumber(minInitRot.x, maxInitRot.x),
    rng:NextNumber(minInitRot.y, maxInitRot.y),
    rng:NextNumber(minInitRot.z, maxInitRot.z)
  ) * utility.DEG_TO_RAD

  local parent = ref:FindFirstAncestorOfClass("Attachment") or start
  local realObj = typeof(obj) == "table" and obj._getReal() or obj

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

  local function updatePos(deltaTime: number)
    local o = sync and utility.getTransformedOriginExtents(parent) or origin
    local add = initRot:Sign() * currentRotSpeed * deltaTime

    currentRot *= CFrame.fromOrientation(add.x, add.y, add.z)

    local cf

    if rotAroundOrigin then
      cf = o * spread * currentRot * currentCFrame
    else
      cf = o * spread * currentCFrame * currentRot
    end

    cf *= currentRot

    obj.CFrame = cf
  end

  updatePos(0)

  lifetime.step(scope, updatePos, "follow")

  local children = lifetime.join(scope)

  local emitOnFinish = scope.effects.prepareEmitOnFinish(obj, scope)

  scope.effects.emitNested(obj, scope.depth + 1, scope, children)

  if goalCFrameOffset ~= CFrame.identity then
    lifetime.hold(
      scope,
      tween.fromParams(attrs.PartCFrameCurve, duration, function(alpha, deltaTime)
        currentCFrame = CFrame.identity:Lerp(goalCFrameOffset, alpha)
        return deltaTime
      end)
    )
  end

  if rotSpeed.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, rotSpeed.duration, function(_, deltaTime, elapsed)
        currentRotSpeed = rotSpeed.at(elapsed)
        return deltaTime
      end)
    )
  end

  obj.Transparency = partTp.at(0)

  if partTp.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, partTp.duration, function(_, deltaTime, elapsed)
        obj.Transparency = partTp.at(elapsed)
        return deltaTime
      end)
    )
  end

  local sizeStart, sizeEnd = start.Size * scale, goal.Size * scale

  if sizeStart ~= sizeEnd then
    local lastSizeAlpha = -1

    lifetime.hold(
      scope,
      tween.fromParams(attrs.PartSizeCurve, duration, function(alpha, deltaTime)
        -- reduce size writes
        if math.abs(alpha - lastSizeAlpha) < 0.005 then
          return deltaTime
        end

        lastSizeAlpha = alpha
        obj.Size = sizeStart:Lerp(sizeEnd, alpha)

        return deltaTime
      end)
    )
  else
    obj.Size = sizeStart
  end

  local startMesh = start:FindFirstChildOfClass("SpecialMesh")
  local goalMesh = goal:FindFirstChildOfClass("SpecialMesh")

  local objMesh = obj:FindFirstChildOfClass("SpecialMesh")

  if objMesh then
    if startMesh and goalMesh then
      local scaleStart, scaleEnd = startMesh.Scale * scale, goalMesh.Scale * scale

      if scaleStart ~= scaleEnd then
        lifetime.hold(
          scope,
          tween.fromParams(attrs.MeshScaleCurve, duration, function(alpha, deltaTime)
            objMesh.Scale = utility.lerp(scaleStart, scaleEnd, alpha)
            return deltaTime
          end)
        )
      end
    else
      objMesh.Parent = nil

      lifetime.hold(scope, function()
        objMesh.Parent = realObj
      end)
    end
  end

  local decals, flipbooks, fromToMap = utility.getMeshDecals(ref, obj)

  local longestFlipbookDuration = 0

  if legacy_isFlipbook then
    table.sort(decals, function(a, b)
      local x = a.Name:match("%d+") or 0
      local y = b.Name:match("%d+") or 0

      return tonumber(x) < tonumber(y)
    end)

    local displayDecal = Instance.new("Decal")
    displayDecal.Parent = realObj

    lifetime.hold(scope, displayDecal)

    if legacy_flipbookFadeOffset > 0 then
      if legacy_decalST ~= legacy_decalET then
        lifetime.hold(
          scope,
          tween.fromParams(utility.default_bezier, duration + legacy_flipbookFadeOffset, function(alpha, deltaTime)
            displayDecal.Transparency = utility.lerp(legacy_decalST, legacy_decalET, alpha)
            return deltaTime
          end)
        )
      end
    end

    lifetime.hold(
      scope,
      tween.fromParams(utility.default_bezier, duration, function(alpha, deltaTime)
        local index = math.max(math.round(#decals * alpha), 1)
        local target = decals[index]

        displayDecal.Texture = target.Texture

        displayDecal.Color3 = target.Color3
        displayDecal.ZIndex = target.ZIndex

        if legacy_flipbookFadeOffset == 0 then
          displayDecal.Transparency = utility.lerp(legacy_decalST, legacy_decalET, alpha)
          displayDecal.ZIndex = target.ZIndex
        end

        return deltaTime
      end)
    )
  else
    for _, decal in decals do
      local from = decal
      local to = fromToMap[from]

      -- this knob is authored on the DECAL rather than on ref: ownership is
      -- keyed to the instance dispatch routes to, and the decal is dispatched
      -- on its own through emitNested
      local decalTp = mods.track(from, "attribute", "Transparency", mods.ramp(legacy_decalST, legacy_decalET), duration)

      decal.Transparency = decalTp.at(0)

      if decalTp.animated then
        lifetime.hold(
          scope,
          tween.fromParams(utility.linear_bezier, decalTp.span, function(_, deltaTime, elapsed)
            decal.Transparency = decalTp.at(elapsed)
            return deltaTime
          end)
        )
      end

      if from.Color3 ~= to.Color3 then
        lifetime.hold(
          scope,
          tween.fromParams(attr.get(from, "Color_Curve", utility.default_bezier), duration, function(alpha, deltaTime)
            local a = Oklab.fromSRGB(from.Color3)
            local b = Oklab.fromSRGB(to.Color3)

            decal.Color3 = Oklab.toSRGB(a:Lerp(b, alpha), true)

            return deltaTime
          end)
        )
      end

      local flipbook = flipbooks[from]

      if flipbook then
        local config = {
          ref = from,
          frames = flipbook,
          effectDuration = duration,
          syncDuration = attr.get(from, "SyncDuration", false, true) == true,

          curve = attr.get(from, "Flipbook_Change_Curve", utility.linear_bezier),
          duration = attr.get(from, "Flipbook_Change_Duration", duration),

          setTexture = function(texture)
            decal.Texture = texture
          end,
        }

        local changeDuration = flipbook_common.getChangeDuration(config)

        if changeDuration > longestFlipbookDuration then
          longestFlipbookDuration = changeDuration
        end

        lifetime.hold(
          scope,
          tween.fromParams(config.curve, changeDuration, flipbook_common.createUpdateCallback(config))
        )
      end
    end
  end

  tween.timer(
    math.max(duration, longestFlipbookDuration) + legacy_flipbookFadeOffset + destroyDelay,
    function(deltaTime)
      return if scope.clock.halted then nil else deltaTime
    end,
    nil,
    scope
  )

  lifetime.awaitJoin(children)

  scope.effects.emitOnFinish(emitOnFinish, realObj, scope.depth + 1, scope, children)
  lifetime.awaitJoin(children)
end

function mesh.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: Model
  local scope = ctx.scope

  local start = ref:FindFirstChild("Start")
  local goal = ref:FindFirstChild("End")

  if not start or not goal or not start:IsA("BasePart") or not goal:IsA("BasePart") or not part_cache then
    return
  end

  -- a plain emit of an enabled model switches it off; the tick's own emits
  -- leave it as it is
  if attrs.Enabled and not ctx.constant then
    attr.set(ref, "Enabled", false)
  end

  lifetime.wait(scope, attrs.EmitDelay)

  if attrs.EmitDuration > 0 and not ctx.constant then
    enabled_effects.window(ctx, mesh, attrs.EmitDuration)
    return
  end

  local range = attrs.EffectDuration

  -- every piece runs on the effect's clock, so one Speed track paces them all
  utility.speedFrom(scope, ref, attrs.Speed)

  -- each piece runs on a thread the effect holds, so a clear closes it
  local outstanding = lifetime.join(scope)

  for _ = 1, attrs.EmitCount do
    local duration = rng:NextNumber(range.Min, range.Max)

    lifetime.spawn(outstanding, function()
      piece(ctx, attrs, utility.assembleMeshVFX(start, scope, part_cache), duration)
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
