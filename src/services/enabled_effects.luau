local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local attr = require("@mod/attributes")
local clock = require("@mod/clock")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local emitters = require("@root/emitters")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")

local numeric_common = require("@mod/common/numeric")

local enabled_effects = {}

-- the emit every tick of an enabled instance is an effect of, never sealed: it
-- lives as long as the instance stays enabled, and finished ticks take
-- themselves out of it. an EmitDuration emit's ticks hang from the clock of the
-- effect that forced them, so its handle and controllers reach them; a plain
-- enabled instance's hang from the global clock. a plain enabled instance's
-- ticks rank under a one-shot emit's at the same priority, and a forced
-- EmitDuration's do not
function enabled_effects.token(obj: Instance): lifetime.emit
  local token = lifetime.emit(nil, utility.forcedClock(obj))

  token.constant = not utility.isForceEmitting(obj)

  return token
end

-- what an enabled instance runs every frame: a tick each `1 / Rate` seconds of
-- the token's clock, the first at once, and none while that clock stands still
function enabled_effects.ticker(obj: Instance, module: registry.Module, token: lifetime.emit, effectsService: any)
  local waited = math.huge

  return function(deltaTime: number)
    local rate = attr.get(obj, "Rate", 5)
    local speed = attr.getState(obj, "SpeedOverride", 1)

    if typeof(speed) ~= "number" or not numeric_common.finite(speed) or speed <= 0 then
      return
    end

    local factor = clock.factorOf(token.clock)

    if factor <= 0 then
      return
    end

    waited += deltaTime * factor * speed

    if waited <= 1 / rate then
      return
    end

    waited = 0

    local emitScope = lifetime.effect(token, 0, effectsService)

    lifetime.run(emitScope, function(scope)
      emitters.dispatch(obj, scope, { unc = {}, ref = {} }, 1, module, true)
    end)
  end
end

-- an EmitDuration emit's window: an emit of its own under the effect's, so the
-- handle's speed, pause, priority and clear reach it and its ticks, ticking
-- every `1 / Rate` seconds of its clock for `duration` seconds of the
-- effect's, then waited on until its last tick has ended
function enabled_effects.window(ctx: reader.Ctx, module: registry.Module, duration: number)
  local scope = ctx.scope
  local window = lifetime.emit(scope.emit, scope.clock)

  -- a window's ticks rank as a one-shot emit's, wherever the emit that
  -- opened it came from
  window.constant = false

  -- a clear of the emit reaches the window through the tree; a kill of this
  -- effect alone does not, so it takes the window's ticks with it
  lifetime.defer(scope, function(cancelled: boolean)
    if cancelled then
      lifetime.clear(window)
    end

    lifetime.seal(window)
  end)

  local tick = enabled_effects.ticker(ctx.ref, module, window, scope.effects)

  -- on real time, since the ticker counts the window's clock itself, and at
  -- depth 0, ahead of every step its ticks add
  local handle = lifetime.hold(scope, scheduler.add("compute", tick, 0, scope, false, clock.REAL))

  -- the first tick as the window opens, so one shorter than a frame still
  -- spawns it
  tick(0)

  lifetime.wait(scope, duration)

  handle:Disconnect()
  lifetime.seal(window)
  lifetime.await(window)
end

function enabled_effects.init(scope: { any }, effects_service: any)
  local enabledScopes = {}
  local ancestryConnections: { [Instance]: RBXScriptConnection } = {}

  local function removeEnabledEffect(obj: Instance)
    local effectScope = enabledScopes[obj]

    if effectScope then
      utility.cleanupScope(effectScope)
    end

    utility.setEnabledCancelToken(obj, nil)
    enabledScopes[obj] = nil
  end

  local function removeEnabledEffectFull(obj: Instance)
    removeEnabledEffect(obj)

    local conn = ancestryConnections[obj]

    if conn then
      conn:Disconnect()
      ancestryConnections[obj] = nil
    end
  end

  local function addEnabledEffect(obj: Instance)
    local module = registry.of(obj)

    if module == nil or not module.constant then
      return
    end

    local tempScope = {} :: { any }
    local effectScope = {} :: { any }

    table.insert(effectScope, tempScope)

    enabledScopes[obj] = effectScope

    if not ancestryConnections[obj] then
      ancestryConnections[obj] = obj.AncestryChanged:Connect(function()
        if obj:IsDescendantOf(workspace) or (obj.Parent and obj.Parent:HasTag("AllowEmitting")) then
          if not enabledScopes[obj] then
            addEnabledEffect(obj)
          end
        else
          removeEnabledEffect(obj)
        end
      end)
    end

    local function onEnabled(enabled: boolean?)
      if enabled == nil then
        enabled = attr.get(obj, "Enabled", true)
      end

      local canEmit = utility.isForceEmitting(obj)
        or obj:IsDescendantOf(workspace)
        or (obj.Parent and obj.Parent:HasTag("AllowEmitting"))

      if enabled and not canEmit then
        return
      end

      if enabled then
        utility.cleanupScope(tempScope)

        local cancelToken = enabled_effects.token(obj)

        utility.setEnabledCancelToken(obj, cancelToken)

        table.insert(
          tempScope,
          RunService.RenderStepped:Connect(enabled_effects.ticker(obj, module, cancelToken, effects_service))
        )
      else
        utility.cleanupScope(tempScope)
        utility.setEnabledCancelToken(obj, nil)
      end
    end

    table.insert(effectScope, attr.observe(obj, "Enabled", onEnabled))

    onEnabled()
  end

  for _, obj in CollectionService:GetTagged(utility.ENABLED_VFX_TAG) do
    addEnabledEffect(obj)
  end

  CollectionService:GetInstanceAddedSignal(utility.ENABLED_VFX_TAG):Connect(addEnabledEffect)
  CollectionService:GetInstanceRemovedSignal(utility.ENABLED_VFX_TAG):Connect(removeEnabledEffectFull)

  table.insert(scope, function()
    for obj, effectScope in enabledScopes do
      utility.cleanupScope(effectScope)
    end

    for obj, conn in ancestryConnections do
      conn:Disconnect()
    end

    table.clear(ancestryConnections)
  end)
end

return enabled_effects
