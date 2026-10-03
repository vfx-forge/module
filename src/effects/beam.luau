--!nolint LocalShadow
local knob = require("@mod/knob")
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local adapters = require("@mod/adapters")
local lifetime = require("@mod/lifetime")
local flipbook_common = require("@mod/common/flipbook")

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

-- the clone every emit plays on, with throwaway attachments whenever the
-- length is not 1: getting this wrong is not cosmetic, since setLengthScale
-- below would move the real attachments and the scope's restore runs on the
-- clone
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

  -- any length other than 1 moves attachments, and only throwaway ones may
  -- move, or an overlapping emit would read the scaled ones as authored
  local lengthScale = attrs.LengthScale

  if lengthScale.animated or lengthScale.at(0) ~= 1 then
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

  lifetime.wait(scope, attrs.EmitDelay)

  obj.Enabled = true

  local children = lifetime.join(scope)

  lifetime.speed(scope, speed)

  scope.effects.emitNested(obj, scope.depth + 1, scope, children)

  local setTexSpeed = adapters.beam(scope, obj, texSpeed.at(0), texSpeed.animated)

  if texSpeed.animated then
    tween.drive(scope, texSpeed, setTexSpeed)
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

  -- every tween below counts the beam's own clock, which the speed row scales
  tween.drive(scope, tScale, setTScale)

  tween.drive(scope, texLength, function(v: number)
    obj.TextureLength = v
  end)

  local lengthScaleStart = lengthScale.at(0)

  if lengthScale.animated then
    tween.drive(scope, lengthScale, setLengthScale)
  elseif lengthScaleStart ~= 1 then
    setLengthScale(lengthScaleStart)
  end

  tween.drive(scope, width0, function(v: number)
    obj.Width0 = v
  end)

  tween.drive(scope, width1, function(v: number)
    obj.Width1 = v
  end)

  tween.drive(scope, curve0, function(v: number)
    obj.CurveSize0 = v
  end)

  tween.drive(scope, curve1, function(v: number)
    obj.CurveSize1 = v
  end)

  -- flipbook support
  local flipbookDuration = 0
  local flipbook = flipbook_common.getFlipbookData(ref)

  if flipbook then
    local config = {
      ref = ref,
      frames = flipbook,
      effectDuration = duration,
      syncDuration = attrs.SyncDuration,

      curve = attrs.FlipbookChangeCurve,
      duration = attrs.FlipbookChangeDuration,

      setTexture = function(texture)
        obj.Texture = texture
      end,
    }

    flipbookDuration = flipbook_common.getChangeDuration(config)

    tween.play(scope, curve.new(flipbookDuration, config.curve), flipbook_common.createUpdateCallback(config))
  end

  -- a Speed resting at 0 for good ends the beam rather than holding it
  tween.wait(scope, curve.new(math.max(duration, flipbookDuration), "linear"))

  if emitOnFinish then
    scope.effects.emitOnFinish(emitOnFinish, obj.Parent or workspace.Terrain, scope.depth + 1, scope, children)
  end

  lifetime.awaitJoin(children)
end

return beam
