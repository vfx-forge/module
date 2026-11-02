const curve = require("@mod/curve")
const tween = require("@mod/tween")

const mover = require("@srv/mover")

const common = {}

export type ProjectileOptions = {
  params: OverlapParams?,
  follow: (() -> CFrame)?,
}

function common.hit(params: OverlapParams, obj: BasePart)
  return workspace:GetPartsInPart(obj, params)[1] ~= nil
end

-- a followed flight is carried by the live origin and takes its turn; an
-- unfollowed one keeps the part's own
function common.projectile(
  scope: any,
  obj: BasePart,
  velocity: vector,
  lifetime: number,
  opts: ProjectileOptions,
  done: () -> ()
)
  const params = opts.params
  const follow = opts.follow
  const start = mover.cframe(obj)
  const origin = start.Position
  const originAtStart = if follow ~= nil then follow() else CFrame.identity
  local hit = false

  -- a caller may be inside a tween's step, which must not yield
  task.spawn(function()
    tween.wait(scope, curve.new(lifetime, "linear"), function(_, _, elapsed: number)
      const at = CFrame.new(origin + velocity * elapsed)

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
