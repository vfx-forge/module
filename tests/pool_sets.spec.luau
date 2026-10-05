local knob = require("@mod/knob")
local pool = require("@srv/pool")
local recolor = require("@mod/recolor")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local fake_pool = require("@tests/fake_pool")

local test, expect = harness.test, harness.expect
local CFrame = harness.datatypes.CFrame
local Color3 = harness.datatypes.Color3

local LISTS = {
  Part = { "Color", "Size", "Transparency", "Material", "Anchored", "CanCollide", "Locked", "CFrame" },
  MeshPart = { "Color", "Size", "Transparency", "Anchored", "Locked" },
  Beam = { "Enabled", "Width0", "Attachment0" },
  ParticleEmitter = { "Enabled", "Rate", "LightEmission" },
  Attachment = { "Visible" },
  Folder = {},
  Sound = { "Volume", "Playing" },
  Configuration = {},
  PointLight = { "Color", "Enabled" },
}

-- the pool's copies are clones harness.query never sees, and its pool holds
-- instances other specs destroyed, so a build's claim check walks the copy and
-- answers the probe's classifier alone
local function claimedQuery(root: Instance, selector: string): { Instance }
  local found = {}

  if selector ~= "Configuration#CustomClaimed" then
    return found
  end

  for _, desc in root:GetDescendants() do
    if desc:IsA("Configuration") and desc.Name == "CustomClaimed" then
      table.insert(found, desc)
    end
  end

  return found
end

local function start(): fake_pool.Fake
  registry.configure({ query = claimedQuery })

  return fake_pool.start(LISTS)
end

local function stop(fake: fake_pool.Fake)
  fake_pool.stop(fake)
  registry.configure({ query = harness.query })
end

local function template(): (Part, ParticleEmitter, Folder)
  local part = harness.make("Part") :: Part
  local attachment = harness.make("Attachment", part)
  local emitter = harness.make("ParticleEmitter", attachment) :: ParticleEmitter
  local finish = harness.make("Folder", part) :: Folder

  part.Name = "Piece"
  attachment.Name = "Center"
  emitter.Name = "Glow"
  finish.Name = "EmitOnFinish"
  harness.make("ParticleEmitter", finish).Name = "Burst"

  emitter.Rate = 20
  emitter.Enabled = true

  return part, emitter, finish
end

