local RunService = game:GetService("RunService")

local logger = require("./logger")
local context_common = require("./common/context")
local numeric_common = require("./common/numeric")

local SERVER_CONTEXT = context_common.serverContext(
  RunService:IsServer(),
  -- an Open Cloud luau execution task runs the runtime with no `script`
  context_common.pluginContext(
    script ~= nil and script:FindFirstAncestorOfClass("Plugin") ~= nil,
    RunService:IsStudio(),
    RunService:IsRunning()
  )
)

local ATTR_CACHE_ID = "U"

type AttrCache = {
  [number]: {
    [string]: any,
  },
}

type AttrHooks = {
  [Instance]: {
    [string]: { (v: any) -> never },
  },
}

local Cache: AttrCache = {}
local Hooks: AttrHooks = {}

local LastRefId = 0

local attr = {}

-- moves on every write into a cache, so a reader keeping what it resolved
-- from one knows when that is no longer what the cache holds
attr.generation = 0

-- what caching leaves on the instance: a handle, which the engine points at a
-- clone's own copy of its target only while it is an attribute
function attr.stays(v: any)
  return typeof(v) == "InstanceHandle"
end

function attr.cache(obj: Instance)
  local prevId = obj:GetAttribute(ATTR_CACHE_ID)

  if prevId then
    logger.warn(`{obj} is already cached (id={prevId})`)
    return
  end

  local attributes = obj:GetAttributes()

  if next(attributes) == nil then
    return
  end

  LastRefId += 1

  local id = LastRefId
  local map = {}

  for k, v in attributes do
    if k == ATTR_CACHE_ID or attr.stays(v) then
      continue
    end

    map[k] = v
    obj:SetAttribute(k, nil)
  end

  Cache[id] = map
  attr.generation += 1

  obj:SetAttribute(ATTR_CACHE_ID, id)
end

function attr.restore(obj: Instance)
  local id = obj:GetAttribute(ATTR_CACHE_ID)

  local cache = Cache[id]

  if not cache then
    logger.warn(`{obj} with cache id '{id}' doesn't have any cached attributes`)
    return
  end

  for k, v in cache do
    obj:SetAttribute(k, v)
  end

  attr.generation += 1
  obj:SetAttribute(ATTR_CACHE_ID, nil)
end

function attr.get<T>(obj: Instance, key: string, default: T, soft: boolean?, validate: ((v: unknown) -> T)?): T
  local id = obj:GetAttribute(ATTR_CACHE_ID)

  local cache = Cache[id]
  local value = cache and cache[key]

  if value ~= nil then
    local resolved = if validate then validate(value) else value

    return if numeric_common.usable(resolved) then resolved else default
  end

  value = obj:GetAttribute(key)

  if validate then
    value = validate(value)
  elseif value == nil then
    value = default
  end

  -- before the write-back, so an authored value that cannot be used reads as
  -- the default without that default being written over what the author set
  if not numeric_common.usable(value) then
    value = default
  end

  if not soft and SERVER_CONTEXT then
    obj:SetAttribute(key, value)
  end

  return value
end

function attr.getRange(obj: Instance, key: string, default: NumberRange, clamp: NumberRange?, soft: boolean?)
  return attr.get(obj, key, default, soft, function(v)
    if typeof(v) ~= "NumberRange" then
      return default
    end

    if clamp then
      -- stylua: ignore
      return NumberRange.new(
        math.clamp(v.Min, clamp.Min, clamp.Max),
        math.clamp(v.Max, clamp.Min, clamp.Max)
      )
    end

    return v
  end)
end

function attr.getEnum<T>(obj: Instance, key: string, default: T, enums: { T }, soft: boolean?): T
  return attr.get(obj, key, default, soft, function(v)
    if v == nil or not table.find(enums, v) then
      return default
    end

    return v
  end)
end

function attr.set<T>(obj: Instance, key: string, value: T)
  local id = obj:GetAttribute(ATTR_CACHE_ID)

  local cache = Cache[id]

  -- a handle in the cache would never be remapped on a clone, so it goes on
  -- the instance, and a cached entry of its name would shadow it there
  if cache and attr.stays(value) then
    if cache[key] ~= nil then
      cache[key] = nil
      attr.generation += 1
    end

    obj:SetAttribute(key, value)
  elseif cache then
    cache[key] = value
    attr.generation += 1
  else
    obj:SetAttribute(key, value)
  end
end

-- the cache table an instance reads through, when it has one and carries no
-- live attribute beyond its id and what caching left: then the table is the
-- whole of what a read of a plain row sees, and every clone of the cached
-- template hands back the same one
function attr.cached(obj: Instance): { [string]: any }?
  local cache = Cache[obj:GetAttribute(ATTR_CACHE_ID)]

  if cache == nil then
    return nil
  end

  for k, v in obj:GetAttributes() do
    if k ~= ATTR_CACHE_ID and not attr.stays(v) then
      return nil
    end
  end

  return cache
end

-- the value as stored, a cached instance's entry first, with no check that it
-- is usable
function attr.raw(obj: Instance, key: string): any
  local cache = Cache[obj:GetAttribute(ATTR_CACHE_ID)]
  local value = cache and cache[key]

  if value ~= nil then
    return value
  end

  return obj:GetAttribute(key)
end

function attr.isCached(obj: Instance): boolean
  return obj:GetAttribute(ATTR_CACHE_ID) ~= nil
end

-- every attribute name the instance answers to, cached and live both and each
-- one once, so a scan over a cached instance finds what a scan over a live one
-- finds and still sees a name set on it after it was cached
function attr.keys(obj: Instance): { string }
  local id = obj:GetAttribute(ATTR_CACHE_ID)
  local cache = Cache[id]
  local keys = {}
  local seen = {}

  if cache then
    for k in cache do
      seen[k] = true

      table.insert(keys, k)
    end
  end

  for k in obj:GetAttributes() do
    if k ~= ATTR_CACHE_ID and not seen[k] then
      table.insert(keys, k)
    end
  end

  return keys
end

-- every attribute the instance answers to as one table, the cached value
-- winning over a live one of the same name, as attr.get reads them. the live
-- read already hands back a table of its own, so it is taken rather than copied
-- into a second one; the caller may still keep it past the next write
function attr.map(obj: Instance)
  local id = obj:GetAttribute(ATTR_CACHE_ID)
  local cache = Cache[id]
  local map = obj:GetAttributes()

  map[ATTR_CACHE_ID] = nil

  if cache then
    for k, v in cache do
      map[k] = v
    end
  end

  return map
end

function attr.trigger<T>(obj: Instance, key: string, value: T)
  local hooks = Hooks[obj]
  local callbacks = hooks and hooks[key]

  if not callbacks then
    return
  end

  for _, callback in callbacks do
    callback(value)
  end
end

function attr.observe<T>(obj: Instance, key: string, callback: (v: T) -> never)
  local hooks = Hooks[obj]

  if not hooks then
    hooks = {}
    Hooks[obj] = hooks
  end

  local callbacks = hooks[key]

  if not callbacks then
    callbacks = {}
    hooks[key] = callbacks
  end

  table.insert(callbacks, callback)

  local connection

  if not attr.isCached(obj) then
    connection = obj:GetAttributeChangedSignal(key):Connect(function()
      local value = obj:GetAttribute(key)
      callback(value)
    end)
  end

  return function()
    if connection then
      connection:Disconnect()
    end

    local index = table.find(callbacks, callback)

    if index then
      table.remove(callbacks, index)
    end

    if #callbacks == 0 then
      hooks[key] = nil
    end

    if next(hooks) == nil then
      Hooks[obj] = nil
    end
  end
end

return attr
