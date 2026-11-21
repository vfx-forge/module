--!native
--!nolint LocalShadow
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")

local attr = require("@mod/attributes")
local mods = require("@mod/mods")
local legacy_mods = require("@mod/legacy_mods")
local curves = require("@mod/curves")
local logger = require("@mod/logger")
local lifetime = require("@mod/lifetime")

local path = require("@mod/common/path")
local context_common = require("@mod/common/context")

local utility = {}

-- an Open Cloud luau execution task runs the runtime with no `script`
utility.PLUGIN_CONTEXT = context_common.pluginContext(
  script ~= nil and script:FindFirstAncestorOfClass("Plugin") ~= nil,
  RunService:IsStudio(),
  RunService:IsRunning()
)

utility.SERVER_CONTEXT = context_common.serverContext(RunService:IsServer(), utility.PLUGIN_CONTEXT)

utility.DEG_TO_RAD = math.pi / 180

utility.BEZIER_TAG = "BezierParticle"
utility.FORGE_MESH_TAG = "ForgeMesh"
utility.LIGHTNING_TAG = "LightningBolt"
utility.SHOCKWAVE_TAG = "Shockwave"
utility.SCREENSHAKE_TAG = "CameraShake"

utility.PROPERTY_TWEENER_TAG = "PropertyTweener"
utility.PROPERTY_ANIMATOR_TAG = "PropertyAnimator"

-- the folder an effect emits once it ends
utility.EMIT_ON_FINISH = "EmitOnFinish"
utility.PROPERTY_RANDOMIZER_TAG = "PropertyRandomizer"

utility.ATTRIBUTE_TWEENER_TAG = "AttributeTweener"
utility.ATTRIBUTE_RANDOMIZER_TAG = "AttributeRandomizer"

-- carried by anything holding at least one non-empty modifier queue, so the
-- applier reaches a target that is not otherwise an effect. the plugin adds it
-- on the first queue and removes it with the last, so it is derived state and
-- never authored by hand
utility.MODIFIERS_TAG = "ForgeModifiers"

utility.ENABLED_VFX_TAG = "ConstantVFX"
utility.TEXTURE_LOAD_TAG = "LoadVFXTextures"

utility.CLEANUP_TAG = "__forge__cleanupOnExit"
utility.EMIT_EXCLUDE_TAG = "__forge_excludeFromEmit"

utility.COLLISION_GROUPS = {
  StudioSelectable = {},

  ForgeDebris = {
    ForgeDebris = false,
  },

  ForgeMouseIgnore = {
    StudioSelectable = false,
  },
}

utility.COPY_SPECIALMESH_PROPERTIES = {
  "MeshId",
  "MeshType",
  "Offset",
  "Scale",
  "TextureId",
  "VertexColor",
}

function utility.setCollisionGroups(groups)
  local rules = {}

  for name, list in groups do
    PhysicsService:RegisterCollisionGroup(name)

    if not name:match("Studio") or RunService:IsStudio() then
      rules[name] = list
    end
  end

  for name, list in rules do
    for group, collidable in list do
      if group:match("Studio") and not RunService:IsStudio() then
        continue
      end

      PhysicsService:CollisionGroupSetCollidable(name, group, collidable)
    end
  end
end

-- the engine's Clone answers nil for an instance whose Archivable is false
function utility.clone<T>(inst: T & Instance): T
  if inst.Archivable then
    return inst:Clone()
  end

  inst.Archivable = true

  local ok, clone = pcall(inst.Clone, inst)

  inst.Archivable = false

  if not ok then
    error(clone, 0)
  end

  return clone
end

function utility.lerp(a: number, b: number, t: number)
  return a + (b - a) * t
end

function utility.try<R...>(msg: string, func: (...any) -> R..., ...: any): (boolean, R...)
  local res = { xpcall(func, function(err)
    logger.warn(string.format(msg, err))
  end, ...) }

  return res[1], table.unpack(res, 2)
end

function utility.reboundfn<A>(sec: number, func: (...A) -> never): (...A) -> never
  local lastRunThread

  return function(...)
    if lastRunThread then
      task.cancel(lastRunThread)
    end

    local args = { ... }

    lastRunThread = task.delay(sec, function()
      lastRunThread = nil
      func(table.unpack(args))
    end)
  end
