local attr = require("@mod/attributes")
local curves = require("@mod/curves")
local harness = require("@tests/harness")
local registry = require("@mod/registry")
local test, expect = harness.test, harness.expect
local Vector3 = harness.datatypes.Vector3

local MODULES = {
  "beam",
  "mesh",
  "spin",
  "sound",
  "trail",
  "bezier",
  "screen",
  "particle",
  "lightning",
  "shockwave",
  "camera_shake",
  "shockwave_ring",
  "shockwave_line",
  "shockwave_debris",
  "controller",
}

-- the two piece modules whose Size row rests on a draw between two corners
local PIECES = { "shockwave_ring", "shockwave_line" }

local MIN_SIZE = Vector3.new(2, 1, 2)
local MAX_SIZE = Vector3.new(3, 2, 3)

local function inside(v: any, lo: Vector3, hi: Vector3): boolean
  return v.X >= lo.X and v.X <= hi.X and v.Y >= lo.Y and v.Y <= hi.Y and v.Z >= lo.Z and v.Z <= hi.Z
end

-- what the beam read for its flipbook curve before the curve was a row,
-- written out here before the read is deleted
local function oldFlipbookCurve(beam: Instance)
  return attr.get(beam, "Flipbook_Change_Curve", curves.linear(), true)
end

-- the built-ins are the require cache's own tables and registering freezes
-- them, so they load once for the whole file rather than once per case
local loaded = false

local function loadAll()
  if loaded then
    return
  end

  registry.clear()
  registry.configure({ query = harness.query })

  for _, name in MODULES do
    registry.register(require(`@vfx/{name}`))
  end

  loaded = true
end

-- one of everything, the way the plugin authors it
local function scene()
  harness.reset()

  local root = harness.make("Folder")
  local made = {}

  made.trail = harness.make("Trail", root)
  made.particle = harness.make("ParticleEmitter", root)
  made.beam = harness.make("Beam", root)
  made.sound = harness.make("Sound", root)

  made.camera_shake = harness.make("RayValue", root)
  made.camera_shake:AddTag("CameraShake")

  made.model_spin = harness.make("Model", root)
  harness.make("Part", made.model_spin)

  made.mesh = harness.make("Model", root)
  harness.make("Part", made.mesh).Name = "Start"
  harness.make("Part", made.mesh).Name = "End"

  made.screen = harness.make("Part", root)
  made.screen:SetAttribute("Enabled", true)

  made.shockwave = harness.make("Attachment", root)
  made.shockwave:AddTag("Shockwave")

  for _, folder in { "Rings", "Lines", "Debris" } do
    local f = harness.make("Folder", made.shockwave)
    f.Name = folder
    made[`shockwave_{string.lower(folder)}`] = harness.make("Part", f)
  end

  made.shockwave_ring = made.shockwave_rings
  made.shockwave_line = made.shockwave_lines
  made.shockwave_rings, made.shockwave_lines = nil, nil

  made.bezier = harness.make("Attachment", root)
  made.bezier:AddTag("BezierParticle")
  harness.make("Part", made.bezier)

  made.lightning = harness.make("Attachment", root)
  made.lightning:AddTag("LightningBolt")
  harness.make("Part", made.lightning)

  made.controller = harness.make("RayValue", root)
  made.controller:AddTag("Controller")

  return root, made
end

