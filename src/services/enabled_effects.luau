local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local attr = require("@mod/attributes")
local clock = require("@mod/clock")
local utility = require("@mod/utility")
local emitters = require("@root/emitters")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")

local enabled_effects = {}

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

        -- never sealed: it lives as long as the instance stays enabled, and
        -- finished ticks take themselves out of it. it hangs from the global
        -- clock, so the ticks keep to the global speed and stop while paused
        local cancelToken = lifetime.emit(nil)

        utility.setEnabledCancelToken(obj, cancelToken)

        -- the time since the last tick on the token's clock, as an
        -- EmitDuration's ramp has it run. the first frame ticks at once
        local waited = math.huge

        table.insert(
          tempScope,
          RunService.RenderStepped:Connect(function(deltaTime: number)
            local rate = attr.get(obj, "Rate", 5)
            local speed = attr.getState(obj, "SpeedOverride", 1)

            if speed == 0 then
              return
            end

            waited += deltaTime * clock.factorOf(cancelToken.clock) * speed

            if waited <= 1 / rate then
              return
            end

            waited = 0

            local emitScope = lifetime.effect(cancelToken, 0, effects_service)

            lifetime.run(emitScope, function(scope)
              emitters.dispatch(obj, scope, { unc = {}, ref = {} }, 1, module, true)
            end)
          end)
        )
      else
        utility.cleanupScope(tempScope)
        utility.setEnabledCancelToken(obj, nil)
      end
    end

    table.insert(effectScope, attr.hook(obj, "Enabled", onEnabled))

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
