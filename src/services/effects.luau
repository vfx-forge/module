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

local EMPTY_ENV: types.EmitEnv = {
  Finished = Promise.resolve(),
  Clear = NOOP,
}

-- every emit handed out, weak so one that ended and is let go costs nothing to
-- keep, and cleared at deinit so its Finished settles instead of hanging. an
-- enabled (ConstantVFX) tick's token is not handed out here, so it is not in
-- LIVE and deinit does not clear it
local LIVE = setmetatable({} :: { [lifetime.emit]: boolean }, { __mode = "k" })

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

local function envOf(emit: lifetime.emit): types.EmitEnv
  local env = {}

  env.Clear = function()
    lifetime.clear(emit)
  end

  setmetatable(env, {
    __index = function(_, key)
      if key ~= "Finished" then
        return nil
      end

      local promise = finishedOf(emit)
      rawset(env, "Finished", promise)

      return promise
    end,
  })

  return env :: any
end

local function emitInto(emit: lifetime.emit, depth: number, ...: Instance)
  local shared: reader.Shared = { unc = {}, ref = {} }

  local legacyScale = 1

  local list = { ... }

  local function dispatchInto(target: lifetime.emit, obj: Instance, effectDepth: number, effect: registry.Module?)
    local fx = lifetime.effect(target, effectDepth, effects)

    lifetime.run(fx, function(scope)
      emitters.dispatch(obj, scope, shared, legacyScale, effect)
    end)
  end

  local function queryAndEmitDescendants(
    target: lifetime.emit,
    obj: Instance,
    baseDepth: number,
    claimant: registry.Module?
  )
    local found = registry.scan(obj, claimant)

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

  for _, obj in list do
    local module = registry.of(obj)

    dispatchInto(emit, obj, depth, module)

    -- a module that claims its whole subtree runs the effects under it itself
    if not (module and module.components == "Instance") then
      queryAndEmitDescendants(emit, obj, depth + 1, module)
    end
  end
end

function effects.emit(depth: number, ...: Instance): types.EmitEnv
  if not api_ref or not api_ref.setup then
    logger.error("effects service not initialized")
    return EMPTY_ENV
  end

  local emit = lifetime.emit(nil)

  emitInto(emit, depth, ...)
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

  emitInto(emit, depth, table.unpack(children))
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
