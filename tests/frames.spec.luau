local harness = require("@tests/harness")
local frames_common = require("@mod/common/frames")
local test, expect = harness.test, harness.expect
local Vector3 = harness.datatypes.Vector3

harness.suite(function()
  harness.describe("frames", function()
    test("index runs one to count and holds the ends", function()
      expect(frames_common.index(24, 0)).toBe(1)
      expect(frames_common.index(24, 0.5)).toBe(12)
      expect(frames_common.index(24, 1)).toBe(24)
      expect(frames_common.index(24, 1.2)).toBe(24)
      expect(frames_common.index(0, 0.5)).toBe(0)
    end)

    test("fit scales a frame's box by the piece over the union", function()
      const union = { size = Vector3.new(4, 2, 2), center = Vector3.new(0, 1, 0) }
      const frame = { size = Vector3.new(2, 2, 2), center = Vector3.new(1, 1, 0) }
      const size, offset = frames_common.fit(frame, union, Vector3.new(8, 2, 2))
      expect(size).toEqual(Vector3.new(4, 2, 2))
      expect(offset).toEqual(Vector3.new(2, 0, 0))
    end)

    test("fit without bounds keeps the piece's size", function()
      const size, offset = frames_common.fit(nil, nil, Vector3.new(3, 3, 3))
      expect(size).toEqual(Vector3.new(3, 3, 3))
      expect(offset).toEqual(Vector3.zero)
    end)

    test("fit treats a flat union axis as ratio one", function()
      const union = { size = Vector3.new(2, 0, 2), center = Vector3.zero }
      const frame = { size = Vector3.new(2, 0, 2), center = Vector3.zero }
      const size = frames_common.fit(frame, union, Vector3.new(4, 1, 4))
      expect(size).toEqual(Vector3.new(4, 0, 4))
    end)

    test("order skips names that are not whole numbers", function()
      const root = harness.make("Model")
      const named = {}

      for _, name in { "10", "2", "x", "0", "1.5", "1" } do
        const part = harness.make("Part", root)
        part.Name = name
        named[name] = part
      end

      const ordered = frames_common.order(root:GetChildren())
      expect(#ordered).toBe(3)
      expect(ordered[1]).toBe(named["1"])
      expect(ordered[2]).toBe(named["2"])
      expect(ordered[3]).toBe(named["10"])
    end)

    test("evict lets the oldest go first until within budget", function()
      const a = { textures = 48, used = 1, lent = 0, parked = true }
      const b = { textures = 48, used = 2, lent = 0, parked = true }
      const c = { textures = 48, used = 3, lent = 0, parked = true }
      expect(frames_common.evict({ c, a, b }, 100, nil)).toEqual({ a })
    end)

    test("evict skips a lent entry, the kept one and unparked ones", function()
      const a = { textures = 64, used = 1, lent = 1, parked = true }
      const b = { textures = 64, used = 2, lent = 0, parked = true }
      const c = { textures = 64, used = 3, lent = 0, parked = false }
      expect(frames_common.evict({ a, b, c }, 64, b)).toEqual({})
    end)

    test("evict never lets go of an entry that holds no textures", function()
      const empty = { textures = 0, used = 0, lent = 0, parked = true }
      const a = { textures = 64, used = 1, lent = 0, parked = true }
      const b = { textures = 64, used = 2, lent = 0, parked = true }
      expect(frames_common.evict({ b, a, empty }, 64, nil)).toEqual({ a })
      expect(frames_common.evict({ empty }, 0, nil)).toEqual({})
    end)

    test("order keeps a gap and drops nothing", function()
      const root = harness.make("Model")
      const one, three = harness.make("Part", root), harness.make("Part", root)

      one.Name, three.Name = "1", "3"

      expect(frames_common.order(root:GetChildren())).toEqual({ one, three })
    end)

    test("order is stable on a tie", function()
      const root = harness.make("Model")
      const padded, plain = harness.make("Part", root), harness.make("Part", root)

      padded.Name, plain.Name = "01", "1"

      const ordered = frames_common.order(root:GetChildren())
      expect(ordered[1]).toBe(padded)
      expect(ordered[2]).toBe(plain)
    end)

    test("evict breaks a tie in used by order seen", function()
      const a = { textures = 48, used = 1, lent = 0, parked = true }
      const b = { textures = 48, used = 1, lent = 0, parked = true }
      const c = { textures = 48, used = 1, lent = 0, parked = true }
      const gone = frames_common.evict({ a, b, c }, 48, nil)
      expect(#gone).toBe(2)
      expect(gone[1]).toBe(a)
      expect(gone[2]).toBe(b)
    end)
  end)
end)
