local RunService = game:GetService("RunService")

local logger = require("./logger")
local context_common = require("./common/context")
local numeric_common = require("./common/numeric")

local SERVER_CONTEXT = context_common.serverContext(
  RunService:IsServer(),
  context_common.pluginContext(
    script:FindFirstAncestorOfClass("Plugin") ~= nil,
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

type RuntimeState = {
  [Instance]: {
    [string]: any,
  },
}

local Cache: AttrCache = {}
local Hooks: AttrHooks = {}
local State: RuntimeState = {}

local LastRefId = 0

local attr = {}

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
    if k == ATTR_CACHE_ID then
      continue
    end

    map[k] = v
    obj:SetAttribute(k, nil)
  end

  Cache[id] = map

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

  if cache then
    cache[key] = value
  else
    obj:SetAttribute(key, value)
  end
end

function attr.isCached(obj: Instance): boolean
  return obj:GetAttribute(ATTR_CACHE_ID) ~= nil
end

-- every attribute name the instance answers to, cached or live, so a scan
-- over a cached template finds what a scan over a live one finds
function attr.keys(obj: Instance): { string }
  local id = obj:GetAttribute(ATTR_CACHE_ID)
  local cache = Cache[id]
  local keys = {}

  if cache then
    for k in cache do
      table.insert(keys, k)
    end

    return keys
  end

  for k in obj:GetAttributes() do
    if k ~= ATTR_CACHE_ID then
      table.insert(keys, k)
    end
  end

  return keys
end

function attr.getState<T>(obj: Instance, key: string, default: T): T
  local state = State[obj]
  local value = state and state[key]

  return if value ~= nil then value else default
end

function attr.setState<T>(obj: Instance, key: string, value: T)
  local state = State[obj]

  if not state then
    state = {}
    State[obj] = state
  end

  state[key] = value
end

function attr.clearState(obj: Instance)
  State[obj] = nil
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

function attr.hook<T>(obj: Instance, key: string, callback: (v: T) -> never)
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
