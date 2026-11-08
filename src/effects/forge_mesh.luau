--!native
--!optimize 2
const attr = require("@mod/attributes")
const clock = require("@mod/clock")
const color = require("@mod/color/color")
const knob = require("@mod/knob")
const curve = require("@mod/curve")
const tween = require("@mod/tween")
const reader = require("@mod/reader")
const utility = require("@mod/utility")
const lifetime = require("@mod/lifetime")
const value_curve = require("@mod/value_curve")
const force_rows = require("@mod/common/force_rows")
const state_list = require("@mod/common/state_list")
const path_curve = require("@mod/common/path_curve")
const look_common = require("@mod/common/look")
const launch_common = require("@mod/common/launch")
const material_rows = require("@mod/common/material_rows")
const orient_common = require("@mod/common/orient")
const bezier_common = require("@mod/common/bezier")
const collision_common = require("@mod/common/collision")
const numeric_common = require("@mod/common/numeric")
const parent_turn = require("@mod/common/parent_turn")
const path_motion = require("@mod/path_motion")
const particle_motion = require("@mod/particle_motion")

const emitters = require("@root/emitters")

const pool = require("@srv/pool")
const containers = require("@srv/containers")
const mover = require("@srv/mover")
const frame_store = require("@srv/frame_store")
const enabled_effects = require("@srv/enabled_effects")

const Bezier = require("@obj/Bezier")

-- the template's folders of frame sets, which a piece is never handed
const SETS = { Frames = "FrameSet", Textures = "TextureSet" }

-- the plugin's folder of copies a template's states are edited as, which a
-- piece is never handed either
const STATES_TAG = "ForgeMeshStates"

-- the plugin's holder of the attachments a template's path is edited as,
-- whatever its class
const PATH_TAG = "ForgeMeshPath"

const FLIPBOOK_MODES = { "OneShot", "Loop", "PingPong" }

-- how far a piece's look must move from what was last written before a write
-- is worth it: transparency in absolute terms, size relative to itself on any
-- axis, color in 8 bit steps on any channel
const CLEAR_STEP = 0.02
const SIZE_STEP = 0.015
const SIZE_FLOOR = 1e-4
const COLOR_STEP = 2 / 255

-- a decal's UVs in steps of a texel of a 1024 map, its rotation in degrees
const UV_STEP = 1 / 1024
const TURN_STEP = 0.25

-- how far into its path a piece looks ahead to face the way it sets off, and
-- the shortest step whose motion reads as its velocity
const PROBE = 1 / 60
const SHORT_STEP = 1e-6

const WORLD_UP = vector.create(0, 1, 0)

-- each EmissionDirection in the emitter's own frame, spelled out since lune
-- has no Vector3.FromNormalId
const FACES = {
  Top = vector.create(0, 1, 0),
  Bottom = vector.create(0, -1, 0),
  Right = vector.create(1, 0, 0),
  Left = vector.create(-1, 0, 0),
  Back = vector.create(0, 0, 1),
  Front = vector.create(0, 0, -1),
}

const WHITE = Color3.new(1, 1, 1)

const isVector = launch_common.isVector
const numberOr = launch_common.numberOr
const modified = launch_common.modified

const function always()
  return true
end

const function linear()
  return utility.linear_bezier
end

const function disabled(_, attrs: any)
  return not attrs.Enabled
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

-- whether the camera turns a States piece's mesh, its launch still turning
-- where its states go
const function facesCamera(_, attrs: any)
  if attrs.Motion ~= "States" then
    return false
  end

  const mode = attrs.StateOrientation

  return mode == "FacingCamera" or mode == "FacingCameraWorldUp"
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

const function untagged(_, attrs: any)
  return attrs.CollisionMode == "Off" or attrs.CollisionFilter == "None"
end

-- whether a child of the template is one of its frame sets, its states or
-- its path's editing holder
const function setFolder(child: Instance)
  if child:HasTag(PATH_TAG) then
    return true
  end

  if not child:IsA("Folder") then
    return false
  end

  if child:HasTag(STATES_TAG) then
    return true
  end

  const key = SETS[child.Name]

  return key ~= nil and child:GetAttribute(key) ~= nil
end

-- the piece's own decals, each its own twin, so nothing blends between two
const function decalsOf(piece: BasePart): look_common.Decals
  const decals = { list = {}, flipbooks = {}, twins = {} }

  for _, child in piece:GetChildren() do
    if not child:IsA("Decal") then
      continue
    end

    const decal = child :: Decal

    table.insert(decals.list, decal)
    decals.twins[decal] = decal

    const data = if attr.get(decal, "FlipbookEnabled", nil, true)
      then attr.get(decal, "FlipbookTextures", nil, true)
      else nil

    if data then
      decals.flipbooks[decal] = utility.deserializeFlipbook(data)
    end
  end

  return decals
end

-- where pieces spawn from: a part's box, an attachment's point, else the
-- template's own pose as a point
const function originOf(template: BasePart): (CFrame, Vector3)
  const parent = template.Parent

  if parent ~= nil and parent:IsA("BasePart") then
    const cframe, size = utility.getTransformedOriginExtents(parent)

    return cframe, size
  end

  if parent ~= nil and parent:IsA("Attachment") then
    return (utility.getTransformedOriginExtents(parent)), Vector3.zero
  end

  return template.CFrame, Vector3.zero
end

-- the turn pieces play at: the template's own, carried by its parent's turn
-- since the plugin last measured the template against it. a template under an
-- attachment never moves with it, nor one cloned into a rig, so its own world
-- pose cannot say where the parent has turned
const function turnOf(template: BasePart, origin: CFrame): CFrame
  const parent = template.Parent
  const framed = parent ~= nil and (parent:IsA("BasePart") or parent:IsA("Attachment"))
  const stored = template:GetAttribute(parent_turn.ATTRIBUTE)

  return parent_turn.turned(template.CFrame, if framed then origin else nil, stored)
end

-- upper case, the spelling a row's vector and an authored Vector3 both answer
-- to under every host
const function toVector(v: Vector3): vector
  return vector.create(v.X, v.Y, v.Z)
end

-- the cast of a piece that meets nothing: locked to its parent, or under no
-- collision
const function unhit(_: vector, _: vector): collision_common.Hit?
  return nil
end

-- a drawn curve, or `fallback` where a modifier drew none of its width
const function curveOr(v: any, fallback: value_curve.Curve): value_curve.Curve
  return if value_curve.is(v) and v.channels == fallback.channels then v else fallback
end

-- a drawn gradient, or `fallback` where a modifier drew none
const function gradientOr(v: any, fallback: ColorSequence): ColorSequence
  return if typeof(v) == "ColorSequence" then v else fallback
end

-- whether every keypoint of a gradient holds one color
const function flatColor(sequence: ColorSequence)
  const keypoints = sequence.Keypoints
  const first = keypoints[1].Value

  for _, keypoint in keypoints do
    if keypoint.Value ~= first then
      return false
    end
  end

  return true
end

-- whether every axis of a pose is finite, so no degenerate row reaches the
-- mover
const function finite(cf: CFrame)
  return numeric_common.usable(cf.Position)
    and numeric_common.usable(cf.XVector)
    and numeric_common.usable(cf.YVector)
    and numeric_common.usable(cf.ZVector)
