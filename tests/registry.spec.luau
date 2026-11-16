local mod = require("@mod/mod")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local harness = require("@tests/harness")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance
local NumberRange = harness.datatypes.NumberRange

local function noop() end

local function stub(id: string, extra: { [string]: any }?)
  local m = {
    id = id,
    display = { name = id, icon = id, order = 10 },
    classifier = "Beam",
    attributes = { EmitDelay = knob(0):min(0) },
    properties = {},
    emit = noop,
  }

  for k, v in extra or {} do
    m[k] = v
  end

  return m
end

harness.suite(function()
  harness.describe("registry.register", function()
    test("a valid module is registered, frozen and listed by order", function()
      registry.clear()
      registry.register(stub("b", { display = { name = "B", order = 20 } }))
      registry.register(stub("a", { display = { name = "A", order = 10 }, classifier = "Trail" }))

      expect(registry.get("a").id).toBe("a")
      expect(table.isfrozen(registry.get("a"))).toBe(true)
      expect(table.isfrozen(registry.get("a").attributes.EmitDelay)).toBe(true)
      expect(registry.list()[1].id).toBe("a")
      expect(registry.list()[2].id).toBe("b")
    end)

    test("a duplicate id errors", function()
      registry.clear()
      registry.register(stub("x"))

      expect(function()
        registry.register(stub("x"))
      end).toThrow()
    end)

    test("registering the same table again after a clear succeeds", function()
      registry.clear()

      local m = stub("x", { layout = { { title = "T", entries = { "EmitDelay" } } } })
      registry.register(m)

      registry.clear()
      registry.register(m)

      expect(registry.get("x")).toBe(m)
    end)

    test("a module frozen by its author still has its rows and layout frozen", function()
      registry.clear()

      local m = table.freeze(stub("x", { layout = { { title = "T", entries = { "EmitDelay" } } } }))
      registry.register(m)

      expect(table.isfrozen(m.attributes)).toBe(true)
      expect(table.isfrozen(m.attributes.EmitDelay)).toBe(true)
      expect(table.isfrozen(m.attributes.EmitDelay.names)).toBe(true)
      expect(table.isfrozen(m.properties)).toBe(true)
      expect(table.isfrozen(m.display)).toBe(true)
      expect(table.isfrozen(m.layout)).toBe(true)
      expect(table.isfrozen(m.layout[1])).toBe(true)
    end)

    test("a row that is not a knob errors", function()
      registry.clear()

      expect(function()
        registry.register(stub("x", { attributes = { EmitDelay = 0 } }))
      end).toThrow()
    end)

    test("a default outside its own bounds errors", function()
      registry.clear()

      expect(function()
        registry.register(stub("x", { attributes = { A = knob(5):max(2) } }))
      end).toThrow()
    end)

    test("a bound on an unordered row errors", function()
      registry.clear()

      expect(function()
        registry.register(stub("x", { attributes = { A = knob("s"):min(0) } }))
      end).toThrow()
    end)

    test("a bound of another kind than the default errors", function()
      registry.clear()

      expect(function()
        registry.register(stub("x", { attributes = { A = knob(NumberRange.new(0, 1)):min("a") } }))
      end).toThrow()
    end)

    test("an alias that is another row's name or alias errors", function()
      registry.clear()

      expect(function()
        registry.register(stub("x", { attributes = { A = knob(1), B = knob(2):aliases("A") } }))
      end).toThrow()

      expect(function()
        registry.register(stub("y", { attributes = { A = knob(1):aliases("C"), B = knob(2):aliases("C") } }))
      end).toThrow()
    end)

    test("a layout entry that names no row errors, a nested group is fine", function()
      registry.clear()

      expect(function()
        registry.register(stub("x", { layout = { { title = "T", entries = { "Nope" } } } }))
      end).toThrow()

      registry.register(stub("y", {
        layout = {
          {
            title = "T",
            entries = { "EmitDelay", { title = "Inner", entries = { { action = "go", label = "Go" } } } },
          },
        },
      }))

      expect(registry.get("y") ~= nil).toBe(true)
      expect(table.isfrozen(registry.get("y").layout[1].entries[2])).toBe(true)
      expect(table.isfrozen(registry.get("y").layout)).toBe(true)
    end)

    test("an unknown unit, curve preset or option list errors", function()
      registry.clear()

      expect(function()
        registry.register(stub("x", { attributes = { A = knob(1):unit("meters") } }))
      end).toThrow()

      expect(function()
        registry.register(stub("y", { attributes = { A = knob(1):curve("bounce") } }))
      end).toThrow()

      expect(function()
        registry.register(stub("z", { attributes = { A = knob(1):options({ "a" }) } }))
      end).toThrow()
    end)

    test("a default modifier must be a mod spec, and the module needs an emit and a classifier", function()
      registry.clear()

      expect(function()
        registry.register(stub("x", { attributes = { A = knob(1):mod({}) } }))
      end).toThrow()

      expect(function()
        registry.register(stub("y", { emit = false }))
      end).toThrow()

      expect(function()
        registry.register(stub("z", { classifier = false }))
      end).toThrow()

      registry.register(stub("ok", { attributes = { A = knob(1):mod(mod.to(2)) } }))
      expect(registry.owned(registry.get("ok")).attribute.A).toBe(true)
      expect(registry.owned(registry.get("ok")).attribute.EmitDelay).toBe(nil)
    end)

    test("a property mod row is owned on both sides, aliases included", function()
      registry.clear()

      registry.register(stub("beam-ish", { properties = { Width = knob():aliases("OldWidth"):mod() } }))

      local owned = registry.owned(registry.get("beam-ish"))

      expect(owned.property.Width).toBe(true)
      expect(owned.property.OldWidth).toBe(true)
      expect(owned.attribute.Width).toBe(true)
      expect(owned.attribute.OldWidth).toBe(true)

      expect(owned.attribute.EmitDelay).toBe(nil)
      expect(owned.property.EmitDelay).toBe(nil)
    end)

    test("constant is an optional boolean", function()
      registry.clear()
      registry.register(stub("c", { constant = true }))

      expect(registry.get("c").constant).toBe(true)

      expect(function()
        registry.register(stub("d", { constant = 1 }))
      end).toThrow()
    end)

    test("events must be unique names and never a built in lane", function()
      registry.clear()

      expect(function()
        registry.register(stub("a", { events = "dissipate" }))
      end).toThrow()

      expect(function()
        registry.register(stub("b", { events = { "start" } }))
      end).toThrow()

      expect(function()
        registry.register(stub("c", { events = { "one", "one" } }))
      end).toThrow()

      registry.register(stub("d", { events = { "one", "two" } }))

      expect(registry.get("d").events[2]).toBe("two")
      expect(table.isfrozen(registry.get("d").events)).toBe(true)
    end)

    test("a row may declare more than one default modifier", function()
      registry.clear()

      expect(function()
        registry.register(stub("a", { attributes = { A = knob(1):mod(mod.to(2), {}) } }))
      end).toThrow()

      registry.register(stub("ok", {
        events = { "dissipate" },
        attributes = { A = knob(1):mod(mod.to(2), mod.from(0):lane("dissipate")) },
      }))

      expect(#registry.get("ok").attributes.A.modDefault).toBe(2)
      expect(table.isfrozen(registry.get("ok").attributes.A.modDefault[2].opts)).toBe(true)
    end)

    -- a row may put every default modifier on an event lane, and where it rests
    -- until one fires is its own value rather than a lane's
    test("a row whose only default modifier waits on an event registers", function()
      registry.clear()

      registry.register(stub("ok", {
        events = { "dissipate" },
        attributes = { Fade = knob(0):mod(mod.to(1):lane("dissipate")) },
      }))

      local row = registry.get("ok").attributes.Fade

      expect(#row.modDefault).toBe(1)
      expect(row.modDefault[1].opts.lane).toBe("dissipate")
    end)

    -- a lane no module declares can never fire, so a modifier waiting on one
    -- would sit on the row for the whole emit
    test("a default modifier on a lane the module never declares errors", function()
      registry.clear()

      expect(function()
        registry.register(stub("a", {
          events = { "dissipate" },
          attributes = { Fade = knob(0):mod(mod.to(1):lane("dissipat")) },
        }))
      end).toThrow()

      expect(function()
        registry.register(stub("b", { attributes = { Fade = knob(0):mod(mod.to(1):lane("dissipate")) } }))
      end).toThrow()

      registry.register(stub("c", {
        events = { "dissipate" },
        attributes = { Fade = knob(0):mod(mod.to(1):lane("dissipate")) },
      }))

      expect(registry.get("c").attributes.Fade.modDefault[1].opts.lane).toBe("dissipate")
    end)

    -- the two built in lanes are always there, whatever a module declares
    test("a default modifier on a built in lane needs no event", function()
      registry.clear()
      registry.register(stub("ok", { attributes = { Fade = knob(0):mod(mod.to(1):lane("end")) } }))

      expect(registry.get("ok").attributes.Fade.modDefault[1].opts.lane).toBe("end")
    end)

    test("a compound layout entry names rows the module has", function()
      registry.clear()

      expect(function()
        registry.register(stub("a", {
          attributes = { A = knob(1) },
          layout = { { title = "One", entries = { "A", { curve = "Nope" } } } },
        }))
      end).toThrow()

      registry.register(stub("ok", {
        attributes = { A = knob(1), ACurve = knob(1), ADuration = knob(1) },
        layout = { { title = "One", entries = { "A", { curve = "ACurve", duration = "ADuration" } } } },
      }))

      expect(registry.get("ok").id).toBe("ok")
    end)

    test("the version moves on every register, unregister and clear", function()
      local before = registry.version
      local module = stub("version_probe")

      registry.register(module :: any)
      expect(registry.version).toBe(before + 1)

      registry.unregister(module :: any)
      expect(registry.version).toBe(before + 2)

      registry.clear()
      expect(registry.version).toBe(before + 3)
    end)
  end)

  harness.describe("registry.depth and registry.subjects", function()
    test("counts top-level combinators in the deepest alternative", function()
      expect(registry.depth("Beam")).toBe(0)
      expect(registry.depth(".Shockwave > #Rings > BasePart")).toBe(2)
      expect(registry.depth("Model:has(> BasePart#Start):has(> BasePart#End)")).toBe(0)
      expect(registry.depth("BasePart[$Enabled=true]:not(.Shockwave BasePart)")).toBe(0)
      expect(registry.depth("Beam, .Shockwave > #Rings > BasePart")).toBe(2)
      expect(registry.depth("Folder >> Part")).toBe(1)
    end)

    test("names the subject class of each alternative, or nothing when one has none", function()
      expect(registry.subjects("Beam")[1]).toBe("Beam")
      expect(registry.subjects(".Shockwave > #Rings > BasePart")[1]).toBe("BasePart")
      expect(registry.subjects("Model:has(> BasePart#Start)")[1]).toBe("Model")
      expect(registry.subjects("RayValue.CameraShake")[1]).toBe("RayValue")
      expect(registry.subjects("Beam, Trail")[2]).toBe("Trail")
      expect(registry.subjects(".BezierParticle")).toBe(nil)
    end)
  end)

  harness.describe("registry.of and registry.scan", function()
    test("of finds the module whose classifier matches from the right ancestor", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("beam"))
      registry.register(stub("trail", { classifier = "Trail" }))
      harness.reset()

      local root = Instance.new("Folder")
      local beam = harness.make("Beam", root)
      local trail = harness.make("Trail", root)
      local part = harness.make("Part", root)

      expect(registry.of(beam).id).toBe("beam")
      expect(registry.of(trail).id).toBe("trail")
      expect(registry.of(part)).toBe(nil)
      expect(registry.of(root)).toBe(nil)
    end)

    test("of asks no query of an instance that fails its subject's own filters", function()
      registry.clear()

      local asked = 0

      registry.configure({
        query = function(root: Instance, selector: string)
          asked += 1
          return harness.query(root, selector)
        end,
      })
      registry.register(stub("screen", { classifier = "BasePart[$Enabled=true]:not(.Shockwave >> BasePart)" }))
      registry.register(stub("mesh", { classifier = "Model#Rig:has(> BasePart#Start)" }))
      harness.reset()

      local root = harness.make("Folder", harness.make("Folder"))
      local plain = harness.make("Part", root)
      local off = harness.make("Part", root)
      local on = harness.make("Part", root)
      local other = harness.make("Model", root)
      local rig = harness.make("Model", root)

      off:SetAttribute("Enabled", false)
      on:SetAttribute("Enabled", true)
      other.Name = "Other"
      rig.Name = "Rig"
      harness.make("Part", rig).Name = "Start"

      expect(registry.of(plain)).toBe(nil)
      expect(registry.of(off)).toBe(nil)
      expect(registry.of(other)).toBe(nil)
      expect(asked).toBe(0)

      expect(registry.of(on).id).toBe("screen")
      expect(registry.of(rig).id).toBe("mesh")
      expect(asked > 0).toBe(true)
    end)

    test("the place and its services are never an effect, and never asked", function()
      registry.clear()

      local asked = 0

      registry.configure({
        query = function(root: Instance, selector: string)
          asked += 1
          return harness.query(root, selector)
        end,
      })
      registry.register(stub("mesh", { classifier = "Model:has(> BasePart#Start):has(> BasePart#End)" }))
      harness.reset()

      local place = harness.make("DataModel")
      local workspace = harness.make("Workspace", place)

      expect(registry.of(place)).toBe(nil)
      expect(registry.of(workspace)).toBe(nil)
      expect(asked).toBe(0)
    end)

    test("a model straight under a service is asked from the service, never the place", function()
      registry.clear()

      local roots: { Instance } = {}

      registry.configure({
        query = function(root: Instance, selector: string)
          table.insert(roots, root)
          return harness.query(root, selector)
        end,
      })
      registry.register(stub("mesh", { classifier = "Model:has(> BasePart#Start):has(> BasePart#End)" }))
      harness.reset()

      local place = harness.make("DataModel")
      local workspace = harness.make("Workspace", place)
      local rig = harness.make("Model", workspace)

      harness.make("Part", rig).Name = "Start"
      harness.make("Part", rig).Name = "End"

      expect(registry.of(rig).id).toBe("mesh")
      expect(#roots > 0).toBe(true)
      expect(table.find(roots, place)).toBe(nil)
    end)

    -- a list asks for any one of its selectors, so a missing first child
    -- rules nothing out and the query is asked
    test("a :has list is left to the query when its first child is missing", function()
      registry.clear()

      local asked: { string } = {}

      -- the harness's query reads no selector list, so this one only notes
      -- that it was asked
      registry.configure({
        query = function(_root: Instance, selector: string)
          table.insert(asked, selector)
          return {}
        end,
      })
      registry.register(stub("mesh", { classifier = "Model:has(> BasePart#Start, > BasePart#End)" }))
      harness.reset()

      local place = harness.make("DataModel")
      local workspace = harness.make("Workspace", place)
      local rig = harness.make("Model", workspace)

      harness.make("Part", rig).Name = "End"

      registry.of(rig)

      expect(#asked > 0).toBe(true)
    end)

    test("a scan of a service never climbs to the place", function()
      registry.clear()

      local roots: { Instance } = {}

      registry.configure({
        query = function(root: Instance, selector: string)
          table.insert(roots, root)
          return harness.query(root, selector)
        end,
      })
      registry.register(stub("beam", { classifier = "Model:has(> Part) > Beam" }))
      harness.reset()

      local place = harness.make("DataModel")
      local workspace = harness.make("Workspace", place)
      local holder = harness.make("Model", workspace)

      harness.make("Part", holder)

      local beam = harness.make("Beam", holder)
      local hits = registry.scan(workspace)

      expect(#hits).toBe(1)
      expect(hits[1].instance).toBe(beam)
      expect(table.find(roots, place)).toBe(nil)
    end)

    test("a filter the engine might read another way is left to the query", function()
      registry.clear()

      local asked = 0

      registry.configure({
        query = function(root: Instance, selector: string)
          asked += 1
          return harness.query(root, selector)
        end,
      })
      registry.register(stub("screen", { classifier = "BasePart[$Enabled=true]:not(.Shockwave >> BasePart)" }))
      harness.reset()

      local part = harness.make("Part", harness.make("Folder", harness.make("Folder")))

      part:SetAttribute("Enabled", "true")
      registry.of(part)

      expect(asked).toBe(1)
    end)

    test("a custom classifier decides an unparented instance a built-in plays whole", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("beam"))
      registry.register(stub("mine", { classifier = "Beam.Mine" }), true)
      registry.register(stub("filtered", { classifier = "Beam.Filtered[$Kind=1]" }), true)
      registry.register(stub("nested", { classifier = "Folder.Outer > Beam.Nested" }), true)
      harness.reset()

      local mine = harness.make("Beam")
      local filtered = harness.make("Beam")
      local nested = harness.make("Beam")
      local plain = harness.make("Beam")
      local parented = harness.make("Beam", harness.make("Folder"))

      mine:AddTag("Mine")
      filtered:AddTag("Filtered")
      nested:AddTag("Nested")
      parented:AddTag("Mine")

      expect(registry.of(mine).id).toBe("mine")
      expect(registry.of(filtered)).toBe(nil)
      expect(registry.of(nested)).toBe(nil)
      expect(registry.of(plain).id).toBe("beam")
      expect(registry.of(parented).id).toBe("mine")
    end)

    test("scan buckets every match by module and drops the components of a match", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("beam"))
      registry.register(stub("owner", { classifier = "Model", components = "Beam" }))
      harness.reset()

      local root = Instance.new("Folder")
      local loose = harness.make("Beam", root)
      local model = harness.make("Model", root)
      local inner = harness.make("Beam", model)

      local hits = registry.scan(root)

      expect(#hits).toBe(2)

      local byInstance = {}

      for _, hit in hits do
        byInstance[hit.instance] = hit.effect.id
      end

      expect(byInstance[loose]).toBe("beam")
      expect(byInstance[model]).toBe("owner")
      expect(byInstance[inner]).toBe(nil)
    end)

    test("of answers a class-only classifier with IsA alone", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("beam"))
      harness.reset()

      expect(registry.of(Instance.new("Beam")).id).toBe("beam")
      expect(registry.of(Instance.new("Part"))).toBe(nil)
    end)

    test("scan finds a subject under a root the classifier's own leftmost compound names", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("debris", { classifier = "Attachment > Folder > Part" }))
      harness.reset()

      local part = harness.make("Part")
      local attachment = harness.make("Attachment", part)
      local folder = harness.make("Folder", attachment)
      local piece = harness.make("Part", folder)

      local hits = registry.scan(attachment)

      expect(#hits).toBe(1)
      expect(hits[1].instance).toBe(piece)
      expect(hits[1].effect.id).toBe("debris")
    end)

    -- a query from above the root reads the whole subtree of that ancestor, which
    -- for a root under workspace is the whole place: a chain of class, tag and
    -- name compounds is matched against the root's own ancestry by hand instead
    test("scan reaches a subject through the root without asking above the root", function()
      registry.clear()

      local above = 0
      local root

      registry.configure({
        query = function(from, selector)
          if from ~= root and not from:IsDescendantOf(root) then
            above += 1
          end

          return harness.query(from, selector)
        end,
      })

      registry.register(stub("ring", { classifier = ".Shockwave > #Rings > BasePart" }))
      harness.reset()

      -- the root sits two levels down, as a folder in workspace does
      root = harness.make("Folder", harness.make("Folder", harness.make("Folder")))

      local attachment = harness.make("Attachment", root)
      attachment:AddTag("Shockwave")
      local rings = harness.make("Folder", attachment)
      rings.Name = "Rings"
      local piece = harness.make("Part", rings)

      -- a Rings folder that is not a child of the tagged attachment is no hit
      local model = harness.make("Model", attachment)
      local deeper = harness.make("Folder", model)
      deeper.Name = "Rings"
      harness.make("Part", deeper)

      for _, from in { root, attachment, rings } do
        above = 0

        local hits = registry.scan(from)

        expect(#hits).toBe(1)
        expect(hits[1].instance).toBe(piece)
        expect(above).toBe(0)
      end
    end)

    test("scan still asks above the root for a chain whose leading compound is not plain", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("debris", { classifier = "Attachment:has(> Folder) > Folder > Part" }))
      harness.reset()

      local part = harness.make("Part")
      local attachment = harness.make("Attachment", part)
      local folder = harness.make("Folder", attachment)
      local piece = harness.make("Part", folder)

      local hits = registry.scan(attachment)

      expect(#hits).toBe(1)
      expect(hits[1].instance).toBe(piece)
    end)

    test("of classifies through a chain of plain compounds without a query", function()
      registry.clear()

      local asked = 0

      registry.configure({
        query = function(from, selector)
          asked += 1
          return harness.query(from, selector)
        end,
      })

      registry.register(stub("ring", { classifier = ".Shockwave > #Rings > BasePart" }))
      harness.reset()

      local attachment = harness.make("Attachment", harness.make("Part"))
      attachment:AddTag("Shockwave")
      local rings = harness.make("Folder", attachment)
      rings.Name = "Rings"
      local piece = harness.make("Part", rings)
      local loose = harness.make("Part", attachment)

      asked = 0

      expect(registry.of(piece).id).toBe("ring")
      expect(registry.of(loose)).toBe(nil)
      expect(asked).toBe(0)
    end)

    test("a hit that claims every descendant drops a hit any number of levels below it", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("mesh", { classifier = "Model", components = "Instance" }))
      registry.register(stub("beam", { classifier = "Beam" }))
      harness.reset()

      local root = harness.make("Folder")
      local model = harness.make("Model", root)
      harness.make("Beam", harness.make("Part", harness.make("Folder", model)))
      local outside = harness.make("Beam", root)

      local hits = registry.scan(root)

      expect(#hits).toBe(2)

      local ids = {}

      for _, hit in hits do
        ids[hit.effect.id] = hit.instance
      end

      expect(ids.mesh == model).toBe(true)
      expect(ids.beam == outside).toBe(true)
    end)

    test("scan drops a hit that lies outside the root it was asked for", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("debris", { classifier = "Attachment > Folder > Part" }))
      harness.reset()

      local part = harness.make("Part")
      local mine = harness.make("Attachment", part)
      local other = harness.make("Attachment", part)
      local piece = harness.make("Part", harness.make("Folder", mine))

      harness.make("Part", harness.make("Folder", other))

      local hits = registry.scan(mine)

      expect(#hits).toBe(1)
      expect(hits[1].instance).toBe(piece)
    end)

    test("source replaces what the reader walks", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("beam", { attributes = { A = knob(0) } }))

      local calls = 0

      registry.source(function()
        calls += 1
        return { A = 7 }
      end)

      local ok, err = pcall(function()
        local attrs = registry.read(Instance.new("Beam"))

        expect(calls).toBe(1)
        expect(attrs.A).toBe(7)
      end)

      registry.source(nil)

      if not ok then
        error(err, 0)
      end
    end)

    test("read given its module already known answers the same as read that resolves it", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("beam", { attributes = { A = knob(3) } }))

      harness.reset()

      local beam = harness.make("Beam")
      local module = registry.of(beam)

      local attrs = registry.read(beam)
      local attrsWithModule = registry.read(beam, module)

      expect(attrsWithModule).toEqual(attrs)
    end)

    test("scan returns nothing under a claimant that claims every descendant, without a query", function()
      registry.clear()

      local asked = 0

      registry.configure({
        query = function(root, selector)
          asked += 1
          return harness.query(root, selector)
        end,
      })

      registry.register(stub("mesh", { classifier = "Model", components = "Instance" }))
      registry.register(stub("beam", { classifier = "Beam" }))

      harness.reset()

      local model = harness.make("Model")
      harness.make("Beam", model)

      asked = 0

      expect(#registry.scan(model, registry.get("mesh"))).toBe(0)
      expect(asked).toBe(0)
      expect(#registry.scan(model)).toBe(1)
    end)

    test("a hit that claims every descendant drops the hits below it by ancestry", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("mesh", { classifier = "Model", components = "Instance" }))
      registry.register(stub("beam", { classifier = "Beam" }))

      harness.reset()

      local root = harness.make("Folder")
      local model = harness.make("Model", root)
      harness.make("Beam", model)
      local outside = harness.make("Beam", root)

      local hits = registry.scan(root)

      expect(#hits).toBe(2)

      local ids = {}

      for _, hit in hits do
        ids[hit.effect.id] = hit.instance
      end

      expect(ids.mesh == model).toBe(true)
      expect(ids.beam == outside).toBe(true)
    end)

    test("scan hands back a legacy tween child with no effect, and a tagged one as its module's", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("shake", { classifier = "RayValue.CameraShake" }))

      harness.reset()

      local root = harness.make("Folder")
      local part = harness.make("Part", root)
      local child = harness.make("RayValue", part)
      local shake = harness.make("RayValue", root)
      shake:AddTag("CameraShake")

      local hits = registry.scan(root)
      local byInstance = {}

      for _, hit in hits do
        byInstance[hit.instance] = hit
      end

      expect(#hits).toBe(2)
      expect(byInstance[shake].effect.id).toBe("shake")
      expect(byInstance[child].effect).toBe(nil)
      expect(byInstance[part]).toBe(nil)
    end)

    test("a legacy child under a subtree a module claims is that module's, not a hit", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("mesh", { classifier = "Model", components = "Instance" }))

      harness.reset()

      local root = harness.make("Folder")
      local model = harness.make("Model", root)
      harness.make("RayValue", harness.make("Part", model))

      expect(#registry.scan(model, registry.get("mesh"))).toBe(0)
      expect(#registry.scan(root)).toBe(1)
    end)

    test("a legacy child naming a mod row of its parent's module is left to the row", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("sound", { classifier = "Sound", properties = { Volume = knob():mod() } }))
      registry.register(stub("trail", { classifier = "Trail" }))

      harness.reset()

      local root = harness.make("Folder")
      local sound = harness.make("Sound", root)
      local trail = harness.make("Trail", root)

      harness.make("RayValue", sound).Name = "Volume"

      local tagged = harness.make("RayValue", sound)
      tagged.Name = "Volume"
      tagged:AddTag("AttributeTweener")

      local lifetime = harness.make("RayValue", trail)
      lifetime.Name = "Lifetime"

      local hits = registry.scan(root)
      local byInstance = {}

      for _, hit in hits do
        byInstance[hit.instance] = hit
      end

      -- a property row's queues lived on the attribute side too, so neither
      -- spelling of the sound's child is dispatched; the trail declares no
      -- rows at all, so its child still drives what it targets
      expect(#hits).toBe(3)
      expect(byInstance[sound].effect.id).toBe("sound")
      expect(byInstance[trail].effect.id).toBe("trail")
      expect(byInstance[lifetime].effect).toBe(nil)
    end)

    test("scan over every classifier shape finds each effect once and nothing else", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(stub("trail", { classifier = "Trail" }))
      registry.register(stub("particle", { classifier = "ParticleEmitter" }))
      registry.register(stub("sound", { classifier = "Sound" }))
      registry.register(stub("shake", { classifier = "RayValue.CameraShake" }))
      registry.register(stub("spin", { classifier = "Model:not(Model:has(> BasePart#Start):has(> BasePart#End))" }))
      registry.register(
        stub("mesh", { classifier = "Model:has(> BasePart#Start):has(> BasePart#End)", components = "Instance" })
      )
      registry.register(
        stub("screen", { classifier = "BasePart[$Enabled=true]:not(.Shockwave >> BasePart)", components = "Instance" })
      )
      registry.register(stub("origin", { classifier = "Attachment.Shockwave" }))
      registry.register(stub("ring", { classifier = ".Shockwave > #Rings > BasePart", components = "Instance" }))
      registry.register(stub("bolt", { classifier = "Attachment.LightningBolt", components = "Instance" }))

      harness.reset()

      local root = harness.make("Folder")
      harness.make("Trail", root)
      harness.make("ParticleEmitter", root)
      harness.make("Sound", root)
      harness.make("RayValue", root):AddTag("CameraShake")
      harness.make("RayValue", root)
      local spin = harness.make("Model", root)
      harness.make("Part", spin).Name = "Start"
      local mesh = harness.make("Model", root)
      harness.make("Part", mesh).Name = "Start"
      harness.make("Part", mesh).Name = "End"
      harness.make("ParticleEmitter", mesh)
      local screen = harness.make("Part", root)
      screen:SetAttribute("Enabled", true)
      harness.make("Sound", screen)
      local origin = harness.make("Attachment", root)
      origin:AddTag("Shockwave")
      local rings = harness.make("Folder", origin)
      rings.Name = "Rings"
      local piece = harness.make("Part", rings)
      piece:SetAttribute("Enabled", true)
      harness.make("Attachment", root):AddTag("LightningBolt")
      local plain = harness.make("Part", root)
      plain:SetAttribute(mods.attrName("attribute", "Transparency"), "x")

      local counts = {}

      for _, hit in registry.scan(root) do
        local id = if hit.effect ~= nil then hit.effect.id else "legacy"
        counts[id] = (counts[id] or 0) + 1
      end

      -- the untagged RayValue is the old format's tween child, and the part
      -- carrying nothing but a modifier attribute is still not a hit at all
      expect(counts).toEqual({
        trail = 1,
        particle = 1,
        sound = 1,
        shake = 1,
        spin = 1,
        mesh = 1,
        screen = 1,
        origin = 1,
        ring = 1,
        bolt = 1,
        legacy = 1,
      })
    end)

    test("scan asks no module whose classes nothing under the root is, and asks again once one is", function()
      local asked: { [string]: number } = {}

      registry.clear()
      registry.configure({
        query = function(root: Instance, selector: string)
          asked[selector] = (asked[selector] or 0) + 1

          return harness.query(root, selector)
        end,
      })
      registry.register(stub("beam"))
      registry.register(stub("trail", { classifier = "Trail" }))
      registry.register(stub("spin", { classifier = "Model:not(Model:has(> BasePart#Start))" }))
      registry.register(stub("ring", { classifier = ".Shockwave > #Rings > BasePart" }))
      registry.register(stub("any", { classifier = ".Loose" }))
      harness.reset()

      local root = harness.make("Folder", harness.make("Folder", harness.make("Folder")))
      local beam = harness.make("Beam", root)
      local origin = harness.make("Attachment", root)
      local rings = harness.make("Folder", origin)

      origin:AddTag("Shockwave")
      rings.Name = "Rings"

      -- a subject class answered by a subclass of it, which only IsA tells
      local piece = harness.make("MeshPart", rings)

      local function ids(hits: { any }): { [string]: Instance }
        local out = {}

        for _, hit in hits do
          out[if hit.effect ~= nil then hit.effect.id else "legacy"] = hit.instance
        end

        return out
      end

      expect(ids(registry.scan(root))).toEqual({ beam = beam, ring = piece })

      -- a classifier whose subject names no class can be anything, so it is
      -- always asked, and the old format's children only where one can be
      expect(asked).toEqual({
        ["Beam"] = 1,
        [".Shockwave > #Rings > BasePart"] = 1,
        [".Loose"] = 1,
      })

      local trail = harness.make("Trail", root)
      local model = harness.make("Model", root)
      local child = harness.make("RayValue", beam)

      table.clear(asked)

      expect(ids(registry.scan(root))).toEqual({
        beam = beam,
        ring = piece,
        trail = trail,
        spin = model,
        legacy = child,
      })
      expect(asked.Trail).toBe(1)
      expect(asked.RayValue).toBe(1)
      expect(asked["Model:not(Model:has(> BasePart#Start))"]).toBe(1)
    end)
  end)
  harness.describe("registry.problems and registry.unregister", function()
    test("every reason a module is refused for is named at once, and nothing is registered", function()
      registry.clear()

      local bad = stub("x", {
        display = { icon = "x" },
        classifier = 5,
        emit = "no",
        attributes = { A = knob(5):max(2), B = 0 },
      })

      local found = registry.problems(bad)

      expect(#found).toBe(5)
      expect(table.concat(found, "\n")).toBe(table.concat({
        "effect module x: display needs a name",
        "effect module x: classifier must be a selector string",
        "effect module x: emit must be a function",
        "effect module x: the default of A lies outside its own bounds",
        "effect module x: attribute row B is not a knob",
      }, "\n"))

      local ok, err = pcall(registry.register, bad)

      expect(ok).toBe(false)
      expect(string.find(tostring(err), "emit must be a function", 1, true) ~= nil).toBe(true)
      expect(string.find(tostring(err), "row B is not a knob", 1, true) ~= nil).toBe(true)
      expect(registry.get("x")).toBe(nil)
      expect(#registry.list()).toBe(0)
    end)

    test("a module that can be registered has no problems, and a taken id is one", function()
      registry.clear()

      local first = stub("x")

      expect(registry.problems(first)).toEqual({})

      registry.register(first)

      expect(registry.problems(stub("x"))).toEqual({ "effect module x: already registered" })
      expect(registry.problems(stub("x"), first)).toEqual({})
    end)

    test("a module that is no table of rows is refused rather than walked", function()
      registry.clear()

      expect(registry.problems(stub("x", { attributes = 3, layout = "a" }))).toEqual({
        "effect module x: attributes must be a table of knobs",
        "effect module x: layout must be a list of entries",
      })
    end)

    test("unregister frees the id and every lookup, and leaves the others", function()
      registry.clear()
      registry.configure({ query = harness.query })
      harness.reset()

      local beam = stub("beam")
      local trail = stub("trail", { classifier = "Trail" })

      registry.register(beam)
      registry.register(trail)
      registry.unregister(beam)

      expect(registry.get("beam")).toBe(nil)
      expect(registry.list()).toEqual({ trail })
      expect(registry.of(harness.make("Beam"))).toBe(nil)
      expect(registry.of(harness.make("Trail"))).toBe(trail)

      registry.unregister(beam)
      registry.register(stub("beam"))

      expect(registry.get("beam") ~= nil).toBe(true)
    end)
  end)
end)
