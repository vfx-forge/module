-- run in a process of its own by lazy.spec, since deferring is decided once,
-- before the index is required: what a deferred index loads, and what its
-- init answers for a place holding an enabled beam
local serde = require("@lune/serde")
local process = require("@lune/process")
local harness = require("@tests/harness")

local lazy = require("@mod/lazy")
local utility = require("@mod/utility")

local deferring = process.args[1] ~= "default"

-- the global the index files its api in, which lune does not have
-- selene: allow(unscoped_variables)
shared = {}

-- the runtime's services stand in for themselves: lune has no engine to make
-- their folders in, and what matters here is when and in which order they
-- start, which each one's init records
local started = {}

for _, name in { "pool", "effects", "frame_store", "texture_loader", "enabled_effects" } do
  local service = require(`@srv/{name}`) :: any

  service.init = function()
    table.insert(started, name)

    if process.args[1] == "runtimefail" and name == "enabled_effects" then
      error("the loops would not start")
    end
  end
end

-- what the index's deinit tears down of the runtime, in the order it does
local torn = {}

for _, teardown in { { "effects", "deinit" }, { "enabled_effects", "clear" }, { "mover", "clear" } } do
  local service = require(`@srv/{teardown[1]}`) :: any

  service[teardown[2]] = function()
    table.insert(torn, `{teardown[1]}.{teardown[2]}`)
  end
end

lazy.defer(deferring)

local at = os.clock()
local vfx = require("@root") :: any
local required = os.clock() - at

local beam = harness.make("Beam")
local tags = game:GetService("CollectionService") :: any

tags.GetTagged = function(_, tag: string)
  return if tag == utility.ENABLED_VFX_TAG then { beam } else {}
end

-- a host that loads the runtime ahead of init
if process.args[1] == "early" then
  lazy.prepare("runtime")
end

local before = lazy.pending()
local startedBeforeInit = table.clone(started)
local needs = vfx.init({ discover = false })
local after = lazy.pending()
local startedAtInit = table.clone(started)

-- an animator's rows read with no emit, as a card or the emit window reads
-- them: what the plugin does on a selection
local reader = require("@mod/reader")
local animatorRay = harness.make("RayValue")
local animatorModule = vfx.effects.get("animator")

reader.resolve(animatorModule, { ref = animatorRay, obj = animatorRay, effect = animatorModule })

local animatorReadLoaded = lazy.loaded("animator")

-- a unit whose start throws, needed once the loader is live
local startFail = nil

if process.args[1] == "startfail" then
  local starts = 0
  local get = lazy.unit("probe_start_fails", function()
    return {}
  end, function()
    starts += 1

    error("the pool would not start")
  end)

  local first = pcall(get)
  local second = pcall(get)

  startFail = { first = first, second = second, starts = starts, failed = lazy.failed("probe_start_fails") ~= nil }
end

local prepared = {}

for _, name in needs or {} do
  local started = os.clock()

  if process.args[1] == "runtimefail" then
    pcall(lazy.prepare, name)
  else
    lazy.prepare(name)
  end

  table.insert(prepared, { name = name, seconds = os.clock() - started })
end

-- a runtime whose start threw half way, torn down at unload
local runtimeFail = nil

if process.args[1] == "runtimefail" then
  local failed = lazy.failed("runtime") ~= nil

  vfx.deinit()
  runtimeFail = { failed = failed, torn = torn }
end

local rest = os.clock()
local count = 0

while process.args[1] ~= "runtimefail" and lazy.prepare() ~= nil do
  count += 1
end

print(serde.encode("json", {
  startFail = startFail,
  runtimeFail = runtimeFail,
  animatorReadLoaded = animatorReadLoaded,
  required = required,
  before = before,
  needs = needs,
  after = after,
  prepared = prepared,
  rest = os.clock() - rest,
  units = count,
  startedBeforeInit = startedBeforeInit,
  startedAtInit = startedAtInit,
  started = started,
}))
