local CollectionService = game:GetService("CollectionService")

local mods = require("@mod/mods")
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local adapters = require("@mod/adapters")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")

local Shockwave = require("@vfx/shockwave")

local pool = require("@srv/pool")
local containers = require("@srv/containers")

local rng = Random.new()

local physicsParts = {}

local physicsStepper: scheduler.Handle?

local debris: any = nil

local play = {}

function play.init()
  if physicsStepper then
    return
  end

  if utility.PLUGIN_CONTEXT then
    physicsStepper = scheduler.add("compute", function(deltaTime: number)
      if #physicsParts == 0 then
        return
      end

      local parts = physicsParts

      -- a part deleted before its release takes it off the list makes
      -- StepPhysics throw, so it is left out until then
      for _, part in physicsParts do
        if part.Parent then
          continue
        end

        parts = {}

        for _, kept in physicsParts do
          if kept.Parent then
            table.insert(parts, kept)
          end
        end

        break
      end

      if #parts == 0 then
        return
      end

      workspace:StepPhysics(deltaTime, parts)
    end, 0, nil, true)
  end
end

function play.deinit()
  if physicsStepper then
    physicsStepper:Disconnect()
    physicsStepper = nil
  end

  for _, part in physicsParts do
    part:Destroy()
  end

  table.clear(physicsParts)
end

