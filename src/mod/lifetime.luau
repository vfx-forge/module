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
-- by that effect's release, so a cancelled effect can no longer leak one
local LOCKS: { [Instance]: boolean } = {}

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

-- the emit tree lands here next: seal, await and clear
settle = function(emit: emit) end

return lifetime
