local mods = require("@mod/mods")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local value = require("@mod/value")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Vector3 = harness.datatypes.Vector3
local NumberRange = harness.datatypes.NumberRange

frame.configure(harness.fakeEncoding, harness.fakeCompression)

local function tween(startV: any, finishV: any, duration: number?)
  return { kind = "tween", chain = false, duration = duration, start = value.lit(startV), finish = value.lit(finishV) }
end

harness.suite(function()
  test("scaleTime scales durations and waits in every lane", function()
    local lanes = {
      start = { tween(0, 1, 2) },
      ["end"] = { { kind = "delay", chain = false, wait = value.lit(1) }, tween(0, 1, 4) },
      dissipate = { { kind = "delay", chain = false, wait = value.draw(1, 3) } },
    }

    mods.scaleTime(lanes, 0.5)

    expect(lanes.start[1].duration).toBe(1)
    expect(lanes["end"][2].duration).toBe(2)
    expect(lanes["end"][1].wait.v).toBe(0.5)
    expect(lanes.dissipate[1].wait.a).toBe(0.5)
    expect(lanes.dissipate[1].wait.b).toBe(1.5)
  end)

  test("scaleTime scales a wait written as a plain number", function()
    local lanes = { start = { { kind = "delay", chain = false, wait = 2 } } }

    mods.scaleTime(lanes, 0.5)

    expect(lanes.start[1].wait).toBe(1)
  end)

  test("scaleTime scales a carried speed ramp's duration", function()
    local lanes = { start = { tween(0, 1, 2) } }
    lanes.start[1].speed = { start = 1, finish = 2, duration = 0.4, curve = "" }

    mods.scaleTime(lanes, 0.5)

    expect(lanes.start[1].speed.duration).toBe(0.2)
  end)

  test("scaleTime leaves an unnamed duration alone", function()
    local lanes = { start = { tween(0, 1) } }

    mods.scaleTime(lanes, 0.5)

    expect(lanes.start[1].duration).toBe(nil)
  end)

  test("scaleValues scales numeric endpoints of every shape in every lane", function()
    local lanes = {
      start = {
        tween(1, 2, 1),
        tween(Vector3.new(1, 2, 3), Vector3.new(2, 4, 6)),
        tween(NumberRange.new(1, 2), NumberRange.new(3, 4)),
        { kind = "tween", chain = false, start = value.draw(1, 2), finish = value.var("x") },
      },
      dissipate = { tween(5, 6, 1) },
    }

    mods.scaleValues(lanes, 2)

    expect(lanes.start[1].start.v).toBe(2)
    expect(lanes.start[1].finish.v).toBe(4)
    expect(lanes.start[2].start.v).toEqual(Vector3.new(2, 4, 6))
    expect(lanes.start[3].finish.v.Min).toBe(6)
    expect(lanes.start[4].start.a).toBe(2)
    expect(lanes.start[4].start.b).toBe(4)
    expect(lanes.start[4].finish.t).toBe("var")
    expect(lanes.dissipate[1].start.v).toBe(10)
  end)

  test("scaleValues leaves a non-numeric endpoint alone", function()
    local lanes = { start = { tween(true, false, 1) } }

    mods.scaleValues(lanes, 2)

    expect(lanes.start[1].start.v).toBe(true)
  end)

  test("recode round-trips a framed lane map through an edit", function()
    local payload = { v = 2, lanes = { start = { tween(0, 1, 2) }, ["end"] = { tween(1, 0, 4) } } }
    local raw = frame.frame(codec.encode(payload))

    local out = mods.recode(raw, function(lanes)
      mods.scaleTime(lanes, 0.5)
    end)

    expect(out ~= nil).toBe(true)

    local decoded = codec.decode(frame.unframe(out) :: buffer)

    expect(decoded.v).toBe(2)
    expect(decoded.lanes.start[1].duration).toBe(1)
    expect(decoded.lanes["end"][1].duration).toBe(2)
  end)

  test("recode refuses anything that is not a framed queue", function()
    expect(mods.recode(3, function() end)).toBe(nil)
    expect(mods.recode("plain", function() end)).toBe(nil)
  end)

  test("recode applies the edit to a payload whose only lane is an event lane", function()
    local payload = { v = 2, lanes = { dissipate = { tween(0, 1, 2) } } }
    local raw = frame.frame(codec.encode(payload))

    local out = mods.recode(raw, function(lanes)
      mods.scaleTime(lanes, 0.5)
    end)

    expect(out ~= nil).toBe(true)

    local decoded = codec.decode(frame.unframe(out) :: buffer)

    expect(decoded.lanes.dissipate[1].duration).toBe(1)
  end)
end)
