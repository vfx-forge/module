local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect

local function ids(list: { Instance })
  local out = {}

  for _, inst in list do
    table.insert(out, inst.Name)
  end

  table.sort(out)

  return table.concat(out, " ")
end

harness.suite(function()
  harness.describe("harness.query", function()
    test("a class token matches by IsA, never the root itself", function()
      harness.reset()

      local root = harness.make("Model")
      root.Name = "root"
      local a = harness.make("Part", root)
      a.Name = "a"
      local b = harness.make("MeshPart", root)
      b.Name = "b"
      harness.make("Folder", root).Name = "f"

      expect(ids(harness.query(root, "BasePart"))).toBe("a b")
      expect(ids(harness.query(root, "Model"))).toBe("")
      expect(ids(harness.query(root, "Instance"))).toBe("a b f")
    end)

    test("name, tag and attribute filters compound", function()
      harness.reset()

      local root = harness.make("Folder")
      local a = harness.make("Part", root)
      a.Name = "Start"
      a:AddTag("Shockwave")
      a:SetAttribute("Enabled", true)
      local b = harness.make("Part", root)
      b.Name = "Start"
      b:SetAttribute("Enabled", false)

      expect(#harness.query(root, "#Start")).toBe(2)
      expect(#harness.query(root, "Part.Shockwave")).toBe(1)
      expect(#harness.query(root, "BasePart[$Enabled=true]")).toBe(1)
      expect(#harness.query(root, "[$Enabled]")).toBe(2)
      expect(#harness.query(root, "#Start.Shockwave[$Enabled=true]")).toBe(1)
    end)

    test("child and descendant combinators, with the whole chain below the root", function()
      harness.reset()

      local root = harness.make("Folder")
      local att = harness.make("Attachment", root)
      att:AddTag("Shockwave")
      local rings = harness.make("Folder", att)
      rings.Name = "Rings"
      local piece = harness.make("Part", rings)
      piece.Name = "piece"
      local deep = harness.make("Folder", rings)
      local nested = harness.make("Part", deep)
      nested.Name = "nested"

      expect(ids(harness.query(root, ".Shockwave > #Rings > BasePart"))).toBe("piece")
      expect(ids(harness.query(root, ".Shockwave >> BasePart"))).toBe("nested piece")
      expect(ids(harness.query(att, ".Shockwave > #Rings > BasePart"))).toBe("")
      expect(ids(harness.query(rings, "#Rings > BasePart"))).toBe("")
    end)

    test("alternatives, :not and :has", function()
      harness.reset()

      local root = harness.make("Folder")
      local mesh = harness.make("Model", root)
      mesh.Name = "mesh"
      harness.make("Part", mesh).Name = "Start"
      harness.make("Part", mesh).Name = "End"
      local spin = harness.make("Model", root)
      spin.Name = "spin"
      harness.make("Part", spin).Name = "Start"
      local att = harness.make("Attachment", root)
      att.Name = "origin"
      att:AddTag("Shockwave")
      local under = harness.make("Part", att)
      under.Name = "under"
      under:SetAttribute("Enabled", true)
      local free = harness.make("Part", root)
      free.Name = "free"
      free:SetAttribute("Enabled", true)

      expect(ids(harness.query(root, "Model:has(> BasePart#Start):has(> BasePart#End)"))).toBe("mesh")
      expect(ids(harness.query(root, "Model:not(Model:has(> BasePart#Start):has(> BasePart#End))"))).toBe("spin")
      expect(ids(harness.query(root, "BasePart[$Enabled=true]:not(.Shockwave >> BasePart)"))).toBe("free")
      expect(ids(harness.query(root, "Attachment.Shockwave, Model:has(> BasePart#End)"))).toBe("mesh origin")
      expect(ids(harness.query(root, "Attachment.Shockwave,Model:has(> BasePart#End)"))).toBe("mesh origin")
    end)
  end)
end)
