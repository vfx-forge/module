local curve = require("@mod/curve")
local tween = require("@mod/tween")

local mover = require("@srv/mover")

local common = {}

export type ProjectileOptions = {
  params: OverlapParams?,
  follow: (() -> CFrame)?,
}

function common.hit(params: OverlapParams, obj: BasePart)
  return workspace:GetPartsInPart(obj, params)[1] ~= nil
end

-- flown on from where the mover last put it; a followed flight is carried by
-- the live origin and takes its turn, an unfollowed one keeps the part's own
function common.projectile(
  scope: any,
  obj: BasePart,
  velocity: vector,
  lifetime: number,
  opts: ProjectileOptions,
  done: () -> ()
)
  local params = opts.params
  local follow = opts.follow
  local origin = mover.cframe(obj).Position
  local originAtStart = if follow ~= nil then follow() else CFrame.identity
  local hit = false

  -- a caller may be inside a tween's step, which must not yield
  task.spawn(function()
    tween.wait(scope, curve.new(lifetime, "linear"), function(_, _, elapsed: number)
      local at = CFrame.new(origin + velocity * elapsed)

      if follow ~= nil then
        mover.move(scope, obj, follow() * originAtStart:ToObjectSpace(at))
      else
        mover.move(scope, obj, at * mover.cframe(obj).Rotation)
      end

      if params ~= nil and common.hit(params, obj) then
        hit = true
        done()
        return false
      end

      return true
    end, scope.depth)

    if not hit then
      done()
    end
  end)
end

return common
