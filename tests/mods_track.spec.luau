local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
local curves = require("@mod/curves")
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

-- a curve is a binary string, which an instance under this harness cannot hold
-- as an attribute. the cache carries raw values and every reader looks there
-- first, so it is the one place a spec can author one
local function setCurve(obj: Instance, name: string, curve: string)
  obj:SetAttribute(name, "")
  attr.cache(obj)
  attr.set(obj, name, curve)
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

  test("a queue that moves nothing is the constant default", function()
    local obj = authored("Width", { { kind = "sequence", chain = false } })
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

  test("a native vector default and a Vector3 queue are one kind", function()
    local obj = authored("Size", { tween(Vector3.new(0, 0, 0), Vector3.new(2, 2, 2), 1) })

    local warnings = harness.captureWarnings(function()
      local track = mods.track(obj, "attribute", "Size", vector.create(0, 0, 0), 2)

      expect(track.animated).toBe(true)
      expect(track.at(1)).toEqual(Vector3.new(2, 2, 2))
    end)

    expect(#warnings).toBe(0)
  end)

  test("a default given as a lane runs when nothing is authored", function()
    local obj = Instance.new("Attachment")
    local track = mods.track(obj, "attribute", "SpinSpeed", { start = { tween(0, 1) } }, 0.5)

    expect(track.animated).toBe(true)
    expect(track.span).toBe(0.5)
    expect(near(track.at(0), 0)).toBe(true)
    expect(near(track.at(0.5), 1)).toBe(true)
  end)

  test("an authored queue wins over a default lane", function()
    local obj = authored("SpinSpeed", { tween(2, 4, 1) })
    local track = mods.track(obj, "attribute", "SpinSpeed", { start = { tween(0, 1) } }, 0.5)

    expect(track.span).toBe(1)
    expect(near(track.at(0), 2)).toBe(true)
  end)

  test("a mismatch against a queue default runs the default queue", function()
    local obj = authored("Size", { tween(1, 2, 1) })

    local warnings = harness.captureWarnings(function()
      local track = mods.track(obj, "attribute", "Size", mods.draw(Vector3.new(1, 1, 1), Vector3.new(1, 1, 1)), 2)

      -- a draw between two equal corners holds one value, so it is not animated
      expect(track.animated).toBe(false)
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

  test("a cached instance still answers its legacy quad", function()
    local obj = Instance.new("Attachment")
    obj:SetAttribute("Width_Start", 2)
    obj:SetAttribute("Width_End", 8)
    attr.cache(obj)

    expect(obj:GetAttribute("Width_Start")).toBe(nil)

    local track = mods.track(obj, "attribute", "Width", 1, 1)

    expect(track.animated).toBe(true)
    expect(track.at(0)).toBe(2)
    expect(track.at(1)).toBe(8)
  end)

  test("a cached instance still answers its framed queue", function()
    local obj = authored("Width", { tween(0, 4, 1) })
    attr.cache(obj)

    local track = mods.track(obj, "attribute", "Width", 1, 1)

    expect(track.animated).toBe(true)
    expect(track.at(1)).toBe(4)
  end)

  test("a curve alone eases the default ramp", function()
    local obj = Instance.new("Attachment")
    setCurve(obj, "Width_Curve", curves.linear())

    local track = mods.track(obj, "attribute", "Width", mods.ramp(0, 10), 1)

    expect(track.animated).toBe(true)
    expect(near(track.at(0.5), 5)).toBe(true)
  end)

  test("a curve alone leaves a constant default alone", function()
    local obj = Instance.new("Attachment")
    setCurve(obj, "Width_Curve", curves.linear())

    local track = mods.track(obj, "attribute", "Width", 3, 1)

    expect(track.animated).toBe(false)
    expect(track.at(0)).toBe(3)
  end)

  -- the old row said where the value ends; where it starts was a seed for a
  -- target that carried nothing of its own, which is the effect's to know
  test("an effect that owns the start completes an old quad from its default", function()
    local obj = Instance.new("Attachment")
    obj:SetAttribute("Width_Start", 5)
    obj:SetAttribute("Width_End", 8)

    local track = mods.track(obj, "attribute", "Width", mods.ramp(1, 8), 1, nil, { ownStart = true })

    expect(track.animated).toBe(true)
    expect(near(track.at(0), 1)).toBe(true)
    expect(near(track.at(1), 8)).toBe(true)
  end)

  -- a row that named no end was a seed too, so both of its ends come from the
  -- default and only its duration and curve survive
  test("an effect that owns the start completes a start-only old quad from its default", function()
    local obj = Instance.new("Attachment")
    obj:SetAttribute("Width_Start", 0.3)

    local track = mods.track(obj, "attribute", "Width", mods.ramp(0.7, 1), 1, nil, { ownStart = true })

    expect(track.animated).toBe(true)
    expect(near(track.at(0), 0.7)).toBe(true)
    expect(near(track.at(1), 1)).toBe(true)
  end)

  test("a framed queue keeps its own start when the effect owns it", function()
    local obj = authored("Width", { tween(5, 8, 1) })
    local track = mods.track(obj, "attribute", "Width", mods.ramp(1, 8), 1, nil, { ownStart = true })

    expect(near(track.at(0), 5)).toBe(true)
  end)

  test("build takes the queue it is handed instead of reading one", function()
    local obj = Instance.new("Attachment")
    local track = mods.build(obj, "attribute", "Width", 3, 2, nil, { start = { tween(0, 10, 4) } }, true)

    expect(track.animated).toBe(true)
    expect(track.span).toBe(4)
    expect(near(track.at(2), 5)).toBe(true)
  end)

  test("build with nothing handed in rests", function()
    local obj = Instance.new("Attachment")
    local track = mods.build(obj, "attribute", "Width", 3, 2, nil, nil, false)

    expect(track.animated).toBe(false)
    expect(track.at(0)).toBe(3)
  end)

  test("a default lane led by a delay still lends its ends to a half quad", function()
    local obj = Instance.new("Attachment")
    local queue = { { kind = "tween", chain = false, finish = value.lit(9), partial = "start" } }
    local default = { start = { delay(1), tween(0, 5) } }
    local track = mods.build(obj, "attribute", "Width", default, 2, nil, { start = queue }, false)

    expect(near(track.at(0), 0)).toBe(true)
    expect(near(track.at(2), 9)).toBe(true)
  end)

  test("kindOf reads both vector spellings as one", function()
    expect(mods.kindOf(vector.create(1, 2, 3))).toBe("Vector3")
    expect(mods.kindOf(Vector3.new(1, 2, 3))).toBe("Vector3")
    expect(mods.kindOf(1)).toBe("number")
  end)
end)
