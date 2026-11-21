--!native
--!optimize 2
const knob = require("@mod/knob")
const lazy = require("@mod/lazy")
const reader = require("@mod/reader")
const utility = require("@mod/utility")
const value_curve = require("@mod/value_curve")
const force_rows = require("@mod/common/force_rows")
const state_list = require("@mod/common/state_list")
const path_curve = require("@mod/common/path_curve")
const material_rows = require("@mod/common/material_rows")
const orient_common = require("@mod/common/orient")
const parent_turn = require("@mod/common/parent_turn")

-- the plugin's holder of the attachments a template's path is edited as,
-- whatever its class
const PATH_TAG = "ForgeMeshPath"

const FLIPBOOK_MODES = { "OneShot", "Loop", "PingPong" }

-- a server running a game draws for no camera of its own, so a ZOffset there
-- moves nothing
const SERVED = utility.SERVER_CONTEXT and not utility.PLUGIN_CONTEXT

const function always()
  return true
end

const function linear()
  return utility.linear_bezier
end

const function eased()
  return utility.default_bezier
end

-- Rate paces the loop and an EmitDuration window alike
const function unpaced(_, attrs: any)
  const duration = attrs.EmitDuration

  return not attrs.Enabled and not (type(duration) == "number" and duration > 0)
end

const function boxed(_, attrs: any)
  return attrs.Shape == "Box"
end

const function noFrames(_, attrs: any)
  return attrs.FrameSet == ""
end

const function noTextures(_, attrs: any)
  return attrs.TextureSet == ""
end

const function frameOneShot(_, attrs: any)
  return attrs.FlipbookMode == "OneShot"
end

const function textureOneShot(_, attrs: any)
  return attrs.TextureMode == "OneShot"
end

const function textureSynced(_, attrs: any)
  return attrs.TextureSyncDuration == true
end

-- whether each piece moves through its states, where no flight row reaches it
const function stated(_, attrs: any)
  return attrs.Motion == "States"
end

const function flown(_, attrs: any)
  return attrs.Motion ~= "States"
end

-- whether each piece walks a path
const function pathed(_, attrs: any)
  return attrs.Motion == "Path"
end

const function unpathed(_, attrs: any)
  return attrs.Motion ~= "Path"
end

-- whether a piece on a path flies at all: on past its end, or off it by a
-- bounce
const function flies(attrs: any)
  return attrs.AfterPath == "Continue" or attrs.CollisionMode == "Bounce"
end

-- whether no flight row reaches a piece: one moving through its states, or
-- one walking a path it never leaves
const function grounded(ctx: any, attrs: any)
  return stated(ctx, attrs) or (pathed(ctx, attrs) and not flies(attrs))
end

-- whether the states set the look, which the rows they replace then show
const function hasStates(_, attrs: any)
  return attrs.Motion == "States" and #attrs.States > 0
end

-- whether the emission direction moves nothing under States: neither the
-- spawn, which it moves on a surface box's face, a cylinder's or disc's axis
-- and a part sphere's cap, nor the launch's turn, which it moves unless a box
-- launches straight out of it
const function aimless(_, attrs: any)
  if attrs.Motion ~= "States" then
    return false
  end

  const spawnless = (attrs.Shape == "Box" and attrs.ShapeStyle ~= "Surface")
    or (attrs.Shape == "Sphere" and attrs.ShapePartial >= 1)

  if not spawnless then
    return false
  end

  const spread = attrs.SpreadAngle

  return attrs.Shape == "Box" and attrs.ShapeFace == "Outward" and spread.value == vector.zero and not spread.animated
end

-- the force card's rows are not this module's, so a rule reads its Force off
-- the instance
const function ringed(ctx: any)
  return force_rows.kindOf(ctx) == "Orbit"
end

-- a mod row reaches a rule as its track
const function dragless(ctx: any, attrs: any)
  return attrs.Drag.value <= 0 or ringed(ctx)
end

-- whether a Turbulence track wanders at all, its base or a modifier lifting it
const function turbulent(track: any)
  if track.animated then
    return true
  end

  const v = track.at(0)

  return type(v) == "number" and v > 0
