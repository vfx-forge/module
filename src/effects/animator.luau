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

-- the effect the animator sits under, past Folders, whose end its end lane
-- is placed against
local function hostOf(ref: Instance): Instance?
  local parent = ref.Parent

  while parent ~= nil and parent:IsA("Folder") do
    parent = parent.Parent
  end

  return parent
end

local function playable(queue: { any }?): { any }?
  if queue == nil or #queue == 0 or mods.inert(queue) then
    return nil
  end

  return queue
end

-- the start lane, and the end lane with the span left to place it against:
-- the host's, less the delay it waited, and none without a host
local function lanesOf(ref: Instance, scope: any, attrs: any): ({ any }?, { any }?, number?)
  if attrs.Property == "" then
    return nil, nil, nil
  end

  local lanes = mods.read(ref, "property", attrs.Property)

  if lanes == nil then
    return nil, nil, nil
  end

  local finish = playable(lanes["end"])
  local span = if finish ~= nil and scope ~= nil then emitters.hostSpan(scope, hostOf(ref)) else nil

  if span == nil then
    finish = nil
  end

  return playable(lanes.start), finish, if span ~= nil then math.max(span - attrs.EmitDelay, 0) else nil
end

function animator.duration(ctx: reader.Ctx, attrs: any)
  local start, finish, span = lanesOf(ctx.ref, ctx.scope, attrs)
  local reach = if start ~= nil then mods.span(start, 1) else 0

  if finish ~= nil and span ~= nil then
    reach = math.max(reach, span)
  end

  return attrs.EmitDelay + reach
end

function animator.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref
  local scope = ctx.scope
  local name = attrs.Property
  local target = targetOf(ref, attrs)
  local start, finish, span = lanesOf(ref, scope, attrs)

  if (start == nil and finish == nil) or target == nil then
    return
  end

  lifetime.wait(scope, attrs.EmitDelay)

  -- an end lane plays against the span left, so the row is built whole
  local track = nil

  if finish ~= nil and span ~= nil then
    local ok, current = pcall(function()
      return (target :: any)[name]
    end)

    track = mods.track(ref, "property", name, nil, span, nil, { value = if ok then current else nil })
  end

  local runs = RUNS[target]

  if runs == nil then
    runs = {}
    RUNS[target] = runs
  end

  local handle: { stop: (() -> ())? } = {}
  local before = runs[name]

  runs[name] = handle

  emitters.drive(target, "property", name, start or {}, scope, 1, {
    rule = if attrs.ResetOnFinish then nil else "keep",
    track = track,

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
