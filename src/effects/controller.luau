local knob = require("@mod/knob")
local clock = require("@mod/clock")
local reader = require("@mod/reader")
local lifetime = require("@mod/lifetime")

local controller = {}

-- how many running controllers scale each clock under each shared key, so the
-- last of them takes that scale off
local HOLDERS = setmetatable({} :: { [any]: { [clock.Clock]: number } }, { __mode = "k" })

controller.id = "controller"
controller.display = { name = "Controller", icon = "controller", order = 90 }
controller.classifier = "RayValue.Controller"

controller.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the controller starts."),
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
  { title = "Effect", entries = { "EmitDelay", "EmitDuration" } },
  { title = "Time", entries = { "Scope", "TimeScale" } },
}

function controller.duration(_, attrs: any)
  return attrs.EmitDuration
end

-- the clocks a scope scales: a local one around the parent instance, the
-- global one for Global
local function targetsOf(region: any, mode: string): { clock.Clock }
  if mode == "Global" then
    return { clock.global }
  end

  if region == nil then
    return {}
  end

  if mode == "Parent" then
    return { region.here }
  end

  if mode == "Descendants" then
    return { region.below }
  end

  -- below already hangs from here under a nested emit
  if region.nested then
    return { region.here }
  end

  return { region.here, region.below }
end

function controller.emit(ctx: reader.Ctx, attrs: any)
  local scope = ctx.scope
  local region, shared = scope.effects.regionOf(scope)
  local key = shared or scope
  local mode = attrs.Scope

  -- a Global controller runs on real time that only a global pause stops,
  -- so it never slows itself or another Global controller
  if mode == "Global" then
    clock.reparent(scope.clock, clock.wall)
  end

  local targets = targetsOf(region, mode)

  lifetime.wait(scope, attrs.EmitDelay)

  local holders = HOLDERS[key]

  if holders == nil then
    holders = {}
    HOLDERS[key] = holders
  end

  for _, target in targets do
    holders[target] = (holders[target] or 0) + 1
  end

  -- taken off on end, on a clear and at deinit, so nothing stays slowed
  lifetime.hold(scope, function()
    for _, target in targets do
      local left = holders[target] - 1

      holders[target] = if left > 0 then left else nil

      if left <= 0 then
        clock.unscale(target, key)
      end
    end
  end)

  -- a nan would pass math.max and stall every clock below the target for good
  attrs.TimeScale:apply(function(v: any)
    if typeof(v) ~= "number" or v ~= v then
      return
    end

    for _, target in targets do
      clock.scale(target, key, math.max(v, 0))
    end
  end)

  lifetime.wait(scope, attrs.EmitDuration)
end

return controller
