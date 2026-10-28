local harness = require("@tests/harness")
local effects = require("@srv/effects")
local utility = require("@mod/utility")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local fake_pool = require("@tests/fake_pool")
local frame_show = require("@mod/frame_show")
local frame_store = require("@srv/frame_store")
local test, expect = harness.test, harness.expect

local mesh = require("@vfx/mesh")

const Color3 = harness.datatypes.Color3
const Vector3 = harness.datatypes.Vector3

type Options = {
  key: string?,
  count: number?,
  part: boolean?,
  goal: Vector3?,
  scale: Vector3?,
  decal: number?,
  attributes: { [string]: any }?,
}

-- the mesh registered on the effects service and the pool, with the frame
-- store started under a terrain of its own and both engine seams stood in,
-- then put back once `body` ends. `applied` keeps every ApplyMesh
local function staged(body: (applied: { { any } }, fake: fake_pool.Fake) -> ())
  const protect, terrain = utility.protectParent, workspace.Terrain
  const constructor, store, show = Instance, frame_store.engine, frame_show.engine
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

  const fake = fake_pool.start({})
  const ok, err = pcall(function()
    frame_store.init(scope)
    body(applied, fake)
  end)

  fake_pool.stop(fake)
  utility.cleanupScope(scope)
  registry.clear()
  frame_store.engine, frame_show.engine = store, show
  utility.protectParent, workspace.Terrain = protect, terrain

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = constructor

  if not ok then
    error(err, 0)
  end
end

-- a mesh model whose start is a 4 stud MeshPart wearing a surface appearance,
-- or with `part` a Part with a special mesh, and with `key` a Frames folder of
-- `count` frames of the same kind, each a frame of half the union's width set
-- one stud off its center, and with `decal` each part frame wearing a decal of
-- that transparency
local function model(options: Options): (any, any)
  const m = harness.make("Model", harness.make("Folder")) :: any
  const class = if options.part then "Part" else "MeshPart"
  const start = harness.make(class, m) :: any
  const goal = harness.make(class, m) :: any

  start.Name, goal.Name = "Start", "End"
  start.Size = Vector3.new(4, 4, 4)
  goal.Size = options.goal or start.Size

  if options.part then
    const from = harness.make("SpecialMesh", start) :: any
    const to = harness.make("SpecialMesh", goal) :: any

    from.MeshId, to.MeshId = "rbxassetid://0", "rbxassetid://0"
    from.Scale, to.Scale = Vector3.one, options.scale or Vector3.one
  else
    const authored = harness.make("SurfaceAppearance", start) :: any

    start.MeshId, goal.MeshId = "rbxassetid://1", "rbxassetid://1"
    authored.EmissiveStrength = 2
    authored.EmissiveTint = Color3.new(1, 0.5, 1)
  end

  if options.key then
    const folder = harness.make("Folder", m) :: any

    folder.Name = "Frames"
    folder:SetAttribute("FrameSet", options.key)
    folder:SetAttribute("UnionSize", Vector3.new(2, 2, 2))
    folder:SetAttribute("UnionCenter", Vector3.zero)
    m:SetAttribute("FrameSet", options.key)

    for index = 1, options.count or 4 do
      const frame = harness.make(class, folder) :: any

      frame.Name = tostring(index)
      frame:SetAttribute("FrameSize", Vector3.new(1, 2, 2))
      frame:SetAttribute("FrameCenter", Vector3.new(1, 0, 0))

      if options.part then
        harness.make("SpecialMesh", frame).MeshId = `rbxassetid://{index}`

        if options.decal then
          harness.make("Decal", frame).Transparency = options.decal
        end
      else
        harness.make("SurfaceAppearance", frame).EmissiveStrength = 2
      end
    end
  end

  for name, v in options.attributes or {} do
    m:SetAttribute(name, v)
  end

  return m, start
end

