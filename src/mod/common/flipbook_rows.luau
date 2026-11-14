const knob = require("@mod/knob")
const curve = require("@mod/curve")
const tween = require("@mod/tween")
const curves = require("@mod/curves")
const lifetime = require("@mod/lifetime")
const flipbook_loop = require("@mod/flipbook_loop")
const flipbook_common = require("@mod/common/flipbook")

const function linear()
  return curves.linear()
end

const function noLoop(_, attrs: any)
  return not attrs.FlipbookLoop
end

const common = {}

-- the rows of a flipbook an effect plays over its own texture, made afresh
-- for each effect that has them. a cycle nothing authors runs over the
-- effect's own duration, which the reader has decided by the time a row
-- resolves
function common.rows()
  return {
    FlipbookChangeDuration = knob(function(ctx)
        return ctx.duration
      end)
      :aliases("Flipbook_Change_Duration")
      :unit("seconds")
      :label("Duration")
      :hint("Seconds for one full flipbook cycle."),
    FlipbookChangeCurve = knob(linear)
      :aliases("Flipbook_Change_Curve")
      :label("Curve")
      :hint("Easing of one flipbook cycle."),
    SyncDuration = knob(false):label("SyncDuration"):hint("Play the flipbook's cycles over the effect duration."),
    FlipbookLoop = knob(false):label("Loop"):hint("Repeat the flipbook cycle."),
    FlipbookLoopCount = knob(0)
      :min(0)
      :hidden(noLoop)
      :label("LoopCount")
      :hint("Cycles to play, 0 repeating until the effect ends."),
  }
end

-- the card those rows sit on, which the plugin shows once the effect has
-- frames
function common.card()
  return {
    {
      title = "Cycle",
      entries = {
        { curve = "FlipbookChangeCurve", duration = "FlipbookChangeDuration" },
        "SyncDuration",
        "FlipbookLoop",
        "FlipbookLoopCount",
      },
    },
  }
end

-- the frames of `ref`'s flipbook handed to `setTexture` from now on, over
-- `span`, the effect's own duration. answers how long the frames keep the
-- effect, 0 for an instance with none
function common.play(
  scope: lifetime.effect,
  ref: Instance,
  attrs: any,
  span: number,
  setTexture: (texture: string) -> ()
): number
  const frames = flipbook_common.getFlipbookData(ref)

  if frames == nil then
    return 0
  end

  const config = {
    ref = ref,
    frames = frames,
    effectDuration = span,
    syncDuration = attrs.SyncDuration,

    curve = attrs.FlipbookChangeCurve,
    duration = attrs.FlipbookChangeDuration,

    setTexture = setTexture,
  }

  const write = flipbook_common.createUpdateCallback(config)

  if attrs.FlipbookLoop then
    const cycle, cycles, length =
      flipbook_common.cycles(config.duration, span, config.syncDuration, true, attrs.FlipbookLoopCount)

    -- an endless loop plays as long as the effect does, never longer
    const played = if cycles == 0 then span else length

    flipbook_loop.play(scope, config.curve, cycle, cycles, played, write)

    return played
  end

  const length = flipbook_common.getChangeDuration(config)

  tween.play(scope, curve.new(length, config.curve), write)

  return length
end

return common
