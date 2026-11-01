local curve = require("@mod/curve")
local tween = require("@mod/tween")
local lifetime = require("@mod/lifetime")
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

return flipbook_loop
