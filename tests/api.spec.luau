local clock = require("@mod/clock")
local harness = require("@tests/harness")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect

-- the api registers every built-in when it first loads, so the registry is
-- emptied first and left empty for whichever spec runs next
local function api()
  registry.clear()

  local loaded = require("@root")

  registry.clear()

  return loaded :: any
end

harness.suite(function()
  harness.describe("the global speed functions", function()
    test("read and write the global clock, a pause leaving the speed as it was", function()
      local vfx = api()

      expect(vfx.getSpeed()).toBe(1)
      expect(vfx.isPaused()).toBe(false)
      expect(vfx.getEffectiveSpeed()).toBe(1)

      vfx.setSpeed(0.5)

      expect(vfx.getSpeed()).toBe(0.5)
      expect(vfx.getEffectiveSpeed()).toBe(0.5)
      expect(clock.global.speed).toBe(0.5)

      vfx.pause()

      expect(vfx.isPaused()).toBe(true)
      expect(vfx.getSpeed()).toBe(0.5)
      expect(vfx.getEffectiveSpeed()).toBe(0.5)
      expect(clock.global.paused).toBe(true)

      vfx.resume()
      vfx.setSpeed(1)

      expect(vfx.isPaused()).toBe(false)
      expect(vfx.getEffectiveSpeed()).toBe(1)
    end)

    test("getEffectiveSpeed counts every Global controller", function()
      local vfx = api()

      clock.scale(clock.global, "a", 0.5)
      clock.scale(clock.global, "b", 0.5)

      expect(vfx.getEffectiveSpeed()).toBe(0.25)
      expect(vfx.getSpeed()).toBe(1)

      clock.unscale(clock.global, "a")
      clock.unscale(clock.global, "b")
    end)

    test("refuses a speed that is not a finite number of 0 or more, naming setSpeed", function()
      local vfx = api()

      vfx.setSpeed(0.5)

      for _, bad in { -1, 0 / 0, math.huge, "fast" :: any } do
        local ok, err = pcall(vfx.setSpeed, bad)

        expect(ok).toBe(false)
        expect(string.find(tostring(err), "setSpeed", 1, true) ~= nil).toBe(true)
      end

      expect(vfx.getSpeed()).toBe(0.5)

      vfx.setSpeed(1)
    end)

    test("a second pause or resume changes nothing and fires nothing", function()
      local vfx = api()
      local heard = {}

      local connection = vfx.PausedChanged:Connect(function(paused: boolean)
        table.insert(heard, paused)
      end)

      vfx.pause()
      vfx.pause()

      expect(vfx.isPaused()).toBe(true)

      vfx.resume()
      vfx.resume()

      connection:Disconnect()

      expect(vfx.isPaused()).toBe(false)
      expect(heard).toEqual({ true, false })
    end)

    test("the signals are the clock's, and the api table is a plain one", function()
      local vfx = api()

      expect(vfx.SpeedChanged).toBe(clock.speedChanged)
      expect(vfx.PausedChanged).toBe(clock.pausedChanged)
      expect(getmetatable(vfx)).toBe(nil)
    end)
  end)
end)
