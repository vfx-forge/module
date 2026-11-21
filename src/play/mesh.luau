--!nolint LocalShadow
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local look_common = require("@mod/common/look")

local pool = require("@srv/pool")
local mover = require("@srv/mover")
local frame_store = require("@srv/frame_store")
local enabled_effects = require("@srv/enabled_effects")

local rng = Random.new()

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

  -- a piece is a look and never a body, whatever its Start was left as: it
  -- neither collides nor weighs on what it is welded to
  obj.CanCollide = false
  obj.Massless = true

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

local mesh: any = nil

local play = {}

function play.emit(ctx: reader.Ctx, attrs: any)
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

function play.bind(module: any)
  mesh = module

  return play
end

return play
