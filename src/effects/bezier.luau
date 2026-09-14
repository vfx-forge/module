--!nolint LocalShadow
local RunService = game:GetService("RunService")

local attr = require("@mod/attributes")
local knob = require("@mod/knob")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local bezier_common = require("@mod/common/bezier")

local Bezier = require("@obj/Bezier")
local Promise = require("@pkg/Promise")
local ObjectCache = require("@obj/ObjectCache")

local bezier = {}

bezier.id = "bezier"
bezier.display = { name = "Bezier", icon = "bezier", order = 110 }
bezier.classifier = "Attachment.BezierParticle"

-- the template part, the points and the end attachments under the bolt are
-- its own; the effects nested in the template part run per emitted piece
bezier.components = "Instance"
bezier.constant = true

bezier.attributes = bezier_common.rows()

bezier.attributes.FacePath =
  knob(false):label("FacePath"):hint("Whether the part orients along its direction of travel.")
bezier.attributes.ArcSpace = knob(false):label("ArcSpace"):hint("Whether progress is measured by arc length.")
bezier.attributes.MinInitRot =
  knob(vector.zero):label("Min"):hint("Lower per-axis bound for each path's initial rotation.")
bezier.attributes.MaxInitRot =
  knob(vector.zero):label("Max"):hint("Upper per-axis bound for each path's initial rotation.")
bezier.attributes.EasingCurve = knob(function()
    return utility.linear_bezier
  end)
  :aliases("Easing_Curve")
  :label("Easing")
  :hint("Easing of travel along the path.")
bezier.attributes.RotSpeed =
  knob(0):unit("perSecond"):mod():label("Speed"):hint("Rotation speed drawn for each piece, in degrees per second.")

bezier.properties = {}

bezier.layout = bezier_common.layout()

-- the rotation rows sit between the shared end point and the projectile phase
table.insert(bezier.layout, 5, {
  title = "Random Rotation",
  entries = { { title = "Speed", entries = { "RotSpeed" } }, "MinInitRot", "MaxInitRot" },
})
table.insert(bezier.layout, { title = "Animation", entries = { "FacePath", "ArcSpace", "EasingCurve" } })
table.insert(bezier.layout, {
  title = "Behavior",
  entries = {
    { action = "edit_path", label = "Edit Bezier" },
    { action = "toggle_paths", label = "Show Paths" },
    { action = "toggle_constant", label = "Add Enabled Tag" },
  },
})

-- the longest a bolt of this emit can run, which the emit's own queues run over
function bezier.duration(_, attrs: any)
  return attrs.Duration.Max
end

local part_cache: ObjectCache.ObjectCache?

function bezier.init(cache)
  part_cache = cache
end

function bezier.deinit()
  part_cache = nil
end

