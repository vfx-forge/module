local mod = require("@mod/mod")
local knob = require("@mod/knob")
local lerp = require("@mod/lerp")
local curve = require("@mod/curve")
local shape = require("@mod/shape")
local tween = require("@mod/tween")
local curves = require("@mod/curves")
local logger = require("@mod/logger")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")

local color = require("@mod/color/color")

local Bezier = require("@obj/Bezier")

local NAN = 0 / 0
local NAN_VECTOR = vector.create(NAN, NAN, NAN)

-- thrown through an effect's own thread once a callback of it has failed, so
-- the author's code after the failing call never runs on an effect that is gone
local STOP = table.freeze({})

-- what an emit waits for once the author's emit returns: the tweens and nested
-- emits counted into `join`, and every join the author made
type Own = { join: lifetime.join?, joins: { lifetime.join } }

local OWN: { [lifetime.effect]: Own } = setmetatable({}, { __mode = "k" }) :: any

-- per module, the instances a failure was already reported for
local WARNED: { [any]: { [Instance]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

-- the threads of the pieces an author spawned, and the effect each belongs to
local PIECES: { [thread]: lifetime.effect } = setmetatable({}, { __mode = "k" }) :: any

local JOINS: { [any]: { join: lifetime.join, ctx: any } } = setmetatable({}, { __mode = "k" }) :: any
local WRITERS: { [any]: { writer: lifetime.writer, warned: boolean } } = setmetatable({}, { __mode = "k" }) :: any
local PATHS: { [any]: Bezier.Bezier } = setmetatable({}, { __mode = "k" }) :: any
local CURVES: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- a traceback for the author's error, and STOP as it came
local function trace(err: any)
  if err == STOP then
    return err
  end

  return debug.traceback(tostring(err), 2)
end

-- the engine spells a vector either way
local VECTORS = { vector = true, Vector3 = true }

local HOLDABLE = { Instance = true, RBXScriptConnection = true, ["function"] = true, thread = true }

local v1 = {}

local function scopeOf(ctx: any, name: string): lifetime.effect
  if type(ctx) ~= "table" or type(ctx.scope) ~= "table" then
    logger.error(`sdk.{name} takes the ctx emit was handed as its first argument`)
  end

  return ctx.scope
end

local function callable(fn: any, name: string)
  if type(fn) ~= "function" then
    logger.error(`sdk.{name} takes a function, got {typeof(fn)}`)
  end
end

local function yielding(name: string)
  if scheduler.inPass() then
    logger.error(`sdk.{name} yields, so it cannot run inside a step or a tween's callback; start it in sdk.spawn`)
  end
end

local function ownOf(scope: lifetime.effect): Own
  local own = OWN[scope]

  if own == nil then
    own = { join = nil, joins = {} }
    OWN[scope] = own
  end

  return own
end

local function joinOf(scope: lifetime.effect): lifetime.join
  local own = ownOf(scope)
  local join = own.join

  if join == nil then
    join = lifetime.join(scope)
    own.join = join
  end

  return join
end

-- the failure warned about once per module and instance, and the effect ended
local function report(ctx: any, err: any)
  local scope = ctx.scope

  if scope.state ~= lifetime.RUNNING then
    return
  end

  local module = ctx.effect
  local seen = WARNED[module]

  if seen == nil then
    seen = setmetatable({}, { __mode = "k" }) :: any
    WARNED[module] = seen
  end

  if not seen[ctx.ref] then
    seen[ctx.ref] = true

    local id = if module ~= nil then module.id else "?"

    logger.warn(`custom effect {id} failed on {ctx.ref:GetFullName()}: {tostring(err)}`)
  end

  lifetime.kill(scope)
end

-- a callback of the author's, run so a throw ends its effect. on the effect's
-- own body or one of its pieces the thread stops there too
local function guarded(ctx: any, fn: (...any) -> (), ...: any): boolean
  local ok, err = xpcall(fn, trace, ...)

  if ok then
    return true
  end

  if err == STOP then
    error(STOP, 0)
  end

  report(ctx, err)

  local running = coroutine.running()

  if running == ctx.scope.thread or PIECES[running] == ctx.scope then
    error(STOP, 0)
  end

  return false
end

function v1.knob(default: any)
  return knob(default)
end

v1.mod = table.freeze({
  from = function(value: any)
    return mod.from(value)
  end,

  to = function(value: any)
    return mod.to(value)
  end,
})

function v1.wait(ctx: any, seconds: number): number
  local scope = scopeOf(ctx, "wait")

  yielding("wait")

  if type(seconds) ~= "number" then
    logger.error(`sdk.wait takes a number of seconds, got {typeof(seconds)}`)
  end

  return lifetime.wait(scope, seconds)
end

function v1.step(ctx: any, fn: (dt: number, elapsed: number) -> ())
  local scope = scopeOf(ctx, "step")

  callable(fn, "step")

  local elapsed = 0

  local handle = lifetime.step(scope, function(deltaTime: number)
    elapsed += deltaTime
    guarded(ctx, fn, deltaTime, elapsed)
  end)

  return function()
    handle:Disconnect()
  end
end

-- a preset's name, a curve row's value, a chain of vectors or a function of
-- time, as the shape the internal curve takes
local function shapeOf(given: any): any
  local kind = typeof(given)

  if kind == "string" then
    -- a curve row's value is binary and starts at time zero, so a name made of
    -- letters is always meant as a preset
    if curves.PRESETS[given] == nil and string.match(given, "^[%a_][%w_]*$") then
      logger.error(`{given} is no curve preset, use linear, easeIn, easeOut or easeInOut`)
    end

    return given
  end

  if kind == "buffer" then
    return given
  end

  if kind == "function" then
    return function(t: number)
      if t < 0 then
        t = 0
      elseif t > 1 then
        t = 1
      end

      return given(t)
    end
  end

  if kind == "table" then
    local chain = table.create(#given)

    for i, point in given do
      if not VECTORS[typeof(point)] then
        logger.error(`a curve's point {i} is a {typeof(point)}, not a vector`)
      end

      chain[i] = point
    end

    return chain
  end

  logger.error(`a curve's shape is a preset, a curve param's value, a chain of vectors or a function, got {kind}`)
end

function v1.curve(duration: number, given: any, options: {}?)
  if type(duration) ~= "number" then
    logger.error(`sdk.curve takes its duration in seconds first, got {typeof(duration)}`)
  end

  if options ~= nil and (type(options) ~= "table" or next(options) ~= nil) then
    logger.error("sdk.curve takes no options yet")
  end

  local made = table.freeze(curve.new(duration, shapeOf(given)))

  CURVES[made] = true

  return made
end

function v1.tween(ctx: any, eased: any, fn: (alpha: number) -> ())
  local scope = scopeOf(ctx, "tween")

  if not CURVES[eased] then
    logger.error("sdk.tween plays a curve made by sdk.curve")
  end

  callable(fn, "tween")

  -- the author's return value is dropped, so an expression bodied callback
  -- that happens to answer false cannot end the tween
  tween.play(scope, eased, function(alpha: number)
    if not guarded(ctx, fn, alpha) then
      return false
    end

    return nil
  end, nil, lifetime.add(joinOf(scope)))
end

function v1.hold<T>(ctx: any, thing: T): T
  local scope = scopeOf(ctx, "hold")

  if not HOLDABLE[typeof(thing)] then
    logger.error(`sdk.hold takes an instance, a connection, a function or a thread, got {typeof(thing)}`)
  end

  return lifetime.hold(scope, thing)
end

function v1.join(ctx: any)
  local scope = scopeOf(ctx, "join")
  local join = lifetime.join(scope)
  local token = table.freeze({})

  table.insert(ownOf(scope).joins, join)
  JOINS[token] = { join = join, ctx = ctx }

  return token
end

local function joined(token: any, name: string)
  local entry = JOINS[token]

  if entry == nil then
    logger.error(`sdk.{name} takes a join made by sdk.join`)
  end

  return entry
end

function v1.spawn(token: any, fn: (...any) -> (), ...: any)
  local entry = joined(token, "spawn")
  local ctx = entry.ctx

  callable(fn, "spawn")

  lifetime.spawn(entry.join, function(...)
    PIECES[coroutine.running()] = ctx.scope

    -- a failing piece has been reported and its effect ended, and the STOP
    -- that unwound it ends here
    pcall(guarded, ctx, fn, ...)
  end, ...)
end

function v1.await(token: any)
  local entry = joined(token, "await")

  yielding("await")
  lifetime.awaitJoin(entry.join)
end

function v1.emit(ctx: any, instance: Instance)
  local scope = scopeOf(ctx, "emit")

  if typeof(instance) ~= "Instance" then
    logger.error(`sdk.emit takes an instance, got {typeof(instance)}`)
  end

  scope.effects.emitInstance(instance, scope.depth + 1, scope, joinOf(scope))
end

local Writer = {}
Writer.__index = Writer

function Writer.set(self: any, value: any)
  local entry = WRITERS[self]

  if lifetime.set(entry.writer, value) or entry.warned then
    return
  end

  entry.warned = true

  local w = entry.writer

  logger.warn(`a {typeof(value)} could not be written to {w.name} of {w.obj:GetFullName()}`)
end

table.freeze(Writer)

local function writerOf(ctx: any, obj: Instance, source: string, name: string, call: string)
  local scope = scopeOf(ctx, call)

  if typeof(obj) ~= "Instance" then
    logger.error(`sdk.{call} writes to an instance, got {typeof(obj)}`)
  end

  if type(name) ~= "string" then
    logger.error(`sdk.{call} takes the name it writes to, got {typeof(name)}`)
  end

  local made = table.freeze(setmetatable({}, Writer))

  WRITERS[made] = { writer = lifetime.write(scope, obj, source, name), warned = false }

  return made
end

function v1.getWriter(ctx: any, obj: Instance, property: string)
  return writerOf(ctx, obj, "property", property, "getWriter")
end

function v1.getAttributeWriter(ctx: any, obj: Instance, name: string)
  return writerOf(ctx, obj, "attribute", name, "getAttributeWriter")
end

function v1.speed(ctx: any, track: any)
  local scope = scopeOf(ctx, "speed")

  if type(track) ~= "table" or type(track.at) ~= "function" then
    logger.error("sdk.speed takes a Speed param's value, a knob declared with :mod()")
  end

  lifetime.speed(scope, track)
end

function v1.lerp(a: any, b: any, t: number)
  return lerp.any(a, b, t)
end

v1.color = table.freeze({
  blend = function(a: Color3, b: Color3, t: number)
    return color.blend(a, b, t)
  end,

  toOklab = function(c: Color3)
    return color.toOklab(c)
  end,

  fromOklab = function(lab: Vector3)
    return color.fromOklab(lab)
  end,
})

v1.shape = table.freeze({
  box = function(cframe: CFrame, size: Vector3, options: shape.Options?)
    return shape.box(cframe, size, options).Position
  end,

  cylinder = function(cframe: CFrame, size: Vector3, options: shape.Options?)
    return shape.cylinder(cframe, size, options).Position
  end,

  sphere = function(cframe: CFrame, size: Vector3, options: shape.Options?)
    return shape.sphere(cframe, size, options).Position
  end,

  disc = function(cframe: CFrame, size: Vector3, options: shape.Options?)
    return shape.disc(cframe, size, options).Position
  end,
})

local function chainOf(points: any): { vector }
  if type(points) ~= "table" then
    logger.error(`a bezier takes a list of vectors, got {typeof(points)}`)
  end

  for i, point in points do
    if not VECTORS[typeof(point)] then
      logger.error(`a bezier's point {i} is a {typeof(point)}, not a vector`)
    end
  end

  return points
end

local Path = {}
Path.__index = Path

function Path.set(self: any, points: { vector })
  PATHS[self]:set(chainOf(points))
end

function Path.at(self: any, t: number): vector
  if t ~= t then
    return NAN_VECTOR
  end

  return PATHS[self]:at(t)
end

function Path.atUniform(self: any, u: number): vector
  if u ~= u then
    return NAN_VECTOR
  end

  return PATHS[self]:atUniform(u)
end

function Path.length(self: any): number
  return PATHS[self]:length()
end

function Path.tangent(self: any, t: number): vector
  if t ~= t then
    return NAN_VECTOR
  end

  return PATHS[self]:tangent(t)
end

table.freeze(Path)

v1.bezier = table.freeze({
  new = function(points: { vector })
    local made = table.freeze(setmetatable({}, Path))

    PATHS[made] = Bezier.new(chainOf(points))

    return made
  end,
})

table.freeze(v1)

local facade = {}

facade.sdk = v1

-- the author's emit run under the facade: a throw ends the effect, warned once
-- per module and instance, and an emit that returns keeps its effect until its
-- tweens, its nested emits and every join it made are through
function facade.run(emit: any, ctx: any, attrs: any, props: any)
  local scope = ctx.scope
  local ok, err = xpcall(emit, trace, v1, ctx, attrs, props)

  if not ok then
    if err ~= STOP then
      report(ctx, err)
    end

    return
  end

  local own = OWN[scope]

  if own == nil then
    return
  end

  while scope.state == lifetime.RUNNING do
    local waiting = if own.join ~= nil and own.join.count > 0 then own.join else nil

    if waiting == nil then
      for _, join in own.joins do
        if join.count > 0 then
          waiting = join
          break
        end
      end
    end

    if waiting == nil then
      return
    end

    lifetime.awaitJoin(waiting)
  end
end

return table.freeze(facade)
