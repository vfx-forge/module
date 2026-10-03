--!nolint LocalShadow
local mod = require("@mod/mod")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local bezier_common = require("@mod/common/bezier")
local enabled_effects = require("@srv/enabled_effects")

local Bezier = require("@obj/Bezier")
local ObjectCache = require("@obj/ObjectCache")

local function linear()
  return utility.linear_bezier
end

local function eased()
  return utility.default_bezier
end

local function always()
  return true
end

-- a fade of no length is no phase at all, which is where an unauthored bolt
-- rests: the row holds its own value and nothing samples it
local function fadeInStart(_, attrs: any)
  return if attrs.FadeInDuration > 0 then attrs.FadeInStart else nil
end

local function fadeInDuration(_, attrs: any)
  return attrs.FadeInDuration
end

local function fadeInCurve(_, attrs: any)
  return attrs.FadeInCurve
end

local function fadeOutEnd(_, attrs: any)
  return if attrs.FadeOutDuration > 0 then attrs.FadeOutEnd else nil
end

local function fadeOutDuration(_, attrs: any)
  return attrs.FadeOutDuration
end

local function fadeOutCurve(_, attrs: any)
  return attrs.FadeOutCurve
end

-- how long a dissipation with no mode of its own runs: the longest dissipate
-- lane on the rows the bolt samples, nil when none of them holds one
local function dissipateLength(tracks: { any }): number?
  local longest: number? = nil

  for _, track in tracks do
    if track.has("dissipate") then
      longest = math.max(longest or 0, track.reach("dissipate"))
    end
  end

  return longest
end

local lightning = {}

lightning.id = "lightning"
lightning.display = { name = "Lightning", icon = "lightning", order = 120 }
lightning.classifier = "Attachment.LightningBolt"
lightning.components = "Instance"
lightning.constant = true
lightning.events = { "dissipate" }

lightning.attributes = bezier_common.rows({
  Segments = knob(8):min(2):label("Amount"):hint("Number of straight segments that make up the bolt."),
  Jaggedness = knob(NumberRange.new(0.5, 1))
    :min(0)
    :label("Jaggedness")
    :hint("Random offset magnitude range for the jagged path."),
  OffsetScale = knob(1):unit("studs"):label("Scale"):hint("Multiplier applied to the jagged offset magnitude."),
  RefreshRate = knob(15)
    :min(0)
    :unit("perSecond")
    :label("Rate")
    :hint("Times per second the jagged path is regenerated."),
  IndependentSegments = knob(false)
    :label("Independent")
    :hint("Whether each segment keeps its own birth width and transparency."),
  RefreshDuringDissipate = knob(false)
    :label("DuringDissipate")
    :hint("Whether the path keeps refreshing while dissipating."),
  NestedEffectMode = knob("None")
    :options({ "None", "All", "Head", "Tail" })
    :label("Mode")
    :hint("Which segments spawn nested child effects."),

  Color = knob(ColorSequence.new(Color3.new(1, 1, 1))):label("Color"):hint("Colour of the segments."),
  ColorCurve = knob(linear):aliases("Color_Curve"):label("Curve"):hint("Easing of the colour cycle."),
  ColorDuration = knob(1)
    :min(0)
    :aliases("Color_Duration")
    :unit("seconds")
    :label("Duration")
    :hint("Seconds one colour cycle takes."),

  FillColor = knob(ColorSequence.new(Color3.new(1, 1, 1)))
    :aliases("Fill_Color")
    :label("Color")
    :hint("Fill (glow) color of the bolt."),
  FillColorCurve = knob(linear):aliases("Fill_Color_Curve"):label("Curve"):hint("Easing of the fill colour cycle."),
  FillColorDuration = knob(1)
    :min(0)
    :aliases("Fill_Color_Duration")
    :unit("seconds")
    :label("Duration")
    :hint("Seconds one fill colour cycle takes."),
  FillDepthMode = knob("Occluded")
    :options({ "AlwaysOnTop", "Occluded" })
    :aliases("Fill_DepthMode")
    :label("DepthMode")
    :hint("Occlusion mode for the fill highlight."),
  FillTransparency = knob(1)
    :aliases("Fill_Transparency")
    :mod()
    :label("Transparency")
    :hint("Fill transparency over the fill colour's duration."),

  -- the six old fade keys stay rows so the panel reaches them through the
  -- Transparency drawer and retime still scales the two spans
  FadeInStart = knob(1):aliases("Fade_In_Start"):hidden(always),
  FadeInDuration = knob(0):min(0):aliases("Fade_In_Duration"):unit("seconds"):hidden(always),
  FadeInCurve = knob(eased):aliases("Fade_In_Curve"):hidden(always),

  FadeOutEnd = knob(1):aliases("Fade_Out_End"):hidden(always),
  FadeOutDuration = knob(0):min(0):aliases("Fade_Out_Duration"):unit("seconds"):hidden(always),
  FadeOutCurve = knob(eased):aliases("Fade_Out_Curve"):hidden(always),

  DissipateMode = knob("None")
    :options({ "None", "Retract", "Scale" })
    :aliases("Dissipate_Mode")
    :label("Mode")
    :hint("How the bolt disappears when it finishes."),
  DissipateDuration = knob(0.5)
    :min(0)
    :aliases("Dissipate_Duration")
    :unit("seconds")
    :label("Duration")
    :hint("Seconds the dissipation animation lasts."),
  DissipateCurve = knob(eased):aliases("Dissipate_Curve"):label("Curve"):hint("Easing of the dissipation."),

  -- an unauthored bolt thins from two studs to a fifth over its own duration
  Width = knob(0.2)
    :min(0)
    :unit("studs")
    :mod(mod.from(2))
    :label("Width")
    :hint("Segment width in studs over the bolt's duration."),
  Length = knob(1):min(0):mod():label("Length"):hint("Visible fraction of the bolt over its duration."),
  -- the two fades are modifiers on the row they change: the entry one runs from
  -- the emit, the exit one from the moment the module fires its dissipation
  Transparency = knob(0)
    :mod(
      mod.from(fadeInStart):duration(fadeInDuration):curve(fadeInCurve),
      mod.to(fadeOutEnd):duration(fadeOutDuration):curve(fadeOutCurve):lane("dissipate")
    )
    :label("Transparency")
    :hint("Segment transparency over the bolt's duration."),

  EasingCurve = knob(linear):aliases("Easing_Curve"):label("Easing"):hint("Easing of travel along the path."),
})

