local harness = require("@tests/harness")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect

local watch = require("@root/sdk/watch")
local custom = require("@root/sdk/custom")

local function effect(id: string, tag: string)
  return {
    sdk_version = 1,
    id = id,
    display = { name = id },
    classifier = `Folder.{tag}`,
    emit = function() end,
  }
end

-- the engine's tags as a spec drives them: what each module returns, which
-- are tagged, and the two signals fired by hand
local function host()
  local values: { [Instance]: any } = {}
  local tagged: { Instance } = {}
  local listeners = { added = {}, removed = {} }

  local function connect(kind: string)
    return function(fn: (inst: Instance) -> ())
      table.insert(listeners[kind], fn)

      return {
        Disconnect = function()
          table.remove(listeners[kind], table.find(listeners[kind], fn) :: number)
        end,
      } :: any
    end
  end

  local stand = {
    values = values,
    tagged = tagged,
    host = {
      tagged = function()
        return table.clone(tagged)
      end,
      added = connect("added"),
      removed = connect("removed"),
      require = function(module: ModuleScript)
        local value = values[module]

        if value == "throws" then
          error("Requested module experienced an error while loading")
        end

        return value
      end,
    },
  }

  function stand.fire(kind: string, inst: Instance)
    for _, fn in table.clone(listeners[kind]) do
      fn(inst)
    end
  end

  function stand.listening(): number
    return #listeners.added + #listeners.removed
  end

  return stand
end

local function module(name: string): ModuleScript
  local made = harness.make("ModuleScript") :: ModuleScript

  made.Name = name

  return made
end

local function fresh()
  watch.stop()
  registry.clear()
end

harness.suite(function()
  harness.describe("custom effect discovery", function()
    test("every module tagged at start is registered, and one tagged later as it is tagged", function()
      fresh()

      local stand = host()
      local first, later = module("First"), module("Later")

      stand.values[first] = effect("first", "First")
      stand.values[later] = effect("later", "Later")
      table.insert(stand.tagged, first)

      watch.start(stand.host)

      expect(registry.get("first") ~= nil).toBe(true)
      expect(registry.get("later")).toBe(nil)

      stand.fire("added", later)

      expect(registry.get("later") ~= nil).toBe(true)
    end)

    test("an untagged or destroyed module is unregistered", function()
      fresh()

      local stand = host()
      local inst = module("First")

      stand.values[inst] = effect("first", "First")
      table.insert(stand.tagged, inst)

      watch.start(stand.host)
      stand.fire("removed", inst)

      expect(registry.get("first")).toBe(nil)
    end)

    test("a module that fails to load or is refused is warned and registers nothing", function()
      fresh()

      local stand = host()
      local broken, refused, part = module("Broken"), module("Refused"), harness.make("Part")

      stand.values[broken] = "throws"
      stand.values[refused] = effect("refused", "Refused")
      stand.values[refused].sdk_version = 2
      table.insert(stand.tagged, broken)
      table.insert(stand.tagged, refused)
      table.insert(stand.tagged, part)

      local warnings = harness.captureWarnings(function()
        watch.start(stand.host)
      end)

      expect(#registry.list()).toBe(0)
      expect(#warnings).toBe(3)
      expect(string.find(warnings[1], "custom effect Broken failed to load", 1, true) ~= nil).toBe(true)
      expect(string.find(warnings[2], "custom effect Refused was refused: refused needs sdk 2", 1, true) ~= nil).toBe(
        true
      )
      expect(string.find(warnings[3], "Part is tagged VFXForgeEffect but is not a ModuleScript", 1, true) ~= nil).toBe(
        true
      )
    end)

    test("stop unregisters every custom effect and stops listening", function()
      fresh()

      local stand = host()
      local inst = module("First")

      stand.values[inst] = effect("first", "First")
      table.insert(stand.tagged, inst)

      watch.start(stand.host)
      watch.stop()

      expect(registry.get("first")).toBe(nil)
      expect(stand.listening()).toBe(0)
      expect(custom.get(inst)).toBe(nil)
    end)
  end)
end)
