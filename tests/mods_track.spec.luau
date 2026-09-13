local mods = require("@mod/mods")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Vector3 = harness.datatypes.Vector3
local Instance = harness.datatypes.Instance

frame.configure(harness.fakeEncoding, harness.fakeCompression)

local EPSILON = 1e-9

local function near(a: number, b: number): boolean
  return math.abs(a - b) < EPSILON
end

local function tween(startV: any, finishV: any, duration: number?)
  return { kind = "tween", chain = false, duration = duration, start = value.lit(startV), finish = value.lit(finishV) }
end

local function delay(wait: number)
  return { kind = "delay", chain = false, wait = value.lit(wait) }
end

local function authored(name: string, queue: { any })
  local obj = Instance.new("Attachment")
  obj:SetAttribute(mods.attrName("attribute", name), frame.frame(codec.encode({ v = 1, queue = queue })))

  return obj
end

harness.suite(function()
  test("nothing authored is a constant default over the lent span", function()
    local obj = Instance.new("Attachment")
    local track = mods.track(obj, "attribute", "Width", 3, 2)

    expect(track.animated).toBe(false)
    expect(track.span).toBe(2)
    expect(track.at(0)).toBe(3)
    expect(track.at(99)).toBe(3)
  end)

  test("an authored queue animates over its own reach", function()
    local obj = authored("Width", { tween(0, 10, 4) })
    local track = mods.track(obj, "attribute", "Width", 3, 2)

    expect(track.animated).toBe(true)
    expect(track.span).toBe(4)
    expect(near(track.at(0), 0)).toBe(true)
    expect(near(track.at(2), 5)).toBe(true)
    expect(near(track.at(4), 10)).toBe(true)
  end)

  test("a queue that names no duration runs over the lent span", function()
    local obj = authored("Width", { tween(0, 10) })
    local track = mods.track(obj, "attribute", "Width", 3, 2)

    expect(track.span).toBe(2)
    expect(near(track.at(1), 5)).toBe(true)
  end)

  test("sampling past the span holds the end value", function()
    local obj = authored("Width", { tween(0, 10, 4) })
    local track = mods.track(obj, "attribute", "Width", 3, 2)

    expect(near(track.at(40), 10)).toBe(true)
  end)

  test("a queue that only waits is the constant default", function()
    local obj = authored("Width", { delay(1) })
    local track = mods.track(obj, "attribute", "Width", 3, 2)

    expect(track.animated).toBe(false)
    expect(track.at(0)).toBe(3)
  end)

  test("a type mismatch falls back to the default and warns once", function()
    local obj = authored("Width", { tween(Vector3.new(0, 0, 0), Vector3.new(1, 1, 1), 1) })

    local warnings = harness.captureWarnings(function()
      local first = mods.track(obj, "attribute", "Width", 3, 2)
      local second = mods.track(obj, "attribute", "Width", 3, 2)

      expect(first.animated).toBe(false)
      expect(first.at(0)).toBe(3)
      expect(second.animated).toBe(false)
    end)

    expect(#warnings).toBe(1)
  end)

  test("a default given as a queue runs when nothing is authored", function()
    local obj = Instance.new("Attachment")
    local track = mods.track(obj, "attribute", "SpinSpeed", { tween(0, 1) }, 0.5)

    expect(track.animated).toBe(true)
    expect(track.span).toBe(0.5)
    expect(near(track.at(0), 0)).toBe(true)
    expect(near(track.at(0.5), 1)).toBe(true)
  end)

  test("an authored queue wins over a default queue", function()
    local obj = authored("SpinSpeed", { tween(2, 4, 1) })
    local track = mods.track(obj, "attribute", "SpinSpeed", { tween(0, 1) }, 0.5)

    expect(track.span).toBe(1)
    expect(near(track.at(0), 2)).toBe(true)
  end)

  test("a mismatch against a queue default runs the default queue", function()
    local obj = authored("Size", { tween(1, 2, 1) })

    local warnings = harness.captureWarnings(function()
      local track = mods.track(obj, "attribute", "Size", mods.draw(Vector3.new(1, 1, 1), Vector3.new(1, 1, 1)), 2)

      expect(track.animated).toBe(true)
      expect(track.at(0)).toEqual(Vector3.new(1, 1, 1))
    end)

    expect(#warnings).toBe(1)
  end)

  test("draw is one value for the life of the track", function()
    local obj = Instance.new("Attachment")
    local track = mods.track(obj, "attribute", "Lifetime", mods.draw(2, 3), 3)
    local first = track.at(0)

    expect(first >= 2 and first <= 3).toBe(true)
    expect(track.at(7)).toBe(first)
  end)

  test("ramp is a value when both ends agree", function()
    expect(mods.ramp(2, 2)).toBe(2)
  end)

  test("ramp is a queue when the ends differ, and runs over the lent span", function()
    local obj = Instance.new("Attachment")
    local track = mods.track(obj, "attribute", "Width", mods.ramp(0, 4), 2)

    expect(track.animated).toBe(true)
    expect(track.span).toBe(2)
    expect(near(track.at(0), 0)).toBe(true)
    expect(near(track.at(2), 4)).toBe(true)
  end)

  test("a legacy quad reads through the same door", function()
    local obj = Instance.new("Attachment")
    obj:SetAttribute("Width_Start", 1)
    obj:SetAttribute("Width_End", 3)
    obj:SetAttribute("Width_Duration", 2)

    local track = mods.track(obj, "attribute", "Width", 0, 5)

    expect(track.animated).toBe(true)
    expect(track.span).toBe(2)
    expect(near(track.at(0), 1)).toBe(true)
    expect(near(track.at(2), 3)).toBe(true)
  end)
end)
