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

-- both are driven here, so the applier must not drive them as well. Lifetime
-- especially: its attribute is a NumberRange and a queue samples numbers, so an
-- applier writing it back would replace the range with a scalar
ring.OWNS = {
  attribute = {
    Speed = true,
    Lifetime = true,
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

  -- both drivers are asked for BEFORE any non-soft read of the quad keys they
  -- would find, because attr.get writes its default back: reading Speed_Start
  -- creates it and legacy_mods then finds a quad nobody authored
  local speedDrv, speedSpan = mods.driver(ref, "attribute", "Speed", attr.get(ref, "Speed_Duration", 0.1, true))

  local speedStart = attr.get(ref, "Speed_Start", 1, true)
  local speedEnd = attr.get(ref, "Speed_End", 1, true)

  local currentSpeed = if speedDrv then speedDrv(0) else speedStart

  local function getEffectiveSpeed(): number
    return currentSpeed
  end

  local lifetime = attr.getRange(ref, "Lifetime", NumberRange.new(2, 3), NumberRange.new(0, math.huge))

  local old_partOffset = attr.get(ref, "PartOffset", vector.zero, true)

  local baseOffset = attr.get(ref, "BaseOffset", old_partOffset)
  local offsetStart = attr.get(ref, "Offset_Start", old_partOffset)
  local offsetEnd = attr.get(ref, "Offset_End", old_partOffset)

  local offsetStartDuration = attr.get(ref, "Offset_Start_Duration", 0.5)
  local offsetEndDuration = attr.get(ref, "Offset_End_Duration", 0.5)

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

  task.wait(emitDelay)

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

    local width = rng:NextNumber(minSize.X, maxSize.X)

    local height = rng:NextNumber(minSize.Y, maxSize.Y)
    local length = rng:NextNumber(minSize.Z, maxSize.Z)

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
      * CFrame.fromOrientation(-math.atan(height / length), 0, 0)

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

    local size = Vector3.new(width, height, length)

    if size * sizeScaleStart ~= size then
      sizeTween = tween.fromParams(sizeStartCurve, sizeStartDuration, function(alpha, deltaTime)
        part.Size = (size * sizeScaleStart):Lerp(size, alpha)
        return deltaTime * getEffectiveSpeed()
      end)

      table.insert(scope, sizeTween)
    else
      part.Size = size * sizeScaleStart
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
    local lifeDrv = mods.driver(ref, "attribute", "Lifetime", 0)
    local drawn = if lifeDrv then lifeDrv(0) else rng:NextNumber(lifetime.Min, lifetime.Max)

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

        local env = scope.effects.emitOnFinish(emitOnFinish, part, scope.depth + 1, scope)
        table.insert(promises, env.Finished)
      end)
    end, scope)
  end

  -- the hold has to run on the same clock the dwells do, or a speed below one
  -- stretches them past it and the scope tears down mid dwell. the transparency
  -- exit is one of the three a dwell starts, so it counts here too or a long one
  -- is cut off partway
  tween.timer(lifetime.Max + math.max(sizeEndDuration, offsetEndDuration, tpDuration), function(deltaTime)
    return deltaTime * getEffectiveSpeed()
  end, nil, scope)

  Promise.all(promises):await()
end

return ring
