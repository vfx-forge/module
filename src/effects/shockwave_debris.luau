local CollectionService = game:GetService("CollectionService")

local mod = require("@mod/mod")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local adapters = require("@mod/adapters")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")

local Shockwave = require("@vfx/shockwave")

local ObjectCache = require("@obj/ObjectCache")

local rng = Random.new()

local function always()
  return true
end

-- the exit is the despawn lane's default on SizeScale, and the shrink rows say
-- where it goes, for how long and how
local function shrinkEnd(_, attrs: any)
  return attrs.ShrinkScale
end

local function shrinkDuration(_, attrs: any)
  return attrs.ShrinkDuration
end

local function shrinkCurve(_, attrs: any)
  return attrs.ShrinkCurve
end

local function transparencyDuration(_, attrs: any)
  return attrs.TransparencyDuration
end

local debris = {}

debris.id = "shockwave_debris"
debris.display = { name = "Shockwave Debris", icon = "shockwave_debris", order = 53 }
debris.classifier = ".Shockwave > #Debris > BasePart"
debris.components = "Instance"
debris.events = { "despawn" }

-- no Speed row. debris flies under physics impulses, so a speed multiplier
-- would scale the dwell and the shrink and leave the flight alone, which reads
-- worse than having no knob at all
debris.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("EmitDelay"):hint("Seconds before the effect starts emitting."),
  Amount = knob(NumberRange.new(5, 10)):min(0):label("Amount"):hint("Random range for how many debris pieces spawn."),
  Lifetime = knob(NumberRange.new(2, 3))
    :min(0)
    :unit("seconds")
    :mod()
    :label("Lifetime")
    :hint("How long each debris piece lives, in seconds."),
  Airtime = knob(NumberRange.new(0.5, 0.5))
    :min(0)
    :unit("seconds")
    :label("Airtime")
    :hint("Target time-of-flight used to compute launch impulse, in seconds."),
  LinearMagnitude = knob(NumberRange.new(15, 25))
    :unit("studsPerSecond")
    :label("Linear")
    :hint("Random range for each piece's launch impulse strength."),
  AngularMagnitude = knob(NumberRange.new(5, 15))
    :label("Angular")
    :hint("Random range for each piece's spin impulse strength."),
  InheritanceEnabled = knob(true)
    :label("Enabled")
    :hint("Whether nearby parts can donate their look to spawned debris."),
  InheritanceRadius = knob(5)
    :unit("studs")
    :label("Radius")
    :hint("Studs around the origin searched for parts to inherit from."),
  InheritanceMaxResults = knob(5):label("MaxResults"):hint("Maximum parts collected by the inheritance overlap query."),
  MinDirection = knob(-vector.one):label("Min"):hint("Lower per-axis bound for each piece's random launch direction."),
  MaxDirection = knob(vector.one):label("Max"):hint("Upper per-axis bound for each piece's random launch direction."),
  Size = knob(vector.create(2.5, 1.5, 2.5))
    :unit("studs")
    :mod()
    :label("Size")
    :hint("Size drawn for each piece, in studs."),
  SizeScale = knob(vector.one)
    :mod(mod.to(shrinkEnd):duration(shrinkDuration):curve(shrinkCurve):lane("despawn"))
    :label("Scale")
    :hint("Size factor on each piece; its despawn lane runs the shrink."),
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
  ShrinkCurve = knob(function()
      return utility.default_bezier
    end)
    :aliases("SizeScaleOut_Curve", "Size_End_Curve", "Size_Curve")
    :label("Curve")
    :hint("Easing of the shrink."),
  Transparency = knob(0)
    :aliases("Transparency_Start")
    :mod(mod.to(1):duration(transparencyDuration))
    :label("Transparency")
    :hint("Transparency applied to spawned debris without an inherited surface."),
  -- the span the old fade ran over, read under its old name when nothing else
  -- was authored, and kept as a row so retime reaches it
  TransparencyDuration = knob(0.5):min(0):aliases("Transparency_Duration"):unit("seconds"):hidden(always),
}

debris.properties = {}

