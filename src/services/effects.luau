local clock = require("@mod/clock")
local types = require("@root/types")
local logger = require("@mod/logger")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local registry = require("@mod/registry")
local emitters = require("@root/emitters")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")

local numeric_common = require("@mod/common/numeric")

local Promise = require("@pkg/Promise")

local effects = {}

local api_ref: types.Api?

local NOOP = function() end

-- the id of the module whose rows scale the effects around it
local CONTROLLER = "controller"

-- the key an env keeps its emit under, out of the way of its public fields
local EMIT = table.freeze({})

-- the scheduler's time when the env was made, and the effect time GetTime
-- counts once it is first asked, each under a key of its own
local BORN = table.freeze({})
local TIMER = table.freeze({})

-- the keys an emit's options table may hold
local OPTIONS = { priority = true }

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
  GetTime = function()
    return 0
  end,
  SetPriority = NOOP,
  GetPriority = function()
    return 0
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

  -- nor a speed or a pause the game left, so an init after this one never
  -- starts its emits slowed or frozen
  clock.setSpeed(clock.global, 1)
  clock.setPaused(clock.global, false)
  clock.setPaused(clock.wall, false)

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

-- the effect time since the emit: counted on the emit's clock from the first
-- call, and before it at the factor that clock has then, which is exact for an
-- emit whose speed and pauses did not change before it was first asked. it
-- stands still once the emit is done; first asked only after that, the clock
-- is gone and it answers the real seconds since the emit at the global speed
function METHODS.GetTime(env: any)
  local timer = rawget(env, TIMER)

  if timer ~= nil then
    return timer.time
  end

  local emit = rawget(env, EMIT)
  local since = scheduler.now - rawget(env, BORN)

  -- a first call from a step that runs earlier in this pass than the wait
  -- phase's depth 0 bucket counts this frame's delta twice
  timer = { time = since * clock.factorOf(emit.clock) }
  rawset(env, TIMER, timer)

  if emit.done then
    return timer.time
  end

  local step: scheduler.Handle

  step = scheduler.add("wait", function(deltaTime: number)
    if emit.done then
      step:Disconnect()
      return
    end

    timer.time += deltaTime
  end, 0, nil, nil, emit.clock)

  return timer.time
end

-- a running emit and every emit it started, ranked again at once. a bad value
-- would silently demote the emit, so it is refused and the priority kept
function METHODS.SetPriority(env: any, priority: number)
  if type(priority) ~= "number" or not numeric_common.finite(priority) then
    logger.warn(`SetPriority takes a finite number, not {priority}`)
    return
  end

  local emit = rawget(env, EMIT)

  if emit.done then
    return
  end

  lifetime.rank(emit, priority)
end

function METHODS.GetPriority(env: any)
  return rawget(env, EMIT).priority
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
    [BORN] = scheduler.now,

    -- a closure rather than a method, so `env.Clear()` with no self keeps
    -- working as it always has
    Clear = function()
      lifetime.clear(emit)
    end,
  }

  return setmetatable(env, ENV) :: any
end

-- the instances a controller sits under, grown by `obj` when it is one. compared
-- with == rather than looked up as keys, since a host hands back an equal
-- instance for a parent, not always the same value
local function parentOf(parents: { Instance }?, inst: Instance?): Instance?
  if parents == nil or inst == nil then
    return nil
  end

  for _, parent in parents do
    if parent == inst then
      return parent
    end
  end

  return nil
end

local function note(parents: { Instance }?, obj: Instance, effect: registry.Module?): { Instance }?
  if effect == nil or effect.id ~= CONTROLLER then
    return parents
  end

  local parent = obj.Parent

  if parent == nil or parentOf(parents, parent) ~= nil then
    return parents
  end

  local around = parents or {}
  table.insert(around, parent)

  return around
end

-- the scale keys of each host's nested controllers, by where each sits
local SOURCES = setmetatable({} :: { [lifetime.effect]: { [string]: {} } }, { __mode = "k" })

