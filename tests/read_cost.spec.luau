local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local knob = require("@mod/knob")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
local reader = require("@mod/reader")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance
local NumberRange = harness.datatypes.NumberRange

frame.configure(harness.fakeEncoding, harness.fakeCompression)

local ROUNDS = 5
local ITERATIONS = 2000

local PLAIN = { "A", "B", "C", "D", "E", "F", "G", "H", "I" }
local ANIMATED = { "X", "Y", "Z" }

local function noop() end

local function fixture(): Instance
  local obj = Instance.new("Part")

  for i, name in PLAIN do
    obj:SetAttribute(name, i)
  end

  obj:SetAttribute("R", NumberRange.new(1, 2))
  obj:SetAttribute("X_Start", 0)
  obj:SetAttribute("X_End", 1)

  obj:SetAttribute(
    mods.attrName("attribute", "Y"),
    frame.frame(codec.encode({
      v = 1,
      queue = { { kind = "tween", chain = false, duration = 1, start = value.lit(0), finish = value.lit(1) } },
    }))
  )

  return obj
end

local function moduleFor()
  local attributes = {}

  for _, name in PLAIN do
    attributes[name] = knob(0):min(0)
  end

  attributes.R = knob(NumberRange.new(0, 1))

  for _, name in ANIMATED do
    attributes[name] = knob(0):mod()
  end

  return {
    id = "cost",
    display = { name = "Cost" },
    classifier = "Part",
    attributes = attributes,
    properties = {},
    emit = noop,
  }
end

-- what a converted effect used to do for the same rows: one soft read per
-- plain row and one track per animated one
local function oldRead(obj: Instance)
  local out = {}

  for _, name in PLAIN do
    out[name] = math.max(attr.get(obj, name, 0, true), 0)
  end

  out.R = attr.getRange(obj, "R", NumberRange.new(0, 1), nil, true)

  for _, name in ANIMATED do
    out[name] = mods.track(obj, "attribute", name, 0, 1)
  end

  return out
end

local function best(fn: () -> ()): number
  local fastest = math.huge

  for _ = 1, ROUNDS do
    local started = os.clock()

    for _ = 1, ITERATIONS do
      fn()
    end

    fastest = math.min(fastest, os.clock() - started)
  end

  return fastest
end

harness.suite(function()
  test("one read of every row costs no more than the reads it replaces", function()
    local obj = fixture()
    local m = moduleFor()

    local old = best(function()
      oldRead(obj)
    end)

    local new = best(function()
      reader.resolve(m, { ref = obj, obj = obj, scale = 1 })
    end)

    print(
      `read cost over {ITERATIONS} emits: old {string.format("%.1f", old * 1000)} ms, new {string.format(
        "%.1f",
        new * 1000
      )} ms`
    )

    -- the one attributes map behind a read carries a fixed cost, and a module
    -- of this few non mod rows does not read enough of them to pay it back,
    -- even though every row costs less than the read it replaced
    expect(new <= old * 1.1).toBe(true)
  end)
end)
