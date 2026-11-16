--!nolint LocalShadow
local knob = require("@mod/knob")
local curve = require("@mod/curve")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local adapters = require("@mod/adapters")
local lifetime = require("@mod/lifetime")
const flipbook_rows = require("@mod/common/flipbook_rows")

local pool = require("@srv/pool")
local containers = require("@srv/containers")

local rng = Random.new()

-- a transparency under a TransparencyScale: below 1 toward opaque, above it
-- toward clear, by how far the scale is from 1
const function scaleTransparency(value: number, tscale: number): number
  const offset = if tscale > 1 then tscale - 1 else 1 - tscale
  const base = if tscale > 1 then 1 - value else -value

  return value + base * offset
end

const function scaledSequence(seq: NumberSequence, tscale: number): NumberSequence
  const keypoints = table.create(#seq.Keypoints)

  for i, kp in seq.Keypoints do
    keypoints[i] = NumberSequenceKeypoint.new(kp.Time, scaleTransparency(kp.Value, tscale), kp.Envelope)
  end

  return NumberSequence.new(keypoints)
end

local beam = {}

beam.id = "beam"
beam.display = { name = "Beam", icon = "beam", order = 80 }
beam.classifier = "Beam"

-- the beam runs the effects nested under it itself, per emit, on its clone
beam.components = "Instance"
beam.copies = true

beam.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
  EffectDuration = knob(NumberRange.new(1, 1))
    :min(0)
    :aliases("Duration")
    :unit("seconds")
    :label("Duration")
    :hint("Duration range of the effect in seconds."),
  Speed = knob(1):mod():label("Speed"):hint("Multiplier on the beam's clock."),
  LengthScale = knob(1)
    :aliases("Length_Scale")
    :mod()
    :label("LengthScale")
    :hint("Multiplier on the distance between the beam's attachments."),
  -- written to every copy as it is emitted, so beams laid end to end in a
  -- ring line their textures up into one band, and a pooled copy never
  -- carries on from where its last emit left the scroll
  TextureOffset = knob(0)
    :label("TextureOffset")
    :hint("Where the texture's scroll starts on each emit, in cycles: 0.5 starts it halfway along."),
  -- off the card (owner 2026-11-15): a modifier on Transparency does the
  -- same fade. still read, so a beam saved with one plays as it did
  TransparencyScale = knob(1)
    :min(0)
    :aliases("Transparency_Scale")
    :mod()
    :label("TransparencyScale")
    :hint("Multiplier on the beam's transparency keypoints.")
    :hidden(function()
      return true
    end),
}

for name, row in flipbook_rows.rows() do
  beam.attributes[name] = row
end

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
  -- a row of its own so it has the effect end's lane too: a Tween there to 1
  -- is how a beam fades out at the end of each emit, now that the card no
  -- longer shows TransparencyScale (owner 2026-11-15)
  Transparency = knob():mod():label("Transparency"):hint("Beam Transparency over the effect."),
}

-- the plugin's card. a property row, or a `property` entry, is the beam's own
-- property, which the card moves there from its engine category. groups and
-- rows run in the order Studio's own Properties widget lists them
beam.layout = {
  { title = "Emit", entries = { "EmitDelay" } },
  { title = "Effect", entries = { "EffectDuration", "Speed" } },
  {
    title = "Appearance",
    entries = {
      { property = "Brightness" },
      { property = "Color" },
      { property = "LightEmission" },
      { property = "LightInfluence" },
      "Transparency",
      { property = "ZOffset" },
    },
  },
  {
    title = "Shape",
    entries = {
      { property = "Attachment0" },
      { property = "Attachment1" },
      { action = "curve_shape", label = "Curve" },
      "CurveSize0",
      "CurveSize1",
      { property = "FaceCamera" },
      "LengthScale",
      { property = "Segments" },
      "Width0",
      "Width1",
    },
  },
  {
    title = "Texture",
    entries = {
      { property = "Texture" },
      "TextureLength",
      { property = "TextureMode" },
      "TextureOffset",
      "TextureSpeed",
      { action = "toggle_textures", label = "Load Textures" },
    },
  },
}

