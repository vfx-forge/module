--!nolint LocalShadow
local CollectionService = game:GetService("CollectionService")

local knob = require("@mod/knob")
local shape = require("@mod/shape")
local utility = require("@mod/utility")

local Bezier = require("@obj/Bezier")

local common = {}

-- the shape a piece is emitted from, by the Shape row
common.SHAPES = table.freeze({
  Box = shape.box,
  Disc = shape.disc,
  Sphere = shape.sphere,
  Cylinder = shape.cylinder,
})

export type HitboxConfig = {
  enabled: boolean,
  collisionGroup: string,
  filterTag: string,
  filterType: string,
  ignoreCanCollide: boolean,
}

function common.createHitboxParams(config: HitboxConfig, parent: Instance, root: Attachment?): OverlapParams
  local params = OverlapParams.new()
  params.MaxParts = 1
  params.FilterType = Enum.RaycastFilterType[config.filterType]
  params.CollisionGroup = config.collisionGroup
  params.RespectCanCollide = not config.ignoreCanCollide

  params:AddToFilter(CollectionService:GetTagged(config.filterTag))

  if config.filterType == "Exclude" then
    local ancestorPart = root and root:FindFirstAncestorOfClass("Part")
    params:AddToFilter({ workspace.Terrain, parent, ancestorPart })
  end

  return params
end

export type EmissionConfig = {
  face: "InAndOut" | "Inward" | "Outward",
  spreadAngle: Vector3,
  mirror: boolean,
  mirrorRot: Vector3,
  partial: number,
  surface: boolean,
  emissionDirection: Enum.NormalId,
}

function common.calculateEmissionCFrame(
  originCFrame: CFrame,
  originSize: Vector3,
  config: EmissionConfig,
  drawFunc: ((CFrame, Vector3, shape.Options?) -> CFrame)?,
  rng: Random,
  endPoint: Attachment?,
  isAttachment: boolean
)
  local cf: CFrame

  if isAttachment then
    cf = originCFrame * CFrame.new(Vector3.zero, Vector3.FromNormalId(config.emissionDirection)).Rotation
  elseif drawFunc then
    cf = drawFunc(originCFrame, originSize, {
      surface = config.surface,
      partial = config.partial,
      normal = config.emissionDirection,
    })
  else
    cf = originCFrame
  end

  local normal = Vector3.FromNormalId(config.emissionDirection)
  local pitchAxis = normal:Cross(originCFrame.LookVector)

  if pitchAxis.Magnitude < 0.001 then
    pitchAxis = normal:Cross(originCFrame.UpVector)
  end

  local spread = CFrame.fromAxisAngle(normal, math.rad(rng:NextNumber(-config.spreadAngle.X, config.spreadAngle.X)))
    * CFrame.fromAxisAngle(pitchAxis, math.rad(rng:NextNumber(-config.spreadAngle.Y, config.spreadAngle.Y)))

  cf *= spread

  if config.face == "Inward" or (config.face == "InAndOut" and rng:NextInteger(0, 1) == 1) then
    cf *= CFrame.fromOrientation(0, math.pi, 0)
  end

  if endPoint and config.mirror and (cf.Position - endPoint.WorldPosition).Unit:Dot(cf.RightVector) >= 0 then
    local rot = config.mirrorRot * utility.DEG_TO_RAD
    cf *= CFrame.fromOrientation(rot.X, rot.Y, rot.Z)
  end

  return cf
end

-- the chain a piece flies with an end attachment, built in one table every
-- piece shares, since a Bezier keeps a copy of its own
local chain: { vector } = {}

-- a piece's path: the authored chain moved to the piece's emission frame, its
-- last anchor and that anchor's incoming handle on the end attachment
function common.endpointPath(points: { vector }, cf: CFrame, endPoint: Attachment?, endT1: Attachment?): Bezier.Bezier
  if not endPoint then
    return Bezier.new(points)
  end

  local count = #points

  table.clear(chain)

  for j, pt in points do
    chain[j] = if j == count - 1
      then (endT1 or endPoint).WorldPosition
      else if j == count then endPoint.WorldPosition else cf * (pt - points[1])
  end

  return Bezier.new(chain)
