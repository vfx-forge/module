local attr = require("@mod/attributes")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local utility = require("@mod/utility")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local fake_pool = require("@tests/fake_pool")
local flipbook_common = require("@mod/common/flipbook")
local test, expect = harness.test, harness.expect

local beam = require("@vfx/beam")
local mesh = require("@vfx/mesh")

const Vector3 = harness.datatypes.Vector3
const NumberRange = harness.datatypes.NumberRange

-- four frames, texture ids 1 to 4
const FRAMES = buffer.tostring(flipbook_common.serialize({ 1, 2, 3, 4 }))

-- `beam` and `mesh` registered on the effects service and a fake pool, put
-- back once `body` ends
const function staged(body: (fake: fake_pool.Fake) -> ())
  const protect = utility.protectParent
  const constructor = Instance

  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
  registry.register(beam)
  registry.register(mesh)

  utility.protectParent = function() end

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = harness.datatypes.Instance

  const fake = fake_pool.start({})
  const ok, err = pcall(body, fake)

  fake_pool.stop(fake)
  registry.clear()
  utility.protectParent = protect

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = constructor

  if not ok then
    error(err, 0)
  end
end

-- the four frames written through the cache, since this host's attributes
-- hold only valid utf-8, then `attributes` beside them
const function flipbook(obj: Instance, attributes: { [string]: any })
  obj:SetAttribute("FlipbookEnabled", true)
  attr.cache(obj)
  attr.set(obj, "FlipbookTextures", FRAMES)

  for name, v in attributes do
    attr.set(obj, name, v)
  end
end

-- a beam living one second whose flipbook cycles once every half second
const function beamOf(attributes: { [string]: any }): any
  const part = harness.make("Part")
  const b = harness.make("Beam", part) :: any

  b.Attachment0 = harness.make("Attachment", part)
  b.Attachment1 = harness.make("Attachment", part)

  b:SetAttribute("EffectDuration", NumberRange.new(1, 1))
  b:SetAttribute("FlipbookChangeDuration", 0.5)
  flipbook(b, attributes)

  return b
end

-- the beam the emit plays on, the one copy of `source` the pool handed out
const function played(fake: fake_pool.Fake, source: Instance): any
  for _, inst in fake.folder:GetDescendants() do
    if inst:IsA("Beam") and inst ~= source then
      return inst
    end
  end

  for _, inst in (source.Parent :: Instance):GetChildren() do
    if inst:IsA("Beam") and inst ~= source then
      return inst
    end
  end

  error("no copy of the beam was taken", 0)
end

-- a mesh model living one second, its start's decal cycling the four frames
-- once every half second
const function meshOf(attributes: { [string]: any }): any
  const m = harness.make("Model", harness.make("Folder")) :: any
  const start = harness.make("Part", m) :: any
  const goal = harness.make("Part", m) :: any

  start.Name, goal.Name = "Start", "End"
  start.Size, goal.Size = Vector3.new(4, 4, 4), Vector3.new(4, 4, 4)
  harness.make("SpecialMesh", start).MeshId = "rbxassetid://0"
  harness.make("SpecialMesh", goal).MeshId = "rbxassetid://0"

  const decal = harness.make("Decal", start) :: any
  const twin = harness.make("Decal", goal) :: any

  decal.Name, twin.Name = "Face", "Face"
  m:SetAttribute("EffectDuration", NumberRange.new(1, 1))
  decal:SetAttribute("Flipbook_Change_Duration", 0.5)
  flipbook(decal, attributes)

  return m
end

