--!nolint LocalShadow
local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local types = require("@root/types")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
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

  -- the width defaults are COMPUTED: they carry THIS emit's scale, so they must
  -- never reach the reference as authored values. a track only ever reads, so
  -- handing it one costs nothing
  local a1, a2, a3, a4 = getLegacyWidths(ref, scale)

  local width0 = mods.track(ref, "attribute", "Width0", mods.ramp(a3, a1), duration)
  local width1 = mods.track(ref, "attribute", "Width1", mods.ramp(a4, a2), duration)
  local curve0 = mods.track(ref, "attribute", "CurveSize0", obj.CurveSize0, duration)
  local curve1 = mods.track(ref, "attribute", "CurveSize1", obj.CurveSize1, duration)
  local tScale = mods.track(ref, "attribute", "Transparency_Scale", mods.ramp(1, legacy_tpScale), duration)
  local texLength = mods.track(ref, "attribute", "Length_Texture", ref.TextureLength, duration)
  local lengthScale = mods.track(ref, "attribute", "Length_Scale", 1, duration)
  local texSpeed = mods.track(ref, "attribute", "Speed_Texture", ref.TextureSpeed, duration)

  -- the span is read off the clone rather than the template on purpose: a
  -- retimed clone carries its own
  local speed = mods.track(ref, "attribute", "Speed", 1, attr.get(obj, "Speed_Duration", 0.1, true))

  local baseTexSpeed = obj.TextureSpeed

  task.wait(emitDelay)

  obj.Enabled = true

  local promises = {}
  local currentSpeed = 1

  local speedTween

  local env = scope.effects.emitNested(obj, scope.depth + 1, scope)
  table.insert(promises, env.Finished)

  baseTexSpeed = texSpeed.at(0)

  if texSpeed.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, texSpeed.span, function(_, deltaTime, elapsed)
        baseTexSpeed = texSpeed.at(elapsed)
        obj.TextureSpeed = baseTexSpeed * currentSpeed

        return deltaTime
      end)
    )
  end

  currentSpeed = speed.at(0)

  if speed.animated then
    speedTween = tween.fromParams(utility.linear_bezier, speed.span, function(_, deltaTime, elapsed)
      currentSpeed = speed.at(elapsed)

      obj.TextureSpeed = baseTexSpeed * currentSpeed

      return deltaTime
    end)

    lifetime.hold(scope, speedTween)
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

  lifetime.hold(scope, function()
    setLengthScale(1)
  end)

  setTScale(tScale.at(0))

  if tScale.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, tScale.span, function(_, deltaTime, elapsed)
        setTScale(tScale.at(elapsed))
        return deltaTime * currentSpeed
      end, speedTween)
    )
  end

  obj.TextureLength = texLength.at(0)

  if texLength.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, texLength.span, function(_, deltaTime, elapsed)
        obj.TextureLength = texLength.at(elapsed)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  end

  local lengthScaleStart = lengthScale.at(0)

  if lengthScale.animated then
    setLengthScale(lengthScaleStart)

    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, lengthScale.span, function(_, deltaTime, elapsed)
        setLengthScale(lengthScale.at(elapsed))
        return deltaTime * currentSpeed
      end, speedTween)
    )
  elseif lengthScaleStart ~= 1 then
    setLengthScale(lengthScaleStart)
  end

  obj.Width0 = width0.at(0)

  if width0.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, width0.span, function(_, deltaTime, elapsed)
        obj.Width0 = width0.at(elapsed)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  end

  obj.Width1 = width1.at(0)

  if width1.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, width1.span, function(_, deltaTime, elapsed)
        obj.Width1 = width1.at(elapsed)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  end

  obj.CurveSize0 = curve0.at(0)

  if curve0.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, curve0.span, function(_, deltaTime, elapsed)
        obj.CurveSize0 = curve0.at(elapsed)
        return deltaTime * currentSpeed
      end, speedTween)
    )
  end

  obj.CurveSize1 = curve1.at(0)

  if curve1.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, curve1.span, function(_, deltaTime, elapsed)
        obj.CurveSize1 = curve1.at(elapsed)
        return deltaTime * currentSpeed
      end, speedTween)
    )
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

    lifetime.hold(
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
