local CollectionService = game:GetService("CollectionService")

local mod = require("@mod/mod")
local mods = require("@mod/mods")
local knob = require("@mod/knob")
local lazy = require("@mod/lazy")
local reader = require("@mod/reader")
local utility = require("@mod/utility")

-- Model:ScaleTo is invalid at zero or below, and the runtime can reach that
-- where the authoring UI cannot: a chained modifier or a randomizer with a bad
-- range evaluates to whatever it evaluates to
local MIN_SCALE = 0.001

local function always()
  return true
end

local spin = {}

spin.id = "model_spin"
spin.display = { name = "Model", icon = "model_spin", order = 10 }

-- every model that is not a mesh effect, which is a model with a Start and an
-- End part directly under it
spin.classifier = "Model:not(Model:has(> BasePart#Start):has(> BasePart#End))"

-- a model stores a rate, degrees a second for SpinDuration, when it was saved
-- before Turn was a row, or when something older wrote one since: an older
-- plugin's Rotation row, an old script, a v2 randomizer child. a stored rate
-- is the newest intent there is, so it plays whatever turn is stored beside it
const function onRate(ref: Instance): boolean
  return ref:GetAttribute("SpinRotation") ~= nil
end

-- the rows a turn is worked out of, the rate and its duration
const RATE_ROWS = { SpinRotation = true, SpinDuration = true }

-- the tags an attribute's tween or randomizer RayValue carries, which find one
-- an ObjectValue aims at the model from anywhere
const DRIVER_TAGS = { "AttributeTweener", "AttributeRandomizer" }

-- whether a RayValue drives the model's rate or duration, by the dispatcher's
-- own reading of it
const function drives(child: Instance, ref: Instance): boolean
  if not child:IsA("RayValue") then
    return false
  end

  const target, read = utility.driverOf(child)

  return target == ref and read.source == "attribute" and RATE_ROWS[read.name] == true
end

-- a model whose rate or duration something drives: a lane the applier plays
-- onto the attribute, or a v2 tween or randomizer RayValue the dispatcher
-- aims at the model, under it through folders or anywhere through an
-- ObjectValue. the rate it plays is whatever that driver has left on the
-- attribute when the spin reads it, which no stored turn reproduces, so such
-- a model stays on its rate
const function driven(ref: Instance): boolean
  for name in RATE_ROWS do
    if ref:GetAttribute(mods.attrName("attribute", name)) ~= nil then
      return true
    end
  end

  -- getTarget climbs out of folders to the first instance that is not one,
  -- so what it lands on the model from is below the model through folders
  const below = { ref }

  while #below > 0 do
    for _, child in (table.remove(below) :: Instance):GetChildren() do
      if child:IsA("Folder") then
        table.insert(below, child)
      elseif drives(child, ref) then
        return true
      end
    end
  end

  for _, tag in DRIVER_TAGS do
    for _, child in CollectionService:GetTagged(tag) do
      if drives(child, ref) then
        return true
      end
    end
  end

  return false
end

-- whether the model plays a rate: one it stores, or one something drives,
-- whatever turn is stored, since the driver writes the rate an emit reads.
-- a turn stored beside a driven rate and no rate does nothing
const function rated(ref: Instance): boolean
  return onRate(ref) or driven(ref)
end

-- the card shows the row that plays: a model on its rate edits the rate
const function shownRate(ctx: any): boolean
  return ctx ~= nil and typeof(ctx.ref) == "Instance" and rated(ctx.ref)
end

const function shownTurn(ctx: any): boolean
  return not shownRate(ctx)
end

spin.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
  ResetDelay = knob(0)
    :min(0)
    :unit("seconds")
    :label("ResetDelay")
    :hint("Extra seconds to hold the finished pose before resetting."),
  ResetOnFinish = knob(true):label("ResetOnFinish"):hint("Whether to reset the effect state after it finishes."),
  -- how far the model turns in all, so a new duration or a retime changes how
  -- fast it gets there and never how far. a model storing a rate plays that
  -- instead, the same turn as before, until the plugin folds it in
  -- (spin.upgrade), and one whose rate something drives always does (rated)
  SpinTurn = knob(function(_, attrs)
      return attrs.SpinRotation * attrs.SpinDuration
    end)
    :label("Turn")
    :hint("Degrees the model turns in all over its duration, per axis.")
    :hidden(shownRate),
  -- degrees a second for SpinDuration, as every model before Turn stored it,
  -- shown only on a model still playing one
  SpinRotation = knob(vector.zero)
    :unit("perSecond")
    :label("Rotation")
    :hint("Degrees a second the model turns for its duration, per axis. A modifier or an older version drives it.")
    :hidden(shownTurn),
  SpinDuration = knob(0.5)
    :min(0)
    :unit("seconds")
    :label("Duration")
    :hint("Seconds the model takes to make its turn at a Speed of 1."),
  SyncPosition = knob(false):label("SyncPosition"):hint("Whether the effect follows the emitter's position."),
  Scale = knob(1):min(MIN_SCALE):mod():label("Scale"):hint("Model scale factor over the spin."),
  -- an unauthored model rests on a ramp from nought to one, and that ramp is
  -- load bearing: a speed that is zero for good returns nil from the rotation
  -- timer's counter and stops it on frame one
  SpinSpeed = knob(1)
    :mod(mod.from(0):duration(function(_, attrs)
      return attrs.SpinSpeedDuration
    end))
    :label("Speed")
    :hint("Multiplier on how fast the model makes its turn. It ramps in from 0 by default."),
  SpinSpeedDuration = knob(0.1):min(0):aliases("SpinSpeed_Duration"):unit("seconds"):hidden(always),
}

spin.properties = {}

spin.layout = {
  { title = "Emit", entries = { "EmitDelay", "ResetDelay", "ResetOnFinish" } },
  { title = "Spin", entries = { "SpinTurn", "SpinRotation", "SpinDuration", "SpinSpeed", "SyncPosition", "Scale" } },
}

function spin.duration(_, attrs: any)
  return attrs.SpinDuration
end

-- the turn as a vector, none for a stored value that is not one: the row's
-- rule takes no type, so the reader checks nothing it reads under it
const function turnOf(ref: Instance, attrs: any): vector
  const turn = if rated(ref) then attrs.SpinRotation * attrs.SpinDuration else attrs.SpinTurn

  return if knob.kindOf(turn) == "Vector3" then turn else vector.zero
end

-- declared below the turn reader, which the play module takes in its load
-- since a play module never requires the module that declares it
const play = lazy.unit("model_spin", function()
  return require("@root/play/spin").bind(spin, { turnOf = turnOf })
end)

-- what saving the model the current way writes and removes: the turn its
-- stored rate makes over its duration, written over any turn stored beside it,
-- and the rate gone. nil for a model storing no rate, and for one whose rate
-- or duration something drives, which keeps playing its rate
function spin.upgrade(ref: Instance): ({ [string]: any }?, { string }?)
  if not onRate(ref) or driven(ref) then
    return nil, nil
  end

  const attrs = reader.resolve(spin, { ref = ref, obj = ref, effect = spin })
  const turn = turnOf(ref, attrs)

  return { SpinTurn = Vector3.new(turn.X, turn.Y, turn.Z) }, { "SpinRotation" }
end

-- a model nothing moves: no turn, a scale resting at one, no following. a
-- speed alone turns nothing
function spin.static(attrs: any, ref: Instance)
  return turnOf(ref, attrs) == vector.zero
    and not attrs.Scale.animated
    and attrs.Scale.value == 1
    and not attrs.SyncPosition
end

function spin.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

return spin