lightning.properties = {}

lightning.layout = bezier_common.layout({}, {
  { title = "Animation", entries = { "EasingCurve" } },
  {
    title = "Segments",
    entries = {
      "Segments",
      "Color",
      { curve = "ColorCurve", duration = "ColorDuration" },
      "IndependentSegments",
      { title = "Refresh", entries = { "RefreshRate", "RefreshDuringDissipate" } },
      "Transparency",
      "Width",
      "Length",
    },
  },
  { title = "Offset", entries = { "Jaggedness", "OffsetScale" } },
  { title = "Nested Effects", entries = { "NestedEffectMode" } },
  {
    title = "Fill",
    entries = {
      "FillColor",
      "FillDepthMode",
      { curve = "FillColorCurve", duration = "FillColorDuration" },
      "FillTransparency",
    },
  },
  {
    title = "Dissipation",
    entries = { "DissipateMode", { curve = "DissipateCurve", duration = "DissipateDuration" } },
  },
  {
    title = "Behavior",
    entries = {
      { action = "edit_path", label = "Edit Lightning" },
      { action = "toggle_paths", label = "Show Paths" },
    },
  },
})

function lightning.duration(_, attrs: any)
  return attrs.Duration.Max
end

local part_cache: ObjectCache.ObjectCache?

function lightning.init(cache)
  part_cache = cache
end

function lightning.deinit()
  part_cache = nil
end

local function createSegmentStates(count: number)
  local states = {}

  for j = 1, count do
    states[j] = {
      initialWidth = nil,
      birth = nil,
      birthElapsed = nil,
      wasVisible = false,
    }
  end

  return states
end

local function computeJaggedOffset(
  rng: Random,
  jaggedness: NumberRange,
  offsetScale: number,
  segLength: number,
  right: Vector3,
  up: Vector3
)
  local jaggedAmount = rng:NextNumber(jaggedness.Min, jaggedness.Max)
  local maxOffset = segLength * 0.8

  local offsetMag = math.min(jaggedAmount * offsetScale * segLength, maxOffset)
  local angle = rng:NextNumber(0, math.pi * 2)

  return (right * math.cos(angle) + up * math.sin(angle)) * offsetMag
end

local function generateLightningPoints(
  rng: Random,
  segments: number,
  getPos: (number) -> Vector3,
  jaggedness: NumberRange,
  offsetScale: number
)
  local points = table.create(segments + 1)
  local invSegments = 1 / segments

  points[1] = getPos(0)

  local prevPos = points[1]

  for j = 1, segments - 1 do
    local t = j * invSegments
    local pos = getPos(t)

    local nextT = math.min(t + 0.01, 1)
    local tangent = getPos(nextT) - pos

    tangent = if tangent.Magnitude > 0.001 then tangent.Unit else Vector3.yAxis

    local right, up = bezier_common.getPerpendicularVectors(tangent)
    local segmentLength = (pos - prevPos).Magnitude

    local offset = computeJaggedOffset(rng, jaggedness, offsetScale, segmentLength, right, up)

    pos = pos + offset
    prevPos = pos

    points[j + 1] = pos
  end

  points[segments + 1] = getPos(1)

  return points
