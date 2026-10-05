local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local mod = require("@mod/mod")
local knob = require("@mod/knob")
local lerp = require("@mod/lerp")
local curve = require("@mod/curve")
local shape = require("@mod/shape")
local tween = require("@mod/tween")
local curves = require("@mod/curves")
local logger = require("@mod/logger")
local adapters = require("@mod/adapters")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")

local color = require("@mod/color/color")

local Bezier = require("@obj/Bezier")

local NAN = 0 / 0
local NAN_VECTOR = vector.create(NAN, NAN, NAN)

-- an author's pass by name, as the scheduler's phase
local PASSES = { early = "compute", late = "screen" }

-- the folder every custom effect's guis live in, by name
local GUI_ROOT = "VFXForgeGui"

-- thrown through an effect's own thread once a callback of it has failed, so
-- the author's code after the failing call never runs on an effect that is gone
local STOP = table.freeze({})

-- what an emit waits for once the author's emit returns: the tweens and nested
-- emits counted into its own join, and every join the author made
local OWN: { [lifetime.effect]: lifetime.join } = setmetatable({}, { __mode = "k" }) :: any
local MADE: { [lifetime.effect]: { lifetime.join } } = setmetatable({}, { __mode = "k" }) :: any

-- per module, the instances a failure was already reported for
local WARNED: { [any]: { [Instance]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

-- per module, the texts sdk.warn already logged for each instance, kept apart
-- from WARNED so a warning never silences a failure
local NOTED: { [any]: { [Instance]: { [string]: boolean } } } = setmetatable({}, { __mode = "k" }) :: any

-- the effects whose emit already holds its instance's lock
local LOCKED: { [lifetime.effect]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- per module, the name its source runs under where that is not where it lives,
-- as a plugin's hidden clone of a module edited in Studio, and that real path
local ALIASES: { [any]: { from: string, to: string } } = setmetatable({}, { __mode = "k" }) :: any

-- the threads of the pieces an author spawned, and the effect each belongs to
local PIECES: { [thread]: lifetime.effect } = setmetatable({}, { __mode = "k" }) :: any

local JOINS: { [any]: { join: lifetime.join, ctx: any } } = setmetatable({}, { __mode = "k" }) :: any
local PATHS: { [any]: Bezier.Bezier } = setmetatable({}, { __mode = "k" }) :: any

-- the writers whose refused write was already warned about
local REFUSED: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- the lifetime writer behind each handle, which the handle itself never holds
local WRITERS: { [any]: lifetime.writer } = setmetatable({}, { __mode = "k" }) :: any

-- what an author is handed of each ctx, and the ctx behind each view, which
-- never leaves the facade
local VIEWS: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
local CTXS: { [any]: any } = setmetatable({}, { __mode = "kv" }) :: any

-- the rules already handed views, so a rule is never wrapped twice
local RULES: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- the reader's Track behind each view an author is handed, and the view of
-- each Track, so one Track is always one view
local TRACKS: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
local VIEWED: { [any]: any } = setmetatable({}, { __mode = "kv" }) :: any

-- the read only window an author is handed of each attrs or props table the
-- reader filled, and the table behind each window
local READS: { [any]: any } = setmetatable({}, { __mode = "kv" }) :: any
local SOURCES: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

-- a host's sentence for a reported failure, which only the plugin sets
local annotate: ((message: string) -> string?)? = nil

-- the gui root last made or found, made again once it leaves its parent
local guiRoot: Instance? = nil

-- what every curve the facade makes is, told apart from any other table by it
local CURVE = getmetatable(curve.new(1, "linear"))

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

local Track = {}
Track.__index = Track

function Track.at(self: any, t: number)
  local inner = TRACKS[self]

  if inner == nil then
    logger.error("call track:at(t), not track.at(t)")
  end

  return inner.at(t)
end

table.freeze(Track)

-- the reader's Track, told apart from an author's table by the lane reads only
-- it answers
local function isTrack(value: any): boolean
  return type(value) == "table" and type(value.at) == "function" and type(value.reach) == "function"
end

local function viewOfTrack(inner: any)
  local view = VIEWED[inner]

  if view ~= nil then
    return view
  end

  view = table.freeze(setmetatable({
    value = inner.value,
    animated = inner.animated,
    duration = inner.duration,
  }, Track))

  VIEWED[inner] = view
  TRACKS[view] = inner

  return view
end

local function shown(value: any)
  return if isTrack(value) then viewOfTrack(value) else value
end

-- a read only window on a table the reader fills, every Track in it a view.
-- read through on every access, so a rule called halfway through a read sees
-- each row as it resolves
local Read = {}

-- a copy of a window carries its metatable but none of the reader's table
local function sourceOf(window: any)
  local read = SOURCES[window]

  if read == nil then
    logger.error("attrs and props are read only windows; read them directly, do not copy them")
  end

  return read
end

function Read.__index(window: any, key: any)
  return shown(sourceOf(window)[key])
end

function Read.__iter(window: any)
  local read = sourceOf(window)
  local key = nil

  return function()
    local value

    key, value = next(read, key)

    if key == nil then
      return nil
    end

    return key, shown(value)
  end
end

table.freeze(Read)

local function authored(read: any)
  if type(read) ~= "table" then
    return read
  end

  local window = READS[read]

  if window ~= nil then
    return window
  end

  window = setmetatable({}, Read)
  SOURCES[window] = read
  READS[read] = window

  return table.freeze(window)
end

local v1 = {}

-- the typed fields of a ctx and nothing else, built once per emit and again
-- only when the duration a read decided after it was built moves
local function viewOf(ctx: any)
  local view = VIEWS[ctx]

  if view ~= nil and view.duration == ctx.duration then
    return view
  end

  view = table.freeze({ ref = ctx.ref, duration = ctx.duration, constant = ctx.constant })
  VIEWS[ctx] = view
  CTXS[view] = ctx

  return view
end

local function ctxOf(view: any, name: string)
  local ctx = CTXS[view]

  if ctx == nil or type(ctx.scope) ~= "table" then
    logger.error(`sdk.{name} takes the ctx your emit was handed`)
  end

  return ctx
end

local function scopeOf(view: any, name: string): lifetime.effect
  return ctxOf(view, name).scope
end

-- an engine function runs with the rights of whoever calls it, and the
-- runtime would call it with its host's, so only the author's own is taken
local function callable(fn: any, name: string)
  if type(fn) ~= "function" then
    logger.error(`sdk.{name} takes a function, got {typeof(fn)}`)
  end

  if debug.info(fn, "s") == "[C]" then
    logger.error(`sdk.{name} takes a function of your own, not an engine function; wrap the call in one`)
  end
end

local function yielding(name: string)
  if scheduler.inPass() then
    logger.error(`sdk.{name} yields, so it cannot run inside a step or a tween's callback; start it in sdk.spawn`)
  end
end

local function joinOf(scope: lifetime.effect): lifetime.join
  local join = OWN[scope]

  if join == nil then
    join = lifetime.join(scope)
    OWN[scope] = join
  end

  return join
end

-- every plain occurrence of `from` in `text` spelled `to`, but for one that
-- runs on into a longer name, as `Fade_3` does into `Fade_31`
local function renamed(text: string, from: string, to: string)
  local out = {}
  local at = 1

  while true do
    local first, last = string.find(text, from, at, true)

    if first == nil then
      break
    end

    local whole = string.find(text, "^[%w_]", last + 1) == nil

    table.insert(out, string.sub(text, at, first - 1))
    table.insert(out, if whole then to else from)
    at = last + 1
  end

  table.insert(out, string.sub(text, at))

  return table.concat(out)
end

-- the host's sentence after the failure's first line, ahead of its traceback
local function annotated(text: string): string
  local ok, sentence = pcall(annotate :: any, text)

  if not ok or type(sentence) ~= "string" then
    return text
  end

  local first, rest = string.match(text, "^([^\n]*)(.*)$")
  local stop = if string.sub(first :: string, -1) == "." then " " else ". "

  return `{first}{stop}{sentence}{rest}`
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
    local text = tostring(err)
    local alias = ALIASES[module]

    if alias ~= nil then
      text = renamed(text, alias.from, alias.to)
    end

    if annotate ~= nil then
      text = annotated(text)
    end

    logger.warn(`custom effect {id} failed on {ctx.ref:GetFullName()}: {text}`)
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

function v1.wait(view: any, seconds: number): number
  local scope = scopeOf(view, "wait")

  yielding("wait")

  if type(seconds) ~= "number" then
    logger.error(`sdk.wait takes a number of seconds, got {typeof(seconds)}`)
  end

  return lifetime.wait(scope, seconds)
end

function v1.step(view: any, fn: (dt: number, elapsed: number) -> (), pass: string?)
  local ctx = ctxOf(view, "step")
  local scope = ctx.scope

  callable(fn, "step")

  local phase = PASSES[if pass == nil then "early" else pass]

  if phase == nil then
    logger.error(`sdk.step's pass is "early" or "late", got {tostring(pass)}`)
  end

  local elapsed = 0

  local handle = lifetime.step(scope, function(deltaTime: number)
    elapsed += deltaTime
    guarded(ctx, fn, deltaTime, elapsed)
  end, phase)

  return function()
    handle:Disconnect()
  end
end

-- a preset's name, a curve row's value, a chain of vectors or a function of
-- time, as the shape the internal curve takes
local function shapeOf(given: any): any
  local kind = typeof(given)

  if kind == "string" then
    -- a curve row's value is binary and starts with four zero bytes, so any
    -- other text is meant as a preset
    if curves.PRESETS[given] == nil and string.sub(given, 1, 4) ~= "\0\0\0\0" then
      logger.error(`{given} is no curve preset, use linear, easeIn, easeOut or easeInOut`)
    end

    return given
  end

  if kind == "buffer" then
    return buffer.tostring(given)
  end

  if kind == "function" then
    callable(given, "curve")

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

  return table.freeze(curve.new(duration, shapeOf(given)))
end

function v1.tween(view: any, eased: any, fn: (alpha: number) -> ())
  local ctx = ctxOf(view, "tween")
  local scope = ctx.scope

  if getmetatable(eased) ~= CURVE or not table.isfrozen(eased) then
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

function v1.hold<T>(view: any, thing: T): T
  local scope = scopeOf(view, "hold")

  if not HOLDABLE[typeof(thing)] then
    logger.error(`sdk.hold takes an instance, a connection, a function or a thread, got {typeof(thing)}`)
  end

  if type(thing) == "function" then
    callable(thing, "hold")
  end

  return lifetime.hold(scope, thing)
end

function v1.join(view: any)
  local ctx = ctxOf(view, "join")
  local scope = ctx.scope
  local join = lifetime.join(scope)
  local token = table.freeze({})
  local made = MADE[scope]

  if made == nil then
    MADE[scope] = { join }
  else
    table.insert(made, join)
  end

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

function v1.emit(view: any, instance: Instance)
  local scope = scopeOf(view, "emit")

  if typeof(instance) ~= "Instance" then
    logger.error(`sdk.emit takes an instance, got {typeof(instance)}`)
  end

  scope.effects.emitInstance(instance, scope.depth + 1, scope, joinOf(scope))
end

local Writer = {}
Writer.__index = Writer

function Writer.set(self: any, value: any)
  local w = WRITERS[self]

  if lifetime.set(w, value) or REFUSED[self] then
    return
  end

  REFUSED[self] = true

  logger.warn(`a {typeof(value)} could not be written to {w.name} of {w.obj:GetFullName()}`)
end

table.freeze(Writer)

local function writerOf(view: any, obj: Instance, source: string, name: string, call: string)
  local scope = scopeOf(view, call)

  if typeof(obj) ~= "Instance" then
    logger.error(`sdk.{call} writes to an instance, got {typeof(obj)}`)
  end

  if type(name) ~= "string" then
    logger.error(`sdk.{call} takes the name it writes to, got {typeof(name)}`)
  end

  local made = table.freeze(setmetatable({}, Writer))

  WRITERS[made] = lifetime.write(scope, obj, source, name)

  return made
end

function v1.getWriter(view: any, obj: Instance, property: string)
  return writerOf(view, obj, "property", property, "getWriter")
end

function v1.getAttributeWriter(view: any, obj: Instance, name: string)
  return writerOf(view, obj, "attribute", name, "getAttributeWriter")
end

function v1.speed(view: any, track: any)
  local scope = scopeOf(view, "speed")
  local inner = TRACKS[track]

  if inner == nil then
    logger.error("sdk.speed takes a param declared with :mod(), as attrs hands it")
  end

  lifetime.speed(scope, inner)
end

function v1.apply(view: any, given: any, write: (value: any) -> ())
  local ctx = ctxOf(view, "apply")

  callable(write, "apply")

  local function written(value: any)
    guarded(ctx, write, value)
  end

  local inner = TRACKS[given]

  -- a row its modifiers move keeps the effect until it lands, as a tween does
  if inner ~= nil then
    inner:apply(written, if inner.animated then lifetime.add(joinOf(ctx.scope)) else nil)
    return
  end

  -- no row's value is a Lua table, so one that is no view is a mistake
  if type(given) == "table" then
    logger.error("sdk.apply takes a param's value, as attrs hands it")
  end

  written(given)
end

function v1.warn(view: any, text: string)
  local ctx = ctxOf(view, "warn")

  if type(text) ~= "string" then
    logger.error(`sdk.warn takes a string, got {typeof(text)}`)
  end

  local module = ctx.effect
  local byRef = NOTED[module]

  if byRef == nil then
    byRef = setmetatable({}, { __mode = "k" }) :: any
    NOTED[module] = byRef
  end

  local texts = byRef[ctx.ref]

  if texts == nil then
    texts = {}
    byRef[ctx.ref] = texts
  end

  if texts[text] then
    return
  end

  texts[text] = true

  local id = if module ~= nil then module.id else "?"

  logger.warn(`custom effect {id} on {ctx.ref:GetFullName()}: {text}`)
end

function v1.lock(view: any)
  local ctx = ctxOf(view, "lock")
  local scope = ctx.scope

  if coroutine.running() ~= scope.thread then
    logger.error("sdk.lock runs in emit only, not in a step, a tween's callback or a piece")
  end

  if LOCKED[scope] then
    return
  end

  -- another emit plays this instance: this one ends here, silently
  if lifetime.lock(scope, ctx.ref) then
    error(STOP, 0)
  end

  LOCKED[scope] = true
end

function v1.context(): string
  if not RunService:IsRunning() then
    return "edit"
  end

  return if RunService:IsClient() then "client" else "server"
end

-- the parent the gui root belongs under in this context, refusing the server
local function guiParent(): Instance
  if not RunService:IsRunning() then
    return StarterGui
  end

  if not RunService:IsClient() then
    logger.error("sdk.guiRoot runs in the editor or on a client; check sdk.context() first")
  end

  local player = Players.LocalPlayer
  local gui = if player ~= nil then player:FindFirstChildOfClass("PlayerGui") else nil

  if gui == nil then
    logger.error("sdk.guiRoot found no PlayerGui; the local player has not loaded yet")
  end

  return gui :: Instance
end

function v1.guiRoot(view: any): Instance
  ctxOf(view, "guiRoot")

  local parent = guiParent()
  local root = guiRoot

  if root ~= nil and root.Parent == parent then
    return root
  end

  root = nil

  for _, child in parent:GetChildren() do
    if child.Name == GUI_ROOT and child:IsA("Folder") and not child.Archivable then
      root = child
      break
    end
  end

  if root == nil then
    local made = adapters.create("Folder")

    made.Name = GUI_ROOT
    made.Archivable = false
    made.Parent = parent
    root = made
  end

  guiRoot = root

  return root :: Instance
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

-- a module whose source runs under the name `from` reports its failures
-- naming `to`, the path it really lives at
function facade.alias(module: any, from: string, to: string)
  if from == "" then
    return
  end

  ALIASES[module] = { from = from, to = to }
end

-- the sentence a host adds to every failure it reports, nil for none
function facade.annotate(fn: ((message: string) -> string?)?)
  annotate = fn
end

-- every custom effect still playing ended as a failure ends one
function facade.kill()
  for ctx in table.clone(VIEWS) do
    local scope = ctx.scope

    if type(scope) == "table" and scope.state == lifetime.RUNNING then
      lifetime.kill(scope)
    end
  end
end

-- an author's rule, called by the reader with the runtime's ctx and handed
-- the view of it instead
function facade.rule(fn: (...any) -> any)
  if RULES[fn] then
    return fn
  end

  local wrapped = function(ctx: any, attrs: any, props: any)
    return fn(if ctx ~= nil then viewOf(ctx) else nil, authored(attrs), authored(props))
  end

  RULES[wrapped] = true

  return wrapped
end

-- an author's duration, called by the reader and handed the author's reads
function facade.duration(fn: (...any) -> any)
  return function(_, attrs: any, props: any)
    return fn(v1, authored(attrs), authored(props))
  end
end

-- an author's template, which a host calls and the runtime never does. it is
-- handed the sdk alone, and a failure that names the clone it ran as names the
-- module's path instead
function facade.template(fn: (sdk: any) -> any, from: string?, to: string)
  return function()
    local ok, made = pcall(fn, v1)

    if ok then
      return made
    end

    local text = tostring(made)

    if from ~= nil and from ~= "" then
      text = renamed(text, from, to)
    end

    -- the author's own failure passed on as it came, with no prefix of ours
    error(text, 0)
  end
end

-- the author's emit run under the facade: a throw ends the effect, warned once
-- per module and instance, and an emit that returns keeps its effect until its
-- tweens, its nested emits and every join it made are through
function facade.run(emit: any, ctx: any, attrs: any, props: any)
  local scope = ctx.scope
  local ok, err = xpcall(emit, trace, v1, viewOf(ctx), authored(attrs), authored(props))

  if not ok then
    if err ~= STOP then
      report(ctx, err)
    end

    return
  end

  while scope.state == lifetime.RUNNING do
    local own = OWN[scope]
    local waiting = if own ~= nil and own.count > 0 then own else nil

    if waiting == nil then
      for _, join in MADE[scope] or {} do
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
