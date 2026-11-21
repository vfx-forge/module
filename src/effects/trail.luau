const knob = require("@mod/knob")
const lazy = require("@mod/lazy")
const reader = require("@mod/reader")
const adapters = require("@mod/adapters")
const flipbook_rows = require("@mod/common/flipbook_rows")

-- the clock every effect with none of its own runs its queues over, which a
-- trail left on keeps, since it has no end
const OPEN_DURATION = 1

const trail = {}

const play = lazy.unit("trail", function()
  return require("@root/play/trail")
end)

trail.id = "trail"
trail.display = { name = "Trail", icon = "trail", order = 75 }
trail.classifier = "Trail"

trail.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
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

function trail.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

return trail
