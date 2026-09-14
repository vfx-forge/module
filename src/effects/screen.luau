local RunService = game:GetService("RunService")

local knob = require("@mod/knob")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")

local Spin = require("@vfx/spin")

local screen = {}

screen.id = "screen"
screen.display = { name = "Screen Effect", icon = "screen", order = 65 }

-- an enabled part that is not a shockwave piece. its descendants are its own:
-- the emit below runs them under the placed part
screen.classifier = "BasePart[$Enabled=true]:not(.Shockwave >> BasePart)"
screen.components = "Instance"

screen.attributes = {
  Enabled = knob(false),
  PartDistance = knob(1.5):min(0):unit("studs"),
  PartScale = knob(vector.one),
  OffsetPosition = knob(vector.zero):unit("studs"),
  OffsetRotation = knob(vector.zero),
}

screen.properties = {}

screen.layout = {
  { title = "Part", entries = { "Enabled", "PartDistance", "PartScale" } },
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

  if anc and registry.of(anc) == Spin and not Spin.static(registry.read(anc)) then
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

  -- a render step binding always runs before RenderStepped in the editor
  local function frame()
    local camera = workspace.CurrentCamera

    local halfFovRad = math.rad(camera.FieldOfView / 2)
    local height = math.tan(halfFovRad) * distance * 2
    local width = (camera.ViewportSize.X / camera.ViewportSize.Y) * height

    local cf = camera.CFrame * CFrame.new(0, 0, -distance)

    ref.Size = Vector3.new(width, height, ref.Size.Z) * scale
    ref.CFrame = cf * CFrame.new(pos) * CFrame.fromOrientation(rot.x, rot.y, rot.z)
  end

  if not RunService:IsRunning() then
    lifetime.hold(scope, RunService.RenderStepped:Connect(frame))
  else
    local id = utility.getRandomId()

    RunService:BindToRenderStep(id, Enum.RenderPriority.Last.Value + 2 + scope.depth, frame)

    lifetime.hold(scope, function()
      RunService:UnbindFromRenderStep(id)
    end)
  end

  -- the part stays placed until the last effect under it finishes
  local env = scope.effects.emitNested(ref, scope.depth + 1, scope)
  env.Finished:await()
end

return screen
