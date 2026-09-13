local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")

local Promise = require("@pkg/Promise")
local ObjectCache = require("@obj/ObjectCache")

local rng = Random.new()

local debris = {}

-- both are driven here, so the applier must not drive them as well: their legacy
-- attributes are a NumberRange and a Min/Max pair, and an applier writing a
-- sample back would replace the range with a scalar.
--
-- no Speed. debris flies under physics impulses, so a speed multiplier would
-- scale the dwell and the shrink and leave the flight alone, which reads worse
-- than having no knob at all
debris.OWNS = {
  attribute = {
    Size = true,
    Lifetime = true,
  },
}

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

function debris.emit(origin: Attachment, ref: Part, scope: types.scope)
  if not part_cache then
    return
  end

  local params

  local inherit = attr.get(ref, "InheritanceEnabled", true)
  local inheritRadius = attr.get(ref, "InheritanceRadius", 5)

  local rayColGroup = attr.get(origin, "RayCollisionGroup", "Default")

  local rayFilterTag = attr.get(origin, "FilterTag", "")
  local rayFilterType = attr.get(origin, "FilterType", "Exclude")

  local rayIgnoreCanCollide = attr.get(origin, "IgnoreCanCollide", false)

  if inherit then
    local inheritMaxResults = attr.get(ref, "InheritanceMaxResults", 5)

    params = OverlapParams.new()
    params.MaxParts = inheritMaxResults
    params.CollisionGroup = rayColGroup
    params.RespectCanCollide = not rayIgnoreCanCollide
    params.FilterType = Enum.RaycastFilterType[rayFilterType]
    params.FilterDescendantsInstances = CollectionService:GetTagged(rayFilterTag)

    if rayFilterType == "Exclude" then
      params:AddToFilter({ workspace.Terrain })
    end
  end

  local emitDelay = attr.get(ref, "EmitDelay", 0)

  local amount = attr.getRange(ref, "Amount", NumberRange.new(5, 10), NumberRange.new(0, math.huge))
  local lifeRange = attr.getRange(ref, "Lifetime", NumberRange.new(2, 3), NumberRange.new(0, math.huge))
  local airtime = attr.getRange(ref, "Airtime", NumberRange.new(0.5, 0.5), NumberRange.new(0, math.huge))

  local linmag = attr.getRange(ref, "LinearMagnitude", NumberRange.new(15, 25))
  local angmag = attr.getRange(ref, "AngularMagnitude", NumberRange.new(5, 15))

  -- one phase, so one row: the shrink after the dwell. the old name is read soft
  -- as the new one's default, so content in the wild keeps working
  local sizeOutEnd = attr.get(ref, "SizeScaleOut_End", attr.get(ref, "SizeScaleEnd", vector.zero, true))

  local minSize = attr.get(ref, "MinSize", vector.create(2, 1, 2))
  local maxSize = attr.get(ref, "MaxSize", vector.create(3, 2, 3))

  local minDir = attr.get(ref, "MinDirection", -vector.one)
  local maxDir = attr.get(ref, "MaxDirection", vector.one)

  local count = rng:NextInteger(amount.Min, amount.Max)

  local sizeCurve = attr.get(ref, "SizeScaleOut_Curve", attr.get(ref, "Size_Curve", utility.default_bezier, true))
  local tpCurve = attr.get(ref, "Transparency_Curve", utility.default_bezier)

  local tpDuration = attr.get(ref, "Transparency_Duration", 0.5)
  local sizeDuration = attr.get(ref, "SizeScaleOut_Duration", attr.get(ref, "Size_Duration", 0.5, true))

  local tpStart = attr.get(ref, "Transparency_Start", 0)
  local tpEnd = attr.get(ref, "Transparency_End", 1)

  local partData = {}
  local promises = {}

  ref.CanCollide = false

  local originCFrame = utility.getTransformedOriginExtents(origin)
  local originPosition = originCFrame.Position

  if params then
    local parts = workspace:GetPartBoundsInRadius(originPosition, inheritRadius, params)

    for _, p in parts do
      if p.Transparency == 1 then
        continue
      end

      table.insert(partData, p)
    end
  end

  task.wait(emitDelay)

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

    -- per PIECE: a size is drawn per emitted instance, and one driver for the
    -- whole field would cut every piece to the same measurements. legacy_mods
    -- reads the MinSize and MaxSize pair as a randomizer, and a randomizer
    -- between two Vector3s draws once per component, which is exactly the three
    -- NextNumber calls this replaces
    local sizeDrv = mods.driver(ref, "attribute", "Size", lifeRange.Max, "Vector3")
    local size = if sizeDrv then sizeDrv(0) else nil

    if typeof(size) ~= "Vector3" then
      size = Vector3.new(
        rng:NextNumber(minSize.X, maxSize.X),
        rng:NextNumber(minSize.Y, maxSize.Y),
        rng:NextNumber(minSize.Z, maxSize.Z)
      )
    end

    part.Size = size

    if iref then
      part.Material = iref.Material
      part.Color = iref.Color
      part.Transparency = iref.Transparency
    else
      part.Transparency = tpStart
    end

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

    -- legacy_mods reads the Lifetime NumberRange as a randomizer, so this covers
    -- authored and unauthored alike and the manual draw is only left for a field
    -- carrying no Lifetime attribute at all
    --
    -- the fallback span is the dwell's own ceiling rather than the effect's run: a
    -- Lifetime driver is sampled on the piece's dwell clock, which never reaches
    -- the run. a zero there reads as fully elapsed, which would pin a linked
    -- modifier at its end value from the first frame
    local lifeDrv = mods.driver(ref, "attribute", "Lifetime", lifeRange.Max, "number")
    local drawn = if lifeDrv then lifeDrv(0) else nil

    -- a NaN lifetime satisfies no comparison, so elapsed >= target is false for
    -- ever and the piece dwells for the life of the session
    if typeof(drawn) ~= "number" or drawn ~= drawn then
      drawn = rng:NextNumber(lifeRange.Min, lifeRange.Max)
    end

    -- the dwell belongs to the effect rather than to the scheduler: its cleanup
    -- lives in the scope, so tearing the field down cancels it rather than
    -- firing a shrink at a pooled part the cache has already handed on, and its
    -- length is the counter's to decide, so a Lifetime a modifier is moving
    -- moves a dwell that is already running
    tween.after(math.huge, function(deltaTime, elapsed)
      local target = if lifeDrv then lifeDrv(elapsed) else nil

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
        local startTp = part.Transparency

        if startSize ~= size * sizeOutEnd then
          lifetime.hold(
            scope,
            tween.fromParams(sizeCurve, sizeDuration, function(alpha, deltaTime)
              part.Size = startSize:Lerp(size * sizeOutEnd, alpha)
              return deltaTime
            end)
          )
        end

        if startTp ~= tpEnd then
          lifetime.hold(
            scope,
            tween.fromParams(tpCurve, tpDuration, function(alpha, deltaTime)
              part.Transparency = utility.lerp(startTp, tpEnd, alpha)
              return deltaTime
            end)
          )
        end

        local env = scope.effects.emitOnFinish(emitOnFinish, realPart, scope.depth + 1, scope)
        table.insert(promises, env.Finished)
      end)
    end, scope)
  end

  task.wait(lifeRange.Max + math.max(tpDuration, sizeDuration))

  Promise.all(promises):await()
end

return debris
