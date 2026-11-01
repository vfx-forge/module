local curve = require("@mod/curve")
local tween = require("@mod/tween")
local curves = require("@mod/curves")
local harness = require("@tests/harness")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local test = harness.test

-- the tween as it stood before the core, dev 213759c, for the cost gate
local before = require("@tests/fixtures/tween_213759c")

harness.suite(function()
  harness.describe("the tween's cost", function()
    local COUNT = 200
    local FRAMES = 60
    local ROUNDS = 5

    -- COUNT tweens of one eased row stepped FRAMES frames, in seconds
    local function timed(start: (fx: lifetime.effect, sink: (alpha: number) -> ()) -> ()): number
      local emit = lifetime.emit(nil)
      local fx = lifetime.effect(emit, 0, nil)
      local total = 0

      local function sink(alpha: number)
        total += alpha
      end

      for _ = 1, COUNT do
        start(fx, sink)
      end

      local started = os.clock()

      for _ = 1, FRAMES do
        scheduler.frame(1 / 60)
      end

      local spent = os.clock() - started

      lifetime.clear(emit)

      return spent
    end

    -- the old stepper as Studio ran it: its 64 step table, read off the
    -- fixture, where lune itself fell back to the slower Newton solve
    test("a playing tween is timed against fromParams", function()
      local eased = curves.default()
      local fastestNew, fastestOld = math.huge, math.huge

      for _ = 1, ROUNDS do
        fastestOld = math.min(
          fastestOld,
          timed(function(fx: lifetime.effect, sink: (alpha: number) -> ())
            lifetime.hold(
              fx,
              before.fromParams(eased, 100, function(alpha: number, deltaTime: number)
                sink(alpha)
                return deltaTime
              end)
            )
          end)
        )

        fastestNew = math.min(
          fastestNew,
          timed(function(fx: lifetime.effect, sink: (alpha: number) -> ())
            tween.play(fx, curve.new(100, eased), function(alpha: number)
              sink(alpha)
            end)
          end)
        )
      end

      print(
        `  tween a frame: play {string.format("%.1f", fastestNew / COUNT / FRAMES * 1e9)} ns, fromParams {string.format(
          "%.1f",
          fastestOld / COUNT / FRAMES * 1e9
        )} ns`
      )
    end)
  end)
end)
