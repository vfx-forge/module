local logger = require("@mod/logger")

export type Unit = {
  name: string,
  load: () -> any,

  -- runs once the unit is loaded while the module is live
  start: ((module: any) -> ())?,
  module: any,
  state: "pending" | "loading" | "loaded" | "failed",

  -- why it failed, which every later need is refused with
  reason: string?,

  -- declared while deferred: loaded at a need, where a failure is the unit's
  -- own, rather than where it is declared, as the require it replaced
  deferred: boolean,
  thread: thread?,
  started: boolean,
}

local lazy = {}

-- a host's hand around every load: it runs `load` and answers what it
-- answers. The plugin puts the shipped sources back for the length of one
local host: ((name: string, load: () -> any) -> any)? = nil

-- in the order they were declared, which is the order the index requires
-- the modules that declare them
local Units: { Unit } = {}
local Named: { [string]: Unit } = {}

-- off unless a host asked before the index was required: a unit then loads
-- where it is declared, at the top of the module that declares it, as its
-- requires did before there were units
local deferred = false

-- set while the module is initialized in its deferred mode: a unit loaded
-- then starts at once
local live = false

-- A UNIT THAT FAILS IS UNAVAILABLE FOR THE SESSION. Roblox keeps a
-- ModuleScript whose require threw as failed and answers every later
-- require of it with the same error, so a load tried again cannot succeed
-- there, and a start that threw has left its services half made. So a
-- failure, of the load or of the start, is said once with the effect's
-- name, and every need after it is refused with that reason, never tried
-- again in a loop on every emit
local function fail(unit: Unit, err: any)
  unit.state = "failed"
  unit.thread = nil
  unit.reason = tostring(err)

  logger.warn(`{unit.name} is unavailable for this session: {unit.reason}`)
end

local function refuse(unit: Unit)
  logger.error(`{unit.name} is unavailable for this session: {unit.reason}`)
end

local function start(unit: Unit)
  if unit.started or not live then
    return
  end

  unit.started = true

  if unit.start then
    local ok, err = pcall(unit.start, unit.module)

    if not ok then
      fail(unit, err)
      refuse(unit)
    end
  end
end

local function load(unit: Unit): any
  if unit.state == "loaded" then
    return unit.module
  end

  if unit.state == "failed" then
    refuse(unit)
  end

  if unit.state == "loading" then
    if unit.thread == coroutine.running() or not coroutine.isyieldable() then
      logger.error(`{unit.name} was needed while it loaded`)
    end

    while unit.state == "loading" do
      task.wait()
    end

    return load(unit)
  end

  unit.state = "loading"
  unit.thread = coroutine.running()

  local result

  if unit.deferred then
    local ok, loaded = pcall(function()
      return if host then host(unit.name, unit.load) else unit.load()
    end)

    if not ok then
      fail(unit, loaded)
      refuse(unit)
    end

    result = loaded
  else
    -- the default path loads where the unit is declared, as the require it
    -- replaced did, and an error there is that require's, traceback and all,
    -- unwrapped. Marked failed for its length, so a need of it after a throw
    -- is refused rather than left waiting on a load that will never end
    unit.state = "failed"
    unit.reason = "its module threw as it loaded"
    result = if host then host(unit.name, unit.load) else unit.load()
    unit.state = "loading"
    unit.reason = nil
  end

  unit.thread = nil
  unit.module = result
  unit.state = "loaded"

  start(unit)

  return result
end

-- declares a unit and answers what loads it, a getter that costs one check
-- once it has: every need of the unit goes through it or `need`
-- `alone` declares this one unit deferred whatever the mode, for a spec
function lazy.unit(name: string, loader: () -> any, starter: ((module: any) -> ())?, alone: boolean?): () -> any
  local unit: Unit = {
    name = name,
    load = loader,
    start = starter,
    module = nil,
    state = "pending",
    thread = nil,
    started = false,
    deferred = deferred or alone == true,
  }

  -- a second copy of the module that declares it (lune loads one under each
  -- path it is required by) takes the first one's place
  const was = Named[name]
  const at = if was then table.find(Units, was) else nil

  Named[name] = unit

  if at then
    Units[at] = unit
  else
    table.insert(Units, unit)
  end

  if not unit.deferred then
    load(unit)
  end

  return function()
    if unit.state == "loaded" then
      return unit.module
    end

    return load(unit)
  end
end