-- the key a controller under a nested emit scales with, shared by every
-- piece's copy of it: keyed by the host and by where the copy sits under its
-- piece (each step's name and place among its siblings, which every clone of
-- one template keeps), so a host of many pieces is scaled once per controller
-- of its template rather than once per piece. the top step's place is its
-- place in what was emitted, since the site may hold children of the run's
-- own, and an on-finish folder's children are moved in among them
local function sourceOf(host: lifetime.effect, from: string, site: Instance?, list: { Instance }, obj: Instance): {}
  local steps = { from }
  local current = obj

  while current ~= nil and current ~= site do
    local parent = current.Parent
    local siblings = if parent == site then list elseif parent ~= nil then parent:GetChildren() else nil
    local place = if siblings ~= nil then table.find(siblings, current) else 0

    table.insert(steps, `{current.Name}#{place}`)
    current = parent
  end

  local path = table.concat(steps, "/")
  local keys = SOURCES[host]

  if keys == nil then
    keys = {}
    SOURCES[host] = keys
  end

  local key = keys[path]

  if key == nil then
    key = {}
    keys[path] = key
  end

  return key
end

-- each nested controller's scale key, keyed by its effect until it takes it
local KEYS = setmetatable({} :: { [lifetime.effect]: {} }, { __mode = "k" })

-- where the effects of one emit hang when a controller is among them: built
-- only then, so an emit with none pays for none of it
type Placement = {
  clockFor: (obj: Instance, effect: registry.Module?) -> clock.Clock?,
  claim: (fx: lifetime.effect, obj: Instance) -> (),
}

local function placementOf(
  emit: lifetime.emit,
  host: lifetime.effect?,
  from: string,
  list: { Instance },
  parents: { Instance }
): Placement
  local regions: { [Instance]: Region } = {}
  local site = list[1].Parent

  -- the instance a nested emit's children sit under hosts the effect that
  -- started it: that effect's clock is its own, and the emit's is below it
  if host ~= nil then
    local anchor = parentOf(parents, site)

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
      local parent = parentOf(parents, current)

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
    if effect ~= nil and effect.id == CONTROLLER then
      local parent = parentOf(parents, obj.Parent)

      return if parent ~= nil then regionAt(parent).above else nil
    end

    local hosted = parentOf(parents, obj)

    if hosted ~= nil then
      return regionAt(hosted).here
    end

    local outer = aboveOf(obj)

    return if outer ~= nil then regionAt(outer).below else nil
  end

  local function claim(fx: lifetime.effect, obj: Instance)
    local parent = parentOf(parents, obj.Parent)

    if parent ~= nil then
      REGIONS[fx] = regionAt(parent)
    end

    if host ~= nil then
      KEYS[fx] = sourceOf(host, from, site, list, obj)
    end
  end

  return { clockFor = clockFor, claim = claim }
end

local function dispatchInto(
  target: lifetime.emit,
  obj: Instance,
  effectDepth: number,
  effect: registry.Module?,
  shared: reader.Shared,
  placement: Placement?
)
  local fx = lifetime.effect(target, effectDepth, effects, placement and placement.clockFor(obj, effect))

  if placement ~= nil and effect ~= nil and effect.id == CONTROLLER then
    placement.claim(fx, obj)
  end

  lifetime.run(fx, function(scope)
    emitters.dispatch(obj, scope, shared, effect)
  end)
end

-- a hit's depth is how many ancestors lie between it and the root, and a hit
-- under an ancestor excluded from emitting is left alone. the walk caches
-- every ancestor it passes, so a tree of many hits walks each branch once. a
-- hit with no effect is a legacy tween child, which the dispatcher drives
-- without a module
local function emitDescendants(
  target: lifetime.emit,
  obj: Instance,
  baseDepth: number,
  found: { registry.Hit },
  shared: reader.Shared,
  placement: Placement?
)
  if #found == 0 then
    return
  end

  local skipCache: { [Instance]: boolean } = {}
  local depthCache: { [Instance]: number } = {}

  skipCache[obj] = false
  depthCache[obj] = baseDepth

  for _, hit in found do
    local desc = hit.instance
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
      dispatchInto(target, desc, depthCache[desc.Parent], hit.effect, shared, placement)
    end
  end
