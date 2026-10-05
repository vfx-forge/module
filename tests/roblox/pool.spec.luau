local pool = require("@srv/pool")
local lifetime = require("@mod/lifetime")

-- local content, so no write reaches the network
local TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local OTHER_TEXTURE = "rbxasset://textures/particles/fire_main.dds"
local SOUND = "rbxasset://sounds/electronicpingshort.wav"
local OTHER_SOUND = "rbxasset://sounds/button.wav"

-- what the pool keeps of a part on purpose: an effect places it, a piece never
-- carries its template's motion, and a copy is always anchored and locked
local OWN_PART = {
  CFrame = true,
  Locked = true,
  Anchored = true,
  Velocity = true,
  RotVelocity = true,
}

local function check(condition: boolean, message: string)
  if condition then
    return
  end

  error(message, 2)
end

local function pick(value: any, first: any, second: any)
  return if value == first then second else first
end

-- a value of the same type that is not this one, nil for a type it cannot make
local function differ(value: any, name: string, spares: { [string]: { Instance } }): any
  local kind = typeof(value)

  if kind == "boolean" then
    return not value
  elseif kind == "number" then
    return if value > 0.5 then value * 0.5 else value + 1
  elseif kind == "string" then
    if name == "SoundId" then
      return pick(value, SOUND, OTHER_SOUND)
    end

    return if string.find(value, "rbxasset", 1, true) or value == ""
      then pick(value, TEXTURE, OTHER_TEXTURE)
      else `{value}Audit`
  elseif kind == "EnumItem" then
    for _, item in value.EnumType:GetEnumItems() do
      if item ~= value then
        return item
      end
    end
  elseif kind == "Color3" then
    return Color3.new(1 - value.R, 0.5 + value.G * 0.25, 1 - value.B)
  elseif kind == "Vector3" then
    return value + Vector3.new(1, 2, 3)
  elseif kind == "Vector2" then
    return value + Vector2.new(0.5, 0.25)
  elseif kind == "CFrame" then
    return value * CFrame.new(1, 2, 3) * CFrame.Angles(0, 1, 0)
  elseif kind == "NumberRange" then
    return NumberRange.new(value.Min + 1, value.Max + 2)
  elseif kind == "NumberSequence" then
    return pick(value, NumberSequence.new(0.3, 0.7), NumberSequence.new(0.6, 0.2))
  elseif kind == "ColorSequence" then
    return pick(
      value,
      ColorSequence.new(Color3.new(0.1, 0.8, 0.3), Color3.new(0.9, 0.2, 0.4)),
      ColorSequence.new(Color3.new(0.5, 0.5, 0.9))
    )
  elseif kind == "PhysicalProperties" then
    return PhysicalProperties.new(0.5, 0.25, 0.75)
  elseif kind == "Instance" then
    for _, spare in spares[value.ClassName] or {} do
      if spare ~= value then
        return spare
      end
    end
  end

  return nil
end

local function withPool(body: () -> ())
  -- an init here would replace the folder and maps of a pool the runtime uses
  check(not pool.started(), "the pool is already running; run this spec on a copy that is not inited")

  local scope = {}
  pool.init(scope)

  local ok, err = pcall(body)

  lifetime.releasePlain(scope)

  if not ok then
    error(err, 0)
  end
end

local function names(class: string, authored: { [string]: any })
  local list = table.clone(pool.engine.properties(class) or {})

  for name in authored do
    if not table.find(list, name) then
      table.insert(list, name)
    end
  end

  return list
end