harness.suite(function()
  harness.describe("the pool's kept sets", function()
    test("a second take reuses the set the first built", function()
      local fake = start()
      local source = template()
      local holder = {}
      local first = pool.take(holder, source)

      expect(#first:GetDescendants()).toBe(4)
      lifetime.releasePlain(holder)

      local second = pool.take(holder, source)

      expect(second).toBe(first)
      expect(pool.stats().builds).toBe(1)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("what an effect wrote on a copy is put back from its twin", function()
      local fake = start()
      local source = template()
      local holder = {}
      local copy = pool.take(holder, source)
      local glow = copy:FindFirstChild("Center"):FindFirstChild("Glow") :: ParticleEmitter

      glow.Rate = 999
      glow.LightEmission = 0.5
      lifetime.releasePlain(holder)

      expect(pool.audit()).toEqual({})

      pool.take(holder, source)

      expect(glow.Rate).toBe(20)
      expect(glow.LightEmission).toBe(0)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a member a hair from its twin's CFrame is neither rewritten nor reported", function()
      local fake = start()
      local source = harness.make("Part")
      local bit = harness.make("Part", source) :: Part
      local holder = {}

      bit.Name = "Bit"
      bit.CFrame = CFrame.new(1, 2, 3)

      -- lune has no default for a LocalTransparencyModifier, so the source sets one
      bit.LocalTransparencyModifier = 0

      local authored = bit.CFrame
      local near = authored * CFrame.new(0, 5e-5, 0) * CFrame.Angles(5e-5, 0, 0)
      local copy = pool.take(holder, source)
      local member = copy:FindFirstChild("Bit") :: Part

      member.CFrame = near

      -- what the write left, which need not read back as written
      local held = member.CFrame

      expect(held ~= authored).toBe(true)

      lifetime.releasePlain(holder)

      expect(pool.audit()).toEqual({})
      expect(member.CFrame).toBe(held)

      pool.take(holder, source)
      member.CFrame = authored * CFrame.new(0, 0.01, 0)
      lifetime.releasePlain(holder)

      expect(member.CFrame).toBe(authored)

      stop(fake)
    end)

    test("a free kept set shows nothing, and a take turns it back on", function()
      local fake = start()
      local source = template()
      local holder = {}
      local copy = pool.take(holder, source)
      local glow = copy:FindFirstChild("Center"):FindFirstChild("Glow") :: ParticleEmitter

      lifetime.releasePlain(holder)

      expect(glow.Enabled).toBe(false)
      expect((copy :: Part).Transparency).toBe(1)
      expect(table.find(fake.settled, glow) ~= nil).toBe(true)

      pool.take(holder, source)

      expect(glow.Enabled).toBe(true)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a folder an effect detached and emptied goes back with its children", function()
      local fake = start()
      local source = template()
      local holder = {}
      local copy = pool.take(holder, source)
      local finish = fake.stable(copy:FindFirstChild("EmitOnFinish") :: Folder)
      local burst = finish:FindFirstChild("Burst") :: Instance

      expect(pool.kept(finish)).toBe(true)

      finish.Parent = nil
      burst.Parent = copy
      lifetime.releasePlain(holder)

      expect(finish.Parent).toBe(copy)
      expect(burst.Parent).toBe(finish)
      expect(pool.take(holder, source)).toBe(copy)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a set that gained an instance is destroyed, not filed", function()
      local fake = start()
      local source = template()
      local holder = {}
      local copy = pool.take(holder, source)

      harness.make("Folder", copy)
      lifetime.releasePlain(holder)

      expect(pool.take(holder, source) ~= copy).toBe(true)
      expect(pool.stats().builds).toBe(2)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a set that lost an instance is destroyed, not filed", function()
      local fake = start()
      local source = template()
      local holder = {}
      local copy = pool.take(holder, source)

      local glow = fake.stable(copy:FindFirstChild("Center"):FindFirstChild("Glow") :: Instance)

      glow:Destroy()
      fake.destroyed[glow]()
      lifetime.releasePlain(holder)

      expect(pool.take(holder, source) ~= copy).toBe(true)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("an edit to the template drops its free sets", function()
      local fake = start()
      local source = template()
      local holder = {}
      local copy = pool.take(holder, source)

      lifetime.releasePlain(holder)
      fake.changed[source]()

      expect(pool.take(holder, source) ~= copy).toBe(true)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a recolor reaches a take in the same frame", function()
      local fake = start()
      local source = harness.make("Part") :: Part
      local light = harness.make("PointLight", source) :: PointLight
      local holder = {}

      light.Name = "Glow"
      light.Color = Color3.new(1, 1, 1)

      pool.take(holder, source)
      lifetime.releasePlain(holder)

      recolor(Color3.new(1, 0, 0), "replace", source)

      local copy = pool.take(holder, source)
      local glow = copy:FindFirstChild("Glow") :: PointLight

      expect(glow.Color).toBe(light.Color)
      expect(pool.stats().builds).toBe(2)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a set taken before an edit is destroyed on release", function()
      local fake = start()
      local source = template()
      local holder = {}
      local copy = pool.take(holder, source)

      fake.changed[source]()
      lifetime.releasePlain(holder)

      expect(pool.take(holder, source) ~= copy).toBe(true)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("an attribute written on a copy destroys its set on release", function()
      local fake = start()
      local source = template()
      local holder = {}
      local copy = pool.take(holder, source)
      local glow = fake.stable(copy:FindFirstChild("Center"):FindFirstChild("Glow") :: Instance)

      glow:SetAttribute("Written", true)
      fake.dirty[glow]()
      lifetime.releasePlain(holder)

      expect(pool.take(holder, source) ~= copy).toBe(true)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a registry change drops every set", function()
      local fake = start()
      local source = template()
      local holder = {}
      local copy = pool.take(holder, source)

      lifetime.releasePlain(holder)
      registry.version += 1

      expect(pool.take(holder, source) ~= copy).toBe(true)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a nested source is keyed by its authored twin", function()
      local fake = start()
      local outer = harness.make("Part")
      local inner = fake.stable((template()))
      inner.Parent = outer

      local holder = {}
      local copy = pool.take(holder, outer)
      local nested = fake.stable(copy:FindFirstChild("Piece") :: Instance)
      local a = pool.take(holder, nested)

      lifetime.releasePlain(holder)

      local again = {}
      local b = pool.take(again, inner)

      expect(b).toBe(a)

      lifetime.releasePlain(again)
      stop(fake)
    end)

    test("a template with a script clones fresh every emit", function()
      local fake = start()
      local source = template()
      harness.make("Script", source)

      local holder = {}
      local copy = pool.take(holder, source)

      expect(copy:FindFirstChildOfClass("Script") ~= nil).toBe(true)
      lifetime.releasePlain(holder)

      local again = pool.take(holder, source)

      expect(again:FindFirstChildOfClass("Script") ~= nil).toBe(true)
      expect(pool.stats().builds).toBe(0)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a template a custom effect claims inside clones fresh every emit", function()
      local fake = start()
      local source = template()
      local marker = harness.make("Configuration", source)
      marker.Name = "CustomClaimed"

      local custom = {
        id = "pool_probe",
        display = { name = "pool_probe", icon = "pool_probe", order = 10 },
        classifier = "Configuration#CustomClaimed",
        attributes = { EmitDelay = knob(0):min(0) },
        properties = {},
        emit = function() end,
      }

      registry.register(custom :: any, true)

      local holder = {}

      pool.take(holder, source)
      lifetime.releasePlain(holder)
      pool.take(holder, source)

      expect(pool.stats().builds).toBe(0)

      lifetime.releasePlain(holder)
      registry.unregister(custom :: any)
      stop(fake)
    end)

    test("members another set left under a part go home before its release", function()
      local fake = start()
      local source = template()
      local bare = harness.make("Part")
      local holder, other = {}, {}
      local copy = pool.take(holder, source)
      local plain = pool.take(other, bare, true)
      local center = copy:FindFirstChild("Center") :: Instance

      center.Parent = plain
      lifetime.releasePlain(other)

      expect(center.Parent).toBe(copy)

      lifetime.releasePlain(holder)
      expect(pool.take(holder, source)).toBe(copy)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a kept root is hidden and settled while free, and shown again on a take", function()
      local fake = start()
      local beam = harness.make("Beam") :: Beam
      beam.Enabled = true
      harness.make("Configuration", beam)

      local holder = {}
      local copy = pool.take(holder, beam) :: Beam

      expect(pool.stats().builds).toBe(1)
      lifetime.releasePlain(holder)

      expect(copy.Enabled).toBe(false)
      expect(table.find(fake.settled, copy) ~= nil).toBe(true)
      expect(pool.take(holder, beam)).toBe(copy)
      expect(copy.Enabled).toBe(true)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("what another holder uses is sent home before a spoiled set is destroyed", function()
      local fake = start()
      local source = template()
      local bare = harness.make("Part")
      local holder, other = {}, {}
      local copy = pool.take(holder, source)
      local plain = pool.take(other, bare, true)

      plain.Parent = copy
      fake.changed[source]()
      lifetime.releasePlain(holder)

      expect(plain.Parent).toBe(fake.folder)
      expect(pool.take(holder, source) ~= copy).toBe(true)

      lifetime.releasePlain(holder)
      lifetime.releasePlain(other)
      stop(fake)
    end)

    test("a take sent home from under a set is never walked into", function()
      local fake = start()
      local source = template()
      local scripted = harness.make("Part")
      harness.make("Script", scripted)

      local holder, other = {}, {}
      local copy = pool.take(holder, source)
      local carrier = pool.take(other, scripted)

      carrier.Parent = copy
      lifetime.releasePlain(holder)

      expect(carrier.Parent).toBe(fake.folder)
      expect(carrier:FindFirstChildOfClass("Script") ~= nil).toBe(true)
      expect(pool.take(holder, source)).toBe(copy)

      lifetime.releasePlain(holder)
      lifetime.releasePlain(other)
      stop(fake)
    end)

    test("a free part member cannot collide, be queried, be touched or be selected", function()
      local fake = start()
      local outer = harness.make("Part")
      local shard = harness.make("Part", outer) :: Part
      shard.Name = "Shard"
      shard.CanCollide = true
      shard.Locked = false

      -- lune has no default for a LocalTransparencyModifier, so the source sets one
      shard.LocalTransparencyModifier = 0

      local holder = {}
      local copy = pool.take(holder, outer)
      local member = copy:FindFirstChild("Shard") :: Part

      lifetime.releasePlain(holder)

      expect(member.CanCollide).toBe(false)
      expect(member.CanQuery).toBe(false)
      expect(member.CanTouch).toBe(false)
      expect(member.Locked).toBe(true)
      expect(member.LocalTransparencyModifier).toBe(1)
      expect(pool.audit()).toEqual({})

      pool.take(holder, outer)

      expect(member.CanCollide).toBe(true)
      expect(member.CanQuery).toBe(true)
      expect(member.CanTouch).toBe(true)
      expect(member.Locked).toBe(false)
      expect(member.LocalTransparencyModifier).toBe(0)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a sound member authored playing is quiet while free and plays again on a take", function()
      local fake = start()
      local outer = harness.make("Part")
      local hum = harness.make("Sound", outer) :: Sound
      hum.Name = "Hum"
      hum.Playing = true

      local holder = {}
      local copy = pool.take(holder, outer)
      local member = copy:FindFirstChild("Hum") :: Sound

      lifetime.releasePlain(holder)

      expect(member.Playing).toBe(false)

      pool.take(holder, outer)

      expect(member.Playing).toBe(true)

      lifetime.releasePlain(holder)
      stop(fake)
    end)

    test("a free set spoiled while it waits is not handed out", function()
      local fake = start()
      local source = template()
      local holder = {}
      local copy = pool.take(holder, source)
      local glow = fake.stable(copy:FindFirstChild("Center"):FindFirstChild("Glow") :: Instance)

      lifetime.releasePlain(holder)
      fake.dirty[glow]()

      expect(pool.take(holder, source) ~= copy).toBe(true)
      expect(pool.stats().builds).toBe(2)

      lifetime.releasePlain(holder)
      stop(fake)
    end)
  end)
end)
