local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")

local Spin = require("@vfx/spin")

local play = {}

function play.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: BasePart
  local scope = ctx.scope

  if not attrs.Enabled or lifetime.lock(scope, ref) then
    return
  end

  -- a part under a model that moves would fight it for the camera
  local anc = ref:FindFirstAncestorOfClass("Model")
  local ancModule = if anc then registry.of(anc) else nil

  if anc and ancModule == Spin and not Spin.static((registry.read(anc, ancModule)), anc) then
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

  scope.effects.emitNested(ref, scope.depth + 1, scope, children, ref)
  lifetime.awaitJoin(children)
end

return play
