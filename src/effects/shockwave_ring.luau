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
  -- the entry phases rest where the old defaults left them: the offset where
  -- it stands, the size on a rise from nothing to the drawn size. the fade
  -- runs only once a piece despawns, from where it rests to the end, so the
  -- row plays from that lane alone. the spans the old quads ran over are rows
  -- of their own, so the defaults keep them and retime reaches them
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

ring.properties = {}

ring.layout = {
  { title = "Emit", entries = { "EmitDelay", "Speed" } },
  { title = "Ring", entries = { "Radius", "Segments", "Lifetime" } },
  { title = "Size", entries = { "MinSize", "MaxSize" } },
  { title = "Settle", entries = { "OffsetIn", "SizeScaleIn", "Transparency" } },
}

-- the longest a segment can last, which is the ring's own clock: the longest
-- dwell it can draw, then the longest exit it can run
function ring.duration(_, attrs: any)
  return attrs.Lifetime.value.Max + math.max(attrs.ShrinkDuration, attrs.OffsetOutDuration, attrs.TransparencyDuration)
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

  if not origin then
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

  -- a Speed resting at 0 for good ends every tween and dwell, and with them
  -- the run, rather than holding the parts out of the pool for ever. a speed
  -- that is merely 0 for now, as a queue reads during a leading delay, does
  -- not
  local timeline = scope.clock

  lifetime.wait(scope, attrs.EmitDelay)

  lifetime.speed(scope, attrs.Speed)

  -- a piece counts from its dwell until its exit and its on-finish emit are
  -- counted in, and a nested emit until it ends, so the wait at the end sees
  -- a dwell that ends on the timer's own frame and an emit started after it
  local outstanding = lifetime.join(scope)

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

    local part = pool.take(scope, ref) :: BasePart

    local emitOnFinish = scope.effects.prepareEmitOnFinish(part, scope)

    part.Color = result.Instance.Color
    part.Material = result.Material
    part.Transparency = result.Instance.Transparency

    -- an opaque surface leaves the piece where the row rests
    if part.Transparency == 0 then
      part.Transparency = attrs.Transparency.value
    end

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

    -- the fade goes from where the segment rests, which a segment inheriting
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

    -- every piece carries the despawn lane, so a track is animated whether or
    -- not anything runs from the emit: only a row with a lane of the emit's
    -- own gets an in-phase stepper, or an unauthored offset would write
    -- CFrame every frame
    if offsetIn.has("start") or offsetIn.has("end") then
      offsetTween = tween.drive(scope, offsetIn, function(at: any)
        -- a queue that stops resolving partway would throw here every frame,
        -- and a stepper that throws ends the ring
        if typeof(at) == "Vector3" then
          currentOffset = at
          mover.move(scope, part, CFrame.new(currentOffset) * rotCF)
        end
      end)
    end

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

    scope.effects.emitNested(part, scope.depth + 1, scope, outstanding)

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

    local landed = lifetime.add(outstanding)

    -- the dwell's own elapsed when it ended, the moment the piece fires its
    -- despawn lane. kept every frame, since a speed that stops for good ends
    -- the dwell wherever it stood
    local fired = 0
    local dwelt = 0
    local dwell

    -- the dwell is part of the effect, not of the scheduler: its cleanup lives
    -- in the scope, so tearing the effect down cancels it rather than letting it
    -- fire into a part the pool has already handed to someone else, and it runs
    -- on the effect's clock, so speed scales it. its length is the step's to
    -- decide, so a Lifetime a modifier is moving is read every frame
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

          -- a row whose despawn lane leaves it where it stands is written once,
          -- where it stands, and the exit still runs as long as its reach says
          local sizeUntil = if sizeIn.still("despawn", fired) then 0 else sizeReach
          local fadeUntil = if fade.still("despawn", fired) then 0 else fadeReach
          local offsetUntil = if offsetIn.still("despawn", fired) then 0 else offsetReach

          -- each row is sampled until its own exit lands and never after, so a row
          -- that snaps is written once and the shorter exit stops first
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

          -- one stepper runs every exit over the longest of them, on the piece's
          -- clock from the fire
          local exitLength = math.max(sizeReach, offsetReach, fadeReach)

          -- a despawn lane is never cut: the emit awaits every exit, however far
          -- past the ring's run it reaches. a teardown closes the body waiting on
          -- it along with the stepper, so nothing is left waiting
          if exitLength > 0 then
            tween.play(scope, curve.new(exitLength, "linear"), function(_, _, elapsed: number)
              -- a sample that throws would throw every frame and hold the
              -- emit until teardown, so it ends the exit instead
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

  -- the hold has to run on the same clock the dwells do, or a speed below one
  -- stretches them past it and the scope tears down mid dwell
  tween.wait(scope, curve.new(runLength, "linear"))

  lifetime.awaitJoin(outstanding)
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
