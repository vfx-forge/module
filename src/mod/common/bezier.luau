--!nolint LocalShadow
local CollectionService = game:GetService("CollectionService")

local knob = require("@mod/knob")
local shape = require("@mod/shape")
local tween = require("@mod/tween")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")

local Oklab = require("@mod/color/Oklab")
local Bezier = require("@obj/Bezier")

local common = {}

common.drawFuncMap = {
  Box = {
    Volume = shape.getPointWithinBox,
    Surface = shape.getPointOnBox,
  },

  Cylinder = {
    Volume = function(seed, cframe, size, normal, partial)
      return shape.getPointWithinCylinder(seed, 0, partial, cframe, size, normal)
    end,

    Surface = function(seed, cframe, size, normal, partial)
      return shape.getPointWithinCylinder(seed, 1, partial, cframe, size, normal)
    end,
  },

  Sphere = {
    Volume = function(seed, cframe, size, normal, partial)
      return shape.getPointWithinSphere(seed, 0, partial, cframe, size, normal)
    end,

    Surface = function(seed, cframe, size, normal, partial)
      return shape.getPointWithinSphere(seed, 1, partial, cframe, size, normal)
    end,
  },

  Disc = {
    Volume = function(seed, cframe, size, normal, partial)
      return shape.getPointWithinDisc(seed, 0, partial, cframe, size, normal)
    end,

    Surface = function(seed, cframe, size, normal, partial)
      return shape.getPointWithinDisc(seed, 1, partial, cframe, size, normal)
    end,
  },
}

