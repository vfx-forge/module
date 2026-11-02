const mods = require("@mod/mods")
const value = require("@mod/value")
const frame = require("@mod/modifier_frame")
const codec = require("@mod/modifier_codec")
const reader = require("@mod/reader")
const lifetime = require("@mod/lifetime")
const harness = require("@tests/harness")
const effects = require("@srv/effects")
const utility = require("@mod/utility")
const registry = require("@mod/registry")
const scheduler = require("@mod/scheduler")
const fake_pool = require("@tests/fake_pool")
const frame_show = require("@mod/frame_show")
const frame_store = require("@srv/frame_store")
const enabled_effects = require("@srv/enabled_effects")
const value_curve = require("@mod/value_curve")
const test, expect = harness.test, harness.expect

const look_common = require("@mod/common/look")
const collision_common = require("@mod/common/collision")

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
    made.keys[i] = {
      time = key[1],
      value = key[2],
      envelope = key[3] or 0,
      left = table.create(channels, vector.zero),
      right = table.create(channels, vector.zero),
    }
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

-- an Instance row's live read and the probe that unwraps it, lune storing no
-- instance in an attribute: a handle is a table naming its target
const function targeting(part: BasePart, target: Instance, body: () -> ())
  const live, probe = reader.liveOf, reader.probe

  reader.liveOf = function(ref: Instance, name: string)
    return if ref == part and name == "AccelTarget" then { handle = true, target = target } else live(ref, name)
  end

  reader.probe = table.freeze({
    kind = function(v: any)
      return if type(v) == "table" and v.handle then "InstanceHandle" else typeof(v)
    end,
    get = function(v: any)
      return v.target
    end,
    alive = function()
      return true
    end,
    isA = function(inst: Instance, class: string)
      return inst:IsA(class)
    end,
  }) :: any

  const ok, err = pcall(body)

  reader.liveOf, reader.probe = live, probe

  if not ok then
    error(err, 0)
  end
end

-- whether a target counts as in the game, answered by `open` for as long as
-- `body` runs
const function reachable(open: () -> boolean, body: () -> ())
  const real = forge_mesh.engine.alive

  forge_mesh.engine.alive = open

  const ok, err = pcall(body)

  forge_mesh.engine.alive = real

  if not ok then
    error(err, 0)
  end
end

-- the world stood in by a floor at y 0 and a parent part's top at y 11 that
-- hits only what its filter leaves in, the filters each ray was cast with
-- kept, put back once `body` ends
const function walled(parent: Instance, body: (filters: { { any } }) -> ())
  const real = collision_common.engine
  const filters = {}

  collision_common.engine = {
    params = function()
      const params = { added = {} }

      function params.AddToFilter(self: any, items: { any })
        for _, item in items do
          table.insert(self.added, item)
        end
      end

      return params :: any
    end,
    tagged = function()
      return {}
    end,
    raycast = function(params: any, from: vector, to: vector)
      table.insert(filters, params.added)

      const wall = if table.find(params.added, parent) == nil then 11 else 0

      if from.y > wall and to.y <= wall then
        const at = from + (to - from) * ((from.y - wall) / (from.y - to.y))

        return { Position = Vector3.new(at.x, at.y, at.z), Normal = Vector3.new(0, 1, 0) } :: any
      end

      return nil
    end,
  }

  const ok, err = pcall(body, filters)

  collision_common.engine = real

  if not ok then
    error(err, 0)
  end
end

-- a piece falling from y 12 on a template under an attachment, `rows` over it
const function falling(rows: { [string]: any }, body: (piece: BasePart, fake: fake_pool.Fake) -> ())
  framed(function(fake)
    const part = attached(table.clone(rows))

    part:SetAttribute("Acceleration", Vector3.new(0, -20, 0))
    part:SetAttribute("Lifetime", NumberRange.new(3, 3))
    part:SetAttribute("Speed", STILL)

    walled(part.Parent :: Instance, function()
      const env = effects.emit(0, part)

      body(pieces(fake)[1], fake)
      env:Clear()
    end)
  end)
end