-- what starts a declared unit once it loads, for a declarer that cannot say
-- at the declaration (the runtime's start needs the api)
function lazy.onStart(name: string, starter: (module: any) -> ())
  local unit = Named[name]

  if unit == nil then
    logger.error(`there is no unit named {name}`)
  end

  unit.start = starter
end

-- a module whose emit plays through another module's unit
function lazy.alias(name: string, target: string)
  Named[name] = Named[target]
end

function lazy.need(name: string): any
  local unit = Named[name]

  if unit == nil then
    logger.error(`there is no unit named {name}`)
  end

  return load(unit)
end

function lazy.declared(name: string): boolean
  return Named[name] ~= nil
end

function lazy.loaded(name: string): boolean
  local unit = Named[name]

  return unit ~= nil and unit.state == "loaded"
end

-- what a unit's load answered, whether its start then ran or threw: a
-- teardown's way to what a start that failed half way had made. nil before
-- the load returns, and after a load that threw, which started nothing
function lazy.module(name: string): any
  local unit = Named[name]

  return if unit ~= nil then unit.module else nil
end

-- the reason a unit is unavailable, nil while it is not
function lazy.failed(name: string): string?
  local unit = Named[name]

  return if unit ~= nil and unit.state == "failed" then unit.reason else nil
end

-- loads one unit, `name` or else the first not yet loaded, and answers its
-- name; nil once every unit is
function lazy.prepare(name: string?): string?
  if name ~= nil then
    lazy.need(name)

    return name
  end

  for _, unit in Units do
    if unit.state == "pending" or unit.state == "loading" then
      load(unit)

      return unit.name
    end
  end

  return nil
end

-- every unit's name, in the order they were declared
function lazy.names(): { string }
  local names = {}

  for _, unit in Units do
    table.insert(names, unit.name)
  end

  return names
end

function lazy.pending(): { string }
  local names = {}

  for _, unit in Units do
    if unit.state ~= "loaded" then
      table.insert(names, unit.name)
    end
  end

  return names
end

-- the units a deferred init leaves for its host to load now: the kind of
-- every enabled instance and of what it holds, in the place's order, then
-- the runtime, whose start begins their loops and the texture preloads, when
-- anything is enabled or preloaded
-- A place's enabled effects can hold thousands of descendants (60 ms for
-- 4,000 under lune), so `step`, when given, is called every STEP_EVERY of
-- them: a host's pace step, which may wait a frame, and a true from it ends
-- the read with what it found
local STEP_EVERY = 256

function lazy.needs(
  enabled: { Instance },
  preloads: number,
  kindOf: (obj: Instance) -> string?,
  step: (() -> boolean)?
): { string }
  local names = {}
  local seen = {}
  local read = 0
  local stopped = false

  local function add(obj: Instance)
    read += 1

    if step ~= nil and read % STEP_EVERY == 0 and step() then
      stopped = true
    end

    local name = kindOf(obj)
    local unit = if name ~= nil then Named[name] else nil

    if unit == nil or seen[unit] or unit.state == "loaded" or unit.state == "failed" then
      return
    end

    seen[unit] = true
    table.insert(names, unit.name)
  end

  for _, obj in enabled do
    if stopped then
      break
    end

    add(obj)

    for _, child in obj:GetDescendants() do
      if stopped then
        break
      end

      add(child)
    end
  end

  local runtime = Named.runtime

  if (#enabled > 0 or preloads > 0) and runtime ~= nil and runtime.state ~= "loaded" then
    table.insert(names, runtime.name)
  end

  return names
end

function lazy.all()
  for _, unit in Units do
    load(unit)
  end
end

-- the lazy mode's init: what is loaded starts in declaration order, and what
-- loads from here starts as it does
function lazy.begin()
  live = true

  for _, unit in Units do
    if unit.state == "loaded" then
      start(unit)
    end
  end
end

-- deinit, after it has stopped what started: a later begin starts it again
function lazy.finish()
  live = false

  for _, unit in Units do
    unit.started = false
  end
end

-- before the index is required: every unit declared from here loads at its
-- first need, at a host's prepare or at init for what the place starts with
-- A unit declared before would have loaded where it was declared, and in
-- the release a play module compiled that early is one the host blanked:
-- deferring after any unit exists is refused, loudly
function lazy.defer(on: boolean?)
  if on ~= false and not deferred and #Units > 0 then
    logger.error(`lazy.defer came after {#Units} unit(s) were declared, the first {Units[1].name}`)
  end

  deferred = on ~= false
end

function lazy.deferred(): boolean
  return deferred
end

function lazy.setHost(fn: ((name: string, load: () -> any) -> any)?)
  host = fn
end

return lazy
