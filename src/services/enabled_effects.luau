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

local enabled_effects = {}

-- every instance whose passive loop runs, to what the loop holds, to the
-- module it ticks, to what starts its ticks once it sits where it may run, and
-- to the signals that follow it in and out of there and see it destroyed
local Loops: { [Instance]: { any } } = {}
local Ticks: { [Instance]: registry.Module } = {}
local Wakes: { [Instance]: () -> () } = {}
local Moves: { [Instance]: { any } } = {}

-- every token a loop started whose ticks may still be playing. a loop that
-- stops lets its ticks play out, so its token is kept until they have, and a
-- teardown clears what is left: nothing else would end a tick once its host's
-- threads are gone, and its bolts or parts would stay in the place for good
local Tokens: { [lifetime.emit]: true } = {}

local service: any = nil

-- the emit every tick of a passive loop is an effect of, never sealed: it lives
-- as long as the instance stays enabled, and finished ticks take themselves out
-- of it. its ticks hang from the global clock and rank under a one-shot emit's
-- at the same priority
function enabled_effects.token(): lifetime.emit
  local token = lifetime.emit(nil)

  token.constant = true

  return token
end

-- what an enabled instance runs every frame: a tick each `1 / Rate` seconds of
-- the token's clock, the first at once, and none while that clock stands still
function enabled_effects.ticker(obj: Instance, module: registry.Module, token: lifetime.emit, effectsService: any)
  local waited = math.huge

  return function(deltaTime: number)
    local rate = attr.get(obj, "Rate", 5)
    local factor = clock.factorOf(token.clock)

    if factor <= 0 then
      return
    end

    waited += deltaTime * factor

    if waited <= 1 / rate then
      return
    end

    waited = 0

    local emitScope = lifetime.effect(token, 0, effectsService)

    lifetime.run(emitScope, function(scope)
      emitters.dispatch(obj, scope, { unc = {}, ref = {}, held = {} }, module, true)
    end)
  end
end

-- an EmitDuration emit's window: an emit of its own under the effect's, so the
-- handle's speed, pause, priority and clear reach it and its ticks, ticking
-- every `1 / Rate` seconds of its clock for `duration` seconds of the
-- effect's, then waited on until its last tick has ended. its Speed row is
-- its clock's, which its ticks hang from, never a tick's own
function enabled_effects.window(ctx: reader.Ctx, module: registry.Module, duration: number, speed: reader.Track)
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

  lifetime.speed(scope, speed, window.clock)

  local tick = enabled_effects.ticker(ctx.ref, module, window, scope.effects)
  local handle: scheduler.Handle
  local spawning = true

  -- on real time, since the ticker counts the window's clock itself, and at
  -- depth 0, ahead of the compute steps its ticks add and after the Speed
  -- ramp. the halt watch outlives the spawning, since the ramp keeps stepping
  -- while the last ticks play out. a wait of a tick sees the halt on the next
  -- frame, a timer in this one
  handle = scheduler.add("compute", function(deltaTime: number)
    if not window.clock.halted then
      if spawning then
        tick(deltaTime)
      end

      return
    end

    handle:Disconnect()

    -- the Speed came to rest at 0: what is still playing ends the way a
    -- halted effect's timers end, its nested emits still running out
    for _, fx in window.effects do
      fx.clock.halted = true
    end
  end, 0, scope, false, clock.REAL)

  lifetime.hold(scope, handle)

  -- the first tick as the window opens, so one shorter than a frame still
  -- spawns it
  tick(0)

  lifetime.wait(scope, duration)

  spawning = false
  lifetime.seal(window)
  lifetime.await(window)
  handle:Disconnect()
end

-- whether the instance sits where its passive loop may run, and the signals that
-- tell it moved and that it is gone for good. a spec stands its own in, since
-- lune has neither
function enabled_effects.placed(obj: Instance)
  return obj:IsDescendantOf(workspace) or (obj.Parent ~= nil and obj.Parent:HasTag("AllowEmitting"))
end

function enabled_effects.moved(obj: Instance, callback: () -> (), destroyed: () -> ())
  return { obj.AncestryChanged:Connect(callback), obj.Destroying:Connect(destroyed) } :: { any }
end

-- the loop taken off an instance that left where it may run; the signal that
-- brings it back stays
local function stop(obj: Instance)
  local loop = Loops[obj]

  if loop then
    utility.cleanupScope(loop)
  end

  Loops[obj] = nil
  Ticks[obj] = nil
  Wakes[obj] = nil
end

