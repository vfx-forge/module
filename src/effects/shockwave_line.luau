local CollectionService = game:GetService("CollectionService")

local mod = require("@mod/mod")
local knob = require("@mod/knob")
local tween = require("@mod/tween")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")

local Shockwave = require("@vfx/shockwave")

local Bezier = require("@obj/Bezier")
local Promise = require("@pkg/Promise")
local ObjectCache = require("@obj/ObjectCache")

local rng = Random.new()

local function always()
  return true
end

local function defaultCurve()
  return utility.default_bezier
end

local line = {}

line.id = "shockwave_line"
line.display = { name = "Shockwave Line", icon = "shockwave_line", order = 52 }
line.classifier = ".Shockwave > #Lines > BasePart"
line.components = "Instance"

line.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("EmitDelay"):hint("Seconds before the effect starts emitting."),
  Duration = knob(1):min(0):unit("seconds"):label("Duration"):hint("How long the raycast sweep takes, in seconds."),
  Lifetime = knob(NumberRange.new(2, 3))
    :min(0)
    :unit("seconds")
    :mod()
    :label("Lifetime")
    :hint("How long each spawned line piece lives, in seconds."),
  SyncPosition = knob(false)
    :label("SyncPosition")
    :hint("Whether the sweep re-samples the origin's position every tick."),
  Length = knob(50):min(0):unit("studs"):label("Length"):hint("Studs the raycast origin sweeps along Direction."),
  Direction = knob(vector.create(0, 0, -1))
    :label("Direction")
    :hint("Local direction the sweep travels away from the origin."),
  Rotation = knob(NumberRange.new(-180, 180))
    :label("Rotation")
    :hint("Random per-piece rotation range around the hit normal, in degrees."),
  -- a fixed amount spreads the casts over the whole sweep itself, and the rate
  -- is then read by nothing
  Rate = knob(30)
    :min(0)
    :unit("perSecond")
    :mod()
    :readonly(function(_, attrs)
      return attrs.FixedAmount ~= 0
    end)
    :label("Rate")
    :hint("Raycasts per second over the sweep."),
  FixedAmount = knob(0)
    :min(0)
    :label("FixedAmount")
    :hint("Total raycasts spread evenly across Duration, overriding Rate."),
  Scale = knob(1):min(0):mod():label("Scale"):hint("Overall size multiplier over the sweep."),
  PathCurve = knob(function()
      return utility.linear_bezier
    end)
    :aliases("Path_Curve")
    :label("Path")
    :hint("Easing of the sweep along its length."),
  Size = knob(vector.create(2.5, 1.5, 2.5))
    :unit("studs")
    :mod()
    :label("Size")
    :hint("Size drawn for each piece, in studs."),
  Speed = knob(1):mod():label("Speed"):hint("Multiplier on the effect's clock."),
  SpeedDuration = knob(0.1):min(0):aliases("Speed_Duration"):unit("seconds"):hidden(always),
  OffsetIn = knob(vector.zero):unit("studs"):mod():label("Offset"):hint("Local offset each piece settles at."),
  OffsetInDuration = knob(0.5)
    :min(0)
    :aliases("OffsetIn_Duration", "Offset_Start_Duration")
    :unit("seconds")
    :hidden(always),
  SizeScaleIn = knob(vector.one)
    :mod(mod.from(vector.zero):duration(function(_, attrs)
      return attrs.SizeScaleInDuration
    end))
    :label("Scale")
    :hint("Fraction of the drawn size each piece settles at."),
  SizeScaleInDuration = knob(0.5)
    :min(0)
    :aliases("SizeScaleIn_Duration", "Size_Start_Duration")
    :unit("seconds")
    :hidden(always),
  Transparency = knob(0)
    :aliases("Transparency_Start")
    :mod(mod.to(0):duration(function(_, attrs)
      return attrs.TransparencyDuration
    end))
    :label("Start")
    :hint("Transparency applied to each line piece on spawn."),
  TransparencyDuration = knob(0.5):min(0):aliases("Transparency_Duration"):unit("seconds"):hidden(always),
  ShrinkScale = knob(vector.zero)
    :aliases("SizeScaleOut_End", "SizeScaleEnd")
    :label("End")
    :hint("Fraction of the rolled size each line piece tweens to."),
  ShrinkDuration = knob(0.5)
    :min(0)
    :aliases("SizeScaleOut_Duration", "Size_End_Duration", "Size_Duration")
    :unit("seconds")
    :label("Duration")
    :hint("Seconds the shrink takes."),
  ShrinkCurve = knob(defaultCurve)
    :aliases("SizeScaleOut_Curve", "Size_End_Curve", "Size_Curve")
    :label("Curve")
    :hint("Easing of the shrink."),
  OffsetOut = knob(vector.zero)
    :aliases("OffsetOut_End", "Offset_End", "PartOffset")
    :unit("studs")
    :label("End")
    :hint("Local offset each line piece tweens to before despawning."),
  OffsetOutDuration = knob(0.5)
    :min(0)
    :aliases("OffsetOut_Duration", "Offset_End_Duration")
    :unit("seconds")
    :label("Duration")
    :hint("Seconds the exit offset takes."),
  OffsetOutCurve = knob(defaultCurve)
    :aliases("OffsetOut_Curve", "Offset_End_Curve")
    :label("Curve")
    :hint("Easing of the exit offset."),
}