end

-- what the template wears itself, which a state's unset field reads as. a
-- state's surface multiplies the surface the piece wears, so its rest is no
-- change but the alpha mode
const function restOf(template: BasePart): state_list.Rest
  const own = template:FindFirstChildOfClass("SurfaceAppearance")
  const decals = {}

  for _, child in template:GetChildren() do
    if not child:IsA("Decal") or decals[child.Name] ~= nil then
      continue
    end

    const decal = child :: Decal

    decals[decal.Name] = {
      color = decal.Color3,
      transparency = decal.Transparency,
      uvOffset = decal.UVOffset,
      uvScale = decal.UVScale,
      rotation = decal.Rotation,
      zIndex = decal.ZIndex,
      glowStrength = attr.get(decal, "GlowStrength", 1, true, function(v)
        return if type(v) == "number" then math.max(v, 0) else 1
      end),
      emissiveStrength = decal.EmissiveStrength,
      emissiveTint = decal.EmissiveTint,
    }
  end

  return {
    surface = {
      color = WHITE,
      emissiveStrength = 1,
      emissiveTint = WHITE,
      alphaMode = if own ~= nil then own.AlphaMode.Name else nil,
    },
    decals = decals,
  }
end

-- one property of a piece the states write: what was last written, what was
-- sampled the frame before, and the share of a step the next write waits for
type Gate = { written: any, sampled: any, share: number }

const function gate(share: number): Gate
  return { written = nil, sampled = nil, share = share }
end

-- whether `v` lies more than `step` from `was`: a ratio and a scale relative
-- to `was` on any axis, a number, a tone, a color and a UV in absolute terms
-- on any channel, a switch whenever the two differ
const function apart(kind: string, v: any, was: any, step: number): boolean
  if kind == "number" then
    return math.abs(v - was) > step
  end

  if kind == "ratio" then
    return math.abs(v - was) > step * math.max(math.abs(was), SIZE_FLOOR)
  end

  if kind == "scale" then
    return math.abs(v.x - was.x) > step * math.max(math.abs(was.x), SIZE_FLOOR)
      or math.abs(v.y - was.y) > step * math.max(math.abs(was.y), SIZE_FLOOR)
      or math.abs(v.z - was.z) > step * math.max(math.abs(was.z), SIZE_FLOOR)
  end

  if kind == "tone" then
    return math.abs(v.x - was.x) > step or math.abs(v.y - was.y) > step or math.abs(v.z - was.z) > step
  end

  if kind == "Color3" then
    return math.abs(v.R - was.R) > step or math.abs(v.G - was.G) > step or math.abs(v.B - was.B) > step
  end

  if kind == "Vector2" then
    return math.abs(v.X - was.X) > step or math.abs(v.Y - was.Y) > step
  end

  return v ~= was
end

-- whether `v` is due a write, as a piece's rows decide one: on the first
-- frame, once it is a step from what was written, and exactly once it holds
-- still or the life is at an end. the first write after the spawn waits the
-- piece's share of a step, every later one a whole step
const function due(g: Gate, kind: string, v: any, step: number, first: boolean, exact: boolean)
  if v == nil then
    return false
  end

  const was = g.written
  const held = v == g.sampled

  g.sampled = v

  if not (first or was == nil or apart(kind, v, was, step * g.share) or ((exact or held) and v ~= was)) then
    return false
  end

  g.written = v
  g.share = if first then g.share else 1

  return true
end

-- a decal of the piece the states write by its name, under its glow mode
type Named = {
  decal: Decal,
  name: string,
  glow: string,
  colors: boolean,
  -- the template decal's own color and glow strength, which a Color glow
  -- lights with where the state sets none; the piece's own may still hold a
  -- glow a pooled life lit
  base: Color3,
  power: number,
  color: Gate,
  transparency: Gate,
  uvOffset: Gate,
  uvScale: Gate,
  rotation: Gate,
  zIndex: Gate,
  strength: Gate,
  tint: Gate,

  -- the color and strength a Color glow last multiplied, and what that made
  tone: Color3?,
  by: number?,
  lit: Color3?,
}

-- what a decal no state names reads as: every field the template's own
const UNSET: state_list.DecalState = table.freeze({}) :: any

-- a material named by a state, which the engine may refuse for a part
const function wear(obj: BasePart, name: string)
  const item = Enum.Material:FromName(name)

  if item ~= nil then
    pcall(function()
      obj.Material = item
    end)
  end
end

