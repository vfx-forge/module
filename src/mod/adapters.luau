local clock = require("@mod/clock")
local lifetime = require("@mod/lifetime")

local adapters = {}

-- a beam's texture scrolls at its TextureSpeed times the effect's clock, so
-- a pause stops it. written at once only when it differs from what the beam
-- already holds. answers what sets the authored TextureSpeed
function adapters.beam(scope: lifetime.effect, obj: any, base: number, animated: boolean): (base: number) -> ()
  local timeline = scope.clock

  local function apply()
    obj.TextureSpeed = base * clock.factorOf(timeline)
  end

  if animated or clock.factorOf(timeline) ~= 1 then
    apply()
  end

  lifetime.hold(scope, clock.watch(timeline, apply))

  return function(value: number)
    base = value
    apply()
  end
end

return adapters