line.properties = {}

line.layout = {
  { title = "Emit", entries = { "EmitDelay", "Speed" } },
  "Duration",
  "Lifetime",
  "SyncPosition",
  "Length",
  "Direction",
  "Rotation",
  { title = "Offset", entries = { "OffsetIn", "OffsetOut", "OffsetOutDuration", "OffsetOutCurve" } },
  "Rate",
  "PathCurve",
  "FixedAmount",
  { title = "Transparency", entries = { "Transparency" } },
  "Scale",
  {
    title = "Size",
    entries = {
      "Size",
      { title = "Scale", entries = { "SizeScaleIn", "ShrinkScale", "ShrinkDuration", "ShrinkCurve" } },
    },
  },
}

-- the longest a piece emitted at the very end can last: the whole emission,
-- then the longest dwell it can draw, then the longest exit it can run
function line.duration(_, attrs: any)
  return attrs.Duration
    + attrs.Lifetime.value.Max
    + math.max(attrs.ShrinkDuration, attrs.OffsetOutDuration, attrs.TransparencyDuration)
end

local part_cache: ObjectCache.ObjectCache?

function line.init(cache)
  part_cache = cache
end

function line.deinit()
  part_cache = nil
end

-- the raycast parameters every piece effect builds from the origin's rows
local function paramsOf(origin: any): (RaycastParams, Vector3)
  local params = RaycastParams.new()
  params.CollisionGroup = origin.RayCollisionGroup
  params.IgnoreWater = origin.IgnoreWater
  params.RespectCanCollide = not origin.IgnoreCanCollide
  params.FilterType = Enum.RaycastFilterType[origin.FilterType]
  params.FilterDescendantsInstances = CollectionService:GetTagged(origin.FilterTag)

  if origin.FilterType == "Exclude" then
    params:AddToFilter({ workspace.Terrain })
  end

  return params, origin.RayDirection
end