debris.layout = {
  { title = "Emit", entries = { "EmitDelay" } },
  { title = "Transparency", entries = { "Transparency" } },
  "Amount",
  "Lifetime",
  "Airtime",
  {
    title = "Inheritance",
    entries = {
      "InheritanceEnabled",
      "InheritanceRadius",
      "InheritanceMaxResults",
      { action = "toggle_paths", label = "Show Paths" },
    },
  },
  { title = "Magnitude", entries = { "LinearMagnitude", "AngularMagnitude" } },
  {
    title = "Size",
    entries = { "Size", "SizeScale", "ShrinkScale", { curve = "ShrinkCurve", duration = "ShrinkDuration" } },
  },
  { title = "Direction", entries = { "MinDirection", "MaxDirection" } },
}

-- the dwell's ceiling: a piece's own lifetime is drawn below it, and a queue
-- naming no duration runs over it
function debris.duration(_, attrs: any)
  return attrs.Lifetime.value.Max
end

local physicsParts = {}

local part_cache: ObjectCache.ObjectCache?
local physicsStepper: scheduler.Handle?

function debris.init(cache)
  if physicsStepper then
    return
  end

  part_cache = cache

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

function debris.deinit()
  if physicsStepper then
    physicsStepper:Disconnect()
    physicsStepper = nil
  end

  part_cache = nil

  for _, part in physicsParts do
    part:Destroy()
  end

  table.clear(physicsParts)
end

