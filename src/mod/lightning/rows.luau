const rows = {}

const function notDirection(_: any, attrs: any): boolean
  return attrs.Target ~= "Direction"
end

const function notEnd(_: any, attrs: any): boolean
  return attrs.Target ~= "End"
end

const function notGround(_: any, attrs: any): boolean
  return attrs.Target ~= "Ground"
end

const function forkless(_: any, attrs: any): boolean
  const forks = attrs.Forks

  return forks ~= nil and math.floor(forks) <= 0
end

-- Rate paces an EmitDuration window as well as the loop
const function loopless(_: any, attrs: any): boolean
  const duration = attrs.EmitDuration

  return attrs.Enabled == false and not (type(duration) == "number" and duration > 0)
end

-- one bolt that stays while the loop or a Duration runs, so nothing is paced and nothing holds for a set time
const function lasting(_: any, attrs: any): boolean
  return attrs.Continuous == true and not loopless(_, attrs)
end

const function paced(_: any, attrs: any): boolean
  return loopless(_, attrs) or lasting(_, attrs)
end

const function instant(_: any, attrs: any): boolean
  return attrs.Appear == "Instant"
end

-- an animated row reaches a rule as a Track, a plain read as its value
const function read(attrs: any, name: string): any
  const value = attrs[name]

  if type(value) == "table" then
    return value.value
  end

  return value
end

const function flowing(_: any, attrs: any): boolean
  return read(attrs, "Motion") == "Flow"
end

const function jittering(_: any, attrs: any): boolean
  return read(attrs, "Motion") == "Jitter"
end

const function tube(_: any, attrs: any): boolean
  return read(attrs, "Style") == "Tube"
end

rows.layout = {
  { title = "Emit", entries = { "EmitDelay", "EmitDuration", "Count", "Enabled", "Continuous", "Rate" } },
  { title = "Path", entries = { "Target", "EndPoint", "Length", "Spread", "Reach", "Jagged", "Detail" } },
  { title = "Motion", entries = { "Motion", "Jitter", "FlowSpeed" } },
  { title = "Forks", entries = { "Forks", "ForkLength", "Latch" } },
  { title = "Look", entries = { "Style", "Width", "Taper" } },
  { title = "Color", entries = { "Gradient", "Heat", "GradientRestart" } },
  { title = "Glow", entries = { "Glow" }, hidden = tube },
  { title = "Light", entries = { "Light", "LightColor" } },
  { title = "Appear", entries = { "Appear", "AppearTime", "AppearCurve" } },
  { title = "Hold", entries = { "Hold", "Restrikes" }, hidden = lasting },
  { title = "Disappear", entries = { "Disappear", "DisappearTime", "DisappearCurve" } },
  { title = "Impact", entries = { "ImpactFacing" } },
}

-- the glow shell is drawn outside Tube while Glow can show
function rows.glowing(style: string, glow: { value: number, animated: boolean })
  return style ~= "Tube" and (glow.value > 0 or glow.animated)
end

