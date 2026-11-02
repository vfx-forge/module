const harness = require("@tests/harness")
const effects = require("@srv/effects")
const utility = require("@mod/utility")
const registry = require("@mod/registry")
const scheduler = require("@mod/scheduler")
const fake_pool = require("@tests/fake_pool")
const frame_show = require("@mod/frame_show")
const frame_store = require("@srv/frame_store")
const test, expect = harness.test, harness.expect

const bezier_common = require("@mod/common/bezier")
const flight_common = require("@mod/common/flight")

const forge_mesh = require("@vfx/forge_mesh")

const CFrame = harness.datatypes.CFrame
const Vector3 = harness.datatypes.Vector3
const NumberRange = harness.datatypes.NumberRange

const EPSILON = 1e-4
const LOOSE = 1e-3
const FRAME = 1 / 60

-- a launch of no speed, so a piece stands where it spawned
const STILL = NumberRange.new(0, 0)

-- the effect registered on the effects service and on a pool that clones
-- every take whole into its folder, put back once `body` ends
const function staged(body: (fake: fake_pool.Fake) -> ())
  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
  registry.register(forge_mesh)

  const fake = fake_pool.start({})
  const ok, err = pcall(body, fake)

  fake_pool.stop(fake)
  registry.clear()

  if not ok then
    error(err, 0)
  end
end

-- `staged` with the frame store started under a terrain of its own and both
-- frame engine seams stood in
const function framed(body: (fake: fake_pool.Fake) -> ())
  const protect, terrain = utility.protectParent, workspace.Terrain
  const constructor, store, show = Instance, frame_store.engine, frame_show.engine
  const scope = {}

  utility.protectParent = function() end
  -- selene: allow(incorrect_standard_library_use)
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
    apply = function() end,
  }

  const ok, err = pcall(staged, function(fake)
    frame_store.init(scope)
    body(fake)
  end)

  utility.cleanupScope(scope)
  frame_store.engine, frame_show.engine = store, show
  utility.protectParent, workspace.Terrain = protect, terrain

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = constructor

  if not ok then
    error(err, 0)
  end
end

-- every emit's Random drawing `durations` in turn for a Duration of
-- `range`, and every other row at its lower bound, put back once `body` ends
const function drawing(range: NumberRange, durations: { number }, body: () -> ())
  const new = Random.new
  local next = 0

  -- selene: allow(incorrect_standard_library_use)
  Random.new = function()
    return {
      NextNumber = function(_, min: number, max: number)
        if min == range.Min and max == range.Max then
          next += 1

          return durations[next]
        end

        return min
      end,
      NextInteger = function(_, min: number)
        return min
      end,
    } :: any
  end

  const ok, err = pcall(body)

  -- selene: allow(incorrect_standard_library_use)
  Random.new = new

  if not ok then
    error(err, 0)
  end
end

-- a tagged template part under `parent`, its rows set from `attributes`
const function template(parent: Instance, attributes: { [string]: any }): BasePart
  const part = harness.make("Part", parent) :: BasePart

  part.Name = "Template"
  part:AddTag(utility.FORGE_MESH_TAG)

  for name, value in attributes do
    part:SetAttribute(name, value)
  end

  return part
end

-- a part of `size` at `cframe` holding the template, in a folder of its own
const function parentPart(cframe: CFrame, size: Vector3): (Instance, BasePart)
  const root = harness.make("Folder")
  const part = harness.make("Part", root) :: BasePart

  part.CFrame = cframe
  part.Size = size

  return root, part
end

-- a template under an attachment standing at (1, 12, 3), unturned
const function attached(attributes: { [string]: any }): BasePart
  const _, part = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
  const attachment = harness.make("Attachment", part) :: Attachment

  -- lune works out no world frame for an attachment, so it is written
  attachment.WorldCFrame = CFrame.new(1, 12, 3)

  return template(attachment, attributes)
end