end

const function calm(_, attrs: any)
  return not turbulent(attrs.Turbulence)
end

-- a piece locked to its parent never meets the world, but one a modifier
-- frees for a while does
const function carried(_, attrs: any)
  const lock = attrs.LockedToPart

  return not lock.animated and lock.at(0) == true
end

const function noBounce(_, attrs: any)
  return attrs.CollisionMode ~= "Bounce"
end

const function noCollision(_, attrs: any)
  return attrs.CollisionMode == "Off"
end

-- whether a hit leaves a piece where it landed, a killed one lingering there
-- through its destroy delay
const function lands(attrs: any)
  return attrs.CollisionMode == "Stop" or attrs.CollisionMode == "Kill"
end

const function unlanded(ctx: any, attrs: any)
  return carried(ctx, attrs) or not lands(attrs)
end

const function unaligned(_, attrs: any)
  return attrs.SurfaceAlign == "None"
end

const function untagged(_, attrs: any)
  return attrs.CollisionMode == "Off" or attrs.CollisionFilter == "None"
end

-- whether the template's parent gives it no point to be kept on, which a
-- rule read with no template never says
const function pointless(ctx: any)
  const ref = if ctx ~= nil then ctx.ref else nil

  return typeof(ref) == "Instance" and not parent_turn.framed(ref)
end

const forge_mesh = {}

const play = lazy.unit("forge_mesh", function()
  return require("@root/play/forge_mesh").bind(forge_mesh, { lands = lands, turbulent = turbulent })
end)

-- the engine calls, held here so a spec can stand in for them under lune
forge_mesh.engine = {
  alive = function(inst: Instance): boolean
    return inst:IsDescendantOf(game)
  end,
  pivot = function(model: Model): CFrame
    return model:GetPivot()
  end,
  -- where the camera a ZOffset draws pieces toward stands, nil on a server
  -- or before a client's camera is set
  eye = function(): Vector3?
    if SERVED then
      return nil
    end

    const camera = workspace.CurrentCamera

    return if camera ~= nil then camera.CFrame.Position else nil
  end,
}

-- every piece alive across all emitters and emits, and the most that may be;
-- a spec lowers max, nothing else writes either
forge_mesh.pieces = { live = 0, max = 500 }

forge_mesh.PATH_TAG = PATH_TAG

forge_mesh.id = "forge_mesh"
forge_mesh.display = { name = "Mesh", icon = "forge_mesh", order = 95 }
forge_mesh.classifier = `BasePart.{utility.FORGE_MESH_TAG}`

-- the template's mesh, frame folders and decals are its own; the effects
-- nested in it run per piece
forge_mesh.components = "Instance"