-- the decal the emit's one piece wears
const function worn(fake: fake_pool.Fake): any
  const pieces = fake.folder:GetChildren()

  expect(#pieces).toBe(1)

  return pieces[1]:FindFirstChildOfClass("Decal")
end

-- the frame a texture names, its id
const function shown(inst: any): number
  return tonumber(string.match(inst.Texture, "(%d+)$")) :: number
end

-- the frame a copy wears after each step in `steps`, a time and the frame
-- expected once the clock reaches it
const function plays(at: () -> any, steps: { { number } })
  local now = 0

  for _, step in steps do
    if step[1] > now then
      scheduler.frame(step[1] - now)
      now = step[1]
    end

    expect(shown(at())).toBe(step[2])
  end
end

harness.suite(function()
  harness.describe("a flipbook's cycles", function()
    test("a flipbook that does not loop plays one cycle of its own", function()
      expect({ flipbook_common.cycles(0.5, 2, false, false, 4) }).toEqual({ 0.5, 1, 0.5 })
    end)

    test("a counted loop plays its cycles one after another", function()
      expect({ flipbook_common.cycles(0.5, 2, false, true, 3) }).toEqual({ 0.5, 3, 1.5 })
    end)

    test("an endless loop takes no time of its own", function()
      expect({ flipbook_common.cycles(0.5, 2, false, true, 0) }).toEqual({ 0.5, 0, 0 })
    end)

    test("synced cycles share the effect's duration", function()
      expect({ flipbook_common.cycles(0.5, 2, true, false, 0) }).toEqual({ 2, 1, 2 })
      expect({ flipbook_common.cycles(0.5, 2, true, true, 4) }).toEqual({ 0.5, 4, 2 })
    end)

    test("a synced endless loop counts as one cycle", function()
      expect({ flipbook_common.cycles(0.5, 2, true, true, 0) }).toEqual({ 2, 1, 2 })
    end)

    test("a loop switched off stops once the cycle playing then ends", function()
      expect(flipbook_common.stopped(0, 0.5)).toBe(1)
      expect(flipbook_common.stopped(3.1, 0.5)).toBe(7)
      expect(flipbook_common.stopped(3.5, 0.5)).toBe(8)
    end)

    test("a count is whole and never below 0", function()
      expect({ flipbook_common.cycles(0.5, 2, false, true, 2.7) }).toEqual({ 0.5, 2, 1 })
      expect({ flipbook_common.cycles(0.5, 2, false, true, -3) }).toEqual({ 0.5, 0, 0 })
    end)

    test("the phase wraps every cycle and holds at 1 after the last", function()
      expect(flipbook_common.phase(0.25, 0.5, 2)).toBe(0.5)
      expect(flipbook_common.phase(0.5, 0.5, 2)).toBe(0)
      expect(flipbook_common.phase(0.75, 0.5, 2)).toBe(0.5)
      expect(flipbook_common.phase(1, 0.5, 2)).toBe(1)
      expect(flipbook_common.phase(5, 0.5, 2)).toBe(1)
    end)

    test("an endless phase never holds", function()
      expect(flipbook_common.phase(100.25, 0.5, 0)).toBe(0.5)
    end)

    test("a cycle of no length stands at its end", function()
      expect(flipbook_common.phase(0, 0, 3)).toBe(1)
    end)

    test("an endless frame count is the texture set's old one", function()
      for _, elapsed in { 0, 0.05, 0.15, 0.3, 0.31, 1.7, 12.34 } do
        expect(flipbook_common.frame(elapsed, 10, 3, 0)).toBe(math.floor(elapsed * 10) % 3 + 1)
      end
    end)

    test("a counted frame holds the last once its cycles are played", function()
      expect(flipbook_common.frame(0.35, 10, 3, 2)).toBe(1)
      expect(flipbook_common.frame(0.55, 10, 3, 2)).toBe(3)
      expect(flipbook_common.frame(0.65, 10, 3, 2)).toBe(3)
      expect(flipbook_common.frame(9, 10, 3, 2)).toBe(3)
      expect(flipbook_common.frame(0, math.huge, 3, 1)).toBe(3)
    end)
  end)

  harness.describe("a beam's flipbook loop", function()
    test("a beam that does not loop plays one cycle and holds its last frame", function()
      staged(function(fake)
        const b = beamOf({})
        const env = effects.emit(0, b)

        plays(function()
          return played(fake, b)
        end, { { 0, 1 }, { 0.25, 2 }, { 0.5, 4 }, { 0.75, 4 } })

        expect(env.Finished:getStatus()).toBe("Started")

        scheduler.frame(0.5)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("a counted loop plays its cycles, then holds its last frame", function()
      staged(function(fake)
        const b = beamOf({ FlipbookLoop = true, FlipbookLoopCount = 2, FlipbookChangeDuration = 0.25 })

        const env = effects.emit(0, b)

        plays(function()
          return played(fake, b)
        end, { { 0, 1 }, { 0.125, 2 }, { 0.25, 1 }, { 0.375, 2 }, { 0.5, 4 }, { 0.75, 4 } })

        env:Clear()
      end)
    end)

    test("a counted loop longer than the beam keeps it for all its cycles", function()
      staged(function(fake)
        const b = beamOf({ FlipbookLoop = true, FlipbookLoopCount = 3 })
        const env = effects.emit(0, b)

        plays(function()
          return played(fake, b)
        end, { { 0, 1 }, { 0.25, 2 }, { 0.5, 1 }, { 0.75, 2 }, { 1.25, 2 } })

        expect(env.Finished:getStatus()).toBe("Started")

        scheduler.frame(0.5)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("a synced counted loop fits its cycles in the beam's duration", function()
      staged(function(fake)
        const b = beamOf({ FlipbookLoop = true, FlipbookLoopCount = 4, SyncDuration = true })
        const env = effects.emit(0, b)

        plays(function()
          return played(fake, b)
        end, { { 0, 1 }, { 0.125, 2 }, { 0.25, 1 }, { 0.375, 2 }, { 0.875, 2 } })

        scheduler.frame(0.25)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("an endless loop cycles until the beam ends", function()
      staged(function(fake)
        const b = beamOf({ FlipbookLoop = true })
        const env = effects.emit(0, b)

        plays(function()
          return played(fake, b)
        end, { { 0, 1 }, { 0.25, 2 }, { 0.5, 1 }, { 0.75, 2 } })

        scheduler.frame(0.5)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("an endless loop longer than the beam ends with it", function()
      staged(function()
        const env = effects.emit(0, beamOf({ FlipbookLoop = true, FlipbookChangeDuration = 4 }))

        scheduler.frame(1)
        scheduler.frame(0.25)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("a beam that does not loop is kept for a cycle longer than it", function()
      staged(function()
        const env = effects.emit(0, beamOf({ FlipbookChangeDuration = 4 }))

        scheduler.frame(1)
        scheduler.frame(0.25)
        expect(env.Finished:getStatus()).toBe("Started")

        scheduler.frame(3)
        scheduler.frame(0.25)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)
  end)

  harness.describe("a mesh decal's flipbook loop", function()
    test("a decal that does not loop plays one cycle and holds its last frame", function()
      staged(function(fake)
        const env = effects.emit(0, meshOf({}))

        plays(function()
          return worn(fake)
        end, { { 0, 1 }, { 0.25, 2 }, { 0.5, 4 }, { 0.75, 4 } })

        scheduler.frame(0.5)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("a counted loop plays its cycles, then holds its last frame", function()
      staged(function(fake)
        const m = meshOf({ FlipbookLoop = true, FlipbookLoopCount = 2, Flipbook_Change_Duration = 0.25 })

        const env = effects.emit(0, m)

        plays(function()
          return worn(fake)
        end, { { 0, 1 }, { 0.125, 2 }, { 0.25, 1 }, { 0.375, 2 }, { 0.5, 4 }, { 0.75, 4 } })

        env:Clear()
      end)
    end)

    test("a counted loop longer than the piece keeps it for all its cycles", function()
      staged(function(fake)
        const m = meshOf({ FlipbookLoop = true, FlipbookLoopCount = 3 })
        const env = effects.emit(0, m)

        plays(function()
          return worn(fake)
        end, { { 0, 1 }, { 0.25, 2 }, { 0.5, 1 }, { 0.75, 2 }, { 1.25, 2 } })

        expect(env.Finished:getStatus()).toBe("Started")

        scheduler.frame(0.5)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("a synced counted loop fits its cycles in the piece's duration", function()
      staged(function(fake)
        const m = meshOf({ FlipbookLoop = true, FlipbookLoopCount = 4, SyncDuration = true })
        const env = effects.emit(0, m)

        plays(function()
          return worn(fake)
        end, { { 0, 1 }, { 0.125, 2 }, { 0.25, 1 }, { 0.375, 2 }, { 0.875, 2 } })

        scheduler.frame(0.25)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("an endless loop cycles until the piece ends", function()
      staged(function(fake)
        const m = meshOf({ FlipbookLoop = true })
        const env = effects.emit(0, m)

        plays(function()
          return worn(fake)
        end, { { 0, 1 }, { 0.25, 2 }, { 0.5, 1 }, { 0.75, 2 } })

        scheduler.frame(0.5)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("a loop counting below 0 keeps cycling past the piece's duration", function()
      staged(function(fake)
        const m = meshOf({ FlipbookLoop = true, FlipbookLoopCount = -1 })
        const env = effects.emit(0, m)

        plays(function()
          return worn(fake)
        end, { { 0, 1 }, { 0.25, 2 }, { 0.5, 1 }, { 2.75, 2 }, { 3, 1 }, { 3.25, 2 } })

        expect(env.Finished:getStatus()).toBe("Started")

        env:Clear()
      end)
    end)

    test("the decal's Loop switched off under a count below 0 lets the cycle end, then the piece ends", function()
      staged(function(fake)
        const m = meshOf({ FlipbookLoop = true, FlipbookLoopCount = -1 })
        const decal = m.Start:FindFirstChildOfClass("Decal")
        const env = effects.emit(0, m)

        scheduler.frame(3.125)
        attr.set(decal, "FlipbookLoop", false)
        attr.trigger(decal, "FlipbookLoop", false)

        plays(function()
          return worn(fake)
        end, { { 0.125, 2 }, { 0.25, 3 } })

        expect(env.Finished:getStatus()).toBe("Started")

        scheduler.frame(0.25)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("a decal that does not loop is kept for a cycle longer than the piece", function()
      staged(function()
        const env = effects.emit(0, meshOf({ Flipbook_Change_Duration = 4 }))

        scheduler.frame(1)
        scheduler.frame(0.25)
        expect(env.Finished:getStatus()).toBe("Started")

        scheduler.frame(3)
        scheduler.frame(0.25)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("an endless loop longer than the piece ends with it", function()
      staged(function()
        const m = meshOf({ FlipbookLoop = true, Flipbook_Change_Duration = 4 })
        const env = effects.emit(0, m)

        scheduler.frame(1)
        scheduler.frame(0.25)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)

    test("switched off, a cycle counting below 0 and longer than the piece plays out", function()
      staged(function()
        const m = meshOf({ FlipbookLoop = true, FlipbookLoopCount = -1, Flipbook_Change_Duration = 4 })
        const decal = m.Start:FindFirstChildOfClass("Decal")
        const env = effects.emit(0, m)

        scheduler.frame(1.25)
        attr.set(decal, "FlipbookLoop", false)
        attr.trigger(decal, "FlipbookLoop", false)

        scheduler.frame(2.5)
        expect(env.Finished:getStatus()).toBe("Started")

        scheduler.frame(0.5)
        expect(env.Finished:getStatus()).toBe("Resolved")
      end)
    end)
  end)
end)
