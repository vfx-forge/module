local clock = require("@mod/clock")
local types = require("@root/types")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local registry = require("@mod/registry")
local emitters = require("@root/emitters")
local lifetime = require("@mod/lifetime")

local Promise = require("@pkg/Promise")

local effects = {}

local api_ref: types.Api?

local NOOP = function() end

-- the id of the module whose rows scale the effects around it
local CONTROLLER = "controller"

-- the key an env keeps its emit under, out of the way of its public fields
local EMIT = table.freeze({})

local EMPTY_ENV: types.EmitEnv = {
  Finished = Promise.resolve(),
  Clear = NOOP,
  SetSpeed = NOOP,
  GetSpeed = function()
    return 1
  end,
  Pause = NOOP,
  Resume = NOOP,
  IsPaused = function()
    return false
  end,
}

-- every emit handed out, weak so one that ended and is let go costs nothing to
-- keep, and cleared at deinit so its Finished settles instead of hanging. an
-- enabled (ConstantVFX) tick's token is not handed out here, so it is not in
-- LIVE and deinit does not clear it
local LIVE = setmetatable({} :: { [lifetime.emit]: boolean }, { __mode = "k" })

-- the clocks a controller scales, around its parent instance: the one the
-- effect on that instance hangs from, the one every effect below it hangs
-- from, and the one both hang from, which the controller itself runs on
export type Region = {
  here: clock.Clock,
  below: clock.Clock,
  above: clock.Clock,

  -- below hangs from here, as a nested emit's clock hangs from the effect
  -- that started it, so scaling here scales below as well
  nested: boolean,
}

-- each controller's region, keyed by the controller's effect until it takes it
local REGIONS = setmetatable({} :: { [lifetime.effect]: Region }, { __mode = "k" })

function effects.init(api: types.Api)
  api_ref = api
end

function effects.deinit()
  api_ref = nil

  for emit in table.clone(LIVE) do
    if not emit.done then
      lifetime.clear(emit)
    end
  end

  table.clear(LIVE)

  -- a Global controller under an emit that is not live, a ConstantVFX tick's,
  -- is never cleared here and would leave the global clock scaled
  clock.unscaleAll(clock.global)

  -- no frame may follow to announce what was taken off
  clock.announce()
end

-- built the first time somebody reads it, since most emits are fire and forget
-- and a promise costs about 5 KB. it resolves once the emit is done by any
-- means, a clear included, so a Promise.all over it always settles
local function finishedOf(emit: lifetime.emit)
  if emit.done then
    return Promise.resolve()
  end

  return Promise.new(function(resolve)
    lifetime.await(emit)
    resolve()
  end)
end

-- what every env answers besides Clear and Finished, shared by all of them
local METHODS = {}

function METHODS.SetSpeed(env: any, speed: number)
  clock.setSpeed(rawget(env, EMIT).clock, clock.checked(speed, "SetSpeed"))
end

function METHODS.GetSpeed(env: any)
  return rawget(env, EMIT).clock.speed
end

function METHODS.Pause(env: any)
  clock.setPaused(rawget(env, EMIT).clock, true)
end

function METHODS.Resume(env: any)
  clock.setPaused(rawget(env, EMIT).clock, false)
end

function METHODS.IsPaused(env: any)
  return rawget(env, EMIT).clock.paused
end

local ENV = {
  __index = function(env: any, key: any)
    local method = METHODS[key]

    if method ~= nil then
      return method
    end

    if key ~= "Finished" then
      return nil
    end

    local promise = finishedOf(rawget(env, EMIT))
    rawset(env, "Finished", promise)

    return promise
  end,
}

local function envOf(emit: lifetime.emit): types.EmitEnv
  local env = {
    [EMIT] = emit,

    -- a closure rather than a method, so `env.Clear()` with no self keeps
    -- working as it always has
    Clear = function()
      lifetime.clear(emit)
    end,
  }

  return setmetatable(env, ENV) :: any
end

