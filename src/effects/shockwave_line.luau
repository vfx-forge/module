local CollectionService = game:GetService("CollectionService")

local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local logger = require("@mod/logger")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local legacy_mods = require("@mod/legacy_mods")

local Bezier = require("@obj/Bezier")
local Promise = require("@pkg/Promise")
local ObjectCache = require("@obj/ObjectCache")

local rng = Random.new()

local line = {}

-- every one of these is driven here, so the applier must not drive them as
-- well. Lifetime and Size especially: their legacy attributes are a NumberRange
-- and a Min/Max pair, and an applier writing a sample back would replace the
-- range with a scalar
line.OWNS = {
  attribute = {
    Rate = true,
    Size = true,
    Scale = true,
    Speed = true,
    Lifetime = true,
    OffsetIn = true,
    SizeScaleIn = true,
    Transparency = true,
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

  local fixedAmount = attr.get(ref, "FixedAmount", 0)

  local duration = attr.get(ref, "Duration", 1)
  local direction = attr.get(ref, "Direction", vector.create(0, 0, -1))
  local lineLength = attr.get(ref, "Length", 50)

  local rot = attr.getRange(ref, "Rotation", NumberRange.new(-180, 180))

  local offsetOutEnd = legacy_mods.alias(ref, "OffsetOut_End", Vector3.zero)
  local offsetOutDuration = legacy_mods.alias(ref, "OffsetOut_Duration", 0.5)
  local offsetOutCurve = legacy_mods.alias(ref, "OffsetOut_Curve", utility.default_bezier)

  local lifeRange = attr.getRange(ref, "Lifetime", NumberRange.new(2, 3), NumberRange.new(0, math.huge))

  local sizeOutEnd = legacy_mods.alias(ref, "SizeScaleOut_End", Vector3.zero)
  local sizeOutDuration = legacy_mods.alias(ref, "SizeScaleOut_Duration", 0.5)
  local sizeOutCurve = legacy_mods.alias(ref, "SizeScaleOut_Curve", utility.default_bezier)

  local minSize = attr.get(ref, "MinSize", vector.create(2, 1, 2))
  local maxSize = attr.get(ref, "MaxSize", vector.create(3, 2, 3))

  local tpDuration = attr.get(ref, "Transparency_Duration", 0.5, true)

  -- the entry phases run over their own clocks, which are the durations the
  -- rows always carried, and rest where the old defaults left them: the offset
  -- where it stands, the size on a rise from nothing to the drawn size
  local offsetIn =
    mods.track(ref, "attribute", "OffsetIn", Vector3.zero, legacy_mods.alias(ref, "OffsetIn_Duration", 0.5))
  local sizeIn = mods.track(
    ref,
    "attribute",
    "SizeScaleIn",
    mods.ramp(Vector3.zero, Vector3.one),
    legacy_mods.alias(ref, "SizeScaleIn_Duration", 0.5)
  )

  -- the fade a piece runs after its dwell: from where the transparency rests to
  -- where it ends, over its own clock
  local transparency = mods.track(ref, "attribute", "Transparency", 0, tpDuration)

  local offsetInStart = offsetIn.at(0)
  local tpStart = transparency.at(0)

  -- a phase that starts where it already ends has nothing to do. an authored
  -- queue is taken at its word
  local offsetInMoves = offsetIn.animated
    and (mods.framed(ref, "attribute", "OffsetIn") ~= nil or offsetIn.at(0) ~= offsetIn.at(offsetIn.span))
  local sizeInMoves = sizeIn.animated
    and (mods.framed(ref, "attribute", "SizeScaleIn") ~= nil or sizeIn.at(0) ~= sizeIn.at(sizeIn.span))

  -- the longest a piece emitted at the very end can last: the whole emission,
  -- then the longest dwell it can draw, then the longest exit it can run
  local runLength = duration + lifeRange.Max + math.max(sizeOutDuration, offsetOutDuration, tpDuration)

  local speed = mods.track(ref, "attribute", "Speed", 1, attr.get(ref, "Speed_Duration", 0.1, true))

  local speedTween

  local currentSpeed = speed.at(0)

  -- a speed of zero advances no stepper's elapsed, so nothing would ever reach
  -- its end: the hold would never return and the parts would never come back to
  -- the cache.
  --
  -- deliberately WITHOUT the `elapsed > 0` term the other effects carry. theirs
  -- is safe because they hand the speed tween to tween.timer as its awaitTween
  -- veto; these do not, and tween.after cannot take one at all. every counter is
  -- called with elapsed == 0 on its first frame, so with that term a speed that
  -- is merely zero FOR NOW, which is what a queue reads during a leading delay,
  -- tears every stepper down on frame one and never rebuilds them
  local function step(deltaTime: number, elapsed: number): number?
    if currentSpeed > 0 or (speedTween ~= nil and speedTween.Connected) then
      return deltaTime * currentSpeed
    end

    return nil
  end

  local sync = attr.get(ref, "SyncPosition", false)

  duration = math.max(duration, 0.001)

  local rate = mods.track(ref, "attribute", "Rate", 30, duration)
  local scale = mods.track(ref, "attribute", "Scale", 1, duration)

  direction = direction.Unit

  if direction ~= direction then
    direction = -Vector3.zAxis
  end

  task.wait(emitDelay)

  local promises = {}

  local start = utility.getTransformedOriginExtents(origin)

  local last = 0
  local total = 0

  local currentRate = rate.at(0)
  local currentScale = scale.at(0)

  -- a fixed amount is a rate: so many pieces spread over the whole emission
  if fixedAmount > 0 then
    currentRate = fixedAmount / duration
  elseif rate.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, rate.span, function(_, deltaTime, elapsed)
        currentRate = rate.at(elapsed)
        return step(deltaTime, elapsed)
      end)
    )
  end

  if scale.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, scale.span, function(_, deltaTime, elapsed)
        currentScale = scale.at(elapsed)
        return step(deltaTime, elapsed)
      end)
    )
  end

  -- the speed tween is the clock itself, so it is the one stepper that does not
  -- scale by it
  if speed.animated then
    speedTween = tween.fromParams(utility.linear_bezier, speed.span, function(_, deltaTime, elapsed)
      currentSpeed = speed.at(elapsed)
      return deltaTime
    end)

    lifetime.hold(scope, speedTween)
  end

  local pathCurve = attr.get(ref, "Path_Curve", utility.linear_bezier)

  local ok, points = pcall(function()
    return utility.deserializePath(pathCurve)
  end)

  if not ok then
    logger.error(`failed to decode bezier path data with error: {points}`)
  end

  local bezier = Bezier.new(points, 0)

  lifetime.hold(
    scope,
    tween.fromParams(utility.linear_bezier, duration, function(_, deltaTime, elapsed)
      -- the emission runs on the effect's clock too, so a speed knob spaces the
      -- pieces out and shortens the line's run by the same factor
      local scaled = step(deltaTime, elapsed)

      if scaled == nil then
        return nil
      end

      deltaTime = scaled

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
        -- instance, and one track for the line would cut every piece to the
        -- same measurements. the track's queue default is the Min and Max pair,
        -- a randomizer between two Vector3s that draws once per component,
        -- which is exactly the three NextNumber calls this replaces
        local drawnSize = mods.track(ref, "attribute", "Size", mods.draw(minSize, maxSize), runLength).at(0)

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

        lifetime.hold(scope, function()
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

        part.CFrame = CFrame.new(offsetInStart) * rotCF

        local sizeTween
        local offsetTween

        local currentOffset = Vector3.zero

        if offsetInMoves then
          offsetTween = tween.fromParams(utility.linear_bezier, offsetIn.span, function(_, deltaTime, elapsed)
            local at = offsetIn.at(elapsed)

            -- a queue that stops resolving partway would throw here every frame, and a
            -- stepper that throws is never cleaned up
            if typeof(at) == "Vector3" then
              currentOffset = at
              part.CFrame = CFrame.new(currentOffset) * rotCF
            end

            return step(deltaTime, elapsed)
          end)

          lifetime.hold(scope, offsetTween)
        end

        local size = drawnSize * currentScale

        part.Size = size * sizeIn.at(0)

        if sizeInMoves then
          sizeTween = tween.fromParams(utility.linear_bezier, sizeIn.span, function(_, deltaTime, elapsed)
            local factor = sizeIn.at(elapsed)

            if typeof(factor) == "Vector3" then
              part.Size = size * factor
            end

            return step(deltaTime, elapsed)
          end)

          lifetime.hold(scope, sizeTween)
        end

        local env = scope.effects.emitNested(realPart, scope.depth + 1, scope)
        table.insert(promises, env.Finished)

        -- the span is the dwell's own ceiling rather than the effect's run: a
        -- Lifetime track is sampled on the piece's dwell clock, which never
        -- reaches the run. a zero there reads as fully elapsed, which would pin
        -- a linked modifier at its end value from the first frame
        local life = mods.track(ref, "attribute", "Lifetime", mods.draw(lifeRange.Min, lifeRange.Max), lifeRange.Max)
        local drawn = life.at(0)

        -- a NaN lifetime satisfies no comparison, so elapsed >= target is false for
        -- ever and the piece dwells for the life of the session
        if typeof(drawn) ~= "number" or drawn ~= drawn then
          drawn = rng:NextNumber(lifeRange.Min, lifeRange.Max)
        end

        -- the dwell belongs to the effect rather than to the scheduler: its
        -- cleanup lives in the scope, so tearing the line down cancels it rather
        -- than firing exit tweens at a pooled part the cache has handed on, and
        -- its length is the counter's to decide, so a Lifetime a modifier is
        -- moving moves a dwell that is already running
        tween.after(math.huge, function(deltaTime, elapsed)
          local target = life.at(elapsed)

          if typeof(target) ~= "number" or target ~= target then
            target = drawn
          end

          if elapsed >= target then
            return nil :: any
          end

          return step(deltaTime, elapsed)
        end, function()
          task.spawn(function()
            if sizeTween then
              sizeTween:Disconnect()
            end

            if offsetTween then
              offsetTween:Disconnect()
            end

            local startSize = part.Size

            if startSize ~= size * sizeOutEnd then
              lifetime.hold(
                scope,
                tween.fromParams(sizeOutCurve, sizeOutDuration, function(alpha, deltaTime, elapsed)
                  part.Size = startSize:Lerp(size * sizeOutEnd, alpha)
                  return step(deltaTime, elapsed)
                end)
              )
            end

            if currentOffset ~= offsetOutEnd then
              lifetime.hold(
                scope,
                tween.fromParams(offsetOutCurve, offsetOutDuration, function(alpha, deltaTime, elapsed)
                  part.CFrame = CFrame.new(currentOffset:Lerp(offsetOutEnd, alpha)) * rotCF
                  return step(deltaTime, elapsed)
                end)
              )
            end

            if transparency.animated then
              lifetime.hold(
                scope,
                tween.fromParams(utility.linear_bezier, transparency.span, function(_, deltaTime, elapsed)
                  part.Transparency = transparency.at(elapsed)
                  return step(deltaTime, elapsed)
                end)
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
  tween.timer(runLength, function(deltaTime, elapsed)
    return step(deltaTime, elapsed)
  end, nil, scope)

  Promise.all(promises):await()
end

return line
