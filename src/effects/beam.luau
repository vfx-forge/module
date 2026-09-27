--!nolint LocalShadow
local knob = require("@mod/knob")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local flipbook_common = require("@mod/common/flipbook")

local Promise = require("@pkg/Promise")

local rng = Random.new()

local function always()
  return true
end

local function linear()
  return utility.linear_bezier
end

local beam = {}

beam.id = "beam"
beam.display = { name = "Beam", icon = "beam", order = 80 }
beam.classifier = "Beam"

-- the beam runs the effects nested under it itself, per emit, on its clone
beam.components = "Instance"

beam.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
  EffectDuration = knob(NumberRange.new(1, 1))
    :min(0)
    :aliases("Duration")
    :unit("seconds")
    :label("Duration")
    :hint("Duration range of the effect in seconds."),
  Speed = knob(1):mod():label("Speed"):hint("Multiplier on the beam's clock."),
  -- the span an old speed quad ran over, read by the old format's reader under
  -- this name and kept as a row so retime reaches it
  SpeedDuration = knob(0.1):min(0):aliases("Speed_Duration"):unit("seconds"):hidden(always),
  LengthScale = knob(1)
    :aliases("Length_Scale")
    :mod()
    :label("Scale")
    :hint("Multiplier on the distance between the beam's attachments."),
  TransparencyScale = knob(1)
    :min(0)
    :aliases("Transparency_Scale")
    :mod()
    :label("Scale")
    :hint("Multiplier on the beam's transparency keypoints."),
  -- a cycle nothing authors runs over the effect's own duration, which the
  -- reader has decided by the time a row resolves
  FlipbookChangeDuration = knob(function(ctx)
      return ctx.duration
    end)
    :aliases("Flipbook_Change_Duration")
    :unit("seconds")
    :label("Duration")
    :hint("Seconds for one full flipbook cycle."),
  FlipbookChangeCurve = knob(linear)
    :aliases("Flipbook_Change_Curve")
    :label("Curve")
    :hint("Easing of one flipbook cycle."),
  SyncDuration = knob(false):label("SyncDuration"):hint("Match the flipbook cycle to the effect duration."),
}

-- the beam's own properties are its state; an old attribute of the same name
-- shadows one, and an old quad on it folds into its queue
beam.properties = {
  Width0 = knob():unit("studs"):mod():label("Width0"):hint("Beam Width0 over the effect."),
  Width1 = knob():unit("studs"):mod():label("Width1"):hint("Beam Width1 over the effect."),
  CurveSize0 = knob():unit("studs"):mod():label("CurveSize0"):hint("Beam CurveSize0 over the effect."),
  CurveSize1 = knob():unit("studs"):mod():label("CurveSize1"):hint("Beam CurveSize1 over the effect."),
  TextureSpeed = knob()
    :aliases("Speed_Texture")
    :unit("perSecond")
    :mod()
    :label("Texture")
    :hint("Texture speed over the effect."),
  TextureLength = knob():aliases("Length_Texture"):mod():label("Texture"):hint("Texture length over the effect."),
}

beam.layout = {
  { title = "Emit", entries = { "EmitDelay" } },
  { title = "Effect", entries = { "EffectDuration", "Speed" } },
  {
    title = "Flipbook",
    entries = { { curve = "FlipbookChangeCurve", duration = "FlipbookChangeDuration" }, "SyncDuration" },
  },
  {
    title = "Shape",
    entries = {
      { title = "Widths", entries = { "Width0", "Width1" } },
      { title = "Curve Sizes", entries = { "CurveSize0", "CurveSize1" } },
      "LengthScale",
    },
  },
  {
    title = "Texture",
    entries = {
      "TextureSpeed",
      "TextureLength",
      "TransparencyScale",
      { action = "toggle_textures", label = "Load Textures" },
    },
  },
}

-- one length per emit, drawn from the range the row holds
function beam.duration(_, attrs: any)
  local range = attrs.EffectDuration

  return rng:NextNumber(range.Min, range.Max)
end