-- what writes one piece's look off its sample each frame, as `appear` writes
-- a particle's off its rows: its size on `rest`, its part's color,
-- transparency, reflectance and materials, its mesh's vertex color, its
-- surface and each decal the states name
const function dresser(
  obj: BasePart,
  sample: state_list.Sample,
  look: look_common.Look,
  decals: look_common.Decals,
  mesh: SpecialMesh?,
  rest: Vector3,
  stagger: number,
  rests: { [string]: state_list.DecalState }
)
  const own = obj:FindFirstChildOfClass("SurfaceAppearance")
  const named: { Named } = {}

  const size, tone, clear, shine = gate(stagger), gate(stagger), gate(stagger), gate(stagger)
  const material, variant, vertex = gate(stagger), gate(stagger), gate(stagger)
  const strength, tint, surfaceColor, alpha = gate(stagger), gate(stagger), gate(stagger), gate(stagger)

  for _, decal in decals.list do
    -- an animator on the decal's Color3 is the explicit ask, so the states
    -- leave the color to it
    const animated = emitters.animated(decal)
    const rested = rests[decal.Name]

    table.insert(named, {
      decal = decal,
      name = decal.Name,
      glow = attr.get(decal, "GlowMode", "None", true),
      colors = not (animated ~= nil and animated.Color3),
      base = if rested ~= nil and rested.color ~= nil then rested.color else decal.Color3,
      power = if rested ~= nil and rested.glowStrength ~= nil then rested.glowStrength else 1,
      color = gate(stagger),
      transparency = gate(stagger),
      uvOffset = gate(stagger),
      uvScale = gate(stagger),
      rotation = gate(stagger),
      zIndex = gate(stagger),
      strength = gate(stagger),
      tint = gate(stagger),
      tone = nil,
      by = nil,
      lit = nil,
    })
  end

  const function write(entry: Named, state: state_list.DecalState, first: boolean, exact: boolean)
    const decal = entry.decal
    local c = state.color

    -- a Color glow multiplies the color, never clamped, so past 1 it glows;
    -- what the state leaves unset is the template decal's own, as the editor
    -- shows it
    if entry.glow == "Color" then
      const by = state.glowStrength or entry.power

      c = c or entry.base

      if c ~= entry.tone or by ~= entry.by then
        entry.tone, entry.by = c, by
        entry.lit = Color3.new(c.R * by, c.G * by, c.B * by)
      end

      c = entry.lit
    end

    if entry.colors and due(entry.color, "Color3", c, COLOR_STEP, first, exact) then
      decal.Color3 = c :: Color3
    end

    if due(entry.transparency, "number", state.transparency, CLEAR_STEP, first, exact) then
      decal.Transparency = state.transparency :: number
    end

    if due(entry.uvOffset, "Vector2", state.uvOffset, UV_STEP, first, exact) then
      decal.UVOffset = state.uvOffset :: Vector2
    end

    if due(entry.uvScale, "Vector2", state.uvScale, UV_STEP, first, exact) then
      decal.UVScale = state.uvScale :: Vector2
    end

    if due(entry.rotation, "number", state.rotation, TURN_STEP, first, exact) then
      decal.Rotation = state.rotation :: number
    end

    if due(entry.zIndex, "switch", state.zIndex, 0, first, exact) then
      decal.ZIndex = state.zIndex :: number
    end

    if entry.glow ~= "Emissive" then
      return
    end

    if due(entry.strength, "ratio", state.emissiveStrength, SIZE_STEP, first, exact) then
      decal.EmissiveStrength = math.max(state.emissiveStrength :: number, 0)
    end

    if due(entry.tint, "Color3", state.emissiveTint, COLOR_STEP, first, exact) then
      decal.EmissiveTint = state.emissiveTint :: Color3
    end
  end

  return function(t: number, first: boolean, over: boolean)
    const exact = first or over or t <= 0 or t >= 1

    if due(size, "scale", sample.size, SIZE_STEP, first, exact) then
      const f = size.written :: vector
      const scaled = Vector3.new(rest.X * f.x, rest.Y * f.y, rest.Z * f.z)

      if mesh ~= nil then
        mesh.Scale = scaled
        look.refit()
      else
        look.size(scaled)
      end
    end

    if due(tone, "Color3", sample.color, COLOR_STEP, first, exact) then
      obj.Color = sample.color
    end

    if due(clear, "number", sample.transparency, CLEAR_STEP, first, exact) then
      obj.Transparency = sample.transparency
    end

    if due(shine, "number", sample.reflectance, CLEAR_STEP, first, exact) then
      obj.Reflectance = sample.reflectance
    end

    if due(material, "switch", sample.material, 0, first, exact) then
      wear(obj, sample.material)
    end

    if due(variant, "switch", sample.materialVariant, 0, first, exact) then
      obj.MaterialVariant = sample.materialVariant
    end

    if mesh ~= nil and due(vertex, "tone", sample.vertexColor, COLOR_STEP, first, exact) then
      const v = sample.vertexColor :: vector

      mesh.VertexColor = Vector3.new(v.x, v.y, v.z)
    end

    const surface = sample.surface

    if surface ~= nil then
      -- every call is made, so each gate sees this frame's sample
      const a = due(strength, "ratio", surface.emissiveStrength, SIZE_STEP, first, exact)
      const b = due(tint, "Color3", surface.emissiveTint, COLOR_STEP, first, exact)
      const c = due(surfaceColor, "Color3", surface.color, COLOR_STEP, first, exact)

      if a or b or c then
        look.glow(strength.written or 1, tint.written or WHITE, surfaceColor.written or WHITE)
      end

      if own ~= nil and due(alpha, "switch", surface.alphaMode, 0, first, exact) then
        const item = Enum.AlphaMode:FromName(surface.alphaMode :: string)

        if item ~= nil then
          own.AlphaMode = item
        end
      end
    end

    for _, entry in named do
      const state = sample.decals[entry.name]

      -- a Color glow is lit even where no state names its decal
      if state ~= nil then
        write(entry, state, first, exact)
      elseif entry.glow == "Color" then
        write(entry, UNSET, first, exact)
      end
    end
  end
end

-- what one piece draws as it spawns: its launch frame, whose look vector is
-- the way it sets off, its speed and whole life, its initial turn in degrees,
-- the velocity it inherits, and the curves and gradient it plays over its
-- life. on a path, the share of the life it walks it, its roll, where it
-- ends off the end point and its Progress draws
type Launch = {
  spawn: CFrame,
  spawned: number,
  speed: number,
  duration: number,
  pathTime: number,
  roll: number,
  offset: vector,
  pace: { number }?,
  turn: vector,
  inherited: vector,
  size: value_curve.Curve,
  squash: value_curve.Curve,
  clear: value_curve.Curve,
  tint: ColorSequence,
  keypoints: { ColorSequenceKeypoint },

  -- the piece's own draw of a list its randomizers vary, nil to sample the
  -- emit's
  states: ((t: number, out: state_list.Sample) -> state_list.Sample)?,
}

-- how pieces meet the world, built once per emit: the rays' filter, and the
-- response each piece copies to give its own bounce and friction
type Collision = {
  params: RaycastParams,
  config: collision_common.Config,
}

-- what every piece of one emit shares, read once as it emits
type Flight = {
  origin: CFrame,

  -- the template's turn as the emit plays it, carried by its parent's turn
  rotation: CFrame,
  rng: Random,
  collision: Collision?,

  -- the face pieces launch out of, which a States piece's turn is measured
  -- from
  normal: Enum.NormalId,

  -- what the force centers on, the target set or else the emitter the
  -- template sat in as it emitted; where it stood on frame `read` and its up
  -- axis, shared by every piece of the emit, nil when it had no place or was
  -- gone
  target: Instance?,
  anchor: Instance?,
  standing: vector?,
  up: vector,
  read: number,

  -- the force as the emit read it, which each piece flies a copy of
  force: particle_motion.Force?,

  -- the Color row's keypoints, read once for the emit's pieces that take it
  -- as it rests
  keypoints: { ColorSequenceKeypoint },

  -- what a piece moving through its states samples them with, built once
  -- for the emit's list; nil for a particle or a list of no state
  states: ((t: number, out: state_list.Sample) -> state_list.Sample)?,

  -- the template decals' own values, read once for the emit's states
  decals: { [string]: state_list.DecalState },

  -- the path every piece walks, read once for the emit; nil for any other
  -- motion
  path: path_motion.Path?,
}

const forge_mesh = {}

-- the engine calls, held here so a spec can stand in for them under lune
forge_mesh.engine = {
  alive = function(inst: Instance): boolean
    return inst:IsDescendantOf(game)
  end,
  pivot = function(model: Model): CFrame
    return model:GetPivot()
  end,
}

-- every piece alive across all emitters and emits, and the most that may be;
-- a spec lowers max, nothing else writes either
forge_mesh.pieces = { live = 0, max = 500 }

forge_mesh.PATH_TAG = PATH_TAG

-- where a force's target stands and its up axis, nil for a class that has no
-- place. the place is read on its own, lune keeping it apart from the frame
const function poseOf(target: Instance): (vector?, vector)
  if target:IsA("BasePart") then
    return toVector(target.Position), toVector(target.CFrame.UpVector)
  end

  if target:IsA("Attachment") then
    const world = target.WorldCFrame

    return toVector(world.Position), toVector(world.UpVector)
  end

  if target:IsA("Model") then
    const pivot = forge_mesh.engine.pivot(target)

    return toVector(pivot.Position), toVector(pivot.UpVector)
  end

  return nil, WORLD_UP
end

