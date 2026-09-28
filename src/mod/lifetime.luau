local logger = require("@mod/logger")
local scheduler = require("@mod/scheduler")
local timing_common = require("@mod/common/timing")

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

  -- what counts this emit out of each join it was included in, once it is done
  joins: { () -> () }?,

  sealed: boolean,
  done: boolean,

  -- set by clear over the whole subtree, so a reader that arrives after a
  -- cancel can tell a cleared emit from one that ended on its own
  cleared: boolean,
}

export type effect = {
  emit: emit,
  depth: number,

  -- the effects service, which a module reaches its nested and on-finish emits
  -- through
  effects: any,

  state: number,
  thread: thread?,
  cancelled: boolean?,

  -- released in this order, each list in reverse
  defers: { (cancelled: boolean) -> () }?,
  threads: { RBXScriptConnection | thread | scheduler.Handle | () -> () }?,
  clones: { Instance }?,
  cleanups: { () -> () }?,
}

-- what a body waits on for its own pieces and child emits. the count is live,
-- so a piece or a child counted in while the body waits is waited for too
export type join = {
  fx: effect,
  count: number,
  waiter: thread?,
}

-- keyed by the locked instance for as long as one effect holds it, and cleared
-- by that effect's release, so a cancelled effect can no longer leak one. weak
-- keyed like the registry in utility, so a lock never pins an instance whose
-- effect never releases
local LOCKS = setmetatable({} :: { [Instance]: boolean }, { __mode = "k" })

-- waiters woken but not resumed yet, held back while a clear is in progress
local wakes: { thread } = {}
local clearing = 0

-- the effect each piece thread runs for, weak keyed so a finished piece is let
-- go, so a piece that started another piece can tell it belongs to the stopped
-- effect
local PIECES = setmetatable({} :: { [thread]: effect }, { __mode = "k" })

-- thrown through a body or a piece whose effect it cleared, or a piece it
-- started cleared, and taken by that thread's own wrapper, so the thread ends
-- there instead of running on for an effect that is gone
local HALT = table.freeze({})

local function trace(err: any)
  if err == HALT then
    return err
  end

  return debug.traceback(err, 2)
end

