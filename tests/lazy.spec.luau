local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local lazy = require("@mod/lazy")
local harness = require("@tests/harness")
local registry = require("@mod/registry")
local lifetime = require("@mod/lifetime")
local test, expect = harness.test, harness.expect

-- the order init starts the runtime's services in, deferred or not
local SERVICES = { "pool", "effects", "frame_store", "texture_loader", "enabled_effects" }

-- deferring is decided once, before the index is required, so each mode
-- runs in a process of its own
local function probe(mode: string): any
  local result = process.exec("lune", { "run", "tests/probes/deferred_index", mode })

  assert(result.ok, `the probe failed: {result.stderr}`)

  local lines = string.split(string.gsub(result.stdout, "\n+$", ""), "\n")

  return serde.decode("json", lines[#lines])
end

-- a unit declared deferred under a name of the spec's own, which the units
-- the index declares never take
local count = 0

local function deferred(load: () -> any, start: ((module: any) -> ())?): (string, () -> any)
  count += 1

  local name = `spec_unit_{count}`

  local ok, get = pcall(lazy.unit, name, load, start, true)

  assert(ok, get)

  return name, get
end

local function walk(dir: string, out: { string })
  for _, entry in fs.readDir(dir) do
    local path = `{dir}/{entry}`

    if fs.isDir(path) then
      walk(path, out)
    elseif string.match(entry, "%.luau$") then
      table.insert(out, path)
    end
  end

  return out
end

harness.suite(function()
  harness.describe("the units, by default", function()
    test("every built-in's unit loads as the index is required, and init starts the runtime itself", function()
      local result = probe("default")

      expect(#result.before).toBe(0)
      expect(result.needs).toBe(nil)
      expect(result.startedAtInit).toEqual(SERVICES)
    end)

    test("a load that throws raises its own error where the unit is declared, as the require it replaced", function()
      local ok, err = pcall(lazy.unit, "spec_unit_default_throws", function()
        error("the module did not compile", 0)
      end)

      expect(ok).toBe(false)
      expect(err).toBe("the module did not compile")
      expect(lazy.failed("spec_unit_default_throws") ~= nil).toBe(true)
    end)

    test("every unit the index declares is loaded once it is required", function()
      -- the index registers every built-in as it loads, which a registry
      -- another spec filled refuses
      registry.clear()
      require("@root")
      registry.clear()

      local pending = {}

      for _, name in lazy.pending() do
        if string.sub(name, 1, 10) ~= "spec_unit_" then
          table.insert(pending, name)
        end
      end

      expect(pending).toEqual({})
      expect(lazy.declared("forge_mesh") and lazy.declared("runtime")).toBe(true)
    end)
  end)

  harness.describe("deferring", function()
    test("is refused once a unit is declared, since that one loaded where it was declared", function()
      registry.clear()
      require("@root")
      registry.clear()

      expect(function()
        lazy.defer()
      end).toThrow()
      expect(lazy.deferred()).toBe(false)
    end)
  end)

  harness.describe("the units, deferred", function()
    test("the index and its init load nothing, and init answers what an enabled beam needs", function()
      local result = probe("deferred")

      expect(table.find(result.before, "forge_mesh") ~= nil).toBe(true)
      expect(table.find(result.before, "runtime") ~= nil).toBe(true)
      expect(result.after).toEqual(result.before)
      expect(result.needs).toEqual({ "beam", "runtime" })
      expect(#result.startedAtInit).toBe(0)
      expect(result.started).toEqual(SERVICES)
    end)

    test("a unit loads at its first need and once", function()
      local loads = 0

      local name, get = deferred(function()
        loads += 1

        return { value = 1 }
      end)

      expect(lazy.loaded(name)).toBe(false)
      expect(get().value).toBe(1)
      expect(lazy.need(name)).toBe(get())
      expect(loads).toBe(1)
    end)

    test("a second need while a load waits takes the same module, and the load runs once", function()
      local loads = 0

      local name, get = deferred(function()
        loads += 1
        task.wait()

        return { value = 2 }
      end)

      local first, second

      task.spawn(function()
        first = get()
      end)

      task.spawn(function()
        second = lazy.need(name)
      end)

      expect(first).toBe(nil)

      for _ = 1, 10 do
        if first ~= nil and second ~= nil then
          break
        end

        task.wait()
      end

      expect(loads).toBe(1)
      expect(first ~= nil and first == second).toBe(true)
    end)

    test("a unit its own load needs is refused rather than handed back half made", function()
      local name: string
      local inner = nil

      name = deferred(function()
        inner = pcall(lazy.need, name)

        return {}
      end)

      lazy.need(name)

      expect(inner).toBe(false)
    end)

    -- Roblox answers a ModuleScript whose require threw with the same error
    -- for the session, so a load tried again cannot succeed there
    test("a load that throws makes the unit unavailable: said once, and every later need refused with why", function()
      local tries = 0

      local name, get = deferred(function()
        tries += 1

        error("the module did not compile")
      end)

      for _ = 1, 3 do
        local ok, err = pcall(get)

        expect(ok).toBe(false)
        expect(string.find(tostring(err), "unavailable", 1, true) ~= nil).toBe(true)
        expect(string.find(tostring(err), "the module did not compile", 1, true) ~= nil).toBe(true)
      end

      expect(tries).toBe(1)
      expect(lazy.loaded(name)).toBe(false)
      expect(lazy.failed(name) ~= nil).toBe(true)
      expect(table.find(
        lazy.needs({ harness.make("Part") }, 0, function()
          return name
        end),
        name
      )).toBe(nil)
    end)

    test("a start that throws makes the unit unavailable too, never run again on half made services", function()
      local result = probe("startfail")

      expect(result.startFail.first).toBe(false)
      expect(result.startFail.second).toBe(false)
      expect(result.startFail.starts).toBe(1)
      expect(result.startFail.failed).toBe(true)
    end)

    test("a runtime whose start threw half way is still torn down at deinit", function()
      local result = probe("runtimefail")

      expect(result.runtimeFail.failed).toBe(true)
      expect(result.runtimeFail.torn).toEqual({ "effects.deinit", "enabled_effects.clear", "mover.clear" })
    end)

    test("a unit that fails is said once, and every emit of it after ends quietly", function()
      local _, get = deferred(function()
        error("its play module did not compile")
      end)

      local warnings = harness.captureWarnings(function()
        pcall(get)

        for _ = 1, 3 do
          local fx = lifetime.effect(lifetime.emit(nil), 0, nil)

          lifetime.run(fx, function()
            get().emit()
          end)
        end
      end)

      local said = 0

      for _, line in warnings do
        if string.find(line, "unavailable for this session", 1, true) then
          said += 1
        end
      end

      expect(said).toBe(1)
    end)

    test("a name nothing declared is refused, never answered with nil", function()
      expect(function()
        lazy.need("spec_never_declared")
      end).toThrow()
    end)

    -- the sound's init can wait in Studio (its dock widget), which lune cannot
    -- make it do: an emit in that wait loads the runtime, whose start runs
    -- only once the loader is live, so the deferred init goes live first
    test("the deferred init makes the loader live before anything in it can wait", function()
      local source = fs.readFile("src/init.luau")
      local body = string.match(source, "local function deferredInit%(.-\nend\n")

      assert(body, "no deferredInit in src/init.luau")

      local live = string.find(body, "lazy.begin()", 1, true)
      local sound = string.find(body, "Sound.init()", 1, true)

      expect(live ~= nil and sound ~= nil and live < sound).toBe(true)
    end)

    test("a runtime loaded before init starts at init, and not before", function()
      local result = probe("early")

      expect(#result.startedBeforeInit).toBe(0)
      expect(result.startedAtInit).toEqual(SERVICES)
      expect(result.needs).toEqual({ "beam" })
    end)
  end)

  harness.describe("lazy.needs", function()
    test("answers each enabled instance's kind and its descendants', once each, then the runtime", function()
      local beamName = deferred(function()
        return {}
      end)

      local meshName = deferred(function()
        return {}
      end)

      local loaded, getLoaded = deferred(function()
        return {}
      end)

      getLoaded()

      local model = harness.make("Model")
      local mesh = harness.make("Part")

      for _, name in { "Beam", "Other", "Done" } do
        harness.make("Folder", model).Name = name
      end

      -- by name: lune hands out a new wrapper for an instance on every walk
      local kinds = { Beam = beamName, Other = beamName, Part = meshName, Done = loaded }

      local function kindOf(obj: Instance): string?
        return kinds[obj.Name]
      end

      local names = lazy.needs({ model, mesh }, 0, kindOf)

      expect(names[1]).toBe(beamName)
      expect(names[2]).toBe(meshName)
      expect(#names == 2 or names[3] == "runtime").toBe(true)
      expect(#lazy.needs({}, 0, kindOf)).toBe(0)
    end)

    test("steps the host's pace every few hundred instances, and stops reading at its word", function()
      local model = harness.make("Model")

      for _ = 1, 600 do
        harness.make("Folder", model)
      end

      local steps = 0

      lazy.needs({ model }, 0, function()
        return nil
      end, function(): boolean
        steps += 1

        return false
      end)

      expect(steps).toBe(2)

      local read = 0

      lazy.needs({ model }, 0, function()
        read += 1

        return nil
      end, function(): boolean
        return true
      end)

      expect(read).toBe(256)
    end)
  end)

  harness.describe("native code", function()
    -- a game runs the declaration half too (its engine seams, its knobs'
    -- default functions), so an effect split in two keeps native code in
    -- both halves when it had it before
    test("an effect whose play half is native has a native declaration half", function()
      local lost = {}

      for _, entry in fs.readDir("src/play") do
        local play = fs.readFile(`src/play/{entry}`)
        local decl = fs.readFile(`src/effects/{entry}`)

        if string.find(play, "^%-%-!native") and not string.find(decl, "^%-%-!native") then
          table.insert(lost, entry)
        end
      end

      expect(lost).toEqual({})
    end)
  end)

  harness.describe("what reaches a play module", function()
    test("selecting an effect's instance never loads what it plays", function()
      local found = {}

      for _, entry in fs.readDir("src/effects") do
        local source = fs.readFile(`src/effects/{entry}`)
        local body = string.match(source, "\nfunction [%w_]+%.selected%(.-\nend\n")

        if body ~= nil and string.find(body, "play()", 1, true) then
          table.insert(found, entry)
        end
      end

      expect(found).toEqual({})
    end)

    test("only the unit its effect declares requires it", function()
      local found = {}

      for _, path in walk("src", {}) do
        local source = fs.readFile(path)

        for name in string.gmatch(source, 'require%("@root/play/([%w_]+)"%)') do
          if path ~= `src/effects/{name}.luau` or not string.find(source, "lazy.unit(", 1, true) then
            table.insert(found, `{path}: {name}`)
          end
        end
      end

      expect(found).toEqual({})
    end)
  end)
end)
