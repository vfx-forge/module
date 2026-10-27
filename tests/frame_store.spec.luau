local harness = require("@tests/harness")
local utility = require("@mod/utility")
local frame_store = require("@srv/frame_store")

local test, expect = harness.test, harness.expect

local PARK = CFrame.new(0, -20000, 0)

type Stand = {
  terrain: Instance,
  clock: number,
  detach: boolean,
}

-- the store started under a terrain of its own with the engine seam stood in, then put back once `body` ends
local function stored(body: (stand: Stand) -> ())
  local protect, terrain = utility.protectParent, workspace.Terrain
  local constructor, engine = Instance, frame_store.engine
  local stand = { terrain = harness.make("Folder"), clock = 0, detach = false } :: Stand
  local scope = {}

  utility.protectParent = function() end
  workspace.Terrain = stand.terrain :: any

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = harness.datatypes.Instance

  frame_store.engine = {
    now = function()
      return stand.clock
    end,
    detaches = function()
      return stand.detach
    end,
    maps = function()
      return 1
    end,
    -- the engine's Clone, which answers nil for an instance that is not Archivable; lune's clones one anyway
    clone = function(instance: Instance)
      return if instance.Archivable then instance:Clone() else nil
    end,
  }

  local ok, err = pcall(function()
    frame_store.init(scope)
    body(stand)
  end)

  utility.cleanupScope(scope)
  frame_store.setBudget(128)
  frame_store.engine = engine
  utility.protectParent, workspace.Terrain = protect, terrain

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = constructor

  if not ok then
    error(err, 0)
  end
end

local function model(key: string, count: number): (Instance, Instance)
  local root = harness.make("Model") :: any
  local folder = harness.make("Folder", root) :: any

  harness.make("Part", root).Name = "Start"
  harness.make("Part", root).Name = "End"

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

-- a model whose frames are Parts wearing a SpecialMesh by id and a Decal each
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

local function warmed(key: string, now: number): any
  local root = model(key, 3)
  local set = frame_store.find(root, key) :: any

  frame_store.engine.now = function()
    return now
  end

  frame_store.warm(set)

  return set
end

