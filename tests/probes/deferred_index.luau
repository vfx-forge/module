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

local prepared = {}

for _, name in needs or {} do
  local started = os.clock()

  lazy.prepare(name)
  table.insert(prepared, { name = name, seconds = os.clock() - started })
end

local rest = os.clock()
local count = 0

while lazy.prepare() ~= nil do
  count += 1
end

print(serde.encode("json", {
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