end

local function generateProjectilePoints(
  rng: Random,
  segments: number,
  tailPos: Vector3,
  headPos: Vector3,
  jaggedness: NumberRange,
  offsetScale: number,
  fallbackDir: Vector3
)
  local points = table.create(segments + 1)
  local invSegments = 1 / segments

  local pathDir = headPos - tailPos
  local pathLength = pathDir.Magnitude

  local tangent = if pathLength > 0.001 then pathDir / pathLength else fallbackDir

  local right, up = bezier_common.getPerpendicularVectors(tangent)
  local segLength = pathLength * invSegments

  points[1] = tailPos

  for j = 1, segments - 1 do
    local t = j * invSegments

    local pos = tailPos:Lerp(headPos, t)
    local offset = computeJaggedOffset(rng, jaggedness, offsetScale, segLength, right, up)

    points[j + 1] = pos + offset
  end

  points[segments + 1] = headPos

  return points
end

export type TransitionState = {
  curvedTailT: number,
  curvedLengthT: number,
  boltLength: number,
  transitionBuffer: number,
  distanceTraveled: number,
  jaggedOffsets: { Vector3 }?,
}

local function getBlendedPosition(
  t: number,
  getPos: (number) -> Vector3,
  straightTailPos: Vector3,
  straightHeadPos: Vector3,
  state: TransitionState
): Vector3
  -- per-point transition alpha
  local pointExitDistance = (1 - t) * state.boltLength
  local pointOvershoot = state.distanceTraveled - pointExitDistance
  local pointAlpha = math.clamp(pointOvershoot / state.transitionBuffer, 0, 1)

  -- curved position on sliding bezier
  local bezierProgress = math.min(state.distanceTraveled / state.boltLength, 1) * state.curvedLengthT
  local bezierT = math.min(1, state.curvedTailT + t * state.curvedLengthT + bezierProgress)

  local curvedPos = getPos(bezierT)

  -- straight position
  local straightPos = straightTailPos:Lerp(straightHeadPos, t)

  return curvedPos:Lerp(straightPos, pointAlpha)
end

local function generateTransitionPoints(
  rng: Random,
  segments: number,
  getPos: (number) -> Vector3,
  straightTailPos: Vector3,
  straightHeadPos: Vector3,
  jaggedness: NumberRange,
  offsetScale: number,
  fallbackDir: Vector3,
  state: TransitionState
)
  local points = table.create(segments + 1)
  local offsets = table.create(segments + 1)

  local invSegments = 1 / segments

  local straightDir = straightHeadPos - straightTailPos
  local straightLength = straightDir.Magnitude

  local tangent = if straightLength > 0.001 then straightDir / straightLength else fallbackDir
  local right, up = bezier_common.getPerpendicularVectors(tangent)

  local segLength = straightLength * invSegments

  for j = 0, segments do
    local t = j * invSegments
    local basePos = getBlendedPosition(t, getPos, straightTailPos, straightHeadPos, state)

    if j == 0 or j == segments then
      points[j + 1] = basePos
      offsets[j + 1] = Vector3.zero
    else
      local offset = computeJaggedOffset(rng, jaggedness, offsetScale, segLength, right, up)

      points[j + 1] = basePos + offset
      offsets[j + 1] = offset
    end
  end

  return points, offsets
end

local function updateTransitionPoints(
  segments: number,
  getPos: (number) -> Vector3,
  straightTailPos: Vector3,
  straightHeadPos: Vector3,
  state: TransitionState
): { Vector3 }
  local points = table.create(segments + 1)

  local invSegments = 1 / segments
  local offsets = state.jaggedOffsets

  for j = 0, segments do
    local t = j * invSegments
    local basePos = getBlendedPosition(t, getPos, straightTailPos, straightHeadPos, state)

    points[j + 1] = basePos + (if offsets then offsets[j + 1] else Vector3.zero)
  end

  return points
end

local function isTransitionComplete(state: TransitionState): boolean
  return state.distanceTraveled >= state.boltLength + state.transitionBuffer
end

