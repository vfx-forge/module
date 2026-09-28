local knob = require("@mod/knob")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")

local Spin = require("@vfx/spin")

local screen = {}

screen.id = "screen"
screen.display = { name = "Screen Effect", icon = "screen", order = 60 }

-- an enabled part that is not a shockwave piece. its descendants are its own:
-- the emit below runs them under the placed part
screen.classifier = "BasePart[$Enabled=true]:not(.Shockwave >> BasePart)"
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
  "Enabled",
  { title = "Part", entries = { "PartDistance", "PartScale" } },
  { title = "Offset", entries = { "OffsetPosition", "OffsetRotation" } },
}

function screen.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: BasePart
  local scope = ctx.scope

  if not attrs.Enabled or lifetime.lock(scope, ref) then
    return
  end

  -- a part under a model that moves would fight it for the camera
  local anc = ref:FindFirstAncestorOfClass("Model")
  local ancModule = if anc then registry.of(anc) else nil

  if anc and ancModule == Spin and not Spin.static((registry.read(anc, ancModule))) then
    return
  end

  local scale = attrs.PartScale
  local distance = attrs.PartDistance

  local pos = attrs.OffsetPosition
  local rot = attrs.OffsetRotation * utility.DEG_TO_RAD

  local originalCF = ref.CFrame
  local originalSize = ref.Size
  local originalColGroup = ref.CollisionGroup

  ref.CollisionGroup = "ForgeMouseIgnore"

  lifetime.hold(scope, function()
    ref.Size = originalSize
    ref.CFrame = originalCF
    ref.CollisionGroup = originalColGroup ~= "" and originalColGroup or "Default"
  end)

  local function frame()
    local camera = workspace.CurrentCamera

    local halfFovRad = math.rad(camera.FieldOfView / 2)
    local height = math.tan(halfFovRad) * distance * 2
    local width = (camera.ViewportSize.X / camera.ViewportSize.Y) * height

    local cf = camera.CFrame * CFrame.new(0, 0, -distance)

    ref.Size = Vector3.new(width, height, ref.Size.Z) * scale
    ref.CFrame = cf * CFrame.new(pos) * CFrame.fromOrientation(rot.x, rot.y, rot.z)
  end

  -- placed once the camera has settled, and before anything that follows it
  lifetime.step(scope, frame, "screen")

  -- the part stays placed until the last effect under it finishes
  local children = lifetime.join(scope)

  scope.effects.emitNested(ref, scope.depth + 1, scope, children)
  lifetime.awaitJoin(children)
end

return screen
