local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local mod = require("@mod/mod")
local knob = require("@mod/knob")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")

local Promise = require("@pkg/Promise")
local ObjectCache = require("@obj/ObjectCache")

local rng = Random.new()

local debris = {}

debris.id = "shockwave_debris"
debris.display = { name = "Shockwave Debris", icon = "shockwave_debris", order = 62 }
debris.classifier = ".Shockwave > #Debris > BasePart"
debris.components = "Instance"

-- no Speed row. debris flies under physics impulses, so a speed multiplier
-- would scale the dwell and the shrink and leave the flight alone, which reads
-- worse than having no knob at all
debris.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"),
  Amount = knob(NumberRange.new(5, 10)):min(0),
  Lifetime = knob(NumberRange.new(2, 3)):min(0):unit("seconds"):mod(),
  Airtime = knob(NumberRange.new(0.5, 0.5)):min(0):unit("seconds"),
  LinearMagnitude = knob(NumberRange.new(15, 25)),
  AngularMagnitude = knob(NumberRange.new(5, 15)),
  InheritanceEnabled = knob(true),
  InheritanceRadius = knob(5):unit("studs"),
  InheritanceMaxResults = knob(5),
  MinDirection = knob(-vector.one),
  MaxDirection = knob(vector.one),
  Size = knob(vector.create(2.5, 1.5, 2.5)):unit("studs"):mod(),
  ShrinkScale = knob(vector.zero):aliases("SizeScaleOut_End", "SizeScaleEnd"),
  ShrinkDuration = knob(0.5)
    :min(0)
    :aliases("SizeScaleOut_Duration", "Size_End_Duration", "Size_Duration")
    :unit("seconds"),
  ShrinkCurve = knob(function()
    return utility.default_bezier
  end):aliases("SizeScaleOut_Curve", "Size_End_Curve", "Size_Curve"),
  Transparency = knob(0):aliases("Transparency_Start"):mod(mod.to(1):duration(0.5)),
}

debris.properties = {}

debris.layout = {
  { title = "Emit", entries = { "EmitDelay", "Amount", "Lifetime", "Airtime" } },
  { title = "Launch", entries = { "LinearMagnitude", "AngularMagnitude", "MinDirection", "MaxDirection" } },
  { title = "Look", entries = { "Size", "Transparency", "ShrinkScale", "ShrinkDuration", "ShrinkCurve" } },
  {
    title = "Inheritance",
    entries = {
      "InheritanceEnabled",
      "InheritanceRadius",
      "InheritanceMaxResults",
      { action = "toggle_paths", label = "Show Paths" },
    },
  },
}

-- the dwell's ceiling: a piece's own lifetime is drawn below it, and a queue
-- naming no duration runs over it
function debris.duration(_, attrs: any)
  return attrs.Lifetime.value.Max
end

local physicsParts = {}

local part_cache: ObjectCache.ObjectCache?
local physicsStepper: RBXScriptConnection?

function debris.init(cache)
  if physicsStepper then
    return
  end

  part_cache = cache

  if utility.PLUGIN_CONTEXT then
    physicsStepper = RunService.RenderStepped:Connect(function(deltaTime)
      if #physicsParts == 0 then
        return
      end

      workspace:StepPhysics(deltaTime, physicsParts)
    end)
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

  local originAttrs = registry.read(origin)

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

  local shrinkTo = attrs.ShrinkScale
  local shrinkCurve = attrs.ShrinkCurve
  local shrinkDuration = attrs.ShrinkDuration

  local lifeMax = attrs.Lifetime.value.Max
  local fadeSeed = attrs.Transparency.value

  local count = rng:NextInteger(amount.Min, amount.Max)

  local partData = {}
  local promises = {}

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

  task.wait(attrs.EmitDelay)

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

        local env = scope.effects.emitFromFolder(emitOnImpact, realPart, scope.depth + 1, scope)
        table.insert(promises, env.Finished)
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

    part.Size = size

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

    local env = scope.effects.emitNested(realPart, scope.depth + 1, scope)
    table.insert(promises, env.Finished)

    -- a piece's own dwell, drawn from the row's range, sampled on the piece's
    -- clock so a modifier moving the row moves a dwell already running
    local life = attrs.Lifetime()
    local drawn = life.at(0)

    -- a NaN lifetime satisfies no comparison, so elapsed >= target is false for
    -- ever and the piece dwells for the life of the session
    if typeof(drawn) ~= "number" or drawn ~= drawn then
      drawn = rng:NextNumber(attrs.Lifetime.value.Min, lifeMax)
    end

    -- the dwell belongs to the effect rather than to the scheduler: its cleanup
    -- lives in the scope, so tearing the field down cancels it rather than
    -- firing a shrink at a pooled part the cache has already handed on, and its
    -- length is the counter's to decide
    tween.after(math.huge, function(deltaTime, elapsed)
      local target = life.at(elapsed)

      if typeof(target) ~= "number" or target ~= target then
        target = drawn
      end

      if elapsed >= target then
        return nil :: any
      end

      return deltaTime
    end, function()
      task.spawn(function()
        local startSize = part.Size

        if startSize ~= size * shrinkTo then
          lifetime.hold(
            scope,
            tween.fromParams(shrinkCurve, shrinkDuration, function(alpha, deltaTime)
              part.Size = startSize:Lerp(size * shrinkTo, alpha)
              return deltaTime
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

              return deltaTime
            end)
          )
        end

        local env = scope.effects.emitOnFinish(emitOnFinish, realPart, scope.depth + 1, scope)
        table.insert(promises, env.Finished)
      end)
    end, scope)
  end

  -- a resting fade holds the emit open for nothing: it only reaches past the
  -- last piece's life when it moves
  local fadeDuration = if attrs.Transparency.animated then attrs.Transparency.duration else 0

  task.wait(lifeMax + math.max(fadeDuration, shrinkDuration))

  Promise.all(promises):await()
end

return debris
