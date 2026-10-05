local harness = require("@tests/harness")
local mover = require("@srv/mover")
local scheduler = require("@mod/scheduler")

local test, expect = harness.test, harness.expect
local CFrame = harness.datatypes.CFrame

local original = mover.bulk

-- every test that stands a batch in puts the harness's back when it ends
local function capture(): { { parts: { any }, cframes: { any } } }
  local batches = {}

  mover.bulk = function(parts: { any }, cframes: { any })
    table.insert(batches, { parts = table.clone(parts), cframes = table.clone(cframes) })
  end

  return batches
end

harness.suite(function()
  harness.describe("the mover", function()
    test("the last write before a flush wins, in one batch", function()
      local batches = capture()
      local part = harness.make("Part")

      mover.move(nil, part, CFrame.new(1, 0, 0))
      mover.move(nil, part, CFrame.new(2, 0, 0))
      mover.flush()

      expect(#batches).toBe(1)
      expect(#batches[1].parts).toBe(1)
      expect(batches[1].cframes[1]).toBe(CFrame.new(2, 0, 0))
      mover.clear()
    end)

    test("a flush with nothing pending sends nothing", function()
      local batches = capture()

      mover.flush()

      expect(#batches).toBe(0)
    end)

    test("a write from the old holder is ignored", function()
      local batches = capture()
      local part = harness.make("Part")
      local first, second = {}, {}

      mover.assign(part, second)
      mover.move(first, part, CFrame.new(5, 0, 0))
      mover.move(second, part, CFrame.new(6, 0, 0))
      mover.flush()

      expect(batches[1].cframes[1]).toBe(CFrame.new(6, 0, 0))
      mover.clear()
    end)

    test("a part with no holder moves for anyone", function()
      local batches = capture()
      local part = harness.make("Part")

      mover.move({}, part, CFrame.new(3, 0, 0))
      mover.flush()

      expect(batches[1].cframes[1]).toBe(CFrame.new(3, 0, 0))
    end)

    test("a release drops the pending write", function()
      local batches = capture()
      local part = harness.make("Part")
      local holder = {}

      mover.assign(part, holder)
      mover.move(holder, part, CFrame.new(4, 0, 0))
      mover.drop(part)
      mover.flush()

      expect(#batches).toBe(0)
    end)

    test("cframe answers the pending write, else the part's own", function()
      capture()
      local part = harness.make("Part")
      part.CFrame = CFrame.new(9, 0, 0)

      expect(mover.cframe(part)).toBe(CFrame.new(9, 0, 0))
      mover.move(nil, part, CFrame.new(1, 2, 3))
      expect(mover.cframe(part)).toBe(CFrame.new(1, 2, 3))
      mover.clear()
    end)

    test("a non-part is refused and never reaches a batch", function()
      local batches = capture()
      local warnings = harness.captureWarnings(function()
        mover.move(nil, harness.make("Folder") :: any, CFrame.new())
      end)

      mover.flush()

      expect(#warnings).toBe(1)
      expect(#batches).toBe(0)
    end)

    test("a batch that throws is dropped, and the next flush still runs", function()
      local part = harness.make("Part")
      local sent = 0

      mover.bulk = function()
        sent += 1
        error("engine refused")
      end

      harness.captureWarnings(function()
        mover.move(nil, part, CFrame.new())
        mover.flush()
        mover.move(nil, part, CFrame.new())
        mover.flush()
      end)

      expect(sent).toBe(2)
    end)

    test("the late pass flushes", function()
      local batches = capture()
      local part = harness.make("Part")

      mover.move(nil, part, CFrame.new(7, 0, 0))
      scheduler.late(1 / 60)

      expect(#batches).toBe(1)
    end)

    harness.test("the harness's batch is put back", function()
      mover.bulk = original
      mover.clear()
    end)
  end)
end)
