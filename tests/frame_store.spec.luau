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
  }

  local ok, err = pcall(function()
    frame_store.init(scope)
    body(stand)
  end)

  utility.cleanupScope(scope)
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
        frame_store.setBudget(128)
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
        frame_store.setBudget(128)
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
        frame_store.setBudget(128)
      end)
    end)

    test("the budget defaults to 128 textures", function()
      expect(frame_store.getBudget()).toBe(128)
    end)
  end)
end)