end

function utility.randomUnitVector(min: Vector3, max: Vector3, rng: Random?)
  local rng = rng or Random.new()
  return Vector3.new(rng:NextNumber(min.X, max.X), rng:NextNumber(min.Y, max.Y), rng:NextNumber(min.Z, max.Z))
end

function utility.getImpulseForce(start: Vector3, goal: Vector3, duration: number)
  return (goal - start) / duration + Vector3.new(0, workspace.Gravity * duration * 0.5, 0)
end

-- the color a ray's hit shows: Terrain's own Color is not its materials', and water keeps its color apart
function utility.surfaceColor(result: RaycastResult): Color3
  local hit = result.Instance

  if not hit:IsA("Terrain") then
    return (hit :: BasePart).Color
  end

  local terrain = hit :: Terrain

  if result.Material == Enum.Material.Water then
    return terrain.WaterColor
  end

  return terrain:GetMaterialColor(result.Material)
end

function utility.getTarget(obj: Instance): Instance?
  local objectValue = obj:FindFirstChildOfClass("ObjectValue")

  if objectValue and objectValue.Value then
    return objectValue.Value
  end

  local parent = obj.Parent

  if not parent then
    return nil
  end

  while parent:IsA("Folder") do
    parent = parent.Parent

    if not parent then
      return nil
    end
  end

  return parent
end

-- what a legacy tween or randomizer RayValue drives, as the dispatcher plays
-- it: the instance it targets and the reading of it (`source`, `name`,
-- `random`). nil for a RayValue that drives nothing. an effect asking what
-- drives one of its rows answers through this, so the two never disagree
function utility.driverOf(child: Instance): (Instance?, any?)
  local read = legacy_mods.readChild(child)

  if read == nil then
    return nil, nil
  end

  return utility.getTarget(child), read
end

-- a window's tick runs on the window's clock, which already carries the
-- window's Speed; a passive loop's tick and a plain emit run at their own
function utility.speedFrom(scope: lifetime.effect, constant: boolean?, row: any)
  if constant and not scope.emit.constant then
    return
  end

  lifetime.speed(scope, row)
end

-- the module-level scopes (api.scope, texture preloads) are plain tables;
-- every emit and effect is a lifetime record now
function utility.cleanupScope(scope: { [any]: any }, syncFunctions: boolean?)
  for _, v in scope do
    local t = typeof(v)

    if t == "Instance" then
      v:Destroy()
    elseif t == "RBXScriptConnection" then
      v:Disconnect()
    elseif t == "thread" then
      if coroutine.status(v) ~= "dead" then
        task.cancel(v)
      end
    elseif t == "function" then
      if syncFunctions then
        v()
      else
        task.spawn(v)
      end
    elseif t == "table" then
      utility.cleanupScope(v)
    end
  end

  table.clear(scope)
end

-- keeps `parent` under `home` while the scope holds, unless `home` itself is gone
function utility.protectParent(scope: { [any]: any }, parent: Instance, home: Instance?)
  local where = home or workspace.Terrain

  table.insert(
    scope,
    parent.AncestryChanged:Connect(function()
      if parent.Parent == where or where.Parent == nil then
        return
      end

      parent.Parent = where
    end)
  )
end

function utility.findFirstClassWithTag(obj: Instance?, class: string, tag: string)
  if not obj or obj.Parent == game then
    return
  end

  if obj.ClassName == class and obj:HasTag(tag) then
    return obj
  else
    return utility.findFirstClassWithTag(obj.Parent, class, tag)
  end
end

