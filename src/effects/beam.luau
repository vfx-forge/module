--!nolint LocalShadow
local knob = require("@mod/knob")
local lazy = require("@mod/lazy")
const flipbook_rows = require("@mod/common/flipbook_rows")

local rng = Random.new()

local beam = {}

const play = lazy.unit("beam", function()
  return require("@root/play/beam")
end)

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
  -- carries on from where its last emit left the scroll. a modifier sets it
  -- every frame from the emit on, which holds the scroll where it says
  TextureOffset = knob(0):mod():label("TextureOffset"):hint(
    "Where the texture's scroll starts on each emit, in cycles: 0.5 starts it halfway along. A modifier holds the scroll where it says each frame, so TextureSpeed does not move it."
  ),
  -- back on the card (owner 2026-11-18) after three days off it
  TransparencyScale = knob(1):min(0):aliases("Transparency_Scale"):mod():label("TransparencyScale"):hint(
    "Fades the beam's transparency keypoints: 0 opaque, 1 as set, 2 clear. A modifier here plays instead of the Transparency row's."
  ),
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
  -- is how a beam fades out at the end of each emit
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
      "TransparencyScale",
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

function beam.emit(ctx: any, attrs: any, props: any)
  return play().emit(ctx, attrs, props)
end

return beam
