local logger = require("@mod/logger")

local RUNNING = 1
local STOPPED = 2
local RELEASED = 3

local lifetime = {}

lifetime.RUNNING = RUNNING
lifetime.STOPPED = STOPPED
lifetime.RELEASED = RELEASED

export type emit = {
  parent: emit?,
  effects: { effect },
  children: { emit },

  pending: number,
  waiters: { thread },

  sealed: boolean,
  done: boolean,

  -- evaera promises an effect module still creates for its own pieces, cancelled
  -- together with the emit until the promise removal lands
  promises: { any },
  finished: any?,
}

export type effect = {
  emit: emit,
  depth: number,

  -- the effects service the old scope carried for the scope.effects.emitNested
  -- call sites, kept until the promise removal
  effects: any,

  state: number,
  thread: thread?,
  cancelled: boolean?,

  -- released in this order, each list in reverse
  defers: { (cancelled: boolean) -> () }?,
  threads: { RBXScriptConnection | thread }?,
  clones: { Instance }?,
  cleanups: { () -> () }?,
}

-- keyed by the locked instance for as long as one effect holds it, and cleared
-- by that effect's release, so a cancelled effect can no longer leak one. weak
-- keyed like the registry in utility, so a lock never pins an instance whose
-- effect never releases
local LOCKS = setmetatable({} :: { [Instance]: boolean }, { __mode = "k" })

function lifetime.emit(parent: emit?): emit
  local emit: emit = {
    parent = parent,
    effects = {},
    children = {},
    pending = 0,
    waiters = {},
    sealed = false,
    done = false,
    promises = {},
  }

  if parent then
    parent.pending += 1
    table.insert(parent.children, emit)
  end

  return emit
end

function lifetime.effect(emit: emit, depth: number, effects: any): effect
  local fx: effect = {
    emit = emit,
    depth = depth,
    effects = effects,
    state = RUNNING,
  }

  emit.pending += 1
  table.insert(emit.effects, fx)

  return fx
end

local function swapRemove(list: { any }, item: any)
  local index = table.find(list, item)

  if not index then
    return
  end

  local last = #list
  list[index] = list[last]
  list[last] = nil
end

local function disposeOne(v: any)
  local t = typeof(v)

  if t == "Instance" then
    v:Destroy()
  elseif t == "RBXScriptConnection" then
    v:Disconnect()
  elseif t == "thread" then
    if coroutine.status(v) == "suspended" then
      coroutine.close(v)
    end
  elseif t == "function" then
    v()
  elseif t == "table" then
    lifetime.releasePlain(v)
  end
end

-- a scope table from before records, still used by the module-level scopes.
-- every entry is taken out before it runs so a throw cannot run it twice
function lifetime.releasePlain(scope: { any })
  while #scope > 0 do
    local last = #scope
    local v = scope[last]
    scope[last] = nil

    disposeOne(v)
  end
end

local function file(fx: effect, key: string, v: any)
  local list = (fx :: any)[key]

  if list then
    table.insert(list, v)
  else
    (fx :: any)[key] = { v }
  end
end

function lifetime.hold<T>(fx: effect, value: T): T
  if fx.state == RELEASED then
    disposeOne(value)
    return value
  end

  local kind = typeof(value)

  if kind == "function" then
    file(fx, "cleanups", value)
  elseif kind == "Instance" then
    file(fx, "clones", value)
  elseif kind == "RBXScriptConnection" or kind == "thread" then
    file(fx, "threads", value)
  elseif kind == "table" then
    file(fx, "cleanups", function()
      lifetime.releasePlain(value :: any)
    end)
  else
    logger.warn(`an effect cannot hold a {kind}`)
  end

  return value
end

function lifetime.defer(fx: effect, callback: (cancelled: boolean) -> ())
  if fx.state == RELEASED then
    callback(fx.cancelled == true)
    return
  end

  file(fx, "defers", callback)
end

function lifetime.lock(fx: effect, ref: Instance): boolean
  if LOCKS[ref] then
    return true
  end

  LOCKS[ref] = true

  lifetime.hold(fx, function()
    LOCKS[ref] = nil
  end)

  return false
end

function lifetime.isLocked(ref: Instance): boolean
  return LOCKS[ref] == true
end

