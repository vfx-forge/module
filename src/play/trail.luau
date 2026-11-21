const reader = require("@mod/reader")
const lifetime = require("@mod/lifetime")
const flipbook_rows = require("@mod/common/flipbook_rows")

local play = {}

function play.emit(ctx: reader.Ctx, attrs: any)
  const ref = ctx.ref :: Trail
  const scope = ctx.scope
  const span = ctx.duration :: number
  const window = attrs.EmitDuration

  -- a trail with a window draws only inside one, and one below 0 never
  -- draws, so either switches one left on off; one another emit's window
  -- holds is that window's to switch off
  if window ~= 0 and ref.Enabled and lifetime.writing(ref, "property", "Enabled") == 0 then
    ref.Enabled = false
  end

  lifetime.wait(scope, attrs.EmitDelay)

  -- a window holds the trail on, and the last window to close lets it go
  const enabled = if window > 0 then lifetime.write(scope, ref, "property", "Enabled") else nil

  if enabled ~= nil then
    lifetime.set(enabled, true)
  elseif window == 0 then
    ref.Enabled = true
  end

  -- the trail plays in place, so its frames give the authored texture back
  -- once the effect ends
  const texture = lifetime.write(scope, ref, "property", "Texture")

  const frames = flipbook_rows.play(scope, ref, attrs, span, function(id: string)
    lifetime.set(texture, id)
  end)

  if enabled == nil then
    lifetime.wait(scope, frames)
    return
  end

  lifetime.wait(scope, window)
  lifetime.leave(enabled)
  lifetime.wait(scope, math.max(span, frames) - window)
end

return play
