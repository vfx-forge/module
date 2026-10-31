local harness = require("@tests/harness")
local decal_fade = require("@mod/decal_fade")
local test, expect = harness.test, harness.expect

-- a mesh model's Start, wearing a decal when `decal` is on
local function startOf(decal: boolean): Instance
  harness.reset()

  local model = harness.make("Model", harness.make("Folder"))
  local start = harness.make("Part", model)

  start.Name = "Start"

  if decal then
    harness.make("Decal", start)
  end

  return start
end

local function fade(stored: { [string]: any }, decal: boolean?): (number?, number?)
  local start = startOf(decal ~= false)
  local model = start.Parent :: Instance

  for name, v in stored do
    model:SetAttribute(name, v)
  end

  return decal_fade.resolve(start, decal_fade.read(model))
end

harness.suite(function()
  harness.describe("decal_fade", function()
    test("a model storing nothing holds its decal", function()
      local from, finish = fade({})

      expect(from).toBe(nil)
      expect(finish).toBe(nil)
    end)

    test("an old start stored alone, under any spelling, fades to clear", function()
      for _, name in { "Decal_StartTransparency", "DecalStartTransparency", "StartTransparency" } do
        local from, finish = fade({ [name] = 0.2 })

        expect(from).toBe(0.2)
        expect(finish).toBe(1)
      end
    end)

    test("an end the model stores wins over the clear an old start implies", function()
      local _, finish = fade({ Decal_StartTransparency = 0, EndTransparency = 0 })
      local _, named = fade({ DecalStartTransparency = 0, Decal_EndTransparency = 0.5 })
      local from, alone = fade({ DecalEndTransparency = 0.3 })

      expect(finish).toBe(0)
      expect(named).toBe(0.5)
      expect(from).toBe(nil)
      expect(alone).toBe(0.3)
    end)

    test("an old flipbook or a start wearing no decal reads the old pair as the mesh's", function()
      local from, finish = fade({ Flipbook = true, StartTransparency = 0.4, EndTransparency = 0 })
      local _, bare = fade({ StartTransparency = 0.4 }, false)

      expect(from).toBe(nil)
      expect(finish).toBe(1)
      expect(bare).toBe(1)
    end)

    test("a number stored as text reads as the number", function()
      local from, finish = fade({ Decal_StartTransparency = "0.25" })

      expect(from).toBe(0.25)
      expect(finish).toBe(1)
    end)
  end)
end)