-- every property a source authors that the engine does not list is named here
-- as well, so a property the pool's list misses fails rather than goes unseen
local function sources(spares: { [string]: { Instance } })
  local a, b = spares.Attachment[1], spares.Attachment[2]

  return {
    Part = {
      Size = Vector3.new(3, 1, 5),
      Color = Color3.new(0.8, 0.1, 0.2),
      Shape = Enum.PartType.Cylinder,
      Material = Enum.Material.Neon,
      Reflectance = 0.3,
      CastShadow = false,
      Transparency = 0.25,
      CustomPhysicalProperties = PhysicalProperties.new(Enum.Material.Wood),
    },
    MeshPart = {
      Size = Vector3.new(2, 4, 6),
      Color = Color3.new(0.2, 0.6, 0.9),
      TextureID = TEXTURE,
      Material = Enum.Material.Glass,
      Transparency = 0.4,
    },
    ParticleEmitter = {
      Rate = 7,
      Texture = TEXTURE,
      Lifetime = NumberRange.new(0.5, 1.5),
      LightEmission = 0.75,
      Color = ColorSequence.new(Color3.new(1, 0.5, 0)),
      Size = NumberSequence.new(2, 0.5),
    },
    Beam = {
      Width0 = 2,
      Width1 = 0.5,
      Segments = 4,
      Texture = TEXTURE,
      Attachment0 = a,
      Attachment1 = b,
      Color = ColorSequence.new(Color3.new(0, 1, 0.5)),
    },
    Trail = {
      Lifetime = 0.7,
      MinLength = 0.2,
      Texture = TEXTURE,
      Attachment0 = a,
      Attachment1 = b,
      WidthScale = NumberSequence.new(1, 0),
    },
    Attachment = {
      Visible = true,
      CFrame = CFrame.new(1, 2, 3) * CFrame.Angles(0.5, 0, 0),
    },
    PointLight = {
      Range = 20,
      Shadows = true,
      Brightness = 3,
      Color = Color3.new(1, 0.8, 0.2),
    },
    Decal = {
      Face = Enum.NormalId.Top,
      Texture = TEXTURE,
      Color3 = Color3.new(0.3, 0.9, 0.6),
      Transparency = 0.35,
    },
    Sound = {
      Looped = true,
      Volume = 0.3,
      SoundId = SOUND,
      PlaybackSpeed = 1.5,
      SoundGroup = spares.SoundGroup[1],
    },
    Highlight = {
      Adornee = a,
      FillColor = Color3.new(0.9, 0.1, 0.5),
      DepthMode = Enum.HighlightDepthMode.Occluded,
      FillTransparency = 0.2,
      OutlineColor = Color3.new(0.1, 0.4, 0.9),
    },
  }
end

local function spareSet(scratch: Instance)
  local spares = { Attachment = {}, SoundGroup = {} }

  for class, list in spares do
    for i = 1, 3 do
      local spare = Instance.new(class)
      spare.Name = `Spare{class}{i}`
      spare.Parent = scratch
      table.insert(list, spare)
    end
  end

  return spares
end

