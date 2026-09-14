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
        registry.register(stub("x", { attributes = { A = knob(1):unit("metres") } }))
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
  end)
end)
