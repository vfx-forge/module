local curves = require("@mod/curves")
local harness = require("@tests/harness")
local effects = require("@srv/effects")
local registry = require("@mod/registry")
local scheduler = require("@mod/scheduler")
local test, expect = harness.test, harness.expect

local load = require("@root/sdk/load")
local custom = require("@root/sdk/custom")

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

    test("a classifier that could match another effect's instances is refused", function()
      fresh()
      builtins()

      expect(refusal(effect({ classifier = "Attachment" }))).toEqual({
        "classifier Attachment must name a class and a tag of its own, as in Attachment.MyEffect",
      })

      expect(refusal(effect({ classifier = "Attachment.BezierParticle" }))).toEqual({
        "classifier Attachment.BezierParticle shares the tag BezierParticle with bezier",
      })

      expect(refusal(effect({ classifier = "Beam.MyEffect" }))).toEqual({
        "classifier Beam.MyEffect overlaps beam, which plays every Beam",
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
