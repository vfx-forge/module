local CollectionService = game:GetService("CollectionService")

local mod = require("@mod/mod")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")

local Shockwave = require("@vfx/shockwave")

local pool = require("@srv/pool")
local mover = require("@srv/mover")
local containers = require("@srv/containers")

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

-- the exits are the despawn lane's defaults on the offset, size and
-- transparency rows, and these rows say where each goes, for how long and how
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

local function transparencyDuration(_, attrs: any)
  return attrs.TransparencyDuration
end

local line = {}

line.id = "shockwave_line"
line.display = { name = "Shockwave Line", icon = "shockwave_line", order = 52 }
line.classifier = ".Shockwave > #Lines > BasePart"
line.components = "Instance"
line.events = { "despawn" }

line.attributes = {
  EmitDelay = knob(0)
    :min(0)
    :unit("seconds")
    :ranged()
    :label("EmitDelay")
    :hint("Seconds before the effect starts emitting."),
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
  -- the corners are the pair an author sets and the panel renders, and they are
  -- spelled the engine's way because a draw only runs per axis between two
  -- values of that spelling. the drawn size between them is the row a queue or
  -- a bare Size attribute overrides, which is all it is ever named for
  Size = knob(sizeFromCorners):unit("studs"):mod():hidden(always),
  MinSize = knob(Vector3.new(2, 1, 2))
    :aliases("Size_Min")
    :unit("studs")
    :label("Min")
    :hint("Minimum per-axis size for each line piece."),
  MaxSize = knob(Vector3.new(3, 2, 3))
    :aliases("Size_Max")
    :unit("studs")
    :label("Max")
    :hint("Maximum per-axis size for each line piece."),
  Speed = knob(1):mod():label("Speed"):hint("Multiplier on the effect's clock."),
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
  -- the fade runs only once a piece despawns, so the row plays from that lane
  -- alone
  Transparency = knob(0)
    :aliases("Transparency_Start")
    :lane("despawn")
    :mod(mod.to(0):duration(transparencyDuration):lane("despawn"))
    :label("Transparency")
    :hint("Transparency each piece rests at before its fade."),
  TransparencyDuration = knob(0.5):min(0):aliases("Transparency_Duration"):unit("seconds"):hidden(always),
  -- the exit phases run on the despawn lane the module fires when a piece's
  -- dwell ends. these old exit rows feed that lane's defaults on OffsetIn and
  -- SizeScaleIn and the module's clock, and are hidden, since the modifier
  -- window's Despawn tab edits the lane itself
  ShrinkScale = knob(vector.zero):aliases("SizeScaleOut_End", "SizeScaleEnd"):hidden(always),
  ShrinkDuration = knob(0.5)
    :min(0)
    :aliases("SizeScaleOut_Duration", "Size_End_Duration", "Size_Duration")
    :unit("seconds")
    :hidden(always),
  ShrinkCurve = knob(defaultCurve):aliases("SizeScaleOut_Curve", "Size_End_Curve", "Size_Curve"):hidden(always),
  OffsetOut = knob(vector.zero):aliases("OffsetOut_End", "Offset_End", "PartOffset"):unit("studs"):hidden(always),
  OffsetOutDuration = knob(0.5)
    :min(0)
    :aliases("OffsetOut_Duration", "Offset_End_Duration")
    :unit("seconds")
    :hidden(always),
  OffsetOutCurve = knob(defaultCurve):aliases("OffsetOut_Curve", "Offset_End_Curve"):hidden(always),
}

line.properties = {}

line.layout = {
  { title = "Emit", entries = { "EmitDelay", "Speed" } },
  { title = "Sweep", entries = { "Duration", "Length", "Direction", "PathCurve", "SyncPosition" } },
  { title = "Pieces", entries = { "Rate", "FixedAmount", "Lifetime", "Rotation" } },
  { title = "Size", entries = { "Scale", "MinSize", "MaxSize" } },
  { title = "Settle", entries = { "OffsetIn", "SizeScaleIn", "Transparency" } },
}

