-- a param's rule, run with the read's ctx and the other params
export type Rule = (ctx: Ctx, attrs: any, props: any) -> any

-- what a number param measures
export type Unit = "seconds" | "perSecond" | "perSecondSquared" | "studs" | "studsPerSecond" | "studsPerSecondSquared"

-- the built-ins an effect is grouped with in the adder
export type Category = "emitters" | "meshes" | "paths" | "shockwaves" | "camera" | "motion"

-- a param: one row in the panel and one value in attrs or props
export type Knob = {
  -- the lowest value, a number or one of the value's own type
  min: (self: Knob, value: any) -> Knob,
  -- the highest value, a number or one of the value's own type
  max: (self: Knob, value: any) -> Knob,
  -- older names the value is still read under
  aliases: (self: Knob, ...string) -> Knob,
  -- the strings a text param may hold, shown as a dropdown
  options: (self: Knob, list: { string }) -> Knob,
  -- the row's name in the panel
  label: (self: Knob, text: string) -> Knob,
  -- the row's tooltip
  hint: (self: Knob, text: string) -> Knob,
  -- a curve param edited in the curve editor, starting as this preset
  curve: (self: Knob, preset: string) -> Knob,
  -- what the number measures
  unit: (self: Knob, unit: Unit) -> Knob,
  -- hides the row while the rule answers true
  hidden: (self: Knob, rule: Rule) -> Knob,
  -- locks the row to its default while the rule answers true
  readonly: (self: Knob, rule: Rule) -> Knob,
  -- a value modifiers can animate, read as a Track, with default modifiers made by sdk.mod
  mod: (self: Knob, ...Mod) -> Knob,
}

-- a default modifier on an animated param
export type Mod = {
  -- seconds it runs, or a rule answering them
  duration: (self: Mod, seconds: number | Rule) -> Mod,
  -- the preset or curve param value it eases with
  curve: (self: Mod, shape: string | Rule) -> Mod,
  -- seconds it waits before it starts
  delay: (self: Mod, seconds: number | Rule) -> Mod,
  -- "start" or "end", the moment of the effect it runs from
  lane: (self: Mod, name: string) -> Mod,
}

-- what params answers
export type Params = {
  -- params stored as attributes, by name
  attributes: { [string]: Knob }?,
  -- params that are properties of the emitted instance, by property name
  properties: { [string]: Knob }?,
}

-- an animated param's value
export type Track = {
  -- the value at the start
  value: any,
  -- false when no modifier moves it
  animated: boolean,
  -- seconds the modifiers run
  duration: number,
  -- the value at a time in seconds; call it as track:at(t)
  at: (self: Track, elapsed: number) -> any,
}

-- what emit is handed about the instance it plays
export type Ctx = {
  -- the instance being emitted
  ref: Instance,
  -- the effect's length in seconds, from duration, else 1
  duration: number,
  -- true when an Enabled loop emitted it
  constant: boolean?,
}

-- a value over time
export type Curve = {
  -- seconds it runs
  duration: number,
  -- the value at t, 0 to 1 over the curve
  at: (self: Curve, t: number) -> number,
}

-- what sdk.curve shapes a curve with: a preset's name, a curve param's value, a chain of vectors, or a function of t from 0 to 1
export type CurveShape = string | buffer | { vector } | (t: number) -> number

-- one property or attribute this effect writes, handed over between overlapping emits and put back at the end
export type Writer = {
  -- writes the value now
  set: (self: Writer, value: any) -> (),
}

-- a group of pieces the effect waits for
export type Join = {}

-- a 3D path through a chain of points
export type Bezier = {
  -- new points, in the same format
  set: (self: Bezier, points: { vector }) -> (),
  -- the point at t, 0 to 1 with each segment an equal share
  at: (self: Bezier, t: number) -> vector,
  -- the point u of the way along by distance, 0 to 1
  atUniform: (self: Bezier, u: number) -> vector,
  -- the length in studs
  length: (self: Bezier) -> number,
  -- the unit direction of travel at t, zero where the path stands still
  tangent: (self: Bezier, t: number) -> vector,
}

-- where a shape draws its point
export type ShapeOptions = {
  -- on the surface rather than inside
  surface: boolean?,
  -- how much of the shape it draws from, 0 to 1: a cylinder's narrowed end, a sphere's cap, a disc's ring
  partial: number?,
  -- the way the shape faces, Top when none is given
  normal: Enum.NormalId?,
  -- the same seed draws the same point
  seed: number?,
}

-- a random point in a shape at cframe with size, in world space
export type ShapeFunction = (cframe: CFrame, size: Vector3, options: ShapeOptions?) -> Vector3

