const rng = require("@mod/lightning/rng")
const timeline = require("@mod/lightning/timeline")
const harness = require("@tests/harness")
const describe, test, expect = harness.describe, harness.test, harness.expect

const function linear(a: number): number
  return a
end

const function plan(appear: string, disappear: string, restrikes: number?)
  return timeline.plan(rng.generator(987654321), {
    appear = appear,
    appearTime = { Min = 0.4, Max = 0.4 },
    hold = { Min = 1, Max = 1 },
    restrikes = restrikes or 0,
    disappear = disappear,
    disappearTime = 0.5,
  })
end

const function near(a: number, b: number): boolean
  return math.abs(a - b) < 1e-6
end

harness.suite(function()
  describe("timeline", function()
    test("Instant is whole at once", function()
      const state = timeline.at(plan("Instant", "Thin"), 0, linear, linear)

      expect(state.head).toBe(1)
      expect(state.width).toBe(1)
      expect(state.glow).toBe(1)
      expect(state.opacity).toBe(1)
    end)

    test("Grow runs the head over appearTime", function()
      const p = plan("Grow", "Thin")

      expect(timeline.at(p, 0, linear, linear).head).toBe(0)
      expect(near(timeline.at(p, p.appearTime / 2, linear, linear).head, 0.5)).toBe(true)
      expect(timeline.at(p, p.appearTime, linear, linear).head).toBe(1)
      expect(timeline.at(p, p.appearTime / 2, linear, linear).width).toBe(1)
    end)

    test("Strike grows a faint leader then flashes", function()
      const p = plan("Strike", "Thin")
      const leader = timeline.at(p, p.appearTime / 2, linear, linear)
      const hit = timeline.at(p, p.appearTime + 0.001, linear, linear)
      const later = timeline.at(p, p.appearTime + 0.5, linear, linear)

      expect(leader.width).toBe(timeline.LEADER_WIDTH)
      expect(leader.glow).toBe(timeline.LEADER_GLOW)
      expect(leader.opacity).toBe(1)
      expect(hit.width).toBe(1)
      expect(hit.glow).toBe(1)
      expect(hit.flash > 0.99).toBe(true)
      expect(later.flash < hit.flash).toBe(true)
    end)

    test("restrikes are spread through the hold", function()
      const p = plan("Instant", "Thin", 3)
      local increasing = true
      local inside = true

      expect(#p.strikes).toBe(4)
      expect(p.strikes[1]).toBe(0)

      for i = 2, #p.strikes do
        if p.strikes[i] <= p.strikes[i - 1] then
          increasing = false
        end

        if p.strikes[i] <= p.appearTime or p.strikes[i] >= p.appearTime + p.hold then
          inside = false
        end
      end

      expect(increasing).toBe(true)
      expect(inside).toBe(true)
    end)

    test("a restrike blinks once for BLINK seconds", function()
      const p = plan("Instant", "Thin", 2)
      const s = p.strikes[2]

      expect(timeline.at(p, s - 0.001, linear, linear).strike).toBe(1)
      expect(timeline.at(p, s - 0.001, linear, linear).visible).toBe(true)

      const dark = timeline.at(p, s + timeline.BLINK / 2, linear, linear)

      expect(dark.visible).toBe(false)
      expect(dark.strike).toBe(2)

      const back = timeline.at(p, s + timeline.BLINK + 0.001, linear, linear)

      expect(back.visible).toBe(true)
      expect(back.strike).toBe(2)
      expect(back.head).toBe(1)
    end)

    test("a restrike's flash peaks once its blink is over", function()
      const p = plan("Strike", "Thin", 2)
      const back = timeline.at(p, p.strikes[2] + timeline.BLINK + 0.001, linear, linear)

      expect(back.visible).toBe(true)
      expect(back.flash > 0.99).toBe(true)
    end)

    test("Thin takes the width to 0 at full opacity", function()
      const p = plan("Instant", "Thin")
      const start = p.appearTime + p.hold
      const mid = timeline.at(p, start + p.disappearTime / 2, linear, linear)
      const done = timeline.at(p, start + p.disappearTime, linear, linear)

      expect(near(mid.width, 0.5)).toBe(true)
      expect(mid.opacity).toBe(1)
      expect(done.width).toBe(0)
      expect(done.opacity).toBe(1)
    end)

    test("a Strike leader carries the leader glow and width, and the flash restores both", function()
      const p = plan("Strike", "Thin")
      const leader = timeline.at(p, p.appearTime / 2, linear, linear)
      const after = timeline.at(p, p.appearTime + 0.001, linear, linear)

      expect(leader.glow).toBe(timeline.LEADER_GLOW)
      expect(leader.width).toBe(timeline.LEADER_WIDTH)
      expect(after.glow).toBe(1)
      expect(after.width).toBe(1)
    end)

    test("Fade keeps the full width while opacity falls from 1 to 0", function()
      const p = plan("Instant", "Fade")
      const start = p.appearTime + p.hold
      local last = 1

      expect(timeline.at(p, start, linear, linear).opacity).toBe(1)

      for i = 0, 50 do
        const s = timeline.at(p, start + p.disappearTime * i / 50, linear, linear)

        expect(s.width).toBe(1)
        expect(s.glow).toBe(1)
        expect(s.opacity <= last).toBe(true)

        last = s.opacity
      end

      expect(near(timeline.at(p, start + p.disappearTime / 2, linear, linear).opacity, 0.5)).toBe(true)
      expect(timeline.at(p, start + p.disappearTime, linear, linear).opacity).toBe(0)
    end)

    test("Retract and Recoil move the tail and head only", function()
      for _, out in { "Retract", "Recoil" } do
        const p = plan("Instant", out)
        const mid = timeline.at(p, p.appearTime + p.hold + p.disappearTime / 2, linear, linear)

        expect(mid.width).toBe(1)
        expect(mid.opacity).toBe(1)
        expect(mid.glow).toBe(1)
      end
    end)

    test("the flash falls with the disappear in every mode", function()
      for _, out in { "Thin", "Fade", "Retract", "Recoil" } do
        const p = plan("Strike", out)
        const start = p.appearTime + p.hold
        const before = timeline.at(p, start, linear, linear).flash
        const mid = timeline.at(p, start + p.disappearTime / 2, linear, linear).flash

        expect(mid < before).toBe(true)
        expect(near(timeline.at(p, start + p.disappearTime, linear, linear).flash, 0)).toBe(true)
      end
    end)

    test("Retract lifts the tail off the origin", function()
      const p = plan("Instant", "Retract")
      const start = p.appearTime + p.hold
      const mid = timeline.at(p, start + p.disappearTime / 2, linear, linear)

      expect(timeline.at(p, start, linear, linear).tail).toBe(0)
      expect(near(mid.tail, 0.5)).toBe(true)
      expect(mid.head).toBe(1)
      expect(timeline.at(p, start + p.disappearTime, linear, linear).tail).toBe(1)
    end)

    test("Recoil draws the head back to the origin", function()
      const p = plan("Instant", "Recoil")
      const start = p.appearTime + p.hold
      const mid = timeline.at(p, start + p.disappearTime / 2, linear, linear)

      expect(timeline.at(p, start, linear, linear).head).toBe(1)
      expect(near(mid.head, 0.5)).toBe(true)
      expect(mid.tail).toBe(0)
      expect(timeline.at(p, start + p.disappearTime, linear, linear).head).toBe(0)
    end)

    test("Thin and Fade hold a curve that overshoots", function()
      const function over(a: number): number
        return a * 1.5 - 0.25
      end

      local inside = true

      for _, out in { "Thin", "Fade" } do
        const p = plan("Instant", out)

        for i = 0, 100 do
          const s = timeline.at(p, p.total * i / 100, linear, over)

          for _, v in { s.width, s.glow, s.opacity, s.flash } do
            if v < 0 or v > 1 then
              inside = false
            end
          end
        end
      end

      expect(inside).toBe(true)
    end)

    test("past the end is invisible", function()
      const p = plan("Strike", "Thin", 1)

      expect(timeline.at(p, p.total + 1, linear, linear).visible).toBe(false)
      expect(timeline.at(p, -1, linear, linear).visible).toBe(false)
    end)

    test("zero times stay finite", function()
      const p = timeline.plan(rng.generator(987654321), {
        appear = "Strike",
        appearTime = { Min = 0, Max = 0 },
        hold = { Min = 0, Max = 0 },
        restrikes = 2,
        disappear = "Fade",
        disappearTime = 0,
      })
      local finite = true

      for _, mode in { "Instant", "Grow", "Strike" } do
        for _, out in { "Thin", "Fade", "Retract", "Recoil" } do
          const q = timeline.plan(rng.generator(987654321), {
            appear = mode,
            appearTime = { Min = 0, Max = 0 },
            hold = { Min = 0, Max = 0 },
            restrikes = 2,
            disappear = out,
            disappearTime = 0,
          })

          for _, t in { -1, 0, 0.001, 0.04, 1 } do
            const s = timeline.at(q, t, linear, linear)

            for _, v in { s.head, s.tail, s.width, s.glow, s.opacity, s.flash } do
              if v ~= v or v == math.huge or v == -math.huge then
                finite = false
              end
            end
          end
        end
      end

      expect(finite).toBe(true)
      expect(p.total).toBe(0)
    end)

    test("a zero hold has no restrikes", function()
      const p = timeline.plan(rng.generator(987654321), {
        appear = "Instant",
        appearTime = { Min = 0.4, Max = 0.4 },
        hold = { Min = 0, Max = 0 },
        restrikes = 3,
        disappear = "Thin",
        disappearTime = 0.5,
      })
      local calm = true

      expect(#p.strikes).toBe(1)

      for i = 0, math.floor(p.total * 1000) do
        const s = timeline.at(p, i / 1000, linear, linear)

        if s.strike ~= 1 or not s.visible then
          calm = false
        end
      end

      expect(calm).toBe(true)
    end)

    test("a short hold fits fewer restrikes", function()
      const function with(hold: number)
        return timeline.plan(rng.generator(987654321), {
          appear = "Instant",
          appearTime = { Min = 0.4, Max = 0.4 },
          hold = { Min = hold, Max = hold },
          restrikes = 5,
          disappear = "Thin",
          disappearTime = 0.5,
        })
      end

      expect(#with(0.1).strikes - 1).toBe(0)

      const p = with(0.5)
      local fits = true

      expect(#p.strikes - 1 <= math.floor(0.5 / 0.08) - 1).toBe(true)

      for i = 2, #p.strikes do
        if i > 2 and p.strikes[i] <= p.strikes[i - 1] then
          fits = false
        end

        if p.strikes[i] + timeline.BLINK >= p.appearTime + p.hold then
          fits = false
        end
      end

      expect(fits).toBe(true)
    end)

    test("a restrike increments strike once", function()
      const p = plan("Instant", "Thin", 1)
      const s = p.strikes[2]
      const seen = {}
      local dark = 0

      for i = 1, 1000 do
        const t = s - 0.5 + i / 1000
        const state = timeline.at(p, t, linear, linear)

        if seen[#seen] ~= state.strike then
          table.insert(seen, state.strike)
        end

        if not state.visible then
          dark += 1
        end
      end

      expect(#seen).toBe(2)
      expect(seen[1]).toBe(1)
      expect(seen[2]).toBe(2)
      expect(math.abs(dark - timeline.BLINK * 1000) <= 1).toBe(true)
    end)

    test("duration uses the maxima", function()
      const total = timeline.duration({
        appear = "Strike",
        appearTime = { Min = 0.06, Max = 0.1 },
        hold = { Min = 0.2, Max = 0.3 },
        restrikes = 1,
        disappear = "Thin",
        disappearTime = 0.25,
      })

      expect(near(total, 0.65)).toBe(true)
    end)

    test("a forced disappear start holds the bolt until then and keeps its restrikes in its own hold", function()
      const rows = {
        appear = "Strike",
        appearTime = { Min = 0.06, Max = 0.1 },
        hold = { Min = 0.2, Max = 0.3 },
        restrikes = 2,
        disappear = "Fade",
        disappearTime = 0.5,
      }
      const own = timeline.plan(rng.generator(4242), rows)
      const forced = timeline.plan(rng.generator(4242), rows, 0.9)
      const sooner = timeline.plan(rng.generator(4242), rows, 0.01)
      const ownEnd = own.appearTime + own.hold

      expect(own.still).toBe(ownEnd)
      expect(forced.appearTime).toBe(own.appearTime)
      expect(near(forced.appearTime + forced.hold, 0.9)).toBe(true)
      expect(near(forced.total, 1.4)).toBe(true)
      expect(forced.still).toBe(ownEnd)
      expect(near(forced.wait, 0.9 - ownEnd)).toBe(true)
      expect(own.wait).toBe(0)
      expect(forced.strikes).toEqual(own.strikes)
      expect(sooner.hold).toBe(own.hold)

      const held = timeline.at(forced, (ownEnd + 0.9) / 2, linear, linear)
      const going = timeline.at(forced, 1.15, linear, linear)

      expect(held.visible and held.opacity == 1 and held.strike == #own.strikes).toBe(true)
      expect(near(going.opacity, 0.5)).toBe(true)
    end)

    test("a bolt with no forced start never waits, so it moves through its whole disappear", function()
      local waited = false
      local shifted = false

      for seed = 1, 20 do
        const own = timeline.plan(rng.generator(seed * 31 + 5), {
          appear = "Strike",
          appearTime = { Min = 0.06, Max = 0.1 },
          hold = { Min = 0.2, Max = 0.3 },
          restrikes = 1,
          disappear = "Thin",
          disappearTime = 0.25,
        })

        for step = 0, 100 do
          const t = own.total * step / 100

          if timeline.waiting(own, t) then
            waited = true
          end

          if timeline.moving(own, t) ~= t then
            shifted = true
          end
        end
      end

      expect(waited).toBe(false)
      expect(shifted).toBe(false)
    end)

    test(
      "a bolt with a forced start keeps its shape only while it waits, and moves on from where it stopped",
      function()
        const forced = timeline.plan(rng.generator(4242), {
          appear = "Instant",
          appearTime = { Min = 0, Max = 0 },
          hold = { Min = 0.2, Max = 0.2 },
          restrikes = 0,
          disappear = "Fade",
          disappearTime = 0.5,
        }, 0.6)

        expect(near(forced.still, 0.2)).toBe(true)
        expect(near(forced.wait, 0.4)).toBe(true)
        expect(timeline.waiting(forced, 0.19)).toBe(false)
        expect(timeline.waiting(forced, 0.2)).toBe(true)
        expect(timeline.waiting(forced, 0.59)).toBe(true)
        expect(timeline.waiting(forced, 0.6)).toBe(false)
        expect(timeline.waiting(forced, 0.9)).toBe(false)
        expect(near(timeline.moving(forced, 0.1), 0.1)).toBe(true)
        expect(near(timeline.moving(forced, 0.4), 0.2)).toBe(true)
        expect(near(timeline.moving(forced, 0.6), 0.2)).toBe(true)
        expect(near(timeline.moving(forced, 0.75), 0.35)).toBe(true)
      end
    )

    test("a covered bolt stays opaque until its Highlight has lifted away", function()
      local opaqueUnder = true
      local last = { 1, 1 }
      local continuous = true

      for step = 1000, 0, -1 do
        const shade, core = timeline.cover(step / 1000)

        if shade > 0 and core < 1 then
          opaqueUnder = false
        end

        if math.abs(shade - last[1]) > 0.0021 or math.abs(core - last[2]) > 0.0021 then
          continuous = false
        end

        last = { shade, core }
      end

      expect(opaqueUnder).toBe(true)
      expect(continuous).toBe(true)
      expect({ timeline.cover(1) }).toEqual({ 1, 1 })
      expect({ timeline.cover(0.5) }).toEqual({ 0, 1 })
      expect({ timeline.cover(0) }).toEqual({ 0, 0 })
    end)

    test("a continuous bolt holds until it is let go, then disappears from there", function()
      const p = plan("Instant", "Thin")

      timeline.stay(p)

      expect(timeline.staying(p)).toBe(true)
      expect(timeline.at(p, 1000, linear, linear).width).toBe(1)
      expect(timeline.moving(p, 1000)).toBe(1000)

      timeline.release(p, 5)

      expect(timeline.staying(p)).toBe(false)
      expect(near(p.total, 5 + p.disappearTime)).toBe(true)
      expect(near(timeline.at(p, 5 + p.disappearTime / 2, linear, linear).width, 0.5)).toBe(true)
      expect(timeline.at(p, p.total + 0.01, linear, linear).visible).toBe(false)
    end)

    test("a continuous bolt let go while it appears still finishes appearing first", function()
      const p = plan("Grow", "Thin")

      timeline.stay(p)
      timeline.release(p, p.appearTime / 2)

      expect(p.hold).toBe(0)
      expect(near(p.total, p.appearTime + p.disappearTime)).toBe(true)
    end)
  end)
end)
