local harness = require("@tests/harness")
local effects = require("@srv/effects")
local utility = require("@mod/utility")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local fake_pool = require("@tests/fake_pool")
local frame_show = require("@mod/frame_show")
local frame_store = require("@srv/frame_store")
local texture_show = require("@mod/texture_show")
local test, expect = harness.test, harness.expect

local mesh = require("@vfx/mesh")

const Color3 = harness.datatypes.Color3
const Vector3 = harness.datatypes.Vector3

type Options = {
  textures: string?,
  count: number?,
  frames: string?,
  attributes: { [string]: any }?,
}

-- the mesh registered on the effects service and the pool, with the frame
-- store started under a terrain of its own and both engine seams stood in,
-- then put back once `body` ends. `applied` keeps every ApplyMesh
const function staged(body: (applied: { { any } }, fake: fake_pool.Fake) -> ())
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

-- a mesh model whose start is a MeshPart wearing a surface appearance of
-- strength 2, with `textures` a Textures folder of `count` carriers, each
-- holding a surface appearance of strength 3, and with `frames` a Frames
-- folder of two MeshPart frames wearing their own
const function model(options: Options): any
  const m = harness.make("Model", harness.make("Folder")) :: any
  const start = harness.make("MeshPart", m) :: any
  const goal = harness.make("MeshPart", m) :: any
  const authored = harness.make("SurfaceAppearance", start) :: any

  start.Name, goal.Name = "Start", "End"
  start.Size, goal.Size = Vector3.new(4, 4, 4), Vector3.new(4, 4, 4)
  start.MeshId, goal.MeshId = "rbxassetid://1", "rbxassetid://1"
  authored.EmissiveStrength = 2

  if options.textures then
    const folder = harness.make("Folder", m) :: any
    const count = options.count or 3

    folder.Name = "Textures"
    folder:SetAttribute("TextureSet", options.textures)
    folder:SetAttribute("TextureCount", count)
    m:SetAttribute("TextureSet", options.textures)

    for index = 1, count do
      const carrier = harness.make("Part", folder) :: any

      carrier.Name = tostring(index)
      carrier.Size = Vector3.zero
      carrier.Transparency = 1
      harness.make("SurfaceAppearance", carrier).EmissiveStrength = 3
    end
  end

  if options.frames then
    const folder = harness.make("Folder", m) :: any

    folder.Name = "Frames"
    folder:SetAttribute("FrameSet", options.frames)
    m:SetAttribute("FrameSet", options.frames)

    for index = 1, 2 do
      const frame = harness.make("MeshPart", folder) :: any

      frame.Name = tostring(index)
      harness.make("SurfaceAppearance", frame)
    end
  end

  for name, v in options.attributes or {} do
    m:SetAttribute(name, v)
  end

  return m
end

