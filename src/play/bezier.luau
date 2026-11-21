--!nolint LocalShadow
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local bezier_common = require("@mod/common/bezier")
local flight_common = require("@mod/common/flight")

local pool = require("@srv/pool")
local mover = require("@srv/mover")
local enabled_effects = require("@srv/enabled_effects")

local Bezier = require("@obj/Bezier")

-- studs a frame's look-ahead must span before FacePath turns the part along it
local FACE_GAP = 1e-3

local bezier: any = nil

local play = {}

function play.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: Attachment
  local scope = ctx.scope
  local root = ref:FindFirstChild("Points")
  local template = ref:FindFirstChildOfClass("Part")

  if not root or not root:IsA("Attachment") or not template then
    return
  end

  -- a plain emit of an enabled bolt switches it off; the tick's own emits
  -- leave it as it is
  if attrs.Enabled and not ctx.constant then
    enabled_effects.switch(ref, false)
  end

  local styled = attrs.ShapeStyle == "Volume" or attrs.ShapeStyle == "Surface"
  local drawFunc = if styled then bezier_common.SHAPES[attrs.Shape] else nil

  if not drawFunc then
    return
  end

  lifetime.wait(scope, attrs.EmitDelay)

  if attrs.EmitDuration > 0 and not ctx.constant then
    enabled_effects.window(ctx, bezier, attrs.EmitDuration, attrs.Speed)
    return
  end

  if attrs.EmitCount <= 0 then
    return
  end

  local parent = bezier_common.validateParent(ref)

  if not parent then
    return
  end

  local originCFrame, originSize = utility.getTransformedOriginExtents(parent)

  if not originCFrame then
    return
  end

  local endPoint, endT1 = bezier_common.findEndAttachments(ref)
  local points = utility.getBezierPoints(root)

  -- a Points attachment with nothing under it has no path to follow
  if #points < 2 then
    return
  end

  local rng = Random.new()
  local baseBezier = not endPoint and Bezier.new(points)

  -- Hitbox params
  local hitboxParams = bezier_common.createHitboxParams(bezier_common.hitboxOf(attrs), parent, root)

  -- every piece runs on the effect's clock, so one Speed track paces them all
  utility.speedFrom(scope, ctx.constant, attrs.Speed)

  -- a piece counts until it finishes and its on-finish emit is counted in, and
  -- a nested emit until it ends
  local outstanding = lifetime.join(scope)
  local emission = bezier_common.emissionOf(attrs)

  for _ = 1, attrs.EmitCount do
    local initRot = vector.create(
      rng:NextNumber(attrs.MinInitRot.x, attrs.MaxInitRot.x),
      rng:NextNumber(attrs.MinInitRot.y, attrs.MaxInitRot.y),
      rng:NextNumber(attrs.MinInitRot.z, attrs.MaxInitRot.z)
    )

    local duration = rng:NextNumber(attrs.Duration.Min, attrs.Duration.Max)
    local projectileLifetime = attrs.ProjectileEnabled
      and rng:NextNumber(attrs.ProjectileLifetime.Min, attrs.ProjectileLifetime.Max)

    -- one track per emitted part rather than one per emit, because the two
    -- endpoints are drawn per part and a sampler is what draws them
    local rotSpeed = attrs.RotSpeed(nil, duration)
    local rotSpeedStart = rotSpeed.at(0)

    local landed = lifetime.add(outstanding)

    -- a piece that throws is logged and counted out, and the pieces beside it
    -- keep running
    local ok = utility.try(`failed to emit a bezier piece with error: %s`, function()
      -- Calculate emission CFrame
      local cf = bezier_common.calculateEmissionCFrame(
        originCFrame,
        originSize,
        emission,
        drawFunc,
        rng,
        endPoint,
        parent:IsA("Attachment")
      )

      -- create bezier
      local pathBezier = baseBezier or bezier_common.endpointPath(points, cf, endPoint, endT1)
      local getPos = bezier_common.createPosGetter(pathBezier, points, cf, endPoint, attrs.ArcSpace)

      local obj = pool.take(scope, template) :: BasePart

      obj.CFrame = CFrame.new(getPos(0))

      local emitOnFinish = scope.effects.prepareEmitOnFinish(obj, scope)

      scope.effects.emitNested(obj, scope.depth + 1, scope, outstanding)

      -- animation state
      local lastPos = Vector3.zero
      local lastVelocity = Vector3.zero

      local didHit = false
      local finished = false

      local prevCF = CFrame.identity

      local currentRot = CFrame.fromOrientation(initRot.x, initRot.y, initRot.z)
      local currentRotSpeed = rotSpeedStart

      local function onFinish()
        if finished then
          return
        end

        if attrs.SyncPosition then
          local initOrigin = utility.getTransformedOriginExtents(parent)
          local initPartPos = mover.cframe(obj)

          lifetime.step(scope, function()
            mover.move(scope, obj, utility.getTransformedOriginExtents(parent) * initOrigin:ToObjectSpace(initPartPos))
          end, "follow")
        end

        finished = true

        scope.effects.emitOnFinish(emitOnFinish, obj, scope.depth + 1, scope, outstanding)
        landed()
      end

      local function shapecast()
        if not attrs.HitboxEnabled then
          return false
        end

        return flight_common.hit(hitboxParams, obj)
      end

      tween.drive(scope, rotSpeed, function(v: number)
        currentRotSpeed = v
      end)

      local path = curve.new(duration, attrs.EasingCurve)

      tween.play(
        scope,
        path,
        function(alpha: number, deltaTime: number, elapsed: number)
          local pos1 = getPos(alpha)
          local newCF = CFrame.new(pos1)

          if attrs.FacePath then
            -- the point a frame ahead on the same eased clock the part moves
            -- on. It once read the linear clock, which under an ease-out sits
            -- BEHIND the part, and near the end both crowd onto the end point:
            -- a look along a gap of float noise, the part spinning as it lands.
            -- Too short a gap keeps the last good facing
            local pos2 = getPos(path:at(math.clamp((elapsed + (1 / 60)) / path.duration, 0, 1)))

            if (pos2 - pos1).Magnitude > FACE_GAP then
              newCF = CFrame.lookAt(pos1, pos2)
            else
              newCF *= prevCF.Rotation
            end
          end

          local add = vector.sign(initRot) * currentRotSpeed * utility.DEG_TO_RAD * deltaTime
          currentRot *= CFrame.fromOrientation(add.x, add.y, add.z)

          -- save current cframe before applying rotation
          prevCF = newCF
          newCF *= currentRot

          if attrs.SyncPosition then
            mover.move(scope, obj, utility.getTransformedOriginExtents(parent) * originCFrame:ToObjectSpace(newCF))
          else
            mover.move(scope, obj, newCF)
          end

          if deltaTime > 0 then
            lastVelocity = (pos1 - lastPos) / deltaTime
          end

          lastPos = pos1

          if shapecast() then
            onFinish()
            didHit = true
            return false
          end

          if (attrs.ProjectileEnabled and alpha * duration < projectileLifetime) or not attrs.ProjectileEnabled then
            return true
          end

          onFinish()

          return false
        end,
        scope.depth,
        function()
          if not attrs.ProjectileEnabled or didHit then
            onFinish()
            return
          end

          -- Projectile mode
          local dir = if attrs.MatchEndDirection and endPoint
            then endPoint.WorldCFrame.LookVector
            else lastVelocity.Unit

          if dir ~= dir then
            dir = Vector3.zero
          end

          const function follow()
            return (utility.getTransformedOriginExtents(parent))
          end

          flight_common.projectile(scope, obj, dir * attrs.ProjectileSpeed, projectileLifetime, {
            params = if attrs.HitboxEnabled then hitboxParams else nil,
            follow = if attrs.SyncPosition then follow else nil,
          }, onFinish)
        end
      )
    end)

    if not ok then
      landed()
    end
  end

  lifetime.awaitJoin(outstanding)

  -- on the effect's clock, and over once it halts, since a halted clock never
  -- moves again
  if attrs.DestroyDelay > 0 then
    tween.wait(scope, curve.new(attrs.DestroyDelay, "linear"))
  end
end

function play.bind(module: any)
  bezier = module

  return play
end

return play
