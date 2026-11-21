local CollectionService = game:GetService("CollectionService")

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

local ring: any = nil

local play = {}

function play.emit(ctx: reader.Ctx, attrs: any)
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

    part.Color = utility.surfaceColor(result)
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

function play.bind(module: any)
  ring = module

  return play
end

return play