end

function common.createPosGetter(
  bezier: Bezier.Bezier,
  points: { vector },
  cf: CFrame,
  endPoint: Attachment?,
  useArcSpace: boolean?
): (number) -> Vector3
  return function(alpha: number): Vector3
    local p = if useArcSpace ~= false then bezier:atUniform(alpha) else bezier:at(alpha)

    if endPoint then
      return p
    else
      return cf * (p - points[1])
    end
  end
end

local function always()
  return true
end

-- the rows a bezier and a lightning bolt share plus the module's own, a fresh
-- table per module so the registry freezes each module's own
function common.rows(own: { [string]: any })
  local rows = {
    EmitCount = knob(1):min(0):label("Count"):hint("The amount of effects to emit."),
    EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
    EmitDuration = knob(0):min(0):unit("seconds"):label("Duration"):hint("Duration of the emit cycle in seconds."),
    DestroyDelay = knob(0)
      :min(0)
      :unit("seconds")
      :label("DestroyDelay")
      :hint("Extra seconds to keep the effect alive after emission finishes."),
    Duration = knob(NumberRange.new(1, 1))
      :min(0)
      :unit("seconds")
      :label("Duration")
      :hint("Duration range of the effect in seconds."),
    Enabled = knob(false):label("Enabled"):hint("Whether the effect continuously emits."),
    Rate = knob(5):min(0):unit("perSecond"):label("Rate"):hint("Effects emitted per second when Enabled is true."),
    SyncPosition = knob(false):label("SyncPosition"):hint("Whether the effect follows the emitter's position."),
    Shape = knob("Box")
      :options({ "Box", "Cylinder", "Disc", "Sphere" })
      :label("Shape")
      :hint("Volume shape emission points are sampled from."),
    ShapeStyle = knob("Volume")
      :options({ "Surface", "Volume" })
      :label("Style")
      :hint("Whether points sample the shape's surface or its volume."),
    EmissionDirection = knob("Top")
      :options({ "Back", "Bottom", "Front", "Left", "Right", "Top" })
      :label("Direction")
      :hint("Face of the emitter the paths launch from."),
    ShapeFace = knob("Outward")
      :options({ "InAndOut", "Inward", "Outward" })
      :label("Face")
      :hint("Direction the emission CFrame faces relative to the shape."),
    SpreadAngle = knob(vector.zero):label("SpreadAngle"):hint("Random rotation spread applied to emitted effects."),
    ShapePartial = knob(1):label("Partial"):hint("Fraction of the shape used when sampling points."),
    MirrorPaths = knob(true):label("Mirror"):hint("Whether to mirror bezier paths."),
    MirrorRotation = knob(vector.create(0, 0, 180)):label("MirrorRotation"):hint("Rotation applied to mirrored paths."),
    ProjectileEnabled = knob(false)
      :label("Enabled")
      :hint("Whether paths continue as projectiles after reaching the end."),
    MatchEndDirection = knob(false)
      :label("MatchEndDirection")
      :hint("Whether the projectile follows the end attachment's facing."),
    ProjectileSpeed = knob(30)
      :unit("studsPerSecond")
      :label("Speed")
      :hint("Projectile travel speed in studs per second."),
    ProjectileLifetime = knob(NumberRange.new(1, 1))
      :min(0)
      :unit("seconds")
      :label("Lifetime")
      :hint("How long the projectile phase lasts in seconds."),
    HitboxEnabled = knob(false):label("Enabled"):hint("Whether the path detects collisions along its travel."),
    HitboxCollisionGroup = knob("Default")
      :label("CollisionGroup")
      :hint("Collision group used for hitbox overlap queries."),
    HitboxFilterTag = knob(""):label("Tag"):hint("CollectionService tag used to filter hitbox overlaps."),
    HitboxFilterType = knob("Exclude")
      :options({ "Include", "Exclude" })
      :label("Type")
      :hint("Whether the tag filter includes or excludes tagged parts."),
    HitboxIgnoreCanCollide = knob(false)
      :label("IgnoreCanCollide")
      :hint("Whether the hitbox ignores non-collidable parts."),
    Speed = knob(1):mod():label("Speed"):hint("Multiplier on the effect's clock."),
    SpeedDuration = knob(0.1):min(0):aliases("Speed_Duration"):unit("seconds"):hidden(always),
  }

  for name, row in own do
    rows[name] = row
  end

  return rows