harness.suite(function()
  harness.describe("the built-in modules", function()
    test("every one registers, with a distinct id and order", function()
      loadAll()

      local list = registry.list()

      expect(#list).toBe(#MODULES)

      local seen = {}

      for _, module in list do
        expect(seen[module.display.order]).toBe(nil)
        seen[module.display.order] = module.id
      end
    end)

    test("every module classifies its own instance and no other", function()
      loadAll()

      local root, made = scene()

      for id, inst in made do
        local module = registry.of(inst)

        expect(module ~= nil and module.id).toBe(id)
      end

      local hits = {}

      for _, hit in registry.scan(root) do
        hits[hit.effect.id] = (hits[hit.effect.id] or 0) + 1
      end

      for id in made do
        expect(hits[id]).toBe(1)
      end

      local count = 0

      for _ in hits do
        count += 1
      end

      expect(count).toBe(#MODULES)
    end)

    test("only the three constant modules may be ticked", function()
      loadAll()

      local constant = {}

      for _, module in registry.list() do
        if module.constant then
          table.insert(constant, module.id)
        end
      end

      table.sort(constant)

      expect(constant).toEqual({ "bezier", "lightning", "mesh" })
    end)

    test("no layout offers a button for the ConstantVFX tag", function()
      loadAll()

      local function offers(entries: { any })
        for _, entry in entries do
          if type(entry) ~= "table" then
            continue
          end

          if entry.action == "toggle_constant" or (entry.entries ~= nil and offers(entry.entries)) then
            return true
          end
        end

        return false
      end

      for _, module in registry.list() do
        expect(`{module.id}: {offers(module.layout or {})}`).toBe(`{module.id}: false`)
      end
    end)

    test("every row the plugin shows has a label and a hint", function()
      loadAll()

      for _, module in registry.list() do
        for _, rows in { module.attributes, module.properties } do
          for name, row in rows do
            if row.hiddenRule ~= nil then
              continue
            end

            expect(type(row.title) == "string" and row.title ~= "").toBe(true)
            expect(type(row.details) == "string" and row.details ~= "").toBe(true)
          end
        end
      end
    end)

    test("every visible row is placed by the layout exactly once", function()
      loadAll()

      for _, module in registry.list() do
        local placed = {}

        local function walk(entries: { any })
          for _, entry in entries do
            if type(entry) == "string" then
              expect(placed[entry]).toBe(nil)
              placed[entry] = true
            elseif type(entry) == "table" and entry.curve ~= nil then
              -- a compound entry draws a set of rows as one, and places each
              -- row it names exactly as a bare name does
              for _, key in { "curve", "duration" } do
                local named = entry[key]

                if named ~= nil then
                  expect(placed[named]).toBe(nil)
                  placed[named] = true
                end
              end
            elseif type(entry) == "table" and type(entry.entries) == "table" then
              walk(entry.entries)
            end
          end
        end

        walk(module.layout or {})

        for _, rows in { module.attributes, module.properties } do
          for name, row in rows do
            if row.hiddenRule == nil then
              expect(placed[name]).toBe(true)
            end
          end
        end
      end
    end)

    test("a piece with no size authored draws between the old corners, once per piece", function()
      loadAll()

      local _, made = scene()

      for _, id in PIECES do
        local attrs = registry.read(made[id])

        expect(attrs.Size.animated).toBe(true)
        expect(inside(attrs.Size().at(0), MIN_SIZE, MAX_SIZE)).toBe(true)
        expect(inside(attrs.Size().at(0), MIN_SIZE, MAX_SIZE)).toBe(true)
      end
    end)

    test("a piece authoring one corner draws between it and the other corner's default", function()
      loadAll()

      local _, made = scene()

      for _, id in PIECES do
        made[id]:SetAttribute("MaxSize", MIN_SIZE)

        local drawn = registry.read(made[id]).Size().at(0)

        expect(inside(drawn, MIN_SIZE, MIN_SIZE)).toBe(true)
      end
    end)

    test("a piece authoring both corners draws inside them", function()
      loadAll()

      local _, made = scene()

      local lo = Vector3.new(4, 4, 4)
      local hi = Vector3.new(8, 8, 8)

      for _, id in PIECES do
        made[id]:SetAttribute("MinSize", lo)
        made[id]:SetAttribute("MaxSize", hi)

        local attrs = registry.read(made[id])

        expect(attrs.Size.animated).toBe(true)
        expect(inside(attrs.Size().at(0), lo, hi)).toBe(true)
      end
    end)

    test("a size authored on the row itself is what every piece rests at", function()
      loadAll()

      local _, made = scene()

      local size = Vector3.new(6, 5, 4)

      for _, id in PIECES do
        made[id]:SetAttribute("Size", size)

        local attrs = registry.read(made[id])

        expect(attrs.Size.animated).toBe(false)
        expect(inside(attrs.Size().at(0), size, size)).toBe(true)
      end
    end)

    test("every hidden duration row carries the seconds unit", function()
      loadAll()

      local seen = 0

      for _, module in registry.list() do
        for _, rows in { module.attributes, module.properties } do
          for name, row in rows do
            -- a switch named for a duration, such as SyncDuration, is no span
            if row.hiddenRule == nil or string.sub(name, -8) ~= "Duration" or row.kind == "boolean" then
              continue
            end

            -- a hidden span is reached by nothing but retime, which finds it
            -- by its unit alone: without one the key is claimed and scaled by
            -- no one
            seen += 1

            expect(row.units).toBe("seconds")
          end
        end
      end

      expect(seen > 0).toBe(true)
    end)

    test("a read of every module against its bare instance answers every row", function()
      loadAll()

      local _, made = scene()

      for id, inst in made do
        local attrs, props = registry.read(inst)
        local module = registry.get(id)

        for name in module.attributes do
          expect(rawget(attrs, name) ~= nil or module.attributes[name].hasDefault == false).toBe(true)
        end

        for name in module.properties do
          expect(rawget(props, name) ~= nil or module.properties[name].hasDefault == false).toBe(true)
        end
      end
    end)

    test("a beam's flipbook curve reads what the old attribute read", function()
      loadAll()

      local _, made = scene()

      expect(registry.read(made.beam).FlipbookChangeCurve).toBe(oldFlipbookCurve(made.beam))

      -- this host's attributes hold only valid utf-8, so a serialized curve is
      -- written through the cache the way every other spec writes one
      made.beam:SetAttribute("Flipbook_Change_Curve", "")
      attr.cache(made.beam)
      attr.set(made.beam, "Flipbook_Change_Curve", curves.default())

      expect(registry.read(made.beam).FlipbookChangeCurve).toBe(oldFlipbookCurve(made.beam))
      expect(registry.read(made.beam).FlipbookChangeCurve).toBe(curves.default())
    end)

    test("a mesh reads its frame and glow rows at their defaults", function()
      loadAll()

      local _, made = scene()
      local attrs = registry.read(made.mesh)
      local strength = attrs.EmissiveStrength(nil, 1)
      local tint = attrs.EmissiveTint(nil, 1)
      local fade = attrs.FrameTransparency(nil, 1)

      expect(attrs.FrameSet).toBe("")
      expect(fade.animated).toBe(false)
      expect(fade.at(0)).toBe(0)
      expect(attrs.FlipbookChangeDuration).toBe(1)
      expect(attrs.FlipbookChangeCurve).toBe(curves.linear())
      expect(attrs.SyncDuration).toBe(false)
      expect(attrs.FlipbookLoop).toBe(false)
      expect(attrs.FlipbookLoopCount).toBe(0)
      expect(attrs.TextureLoop).toBe(true)
      expect(attrs.TextureLoopCount).toBe(0)
      expect(attrs.TextureSyncDuration).toBe(false)
      expect(strength.animated).toBe(false)
      expect(strength.at(0)).toBe(1)
      expect(tint.animated).toBe(false)
      expect(tint.at(0)).toEqual(Color3.new(1, 1, 1))
    end)

    test("a mesh decal's end is clear only where the model stores an old start for it", function()
      loadAll()

      local function endOf(stored: { [string]: any }, decal: boolean?)
        local _, made = scene()

        if decal ~= false then
          harness.make("Decal", made.mesh:FindFirstChild("Start"))
        end

        for name, v in stored do
          made.mesh:SetAttribute(name, v)
        end

        return registry.read(made.mesh).DecalEndTransparency
      end

      expect(endOf({})).toBe(nil)
      expect(endOf({ Decal_StartTransparency = 0 })).toBe(1)
      expect(endOf({ DecalStartTransparency = 0.2 })).toBe(1)
      expect(endOf({ StartTransparency = 0 })).toBe(1)
      expect(endOf({ Decal_StartTransparency = 0, EndTransparency = 0 })).toBe(0)
      expect(endOf({ Decal_StartTransparency = 0, Decal_EndTransparency = 0.5 })).toBe(0.5)
      expect(endOf({}, false)).toBe(1)
    end)

    test("a mesh lays its frame and glow rows out before its behavior", function()
      loadAll()

      local module = registry.get("mesh")
      local rows = module.attributes
      local titles = {}

      for _, group in module.layout do
        if type(group) == "table" and group.title ~= nil then
          table.insert(titles, group.title)
        end
      end

      local frames = table.find(titles, "Frames")
      local glow = table.find(titles, "Glow")

      expect(frames ~= nil and glow ~= nil).toBe(true)
      expect(glow).toBe((frames :: number) + 1)
      expect(titles[(glow :: number) + 1]).toBe("Behavior")
      expect(module.layout[frames :: number].entries).toEqual({
        { curve = "FlipbookChangeCurve", duration = "FlipbookChangeDuration" },
        "SyncDuration",
        "FlipbookLoop",
        "FlipbookLoopCount",
        "FrameTransparency",
        "TextureFps",
        "TextureSyncDuration",
        "TextureLoop",
        "TextureLoopCount",
      })
      expect(module.layout[glow :: number].entries).toEqual({ "SurfaceColor", "EmissiveStrength", "EmissiveTint" })
      expect(rows.FrameSet.hiddenRule ~= nil).toBe(true)
      expect(rows.FrameTransparency.title).toBe("Transparency")
      expect(rows.FrameTransparency.upper).toBe(1)

      -- the frame rows show only on a mesh that plays a frame set; its glow shows on every mesh
      for _, name in
        { "FlipbookChangeCurve", "FlipbookChangeDuration", "SyncDuration", "FlipbookLoop", "FrameTransparency" }
      do
        local rule = rows[name].hiddenRule

        expect(rule ~= nil and rule(nil, { FrameSet = "" }) == true).toBe(true)
        expect(rule ~= nil and rule(nil, { FrameSet = "walk" }) == false).toBe(true)
      end

      -- the texture rows show only on a mesh that wears a texture set
      for _, name in { "TextureFps", "TextureSyncDuration", "TextureLoop" } do
        local textureRule = rows[name].hiddenRule

        expect(textureRule ~= nil and textureRule(nil, { TextureSet = "" }) == true).toBe(true)
        expect(textureRule ~= nil and textureRule(nil, { TextureSet = "walk" }) == false).toBe(true)
      end

      expect(rows.TextureSet.hiddenRule ~= nil).toBe(true)

      -- a loop count shows only while its set plays and loops
      local frameCount = rows.FlipbookLoopCount.hiddenRule
      local textureCount = rows.TextureLoopCount.hiddenRule

      expect(frameCount(nil, { FrameSet = "walk", FlipbookLoop = true })).toBe(false)
      expect(frameCount(nil, { FrameSet = "walk", FlipbookLoop = false })).toBe(true)
      expect(frameCount(nil, { FrameSet = "", FlipbookLoop = true })).toBe(true)
      expect(textureCount(nil, { TextureSet = "walk", TextureLoop = true })).toBe(false)
      expect(textureCount(nil, { TextureSet = "walk", TextureLoop = false })).toBe(true)
      expect(textureCount(nil, { TextureSet = "", TextureLoop = true })).toBe(true)

      expect(rows.EmissiveStrength.hiddenRule).toBe(nil)
      expect(rows.EmissiveTint.hiddenRule).toBe(nil)
      expect(rows.FlipbookChangeDuration.units).toBe("seconds")
      expect(rows.EmissiveStrength.title).toBe("Strength")
      expect(rows.EmissiveTint.title).toBe("Tint")
    end)
  end)

  -- the modules whose pieces are authored where they emit: the plugin settles a
  -- selected instance through this hook before it shows the rows
  local SETTLED = {
    mesh = true,
    bezier = true,
    lightning = true,
    shockwave_ring = true,
    shockwave_line = true,
    shockwave_debris = true,
  }

  test("only the modules authored at their origin carry a selected hook", function()
    loadAll()

    for _, module in registry.list() do
      if SETTLED[module.id] then
        expect(type(module.selected)).toBe("function")
      else
        expect(module.selected).toBe(nil)
      end
    end
  end)
end)