-- the flipbook's card, which the plugin shows once the beam has frames
beam.cards = {
  Flipbook = flipbook_rows.card(),
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

  -- the copy keeps its children, which the beam emits as its nested effects
  local clone = pool.take(scope, ref) :: Beam

  -- any length other than 1 moves attachments, and only throwaway ones may
  -- move, or an overlapping emit would read the scaled ones as authored
  local lengthScale = attrs.LengthScale

  if lengthScale.animated or lengthScale.at(0) ~= 1 then
    local a = pool.take(scope, att0, true) :: Attachment
    local b = pool.take(scope, att1, true) :: Attachment

    a.Name = "_ForgeTempAttachment"
    b.Name = "_ForgeTempAttachment"

    a:AddTag(utility.EMIT_EXCLUDE_TAG)
    b:AddTag(utility.EMIT_EXCLUDE_TAG)

    clone.Attachment0 = a
    clone.Attachment1 = b

    a.Parent = att0.Parent
    b.Parent = att1.Parent
  end

  -- the reader has already run by here, so the clone is for what this effect
  -- reads of its own below and for the plans that will read from it
  ctx.obj = clone

  if ctx.copied then
    ctx.copied(clone, scope)
  end

  return clone
end

-- where a finished beam's EmitOnFinish plays: a stand-in for the beam's own parent, which it played in before the
-- runtime kept its copies in the container, so an attachment there keeps its offset and an emitter its volume.
-- the parent is the author's, so nothing is parented into it
local function finishHost(scope: lifetime.effect, ref: Beam, obj: Beam): BasePart
  const host = lifetime.hold(scope, Instance.new("Part"))
  const parent = ref.Parent
  const a0, a1 = obj.Attachment0, obj.Attachment1

  host.Name = "EmitOnFinish"
  host.Archivable = false
  host.Anchored = true
  host.CanCollide = false
  host.CanQuery = false
  host.CanTouch = false
  host.CastShadow = false
  host.Transparency = 1

  if parent ~= nil and parent:IsA("BasePart") then
    host.Size = parent.Size
    host.CFrame = parent.CFrame
  elseif parent ~= nil and parent:IsA("Attachment") then
    host.Size = Vector3.zero
    host.CFrame = parent.WorldCFrame
  elseif a0 ~= nil and a1 ~= nil then
    host.Size = Vector3.zero
    host.CFrame = CFrame.new(a0.WorldPosition:Lerp(a1.WorldPosition, 0.5))
  end

  host.Parent = containers.of("beam")

  return host
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

    for i, kd in keypointData do
      scaledKeypoints[i] = NumberSequenceKeypoint.new(kd.time, scaleTransparency(kd.value, tscale), kd.envelope)
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

  -- the Transparency row's own modifiers. a beam saved with a modifier on
  -- TransparencyScale plays that one instead, as it always did: the two would
  -- write the same property. a still scale applies over the row as it does
  -- over the beam's own keypoints, or the row's first write dropped it
  if props.Transparency.animated and not tScale.animated then
    const still = tScale.at(0)

    tween.drive(scope, props.Transparency, function(v: NumberSequence)
      obj.Transparency = if still == 1 then v else scaledSequence(v, still)
    end)
  end

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

  const flipbookDuration = flipbook_rows.play(scope, ref, attrs, duration, function(texture: string)
    obj.Texture = texture
  end)

  -- after the flipbook's first frame: on a beam with no texture yet the call
  -- does nothing
  obj:SetTextureOffset(attrs.TextureOffset)

  -- a Speed resting at 0 for good ends the beam rather than holding it
  tween.wait(scope, curve.new(math.max(duration, flipbookDuration), "linear"))

  if emitOnFinish then
    scope.effects.emitOnFinish(emitOnFinish, finishHost(scope, ref, obj), scope.depth + 1, scope, children)
  end

  lifetime.awaitJoin(children)
end

return beam