-- the longest a piece emitted at the very end can last: the whole emission,
-- then the longest dwell it can draw, then the longest exit it can run
function line.duration(_, attrs: any)
  return attrs.Duration
    + attrs.Lifetime.value.Max
    + math.max(attrs.ShrinkDuration, attrs.OffsetOutDuration, attrs.TransparencyDuration)
end

-- the raycast parameters every piece effect builds from the origin's rows
local function paramsOf(origin: any): (RaycastParams, Vector3)
  local params = RaycastParams.new()
  params.CollisionGroup = origin.RayCollisionGroup
  params.IgnoreWater = origin.IgnoreWater
  params.RespectCanCollide = not origin.IgnoreCanCollide
  params.FilterType = Enum.RaycastFilterType[origin.FilterType]
  params.FilterDescendantsInstances = CollectionService:GetTagged(origin.FilterTag)

  -- the runtime's own pieces, debris among them, sit under its container, so Terrain itself stays hittable
  if origin.FilterType == "Exclude" then
    params:AddToFilter({ containers.root() })
  end

  return params, origin.RayDirection
end

function line.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: BasePart
  local scope = ctx.scope
  local origin = utility.findFirstClassWithTag(ref, "Attachment", utility.SHOCKWAVE_TAG)

  if not origin then
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

  local runLength = ctx.duration :: number

  -- a Speed resting at 0 for good ends every tween and dwell, and with them
  -- the run, rather than holding the parts out of the pool for ever. a speed
  -- that is merely 0 for now, as a queue reads during a leading delay, does
  -- not
  local timeline = scope.clock

  local sync = attrs.SyncPosition

  -- the sweep's own rows run over the sweep, not over the whole run
  local rate = attrs.Rate(nil, duration)
  local scale = attrs.Scale(nil, duration)

  direction = direction.Unit

  if direction ~= direction then
    direction = -Vector3.zAxis
  end

  lifetime.wait(scope, attrs.EmitDelay)

  lifetime.speed(scope, attrs.Speed)

  -- a piece counts from its dwell until its exit and its on-finish emit are
  -- counted in, and a nested emit until it ends, so the wait at the end sees
  -- a dwell that ends on the timer's own frame and an emit started after it
  local outstanding = lifetime.join(scope)

  local start = utility.getTransformedOriginExtents(origin)

  local last = 0
  local total = 0

  local currentRate = rate.at(0)
  local currentScale = scale.at(0)

  -- a fixed amount is a rate: so many pieces spread over the whole emission
  if fixedAmount > 0 then
    currentRate = fixedAmount / duration
  elseif rate.animated then
    tween.drive(scope, rate, function(value: number)
      currentRate = value
    end)
  end

  if scale.animated then
    tween.drive(scope, scale, function(value: number)
      currentScale = value
    end)
  end

  local sweep = curve.new(1, attrs.PathCurve)

  local function emitFrame(deltaTime: number, closing: boolean)
    last += deltaTime

    local threshold = 1 / currentRate
    local max = duration * currentRate

    -- a fixed amount lands whole: the closing frame emits what the summed
    -- deltas left a float short of a tick
    local whole = closing and fixedAmount > 0

    if (last < threshold and not whole) or total >= max then
      return
    end

    local ticks = last // threshold

    if whole then
      ticks = math.max(ticks, fixedAmount - total)
    end

    for i = 1, ticks do
      if total >= max then
        continue
      end

      total += 1

      local t = math.clamp(total / max, 0, 1)
      local alpha = sweep:at(t)

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
        return
      end

      -- per emitted PIECE: the row is called again so a drawn size is this
      -- piece's own
      local drawnSize = attrs.Size().at(0)

      local part = pool.take(scope, ref) :: BasePart

      local emitOnFinish = scope.effects.prepareEmitOnFinish(part, scope)

      part.Color = utility.surfaceColor(result)
      part.Material = result.Material
      part.Transparency = result.Instance.Transparency

      -- an opaque surface leaves the piece where the row rests
      if part.Transparency == 0 then
        part.Transparency = attrs.Transparency.value
      end

      part.Size = Vector3.zero

      local angle = math.rad(rng:NextNumber(rot.Min, rot.Max))

      local rx = -math.cos(angle)
      local rz = -math.sin(angle)

      local dir = originCFrame:VectorToWorldSpace(Vector3.new(rx, 0, rz))
      local right = dir:Cross(result.Normal).Unit

      local rotCF = CFrame.fromMatrix(result.Position, right, result.Normal)
        * CFrame.fromOrientation(-math.atan(drawnSize.Y / drawnSize.Z), 0, 0)

      -- per PIECE: the entry and exit phases are the offset and size rows'
      -- lanes on this piece's own clock, so one piece despawning never
      -- moves another
      local piece = mods.piece(line.events)
      local offsetIn = attrs.OffsetIn(nil, nil, piece)
      local sizeIn = attrs.SizeScaleIn(nil, nil, piece)

      -- the fade goes from where the piece rests, which a piece inheriting
      -- its hit surface knows only now
      local fade = attrs.Transparency(part.Transparency, nil, piece)

      -- where each row last put the piece, so an exit writes only what moved
      local currentOffset = offsetIn.at(0)
      local currentFactor = sizeIn.at(0)
      local currentFade = fade.at(0)

      part.Transparency = currentFade

      -- the first pose is written at once, so a reused piece never shows a
      -- frame where its last holder let it go
      part.CFrame = CFrame.new(currentOffset) * rotCF

      local sizeTween
      local fadeTween
      local offsetTween

      -- every piece carries the despawn lane, so a track is animated whether
      -- or not anything runs from the emit: only a row with a lane of the
      -- emit's own gets an in-phase stepper, or an unauthored offset would
      -- write CFrame every frame
      if offsetIn.has("start") or offsetIn.has("end") then
        offsetTween = tween.drive(scope, offsetIn, function(at: any)
          -- a queue that stops resolving partway would throw here every
          -- frame, and a stepper that throws ends the line
          if typeof(at) == "Vector3" then
            currentOffset = at
            mover.move(scope, part, CFrame.new(currentOffset) * rotCF)
          end
        end)
      end

      local size = drawnSize * currentScale

      part.Size = size * currentFactor

      if sizeIn.has("start") or sizeIn.has("end") then
        sizeTween = tween.drive(scope, sizeIn, function(factor: any)
          if typeof(factor) == "Vector3" then
            currentFactor = factor
            part.Size = size * factor
          end
        end)
      end

      if fade.has("end") then
        fadeTween = tween.drive(scope, fade, function(v: any)
          if typeof(v) == "number" then
            currentFade = v
            part.Transparency = v
          end
        end)
      end

      scope.effects.emitNested(part, scope.depth + 1, scope, outstanding, ref)

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

      local landed = lifetime.add(outstanding)

      -- the dwell's own elapsed when it ended, the moment the piece fires its
      -- despawn lane. kept every frame, since a speed that stops for good
      -- ends the dwell wherever it stood
      local fired = 0
      local dwelt = 0
      local dwell

      -- the dwell belongs to the effect rather than to the scheduler: its
      -- cleanup lives in the scope, so tearing the line down cancels it rather
      -- than firing exit tweens at a part the pool has handed on, and
      -- its length is the step's to decide, so a Lifetime a modifier is
      -- moving moves a dwell that is already running
      dwell = lifetime.step(scope, function(deltaTime: number)
        local target = life.at(dwelt)

        fired = dwelt

        if typeof(target) ~= "number" or target ~= target then
          target = drawn
        end

        if dwelt < target and not timeline.halted then
          dwelt += deltaTime
          return
        end

        dwell:Disconnect()

        task.spawn(function()
          -- a despawn that throws still lands its piece, or the emit would wait
          -- on it until the effect is torn down
          local ok, err = pcall(function()
            if sizeTween then
              sizeTween:Disconnect()
            end

            if fadeTween then
              fadeTween:Disconnect()
            end

            if offsetTween then
              offsetTween:Disconnect()
            end

            piece:fire("despawn", fired)

            local sizeReach = sizeIn.reach("despawn")
            local fadeReach = fade.reach("despawn")
            local offsetReach = offsetIn.reach("despawn")

            -- a row whose despawn lane leaves it where it stands is written
            -- once, where it stands, and the exit still runs as long as its
            -- reach says
            local sizeUntil = if sizeIn.still("despawn", fired) then 0 else sizeReach
            local fadeUntil = if fade.still("despawn", fired) then 0 else fadeReach
            local offsetUntil = if offsetIn.still("despawn", fired) then 0 else offsetReach

            -- each row is sampled until its own exit lands and never after, so
            -- a row that snaps is written once and the shorter exit stops first
            local sizeMoving = true
            local fadeMoving = true
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
                  mover.move(scope, part, CFrame.new(offset) * rotCF)
                end
              end

              if fadeMoving then
                fadeMoving = since < fadeUntil

                local v = fade.at(fired + math.min(since, fadeUntil))

                if typeof(v) == "number" and v ~= currentFade then
                  currentFade = v
                  part.Transparency = v
                end
              end
            end

            -- one stepper runs every exit over the longest of them, on the
            -- piece's clock from the fire
            local exitLength = math.max(sizeReach, offsetReach, fadeReach)

            -- a despawn lane is never cut: the emit awaits every exit, however
            -- far past the line's run it reaches. a teardown closes the body
            -- waiting on it along with the stepper, so nothing is left waiting
            if exitLength > 0 then
              tween.play(scope, curve.new(exitLength, "linear"), function(_, _, elapsed: number)
                -- a sample that throws would throw every frame and hold
                -- the emit until teardown, so it ends the exit instead
                local sampled, problem = pcall(exitAt, elapsed)

                if not sampled then
                  logger.warn(`a piece's exit stopped: {problem}`)
                  return false
                end

                return true
              end, nil, lifetime.add(outstanding))
            else
              exitAt(0)
            end

            scope.effects.emitOnFinish(emitOnFinish, part, scope.depth + 1, scope, outstanding)
          end)

          landed()

          if not ok then
            logger.warn(`a piece failed to despawn: {err}`)
          end
        end)
      end)
    end

    last %= threshold
  end

  -- the sweep ends on the first frame that starts at or past its duration, a
  -- frame after the summed deltas reach it, and that frame's time still counts
  -- toward a piece. the play has a second's grace to outlast it
  local clocked = 0
  local grace = duration + 1

  -- the emission runs on the effect's clock too, so a speed knob spaces the
  -- pieces out and shortens the line's run by the same factor
  tween.play(scope, curve.new(grace, "linear"), function(_, deltaTime: number, elapsed: number)
    local closing = clocked >= duration or elapsed >= grace

    clocked = math.min(clocked + deltaTime, duration)

    emitFrame(deltaTime, closing)

    return not closing
  end, scope.depth)

  -- the hold runs on the clock the dwells do, or a speed below one stretches
  -- them past it and the scope tears down mid dwell. the transparency exit is
  -- one of the three a dwell starts, so it counts here too
  tween.wait(scope, curve.new(runLength, "linear"))

  lifetime.awaitJoin(outstanding)
end

-- a piece is authored resting on its origin, so what the panel shows is what
-- the sweep starts from; the origin is the shockwave attachment two levels up
function line.selected(ctx: reader.Ctx)
  local piece = ctx.ref :: BasePart
  local folder = piece.Parent
  local origin = if folder ~= nil then folder.Parent else nil

  if origin == nil or not origin:IsA("Attachment") then
    return
  end

  piece.Anchored = true
  piece.CFrame = origin.WorldCFrame
end

return line