function rows.params(sdk: any): { attributes: { [string]: any } }
  return {
    attributes = {
      EmitDelay = sdk.knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the first bolt strikes."),
      EmitDuration = sdk
        .knob(0)
        :min(0)
        :unit("seconds")
        :label("Duration")
        :hint("Seconds the loop plays at Rate when the lightning is emitted. 0 emits it once."),
      Count = sdk
        .knob(1)
        :min(1)
        :label("Count")
        :hint("Bolts each emit makes, each with its own shape and timing. 1 to 5 reads as one storm."),
      Enabled = sdk
        .knob(false)
        :label("Enabled")
        :hint("Keeps striking on a loop while on, a new emit at the rate below."),
      Continuous = sdk.knob(false):label("Continuous"):hint(
        "One bolt stays and keeps moving while Enabled is on, or for the Duration, instead of a new bolt at the rate. It disappears once Enabled goes off."
      ),
      Rate = sdk
        .knob(5)
        :min(0)
        :unit("perSecond")
        :hidden(paced)
        :label("Rate")
        :hint("Emits a second while the loop or a Duration runs. 2 to 10 crackles."),
      Target = sdk.knob("End"):options({ "Direction", "End", "Ground" }):label("Target"):hint(
        "Where the bolt ends. Direction shoots along the attachment's up axis, End runs to the End point, or without one to the End attachment inside it, and follows it, Ground strikes the nearest surface below."
      ),
      EndPoint = sdk.knob():instance({ "Attachment" }):hidden(notEnd):label("End point"):hint(
        "An attachment anywhere in the place for the bolt to run to and follow. Empty runs to the End attachment inside the lightning."
      ),
      Length = sdk
        .knob(20)
        :min(0)
        :unit("studs")
        :hidden(notDirection)
        :label("Length")
        :hint("How far the bolt reaches along the up axis."),
      Spread = sdk.knob(Vector2.zero):hidden(notDirection):label("Spread"):hint(
        "Degrees each bolt may tilt away from the up axis, around x and y. 0 aims every bolt the same way."
      ),
      Reach = sdk
        .knob(30)
        :min(1)
        :unit("studs")
        :hidden(notGround)
        :label("Reach")
        :hint("How far below the attachment a surface is looked for. Nothing found, the bolt ends in the air."),
      Jagged = sdk.knob(0.1):min(0):max(0.5):slider():label("Jagged"):hint(
        "How far the zigzags stray, as a share of the bolt's length. 0 is straight, 0.05 to 0.2 reads as lightning."
      ),
      Detail = sdk
        .knob(16)
        :min(2)
        :max(32)
        :label("Detail")
        :hint("Segments in the main bolt. More makes finer zigzags; 8 to 24 looks right."),
      Jitter = sdk
        .knob(15)
        :min(0)
        :unit("perSecond")
        :hidden(flowing)
        :label("Jitter")
        :hint("Times a second the bolt takes a new zigzag while it shows. 0 keeps one shape."),
      Motion = sdk.knob("Jitter"):options({ "Jitter", "Flow" }):label("Mode"):hint(
        "Jitter takes a new zigzag several times a second. Flow slides the kinks along the bolt like a wave."
      ),
      FlowSpeed = sdk
        .knob(1)
        :unit("perSecond")
        :hidden(jittering)
        :label("Speed")
        :hint("Bolt lengths a second the kinks slide. Negative flows back toward the origin."),
      Forks = sdk.knob(3):min(0):max(8):label("Amount"):hint("Branches leaving the middle of the bolt. 0 makes none."),
      ForkLength = sdk
        .knob(0.3)
        :min(0.05)
        :max(1)
        :slider()
        :hidden(forkless)
        :label("Length")
        :hint("How long the branches are, as a share of the bolt's length."),
      Latch = sdk.knob(0):min(0):unit("studs"):hidden(forkless):label("Latch"):hint(
        "Branches bend onto a surface within this many studs of their tip and strike it. 0 keeps them in the air."
      ),
      Style = sdk.knob("Tube"):options({ "Tube", "Glow", "Segments" }):label("Style"):hint(
        "Tube is the bright core alone. Glow wraps it in a soft shell of the bolt's color. Segments builds the bolt from blocky parts, which also work where meshes are not allowed."
      ),
      Width = sdk
        .knob(0.7)
        :min(0)
        :unit("studs")
        :mod()
        :label("Width")
        :hint("How thick the bolt is where it starts. 0.3 to 1.5 for most bolts."),
      Taper = sdk
        .knob(0)
        :min(0)
        :max(1)
        :slider()
        :label("Taper")
        :hint("How thick each tip is, as a share of where it starts. 1 keeps the width all the way."),
      Gradient = sdk.knob(ColorSequence.new(Color3.new(1, 1, 1))):mod():label("Color"):hint(
        "The bolt's color from the origin to the tip. One color paints the whole bolt, more keys shift it along its length. The glow shows it as it is, the core whitened by Heat."
      ),
      Heat = sdk.knob(0.8):min(0):max(1):slider():mod():label("Heat"):hint(
        "How white-hot the core is. 0 makes the core the bolt's color, 1 a white center with the color only in the glow around it."
      ),
      GradientRestart = sdk.knob(true):hidden(forkless):label("Restart on forks"):hint(
        "Each fork starts the color over, as if it were a bolt of its own. Off carries it on from where the fork leaves the bolt."
      ),
      Glow = sdk.knob(1):min(0):max(1):slider():mod():label("Strength"):hint(
        "How strong the soft glow of the bolt's color around the core is. 0 leaves the bare core, 1 is the strongest."
      ),
      Light = sdk
        .knob(0)
        :min(0)
        :label("Brightness")
        :hint("How bright a light flashes at the bolt's middle. 0 casts none, 2 to 10 lights the scene."),
      LightColor = sdk
        .knob(Color3.new(1, 1, 1))
        :mod()
        :label("Color")
        :hint("Color of the light the bolt casts on what is around it."),
      Appear = sdk.knob("Strike"):options({ "Instant", "Grow", "Strike" }):label("Mode"):hint(
        "How the bolt shows. Instant is whole at once, Grow draws it from the origin out, Strike grows a faint leader and then flashes."
      ),
      AppearTime = sdk
        .knob(NumberRange.new(0.06, 0.1))
        :min(0)
        :unit("seconds")
        :hidden(instant)
        :label("Time")
        :hint("Seconds the bolt takes to reach its end, picked between the two for each bolt."),
      AppearCurve = sdk
        .knob("linear")
        :curve("linear")
        :hidden(instant)
        :label("Curve")
        :hint("How the growth speeds up or slows down on its way out."),
      Hold = sdk
        .knob(NumberRange.new(0.2, 0.3))
        :min(0)
        :unit("seconds")
        :label("Time")
        :hint("Seconds the whole bolt stays, picked between the two for each bolt."),
      Restrikes = sdk
        .knob(1)
        :min(0)
        :label("Restrikes")
        :hint("Times the bolt blinks out and strikes again in a new shape while it holds. 0 to 3."),
      Disappear = sdk.knob("Thin"):options({ "Thin", "Fade", "Retract", "Recoil" }):label("Mode"):hint(
        "How the bolt goes. Thin narrows it to nothing, Fade fades the bolt out at full width, Retract lets go of the origin first, Recoil pulls the tips back in."
      ),
      DisappearTime = sdk.knob(0.25):min(0):unit("seconds"):label("Time"):hint("Seconds the bolt takes to go."),
      DisappearCurve = sdk
        .knob("easeIn")
        :curve("easeIn")
        :label("Curve")
        :hint("How the disappearance speeds up or slows down."),
      ImpactFacing = sdk.knob("Surface"):options({ "Surface", "Bolt", "Upright" }):label("Facing"):hint(
        "How effects in EmitOnImpact are turned. Surface lies them on what was hit, Bolt points them along the bolt, Upright keeps them level."
      ),
    },
  }
end

return rows
