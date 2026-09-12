local numeric = require("@mod/common/numeric")

local timing = {}

-- a duration that cannot be run is run as zero, which lands a tween on its end
-- value on its first frame instead of dividing by it
function timing.duration(d: number): number
  if not numeric.finite(d) or d < 0 then
    return 0
  end

  return d
end

function timing.progress(elapsed: number, duration: number): number
  if duration <= 0 then
    return 1
  end

  return math.clamp(elapsed / duration, 0, 1)
end

-- roblox tweens do not report their first frame as finished, so a zero
-- duration is done only once some time has been counted against it
function timing.done(elapsed: number, duration: number): boolean
  if duration > 0 then
    return elapsed >= duration
  end

  return elapsed > duration
end

return timing
