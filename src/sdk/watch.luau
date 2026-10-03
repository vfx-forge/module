local CollectionService = game:GetService("CollectionService")

local logger = require("@mod/logger")

local custom = require("@root/sdk/custom")

-- where tagged modules come from: the engine's tags, or a stand-in a spec
-- hands over
export type Host = {
  tagged: () -> { Instance },
  added: (fn: (inst: Instance) -> ()) -> RBXScriptConnection,
  removed: (fn: (inst: Instance) -> ()) -> RBXScriptConnection,
  require: (module: ModuleScript) -> any,
}

local watch = {}

watch.TAG = "VFXForgeEffect"

local connections: { RBXScriptConnection } = {}

local function engineHost(): Host
  return {
    tagged = function()
      return CollectionService:GetTagged(watch.TAG)
    end,

    added = function(fn: (inst: Instance) -> ())
      return CollectionService:GetInstanceAddedSignal(watch.TAG):Connect(fn)
    end,

    removed = function(fn: (inst: Instance) -> ())
      return CollectionService:GetInstanceRemovedSignal(watch.TAG):Connect(fn)
    end,

    require = function(module: ModuleScript)
      return (require :: any)(module)
    end,
  }
end

local function add(host: Host, inst: Instance)
  local path = inst:GetFullName()

  if not inst:IsA("ModuleScript") then
    logger.warn(`{path} is tagged {watch.TAG} but is not a ModuleScript`)
    return
  end

  local ok, value = pcall(host.require, inst :: ModuleScript)

  if not ok then
    logger.warn(`custom effect {path} failed to load: {tostring(value)}`)
    return
  end

  local took, found = custom.add(inst, value, path)

  if not took then
    logger.warn(`custom effect {path} was refused: {table.concat(found, "; ")}`)
  end
end

-- every module tagged now is required once and registered, one tagged later
-- as it is tagged, and one untagged or destroyed is unregistered
function watch.start(host: Host?)
  watch.stop()

  local from = host or engineHost()

  table.insert(
    connections,
    from.added(function(inst: Instance)
      add(from, inst)
    end)
  )

  table.insert(connections, from.removed(custom.remove))

  for _, inst in from.tagged() do
    add(from, inst)
  end
end

function watch.stop()
  for _, connection in connections do
    connection:Disconnect()
  end

  table.clear(connections)
  custom.clear()
end

return watch