function lightning.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: Attachment
  local scope = ctx.scope
  local root = ref:FindFirstChild("Points")
  local template = ref:FindFirstChildOfClass("Part")

  if not root or not root:IsA("Attachment") or not part_cache or not template then
    return
  end

  -- a plain emit of an enabled bolt switches it off; the tick's own emits
  -- leave it as it is
  if attrs.Enabled and not ctx.constant then
    enabled_effects.switch(ref, false)
  end

  local refObj = template:Clone()
  refObj.Locked = true

  lifetime.hold(scope, refObj)

  local drawFunc = bezier_common.drawFuncMap[attrs.Shape] and bezier_common.drawFuncMap[attrs.Shape][attrs.ShapeStyle]

  if not drawFunc then
    return
  end

  lifetime.wait(scope, attrs.EmitDelay)

  if attrs.EmitDuration > 0 and not ctx.constant then
    enabled_effects.window(ctx, lightning, attrs.EmitDuration, attrs.Speed)
    return
  end

  if attrs.EmitCount <= 0 then
    return
  end

  local parent = bezier_common.validateParent(ref)

  if not parent then
    return
  end

  local originCFrame, originSize = utility.getTransformedOriginExtents(parent)

  if not originCFrame then
    return
  end

  local endPoint, endT1 = bezier_common.findEndAttachments(ref)
  local points = utility.getBezierPoints(root)

  -- a Points attachment with nothing under it has no path to follow
  if #points < 2 then
    return
  end

  local rng = Random.new()
  local baseBezier = not endPoint and Bezier.new(points)

  local colorEasing = curve.new(1, attrs.ColorCurve)
  local fillColorEasing = curve.new(1, attrs.FillColorCurve)

  local hitboxParams = bezier_common.createHitboxParams(bezier_common.hitboxOf(attrs), parent, root)

  -- every bolt runs on the effect's clock, so one Speed track paces them all
  utility.speedFrom(scope, ctx.constant, attrs.Speed)

  -- a bolt counts until it has dissipated and its on-finish emit is counted in,
  -- and a nested emit until it ends
  local outstanding = lifetime.join(scope)
  local emission = bezier_common.emissionOf(attrs)

  for _ = 1, attrs.EmitCount do
    local duration = rng:NextNumber(attrs.Duration.Min, attrs.Duration.Max)
    local projectileLifetime = attrs.ProjectileEnabled
      and rng:NextNumber(attrs.ProjectileLifetime.Min, attrs.ProjectileLifetime.Max)

    -- one track set per emitted bolt, the same granularity the legacy tweens
    -- ran at. FillTransparency spans FillColorDuration rather than the bolt's,
    -- which is what its tween always did. the piece is the clock this bolt's
    -- own lanes fire on, so one bolt dissipating never moves another, and every
    -- row the bolt samples takes it, so a dissipate lane on any of them runs
    local piece = mods.piece(lightning.events)
    local width = attrs.Width(nil, duration, piece)
    local length = attrs.Length(nil, duration, piece)
    local transparency = attrs.Transparency(nil, duration, piece)
    local fillTp = attrs.FillTransparency(nil, attrs.FillColorDuration, piece)

    local landed = lifetime.add(outstanding)

    -- a bolt that throws is logged and counted out, and the bolts beside it
    -- keep running
    local ok = utility.try(`failed to emit a lightning bolt with error: %s`, function()
      local cf = bezier_common.calculateEmissionCFrame(
        originCFrame,
        originSize,
        emission,
        drawFunc,
        rng,
        endPoint,
        parent:IsA("Attachment")
      )

      local bezier = baseBezier or bezier_common.endpointPath(points, cf, endPoint, endT1)
      local getPos = bezier_common.createPosGetter(bezier, points, cf, endPoint, true)

      -- create segment parts
      local segmentRealParts = table.create(attrs.Segments)
      local segmentCacheIds = table.create(attrs.Segments)

      local segmentState = createSegmentStates(attrs.Segments)

      local invSegments = 1 / attrs.Segments
      local segmentBounds = table.create(attrs.Segments)

      for j = 1, attrs.Segments do
        segmentBounds[j] = {
          start = (j - 1) * invSegments,
          finish = j * invSegments,
        }
      end

      if not part_cache then
        landed()
        return
      end

      -- create a highlight container if needed. a highlight is built when the
      -- fill is less than opaque at either end of its track, or when its
      -- dissipate lane may take it there
      local useHighlight = fillTp.at(0) < 1 or fillTp.at(fillTp.duration) < 1 or fillTp.has("dissipate")

      local highlight: Highlight?
      local containerModel: Model?

      if useHighlight then
        local container = Instance.new("Model")
        container.Name = "LightningContainer"
        container.Parent = workspace.Terrain
        containerModel = container

        local hl = Instance.new("Highlight")
        hl.Adornee = container
        hl.FillColor = bezier_common.getColorWithEasingOklab(attrs.FillColor, 0, fillColorEasing)
        hl.FillTransparency = fillTp.at(0)
        hl.OutlineTransparency = 1
        hl.DepthMode = Enum.HighlightDepthMode[attrs.FillDepthMode]
        hl.Parent = container

        highlight = hl
      end

      -- determine which segments get nested effects
      local function shouldEmitNested(segmentIndex: number): boolean
        local mode = attrs.NestedEffectMode

        if mode == "All" then
          return true
        elseif mode == "Head" then
          return segmentIndex == attrs.Segments
        elseif mode == "Tail" then
          return segmentIndex == 1
        end

        return false
      end

      local emitOnFinish = if attrs.NestedEffectMode ~= "None"
        then scope.effects.prepareEmitOnFinish(refObj, scope)
        else nil

      -- track segments that need nested effect emission
      local nestedSegments = {}
      local nestedEffectChildren = {}

      -- sampled once: every segment is born at the same width, and a queue
      -- evaluation per segment per axis is not free
      local initWidth = width.at(0)

      -- create segment parts
      for j = 1, attrs.Segments do
        local cacheId = utility.getRandomId()

        local objAbstr = part_cache:get(cacheId)
        local obj = objAbstr._getReal()

        utility.copyProperties(refObj, obj, utility.COPY_PART_PROPERTIES)

        obj.Size = Vector3.new(initWidth, initWidth, 1)

        obj.Anchored = true
        obj.CanQuery = false
        obj.CanTouch = false
        obj.CanCollide = false

        if useHighlight and containerModel then
          obj.Parent = containerModel
        end

        if shouldEmitNested(j) then
          local clone = refObj:Clone()

          for _, child in clone:GetChildren() do
            child.Parent = obj

            if attrs.NestedEffectMode == "Head" then
              table.insert(nestedEffectChildren, child)
            end
          end

          clone:Destroy()

          table.insert(nestedSegments, j)
        end

        segmentRealParts[j] = obj
        segmentCacheIds[j] = cacheId
      end

      -- for Head mode, reparent children to segment 1 initially
      local currentNestedParentIndex = nil

      if attrs.NestedEffectMode == "Head" and #nestedEffectChildren > 0 then
        for _, child in nestedEffectChildren do
          child.Parent = segmentRealParts[1]
        end
        currentNestedParentIndex = 1
      end

      -- cleanup
      lifetime.hold(scope, function()
        if part_cache then
          for j = 1, attrs.Segments do
            part_cache:free(segmentCacheIds[j])
          end

          if containerModel then
            containerModel:Destroy()
          end
        end
      end)

      local effectContainer = containerModel or refObj

      -- animation state
      local finished = false

      local currentWidth = width.at(0)
      local currentLength = length.at(0)
      local currentFillTransparency = fillTp.at(0)

      local currentColorAlpha = 0
      local currentFillColorAlpha = 0

      -- a cycle of no length holds its alpha where it stands. dividing the
      -- frame by it would hand every frame after it a nan
      local colorCycle = if attrs.ColorDuration > 0 then attrs.ColorDuration else math.huge
      local fillColorCycle = if attrs.FillColorDuration > 0 then attrs.FillColorDuration else math.huge

      local lastRefreshTime = 0

      local lightningPoints = generateLightningPoints(rng, attrs.Segments, getPos, attrs.Jaggedness, attrs.OffsetScale)

      -- emit nested effects
      for _, j in nestedSegments do
        local emitFrom = if attrs.NestedEffectMode == "Head" then 1 else j
        scope.effects.emitNested(segmentRealParts[emitFrom], scope.depth + 1, scope, outstanding)
      end

      local lastVelocity = Vector3.zero
      local lastHeadPos = Vector3.zero

      local scaledElapsedTime = 0

      local isDissipating = false

      local currentHeadAlpha = 0

      local dissipateStartTail = 0

      local dissipateStartWidth = initWidth
      local currentOriginCFrame = originCFrame

      local projectileDir: Vector3?
      local projectileHeadPos: Vector3?
      local projectileTailPos: Vector3?

      local transitionState: TransitionState?

      local function getHeadSegmentIndex(): number
        return math.clamp(math.ceil(currentHeadAlpha * attrs.Segments), 1, attrs.Segments)
      end

      local function shapecast()
        if not attrs.HitboxEnabled then
          return false
        end

        local headSegment = segmentRealParts[getHeadSegmentIndex()]

        if headSegment and headSegment.Transparency < 1 then
          local result = workspace:GetPartsInPart(headSegment, hitboxParams)

          if result[1] then
            return true
          end
        end

        return false
      end

      -- refresh lightning points based on current state
      local function refreshPoints()
        if projectileHeadPos and projectileTailPos and projectileDir then
          if transitionState and not isTransitionComplete(transitionState) then
            lightningPoints, transitionState.jaggedOffsets = generateTransitionPoints(
              rng,
              attrs.Segments,
              getPos,
              projectileTailPos,
              projectileHeadPos,
              attrs.Jaggedness,
              attrs.OffsetScale,
              projectileDir,
              transitionState
            )
          else
            lightningPoints = generateProjectilePoints(
              rng,
              attrs.Segments,
              projectileTailPos,
              projectileHeadPos,
              attrs.Jaggedness,
              attrs.OffsetScale,
              projectileDir
            )

            if transitionState then
              transitionState.jaggedOffsets = nil
            end
          end
        else
          lightningPoints = generateLightningPoints(rng, attrs.Segments, getPos, attrs.Jaggedness, attrs.OffsetScale)
        end
      end

      -- update points between refreshes during transition
      local function updatePointsBetweenRefreshes(deltaTime: number)
        if transitionState and not isTransitionComplete(transitionState) then
          if transitionState.jaggedOffsets then
            lightningPoints = updateTransitionPoints(
              attrs.Segments,
              getPos,
              projectileTailPos :: Vector3,
              projectileHeadPos :: Vector3,
              transitionState
            )
          else
            -- generate offsets on first frame
            lightningPoints, transitionState.jaggedOffsets = generateTransitionPoints(
              rng,
              attrs.Segments,
              getPos,
              projectileTailPos :: Vector3,
              projectileHeadPos :: Vector3,
              attrs.Jaggedness,
              attrs.OffsetScale,
              projectileDir :: Vector3,
              transitionState
            )
          end
        else
          -- fully transitioned, move points along the projectile direction
          local offset = projectileDir * attrs.ProjectileSpeed * deltaTime

          for j = 1, #lightningPoints do
            lightningPoints[j] = lightningPoints[j] + offset
          end
        end
      end

      local function updateSegments(
        headAlpha: number,
        tailAlphaOverride: number?,
        scaledDelta: number,
        allowRefresh: boolean?,
        widthOverride: number?
      )
        currentHeadAlpha = headAlpha

        local tailAlpha = tailAlphaOverride or math.max(0, headAlpha - currentLength)
        local effectiveWidth = widthOverride or currentWidth

        -- refresh lightning points
        if allowRefresh ~= false and attrs.RefreshRate > 0 then
          local refreshInterval = 1 / attrs.RefreshRate
          lastRefreshTime += scaledDelta

          if lastRefreshTime >= refreshInterval then
            refreshPoints()
            lastRefreshTime = 0
          end
        end

        -- the clock is the same for every segment in one call, so a row no
        -- segment holds a value of its own on is folded once here rather than
        -- once each
        local sharedTransparency = if attrs.IndependentSegments then nil else transparency.at(scaledElapsedTime)

        -- update each segment
        for j = 1, attrs.Segments do
          local state = segmentState[j]

          local bounds = segmentBounds[j]
          local segment = segmentRealParts[j]

          local segStart = bounds.start
          local segEnd = bounds.finish

          local isVisible = segEnd > tailAlpha and segStart < headAlpha

          if not isVisible then
            segment.Transparency = 1

            if state.wasVisible then
              state.wasVisible = false
              state.initialWidth = nil
              state.birth = nil
              state.birthElapsed = nil
            end
          else
            if not state.wasVisible then
              state.wasVisible = true
              state.initialWidth = currentWidth
              state.birth = transparency.at(scaledElapsedTime)
              state.birthElapsed = scaledElapsedTime
            end

            -- color
            segment.Color = bezier_common.getColorWithEasingOklab(attrs.Color, currentColorAlpha, colorEasing)

            -- a segment holding what it was born with composes only the lanes
            -- that started at or after its birth over that value
            segment.Transparency = if attrs.IndependentSegments
              then transparency.at(scaledElapsedTime, state.birth, state.birthElapsed)
              else sharedTransparency

            -- width
            local useWidth

            if widthOverride then
              local baseWidth = if attrs.IndependentSegments and state.initialWidth
                then state.initialWidth
                else currentWidth

              useWidth = baseWidth * (if currentWidth > 0 then widthOverride / currentWidth else 0)
            elseif attrs.IndependentSegments and state.initialWidth then
              useWidth = state.initialWidth
            else
              useWidth = effectiveWidth
            end

            -- geometry
            local p1 = lightningPoints[j]
            local p2 = lightningPoints[j + 1]

            if p1 and p2 then
              local clampedP1 = if segStart < tailAlpha
                then p1:Lerp(p2, (tailAlpha - segStart) / (segEnd - segStart))
                else p1

              local clampedP2 = if segEnd > headAlpha
                then p1:Lerp(p2, (headAlpha - segStart) / (segEnd - segStart))
                else p2

              local midpoint = (clampedP1 + clampedP2) / 2
              local length = (clampedP2 - clampedP1).Magnitude

              if length > 0.001 then
                segment.Size = Vector3.new(useWidth, useWidth, length)
                segment.CFrame = CFrame.lookAt(midpoint, clampedP2)
              end
            end
          end
        end

        -- update fill
        if highlight then
          highlight.FillColor =
            bezier_common.getColorWithEasingOklab(attrs.FillColor, currentFillColorAlpha, fillColorEasing)

          highlight.FillTransparency = currentFillTransparency
        end

        -- reparent nested effect children to current head segment (Head mode)
        if currentNestedParentIndex then
          local headIndex = getHeadSegmentIndex()

          if headIndex ~= currentNestedParentIndex then
            local targetSegment = segmentRealParts[headIndex]

            for _, child in nestedEffectChildren do
              child.Parent = targetSegment
            end

            currentNestedParentIndex = headIndex
          end
        end

        -- track velocity
        local currentHeadPos = getPos(math.min(headAlpha, 1))

        if scaledDelta > 0 then
          lastVelocity = (currentHeadPos - lastHeadPos) / scaledDelta
        end

        lastHeadPos = currentHeadPos
      end

      tween.drive(scope, width, function(v: number)
        currentWidth = v
      end)

      -- the segment loop reads the transparency itself, so nothing here has to
      -- write it. the hold stays because an authored lane longer than the bolt
      -- kept the emit open on old content, and a driven row always did
      if transparency.animated then
        tween.play(scope, curve.new(transparency.duration, "linear"), function() end)
      end

      tween.drive(scope, length, function(v: number)
        currentLength = v
      end)

      if useHighlight then
        tween.drive(scope, fillTp, function(v: number)
          currentFillTransparency = v
        end)
      end

      -- a driver steps only its row's own span and the dissipation starts
      -- after it, so the phase samples the rows whose dissipate lane it opens
      local widthDissipates = width.has("dissipate")
      local lengthDissipates = length.has("dissipate")
      local fillDissipates = fillTp.has("dissipate")

      -- dissipation handler
      local function handleDissipation(
        headAlpha: number,
        startTail: number,
        startWidth: number,
        curveData: string,
        dissipationDuration: number,
        mode: string,
        onComplete: () -> ()
      )
        isDissipating = true
        dissipateStartTail = startTail
        dissipateStartWidth = startWidth

        tween.play(scope, curve.new(dissipationDuration, curveData), function(alpha: number, deltaTime: number)
          local scaledDelta = deltaTime
          scaledElapsedTime += scaledDelta

          -- a Scale dissipation owns the width, as a Retract one owns the
          -- tail
          if widthDissipates and mode ~= "Scale" then
            currentWidth = width.at(scaledElapsedTime)
          end

          if lengthDissipates then
            currentLength = length.at(scaledElapsedTime)
          end

          if fillDissipates then
            currentFillTransparency = fillTp.at(scaledElapsedTime)
          end

          if attrs.RefreshDuringDissipate then
            currentColorAlpha = (currentColorAlpha + scaledDelta / colorCycle) % 1
            currentFillColorAlpha = (currentFillColorAlpha + scaledDelta / fillColorCycle) % 1
          end

          local tailOverride = if mode == "Retract" then utility.lerp(dissipateStartTail, headAlpha, alpha) else nil
          local widthOverrideVal = if mode == "Scale" then utility.lerp(dissipateStartWidth, 0, alpha) else nil

          updateSegments(headAlpha, tailOverride, scaledDelta, attrs.RefreshDuringDissipate, widthOverrideVal)
        end, scope.depth, onComplete)
      end

      local function startDissipation()
        if isDissipating or finished then
          return
        end

        -- the phase is decided before the lane fires, so the fire can say how
        -- long the phase it opens runs: a mode runs its own duration, and a
        -- bolt with none runs its longest dissipate lane
        local mode = attrs.DissipateMode
        local fade = if mode == "None" then dissipateLength({ transparency, width, length, fillTp }) else nil
        local runFor = if mode ~= "None" then attrs.DissipateDuration else fade

        -- the lane runs on the clock every other track on this bolt reads
        piece:fire("dissipate", scaledElapsedTime, runFor)

        local headAlpha = currentHeadAlpha

        if emitOnFinish then
          scope.effects.emitOnFinish(emitOnFinish, effectContainer, scope.depth + 1, scope, outstanding)
        end

        local function onDissipationComplete()
          if finished then
            return
          end

          finished = true

          landed()
        end

        if mode ~= "None" then
          handleDissipation(
            headAlpha,
            math.max(0, headAlpha - currentLength),
            currentWidth,
            attrs.DissipateCurve,
            attrs.DissipateDuration,
            mode,
            onDissipationComplete
          )
        elseif fade ~= nil then
          -- no mode moves the tail or the width, so the curve eases nothing
          handleDissipation(
            headAlpha,
            math.max(0, headAlpha - currentLength),
            currentWidth,
            "linear",
            fade,
            "None",
            onDissipationComplete
          )
        else
          onDissipationComplete()
        end
      end

      tween.play(
        scope,
        curve.new(duration, attrs.EasingCurve),
        function(alpha: number, deltaTime: number)
          local scaledDelta = deltaTime
          scaledElapsedTime += scaledDelta

          currentColorAlpha = (currentColorAlpha + scaledDelta / colorCycle) % 1
          currentFillColorAlpha = (currentFillColorAlpha + scaledDelta / fillColorCycle) % 1

          if attrs.SyncPosition then
            local newOrigin = utility.getTransformedOriginExtents(parent)
            local offset = newOrigin * currentOriginCFrame:Inverse()

            for j = 1, #lightningPoints do
              lightningPoints[j] = offset:PointToWorldSpace(currentOriginCFrame:PointToObjectSpace(lightningPoints[j]))
            end

            currentOriginCFrame = newOrigin
          end

          updateSegments(alpha, nil, scaledDelta)

          if shapecast() then
            startDissipation()
            return false
          end

          if (attrs.ProjectileEnabled and alpha * duration < projectileLifetime) or not attrs.ProjectileEnabled then
            return true
          end

          startDissipation()

          return false
        end,
        scope.depth,
        function()
          if isDissipating or finished then
            return
          end

          -- non-projectile mode
          if not attrs.ProjectileEnabled then
            if attrs.DestroyDelay > 0 then
              tween.play(scope, curve.new(attrs.DestroyDelay, "linear"), function(_, deltaTime: number)
                local scaledDelta = deltaTime
                scaledElapsedTime += scaledDelta

                currentColorAlpha = (currentColorAlpha + scaledDelta / colorCycle) % 1
                currentFillColorAlpha = (currentFillColorAlpha + scaledDelta / fillColorCycle) % 1

                updateSegments(1, nil, scaledDelta, true)

                if shapecast() then
                  startDissipation()
                  return false
                end

                return true
              end, scope.depth, startDissipation)
            else
              startDissipation()
            end

            return
          end

          -- projectile mode
          local dir = if attrs.MatchEndDirection and endPoint
            then endPoint.WorldCFrame.LookVector
            else lastVelocity.Unit

          if dir ~= dir or dir.Magnitude < 0.001 then
            dir = Vector3.zAxis
          else
            dir = dir.Unit
          end

          local initialHeadPos = getPos(1)
          local initialTailPos = getPos(math.max(0, 1 - currentLength))

          local boltLength = (initialHeadPos - initialTailPos).Magnitude

          local curvedTailT = math.max(0, 1 - currentLength)
          local curvedLengthT = 1 - curvedTailT

          local transitionBuffer = boltLength * 0.3

          -- preserve existing jaggedness offsets from bezier phase
          local existingOffsets = table.create(attrs.Segments + 1)

          for j = 0, attrs.Segments do
            local t = j / attrs.Segments
            local bezierT = curvedTailT + t * curvedLengthT
            local basePos = getPos(bezierT)

            existingOffsets[j + 1] = lightningPoints[j + 1] - basePos
          end

          local state: TransitionState = {
            curvedTailT = curvedTailT,
            curvedLengthT = curvedLengthT,
            boltLength = boltLength,
            transitionBuffer = transitionBuffer,
            distanceTraveled = 0,
            jaggedOffsets = existingOffsets,
          }

          transitionState = state

          -- this runs inside the main animation's step, which must not yield
          task.spawn(function()
            tween.wait(scope, curve.new(projectileLifetime, "linear"), function(_, deltaTime: number, elapsed: number)
              local scaledDelta = deltaTime
              scaledElapsedTime += scaledDelta

              currentColorAlpha = (currentColorAlpha + scaledDelta / colorCycle) % 1
              currentFillColorAlpha = (currentFillColorAlpha + scaledDelta / fillColorCycle) % 1

              local distanceTraveled = elapsed * attrs.ProjectileSpeed
              state.distanceTraveled = distanceTraveled

              local currentHeadPos = initialHeadPos + dir * distanceTraveled
              local currentTailPos = currentHeadPos - dir * boltLength

              projectileHeadPos = currentHeadPos
              projectileTailPos = currentTailPos
              projectileDir = dir

              local shouldRefresh = attrs.RefreshRate > 0

              if shouldRefresh then
                lastRefreshTime += scaledDelta

                if lastRefreshTime >= 1 / attrs.RefreshRate then
                  refreshPoints()
                  lastRefreshTime = 0
                else
                  updatePointsBetweenRefreshes(deltaTime)
                end
              else
                updatePointsBetweenRefreshes(deltaTime)
              end

              updateSegments(1, nil, scaledDelta, false)

              if shapecast() then
                startDissipation()
                return false
              end

              return true
            end, scope.depth)

            startDissipation()
          end)
        end
      )
    end)

    if not ok then
      landed()
    end
  end

  lifetime.awaitJoin(outstanding)
end

-- the template part is authored on the bolt, so a preview of a piece starts
-- where the bolt is
function lightning.selected(ctx: reader.Ctx)
  local ref = ctx.ref :: Attachment
  local points = ref:FindFirstChild("Points")
  local template = ref:FindFirstChildOfClass("Part")

  if template == nil or points == nil or not points:IsA("Attachment") then
    return
  end

  template.CFrame = ref.WorldCFrame
end

return lightning
