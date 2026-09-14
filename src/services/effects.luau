local types = require("@root/types")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local registry = require("@mod/registry")
local emitters = require("@root/emitters")
local lifetime = require("@mod/lifetime")

local Promise = require("@pkg/Promise")

local EffectSelectors = table.concat({
  -- Mesh effects, until their module exists; a spin model is the registry's first
  "Model",

  -- Legacy tween children, until the union goes
  "RayValue",

  -- anything carrying a modifier queue, which is how the applier reaches a
  -- target that is not otherwise an effect. overlaps every clause above on
  -- purpose; queryAndEmitDescendants dedupes
  `.{utility.MODIFIERS_TAG}`,
}, ",")

local effects = {}

-- exposed so the selector spec can query against the real string instead of
-- keeping a copy that drifts
effects.SELECTORS = EffectSelectors

local api_ref: types.Api?

local NOOP = function() end

local EMPTY_ENV: types.EmitEnv = {
  Finished = Promise.resolve(),
  Clear = NOOP,
}

function effects.init(api: types.Api)
  api_ref = api
end

function effects.deinit()
  api_ref = nil
end

-- built the first time somebody reads it: most emits are fire and forget, and
-- a promise costs about 5 KB each
local function finishedOf(emit: lifetime.emit)
  if emit.finished then
    return emit.finished
  end

  local promise

  if emit.cleared then
    promise = Promise.new(function() end)
    promise:cancel()
  elseif emit.done then
    promise = Promise.resolve()
  else
    promise = Promise.new(function(resolve)
      lifetime.await(emit)
      resolve()
    end)
  end

  emit.finished = promise

  return promise
end

local function envOf(emit: lifetime.emit): types.EmitEnv
  local env = {}

  env.Clear = function()
    utility.cancelToken(emit)
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
  local api = api_ref :: types.Api

  local shared: reader.Shared = { unc = {}, ref = {} }

  local legacyScale = 1

  local list = { ... }

  local function dispatchInto(target: lifetime.emit, obj: Instance, effectDepth: number, effect: registry.Module?)
    local fx = lifetime.effect(target, effectDepth, effects)

    lifetime.run(fx, function(scope)
      emitters.dispatch(obj, scope, shared, api.caches.shared_part, legacyScale, effect)
    end)
  end

  local function queryAndEmitDescendants(
    target: lifetime.emit,
    obj: Instance,
    baseDepth: number,
    claimant: registry.Module?
  )
    -- the registry's matches first, each with its module, then the union
    -- selector for everything still routed by class and tag. an instance the
    -- registry matched is never dispatched again by the union
    local found = registry.scan(obj, claimant)
    local allDesc = obj:QueryDescendants(EffectSelectors)

    if #found == 0 and #allDesc == 0 then
      return
    end

    local skipCache: { [Instance]: boolean } = {}
    local depthCache: { [Instance]: number } = {}

    -- QueryDescendants returns one entry per MATCHING CLAUSE, not per instance,
    -- and the clauses overlap: a bezier-tagged part that is also Enabled matches
    -- both its tag and BasePart[$Enabled=true], and a shockwave ring part
    -- matches both its group and that same clause. Without this the instance is
    -- dispatched once per clause, which emits it twice and, since the applier
    -- runs in dispatch's prologue, puts two drivers on every modifier target
    local emitted: { [Instance]: boolean } = {}

    skipCache[obj] = false
    depthCache[obj] = baseDepth

    local function visit(desc: Instance, effect: registry.Module?)
      if emitted[desc] then
        return
      end

      emitted[desc] = true

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
          shouldSkip = utility.shouldSkipNested(ancestor) or ancestor:HasTag(utility.EMIT_EXCLUDE_TAG)
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

    for _, desc in allDesc do
      visit(desc, nil)
    end
  end

  for _, obj in list do
    local module = registry.of(obj)

    dispatchInto(emit, obj, depth, module)

    -- a module that claims its whole subtree runs the effects under it itself
    if not (module and module.components == "Instance") and not utility.shouldSkipNested(obj) then
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

local function emitChildren(children: { Instance }, depth: number, parentScope: types.scope?): types.EmitEnv
  if not api_ref or not api_ref.setup then
    return EMPTY_ENV
  end

  if #children == 0 then
    return EMPTY_ENV
  end

  local emit = lifetime.emit(if parentScope then parentScope.emit else nil)

  emitInto(emit, depth, table.unpack(children))
  lifetime.seal(emit)

  return envOf(emit)
end

function effects.emitNested(part: Instance, depth: number, parentScope: types.scope?): types.EmitEnv
  return emitChildren(part:GetChildren(), depth, parentScope)
end

function effects.emitFromFolder(
  folder: Folder?,
  targetParent: Instance,
  depth: number,
  parentScope: types.scope?
): types.EmitEnv
  if not folder then
    return EMPTY_ENV
  end

  local children = folder:GetChildren()

  for _, child in children do
    child.Parent = targetParent
  end

  return emitChildren(children, depth, parentScope)
end

function effects.emitOnFinish(
  emitOnFinish: Folder?,
  targetParent: Instance,
  depth: number,
  parentScope: types.scope?
): types.EmitEnv
  return effects.emitFromFolder(emitOnFinish, targetParent, depth, parentScope)
end

return effects
