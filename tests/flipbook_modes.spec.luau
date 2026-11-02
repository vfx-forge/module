const attr = require("@mod/attributes")
const harness = require("@tests/harness")
const effects = require("@srv/effects")
const utility = require("@mod/utility")
const registry = require("@mod/registry")
const scheduler = require("@mod/scheduler")
const fake_pool = require("@tests/fake_pool")
const frame_show = require("@mod/frame_show")
const look_common = require("@mod/common/look")
const frame_store = require("@srv/frame_store")
const flipbook_common = require("@mod/common/flipbook")
const test, expect = harness.test, harness.expect

const mesh = require("@vfx/mesh")

const NumberRange = harness.datatypes.NumberRange
const Vector3 = harness.datatypes.Vector3

-- what the mesh effect's look was before the modes: the cycle's phase and the
-- texture set's frame
const function oldPhase(elapsed: number, cycle: number, cycles: number): number
  if cycle <= 0 then
    return 1
  end

  const t = elapsed / cycle

  if cycles > 0 and t >= cycles then
    return 1
  end

  return t - math.floor(t)
end

const function oldFrame(elapsed: number, rate: number, count: number, cycles: number): number
  if not (rate < math.huge) then
    return count
  end

  const played = math.floor(elapsed * rate)

  if cycles > 0 and played >= count * cycles then
    return count
  end

  return played % count + 1
end

-- the frame at each whole second, rate 1
const function sweep(count: number, cycles: number, mode: string?, reverse: boolean?, offset: number?, last: number)
  const out = {}

  for step = 0, last do
    table.insert(out, flipbook_common.frame(step + 0.5, 1, count, cycles, mode :: any, reverse, offset))
  end

  return out
end

-- the mesh effect with the look given the modes the way the forge mesh will:
-- the attributes read off the model, a stub rng, and with `own` a row default
-- far past any piece's life. put back once `body` ends
const function staged(own: boolean, body: (applied: { { any } }) -> ())
  const protect, terrain = utility.protectParent, workspace.Terrain
  const constructor, store, show = Instance, frame_store.engine, frame_show.engine
  const start = look_common.start
  const applied = {}
  const scope = {}

  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
  registry.register(mesh)

  utility.protectParent = function() end
  workspace.Terrain = harness.make("Folder") :: any

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = harness.datatypes.Instance

  frame_store.engine = {
    now = function()
      return 0
    end,
    detaches = function()
      return false
    end,
    maps = function()
      return 1
    end,
    clone = function(instance: Instance)
      return instance:Clone()
    end,
  }

  frame_show.engine = {
    apply = function(shape: any, source: any)
      table.insert(applied, { shape, source })
    end,
  }

  look_common.start = function(scope: any, piece: any, template: any, attrs: any, duration: any, sets: any, opts: any)
    const ref = opts.owner

    opts.modes = true
    opts.ownDefault = own
    opts.rng = {
      NextNumber = function()
        return 0
      end,
    }

    const added = {
      FlipbookMode = attr.get(ref, "FlipbookMode", "OneShot", true),
      FlipbookStartRandom = attr.get(ref, "FlipbookStartRandom", false, true),
      FlipbookReverse = attr.get(ref, "FlipbookReverse", false, true),
      FlipbookChangeDuration = if own and attr.get(ref, "FlipbookChangeDuration", nil, true) == nil
        then 100
        else attrs.FlipbookChangeDuration,
    }

    const extra = setmetatable({}, {
      __index = function(_, key: string)
        if added[key] ~= nil then
          return added[key]
        end

        return attrs[key]
      end,
    })

    return start(scope, piece, template, extra, duration, sets, opts)
  end

  const fake = fake_pool.start({})
  const ok, err = pcall(function()
    frame_store.init(scope)
    body(applied)
  end)

  fake_pool.stop(fake)
  utility.cleanupScope(scope)
  registry.clear()
  look_common.start = start
  frame_store.engine, frame_show.engine = store, show
  utility.protectParent, workspace.Terrain = protect, terrain

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = constructor

  if not ok then
    error(err, 0)
  end
end

-- a mesh model of four frames living `life` seconds
const function model(key: string, life: number, attributes: { [string]: any }): any
  const m = harness.make("Model", harness.make("Folder")) :: any
  const start = harness.make("MeshPart", m) :: any
  const goal = harness.make("MeshPart", m) :: any
  const folder = harness.make("Folder", m) :: any

  start.Name, goal.Name = "Start", "End"
  start.Size, goal.Size = Vector3.new(4, 4, 4), Vector3.new(4, 4, 4)
  start.MeshId, goal.MeshId = "rbxassetid://1", "rbxassetid://1"
  harness.make("SurfaceAppearance", start)

  folder.Name = "Frames"
  folder:SetAttribute("FrameSet", key)
  folder:SetAttribute("UnionSize", Vector3.new(2, 2, 2))
  folder:SetAttribute("UnionCenter", Vector3.zero)
  m:SetAttribute("FrameSet", key)
  m:SetAttribute("EffectDuration", NumberRange.new(life, life))

  for index = 1, 4 do
    const frame = harness.make("MeshPart", folder) :: any

    frame.Name = tostring(index)
    frame:SetAttribute("FrameSize", Vector3.new(1, 2, 2))
    frame:SetAttribute("FrameCenter", Vector3.zero)
    harness.make("SurfaceAppearance", frame)
  end

  for name, v in attributes do
    m:SetAttribute(name, v)
  end

  attr.cache(m)

  return m
end

