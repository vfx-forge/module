local CollectionService = game:GetService("CollectionService")

local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local logger = require("@mod/logger")
local utility = require("@mod/utility")

local Bezier = require("@obj/Bezier")
local Promise = require("@pkg/Promise")
local ObjectCache = require("@obj/ObjectCache")

local rng = Random.new()

local line = {}

-- all three are driven here, so the applier must not drive them as well.
-- Lifetime and Size especially: their legacy attributes are a NumberRange and a
-- Min/Max pair, and an applier writing a sample back would replace the range
-- with a scalar
line.OWNS = {
  attribute = {
    Size = true,
    Speed = true,
    Lifetime = true,
  },
}

local part_cache: ObjectCache.ObjectCache?

function line.init(cache)
  part_cache = cache
end

function line.deinit()
  part_cache = nil
end

function line.emit(origin: Attachment, ref: Part, scope: types.scope)
  if not part_cache then
    return
  end

  local raydir = attr.get(origin, "RayDirection", vector.create(0, -50, 0))

  local rayColGroup = attr.get(origin, "RayCollisionGroup", "Default")
  local rayFilterTag = attr.get(origin, "FilterTag", "")
  local rayFilterType = attr.get(origin, "FilterType", "Exclude")

  local rayIgnoreWater = attr.get(origin, "IgnoreWater", true)
  local rayIgnoreCanCollide = attr.get(origin, "IgnoreCanCollide", false)

  local params = RaycastParams.new()
  params.CollisionGroup = rayColGroup
  params.IgnoreWater = rayIgnoreWater
  params.RespectCanCollide = not rayIgnoreCanCollide
  params.FilterType = Enum.RaycastFilterType[rayFilterType]
  params.FilterDescendantsInstances = CollectionService:GetTagged(rayFilterTag)

  if rayFilterType == "Exclude" then
    params:AddToFilter({ workspace.Terrain })
  end

  local emitDelay = attr.get(ref, "EmitDelay", 0)

  local rateStart = attr.get(ref, "Rate_Start", 30)
  local rateEnd = attr.get(ref, "Rate_End", 30)

  local fixedAmount = attr.get(ref, "FixedAmount", 0)

  local scaleStart = attr.get(ref, "Scale_Start", 1)
  local scaleEnd = attr.get(ref, "Scale_End", 1)

  local duration = attr.get(ref, "Duration", 1)
  local direction = attr.get(ref, "Direction", vector.create(0, 0, -1))
  local lineLength = attr.get(ref, "Length", 50)

  local rot = attr.getRange(ref, "Rotation", NumberRange.new(-180, 180))

  local old_partOffset = attr.get(ref, "PartOffset", vector.zero, true)

  local baseOffset = attr.get(ref, "BaseOffset", old_partOffset)
  local offsetStart = attr.get(ref, "Offset_Start", old_partOffset)
  local offsetEnd = attr.get(ref, "Offset_End", old_partOffset)

  local offsetStartDuration = attr.get(ref, "Offset_Start_Duration", 0.5)
  local offsetEndDuration = attr.get(ref, "Offset_End_Duration", 0.5)

  local lifetime = attr.getRange(ref, "Lifetime", NumberRange.new(2, 3), NumberRange.new(0, math.huge))

  local sizeScaleStart = attr.get(ref, "SizeScaleStart", vector.zero)
  local sizeScaleEnd = attr.get(ref, "SizeScaleEnd", vector.zero)

  local minSize = attr.get(ref, "MinSize", vector.create(2, 1, 2))
  local maxSize = attr.get(ref, "MaxSize", vector.create(3, 2, 3))

  local old_sizeCurve = attr.get(ref, "Size_Curve", utility.default_bezier, true)
  local old_sizeDuration = attr.get(ref, "Size_Duration", 0.5, true)

  local sizeStartCurve = attr.get(ref, "Size_Start_Curve", old_sizeCurve)
  local sizeEndCurve = attr.get(ref, "Size_End_Curve", old_sizeCurve)

  local sizeStartDuration = attr.get(ref, "Size_Start_Duration", old_sizeDuration)
  local sizeEndDuration = attr.get(ref, "Size_End_Duration", old_sizeDuration)

  local tpDuration = attr.get(ref, "Transparency_Duration", 0.5)

  local tpStart = attr.get(ref, "Transparency_Start", 0)
  local tpEnd = attr.get(ref, "Transparency_End", 0)

  -- the longest a piece emitted at the very end can last: the whole emission,
  -- then the longest dwell it can draw, then the longest exit it can run
  local runLength = duration + lifetime.Max + math.max(sizeEndDuration, offsetEndDuration, tpDuration)

  -- asked for BEFORE any non-soft read of the quad keys it would find, because
  -- attr.get writes its default back. the fallback is the line's own run rather
  -- than Speed_Duration: it is only reached when no modifier names a duration,
  -- which is what the panel calls linked, and linked means "as long as the
  -- effect runs"
  local speedDrv, speedSpan = mods.driver(ref, "attribute", "Speed", runLength)

  local speedStart = attr.get(ref, "Speed_Start", 1, true)
  local speedEnd = attr.get(ref, "Speed_End", 1, true)

  local currentSpeed = if speedDrv then speedDrv(0) else speedStart

  local function getEffectiveSpeed(): number
    return currentSpeed
  end

  local sync = attr.get(ref, "SyncPosition", false)

  duration = math.max(duration, 0.001)

  if fixedAmount > 0 then
    local rate = fixedAmount / duration

    rateStart = rate
    rateEnd = rate
  end

  direction = direction.Unit

  if direction ~= direction then
    direction = -Vector3.zAxis
  end

  task.wait(emitDelay)

  local promises = {}

  local start = utility.getTransformedOriginExtents(origin)

  local last = 0
  local total = 0

  local currentRate = rateStart
  local currentScale = scaleStart

  -- the speed tween is the clock itself, so it is the one stepper that does not
  -- scale by it
  if speedDrv then
    table.insert(
      scope,
      tween.fromParams(utility.linear_bezier, speedSpan, function(_, deltaTime, elapsed)
        currentSpeed = speedDrv(elapsed)
        return deltaTime
      end)
    )
  elseif speedStart ~= speedEnd then
    table.insert(
      scope,
      tween.fromParams(
        attr.get(ref, "Speed_Curve", utility.default_bezier),
        attr.get(ref, "Speed_Duration", 0.1),
        function(alpha, deltaTime)
          currentSpeed = utility.lerp(speedStart, speedEnd, alpha)
          return deltaTime
        end
      )
    )
  end

  if scaleStart ~= scaleEnd then
    table.insert(
      scope,
      tween.fromParams(attr.get(ref, "Scale_Curve", utility.default_bezier), duration, function(alpha, deltaTime)
        currentScale = utility.lerp(scaleStart, scaleEnd, alpha)
        return deltaTime * getEffectiveSpeed()
      end)
    )
  end

  if rateStart ~= rateEnd then
    table.insert(
      scope,
      tween.fromParams(attr.get(ref, "Rate_Curve", utility.default_bezier), duration, function(alpha, deltaTime)
        currentRate = utility.lerp(rateStart, rateEnd, alpha)
        return deltaTime * getEffectiveSpeed()
      end)
    )
  end

  local pathCurve = attr.get(ref, "Path_Curve", utility.linear_bezier)

  local ok, points = pcall(function()
    return utility.deserializePath(pathCurve)
  end)

  if not ok then
    logger.error(`failed to decode bezier path data with error: {points}`)
  end

  local bezier = Bezier.new(points, 0)

  table.insert(
    scope,
    tween.fromParams(utility.linear_bezier, duration, function(_, deltaTime)
      -- the emission runs on the effect's clock too, so a speed knob spaces the
      -- pieces out and shortens the line's run by the same factor
      deltaTime *= getEffectiveSpeed()

      last += deltaTime

      local threshold = 1 / currentRate
      local max = duration * currentRate

      if last < threshold or total >= max then
        return deltaTime
      end

      local ticks = last // threshold

      for i = 1, ticks do
        if total >= max then
          continue
        end

        total += 1

        local t = math.clamp(total / max, 0, 1)
        local alpha = 1 - bezier:getEase(t).y

        if sync then
          start = utility.getTransformedOriginExtents(origin)
        end

        local originCFrame = utility.getTransformedOriginExtents(origin)
        local result = workspace:Raycast(
          start.Position + start:VectorToWorldSpace(direction) * lineLength * alpha,
          originCFrame:VectorToWorldSpace(raydir),
          params
        )

        if not result then
          last = 0
          return deltaTime
        end

        -- per emitted PIECE, like the lifetime below: a size is drawn per
        -- instance, and one driver for the line would cut every piece to the
        -- same measurements. legacy_mods reads the MinSize and MaxSize pair as
        -- a randomizer, and a randomizer between two Vector3s draws once per
        -- component, which is exactly the three NextNumber calls this replaces
        local sizeDrv = mods.driver(ref, "attribute", "Size", runLength)
        local drawnSize = if sizeDrv then sizeDrv(0) else nil

        if typeof(drawnSize) ~= "Vector3" then
          drawnSize = Vector3.new(
            rng:NextNumber(minSize.X, maxSize.X),
            rng:NextNumber(minSize.Y, maxSize.Y),
            rng:NextNumber(minSize.Z, maxSize.Z)
          )
        end

        local id = utility.getRandomId()

        local part = part_cache:get(id)

        local realPart = part._getReal()

        utility.copyProperties(ref, realPart, utility.COPY_PART_PROPERTIES)
        utility.copyProperties(ref, realPart, utility.COPY_EXTENDED_PART_PROPERTIES)

        if #ref:GetChildren() ~= 0 then
          local clone = ref:Clone()

          for _, child in clone:GetChildren() do
            child.Parent = realPart
          end

          clone:Destroy()
        end

        local emitOnFinish = scope.effects.prepareEmitOnFinish(realPart, scope)

        table.insert(scope, function()
          if part_cache then
            part_cache:free(id)
          end
        end)

        part.Color = result.Instance.Color
        part.Material = result.Material
        part.Transparency = result.Instance.Transparency

        if part.Transparency == 0 then
          part.Transparency = tpStart
        end

        part.Size = Vector3.zero

        local angle = rng:NextNumber(rot.Min, rot.Max)

        local rx = -math.cos(angle)
        local rz = -math.sin(angle)

        local dir = originCFrame:VectorToWorldSpace(Vector3.new(rx, 0, rz))
        local right = dir:Cross(result.Normal).Unit

        local rotCF = CFrame.fromMatrix(result.Position, right, result.Normal)
          * CFrame.fromOrientation(-math.atan(drawnSize.Y / drawnSize.Z), 0, 0)

        part.CFrame = CFrame.new(offsetStart) * rotCF

        local sizeTween
        local offsetTween

        local currentOffset = Vector3.zero

        if offsetStart ~= baseOffset then
          offsetTween = tween.fromParams(
            attr.get(ref, "Offset_Start_Curve", utility.default_bezier),
            offsetStartDuration,
            function(alpha, deltaTime)
              currentOffset = offsetStart:Lerp(baseOffset, alpha)
              part.CFrame = CFrame.new(currentOffset) * rotCF
              return deltaTime * getEffectiveSpeed()
            end
          )

          table.insert(scope, offsetTween)
        end

        local size = drawnSize * currentScale

        if size * sizeScaleStart ~= size then
          sizeTween = tween.fromParams(sizeStartCurve, sizeStartDuration, function(alpha, deltaTime)
            part.Size = (size * sizeScaleStart):Lerp(size, alpha)
            return deltaTime * getEffectiveSpeed()
          end)

          table.insert(scope, sizeTween)
        else
          part.Size = size * sizeScaleStart
        end

        local env = scope.effects.emitNested(realPart, scope.depth + 1, scope)
        table.insert(promises, env.Finished)

        -- legacy_mods reads the Lifetime NumberRange as a randomizer, so this
        -- covers authored and unauthored alike and the manual draw is only left
        -- for a line carrying no Lifetime attribute at all
        local lifeDrv = mods.driver(ref, "attribute", "Lifetime", 0)
        local drawn = if lifeDrv then lifeDrv(0) else rng:NextNumber(lifetime.Min, lifetime.Max)

        -- the dwell belongs to the effect rather than to the scheduler: its
        -- cleanup lives in the scope, so tearing the line down cancels it rather
        -- than firing exit tweens at a pooled part the cache has handed on, and
        -- its length is the counter's to decide, so a Lifetime a modifier is
        -- moving moves a dwell that is already running
        tween.after(math.huge, function(deltaTime, elapsed)
          local target = if lifeDrv then lifeDrv(elapsed) else nil

          if typeof(target) ~= "number" then
            target = drawn
          end

          if elapsed >= target then
            return nil :: any
          end

          return deltaTime * getEffectiveSpeed()
        end, function()
          task.spawn(function()
            if sizeTween then
              sizeTween:Disconnect()
            end

            if offsetTween then
              offsetTween:Disconnect()
            end

            local startSize = part.Size
            local startTp = part.Transparency

            if startSize ~= size * sizeScaleEnd then
              table.insert(
                scope,
                tween.fromParams(sizeEndCurve, sizeEndDuration, function(alpha, deltaTime)
                  part.Size = startSize:Lerp(size * sizeScaleEnd, alpha)
                  return deltaTime * getEffectiveSpeed()
                end)
              )
            end

            if currentOffset ~= offsetEnd then
              table.insert(
                scope,
                tween.fromParams(
                  attr.get(ref, "Offset_End_Curve", utility.default_bezier),
                  offsetEndDuration,
                  function(alpha, deltaTime)
                    part.CFrame = CFrame.new(currentOffset:Lerp(offsetEnd, alpha)) * rotCF
                    return deltaTime * getEffectiveSpeed()
                  end
                )
              )
            end

            if startTp ~= tpEnd then
              table.insert(
                scope,
                tween.fromParams(
                  attr.get(ref, "Transparency_Curve", utility.default_bezier),
                  tpDuration,
                  function(alpha, deltaTime)
                    part.Transparency = utility.lerp(startTp, tpEnd, alpha)
                    return deltaTime * getEffectiveSpeed()
                  end
                )
              )
            end

            local env = scope.effects.emitOnFinish(emitOnFinish, realPart, scope.depth + 1, scope)
            table.insert(promises, env.Finished)
          end)
        end, scope)
      end

      last %= threshold

      return deltaTime
    end, nil, nil, true, utility.RENDER_PRIORITY + scope.depth)
  )

  -- the hold runs on the clock the dwells do, or a speed below one stretches
  -- them past it and the scope tears down mid dwell. the transparency exit is
  -- one of the three a dwell starts, so it counts here too
  tween.timer(runLength, function(deltaTime)
    return deltaTime * getEffectiveSpeed()
  end, nil, scope)

  Promise.all(promises):await()
end

return line