function line.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: BasePart
  local scope = ctx.scope
  local origin = utility.findFirstClassWithTag(ref, "Attachment", utility.SHOCKWAVE_TAG)

  if not part_cache or not origin then
    return
  end

  local originAttrs = registry.read(origin, Shockwave)

  if originAttrs == nil then
    return
  end

  local params, raydir = paramsOf(originAttrs)

  local fixedAmount = attrs.FixedAmount

  local duration = math.max(attrs.Duration, 0.001)
  local direction = attrs.Direction
  local lineLength = attrs.Length

  local rot = attrs.Rotation

  local lifeMin = attrs.Lifetime.value.Min
  local lifeMax = attrs.Lifetime.value.Max

  local shrinkTo = attrs.ShrinkScale
  local shrinkCurve = attrs.ShrinkCurve
  local shrinkDuration = attrs.ShrinkDuration

  local offsetOut = attrs.OffsetOut
  local offsetOutCurve = attrs.OffsetOutCurve
  local offsetOutDuration = attrs.OffsetOutDuration

  local offsetIn = attrs.OffsetIn
  local sizeIn = attrs.SizeScaleIn

  local offsetInStart = offsetIn.at(0)
  local sizeInStart = sizeIn.at(0)

  local offsetInMoves = offsetIn.animated and offsetInStart ~= offsetIn.at(offsetIn.duration)
  local sizeInMoves = sizeIn.animated and sizeInStart ~= sizeIn.at(sizeIn.duration)

  local runLength = ctx.duration :: number

  local speed = attrs.Speed

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

  local sync = attrs.SyncPosition

  -- the sweep's own rows run over the sweep, not over the whole run
  local rate = attrs.Rate(nil, duration)
  local scale = attrs.Scale(nil, duration)

  direction = direction.Unit

  if direction ~= direction then
    direction = -Vector3.zAxis
  end

  task.wait(attrs.EmitDelay)

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
      tween.fromParams(utility.linear_bezier, rate.duration, function(_, deltaTime, elapsed)
        currentRate = rate.at(elapsed)
        return step(deltaTime, elapsed)
      end)
    )
  end

  if scale.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, scale.duration, function(_, deltaTime, elapsed)
        currentScale = scale.at(elapsed)
        return step(deltaTime, elapsed)
      end)
    )
  end

  -- the speed tween is the clock itself, so it is the one stepper that does not
  -- scale by it
  if speed.animated then
    speedTween = tween.fromParams(utility.linear_bezier, speed.duration, function(_, deltaTime, elapsed)
      currentSpeed = speed.at(elapsed)
      return deltaTime
    end)

    lifetime.hold(scope, speedTween)
  end

  local pathCurve = attrs.PathCurve

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

        -- per emitted PIECE: the row is called again so a drawn size is this
        -- piece's own
        local drawnSize = attrs.Size().at(0)

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

        -- an opaque surface leaves the piece where the row rests
        if part.Transparency == 0 then
          part.Transparency = attrs.Transparency.value
        end

        -- the fade a piece runs after its dwell goes from where the piece
        -- rests, which a piece inheriting its hit surface knows only now,
        -- to where the row ends. a framed queue names both ends and is
        -- taken at its word
        local fade = attrs.Transparency(part.Transparency)

        part.Transparency = fade.at(0)

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
          offsetTween = tween.fromParams(utility.linear_bezier, offsetIn.duration, function(_, deltaTime, elapsed)
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

        part.Size = size * sizeInStart

        if sizeInMoves then
          sizeTween = tween.fromParams(utility.linear_bezier, sizeIn.duration, function(_, deltaTime, elapsed)
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

        -- per PIECE, over the dwell's own ceiling rather than the line's run: a
        -- Lifetime track is sampled on the piece's dwell clock, which never
        -- reaches the run, and a zero there would read as fully elapsed
        local life = attrs.Lifetime(nil, lifeMax)
        local drawn = life.at(0)

        -- a NaN lifetime satisfies no comparison, so elapsed >= target is false for
        -- ever and the piece dwells for the life of the session
        if typeof(drawn) ~= "number" or drawn ~= drawn then
          drawn = rng:NextNumber(lifeMin, lifeMax)
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

            if startSize ~= size * shrinkTo then
              lifetime.hold(
                scope,
                tween.fromParams(shrinkCurve, shrinkDuration, function(alpha, deltaTime, elapsed)
                  part.Size = startSize:Lerp(size * shrinkTo, alpha)
                  return step(deltaTime, elapsed)
                end)
              )
            end

            if currentOffset ~= offsetOut then
              lifetime.hold(
                scope,
                tween.fromParams(offsetOutCurve, offsetOutDuration, function(alpha, deltaTime, elapsed)
                  part.CFrame = CFrame.new(currentOffset:Lerp(offsetOut, alpha)) * rotCF
                  return step(deltaTime, elapsed)
                end)
              )
            end

            if fade.animated then
              lifetime.hold(
                scope,
                tween.fromParams(utility.linear_bezier, fade.duration, function(_, deltaTime, elapsed)
                  local v = fade.at(elapsed)

                  if typeof(v) == "number" then
                    part.Transparency = v
                  end

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
