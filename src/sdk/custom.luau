local logger = require("@mod/logger")
local registry = require("@mod/registry")

local load = require("@root/sdk/load")
local enabled_effects = require("@srv/enabled_effects")

type Entry = { path: string, author: any, module: any }

-- what each tagged module registered, by the key its watcher names it with
local entries: { [any]: Entry } = {}

local custom = {}

local function unload(author: any, path: string)
  local fn = if type(author) == "table" then author.unload else nil

  if type(fn) ~= "function" then
    return
  end

  local ok, err = pcall(fn)

  if not ok then
    logger.warn(`{path}: unload failed: {tostring(err)}`)
  end
end

-- a version that ran its top level but was not registered is unloaded, unless
-- the very table is one that is registered, as a cached require answers
local function discard(author: any, path: string)
  for _, entry in entries do
    if entry.author == author then
      return
    end
  end

  unload(author, path)
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
-- refusal leaves the earlier version registered and unloads the refused one.
-- `alias` is the name the module's source ran under when that is not `path`,
-- as a plugin's hidden clone, which a failure it reports names as `path`
function custom.add(key: any, author: any, path: string, alias: string?): (boolean, { string })
  local previous = entries[key]
  local module, found = load.assemble(author, path, if previous ~= nil then previous.module else nil, alias)

  if module == nil then
    discard(author, path)
    return false, found
  end

  local holder = registry.get(module.id)

  if holder ~= nil and (previous == nil or holder ~= previous.module) then
    local other = holderOf(holder)

    discard(author, path)

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

  registry.register(module, true)

  entries[key] = { path = path, author = author, module = module }

  if previous ~= nil then
    unload(previous.author, previous.path)
  end

  enabled_effects.resync()

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
  unload(entry.author, entry.path)
  enabled_effects.resync()
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