forge_mesh.attributes = {
  EmitCount = knob(1):min(0):label("Count"):hint("Pieces emitted at once."),
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the effect starts emitting."),
  EmitDuration = knob(0)
    :min(0)
    :unit("seconds")
    :label("Duration")
    :hint("Seconds the effect emits at its Rate, 0 emitting Count pieces once."),
  DestroyDelay = knob(0)
    :min(0)
    :unit("seconds")
    :label("DestroyDelay")
    :hint("Extra seconds each piece keeps its look and nested effects after its motion ends."),

  Color = knob(function(ctx: reader.Ctx)
      return ColorSequence.new((ctx.ref :: BasePart).Color)
    end)
    :mod()
    :hidden(hasStates)
    :alpha("Transparency")
    :label("Color")
    :hint("Color of each piece over its life."),
  Orientation = knob("FacingCamera"):options(orient_common.MODES):hidden(stated):label("Orientation"):hint(
    "How each piece turns as it flies: its own pose, toward the camera or along its velocity. Trails and beams inside a piece that faces the camera sweep whenever the view moves."
  ),
  StateOrientation = knob("None")
    :options({ "None", "FacingCamera", "FacingCameraWorldUp" })
    :hidden(flown)
    :label("Orientation")
    :hint("How each piece's mesh turns: as it launched, or toward the camera while its launch still places its states."),
  Size = knob(value_curve.flat(1, 3))
    :valueCurve(3)
    :mod()
    :hidden(hasStates)
    :label("Size")
    :hint("Factor on the template's size, or its special mesh's scale, over each piece's life."),
  Squash = knob(value_curve.flat(0, 1))
    :valueCurve(1)
    :mod()
    :hidden(hasStates)
    :label("Squash")
    :hint("Stretch along each piece's up axis over its life, the other axes taking the opposite."),
  Transparency = knob(value_curve.flat(0, 1))
    :valueCurve(1)
    :mod()
    :hidden(hasStates)
    :label("Transparency")
    :hint("Transparency of each piece over its life."),
  ZOffset = knob(0):unit("studs"):label("ZOffset"):hint(
    "Studs each piece is drawn nearer the camera, below 0 farther, to layer it over or under other effects. The piece looks the same, only its order changes. Trails, beams and particles inside a piece sweep whenever the view moves."
  ),

  EmissionDirection = knob("Top")
    :options({ "Back", "Bottom", "Front", "Left", "Right", "Top" })
    :hidden(aimless)
    :label("EmissionDirection")
    :hint("Face of the emitter pieces launch from."),
  Enabled = knob(false):label("Enabled"):hint("Whether the effect emits continuously at its Rate."),
  Lifetime = knob(NumberRange.new(5, 10))
    :min(0)
    :unit("seconds")
    :mod()
    :label("Lifetime")
    :hint("Seconds each piece flies, drawn per piece."),
  Rate = knob(20)
    :min(0)
    :unit("perSecond")
    :hidden(unpaced)
    :label("Rate")
    :hint("Emits per second while Enabled, and through the emit Duration."),
  Rotation = knob(vector.zero)
    :mod()
    :hidden(stated)
    :label("Rotation")
    :hint("Initial rotation of each piece per axis, in degrees, drawn per piece."),
  RotationRandom = knob(vector.zero):mod():hidden(stated):label("RotationRandom"):hint(
    "Random extra rotation per axis, in degrees: each piece adds a value between minus and plus this to Rotation."
  ),
  RotSpeed = knob(vector.zero)
    :unit("perSecond")
    :mod()
    :hidden(stated)
    :label("RotSpeed")
    :hint("Spin of each piece per axis, in degrees per second, drawn per piece."),
  Speed = knob(NumberRange.new(5, 5))
    :unit("studsPerSecond")
    :mod()
    :hidden(function(ctx: any, attrs: any)
      return grounded(ctx, attrs) or (unpathed(ctx, attrs) and force_rows.speedless(ctx))
    end)
    :label("Speed")
    :hint("Speed each piece launches at along its emission direction, or leaves its path at, drawn per piece."),
  SpreadAngle = knob(vector.zero)
    :mod()
    :label("SpreadAngle")
    :hint("Random spread of each piece's launch direction, in degrees about X and Y."),

  Shape = knob("Box")
    :options({ "Box", "Cylinder", "Disc", "Sphere" })
    :label("Shape")
    :hint("Volume shape the pieces spawn in."),
  ShapeFace = knob("Outward")
    :options({ "InAndOut", "Inward", "Outward" })
    :label("Face")
    :hint("Whether pieces launch out of the shape, into it or both."),
  ShapePartial = knob(1):min(0):max(1):hidden(boxed):label("Partial"):hint("Fraction of the shape pieces spawn in."),
  ShapeStyle = knob("Volume")
    :options({ "Surface", "Volume" })
    :label("Style")
    :hint("Whether pieces spawn on the shape's surface or in its volume."),

  FlipbookMode = knob("OneShot")
    :options(FLIPBOOK_MODES)
    :label("Mode")
    :hint("Whether the frames play once, loop, or play back and forth."),
  FlipbookStartRandom = knob(false):label("StartRandom"):hint("Start each piece at a random frame."),
  FlipbookReverse = knob(false):label("Reverse"):hint("Play the frames backward."),
  FlipbookChangeCurve = knob(linear):label("Curve"):hint("Easing of the frames' playback."),
  FlipbookChangeDuration = knob(function(ctx)
      return ctx.duration
    end)
    :unit("seconds")
    :label("Duration")
    :hint("Seconds one pass of the frames takes, a PingPong pass running there and back."),
  SyncDuration = knob(true):label("SyncDuration"):hint("Play the frames' cycles over the piece's life."),
  FlipbookLoopCount = knob(0):hidden(frameOneShot):label("LoopCount"):hint(
    "Cycles of the frames to play, 0 repeating for the piece's life, below 0 until Mode leaves Loop or PingPong."
  ),
  FrameTransparency = knob(0)
    :min(0)
    :max(1)
    :mod()
    :label("Transparency")
    :hint("Transparency of the frames' decals over the piece's life."),

  TextureMode = knob("Loop")
    :options(FLIPBOOK_MODES)
    :label("Mode")
    :hint("Whether the material frames play once, loop, or play back and forth."),
  TextureStartRandom = knob(false):label("StartRandom"):hint("Start each piece at a random material frame."),
  TextureReverse = knob(false):label("Reverse"):hint("Play the material frames backward."),
  TextureFps = knob(24)
    :min(1)
    :unit("perSecond")
    :readonly(textureSynced)
    :label("Fps")
    :hint("Material frames worn per second, set by the piece's life while synced."),
  TextureSyncDuration = knob(false)
    :label("SyncDuration")
    :hint("Play the material frames' cycles over the piece's life."),
  TextureLoopCount = knob(0):hidden(textureOneShot):label("LoopCount"):hint(
    "Cycles of the material frames to play, 0 repeating for the piece's life, below 0 until Mode leaves Loop or PingPong."
  ),

  Motion = knob("Particle"):options({ "Particle", "Path", "States" }):label("Motion"):hint(
    "How each piece moves after it spawns: as a particle flies, along a drawn path, or through the states it is given."
  ),
  -- the list of states each piece moves through, which Edit States writes
  States = knob(state_list.EMPTY):stateList():hidden(always),
  -- the curve each piece walks, which Edit Path writes
  Path = knob(path_curve.DEFAULT):path():hidden(always),
  PathEnd = knob("Free"):options({ "Free", "Center", "Target" }):hidden(unpathed):label("PathEnd"):hint(
    "Where each path ends: as drawn from its spawn, stretched to the emitter's center, or to the EndPoint."
  ),
  EndPoint = knob()
    :instance({ "Attachment", "BasePart" })
    :hidden(function(ctx: any, attrs: any)
      return unpathed(ctx, attrs) or attrs.PathEnd ~= "Target"
    end)
    :label("EndPoint")
    :hint("The attachment or part every path ends on, followed as it moves. Unset, the paths run as drawn."),
  EndRadius = knob(NumberRange.new(0, 0))
    :min(0)
    :unit("studs")
    :hidden(function(ctx: any, attrs: any)
      return unpathed(ctx, attrs) or attrs.PathEnd == "Free"
    end)
    :label("EndRadius")
    :hint("How far from the end point each path ends, between the two distances, on the side facing its spawn."),
  Reverse = knob(false):hidden(unpathed):label("Reverse"):hint("Run every path backward, from its end to its spawn."),
  Bend = knob("AsDrawn"):options({ "AsDrawn", "Outward", "Swirl", "Random" }):hidden(unpathed):label("Bend"):hint(
    "Which way each path's bulge faces: as drawn, away from the center, around the emission axis, or at random."
  ),
  Progress = knob(value_curve.ramp(0, 1))
    :valueCurve(1)
    :hidden(unpathed)
    :label("Progress")
    :hint("How far along its path each piece is over its path time, 0 at the start and 1 at the end."),
  AfterPath = knob("Stop")
    :options({ "Stop", "Continue" })
    :hidden(unpathed)
    :label("AfterPath")
    :hint("What a piece does at its path's end: stop there, or fly on along it at Speed."),
  FlightTime = knob(NumberRange.new(1, 1))
    :min(0)
    :unit("seconds")
    :hidden(function(ctx: any, attrs: any)
      return unpathed(ctx, attrs) or attrs.AfterPath ~= "Continue"
    end)
    :label("FlightTime")
    :hint("Seconds each piece flies on past its path's end, drawn per piece."),
  Acceleration = knob(vector.zero)
    :unit("studsPerSecondSquared")
    :mod()
    :hidden(function(ctx: any, attrs: any)
      return grounded(ctx, attrs) or ringed(ctx)
    end)
    :label("Acceleration")
    :hint("Constant acceleration on each piece, in the parent's frame while LockedToPart."),
  Turbulence = knob(0)
    :min(0)
    :unit("studs")
    :mod()
    :hidden(grounded)
    :label("Turbulence")
    :hint("How far each piece wanders off its path, drawn per piece."),
  TurbulenceFrequency = knob(1)
    :min(0)
    :unit("perSecond")
    :hidden(function(ctx: any, attrs: any)
      return grounded(ctx, attrs) or calm(ctx, attrs)
    end)
    :label("TurbulenceFrequency")
    :hint("How fast each piece's wander changes."),

  Drag = knob(0)
    :min(0)
    :unit("perSecond")
    :mod()
    :hidden(function(ctx: any, attrs: any)
      return grounded(ctx, attrs) or ringed(ctx)
    end)
    :label("Drag")
    :hint("Rate each piece loses speed, halving it every 1/Drag seconds."),
  LockedToPart = knob(false)
    :mod()
    :label("LockedToPart")
    :hint("Whether pieces move with the parent. A modifier locks or frees pieces in flight."),
  TimeScale = knob(1):min(0):mod():label("TimeScale"):hint("Multiplier on the effect's clock, 0 freezing it."),
  VelocityInheritance = knob(0)
    :mod()
    :hidden(function(ctx: any, attrs: any)
      return grounded(ctx, attrs) or ringed(ctx)
    end)
    :label("VelocityInheritance")
    :hint("Share of the parent part's velocity each piece launches with."),
  WindAffectsDrag = knob(false)
    :hidden(function(ctx: any, attrs: any)
      return grounded(ctx, attrs) or dragless(ctx, attrs)
    end)
    :label("WindAffectsDrag")
    :hint("Whether drag eases each piece toward the global wind rather than to rest."),

  CollisionMode = knob("Off")
    :options({ "Off", "Kill", "Stop", "Bounce" })
    :label("CollisionMode")
    :hint("What a piece does when its path hits something."),
  Bounce = knob(0.5)
    :min(0)
    :max(1)
    :mod()
    :hidden(noBounce)
    :label("Bounce")
    :hint("Share of the speed into the surface a bounce keeps."),
  Friction = knob(0.2)
    :min(0)
    :max(1)
    :mod()
    :hidden(noBounce)
    :label("Friction")
    :hint("Share of the speed along the surface a bounce loses."),
  CollisionFilter = knob("None")
    :options({ "None", "Exclude Tag", "Include Tag" })
    :hidden(noCollision)
    :label("CollisionFilter")
    :hint("Whether tagged parts are left out of the hits or are the only ones hit."),
  CollisionFilterTag = knob(""):hidden(untagged):label("FilterTag"):hint("CollectionService tag the filter reads."),
  CollisionGroup = knob("Default")
    :hidden(noCollision)
    :label("CollisionGroup")
    :hint("Collision group the hits are cast in."),
  CollisionRespectCanCollide = knob(true)
    :hidden(noCollision)
    :label("RespectCanCollide")
    :hint("Whether parts with CanCollide off are passed through."),

  SurfaceAlign = knob("None"):options(orient_common.SIDES):label("SurfaceAlign"):hint(
    "Which side of each piece faces out of the surface it lands on: its top lies flat, its front faces out, its back points in."
  ),
  SurfaceAlignCurve = knob(eased):hidden(unaligned):label("Curve"):hint("Easing of the turn onto the surface."),
  SurfaceAlignDuration = knob(0.1)
    :min(0)
    :unit("seconds")
    :hidden(unaligned)
    :label("Duration")
    :hint("Seconds the turn onto the surface takes, 0 snapping at once."),
  SurfaceOffset = knob(0)
    :unit("studs")
    :label("Offset")
    :hint("How far each landed piece rests off the surface, along the surface's normal."),

  -- read by the plugin alone (parent_turn): pieces spawn from the parent
  -- either way
  FollowParent = knob(true):hidden(pointless):label("FollowParent"):hint(
    "Keep the mesh on its parent's point while you edit. Off lets you move it anywhere, such as under the ground, while pieces still spawn from the parent and turn as the mesh does."
  ),

  -- the keys of the Frames and Textures folders the template plays, which the
  -- plugin writes
  FrameSet = knob(""):hidden(always),
  TextureSet = knob(""):hidden(always),
}