-- what every method of a custom effect is handed first
export type V1 = {
  -- a param with its default value, or a rule answering it
  knob: (default: any) -> Knob,
  -- default modifiers for an animated param
  mod: {
    -- runs from value to the param's own value
    from: (value: any) -> Mod,
    -- runs from the param's own value to value
    to: (value: any) -> Mod,
  },
  -- waits seconds of effect time, and answers the seconds waited
  wait: (ctx: Ctx, seconds: number) -> number,
  -- calls fn every frame with the frame's seconds and the seconds since the step began, and answers a function that stops it
  step: (ctx: Ctx, fn: (dt: number, elapsed: number) -> ()) -> () -> (),
  -- a curve running for duration seconds
  curve: (duration: number, shape: CurveShape, options: {}?) -> Curve,
  -- plays the curve on effect time, calling fn with each value; the effect waits for it
  tween: (ctx: Ctx, curve: Curve, fn: (alpha: number) -> ()) -> (),
  -- cleans thing up when the effect ends: an instance, a connection, a function or a thread
  hold: <T>(ctx: Ctx, thing: T) -> T,
  -- a group of pieces the effect waits for
  join: (ctx: Ctx) -> Join,
  -- runs fn on a thread of its own, counted into join
  spawn: (join: Join, fn: (...any) -> (), ...any) -> (),
  -- waits until every piece of join is done
  await: (join: Join) -> (),
  -- emits instance as a nested effect the effect waits for
  emit: (ctx: Ctx, instance: Instance) -> (),
  -- a writer for a property of obj
  getWriter: (ctx: Ctx, obj: Instance, property: string) -> Writer,
  -- a writer for an attribute of obj
  getAttributeWriter: (ctx: Ctx, obj: Instance, name: string) -> Writer,
  -- runs the effect's time at a param declared with :mod()
  speed: (ctx: Ctx, track: Track) -> (),
  -- writes a param's value now, and every frame while modifiers move it
  apply: (ctx: Ctx, row: any, write: (value: any) -> ()) -> (),
  -- logs text once per instance; the effect plays on
  warn: (ctx: Ctx, text: string) -> (),
  -- plays this emit alone on ctx.ref: a later emit while it plays ends at its own lock, silently
  lock: (ctx: Ctx) -> (),
  -- t of the way from a to b, for any value that blends
  lerp: <T>(a: T, b: T, t: number) -> T,
  -- colors blended the way eyes see them
  color: {
    -- t of the way from a to b, in Oklab
    blend: (a: Color3, b: Color3, t: number) -> Color3,
    -- a color as Oklab lightness and its two hues
    toOklab: (color: Color3) -> Vector3,
    -- an Oklab value back as a color, clamped into range
    fromOklab: (lab: Vector3) -> Color3,
  },
  -- random points in shapes
  shape: {
    -- a point in a box
    box: ShapeFunction,
    -- a point in a cylinder whose axis runs along the normal
    cylinder: ShapeFunction,
    -- a point in a sphere
    sphere: ShapeFunction,
    -- a point in a disc lying across the normal
    disc: ShapeFunction,
  },
  -- 3D paths
  bezier: {
    -- a path through 3n + 1 points, or 2 for a straight one
    new: (points: { vector }) -> Bezier,
  },
}

-- a custom effect module
export type Effect = {
  -- the facade version it is written against
  sdk_version: number,
  -- unique across every effect
  id: string,
  -- how the panel shows it, the built-ins the adder groups it with, under Custom when none,
  -- and the engine properties of its instance the panel mirrors like a built-in's
  display: {
    name: string,
    icon: string?,
    category: Category?,
    -- "all", or the names of the properties mirrored; none when absent
    reflect: ("all" | { string })?,
  },
  -- the selector an instance must match to play it
  classifier: string,
  -- a selector for the descendants it plays itself, so nothing else does
  components: string?,
  -- the panel's rows: param names and groups of them
  layout: { any }?,
  -- true when an Enabled loop may emit it
  constant: boolean?,
  -- the params, called once per load
  params: ((sdk: V1) -> Params)?,
  -- the effect's length in seconds
  duration: ((sdk: V1, attrs: any, props: any) -> number)?,
  -- plays the effect on ctx.ref
  emit: (sdk: V1, ctx: Ctx, attrs: any, props: any) -> (),
  -- called on the old version before a reload drops it
  unload: (() -> ())?,
  -- a new instance the classifier finds, unparented, made by the plugin's adder
  template: ((sdk: V1) -> Instance)?,
}

return nil
