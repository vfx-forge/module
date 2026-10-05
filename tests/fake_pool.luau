local pool = require("@srv/pool")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")

export type Fake = {
  engine: any,
  folder: Instance,
  scope: { any },
  settled: { Instance },
  made: number,
  wrappers: { [string]: Instance },
  stable: (inst: Instance) -> Instance,
  changed: { [Instance]: () -> () }?,
  dirty: { [Instance]: () -> () }?,
  destroyed: { [Instance]: () -> () }?,
}

local ENGINE = pool.engine

local fake_pool = {}

-- the pool on an engine with no signals, which a spec fires itself, answering
-- each class with the properties `lists` names for it
function fake_pool.start(lists: { [string]: { string } }): Fake
  local fake = { settled = {}, made = 0, scope = {}, wrappers = {} } :: any
  local folder = harness.make("Folder")

  -- lune hands out a fresh wrapper for an instance on every walk, so a walk
  -- answers the first wrapper seen for each, which is what a map keyed by
  -- instance finds in Studio
  local function canonical(inst: Instance): Instance
    local id = inst:GetDebugId()
    local first = fake.wrappers[id]

    if first == nil then
      first = inst
      fake.wrappers[id] = inst
    end

    return first
  end

  fake.folder = folder
  fake.stable = canonical
  fake.engine = {
    folder = function()
      return folder
    end,
    fromExisting = function(source: Instance)
      fake.made += 1

      local copy = source:Clone()
      copy:ClearAllChildren()

      return canonical(copy)
    end,
    -- lune knows no CollisionFidelity or MeshContent, so a mesh is all a spec
    -- tells apart, and a spec's empty one stands for content no key can name
    mesh = function(part: Instance)
      local id = (part :: MeshPart).MeshId

      return if id == "" then nil else id
    end,
    properties = function(class: string)
      return lists[class]
    end,
    watch = function(template: Instance, changed: () -> ())
      fake.changed = fake.changed or {}
      fake.changed[template] = changed

      return {}
    end,
    listen = function(inst: Instance, changed: () -> ())
      fake.dirty = fake.dirty or {}
      fake.dirty[inst] = changed

      return { Disconnect = function() end }
    end,
    children = function(inst: Instance)
      local list = {}

      for _, child in inst:GetChildren() do
        table.insert(list, canonical(child))
      end

      return list
    end,
    destroying = function(inst: Instance, fn: () -> ())
      fake.destroyed = fake.destroyed or {}
      fake.destroyed[inst] = fn

      return { Disconnect = function() end }
    end,
    settle = function(inst: Instance)
      table.insert(fake.settled, inst)
    end,
  }

  pool.engine = fake.engine
  pool.init(fake.scope)

  return fake
end

function fake_pool.stop(fake: Fake)
  lifetime.releasePlain(fake.scope)
  pool.engine = ENGINE
end

return fake_pool