forge_mesh.properties = {}

forge_mesh.layout = {
  { title = "Emit", entries = { "EmitCount", "EmitDelay", "EmitDuration", "DestroyDelay" } },
  {
    title = "Appearance",
    entries = { "Color", "Orientation", "StateOrientation", "Size", "Squash", "Transparency", "ZOffset" },
  },
  {
    title = "Emission",
    entries = {
      "EmissionDirection",
      "Enabled",
      "Lifetime",
      "Rate",
      "Rotation",
      "RotationRandom",
      "RotSpeed",
      "Speed",
      "SpreadAngle",
    },
  },
  { title = "EmitterShape", entries = { "Shape", "ShapeFace", "ShapePartial", "ShapeStyle" } },
  {
    title = "Motion",
    entries = {
      "Motion",
      "Acceleration",
      "Turbulence",
      "TurbulenceFrequency",
    },
  },
  {
    title = "Path",
    entries = {
      "PathEnd",
      "EndPoint",
      "EndRadius",
      "Reverse",
      "Bend",
      "Progress",
      "AfterPath",
      "FlightTime",
      { action = "edit_path", label = "Edit Path" },
    },
    hidden = unpathed,
  },
  {
    title = "States",
    entries = { { action = "edit_states", label = "Edit States" } },
    hidden = flown,
  },
  {
    title = "Particles",
    entries = { "Drag", "LockedToPart", "TimeScale", "VelocityInheritance", "WindAffectsDrag" },
  },
  {
    title = "Collision",
    entries = {
      "CollisionMode",
      "Bounce",
      "Friction",
      "CollisionFilter",
      "CollisionFilterTag",
      "CollisionGroup",
      "CollisionRespectCanCollide",
    },
    hidden = carried,
  },
  {
    title = "Landing",
    entries = {
      "SurfaceAlign",
      { curve = "SurfaceAlignCurve", duration = "SurfaceAlignDuration" },
      "SurfaceOffset",
    },
    hidden = unlanded,
  },
  {
    title = "Behavior",
    entries = {
      "FollowParent",
      { action = "toggle_paths", label = "Show Paths" },
      { action = "toggle_textures", label = "Load Textures" },
    },
  },
}

