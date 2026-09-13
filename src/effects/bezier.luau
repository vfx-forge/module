--!nolint LocalShadow
local RunService = game:GetService("RunService")

local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local bezier_common = require("@mod/common/bezier")

local Bezier = require("@obj/Bezier")
local Promise = require("@pkg/Promise")
local ObjectCache = require("@obj/ObjectCache")

local bezier = {}

-- both knobs are driven through samplers of their own, so emitters.applyMods
-- leaves them alone. RotSpeed's endpoints are NumberRanges this effect used to
-- draw a scalar from per emitted part; they read back as rand endpoints now and
-- the sampler makes the same two draws
bezier.OWNS = {
  attribute = {
    Speed = true,
    RotSpeed = true,
  },
}

local part_cache: ObjectCache.ObjectCache?

function bezier.init(cache)
  part_cache = cache
end

function bezier.deinit()
  part_cache = nil
end

local function readBezierAttributes(ref: Attachment)
  return {
    -- animation
    facePath = attr.get(ref, "FacePath", false),
    arcSpace = attr.get(ref, "ArcSpace", false),

    -- rotation. read soft so the defaults are not written back: this runs
    -- before any driver read, and a stamped RotSpeed_Start is a quad
    -- legacy_mods would then find that nobody authored
    rotSpeedStart = attr.getRange(ref, "RotSpeed_Start", NumberRange.new(0, 0), nil, true),
    rotSpeedEnd = attr.getRange(ref, "RotSpeed_End", NumberRange.new(0, 0), nil, true),
    minInitRot = attr.get(ref, "MinInitRot", vector.zero),
    maxInitRot = attr.get(ref, "MaxInitRot", vector.zero),

    -- curves
    speedCurve = attr.get(ref, "Speed_Curve", utility.default_bezier),
    speedDuration = attr.get(ref, "Speed_Duration", 0.1),
    easingCurve = attr.get(ref, "Easing_Curve", utility.linear_bezier),
  }
end

