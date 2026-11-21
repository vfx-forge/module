local knob = require("@mod/knob")
local lazy = require("@mod/lazy")
local utility = require("@mod/utility")

local screen = {}

const play = lazy.unit("screen", function()
  return require("@root/play/screen")
end)

screen.id = "screen"
screen.display = { name = "Screen Effect", icon = "screen", order = 60 }

-- an enabled part that is not a shockwave piece or a mesh template, which a
-- passive loop leaves enabled. its descendants are its own: the emit below
-- runs them under the placed part
screen.classifier = `BasePart[$Enabled=true]:not(.{utility.FORGE_MESH_TAG}):not(.Shockwave >> BasePart)`
screen.components = "Instance"

screen.attributes = {
  Enabled = knob(false):label("Enabled"):hint("Whether the screen effect is active."),
  PartDistance = knob(1.5):min(0):unit("studs"):label("Distance"):hint("Studs from the camera the part is held at."),
  PartScale = knob(vector.one):label("Scale"):hint("Multiplier on the computed full-frustum size."),
  OffsetPosition = knob(vector.zero)
    :unit("studs")
    :label("Position")
    :hint("Local offset from the camera-relative placement."),
  OffsetRotation = knob(vector.zero):label("Rotation"):hint("Initial rotation offset applied to the effect."),
}

screen.properties = {}

screen.layout = {
  { title = "Part", entries = { "Enabled", "PartDistance", "PartScale" } },
  { title = "Offset", entries = { "OffsetPosition", "OffsetRotation" } },
}

function screen.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

return screen