-- the force's center and up axis this frame, read from the engine by the
-- first piece to ask and kept for the rest of the emit's pieces. with no
-- target it is the emitter, whose last pose is held once the template leaves
-- it
const function standingNow(flight: Flight, template: BasePart): (vector?, vector)
  if flight.read == clock.frame then
    return flight.standing, flight.up
  end

  flight.read = clock.frame

  const target = flight.target

  if target == nil then
    if template.Parent == flight.anchor then
      const pose = originOf(template)

      flight.standing, flight.up = toVector(pose.Position), toVector(pose.UpVector)
    end
  elseif forge_mesh.engine.alive(target) then
    flight.standing, flight.up = poseOf(target)
  else
    flight.standing, flight.up = nil, WORLD_UP
  end

  return flight.standing, flight.up
end

-- where the path's EndPoint stands this frame, read from the engine by the
-- first piece to ask and kept for the rest; a gone one holds its last pose
const function endNow(flight: Flight): vector?
  const path = flight.path :: path_motion.Path

  if path.read == clock.frame then
    return path.finish
  end

  path.read = clock.frame

  const target = path.target

  if target ~= nil and forge_mesh.engine.alive(target) then
    path.finish = poseOf(target) or path.finish
  end

  return path.finish
end

-- what every piece of an emit walks: the curve built once, its ends fit to
-- the emitter's center or the EndPoint where it stands now, an EndPoint unset,
-- gone or of no place walked as drawn
const function pathOf(rows: any, origin: CFrame): path_motion.Path
  const curve = rows.Path :: path_curve.Curve
  const target = if rows.PathEnd == "Target" then rows.EndPoint :: Instance? else nil
  const finish = if target ~= nil and forge_mesh.engine.alive(target) then (poseOf(target)) else nil
  const ends = if rows.PathEnd == "Target" and finish == nil then "Free" else rows.PathEnd
  const face = FACES[rows.EmissionDirection] or FACES.Top

  return {
    bezier = Bezier.new(path_curve.points(curve)),
    drawn = path_curve.drawn(curve),
    ends = ends,
    bend = rows.Bend,
    reverse = rows.Reverse,
    radius = rows.EndRadius,
    after = rows.AfterPath,
    axis = toVector(origin:VectorToWorldSpace(Vector3.new(face.x, face.y, face.z))),
    center = toVector(origin.Position),
    flight = rows.FlightTime,
    progress = rows.Progress,
    target = if finish ~= nil then target else nil,
    finish = finish,
    read = clock.frame,
  }
end

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
  Orientation = knob("FacingCamera")
    :options(orient_common.MODES)
    :hidden(stated)
    :label("Orientation")
    :hint("How each piece turns as it flies: its own pose, toward the camera or along its velocity."),
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
  Rate = knob(20):min(0):unit("perSecond"):hidden(disabled):label("Rate"):hint("Emits per second while Enabled."),
  Rotation = knob(vector.zero)
    :mod()
    :hidden(stated)
    :label("Rotation")
    :hint("Initial rotation of each piece per axis, in degrees, drawn per piece."),
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

  -- the keys of the Frames and Textures folders the template plays, which the
  -- plugin writes
  FrameSet = knob(""):hidden(always),
  TextureSet = knob(""):hidden(always),
}

forge_mesh.properties = {}