harness.suite(function()
  harness.describe("the frame store", function()
    test("find registers a folder by its key", function()
      stored(function()
        local root = model("a", 3)
        local set = frame_store.find(root, "a") :: any

        expect(set ~= nil).toBe(true)
        expect(#set.frames).toBe(3)
        expect(set.materials).toBe(true)
        expect(set.key).toBe("a")
      end)
    end)

    test("an unknown key and no folder answers nil", function()
      stored(function()
        local root = harness.make("Model")

        expect(frame_store.find(root, "missing")).toBe(nil)
      end)
    end)

    test("a detached folder resolves by key", function()
      stored(function(stand: Stand)
        stand.detach = true

        local root, folder = model("b", 3)
        local set = frame_store.find(root, "b")

        expect(folder.Parent).toBe(nil)

        local other = harness.make("Model")

        other:SetAttribute("FrameSet", "b")
        expect(frame_store.find(other, "b")).toBe(set)
      end)
    end)

    test("a second folder of a known key is detached and not read again", function()
      stored(function(stand: Stand)
        stand.detach = true

        local first = model("c", 3)
        local second, folder = model("c", 5)
        local set = frame_store.find(first, "c") :: any

        expect(frame_store.find(second, "c")).toBe(set)
        expect(folder.Parent).toBe(nil)
        expect(#set.frames).toBe(3)
      end)
    end)

    test("a folder stays put while the game does not detach", function()
      stored(function()
        local root, folder = model("d", 2)

        frame_store.find(root, "d")
        expect(folder.Parent).toBe(root)
      end)
    end)

    test("a frame's bounds are read off its attributes", function()
      stored(function()
        local root, folder = model("e", 2)

        folder:SetAttribute("UnionSize", Vector3.new(4, 4, 4))
        folder:SetAttribute("UnionCenter", Vector3.new(0, 1, 0))
        folder:FindFirstChild("1"):SetAttribute("FrameSize", Vector3.new(1, 2, 3))
        folder:FindFirstChild("1"):SetAttribute("FrameCenter", Vector3.new(0, 1, 0))

        local set = frame_store.find(root, "e") :: any

        expect(set.union).toEqual({ size = Vector3.new(4, 4, 4), center = Vector3.new(0, 1, 0) })
        expect(set.frames[1].size).toBe(Vector3.new(1, 2, 3))
        expect(set.frames[2].size).toBe(nil)
      end)
    end)

    test("warm parks every frame out of view", function()
      stored(function(stand: Stand)
        local set = warmed("f", 1)

        expect(set.entry.parked).toBe(true)
        expect(set.entry.textures).toBe(3)

        for _, frame in set.frames do
          expect(frame.mesh.Size).toBe(Vector3.zero)
          expect(frame.mesh.Transparency).toBe(1)
          expect(frame.mesh.CFrame).toBe(PARK)
          expect(#frame.mesh:GetChildren()).toBe(0)
          expect(frame.material.ClassName).toBe("SurfaceAppearance")
          expect(frame.material.Parent:IsA("BasePart")).toBe(true)
          expect(frame.material.Parent.CFrame).toBe(PARK)
          expect(frame.mesh:IsDescendantOf(stand.terrain)).toBe(true)
        end
      end)
    end)

    test("a first lend is the parked copy and a second lend of one frame is a clone", function()
      stored(function()
        local set = warmed("g", 1)
        local first = frame_store.lend(set, 1) :: any
        local second = frame_store.lend(set, 1) :: any

        expect(first).toBe(set.frames[1].material)
        expect(second ~= first).toBe(true)
        expect(second.Parent).toBe(nil)
        expect(set.entry.lent).toBe(2)

        frame_store.giveBack(set, 1, second)
        expect(set.entry.lent).toBe(1)
      end)
    end)

    test("a frame without a material lends nothing", function()
      stored(function()
        local root, folder = model("h", 2)

        folder:FindFirstChild("2"):FindFirstChildOfClass("SurfaceAppearance"):Destroy()

        local set = frame_store.find(root, "h") :: any

        frame_store.warm(set)
        expect(set.materials).toBe(true)
        expect(frame_store.lend(set, 2)).toBe(nil)
        expect(set.entry.lent).toBe(0)
      end)
    end)

    test("giveBack restores the authored glow", function()
      stored(function()
        local root, folder = model("i", 1)
        local authored = folder:FindFirstChild("1"):FindFirstChildOfClass("SurfaceAppearance") :: any

        authored.EmissiveStrength = 2

        local set = frame_store.find(root, "i") :: any

        frame_store.warm(set)

        local lent = frame_store.lend(set, 1) :: any

        lent.EmissiveStrength = 5
        frame_store.giveBack(set, 1, lent)

        expect(set.frames[1].material.EmissiveStrength).toBe(2)
        expect(set.frames[1].material.Parent:IsA("BasePart")).toBe(true)
        expect(set.entry.lent).toBe(0)
      end)
    end)

    test("the budget lets the oldest set go", function()
      stored(function()
        frame_store.setBudget(6)

        local a, b, c = warmed("j1", 1), warmed("j2", 2), warmed("j3", 3)

        expect(a.entry.parked).toBe(false)
        expect(a.frames[1].mesh.Parent).toBe(nil)
        expect(a.frames[1].material.Parent.Parent).toBe(nil)
        expect(b.entry.parked).toBe(true)
        expect(c.entry.parked).toBe(true)
      end)
    end)

    test("eviction never takes a set with a lent frame", function()
      stored(function()
        frame_store.setBudget(6)

        local a = warmed("k1", 1)
        local lent = frame_store.lend(a, 1)
        local b, c = warmed("k2", 2), warmed("k3", 3)

        expect(a.entry.parked).toBe(true)
        expect(b.entry.parked).toBe(false)
        expect(c.entry.parked).toBe(true)
        expect(lent ~= nil).toBe(true)
      end)
    end)

    test("warm on an evicted set parks it again", function()
      stored(function()
        frame_store.setBudget(6)

        local a = warmed("l1", 1)

        warmed("l2", 2)
        warmed("l3", 3)
        expect(a.entry.parked).toBe(false)

        frame_store.warm(a)
        expect(a.entry.parked).toBe(true)
        expect(a.frames[1].mesh.Parent ~= nil).toBe(true)
        expect(a.frames[1].material.Parent.Parent ~= nil).toBe(true)
      end)
    end)

    test("frames with differing special meshes switch meshes", function()
      stored(function()
        local root = decaled("m1", { "rbxassetid://1", "rbxassetid://2" })
        local set = frame_store.find(root, "m1") :: any

        expect(set.meshes).toBe(true)
        expect(set.materials).toBe(true)
      end)
    end)

    test("frames sharing one special mesh switch none", function()
      stored(function()
        local root = decaled("m2", { "rbxassetid://1", "rbxassetid://1", "rbxassetid://1" })
        local set = frame_store.find(root, "m2") :: any

        expect(set.meshes).toBe(false)
      end)
    end)

    test("a decal frame parks on a part copy that holds only the decal", function()
      stored(function()
        local root = decaled("m3", { "rbxassetid://1", "rbxassetid://2" })
        local set = frame_store.find(root, "m3") :: any

        frame_store.warm(set)

        for _, frame in set.frames do
          local home = frame.material.Parent

          expect(frame.material.ClassName).toBe("Decal")
          expect(home.ClassName).toBe("Part")
          expect(home.CFrame).toBe(PARK)
          expect(#home:GetChildren()).toBe(1)
        end
      end)
    end)

    test("a part frame's mesh copy keeps its special mesh", function()
      stored(function()
        local root = decaled("m4", { "rbxassetid://7" })
        local set = frame_store.find(root, "m4") :: any

        frame_store.warm(set)

        local mesh = set.frames[1].mesh
        local kept = mesh:FindFirstChildOfClass("SpecialMesh")

        expect(#mesh:GetChildren()).toBe(1)
        expect(kept.MeshId).toBe("rbxassetid://7")
        expect(mesh:FindFirstChildOfClass("Decal")).toBe(nil)
        expect(mesh.CFrame).toBe(PARK)
      end)
    end)

    test("giveBack restores a decal's authored glow", function()
      stored(function()
        local root, folder = decaled("m5", { "rbxassetid://1" })
        local authored = folder:FindFirstChild("1"):FindFirstChildOfClass("Decal") :: any

        authored.EmissiveStrength = 3
        authored.EmissiveTint = Color3.new(1, 0, 0)

        local set = frame_store.find(root, "m5") :: any

        frame_store.warm(set)

        local lent = frame_store.lend(set, 1) :: any
        local clone = frame_store.lend(set, 1) :: any

        expect(clone.EmissiveStrength).toBe(3)
        expect(clone.EmissiveTint).toBe(Color3.new(1, 0, 0))

        lent.EmissiveStrength = 9
        lent.EmissiveTint = Color3.new(0, 0, 1)
        frame_store.giveBack(set, 1, lent)
        frame_store.giveBack(set, 1, clone)

        expect(set.frames[1].material.EmissiveStrength).toBe(3)
        expect(set.frames[1].material.EmissiveTint).toBe(Color3.new(1, 0, 0))
        expect(set.entry.lent).toBe(0)
      end)
    end)

    test("a folder short of its FrameCount answers nil and stays until it is whole", function()
      stored(function(stand: Stand)
        stand.detach = true

        local root, folder = model("n1", 2)

        folder:SetAttribute("FrameCount", 3)

        expect(frame_store.find(root, "n1")).toBe(nil)
        expect(folder.Parent).toBe(root)

        harness.make("MeshPart", folder).Name = "3"

        local set = frame_store.find(root, "n1") :: any

        expect(#set.frames).toBe(3)
        expect(folder.Parent).toBe(nil)
      end)
    end)

    test("a folder holding its FrameCount registers at once", function()
      stored(function()
        local root, folder = model("n2", 2)

        folder:SetAttribute("FrameCount", 2)

        local set = frame_store.find(root, "n2") :: any

        expect(#set.frames).toBe(2)
      end)
    end)

    test("a folder detached before the store started again registers its set again", function()
      stored(function(stand: Stand)
        stand.detach = true

        local root, folder = model("n3", 3)
        local first = frame_store.find(root, "n3")
        local again = {}

        expect(folder.Parent).toBe(nil)

        frame_store.init(again)

        local set = frame_store.find(root, "n3") :: any

        utility.cleanupScope(again)

        expect(set ~= nil and set ~= first).toBe(true)
        expect(#set.frames).toBe(3)
      end)
    end)

    test("a new park holder parks every set again under it", function()
      stored(function(stand: Stand)
        local set = warmed("n4", 1)
        local other = warmed("n5", 2)
        local old = set.frames[1].mesh
        local holder = old.Parent

        holder:Destroy()
        frame_store.warm(set)

        local mesh = set.frames[1].mesh

        expect(mesh ~= old).toBe(true)
        expect(mesh.Parent ~= nil and mesh.Parent ~= holder).toBe(true)
        expect(mesh:IsDescendantOf(stand.terrain)).toBe(true)
        expect(set.frames[1].material.Parent.Parent).toBe(mesh.Parent)
        expect(set.entry.parked).toBe(true)
        expect(other.entry.parked).toBe(false)
        expect(other.frames[1].mesh).toBe(nil)

        frame_store.warm(other)

        expect(other.entry.parked).toBe(true)
        expect(other.frames[1].mesh.Parent).toBe(mesh.Parent)
      end)
    end)

    test("a frame material that is not Archivable parks nothing of its set and warns once", function()
      stored(function(stand: Stand)
        local root, folder = decaled("n6", { "rbxassetid://1", "rbxassetid://2" })

        folder:FindFirstChild("2"):FindFirstChildOfClass("Decal").Archivable = false

        local set = frame_store.find(root, "n6") :: any
        local warnings = harness.captureWarnings(function()
          frame_store.warm(set)
          frame_store.warm(set)
        end)

        local holder = stand.terrain:FindFirstChild("VFXForge"):FindFirstChild("frames")
        local said = 0

        for _, text in warnings do
          if string.find(text, "n6", 1, true) then
            said += 1
          end
        end

        expect(#holder:GetChildren()).toBe(0)
        expect(said).toBe(1)
        expect(set.entry.parked).toBe(false)
        expect(set.frames[1].mesh).toBe(nil)
        expect(set.frames[1].material).toBe(nil)
        expect(frame_store.lend(set, 1)).toBe(nil)
      end)
    end)

    test("a lent decal's clone and its return carry the authored transparency", function()
      stored(function()
        local root, folder = decaled("n7", { "rbxassetid://1" })
        local authored = folder:FindFirstChild("1"):FindFirstChildOfClass("Decal") :: any

        authored.Transparency = 0.2

        local set = frame_store.find(root, "n7") :: any

        frame_store.warm(set)

        local lent = frame_store.lend(set, 1) :: any

        lent.Transparency = 0.7

        local clone = frame_store.lend(set, 1) :: any

        expect(clone.Transparency).toBe(authored.Transparency)

        frame_store.giveBack(set, 1, lent)
        frame_store.giveBack(set, 1, clone)

        expect(set.frames[1].material.Transparency).toBe(authored.Transparency)
      end)
    end)

    test("a lower budget lets sets go at once", function()
      stored(function()
        local a, b, c = warmed("n8", 1), warmed("n9", 2), warmed("n10", 3)

        frame_store.setBudget(6)

        expect(a.entry.parked).toBe(false)
        expect(a.frames[1].mesh.Parent).toBe(nil)
        expect(b.entry.parked).toBe(true)
        expect(c.entry.parked).toBe(true)
      end)
    end)

    test("the budget defaults to 128 textures", function()
      expect(frame_store.getBudget()).toBe(128)
    end)
  end)
end)
