local knob = require("@mod/knob")
local lazy = require("@mod/lazy")

local controller = {}

const play = lazy.unit("controller", function()
  return require("@root/play/controller")
end)

controller.id = "controller"
controller.display = { name = "Controller", icon = "controller", order = 90 }
controller.classifier = "RayValue.Controller"

controller.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):ranged():label("Delay"):hint("Seconds before the controller starts."),
  EmitDuration = knob(1):min(0):unit("seconds"):label("Duration"):hint("Seconds the controller runs for."),
  Scope = knob("ParentAndDescendants")
    :options({ "Parent", "ParentAndDescendants", "Descendants", "Global" })
    :label("Scope")
    :hint(
      "What the controller scales: the effect on its parent (nothing if the parent hosts none), that and everything below it, only what is below it, or every effect."
    ),
  TimeScale = knob(1):min(0):mod():label("TimeScale"):hint("Multiplier on the clock of every effect in the scope."),
}

controller.properties = {}

controller.layout = {
  { title = "Emit", entries = { "EmitDelay", "EmitDuration" } },
  { title = "Time", entries = { "Scope", "TimeScale" } },
}

function controller.duration(_, attrs: any)
  return attrs.EmitDuration
end

function controller.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

return controller
