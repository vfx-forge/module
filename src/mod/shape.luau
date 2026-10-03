--!native
--!optimize 2
export type Options = {
  surface: boolean?,
  partial: number?,
  normal: Enum.NormalId?,
  seed: number?,
}

-- by name, since an enum item is not the same value twice under every host
local NORMALS: { [string]: Vector3 } = {
  Top = Vector3.yAxis,
  Bottom = -Vector3.yAxis,
  Right = Vector3.xAxis,
  Left = -Vector3.xAxis,
  Back = Vector3.zAxis,
  Front = -Vector3.zAxis,
}

local NONE: Options = table.freeze({})

local shape = {}

-- the one generator every unseeded point is drawn from
local rng = Random.new()

local function randomOf(options: Options): Random
  local seed = options.seed

  if seed == nil then
    return rng
  end

  return Random.new(seed)
end

-- the normal's name, the top when none is given
local function nameOf(options: Options): string
  local normal = options.normal

  return if normal ~= nil then normal.Name else "Top"
end

local function surfaceOf(cframe: CFrame, n: Vector3, pos: Vector3)
  local up = if math.abs(n:Dot(Vector3.yAxis)) > 0.99 then Vector3.zAxis else Vector3.yAxis

  return cframe * CFrame.new(pos) * CFrame.lookAt(Vector3.zero, n, up)
end

-- a point in a box, or on the face its normal points out of, facing the normal
function shape.box(cframe: CFrame, size: Vector3, options: Options?): CFrame
  local opts = options or NONE
  local random = randomOf(opts)
  local n = NORMALS[nameOf(opts)]
  local half = size / 2

  -- stylua: ignore
  local pos = Vector3.new(
    random:NextNumber(-1, 1),
    random:NextNumber(-1, 1),
    random:NextNumber(-1, 1)
  ) * half

  if not opts.surface then
    return surfaceOf(cframe, n, pos)
  end

  return surfaceOf(cframe, n, pos * (Vector3.one - n:Abs()) + n * half)
end

-- a point in a cylinder whose axis runs along the normal, or on its curved
-- side; `partial` narrows the end the normal points out of
function shape.cylinder(cframe: CFrame, size: Vector3, options: Options?): CFrame
  local opts = options or NONE
  local random = randomOf(opts)
  local normal = nameOf(opts)
  local partial = opts.partial or 1

  local r = math.sqrt(random:NextNumber(if opts.surface then 1 else 0, 1))
  local theta = random:NextNumber(0, 2 * math.pi)

  if normal == "Left" or normal == "Right" then
    cframe *= CFrame.fromOrientation(0, math.pi / 2 * (if normal == "Right" then -1 else 1), 0)
    size = Vector3.new(size.Z, size.Y, size.X)
  elseif normal == "Front" or normal == "Back" then
    cframe *= CFrame.fromOrientation(0, math.pi, 0)
  end

  local z = random:NextNumber()
  local t = 1 - z ^ (0.5 + 0.5 * math.sqrt(partial))
  local width = 1 + (partial - 1) * t

  -- stylua: ignore
  local pos = Vector3.new(
    t * 2 - 1,
    r * math.sin(theta) * width,
    r * math.cos(theta) * width
  ) * size / 2

  -- stylua: ignore
  local outward = Vector3.new(
    0,
    math.sin(theta) * width,
    math.cos(theta) * width
  ) * size / 2

  local tangent = Vector3.new(0, math.cos(theta) * width, -math.sin(theta) * width) * size / 2
  local up = if tangent.Magnitude > 0.001 then tangent.Unit else cframe.UpVector

  return cframe * CFrame.new(pos) * CFrame.lookAt(Vector3.zero, outward, up)
end

-- a point in a sphere, or on it, facing out of it; `partial` keeps it to the
-- cap around the normal, a whole sphere at 1
function shape.sphere(cframe: CFrame, size: Vector3, options: Options?): CFrame
  local opts = options or NONE
  local random = randomOf(opts)
  local normal = nameOf(opts)
  local partial = opts.partial or 1

  local u = random:NextNumber()
  local v = random:NextNumber()

  local theta = u * 2 * math.pi
  local phi = math.acos(2 * v - 1) * partial
  local r = random:NextNumber(if opts.surface then 1 else 0, 1) ^ (1 / 3)

  local sinTheta = math.sin(theta)
  local cosTheta = math.cos(theta)
  local sinPhi = math.sin(phi)
  local cosPhi = math.cos(phi)

  if normal == "Left" or normal == "Right" then
    size = Vector3.new(size.Z, size.Y, size.X)
  elseif normal == "Top" or normal == "Bottom" then
    size = Vector3.new(size.X, size.Z, size.Y)
  end

  local half = size / 2
  local cf = surfaceOf(cframe, NORMALS[normal], Vector3.zero)

  -- stylua: ignore
  local pos = Vector3.new(
    r * sinPhi * cosTheta,
    r * sinPhi * sinTheta,
    r * cosPhi
  ) * half

  local tangent = Vector3.new(-sinPhi * sinTheta, sinPhi * cosTheta, 0) * half
  local up = if tangent.Magnitude > 0.001 then tangent.Unit else Vector3.xAxis

  return cf * CFrame.Angles(0, math.pi, 0) * CFrame.new(pos) * CFrame.lookAt(Vector3.zero, pos, up)
end

-- a point in a disc lying across the normal, or on the face the normal points
-- out of; `partial` is the ring's width, a whole disc at 1
function shape.disc(cframe: CFrame, size: Vector3, options: Options?): CFrame
  local opts = options or NONE
  local random = randomOf(opts)
  local normal = nameOf(opts)
  local partial = opts.partial or 1
  local depth = if opts.surface then 1 else 0

  local n = NORMALS[normal]
  local axes = Vector3.one - n:Abs() * depth
  local half = size / 2

  local t = random:NextNumber(depth, 1)
  local d = 1 - 0.5 * partial ^ 4

  local r = random:NextNumber(1 - partial, 1) ^ d
  local theta = random:NextNumber(0, 2 * math.pi)

  -- stylua: ignore
  local s = Vector3.new(
    t * 2 - 1,
    r * math.sin(theta),
    r * math.cos(theta)
  )

  if normal == "Bottom" or normal == "Top" then
    s = Vector3.new(s.Z, s.X, s.Y)
  elseif normal == "Front" or normal == "Back" then
    s = Vector3.new(s.Y, s.Z, s.X)
  end

  return surfaceOf(cframe, n, s * half * axes + n * depth * half)
end

return shape
