local mods = require("@mod/mods")
local value = require("@mod/value")
local codec = require("@mod/modifier_codec")
local frame = require("@mod/modifier_frame")
local harness = require("@tests/harness")
local test, expect = harness.test, harness.expect
local Instance = harness.datatypes.Instance
local NumberRange = harness.datatypes.NumberRange

frame.configure(harness.fakeEncoding, harness.fakeCompression)

local function tween(startV: any, finishV: any, duration: number?)
  return { kind = "tween", chain = false, duration = duration, start = value.lit(startV), finish = value.lit(finishV) }
end

local function onward(finishV: any, duration: number?)
  return { kind = "tween", chain = true, duration = duration, finish = value.lit(finishV) }
end

local function built(lanes: { [string]: { any } }, rest: any, span: number, piece: any)
  return mods.build(Instance.new("Attachment"), "attribute", "Width", rest, span, nil, lanes, true, nil, piece)
end

local function authored(name: string, queue: { any })
  local obj = Instance.new("Attachment")
  obj:SetAttribute(mods.attrName("attribute", name), frame.frame(codec.encode({ v = 1, queue = queue })))

  return obj
end

-- a row whose every lane leaves it where it already is has nothing to step: an
-- effect writes it once and opens no stepper, the way the old arms skipped a
-- tween whose ends agreed
harness.suite(function()
  harness.describe("a still track", function()
    test("a tween whose literal ends agree is not animated and still reaches", function()
      local track = built({ start = { tween(5, 5, 2) } }, 3, 4, nil)

      expect(track.animated).toBe(false)
      expect(track.at(0)).toBe(5)
      expect(track.at(1)).toBe(5)
      expect(track.at(4)).toBe(5)
      expect(track.span).toBe(2)
      expect(track.reach("start")).toBe(2)
      expect(track.has("start")).toBe(true)
    end)

    test("a tween whose ends differ animates", function()
      expect(built({ start = { tween(5, 6, 2) } }, 3, 4, nil).animated).toBe(true)
    end)

    test("two still tweens resting at different values animate", function()
      expect(built({ start = { tween(5, 5, 1), tween(7, 7, 1) } }, 3, 4, nil).animated).toBe(true)
    end)

    test("a chained tween to where the row rests is still, to anywhere else animates", function()
      expect(built({ start = { onward(3, 2) } }, 3, 4, nil).animated).toBe(false)
      expect(built({ start = { onward(4, 2) } }, 3, 4, nil).animated).toBe(true)
    end)

    test("an old quad whose halves agree is read as the value it names", function()
      local obj = Instance.new("Attachment")
      obj:SetAttribute("Width_Start", 5)
      obj:SetAttribute("Width_End", 5)

      local track = mods.track(obj, "attribute", "Width", 3, 2)

      expect(track.animated).toBe(false)
      expect(track.at(0)).toBe(5)
      expect(track.at(2)).toBe(5)
    end)

    test("a drawn range whose corners agree is still", function()
      local obj = Instance.new("Attachment")
      obj:SetAttribute("Part_RotSpeed_Start", NumberRange.new(0, 0))
      obj:SetAttribute("Part_RotSpeed_End", NumberRange.new(0, 0))

      local track = mods.track(obj, "attribute", "Part_RotSpeed", 1, 2)

      expect(track.animated).toBe(false)
      expect(track.at(0)).toBe(0)
    end)

    test("a drawn range whose corners differ animates", function()
      local obj = Instance.new("Attachment")
      obj:SetAttribute("Part_RotSpeed_Start", NumberRange.new(0, 1))
      obj:SetAttribute("Part_RotSpeed_End", NumberRange.new(0, 1))

      expect(mods.track(obj, "attribute", "Part_RotSpeed", 1, 2).animated).toBe(true)
    end)

    test("an event lane resting where the start lane does is still, elsewhere it animates", function()
      local piece = mods.piece({ "dissipate" })

      expect(built({ start = { tween(5, 5, 1) }, dissipate = { tween(5, 5, 1) } }, 3, 4, piece).animated).toBe(false)
      expect(built({ start = { tween(5, 5, 1) }, dissipate = { onward(1, 1) } }, 3, 4, piece).animated).toBe(true)
    end)

    test("an authored still queue reads as still through the framed path too", function()
      local track = mods.track(authored("Width", { tween(2, 2, 3) }), "attribute", "Width", 3, 5)

      expect(track.animated).toBe(false)
      expect(track.at(0)).toBe(2)
    end)
  end)
end)