function utility.cloneParticleAncestry(
  particle: ParticleEmitter,
  map: { [Instance?]: Instance },
  make: (obj: Instance) -> Instance
): (Instance?, Instance?)
  if not particle:FindFirstAncestorWhichIsA("BasePart") and not particle:FindFirstAncestorOfClass("Attachment") then
    return
  end

  local function findAncestor(obj: Instance?)
    if not obj then
      return
    end

    local ancestor = obj

    if obj.Parent and (obj.Parent:IsA("BasePart") or obj.Parent:IsA("Attachment")) then
      ancestor = findAncestor(obj.Parent)
    end

    return ancestor
  end

  local function recurse(obj: Instance?)
    if not obj then
      return
    end

    local created = map[obj]

    if created then
      return created, if obj == particle then map[obj.Parent] else map[findAncestor(obj.Parent)] or map[obj]
    end

    local clone = make(obj)
    local ancestor = clone

    if map then
      map[obj] = clone
    end

    if obj.Parent and (obj.Parent:IsA("BasePart") or obj.Parent:IsA("Attachment")) then
      local parent, pa = recurse(obj.Parent)

      if pa then
        ancestor = pa
      end

      if parent then
        clone.Parent = parent
      end
    end

    return clone, ancestor
  end

  return recurse(particle.Parent)
end

function utility.getTransformedOriginExtents(parent: Instance)
  local originCFrame, originSize = CFrame.identity, vector.zero

  if parent:IsA("BasePart") then
    originSize = parent.Size
    originCFrame = parent.CFrame
  elseif parent:IsA("Attachment") then
    originCFrame = parent.WorldCFrame

    local newParent = parent.Parent

    -- step 1: find the full origin cframe by walking up the tree, and processing the upmost attachment
    local positionScale = attr.get(parent, "PositionScale", vector.zero, true)

    if newParent then
      if newParent:IsA("BasePart") and positionScale ~= vector.zero then
        local offset = (newParent.Size / 2) * positionScale
        originCFrame = originCFrame + offset
      end
    end

    -- step 2: apply rotation on final origin cframe
    local overrideWorldRotation = attr.get(parent, "OverrideWorldRotation", false, true)
    local worldRotation = attr.get(parent, "WorldRotation", vector.zero, true)

    if overrideWorldRotation then
      local rotRad = worldRotation * utility.DEG_TO_RAD
      local position = originCFrame.Position

      originCFrame = CFrame.new(position) * CFrame.fromOrientation(rotRad.X, rotRad.Y, rotRad.Z)
    end
  end

  return originCFrame, originSize
end

function utility.getMeshDecals(ref: Model, start: BasePart)
  local legacy_isFlipbook = attr.get(ref, "Flipbook", false, true)

  local decals = {}
  local flipbooks = {}
  local fromToMap = {}

  local function filter(list: { Instance }): { Decal }
    local filtered = {}

    for _, v in list do
      if v:IsA("Decal") then
        table.insert(filtered, v)
      end
    end

    return filtered
  end

  if legacy_isFlipbook then
    decals = filter(start:GetChildren())
  else
    local originalEnd = ref:FindFirstChild("End")
    local originalStart = ref:FindFirstChild("Start")

    if originalEnd then
      for _, v in start:GetChildren() do
        if not v:IsA("Decal") then
          continue
        end

        local from = v

        local to = originalEnd:FindFirstChild(v.Name)

        if not to or not to:IsA("Decal") then
          continue
        end

        table.insert(decals, v)

        fromToMap[from] = to

        if not attr.get(v, "FlipbookEnabled", nil, true) then
          table.insert(decals, v)
        else
          local data = attr.get(v, "FlipbookTextures", nil, true)

          if data then
            flipbooks[v] = utility.deserializeFlipbook(data)
          end
        end
      end

      for _, v in originalStart:GetChildren() do
        if not v:IsA("Decal") then
          continue
        end

        -- convert children decals to flipbooks
        local children = v:GetChildren()

        do
          local offset = 0

          for i = 1, #children do
            i -= offset

            local obj = children[i]

            if not obj:IsA("Decal") then
              table.remove(children, i)
              offset += 1
            end
          end
        end

        if #children ~= 0 then
          local function idx(str: string)
            return tonumber(str:match("%d+")) or 0
          end

          table.sort(children, function(a, b)
            return idx(a.Name) < idx(b.Name)
          end)

          local ids = {}

          for _, obj in children do
            table.insert(ids, idx(obj.Texture))
            obj:Destroy()
          end

          local buf = utility.serializeFlipbook(ids)

          attr.set(v, "FlipbookEnabled", true)
          attr.set(v, "FlipbookTextures", buffer.tostring(buf))
        end
      end
    end
  end

  return decals, flipbooks, fromToMap
end