-- every row and group a hidden rule hides on `part`, by row name or group title
const function hiddenOf(part: BasePart): { [string]: boolean }
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

  return hidden
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

    test("Squash stretches up and narrows the rest as an emitter does", function()
      lived({ Squash = curveOf(1, { { 0, { 1 } } }) }, nil, function(piece)
        frames(1)

        expect(near(piece.Size, Vector3.new(1, 4, 1), LOOSE)).toBe(true)
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

    test("turbulence wanders a piece off its path and stays within its amount", function()
      seeding(function()
        staged(function(fake)
          const part = attached({
            Speed = STILL,
            Turbulence = 2,
            TurbulenceFrequency = 3,
            Lifetime = NumberRange.new(3, 3),
          })
          const env = effects.emit(0, part)
          local farthest = 0

          for _ = 1, 90 do
            frames(1)

            const piece = pieces(fake)[1]
            const away = piece.CFrame.Position - Vector3.new(1, 12, 3)

            farthest = math.max(farthest, away.Magnitude)

            expect(math.abs(away.X) <= 2 + EPSILON).toBe(true)
            expect(math.abs(away.Y) <= 2 + EPSILON).toBe(true)
            expect(math.abs(away.Z) <= 2 + EPSILON).toBe(true)
          end

          expect(farthest > 0.05).toBe(true)

          env:Clear()
        end)
      end)
    end)

    test("turbulence 0 is the plain path", function()
      staged(function(fake)
        const part = attached({ Speed = STILL, Turbulence = 0, TurbulenceFrequency = 3 })
        const env = effects.emit(0, part)

        frames(30)

        const piece = pieces(fake)[1]

        expect(near(piece.CFrame.Position, Vector3.new(1, 12, 3), EPSILON)).toBe(true)

        env:Clear()
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

  harness.describe("a mesh's motion", function()
    test("a target pulls pieces in", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(3, 3) })
        const goal = harness.make("Part", parent) :: BasePart

        goal.Position = Vector3.new(30, 10, 0)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            frames(1)

            const before = (piece.CFrame.Position - goal.Position).Magnitude

            frames(30)

            expect((piece.CFrame.Position - goal.Position).Magnitude < before - 1).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("a destroyed target stops pulling", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(3, 3) })
        const goal = harness.make("Part", parent) :: BasePart
        local open = true

        goal.Position = Vector3.new(30, 10, 0)

        reachable(function()
          return open
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)
            const piece = pieces(fake)[1]

            frames(10)

            open = false

            frames(2)

            const a = piece.CFrame.Position

            frames(1)

            const b = piece.CFrame.Position

            frames(10)

            const c = piece.CFrame.Position

            frames(1)

            const d = piece.CFrame.Position

            expect((b - a).Magnitude > EPSILON).toBe(true)
            expect(near(b - a, d - c, EPSILON)).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("a target at the piece adds nothing", function()
      staged(function(fake)
        const part = attached({ Speed = STILL, Lifetime = NumberRange.new(2, 2) })
        const goal = harness.make("Part", part.Parent) :: BasePart

        goal.Position = Vector3.new(1, 12, 3)

        reachable(function()
          return true
        end, function()
          targeting(part, goal, function()
            const env = effects.emit(0, part)

            frames(20)

            const piece = pieces(fake)[1]

            expect(finite(piece.CFrame)).toBe(true)
            expect(near(piece.CFrame.Position, Vector3.new(1, 12, 3), EPSILON)).toBe(true)

            env:Clear()
          end)
        end)
      end)
    end)

    test("Kill ends a piece at the floor", function()
      falling({ CollisionMode = "Kill" }, function(piece)
        local last = piece.CFrame.Position

        for _ = 1, 120 do
          frames(1)

          if piece.Parent == nil then
            break
          end

          last = piece.CFrame.Position
        end

        expect(piece.Parent).toBe(nil)

        -- the frame before the hit, a frame's fall above the floor
        expect(last.Y > 0).toBe(true)
        expect(last.Y < 0.5).toBe(true)
      end)
    end)

    test("Stop pins it", function()
      falling({ CollisionMode = "Stop" }, function(piece)
        frames(90)

        const at = piece.CFrame.Position

        frames(30)

        expect(piece.Parent ~= nil).toBe(true)
        expect(math.abs(at.Y) < 0.01).toBe(true)
        expect(near(piece.CFrame.Position, at, EPSILON)).toBe(true)
      end)
    end)

    test("Bounce lifts it back up and a slow bounce stops", function()
      falling({ CollisionMode = "Bounce", Bounce = 0.5, Friction = 0 }, function(piece)
        local landed = false
        local rose = false

        for _ = 1, 100 do
          frames(1)

          if piece.CFrame.Position.Y < 0.5 then
            landed = true
          elseif landed then
            rose = true
          end
        end

        expect(rose).toBe(true)
      end)

      falling({ CollisionMode = "Bounce", Bounce = 0.02 }, function(piece)
        frames(90)

        const at = piece.CFrame.Position

        frames(30)

        expect(math.abs(at.Y) < 0.05).toBe(true)
        expect(near(piece.CFrame.Position, at, EPSILON)).toBe(true)
      end)
    end)

    test("collision never hits the template or its parent", function()
      framed(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, {
          Speed = NumberRange.new(5, 5),
          Lifetime = NumberRange.new(1, 1),
          ShapeFace = "Inward",
          ShapeStyle = "Surface",
          CollisionMode = "Kill",
        })

        walled(parent, function(filters)
          const env = effects.emit(0, part)

          frames(30)

          expect(pieces(fake)[1].Parent ~= nil).toBe(true)
          expect(#filters > 0).toBe(true)
          expect(table.find(filters[1], parent) ~= nil).toBe(true)
          expect(table.find(filters[1], part) ~= nil).toBe(true)

          env:Clear()
        end)
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
        const hidden = hiddenOf(part)

        for _, name in
          {
            "Rate",
            "WindAffectsDrag",
            "ShapePartial",
            "AccelStrength",
            "TurbulenceFrequency",
            "Mesh Frames",
            "Material Frames",
            "Bounce",
            "Friction",
            "Filter",
          }
        do
          expect(`{name} {hidden[name]}`).toBe(`{name} true`)
        end

        expect(hidden.Collision).toBe(false)
      end)
    end)

    test("LockedToPart hides the Collision group", function()
      staged(function()
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))

        expect(hiddenOf(template(parent, { LockedToPart = true })).Collision).toBe(true)
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

    test("a plain emit carries an edit no signal told of, and a tick keeps its copy until one does", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Speed = STILL, Lifetime = NumberRange.new(1, 1) })
        const decal = harness.make("Decal", part) :: Decal
        const set = harness.make("Folder", part)

        decal.Name = "Front"
        decal.Texture = "rbxassetid://1"
        set.Name = "Frames"
        set:SetAttribute("FrameSet", "kept")
        set:AddTag(utility.EMIT_EXCLUDE_TAG)

        -- the texture the piece of one emit shows, its set left behind
        const function shown(emit: () -> () -> ())
          const clear = emit()
          const list = pieces(fake)

          expect(#list).toBe(1)
          expect(list[1]:FindFirstChild("Frames")).toBe(nil)

          const texture = (list[1]:FindFirstChild("Front") :: Decal).Texture

          clear()
          frames(1)

          return texture
        end

        const function plain()
          const env = effects.emit(0, part)

          return function()
            env:Clear()
          end
        end

        const function tick()
          const token = enabled_effects.token()

          enabled_effects.ticker(part, forge_mesh, token, effects)(FRAME)

          return function()
            lifetime.clear(token)
          end
        end

        const function told()
          for source, stale in fake.stale or {} do
            if source == part then
              stale()
            end
          end
        end

        expect(shown(plain)).toBe("rbxassetid://1")

        -- lune fires no signal, so only a plain emit's rebuild sees an edit
        decal.Texture = "rbxassetid://2"

        expect(shown(tick)).toBe("rbxassetid://1")
        expect(shown(plain)).toBe("rbxassetid://2")

        decal.Texture = "rbxassetid://3"
        told()

        expect(shown(tick)).toBe("rbxassetid://3")
      end)
    end)
  end)
end)