-- the instance's passive loop, started once: it ticks while Enabled is true and
-- the instance sits where it may run, the tag listener's path and api.enable's
function enabled_effects.add(obj: Instance)
  if Loops[obj] ~= nil or service == nil then
    return
  end

  local module = registry.of(obj)

  if module == nil or not module.constant then
    return
  end

  local tempScope = {} :: { any }
  local loop = { tempScope } :: { any }

  Loops[obj] = loop
  Ticks[obj] = module

  if Moves[obj] == nil then
    Moves[obj] = enabled_effects.moved(obj, function()
      if not enabled_effects.placed(obj) then
        stop(obj)
        return
      end

      local wake = Wakes[obj]

      if wake then
        wake()
      else
        enabled_effects.add(obj)
      end
    end, function()
      enabled_effects.remove(obj)
    end)
  end

  local function onEnabled(enabled: boolean?)
    if enabled == nil then
      enabled = attr.get(obj, "Enabled", true)
    end

    -- already ticking, or nowhere it may tick yet
    if enabled and (next(tempScope) ~= nil or not enabled_effects.placed(obj)) then
      return
    end

    utility.cleanupScope(tempScope)

    if not enabled then
      return
    end

    for token in Tokens do
      if #token.effects == 0 and #token.children == 0 then
        Tokens[token] = nil
      end
    end

    local token = enabled_effects.token()

    Tokens[token] = true

    local tick = enabled_effects.ticker(obj, module, token, service)

    table.insert(tempScope, RunService.RenderStepped:Connect(tick))
  end

  Wakes[obj] = onEnabled

  table.insert(loop, attr.observe(obj, "Enabled", onEnabled))

  onEnabled()
end

-- the instance's passive loop gone for good, and the signal that would bring it
-- back with it
function enabled_effects.remove(obj: Instance)
  stop(obj)

  local moves = Moves[obj]

  if moves then
    utility.cleanupScope(moves)
    Moves[obj] = nil
  end
end

-- the module a loop on the instance should tick now, or nil
local function wanted(obj: Instance): registry.Module?
  local module = registry.of(obj)

  return if module ~= nil and module.constant then module else nil
end

-- every loop restarted whose instance now classifies as another module, and
-- every tagged instance with none started, after the registry changed under
-- them, as a custom effect's load, reload or removal does
function enabled_effects.resync()
  if service == nil then
    return
  end

  local stale = {}

  for obj, module in Ticks do
    if wanted(obj) ~= module then
      table.insert(stale, obj)
    end
  end

  for _, obj in CollectionService:GetTagged(utility.ENABLED_VFX_TAG) do
    if Loops[obj] == nil and wanted(obj) ~= nil then
      table.insert(stale, obj)
    end
  end

  for _, obj in stale do
    enabled_effects.remove(obj)
    enabled_effects.add(obj)
  end
end

-- a lightning, bezier or mesh instance's passive loop starts and stops with the
-- switch, tagged or not, and in Studio's edit mode the tag follows it so the
-- place saves as it was left. switched off in a running game, a tagged instance
-- keeps its tag and its loop record, so Enabled set back on resumes it; an
-- untagged one has its record removed
function enabled_effects.switch(obj: Instance, enabled: boolean)
  attr.set(obj, "Enabled", enabled)

  -- a cached instance's listeners hear nothing from the write itself
  if attr.isCached(obj) then
    attr.trigger(obj, "Enabled", enabled)
  end

  local module = registry.of(obj)

  if module == nil or not module.constant then
    return
  end

  if not enabled then
    if not RunService:IsRunning() then
      obj:RemoveTag(utility.ENABLED_VFX_TAG)
      enabled_effects.remove(obj)
    elseif not obj:HasTag(utility.ENABLED_VFX_TAG) then
      enabled_effects.remove(obj)
    end

    return
  end

  if not RunService:IsRunning() then
    obj:AddTag(utility.ENABLED_VFX_TAG)
  end

  enabled_effects.add(obj)
end

-- every tick still playing ended, as a cleared emit is: what it holds is let
-- go and its pieces go back while the pool still stands
function enabled_effects.clear()
  for token in table.clone(Tokens) do
    lifetime.clear(token)
  end

  table.clear(Tokens)
end

function enabled_effects.init(scope: { any }, effects_service: any)
  service = effects_service

  for _, obj in CollectionService:GetTagged(utility.ENABLED_VFX_TAG) do
    enabled_effects.add(obj)
  end

  table.insert(scope, CollectionService:GetInstanceAddedSignal(utility.ENABLED_VFX_TAG):Connect(enabled_effects.add))
  table.insert(
    scope,
    CollectionService:GetInstanceRemovedSignal(utility.ENABLED_VFX_TAG):Connect(enabled_effects.remove)
  )

  table.insert(scope, function()
    for obj in Loops do
      enabled_effects.remove(obj)
    end

    for obj in Moves do
      enabled_effects.remove(obj)
    end

    service = nil
  end)
end

return enabled_effects
