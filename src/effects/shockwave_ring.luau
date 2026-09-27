local CollectionService = game:GetService("CollectionService")

local mod = require("@mod/mod")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")

local Shockwave = require("@vfx/shockwave")

local Promise = require("@pkg/Promise")
local ObjectCache = require("@obj/ObjectCache")

local rng = Random.new()

local function always()
  return true
end

local function defaultCurve()
  return utility.default_bezier
end

-- each piece draws its own size between the two corners, which is what the old
-- pair of reads did with a default each. a size authored on the row itself, or
-- a queue under it, is the row's state and draws nothing
local function sizeFromCorners(_, attrs: any)
  return mods.draw(attrs.MinSize, attrs.MaxSize)
end

-- the exits are the despawn lane's defaults on the offset and size rows, and
-- these rows say where each goes, for how long and how
local function shrinkEnd(_, attrs: any)
  return attrs.ShrinkScale
end

local function shrinkDuration(_, attrs: any)
  return attrs.ShrinkDuration
end

local function shrinkCurve(_, attrs: any)
  return attrs.ShrinkCurve
end

local function offsetOutEnd(_, attrs: any)
  return attrs.OffsetOut
end

local function offsetOutDuration(_, attrs: any)
  return attrs.OffsetOutDuration
end

local function offsetOutCurve(_, attrs: any)
  return attrs.OffsetOutCurve
end

local ring = {}

ring.id = "shockwave_ring"
ring.display = { name = "Shockwave Ring", icon = "shockwave_ring", order = 51 }
ring.classifier = ".Shockwave > #Rings > BasePart"
ring.components = "Instance"
ring.events = { "despawn" }

ring.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("EmitDelay"):hint("Seconds before the effect starts emitting."),
  Radius = knob(5):min(0):unit("studs"):label("Radius"):hint("Radius of the effect."),
  Segments = knob(7):min(1):label("Segments"):hint("Number of raycasts distributed evenly around the ring."),
  Lifetime = knob(NumberRange.new(2, 3))
    :min(0)
    :unit("seconds")
    :mod()
    :label("Lifetime")
    :hint("How long the effect lives in seconds."),
  -- the corners are the pair an author sets and the panel renders, and they are
  -- spelled the engine's way because a draw only runs per axis between two
  -- values of that spelling. the drawn size between them is the row a queue or
  -- a bare Size attribute overrides, which is all it is ever named for
  Size = knob(sizeFromCorners):unit("studs"):mod():hidden(always),
  MinSize = knob(Vector3.new(2, 1, 2))
    :aliases("Size_Min")
    :unit("studs")
    :label("Min")
    :hint("Minimum per-axis size for each ring piece."),
  MaxSize = knob(Vector3.new(3, 2, 3))
    :aliases("Size_Max")
    :unit("studs")
    :label("Max")
    :hint("Maximum per-axis size for each ring piece."),
  Speed = knob(1):mod():label("Speed"):hint("Multiplier on the effect's clock."),
  -- the span an old speed quad ran over, read by the old format's reader under
  -- this name and kept as a row so retime reaches it
  SpeedDuration = knob(0.1):min(0):aliases("Speed_Duration"):unit("seconds"):hidden(always),
  -- the entry phases rest where the old defaults left them: the offset where
  -- it stands, the size on a rise from nothing to the drawn size, the fade
  -- from where a piece rests to the end. the spans the old quads ran over
  -- are rows of their own, so the defaults keep them and retime reaches them
  OffsetIn = knob(vector.zero)
    :unit("studs")
    :mod(mod.to(offsetOutEnd):duration(offsetOutDuration):curve(offsetOutCurve):lane("despawn"))
    :label("Offset")
    :hint("Local offset each piece settles at."),
  OffsetInDuration = knob(0.5)
    :min(0)
    :aliases("OffsetIn_Duration", "Offset_Start_Duration")
    :unit("seconds")
    :hidden(always),
  SizeScaleIn = knob(vector.one)
    :mod(
      mod.from(vector.zero):duration(function(_, attrs)
        return attrs.SizeScaleInDuration
      end),
      mod.to(shrinkEnd):duration(shrinkDuration):curve(shrinkCurve):lane("despawn")
    )
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
    :label("Transparency")
    :hint("Transparency each piece rests at before its fade."),
  TransparencyDuration = knob(0.5):min(0):aliases("Transparency_Duration"):unit("seconds"):hidden(always),
  -- the exit phases run on the despawn lane the module fires when a piece's
  -- dwell ends; these rows feed its defaults on OffsetIn and SizeScaleIn and
  -- stay shown, since the panel edits only the start lane
  ShrinkScale = knob(vector.zero)
    :aliases("SizeScaleOut_End", "SizeScaleEnd")
    :label("End")
    :hint("Fraction of the drawn size each piece tweens to before despawning."),
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
    :hint("Local offset each piece tweens to before despawning."),
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

