const harness = require("@tests/harness")
const effects = require("@srv/effects")
const utility = require("@mod/utility")
const registry = require("@mod/registry")
const scheduler = require("@mod/scheduler")
const fake_pool = require("@tests/fake_pool")
const test, expect = harness.test, harness.expect

const forge_mesh = require("@vfx/forge_mesh")

const CFrame = harness.datatypes.CFrame
const Vector3 = harness.datatypes.Vector3
const NumberRange = harness.datatypes.NumberRange

const EPSILON = 1e-4

-- the effect registered on the effects service and on a pool that clones
-- every take whole into its folder, put back once `body` ends
const function staged(body: (fake: fake_pool.Fake) -> ())
  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
  registry.register(forge_mesh)

  const fake = fake_pool.start({})
  const ok, err = pcall(body, fake)

  fake_pool.stop(fake)
  registry.clear()

  if not ok then
    error(err, 0)
  end
end

-- a tagged template part under `parent`, its rows set from `attributes`
const function template(parent: Instance, attributes: { [string]: any }): BasePart
  const part = harness.make("Part", parent) :: BasePart

  part.Name = "Template"
  part:AddTag(utility.FORGE_MESH_TAG)

  for name, value in attributes do
    part:SetAttribute(name, value)
  end

  return part
end

-- a part of `size` at `cframe` holding the template, in a folder of its own
const function parentPart(cframe: CFrame, size: Vector3): (Instance, BasePart)
  const root = harness.make("Folder")
  const part = harness.make("Part", root) :: BasePart

  part.CFrame = cframe
  part.Size = size

  return root, part
end

const function pieces(fake: fake_pool.Fake): { BasePart }
  return fake.folder:GetChildren() :: any
end

const function finite(cframe: CFrame)
  for _, x in { cframe:GetComponents() } do
    if x ~= x or math.abs(x) == math.huge then
      return false
    end
  end

  return true
end

const function tagged(roots: { Instance }): { Instance }
  const found = {}

  for _, root in roots do
    for _, inst in root:GetDescendants() do
      if inst:HasTag(utility.FORGE_MESH_TAG) then
        table.insert(found, inst)
      end
    end
  end

  return found
end

harness.suite(function()
  harness.describe("a mesh's pieces", function()
    test("an emit spawns EmitCount pieces inside the parent part", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))

        template(parent, { EmitCount = 5, Shape = "Box", ShapeStyle = "Volume" })

        const env = effects.emit(0, parent:FindFirstChild("Template"))

        scheduler.frame(1 / 60)

        const list = pieces(fake)

        expect(#list).toBe(5)

        for _, piece in list do
          const at = parent.CFrame:PointToObjectSpace(piece.CFrame.Position)

          expect(math.abs(at.X) <= 2 + EPSILON).toBe(true)
          expect(math.abs(at.Y) <= 1 + EPSILON).toBe(true)
          expect(math.abs(at.Z) <= 2 + EPSILON).toBe(true)
        end

        env:Clear()
      end)
    end)

    test("no piece carries the tag", function()
      staged(function(fake)
        const root, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { EmitCount = 3 })

        -- a template with children is cloned whole rather than taken from a stack
        harness.make("SpecialMesh", part)
        part:AddTag(utility.ENABLED_VFX_TAG)
        part:SetAttribute("Rate", 5)

        const env = effects.emit(0, part)

        scheduler.frame(1 / 60)

        const found = tagged({ root, fake.folder })

        expect(#pieces(fake)).toBe(3)
        expect(#found).toBe(1)
        expect(found[1]).toBe(part)

        for _, piece in pieces(fake) do
          expect(#piece:GetTags()).toBe(0)
          expect(next(piece:GetAttributes())).toBe(nil)
        end

        env:Clear()
      end)
    end)

    test("an attachment parent spawns at the attachment", function()
      staged(function(fake)
        const _, part = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const attachment = harness.make("Attachment", part) :: Attachment

        -- lune works out no world frame for an attachment, so it is written
        attachment.WorldCFrame = CFrame.new(1, 12, 3)

        template(attachment, { EmitCount = 4, SpreadAngle = Vector3.new(30, 30, 0) })

        const env = effects.emit(0, attachment:FindFirstChild("Template"))

        scheduler.frame(1 / 60)

        const list = pieces(fake)

        expect(#list).toBe(4)

        for _, piece in list do
          expect((piece.CFrame.Position - Vector3.new(1, 12, 3)).Magnitude < EPSILON).toBe(true)
        end

        env:Clear()
      end)
    end)

    test("a template with no part or attachment above it spawns at its own pose", function()
      staged(function(fake)
        const root = harness.make("Folder")
        const part = template(root, { EmitCount = 2, Shape = "Sphere" })

        part.CFrame = CFrame.new(5, 6, 7)

        const env = effects.emit(0, part)

        scheduler.frame(1 / 60)

        const list = pieces(fake)

        expect(#list).toBe(2)

        for _, piece in list do
          expect((piece.CFrame.Position - Vector3.new(5, 6, 7)).Magnitude < EPSILON).toBe(true)
        end

        env:Clear()
      end)
    end)

    test("pieces are released when their life ends", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { EmitCount = 3, Duration = NumberRange.new(0.5, 0.5) })

        effects.emit(0, part)

        scheduler.frame(0.25)
        expect(#pieces(fake)).toBe(3)

        scheduler.frame(0.3)
        scheduler.frame(1 / 60)
        expect(#pieces(fake)).toBe(0)
      end)
    end)

    test("a piece takes its transparency from the row, not the template", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { EmitCount = 3 })

        part.Transparency = 1

        const env = effects.emit(0, part)

        scheduler.frame(1 / 60)

        const list = pieces(fake)

        expect(#list).toBe(3)

        for _, piece in list do
          expect(piece.Transparency).toBe(0)
        end

        env:Clear()
      end)
    end)

    test("a piece's size is the template's times the Scale row", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.new(4, 2, 4))
        const part = template(parent, { Scale = Vector3.new(2, 3, 4) })

        part.Size = Vector3.new(2, 2, 2)

        const env = effects.emit(0, part)
        const list = pieces(fake)

        expect(#list).toBe(1)
        expect(list[1].Size).toBe(Vector3.new(4, 6, 8))

        env:Clear()
      end)
    end)

    test("degenerate rows do not produce NaN", function()
      staged(function(fake)
        const _, parent = parentPart(CFrame.new(0, 10, 0), Vector3.zero)
        const part = template(parent, {
          EmitCount = 4,
          -- a piece of no duration is up only for its destroy delay
          Duration = NumberRange.new(0, 0),
          DestroyDelay = 0.1,
          ShapeStyle = "Surface",
          SpreadAngle = Vector3.new(180, 180, 0),
        })

        effects.emit(0, part)

        const list = pieces(fake)

        expect(#list).toBe(4)

        for _, piece in list do
          expect(finite(piece.CFrame)).toBe(true)
          expect(piece.Size == piece.Size).toBe(true)
        end

        scheduler.frame(1 / 60)

        for _, piece in list do
          expect(finite(piece.CFrame)).toBe(true)
          expect(piece.Size == piece.Size).toBe(true)
        end

        scheduler.frame(0.1)
        scheduler.frame(1 / 60)
        expect(#pieces(fake)).toBe(0)
      end)
    end)
  end)
end)
