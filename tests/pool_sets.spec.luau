local knob = require("@mod/knob")
local pool = require("@srv/pool")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")

local test, expect = harness.test, harness.expect

local LISTS = {
  Part = { "Color", "Size", "Transparency", "Material", "Anchored", "CanCollide", "Locked" },
  MeshPart = { "Color", "Size", "Transparency", "Anchored", "Locked" },
  Beam = { "Enabled", "Width0", "Attachment0" },
  ParticleEmitter = { "Enabled", "Rate", "LightEmission" },
  Attachment = { "Visible" },
  Folder = {},
  Sound = { "Volume" },
  Configuration = {},
}

type Fake = {
  engine: any,
  folder: Instance,
  scope: { any },
  settled: { Instance },
  meshes: { string },
  made: number,
  wrappers: { [string]: Instance },
  stable: (inst: Instance) -> Instance,
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

-- an engine with no signals: lune instances have none, so the spec fires
-- what the pool listens to itself
local function start(): Fake
  local fake = { settled = {}, meshes = {}, made = 0, scope = {}, wrappers = {} } :: any
  local folder = harness.make("Folder")

  -- lune hands out a fresh wrapper for an instance on every walk, so a walk
  -- answers the first wrapper seen for each, which is what a map keyed by
  -- instance finds in Studio
  local function canonical(inst: Instance): Instance
    local id = inst:GetDebugId()
    local first = fake.wrappers[id]

    if first == nil then
      first = inst
      fake.wrappers[id] = inst
    end

    return first
  end

  fake.folder = folder
  fake.stable = canonical
  fake.engine = {
    folder = function()
      return folder
    end,
    fromExisting = function(source: Instance)
      fake.made += 1

      local copy = source:Clone()
      copy:ClearAllChildren()

      return canonical(copy)
    end,
    applyMesh = function(_, source: Instance)
      table.insert(fake.meshes, source.Name)
    end,
    properties = function(class: string)
      return LISTS[class]
    end,
    watch = function(template: Instance, changed: () -> ())
      fake.changed = fake.changed or {}
      fake.changed[template] = changed

      return {}
    end,
    listen = function(inst: Instance, changed: () -> ())
      fake.dirty = fake.dirty or {}
      fake.dirty[inst] = changed

      return { Disconnect = function() end }
    end,
    children = function(inst: Instance)
      local list = {}

      for _, child in inst:GetChildren() do
        table.insert(list, canonical(child))
      end

      return list
    end,
    destroying = function(inst: Instance, fn: () -> ())
      fake.destroyed = fake.destroyed or {}
      fake.destroyed[inst] = fn

      return { Disconnect = function() end }
    end,
    settle = function(inst: Instance)
      table.insert(fake.settled, inst)
    end,
  }

  registry.configure({ query = claimedQuery })
  pool.engine = fake.engine
  pool.init(fake.scope)

  return fake
end

local function stop(fake: Fake)
  lifetime.releasePlain(fake.scope)
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
  end)
end)
