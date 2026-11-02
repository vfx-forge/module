const knob = require("@mod/knob")
const reader = require("@mod/reader")

const function forceless(_, attrs: any)
  return attrs.Force == "None"
end

const function gravityless(_, attrs: any)
  return attrs.Force ~= "Gravity"
end

const function orbitless(_, attrs: any)
  return attrs.Force ~= "Orbit"
end

const common = {}

-- what moves a mesh's pieces around the emitter or a target, declared apart
-- from the effect's own rows so the force card is their one editor
common.rows = {
  Force = knob("None")
    :options({ "None", "Gravity", "Orbit" })
    :label("Force")
    :hint("What moves each piece around the emitter or a target: a pull or a ring."),
  ForceTarget = knob()
    :instance({ "Attachment", "BasePart", "Model" })
    :hidden(forceless)
    :label("ForceTarget")
    :hint("Optional. The force centers on the emitter unless a target is set."),
  GravityMass = knob(1000):min(0):mod():hidden(gravityless):label("GravityMass"):hint(
    "How hard the center pulls. At distance d the pull is Mass / d squared, in studs per second squared."
  ),
  GravitySoftening = knob(1)
    :min(0)
    :unit("studs")
    :hidden(gravityless)
    :label("GravitySoftening")
    :hint("Smooths the pull close to the center, so a piece passing through it is not flung away."),
  OrbitLaunch = knob(false)
    :hidden(gravityless)
    :label("OrbitLaunch")
    :hint("Launch each piece sideways at the speed of a circular orbit around the center."),
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