function play.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: Part
  local scope = ctx.scope
  local origin = utility.findFirstClassWithTag(ref, "Attachment", utility.SHOCKWAVE_TAG)

  if not origin then
    return
  end

  local params

  local originAttrs = registry.read(origin, Shockwave)

  if originAttrs == nil then
    return
  end

  local rayColGroup = originAttrs.RayCollisionGroup

  local rayFilterTag = originAttrs.FilterTag
  local rayFilterType = originAttrs.FilterType

  local rayIgnoreCanCollide = originAttrs.IgnoreCanCollide

  if attrs.InheritanceEnabled then
    params = OverlapParams.new()
    params.MaxParts = attrs.InheritanceMaxResults
    params.CollisionGroup = rayColGroup
    params.RespectCanCollide = not rayIgnoreCanCollide
    params.FilterType = Enum.RaycastFilterType[rayFilterType]
    params.FilterDescendantsInstances = CollectionService:GetTagged(rayFilterTag)

    if rayFilterType == "Exclude" then
      params:AddToFilter({ containers.root() })
    end
  end

  local amount = attrs.Amount
  local airtime = attrs.Airtime

  local linmag = attrs.LinearMagnitude
  local angmag = attrs.AngularMagnitude

  local minDir = attrs.MinDirection
  local maxDir = attrs.MaxDirection

  local lifeMax = attrs.Lifetime.value.Max
  local fadeSeed = attrs.Transparency.value

  -- the exit every piece runs after its dwell, which the emit waits out too:
  -- the longer of the two despawn lanes. a resting fade holds nothing open.
  -- the fire lends the lanes this length, so an entry on one naming no
  -- duration runs out the exit rather than what is left of the dwell ceiling
  local fadeLength = if attrs.Transparency.animated then attrs.Transparency.reach("despawn") else 0
  local exitLength = math.max(fadeLength, attrs.SizeScale.reach("despawn"))

  local count = rng:NextInteger(amount.Min, amount.Max)

  local partData = {}

  -- a piece counts from its dwell until its exit and its on-finish emit are
  -- counted in, and a nested emit until it ends, so the wait at the end sees
  -- a dwell that ends on the wait's own frame and an emit started after it
  local outstanding = lifetime.join(scope)

  ref.CanCollide = false

  local originCFrame = utility.getTransformedOriginExtents(origin)
  local originPosition = originCFrame.Position

  if params then
    local parts = workspace:GetPartBoundsInRadius(originPosition, attrs.InheritanceRadius, params)

    for _, p in parts do
      if p.Transparency == 1 then
        continue
      end

      table.insert(partData, p)
    end
  end

  lifetime.wait(scope, attrs.EmitDelay)

  -- the flight follows the effect's clock through the launch and a force
  local launch, resized = adapters.debris(scope)

  for _ = 1, count do
    local iref = #partData ~= 0 and partData[rng:NextInteger(1, #partData)]

    local part = pool.take(scope, ref) :: BasePart

    local emitOnFinish = scope.effects.prepareEmitOnFinish(part, scope)
    local emitOnImpact = scope.effects.prepareEmitFolder(part, "EmitOnImpact", scope)

    if emitOnImpact and #emitOnImpact:GetChildren() > 0 then
      local conn
      conn = part.Touched:Connect(function(hit)
        if
          (not rayIgnoreCanCollide and not hit:CanCollideWith(part)) -- ignore parts we can't collide with if they can be ignored
          or hit:IsDescendantOf(workspace.Terrain) -- ignore all debris parts/other effects
          or (rayFilterType == "Exclude" and hit:HasTag(rayFilterTag)) -- ignore all excluded tags
        then
          return
        end

        conn:Disconnect()

        scope.effects.emitFromFolder(emitOnImpact, part, scope.depth + 1, scope, outstanding)
      end)

      lifetime.hold(scope, function()
        if conn then
          conn:Disconnect()
          conn = nil
        end
      end)
    end

    part.Anchored = false
    part.CanCollide = true

    if part.CollisionGroup == "Default" then
      part.CollisionGroup = "ForgeDebris"
    end

    part.CFrame = CFrame.new(originPosition)

    -- per PIECE: the row is called again so a drawn size is this piece's own
    local size = attrs.Size().at(0)

    -- per PIECE: the exit is the SizeScale row's despawn lane on this piece's
    -- own clock, so one piece despawning never moves another
    local piece = mods.piece(debris.events)
    local sizeScale = attrs.SizeScale(nil, nil, piece)

    -- where the row last put the piece, so the exit writes only what moved
    local currentFactor = sizeScale.at(0)

    part.Size = size * currentFactor

    local scaleTween

    -- every piece carries the despawn lane, so the track is animated whether
    -- or not anything runs during the dwell: only a lane of the emit's own
    -- gets a stepper, or an unauthored factor would write Size every frame
    if sizeScale.has("start") or sizeScale.has("end") then
      scaleTween = tween.drive(scope, sizeScale, function(factor: any)
        if typeof(factor) == "Vector3" then
          local changed = factor ~= currentFactor

          currentFactor = factor
          part.Size = size * factor

          if changed then
            resized(part)
          end
        end
      end)
    end

    if iref then
      part.Material = iref.Material
      part.Color = iref.Color
      part.Transparency = iref.Transparency
    else
      part.Transparency = fadeSeed
    end

    -- the fade continues from where the piece rests, which a piece inheriting
    -- a nearby part knows only now
    local fade = attrs.Transparency(part.Transparency, nil, piece)
    local currentFade = fade.at(0)

    part.Transparency = currentFade

    local fadeTween

    if fade.has("end") then
      fadeTween = tween.drive(scope, fade, function(v: any)
        if typeof(v) == "number" then
          currentFade = v
          part.Transparency = v
        end
      end)
    end

    lifetime.hold(scope, function()
      local index = table.find(physicsParts, part)

      if index then
        table.remove(physicsParts, index)
      end
    end)

    table.insert(physicsParts, part)

    part.AssemblyLinearVelocity = originCFrame:VectorToWorldSpace(part.AssemblyLinearVelocity)

    local relDir = utility.randomUnitVector(minDir, maxDir)
    local worldDir = originCFrame:VectorToWorldSpace(relDir)

    local impulse = part.AssemblyMass
      * utility.getImpulseForce(
        originPosition,
        originPosition + worldDir.Unit * rng:NextNumber(linmag.Min, linmag.Max),
        rng:NextNumber(airtime.Min, airtime.Max)
      )

    local spin = part.AssemblyMass * rng:NextUnitVector() * rng:NextNumber(angmag.Min, angmag.Max)

    launch(part, impulse, spin)

    scope.effects.emitNested(part, scope.depth + 1, scope, outstanding)

    -- a piece's own dwell, drawn from the row's range, sampled on the piece's
    -- clock so a modifier moving the row moves a dwell already running
    local life = attrs.Lifetime()
    local drawn = life.at(0)

    -- a NaN lifetime satisfies no comparison, so elapsed >= target is false for
    -- ever and the piece dwells for the life of the session
    if typeof(drawn) ~= "number" or drawn ~= drawn then
      drawn = rng:NextNumber(attrs.Lifetime.value.Min, lifeMax)
    end

    local landed = lifetime.add(outstanding)

    -- the dwell's own elapsed when it ended, the moment the piece fires its
    -- despawn lane
    local fired = 0
    local dwelt = 0
    local dwell

    -- the dwell belongs to the effect rather than to the scheduler: its cleanup
    -- lives in the scope, so tearing the field down cancels it rather than
    -- firing an exit at a part the pool has already handed on, and its
    -- length is the step's to decide
    dwell = lifetime.step(scope, function(deltaTime: number)
      local target = life.at(dwelt)

      if typeof(target) ~= "number" or target ~= target then
        target = drawn
      end

      if dwelt < target then
        dwelt += deltaTime
        return
      end

      fired = dwelt
      dwell:Disconnect()

      task.spawn(function()
        -- a despawn that throws still lands its piece, or the emit would wait
        -- on it until the effect is torn down
        local ok, err = pcall(function()
          if scaleTween then
            scaleTween:Disconnect()
          end

          if fadeTween then
            fadeTween:Disconnect()
          end

          piece:fire("despawn", fired, exitLength)

          -- the emit's exit, or longer for a piece whose lanes drew their own
          -- length. a no-duration entry runs out the exit the fire lent it,
          -- which can outlast the lane's own reach, so the whole of it is
          -- sampled
          local length = math.max(exitLength, sizeScale.reach("despawn"), fade.reach("despawn"))

          -- a lane that leaves its row where it stands is written once, where
          -- it stands, and each is sampled until it lands and never after
          local sizeUntil = if sizeScale.still("despawn", fired) then 0 else length
          local fadeUntil = if fade.still("despawn", fired) then 0 else length
          local sizeMoving = true
          local fadeMoving = true

          local function exitAt(since: number)
            if sizeMoving then
              sizeMoving = since < sizeUntil

              local factor = sizeScale.at(fired + math.min(since, sizeUntil))

              if typeof(factor) == "Vector3" and factor ~= currentFactor then
                currentFactor = factor
                part.Size = size * factor
                resized(part)
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

          -- a despawn lane is never cut: the emit awaits every exit as well as
          -- the wait below, which a piece's own draws could outlast. a teardown
          -- closes the body waiting on it along with the stepper
          if length > 0 then
            tween.play(scope, curve.new(length, "linear"), function(_, _, elapsed: number)
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

  lifetime.wait(scope, lifeMax + exitLength)

  lifetime.awaitJoin(outstanding)
end

function play.bind(module: any)
  debris = module

  return play
end

return play
