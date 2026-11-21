--!nolint LocalShadow
local knob = require("@mod/knob")
local lazy = require("@mod/lazy")
local utility = require("@mod/utility")
local bezier_common = require("@mod/common/bezier")

local bezier = {}

const play = lazy.unit("bezier", function()
  return require("@root/play/bezier").bind(bezier)
end)

bezier.id = "bezier"
bezier.display = { name = "Bezier (legacy)", icon = "bezier", order = 110 }
bezier.classifier = "Attachment.BezierParticle"

-- the template part, the points and the end attachments under the bolt are
-- its own; the effects nested in the template part run per emitted piece
bezier.components = "Instance"
bezier.constant = true

bezier.attributes = bezier_common.rows({
  FacePath = knob(false):label("FacePath"):hint("Whether the part orients along its direction of travel."),
  ArcSpace = knob(false):label("ArcSpace"):hint("Whether progress is measured by arc length."),
  MinInitRot = knob(vector.zero)
    :label("Min")
    :hint("Lower per-axis bound for each path's initial rotation, in radians."),
  MaxInitRot = knob(vector.zero)
    :label("Max")
    :hint("Upper per-axis bound for each path's initial rotation, in radians."),
  EasingCurve = knob(function()
      return utility.linear_bezier
    end)
    :aliases("Easing_Curve")
    :label("Easing")
    :hint("Easing of travel along the path."),
  RotSpeed = knob(0):unit("perSecond"):mod():label("Speed"):hint(
    "Rotation speed drawn for each piece, in degrees per second, on the axes its initial rotation turns."
  ),
})

bezier.properties = {}

-- the rotation rows sit between the shared end point and the projectile phase
bezier.layout = bezier_common.layout({
  {
    title = "Random Rotation",
    entries = { { title = "Speed", entries = { "RotSpeed" } }, "MinInitRot", "MaxInitRot" },
  },
}, {
  { title = "Animation", entries = { "FacePath", "ArcSpace", "EasingCurve" } },
  {
    title = "Behavior",
    entries = {
      { action = "edit_path", label = "Edit Bezier" },
      { action = "toggle_paths", label = "Show Paths" },
    },
  },
})

-- the longest a bolt of this emit can run, which the emit's own queues run over
function bezier.duration(_, attrs: any)
  return attrs.Duration.Max
end

function bezier.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

-- in the declarations, so selecting one never loads what it plays
function bezier.selected(ctx: any)
  local ref = ctx.ref :: Attachment
  local points = ref:FindFirstChild("Points")
  local template = ref:FindFirstChildOfClass("Part")

  if template == nil or points == nil or not points:IsA("Attachment") then
    return
  end

  template.CFrame = ref.WorldCFrame
end

return bezier
