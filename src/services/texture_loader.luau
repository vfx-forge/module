local CollectionService = game:GetService("CollectionService")

local utility = require("@mod/utility")
local flipbook_common = require("@mod/common/flipbook")

local texture_loader = {}

function texture_loader.init(scope: { any })
  local parent = Instance.new("Part")
  parent.Name = "DO_NOT_REMOVE_ForgeTextureCache"
  parent.Transparency = 1
  parent.Size = Vector3.zero
  parent.Archivable = false
  parent.Anchored = true
  parent.CanCollide = false
  parent.CanQuery = false
  parent.Locked = true
  parent.Parent = workspace.Terrain

  utility.protectParent(scope, parent)

  local decals: { [string]: { decal: Decal, count: number } } = {}
  local preloadScopes = {}

  local function acquire(texture: string)
    local entry = decals[texture]

    if entry == nil then
      local decal = Instance.new("Decal")
      decal.Texture = texture
      decal.Parent = parent

      entry = { decal = decal, count = 0 }
      decals[texture] = entry
    end

    entry.count += 1
  end

  local function release(texture: string)
    local entry = decals[texture]

    if entry == nil then
      return
    end

    entry.count -= 1

    if entry.count <= 0 then
      entry.decal:Destroy()
      decals[texture] = nil
    end
  end

  local function createLoader(
    ref: Instance,
    collectTextures: (add: (tex: string) -> ()) -> (),
    conns: ((run: () -> ()) -> { RBXScriptConnection })?
  )
    local loadScope = {} :: { any }
    local snapshotScope = {} :: { any }

    table.insert(loadScope, snapshotScope)

    local function refresh()
      utility.cleanupScope(snapshotScope)

      local function add(tex: string)
        if tex == "" then
          return
        end

        acquire(tex)

        table.insert(snapshotScope, function()
          release(tex)
        end)
      end

      collectTextures(add)
    end

    refresh()

    if utility.PLUGIN_CONTEXT and conns then
      local run = utility.reboundfn(1, refresh)

      for _, connection in conns(run) do
        table.insert(loadScope, connection)
      end
    end

    preloadScopes[ref] = loadScope
  end

  local function loadTextures(ref: Instance)
    if ref:IsDescendantOf(workspace.Terrain) then
      return
    end

    local obj = ref:FindFirstChild("Start")

    if
      ref:IsA("Model")
      and obj
      and obj:IsA("BasePart")
      and ref:FindFirstChild("End")
      and (ref :: any).End:IsA("BasePart")
    then
      createLoader(ref, function(add)
        local decals, flipbooks = utility.getMeshDecals(ref :: Model, obj)

        for _, d in decals do
          add(typeof(d) ~= "string" and d.Texture or d)
        end

        for v, list in flipbooks do
          local prefix = flipbook_common.getTexturePrefix(ref)

          for _, id in list do
            add(`{prefix}{id}`)
          end
        end
      end, function(run)
        return {
          obj.DescendantAdded:Connect(run),
          obj.DescendantRemoving:Connect(run),
        }
      end)
    elseif ref:IsA("Beam") then
      createLoader(ref, function(add)
        add(ref.Texture)

        local flipbook = flipbook_common.getFlipbookData(ref)

        if flipbook then
          local prefix = flipbook_common.getTexturePrefix(ref)

          for _, id in flipbook do
            add(`{prefix}{id}`)
          end
        end
      end, function(run)
        return {
          ref:GetPropertyChangedSignal("Texture"):Connect(run),
          ref.AttributeChanged:Connect(run),
        }
      end)
    else
      createLoader(ref, function(add)
        local function check(obj: Instance)
          if obj:IsA("ParticleEmitter") then
            add(obj.Texture)
          end
        end

        check(ref)

        for _, obj in ref:GetDescendants() do
          check(obj)
        end
      end, function(run)
        return {
          ref.DescendantAdded:Connect(run),
          ref.DescendantRemoving:Connect(run),
        }
      end)
    end
  end

  for _, ref in CollectionService:GetTagged(utility.TEXTURE_LOAD_TAG) do
    loadTextures(ref)
  end

  table.insert(scope, CollectionService:GetInstanceAddedSignal(utility.TEXTURE_LOAD_TAG):Connect(loadTextures))
  table.insert(
    scope,
    CollectionService:GetInstanceRemovedSignal(utility.TEXTURE_LOAD_TAG):Connect(function(ref)
      local loadScope = preloadScopes[ref]

      if loadScope then
        utility.cleanupScope(loadScope)
        preloadScopes[ref] = nil
      end
    end)
  )

  table.insert(scope, function()
    for _, entry in decals do
      entry.decal:Destroy()
    end

    table.clear(decals)

    for _, loadScope in preloadScopes do
      utility.cleanupScope(loadScope)
    end

    table.clear(preloadScopes)
    parent:Destroy()
  end)
end

return texture_loader