function debris.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: Part
  local scope = ctx.scope
  local origin = utility.findFirstClassWithTag(ref, "Attachment", utility.SHOCKWAVE_TAG)

  if not part_cache or not origin then
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
      params:AddToFilter({ workspace.Terrain })
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
  -- the fade or the despawn lane, whichever is longer. a resting fade holds
  -- nothing open. the fire lends the lane this length, so an entry on it
  -- naming no duration runs out the exit rather than what is left of the
  -- dwell ceiling
  local fadeDuration = if attrs.Transparency.animated then attrs.Transparency.duration else 0
  local exitLength = math.max(fadeDuration, attrs.SizeScale.reach("despawn"))

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

    local id = utility.getRandomId()

    local part = part_cache:get(id)

    local realPart = part._getReal() :: BasePart

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
    local emitOnImpact = scope.effects.prepareEmitFolder(realPart, "EmitOnImpact", scope)

    if emitOnImpact and #emitOnImpact:GetChildren() > 0 then
      local conn
      conn = realPart.Touched:Connect(function(hit)
        if
          (not rayIgnoreCanCollide and not hit:CanCollideWith(realPart)) -- ignore parts we can't collide with if they can be ignored
          or hit:IsDescendantOf(workspace.Terrain) -- ignore all debris parts/other effects
          or (rayFilterType == "Exclude" and hit:HasTag(rayFilterTag)) -- ignore all excluded tags
        then
          return
        end

        conn:Disconnect()

        scope.effects.emitFromFolder(emitOnImpact, realPart, scope.depth + 1, scope, outstanding)
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
      scaleTween = tween.fromParams(utility.linear_bezier, sizeScale.duration, function(_, deltaTime, elapsed)
        local factor = sizeScale.at(elapsed)

        if typeof(factor) == "Vector3" then
          local changed = factor ~= currentFactor

          currentFactor = factor
          part.Size = size * factor

          if changed then
            resized(realPart)
          end
        end

        return deltaTime
      end)

      lifetime.hold(scope, scaleTween)
    end

    if iref then
      part.Material = iref.Material
      part.Color = iref.Color
      part.Transparency = iref.Transparency
    else
      part.Transparency = fadeSeed
    end

    -- the fade a piece runs after its dwell continues from where the piece
    -- rests, which a piece inheriting a nearby part knows only now. a framed
    -- queue names its own start and is taken at its word
    local fade = attrs.Transparency(part.Transparency)

    part.Transparency = fade.at(0)

    lifetime.hold(scope, function()
      local index = table.find(physicsParts, realPart)

      if index then
        table.remove(physicsParts, index)
      end

      if part_cache then
        part_cache:free(id)
      end
    end)

    table.insert(physicsParts, realPart)

    part.AssemblyLinearVelocity = originCFrame:VectorToWorldSpace(part.AssemblyLinearVelocity)

    local relDir = utility.randomUnitVector(minDir, maxDir)
    local worldDir = originCFrame:VectorToWorldSpace(relDir)

    part:ApplyImpulse(
      part.AssemblyMass
        * utility.getImpulseForce(
          originPosition,
          originPosition + worldDir.Unit * rng:NextNumber(linmag.Min, linmag.Max),
          rng:NextNumber(airtime.Min, airtime.Max)
        )
    )

    part:ApplyAngularImpulse(part.AssemblyMass * rng:NextUnitVector() * rng:NextNumber(angmag.Min, angmag.Max))

    launch(realPart)

    scope.effects.emitNested(realPart, scope.depth + 1, scope, outstanding)

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

    -- the dwell belongs to the effect rather than to the scheduler: its cleanup
    -- lives in the scope, so tearing the field down cancels it rather than
    -- firing an exit at a pooled part the cache has already handed on, and its
    -- length is the counter's to decide
    tween.after(math.huge, function(deltaTime, elapsed)
      local target = life.at(elapsed)

      if typeof(target) ~= "number" or target ~= target then
        target = drawn
      end

      if elapsed >= target then
        fired = elapsed
        return nil :: any
      end

      return deltaTime
    end, function()
      task.spawn(function()
        -- a despawn that throws still lands its piece, or the emit would wait
        -- on it until the effect is torn down
        local ok, err = pcall(function()
          if scaleTween then
            scaleTween:Disconnect()
          end

          piece:fire("despawn", fired, exitLength)

          -- the emit's exit, or longer for a piece whose lane drew its own
          -- length. a no-duration entry runs out the exit the fire lent it,
          -- which can outlast the lane's own reach, so the whole of it is
          -- sampled
          local length = math.max(exitLength, sizeScale.reach("despawn"))

          -- a lane that leaves the size where it stands is written once, where
          -- it stands, and sampled until it lands and never after
          local sizeUntil = if sizeScale.still("despawn", fired) then 0 else length
          local sizeMoving = true

          local function exitAt(since: number)
            if not sizeMoving then
              return
            end

            sizeMoving = since < sizeUntil

            local factor = sizeScale.at(fired + math.min(since, sizeUntil))

            if typeof(factor) == "Vector3" and factor ~= currentFactor then
              currentFactor = factor
              part.Size = size * factor
              resized(realPart)
            end
          end

          -- a despawn lane is never cut: the emit awaits every exit as well as
          -- the wait below, which a piece's own draws could outlast. a teardown
          -- closes the body waiting on it along with the stepper
          if length > 0 then
            local exited = lifetime.add(outstanding)

            lifetime.hold(
              scope,
              tween.fromParams(utility.linear_bezier, length, function(_, deltaTime, elapsed)
                -- a sample that throws would throw every frame and hold the
                -- emit until teardown, so it ends the exit instead
                local sampled, problem = pcall(exitAt, elapsed)

                if not sampled then
                  logger.warn(`a piece's exit stopped: {problem}`)
                  return nil
                end

                return deltaTime
              end, nil, exited)
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

                return deltaTime
              end)
            )
          end

          scope.effects.emitOnFinish(emitOnFinish, realPart, scope.depth + 1, scope, outstanding)
        end)

        landed()

        if not ok then
          logger.warn(`a piece failed to despawn: {err}`)
        end
      end)
    end, scope)
  end

  lifetime.wait(scope, lifeMax + exitLength)

  lifetime.awaitJoin(outstanding)
end

-- a piece is authored resting on its origin, so what the panel shows is what
-- the sweep starts from; the origin is the shockwave attachment two levels up
function debris.selected(ctx: reader.Ctx)
  local piece = ctx.ref :: BasePart
  local folder = piece.Parent
  local origin = if folder ~= nil then folder.Parent else nil

  if origin == nil or not origin:IsA("Attachment") then
    return
  end

  piece.Anchored = true
  piece.CFrame = origin.WorldCFrame
end

return debris