end

-- the shared groups with the module's own: `middle` sits between the shared
-- end point and the projectile phase, `tail` after the hitbox
function common.layout(middle: { any }, tail: { any })
  local head = {
    { title = "Emit", entries = { "EmitCount", "EmitDelay", "EmitDuration", "DestroyDelay" } },
    { title = "Effect", entries = { "Duration", "SpreadAngle", "Enabled", "Rate", "SyncPosition", "Speed" } },
    { title = "Shape", entries = { "EmissionDirection", "Shape", "ShapePartial", "ShapeStyle", "ShapeFace" } },
    { title = "Shared End Point", entries = { "MirrorPaths", "MirrorRotation" } },
  }
  local rest = {
    {
      title = "Projectile Motion",
      entries = { "ProjectileEnabled", "ProjectileLifetime", "ProjectileSpeed", "MatchEndDirection" },
    },
    {
      title = "Hitbox",
      entries = {
        "HitboxEnabled",
        "HitboxCollisionGroup",
        { title = "Filter", entries = { "HitboxFilterTag", "HitboxFilterType", "HitboxIgnoreCanCollide" } },
      },
    },
  }

  table.move(middle, 1, #middle, #head + 1, head)
  table.move(rest, 1, #rest, #head + 1, head)
  table.move(tail, 1, #tail, #head + 1, head)

  return head
end

-- the hitbox parameters as the two modules' rows spell them
function common.hitboxOf(attrs: any): HitboxConfig
  return {
    enabled = attrs.HitboxEnabled,
    collisionGroup = attrs.HitboxCollisionGroup,
    filterTag = attrs.HitboxFilterTag,
    filterType = attrs.HitboxFilterType,
    ignoreCanCollide = attrs.HitboxIgnoreCanCollide,
  }
end

-- the emission parameters as the two modules' rows spell them
function common.emissionOf(attrs: any)
  return {
    face = attrs.ShapeFace,
    spreadAngle = attrs.SpreadAngle,
    mirror = attrs.MirrorPaths,
    mirrorRot = attrs.MirrorRotation,
    partial = attrs.ShapePartial,
    surface = attrs.ShapeStyle == "Surface",
    emissionDirection = Enum.NormalId[attrs.EmissionDirection],
  }
end

function common.getCurrentOriginCFrame(parent: Instance, fallback: CFrame)
  if parent:IsA("BasePart") then
    return parent.CFrame
  elseif parent:IsA("Attachment") then
    return parent.WorldCFrame
  end

  return fallback
end

function common.findEndAttachments(ref: Attachment): (Attachment?, Attachment?)
  local endPoint = ref:FindFirstChild("End")
  local endT1 = endPoint and endPoint:FindFirstChild("T1")

  if endPoint and not endPoint:IsA("Attachment") then
    endPoint = nil
  end

  if endT1 and not endT1:IsA("Attachment") then
    endT1 = nil
  end

  return endPoint, endT1
end

function common.validateParent(ref: Attachment): Instance?
  local parent = ref.Parent

  if not parent then
    return nil
  end

  if not parent:IsA("BasePart") and not parent:IsA("Attachment") then
    parent = ref
  end

  return parent
end

function common.getPerpendicularVectors(tangent: Vector3)
  local right = tangent:Cross(Vector3.yAxis)

  if right.Magnitude < 0.001 then
    right = tangent:Cross(Vector3.zAxis)
  end

  right = right.Unit

  local up = tangent:Cross(right).Unit

  return right, up
end

return common
