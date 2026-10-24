local harness = require("@tests/harness")
local utility = require("@mod/utility")
local texture_loader = require("@srv/texture_loader")

local test, expect = harness.test, harness.expect

local TEXTURE = "rbxassetid://5"

type Stand = {
  scope: { any },
  terrain: Instance,
  removed: (ref: Instance) -> (),
  disconnected: number,
}

-- the loader started on `tagged`, with the tag service's signals, the terrain
-- its part sits under and the decals' constructor stood in, then put back once
-- `body` ends
local function loader(tagged: { Instance }, body: (stand: Stand) -> ())
  local tags = game:GetService("CollectionService") :: any
  local getTagged, addedSignal, removedSignal =
    tags.GetTagged, tags.GetInstanceAddedSignal, tags.GetInstanceRemovedSignal
  local protect, terrain = utility.protectParent, workspace.Terrain
  local constructor = Instance

  local stand = { scope = {}, terrain = harness.make("Folder"), disconnected = 0 } :: any

  local function signal(store: string?)
    return {
      Connect = function(_, fn: (ref: Instance) -> ())
        if store ~= nil then
          stand[store] = fn
        end

        return {
          Disconnect = function()
            stand.disconnected += 1
          end,
        }
      end,
    }
  end

  tags.GetTagged = function()
    return tagged
  end

  tags.GetInstanceAddedSignal = function()
    return signal(nil)
  end

  tags.GetInstanceRemovedSignal = function()
    return signal("removed")
  end

  utility.protectParent = function() end
  workspace.Terrain = stand.terrain :: any

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = harness.datatypes.Instance

  local ok, err = pcall(function()
    texture_loader.init(stand.scope)
    body(stand)
  end)

  tags.GetTagged, tags.GetInstanceAddedSignal, tags.GetInstanceRemovedSignal = getTagged, addedSignal, removedSignal
  utility.protectParent, workspace.Terrain = protect, terrain

  -- selene: allow(unscoped_variables, incorrect_standard_library_use)
  Instance = constructor

  if not ok then
    error(err, 0)
  end
end

local function beam(): Instance
  local made = harness.make("Beam", harness.make("Folder")) :: any
  made.Texture = TEXTURE

  return made
end

local function decals(stand: Stand): { string }
  local home = stand.terrain:FindFirstChild("VFXForge")
  local part = if home ~= nil then home:FindFirstChild("TextureCache") else nil
  local found = {}

  if part == nil then
    return found
  end

  for _, child in part:GetChildren() do
    table.insert(found, (child :: any).Texture)
  end

  return found
end

harness.suite(function()
  harness.describe("the texture preloader", function()
    test("a texture two tagged refs share stays loaded until the last lets go", function()
      local a, b = beam(), beam()

      loader({ a, b }, function(stand: Stand)
        expect(decals(stand)).toEqual({ TEXTURE })

        stand.removed(a)

        expect(decals(stand)).toEqual({ TEXTURE })

        stand.removed(b)

        expect(decals(stand)).toEqual({})
        utility.cleanupScope(stand.scope)
      end)
    end)

    test("its scope lets go of every decal, its part and both tag listeners", function()
      loader({ beam() }, function(stand: Stand)
        expect(decals(stand)).toEqual({ TEXTURE })

        utility.cleanupScope(stand.scope)

        local home = stand.terrain:FindFirstChild("VFXForge")

        expect(home ~= nil and #home:GetChildren() or -1).toBe(0)
        expect(stand.disconnected).toBe(2)
      end)
    end)
  end)
end)
