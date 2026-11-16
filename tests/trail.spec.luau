const attr = require("@mod/attributes")
const harness = require("@tests/harness")
const effects = require("@srv/effects")
const registry = require("@mod/registry")
const scheduler = require("@mod/scheduler")
const flipbook_common = require("@mod/common/flipbook")
const test, expect = harness.test, harness.expect

const trail = require("@vfx/trail")

-- four frames, texture ids 1 to 4
const FRAMES = buffer.tostring(flipbook_common.serialize({ 1, 2, 3, 4 }))

const AUTHORED = "rbxassetid://99"

-- the trail module alone on the effects service, put back once `body` ends
const function staged(body: () -> ())
  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
  registry.register(trail)

  const ok, err = pcall(body)

  registry.clear()

  if not ok then
    error(err, 0)
  end
end

-- a trail resting off, fading over half a second, with `attributes` on it
const function trailOf(attributes: { [string]: any }, parent: Instance?): any
  const t = harness.make("Trail", parent) :: any

  t.Enabled = false
  t.Lifetime = 0.5
  t.Texture = AUTHORED

  for name, v in attributes do
    t:SetAttribute(name, v)
  end

  return t
end

-- the four frames written through the cache, since this host's attributes
-- hold only valid utf-8
const function withFrames(t: Instance)
  t:SetAttribute("FlipbookEnabled", true)
  attr.cache(t)
  attr.set(t, "FlipbookTextures", FRAMES)
end

harness.suite(function()
  harness.describe("a trail's emit", function()
    test(
      "a trail nested in what is emitted is turned on by that emit and left on, unless its duration is below 0",
      function()
        staged(function()
          const root = harness.make("Folder")
          const plain = trailOf({}, root)
          const opted = trailOf({ EmitDuration = -1 }, root)

          const env = effects.emit(0, root)

          expect(plain.Enabled).toBe(true)
          expect(opted.Enabled).toBe(false)
          expect(env.Finished:getStatus()).toBe("Resolved")

          scheduler.frame(5)
          expect(plain.Enabled).toBe(true)
        end)
      end
    )

    -- below 0 means the trail never draws on an emit, so one the place has
    -- switched on is switched off, as a window above 0 does
    test("a duration below 0 switches a trail left on off", function()
      staged(function()
        const t = trailOf({ EmitDuration = -1 })
        t.Enabled = true

        const env = effects.emit(0, t)

        expect(t.Enabled).toBe(false)
        expect(env.Finished:getStatus()).toBe("Resolved")

        scheduler.frame(5)
        expect(t.Enabled).toBe(false)
      end)
    end)

    -- the window is what holds the trail on, so an emit below 0 meanwhile
    -- leaves it to the window to switch off
    test("a duration below 0 leaves a trail another emit's window holds on", function()
      staged(function()
        const t = trailOf({ EmitDuration = 0.5 })

        effects.emit(0, t)
        scheduler.frame(0.1)
        expect(t.Enabled).toBe(true)

        t:SetAttribute("EmitDuration", -1)
        effects.emit(0, t)
        expect(t.Enabled).toBe(true)

        scheduler.frame(0.5)
        expect(t.Enabled).toBe(false)
      end)
    end)

    test("a delay holds the trail off until it passes", function()
      staged(function()
        const t = trailOf({ EmitDelay = 0.5 })
        const env = effects.emit(0, t)

        scheduler.frame(0.25)
        expect(t.Enabled).toBe(false)

        scheduler.frame(0.3)
        expect(t.Enabled).toBe(true)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("a duration turns the trail on after the delay and off after the duration, then waits out its fade", function()
      staged(function()
        const t = trailOf({ EmitDelay = 0.25, EmitDuration = 0.5 })
        const env = effects.emit(0, t)

        expect(t.Enabled).toBe(false)

        scheduler.frame(0.3)
        expect(t.Enabled).toBe(true)

        scheduler.frame(0.5)
        expect(t.Enabled).toBe(false)
        expect(env.Finished:getStatus()).toBe("Started")

        scheduler.frame(0.5)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("a trail left on is switched off by an emit with a duration until its window", function()
      staged(function()
        const t = trailOf({ EmitDelay = 0.25, EmitDuration = 0.5 })
        t.Enabled = true

        effects.emit(0, t)
        expect(t.Enabled).toBe(false)

        scheduler.frame(0.3)
        expect(t.Enabled).toBe(true)

        scheduler.frame(0.5)
        expect(t.Enabled).toBe(false)
      end)
    end)

    test("two windows on one trail keep it on until the later closes", function()
      staged(function()
        const t = trailOf({ EmitDuration = 0.5 })

        effects.emit(0, t)
        scheduler.frame(0.3)
        effects.emit(0, t)

        scheduler.frame(0.3)
        expect(t.Enabled).toBe(true)

        scheduler.frame(0.3)
        expect(t.Enabled).toBe(false)
      end)
    end)

    test("a cleared emit switches its window's trail back off", function()
      staged(function()
        const t = trailOf({ EmitDuration = 2 })
        const env = effects.emit(0, t)

        scheduler.frame(0.1)
        expect(t.Enabled).toBe(true)

        env:Clear()
        expect(t.Enabled).toBe(false)
      end)
    end)
  end)

  harness.describe("a trail's flipbook", function()
    test("plays its frames over the texture and gives the authored one back as it ends", function()
      staged(function()
        const t = trailOf({ FlipbookChangeDuration = 0.5 })
        withFrames(t)

        const env = effects.emit(0, t)

        expect(t.Enabled).toBe(true)
        expect(t.Texture).toBe("rbxassetid://1")

        scheduler.frame(0.25)
        expect(t.Texture).toBe("rbxassetid://2")

        scheduler.frame(0.3)
        expect(env.Finished:getStatus()).toBe("Resolved")
        expect(t.Texture).toBe(AUTHORED)
      end)
    end)

    test("synced cycles span the window and the fade", function()
      staged(function()
        const t = trailOf({ EmitDuration = 0.5, SyncDuration = true })
        withFrames(t)

        const env = effects.emit(0, t)

        scheduler.frame(0.5)
        expect(t.Texture).toBe("rbxassetid://2")

        scheduler.frame(0.4)
        expect(t.Texture).toBe("rbxassetid://4")
        expect(env.Finished:getStatus()).toBe("Started")

        scheduler.frame(0.2)
        expect(env.Finished:getStatus()).toBe("Resolved")
        expect(t.Texture).toBe(AUTHORED)
      end)
    end)

    test("an endless loop on a trail left on cycles for the second every effect without a clock runs", function()
      staged(function()
        const t = trailOf({ FlipbookLoop = true, FlipbookChangeDuration = 0.25 })
        withFrames(t)

        const env = effects.emit(0, t)

        scheduler.frame(0.3)
        expect(t.Texture).toBe("rbxassetid://1")

        scheduler.frame(0.6)
        expect(env.Finished:getStatus()).toBe("Started")

        scheduler.frame(0.2)
        expect(env.Finished:getStatus()).toBe("Resolved")
        expect(t.Enabled).toBe(true)
      end)
    end)
  end)
end)
