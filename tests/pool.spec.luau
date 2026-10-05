local harness = require("@tests/harness")
local pool = require("@srv/pool")
local mover = require("@srv/mover")
local lifetime = require("@mod/lifetime")
local fake_pool = require("@tests/fake_pool")

local test, expect = harness.test, harness.expect
local Color3 = harness.datatypes.Color3
local Vector3 = harness.datatypes.Vector3

local LISTS = {
  Part = { "Color", "Size", "Transparency", "Material", "Anchored", "CanCollide", "Locked" },
  MeshPart = { "Color", "Size", "Transparency", "Anchored", "Locked" },
  Beam = { "Enabled", "Width0", "Attachment0" },
  ParticleEmitter = { "Enabled", "Rate", "LightEmission" },
  Attachment = { "Visible" },
  Folder = {},
  Sound = { "Volume" },
}

local function start(): fake_pool.Fake
  return fake_pool.start(LISTS)
end

local stop = fake_pool.stop

local function source(class: string): Instance
  local inst = harness.make(class)
  inst.Name = `Authored{class}`

  return inst
end

harness.suite(function()
  harness.describe("the pool's single instances", function()
    test("a take matches its source and is held by the holder", function()
      local fake = start()
      local part = source("Part") :: Part
      part.Color = Color3.new(1, 0, 0)
      part.Size = Vector3.new(2, 3, 4)
      part.Transparency = 0.25

      local holder = {}
      local taken = pool.take(holder, part) :: Part

      expect(taken ~= part).toBe(true)
      expect(taken.Color).toBe(part.Color)
      expect(taken.Size).toBe(part.Size)
      expect(taken.Transparency).toBe(0.25)
      expect(taken.Name).toBe("AuthoredPart")
      expect(taken.Anchored).toBe(true)
      expect(taken.Locked).toBe(true)
      expect(taken.Parent).toBe(fake.folder)
      expect(#holder).toBe(1)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a released instance is hidden, inert and handed out again", function()
      local fake = start()
      local part = source("Part")
      local holder = {}
      local first = pool.take(holder, part) :: Part

      first.CanCollide = true
      first.Anchored = false
      lifetime.releasePlain(holder)

      expect(first.Transparency).toBe(1)
      expect(first.Anchored).toBe(true)
      expect(first.CanCollide).toBe(false)

      local again = {}
      local second = pool.take(again, part)

      expect(second).toBe(first)
      expect(fake.made).toBe(1)

      lifetime.releasePlain(again)
      stop(fake)
    end)

    test("releasing twice files the instance once", function()
      local fake = start()
      local part = source("Part")
      local holder = {}
      local taken = pool.take(holder, part)
      local release = holder[1]

      release()
      release()

      local a, b = {}, {}

      expect(pool.take(a, part)).toBe(taken)
      expect(pool.take(b, part) ~= taken).toBe(true)

      lifetime.releasePlain(a)
      lifetime.releasePlain(b)
      stop(fake)
    end)

    test("an instance destroyed by someone else is forgotten", function()
      local fake = start()
      local part = source("Part")
      local holder = {}
      local taken = pool.take(holder, part)

      fake.destroyed[taken]()
      taken:Destroy()
      lifetime.releasePlain(holder)

      local again = {}

      expect(pool.take(again, part) ~= taken).toBe(true)

      lifetime.releasePlain(again)
      stop(fake)
    end)

    test("a release after a destroy whose signal has not fired yet does nothing", function()
      local fake = start()
      local part = source("Part")
      local holder = {}
      local taken = pool.take(holder, part)

      taken:Destroy()

      expect((pcall(lifetime.releasePlain, holder))).toBe(true)

      local again = {}

      expect(pool.take(again, part) ~= taken).toBe(true)

      lifetime.releasePlain(again)
      stop(fake)
    end)

    test("a beam from the stack takes every listed property of its new source", function()
      local fake = start()
      local one = source("Beam") :: Beam
      local two = source("Beam") :: Beam
      local anchor = harness.make("Attachment")

      one.Width0 = 3
      two.Width0 = 7
      two.Attachment0 = anchor

      local holder = {}
      local taken = pool.take(holder, one) :: Beam

      taken.Enabled = false
      lifetime.releasePlain(holder)

      local again = {}
      local reused = pool.take(again, two) :: Beam

      expect(reused).toBe(taken)
      expect(reused.Width0).toBe(7)
      expect(reused.Enabled).toBe(true)
      expect(reused.Attachment0).toBe(anchor)

      lifetime.releasePlain(again)
      stop(fake)
    end)

    test("a part from the stack never takes its new source's velocity", function()
      local lists = table.clone(LISTS)
      lists.Part = { "Color", "Velocity" }

      local fake = fake_pool.start(lists)
      local still = source("Part")
      local moving = source("Part") :: Part
      local holder = {}
      local taken = pool.take(holder, still) :: Part

      moving.Velocity = Vector3.new(0, 30, 0)
      lifetime.releasePlain(holder)

      local again = {}
      local reused = pool.take(again, moving) :: Part

      expect(reused).toBe(taken)
      expect(reused.Velocity).toBe(Vector3.zero)

      lifetime.releasePlain(again)
      stop(fake)
    end)

    test("a new part starts at rest whatever its source's velocity", function()
      local fake = start()
      local moving = source("Part") :: Part
      local holder = {}

      moving.AssemblyLinearVelocity = Vector3.new(0, 30, 0)
      moving.AssemblyAngularVelocity = Vector3.new(1, 0, 0)

      local taken = pool.take(holder, moving) :: Part

      expect(fake.made).toBe(1)
      expect(taken.AssemblyLinearVelocity).toBe(Vector3.zero)
      expect(taken.AssemblyAngularVelocity).toBe(Vector3.zero)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("an attachment from the stack takes its new source's offset, a part never its CFrame", function()
      local lists = table.clone(LISTS)
      lists.Attachment = { "Visible", "CFrame" }
      lists.Part = { "Color", "CFrame" }

      local fake = fake_pool.start(lists)
      local CFrame = harness.datatypes.CFrame
      local first = source("Attachment") :: Attachment
      local second = source("Attachment") :: Attachment
      local still = source("Part") :: Part
      local moved = source("Part") :: Part

      first.CFrame = CFrame.new(0, 0, 5)
      second.CFrame = CFrame.new(0, 3, 0)
      moved.CFrame = CFrame.new(10, 0, 0)

      local holder = {}
      local attachment = pool.take(holder, first) :: Attachment
      local part = pool.take(holder, still) :: Part

      lifetime.releasePlain(holder)

      local again = {}

      expect(pool.take(again, second)).toBe(attachment)
      expect(pool.take(again, moved)).toBe(part)
      expect(attachment.CFrame).toEqual(CFrame.new(0, 3, 0))
      expect(part.CFrame).toEqual(CFrame.identity)

      lifetime.releasePlain(again)
      stop(fake)
    end)

    test("a free sound never plays on removal, and its next take does if authored to", function()
      local lists = table.clone(LISTS)
      lists.Sound = { "Volume", "PlayOnRemove" }

      local fake = fake_pool.start(lists)
      local sound = source("Sound") :: Sound
      local holder = {}

      sound.PlayOnRemove = true

      local taken = pool.take(holder, sound) :: Sound

      expect(taken.PlayOnRemove).toBe(true)

      lifetime.releasePlain(holder)

      expect(taken.PlayOnRemove).toBe(false)

      local again = {}

      expect(pool.take(again, sound)).toBe(taken)
      expect(taken.PlayOnRemove).toBe(true)

      lifetime.releasePlain(again)
      stop(fake)
    end)

    test("a released emitter is cleared and switched off", function()
      local fake = start()
      local emitter = source("ParticleEmitter")
      local holder = {}
      local taken = pool.take(holder, emitter) :: ParticleEmitter

      lifetime.releasePlain(holder)

      expect(taken.Enabled).toBe(false)
      expect(table.find(fake.settled, taken) ~= nil).toBe(true)

      stop(fake)
    end)

    test("a single carries no tags or attributes into its next use", function()
      local fake = start()
      local attachment = source("Attachment")
      attachment:SetAttribute("Authored", 1)
      attachment:AddTag("AuthoredTag")

      local holder = {}
      local taken = pool.take(holder, attachment)

      expect(taken:GetAttribute("Authored")).toBe(nil)
      expect(#taken:GetTags()).toBe(0)

      taken:AddTag("Exclude")
      lifetime.releasePlain(holder)

      expect(#taken:GetTags()).toBe(0)

      stop(fake)
    end)

    test("a MeshPart comes back only for its own mesh", function()
      local fake = start()
      local sword = source("MeshPart") :: MeshPart
      local axe = source("MeshPart") :: MeshPart

      -- lune has no default for a MeshId, so the sources set one
      sword.MeshId = "rbxassetid://1"
      axe.MeshId = "rbxassetid://2"

      local holder = {}
      local first = pool.take(holder, sword)

      lifetime.releasePlain(holder)

      local other = pool.take(holder, axe)

      expect(other ~= first).toBe(true)
      expect(fake.made).toBe(2)

      lifetime.releasePlain(holder)

      expect(pool.take(holder, sword)).toBe(first)
      expect(fake.made).toBe(2)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a MeshPart whose mesh no key can name is copied fresh every take", function()
      local fake = start()
      local shaped = source("MeshPart") :: MeshPart
      local holder = {}

      shaped.MeshId = ""

      local first = pool.take(holder, shaped)

      lifetime.releasePlain(holder)

      local second = pool.take(holder, shaped)

      expect(second ~= first).toBe(true)
      expect(fake.made).toBe(0)
      expect(pool.stats().fresh).toBe(2)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a mesh's stack keeps nothing past its recent peak", function()
      local fake = start()
      local sword = source("MeshPart") :: MeshPart
      local holder = {}

      sword.MeshId = "rbxassetid://1"
      pool.take(holder, sword)
      lifetime.releasePlain(holder)

      pool.sweep(1e9)

      expect(#fake.folder:GetChildren()).toBe(1)

      pool.sweep(2e9)

      expect(#fake.folder:GetChildren()).toBe(0)

      pool.take(holder, sword)

      expect(fake.made).toBe(2)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("children a single gained are destroyed, a pooled child goes back to the folder", function()
      local fake = start()
      local part = source("Part")
      local emitter = source("ParticleEmitter")
      local outer, inner = {}, {}
      local taken = pool.take(outer, part)
      local child = pool.take(inner, emitter)
      local stray = harness.make("Folder")

      child.Parent = taken
      stray.Parent = taken
      lifetime.releasePlain(outer)

      expect(child.Parent).toBe(fake.folder)
      expect(stray.Parent).toBe(nil)

      lifetime.releasePlain(inner)
      stop(fake)
    end)

    test("a class off the restorable list is cloned fresh and held", function()
      local fake = start()
      local script = harness.make("Script")
      local holder = {}
      local taken = pool.take(holder, script)

      expect(taken ~= script).toBe(true)
      expect(taken.ClassName).toBe("Script")
      expect(pool.stats().fresh).toBe(1)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a take before init is a fresh clone", function()
      local holder = {}
      local part = source("Part")
      local taken = pool.take(holder, part)

      expect(taken ~= part).toBe(true)

      lifetime.releasePlain(holder)
    end)

    test("a pooled part is assigned to its holder for the mover", function()
      local fake = start()
      local part = source("Part")
      local holder, other = {}, {}
      local taken = pool.take(holder, part) :: Part
      local sent = 0
      local bulk = mover.bulk

      mover.bulk = function()
        sent += 1
      end

      mover.move(other, taken, harness.datatypes.CFrame.new(1, 0, 0))
      mover.flush()
      expect(sent).toBe(0)

      mover.move(holder, taken, harness.datatypes.CFrame.new(1, 0, 0))
      mover.flush()
      expect(sent).toBe(1)

      mover.bulk = bulk
      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("free instances above the floor and the recent peak are destroyed", function()
      local fake = start()
      local part = source("Part")
      local holders = {}

      for i = 1, 80 do
        holders[i] = {}
        pool.take(holders[i], part)
      end

      for i = 1, 80 do
        lifetime.releasePlain(holders[i])
      end

      expect(#fake.folder:GetChildren()).toBe(80)

      -- two turns of the peak buckets: the first moves 80 to the previous
      -- bucket, the second lets it go
      pool.sweep(1e9)
      pool.sweep(2e9)

      expect(#fake.folder:GetChildren()).toBe(64)

      stop(fake)
    end)

    test("the pool says whether it is started", function()
      expect(pool.started()).toBe(false)

      local fake = start()

      expect(pool.started()).toBe(true)

      stop(fake)

      expect(pool.started()).toBe(false)
    end)

    test("a release after a stop destroys the instance where it stands", function()
      local fake = start()
      local part = source("Part")
      local scene = harness.make("Model")
      local holder = {}
      local taken = pool.take(holder, part)

      taken.Parent = scene
      stop(fake)
      lifetime.releasePlain(holder)

      expect(taken.Parent).toBe(nil)
      expect((pcall(function()
        taken.Parent = scene
      end))).toBe(false)
    end)

    test("init after a stop starts empty", function()
      local fake = start()
      local part = source("Part")
      local holder = {}

      pool.take(holder, part)
      stop(fake)
      lifetime.releasePlain(holder)

      local again = start()

      expect(#again.folder:GetChildren()).toBe(0)
      expect(pool.stats().made).toBe(0)

      stop(again)
    end)
  end)
end)