-- the emit's one piece, which the pool clones whole into its folder
local function only(fake: fake_pool.Fake): any
  const pieces = fake.folder:GetChildren()

  expect(#pieces).toBe(1)

  return pieces[1]
end

-- the set the emit will find, told its frames differ by mesh, which lune holds
-- no content to tell
local function found(m: Instance, key: string): any
  const set = frame_store.find(m, key) :: any

  set.meshes = true

  return set
end

local function near(value: number, expected: number)
  expect(math.abs(value - expected) < 1e-6).toBe(true)
end

harness.suite(function()
  harness.describe("a mesh's frames", function()
    test("the frames play over the change duration on the piece", function()
      staged(function(applied, fake)
        const m = model({ key = "a", attributes = { DestroyDelay = 1 } })
        const set = found(m, "a")
        const env = effects.emit(0, m)
        const placed = only(fake)

        expect(#applied).toBe(1)
        expect(applied[1][1]).toBe(placed)
        expect(applied[1][2]).toBe(set.frames[1].mesh)

        scheduler.frame(0.5)
        expect(applied[#applied][2]).toBe(set.frames[2].mesh)

        scheduler.frame(0.25)
        expect(applied[#applied][2]).toBe(set.frames[3].mesh)

        scheduler.frame(0.25)
        expect(applied[#applied][2]).toBe(set.frames[4].mesh)

        env:Clear()
      end)
    end)

    test("the first pose and size are the first frame's", function()
      staged(function(_, fake)
        const m = model({ key = "b" })

        found(m, "b")

        const env = effects.emit(0, m)
        const placed = only(fake)

        expect(placed.Size).toBe(Vector3.new(2, 4, 4))
        expect(placed.CFrame.Position).toBe(Vector3.new(2, 0, 0))

        env:Clear()
      end)
    end)

    test("a size tween after the frames end is fitted to the frame held", function()
      staged(function(_, fake)
        const m = model({
          key = "c",
          goal = Vector3.new(8, 8, 8),
          attributes = { FlipbookChangeDuration = 0.25, DestroyDelay = 1 },
        })

        found(m, "c")

        const env = effects.emit(0, m)
        const placed = only(fake)

        scheduler.frame(0.5)
        scheduler.frame(0.6)

        expect(placed.Size).toBe(Vector3.new(4, 8, 8))
        expect(placed.CFrame.Position).toBe(Vector3.new(4, 0, 0))

        env:Clear()
      end)
    end)

    test("a special mesh's offset follows its scale tween after the frames end", function()
      staged(function(_, fake)
        const m = model({
          key = "d",
          part = true,
          count = 2,
          scale = Vector3.new(3, 3, 3),
          attributes = { FlipbookChangeDuration = 0.25, DestroyDelay = 1 },
        })

        frame_store.find(m, "d")

        const env = effects.emit(0, m)
        const placed = only(fake)
        const special = placed:FindFirstChildOfClass("SpecialMesh")

        expect(special.MeshId).toBe("rbxassetid://1")
        expect(special.Offset).toBe(Vector3.new(1, 0, 0))

        scheduler.frame(0.5)
        expect(special.MeshId).toBe("rbxassetid://2")

        scheduler.frame(0.6)
        expect(special.Offset).toBe(Vector3.new(3, 0, 0))
        expect(placed.Size).toBe(Vector3.new(4, 4, 4))
        expect(placed.CFrame.Position).toBe(Vector3.zero)

        env:Clear()
      end)
    end)

    test("SyncDuration plays the frames over the piece's duration", function()
      staged(function(applied)
        const m = model({ key = "e", attributes = { FlipbookChangeDuration = 4, SyncDuration = true } })
        const set = found(m, "e")
        const env = effects.emit(0, m)

        scheduler.frame(0.5)
        expect(applied[#applied][2]).toBe(set.frames[2].mesh)

        env:Clear()
      end)
    end)

    test("frames longer than the piece keep it until they end", function()
      staged(function(applied, fake)
        const m = model({ key = "f", attributes = { FlipbookChangeDuration = 2 } })
        const set = found(m, "f")
        const env = effects.emit(0, m)

        scheduler.frame(1.5)

        only(fake)
        expect(applied[#applied][2]).toBe(set.frames[3].mesh)
        expect(set.entry.lent).toBe(1)

        env:Clear()
      end)
    end)

    test("a clear gives the lent material back before the piece goes, and puts the start mesh back", function()
      staged(function(applied, fake)
        const m, start = model({ key = "g" })
        const set = found(m, "g")
        const env = effects.emit(0, m)
        const placed = only(fake)
        const material = set.frames[1].material

        expect(material.Parent).toBe(placed)
        expect(set.entry.lent).toBe(1)

        env:Clear()

        expect(set.entry.lent).toBe(0)
        expect(material.Parent ~= nil and material.Parent ~= placed).toBe(true)
        expect(applied[#applied][2]).toBe(start)
      end)
    end)

    test("glow with a frame set dresses the lent material", function()
      staged(function(_, fake)
        const m = model({ key = "h", attributes = { EmissiveStrength = 0.5, EmissiveTint = Color3.new(0.5, 1, 1) } })
        const set = found(m, "h")
        const env = effects.emit(0, m)
        const material = set.frames[1].material

        expect(material.Parent).toBe(only(fake))
        expect(material.EmissiveStrength).toBe(1)
        expect(material.EmissiveTint).toEqual(Color3.new(0.5, 1, 1))

        env:Clear()

        expect(material.EmissiveStrength).toBe(2)
      end)
    end)

    test("glow with no frame set multiplies the piece's own surface appearance", function()
      staged(function(_, fake)
        const m = model({ attributes = { EmissiveStrength = 0.5, EmissiveTint = Color3.new(0.5, 1, 1) } })
        const env = effects.emit(0, m)
        const authored = only(fake):FindFirstChildOfClass("SurfaceAppearance")

        expect(authored.EmissiveStrength).toBe(1)
        expect(authored.EmissiveTint).toEqual(Color3.new(0.5, 0.5, 1))

        env:Clear()
      end)
    end)

    test("FrameTransparency fades each decal frame from its own transparency", function()
      staged(function(_, fake)
        const m = model({
          key = "i",
          part = true,
          count = 2,
          decal = 0.2,
          attributes = { FrameTransparency = 0.5, DestroyDelay = 1 },
        })

        const set = frame_store.find(m, "i") :: any
        const env = effects.emit(0, m)
        const first, second = set.frames[1].material, set.frames[2].material

        expect(first.Parent).toBe(only(fake))
        near(first.Transparency, 0.6)

        scheduler.frame(0.8)

        expect(second.Parent).toBe(only(fake))
        near(second.Transparency, 0.6)
        near(first.Transparency, 0.2)

        env:Clear()

        near(second.Transparency, 0.2)
      end)
    end)

    test("a frame's offset runs along the piece's own axes when it starts turned", function()
      staged(function(_, fake)
        const turn = Vector3.new(0, 45, 0)
        const m = model({ key = "j", attributes = { MinInitRot = turn, MaxInitRot = turn } })

        found(m, "j")

        const env = effects.emit(0, m)
        const placed = only(fake)
        const along = placed.CFrame:VectorToWorldSpace(Vector3.new(2, 0, 0))

        expect((placed.CFrame.Position - along).Magnitude < 1e-4).toBe(true)
        expect((placed.CFrame.Position - Vector3.new(2, 0, 0)).Magnitude > 1).toBe(true)

        env:Clear()
      end)
    end)

    test("a mesh with no frame set sizes its piece as it did and applies nothing", function()
      staged(function(applied, fake)
        const m = model({ goal = Vector3.new(8, 8, 8), attributes = { DestroyDelay = 1 } })
        const env = effects.emit(0, m)
        const placed = only(fake)

        expect(placed.Size).toBe(Vector3.new(4, 4, 4))
        expect(placed.CFrame.Position).toBe(Vector3.zero)

        scheduler.frame(1.1)

        expect(placed.Size).toBe(Vector3.new(8, 8, 8))
        expect(#applied).toBe(0)

        env:Clear()
      end)
    end)

    test("SurfaceColor multiplies each frame's color", function()
      staged(function()
        const m = model({ key = "j", attributes = { SurfaceColor = Color3.new(1, 0.5, 1) } })
        const set = found(m, "j")
        const env = effects.emit(0, m)
        const material = set.frames[1].material

        expect(material.Color).toEqual(Color3.new(1, 0.5, 1))
        expect(material.EmissiveStrength).toBe(2)

        env:Clear()

        expect(material.Color).toEqual(Color3.new(1, 1, 1))
      end)
    end)

    test("SurfaceColor with no frame set multiplies the piece's own surface appearance", function()
      staged(function(_, fake)
        const m = model({ attributes = { SurfaceColor = Color3.new(1, 0.5, 1) } })
        const env = effects.emit(0, m)
        const authored = only(fake):FindFirstChildOfClass("SurfaceAppearance")

        expect(authored.Color).toEqual(Color3.new(1, 0.5, 1))

        env:Clear()
      end)
    end)

    test("every row at rest writes no material property", function()
      staged(function()
        const m = model({ key = "k" })
        const set = found(m, "k")

        frame_store.warm(set)

        -- marks that a write of any of the three would replace
        const material = set.frames[1].material
        const mark = Color3.new(0.25, 0.25, 0.25)

        material.Color = mark
        material.EmissiveTint = mark
        material.EmissiveStrength = 7

        const env = effects.emit(0, m)

        expect(material.Color).toEqual(mark)
        expect(material.EmissiveTint).toEqual(mark)
        expect(material.EmissiveStrength).toBe(7)

        env:Clear()
      end)
    end)

    test("glow at rest on a materials set leaves each frame's own glow alone", function()
      staged(function(_, fake)
        const m = model({ key = "i" })
        const set = found(m, "i")
        const env = effects.emit(0, m)
        const material = set.frames[1].material

        expect(material.Parent).toBe(only(fake))
        expect(material.EmissiveStrength).toBe(2)

        env:Clear()
      end)
    end)
  end)
end)
