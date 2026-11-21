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

local line = {}

const play = lazy.unit("shockwave_line", function()
  return require("@root/play/shockwave_line").bind(line)
end)

line.id = "shockwave_line"
line.display = { name = "Shockwave Line", icon = "shockwave_line", order = 52 }
line.classifier = ".Shockwave > #Lines > BasePart"
line.components = "Instance"
line.events = { "despawn" }

line.attributes = {
  EmitDelay = knob(0)
    :min(0)
    :unit("seconds")
    :ranged()
    :label("EmitDelay")
    :hint("Seconds before the effect starts emitting."),
  Duration = knob(1):min(0):unit("seconds"):label("Duration"):hint("How long the raycast sweep takes, in seconds."),
  Lifetime = knob(NumberRange.new(2, 3))
    :min(0)
    :unit("seconds")
    :mod()
    :label("Lifetime")
    :hint("How long each spawned line piece lives, in seconds."),
  SyncPosition = knob(false)
    :label("SyncPosition")
    :hint("Whether the sweep re-samples the origin's position every tick."),
  Length = knob(50):min(0):unit("studs"):label("Length"):hint("Studs the raycast origin sweeps along Direction."),
  Direction = knob(vector.create(0, 0, -1))
    :label("Direction")
    :hint("Local direction the sweep travels away from the origin."),
  Rotation = knob(NumberRange.new(-180, 180))
    :label("Rotation")
    :hint("Random per-piece rotation range around the hit normal, in degrees."),
  -- a fixed amount spreads the casts over the whole sweep itself, and the rate
  -- is then read by nothing
  Rate = knob(30)
    :min(0)
    :unit("perSecond")
    :mod()
    :readonly(function(_, attrs)
      return attrs.FixedAmount ~= 0
    end)
    :label("Rate")
    :hint("Raycasts per second over the sweep."),
  FixedAmount = knob(0)
    :min(0)
    :label("FixedAmount")
    :hint("Total raycasts spread evenly across Duration, overriding Rate."),
  Scale = knob(1):min(0):mod():label("Scale"):hint("Overall size multiplier over the sweep."),
  PathCurve = knob(function()
      return utility.linear_bezier
    end)
    :aliases("Path_Curve")
    :label("Path")
    :hint("Easing of the sweep along its length."),
  -- the corners are the pair an author sets and the panel renders, and they are
  -- spelled the engine's way because a draw only runs per axis between two
  -- values of that spelling. the drawn size between them is the row a queue or
  -- a bare Size attribute overrides, which is all it is ever named for
  Size = knob(sizeFromCorners):unit("studs"):mod():hidden(always),
  MinSize = knob(Vector3.new(2, 1, 2))
    :aliases("Size_Min")
    :unit("studs")
    :label("Min")
    :hint("Minimum per-axis size for each line piece."),
  MaxSize = knob(Vector3.new(3, 2, 3))
    :aliases("Size_Max")
    :unit("studs")
    :label("Max")
    :hint("Maximum per-axis size for each line piece."),
  Speed = knob(1):mod():label("Speed"):hint("Multiplier on the effect's clock."),
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
  -- the fade runs only once a piece despawns, so the row plays from that lane
  -- alone
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

line.properties = {}

line.layout = {
  { title = "Emit", entries = { "EmitDelay", "Speed" } },
  { title = "Sweep", entries = { "Duration", "Length", "Direction", "PathCurve", "SyncPosition" } },
  { title = "Pieces", entries = { "Rate", "FixedAmount", "Lifetime", "Rotation" } },
  { title = "Size", entries = { "Scale", "MinSize", "MaxSize" } },
  { title = "Settle", entries = { "OffsetIn", "SizeScaleIn", "Transparency" } },
}

-- the longest a piece emitted at the very end can last: the whole emission,
-- then the longest dwell it can draw, then the longest exit it can run
function line.duration(_, attrs: any)
  return attrs.Duration
    + attrs.Lifetime.value.Max
    + math.max(attrs.ShrinkDuration, attrs.OffsetOutDuration, attrs.TransparencyDuration)
end

function line.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

-- in the declarations, so selecting one never loads what it plays
function line.selected(ctx: any)
  local piece = ctx.ref :: BasePart
  local folder = piece.Parent
  local origin = if folder ~= nil then folder.Parent else nil

  if origin == nil or not origin:IsA("Attachment") then
    return
  end

  piece.Anchored = true
  piece.CFrame = origin.WorldCFrame
end

return line