function utility.getBezierPoints(root: Attachment, metadata: boolean?)
  local objs = root:GetChildren()

  table.sort(objs, function(a, b)
    return tonumber(a.Name) < tonumber(b.Name)
  end)

  local points: { vector } = {}
  local attachments: { Attachment } = {}
  local attachmentToPointMap: { [Attachment]: vector } = {}

  local function vec(p: Attachment)
    local w = root.WorldCFrame:PointToObjectSpace(p.WorldPosition)
    local pos = vector.create(w.X, w.Y, w.Z)

    table.insert(points, pos)

    if metadata then
      attachmentToPointMap[p] = pos
      table.insert(attachments, p)
    end

    return pos
  end

  for i, p in objs do
    local t0 = p:FindFirstChild("T0")
    local t1 = p:FindFirstChild("T1")

    if i == 1 then
      vec(p)
    end

    -- left
    if i ~= 1 then
      if t1 then
        vec(t1)
      else
        vec(p)
      end
    end

    if i ~= 1 and i ~= #objs then
      vec(p)
    end

    -- right
    if i ~= #objs then
      if t0 then
        vec(t0)
      else
        vec(p)
      end
    end

    if i == #objs then
      vec(p)
    end
  end

  return points, attachments, attachmentToPointMap
end

function utility.scaleNumberSequence(
  seq: NumberSequence,
  scale: number | (value: number, envelope: number) -> (number, number)
)
  if scale == 1 then
    return seq
  end

  local scaled = {}

  for _, keypoint in seq.Keypoints do
    local value, envelope

    if typeof(scale) == "function" then
      value, envelope = scale(keypoint.Value, keypoint.Envelope)
    else
      value, envelope = keypoint.Value * scale, keypoint.Envelope * scale
    end

    table.insert(scaled, NumberSequenceKeypoint.new(keypoint.Time, value, envelope))
  end

  return NumberSequence.new(scaled)
end

-- Moved to `@mod/common/path` (a pure module, no `game`/`script` access, so it
-- can be required under lune as well as in Studio); delegate to keep this
-- public API unchanged.
utility.serializePath = path.serializePath
utility.deserializePath = path.deserializePath

local flipbook_common = require("@mod/common/flipbook")

utility.serializeFlipbook = flipbook_common.serialize
utility.deserializeFlipbook = flipbook_common.deserialize

-- out cubic. both live in @mod/curves so legacy_mods can reach the same bytes
-- without requiring this module, which would close a cycle through mods
utility.default_bezier = curves.default()
utility.linear_bezier = curves.linear()

function utility.scaleAttribute(obj: Instance, factor: number, name: string)
  local value = attr.get(obj, name, nil)

  if value ~= nil then
    if typeof(value) == "number" then
      attr.set(obj, name, value * factor)
    elseif typeof(value) == "Vector3" then
      attr.set(obj, name, value * factor)
    elseif typeof(value) == "NumberRange" then
      attr.set(obj, name, NumberRange.new(value.Min * factor, value.Max * factor))
    end
  end
end

-- the framed lanes on one knob, rewritten through the attribute cache so a
-- cached instance is edited where its attributes actually live
function utility.rescaleQueue(obj: Instance, source: string, name: string, edit: (lanes: { [string]: { any } }) -> ())
  local key = mods.attrName(source, name)
  local raw = attr.get(obj, key, nil, true)

  if raw == nil then
    return
  end

  local out = mods.recode(raw, edit)

  if out ~= nil then
    attr.set(obj, key, out)
  end
end

-- every framed row on an instance, for a rewrite that applies to all of them
-- alike
function utility.rescaleQueues(obj: Instance, edit: (lanes: { [string]: { any } }) -> ())
  for _, key in attr.keys(obj) do
    for source, prefix in mods.PREFIX do
      if string.sub(key, 1, #prefix) == prefix then
        utility.rescaleQueue(obj, source, string.sub(key, #prefix + 1), edit)
      end
    end
  end
end

function utility.scaleAttachmentDistance(a0: Attachment?, a1: Attachment?, factor: number)
  if not a0 or not a1 then
    return
  end

  local midpoint = (a0.Position + a1.Position) / 2

  a0.Position = midpoint + (a0.Position - midpoint) * factor
  a1.Position = midpoint + (a1.Position - midpoint) * factor
end

return utility
