local clock = require("@mod/clock")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

-- a number as a property stores it, single precision
local function f32(v: number): number
  return (string.unpack("f", string.pack("f", v)))
end

-- an engine instance's properties as a plain table that stores numbers the
-- way the engine does
local function instance(values: { [string]: any }): any
  local store = table.clone(values)

  return setmetatable({}, {
    __index = store,
    __newindex = function(_, key: string, v: any)
      store[key] = if type(v) == "number" then f32(v) else v
    end,
  })
end

local function effect(): (lifetime.emit, lifetime.effect)
  local emit = lifetime.emit(nil)

  return emit, lifetime.effect(emit, 0, nil)
end

local function done(emit: lifetime.emit)
  lifetime.clear(emit)
end

harness.suite(function()
  harness.describe("a writer", function()
    test("joins at its first set, and the last to leave puts the value back", function()
      local emit, fx = effect()
      local obj = instance({ Transparency = 0.25 })
      local w = lifetime.write(fx, obj, "property", "Transparency")

      expect(lifetime.writing(obj, "property", "Transparency")).toBe(0)
      expect(lifetime.restoreOf(obj, "property", "Transparency")).toBe(nil)

      expect(lifetime.set(w, 0.5)).toBe(true)

      expect(lifetime.writing(obj, "property", "Transparency")).toBe(1)
      expect(lifetime.restoreOf(obj, "property", "Transparency")).toBe(0.25)
      expect(obj.Transparency).toBe(0.5)

      done(emit)

      expect(obj.Transparency).toBe(0.25)
      expect(lifetime.writing(obj, "property", "Transparency")).toBe(0)
    end)

    test("that never set owns nothing and puts nothing back", function()
      local first, a = effect()
      local second, b = effect()
      local obj = instance({ Transparency = 0 })

      lifetime.write(a, obj, "property", "Transparency")

      local wb = lifetime.write(b, obj, "property", "Transparency")

      lifetime.set(wb, 0.5)
      done(second)

      expect(obj.Transparency).toBe(0)

      done(first)

      expect(obj.Transparency).toBe(0)
    end)

    test("of two at one priority, the newer owns and the older takes over from where it is", function()
      local first, a = effect()
      local second, b = effect()
      local obj = instance({ Transparency = 0 })
      local wa = lifetime.write(a, obj, "property", "Transparency")
      local wb = lifetime.write(b, obj, "property", "Transparency")

      lifetime.set(wa, 0.2)
      lifetime.set(wb, 0.6)

      expect(obj.Transparency).toBe(f32(0.6))

      lifetime.set(wa, 0.3)

      expect(obj.Transparency).toBe(f32(0.6))

      done(second)

      expect(obj.Transparency).toBe(f32(0.3))

      done(first)

      expect(obj.Transparency).toBe(0)
    end)

    test("of a higher priority owns over a newer one", function()
      local first, a = effect()
      local second, b = effect()
      local obj = instance({ Transparency = 0 })
      local wa = lifetime.write(a, obj, "property", "Transparency")
      local wb = lifetime.write(b, obj, "property", "Transparency")

      first.priority = 5

      lifetime.set(wa, 0.2)
      lifetime.set(wb, 0.6)

      expect(obj.Transparency).toBe(f32(0.2))

      done(first)

      expect(obj.Transparency).toBe(f32(0.6))

      done(second)
    end)

    test("of a one-shot emit owns over a newer ConstantVFX tick at one priority", function()
      local shot, s = effect()
      local tick, t = effect()
      local obj = instance({ Transparency = 0 })
      local ws = lifetime.write(s, obj, "property", "Transparency")
      local wt = lifetime.write(t, obj, "property", "Transparency")

      tick.constant = true

      lifetime.set(ws, 0.4)
      lifetime.set(wt, 0.9)

      expect(obj.Transparency).toBe(f32(0.4))

      done(shot)

      expect(obj.Transparency).toBe(f32(0.9))

      done(tick)
    end)

    test("that owns keeps the target while its clock is paused", function()
      local first, a = effect()
      local second, b = effect()
      local obj = instance({ Transparency = 0 })
      local wa = lifetime.write(a, obj, "property", "Transparency")
      local wb = lifetime.write(b, obj, "property", "Transparency")

      lifetime.set(wa, 0.2)
      lifetime.set(wb, 0.6)

      clock.setPaused(second.clock, true)
      scheduler.frame(0)

      lifetime.set(wa, 0.3)

      expect(obj.Transparency).toBe(f32(0.6))

      done(first)
      done(second)
    end)
  end)

  harness.describe("a target", function()
    test("written by somebody else keeps that value for the end, and the owner keeps writing", function()
      local emit, fx = effect()
      local obj = instance({ Transparency = 0.25 })
      local w = lifetime.write(fx, obj, "property", "Transparency")

      lifetime.set(w, 0.5)

      obj.Transparency = 0.8

      lifetime.set(w, 0.6)

      expect(obj.Transparency).toBe(f32(0.6))

      done(emit)

      expect(obj.Transparency).toBe(f32(0.8))
    end)

    test("written by somebody else after the owner's last write keeps that value", function()
      local emit, fx = effect()
      local obj = instance({ Transparency = 0.25 })
      local w = lifetime.write(fx, obj, "property", "Transparency")

      lifetime.set(w, 0.5)

      obj.Transparency = 0.8

      done(emit)

      expect(obj.Transparency).toBe(f32(0.8))
    end)

    test("read back single precision is not taken for somebody else's write", function()
      local emit, fx = effect()
      local obj = instance({ Transparency = 0.25 })
      local w = lifetime.write(fx, obj, "property", "Transparency")

      lifetime.set(w, 0.1)
      lifetime.set(w, 0.2)

      done(emit)

      expect(obj.Transparency).toBe(0.25)
    end)

    test("an attribute goes back as it was, and one that was not there goes again", function()
      local emit, fx = effect()
      local part = harness.make("Part")

      part:SetAttribute("Glow", 1)

      local glow = lifetime.write(fx, part, "attribute", "Glow")
      local fresh = lifetime.write(fx, part, "attribute", "Fresh")

      lifetime.set(glow, 3)
      lifetime.set(fresh, 2)

      expect(part:GetAttribute("Glow")).toBe(3)
      expect(part:GetAttribute("Fresh")).toBe(2)

      done(emit)

      expect(part:GetAttribute("Glow")).toBe(1)
      expect(part:GetAttribute("Fresh")).toBe(nil)
    end)

    test("that refuses writes answers false, and the leave never throws", function()
      local emit, fx = effect()
      local values = { Transparency = 0 }
      local refusing = false

      local obj = setmetatable({}, {
        __index = values,
        __newindex = function(_, key: string, v: any)
          if refusing then
            error("the instance is gone")
          end

          values[key] = v
        end,
      })

      local w = lifetime.write(fx, obj, "property", "Transparency")

      expect(lifetime.set(w, 0.5)).toBe(true)

      refusing = true

      expect(lifetime.set(w, 0.6)).toBe(false)

      done(emit)

      expect(values.Transparency).toBe(0.5)
    end)
  end)

  harness.describe("an end rule", function()
    test("keep leaves the owner's last value behind", function()
      local emit, fx = effect()
      local obj = instance({ Transparency = 0 })
      local w = lifetime.write(fx, obj, "property", "Transparency", "keep")

      lifetime.set(w, 0.7)
      done(emit)

      expect(obj.Transparency).toBe(f32(0.7))
    end)

    test("start leaves the start value behind", function()
      local emit, fx = effect()
      local obj = instance({ Transparency = 0 })
      local w = lifetime.write(fx, obj, "property", "Transparency", "start", 0.1)

      lifetime.set(w, 0.7)
      done(emit)

      expect(obj.Transparency).toBe(f32(0.1))
    end)

    test("counts only for a writer that leaves owning the target", function()
      local first, a = effect()
      local second, b = effect()
      local obj = instance({ Transparency = 0 })
      local wa = lifetime.write(a, obj, "property", "Transparency", "keep")
      local wb = lifetime.write(b, obj, "property", "Transparency")

      lifetime.set(wa, 0.4)
      lifetime.set(wb, 0.6)

      done(first)
      done(second)

      expect(obj.Transparency).toBe(0)
    end)
  end)

  harness.describe("lifetime.rank", function()
    test("hands a target to the emit it raises at once, and back", function()
      local first, a = effect()
      local second, b = effect()
      local obj = instance({ Transparency = 0 })
      local wa = lifetime.write(a, obj, "property", "Transparency")
      local wb = lifetime.write(b, obj, "property", "Transparency")

      lifetime.set(wa, 0.2)
      lifetime.set(wb, 0.6)

      lifetime.rank(first, 1)

      expect(obj.Transparency).toBe(f32(0.2))

      lifetime.rank(first, 0)

      expect(obj.Transparency).toBe(f32(0.6))

      done(first)
      done(second)
    end)

    test("reaches the emits the ranked one started, which inherit its priority", function()
      local parent = lifetime.emit(nil)

      parent.priority = 3
      parent.constant = true

      local child = lifetime.emit(parent)

      expect(child.priority).toBe(3)
      expect(child.constant).toBe(true)

      lifetime.rank(parent, 7)

      expect(child.priority).toBe(7)

      done(parent)
    end)
  end)
end)
