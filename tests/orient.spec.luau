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

  harness.describe("orient_common.landing", function()
    const NORMAL = vector.normalize(vector.create(0.3, 1, -0.4))
    const UP = Vector3.new(NORMAL.x, NORMAL.y, NORMAL.z)

    test("lists the sides in the SurfaceAlign row's order", function()
      expect(table.concat(orient_common.SIDES, ",")).toBe("None,Top,Front,Back")
    end)

    test("None keeps the turn", function()
      const cf = orient_common.landing(BASE, "None", NORMAL)

      expect(near(cf.LookVector, BASE.LookVector) and near(cf.UpVector, BASE.UpVector)).toBe(true)
    end)

    test("each side lands its axis on its way out of the surface", function()
      expect(near(orient_common.landing(BASE, "Top", NORMAL).UpVector, UP)).toBe(true)
      expect(near(orient_common.landing(BASE, "Front", NORMAL).LookVector, UP)).toBe(true)
      expect(near(orient_common.landing(BASE, "Back", NORMAL).LookVector, -UP)).toBe(true)
    end)

    test("turns about an axis square to the normal, so its heading about it holds", function()
      for _, side in { "Top", "Front", "Back" } do
        const cf = orient_common.landing(BASE, side :: any, NORMAL)
        const delta = cf * BASE:Inverse()
        const axis, angle = delta:ToAxisAngle()

        expect(angle < 1e-4 or math.abs(axis.Unit:Dot(UP)) < EPSILON).toBe(true)
      end
    end)

    test("a piece already flat keeps its yaw", function()
      const flat = CFrame.fromOrientation(0, 1.2, 0)
      const cf = orient_common.landing(flat, "Top", vector.create(0, 1, 0))

      expect(near(cf.LookVector, flat.LookVector) and near(cf.UpVector, flat.UpVector)).toBe(true)
    end)

    test("a side facing straight into the surface turns over finitely", function()
      const cases = {
        { side = "Top", turn = CFrame.fromOrientation(math.pi, 0.5, 0), want = "UpVector", sign = 1 },
        { side = "Front", turn = CFrame.fromOrientation(-math.pi / 2, 0, 0), want = "LookVector", sign = 1 },
        { side = "Back", turn = CFrame.fromOrientation(math.pi / 2, 0, 0), want = "LookVector", sign = -1 },
      }

      for _, case in cases do
        const cf = orient_common.landing(case.turn, case.side :: any, vector.create(0, 1, 0))
        const got = (cf :: any)[case.want] :: Vector3

        expect(got.X == got.X and got.Y == got.Y and got.Z == got.Z).toBe(true)
        expect(near(got, Vector3.new(0, case.sign, 0))).toBe(true)
        expect(math.abs(cf.RightVector:Dot(cf.UpVector)) < EPSILON).toBe(true)
      end
    end)
  end)

  harness.describe("orient_common.settling", function()
    const FROM = CFrame.fromOrientation(0.2, 0.4, 0)
    const TO = CFrame.fromOrientation(1.3, -0.2, 0.6)

    const function ease(t: number)
      return t * t
    end

    test("no duration snaps to the landed turn", function()
      const cf = orient_common.settling(FROM, TO, 0, 0, ease)

      expect(near(cf.LookVector, TO.LookVector) and near(cf.UpVector, TO.UpVector)).toBe(true)
    end)

    test("starts at the hit turn and ends on the landed one", function()
      const first = orient_common.settling(FROM, TO, 0, 0.5, ease)
      const last = orient_common.settling(FROM, TO, 0.7, 0.5, ease)

      expect(near(first.LookVector, FROM.LookVector) and near(first.UpVector, FROM.UpVector)).toBe(true)
      expect(near(last.LookVector, TO.LookVector) and near(last.UpVector, TO.UpVector)).toBe(true)
    end)

    test("eases between them on the curve", function()
      const cf = orient_common.settling(FROM, TO, 0.25, 0.5, ease)
      const want = FROM:Lerp(TO, 0.25)

      expect(near(cf.LookVector, want.LookVector) and near(cf.UpVector, want.UpVector)).toBe(true)
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

  harness.describe("orient_common.toward", function()
    const EYE = Vector3.new(0, 0, 10)

    test("draws a pose that many studs toward the camera, keeping its turn", function()
      const cf = CFrame.new(0, 0, -2) * CFrame.fromOrientation(0.4, 1.1, -0.3)
      const drawn, k = orient_common.toward(cf, EYE, 1.5)

      expect(near(drawn.Position, Vector3.new(0, 0, -0.5))).toBe(true)
      expect(near(drawn.LookVector, cf.LookVector) and near(drawn.UpVector, cf.UpVector)).toBe(true)
      expect(math.abs(k - 10.5 / 12) < EPSILON).toBe(true)
    end)

    test("below 0 draws it away from the camera, and larger", function()
      const drawn, k = orient_common.toward(CFrame.new(3, 4, 10), EYE, -5)

      expect(near(drawn.Position, Vector3.new(6, 8, 10))).toBe(true)
      expect(math.abs(k - 2) < EPSILON).toBe(true)
    end)

    test("moves along the line to the camera wherever the camera stands", function()
      const cf = CFrame.new(1, 2, 3)
      const eye = Vector3.new(4, -2, 15)
      const drawn = orient_common.toward(cf, eye, 2)

      expect(math.abs((drawn.Position - cf.Position).Magnitude - 2) < EPSILON).toBe(true)
      expect(near((drawn.Position - cf.Position).Unit, (eye - cf.Position).Unit)).toBe(true)
    end)

    test("every point of a piece scaled by the share lands on the same line of sight", function()
      const cf = CFrame.new(2, 1, -4) * CFrame.fromOrientation(0.3, -0.8, 0.2)
      const drawn, k = orient_common.toward(cf, EYE, 6)
      const corner = Vector3.new(1.5, -0.7, 0.4)
      const before = cf:PointToWorldSpace(corner)
      const after = drawn:PointToWorldSpace(corner * k)

      expect(near((after - EYE).Unit, (before - EYE).Unit)).toBe(true)
    end)

    test("stops short of the camera however far it is asked to draw", function()
      const drawn, k = orient_common.toward(CFrame.new(0, 0, 0), EYE, 50)

      expect(k > 0).toBe(true)
      expect(drawn.Position.Z < 10).toBe(true)
    end)

    test("leaves a pose at the camera where it is", function()
      const cf = CFrame.new(0, 0, 10)
      const drawn, k = orient_common.toward(cf, EYE, 3)

      expect(drawn).toBe(cf)
      expect(k).toBe(1)
    end)
  end)
end)
