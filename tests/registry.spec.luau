local mod = require("@mod/mod")
local knob = require("@mod/knob")
local harness = require("@tests/harness")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance
local NumberRange = harness.datatypes.NumberRange

-- lune has no selector engine, so the spec's query understands class names and
-- child combinators between them and nothing else, which is what every stub
-- here uses. it draws from a pool rather than walking root:GetDescendants()
-- live: the test host hands out a fresh Instance wrapper on every such call,
-- and the registry keys scan's results by instance the way the engine allows,
-- so the fake query has to serve back the very wrappers the spec itself holds
local pool: { Instance } = {}

local function make(class: string, parent: Instance?): Instance
  local inst = Instance.new(class)

  if parent then
    inst.Parent = parent
  end

  table.insert(pool, inst)

  return inst
end

-- the engine never matches a selector's leftmost compound against the instance
-- the query runs from, so a chain counts only when the whole of it lies below
-- the queried instance
local function fakeQuery(root: Instance, selector: string): { Instance }
  local chain = {}

  for token in string.gmatch(selector, "[^>%s]+") do
    table.insert(chain, token)
  end

  local out = {}

  for _, inst in pool do
    if not inst:IsA(chain[#chain]) then
      continue
    end

    local current: Instance? = inst

    for i = #chain - 1, 1, -1 do
      current = (current :: Instance).Parent

      if current == nil or not (current :: Instance):IsA(chain[i]) then
        current = nil
        break
      end
    end

    if current ~= nil and (current :: Instance):IsDescendantOf(root) then
      table.insert(out, inst)
    end
  end

  return out
end

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
      registry.configure({ query = fakeQuery })
      registry.register(stub("beam"))
      registry.register(stub("trail", { classifier = "Trail" }))
      table.clear(pool)

      local root = Instance.new("Folder")
      local beam = make("Beam", root)
      local trail = make("Trail", root)
      local part = make("Part", root)

      expect(registry.of(beam).id).toBe("beam")
      expect(registry.of(trail).id).toBe("trail")
      expect(registry.of(part)).toBe(nil)
      expect(registry.of(root)).toBe(nil)
    end)

    test("scan buckets every match by module and drops the components of a match", function()
      registry.clear()
      registry.configure({ query = fakeQuery })
      registry.register(stub("beam"))
      registry.register(stub("owner", { classifier = "Model", components = "Beam" }))
      table.clear(pool)

      local root = Instance.new("Folder")
      local loose = make("Beam", root)
      local model = make("Model", root)
      local inner = make("Beam", model)

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
      registry.configure({ query = fakeQuery })
      registry.register(stub("beam"))
      table.clear(pool)

      expect(registry.of(Instance.new("Beam")).id).toBe("beam")
      expect(registry.of(Instance.new("Part"))).toBe(nil)
    end)

    test("scan finds a subject under a root the classifier's own leftmost compound names", function()
      registry.clear()
      registry.configure({ query = fakeQuery })
      registry.register(stub("debris", { classifier = "Attachment > Folder > Part" }))
      table.clear(pool)

      local part = make("Part")
      local attachment = make("Attachment", part)
      local folder = make("Folder", attachment)
      local piece = make("Part", folder)

      local hits = registry.scan(attachment)

      expect(#hits).toBe(1)
      expect(hits[1].instance).toBe(piece)
      expect(hits[1].effect.id).toBe("debris")
    end)

    test("scan drops a hit that lies outside the root it was asked for", function()
      registry.clear()
      registry.configure({ query = fakeQuery })
      registry.register(stub("debris", { classifier = "Attachment > Folder > Part" }))
      table.clear(pool)

      local part = make("Part")
      local mine = make("Attachment", part)
      local other = make("Attachment", part)
      local piece = make("Part", make("Folder", mine))

      make("Part", make("Folder", other))

      local hits = registry.scan(mine)

      expect(#hits).toBe(1)
      expect(hits[1].instance).toBe(piece)
    end)

    test("source replaces what the reader walks", function()
      registry.clear()
      registry.configure({ query = fakeQuery })
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
  end)
end)
