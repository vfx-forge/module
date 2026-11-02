const mods = require("@mod/mods")
const value = require("@mod/value")
const frame = require("@mod/modifier_frame")
const codec = require("@mod/modifier_codec")
const reader = require("@mod/reader")
const harness = require("@tests/harness")
const effects = require("@srv/effects")
const utility = require("@mod/utility")
const registry = require("@mod/registry")
const scheduler = require("@mod/scheduler")
const fake_pool = require("@tests/fake_pool")
const frame_show = require("@mod/frame_show")
const frame_store = require("@srv/frame_store")
const value_curve = require("@mod/value_curve")
const test, expect = harness.test, harness.expect

const look_common = require("@mod/common/look")

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

-- every piece's drawn life by the piece, as the look is handed it, put back
-- once `body` ends
const function recording(body: (lives: { [BasePart]: number }) -> ())
  const start = look_common.start
  const lives: { [BasePart]: number } = {}

  look_common.start = function(scope, piece, template, attrs, duration, ...)
    lives[piece] = duration

    return start(scope, piece, template, attrs, duration, ...)
  end

  const ok, err = pcall(body, lives)

  look_common.start = start

  if not ok then
    error(err, 0)
  end
end

-- every Random built without a seed seeded apart, as the harness's fixed one
-- would draw the same for every piece, put back once `body` ends
const function seeding(body: () -> ())
  const new = Random.new
  local seed = 0

  -- selene: allow(incorrect_standard_library_use)
  Random.new = function(given: number?)
    seed += 1

    return new(given or (seed * 1103515245 + 12345) % 2147483647)
  end

  const ok, err = pcall(body)

  -- selene: allow(incorrect_standard_library_use)
  Random.new = new

  if not ok then
    error(err, 0)
  end
end

-- a randomizer from `low` to `high` on the row `name`, drawn per component
const function randomized(obj: Instance, name: string, low: any, high: any)
  const queue = {
    { kind = "randomizer", chain = false, start = value.lit(low), finish = value.lit(high), perComponent = true },
  }

  obj:SetAttribute(mods.attrName("attribute", name), frame.frame(codec.encode({ v = 1, queue = queue })))
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

-- the stored rows of `part` replaced by `rows` for as long as `body` runs; lune
-- refuses a non utf-8 attribute string, so a curve is stubbed in, not set
const function stubbed(part: BasePart, rows: { [string]: any }, body: () -> ())
  reader.source = function(inst: Instance)
    const map = table.clone(reader.defaultSource(inst))

    if inst == part then
      for name, row in rows do
        map[name] = row
      end
    end

    return map
  end

  const ok, err = pcall(body)

  reader.source = reader.defaultSource

  if not ok then
    error(err, 0)
  end
end

-- a curve of `channels` from keys given as { time, value, envelope? }
const function curveOf(channels: number, keys: { { any } }, linked: boolean?)
  const made = value_curve.flat(1, channels)

  made.linked = linked ~= false
  made.keys = {}

  for i, key in keys do
    made.keys[i] = { time = key[1], value = key[2], envelope = key[3] or 0, left = vector.zero, right = vector.zero }
  end

  return value_curve.encode(made)
end