-- each list is emptied from the back and every entry taken out before it runs,
-- so a throw re-enters here and carries on after the thrower
local function drain(fx: effect, key: string, dispose: (any) -> ())
  local list = (fx :: any)[key]

  if not list then
    return
  end

  while #list > 0 do
    local last = #list
    local v = list[last]
    list[last] = nil

    dispose(v)
  end

  (fx :: any)[key] = nil
end

local function releaseResources(fx: effect, cancelled: boolean)
  drain(fx, "defers", function(callback)
    callback(cancelled)
  end)

  drain(fx, "threads", disposeOne)
  drain(fx, "clones", disposeOne)
  drain(fx, "cleanups", disposeOne)
end

-- filled in with the emit tree below; declared here because release needs it
local settle

local function finishEffect(fx: effect)
  local emit = fx.emit

  swapRemove(emit.effects, fx)
  emit.pending -= 1

  settle(emit)
end

function lifetime.release(fx: effect, cancelled: boolean?)
  if fx.state == RELEASED then
    return
  end

  fx.state = RELEASED
  fx.cancelled = cancelled == true

  while true do
    local ok, err = pcall(releaseResources, fx, fx.cancelled)

    if ok then
      break
    end

    logger.warn(`failed to release an effect resource with error: {err}`)
  end

  finishEffect(fx)
end

function lifetime.run(fx: effect, body: (effect) -> ())
  local thread = coroutine.create(function()
    local ok, err = xpcall(body, debug.traceback, fx)

    if not ok then
      logger.warn(`effect failed with error: {err}`)
    end

    lifetime.release(fx, false)
  end)

  fx.thread = thread

  task.spawn(thread)
end

local clearing = 0
local wakes: { thread } = {}

-- a wake resumes at once, the same timing the promises had, except during a
-- clear: a thread resumed halfway through one would see a tree half released
local function flushWakes()
  if clearing > 0 then
    return
  end

  while #wakes > 0 do
    local batch = wakes
    wakes = {}

    for _, thread in batch do
      if coroutine.status(thread) == "suspended" then
        task.spawn(thread)
      end
    end
  end
end

local function wake(emit: emit)
  local waiters = emit.waiters

  if #waiters == 0 then
    return
  end

  emit.waiters = {}

  for _, thread in waiters do
    table.insert(wakes, thread)
  end

  flushWakes()
end

settle = function(emit: emit)
  if emit.pending > 0 then
    return
  end

  wake(emit)

  if not emit.sealed or emit.done then
    return
  end

  emit.done = true

  local parent = emit.parent

  if parent then
    swapRemove(parent.children, emit)
    parent.pending -= 1
    settle(parent)
  end
end

-- the caller has added every effect it will add directly. children an effect
-- starts later still count, because that effect is pending until it returns
function lifetime.seal(emit: emit)
  emit.sealed = true
  settle(emit)
end

function lifetime.await(emit: emit)
  if emit.pending == 0 then
    return
  end

  table.insert(emit.waiters, coroutine.running())
  coroutine.yield()
end

local function ownsThread(emit: emit, thread: thread): boolean
  for _, fx in emit.effects do
    if fx.thread == thread then
      return true
    end
  end

  for _, child in emit.children do
    if ownsThread(child, thread) then
      return true
    end
  end

  return false
end

-- pass one: every thread in the subtree stops before anything is released, so
-- no body resumes into a half-released tree. the running thread cannot be
-- closed and is parked at the end of clear instead
local function stopTree(emit: emit, running: thread)
  for _, fx in emit.effects do
    if fx.state ~= RUNNING then
      continue
    end

    fx.state = STOPPED

    local thread = fx.thread

    if thread and thread ~= running and coroutine.status(thread) == "suspended" then
      coroutine.close(thread)
    end
  end

  for _, child in emit.children do
    stopTree(child, running)
  end
end

-- pass two: children before parents, over copies because release edits both lists
local function releaseTree(emit: emit)
  for _, child in table.clone(emit.children) do
    releaseTree(child)
  end

  for _, fx in table.clone(emit.effects) do
    lifetime.release(fx, true)
  end
end

function lifetime.clear(emit: emit)
  local running = coroutine.running()
  local self = ownsThread(emit, running)

  clearing += 1

  stopTree(emit, running)
  releaseTree(emit)

  clearing -= 1

  flushWakes()

  if self then
    coroutine.yield()
  end
end

return lifetime
