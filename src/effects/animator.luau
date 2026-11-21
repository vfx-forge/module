local knob = require("@mod/knob")
local lazy = require("@mod/lazy")
local utility = require("@mod/utility")

local animator = {}

const play = lazy.unit("animator", function()
  return require("@root/play/animator")
end)

animator.id = "animator"
animator.display = { name = "Property Animator", icon = "animator", order = 95 }
animator.classifier = `RayValue.{utility.PROPERTY_ANIMATOR_TAG}`

animator.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the animation starts."),
  Target = knob():instance():label("Target"):hint("The instance animated. Empty animates the parent."),
  Property = knob(""):label("Property"):hint("The property of the target that is animated."),
  ResetOnFinish = knob(true)
    :label("ResetOnFinish")
    :hint("Whether the property goes back to what it was once the animation ends."),
}

animator.properties = {}

animator.layout = {
  { title = "Emit", entries = { "EmitDelay" } },
  { title = "Animation", entries = { "Target", "Property", "ResetOnFinish" } },
}

function animator.duration(ctx: any, attrs: any)
  return play().duration(ctx, attrs)
end

function animator.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

return animator