end

-- every root's scan is taken before anything runs, so the clocks a controller
-- scales stand before the first effect under it starts. `host` is the effect
-- a nested emit was started by, and the instance its children sit under is
-- that effect's own; `from` tells a nested emit from an on-finish one
local function emitInto(emit: lifetime.emit, depth: number, host: lifetime.effect?, from: string, ...: Instance)
  local shared: reader.Shared = { unc = {}, ref = {}, held = {} }

  local list = { ... }
  local modules: { registry.Module? } = table.create(#list)
  local scans: { { registry.Hit } } = table.create(#list)

  local parents: { Instance }? = nil

  for i, obj in list do
    local module = registry.of(obj)
    local found = registry.scan(obj, module)

    modules[i] = module
    scans[i] = found

    parents = note(parents, obj, module)

    for _, hit in found do
      parents = note(parents, hit.instance, hit.effect)
    end
  end

  local placement = if parents ~= nil then placementOf(emit, host, from, list, parents) else nil

  for i, obj in list do
    dispatchInto(emit, obj, depth, modules[i], shared, placement)
    emitDescendants(emit, obj, depth + 1, scans[i], shared, placement)
  end
end

-- the region a controller scales and the key it scales with, handed to it
-- once. the key is nil for a controller no nested emit started, which scales
-- with its own effect
function effects.regionOf(fx: lifetime.effect): (Region?, {}?)
  local region = REGIONS[fx]
  local key = KEYS[fx]

  REGIONS[fx] = nil
  KEYS[fx] = nil

  return region, key
end

-- the priority an emit's options table asks for, every key it does not know
-- and every priority that is not a finite number warned about
local function priorityOf(options: { [any]: any }): number?
  for key in options do
    if OPTIONS[key] == nil then
      logger.warn(`emit has no option called {key}`)
    end
  end

  local priority = options.priority

  if priority == nil then
    return nil
  end

  if type(priority) ~= "number" or not numeric_common.finite(priority) then
    logger.warn(`emit's priority must be a finite number, not {priority}`)
    return nil
  end

  return priority
end

function effects.emit(depth: number, ...: any): types.EmitEnv
  if not api_ref or not api_ref.setup then
    logger.error("effects service not initialized")
    return EMPTY_ENV
  end

  local emit = lifetime.emit(nil)
  local count = select("#", ...)
  local last = if count > 0 then select(count, ...) else nil

  -- an options table ends the instances, told apart by being a table
  if type(last) == "table" then
    emit.priority = priorityOf(last) or 0
    emitInto(emit, depth, nil, "", table.unpack({ ... }, 1, count - 1))
  else
    emitInto(emit, depth, nil, "", ...)
  end

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
local function emitChildren(
  children: { Instance },
  depth: number,
  parentScope: types.scope?,
  join: lifetime.join?,
  from: string
)
  if not api_ref or not api_ref.setup then
    return
  end

  if #children == 0 then
    return
  end

  -- a nested emit runs on the clock of the effect that started it
  local emit = if parentScope then lifetime.emit(parentScope.emit, parentScope.clock) else lifetime.emit(nil)

  emitInto(emit, depth, parentScope, from, table.unpack(children))
  lifetime.seal(emit)

  if join then
    lifetime.include(join, emit)
  end
end

function effects.emitNested(part: Instance, depth: number, parentScope: types.scope?, join: lifetime.join?)
  emitChildren(part:GetChildren(), depth, parentScope, join, "")
end

-- one instance emitted under an effect, on its clock, counted into the join
function effects.emitInstance(inst: Instance, depth: number, parentScope: types.scope?, join: lifetime.join?)
  emitChildren({ inst }, depth, parentScope, join, "")
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

  emitChildren(children, depth, parentScope, join, folder.Name)
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
