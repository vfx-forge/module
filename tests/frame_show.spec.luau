local harness = require("@tests/harness")
local utility = require("@mod/utility")
local frame_show = require("@mod/frame_show")
local frame_store = require("@srv/frame_store")

local roblox = require("@lune/roblox") :: any

local test, expect = harness.test, harness.expect

-- each preload the store asked for, settled by hand
const preloads: { { parts: { Instance }, each: (id: string) -> (), done: () -> () } } = {}

-- the store started under a terrain of its own with both engine seams stood in, then put back once `body` ends
local function stored(body: (applied: { { any } }) -> ())
  local protect, terrain = utility.protectParent, workspace.Terrain
  local constructor, store, show = Instance, frame_store.engine, frame_show.engine
  local applied = {}

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
    preload = function(parts: { Instance }, each: (id: string) -> (), done: () -> ())
      table.insert(preloads, { parts = parts, each = each, done = done })
    end,
  }

  table.clear(preloads)

  frame_show.engine = {
    apply = function(piece: any, source: any)
      table.insert(applied, { piece, source })
    end,
  }

  local scope = {}
  local ok, err = pcall(function()
    frame_store.init(scope)
    body(applied)
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

local function meshes(key: string, count: number): (Instance, Instance)
  local root = harness.make("Model") :: any
  local folder = harness.make("Folder", root) :: any

  root:SetAttribute("FrameSet", key)
  folder.Name = "Frames"
  folder:SetAttribute("FrameSet", key)

  for index = 1, count do
    local frame = harness.make("MeshPart", folder) :: any

    frame.Name = tostring(index)
    harness.make("SurfaceAppearance", frame)
  end

  return root, folder
end

local function decaled(key: string, ids: { string }): (Instance, Instance)
  local root = harness.make("Model") :: any
  local folder = harness.make("Folder", root) :: any

  root:SetAttribute("FrameSet", key)
  folder.Name = "Frames"
  folder:SetAttribute("FrameSet", key)

  for index, id in ids do
    local frame = harness.make("Part", folder) :: any

    frame.Name = tostring(index)
    harness.make("SpecialMesh", frame).MeshId = id
    harness.make("Decal", frame)
  end

  return root, folder
end

local function worn(key: string, count: number): (any, any, any, any)
  local root, folder = meshes(key, count)
  local set = frame_store.find(root, key) :: any

  -- lune holds no mesh content to tell frames apart by
  set.meshes = true
  frame_store.warm(set)

  local piece = harness.make("MeshPart") :: any
  local start = harness.make("MeshPart") :: any

  return set, piece, start, folder
end

harness.suite(function()
  harness.describe("frame show", function()
    test("show applies the frame's mesh and wears its material", function()
      stored(function(applied)
        local set, piece, start = worn("a", 3)
        local shown = frame_show.new(set, piece, start)

        shown.show(2, Vector3.new(1, 1, 1))

        expect(#applied).toBe(1)
        expect(applied[1][1]).toBe(piece)
        expect(applied[1][2]).toBe(set.frames[2].mesh)
        expect(set.frames[2].material.Parent).toBe(piece)
        expect(set.entry.lent).toBe(1)

        shown.show(3, Vector3.new(1, 1, 1))

        expect(set.frames[2].material.Parent ~= piece).toBe(true)
        expect(set.frames[3].material.Parent).toBe(piece)
        expect(set.entry.lent).toBe(1)
      end)
    end)

    test("show of the shown mesh applies nothing", function()
      stored(function(applied)
        local set, piece, start = worn("b", 3)
        local shown = frame_show.new(set, piece, start)

        shown.show(2, Vector3.one)
        shown.show(2, Vector3.new(2, 2, 2))

        expect(#applied).toBe(1)
        expect(set.entry.lent).toBe(1)
      end)
    end)

    test("a missing frame keeps what is shown", function()
      stored(function(applied)
        local set, piece, start = worn("c", 2)
        local shown = frame_show.new(set, piece, start)

        shown.show(1, Vector3.one)
        shown.show(99, Vector3.one)

        expect(#applied).toBe(1)
        expect(set.frames[1].material.Parent).toBe(piece)
        expect(set.entry.lent).toBe(1)
      end)
    end)

    test("the piece's own surface appearance steps aside and comes back on release", function()
      stored(function()
        local set, piece, start = worn("d", 2)
        local own = harness.make("SurfaceAppearance", piece) :: any
        local shown = frame_show.new(set, piece, start)

        shown.show(1, Vector3.one)
        expect(own.Parent).toBe(nil)

        shown.release()
        expect(own.Parent).toBe(piece)
        expect(set.entry.lent).toBe(0)
        expect(set.frames[1].material.Parent ~= piece).toBe(true)
      end)
    end)

    test("glow multiplies the frame's own strength and tints it", function()
      stored(function()
        local root, folder = meshes("e", 2)
        local authored = folder:FindFirstChild("1"):FindFirstChildOfClass("SurfaceAppearance") :: any

        authored.EmissiveStrength = 2
        authored.EmissiveTint = Color3.new(1, 1, 0.5)

        local set = frame_store.find(root, "e") :: any

        frame_store.warm(set)

        local piece, start = harness.make("MeshPart") :: any, harness.make("MeshPart")
        local shown = frame_show.new(set, piece, start)

        shown.show(1, Vector3.one)
        shown.glow(3, Color3.new(1, 0.5, 1), Color3.new(1, 1, 1))

        local material = set.frames[1].material

        expect(material.EmissiveStrength).toBe(6)
        expect(material.EmissiveTint).toEqual(Color3.new(1, 0.5, 0.5))

        shown.show(1, Vector3.one)
        expect(material.EmissiveStrength).toBe(6)
      end)
    end)

    test("glow multiplies the frame's own color by the color row", function()
      stored(function()
        local root, folder = meshes("e2", 2)
        local authored = folder:FindFirstChild("1"):FindFirstChildOfClass("SurfaceAppearance") :: any

        authored.Color = Color3.new(0.5, 1, 1)
        authored.EmissiveStrength = 2

        local set = frame_store.find(root, "e2") :: any

        frame_store.warm(set)

        local piece, start = harness.make("MeshPart") :: any, harness.make("MeshPart")
        local shown = frame_show.new(set, piece, start)

        shown.show(1, Vector3.one)
        shown.glow(1, Color3.new(1, 1, 1), Color3.new(1, 0.5, 1))

        local material = set.frames[1].material

        expect(material.Color).toEqual(Color3.new(0.5, 0.5, 1))
        expect(material.EmissiveStrength).toBe(2)
      end)
    end)

    test("glow multiplies a decal frame's Color3 by the color row", function()
      stored(function()
        local root, folder = decaled("e3", { "rbxassetid://1" })
        local authored = folder:FindFirstChild("1"):FindFirstChildOfClass("Decal") :: any

        authored.Color3 = Color3.new(0.5, 1, 1)

        local set = frame_store.find(root, "e3") :: any

        frame_store.warm(set)

        local piece, start = harness.make("MeshPart") :: any, harness.make("MeshPart")
        local shown = frame_show.new(set, piece, start)

        shown.show(1, Vector3.one)
        shown.glow(1, Color3.new(1, 1, 1), Color3.new(1, 0.5, 1))

        expect(set.frames[1].material.Color3).toEqual(Color3.new(0.5, 0.5, 1))
      end)
    end)

    test("fit sizes the piece and answers the offset", function()
      stored(function()
        local root, folder = meshes("f", 1)

        folder:SetAttribute("UnionSize", Vector3.new(4, 4, 4))
        folder:SetAttribute("UnionCenter", Vector3.zero)

        local one = folder:FindFirstChild("1") :: any

        one:SetAttribute("FrameSize", Vector3.new(2, 4, 4))
        one:SetAttribute("FrameCenter", Vector3.new(1, 0, 0))

        local set = frame_store.find(root, "f") :: any

        frame_store.warm(set)

        local piece, start = harness.make("MeshPart") :: any, harness.make("MeshPart")
        local shown = frame_show.new(set, piece, start)
        local offset = shown.show(1, Vector3.new(8, 4, 4))

        expect(piece.Size).toBe(Vector3.new(4, 4, 4))
        expect(offset).toBe(Vector3.new(2, 0, 0))
      end)
    end)

    test("a fitted size the piece was last given is not written again", function()
      stored(function()
        local root, folder = meshes("r", 1)

        folder:SetAttribute("UnionSize", Vector3.new(4, 4, 4))
        folder:SetAttribute("UnionCenter", Vector3.zero)
        folder:FindFirstChild("1"):SetAttribute("FrameSize", Vector3.new(2, 4, 4))
        folder:FindFirstChild("1"):SetAttribute("FrameCenter", Vector3.zero)

        local set = frame_store.find(root, "r") :: any

        frame_store.warm(set)

        local piece, start = harness.make("MeshPart") :: any, harness.make("MeshPart")
        local shown = frame_show.new(set, piece, start)

        shown.show(1, Vector3.new(8, 4, 4))
        piece.Size = Vector3.new(9, 9, 9)
        shown.show(1, Vector3.new(8, 4, 4))

        expect(piece.Size).toBe(Vector3.new(9, 9, 9))

        shown.show(1, Vector3.new(4, 4, 4))

        expect(piece.Size).toBe(Vector3.new(2, 4, 4))
      end)
    end)

    test("release puts the start mesh back", function()
      stored(function(applied)
        local set, piece, start = worn("g", 2)
        local shown = frame_show.new(set, piece, start)

        shown.show(1, Vector3.one)
        shown.release()

        expect(#applied).toBe(2)
        expect(applied[2][1]).toBe(piece)
        expect(applied[2][2]).toBe(start)
      end)
    end)

    test("a plain part piece wears the material and releases with no apply", function()
      stored(function(applied)
        local set, _, start = worn("p", 2)
        local piece = harness.make("Part") :: any
        local shown = frame_show.new(set, piece, start)

        shown.show(1, Vector3.one)
        expect(set.frames[1].material.Parent).toBe(piece)

        shown.release()
        expect(#applied).toBe(0)
        expect(set.entry.lent).toBe(0)
      end)
    end)

    test("a release with no mesh switched applies nothing", function()
      stored(function(applied)
        local set, piece, start = worn("q", 2)
        local shown = frame_show.new(set, piece, start)

        set.meshes = false
        shown.show(1, Vector3.one)
        shown.release()

        expect(#applied).toBe(0)
      end)
    end)

    local function decaled(key: string): (any, any, any)
      local root = harness.make("Model") :: any
      local folder = harness.make("Folder", root) :: any

      root:SetAttribute("FrameSet", key)
      folder.Name = "Frames"
      folder:SetAttribute("FrameSet", key)
      folder:SetAttribute("UnionSize", Vector3.new(4, 4, 4))
      folder:SetAttribute("UnionCenter", Vector3.zero)

      for index = 1, 2 do
        local frame = harness.make("Part", folder) :: any

        frame.Name = tostring(index)
        harness.make("SpecialMesh", frame).MeshId = `rbxassetid://{index}`
        harness.make("Decal", frame)
        frame:SetAttribute("FrameSize", Vector3.new(2, 2, 2))
        frame:SetAttribute("FrameCenter", Vector3.new(index, 0, 0))
      end

      return root, folder, frame_store.find(root, key)
    end

    test("a special mesh piece switches by mesh id", function()
      stored(function(applied)
        local _, _, set = decaled("h")

        frame_store.warm(set)

        local piece, start = harness.make("Part") :: any, harness.make("Part") :: any
        local special = harness.make("SpecialMesh", piece) :: any
        local original = harness.make("SpecialMesh", start) :: any

        special.MeshId = "rbxassetid://0"
        special.Scale = Vector3.new(2, 1, 1)
        special.Offset = Vector3.new(0, 5, 0)
        original.MeshId = "rbxassetid://0"
        piece.Size = Vector3.new(3, 3, 3)

        local shown = frame_show.new(set, piece, start)

        shown.show(2, Vector3.new(4, 4, 4))

        expect(special.MeshId).toBe("rbxassetid://2")
        expect(special.Offset).toBe(Vector3.new(4, 5, 0))
        expect(piece.Size).toBe(Vector3.new(3, 3, 3))
        expect(#applied).toBe(0)

        -- a ZOffset's share draws the mesh's own Offset nearer with the rest
        -- of it; the frame's part comes from the Scale, written by the caller
        shown.show(2, Vector3.new(4, 4, 4), 0.5)
        expect(special.Offset).toBe(Vector3.new(4, 2.5, 0))

        shown.show(1, Vector3.new(4, 4, 4))
        expect(special.MeshId).toBe("rbxassetid://1")

        shown.release()
        expect(special.MeshId).toBe("rbxassetid://0")
        expect(special.Offset).toBe(Vector3.new(0, 5, 0))
        expect(#applied).toBe(0)
      end)
    end)

    local function near(value: number, expected: number)
      expect(math.abs(value - expected) < 1e-6).toBe(true)
    end

    test("fade lays the row over each decal frame's own transparency", function()
      stored(function()
        local _, folder, set = decaled("i")

        folder:FindFirstChild("1"):FindFirstChildOfClass("Decal").Transparency = 0.2
        folder:FindFirstChild("2"):FindFirstChildOfClass("Decal").Transparency = 0.4
        frame_store.warm(set)

        local piece, start = harness.make("Part") :: any, harness.make("Part") :: any

        harness.make("SpecialMesh", piece).MeshId = "rbxassetid://0"
        harness.make("SpecialMesh", start).MeshId = "rbxassetid://0"

        local shown = frame_show.new(set, piece, start)
        local first, second = set.frames[1].material, set.frames[2].material

        shown.show(1, Vector3.new(4, 4, 4))
        shown.fade(0.5)
        near(first.Transparency, 0.6)

        shown.show(2, Vector3.new(4, 4, 4))
        near(second.Transparency, 0.7)
        near(first.Transparency, 0.2)

        shown.fade(1)
        near(second.Transparency, 1)

        shown.release()
        near(second.Transparency, 0.4)
      end)
    end)

    test("fade leaves a surface appearance alone", function()
      stored(function()
        local set, piece, start = worn("j", 2)
        local shown = frame_show.new(set, piece, start)

        shown.show(1, Vector3.one)
        shown.fade(0.5)
        shown.show(2, Vector3.one)

        expect(set.frames[2].material.Parent).toBe(piece)
      end)
    end)

    test("release twice restores once", function()
      stored(function(applied)
        local set, piece, start = worn("r1", 2)
        local shown = frame_show.new(set, piece, start)

        shown.show(2, Vector3.one)
        shown.release()
        shown.release()

        expect(#applied).toBe(2)
        expect(set.entry.lent).toBe(0)
      end)
    end)

    test("release before any show restores nothing", function()
      stored(function(applied)
        local set, piece, start = worn("r2", 2)
        local own = harness.make("SurfaceAppearance", piece) :: any
        local shown = frame_show.new(set, piece, start)

        own.Parent = nil
        shown.release()

        expect(own.Parent).toBe(nil)
        expect(#applied).toBe(0)
      end)
    end)

    test("a glow set before a switch survives it", function()
      stored(function()
        local set, piece, start = worn("r3", 2)
        local shown = frame_show.new(set, piece, start)

        shown.glow(0.5, Color3.new(1, 1, 1), Color3.new(1, 1, 1))
        shown.show(1, Vector3.one)
        shown.show(2, Vector3.one)

        expect(set.frames[2].material.EmissiveStrength).toBe(0.5)
      end)
    end)

    test("a frame with no material in a materials set gives the piece its own appearances back", function()
      stored(function()
        local set, piece, start = worn("r4", 3)
        local own = harness.make("SurfaceAppearance", piece) :: any

        set.frames[2].source:FindFirstChildOfClass("SurfaceAppearance"):Destroy()
        set.frames[2].material:Destroy()
        set.frames[2].material = nil

        local shown = frame_show.new(set, piece, start)

        shown.show(1, Vector3.one)
        expect(own.Parent).toBe(nil)

        shown.show(2, Vector3.one)
        expect(own.Parent).toBe(piece)
        expect(set.entry.lent).toBe(0)

        shown.show(3, Vector3.one)
        expect(own.Parent).toBe(nil)
      end)
    end)

    test("materials = false never lends a frame's material", function()
      stored(function(applied)
        local set, piece, start = worn("s", 2)
        local own = harness.make("SurfaceAppearance", piece) :: any
        local shown = frame_show.new(set, piece, start, { materials = false })

        shown.show(1, Vector3.one)
        shown.glow(0.5, Color3.new(1, 1, 1), Color3.new(1, 1, 1))
        shown.show(2, Vector3.one)

        expect(#applied).toBe(2)
        expect(set.entry.lent).toBe(0)
        expect(own.Parent).toBe(piece)
        expect(set.frames[1].material.Parent ~= piece).toBe(true)
        expect(set.frames[2].material.Parent ~= piece).toBe(true)

        own.Parent = nil
        shown.release()

        expect(own.Parent).toBe(nil)
        expect(set.entry.lent).toBe(0)
      end)
    end)

    test("a special mesh piece restores the MeshId it had at new", function()
      stored(function()
        local _, _, set = decaled("r5")

        frame_store.warm(set)

        local piece, start = harness.make("Part") :: any, harness.make("Part") :: any
        local special = harness.make("SpecialMesh", piece) :: any
        local original = harness.make("SpecialMesh", start) :: any

        special.MeshId = "rbxassetid://0"
        original.MeshId = "rbxassetid://0"

        local shown = frame_show.new(set, piece, start)

        shown.show(2, Vector3.one)
        original.MeshId = "rbxassetid://9"
        shown.release()

        expect(special.MeshId).toBe("rbxassetid://0")
      end)
    end)

    -- frames whose meshes the store loads before any may be applied, under a model holding a start
    local function loading(key: string, count: number): (any, any)
      local root, folder = meshes(key, count)
      local start = harness.make("MeshPart", root) :: any

      start.Name = "Start"
      start.MeshContent = roblox.Content.fromUri("rbxassetid://900")

      for index = 1, count do
        folder:FindFirstChild(tostring(index)).MeshContent = roblox.Content.fromUri(`rbxassetid://{index}`)
      end

      local set = frame_store.find(root, key) :: any

      frame_store.warm(set, start)

      return set, start
    end

    test("warm loads the start and every frame mesh once", function()
      stored(function()
        local set, start = loading("l1", 3)

        frame_store.warm(set, start)

        expect(#preloads).toBe(1)
        expect(#preloads[1].parts).toBe(4)
        expect(preloads[1].parts[1]).toBe(start)
        expect(preloads[1].parts[3]).toBe(set.frames[2].source)
      end)
    end)

    test("a frame still loading holds the last ready frame, then the piece catches up", function()
      stored(function(applied)
        local set, start = loading("l2", 3)
        local piece = harness.make("MeshPart") :: any
        local shown = frame_show.new(set, piece, start)
        local preload = preloads[1]

        preload.each("rbxassetid://1")
        shown.show(1, Vector3.one)

        expect(#applied).toBe(1)
        expect(applied[1][2]).toBe(set.frames[1].mesh)

        shown.show(2, Vector3.one)
        shown.show(3, Vector3.one)

        expect(#applied).toBe(1)
        expect(set.frames[1].material.Parent).toBe(piece)

        preload.each("rbxassetid://3")
        shown.show(3, Vector3.one)

        expect(#applied).toBe(2)
        expect(applied[2][2]).toBe(set.frames[3].mesh)
        expect(set.frames[3].material.Parent).toBe(piece)

        preload.done()
        shown.show(2, Vector3.one)

        expect(#applied).toBe(3)
        expect(applied[3][2]).toBe(set.frames[2].mesh)
        expect(set.entry.lent).toBe(1)
      end)
    end)

    test("a held frame keeps the shape its bounds fit", function()
      stored(function()
        local set, start = loading("l3", 2)

        set.union = { size = Vector3.new(4, 4, 4), center = Vector3.zero }
        set.frames[1].bounds = { size = Vector3.new(2, 4, 4), center = Vector3.new(1, 0, 0) }
        set.frames[2].bounds = { size = Vector3.new(4, 4, 4), center = Vector3.zero }

        local piece = harness.make("MeshPart") :: any
        local shown = frame_show.new(set, piece, start)

        preloads[1].each("rbxassetid://1")
        shown.show(1, Vector3.new(4, 4, 4))

        local offset = shown.show(2, Vector3.new(8, 8, 8))

        expect(piece.Size).toBe(Vector3.new(4, 8, 8))
        expect(offset).toBe(Vector3.new(2, 0, 0))
      end)
    end)

    test("a piece already wearing a frame's mesh shows that frame at its bounds while the mesh loads", function()
      stored(function(applied)
        local set, start = loading("l5", 2)

        set.union = { size = Vector3.new(4, 8, 4), center = Vector3.new(0, 4, 0) }
        set.frames[1].bounds = { size = Vector3.new(4, 2, 4), center = Vector3.new(0, 1, 0) }
        set.frames[2].bounds = { size = Vector3.new(4, 8, 4), center = Vector3.new(0, 4, 0) }

        local piece = harness.make("MeshPart") :: any

        piece.MeshContent = roblox.Content.fromUri("rbxassetid://1")

        local shown = frame_show.new(set, piece, start)
        local offset = shown.show(1, Vector3.new(4, 8, 4))

        expect(#applied).toBe(0)
        expect(piece.Size).toBe(Vector3.new(4, 2, 4))
        expect(offset).toBe(Vector3.new(0, -3, 0))

        offset = shown.show(2, Vector3.new(4, 8, 4))

        expect(#applied).toBe(0)
        expect(piece.Size).toBe(Vector3.new(4, 2, 4))
        expect(offset).toBe(Vector3.new(0, -3, 0))

        preloads[1].done()
        offset = shown.show(2, Vector3.new(4, 8, 4))

        expect(#applied).toBe(1)
        expect(piece.Size).toBe(Vector3.new(4, 8, 4))
        expect(offset).toBe(Vector3.zero)
      end)
    end)

    test("before any frame is ready the piece keeps its start mesh and surface", function()
      stored(function(applied)
        local set, start = loading("l4", 2)
        local piece = harness.make("MeshPart") :: any
        local own = harness.make("SurfaceAppearance", piece) :: any
        local shown = frame_show.new(set, piece, start)
        local offset = shown.show(1, Vector3.new(3, 3, 3))

        expect(#applied).toBe(0)
        expect(own.Parent).toBe(piece)
        expect(set.entry.lent).toBe(0)
        expect(piece.Size).toBe(Vector3.new(3, 3, 3))
        expect(offset).toBe(Vector3.zero)

        shown.release()
        expect(#applied).toBe(0)

        preloads[1].done()
        shown.show(1, Vector3.one)

        expect(#applied).toBe(1)
        expect(own.Parent).toBe(nil)
      end)
    end)
  end)
end)
