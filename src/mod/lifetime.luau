local attr = require("@mod/attributes")
local clock = require("@mod/clock")
local logger = require("@mod/logger")
local scheduler = require("@mod/scheduler")
local timing_common = require("@mod/common/timing")
local numeric_common = require("@mod/common/numeric")

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

  -- what the handle's speed and pause set, hanging from the clock of the
  -- effect that started the emit, or from the global clock
  clock: clock.Clock,

  -- what every write of the emit ranks at against another emit's, and
  -- whether it is a ConstantVFX tick's, which a one-shot emit outranks. both
  -- are inherited by the emits it starts
  priority: number,
  constant: boolean,

  -- the writers its effects hold, so a new priority reaches their targets
  writers: { writer }?,

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

  -- what every step and wait of the effect advances on, and what its authored
  -- Speed sets
  clock: clock.Clock,

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

-- one property or attribute on one instance that some effect writes but did
-- not make, and every writer on it
export type target = {
  obj: any,
  source: string,
  name: string,

  -- what goes back once the last writer leaves: the value read when the
  -- first joined, or whatever somebody else has written over the owner since
  restore: any,

  -- what the target read back after the owner's last write, which a property
  -- stores single precision
  written: any,

  owner: writer?,
  writers: { writer },

  -- the first value written since the target was last let go, which a hook's
  -- Offset counts from
  first: any,

  -- connected while game code reads the target in place of having it
  -- written, and the identity of the target's type, which a quiet hook's
  -- Offset reads
  hooks: { WriteHook }?,
  identity: any,
  destroying: any,
}

-- one effect's claim on one target, joined at its first set
export type writer = {
  fx: effect,
  obj: any,
  source: string,
  name: string,

  target: target?,
  order: number,

  -- what a legacy child leaves behind when it leaves owning the target:
  -- "keep" its own last value, "start" the start value it was authored with
  rule: string?,
  start: any,

  last: any,
  left: boolean,
}

-- what game code reads in place of a target ForgeVFX stops writing while it
-- is connected
export type WriteHook = {
  Connected: boolean,
  Active: boolean,
  Value: any,
  Offset: any,
  Priority: number?,
  Disconnect: (self: WriteHook) -> (),
}

-- keyed by the locked instance for as long as one effect holds it, and cleared
-- by that effect's release, so a cancelled effect can no longer leak one. weak
-- keyed like the registry in utility, so a lock never pins an instance whose
-- effect never releases
local LOCKS = setmetatable({} :: { [Instance]: boolean }, { __mode = "k" })

-- waiters woken but not resumed yet, held back while a clear is in progress
local wakes: { thread } = {}
local clearing = 0

-- the effect each spawned thread runs for, weak keyed so a finished one is let
-- go, so a spawned thread that started another can tell it belongs to the
-- stopped effect
local SPAWNED = setmetatable({} :: { [thread]: effect }, { __mode = "k" })

-- every target some writer holds, by instance, source and name. weak keyed
-- like LOCKS, so a destroyed instance takes its targets with it
local TARGETS = setmetatable({} :: { [any]: { [string]: { [string]: target } } }, { __mode = "k" })

-- how many writers have joined so far, which ranks the newer of two
local joined = 0

-- the target each connected hook reads
local HOOKED = setmetatable({} :: { [WriteHook]: target }, { __mode = "k" })

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

