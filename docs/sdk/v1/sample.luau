local effect = {}

effect.sdk_version = 1
effect.id = "pulse"
effect.display = { name = "Pulse" }
effect.classifier = "BasePart.Pulse"

effect.layout = {
  { title = "Pulse", entries = { "FadeTime", "FadeCurve", "Growth", "Speed" } },
  { title = "Color", entries = { "EndColor" } },
}

function effect.params(sdk)
  return {
    attributes = {
      FadeTime = sdk.knob(0.5):min(0):unit("seconds"):label("Fade"):hint("Seconds the part takes to fade out."),
      FadeCurve = sdk.knob("easeOut"):curve("easeOut"):label("Curve"):hint("How the fade eases."),
      Growth = sdk.knob(2):min(0):label("Growth"):hint("Times its size the part grows to."),
      EndColor = sdk.knob(Color3.new(1, 1, 1)):label("Color"):hint("The color the part fades to."),
      Speed = sdk.knob(1):min(0):mod():label("Speed"):hint("Multiplier on the pulse's clock."),
    },
  }
end

function effect.duration(_, attrs)
  return attrs.FadeTime
end

function effect.emit(sdk, ctx, attrs)
  local part = ctx.ref
  local size = part.Size
  local color = part.Color
  local start = part.Transparency

  sdk.speed(ctx, attrs.Speed)

  local transparency = sdk.getWriter(ctx, part, "Transparency")
  local grow = sdk.getWriter(ctx, part, "Size")
  local tint = sdk.getWriter(ctx, part, "Color")

  sdk.tween(ctx, sdk.curve(attrs.FadeTime, attrs.FadeCurve), function(alpha)
    transparency:set(sdk.lerp(start, 1, alpha))
    grow:set(size * sdk.lerp(1, attrs.Growth, alpha))
    tint:set(sdk.color.blend(color, attrs.EndColor, alpha))
  end)
end

return effect