-- every root's scan is taken before anything runs, so the clocks a controller
-- scales stand before the first effect under it starts. `host` is the effect
-- a nested emit was started by, and the instance its children sit under is
-- that effect's own
local function emitInto(emit: lifetime.emit, depth: number, host: lifetime.effect?, ...: Instance)
  local shared: reader.Shared = { unc = {}, ref = {} }

  local legacyScale = 1

  local list = { ... }
  local modules: { registry.Module? } = table.create(#list)
  local scans: { { registry.Hit } } = table.create(#list)

  -- the instances a controller sits under, when any does. compared with ==
  -- rather than looked up as keys, since a host hands back an equal instance
  -- for a parent, not always the same value
  local parents: { Instance }? = nil

  local function parentOf(inst: Instance?): Instance?
    local around = parents

    if around == nil or inst == nil then
      return nil
    end

    for _, parent in around do
      if parent == inst then
        return parent
      end
    end

    return nil
  end

  local function note(obj: Instance, effect: registry.Module?)
    if effect == nil or effect.id ~= CONTROLLER then
      return
    end

    local parent = obj.Parent

    if parent == nil or parentOf(parent) ~= nil then
      return
    end

    local around = parents or {}
    table.insert(around, parent)
    parents = around
  end

  for i, obj in list do
    local module = registry.of(obj)

    modules[i] = module
    scans[i] = registry.scan(obj, module)

    note(obj, module)

    for _, hit in scans[i] do
      note(hit.instance, hit.effect)
    end
  end

  local regions: { [Instance]: Region } = {}

  -- the instance a nested emit's children sit under hosts the effect that
  -- started it: that effect's clock is its own, and the emit's is below it
  if host ~= nil then
    local anchor = parentOf(list[1].Parent)

    if anchor ~= nil then
      regions[anchor] = {
        here = host.clock,
        below = emit.clock,
        above = host.clock.parent or emit.clock,
        nested = true,
      }
    end
  end

  -- the nearest controller's parent above an instance, the instance itself
  -- left out
  local function aboveOf(inst: Instance): Instance?
    local current = inst.Parent

    while current ~= nil do
      local parent = parentOf(current)

      if parent ~= nil then
        return parent
      end

      current = current.Parent
    end

    return nil
  end

  local function regionAt(parent: Instance): Region
    local region = regions[parent]

    if region ~= nil then
      return region
    end

    local outer = aboveOf(parent)
    local above = if outer ~= nil then regionAt(outer).below else emit.clock

    region = { here = clock.new(above), below = clock.new(above), above = above, nested = false }

    regions[parent] = region

    return region
  end

  -- the clock an effect on this instance hangs from: the emit's own unless a
  -- controller's region reaches it. a controller runs above its own region
  local function clockFor(obj: Instance, effect: registry.Module?): clock.Clock?
    if parents == nil then
      return nil
    end

    if effect ~= nil and effect.id == CONTROLLER then
      local parent = parentOf(obj.Parent)

      return if parent ~= nil then regionAt(parent).above else nil
    end

    local hosted = parentOf(obj)

    if hosted ~= nil then
      return regionAt(hosted).here
    end

    local outer = aboveOf(obj)

    return if outer ~= nil then regionAt(outer).below else nil
  end

  local function dispatchInto(target: lifetime.emit, obj: Instance, effectDepth: number, effect: registry.Module?)
    local fx = lifetime.effect(target, effectDepth, effects, clockFor(obj, effect))

    if effect ~= nil and effect.id == CONTROLLER then
      local parent = parentOf(obj.Parent)

      if parent ~= nil then
        REGIONS[fx] = regionAt(parent)
      end
    end

    lifetime.run(fx, function(scope)
      emitters.dispatch(obj, scope, shared, legacyScale, effect)
    end)
  end

  local function emitDescendants(target: lifetime.emit, obj: Instance, baseDepth: number, found: { registry.Hit })
    if #found == 0 then
      return
    end

    local skipCache: { [Instance]: boolean } = {}
    local depthCache: { [Instance]: number } = {}

    skipCache[obj] = false
    depthCache[obj] = baseDepth

    -- a hit's depth is how many ancestors lie between it and the root, and a
    -- hit under an ancestor excluded from emitting is left alone. the walk
    -- caches every ancestor it passes, so a tree of many hits walks each
    -- branch once. a hit with no effect is a legacy tween child, which the
    -- dispatcher drives without a module
    local function visit(desc: Instance, effect: registry.Module?)
      local ancestors = {}
      local current = desc.Parent

      while depthCache[current] == nil do
        table.insert(ancestors, current)
        current = current.Parent
      end

      local shouldSkip = skipCache[current]
      local currentDepth = depthCache[current]

      for i = #ancestors, 1, -1 do
        local ancestor = ancestors[i]

        currentDepth += 1
        depthCache[ancestor] = currentDepth

        if not shouldSkip then
          shouldSkip = ancestor:HasTag(utility.EMIT_EXCLUDE_TAG)
        end

        skipCache[ancestor] = shouldSkip
      end

      if not shouldSkip then
        dispatchInto(target, desc, depthCache[desc.Parent], effect)
      end
    end

    for _, hit in found do
      visit(hit.instance, hit.effect)
    end
  end

  for i, obj in list do
    dispatchInto(emit, obj, depth, modules[i])
    emitDescendants(emit, obj, depth + 1, scans[i])
  end
end

-- the region a controller scales, handed to it once
function effects.regionOf(fx: lifetime.effect): Region?
  local region = REGIONS[fx]
  REGIONS[fx] = nil

  return region
end

function effects.emit(depth: number, ...: Instance): types.EmitEnv
  if not api_ref or not api_ref.setup then
    logger.error("effects service not initialized")
    return EMPTY_ENV
  end

  local emit = lifetime.emit(nil)

  emitInto(emit, depth, nil, ...)
  lifetime.seal(emit)

  if not emit.done then
    LIVE[emit] = true
  end

  return envOf(emit)
end

function effects.prepareEmitFolder(obj: Instance, folderName: string, scope: types.scope): Folder?
  local folder = obj:FindFirstChild(folderName)

  if folder and folder:IsA("Folder") then
    folder.Parent = nil
    lifetime.hold(scope, folder)
    return folder
  end

  return nil
end

function effects.prepareEmitOnFinish(obj: Instance, scope: types.scope): Folder?
  return effects.prepareEmitFolder(obj, "EmitOnFinish", scope)
end

-- a child emit is counted into the join it is given until it is done, so the
-- effect that started it can keep its parts until the children under them end
local function emitChildren(children: { Instance }, depth: number, parentScope: types.scope?, join: lifetime.join?)
  if not api_ref or not api_ref.setup then
    return
  end

  if #children == 0 then
    return
  end

  -- a nested emit runs on the clock of the effect that started it
  local emit = if parentScope then lifetime.emit(parentScope.emit, parentScope.clock) else lifetime.emit(nil)

  emitInto(emit, depth, parentScope, table.unpack(children))
  lifetime.seal(emit)

  if join then
    lifetime.include(join, emit)
  end
end

function effects.emitNested(part: Instance, depth: number, parentScope: types.scope?, join: lifetime.join?)
  emitChildren(part:GetChildren(), depth, parentScope, join)
end

function effects.emitFromFolder(
  folder: Folder?,
  targetParent: Instance,
  depth: number,
  parentScope: types.scope?,
  join: lifetime.join?
)
  if not folder then
    return
  end

  local children = folder:GetChildren()

  for _, child in children do
    child.Parent = targetParent
  end

  emitChildren(children, depth, parentScope, join)
end

function effects.emitOnFinish(
  emitOnFinish: Folder?,
  targetParent: Instance,
  depth: number,
  parentScope: types.scope?,
  join: lifetime.join?
)
  effects.emitFromFolder(emitOnFinish, targetParent, depth, parentScope, join)
end

return effects