-- a Frames folder of `count` frames under `part`, the part naming its key
const function frameSet(part: BasePart, key: string, count: number)
  const folder = harness.make("Folder", part)

  folder.Name = "Frames"
  folder:SetAttribute("FrameSet", key)
  folder:SetAttribute("UnionSize", Vector3.new(2, 2, 2))
  folder:SetAttribute("UnionCenter", Vector3.zero)
  part:SetAttribute("FrameSet", key)

  for index = 1, count do
    const frame = harness.make("MeshPart", folder) :: any

    frame.Name = tostring(index)
    frame:SetAttribute("FrameSize", Vector3.new(1, 2, 2))
    frame:SetAttribute("FrameCenter", Vector3.zero)
    harness.make("SurfaceAppearance", frame)
  end
end

const function frames(count: number)
  for _ = 1, count do
    scheduler.frame(FRAME)
  end
end

const function near(a: Vector3, b: Vector3, epsilon: number)
  return (a - b).Magnitude < epsilon
end

const function pieces(fake: fake_pool.Fake): { BasePart }
  return fake.folder:GetChildren() :: any
end

const function finite(cframe: CFrame)
  for _, x in { cframe:GetComponents() } do
    if x ~= x or math.abs(x) == math.huge then
      return false
    end
  end

  return true
end

const function tagged(roots: { Instance }): { Instance }
  const found = {}

  for _, root in roots do
    for _, inst in root:GetDescendants() do
      if inst:HasTag(utility.FORGE_MESH_TAG) then
        table.insert(found, inst)
      end
    end
  end

  return found
end

