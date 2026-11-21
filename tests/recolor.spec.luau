local attr = require("@mod/attributes")
local knob = require("@mod/knob")
local mesh = require("@vfx/mesh")
local harness = require("@tests/harness")
local recolor = require("@mod/recolor")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect
local Color3 = harness.datatypes.Color3
local Instance = harness.datatypes.Instance
local ColorSequence = harness.datatypes.ColorSequence

local WHITE = Color3.new(1, 1, 1)
local RED = Color3.new(1, 0, 0)
local BLUE = Color3.new(0, 0, 1)

local function noop() end

-- the bolt's own shape: color rows that are sequences, one of them under an
-- old spelling, beside a flat color row and a row of another kind
local function boltLike()
  registry.clear()
  registry.configure({ query = harness.query })
  registry.register({
    id = "lightning",
    display = { name = "Lightning" },
    classifier = "Attachment",
    attributes = {
      Rate = knob(15),
      Tint = knob(WHITE),
      Color = knob(ColorSequence.new(WHITE)),
      FillColor = knob(ColorSequence.new(WHITE)):aliases("Fill_Color"),
    },
    properties = {},
    emit = noop,
  })
end

local function bolt(key: string, authored: any): Instance
  local obj = Instance.new("Attachment")
  obj:SetAttribute(key, authored)

  return obj
end

-- the color a row reads as, whichever kind it holds, through the read every
-- other reader on this path uses
local function colorOf(obj: Instance, name: string): Color3
  local current = attr.get(obj, name, nil, true)

  if typeof(current) == "ColorSequence" then
    return current.Keypoints[1].Value
  end

  return current
end

local function same(a: Color3, b: Color3): boolean
  return a.R == b.R and a.G == b.G and a.B == b.B
end

harness.suite(function()
  harness.describe("recolor rows", function()
    test("a replaced sequence row reads as the new color, cached or live", function()
      boltLike()

      local live = bolt("Color", ColorSequence.new(RED))
      local cached = bolt("Color", ColorSequence.new(RED))

      attr.cache(cached)

      recolor(BLUE, "replace", live)
      recolor(BLUE, "replace", cached)

      expect(same(colorOf(live, "Color"), BLUE)).toBe(true)
      expect(same(colorOf(cached, "Color"), BLUE)).toBe(true)
      expect(cached:GetAttribute("Color")).toBe(nil)
    end)

    test("a multiplied sequence row reads the same value cached or live", function()
      boltLike()

      local live = bolt("Color", ColorSequence.new(RED))
      local cached = bolt("Color", ColorSequence.new(RED))

      attr.cache(cached)

      recolor(BLUE, "multiply", live)
      recolor(BLUE, "multiply", cached)

      expect(same(colorOf(live, "Color"), RED)).toBe(false)
      expect(same(colorOf(cached, "Color"), colorOf(live, "Color"))).toBe(true)
      expect(cached:GetAttribute("Color")).toBe(nil)
    end)

    test("a flat color row is replaced and multiplied the same way", function()
      boltLike()

      local replaced = bolt("Tint", RED)
      local multiplied = bolt("Tint", RED)

      attr.cache(replaced)
      attr.cache(multiplied)

      recolor(BLUE, "replace", replaced)
      recolor(BLUE, "multiply", multiplied)

      expect(same(colorOf(replaced, "Tint"), BLUE)).toBe(true)
      expect(same(colorOf(multiplied, "Tint"), RED)).toBe(false)
      expect(typeof(attr.get(multiplied, "Tint", nil, true))).toBe("Color3")
    end)

    test("a row authored under an old spelling is recolored where it was authored", function()
      boltLike()

      local obj = bolt("Fill_Color", ColorSequence.new(RED))

      attr.cache(obj)
      recolor(BLUE, "replace", obj)

      expect(same(colorOf(obj, "Fill_Color"), BLUE)).toBe(true)
      expect(attr.get(obj, "FillColor", nil, true)).toBe(nil)
    end)

    test("a row nothing authored is recolored from its default, and a plain row is left alone", function()
      boltLike()

      local obj = bolt("Rate", 30)

      attr.cache(obj)
      recolor(BLUE, "replace", obj)

      expect(same(colorOf(obj, "Color"), BLUE)).toBe(true)
      expect(same(colorOf(obj, "Tint"), BLUE)).toBe(true)
      expect(attr.get(obj, "Rate", nil, true)).toBe(30)
    end)

    test("a row declared :recolor(false) keeps its color", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register({
        id = "outlined",
        display = { name = "Outlined" },
        classifier = "Attachment",
        attributes = {
          Tint = knob(RED),
          Outline = knob(RED):recolor(false),
        },
        properties = {},
        emit = noop,
      })

      local obj = bolt("Outline", RED)

      attr.cache(obj)
      recolor(BLUE, "replace", obj)

      expect(same(colorOf(obj, "Tint"), BLUE)).toBe(true)
      expect(same(colorOf(obj, "Outline"), RED)).toBe(true)
    end)

    test("a legacy mesh's Start and End parts are recolored, any other part under the root is not", function()
      registry.clear()
      registry.configure({ query = harness.query })
      registry.register(mesh)

      local root = harness.make("Folder")
      local model = harness.make("Model", root)
      local start = harness.make("Part", model) :: any
      local goal = harness.make("Part", model) :: any
      local other = harness.make("Part", model) :: any
      local loose = harness.make("Part", harness.make("Model", root)) :: any

      start.Name = "Start"
      goal.Name = "End"
      loose.Name = "Start"

      for _, part in { start, goal, other, loose } do
        part.Color = RED
      end

      recolor(BLUE, "replace", root)

      expect(same(start.Color, BLUE)).toBe(true)
      expect(same(goal.Color, BLUE)).toBe(true)
      expect(same(other.Color, RED)).toBe(true)
      expect(same(loose.Color, RED)).toBe(true)
    end)

    test("a descendant of a recolored root is classified and recolored too", function()
      boltLike()

      local root = Instance.new("Folder")
      local obj = bolt("Color", ColorSequence.new(RED))
      obj.Parent = root

      attr.cache(obj)
      recolor(BLUE, "replace", root)

      expect(same(colorOf(obj, "Color"), BLUE)).toBe(true)
    end)
  end)
end)
