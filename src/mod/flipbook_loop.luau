local curve = require("@mod/curve")
local tween = require("@mod/tween")
local lifetime = require("@mod/lifetime")
local scheduler = require("@mod/scheduler")
local flipbook_common = require("@mod/common/flipbook")

local flipbook_loop = {}

-- a flipbook's cycles played for `span` seconds of the effect's clock, each
-- eased by `shape`. the alpha `write` is handed is read off the time played
-- rather than chained cycle to cycle, so a long loop never drifts
function flipbook_loop.play(
  scope: lifetime.effect,
  shape: any,
  cycle: number,
  cycles: number,
  span: number,
  write: (alpha: number) -> ()
)
  const eased = curve.new(1, shape)

  tween.play(scope, curve.new(span, "linear"), function(_, _, elapsed: number)
    write(eased:at(flipbook_common.phase(elapsed, cycle, cycles)))
  end)
end

-- an endless loop's cycles played on the effect's clock until the stop it
-- answers is called, then to the end of the cycle playing then. `write` is
-- handed the time played and how many cycles play, 0 until the stop, and
-- `done` is called once the last ends or the clock halts for good
function flipbook_loop.endless(
  scope: lifetime.effect,
  cycle: number,
  write: (elapsed: number, cycles: number) -> (),
  done: () -> ()
): () -> ()
  local elapsed = 0
  local cycles = 0
  local handle: scheduler.Handle

  write(0, 0)

  handle = lifetime.step(scope, function(deltaTime: number)
    elapsed += deltaTime
    write(elapsed, cycles)

    if (cycles > 0 and elapsed >= cycles * cycle) or scope.clock.halted then
      handle:Disconnect()
      done()
    end
  end)

  return function()
    if cycles == 0 then
      cycles = flipbook_common.stopped(elapsed, cycle)
    end
  end
end

return flipbook_loop
