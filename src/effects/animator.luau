local knob = require("@mod/knob")
local mods = require("@mod/mods")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local emitters = require("@root/emitters")

local animator = {}

-- the run each target's property is under, newest emit first: a new run takes
-- the property over and stops the one before it, so one target property is
-- never driven twice by animators, re-emitted or cloned alike
local RUNS = setmetatable({} :: { [Instance]: { [string]: { stop: (() -> ())? } } }, { __mode = "k" })

animator.id = "animator"
animator.display = { name = "Property Animator", icon = "animator", order = 95 }
animator.classifier = `RayValue.{utility.PROPERTY_ANIMATOR_TAG}`

animator.attributes = {
  EmitDelay = knob(0):min(0):unit("seconds"):label("Delay"):hint("Seconds before the animation starts."),
  Target = knob():instance():label("Target"):hint("The instance animated. Empty animates the parent."),
  Property = knob(""):label("Property"):hint("The property of the target that is animated."),
  ResetOnFinish = knob(true)
    :label("ResetOnFinish")
    :hint("Whether the property goes back to what it was once the animation ends."),
}

animator.properties = {}

animator.layout = {
  { title = "Emit", entries = { "EmitDelay" } },
  { title = "Animation", entries = { "Target", "Property", "ResetOnFinish" } },
}

-- the instance driven: the Target row, else the parent the way a legacy
-- tween child finds its own
local function targetOf(ref: Instance, attrs: any): Instance?
  if attrs.Target ~= nil then
    return attrs.Target
  end

  return utility.getTarget(ref)
end

local function queueOf(ref: Instance, name: string): { any }?
  if name == "" then
    return nil
  end

  local lanes = mods.read(ref, "property", name)
  local queue = if lanes ~= nil then lanes.start else nil

  if queue == nil or #queue == 0 or mods.inert(queue) then
    return nil
  end

  return queue
end

function animator.duration(ctx: reader.Ctx, attrs: any)
  local queue = queueOf(ctx.ref, attrs.Property)

  if queue == nil then
    return attrs.EmitDelay
  end

  return attrs.EmitDelay + mods.span(queue, 1)
end

function animator.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref
  local scope = ctx.scope
  local name = attrs.Property
  local queue = queueOf(ref, name)
  local target = targetOf(ref, attrs)

  if queue == nil or target == nil then
    return
  end

  lifetime.wait(scope, attrs.EmitDelay)

  local runs = RUNS[target]

  if runs == nil then
    runs = {}
    RUNS[target] = runs
  end

  local handle: { stop: (() -> ())? } = {}
  local before = runs[name]

  runs[name] = handle

  emitters.drive(target, "property", name, queue, scope, 1, {
    rule = if attrs.ResetOnFinish then nil else "keep",

    -- the run before this one ends only once this one holds the property, so
    -- the target never goes back for a frame in between
    took = function()
      if before ~= nil and before.stop ~= nil then
        before.stop()
      end
    end,

    handle = handle,
  })
end

return animator
