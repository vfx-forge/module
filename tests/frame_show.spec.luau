local harness = require("@tests/harness")
local utility = require("@mod/utility")
local frame_show = require("@mod/frame_show")
local frame_store = require("@srv/frame_store")

local test, expect = harness.test, harness.expect

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
  }

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
        shown.glow(3, Color3.new(1, 0.5, 1))

        local material = set.frames[1].material

        expect(material.EmissiveStrength).toBe(6)
        expect(material.EmissiveTint).toEqual(Color3.new(1, 0.5, 0.5))

        shown.show(1, Vector3.one)
        expect(material.EmissiveStrength).toBe(6)
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
        expect(special.Offset).toBe(Vector3.new(4, 0, 0))
        expect(piece.Size).toBe(Vector3.new(3, 3, 3))
        expect(#applied).toBe(0)

        shown.show(1, Vector3.new(4, 4, 4))
        expect(special.MeshId).toBe("rbxassetid://1")

        shown.release()
        expect(special.MeshId).toBe("rbxassetid://0")
        expect(special.Offset).toBe(Vector3.new(0, 5, 0))
        expect(#applied).toBe(0)
      end)
    end)
  end)
end)
