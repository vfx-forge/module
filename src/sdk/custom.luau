local logger = require("@mod/logger")
local registry = require("@mod/registry")

local load = require("@root/sdk/load")

type Entry = { path: string, author: any, module: any }

-- what each tagged module registered, by the key its watcher names it with
local entries: { [any]: Entry } = {}

local custom = {}

local function unload(entry: Entry)
  local fn = entry.author.unload

  if type(fn) ~= "function" then
    return
  end

  local ok, err = pcall(fn)

  if not ok then
    logger.warn(`{entry.path}: unload failed: {tostring(err)}`)
  end
end

local function holderOf(module: any): Entry?
  for _, entry in entries do
    if entry.module == module then
      return entry
    end
  end

  return nil
end

-- registers what a tagged module returned under `key`, replacing what that key
-- registered before. answers whether it took and every reason it did not; a
-- refusal leaves the earlier version registered
function custom.add(key: any, author: any, path: string): (boolean, { string })
  local previous = entries[key]
  local module, found = load.assemble(author, path, if previous ~= nil then previous.module else nil)

  if module == nil then
    return false, found
  end

  local holder = registry.get(module.id)

  if holder ~= nil and (previous == nil or holder ~= previous.module) then
    local other = holderOf(holder)

    return false,
      {
        if other ~= nil
          then `the id {module.id} is already claimed by {other.path}`
          else `{module.id} is a built-in effect's id`,
      }
  end

  if previous ~= nil then
    registry.unregister(previous.module)
  end

  registry.register(module)

  entries[key] = { path = path, author = author, module = module }

  if previous ~= nil then
    unload(previous)
  end

  return true, found
end

-- what `key` registered is taken out and its unload called. emits already
-- playing it finish on the version they started with
function custom.remove(key: any)
  local entry = entries[key]

  if entry == nil then
    return
  end

  entries[key] = nil
  registry.unregister(entry.module)
  unload(entry)
end

function custom.clear()
  for key in entries do
    custom.remove(key)
  end
end

-- the module `key` registered, or nil
function custom.get(key: any): any?
  local entry = entries[key]

  return if entry ~= nil then entry.module else nil
end

return custom