-- the plugin's Flipbook card, which edits these rows of the template apart
-- from its main card
forge_mesh.cards = {
  Flipbook = {
    {
      title = "Mesh Frames",
      entries = {
        "FlipbookMode",
        "FlipbookStartRandom",
        "FlipbookReverse",
        { curve = "FlipbookChangeCurve", duration = "FlipbookChangeDuration" },
        "SyncDuration",
        "FlipbookLoopCount",
        "FrameTransparency",
      },
      hidden = noFrames,
    },
    {
      title = "Material Frames",
      entries = {
        "TextureMode",
        "TextureStartRandom",
        "TextureReverse",
        "TextureFps",
        "TextureSyncDuration",
        "TextureLoopCount",
      },
      hidden = noTextures,
    },
  },
}

-- the rows of the cards beside the effect's own, held on its instance and
-- read at emit, which the applier, retime and resize treat as its own
forge_mesh.companions = { force_rows.rows, material_rows.rows }

-- a path piece flying on past its end lives its flight time longer
function forge_mesh.duration(_, attrs: any)
  const flight = if attrs.Motion == "Path" and attrs.AfterPath == "Continue" then attrs.FlightTime.Max else 0

  return attrs.Lifetime.value.Max + flight
end

forge_mesh.constant = true

function forge_mesh.emit(ctx: any, attrs: any)
  return play().emit(ctx, attrs)
end

return forge_mesh
