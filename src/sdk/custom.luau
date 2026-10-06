local logger = require("@mod/logger")
local registry = require("@mod/registry")

local load = require("@root/sdk/load")
local enabled_effects = require("@srv/enabled_effects")

type Entry = { path: string, author: any, module: any, unload: (() -> ())? }

-- what each tagged module registered, by the key its watcher names it with
local entries: { [any]: Entry } = {}

local custom = {}

-- the unload load read off the module, never read off the author's table
-- again, whose metatable could otherwise run on the host's thread
local function unload(fn: (() -> ())?, path: string)
  if fn == nil then
    return
  end

  local ok, err = pcall(fn)

  if not ok then
    logger.warn(`{path}: unload failed: {tostring(err)}`)
  end
end

-- a version that ran its top level but was not registered is unloaded, unless
-- the very table is one that is registered, as a cached require answers
local function discard(author: any, path: string, fn: (() -> ())?)
  for _, entry in entries do
    if rawequal(entry.author, author) then
      return
    end
  end

  unload(fn, path)
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
  local module, found, fn = load.assemble(author, path, if previous ~= nil then previous.module else nil, alias)

  if module == nil then
    discard(author, path, fn)
    return false, found
  end

  local holder = registry.get(module.id)

  if holder ~= nil and (previous == nil or holder ~= previous.module) then
    local other = holderOf(holder)

    discard(author, path, fn)

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

  entries[key] = { path = path, author = author, module = module, unload = fn }

  if previous ~= nil then
    unload(previous.unload, previous.path)
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
  unload(entry.unload, entry.path)
  enabled_effects.resync()
end

function custom.clear()
  for key in entries do
    custom.remove(key)
  end
end

-- a host's sentence added to every failure a custom effect reports, as the
-- plugin says what its sandbox refused. nil takes it away, and the game never
-- sets one, so there a failure reads as the engine wrote it
function custom.annotate(fn: ((message: string) -> string?)?)
  for _, facade in load.VERSIONS do
    facade.annotate(fn)
  end
end

-- every custom effect still playing ended now, letting go of what it held, as
-- when a host takes from custom effects what they could do when they started
function custom.kill()
  for _, facade in load.VERSIONS do
    facade.kill()
  end
end

-- the module `key` registered, or nil
function custom.get(key: any): any?
  local entry = entries[key]

  return if entry ~= nil then entry.module else nil
end

return custom
