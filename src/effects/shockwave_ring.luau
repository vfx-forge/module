local CollectionService = game:GetService("CollectionService")

local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local utility = require("@mod/utility")

local Promise = require("@pkg/Promise")
local ObjectCache = require("@obj/ObjectCache")

local rng = Random.new()

local ring = {}

-- all three are driven here, so the applier must not drive them as well.
-- Lifetime and Size especially: their legacy attributes are a NumberRange and a
-- Min/Max pair, and an applier writing a sample back would replace the range
-- with a scalar
ring.OWNS = {
  attribute = {
    Size = true,
    Speed = true,
    Lifetime = true,
    OffsetIn = true,
    SizeScaleIn = true,
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

  local lifetime = attr.getRange(ref, "Lifetime", NumberRange.new(2, 3), NumberRange.new(0, math.huge))

  -- the two phases are rows now, each a stem whose four keys legacy_mods can
  -- derive: OffsetIn and OffsetOut, SizeScaleIn and SizeScaleOut. Every rename
  -- reads the old name SOFT as the new one's default, which is what PartOffset
  -- and Size_Curve already did here, so content in the wild keeps working and
  -- nothing of it is overwritten
  local old_partOffset = attr.get(ref, "PartOffset", vector.zero, true)

  local old_baseOffset = attr.get(ref, "BaseOffset", old_partOffset, true)
  local old_offsetStart = attr.get(ref, "Offset_Start", old_partOffset, true)
  local old_offsetEnd = attr.get(ref, "Offset_End", old_partOffset, true)

  local offsetInStart = attr.get(ref, "OffsetIn_Start", old_offsetStart)
  local offsetInEnd = attr.get(ref, "OffsetIn_End", old_baseOffset)
  local offsetOutEnd = attr.get(ref, "OffsetOut_End", old_offsetEnd)

  local offsetInDuration = attr.get(ref, "OffsetIn_Duration", attr.get(ref, "Offset_Start_Duration", 0.5, true))
  local offsetOutDuration = attr.get(ref, "OffsetOut_Duration", attr.get(ref, "Offset_End_Duration", 0.5, true))

  -- hoisted for the same reason the size curves are: read down in the legacy
  -- branch this never runs when a driver exists, so an authored Offset_Start_Curve
  -- would be dropped. reading it here also stamps the new name before the driver
  -- asks, so the quad readQuad finds carries the migrated curve
  local offsetInCurve =
    attr.get(ref, "OffsetIn_Curve", attr.get(ref, "Offset_Start_Curve", utility.default_bezier, true))
  local offsetOutCurve =
    attr.get(ref, "OffsetOut_Curve", attr.get(ref, "Offset_End_Curve", utility.default_bezier, true))

  local minSize = attr.get(ref, "MinSize", vector.create(2, 1, 2))
  local maxSize = attr.get(ref, "MaxSize", vector.create(3, 2, 3))

  local old_sizeCurve = attr.get(ref, "Size_Curve", utility.default_bezier, true)
  local old_sizeDuration = attr.get(ref, "Size_Duration", 0.5, true)

  local old_scaleStart = attr.get(ref, "SizeScaleStart", vector.zero, true)
  local old_scaleEnd = attr.get(ref, "SizeScaleEnd", vector.zero, true)

  local sizeInStart = attr.get(ref, "SizeScaleIn_Start", old_scaleStart)
  local sizeOutEnd = attr.get(ref, "SizeScaleOut_End", old_scaleEnd)

  -- the entry phase always ended at exactly the drawn size, which is a factor of
  -- one. naming it makes it authorable: a piece can overshoot and settle
  local sizeInEnd = attr.get(ref, "SizeScaleIn_End", vector.one)

  local sizeInCurve = attr.get(ref, "SizeScaleIn_Curve", attr.get(ref, "Size_Start_Curve", old_sizeCurve, true))
  local sizeOutCurve = attr.get(ref, "SizeScaleOut_Curve", attr.get(ref, "Size_End_Curve", old_sizeCurve, true))

  local sizeInDuration =
    attr.get(ref, "SizeScaleIn_Duration", attr.get(ref, "Size_Start_Duration", old_sizeDuration, true))
  local sizeOutDuration =
    attr.get(ref, "SizeScaleOut_Duration", attr.get(ref, "Size_End_Duration", old_sizeDuration, true))

  local tpDuration = attr.get(ref, "Transparency_Duration", 0.5)

  local tpStart = attr.get(ref, "Transparency_Start", 0)
  local tpEnd = attr.get(ref, "Transparency_End", 0)

  -- the longest a segment can last, which is the ring's own clock: the longest
  -- dwell it can draw, then the longest exit it can run
  local runLength = lifetime.Max + math.max(sizeOutDuration, offsetOutDuration, tpDuration)

  -- the driver is asked for BEFORE any non-soft read of the quad keys it would
  -- find, because attr.get writes its default back: reading Speed_Start creates
  -- it and legacy_mods then finds a quad nobody authored.
  --
  -- the fallback is the ring's own run, not Speed_Duration. it is only reached
  -- when NO modifier in the queue names a duration, which is what the panel
  -- calls a linked modifier, and linked means "as long as the effect runs". a
  -- legacy quad never reaches it at all, since readQuad puts Speed_Duration on
  -- the modifier itself
  -- the entry phases are rows a reader can derive now, so each runs from its own
  -- queue when it has one. the exit phases carry only an _End: their start is
  -- wherever the value got to, so they read as half quads and mods.driver stands
  -- down on them, which is lightning's Fade_In and Fade_Out shape exactly.
  --
  -- the usual "ask before any non-soft read of the quad keys" rule does not bite
  -- here. it exists because attr.get stamps a default the author never chose;
  -- what these stamp is the value the old name already held, which is precisely
  -- what the legacy branch below would have tweened, so the queue readQuad finds
  -- says the same thing either way
  local offsetInQueue = mods.framed(ref, "attribute", "OffsetIn")
  local offsetInDrv, offsetInSpan = mods.driver(ref, "attribute", "OffsetIn", runLength, "Vector3")

  local sizeInQueue = mods.framed(ref, "attribute", "SizeScaleIn")
  local sizeInDrv, sizeInSpan = mods.driver(ref, "attribute", "SizeScaleIn", runLength, "Vector3")

  -- a phase that starts where it already ends has nothing to do, and the legacy
  -- branch skipped it outright rather than binding a stepper per piece to write
  -- one value over itself. an authored queue is taken at its word
  local offsetInMoves = offsetInDrv ~= nil and (offsetInQueue ~= nil or offsetInStart ~= offsetInEnd)
  local sizeInMoves = sizeInDrv ~= nil and (sizeInQueue ~= nil or sizeInStart ~= sizeInEnd)

  local speedDrv, speedSpan = mods.driver(ref, "attribute", "Speed", runLength, "number")

  local speedStart = attr.get(ref, "Speed_Start", 1, true)
  local speedEnd = attr.get(ref, "Speed_End", 1, true)

  local speedTween

  local currentSpeed = if speedDrv then speedDrv(0) else speedStart

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
  if speedDrv then
    speedTween = tween.fromParams(utility.linear_bezier, speedSpan, function(_, deltaTime, elapsed)
      currentSpeed = speedDrv(elapsed)
      return deltaTime
    end)

    table.insert(scope, speedTween)
  elseif speedStart ~= speedEnd then
    speedTween = tween.fromParams(
      attr.get(ref, "Speed_Curve", utility.default_bezier),
      attr.get(ref, "Speed_Duration", 0.1),
      function(alpha, deltaTime)
        currentSpeed = utility.lerp(speedStart, speedEnd, alpha)
        return deltaTime
      end
    )

    table.insert(scope, speedTween)
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
    -- one driver for the ring would cut every piece to the same measurements.
    --
    -- legacy_mods reads the MinSize and MaxSize pair as a randomizer, and a
    -- randomizer between two Vector3s draws once per component, which is exactly
    -- the three NextNumber calls this replaces
    local sizeDrv = mods.driver(ref, "attribute", "Size", runLength, "Vector3")
    local size = if sizeDrv then sizeDrv(0) else nil

    if typeof(size) ~= "Vector3" then
      size = Vector3.new(
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

    local emitOnFinish = scope.effects.prepareEmitOnFinish(part, scope)

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
      -- linear, because the queue's own curve is what shapes it
      offsetTween = tween.fromParams(utility.linear_bezier, offsetInSpan, function(_, deltaTime, elapsed)
        local at = (offsetInDrv :: any)(elapsed)

        -- a queue that stops resolving partway would throw here every frame, and a
        -- stepper that throws is never cleaned up
        if typeof(at) == "Vector3" then
          currentOffset = at
          part.CFrame = CFrame.new(currentOffset) * rotCF
        end

        return step(deltaTime, elapsed)
      end)

      table.insert(scope, offsetTween)
    elseif offsetInStart ~= offsetInEnd then
      offsetTween = tween.fromParams(offsetInCurve, offsetInDuration, function(alpha, deltaTime, elapsed)
        currentOffset = offsetInStart:Lerp(offsetInEnd, alpha)
        part.CFrame = CFrame.new(currentOffset) * rotCF
        return step(deltaTime, elapsed)
      end)

      table.insert(scope, offsetTween)
    end

    if sizeInMoves then
      sizeTween = tween.fromParams(utility.linear_bezier, sizeInSpan, function(_, deltaTime, elapsed)
        local scale = (sizeInDrv :: any)(elapsed)

        if typeof(scale) == "Vector3" then
          part.Size = size * scale
        end

        return step(deltaTime, elapsed)
      end)

      table.insert(scope, sizeTween)
    elseif size * sizeInStart ~= size * sizeInEnd then
      sizeTween = tween.fromParams(sizeInCurve, sizeInDuration, function(alpha, deltaTime, elapsed)
        part.Size = (size * sizeInStart):Lerp(size * sizeInEnd, alpha)
        return step(deltaTime, elapsed)
      end)

      table.insert(scope, sizeTween)
    else
      part.Size = size * sizeInStart
    end

    local env = scope.effects.emitNested(part, scope.depth + 1, scope)
    table.insert(promises, env.Finished)

    -- asked for per SEGMENT, not once for the ring: a lifetime is drawn per
    -- emitted instance, and a driver asked for once would hand every segment the
    -- same draw and break them apart into one synchronised flash.
    --
    -- legacy_mods reads the Lifetime NumberRange as a randomizer, so this covers
    -- authored and unauthored alike and the manual draw is only left for a ring
    -- carrying no Lifetime attribute at all
    --
    -- the fallback span is the dwell's own ceiling rather than the effect's run: a
    -- Lifetime driver is sampled on the piece's dwell clock, which never reaches
    -- the run. a zero there reads as fully elapsed, which would pin a linked
    -- modifier at its end value from the first frame
    local lifeDrv = mods.driver(ref, "attribute", "Lifetime", lifetime.Max, "number")
    local drawn = if lifeDrv then lifeDrv(0) else nil

    -- a NaN lifetime satisfies no comparison, so elapsed >= target is false for
    -- ever and the piece dwells for the life of the session
    if typeof(drawn) ~= "number" or drawn ~= drawn then
      drawn = rng:NextNumber(lifetime.Min, lifetime.Max)
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
      local target = if lifeDrv then lifeDrv(elapsed) else nil

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
        local startTp = part.Transparency

        if startSize ~= size * sizeOutEnd then
          table.insert(
            scope,
            tween.fromParams(sizeOutCurve, sizeOutDuration, function(alpha, deltaTime, elapsed)
              part.Size = startSize:Lerp(size * sizeOutEnd, alpha)
              return step(deltaTime, elapsed)
            end)
          )
        end

        if currentOffset ~= offsetOutEnd then
          table.insert(
            scope,
            tween.fromParams(offsetOutCurve, offsetOutDuration, function(alpha, deltaTime, elapsed)
              part.CFrame = CFrame.new(currentOffset:Lerp(offsetOutEnd, alpha)) * rotCF
              return step(deltaTime, elapsed)
            end)
          )
        end

        if startTp ~= tpEnd then
          table.insert(
            scope,
            tween.fromParams(
              attr.get(ref, "Transparency_Curve", utility.default_bezier),
              tpDuration,
              function(alpha, deltaTime, elapsed)
                part.Transparency = utility.lerp(startTp, tpEnd, alpha)
                return step(deltaTime, elapsed)
              end
            )
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
