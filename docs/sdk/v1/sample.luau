local effect = {}

effect.sdk_version = 1
effect.id = "pulse"
effect.display = { name = "Pulse" }
effect.classifier = "BasePart.Pulse"

effect.layout = {
  { title = "Emit", entries = { "EmitDelay" } },
  { title = "Pulse", entries = { "FadeTime", "FadeCurve", "Growth", "EndColor", "Shine" } },
}

function effect.params(sdk)
  return {
    attributes = {
      EmitDelay = sdk
        .knob(0)
        :min(0)
        :unit("seconds")
        :label("Delay")
        :hint("Seconds before the pulse starts; 0 to 1 suits most hits."),
      FadeTime = sdk
        .knob(0.5)
        :min(0)
        :unit("seconds")
        :label("Fade")
        :hint("Seconds the part takes to fade out; 0.2 to 2 reads well."),
      FadeCurve = sdk.knob("easeOut"):curve("easeOut"):label("Curve"):hint("How the fade eases."),
      Growth = sdk.knob(2):min(0):slider(1, 4):label("Growth"):hint("Times its size the part grows to; 1 to 4."),
      EndColor = sdk.knob(Color3.new(1, 1, 1)):label("Color"):hint("The color the part fades to."),
      Shine = sdk
        .knob(0)
        :min(0)
        :max(1)
        :mod(sdk.mod.to(0.6):duration(0.2))
        :label("Shine")
        :hint("How much the part reflects, 0 to 1; by default it rises to 0.6 in 0.2 seconds and holds."),
    },
  }
end

function effect.duration(_, attrs)
  return attrs.EmitDelay + attrs.FadeTime
end

function effect.emit(sdk, ctx, attrs)
  sdk.lock(ctx)
  sdk.wait(ctx, attrs.EmitDelay)

  local part = ctx.ref
  local size = part.Size
  local color = part.Color
  local start = part.Transparency

  local transparency = sdk.getWriter(ctx, part, "Transparency")
  local grow = sdk.getWriter(ctx, part, "Size")
  local tint = sdk.getWriter(ctx, part, "Color")
  local shine = sdk.getWriter(ctx, part, "Reflectance")

  sdk.apply(ctx, attrs.Shine, function(value)
    shine:set(value)
  end)

  sdk.tween(ctx, sdk.curve(attrs.FadeTime, attrs.FadeCurve), function(alpha)
    transparency:set(sdk.lerp(start, 1, alpha))
    grow:set(size * sdk.lerp(1, attrs.Growth, alpha))
    tint:set(sdk.color.blend(color, attrs.EndColor, alpha))
  end)
end

return effect
