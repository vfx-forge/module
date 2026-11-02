const harness = require("@tests/harness")

const orient_common = require("@mod/common/orient")

const test, expect = harness.test, harness.expect
const CFrame = harness.datatypes.CFrame
const Vector3 = harness.datatypes.Vector3

const EPSILON = 1e-4

const BASE = CFrame.fromOrientation(0.4, 1.1, -0.3)
const POSITION = vector.create(2, 1, -3)
const VELOCITY = vector.create(3, -1, 2)
const CAMERA = CFrame.new(10, 4, 6) * CFrame.fromOrientation(-0.2, 0.7, 0.3)

const function near(a: Vector3, b: Vector3)
  return (a - b).Magnitude < EPSILON
end

const function unit(v: Vector3)
  return v.Unit
end

harness.suite(function()
  harness.describe("orient_common.rotation", function()
    test("lists the modes in the Orientation row's order", function()
      expect(table.concat(orient_common.MODES, ",")).toBe(
        "None,FacingCamera,FacingCameraWorldUp,VelocityParallel,VelocityPerpendicular"
      )
    end)

    test("None keeps the base turn", function()
      const cf = orient_common.rotation("None", BASE, POSITION, VELOCITY, CAMERA)

      expect(near(cf.LookVector, BASE.LookVector) and near(cf.UpVector, BASE.UpVector)).toBe(true)
    end)

    test("VelocityPerpendicular looks along the velocity", function()
      const cf = orient_common.rotation("VelocityPerpendicular", BASE, POSITION, VELOCITY, CAMERA)

      expect(near(cf.LookVector, unit(Vector3.new(3, -1, 2)))).toBe(true)
      expect(near(cf.UpVector, cf.UpVector.Unit)).toBe(true)
    end)

    test("VelocityPerpendicular keeps a turn straight down valid", function()
      const cf = orient_common.rotation("VelocityPerpendicular", BASE, POSITION, vector.create(0, -5, 0), CAMERA)

      expect(near(cf.LookVector, Vector3.new(0, -1, 0))).toBe(true)
      expect(math.abs(cf.LookVector:Dot(cf.UpVector)) < EPSILON).toBe(true)
      expect(math.abs(cf.UpVector.Magnitude - 1) < EPSILON).toBe(true)
    end)

    test("VelocityParallel puts the up vector along the velocity", function()
      const cf = orient_common.rotation("VelocityParallel", BASE, POSITION, VELOCITY, CAMERA)

      expect(near(cf.UpVector, unit(Vector3.new(3, -1, 2)))).toBe(true)
      expect(math.abs(cf.RightVector:Dot(cf.UpVector)) < EPSILON).toBe(true)
    end)

    test("FacingCamera looks at the camera with the camera's up", function()
      const cf = orient_common.rotation("FacingCamera", BASE, POSITION, VELOCITY, CAMERA)
      const toward = unit(CAMERA.Position - Vector3.new(2, 1, -3))

      expect(near(cf.LookVector, toward)).toBe(true)

      const want = unit(CAMERA.UpVector - toward * CAMERA.UpVector:Dot(toward))

      expect(near(cf.UpVector, want)).toBe(true)
    end)

    test("FacingCameraWorldUp looks at the camera level, up world Y", function()
      const cf = orient_common.rotation("FacingCameraWorldUp", BASE, POSITION, VELOCITY, CAMERA)
      const flat = CAMERA.Position - Vector3.new(2, 1, -3)

      expect(near(cf.LookVector, unit(Vector3.new(flat.X, 0, flat.Z)))).toBe(true)
      expect(near(cf.UpVector, Vector3.new(0, 1, 0))).toBe(true)
    end)

    test("a nil camera acts as None", function()
      for _, mode in { "FacingCamera", "FacingCameraWorldUp" } do
        const cf = orient_common.rotation(mode, BASE, POSITION, VELOCITY, nil)

        expect(near(cf.LookVector, BASE.LookVector) and near(cf.UpVector, BASE.UpVector)).toBe(true)
      end
    end)

    test("a still piece keeps its base", function()
      for _, mode in { "VelocityParallel", "VelocityPerpendicular" } do
        const cf = orient_common.rotation(mode, BASE, POSITION, vector.zero, CAMERA)

        expect(near(cf.LookVector, BASE.LookVector) and near(cf.UpVector, BASE.UpVector)).toBe(true)
      end
    end)
  end)

  harness.describe("orient_common.squash", function()
    test("keeps the area of the side it stretches", function()
      for _, s in { -2, -0.5, 0, 0.25, 1.5 } do
        const size = orient_common.squash(Vector3.new(2, 3, 5), s)

        -- a Vector3 holds float32, so the product is good to a part in 1e-6
        expect(math.abs(size.X * size.Y / 6 - 1) < 1e-6).toBe(true)
        expect(math.abs(size.Z * size.Y / 15 - 1) < 1e-6).toBe(true)
      end
    end)

    test("1 doubles the height and halves the rest, -1 the other way", function()
      const tall = orient_common.squash(Vector3.new(2, 3, 5), 1)
      const wide = orient_common.squash(Vector3.new(2, 3, 5), -1)

      expect(math.abs(tall.Y - 6) < 1e-6 and math.abs(tall.X - 1) < 1e-6).toBe(true)
      expect(math.abs(wide.Y - 1.5) < 1e-6 and math.abs(wide.Z - 10) < 1e-6).toBe(true)
    end)

    test("the height grows linearly past 0, as an emitter's does", function()
      expect(math.abs(orient_common.squash(Vector3.one, 2).Y - 3) < 1e-6).toBe(true)
      expect(math.abs(orient_common.squash(Vector3.one, -2).X - 3) < 1e-6).toBe(true)
    end)
  end)
end)