function lifetime.emit(parent: emit?): emit
  local emit: emit = {
    parent = parent,
    effects = {},
    children = {},
    pending = 0,
    waiters = {},
    sealed = false,
    done = false,
    cleared = false,
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
    if v.Disconnect ~= nil then
      v:Disconnect()
    else
      lifetime.releasePlain(v)
    end
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
  elseif kind == "table" and (value :: any).Disconnect ~= nil then
    scheduler.adopt(value :: any, fx)
    file(fx, "threads", value)
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
  if fx.state ~= RUNNING then
    return true
  end

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

-- a step of this effect in one of the scheduler's phases, stopped when the
-- effect is released. a follower steps at the effect's own depth
function lifetime.step(fx: effect, run: (deltaTime: number) -> (), phase: scheduler.Phase?): scheduler.Handle
  return lifetime.hold(fx, scheduler.add(phase or "compute", run, fx.depth, fx))
end

-- parks the calling thread, whichever thread of the effect it is, until the
-- frames add up to `seconds`, and answers how long that took. a wait of no
-- usable length does not yield at all, and a wait on an effect that is no
-- longer running never resumes
function lifetime.wait(fx: effect, seconds: number): number
  if scheduler.inPass() then
    logger.error("lifetime.wait yields, so it cannot run inside a step or a tween's callback; start it in task.spawn")
  end

  local left = timing_common.duration(seconds)

  if left <= 0 and fx.state == RUNNING then
    return 0
  end

  local thread = coroutine.running()
  local waited = 0
  local handle: scheduler.Handle

  handle = scheduler.add("wait", function(deltaTime: number)
    if fx.state ~= RUNNING then
      handle:Disconnect()
      return
    end

    waited += deltaTime

    if waited < left then
      return
    end

    handle:Disconnect()
    task.spawn(thread)
  end)

  coroutine.yield()

  return waited
end

function lifetime.run(fx: effect, body: (effect) -> ())
  if fx.state ~= RUNNING then
    return
  end

  local thread = coroutine.create(function()
    local ok, err = xpcall(body, trace, fx)

    if not ok and err ~= HALT then
      logger.warn(`effect failed with error: {err}`)
    end

    lifetime.release(fx, false)
  end)

  fx.thread = thread

  task.spawn(thread)
end

-- an effect whose step threw: its body stops where it is parked and everything
-- it holds is released as a clear would release it
function lifetime.kill(fx: effect)
  if fx.state ~= RUNNING then
    return
  end

  fx.state = STOPPED

  local thread = fx.thread

  if thread and thread ~= coroutine.running() and coroutine.status(thread) == "suspended" then
    coroutine.close(thread)
  end

  lifetime.release(fx, true)
end

scheduler.failed = lifetime.kill

-- a wake resumes at once, except during a clear: a thread resumed halfway
-- through one would see a tree half released
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

  if emit.sealed and not emit.done then
    emit.done = true

    local parent = emit.parent

    if parent then
      swapRemove(parent.children, emit)
      parent.pending -= 1
      settle(parent)
    end

    local joins = emit.joins

    if joins then
      emit.joins = nil

      for _, done in joins do
        done()
      end
    end
  end

  wake(emit)
end

-- the caller has added every effect it will add directly. children an effect
-- starts later still count, because that effect is pending until it returns
function lifetime.seal(emit: emit)
  emit.sealed = true
  settle(emit)
end

function lifetime.await(emit: emit)
  if scheduler.inPass() then
    logger.error("lifetime.await yields, so it cannot run inside a step or a tween's callback; start it in task.spawn")
  end

  if emit.pending == 0 then
    return
  end

  table.insert(emit.waiters, coroutine.running())
  coroutine.yield()
end

function lifetime.join(fx: effect): join
  return { fx = fx, count = 0, waiter = nil }
end

-- counts one more thing into the join and answers what counts it out. only the
-- first call counts, so a piece may be counted out by its own end and again by
-- whatever tears it down
function lifetime.add(join: join)
  join.count += 1

  local counted = true

  return function()
    if not counted then
      return
    end

    counted = false
    join.count -= 1

    local waiter = join.waiter

    if join.count > 0 or waiter == nil then
      return
    end

    join.waiter = nil

    table.insert(wakes, waiter)
    flushWakes()
  end
end

-- a child emit counted into the join until it is done, by any means: a clear
-- finishes it too
function lifetime.include(join: join, emit: emit)
  if emit.done then
    return
  end

  local done = lifetime.add(join)
  local joins = emit.joins

  if joins then
    table.insert(joins, done)
  else
    emit.joins = { done }
  end
end

-- a piece on a thread of its own, held by the effect so a clear closes it, and
-- counted into the join until it returns or is closed. a piece that throws is
-- logged and counted out, and the pieces beside it keep running
function lifetime.spawn(join: join, body: (...any) -> (), ...: any)
  local fx = join.fx

  if fx.state ~= RUNNING then
    return
  end

  local done = lifetime.add(join)

  local thread = coroutine.create(function(...)
    local ok, err = xpcall(body, trace, ...)

    if not ok and err ~= HALT then
      logger.warn(`a piece failed with error: {err}`)
    end

    done()
  end)

  PIECES[thread] = fx

  file(fx, "threads", function()
    disposeOne(thread)
    done()
  end)

  task.spawn(thread, ...)

  if fx.state == RUNNING then
    return
  end

  -- the effect stopped while the piece ran, so a body or piece of this effect
  -- that started it ends as well
  local caller = coroutine.running()

  if caller == fx.thread or PIECES[caller] == fx then
    error(HALT)
  end
end

-- parks the calling thread until everything counted into the join is out, and
-- not at all once the join's effect has stopped. a join has one waiter at a
-- time, and may be waited on again once it is empty
function lifetime.awaitJoin(join: join)
  if scheduler.inPass() then
    logger.error(
      "lifetime.awaitJoin yields, so it cannot run inside a step or a tween's callback; start it in task.spawn"
    )
  end

  if join.count == 0 or join.fx.state ~= RUNNING then
    return
  end

  join.waiter = coroutine.running()
  coroutine.yield()
end

-- the body or a piece of an effect in the tree, so a piece clearing its own
-- emit ends the way a body does, and neither its `piece after` nor the body's
-- `joined` ever runs
local function ownsThread(emit: emit, thread: thread): boolean
  local piece = PIECES[thread]

  for _, fx in emit.effects do
    if fx.thread == thread or piece == fx then
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
-- closed and ends at the end of clear instead
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

-- pass two: children before parents, over copies because release edits both
-- lists. a cleared child can never gain an effect again, so it is sealed on the
-- way out and finishes its parent even if the caller never sealed it. the root
-- keeps the flag the caller left it with, and every emit the pass walks is
-- marked cleared on the way in
local function releaseTree(emit: emit, root: boolean)
  emit.cleared = true

  for _, child in table.clone(emit.children) do
    releaseTree(child, false)
  end

  for _, fx in table.clone(emit.effects) do
    lifetime.release(fx, true)
  end

  if root then
    return
  end

  emit.sealed = true
  settle(emit)
end

function lifetime.clear(emit: emit)
  local running = coroutine.running()
  local self = ownsThread(emit, running)

  clearing += 1

  local ok, err = pcall(function()
    stopTree(emit, running)
    releaseTree(emit, true)
  end)

  clearing -= 1

  if not ok then
    logger.warn(`failed to clear an emit with error: {err}`)
  end

  flushWakes()

  if self then
    error(HALT)
  end
end

return lifetime