function bezier.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: Attachment
  local scope = ctx.scope
  local root = ref:FindFirstChild("Points")
  local template = ref:FindFirstChildOfClass("Part")

  if not root or not root:IsA("Attachment") or not part_cache or not template then
    return
  end

  -- a plain emit of an enabled bolt switches it off; the tick's own emits
  -- leave it as it is
  if attrs.Enabled and not ctx.constant then
    ref:SetAttribute("Enabled", false)
  end

  local refObj = template:Clone()
  refObj.Locked = true

  lifetime.hold(scope, refObj)

  local drawFunc = bezier_common.drawFuncMap[attrs.Shape] and bezier_common.drawFuncMap[attrs.Shape][attrs.ShapeStyle]

  if not drawFunc then
    return
  end

  local useDuration = attrs.EmitDuration > 0

  task.wait(attrs.EmitDelay)

  if useDuration and not ctx.constant then
    utility.forceEmit(ref, true)
    attr.trigger(ref, "Enabled", true)

    utility.onCancel(scope, function()
      local token = utility.stopEmitDuration(ref)

      if token then
        utility.cancelToken(token)
      end
    end)

    local speed = attrs.Speed

    if speed.animated then
      attr.setState(ref, "SpeedTweening", true)

      lifetime.hold(
        scope,
        tween.fromParams(
          utility.linear_bezier,
          speed.duration,
          function(_, deltaTime, elapsed)
            attr.setState(ref, "SpeedOverride", speed.at(elapsed))
            return deltaTime
          end,
          nil,
          function()
            attr.setState(ref, "SpeedTweening", nil)
          end
        )
      )
    end

    task.wait(attrs.EmitDuration)

    utility.awaitEmitDuration(utility.stopEmitDuration(ref))

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

  local rng = Random.new()
  local baseBezier = not endPoint and Bezier.new(points)

  -- Hitbox params
  local hitboxParams = bezier_common.createHitboxParams(bezier_common.hitboxOf(attrs), parent, root)

  local promises = {}
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

    table.insert(
      promises,
      Promise.new(function(resolve)
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
        local pathBezier = baseBezier or bezier_common.createBezierWithEndpoint(points, cf, endPoint, endT1)
        local getPos = bezier_common.createPosGetter(pathBezier, points, cf, endPoint, attrs.ArcSpace)

        -- get part from cache
        local cacheId = utility.getRandomId()

        if not part_cache then
          resolve()
          return
        end

        local objAbstr = part_cache:get(cacheId)
        objAbstr.CFrame = CFrame.new(getPos(0))

        local obj = objAbstr._getReal()

        utility.copyProperties(refObj, obj, utility.COPY_PART_PROPERTIES)
        utility.copyProperties(refObj, obj, utility.COPY_EXTENDED_PART_PROPERTIES)

        -- clone children from reference
        do
          local clone = refObj:Clone()
          for _, child in clone:GetChildren() do
            child.Parent = obj
          end
          clone:Destroy()
        end

        local emitOnFinish = scope.effects.prepareEmitOnFinish(obj, scope)
        local env = scope.effects.emitNested(obj, scope.depth + 1, scope)

        table.insert(promises, env.Finished)

        lifetime.hold(scope, function()
          if part_cache then
            part_cache:free(cacheId)
          end
        end)

        -- animation state
        local lastPos = Vector3.zero
        local lastVelocity = Vector3.zero

        local didHit = false
        local finished = false

        local prevCF = CFrame.identity
        local currentSpeed = 1

        local currentRot = CFrame.fromOrientation(initRot.x, initRot.y, initRot.z)
        local currentRotSpeed = rotSpeedStart

        local function onFinish()
          if finished then
            return
          end

          if attrs.SyncPosition then
            local initOrigin = utility.getTransformedOriginExtents(parent)
            local initPartPos = objAbstr.CFrame

            local function updatePos()
              objAbstr.CFrame = utility.getTransformedOriginExtents(parent) * initOrigin:ToObjectSpace(initPartPos)
            end

            local id = utility.getRandomId()

            RunService:BindToRenderStep(id, utility.RENDER_PRIORITY + scope.depth, updatePos)

            lifetime.hold(scope, function()
              RunService:UnbindFromRenderStep(id)
            end)
          end

          finished = true

          local finishEnv = scope.effects.emitOnFinish(emitOnFinish, obj, scope.depth + 1, scope)
          finishEnv.Finished:finally(function()
            resolve()
          end)
        end

        local function shapecast()
          if not attrs.HitboxEnabled then
            return false
          end

          local result = workspace:GetPartsInPart(obj, hitboxParams)
          return result[1] ~= nil
        end

        -- Speed tween
        local speedTween
        local speed = attrs.Speed(nil, duration)

        if not attr.getState(ref, "SpeedOverride", nil) then
          currentSpeed = speed.at(0)

          if speed.animated then
            speedTween = tween.fromParams(utility.linear_bezier, speed.duration, function(_, deltaTime, sampledAt)
              currentSpeed = speed.at(sampledAt)
              return deltaTime
            end)

            lifetime.hold(scope, speedTween)
          end
        end

        local function getEffectiveSpeed()
          return attr.getState(ref, "SpeedOverride", currentSpeed)
        end

        local function isSpeedTweening()
          return if speedTween then speedTween.Connected else attr.getState(ref, "SpeedTweening", false)
        end

        -- Rotation speed tween
        bezier_common.drivePropertyTrack(scope, rotSpeed, function(v)
          currentRotSpeed = v
        end, getEffectiveSpeed, speedTween)

        -- main animation
        lifetime.hold(
          scope,
          tween.fromParams(
            attrs.EasingCurve,
            duration,
            function(alpha, deltaTime, elapsed)
              local pos1 = getPos(alpha)
              local newCF = CFrame.new(pos1)

              if attrs.FacePath then
                local pos2 = getPos(math.clamp((elapsed + (1 / 60)) / duration, 0, 1))

                if pos1 ~= pos2 then
                  newCF = CFrame.lookAt(pos1, pos2)
                else
                  newCF *= prevCF.Rotation
                end
              end

              local add = initRot:Sign() * currentRotSpeed * utility.DEG_TO_RAD * deltaTime
              currentRot *= CFrame.fromOrientation(add.x, add.y, add.z)

              -- save current cframe before applying rotation
              prevCF = newCF
              newCF *= currentRot

              if attrs.SyncPosition then
                objAbstr.CFrame = utility.getTransformedOriginExtents(parent) * originCFrame:ToObjectSpace(newCF)
              else
                objAbstr.CFrame = newCF
              end

              lastVelocity = (pos1 - lastPos) / deltaTime
              lastPos = pos1

              if shapecast() then
                onFinish()
                didHit = true
                return nil
              end

              local speed = getEffectiveSpeed()
              currentSpeed = speed

              if speed == 0 and not isSpeedTweening() then
                return nil
              end

              if (attrs.ProjectileEnabled and alpha * duration < projectileLifetime) or not attrs.ProjectileEnabled then
                return deltaTime * speed
              else
                onFinish()
                return nil
              end
            end,
            speedTween,
            function(organic)
              if not attrs.ProjectileEnabled or didHit then
                if organic then
                  onFinish()
                end
                return
              end

              -- Projectile mode
              local dir = if attrs.MatchEndDirection and endPoint
                then endPoint.WorldCFrame.LookVector
                else lastVelocity.Unit

              if dir ~= dir then
                dir = Vector3.zero
              end

              lastVelocity = dir * attrs.ProjectileSpeed

              local projectileOrigin = obj.Position
              local originCFrameAtProjectileInit = utility.getTransformedOriginExtents(parent)

              tween.timer(projectileLifetime, function(deltaTime, elapsed)
                if attrs.SyncPosition then
                  objAbstr.CFrame = utility.getTransformedOriginExtents(parent)
                    * originCFrameAtProjectileInit:ToObjectSpace(CFrame.new(projectileOrigin + lastVelocity * elapsed))
                else
                  objAbstr.CFrame = CFrame.new(projectileOrigin + lastVelocity * elapsed) * obj.CFrame.Rotation
                end

                if shapecast() then
                  onFinish()
                  didHit = true
                  return nil
                end

                local speed = getEffectiveSpeed()
                currentSpeed = speed

                return if speed > 0 or (elapsed > 0 and isSpeedTweening()) then deltaTime * speed else nil
              end, speedTween, scope, utility.RENDER_PRIORITY + scope.depth)

              if not didHit then
                onFinish()
              end
            end,
            true, -- start at zero, important for facepath to work on short durations
            utility.RENDER_PRIORITY + scope.depth
          )
        )
      end)
    )
  end

  Promise.all(promises):await()

  task.wait(attrs.DestroyDelay)
end

return bezier
