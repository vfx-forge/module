const kinds = require("@mod/lightning/kinds")
const harness = require("@tests/harness")
const describe, test, expect = harness.describe, harness.test, harness.expect

harness.suite(function()
  describe("kinds", function()
    test("a Bolt child is sorted by its class", function()
      expect(kinds.bolt("Highlight")).toBe("highlight")
      expect(kinds.bolt("PointLight")).toBe("light")
      expect(kinds.bolt("SpotLight")).toBe("light")
      expect(kinds.bolt("Beam")).toBe("beam")
      expect(kinds.bolt("ParticleEmitter")).toBe("emitter")
      expect(kinds.bolt("Trail")).toBe("trail")
    end)

    test("what Bolt cannot drive is refused", function()
      for _, class in { "Shockwave", "Sound", "Model", "Attachment" } do
        expect(kinds.bolt(class)).toBe("refused")
      end
    end)

    test("one sort of Bolt answers its Highlight, what rides and what it refuses", function()
      const shine = { ClassName = "Highlight", Archivable = true }
      const beam = { ClassName = "Beam", Archivable = true }
      const emitter = { ClassName = "ParticleEmitter", Archivable = true }
      const light = { ClassName = "SpotLight", Archivable = true }
      const trail = { ClassName = "Trail", Archivable = true }
      const sorted = kinds.sort({ shine, beam, emitter, light, trail })

      expect(sorted.highlight).toBe(shine)
      expect(sorted.beam[1]).toBe(beam)
      expect(sorted.emitter[1]).toBe(emitter)
      expect(sorted.light[1]).toBe(light)
      expect(sorted.trail[1]).toBe(trail)
      expect(sorted.found).toBe(4)
      expect(sorted.refused).toBe(false)
      expect(sorted.extra).toBe(false)
    end)

    test("the sort keeps the first Highlight and flags a second and a refused child", function()
      const first = { ClassName = "Highlight", Archivable = true }
      const sorted = kinds.sort({
        first,
        { ClassName = "Highlight", Archivable = true },
        { ClassName = "Sound", Archivable = true },
      })

      expect(sorted.highlight).toBe(first)
      expect(sorted.extra).toBe(true)
      expect(sorted.refused).toBe(true)
      expect(sorted.found).toBe(0)
    end)

    test("a child that is not Archivable is never driven and is flagged apart from a refused one", function()
      const sorted = kinds.sort({
        { ClassName = "Highlight", Archivable = false },
        { ClassName = "Beam", Archivable = false },
      })

      expect(sorted.highlight).toBe(nil)
      expect(#sorted.beam).toBe(0)
      expect(sorted.found).toBe(0)
      expect(sorted.locked).toBe(true)
      expect(sorted.refused).toBe(false)
    end)

    test("a refused class is refused whether or not it is Archivable", function()
      const sorted = kinds.sort({ { ClassName = "Sound", Archivable = false } })

      expect(sorted.refused).toBe(true)
      expect(sorted.locked).toBe(false)
    end)

    test("an empty Bolt sorts to nothing", function()
      const sorted = kinds.sort({})

      expect(sorted.highlight).toBe(nil)
      expect(sorted.found).toBe(0)
      expect(sorted.refused).toBe(false)
      expect(sorted.locked).toBe(false)
    end)

    test("EmitAlong sorts particles from the rest and leaves out what is not Archivable", function()
      const emitter = { ClassName = "ParticleEmitter", Archivable = true }
      const sound = { ClassName = "Sound", Archivable = true }
      const sorted = kinds.sortAlong({
        emitter,
        sound,
        { ClassName = "ParticleEmitter", Archivable = false },
        { ClassName = "Attachment", Archivable = false },
      })

      expect(#sorted.emitter).toBe(1)
      expect(sorted.emitter[1]).toBe(emitter)
      expect(#sorted.strike).toBe(1)
      expect(sorted.strike[1]).toBe(sound)
      expect(sorted.locked).toBe(true)
      expect(kinds.sortAlong({ emitter }).locked).toBe(false)
    end)

    test("EmitAlong re-emits only particles", function()
      expect(kinds.along("ParticleEmitter")).toBe("emitter")

      for _, class in { "Shockwave", "Sound", "Model", "Attachment" } do
        expect(kinds.along(class)).toBe("strike")
      end
    end)
  end)
end)