forge_mesh.layout = {
  { title = "Emit", entries = { "EmitCount", "EmitDelay", "EmitDuration", "DestroyDelay" } },
  { title = "Appearance", entries = { "Color", "Orientation", "StateOrientation", "Size", "Squash", "Transparency" } },
  {
    title = "Emission",
    entries = {
      "EmissionDirection",
      "Enabled",
      "Lifetime",
      "Rate",
      "Rotation",
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
    title = "Behavior",
    entries = {
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

-- one piece: a bare copy of the template flown from its launch for its life,
-- wearing the look, its nested effects run on it
const function piece(
  ctx: reader.Ctx,
  attrs: any,
  template: BasePart,
  launch: Launch,
  flight: Flight,
  sets: look_common.Sets
)
  const scope = ctx.scope
  const duration = launch.duration
  const census = forge_mesh.pieces

  -- a full house drops the piece before it takes anything
  if census.live >= census.max then
    return
  end

  census.live += 1

  -- given back once, by whichever comes first: the piece's own end or the
  -- effect letting go (a clear, a cancel, a thrown step)
  local counted = true

  const function uncount()
    if counted then
      counted = false
      census.live -= 1
    end
  end

  lifetime.hold(scope, uncount)

  const obj = pool.take(scope, template, false, true) :: BasePart

  -- a frame set is lent from the store, never worn as a copy of its folder
  for _, child in obj:GetChildren() do
    if setFolder(child) then
      child:Destroy()
    end
  end

  const objMesh = obj:FindFirstChildOfClass("SpecialMesh")
  const templateMesh = template:FindFirstChildOfClass("SpecialMesh")

  -- read before a frame's decal joins the piece, where it would pass for one
  -- of the piece's own
  const decals = decalsOf(obj)

  -- a piece moving through a list of states samples it into a table of its
  -- own, once a frame, for its pose and its look alike
  const states = launch.states or flight.states
  const sample = if states ~= nil then states(0, {} :: any) else nil

  const look = look_common.start(scope, obj, template, attrs, duration, sets, {
    owner = template,
    decals = decals,
    modes = true,
    rng = flight.rng,
    ownDefault = true,
    stated = sample ~= nil,
  })

  -- one draw per curve for the piece's whole life, read through samplers built
  -- once, so a frame allocates nothing for them; a flat one is written once
  const sizeAt, sizeFlat = value_curve.sampler(launch.size, value_curve.draw(launch.size, flight.rng))
  const squashAt, squashFlat = value_curve.sampler(launch.squash, value_curve.draw(launch.squash, flight.rng))
  const clearAt, clearFlat = value_curve.sampler(launch.clear, value_curve.draw(launch.clear, flight.rng))

  const keypoints = launch.keypoints
  const tinted = not flatColor(launch.tint)
  const shaped = not (sizeFlat and squashFlat)
  const mode = attrs.Orientation :: orient_common.Mode
  const watching = mode == "FacingCamera" or mode == "FacingCameraWorldUp"

  -- a template's special mesh carries the size when the piece has one too
  const meshed = objMesh ~= nil and templateMesh ~= nil
  const rest = if meshed then (templateMesh :: SpecialMesh).Scale else template.Size

  -- the last size, transparency and color written; a value is written only
  -- once it is far enough from these, and always on the first frame, at an
  -- end of the curve and as the piece ends
  local writtenSize = rest
  local writtenClear = 0
  local writtenColor = obj.Color

  -- what each channel sampled last frame: one that samples the same again
  -- has stopped moving, at a key it holds, and is written exact
  local sampledSize: Vector3? = nil
  local sampledClear: number? = nil
  local sampledColor: Color3? = nil

  -- the share of a step each channel's first write after the spawn waits
  -- for, drawn per piece, so the pieces of one emit playing one curve cross
  -- their steps on different frames; every later write waits a whole step
  const stagger = if shaped or tinted or not clearFlat then flight.rng:NextNumber() else 1

  local sizeShare = stagger
  local clearShare = stagger
  local colorShare = stagger

  -- the piece's size, color and transparency at `t` of its life, each checked
  -- every frame only while it changes over the life
  const function appear(t: number, first: boolean, over: boolean)
    const exact = first or over or t <= 0 or t >= 1

    if first or shaped then
      const size = sizeAt(t)
      const x, y, z = size[1], size[2], size[3]
      const stretched = orient_common.squash(Vector3.new(rest.X * x, rest.Y * y, rest.Z * z), squashAt(t)[1])
      const sx, sy, sz = stretched.X, stretched.Y, stretched.Z

      const step = SIZE_STEP * sizeShare
      const moved = math.abs(sx - writtenSize.X) > step * math.max(math.abs(writtenSize.X), SIZE_FLOOR)
        or math.abs(sy - writtenSize.Y) > step * math.max(math.abs(writtenSize.Y), SIZE_FLOOR)
        or math.abs(sz - writtenSize.Z) > step * math.max(math.abs(writtenSize.Z), SIZE_FLOOR)
      const held = stretched == sampledSize

      sampledSize = stretched

      if first or moved or ((exact or held) and stretched ~= writtenSize) then
        writtenSize = stretched
        sizeShare = if first then sizeShare else 1

        if meshed then
          (objMesh :: SpecialMesh).Scale = stretched
          look.refit()
        else
          look.size(stretched)
        end
      end
    end

    if first or not clearFlat then
      const clear = clearAt(t)[1]
      const held = clear == sampledClear

      sampledClear = clear

      if
        first
        or math.abs(clear - writtenClear) > CLEAR_STEP * clearShare
        or ((exact or held) and clear ~= writtenClear)
      then
        writtenClear = clear
        clearShare = if first then clearShare else 1
        obj.Transparency = clear
      end
    end

    if first or tinted then
      const tone = color.keypointsAt(keypoints, t)

      const step = COLOR_STEP * colorShare
      const moved = math.abs(tone.R - writtenColor.R) > step
        or math.abs(tone.G - writtenColor.G) > step
        or math.abs(tone.B - writtenColor.B) > step
      const held = tone == sampledColor

      sampledColor = tone

      if first or moved or ((exact or held) and tone ~= writtenColor) then
        writtenColor = tone
        colorShare = if first then colorShare else 1
        obj.Color = tone
      end
    end
  end

  -- the states write a stated piece's look, its rows a particle's
  const dress = if sample ~= nil
    then dresser(
      obj,
      sample,
      look,
      decals,
      if meshed then objMesh else nil,
      rest,
      flight.rng:NextNumber(),
      flight.decals
    )
    else appear

  dress(0, true, false)

  -- a lock a modifier drives is read each step on the effect's clock, one at
  -- rest once
  const lockRow = attrs.LockedToPart
  const lockTrack = if lockRow.animated then lockRow() else nil
  local locked = if lockTrack ~= nil then lockTrack.at(launch.spawned) == true else lockRow.at(0) == true

  const windy = attrs.WindAffectsDrag
  const origin = flight.origin
  const facing = flight.rotation
  const turn = launch.turn
  const at = launch.spawn.Position
  const posing = attrs.Motion == "States"
  const billboard = facesCamera(nil, attrs)
  const stateMode = attrs.StateOrientation :: orient_common.Mode

  -- a piece moving through its states stands where it spawned on the emitter,
  -- as a particle or a path piece does, turned as its launch was and then as
  -- the template is in its parent's frame; where the template itself sits
  -- plays no part, and no other flight or turn row reaches it
  const base = if posing
    then CFrame.new(at) * particle_motion.launchTurn(launch.spawn, origin, flight.normal) * facing
    else nil

  -- where its states put it now. under a camera orientation the launch still
  -- places it, and only its own turn is kept, for the camera to turn it as it
  -- is drawn
  const function stanceNow(): CFrame
    const own = if sample ~= nil then sample.cframe else CFrame.identity
    const frame = (base :: CFrame) * own

    return if billboard then own.Rotation + frame.Position else frame
  end

  -- where its states put it as it was last drawn, nil for a particle
  local stance = if posing then stanceNow() else nil

  local position = toVector(at)
  local velocity = toVector(launch.spawn.LookVector) * launch.speed + launch.inherited
  local acceleration = vector.zero
  local drag = 0
  local amount = 0
  local wander = vector.zero
  local spin = vector.zero

  -- a piece the world stopped keeps its look but no longer moves
  local pinned = false

  -- the force the piece flies under, its place and axis written each frame
  -- and its driven rows over the life
  const pull: any = if flight.force ~= nil then table.clone(flight.force) else nil
  const collision = if flight.collision ~= nil and (lockTrack ~= nil or not locked) then flight.collision else nil
  const responds = collision ~= nil and (not posing or collision.config.mode == "Bounce")
  const response = if responds then table.clone((collision :: Collision).config) else nil

  -- the surfaces a States piece's states bounced off, for one that can meet
  -- any, and under Bounce its Bounce and Friction rows, read where they stand
  -- at a hit `span * share` into the step that began at `from`
  const mirror = if stance ~= nil and collision ~= nil then collision_common.mirror(toVector(stance.Position)) else nil
  const shifts: any = if posing and response ~= nil
    then { bounce = attrs.Bounce(nil, duration), friction = attrs.Friction(nil, duration), from = 0, span = 0 }
    else nil

  -- the initial turn, each step's spin added onto it
  local rotation = if posing
    then CFrame.identity
    else CFrame.fromOrientation(
      turn.x * utility.DEG_TO_RAD,
      turn.y * utility.DEG_TO_RAD,
      turn.z * utility.DEG_TO_RAD
    )

  -- the parent's pose the lock holds the piece to, in the frame the piece
  -- flies in, and where the last release left that frame in the world
  local grip = origin
  local lift = CFrame.identity
  local lifted = false

  -- the Acceleration row as last drawn, which a piece locked to its parent
  -- takes in the parent's frame
  local thrust: any = Vector3.zero

  const function aim()
    const v = Vector3.new(thrust.X, thrust.Y, thrust.Z)

    if locked then
      acceleration = toVector(grip:VectorToWorldSpace(v))
    elseif lifted then
      acceleration = toVector(lift:VectorToObjectSpace(v))
    else
      acceleration = toVector(thrust)
    end
  end

  if not posing then
    tween.drive(scope, attrs.Acceleration(nil, duration), function(v: any)
      if isVector(v) then
        thrust = v
        aim()
      end
    end)

    tween.drive(scope, attrs.Drag(nil, duration), function(v: number)
      drag = v
    end)
  end

  -- a driven row that draws no number rests where the row does, and keeps to
  -- the row's floor whatever a modifier reaches
  if pull ~= nil then
    for row, field in launch_common.DRIVEN[pull.kind] do
      const track = attrs[row]
      const rest = numberOr(track.value, 0)
      const lower = force_rows.rows[row].lower

      tween.drive(scope, track(nil, duration), function(v: any)
        const drawn = numberOr(v, rest)

        pull[field] = if lower ~= nil then math.max(drawn, lower) else drawn
      end)
    end
  end

  -- an orbit piece on the axis whose launch runs along it sets off from an
  -- angle of its own
  if pull ~= nil and pull.kind == "Orbit" then
    pull.angle = flight.rng:NextNumber(0, 2 * math.pi)
  end

  const wobbles = not posing and turbulent(attrs.Turbulence)
  const seed = if wobbles then flight.rng:NextNumber(0, 1000) else 0
  const frequency = attrs.TurbulenceFrequency
  const calm = if wobbles then particle_motion.rest(seed) else vector.zero

  if wobbles then
    tween.drive(scope, attrs.Turbulence(nil, duration), function(v: any)
      amount = numberOr(v, 0)
    end)
  end

  if response ~= nil and shifts == nil then
    tween.drive(scope, attrs.Bounce(nil, duration), function(v: any)
      response.bounce = numberOr(v, 0)
    end)

    tween.drive(scope, attrs.Friction(nil, duration), function(v: any)
      response.friction = numberOr(v, 0)
    end)
  end

  if not posing then
    tween.drive(scope, attrs.RotSpeed(nil, duration), function(v: any)
      if isVector(v) then
        spin = toVector(v) * utility.DEG_TO_RAD
      end
    end)
  end

  -- the parent the piece spawned under, whose last pose is held once the
  -- template leaves it, so a destroyed parent never snaps a locked piece
  const anchor = template.Parent
  local held = origin
  local heldOn = -1

  -- read once a frame, however many of the piece's steps ask
  const function live()
    if heldOn ~= clock.frame and template.Parent == anchor then
      heldOn = clock.frame
      held = (originOf(template))
    end

    return held
  end

  -- a piece locked to its parent rides the parent from where the lock took
  -- hold, and a freed one flies on from where it was let go
  const function placed(cf: CFrame)
    if locked then
      return live() * grip:ToObjectSpace(cf)
    end

    return if lifted then lift * cf else cf
  end

  -- a world point in the frame the piece flies in, carried back by the
  -- parent's move since the lock took hold
  const function unplaced(at: vector): vector
    if locked then
      return toVector(grip:PointToWorldSpace(live():PointToObjectSpace(Vector3.new(at.x, at.y, at.z))))
    end

    return if lifted then toVector(lift:PointToObjectSpace(Vector3.new(at.x, at.y, at.z))) else at
  end

  -- a world axis in the frame the piece flies in
  const function unturned(up: vector): vector
    if locked then
      return toVector(grip:VectorToWorldSpace(live():VectorToObjectSpace(Vector3.new(up.x, up.y, up.z))))
    end

    return if lifted then toVector(lift:VectorToObjectSpace(Vector3.new(up.x, up.y, up.z))) else up
  end

  -- a ray between two points of the frame the piece flies in, its hit read
  -- back into that frame. a piece casts only while free, so at most a lift
  -- lies between that frame and the world
  const function strike(from: vector, to: vector): { position: vector, normal: vector }?
    const params = (collision :: Collision).params

    if not lifted then
      const hit = collision_common.cast(params, from, to)

      return if hit ~= nil then { position = toVector(hit.Position), normal = toVector(hit.Normal) } else nil
    end

    const a = lift:PointToWorldSpace(Vector3.new(from.x, from.y, from.z))
    const b = lift:PointToWorldSpace(Vector3.new(to.x, to.y, to.z))
    const hit = collision_common.cast(params, toVector(a), toVector(b))

    if hit == nil then
      return nil
    end

    return {
      position = toVector(lift:PointToObjectSpace(hit.Position)),
      normal = toVector(lift:VectorToObjectSpace(hit.Normal)),
    }
  end

  -- the force this frame, placed where its center stands, in the frame the
  -- piece flies in; none while the target is gone, or for gravity of no mass
  const function forceNow(): particle_motion.Force?
    if pull == nil or (pull.kind == "Gravity" and pull.mass == 0) then
      return nil
    end

    const standing, up = standingNow(flight, template)

    if standing == nil then
      return nil
    end

    const at = unplaced(standing)

    if pull.kind == "Gravity" then
      pull.target = at
      return pull
    end

    const axis = vector.normalize(unturned(up))

    pull.center = at
    pull.axis = axis

    -- a piece's own ring sits at the height it spawned at
    if pull.height == nil then
      pull.height = vector.dot(position - at, axis)
    end

    return pull
  end

  -- an orbit launch trades the launch's speed for a share of the circular
  -- orbit's about where the center stands, in the frame the piece flies in. a
  -- piece at the center has no circle to fly, and keeps its launch
  if pull ~= nil and pull.kind == "Gravity" and attrs.OrbitLaunch and pull.mass ~= 0 and flight.path == nil then
    const standing, up = standingNow(flight, template)

    if standing ~= nil then
      const look = toVector(launch.spawn.LookVector)
      const circular =
        particle_motion.orbit(position, unplaced(standing), look, unturned(up), pull.mass, pull.softening)

      if vector.magnitude(circular) > 0 then
        velocity = circular * attrs.OrbitLaunchScale + launch.inherited
      end
    end
  end

  -- a piece on a path walks it for its path time, its first pose facing the
  -- way the path sets off
  const pathTime = launch.pathTime
  const walk, departure = path_motion.follow(flight.path, launch, function()
    return endNow(flight)
  end, unplaced)

  if walk ~= nil then
    const probe = math.min(pathTime, PROBE)

    position = walk(0)
    velocity = if probe > 0 then (walk(probe) - position) / probe else departure()
  end

  -- the turn the velocity last gave, held once the piece stops
  local heading: CFrame? = nil

  const function pose()
    -- the camera turn is taken where the piece is drawn, after a locked
    -- piece's parent carried it, so the parent's own turn never reaches it
    if stance ~= nil and billboard then
      const camera = workspace.CurrentCamera
      const view = if camera then camera.CFrame else nil
      const point = if locked or lifted then placed(CFrame.new(stance.Position)).Position else stance.Position
      const turned = orient_common.rotation(stateMode, facing, toVector(point), vector.zero, view, nil)

      return (turned * stance.Rotation + point) * look.offset()
    end

    if stance ~= nil then
      return placed(stance) * look.offset()
    end

    const camera = if watching then workspace.CurrentCamera else nil
    const turned =
      orient_common.rotation(mode, facing, position, velocity, if camera then camera.CFrame else nil, heading)

    heading = turned

    const drawn = position + wander
    const cf = CFrame.new(drawn.x, drawn.y, drawn.z) * turned * rotation

    return placed(cf) * look.offset()
  end

  -- the first pose is written at once, so a reused piece never shows a frame
  -- where its last holder let it go
  const first = pose()

  if finite(first) then
    obj.CFrame = first
  end

  const children = lifetime.join(scope)
  const emitOnFinish = scope.effects.prepareEmitOnFinish(obj, scope)

  scope.effects.emitNested(obj, scope.depth + 1, scope, children)

  look.play()

  const ended = lifetime.join(scope)
  const finish = lifetime.add(ended)

  local age = 0
  local moving = true

  -- whether the piece still walks its path, and the age it began to fly at,
  -- which its wander counts from
  local onPath = walk ~= nil
  local since = 0

  -- off its path's end a piece stops, or under Continue flies on the way it
  -- was going at its Speed; whether it flies on
  const function depart()
    onPath = false
    since = pathTime

    if (flight.path :: path_motion.Path).after ~= "Continue" then
      return false
    end

    velocity = path_motion.unit(velocity, departure) * launch.speed + launch.inherited

    return true
  end

  if walk ~= nil and pathTime <= 0 then
    depart()
  end

  const function place()
    const cf = pose()

    if finite(cf) then
      mover.move(scope, obj, cf)
    end
  end

  -- one step of a particle's flight, its substeps cast along what is drawn
  const function fly(dt: number)
    const gust = if windy then toVector(workspace.GlobalWind) else vector.zero
    const wind = if lifted and not locked then unturned(gust) else gust
    const hits = collision ~= nil and not locked

    -- the force's target is read once a frame, a gone one adding none
    const force = forceNow()

    const steps = if hits or drag > 0 or force ~= nil then particle_motion.substeps(dt) else 1
    const h = dt / steps

    for step = 1, steps do
      const nextPosition, nextVelocity = particle_motion.advance(position, velocity, acceleration, drag, wind, force, h)

      if not (numeric_common.usable(nextPosition) and numeric_common.usable(nextVelocity)) then
        break
      end

      -- the ray runs along what is drawn: the flown position plus the wander
      const nextWander = if amount > 0
        then particle_motion.wander(seed, age - since - dt + h * step, frequency, amount, calm)
        else vector.zero

      const hit = if hits then strike(position + wander, nextPosition + nextWander) else nil

      wander = nextWander

      if hit == nil then
        position, velocity = nextPosition, nextVelocity
        continue
      end

      const outcome, landed, rebound = collision_common.respond(response :: collision_common.Config, nextVelocity, hit)

      position, velocity = landed - wander, rebound

      if outcome == "kill" then
        moving = false
        break
      end

      if outcome == "stop" then
        pinned = true
        break
      end
    end
  end

  -- one step along the path, cast from where the piece was to where the path
  -- puts it now: a Kill ends it there, a Stop pins it there and a Bounce sends
  -- it off the path to fly the rest of its life. the share of the step past
  -- the path's end is flown
  const function trail(dt: number)
    const along = math.min(dt, pathTime - (age - dt))
    const nextPosition = walk(age)
    const nextVelocity = if along > SHORT_STEP then (nextPosition - position) / along else velocity
    const hit = if collision ~= nil and not locked then strike(position, nextPosition) else nil

    if hit == nil then
      position, velocity = nextPosition, nextVelocity

      if age >= pathTime and depart() and dt > along then
        fly(dt - along)
      end

      return
    end

    const outcome, landed, rebound = collision_common.respond(response :: collision_common.Config, nextVelocity, hit)

    position, velocity = landed, rebound
    onPath = false
    since = age

    if outcome == "kill" then
      moving = false
    elseif outcome == "stop" then
      pinned = true
    end
  end

  const function responded(share: number): collision_common.Config
    if shifts == nil then
      return (collision :: Collision).config
    end

    const config = response :: collision_common.Config
    const elapsed = shifts.from + shifts.span * share

    config.bounce = numberOr(shifts.bounce.at(elapsed), 0)
    config.friction = numberOr(shifts.friction.at(elapsed), 0)

    return config
  end

  -- one step through the states, cast from where the piece was drawn to
  -- where its states put it now: a Kill ends it at a hit, a Stop pins it
  -- there and a Bounce mirrors the rest of its states across the surface. the
  -- states' own turn is kept whatever the mirror does
  const function stand(dt: number)
    const nextStance = stanceNow()

    if mirror == nil then
      stance = nextStance
      return
    end

    if shifts ~= nil then
      shifts.from, shifts.span = age - dt, dt
    end

    const cast = if locked then unhit else strike
    const outcome, at = collision_common.step(mirror, responded, toVector(nextStance.Position), dt, cast)

    if outcome == "move" and mirror.bounces == 0 then
      stance = nextStance
      return
    end

    stance = nextStance.Rotation + Vector3.new(at.x, at.y, at.z)

    if outcome == "kill" then
      moving = false
    elseif outcome == "stop" then
      pinned = true
    end
  end

  -- the parent's pose as the last step found it, and its velocity at the
  -- piece when the lock last took hold, in the frame the piece flies in. a
  -- piece that spawned locked gripped none, so its release hands it all of
  -- the parent's
  local parentWas = origin
  local gripped = vector.zero

  -- the lock as the effect's clock stands `age` into the piece's life. the
  -- frame the piece flies in carries it on as it was last drawn, so the piece
  -- never jumps: a lock grips the parent from that pose and keeps the
  -- velocity as one in the parent's frame, so the piece rides with it, and a
  -- release freezes the parent's carry into the lift and adds the parent's
  -- velocity at the piece less what it had at the grip, so it trails off
  -- and a lock and release in turn never pumps its speed
  const function regrip(deltaTime: number)
    const now = live()
    const was = parentWas

    parentWas = now

    if ((lockTrack :: any).at(launch.spawned + age) == true) == locked then
      return
    end

    const carry = if locked then was * grip:Inverse() else lift
    const drawn = position + wander
    const own = if stance ~= nil then stance.Position else Vector3.new(drawn.x, drawn.y, drawn.z)
    const at = carry:PointToWorldSpace(own)

    -- read off the parent's move over the step, since an anchored parent a
    -- script moves reports no velocity of its own
    const moved = now:PointToWorldSpace(was:PointToObjectSpace(at)) - at
    const parentVelocity = if deltaTime > 0 then toVector(carry:VectorToObjectSpace(moved)) / deltaTime else vector.zero

    locked = not locked

    if locked then
      grip = lift:Inverse() * was
      gripped = parentVelocity
    else
      lift, lifted = carry, true
      velocity += parentVelocity - gripped
      gripped = vector.zero
    end

    aim()
  end

  const function advance(deltaTime: number)
    -- a piece at rest moves only with its parent or its frames
    if not moving then
      if locked or sets.frames then
        place()
      end

      return
    end

    -- a clock halted for good never reaches the end of the motion
    if scope.clock.halted then
      moving = false
      finish()
      return
    end

    -- the last step lands on the end of the piece's life exactly
    const dt = math.min(deltaTime, duration - age)

    age += dt

    if lockTrack ~= nil then
      regrip(deltaTime)
    end

    const t = if duration > 0 then age / duration else 1

    -- a pinned piece's look still plays through its states
    if states ~= nil and sample ~= nil then
      states(t, sample)
    end

    if dt > 0 and not pinned then
      if posing then
        stand(dt)
      else
        if onPath then
          trail(dt)
        else
          fly(dt)
        end

        const add = spin * dt

        if not pinned and moving and numeric_common.usable(add) then
          rotation *= CFrame.fromOrientation(add.x, add.y, add.z)
        end
      end
    end

    const over = not moving or age >= duration

    dress(t, false, over)
    place()

    if over then
      moving = false
      finish()
    end
  end

  const stepping = lifetime.step(scope, advance, "follow")
  lifetime.awaitJoin(ended)

  scope.effects.emitOnFinish(emitOnFinish, obj, scope.depth + 1, scope, children)

  -- the look may run past the motion, as frames played longer than the piece
  -- do
  const tail = look.life - duration

  if tail > 0 then
    tween.wait(scope, curve.new(tail, "linear"))
  end

  look.linger()
  lifetime.awaitJoin(children)

  -- a piece that ends ahead of its emit leaves the world at once, out of
  -- reach of the writes still running on the effect, its last move with it;
  -- the pool takes it back when the effect lets go
  stepping:Disconnect()
  mover.cancel(obj)
  obj.Parent = nil
  uncount()
end

function forge_mesh.emit(ctx: reader.Ctx, attrs: any)
  const template = ctx.ref :: BasePart
  const scope = ctx.scope

  -- a deferred signal has not yet told the pool of a write made just before a
  -- plain emit, so its pieces come from a copy taken now; a tick's keep the one
  -- its loop has
  if not ctx.constant then
    pool.refresh(template)
  end

  -- a plain emit of an enabled template switches it off; the tick's own emits
  -- leave it as it is
  if attrs.Enabled and not ctx.constant then
    enabled_effects.switch(template, false)
  end

  lifetime.wait(scope, attrs.EmitDelay)

  if attrs.EmitDuration > 0 and not ctx.constant then
    enabled_effects.window(ctx, forge_mesh, attrs.EmitDuration, attrs.TimeScale)
    return
  end

  if attrs.EmitCount <= 0 or bezier_common.SHAPES[attrs.Shape] == nil then
    return
  end

  -- the force and the material's glow are rows of cards of their own, read
  -- here beside the effect's, so the pieces and the look take them as one
  const rows = table.clone(attrs)

  for _, companion in { force_rows, material_rows } do
    for name, track in companion.resolve(ctx, template) do
      rows[name] = track
    end
  end

  -- every piece runs on the effect's clock, so one TimeScale track paces them
  -- all
  utility.speedFrom(scope, ctx.constant, rows.TimeScale)

  const sets: look_common.Sets = {
    frames = if rows.FrameSet ~= "" then frame_store.find(template, rows.FrameSet) else nil,
    textures = if rows.TextureSet ~= "" then frame_store.findTextures(template, rows.TextureSet) else nil,
  }

  if sets.frames then
    frame_store.warm(sets.frames, template, sets.textures)
  end

  if sets.textures then
    frame_store.warm(sets.textures)
  end

  const origin, size = originOf(template)
  const parent = template.Parent

  -- an attachment or no parent at all has no velocity to hand on
  const moved = parent ~= nil and parent:IsA("BasePart")

  const config: particle_motion.Config = {
    shape = rows.Shape,
    surface = rows.ShapeStyle == "Surface",
    partial = rows.ShapePartial,
    normal = Enum.NormalId[rows.EmissionDirection],
    face = rows.ShapeFace,
    spread = vector.zero,
  }

  const list = rows.States :: state_list.List
  const listed = rows.Motion == "States" and #list > 0
  const varied = listed and state_list.varied(list)
  const own = if listed then restOf(template) else nil

  -- the look rows keep what the author set under states but play no part, so
  -- a piece takes their defaults and draws nothing off them
  const tintRest = if listed then ColorSequence.new(template.Color) else rows.Color.value :: ColorSequence

  const flight: Flight = {
    origin = origin,
    rotation = turnOf(template, origin),
    rng = Random.new(),
    collision = nil,
    normal = config.normal,
    target = launch_common.target(rows),
    anchor = parent,
    standing = toVector(origin.Position),
    up = toVector(origin.UpVector),
    read = -1,
    force = launch_common.force(rows),
    keypoints = tintRest.Keypoints,
    states = nil,
    decals = {},
    path = if rows.Motion == "Path" then pathOf(rows, origin) else nil,
  }

  -- a varied list samples per piece, so it builds no shared sampler
  if own ~= nil then
    flight.decals = own.decals
    flight.states = if varied then nil else state_list.sampler(list, own)
  end

  if rows.CollisionMode ~= "Off" then
    const exclude = { containers.root(), template }

    -- the workspace and its terrain are the world the rays are for
    if parent ~= nil and parent ~= workspace and parent ~= workspace.Terrain then
      table.insert(exclude, parent)
    end

    const filterType, filterTag = collision_common.filter(rows.CollisionFilter, rows.CollisionFilterTag)

    const collision: collision_common.Config = {
      mode = rows.CollisionMode,
      bounce = 0,
      friction = 0,
      filterType = filterType,
      filterTag = filterTag,
      group = rows.CollisionGroup,
      respectCanCollide = rows.CollisionRespectCanCollide,
    }

    flight.collision = { params = collision_common.params(collision, exclude), config = collision }
  end

  -- each piece runs on a thread the effect holds, so a clear closes it
  const outstanding = lifetime.join(scope)

  -- every piece of an emit spawns at one time on the effect's clock: 0, or for
  -- a tick of an EmitDuration window how far into the window it fired. so
  -- these tracks differ between the pieces of one emit only by what their
  -- modifiers draw, and between ticks by where the window had got to
  const spawned = scope.windowAt or 0

  -- an appearance row with no modifier hands every piece the value it rests
  -- at, read here once rather than per piece
  const knobs = forge_mesh.attributes
  const sizeRest = (if listed then knobs.Size.default else rows.Size.value) :: value_curve.Curve
  const squashRest = (if listed then knobs.Squash.default else rows.Squash.value) :: value_curve.Curve
  const clearRest = (if listed then knobs.Transparency.default else rows.Transparency.value) :: value_curve.Curve

  const sized = not listed and modified(rows.Size)
  const squashed = not listed and modified(rows.Squash)
  const cleared = not listed and modified(rows.Transparency)
  const colored = not listed and modified(rows.Color)

  const census = forge_mesh.pieces

  for _ = 1, rows.EmitCount do
    -- a full house draws nothing more; each piece counts itself in as it
    -- starts, before the next is drawn
    if census.live >= census.max then
      break
    end

    const speed, duration, spread, turn, inheritance = launch_common.draw(rows, spawned)
    const tint = if colored then gradientOr(rows.Color().at(spawned), tintRest) else tintRest

    config.spread = spread

    const spawn = particle_motion.spawn(origin, size, config, flight.rng)

    -- a path piece's Lifetime is the time it walks its path, its life that
    -- and the time it flies on
    const roll, offset, flightTime, pace = path_motion.draw(flight.path, flight.rng, spawn)

    const launch: Launch = {
      spawn = spawn,
      spawned = spawned,
      speed = speed,
      duration = duration + flightTime,
      pathTime = duration,
      roll = roll,
      offset = offset,
      pace = pace,
      turn = turn,
      inherited = if inheritance ~= 0 and moved
        then toVector((parent :: BasePart).AssemblyLinearVelocity) * inheritance
        else vector.zero,
      size = if sized then curveOr(rows.Size().at(spawned), sizeRest) else sizeRest,
      squash = if squashed then curveOr(rows.Squash().at(spawned), squashRest) else squashRest,
      clear = if cleared then curveOr(rows.Transparency().at(spawned), clearRest) else clearRest,
      tint = tint,
      keypoints = if colored then tint.Keypoints else flight.keypoints,
      states = nil,
    }

    -- each piece draws its own values of a list its randomizers vary, on a
    -- sampler of its own; a list of none draws nothing more
    if varied then
      launch.states = state_list.sampler(state_list.resolve(list, flight.rng), own)
    end

    lifetime.spawn(outstanding, piece, ctx, rows, template, launch, flight, sets)
  end

  lifetime.awaitJoin(outstanding)
end

return forge_mesh
