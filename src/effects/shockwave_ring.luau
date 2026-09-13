local CollectionService = game:GetService("CollectionService")

local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local legacy_mods = require("@mod/legacy_mods")

local Promise = require("@pkg/Promise")
local ObjectCache = require("@obj/ObjectCache")

local rng = Random.new()

local ring = {}

-- every one of these is driven here, so the applier must not drive them as
-- well. Lifetime and Size especially: their legacy attributes are a NumberRange
-- and a Min/Max pair, and an applier writing a sample back would replace the
-- range with a scalar
ring.OWNS = {
  attribute = {
    Size = true,
    Speed = true,
    Lifetime = true,
    OffsetIn = true,
    SizeScaleIn = true,
    Transparency = true,
  },
}

local part_cache: ObjectCache.ObjectCache?

function ring.init(cache)
  part_cache = cache
end

function ring.deinit()
  part_cache = nil
end

function ring.emit(origin: Attachment, ref: Part, scope: types.scope)
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

  local radius = attr.get(ref, "Radius", 5)
  local segments = attr.get(ref, "Segments", 7)

  local lifeRange = attr.getRange(ref, "Lifetime", NumberRange.new(2, 3), NumberRange.new(0, math.huge))

  local offsetOutEnd = legacy_mods.alias(ref, "OffsetOut_End", Vector3.zero)
  local offsetOutDuration = legacy_mods.alias(ref, "OffsetOut_Duration", 0.5)
  local offsetOutCurve = legacy_mods.alias(ref, "OffsetOut_Curve", utility.default_bezier)

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

  -- the fade a segment runs after its dwell: from where the transparency rests
  -- to where it ends, over its own clock
  local transparency = mods.track(ref, "attribute", "Transparency", 0, tpDuration)

  local offsetInStart = offsetIn.at(0)
  local tpStart = transparency.at(0)

  -- a phase that starts where it already ends has nothing to do. an authored
  -- queue is taken at its word
  local offsetInMoves = offsetIn.animated
    and (mods.framed(ref, "attribute", "OffsetIn") ~= nil or offsetIn.at(0) ~= offsetIn.at(offsetIn.span))
  local sizeInMoves = sizeIn.animated
    and (mods.framed(ref, "attribute", "SizeScaleIn") ~= nil or sizeIn.at(0) ~= sizeIn.at(sizeIn.span))

  -- the longest a segment can last, which is the ring's own clock: the longest
  -- dwell it can draw, then the longest exit it can run
  local runLength = lifeRange.Max + math.max(sizeOutDuration, offsetOutDuration, tpDuration)

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

  task.wait(emitDelay)

  -- the speed tween is the clock itself, so it is the one stepper that does not
  -- scale by it
  if speed.animated then
    speedTween = tween.fromParams(utility.linear_bezier, speed.span, function(_, deltaTime, elapsed)
      currentSpeed = speed.at(elapsed)
      return deltaTime
    end)

    lifetime.hold(scope, speedTween)
  end

  local promises = {}
  local originCFrame = utility.getTransformedOriginExtents(origin)

  for i = 0, segments - 1 do
    local angle = i / segments * math.pi * 2

    local x = radius * math.cos(angle)
    local y = radius * math.sin(angle)

    local result =
      workspace:Raycast((originCFrame * CFrame.new(x, 0, y)).Position, originCFrame:VectorToWorldSpace(raydir), params)

    if not result then
      continue
    end

    -- per SEGMENT, like the lifetime: a size is drawn per emitted instance, and
    -- one track for the ring would cut every piece to the same measurements.
    --
    -- the track's queue default is the Min and Max pair, a randomizer between
    -- two Vector3s that draws once per component, which is exactly the three
    -- NextNumber calls this replaces
    local size = mods.track(ref, "attribute", "Size", mods.draw(minSize, maxSize), runLength).at(0)

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

    local emitOnFinish = scope.effects.prepareEmitOnFinish(part, scope)

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

    local rx = -math.cos(angle)
    local rz = -math.sin(angle)

    local dir = originCFrame:VectorToWorldSpace(Vector3.new(rx, 0, rz))
    local right = dir:Cross(result.Normal).Unit

    local rotCF = CFrame.fromMatrix(result.Position, right, result.Normal)
      * CFrame.fromOrientation(-math.atan(size.Y / size.Z), 0, 0)

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

    local env = scope.effects.emitNested(part, scope.depth + 1, scope)
    table.insert(promises, env.Finished)

    -- asked for per SEGMENT, not once for the ring: a lifetime is drawn per
    -- emitted instance, and a track asked for once would hand every segment the
    -- same draw and break them apart into one synchronised flash.
    --
    -- the span is the dwell's own ceiling rather than the effect's run: a
    -- Lifetime track is sampled on the piece's dwell clock, which never reaches
    -- the run. a zero there reads as fully elapsed, which would pin a linked
    -- modifier at its end value from the first frame
    local life = mods.track(ref, "attribute", "Lifetime", mods.draw(lifeRange.Min, lifeRange.Max), lifeRange.Max)
    local drawn = life.at(0)

    -- a NaN lifetime satisfies no comparison, so elapsed >= target is false for
    -- ever and the piece dwells for the life of the session
    if typeof(drawn) ~= "number" or drawn ~= drawn then
      drawn = rng:NextNumber(lifeRange.Min, lifeRange.Max)
    end

    -- the dwell is part of the effect, not of the scheduler: its cleanup lives
    -- in the scope, so tearing the effect down cancels it rather than letting it
    -- fire into a part the cache has already handed to someone else, and it runs
    -- on the effect's clock, so speed scales it.
    --
    -- the length is the counter's to decide rather than the duration's, so a
    -- Lifetime a modifier is moving is read every frame instead of being baked
    -- at emit. with nothing authored that reads the value this segment drew and
    -- the two are the same thing.
    --
    -- the body still runs on its own thread, the way task.delay ran it: what
    -- resumes it is a render step, and emitOnFinish is not something to hand a
    -- render step
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

        local env = scope.effects.emitOnFinish(emitOnFinish, part, scope.depth + 1, scope)
        table.insert(promises, env.Finished)
      end)
    end, scope)
  end

  -- the hold has to run on the same clock the dwells do, or a speed below one
  -- stretches them past it and the scope tears down mid dwell. the transparency
  -- exit is one of the three a dwell starts, so it counts here too or a long one
  -- is cut off partway
  tween.timer(runLength, function(deltaTime, elapsed)
    return step(deltaTime, elapsed)
  end, nil, scope)

  Promise.all(promises):await()
end

return ring