harness.suite(function()
  harness.describe("a mesh's pieces", function()
    test("an emit spawns EmitCount pieces inside the parent part", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))

        template(parent, { EmitCount = 5, Shape = "Box", ShapeStyle = "Volume", Velocity = STILL })

        const env = effects.emit(0, parent:FindFirstChild("Template"))

        scheduler.frame(1 / 60)

        const list = pieces(fake)

        expect(#list).toBe(5)

        for _, piece in list do
          const at = parent.CFrame:PointToObjectSpace(piece.CFrame.Position)

          expect(math.abs(at.X) <= 2 + EPSILON).toBe(true)
          expect(math.abs(at.Y) <= 1 + EPSILON).toBe(true)
          expect(math.abs(at.Z) <= 2 + EPSILON).toBe(true)
        end

        env:Clear()
      end)
    end)

    test("no piece carries the tag", function()
      staged(function(fake)
        const root, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { EmitCount = 3 })

        -- a template with children is cloned whole rather than taken from a stack
        harness.make("SpecialMesh", part)
        part:AddTag(utility.ENABLED_VFX_TAG)
        part:SetAttribute("Rate", 5)

        const env = effects.emit(0, part)

        scheduler.frame(1 / 60)

        const found = tagged({ root, fake.folder })

        expect(#pieces(fake)).toBe(3)
        expect(#found).toBe(1)
        expect(found[1]).toBe(part)

        for _, piece in pieces(fake) do
          expect(#piece:GetTags()).toBe(0)
          expect(next(piece:GetAttributes())).toBe(nil)
        end

        env:Clear()
      end)
    end)

    test("an attachment parent spawns at the attachment", function()
      staged(function(fake)
        const _, part = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const attachment = harness.make("Attachment", part) :: Attachment

        -- lune works out no world frame for an attachment, so it is written
        attachment.WorldCFrame = CFrame.new(1, 12, 3)

        template(attachment, { EmitCount = 4, SpreadAngle = Vector3.new(30, 30, 0), Velocity = STILL })

        const env = effects.emit(0, attachment:FindFirstChild("Template"))

        scheduler.frame(1 / 60)

        const list = pieces(fake)

        expect(#list).toBe(4)

        for _, piece in list do
          expect((piece.CFrame.Position - Vector3.new(1, 12, 3)).Magnitude < EPSILON).toBe(true)
        end

        env:Clear()
      end)
    end)

    test("a template with no part or attachment above it spawns at its own pose", function()
      staged(function(fake)
        const root = harness.make("Folder")
        const part = template(root, { EmitCount = 2, Shape = "Sphere", Velocity = STILL })

        part.CFrame = CFrame.new(5, 6, 7)

        const env = effects.emit(0, part)

        scheduler.frame(1 / 60)

        const list = pieces(fake)

        expect(#list).toBe(2)

        for _, piece in list do
          expect((piece.CFrame.Position - Vector3.new(5, 6, 7)).Magnitude < EPSILON).toBe(true)
        end

        env:Clear()
      end)
    end)

    test("pieces are released when their life ends", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { EmitCount = 3, Duration = NumberRange.new(0.5, 0.5) })

        effects.emit(0, part)

        scheduler.frame(0.25)
        expect(#pieces(fake)).toBe(3)

        scheduler.frame(0.3)
        scheduler.frame(1 / 60)
        expect(#pieces(fake)).toBe(0)
      end)
    end)

    test("a piece takes its transparency from the row, not the template", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { EmitCount = 3 })

        part.Transparency = 1

        const env = effects.emit(0, part)

        scheduler.frame(1 / 60)

        const list = pieces(fake)

        expect(#list).toBe(3)

        for _, piece in list do
          expect(piece.Transparency).toBe(0)
        end

        env:Clear()
      end)
    end)

    test("a piece's size is the template's times the Scale row", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Scale = Vector3.new(2, 3, 4) })

        part.Size = Vector3.new(2, 2, 2)

        const env = effects.emit(0, part)
        const list = pieces(fake)

        expect(#list).toBe(1)
        expect(list[1].Size).toBe(Vector3.new(4, 6, 8))

        env:Clear()
      end)
    end)

    test("degenerate rows do not produce NaN", function()
      for _, timeScale in { 0, 1 } do
        staged(function(fake)
          const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.zero)
          const part = template(parent, {
            EmitCount = 4,
            -- a piece of no duration is up only for its destroy delay
            Duration = NumberRange.new(0, 0),
            DestroyDelay = 0.1,
            ShapeStyle = "Surface",
            SpreadAngle = Vector3.new(180, 180, 0),
            Drag = 1e308,
            TimeScale = timeScale,
            FaceVelocity = true,
            RotSpeed = 1e308,
            MaxInitRot = Vector3.new(1, 1, 1),
          })

          effects.emit(0, part)

          const list = pieces(fake)

          expect(#list).toBe(4)

          for _, piece in list do
            expect(finite(piece.CFrame)).toBe(true)
            expect(piece.Size == piece.Size).toBe(true)
          end

          scheduler.frame(1 / 60)

          for _, piece in list do
            expect(finite(piece.CFrame)).toBe(true)
            expect(piece.Size == piece.Size).toBe(true)
          end

          scheduler.frame(0.1)
          scheduler.frame(1 / 60)
          expect(#pieces(fake)).toBe(0)
        end)
      end
    end)
  end)

  harness.describe("a mesh's flight", function()
    test("a piece flies the particle formula", function()
      staged(function(fake)
        const part = attached({
          Velocity = NumberRange.new(10, 10),
          Acceleration = Vector3.new(0, -20, 0),
          Drag = 0,
          Duration = NumberRange.new(1, 1),
        })

        const env = effects.emit(0, part)

        frames(30)

        const list = pieces(fake)
        const start = Vector3.new(1, 12, 3)
        const expected = start + Vector3.new(0, 1, 0) * 10 * 0.5 + Vector3.new(0, -20, 0) * 0.125

        expect(#list).toBe(1)
        expect(near(list[1].CFrame.Position, expected, LOOSE)).toBe(true)

        env:Clear()
      end)
    end)

    test("a piece keeps the template's own orientation as it flies", function()
      staged(function(fake)
        const part = attached({ Velocity = NumberRange.new(10, 10) })
        const turn = CFrame.fromOrientation(0.3, 1, 0.2)

        part.CFrame = CFrame.new(0, 0, 0) * turn

        const env = effects.emit(0, part)

        frames(10)

        const piece = pieces(fake)[1]

        expect(near(piece.CFrame.LookVector, turn.LookVector, EPSILON)).toBe(true)
        expect(near(piece.CFrame.UpVector, turn.UpVector, EPSILON)).toBe(true)

        env:Clear()
      end)
    end)

    test("WindAffectsDrag carries a piece with the wind", function()
      staged(function(fake)
        const wind = workspace.GlobalWind

        workspace.GlobalWind = Vector3.new(10, 0, 0)

        const ok, err = pcall(function()
          const part = attached({ Velocity = STILL, Drag = 2, WindAffectsDrag = true })
          const env = effects.emit(0, part)

          frames(30)

          const piece = pieces(fake)[1]
          const at = piece.CFrame.Position

          -- the position steps on the velocity it had, so one more frame reads it
          frames(1)

          const velocity = (piece.CFrame.Position - at) / FRAME

          expect(at.X > 1).toBe(true)
          expect(near(velocity, Vector3.new(5, 0, 0), LOOSE)).toBe(true)

          env:Clear()
        end)

        workspace.GlobalWind = wind

        if not ok then
          error(err, 0)
        end
      end)
    end)

    test("TimeScale 0 freezes a piece in place", function()
      staged(function(fake)
        const part = attached({
          Velocity = NumberRange.new(10, 10),
          Acceleration = Vector3.new(0, -20, 0),
          TimeScale = 0,
          RotSpeed = 90,
          MaxInitRot = Vector3.new(10, 10, 10),
          Duration = NumberRange.new(0.5, 0.5),
        })

        effects.emit(0, part)

        const piece = pieces(fake)[1]
        const before = piece.CFrame

        frames(12)

        expect(near(piece.CFrame.Position, Vector3.new(1, 12, 3), EPSILON)).toBe(true)
        expect(near(piece.CFrame.LookVector, before.LookVector, EPSILON)).toBe(true)
        expect(finite(piece.CFrame)).toBe(true)

        frames(20)

        expect(#pieces(fake)).toBe(0)
      end)
    end)

    test("LockedToPart carries pieces with the parent", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Velocity = STILL, SyncPosition = true })
        const env = effects.emit(0, part)

        frames(1)

        const piece = pieces(fake)[1]
        const before = piece.CFrame.Position

        parent.CFrame = CFrame.new(5, 10, 0)

        frames(1)

        expect(near(piece.CFrame.Position - before, Vector3.new(5, 0, 0), EPSILON)).toBe(true)

        env:Clear()
      end)
    end)

    test("FaceVelocity turns a piece along its flight", function()
      staged(function(fake)
        const part = attached({
          Velocity = NumberRange.new(10, 10),
          Acceleration = Vector3.new(10, -20, 0),
          FaceVelocity = true,
        })

        const env = effects.emit(0, part)

        frames(5)

        const elapsed = 5 * FRAME
        const velocity = Vector3.new(0, 10, 0) + Vector3.new(10, -20, 0) * elapsed

        expect(near(pieces(fake)[1].CFrame.LookVector, velocity.Unit, LOOSE)).toBe(true)

        env:Clear()
      end)
    end)

    test("a hit ends a piece early", function()
      staged(function(fake)
        const hit = flight_common.hit
        const params = bezier_common.createHitboxParams
        const onFinish = effects.emitOnFinish
        local steps = 0
        local finished = 0

        flight_common.hit = function()
          steps += 1

          return steps >= 3
        end

        bezier_common.createHitboxParams = function()
          return {} :: any
        end

        effects.emitOnFinish = function(...)
          finished += 1

          return onFinish(...)
        end

        const ok, err = pcall(function()
          const part = attached({ HitboxEnabled = true, Duration = NumberRange.new(1, 1) })

          effects.emit(0, part)

          frames(3)
          expect(finished).toBe(1)

          frames(2)
          expect(#pieces(fake)).toBe(0)
          expect(steps).toBe(3)
        end)

        flight_common.hit = hit
        bezier_common.createHitboxParams = params
        effects.emitOnFinish = onFinish

        if not ok then
          error(err, 0)
        end
      end)
    end)

    test("a piece whose life ends first leaves the world while the other flies on", function()
      staged(function(fake)
        const part = attached({ EmitCount = 2, Duration = NumberRange.new(0.5, 2) })
        const env = effects.emit(0, part)
        const list = pieces(fake)
        local elapsed = 0

        expect(#list).toBe(2)

        while #pieces(fake) == 2 and elapsed < 2.5 do
          frames(1)
          elapsed += FRAME
        end

        -- held by the effect to its end, both would leave on the same frame
        expect(#pieces(fake)).toBe(1)

        const gone = if list[1].Parent == nil then list[1] else list[2]
        const flying = if gone == list[1] then list[2] else list[1]

        expect(gone.Parent).toBe(nil)
        expect(flying.Parent ~= nil).toBe(true)

        env:Clear()
      end)
    end)

    test("a projectile keeps its piece up until it lands", function()
      staged(function(fake)
        const part = attached({
          Velocity = NumberRange.new(10, 10),
          Duration = NumberRange.new(0.2, 0.2),
          ProjectileEnabled = true,
          ProjectileSpeed = 30,
          ProjectileLifetime = NumberRange.new(0.5, 0.5),
        })

        effects.emit(0, part)

        frames(12)

        const piece = pieces(fake)[1]
        const at = piece.CFrame.Position

        frames(12)

        expect(#pieces(fake)).toBe(1)
        expect(piece.CFrame.Position.Y - at.Y > 5).toBe(true)

        frames(30)

        expect(#pieces(fake)).toBe(0)
      end)
    end)

    test("Speed 0 releases pieces", function()
      staged(function(fake)
        const part = attached({ EmitCount = 3, Speed = 0, Duration = NumberRange.new(0.5, 0.5) })

        effects.emit(0, part)

        frames(2)

        expect(#pieces(fake)).toBe(0)
      end)
    end)

    test("RotSpeed spins a piece whose rotation rows rest at 0", function()
      staged(function(fake)
        const part = attached({ Velocity = STILL, RotSpeed = 90 })
        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(30)

        -- a quarter second's spin on every axis turns the look away
        expect(near(piece.CFrame.LookVector, part.CFrame.LookVector, 0.1)).toBe(false)

        env:Clear()
      end)
    end)

    test("a locked piece holds its last pose once the parent is destroyed", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Velocity = STILL, SyncPosition = true, Duration = NumberRange.new(1, 1) })

        part.CFrame = CFrame.new(50, 0, 0)

        const env = effects.emit(0, part)

        frames(1)

        const piece = pieces(fake)[1]
        const before = piece.CFrame.Position

        parent:Destroy()

        frames(2)

        expect(near(piece.CFrame.Position, before, EPSILON)).toBe(true)

        env:Clear()
      end)
    end)
  end)

  harness.describe("a mesh's frame set", function()
    test("pieces end at their own drawn durations", function()
      const range = NumberRange.new(0.25, 2)

      drawing(range, { 0.25, 1, 2 }, function()
        framed(function(fake)
          const part = attached({ EmitCount = 3, Duration = range })

          frameSet(part, "durations", 4)

          const env = effects.emit(0, part)
          const list = pieces(fake)
          const gone: { [BasePart]: number } = {}
          local elapsed = 0

          expect(frame_store.find(part, "durations") ~= nil).toBe(true)
          expect(#list).toBe(3)

          while elapsed < 2.5 do
            frames(1)
            elapsed += FRAME

            for _, piece in list do
              if gone[piece] == nil and piece.Parent == nil then
                gone[piece] = elapsed
              end
            end
          end

          for index, duration in { 0.25, 1, 2 } do
            const at = gone[list[index]]

            expect(at ~= nil and math.abs(at - duration) < 2 * FRAME).toBe(true)
          end

          env:Clear()
        end)
      end)
    end)

    test("unsynced frames longer than the piece hold it still until they end", function()
      framed(function(fake)
        const part = attached({
          Velocity = NumberRange.new(10, 10),
          Duration = NumberRange.new(0.25, 0.25),
          SyncDuration = false,
          FlipbookChangeDuration = 1,
        })

        frameSet(part, "longer", 4)

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(18)

        const at = piece.CFrame.Position

        frames(18)

        expect(piece.Parent ~= nil).toBe(true)
        expect(near(piece.CFrame.Position, at, EPSILON)).toBe(true)

        frames(30)

        expect(piece.Parent).toBe(nil)

        env:Clear()
      end)
    end)
  end)
end)