local function singleCase(class: string)
  return {
    name = `a reused {class} matches a fresh clone of its source`,
    run = function()
      local scratch = Instance.new("Folder")
      scratch.Name = "PoolSpecScratch"

      local ok, err = pcall(withPool, function()
        local spares = spareSet(scratch)
        local authored = sources(spares)[class]
        local source = Instance.new(class)
        source.Name = `Authored{class}`

        for name, value in authored do
          (source :: any)[name] = value
        end

        source.Parent = scratch

        local list = names(class, authored)
        local isPart = source:IsA("BasePart")
        local holder = {}
        local first = pool.take(holder, source)
        local written = 0

        for _, name in list do
          local value = differ((first :: any)[name], name, spares)

          if value == nil then
            continue
          end

          if pcall(function()
            (first :: any)[name] = value
          end) then
            written += 1
          end
        end

        check(written >= math.min(3, #list), `only {written} of {#list} listed properties took a write`)

        lifetime.releasePlain(holder)

        local again = {}
        local second = pool.take(again, source)
        local clone = source:Clone()
        local wrong = {}

        check(second == first, "the second take built a new instance instead of reusing the first")

        for _, name in list do
          if isPart and OWN_PART[name] then
            continue
          end

          local have, want = (second :: any)[name], (clone :: any)[name]

          if have ~= want then
            table.insert(wrong, `{name}: {tostring(have)} vs {tostring(want)}`)
          end
        end

        clone:Destroy()
        lifetime.releasePlain(again)

        check(#wrong == 0, table.concat(wrong, "; "))
      end)

      scratch:Destroy()

      if not ok then
        error(err, 0)
      end
    end,
  }
end

local cases = {
  {
    name = "the engine's list carries a part's size, color and shape and a highlight's look",
    run = function()
      local part = pool.engine.properties("Part") or {}
      local highlight = pool.engine.properties("Highlight") or {}

      for _, name in { "Size", "Color", "Shape", "MaterialVariant" } do
        check(table.find(part, name) ~= nil, `Part lacks {name}`)
      end

      for _, name in { "FillColor", "OutlineColor", "FillTransparency", "Adornee" } do
        check(table.find(highlight, name) ~= nil, `Highlight lacks {name}`)
      end

      -- derived from what is listed, and moving a part is its effect's business
      for _, name in { "Position", "Orientation", "BrickColor" } do
        check(table.find(part, name) == nil, `Part lists {name}`)
      end
    end,
  },
}

for _, class in
  { "Part", "MeshPart", "ParticleEmitter", "Beam", "Trail", "Attachment", "PointLight", "Decal", "Sound", "Highlight" }
do
  table.insert(cases, singleCase(class))
end

table.insert(cases, {
  name = "a kept set put back after its emit matches its template",
  run = function()
    local template = Instance.new("Part")
    template.Name = "KeptRoot"
    template.Anchored = true

    local mount = Instance.new("Attachment")
    mount.Name = "Mount"
    mount.Parent = template

    local emitter = Instance.new("ParticleEmitter")
    emitter.Name = "Sparks"
    emitter.Rate = 7
    emitter.Parent = mount

    local model = Instance.new("Model")
    model.Name = "Rig"
    model.Parent = template

    local inner = Instance.new("Part")
    inner.Name = "Inner"
    inner.Anchored = true
    inner.Size = Vector3.new(2, 2, 2)
    inner.Parent = model

    local ok, err = pcall(withPool, function()
      local holder = {}
      local copy = pool.take(holder, template)
      local copyEmitter = copy:FindFirstChild("Mount"):FindFirstChild("Sparks") :: ParticleEmitter
      local copyModel = copy:FindFirstChild("Rig") :: Model

      copyEmitter.Rate = 99
      copyEmitter.Color = ColorSequence.new(Color3.new(0, 0, 1))
      copyModel:ScaleTo(2)
      copyModel:PivotTo(copyModel:GetPivot() * CFrame.new(10, 0, 0))

      lifetime.releasePlain(holder)

      local found = pool.audit()

      check(#found == 0, `audit: {table.concat(found, "; ")}`)
      check(copyModel:GetScale() == model:GetScale(), `copy scale {copyModel:GetScale()}`)
      check(copyModel.WorldPivot == model.WorldPivot, `copy pivot {copyModel.WorldPivot}`)
      check(copyEmitter.Enabled == false, "a free set's emitter is enabled")

      local again = {}

      check(pool.take(again, template) == copy, "the set was not reused")
      check(pool.stats().builds == 1, `{pool.stats().builds} builds`)

      lifetime.releasePlain(again)
    end)

    template:Destroy()

    if not ok then
      error(err, 0)
    end
  end,
})

table.insert(cases, {
  name = "a first build points a beam at its copy's attachments, not the template's",
  run = function()
    local template = Instance.new("Part")
    template.Name = "BeamRoot"
    template.Anchored = true

    local from = Instance.new("Attachment")
    from.Name = "From"
    from.Parent = template

    local to = Instance.new("Attachment")
    to.Name = "To"
    to.Parent = template

    local beam = Instance.new("Beam")
    beam.Name = "Ray"
    beam.Attachment0 = from
    beam.Attachment1 = to
    beam.Parent = template

    local ok, err = pcall(withPool, function()
      local holder = {}
      local copy = pool.take(holder, template)
      local ray = copy:FindFirstChild("Ray") :: Beam

      check(
        ray.Attachment0 == copy:FindFirstChild("From"),
        `Attachment0 is {ray.Attachment0 and ray.Attachment0:GetFullName()}`
      )
      check(
        ray.Attachment1 == copy:FindFirstChild("To"),
        `Attachment1 is {ray.Attachment1 and ray.Attachment1:GetFullName()}`
      )

      lifetime.releasePlain(holder)
    end)

    template:Destroy()

    if not ok then
      error(err, 0)
    end
  end,
})

return cases