function bezier.emit(ref: Attachment, refObj: Part, scope: types.scope, mustEmit: boolean?)
  local root = ref:FindFirstChild("Points")

  if not root or not root:IsA("Attachment") or not part_cache then
    return
  end

  local common = bezier_common.readCommonAttributes(ref)
  local attrs = readBezierAttributes(ref)

  local drawFunc = bezier_common.drawFuncMap[common.shapeType]
    and bezier_common.drawFuncMap[common.shapeType][common.shapeStyle]

  if not drawFunc then
    return
  end

  local useDuration = common.emitDuration > 0

  task.wait(common.emitDelay)

  if useDuration and not mustEmit then
    utility.forceEmit(ref, true)
    attr.trigger(ref, "Enabled", true)

    utility.onCancel(scope, function()
      local token = utility.stopEmitDuration(ref)

      if token then
        utility.cancelToken(token)
      end
    end)

    if common.speedStart ~= common.speedEnd then
      attr.setState(ref, "SpeedTweening", true)

      lifetime.hold(
        scope,
        tween.fromParams(
          attrs.speedCurve,
          attrs.speedDuration,
          function(alpha, deltaTime)
            attr.setState(ref, "SpeedOverride", utility.lerp(common.speedStart, common.speedEnd, alpha))
            return deltaTime
          end,
          nil,
          function()
            attr.setState(ref, "SpeedTweening", nil)
          end
        )
      )
    end

    task.wait(common.emitDuration)

    utility.awaitEmitDuration(utility.stopEmitDuration(ref))

    return
  end

  if common.emitCount <= 0 then
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
  local hitboxParams = bezier_common.createHitboxParams({
    enabled = common.hitboxEnabled,
    collisionGroup = common.hitboxCollisionGroup,
    filterTag = common.hitboxFilterTag,
    filterType = common.hitboxFilterType,
    ignoreCanCollide = common.hitboxIgnoreCanCollide,
  }, parent, root)

  local promises = {}

  for _ = 1, common.emitCount do
    local initRot = vector.create(
      rng:NextNumber(attrs.minInitRot.x, attrs.maxInitRot.x),
      rng:NextNumber(attrs.minInitRot.y, attrs.maxInitRot.y),
      rng:NextNumber(attrs.minInitRot.z, attrs.maxInitRot.z)
    )

    local duration = rng:NextNumber(common.duration.Min, common.duration.Max)
    local projectileLifetime = common.projectileEnabled
      and rng:NextNumber(common.projectileLifetime.Min, common.projectileLifetime.Max)

    -- one driver per emitted part rather than one per emit, because the two
    -- endpoints are drawn per part and a sampler is what draws them. the legacy
    -- pair below is read only when nothing is authored, so the two paths never
    -- both draw
    local rotSpeed, rotSpeedSpan = mods.driver(ref, "attribute", "RotSpeed", duration)

    local rotSpeedStart = 0
    local rotSpeedEnd = 0

    if rotSpeed then
      rotSpeedStart = rotSpeed(0)
    else
      rotSpeedStart = rng:NextNumber(attrs.rotSpeedStart.Min, attrs.rotSpeedStart.Max)
      rotSpeedEnd = rng:NextNumber(attrs.rotSpeedEnd.Min, attrs.rotSpeedEnd.Max)
    end

    table.insert(
      promises,
      Promise.new(function(resolve)
        -- Calculate emission CFrame
        local cf = bezier_common.calculateEmissionCFrame(originCFrame, originSize, {
          face = common.face,
          spreadAngle = common.spreadAngle,
          mirror = common.mirror,
          mirrorRot = common.mirrorRot,
          partial = common.partial,
          emissionDirection = common.emissionDirection,
        }, drawFunc, rng, endPoint, parent:IsA("Attachment"))

        -- create bezier
        local pathBezier = baseBezier or bezier_common.createBezierWithEndpoint(points, cf, endPoint, endT1)
        local getPos = bezier_common.createPosGetter(pathBezier, points, cf, endPoint, attrs.arcSpace)

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
        local currentSpeed = common.speedStart

        local currentRot = CFrame.fromOrientation(initRot.x, initRot.y, initRot.z)
        local currentRotSpeed = rotSpeedStart

        local function onFinish()
          if finished then
            return
          end

          if common.syncPosition then
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
          if not common.hitboxEnabled then
            return false
          end

          local result = workspace:GetPartsInPart(obj, hitboxParams)
          return result[1] ~= nil
        end

        -- Speed tween
        local speedTween
        local speed, speedSpan = mods.driver(ref, "attribute", "Speed", attrs.speedDuration)

        if speed and not attr.getState(ref, "SpeedOverride", nil) then
          currentSpeed = speed(0)

          speedTween = tween.fromParams(utility.linear_bezier, speedSpan, function(_, deltaTime, sampledAt)
            currentSpeed = speed(sampledAt)
            return deltaTime
          end)

          lifetime.hold(scope, speedTween)
        elseif common.speedStart ~= common.speedEnd and not attr.getState(ref, "SpeedOverride", nil) then
          speedTween = tween.fromParams(attrs.speedCurve, attrs.speedDuration, function(alpha, deltaTime)
            currentSpeed = utility.lerp(common.speedStart, common.speedEnd, alpha)
            return deltaTime
          end)

          lifetime.hold(scope, speedTween)
        end

        local function getEffectiveSpeed()
          return attr.getState(ref, "SpeedOverride", currentSpeed)
        end

        local function isSpeedTweening()
          return if speedTween then speedTween.Connected else attr.getState(ref, "SpeedTweening", false)
        end

        -- Rotation speed tween
        if rotSpeed then
          lifetime.hold(
            scope,
            tween.fromParams(utility.linear_bezier, rotSpeedSpan, function(_, deltaTime, elapsed)
              currentRotSpeed = rotSpeed(elapsed)
              return deltaTime * getEffectiveSpeed()
            end, speedTween)
          )
        else
          bezier_common.createPropertyTween(scope, ref, "RotSpeed", duration, rotSpeedStart, rotSpeedEnd, function(v)
            currentRotSpeed = v
          end, function()
            return getEffectiveSpeed()
          end, speedTween)
        end

        -- main animation
        lifetime.hold(
          scope,
          tween.fromParams(
            attrs.easingCurve,
            duration,
            function(alpha, deltaTime, elapsed)
              local pos1 = getPos(alpha)
              local newCF = CFrame.new(pos1)

              if attrs.facePath then
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

              if common.syncPosition then
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

              if
                (common.projectileEnabled and alpha * duration < projectileLifetime) or not common.projectileEnabled
              then
                return deltaTime * speed
              else
                onFinish()
                return nil
              end
            end,
            speedTween,
            function(organic)
              if not common.projectileEnabled or didHit then
                if organic then
                  onFinish()
                end
                return
              end

              -- Projectile mode
              local dir = if common.projectileMatchEnd and endPoint
                then endPoint.WorldCFrame.LookVector
                else lastVelocity.Unit

              if dir ~= dir then
                dir = Vector3.zero
              end

              lastVelocity = dir * common.projectileSpeed

              local projectileOrigin = obj.Position
              local originCFrameAtProjectileInit = utility.getTransformedOriginExtents(parent)

              tween.timer(projectileLifetime, function(deltaTime, elapsed)
                if common.syncPosition then
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

  task.wait(common.destroyDelay)
end

return bezier