-- the frame the piece shows after each step, a time and the frame expected
const function plays(applied: { { any } }, set: any, steps: { { number } })
  local now = 0

  for _, step in steps do
    if step[1] > now then
      scheduler.frame(step[1] - now)
      now = step[1]
    end

    expect(applied[#applied][2]).toBe(set.frames[step[2]].mesh)
  end
end

harness.suite(function()
  harness.describe("flipbook modes", function()
    test("PingPong runs forward then back", function()
      expect(sweep(4, 0, "PingPong", nil, nil, 7)).toEqual({ 1, 2, 3, 4, 3, 2, 1, 2 })
      expect(flipbook_common.phase(0.25, 1, 0, "PingPong")).toBe(0.25)
      expect(flipbook_common.phase(1.25, 1, 0, "PingPong")).toBe(0.25)
    end)

    test("a PingPong holds every frame for the same time, at both turns too", function()
      for _, count in { 2, 4, 5 } do
        const steps = flipbook_common.steps(count, "PingPong")
        const holds = table.create(count, 0)
        const samples = steps * 100

        for k = 0, samples - 1 do
          const alpha = flipbook_common.phase((k + 0.5) / samples, 1, 0, "PingPong")
          const frame = flipbook_common.pick(count, alpha, "PingPong")

          holds[frame] += 1
        end

        for frame, held in holds do
          expect(held).toBe(if frame == 1 or frame == count then 100 else 200)
        end
      end

      expect(flipbook_common.pick(4, 0, "PingPong")).toBe(1)
      expect(flipbook_common.pick(4, 0.5, "PingPong")).toBe(4)
      expect(flipbook_common.pick(4, 0.99, "PingPong")).toBe(2)
    end)

    test("a counted PingPong ends back on the first frame", function()
      expect(sweep(4, 1, "PingPong", nil, nil, 8)).toEqual({ 1, 2, 3, 4, 3, 2, 1, 1, 1 })
      expect(flipbook_common.phase(1, 1, 1, "PingPong")).toBe(0)
    end)

    test("Reverse plays backward", function()
      expect(sweep(4, 1, "OneShot", true, nil, 5)).toEqual({ 4, 3, 2, 1, 1, 1 })
      expect(sweep(4, 0, "PingPong", true, nil, 6)).toEqual({ 4, 3, 2, 1, 2, 3, 4 })
    end)

    test("Start Random offsets the start and OneShot wraps", function()
      expect(sweep(4, 1, "OneShot", nil, 2, 5)).toEqual({ 3, 4, 1, 2, 2, 2 })
      expect(sweep(4, 0, "Loop", nil, 3, 5)).toEqual({ 4, 1, 2, 3, 4, 1 })
      expect(flipbook_common.phase(0, 1, 0, "Loop", 0.25)).toBe(0.25)
      expect(flipbook_common.phase(0.5, 1, 0, "PingPong", 0.25)).toBe(0.75)
    end)

    test("a nil mode is today's frame", function()
      for _, count in { 1, 3, 4 } do
        for _, cycles in { 0, 1, 2 } do
          for _, rate in { 0.5, 10, math.huge } do
            for _, elapsed in { 0, 0.05, 0.31, 1, 1.7, 5.5, 12.34 } do
              expect(flipbook_common.frame(elapsed, rate, count, cycles)).toBe(oldFrame(elapsed, rate, count, cycles))
            end
          end
        end
      end

      for _, cycle in { 0, 0.5, 2 } do
        for _, cycles in { 0, 1, 3 } do
          for _, elapsed in { 0, 0.25, 0.5, 1, 2.6, 9 } do
            expect(flipbook_common.phase(elapsed, cycle, cycles)).toBe(oldPhase(elapsed, cycle, cycles))
          end
        end
      end
    end)

    test("an endless PingPong stops when the mode leaves PingPong", function()
      staged(false, function(applied)
        const m = model("modes-a", 1, {
          FlipbookChangeDuration = 1,
          FlipbookMode = "PingPong",
          FlipbookLoopCount = -1,
          DestroyDelay = 1,
        })
        const set = frame_store.find(m, "modes-a") :: any

        set.meshes = true
        effects.emit(0, m)

        -- one cycle is a round trip, 1 2 3 4 3 2 over four steps either way
        plays(applied, set, { { 0, 1 }, { 0.5, 4 }, { 1.5, 4 }, { 2.25, 2 } })

        attr.set(m, "FlipbookMode", "OneShot")
        attr.trigger(m, "FlipbookMode", "OneShot")

        -- the cycle playing then plays out and the last frame holds
        plays(applied, set, { { 0.5, 3 }, { 0.65, 2 }, { 1.25, 1 } })
      end)
    end)

    test("an unset change duration follows the piece's own duration with ownDefault", function()
      for _, life in { 0.5, 2 } do
        staged(true, function(applied)
          const m = model(`modes-own-{life}`, life, {})
          const set = frame_store.find(m, `modes-own-{life}`) :: any

          set.meshes = true
          effects.emit(0, m)

          plays(applied, set, { { 0, 1 }, { life * 0.5, 2 }, { life * 0.98, 4 } })
        end)
      end
    end)

    test("a set change duration is kept with ownDefault", function()
      staged(true, function(applied)
        const m = model("modes-set", 2, { FlipbookChangeDuration = 0.5 })
        const set = frame_store.find(m, "modes-set") :: any

        set.meshes = true
        effects.emit(0, m)

        plays(applied, set, { { 0, 1 }, { 0.25, 2 }, { 0.5, 4 } })
      end)
    end)
  end)
end)
