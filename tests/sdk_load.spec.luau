local fs = require("@lune/fs")
local curves = require("@mod/curves")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

local load = require("@root/sdk/load")
local custom = require("@root/sdk/custom")
local facade = require("@root/sdk/v1/facade")

-- a custom effect as an author writes it, every field overridable
local function effect(extra: { [string]: any }?)
  local out: { [string]: any } = {
    sdk_version = 1,
    id = "my_effect",
    display = { name = "My Effect" },
    classifier = "Folder.MyEffect",
    params = function(sdk: any)
      return {
        attributes = {
          FadeTime = sdk.knob(0.5):min(0):unit("seconds"),
        },
      }
    end,
    emit = function(sdk: any, ctx: any, attrs: any)
      sdk.wait(ctx, attrs.FadeTime)
    end,
  }

  for k, v in extra or {} do
    out[k] = v
  end

  return out
end

local function fresh()
  custom.clear()
  registry.clear()
  registry.configure({ query = harness.query })
  harness.reset()
  effects.init({ setup = true } :: any)
end

local function builtins()
  registry.register(require("@vfx/beam"))
  registry.register(require("@vfx/bezier"))
end

-- parented, since a classifier past a bare class is matched from above
local function tagged(): Instance
  local folder = harness.make("Folder", harness.make("Folder"))

  folder:AddTag("MyEffect")

  return folder
end

local function refusal(author: any): { string }
  local module, found = load.assemble(author, "ReplicatedStorage.MyEffect")

  expect(module).toBe(nil)

  return found
end