-- the emit's one piece, which the pool clones whole into its folder
const function only(fake: fake_pool.Fake): any
  const pieces = fake.folder:GetChildren()

  expect(#pieces).toBe(1)

  return pieces[1]
end

const function surfaces(piece: Instance): { Instance }
  const found = {}

  for _, child in piece:GetChildren() do
    if child:IsA("SurfaceAppearance") then
      table.insert(found, child)
    end
  end

  return found
end

harness.suite(function()
  harness.describe("a mesh's texture set", function()
    test("a piece wears frame 1's surface at time 0", function()
      staged(function(_, fake)
        const m = model({ textures = "a" })
        const set = frame_store.findTextures(m, "a") :: any
        const env = effects.emit(0, m)
        const placed = only(fake)
        const worn = surfaces(placed)

        expect(#worn).toBe(1)
        expect(worn[1]).toBe(set.frames[1].material)
        expect(set.entry.lent).toBe(1)

        env:Clear()
      end)
    end)

    test("frames step at TextureFps and loop", function()
      staged(function(_, fake)
        const m = model({ textures = "b", attributes = { TextureFps = 10 } })
        const set = frame_store.findTextures(m, "b") :: any
        const env = effects.emit(0, m)
        const placed = only(fake)

        scheduler.frame(0.15)
        expect(set.frames[2].material.Parent).toBe(placed)
        expect(set.frames[1].material.Parent ~= placed).toBe(true)

        scheduler.frame(0.1)
        expect(set.frames[3].material.Parent).toBe(placed)

        scheduler.frame(0.1)
        expect(set.frames[1].material.Parent).toBe(placed)
        expect(#surfaces(placed)).toBe(1)
        expect(set.entry.lent).toBe(1)

        env:Clear()
      end)
    end)

    test("the clock keeps looping through the piece's destroy delay", function()
      staged(function(_, fake)
        const m = model({ textures = "b2", attributes = { TextureFps = 10, DestroyDelay = 1 } })
        const set = frame_store.findTextures(m, "b2") :: any
        const env = effects.emit(0, m)
        const placed = only(fake)

        scheduler.frame(1)
        scheduler.frame(0.15)
        expect(set.frames[3].material.Parent).toBe(placed)

        env:Clear()
      end)
    end)

    test("the glow multiplies the worn surface", function()
      staged(function(_, fake)
        const m = model({
          textures = "c",
          attributes = { EmissiveStrength = 0.5, SurfaceColor = Color3.new(1, 0.5, 1) },
        })
        const set = frame_store.findTextures(m, "c") :: any
        const env = effects.emit(0, m)
        const material = set.frames[1].material

        expect(material.Parent).toBe(only(fake))
        expect(material.EmissiveStrength).toBe(1.5)
        expect(material.Color).toEqual(Color3.new(1, 0.5, 1))

        env:Clear()

        expect(material.EmissiveStrength).toBe(3)
        expect(material.Color).toEqual(Color3.new(1, 1, 1))
      end)
    end)

    test("a texture set and a frame set play together, the texture set's surface worn", function()
      staged(function(applied, fake)
        const m = model({ textures = "d", frames = "e", attributes = { EmissiveStrength = 0.5 } })
        const textures = frame_store.findTextures(m, "d") :: any
        const frames = frame_store.find(m, "e") :: any

        -- lune holds no mesh content to tell frames apart by
        frames.meshes = true

        const env = effects.emit(0, m)
        const placed = only(fake)
        const worn = surfaces(placed)

        expect(#applied).toBe(1)
        expect(applied[1][2]).toBe(frames.frames[1].mesh)
        expect(#worn).toBe(1)
        expect(worn[1]).toBe(textures.frames[1].material)
        expect(worn[1].EmissiveStrength).toBe(1.5)
        expect(frames.entry.lent).toBe(0)

        scheduler.frame(0.8)
        expect(applied[#applied][2]).toBe(frames.frames[2].mesh)
        expect(#surfaces(placed)).toBe(1)
        expect(frames.entry.lent).toBe(0)

        env:Clear()
      end)
    end)

    test("a clear gives the worn surface back", function()
      staged(function(_, fake)
        const m = model({ textures = "f" })
        const set = frame_store.findTextures(m, "f") :: any
        const env = effects.emit(0, m)
        const placed = only(fake)
        const material = set.frames[1].material

        expect(material.Parent).toBe(placed)

        env:Clear()

        expect(set.entry.lent).toBe(0)
        expect(material.Parent ~= nil and material.Parent ~= placed).toBe(true)
      end)
    end)

    test("release puts the piece's own surface back", function()
      staged(function()
        const m = model({ textures = "f2" })
        const set = frame_store.findTextures(m, "f2") :: any

        frame_store.warm(set)

        const piece = harness.make("MeshPart") :: any
        const own = harness.make("SurfaceAppearance", piece) :: any
        const shown = texture_show.new(set, piece)

        shown.show(1)
        expect(own.Parent).toBe(nil)
        expect(set.frames[1].material.Parent).toBe(piece)

        shown.show(2)
        expect(own.Parent).toBe(nil)
        expect(set.frames[1].material.Parent ~= piece).toBe(true)
        expect(set.entry.lent).toBe(1)

        shown.release()
        expect(own.Parent).toBe(piece)
        expect(#surfaces(piece)).toBe(1)
        expect(set.entry.lent).toBe(0)
      end)
    end)

    test("a missing Textures folder plays the mesh as before", function()
      staged(function(applied, fake)
        const m = model({ attributes = { TextureSet = "gone", EmissiveStrength = 0.5 } })
        const env = effects.emit(0, m)
        const worn = surfaces(only(fake))

        expect(frame_store.findTextures(m, "gone")).toBe(nil)
        expect(#worn).toBe(1)
        expect((worn[1] :: any).EmissiveStrength).toBe(1)
        expect(#applied).toBe(0)

        env:Clear()
      end)
    end)
  end)

  harness.describe("a mesh's texture set looping", function()
    -- the texture the piece wears after each step, a time and the frame
    -- expected once the clock reaches it
    const function wears(set: any, placed: Instance, steps: { { number } })
      local now = 0

      for _, step in steps do
        if step[1] > now then
          scheduler.frame(step[1] - now)
          now = step[1]
        end

        expect(set.frames[step[2]].material.Parent).toBe(placed)
        expect(#surfaces(placed)).toBe(1)
      end
    end

    test("a set that does not loop plays one cycle and holds the last", function()
      staged(function(_, fake)
        const m = model({ textures = "loop-a", attributes = { TextureFps = 10, TextureLoop = false } })
        const set = frame_store.findTextures(m, "loop-a") :: any
        const env = effects.emit(0, m)

        wears(set, only(fake), { { 0, 1 }, { 0.15, 2 }, { 0.25, 3 }, { 0.35, 3 }, { 0.65, 3 } })

        env:Clear()
      end)
    end)

    test("a cycle that does not loop and outlasts the piece keeps it until it ends", function()
      staged(function(_, fake)
        const m = model({ textures = "loop-b", attributes = { TextureFps = 1, TextureLoop = false } })
        const set = frame_store.findTextures(m, "loop-b") :: any

        effects.emit(0, m)

        wears(set, only(fake), { { 0, 1 }, { 1.5, 2 }, { 2.5, 3 } })
        expect(set.entry.lent).toBe(1)

        scheduler.frame(0.75)
        expect(set.entry.lent).toBe(0)
      end)
    end)

    test("a counted loop plays its cycles, then holds the last", function()
      staged(function(_, fake)
        const m = model({ textures = "loop-c", attributes = { TextureFps = 10, TextureLoopCount = 2 } })
        const set = frame_store.findTextures(m, "loop-c") :: any
        const env = effects.emit(0, m)

        wears(set, only(fake), { { 0, 1 }, { 0.15, 2 }, { 0.35, 1 }, { 0.55, 3 }, { 0.65, 3 }, { 0.75, 3 } })

        env:Clear()
      end)
    end)

    test("a counted loop longer than the piece keeps it for all its cycles", function()
      staged(function(_, fake)
        const m = model({ textures = "loop-d", attributes = { TextureFps = 2, TextureLoopCount = 2 } })
        const set = frame_store.findTextures(m, "loop-d") :: any

        effects.emit(0, m)

        wears(set, only(fake), { { 0, 1 }, { 1.75, 1 }, { 2.75, 3 } })
        expect(set.entry.lent).toBe(1)

        scheduler.frame(0.5)
        expect(set.entry.lent).toBe(0)
      end)
    end)

    test("a synced set plays one cycle over the piece's duration, whatever its fps", function()
      staged(function(_, fake)
        const m = model({ textures = "loop-e", attributes = { TextureFps = 1, TextureSyncDuration = true } })
        const set = frame_store.findTextures(m, "loop-e") :: any

        effects.emit(0, m)

        wears(set, only(fake), { { 0, 1 }, { 0.4, 2 }, { 0.7, 3 }, { 0.95, 3 } })

        scheduler.frame(0.25)
        expect(set.entry.lent).toBe(0)
      end)
    end)

    test("a synced counted loop fits its cycles in the piece's duration", function()
      staged(function(_, fake)
        const m = model({
          textures = "loop-f",
          attributes = { TextureFps = 1, TextureSyncDuration = true, TextureLoopCount = 2 },
        })
        const set = frame_store.findTextures(m, "loop-f") :: any

        effects.emit(0, m)

        wears(set, only(fake), { { 0, 1 }, { 0.2, 2 }, { 0.6, 1 }, { 0.95, 3 } })

        scheduler.frame(0.25)
        expect(set.entry.lent).toBe(0)
      end)
    end)

    test("the endless loop every set plays by default never outlasts the piece", function()
      staged(function(_, fake)
        const m = model({ textures = "loop-g", attributes = { TextureFps = 1 } })
        const set = frame_store.findTextures(m, "loop-g") :: any

        effects.emit(0, m)

        wears(set, only(fake), { { 0, 1 }, { 0.95, 1 } })

        scheduler.frame(0.25)
        expect(set.entry.lent).toBe(0)
      end)
    end)
  end)
end)
