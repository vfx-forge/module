local shape = require("@mod/shape")
local roblox = require("@lune/roblox") :: any
local harness = require("@tests/harness")

local test, expect = harness.test, harness.expect
local CFrame = harness.datatypes.CFrame
local Vector3 = harness.datatypes.Vector3
local NormalId = roblox.Enum.NormalId

local DRAWS = 500
local EPSILON = 1e-4

local ORIGIN = CFrame.new(3, -2, 7) * CFrame.fromOrientation(0.4, 1.1, -0.3)
local SIZE = Vector3.new(4, 6, 10)
local HALF = SIZE / 2

-- every point `make` gives with these options, each as its point in the origin's
-- own space and its frame
local function points(make: (...any) -> any, size: any, options: any): { { any } }
  local list = {}

  for _ = 1, DRAWS do
    local cf = make(ORIGIN, size, options)

    table.insert(list, { ORIGIN:PointToObjectSpace(cf.Position), cf })
  end

  return list
end

-- where a frame built on the normal `n` looks. lune's CFrame.lookAt faces
-- away from its target where Studio's faces it, so facing is checked against
-- the host's own
local function facing(n: any): any
  local up = if math.abs(n.Y) > 0.99 then Vector3.zAxis else Vector3.yAxis

  return (ORIGIN * CFrame.lookAt(Vector3.zero, n, up)).LookVector
end

local function near(a: number, b: number): boolean
  return math.abs(a - b) < EPSILON
end

harness.suite(function()
  harness.describe("shape.box", function()
    test("a volume point is inside the box and faces the normal", function()
      for _, entry in points(shape.box, SIZE, nil) do
        local p = entry[1]

        expect(math.abs(p.X) <= HALF.X + EPSILON and math.abs(p.Y) <= HALF.Y + EPSILON).toBe(true)
        expect(math.abs(p.Z) <= HALF.Z + EPSILON).toBe(true)
        expect((entry[2].LookVector - facing(Vector3.yAxis)).Magnitude < EPSILON).toBe(true)
      end
    end)

    test("a surface point is on the face the normal points out of", function()
      for _, entry in points(shape.box, SIZE, { surface = true, normal = NormalId.Right }) do
        local p = entry[1]

        expect(near(p.X, HALF.X)).toBe(true)
        expect(math.abs(p.Y) <= HALF.Y + EPSILON and math.abs(p.Z) <= HALF.Z + EPSILON).toBe(true)
        expect((entry[2].LookVector - facing(Vector3.xAxis)).Magnitude < EPSILON).toBe(true)
      end
    end)
  end)

  harness.describe("shape.cylinder", function()
    -- the axis runs along x for the top normal; a point's distance from it,
    -- as a share of the radius, and the radius `partial` leaves at its x
    local function radial(p: any): (number, number)
      local along = (p.X / HALF.X + 1) / 2

      return math.sqrt((p.Y / HALF.Y) ^ 2 + (p.Z / HALF.Z) ^ 2), along
    end

    test("a volume point is inside, and a surface point on the curved side", function()
      for _, entry in points(shape.cylinder, SIZE, nil) do
        local r = radial(entry[1])

        expect(r <= 1 + EPSILON and math.abs(entry[1].X) <= HALF.X + EPSILON).toBe(true)
      end

      for _, entry in points(shape.cylinder, SIZE, { surface = true }) do
        expect(near(radial(entry[1]), 1)).toBe(true)
      end
    end)

    test("partial narrows the cylinder toward its far end", function()
      for _, entry in points(shape.cylinder, SIZE, { surface = true, partial = 0.25 }) do
        local r, along = radial(entry[1])

        expect(near(r, 1 + (0.25 - 1) * along)).toBe(true)
      end
    end)
  end)

  harness.describe("shape.sphere", function()
    local CUBE = Vector3.new(8, 8, 8)

    test("a volume point is inside the sphere, and a surface point on it", function()
      for _, entry in points(shape.sphere, CUBE, nil) do
        expect(entry[1].Magnitude <= 4 + EPSILON).toBe(true)
      end

      for _, entry in points(shape.sphere, CUBE, { surface = true }) do
        expect(near(entry[1].Magnitude, 4)).toBe(true)
      end
    end)

    test("partial keeps a point to the cap around the normal", function()
      local axis = ORIGIN:VectorToObjectSpace(facing(-Vector3.zAxis))

      for _, entry in points(shape.sphere, CUBE, { surface = true, partial = 0.25, normal = NormalId.Front }) do
        local p = entry[1]
        local angle = math.acos(math.clamp(p.Unit:Dot(axis), -1, 1))

        expect(angle <= math.pi * 0.25 + EPSILON).toBe(true)
      end
    end)
  end)

  harness.describe("shape.disc", function()
    test("a volume point is inside the disc, and a surface point on its face", function()
      for _, entry in points(shape.disc, SIZE, nil) do
        local p = entry[1]

        expect(math.sqrt((p.X / HALF.X) ^ 2 + (p.Z / HALF.Z) ^ 2) <= 1 + EPSILON).toBe(true)
        expect(math.abs(p.Y) <= HALF.Y + EPSILON).toBe(true)
      end

      for _, entry in points(shape.disc, SIZE, { surface = true }) do
        expect(near(entry[1].Y, HALF.Y)).toBe(true)
      end
    end)

    test("partial keeps a point to the ring at the disc's rim", function()
      local inner = (1 - 0.3) ^ (1 - 0.5 * 0.3 ^ 4)

      for _, entry in points(shape.disc, SIZE, { surface = true, partial = 0.3 }) do
        local p = entry[1]
        local r = math.sqrt((p.X / HALF.X) ^ 2 + (p.Z / HALF.Z) ^ 2)

        expect(r >= inner - EPSILON and r <= 1 + EPSILON).toBe(true)
      end
    end)
  end)

  harness.describe("shape seeds", function()
    test("a seed draws the same point every time, and none draws a new one", function()
      for _, name in { "box", "disc", "sphere", "cylinder" } do
        local make = (shape :: any)[name]
        local first = make(ORIGIN, SIZE, { seed = 12 })
        local again = make(ORIGIN, SIZE, { seed = 12 })
        local other = make(ORIGIN, SIZE, { seed = 13 })

        expect(first).toBe(again)
        expect(first == other).toBe(false)
        expect(make(ORIGIN, SIZE) == make(ORIGIN, SIZE)).toBe(false)
      end
    end)
  end)
end)