-- the clone every emit plays on, with throwaway attachments when the length
-- moves: getting this wrong is not cosmetic, since setLengthScale below would
-- move the real attachments and the scope's restore runs on the clone
local function prepare(ctx: reader.Ctx, attrs: any): Beam?
  local ref = ctx.ref :: Beam
  local scope = ctx.scope
  local att0, att1 = ref.Attachment0, ref.Attachment1

  if not att0 or not att1 then
    return nil
  end

  local clone = ref:Clone()
  clone.Archivable = false
  clone.Parent = workspace.Terrain

  if attrs.LengthScale.animated then
    local a, b = att0:Clone(), att1:Clone()

    lifetime.hold(scope, a)
    lifetime.hold(scope, b)

    a.Name = "_ForgeTempAttachment"
    b.Name = "_ForgeTempAttachment"

    a:AddTag(utility.EMIT_EXCLUDE_TAG)
    b:AddTag(utility.EMIT_EXCLUDE_TAG)

    clone.Attachment0 = a
    clone.Attachment1 = b

    a.Parent = att0.Parent
    b.Parent = att1.Parent
  end

  lifetime.hold(scope, clone)

  -- the reader has already run by here, so the clone is for what this effect
  -- reads of its own below and for the plans that will read from it
  ctx.obj = clone

  return clone
end

function beam.emit(ctx: reader.Ctx, attrs: any, props: any)
  local obj = prepare(ctx, attrs)

  if obj == nil then
    return
  end

  local ref = ctx.ref :: Beam
  local scope = ctx.scope
  local duration = ctx.duration :: number

  local emitOnFinish = scope.effects.prepareEmitOnFinish(obj, scope)

  local width0 = props.Width0
  local width1 = props.Width1
  local curve0 = props.CurveSize0
  local curve1 = props.CurveSize1
  local texSpeed = props.TextureSpeed
  local texLength = props.TextureLength

  local speed = attrs.Speed
  local tScale = attrs.TransparencyScale
  local lengthScale = attrs.LengthScale

  task.wait(attrs.EmitDelay)

  obj.Enabled = true

  local promises = {}
  local currentSpeed = 1

  local speedTween

  local env = scope.effects.emitNested(obj, scope.depth + 1, scope)
  table.insert(promises, env.Finished)

  local baseTexSpeed = texSpeed.at(0)

  if texSpeed.animated then
    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, texSpeed.duration, function(_, deltaTime, elapsed)
        baseTexSpeed = texSpeed.at(elapsed)
        obj.TextureSpeed = baseTexSpeed * currentSpeed

        return deltaTime
      end)
    )
  end

  currentSpeed = speed.at(0)

  if speed.animated then
    speedTween = tween.fromParams(utility.linear_bezier, speed.duration, function(_, deltaTime, elapsed)
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

  -- every stepper below counts the beam's own clock, which the speed row scales
  local function step(track: reader.Track, write: (v: any) -> ())
    write(track.at(0))

    if not track.animated then
      return
    end

    lifetime.hold(
      scope,
      tween.fromParams(utility.linear_bezier, track.duration, function(_, deltaTime, elapsed)
        write(track.at(elapsed))
        return deltaTime * currentSpeed
      end, speedTween)
    )
  end

  step(tScale, setTScale)

  step(texLength, function(v)
    obj.TextureLength = v
  end)

  local lengthScaleStart = lengthScale.at(0)

  if lengthScale.animated then
    step(lengthScale, setLengthScale)
  elseif lengthScaleStart ~= 1 then
    setLengthScale(lengthScaleStart)
  end

  step(width0, function(v)
    obj.Width0 = v
  end)

  step(width1, function(v)
    obj.Width1 = v
  end)

  step(curve0, function(v)
    obj.CurveSize0 = v
  end)

  step(curve1, function(v)
    obj.CurveSize1 = v
  end)

  -- flipbook support
  local flipbookDuration = 0
  local flipbook = flipbook_common.getFlipbookData(ref)

  if flipbook then
    local config = {
      ref = ref,
      frames = flipbook,
      speedTween = speedTween,
      effectDuration = duration,
      syncDuration = attrs.SyncDuration,

      curve = attrs.FlipbookChangeCurve,
      duration = attrs.FlipbookChangeDuration,

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
