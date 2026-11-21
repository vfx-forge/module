local mod = require("@mod/mod")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local lazy = require("@mod/lazy")
local utility = require("@mod/utility")

local function always()
  return true
end

local function defaultCurve()
  return utility.default_bezier
end

-- each piece draws its own size between the two corners, which is what the old
-- pair of reads did with a default each. a size authored on the row itself, or
-- a queue under it, is the row's state and draws nothing
local function sizeFromCorners(_, attrs: any)
  return mods.draw(attrs.MinSize, attrs.MaxSize)
end

-- the exits are the despawn lane's defaults on the offset, size and
-- transparency rows, and these rows say where each goes, for how long and how
local function shrinkEnd(_, attrs: any)
  return attrs.ShrinkScale
end

local function shrinkDuration(_, attrs: any)
  return attrs.ShrinkDuration
end

local function shrinkCurve(_, attrs: any)
  return attrs.ShrinkCurve
end

local function offsetOutEnd(_, attrs: any)
  return attrs.OffsetOut
end

local function offsetOutDuration(_, attrs: any)
  return attrs.OffsetOutDuration
end

local function offsetOutCurve(_, attrs: any)
  return attrs.OffsetOutCurve
end

local function transparencyDuration(_, attrs: any)
  return attrs.TransparencyDuration
end

local ring = {}

const play = lazy.unit("shockwave_ring", function()
  return require("@root/play/shockwave_ring").bind(ring)
end)

ring.id = "shockwave_ring"
ring.display = { name = "Shockwave Ring", icon = "shockwave_ring", order = 51 }
ring.classifier = ".Shockwave > #Rings > BasePart"
ring.components = "Instance"
ring.events = { "despawn" }

ring.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("EmitDelay"):hint("Seconds before the effect starts emitting."),
  Radius = knob(5):min(0):unit("studs"):label("Radius"):hint("Radius of the effect."),
  Segments = knob(7):min(1):label("Segments"):hint("Number of raycasts distributed evenly around the ring."),
  Lifetime = knob(NumberRange.new(2, 3))
    :min(0)
    :unit("seconds")
    :mod()
    :label("Lifetime")
    :hint("How long the effect lives in seconds."),
  -- the corners are the pair an author sets and the panel renders, and they are
  -- spelled the engine's way because a draw only runs per axis between two
  -- values of that spelling. the drawn size between them is the row a queue or
  -- a bare Size attribute overrides, which is all it is ever named for
  Size = knob(sizeFromCorners):unit("studs"):mod():hidden(always),
  MinSize = knob(Vector3.new(2, 1, 2))
    :aliases("Size_Min")
    :unit("studs")
    :label("Min")
    :hint("Minimum per-axis size for each ring piece."),
  MaxSize = knob(Vector3.new(3, 2, 3))
    :aliases("Size_Max")
    :unit("studs")
    :label("Max")
    :hint("Maximum per-axis size for each ring piece."),
  Speed = knob(1):mod():label("Speed"):hint("Multiplier on the effect's clock."),
  -- the entry phases rest where the old defaults left them: the offset where
  -- it stands, the size on a rise from nothing to the drawn size. the fade
  -- runs only once a piece despawns, from where it rests to the end, so the
  -- row plays from that lane alone. the spans the old quads ran over are rows
  -- of their own, so the defaults keep them and retime reaches them
  OffsetIn = knob(vector.zero)
    :unit("studs")
    :mod(mod.to(offsetOutEnd):duration(offsetOutDuration):curve(offsetOutCurve):lane("despawn"))
    :label("Offset")
    :hint("Local offset each piece settles at."),
  OffsetInDuration = knob(0.5)
    :min(0)
    :aliases("OffsetIn_Duration", "Offset_Start_Duration")
    :unit("seconds")
    :hidden(always),
  SizeScaleIn = knob(vector.one)
    :mod(
      mod.from(vector.zero):duration(function(_, attrs)
        return attrs.SizeScaleInDuration
      end),
      mod.to(shrinkEnd):duration(shrinkDuration):curve(shrinkCurve):lane("despawn")
    )
    :label("Scale")
    :hint("Fraction of the drawn size each piece settles at."),
  SizeScaleInDuration = knob(0.5)
    :min(0)
    :aliases("SizeScaleIn_Duration", "Size_Start_Duration")
    :unit("seconds")
    :hidden(always),
  Transparency = knob(0)
    :aliases("Transparency_Start")
    :lane("despawn")
    :mod(mod.to(0):duration(transparencyDuration):lane("despawn"))
    :label("Transparency")
    :hint("Transparency each piece rests at before its fade."),
  TransparencyDuration = knob(0.5):min(0):aliases("Transparency_Duration"):unit("seconds"):hidden(always),
  -- the exit phases run on the despawn lane the module fires when a piece's
  -- dwell ends. these old exit rows feed that lane's defaults on OffsetIn and
  -- SizeScaleIn and the module's clock, and are hidden, since the modifier
  -- window's Despawn tab edits the lane itself
  ShrinkScale = knob(vector.zero):aliases("SizeScaleOut_End", "SizeScaleEnd"):hidden(always),
  ShrinkDuration = knob(0.5)
    :min(0)
    :aliases("SizeScaleOut_Duration", "Size_End_Duration", "Size_Duration")
    :unit("seconds")
    :hidden(always),
  ShrinkCurve = knob(defaultCurve):aliases("SizeScaleOut_Curve", "Size_End_Curve", "Size_Curve"):hidden(always),
  OffsetOut = knob(vector.zero):aliases("OffsetOut_End", "Offset_End", "PartOffset"):unit("studs"):hidden(always),
  OffsetOutDuration = knob(0.5)
    :min(0)
    :aliases("OffsetOut_Duration", "Offset_End_Duration")
    :unit("seconds")
    :hidden(always),
  OffsetOutCurve = knob(defaultCurve):aliases("OffsetOut_Curve", "Offset_End_Curve"):hidden(always),
}

ring.properties = {}

ring.layout = {
  { title = "Emit", entries = { "EmitDelay", "Speed" } },
  { title = "Ring", entries = { "Radius", "Segments", "Lifetime" } },
  { title = "Size", entries = { "MinSize", "MaxSize" } },
  { title = "Settle", entries = { "OffsetIn", "SizeScaleIn", "Transparency" } },
}

-- the longest a segment can last, which is the ring's own clock: the longest
-- dwell it can draw, then the longest exit it can run
function ring.duration(_, attrs: any)
  return attrs.Lifetime.value.Max + math.max(attrs.ShrinkDuration, attrs.OffsetOutDuration, attrs.TransparencyDuration)
end

function ring.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

function ring.selected(ctx: any)
  return play().selected(ctx)
end

return ring