function common.getColorAtTime(sequence: ColorSequence, time: number)
  local keypoints = sequence.Keypoints

  if time <= keypoints[1].Time then
    return keypoints[1].Value
  end

  if time >= keypoints[#keypoints].Time then
    return keypoints[#keypoints].Value
  end

  local closestBelow
  local closestAbove

  for i = 1, #keypoints do
    local kp = keypoints[i]
    if kp.Time == time then
      return kp.Value
    elseif kp.Time < time then
      closestBelow = kp
    elseif kp.Time > time then
      closestAbove = kp
      break
    end
  end

  if not closestBelow or not closestAbove then
    return keypoints[1].Value
  end

  local alpha = (time - closestBelow.Time) / (closestAbove.Time - closestBelow.Time)
  return closestBelow.Value:Lerp(closestAbove.Value, alpha)
end

function common.getColorAtTimeOklab(sequence: ColorSequence, time: number)
  local keypoints = sequence.Keypoints

  if time <= keypoints[1].Time then
    return keypoints[1].Value
  end

  if time >= keypoints[#keypoints].Time then
    return keypoints[#keypoints].Value
  end

  local closestBelow
  local closestAbove

  for i = 1, #keypoints do
    local kp = keypoints[i]
    if kp.Time == time then
      return kp.Value
    elseif kp.Time < time then
      closestBelow = kp
    elseif kp.Time > time then
      closestAbove = kp
      break
    end
  end

  if not closestBelow or not closestAbove then
    return keypoints[1].Value
  end

  local alpha = (time - closestBelow.Time) / (closestAbove.Time - closestBelow.Time)

  local labA = Oklab.fromSRGB(closestBelow.Value)
  local labB = Oklab.fromSRGB(closestAbove.Value)

  local blendedLab = labA:Lerp(labB, alpha)

  return Oklab.toSRGB(blendedLab)
end

function common.getColorWithEasingOklab(sequence: ColorSequence, time: number, easingBezier)
  local easedTime = 1 - easingBezier:getEase(math.clamp(time, 0, 1)).y
  return common.getColorAtTimeOklab(sequence, math.clamp(easedTime, 0, 1))
end

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
  emissionDirection: Enum.NormalId,
}

function common.calculateEmissionCFrame(
  originCFrame: CFrame,
  originSize: Vector3,
  config: EmissionConfig,
  drawFunc: ((...any) -> CFrame)?,
  rng: Random,
  endPoint: Attachment?,
  isAttachment: boolean
)
  local cf: CFrame

  if isAttachment then
    cf = originCFrame * CFrame.new(Vector3.zero, Vector3.FromNormalId(config.emissionDirection)).Rotation
  elseif drawFunc then
    cf = drawFunc(nil, originCFrame, originSize, config.emissionDirection, config.partial)
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

function common.createBezierWithEndpoint(points: { vector }, cf: CFrame, endPoint: Attachment?, endT1: Attachment?)
  if not endPoint then
    return Bezier.new(points)
  end

  local pts = {}

  for j, pt in points do
    table.insert(
      pts,
      if j == (#points - 1)
        then endT1 and endT1.WorldPosition or endPoint.WorldPosition
        else if j == #points then endPoint.WorldPosition else cf * (pt - points[1])
    )
  end

  return Bezier.new(pts)
end

function common.createPosGetter(
  bezier,
  points: { vector },
  cf: CFrame,
  endPoint: Attachment?,
  useArcSpace: boolean?
): (number) -> Vector3
  return function(alpha: number): Vector3
    local p = if useArcSpace ~= false then bezier:getPositionArcSpace(alpha) else bezier:getPosition(alpha)

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

-- the rows a bezier and a lightning bolt share, a fresh table per module so
-- the registry freezes each module's own
function common.rows()
  return {
    EmitCount = knob(1):min(0),
    EmitDelay = knob(0):min(0):unit("seconds"),
    EmitDuration = knob(0):min(0):unit("seconds"),
    DestroyDelay = knob(0):min(0):unit("seconds"),
    Duration = knob(NumberRange.new(1, 1)):min(0):unit("seconds"),
    Enabled = knob(false),
    Rate = knob(5):min(0):unit("perSecond"),
    SyncPosition = knob(false),
    Shape = knob("Box"):options({ "Box", "Cylinder", "Sphere", "Disc" }),
    ShapeStyle = knob("Volume"):options({ "Volume", "Surface" }),
    EmissionDirection = knob("Top"):options({ "Top", "Bottom", "Left", "Right", "Front", "Back" }),
    ShapeFace = knob("Outward"):options({ "InAndOut", "Inward", "Outward" }),
    SpreadAngle = knob(vector.zero),
    ShapePartial = knob(1),
    MirrorPaths = knob(true),
    MirrorRotation = knob(vector.create(0, 0, 180)),
    ProjectileEnabled = knob(false),
    MatchEndDirection = knob(false),
    ProjectileSpeed = knob(30):unit("studsPerSecond"),
    ProjectileLifetime = knob(NumberRange.new(1, 1)):min(0):unit("seconds"),
    HitboxEnabled = knob(false),
    HitboxCollisionGroup = knob("Default"),
    HitboxFilterTag = knob(""),
    HitboxFilterType = knob("Exclude"):options({ "Include", "Exclude" }),
    HitboxIgnoreCanCollide = knob(false),
    Speed = knob(1):mod(),
    SpeedDuration = knob(0.1):min(0):aliases("Speed_Duration"):unit("seconds"):hidden(always),
  }
end

function common.layout()
  return {
    { title = "Emit", entries = { "EmitCount", "EmitDelay", "EmitDuration", "DestroyDelay" } },
    { title = "Effect", entries = { "Duration", "SpreadAngle", "Enabled", "Rate", "SyncPosition", "Speed" } },
    { title = "Shape", entries = { "EmissionDirection", "Shape", "ShapePartial", "ShapeStyle", "ShapeFace" } },
    { title = "Shared End Point", entries = { "MirrorPaths", "MirrorRotation" } },
    {
      title = "Projectile Motion",
      entries = { "ProjectileEnabled", "ProjectileLifetime", "ProjectileSpeed", "MatchEndDirection" },
    },
    {
      title = "Hitbox",
      entries = {
        "HitboxEnabled",
        "HitboxCollisionGroup",
        "HitboxFilterTag",
        "HitboxFilterType",
        "HitboxIgnoreCanCollide",
      },
    },
  }
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

-- one knob of a projectile driven from its track: the setter sees the first
-- value at once and every later one on a stepper scaled by the projectile's
-- speed. a constant track costs no stepper
function common.drivePropertyTrack(
  scope: lifetime.effect,
  track: any,
  setter: (number) -> (),
  getSpeed: () -> number,
  speedTween: any?
)
  setter(track.at(0))

  if not track.animated then
    return
  end

  lifetime.hold(
    scope,
    tween.fromParams(utility.linear_bezier, track.duration, function(_, deltaTime, elapsed)
      setter(track.at(elapsed))
      return deltaTime * getSpeed()
    end, speedTween)
  )
end

return common