ring.properties = {}

ring.layout = {
  { title = "Emit", entries = { "EmitDelay", "Speed" } },
  "Radius",
  "Segments",
  "Lifetime",
  {
    title = "Offset",
    entries = { "OffsetIn", "OffsetOut", { curve = "OffsetOutCurve", duration = "OffsetOutDuration" } },
  },
  { title = "Transparency", entries = { "Transparency" } },
  {
    title = "Size",
    entries = {
      {
        title = "Scale",
        entries = { "SizeScaleIn", "ShrinkScale", { curve = "ShrinkCurve", duration = "ShrinkDuration" } },
      },
      "MinSize",
      "MaxSize",
    },
  },
}

-- the longest a segment can last, which is the ring's own clock: the longest
-- dwell it can draw, then the longest exit it can run
function ring.duration(_, attrs: any)
  return attrs.Lifetime.value.Max + math.max(attrs.ShrinkDuration, attrs.OffsetOutDuration, attrs.TransparencyDuration)
end

local part_cache: ObjectCache.ObjectCache?

function ring.init(cache)
  part_cache = cache
end

function ring.deinit()
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

function ring.emit(ctx: reader.Ctx, attrs: any)
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

  local radius = attrs.Radius
  local segments = attrs.Segments

  local lifeMin = attrs.Lifetime.value.Min
  local lifeMax = attrs.Lifetime.value.Max

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

  task.wait(attrs.EmitDelay)

  -- the speed tween is the clock itself, so it is the one stepper that does not
  -- scale by it
  if speed.animated then
    speedTween = tween.fromParams(utility.linear_bezier, speed.duration, function(_, deltaTime, elapsed)
      currentSpeed = speed.at(elapsed)
      return deltaTime
    end)

    lifetime.hold(scope, speedTween)
  end

  local promises = {}

  -- pieces whose dwell has begun and whose exit is not among the promises yet,
  -- and what wakes the emit once none is left. a teardown cancels every dwell
  -- without ending it, so it wakes the emit too
  local inFlight = 0
  local drained: (() -> ())? = nil

  local function landed()
    inFlight -= 1

    if inFlight == 0 and drained ~= nil then
      drained()
    end
  end

  lifetime.hold(scope, function()
    inFlight = 0

    if drained ~= nil then
      drained()
    end
  end)

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

    -- per SEGMENT: the row is called again so a drawn size is this piece's own
    local size = attrs.Size().at(0)

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

    -- an opaque surface leaves the piece where the row rests
    if part.Transparency == 0 then
      part.Transparency = attrs.Transparency.value
    end

    -- the fade a segment runs after its dwell goes from where the segment
    -- rests, which a segment inheriting its hit surface knows only now, to
    -- where the row ends. a framed queue names both ends and is taken at its
    -- word
    local fade = attrs.Transparency(part.Transparency)

    part.Transparency = fade.at(0)

    part.Size = Vector3.zero

    local rx = -math.cos(angle)
    local rz = -math.sin(angle)

    local dir = originCFrame:VectorToWorldSpace(Vector3.new(rx, 0, rz))
    local right = dir:Cross(result.Normal).Unit

    local rotCF = CFrame.fromMatrix(result.Position, right, result.Normal)
      * CFrame.fromOrientation(-math.atan(size.Y / size.Z), 0, 0)

    -- per SEGMENT: the entry and exit phases are the offset and size rows'
    -- lanes on this piece's own clock, so one piece despawning never moves
    -- another
    local piece = mods.piece(ring.events)
    local offsetIn = attrs.OffsetIn(nil, nil, piece)
    local sizeIn = attrs.SizeScaleIn(nil, nil, piece)

    -- where each row last put the piece, so an exit writes only what moved
    local currentOffset = offsetIn.at(0)
    local currentFactor = sizeIn.at(0)

    part.CFrame = CFrame.new(currentOffset) * rotCF

    local sizeTween
    local offsetTween

    -- every piece carries the despawn lane, so a track is animated whether or
    -- not anything runs from the emit: only a row with a lane of the emit's
    -- own gets an in-phase stepper, or an unauthored offset would write
    -- CFrame every frame
    if offsetIn.has("start") or offsetIn.has("end") then
      offsetTween = tween.fromParams(utility.linear_bezier, offsetIn.duration, function(_, deltaTime, elapsed)
        local at = offsetIn.at(elapsed)

        -- a queue that stops resolving partway would throw here every frame,
        -- and a stepper that throws is never cleaned up
        if typeof(at) == "Vector3" then
          currentOffset = at
          part.CFrame = CFrame.new(currentOffset) * rotCF
        end

        return step(deltaTime, elapsed)
      end)

      lifetime.hold(scope, offsetTween)
    end

    part.Size = size * currentFactor

    if sizeIn.has("start") or sizeIn.has("end") then
      sizeTween = tween.fromParams(utility.linear_bezier, sizeIn.duration, function(_, deltaTime, elapsed)
        local factor = sizeIn.at(elapsed)

        if typeof(factor) == "Vector3" then
          currentFactor = factor
          part.Size = size * factor
        end

        return step(deltaTime, elapsed)
      end)

      lifetime.hold(scope, sizeTween)
    end

    local env = scope.effects.emitNested(part, scope.depth + 1, scope)
    table.insert(promises, env.Finished)

    -- per SEGMENT, over the dwell's own ceiling rather than the ring's run: a
    -- Lifetime track is sampled on the piece's dwell clock, which never
    -- reaches the run, and a zero there would read as fully elapsed
    local life = attrs.Lifetime(nil, lifeMax)
    local drawn = life.at(0)

    -- a NaN lifetime satisfies no comparison, so elapsed >= target is false for
    -- ever and the piece dwells for the life of the session
    if typeof(drawn) ~= "number" or drawn ~= drawn then
      drawn = rng:NextNumber(lifeMin, lifeMax)
    end

    inFlight += 1

    -- the dwell's own elapsed when it ended, the moment the piece fires its
    -- despawn lane. kept every frame, since a speed that stops for good ends
    -- the dwell wherever it stood
    local fired = 0

    -- the dwell is part of the effect, not of the scheduler: its cleanup lives
    -- in the scope, so tearing the effect down cancels it rather than letting it
    -- fire into a part the cache has already handed to someone else, and it runs
    -- on the effect's clock, so speed scales it. its length is the counter's to
    -- decide, so a Lifetime a modifier is moving is read every frame
    tween.after(math.huge, function(deltaTime, elapsed)
      local target = life.at(elapsed)

      fired = elapsed

      if typeof(target) ~= "number" or target ~= target then
        target = drawn
      end

      if elapsed >= target then
        return nil :: any
      end

      return step(deltaTime, elapsed)
    end, function()
      task.spawn(function()
        -- a despawn that throws still lands its piece, or the emit would wait
        -- on it until the effect is torn down
        local ok, err = pcall(function()
          if sizeTween then
            sizeTween:Disconnect()
          end

          if offsetTween then
            offsetTween:Disconnect()
          end

          piece:fire("despawn", fired)

          local sizeReach = sizeIn.reach("despawn")
          local offsetReach = offsetIn.reach("despawn")

          -- a row whose despawn lane leaves it where it stands is written once,
          -- where it stands, and the exit still runs as long as its reach says
          local sizeUntil = if sizeIn.still("despawn", fired) then 0 else sizeReach
          local offsetUntil = if offsetIn.still("despawn", fired) then 0 else offsetReach

          -- each row is sampled until its own exit lands and never after, so a row
          -- that snaps is written once and the shorter exit stops first
          local sizeMoving = true
          local offsetMoving = true

          local function exitAt(since: number)
            if sizeMoving then
              sizeMoving = since < sizeUntil

              local factor = sizeIn.at(fired + math.min(since, sizeUntil))

              if typeof(factor) == "Vector3" and factor ~= currentFactor then
                currentFactor = factor
                part.Size = size * factor
              end
            end

            if offsetMoving then
              offsetMoving = since < offsetUntil

              local offset = offsetIn.at(fired + math.min(since, offsetUntil))

              if typeof(offset) == "Vector3" and offset ~= currentOffset then
                currentOffset = offset
                part.CFrame = CFrame.new(offset) * rotCF
              end
            end
          end

          -- one stepper runs both exits over the longer of them, on the piece's
          -- clock from the fire
          local exitLength = math.max(sizeReach, offsetReach)

          -- a despawn lane is never cut: the emit awaits every exit, however far
          -- past the ring's run it reaches. a teardown cancels the stepper without
          -- finishing it, so the teardown settles the wait too
          if exitLength > 0 then
            table.insert(
              promises,
              Promise.new(function(resolve)
                lifetime.hold(scope, function()
                  resolve()
                end)

                lifetime.hold(
                  scope,
                  tween.fromParams(
                    utility.linear_bezier,
                    exitLength,
                    function(_, deltaTime, elapsed)
                      -- a sample that throws would throw every frame and hold
                      -- the emit until teardown, so it ends the exit instead
                      local sampled, problem = pcall(exitAt, elapsed)

                      if not sampled then
                        logger.warn(`a piece's exit stopped: {problem}`)
                        return nil
                      end

                      return step(deltaTime, elapsed)
                    end,
                    nil,
                    function()
                      resolve()
                    end
                  )
                )
              end)
            )
          else
            exitAt(0)
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

          local env = scope.effects.emitOnFinish(emitOnFinish, part, scope.depth + 1, scope)
          table.insert(promises, env.Finished)
        end)

        landed()

        if not ok then
          logger.warn(`a piece failed to despawn: {err}`)
        end
      end)
    end, scope)
  end

  -- the hold has to run on the same clock the dwells do, or a speed below one
  -- stretches them past it and the scope tears down mid dwell
  tween.timer(runLength, function(deltaTime, elapsed)
    return step(deltaTime, elapsed)
  end, nil, scope)

  -- a dwell ending on the timer's own frame files its exit after the timer
  -- returns, and the wait below would never see it
  if inFlight > 0 then
    Promise.new(function(resolve)
      drained = resolve
    end):await()
  end

  Promise.all(promises):await()
end

-- a piece is authored resting on its origin, so what the panel shows is what
-- the sweep starts from; the origin is the shockwave attachment two levels up
function ring.selected(ctx: reader.Ctx)
  local piece = ctx.ref :: BasePart
  local folder = piece.Parent
  local origin = if folder ~= nil then folder.Parent else nil

  if origin == nil or not origin:IsA("Attachment") then
    return
  end

  piece.Anchored = true
  piece.CFrame = origin.WorldCFrame
end

return ring