function lifetime.emit(parent: emit?, above: clock.Clock?): emit
  local emit: emit = {
    parent = parent,
    effects = {},
    children = {},
    clock = clock.new(above or (if parent then parent.clock else clock.global)),
    priority = if parent then parent.priority else 0,
    constant = if parent then parent.constant else false,
    writers = nil,
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

function lifetime.effect(emit: emit, depth: number, effects: any, above: clock.Clock?): effect
  local fx: effect = {
    emit = emit,
    depth = depth,
    clock = clock.new(above or emit.clock),
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

  clock.drop(fx.clock)

  while true do
    local ok, err = pcall(releaseResources, fx, fx.cancelled)

    if ok then
      break
    end

    logger.warn(`failed to release an effect resource with error: {err}`)
  end

  finishEffect(fx)
end

local function readProperty(obj: any, name: string): any
  return obj[name]
end

local function writeProperty(obj: any, name: string, v: any)
  obj[name] = v
end

-- a property that does not exist throws on the read, which reads as nil
local function read(target: target): any
  if target.source ~= "property" then
    return attr.raw(target.obj, target.name)
  end

  local ok, v = pcall(readProperty, target.obj, target.name)

  return if ok then v else nil
end

-- the attribute arm goes through the cache-aware write, where every reader of
-- an attribute looks
local function put(target: target, v: any): boolean
  if target.source ~= "property" then
    return (pcall(attr.set, target.obj, target.name, v))
  end

  return (pcall(writeProperty, target.obj, target.name, v))
end

local function targetOf(obj: any, source: string, name: string, make: boolean): target?
  local sources = TARGETS[obj]

  if sources == nil then
    if not make then
      return nil
    end

    sources = {}
    TARGETS[obj] = sources
  end

  local names = sources[source]

  if names == nil then
    if not make then
      return nil
    end

    names = {}
    sources[source] = names
  end

  local target = names[name]

  if target == nil and make then
    target = {
      obj = obj,
      source = source,
      name = name,
      restore = nil,
      written = nil,
      owner = nil,
      writers = {},
      first = nil,
      hooks = nil,
      identity = nil,
      destroying = nil,
    }

    names[name] = target
  end

  return target
end

local function forget(target: target)
  local sources = TARGETS[target.obj]
  local names = if sources then sources[target.source] else nil

  if names == nil then
    return
  end

  names[target.name] = nil
end

-- the newer of two writers at one priority, unless only the newer is a
-- ConstantVFX tick's
local function outranks(a: writer, b: writer): boolean
  local above, below = a.fx.emit, b.fx.emit

  if above.priority ~= below.priority then
    return above.priority > below.priority
  end

  if above.constant ~= below.constant then
    return below.constant
  end

  return a.order > b.order
end

local function ownerOf(target: target): writer?
  local best: writer? = nil

  for _, w in target.writers do
    if best == nil or outranks(w, best) then
      best = w
    end
  end

  return best
end

-- what a type's Offset reads with nothing written over it, nil for a type with
-- no subtraction
local function identityOf(v: any): any
  local kind = typeof(v)

  if kind == "number" then
    return 0
  elseif kind == "Vector2" then
    return Vector2.zero
  elseif kind == "Vector3" then
    return Vector3.zero
  elseif kind == "UDim" then
    return UDim.new()
  elseif kind == "UDim2" then
    return UDim2.new()
  elseif kind == "CFrame" then
    return CFrame.identity
  end

  return nil
end

-- how far `v` has moved from the first value written, in the type the hook
-- was made for
local function offsetOf(target: target, v: any): any
  local identity = target.identity
  local first = target.first

  if identity == nil or first == nil or typeof(v) ~= typeof(identity) or typeof(first) ~= typeof(identity) then
    return identity
  end

  if typeof(v) == "CFrame" then
    return first:Inverse() * v
  end

  return v - first
end

-- the owner's value into every hook on the target
local function publish(target: target, v: any)
  local owner = target.owner
  local priority = if owner then owner.fx.emit.priority else nil
  local offset = offsetOf(target, v)

  for _, hook in target.hooks :: { WriteHook } do
    hook.Active = true
    hook.Value = v
    hook.Offset = offset
    hook.Priority = priority
  end
end

-- every hook on a target nobody writes any more
local function quiet(target: target)
  for _, hook in target.hooks :: { WriteHook } do
    hook.Active = false
    hook.Value = nil
    hook.Offset = target.identity
    hook.Priority = nil
  end
end

-- the owner's value onto the target, or into its hooks while one is
-- connected. a live value other than the one read back last was written by
-- somebody else, and is what goes back at the end
local function land(target: target, v: any): boolean
  if target.first == nil then
    target.first = v
  end

  if target.hooks ~= nil then
    publish(target, v)
    return true
  end

  local live = read(target)

  if live ~= target.written then
    target.restore = live
  end

  if not put(target, v) then
    return false
  end

  target.written = if target.source == "property" then read(target) else v

  return true
end

-- the owner worked out again, and a new one's value written at once so the
-- target never shows a frame of the old owner's
local function retarget(target: target)
  local owner = ownerOf(target)

  if owner == target.owner then
    return
  end

  target.owner = owner

  if owner ~= nil then
    land(target, owner.last)
  end
end

-- an effect's claim on one target, which joins the target's writers at its
-- first set. a legacy child's `rule` says what it leaves behind
function lifetime.write(fx: effect, obj: any, source: string, name: string, rule: string?, start: any?): writer
  return {
    fx = fx,
    obj = obj,
    source = source,
    name = name,
    target = nil,
    order = 0,
    rule = rule,
    start = start,
    last = nil,
    left = false,
  }
end

local function join(w: writer): target
  local target = targetOf(w.obj, w.source, w.name, true) :: target

  if #target.writers == 0 then
    local current = read(target)

    target.restore = current
    target.written = current
    target.first = nil
  end

  joined += 1

  w.target = target
  w.order = joined

  table.insert(target.writers, w)

  local emit = w.fx.emit
  local writers = emit.writers

  if writers then
    table.insert(writers, w)
  else
    emit.writers = { w }
  end

  lifetime.hold(w.fx, function()
    lifetime.leave(w)
  end)

  return target
end

-- the writer's value this frame: written when it owns the target, and kept
-- for when it comes to own it otherwise. answers false only for a write the
-- target refused
function lifetime.set(w: writer, v: any): boolean
  if w.left or w.fx.state == RELEASED then
    return true
  end

  w.last = v

  local target = w.target

  if target == nil then
    target = join(w)
    target.owner = ownerOf(target)
  end

  if target.owner ~= w then
    return true
  end

  return land(target, v)
end

-- the writer gives the target up, and the next owner takes it from where
-- that one is. the last to leave puts back what the target goes back to
function lifetime.leave(w: writer)
  if w.left then
    return
  end

  w.left = true

  local target = w.target

  if target == nil then
    return
  end

  swapRemove(target.writers, w)

  local writers = w.fx.emit.writers

  if writers then
    swapRemove(writers, w)
  end

  if target.owner == w then
    if w.rule == "keep" then
      target.restore = w.last
    elseif w.rule == "start" then
      target.restore = w.start
    end

    target.owner = nil
    retarget(target)
  end

  if #target.writers > 0 then
    return
  end

  target.first = nil

  if target.hooks ~= nil then
    quiet(target)
    return
  end

  local live = read(target)

  if live ~= target.written then
    target.restore = live
  end

  put(target, target.restore)
  forget(target)
end

-- a new priority for an emit and every emit it started, and the owner of
-- every target their writers hold worked out again
function lifetime.rank(emit: emit, priority: number)
  emit.priority = priority

  local writers = emit.writers

  if writers then
    for _, w in writers do
      local target = w.target :: target

      retarget(target)

      local owner = target.owner

      if target.hooks ~= nil and owner ~= nil then
        publish(target, owner.last)
      end
    end
  end

  for _, child in emit.children do
    lifetime.rank(child, priority)
  end
end

-- how many writers hold a target now
function lifetime.writing(obj: any, source: string, name: string): number
  local target = targetOf(obj, source, name, false)

  return if target then #target.writers else 0
end

-- what a target goes back to once its writers leave, nil while none holds it
function lifetime.restoreOf(obj: any, source: string, name: string): any
  local target = targetOf(obj, source, name, false)

  if target == nil or #target.writers == 0 then
    return nil
  end

  return target.restore
end

local function unhook(hook: WriteHook)
  if not hook.Connected then
    return
  end

  hook.Connected = false

  local target = HOOKED[hook]

  HOOKED[hook] = nil

  local hooks = if target then target.hooks else nil

  if target == nil or hooks == nil then
    return
  end

  swapRemove(hooks, hook)

  if #hooks > 0 then
    return
  end

  target.hooks = nil

  local destroying = target.destroying

  if destroying ~= nil then
    target.destroying = nil
    destroying:Disconnect()
  end

  if #target.writers == 0 then
    forget(target)
    return
  end

  -- only what the game wrote while it held the target goes back at the end,
  -- and the owner writes the target again from its next set
  local live = read(target)

  if live ~= target.written then
    target.restore = live
  end

  target.written = live
end

-- a destroyed instance's hooks read disconnected. an object with no such
-- signal is not watched
local function watchDestroying(target: target)
  local ok, signal = pcall(readProperty, target.obj, "Destroying")

  if not ok or signal == nil then
    return
  end

  target.destroying = signal:Connect(function()
    for _, hook in table.clone(target.hooks or {}) do
      unhook(hook)
    end
  end)
end

-- game code reads the target through the hook, and ForgeVFX stops writing it
-- until the last hook on it disconnects
function lifetime.hook(obj: any, source: string, name: string): WriteHook
  local target = targetOf(obj, source, name, true) :: target
  local hooks = target.hooks

  if hooks == nil then
    hooks = {}
    target.hooks = hooks
    target.identity = identityOf(read(target))

    watchDestroying(target)
  end

  local hook: WriteHook = {
    Connected = true,
    Active = false,
    Value = nil,
    Offset = target.identity,
    Priority = nil,
    Disconnect = unhook,
  }

  local owner = target.owner

  if owner ~= nil and #target.writers > 0 then
    hook.Active = true
    hook.Value = owner.last
    hook.Offset = offsetOf(target, owner.last)
    hook.Priority = owner.fx.emit.priority
  end

  HOOKED[hook] = target
  table.insert(hooks, hook)

  return hook
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

  -- on the effect's clock, so a slowed or paused effect waits longer
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
  end, 0, nil, false, fx.clock)

  coroutine.yield()

  return waited
end

-- an authored Speed row as the effect's clock. its track runs on the clock
-- above the effect's, so a speed never scales itself, and is sampled ahead of
-- every step the effect adds after this call, so those see the frame's speed
-- on the frame it changes. a speed is never below zero, and one that rests at
-- or below it for good halts the effect's timers
function lifetime.speed(fx: effect, row: any)
  local timeline = fx.clock
  local first = row.at(0)

  clock.setSpeed(timeline, if typeof(first) == "number" and numeric_common.finite(first) then math.max(first, 0) else 1)
  clock.refresh(timeline)

  if not row.animated then
    timeline.halted = timeline.speed <= 0
    return
  end

  local duration = row.duration
  local elapsed = 0
  local handle: scheduler.Handle

  handle = scheduler.add("compute", function(deltaTime: number)
    elapsed += deltaTime

    local v = row.at(math.min(elapsed, duration))

    if typeof(v) == "number" and numeric_common.finite(v) then
      clock.setSpeed(timeline, math.max(v, 0))
      clock.refresh(timeline)
    end

    if elapsed < duration then
      return
    end

    handle:Disconnect()
    timeline.halted = timeline.speed <= 0
  end, 0, fx, false, timeline.parent)

  lifetime.hold(fx, handle)
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

    clock.drop(emit.clock)

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

  SPAWNED[thread] = fx

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

  if caller == fx.thread or SPAWNED[caller] == fx then
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
  local owner = SPAWNED[thread]

  for _, fx in emit.effects do
    if fx.thread == thread or owner == fx then
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

  -- nothing runs on a cleared emit again, so nothing below it stays slowed
  clock.drop(emit.clock)

  if not ok then
    logger.warn(`failed to clear an emit with error: {err}`)
  end

  flushWakes()

  if self then
    error(HALT)
  end
end

return lifetime