-- a template with `rows` stubbed in, one piece of a second's life standing
-- where it spawned
const function lived(rows: { [string]: any }, attributes: { [string]: any }?, body: (piece: BasePart, env: any) -> ())
  staged(function(fake)
    const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
    const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(1, 1) })

    for name, value in attributes or {} do
      part:SetAttribute(name, value)
    end

    part.Size = Vector3.new(2, 2, 2)

    stubbed(part, rows, function()
      const env = effects.emit(0, part)

      body(pieces(fake)[1], env)
      env:Clear()
    end)
  end)
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

        template(parent, { EmitCount = 5, Shape = "Box", ShapeStyle = "Volume", Speed = STILL })

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

        template(attachment, { EmitCount = 4, SpreadAngle = Vector3.new(30, 30, 0), Speed = STILL })

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
        const part = template(root, { EmitCount = 2, Shape = "Sphere", Speed = STILL })

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
        const part = template(parent, { EmitCount = 3, Lifetime = NumberRange.new(0.5, 0.5) })

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

    test("a piece's size is the template's times the Size curve", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const size = value_curve.flat(1, 3)

        size.linked = false
        size.keys[1].value = { 2, 3, 4 }

        const part = template(parent, {})
        const encoded = value_curve.encode(size)

        part.Size = Vector3.new(2, 2, 2)

        -- lune refuses a non utf-8 attribute string, so the stored map is stubbed
        reader.source = function(inst: Instance)
          const map = table.clone(reader.defaultSource(inst))

          if inst == part then
            map.Size = encoded
          end

          return map
        end

        const ok, err = pcall(function()
          const env = effects.emit(0, part)
          const list = pieces(fake)

          expect(#list).toBe(1)
          expect(list[1].Size).toBe(Vector3.new(4, 6, 8))

          env:Clear()
        end)

        reader.source = reader.defaultSource

        if not ok then
          error(err, 0)
        end
      end)
    end)

    test("Size follows its curve per axis", function()
      lived({ Size = curveOf(3, { { 0, { 1, 1, 1 } }, { 1, { 2, 1, 3 } } }, false) }, nil, function(piece)
        frames(30)

        expect(near(piece.Size, Vector3.new(3, 2, 4), LOOSE)).toBe(true)
      end)
    end)

    test("Squash stretches up and keeps volume", function()
      lived({ Squash = curveOf(1, { { 0, { 1 } } }) }, nil, function(piece)
        frames(1)

        expect(near(piece.Size, Vector3.new(2 / math.sqrt(2), 4, 2 / math.sqrt(2)), LOOSE)).toBe(true)
        expect(math.abs(piece.Size.X * piece.Size.Y * piece.Size.Z - 8) < LOOSE).toBe(true)
      end)
    end)

    test("Transparency follows its curve", function()
      lived({ Transparency = curveOf(1, { { 0, { 0 } }, { 1, { 1 } } }) }, nil, function(piece)
        frames(30)

        expect(math.abs(piece.Transparency - 0.5) < LOOSE).toBe(true)
      end)
    end)

    test("Color follows its gradient", function()
      const red, blue = Color3.new(1, 0, 0), Color3.new(0, 0, 1)
      const gradient = ColorSequence.new(red, blue)

      lived({}, { Color = gradient }, function(piece)
        expect(piece.Color).toBe(red)

        frames(30)

        expect(piece.Color.R < 1 and piece.Color.R > 0).toBe(true)
        expect(piece.Color.B < 1 and piece.Color.B > 0).toBe(true)
      end)
    end)

    test("an envelope draws once per piece", function()
      seeding(function()
        staged(function(fake)
          const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
          const part = template(parent, { EmitCount = 2, Speed = STILL, Lifetime = NumberRange.new(1, 1) })

          part.Size = Vector3.new(2, 2, 2)

          stubbed(part, { Size = curveOf(3, { { 0, { 1, 1, 1 }, 0.5 } }) }, function()
            const env = effects.emit(0, part)
            const list = pieces(fake)
            const first = list[1].Size

            frames(5)

            expect(list[1].Size).toBe(first)
            expect(list[1].Size ~= list[2].Size).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("FacingCamera points at the camera", function()
      const camera = workspace.CurrentCamera
      const before = camera.CFrame

      camera.CFrame = CFrame.new(0, 10, 50)

      lived({}, { Orientation = "FacingCamera" }, function(piece)
        frames(2)

        expect(near(piece.CFrame.LookVector, (Vector3.new(0, 10, 50) - piece.CFrame.Position).Unit, LOOSE)).toBe(true)
      end)

      camera.CFrame = before
    end)

    test("VelocityPerpendicular turns along the flight", function()
      staged(function(fake)
        const part = attached({ Speed = NumberRange.new(10, 10), Orientation = "VelocityPerpendicular" })
        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(2)

        const at = piece.CFrame.Position

        frames(2)

        const heading = (piece.CFrame.Position - at).Unit

        expect(near(piece.CFrame.LookVector, heading, LOOSE)).toBe(true)

        env:Clear()
      end)
    end)

    test("degenerate rows do not produce NaN", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.zero)
        const part = template(parent, {
          EmitCount = 4,
          -- a short life, so the spin steps, then the destroy delay
          Lifetime = NumberRange.new(0.05, 0.05),
          DestroyDelay = 0.1,
          ShapeStyle = "Surface",
          SpreadAngle = Vector3.new(180, 180, 0),
          Drag = 1e308,
          Orientation = "VelocityPerpendicular",
          RotSpeed = Vector3.new(1e308, 1e308, 1e308),
          Rotation = Vector3.new(1, 1, 1),
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
        scheduler.frame(0.1)
        scheduler.frame(1 / 60)
        expect(#pieces(fake)).toBe(0)
      end)
    end)
  end)

  harness.describe("a mesh's flight", function()
    test("a piece flies the particle formula", function()
      staged(function(fake)
        const part = attached({
          Speed = NumberRange.new(10, 10),
          Acceleration = Vector3.new(0, -20, 0),
          Drag = 0,
          Lifetime = NumberRange.new(1, 1),
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
        const part = attached({ Speed = NumberRange.new(10, 10) })
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
          const part = attached({ Speed = STILL, Drag = 2, WindAffectsDrag = true })
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

    test("LockedToPart carries pieces with the parent", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, LockedToPart = true })
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

    test("a piece whose life ends first leaves the world while the other flies on", function()
      seeding(function()
        staged(function(fake)
          const part = attached({ EmitCount = 2, Lifetime = NumberRange.new(0.5, 2) })
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
    end)

    test("Speed is the launch speed, TimeScale the clock", function()
      for _, timeScale in { 1, 0.5 } do
        staged(function(fake)
          const part = attached({ Speed = NumberRange.new(20, 20), TimeScale = timeScale })

          effects.emit(0, part)

          const piece = pieces(fake)[1]

          frames(30)

          -- half a second of the effect's clock at its own pace
          const elapsed = 0.5 * timeScale

          expect(near(piece.CFrame.Position, Vector3.new(1, 12 + 20 * elapsed, 3), LOOSE)).toBe(true)

          local alive = 30 * FRAME

          while piece.Parent ~= nil and alive < 4 do
            frames(1)
            alive += FRAME
          end

          expect(math.abs(alive - 1 / timeScale) < 2 * FRAME).toBe(true)
        end)
      end
    end)

    test("TimeScale 0 releases pieces", function()
      staged(function(fake)
        const part = attached({ EmitCount = 3, TimeScale = 0, Lifetime = NumberRange.new(0.5, 0.5) })

        effects.emit(0, part)

        frames(2)

        expect(#pieces(fake)).toBe(0)
      end)
    end)

    test("RotSpeed spins an axis whose rotation rests at 0", function()
      staged(function(fake)
        const part = attached({ Speed = STILL, RotSpeed = Vector3.new(0, 90, 0) })
        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(30)

        -- half a second at 90 degrees per second turns the yaw by 45 alone
        const turned = CFrame.fromOrientation(0, math.rad(45), 0)

        expect(near(piece.CFrame.LookVector, turned.LookVector, LOOSE)).toBe(true)
        expect(near(piece.CFrame.UpVector, Vector3.new(0, 1, 0), LOOSE)).toBe(true)

        env:Clear()
      end)
    end)

    test("a Rotation randomizer draws per axis per piece", function()
      seeding(function()
        staged(function(fake)
          const part = attached({ EmitCount = 4, Speed = STILL })

          randomized(part, "Rotation", Vector3.zero, Vector3.new(90, 90, 90))

          const env = effects.emit(0, part)
          const list = pieces(fake)
          const seen = {}

          expect(#list).toBe(4)

          for _, piece in list do
            const x, y, z = piece.CFrame:ToOrientation()

            -- every axis draws its own, so no two match
            expect(math.abs(x - y) > EPSILON and math.abs(y - z) > EPSILON).toBe(true)

            for _, other in seen do
              expect(near(piece.CFrame.LookVector, other, EPSILON)).toBe(false)
            end

            table.insert(seen, piece.CFrame.LookVector)
          end

          env:Clear()
        end)
      end)
    end)

    test("a locked piece holds its last pose once the parent is destroyed", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, LockedToPart = true, Lifetime = NumberRange.new(1, 1) })

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
    test("pieces end at their own drawn lives", function()
      recording(function(lives)
        framed(function(fake)
          const part = attached({ EmitCount = 3, Lifetime = NumberRange.new(0.25, 2) })

          frameSet(part, "lives", 4)

          const env = effects.emit(0, part)
          const list = pieces(fake)
          const gone: { [BasePart]: number } = {}
          local elapsed = 0

          expect(frame_store.find(part, "lives") ~= nil).toBe(true)
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

          for _, piece in list do
            const at = gone[piece]
            const life = lives[piece]

            expect(life ~= nil and at ~= nil and math.abs(at - life) < 2 * FRAME).toBe(true)
          end

          env:Clear()
        end)
      end)
    end)

    test("an unsynced frame set ends with each piece's own Lifetime", function()
      framed(function(fake)
        const part = attached({ Lifetime = NumberRange.new(0.25, 0.25), SyncDuration = false })

        frameSet(part, "own", 4)

        const env = effects.emit(0, part)
        const piece = pieces(fake)[1]

        frames(24)

        expect(piece.Parent).toBe(nil)

        env:Clear()
      end)
    end)

    test("unsynced frames longer than the piece hold it still until they end", function()
      framed(function(fake)
        const part = attached({
          Speed = NumberRange.new(10, 10),
          Lifetime = NumberRange.new(0.25, 0.25),
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

  harness.describe("a mesh's rows", function()
    test("every hidden rule runs on an untouched template", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, {})
        const ctx = { ref = part, obj = part, effect = forge_mesh }
        const attrs, props = reader.resolve(forge_mesh :: any, ctx :: any)
        const hidden: { [string]: boolean } = {}

        for name, row in forge_mesh.attributes do
          if row.hiddenRule ~= nil then
            hidden[name] = row.hiddenRule(ctx, attrs, props) == true
          end

          if row.readonlyRule ~= nil then
            row.readonlyRule(ctx, attrs, props)
          end
        end

        const function walk(entries: { any })
          for _, entry in entries do
            if type(entry) ~= "table" or entry.entries == nil then
              continue
            end

            if entry.hidden ~= nil then
              hidden[entry.title] = entry.hidden(ctx, attrs, props) == true
            end

            walk(entry.entries)
          end
        end

        walk(forge_mesh.layout)

        for _, name in
          {
            "Rate",
            "WindAffectsDrag",
            "ShapePartial",
            "AccelStrength",
            "Mesh Frames",
            "Material Frames",
            "Bounce",
            "Friction",
            "Filter",
          }
        do
          expect(`{name} {hidden[name]}`).toBe(`{name} true`)
        end
      end)
    end)

    test("glow rows set on a template reach the look without being forge_mesh rows", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { EmissiveStrength = 3 })
        const authored = harness.make("SurfaceAppearance", part) :: any

        authored.EmissiveStrength = 2

        const env = effects.emit(0, part)
        const worn = pieces(fake)[1]:FindFirstChildOfClass("SurfaceAppearance") :: any

        expect(forge_mesh.attributes.EmissiveStrength).toBe(nil)
        expect(math.abs(worn.EmissiveStrength - 6) < EPSILON).toBe(true)

        env:Clear()
      end)
    end)
  end)
end)
