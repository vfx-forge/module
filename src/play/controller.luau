local clock = require("@mod/clock")
local reader = require("@mod/reader")
local lifetime = require("@mod/lifetime")

local numeric_common = require("@mod/common/numeric")

-- each running controller under a shared key, for each clock it scales,
-- oldest first: the newest one's value is that key's scale, and when it ends
-- the one before it takes over, the last taking the scale off
type Holding = { value: number? }

local HOLDERS = setmetatable({} :: { [any]: { [clock.Clock]: { Holding } } }, { __mode = "k" })

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

local play = {}

function play.emit(ctx: reader.Ctx, attrs: any)
  local scope = ctx.scope
  local region, source = scope.effects.regionOf(scope)
  local key = source or scope
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

  local mine: Holding = { value = nil }

  for _, target in targets do
    local list = holders[target]

    if list == nil then
      list = {}
      holders[target] = list
    end

    table.insert(list, mine)
  end

  -- taken off on end, on a clear and at deinit, so nothing stays slowed
  lifetime.hold(scope, function()
    for _, target in targets do
      local list = holders[target]
      local index = if list then table.find(list, mine) else nil

      if list == nil or index == nil then
        continue
      end

      table.remove(list, index)

      if #list == 0 then
        holders[target] = nil
        clock.unscale(target, key)

        continue
      end

      local newest = list[#list]

      if newest.value ~= nil then
        clock.scale(target, key, newest.value)
      end
    end
  end)

  -- a nan or an infinity would pass math.max and stall every clock below the
  -- target for good
  attrs.TimeScale:apply(function(v: any)
    if typeof(v) ~= "number" or not numeric_common.finite(v) then
      return
    end

    mine.value = math.max(v, 0)

    for _, target in targets do
      local list = holders[target]

      if list ~= nil and list[#list] == mine then
        clock.scale(target, key, mine.value)
      end
    end
  end)

  lifetime.wait(scope, attrs.EmitDuration)
end

return play
