const attr = require("@mod/attributes")
const knob = require("@mod/knob")
const reader = require("@mod/reader")

const FORCES = { "None", "Gravity", "Orbit" }

-- whether the template moves its pieces through their states, where no force
-- reaches them, read off the instance as the Force is
const function stated(ctx: any): boolean
  const ref = if ctx ~= nil then ctx.ref else nil

  return ref ~= nil and attr.get(ref, "Motion", nil) == "States"
end

-- whether no force reaches the template's pieces: they move through their
-- states, or walk a path they never fly off, past its end or by a bounce
const function unflown(ctx: any): boolean
  const ref = if ctx ~= nil then ctx.ref else nil

  if ref == nil then
    return false
  end

  const motion = attr.get(ref, "Motion", nil)

  if motion == "States" then
    return true
  end

  return motion == "Path"
    and attr.get(ref, "AfterPath", nil) ~= "Continue"
    and attr.get(ref, "CollisionMode", nil) ~= "Bounce"
end

-- whether the template's pieces walk a path, which sets their launch, so no
-- orbit launch reaches them
const function walking(ctx: any): boolean
  const ref = if ctx ~= nil then ctx.ref else nil

  return ref ~= nil and attr.get(ref, "Motion", nil) == "Path"
end

const function forceless(ctx: any, attrs: any)
  return unflown(ctx) or attrs.Force == "None"
end

const function gravityless(ctx: any, attrs: any)
  return unflown(ctx) or attrs.Force ~= "Gravity"
end

const function orbitless(ctx: any, attrs: any)
  return unflown(ctx) or attrs.Force ~= "Orbit"
end

const function launchless(ctx: any, attrs: any)
  return walking(ctx) or gravityless(ctx, attrs)
end

const function unlaunched(ctx: any, attrs: any)
  return launchless(ctx, attrs) or attrs.OrbitLaunch ~= true
end

const common = {}

common.stated = stated

-- what moves a mesh's pieces around the emitter or a target, declared apart
-- from the effect's own rows so the force card is their one editor
common.rows = {
  Force = knob("None")
    :options(FORCES)
    :hidden(unflown)
    :label("Force")
    :hint("What moves each piece around the emitter or a target: a pull or a ring."),
  ForceTarget = knob()
    :instance({ "Attachment", "BasePart", "Model" })
    :hidden(forceless)
    :label("ForceTarget")
    :hint("Optional. The force centers on the emitter unless a target is set."),
  GravityMass = knob(1000)
    :min(0)
    :unit("studsCubedPerSecondSquared")
    :mod()
    :hidden(gravityless)
    :label("GravityMass")
    :hint("How hard the center pulls. At distance d the pull is Mass / d squared, in studs per second squared."),
  GravitySoftening = knob(1):min(0):unit("studs"):hidden(gravityless):label("GravitySoftening"):hint(
    "Smooths the pull close to the center, so a piece passing through it is not flung away. At 0 a piece passing through the center is flung."
  ),
  OrbitLaunch = knob(false)
    :hidden(launchless)
    :label("OrbitLaunch")
    :hint("Launch each piece sideways at the speed of a circular orbit around the center."),
  OrbitLaunchScale = knob(1):min(0):hidden(unlaunched):label("OrbitLaunchScale"):hint(
    "Share of the circular orbit's speed each piece launches at. Below 1 it falls inward, from about 1.41 it escapes."
  ),
  OrbitRadius = knob(10):min(0):unit("studs"):mod():hidden(orbitless):label("OrbitRadius"):hint("The ring's radius."),
  OrbitSpin = knob(0.25)
    :unit("perSecond")
    :mod()
    :hidden(orbitless)
    :label("OrbitSpin")
    :hint("Turns per second around the ring. Negative goes the other way."),
  OrbitRise = knob(0)
    :unit("studsPerSecond")
    :mod()
    :hidden(orbitless)
    :label("OrbitRise")
    :hint("Climb speed of the ring along the axis. Negative sinks."),
  OrbitCapture = knob(2)
    :min(0)
    :unit("perSecond")
    :hidden(orbitless)
    :label("OrbitCapture")
    :hint("How quickly a piece settles onto the ring, per second."),
}

common.layout = {
  "Force",
  "ForceTarget",
  "GravityMass",
  "GravitySoftening",
  "OrbitLaunch",
  "OrbitLaunchScale",
  "OrbitRadius",
  "OrbitSpin",
  "OrbitRise",
  "OrbitCapture",
}

-- the rows read as a module of their own, over the clock the effect decided
const module = {
  id = "force",
  display = { name = "Force" },
  classifier = "",
  attributes = common.rows,
  properties = {},
  duration = function(ctx: reader.Ctx)
    return ctx.duration
  end,
  emit = function() end,
}

-- the force a template's card names, read off the instance for a rule of the
-- effect's own rows, which never sees the card's
function common.kindOf(ctx: any): string
  const ref = if ctx ~= nil then ctx.ref else nil
  const kind = if ref ~= nil then attr.get(ref, "Force", nil) else nil

  return if table.find(FORCES, kind) ~= nil then kind else "None"
end

-- whether the effect's own Speed is spent: an orbit places its pieces on the
-- ring, and an orbit launch picks the circular speed in its place
function common.speedless(ctx: any): boolean
  const kind = common.kindOf(ctx)

  return kind == "Orbit" or (kind == "Gravity" and attr.get(ctx.ref, "OrbitLaunch", nil) == true)
end

-- the rows as the template holds them, modifiers and all, the way an
-- effect's own rows resolve
function common.resolve(ctx: reader.Ctx, ref: Instance): any
  const attrs = reader.resolve(module :: any, {
    ref = ref,
    obj = ref,
    scope = ctx.scope,
    duration = ctx.duration,
    shared = ctx.shared,
  })

  return attrs
end

return common
