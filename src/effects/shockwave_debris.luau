local mod = require("@mod/mod")
local knob = require("@mod/knob")
local lazy = require("@mod/lazy")
local utility = require("@mod/utility")

local function always()
  return true
end

-- the exits are the despawn lane's defaults on SizeScale and Transparency, and
-- the shrink and fade rows say where each goes, for how long and how
local function shrinkEnd(_, attrs: any)
  return attrs.ShrinkScale
end

local function shrinkDuration(_, attrs: any)
  return attrs.ShrinkDuration
end

local function shrinkCurve(_, attrs: any)
  return attrs.ShrinkCurve
end

local function transparencyDuration(_, attrs: any)
  return attrs.TransparencyDuration
end

local debris = {}

const play = lazy.unit("shockwave_debris", function()
  return require("@root/play/shockwave_debris").bind(debris)
end, function(module: any)
  module.init()
end)

debris.id = "shockwave_debris"
debris.display = { name = "Shockwave Debris", icon = "shockwave_debris", order = 53 }
debris.classifier = ".Shockwave > #Debris > BasePart"
debris.components = "Instance"
debris.events = { "despawn" }

-- no Speed row. debris flies under physics impulses, so a speed multiplier
-- would scale the dwell and the shrink and leave the flight alone, which reads
-- worse than having no knob at all
debris.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("EmitDelay"):hint("Seconds before the effect starts emitting."),
  Amount = knob(NumberRange.new(5, 10)):min(0):label("Amount"):hint("Random range for how many debris pieces spawn."),
  Lifetime = knob(NumberRange.new(2, 3))
    :min(0)
    :unit("seconds")
    :mod()
    :label("Lifetime")
    :hint("How long each debris piece lives, in seconds."),
  Airtime = knob(NumberRange.new(0.5, 0.5))
    :min(0)
    :unit("seconds")
    :label("Airtime")
    :hint("Target time-of-flight used to compute launch impulse, in seconds."),
  LinearMagnitude = knob(NumberRange.new(15, 25))
    :unit("studs")
    :label("Linear")
    :hint("Random range for how far each piece is thrown, in studs, landing after its Airtime."),
  AngularMagnitude = knob(NumberRange.new(5, 15))
    :label("Angular")
    :hint("Random range for each piece's spin impulse strength."),
  InheritanceEnabled = knob(true)
    :label("Enabled")
    :hint("Whether nearby parts can donate their look to spawned debris."),
  InheritanceRadius = knob(5)
    :unit("studs")
    :label("Radius")
    :hint("Studs around the origin searched for parts to inherit from."),
  InheritanceMaxResults = knob(5):label("MaxResults"):hint("Maximum parts collected by the inheritance overlap query."),
  MinDirection = knob(-vector.one):label("Min"):hint("Lower per-axis bound for each piece's random launch direction."),
  MaxDirection = knob(vector.one):label("Max"):hint("Upper per-axis bound for each piece's random launch direction."),
  Size = knob(vector.create(2.5, 1.5, 2.5))
    :unit("studs")
    :mod()
    :label("Size")
    :hint("Size drawn for each piece, in studs."),
  SizeScale = knob(vector.one)
    :mod(mod.to(shrinkEnd):duration(shrinkDuration):curve(shrinkCurve):lane("despawn"))
    :label("Scale")
    :hint("Size factor on each piece; its despawn lane runs the shrink."),
  -- the old shrink rows feed the despawn lane's default and are hidden, since
  -- the modifier window's Despawn tab edits the lane itself
  ShrinkScale = knob(vector.zero):aliases("SizeScaleOut_End", "SizeScaleEnd"):hidden(always),
  ShrinkDuration = knob(0.5)
    :min(0)
    :aliases("SizeScaleOut_Duration", "Size_End_Duration", "Size_Duration")
    :unit("seconds")
    :hidden(always),
  ShrinkCurve = knob(function()
      return utility.default_bezier
    end)
    :aliases("SizeScaleOut_Curve", "Size_End_Curve", "Size_Curve")
    :hidden(always),
  -- the fade runs only once a piece despawns, so the row plays from that lane
  -- alone
  Transparency = knob(0)
    :aliases("Transparency_Start")
    :lane("despawn")
    :mod(mod.to(1):duration(transparencyDuration):lane("despawn"))
    :label("Transparency")
    :hint("Transparency applied to spawned debris without an inherited surface."),
  -- the span the old fade ran over, read under its old name when nothing else
  -- was authored, and kept as a row so retime reaches it
  TransparencyDuration = knob(0.5):min(0):aliases("Transparency_Duration"):unit("seconds"):hidden(always),
}

debris.properties = {}

debris.layout = {
  { title = "Emit", entries = { "EmitDelay", "Amount", "Lifetime" } },
  { title = "Launch", entries = { "Airtime", "LinearMagnitude", "AngularMagnitude" } },
  { title = "Direction", entries = { "MinDirection", "MaxDirection" } },
  { title = "Appearance", entries = { "Size", "SizeScale", "Transparency" } },
  {
    title = "Inheritance",
    entries = {
      "InheritanceEnabled",
      "InheritanceRadius",
      "InheritanceMaxResults",
      { action = "toggle_paths", label = "Show Paths" },
    },
  },
}

-- the dwell's ceiling: a piece's own lifetime is drawn below it, and a queue
-- naming no duration runs over it
function debris.duration(_, attrs: any)
  return attrs.Lifetime.value.Max
end

function debris.init()
  return play().init()
end

-- nothing to stop before its first load
function debris.deinit()
  if lazy.loaded("shockwave_debris") then
    play().deinit()
  end
end

function debris.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

-- in the declarations, so selecting one never loads what it plays
function debris.selected(ctx: any)
  local piece = ctx.ref :: BasePart
  local folder = piece.Parent
  local origin = if folder ~= nil then folder.Parent else nil

  if origin == nil or not origin:IsA("Attachment") then
    return
  end

  piece.Anchored = true
  piece.CFrame = origin.WorldCFrame
end

return debris
