const knob = require("@mod/knob")
const reader = require("@mod/reader")
const adapters = require("@mod/adapters")
const lifetime = require("@mod/lifetime")
const flipbook_rows = require("@mod/common/flipbook_rows")

-- the clock every effect with none of its own runs its queues over, which a
-- trail left on keeps, since it has no end
const OPEN_DURATION = 1

const trail = {}

trail.id = "trail"
trail.display = { name = "Trail", icon = "trail", order = 75 }
trail.classifier = "Trail"

trail.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):ranged():label("Delay"):hint("Seconds before the effect starts emitting."),
  -- 0 is what an emit did before trails had a window, and stays the default
  -- so every trail saved then plays as it did, a nested one switched on by
  -- its parent's emit included
  EmitDuration = knob(0)
    :min(-1)
    :unit("seconds")
    :label("Duration")
    :hint("Seconds the trail stays on. 0 leaves it on, below 0 turns it off."),
}

for name, row in flipbook_rows.rows() do
  trail.attributes[name] = row
end

trail.properties = {}

trail.layout = {
  { title = "Emit", entries = { "EmitDelay", "EmitDuration" } },
  {
    title = "Behavior",
    entries = {
      { action = "spin_trail", label = "Spin Trail" },
      { action = "toggle_textures", label = "Load Textures" },
    },
  },
}

-- the flipbook's card, which the plugin shows once the trail has frames
trail.cards = {
  Flipbook = flipbook_rows.card(),
}

-- how long what the trail drew takes to fade, as authored even while a queue
-- of another emit writes its Lifetime
const function fadeOf(ref: Trail): number
  const authored = adapters.authoredOf(ref, "Lifetime")

  return if type(authored) == "number" then authored else ref.Lifetime
end

-- the window the trail is on, then what it drew fading over its Lifetime
function trail.duration(ctx: reader.Ctx, attrs: any)
  const window = attrs.EmitDuration

  if window <= 0 then
    return OPEN_DURATION
  end

  return window + fadeOf(ctx.ref :: Trail)
end

function trail.emit(ctx: reader.Ctx, attrs: any)
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

return trail
