--!nolint LocalShadow
local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local utility = require("@mod/utility")
local flipbook_common = require("@mod/common/flipbook")

local Promise = require("@pkg/Promise")

local rng = Random.new()

local beam = {}

-- all nine knobs, every one of them read off ref and driven here, so
-- emitters.applyMods leaves them alone. these are ATTRIBUTE names: Width0 and
-- CurveSize0 are also real Beam properties, and a queue on the property side is
-- still the applier's to drive
beam.OWNS = {
  attribute = {
    Speed = true,
    Width0 = true,
    Width1 = true,
    CurveSize0 = true,
    CurveSize1 = true,
    Length_Scale = true,
    Speed_Texture = true,
    Length_Texture = true,
    Transparency_Scale = true,
  },
}

local function getLegacyWidths(obj: Beam, scale: number)
  local w0 = attr.get(obj, "Width0", obj.Width0, true) * scale
  local w1 = attr.get(obj, "Width1", obj.Width1, true) * scale

  local s_w0 = attr.get(obj, "StartWidth0", obj.Width0, true) * scale
  local s_w1 = attr.get(obj, "StartWidth1", obj.Width1, true) * scale

  return w0, w1, s_w0, s_w1
end

function beam.emit(ref: Beam, obj: Beam, scope: types.scope, scale: number)
  local emitOnFinish = scope.effects.prepareEmitOnFinish(obj, scope)

  local emitDelay = attr.get(ref, "EmitDelay", 0)

  local legacy_duration = attr.get(ref, "Duration", 1, true)
  local legacy_tpScale = attr.get(ref, "EndTransparencyScale", 1, true)

  local durationRange = attr.getRange(
    ref,
    "EffectDuration",
    NumberRange.new(legacy_duration, legacy_duration),
    NumberRange.new(0, math.huge)
  )

  local duration = rng:NextNumber(durationRange.Min, durationRange.Max)

  -- every driver is read before the legacy attr.get for the same knob, and beam
  -- is the worst case for that ordering: the width defaults are COMPUTED, so
  -- attr.get(ref, "Width0_Start", a3) would write back a value carrying THIS
  -- emit's legacyScale, and every later emit would read it as authored. the
  -- fallback reads below are soft for the same reason
  local width0, width0Span = mods.driver(ref, "attribute", "Width0", duration)
  local width1, width1Span = mods.driver(ref, "attribute", "Width1", duration)
  local curve0, curve0Span = mods.driver(ref, "attribute", "CurveSize0", duration)
  local curve1, curve1Span = mods.driver(ref, "attribute", "CurveSize1", duration)
  local tScale, tScaleSpan = mods.driver(ref, "attribute", "Transparency_Scale", duration)
  local texLength, texLengthSpan = mods.driver(ref, "attribute", "Length_Texture", duration)
  local lengthScale, lengthScaleSpan = mods.driver(ref, "attribute", "Length_Scale", duration)
  local texSpeed, texSpeedSpan = mods.driver(ref, "attribute", "Speed_Texture", duration)

  -- Speed_Duration is read off obj rather than ref, which is what the legacy
  -- tween did; kept so a converted queue with no duration of its own spans the
  -- same clock it always has
  local speed, speedSpan = mods.driver(ref, "attribute", "Speed", attr.get(obj, "Speed_Duration", 0.1, true))

  local a1, a2, a3, a4 = getLegacyWidths(ref, scale)

  local w1, w2 = 0, 0
  local w3, w4 = 0, 0

  if not width0 then
    w1 = attr.get(ref, "Width0_Start", a3, true)
    w2 = attr.get(ref, "Width0_End", a1, true)
  end

  if not width1 then
    w3 = attr.get(ref, "Width1_Start", a4, true)
    w4 = attr.get(ref, "Width1_End", a2, true)
  end

  local c1, c2 = 0, 0
  local c3, c4 = 0, 0

  if not curve0 then
    c1 = attr.get(ref, "CurveSize0_Start", obj.CurveSize0, true)
    c2 = attr.get(ref, "CurveSize0_End", obj.CurveSize0, true)
  end

  if not curve1 then
    c3 = attr.get(ref, "CurveSize1_Start", obj.CurveSize1, true)
    c4 = attr.get(ref, "CurveSize1_End", obj.CurveSize1, true)
  end

  local texLengthStart, textLengthEnd = 0, 0

  if not texLength then
    texLengthStart = attr.get(ref, "Length_Texture_Start", ref.TextureLength, true)
    textLengthEnd = attr.get(ref, "Length_Texture_End", ref.TextureLength, true)
  end

  local lengthScaleStart, lengthScaleEnd = 1, 1

  if lengthScale then
    lengthScaleStart = lengthScale(0)
  else
    local lengthScaleRangeStart = attr.get(ref, "Length_Scale_Start", NumberRange.new(1, 1), true)
    local lengthScaleRangeEnd = attr.get(ref, "Length_Scale_End", NumberRange.new(1, 1), true)

    lengthScaleEnd = rng:NextNumber(lengthScaleRangeEnd.Min, lengthScaleRangeEnd.Max)
    lengthScaleStart = rng:NextNumber(lengthScaleRangeStart.Min, lengthScaleRangeStart.Max)
  end

  local tStart, tEnd = 1, 1

  if not tScale then
    tStart = attr.get(ref, "Transparency_Scale_Start", 1, true)
    tEnd = attr.get(ref, "Transparency_Scale_End", legacy_tpScale, true)
  end

  local texSpeedStart, texSpeedEnd = 0, 0

  if not texSpeed then
    texSpeedStart = attr.get(ref, "Speed_Texture_Start", ref.TextureSpeed, true)
    texSpeedEnd = attr.get(ref, "Speed_Texture_End", ref.TextureSpeed, true)
  end

  local speedStart, speedEnd = 1, 1

  if not speed then
    speedStart = attr.get(ref, "Speed_Start", 1, true)
    speedEnd = attr.get(ref, "Speed_End", 1, true)
  end

  local baseTexSpeed = obj.TextureSpeed

  task.wait(emitDelay)

  obj.Enabled = true

  local promises = {}
  local currentSpeed = 1

  local speedTween

  local env = scope.effects.emitNested(obj, scope.depth + 1, scope)
  table.insert(promises, env.Finished)

  if texSpeed then
    baseTexSpeed = texSpeed(0)

    tween.fromParams(utility.linear_bezier, texSpeedSpan, function(_, deltaTime, elapsed)
      baseTexSpeed = texSpeed(elapsed)
      obj.TextureSpeed = baseTexSpeed * currentSpeed

      return deltaTime
    end)
  elseif texSpeedStart ~= texSpeedEnd then
    tween.fromParams(attr.get(ref, "Speed_Texture_Curve", utility.default_bezier), duration, function(alpha, deltaTime)
      baseTexSpeed = utility.lerp(texSpeedStart, texSpeedEnd, alpha)
      obj.TextureSpeed = baseTexSpeed * currentSpeed

      return deltaTime
    end)
  end

  if speed then
    currentSpeed = speed(0)

    speedTween = tween.fromParams(utility.linear_bezier, speedSpan, function(_, deltaTime, elapsed)
      currentSpeed = speed(elapsed)

      obj.TextureSpeed = baseTexSpeed * currentSpeed

      return deltaTime
    end)

    table.insert(scope, speedTween)
  elseif speedStart ~= speedEnd then
    speedTween = tween.fromParams(
      attr.get(ref, "Speed_Curve", utility.default_bezier),
      attr.get(obj, "Speed_Duration", 0.1),
      function(alpha, deltaTime)
        currentSpeed = utility.lerp(speedStart, speedEnd, alpha)

        obj.TextureSpeed = baseTexSpeed * currentSpeed

        return deltaTime
      end
    )

    table.insert(scope, speedTween)
  end

  local refTpKp = ref.Transparency.Keypoints

  local numKeypoints = #refTpKp
  local scaledKeypoints = table.create(numKeypoints)

  local keypointData = table.create(numKeypoints)

  for i, kp in refTpKp do
    keypointData[i] = {
      time = kp.Time,
      value = kp.Value,
      envelope = kp.Envelope,
    }
  end

  local lastTScale = nil

  local function setTScale(tscale: number)
    if lastTScale and math.abs(tscale - lastTScale) < 0.001 then
      return
    end

    lastTScale = tscale

    local offset = tscale > 1 and tscale - 1 or 1 - tscale

    for i, kd in keypointData do
      local value = kd.value
      local base = tscale > 1 and (1 - value) or -value

      scaledKeypoints[i] = NumberSequenceKeypoint.new(kd.time, value + base * offset, kd.envelope)
    end

    obj.Transparency = NumberSequence.new(scaledKeypoints)
  end

  local att0, att1 = obj.Attachment0, obj.Attachment1
  local cf0, cf1 = att0 and att0.CFrame, att1 and att1.CFrame

  local function setLengthScale(scale: number)
    if not cf0 or not cf1 then
      return
    end

    -- calculate the original offset vector from att0 to att1
    local offset = cf1.Position - cf0.Position
    local halfOffset = offset * 0.5

    -- calculate center point
    local center = cf0.Position + halfOffset

    -- scale the half-offsets and apply from center
    local scaledHalfOffset = halfOffset * scale

    att0.CFrame = CFrame.new(center - scaledHalfOffset) * (cf0 - cf0.Position)
    att1.CFrame = CFrame.new(center + scaledHalfOffset) * (cf1 - cf1.Position)
  end

  table.insert(scope, function()
    setLengthScale(1)
  end)

  if tScale then
    setTScale(tScale(0))

    table.insert(
      scope,
      tween.fromParams(utility.linear_bezier, tScaleSpan, function(_, deltaTime, elapsed)
        setTScale(tScale(elapsed))
        return deltaTime * currentSpeed
      end, speedTween)
    )
  elseif tStart ~= tEnd then
    table.insert(
      scope,
      tween.fromParams(
        attr.get(ref, "Transparency_Scale_Curve", utility.default_bezier),
        duration,
        function(alpha, deltaTime)
          setTScale(utility.lerp(tStart, tEnd, alpha))
          return deltaTime * currentSpeed
        end,
        speedTween
      )
    )
  elseif tStart ~= 1 then
    setTScale(tStart)
  end

  if texLength then
    obj.TextureLength = texLength(0)

    table.insert(
      scope,
      tween.fromParams(utility.linear_bezier, texLengthSpan, function(_, deltaTime, elapsed)
        obj.TextureLength = texLength(elapsed)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  elseif texLengthStart ~= textLengthEnd then
    table.insert(
      scope,
      tween.fromParams(
        attr.get(ref, "Length_Texture_Curve", utility.default_bezier),
        duration,
        function(alpha, deltaTime)
          obj.TextureLength = utility.lerp(texLengthStart, textLengthEnd, alpha)
          return deltaTime * currentSpeed
        end,
        speedTween
      )
    )
  end

  if lengthScale then
    setLengthScale(lengthScaleStart)

    table.insert(
      scope,
      tween.fromParams(utility.linear_bezier, lengthScaleSpan, function(_, deltaTime, elapsed)
        setLengthScale(lengthScale(elapsed))
        return deltaTime * currentSpeed
      end, speedTween)
    )
  elseif lengthScaleStart ~= lengthScaleEnd then
    table.insert(
      scope,
      tween.fromParams(attr.get(ref, "Length_Scale_Curve", utility.default_bezier), duration, function(alpha, deltaTime)
        local x = utility.lerp(lengthScaleStart, lengthScaleEnd, alpha)

        setLengthScale(x)

        return deltaTime * currentSpeed
      end, speedTween)
    )
  elseif lengthScaleStart ~= 1 then
    -- was `texLengthStart ~= 1`, which is the TEXTURE length: a static length
    -- scale only applied when an unrelated knob happened not to be 1
    setLengthScale(lengthScaleStart)
  end

  if width0 then
    obj.Width0 = width0(0)

    table.insert(
      scope,
      tween.fromParams(utility.linear_bezier, width0Span, function(_, deltaTime, elapsed)
        obj.Width0 = width0(elapsed)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  elseif w1 ~= w2 then
    table.insert(
      scope,
      tween.fromParams(attr.get(ref, "Width0_Curve", utility.default_bezier), duration, function(alpha, deltaTime)
        obj.Width0 = utility.lerp(w1, w2, alpha)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  else
    obj.Width0 = w1
  end

  if width1 then
    obj.Width1 = width1(0)

    table.insert(
      scope,
      tween.fromParams(utility.linear_bezier, width1Span, function(_, deltaTime, elapsed)
        obj.Width1 = width1(elapsed)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  elseif w3 ~= w4 then
    table.insert(
      scope,
      tween.fromParams(attr.get(ref, "Width1_Curve", utility.default_bezier), duration, function(alpha, deltaTime)
        obj.Width1 = utility.lerp(w3, w4, alpha)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  else
    obj.Width1 = w3
  end

  if curve0 then
    obj.CurveSize0 = curve0(0)

    table.insert(
      scope,
      tween.fromParams(utility.linear_bezier, curve0Span, function(_, deltaTime, elapsed)
        obj.CurveSize0 = curve0(elapsed)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  elseif c1 ~= c2 then
    table.insert(
      scope,
      tween.fromParams(attr.get(ref, "CurveSize0_Curve", utility.default_bezier), duration, function(alpha, deltaTime)
        obj.CurveSize0 = utility.lerp(c1, c2, alpha)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  else
    -- was `obj.Width0 = w1`, a copy-paste of the Width0 branch above, so a
    -- static CurveSize0 was never applied at all
    obj.CurveSize0 = c1
  end

  if curve1 then
    obj.CurveSize1 = curve1(0)

    table.insert(
      scope,
      tween.fromParams(utility.linear_bezier, curve1Span, function(_, deltaTime, elapsed)
        obj.CurveSize1 = curve1(elapsed)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  elseif c3 ~= c4 then
    table.insert(
      scope,
      tween.fromParams(attr.get(ref, "CurveSize1_Curve", utility.default_bezier), duration, function(alpha, deltaTime)
        obj.CurveSize1 = utility.lerp(c3, c4, alpha)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  else
    -- was `obj.Width1 = w3`, the same copy-paste
    obj.CurveSize1 = c3
  end

  -- flipbook support
  local flipbookDuration = 0
  local flipbook = flipbook_common.getFlipbookData(ref)

  if flipbook then
    local config = {
      ref = ref,
      frames = flipbook,
      speedTween = speedTween,
      effectDuration = duration,

      curve = attr.get(ref, "Flipbook_Change_Curve", utility.linear_bezier),
      duration = attr.get(ref, "Flipbook_Change_Duration", duration),

      getSpeed = function()
        return currentSpeed
      end,

      setTexture = function(texture)
        obj.Texture = texture
      end,
    }

    flipbookDuration = flipbook_common.getChangeDuration(config)

    table.insert(
      scope,
      tween.fromParams(config.curve, flipbookDuration, flipbook_common.createUpdateCallback(config), speedTween)
    )
  end

  tween.timer(math.max(duration, flipbookDuration), function(deltaTime, elapsed)
    return if currentSpeed > 0 or (elapsed > 0 and speedTween and speedTween.Connected)
      then deltaTime * currentSpeed
      else nil
  end, speedTween, scope)

  if emitOnFinish then
    local env = scope.effects.emitOnFinish(emitOnFinish, obj.Parent or workspace.Terrain, scope.depth + 1, scope)
    table.insert(promises, env.Finished)
  end

  Promise.all(promises):await()
end

return beam
