--!nolint LocalShadow
local mod = require("@mod/mod")
local knob = require("@mod/knob")
local lazy = require("@mod/lazy")
local utility = require("@mod/utility")
local bezier_common = require("@mod/common/bezier")

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

local lightning = {}

const play = lazy.unit("lightning", function()
  return require("@root/play/lightning").bind(lightning)
end)

lightning.id = "lightning"
lightning.display = { name = "Lightning (legacy)", icon = "lightning", order = 120 }
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

  Color = knob(ColorSequence.new(Color3.new(1, 1, 1))):label("Color"):hint("Color of the segments."),
  ColorCurve = knob(linear):aliases("Color_Curve"):label("Curve"):hint("Easing of the color cycle."),
  ColorDuration = knob(1)
    :min(0)
    :aliases("Color_Duration")
    :unit("seconds")
    :label("Duration")
    :hint("Seconds one color cycle takes."),

  FillColor = knob(ColorSequence.new(Color3.new(1, 1, 1)))
    :aliases("Fill_Color")
    :label("Color")
    :hint("Fill (glow) color of the bolt."),
  FillColorCurve = knob(linear):aliases("Fill_Color_Curve"):label("Curve"):hint("Easing of the fill color cycle."),
  FillColorDuration = knob(1)
    :min(0)
    :aliases("Fill_Color_Duration")
    :unit("seconds")
    :label("Duration")
    :hint("Seconds one fill color cycle takes."),
  FillDepthMode = knob("Occluded")
    :options({ "AlwaysOnTop", "Occluded" })
    :aliases("Fill_DepthMode")
    :label("DepthMode")
    :hint("Occlusion mode for the fill highlight."),
  FillTransparency = knob(1)
    :aliases("Fill_Transparency")
    :mod()
    :label("Transparency")
    :hint("Fill transparency over the fill color's duration."),

  -- the six old fade keys stay rows so the Transparency row's default fades
  -- read them and retime still scales the two spans
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

function lightning.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

-- in the declarations, so selecting one never loads what it plays
function lightning.selected(ctx: any)
  local ref = ctx.ref :: Attachment
  local points = ref:FindFirstChild("Points")
  local template = ref:FindFirstChildOfClass("Part")

  if template == nil or points == nil or not points:IsA("Attachment") then
    return
  end

  template.CFrame = ref.WorldCFrame
end

return lightning