harness.suite(function()
  harness.describe("loading a custom effect", function()
    test("a valid module registers, and plays through the facade", function()
      fresh()

      local ok, found = custom.add("a", effect(), "ReplicatedStorage.MyEffect")

      expect(ok).toBe(true)
      expect(found).toEqual({})
      expect(registry.get("my_effect").display.name).toBe("My Effect")

      local env = effects.emit(0, tagged())

      scheduler.frame(0.25)

      expect(env.Finished:getStatus()).toBe("Started")

      scheduler.frame(0.25)

      expect(env.Finished:getStatus()).toBe("Resolved")
    end)

    test("a missing sdk_version is refused", function()
      fresh()

      expect(refusal(effect({ sdk_version = false :: any }))).toEqual({
        "sdk_version must be a whole number from 1, got false",
      })

      local author = effect()

      author.sdk_version = nil

      expect(refusal(author)).toEqual({ "it declares no sdk_version" })
    end)

    test("a newer sdk than this runtime knows is refused, naming both", function()
      fresh()

      expect(refusal(effect({ sdk_version = 2 }))).toEqual({
        "my_effect needs sdk 2, this VFX Forge supports up to 1, update the plugin or the emit module",
      })
    end)

    test("a module that answers no table is refused", function()
      expect(refusal(5)).toEqual({ "ReplicatedStorage.MyEffect answers a number, not an effect table" })
    end)

    test("every reason is named at once, a typo with the field it meant", function()
      fresh()

      local author = effect({ id = "my effect", display = {}, clasifier = "Part", emit = 1 })

      author.classifier = nil

      expect(refusal(author)).toEqual({
        "unknown field clasifier, did you mean classifier",
        "id must be a name of letters, digits and underscores",
        "display needs a name",
        "classifier must be a selector string",
        "emit must be a function",
      })
    end)

    test("a display category groups the effect, and any other value is refused with the reason", function()
      fresh()

      for _, category in load.CATEGORIES do
        local module =
          load.assemble(effect({ display = { name = "My Effect", category = category } }), "ReplicatedStorage.MyEffect")

        expect(module and module.display.category).toBe(category)
      end

      local reason = "display.category must be one of emitters, meshes, paths, shockwaves, camera, motion"

      expect(refusal(effect({ display = { name = "My Effect", category = "particles" } }))).toEqual({ reason })
      expect(refusal(effect({ display = { name = "My Effect", category = 3 } }))).toEqual({ reason })
      expect(refusal(effect({ display = { name = "My Effect", categry = "paths" } }))).toEqual({
        "unknown display field categry",
      })
    end)

    test("a display reflect of all or a list is carried, the list a frozen copy", function()
      fresh()

      local all =
        load.assemble(effect({ display = { name = "My Effect", reflect = "all" } }), "ReplicatedStorage.MyEffect")

      expect(all and all.display.reflect).toBe("all")

      local names = { "Color", "LightEmission" }
      local listed =
        load.assemble(effect({ display = { name = "My Effect", reflect = names } }), "ReplicatedStorage.MyEffect")
      local reflect = listed and listed.display.reflect

      expect(reflect).toEqual(names)
      expect(reflect == names).toBe(false)
      expect(table.isfrozen(reflect)).toBe(true)
      expect(table.isfrozen(names)).toBe(false)

      local none = load.assemble(effect(), "ReplicatedStorage.MyEffect")

      expect(none and none.display.reflect).toBe(nil)
    end)

    test("a display reflect that is neither all nor a list of names is refused with the reason", function()
      fresh()

      local reason = 'display.reflect must be "all" or a list of property names'

      for _, reflect in { "some", 3, {}, { "Color", 4 }, { "Color", "" } } :: { any } do
        expect(refusal(effect({ display = { name = "My Effect", reflect = reflect } }))).toEqual({ reason })
      end
    end)

    test("the category type names every category the loader takes", function()
      local source = fs.readFile("src/sdk/v1/types.luau")
      local union = string.match(source, "export type Category = ([^\n]+)") :: string
      local named = {}

      for name in string.gmatch(union, '"(%w+)"') do
        table.insert(named, name)
      end

      expect(named).toEqual(table.clone(load.CATEGORIES))
    end)

    test("params that throw, answer no table or hold no knobs are refused with the reason", function()
      fresh()

      local thrown = refusal(effect({
        params = function()
          error("bad params")
        end,
      }))

      expect(#thrown).toBe(1)
      expect(string.find(thrown[1], "params failed:", 1, true) ~= nil).toBe(true)
      expect(string.find(thrown[1], "bad params", 1, true) ~= nil).toBe(true)

      expect(refusal(effect({
        params = function()
          return 3
        end,
      }))).toEqual({ "params must answer a table, got number" })

      expect(refusal(effect({
        params = function(sdk: any)
          return { attributes = { A = 0, B = sdk.knob(5):max(2) }, rows = {} }
        end,
      }))).toEqual({
        "params answers rows, which is neither attributes nor properties",
      })

      expect(refusal(effect({
        params = function(sdk: any)
          return { attributes = { B = sdk.knob(5):max(2) } }
        end,
      }))).toEqual({ "the default of B lies outside its own bounds" })
    end)

    test("a param of a type the panel cannot edit is refused, naming the row", function()
      fresh()

      local allowed =
        "number, boolean, string, NumberRange, Vector2, Vector3, UDim, UDim2, Color3, NumberSequence, ColorSequence"

      expect(refusal(effect({
        params = function(sdk: any)
          return {
            attributes = {
              Offset = sdk.knob(CFrame.new()),
              Look = sdk.knob(Enum.Material.Plastic),
              Size = sdk.knob(1),
            },
            properties = {
              Material = sdk.knob(Enum.Material.Plastic),
              Pivot = sdk.knob(CFrame.new()),
            },
          }
        end,
      }))).toEqual({
        `attributes.Look is of type EnumItem, which the panel cannot edit; a param holds one of {allowed}, or a curve`,
        `attributes.Offset is of type CFrame, which the panel cannot edit; a param holds one of {allowed}, or a curve`,
        `properties.Pivot is of type CFrame, which the panel cannot edit; a param holds one of {allowed}, EnumItem, or a curve`,
      })
    end)

    test("every type the panel edits loads, a curve, a rule and a property's enum item among them", function()
      fresh()

      local ok, found = custom.add(
        "a",
        effect({
          params = function(sdk: any)
            return {
              attributes = {
                Count = sdk.knob(1),
                On = sdk.knob(true),
                Label = sdk.knob("a"),
                Range = sdk.knob(NumberRange.new(0, 1)),
                Flat = sdk.knob(Vector2.new(1, 2)),
                Point = sdk.knob(Vector3.new(1, 2, 3)),
                Pad = sdk.knob(UDim.new(0, 1)),
                Box = sdk.knob(UDim2.new(0, 1, 0, 1)),
                Tint = sdk.knob(Color3.new(1, 0, 0)),
                Fade = sdk.knob(NumberSequence.new(0)),
                Ramp = sdk.knob(ColorSequence.new(Color3.new(1, 1, 1))),
                FadeCurve = sdk.knob("easeOut"):curve("easeOut"),
                Twice = sdk.knob(function(_: any, attrs: any)
                  return attrs.Count * 2
                end),
              },
              properties = {
                Material = sdk.knob(Enum.Material.Plastic),
              },
            }
          end,
        }),
        "ReplicatedStorage.MyEffect"
      )

      expect(found).toEqual({})
      expect(ok).toBe(true)
    end)

    test("a classifier that could match another effect's instances is refused", function()
      fresh()
      builtins()

      expect(refusal(effect({ classifier = "Attachment" }))).toEqual({
        "classifier Attachment must name a class and a tag of its own, as in Attachment.MyEffect",
      })

      expect(refusal(effect({ classifier = "Attachment.BezierParticle" }))).toEqual({
        "classifier Attachment.BezierParticle shares the tag BezierParticle with bezier",
      })

      expect(refusal(effect({ classifier = "Instance.MyEffect" }))).toEqual({
        "classifier Instance.MyEffect: Instance is too broad a class for a custom effect, name a concrete class such as BasePart",
      })

      expect(refusal(effect({ classifier = "Folder.MyEffect, PVInstance.MyOther" }))).toEqual({
        "classifier Folder.MyEffect, PVInstance.MyOther: PVInstance is too broad a class for a custom effect, name a concrete class such as BasePart",
      })

      local module = load.assemble(effect({ classifier = "Attachment.MyEffect" }), "ReplicatedStorage.MyEffect")

      expect(module ~= nil).toBe(true)
    end)

    test("a classifier may name a class a built-in plays whole, as its tag is its own", function()
      fresh()
      builtins()
      registry.register(require("@vfx/particle"))

      for _, classifier in { "Beam.MyEffect", "ParticleEmitter.MyTag" } do
        local module, found = load.assemble(effect({ classifier = classifier }), "ReplicatedStorage.MyEffect")

        expect(found).toEqual({})
        expect(module ~= nil).toBe(true)
      end
    end)

    test("a class too broad to tell apart is refused even when no other effect is registered", function()
      fresh()

      expect(#registry.list()).toBe(0)
      expect(refusal(effect({ classifier = "Instance.MyEffect" }))).toEqual({
        "classifier Instance.MyEffect: Instance is too broad a class for a custom effect, name a concrete class such as BasePart",
      })
    end)

    test("a built-in's id is refused, and a second module claiming an id names the first", function()
      fresh()
      builtins()

      local ok, found = custom.add("a", effect({ id = "beam" }), "ReplicatedStorage.A")

      expect(ok).toBe(false)
      expect(found).toEqual({ "beam is a built-in effect's id" })

      expect((custom.add("a", effect(), "ReplicatedStorage.A"))).toBe(true)

      ok, found = custom.add("b", effect({ classifier = "Folder.Other" }), "ReplicatedStorage.B")

      expect(ok).toBe(false)
      expect(found).toEqual({ "the id my_effect is already claimed by ReplicatedStorage.A" })
      expect(registry.get("my_effect").classifier).toBe("Folder.MyEffect")
    end)

    test("the author's table is never changed or frozen", function()
      fresh()

      local author = effect({ layout = { { title = "Fade", entries = { "FadeTime" } } } })

      custom.add("a", author, "ReplicatedStorage.A")

      expect(table.isfrozen(author)).toBe(false)
      expect(table.isfrozen(author.display)).toBe(false)
      expect(table.isfrozen(author.layout)).toBe(false)
      expect(table.isfrozen(author.layout[1])).toBe(false)
      expect(author.attributes).toBe(nil)
      expect(registry.get("my_effect") ~= author).toBe(true)
    end)

    test("a curve param starts as its preset's curve", function()
      fresh()

      custom.add(
        "a",
        effect({
          params = function(sdk: any)
            return {
              attributes = {
                FadeCurve = sdk.knob("easeOut"):curve("easeOut"),
                InCurve = sdk.knob():curve("easeIn"),
              },
            }
          end,
        }),
        "ReplicatedStorage.A"
      )

      local attributes = registry.get("my_effect").attributes

      expect(attributes.FadeCurve.default).toBe(curves.PRESETS.easeOut)
      expect(attributes.InCurve.default).toBe(curves.PRESETS.easeIn)
    end)

    test("duration is asked through the facade, and becomes the ctx's", function()
      fresh()

      local seen

      custom.add(
        "a",
        effect({
          duration = function(sdk: any, attrs: any)
            expect(type(sdk.curve)).toBe("function")
            return attrs.FadeTime * 4
          end,
          emit = function(_, ctx: any)
            seen = ctx.duration
          end,
        }),
        "ReplicatedStorage.A"
      )

      effects.emit(0, tagged())

      expect(seen).toBe(2)
    end)
  end)

  harness.describe("the ctx a custom effect's rules are handed", function()
    test("a rule and emit of the same emit are handed one view, never the runtime's ctx", function()
      fresh()

      local views = {}

      custom.add(
        "a",
        effect({
          params = function(sdk: any)
            return {
              attributes = {
                FadeTime = sdk
                  .knob(function(ctx: any)
                    views.default = ctx
                    return 0.5
                  end)
                  :min(0),
                Locked = sdk.knob(1):readonly(function(ctx: any)
                  views.readonly = ctx
                  return false
                end),
                Rise = sdk.knob(0):mod(sdk.mod.to(1):duration(function(ctx: any)
                  views.mod = ctx
                  return 0.25
                end)),
              },
            }
          end,
          layout = {
            {
              title = "Fade",
              entries = { "FadeTime", "Locked", "Rise" },
              hidden = function(ctx: any)
                views.layout = ctx
                return false
              end,
            },
          },
          emit = function(sdk: any, ctx: any, attrs: any)
            views.emit = ctx
            sdk.wait(ctx, attrs.FadeTime)
          end,
        }),
        "ReplicatedStorage.A"
      )

      local folder = tagged()

      effects.emit(0, folder)

      expect(views.emit.ref).toBe(folder)
      expect(views.emit.scope).toBe(nil)
      expect(table.isfrozen(views.emit)).toBe(true)
      expect(views.default).toBe(views.emit)
      expect(views.readonly).toBe(views.emit)
      expect(views.mod).toBe(views.emit)

      -- the panel reads a module's rules over a ctx of its own
      local panel = { ref = folder, obj = folder }

      registry.get("my_effect").layout[1].hidden(panel, {}, {})

      expect(views.layout ~= panel).toBe(true)
      expect(views.layout.ref).toBe(folder)
      expect(table.isfrozen(views.layout)).toBe(true)
    end)

    test("a rule read while the duration is decided sees none, and emit sees the decided one", function()
      fresh()

      local during, seen

      custom.add(
        "a",
        effect({
          params = function(sdk: any)
            return {
              attributes = {
                FadeTime = sdk
                  .knob(function(ctx: any)
                    during = ctx
                    return 0.5
                  end)
                  :min(0),
              },
            }
          end,
          duration = function(_, attrs: any)
            return attrs.FadeTime * 4
          end,
          emit = function(_, ctx: any)
            seen = ctx
          end,
        }),
        "ReplicatedStorage.A"
      )

      effects.emit(0, tagged())

      expect(during.duration).toBe(nil)
      expect(seen.duration).toBe(2)
      expect(seen.scope).toBe(nil)
    end)
  end)

  harness.describe("classifying a custom effect's instance", function()
    test("a tagged part with Enabled set is the custom effect's, not screen's, in of and scan", function()
      fresh()
      registry.register(require("@vfx/screen"))

      local folder = harness.make("Folder", harness.make("Folder"))
      local part = harness.make("Part", folder)

      part:AddTag("MyEffect")
      part:SetAttribute("Enabled", true)

      expect(registry.of(part)).toBe(registry.get("screen"))
      expect((custom.add("a", effect({ classifier = "BasePart.MyEffect" }), "ReplicatedStorage.A"))).toBe(true)

      local mine = registry.get("my_effect")
      local hits = registry.scan(folder)

      expect(registry.of(part)).toBe(mine)
      expect(#hits).toBe(1)
      expect(hits[1].effect).toBe(mine)

      -- the order a list shows is the display order, custom effects last
      expect(registry.list()[2]).toBe(mine)

      custom.remove("a")

      expect(registry.of(part)).toBe(registry.get("screen"))
      expect(registry.scan(folder)[1].effect).toBe(registry.get("screen"))
    end)
  end)

  harness.describe("an effect's template", function()
    test("is handed the sdk alone when the host calls it, and answers what it made", function()
      fresh()

      local handed = {}
      local made = harness.make("Folder")

      local ok = custom.add(
        "a",
        effect({
          template = function(...: any)
            handed = table.pack(...)
            return made
          end,
        }),
        "ReplicatedStorage.MyEffect"
      )

      expect(ok).toBe(true)
      expect(registry.get("my_effect").template()).toBe(made)
      expect(handed.n).toBe(1)
      expect(handed[1]).toBe(load.VERSIONS[1].sdk)
    end)

    test("is never called by the runtime itself", function()
      fresh()

      local calls = 0

      local ok = custom.add(
        "a",
        effect({
          template = function()
            calls += 1
            return harness.make("Folder")
          end,
        }),
        "ReplicatedStorage.MyEffect"
      )

      expect(ok).toBe(true)

      local env = effects.emit(0, tagged())

      scheduler.frame(0.5)
      scheduler.frame(0.5)

      expect(env.Finished:getStatus()).toBe("Resolved")
      expect(calls).toBe(0)
    end)

    test("an effect without one loads as before, with none", function()
      fresh()

      custom.add("a", effect(), "ReplicatedStorage.MyEffect")

      expect(registry.get("my_effect").template).toBe(nil)
    end)

    test("one that is not a function is refused with the usual message", function()
      fresh()

      expect(refusal(effect({ template = "Part" }))).toEqual({ "template must be a function" })
    end)

    test("an engine function is refused, since the host would call it with its own rights", function()
      fresh()

      expect(refusal(effect({ template = print }))).toEqual({
        "template must be a function of your own, not an engine function",
      })
    end)

    test("a failure names the module's real path where it names the clone it ran as", function()
      fresh()

      local alias = "VFXForgeEffects.MyEffect_4"

      custom.add(
        "a",
        effect({
          template = function()
            error(`{alias}:7: template boom, then {alias}1:3`, 0)
          end,
        }),
        "ReplicatedStorage.MyEffect",
        alias
      )

      local ok, err = pcall(registry.get("my_effect").template)

      expect(ok).toBe(false)
      expect(err).toBe(`ReplicatedStorage.MyEffect:7: template boom, then {alias}1:3`)
    end)

    test("a failure that is no string is passed on as its text", function()
      fresh()

      custom.add(
        "a",
        effect({
          template = function()
            error({}, 0)
          end,
        }),
        "ReplicatedStorage.MyEffect",
        "VFXForgeEffects.MyEffect_4"
      )

      local ok, err = pcall(registry.get("my_effect").template)

      expect(ok).toBe(false)
      expect(type(err)).toBe("string")
      expect(string.find(err, "table: ", 1, true)).toBe(1)
    end)
  end)

  harness.describe("a failing custom effect's report", function()
    test("names the module's path where its error names the clone it ran as", function()
      fresh()

      local alias = "VFXForgeEffects.MyEffect_4"

      custom.add(
        "a",
        effect({
          emit = function()
            error(`{alias}:20: emit boom, then {alias}1:3`, 0)
          end,
        }),
        "ReplicatedStorage.MyEffect",
        alias
      )

      local warnings = harness.captureWarnings(function()
        effects.emit(0, tagged())
      end)

      expect(#warnings).toBe(1)
      expect(string.find(warnings[1], "ReplicatedStorage.MyEffect:20: emit boom", 1, true) ~= nil).toBe(true)

      -- another clone whose name only starts with this one's is left alone
      expect(string.find(warnings[1], `then {alias}1:3`, 1, true) ~= nil).toBe(true)
    end)

    test("is left as it was when the module ran under its own path", function()
      fresh()

      custom.add(
        "a",
        effect({
          emit = function()
            error("VFXForgeEffects.MyEffect_4:20: emit boom", 0)
          end,
        }),
        "ReplicatedStorage.MyEffect"
      )

      local warnings = harness.captureWarnings(function()
        effects.emit(0, tagged())
      end)

      expect(#warnings).toBe(1)
      expect(string.find(warnings[1], "VFXForgeEffects.MyEffect_4:20: emit boom", 1, true) ~= nil).toBe(true)
    end)
  end)

  harness.describe("what a host adds to a failure, and ending every custom effect", function()
    -- lune refuses churn(), so garbage is made until the
    -- collector has run a few whole cycles
    local function churn()
      for _ = 1, 40 do
        local junk = {}

        for i = 1, 50000 do
          junk[i] = { i }
        end
      end
    end
    local REFUSAL = "The current thread cannot call 'GetAsync' (lacking capability Network)"

    local function failing(id: string, message: string)
      return effect({
        id = id,
        classifier = `Folder.{id}`,
        emit = function()
          error(message)
        end,
      })
    end

    local function warned(id: string): string
      local folder = harness.make("Folder", harness.make("Folder"))

      folder:AddTag(id)

      local warnings = harness.captureWarnings(function()
        effects.emit(0, folder)
      end)

      expect(#warnings).toBe(1)

      return warnings[1]
    end

    test(
      "a host's sentence follows the error's first line once, and a failure it says nothing about is as it was",
      function()
        fresh()

        local asked = 0

        custom.annotate(function(message: string)
          asked += 1

          if string.find(message, "lacking capability Network", 1, true) then
            return "Turn Network on."
          end

          return nil
        end)

        custom.add("a", failing("net", REFUSAL), "ReplicatedStorage.Net")
        custom.add("b", failing("plain", "boom"), "ReplicatedStorage.Plain")

        local net = warned("net")
        local plain = warned("plain")

        custom.annotate(nil)

        local first = string.split(net, "\n")[1]

        expect(string.sub(first, -#`{REFUSAL}. Turn Network on.`)).toBe(`{REFUSAL}. Turn Network on.`)
        expect(select(2, string.gsub(net, "Turn Network on%.", ""))).toBe(1)
        expect(string.find(plain, "boom", 1, true) ~= nil).toBe(true)
        expect(string.find(plain, "Turn Network on", 1, true)).toBe(nil)
        expect(asked).toBe(2)
      end
    )

    test("with no host sentence set, a failure reads as the engine wrote it", function()
      fresh()

      custom.add("a", failing("net", REFUSAL), "ReplicatedStorage.Net")

      local net = warned("net")

      expect(string.find(net, REFUSAL, 1, true) ~= nil).toBe(true)
      expect(string.find(net, `{REFUSAL}.`, 1, true)).toBe(nil)
    end)

    test("a sentence that throws leaves the failure as it was", function()
      fresh()

      custom.annotate(function()
        error("sentence boom")
      end)

      custom.add("a", failing("net", REFUSAL), "ReplicatedStorage.Net")

      local net = warned("net")

      custom.annotate(nil)

      expect(string.find(net, REFUSAL, 1, true) ~= nil).toBe(true)
      expect(string.find(net, "sentence boom", 1, true)).toBe(nil)
    end)

    test("kill ends every custom effect still playing and puts back what it wrote, and leaves a built-in", function()
      fresh()
      registry.register({
        id = "waits",
        display = { name = "waits" },
        classifier = "Configuration",
        attributes = {},
        properties = {},
        emit = function(ctx: any)
          lifetime.wait(ctx.scope, 10)
        end,
      })

      custom.add(
        "a",
        effect({
          emit = function(sdk: any, ctx: any)
            sdk.getWriter(ctx, ctx.ref, "Name"):set("written")
            sdk.wait(ctx, 10)
          end,
        }),
        "ReplicatedStorage.A"
      )

      local folder = tagged()

      folder.Name = "authored"

      local mine = effects.emit(0, folder)
      local builtin = effects.emit(0, harness.make("Configuration", harness.make("Folder")))

      scheduler.frame(0.5)

      expect(folder.Name).toBe("written")

      custom.kill()

      expect(mine.Finished:getStatus()).toBe("Resolved")
      expect(folder.Name).toBe("authored")
      expect(builtin.Finished:getStatus()).toBe("Started")
      expect(registry.get("my_effect") ~= nil).toBe(true)

      builtin:Clear()
    end)

    test("an effect kept running by a hold alone is still found by kill after a collect", function()
      fresh()

      local cleaned = 0
      local view

      custom.add(
        "a",
        effect({
          emit = function(sdk: any, ctx: any)
            view = ctx

            sdk.hold(ctx, function()
              cleaned += 1
            end)

            sdk.wait(ctx, 10)
          end,
        }),
        "ReplicatedStorage.A"
      )

      local mine = effects.emit(0, tagged())

      scheduler.frame(0.1)
      churn()

      expect(mine.Finished:getStatus()).toBe("Started")
      expect((pcall(view.ref.GetFullName, view.ref))).toBe(true)

      custom.kill()

      expect(mine.Finished:getStatus()).toBe("Resolved")
      expect(cleaned).toBe(1)
    end)

    test("the facade lets a ctx go once its scope has ended", function()
      fresh()

      local probe = setmetatable({}, { __mode = "k" })

      registry.register({
        id = "probed",
        display = { name = "probed" },
        classifier = "Folder",
        attributes = {},
        properties = {},
        emit = function(ctx: any, attrs: any, props: any)
          probe[ctx] = true

          facade.run(function(sdk: any, view: any)
            sdk.hold(view, function() end)
            sdk.wait(view, 10)
          end, ctx, attrs, props)
        end,
      })

      local mine = effects.emit(0, harness.make("Folder", harness.make("Folder")))

      churn()

      expect(next(probe) ~= nil).toBe(true)

      mine:Clear()
      mine = nil
      scheduler.frame(0.5)
      churn()

      expect(next(probe)).toBe(nil)
    end)
  end)

  harness.describe("replacing and removing a custom effect", function()
    test("a new version under the same key replaces the old, whose unload runs once", function()
      fresh()

      local unloaded = 0
      local old = effect({
        unload = function()
          unloaded += 1
        end,
      })

      custom.add("a", old, "ReplicatedStorage.A")

      local playing = effects.emit(0, tagged())

      expect((custom.add("a", effect({ display = { name = "Second" } }), "ReplicatedStorage.A"))).toBe(true)
      expect(unloaded).toBe(1)
      expect(registry.get("my_effect").display.name).toBe("Second")
      expect(#registry.list()).toBe(1)

      -- the emit that started on the old version finishes on it
      scheduler.frame(0.5)

      expect(playing.Finished:getStatus()).toBe("Resolved")
    end)

    test("a refused version keeps the last good one, and unload is not called", function()
      fresh()

      local unloaded = 0

      custom.add(
        "a",
        effect({
          unload = function()
            unloaded += 1
          end,
        }),
        "ReplicatedStorage.A"
      )

      local first = registry.get("my_effect")
      local ok = custom.add("a", effect({ emit = 4 }), "ReplicatedStorage.A")

      expect(ok).toBe(false)
      expect(registry.get("my_effect")).toBe(first)
      expect(unloaded).toBe(0)
    end)

    test("a version refused or beaten to its id is unloaded, and the one registered is not", function()
      fresh()

      local unloaded = {}

      local function counted(name: string, extra: { [string]: any }?)
        local author = effect(extra)

        author.unload = function()
          table.insert(unloaded, name)
        end

        return author
      end

      local first = counted("first")

      custom.add("a", first, "ReplicatedStorage.A")

      expect((custom.add("a", counted("broken", { emit = 4 }), "ReplicatedStorage.A"))).toBe(false)
      expect((custom.add("b", counted("rival", { classifier = "Folder.Other" }), "ReplicatedStorage.B"))).toBe(false)

      -- a cached require answers the registered table itself
      expect((custom.add("b", first, "ReplicatedStorage.B"))).toBe(false)
      expect(unloaded).toEqual({ "broken", "rival" })
      expect(registry.get("my_effect").classifier).toBe("Folder.MyEffect")
    end)

    test("a refused version's unload that throws is warned with its path", function()
      fresh()

      local warnings = harness.captureWarnings(function()
        custom.add(
          "a",
          effect({
            emit = 4,
            unload = function()
              error("unload boom")
            end,
          }),
          "ReplicatedStorage.A"
        )
      end)

      expect(#warnings).toBe(1)
      expect(string.find(warnings[1], "ReplicatedStorage.A: unload failed", 1, true) ~= nil).toBe(true)
    end)

    test("a new version may change its id and classifier", function()
      fresh()

      custom.add("a", effect(), "ReplicatedStorage.A")

      expect((custom.add("a", effect({ id = "renamed" }), "ReplicatedStorage.A"))).toBe(true)
      expect(registry.get("my_effect")).toBe(nil)
      expect(registry.get("renamed") ~= nil).toBe(true)
    end)

    test("removing unregisters, calls unload and frees the id", function()
      fresh()

      local unloaded = 0

      custom.add(
        "a",
        effect({
          unload = function()
            unloaded += 1
          end,
        }),
        "ReplicatedStorage.A"
      )

      custom.remove("a")
      custom.remove("a")

      expect(registry.get("my_effect")).toBe(nil)
      expect(unloaded).toBe(1)
      expect((custom.add("b", effect(), "ReplicatedStorage.B"))).toBe(true)
    end)

    test("isCustom is true for a custom effect's module only while it is registered", function()
      fresh()
      builtins()

      custom.add("a", effect(), "ReplicatedStorage.A")

      local module = registry.get("my_effect")

      expect(registry.isCustom(module)).toBe(true)
      expect(registry.isCustom(registry.get("beam"))).toBe(false)

      custom.remove("a")

      expect(registry.isCustom(module)).toBe(false)
    end)

    test("an unload that throws is warned and the removal still happens", function()
      fresh()

      custom.add(
        "a",
        effect({
          unload = function()
            error("unload boom")
          end,
        }),
        "ReplicatedStorage.A"
      )

      local warnings = harness.captureWarnings(function()
        custom.remove("a")
      end)

      expect(registry.get("my_effect")).toBe(nil)
      expect(#warnings).toBe(1)
      expect(string.find(warnings[1], "ReplicatedStorage.A: unload failed", 1, true) ~= nil).toBe(true)
    end)
  end)
end)
